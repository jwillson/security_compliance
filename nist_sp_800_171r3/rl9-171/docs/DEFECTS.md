# Record — what was proven, and the defects found proving it

Split out of `TASKS.md` on 2026-09-22. Every phase below is closed; the text
is the contemporaneous record, unchanged, because the defect narratives are
the evidence that the claims in the README and the RUNBOOK were earned rather
than assumed. Cited from TASKS.md by number (1b.4, 2b.8, 3.2, 4.4 ...).

The live checklist — what is still open — is `../../../TASKS.md`.

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

---

## Phase 2 — prove the portability claim

The stated goal is a single portable tool that can harden *any* Rocky 9 host.
Until Phase 2 nothing had tested that outside the kickstart VMs, and the
claim was false as shipped: eight defects (2b) separated the code from the
result below, and each was invisible on a host the kickstart had built.

- [x] **2.1 Harden a Rocky 9 host this toolkit did not build.** *Done, from
      scratch, twice.* A stock Rocky 9.8 GenericCloud image (`byo-rl9-01`:
      UEFI, one 19 GB root partition, no LVM, FIPS off, firewalld not even
      installed, sudo asks for a password) booted with cloud-init on an Ubuntu
      laptop — a second control workstation with no `.secrets/`, ansible in a
      venv, the key from `~/.ssh`, the become password from the environment.
      Deliberately nothing from `vm/build-vm.sh`.

      * `./apply.sh --check --diff` on the never-applied host: `ok=171
        changed=116 failed=0`.
      * `./apply.sh`: `ok=226 changed=149 failed=0`, `Reboot required: True`.
        The 03.04.06 mount task found none of the five kickstart volumes,
        hardened nothing by device path, wrote `unretrofittable-mounts`
        naming all five, and the play went on — the fix Opus left unverified
        is proven.
      * After the reboot FIPS is on, sshd enforces `publickey,password` and
        the operator's own askpass supplies the second factor.
      * `./verify.sh`: **34 / 30 / 5 / 28, 334 checks, 6 failed** (41 / 23
        before the 4.4 re-dispositions), all six
        the retrofit limits in 2.2.
      * `./apply.sh` after the reboot: `changed=2` - `support-status` now
        names the kernel the security updates installed, and 03.14.08
        tightened the one 0440 service-group log the old rule let through.
        The apply after that: `changed=0`; `--check --diff` on the applied
        host, before and after another reboot: `changed=0`. (Shell tasks
        such as 03.14.08 are skipped in check mode, so a real apply is what
        proves that one.)

      Eight defects stood between the shipped code and that result — see 2b.
      The first two were Opus's; the rest were invisible until the whole path
      ran, and the last two until the host was rebooted and applied again.

- [x] **2.2 Write down which requirements a retrofit cannot satisfy.**
      Exactly five requirements, six checks, on a host with a single root
      filesystem and no volume group. Both causes are install-time and the
      role records them (`unretrofittable-mounts`, and the 03.08.09 warning)
      rather than failing the run:
      * **03.04.06** `cm-06-mount-options`, `cm-06-tmp-separate` — `/home`,
        `/tmp`, `/var/tmp`, `/var/log`, `/var/log/audit` are not separate
        filesystems. A playbook cannot repartition a running system.
      * **03.01.18**, **03.08.03**, **03.08.09**, **03.13.08** — one LUKS check
        each (`ac-18-luks-root-or-data`, `mp-03-luks-present`,
        `mp-09-luks-cipher`, `sc-08-luks-encrypted`). The encrypted CUI and
        backup volumes need free space in `vg_sys`; this host has no volume
        group at all. A host with an LVM root and 3 GB free passes these on
        a retrofit, given `NIST_LUKS_PASSPHRASE`.
      Not on the list, contrary to expectation: FIPS (03.13.11) retrofits
      cleanly with one reboot. Recorded in the README next to the lab numbers.

- [x] **2.3 Confirm the non-lab connection path works.** *Proven by 2.1:* no
      `.secrets/` existed on the control workstation at any point.
      `lib/ssh-env.sh` fell through to `~/.ssh/known_hosts`, the key came from
      `~/.ssh/id_rsa` (RSA-3072, so FIPS accepts it), sudo from
      `NIST_BECOME_PASSWORD`, and after 03.05.03 the second SSH factor from an
      operator-supplied `SSH_ASKPASS`. `apply.sh` re-recorded the host key in
      `~/.ssh/known_hosts` after 03.13.10 rotated it, as designed.

---

---

## Phase 2b — defects Phase 2 uncovered

Each was invisible on a kickstart-built host. Found by running the BYO path
end to end; every fix was proven by reverting the guest to its pristine copy
and running the whole path again.

- [x] **2b.1 `site.yml` wrote into a directory only the kickstart created.**
      (Opus, proven.) The pre_task now creates `/etc/nist-800-171`.

- [x] **2b.2 03.04.06 aborted the play on a host without the LVM volumes.**
      (Opus, now proven.) Stats each device, hardens what exists, records the
      rest.

- [x] **2b.3 `--check` could not complete on a never-applied host.** The
      systemd failure Opus recorded was one of four kinds: enabling a unit
      that check mode had not written or installed; `lineinfile` against a
      package-owned file check mode had not installed (`fapolicyd.conf`,
      `firewalld.conf`, `aide.conf`); `firewall-cmd` against a daemon that was
      neither installed nor running; and a `restart fapolicyd` handler notified
      by a task that reports a change in check mode. Verified locally first:
      `copy` and `template` into a missing directory merely report a change,
      so those needed nothing. The fix is one idiom, explained at the top of
      `tasks/main.yml`: the providing task is registered and the consumer
      carries `when: not (ansible_check_mode and (nist_x | default({})) is
      changed)`, so it is skipped only in check mode and only while the
      prerequisite is outstanding. On an applied host the tasks still run in
      check mode and a disabled timer is still reported as drift — the
      `--check` on the hardened host reports `changed=0`, not "skipped".
      Widening a check or `failed_when: false` was not used.

- [x] **2b.4 The role read the lab's `.secrets/` from inside two tasks**, so a
      real apply on any host without one died at 03.10.07 (`admin_password`
      as the GRUB superuser password) and would have died at 03.08.09 on a
      host with volume-group space (`luks_passphrase`). Neither the README's
      "make secrets is a prerequisite" note nor Opus's 2.1 note knew about the
      first. Both are now role variables: `NIST_GRUB_PASSWORD` /
      `NIST_LUKS_PASSPHRASE` from the environment, `.secrets/` only as the lab
      fallback, and an explicit warning plus a reported deviation when
      neither is present. A BYO host also should not get the lab admin
      password as its bootloader password.

