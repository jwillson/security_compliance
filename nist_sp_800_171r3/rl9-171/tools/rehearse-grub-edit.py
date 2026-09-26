#!/usr/bin/env python3
"""Rehearse 03.10.07 by behaviour: editing a boot entry needs the GRUB password.

    tools/rehearse-grub-edit.py HOST

Attaches to HOST's serial console, reboots it (over SSH, as apply.sh would
reach it), catches the GRUB menu - it shows for one second - and presses `e`:

  1. GRUB must ask for a username; an editor appearing instead means there is
     no password (the state DEFECTS 6b.2 left every host in).
  2. A wrong password must be refused.
  3. root and the right password ($NIST_GRUB_PASSWORD) must open the editor.
  4. Escape leaves the editor without booting the edited entry; Enter boots
     the default entry, and the host must reach its login prompt unattended.

PASS or FAIL per step; exit 0 only if all pass. Nothing is changed: the edited
entry is never booted. Source the lab's env.sh first.
"""
from __future__ import annotations

import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from console import Console  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MENU = r"Press enter to boot the selected OS"
USERNAME = r"Enter username:"
PASSWORD = r"Enter password:"
EDITOR = r"Minimum Emacs-like screen editing|setparams|linux[ \t]+\(\$root\)|linux[ \t]+/vmlinuz"
DENIED = r"[Aa]ccess denied"


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    host = argv[0]
    grub_pw = os.environ.get("NIST_GRUB_PASSWORD", "")
    if not grub_pw:
        print("error: NIST_GRUB_PASSWORD is not set (source the lab's env.sh)", file=sys.stderr)
        return 2

    results: list[tuple[str, bool, str]] = []
    def record(step: str, ok: bool, detail: str = "") -> None:
        results.append((step, ok, detail))
        print(f"{'PASS' if ok else 'FAIL'}  {step}{'  - ' + detail if detail else ''}", flush=True)

    con = Console(host, timeout=300)
    try:
        print(f"==> rebooting {host} with the console attached", flush=True)
        subprocess.run(["ansible", host, "-b", "-m", "ansible.builtin.shell",
                        "-a", "sleep 2; systemctl reboot", "-B", "60", "-P", "0"],
                       cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

        con.expect(MENU, timeout=300)
        con.send("e")
        i = con.expect([USERNAME, EDITOR], timeout=20)
        record("1. editing an entry asks for a username", i == 0,
               "" if i == 0 else "the editor opened with no password: 03.10.07 is not enforced")
        if i != 0:
            con.send("\x1b")                    # leave the editor unbooted
            con.expect(MENU, timeout=20)
            con.sendline()
        else:
            con.sendline("root"); con.expect(PASSWORD, timeout=20)
            con.sendline("not-the-grub-password")
            j = con.expect([DENIED, EDITOR, MENU, USERNAME], timeout=20)
            record("2. a wrong password is refused", j != 1,
                   "" if j != 1 else "the editor opened with a wrong password")
            if j == 1:
                con.send("\x1b"); con.expect(MENU, timeout=20)
            else:
                con.send("\r")                  # dismiss "press any key", if shown
            con.expect(MENU, timeout=30)
            con.send("e")
            con.expect(USERNAME, timeout=20)
            con.sendline("root"); con.expect(PASSWORD, timeout=20)
            con.sendline(grub_pw)
            k = con.expect([EDITOR, DENIED], timeout=20)
            record("3. root and the right password open the editor", k == 0,
                   "" if k == 0 else "the right password was refused")
            con.send("\x1b")                    # never boot the edited entry
            con.expect(MENU, timeout=30)
            con.sendline()                      # boot the default entry
        con.expect(con.login_prompt, timeout=300)
        record("4. the default entry boots unattended to a login prompt", True)
    except Exception as e:  # a timeout mid-sequence is a failed step, not a crash
        record("sequence", False, f"{type(e).__name__}: stopped waiting ({str(e).splitlines()[0][:80]})")
    finally:
        con.close()

    ok = all(r[1] for r in results) and len(results) >= 4
    print(f"==> {'PASS' if ok else 'FAIL'}: GRUB edit protection on {host}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
