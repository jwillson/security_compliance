# The lab

Two labs prove this tool, and they answer different questions.

| Lab | Built by | Proves |
| --- | --- | --- |
| **Kickstart** | `vm/build-vm.sh` (`make all`, `make vm-log`) | The reference build: install-time controls (separate filesystems, LUKS volumes, FIPS from first boot) plus the role. |
| **BYO** ("bring your own") | `vm/byo-guest.sh` | The portability claim: the role hardening a stock Rocky 9 host this toolkit did not build. |

Both run on libvirt (`qemu:///system`) on the isolated NAT network `nist-lab`
(`vm/nist-lab-network.xml`, bridge `virbr17`, 192.168.171.0/24). Nothing on a
lab host is changed by hand: every build, probe and comparison is a script in
this repository (AGENTS.md, *Doctrine*).

---

## On any host

Any Linux host with KVM and memory to spare runs either lab: 8 GiB free for
the kickstart pair (4 GiB each while installing), 9 GiB for the three BYO
guests. Nothing is set up by hand. Every step is a script or a `make` target,
each does only what is missing, and re-running one is safe.

| To | Run |
| --- | --- |
| See whether this host can, and what to install if not | `make host-check` (the kickstart lab); `vm/host-check.sh byo` or `all`. It prints the `apt` or `dnf` command for whatever is missing |
| Build, harden and assess the kickstart CUI host from a bare clone | `make all`: the host check, the pinned Ansible (`make tools`), the catalog, `.secrets/`, the ISO, the VM (creating `nist-lab` if missing), apply with the reboot it owes (`apply.sh --reboot`), verify |
| Add its collector | `make vm-log && make pki && make apply && make verify` |
| Build the BYO lab | `vm/byo-lab-init.sh`, `source $NIST_BYO_LAB/env.sh`, then `vm/byo-guest.sh build` per guest (*BYO guests*), or `tools/release-run.sh byo --rebuild`, which builds and cycles all three |
| Get into a hardened guest | `tools/lab-ssh.sh HOST [COMMAND]` (SSH, both factors supplied); `tools/lab-console.sh HOST` (the serial console, when SSH cannot) |
| See what the labs left on the host | `tools/lab-residue.sh` (`--orphans`: only what belongs to no guest) |
| Remove | `make destroy`: the kickstart VMs, then `nist-lab` if no guest uses it. `vm/byo-guest.sh destroy NAME`: one BYO guest. `make teardown`: both labs and everything they left, asking first |
| Prove all of the above | `tools/lab-from-scratch.sh --yes`: teardown, then both labs rebuilt from nothing by these scripts alone |

`make teardown` keeps the inputs a rebuild needs - `.secrets/`, the
downloaded ISO in `iso/`, and the BYO lab directory's secrets and tooling -
and removes everything else: guests, disks, snapshots, UEFI variables, TPM
state, DHCP pins, libvirt logs, host keys, inventory entries, the stand-in
SIEM, `nist-lab`, the staged ISO and the BYO base image. It finishes by
running `tools/lab-residue.sh`, and fails if anything is left.

**Into a hardened guest.** After the overlay is applied, SSH wants your key
*and* the account's password (03.05.03), from a host key already trusted,
over an RSA key (the FIPS policy refuses ed25519), and three wrong passwords
lock the account (03.01.08). A plain `ssh` therefore fails, by design.
`tools/lab-ssh.sh` reads the address, user, key and `known_hosts` file from
the inventory and supplies the second factor, so nothing is typed.
`tools/lab-console.sh` attaches the serial console, for when SSH cannot be
used - a firewall or sshd mistake, a locked account, a boot waiting for the
LUKS passphrase - and first prints which account and password file to use.
A newer OpenSSH client warns that the connection "is not using a
post-quantum key exchange": the FIPS policy offers none, and the warning is
expected.