- [x] **2b.5 Two checks failed for reasons that were the toolkit's, not the
      host's.**
      * `cm-01-baseline-manifest` asserted `/etc/nist-800-171/build-info`,
        which only the kickstart's `%post` writes, so no retrofit host could
        ever pass 03.04.01. The role now writes it, create-only, when absent —
        and the record says `kickstart=none (retrofit ...)` rather than
        claiming an install it did not do. The overlay's 03.04.01 text says
        the same.
      * `sc-10-host-key-strength` reported the stock image's ed25519 host key
        as `unapproved:` with an empty type: under the FIPS policy this
        baseline enforces, `ssh-keygen -l` refuses to read it and sshd cannot
        load it. A kickstart host never has one (sshd-keygen skips it under
        FIPS); a host that had FIPS turned on by the role keeps the key it
        generated before. 03.05.04 now removes it and masks its generator
        alongside dsa/ecdsa, and the check's evidence names the cause
        (`unreadable-under-crypto-policy:`) instead of an empty string.

- [x] **2b.6 Not idempotent on a host hardened from stock.** The second apply
      re-set `/etc/ssh/sshd_config.d` and `/etc/fapolicyd/rules.d` to
      `0755 root:root`: the drop-in pre-creation task imposed that mode before
      the owning package was installed or upgraded later in the same run, and
      the package (`0700`, and `root:fapolicyd`) reset it. The task now ensures
      existence only; a package-created directory keeps the package's choice.
      Invisible on the lab because the kickstart installs the packages first.
      A third apply and a `--check` on the applied host both report
      `changed=0`.

- [x] **2b.7 Three more flip-flops, found by rebooting and applying again.**
      The apply straight after a reboot changed five tasks; the next one
      changed none. Each was read from evidence taken after the boot and
      before the apply:
      * `03.06.02` set `/var/log/journal` to 2750; systemd's own tmpfiles
        entry resets it to 2755 at every boot. The task now matches the
        vendor mode - the per-machine directory below is 2750 by the same
        vendor rules and the journal files are 0640, so 2750 on the top
        directory hid only the machine-id name.
      * `03.14.08` chmod-ed `/var/log/firewalld` to 0600; firewalld reopens
        it as 0640 root:root on every start (`os.fchmod` in its logger). The
        rule is now "root and nobody else": 0600, or 0640 with group root.
        The old test, numeric mode greater than 600, also let a 0440 file
        owned by a service group through; it no longer does.
      * `03.01.01` rewrote `/usr/sbin/nologin` to `/sbin/nologin` for an
        account a package created later in the same run (clevis). The task
        accepts both spellings, as the check has since 1b.2.
      * Not defects: `03.16.02 support-status` records the running kernel and
        the first apply installs a newer one, so the apply after that reboot
        changes it once. With the new 03.14.08 rule, the apply after the
        first reboot also tightened `/var/log/fapolicyd-access.log` (0440,
        service group) once; fapolicyd does not reset it, and the apply
        after a further reboot changed nothing.

- [x] **2b.8 The first failed authentication on a hardened host broke sudo
      for good.** `03.01.08` keeps the faillock tally under `/var/log/faillock`
      so a lockout survives a reboot, but the targeted policy labels that path
      `var_log_t` and pam_faillock is confined to `faillog_t`. Nothing fails
      until an unsuccessful authentication creates a tally file there; from
      then on SELinux denies every read of it, pam_faillock fails in sshd and
      sudo alike, and sudo's stack fails before it asks for a password
      (`pam_unix(sudo:auth): conversation failed`). One mistyped sudo
      password on the retrofit host made sudo unusable, with root locked and
      no lockout to wait out - recovered by reverting the guest. The lab
      never saw it because no authentication ever failed there, which is
      exactly what Phase 3.2 exists to try. The role now installs a
      `faillog_t` file context for the directory and relabels it, and a new
      check, `ac-08-faillock-dir-context`, reads the effective label so the
      assessor would have reported it. Proven from scratch: after the fix a
      deliberately wrong sudo password is recorded and the next correct one
      is accepted.

---

---

## Phase 3 — rehearse the recovery procedures

Every procedure in `docs/RUNBOOK.md#when-you-are-locked-out` was standard
practice that had **not** been tested against this baseline. Rehearsed on
the retrofit guest `byo-rl9-01`, whose serial console is driven by a script
so each rehearsal is reproducible, and whose pristine and hardened disk
copies make a failed one cheap.

