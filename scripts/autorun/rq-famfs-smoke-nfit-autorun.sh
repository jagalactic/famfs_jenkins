#!/bin/bash
# run_qemu --autorun: famfs smoke + unit tests on an nfit_test-backed devdax.
#
# nfit_test pmem has REAL DRAM backing, so famfs can actually read/write the
# dax memory (per Alison's review). We carve a 6G devdax (the VM has 12G RAM
# and nfit_test is system-RAM-backed, so 6G leaves headroom for the OS).
#
# Source (/root/famfs) is copied in by run_qemu's famfs=; built offline here.
# An EXIT trap always emits the sentinel + powers off (fail fast, no hang).

exec >/dev/console 2>&1
set -x

result_rc=1
finish() {
    sync
    echo "RQ_FAMFS_SMOKE_RESULT rc=${result_rc}"
    sleep 1
    if grep -qw rq_poweroff /proc/cmdline; then systemctl poweroff -f; fi
}
trap finish EXIT

modprobe nfit_test || true

cd /root/famfs || { echo "FAMFS SMOKE: /root/famfs missing (famfs= not set?)"; exit 1; }
make debug || { echo "FAMFS SMOKE: build failed"; exit 1; }
# shellcheck disable=SC1091
source scripts/test_funcs.sh 2>/dev/null || true

NDCTL=./ndctl/build/ndctl/ndctl
DAXCTL=./ndctl/build/daxctl/daxctl

# 6G devdax off the emulated ACPI.NFIT bus (real DRAM backing).
"$NDCTL" disable-region -b ACPI.NFIT all || true
"$NDCTL" init-labels -f -b ACPI.NFIT all || true
"$NDCTL" enable-region  -b ACPI.NFIT all || true
ns=$("$NDCTL" list -b ACPI.NFIT -Ni | jq -er '.[0].dev') \
    || { echo "FAMFS SMOKE: no namespace on ACPI.NFIT"; exit 1; }
"$NDCTL" destroy-namespace -f -b ACPI.NFIT "$ns" || true
ns=$("$NDCTL" create-namespace -b ACPI.NFIT -m devdax -fe "$ns" -s 6G | jq -er '.dev') \
    || { echo "FAMFS SMOKE: create-namespace (6G devdax) failed"; exit 1; }
daxdev=$("$NDCTL" list -n "$ns" -X | jq -er '.[].daxregion.devices[0].chardev')
[ -n "$daxdev" ] || { echo "FAMFS SMOKE: no dax device"; exit 1; }
export DEV="/dev/${daxdev}"
echo "FAMFS SMOKE: backend=nfit DEV=${DEV}"

# ---- common: detect supported modes, run smoke per mode + unit tests ----
fuse_ok=0; v1_ok=0
[ "$(famfs_fuse_supported 2>/dev/null || echo 0)" -ge 1 ] && fuse_ok=1
[ "$(famfs_v1_supported   2>/dev/null || echo 0)" -eq 1 ] && v1_ok=1
echo "FAMFS SMOKE: fuse_supported=${fuse_ok} v1_supported=${v1_ok}"
if [ "$fuse_ok" -eq 0 ] && [ "$v1_ok" -eq 0 ]; then
    echo "FAMFS SMOKE: kernel supports neither famfs mode - failing"
    exit 1
fi

# run_smoke.sh refuses to run as root; run it as a non-root user with NOPASSWD
# sudo (the unit tests below are fine as root).
SMOKE_USER=famfs
id "$SMOKE_USER" >/dev/null 2>&1 || useradd -m "$SMOKE_USER"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$SMOKE_USER" > /etc/sudoers.d/99-famfs
chmod 0440 /etc/sudoers.d/99-famfs
chmod o+rx /root            # let the smoke user traverse into root's home
chmod -R o+rwX "$PWD"       # ...and use the famfs tree in place
run_smoke_as() { sudo -u "$SMOKE_USER" DEV="$DEV" bash -c "cd '$PWD' && ./run_smoke.sh $*"; }

rc=0
echo "===RQ_TESTLOG_BEGIN==="
"$DAXCTL" list || true
# ===RQ_SECTION <name>=== markers delimit each phase so the Jenkins job can
# carve the interleaved serial console into per-mode artifacts (smoke-fuse.log,
# smoke-nofuse.log, unit.log). A bare 'end' marker closes the last section.
if [ "$fuse_ok" -eq 1 ]; then
    echo "===RQ_SECTION smoke-fuse==="
    echo "## ---- smoke --fuse ----"
    run_smoke_as --fuse;   r=$?; echo "## smoke --fuse rc=$r";   [ "$r" -ne 0 ] && rc=1
fi
if [ "$v1_ok" -eq 1 ]; then
    echo "===RQ_SECTION smoke-nofuse==="
    echo "## ---- smoke --nofuse (v1) ----"
    run_smoke_as --nofuse; r=$?; echo "## smoke --nofuse rc=$r"; [ "$r" -ne 0 ] && rc=1
fi
echo "===RQ_SECTION unit==="
echo "## ---- unit tests (ctest) ----"
( cd debug && sudo ctest --output-on-failure ); r=$?; echo "## unit rc=$r"; [ "$r" -ne 0 ] && rc=1
echo "===RQ_SECTION end==="
echo "## ---- overall rc=$rc ----"
echo "===RQ_TESTLOG_END==="

result_rc=$rc
exit 0
