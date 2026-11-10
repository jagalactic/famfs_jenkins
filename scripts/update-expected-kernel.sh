#!/usr/bin/env bash
#
# update-expected-kernel.sh - point every "expected kernel" pin in this repo at
# the kernel an agent is now running, in one shot.
#
# Each Jenkins agent VM is pinned to a specific kernel version in several files.
# After you install/recycle a kernel on an agent, run this to update them all:
#
#   chk_kernels.sh         check_kernel <node> "<kernel>"            (per node)
#   check_kernels.groovy   check_kernel('<node>', '<kernel>')        (per node)
#   *.groovy pipelines     buildOnKernel(.., '.. && <label>', '<kernel>', ..)
#                          (per label: smoke/sanitize/valgrind/coverage/fail)
#
# chk_kernels.sh is the source of truth fix_kernels.sh reads, so its node list
# drives everything here.
#
# Usage:
#   ./update-expected-kernel.sh [-n] <agent> [kernel]
#
#   <agent>   a node name (jenkins-dualv1-0) OR a pipeline label (dual_v1).
#             Either way the whole label group is updated together, since a
#             label is a pool of identical agents on the same kernel.
#   [kernel]  the new kernel string. If omitted, the script ssh'es the agent
#             and reads `uname -r` (so it expects whatever is actually running).
#
# Options:
#   -n, --dry-run     show what would change; write nothing
#   -k, --kernel STR  new kernel string (same as the positional [kernel])
#   -l, --list        list known agents/labels (from chk_kernels.sh) and exit
#   -h, --help        this help
#
# Environment:
#   SSH_USER   ssh user used to read `uname -r` (default: your login user)
#
# Examples:
#   ./update-expected-kernel.sh jenkins-dualv1-0          # ssh, use uname -r
#   ./update-expected-kernel.sh dual_v1 7.1.0-rc7-famfs_dual+
#   ./update-expected-kernel.sh -n dual_v1                # preview only
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHK="${SCRIPT_DIR}/chk_kernels.sh"
CKG="${SCRIPT_DIR}/../groovy/check_kernels.groovy"

DRY=0
NEWK=""
AGENT=""
SSH_USER="${SSH_USER:-}"

die() { echo "error: $*" >&2; exit 1; }

[[ -f "$CHK" ]] || die "cannot find $CHK (source of truth for node->kernel)"

# node "jenkins-dualv1-0" -> pipeline label "dual_v1"; "jenkins-kernel43-1" -> "kernel43";
# "jenkins-fuse-extmap0" -> "extmap" (no dash before the instance number there)
derive_label() {
    local b="${1#jenkins-}"   # dualv1-0 / fuse-extmap0
    if [[ $b =~ ^fuse-extmap[0-9]*$ ]]; then
        echo extmap; return
    fi
    b="${b%-*}"               # dualv1   (strip trailing -N)
    if [[ $b =~ ^(fuse|dual)v([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}_v${BASH_REMATCH[2]}"
    else
        echo "$b"             # kernel42 / kernel43 / anything else: as-is
    fi
}

# all active (uncommented) nodes, in file order
mapfile -t ALL_NODES < <(awk '$1=="check_kernel"{print $2}' "$CHK")

list_known() {
    local seen=" " n l
    echo "Known agents (node -> label), from chk_kernels.sh:"
    for n in "${ALL_NODES[@]}"; do
        l="$(derive_label "$n")"
        printf '  %-22s %s\n' "$n" "$l"
    done
    echo
    echo "Labels:"
    for n in "${ALL_NODES[@]}"; do
        l="$(derive_label "$n")"
        [[ $seen == *" $l "* ]] && continue
        seen+="$l "
        printf '  %s\n' "$l"
    done
}

# --- arg parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY=1; shift ;;
        -k|--kernel)  NEWK="${2:-}"; shift 2 ;;
        -l|--list)    list_known; exit 0 ;;
        -h|--help)    sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^set -u/d'; exit 0 ;;
        -*)           die "unknown option: $1 (try --help)" ;;
        *)
            if [[ -z $AGENT ]]; then AGENT="$1"
            elif [[ -z $NEWK ]]; then NEWK="$1"
            else die "too many arguments: $1"; fi
            shift ;;
    esac
done

[[ -n $AGENT ]] || { echo "Usage: $0 [-n] <agent> [kernel]   (see --help, --list)" >&2; exit 1; }

# --- resolve agent -> label + node set + a representative node to ssh ---
REPNODE=""; LABEL=""
if printf '%s\n' "${ALL_NODES[@]}" | grep -Fxq -- "$AGENT"; then
    REPNODE="$AGENT"; LABEL="$(derive_label "$AGENT")"
else
    LABEL="$AGENT"
