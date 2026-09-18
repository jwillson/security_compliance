# ODP review — decisions for the system owner

TASKS.md 4.1 / 4.1b. The overlay ships 76 organization-defined parameters
(28 machine-enforced in `odp:`, 48 in `odp_organizational:` once this review
is applied) against 80 organization-defined decision points in the 97
active statements of SP 800-171r3. Every value is a default drawn from
common practice; none is this organization's decision until it is accepted
here. An assessor will ask where each came from.

How to use this: each item has a **recommendation** and a **decision** line.
Accept it, or write the value you want. When every decision line is filled
in, the overlay, the checks and the tasks are changed to match (`make
validate` guards the mechanics; it cannot tell whether a number is right).

Numbers quoted for the host come from the role defaults and the checks, not
from memory: `roles/nist_800_171/defaults/main.yml`, `audit/checks.yml`.

---

## A. The register says the opposite of what the host does

**A1. Password lifetime.** `auth_refresh` (03.05.12e) says *"passwords on
recovery not calendar"*, while `odp.password_max_age: 60` expires every local
password after 60 days and `ia-12-pass-max-days` / `ia-12-existing-max-days`
assert it. The SSP would state the opposite of the evidence.
Recommendation: keep the 60-day expiry (it is the RHEL 9 STIG value, and
removing it changes two checks) and make the register say so:
`auth_refresh: "local passwords every 60 days (PASS_MAX_DAYS, enforced) and
on compromise or role change; SSH keys and hardware tokens on compromise,
role change, or 1 year"`. Note the deliberate deviation from SP 800-63B,
which prefers no calendar expiry, in the rationale.
Decision:

**A2. Idle disconnect.** `session_events` (03.01.11) says 900 s idle, but
SSH sessions drop at `ssh_client_alive_interval: 600` with
`ssh_client_alive_count_max: 0`; the console locks at
`idle_lock_seconds: 900` and `session_timeout_seconds: 900`.
Recommendation: one idle value everywhere: `ssh_client_alive_interval: 900`.
Keep `session_events` in the organizational block (end of shift and incident
lockout are not host settings) and reword it to
`"900 s idle on any session type; end of shift; incident lockout"`.
Decision:

## B. Registers that understate the host, and schedules nothing asserts

Three review frequencies are recorded as if the work were manual, while the
host runs it daily. No check asserts any timer's schedule, so a changed
`OnCalendar` fails nothing.

**B1.** `assess_freq` (03.12.01) = 12 months; `nist-assessment.timer` runs
daily at 06:00.
Recommendation: `"automated: daily (nist-assessment.timer); formal
800-171A assessment: 12 months"`.
Decision:

**B2.** `audit_review_freq` (03.03.05a) = 7 days; `nist-audit-review.timer`
runs daily at 05:00.
Recommendation: `"automated report: daily (nist-audit-review.timer); human
review of the report: 7 days"`.
Decision:

**B3.** `inv_review` (03.04.10b) = 30 days; `nist-inventory.timer` runs daily
and the dnf post-transaction action refreshes it on every package change.
Recommendation: `"automated: daily and on every package transaction; owner
attestation: 90 days"`.
Decision:

**B4. Assert the schedules.** Add one check per timer reading
`systemctl show <timer> -p TimersCalendar` against the role default, so the
schedule is evidence rather than an assumption. No decision needed; done
with the rest of this review unless you object.
Decision:

**B5. Host-scope texts that cite an ODP that does not exist.** 03.03.01,
03.11.02 and 03.14.02 say "at the ODP frequency"; 03.03.05's timer task says
the same. The ODPs are added under D below and the texts made to cite them.
No decision needed.

## C. Baseline coherence

**C1. Precedence.** `config_settings` (03.04.02a) names *"DISA RHEL 9 STIG +
CIS L2 + this overlay"* with no rule for a conflict, so the requirement's
"most restrictive mode" is undefined.
Recommendation: `"this overlay; where it is silent, the DISA RHEL 9 STIG;
CIS Level 2 only where both are silent. On conflict the most restrictive
setting applies and the overlay records the deviation"`.
Decision:

**C2. Minimum password length.** `password_min_length: 14` is the CIS value;
the RHEL 9 STIG (V1R3, RHEL-09-611090) requires 15. Every neighbouring value
is STIG.
Recommendation: `15`.
Decision:

**C3. Patch SLA drops the medium tier.** `patch_sla` (03.14.01b) =
*"critical 15d; high 30d"* while `remediate_sla` (03.11.02b) = *"critical
15d; high 30d; medium 90d"*, and `patch_sla`'s rationale claims it matches.
Recommendation: `"critical 15 days; high 30 days; medium 90 days; low at
the next maintenance window"` for both.
Decision:

## D. Decision points with no ODP at all (added by this review)

Each is a real assignment in the publication with nothing recorded. The
recommended value is what the host already does where a host control
exists; otherwise a common default.

**D1. 03.01.01f/g/h — account management time periods.** f: disable an
account within a time period of the account being no longer needed; g:
notify account managers within a time period of termination, transfer, or
change of need; h: disable after inactivity. `notify_period` (24 hours)
answers g; `account_inactivity_days` (35) answers h.
Recommendation: add `disable_period: "immediately when for cause; within 4
hours otherwise (matches offboard_time)"` for f.
Decision:

**D2. 03.01.05b — security-relevant information.** `sec_functions` names the
functions; the information is unrecorded.
Recommendation: add `sec_info: "/etc/shadow and gshadow, sudoers, audit
rules and logs, faillock state, SSH host keys, LUKS key slots, the
nist-800-171 configuration tree"`.
Decision:

