# Operator runbook

How to run this thing. The [README](../README.md) explains *why* the tool is
built the way it is; this is the procedure.

Everything below was exercised against a hardened Rocky 9 guest unless a step
says otherwise. Where a recovery procedure is standard practice that has not
been rehearsed here, it says so.

**Contents**

- [Safety rules](#safety-rules)
- [Day 0 — prepare the control workstation](#day-0--prepare-the-control-workstation)
- [Day 0 — choose a target](#day-0--choose-a-target)
- [Day 1 — apply the overlay](#day-1--apply-the-overlay)
- [Day 1 — what changes about connecting](#day-1--what-changes-about-connecting)
- [Day 2 — what runs on its own](#day-2--what-runs-on-its-own)
- [Day 2 — where the evidence is](#day-2--where-the-evidence-is)
- [Reading an assessment](#reading-an-assessment)
- [Responding to a deviation](#responding-to-a-deviation)
- [Changing policy](#changing-policy)
- [Adding a log collector](#adding-a-log-collector)
- [When you are locked out](#when-you-are-locked-out)
- [Other things that will bite you](#other-things-that-will-bite-you)
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
   control and 25 more have residual obligations. See
   `/etc/nist-800-171/organizational-requirements.md` on the host.

---

## Day 0 — prepare the control workstation

```bash
cd nist_sp_800_171r3/rl9-171
make validate        # catalog <-> overlay <-> checks agree; no host needed
```

Required:

| For | Needs |
|---|---|
| Everything | `ansible-core` >= 2.14, `python3-yaml` |
| `make catalog` | `poppler-utils` (`pdftotext`) |
| `make vm` | `libvirt`, `virt-install`, `qemu`, `swtpm`, `edk2-ovmf` |
| Kickstart validation | `podman` (optional; skipped silently if absent) |

Ansible collections (`ansible.posix`, `community.general`) install on the
first `./apply.sh`.

`make catalog` re-extracts `catalog/requirements.json` from
`NIST.SP.800-171r3.pdf` and reproduces the committed file byte for byte. You
only need it if you change the extractor or substitute a different revision.

---

## Day 0 — choose a target

### An existing Rocky 9 host

The VM targets are **not** a prerequisite.

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
$EDITOR inventory/hosts.yml
```

Install-time controls the role cannot retrofit — a separate `/var/log/audit`
filesystem, FIPS from first boot — will be reported as deviations rather than
silently skipped. That is correct: on a host not installed that way, they are
real findings. Fixing them means a rebuild, not a playbook run.

### The reference VM

```bash
make secrets      # RSA-3072 key + admin password + LUKS passphrase
make iso          # download and checksum the Rocky 9 boot ISO
make vm           # unattended kickstart install, 15-25 min
```

`make vm` establishes what a role cannot: separate filesystems for `/home`,
`/tmp`, `/var`, `/var/log`, `/var/log/audit`, `/var/tmp` with
`nodev`/`nosuid`/`noexec`; FIPS from first boot; minimal package set; locked
root; UEFI + vTPM 2.0. It registers the guest in `inventory/hosts.yml` via
`tools/inventory.py` — it does not overwrite hosts already there.

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
| Key alone no longer authenticates | 03.05.03 sets `AuthenticationMethods publickey,password` | Supply the password factor. `lib/ssh-env.sh` does this via `SSH_ASKPASS`. |
| Host key changed after the first apply | 03.13.10 removes the weak DSA/ECDSA host keys | Expected once. `apply.sh` re-records it on success. `verify.sh` never does — an *unexpected* change stays an error. |
| `ping` times out | firewalld default zone target is DROP (03.13.06) | Not a fault. The host is reachable on its permitted services. |
| `last`, `lastlog`, `w` need root | `wtmp`/`btmp`/`lastlog` are audit information under 03.03.08a, mode 0600 | Use `sudo`. |

**Ad-hoc `ansible` commands need the SSH environment.** `apply.sh` and
`verify.sh` source `lib/ssh-env.sh`; a bare `ansible` invocation does not, and
against a hardened host it fails with
`Timeout waiting for privilege escalation prompt`. Source it first:

```bash
bash -c '. lib/ssh-env.sh; ansible rl9-cui-01 -b -m shell -a "systemctl status auditd"'
```

---

## Day 2 — what runs on its own

Seven timers provide the continuous monitoring strategy (03.12.03). Schedules
come from `roles/nist_800_171/defaults/main.yml` and are UTC.

| Timer | Runs | Does | Requirement |
|---|---|---|---|
| `nist-malware-scan.timer` | 03:00 daily | ClamAV scan (only if `nist_clamav_enabled`) | 03.14.02 |
| `nist-aide-check.timer` | 04:00 daily | AIDE integrity check | 03.14.06 |
| `nist-audit-review.timer` | 05:00 daily | `aureport`/`ausearch` summary | 03.03.05 |
| `nist-assessment.timer` | 06:00 daily | Full on-host assessment | 03.12.01 |
| `nist-inventory.timer` | daily | Refresh the component inventory | 03.04.10 |
| `nist-vuln-scan.timer` | Sun 02:00 | OpenSCAP authenticated scan | 03.11.02 |
| `dnf-automatic.timer` | daily | Security errata | 03.14.01 |

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
| `/etc/nist-800-171/system-security-plan.md` | SSP generated from live state (03.15.02) |
| `/etc/nist-800-171/organizational-requirements.md` | Everything the host cannot enforce, with the ODP values committed to |
| `/etc/nist-800-171/component-inventory.json` | Component inventory (03.04.10) |
| `/etc/nist-800-171/overlay-version` | Which overlay version is applied |
| `/etc/nist-800-171/mfa-status` | Whether pubkey MFA enforcement is on |
| `/etc/nist-800-171/log-forwarding-status` | Whether records are forwarded, or local-only |
| `/var/log/nist-800-171/assessment-latest.json` | Most recent on-host assessment |
| `/var/log/nist-800-171/poam-*.csv` | POA&M generated from failed checks (03.12.02) |
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

A healthy reference VM reports:

```
 43 satisfied            (technical requirements fully enforced and verified)
 26 partially satisfied  (host controls verified; organizational evidence still required)
  0 not satisfied
 28 organizational       (no host control exists; policy/process/physical)
 ----------------------------------------
 97 requirements assessed, 327 checks run, 0 failed
```

43 rather than 44 satisfied because 03.14.02 reports partial: fapolicyd
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
3. **Re-verify the one requirement:** `./verify.sh --requirement 03.13.11`
4. **Record what you could not fix.** `sudo nist-generate-poam` turns failed
   checks into a POA&M in `/var/log/nist-800-171/`.

---

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
receiving half: rsyslog on 514/tcp, one directory per sending host at mode
0700, rotation at the same `audit_retention_days` the records had at origin.

514/tcp is plain. That is acceptable only because the lab network is isolated
(03.13.01). For a real deployment use 6514 with TLS; the role does not
provision the certificates.

---

## When you are locked out

Console access is the way back in. On the reference VM:

```bash
sudo virsh -c qemu:///system console rl9-cui-01
```

The admin password is in `.secrets/admin_password`. Root is locked by design
(03.01.06) — log in as the admin user and `sudo`.

*The procedures below are standard practice for these controls and have not
been rehearsed against this baseline. Take a snapshot before you need them.*

| Cause | From the console |
|---|---|
| Account locked by faillock after 3 failures (03.01.08) | `sudo faillock --user <name> --reset` — or wait out `lockout_duration_seconds` (default 900) |
| MFA enforced before operators enrolled keys | `sudo sed -i 's/^AuthenticationMethods.*/AuthenticationMethods publickey/' /etc/ssh/sshd_config.d/00-nist-800-171.conf && sudo systemctl reload sshd`, then set `nist_mfa_enforce_pubkey: false` and re-apply so the change survives |
| Your key is ed25519 and FIPS rejects it | Add an RSA-3072 key to the admin user's `authorized_keys` from the console |
| Firewall locked out your source network | `sudo firewall-cmd --add-source=<cidr> --zone=trusted` (add `--permanent` and reload to persist) |

A reverted control is a deviation. `./verify.sh` will report it, which is
correct — re-apply properly once you are back in.

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
make destroy       # removes the CUI VM and the collector, and their disks
make clean         # removes reports and the generated inventory; keeps the ISO
```

`make destroy` also drops each host from `inventory/hosts.yml`. The ISO,
catalog and `.secrets/` survive both, so a rebuild does not re-download or
re-key.

To decommission a real host rather than a lab guest, sanitization is a
documented process, not a command — see 03.08.03 in
`organizational-requirements.md`. `nist-sanitize-media` implements the
mechanical part only.
