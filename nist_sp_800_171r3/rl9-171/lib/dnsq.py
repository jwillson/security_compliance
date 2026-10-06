#!/usr/bin/env python3
"""dnsq.py SERVER NAME - ask SERVER (IPv4 or IPv6) for NAME's A record, by one UDP query.

Prints the first address and exits 0, or prints why not ("rcode 5, 0
answers", "no answer: timed out") and exits 1. Stdlib only, so it runs on a
bare host: vm/lab-network.sh uses it to find a resolver that answers, and
tools/diagnose-lab-net.sh to ask the lab network's dnsmasq as a guest would.
"""
import random, socket, struct, sys
server, name = sys.argv[1], sys.argv[2]
qid = random.randrange(65536)
q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
q += b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0" + struct.pack(">HH", 1, 1)
try:
    # getaddrinfo takes IPv4, IPv6 and a scoped link-local (fe80::1%eth0).
    fam, _, _, _, addr = socket.getaddrinfo(server, 53, type=socket.SOCK_DGRAM)[0]
    s = socket.socket(fam, socket.SOCK_DGRAM); s.settimeout(5)
    s.sendto(q, addr); data, _ = s.recvfrom(4096)
except OSError as e:
    print("no answer: %s" % e); sys.exit(1)
rcode, an = data[3] & 0x0F, struct.unpack(">H", data[6:8])[0]
if rcode or not an:
    print("rcode %d, %d answers" % (rcode, an)); sys.exit(1)
i = 12
while data[i]: i += data[i] + 1
i += 5
for _ in range(an):
    if data[i] & 0xC0 == 0xC0: i += 2
    else:
        while data[i]: i += data[i] + 1
        i += 1
    rtype, _, _, rdlen = struct.unpack(">HHIH", data[i:i + 10]); i += 10
    if rtype == 1:
        print(".".join(str(b) for b in data[i:i + 4])); sys.exit(0)
    i += rdlen
print("no A record"); sys.exit(1)
