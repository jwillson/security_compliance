# QEMU/KVM lab

Throwaway Rocky Linux 9 guests for the r3 overlay. This is the lab path for
`nistctl remediate`. It does **not** replace `nist_sp_800_171r3/os/` (Vagrant,
r2-tagged playbook).

Requires KVM (`/dev/kvm`), libvirt system URI (`qemu:///system`), `virt-install`,
`cloud-localds`, and membership in the `libvirt` group. No Vagrant, no
VirtualBox. Guests boot UEFI. If host UFW is active, `labctl up` opens the lab
bridge (`virbr17`) so DHCP, SSH, and NAT work.

## Topology

Isolated NAT `nist-lab` on `10.17.1.0/24` (inside `odp.ssh_allow_cidrs`).

| Node | Role | IP | RAM |
| --- | --- | --- | --- |
| `cui-01` | overlay target | 10.17.1.11 | 2G |
| `cui-02` | overlay target | 10.17.1.12 | 2G |
| `log-01` | rsyslog listener `:514` | 10.17.1.13 | 1G |

Edit [cluster.json](cluster.json) to change counts or sizes. Guest user is
`ansible` with a lab-only ed25519 key under `.state/` (gitignored).

Walkthrough (spin up, one tag, apply, tear down): [RUNBOOK.md](RUNBOOK.md).

## Use

```bash
python3 nist_sp_800_171r3/r3/lab/labctl.py up
python3 nist_sp_800_171r3/r3/lab/labctl.py status
python3 nist_sp_800_171r3/r3/lab/labctl.py ssh cui-01

# first apply a single tag, then the rest — never on the writing host
python3 nist_sp_800_171r3/r3/nistctl.py remediate --check --id 03.01.08
python3 nist_sp_800_171r3/r3/nistctl.py remediate --apply --id 03.01.08
```

`up` writes `../ansible/inventory.ini` (gitignored). `destroy` removes guests
and overlay disks; `--network` drops the NAT net; `--image` drops the cached
Rocky GenericCloud volume.

```bash
python3 nist_sp_800_171r3/r3/lab/labctl.py destroy --network
```

`--apply` is never implied. FIPS still needs a guest reboot after
`fips-mode-setup --enable`.

Serial consoles are also written to `/var/tmp/nist-<node>.serial.log` if a
guest fails to come up.
