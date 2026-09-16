#!/usr/bin/env python3
"""nistctl — NIST SP 800-171r3 Linux hardening middleware.

Catalog-driven. Does not invent controls: every audit command and Ansible
task is sourced from catalog.json (SP 800-171 Revision 3, May 2024).

    nistctl catalog [--family AC] [--impl linux]
    nistctl gap [--kind missing_from_legacy]
    nistctl odps [--write odps.yml]
    nistctl playbook [--out ansible/site.yml]
    nistctl audit [--id 03.01.08]          # read-only local checks
    nistctl remediate [--id 03.01.08] --check
    nistctl remediate --apply              # runs ansible-playbook; never the default

Target: Rocky Linux 9 / RHEL 9 family. Review ODPs before apply.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
CATALOG_PATH = HERE / "catalog.json"
GAP_PATH = HERE / "gap.json"
ODPS_PATH = HERE / "odps.yml"

MODULE = {
    "lineinfile": "ansible.builtin.lineinfile",
    "copy": "ansible.builtin.copy",
    "command": "ansible.builtin.command",
    "service": "ansible.builtin.service",
    "blockinfile": "ansible.builtin.blockinfile",
    "file": "ansible.builtin.file",
    "package": "ansible.builtin.dnf",
    "ini_file": "community.general.ini_file",
    "selinux": "ansible.posix.selinux",
    "sysctl": "ansible.posix.sysctl",
    "group": "ansible.builtin.group",
    "replace": "ansible.builtin.replace",
    "timezone": "community.general.timezone",
    "systemd": "ansible.builtin.systemd",
    "shell": "ansible.builtin.shell",
}

# Machine values that make the Ansible templates valid (ints, not "35 days").
MACHINE_ODPS: dict[str, Any] = {
    "inactive_days": 35,
    "notify_period": "24h",
    "logout_inactivity": 900,
    "idle_seconds": 900,
    "priv_review": "90d",
    "sec_functions": "account mgmt, sudoers, auditd, firewall, crypto keys, package install",
    "priv_roles": "wheel",
    "faillock_deny": 3,
    "faillock_interval": 900,
    "faillock_unlock": 900,
    "banner": "This system processes CUI. Unauthorized use is prohibited. Use may be monitored.",
    "session_events": "900s idle; end of shift; incident lockout",
    "max_auth_tries": 3,
    "client_alive": 300,
    "ext_reqs": "Same 800-171r3 overlay; no CUI on unmanaged endpoints",
    "ssh_allow_cidrs": "10.0.0.0/8",
    "syslog_server": "127.0.0.1",
    "password_min_len": 14,
    "audit_retain_days": 90,
    "net_idle": 900,
}


def load_catalog() -> list[dict]:
    if not CATALOG_PATH.exists():
        sys.exit(f"missing {CATALOG_PATH}")
    return json.loads(CATALOG_PATH.read_text())


def load_gap() -> list[dict]:
    if not GAP_PATH.exists():
        sys.exit(f"missing {GAP_PATH}")
    return json.loads(GAP_PATH.read_text())


def yaml_scalar(value: Any) -> str:
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "null"
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return str(value)
    s = str(value)
    if s == "" or any(ch in s for ch in ":#[]{}&*!|>%@`'\n,") or s.lower() in {
        "true",
        "false",
        "yes",
        "no",
        "on",
        "off",
    }:
        return json.dumps(s)
    return s


def yaml_block(text: str, indent: int) -> str:
    pad = " " * indent
    body = "\n".join(pad + line for line in text.replace("\n", "\n").rstrip("\n").split("\n"))
    return "|\n" + body


def yaml_dump(value: Any, indent: int) -> str:
    if isinstance(value, dict):
        if not value:
            return "{}"
        parts = []
        pad = " " * indent
        for k, v in value.items():
            if isinstance(v, str) and "\n" in v:
                parts.append(f"{pad}{k}: {yaml_block(v, indent + 2)}")
            elif isinstance(v, (dict, list)):
                nested = yaml_dump(v, indent + 2)
                if nested.startswith("{") or nested.startswith("["):
                    parts.append(f"{pad}{k}: {nested}")
                else:
                    parts.append(f"{pad}{k}:\n{nested}")
            else:
                parts.append(f"{pad}{k}: {yaml_scalar(v)}")
        return "\n".join(parts)
    if isinstance(value, list):
        if not value:
            return "[]"
        pad = " " * indent
        parts = []
        for item in value:
            if isinstance(item, (dict, list)):
                nested = yaml_dump(item, indent + 2)
                first, _, rest = nested.partition("\n")
                if rest:
                    parts.append(f"{pad}- {first.lstrip()}\n{rest}")
                else:
                    parts.append(f"{pad}- {first.lstrip()}")
            else:
                parts.append(f"{pad}- {yaml_scalar(item)}")
        return "\n".join(parts)
    if isinstance(value, str) and "\n" in value:
        return yaml_block(value, indent)
    return yaml_scalar(value)


def cmd_catalog(args: argparse.Namespace) -> int:
    rows = load_catalog()
    if args.family:
        rows = [c for c in rows if c["family"] == args.family.upper()]
    if args.impl == "linux":
        rows = [c for c in rows if c.get("linux")]
    elif args.impl:
        rows = [c for c in rows if c["implementability"] == args.impl]
    if args.status:
        rows = [c for c in rows if c["status"] == args.status]
    if args.json:
        json.dump(rows, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0
    print(f"{'ID':<10} {'IMPL':<12} {'TITLE'}")
    for c in rows:
        print(f"{c['id']:<10} {c['implementability']:<12} {c['title']}")
    print(f"# {len(rows)} requirement(s)", file=sys.stderr)
    return 0


def cmd_gap(args: argparse.Namespace) -> int:
    rows = load_gap()
    if args.kind:
        rows = [g for g in rows if g["kind"] == args.kind]
    if args.json:
        json.dump(rows, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0
    print(f"{'ID':<10} {'KIND':<22} {'R3':<42} {'LEGACY'}")
    for g in rows:
        r3 = (g.get("r3Title") or "—")[:40]
        legacy = (g.get("legacyTitle") or "—")[:40]
        print(f"{g['id']:<10} {g['kind']:<22} {r3:<42} {legacy}")
    print(f"# {len(rows)} row(s)", file=sys.stderr)
    return 0


def flatten_odps(catalog: list[dict]) -> dict[str, Any]:
    out = dict(MACHINE_ODPS)
    for c in catalog:
        for o in c.get("odps") or []:
            oid = o["id"]
            if oid not in out:
                out[oid] = o.get("defaultValue")
    return out


def render_odps_yaml(odps: dict[str, Any]) -> str:
    lines = [
        "# Organization-defined parameters for NIST SP 800-171r3",
        "# CIS Linux L2 / DISA STIG RHEL 9 aligned where the publication leaves an ODP.",
        "# Edit, then pass to ansible via vars_files.",
        "odp:",
    ]
    for k, v in odps.items():
        lines.append(f"  {k}: {yaml_scalar(v)}")
    lines.append("")
    return "\n".join(lines)


def cmd_odps(args: argparse.Namespace) -> int:
    odps = flatten_odps(load_catalog())
    text = render_odps_yaml(odps)
    if args.write:
        Path(args.write).write_text(text)
        print(f"wrote {args.write}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


def render_playbook(catalog: list[dict], ids: list[str] | None) -> str:
    want = set(ids) if ids else None
    tasks: list[str] = []
    for c in catalog:
        linux = c.get("linux") or {}
        if want and c["id"] not in want:
            continue
        for step in linux.get("remediate") or []:
            fqcn = MODULE.get(step["module"], f"ansible.builtin.{step['module']}")
            tags = [c["id"], c["family"], c["implementability"]]
            args = dict(step.get("args") or {})
            src = args.get("src")
            if isinstance(src, str) and src and "/" not in src:
                args["src"] = "{{ playbook_dir }}/files/" + src
            args_yaml = yaml_dump(args, 8)
            notes = ""
            if step.get("notes"):
                notes = f"\n        # {step['notes'].replace(chr(10), ' ')}"
            task = (
                f'    - name: "{c["id"]} {c["title"]} — {step["title"]}"\n'
                f"      tags: [{', '.join(yaml_scalar(t) for t in tags)}]{notes}\n"
                f"      {fqcn}:\n{args_yaml}"
            )
            tasks.append(task)
    body = "\n\n".join(tasks) if tasks else "    - name: nothing to do\n      ansible.builtin.debug:\n        msg: no remediations matched"
    return f"""---
