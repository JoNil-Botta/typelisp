#!/usr/bin/env python3
"""Export per-function SSA-construction inputs from `--dump-ir after-rotation`.

`after-rotation` is the dump point immediately before the `ssa` pass in
`optimize-function-once-with-summaries`, so these are the exact non-SSA
functions `opt-ssa-construct-function-from-context-and-representations-result`
receives: a scalar local that the front end lowered from `set!` is still one
vreg assigned in several blocks.

Only the snapshots that FAIL `opt-verify-single-defs?` are kept -- those are the
records the pass actually transforms. The already-single-def snapshots are
counted and reported on stderr; the kernel still runs the gate on every record
it is given (all of which fail it) because the gate is part of the algorithm.

Per function the record holds

    frame nparams nblocks ninstrs expect-candidates expect-phis expect-verify
    nparams x:  var typeclass
    nblocks x:  nsucc succ...  ninstr  instr...

with blocks numbered 0..n-1 in dump (= block-list) order, which is the CFG id
numbering `opt-cfg-index-build` assigns, and successor edges in
`opt-cfg-instr-successors` discovery order (same terminator rules as
benchmarks/cfg_domloops/tools/export_cfg_blocks.py).

Instruction encodings -- the leading integer is the `opt-ssa-facts-add-instr`
arm the instruction lands in:

    0 nuses use...            no destination            (`[_ facts]`, def-var None)
    1 nuses use... def ty     `opt-ssa-facts-add-def-ty`
    2 nuses use... def        `opt-ssa-facts-add-def-bad`
    3 nuses use... def        `AddrOf`: def bad AND use[0] poisoned
    4 nuses use... def        Pack/Word: defines `def`, but facts ignore it
    5 def ty nin (val pred)*  `Phi`: a lowerer-emitted phi, inputs are edge uses

`ty` is a nonzero signed type-class id: the magnitude interns the printed
TypeLisp type, the SIGN is `opt-ssa-register-value-type?` (positive = the fixed
one-word register representation `opt-ssa-fixed-register-value-type?` accepts).
`opt-ssa-facts-add-def-ty` needs exactly those two facts: identity, to detect a
var redefined at a different type, and register-value-ness. A phi input `val` of
-1 is a constant (not a var).

`expect-candidates` and `expect-phis` are this script's own independent replay
of `opt-ssa-candidate?` and of the `opt-ssa-insert-phis` iterated-dominance-
frontier worklist (including all four early-outs), written here in Python
against the same dump text. `expect-verify` is 1 when the constructed function
will pass `opt-verify-single-defs?` -- i.e. when no NON-candidate vreg has more
than one definition, since only candidates are versioned and everything else is
carried through unchanged; a 0 is the real `opt-ssa-construct-checked` reject,
where the pass throws its work away and keeps the pre-SSA function. The kernels
assert their own three numbers against these.

Functions are deduplicated by exact rendered body ACROSS all input dumps (every
dump is a whole program, so the stdlib and compiler_intern functions repeat, and
each dump holds one snapshot per optimizer pipeline iteration); first occurrence
wins. The deduplicated stream is then strided: every k-th record for the
smallest k whose rendering fits the byte budget.

Usage:
  python3 export_ssa_funcs.py OUT.txt BUDGET_BYTES DUMP.ir [DUMP.ir ...]

See ../README.md for the exact regeneration commands.
"""

import re
import sys

FUNC_RE = re.compile(r"^function @[^(]*\((.*)\) -> (.*) vars (-?\d+) \{$")
LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_.$]*):$")
DEF_RE = re.compile(r"^%(\d+) = (.*)$")
VAR_RE = re.compile(r"%(\d+)")
SWITCH_RE = re.compile(r"^switch .*\[(.*)\] default ([A-Za-z_][A-Za-z0-9_.$]*)$")
PHI_IN_RE = re.compile(r"\[([^,\]]+), ([A-Za-z_][A-Za-z0-9_.$]*)\]")

