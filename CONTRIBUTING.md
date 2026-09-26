# Contributing

Thank you for looking. This project makes claims about the security of
systems that handle Controlled Unclassified Information, so the bar for a
change is evidence: what a running host shows, not what the code looks like
it should do. The rules below exist because each of them was learned the hard
way — the record is `nist_sp_800_171r3/rl9-171/docs/DEFECTS.md`.

Security issues go through `SECURITY.md`, not a public issue.

## Before you start

The tool is `nist_sp_800_171r3/rl9-171/`. Read its `README.md` (the design),
`docs/RUNBOOK.md` (operating it), `docs/LAB.md` (the labs that prove it) and
`AGENTS.md` at the repository root (the rules below, in full).

```bash
cd nist_sp_800_171r3/rl9-171
make validate        # catalog <-> overlay <-> checks agree
make test            # unit tests: assessor, validator, POA&M register
make catalog-check   # the catalog still reproduces from the PDF
```

CI (`.github/workflows/ci.yml`) runs these, the playbook's syntax check and
a parse of every script on every push and pull request. It cannot run a
host; that is what the labs are for.

## How a change is accepted

- **A finding is a lead until a host confirms it.** Reproduce it on a lab
  host (`docs/LAB.md`) and say what the host showed.
- **Fix the check first.** If the assessor passed something it should not
  have, change the check so it **fails** on the defect, show that it fails,
  then fix the role until it passes. A check that cannot fail proves nothing.
- **Prove it on a host.** For a role change, a full cycle —
  `tools/harden-cycle.sh HOST`: dry run, apply, reboot when owed, apply,
  `changed=0`, verify. For an assessor change, the old and new assessors
  back to back on the same hosts: `tools/assessor-parity.sh BASE NEW`.
  Where configuration is not enough — an idle timeout, a boot prompt, a
  recovery — prove the behaviour (`tools/ssh-idle-test.sh`,
  `tools/rehearse-*`).
- **Script everything you run against a host.** An exploratory command is
  only the first draft of the script it becomes; commit the script
  (`vm/` for lab builds, `tools/` for probes and rehearsals).
- **Keep documentation fresh, in the repository.** What you learned goes into
  the file that owns it, in the same change. A document that disagrees with
  the code is a defect.
- **Record it.** An open item goes in `TASKS.md`; once fixed and proven it
  moves to `docs/DEFECTS.md`, with the evidence.

## Rules the code keeps

- Requirements come from SP 800-171r3 via the extractor, never by hand;
  `catalog/requirements.json` is generated.
- Policy lives in `catalog/overlay-rocky9.yml`. An organization-defined
  parameter the host enforces is asserted by a check through `{odp.name}` —
  never hardcoded in a task or a check.
- A `partial` requirement never reports PASS, only MANUAL; a `technical` one
  carries no `residual`. `make validate` enforces both.
- Checks read **effective** state (`sshd -T`, `sysctl -n`, `auditctl -l`,
  `systemctl is-enabled`), declare exactly one assertion, and report expected
  next to observed.
- Ansible tasks use fully qualified module names and carry their requirement
  ID as a tag; `tasks/main.yml` uses `import_tasks`, so `--tags 03.05.07`
  selects that requirement's tasks — and every task a tagged task depends on
  must carry the tag too.
- A role that opens a listening port declares it in
  `/etc/nist-800-171/authorized-ports.d/`; widening a check to go green is the
  wrong fix.
- Python 3, standard library first.

## What never goes in the repository

Key material or passwords (`.secrets/`, a lab directory), live inventories
(`inventory/*.yml`), ISOs, disk images, and generated reports. `.gitignore`
covers them; check `git status` anyway.

## Licence

Contributions are made under the Apache License 2.0, the same terms as the
rest of the repository (`LICENSE`).
