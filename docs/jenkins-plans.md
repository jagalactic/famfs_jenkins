# Jenkins job plans

Design notes for planned-but-not-yet-built famfs_jenkins jobs. One section per
job. Once a plan is implemented, move its user-facing docs to `docs/` and leave
a one-line "DONE ->" pointer here.

---

## ndctl-regression-public

Nightly regression job over **two moving upstream axes** - Linus' mainline
**kernel** and upstream **ndctl** - built + booted + tested under
`run_qemu_fixture.groovy` on thing1. Modeled on
`ndctl_qemu_test_{all,famfs}_local`, but both the kernel and ndctl are moving
targets, and it can be pinned to *local* repos for a manual run.

Status: **DONE** -> see [ndctl_regression_public.md](ndctl_regression_public.md)
(job + watcher + two systemd timers) and
[run_qemu_build_infra.md](run_qemu_build_infra.md) (kernel mirror, mkosi/buildDir
layout, package cache). The design notes below are retained as history; a few
details differ from what shipped (e.g. systemd timers instead of an in-groovy
cron trigger; a local `--mirror` of the stable tree with a public fallback).

### Goal

Catch regressions in the mainline nvdimm / dax / cxl subsystems and in ndctl as
either moves. The ndctl suite only exercises code that is upstream, so the
tested range is bounded (below). famfs is additionally built out-of-tree and
tested when it builds against the kernel under test.

### Scope / lower bounds

- **Kernel axis:** Linus' mainline (`torvalds/linux`). Only kernels in the
  **7.1 cycle and later** (the code the suite validates first went upstream in
  7.1): release/rc tags `>= v7.1` plus `master`. (Confirm the exact first rc
  that carries the code; the tag lower bound may be `v7.1-rcN`.)
- **ndctl axis:** upstream **`pmem/ndctl`**. Only **releases `>= v85`** plus the
  default branch **`main`**. (v85 is where the validated code lands.)
- The **jagalactic** fork (kernel `linux.git@famfs`, `jagalactic/ndctl@famfs`)
  is not the nightly axis - it's reachable via the manual override below.

### Two axes + "known-good" references

Each axis has a moving frontier and a stable reference used when we vary the
*other* axis (so a new failure is attributable to the axis that moved):

| | frontier (varied) | reference `_ref` (held fixed) |
|---|---|---|
| Kernel | new tags `>= v7.1` (release+rc) and `master` | latest kernel **release** `>= v7.1` (no rc) |
| ndctl  | new **releases** `>= v85` and `main` | latest ndctl **release** `>= v85` |

### Nightly matrix: hold-one-fixed + tips  (the core)

Runs on thing1. Up to three build+boot+test runs per night, bounded and
attributable:

```
K_ref = latest kernel RELEASE tag >= v7.1        # stable kernel baseline
N_ref = latest ndctl  RELEASE tag >= v85         # stable ndctl baseline
runs  = []

# 1) Kernel stream: did a new kernel tag (release or rc, >= v7.1) appear?
K_new = newest kernel tag >= v7.1
if K_new != state.last_kernel_tag:
    runs += (kernel = K_new,          ndctl = N_ref)     # vary kernel
    state.last_kernel_tag = K_new

# 2) ndctl stream: did a new ndctl release (>= v85) appear?
N_new = newest ndctl release >= v85
if N_new != state.last_ndctl_release:
    runs += (kernel = K_ref,          ndctl = N_new)     # vary ndctl
    state.last_ndctl_release = N_new

# 3) Tips (bleeding edge; almost always moves): always run
runs += (kernel = linus/master,       ndctl = pmem/main)

for r in runs:
    build + boot + test r
    displayName/artifact record BOTH refs (kernel + ndctl, kind + sha)
```

- **Version sort:** `git config versionsort.suffix -rc` on the kernel mirror so
  `v7.1-rc7 < v7.1`. Restrict kernel tag glob to `>= v7.1`; ndctl to `>= v85`.
- **Per-stream state** on thing1's persistent disk, e.g.
  `/home/jenkins/state/ndctl-regression-public/{last_kernel_tag,last_ndctl_release}`.
  (Optionally also `last_master_sha` / `last_main_sha` to skip the tips run when
  neither tip moved.)
