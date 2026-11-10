#!/bin/bash
# create-job.sh - register/update a Jenkins Pipeline job from groovy/<job>.groovy.
# Pass JOB=<name>; the script reads groovy/<name>.groovy, builds the config.xml,
# and POSTs createItem (new) or config.xml (update). API token is read from
# ./api-key.md (gitignored, never printed).
#
# Site-specific values are kept out of the entrypoints: an @NOTIFY_EMAIL@
# placeholder in the entrypoint is replaced with NOTIFY_EMAIL from ./site.conf
# (gitignored; see site.conf.example) as the config.xml is built.
#
# The job config is REBUILT from scratch, so anything configured only in the
# Jenkins UI would be lost. To make that safe:
#   - triggers are taken from the entrypoint: every cron('...') / pollSCM('...')
#     inside properties([pipelineTriggers([...])]) is also written into the
#     config.xml, so the trigger is live immediately (not only after the first
#     run) and survives every re-registration;
#   - an existing <hudson.model.ParametersDefinitionProperty> block is carried
#     over verbatim;
#   - if the existing job has trigger specs that the new config would drop,
#     the update is REFUSED unless FORCE=1 (this is exactly what silently
#     killed every nightly *_local job on 2026-09-04).
#
# Usage:  JOB=<name> [JENKINS_USER=jmg] scripts/create-job.sh [-n|--dry-run]
#   -n    build the config and show a diff against the live one; no POST.
# Env:    JENKINS_URL, JENKINS_USER, ENTRY (entrypoint path), DESC, FORCE=1,
#         NOTIFY_EMAIL (overrides site.conf)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
JENKINS_URL="${JENKINS_URL:-http://jenkins-server:8080}"
JOB="${JOB:-ndctl_qemu_test_famfs_local}"
JUSER="${JENKINS_USER:-jenkins}"
TOKEN="$(tr -d ' \t\r\n' < "$HERE/../api-key.md")"
ENTRY="${ENTRY:-$HERE/../groovy/$JOB.groovy}"
DESC="${DESC:-$JOB - run_qemu-based test job}"
# Site config (gitignored): NOTIFY_EMAIL. The environment wins over the file.
SITE_CONF="$HERE/../site.conf"
if [[ -z "${NOTIFY_EMAIL:-}" && -f "$SITE_CONF" ]]; then
  NOTIFY_EMAIL="$(sed -n 's/^NOTIFY_EMAIL=//p' "$SITE_CONF" | tail -1 | tr -d "\"' \t\r")"
fi
export NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
DRY=0; [[ "${1:-}" == "-n" || "${1:-}" == "--dry-run" ]] && DRY=1

[ -f "$ENTRY" ] || { echo "missing $ENTRY" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CONFIG="$TMP/new.xml"; OLD="$TMP/old.xml"

# Existing config (empty file if the job does not exist yet).
EXISTS=0
if curl -g -fsS -u "$JUSER:$TOKEN" "$JENKINS_URL/job/$JOB/config.xml" -o "$OLD" 2>/dev/null; then
  EXISTS=1
else
  : > "$OLD"
fi

# Build config.xml: a Pipeline (CpsFlowDefinition) with the entrypoint inline
# (CDATA, so no XML escaping needed). Triggers mirrored from the entrypoint;
# parameters carried over from the existing config.
python3 - "$ENTRY" "$OLD" "$CONFIG" "$DESC" "${FORCE:-0}" <<'PY'
import os, re, sys, html
entry, old, out, desc, force = sys.argv[1:6]
src = open(entry).read()
if "@NOTIFY_EMAIL@" in src:
    notify = os.environ.get("NOTIFY_EMAIL", "")
    if not notify:
        sys.stderr.write("REFUSING: %s uses @NOTIFY_EMAIL@ but NOTIFY_EMAIL is not set.\n"
                         "  Copy site.conf.example to site.conf and set it (or export NOTIFY_EMAIL).\n" % entry)
        sys.exit(4)
    src = src.replace("@NOTIFY_EMAIL@", notify)
oldx = open(old).read()

crons = re.findall(r"""cron\(\s*['"]([^'"]+)['"]\s*\)""", src)
polls = re.findall(r"""pollSCM\(\s*['"]([^'"]+)['"]\s*\)""", src)

old_specs = set(re.findall(r"<spec>([^<]*)</spec>", oldx))
new_specs = set(crons) | set(polls)
dropped = old_specs - new_specs
if dropped and force != "1":
    sys.stderr.write(
        "REFUSING: the live job has trigger spec(s) the new config would drop: %s\n"
        "  Declare them in the entrypoint as properties([pipelineTriggers([cron('...')])])\n"
        "  or re-run with FORCE=1 to drop them on purpose.\n" % sorted(dropped))
    sys.exit(3)

props = []
m = re.search(r"<hudson\.model\.ParametersDefinitionProperty>.*?</hudson\.model\.ParametersDefinitionProperty>", oldx, re.S)
if m:
    props.append(m.group(0))
if new_specs:
    t = ["    <org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>",
         "      <triggers>"]
    for c in crons:
        t += ["        <hudson.triggers.TimerTrigger>",
              "          <spec>%s</spec>" % html.escape(c),
              "        </hudson.triggers.TimerTrigger>"]
    for p in polls:
        t += ["        <hudson.triggers.SCMTrigger>",
              "          <spec>%s</spec>" % html.escape(p),
              "          <ignorePostCommitHooks>false</ignorePostCommitHooks>",
              "        </hudson.triggers.SCMTrigger>"]
    t += ["      </triggers>",
          "    </org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>"]
    props.append("\n".join(t))

properties = "<properties/>" if not props else "<properties>\n" + "\n".join(props) + "\n  </properties>"
assert "]]>" not in src, "entrypoint contains ']]>'"
xml = """<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>%s</description>
  <keepDependencies>false</keepDependencies>
  %s
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script><![CDATA[
%s]]></script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
""" % (html.escape(desc), properties, src)
open(out, "w").write(xml)
print("triggers: %s" % (", ".join(sorted(new_specs)) or "none"))
PY

if (( DRY )); then
  echo "== dry-run: $JOB ($([ $EXISTS = 1 ] && echo update || echo create)); diff live -> new:"
  diff -u "$OLD" "$CONFIG" || true
  exit 0
fi

# CSRF crumb (Jenkins requires it for POSTs)
crumb_json="$(curl -fsS -u "$JUSER:$TOKEN" "$JENKINS_URL/crumbIssuer/api/json")"
CRUMB="$(sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p' <<<"$crumb_json")"
CFIELD="$(sed -n 's/.*"crumbRequestField":"\([^"]*\)".*/\1/p' <<<"$crumb_json")"

if (( EXISTS )); then
  echo "Updating existing job: $JOB"
  curl -fsS -X POST -u "$JUSER:$TOKEN" -H "$CFIELD:$CRUMB" \
       -H "Content-Type: application/xml" --data-binary @"$CONFIG" \
       "$JENKINS_URL/job/$JOB/config.xml"
else
  echo "Creating job: $JOB"
  curl -fsS -X POST -u "$JUSER:$TOKEN" -H "$CFIELD:$CRUMB" \
       -H "Content-Type: application/xml" --data-binary @"$CONFIG" \
       "$JENKINS_URL/createItem?name=$JOB"
fi
echo "OK: $JENKINS_URL/job/$JOB/"
