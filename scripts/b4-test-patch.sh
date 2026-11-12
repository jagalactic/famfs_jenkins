#!/usr/bin/env bash
#
# b4-test-patch.sh - test a lore patch/series against the famfs and dax CI.
#
# Pulls one or more series from lore with b4, applies them on a base kernel
# (the series' own base-commit when it has one, else Linus' current master),
# publishes the result as a branch of a local bare repo that the run_qemu
# workers can fetch, and dispatches famfs_dbg_regression_public (famfs over fuse
# on nfit devdax) and/or ndctl_regression_public (ndctl + dax unit tests) at
# that branch. Jenkins shows the runs as "k:b4/<name> [...]".
#
# Usage:
#   b4-test-patch.sh [options] <msgid-or-lore-url> [<msgid-or-lore-url>...]
#
#   Several series are applied in order on the same branch (a prerequisite
#   series first, then the one under test). A lore URL is reduced to its
#   message-id; b4 then fetches the newest revision of that series.
#
# Options:
#   -n, --dry-run        fetch + apply in the work tree, show the result, but
#                        publish nothing and dispatch nothing
#   -j, --jobs LIST      which workers: famfs, ndctl, or famfs,ndctl (default)
#   -b, --base REF       base to apply on: a tag (v7.4-rc1), sha, or a branch
#                        of Linus' tree. Default: the series' base-commit if
#                        b4 reports one that we have, else Linus' master
#   -B, --baseline       also dispatch the same job(s) at the UNPATCHED base
#                        (branch b4/<name>-base) for a same-day comparison
#   -N, --name NAME      branch suffix -> b4/NAME (default: derived from the
#                        b4 mbox name, e.g. 20261106_ziy_mm_truncate_unmap_dax)
#   -f, --famfs-refs S   FAMFS_REFS for the famfs job (default: master)
#   -r, --ndctl-refs S   NDCTL_REFS for the ndctl job (default: "pending v85")
#   --b4-args "ARGS"     extra arguments for `b4 am` (e.g. "-P 2-4", "-v 3")
#   -h, --help
#
# Environment:
#   PATCH_REPO     bare repo the workers fetch from
#                  (default /home/jenkins/git/linux-patches.git; the jenkins
#                  user must list it in its git safe.directory, see docs)
#   WORK           work tree the series is applied in (default ~/.b4-test-patch/work)
#   MIRROR         local kernel mirror used as an object store (alternates)
#   MAINLINE_REPO  Linus' tree (base for everything, fetched each run)
#   JENKINS_URL, JENKINS_USER, FAMFS_REPO, NDCTL_REPO
#   FAMFS_JOBS     famfs worker job(s) to dispatch, space-separated (default
#                  famfs_dbg_regression_public; add famfs_rel_regression_public
#                  to also test the release build of famfs)
#
# Exit: 0 dispatched (or dry-run ok); 1 usage; 2 setup/fetch error;
#       3 the series does not apply; 4 a dispatch failed.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PATCH_REPO="${PATCH_REPO:-/home/jenkins/git/linux-patches.git}"
STATE_DIR="${STATE_DIR:-$HOME/.b4-test-patch}"
WORK="${WORK:-$STATE_DIR/work}"
MIRROR="${MIRROR:-/home/jenkins/git/linux-mirror.git}"
MAINLINE_REPO="${MAINLINE_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git}"

JENKINS_URL="${JENKINS_URL:-http://jenkins-server:8080}"
JENKINS_USER="${JENKINS_USER:-jmg}"
FAMFS_REPO="${FAMFS_REPO:-file:///home/jenkins/git/famfs.git}"
NDCTL_REPO="${NDCTL_REPO:-https://github.com/pmem/ndctl.git}"
FAMFS_JOBS="${FAMFS_JOBS:-famfs_dbg_regression_public}"

