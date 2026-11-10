#!/usr/bin/env bash
#
# ndctl-regression-watch.sh - the WATCHER/dispatcher for ndctl_regression_public.
#
# Polls the kernel and ndctl repos with `git ls-remote` (no clone), notices new
# tags and branch-tip movements, and triggers the ndctl_regression_public
# Jenkins job (Build with Parameters) for each, using a "hold-one-fixed + tips"
# pairing. Each kernel is tested (in ONE build) against an ndctl SET = the
# pending branch + the last NDCTL_KEEP releases, so a build amortizes the kernel
# compile across several ndctl versions and the worker attributes per-ref:
#
#   new kernel tag    -> test (that kernel) x (ndctl SET)
#   new ndctl release -> test (K_ref)       x (ndctl SET, incl. the new release)
#   master/pending tip moved, or idle day -> test (kernel master) x (pending)
#
# Detection is by set-difference against a small state dir, so each ref is
# dispatched once. Idempotent, non-interactive -> run from cron / a systemd
# timer. Reads the Jenkins API token from ./api-key.md.
#
# ============================ EDIT WHAT GETS TESTED ==========================
# The kernel repo/floor/branch and ndctl repo/floor/branch below are the whole
# policy. Change them (or the flags) to change what is watched and dispatched.
KERNEL_REPO="${KERNEL_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
KERNEL_MIN="${KERNEL_MIN:-7.1}"     # only kernels >= this MAJOR.MINOR (where the code is upstream)
KERNEL_BRANCH="${KERNEL_BRANCH:-master}"  # tip branch to watch for movement (on MAINLINE_REPO, not KERNEL_REPO)
# Linus' tree: the tip (KERNEL_BRANCH) is watched and built from here. linux-stable
# has every vX.Y/-rcN/.Z tag (so it stays the tag source), but its 'master' is a
# re-merge of mainline that trails Linus by hours to days.
MAINLINE_REPO="${MAINLINE_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git}"
NDCTL_REPO="${NDCTL_REPO:-https://github.com/pmem/ndctl.git}"
NDCTL_MIN="${NDCTL_MIN:-85}"        # only ndctl releases vN with N >= this (nothing older)
NDCTL_PENDING_BRANCH="${NDCTL_PENDING_BRANCH:-pending}"  # bleeding-edge staging branch (everything queues here for the next release)
NDCTL_KEEP="${NDCTL_KEEP:-2}"       # test the last N ndctl releases (>= NDCTL_MIN) against each kernel, alongside pending

WATCH_KERNEL_TAGS="${WATCH_KERNEL_TAGS:-1}"   # dispatch on new kernel release/rc/stable tags
WATCH_NDCTL_TAGS="${WATCH_NDCTL_TAGS:-1}"     # dispatch on new ndctl releases
WATCH_TIPS="${WATCH_TIPS:-1}"                 # dispatch kernel-master x ndctl-pending when a watched tip moves
HEARTBEAT="${HEARTBEAT:-1}"                   # on a fully idle run, still dispatch kernel-master x ndctl-pending
# ============================================================================

# Which repo/ref the *worker* should clone (what actually gets handed to Jenkins).
# Usually the same as the watched repos; override e.g. to point the worker at a
# local mirror on thing1 while still watching the public URL for new tags.
KERNEL_REPO_BUILD="${KERNEL_REPO_BUILD:-$KERNEL_REPO}"
NDCTL_REPO_BUILD="${NDCTL_REPO_BUILD:-$NDCTL_REPO}"

JENKINS_URL="${JENKINS_URL:-http://jenkins-server:8080}"
JENKINS_USER="${JENKINS_USER:-jmg}"
JOB="${JOB:-ndctl_regression_public}"
STATE_DIR="${STATE_DIR:-$HOME/.ndctl-regression-watch}"

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
case "${1:-}" in -n|--dry-run) DRY_RUN=1 ;; "" ) ;; *) echo "usage: $0 [-n]" >&2; exit 2 ;; esac