**When an install stops.** `vm/build-vm.sh` logs the installer's serial
console to `/var/log/libvirt/qemu/NAME-serial.log` and watches it. Twenty
minutes with no new output (`NIST_INSTALL_STALL_MIN`), or two hours in all
(`NIST_INSTALL_TIMEOUT_MIN`), and it stops with the console's last lines and
the likely causes, leaving the VM up to inspect. An installer that halts
itself - anaconda giving up - is caught at once rather than after the
twenty minutes, and either way the stop shows what the installer said
(`tools/install-log.sh NAME`, which also reads a log left behind; DEFECTS
7.30). The inventory is checked before the install starts (7.31); after any
failure, `make destroy` and `make all` repeat it from nothing. An installer that halts
itself - anaconda giving up - is caught at once rather than after the
twenty minutes, and either way the stop shows what the installer said
(`tools/install-log.sh NAME`, which also reads a log left behind; DEFECTS
7.30). The usual cause is a guest
that cannot reach the Rocky mirror: forwarding off, a firewall, or Docker's
`FORWARD DROP` policy (`vm/lab-network.sh` warns about the last two), DNS, or
a proxy. DNS: the guests ask libvirt's dnsmasq, which forwards to the
nameservers in `/etc/resolv.conf` and to nothing else; when that file lists
none (the host resolving through systemd-resolved or a local resolver
instead), `vm/lab-network.sh` gives the network a forwarder the host answers
from, or the one `NIST_LAB_DNS="IP ..."` names (DEFECTS 7.29).
`tools/diagnose-lab-net.sh` tests each layer from the host and from inside
the lab network. `NIST_ROCKY_MIRROR=URL` installs from another mirror. Before
2026-10-05 the install waited forever, unseen - 48 hours on one host (DEFECTS
7.17).

---

## Two labs on one workstation

Run only one lab and none of this applies. Run both on one host and the two
connect differently and must not share an inventory: each has
its own collector, its own CA, and its own second SSH factor — and offering a
host the other lab's password is a failed authentication, a faillock strike
(03.01.08) on every connection. So each lab has its own inventory, and the
lab's own tools choose it - nothing to export (DEFECTS 7.33): `make` and
`vm/build-vm.sh` use `inventory/kickstart.yml`; `./apply.sh`, `./verify.sh`
and the BYO lab's `env.sh` use `inventory/hosts.yml`; `tools/lab-ssh.sh` and
`tools/lab-console.sh` take the one that lists the host named.
`NIST_INVENTORY` overrides any of them. `lib/inventory-env.sh`, sourced by
`apply.sh`, `verify.sh` and the tools, exports it as `ANSIBLE_INVENTORY` so
every `ansible` call follows.

