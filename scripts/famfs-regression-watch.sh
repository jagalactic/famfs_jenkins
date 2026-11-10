#!/usr/bin/env bash
#
# famfs-regression-watch.sh - the WATCHER/dispatcher for famfs_regression_public.
#
# Polls the public kernel repo and the famfs repo with `git ls-remote` (no
# clone), notices new tags / tip movement, and triggers the
# famfs_regression_public Jenkins job (Build with Parameters). Each kernel is
# tested (in ONE build) against a famfs SET = the master branch + the last
# FAMFS_KEEP releases, so a build amortizes the kernel compile across several
# famfs versions and the worker attributes per-ref.
#
# famfs enablement is not upstream yet, so the kernel side has THREE PHASES,
# selected automatically on every run:
#
#   premerge  no kernel tag >= KERNEL_MIN exists and the pull-request ref
#             (PREMERGE_REPO @ PREMERGE_REF, Miklos' fuse-update-7.4 tag) is not
#             yet an ancestor of mainline master -> test that ref nightly.
#   master    the PR ref has been merged but the first v7.4 tag (rc1) is not
#             out yet -> test Linus' master nightly.
#   tags      kernel tags >= KERNEL_MIN exist -> like ndctl-regression-watch:
#               new kernel tag (release / rc / stable)  -> (that kernel) x (famfs SET)
#               new famfs release                        -> (newest kernel release) x (SET)
#               nothing new                              -> (kernel master) x (SET)  [heartbeat]
#
# The merge check needs commits, not just ls-remote: it fetches the PR ref into
# the local kernel mirror's FETCH_HEAD (objects only, no ref -> nothing for the
# mirror's --prune refresh to fight with) and asks merge-base --is-ancestor
# against the mirror's master (the linux-stable tree tracks mainline on master).
#
# Detection is by set-difference against a small state dir, so each ref is
# dispatched once; the first run only baselines the tag lists (no tag flood)
# but still sends the nightly tip build. Idempotent, non-interactive -> run
# from a systemd timer. Reads the Jenkins API token from ./api-key.md.
#
# ============================ EDIT WHAT GETS TESTED ==========================
KERNEL_REPO="${KERNEL_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
KERNEL_MIN="${KERNEL_MIN:-7.4}"       # only kernels >= this MAJOR.MINOR (first with famfs fuse enablement)
KERNEL_BRANCH="${KERNEL_BRANCH:-master}"  # mainline tip, taken from MAINLINE_REPO (Linus' tree)
MAINLINE_REPO="${MAINLINE_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git}"  # Linus' tree: the merge check + master/heartbeat builds (linux-stable's master lags it)
PREMERGE_REPO="${PREMERGE_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/mszeredi/fuse.git}"
PREMERGE_REF="${PREMERGE_REF:-fuse-update-7.4}"   # Miklos' pull-request tag (or branch) carrying famfs until merged
FAMFS_REPO="${FAMFS_REPO:-file:///home/jenkins/git/famfs.git}"  # watched AND built (thing1 mirror; what smoke_local tests)
FAMFS_BRANCH="${FAMFS_BRANCH:-master}"
FAMFS_MIN="${FAMFS_MIN:-}"            # only famfs releases vX.Y >= this (e.g. 1.0); EMPTY = no releases yet (master only)
FAMFS_KEEP="${FAMFS_KEEP:-2}"         # test the last N famfs releases (>= FAMFS_MIN) against each kernel, alongside master
MIRROR="${MIRROR:-/home/jenkins/git/linux-mirror.git}"  # local bare kernel mirror (merge check); refreshed by kernel-mirror-update.timer

WATCH_KERNEL_TAGS="${WATCH_KERNEL_TAGS:-1}"   # tags phase: dispatch on new kernel release/rc/stable tags
WATCH_FAMFS_TAGS="${WATCH_FAMFS_TAGS:-1}"     # dispatch on new famfs releases
HEARTBEAT="${HEARTBEAT:-1}"                   # nightly tip build when nothing else was dispatched
# ============================================================================

# Which repo the *worker* should clone for the public kernel (what is handed to
# Jenkins). Usually the watched repo; override to a local path if needed.
KERNEL_REPO_BUILD="${KERNEL_REPO_BUILD:-$KERNEL_REPO}"

