#!/usr/bin/env bash
#
# cleanup-jenkins-builds.sh - prune old Jenkins build history so the controller
# root disk doesn't fill up. Deletes builds through the Jenkins API (doDelete -
# the clean way; Jenkins updates its own records), keeping the newest N per job:
#
#   job name contains "coverage" -> keep $KEEP_COVERAGE (default 8)
#   every other job              -> keep $KEEP_OTHER    (default 50)
#
# Idempotent and non-interactive - safe to run repeatedly and from a systemd
# timer. Reads the API token from ./api-key.md (gitignored) and talks only to
# the HTTP API, so it can run from anywhere that can reach the controller.
#
# Usage:
#   ./cleanup-jenkins-builds.sh [-n|--dry-run]
#
# Env overrides:
#   JENKINS_URL   (default http://jenkins-server:8080)
#   JENKINS_USER  (default jmg)
#   KEEP_COVERAGE (default 8)
#   KEEP_OTHER    (default 50)
#   ONLY_JOB      (restrict to a single job name, for testing)
#
# Exit: 0 on success; 2 on setup error; 1 if any individual delete failed.
# Note: handles flat top-level jobs (this controller's layout); folder /
# multibranch jobs would need path encoding.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JENKINS_URL="${JENKINS_URL:-http://jenkins-server:8080}"
JUSER="${JENKINS_USER:-jmg}"
KEEP_COVERAGE="${KEEP_COVERAGE:-8}"
KEEP_OTHER="${KEEP_OTHER:-50}"
DRY_RUN=0
case "${1:-}" in
    -n|--dry-run) DRY_RUN=1 ;;
    "")           ;;
    *)            echo "usage: $0 [-n|--dry-run]" >&2; exit 2 ;;
esac

TOKEN="$(tr -d ' \t\r\n' < "$HERE/../api-key.md" 2>/dev/null || true)"
[[ -n "$TOKEN" ]] || { echo "ERROR: no API token in $HERE/../api-key.md" >&2; exit 2; }

# curl wrapper: -g disables URL globbing (tree queries use [] and {}).
jc() { curl -g -fsS -u "$JUSER:$TOKEN" "$@"; }

# CSRF crumb (Jenkins requires it for POSTs, incl. doDelete).
if ! crumb_json="$(jc "$JENKINS_URL/crumbIssuer/api/json")"; then
    echo "ERROR: cannot reach or authenticate to $JENKINS_URL" >&2; exit 2
fi
CRUMB="$(sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p'            <<<"$crumb_json")"
CFIELD="$(sed -n 's/.*"crumbRequestField":"\([^"]*\)".*/\1/p' <<<"$crumb_json")"

keep_for() { case "$1" in *coverage*) echo "$KEEP_COVERAGE" ;; *) echo "$KEEP_OTHER" ;; esac; }

if [[ -n "${ONLY_JOB:-}" ]]; then
    JOBS=("$ONLY_JOB")
else
    mapfile -t JOBS < <(jc "$JENKINS_URL/api/json?tree=jobs[name]" \
        | grep -oE '"name":"[^"]+"' | sed 's/^"name":"//; s/"$//')
fi
(( ${#JOBS[@]} )) || { echo "ERROR: no jobs found" >&2; exit 2; }

dry_label=""; (( DRY_RUN )) && dry_label="[dry-run] "
echo "== ${dry_label}cleanup: coverage keep=$KEEP_COVERAGE, others keep=$KEEP_OTHER =="
deleted=0 failed=0
for job in "${JOBS[@]}"; do
    keep="$(keep_for "$job")"
    # existing build numbers, newest first. Use allBuilds (not builds), which is
    # NOT capped at the API's default 100 - otherwise jobs with >100 builds only
    # get trimmed down to their 100 most recent and the overflow is left behind.
    mapfile -t builds < <(jc "$JENKINS_URL/job/$job/api/json?tree=allBuilds[number]" 2>/dev/null \
        | grep -oE '"number":[0-9]+' | grep -oE '[0-9]+' | sort -rn || true)
    n=${#builds[@]}
    if (( n <= keep )); then
        printf '  %-34s keep=%-3d have=%-5d  (nothing to delete)\n' "$job" "$keep" "$n"
        continue
    fi
    to_delete=("${builds[@]:keep}")   # everything older than the newest $keep
    printf '  %-34s keep=%-3d have=%-5d  delete %d  (#%d .. #%d)\n' \
        "$job" "$keep" "$n" "${#to_delete[@]}" "${to_delete[0]}" "${to_delete[-1]}"
    (( DRY_RUN )) && continue
    for b in "${to_delete[@]}"; do
        if jc -X POST -H "$CFIELD:$CRUMB" "$JENKINS_URL/job/$job/$b/doDelete" -o /dev/null; then
            deleted=$((deleted + 1))
        else
            echo "    WARN: failed to delete $job #$b" >&2
            failed=$((failed + 1))
        fi
    done
done

if (( DRY_RUN )); then
    echo "== dry-run only; nothing deleted =="
else
    echo "== deleted $deleted build(s); $failed failure(s) =="
fi
(( failed == 0 ))
