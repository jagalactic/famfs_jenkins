# Keeping Jenkins agents on the expected kernels

## The problem

Each Jenkins agent VM is supposed to run a specific pinned kernel (see
`chk_kernels.sh` for the host -> kernel mapping). The famfs tests fail if an
agent boots the wrong kernel.

After an unexpected reboot (power outage, host crash) an agent can come up on
the wrong kernel. Root cause: the agent's GRUB *persistent* default
(`saved_entry` in `/boot/grub2/grubenv`) was pointing at the wrong entry -
typically the stock Fedora kernel - so a clean power-on lands there. (Selecting
the right kernel with a one-time `grub2-reboot` does not survive a power
outage, because the one-time choice is cleared on the unexpected boot.)

## The fix

Pin the correct kernel as the **persistent** default on each agent:

```
grubby --set-default=/boot/vmlinuz-<expected-version>
```

Once the persistent default is correct, the agent boots the right kernel on its
own after any future power outage - which is how the healthy agents already
behave.

## Tooling

- `chk_kernels.sh` - reports which agents are on the wrong kernel (read-only).
- `fix_kernels.sh` - remediates: for any agent on the wrong kernel it pins the
  correct kernel as the persistent default and reboots, then re-verifies. It
  reads the expected host->kernel mapping from `chk_kernels.sh`, so there is a
  single source of truth. Agents already correct are left untouched.

```
scripts/fix_kernels.sh        # fix anything wrong
scripts/fix_kernels.sh -n     # dry-run: report only, change nothing
```

## Automated recovery after this host (jmg) reboots

`famfs-fix-kernels.service` runs `fix_kernels.sh` once at boot, so after jmg
itself comes back from a power outage the agents are checked and corrected
automatically. It runs as user `jmg` (using jmg's passwordless-root SSH keys)
and polls each agent until it is reachable, so it tolerates the agents still
booting.

Install (needs sudo on jmg):

```
sudo cp famfs-fix-kernels.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable famfs-fix-kernels.service   # run at every boot
```

Run it by hand / check results:

```
sudo systemctl start  famfs-fix-kernels.service   # trigger now
journalctl -u famfs-fix-kernels.service           # see what it did
```

Note: because the persistent GRUB default is now correct on every agent, the
agents will usually boot the right kernel on their own; this service is the
safety net for the case where the default gets clobbered again (e.g. a Fedora
`dnf` kernel update re-pointing the default at a new stock kernel).
