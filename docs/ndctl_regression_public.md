# ndctl_regression_public

The **automated upstream regression** job: build ONE kernel, boot it under
run_qemu with the emulated `nfit_test` + `cxl_test` backends, and run the
**ndctl** meson suite (nfit + dax + cxl) against **several ndctl versions in that
single boot**. It catches regressions in the mainline nvdimm / dax / cxl
subsystems as either the kernel or ndctl moves. It is the parameterized
generalization of `ndctl_qemu_test_all_local`, and the first job driven
end-to-end by a watcher + timer (no human in the loop).

Testing multiple ndctl versions per boot **amortizes the expensive work** - the
kernel compile, the in-tree `nfit_test`/`cxl_test` modules, the rootfs, and the
boot are all done once and shared; only the (cheap) ndctl `meson` build+test
repeats per version.

## Two pieces: watcher and worker

```
scripts/ndctl-regression-watch.sh   (controller-side, daily timer)
        | polls upstream, dispatches buildWithParameters
        v
ndctl_regression_public  (the Jenkins job / worker, groovy/ndctl_regression_public.groovy)
        | node('run_qemu') on thing1 -> run_qemu_fixture
        v
guest: scripts/autorun/rq-ndctl-autorun.sh  -> per ndctl ref: meson test (ndctl+dax+cxl)
```

Each ndctl ref is rsync'd into the guest at `/root/ndctl-<ref>` via run_qemu's
`guest_srcs=` (a repeatable labeled-source env we added to the fork). The autorun
loops those, bracketing each with `===RQ_SECTION ndctl-<ref>===` and emitting
`RQ_NDCTL_RESULT ref=<ref> rc=<n>`, so the worker splits per-ref logs and
attributes failures. The emulated buses are reloaded between refs for a clean
slate.

### Worker parameters (`groovy/ndctl_regression_public.groovy`)

| param | default | meaning |
|-------|---------|---------|
| `KERNEL_REPO` | stable tree URL | authoritative kernel repo (fallback + recorded) |
| `KERNEL_REF`  | `master` | tag / branch / sha to build (e.g. `v7.2`, `v7.1.5`, `v7.3-rc1`) |
| `NDCTL_REPO`  | `github.com/pmem/ndctl.git` | ndctl repo |
| `NDCTL_REFS`  | `pending v85` | **space-separated** ndctl refs to test in one boot (tags `vN`, branches `pending`/`main`, or shas) |

The kernel is **hardlink-cloned from the local mirror** (`kernelMirror=
/home/jenkins/git/linux-mirror.git`), not the network - see
[run_qemu_build_infra.md](run_qemu_build_infra.md). `KERNEL_REPO` is the public
fallback for a ref not yet in the mirror. Each ndctl ref in `NDCTL_REFS` is
cloned from `NDCTL_REPO` (one network clone + fast local per-ref clones) and
built+tested in-guest (run_qemu's own ndctl build is disabled via
`--no-ndctl-build`). The config is a run_qemu-compatible base
(`configs/famfs_qemu_ndctl.config`) + the nvdimm/dax/cxl fragment
(`configs/ndctl_regression.fragment`), and `assertConfig` fails the build loudly
if `make olddefconfig` drops a required symbol.

### Per-ref results and weighted notification

- **Build status:** UNSTABLE if any ndctl ref's suite fails (overall sentinel),
  FAILURE only for build/boot/infra breakage.
- **displayName** summarizes at a glance: `k:v7.3-rc1 [pending:OK v85:OK]`;
  per-ref logs `ndctl-<ref>.log` + `test-results.txt` are archived.
- **Weighted email** (avoids alert fatigue on moving branches):
  - **release-grade** failure - the kernel is a version tag **and** a released
    ndctl (`vN`) failed -> **loud** email (real regression).
  - **tip-grade** failure - anything on kernel-`master`, or `pending`/`main` ->
    quiet email, `[tip]` subject prefix (option (c), new-failure-only, is a
    planned refinement).
  - all pass -> no email.

### Watcher (`scripts/ndctl-regression-watch.sh`)

