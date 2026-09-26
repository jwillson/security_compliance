# Tasks

The live checklist for `nist_sp_800_171r3/rl9-171/`. Only open work is here.

Phases 1–5 are closed. Their evidence, and the defects found earning it, are
`nist_sp_800_171r3/rl9-171/docs/DEFECTS.md`, cited by the same numbers
(1b.4, 2b.8, 3.2, 4.4). The ODP decisions are `docs/ODP-REVIEW.md`; operator
procedure is `docs/RUNBOOK.md`.

---

## Where the tool stands

As of 2026-09-26, at the head of `main`.

**Consistent** — `make validate`: 97 active requirements (33 withdrawn), 340
checks defined and referenced, 32 machine ODPs each asserted by a check, 62
organizational across 49 requirements. Disposition **37 technical, 32
partial, 28 organizational**. `make catalog-check`: the catalog still
reproduces byte for byte from the PDF.

**Tested** — `make test`: 56 unit tests for the assessor, the validator and
the POA&M register.
The assessor never reads a command that could not run as a clean result
(6b.1); every check reads effective state.

**Proven against running hosts**, by `tools/harden-cycle.sh` (dry run,
apply, reboot when owed, apply, `changed=0`, verify, evidence before and
after):

| Lab | Result |
| --- | --- |
| Kickstart, built on the laptop (`inventory/kickstart.yml`) | `rl9-cui-01` **36/33/0/28**, `rl9-log-01` **35/34/0/28** — 344 checks run, **0 failed** on both. CUI volumes sealed to the TPM; 121,650 auditd records forwarded over TLS to the collector |
| BYO retrofit reference (`inventory/hosts.yml`) | `byo-rl9-01`, `byo-log-01` **34/30/5/28** — 6 checks failed, all five requirements the documented retrofit limits (no volume group, no separate `/tmp`; DEFECTS 2.2) |
| BYO with a volume group, a TPM and two accounts | `byo-rl9-02` **35/33/1/28** — 2 checks failed, both 03.04.06 (no separate `/tmp`) |

Proven by behaviour, not configuration: an idle SSH session closed at the
ODP limit (`tools/ssh-idle-test.sh`); GRUB demanding its password to edit an
entry (`tools/rehearse-grub-edit.py`); the TPM refusing after a PCR 7 change,
the stale binding reported, resealed, and the next boot unlocking alone
(`tools/rehearse-pcr7-recovery.py`); every lockout recovery in the RUNBOOK
(DEFECTS Phase 3). The history behind these numbers — and the defects each
run found — is `docs/DEFECTS.md`.

What is open is below: the release blockers first, then one item that needs
a receiver we do not have, the owner's authoring, and the defects found
working out how to do it.

---

## Release 1.0 — what a public release needs

Goal set 2026-09-25: a public release. The repository stays private until
every blocker below is closed. The bar follows from what the tool is: a
compliance assessor that reports a false PASS is worse than none, because it
is believed.

**Blockers**

- [x] **R1 No known false PASS.** *Met 2026-09-26:* 6b.2–6b.6 fixed and
      proven, 6b.5 by the owner's choice (TPM), each with its check changed
      first so it failed on the defect (DEFECTS.md Phase 6b).
- [x] **R2 No data loss in what the tool generates.** *Met 2026-09-26* (6.6):
      the SSP and the POA&M keep what the owner writes, proven by rehearsal.
- [ ] **R3 A full lab cycle green on the release commit.** Both labs, from a
      clean state, through apply → reboot → apply → verify, `--check` at
      `changed=0`, with a second interactive account present (6b.4):
      `tools/release-run.sh byo` and `tools/release-run.sh kickstart`
      (docs/LAB.md). A host passes only with no failure beyond the documented
      retrofit limits. The numbers quoted in the READMEs come from this run
      and nothing earlier. The READMEs and CHANGELOG are written from it
      afterwards, so the tag lands on a later commit; `git diff --stat
      PROVEN..v1.0.0` must then show documentation only.
- [ ] **R4 The READMEs say only what that run proved.** Current numbers; the
      6.5 caveat where a first-time reader meets it; supported platforms
      stated precisely (Rocky/RHEL 9 minors, and what differs on OpenSSH
      8.7 vs ≥ 9.2 after 6b.3); a *Known limitations* section carrying
      everything under *Not blockers*.
