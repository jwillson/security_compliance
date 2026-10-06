# Operator runbook

How to run this thing. The [README](../README.md) explains *why* the tool is
built the way it is; this is the procedure.

Everything below was exercised against the two hardened Rocky 9 guests of the
reference lab — a CUI host and a log collector — unless a step says otherwise. Every recovery procedure in "When you are locked out"
has been rehearsed against this baseline on a retrofit guest; where the rehearsal changed the advice, the step says what happened.

**Contents**

- [Safety rules](#safety-rules)
- [Day 0 — prepare the control workstation](#day-0--prepare-the-control-workstation)
- [Day 0 — choose a target](#day-0--choose-a-target)
- [Day 1 — apply the overlay](#day-1--apply-the-overlay)
- [Day 1 — what changes about connecting](#day-1--what-changes-about-connecting)
  - [Anything outside apply.sh / verify.sh needs the SSH environment](#anything-outside-applysh--verifysh-needs-the-ssh-environment)
- [Day 2 — what runs on its own](#day-2--what-runs-on-its-own)
- [Day 2 — where the evidence is](#day-2--where-the-evidence-is)
- [Reading an assessment](#reading-an-assessment)
- [Responding to a deviation](#responding-to-a-deviation)
- [Changing policy](#changing-policy)
- [Adding a log collector](#adding-a-log-collector)
- [When you are locked out](#when-you-are-locked-out)
- [Other things that will bite you](#other-things-that-will-bite-you)
- [Rotating the automation account's password](#rotating-the-automation-accounts-password)
- [Rotating the LUKS passphrase](#rotating-the-luks-passphrase)
- [Rotating the lab credentials](#rotating-the-lab-credentials)
- [Decommissioning](#decommissioning)

---

## Safety rules

1. **Never apply to the machine you are working from.** `./apply.sh` disables
   root login, enforces MFA on sshd, sets the firewall default target to DROP
   and turns on deny-by-default execution. On your workstation that is a
   self-inflicted outage.
2. **`--check` first, always.** `./apply.sh --check --diff` changes nothing
   and shows exactly what would move.
3. **`./verify.sh` is read-only.** It copies the assessor to the target and
   runs it. It never remediates, and it never re-records a changed host key.
4. **A clean assessment is not authorization.** 28 requirements have no host
   control and 31 more carry residual obligations. See
   `/etc/nist-800-171/organizational-requirements.md` on the host.

---

## Day 0 — prepare the control workstation

```bash
cd nist_sp_800_171r3/rl9-171
make validate        # catalog <-> overlay <-> checks agree; no host needed
```

To harden and assess hosts you already have, the workstation needs only
podman or docker: `./nist` runs any command inside the control-plane
container (`./nist make validate`, `./nist ./apply.sh`, `./nist ./verify.sh`;
README, *Quick start*). The rest of this section is for running the labs,
which build VMs on this host.

Check the host first; it names what is missing and the `apt`, `dnf` or
`pacman` command to install it, and installs nothing itself:

```bash
make host-check      # KVM, memory, libvirt, virt-install, swtpm, Secure Boot firmware, Python >= 3.12
make tools           # the pinned ansible-core and collections (make all does it)
```

`make tools` builds the Ansible this project pins (`vm/byo-lab-init.sh
--tools-only`, into `$NIST_BYO_LAB`, default `~/.local/share/nist-byo-lab`),
and every `make` target puts it on `PATH`. To harden a host you brought with
no lab at all, any `ansible-core` >= 2.14 with `python3-yaml` on `PATH` does;
the collections install on the first `./apply.sh`.

`make catalog` re-extracts `catalog/requirements.json` from
`NIST.SP.800-171r3.pdf` and reproduces the committed file byte for byte. You
only need it if you change the extractor or substitute a different revision.

---

## Day 0 — choose a target

### An existing Rocky 9 host

Neither the VM targets nor `.secrets/` are prerequisites. The role consumes
two secrets, and a host you bring supplies them from the environment:

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
$EDITOR inventory/hosts.yml
export NIST_BECOME_PASSWORD=...  # sudo, if the host asks for one
export NIST_GRUB_PASSWORD=...    # 03.10.07 bootloader superuser
export NIST_LUKS_PASSPHRASE=...  # 03.08.09, only if the host has free VG space
```

The GRUB superuser is `root` with `NIST_GRUB_PASSWORD`: GRUB asks for both to
edit a boot entry or reach its shell, never to boot one - every BLS entry is
`--unrestricted`, and the role checks that before it sets a password and
leaves the boot path alone if one is not (`pe-07-boot-entries-unrestricted`).
To recover a host whose GRUB password is lost, boot normally, then re-apply
with a new `NIST_GRUB_PASSWORD` (`--tags 03.10.07`); to remove it, empty
`/boot/grub2/user.cfg`.

With a TPM, the passphrase is not what opens the CUI volumes day to day: the
role binds each volume to the TPM and deletes the staged key, so nothing on
the disk can open them. The passphrase keyslot stays as the **recovery
key** — keep it where you keep other break-glass secrets; it is the only way
in if the TPM ever refuses (see *When you are locked out*).

Without a TPM there is nowhere to seal the key, and none is left on the disk:
every boot stops at the console and asks for the passphrase before the CUI
filesystems mount (ODP-REVIEW I5). Plan for a person at the console - the
BMC's, for a remote machine - at each reboot, `./apply.sh --reboot`
included. `tools/probes/hardware.sh` tells you beforehand which kind of
host you have.

Leave one unset and the control it feeds is skipped with a warning and
reported by `./verify.sh` as a deviation; the run does not abort. `.secrets/`
is read only when the environment says nothing, which is how the lab works.

Install-time controls the role cannot retrofit — a separate `/var/log/audit`
filesystem, FIPS from first boot — will be reported as deviations rather than
silently skipped. That is correct: on a host not installed that way, they are
real findings. Fixing them means a rebuild, not a playbook run.

### A new bare-metal host

The install-time controls - separate filesystems with their mount options,
FIPS from first boot, the minimal package set, the free space the role
carves the encrypted volumes from - come only from installing with the
project's kickstart. `install/iso.sh` puts it into the Rocky 9 boot ISO for
one machine; the workstation needs only podman or docker (it runs in the
control-plane image).

```bash
# 1. What the machine offers, if it runs any Linux now (read-only):
ssh HOST sudo bash -s < tools/probes/hardware.sh
#    firmware must be UEFI; note Secure Boot, the TPM, and the disk's
#    /dev/disk/by-id/ name - the one disk the install will wipe.

# 2. Its install ISO (written 0600 under iso/: it holds the admin password's hash):
make iso
export NIST_BECOME_PASSWORD=...           # the admin account's password, and sudo's
./install/iso.sh HOST --disk /dev/disk/by-id/ID [--console tty0|ttyS1] [--key ~/.ssh/id_rsa.pub]
```

3. Attach `iso/HOST-install.iso` as the BMC's virtual media (or write it to a
   USB stick), and boot it in UEFI mode. It installs unattended - wiping the
   disk named and no other; on a machine without that disk it stops - and
   reboots into Rocky 9. Detach the media, and delete the ISO.
4. Register it and harden it as a host you brought:

```bash
./tools/inventory.py add HOST --ip ADDRESS --user cuiadmin --connection byo --key ~/.ssh/id_rsa
export NIST_GRUB_PASSWORD=... NIST_LUKS_PASSPHRASE=...
./apply.sh --limit HOST --reboot && ./verify.sh --host HOST
```

`--console` is where the installer's screen and every later passphrase
prompt appear: `tty0`, the default, is the screen a BMC's virtual KVM shows;
`ttyS0`/`ttyS1` is serial-over-LAN. The other gets the kernel's messages too.
Without a TPM, the reboot in step 4 waits for the LUKS passphrase at that
console. `tools/rehearse-baremetal.sh` is this procedure in the lab - a guest
booted from the ISO alone, UEFI, no TPM - and proves it end to end.

### The reference VM

```bash
make all          # host check, tools, catalog, secrets, ISO, the CUI VM, apply, verify
make vm-log && make pki && make apply && make verify   # the collector, then both again
```

`make all` runs from a bare clone on any host that `make host-check` passes:
it creates the lab network if it is missing, installs unattended (15-25 min),
applies with the reboot the first apply owes (`apply.sh --reboot`), and
verifies. Step by step it is `make secrets` (RSA-3072 key, admin password,
LUKS passphrase), `make iso`, `make vm`, `make apply`, `make verify`.

If the install stops - the installer's console silent for 20 minutes, most
often because the guest cannot reach the Rocky mirror - `build-vm.sh` says
so, shows the console's last lines and the likely causes, and leaves the VM
up to inspect (docs/LAB.md, *When an install stops*).

Both roles install at 4096 MB — the Rocky 9 network installer needs it — and a
collector is trimmed back to 2048 MB once the install finishes.

`make vm` establishes what a role cannot: separate filesystems for `/home`,
`/tmp`, `/var`, `/var/log`, `/var/log/audit`, `/var/tmp` with
`nodev`/`nosuid`/`noexec`; FIPS from first boot; minimal package set; locked
root; UEFI + vTPM 2.0. It registers the guest in the kickstart lab's
inventory, `inventory/kickstart.yml`, via `tools/inventory.py` — it does not
overwrite hosts already there — and `make apply` / `make verify` read the
same file.

```bash
./tools/inventory.py show      # what is in the inventory and where it forwards
```

---

## Day 1 — apply the overlay

```bash
./apply.sh --check --diff                 # change nothing, report drift
./apply.sh --check --diff --tags 03.05    # one family
./apply.sh                                # apply everything
./apply.sh --tags 03.05.07                # one requirement
./apply.sh --limit rl9-cui-01             # one host
```

Every task carries its requirement ID as a tag, so `--tags 03.05.07` applies
exactly the tasks implementing Password Management and nothing else.

Recommended first run on a host you care about:

```bash
./apply.sh --check --diff | tee /tmp/nist-preview.txt   # read it
./apply.sh --tags 03.03                                  # audit only, low risk
./verify.sh --family 03.03                               # confirm
./apply.sh                                               # then the rest
```

The role is idempotent: a second consecutive run reports `changed=0`, which is
what makes `./apply.sh --check` a meaningful drift detector rather than
permanent noise.

**FIPS needs a reboot.** If the run reports `Reboot required: True`, reboot
before assessing — `03.13.11` checks the running kernel's crypto state, not
the configuration file.

---

## Day 1 — what changes about connecting

Each of these is a control working. Each looks like a broken tool the first
time you hit it.

| Symptom | Cause | What to do |
|---|---|---|
| `signature algorithm ssh-ed25519 not in PubkeyAcceptedAlgorithms` | FIPS policy (03.13.11) excludes ed25519 | Use RSA >= 3072 or ECDSA P-256/384. `make secrets` generates RSA-3072. |
| Key alone no longer authenticates; you are asked for a password | 03.05.03 sets `AuthenticationMethods publickey,password` | Expected. Source `lib/ssh-env.sh`, or type the password from `.secrets/admin_password`. See below. |
| Host key changed after the first apply | 03.13.10 removes the weak DSA/ECDSA host keys | Expected once. `apply.sh` re-records it on success. `verify.sh` never does — an *unexpected* change stays an error. |
| `ping` times out | firewalld default zone target is DROP (03.13.06) | Not a fault. The host is reachable on its permitted services. |
| `last`, `lastlog`, `w` need root | `wtmp`/`btmp`/`lastlog` are audit information under 03.03.08a, mode 0600 | Use `sudo`. |

### Anything outside apply.sh / verify.sh needs the SSH environment

This is the first thing that will confuse you, and it is the control working.

After `./apply.sh`, `sshd -T` reports
`authenticationmethods publickey,password` (03.05.03). Your key authenticates
as factor one and sshd then demands factor two. `apply.sh` and `verify.sh`
source `lib/ssh-env.sh`, which points `SSH_ASKPASS` at `.secrets/askpass.sh`
and sets `SSH_ASKPASS_REQUIRE=force` so ssh uses it even with a terminal
attached. Nothing else does.

So a plain `ssh` prompts you for the admin password:

```
cuiadmin@10.0.0.10: Permission denied (password).     # with BatchMode
cuiadmin@10.0.0.10's password:                        # without
```

and a bare `ansible` fails with
`Timeout waiting for privilege escalation prompt`.

Use the scripts, which supply the second factor from the inventory and the
lab's askpass, so nothing is typed and nothing wrong is offered (three wrong
passwords lock the account, 03.01.08):

```bash
./tools/lab-ssh.sh rl9-cui-01                         # a shell
./tools/lab-ssh.sh rl9-cui-01 'sudo systemctl status auditd'
./tools/lab-console.sh rl9-cui-01                     # the serial console, when SSH cannot
bash -c '. lib/ssh-env.sh; ansible rl9-cui-01 -b -m shell -a "systemctl status auditd"'
```

Both find the host in whichever lab's inventory lists it. What you must not do is
"fix" a refused login by relaxing `AuthenticationMethods`, which is the
requirement itself.

The `ssh` line printed by `vm/build-vm.sh` reflects this. A plain `ssh` works
against a freshly built guest and stops working the moment you apply the
overlay.

---

## Day 2 — what runs on its own

Seven timers provide the continuous monitoring strategy (03.12.03). Schedules
come from `roles/nist_800_171/defaults/main.yml` — except `dnf-automatic`,
which is overridden in `tasks/si.yml` — and are UTC.

| Timer | Runs | Does | Requirement |
|---|---|---|---|
| `nist-malware-scan.timer` | 03:00 daily | ClamAV scan (only if `nist_clamav_enabled`) | 03.14.02 |
| `nist-aide-check.timer` | 04:00 daily | AIDE integrity check | 03.14.06 |
| `nist-audit-review.timer` | 05:00 daily | `aureport`/`ausearch` summary | 03.03.05 |
| `nist-assessment.timer` | 06:00 daily | Full on-host assessment | 03.12.01 |
| `nist-inventory.timer` | daily | Refresh the component inventory | 03.04.10 |
| `nist-vuln-scan.timer` | Sun 02:00 | OpenSCAP authenticated scan | 03.11.02 |
| `dnf-automatic.timer` | 01:00 daily | Security errata | 03.14.01 |

Check them:

```bash
systemctl list-timers --all | grep -iE 'nist|dnf-auto'
```

Eleven helper scripts are installed in `/usr/local/sbin`, all runnable by
hand:

```
nist-assess            nist-generate-poam     nist-privilege-report
nist-aide-check        nist-generate-ssp      nist-sanitize-media
nist-audit-review      nist-inventory         nist-vuln-scan
nist-malware-scan      nist-offboard-user
```

Two are operator actions rather than scheduled jobs:

```bash
sudo nist-offboard-user <username>            # offboarding (03.09.02)
sudo nist-sanitize-media [--clear] <device>   # media sanitization (03.08.03)
```

`nist-offboard-user` locks and expires the account, sets its shell to
`nologin`, renames its `authorized_keys`, drops its cron jobs and Kerberos
tickets, and terminates its sessions — then prints the parts of 03.09.02a it
cannot do, such as retrieving physical property. It is destructive and takes
effect immediately.

`nist-sanitize-media` requires a block device and refuses anything else.

---

## Day 2 — where the evidence is

On the host:

| Path | What |
|---|---|
| `/etc/nist-800-171/system-security-plan.md` | SSP, regenerated on every apply and assessment; your sections spliced in (03.15.02) |
| `/etc/nist-800-171/ssp.d/` | The SSP sections you write — never touched by the generators; an apply with `NIST_SSP_DIR` set replaces the host's copies with yours (see *Writing the SSP and working the POA&M*) |
| `/etc/nist-800-171/poam.csv` | The POA&M register, merged after every assessment; your columns carried forward (03.12.02) |
| `/etc/nist-800-171/organizational-requirements.md` | Everything the host cannot enforce, with the ODP values committed to |
| `/etc/nist-800-171/component-inventory.json` | Component inventory (03.04.10) |
| `/etc/nist-800-171/overlay-version` | Which overlay version is applied |
| `/etc/nist-800-171/mfa-status` | Whether pubkey MFA enforcement is on |
| `/etc/nist-800-171/log-forwarding-status` | Whether records are forwarded, or local-only |
| `/etc/nist-800-171/authorized-ports.d/` | Authorized listening ports, one fragment per role. The port checks subtract this; a port opened by hand and not declared here is a finding |
| `/etc/nist-800-171/log-collector-status` | On a collector: port, record directory, retention |
| `/var/log/nist-800-171/assessment-latest.json` | Most recent on-host assessment |
| `/var/log/nist-800-171/poam-*.csv` | Dated snapshots of the register, for the record |
| `/var/log/nist-800-171/oscap-report-*.html` | Vulnerability scan output |
| `/var/log/nist-800-171/security-advisories-*.txt` | Advisories (03.14.03) |

On the control workstation, `reports/<host>-<UTC timestamp>.{json,html}` per
`./verify.sh` run.

---

## Reading an assessment

```bash
./verify.sh                          # every host
./verify.sh --failed-only            # deviations only
./verify.sh --family 03.13           # one family
./verify.sh --requirement 03.05.07   # one requirement
./verify.sh --host rl9-cui-01        # one host
make report                          # open the newest HTML report
```

Five statuses, and the distinctions matter:

| Status | Means |
|---|---|
| `PASS` | Every check passed. Only ever claimed for something observed on the host. |
| `FAIL` | At least one check failed. A real deviation. |
| `MANUAL` | Host controls verified, organizational evidence still required. A `partial` requirement can never report PASS. |
| `NOT_APPLICABLE` | No host control exists — policy, process, personnel, physical. |
| `ERROR` | The check itself could not run. Investigate the check, not the host. |

A `PASS` is a discharged host obligation and nothing more: a requirement
with a `residual` is `partial`, and reports as partial however many of its
checks pass. `make validate` enforces that.

A healthy reference VM reports:

```
 36 satisfied            (technical requirements fully enforced and verified)
 33 partially satisfied  (host controls verified; organizational evidence still required)
  0 not satisfied
 28 organizational       (no host control exists; policy/process/physical)
 ----------------------------------------
 97 requirements assessed, 334 checks run, 0 failed
```

36 rather than 37 satisfied because 03.14.02 reports partial: fapolicyd
prevention is verified but ClamAV signature scanning needs EPEL, outside the
authorized repository set (03.17.03).

---

## Responding to a deviation

```
FAIL  03.13.11  Cryptographic Protection
        FAIL   sc-11-fips-proc: kernel crypto subsystem reports FIPS mode active
               expected: output == '1'
               observed: 0
```

1. **Read expected vs observed.** The check names both. It read effective
   state (`sshd -T`, `sysctl -n`, `auditctl -l`), not a config file, so this
   is what the running system is actually doing.
2. **Decide which of three things it is:**
   - *Drift* — someone changed the host. Re-apply that tag:
     `./apply.sh --tags 03.13.11`
   - *Never applied* — an install-time control on a host that was not built
     by `make vm`. A playbook cannot fix a filesystem layout. Rebuild, or
     accept it and open a POA&M item.
   - *A wrong check* — the host is genuinely compliant by another mechanism.
     Fix the check in `audit/checks.yml`, run `make validate`, and say why in
     the commit. Do not widen a check to make a red report green.
   - *ERROR, not FAIL* — the check could not look: a tool is missing, or it
     exited with a status the check does not declare normal (`ok_rc`). The
     observed line carries its stderr. Fix what stopped it (a dnf that
     cannot reach its repositories, a firewalld that is not running); do not
     add the status to `ok_rc` unless it genuinely means "nothing found".
3. **Re-verify the one requirement:** `./verify.sh --requirement 03.13.11`
4. **Record what you could not fix.** It already is: every failing
   requirement is an item in the POA&M register after the next scheduled
   assessment (or `sudo nist-generate-poam` now). Fill in its plan — below.

---

## Writing the SSP and working the POA&M

Both plans are regenerated from the host — on every apply and after every
scheduled assessment — and both keep what you write. (They used to rewrite
themselves from scratch, destroying it: DEFECTS 6.6.)

**The SSP's three sections only you can write** go in `/etc/nist-800-171/ssp.d/`
on the host, as Markdown; the plan splices them in and its first table says
which are written and when:

| File | Section | What an assessor looks for |
|---|---|---|
| `02-information-types.md` | 2. Information types | The CUI categories this system processes, stores and transmits, by NARA CUI Registry category and marking, and which of the three for each. (The CUI *locations* are generated.) |
| `03-threats.md` | 3. Threats of concern | Threats specific to this system, not a generic list — e.g. credential theft against its few administrators, supply chain through its package repositories, insider misuse of `cuiusers`, loss of the hardware, tampering with the audit trail — and where each comes from (ATT&CK technique IDs, CISA advisories). |
| `07-roles.md` | 7. Roles and responsibilities | Who holds each role — System Owner (accepts residual risk, approves the plan), System Administrator, Audit Administrator, ISSO. One person holding all of them is fine; say so. A Markdown table works. |

To keep them under version control, put them in a repository of your own —
not this public one — and set `NIST_SSP_DIR` to that directory: each apply
installs them, replacing the host's copies. Without it, edit on the host.

**The POA&M register** is `/etc/nist-800-171/poam.csv`, root-only. Each row is
an item:

- `deviation` — a requirement the host fails; the weakness is the failed
  checks. It closes itself, with the date, when the requirement passes; if it
  fails again later that is a new item.
- `residual` — a partial requirement's organizational obligation (the
  overlay's residual). The host can never evidence it, so **you** close it:
  set `Status` to `Closed` and say why in `Closure` (the procedure exists, the
  training was delivered, ...). It is not reopened.
- `Risk Accepted` — for either kind, when the System Owner accepts the risk
  instead; say who and until when in `Owner Notes`.

Your columns — `Scheduled Completion`, `Responsible Party`, `Resources
Required`, `Milestones`, `Owner Notes` — and your `Status` / `Closure`
changes are carried forward on every merge. Edit with anything that keeps it
a CSV (`sudo -e /etc/nist-800-171/poam.csv`). `ca-02-poam-register` fails if
a failing requirement has no active item. Purely organizational requirements
are not items; their register is `organizational-requirements.md`.

## Changing policy

Policy lives in `catalog/overlay-rocky9.yml` and nowhere else.

```bash
$EDITOR catalog/overlay-rocky9.yml   # odp: or odp_organizational:
make validate                        # catalog <-> overlay <-> checks agree
./apply.sh --check --diff            # see the effect
./apply.sh && ./verify.sh
```

- **`odp:`** — values the host enforces. The role applies them and the checks
  assert them via `{odp.name}`, so they cannot drift. Change
  `lockout_attempts` and both sides follow.
- **`odp_organizational:`** — the 47 assignments no host setting can satisfy
  (review frequencies, notification periods, named authorities). Nothing
  reads them to configure anything; they are rendered into
  `organizational-requirements.md` so the SSP cites a decision, not a blank.

Both ship with defaults drawn from common DoD CUI practice. **They are not
your organization's values.** `make validate` only confirms nothing references
a parameter that does not exist — it cannot tell you a number is wrong.

Never hand-edit a value into a task or a check. That is the drift the single
source of truth exists to prevent.

---

## Adding a log collector

A single host cannot demonstrate 03.03.05c: records are to be correlated
*across repositories*, and there is no second repository. The assessor reports
MANUAL, correctly, because nothing was observed.

```bash
make vm-log        # or ./vm/build-vm.sh --role log
./apply.sh         # CUI hosts now forward; the collector now receives
./verify.sh --requirement 03.03.05
```

`tools/inventory.py` wires the forwarders to the collector automatically.
Removing the collector unwires them. The collector never forwards to itself.

The collector is hardened by the same overlay — it holds other systems' audit
records, so it is a CUI host. `roles/nist_log_collector` adds only the
receiving half: rsyslog on 6514/tcp under TLS with mutual x509
authentication, one directory per sending host (by the address it came from, not the
hostname it claims) at mode 0700, rotation at the
same `audit_retention_days` the records had at origin.

Both sides need certificates: `ca.crt` and `HOST.crt`/`HOST.key` per host in
`NIST_PKI_DIR` (default `.secrets/pki`), `HOST` being the inventory name.
`make pki` mints a lab authority after the hosts are in the inventory; a
real deployment uses its own PKI's files in the same layout. Run it before
`./apply.sh`, or the forwarders record `tls-certificate-missing`, forward
nothing, and `verify.sh` reports them - there is no plaintext fallback.
`nist_log_tls: false` in the inventory is the explicit opt-out to 514 plain,
which `sc-08-forward-encrypted` then reports on every forwarder.

The forwarder authenticates the collector by the name in its certificate
(`nist_log_collector_name`, the `log_hosts` member by default), and the
collector accepts only certificates naming a `cui_hosts` member of the
inventory it was applied from. Moving the collector's port closes the old
one: ports no `authorized-ports.d` fragment declares are removed on apply.

---

## When you are locked out

Console access is the way back in. On a lab guest:

```bash
sudo virsh -c qemu:///system console rl9-cui-01
sudo virsh -c qemu:///system console rl9-log-01   # the collector
```

`./tools/inventory.py show` lists the guests and their addresses.

The lab admin password is in `.secrets/admin_password`; a host you brought
has whatever you gave it. Root is locked by design (03.01.06) — log in as
the admin user and `sudo`.

**First, quiet the console.** `LogDenied=all` (03.13.01) sends every dropped
packet to the kernel log, and the kernel log goes to the serial console, so
the prompt is buried within seconds. `sudo dmesg -n 1` silences it for the
session. (Every step below was rehearsed with the console scripted; the noise
was the first thing the script had to handle.)

**Before you need any of this, take a copy of the guest.** `virsh
snapshot-create-as` refuses a UEFI guest with raw NVRAM. Shut the guest down,
copy its qcow2 and its NVRAM file (`virsh dumpxml <guest> | grep nvram`), and
start it again; reverting is the reverse. That is how each procedure below
was rehearsed and reverted.

| Cause | What happens | From the console |
|---|---|---|
| Account locked by faillock after 3 failures (03.01.08) | The correct password is refused over SSH **and at the console**: the console login runs the same PAM stack. With root locked and one admin account, nobody can log in to run a reset during the lockout. | **Wait.** The lock expires `lockout_duration_seconds` (default 900) after the last failure; then log in and `sudo faillock --user <name> --reset` clears the tally, or simply carry on. For a single-admin host, create a second administrative account before you need it: faillock is per user, so it is not locked when the first one is. |
| MFA enforced before operators enrolled keys | Key-only logins are refused with "Permission denied". | `sudo sed -i 's/^AuthenticationMethods.*/AuthenticationMethods publickey/' /etc/ssh/sshd_config.d/00-nist-800-171.conf && sudo systemctl reload sshd`. Rehearsed verbatim: key-only login works immediately, `./verify.sh --requirement 03.05.03` reports `ia-03-sshd-authmethods` as failing, and `./apply.sh --tags 03.05.03` restores enforcement. To keep it off, set `nist_mfa_enforce_pubkey: false` and re-apply. |
| Your key is ed25519 and FIPS rejects it | `signature algorithm ssh-ed25519 not in PubkeyAcceptedAlgorithms` at preauth. | Add an RSA-3072 key to the admin user's `authorized_keys` from the console. |
| Boot never reaches a login prompt; the console shows "Please enter passphrase for disk vg_sys-lv_cui (cui_data)" | The TPM would not release the volume keys. They are sealed to PCR 7, the Secure Boot state, so a firmware or Secure Boot database update (a `dbx` revocation from `fwupd`, new keys, Secure Boot toggled) or a cleared TPM changes it, from the next boot on. Remote access is gone until the passphrase is typed. **The prompt alone is not the symptom:** it is shown on every boot while clevis answers it from the TPM a second later — the symptom is that it stays. | Type `NIST_LUKS_PASSPHRASE` at the prompt (systemd tries it on the second volume too, so usually once). Once up, `./verify.sh` reports `mp-09-luks-tpm-bound`: "stale binding - the TPM will not release the key". **First check Secure Boot** — `mp-09-secure-boot`. If it is off, turn it back on in the firmware before anything else: a seal made with Secure Boot off would open for any boot medium, so the role will not reseal then (ODP-REVIEW I1). It puts the key back on disk so the host boots unattended meanwhile, and reports it. With Secure Boot on again the original seal is often valid once more: re-apply and the role finds it so, removes the key and returns crypttab to the TPM. If the binding is still stale with Secure Boot on (a `dbx` update or new keys changed PCR 7), reseal from the control workstation: `NIST_LUKS_PASSPHRASE=... ./apply.sh --limit <host> --tags 03.08.09` (the role runs `clevis luks regen` with the passphrase), `./verify.sh` passes again, and the next boot unlocks alone. By hand instead: `sudo clevis luks regen -d /dev/vg_sys/lv_cui -s <slot>` per volume, only with Secure Boot enforced. **Rehearsed** with `tools/rehearse-pcr7-recovery.py` (Secure Boot turned off to change PCR 7: the boot waits for the passphrase, the role declines to reseal and keeps the host bootable, Secure Boot restored, the original seal holds, and the next boot unlocks from the TPM alone). |
| sshd penalised your address (OpenSSH 9.8+ `PerSourcePenalties`, default on) | Every new connection from one workstation is reset before the banner - `kex_exchange_identification: read: Connection reset by peer`; `ssh -v` shows `banner line 0: Not allowed at this time`. Other workstations, and other hosts from this one, are unaffected. Earned by connections that fail or are dropped before authenticating (a stalled tool, a run killed mid-login), and it grows with repeats. | **Wait.** It lifts by itself, at most 10 minutes after the last offence; retrying meanwhile does not help. Nothing in the role sets it. If it recurs, find what keeps abandoning logins before raising anything on the host. |
| Firewall locked out your source network | New SSH connections time out; an existing session may survive. | `sudo firewall-cmd --add-source=<cidr> --zone=trusted` gets you back in immediately (rehearsed verbatim). It exempts that address from the firewall entirely, so do not leave it: once you are in, restore the authorized services with `./apply.sh --tags 03.13`, which also removes any trusted-zone exemption, and `sc-06-no-trusted-bypass` reports one that remains. Do **not** make it `--permanent` unless you accept the bypass until the next apply. |

A reverted control is a deviation. `./verify.sh` reports each of the above
(rehearsed for MFA and for the firewall bypass) — re-apply properly once you
are back in.

---

## Other things that will bite you

**fapolicyd blocks an application.** It enforces deny-by-default execution. On
a host with unprofiled workloads this will stop things.

```yaml
nist_fapolicyd_permissive: true    # log instead of block, while profiling
```

Re-apply, profile from the logs, write rules into
`/etc/fapolicyd/rules.d/`, then turn enforcement back on.

**ClamAV is off by default.** It needs EPEL, which is outside the authorized
repository set (03.17.03). Enabling it is an explicit trade-off, not a
silent one:

```yaml
nist_clamav_enabled: true
nist_enable_epel: true
```

**authselect owns the PAM stack.** The role reasserts the profile if
`authselect check` fails. Do not hand-edit files under `/etc/pam.d/` — they
are generated, and your edit will be reverted on the next run while breaking
`authselect check` in the meantime.

**A later sshd drop-in cannot weaken the baseline.** The role writes
`00-nist-800-171.conf`; sshd honours the *first* occurrence of a keyword and
reads the drop-in directory in sorted order. A `99-local.conf` setting
`PermitRootLogin yes` has no effect, and the assessor will correctly report
the host as still compliant. Verify with `sshd -T`, not by reading files.

---

## Rotating the automation account's password

The account `apply.sh` connects as (the inventory's `ansible_user`) signs in
with its key **and** its password (03.05.03). Password expiry would end its
sign-in on day 60 and the inactivity lock disable it 35 days later, cutting
off the run that hardens the host, so it is exempt from both (ODP-REVIEW
I2): the role lists it in `/etc/nist-800-171/aging-exempt`, and the checks
skip exactly that name. It is rotated by hand instead, every 60 days
(`auth_refresh`), and `ia-12-exempt-rotated` reports a password older than
that as a deviation.

**Every connection that still offers the old password after the change is a
failed authentication, and three in a row lock the account (03.01.08).**
So change it, then update the stored copy, then run anything else:

1. Choose a password the policy accepts (03.05.07: length, classes, not
   reused). The minimum age is one day, so it cannot be changed twice the
   same day.
2. Change it on the host, over one interactive session:
   `ssh <user>@<host>` (key, then the current password) and `passwd`.
3. At once, update where the workstation keeps it: `NIST_BECOME_PASSWORD`
   and whatever your `SSH_ASKPASS` reads (BYO lab: `$NIST_BYO_LAB/byoadmin_password`;
   kickstart lab: `.secrets/admin_password`). One password for several
   hosts means changing it on each before updating the copy - or give each
   host its own.
4. `./verify.sh --host <host> --requirement 03.05.12`: the connection
   works with the new factor and `ia-12-exempt-rotated` passes.

If the account is locked anyway: *When you are locked out*, faillock.

---

## Rotating the LUKS passphrase

The passphrase is what opens the CUI and backup volumes when the TPM will
not - recovery at the console - and what the role is given to create them.
Rotate it on the schedule your key management sets (03.13.10), when someone
who knew it leaves, or when it may have been seen:

```bash
NIST_LUKS_PASSPHRASE=<current> NIST_LUKS_NEW_PASSPHRASE=<new> \
  ansible-playbook rotate-luks-passphrase.yml --limit <host>
```

It changes the passphrase keyslot of each volume (PBKDF2), proves the new one
opens it and the old one no longer does, and on a host that keeps its key on
disk (no TPM, or Secure Boot off) rewrites that file. The TPM binding is a
separate keyslot and keeps working. Both passphrases are staged in RAM and
removed. A second run reports no change. **Then** give the role the new one:
set `NIST_LUKS_PASSPHRASE` to it, and keep it where you keep recovery
secrets - without it, a boot the TPM refuses cannot be unlocked.

One passphrase for every host is the simple arrangement, and the weak one: a
host's own `nist_luks_passphrase` in the inventory (vault-encrypted) takes
precedence over the environment, so each host can have its own. Rehearsed
with `tools/rehearse-luks-rotation.sh` (DEFECTS 7.14).

---

## Rotating the lab credentials

`.secrets/` holds a real private key, the admin password and the LUKS
passphrase. It is gitignored at two levels and has never been committed.

Rotating it invalidates any VM built with it — the public key is in the
guest's `authorized_keys` and the password hash is in its `/etc/shadow`. So
rotate at rebuild time, when it is free:

```bash
make destroy
rm -rf .secrets
make secrets
make vm
```

Do not rotate while a guest you still need is running; you will lock yourself
out of it.

---

## Decommissioning

```bash
make destroy       # the kickstart VMs and all they left; the lab network if unused
make teardown      # both labs and everything they left on the host (asks first)
tools/lab-residue.sh   # what is left, if anything
make clean         # reports only
```

Each destroy removes a guest's disk, UEFI variables, TPM state, logs, host
key and inventory entry. `make teardown` also removes the BYO guests, the
stand-in SIEM, the lab network, the staged ISO and the BYO base image, and
fails if `tools/lab-residue.sh` still finds anything. The downloaded ISO,
the catalog, `.secrets/` and the BYO lab's secrets survive, so a rebuild
neither re-downloads nor re-keys; delete those by hand only if you will not
rebuild.

To decommission a real host rather than a lab guest, sanitization is a
documented process, not a command — see 03.08.03 in
`organizational-requirements.md`. `nist-sanitize-media` implements the
mechanical part only.
