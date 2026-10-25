#!/usr/bin/env python3
# sites.py FILE REGEX...: each match with its line and enclosing top-level define.
import re
import sys

path = sys.argv[1]
pats = [re.compile(p) for p in sys.argv[2:]]
cur = '?'
defre = re.compile(r'^\((?:define|define-macro|defmacro) \(?([^\s()]+)')
for n, line in enumerate(open(path), 1):
    m = defre.match(line)
    if m:
        cur = m.group(1)
    for p in pats:
        if p.search(line):
            print(f'{n}\t{cur}\t{p.pattern}\t{line.strip()[:110]}')
            break