# opt-ssa-facts-add-instr arms, by printed opcode.
FACT_TY = {
    "mov", "load", "cast", "bitcast", "call", "call*", "callc*", "entry_argc",
    "add", "sub", "mul", "div", "mod", "safe_div", "safe_mod", "shl", "shr",
    "bit_and", "bit_or", "bit_xor", "eq", "ne", "lt", "le", "gt", "ge",
    "bit_test_eq", "bit_test_ne", "neg", "not", "bit_not", "sqrt",
}
FACT_BAD = {
    "alloc", "gep", "lane_id", "splat", "select", "tail_mask", "entry_argv",
    "entry_envp", "cpuid", "xgetbv", "syscall", "vector_binop", "vector_prefix",
    "vector_reduce", "vector_compare", "mask_binop", "mask_not", "mask_reduce",
    "vector_load", "predicated_load", "gather_load", "vector_shuffle",
}
FACT_DEFONLY = {"pack", "word"}
COMPARES = {"eq", "ne", "lt", "le", "gt", "ge", "bit_test_eq", "bit_test_ne"}

# opt-ssa-fixed-register-value-type?
SCALAR_TYPES = {
    "i64", "i32", "i16", "i8", "u64", "u32", "u16", "u8", "f64", "f32",
    "bool", "char", "String", "str",
}
REG_PREFIXES = ("(Ptr ", "(MutPtr ", "(& ", "(&mut ", "(Func ", "(Array ",
                "(__tl_dyn-array ", "(Box ")

KIND_NODEF, KIND_TY, KIND_BAD, KIND_ADDROF, KIND_DEFONLY, KIND_PHI = range(6)


def register_value_type(text):
    """opt-ssa-register-value-type? on the printed form of an AstType."""
    if text in SCALAR_TYPES:
        return True
    return text.startswith(REG_PREFIXES)


def split_params(text):
    """Split a parameter list on top-level commas (types contain commas)."""
    out, depth, start = [], 0, 0
    for i, ch in enumerate(text):
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth -= 1
        elif ch == "," and depth == 0:
            out.append(text[start:i].strip())
            start = i + 1
    tail = text[start:].strip()
    if tail:
        out.append(tail)
    return out


def block_successors(last_instr):
    """cfg_domloops' terminator rules: (labels, falls_through)."""
    if last_instr is None:
        return [], True
    if last_instr.startswith("jump "):
        return [last_instr[5:].strip()], False
    if last_instr.startswith("branch "):
        parts = last_instr[7:].split(", ")
        return [parts[1].strip(), parts[2].strip()], False
    if last_instr.startswith("switch "):
        match = SWITCH_RE.match(last_instr)
        if match is None:
            return [], False
        labels = [match.group(2)]
        for case in match.group(1).split(", "):
            if ":" in case:
                labels.append(case.split(":", 1)[1].strip())
        return labels, False
    if last_instr.startswith("return") or last_instr.startswith("tailcall"):
        return [], False
    return [], True


def dedup(items):
    seen, out = set(), []
    for item in items:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


class Types(object):
    """Intern printed types; id 1.. , sign carries register-value-ness."""

    def __init__(self):
        self.ids = {}

    def signed_id(self, text):
        tid = self.ids.get(text)
        if tid is None:
            tid = len(self.ids) + 1
            self.ids[text] = tid
        return tid if register_value_type(text) else -tid


def result_type(op, rest):
    """The AstType `opt-ssa-facts-add-instr` hands to add-def-ty."""
    if op in COMPARES:
        return "bool"                       # compiler-ir-binop-result-type
    if op in ("cast", "bitcast"):
        pos = rest.rfind(" to ")
        return rest[pos + 4:].strip() if pos >= 0 else None
    pos = rest.rfind(" : ")
    return rest[pos + 3:].strip() if pos >= 0 else None


def parse_function(header, body, types):
    """Parse one dumped function into (frame, params, blocks) or None."""
    match = FUNC_RE.match(header)
    if match is None:
        return None
    frame = int(match.group(3))
    if frame <= 0:
        return None
    params = []
    for text in split_params(match.group(1)):
        pos = text.find("=%")
        if pos < 0:
            return None
        colon = text.find(":", pos)
        if colon < 0:
            return None
        params.append((int(text[pos + 2:colon]), types.signed_id(text[colon + 1:])))

    labels, instrs = [], []
    for raw in body:
        line = raw.rstrip("\n")
        if line.startswith("  "):
            if not labels:
                return None
            instrs[-1].append(line[2:].strip())
            continue
        label = LABEL_RE.match(line)
        if label is None:
            if line.strip() == "":
                continue
            return None                      # a string operand spanning lines
        labels.append(label.group(1))
        instrs.append([])
    if not labels:
        return None

    index = {label: i for i, label in enumerate(labels)}
    blocks = []
    for pos, label in enumerate(labels):
        rows = [row for row in instrs[pos] if row]
        targets, falls = block_successors(rows[-1] if rows else None)
        if falls and pos + 1 < len(labels):
            targets = targets + [labels[pos + 1]]
        succs = [index[t] for t in dedup(targets) if t in index]
        parsed = []
        for row in rows:
            one = parse_instr(row, frame, index, types)
            if one is None:
                return None
            parsed.append(one)
        blocks.append((succs, parsed))
    return (frame, params, blocks)


