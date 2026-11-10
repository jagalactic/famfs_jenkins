# run_qemu VM resources (vCPUs, memory, dax devices)

Applies to every run_qemu-based job (`smoke_qemu_*`, `ndctl_qemu_*`,
`ndctl_regression_public`, ...). They all boot the guest through
`run_qemu_fixture.groovy`, which passes only the job's `runQemuArgs` (e.g.
`--nfit-test`) and **no** `--preset` / `--mem-size`, so the VM size is
**run_qemu's default** unless a job overrides it.

## Defaults (confirmed from a real boot)

The qemu invocation for `smoke_qemu_nfit_local` was:

```
-smp 8,sockets=2,cores=2,threads=2
-m 12288M,slots=8,maxmem=77832M
```

- **vCPUs = 8.** Topology is derived: `sockets = number of NUMA nodes`, 2 cores
  per socket, 2 threads per core. Threads is 2 with **KVM** (thing1 has KVM) and
  1 under TCG. So `vCPUs = nodes x 2 x 2 = 8` here (would be 4 under TCG).
- **Memory = 12 GiB** (`-m 12288M`). run_qemu computes
  `-m = mem-size x (nodes + mems)`; the default `mem-size` is **2048 MiB**, and
  the effective default topology here is `nodes=2, mems=4`, so
  `2048 x (2 + 4) = 12288 MiB`.
  - Of that 12 GiB, the guest kernel manages **~8 GiB as normal System RAM**
    (`Memory: .../8383184K available`, ~5.2 GiB free at boot); the remaining
    ~4 GiB is the emulated nvdimm/pmem reservation and shows up as pmem/dax,
    not System RAM.
  - `maxmem` (~76 GiB) and `slots=8` are the memory-hotplug ceiling, not the
    initial size.

## Tuning vCPUs / memory

Change the sizing by adding run_qemu flags to the job's `runQemuArgs` in its
`*.groovy` (the `fixture.call(...)`), e.g. `smoke_qemu_nfit_local.groovy` uses
`runQemuArgs: '--nfit-test'`:

- `--mem-size <MiB>` - size of each memory device; **total RAM =
  mem-size x (nodes + mems)**. e.g. `--nfit-test --mem-size 4096` -> 24 GiB.
- `--preset <tiny|small|med|large|huge|insane>` - sets `nodes/mems/pmems`
  together (see run_qemu's preset table). Larger presets add nodes (more
  vCPUs) and memory.
- `--nodes N` / `--mems N` / `--pmems N` - override the counts individually.
- **vCPUs track `nodes`** (`vCPUs = nodes x 2 x threads`); there is no direct
  `--cpus`/`--smp` flag, so raise `--nodes` to get more vCPUs (that also raises
  memory via the formula above).

Example - give the nfit smoke VM more RAM without changing CPUs:
```groovy
runQemuArgs: '--nfit-test --mem-size 4096'   // 4096 * (2+4) = 24 GiB
```
Presets interact, so re-confirm the actual values after changing (see below).

## dax device size (nfit smoke)

`smoke_qemu_nfit_local`'s in-guest autorun (`rq-famfs-smoke-nfit-autorun.sh`)
carves a **6 GiB devdax** off the emulated ACPI.NFIT (`nfit_test`) bus:

```sh
ns=$("$NDCTL" create-namespace -b ACPI.NFIT -m devdax -fe "$ns" -s 6G | jq -er '.dev')
```

Tune it by editing the `-s 6G`. Constraint: `nfit_test` pmem is backed by the
guest's **System RAM** (~8 GiB usable), so the devdax competes with the OS for
that RAM - a bigger devdax needs a bigger VM (bump `--mem-size` / `--preset`
above) to leave OS headroom. (The 6 GiB currently leaves ~2 GiB for the OS.)

> Note: the two 16 GiB `nvdimm` dimms (`nvmem0/1`, file-backed, sparse) are a
> *separate* qemu pmem source that the nfit smoke autorun does not use - it uses
> the `nfit_test` ACPI.NFIT bus. Other jobs (e.g. cxl) exercise different
> backends.

## Confirming the actual values

The real `-m` / `-smp` are in the run_qemu invocation in the Jenkins **build**
log, and the guest's usable System RAM is in the archived `console.log`:

```sh
# on the controller, for build <N> of <job>:
d=/var/lib/jenkins/jobs/<job>/builds/<N>
grep -aoE '\-m [0-9]+M[^ ]*|\-smp [0-9,a-z=]+' "$d/log" | sort -u
grep -aE 'Memory: [0-9]+K/[0-9]+K available' "$d/archive/console.log"
```
