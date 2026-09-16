# security_compliance

POSIX hardening for CUI systems. Target family: **Rocky Linux 9 / RHEL 9**.
Grok Build CLI is expected to work from this repo root or from `nist_sp_800_171r3/r3/`.

## Trees (do not collapse them)

| Path | Status | Treat as |
| --- | --- | --- |
| `nist_sp_800_171r3/r3/` | **current work** | Faithful SP 800-171 Revision 3 (May 2024) catalog, `nistctl`, generated Ansible |
| `nist_sp_800_171r3/os/` | lab image, r2-tagged | Vagrant + older playbook. Keep. Do not retag IDs to r3 without a gap pass. Do not overwrite from `r3/` |
| `nist_sp_800_171r3/stig/` | scrapbook | r2 titles glued onto r3 IDs. Not the catalog of record |
| `nist_sp_800_171r3/web/` | nginx TLS snippet | Comments may cite the wrong r3 ID; fix against `r3/catalog.json` |

When in `nist_sp_800_171r3/r3/`, also follow that directory's `AGENTS.md`.

## Hard rules

- Do not invent NIST controls. IDs, titles, statements, ODPs, audit commands, and remediations come from SP 800-171r3 via `nist_sp_800_171r3/r3/catalog.json`.
- Live remediations (`ansible-playbook` without `--check`, `nistctl remediate --apply`) only against an intended CUI host or a **throwaway Rocky 9 VM**. Never overlay the machine used to write or review the playbook.
- `nistctl audit` is read-only. `nistctl remediate` is `--check` unless `--apply` is explicit. `--apply` is never implied.
- Git author must match `main`: `Jason Willson <jason.willson@gmail.com>`. Do not invent `@users.noreply.github.com` addresses.
- Python 3, stdlib first. Ansible tasks use FQCN (`ansible.builtin.*`, `ansible.posix.*`, `community.general.*`).
- Do not commit `.vagrant/`, `__pycache__/`, live `inventory.ini`, or hosts with real names.

## First commands

```bash
python3 nist_sp_800_171r3/r3/nistctl.py catalog --impl linux
python3 nist_sp_800_171r3/r3/nistctl.py gap --kind missing_from_legacy
python3 nist_sp_800_171r3/r3/nistctl.py audit --id 03.01.08
```

Lab VM: `nist_sp_800_171r3/os/Vagrantfile`. First apply a single tag (`--id 03.01.08`) before the full overlay.
