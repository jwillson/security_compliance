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

**Tested** — `make test`: 41 unit tests for the assessor and the validator.
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
- [ ] **R2 No data loss in what the tool generates.** 6.6: the SSP and POA&M
      generators must keep what the owner authors.
- [ ] **R3 A full lab cycle green on the release commit.** Both labs — the
      kickstart pair (other workstation) and the BYO pair — through apply →
      reboot → apply → verify, `--check` at `changed=0`, with a second
      interactive account present (6b.4). The numbers quoted in the READMEs
      come from this run and nothing earlier.
- [ ] **R4 The READMEs say only what that run proved.** Current numbers; the
      6.5 caveat where a first-time reader meets it; supported platforms
      stated precisely (Rocky/RHEL 9 minors, and what differs on OpenSSH
      8.7 vs ≥ 9.2 after 6b.3); a *Known limitations* section carrying
      everything under *Not blockers*.
- [ ] **R5 `SECURITY.md`.** A security tool needs a private route for
      vulnerability reports: GitHub private vulnerability reporting, plus
      what counts as in scope (a false PASS is a vulnerability).
- [ ] **R6 CI.** A GitHub Actions workflow running `make validate`,
      `make test` and `make catalog-check` on every push and PR. None needs
      a host; `catalog-check` needs `pdftotext` (poppler-utils).
- [ ] **R7 Versioned.** `CHANGELOG.md`, and a `v1.0.0` tag that matches
      `meta.version` in the overlay. The overlay has claimed 1.0.0 since
      before 6b.1; decide whether the release is 1.0.0 or the overlay bumps.
- [ ] **R8 History scanned with a real secret scanner** (gitleaks or
      trufflehog) before visibility changes. A pattern grep on 2026-09-25
      (private keys, `$6$` hashes, tokens, `.secrets/`, keys, images,
      inventories, reports) found nothing, but a grep is not a scanner.
- [ ] **R9 `CONTRIBUTING.md`** carrying *How work arrives* below: fix the
      check first, a lab run before merge, closed items to `DEFECTS.md`.

