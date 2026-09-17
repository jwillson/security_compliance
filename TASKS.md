# Tasks

Working checklist to take `nist_sp_800_171r3/rl9-171/` from "builds and
assesses one VM" to "a tool I trust against a real Rocky 9 host".

Ordered so that each phase makes the next one meaningful. Phases 1–3 are
verification of things already written; phase 4 is decisions nobody but the
system owner can make.

---

## Status: what is proven, and what is only written

Be honest about the difference — most of what follows exists to close the gap.

**Proven against running hosts (`rl9-cui-01`, `rl9-cui-02`, `rl9-log-01`)**

- `make catalog` reproduces `catalog/requirements.json` byte for byte from the PDF
- `make validate` — 97 requirements, 327 checks, 29 + 47 ODPs, all consistent
- `./apply.sh` is idempotent (`changed=0` on re-run); `--check --diff` is a real drift detector
- `./verify.sh` — **all three hosts** 97 assessed, 327 checks, 0 failed, 43 / 26 / 0 / 28,
  three report pairs from one run
- The seven timers are active and producing output in `/var/log/nist-800-171/`
- `organizational-requirements.md` renders on the host with all 43 ODP sections
- `make vm-log` / `build-vm.sh --role log` builds a collector end to end
- `roles/nist_log_collector` applies cleanly; rsyslog config passes `rsyslogd -N1`
- **03.03.05c audit-record forwarding actually works** — records arrive in
  `/var/log/nist-remote/<host>/` at 0700/0600 root:root, and
  `au-05-forward-established` / `au-05-collector-receiving` each report PASS
  on the host where they are meaningful and MANUAL where they are not
- `tools/inventory.py` driven by real builds and destroys: adding a second
  host preserves the first, destroying one rewires the survivors

**Written but never executed**

- The whole BYO-host path (`inventory/hosts.yml.example`) — the headline
  portability claim, never run against a machine this toolkit did not build.
  Note that `make secrets` turns out to be a prerequisite after all (03.08.09
  reads `.secrets/luks_passphrase`); that trap is now documented but still
  untested in anger
- Every lockout recovery procedure in the runbook

---

## Phase 1 — prove the lab end to end

- [x] **1.1 Build the log collector.** `make vm-log`
  *Why:* the single largest unproven piece. The role, the second play, the
  `--role log` path and the inventory rewiring all execute for the first time
  here.
  *Done when:* `./tools/inventory.py show` lists two hosts and the CUI host
  forwards to the collector.

- [x] **1.2 Apply to both and confirm forwarding actually works.**
  `./apply.sh && ./verify.sh --requirement 03.03.05`
  *Why:* 03.03.05c has never been verified, only deferred to MANUAL.
  *Done when:* `au-05-forward-established` and `au-05-collector-receiving`
  both report **PASS**. If either stays MANUAL the wiring is wrong, not the
  host.
  *Check by hand too:* `ls /var/log/nist-remote/*/` on the collector should
  show a directory named for the CUI host.

- [x] **1.3 Confirm the collector is itself hardened.**
  `./verify.sh --host rl9-log-01`
  *Why:* it stores other systems' audit records. If the first play did not
  cover it, it is an unhardened box holding CUI evidence.
  *Done when:* it reports the same 43 / 26 / 0 / 28 as the CUI host.

- [x] **1.4 Build a second CUI host.** `./vm/build-vm.sh --name rl9-cui-02`
      *Done.* Three hosts, one `./verify.sh` run, three report pairs, all
      **43 / 26 / 0 / 28, 327 checks, 0 failed**. `tools/inventory.py` kept
      both existing hosts and wired the new one to the collector by itself.
      Two results the two-host lab could not produce:
      * **Many-to-one forwarding works.** The collector now holds
        `/var/log/nist-remote/rl9-cui-01/` and `.../rl9-cui-02/` side by side.
      * **The build is reproducible.** A host created from scratch reaches the
        same 43/26/0/28 as one hardened over two days, in one apply plus one
        reboot.

- [x] **1.5 Read the generated organizational document on a host.**
  `sudo cat /etc/nist-800-171/organizational-requirements.md`
  *Why:* it has only been rendered in `--check`. Confirm the 43 ODP sections
  are present and the tables are not mangled.

---

## Phase 1b — defects Phase 1 uncovered

Found by building a second host. Each was invisible with one VM.

- [x] **1b.1 `--role log` set install memory to 2048.** virt-install silently
      raised it to its 3072 minimum and the install died at firmware: idle
      CPU, zero disk writes, silent serial console, no diagnostic. Both roles
      now install at 4096. *Fixed.*

