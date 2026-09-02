#!/usr/bin/env python3
"""Export the callgraph_scc corpus from TypeLisp `--dump-ir` text.

The whole-program inline stage in `src/compiler_optimize.tl` builds, for every
compile, four tables over the program it is handed:

  `opt-function-index-build`   name-id -> dense slot, in an `opt_i64_i64_map`
                               (`stdlib/hashmap.tl`'s generated i64 -> i64 map)
                               sized `opt-function-index-capacity count`.
  `opt-callgraph-build`        per function, every instruction is walked and a
                               Call / TailCall / CallCAbiStoreResult / SpmdCall
                               contributes the callee's slot through
                               `opt-slot-list-add` -- an O(n) walk of an
                               `OptSlotList` cons list followed by a prepend.
  `opt-inline-census-build`    three i64 -> i64 maps keyed by slot: refcount,
                               hotcount (each reference weighted by the loop
                               depth of the block that holds it) and addrtaken
                               (a `fn@` function VALUE in any operand).
  `opt-scc-compute`            iterative Tarjan over the call graph with an
                               explicit frame stack.

This tool captures the input those four passes see. Per dump it emits one
program record holding, for every function in dump order:

  * NAME-ID -- a 64-bit FNV-1a of the function's mangled name text. The
    compiler keys `OptFunctionNameIndex.ids` by the name's interned symbol id,
    so the kernel must hash the ID, not the text; a stable per-name 64-bit
    integer reproduces that exactly while keeping the corpus all-integer.
  * NBLOCKS -- the block count, blocks numbered 0..n-1 in block-list order,
    which is the numbering `opt-inline-census-depth-stamp!` assigns.
  * the block-order edge list, `src dst` pairs derived from the terminators the
    same way `benchmarks/cfg_domloops/tools/export_cfg_blocks.py` derives them,
    except that this list is NOT deduplicated and carries no fall-through edge:
    `opt-inline-census-depth-instrs!` reacts only to a Jump / Branch /
    TotalEnumBranch / Switch / TotalEnumSwitch instruction, once per target
    operand, and the comment on `opt-inline-census-depth-edge!` states that the
    fall-through (always the next block, hence never a back edge) contributes
    nothing.
  * the reference list, `block callee-name-id kind` triples in exactly the
    order `opt-inline-census-blocks` -> `opt-inline-census-instr-seq` ->
    `opt-inline-census-instr` visits them:

      kind 0  a direct call edge: the callee name of a `call` or `tailcall`
              (`opt-inline-census-add-ref`, and the only kind
              `opt-callgraph-instr` turns into a call-graph edge)
      kind 1  an address-taken function value: a `fn@NAME` operand
              (`opt-inline-census-value` -> `opt-inline-census-add-address`)
      kind 2  reserved: no other operand shape reaches the census's counters.

    Within a call instruction the census walks the ARGUMENTS first and adds the
    callee reference last, so a `fn@` operand of a call is emitted before that
    call's own kind-0 triple.

Each program record is preceded by two independently computed self-check
values, which both kernels recompute and compare:

  * the deduplicated call-graph edge count -- the total length of every
    `OptSlotList` after `opt-slot-list-add`'s `opt-slot-list-contains?` filter,
    counting only callee names that resolve to a function of this program;
  * the SCC count `opt-scc-compute` returns, computed here by an independent
    recursive Tarjan (standard library only).

Corpus format (whitespace-separated decimal integers, `#` comments to end of
line; both the TypeLisp and the C kernel parse it with the same scanner):

    1                                   format version
    P                                   program count
    repeated P times:
      nfuncs dedup_edges scc_count
      repeated nfuncs times:
        name-id nblocks nedges nrefs
        repeated nedges times:  src dst
        repeated nrefs  times:  block callee-name-id kind

Usage:
  python3 export_callgraph.py OUT.txt DUMP.ir [DUMP.ir ...]

See ../README.md for the exact regeneration commands.
"""

import re
import sys

