# Tasks

The live checklist for `nist_sp_800_171r3/rl9-171/`. Only open work is here.

Phases 1–5 are closed. Their evidence, and the defects found earning it, are
`nist_sp_800_171r3/rl9-171/docs/DEFECTS.md`, cited by the same numbers
(1b.4, 2b.8, 3.2, 4.4). The ODP decisions are `docs/ODP-REVIEW.md`; operator
procedure is `docs/RUNBOOK.md`.

---

## Where the tool stands

**Consistent** — `make validate` passes: 97 active requirements (33 withdrawn),
334 checks defined and referenced, 32 machine ODPs + 62 organizational across
49 requirements, and every machine ODP asserted by a check. Disposition is
**37 technical, 32 partial, 28 organizational**.

**Proven against running hosts.** `make catalog` reproduces
`catalog/requirements.json` byte for byte from the PDF. `./apply.sh` is
idempotent and `--check --diff` is a real drift detector, including on a host
that has never been applied.

| Lab | Result |
| --- | --- |
| Kickstart, rebuilt with rotated secrets (5.1) | `rl9-cui-01` 36/33/0/28, `rl9-log-01` 35/34/0/28 — 334 checks, **0 failed** both |
| BYO retrofit, no `.secrets/` at all (2.1) | `byo-rl9-01` and `byo-log-01` 34/30/5/28 — 6 checks failed, **all five requirements documented retrofit limits** (2.2) |

Also proven: TLS audit-record forwarding on 6514 with mutual x509 (6.1); the
seven timers producing output; `organizational-requirements.md` rendering with
all 43 ODP sections; `tools/inventory.py` driven by real builds and destroys;
every lockout recovery in the RUNBOOK rehearsed with a scripted serial
console (Phase 3), which corrected two of them.

**Nothing remains written-but-unexecuted at the level of a procedure.** What
is open is listed below: one item needs a receiver we do not have, two need
authoring only the system owner can do, and three are defects found while
working out how to do them.

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
      and `sc-08-forward-encrypted` both PASS, and a record written on the
      CUI host is legible in the container's output.
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
