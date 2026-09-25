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

**Tested** — `make test`: 41 unit tests for the assessor and the validator.
`make catalog-check` proves `catalog/requirements.json` still reproduces byte
for byte from the PDF. Since 6b.1 the assessor never reads a command that
could not run as a clean result: a missing tool or an undeclared exit status
is ERROR, and it refuses to run unprivileged or off RHEL 9.

**Proven against running hosts.** `./apply.sh` is idempotent and
`--check --diff` is a real drift detector, including on a host that has
never been applied.

| Lab | Result |
| --- | --- |
| Kickstart, rebuilt with rotated secrets (5.1) | `rl9-cui-01` 36/33/0/28, `rl9-log-01` 35/34/0/28 — 334 checks, **0 failed** both |
| BYO retrofit, no `.secrets/` at all (2.1) | `byo-rl9-01` and `byo-log-01` 34/30/5/28 — 6 checks failed, **all five requirements documented retrofit limits** (2.2) |
| BYO pair, 2026-09-25, after a week powered off | 33/30/6/28 on both — the five retrofit limits plus `si-01`: 21 security advisories pending. A host finding, cleared by the next apply |
| `byo-rl9-02`, first cycle, 2026-09-25 (`tools/harden-cycle.sh`) | **35/31/3/28**, 6 checks failed: 03.01.01 and 03.05.12 (6b.4 — the checks catch it) and 03.04.06 (no separate `/tmp`, the retrofit limit). Dry run, apply, reboot, apply, then `changed=0`. The LUKS requirements PASS with the key in cleartext beside the volumes (6b.5), and 03.10.07 PASSes with no GRUB password (6b.2) |
| `byo-rl9-01`, same afternoon | 32/30/7/28 — the role's update timer installed 13 of the 21 advisories and a new kernel by itself; `sa-02-kernel-current` then fails 03.16.02 until a reboot. The timer working, and the assessor saying a reboot is owed |

**Every number in that table overstates, until 6b.2–6b.6 are fixed.** A review
on 2026-09-25 found five role defects, and in four of them the check was as
wrong as the role: 03.10.07 (no GRUB password exists), 03.03.05c (no audit
record is forwarded), and 03.01.11 / 03.13.09 (the SSH setting asserted does
nothing) have all been reported PASS on hosts where they are not true, and
the LUKS checks cannot see that the key sits beside the data it unlocks. See
*Open — defects in the role and its checks* below.

Also proven: the TLS **transport** on 6514 with mutual x509 (6.1) — but what
it carries is syslog, not the audit trail (6b.6); the
seven timers producing output; `organizational-requirements.md` rendering with
all 43 ODP sections; `tools/inventory.py` driven by real builds and destroys;
every lockout recovery in the RUNBOOK rehearsed with a scripted serial
console (Phase 3), which corrected two of them.

What is open is listed below: five defects in the role and its checks, the
first priority; one item that needs a receiver we do not have; two that need
authoring only the system owner can do; three defects found while working
out how to do them; and the lab work that makes all of it testable here.

---

## Release 1.0 — what a public release needs

Goal set 2026-09-25: a public release. The repository stays private until
every blocker below is closed. The bar follows from what the tool is: a
compliance assessor that reports a false PASS is worse than none, because it
is believed.

**Blockers**

- [ ] **R1 No known false PASS.** 6b.2, 6b.3, 6b.4, 6b.6 fixed and proven;
      6b.5 fixed after the owner's decision, or its requirements downgraded
      so the report stops implying encryption at rest that the key placement
      defeats.
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

## Open — defects in the role and its checks

