# NIST SP 800-171r3 → Rocky Linux 9

A repeatable toolchain that extracts the security requirements from NIST
SP 800-171r3, maps the ones a Linux host can enforce onto Rocky Linux 9,
applies them, and then independently verifies that they are actually in place.

```
  PDF ──extract──▶ catalog ──overlay──▶ Ansible role ──apply──▶ hardened host
                      │                                              │
                      └──────────────▶ checks ──assess───────────────┘
                                                     │
                                          JSON + HTML + POA&M
```

Four artifacts, each with one job:

| Artifact | Purpose |
|---|---|
| `catalog/requirements.json` | All 130 requirements parsed from the PDF (97 active, 33 withdrawn) |
| `catalog/overlay-rocky9.yml` | What Rocky 9 can enforce for each, and what it cannot |
| `roles/` | `nist_800_171/` applies the overlay to every CUI host; `nist_log_collector/` adds the receiving half of 03.03.05c on a log host |
| `audit/` | An assessor that verifies the host, written independently of the role |

Day-to-day procedure — building, applying, assessing, and getting back in when
a control locks you out — is in [docs/RUNBOOK.md](docs/RUNBOOK.md). This README
is the design: what the tool does and why.

---

## Quick start

```bash
make all        # catalog → secrets → ISO → VM → apply → verify
```

Or step by step:

```bash
make catalog    # parse the PDF into a machine-readable catalog
make validate   # confirm catalog, overlay and checks agree
make secrets    # generate the automation key and credentials
make iso        # download and checksum the Rocky 9 boot ISO
make vm         # unattended install of the hardened reference VM
make vm-log     # log collector, so record forwarding can be verified
                # (`make all` builds the CUI host only)
make pki        # lab CA + a certificate per host, for TLS forwarding
make apply      # apply the overlay via Ansible
make verify     # assess all 97 requirements, write JSON + HTML
make report     # open the newest HTML report
```

---

## How the requirements were divided

800-171r3 has **97 active requirements**. Most published "800-171 hardening
scripts" quietly cover only the technical subset and report 100%. This overlay
classifies every requirement explicitly, and the assessor reports the
organizational ones as `NOT_APPLICABLE(host)` rather than `PASS`:

| Disposition | Count | Meaning |
|---|---|---|
| **technical** | 37 | The host enforces it. A failing check is a real finding. `make validate` refuses a technical entry that carries a `residual`. |
| **partial** | 32 | The host enforces part of it; `residual` names what the organization still owes, and the assessor reports it as partial even when every check passes. |
| **organizational** | 28 | Policy, process, personnel, physical. No host setting satisfies it. |

Assessment result for a host on which every check passes, such as the
kickstart-built reference lab:

```
 36 satisfied            (technical requirements fully enforced and verified)
 33 partially satisfied  (host controls verified; organizational evidence still required)
  0 not satisfied
 28 organizational       (no host control exists; policy/process/physical)
 ----------------------------------------
 97 requirements assessed, 330 checks run, 0 failed
```

36 rather than 37 satisfied, because 03.14.02 (Malicious Code Protection)
reports *partially satisfied*: fapolicyd prevention is verified, but ClamAV
signature scanning needs EPEL, which is outside the authorized repository set
(03.17.03). That trade-off is opt-in via `nist_clamav_enabled`, not decided
silently.

A requirement marked `partial` can never report `PASS`, only `MANUAL` — every
host-side check passed, but organizational evidence is still required. That is
deliberate: a green report must never imply the system is authorized.

The full breakdown, including the residual obligation for each partial
requirement, is generated onto the host at
`/etc/nist-800-171/organizational-requirements.md`.

---

## Why verification is separate from remediation

The assessor (`audit/nist-assess` + `audit/checks.yml`) never reads the role's
variables or task files, and never trusts Ansible's own `changed=0`. It
inspects **effective** system state, preferring the runtime view over the file
the role wrote:

