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
  4. verify.sh reports the stale binding (mp-09-luks-tpm-bound FAIL).
  5. apply.sh --tags 03.08.09 reseals the volumes to the new PCR 7.
  6. verify.sh passes 03.08.09 again.
  7. A reboot unlocks both volumes from the TPM alone, no prompt.

Then the guest is reverted to its `hardened` snapshot (Secure Boot on, TPM
state as before). Exit 0 only if every step passes. Needs the lab's env.sh
sourced, with NIST_LUKS_PASSPHRASE set; the passphrase is typed at the
console and never logged (the transcript records only what the guest sends).
"""
from __future__ import annotations

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
NO_KEYS_VARS = "/usr/share/OVMF/OVMF_VARS_4M.fd"     # no PK/KEK/db: Secure Boot off
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

    nvram = re.search(r"<nvram[^>]*>([^<]+)<", sh(*VIRSH, "dumpxml", host).stdout).group(1)
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
        sh("sudo", "cp", "-f", NO_KEYS_VARS, nvram, check=True)
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

        # 4. verify must see the stale binding.
        out = sh("./verify.sh", "--host", host, "--requirement", "03.08.09").stdout
        stale = "stale binding" in out
        record("4. verify.sh reports the stale binding", stale,
               "" if stale else "mp-09-luks-tpm-bound did not report it")

        # 5. The role reseals.
        out = sh("./apply.sh", "--limit", host, "--tags", "03.08.09").stdout
        recap = next((l for l in out.splitlines() if re.match(rf"^{re.escape(host)}\s+:", l)), "")
        ok5 = "failed=0" in recap and "unreachable=0" in recap
        record("5. apply.sh --tags 03.08.09 reseals to the new PCR 7", ok5, re.sub(r"\s+", " ", recap))

        # 6. verify passes again.
        out = sh("./verify.sh", "--host", host, "--requirement", "03.08.09").stdout
        ok6 = re.search(r"(PASS|PART)\s+03\.08\.09", out) is not None and "0 failed" in out
        record("6. verify.sh passes 03.08.09 again", ok6)

        # 7. Reboot: the TPM alone must unlock, with no prompt. If it prompts,
        #    answer (so the host stays usable), reseal once more and try again:
        #    that tells a first-boot artefact from a recovery that never holds.
        def reboot_expect_unlock(label):
            nonlocal con
            con = Console(host, timeout=600)
            sh("ansible", host, "-b", "-m", "ansible.builtin.shell", "-a", "sleep 2; systemctl reboot",
               "-B", "60", "-P", "0")
            how = unlock_at_boot(con, pw)
            con.close(); con = None
            evidence(host, run_dir, label)
            return how != "tpm"

        prompted = reboot_expect_unlock("boot-B-after-reseal")
        record("7. the next boot unlocks from the TPM alone", prompted == 0,
               "" if prompted == 0 else f"no login within {UNATTENDED_GRACE}s until the passphrase was typed")
        if prompted:
            out = sh("./apply.sh", "--limit", host, "--tags", "03.08.09").stdout
            recap = next((l for l in out.splitlines() if re.match(rf"^{re.escape(host)}\s+:", l)), "")
            print(f"    resealed again: {re.sub(r'\s+', ' ', recap)}", flush=True)
            again = reboot_expect_unlock("boot-C-after-second-reseal")
            record("7b. after a second reseal, the next boot unlocks alone", again == 0,
                   "" if again == 0 else "still prompting")
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
