# r3 catalog vs `nist_800_171r3_stig.json`

The extraction in `stig/` is 97 items with r2 titles glued onto r3 IDs. It is a
useful command scrapbook. It is not a faithful SP 800-171r3 catalog.

Counts from `gap.json`:

| Kind | N | Meaning |
| --- | ---: | --- |
| aligned | 30 | Same ID, same intent |
| retitled | 25 | Same ID, r3 title/statement drifted |
| renumbered | 18 | Intent survived under a different r3 ID |
| withdrawn_kept | 31 | r2 ID withdrawn in r3, still listed as live |
| missing_from_legacy | 24 | Active r3 requirement absent from the JSON/CSV |

## Withdrawn in r3, still in the JSON

`03.01.13` `03.01.14` `03.01.15` `03.01.17` `03.01.19` `03.01.21`
`03.02.03`
`03.03.09`
`03.04.07` `03.04.09`
`03.05.06` `03.05.08` `03.05.09` `03.05.10`
`03.07.01` `03.07.02` `03.07.03`
`03.08.06`
`03.10.03` `03.10.04` `03.10.05`
`03.11.03`
`03.12.04`
`03.13.02` `03.13.03` `03.13.05` `03.13.07` `03.13.14` `03.13.16`
`03.14.04` `03.14.05` `03.14.07`

Playbook tags that still use these IDs will map to nothing in an r3 assessment.

## Missing from the extraction (add)

`03.04.10` System Component Inventory
`03.04.11` Information Location
`03.04.12` High-Risk Areas
`03.05.12` Authenticator Management
`03.06.04` Incident Response Training
`03.06.05` Incident Response Plan
`03.07.06` Maintenance Personnel
`03.08.07` Media Use
`03.08.09` System Backup — Cryptographic Protection
`03.10.07` Alternate Work Site
`03.10.08` Access Records
`03.11.04` Risk Response
`03.12.05` Information Exchange
`03.13.09` Network Disconnect
`03.14.08` Information Management
Entire **3.15 Planning** (`03.15.01`–`03.15.03`)
Entire **3.16 System and Services Acquisition** (`03.16.01`–`03.16.03`)
Entire **3.17 Supply Chain Risk Management** (`03.17.01`–`03.17.03`)

## Dangerous retitles (the playbook is tagging the wrong control)

| Extraction | What it thought it was | r3 actually is |
| --- | --- | --- |
| `03.03.03` | Audit review | Audit Record Generation |
| `03.03.07` | (was time stamps in r2 as 3.3.7 — confirm) | Time Stamps |
| `03.05.02` | MFA | Device Identification and Authentication |
| `03.05.03` | (was replay) | Multifactor Authentication |
| `03.05.11` | Password encryption | Authentication Feedback |
| `03.13.12` | Wireless / USB in comments | Collaborative Computing Devices |
| `03.13.13` | Mobile code vs USB | Mobile Code |
| `03.13.15` | Session authenticity (nginx comment said 03.13.11) | Session Authenticity |
| `03.14.06` | FIM / AIDE | System Monitoring |
| `03.14.07` | AIDE in the old playbook | **Withdrawn** |

## Overlay notes vs `os/nist_full_remediate.yml`

- `shadow` mode `000` is correct for RHEL; keep it.
- `google-authenticator` is not FIPS; r3 MFA (`03.05.03`) wants a FIPS authenticator (PAM u2f / sssd / PIV).
- SSH cipher lists belong under `03.13.08` / `03.13.11` (cryptographic protection), not wireless.
- `usb_storage` blacklist is `03.08.07` Media Use and `03.01.18` mobile, not 03.13.12.
- Telemetry POST to a placeholder URL is not an r3 requirement; drop it from the overlay.
- Banner / TMOUT / faillock / auditd / chrony / firewalld / AIDE survive, retagged.

The r3 playbook is generated from `catalog.json` by `nistctl.py playbook`. Do not
hand-edit `ansible/site.yml` — edit the catalog or ODPs and regenerate.