**D3. 03.02.01 / 03.02.02 — training events.** Frequency is recorded (12
months); the events that also trigger training are not.
Recommendation: add `at_events: "on hire; on role change; after a
security incident involving the user; on a significant change to the
system"` for both requirements.
Decision:

**D4. 03.03.01a — event types to log.** The host logs the rule set in
`audit-rules.j2`; nothing names it as the organization's choice.
Recommendation: add `event_types: "the audit rule set the role installs:
authentication and authorization decisions, privilege use, account and
group changes, changes to audit configuration, kernel module loading, file
deletion by users, access to CUI paths, and system startup and shutdown"`.
Decision:

**D5. 03.03.04a/b — audit failure alert window and additional actions.**
The host does: `space_left_action = SYSLOG` at 500 MB,
`admin_space_left_action = SINGLE` at 250 MB, `disk_full_action = SINGLE`,
`disk_error_action = SINGLE`.
Recommendation: add `audit_fail_alert: "immediately, by syslog and to the
audit administrator, at 500 MB free"` and `audit_fail_actions: "drop to
single-user mode at 250 MB free, on a full disk, and on a disk error, so no
unaudited work occurs"`. These describe what the host enforces; the
mechanism stays in the machine ODPs.
Decision:

**D6. 03.03.07b — time-stamp granularity.**
Recommendation: add `time_granularity: "one second, UTC, chrony-
synchronised to the organization's authoritative sources"`.
Decision:

**D7. 03.04.06b — prohibited functions, ports, protocols and services.**
The host removes a named package set and closes every port nothing declares.
Recommendation: add `prohibited_services: "any listener not declared in
authorized-ports.d; telnet, rsh, ftp, tftp, ypbind, VNC and conferencing
software; uncommon network protocols (dccp, sctp, rds, tipc); unused
filesystem drivers"`.
Decision:

**D8. 03.06.04a — time period to train incident responders after assuming
the role.**
Recommendation: add `ir_train_period: "within 30 days of assuming the role"`.
Decision:

**D9. 03.10.02b — events or indications that trigger a physical-access log
review.**
Recommendation: extend `pe_log_review` to `"7 days; and on any incident,
alarm, or reported unauthorized presence"`.
Decision:

**D10. 03.11.02a/c — scan frequency.** The host scans weekly
(`nist-vuln-scan.timer`, Sunday 02:00) and refreshes advisory metadata on
every run.
Recommendation: add `scan_freq: "weekly (nist-vuln-scan.timer); and within
7 days of a new vulnerability being disclosed that affects the platform"`.
Decision:

**D11. 03.13.11 — types of cryptography.**
Recommendation: add `crypto_types: "FIPS 140-3 validated modules only:
the system-wide crypto policy FIPS, LUKS2 aes-xts-plain64, RSA >= 3072 or
ECDSA P-256/384, SHA-2, TLS 1.2+"`.
Decision:

**D12. 03.14.02c — malicious-code scan frequency.** fapolicyd is
continuous; the ClamAV timer, when enabled, runs daily at 03:00 (off by
default, TASKS.md 4.2).
Recommendation: add `malware_scan_freq: "continuous execution control
(fapolicyd); signature scan daily at 03:00 when ClamAV is enabled"`.
Decision:

**D13. Two nested selections.** 03.01.08b: the host locks the *account* for
`lockout_duration_seconds`; 03.01.10a: the host *initiates* a device lock
after `idle_lock_seconds` (users are not required to lock manually).
Recommendation: record both selections in the parameter text of the
machine ODPs' comments, and in `organizational-requirements.md`.
Decision:

## E. Checks whose assertion does not match the ODP's meaning

**E1.** `ac-08-faillock-unlock` asserts `unlock_time >= lockout_duration_seconds`.
The ODP comment allows `0 = until admin release`, the strictest setting, and
the check would fail it; and `ac-08-faillock-deny` asserts
`deny <= lockout_attempts`, which passes `deny = 0` (lockout off).
Recommendation: `unlock_time == ODP, or 0 when the ODP is 0`; and
`1 <= deny <= ODP`. Rehearsal 3.2 showed what 0 means on a single-admin
host: nobody can log in until an administrator resets it, and there is no
other administrator. Keep 900.
Decision:

**E2.** `au-03-retention-capacity` asserts `num_logs * max_log_file >= 500`,
a constant unrelated to `audit_retention_days`. auditd's `ROTATE` deletes
the oldest file at `num_logs`, so 90-day retention is not delivered by the
settings that claim to deliver it; logrotate's `maxage 90` applies only to
files auditd has not already deleted.
Recommendation: `max_log_file_action = KEEP_LOGS` (auditd never deletes)
and let logrotate enforce both `maxage {{ audit_retention_days }}` and a
size cap; change the check to assert `keep_logs` and drop the constant.
`audit_num_logs` then has no function and is removed (the validator would
flag it anyway).
Decision:

## F. Factual errors in values

**F1.** `travel_config` (03.04.12) and `media_types` (03.08.07) name
`usbguard`, which nothing installs; the host blacklists the `usb-storage`
module.
Recommendation: replace with `"usb-storage module blocked (03.01.16,
03.08.07)"` in both.
Decision:

## G. Already decided (recorded here for completeness)

- `ir_authorities` stays CISA-based: the population is non-DoD CUI (TASKS.md
  4.1b, 2026-09-17).
- `patch_window_days` removed: dead machine ODP (TASKS.md 4.1c).
- ClamAV off, fapolicyd enforcing (TASKS.md 4.2, 4.3).

## H. Values accepted as they are

Everything not listed above keeps its current value, and the acceptance is
this document. If any of those should change, add it here.