**Not blockers** — ship as documented limitations:
6.2a (interop with a non-rsyslog receiver; after 6b.6 the audit path is
proven against our own collector), 6.2b (needs each deployer's SIEM), 6.7
(a disposition decision), 5.5 (a comment about one workstation), and 6.3 /
6.4, which are the owner's documents for their own system, not the tool's.

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

- [ ] **6.2a Prove TLS forwarding to a receiver that is not our own rsyslog.**
      The path has only ever run rsyslog→rsyslog between two guests built the
      same way, with certificates from the same lab CA. Three of the risks in
      6.2 can be closed without the production SIEM: interop with a different
      TLS stack, `x509/name` peer matching against a name that is not a lab
      hostname, and whether our records are parseable on the far side.

      *Decided 2026-09-22: a container, not a VM.* All three forwarding checks
      read state on the **forwarder** — `au-05-forward-established` reads the
      established socket, `sc-08-forward-encrypted` reads
      `log-forwarding-status`, and `au-05-collector-receiving` is gated on
      `/etc/rsyslog.d/10-nist-collector.conf` so it reports MANUAL against any
      third-party receiver, which is correct. Nothing in the assessment can
      distinguish a VM from a container, so the receiver's fidelity buys
      nothing and its setup cost is real.

      Shape: syslog-ng in podman (a different implementation, not an rsyslog
      fork), attached to `virbr17` with its own `192.168.171.x` so it is an
      ordinary peer — this also avoids a host ufw rule, which the lab bridge
      does not currently have (see 5.5). Certificate needs no new tooling:
      `tools/lab-pki.sh siem.nist-lab=192.168.171.50` already mints CN + SAN
      DNS + IP with `serverAuth,clientAuth`.
      *Done when:* on `byo-rl9-01`, with `nist_log_collector` and
      `nist_log_collector_name` pointed at it, `au-05-forward-established`
      and `sc-08-forward-encrypted` both PASS, and an **audit** record
      (`type=`) written on the CUI host is legible in the container's
      output. *6b.6 is fixed*, so audit records now travel this path; the
      receiver must show them, not just syslog.
      *Constraint:* the receiver must never enter `inventory/hosts.yml`. It is
      not a CUI host, and `nist_log_collector_name` defaults to
      `groups['log_hosts'] | first`, so it has to be set explicitly.

- [ ] **6.2b Point forwarding at the real SIEM.** **Blocked: needs the SIEM.**
      What 6.2a cannot close is a certificate we did not mint. Set
      `nist_log_collector: HOST:PORT` and `nist_log_collector_name` to the
      name the SIEM's certificate carries, and put its CA in `NIST_PKI_DIR` as
      `ca.crt` alongside a certificate the SIEM will accept for each host.
      Confirm `au-05-forward-established` still passes, and that the SIEM
      parses the records rather than merely accepting the connection.

---

## Open — the system owner's authoring

- [ ] **6.3 Author the three SSP sections no host can fill.**
      `sudo nist-generate-ssp` writes 92 lines; sections 1, 4, 5, 6 and 8 are
      generated from live state and refresh on every run. Three are marked
      AUTHOR and are empty:
      * **§2 Information types** — the CUI categories this system processes,
        stores and transmits, by NARA registry category and marking.
        Populating `/etc/nist-800-171/cui-locations` feeds the section's
        location list automatically; naming the categories is prose.
      * **§3 Threats of concern** — system-specific, not a generic list:
        credential theft against the single admin account, supply chain via
        the dnf repositories (where the 4.2 EPEL decision earns its place),
        insider misuse of `cuiusers`, physical loss of the host, audit-trail
        tampering. Cite a derivation an assessor can follow.
      * **§7 Roles and responsibilities** — four rows; System Owner is the one
        that matters, as the party who accepts residual risk and approves the
        plan. If every role is the same person, state that rather than leaving
        rows blank.
      *Read 6.6 first:* authoring into the generated file destroys the work.

- [ ] **6.4 Complete the POA&M.** `sudo nist-generate-poam` reads the timer's
      `assessment-latest.json` and wrote 5 open items on `byo-rl9-01`, one per
      failing requirement (03.01.18, 03.04.06, 03.08.03, 03.08.09, 03.13.08 —
      the retrofit limits of 2.2), with First Observed set and Scheduled
      Completion, Responsible Party, Resources Required and Milestones empty
      for the owner. `poam-first-observed.json` preserves the observation date
      across runs and drops an item once it stops failing.
      *Read 6.6 and 6.7 first:* the columns you fill are not carried forward,
      and the 32 partial residuals and 28 organizational requirements are
      absent from the file.
      Run the generators by full path (`/usr/local/sbin/nist-generate-poam`)
      from automation; a login shell's PATH finds them by name.

---

## Open — defects found while working out 6.3 and 6.4

- [ ] **6.6 Both generators destroy authored content.** `generate-ssp.sh`
      writes with a truncating redirect (`} > "$OUT"`), so every word authored
      into sections 2, 3 and 7 of `system-security-plan.md` is lost the next
      time the script runs — and 03.15.02 is only satisfied once those
      sections exist, so the tool destroys the evidence for the requirement it
      generates. `generate-poam.sh` has the sibling problem: it writes a new
      `poam-$(date).csv` per run, so management's columns are not carried into
      the next one. Fix: an include directory both scripts read and splice
      (`{{ nist_conf_dir }}/ssp.d/`, and a stable POA&M keyed on POAM ID that
      merges the owner's columns by ID).
      *Until this is fixed, author the prose anywhere but those two files.*

- [ ] **6.7 The POA&M omits the obligations that are not FAILs.**
      `generate-poam.sh` opens an item only for `FAIL` or `ERROR`, so the
      32 partial requirements' residual obligations and the 28 purely
      organizational ones never appear — they live only in
      `organizational-requirements.md`. An assessor will expect them tracked.
      Either emit them as rows with a disposition that distinguishes them
      from host findings, or state in the SSP that the register serves that
      purpose. This is a decision before it is a change.

- [ ] **5.5 `vm/nist-lab-network.xml` claims a ufw rule this host lacks.** The
      comment says the host's ufw policy "already permits nist-lab qemu
      guests". On this laptop `ufw status` shows rules for `virbr0` and
      `virbr-k8s` and none for `virbr17`, with default incoming deny. Guest to
      guest traffic crosses the bridge and never the host INPUT chain, so the
      lab works and nothing is broken — but the comment describes the other
      workstation, and it will mislead whoever first tries to make the host
      itself a receiver. Correct the comment, or add the rule it describes.

- [x] **5.6 Make every open defect testable on the laptop lab.** *Done
      2026-09-26:* the laptop runs both labs — the BYO guests (`vm/byo-guest.sh`,
      including `byo-rl9-02` with a volume group, a TPM and two accounts) and
      the kickstart lab (`make vm`, `make vm-log`), each in its own inventory
      (docs/LAB.md, *Two labs on one workstation*). Every 6b defect was
      reproduced and its fix proven here. The syslog-ng receiver is 6.2a's.
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
