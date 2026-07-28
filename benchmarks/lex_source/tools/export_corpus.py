#!/usr/bin/env python3
"""Export the lex_source corpus: real TypeLisp compiler source text.

The lex_source benchmark tokenizes the text the compiler's own lexer sees when
the compiler compiles itself. The corpus is therefore a deterministic
concatenation of representative `src/*.tl` modules, byte for byte as committed.

Regenerate from the repository root with:

    python3 benchmarks/lex_source/tools/export_corpus.py

which rewrites benchmarks/lex_source/data/corpus.tl-txt. The output is
deterministic: the same inputs always produce the same bytes, so the benchmark
checksum is stable.

The file list below is the corpus definition. It is ordered smallest to
largest, and each module is separated from the next by a single newline so a
module that does not end in one cannot fuse its last token with the next
module's first token.
"""

import os
import sys

# Ordered corpus definition: the lexer front end itself, the dataflow pass, the
# symbol tables, and the IR lowering. Together they cover the spelling range of
# the compiler's sources (dashed names, keyword annotations, string literals
# with escapes, comment blocks, deep nesting, integer and float literals).
SOURCES = [
    "src/lex.tl",
    "src/compiler_liveness.tl",
    "src/compiler_symbols.tl",
    "src/compiler_lower.tl",
]

OUTPUT = "benchmarks/lex_source/data/corpus.tl-txt"


def main(argv):
    root = argv[1] if len(argv) > 1 else "."
    out_path = os.path.join(root, OUTPUT)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    chunks = []
    for name in SOURCES:
        path = os.path.join(root, name)
        with open(path, "rb") as handle:
            data = handle.read()
        chunks.append(data)
        if not data.endswith(b"\n"):
            chunks.append(b"\n")

    blob = b"".join(chunks)
    with open(out_path, "wb") as handle:
        handle.write(blob)

    print("wrote %s: %d bytes from %d modules" % (OUTPUT, len(blob), len(SOURCES)))
    for name in SOURCES:
        size = os.path.getsize(os.path.join(root, name))
        print("  %9d  %s" % (size, name))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
