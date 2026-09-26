# Changelog

Notable changes, newest first. Versions follow `meta.version` in
`nist_sp_800_171r3/rl9-171/catalog/overlay-rocky9.yml`, which every applied
host and every assessment report records; each release is a `v<version>` tag
on the commit it was proven at.

## [1.0.0] — unreleased

The first release. Development builds before it also reported overlay
`1.0.0`; a report is from this release only if it was produced by the tagged
commit (`v1.0.0`) or later. The complete record of what was found and fixed
before this release, with the evidence for each, is
`nist_sp_800_171r3/rl9-171/docs/DEFECTS.md`.

### What it is

- NIST SP 800-171r3 (May 2024) for Rocky Linux 9 / RHEL 9: the 97 active
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

To be filled in from the release run (TASKS.md R3): both labs cycled at the
tagged commit.

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
