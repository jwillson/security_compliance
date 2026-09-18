# security_compliance

POSIX hardening for CUI systems. Target family: **Rocky Linux 9 / RHEL 9**.

The tool is `nist_sp_800_171r3/rl9-171/`. Work from there unless you are
deliberately reading history.

## Trees

| Path | Status | Treat as |
| --- | --- | --- |
| `nist_sp_800_171r3/rl9-171/` | **the tool** | Catalog extracted from the publication PDF, two Ansible roles (`nist_800_171` over `cui_hosts`, `nist_log_collector` over `log_hosts`), independent assessor, reference VM build, and `tools/inventory.py`, which owns `inventory/hosts.yml`. |

Superseded trees (`r3/`, `os/`, `stig/`) were removed once their reconciliation
had served its purpose, and the orphaned `web/` nginx snippet went the same way
(TASKS.md 4.5). They remain in git history if ever needed.

## Source of truth

- **Requirements**: `rl9-171/catalog/requirements.json` — *generated*, never
  hand-edited. `make catalog` re-extracts it from
  `rl9-171/NIST.SP.800-171r3.pdf` and reproduces it byte for byte.
- **Mapping and policy**: `rl9-171/catalog/overlay-rocky9.yml` — what Rocky 9
  enforces for each requirement, what it cannot, and the ODP values. This is
  the file to edit.
- ODPs live in two blocks of the overlay and nowhere else.
  `odp:` (32) are values the host enforces: the role applies them and the checks
  assert them via `{odp.name}`, so they cannot drift. Never hardcode one in a
  task or a check; `make validate` fails on a machine ODP no check asserts.
  `odp_organizational:` (62, across 49 requirements) are the assignments no host
  setting can satisfy. Nothing substitutes them and no check asserts them; they
  render into `/etc/nist-800-171/organizational-requirements.md`. Each is keyed
  to the requirement that asks for the parameter. Every value was reviewed and
  accepted by the owner on 2026-09-18 (`rl9-171/docs/ODP-REVIEW.md`).
- `make validate` must pass: it confirms the catalog, the overlay and the
  checks all agree. Run it after editing any of the three.

## Hard rules

- Do not invent NIST requirements. IDs, titles and statements come from
  SP 800-171r3 (May 2024) via the extractor. If the wording is in doubt, the
  PDF settles it and the answer goes into the extractor, not into a task file.
- A requirement classed `partial` must never report PASS — only MANUAL. A
  green report must not imply the system is authorized. 28 requirements are
  purely organizational; the assessor reports them `NOT_APPLICABLE(host)`.
  A `technical` entry may not carry a `residual` and every machine ODP must
  be asserted by a check; `make validate` enforces both.
- Verification reads **effective** state, not the file the role wrote:
  `sshd -T` over `sshd_config`, `sysctl -n` over `/etc/sysctl.d/`,
  `auditctl -l` over `rules.d`, `systemctl is-enabled` over unit files. Every
  check declares exactly one assertion and reports expected next to observed.
- `./apply.sh` changes the target. Only run it against a host you intend to
  harden or a throwaway Rocky 9 VM. Never against the machine you write on.
  `./apply.sh --check --diff` is the dry run; `./verify.sh` is read-only.
- Never commit key material (`.secrets/`), live inventories, ISOs, qcow2
  images, or generated reports. The repo's history is clean of all of these —
  keep it that way.
- Git author is the repository owner's GitHub identity,
  `Jason Willson <jason.willson@gmail.com>`, on every commit. Do not invent
  `@users.noreply.github.com` addresses or use any other address.
- `roles/nist_800_171/tasks/main.yml` uses `import_tasks`, never
  `include_tasks`. An include is resolved at run time, so the tag filter sees
  only the family tag on the include statement and `--tags 03.05.07` silently
  runs nothing at all. An import is resolved at parse time, so each task's own
  requirement tag is selectable.
- A role that opens a listening port declares it in
  `{{ nist_conf_dir }}/authorized-ports.d/<NN>-<role>`. The port checks read
  that directory rather than hardcoding a port, so 6514 is authorized on a
  collector and still a finding on a plain CUI host, and a port nothing
  declares is closed on apply. Widening a check to go
  green is the wrong fix.
- Python 3, stdlib first. Ansible tasks use FQCN (`ansible.builtin.*`,
  `ansible.posix.*`, `community.general.*`) and carry their requirement ID as
  a tag.

Operator procedure, including recovery paths, is
`nist_sp_800_171r3/rl9-171/docs/RUNBOOK.md`.

## First commands

```bash
cd nist_sp_800_171r3/rl9-171
make validate                    # catalog <-> overlay <-> checks agree
make help                        # the whole pipeline

./apply.sh --check --diff        # dry run against inventory/hosts.yml
./verify.sh --failed-only        # assess, show deviations only
```

Hardening an existing host needs neither the VM targets nor `.secrets/`. The
role reads its two secrets from `NIST_GRUB_PASSWORD` (03.10.07) and
`NIST_LUKS_PASSPHRASE` (03.08.09) first, and from `.secrets/` only as the lab
fallback; unset, the control is skipped with a warning and reported, and the
run does not abort. `./apply.sh --check --diff` completes on a host that has
never been applied: a task that needs a package or unit an earlier task
provides is skipped in check mode only while that prerequisite is outstanding
(the idiom is explained at the top of `roles/nist_800_171/tasks/main.yml`).

```bash
cp inventory/hosts.yml.example inventory/hosts.yml   # edit for your host
export NIST_BECOME_PASSWORD=... NIST_GRUB_PASSWORD=...
./apply.sh --check --diff && ./apply.sh && ./verify.sh
```

`site.yml` has two plays: the overlay over `cui_hosts`, then
`nist_log_collector` over `log_hosts`. `./tools/inventory.py show` lists the
hosts and where each forwards its records.
