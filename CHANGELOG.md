# Changelog

Notable changes, newest first. Versions follow `meta.version` in
`nist_sp_800_171r3/rl9-171/catalog/overlay-rocky9.yml`, which every applied
host and every assessment report records; each release is a `v<version>` tag
on the commit it was proven at.

## [1.0.1] — 2026-10-02

A review of 1.0.0 (GitHub issues #3–#15) found false PASSes on technical
requirements, two lockout paths and a step that could delete the LUKS key; a
monthly log rotation found one more. Every finding was checked in the code
before it was fixed, each fix is test-first where a check is involved and
proven on a lab host, and each is recorded with its evidence in
`docs/DEFECTS.md`, Phase 7 (7.1–7.16). Owner decisions: `docs/ODP-REVIEW.md`
I1–I4.

### Fixed

- **A failed TPM bind reported success**, after which the role deleted the
  LUKS key and set crypttab to `none` (7.1). The bind now fails the task.
- **No TPM seal while Secure Boot is off** (7.2, I1): such a seal opens for
  any boot medium. The host is treated as one without a TPM and the rest of
  the role carries on; `mp-09-secure-boot` reports it; the PCR 7 recovery
  rehearsal proves the path.
- **Idle sessions** (7.3): `ClientAliveInterval 0` and `TMOUT=0` passed; a
  terminal session printing output was never ended. logind's
  `StopIdleSessionSec` now ends it (901 s in the test); the TMOUT checks read
  a login shell.
- **The automation account** is exempt from password expiry, which would
  have cut off its key-and-password sign-in on day 60; its rotation is
  checked instead (7.4, I2).
- **Forwarding** (7.5): records are filed under the peer they came from, not
  the hostname they claim; the disk queue is bounded, so an outage cannot
  fill the disk and take the host to single-user.
- **GRUB** (7.6): no password is set while a boot entry would ask for it; the
  check reads what GRUB reads.
- **LUKS** (7.7, 7.14): the key is staged in RAM, never on disk where a TPM
  holds it; the cipher checks see every LUKS device; the passphrase can be
  rotated (`rotate-luks-passphrase.yml`); a TPM refusal at boot waits for the
  passphrase (I4).
- **Log rotation failed every day on every host** (7.9): the system logs
  were never rotated; btmp and wtmp were recreated readable.
- **Checks that could not fail** (7.10) and a refused assessment that looked
  like a successful one (7.11).
- **The POA&M register** survives a spreadsheet re-save and closes only what
  was assessed (7.12).
- **The playbook refuses the control workstation**; Rocky Linux 9 only (7.13,
  I3).
- **Tooling** (7.8, 7.15, 7.16): the lab scripts refuse a domain that is not a
  lab guest; CI parses the example inventory, pins its tools and runs the
  host-side code on Python 3.9; the BYO lab directory has a script to create
  it; SECURITY.md has a fallback reporting channel.

### Proven at this release

Both labs from a clean state - kickstart VMs reinstalled, BYO guests rebuilt
from the stock Rocky 9.8 GenericCloud image (`release-run.sh byo --rebuild`) -
hardened and cycled at `6c609be`, then assessed at `733ec8d`, which corrected
one check and changed nothing that hardens a host (`release-run.sh
--reverify`). Every host passed the release gate: settled at `changed=0`, no
check failed beyond its documented limits.

| Host | What it is | Satisfied / partial / not / org. | Checks run, failed |
| --- | --- | --- | --- |
| `rl9-cui-01` | kickstart reference build, CUI host | 36 / 33 / 0 / 28 | 351, 0 |
| `rl9-log-01` | kickstart reference build, collector | 35 / 34 / 0 / 28 | 351, 0 |
| `byo-rl9-01` | stock image, one filesystem, no volume group, no TPM | 34 / 30 / 5 / 28 | 351, 9 — the retrofit limits |
| `byo-log-01` | stock image, collector | 34 / 30 / 5 / 28 | 351, 9 — the same limits |
| `byo-rl9-02` | stock image with a volume group, a TPM and a second account | 35 / 33 / 1 / 28 | 351, 2 — only the separate filesystems |

The retrofit hosts fail 9 checks where 1.0.0 showed 6: the LUKS checks no
longer pass on a host that has no LUKS volume at all. The requirement-level
results are unchanged.

## [1.0.0] — 2026-09-26

The first release. Development builds before it also reported overlay
`1.0.0`; a report is from this release only if it was produced by the tagged
commit (`v1.0.0`) or later. The complete record of what was found and fixed
before this release, with the evidence for each, is
`nist_sp_800_171r3/rl9-171/docs/DEFECTS.md`.

### What it is

- NIST SP 800-171r3 (May 2024) for Rocky Linux 9: the 97 active
  requirements extracted from the publication (the catalog reproduces byte
  for byte from the PDF, with poppler 24.02 and 26.01 alike), each mapped in
  an overlay to what the host enforces — 37 technical, 32 partial, 28
  organizational — with 32 machine and 62 organizational parameters, every
  value reviewed and accepted by the owner (`docs/ODP-REVIEW.md`).
- An Ansible role that hardens a CUI host, a second that turns one into the
  audit-record collector (TLS on 6514, mutual x509), and an independent
  assessor: 340 checks, each reading effective state, a `partial`
  requirement never reported as PASS.
- A System Security Plan and a POA&M register generated from the host, which
  keep what the owner writes in them.
- Two labs that prove it: a kickstart reference build, and "bring your own"
  stock Rocky 9 guests, driven from one workstation with one inventory each.

### Proven at this release

Both labs, from a clean state, by `tools/release-run.sh` at commit `8c332c5`:
the kickstart VMs reinstalled, the BYO guests rebuilt from the stock Rocky 9.8
GenericCloud image (`--rebuild`). Each host: dry run on the never-applied
host, apply, the reboot it reported it owed, apply again, dry run at
`changed=0`, verify. Every host passed the release gate: it settled at
`changed=0`, and no check failed beyond the documented limits shown below. The tag is on a later commit that
changes documentation only (`git diff --stat 8c332c5 v1.0.0`).

| Host | What it is | Satisfied / partial / not / org. | Checks run, failed |
| --- | --- | --- | --- |
| `rl9-cui-01` | kickstart reference build, CUI host | 36 / 33 / 0 / 28 | 344, 0 |
| `rl9-log-01` | kickstart reference build, collector | 35 / 34 / 0 / 28 | 344, 0 |
| `byo-rl9-01` | stock image, one filesystem, no volume group, no TPM | 34 / 30 / 5 / 28 | 344, 6 — the retrofit limits below |
| `byo-log-01` | stock image, collector | 34 / 30 / 5 / 28 | 344, 6 — the same limits |
| `byo-rl9-02` | stock image with a volume group, a TPM and a second account | 35 / 33 / 1 / 28 | 344, 2 — only the separate filesystems |

Proven by behaviour as well as by the checks, in the lab, before this run:
an idle SSH session closed by sshd at the 900 s limit; GRUB demanding its
password to edit an entry; a PCR 7 change making the TPM withhold the LUKS
keys, the stale binding reported, resealed, and the next boot unlocking
alone; the owner's SSP sections and POA&M entries surviving regeneration;
audit records forwarded over mutual TLS to the toolkit's collector and to
syslog-ng, with a certificate-less client refused and a wrong peer name
sending nothing. The first release runs found four defects, all fixed and
proven here (DEFECTS.md 6b.11–6b.14).

### Known limitations

- **Retrofit hosts** — a host installed without separate `/tmp`, `/var/tmp`,
  `/var/log`, `/var/log/audit` and `/home` filesystems, or without a volume
  group with free space, fails 03.04.06 (and, without the volume group, the
  LUKS requirements). A playbook cannot repartition a running system; the role
  records what it could not do.
- **A TPM is needed** to keep the LUKS keys off the disk. Without one the key
  file stays so the host can boot, and the assessment reports it.
- **OpenSSH before 9.2** (early Rocky 9 minors) cannot close an idle SSH
  session that is not at a shell prompt; the role records the gap.
- **Forwarding is proven to lab receivers only** — this toolkit's collector,
  and syslog-ng with certificates from the lab CA (TASKS.md 6.2b). A
  deployer's SIEM, with a certificate the lab did not mint and a parser of
  its own, is theirs to prove; `tools/prove-foreign-receiver.sh` is the
  pattern.
- **The organizational requirements are the owner's.** 28 requirements have
  no host control and 32 have an organizational residual; the tool lists them
  (`organizational-requirements.md`, the POA&M register) and cannot satisfy
  them. A report with nothing failed is not compliance, and not authorization.
