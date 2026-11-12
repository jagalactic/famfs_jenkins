#!/bin/bash
# run_qemu --autorun: famfs smoke (--fuse) + unit tests for ONE OR MORE famfs
# source trees, on an nfit_test-backed devdax, under a PUBLIC kernel.
#
# This is the famfs_{dbg,rel}_regression_public payload: the mashup of
# rq-ndctl-autorun.sh (loop over /root/<label> trees injected via run_qemu's
# guest_srcs=, per-ref result lines) and rq-famfs-smoke-nfit-autorun.sh (carve
# a 6G devdax off ACPI.NFIT, run_smoke as a non-root user, ctest).
#
# Sources: each /root/famfs-<ref> (prepared on the host with 'make all' so all
# subrepos - ndctl, libfuse, cmake-modules, C-Thread-Pool, mongoose - are
# present; the guest has no network). Each is built + tested in turn, bracketed
# by ===RQ_SECTION famfs-<ref>.<phase>=== markers and reported with a per-ref
# "RQ_FAMFS_RESULT ref=<ref> rc=<n>" line so the Jenkins job can split per-ref
# logs and attribute failures. A final "RQ_FAMFS_RESULT rc=<overall>" drives the
# fixture's unstableOnFail.
#
# Public kernels carry famfs only in fuse mode (no fs/famfs v1 module), so only
# 'run_smoke.sh --fuse' + the unit tests run. Per-ref rc codes:
#   0    all passed
#   1    smoke and/or unit tests failed
#   121  this kernel speaks no famfs fuse ABI (no fuse_backing_is_dax /
#        famfs_fuse_iomap_begin in kallsyms) - "unsupported", not a test fail
#   122  famfs build failed
#   123  could not set up the nfit devdax (infra; applies to every ref)
#
# Build type: each tree carries .famfs-build-type, written on the host by the
# worker: "debug" (make debug, run_smoke.sh --fuse, ctest in debug/) or
# "release [<CMAKE_BUILD_TYPE>]" (make release, run_smoke.sh --fuse --release,
# ctest in release/). famfs' release target passes no CMAKE_BUILD_TYPE, which
# gives an unoptimized build without NDEBUG; when a type is given it is
# exported for the build, and cmake (>= 3.22) takes it as the default. No
# file = debug.
#
# libfuse: pinned per job (the worker's LIBFUSE_REF, famfs.extmap for now),
# NOT chosen from the running kernel. The host checks that ref out in
# ./libfuse before the copy (run_qemu ships the tree without .git/, so nothing
# can be switched here) and records it in .libfuse-ref; the build uses the
# checkout as is. The kernel's fuse ABI (same kallsyms keys as the Makefile /
# famfs_get_kernel_fuse_abi()) is only used to report NOSUPPORT.
#
# Invoked by run_qemu's rq_autorun.service at boot, as root, CWD=/ -- use
# absolute paths. stdout -> /dev/console (the run_qemu --log capture Jenkins
# parses). An EXIT trap always emits the sentinel + powers off (fail fast).

exec >/dev/console 2>&1
set -x

overall=1
finish() {
    sync
    echo "===RQ_SECTION end==="
    echo "RQ_FAMFS_RESULT rc=${overall}"
    sleep 1
    if grep -qw rq_poweroff /proc/cmdline; then systemctl poweroff -f; fi
}
trap finish EXIT

modprobe nfit_test || true
modprobe fuse      || true      # kallsyms markers only appear once fuse is loaded

