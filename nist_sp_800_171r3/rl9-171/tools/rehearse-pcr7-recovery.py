#!/usr/bin/env python3
"""Rehearse the recovery when the TPM stops releasing the LUKS keys.

    tools/rehearse-pcr7-recovery.py HOST

The CUI volumes are sealed to PCR 7, the Secure Boot state (DEFECTS 6b.5). A
firmware or Secure Boot update changes it, and at the next boot the TPM
refuses. This makes that happen for real, on a lab guest, then walks the
RUNBOOK's recovery ("When you are locked out"):

  1. PCR 7 changes: the guest starts with a UEFI variable store that has no
     Secure Boot keys (Secure Boot off) - the boot entries go with it, and
     shim's fallback recreates them.
  2. Boot stops at the passphrase prompt for each CUI volume (it must not
     unlock by itself); the console answers with $NIST_LUKS_PASSPHRASE.
  3. The host reaches its login prompt, with Secure Boot now off.
  4. verify.sh reports the stale binding and that Secure Boot is off
     (mp-09-luks-tpm-bound, mp-09-secure-boot FAIL).
  5. apply.sh --tags 03.08.09 completes but does NOT reseal: a seal made with
     Secure Boot off opens for any boot medium (ODP-REVIEW I1). The binding
     stays stale and the key goes back on disk so the host boots unattended.
  6. Secure Boot is enforced again - only the variable store is restored,
     disk and TPM untouched - and the host boots by itself.
  7. apply.sh --tags 03.08.09 finds the original seal valid again, sets
     crypttab back to the TPM and removes the key; verify.sh passes 03.08.09.
  8. A reboot unlocks both volumes from the TPM alone, no prompt.

It refuses, before it touches anything, a guest that is not a lab guest or
has no `hardened` snapshot. At the end the guest is reverted to that snapshot
(Secure Boot on, TPM state as before). Exit 0 only if every step passes. Needs the lab's env.sh
sourced, with NIST_LUKS_PASSPHRASE set; the passphrase is typed at the
console and never logged (the transcript records only what the guest sends).
"""
from __future__ import annotations

import glob
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from console import Console  # noqa: E402
import pexpect  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VIRSH = ["virsh", "-c", "qemu:///system"]
FIRMWARE_DESCRIPTORS = "/usr/share/qemu/firmware"   # what every distribution installs


def no_keys_vars(nvram: str) -> str:
    """A UEFI variable store with no Secure Boot keys, for this guest.

    The template of a firmware descriptor that enrolls no keys, the same size
    as the guest's own store (so it fits its firmware). It was hardcoded to
    Ubuntu's /usr/share/OVMF/OVMF_VARS_4M.fd (DEFECTS 7.19)."""
    size = int(sh("sudo", "stat", "-c", "%s", nvram, check=True).stdout)
    found = []
    for path in sorted(glob.glob(os.path.join(FIRMWARE_DESCRIPTORS, "*.json"))):
        try:
            d = json.load(open(path))
        except (OSError, ValueError):
            continue
        tmpl = d.get("mapping", {}).get("nvram-template", {}).get("filename", "")
        if d.get("mapping", {}).get("device") != "flash" or "enrolled-keys" in d.get("features", []):
            continue
        if tmpl and os.path.exists(tmpl) and os.path.getsize(tmpl) == size:
            found.append(tmpl)
    if not found:
        raise SystemExit(f"error: no firmware descriptor in {FIRMWARE_DESCRIPTORS} offers a variable "
                         f"store without Secure Boot keys of {size} bytes")
    return found[0]
IMAGES = "/var/lib/libvirt/images"                   # vm/byo-snapshot.sh keeps snapshots here
PASSPHRASE_PROMPT = r"[Pp]assphrase for (disk )?[^\r\n]*(cui_data|cui_backup|lv_cui|lv_backup)"
# The prompt is shown on every boot - systemd displays the request while
# clevis-luks-askpass answers it from the TPM - so a prompt proves nothing.
# What does: whether the login prompt arrives with nobody answering. The CUI
# mounts are required for boot, so getty only starts once both are open.
UNATTENDED_GRACE = 120