| Checked via | Instead of |
|---|---|
| `sshd -T` | reading `sshd_config` |
| `sysctl -n` | reading `/etc/sysctl.d/` |
| `auditctl -l` | reading `/etc/audit/rules.d/` |
| `systemctl is-enabled` | reading unit files |
| `firewall-cmd --list-services` | reading firewalld XML |

So a setting that was written but never took effect — a typo'd sysctl, a rule
rejected by the kernel, a service that failed to start — is caught.

330 checks cover the 69 enforceable requirements. Each declares exactly one
assertion (`expect_output`, `expect_match`, `expect_int`, …) and reports the
expected value alongside what was actually observed.

```
FAIL  03.13.11  Cryptographic Protection
        FAIL   sc-11-fips-proc: kernel crypto subsystem reports FIPS mode active
               expected: output == '1'
               observed: 0
```

### Policy values live in one place

Organization-defined parameters (ODPs) — lockout thresholds, password
composition, retention periods, timeouts — are defined once in the `odp:` block
of `catalog/overlay-rocky9.yml`. The role applies them and the checks assert
against them via `{odp.name}` substitution, so the two can never drift. Change
the lockout threshold there and both sides follow.

The publication leaves 47 more parameters to the organization that no host
setting can satisfy: review frequencies, notification periods, named
authorities, policy statements. Those live in the same file, under
`odp_organizational:`, keyed to the requirement that asks for them. Nothing
reads them to configure anything and no check asserts them — they are rendered
into `/etc/nist-800-171/organizational-requirements.md` so that each residual
obligation carries the organization's decision instead of a blank, and so the
SSP has one place to cite.

The distinction is the point. `lockout_attempts: 3` is evidence, because the
assessor observes it on every run. "Report suspected incidents within 1 hour"
is a commitment, and nothing on the host can demonstrate it was kept. Both
still have to be written down somewhere.

Both blocks ship with defaults drawn from common DoD CUI practice. **They are
not your organization's values.** `make validate` will not tell you whether
they are right — only that nothing references a parameter that does not exist.

---

## Usage

```bash
./apply.sh                       # apply everything
./apply.sh --tags 03.03          # one family
./apply.sh --tags 03.05.07       # one requirement
./apply.sh --check --diff        # report drift, change nothing

./verify.sh                      # assess every host
./verify.sh --failed-only        # only deviations
./verify.sh --family 03.13       # one family
./verify.sh --requirement 03.05.07
```

Every task carries its requirement ID as a tag, so `--tags 03.05.07` applies
exactly the tasks implementing Password Management and nothing else.

### Applying to an existing host

The role is not VM-specific, and neither the VM targets nor `.secrets/` are
prerequisites. Point the inventory at any Rocky 9 host reachable over SSH
with sudo, and supply the two secrets the role consumes from your own
environment:

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
$EDITOR inventory/hosts.yml
export NIST_BECOME_PASSWORD=...  # sudo, if the host asks for one
export NIST_GRUB_PASSWORD=...    # 03.10.07 bootloader superuser
export NIST_LUKS_PASSPHRASE=...  # 03.08.09, only if the host has free VG space
./apply.sh --check --diff        # dry run; completes on a host never applied
./apply.sh && ./verify.sh
```

Without `NIST_GRUB_PASSWORD` the bootloader is left as it is and
`pe-07-grub-password` is reported as a deviation; without
`NIST_LUKS_PASSPHRASE` on a host with room for the CUI volumes, 03.08.09 and
03.13.08 are skipped and reported. Neither aborts the run. The lab build
supplies both from `.secrets/` (`make secrets`), which the role reads only
when the environment says nothing.

**What a retrofit reports.** Proven against a stock Rocky 9.8 GenericCloud
guest (UEFI, one root partition, no LVM, FIPS off, no firewalld) driven from
an Ubuntu workstation with no `.secrets/`: the dry run completes on the
never-applied host, the apply completes with one reboot, and the assessment
reports **34 satisfied, 30 partial, 5 not satisfied, 28 organizational** —
330 checks, 6 failed — against 36 / 33 / 0 / 28 for a host on which every
check passes.
Every failure is an install-time limit the role records rather than hides:

| Requirement | Check | Why a retrofit cannot satisfy it |
|---|---|---|
| 03.04.06 | `cm-06-mount-options`, `cm-06-tmp-separate` | `/home`, `/tmp`, `/var/tmp`, `/var/log`, `/var/log/audit` are not separate filesystems; the role writes `unretrofittable-mounts` naming them |
| 03.01.18, 03.08.03, 03.08.09, 03.13.08 | one LUKS check each | the encrypted CUI and backup volumes need free space in `vg_sys`; this host has no volume group |

FIPS (03.13.11) is *not* on that list: it retrofits with one reboot. A host
with an LVM root and 3 GB free passes the LUKS checks too, given
`NIST_LUKS_PASSPHRASE`. The apply after the reboot records the kernel the
security updates installed and is otherwise settled; the apply after that
reports `changed=0`, and so does `./apply.sh --check` on the hardened host.

```yaml
# inventory/hosts.yml
cui_hosts:
  hosts:
    server-01:
      ansible_host: 10.0.0.10
      ansible_user: admin
      ansible_become: true
