#!/usr/bin/env bash
#
# fix_kernels.sh - ensure every Jenkins agent VM is running its expected kernel.
#
# Why this exists:
#   An unexpected reboot (power outage, host crash) can land an agent on the
#   wrong GRUB default kernel, which makes the famfs tests fail. This script
#   re-pins the correct kernel as the PERSISTENT default (grubby --set-default)
#   and reboots any agent that is currently on the wrong kernel, then re-checks.
#
#   It is the automated counterpart to chk_kernels.sh: chk_kernels.sh reports,
#   fix_kernels.sh remediates. The host->kernel mapping is read from
#   chk_kernels.sh so there is a single source of truth.
#
# Safe to run anytime: agents already on the right kernel are left untouched.
#
# Usage:
#   ./fix_kernels.sh            # remediate any agent on the wrong kernel
#   ./fix_kernels.sh -n         # dry-run: report what it WOULD do, change nothing
#
# Environment:
#   SSH_USER       ssh user for privileged ops (default: root)
#   REACH_TIMEOUT  seconds to wait for an agent to become reachable (default: 300)
#   BOOT_TIMEOUT   seconds to wait for an agent to come back after reboot (default: 420)
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHK="${SCRIPT_DIR}/chk_kernels.sh"

SSH_USER="${SSH_USER:-root}"
REACH_TIMEOUT="${REACH_TIMEOUT:-300}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-420}"
DRY_RUN=0
[[ "${1:-}" == "-n" || "${1:-}" == "--dry-run" ]] && DRY_RUN=1

SSH_OPTS=(-n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

if [[ ! -f "$CHK" ]]; then
    echo "ERROR: cannot find $CHK (source of expected kernels)" >&2
    exit 2
fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Wait until the agent answers ssh, or until $2 seconds elapse. Returns 0/1.
wait_reachable() {
    local host="$1" timeout="$2" waited=0
    while ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" true 2>/dev/null; do
        (( waited >= timeout )) && return 1
        sleep 5
        (( waited += 5 ))
    done
    return 0
}

FAILED=()
FIXED=()

# Read "check_kernel <host> "<kernel>"" lines; commented (#) lines are skipped.
while read -r _kw host kern _rest; do
    # strip surrounding quotes from the kernel string
    kern="${kern%\"}"; kern="${kern#\"}"
    [[ -z "${host:-}" || -z "${kern:-}" ]] && continue

    echo "==================== ${host} ===================="
    if ! wait_reachable "$host" "$REACH_TIMEOUT"; then
        log "${host}: UNREACHABLE after ${REACH_TIMEOUT}s - skipping"
        FAILED+=("$host (unreachable)")
        continue
    fi

    actual="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" uname -r 2>/dev/null)"
    if [[ "$actual" == "$kern" ]]; then
        log "${host}: OK (kernel=${kern})"
        continue
    fi

    log "${host}: WRONG kernel: running '${actual}', expected '${kern}'"

    vmlinuz="/boot/vmlinuz-${kern}"
    if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "test -f '${vmlinuz}'" 2>/dev/null; then
        log "${host}: target ${vmlinuz} NOT INSTALLED - cannot fix, skipping reboot"
        FAILED+=("$host (no ${vmlinuz})")
        continue
    fi

    if (( DRY_RUN )); then
        log "${host}: [dry-run] would: grubby --set-default='${vmlinuz}' && reboot"
        FAILED+=("$host (dry-run, not fixed)")
        continue
    fi

    log "${host}: pinning persistent default -> ${vmlinuz}"
    if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "grubby --set-default='${vmlinuz}'" 2>&1; then
        log "${host}: grubby --set-default FAILED"
        FAILED+=("$host (grubby failed)")
        continue
    fi

    log "${host}: rebooting into expected kernel"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "systemctl reboot" 2>/dev/null || true
    sleep 10  # let it actually go down before we start polling

    if ! wait_reachable "$host" "$BOOT_TIMEOUT"; then
        log "${host}: did NOT come back within ${BOOT_TIMEOUT}s"
        FAILED+=("$host (no return after reboot)")
        continue
    fi

    actual="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" uname -r 2>/dev/null)"
    if [[ "$actual" == "$kern" ]]; then
        log "${host}: FIXED (now kernel=${kern})"
        FIXED+=("$host")
    else
        log "${host}: STILL WRONG after reboot: running '${actual}', expected '${kern}'"
        FAILED+=("$host (still '${actual}' after reboot)")
    fi
done < <(grep -E '^[[:space:]]*check_kernel[[:space:]]' "$CHK")

echo "======================================================"
if (( ${#FIXED[@]} )); then
    echo "Fixed: ${FIXED[*]}"
fi
if (( ${#FAILED[@]} )); then
    echo "UNRESOLVED:"
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
fi
echo "All agents on their expected kernels."
exit 0
