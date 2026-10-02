# Tasks

The live checklist for `nist_sp_800_171r3/rl9-171/`. Only open work is here.

Phases 1–5 are closed. Their evidence, and the defects found earning it, are
`nist_sp_800_171r3/rl9-171/docs/DEFECTS.md`, cited by the same numbers
(1b.4, 2b.8, 3.2, 4.4). The ODP decisions are `docs/ODP-REVIEW.md`; operator
procedure is `docs/RUNBOOK.md`.

---

## Where the tool stands

As of 2026-09-26, release 1.0.0.

**Consistent** — `make validate`: 97 active requirements (33 withdrawn), 340
checks defined and referenced, 32 machine ODPs each asserted by a check, 62
organizational across 49 requirements. Disposition **37 technical, 32
partial, 28 organizational**. `make catalog-check`: the catalog still
reproduces byte for byte from the PDF.

**Tested** — `make test`: 56 unit tests for the assessor, the validator and
the POA&M register.
The assessor never reads a command that could not run as a clean result
(6b.1); every check reads effective state.

**Proven against running hosts** — the release run (R3) at `8c332c5`,
`tools/release-run.sh` on both labs from a clean state (kickstart VMs
reinstalled, BYO guests rebuilt from the stock image): dry run on the
never-applied host, apply, reboot, apply, dry run at `changed=0`, verify.

| Lab | Result |
| --- | --- |
| Kickstart, built on the laptop (`inventory/kickstart.yml`) | `rl9-cui-01` **36/33/0/28**, `rl9-log-01` **35/34/0/28** — 344 checks run, **0 failed** on both |
| BYO retrofit (`inventory/hosts.yml`) | `byo-rl9-01`, `byo-log-01` **34/30/5/28** — 6 checks failed, all five requirements the documented retrofit limits (no volume group, no separate `/tmp`; DEFECTS 2.2) |
| BYO with a volume group, a TPM and two accounts | `byo-rl9-02` **35/33/1/28** — 2 checks failed, both 03.04.06 (no separate `/tmp`) |

Proven by behaviour, not configuration: an idle SSH session closed at the
ODP limit (`tools/ssh-idle-test.sh`); GRUB demanding its password to edit an
entry (`tools/rehearse-grub-edit.py`); the TPM refusing after a PCR 7 change,
the stale binding reported, resealed, and the next boot unlocking alone
(`tools/rehearse-pcr7-recovery.py`); audit records received legible by
syslog-ng, a certificate-less client refused and a wrong peer name sending
nothing (`tools/prove-foreign-receiver.sh`, 6.2a); every lockout recovery in
the RUNBOOK (DEFECTS Phase 3). The history behind these numbers — and the defects each
run found — is `docs/DEFECTS.md`.

What is open is below. Every release blocker is closed; going public is the
owner's step in the repository settings. After it: forwarding to a
deployer's own SIEM (6.2b) and a cross-host review report (6.2c), and the
owner's authoring (6.3, 6.4).

---

## Release 1.0.1 — the review after 1.0.0

**Going public waits for this.** A cloud review on 2026-09-26 filed issues
#3-#15 and pushed fixes for #3-#7 to `claude/dazzling-archimedes-kus9kd`
(two commits, no PR). Verified against `main` on 2026-10-01, every claim read
in the code and the worst proven on a lab host: most hold, and 1.0.0 carries
false PASSes on technical requirements and two lockout paths — R1 was not
met after all. The owner's decisions are `docs/ODP-REVIEW.md` I1-I3.

