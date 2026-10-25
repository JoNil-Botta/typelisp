"""reseed.py OLD NEW: a fresh consLoop state keeping only the permanent failures (held or skipped
definitions, temporaries in held code, constructors that store the value); everything else is
retried with the current loop."""
import json
import re
import sys

old = json.load(open(sys.argv[1]))
PERM = re.compile(r"^(held|no unique|temporary argument|bare variant|ERR)|call `(?:[A-Za-z_]+\.)*[A-Z][A-Za-z]*` ")
failed = {k: v for k, v in old["failed"].items() if PERM.search(v)}
json.dump({"converted": {}, "failed": failed, "wraps": [], "edits": [], "initialized": False},
          open(sys.argv[2], "w"), indent=1)
print(len(failed), "failures kept:", ", ".join(sorted(failed)))