- [x] **1b.2 `ac-01-nologin-shells` false positive.** It accepted only
      `/sbin/nologin` and `/bin/false`. `clevis` ships `/usr/sbin/nologin`,
      the same binary under the /usr merge, and was reported as a system
      account with an interactive shell. Now accepts both spellings. *Fixed.*

- [x] **1b.3 A collector's own listener was an unauthorized port.** The
      collector opens 514 for 03.03.05c, which `cm-06-no-listening-extras`,
      `sc-06-no-unexpected-ports` and `sc-06-listening-allowlist` correctly
      flagged, because their allowlist was hardcoded to 22. Fixed without
      widening the checks: each host declares its authorized ports in
      `/etc/nist-800-171/authorized-ports.d/`, written by whatever opened
      them, and the checks subtract that declaration. 514 is authorized on a
      collector and still a finding on a plain CUI host. *Fixed.*

- [x] **1b.4 `apply.sh` reported "Reboot required: False" when a reboot was
      required.** *Fixed, and tested in both directions against a
      deliberately staged host.* `augenrules` exits 0 whether it loaded the
      rules or refused them, so its exit code was never evidence. The handler
      now reads stdout: `augenrules --check` prints "Rules have changed and
      should be updated" exactly when what is on disk is not what the kernel
      enforces.
      Tempting and wrong: keying on the "immutable mode" message from
      `--load`. A settled, locked host prints that too, so it would demand a
      reboot after rewriting a file with identical content.
      *Proven:* rules genuinely pending -> `Reboot required: True`; nothing
      pending -> `False`, on the same host minutes apart.

- [x] **1b.5 Answered by 1.4: a from-scratch host genuinely passes.** The
      worry was that `rl9-cui-01` reported `loginuid_immutable 1` from stale
      running-kernel state rather than from configuration. `rl9-cui-02` was
      built, hardened and rebooted once, and passes
      `ia-01-loginuid-immutable` — so the control is real, and the reboot is
      the whole of what it needs. The 1b.4 fix also proved itself unstaged in
      the same run: of the three hosts, only the fresh one reported
      `Reboot required: True`, and the two settled hosts applied at
      `changed=0`.

- [x] **1b.6 The collector is idempotent after all — my earlier reading was
      wrong.** I recorded that `03.14.08 | Tighten permissions on existing log
      files` changed on every run. Isolating it (`--tags 03.14.08`, twice) gave
      `changed=0` both times, and a subsequent full apply of the collector gave
      `changed=0` overall. The task is correctly written: it chmods only files
      whose mode exceeds 600 and reports changed only if it acted, and it is
      `maxdepth 1`, so the `/var/log/nist-remote/` files I blamed are out of
      its scope entirely. The `changed=3` runs were a freshly rebooted host
      settling (journal directory recreated, then its files tightened). No
      defect. *Recorded here because the wrong diagnosis was committed.*

- [x] **1b.7 `--tags <requirement>` ran nothing at all.** README, RUNBOOK and
      `apply.sh`'s own header all promised that `--tags 03.05.07` applies exactly
      that requirement's tasks. `main.yml` used `include_tasks` with only the
      family tag on the include statement, so a requirement tag never reached
      the inner tasks: `--tags 03.05.01` ran **0** tasks while `--tags 03.05`
      ran 26. All 17 includes converted to `import_tasks`, which resolves at
      parse time so each task's own tag is visible to the filter. *Fixed —
      `--tags 03.05.01` now runs exactly those four tasks.* Found only
      because 1b.4 needed to trigger one requirement's tasks in isolation.

---

## Phase 2 — prove the portability claim

The stated goal is a single portable tool that can harden *any* Rocky 9 host.
Nothing has tested that outside the kickstart VMs.

