#!/usr/bin/env python3
"""Throwaway Rocky 9 QEMU/KVM cluster for the r3 overlay.

Replaces Vagrant/VirtualBox for this tree. Does not touch nist_sp_800_171r3/os/.
Libvirt system URI, isolated NAT 10.17.1.0/24 (inside odp.ssh_allow_cidrs).

    python3 labctl.py up
    python3 labctl.py status
    python3 labctl.py ssh cui-01
    python3 nistctl.py remediate --check --id 03.01.08
    python3 labctl.py destroy
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
R3 = HERE.parent
CLUSTER_PATH = HERE / "cluster.json"
STATE = HERE / ".state"
KEY_PATH = STATE / "id_ed25519"
KNOWN_HOSTS = STATE / "known_hosts"
INVENTORY_PATH = R3 / "ansible" / "inventory.ini"
IMAGE_CACHE = STATE / "Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"

SSH_COMMON = [
    "-o",
    "IdentitiesOnly=yes",
    "-o",
    "StrictHostKeyChecking=accept-new",
    "-o",
    f"UserKnownHostsFile={KNOWN_HOSTS}",
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=5",
]


def load_cluster() -> dict[str, Any]:
    return json.loads(CLUSTER_PATH.read_text())


def uri(cfg: dict[str, Any]) -> str:
    return cfg.get("uri") or "qemu:///system"


def domain_name(node: dict[str, Any]) -> str:
    return f"nist-{node['name']}"


def vol_name(node: dict[str, Any]) -> str:
    return f"nist-{node['name']}.qcow2"


def run(
    cmd: list[str],
    *,
    check: bool = True,
    capture: bool = False,
    quiet: bool = False,
) -> subprocess.CompletedProcess:
    if not quiet:
        print("+", " ".join(cmd), file=sys.stderr)
    return subprocess.run(
        cmd,
        check=check,
        text=True,
        capture_output=capture,
    )


def virsh(cfg: dict[str, Any], *args: str, check: bool = True, capture: bool = False, quiet: bool = False) -> subprocess.CompletedProcess:
    return run(["virsh", "-c", uri(cfg), *args], check=check, capture=capture, quiet=quiet)


def virsh_out(cfg: dict[str, Any], *args: str) -> str:
    proc = virsh(cfg, *args, capture=True, quiet=True, check=False)
    return (proc.stdout or "").strip()


def have_net(cfg: dict[str, Any], name: str) -> bool:
    proc = virsh(cfg, "net-info", name, check=False, capture=True, quiet=True)
    return proc.returncode == 0


def have_vol(cfg: dict[str, Any], name: str) -> bool:
    proc = virsh(cfg, "vol-info", "--pool", cfg["pool"], name, check=False, capture=True, quiet=True)
    return proc.returncode == 0


def have_dom(cfg: dict[str, Any], name: str) -> bool:
    proc = virsh(cfg, "dominfo", name, check=False, capture=True, quiet=True)
    return proc.returncode == 0


def dom_state(cfg: dict[str, Any], name: str) -> str:
    out = virsh_out(cfg, "domstate", name)
    return out.splitlines()[0] if out else "undefined"


def ensure_state_dir() -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    STATE.joinpath(".gitignore").write_text("*\n")


def ensure_ssh_key() -> str:
    ensure_state_dir()
    if not KEY_PATH.exists():
        run(
            [
                "ssh-keygen",
                "-t",
                "ed25519",
                "-N",
                "",
                "-C",
                "nist-lab",
                "-f",
                str(KEY_PATH),
            ]
        )
        KEY_PATH.chmod(0o600)
    return (KEY_PATH.with_suffix(".pub")).read_text().strip()


def http_get(url: str, dest: Path | None = None) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "nist-labctl"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        if dest is None:
            return resp.read()
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(dest.suffix + ".part")
        total = int(resp.headers.get("Content-Length") or 0)
        got = 0
        with tmp.open("wb") as fh:
            while True:
                chunk = resp.read(1024 * 1024)
                if not chunk:
                    break
                fh.write(chunk)
                got += len(chunk)
                if total:
                    pct = got / total * 100
                    print(f"\r  downloading {pct:5.1f}% ({got // (1024 * 1024)} MiB)", end="", flush=True)
        print()
        tmp.replace(dest)
        return b""


def parse_sha256(text: str, filename: str) -> str:
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("SHA256") and filename in line and "=" in line:
            return line.split("=", 1)[1].strip().lower()
        parts = line.split()
        if len(parts) == 2 and len(parts[0]) == 64 and parts[1].endswith(filename):
            return parts[0].lower()
    raise SystemExit(f"no SHA256 for {filename} in checksum file")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_image(cfg: dict[str, Any]) -> Path:
    ensure_state_dir()
    img = cfg["image"]
    filename = Path(img["url"]).name
    if IMAGE_CACHE.exists():
        print(f"cached image {IMAGE_CACHE} ({IMAGE_CACHE.stat().st_size} bytes)", file=sys.stderr)
    else:
        print(f"fetching {img['url']}", file=sys.stderr)
        http_get(img["url"], IMAGE_CACHE)
    checksum_text = http_get(img["checksum_url"]).decode()
    expected = parse_sha256(checksum_text, filename)
    actual = sha256_file(IMAGE_CACHE)
    if actual != expected:
        IMAGE_CACHE.unlink(missing_ok=True)
        raise SystemExit(f"SHA256 mismatch for {filename}: got {actual} want {expected}")
    print(f"image SHA256 ok ({actual[:12]}…)", file=sys.stderr)
    return IMAGE_CACHE


def qemu_virtual_size(path: Path) -> str:
    proc = run(
        ["qemu-img", "info", "--output=json", str(path)],
        capture=True,
        quiet=True,
    )
    info = json.loads(proc.stdout)
    return str(int(info["virtual-size"]))


def ensure_base_vol(cfg: dict[str, Any], image: Path) -> None:
    name = cfg["image"]["base_vol"]
    pool = cfg["pool"]
    if have_vol(cfg, name):
        print(f"base volume {name} exists", file=sys.stderr)
        return
    size = qemu_virtual_size(image)
    virsh(cfg, "vol-create-as", pool, name, size, "--format", "qcow2")
    virsh(cfg, "vol-upload", "--pool", pool, name, str(image))


def net_xml(cfg: dict[str, Any]) -> str:
    net = cfg["network"]
    hosts = "\n".join(
        f'        <host mac="{n["mac"]}" name="{n["name"]}.{cfg["domain"]}" ip="{n["ip"]}"/>'
        for n in cfg["nodes"]
    )
    return f"""<network>
  <name>{net["name"]}</name>
  <forward mode="nat"/>
  <bridge name="{net["bridge"]}" stp="on" delay="0"/>
  <domain name="{cfg["domain"]}"/>
  <ip address="{net["gateway"]}" netmask="{net["netmask"]}">
    <dhcp>
      <range start="{net["dhcp_start"]}" end="{net["dhcp_end"]}"/>
{hosts}
    </dhcp>
  </ip>