- [x] **3.1 Snapshot a guest.** `virsh snapshot-create-as` refuses a UEFI
      guest with raw NVRAM ("internal snapshots ... require QCOW2 nvram
      format"). Snapshots are file copies instead: shut down, copy the qcow2
      and the NVRAM file, start; revert is the reverse. The runbook says so
      now.
- [x] **3.2 Trigger a faillock lockout** (3 bad passwords) and recover with
      `faillock --user <name> --reset` from the console. *Rehearsed.* Three
      bad SSH passwords lock the account; the correct password is then
      refused over SSH **and at the console**, because the console login
      runs the same PAM stack. With root locked (03.01.06) and one admin
      account, the runbook's "reset from the console" is impossible during
      the lockout: nobody can log in to run it. What worked was the
      alternative it also listed - the lock expired 15 minutes after the
      last failure (`unlock_time`), SSH came back, and only then could the
      tally be listed and reset from the console. The runbook now leads
      with the wait, and recommends a second, key-only administrative
      account as the break-glass path for a single-admin host.
      *Found on the way (2b.8):* before the SELinux fix, the first bad
      password did not lock anything - it broke sudo permanently.
- [x] **3.3 Back MFA out from the console** and confirm you can log in with a
      key alone, then re-apply to restore it. *Rehearsed, runbook command
      verbatim.* `sshd -T` showed `authenticationmethods publickey`, a
      key-only login succeeded, `./verify.sh --requirement 03.05.03` reported
      `ia-03-sshd-authmethods` failing, `./apply.sh --tags 03.05.03` restored
      it (`changed=2`) and key-only login was refused again. Nothing to
      correct.
- [x] **3.4 Lock yourself out with the firewall** and recover via
      `firewall-cmd --add-source`. *Rehearsed, runbook command verbatim, and
      it found a gap.* Removing ssh from the public zone locked new
      connections out (existing SSH sessions survive, which is why the
      earlier scripted run could still reach the host). The console
      `--add-source=<cidr> --zone=trusted` restored access at once. But that
      source exempts the address from the firewall entirely, it survived
      `./apply.sh --tags 03.13` (`changed=0`), and `./verify.sh --family
      03.13` reported nothing - the runbook's "verify.sh will report it" was
      false for this case. Fixed both ways: 03.13.06 now removes any source
      or interface from the trusted zone on apply, and the new check
      `sc-06-no-trusted-bypass` (334 checks) reports one that remains.
      Proven on the host: a planted permanent trusted source is flagged, the
      tagged re-apply removes it, and the check passes.
- [x] **3.5 Correct anything the runbook got wrong.** *Done.* The faillock
      row led with a console reset that cannot be run during the lockout it
      describes; it now leads with the wait and recommends a second admin
      account. The firewall row now says what the trusted zone does and how
      to undo it. Two things no row mentioned: the serial console is buried
      by `LogDenied=all` within seconds (`sudo dmesg -n 1` first), and
      `virsh snapshot-create-as` refuses UEFI guests with raw NVRAM (copy the
      disk and NVRAM instead).
- [x] **3.6 Update the runbook header.** *Done:* it now says every recovery
      procedure was rehearsed on a retrofit guest, and where the rehearsal
      changed the advice, the step says what happened.

---

---

## Phase 4 — decisions only the system owner can make

No amount of testing substitutes for these. Each is a live commitment.

- [x] **4.1 Review every ODP** in `catalog/overlay-rocky9.yml`. *Done
      2026-09-18: all 25 recommendations in `rl9-171/docs/ODP-REVIEW.md`
      accepted by the owner and applied.* The register now holds 32 machine
      and 62 organizational ODPs against all 80 decision points in the 97
      statements. What changed on the hosts: one idle value (900 s) for
      console and SSH alike; password minimum length 15 (STIG); audit
      retention measured in days (auditd keep_logs, the daily review prunes
      by age, logrotate no longer touches the audit log); the five
      continuous-monitoring schedules are machine ODPs the assessor reads
      back from the timers (five new checks); the two faillock checks assert
      what the ODPs mean. What changed on paper: every register entry that
      contradicted or understated the host now states what the host does,
      a precedence rule for STIG versus CIS versus this overlay, the medium
      patch tier restored, 15 previously unrecorded assignments and both
      nested selections recorded, and the usbguard error corrected.
      *Why:* they are defaults drawn from common DoD CUI practice, not your
      organization's values. `make validate` confirms nothing references a
      parameter that does not exist — it cannot tell you a number is wrong.
      An assessor will ask where each came from.

- [x] **4.1b ODP audit results — 26 of 76 carry a finding, 18 assignments are
      unanswered.** A full audit mapped all 76 ODPs onto the 82
      organization-defined decision points in the 97 active statements.
      Spot-verified: every claim below was confirmed directly.

      *Closed 2026-09-22.* Every finding below was resolved when the owner
      accepted `docs/ODP-REVIEW.md` on 2026-09-18 and it was applied to the
      overlay, the checks and the tasks in the same change. The review's
      sections answer this list one for one: A1/A2 the two contradictions,
      B1–B3 the three understated frequencies, C the baseline precedence and
      `password_min_length` (now 15, the STIG value), D the unrecorded
      assignments (15 added, plus both nested `[Selection:]` choices), E1/E2
      the two assertion-semantics defects, F1 the `usbguard` error, G the
      already-decided items including the removal of `patch_window_days`.
      Verified in the current overlay: `patch_window_days` and `usbguard`
      appear nowhere, `password_min_length: 15`, and the register is 32
      machine + 62 organizational ODPs with `make validate` passing. The
      list below is kept as the audit that drove the review.

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

      *Contractual — decided 2026-09-17:*
      * `ir_authorities` names CISA. The intended population is non-DoD CUI,
        so DFARS 252.204-7012 (DoD via DIBNet within 72 hours) does not
        apply; the ODP's rationale now says so, so a DoD contractor adopting
        the overlay knows it is the value to change.

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

- [x] **4.1c Add the two validator guards that would have caught most of
      this.** *Done.* Both are in `tools/validate.py` and both red-lit it
      until their defects were fixed in the same change:
      * every key in `odp:` must be referenced by at least one check.
        `patch_window_days` was the only offender and is gone: the dnf timer
        is daily whatever the value, so the window is policy, which
        `odp_organizational.patch_sla` already records; the two comments that
        cited the dead value now cite that one. 28 machine ODPs remain.
      * no `technical` entry may carry a `residual`. All six in 4.4 were
        re-dispositioned, so the guard passes.
      Longer term: give each ODP an `answers:` field naming the requirement
      *and statement letter* (`03.14.01b`), then assert every assignment is
      answered exactly once.

- [x] **4.2 Decide the ClamAV / EPEL trade-off (03.14.02 vs 03.17.03).**
      *Decided 2026-09-17: ClamAV stays off.* A third-party repository on a
      CUI host is a larger supply-chain exposure (03.17.03) than the
      signature-scanning gap it would close, and the gap is recorded rather
      than hidden: 03.14.02 is partial with EPEL named in its residual, and
      `malicious-code.conf` on the host says signature scanning is not
      installed. Reversible per host with `nist_clamav_enabled` and
      `nist_enable_epel`, which then needs its own 03.17.03 justification.

- [x] **4.3 Profile fapolicyd against a real workload.** *Decided
      2026-09-17: the shipped default stays enforcing.* A baseline that ships
      permissive would report 03.04.08 as satisfied on the strength of a log
      file. Profiling is per workload, not per toolkit: the runbook's "Other
      things that will bite you" already gives the sequence (permissive,
      collect, write rules into `/etc/fapolicyd/rules.d/`, re-enforce). On
      the BYO guest, enforcing mode has blocked nothing the toolkit itself
      runs across four applies, three reboots and the assessments.

- [x] **4.4 Six requirements report PASS while conceding they are not fully
      satisfied.** *Resolved: all six, plus 03.08.02, are `partial`.* The
      overlay now reads 37 technical, 32 partial, 28 organizational. Each
      residual names the statements the host does not cover, checked against
      the publication text, and the three false host_scope claims below are
      struck. Nothing on any host changed; what changed is that the tool no
      longer claims seven PASSes it could not back, so every assessment
      number quoted before this point is seven satisfied fewer and seven
      partial more. The record of the analysis follows.

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

