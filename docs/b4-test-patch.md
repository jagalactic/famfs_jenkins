# b4-test-patch: run a lore patch through the famfs / dax CI

`scripts/b4-test-patch.sh` takes a patch or series from lore (by message-id
or lore URL), applies it on a kernel base, publishes the result as a branch
the run_qemu workers can fetch, and dispatches the existing
[famfs_dbg_regression_public](famfs_regression_public.md) (famfs over fuse on an
nfit devdax) and/or [ndctl_regression_public](ndctl_regression_public.md)
(ndctl + dax unit tests) jobs at that branch. No new Jenkins job: these are
the nightly workers with `KERNEL_REPO`/`KERNEL_REF` pointed at the patched
tree, so the results, logs and email rules are the ones you already know.

```sh
# the Nov 6 DAX truncate fix, famfs + ndctl, on Linus' master
scripts/b4-test-patch.sh 20261106-fix-dax-invalidate-mapped-v1-1-292ce5958d67@nvidia.com

# a lore URL works too; -n applies but publishes/dispatches nothing
scripts/b4-test-patch.sh -n https://lore.kernel.org/all/<msgid>/

# famfs only, on top of v7.4-rc1, and also run the unpatched base for comparison
scripts/b4-test-patch.sh -j famfs -b v7.4-rc1 -B <msgid>

# a series that needs another series first: apply both, in order
scripts/b4-test-patch.sh <prereq-msgid> <msgid>
```

## What it does

```
b4 am <msgid>  ->  ~/.b4-test-patch/mbox/<run>/*.mbx
        |  (base: --base REF, else the series' base-commit if we have it, else Linus' master)
        v
~/.b4-test-patch/work          git checkout --detach <base>; git am -3 each mbox
        |  push
        v
/home/jenkins/git/linux-patches.git   refs/heads/b4/<name>      (+ b4/<name>-base with -B)
        |  buildWithParameters KERNEL_REPO=file://...linux-patches.git KERNEL_REF=b4/<name>
        v
famfs_dbg_regression_public   k:b4/<name> [master:OK]
ndctl_regression_public   k:b4/<name> [pending:OK v85:OK]
```

- **Base.** A series posted with `base-commit:` is applied on exactly that
  commit when it is in Linus' tree. mm patches are usually based on
  mm-unstable / linux-next, which we do not have, so the script says so and
  falls back to Linus' current `master` (b4 itself reports "base-commit ...
  not known"). Force a base with `-b` (tag, sha, or a branch of Linus' tree);
  `-b v7.4-rc1` is the right choice when you want a result comparable to the
  nightly tag runs.
- **Name.** `b4/<mbox name>`, e.g.
  `b4/20261106_ziy_mm_truncate_unmap_dax_entries_before_invalidating_them`;
  override with `-N`. The Jenkins display name is `k:b4/<name> [...]`, so the
  patch run is easy to spot in the build list.
- **Apply failure** (exit 3) prints the conflicting hunks and leaves nothing
  published. Fix the base (`-b`) or pick the series' prerequisite first.
- **Baseline** (`-B`) also dispatches each selected job at the unpatched base
  as `b4/<name>-base`, so a failure can be attributed to the patch rather than
  to the day's master. The nightly `master` run is usually baseline enough.
- **Where things live.** `linux-patches.git` is a bare clone of Linus' tree
  with the thing1 kernel mirror as its object store (`--reference`), so it
  costs a few MB, and its `mainline` branch is refreshed on every run. The
  work tree is a `--shared` clone of it under `~/.b4-test-patch/`; mboxes are
  kept per run under `~/.b4-test-patch/mbox/`. Branches are never deleted by
  the script; `git -C /home/jenkins/git/linux-patches.git branch -D b4/...`
  when done.

## Reading the result

Same as the nightly jobs: UNSTABLE = a test failed on the patched kernel
(per-ref verdicts in the display name and the `famfs-*.log` /
`ndctl-*.log` artifacts), FAILURE = the kernel did not build/boot. Because
`b4/...` is not a version tag, a failure sends the quiet `[tip]` email, not the
loud release one, and the runs are **kept out of the dax-regression-ledger
dashboard** (it is a public-kernel matrix).

Both workers share thing1's single `run_qemu` executor, so the two runs queue
behind each other (and behind the nightly jobs if they are in the queue):
about 15 min for famfs, 20-35 min for ndctl, each incremental on the
persistent kernel tree.

## One-time setup (done on thing1)

- `b4` (and `lei`, for searching lore by subject) installed; `b4.midmask` set.
- The jenkins user fetches the patched kernel over `file://`, which goes
  through `git upload-pack` on a jmg-owned repo, so the repo is in its safe
  list: `sudo -u jenkins git config --global --add safe.directory
  /home/jenkins/git/linux-patches.git`.

## Finding a message-id

lore's web search refuses non-browser clients, but `lei` can query it:

```sh
lei q -I https://lore.kernel.org/all/ -f ldjson 's:"mm/truncate: unmap DAX entries"' \
  | python3 -c 'import sys,json; [print(json.loads(l)["m"], json.loads(l)["s"]) for l in sys.stdin if l.startswith("{")]'
```

Or paste the lore URL from the mail client: the script reduces
`https://lore.kernel.org/<list>/<msgid>/...` to `<msgid>`.