</network>
"""


def net_is_active(cfg: dict[str, Any], name: str) -> bool:
    for line in virsh_out(cfg, "net-info", name).splitlines():
        if line.lower().startswith("active:"):
            return line.split(":", 1)[1].strip().lower() == "yes"
    return False


def ensure_network(cfg: dict[str, Any]) -> None:
    name = cfg["network"]["name"]
    xml_path = STATE / "nist-lab-net.xml"
    ensure_state_dir()
    xml_path.write_text(net_xml(cfg))
    if not have_net(cfg, name):
        virsh(cfg, "net-define", str(xml_path))
    if not net_is_active(cfg, name):
        virsh(cfg, "net-start", name)
    virsh(cfg, "net-autostart", name, check=False)
    ensure_host_firewall(cfg)


def ensure_host_firewall(cfg: dict[str, Any]) -> None:
    """UFW default deny INPUT/FORWARD drops libvirt DHCP and guest NAT."""
    ufw = shutil.which("ufw")
    if ufw is None:
        return
    status = run(["sudo", "-n", ufw, "status"], capture=True, check=False, quiet=True)
    if "Status: active" not in (status.stdout or ""):
        return
    bridge = cfg["network"]["bridge"]
    if f"Anywhere on {bridge}" in (status.stdout or "") and "ALLOW FWD" in (status.stdout or ""):
        print(f"ufw already allows {bridge}", file=sys.stderr)
        return
    print(f"opening ufw on {bridge} for the lab NAT", file=sys.stderr)
    run(["sudo", "-n", ufw, "allow", "in", "on", bridge, "comment", "nist-lab qemu guests"], check=False)
    run(["sudo", "-n", ufw, "route", "allow", "in", "on", bridge, "comment", "nist-lab forward in"], check=False)
    run(["sudo", "-n", ufw, "route", "allow", "out", "on", bridge, "comment", "nist-lab forward out"], check=False)


def user_data(cfg: dict[str, Any], node: dict[str, Any], pubkey: str) -> str:
    hosts = "\n".join(f"      {n['ip']} {n['name']} {n['name']}.{cfg['domain']}" for n in cfg["nodes"])
    extra_files = ""
    extra_runcmd = ""
    if node["role"] == "log":
        extra_files = """  - path: /etc/rsyslog.d/99-nist-lab.conf
    permissions: "0644"
    content: |
      module(load="imudp")
      input(type="imudp" port="514")
      module(load="imtcp")
      input(type="imtcp" port="514")