- [~] **2.1 Harden a Rocky 9 host this toolkit did not build.** *In progress —
      paused mid-task.* A stock Rocky 9 GenericCloud image (`byo-rl9-01`,
      192.168.171.151, user `byoadmin`, UEFI, single 19 GB root, FIPS off,
      firewalld inactive) was booted with cloud-init — deliberately not via
      `build-vm.sh`. It found three real defects; the portability claim was
      false as shipped.

      * **FIXED and proven — `site.yml` only worked on hosts its own kickstart
        built.** The `pre_task` that records the overlay version writes into
        `/etc/nist-800-171/`, and the role task that *creates* that directory
        runs in `roles:`, i.e. after `pre_tasks:`. The kickstart does
        `mkdir -p /etc/nist-800-171` in `%post`
        (`vm/kickstart/rl9-cui.ks.j2:145`), so lab hosts had it already and
        the bug was invisible. On the BYO host the play died on its second
        task: *"Destination directory /etc/nist-800-171 does not exist"*.
        The pre_task now creates it. Proven: the apply went from `ok=2` to
        `ok=87, changed=53`.

      * **FIXED, NOT YET VERIFIED — mount hardening aborted the whole play.**
        03.04.06 mounts the kickstart's LVM volumes
        (`/dev/mapper/vg_sys-lv_home`, `-lv_tmp`, `-lv_vartmp`). On a
        single-partition host those devices do not exist, the task failed, and
        the play stopped — so the remaining overlay never applied and a BYO
        host could not be hardened at all. The task now stats each device
        first, hardens only what exists, and writes
        `{{ nist_conf_dir }}/unretrofittable-mounts` naming the rest.
        **This change is syntax-checked only. Re-run the BYO apply to confirm
        it completes.**

      * **OPEN — `./apply.sh --check --diff` cannot succeed on a host that has
        never been applied.** Both README and RUNBOOK tell BYO operators to
        dry-run first. In check mode the tasks that would create the systemd
        units do not actually write, so the task that enables
        `nist-audit-review.timer` fails with *"Could not find the requested
        service"*. Verified asymmetry: `--check` succeeds on `rl9-cui-01`
        (already applied, `changed=0`) and fails on `byo-rl9-01`.
        *Fix:* guard service-enable tasks with `when: not ansible_check_mode`,
        or make them tolerant of a unit that does not exist yet. Then correct
        the docs, which currently promise a dry-run that cannot work.

      *Resume here:* re-run
      `./apply.sh -i <byo-inventory> --limit byo-rl9-01` with
      `NIST_BECOME_PASSWORD` exported, confirm it completes, then `./verify.sh`
      and record the deviations for 2.2.

- [ ] **2.2 Write down which requirements a retrofit cannot satisfy.**
  Expect the separate `/var/log/audit` filesystem (03.04.06) and FIPS from
  first boot (03.13.11).
  *Why:* this is the honest answer to "can I use this on my existing fleet?"
  It belongs in the README next to the assessment numbers.

- [ ] **2.3 Confirm the non-lab connection path works.** No `.secrets/`, key
  from `~/.ssh`, become password from the environment.
  *Why:* `lib/ssh-env.sh` was changed to tolerate a missing `.secrets/`. That
  change has been proven not to break the *lab*; it has not been proven to
  *work* without one.

---

## Phase 3 — rehearse the recovery procedures

Every procedure in `docs/RUNBOOK.md#when-you-are-locked-out` is standard
practice that has **not** been tested against this baseline. The runbook says
so. Fix that on a throwaway guest, before needing it at 2am.

- [ ] **3.1 Snapshot a guest.** `virsh snapshot-create-as rl9-cui-02 pre-lockout`
- [ ] **3.2 Trigger a faillock lockout** (3 bad passwords) and recover with
      `faillock --user <name> --reset` from the console.
- [ ] **3.3 Back MFA out from the console** and confirm you can log in with a
      key alone, then re-apply to restore it.
- [ ] **3.4 Lock yourself out with the firewall** and recover via
      `firewall-cmd --add-source`.
- [ ] **3.5 Correct anything the runbook got wrong.** A recovery step that
      does not work is worse than no step.
- [ ] **3.6 Update the runbook header** — it currently says these are
      unrehearsed. Once they are, say so instead.

---

## Phase 4 — decisions only the system owner can make

No amount of testing substitutes for these. Each is a live commitment.

- [ ] **4.1 Review all 29 machine ODPs and all 47 organizational ODPs** in
      `catalog/overlay-rocky9.yml`.
      *Why:* they are defaults drawn from common DoD CUI practice, not your
      organization's values. `make validate` confirms nothing references a
      parameter that does not exist — it cannot tell you a number is wrong.
      An assessor will ask where each came from.