Found by the cloud review of 2026-09-25 (after PR #2), each confirmed on
`byo-rl9-01` / `byo-log-01` the same day. Continues the 6b series in
`DEFECTS.md`, where 6b.1 is closed. Fixes are requested from the cloud session
as one PR, one commit per defect; 6b.5 needs an owner decision first.

- [ ] **6b.2 03.10.07: no GRUB password is ever set, and the check passes.**
      Stock `grub2-tools` ships `/etc/grub.d/01_users` containing the literal
      template `password_pbkdf2 root ${GRUB2_PASSWORD}`, filled from
      `user.cfg` only when one exists. The role's guard (`pe.yml:36`) greps
      that file for `password_pbkdf2`, so it always prints "already-set" and
      writes nothing; `pe-07-grub-password` greps the same file and passes.
      *Evidence:* on the hardened guest `rpm -V grub2-tools` shows `01_users`
      unmodified and no `user.cfg` exists, so GRUB has **no password at
      all**. The kickstart defers the password to the role (see the comment
      above `bootloader` in `rl9-cui.ks.j2`), so the kickstart lab took the
      same path — inferred; that lab is on the other workstation. Also: the
      password the role meant to set is left in cleartext at
      `/root/.grub-pw` (0400).
      *Fix direction:* leave `01_users` stock and write `/boot/grub2/user.cfg`
      as `grub2-setpassword` does; delete the staged file; the check asserts
      a real `grub.pbkdf2.` hash, never the template. RHEL 9 boots BLS
      entries, which carry `grub_arg --unrestricted`, so the `10_linux` edit
      may be dead code — the test must include a reboot with no console
      input.

- [ ] **6b.3 03.01.11 / 03.13.09: the SSH idle setting asserted does nothing.**
      `odp.ssh_client_alive_count_max: 0`, and the installed OpenSSH 9.9 man
      page: "Setting a zero ClientAliveCountMax disables connection
      termination." `ac-11-` and `sc-09-clientalive-countmax` assert
      `<= ODP`, so they pass it. Raising the value to 1 is not the fix
      either: a live idle client answers the keepalive probes, so ClientAlive
      only reaps dead clients — and `<= 1` would still pass 0.
      *What actually enforces idle today:* `TMOUT=900`, readonly, for bash
      prompts (`ac.yml:509`). Uncovered: SSH sessions not at a prompt — a
      foreground program, sftp, forwards. `sshd -T` shows `channeltimeout
      none`, `unusedconnectiontimeout none`.
      *Fix direction:* `ChannelTimeout session=` and `UnusedConnectionTimeout`
      from `session_timeout_seconds`, asserted from `sshd -T`; a nonzero
      CountMax to reap dead clients, asserted as a range that excludes 0.
      Needs OpenSSH ≥ 9.2; earlier Rocky 9 minors shipped 8.7p1, so gate on
      the version and record the gap rather than fail the apply. Correct
      `ma.yml:48` and the 03.01.11 text, which name ClientAliveInterval as
      the mechanism.
      *Owner decision:* this changes `ssh_client_alive_count_max`, a value
      accepted in `ODP-REVIEW.md` A2 on a premise that was wrong.

- [ ] **6b.4 03.01.01 / 03.05.12: account aging does nothing on a host with
      more than one user.** `ac.yml:36` (inactivity lock) and `ia.yml:368`
      (password lifetime) loop over
      `{{ nist_interactive_accounts.stdout_lines | join(' ') | quote }}`:
      `quote` makes the whole list one word, so with two users the loop runs
      once on `"alice bob"`, `chage` fails on a user that does not exist, and
      the task reports `changed=0`. Invisible on the lab, where every host has
      one interactive account.
      *The checks are right:* `ac-01-inactive-users` and `ia-12-existing-*`
      read every account in `/etc/passwd`, so a multi-user host reports FAIL
      — the one defect of the five the assessment would have shown.
      *Fix direction:* loop over the list, and let a failing `chage` fail
      the task. Test with a second interactive account (5.6).

- [ ] **6b.5 03.08.09 / 03.13.08: the LUKS key sits beside the data it
      unlocks.** `mp.yml` stages `/root/.luks-key` and `crypttab` points at
      it; the kickstart's `lv_root` is plain xfs. The "key file" is
      `nist_luks_passphrase` itself, in plaintext. Anyone holding the disk
      reads it and opens the CUI and backup volumes, so encryption at rest
      protects against nothing it exists for. The checks (`mp-03-`,
      `sc-08-luks-*`, `mp-09-luks-cipher`, `sc-10-luks-kdf`) count crypt
      devices and read ciphers; nothing asks where the key lives.
      *The intended design was TPM2:* `mp.yml` runs `clevis luks bind ...
      tpm2` (PCR 7), best-effort with `failed_when: false`. But a successful
      bind leaves the key file on disk and `crypttab` still pointing at it,
      and the task's comment — "a host without a TPM keeps the key file,
      which the auditor reports" — is false: no check reports it.
      *And the bind does not work where there is a TPM.* On `byo-rl9-02`
      (TPM 2.0, Secure Boot, first run of the LUKS path on any lab guest)
      both binds exit 1 with no output, first apply and every one after;
      `failed_when: false` reports that as `ok`. The platform is not the
      cause: the clevis packages are installed, PCR 7 reads, and `clevis
      encrypt tpm2` with the role's exact pin seals (`tools/probe.sh
      6b-evidence`). It is `clevis luks bind` itself, which writes the LUKS
      header, so the root cause is left to the fix. Reproduce with
      `./apply.sh --limit byo-rl9-02 --tags 03.13.10 -v`.
      **Owner decision before any code:** clevis + TPM2 (needs a vTPM on the
      guests), clevis + tang (needs a tang server), a passphrase at boot
      (gives up unattended boot), or root encrypted at install. The cloud
      session will write the options up with a recommendation.
      *Testable only with a volume group* — the BYO guests have none (5.6).

- [ ] **6b.6 03.03.05c: audit records are never forwarded, and three checks
      pass.** Nothing routes auditd into rsyslog: no
      `/etc/audit/plugins.d/syslog.conf`, no `imfile` on `audit.log`. The
      forwarder ships syslog, which the collector stores.
      *Evidence:* `byo-rl9-01` holds 111,198 records in
      `/var/log/audit/audit.log`; the collector's
      `/var/log/nist-remote/byo-rl9-01/` holds **0** records written by auditd.
      What does arrive: three status lines from the auditd daemon, and 30
      `kernel: audit: type=NNNN` lines the kernel printed to kmsg only while
      auditd was not running (shutdown, boot). `tools/probe.sh 6b-evidence`
      counts both separately; a bare `grep type=` overcounts, because
      ansible's own module arguments contain `type=`. `au-05-rsyslog-forwarding`
      passes on any forwarding rule, `au-05-forward-established` on any open
      socket, `au-05-collector-receiving` on any remote record.
      *Fix direction:* the audisp syslog plugin (or `imfile`), sized for about
      110k records a week on an idle host; the collector check requires an
      audit record (`type=`) from another host; a forwarder check asserts the
      plugin is active. 6.2a depends on this.

- [x] **6b.7 `--check` failed on a never-applied host that has a volume
      group.** *Found and fixed 2026-09-25 on `byo-rl9-02`, its first run.*
      With room in `vg_sys` and a LUKS passphrase, check mode reports the
      logical volumes as "would be created" and skips the format and open
      shell tasks, so `/dev/mapper/cui_data` never exists and "Create
      filesystems on the encrypted volumes" failed on the missing device
      (`failed=1`, 118 tasks in). AGENTS.md promises the dry run completes on
      a never-applied host; 2b.3 made that true only on the paths the labs
      had exercised — the retrofit guest has no volume group, and the
      kickstart hosts had their volumes before anyone ran `--check`.
      *Fix:* the 2b.3 idiom in `mp.yml` — the LV task registers
      `nist_luks_lvs`, and the filesystem and mount tasks are skipped only in
      check mode while it is outstanding. *Proven:* reverted to `fresh`, the
      dry run then completed, `ok=183 changed=123 failed=0`.
      Moves to DEFECTS.md with the rest of 6b when the series closes.

- [x] **6b.8 `--tags 03.13.10` failed: "'nist_can_encrypt' is undefined".**
      *Found and fixed 2026-09-25, reproducing 6b.5.* The TPM bind carries
      the 03.13.10 tag, but the two tasks that compute `nist_vg_free` and
      `nist_can_encrypt`, which its block depends on, were tagged only
      03.08.09 / 03.13.08, so selecting 03.13.10 alone evaluated the block's
      `when` against an undefined fact and failed the play — the promise of
      1b.7 (a requirement tag selects that requirement's tasks) broken for
      this one. *Fix:* both tasks also carry 03.13.10. `| default(false)`
      would have been wrong: the bind would then silently run nothing, 1b.7's
      original failure. *Proven:* `--tags 03.13.10` reaches the bind task,
      `failed=0`.

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
      output. *Depends on 6b.6:* until then only syslog is forwarded, and
      "a record arrived" proves nothing about the audit trail.
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

- [ ] **5.6 Make every open defect testable on the laptop lab.** The BYO pair
      reproduces 6b.2, 6b.3 and 6b.6 as they are. Authorized 2026-09-25: grow
      the lab as needed, without disturbing the BYO pair's role as the
      retrofit reference. *Done so far* (`docs/LAB.md`): `vm/byo-guest.sh`
      builds BYO guests reproducibly, and built `byo-rl9-02` (.144) with a
      second interactive account (6b.4), a data disk carrying `vg_sys` with
      10 GB free (6b.5, 2.2's LUKS limits) and a TPM 2.0 — the role's clevis
      `tpm2` bind has never run before this guest. `vm/byo-snapshot.sh`
      snapshots disks, NVRAM and TPM state. `tools/inventory.py add
      --connection byo` replaces the hand-edited inventory entries (proven
      byte-identical). `tools/probe.sh 6b-evidence` and
      `tools/assessor-parity.sh` script the evidence and the PR #2 method.
      `tools/harden-cycle.sh` runs and records a full cycle; its first run,
      on `byo-rl9-02`, found 6b.7 and 6b.8 and the 6b.5 bind failure, and
      reproduced 6b.2–6b.6 (`reports/runs/`, before/after evidence).
      *Remaining:* the syslog-ng container (6.2a, after 6b.6).

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