JENKINS_URL="${JENKINS_URL:-http://jenkins-server:8080}"
JENKINS_USER="${JENKINS_USER:-jmg}"
JOB="${JOB:-famfs_regression_public}"
STATE_DIR="${STATE_DIR:-$HOME/.famfs-regression-watch}"

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
# sha of a ref that may be a tag or a branch (tag preferred); empty if absent
any_sha()   { git ls-remote "$1" "refs/tags/$2" "refs/heads/$2" 2>/dev/null | awk '{print $1}' | head -1; }

# kernel tags in the release / rc / stable families with MAJOR.MINOR >= KERNEL_MIN
kernel_tags() {
    ls_tags "$KERNEL_REPO" | awk -v min="$KERNEL_MIN" '
        /^v[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?$/ {
            split(substr($0,2), a, /[.-]/); split(min, m, ".");
            if (a[1]*1000 + a[2] >= m[1]*1000 + m[2]) print
        }'
}
# newest kernel RELEASE tag (vX.Y only, no rc/stable) >= floor - the held-fixed ref
kernel_release_ref() { kernel_tags | grep -E '^v[0-9]+\.[0-9]+$' | sort -V | tail -1; }

# famfs release tags vX.Y[.Z] with X.Y >= FAMFS_MIN (none while FAMFS_MIN is empty)
famfs_tags() {
    [[ -n "$FAMFS_MIN" ]] || return 0
    ls_tags "$FAMFS_REPO" | awk -v min="$FAMFS_MIN" '
        /^v[0-9]+\.[0-9]+(\.[0-9]+)?$/ {
            split(substr($0,2), a, /\./); split(min, m, ".");
            if (a[1]*1000 + a[2] >= m[1]*1000 + m[2]) print
        }'
}
# The famfs SET tested against each kernel (one build): master + the last
# FAMFS_KEEP release tags (>= FAMFS_MIN). Space-separated, master first.
famfs_set() { printf '%s %s\n' "$FAMFS_BRANCH" "$(famfs_tags | sort -V | tail -n "$FAMFS_KEEP" | tr '\n' ' ')" | xargs; }

# Has the pull-request ref landed in mainline? Needs commits: fetch Linus'
# master and then the PR ref into the mirror (FETCH_HEAD only, no refs created)
# and test ancestry. Linus' tree, not the mirror's own (linux-stable) master,
# which trails it by hours to days. Unknown (no mirror / fetch failed) ->
# treated as not merged.
premerge_merged() {
    [[ -d "$MIRROR" ]] || { log "  merge check: no mirror at $MIRROR; assuming not merged"; return 1; }
    local spec mainline
    git -C "$MIRROR" fetch -q --no-tags "$MAINLINE_REPO" "refs/heads/$KERNEL_BRANCH" 2>/dev/null \
        || { log "  merge check: cannot fetch $MAINLINE_REPO $KERNEL_BRANCH; assuming not merged"; return 1; }
    mainline="$(git -C "$MIRROR" rev-parse 'FETCH_HEAD^{commit}')"
    for spec in "refs/tags/$PREMERGE_REF" "refs/heads/$PREMERGE_REF"; do
        if git -C "$MIRROR" fetch -q --no-tags "$PREMERGE_REPO" "$spec" 2>/dev/null; then
            git -C "$MIRROR" merge-base --is-ancestor 'FETCH_HEAD^{commit}' "$mainline"
            return $?
        fi
    done
    log "  merge check: $PREMERGE_REF not found in $PREMERGE_REPO; assuming not merged"
    return 1
}

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
trigger() {  # $1=KERNEL_REPO  $2=KERNEL_REF  $3=FAMFS_REFS (space-separated famfs set)
    local krepo="$1" kref="$2" frefs="$3"
    log "  dispatch: KERNEL=$krepo@$kref  FAMFS=$FAMFS_REPO@[$frefs]"
    (( DRY_RUN )) && return 0
    curl -fsS -X POST -u "$JENKINS_USER:$TOKEN" -H "$CFIELD:$CRUMB" \
        --data-urlencode "KERNEL_REPO=$krepo" \
        --data-urlencode "KERNEL_REF=$kref" \
        --data-urlencode "FAMFS_REPO=$FAMFS_REPO" \
        --data-urlencode "FAMFS_REFS=$frefs" \
        "$JENKINS_URL/job/$JOB/buildWithParameters" -o /dev/null \
        || { echo "    WARN: dispatch failed for $kref x [$frefs]" >&2; return 1; }
}

# ---- gather current state ----
log "polling $KERNEL_REPO (kernels >= v$KERNEL_MIN), $MAINLINE_REPO @ $KERNEL_BRANCH, $PREMERGE_REPO @ $PREMERGE_REF, $FAMFS_REPO (famfs >= v${FAMFS_MIN:-none})"
cur_ktags="$(kernel_tags)"
cur_ftags="$(famfs_tags)";  F_set="$(famfs_set)"
cur_ksha="$(branch_sha "$MAINLINE_REPO" "$KERNEL_BRANCH")"
cur_fsha="$(branch_sha "$FAMFS_REPO"  "$FAMFS_BRANCH")"
cur_psha="$(any_sha "$PREMERGE_REPO" "$PREMERGE_REF")"
[[ -n "$cur_ksha" ]] || { echo "ERROR: cannot resolve $MAINLINE_REPO $KERNEL_BRANCH" >&2; exit 2; }
[[ -n "$cur_fsha" ]] || { echo "ERROR: cannot resolve $FAMFS_REPO $FAMFS_BRANCH" >&2; exit 2; }

# ---- phase ----
if [[ -n "$cur_ktags" ]]; then
    phase=tags
elif premerge_merged; then
    phase=master
else
    phase=premerge
fi
prev_phase="$(cat "$STATE_DIR/phase" 2>/dev/null || echo none)"
[[ "$phase" == "$prev_phase" ]] || log "phase: $prev_phase -> $phase"
log "phase=$phase ; famfs set=[$F_set]"

# The "tip" kernel this phase tests nightly, and the kernel a new famfs release
# is tested against.
case "$phase" in
    premerge) tip_repo="$PREMERGE_REPO";     tip_ref="$PREMERGE_REF" ;;
    *)        tip_repo="$MAINLINE_REPO";     tip_ref="$KERNEL_BRANCH" ;;   # Linus' master, not stable's
