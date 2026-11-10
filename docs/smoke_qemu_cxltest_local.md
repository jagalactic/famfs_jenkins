# smoke_qemu_cxltest_local

## Code under test

| Component | Repo / source | Ref |
|-----------|---------------|-----|
| **famfs** user-space (the code under test) | `/home/jenkins/git/famfs` (local bare mirror) | branch **`master`** |
| Kernel (provides the famfs modes) | `/home/jenkins/git/linux.git` | branch **`famfs`** |
| Kernel `.config` | `configs/famfs_qemu_ndctl.config` | - |

Same as [`smoke_qemu_nfit_local`](smoke_qemu_nfit_local.md), but the devdax is
sourced from the **`cxl_test` mock** instead of nfit_test.

> **Status: EXPERIMENTAL / does not currently pass.** The cxl_test devdax
> path itself works for famfs setup (daxctl mode-switch devdax<->famfs round-
> trips fine, ownership/perms OK, region discovery picks the right region),
> but `mkfs.famfs` then rejects the device for being too small: cxl_test's
> auto-region is **512 MiB**, and famfs enforces a **4 GiB minimum**. See
> "Open issue" below.

## Why cxl_test (mock) and not real `--cxl`

Earlier this job used run_qemu's `--cxl` (real, file-backed CXL type3 devices)
on the theory that famfs needs "real" memory. That theory mis-scoped Alison's
note: "`cxl_test` has no real DRAM backing" is true for **kmem onlining**
(`system-ram` mode, where the kernel adds CXL memory to the page allocator) -
the gen_pool cxl_test carves out is **not** suitable for that. But for plain
**devdax** read/write, the memory the gen_pool is carved from **is** system
RAM, so famfs (mount + mmap I/O) is plausibly usable on it.

Switching to `--cxl-test` avoids the file-backed-CXL setup problem (`--cxl`
alone presented no CXL memdev to the guest) and lets us see whether famfs
smoke really works on cxl_test dax. If smoke passes on cxl_test it confirms
the cxl stack is fine for famfs's access pattern; if it fails (e.g. mmap of
gen_pool memory misbehaves), we know we genuinely need real file-backed CXL
and the device-setup problem is worth revisiting.

## Flow

Entrypoint `smoke_qemu_cxltest_local.groovy`: same host `prepare famfs source`
as the nfit job, then `fixture.call(famfsSrc=..., runQemuArgs='--cxl-test',
autorunScript=rq-famfs-smoke-cxl-autorun.sh)`.

`rq-famfs-smoke-cxl-autorun.sh`: build famfs offline, `modprobe cxl_test`,
find the `cxl_acpi.0` region (same discovery as `daxctl-famfs-cxltest.sh`),
take its dax chardev, ensure `devdax` mode, then the same detect-modes /
`run_smoke` (non-root) / `ctest` flow as the nfit job. Fail fast (`EXIT` trap
powers off).

## Open issue: 512 MiB cxl_test region vs 4 GiB famfs minimum

Build #5 (the first that booted + ran tests end-to-end) failed with
`famfs_mkfs_allowed: unsupported memory device size (<4GiB)`. The size
mismatch comes from two hard limits:

- **cxl_test auto-region: 512 MiB.** `tools/testing/cxl/test/cxl.c:31`:
  `#define MOCK_AUTO_REGION_SIZE_DEFAULT SZ_512M`; the corresponding
  `static int mock_auto_region_size` is **not** exposed as a `module_param`,
  so `modprobe cxl_test mock_auto_region_size=...` is not currently a knob.
- **famfs `mkfs` minimum: 4 GiB.** `src/famfs_lib.c:5564`:
  `u64 min_devsize = 4ll * 1024ll * 1024ll * 1024ll;` - enforced
  unconditionally in `famfs_mkfs_allowed` (the `force` arg only bypasses the
  client-superblock check, not this size check).

Three options for resolving this (none implemented):

1. **Abandon `smoke_qemu_cxltest_local`.** Accept that famfs smoke can only
   run on backends that meet the 4 GiB minimum (nfit_test at 8 GiB works;
   file-backed `--cxl` would too, once the original device-setup problem is
   solved); delete this job. Lowest effort, no upstream impact.
2. **Patch famfs to work with 512 MiB devices.** Lower `min_devsize`, or add
   a `--force`-style override that also bypasses the size check, in
   `famfs_mkfs_allowed`. famfs-only change; lets cxl_test smoke pass with no
   kernel changes. Worth doing only if 512 MiB famfs filesystems are a
   sensible target in their own right.
3. **Patch cxl_test to support >= 4 GiB regions.** Expose
   `mock_auto_region_size` as a `module_param` in
   `tools/testing/cxl/test/cxl.c` (and possibly bump the default), so the
   autorun can `modprobe cxl_test mock_auto_region_size=0x100000000`
   (4 GiB) or larger. Kernel-fork-only change; keeps famfs and its minimum
   unchanged.

## Deploy / run

```sh
JOB=smoke_qemu_cxltest_local JENKINS_USER=jmg scripts/create-job.sh
```
