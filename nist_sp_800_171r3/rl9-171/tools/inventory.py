#!/usr/bin/env python3
"""Maintain inventory/hosts.yml across more than one VM.

vm/build-vm.sh used to write the inventory whole, so building a second VM
silently dropped the first. This adds and removes hosts instead, and keeps
the one piece of cross-host wiring the overlay needs: a CUI node forwards its
audit records to the log collector (03.03.05c), which it cannot know the
address of until the collector exists.

    ./tools/inventory.py add rl9-cui-01 --ip 10.0.0.10 --role cui
    ./tools/inventory.py add rl9-log-01 --ip 10.0.0.11 --role log
    ./tools/inventory.py add byo-rl9-02 --ip 192.168.171.142 --user byoadmin \
        --connection byo
    ./tools/inventory.py remove rl9-cui-01
    ./tools/inventory.py check rl9-cui-01     could it be added? (exit 1 if not)
    ./tools/inventory.py show

Roles:
    cui   a host the overlay hardens, forwarding its records to the collector
    log   the collector. Also a CUI host - it stores audit records, so it is
          hardened by the same overlay - and additionally receives.

Connections:
    lab   a host vm/build-vm.sh built: the lab key, sudo password and
          known_hosts under .secrets/ (the default).
    byo   a host you already have (vm/byo-guest.sh, or real hardware): the
          operator's own key (--key, default ~/.ssh/id_rsa), the sudo
          password from NIST_BECOME_PASSWORD, and the operator's known_hosts.
          Nothing is read from .secrets/.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("error: PyYAML required (pip install pyyaml)")

ROOT = Path(__file__).resolve().parent.parent
# NIST_INVENTORY selects the file, as it does for apply.sh and verify.sh
# (lib/inventory-env.sh): one inventory per lab, each with its own collector.
_inv = os.environ.get("NIST_INVENTORY", "inventory/hosts.yml")
INVENTORY = Path(_inv) if os.path.isabs(_inv) else ROOT / _inv

HEADER = """\
# Managed by tools/inventory.py (vm/build-vm.sh calls it).
#
# cui_hosts   every host the overlay hardens; site.yml's first play targets it
# log_hosts   the subset that also receives forwarded records (03.03.05c).
#             A collector is a CUI host too: it stores audit records.
#
# nist_log_collector is set on the forwarders, not by hand. Adding or removing
# a log host rewires it.
"""

CONNECTIONS = {}
CONNECTIONS["lab"] = {
    "ansible_ssh_private_key_file": "{{ playbook_dir }}/.secrets/id_rsa",
    "ansible_become": True,
    "ansible_become_method": "sudo",
    "ansible_become_password":
        "{{ lookup('file', playbook_dir + '/.secrets/admin_password') | trim }}",
    "ansible_ssh_common_args":
        "-o StrictHostKeyChecking=yes "
        "-o UserKnownHostsFile={{ playbook_dir }}/.secrets/known_hosts",
}
CONNECTIONS["byo"] = {
    "ansible_become": True,
    "ansible_become_method": "sudo",
    "ansible_become_password": "{{ lookup('env', 'NIST_BECOME_PASSWORD') }}",
}


def load() -> dict:
    if not INVENTORY.exists():
        return {"cui_hosts": {"hosts": {}}}
    data = yaml.safe_load(INVENTORY.read_text()) or {}
    data.setdefault("cui_hosts", {}).setdefault("hosts", {})
    return data


def rewire(data: dict) -> None:
    """Point every forwarder at the collector; the collector forwards nowhere.

    Forwarding to yourself is not correlation across repositories, and it
    would loop records back through rsyslog, so the collector is excluded.
    """
    cui = data.get("cui_hosts", {}).get("hosts", {}) or {}
    logs = (data.get("log_hosts") or {}).get("hosts", {}) or {}

    collector = None
    if logs:
        name = sorted(logs)[0]
        collector = (cui.get(name) or logs.get(name) or {}).get("ansible_host")
        if len(logs) > 1:
            print(f"warn: {len(logs)} log hosts; forwarding to {name}",
                  file=sys.stderr)

    for name, host in cui.items():
        if collector and name not in logs:
            # 6514/tcp over TLS with mutual x509 authentication (the roles'
            # default, nist_log_tls). `make pki` mints the lab certificates;
            # set nist_log_tls: false in the inventory for plain 514.
            host["nist_log_collector"] = f"{collector}:6514"
        else:
            host.pop("nist_log_collector", None)


def save(data: dict) -> None:
    for group in list(data):
        if not (data[group] or {}).get("hosts"):
            if group != "cui_hosts":
                del data[group]
    INVENTORY.parent.mkdir(parents=True, exist_ok=True)
    INVENTORY.write_text(HEADER + yaml.safe_dump(data, sort_keys=True,
                                                 default_flow_style=False))


def conflict(data: dict, name: str, connection: str):
    """Why `connection` host `name` cannot join this inventory, or None.

    One connection kind per inventory: a second SSH factor serves one lab
    (lib/inventory-env.sh refuses a mixed inventory)."""
    kinds = {("lab" if ".secrets/" in str(h.get("ansible_ssh_private_key_file", "")) else "byo")
             for n, h in data["cui_hosts"]["hosts"].items() if n != name}
    if kinds and kinds != {connection}:
        where = INVENTORY.relative_to(ROOT) if INVENTORY.is_relative_to(ROOT) else INVENTORY
        return (f"error: {where} holds {kinds.pop()} hosts; add this {connection} host to its own "
                "inventory (NIST_INVENTORY=inventory/<lab>.yml)")
    return None


def cmd_check(args) -> int:
    msg = conflict(load(), args.name, args.connection)
    if msg:
        print(msg, file=sys.stderr)
        return 1
    return 0


def cmd_add(args) -> int:
    data = load()
    host = dict(CONNECTIONS[args.connection])
    if args.connection == "byo":
        host["ansible_ssh_private_key_file"] = args.key
    host["ansible_host"] = args.ip
    host["ansible_user"] = args.user

    msg = conflict(data, args.name, args.connection)
    if msg:
        sys.exit(msg)
    data["cui_hosts"]["hosts"][args.name] = host
    if args.role == "log":
        data.setdefault("log_hosts", {}).setdefault("hosts", {})[args.name] = None
    elif (data.get("log_hosts") or {}).get("hosts"):
        # Re-adding an existing host as `cui` demotes it out of log_hosts.
        data["log_hosts"]["hosts"].pop(args.name, None)

    rewire(data)
    save(data)
    print(f"{args.name} ({args.role}) -> {INVENTORY.relative_to(ROOT)}")
    return 0


def cmd_remove(args) -> int:
    data = load()
    gone = data["cui_hosts"]["hosts"].pop(args.name, None) is not None
    if (data.get("log_hosts") or {}).get("hosts"):
        data["log_hosts"]["hosts"].pop(args.name, None)
    if not gone:
        print(f"{args.name} was not in the inventory", file=sys.stderr)
    rewire(data)
    save(data)
    return 0


def cmd_show(args) -> int:
    data = load()
    cui = data["cui_hosts"]["hosts"]
    logs = (data.get("log_hosts") or {}).get("hosts", {}) or {}
    if not cui:
        print("no hosts")
        return 0
    for name in sorted(cui):
        h = cui[name] or {}
        role = "log" if name in logs else "cui"
        fwd = h.get("nist_log_collector", "-")
        print(f"  {name:<16} {h.get('ansible_host', '?'):<16} {role:<4} "
              f"forwards to {fwd}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("add", help="add or update a host")
    a.add_argument("name")
    a.add_argument("--ip", required=True)
    a.add_argument("--user", default="cuiadmin")
    a.add_argument("--role", choices=("cui", "log"), default="cui")
    a.add_argument("--connection", choices=sorted(CONNECTIONS), default="lab")
    a.add_argument("--key", default="~/.ssh/id_rsa",
                   help="private key for --connection byo")
    a.set_defaults(fn=cmd_add)

    c = sub.add_parser("check", help="exit 1 if the host could not be added "
                       "(the inventory holds the other lab's hosts)")
    c.add_argument("name")
    c.add_argument("--connection", choices=sorted(CONNECTIONS), default="lab")
    c.set_defaults(fn=cmd_check)

    r = sub.add_parser("remove", help="remove a host")
    r.add_argument("name")
    r.set_defaults(fn=cmd_remove)

    s = sub.add_parser("show", help="list hosts and their forwarding")
    s.set_defaults(fn=cmd_show)

    args = p.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