def parse_instr(row, frame, index, types):
    """One instruction -> (kind, uses, def, ty, phi inputs)."""
    match = DEF_RE.match(row)
    if match is None:
        uses = [int(v) for v in VAR_RE.findall(row)]
        return (KIND_NODEF, [u for u in uses if u < frame], -1, 0, [])
    dst = int(match.group(1))
    rest = match.group(2)
    op = rest.split(" ", 1)[0].split("(", 1)[0]
    if op == "phi":
        pos = rest.rfind(" : ")
        if pos < 0:
            return None
        tid = types.signed_id(rest[pos + 3:].strip())
        inputs = []
        for value, pred in PHI_IN_RE.findall(rest[:pos]):
            if pred not in index:
                return None
            var = VAR_RE.fullmatch(value.strip())
            inputs.append((int(var.group(1)) if var else -1, index[pred]))
        if not inputs:
            return None
        return (KIND_PHI, [], dst, tid, inputs)

    operands = rest.split(" ", 1)[1] if " " in rest else ""
    uses = [int(v) for v in VAR_RE.findall(operands)]
    uses = [u for u in uses if u < frame]
    if op == "addr_of":
        return (KIND_ADDROF, uses, dst, 0, [])
    if op in FACT_BAD:
        return (KIND_BAD, uses, dst, 0, [])
    if op in FACT_DEFONLY:
        return (KIND_DEFONLY, uses, dst, 0, [])
    if op == "entry_argc":
        return (KIND_TY, uses, dst, types.signed_id("i64"), [])
    if op in FACT_TY:
        text = result_type(op, rest)
        if text is None:
            return None
        return (KIND_TY, uses, dst, types.signed_id(text), [])
    return None                              # unknown opcode: drop the record


# --- the compiler's own analysis, replayed here -----------------------------


def verify_single_defs(frame, params, blocks):
    """opt-verify-single-defs?"""
    seen = [False] * frame
    for var, _ in params:
        if var < 0 or var >= frame or seen[var]:
            return False
        seen[var] = True
    for _, instrs in blocks:
        for kind, _, dst, _, _ in instrs:
            if kind == KIND_NODEF:
                continue
            if dst < 0 or dst >= frame or seen[dst]:
                return False
            seen[dst] = True
    return True


def build_facts(frame, params, blocks):
    """opt-ssa-facts-from-function-with-representations."""
    counts = [0] * frame
    bad = [False] * frame
    tid = [0] * frame
    order = []

    def add_def_ty(var, signed):
        counts[var] += 1
        if signed < 0:
            bad[var] = True
            return
        if tid[var] == 0:
            tid[var] = signed
            order.append(var)
        elif tid[var] != signed:
            bad[var] = True

    for var, signed in params:
        add_def_ty(var, signed)
    for _, instrs in blocks:
        for kind, uses, dst, signed, _ in instrs:
            if kind == KIND_TY or kind == KIND_PHI:
                add_def_ty(dst, signed)
            elif kind == KIND_BAD:
                counts[dst] += 1
                bad[dst] = True
            elif kind == KIND_ADDROF:
                counts[dst] += 1
                bad[dst] = True
                if uses:
                    bad[uses[0]] = True
    return counts, bad, tid, order


def candidate(counts, bad, tid, var):
    """opt-ssa-candidate?"""
    return counts[var] > 1 and not bad[var] and tid[var] != 0


