#!/usr/bin/env python3
"""Drive a lab guest's serial console non-interactively.

    tools/console.py HOST 'cmd1' 'cmd2' ...   log in, run each, print output
    tools/console.py HOST --login-only        report whether login succeeds

As a module, Console is what the rehearsals build on: it can attach before a
reboot and interact with GRUB or a passphrase prompt during boot, which
nothing that logs in over SSH can do.

A command starting with `sudo ` gets the password once sudo has asked for it
(sudo -S reads stdin, and timestamp_timeout=0 means it always asks). Nothing
waits for a prompt string that could also occur in echoed input, and a
pending prompt left by an earlier session is cancelled, never answered: an
empty answer is a failed authentication and counts towards faillock
(DEFECTS 3.2).

The login password is read from $NIST_CONSOLE_PASSWORD, else from
$NIST_BYO_LAB/byoadmin_password (default ~/.local/share/nist-byo-lab). Set
CONSOLE_TRANSCRIPT=<file> to keep the raw console output. Needs pexpect
(python3-pexpect, or `uv pip install pexpect` in the lab venv).

Moved into the repository from the lab directory on 2026-09-26 (AGENTS.md,
Doctrine), where it had been written for the Phase 3 rehearsals and knew only
byo-rl9-01.
"""
from __future__ import annotations

import os
import re
import sys

import pexpect

LAB = os.environ.get("NIST_BYO_LAB", os.path.expanduser("~/.local/share/nist-byo-lab"))
PROMPT = "NISTCONSOLE> "
SET_PS1 = "PS1='NIST''CONSOLE> '; export PS1"   # the echo differs from the prompt
SUDO_PROMPT = "NISTSUDO: "


class AuthFailed(RuntimeError):
    """An authentication on the console did not succeed. Nothing retries: on a
    hardened host every failure - including a password prompt cancelled or
    left unanswered - counts towards faillock (03.01.08), and three lock the
    account for lockout_duration_seconds. The first version of this driver
    locked byoadmin on byo-rl9-02 that way (its LF line endings never
    terminated the password line), recovered by reverting the guest."""


def login_password() -> str:
    pw = os.environ.get("NIST_CONSOLE_PASSWORD")
    if pw:
        return pw
    with open(os.path.join(LAB, "byoadmin_password")) as fh:
        return fh.read().strip()


class Console:
    def __init__(self, host: str, user: str = "byoadmin", timeout: int = 90):
        self.host, self.user = host, user
        self.login_prompt = f"{host} login: "   # getty's; 'Last login:' must not match
        self.c = pexpect.spawn("virsh", ["-c", "qemu:///system", "console", host, "--force"],
                               encoding="utf-8", timeout=timeout)
        self.c.logfile_read = open(os.environ.get("CONSOLE_TRANSCRIPT", "/dev/null"), "a")
        self.c.expect("Escape character")

    # -- boot-time interaction -------------------------------------------------
    def expect(self, patterns, timeout=None) -> int:
        """Index of the first pattern seen; raises on timeout or EOF."""
        return self.c.expect(patterns, timeout=timeout)

    def send(self, text: str) -> None:
        self.c.send(text)

    def sendline(self, text: str = "") -> None:
        # CR, as a terminal's Enter key sends it. pexpect's own sendline sends
        # a bare LF, which the hardened serial line does not act on: the shell
        # never saw the Enter and sudo -S never got its password line.
        self.c.send(text + "\r")

    # -- a shell session ---------------------------------------------------------
    def login(self) -> None:
        c = self.c
        c.sendcontrol("c"); self.sendline()
        i = c.expect([self.login_prompt, PROMPT, r"\]\$ ", "Password: "], timeout=30)
        if i == 3:                     # a pending login password prompt: back out
            c.sendcontrol("c"); self.sendline(); c.expect(self.login_prompt, timeout=30); i = 0
        if i == 0:
            self.sendline(self.user); c.expect("Password: ", timeout=30)
            self.sendline(login_password())
            if c.expect([r"\]\$ ", "Login incorrect", self.login_prompt], timeout=60) != 0:
                raise AuthFailed(f"console login refused for {self.user}; not retrying (faillock)")
        self.sendline(SET_PS1); c.expect(PROMPT, timeout=30)
        # firewalld's LogDenied=all reaches the serial console through printk and
        # buries everything; quiet it for this session, as an operator would.
        self.run("sudo dmesg -n 1")

    def run(self, cmd: str, timeout: int = 180) -> str:
        c = self.c
        if cmd.startswith("sudo "):
            # Wait for sudo's own prompt before answering: sudo flushes pending
            # terminal input when it turns echo off, so a password typed ahead
            # is discarded and sudo waits forever. The prompt is split in the
            # command line ('NIST''SUDO: ') so the echo cannot match it.
            self.sendline("sudo -S -p 'NIST''SUDO: ' " + cmd[5:])
            if c.expect([SUDO_PROMPT, PROMPT], timeout=30) == 0:
                self.sendline(login_password())
                if c.expect([PROMPT, SUDO_PROMPT,
                             r"Sorry, try again|incorrect password|a password is required|locked"],
                            timeout=timeout) != 0:
                    raise AuthFailed(f"sudo refused the password for {self.user}; "
                                     "not retrying (faillock)")
                return self._output()
            return self._output()
        self.sendline(cmd)
        c.expect(PROMPT, timeout=timeout)
        return self._output()

    def _output(self) -> str:
        out = self.c.before.replace("\r", "")
        out = re.sub(r"\x1b\[\?2004[hl]", "", out)
        out = re.sub(r"^\[ *\d+\.\d+\] filter_IN_[^\n]*\n?", "", out, flags=re.M)
        return out.split("\n", 1)[1].rstrip() if "\n" in out else ""

    def answer_passphrases(self, pw: str, prompt: str, timeout: int = 900) -> int:
        """At boot, answer every LUKS passphrase prompt matching `prompt` with
        pw until the login prompt; return how many were answered. For a host
        with no TPM (ODP-REVIEW I5), where each boot asks: nothing to wait
        out first, unlike tools/rehearse-pcr7-recovery.py's unlock_at_boot."""
        n = 0
        while self.expect([prompt, self.login_prompt], timeout=timeout) == 0:
            self.sendline(pw)
            n += 1
        return n

    def logout(self) -> None:
        self.sendline("exit")
        self.c.expect(self.login_prompt, timeout=30)

    def close(self) -> None:
        self.c.sendcontrol("]")
        self.c.close()


def main(argv: list[str]) -> int:
    if not argv or argv[0].startswith("-"):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    host, rest = argv[0], argv[1:]
    con = Console(host)
    try:
        con.login()
        print("LOGIN OK")
        if "--login-only" not in rest:
            for cmd in rest:
                print("$ " + cmd)
                print(con.run(cmd))
        con.logout()
    except AuthFailed as e:
        print(f"STOPPED: {e}", file=sys.stderr)
        return 2
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