# NIST SP 800-171r3 Linux overlay — generated by nistctl from catalog.json
# Target: Rocky Linux 9 / RHEL 9 family. Review ODPs. Do not apply blindly.
#
#   ansible-galaxy collection install -r ansible/requirements.yml
#   ansible-playbook -i ansible/inventory.ini ansible/site.yml --check
#   ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags 03.01.08

- name: nistctl 800-171r3 overlay
  hosts: cui
  become: true
  gather_facts: true
  vars_files:
    - "{{{{ playbook_dir }}}}/../odps.yml"
  tasks:
{body}
"""


def cmd_playbook(args: argparse.Namespace) -> int:
    catalog = load_catalog()
    ids = args.id if args.id else None
    text = render_playbook(catalog, ids)
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
        print(f"wrote {out} ({text.count(chr(10))} lines)", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


def run_check(command: str) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            ["bash", "-lc", command],
            capture_output=True,
            text=True,
            timeout=20,
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        return proc.returncode, out.strip()[:400]
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    except OSError as exc:
        return 1, str(exc)


def cmd_audit(args: argparse.Namespace) -> int:
    """Read-only. Never writes. Interprets a non-zero command as fail, not as proof of non-compliance."""
    catalog = load_catalog()
    results = []
    for c in catalog:
        if args.id and c["id"] not in args.id:
            continue
        linux = c.get("linux") or {}
        for chk in linux.get("audit") or []:
            rc, observed = run_check(chk["command"])
            item = {
                "id": c["id"],
                "check": chk["id"],
                "title": chk["title"],
                "command": chk["command"],
                "expect": chk["expect"],
                "rc": rc,
                "observed": observed,
                "verdict": "pass" if rc == 0 else "fail",
            }
            results.append(item)
    if args.json:
        json.dump(results, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print(f"{'ID':<10} {'CHECK':<14} {'RC':<4} {'VERDICT':<6} TITLE")
        for r in results:
            print(f"{r['id']:<10} {r['check']:<14} {r['rc']:<4} {r['verdict']:<6} {r['title']}")
    failed = sum(1 for r in results if r["verdict"] == "fail")
    print(f"# {len(results)} checks, {failed} non-zero", file=sys.stderr)
    return 1 if failed else 0


def cmd_remediate(args: argparse.Namespace) -> int:
    playbook = HERE / "ansible" / "site.yml"
    if not playbook.exists():
        playbook.parent.mkdir(parents=True, exist_ok=True)
        playbook.write_text(render_playbook(load_catalog(), args.id))
    ansible = shutil.which("ansible-playbook")
    inventory = HERE / "ansible" / "inventory.ini"
    cmd = ["ansible-playbook", "-i", str(inventory if inventory.exists() else "localhost,"), str(playbook)]
    if not args.apply:
        cmd.append("--check")
    if args.id:
        cmd.extend(["--tags", ",".join(args.id)])
    if args.limit:
        cmd.extend(["--limit", args.limit])
    print(" ".join(cmd), file=sys.stderr)
    if ansible is None:
        print("ansible-playbook not on PATH. Install ansible-core, then rerun.", file=sys.stderr)
        return 2
    if not args.apply and not args.check:
        print("refusing to change the host: pass --check (dry-run) or --apply.", file=sys.stderr)
        return 2
    env = os.environ.copy()
    return subprocess.call(cmd, env=env)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="nistctl", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("catalog", help="list r3 requirements")
    c.add_argument("--family")
    c.add_argument("--impl", choices=["os", "os_partial", "policy", "physical", "withdrawn", "linux"])
    c.add_argument("--status", choices=["active", "withdrawn"])
    c.add_argument("--json", action="store_true")
    c.set_defaults(func=cmd_catalog)

    g = sub.add_parser("gap", help="r3 vs the r2-shaped STIG JSON")
    g.add_argument("--kind", choices=["aligned", "retitled", "renumbered", "withdrawn_kept", "missing_from_legacy", "legacy_only"])
    g.add_argument("--json", action="store_true")
    g.set_defaults(func=cmd_gap)

    o = sub.add_parser("odps", help="print or write organization-defined parameters")
    o.add_argument("--write")
    o.set_defaults(func=cmd_odps)

    pb = sub.add_parser("playbook", help="emit Ansible from the catalog")
    pb.add_argument("--out")
    pb.add_argument("--id", action="append")
    pb.set_defaults(func=cmd_playbook)

    a = sub.add_parser("audit", help="run read-only local checks")
    a.add_argument("--id", action="append")
    a.add_argument("--json", action="store_true")
    a.set_defaults(func=cmd_audit)

    r = sub.add_parser("remediate", help="dry-run or apply the overlay via Ansible")
    r.add_argument("--id", action="append")
    r.add_argument("--limit")
    r.add_argument("--check", action="store_true", help="ansible --check (default unless --apply)")
    r.add_argument("--apply", action="store_true", help="make changes; never implied")
    r.set_defaults(func=cmd_remediate)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args) or 0)


if __name__ == "__main__":
    sys.exit(main())
