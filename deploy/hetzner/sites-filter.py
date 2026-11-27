"""sites-filter.py -- the part of lt.caddy whose DNS points at this server.

    python3 -I sites-filter.py <lt.caddy> <installed file or ""> > wanted
    (a report goes to stderr, one line per name)

The same filter FOMO Maldives uses (its deploy/hetzner/app/sites-filter.py).
A name may only be served here once its DNS points here: otherwise Caddy fails
its certificate challenge, and repeated failures rate-limit the certificate
authority for every domain on this server, Top Voice's and FOMO's included.
So a site block is kept only when ALL its names point here:

  - every A record is one of this server's addresses, and
  - there is no AAAA record, or every AAAA is one of this server's addresses
    (Let's Encrypt prefers IPv6, so a stray AAAA elsewhere fails the challenge).

A name whose lookup fails for a TEMPORARY reason (resolver down) keeps the state
it has in the installed file -- a DNS hiccup must never take a served site off.
Snippets, comments and blank lines are kept as they are.

LT_SITES_SERVER_IPS (space-separated) overrides this server's addresses, for
a floating IP or a test.
"""
import ipaddress
import os
import re
import socket
import subprocess
import sys


def server_ips():
    env = os.environ.get("LT_SITES_SERVER_IPS", "").split()
    if env:
        return {str(ipaddress.ip_address(a)) for a in env}
    ips = set()
    # Every address on the box (iproute2 is on any Ubuntu server)...
    try:
        out = subprocess.run(["ip", "-o", "addr", "show"], capture_output=True, text=True).stdout
        for m in re.finditer(r"\binet6?\s+([0-9a-fA-F:.]+)/", out):
            ips.add(str(ipaddress.ip_address(m.group(1))))
    except OSError:
        pass
    # ...and, failing that, the address it reaches the internet from (a UDP
    # "connect" sends nothing; it only picks the route).
    for family, probe in ((socket.AF_INET, "1.1.1.1"), (socket.AF_INET6, "2606:4700:4700::1111")):
        try:
            with socket.socket(family, socket.SOCK_DGRAM) as s:
                s.connect((probe, 53))
                ips.add(str(ipaddress.ip_address(s.getsockname()[0])))
        except OSError:
            pass
    return ips


def lookup(host, family):
    """('ok', {ips}) | ('none', set()) | ('temp', set())"""
    try:
        infos = socket.getaddrinfo(host, None, family, socket.SOCK_STREAM)
        return "ok", {str(ipaddress.ip_address(i[4][0])) for i in infos}
    except socket.gaierror as e:
        if e.errno in (socket.EAI_NONAME, getattr(socket, "EAI_NODATA", -5), getattr(socket, "EAI_ADDRFAMILY", -9)):
            return "none", set()
        return "temp", set()


def blocks(text):
    """Split a Caddyfile into top-level chunks: ('site'|'other', header, lines)."""
    out, cur, depth, header = [], [], 0, None
    for line in text.splitlines(keepends=True):
        code = re.sub(r"(^|\s)#.*$", "", line.rstrip("\n"))
        if depth == 0 and not cur:
            if code.strip().endswith("{"):
                header = code.strip()[:-1].strip()
            else:
                out.append(("other", None, [line]))
                continue
        cur.append(line)
        depth += code.count("{") - code.count("}")
        if depth <= 0:
            kind = "other" if header.startswith("(") else "site"
            out.append((kind, header, cur))
            cur, depth, header = [], 0, None
    if cur:
        out.append(("other", None, cur))
    return out


def hosts(header):
    names = []
    for addr in re.split(r"[,\s]+", header):
        if not addr:
            continue
        addr = re.sub(r"^[a-z]+://", "", addr)
        addr = addr.split("/")[0]
        addr = re.sub(r":\d+$", "", addr)
        names.append(addr.lower())
    return names


def installed_hosts(path):
    if not path or not os.path.exists(path):
        return set()
    found = set()
    for kind, header, _ in blocks(open(path).read()):
        if kind == "site":
            found.update(hosts(header))
    return found


def main():
    src, installed = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
    mine = server_ips()
    live = installed_hosts(installed)
    keep_text = []
    for kind, header, lines in blocks(open(src).read()):
        if kind != "site":
            keep_text.extend(lines)
            continue
        verdicts = []
        for h in hosts(header):
            s4, a = lookup(h, socket.AF_INET)
            s6, aaaa = lookup(h, socket.AF_INET6)
            if "temp" in (s4, s6):
                ok = h in live
                why = "DNS lookup failed for now; " + ("still served" if ok else "not served yet")
            elif not a:
                ok, why = False, "no A record yet"
            elif not a <= mine:
                ok, why = False, "points to " + ", ".join(sorted(a)) + " (not this server)"
            elif aaaa and not aaaa <= mine:
                ok, why = False, "its AAAA points to " + ", ".join(sorted(aaaa)) + " (remove it, or point it here)"
            else:
                ok, why = True, "points here"
            verdicts.append((h, ok, why))
        served = all(ok for _, ok, _ in verdicts)
        for h, ok, why in verdicts:
            state = "SERVED " if served else "waiting"
            print(f"  {state}  {h:32} {why}", file=sys.stderr)
        if served:
            keep_text.extend(lines)
    sys.stdout.write("".join(keep_text))


if __name__ == "__main__":
    main()
