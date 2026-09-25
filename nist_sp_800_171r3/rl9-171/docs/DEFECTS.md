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
