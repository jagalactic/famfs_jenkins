#!/bin/bash
# run_qemu --autorun script: build the famfs ndctl tree's tests and run the
# nfit + cxl_test famfs mode-transition tests in the guest, then report.
#
# Invoked by run_qemu's rq_autorun.service at boot, as root, with CWD=/ —
# so use absolute paths. Its stdout normally goes to the journal; we redirect
# to /dev/console so it shows up in your `script` capture of the run.

exec >/dev/console 2>&1
set -x

# Backing/feature modules. nfit_test provides the bus the nfit test uses;
# fsdev_dax = famfs mode; kmem = system-ram. (the cxltest script modprobes
# cxl_test itself.)
modprobe nfit_test || true
modprobe fsdev_dax || true
modprobe kmem || true

cd /root/ndctl || { echo "FAMFS AUTORUN: /root/ndctl missing"; exit 1; }

# Fresh, test-enabled build dir (avoids any stale host paths in the rsynced-in
# tree's build/).
rm -rf build
meson setup -Dtest=enabled -Ddestructive=enabled build
meson test -C build daxctl-famfs-nfit.sh daxctl-famfs-cxltest.sh
rc=$?

# Full per-test output + meson Ok/Fail summary (testlog.txt is self-contained).
# Wrap in stable markers so Jenkins can extract a clean test-results artifact.
echo "===RQ_TESTLOG_BEGIN==="
cat build/meson-logs/testlog.txt 2>/dev/null
echo "===RQ_TESTLOG_END==="

# Result sentinel for the host/Jenkins to grep out of the console log.
# Keep this string unique and stable.
sync
echo "RQ_FAMFS_RESULT rc=$rc"
sleep 1                          # let the console drain before power-off

# Exit the VM so qemu (and run_qemu) terminate. Gated on a kernel-cmdline
# token so the SAME image still boots to an interactive shell when you don't
# pass it: CI passes 'rq_poweroff' on the kernel cmdline; interactive runs omit
# it and the VM stays up at a prompt.
if grep -qw rq_poweroff /proc/cmdline; then
	systemctl poweroff
fi
