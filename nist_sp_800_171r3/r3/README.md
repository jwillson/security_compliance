# nistctl — SP 800-171r3 Linux overlay

Catalog-driven hardening for Rocky Linux 9 / RHEL 9 family. This tree is the
r3 middleware. It does **not** replace `nist_sp_800_171r3/os/` — that playbook
is the r2-tagged lab image. Keep both until the overlay has been run against a
throwaway VM.

Source of truth: [NIST SP 800-171 Revision 3](https://doi.org/10.6028/NIST.SP.800-171r3) (May 2024).

## What changed vs the STIG JSON

`stig/nist_800_171r3_stig.json` used r2 titles on r3 IDs. This catalog:

- Drops 33 **withdrawn** r2 IDs (kept in the JSON as if they were still live)
- Adds 24 r3-only requirements, including families **3.15 Planning**, **3.16 SA**, **3.17 SR**
- Retitles / renumbers the rest — MFA is `03.05.03`, time stamps are `03.03.07`, FIM is `03.14.06`

See [gap.md](gap.md).

## Implementability

| Class | Meaning |
| --- | --- |
| `os` | Enforced on the POSIX host (sshd, auditd, faillock, crypto-policies, …) |
| `os_partial` | OS can do a slice; policy, identity, or another system still required |
| `policy` | SSP / process — nistctl will not pretend a sysctl satisfies it |
| `physical` | Facility / media / visitor — out of band for Ansible |
| `withdrawn` | Not a requirement in r3 |

Linux implementations: 72 of 97 active requirements (`os` + `os_partial`).

## Layout

```
r3/
  catalog.json      # 130 entries (97 active + 33 withdrawn)
  gap.json          # reconciliation vs the r2-shaped JSON/CSV
  gap.md
  odps.yml          # organization-defined parameters (edit these)
  nistctl.py        # catalog / gap / odps / playbook / audit / remediate
  ansible/
    site.yml        # generated from catalog.json — regenerate after catalog edits
    ansible.cfg
    inventory.ini.example
    requirements.yml
```

## Use

```bash
cd nist_sp_800_171r3/r3
python3 nistctl.py catalog --impl linux
python3 nistctl.py gap --kind missing_from_legacy
python3 nistctl.py odps --write odps.yml
python3 nistctl.py playbook --out ansible/site.yml
python3 nistctl.py audit --id 03.01.08          # read-only, this host
```

Apply only against a CUI enclave host you intend to overlay:

```bash
cp ansible/inventory.ini.example ansible/inventory.ini
# edit inventory + odps.yml
ansible-galaxy collection install -r ansible/requirements.yml
python3 nistctl.py remediate --check
python3 nistctl.py remediate --apply --id 03.01.08
```

`--apply` is never implied. `--check` is a dry run.

Default ODPs follow CIS Linux L2 and DISA STIG RHEL 9: inactive lock 35 days,
idle 900s, faillock 3 / 900s, password minlen 14, FIPS crypto-policies, chrony.

## Known limits

- Does not satisfy policy, physical, or most of AT / IR / PL / SA / SR. Those stay in the SSP.
- `os_partial` tasks are best-effort (LUKS, usbguard, MFA PAM). Confirm in the lab.
- FIPS (`03.13.08` / `03.13.11`) needs a reboot after `fips-mode-setup --enable`.
- Do not run this overlay on the laptop you use to write it.

Regenerate the playbook after editing `catalog.json`:

```bash
python3 nistctl.py playbook --out ansible/site.yml
```