def unlock_at_boot(con, pw):
    """'tpm' if the host reached its login prompt with no answer given,
    else 'passphrase' after answering every prompt with pw."""
    if con.expect([PASSPHRASE_PROMPT, con.login_prompt], timeout=600) == 1:
        return "tpm"
    try:
        con.expect(con.login_prompt, timeout=UNATTENDED_GRACE)
        return "tpm"
    except pexpect.TIMEOUT:
        pass
    con.sendline(pw)
    while con.expect([PASSPHRASE_PROMPT, con.login_prompt], timeout=600) == 0:
        con.sendline(pw)
    return "passphrase"


def sh(*cmd, check=False, capture=True):
    return subprocess.run(list(cmd), cwd=ROOT, text=True, check=check,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.STDOUT if capture else None)


def evidence(host, run_dir, label):
    """PCR 7 and the TPM event log at this boot, saved for comparison."""
    out = sh("ansible", host, "-b", "-m", "ansible.builtin.shell", "-a",
             "tpm2_pcrread sha256:7 | awk '/7 :/ {print $NF}'; echo ---; "
             "tpm2_eventlog /sys/kernel/security/tpm0/binary_bios_measurements").stdout
    body = out.split("\n", 1)[1] if "\n" in out else out
    with open(os.path.join(run_dir, f"{label}.eventlog.txt"), "w") as fh:
        fh.write(body)
    pcr7 = body.split("---", 1)[0].strip().splitlines()[-1] if "---" in body else "?"
    print(f"    [{label}] PCR 7 = {pcr7}", flush=True)
    return pcr7


def pcr7_events(path):
    """(event type, variable name, sha256) for each PCR 7 event in a saved log."""
    import yaml
    text = open(path).read().split("---", 1)[1]
    doc = yaml.safe_load(text) or {}
    events = []
    for e in doc.get("events", []):
        if e.get("PCRIndex") != 7:
            continue
        digest = next((d.get("Digest") for d in e.get("Digests", []) if d.get("AlgorithmId") == "sha256"), "")
        ev = e.get("Event") or {}
        name = ev.get("UnicodeName", "") if isinstance(ev, dict) else ""
        events.append((e.get("EventType"), name, digest))
    return events


def domstate(host):
    return sh(*VIRSH, "domstate", host).stdout.strip()