*The branch is a source, not a merge.* Taken, each re-proven here: the bind
fix (#3 — `tools/probes/bind-script-experiment.sh` on `byo-rl9-02`: main's
script prints `bound` and exits 0 after a failed bind, the branch's exits 1;
first bind and re-run work), the POA&M hardening and its tests (#5), the
`byo-*` lab-guest guards (#6). Not taken as they stand: the Secure Boot
refusal stops the play (I1 says keep going); the authored-plans guard refuses
every host (`ls` fails on a clean host and ansible's minimal callback prints
"non-zero return code", so the result is never empty); `harden-cycle
--snapshot` would refuse kickstart guests; `site.yml` admits RHEL the role
does not support (I3); the workstation guard covers only the first play; its
TASKS.md says the repository went public, which it has not.

**P1 — lockout, data loss, or a false PASS on a `technical` requirement**
- [x] #3 a failed TPM bind reported success, then the key was deleted.
- [x] #4 sealing with Secure Boot off (I1: refuse, keep going, report);
      `mp-09-luks-tpm-bound` widened to partitions and disks, PCR 7 in the
      sha256 bank, no pass on a host with no LUKS device.
- [x] #9 03.01.11: `ClientAliveInterval 0` passes three checks; `TMOUT=0`
      can pass (a file grep, not effective state); an idle session that
      produces output is never ended, and the overlay says it is.
- [x] #12 aging cuts the automation account off on day 60 (I2: exempt, and
      a rotation runbook); the inactivity check passes 99999.
- [x] #10 a full disk from the unbounded forwarding queue drops the host to
      single-user (`SINGLE`); the collector files by the sender-claimed
      hostname; `au-05-collector-receiving` matches a forged line.
- [x] #8 no pre-flight keeps the boot entries `--unrestricted` before the
      GRUB password goes on.
- [x] #11 the LUKS passphrase written to unencrypted disk and only unlinked;
      the key-on-disk check ignores `/etc/cryptsetup-keys.d`.
- [x] #6 lab tools act on any libvirt domain (`destroy` deletes its disks).

**P2 — checks that cannot fail, and correctness**
- [ ] #13 a refused assessment looks like a successful service run; the SSP
      skips ERROR; six checks cannot fail (`ac-12-sshd-crypto-policy`,
      `ir-02-journald-retention`, `mp-02-umask-profile`,
      `pe-07-single-user-auth`, the MAC deny lists, the repository prefix
      match).
- [ ] #5 the POA&M register: an Excel re-save erases every ID; a scoped
      assessment merged by hand closes what it never examined.
- [x] #12 the last-change loop swallows `chage` failures; `--skip-tags
      03.01.01` breaks `ia.yml`.
- [ ] #7 a workstation guard on both plays; the documents say Rocky (I3).

- [ ] #11, the rest: LUKS passphrase rotation (`luksChangeKey`, a RUNBOOK
      procedure, per-host passphrases). Boot behaviour when the TPM refuses
      is decided: the boot waits for the passphrase, no `nofail`
      (ODP-REVIEW I4).

**P3 — CI, tooling, documents**
- [ ] #14 CI's syntax check runs on an empty inventory (the example does
      not parse — R6 claimed more than it did); unpinned installs; code that
      parses only on Python 3.12. ("apply.sh exits silently" is wrong; the
      misleading message is `verify.sh`'s.)
- [ ] #15 SECURITY.md's only channel does not exist while private — add a
      fallback; LAB.md's six hand-made lab files get a script or a template;
      the CHANGELOG's "every host passed" means the release gate.

Done so far (DEFECTS.md, Phase 7): 7.1 (#3), 7.2 (#4), 7.3 (#9), 7.4 (#12), 7.5 (#10), 7.6 (#8), 7.7 (#11), 7.8 (#6). P1 is complete. Then 7.9 (log rotation, found on the way) and 7.10 (#13, the checks that could not fail).

*Done when:* each fix is check-first where a check is involved (the check
fails on the defect first), the release run passes on both labs at the fixed
commit, and `docs/DEFECTS.md` records each issue with its proof — then 1.0.1
is tagged and the repository can go public.

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
- [x] **R3 A full lab cycle green on the release commit.** *Met 2026-09-26
      at `8c332c5`:* `tools/release-run.sh byo --rebuild` and
      `tools/release-run.sh kickstart`, every host from a clean state, every
      host PASS (the table above; CHANGELOG, *Proven at this release*). The
      two attempts before it stopped on 6b.11-6b.14, fixed and proven by this
      run (DEFECTS.md, Phase 6b). The tag is on the documentation commit
      after it; `git diff --stat 8c332c5 v1.0.0` shows documentation only.
- [x] **R4 The READMEs say only what that run proved.** *Done 2026-09-26:*
      both READMEs quote R3's numbers and nothing earlier; the 6.5 caveat
      opens the tool's README and the top-level one; *Supported platforms*
      says what was run (Rocky 9.8, OpenSSH 9.9) apart from what is expected
      (other minors, RHEL, OpenSSH before 9.2); *Known limitations* carries
      the retrofit, TPM, forwarding, ClamAV and organizational limits; the
      NIST publication's public-domain status sits beside the licence.
- [x] **R5 `SECURITY.md`.** *Written 2026-09-26:* private reporting through
      GitHub's private vulnerability reporting, a false PASS in scope, a 7-day
      acknowledgement target (confirmed by the owner 2026-09-26).
- [x] **R6 CI.** *Done 2026-09-26* (`.github/workflows/ci.yml`): validate,
      the 56 unit tests, catalog-check, the playbook's syntax check and a parse
      of every script, on every push and pull request; actions pinned to SHAs.
      The first run passed, and showed the catalog reproduces with the
      runner's poppler 24.02 as with the laptop's 26.01.
- [x] **R7 Versioned.** *The owner chose 1.0.0 on 2026-09-26.* `CHANGELOG.md`
      dated, "Proven at this release" filled from R3, and `v1.0.0` tagged on
      the documentation commit after `8c332c5`, with the secret scan run on
      it first.
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

**Going public** — the owner's, in the repository settings, once R3, R4 and
R7 are done (agreed 2026-09-26): make the repository public; enable private
vulnerability reporting, which GitHub offers only on public repositories and
`SECURITY.md` sends reporters to; protect `main` so a pull request must pass
the `ci` workflow before it merges.

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

- [ ] **6.2c A cross-host review report on the collector.** *After 1.0.*
      *Decided 2026-09-26, instead of a lab SIEM VM:* a SIEM would satisfy
      nothing the tool does not already cover. The host part of 03.03.05
      (correlation across repositories, statement c) is the collector, proven
      on both labs and, by 6.2a, to a third-party receiver. What remains of
      03.03.05a/b and 03.06.02 is a person reviewing and reporting, which is
      why they are `partial` and read MANUAL with or without a SIEM. A SIEM VM
      would also be another CUI host to harden and prove, and 4-8 GB the lab
      does not have.
      What would help that person: each host's daily `nist-audit-review`
      summarises its own records only. Give the collector the same for the
      whole enclave, from `/var/log/remote/<host>/audispd.log` — per host and
      in total: failed authentications, privileged commands, changes to
      accounts, audit rules and time, and any host that has stopped sending
      (no record within a threshold) — at the review frequency ODP, into
      `/var/log/nist-800-171/`. The records arrive as syslog lines, not as
      `audit.log`, so `aureport` cannot read them as they are; the parsing is
      part of the work.
      *Done when:* on both labs the report names every forwarder, counts
      events generated for the test on the right host, and flags a
      forwarder stopped for the test; a check asserts the timer, not the
      report's contents; 03.03.05 still reports MANUAL. The RUNBOOK says who
      reads it, and the SSP section on 03.03.05 can cite it.

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
