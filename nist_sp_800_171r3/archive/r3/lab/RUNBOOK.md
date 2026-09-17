# Runbook: spin up a Rocky 9 guest and harden it

This is the path for the r3 overlay. You are not using Vagrant or VirtualBox.
The guests are throwaway QEMU/KVM VMs. **Never** run `nistctl remediate --apply`
on the laptop that writes the playbook.

Publication (prose): `nist_sp_800_171r3/rl9-171/NIST.SP.800-171r3.pdf` (May 2024).
Machine catalog: `nist_sp_800_171r3/r3/catalog.json`. Ansible is generated from
the catalog, not hand-edited.

All commands below assume the **repo root**.

## What you will do

1. Create an isolated libvirt NAT (`10.17.1.0/24`) and three Rocky 9 guests.
2. SSH in as `ansible` and confirm they are vanilla.
3. Dry-run one control (`03.01.08`, unsuccessful logon attempts).
4. Apply that one control.
5. Optionally apply more tags, or the rest of the overlay.
6. Destroy the guests when you are done.

Default topology (edit `cluster.json` if you want fewer nodes):

| Node | IP | Why it exists |
| --- | --- | --- |
| `cui-01` | 10.17.1.11 | CUI host you harden |
| `cui-02` | 10.17.1.12 | Second CUI host (Ansible group, not a singleton) |
| `log-01` | 10.17.1.13 | rsyslog listener on `:514` |

To **harden a single VM** you still spin the cluster up, then pass
`--limit cui-01`. You do not need to edit `cluster.json` for a first pass.

## Safety

| Command | What it does |
| --- | --- |
| `nistctl audit --limit cui-01` | Read-only catalog checks **on the guest** via inventory |
| `nistctl audit --local` | Read-only checks on **this** machine (the writing host) |
| `nistctl remediate --check` | Ansible dry-run against `ansible/inventory.ini` |
| `nistctl remediate --apply` | Makes changes on the guests. Never implied. |
| `labctl destroy` | Deletes guests and overlay disks. Cached Rocky image stays. |

`--apply` without `--id` is the full Linux overlay (FIPS, firewall DROP,
usbguard, …). First time: one tag, one host.

## 0. Prerequisites

You already have these on this machine: KVM, libvirt, `virt-install`,
`cloud-localds`, `ansible-playbook`, membership in `libvirt`. Confirm:

```bash
test -e /dev/kvm && echo kvm-ok
groups | grep -E 'libvirt|kvm'
command -v virsh virt-install cloud-localds ansible-playbook
```

If UFW is active, `labctl up` opens the lab bridge `virbr17` (DHCP, SSH, NAT).
That is local-only, not a WAN hole.

Optional collections (already present if you have run Ansible here before):

```bash
ansible-galaxy collection install -r nist_sp_800_171r3/r3/ansible/requirements.yml
```

## 1. Clean slate

Guests from a previous run should be gone (`undefined`). If `status` still
shows `running`, destroy first:

```bash
python3 nist_sp_800_171r3/r3/lab/labctl.py status
python3 nist_sp_800_171r3/r3/lab/labctl.py destroy --network
```

`--network` also drops the `nist-lab` NAT. Do **not** pass `--image` unless you
want to re-download the ~616 MiB Rocky GenericCloud qcow2.

## 2. Spin up

```bash
python3 nist_sp_800_171r3/r3/lab/labctl.py up
```

First image fetch is several minutes. After that, expect about 1–2 minutes:
libvirt network, overlay disks, cloud-init, wait for SSH, write inventory.

You want:

```
ssh ready cui-01
ssh ready cui-02
ssh ready log-01
wrote .../ansible/inventory.ini
```

`ansible/inventory.ini` is gitignored. It points at `10.17.1.11–13` with a
lab-only key under `lab/.state/`.

Check:

```bash
python3 nist_sp_800_171r3/r3/lab/labctl.py status
```

All three should be `running` with DHCP leases.

If SSH never comes up: `tail /var/tmp/nist-cui-01.serial.log` (needs sudo).

## 3. Look at a vanilla guest

```bash
python3 nist_sp_800_171r3/r3/lab/labctl.py ssh cui-01
```

You are `ansible` with passwordless sudo. Quick sanity:

```bash
hostname -f          # cui-01.nist.lab
grep PRETTY /etc/os-release
systemctl is-active sshd
sudo grep '^deny' /etc/security/faillock.conf || true
exit
```

`faillock` deny is still the distro default. That is the control you will
change next.

Ansible ping (optional):