FUNC_RE = re.compile(r"^function @([^(]*)\(")
LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_.$]*):$")
SWITCH_RE = re.compile(r"^switch .*\[(.*)\] default ([A-Za-z_][A-Za-z0-9_.$]*)$")
CALL_RE = re.compile(r"^(?:%\d+ = )?(call|tailcall) ([^(]*)\(")
FN_VALUE_RE = re.compile(r"fn@([^,()\s]+)")

FNV_BASIS = 1469598103934665603
FNV_PRIME = 1099511628211
MASK64 = (1 << 64) - 1
# The compiler's symbol ids are non-negative; a negative id means "no symbol"
# and `opt-function-index-slot-id` rejects it before probing. Keeping the top
# two bits clear keeps every emitted id inside that domain (and inside a signed
# 64-bit token both kernels can scan without wrapping).
ID_MASK = (1 << 62) - 1


def name_id(text):
    """64-bit FNV-1a of a mangled name, the kernel's stand-in for a symbol id."""
    h = FNV_BASIS
    for byte in text.encode("utf-8"):
        h = ((h ^ byte) * FNV_PRIME) & MASK64
    return h & ID_MASK


def terminator_targets(instr):
    """The labels `opt-inline-census-depth-instrs!` feeds to `depth-edge!`.

    Order matters only for readability (the pass keeps a per-header maximum),
    but it is the compiler's: Jump -> its label, Branch / TotalEnumBranch ->
    true then false, Switch / TotalEnumSwitch -> default then the cases in
    textual order. Everything else is not a terminator shape the pass reacts
    to."""
    if instr.startswith("jump "):
        return [instr[5:].strip()]
    if instr.startswith("branch "):
        parts = instr[7:].split(", ")
        if len(parts) < 3:
            return []
        return [parts[1].strip(), parts[2].strip()]
    if instr.startswith("switch "):
        match = SWITCH_RE.match(instr)
        if match is None:
            return []
        labels = [match.group(2)]
        for case in match.group(1).split(", "):
            if ":" in case:
                labels.append(case.split(":", 1)[1].strip())
        return labels
    return []


def instr_references(instr):
    """`(callee-name, kind)` pairs one instruction contributes to the census.

    A call's arguments are censused before its callee name, so every `fn@`
    operand of the line is reported first."""
    out = [(name, 1) for name in FN_VALUE_RE.findall(instr)]
    match = CALL_RE.match(instr)
    if match is not None:
        out.append((match.group(2).strip(), 0))
    return out


def parse_dump(path):
    """Every function of one dump, in dump order.

    Returns a list of `(name, labels, edges, refs)`, where `edges` holds
    `(src-block, dst-block)` pairs and `refs` holds `(block, callee-name,
    kind)` triples. Only the FIRST snapshot of a function name is kept: a dump
    holds one snapshot per pipeline iteration and the census sees each function
    once."""
    functions = []
    seen = set()
    name = None
    labels = None
    blocks = None
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            match = FUNC_RE.match(line)
            if match is not None:
                name = match.group(1)
                labels = []
                blocks = []
                continue
            if labels is None:
                continue
            if line == "}":
                functions.append((name, labels, blocks))
                name, labels, blocks = None, None, None
                continue
            if line.startswith("  "):
                if blocks:
                    blocks[-1].append(line[2:].strip())
                continue
            hit = LABEL_RE.match(line)
            if hit is not None:
                labels.append(hit.group(1))
                blocks.append([])

    out = []
    for name, labels, blocks in functions:
        if not labels or name in seen:
            continue
        seen.add(name)
        index = {label: i for i, label in enumerate(labels)}
        edges = []
        refs = []
        for position, body in enumerate(blocks):
            for instr in body:
                for target in terminator_targets(instr):
                    if target in index:
                        edges.append((position, index[target]))
                for callee, kind in instr_references(instr):
                    refs.append((position, callee, kind))
        out.append((name, labels, edges, refs))
    return out


def dedup_edge_count(call_edges):
    """`opt-slot-list-add`'s result size: per caller, distinct resolved callee
    slots."""
    total = 0
    for callees in call_edges:
        total += len(callees)
    return total