| Lab | Inventory | Shell | Secrets from |
| --- | --- | --- | --- |
| BYO | `inventory/hosts.yml` | `source ~/.local/share/nist-byo-lab/env.sh`, then `./apply.sh`, `./verify.sh` | the environment that `env.sh` sets |
| Kickstart | `inventory/kickstart.yml` | a **fresh** shell (none of the BYO lab's secrets in it), then `make` - `make vm`, `make apply`, `make verify` | `.secrets/` |

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
| `byo-rl9-02` | .144 | cui | What the reference lacks (DEFECTS 5.6): a 10 GB data disk carrying `vg_sys` with all of it free (the LUKS path, 6b.5), a TPM 2.0 (the role's clevis `tpm2` bind), and a second interactive account `cuiuser1` (6b.4). |

All three are built by `vm/byo-guest.sh` (stock `Rocky-9-GenericCloud-Base`
9.8, cloud-init, UEFI with Secure Boot, 3 GB, 2 vCPU); their shapes are
`BYO_SPEC` in `tools/release-run.sh`, and `release-run.sh byo --rebuild`
rebuilds all three from the stock image. `byo-rl9-01` and `byo-log-01` were
first built by hand on 2026-09-17 and replaced by script builds on
2026-09-26, when the release run found the hand-made `byo-rl9-01` snapshot
unusable (DEFECTS 6b.12). A guest has a TPM only when built with `--tpm`
(6b.13: virt-install otherwise adds one to every UEFI guest).

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
`$NIST_BYO_LAB` (default `~/.local/share/nist-byo-lab`), mode 0700, created by
`vm/byo-lab-init.sh`. None of it is ever committed.

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

`vm/byo-lab-init.sh` creates all of it on a new workstation - random
secrets, the venv at the ansible-core version CI pins, the collections, and
the four scripts - and only what is missing, so it is safe on a lab in use
(DEFECTS 7.16). Before it existed these files were made by hand, and nothing
could rebuild them.

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
  guest silently takes a different address. `byo-guest.sh` derives the MAC
  from the address, so a rebuild keeps it. When a different MAC holds the
  lease it refuses if a defined guest owns that MAC, and otherwise - a guest
  already destroyed, like the hand-built `byo-log-01` with its random MAC -
  waits out the expiry (at most the network's hour) and then builds.
  (`dhcp_release` would free it at once; it is in `dnsmasq-utils`, which this
  workstation does not have.)
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
| `vm/host-check.sh [kickstart\|byo\|all]` | Can this host run the lab: KVM, memory, the tools, UEFI firmware with Secure Boot and enrolled keys, libvirt answering; the `apt`/`dnf` command for what is missing. Run by `make vm` and `byo-guest.sh build` (DEFECTS 7.19). |
| `vm/lab-network.sh ensure\|destroy\|destroy-if-unused` | `nist-lab` in `qemu:///system`: created only if missing (by both builders), removed only when no guest uses it; warns about forwarding and Docker (DEFECTS 7.17); gives dnsmasq a DNS forwarder when resolv.conf lists none (7.29). `upstream` prints the one it uses. |
| `vm/lab-teardown.sh [--yes]` | `make teardown`: both labs and everything they left; fails if `lab-residue.sh` still finds anything (DEFECTS 7.18). |
| `tools/lab-residue.sh [--orphans]` | Read-only: every guest, disk, snapshot, UEFI store, TPM state, log, network and container the labs have on this host, and which are orphans. |
| `tools/lab-from-scratch.sh --yes` | Teardown, then both labs rebuilt from nothing by the scripts alone, from a bare shell; logs in `reports/runs/from-scratch-UTC/`. |
| `tools/lab-ssh.sh HOST [COMMAND]` | SSH into a hardened guest with both factors supplied from the inventory and the lab's askpass (DEFECTS 7.20). |
| `tools/lab-console.sh HOST` | The guest's serial console, naming the account and password file first (DEFECTS 7.20). |
| `tools/test-lab-network.sh` | `lab-network.sh` by behaviour, on a throwaway copy of the network. |
| `tools/install-log.sh NAME\|FILE` | What an installer said before it stopped: the console log cut where the shutdown began, the lines that name a fault, then the last lines before it. `build-vm.sh` prints it when an install stops (DEFECTS 7.30). |
| `vm/byo-lab-init.sh` | Create the BYO lab directory on a new workstation: random secrets, the pinned venv and collections, `tools.sh`, `env.sh`, the askpass scripts; only what is missing (DEFECTS 7.16). |
| `tools/release-run.sh byo\|kickstart` | The release gate (TASKS R3), one lab at a time, at a committed worktree: every guest to a clean state (BYO: revert to `fresh`, or rebuild with `byo-guest.sh` if it has none; kickstart: reinstall with `build-vm.sh`), `harden-cycle.sh` on the collector and then each CUI host, a final verify of every host, and `summary.md` in `reports/runs/release-LAB-COMMIT-UTC/`. A host passes with `changed=0` and no failure beyond its documented retrofit limits. Destroys and rebuilds lab guests. `--reverify RUN_DIR` repeats only the final assessment at a later commit that changed no role, playbook, overlay or lab script (it refuses otherwise), reusing RUN_DIR's cycles. |
| `tools/console.py HOST 'cmd' ...` | The guest's serial console, scripted: logs in and runs commands where SSH cannot reach (a locked-out host, boot-time prompts); a module the rehearsals build on. Sends CR line endings and waits for each password prompt before answering, and stops at the first refused authentication — every failure, a cancelled prompt included, counts towards faillock. Needs `pexpect`. |
| `tools/probe.sh PROBE [HOSTS]` | Run a read-only probe from `tools/probes/` on hosts as root. `6b-evidence` shows the state behind DEFECTS 6b.2–6b.6; run it before and after a fix and diff. The `*-experiment` probes are self-cleaning tests of one behaviour (clevis binding and resealing; the role's bind script under `set -e`, against a bind that fails; rsyslog's peer-name check). |
| `tools/rehearse-pcr7-recovery.py HOST` | The RUNBOOK's recovery when the TPM stops releasing the LUKS keys, for real, under ODP-REVIEW I1: starts the guest with no Secure Boot keys (Secure Boot off, PCR 7 changes), checks the boot waits for the passphrase and types it; verify reports the stale binding and Secure Boot off; the role declines to reseal, puts the key back on disk and completes; the hardened variable store is restored (Secure Boot on) and the host boots by itself; the role finds the original seal valid and removes the key; the next boot unlocks from the TPM alone. Refuses a guest that is not a lab guest or has no `hardened` snapshot before it touches anything. PCR 7 and the TPM event log are saved per boot under `reports/runs/`. Reverts to `hardened` at the end. |
| `tools/rehearse-grub-edit.py HOST` | 03.10.07 by behaviour: reboots with the console attached, catches the one-second GRUB menu, presses `e`, and checks a username is demanded, a wrong password refused, the right one accepted, and the default entry still boots unattended. The edited entry is never booted. |
| `tools/rehearse-poam-spreadsheet.sh HOST` | The POA&M register survives a spreadsheet (DEFECTS 7.12): re-saves the host's real register with a byte-order mark, as "CSV UTF-8" does, and requires the generator to keep every ID and a backup, and to refuse a scoped assessment; puts the register back. |
| `tools/rehearse-luks-rotation.sh HOST` | `rotate-luks-passphrase.yml` by behaviour (DEFECTS 7.14): to a random passphrase and back on a LUKS guest, requiring the second run unchanged, the TPM still unlocking, 03.08.09 verifying, nothing left in `/run`. |
| `tools/rehearse-log-rotation.sh HOST` | Log rotation by behaviour (DEFECTS 7.9): no configuration error, `logrotate.service` succeeding, and btmp, wtmp and messages recreated 0600 after a forced rotation; then 03.14.08 verifies. |
| `tools/rehearse-luks-staging.sh HOST` | Where the LUKS key goes while the volumes are created (DEFECTS 7.7): reverts a `--data-disk --tpm` guest to `fresh`, applies 03.08.09 while polling for a key file, and requires it only ever in RAM (`/run/nist-luks-key`), never `/root/.luks-key`, and nothing left after; reverts to `hardened`. |
| `tools/rehearse-grub-preflight.sh HOST` | 03.10.07's pre-flight by behaviour (DEFECTS 7.6): adds a test boot entry without `--unrestricted` (never the default, never booted), moves the password aside, and requires the role to decline to set it and `pe-07-boot-entries-unrestricted` to fail; restores both whatever happens. |
| `tools/rehearse-authored-plans.sh HOST` | Authored SSP sections (through `NIST_SSP_DIR`) and an owner's POA&M entry must survive the scheduled assessment service and a second apply; the rehearsal text is removed at the end (DEFECTS 6.6). |
| `tools/stage-pending-kernel.sh HOST` | Leaves a host as dnf-automatic would: the newest kernel installed and default, an older one running. `apply.sh` must then report "Reboot required: True" with the reason (DEFECTS 6b.10). |
| `tools/ssh-idle-test.sh HOST [LIMIT] [--output]` | Behaviour, not configuration (03.01.11 / 03.13.09). Silent: a session running `sleep` with no terminal, which sshd's ChannelTimeout must close at the limit (DEFECTS 6b.3). `--output`: a terminal session printing every 10 s with nobody typing, which only logind's StopIdleSessionSec ends, since sshd counts output as activity (issue #9); it may live up to about twice the limit, as logind checks on a timer. TMOUT can end neither. |
| `vm/siem-container.sh up\|down\|records` | A stand-in SIEM: syslog-ng (not rsyslog) in a rootful podman container at `192.168.171.50:6514`, macvlan on `virbr17`, mutual x509 with the lab CA, certificate for `siem.nist-lab`. Never in an inventory. State and received records in `$NIST_BYO_LAB/siem/`. The workstation cannot reach a macvlan child of its own bridge; the guests can. |
| `tools/prove-foreign-receiver.sh HOST [--keep]` | Forwarding to a receiver the toolkit did not build (DEFECTS 6.2a): points HOST at the container for the run only (extra vars), then requires the three forwarding checks to PASS, auditd records legible at the receiver, a certificate-less client refused, and nothing delivered when HOST expects a different peer name; points HOST back at its own collector. |
| `tools/prove-collector-attribution.sh FORWARDER VICTIM COLLECTOR` | Root on a permitted peer sends, with its own TLS certificate, one record whose header claims to be another host; PASS when the collector files it under the peer it came from (DEFECTS 7.5). Leaves the marked line in the store; it says what it is. |
| `tools/test-workstation-guard.sh [LAB_HOST]` | `site.yml` refuses the control workstation (DEFECTS 7.13): a throwaway inventory naming this machine in both groups must be stopped by both plays' guard with no role task reached (`--check`), and a lab host must pass. |
| `tools/test-lab-guards.sh [BYO] [KICKSTART]` | The lab tools refuse a domain that is not a lab guest (DEFECTS 7.8): a decoy domain on no network must be refused by every destructive entry point and left intact, real guests must pass, and the authored-plans rehearsal must refuse a host with an authored section. Removes the decoy whatever happens. |
| `tools/assessor-parity.sh BASE NEW [--host H]` | Run two versions of the assessor back to back against the same hosts and compare every check. How PR #2 was accepted (DEFECTS 6b.1). |

## Rehearsing a guest from its fresh state

```bash
./vm/byo-snapshot.sh revert byo-rl9-02 fresh
./tools/harden-cycle.sh byo-rl9-02 --snapshot hardened
```

The whole host from nothing is `tools/lab-from-scratch.sh --yes` (*On any
host*).

**A new forwarder must be admitted by the collector.** The collector's TLS
listener accepts only the certificate names in `nist_col_peers`, which is
`cui_hosts` as it stood when the collector was last applied. A host added to
the inventory afterwards is refused until the collector's 03.03.05 tasks run
again; `harden-cycle.sh` does that step (`apply.sh --limit COLLECTOR --tags
03.03.05`) whenever the host forwards to an inventory collector.
