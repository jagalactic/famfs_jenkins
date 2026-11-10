#!/usr/bin/env bash
#
# register-all-jobs.sh - re-inline every existing Jenkins job whose entrypoint
# is groovy/<job>.groovy, by calling create-job.sh for each. Job entrypoints are
# inlined into their Jenkins config, so after a repo reorg (files moved) or an
# entrypoint edit you must re-register. Existing descriptions are preserved.
#
# Usage:  scripts/register-all-jobs.sh [-n|--dry-run]   (-n shows per-job config diffs)
# Env:    JENKINS_URL (default http://jenkins-server:8080), JENKINS_USER (jmg)
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
JENKINS_URL="${JENKINS_URL:-http://jenkins-server:8080}"
JUSER="${JENKINS_USER:-jmg}"
TOKEN="$(tr -d ' \t\r\n' < "$ROOT/api-key.md")"
DRY=0; [[ "${1:-}" == "-n" || "${1:-}" == "--dry-run" ]] && DRY=1

mapfile -t JOBS < <(curl -g -fsS -u "$JUSER:$TOKEN" "$JENKINS_URL/api/json?tree=jobs[name]" \
    | grep -oE '"name":"[^"]+"' | sed 's/^"name":"//; s/"$//')
(( ${#JOBS[@]} )) || { echo "ERROR: no jobs found at $JENKINS_URL" >&2; exit 2; }

n=0
for job in "${JOBS[@]}"; do
    if [[ ! -f "$ROOT/groovy/$job.groovy" ]]; then
        echo "  skip $job (no groovy/$job.groovy)"; continue
    fi
    # preserve the current description
    desc="$(curl -g -fsS -u "$JUSER:$TOKEN" "$JENKINS_URL/job/$job/api/json?tree=description" \
        | python3 -c 'import sys,json; print(json.load(sys.stdin).get("description") or "")' 2>/dev/null || true)"
    if (( DRY )); then
        echo "  would re-register: $job"
        JOB="$job" JENKINS_USER="$JUSER" DESC="$desc" "$HERE/create-job.sh" -n | sed 's/^/      /'
    else
        echo "  re-registering: $job"
        # create-job.sh refuses (exit 3) if the live job has triggers the
        # entrypoint does not declare; that is deliberate -- fix the entrypoint.
        JOB="$job" JENKINS_USER="$JUSER" DESC="$desc" "$HERE/create-job.sh" | grep -E "^triggers:" | sed 's/^/      /'
    fi
    n=$((n+1))
done
echo "== $([ "$DRY" = 1 ] && echo 'dry-run: ')$n job(s) $([ "$DRY" = 1 ] && echo 'would be ' || echo 're-')registered =="
