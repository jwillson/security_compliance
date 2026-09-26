# The lab

Two labs prove this tool, and they answer different questions.

| Lab | Built by | Proves | Where |
| --- | --- | --- | --- |
| **Kickstart** | `vm/build-vm.sh` (`make vm`, `make vm-log`) | The reference build: install-time controls (separate filesystems, LUKS volumes, FIPS from first boot) plus the role. | Either workstation, with `.secrets/`: the owner's older one, and since 2026-09-26 the Ubuntu laptop too (`rl9-cui-01` .143, `rl9-log-01` .184, in `inventory/kickstart.yml`). |
| **BYO** ("bring your own") | `vm/byo-guest.sh` | The portability claim: the role hardening a stock Rocky 9 host this toolkit did not build, driven from a control workstation with no `.secrets/`. | The owner's Ubuntu laptop. |

Both run on libvirt (`qemu:///system`) on the isolated NAT network `nist-lab`
(`vm/nist-lab-network.xml`, bridge `virbr17`, 192.168.171.0/24). Nothing on a
lab host is changed by hand: every build, probe and comparison is a script in
this repository (AGENTS.md, *Doctrine*).

---

## Two labs on one workstation

The two labs connect differently and must not share an inventory: each has
its own collector, its own CA, and its own second SSH factor — and offering a
host the other lab's password is a failed authentication, a faillock strike
(03.01.08) on every connection. So each lab has its own inventory, chosen with
`NIST_INVENTORY` (default `inventory/hosts.yml`); `lib/inventory-env.sh`,
sourced by `apply.sh`, `verify.sh` and the tools, exports it as
`ANSIBLE_INVENTORY` so every `ansible` call follows.

| Lab | Inventory | Shell | Secrets from |
| --- | --- | --- | --- |
| BYO | `inventory/hosts.yml` (the default) | `source ~/.local/share/nist-byo-lab/env.sh` | the environment that `env.sh` sets |
| Kickstart | `inventory/kickstart.yml` | a **fresh** shell: `source ~/.local/share/nist-byo-lab/tools.sh` (the ansible tooling alone, no secrets), then `export NIST_INVENTORY=inventory/kickstart.yml` | `.secrets/` |

The helper reads the connection kind from the inventory itself — `lab` if the
hosts use the `.secrets/` key, `byo` otherwise — and from it `lib/ssh-env.sh`
chooses the askpass and each host's `known_hosts`. It refuses, with the reason:

- an inventory that mixes the two kinds (`tools/inventory.py add` refuses to
  create one);
- a lab inventory in a shell that sets `NIST_PKI_DIR`, `NIST_GRUB_PASSWORD`
  or `NIST_LUKS_PASSPHRASE` — the role prefers the environment to `.secrets/`,
  so a kickstart run from the BYO shell would quietly get the BYO lab's CA,
  GRUB password and LUKS passphrase. `NIST_ALLOW_ENV_SECRETS=1` overrides,
  for when that is really meant.

Before 2026-09-26 the choice was made by whether `.secrets/` existed at all,
so creating it for the kickstart lab silently gave every BYO host the wrong
second factor.

---

## BYO guests

| Guest | Address | Role | What it is for |
| --- | --- | --- | --- |
| `byo-rl9-01` | .141 | cui | **The retrofit reference.** Stock GenericCloud, one root filesystem, no volume group, no TPM, one interactive account. Its five failing requirements are the documented retrofit limits (DEFECTS 2.2). Do not add to it. |
| `byo-log-01` | .101 | log | The collector the BYO CUI hosts forward to over TLS. |
| `byo-rl9-02` | .144 | cui | What the reference lacks, for the open defects (TASKS 5.6): a 10 GB data disk carrying `vg_sys` with all of it free (the LUKS path, 6b.5), a TPM 2.0 (the role's clevis `tpm2` bind), and a second interactive account `cuiuser1` (6b.4). |

`byo-rl9-01` and `byo-log-01` predate `vm/byo-guest.sh`; they were built by
hand on 2026-09-17 in the same shape (stock `Rocky-9-GenericCloud-Base` 9.8,
cloud-init, UEFI with Secure Boot, 3 GB, 2 vCPU). `byo-rl9-02` was the first
guest built by the script, after a hand-built attempt was destroyed and
rebuilt to prove the script reproduces it.

### Build, check, destroy

```bash
cd nist_sp_800_171r3/rl9-171
source ~/.local/share/nist-byo-lab/env.sh     # NIST_PKI_DIR, become password, askpass

./vm/byo-guest.sh build byo-rl9-02 --ip 192.168.171.144 \
    --data-disk 10 --tpm --user cuiuser1
./vm/byo-guest.sh check byo-rl9-02            # read-only: release, accounts, vg_sys, TPM, Secure Boot
./vm/byo-guest.sh destroy byo-rl9-02
```

A build writes the cloud-init seed, creates the disks, pins the address in
`nist-lab`'s DHCP (the MAC is derived from the address, so a rebuild keeps
it), defines the domain, waits for first boot, adds the host to
`inventory/hosts.yml` with `tools/inventory.py add --connection byo`, mints
its TLS certificate into `$NIST_PKI_DIR`, and saves a `fresh` snapshot.

