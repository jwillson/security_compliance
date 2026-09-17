# Archive — superseded work

Nothing in this directory is maintained, and nothing in it is the catalog of
record. It is kept because it documents how the current tool was arrived at,
and because the reconciliation in
[`../rl9-171/docs/legacy-gap.md`](../rl9-171/docs/legacy-gap.md) refers to it.

The current tool is [`../rl9-171/`](../rl9-171/). Use that.

| Path | What it was | Why it is here |
| --- | --- | --- |
| `r3/` | Catalog-driven middleware: `nistctl.py`, hand-authored `catalog.json`, generated `ansible/site.yml`, QEMU lab in `lab/` | Superseded. Its catalog agrees with the current one exactly on IDs, titles and the withdrawn set, but its verifier grades on exit status only, and its playbook has no handlers. See below. |
| `os/` | Vagrant box plus `nist_full_remediate.yml` | r2-tagged. Retagging it without a gap pass would point tasks at the wrong controls. |
| `stig/` | `nist_800_171r3_stig.json` + CSV checklist | r2 titles on r3 IDs. A command scrapbook, not a catalog. |

There is no copy of the publication here. These trees' references point at the
one the live tool carries, `../rl9-171/NIST.SP.800-171r3.pdf`, so the repo
holds it once.

## Why `r3/` was retired rather than merged

Its data layer was sound — an independent check found zero disagreement with
the current catalog across all 130 requirement IDs, all 97 titles, and the
33-item withdrawn set. The layers above it were the problem:

- **`nistctl audit` cannot fail correctly.** Verdicts are `rc == 0`; the
  `expect` value in the catalog is carried as metadata and never asserted.
  14 checks run commands whose exit status does not depend on the value being
  tested (`getenforce`, `stat -c '%a' /etc/shadow`, `cat
  /proc/sys/crypto/fips_enabled`), so they can never fail. 4 more are
  inverted — `03.01.05` greps for `NOPASSWD` with `expect: none`, so a host
  with passwordless sudo scores **pass** and a clean host scores **fail**.
- **The generated playbook has no handlers.** 74 tasks, zero `notify`: it
  writes sshd and auditd configuration and never restarts the service, so
  what is applied and what is in effect are not the same thing.
- **No partial state.** Every requirement is pass or fail, so requirements
  with organizational statements get reported as fully satisfied by a host
  setting.

What was worth keeping has been taken across:

- `gap.md` / `gap.json` → regenerated and corrected as
  `rl9-171/docs/legacy-gap.md` (`rl9-171/tools/legacy-gap.py`). The original
  misnamed two requirements: it lists `03.10.07` as "Alternate Work Site" and
  `03.10.08` as "Access Records"; they are Physical Access Control and Access
  Control for Transmission.
- The organizational ODP register in `r3/odps.yml` and the per-requirement
  `odps[]` in `r3/catalog.json` — 68 definitions with defaults and rationale,
  including the organizational assignments (assessment frequency, incident
  reporting time, rescreening interval, remediation SLA) that the live
  overlay's machine-value `odp:` block has no slot for. **Not yet ported.**
- `r3/lab/labctl.py`'s three-node topology, which includes an rsyslog
  listener (`log-01`) that the single-VM lab lacks. **Not yet ported.**
