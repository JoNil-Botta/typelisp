"""fnasm.py FILE.s SYMBOL: print the asm of one function (from its label to the next global label)."""
import sys

path, sym = sys.argv[1], sys.argv[2]
out = []
on = False
for line in open(path):
    if line.startswith(sym + ":"):
        on = True
    elif on and line and not line[0].isspace() and line.rstrip().endswith(":") and not line.startswith(".L"):
        break
    if on:
        out.append(line.rstrip("\n"))
print("\n".join(out))
print(len(out), "lines", file=sys.stderr)
