# famfs_dbg_regression_public / famfs_rel_regression_public

The **famfs-against-public-kernels regression** jobs. There are two, identical
except for how famfs is built (see [Debug and release jobs](#debug-and-release-jobs)):

| job | famfs build | smoke | unit tests |
|-----|-------------|-------|------------|
| `famfs_dbg_regression_public` | `make debug` (`-O0 -ggdb`) | `run_smoke.sh --fuse` | `ctest` in `debug/` |
| `famfs_rel_regression_public` | `make release`, optimized, `NDEBUG` | `run_smoke.sh --fuse --release` | `ctest` in `release/` |

Each one does this: build ONE public kernel,
boot it under run_qemu with the emulated `nfit_test` backend, and build +
smoke-test (`--fuse`) + unit-test **several famfs versions in that single
boot**. It is the mashup of [ndctl_regression_public](ndctl_regression_public.md)
(public kernel refs, N payload versions per boot, per-ref attribution, weighted
mail, watcher + timer) and [smoke_qemu_nfit_local](smoke_qemu_nfit_local.md)
(the famfs smoke/unit payload on a 6G nfit devdax with real DRAM backing).

famfs enablement is not upstream yet: the kernel side goes through three
phases, and the watcher picks the phase automatically:

| phase | kernel under test | when |
|-------|-------------------|------|
| `premerge` | Miklos' pull-request tag `fuse-update-7.4` in `mszeredi/fuse.git`, nightly | until that tag is an ancestor of mainline master |
| `master`   | Linus' master (`torvalds/linux.git`), nightly | merged, but no `v7.4*` tag yet |
| `tags`     | every new `vX.Y`, `vX.Y-rcN`, `vX.Y.Z` tag with X.Y >= `KERNEL_MIN` (7.4); master as the idle heartbeat | from `v7.4-rc1` on |

Public kernels carry famfs **only in fuse mode** (no `fs/famfs` v1 module), so
the autorun runs `run_smoke.sh --fuse` + `ctest` and skips `--nofuse` by design.
A kernel with no famfs fuse ABI at all (no `fuse_backing_is_dax` /
`famfs_fuse_iomap_begin` in kallsyms) is reported per ref as `NOSUPPORT`
(rc 121), not as a test failure.

## Two pieces: watcher and worker

```
scripts/famfs-regression-watch.sh   (thing1, daily timer 04:30)
        | polls upstream, picks the phase, dispatches buildWithParameters
        v
famfs_dbg_regression_public, famfs_rel_regression_public
        | (the Jenkins jobs / workers: thin entrypoints over groovy/famfs_regression.groovy)
        | node('run_qemu') on thing1 -> run_qemu_fixture
        v
guest: scripts/autorun/rq-famfs-regression-autorun.sh
        -> per famfs ref: make debug | make release (as .famfs-build-type says),
           run_smoke.sh --fuse [--release], ctest
```

Each famfs ref is cloned on the host and **prepared with `make all`** there (the
guest has no network, so every subrepo - ndctl, libfuse, cmake-modules,
C-Thread-Pool, mongoose - must already be present), then rsync'd into the guest
at `/root/famfs-<ref>` via run_qemu's `guest_srcs=`. The autorun loops those,
bracketing each phase with `===RQ_SECTION famfs-<ref>.<phase>===`
(`build`, `smoke-fuse`, `unit`) and emitting `RQ_FAMFS_RESULT ref=<ref> rc=<n>`,
so the worker splits per-ref logs (`famfs-<ref>.<phase>.log`) and attributes
failures.

**libfuse branch:** pinned per job by `LIBFUSE_REF` (**`famfs.extmap`** while
famfs support lives on that branch of `jagalactic/libfuse`; switch the default
to `master` or a release tag once it lands upstream). It is deliberately *not*
derived from the kernel under test: the famfs Makefile only does that for a
fresh clone, and the host that prepares the tree has no famfs kernel. run_qemu
copies guest trees **without `.git/`** (and without `build/`), so the host
checks the pinned ref out in `./libfuse` before the copy, records it in
`.libfuse-ref` (and the famfs sha in `.famfs-sha`), and drops `debug/`; the
guest's build uses the checkout as is. A kernel/libfuse ABI mismatch
shows up as a smoke failure, which is the signal a pinned-branch job should
give.

### Debug and release jobs

Both jobs are thin entrypoints (`groovy/famfs_dbg_regression_public.groovy`,
`groovy/famfs_rel_regression_public.groovy`) that call the shared worker
`groovy/famfs_regression.groovy` with `buildType: 'debug'` or `'release'`. The
worker records the choice in each prepared tree as `.famfs-build-type`, and the
autorun builds and tests accordingly. Everything else (kernel, config, famfs
refs, libfuse pin, attribution, mail) is the same code, and the watcher
dispatches both with the same parameters, so a failure in only one of them is
specific to that build type.

**What "release" means.** famfs' `release` Makefile target runs cmake with no
`CMAKE_BUILD_TYPE`, which gives an unoptimized build with asserts still
enabled - little different from debug. The release job therefore exports
`CMAKE_BUILD_TYPE` (job parameter `RELEASE_CMAKE_BUILD_TYPE`, default
`RelWithDebInfo` = `-O2 -g -DNDEBUG`) while the guest runs `make release`;
cmake (>= 3.22) uses the environment value as the default when the command line
sets none. That is what exposes the bugs a debug build hides: asserts compiled
out, optimizer-sensitive undefined behaviour, uninitialized variables. Set the
parameter to `Release` for `-O3`, or empty to test exactly what the ref's own
`make release` produces. The build section of the log prints the
`CMAKE_BUILD_TYPE` and `C_FLAGS` actually used. If famfs' `release` target
later sets a build type itself, that wins and the parameter becomes a no-op.

Each job has its own workspace, so each keeps its own incremental kernel tree.

### Worker parameters (`groovy/famfs_regression.groovy`)

| param | default | meaning |
|-------|---------|---------|
| `KERNEL_REPO` | Linus' tree URL | authoritative kernel repo, so `master` means mainline; the stable tree for `vX.Y.Z` tags, Miklos' `mszeredi/fuse.git` for a `fuse-update-*` tag |
| `KERNEL_REF`  | `master` | tag / branch / sha to build (e.g. `fuse-update-7.4`, `v7.4-rc1`, `v7.4.2`) |
| `FAMFS_REPO`  | `file:///home/jenkins/git/famfs.git` | famfs repo (the thing1 mirror smoke_local tests) |
| `FAMFS_REFS`  | `master` | **space-separated** famfs refs to test in one boot (branches, release tags `vX.Y`, or shas) |
| `LIBFUSE_REF` | `famfs.extmap` | libfuse branch/tag/sha famfs is built against, pinned for the job (see below) |
| `RELEASE_CMAKE_BUILD_TYPE` | `RelWithDebInfo` | release job only: `CMAKE_BUILD_TYPE` exported for `make release`; empty = no override |

The kernel is **hardlink-cloned from the local mirror** (`kernelMirror=
/home/jenkins/git/linux-mirror.git`); a ref the mirror lacks (Miklos' tag, or a
brand-new mainline tag) is fetched from `KERNEL_REPO` by the fixture. The config
is the run_qemu base (`configs/famfs_qemu_ndctl.config`) + the nfit/dax/fuse
fragment (`configs/famfs_regression.fragment`); `assertConfig` fails the build
loudly if `make olddefconfig` drops `FUSE_FS`, `FUSE_PASSTHROUGH` (which carries
`fs/fuse/ext_map.o` + `backing.o` in the 7.4 pull request) or the nfit/dax set.
`disableConcurrentBuilds()` keeps one run_qemu kernel build at a time per job.

### Per-ref results and weighted notification

- **Build status:** UNSTABLE if any famfs ref fails (or is `NOSUPPORT`), FAILURE
  only for build/boot/infra breakage.
- **displayName:** `k:fuse-update-7.4 [master:OK]`; per-ref verdicts are `OK`,
  `FAIL`, `NOSUPPORT` (121), `BUILDFAIL` (122), `NODAX` (123, nfit devdax setup
  failed), `?` (no result line).
- **Weighted email**, same rule as ndctl: a version-tag kernel **and** a released
  famfs (`vX.Y*`) failing, or infra failing on a tag kernel -> **loud**; anything
  failing on Miklos' tag, master, or famfs master -> quiet `[tip]` note; all
  pass -> no email.

### Watcher (`scripts/famfs-regression-watch.sh`)

Polls with `git ls-remote` (no clone). The famfs **SET** tested against each
kernel is `master` + the last `FAMFS_KEEP` (default **2**) release tags `vX.Y`
with X.Y >= `FAMFS_MIN`. `FAMFS_MIN` is **empty until the first famfs release is
cut**, so today the set is just `master`; set it (e.g. `FAMFS_MIN=1.0`, via an
`Environment=` line in the .service) when releases start.

```
premerge/master phase:  nightly       -> (phase's tip kernel) x (famfs SET)
tags phase: new kernel tag             -> (that kernel)        x (famfs SET)
            nothing new (heartbeat)    -> (kernel master)      x (famfs SET)
any phase:  new famfs release          -> (newest kernel release, else the tip) x (SET incl. the release)
```

The **merge check** needs commits: Linus' master (`MAINLINE_REPO`) and then
the PR ref are fetched into the local mirror's `FETCH_HEAD` (objects only, no
ref, so the mirror's daily `--prune` refresh has nothing to fight with) and
tested with `merge-base --is-ancestor`. Linus' tree, not the mirror's own
linux-stable `master`, which trails it by hours to days; the `master` phase and
the tags-phase heartbeat build Linus' master for the same reason (the fixture
fetches a branch of a non-mirror repo from that repo). No mirror or no such
ref -> "not merged".
Phase transitions are logged (`phase: premerge -> master`) and the current
phase is kept in the state dir.

Dedup is by set-difference against `~/.famfs-regression-watch/`; the **first run
baselines the tag lists** (no tag flood) but still dispatches the nightly tip
build. Idempotent and non-interactive. Reads the Jenkins API token from
`api-key.md`.

## Scheduling

```
kernel-mirror-update.timer    03:00  -> mirror refresh (ssh thing1)
ndctl-regression-watch.timer  04:00  -> ndctl_regression_public
famfs-regression-watch.timer  04:30  -> famfs_dbg_regression_public + famfs_rel_regression_public
```

All the regression workers run on thing1's `run_qemu` agent.

## Run it manually

```sh
# Build-with-Parameters (UI), or:
T=$(tr -d ' \t\r\n' < api-key.md); J=http://jenkins-server:8080
CR=$(curl -sS -u "jmg:$T" "$J/crumbIssuer/api/json" | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p')
curl -sS -X POST -u "jmg:$T" -H "Jenkins-Crumb:$CR" \
  --data-urlencode KERNEL_REPO=https://git.kernel.org/pub/scm/linux/kernel/git/mszeredi/fuse.git \
  --data-urlencode KERNEL_REF=fuse-update-7.4 --data-urlencode "FAMFS_REFS=master" \
  "$J/job/famfs_dbg_regression_public/buildWithParameters"    # or famfs_rel_...

# dry-run the watcher (no dispatch, no state change):
scripts/famfs-regression-watch.sh -n
```

> Note: the parameters are declared by the shared worker at run time, so a
> **newly created** job has none until its first build has run; start that one
> with a plain build (it uses the defaults: Linus' master x famfs master).
> `create-job.sh` carries existing parameter definitions over on an update.

## Deploy

1. Push this repo to gh (the worker loads the fixture, autorun, fragment and
   watcher from master at runtime).
2. Register both jobs: `JOB=famfs_dbg_regression_public JENKINS_USER=jmg
   scripts/create-job.sh`, then the same with `famfs_rel_regression_public`
   (`-n` first for the diff).
3. Run each once by hand (a plain build; it registers the parameters) to shake
   out the config fragment / libfuse pin on the first real build.
4. Install the timer: `sudo cp systemd/famfs-regression-watch.{service,timer}
   /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl
   enable --now famfs-regression-watch.timer`.
5. Add `"famfs_dbg_regression_public": (48, False)` (and the `rel` one) to `EXPECTED_JOBS` and
   `famfs-regression-watch.timer` to `LOCAL_TIMERS` in `scripts/jenkins-watchdog`
   so a silent stop is reported (the watchdog runs from this checkout, so do
   this after steps 2 and 4 or it will complain daily until then).