TOKEN="$(tr -d ' \t\r\n' < "$HERE/../api-key.md" 2>/dev/null || true)"
[[ -n "$TOKEN" ]] || { echo "ERROR: no API token in $HERE/../api-key.md" >&2; exit 2; }
mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ---- ref enumeration (git ls-remote; no clone) ----
ls_tags()   { git ls-remote --tags --refs "$1" 'v*' 2>/dev/null | sed 's#.*refs/tags/##'; }
branch_sha(){ git ls-remote "$1" "refs/heads/$2" 2>/dev/null | awk '{print $1}'; }

# kernel tags in the release / rc / stable families with MAJOR.MINOR >= KERNEL_MIN
kernel_tags() {
    ls_tags "$KERNEL_REPO" | awk -v min="$KERNEL_MIN" '
        /^v[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?$/ {
            split(substr($0,2), a, /[.-]/); split(min, m, ".");
            if (a[1]*1000 + a[2] >= m[1]*1000 + m[2]) print
        }'
}
# newest kernel RELEASE tag (vX.Y only, no rc/stable) >= floor - the held-fixed ref
kernel_ref() { kernel_tags | grep -E '^v[0-9]+\.[0-9]+$' | sort -V | tail -1; }

# ndctl release tags vN with N >= NDCTL_MIN
ndctl_tags() { ls_tags "$NDCTL_REPO" | awk -v min="$NDCTL_MIN" '/^v[0-9]+$/ { if (substr($0,2)+0 >= min) print }'; }
ndctl_ref()  { ndctl_tags | sort -V | tail -1; }
# The ndctl SET tested against each kernel (one build): the pending branch + the
# last NDCTL_KEEP release tags (>= NDCTL_MIN). Space-separated, pending first.
ndctl_set()  { printf '%s %s\n' "$NDCTL_PENDING_BRANCH" "$(ndctl_tags | sort -V | tail -n "$NDCTL_KEEP" | tr '\n' ' ')" | xargs; }

# new-since-last-run = set difference vs state file; empty state = baseline (no
# dispatch on first run, just record - avoids a flood of "everything is new").
new_since() {  # $1=current-list  $2=state-file
    if [[ -s "$2" ]]; then comm -23 <(printf '%s\n' "$1" | sort -u) <(sort -u "$2"); fi
}

# ---- Jenkins dispatch ----
CRUMB=""; CFIELD=""
jenkins_crumb() {
    local j; j="$(curl -fsS -u "$JENKINS_USER:$TOKEN" "$JENKINS_URL/crumbIssuer/api/json")" \
        || { echo "ERROR: cannot reach/auth $JENKINS_URL" >&2; exit 2; }
    CRUMB="$(sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p' <<<"$j")"
    CFIELD="$(sed -n 's/.*"crumbRequestField":"\([^"]*\)".*/\1/p' <<<"$j")"
}
trigger() {  # $1=KREF  $2=NREFS (space-separated ndctl set)  [$3=kernel repo; default KERNEL_REPO_BUILD]
    local kref="$1" nrefs="$2" krepo="${3:-$KERNEL_REPO_BUILD}"
    log "  dispatch: KERNEL=$krepo@$kref  NDCTL=$NDCTL_REPO_BUILD@[$nrefs]"
    (( DRY_RUN )) && return 0
    curl -fsS -X POST -u "$JENKINS_USER:$TOKEN" -H "$CFIELD:$CRUMB" \
        --data-urlencode "KERNEL_REPO=$krepo" \
        --data-urlencode "KERNEL_REF=$kref" \
        --data-urlencode "NDCTL_REPO=$NDCTL_REPO_BUILD" \
        --data-urlencode "NDCTL_REFS=$nrefs" \
        "$JENKINS_URL/job/$JOB/buildWithParameters" -o /dev/null \
        || { echo "    WARN: dispatch failed for $kref x [$nrefs]" >&2; return 1; }
}

# ---- gather current state ----
log "polling $KERNEL_REPO (kernels >= v$KERNEL_MIN), $MAINLINE_REPO ($KERNEL_BRANCH) and $NDCTL_REPO (ndctl >= v$NDCTL_MIN)"
cur_ktags="$(kernel_tags)"; K_ref="$(kernel_ref)"
cur_ntags="$(ndctl_tags)";  N_set="$(ndctl_set)"
cur_ksha="$(branch_sha "$MAINLINE_REPO" "$KERNEL_BRANCH")"
cur_psha="$(branch_sha "$NDCTL_REPO"  "$NDCTL_PENDING_BRANCH")"
[[ -n "$K_ref" ]] || { echo "ERROR: no kernel release tag >= v$KERNEL_MIN found" >&2; exit 2; }
[[ -n "$cur_ntags" ]] || { echo "ERROR: no ndctl release tag >= v$NDCTL_MIN found" >&2; exit 2; }
log "held-fixed kernel K_ref=$K_ref ; ndctl set=[$N_set]"

(( DRY_RUN )) || jenkins_crumb
dispatched=0

# new kernel tag(s) -> that kernel x the ndctl set
if (( WATCH_KERNEL_TAGS )); then
    while read -r t; do [[ -n "$t" ]] || continue; log "new kernel tag: $t"; trigger "$t" "$N_set" && dispatched=$((dispatched+1)); done \
        < <(new_since "$cur_ktags" "$STATE_DIR/kernel_tags")
fi
# new ndctl release(s) -> K_ref x the (refreshed) set, once
if (( WATCH_NDCTL_TAGS )); then
    new_nrel="$(new_since "$cur_ntags" "$STATE_DIR/ndctl_tags")"
    if [[ -n "$new_nrel" ]]; then
        log "new ndctl release(s): $(echo $new_nrel | tr '\n' ' ')-> $K_ref x set"
        trigger "$K_ref" "$N_set" && dispatched=$((dispatched+1))
    fi
fi
# bleeding edge: kernel-master x ndctl-pending when a watched tip moved, or (on
# a fully idle run) as a heartbeat so there's always a datapoint. The kernel tip
# is Linus' master (MAINLINE_REPO); the worker's fixture fetches a branch of a
# non-mirror repo from that repo, so the build sees the same sha we polled.
if (( WATCH_TIPS )); then
    kmoved=0; pmoved=0
    [[ "$cur_ksha" != "$(cat "$STATE_DIR/kernel_sha"  2>/dev/null || true)" ]] && kmoved=1
    [[ "$cur_psha" != "$(cat "$STATE_DIR/pending_sha" 2>/dev/null || true)" ]] && pmoved=1
    if (( kmoved || pmoved )); then
        log "tip moved (kernel master=$kmoved / ndctl pending=$pmoved) -> master x pending"
        trigger "$KERNEL_BRANCH" "$NDCTL_PENDING_BRANCH" "$MAINLINE_REPO" && dispatched=$((dispatched+1))
    elif (( HEARTBEAT )) && (( dispatched == 0 )); then
        log "idle -> heartbeat: master x pending"
        trigger "$KERNEL_BRANCH" "$NDCTL_PENDING_BRANCH" "$MAINLINE_REPO" && dispatched=$((dispatched+1))
    fi
fi

# ---- persist state (skip in dry-run) ----
if (( DRY_RUN )); then
    log "dry-run: would dispatch $dispatched run(s); state unchanged"
else
    printf '%s\n' "$cur_ktags" > "$STATE_DIR/kernel_tags"
    printf '%s\n' "$cur_ntags" > "$STATE_DIR/ndctl_tags"
    printf '%s'  "$cur_ksha"   > "$STATE_DIR/kernel_sha"
    printf '%s'  "$cur_psha"   > "$STATE_DIR/pending_sha"
    log "dispatched $dispatched run(s); state updated in $STATE_DIR"
fi
