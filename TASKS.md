# Tasks

Working checklist to take `nist_sp_800_171r3/rl9-171/` from "builds and
assesses one VM" to "a tool I trust against a real Rocky 9 host".

Ordered so that each phase makes the next one meaningful. Phases 1–3 are
verification of things already written; phase 4 is decisions nobody but the
system owner can make.

---

## Status: what is proven, and what is only written

Be honest about the difference — most of what follows exists to close the gap.

**Proven against running hosts (`rl9-cui-01` + `rl9-log-01`)**

- `make catalog` reproduces `catalog/requirements.json` byte for byte from the PDF
- `make validate` — 97 requirements, 327 checks, 29 + 47 ODPs, all consistent
- `./apply.sh` is idempotent (`changed=0` on re-run); `--check --diff` is a real drift detector
- `./verify.sh` — **both hosts** 97 assessed, 327 checks, 0 failed, 43 / 26 / 0 / 28
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
  portability claim, never run against a non-lab machine
- A third host. `verify.sh` has looped over two, not three
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

- [ ] **1.4 Build a second CUI host.** `./vm/build-vm.sh --name rl9-cui-02`
  *Why:* proves `inventory.py` does not evict the first host — the bug that
  motivated writing it — and that `verify.sh` genuinely loops over hosts
  rather than assuming one.
  *Done when:* `./verify.sh` assesses three hosts in one run and writes three
  report pairs.

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

- [ ] **1b.6 The collector is not idempotent.** `03.14.08 | Tighten
      permissions on existing log files` reports changed on every run against
      `rl9-log-01`, while `rl9-cui-01` sits at `changed=0`. The collector
      continuously creates `/var/log/nist-remote/<host>/<program>.log`, so
      the task always finds files it has not seen — even though rsyslog
      already creates them 0600 via `$FileCreateMode`.
      *Why it matters:* `./apply.sh --check` is documented as a drift
      detector. On a collector it now reports permanent drift, which is the
      kind of noise that makes people stop reading it.
      *Fix:* have the task touch only files whose mode is actually wrong.

- [x] **1b.7 `--tags <requirement>` ran nothing at all.** README, RUNBOOK and
      `apply.sh --help` all promised that `--tags 03.05.07` applies exactly
      that requirement's tasks. `main.yml` used `include_tasks` with only the
      family tag on the include statement, so a requirement tag never reached
      the inner tasks: `--tags 03.05.01` ran **0** tasks while `--tags 03.05`
      ran 26. All 17 includes converted to `import_tasks`, which resolves at
      parse time so each task's own tag is visible to the filter. *Fixed —
      `--tags 03.05.01` now runs exactly those four tasks.* Found only
      because 1b.4 needed to trigger one requirement's tasks in isolation.

- [ ] **1b.5 `rl9-cui-01` was passing `ia-01-loginuid-immutable` by
      accident.** Neither host configures it persistently in a way that
      survives without a reboot; cui-01 reported `loginuid_immutable 1` from
      stale running-kernel state accumulated over 16 hours and several
      applies. Re-verify after a rebuild from scratch, not after an apply to
      a long-lived host.

---

## Phase 2 — prove the portability claim

The stated goal is a single portable tool that can harden *any* Rocky 9 host.
Nothing has tested that outside the kickstart VMs.

- [ ] **2.1 Harden a Rocky 9 host this toolkit did not build.** A stock
  cloud image or minimal ISO install is fine — it must *not* come from
  `make vm`.
  ```bash
  cp inventory/hosts.yml.example inventory/hosts.yml   # edit for that host
  ./apply.sh --check --diff        # read it before applying
  ./apply.sh && ./verify.sh
  ```
  *Why:* this is the difference between "hardens the VM it builds" and "a
  hardening tool". The install-time controls will fail here and that is the
  point.
  *Done when:* it applies without error and the only deviations are
  install-time ones.

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

- [ ] **4.2 Decide the ClamAV / EPEL trade-off (03.14.02 vs 03.17.03).**
      Signature scanning needs EPEL, which sits outside the authorized
      repository set. Currently off, which is why the VM reports 43 satisfied
      rather than 44. Either accept the gap and record it, or set
      `nist_clamav_enabled` + `nist_enable_epel` and justify the repository.

- [ ] **4.3 Profile fapolicyd against a real workload.** Deny-by-default
      execution will block unprofiled applications. Run with
      `nist_fapolicyd_permissive: true`, collect, write rules, re-enforce.

- [ ] **4.4 Re-examine three classifications inherited from this merge.**
      These moved from `os_partial` to `technical`, meaning a failing check is
      now treated as a real finding rather than a partial obligation:
      `03.05.05` Identifier Management, `03.05.12` Authenticator Management,
      `03.08.02` Media Access.
      *Why:* the merge adopted the stricter reading wholesale. These three are
      the ones where it is genuinely arguable.

- [ ] **4.5 Decide what happens to `nist_sp_800_171r3/web/`.** An nginx TLS
      snippet, orphaned from the tool, which hardens hosts rather than web
      tiers. Its requirement IDs are now correct. Either fold it into scope
      properly, or archive it and stop implying it is maintained.

---

## Phase 5 — cleanup and housekeeping

- [ ] **5.1 Rotate `.secrets/`.** Free at the next rebuild, disruptive at any
      other time — it locks you out of every guest built with the old key.
      ```bash
      make destroy && rm -rf .secrets && make secrets && make vm
      ```

- [ ] **5.2 Delete the `r3-hardening-middleware` branch.** `main` contains
      everything; the branch is redundant.

- [ ] **5.3 Decide whether `archive/` stays.** It is 618 MB on disk (mostly
      the ignored `r3/lab/.state/` qcow2; far less in git). It exists so
      `docs/legacy-gap.md` has a subject.
      *If you delete it:* also delete `rl9-171/tools/legacy-gap.py` and
      `rl9-171/docs/legacy-gap.md`. The tool already refuses to run and says
      exactly this when its source is missing — it will not fail silently.

- [ ] **5.4 Prune local build cruft.** `archive/r3/lab/.state/` (646 MB
      qcow2), `__pycache__` directories, old `reports/`. All gitignored, none
      of it in history — this is disk, not hygiene.

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
      organizational requirements and 25 residual obligations are not in it —
      they come from `organizational-requirements.md`.

- [ ] **6.5 Re-read the caveat that matters.** Passing every check means the
      host-enforceable controls are in place. It does not mean the system is
      compliant or authorized.

---

## Not planned

Recorded so they do not get re-litigated:

- Reviving anything under `archive/`. `r3/` was retired for cause: its
  verifier grades on exit status, 14 of its checks cannot fail and 4 are
  inverted. `os/` and `stig/` are r2-tagged. Both worthwhile pieces have
  already been ported.
- Supporting distributions other than the RHEL 9 family. The overlay is
  Rocky 9 specific by design and `site.yml` asserts it.
