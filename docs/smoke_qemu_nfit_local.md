# smoke_qemu_nfit_local

## Code under test

| Component | Repo / source | Ref |
|-----------|---------------|-----|
| **famfs** user-space (the code under test) | `/home/jenkins/git/famfs` (local bare mirror) | branch **`master`** |
| Kernel (provides the famfs modes) | `/home/jenkins/git/linux.git` | branch **`famfs`** |
| Kernel `.config` | `configs/famfs_qemu_ndctl.config` | - |

Builds famfs in the guest and runs its **smoke tests** (`run_smoke.sh`, both
fuse and v1) plus the googletest **unit** suite, on a **6G nfit_test devdax**.
nfit_test pmem has **real DRAM backing**, so famfs can actually read/write the
dax memory (per Alison's review - that's why this is the high-confidence
variant). **Status: green** (fuse + v1 + units all pass). See
[README.md](README.md) for the shared agent / fixture / artifacts / deploy.

The VM is **8 vCPUs / 12 GiB** (run_qemu defaults; ~8 GiB usable System RAM),
and the devdax is **6 GiB**. Both are tunable - see
[run_qemu_vm_resources.md](run_qemu_vm_resources.md).

## Flow

Entrypoint `smoke_qemu_nfit_local.groovy`:

1. **`prepare famfs source`** (on the host): clone the `/home/jenkins/git/famfs`
   mirror, `make all` (pulls famfs's subrepos while the host has DNS), then
   prune dangling symlinks (mongoose ships tutorial symlinks that break
   run_qemu's `-L` `famfs=` rsync).
2. `fixture.call(famfsSrc=…, runQemuArgs='--nfit-test',
   autorunScript=rq-famfs-smoke-nfit-autorun.sh)`.

In the guest, `rq-famfs-smoke-nfit-autorun.sh`:

- `make debug` in `/root/famfs` (offline; the rootfs has cmake/gcc-c++/
  libyaml-devel/attr).
- carve a **6G** devdax off `ACPI.NFIT` (`ndctl create-namespace -m devdax
  -s 6G`), set `DEV`.
- detect modes (`famfs_fuse_supported` / `famfs_v1_supported`); fail fast if
  neither is supported.
- run `run_smoke.sh --fuse` and `--nofuse` **as a non-root `famfs` user**
  (`run_smoke` refuses to run as root), then the `ctest` unit suite (as root).
- emit `RQ_FAMFS_SMOKE_RESULT rc=<n>`; an `EXIT` trap always powers off.

The autorun brackets each phase with `===RQ_SECTION <name>===` markers, and the
job's `split smoke logs` stage carves the (interleaved) serial console into
per-mode artifacts - **`smoke-fuse.log`**, **`smoke-nofuse.log`**,
**`unit.log`** - alongside the combined `console.log` / `test-results.txt`. It
runs in a `finally`, so the per-mode logs are archived even when the run fails
(a skipped mode simply has no file).

## Gating

No `unstableOnFail` - any failure (build, neither mode, a smoke/unit failure,
or a missing sentinel) is **red**. Last run: **3 PASS / 0 FAIL** (fuse, v1,
unit). (`run_smoke`'s `ERROR: N ALLOCATION COLLISIONS FOUND` lines are expected
negative-test output, not a failure.)

## Gotchas worked through (so the next person doesn't relive them)

- **mongoose dangling symlinks** abort the `-L` `famfs=` rsync (`code 23`) ->
  prune dangling symlinks in the prepare stage.
- **`libyaml-devel`** (and `attr`) were missing from the guest rootfs ->
  added to the run_qemu fork's fedora package list.
- **`run_smoke` refuses root** (`EUID==0` -> exit) -> run it as a non-root user
  with passwordless sudo.
- **Module compression vs `run_smoke`'s module detection:** the CI kernel sets
  `CONFIG_MODULE_COMPRESS_ZSTD`, so the module installs as `famfsv1.ko.zst`.
  `run_smoke`'s old `[ -f "${V1PATH}/famfsv1.ko" ]` check missed the `.zst` and
  fell back to `modprobe famfs.ko` (wrong name) -> v1 FATAL. Fixed in `run_smoke`
  to probe by name (`modprobe -n famfsv1`), which is compression-agnostic.

## Deploy / run

```sh
JOB=smoke_qemu_nfit_local JENKINS_USER=jmg scripts/create-job.sh
```
