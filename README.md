# security_compliance

Out-of-the-box implementations of security controls for POSIX systems.

## NIST SP 800-171r3 → Rocky Linux 9

[`nist_sp_800_171r3/rl9-171/`](nist_sp_800_171r3/rl9-171/) is a portable
toolchain that extracts the 97 active security requirements of
[NIST SP 800-171r3](https://doi.org/10.6028/NIST.SP.800-171r3) from the
publication, maps the ones a Linux host can enforce onto Rocky Linux 9,
applies them with Ansible, and then independently verifies the running host.

```bash
cd nist_sp_800_171r3/rl9-171
cp inventory/hosts.yml.example inventory/hosts.yml   # your Rocky 9 host
./apply.sh --check --diff                            # what would change
./apply.sh && ./verify.sh                            # harden, then assess
```

It reports 44 requirements as host-enforceable in full, 25 as partially
enforceable with the residual obligation named, and 28 as organizational with
no host control at all — rather than claiming 100% on the technical subset.
Verification reads effective system state (`sshd -T`, `auditctl -l`,
`sysctl -n`), not the files the role wrote, and never reports PASS for a
requirement the host only partly satisfies.

See its [README](nist_sp_800_171r3/rl9-171/README.md) for the full design.

Open work is tracked in [TASKS.md](TASKS.md) — what is proven against a
running host, what is written but not yet executed, and the decisions that
need a system owner rather than a test.

Earlier work on the same problem is kept unmaintained under
[`nist_sp_800_171r3/archive/`](nist_sp_800_171r3/archive/README.md).