- [x] **R5 `SECURITY.md`.** *Written 2026-09-26:* private reporting through
      GitHub's private vulnerability reporting, a false PASS in scope, a 7-day
      acknowledgement target (the owner's to confirm). *At release:* enable
      private vulnerability reporting in the repository settings — GitHub
      offers it only on public repositories.
- [x] **R6 CI.** *Done 2026-09-26* (`.github/workflows/ci.yml`): validate,
      the 56 unit tests, catalog-check, the playbook's syntax check and a parse
      of every script, on every push and pull request; actions pinned to SHAs.
      The first run passed, and showed the catalog reproduces with the
      runner's poppler 24.02 as with the laptop's 26.01.
- [ ] **R7 Versioned.** *`CHANGELOG.md` written 2026-09-26.* Recommended:
      release as **1.0.0** — never released before — with the changelog saying
      development builds reported the same number. *At release:* fill in
      "Proven at this release" from R3's run, date the entry, and tag
      `v1.0.0` on that commit.
- [x] **R8 History scanned with a real secret scanner.** *Done 2026-09-26:*
      `tools/secret-scan.sh` runs gitleaks 8.30.1 (the binary verified against
      a SHA-256 pinned in the script) over every commit on every branch: **no
      leaks**. Shown to work first: in a throwaway repository it found a
      private key and an AWS key committed and then deleted. It now runs in
      CI on every push, so the history stays clean. *At release:* run it once
      more on the release commit.

- [x] **R9 `CONTRIBUTING.md`.** *Written 2026-09-26:* the acceptance rules
      (a finding is a lead until a host confirms it; fix the check first; prove
      it on a host; script everything; docs in the repo), the rules the code
      keeps, and what never goes in the repository.

**Not blockers** — ship as documented limitations:
6.2b (needs each deployer's SIEM; 6.2a proved the path to a third-party
receiver in the lab) and 6.3 / 6.4, which are the owner's documents for their
own system, not the tool's.

Redistribution: `NIST.SP.800-171r3.pdf` is a work of the U.S. Government and
not subject to copyright in the United States; the README should say so next
to the Apache-2.0 notice that covers everything else.

---

## How work arrives, and how it is accepted

The project is developed by its owner with two Claude Code sessions: a cloud
session that reviews code and opens pull requests, and a local session on the
owner's KVM workstation that proves them on the lab. Both commit under the
owner's identity. The rules that keep that honest:

- **A finding is a lead until a host confirms it.** Every item below was
  reported by the cloud review and then reproduced on the BYO guests before
  it was written here; the evidence line in each is what the host showed.
- **Fix the check first.** A defect where the check agreed with the broken
  role is fixed by making the check FAIL on the current guests, then fixing
  the role until it passes. A check that cannot fail proves nothing.
- **A PR is merged only after a lab run.** For an assessor change, main's
  assessor and the PR's are run back to back against the same host state
  and compared check by check (6b.1: 0 of 334 differed). For a role change,
  apply → reboot → apply → verify, and `--check` at `changed=0`.
- **Closed items move to `docs/DEFECTS.md`** with their evidence, so the
  record of what was wrong stays citable after it is fixed.

---

## Defects in the role and its checks — closed

6b.2–6b.10 are fixed and proven on both labs, with the GRUB-edit and PCR 7
recovery rehearsals passed; the record is `docs/DEFECTS.md`, Phase 6b. They
were found by the cloud review of 2026-09-25 and by cycling the labs.

---

## Open — audit-record forwarding

6.2a is closed (docs/DEFECTS.md, Phase 6): forwarding is proven to syslog-ng,
a receiver the toolkit did not build, with a peer name no lab host has.

- [ ] **6.2b Point forwarding at the real SIEM.** **Blocked: needs the SIEM.**
      What 6.2a cannot close is a certificate we did not mint. Set
      `nist_log_collector: HOST:PORT` and `nist_log_collector_name` to the
      name the SIEM's certificate carries, and put its CA in `NIST_PKI_DIR` as
      `ca.crt` alongside a certificate the SIEM will accept for each host.
      Confirm `au-05-forward-established` still passes, and that the SIEM
      parses the records rather than merely accepting the connection.

---

## Open — the system owner's authoring

- [ ] **6.3 Author the three SSP sections no host can fill.** Write
      `02-information-types.md`, `03-threats.md` and `07-roles.md` in
      `/etc/nist-800-171/ssp.d/` on each host, or keep them in a private
      repository of your own and set `NIST_SSP_DIR` (RUNBOOK, *Writing the SSP
      and working the POA&M*, says what an assessor looks for in each). They
      are spliced into the plan on every regeneration and never overwritten
      (6.6); the plan's first table says which are still unwritten.

- [ ] **6.4 Work the POA&M.** `/etc/nist-800-171/poam.csv` holds every
      deviation and every partial requirement's residual, merged after each
      assessment. Fill `Scheduled Completion`, `Responsible Party`,
      `Resources Required`, `Milestones` for the open items; close residuals
      with evidence, or mark them `Risk Accepted` (RUNBOOK). Your entries are
      carried forward on every run.

---

## Standing caveat

- [ ] **6.5 A green report is not compliance, and not authorization.** Not a
      task; a thing to re-read before quoting a number to anyone.

      Of 97 requirements, **28 report `NOT_APPLICABLE(host)` and 32 are
      `partial`** — so on roughly 60 of them a clean host proves little or
      nothing. What the checks measure is host-enforceable configuration
      state, read from effective state (`sshd -T`, not `sshd_config`), on one
      host. That is the whole of it.

      *Compliant* means all 97 satisfied with evidence, an SSP and a POA&M;
      this tool produces the evidence for part of one of the three.
      *Authorized* means a person with the authority to do so accepted the
      residual risk. No tool does that.

      A report with 0 failed specifically does not establish that the
      organizational controls exist, that the ODP values match your actual
      policy (`make validate` checks mechanics and can never tell you a
      number is wrong), that the system boundary was assessed — this
      workstation, the lab network, the SIEM and the backups are all outside
      a host assessment — or that an assessor would agree with how the 32
      partials were disposed.

      The 4.4 work is what keeps this honest rather than decorative: seven
      requirements used to print PASS beside prose conceding non-compliance.
      The guard in `tools/validate.py` that forbids a `residual` on a
      `technical` entry is now the thing holding 6.5 true — not this
      paragraph.

---

## Not planned

Recorded so they do not get re-litigated:

- Reviving the superseded trees, now deleted (recoverable from git history).
  `r3/` was retired for cause: its verifier graded on exit status, 14 of its
  checks could not fail and 4 were inverted. `os/` and `stig/` were r2-tagged.
  Both worthwhile pieces were ported before removal.
- Supporting distributions other than the RHEL 9 family. The overlay is
  Rocky 9 specific by design and `site.yml` asserts it.
- Shipping ClamAV, or fapolicyd in permissive mode (4.2, 4.3). Both decided
  2026-09-17; the gaps are recorded rather than hidden.