- [ ] **4.1b ODP audit results — 26 of 76 carry a finding, 18 assignments are
      unanswered.** A full audit mapped all 76 ODPs onto the 82
      organization-defined decision points in the 97 active statements.
      Spot-verified: every claim below was confirmed directly.

      *Contradictions — the register says the opposite of what the host does:*
      * `auth_refresh` says "passwords on recovery **not calendar**" while
        `odp.password_max_age: 60` expires them every 60 days and two checks
        assert it. The SSP would state the opposite of the evidence. Pick one.
      * `session_events` says 900s idle, but SSH sessions actually drop at
        `ssh_client_alive_interval: 600`. It is also in the organizational
        block despite 03.01.11 being `technical` and machine-asserted.

      *Dead and drifting policy:*
      * `odp.patch_window_days: 30` is the **only** machine ODP no check
        references. The dnf timer is hardcoded; changing it changes nothing
        and fails nothing. 03.14.01b is a policy SLA — `patch_sla` is its
        right home.
      * Three registers understate the host: `assess_freq` 12 months /
        `audit_review_freq` 7 days / `inv_review` 30 days, against timers that
        all run **daily**. No check asserts any timer's `OnCalendar`, so the
        schedules are unparameterised, unasserted, and in three cases
        contradicted by the register the SSP cites.
      * Four `host_scope` texts cite "the ODP frequency"/"the ODP names" for
        ODPs that do not exist (03.03.01, 03.11.02, 03.14.02, and see 4.4).

      *Contractual — needs legal/contracts review, do not ship unexamined:*
      * `ir_authorities` names CISA. For the DoD CUI population this targets,
        DFARS 252.204-7012 requires reporting to DoD via DIBNet within 72
        hours. No ODP carries that clock.

      *Baseline coherence:*
      * `config_settings` names "DISA RHEL 9 STIG + CIS L2 + this overlay"
        with no precedence rule, so 03.04.02a's "most restrictive mode" is
        unresolved. `password_min_length: 14` is the CIS value while every
        neighbouring value is STIG — confirm the STIG minlen for your
        revision and either raise it or document the deviation.
      * `patch_sla` drops the medium tier that `remediate_sla` rates 90 days,
        while claiming "Matches 03.11.02".

      *Assertion semantics:*
      * `ac-08-faillock-unlock` asserts `>= lockout_duration_seconds`, but the
        ODP's own comment offers `0 = until admin release`. Set 0 and the
        check passes anything; leave 900 and the strictest possible host
        setting (never auto-unlock) **fails**. `ac-08-faillock-deny` likewise
        passes `deny = 0`, which disables lockout entirely.
      * `au-03-retention-capacity` asserts `n * s >= 500`, a magic constant
        unrelated to `audit_retention_days`. auditd's `ROTATE` **deletes** the
        oldest log at `num_logs`, so 90-day retention is not guaranteed by the
        settings meant to deliver it.

      *Factual:* `travel_config` and `media_types` name `usbguard`, which this
      toolkit never installs — it blacklists the `usb-storage` module.

      *Unanswered:* 18 assignments across 13 requirements have no ODP at all,
      including `03.03.04a`'s audit-failure alert window on a requirement
      marked `technical`, `03.03.01a`'s event types, and `03.04.06b`'s
      prohibited functions/ports/services list. Both nested `[Selection:]`
      choices (03.01.08b, 03.01.10a) are unrecorded.

- [ ] **4.1c Add the two validator guards that would have caught most of
      this.** Neither costs judgement, and both will red-light `make validate`
      until the defects above are resolved — which is the point, so sequence
      them with the fixes:
      * every key in `odp:` must be referenced by at least one check
        (catches `patch_window_days`);
      * no `technical` entry may carry a `residual` (catches all six in 4.4).
      Longer term: give each ODP an `answers:` field naming the requirement
      *and statement letter* (`03.14.01b`), then assert every assignment is
      answered exactly once.

- [ ] **4.2 Decide the ClamAV / EPEL trade-off (03.14.02 vs 03.17.03).**
      Signature scanning needs EPEL, which sits outside the authorized
      repository set. Currently off, which is why the VM reports 43 satisfied
      rather than 44. Either accept the gap and record it, or set
      `nist_clamav_enabled` + `nist_enable_epel` and justify the repository.

- [ ] **4.3 Profile fapolicyd against a real workload.** Deny-by-default
      execution will block unprofiled applications. Run with
      `nist_fapolicyd_permissive: true`, collect, write rules, re-enforce.