- **State-update policy (decide):** on *selection* (each tag/release tested once,
  a broken one fails once and doesn't re-wedge) vs on *successful* build.
  Leaning "on selection".
- **Cost:** each run is a full kernel build (incremental in a persistent
  `kernelDir`) + qemu boot + suite; a busy night (new kernel tag + new ndctl
  release + tips) is ~3 runs. Acceptable for nightly on thing1; note wall-clock
  can reach a few hours.

### Manual override: run vs local kernel and/or ndctl

**local kernel x local ndctl is already covered** by `ndctl_qemu_test_all_local`
(`linux.git@famfs` x `jagalactic/ndctl@famfs`, full ndctl suite) - and
`ndctl_qemu_test_famfs_local` covers the famfs-daxctl payload on that same pair.
So the *only* combinations the existing jobs do **not** cover are the **mixed**
ones:

- local kernel (`linux.git@famfs`) x **upstream** ndctl (does the famfs kernel
  pass current pmem/ndctl?)
- **upstream** kernel x local ndctl (`jagalactic/ndctl@famfs`)

**Open decision:** are those mixed runs wanted? If yes, keep a parameter
override (`KERNEL_REPO/REF`, `NDCTL_REPO/REF`; empty = nightly upstream matrix,
any set = a single pinned run, unset axis defaulting to kernel `master` / ndctl
`N_ref`, no state writes). If the mixed cases aren't interesting, drop the
override entirely and let this job be **upstream-only**, leaving local/local to
the existing `_local` jobs. Leaning: keep a lightweight override for the mixed
cases, since it's cheap and reuses the same harness.

### Kernel source & mirror

- Upstream `https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git`.
- **Local bare mirror on thing1** (a nightly ~4-5 GB clone is wasteful): a
  dedicated `/home/jenkins/git/torvalds-linux.git` (preferred, keeps the famfs
  mirror clean) or a `torvalds` remote on the existing `linux.git`.
  `git fetch --tags` at job start.

### ndctl source & mirror

- Upstream `https://github.com/pmem/ndctl.git` (default branch **`main`**;
  releases tagged `vNN`). A small mirror/clone per run is cheap; fetch tags +
  `main` at job start. The chosen ndctl tree is handed to the fixture via
  `ndctlSrc`; `rq-ndctl-autorun.sh` rebuilds it in the guest with tests enabled.

### Kernel .config strategy  (PRIMARY RISK)

`configs/famfs_qemu_ndctl.config` is tuned to the famfs branch and won't map
correctly to arbitrary mainline versions (new symbols default via
`olddefconfig`, possibly disabling needed infra; famfs symbols absent upstream).
Recommended:

1. Commit a **config fragment** (`configs/ndctl_regression.fragment`) of only
   the CONFIG_* the ndctl test infra needs on mainline (ACPI_NFIT, DEV_DAX /
   DAX / DAX_PMEM, ZONE_DEVICE, NVDIMM, CXL_* for cxl_test, etc.;
   nfit_test/cxl_test *modules* are built by run_qemu's `--nfit-test` /
   `--cxl-test`, not the base config).
2. Per kernel: `make defconfig` -> `scripts/kconfig/merge_config.sh` with the
   fragment -> `olddefconfig`.
3. **Assert required symbols** in the resulting `.config`; if any is missing or
   `=n`, fail as *infra* (no sentinel -> red) rather than silently testing a
   mis-configured kernel.

Either extend the fixture to take a base+fragment, or generate the `.config` in
the job and pass it as `configFile` (keeps the fixture untouched for this part).

### Test payloads  (both, per earlier decision)

1. **ndctl meson suite (always)** - reuse `rq-ndctl-autorun.sh` (builds ndctl
   `-Dtest=enabled -Ddestructive=enabled`, runs suites ndctl+dax+cxl under
   nfit_test+cxl_test). `unstableOnFail: true`.
2. **famfs out-of-tree (when buildable)** - attempt to build the famfs module
   OOT against the kernel under test; if it builds+loads, run the famfs daxctl
   tests; else log `famfs: skipped (no OOT build for <kernel-ref>)`.
   - **Open:** confirm famfs supports an OOT build against arbitrary mainline.
     If not, ship payload 1 first; famfs becomes free for kernels that carry it
     in-tree (>= its upstream merge). Prefer one boot with a combined autorun
     (ndctl suite, then famfs attempt) to avoid a second kernel boot.

### Fixture change needed:  `kernelRef`

`run_qemu_fixture.groovy`'s `kernel: fetch` does
`git checkout <branch>; git reset --hard origin/<branch>` (branch-only). Add a
back-compat `kernelRef`: when set, `git fetch --tags` + `git checkout --detach
<ref>` (tag / sha / `origin/master`), skipping the `reset --hard origin/...`.
Existing jobs (no `kernelRef`) are unchanged. `ndctlSrc` is already a path arg,
so the ndctl axis needs no fixture change.

### Scheduling & gating

- **Trigger:** `properties([pipelineTriggers([cron('H 3 * * *')])])` in the
  entrypoint (self-contained; `create-job.sh` writes an empty `<triggers/>`).
- **Gating:** `unstableOnFail: true` (env-dependent test failures -> yellow);
  kernel-build failure, boot failure, missing sentinel, or a failed
  required-symbol assertion -> red.

### Artifacts & result identification

- Fixture artifacts (`console.log`, `test-results.txt`, `test-summary.txt`) per
  run - **namespaced per run** (kernel-ref + ndctl-ref) since a night has
  several.
- `tested-refs.txt` per run: kernel {kind, ref, sha}, ndctl {kind, ref, sha},
  date. Set `currentBuild.displayName` to both, e.g.
  `k:v7.2-rc3 x n:v86` or `k:master@ab12 x n:main@cd34`.
- **Future:** diff each run's PASS/FAIL set against a stored per-pair baseline;
  alert only on *newly* failing tests (regression signal vs known-flaky noise).

### Reused vs new components

Reused: `run_qemu_fixture.groovy` (+ `kernelRef`), `rq-ndctl-autorun.sh`,
`rq-ci-cmdline`, `create-job.sh`, the run_qemu agent (thing1).

New:
- `ndctl-regression-public.groovy` (trigger + params + auto/manual mode +
  two-axis selection + per-stream state + N runs of fixture.call + famfs attempt
  + per-run displayName/artifacts).
- `configs/ndctl_regression.fragment` (+ config-gen/assert helper).
- Linus mirror + `/home/jenkins/state/ndctl-regression-public/` on thing1.
- (maybe) combined `rq-ndctl-famfs-autorun.sh` for both payloads in one boot.
- `docs/ndctl-regression-public.md`.

### Implementation phases

0. **Prereqs:** Linus mirror + nightly fetch on thing1; confirm the first 7.1 rc
   carrying the code; identify the required mainline CONFIG_* set; confirm famfs
   OOT feasibility (or defer payload 2).
1. **Fixture:** add `kernelRef` (back-compat).
2. **Config:** fragment + `merge_config.sh` + required-symbol assertion.
3. **Entrypoint v1:** cron; params + auto/manual mode; two-axis selection +
   per-stream state; ndctl-suite payload; per-run displayName/`tested-refs.txt`.
   Register via `create-job.sh`.
4. **famfs payload:** OOT build attempt + famfs tests (once feasible).
5. **Future:** per-pair baseline diffing + notification on new regressions.

### Open decisions to confirm

- Manual override: keep it (for the *mixed* local/upstream combos) vs
  upstream-only (local/local already == `ndctl_qemu_test_all_local`).
- Exact kernel lower bound (`v7.1` release vs the specific `v7.1-rcN` merge).
- Job name: `ndctl-regression-public` (hyphens) vs repo convention
  (`ndctl_qemu_regression_public`, underscores + `_qemu_`).
- State-update policy: on selection (leaning) vs on successful build.
- Tips run: always nightly vs only when master/main moved.
- Multi-tag/-release catch-up: newest only (default) vs each missed one.
- Default upstream ndctl `main` vs pinning a release for the ndctl `_ref`.
- Config approach: fragment+merge (recommended) vs olddefconfig-from-saved.
- famfs OOT feasibility -> ship payload 1 first if unresolved.

---

## smoke_qemu_nfit_kcov_local  (kernel gcov coverage)

A variant of `smoke_qemu_nfit_local` that measures **kernel** code coverage
(gcov) for the dax/fuse/famfs paths the nfit smoke suite exercises. **Local
only** for now (famfs's fs isn't upstream, so the kernel is `linux.git@famfs`).

Status: **PLANNED** (assessed feasible in discussion; not yet built or, until
now, written down). Naming: `smoke_qemu_nfit_kcov_local` or
`kcoverage_qemu_nfit_local` - deliberately distinct from the user-space
`coverage_*` jobs, which measure famfs *user-space* coverage, not the kernel.

### Goal / scope

Measure how much of the kernel dax/fuse/famfs code the nfit smoke run actually
exercises. Scoped to keep it small and meaningful:

- `fs/fuse/`
- `fs/famfs/`
- `drivers/dax/`
- `fs/dax.c`

This is *kernel* coverage of the code under `run_smoke`, complementary to the
existing user-space coverage jobs.

### Feasibility: yes

The kernel has first-class gcov support (`CONFIG_GCOV_KERNEL`): instrumented
objects expose live counters at `/sys/kernel/debug/gcov/`. The trick is to
**not** instrument the whole kernel (`GCOV_PROFILE_ALL` = huge, slow, and a big
`.gcda` set that's painful to extract); instead instrument only the four paths.

### Selective instrumentation

- Config: `CONFIG_GCOV_KERNEL=y` + `CONFIG_DEBUG_FS=y`, and **not**
  `GCOV_PROFILE_ALL`. Merge into `configs/famfs_qemu_ndctl.config` (or a small
  `configs/kcov.fragment`).
- One-line Makefile edits (applied as a tiny patch/sed at build time, since this
  is the local famfs kernel):
  - `GCOV_PROFILE := y` in `fs/fuse/Makefile`, `fs/famfs/Makefile`,
    `drivers/dax/Makefile`
  - `GCOV_PROFILE_dax.o := y` in `fs/Makefile` (for `fs/dax.c`)
- Keeping the instrumented set tiny keeps the runtime `.gcda` small, which
  matters for extraction (below).

### Run

Reuse the `smoke_qemu_nfit_local` flow wholesale: same fixture, same 6G
nfit_test devdax + `run_smoke` (fuse + v1) - that's exactly what exercises
fuse/dax/famfs. Additions are the gcov config/patch at build time and a
gcov-gather step at the end of `rq-famfs-smoke-nfit-autorun.sh` (after the tests,
before shutdown/module-unload).

### Extracting coverage from the guest  (the design question)

Counters live in the guest; the report needs them combined with the `.gcno`
files in the host build tree. run_qemu gives clean channels:

- **Preferred: host post-run mount.** run_qemu already loop-mounts the rootfs
  image (`losetup -Pf`) and has a `--post-script` host hook. The guest autorun
  tars the small gcov tree (`tar czf /root/kgcov.tgz -C /sys/kernel/debug/gcov
  .`); after poweroff the host mounts the rootfs image and copies it out. Size-
  agnostic. **Phase-0 check:** confirm run_qemu boots the rootfs read-write /
  persistent (not a throwaway snapshot).
- **Guaranteed fallback: base64 over console.** gzip+base64 the gcov tree to
  `/dev/console`; the fixture already captures `console.log`, so decode it back
  on the host. For a 4-subsystem selective set this is only tens-hundreds of KB
  gzipped - fine, and needs zero new run_qemu plumbing.

### Report

On thing1 (same host that built the kernel, so gcc/gcov versions match;
`CONFIG_GCOV_FORMAT_AUTODETECT` handles the rest): overlay the extracted `.gcda`
onto the kernel build tree, `lcov --capture` (or gcovr), **filter to the four
paths**, `genhtml` -> archive as an HTML artifact, like the `coverage_local`
reports.

### Caveats

- **Modules vs built-in:** if famfs/fuse/dax are modules, gather gcov *after*
  the tests and *before* unload/shutdown (per-module `.gcda` disappears on
  unload).
- Coverage reflects only what the smoke suite exercises - which is the point.
- gcov needs a gcc-built kernel (the famfs kernel is; not clang).

### Reused vs new components

Reused: `run_qemu_fixture.groovy`, `smoke_qemu_nfit_local.groovy` flow,
`rq-famfs-smoke-nfit-autorun.sh`, the nfit devdax setup, thing1.

New:
- `smoke_qemu_nfit_kcov_local.groovy` (entrypoint: gcov config/patch + gather +
  host-side collect/report).
- gcov Makefile patch + `configs/kcov.fragment` (or config edits).
- host-side collect+lcov+genhtml step (in the job or a post-script).
- `docs/smoke_qemu_nfit_kcov_local.md`.

### Implementation phases

0. **Prereqs:** confirm run_qemu rootfs persistence for the mount-back path (else
   use base64-over-console); confirm the four Makefiles take `GCOV_PROFILE`.
1. **Build:** gcov config + Makefile patch; verify `/sys/kernel/debug/gcov/`
   populates for the four paths in a boot.
2. **Extract:** gather tarball in the autorun + get it to the host (mount-back or
   base64).
3. **Report:** overlay `.gcda` -> lcov -> filter -> genhtml -> archiveArtifacts.
4. **Wire up:** entrypoint + `create-job.sh` register + docs.

### Open decisions

- Extraction: host mount-back (cleaner, needs the persistence check) vs
  base64-over-console (guaranteed, tiny-data only).
- Config: merge into the shared `famfs_qemu_ndctl.config` vs a separate
  `kcov.fragment` (keeps the base config clean).
- Job name: `smoke_qemu_nfit_kcov_local` vs `kcoverage_qemu_nfit_local`.
- Whether to also fold in the cxl smoke path later (would broaden dax coverage).

---

## famfs_daxmode_regression_public

A variant of `ndctl_qemu_test_famfs_local` that runs the **famfs dax-mode
transition tests against upstream kernels** - triggered by new mainline
releases, release candidates, and applicable **stable** point releases - to
catch regressions in the kernel's famfs dax mode (`fsdev_dax`).

Status: **PLANNED, near-term** (user wants this implemented almost right away).
Simpler than `ndctl-regression-public` and shares its infrastructure (see
"Relationship" below). Name: `famfs_daxmode_regression_public` (or
`ndctl_qemu_test_famfs_public`) - decide vs repo convention.

### Goal

`fsdev_dax` (the dax-device "famfs mode") is **upstream** (7.1+). This job
re-runs `ndctl_qemu_test_famfs_local`'s two mode-transition tests -
`daxctl-famfs-nfit.sh` + `daxctl-famfs-cxltest.sh` (from `rq-famfs-autorun.sh`) -
against each new upstream kernel, so a regression in `fsdev_dax` / dax mode
transitions is caught as it lands.

### Key simplifier: no fs/famfs needed

Those tests only exercise **daxctl reconfiguring a dax device to/from famfs mode**
(`fsdev_dax` + `nfit_test`/`cxl_test` backends) - they do **not** mount the
`fs/famfs` filesystem. So this runs on a **pure mainline/stable kernel** with no
famfs-branch kernel and no out-of-tree module build. That's why it's near-term
and much lighter than the two-axis `ndctl-regression-public`.

### Kernel axis: releases + rcs + applicable stable

Single moving axis - the kernel. Watch three tag families, lower-bounded to
where `fsdev_dax` exists (**>= v7.1**):

- **Mainline releases:** `v7.2`, `v7.3`, ...
- **Release candidates:** `v7.3-rc1`, ...
- **Applicable stable point releases:** `v7.1.1`, `v7.1.2`, `v7.2.1`, ... for
  series `>= 7.1`.

Source: the **linux-stable** tree
(`git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git`) carries the
mainline release/rc tags **and** the `vX.Y.Z` stable tags - one mirror covers
all three families (vs `torvalds/linux`, which has no stable point releases).
Reuse / extend the mirror from `ndctl-regression-public`.

### Trigger & state

Nightly poll of the mirror for **new** tags in those families; run one
build+boot+test per newly-appeared tag (so each release/rc/stable is tested
once). Per-family state on thing1
(`/home/jenkins/state/famfs_daxmode_regression_public/last_{release,rc,stable}`),
same pattern as `ndctl-regression-public`. (A busy night = a few runs; each is a
full kernel build + qemu boot + 2 tests.)

### ndctl/daxctl userspace (held fixed)

The kernel is the variable, so pin the userspace at a known-good version - a
failure then points at the kernel. Upstream `pmem/ndctl >= v85` supports famfs
mode (**confirmed**), so pin a **fixed upstream release** as the reference (no
need for the jagalactic fork here). Built + rebuilt in the guest exactly as
`ndctl_qemu_test_famfs_local` does (via `ndctlSrc` -> `rq-famfs-autorun.sh`).

### Config strategy (same PRIMARY RISK as ndctl-regression-public)

The famfs config won't map to arbitrary upstream/stable kernels. Reuse the
config-fragment approach: a fragment enabling the needed CONFIG_* -
**`fsdev_dax`** (the famfs dax mode), `DEV_DAX`/`DAX`/`DAX_PMEM`, `ACPI_NFIT`,
`CXL_*` (for cxl_test), `ZONE_DEVICE`, etc. - `merge_config.sh` + `olddefconfig`,
then **assert** the required symbols (missing/`=n` -> red infra failure).

### Fixture

Reuse the back-compat **`kernelRef`** addition planned for
`ndctl-regression-public` (checkout an arbitrary tag / sha, not just a branch).
No further fixture change needed.

### Gating

Match the base job: these two tests are expected to **pass**, so a test failure
is the regression signal -> **red** (no `unstableOnFail`). Kernel-build failure,
boot failure, missing sentinel, or failed config assertion -> also red. Set
`currentBuild.displayName` to the tested kernel tag; archive `tested-ref.txt` +
the usual fixture artifacts.

### Relationship to ndctl-regression-public

This is essentially the **kernel-only, famfs-dax-mode slice** of that plan, plus
**stable point releases**, and minus the ndctl axis / full suite / famfs-OOT.
Building it first delivers the shared pieces - `kernelRef` fixture change, the
config fragment + assertion, and the kernel mirror + tag-watch/state harness -
which `ndctl-regression-public` then reuses.

### Reused vs new components

Reused: `run_qemu_fixture.groovy` (+ `kernelRef`), `rq-famfs-autorun.sh`,
`ndctl_qemu_test_famfs_local` structure, `create-job.sh`, thing1.

New:
- `famfs_daxmode_regression_public.groovy` (nightly trigger + tag selection +
  per-family state + per-tag fixture.call + displayName/artifacts).
- Kernel `.config` fragment (fsdev_dax + dax/nfit/cxl) + assertion helper.
- linux-stable mirror + `/home/jenkins/state/famfs_daxmode_regression_public/`.
- `docs/famfs_daxmode_regression_public.md`.

### Implementation phases

0. **Prereqs:** linux-stable mirror + nightly fetch on thing1; confirm the exact
   `fsdev_dax` lower bound (`v7.1` vs a specific `v7.1-rcN`); required CONFIG_*
   set (incl. `fsdev_dax`).
1. **Fixture:** `kernelRef` (shared with ndctl-regression-public).
2. **Config:** fragment + `merge_config.sh` + required-symbol assertion.
3. **Entrypoint:** cron; tag selection over the three families + per-family
   state; pinned ndctl; per-tag fixture.call with `rq-famfs-autorun.sh`;
   displayName/`tested-ref.txt`. Register via `create-job.sh` + docs.

### Open decisions

- ndctl userspace reference: which upstream `pmem/ndctl` release to pin as
  known-good (confirmed: upstream `>= v85` supports famfs mode).
- Exact kernel lower bound (`v7.1` vs the `-rcN` where `fsdev_dax` landed).
- "Applicable stable" policy: all `>= 7.1` stable series, or only the latest N
  series (to bound how far back stable point releases are chased).
- Catch-up: test each newly-seen tag vs only the newest per family per night.
- Job name (`famfs_daxmode_regression_public` vs `ndctl_qemu_test_famfs_public`).

---

## Shared architecture: tag/branch watcher + parameterized test worker

Both regression jobs above (`ndctl-regression-public` and
`famfs_daxmode_regression_public`) are better built as **one generic watcher
that dispatches to one parameterized worker**, rather than each job embedding its
own tag-watching + build + test. This is the recommended structure for both.

### Worker: parameterized test job

A parameterized generalization of `ndctl_qemu_test_famfs_local`. Does the heavy
lifting for **one** (kernel, ndctl) pair:

- **Params:** `KERNEL_REPO`, `KERNEL_REF`, `NDCTL_REPO`, `NDCTL_REF`,
  `PAYLOAD` (`daxmode` = the `daxctl-famfs-*` tests | `ndctl-suite` = full meson
  suite | `both`).
- Clones kernel@ref + ndctl@ref, generates the `.config` (fragment + assert),
  boots via `run_qemu_fixture` (with `kernelRef`), runs the selected payload.
- **Manually runnable** with any combo, including *local* repos - so it
  subsumes the "manual override" of `ndctl-regression-public` and reproduces
  today's `ndctl_qemu_test_{famfs,all}_local` (which are just
  `linux.git@famfs` x `jagalactic/ndctl@famfs`).
- Sets `currentBuild.displayName` from both refs; archives `tested-refs.txt` +
  the fixture artifacts. No tag-watching or state lives here.

### Watcher: scheduled dispatcher

Lightweight, config-driven, no clone needed just to detect changes:

- A table of watched targets, e.g. kernel = linux-stable
  (releases + rcs + stable `>= v7.1`), ndctl = `pmem/ndctl`
  (releases `>= v85` + branch `main`).
- Poll each with **`git ls-remote`** (tags and the tracked branch SHA) - cheap,
  no working tree. Compare against per-target state on thing1.
- For each newly-seen tag or moved branch tip, **trigger the worker** with the
  right params (Jenkins `build job: 'worker', parameters: [...]`), using the
  hold-one-fixed + tips pairing: new kernel x `N_ref`; new ndctl x `K_ref`;
  `master` x `main` for tips.
- Adding an axis/repo/pattern = a config edit in the watcher, not a new job.
- Only the *worker* needs a real source mirror (for the build); the watcher
  needs only `git ls-remote`.

### Decoupling ndctl from the famfs build  (the key change)

Today `rq-famfs-autorun.sh` runs the `daxctl-famfs-*` tests from `/root/ndctl`,
which `ndctl_qemu_test_famfs_local` gets via `make ndctl` in the *famfs* repo
(= `jagalactic/ndctl@famfs`) - so ndctl is coupled to the famfs build. To make
ndctl a real axis:

- The worker clones ndctl **directly** from `NDCTL_REPO@NDCTL_REF` and passes it
  to the fixture as `ndctlSrc` (not via the famfs build). The **famfs
  user-space repo is not needed for the `daxmode` payload** - those tests live
  in the *ndctl* tree, and the kernel provides `fsdev_dax`.
- **Confirmed:** upstream `pmem/ndctl >= v85` supports famfs mode (the
  `daxctl-famfs-*` mode tests are present upstream). So the ndctl axis can be
  **pure upstream** (releases `>= v85` + `main`) for the `daxmode` payload too -
  no dependency on the jagalactic fork, and no fork-only fallback needed.

### Effect on the two job plans above

`ndctl-regression-public` and `famfs_daxmode_regression_public` collapse into
**payload/config choices of the one worker, dispatched by the one watcher**.
Their goals, scope/lower-bounds, `.config` fragment, and gating notes still
apply; their separate *trigger / state / entrypoint* descriptions are superseded
by this watcher/worker split. Net new components shrink to: the worker groovy,
the watcher groovy (+ its target table + state dir), the shared config fragment,
and `kernelRef`.

### Open decisions

- One worker with a `PAYLOAD` param vs two workers (daxmode vs ndctl-suite).
- Watcher cadence: nightly vs more frequent (`ls-remote` is cheap, but each
  dispatched worker run is a full kernel build+boot).
- Where "hold-one-fixed + tips" pairing lives: in the watcher (recommended) so
  the worker stays a dumb "test exactly this pair".
