> **ARCHIVED — do not follow these instructions.**
>
> This tree is superseded by `../../rl9-171/`. Its catalog agrees with the
> current one on every requirement ID, title and withdrawn flag, but its
> verifier grades on exit status alone and its generated playbook has no
> handlers. See `../README.md` for the full reasoning, and
> `../../rl9-171/docs/legacy-gap.md` for the reconciliation this tree's
> `gap.md` used to hold (corrected — the original misnamed 03.10.07 and
> 03.10.08).
>
> Do not extend anything here. Port it into `rl9-171/` instead.

# r3 overlay

Source of truth: `catalog.json` (NIST SP 800-171 Revision 3, May 2024).
97 active + 33 withdrawn. Linux-implementable: 72 (`os` + `os_partial`).
Publication PDF (prose, not the machine catalog): `../../rl9-171/NIST.SP.800-171r3.pdf`.

## Source of truth

- Edit requirements in `catalog.json`. Then regenerate:
  `python3 nistctl.py playbook --out ansible/site.yml`
- Do **not** hand-edit `ansible/site.yml`.
- Machine ODPs live in `odps.yml` (`inactive_days: 35`, not `"35 days"`).
- Copy payloads go in `ansible/files/`. Bare `src:` values are rewritten to `{{ playbook_dir }}/files/...`.
- `../../rl9-171/NIST.SP.800-171r3.pdf` is the May 2024 publication. Use it to resolve wording; put the result in `catalog.json`.
- `../stig/nist_800_171r3_stig.json` is the r2-shaped extraction. Use `gap.md` / `python3 nistctl.py gap` instead of trusting its titles.

## Implementability

| Class | Agent behavior |
| --- | --- |
| `os` | POSIX enforcement is in scope (sshd, auditd, faillock, crypto-policies, …) |
| `os_partial` | Ship the OS slice; say what still needs policy/IdP/hardware |
| `policy` | SSP / process. Do not fake it with a sysctl |
| `physical` | Out of band. Do not Ansible it |
| `withdrawn` | Not a requirement in r3. Do not keep it live |

## IDs that were wrong in the old playbook / JSON

Confirm against the catalog before tagging:

- MFA is `03.05.03` (not `03.05.02`)
- Time stamps are `03.03.07`; `03.03.03` is audit record generation
- FIM / AIDE is `03.14.06`; `03.14.07` is withdrawn
- `03.05.11` is authentication *feedback*, not password hashing
- `03.13.12` / `03.13.13` are collaborative computing / mobile code, not wireless/USB
- `03.05.03` needs a FIPS authenticator (PAM u2f / sssd / PIV), not `google-authenticator`

Full recon: `gap.md`.

## Commands

```bash
python3 nistctl.py catalog --impl linux
python3 nistctl.py gap --kind missing_from_legacy
python3 nistctl.py odps --write odps.yml
python3 nistctl.py playbook --out ansible/site.yml
python3 nistctl.py audit --id 03.01.08 --limit cui-01   # guests via inventory
python3 nistctl.py audit --id 03.01.08 --local          # this host only
python3 nistctl.py remediate --check
python3 nistctl.py remediate --apply --id 03.01.08   # only on a throwaway Rocky 9
python3 lab/labctl.py up                             # QEMU/KVM cluster, writes ansible/inventory.ini
# Guest walkthrough: lab/RUNBOOK.md
```

`--apply` is never implied. FIPS (`03.13.08` / `03.13.11`) needs a reboot after `fips-mode-setup --enable`.

Do not POST telemetry. Do not add controls that are not in r3.