Polls the kernel and ndctl repos with `git ls-remote` (no clone), notices new
tags / branch-tip movement, and dispatches **one build per kernel** against an
ndctl **SET** = the `pending` branch + the last `NDCTL_KEEP` (default **2**)
releases (`>= NDCTL_MIN`):

```
new kernel tag    -> (that kernel)   x (ndctl SET, e.g. "pending v85")
new ndctl release -> (K_ref)         x (ndctl SET, incl. the new release)
master/pending moved, or idle day -> (Linus' master) x (pending only)
```

**Dispatch policy (current):** kernel tags matching `vX.Y`, `vX.Y-rcN`, **and**
stable point releases `vX.Y.Z`, with `MAJOR.MINOR >= KERNEL_MIN` (default
**7.1**); the ndctl SET is `pending` + the last `NDCTL_KEEP` releases `vN` with
`N >= NDCTL_MIN` (default **85**, nothing older). Kernel-`master` runs test
`pending` **only** (the noisy tip stays lean); `HEARTBEAT=1` guarantees a
`master x pending` datapoint even on a fully idle day. To test mainline kernels
only, drop `.Z` from `kernel_tags()`.

Tags come from the linux-stable tree (`KERNEL_REPO`): it carries every mainline
`vX.Y` / `vX.Y-rcN` tag plus the `.Z` point releases. The **tip** is a different
matter: linux-stable's `master` is a re-merge of mainline that trails Linus by
hours to days, so the `master` sha is polled from, and the master/heartbeat
builds are dispatched with, Linus' tree (`MAINLINE_REPO`,
`torvalds/linux.git`). The worker's fixture fetches that branch from that repo
rather than resolving it against the local mirror (which follows linux-stable).

Dedup is by set-difference against a small state dir (`~/.ndctl-regression-watch/`);
the **first run only baselines** (records current refs, dispatches nothing), so a
tag is built only once and only if it appears *after* the baseline. Idempotent
and non-interactive. Reads the Jenkins API token from `api-key.md`.

## Scheduling

Two controller-side systemd timers, ordered so new tags are mirrored before the
watcher dispatches (the fixture also has a public fallback if the mirror lags):

```
kernel-mirror-update.timer   03:00   -> git remote update --prune (ssh thing1)
ndctl-regression-watch.timer 04:00   -> poll + dispatch
```

## Gating and notification

- `unstableOnFail: true` -> a **test** failure is **UNSTABLE** (yellow); only
  build/boot/infra breakage is **FAILURE** (red).
- The job **emails** `NOTIFY_EMAIL` (from `site.conf`, baked in by `create-job.sh`) on **both** UNSTABLE and FAILURE
  (via the `mail` step / authenticated Mailer account) - notifying only on
  FAILURE would miss real test regressions, which land as UNSTABLE.
- Records: Jenkins keeps per-build result + console + `tested-refs.txt`
  (resolved shas) + the archived logs. The watcher keeps no result history.

## Run it manually

```sh
# Build-with-Parameters (UI), or:
T=$(tr -d ' \t\r\n' < api-key.md); J=http://jenkins-server:8080
CR=$(curl -sS -u "jmg:$T" "$J/crumbIssuer/api/json" | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p')
curl -sS -X POST -u "jmg:$T" -H "Jenkins-Crumb:$CR" \
  --data-urlencode KERNEL_REF=v7.3-rc1 --data-urlencode "NDCTL_REFS=pending v85" \
  "$J/job/ndctl_regression_public/buildWithParameters"

# dry-run the watcher (no dispatch, no state change):
scripts/ndctl-regression-watch.sh -n
```

> Note: re-registering the job (`create-job.sh`) writes empty `<properties/>`,
> which **resets the Build-with-Parameters UI** until one build runs the
> `properties([parameters...])` block. See [README.md](../README.md).

## Deploy

Entrypoint change -> re-register (`JOB=ndctl_regression_public JENKINS_USER=jmg
scripts/create-job.sh`). Library/config/autorun change -> push to gh. Watcher /
mirror units -> install under `/etc/systemd/system/` (see README).
