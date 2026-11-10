#!/bin/bash
# run_qemu --autorun script: run the ndctl test suite (nfit + dax + cxl) under
# the kernel-under-test, for ONE OR MORE ndctl source trees, then report.
#
# Sources: each /root/ndctl-<ref> (injected via run_qemu guest_srcs=) is built +
# tested in turn, bracketed by ===RQ_SECTION ndctl-<ref>=== and reported with a
# per-ref "RQ_NDCTL_RESULT ref=<ref> rc=<n>" line, so the Jenkins job can split
# per-ref logs and attribute failures. Back-compat: with no /root/ndctl-* dirs
# it falls back to the single /root/ndctl. A final "RQ_NDCTL_RESULT rc=<overall>"
# drives the fixture's unstableOnFail (any ref failing -> UNSTABLE).
#
# Invoked by run_qemu's rq_autorun.service at boot, as root, CWD=/ -- use
# absolute paths. stdout -> /dev/console (the run_qemu --log capture Jenkins
# parses).

exec >/dev/console 2>&1
set -x

load_test_modules() {
    modprobe nfit_test || true
    modprobe cxl_test  || true
    modprobe dax_pmem  || true
    modprobe fsdev_dax || true
    modprobe kmem      || true
}
# Best-effort clean slate between ndctl versions: reload the emulated test buses
# so ref N+1 doesn't inherit ref N's namespaces/regions. Non-fatal - the next
# suite's own setup re-establishes what it needs.
reset_test_state() {
    modprobe -r cxl_test nfit_test dax_pmem fsdev_dax kmem >/dev/null 2>&1 || true
    load_test_modules
}

load_test_modules

# Collect the ndctl source trees to test: prefer per-ref dirs from guest_srcs
# (/root/ndctl-<ref>), else the legacy single tree (/root/ndctl).
srcs=()
for d in /root/ndctl-*/; do [ -d "$d" ] && srcs+=("${d%/}"); done
if [ ${#srcs[@]} -eq 0 ]; then
    if [ -d /root/ndctl ]; then srcs=(/root/ndctl); else
        echo "NDCTL AUTORUN: no ndctl source (/root/ndctl-* or /root/ndctl)"; exit 1
    fi
fi

overall=0
first=1
for src in "${srcs[@]}"; do
    ref="$(basename "$src")"; ref="${ref#ndctl-}"   # /root/ndctl-v85 -> v85 ; /root/ndctl -> ndctl
    [ "$first" = 1 ] || reset_test_state
    first=0

    echo "===RQ_SECTION ndctl-$ref==="
    if ! cd "$src"; then
        echo "NDCTL AUTORUN[$ref]: cd $src failed"; overall=1
        echo "RQ_NDCTL_RESULT ref=$ref rc=125"; continue
    fi
    # Fresh, test-enabled build. A build failure is a real result for THIS ref
    # (e.g. an old ndctl no longer compiles) -> record it and continue; don't
    # abort the whole run and lose the other refs' results.
    rm -rf build
    if ! meson setup -Dtest=enabled -Ddestructive=enabled build; then
        echo "NDCTL AUTORUN[$ref]: meson setup failed"; overall=1
        echo "RQ_NDCTL_RESULT ref=$ref rc=124"; continue
    fi
    if ! meson compile -C build; then
        echo "NDCTL AUTORUN[$ref]: meson compile failed"; overall=1
        echo "RQ_NDCTL_RESULT ref=$ref rc=123"; continue
    fi

    # Some tests legitimately fail/skip in the emulated environment; the job is
    # unstableOnFail, so a non-zero rc shows UNSTABLE (yellow), not red.
    meson test -C build --print-errorlogs --timeout-multiplier 3
    rc=$?
    echo "===RQ_TESTLOG_BEGIN ndctl-$ref==="
    cat build/meson-logs/testlog.txt 2>/dev/null
    echo "===RQ_TESTLOG_END==="
    [ "$rc" -ne 0 ] && overall=1
    echo "RQ_NDCTL_RESULT ref=$ref rc=$rc"
done

echo "===RQ_SECTION end==="
sync
echo "RQ_NDCTL_RESULT rc=$overall"
sleep 1

# CI passes 'rq_poweroff' on the kernel cmdline; interactive runs omit it and
# the VM stays up at a prompt.
if grep -qw rq_poweroff /proc/cmdline; then
    systemctl poweroff
fi
