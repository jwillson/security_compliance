# security_compliance

POSIX hardening for CUI systems. Target family: **Rocky Linux 9 / RHEL 9**.

The tool is `nist_sp_800_171r3/rl9-171/`. Work from there unless you are
deliberately reading history.

## Trees

| Path | Status | Treat as |
| --- | --- | --- |
| `nist_sp_800_171r3/rl9-171/` | **the tool** | Catalog extracted from the publication PDF, Ansible role, independent assessor, reference VM build. Everything else is history. |
| `nist_sp_800_171r3/web/` | adjunct, out of scope | nginx TLS snippet for a web tier. Not covered by the role, which hardens hosts. Requirement IDs in its comments are checked against the catalog. |
| `nist_sp_800_171r3/archive/` | **superseded — do not extend** | `r3/`, `os/`, `stig/`, and the PDF copy their relative paths resolve to. See `archive/README.md`. |

Do not add features to anything under `archive/`. If something there is worth
having, port it into `rl9-171/` and note the port in `archive/README.md`.

## Source of truth

- **Requirements**: `rl9-171/catalog/requirements.json` — *generated*, never
  hand-edited. `make catalog` re-extracts it from
  `rl9-171/NIST.SP.800-171r3.pdf` and reproduces it byte for byte.
- **Mapping and policy**: `rl9-171/catalog/overlay-rocky9.yml` — what Rocky 9
  enforces for each requirement, what it cannot, and the ODP values. This is
  the file to edit.
- ODPs are defined once, in the overlay's `odp:` block, and substituted into
  both the role and the checks via `{odp.name}`. Never hardcode a policy value
  in a task or a check; the two would drift.
- `make validate` must pass: it confirms the catalog, the overlay and the
  checks all agree. Run it after editing any of the three.

## Hard rules

- Do not invent NIST requirements. IDs, titles and statements come from
  SP 800-171r3 (May 2024) via the extractor. If the wording is in doubt, the
  PDF settles it and the answer goes into the extractor, not into a task file.
- A requirement classed `partial` must never report PASS — only MANUAL. A
  green report must not imply the system is authorized. 28 requirements are
  purely organizational; the assessor reports them `NOT_APPLICABLE(host)`.
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
- Git author must match `main`:
  `Jason Willson <jason.willson@gmail.com>`. Do not invent
  `@users.noreply.github.com` addresses.
- Python 3, stdlib first. Ansible tasks use FQCN (`ansible.builtin.*`,
  `ansible.posix.*`, `community.general.*`) and carry their requirement ID as
  a tag.

## First commands

```bash
cd nist_sp_800_171r3/rl9-171
make validate                    # catalog <-> overlay <-> checks agree
make help                        # the whole pipeline

./apply.sh --check --diff        # dry run against inventory/hosts.yml
./verify.sh --failed-only        # assess, show deviations only
```

Hardening an existing host needs only an inventory — the VM and ISO targets
are for building a reference machine, not a prerequisite:

```bash
cp inventory/hosts.yml.example inventory/hosts.yml   # edit for your host
./apply.sh && ./verify.sh
```
