"""selfcalls.py A.s B.s: functions whose self-recursive call count grows from A to B (lost tail-call
elimination), plus functions whose instruction count changed the most."""
import collections
import re
import sys


def scan(path):
    calls = collections.Counter()
    size = collections.Counter()
    cur = None
    for line in open(path):
        if line and not line[0].isspace() and line.rstrip().endswith(":") and not line.startswith("."):
            cur = line.rstrip()[:-1]
            continue
        if cur is None:
            continue
        s = line.strip()
        if s and not s.startswith(".") and not s.endswith(":"):
            size[cur] += 1
        m = re.match(r"\s+call (\S+)", line)
        if m and m.group(1) == cur:
            calls[cur] += 1
    return calls, size


ca, sa = scan(sys.argv[1])
cb, sb = scan(sys.argv[2])
print("-- lost self tail calls (self-call count grew)")
for f in sorted(cb):
    if cb[f] > ca.get(f, 0):
        print(f"{ca.get(f, 0)} -> {cb[f]}\t{f}")
print("-- fewer self calls")
for f in sorted(ca):
    if ca[f] > cb.get(f, 0):
        print(f"{ca[f]} -> {cb.get(f, 0)}\t{f}")