```

Install-time controls the role cannot retrofit (separate `/var/log/audit`,
FIPS from first boot) will be reported as deviations rather than silently
skipped.

The example inventory documents the connection consequences in full — they are
the same ones listed below, and each looks like a broken tool the first time.

---

## The reference VM

`vm/build-vm.sh` performs an unattended kickstart install establishing what
cannot be applied afterwards:

- **Separate filesystems** for `/home`, `/tmp`, `/var`, `/var/log`,
  `/var/log/audit`, `/var/tmp`, each with `nodev`/`nosuid`/`noexec` as
  appropriate (03.04.06). A full `/var` cannot starve audit logging.
- **FIPS mode from first boot** (03.13.11) via `fips-mode-setup` in `%post`.
- **Minimal package set** — no GUI, no legacy network services (03.04.06).
- **Locked root account**; access via a named admin account and sudo (03.01.06).
- **UEFI + vTPM 2.0**, so LUKS keys can be sealed to platform state (03.13.10).

The VM runs on an isolated libvirt network (`nist-lab`, `virbr17`) rather than
the shared `default` bridge, which keeps lab traffic separated (03.13.01).

```bash
./vm/build-vm.sh                      # build the CUI host (15-25 min, unattended)
./vm/build-vm.sh --role log           # build the collector
./vm/build-vm.sh --name rl9-cui-02 --disk-gb 60
./vm/build-vm.sh --destroy            # remove the CUI VM and its disk
./vm/build-vm.sh --role log --destroy # remove the collector
make destroy                          # both
```

`--destroy` resolves the name from `--role`, so the plain form leaves a
collector running.

The kickstart is validated with the real `pykickstart` parser (in a Rocky 9
container) before any VM is created, because a syntax error otherwise costs a
full install cycle to discover.

### The log collector

One host cannot demonstrate audit-record forwarding. 03.03.05c asks for
records to be correlated *across repositories*, and on a single VM there is no
second repository — the role writes the forwarding rule, nothing receives it,
and the assessor reports MANUAL because nothing was observed.

```bash
make vm-log        # or ./vm/build-vm.sh --role log
./apply.sh         # the CUI hosts now forward; the collector now receives
```

The collector is a CUI host too — it stores other systems' audit records — so
the same overlay hardens it, and `roles/nist_log_collector` adds only the
receiving half: rsyslog on 6514/tcp under TLS with mutual x509
authentication (03.13.08), one directory per sending host at mode 0700, and
rotation at the same `audit_retention_days` the records had at origin.
`tools/inventory.py` owns `inventory/hosts.yml` and points the forwarders at
the collector; adding or removing a log host rewires them.

Every host needs `ca.crt` and its own `HOST.crt`/`HOST.key` in
`NIST_PKI_DIR` (default `.secrets/pki`), where `HOST` is its inventory name:
`make pki` mints a lab authority for the inventory; a real deployment drops
its own PKI's files there. A forwarder without a certificate forwards
nothing, records `tls-certificate-missing`, and is reported by the assessor;
nothing falls back to plaintext. `nist_log_tls: false` is the explicit
opt-out (514 plain), and `sc-08-forward-encrypted` reports it.

Proven on the retrofit pair `byo-rl9-01` / `byo-log-01`: the forwarder logs
"TLS Connection initiated", both ends hold the established 6514 socket, a
probe record lands in the collector's per-host directory, and the checks
below pass on the side where each is meaningful.

Two checks then assert the path rather than the configuration:

| Check | Asserts |
|---|---|
| `au-05-forward-established` | rsyslog holds a live TCP connection to the collector. It queues to disk when the collector is unreachable, so a host can look configured and be forwarding nothing. |
| `au-05-collector-receiving` | The collector holds records from a host other than itself. |

Both degrade to MANUAL on a single-node lab rather than failing it: no
collector configured is the one-VM case, not a deviation.

---

## Things the hardened baseline changes about how you connect

These are consequences of controls working, not workarounds. They are listed
because each one looks like a broken tool the first time you hit it.

**Ed25519 keys stop working.** The FIPS crypto policy (03.13.11) excludes
`ssh-ed25519` from `PubkeyAcceptedAlgorithms`, so such a key is rejected at
preauth with `signature algorithm ssh-ed25519 not in PubkeyAcceptedAlgorithms`.
The toolchain generates **RSA-3072**. Bring your own key only if it is RSA
≥3072 or ECDSA P-256/384.

**Key-only automation stops working.** 03.05.03 sets
`AuthenticationMethods publickey,password`, so one factor is not enough.
`lib/ssh-env.sh` supplies the password factor via `SSH_ASKPASS` — the
automation authenticates with two factors like any operator, rather than the
control being switched off for it. Set `nist_mfa_enforce_pubkey: false` only if
your operators have not enrolled keys.

**Host key checking cannot be disabled.** OpenSSH refuses to send a password to
an unverified host (`Password authentication is disabled to avoid
man-in-the-middle attacks`), so `host_key_checking = False` would break
authentication rather than relax it. `known_hosts` is seeded before connecting.

**The host key changes when you first apply.** 03.13.10 removes the weak
DSA/ECDSA host keys, so a host trusted before the run presents a different key
afterwards. `apply.sh` re-records it after a successful run; `verify.sh` never
does, so an *unexpected* key change is still an error.

**Ping stops working.** The firewall default zone target is `DROP` (03.13.06),
so ICMP echo is dropped. The host is still reachable on its permitted services.

**`last`, `lastlog` and `w` require root.** `wtmp`, `btmp` and `lastlog` are
audit information under 03.03.08a and are mode 0600.

**`Defaults requiretty` is deliberately NOT set.** It blocks configuration
management without adding protection beyond `use_pty`, which the role does set.

---

## Evidence the verifier actually verifies

A checker that only agrees with its own remediator is worthless. This one was
tested by deliberately breaking three controls on a passing host:

| Regression introduced | Result |
|---|---|
| `minlen` 14 → 6 in `pwquality.conf` | **caught** — `ia-07-minlen`, expected ≥14, observed 6 |
| `setenforce 0` | **caught** — `ac-02-selinux-enforcing`, expected Enforcing, observed Permissive |
| `PermitRootLogin yes` drop-in added | **correctly reported as still compliant** |

The third is worth explaining. The role's config is `00-nist-800-171.conf`;
sshd honours the *first* occurrence of a keyword and reads the drop-in
directory in sorted order, so a later file cannot weaken the baseline.
`sshd -T` confirmed `permitrootlogin no` remained in effect. The check reported
the host's true state — which is the point of reading effective state rather
than config files.

The role is also idempotent: two consecutive `./apply.sh` runs report
`changed=0`, so `./apply.sh --check` is a meaningful drift detector rather than
permanent noise.

---

## Layout

```
rl9-171/
├── NIST.SP.800-171r3.pdf        the publication; `make catalog` reads it
├── catalog/
│   ├── requirements.json        parsed from the PDF (generated)
│   └── overlay-rocky9.yml       the mapping + ODP values  ← edit policy here
│                                 (`odp:` enforced, `odp_organizational:` not)
├── extract/
│   └── extract_requirements.py  PDF → JSON
├── inventory/
│   └── hosts.yml.example        copy to hosts.yml to target your own host
├── docs/
│   └── RUNBOOK.md               operator procedure: build, apply, verify, recover
├── roles/
│   ├── nist_800_171/            the overlay
│   │   ├── tasks/               one file per family, per-requirement tags
│   │   ├── templates/           auditd rules, sshd, banner, helper scripts
│   │   └── defaults/main.yml    implementation detail (not policy)
│   └── nist_log_collector/      the receiving half of 03.03.05c
├── audit/
│   ├── nist-assess              the assessor
│   └── checks.yml               330 check definitions
├── vm/
│   ├── build-vm.sh              unattended VM build
│   ├── kickstart/rl9-cui.ks.j2  install-time controls
│   └── nist-lab-network.xml     isolated lab network
├── tools/
│   ├── validate.py              catalog ↔ overlay ↔ checks consistency
│   └── inventory.py             owns inventory/hosts.yml across VMs
├── lib/ssh-env.sh               supplies the MFA knowledge factor to ssh
├── site.yml                     two plays: cui_hosts, then log_hosts
├── apply.sh  verify.sh  Makefile
└── reports/                     assessment output (generated)
```

---

## What gets installed on the host

The role leaves working artifacts behind, not just settings:

| Path | Purpose |
|---|---|
| `/etc/nist-800-171/system-security-plan.md` | SSP, generated from live state (03.15.02) |
| `/etc/nist-800-171/organizational-requirements.md` | What the host cannot enforce |
| `/etc/nist-800-171/component-inventory.json` | Component inventory (03.04.10) |
| `/usr/local/sbin/nist-assess` | On-host assessment (03.12.01) |
| `/usr/local/sbin/nist-generate-poam` | POA&M from failed checks (03.12.02) |
| `/usr/local/sbin/nist-offboard-user` | One-action offboarding (03.09.02) |
| `/usr/local/sbin/nist-sanitize-media` | Media sanitization (03.08.03) |
| `/usr/local/sbin/nist-privilege-report` | Privilege review evidence (03.01.05c) |
| `/etc/nist-800-171/authorized-ports.d/` | Per-role declaration of authorized listening ports; the port checks read it |
| `/etc/nist-800-171/log-forwarding-status` | Whether records are forwarded, or local-only (03.03.05c) |
| `/etc/nist-800-171/log-collector-status` | On a collector: port, record directory, retention |
| `/var/log/nist-800-171/` | Assessment, scan and review output |

Seven systemd timers provide the continuous monitoring strategy (03.12.03):
integrity check, audit review, vulnerability scan, assessment, inventory
refresh, malware scan, and security errata (`dnf-automatic`).

---

## Requirements

- **Control workstation**: `ansible-core` ≥2.14, `python3-yaml`, `poppler-utils`
  (for `pdftotext`), and for VM builds `libvirt`, `virt-install`, `qemu`,
  `swtpm`, `edk2-ovmf`. `podman` is optional (kickstart validation).
- **Target**: Rocky Linux 9, reachable over SSH with sudo.

Ansible collections (`ansible.posix`, `community.general`) install
automatically on first `./apply.sh`.

---

## Caveats

- `catalog/requirements.json` is derived from the published PDF. The PDF remains
  authoritative; re-run `make catalog` if you substitute a different revision.
- The overlay's ODP values are defensible defaults drawn from the DoD CUI
  baseline and the SSG RHEL 9 CUI profile. **They are not your organization's
  values** — review the `odp:` and `odp_organizational:` blocks before use.
- `fapolicyd` enforces deny-by-default execution. On a host with unprofiled
  workloads this can block applications; set `nist_fapolicyd_permissive: true`
  to log instead while profiling.
- Passing every check means the host-enforceable controls are in place. It does
  **not** mean the system is compliant or authorized — 28 requirements are
  purely organizational and 32 more are partial, each with its residual
  obligation named in `organizational-requirements.md`.