DRY_RUN=0; JOBS="famfs,ndctl"; BASE=""; BASELINE=0; NAME=""
FAMFS_REFS="master"; NDCTL_REFS="pending v85"; B4_ARGS=""
MSGIDS=()

die() { echo "error: $*" >&2; exit "${2:-2}"; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^set -euo/d'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)    DRY_RUN=1; shift ;;
        -j|--jobs)       JOBS="${2:-}"; shift 2 ;;
        -b|--base)       BASE="${2:-}"; shift 2 ;;
        -B|--baseline)   BASELINE=1; shift ;;
        -N|--name)       NAME="${2:-}"; shift 2 ;;
        -f|--famfs-refs) FAMFS_REFS="${2:-}"; shift 2 ;;
        -r|--ndctl-refs) NDCTL_REFS="${2:-}"; shift 2 ;;
        --b4-args)       B4_ARGS="${2:-}"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        -*)              die "unknown option: $1 (try --help)" 1 ;;
        *)               MSGIDS+=("$1"); shift ;;
    esac
done
((${#MSGIDS[@]})) || { usage >&2; exit 1; }

RUN_FAMFS=0; RUN_NDCTL=0
IFS=, read -ra _jobs <<<"$JOBS"
for j in "${_jobs[@]}"; do
    case "$j" in
        famfs) RUN_FAMFS=1 ;;
        ndctl|dax) RUN_NDCTL=1 ;;
        *) die "unknown job '$j' (famfs, ndctl)" 1 ;;
    esac
done

command -v b4 >/dev/null || die "b4 not installed"
[[ -d "$MIRROR" ]] || die "kernel mirror $MIRROR not found"