def tarjan_sccs(count, adjacency):
    """An independent recursive Tarjan, for the self-check only.

    `opt-scc-compute` walks each node's children in ASCENDING slot order
    (`opt-scc-next-child` returns the smallest slot greater than `after`) and
    roots the outer sweep at slot 0, 1, ... so this walk closes components in
    the same order and therefore returns the same count."""
    sys.setrecursionlimit(1 << 20)
    indices = [-1] * count
    lowlink = [0] * count
    on_stack = [False] * count
    stack = []
    state = {"next": 0, "sccs": 0, "largest": 0}

    def visit(node):
        indices[node] = state["next"]
        lowlink[node] = state["next"]
        state["next"] += 1
        stack.append(node)
        on_stack[node] = True
        for child in sorted(adjacency[node]):
            if indices[child] < 0:
                visit(child)
                if lowlink[child] < lowlink[node]:
                    lowlink[node] = lowlink[child]
            elif on_stack[child]:
                if indices[child] < lowlink[node]:
                    lowlink[node] = indices[child]
        if lowlink[node] == indices[node]:
            members = 0
            while True:
                member = stack.pop()
                on_stack[member] = False
                members += 1
                if member == node:
                    break
            state["sccs"] += 1
            if members > state["largest"]:
                state["largest"] = members

    for root in range(count):
        if indices[root] < 0:
            visit(root)
    return state["sccs"], state["largest"]


def build_program(functions):
    """One program record: the dense index, the deduplicated call graph, and
    the two self-check quantities."""
    slots = {}
    for slot, entry in enumerate(functions):
        slots[name_id(entry[0])] = slot

    adjacency = []
    for _, _, _, refs in functions:
        callees = []
        for _, callee, kind in refs:
            if kind != 0:
                continue
            slot = slots.get(name_id(callee))
            if slot is None:
                continue
            if slot not in callees:
                callees.append(slot)
        adjacency.append(callees)

    scc_count, largest = tarjan_sccs(len(functions), adjacency)
    return dedup_edge_count(adjacency), scc_count, largest, adjacency


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    out_path = argv[1]
    sources = argv[2:]

    programs = []
    for source in sources:
        functions = parse_dump(source)
        dedup_edges, scc_count, largest, adjacency = build_program(functions)
        programs.append((functions, dedup_edges, scc_count, largest, adjacency))

    with open(out_path, "w", encoding="ascii", newline="\n") as out:
        out.write("# benchmarks/callgraph_scc corpus v1\n")
        out.write("# sources: %s\n" % " ".join(sources))
        out.write("# version, nprograms, then per program:"
                  " nfuncs dedup-edges scc-count,\n")
        out.write("# then per function: name-id nblocks nedges nrefs,"
                  " nedges 'src dst' pairs,\n")
        out.write("# then nrefs 'block callee-name-id kind' triples"
                  " (kind 0 = call, 1 = address-taken).\n")
        out.write("1\n")
        out.write("%d\n" % len(programs))
        for functions, dedup_edges, scc_count, _, _ in programs:
            out.write("%d %d %d\n" % (len(functions), dedup_edges, scc_count))
            for name, labels, edges, refs in functions:
                out.write("%d %d %d %d\n"
                          % (name_id(name), len(labels), len(edges), len(refs)))
                for src, dst in edges:
                    out.write("%d %d\n" % (src, dst))
                for block, callee, kind in refs:
                    out.write("%d %d %d\n" % (block, name_id(callee), kind))

    for source, entry in zip(sources, programs):
        functions, dedup_edges, scc_count, largest, adjacency = entry
        distinct = len(set(slot for row in adjacency for slot in row))
        blocks = sum(len(item[1]) for item in functions)
        edges = sum(len(item[2]) for item in functions)
        refs = sum(len(item[3]) for item in functions)
        calls = sum(1 for item in functions for ref in item[3] if ref[2] == 0)
        sys.stderr.write(
            "%s: functions=%d blocks=%d cfg-edges=%d refs=%d calls=%d"
            " addr-refs=%d graph-edges=%d distinct-callees=%d sccs=%d"
            " largest-scc=%d\n"
            % (source, len(functions), blocks, edges, refs, calls,
               refs - calls, dedup_edges, distinct, scc_count, largest))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
