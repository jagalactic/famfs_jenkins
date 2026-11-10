# run_qemu build infrastructure (thing1)

How the run_qemu jobs (`smoke_qemu_*`, `ndctl_qemu_*`, `ndctl_regression_public`)
are laid out on the build agent **thing1**, and why. All of them boot the guest
through `groovy/run_qemu_fixture.groovy`. For VM sizing (vCPUs/memory/dax) see
[run_qemu_vm_resources.md](run_qemu_vm_resources.md); this doc is about **disk,
caching, and the kernel mirror**.

## The hard constraint: a small root fs

thing1's filesystems:

| mount | size | role |
|-------|------|------|
| `/` (root) | **50 GB** | OS. **Nothing build-related may fill it.** |
| `/home` | **~1.5 TB** (local xfs) | all build state lives here |
| `/tmp` | 237 GB tmpfs | not used for builds |

thing1 has **8 executors**. mkosi (which builds the guest rootfs) defaults its
workspace to `/var/tmp` on the 50 GB root fs; 8 concurrent builds each stage a
~5 GB Fedora rootfs there and **exhaust `/`** (`dnf5 "needs more space on the /
filesystem"` -> `make_rootfs` fails). So everything heavy is deliberately pinned
to `/home`.

## Per-job / per-executor layout under /home

`run_qemu_fixture` keeps build state **outside** the Jenkins workspace (so
root-owned mkosi files don't break the next SCM checkout) and **per executor**
(so concurrent builds of the same job don't collide):

```
/home/jenkins/rq-build/<JOB_NAME>/exec<N>/qbuild        run_qemu builddir (mkosi.cache = image cache, kernel staging)
/home/jenkins/rq-build/<JOB_NAME>/exec<N>/mkosi-ws       mkosi WorkspaceDirectory (transient rootfs staging) -- SIBLING of qbuild
/home/jenkins/rq-build/pkgcache                          shared mkosi PackageCacheDirectory (downloaded RPMs) -- all execs+jobs
/home/jenkins/thing1/workspace/<JOB_NAME>[@N]/linux-rq   persistent kernel tree (incremental builds)
/home/jenkins/git/linux-mirror.git                       bare kernel mirror (see below)
```

Key points:
- **mkosi workspace is relocated off `/`** via a `mkosi.local.conf` the fixture
  writes into `qbuild` (`[Build] WorkspaceDirectory=<exec>/mkosi-ws`). run_qemu
  regenerates `mkosi.conf`/`mkosi.conf.d` but leaves `mkosi.local.conf` alone,
  and mkosi reads it last (wins). It must be a **sibling** of `qbuild`, not a
  child - mkosi rejects a workspace nested under a build source.
- **Shared package cache** (`PackageCacheDirectory`): one RPM/metadata cache for
  all executors and jobs, so a package is pulled over WAN once, not per executor.
  dnf locks it, so concurrent access is safe. (The incremental *image* cache
  stays per-executor in each `qbuild/mkosi.cache`.)
- **Kernel staging is purged each build:** run_qemu drops the built kernel into
  `qbuild/mkosi.extra/boot` but never removes the previous one; the fixture
  clears stale `vmlinuz-*`/`*.efi`/`initramfs-*` so accumulated UKIs don't
  overflow the vfat ESP.

## The kernel mirror (`/home/jenkins/git/linux-mirror.git`)

A bare `git clone --mirror` of the linux-**stable** tree (a superset of Linus'
tree: mainline `vX.Y` + `-rcN` tags **and** stable `vX.Y.Z` tags, `master`
tracks mainline). `ndctl_regression_public` clones the kernel from it instead of
the network:

- Same filesystem as the workspace, so `git clone <mirror> linux-rq`
  **hardlinks** the object store - near-instant, minimal disk (vs a full
  multi-GB network clone per executor). Pre-existing full-copy `linux-rq` trees
  just `fetch` from the mirror (still local/offline); wipe them to bank the
  hardlink dedup.
- **Public fallback:** if a requested ref isn't in the mirror yet (it's
  refreshed daily), the fixture fetches that ref from `KERNEL_REPO` (the public
  URL) before checkout, so a build never fails on mirror lag.
- Refreshed daily by `scripts/update-kernel-mirror.sh` +
  `systemd/kernel-mirror-update.*` (03:00, over ssh from the controller; also
  rewrites the commit-graph). The smoke jobs use a **separate** push-populated
  `/home/jenkins/git/linux.git` (famfs dev branches), unchanged.

## Ownership / cleanup gotchas

- mkosi runs privileged, so `/home/jenkins/rq-build/**` and the mkosi caches are
  **root-owned** - fine, because they're outside the Jenkins workspace so the
  SCM checkout never touches them. (Inside the workspace, root-owned files break
  the next checkout; that's why buildDir/mkosi-ws live outside it.)
- After an in-place JDK upgrade on thing1, the long-running agent JVM must be
  restarted (`sudo systemctl restart jenkins-agent.service`) or every step fails
  with `Failed to exec spawn helper`.