"""
        extra_runcmd = """  - [bash, -lc, "systemctl enable --now rsyslog || true"]
  - [bash, -lc, "firewall-cmd --permanent --add-port=514/tcp --add-port=514/udp && firewall-cmd --reload || true"]
"""
    return f"""#cloud-config
hostname: {node["name"]}
fqdn: {node["name"]}.{cfg["domain"]}
prefer_fqdn_over_hostname: true
manage_etc_hosts: true
users:
  - name: {cfg["ssh_user"]}
    gecos: Ansible
    groups: [wheel]
    shell: /bin/bash
    lock_passwd: true
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - {pubkey}
ssh_pwauth: false
disable_root: true
package_update: false
write_files:
  - path: /etc/hosts.d/nist-lab
    permissions: "0644"
    content: |
{hosts}
{extra_files}runcmd:
  - [bash, -lc, "cat /etc/hosts.d/nist-lab >> /etc/hosts"]
  - [bash, -lc, "systemctl enable --now qemu-guest-agent || true"]
  - [bash, -lc, "systemctl enable --now sshd || true"]
{extra_runcmd}timezone: UTC
ssh_deletekeys: false
"""


def network_config(node: dict[str, Any], gateway: str) -> str:
    # net.ifnames=0 → eth0. DHCP reservations in the libvirt net pin the IP to MAC.
    # Avoid netplan v2 `to: default` — Rocky cloud-init 24.4 treats it as an address.
    _ = gateway
    return f"""version: 2
ethernets:
  eth0:
    match:
      macaddress: "{node["mac"]}"
    dhcp4: true
    dhcp-identifier: mac
