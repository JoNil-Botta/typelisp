#!/usr/bin/env python3
"""Sample the compiler's own emitted assembly into a benchmark-sized corpus.

The input is the `.s` file the snapshot compiler writes for `src/main.tl`, i.e.
exactly the text `compiler-backend-peephole-asm-once-records` streams over when
the compiler compiles itself. The full file is ~41 MB, so this keeps a strided
sample of its function chunks.

A chunk starts at a line whose first non-space bytes are `.globl` and runs to
just before the next one, matching `compiler-backend-peephole-chunk-starts-global?`,
which is where the streaming peephole's pending pair and owner state are reset
anyway (a group ends at a function-level `.globl` chunk). Everything
before the first `.globl` (the file prologue) is always kept. The exporter
renders every chunk once, then keeps every k-th chunk with the smallest k whose
total fits the byte budget.

Because the kept chunks are not adjacent in the original file, a `jmp` whose
target block was dropped simply stays (the fallthrough scan only excises a jump
whose target label it actually reaches), so the sample changes rule-hit counts
slightly relative to the whole file. Within one function every label is local
and present, which is where all the pair rules and nearly all the fallthrough
jumps live.

Usage:
  python3 export_asm_slice.py OUT.s BUDGET_BYTES MAIN.s

See ../README.md for the exact regeneration commands.
"""

import sys


def main(argv):
    if len(argv) != 4:
        sys.stderr.write(__doc__)
        return 2
    out_path = argv[1]
    budget = int(argv[2])
    source = argv[3]

    with open(source, "r", encoding="utf-8", errors="replace", newline="\n") as fh:
        text = fh.read()

    chunks = []
    current = []
    for line in text.split("\n"):
        if line.lstrip(" ").startswith(".globl") and current:
            chunks.append("\n".join(current) + "\n")
            current = [line]
        else:
            current.append(line)
    if current:
        chunks.append("\n".join(current) + "\n")

    prologue = chunks[0]
    body = chunks[1:]
    total = sum(len(chunk) for chunk in body)
    stride = 1
    while len(prologue) + total // stride > budget:
        stride += 1
    kept = body[::stride]

    with open(out_path, "w", encoding="ascii", errors="replace",
              newline="\n") as out:
        out.write(prologue)
        for chunk in kept:
            out.write(chunk)

    lines = prologue.count("\n") + sum(chunk.count("\n") for chunk in kept)
    sys.stderr.write("chunks=%d/%d stride=%d lines=%d\n"
                     % (len(kept), len(body), stride, lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
