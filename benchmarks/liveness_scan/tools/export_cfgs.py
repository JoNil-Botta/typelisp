#!/usr/bin/env python3
"""Export the liveness_scan corpus: real per-function CFGs and use/def sets,
captured from the compiler compiling itself.

src/compiler_liveness.tl runs a backward dataflow fixpoint over every function
the backend lowers. This tool captures that input without modifying the
compiler: it runs `typelisp compile <module> --dump-ir`, which writes the final
optimized IR (the same IR the liveness pass consumes), and converts the textual
dump into a compact all-integer corpus.

Per block it derives exactly what src/compiler_liveness.tl derives:

  successors   `compiler-live-block-successors`: the terminator's targets.
               `jump` has one, `branch` has two, `switch` has its cases plus its
               default, `return` and `tailcall` have none.
  def          `compiler-live-instr-defs` unioned over the block: every `%d`
               that appears on the left of an `=`.
  use          `compiler-live-block-use-def-seq`: iterating forward,
               `uses |= instr_uses - defs_so_far`, so only upward-exposed reads
               survive. Phi operands count as uses here, matching
               `compiler-live-instr-uses`.
  use_nophi    `compiler-live-block-use-def-nophi-seq-from`, which uses
               `compiler-live-instr-uses-nophi` and therefore drops phi
               operands. This is the entry `compiler-live-analyze-blocks-edge-
               precise` builds from.
  phi_out      `compiler-live-phi-out-add-inputs!`: for every phi input
               `(%v, predLabel)`, `%v` joins phi_out[predBlock]. The edge-precise
               pass unions this into each block's live-out.

Function parameters are deliberately NOT treated as defs: the compiler only
derives defs from instructions, so a parameter read stays in the entry block's
use set exactly as it does in src/compiler_liveness.tl.

Corpus format (whitespace-separated decimal integers, nothing else, so both the
TypeLisp and the C implementation can parse it with the same trivial scanner):

    1                      format version
    F                      function count
    repeated F times:
      vars nblocks
      repeated nblocks times:
        nsucc  succ...     block indices inside this function
        nuse   var...
        nnophi var...
        ndef   var...
        nphi   var...

Blocks appear in dump order, which is the lowering's deterministic reverse
postorder -- the order `compiler-live-worklist-pick!` walks backwards.

Regenerate from the repository root with:

    python3 benchmarks/liveness_scan/tools/export_cfgs.py \\
        --typelisp <path-to-typelisp> [--module src/compiler_liveness.tl]

It writes benchmarks/liveness_scan/data/cfgs.txt. The intermediate IR dump goes
to a temporary directory and is not kept.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

DEFAULT_MODULES = ["src/compiler_liveness.tl"]
OUTPUT = "benchmarks/liveness_scan/data/cfgs.txt"

FUNCTION_RE = re.compile(r"^function .* vars (\d+) \{$")
LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_.]*):$")
DEF_RE = re.compile(r"^  %(\d+) = ")
VAR_RE = re.compile(r"%(\d+)")
PHI_INPUT_RE = re.compile(r"\[(%\d+|[^,\]]+), ([A-Za-z_][A-Za-z0-9_.]*)\]")
SWITCH_CASE_RE = re.compile(r"(?:\d+):([A-Za-z_][A-Za-z0-9_.]*)")


class Block(object):
    def __init__(self, label):
        self.label = label
        self.succ_labels = []
        self.use = []
        self.use_nophi = []
        self.defs = []
        # (var, predecessor label) pairs contributed by this block's phis.
        self.phi_inputs = []


def instruction_vars(line):
    """Split one instruction line into (def_var_or_None, used_vars)."""
    match = DEF_RE.match(line)
    if match:
        def_var = int(match.group(1))
        rhs = line[match.end():]
    else:
        def_var = None
        rhs = line
    used = [int(v) for v in VAR_RE.findall(rhs)]
    return def_var, used


def terminator_successors(line):
    """`compiler-live-block-successors`, over the dump's terminator spellings."""
    body = line.strip()
    if body.startswith("jump "):
        return [body[len("jump "):].strip()]
    if body.startswith("branch "):
        parts = body[len("branch "):].split(",")
        return [p.strip() for p in parts[1:]]
    if body.startswith("switch "):
        cases = SWITCH_CASE_RE.findall(body)
        default = body.rsplit(" default ", 1)
        targets = list(cases)
        if len(default) == 2:
            targets.append(default[1].strip())
        return targets
    return []


