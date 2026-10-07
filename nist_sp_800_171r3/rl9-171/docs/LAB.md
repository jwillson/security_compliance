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

Any Linux host with KVM, its hypervisor (libvirt, qemu, swtpm, UEFI
firmware, dnsmasq), podman or docker, and memory to spare runs either lab -
the tool itself runs in its container and drives libvirt through its
socket, as you, without sudo (TASKS C5): 8 GiB free for
the kickstart pair (4 GiB each while installing), 9 GiB for the three BYO
guests. Nothing is set up by hand. Every step is a script or a `make` target,
each does only what is missing, and re-running one is safe.

| To | Run |
| --- | --- |
| See whether this host can, and what to install if not | `make host-check` (the kickstart lab); `vm/host-check.sh byo` or `all`. It asks libvirt, and prints the host's `apt`, `dnf` or `pacman` command for whatever is missing |
| Build, harden and assess the kickstart CUI host from a bare clone | `make all`: the host check, the catalog, `.secrets/`, the ISO, the VM (creating `nist-lab` if missing), apply with the reboot it owes (`apply.sh --reboot`), verify |
| Add its collector | `make vm-log && make pki && make apply && make verify` |
| Build the BYO lab | `vm/byo-lab-init.sh`, `source $NIST_BYO_LAB/env.sh`, then `vm/byo-guest.sh build` per guest (*BYO guests*), or `tools/release-run.sh byo`, which builds and cycles all three |
| Get into a hardened guest | `tools/lab-ssh.sh HOST [COMMAND]` (SSH, both factors supplied); `tools/lab-console.sh HOST` (the serial console, when SSH cannot) |
| See what the labs left on the host | `tools/lab-residue.sh` (`--orphans`: only what belongs to no guest) |
| Remove | `make destroy`: the kickstart VMs, then `nist-lab` if no guest uses it. `vm/byo-guest.sh destroy NAME`: one BYO guest. `make teardown`: both labs and everything they left, asking first |
| Prove all of the above | `tools/lab-from-scratch.sh --yes`: teardown, then both labs rebuilt from nothing by these scripts alone |

`make teardown` keeps the inputs a rebuild needs - `.secrets/`, the
downloaded ISO in `iso/`, and the BYO lab directory's secrets - and removes
everything else, through libvirt: guests, their volumes (disks, install and
seed ISOs, the BYO base image), UEFI variables, TPM state, DHCP pins, host
keys, inventory entries and `nist-lab` (libvirt keeps its own per-domain
logs, rotated by it). It finishes by running `tools/lab-residue.sh`, and
fails if anything is left.

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

**When an install stops.** `vm/build-vm.sh` installs each guest from its own
install ISO, booted as a CD-ROM - the media a bare-metal machine gets - and
records the installer's console through libvirt (`tools/console-record.sh`)
into `reports/runs/build-NAME-UTC/console.log`, and watches it. Twenty
minutes with no new output (`NIST_INSTALL_STALL_MIN`), or two hours in all
(`NIST_INSTALL_TIMEOUT_MIN`), and it stops with what the installer said and
the likely causes, leaving the VM up to inspect. An installer that halts
itself - anaconda giving up - is caught at once rather than after the
twenty minutes, and either way the stop shows what the installer said
(`tools/install-log.sh NAME`, which also reads a log left behind; DEFECTS
7.30). The inventory is checked before the install starts (7.31); after any
failure, `make destroy` and `make all` repeat it from nothing. The usual cause of a stall is a guest
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
`BYO_SPEC` in `tools/release-run.sh`, and `release-run.sh byo` rebuilds all
three from the stock image, every time. `byo-rl9-01` and `byo-log-01` were
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
its TLS certificate into `$NIST_PKI_DIR`. There are no snapshots: a clean
guest is a rebuilt one (DEFECTS 7.36).

### The lab directory

Operator-side state lives outside the repository, in
`$NIST_BYO_LAB` (default `~/.local/share/nist-byo-lab`), mode 0700, created by
`vm/byo-lab-init.sh`. None of it is ever committed.