# ---- famfs source trees to test (/root/famfs-<ref>) ----
srcs=()
for d in /root/famfs-*/; do [ -d "$d" ] && srcs+=("${d%/}"); done
if [ ${#srcs[@]} -eq 0 ]; then
    echo "FAMFS REGRESSION: no famfs source (/root/famfs-*)"; exit 0   # overall stays 1
fi
ref_of() { local b; b="$(basename "$1")"; echo "${b#famfs-}"; }

# ---- which famfs fuse ABI does this kernel speak? ----
kabi=none
if   grep -qsw fuse_backing_is_dax    /proc/kallsyms; then kabi=extmap
elif grep -qsw famfs_fuse_iomap_begin /proc/kallsyms; then kabi=daxfmap
fi
echo "FAMFS REGRESSION: kernel=$(uname -r) fuse_abi=${kabi}"

if [ "$kabi" = none ]; then
    # Not a test failure: this kernel has no famfs fuse enablement (e.g. Linus'
    # master before the fuse pull request landed). Report every ref as 121.
    for src in "${srcs[@]}"; do
        echo "===RQ_SECTION famfs-$(ref_of "$src").unsupported==="
        echo "FAMFS REGRESSION[$(ref_of "$src")]: kernel ${kver} speaks no famfs fuse ABI - unsupported"
        echo "RQ_FAMFS_RESULT ref=$(ref_of "$src") rc=121"
    done
    overall=121
    exit 0
fi

# ---- 6G devdax off the emulated ACPI.NFIT bus (real DRAM backing) ----
# Prefer the rootfs ndctl/daxctl packages; fall back to the first tree's build.
NDCTL="$(command -v ndctl || echo "${srcs[0]}/ndctl/build/ndctl/ndctl")"
DAXCTL="$(command -v daxctl || echo "${srcs[0]}/ndctl/build/daxctl/daxctl")"
setup_devdax() {
    "$NDCTL" disable-region -b ACPI.NFIT all || true
    "$NDCTL" init-labels -f -b ACPI.NFIT all || true
    "$NDCTL" enable-region  -b ACPI.NFIT all || true
    local ns
    ns=$("$NDCTL" list -b ACPI.NFIT -Ni | jq -er '.[0].dev') || return 1
    "$NDCTL" destroy-namespace -f -b ACPI.NFIT "$ns" || true
    ns=$("$NDCTL" create-namespace -b ACPI.NFIT -m devdax -fe "$ns" -s 6G | jq -er '.dev') || return 1
    daxdev=$("$NDCTL" list -n "$ns" -X | jq -er '.[].daxregion.devices[0].chardev') || return 1
    [ -n "$daxdev" ] || return 1
    export DEV="/dev/${daxdev}"
    echo "FAMFS REGRESSION: backend=nfit DEV=${DEV}"
}
if ! setup_devdax; then
    echo "FAMFS REGRESSION: nfit devdax setup failed"
    for src in "${srcs[@]}"; do echo "RQ_FAMFS_RESULT ref=$(ref_of "$src") rc=123"; done
    overall=123
    exit 0
fi
"$DAXCTL" list || true

# run_smoke.sh refuses to run as root; run it as a non-root user with NOPASSWD
# sudo (the unit tests are fine as root).
SMOKE_USER=famfs
id "$SMOKE_USER" >/dev/null 2>&1 || useradd -m "$SMOKE_USER"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$SMOKE_USER" > /etc/sudoers.d/99-famfs
chmod 0440 /etc/sudoers.d/99-famfs
chmod o+rx /root            # let the smoke user traverse into root's home
run_smoke_as() { local tree="$1"; shift; sudo -u "$SMOKE_USER" DEV="$DEV" bash -c "cd '$tree' && ./run_smoke.sh $*"; }

overall=0
for src in "${srcs[@]}"; do
    ref="$(ref_of "$src")"
    rc=0
    umount /mnt/famfs 2>/dev/null || true     # clean slate between refs

    echo "===RQ_SECTION famfs-${ref}.build==="
    if ! cd "$src"; then
        echo "FAMFS REGRESSION[$ref]: cd $src failed"; overall=1
        echo "RQ_FAMFS_RESULT ref=$ref rc=122"; continue
    fi
    echo "famfs ${ref}: $(cat .famfs-sha 2>/dev/null || echo '?')"
    echo "libfuse (pinned on the host): $(cat .libfuse-ref 2>/dev/null || echo '?')"
    chmod -R o+rwX "$src"       # let the smoke user use the tree in place
    btype=debug; cmake_bt=""
    [ -r .famfs-build-type ] && read -r btype cmake_bt < .famfs-build-type
    case "$btype" in
        release) bdir=release; smoke_bt="--release" ;;
        *)       btype=debug; bdir=debug; smoke_bt=""; cmake_bt="" ;;
    esac
    echo "famfs build type: ${btype}${cmake_bt:+ (CMAKE_BUILD_TYPE=${cmake_bt})}"
    rm -rf "$bdir"              # always configure fresh (see CMAKE_BUILD_TYPE below)
    # env CMAKE_BUILD_TYPE is only a default: it applies because the release
    # target passes none (and never to 'make debug', which passes its own).
    if ! ( [ -n "$cmake_bt" ] && export CMAKE_BUILD_TYPE="$cmake_bt"; make "$bdir" ); then
        echo "FAMFS REGRESSION[$ref]: build failed"
        overall=1; echo "RQ_FAMFS_RESULT ref=$ref rc=122"; continue
    fi
    # What was really built: cmake's build type and the C flags in effect.
    echo "FAMFS REGRESSION[$ref]: $(grep -s '^CMAKE_BUILD_TYPE' "$bdir/CMakeCache.txt" || echo 'CMAKE_BUILD_TYPE unset')"
    grep -hs '^C_FLAGS' "$bdir"/CMakeFiles/*/flags.make | sort -u | head -3
    "./$bdir/famfs_fused" --fuse-abi 2>/dev/null || true

    echo "===RQ_SECTION famfs-${ref}.smoke-fuse==="
    echo "## ---- famfs ${ref}: smoke --fuse ${smoke_bt} ----"
    run_smoke_as "$src" --fuse $smoke_bt; r=$?; echo "## smoke --fuse rc=$r"; [ "$r" -ne 0 ] && rc=1
    umount /mnt/famfs 2>/dev/null || true

    echo "===RQ_SECTION famfs-${ref}.unit==="
    echo "## ---- famfs ${ref}: unit tests (ctest) ----"
    ( cd "$bdir" && ctest --output-on-failure ); r=$?; echo "## unit rc=$r"; [ "$r" -ne 0 ] && rc=1

    [ "$rc" -ne 0 ] && overall=1
    echo "RQ_FAMFS_RESULT ref=$ref rc=$rc"
done

exit 0