def parse_functions(text):
    """Yield (vars, [Block]) for each function in an IR dump."""
    lines = text.split("\n")
    i = 0
    n = len(lines)
    while i < n:
        match = FUNCTION_RE.match(lines[i])
        if not match:
            i += 1
            continue
        declared_vars = int(match.group(1))
        max_var = 0
        blocks = []
        current = None
        # Ordered forward scan so the use/def rule sees instructions in order.
        block_defs = set()
        i += 1
        while i < n and lines[i] != "}":
            line = lines[i]
            label = LABEL_RE.match(line)
            if label:
                current = Block(label.group(1))
                blocks.append(current)
                block_defs = set()
                i += 1
                continue
            if not line.startswith("  ") or current is None:
                i += 1
                continue

            def_var, used = instruction_vars(line)
            is_phi = " = phi " in line
            for v in used:
                if v not in block_defs:
                    if v not in current.use:
                        current.use.append(v)
                    if not is_phi and v not in current.use_nophi:
                        current.use_nophi.append(v)
                if v > max_var:
                    max_var = v
            if is_phi:
                for value, pred in PHI_INPUT_RE.findall(line):
                    if value.startswith("%"):
                        current.phi_inputs.append((int(value[1:]), pred))
            if def_var is not None:
                block_defs.add(def_var)
                if def_var not in current.defs:
                    current.defs.append(def_var)
                if def_var > max_var:
                    max_var = def_var
            current.succ_labels = terminator_successors(line)
            i += 1
        i += 1
        if blocks:
            yield max(declared_vars, max_var + 1), blocks


def encode_function(vars_count, blocks, out):
    index_of = {}
    for slot, block in enumerate(blocks):
        index_of[block.label] = slot

    phi_out = [[] for _ in blocks]
    for block in blocks:
        for var, pred in block.phi_inputs:
            slot = index_of.get(pred, -1)
            if slot >= 0 and var not in phi_out[slot]:
                phi_out[slot].append(var)

    out.append("%d %d" % (vars_count, len(blocks)))
    for slot, block in enumerate(blocks):
        succ = [index_of[l] for l in block.succ_labels if l in index_of]
        # `compiler-live-label-set-insert` keeps the successor list a set.
        unique = []
        for s in succ:
            if s not in unique:
                unique.append(s)
        rows = [unique, block.use, block.use_nophi, block.defs, phi_out[slot]]
        out.append(" ".join(
            str(len(row)) + ("" if not row else " " + " ".join(str(v) for v in row))
            for row in rows))


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--typelisp", required=True,
                        help="path to a typelisp compiler binary")
    parser.add_argument("--module", action="append", default=None,
                        help="module to dump (repeatable); "
                             "default: " + " ".join(DEFAULT_MODULES))
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--opt-level", default="2")
    parser.add_argument("--target", default="linux-x86_64")
    args = parser.parse_args(argv[1:])

    modules = args.module if args.module else DEFAULT_MODULES
    out_path = os.path.join(args.root, OUTPUT)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    functions = []
    total_blocks = 0
    with tempfile.TemporaryDirectory() as scratch:
        for module in modules:
            dump = os.path.join(scratch, os.path.basename(module) + ".ir")
            subprocess.check_call([
                args.typelisp, "compile", module, "--dump-ir", "-o", dump,
                "--target", args.target, "--opt-level", args.opt_level,
                "--stdlib-root", "stdlib", "--stdlib-root", "src",
            ], cwd=args.root, stdout=subprocess.DEVNULL)
            with open(dump, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
            for vars_count, blocks in parse_functions(text):
                functions.append((vars_count, blocks))
                total_blocks += len(blocks)

    out = ["1", str(len(functions))]
    for vars_count, blocks in functions:
        encode_function(vars_count, blocks, out)
    blob = ("\n".join(out) + "\n").encode("ascii")
    with open(out_path, "wb") as handle:
        handle.write(blob)

    words = sorted((v + 31) // 32 for v, _ in functions)
    print("wrote %s: %d bytes" % (OUTPUT, len(blob)))
    print("  modules: %s" % " ".join(modules))
    print("  functions: %d  blocks: %d" % (len(functions), total_blocks))
    print("  bitset words min/median/p90/max: %d/%d/%d/%d"
          % (words[0], words[len(words) // 2], words[(len(words) * 9) // 10],
             words[-1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
