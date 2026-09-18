# security_compliance

Out-of-the-box implementations of security controls for POSIX systems.

## NIST SP 800-171r3 → Rocky Linux 9

[`nist_sp_800_171r3/rl9-171/`](nist_sp_800_171r3/rl9-171/) is a portable
toolchain that extracts the 97 active security requirements of
[NIST SP 800-171r3](https://doi.org/10.6028/NIST.SP.800-171r3) from the
publication, maps the ones a Linux host can enforce onto Rocky Linux 9,
applies them with Ansible, and then independently verifies each running host.

```bash
cd nist_sp_800_171r3/rl9-171
cp inventory/hosts.yml.example inventory/hosts.yml   # your Rocky 9 host
./apply.sh --check --diff                            # what would change
./apply.sh && ./verify.sh                            # harden, then assess
```

It classifies 37 requirements as host-enforceable, 32 as partially enforceable
with the residual obligation named, and 28 as organizational with no host
control at all — rather than claiming 100% on the technical subset. On the
reference lab every host check passes; 03.14.02 is among the partial ones
because ClamAV signature scanning needs EPEL, which is outside the
authorized repository set.

Verification reads effective system state (`sshd -T`, `auditctl -l`,
`sysctl -n`), not the files the role wrote, and `make validate` refuses an
overlay that lets a requirement with a residual obligation report PASS.

See its [README](nist_sp_800_171r3/rl9-171/README.md) for the full design.

The same overlay applied to a stock Rocky 9 cloud image it did not build
reports **34 satisfied, 30 partial, 5 not satisfied, 28 organizational**: the
five are the separate filesystems and LUKS volumes only an install can
create, and the role records them rather than hiding them.

Open work is tracked in [TASKS.md](TASKS.md) — what is proven against a
running host, what is written but not yet executed, and the decisions that
need a system owner rather than a test.

Audit-record forwarding (03.03.05c) needs somewhere to forward to. `make vm-log`
builds a second host — a log collector, hardened by the same overlay and taught
to receive by a second role — and `tools/inventory.py` wires the forwarders to
it. With a single host that requirement can only ever report MANUAL.