| Path | What |
| --- | --- |
| `env.sh` | Source for the BYO lab. It holds no secret: it names the inventory (`inventory/hosts.yml`), the vault password file (`NIST_VAULT_PASSWORD_FILE`) and `NIST_PKI_DIR`. |
| `byoadmin_password` | `byoadmin`'s password on every BYO guest: sudo, and the SSH second factor. |
| `grub_password`, `luks_passphrase` | What the role is given for 03.10.07 and 03.08.09. |
| `vault_password` | Unlocks `inventory/hosts.vault.yml`, where the tools read the three secrets above from (TASKS C3). |
| `pki/` | The lab CA and one certificate per host (`tools/lab-pki.sh`). |
| `NAME/` | One guest's cloud-init seed, its address, and each `--user` account's password. |

`vm/byo-lab-init.sh` creates all of it on a new workstation - random
secrets, the vault, `env.sh` - and only what is missing, so it is safe on a
lab in use (DEFECTS 7.16). It removes what earlier versions made and the
container retired: the venv, the collections, `tools.sh` and the askpass
scripts (TASKS C4).

### Host problems the scripts handle

Each of these stopped a build once. The fix is in the script, not in a note.

- **`virt-install`: "No module named 'gi'".** `virt-install` needs the system
  Python's GObject bindings; a `PATH` that puts a venv's `python3` first
  breaks it. In the control-plane image the venv is last on `PATH`.
- **vTPM: "Need read/write rights on statedir /var/lib/swtpm-localca for user
  tss".** libvirt runs swtpm as `tss`; Ubuntu's package leaves the local CA
  directory owned by `swtpm`. It is the host's to fix, once, since the tool no
  longer touches host files: `sudo install -d -m 0750 -o tss -g root
  /var/lib/swtpm-localca`.
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
  instead (the idle-session proof of DEFECTS 6b, retired with the other
  one-off proofs - 7.36), and read OpenSSH's source for mechanism.
- **`build-vm.sh` on Ubuntu.** Its firmware presence check knew only the
  Fedora/RHEL paths; Ubuntu ships `/usr/share/OVMF/OVMF_CODE_4M.fd`. Found by
  the first kickstart build on the laptop.
- **A tool that runs `ansible` itself must source `lib/ssh-env.sh`**, not
  just the inventory helper: once 03.05.03 is applied every connection needs
  the second factor, which for the kickstart lab only `ssh-env.sh` supplies,
  and a newly built host's key must be seeded into `.secrets/known_hosts`
  first. `harden-cycle.sh` and `probe.sh` do.
- **A silent firmware delay.** Without a boot order the firmware tried other
  devices first and the kernel started ~10 minutes after the domain did.
  `byo-guest.sh` puts `hd` first; a slow boot is read with
  `tools/console-record.sh` or `tools/lab-console.sh`.

---

## Evidence and comparisons