def dominators(nblocks, succs):
    """opt-cfg-index-build + opt-cfg-dominators-with (reachability + idom)."""
    reachable = [False] * nblocks
    postorder = []
    stack = [(0, 0)]
    reachable[0] = True
    while stack:
        node, cursor = stack[-1]
        row = succs[node]
        if cursor < len(row):
            stack[-1] = (node, cursor + 1)
            nxt = row[cursor]
            if not reachable[nxt]:
                reachable[nxt] = True
                stack.append((nxt, 0))
        else:
            postorder.append(node)
            stack.pop()
    rpo = postorder[::-1]
    rpo_num = [-1] * nblocks
    for slot, node in enumerate(rpo):
        rpo_num[node] = slot
    preds = [[] for _ in range(nblocks)]
    for src in range(nblocks):
        for dst in succs[src]:
            preds[dst].append(src)

    idom = [-1] * nblocks
    idom[0] = 0
    remaining = nblocks + 1
    changed = True
    while changed and remaining > 0:
        changed = False
        for node in rpo[1:]:
            best = -1
            for pred in preds[node]:
                if not reachable[pred] or idom[pred] < 0:
                    continue
                if best < 0:
                    best = pred
                else:
                    a, b = pred, best
                    while a != b:
                        while rpo_num[a] > rpo_num[b]:
                            a = idom[a]
                        while rpo_num[b] > rpo_num[a]:
                            b = idom[b]
                    best = a
            if node != 0 and best >= 0 and idom[node] != best:
                idom[node] = best
                changed = True
        remaining -= 1
    return reachable, preds, idom


def dominates(idom, a, b):
    """opt-dom-info-dominates-id? (the Euler test, by tree walk here)."""
    node = b
    while True:
        if node == a:
            return True
        parent = idom[node]
        if parent < 0 or parent == node:
            return False
        node = parent


def expect_verify(frame, params, blocks, counts, bad, tid):
    """opt-verify-single-defs? on the CONSTRUCTED function.

    Construction gives every candidate definition a fresh vreg, so the only way
    the result can still hold a repeated definition is a non-candidate vreg that
    was already defined more than once. `opt-instr-def-var` counts Pack/Word
    destinations that `opt-ssa-facts-add-instr` ignores, so recount here."""
    defs = [0] * frame
    for var, _ in params:
        defs[var] += 1
    for _, instrs in blocks:
        for kind, _, dst, _, _ in instrs:
            if kind != KIND_NODEF:
                defs[dst] += 1
    for var in range(frame):
        if defs[var] > 1 and not candidate(counts, bad, tid, var):
            return 0
    return 1


def expect_counts(frame, params, blocks):
    """The candidate count and the phi count `opt-ssa-insert-phis` produces."""
    counts, bad, tid, order = build_facts(frame, params, blocks)
    verify = expect_verify(frame, params, blocks, counts, bad, tid)
    ncand = sum(1 for var in order if candidate(counts, bad, tid, var))
    if ncand == 0:
        return 0, 0, verify
    # opt-ssa-blocks-have-candidate-phi-dst?
    for _, instrs in blocks:
        for kind, _, dst, _, _ in instrs:
            if kind == KIND_PHI and candidate(counts, bad, tid, dst):
                return ncand, 0, verify
    nblocks = len(blocks)
    if nblocks > 4096:                       # opt-ssa-block-budget
        return ncand, 0, verify
    succs = [row for row, _ in blocks]
    reachable, preds, idom = dominators(nblocks, succs)
    if preds[0]:                             # opt-ssa-entry-has-preds?
        return ncand, 0, verify

    def frontier(label):
        out = []
        for block in range(nblocks):
            if not reachable[block]:
                continue
            if not any(reachable[p] and dominates(idom, label, p)
                       for p in preds[block]):
                continue
            if label != block and dominates(idom, label, block):
                continue
            out.append(block)
        return out

    # opt-ssa-def-blocks-from-function
    defblocks = {}
    for var, _ in params:
        if candidate(counts, bad, tid, var):
            defblocks.setdefault(var, []).append(0)
    for block, (_, instrs) in enumerate(blocks):
        for kind, _, dst, _, _ in instrs:
            if kind == KIND_NODEF:
                continue
            if candidate(counts, bad, tid, dst):
                row = defblocks.setdefault(dst, [])
                if block not in row:
                    row.append(block)

    phis = 0
    for var in order:
        if not candidate(counts, bad, tid, var):
            continue
        work = list(defblocks.get(var, []))
        sites = set()
        while work:
            label = work.pop()
            for block in frontier(label):
                if block in sites:
                    continue
                sites.add(block)
                phis += 1
                work.append(block)
    return ncand, phis, verify


# --- rendering --------------------------------------------------------------


