#!/usr/bin/env python3
"""Maintain inventory/hosts.yml across more than one VM.

vm/build-vm.sh used to write the inventory whole, so building a second VM
silently dropped the first. This adds and removes hosts instead, and keeps
the one piece of cross-host wiring the overlay needs: a CUI node forwards its
audit records to the log collector (03.03.05c), which it cannot know the
address of until the collector exists.

    ./nist inventory add rl9-cui-01 --ip 10.0.0.10 --role cui
    ./nist inventory add rl9-log-01 --ip 10.0.0.11 --role log
    ./nist inventory add byo-rl9-02 --ip 192.168.171.142 --user byoadmin \
        --connection byo
    ./nist inventory remove rl9-cui-01
    ./nist inventory check rl9-cui-01     could it be added? (exit 1 if not)
    ./nist inventory show

Roles:
    cui   a host the overlay hardens, forwarding its records to the collector
    log   the collector. Also a CUI host - it stores audit records, so it is
          hardened by the same overlay - and additionally receives.

Connections:
    lab   a host vm/build-vm.sh built: the lab key, admin password (for
          sudo and as the SSH password factor, which ansible answers itself)
          and known_hosts under .secrets/ (the default).
    byo   a host you already have (vm/byo-guest.sh, or real hardware): the
          operator's own key (--key, default ~/.ssh/id_rsa) and known_hosts;
          the passwords come from the inventory's vault,
          inventory/NAME.vault.yml (tools/vault.sh; TASKS C3), never from the
          environment. Nothing is read from .secrets/.

Runs in the control-plane container, entering it when started outside.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

# The tool runs only in its container (TASKS C2): from outside, run this again
# inside, through ./nist, as lib/container.sh does for the shell tools.
if not os.environ.get("NIST_IN_CONTAINER"):
    _nist = str(Path(__file__).resolve().parent.parent / "nist")
    os.execv(_nist, [_nist, os.path.abspath(sys.argv[0])] + sys.argv[1:])

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
    # The SSH password factor (03.05.03), answered by ansible itself: it hands
    # the password to ssh through shared memory, so no askpass script and no
    # environment carries it.
    "ansible_password":
        "{{ lookup('file', playbook_dir + '/.secrets/admin_password') | trim }}",
    "ansible_ssh_common_args":
        "-o StrictHostKeyChecking=yes "
        "-o UserKnownHostsFile={{ playbook_dir }}/.secrets/known_hosts",
}
CONNECTIONS["byo"] = {
    "ansible_become": True,
    "ansible_become_method": "sudo",
    # No passwords here: a host variable would outrank the vault's group
    # variables (ansible_become_password, ansible_password).
}
LEGACY_BECOME = "{{ lookup('env', 'NIST_BECOME_PASSWORD') }}"


def load() -> dict:
    if not INVENTORY.exists():
        return {"cui_hosts": {"hosts": {}}}
    data = yaml.safe_load(INVENTORY.read_text()) or {}
    data.setdefault("cui_hosts", {}).setdefault("hosts", {})
    # Inventories written before the vault (TASKS C3): a BYO host's password
    # from the environment would shadow the vault's, and a lab host lacked
    # the SSH password ansible now answers itself.
    for host in data["cui_hosts"]["hosts"].values():
        if not host:
            continue
        if host.get("ansible_become_password") == LEGACY_BECOME:
            del host["ansible_become_password"]
        if ".secrets/" in str(host.get("ansible_ssh_private_key_file", "")):
            host.setdefault("ansible_password", CONNECTIONS["lab"]["ansible_password"])
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


# After 03.13.11 the host's FIPS policy accepts RSA of 3072 bits or more and
# ECDSA P-256/384, and nothing else: an ed25519 key that works today stops
# working at the first apply, and the next login is the console's.
FIPS_KEY_HINT = ("the FIPS policy the role enforces accepts RSA >= 3072 and ECDSA "
                 "P-256/384 only: an ed25519 or short RSA key would lock you out after "
                 "the first apply. Make one: ./nist ssh-keygen -t rsa -b 3072")


def fips_ok(pubkey_line: str) -> bool:
    import subprocess
    kind = pubkey_line.split()[0] if pubkey_line.split() else ""
    if kind in ("ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384"):
        return True
    if kind != "ssh-rsa":
        return False
    out = subprocess.run(["ssh-keygen", "-lf", "-"], input=pubkey_line, capture_output=True, text=True).stdout
    return bool(out) and int(out.split()[0]) >= 3072


def key_file(path: str) -> None:
    """A private key the container can read, of a type the hardened host accepts."""
    p = Path(os.path.expanduser(path))
    if not p.exists():
        sys.exit(f"error: {path} is not visible inside the container, which sees ~/.ssh, "
                 "the repository and the BYO lab directory: put the key in ~/.ssh, or "
                 "ssh-add it on the host and use --key agent")
    pub = Path(str(p) + ".pub")
    if pub.exists() and not fips_ok(pub.read_text()):
        sys.exit(f"error: {path}: {FIPS_KEY_HINT}")


def agent_key() -> None:
    """The host's agent (./nist forwards it) holds a key the hardened host accepts."""
    import subprocess
    if not os.environ.get("SSH_AUTH_SOCK"):
        sys.exit("error: --key agent, but no SSH agent reached the container: run ssh-agent "
                 "on the host, ssh-add the key, and run ./nist from that shell")
    keys = subprocess.run(["ssh-add", "-L"], capture_output=True, text=True).stdout.splitlines()
    if not any(fips_ok(k) for k in keys):
        sys.exit(f"error: the SSH agent holds no key it can use: {FIPS_KEY_HINT}")