### Snapshots

`virsh snapshot-create-as` refuses a UEFI guest with raw NVRAM (DEFECTS 3.1),
so a snapshot is a copy of every file the guest's state lives in: each disk,
the NVRAM, and the vTPM state when there is one. The TPM state matters — a
LUKS volume bound with clevis `tpm2` cannot be unlocked after a revert that
restores the disk but not the TPM it was sealed to.

```bash
./vm/byo-snapshot.sh save   byo-rl9-02 hardened   # shuts down, copies, starts
./vm/byo-snapshot.sh revert byo-rl9-02 fresh      # stops, copies back, starts, waits for SSH
./vm/byo-snapshot.sh list
```

Labels in use: `fresh` (right after cloud-init) and `hardened` (applied,
rebooted, settled).

### The lab directory

Operator-side state lives outside the repository, in
`$NIST_BYO_LAB` (default `~/.local/share/nist-byo-lab`), mode 0700. None of
it is ever committed.

| Path | What |
| --- | --- |
| `tools.sh` | The ansible venv and collections on `PATH`, and nothing else — what a kickstart-lab shell sources. |
| `env.sh` | Source before `apply.sh` / `verify.sh` for the BYO lab (it sources `tools.sh`): the ansible venv, `NIST_BECOME_PASSWORD`, `NIST_GRUB_PASSWORD`, `SSH_ASKPASS` (the second factor once 03.05.03 applies), `NIST_PKI_DIR`. |
| `byoadmin_password` | `byoadmin`'s password on every BYO guest: sudo, and the SSH second factor. |
| `grub_password`, `luks_passphrase` | What the role is given for 03.10.07 and 03.08.09. |
| `pki/` | The lab CA and one certificate per host (`tools/lab-pki.sh`). |
| `NAME/` | One guest's cloud-init seed, its address, and each `--user` account's password. |
| `askpass.sh`, `wrongpass.sh` | The SSH askpass; a deliberately wrong one for lockout rehearsals. (The scripted serial console used to live here too; it is `tools/console.py` now.) |
| `venv/`, `collections/` | ansible-core and the collections in `requirements.yml`. |

The venv: `uv venv venv && uv pip install --python venv/bin/python ansible-core`,
then `venv/bin/ansible-galaxy collection install -p collections -r <repo>/nist_sp_800_171r3/rl9-171/requirements.yml`.

### Host problems the scripts handle

Each of these stopped a build once. The fix is in the script, not in a note.