def render(record):
    frame, params, blocks, ncand, phis, verify = record
    ninstr = sum(len(instrs) for _, instrs in blocks)
    out = ["%d %d %d %d %d %d %d" % (frame, len(params), len(blocks), ninstr,
                                     ncand, phis, verify)]
    out.append(" ".join("%d %d" % pair for pair in params))
    for succs, instrs in blocks:
        out.append("%d %s %d" % (len(succs), " ".join(str(s) for s in succs),
                                 len(instrs)))
        for kind, uses, dst, ty, inputs in instrs:
            if kind == KIND_PHI:
                row = ["5", str(dst), str(ty), str(len(inputs))]
                for value, pred in inputs:
                    row.append(str(value))
                    row.append(str(pred))
            else:
                row = [str(kind), str(len(uses))]
                row.extend(str(u) for u in uses)
                if kind != KIND_NODEF:
                    row.append(str(dst))
                if kind == KIND_TY:
                    row.append(str(ty))
            out.append(" ".join(row))
    return "\n".join(row for row in out if row) + "\n"


def parse_dump(path, types, seen, stats):
    """Yield the kept records of one dump file."""
    records = []
    header, body = None, None
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if line.startswith("function @"):
                header, body = line, []
                continue
            if header is None:
                continue
            if line == "}":
                key = header + "\n" + "\n".join(body)
                if key not in seen:
                    seen.add(key)
                    stats["unique"] += 1
                    parsed = parse_function(header, body, types)
                    if parsed is None:
                        stats["unparsed"] += 1
                    else:
                        frame, params, blocks = parsed
                        if verify_single_defs(frame, params, blocks):
                            stats["already_ssa"] += 1
                        else:
                            ncand, phis, verify = expect_counts(
                                frame, params, blocks)
                            records.append((frame, params, blocks, ncand, phis,
                                            verify))
                stats["snapshots"] += 1
                header, body = None, None
                continue
            body.append(line)
    return records


def main(argv):
    if len(argv) < 4:
        sys.stderr.write(__doc__)
        return 2
    out_path, budget, sources = argv[1], int(argv[2]), argv[3:]

    types = Types()
    seen = set()
    stats = {"snapshots": 0, "unique": 0, "already_ssa": 0, "unparsed": 0}
    records = []
    for source in sources:
        records.extend(parse_dump(source, types, seen, stats))

    chunks = [render(record) for record in records]
    total = sum(len(chunk) for chunk in chunks)
    stride = 1
    while total // stride > budget:
        stride += 1
    kept = records[::stride]
    chunks = chunks[::stride]

    with open(out_path, "w", encoding="ascii", newline="\n") as out:
        out.write("# benchmarks/ssa_construct corpus v1\n")
        out.write("# sources: %s\n" % " ".join(sources))
        out.write("# stride: every %dth deduplicated non-SSA function\n" % stride)
        out.write("# nfuncs, then per function:\n")
        out.write("#   frame nparams nblocks ninstrs expect-candidates"
                  " expect-phis expect-verify\n")
        out.write("#   nparams 'var typeclass' pairs\n")
        out.write("#   per block: nsucc succ... ninstr, then the instructions\n")
        out.write("#   0 nuses use...          no destination\n")
        out.write("#   1 nuses use... def ty   facts add-def-ty\n")
        out.write("#   2 nuses use... def      facts add-def-bad\n")
        out.write("#   3 nuses use... def      addr_of: def bad, use[0] poisoned\n")
        out.write("#   4 nuses use... def      pack/word: defines def, facts skip\n")
        out.write("#   5 def ty nin (val pred)*  lowerer phi (val -1 = constant)\n")
        out.write("# ty: |ty| interns the printed type, ty > 0 is"
                  " opt-ssa-register-value-type?\n")
        out.write("%d\n" % len(chunks))
        for chunk in chunks:
            out.write(chunk)

    nblocks = sum(len(record[2]) for record in kept)
    ninstr = sum(len(instrs) for record in kept for _, instrs in record[2])
    ncand = sum(record[3] for record in kept)
    nphis = sum(record[4] for record in kept)
    nreject = sum(1 for record in kept if record[5] == 0)
    sys.stderr.write(
        "snapshots=%d unique=%d already-ssa=%d unparsed=%d kept=%d stride=%d\n"
        % (stats["snapshots"], stats["unique"], stats["already_ssa"],
           stats["unparsed"], len(chunks), stride))
    sys.stderr.write(
        "blocks=%d instrs=%d candidates=%d phis=%d verify-rejects=%d types=%d\n"
        % (nblocks, ninstr, ncand, nphis, nreject, len(types.ids)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
