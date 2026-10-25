#!/usr/bin/env python3
"""w1sites.py: the census sites (sites.tsv) whose view produces a value of a structurally Copy type, with
the helper classified as an identity view (place -> same type) or a reference view ((& T) -> T).
Writes w1-sites.tsv: rel, line, function, helper, arg, value type, kind, sink."""
import collections
import contextlib
import importlib.util
import io
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.pop("FORCE_COPY", None)
IDENT = {"ast-place-shared-view", "compiler-backend-global-shared-view", "compiler-owned-shared-view",
         "compiler-parse-place-shared-view", "lower-global-shared-view", "tc-global-shared-view",
         "compiler-opt-global-shared-view", "compiler-reg-global-shared-view", "compiler-ir-global-shared-view"}
REF = {"compiler-owned-reference-shared-view", "compiler-registries-reference-shared-view",
       "compiler-symbols-reference-shared-view", "compiler-symbols-shared-view",
       "compiler-symbols-program-shared-view", "ctfe-env-shared-view", "ctfe-expr-shared-view",
       "spec-subst-shared-view", "spec-template-env-shared-view", "compiler-registries-shared-view",
       "sym-i64-shared-view", "spec-value-subst-shared-view", "spec-type-subst-shared-view",
       "compiler-module-decl-index-shared-view"}
spec = importlib.util.spec_from_file_location("ct", HERE + "/copytypes.py")
ct = importlib.util.module_from_spec(spec)
with contextlib.redirect_stdout(io.StringIO()):
    spec.loader.exec_module(ct)
R = ct.R
out = []
for line in open(R + "sites.tsv").read().split("\n")[1:]:
    if not line:
        continue
    r = line.split("\t")
    rel, ln, fname, helper, arg, atype, sink = r[:7]
    if not atype:
        continue
    ty = atype.strip()
    if helper in IDENT:
        kind = "identity"
    elif helper in REF:
        m = re.match(r"\(&\s+(?:[a-z][A-Za-z0-9_-]*\s+)?(.*)\)$", ty)
        if not m:
            continue
        ty = m.group(1)
        kind = "reference"
    else:
        continue
    if ct.is_copy(ty):
        out.append([rel, ln, fname, helper, arg, ty, kind, sink])
with open(R + "w1-sites.tsv", "w") as fh:
    for r in out:
        fh.write("\t".join(r) + "\n")
print(len(out), dict(collections.Counter(r[6] for r in out)))
print(collections.Counter(r[5] for r in out).most_common(40))
