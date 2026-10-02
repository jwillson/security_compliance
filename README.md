# security_compliance

Out-of-the-box implementations of security controls for POSIX systems.

## NIST SP 800-171r3 → Rocky Linux 9

[`nist_sp_800_171r3/rl9-171/`](nist_sp_800_171r3/rl9-171/) is a portable
toolchain that extracts the 97 active security requirements of
[NIST SP 800-171r3](https://doi.org/10.6028/NIST.SP.800-171r3) from the
publication, maps the ones a Linux host can enforce onto Rocky Linux 9,
applies them with Ansible, and then independently verifies each running host.

```bash
cd nist_sp_800_171r3/rl9-171
cp inventory/hosts.yml.example inventory/hosts.yml   # your Rocky 9 host
./apply.sh --check --diff                            # what would change
./apply.sh && ./verify.sh                            # harden, then assess
```

It classifies 37 requirements as host-enforceable, 32 as partially enforceable
with the residual obligation named, and 28 as organizational with no host
control at all — rather than claiming 100% on the technical subset. A partial
requirement can never report PASS. Verification reads effective system state
(`sshd -T`, `auditctl -l`, `sysctl -n`), not the files the role wrote, and a
command that could not look is an error, never a clean result.

**A report with nothing failed is not compliance, and not authorization.** On
about 60 of the 97 requirements a clean host proves little or nothing; the
rest is the organization's, and only a person with the authority to accept the
residual risk authorizes a system. The tool produces the host evidence, a
System Security Plan it keeps regenerating around what the owner writes, and a
POA&M register — see its [README](nist_sp_800_171r3/rl9-171/README.md).

What the 1.0.1 release run proved, every host from a clean start (CHANGELOG,
*Proven at this release*):

| Host | Satisfied / partial / not / organizational |
| --- | --- |
| Kickstart reference build, CUI host and log collector | **36 / 33 / 0 / 28** and **35 / 34 / 0 / 28** — 0 checks failed |
| A stock Rocky 9 cloud image it did not build | **34 / 30 / 5 / 28** — the five are the separate filesystems and LUKS volumes only an install can create, recorded rather than hidden |
| The same, given a volume group, a TPM and a second user | **35 / 33 / 1 / 28** — only the separate filesystems remain |

Audit records are forwarded over mutually authenticated TLS to a collector the
second role builds, and have been proven to reach a third-party receiver
(syslog-ng) as well.

- [CHANGELOG.md](CHANGELOG.md) — releases, what each proved, known limitations
- [TASKS.md](TASKS.md) — open work
- [docs/DEFECTS.md](nist_sp_800_171r3/rl9-171/docs/DEFECTS.md) — every phase
  closed and every defect found earning these claims, with the evidence
- [docs/RUNBOOK.md](nist_sp_800_171r3/rl9-171/docs/RUNBOOK.md) — operating
  it, and getting back in when a control locks you out
- [SECURITY.md](SECURITY.md) — reporting a vulnerability, including a false PASS
- [CONTRIBUTING.md](CONTRIBUTING.md) — how a change is accepted

## Licence

Apache-2.0 ([LICENSE](LICENSE)). `NIST.SP.800-171r3.pdf`, included so the
catalog can be reproduced from it, is a work of the U.S. Government and not
subject to copyright in the United States.
