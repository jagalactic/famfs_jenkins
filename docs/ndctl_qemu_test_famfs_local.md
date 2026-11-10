# ndctl_qemu_test_famfs_local

## Code under test

| Component | Repo / source | Ref |
|-----------|---------------|-----|
| **ndctl** (the code under test) | `jagalactic/ndctl` (via famfs `make all`) | branch **`famfs`** |
| Kernel | `/home/jenkins/git/linux.git` | branch **`famfs`** |
| Kernel `.config` | `configs/famfs_qemu_ndctl.config` | — |

Runs the **daxctl famfs mode-transition tests** (`daxctl-famfs-nfit.sh`,
`daxctl-famfs-cxltest.sh`) from that ndctl — the V5/V6 daxctl-famfs-mode work's
coverage. See [README.md](README.md) for the shared agent, fixture, artifacts.

## Flow

Entrypoint `ndctl_qemu_test_famfs_local.groovy`:

1. `stage('build famfs ndctl')` - clone famfs, `make all` (pulls
   `jagalactic/ndctl@famfs` into `famfs/ndctl`).
2. `fixture.call(...)` with `ndctlSrc: famfs/ndctl`,
   `runQemuArgs: '--nfit-test --cxl-test'`, `autorunScript: rq-famfs-autorun.sh`.

In the guest, `rq-famfs-autorun.sh` modprobes `nfit_test`/`fsdev_dax`/`kmem`,
does a fresh test-enabled meson build of `/root/ndctl`, runs the two tests, and
prints the sentinel `RQ_FAMFS_RESULT rc=<n>`.

## Gating

Default (no `unstableOnFail`): any test failure or a missing sentinel **fails**
the build (red). Last known-good run: **rc=0** (both tests pass).

## Deploy / run

```sh
JOB=ndctl_qemu_test_famfs_local JENKINS_USER=jmg scripts/create-job.sh
```
