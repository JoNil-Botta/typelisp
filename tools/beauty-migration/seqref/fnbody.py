#!/usr/bin/env python3
"""fnbody.py FILE.s SUFFIX: print the body of the first function whose symbol
ends with SUFFIX, from its label to its .size line."""
import sys

path, suffix = sys.argv[1], sys.argv[2]
on = False
for line in open(path, errors='replace'):
    if not on and line.rstrip().endswith(suffix + ':') and not line.startswith(' '):
        on = True
    if on:
        sys.stdout.write(line)
        if line.strip().startswith('.size'):
            break