```bash
ansible -i nist_sp_800_171r3/r3/ansible/inventory.ini cui -m ping
```

Three `pong`s.

## 4. Dry-run one control

`03.01.08` is Unsuccessful Logon Attempts (faillock). It is a small, reversible
OS control — a good first tag.

```bash
python3 nist_sp_800_171r3/r3/nistctl.py remediate --check --id 03.01.08 --limit cui-01
```

`--check` is a dry-run. `--limit cui-01` is one guest. You should see
`changed` for the faillock task and `failed=0`. Nothing on the guest has
been written yet.

Omit `--limit` to dry-run all hosts in `[cui]` (all three).

## 5. Apply that one control

```bash
python3 nist_sp_800_171r3/r3/nistctl.py remediate --apply --id 03.01.08 --limit cui-01
```

`--apply` is the only way changes happen. Confirm on the guest:

```bash
python3 nist_sp_800_171r3/r3/lab/labctl.py ssh cui-01 'sudo grep -E "^(deny|fail_interval|unlock_time)" /etc/security/faillock.conf'
```

Expect `deny = 3` and 900-second interval/unlock (from `odps.yml`).

Re-run `--check` on the same tag: it should report `ok` / not `changed`.

Audit the guest (same catalog commands, over SSH, as root). This is how you
eval the VM, not the CachyOS box:

```bash
python3 nist_sp_800_171r3/r3/nistctl.py audit --id 03.01.08 --limit cui-01
```

A vanilla guest **fails** `03.01.08`. After `--apply`, it should **pass**.
`--json` adds `observed` vs `expect` if you want the raw grep.

On an airgapped CUI host you copy `nistctl.py` + `catalog.json` onto the
machine and run `python3 nistctl.py audit --local` there — no SSH, no lab.

## 6. Harden more (still on the guest)

Pick another tag the same way. Examples:

```bash
# idle timeout / TMOUT
python3 nist_sp_800_171r3/r3/nistctl.py remediate --check --id 03.01.01 --limit cui-01
python3 nist_sp_800_171r3/r3/nistctl.py remediate --apply --id 03.01.01 --limit cui-01

# list Linux-implementable controls
python3 nist_sp_800_171r3/r3/nistctl.py catalog --impl linux
```

Full overlay on one guest (read the caveats first):

```bash
python3 nist_sp_800_171r3/r3/nistctl.py remediate --check --limit cui-01
python3 nist_sp_800_171r3/r3/nistctl.py remediate --apply --limit cui-01
```

Caveats for a full apply:

- **FIPS** (`03.13.08`, `03.13.11`) runs `fips-mode-setup --enable` and needs a
  **guest reboot** before it is actually on. Reboot with
  `python3 nist_sp_800_171r3/r3/lab/labctl.py ssh cui-01 'sudo reboot'`
  then wait and `labctl.py ssh cui-01` again.
- **Firewall** sets the public zone target to DROP. SSH from this host still
  works because you are on `10.17.1.0/24` (`odp.ssh_allow_cidrs` is `10.0.0.0/8`).
- **usbguard** is `os_partial`. Fine on a headless VM; do not copy that habit
  onto a laptop that needs HID.
- Policy / physical / most of AT, IR, PL, SA, SR stay in the SSP. Ansible will
  not pretend a sysctl satisfies them.

`nistctl audit` without `--local` uses `ansible/inventory.ini` and runs the
catalog checks on the guests. `--local` is this laptop — useless for an
airgapped eval. On the real CUI box, copy `nistctl.py` and `catalog.json`
over and use `--local` *there*.

## 7. Tear down

```bash
python3 nist_sp_800_171r3/r3/lab/labctl.py destroy --network
python3 nist_sp_800_171r3/r3/lab/labctl.py status
```

Status should show `undefined`. The cached image remains so the next `up` is
fast. To drop the cache too: `labctl.py destroy --network --image`.

## If something fails

| Symptom | Where to look |
| --- | --- |
| `up` waits on SSH, then timeout | `sudo tail -80 /var/tmp/nist-cui-01.serial.log` |
| `Permission denied (publickey)` | Use `labctl.py ssh`, not your personal key. `IdentitiesOnly` is set in inventory on purpose (`MaxAuthTries` becomes 3 after overlay). |
| Ansible targets localhost | `labctl up` did not write `r3/ansible/inventory.ini` |
| UFW / no DHCP leases | `sudo ufw status`; `labctl up` should allow `virbr17` |
| Domain already defined | `labctl.py destroy --network` and `up` again |

Do not apply the overlay to this CachyOS host. The guests are the target.