| Script | Use |
| --- | --- |
| `tools/harden-cycle.sh HOST [--no-probe]` | One full, recorded hardening cycle: probe, dry run, apply, admit to the collector, reboot if required, apply, dry run (expects `changed=0`), verify, probe again. Logs and evidence in `reports/runs/HOST-UTC/`. The release gate (TASKS R3) is this, on every lab host, at the release commit. |
| `vm/host-check.sh [kickstart\|byo\|all]` | Can this host run the lab - asked of libvirt through its socket: libvirt as you, KVM, UEFI with Secure Boot, swtpm, the default pool, memory; the host's package command for what is missing (DEFECTS 7.19; TASKS C4). |
| `vm/lab-network.sh ensure\|destroy\|destroy-if-unused` | `nist-lab` in `qemu:///system`: created only if missing (by both builders), removed only when no guest uses it; warns about forwarding and Docker (DEFECTS 7.17); gives dnsmasq a DNS forwarder when resolv.conf lists none (7.29). `upstream` prints the one it uses. |
| `vm/lab-teardown.sh [--yes]` | `make teardown`: both labs and everything they left; fails if `lab-residue.sh` still finds anything (DEFECTS 7.18). |
| `tools/lab-residue.sh [--orphans]` | Read-only, through the libvirt socket: every lab guest, network and pool volume, and which are orphans. UEFI and TPM state go with `undefine --nvram --tpm`; libvirt keeps its own per-domain logs. |
| `tools/lab-from-scratch.sh --yes` | Teardown, then both labs rebuilt from nothing by the scripts alone, from a bare shell; logs in `reports/runs/from-scratch-UTC/`. |
| `tools/lab-ssh.sh HOST [COMMAND]` | SSH into a hardened guest with both factors supplied from the inventory and the lab's askpass (DEFECTS 7.20). |
| `tools/lab-console.sh HOST` | The guest's serial console, naming the account and password file first (DEFECTS 7.20). |
| `tools/test-lab-network.sh` | `lab-network.sh` by behaviour, on a throwaway copy of the network. |
| `tools/install-log.sh NAME\|FILE` | What an installer said before it stopped: the console log cut where the shutdown began, the lines that name a fault, then the last lines before it. `build-vm.sh` prints it when an install stops (DEFECTS 7.30). |
| `tools/console-record.sh NAME FILE [SECONDS]` | A guest's serial console, recorded through the libvirt socket across its restarts, in the control-plane container: `virsh console` under util-linux `script` (DEFECTS 7.34). `tools/test-console-record.sh` proves it in minutes on a diskless guest restarted twice. |
| `tools/spike-container-libvirt.sh [--keep]` | The lab-in-container spike: a fresh install of the real kickstart driven from inside `./nist` through the socket alone - ISO upload, virt-install, SSH, the console recorded - then removed (DEFECTS 7.34). |
| `tools/rehearse-baremetal.sh [--keep]` | A bare-metal install, rehearsed: `install/iso.sh` builds the ISO, a guest boots it as a plain CD-ROM (UEFI, no TPM, disk known by id), then apply, a reboot that waits for the LUKS passphrase at the console, and verify - as an operator would, with nothing from `.secrets/` (DEFECTS 7.35). |
| `vm/byo-lab-init.sh` | Create the BYO lab directory on a new workstation: random secrets, the lab inventory's vault, `env.sh` (paths only); only what is missing, and it removes what the container retired (DEFECTS 7.16; TASKS C3, C4). |
| `tools/release-run.sh byo\|kickstart` | The release gate (TASKS R3), one lab at a time, at a committed worktree: every guest to a clean state (BYO: revert to `fresh`, or rebuild with `byo-guest.sh` if it has none; kickstart: reinstall with `build-vm.sh`), `harden-cycle.sh` on the collector and then each CUI host, a final verify of every host, and `summary.md` in `reports/runs/release-LAB-COMMIT-UTC/`. A host passes with `changed=0` and no failure beyond its documented retrofit limits. Destroys and rebuilds lab guests. `--reverify RUN_DIR` repeats only the final assessment at a later commit that changed no role, playbook, overlay or lab script (it refuses otherwise), reusing RUN_DIR's cycles. |
| `tools/console.py HOST 'cmd' ...` | The guest's serial console, scripted: logs in and runs commands where SSH cannot reach (a locked-out host, boot-time prompts); a module the rehearsals build on. Sends CR line endings and waits for each password prompt before answering, and stops at the first refused authentication — every failure, a cancelled prompt included, counts towards faillock. Needs `pexpect`. |
| `tools/probe.sh PROBE [HOSTS]` | Run a read-only probe from `tools/probes/` on hosts as root. `6b-evidence` shows the state behind DEFECTS 6b.2–6b.6; run it before and after a fix and diff. The `*-experiment` probes are self-cleaning tests of one behaviour (clevis binding and resealing; the role's bind script under `set -e`, against a bind that fails; rsyslog's peer-name check). |
| *Retired one-off proofs* | The rehearsals and proofs of closed defects - PCR 7 recovery, GRUB edit and pre-flight, LUKS rotation and staging, log rotation, POA&M spreadsheet, authored plans, a pending kernel, the SSH idle timeout, the stand-in SIEM and foreign receiver, collector attribution, the workstation and lab guards, assessor parity - are no longer in the tree (DEFECTS 7.36). Each reruns from the last commit that held it: `git worktree add /tmp/at-1195ace 1195ace`. |

## Rehearsing a guest

A guest is rehearsed from nothing: `vm/byo-guest.sh destroy NAME` and `build`, then
`tools/harden-cycle.sh NAME`.

The whole host from nothing is `tools/lab-from-scratch.sh --yes` (*On any
host*).

**A new forwarder must be admitted by the collector.** The collector's TLS
listener accepts only the certificate names in `nist_col_peers`, which is
`cui_hosts` as it stood when the collector was last applied. A host added to
the inventory afterwards is refused until the collector's 03.03.05 tasks run
again; `harden-cycle.sh` does that step (`apply.sh --limit COLLECTOR --tags
03.03.05`) whenever the host forwards to an inventory collector.