def forget_host_key(ip: str, connection: str) -> None:
    """Adding a host is the moment its key is trusted: an older key recorded
    for the address - a machine reinstalled, or a lab address handed out
    again - is forgotten, and the next connection records the current one
    (lib/ssh-env.sh). Kept, it made StrictHostKeyChecking refuse the host
    with "REMOTE HOST IDENTIFICATION HAS CHANGED", and the operator had to
    run ssh-keygen -R by hand."""
    import subprocess
    kh = ROOT / ".secrets" / "known_hosts" if connection == "lab" else Path.home() / ".ssh" / "known_hosts"
    if not kh.exists():
        return
    if subprocess.run(["ssh-keygen", "-F", ip, "-f", str(kh)], capture_output=True).returncode == 0:
        subprocess.run(["ssh-keygen", "-R", ip, "-f", str(kh)], capture_output=True)
        Path(str(kh) + ".old").unlink(missing_ok=True)   # ssh-keygen's copy, the old key in it
        print(f"forgot the host key recorded for {ip} in {kh}; the next connection records its current one")


def cmd_add(args) -> int:
    data = load()
    host = dict(CONNECTIONS[args.connection])
    if args.connection == "byo":
        if args.key == "agent":
            agent_key()           # no key file: ssh takes it from the agent
        else:
            key_file(args.key)
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
    forget_host_key(args.ip, args.connection)
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


def cmd_tidy(args) -> int:
    """Rewrite the inventory if load() migrated anything; quiet otherwise."""
    if not INVENTORY.exists():
        return 0
    before = yaml.safe_load(INVENTORY.read_text()) or {}
    data = load()
    if data != before:
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
                   help="private key for --connection byo: a file under ~/.ssh, or "
                        "'agent' for one the host's SSH agent holds")
    a.set_defaults(fn=cmd_add)

    c = sub.add_parser("check", help="exit 1 if the host could not be added "
                       "(the inventory holds the other lab's hosts)")
    c.add_argument("name")
    c.add_argument("--connection", choices=sorted(CONNECTIONS), default="lab")
    c.set_defaults(fn=cmd_check)

    r = sub.add_parser("remove", help="remove a host")
    r.add_argument("name")
    r.set_defaults(fn=cmd_remove)

    t = sub.add_parser("tidy", help="bring an older inventory up to date (lib/inventory-env.sh runs it)")
    t.set_defaults(fn=cmd_tidy)

    s = sub.add_parser("show", help="list hosts and their forwarding")
    s.set_defaults(fn=cmd_show)

    args = p.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
