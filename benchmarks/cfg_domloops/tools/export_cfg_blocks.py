#!/usr/bin/env python3
"""Export per-function CFG block graphs from TypeLisp `--dump-ir` text.

The corpus this writes is the input `opt-cfg-context-build` sees: for every
function in the dump, the block count and the successor edges of every block,
with blocks numbered 0..n-1 in dump (= block-list) order, which is exactly the
CFG id numbering `opt-cfg-index-build` assigns.

Successor edges are emitted in the order the compiler's CSR successor row holds
them, which `opt-cfg-instr-successors` + `opt-label-add` (prepend on first
occurrence) + `opt-cfg-csr-fill-rows!` (reverse each row) makes equal to
first-occurrence textual order:

  jump L                     -> [L]
  branch %v, T, F            -> [T, F]
  switch %v base N [..] default D -> [D, case labels in textual order]
  return / tailcall          -> []
  no terminator              -> [next block in list order]  (fallthrough)

Usage:
  python3 export_cfg_blocks.py OUT.txt DUMP.ir [DUMP.ir ...]

See ../README.md for the exact regeneration commands.
"""

import re
import sys

FUNC_RE = re.compile(r"^function ")
LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_.$]*):$")
SWITCH_RE = re.compile(r"^switch .*\[(.*)\] default ([A-Za-z_][A-Za-z0-9_.$]*)$")
TERMINATORS = ("jump ", "branch ", "return", "tailcall", "switch ")


def block_successors(last_instr):
    """Successor labels of a block whose final instruction is `last_instr`.

    Returns (labels, falls_through)."""
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


def dedup(labels):
    seen = set()
    out = []
    for label in labels:
        if label not in seen:
            seen.add(label)
            out.append(label)
    return out


def parse_functions(path):
    """Yield (labels, per-block last instruction) for every function in a dump."""
    functions = []
    labels = None
    last = None
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if FUNC_RE.match(line):
                labels, last = [], []
                continue
            if labels is None:
                continue
            if line == "}":
                functions.append((labels, last))
                labels, last = None, None
                continue
            if line.startswith("  "):
                if last:
                    last[-1] = line[2:].strip()
                continue
            match = LABEL_RE.match(line)
            if match is not None:
                labels.append(match.group(1))
                last.append(None)
    return functions


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    out_path = argv[1]
    sources = argv[2:]

    records = []
    for source in sources:
        for labels, last in parse_functions(source):
            if not labels:
                continue
            index = {label: i for i, label in enumerate(labels)}
            edges = []
            for block in range(len(labels)):
                targets, falls = block_successors(last[block])
                if falls and block + 1 < len(labels):
                    targets = targets + [labels[block + 1]]
                for target in dedup(targets):
                    if target in index:
                        edges.append((block, index[target]))
            records.append((len(labels), edges))

    with open(out_path, "w", encoding="ascii", newline="\n") as out:
        out.write("# benchmarks/cfg_domloops corpus v1\n")
        out.write("# sources: %s\n" % " ".join(sources))
        out.write("# nfuncs, then per function: nblocks nedges, then nedges"
                  " 'src dst' pairs\n")
        out.write("%d\n" % len(records))
        for count, edges in records:
            out.write("%d %d\n" % (count, len(edges)))
            for src, dst in edges:
                out.write("%d %d\n" % (src, dst))

    blocks = sum(count for count, _ in records)
    edges = sum(len(edge_list) for _, edge_list in records)
    sys.stderr.write("functions=%d blocks=%d edges=%d\n"
                     % (len(records), blocks, edges))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