- [x] **4.4b Make `validate.py` reject `residual` on a `technical` entry.**
      *Done with 4.1c.*

- [x] **4.5 Decide what happens to `nist_sp_800_171r3/web/`.** *Deleted
      2026-09-17.* The tool hardens hosts, not web tiers; the snippet implied
      coverage the roles and the assessor do not have. It remains in git
      history.

---

---

## Phase 5 — cleanup and housekeeping

- [x] **5.1 Rotate `.secrets/`.** *Done 2026-09-18, and it doubled as the
      kickstart-path proof of everything since Phase 2.* On the lab
      workstation: the three guests destroyed, `.secrets/` rotated, the CUI
      host and the collector rebuilt from the kickstart (21 and 20 minutes),
      `make pki`, apply, reboot, apply again. With the final overlay:
      `rl9-cui-01` **36 / 33 / 0 / 28**, `rl9-log-01` **35 / 34 / 0 / 28**,
      334 checks, 0 failed on both, TLS forwarding passing on both sides,
      `--check` at `changed=0` on both. The collector's extra partial is
      03.13.08: it forwards nowhere, so `sc-08-forward-encrypted` is MANUAL
      there - the single-node case, reported as such. The rebuild also caught
      a broken `make pki` recipe, and the forwarder did exactly what it
      should without certificates: recorded the gap and failed both
      forwarding checks rather than sending in the clear.

- [x] **5.2 Delete the `r3-hardening-middleware` branch.** Already gone: no
      such branch exists locally or on the remote (checked 2026-09-18, after
      the history rewrite that put the owner's GitHub identity on every
      commit).

- [x] **5.3 `archive/` removed.** The reconciliation had served its purpose:
      `r3/`, `os/` and `stig/` are gone, along with `tools/legacy-gap.py` and
      `docs/legacy-gap.md`, which existed only to document them. 618 MB
      reclaimed, almost all of it the gitignored `r3/lab/.state/` qcow2.
      Everything remains in git history. *Done.*

- [x] **5.4 Local build cruft pruned** with 5.3 — the cached cloud image and
      `__pycache__` directories went with the archive. *Done.*

---

---

## Phase 6b — defects found after Phase 5 closed

- [x] **6b.1 A check satisfied by absence passed when its command failed.**
      *Fixed in PR #2 (`8ebaeb3`), written by a cloud session; reviewed and
      proven against the BYO pair on 2026-09-25.* `nist-assess` ignored the
      exit status for every assertion except `expect_rc`, so `expect_empty`
      and `expect_no_match` read a command that could not run as a clean
      result: `sshd -T` refusing a broken config showed no weak ciphers,
      `dnf` unable to reach its repositories listed no advisories, and a
      stopped firewalld exposed no services. Several checks made it worse by
      ending in `grep -v ... || true`, which swallowed the inspected tool's
      status even under `pipefail`. Run against an unhardened non-EL9
      container, the old assessor reported 84 checks and three technical
      requirements PASS. That is the overstatement this project exists to
      prevent, in the assessor itself rather than in the overlay.
      The fix: an absence PASS also needs an exit status the check declares
      normal (`ok_rc`, default `[0]`, declared on the 17 checks whose clean
      result is non-zero); a missing tool (126/127, or "command not found"
      folded into stdout) is ERROR whatever its output; the `|| true`
      filters are `awk`; checks run under `LC_ALL=C` and a fixed PATH; and
      the assessor refuses to run unprivileged or off RHEL 9 unless
      `--allow-unsupported`, which marks the report and exits non-zero.
      `validate.py` now compiles every regex and parses every `expect_int`
      after ODP expansion, rejects unknown check keys, and counts a machine
      ODP as asserted only from the command or assertion of a referenced
      check. `make test` holds 41 unit tests for both.
      *Proven on hosts, which the cloud session could not do:* the risk ran
      the other way, false ERRORs on a hardened host from an absence check
      that exits non-zero when clean and lacked `ok_rc`. A static audit found
      no such check among the other 56 (`find` exits 0 on no match, `A ||
      echo X` is 0 either way, `cm-02` ends in `exit 0`). Then main's
      assessor and the PR's were run back to back against the same state of
      `byo-rl9-01` and `byo-log-01`: **0 of 334 checks and 0 of 97
      requirements differ, 0 ERROR.** Unprivileged on the Ubuntu control
      workstation it refuses with both reasons before running a check.
      *Behaviour change to expect:* `si-01-no-pending-security-updates`
      now has `ok_rc: [0]`, so a host that cannot reach its repositories
      reports ERROR daily rather than a clean zero. That is the correct
      answer, and the RUNBOOK says not to widen `ok_rc` to silence it.

*Moved from TASKS.md on 2026-09-26, when every item below had been proven on
both labs - the BYO pair and the kickstart lab built on the laptop - and the
two rehearsals it needed (GRUB edit, PCR 7 recovery) had passed. Found by the
cloud review of 2026-09-25 (6b.2-6b.6), by cycling the labs (6b.7-6b.10),
and by the first release runs (6b.11-6b.14), which the release run at
`8c332c5` then proved fixed.*

- [x] **6b.2 03.10.07: no GRUB password is ever set, and the check passes.**
      *Fixed 2026-09-25, check first.* `pe-07-grub-password` now reads what
      GRUB boots — a real `grub.pbkdf2.` hash inline in `/boot/grub2/grub.cfg`,
      or `user.cfg` holding one while `grub.cfg` sources it — and the new
      `pe-07-grub-no-staged-secret` fails on a cleartext copy. Both FAILED on
      the hardened `byo-rl9-02` before the role changed. The role now writes
      `GRUB2_PASSWORD=` to `/boot/grub2/user.cfg` as `grub2-setpassword` does,
      the password passed on stdin and never on disk; an existing hash is kept
      only if it verifies (PBKDF2-SHA512 from its own salt, which works under
      FIPS), so a changed `NIST_GRUB_PASSWORD` takes effect; the staged file
      is removed. The `10_linux` edit, the `/etc/default/grub` edits (which
      had never run) and the `update grub config` handler are gone: the
      probe shows all four BLS entries already `--unrestricted` and `grub.cfg`
      already sourcing `user.cfg`. *Proven on `byo-rl9-02`:* apply
      `changed=2` then `changed=0`; both checks PASS; a reboot counted down
      and booted by itself in 29 s (serial log). *Proven by behaviour
      2026-09-26* with `tools/rehearse-grub-edit.py`: the console catches the
      one-second menu and presses `e` — GRUB asks for a username; a wrong
      password gets "access denied"; root and the right one open the editor
      (the real `linux ($root)/vmlinuz-…` line); Escape, and the default
      entry boots unattended to a login prompt.
      *The finding as recorded:*
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

