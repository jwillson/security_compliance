# Security policy

This repository hardens Rocky Linux 9 / RHEL 9 hosts that handle Controlled
Unclassified Information, and assesses them against NIST SP 800-171r3. People
act on what it reports, so a defect that makes it *say* a host is protected
when it is not is treated as a vulnerability, not an ordinary bug.

## Reporting

Use GitHub's **private vulnerability reporting**: the repository's *Security*
tab → *Report a vulnerability*. Please do not open a public issue or pull
request for anything in scope below until a fix is released.

Include what you can of:

- the commit or release you ran, and the Rocky / RHEL minor version of the host;
- how to reproduce it — the command, the inventory shape (no real addresses
  or credentials), and what you expected;
- the relevant lines of `./verify.sh` output or the assessment JSON, with host
  names, addresses and anything sensitive removed.

You should get an acknowledgement within 7 days. A confirmed issue is fixed
the way every defect here is fixed: the check that should have caught it is
changed first so that it fails on the defect, then the role, then it is
proven on a lab host and recorded in `nist_sp_800_171r3/rl9-171/docs/DEFECTS.md`.
We will agree a disclosure date with you and credit you, unless you prefer not
to be named.

## In scope

- **A false PASS**: the assessor reporting a check or a `technical`
  requirement as satisfied when the host does not satisfy it, or a check that
  cannot fail. (Findings of exactly this kind are recorded in DEFECTS.md:
  6b.1, 6b.2, 6b.3, 6b.5 and 6b.6.)
- **A `partial` requirement reporting PASS**, or an assessment that implies
  the system is authorized.
- **The role weakening a host**: opening a service or port, relaxing a
  setting it claims to harden, or leaving a secret readable on disk (a key,
  a passphrase, a password in cleartext).
- **Secrets leaking** from the control workstation's tooling: into logs,
  reports, process arguments, or the repository.
- **Privilege escalation** through the scripts the role installs
  (`/usr/local/sbin/nist-*`, `/opt/nist-assess`).
- **A lockout the RUNBOOK does not recover from**: a control the role applies
  that leaves the owner unable to get back in by the documented procedure.

## Out of scope

- Requirements the tool reports as `MANUAL` or `NOT_APPLICABLE(host)`. That is
  by design: 32 requirements are only partly enforceable on a host and 28 are
  organizational; the tool says so rather than passing them.
- The values chosen for organization-defined parameters. They are policy,
  recorded and accepted in `docs/ODP-REVIEW.md`; change them in the overlay.
- Vulnerabilities in Rocky Linux or RHEL packages themselves — report those
  to the Rocky Enterprise Software Foundation or Red Hat. (A host that fails
  to *install* an available security update is in scope.)
- The lab build scripts under `vm/` when used as intended, on a throwaway lab
  network.

## Supported versions

Fixes are made on `main` and released from it. Only the latest release is
supported.