def main(argv):
    if len(argv) != 1:
        print(__doc__.split("\n\n")[1], file=sys.stderr); return 2
    host = argv[0]
    pw = os.environ.get("NIST_LUKS_PASSPHRASE", "")
    if not pw:
        print("error: NIST_LUKS_PASSPHRASE is not set", file=sys.stderr); return 2

    results = []
    def record(step, ok, detail=""):
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {step}{'  - ' + detail if detail else ''}", flush=True)

    # Refuse before touching the variable store: the end of the rehearsal
    # depends on the hardened snapshot (issue #6).
    xml = sh(*VIRSH, "dumpxml", host).stdout
    if "52:54:00:17:ab:" not in xml:
        print(f"error: {host} is not a lab guest (no 52:54:00:17:ab: MAC on nist-lab)", file=sys.stderr); return 2
    snaps = sh("./vm/byo-snapshot.sh", "list", host).stdout
    if not (re.search(rf"^{re.escape(host)}\s+hardened\s+qcow2", snaps, re.M)
            and re.search(rf"^{re.escape(host)}\s+hardened\s+nvram", snaps, re.M)):
        print(f"error: {host} has no 'hardened' snapshot (vm/byo-snapshot.sh save {host} hardened)",
              file=sys.stderr); return 2
    nvram = re.search(r"<nvram[^>]*>([^<]+)<", xml).group(1)
    hardened_nvram = os.path.join(IMAGES, f"{host}.hardened.nvram")

    def recap_of(out):
        line = next((l for l in out.splitlines() if re.match(rf"^{re.escape(host)}\s+:", l)), "")
        return re.sub(r"\s+", " ", line)

    def check_status(cid):
        """A check's status from the newest report for host, or None."""
        reports = sorted((f for f in os.listdir(os.path.join(ROOT, "reports"))
                          if f.startswith(host + "-") and f.endswith(".json")), reverse=True)
        if not reports: return None
        d = json.load(open(os.path.join(ROOT, "reports", reports[0])))
        return next((c["status"] for r in d["requirements"] for c in r.get("checks", [])
                     if c["id"] == cid), None)
    run_dir = os.path.join(ROOT, "reports", "runs", f"pcr7-{host}-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}")
    os.makedirs(run_dir, exist_ok=True)
    print(f"==> evidence in {run_dir}", flush=True)
    con = None
    try:
        # 1. Change PCR 7: stop the guest, replace its variable store.
        print(f"==> {host}: shutting down, replacing {nvram} with a store that has no Secure Boot keys", flush=True)
        sh(*VIRSH, "shutdown", host)
        for _ in range(60):
            if domstate(host) == "shut off": break
            time.sleep(2)
        else:
            sh(*VIRSH, "destroy", host)
        sh("sudo", "cp", "-f", no_keys_vars(nvram), nvram, check=True)
        sh(*VIRSH, "start", host, check=True)
        con = Console(host, timeout=600)

        # 2. The TPM must refuse: no login prompt until the passphrase is given.
        how = unlock_at_boot(con, pw)
        record(f"1-2. PCR 7 changed: boot waited {UNATTENDED_GRACE}s+ until the passphrase was typed",
               how == "passphrase",
               "" if how == "passphrase" else "the TPM still unlocked the volumes - PCR 7 did not change")
        record("3. the host reached its login prompt after the passphrase", True)
        con.close(); con = None

        evidence(host, run_dir, "boot-A-recovery")
        sb = sh("ansible", host, "-b", "-m", "ansible.builtin.shell", "-a",
                "od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* | awk '{print $NF}'").stdout
        print(f"    Secure Boot byte now: {sb.strip().splitlines()[-1] if sb.strip() else '?'} (1 = on)", flush=True)

        # 4. verify must see the stale binding and Secure Boot off.
        out = sh("./verify.sh", "--host", host, "--requirement", "03.08.09").stdout
        stale = "stale binding" in out
        sb_off = check_status("mp-09-secure-boot") == "FAIL"
        record("4. verify.sh reports the stale binding and Secure Boot off", stale and sb_off,
               "" if stale and sb_off else f"stale binding reported: {stale}; mp-09-secure-boot FAIL: {sb_off}")

        # 5. The role must not reseal to a Secure-Boot-off PCR 7 - and must
        #    not stop either: the key goes back on disk and the run completes.
        out = sh("./apply.sh", "--limit", host, "--tags", "03.08.09").stdout
        recap = recap_of(out)
        ran = "failed=0" in recap and "unreachable=0" in recap
        warned = "not bound or resealed" in out
        sh("./verify.sh", "--host", host, "--requirement", "03.08.09")
        still_stale = check_status("mp-09-luks-tpm-bound") == "FAIL"
        key = sh("ansible", host, "-b", "-m", "ansible.builtin.shell", "-a",
                 "test -s /root/.luks-key && grep -c '/root/.luks-key' /etc/crypttab").stdout
        key_back = bool(re.search(r"^2\s*$", key, re.M))
        record("5. apply.sh completes without resealing; the key is back on disk for boot",
               ran and warned and still_stale and key_back,
               f"{recap}; warned: {warned}; still stale: {still_stale}; key named in crypttab: {key_back}")

        # 6. Enforce Secure Boot again: the hardened variable store, nothing else.
        print(f"==> {host}: restoring the hardened variable store (Secure Boot on)", flush=True)
        sh(*VIRSH, "shutdown", host)
        for _ in range(60):
            if domstate(host) == "shut off": break
            time.sleep(2)
        else:
            sh(*VIRSH, "destroy", host)
        sh("sudo", "cp", "-f", hardened_nvram, nvram, check=True)
        sh(*VIRSH, "start", host, check=True)
        con = Console(host, timeout=600)
        how = unlock_at_boot(con, pw)
        con.close(); con = None
        evidence(host, run_dir, "boot-B-secure-boot-restored")
        record("6. with Secure Boot enforced again the host boots by itself", how == "tpm",
               "" if how == "tpm" else "the passphrase had to be typed")

        # 7. The role finds the original seal valid, removes the key; verify passes.
        out = sh("./apply.sh", "--limit", host, "--tags", "03.08.09").stdout
        recap = recap_of(out)
        key = sh("ansible", host, "-b", "-m", "ansible.builtin.shell", "-a",
                 "test -e /root/.luks-key && echo present || echo absent; grep -c ' none luks' /etc/crypttab").stdout
        out = sh("./verify.sh", "--host", host, "--requirement", "03.08.09").stdout
        ok7 = ("failed=0" in recap and "absent" in key and re.search(r"^2\s*$", key, re.M) is not None
               and re.search(r"(PASS|PART)\s+03\.08\.09", out) is not None and "0 failed" in out)
        record("7. apply.sh relies on the TPM again and removes the key; verify.sh passes 03.08.09", ok7,
               "" if ok7 else f"{recap}; key/crypttab: {' '.join(key.split())}")

        # 8. Reboot: the TPM alone must unlock, with no prompt.
        con = Console(host, timeout=600)
        sh("ansible", host, "-b", "-m", "ansible.builtin.shell", "-a", "sleep 2; systemctl reboot",
           "-B", "60", "-P", "0")
        how = unlock_at_boot(con, pw)
        con.close(); con = None
        evidence(host, run_dir, "boot-C-after-reapply")
        record("8. the next boot unlocks from the TPM alone", how == "tpm",
               "" if how == "tpm" else f"no login within {UNATTENDED_GRACE}s until the passphrase was typed")
        mounts = sh("ansible", host, "-b", "-m", "ansible.builtin.shell", "-a",
                    # One path per findmnt: given two, it reads them as a
                    # source and a target and matches nothing.
                    "for m in /var/lib/cui /var/backups/cui; do findmnt -no SOURCE $m; done").stdout
        record("   both volumes are mounted", "cui_data" in mounts and "cui_backup" in mounts)

        # Which PCR 7 measurement differed between consecutive boots?
        logs = sorted(f for f in os.listdir(run_dir) if f.endswith(".eventlog.txt"))
        for a, b in zip(logs, logs[1:]):
            ea, eb = pcr7_events(os.path.join(run_dir, a)), pcr7_events(os.path.join(run_dir, b))
            diff = [f"{x} -> {y}" for x, y in zip(ea, eb) if x != y]
            extra = len(eb) - len(ea)
            print(f"    PCR 7 events {a.split('.')[0]} -> {b.split('.')[0]}: "
                  f"{len(diff)} differ{', %+d events' % extra if extra else ''}", flush=True)
            for d in diff[:6]:
                print(f"      {d}", flush=True)
    except Exception as e:
        record("sequence", False, f"{type(e).__name__}: {str(e).splitlines()[0][:100] if str(e) else ''}")
    finally:
        if con: con.close()
        print(f"==> restoring {host} from its 'hardened' snapshot (Secure Boot on)", flush=True)
        r = sh("./vm/byo-snapshot.sh", "revert", host, "hardened")
        print("    " + (r.stdout.strip().splitlines()[-1] if r.stdout.strip() else f"rc={r.returncode}"), flush=True)

    ok = bool(results) and all(results)
    print(f"==> {'PASS' if ok else 'FAIL'}: PCR 7 recovery on {host}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
