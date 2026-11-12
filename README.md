# famfs_jenkins

Jenkins CI configuration for famfs: pipeline scripts, the jobs' host/guest
helper scripts, saved kernel configs, systemd units, and docs.

## Layout

```
groovy/            Jenkins pipeline scripts:
                   - job entrypoints (job-named, e.g. smoke_qemu_nfit_local.groovy)
                     -> INLINED into each Jenkins job by scripts/create-job.sh
                   - loaded libraries (run_qemu_fixture.groovy, coverage.groovy,
                     smoke.groovy, sanitize.groovy, valgrind.groovy, coverage_unit.groovy,
                     fail.groovy) -> loaded at runtime via load 'groovy/<x>.groovy'
scripts/           host/ops shell scripts (create-job, fix_kernels, chk_kernels,
                   cleanup-jenkins-builds, ndctl-regression-watch, update-expected-kernel,
                   register-all-jobs, ...) + test-summary.awk
scripts/autorun/   guest-side scripts run INSIDE the run_qemu VM (rq-*-autorun.sh),
                   referenced by the qemu job entrypoints as ${WORKSPACE}/scripts/autorun/...
systemd/           service + timer units (famfs-fix-kernels, jenkins-agent, ...)
configs/           kernel .config + fragments, rq-ci-cmdline (kernel cmdline), nodes.txt
docs/              per-job docs + references (run_qemu_vm_resources.md, jenkins-plans.md, ...)
api-key.md         Jenkins API token (gitignored; kept at repo root)
site.conf          site-specific settings, e.g. NOTIFY_EMAIL (gitignored; copy
                   site.conf.example)
```

## Deploy model (important)

Two different mechanisms, so a change reaches Jenkins two different ways:

- **Job entrypoints are INLINED** into each Jenkins job's config by
  `scripts/create-job.sh` (`JOB=<name>`). Editing `groovy/<job>.groovy` only
  takes effect after **re-running create-job.sh** for that job.
- **Libraries, autoruns, and configs are read at RUNTIME** from the GitHub
  clone: an entrypoint does `git url: ...famfs_jenkins` then
  `load 'groovy/run_qemu_fixture.groovy'` and references
  `${WORKSPACE}/scripts/autorun/...` / `${WORKSPACE}/configs/...`. Editing those
  only takes effect after a **`git push` to GitHub master**.

So after moving files or changing an entrypoint: **push, then re-register the
jobs** with `scripts/register-all-jobs.sh` (re-inlines every existing job whose
entrypoint is `groovy/<job>.groovy`).

**Triggers live in the entrypoint, not the Jenkins UI.** `create-job.sh`
rebuilds the whole job config, so a UI-only cron/poll trigger is lost on
re-register (this silently stopped every nightly `*_local` job on 2026-09-04).
Declare the schedule at the top of the entrypoint:

```groovy
properties([pipelineTriggers([cron('H 4 * * *')])])
```

`create-job.sh` mirrors every `cron(...)`/`pollSCM(...)` it finds into the
config.xml (so the trigger is live immediately), carries an existing
parameters block over, and **refuses** to update a job whose live config has
trigger specs the entrypoint does not declare (`FORCE=1` overrides). Use
`-n` (also via `register-all-jobs.sh -n`) to diff live vs new config first.

## Common commands

```sh
# create / update one job from its entrypoint
JENKINS_USER=jmg JOB=smoke_qemu_nfit_local scripts/create-job.sh

# re-register every existing job (after a reorg / entrypoint change)
JENKINS_USER=jmg scripts/register-all-jobs.sh -n   # dry-run
JENKINS_USER=jmg scripts/register-all-jobs.sh

# watch upstream and dispatch the regression worker
scripts/ndctl-regression-watch.sh -n               # dry-run
# prune old builds so the controller disk doesn't fill
scripts/cleanup-jenkins-builds.sh -n               # dry-run
# test a lore patch/series (b4) through famfs_dbg_regression_public + ndctl_regression_public
scripts/b4-test-patch.sh -n <msgid-or-lore-url>    # dry-run; see docs/b4-test-patch.md
```

## Automated regression (systemd)

The `ndctl_regression_public` job runs unattended via **two** controller-side
timers (installed as `jmg` against this checkout, like `famfs-fix-kernels`),
ordered so new upstream tags are mirrored before the watcher dispatches:

```sh
sudo cp systemd/kernel-mirror-update.{service,timer} \
        systemd/ndctl-regression-watch.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kernel-mirror-update.timer ndctl-regression-watch.timer
systemctl list-timers 'kernel-mirror-update.timer' 'ndctl-regression-watch.timer'
journalctl -u ndctl-regression-watch.service -e        # dispatch logs
# baseline / test one cycle by hand (first run only records state, no dispatch):
sudo systemctl start ndctl-regression-watch.service
```

- `kernel-mirror-update.timer` (**03:00**) -> `git remote update --prune` on the
  bare kernel mirror on thing1 (over ssh) + refresh commit-graph.
- `ndctl-regression-watch.timer` (**04:00**) -> poll upstream, dispatch the
  worker for new kernel/ndctl tags (`.Z` stable releases included, floor
  `KERNEL_MIN=7.1`) and tip movement. First run baselines (no dispatch).

The watched repos, version floors, and `WATCH_*` toggles are the config block at
the top of `ndctl-regression-watch.sh`. See
[docs/ndctl_regression_public.md](docs/ndctl_regression_public.md) for the
watcher/worker flow and [docs/run_qemu_build_infra.md](docs/run_qemu_build_infra.md)
for the kernel mirror, mkosi/buildDir layout, and package cache on thing1.

`famfs_dbg_regression_public` and `famfs_rel_regression_public` (the debug and
the release build of famfs; one shared implementation,
`groovy/famfs_regression.groovy`) are the same shape for **famfs against public
kernels**: `famfs-regression-watch.timer` (**04:30**) runs
`scripts/famfs-regression-watch.sh`, which picks the kernel phase itself
(Miklos' `fuse-update-7.4` tag until it is merged, then mainline master nightly,
then every `v7.4+` tag) and dispatches both workers with a famfs set of `master`
plus the last two releases once `FAMFS_MIN` is set. Install it the same way
(`systemd/famfs-regression-watch.{service,timer}`); see
[docs/famfs_regression_public.md](docs/famfs_regression_public.md).

### Watchdog (jenkins-watchdog) + failure mail

Jenkins only mails on a FAILED build; a job that stops being scheduled, an
agent that drops off, a stuck queue, or a full controller disk are silent.
`scripts/jenkins-watchdog` runs daily at **09:00** from `jenkins-watchdog.timer`
on thing1 (independent of Jenkins) and mails `NOTIFY_EMAIL` (from `site.conf`) via the
local msmtp when something is wrong, plus an "all OK" heartbeat on Mondays
so a dead watchdog is itself noticed. It checks: every job in its
`EXPECTED_JOBS` table ran within its max age and still has a trigger, the last
result is not FAILURE, no agent is offline (unless marked temporarily offline),
nothing is queued > 6h, controller root fs < 85%, and the local
`jenkins-agent.service` + the CI timers are healthy.

The timer services (`ndctl-regression-watch`, `kernel-mirror-update`,
`dax-regression-ledger`, `jenkins-watchdog`) carry
`OnFailure=status-email@%n.service`, which mails the failed unit's journal tail
(`scripts/systemd-status-email`).

```sh
sudo cp systemd/status-email@.service systemd/jenkins-watchdog.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now jenkins-watchdog.timer
scripts/jenkins-watchdog -n            # print the report, no mail
scripts/jenkins-watchdog --mail-test   # mail it even if all is OK
```

Edit the `EXPECTED_JOBS` table in the script when adding/removing nightly jobs.

### Dashboard (dax-regression-ledger)

`scripts/dax-regression-ledger` collects each completed `ndctl_regression_public`
build into a durable JSONL ledger (`~jmg/.dax-regression-ledger/ledger.jsonl`) that
**outlives Jenkins build pruning**, and renders a kernel x ndctl dashboard (a
coverage matrix + a chronological log with resolved commit shas) to Jenkins
userContent: **http://jenkins-server:8080/userContent/dax-regression-ledger.html**.
A third timer runs it hourly:

```sh
sudo cp systemd/dax-regression-ledger.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now dax-regression-ledger.timer
scripts/dax-regression-ledger -n     # dry-run: what it would collect, no write/publish
```