- **`virt-install`: "No module named 'gi'".** `virt-install` needs the system
  Python's GObject bindings; a `PATH` that puts linuxbrew's (or a venv's)
  `python3` first breaks it. `byo-guest.sh` always runs it under
  `/usr/bin/python3`.
- **vTPM: "Need read/write rights on statedir /var/lib/swtpm-localca for user
  tss".** libvirt runs swtpm as `tss`; Ubuntu's package leaves the local CA
  directory owned by `swtpm`. `byo-guest.sh --tpm` re-owns it, once, and says
  so. `/etc/libvirt/qemu.conf` may not exist; libvirt's default `tss` then
  applies.
- **A pinned address handed to someone else.** dnsmasq will not give a pinned
  address to a new MAC while an unexpired lease holds it for another, and the
  guest silently takes a different address. `byo-guest.sh` refuses to build
  onto an address leased to a different MAC and says until when.
- **First boot is slow.** A login can authenticate and then stall until
  logind and cloud-init settle; `cloud-init status` is not readable by an
  unprivileged user. The wait polls `/var/lib/cloud/instance/boot-finished`
  with a timeout per attempt.
- **First boot needs the Rocky mirrors when `--data-disk` is given.** The
  GenericCloud image does not ship `lvm2`, and a host with a volume group
  always has it (without it the role takes its "no volume group" branch and
  skips LUKS), so cloud-init installs it. On 2026-09-25 a slow mirror
  (`Curl error (28) ... Operation too slow`) stretched that to 8 minutes;
  dnf moves on to other mirrors by itself. Read `/var/log/dnf.log` in the
  guest before assuming the build is stuck.
- **Scripting the serial console can lock the account.** Three lessons from
  locking `byoadmin` on `byo-rl9-02` (2026-09-26, recovered by reverting to
  `hardened`): the serial line acts on CR, not the bare LF pexpect's
  `sendline` sends, so neither the shell nor `sudo -S` saw a line end; sudo
  flushes typed-ahead input when it turns echo off, so a password sent before
  its prompt is discarded; and every attempt that does not succeed — a
  cancelled or abandoned prompt included — is a faillock failure, three of
  which lock the account for 900 s over SSH and console alike. `tools/console.py`
  sends CR, waits for each prompt, and stops at the first refusal.
- **A passphrase prompt at boot is not a TPM failure.** systemd shows the
  prompt for each CUI volume on every boot while `clevis-luks-askpass`
  answers it from the TPM; a script that answers what it sees cannot tell a
  refused TPM from a working one. Judge by whether the login prompt arrives
  with nobody answering (the CUI mounts gate boot). And `findmnt` given two
  paths reads them as a source and a target and matches nothing.
- **A throwaway sshd cannot open a session on a hardened guest.** Testing
  sshd options in isolation with `sshd -i` (inetd mode, no port) fails after
  authentication with "A valid context for byoadmin could not be obtained":
  pam_selinux refuses a session from an sshd not running in `sshd_t`, and
  policy does not allow starting one there. Test the real sshd by behaviour
  instead (`tools/ssh-idle-test.sh`), and read OpenSSH's source for mechanism.
- **`build-vm.sh` on Ubuntu.** Its firmware presence check knew only the
  Fedora/RHEL paths; Ubuntu ships `/usr/share/OVMF/OVMF_CODE_4M.fd`. Found by
  the first kickstart build on the laptop.
- **A tool that runs `ansible` itself must source `lib/ssh-env.sh`**, not
  just the inventory helper: once 03.05.03 is applied every connection needs
  the second factor, which for the kickstart lab only `ssh-env.sh` supplies,
  and a newly built host's key must be seeded into `.secrets/known_hosts`
  first. `harden-cycle.sh`, `probe.sh` and `stage-pending-kernel.sh` do.
- **A silent firmware delay.** Without a boot order the firmware tried other
  devices first and the kernel started ~10 minutes after the domain did.
  `byo-guest.sh` puts `hd` first, and logs the serial console to
  `/var/log/libvirt/qemu/NAME-serial.log`.

---

## Evidence and comparisons

| Script | Use |
| --- | --- |
| `tools/harden-cycle.sh HOST [--snapshot LABEL]` | One full, recorded hardening cycle: probe, dry run, apply, admit to the collector, reboot if required, apply, dry run (expects `changed=0`), verify, probe again, optional snapshot. Logs and evidence in `reports/runs/HOST-UTC/`. The release gate (TASKS R3) is this, on every lab host, at the release commit. |
| `tools/console.py HOST 'cmd' ...` | The guest's serial console, scripted: logs in and runs commands where SSH cannot reach (a locked-out host, boot-time prompts); a module the rehearsals build on. Sends CR line endings and waits for each password prompt before answering, and stops at the first refused authentication — every failure, a cancelled prompt included, counts towards faillock. Needs `pexpect`. |
| `tools/probe.sh PROBE [HOSTS]` | Run a read-only probe from `tools/probes/` on hosts as root. `6b-evidence` shows the state behind TASKS 6b.2–6b.6; run it before and after a fix and diff. |
| `tools/rehearse-pcr7-recovery.py HOST` | The RUNBOOK's recovery when the TPM stops releasing the LUKS keys, for real: starts the guest with no Secure Boot keys (PCR 7 changes), checks the boot waits for the passphrase, types it, then verify reports the stale binding, the role reseals, verify passes, and the next boot unlocks alone. PCR 7 and the TPM event log are saved per boot under `reports/runs/`. Reverts to `hardened` at the end. |
| `tools/rehearse-grub-edit.py HOST` | 03.10.07 by behaviour: reboots with the console attached, catches the one-second GRUB menu, presses `e`, and checks a username is demanded, a wrong password refused, the right one accepted, and the default entry still boots unattended. The edited entry is never booted. |
| `tools/rehearse-authored-plans.sh HOST` | Authored SSP sections (through `NIST_SSP_DIR`) and an owner's POA&M entry must survive the scheduled assessment service and a second apply; the rehearsal text is removed at the end (DEFECTS 6.6). |
| `tools/stage-pending-kernel.sh HOST` | Leaves a host as dnf-automatic would: the newest kernel installed and default, an older one running. `apply.sh` must then report "Reboot required: True" with the reason (DEFECTS 6b.10). |
| `tools/ssh-idle-test.sh HOST [LIMIT]` | Behaviour, not configuration: opens an SSH session running a silent `sleep` and measures when sshd closes it (03.01.11 / 03.13.09; TMOUT cannot end it). Takes the idle limit plus up to 90 s. |
| `tools/assessor-parity.sh BASE NEW [--host H]` | Run two versions of the assessor back to back against the same hosts and compare every check. How PR #2 was accepted (DEFECTS 6b.1). |

## Rehearsing from scratch

```bash
./vm/byo-snapshot.sh revert byo-rl9-02 fresh
./tools/harden-cycle.sh byo-rl9-02 --snapshot hardened
```

**A new forwarder must be admitted by the collector.** The collector's TLS
listener accepts only the certificate names in `nist_col_peers`, which is
`cui_hosts` as it stood when the collector was last applied. A host added to
the inventory afterwards is refused until the collector's 03.03.05 tasks run
again; `harden-cycle.sh` does that step (`apply.sh --limit COLLECTOR --tags
03.03.05`) whenever the host forwards to an inventory collector.