"""


def meta_data(cfg: dict[str, Any], node: dict[str, Any]) -> str:
    return f"instance-id: nist-{node['name']}\nlocal-hostname: {node['name']}\n"


def ensure_overlay_vol(cfg: dict[str, Any], node: dict[str, Any]) -> None:
    name = vol_name(node)
    if have_vol(cfg, name):
        print(f"volume {name} exists", file=sys.stderr)
        return
    virsh(
        cfg,
        "vol-create-as",
        cfg["pool"],
        name,
        f"{node['disk_gb']}G",
        "--format",
        "qcow2",
        "--backing-vol",
        cfg["image"]["base_vol"],
        "--backing-vol-format",
        "qcow2",
    )


def cidata_vol(node: dict[str, Any]) -> str:
    return f"nist-{node['name']}-cidata.iso"


def ensure_cidata_vol(cfg: dict[str, Any], node: dict[str, Any], pubkey: str) -> str:
    """Persistent NoCloud ISO. virt-install --cloud-init ISOs are transient and get deleted."""
    if shutil.which("cloud-localds") is None:
        raise SystemExit("cloud-localds not on PATH (cloud-utils / cloud-image-utils)")
    seed = STATE / f"seed-{node['name']}"
    seed.mkdir(parents=True, exist_ok=True)
    ud = seed / "user-data"
    md = seed / "meta-data"
    nd = seed / "network-config"
    iso = seed / "cidata.iso"
    ud.write_text(user_data(cfg, node, pubkey))
    md.write_text(meta_data(cfg, node))
    nd.write_text(network_config(node, cfg["network"]["gateway"]))
    run(["cloud-localds", "--network-config", str(nd), str(iso), str(ud), str(md)])
    vol = cidata_vol(node)
    if have_vol(cfg, vol):
        virsh(cfg, "vol-delete", "--pool", cfg["pool"], vol)
    virsh(cfg, "vol-create-as", cfg["pool"], vol, str(iso.stat().st_size), "--format", "raw")
    virsh(cfg, "vol-upload", "--pool", cfg["pool"], vol, str(iso))
    return vol


def domain_has_cidata(cfg: dict[str, Any], node: dict[str, Any]) -> bool:
    xml = virsh_out(cfg, "dumpxml", domain_name(node))
    return cidata_vol(node) in xml


def domain_is_uefi(cfg: dict[str, Any], node: dict[str, Any]) -> bool:
    xml = virsh_out(cfg, "dumpxml", domain_name(node)).lower()
    return "ovmf" in xml or "firmware='efi'" in xml or 'firmware="efi"' in xml


def undefine_domain(cfg: dict[str, Any], node: dict[str, Any], *, remove_overlay: bool = False) -> None:
    name = domain_name(node)
    if not have_dom(cfg, name):
        return
    if dom_state(cfg, name) == "running":
        virsh(cfg, "destroy", name)
    virsh(cfg, "undefine", name, "--nvram", check=False)
    if have_dom(cfg, name):
        virsh(cfg, "undefine", name, check=False)
    if remove_overlay and have_vol(cfg, vol_name(node)):
        virsh(cfg, "vol-delete", "--pool", cfg["pool"], vol_name(node), check=False)


def create_domain(cfg: dict[str, Any], node: dict[str, Any], pubkey: str) -> None:
    name = domain_name(node)
    if have_dom(cfg, name):
        if domain_has_cidata(cfg, node) and domain_is_uefi(cfg, node):
            if dom_state(cfg, name) != "running":
                virsh(cfg, "start", name)
            else:
                print(f"domain {name} already running", file=sys.stderr)
            return
        print(f"rebuilding {name}: need UEFI + persistent cidata", file=sys.stderr)
        undefine_domain(cfg, node, remove_overlay=True)
    ensure_overlay_vol(cfg, node)
    cidata = ensure_cidata_vol(cfg, node, pubkey)
    virt_install = shutil.which("virt-install")
    if virt_install is None:
        raise SystemExit("virt-install not on PATH")
    serial_log = Path("/var/tmp") / f"nist-{node['name']}.serial.log"
    run(
        [
            virt_install,
            "--connect",
            uri(cfg),
            "--name",
            name,
            "--virt-type",
            "kvm",
            "--os-variant",
            cfg.get("os_variant") or "rocky9",
            "--boot",
            "firmware=efi,useserial=on",
            "--memory",
            str(node["memory_mb"]),
            "--vcpus",
            str(node["vcpus"]),
            "--cpu",
            "host-passthrough",
            "--import",
            "--disk",
            f"vol={cfg['pool']}/{vol_name(node)},bus=virtio,cache=writeback",
            "--disk",
            f"vol={cfg['pool']}/{cidata},device=cdrom,bus=sata",
            "--network",
            f"network={cfg['network']['name']},model=virtio,mac={node['mac']}",
            "--graphics",
            "none",
            "--serial",
            f"file,path={serial_log}",
            "--channel",
            "unix,target_type=virtio,name=org.qemu.guest_agent.0",
            "--rng",
            "/dev/urandom",
            "--noautoconsole",
            "--wait",
            "0",
        ]
    )


def wait_tcp(ip: str, port: int, timeout: int) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((ip, port), 2):
                return
        except OSError:
            time.sleep(2)
    raise SystemExit(f"timeout waiting for {ip}:{port}")


def wait_ssh(cfg: dict[str, Any], node: dict[str, Any], timeout: int = 300) -> None:
    print(f"waiting for ssh {node['name']} {node['ip']}:22", file=sys.stderr)
    wait_tcp(node["ip"], 22, timeout)
    key = str(KEY_PATH)
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        proc = subprocess.run(
            [
                "ssh",
                "-i",
                key,
                *SSH_COMMON,
                "-o",
                "StrictHostKeyChecking=no",
                f"{cfg['ssh_user']}@{node['ip']}",
                "true",
            ],
            capture_output=True,
            text=True,
        )
        if proc.returncode == 0:
            print(f"ssh ready {node['name']}", file=sys.stderr)
            return
        last = (proc.stderr or proc.stdout or "").strip()
        time.sleep(3)
    raise SystemExit(f"ssh to {node['name']} failed: {last}")


def write_inventory(cfg: dict[str, Any]) -> Path:
    key = KEY_PATH.resolve()
    known = KNOWN_HOSTS.resolve()
    lines = [
        "# generated by nist_sp_800_171r3/r3/lab/labctl.py — do not commit",
        "",
        "[cui]",
    ]
    for node in cfg["nodes"]:
        if node["role"] in {"cui", "log"}:
            lines.append(
                f"{node['name']} ansible_host={node['ip']} ansible_user={cfg['ssh_user']}"
            )
    lines += [
        "",
        "[log]",
    ]
    for node in cfg["nodes"]:
        if node["role"] == "log":
            lines.append(
                f"{node['name']} ansible_host={node['ip']} ansible_user={cfg['ssh_user']}"
            )
    ssh_args = (
        f"-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "
        f"-o UserKnownHostsFile={known}"
    )
    lines += [
        "",
        "[cui:vars]",
        "ansible_python_interpreter=/usr/bin/python3",
        "ansible_become=true",
        f"ansible_ssh_private_key_file={key}",
        f"ansible_ssh_common_args={ssh_args}",
        "",
        "[log:vars]",
        "ansible_python_interpreter=/usr/bin/python3",
        "ansible_become=true",
        f"ansible_ssh_private_key_file={key}",
        f"ansible_ssh_common_args={ssh_args}",
        "",
    ]
    text = "\n".join(lines)
    INVENTORY_PATH.write_text(text)
    ensure_state_dir()
    (STATE / "inventory.ini").write_text(text)
    print(f"wrote {INVENTORY_PATH}", file=sys.stderr)
    return INVENTORY_PATH


def cmd_up(args: argparse.Namespace) -> int:
    cfg = load_cluster()
    if shutil.which("virsh") is None or shutil.which("virt-install") is None:
        raise SystemExit("need virsh and virt-install (libvirt + virt-install)")
    if not Path("/dev/kvm").exists():
        raise SystemExit("/dev/kvm missing; KVM is required")
    pubkey = ensure_ssh_key()
    image = ensure_image(cfg)
    ensure_base_vol(cfg, image)
    ensure_network(cfg)
    for node in cfg["nodes"]:
        create_domain(cfg, node, pubkey)
    for node in cfg["nodes"]:
        wait_ssh(cfg, node)
    write_inventory(cfg)
    print()
    print("cluster is up. Next:")
    print(f"  python3 {R3 / 'nistctl.py'} remediate --check --id 03.01.08")
    print(f"  python3 {HERE / 'labctl.py'} ssh cui-01")
    print("Do not --apply on this laptop; these guests are the throwaway overlay target.")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    cfg = load_cluster()
    print(f"{'NODE':<10} {'DOMAIN':<16} {'IP':<14} {'ROLE':<6} STATE")
    for node in cfg["nodes"]:
        name = domain_name(node)
        state = dom_state(cfg, name) if have_dom(cfg, name) else "undefined"
        print(f"{node['name']:<10} {name:<16} {node['ip']:<14} {node['role']:<6} {state}")
    net = cfg["network"]["name"]
    if have_net(cfg, net):
        print()
        print(virsh_out(cfg, "net-info", net))
        leases = virsh_out(cfg, "net-dhcp-leases", net)
        if leases:
            print()
            print(leases)
    return 0


def cmd_ssh(args: argparse.Namespace) -> int:
    cfg = load_cluster()
    node = next((n for n in cfg["nodes"] if n["name"] == args.node), None)
    if node is None:
        names = ", ".join(n["name"] for n in cfg["nodes"])
        raise SystemExit(f"unknown node {args.node!r} (one of: {names})")
    if not KEY_PATH.exists():
        raise SystemExit("no lab key; run labctl.py up first")
    cmd = [
        "ssh",
        "-i",
        str(KEY_PATH),
        *SSH_COMMON,
        f"{cfg['ssh_user']}@{node['ip']}",
    ]
    if args.remote:
        cmd.append(args.remote)
    os.execvp(cmd[0], cmd)
    return 1


def cmd_down(args: argparse.Namespace) -> int:
    cfg = load_cluster()
    for node in cfg["nodes"]:
        name = domain_name(node)
        if have_dom(cfg, name) and dom_state(cfg, name) == "running":
            virsh(cfg, "shutdown", name, check=False)
    deadline = time.time() + 60
    while time.time() < deadline:
        if all(not have_dom(cfg, domain_name(n)) or dom_state(cfg, domain_name(n)) != "running" for n in cfg["nodes"]):
            break
        time.sleep(2)
    for node in cfg["nodes"]:
        name = domain_name(node)
        if have_dom(cfg, name) and dom_state(cfg, name) == "running":
            virsh(cfg, "destroy", name)
    return 0


def cmd_destroy(args: argparse.Namespace) -> int:
    cfg = load_cluster()
    for node in cfg["nodes"]:
        name = domain_name(node)
        if have_dom(cfg, name):
            if dom_state(cfg, name) == "running":
                virsh(cfg, "destroy", name)
            virsh(cfg, "undefine", name, "--nvram", "--remove-all-storage", check=False)
            if have_dom(cfg, name):
                virsh(cfg, "undefine", name, "--remove-all-storage", check=False)
        if have_vol(cfg, vol_name(node)):
            virsh(cfg, "vol-delete", "--pool", cfg["pool"], vol_name(node), check=False)
        # virt-install cloud-init ISO, if left behind
        cidata = f"nist-{node['name']}-cidata.iso"
        if have_vol(cfg, cidata):
            virsh(cfg, "vol-delete", "--pool", cfg["pool"], cidata, check=False)
    if args.image and have_vol(cfg, cfg["image"]["base_vol"]):
        virsh(cfg, "vol-delete", "--pool", cfg["pool"], cfg["image"]["base_vol"])
    if args.network and have_net(cfg, cfg["network"]["name"]):
        virsh(cfg, "net-destroy", cfg["network"]["name"], check=False)
        virsh(cfg, "net-undefine", cfg["network"]["name"], check=False)
    if INVENTORY_PATH.exists():
        INVENTORY_PATH.unlink()
        print(f"removed {INVENTORY_PATH}", file=sys.stderr)
    return 0


def cmd_inventory(args: argparse.Namespace) -> int:
    cfg = load_cluster()
    path = write_inventory(cfg)
    sys.stdout.write(path.read_text())
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="labctl", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    u = sub.add_parser("up", help="create network, volumes, VMs; wait for SSH; write inventory")
    u.set_defaults(func=cmd_up)

    s = sub.add_parser("status", help="show domain state and DHCP leases")
    s.set_defaults(func=cmd_status)

    sh = sub.add_parser("ssh", help="ssh to a node as the ansible user")
    sh.add_argument("node")
    sh.add_argument("remote", nargs="?", help="optional remote command")
    sh.set_defaults(func=cmd_ssh)

    d = sub.add_parser("down", help="ACPI shutdown (keep disks)")
    d.set_defaults(func=cmd_down)

    x = sub.add_parser("destroy", help="undefine VMs and delete overlay disks")
    x.add_argument("--image", action="store_true", help="also delete the cached libvirt base volume")
    x.add_argument("--network", action="store_true", help="also destroy the nist-lab NAT network")
    x.set_defaults(func=cmd_destroy)

    i = sub.add_parser("inventory", help="rewrite ansible/inventory.ini from cluster.json")
    i.set_defaults(func=cmd_inventory)
    return p


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as exc:
        print(exc, file=sys.stderr)
        sys.exit(exc.returncode or 1)
