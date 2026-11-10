# ndctl_qemu_test_all_local

## Code under test

| Component | Repo / source | Ref |
|-----------|---------------|-----|
| **ndctl** (the code under test) | `jagalactic/ndctl` (cloned fresh per build) | branch **`famfs`** |
| Kernel | `/home/jenkins/git/linux.git` | branch **`famfs`** |
| Kernel `.config` | `configs/famfs_qemu_ndctl.config` | — |

Runs **as much of the ndctl test suite as possible** against that ndctl - meson
suites `ndctl` + `dax` + `cxl` (~53 tests, `-Dtest=enabled -Ddestructive=enabled`)
on the nfit_test + cxl_test emulated backends. A broad-coverage regression job.
See [README.md](README.md) for the shared agent, fixture, artifacts.

## Flow

Entrypoint `ndctl_qemu_test_all_local.groovy`: `stage('fetch ndctl')` does
`git clone -b famfs https://github.com/jagalactic/ndctl.git`, then
`fixture.call(...)` with `runQemuArgs: '--nfit-test --cxl-test'`,
`timeoutMin: 90`, `autorunScript: rq-ndctl-autorun.sh`, `unstableOnFail: true`.

`rq-ndctl-autorun.sh` loads the mock modules, does a fresh test+destructive
meson build of `/root/ndctl`, runs the full suite, dumps the testlog, and prints
`RQ_NDCTL_RESULT rc=<meson-rc>`. A `meson setup`/`compile` failure exits without
a sentinel (so it reads as infra failure, not a test result).

## Gating (`unstableOnFail: true`)

- **Red (FAILURE):** missing sentinel, or the suite couldn't build/run.
- **Yellow (UNSTABLE):** the suite ran but some tests failed (`rc != 0`).
- **Green:** all tests passed.

A max-coverage suite will have some environment-dependent failures, so UNSTABLE
is expected; read `test-summary.txt` for the per-test breakdown.

## Known status

Last run: **UNSTABLE - 49 PASS / 2 FAIL / 2 SKIP**. Failures:

- `cxl / cxl-translate.sh` - **SIGSEGV** (a crash; worth investigating).
- `cxl / cxl-elc.sh` - exit 1.

Skips (meson code 77): `ndctl / libndctl`, `cxl / cxl-features.sh`.

## Deploy / run

```sh
JOB=ndctl_qemu_test_all_local JENKINS_USER=jmg scripts/create-job.sh
```