- [x] **6b.3 03.01.11 / 03.13.09: the SSH idle setting asserted does nothing.**
      *Closed 2026-09-25:* the owner accepted CountMax **1** (ODP-REVIEW A2a).
      The countmax checks assert `==` and FAILED on 0 first; applied,
      03.01.11 and 03.13.09 PASS with 0 failed.
      *Idle termination fixed 2026-09-25, check first; the CountMax value
      waits on the owner.* **The first fix did not work, and only the
      behaviour test showed it:** with `ChannelTimeout session=900s` set and
      `sshd -T` agreeing, `tools/ssh-idle-test.sh` held an idle session open
      for its full 1,200 s. The suspected cause — ClientAlive probes, which
      sshd sends *on* the open session channel (serverloop.c) — was refuted
      by the source: they do not touch the channel's idle clock
      (`lastused`, reset only by stream reads/writes in channels.c). The
      real cause: when a session starts a shell, a command or sftp, sshd
      relabels its channel `session:shell` / `session:command` /
      `session:subsystem:*` and looks the timeout up again under that name
      with `match_pattern` (`channel_set_xtype`), so a bare `session` never
      applies to a running session — the installed man page's description
      of `session` notwithstanding. The fix is `session*`. New
      `ac-11-ssh-channel-timeout` and
      `sc-09-unused-connection-timeout` read `sshd -T`, are referenced by
      both requirements, and FAILED on `byo-rl9-02` (`none`) — 03.01.11, a
      `technical` requirement, had been reporting a plain PASS. The role sets
      `ChannelTimeout session*=` and `UnusedConnectionTimeout` from the
      accepted `session_timeout_seconds` (900 s), gated on OpenSSH >= 9.2
      with a warning and a recorded gap below it; `session` is the only
      channel type a user can open, since every forwarding is disabled. The
      sshd template now also carries the 03.01.11 tag (`--tags 03.01.11`
      never deployed it — 1b.7 again), `ma.yml`'s posture record names the
      real mechanism, and both `host_scope` texts, which claimed
      ClientAlive 0 "terminates idle network sessions", are corrected.
      *Proven on `byo-rl9-02`:* `sshd -T` shows `channeltimeout
      session*=900s`, `unusedconnectiontimeout 900`; 03.01.11 and 03.13.09
      PASS with 0 checks failed; and by behaviour — `tools/ssh-idle-test.sh`,
      a session running a silent `sleep 1200`, closed by sshd at **900 s**
      (with bare `session`: never).
      *Owner decision, since taken —* `ssh_client_alive_count_max`. 0 disables
      ClientAlive termination, so dead peers are never reaped. Proposed: **1**,
      the RHEL 9 STIG value (ODP-REVIEW's precedence puts STIG first): a
      silent peer is dropped one interval after the first unanswered probe.
      The two countmax checks then assert `== {odp}` rather than `<=`, which
      today passes the 0 that disables it. Accept, or name another value.
      *The finding as recorded:*
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

- [x] **6b.4 03.01.01 / 03.05.12: account aging does nothing on a host with
      more than one user.** *Fixed 2026-09-25.* The checks already failed on
      it (shown by `byo-rl9-02`'s first cycle), so the fix is the role's:
      both loops quote each name separately (`map('quote') | join(' ')`),
      and a failing `chage` fails the task naming the account instead of
      vanishing into `&& changed=1`. Found alongside, the 1b.7 failure again:
      the account list was computed only under 03.01.01 / 03.01.05, so
      `--tags 03.05.12` looped over `default([])` — nothing — and reported
      success; the list task now carries 03.05.12 and the default is gone.
      *Proven on `byo-rl9-02`:* `--tags 03.05.12` alone and `--tags
      03.01.01` alone each `changed=1`, together again `changed=0`; the probe
      shows `byoadmin` and `cuiuser1` both at min=1 max=60 warn=7
      inactive=35; 03.01.01 and 03.05.12 from FAIL to PART, 0 checks failed.
      *The finding as recorded:* `ac.yml:36` (inactivity lock) and `ia.yml:368`
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

- [x] **6b.5 03.08.09 / 03.13.08: the LUKS key sits beside the data it
      unlocks.** *Fixed 2026-09-25, owner's choice: bind to the TPM.* Check
      first: `mp-09-luks-tpm-bound` (every LUKS volume has a clevis tpm2
      binding) and `mp-09-luks-no-key-on-disk` (crypttab names no key file,
      `/root/.luks-key` absent), referenced by 03.08.09 and 03.13.08; both
      FAILED on `byo-rl9-02`, taking 03.08.09 from a false PASS to FAIL.
      *Root cause of the silent bind:* the role ran `clevis luks bind -d DEV
      tpm2 CFG -k KEY -y`; clevis parses options with getopts, which stops at
      the first positional, so `-k` and `-y` were never read, clevis
      prompted for the passphrase, failed without a terminal, and
      `failed_when: false` reported `ok`. Reproduced on a throwaway loop
      image (`tools/probes/clevis-bind-experiment.sh`): the role's order
      rc=1, options first rc=0, and `clevis luks unlock` with the TPM alone
      opens it, under FIPS. *The role now* reads each volume's state,
      stages the key only while a volume needs it, binds with options first
      (a failure fails the task), and once both are bound sets crypttab to
      `none`, enables `clevis-luks-askpass.path` and deletes the key; the
      passphrase slot remains the recovery key. Without a TPM the key stays
      (the host must boot), a warning says so, and both checks FAIL.
      A latent idempotence bug went with it: `'bound' in stdout` also
      matched `already-bound`. *Proven on `byo-rl9-02`:* migrated in place
      (bound, crypttab `none`, key removed; re-apply `changed=0`), then a
      reboot unlocked and mounted both volumes from the TPM alone in 41 s
      (`clevis-luks-askpass` → `systemd-cryptsetup@cui_*`); 03.13.08 PASS,
      03.08.09 / 03.01.18 / 03.08.03 PART, 0 checks failed.
      *Recovery rehearsed 2026-09-26* (`tools/rehearse-pcr7-recovery.py`):
      Secure Boot off changed PCR 7; the boot waited for the passphrase; then
      `verify.sh` reported the stale binding, `apply.sh --tags 03.08.09`
      resealed, verify passed and the next boot unlocked alone. That meant
      two more changes first: a binding the TPM refuses is not "bound" — the
      check now asks the TPM (`clevis luks pass`) and the role reseals a
      stale one with `clevis luks regen` (mechanics proven on a PCR 16 loop
      image, `tools/probes/clevis-stale-experiment.sh`). The rehearsal also
      disproved two of my own assumptions: PCR 7 does not differ between the
      first and later boots (event logs identical), and a passphrase prompt
      at boot is shown even when the TPM answers it.
      *Correction (2026-09-26):* an earlier note here said the kickstart lab
      has no TPM. It has had one since the first commit (`vm/build-vm.sh`,
      `--tpm ... model=tpm-crb`, `9009b90`) — so every kickstart host had a
      TPM and the silent bind is the only reason none was ever sealed.
      *Proven 2026-09-26:* the kickstart lab, built on the laptop, seals both
      volumes to the TPM and passes 03.08.09 / 03.13.08 with 0 checks failed.
      *The finding as recorded:* `mp.yml` stages `/root/.luks-key` and `crypttab` points at
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

- [x] **6b.6 03.03.05c: audit records are never forwarded, and three checks
      pass.** *Fixed 2026-09-25, check first.* `au-05-collector-receiving`
      now requires an auditd record (`type=… msg=audit(`) from another host,
      and the new `au-05-audit-trail-forwarded` requires auditd's syslog
      plugin running on the forwarder; both FAILED before the role changed
      (336 checks). *The route:* rsyslog `imfile` on `audit.log` was tried
      first, to avoid rate limits, and refused — SELinux denies `syslogd_t`
      on `auditd_log_t` under a `dontaudit` rule (rsyslog logs "Permission
      denied", no AVC is recorded), and a policy module widening the
      logger's access to the trail is the wrong trade. So auditd's syslog
      plugin (`audispd-plugins`, `args = LOG_LOCAL6`), with the two rate
      limits on that path lifted — journald's for `auditd.service` only
      (`LogRateLimitIntervalSec=0`), imjournal's in `rsyslog.conf` — and the
      records forwarded once and stopped, so they are not copied into
      `/var/log/messages`. The records' identifier is `audispd` on local6;
      matching `audisp-syslog` (the plugin's status messages) first let
      6,561 through to the local file before the probe caught it.
      *Proven on `byo-rl9-02` → `byo-log-01`:* 0 auditd records at the
      collector all week, then 187 within a minute; over a 60 s window with
      generated events the collector grew 6,972 → 7,454 while local copies
      stayed flat; both checks PASS. 6.2a is unblocked.
      *The finding as recorded:* Nothing routes auditd into rsyslog: no
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

- [x] **6b.9 The collector restarted rsyslog on every run once it had two
      forwarders.** *Found 2026-09-26 cycling `byo-log-01`* (dry run after
      settling: `changed=2`). `nist_col_peers` was `cui_hosts | difference(
      [inventory_hostname])`, and `difference` keeps no order: the
      PermittedPeer list came out either way round, the template changed and
      the handler restarted the collector — invisible with one forwarder.
      *Fix:* `| sort`. *Proven:* apply `changed=3` (rewritten sorted, one
      restart), then `changed=0`.

- [x] **6b.10 apply.sh said "Reboot required: False" on a host that owed
      one.** *Found 2026-09-26 cycling `byo-rl9-01`:* dnf-automatic had
      installed kernel 687.50.1 while 687.48.1 ran, `sa-02-kernel-current`
      failed and `si-01` counted 8 advisories that apply to the running
      kernel — and the cycle did not reboot, because the handlers only flag
      reboots the role itself causes. (`needs-restarting -r` alone is not the
      test either: it compares install time with boot time, and missed it
      after an unrelated restart.) *Fix:* `site.yml`'s closing tasks ask the
      host — the running kernel against the newest installed, as `sa-02`
      does, and `needs-restarting -r` for libraries and services — and the
      report gives the reason. *Proven:* `tools/stage-pending-kernel.sh`
      boots the older kernel of `byo-rl9-02` with the newest as default, as
      dnf leaves it; apply then reports "Reboot required: True (kernel
      5.14.0-687.50.1 is installed, 5.14.0-687.10.1 is running)", the cycle
      reboots on it, and the host ends at 35/33/1/28 with `sa-02` and `si-01`
      passing, then `changed=0`.

*Found by the first release run (TASKS R3), 2026-09-26, which starts every
host from a clean state — something no cycle before it had done for the
collector or for the retrofit reference.*

- [x] **6b.11 The dry run failed on a collector that had never been applied.**
      `./apply.sh --check` on the freshly built `byo-log-01` stopped at the
      collector role's `ansible.posix.firewalld` task: "Failed to import the
      required Python library (firewall)". firewalld and its python library
      come from the overlay's 03.13.01 install in the play before, which
      check mode does not perform. "The dry run completes on a host never
      applied" had been proven on CUI hosts only; the old `byo-log-01` had
      been applied long before the claim was made, and a kickstart collector
      ships with firewalld. *Fix:* the task carries the overlay's check-mode
      guard (`not (ansible_check_mode and nist_firewalld_pkg is changed)`).
      *Proven* by the release run at `8c332c5`: the dry run on the
      never-applied, freshly rebuilt `byo-log-01` completed with `failed=0`.

- [x] **6b.12 `byo-rl9-01`'s `fresh` snapshot could not be logged into.** The
      release run reverted it and sudo refused the become password: the
      snapshot was taken by hand on 2026-09-17 and `byoadmin`'s password was
      rotated on the 18th. Nothing had reverted to it since, so nothing
      noticed. A state only a hand build produced is the doctrine's failure
      case. *Fix:* the guest is destroyed and rebuilt by `vm/byo-guest.sh`
      like the others, and `tools/release-run.sh byo --rebuild` rebuilds every
      BYO guest from the stock image, so the release proof depends on no
      older build. *Proven:* `release-run.sh byo --rebuild` at `8c332c5` rebuilt all three
      guests from the stock image and cycled each to a pass.

- [x] **6b.13 Every BYO guest had a TPM, asked for or not.** `byo-guest.sh`
      passed `--tpm` only with `--tpm`, but virt-install 5.1 gives any UEFI
      guest an emulated TPM unless told `--tpm none` (virtinst `guest.py`,
      `_add_default_tpm`); the rebuilt `byo-log-01` came up with one. Harmless
      there, but `byo-rl9-01` is the no-TPM retrofit reference, and rebuilt
      this way it would have silently stopped being one. *Fix:* `--tpm none`
      unless `--tpm` is given. *Proven:* `byo-guest.sh check` on the rebuilt
      `byo-rl9-01` and `byo-log-01` reads `tpm none`; `byo-rl9-02`, built with
      `--tpm`, has one and seals its LUKS keys to it.

- [x] **6b.14 `byo-guest.sh build` exited 1 after every successful build.**
      `cmd_check` removes its temporary probe with `trap ... RETURN`, and a
      RETURN trap outlives the function that sets it: it fired again when
      `cmd_build` returned, where `$probe` is undefined, and `set -u` ended
      the script — after the guest, its inventory entry, its certificate and
      its `fresh` snapshot were all in place. It went unseen because the
      builds before the release run were read from their output, not their
      status; `release-run.sh` reads the status, and stopped. *Fix:* the trap
      clears itself (`trap - RETURN`). *Proven:* all three rebuilds in the release run
      at `8c332c5` exited 0.

---

## Phase 6 — closed items

*Moved from TASKS.md on 2026-09-26.*

- [x] **6.2a Prove TLS forwarding to a receiver that is not our own rsyslog.**
      *Proven 2026-09-26* with `tools/prove-foreign-receiver.sh` on
      `byo-rl9-02` and `byo-rl9-01`. The receiver is syslog-ng 4.12.0 in a
      rootful podman container (`vm/siem-container.sh`, image pinned by
      digest) at `192.168.171.50:6514` on a macvlan child of `virbr17`,
      requiring a client certificate from the lab CA, with its own
      certificate for `siem.nist-lab` — a name no inventory host has. The
      host is pointed at it for the run only, by extra vars; the inventory is
      never touched and the host is pointed back at its own collector at the
      end. On each host: `au-05-forward-established`,
      `au-05-audit-trail-forwarded` and `sc-08-forward-encrypted` PASS (read
      from the report JSON, so a check that did not run cannot pass); the
      receiver gained over 11,000 auditd records per run and a `type=SYSCALL`
      record is legible there; a client with no certificate is refused
      ("peer did not return a certificate"); and when the host is told to
      expect `not-the-siem.nist-lab`, nothing reaches the receiver — rsyslog:
      "peer name not authorized, not permitted to talk to name:
      /CN=siem.nist-lab".
      *A false alarm on the way, recorded because it will recur:* the first
      negative test counted 6,148 records "sent to the wrong peer". The
      baseline had been taken before the apply, and until the handler
      restarts rsyslog the old session keeps forwarding — including the
      apply's own audit records. `tools/probes/permitted-peers-experiment.sh`
      settled it away from the live forwarding (a throwaway rsyslogd per
      case, a marker each): the right name and `*.nist-lab` delivered, the
      wrong name delivered nothing. A test of a forwarding change must take
      its baseline after rsyslog restarts.
      *What it does not prove:* a certificate we did not mint, or a SIEM's
      parser — that is 6.2b.

- [x] **6.6 Both generators destroyed authored content.** *Fixed and proven
      2026-09-26.* Worse than first recorded: the role ran `nist-generate-ssp`
      on **every apply**, rewriting the whole file, so any authored section was
      lost at the next apply; and `nist-generate-poam` wrote a fresh dated CSV
      each run, so the owner's columns never carried forward and a resolved
      item simply vanished. Its check, `ca-02-poam-output`, only tested that
      the report directory existed and could not fail.
      *Now:* the owner's SSP sections live in `/etc/nist-800-171/ssp.d/` (or
      come from `NIST_SSP_DIR` on the workstation) and are spliced in on every
      regeneration, with a table of which are written. The POA&M is a
      register, `/etc/nist-800-171/poam.csv`, merged by `nist_poam.py`
      (stdlib, 15 unit tests): owner columns carried forward, resolved
      deviations closed with their date and kept, residuals closed by the
      owner, an assessment older than 24 h refused. Both plans regenerate after
      every scheduled assessment (`ExecStartPost`, with `SuccessExitStatus=1`
      because nist-assess exits 1 on deviations). `ca-02-poam-register`
      replaces the directory check: every failing requirement must be tracked;
      it FAILED on a host with no register before the change.
      *Proven* with `tools/rehearse-authored-plans.sh` on `byo-rl9-01`:
      authored sections and an owner's entry survived the scheduled
      assessment service and a second apply; the rehearsal text was removed.
      fapolicyd (enforcing) runs the module as root without a denial.

- [x] **6.7 The POA&M omitted the obligations that are not FAILs.** *Resolved
      2026-09-26 with 6.6.* Not a decision after all: the overlay's 03.12.02
      host_scope already promised "every failed or partially implemented
      requirement", and the generator emitted only FAILs. Every partial
      requirement is now a `residual` item carrying the overlay's residual
      text (`byo-rl9-01`: 5 deviations, 32 residuals). The 28 purely
      organizational requirements are not items — they have no host part — and
      the SSP's section 8 names `organizational-requirements.md` as their
      register.

- [x] **5.5 `vm/nist-lab-network.xml` claims a ufw rule this host lacks.** The
      comment says the host's ufw policy "already permits nist-lab qemu
      guests". On this laptop `ufw status` shows rules for `virbr0` and
      `virbr-k8s` and none for `virbr17`, with default incoming deny. Guest to
      guest traffic crosses the bridge and never the host INPUT chain, so the
      lab works and nothing is broken — but the comment describes the other
      workstation, and it will mislead whoever first tries to make the host
      itself a receiver. Correct the comment, or add the rule it describes.
      *Fixed 2026-09-26:* the comment now says what is true on both
      workstations — no host rule is needed for the lab, only for making the
      workstation itself a receiver.

- [x] **5.6 Make every open defect testable on the laptop lab.** *Done
      2026-09-26:* the laptop runs both labs — the BYO guests (`vm/byo-guest.sh`,
      including `byo-rl9-02` with a volume group, a TPM and two accounts) and
      the kickstart lab (`make vm`, `make vm-log`), each in its own inventory
      (docs/LAB.md, *Two labs on one workstation*). Every 6b defect was
      reproduced and its fix proven here, and 6.2a's syslog-ng receiver runs here.

---

## Phase 7 — the review after 1.0.0 (release 1.0.1)

*A cloud review on 2026-09-26 filed GitHub issues #3-#15 and pushed fixes for
#3-#7 to a branch. Verified against `main` on 2026-10-01 (TASKS.md, *Release
1.0.1*): most findings hold. Each item below cites its issue; the branch was a
source, and nothing from it is taken without its own proof here.*

- [x] **7.1 A failed TPM bind reported success, then the key was deleted
      (#3).** The bind script had `set -o pipefail` and no `set -e`: a failed
      `clevis luks bind` fell through to `echo "bound"`, the task succeeded,
      `nist_luks_tpm_ok` went true, the staged key was removed and crypttab
      set to `none`, and the next boot waited at the console with no SSH. The
      6b.5 comment above it — "a failed bind now fails the task" — was not
      true. *Shown on a host first:* `tools/probes/bind-script-experiment.sh`
      on `byo-rl9-02`, a loop device bound with the wrong key: main's script
      exits 0 and prints `bound`; with `set -euo pipefail` and the TPM asked
      for the key before the result is trusted (the branch's version), it
      exits 1. The same probe shows the fix binds a volume never bound
      (`clevis luks list` exits 0 there, so `set -e` does not break first
      binds) and re-runs as `already-bound`.

- [x] **7.2 The volumes could be sealed with Secure Boot off (#4).** PCR 7
      measures the Secure Boot policy; with it off the measurement is the
      same for any boot medium, so a seal made then opens for a live image on
      the same machine. The RUNBOOK's recovery resealed in exactly that
      state, and the PCR 7 rehearsal called it a pass. *Owner decision*
      (ODP-REVIEW I1): refuse, and keep going. *Check first:*
      `mp-09-luks-tpm-bound` now examines LUKS on partitions and disks as
      well as logical volumes, requires PCR 7 in the sha256 bank, and fails
      a host with no LUKS device — on `byo-rl9-01` it went from a vacuous
      PASS to "no LUKS device found", while `byo-rl9-02` still passes; new
      `mp-09-secure-boot` reads the SecureBoot EFI variable (03.08.09,
      03.13.08). *Fix:* the role reads the Secure Boot state; with it off a
      TPM host is treated as one without a TPM — nothing bound or resealed,
      the key on disk so it boots, a warning, the play carries on (the
      branch's version stopped the play). *Proven* by
      `tools/rehearse-pcr7-recovery.py byo-rl9-02`, all eight steps: the
      boot with Secure Boot off waits for the passphrase; verify reports the
      stale binding and Secure Boot off; apply completes without resealing
      and puts the key back; with the hardened variable store restored the
      host boots by itself; the re-apply finds the original seal valid and
      removes the key; the next boot unlocks from the TPM alone. The TPM
      event logs show why the original seal holds: with Secure Boot back on,
      PCR 7 returns to the value it was sealed to (identical across the last
      two boots).

- [x] **7.3 03.01.11 passed on settings that end nothing (#9).** Three
      checks asserted `ClientAliveInterval <= ODP`, which 0 — ClientAlive
      off — passes; three read `TMOUT` as the smallest value in any profile
      file, so a stray `TMOUT=0` passed, and none read the effective value;
      and a terminal session printing output with nobody typing was never
      ended, while the overlay said sshd ended a session "whatever runs in
      it" — ChannelTimeout counts output as activity. *Check first:*
      `tests/test_assessor.py` (`RealChecks`) runs the shipped checks with
      only the host read replaced: all six failed on the defect values
      before the change. The interval checks now assert equality, the
      `TMOUT` checks read a login shell (`env -i bash --login`), 0 or unset
      failing as absent, and `ac-10-tmout-readonly` reads `readonly -p`. New
      `ac-11-logind-idle-session` reads logind's `StopIdleSessionUSec` over
      D-Bus; it failed on `byo-rl9-01` ("infinity"). *Fix:* the role sets
      `StopIdleSessionSec` to the ODP (the RHEL 9 STIG's control); logind
      judges a terminal session by its last input. The two tasks that can
      run longer than the limit in one silent session — the security
      updates and the first `aide --init` — are polled (`async`), since
      either timeout would end them (#9's second point). *Proven by
      behaviour* with `tools/ssh-idle-test.sh byo-rl9-01`: a terminal
      session printing every 10 s with no input was ended by logind at
      **901 s**, and a silent session by sshd at **900 s**. The async
      security-update task ran, polled, and settled at `changed=0` on
      `byo-rl9-02`.

- [x] **7.4 Aging would lock the automation account out (#12).** Every
      interactive account got a 60-day maximum and a 35-day inactivity lock,
      the automation account included — and it signs in with key **and**
      password (03.05.03), so on day 60 the run that hardens the host could
      no longer sign in. *Owner decision* (ODP-REVIEW I2): exempt it, rotate
      by hand. Also: `ac-01-inactive-users` accepted any non-empty
      inactivity period, 99999 included; `ia-12-no-never-expire` resolved
      users with `id -u`, whose failure read as uid 0, so an account it
      could not resolve was never reported; the last-change loop swallowed a
      failing `chage`; and `--skip-tags 03.01.01` removed the account list
      from under `ia.yml`. *Check first:* `AgingChecks` in
      `tests/test_assessor.py`, against a fake passwd and shadow, failed on
      99999 and on an undeclared exemption before the change. *Fix:* the
      role declares the exempt accounts (default `ansible_user`) in
      `/etc/nist-800-171/aging-exempt`, lifts their maximum age and
      inactivity lock and keeps their minimum age and warning; the checks
      skip exactly the declared names; new `ia-12-exempt-rotated` reports an
      exempt password older than `password_max_age`, so the rotation is
      still evidenced (RUNBOOK, *Rotating the automation account's
      password*; `auth_refresh` records it). The account list is `always`
      tagged; the loop fails on a failed `chage`. *Proven* on `byo-rl9-02`
      (two accounts): `byoadmin` lost maximum age and inactivity and kept
      minimum and warning, `cuiuser1` kept 60/35, the second apply reported
      `changed=0`, `--skip-tags 03.01.01 --check` completed, and 03.01.01
      and 03.05.12 verify with nothing failed.
