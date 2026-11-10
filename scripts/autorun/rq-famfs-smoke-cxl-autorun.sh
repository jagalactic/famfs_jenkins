#!/bin/bash
# run_qemu --autorun: famfs smoke + unit tests on a cxl_test (mock) devdax.
#
# EXPERIMENTAL: probes whether famfs I/O works on cxl_test's gen_pool memory.
# Alison's "cxl_test has no real DRAM backing" is scoped to kmem onlining
# (system-ram mode), not dax read/write - that memory IS system RAM, so famfs
# smoke (mount + mmap I/O) is plausibly usable. Device discovery mirrors
# daxctl-famfs-cxltest.sh (the cxl_acpi.0 region's dax chardev).
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

cd /root/famfs || { echo "FAMFS SMOKE: /root/famfs missing (famfs= not set?)"; exit 1; }
make debug || { echo "FAMFS SMOKE: build failed"; exit 1; }
# shellcheck disable=SC1091
source scripts/test_funcs.sh 2>/dev/null || true

NDCTL=./ndctl/build/ndctl/ndctl
DAXCTL=./ndctl/build/daxctl/daxctl

# cxl_test backend: load fresh, find the cxl_acpi.0 region, take its dax
# device. Mirrors daxctl-famfs-cxltest.sh's discovery; no create-region needed
# (cxl_test auto-presents the region).
modprobe -r cxl_test 2>/dev/null || true
modprobe cxl_test     || { echo "FAMFS SMOKE: cxl_test modprobe failed"; exit 1; }

region_id=""
for i in 1 2 3 4 5; do
    region_id=$("$DAXCTL" list -R 2>/dev/null | jq -r '.[]|select(.path|test("cxl_acpi.0"))|.id' | head -1)
    [ -n "$region_id" ] && break
    sleep 1
done
[ -n "$region_id" ] || { echo "FAMFS SMOKE: no cxl_acpi.0 region after cxl_test load"; "$DAXCTL" list -R || true; exit 1; }

daxdev=$("$DAXCTL" list -D -r "$region_id" 2>/dev/null | jq -er '.[0].chardev') \
    || { echo "FAMFS SMOKE: no dax device on cxl region $region_id"; "$DAXCTL" list -D -r "$region_id" || true; exit 1; }

# Ensure devdax mode (cxl_test devices may come up in another mode; mirrors
# daxctl-famfs-cxltest.sh's ensure_devdax_mode).
mode=$("$DAXCTL" list -d "$daxdev" 2>/dev/null | jq -r '.[].mode // empty')
if [ "$mode" != "devdax" ]; then
    "$DAXCTL" reconfigure-device -f -m devdax "$daxdev" >/dev/null 2>&1 || true
fi
export DEV="/dev/${daxdev}"
echo "FAMFS SMOKE: backend=cxl_test region=$region_id DEV=${DEV}"

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
if [ "$fuse_ok" -eq 1 ]; then
    echo "## ---- smoke --fuse ----"
    run_smoke_as --fuse;   r=$?; echo "## smoke --fuse rc=$r";   [ "$r" -ne 0 ] && rc=1
fi
if [ "$v1_ok" -eq 1 ]; then
    echo "## ---- smoke --nofuse (v1) ----"
    run_smoke_as --nofuse; r=$?; echo "## smoke --nofuse rc=$r"; [ "$r" -ne 0 ] && rc=1
fi
echo "## ---- unit tests (ctest) ----"
( cd debug && sudo ctest --output-on-failure ); r=$?; echo "## unit rc=$r"; [ "$r" -ne 0 ] && rc=1
echo "## ---- overall rc=$rc ----"
echo "===RQ_TESTLOG_END==="

result_rc=$rc
exit 0