esac
K_ref="$(kernel_release_ref || true)"
if [[ -n "$K_ref" ]]; then rel_repo="$KERNEL_REPO_BUILD"; rel_ref="$K_ref"; else rel_repo="$tip_repo"; rel_ref="$tip_ref"; fi

(( DRY_RUN )) || jenkins_crumb
dispatched=0

# new kernel tag(s) -> that kernel x the famfs set (tags phase only; the lists
# are empty before the first v7.4 tag anyway)
if (( WATCH_KERNEL_TAGS )) && [[ "$phase" == tags ]]; then
    while read -r t; do [[ -n "$t" ]] || continue; log "new kernel tag: $t"; trigger "$KERNEL_REPO_BUILD" "$t" "$F_set" && dispatched=$((dispatched+1)); done \
        < <(new_since "$cur_ktags" "$STATE_DIR/kernel_tags")
fi
# new famfs release(s) -> newest kernel release (or this phase's tip) x the refreshed set, once
if (( WATCH_FAMFS_TAGS )); then
    new_frel="$(new_since "$cur_ftags" "$STATE_DIR/famfs_tags")"
    if [[ -n "$new_frel" ]]; then
        log "new famfs release(s): $(echo $new_frel | tr '\n' ' ')-> $rel_ref x set"
        trigger "$rel_repo" "$rel_ref" "$F_set" && dispatched=$((dispatched+1))
    fi
fi
# nightly tip build: Miklos' PR ref (premerge) / mainline master (master, tags)
# x the famfs set, whenever nothing else was dispatched this run.
if (( HEARTBEAT )) && (( dispatched == 0 )); then
    log "nightly: $tip_ref x set (phase $phase)"
    trigger "$tip_repo" "$tip_ref" "$F_set" && dispatched=$((dispatched+1))
fi

# ---- persist state (skip in dry-run) ----
if (( DRY_RUN )); then
    log "dry-run: would dispatch $dispatched run(s); state unchanged"
else
    printf '%s\n' "$cur_ktags" > "$STATE_DIR/kernel_tags"
    printf '%s\n' "$cur_ftags" > "$STATE_DIR/famfs_tags"
    printf '%s'  "$cur_ksha"   > "$STATE_DIR/kernel_sha"
    printf '%s'  "$cur_fsha"   > "$STATE_DIR/famfs_sha"
    printf '%s'  "$cur_psha"   > "$STATE_DIR/premerge_sha"
    printf '%s'  "$phase"      > "$STATE_DIR/phase"
    log "dispatched $dispatched run(s); state updated in $STATE_DIR"
fi