- [ ] **4.4 Six requirements report PASS while conceding they are not fully
      satisfied.** Reviewed in depth; decision outstanding because changing a
      disposition changes what the tool claims about compliance.

      `03.01.05`, `03.01.10`, `03.01.12`, `03.05.05`, `03.05.12` and
      `03.07.05` are classified `technical` *and* carry a `residual` field.
      `residual` is the field that names what the organization still owes — it
      is the definition of `partial`. The assessor only downgrades `partial`
      to MANUAL, so all six print **PASS** in the current report next to prose
      conceding non-compliance. That is precisely the overstatement this
      project exists to prevent, and it is live today.

      Three were examined against the publication text, the checks and the
      implementing tasks — two of the six, plus `03.08.02`, which carries no
      `residual` but overstates in the same way. `03.01.10`, `03.01.12` and
      `03.07.05` are not yet examined. All three examined should be `partial`:
      * `03.05.05` — nothing implements statement (c), reuse prevention over a
        time period. `ia-05-no-uid-reuse` tests that no two *current* accounts
        share a UID, which is 03.05.01a restated. Statement (d)'s
        status-characteristic clause has no control either.
      * `03.05.12` — statements (a), (c), (d) uncovered; (e) enforced for
        local passwords only, not for the event triggers, SSH keys or tokens.
      * `03.08.02` — the publication defines system media as including
        **non-digital** media, which is why siblings 03.08.01/.04/.05 are
        already `organizational`. A PASS also transitively claims what
        03.04.11 explicitly disclaims. And `cuiusers`, the operative
        definition of "authorized personnel", is created empty and unmanaged.

      *Two `host_scope` claims are simply false and should be struck whatever
      is decided — both were verified as unimplemented:*
      * `03.05.12`: "the installer's root password is expired at first boot" —
        no such task exists anywhere in the role.
      * `03.05.05`: "UID reuse is blocked by retaining the account record" —
        no such mechanism; the only reuse control is password history.
      * `03.08.02`: "its parent path is not world-traversable" — asserted by
        no check.

- [ ] **4.4b Make `validate.py` reject `residual` on a `technical` entry.**
      It already rejects `partial` without a `residual`; the converse is the
      same error the other way round and would have caught all six above
      automatically, at no judgement cost.

- [ ] **4.5 Decide what happens to `nist_sp_800_171r3/web/`.** An nginx TLS
      snippet, orphaned from the tool, which hardens hosts rather than web
      tiers. Its requirement IDs are now correct. Either fold it into scope
      properly, or delete it and stop implying it is maintained.

---

## Phase 5 — cleanup and housekeeping

- [ ] **5.1 Rotate `.secrets/`.** Free at the next rebuild, disruptive at any
      other time — it locks you out of every guest built with the old key.
      ```bash
      make destroy && rm -rf .secrets && make secrets && make vm
      ```

- [ ] **5.2 Delete the `r3-hardening-middleware` branch.** `main` contains
      everything; the branch is redundant.

- [x] **5.3 `archive/` removed.** The reconciliation had served its purpose:
      `r3/`, `os/` and `stig/` are gone, along with `tools/legacy-gap.py` and
      `docs/legacy-gap.md`, which existed only to document them. 618 MB
      reclaimed, almost all of it the gitignored `r3/lab/.state/` qcow2.
      Everything remains in git history. *Done.*

- [x] **5.4 Local build cruft pruned** with 5.3 — the cached cloud image and
      `__pycache__` directories went with the archive. *Done.*

---

## Phase 6 — before any real CUI host

- [ ] **6.1 Put TLS on the collector.** 514/tcp plain is acceptable only
      because the lab network is isolated. Real use needs 6514 with
      certificates; `roles/nist_log_collector` does not provision them.

- [ ] **6.2 Point forwarding at the real SIEM**, not a lab collector, and
      confirm `au-05-forward-established` still passes against it.

- [ ] **6.3 Generate and review the SSP.** `sudo nist-generate-ssp`, then read
      `/etc/nist-800-171/system-security-plan.md`. It is generated from live
      state; the threat description, role assignments and approval are yours
      to author.

- [ ] **6.4 Open POA&M items for every remaining gap.**
      `sudo nist-generate-poam` turns failed checks into a CSV. The 28
      organizational requirements and 25 partial residual obligations are not
      in it — they come from `organizational-requirements.md`. The six
      residuals on `technical` requirements (4.4) appear in neither, which is
      part of why 4.4 matters.

- [ ] **6.5 Re-read the caveat that matters.** Passing every check means the
      host-enforceable controls are in place. It does not mean the system is
      compliant or authorized.

---

## Not planned

Recorded so they do not get re-litigated:

- Reviving the superseded trees, now deleted (recoverable from git history).
  `r3/` was retired for cause: its verifier graded on exit status, 14 of its
  checks could not fail and 4 were inverted. `os/` and `stig/` were r2-tagged.
  Both worthwhile pieces were ported before removal.
- Supporting distributions other than the RHEL 9 family. The overlay is
  Rocky 9 specific by design and `site.yml` asserts it.