fi

NODES=()
for n in "${ALL_NODES[@]}"; do
    [[ "$(derive_label "$n")" == "$LABEL" ]] && NODES+=("$n")
done
((${#NODES[@]})) || { echo "error: '$AGENT' is not a known node or label." >&2; echo >&2; list_known >&2; exit 1; }
[[ -n $REPNODE ]] || REPNODE="${NODES[0]}"

# --- determine the new kernel ---
if [[ -z $NEWK ]]; then
    echo "Reading running kernel from ${REPNODE} (uname -r)..."
    NEWK="$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
              "${SSH_USER:+${SSH_USER}@}${REPNODE}" uname -r 2>/dev/null)" || true
    [[ -n $NEWK ]] || die "could not ssh ${REPNODE} to read 'uname -r'. Pass the kernel explicitly: $0 $AGENT <kernel>"
fi
[[ $NEWK == *[[:space:]]* ]] && die "kernel string contains whitespace: '$NEWK'"

echo "Label : $LABEL"
echo "Nodes : ${NODES[*]}"
echo "Kernel: $NEWK"
((DRY)) && echo "(dry-run: no files will be written)"
echo

CHANGES=0
report() {  # file key current
    local file="$1" key="$2" cur="$3"
    if [[ -z $cur ]]; then
        printf '  %-22s %-20s no match (skipped)\n' "$file" "$key"
    elif [[ $cur == "$NEWK" ]]; then
        printf '  %-22s %-20s already %s\n' "$file" "$key" "$NEWK"
    else
        printf '  %-22s %-20s %s -> %s\n' "$file" "$key" "$cur" "$NEWK"
        CHANGES=$((CHANGES+1))
    fi
}

# --- per-node files: chk_kernels.sh, check_kernels.groovy ---
for node in "${NODES[@]}"; do
    cur="$(awk -v n="$node" '$1=="check_kernel"&&$2==n{gsub(/"/,"",$3);print $3;exit}' "$CHK")"
    report "chk_kernels.sh" "$node" "$cur"
    if [[ -n $cur && $cur != "$NEWK" && $DRY -eq 0 ]]; then
        NODE="$node" NEWK="$NEWK" perl -i -pe \
            's{^(\s*check_kernel\s+\Q$ENV{NODE}\E\s+)"[^"]*"}{$1"$ENV{NEWK}"}' "$CHK"
    fi

    cur="$(NODE="$node" perl -ne \
        'print "$1" if /check_kernel\(\x27\Q$ENV{NODE}\E\x27,\s*\x27([^\x27]*)\x27/' "$CKG" 2>/dev/null)"
    report "check_kernels.groovy" "$node" "$cur"
    if [[ -n $cur && $cur != "$NEWK" && $DRY -eq 0 ]]; then
        NODE="$node" NEWK="$NEWK" perl -i -pe \
            's{(check_kernel\(\x27\Q$ENV{NODE}\E\x27,\s*)\x27[^\x27]*\x27}{$1\x27$ENV{NEWK}\x27}' "$CKG"
    fi
done

# --- per-label pipeline files: buildOnKernel(.., '.. && <label>', '<kernel>', ..) ---
# Only files that actually call buildOnKernel, and only the 4th-arg kernel token
# (anchored to start with a digit, so label-expression lists are never touched).
mapfile -t PIPES < <(
    for f in "$SCRIPT_DIR"/../groovy/*.groovy; do
        grep -q 'buildOnKernel(' "$f" 2>/dev/null \
            && grep -qE "&& ${LABEL}'" "$f" 2>/dev/null && echo "$f"
    done | sort
)
for f in "${PIPES[@]:-}"; do
    [[ -n ${f:-} ]] || continue
    cur="$(LABEL="$LABEL" perl -0777 -ne \
        'print "$1" if /&&\s*\Q$ENV{LABEL}\E\x27\s*,\s*\x27(\d[^\x27]*)\x27/' "$f" 2>/dev/null)"
    report "$(basename "$f")" "$LABEL" "$cur"
    if [[ -n $cur && $cur != "$NEWK" && $DRY -eq 0 ]]; then
        LABEL="$LABEL" NEWK="$NEWK" perl -0777 -i -pe \
            's{(&&\s*\Q$ENV{LABEL}\E\x27\s*,\s*)\x27\d[^\x27]*\x27}{$1\x27$ENV{NEWK}\x27}g' "$f"
    fi
done

echo
if ((DRY)); then
    echo "Dry-run: ${CHANGES} file(s) would change. Re-run without -n to apply."
elif ((CHANGES)); then
    echo "Updated ${CHANGES} file(s). Review with: jj diff"
else
    echo "Nothing to do: everything already pinned to ${NEWK}."
fi