# "https://lore.kernel.org/all/<msgid>/" or "<msgid>" or "<msgid>" -> msgid
norm_msgid() {
    local m="$1"
    m="${m#<}"; m="${m%>}"
    if [[ $m == http*://* ]]; then
        m="${m%/}"; m="${m%/T/*}"; m="${m%/t/*}"; m="${m%/raw}"
        m="${m##*/}"
    fi
    printf '%s' "$m"
}

# ---- repos: bare publish repo (object store = the mirror) + work tree ----
ensure_repos() {
    if [[ ! -d "$PATCH_REPO" ]]; then
        log "creating $PATCH_REPO (bare, objects shared with $MIRROR)"
        git clone -q --bare --reference "$MIRROR" "$MAINLINE_REPO" "$PATCH_REPO"
        git -C "$PATCH_REPO" config uploadpack.allowReachableSHA1InWant true
    fi
    log "refreshing mainline + tags in $PATCH_REPO"
    git -C "$PATCH_REPO" fetch -q "$MAINLINE_REPO" "+refs/heads/master:refs/heads/mainline" \
        || die "cannot fetch $MAINLINE_REPO"
    git -C "$PATCH_REPO" fetch -q --tags "$MIRROR" 2>/dev/null || true   # stable .Z tags, cheap (alternates)
    if [[ ! -d "$WORK/.git" ]]; then
        log "creating work tree $WORK (one-time kernel checkout)"
        mkdir -p "$(dirname "$WORK")"
        git clone -q --shared "$PATCH_REPO" "$WORK"
    fi
    git -C "$WORK" fetch -q --tags origin "+refs/heads/*:refs/remotes/origin/*"
}

resolve_base() {   # $1=ref -> sha on stdout, or fail
    local r="$1" sha
    sha="$(git -C "$WORK" rev-parse -q --verify "$r^{commit}" 2>/dev/null)" && { echo "$sha"; return 0; }
    sha="$(git -C "$WORK" rev-parse -q --verify "refs/remotes/origin/$r^{commit}" 2>/dev/null)" && { echo "$sha"; return 0; }
    # a branch of Linus' tree we don't track, or a sha the mirror lacks
    if git -C "$WORK" fetch -q "$MAINLINE_REPO" "$r" 2>/dev/null; then
        git -C "$WORK" rev-parse FETCH_HEAD; return 0
    fi
    return 1
}

ensure_repos
MAINLINE_SHA="$(git -C "$WORK" rev-parse refs/remotes/origin/mainline)"

# ---- b4: fetch each series into an mbox, remember any base-commit ----
RUNTAG="$(date +%Y%m%d-%H%M%S)"
MBOXDIR="$STATE_DIR/mbox/$RUNTAG"; mkdir -p "$MBOXDIR"
MBXS=(); B4_BASE=""
# shellcheck disable=SC2206
_b4args=($B4_ARGS)
for raw in "${MSGIDS[@]}"; do
    mid="$(norm_msgid "$raw")"
    log "b4 am $mid"
    out="$(cd "$WORK" && b4 am -o "$MBOXDIR" -l "${_b4args[@]}" "$mid" 2>&1)" \
        || { echo "$out" >&2; die "b4 am failed for $mid"; }
    echo "$out" | sed 's/^/    /'
    mbx="$(ls -t "$MBOXDIR"/*.mbx 2>/dev/null | head -1)"
    [[ -n $mbx && ! " ${MBXS[*]-} " == *" $mbx "* ]] || die "b4 produced no new mbox for $mid"
    MBXS+=("$mbx")
    # "Base: <sha>" from b4 (only series that carry base-commit have it);
    # the LAST series' base wins (it is the one under test).
    b="$(echo "$out" | grep -E '^ *Base: ' | grep -oE '\b[0-9a-f]{12,40}\b' | tail -1 || true)"
    [[ -n $b ]] && B4_BASE="$b"
done

# ---- choose the base ----
BASE_HOW=""
if [[ -n $BASE ]]; then
    BASE_SHA="$(resolve_base "$BASE")" || die "cannot resolve --base '$BASE' (tag/sha/branch of Linus' tree)"
    BASE_HOW="--base $BASE"
elif [[ -n $B4_BASE ]] && BASE_SHA="$(resolve_base "$B4_BASE")" \
     && git -C "$WORK" merge-base --is-ancestor "$BASE_SHA" "$MAINLINE_SHA"; then
    # the series' own base, but only when it is mainline: kernel.org serves
    # any sha from its shared object store, so an mm-unstable / linux-next
    # base-commit resolves fine yet is not a kernel we want to test famfs on.
    BASE_HOW="series base-commit"
else
    [[ -n $B4_BASE ]] && log "series base-commit $B4_BASE is not in Linus' tree (mm-unstable/linux-next?); using Linus' master instead"
    BASE_SHA="$MAINLINE_SHA"; BASE_HOW="Linus' master"
fi
if [[ -n $BASE ]] && ! git -C "$WORK" merge-base --is-ancestor "$BASE_SHA" "$MAINLINE_SHA"; then
    log "note: --base $BASE is not in Linus' master"
fi

# ---- name ----
if [[ -z $NAME ]]; then
    NAME="$(basename "${MBXS[-1]}" .mbx)"
    NAME="$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._\n-' '_' | sed 's/__*/_/g; s/^_//; s/_$//' | cut -c1-72)"
fi
[[ $NAME =~ ^[A-Za-z0-9._-]+$ ]] || die "bad branch name '$NAME'"
BRANCH="b4/$NAME"

# ---- apply ----
log "applying ${#MBXS[@]} series on $BASE_HOW ($(git -C "$WORK" log -1 --format='%h %s' "$BASE_SHA"))"
git -C "$WORK" am --abort 2>/dev/null || true
git -C "$WORK" checkout -q -f --detach "$BASE_SHA"
git -C "$WORK" clean -qfdx
for mbx in "${MBXS[@]}"; do
    if ! git -C "$WORK" am -3 -q "$mbx"; then
        echo "---- git am failed; first conflicting hunk(s):" >&2
        git -C "$WORK" diff --diff-filter=U 2>/dev/null | head -60 >&2
        git -C "$WORK" am --abort 2>/dev/null || true
        die "series $(basename "$mbx") does not apply on $BASE_HOW ($BASE_SHA)" 3
    fi
done
HEAD_SHA="$(git -C "$WORK" rev-parse HEAD)"
NPATCH="$(git -C "$WORK" rev-list --count "$BASE_SHA..HEAD")"
echo
echo "branch : $BRANCH"
echo "base   : $BASE_SHA ($BASE_HOW)"
echo "head   : $HEAD_SHA  ($NPATCH patch(es))"
git -C "$WORK" log --reverse --format='         %h %s' "$BASE_SHA..HEAD"
echo "touches:"
git -C "$WORK" diff --stat=100 "$BASE_SHA..HEAD" | sed 's/^/         /'
echo

if (( DRY_RUN )); then
    log "dry-run: not publishing $BRANCH to $PATCH_REPO, not dispatching"
    exit 0
fi

# ---- publish ----
git -C "$WORK" push -q -f origin "HEAD:refs/heads/$BRANCH"
log "published $BRANCH -> $PATCH_REPO"
if (( BASELINE )); then
    git -C "$WORK" push -q -f origin "$BASE_SHA:refs/heads/$BRANCH-base"
    log "published $BRANCH-base (unpatched base) -> $PATCH_REPO"
fi

# ---- dispatch ----
TOKEN="$(tr -d ' \t\r\n' < "$REPO_ROOT/api-key.md" 2>/dev/null)" || die "no api-key.md in $REPO_ROOT"
cj="$(curl -fsS -u "$JENKINS_USER:$TOKEN" "$JENKINS_URL/crumbIssuer/api/json")" || die "cannot reach/auth $JENKINS_URL"
CRUMB="$(sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p' <<<"$cj")"
CFIELD="$(sed -n 's/.*"crumbRequestField":"\([^"]*\)".*/\1/p' <<<"$cj")"
FAILS=0
dispatch() {  # $1=job $2=kernel ref, then extra --data-urlencode args
    local job="$1" kref="$2"; shift 2
    local loc
    loc="$(curl -fsS -o /dev/null -D - -X POST -u "$JENKINS_USER:$TOKEN" -H "$CFIELD:$CRUMB" \
            --data-urlencode "KERNEL_REPO=file://$PATCH_REPO" \
            --data-urlencode "KERNEL_REF=$kref" "$@" \
            "$JENKINS_URL/job/$job/buildWithParameters" | sed -n 's/^[Ll]ocation: *//p' | tr -d '\r')" \
        || { echo "    WARN: dispatch failed: $job k:$kref" >&2; FAILS=$((FAILS+1)); return 0; }
    log "queued $job  k:$kref  (${loc:-$JENKINS_URL/job/$job/})"
}
KREFS=("$BRANCH"); (( BASELINE )) && KREFS+=("$BRANCH-base")
for kref in "${KREFS[@]}"; do
    if (( RUN_FAMFS )); then
        for fjob in $FAMFS_JOBS; do
            dispatch "$fjob" "$kref" \
                --data-urlencode "FAMFS_REPO=$FAMFS_REPO" --data-urlencode "FAMFS_REFS=$FAMFS_REFS"
        done
    fi
    (( RUN_NDCTL )) && dispatch ndctl_regression_public "$kref" \
        --data-urlencode "NDCTL_REPO=$NDCTL_REPO" --data-urlencode "NDCTL_REFS=$NDCTL_REFS"
done
echo
echo "watch:   $(for j in $FAMFS_JOBS; do printf '%s/job/%s/   ' "$JENKINS_URL" "$j"; done)$JENKINS_URL/job/ndctl_regression_public/"
echo "         (display name k:$BRANCH [...]; both run on thing1's single run_qemu executor, in queue order)"
(( FAILS == 0 )) || exit 4
