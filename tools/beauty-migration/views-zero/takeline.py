#!/usr/bin/env python3
"""takeline.py FILE BACKUP LINE: copy BACKUP's LINE into FILE (same line count); exit 1 when they
already agree there."""
import sys

path, backup, ln = sys.argv[1], sys.argv[2], int(sys.argv[3])
a = open(path).read().split("\n")
b = open(backup).read().split("\n")
assert len(a) == len(b)
if a[ln - 1] == b[ln - 1]:
    print("no backup change at", ln)
    sys.exit(1)
print("take", ln, b[ln - 1].strip())
a[ln - 1] = b[ln - 1]
open(path, "w").write("\n".join(a))
