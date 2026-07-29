# lex_source

The compiler's own tokenizer hot loop, over real compiler source text.

`bench.tl` and `baseline.c` implement the byte-class dispatch of `src/lex.tl`
(`into-spanned-tokens-result` and its scanners) with the token-kind
numbering of `src/token.tl` (`tag`). Every token folds its `(kind, length,
first byte)` into a wrapping 64-bit accumulator; after each pass the final line,
column, and token count fold in too. See the header comment of either file for
the function-by-function correspondence and for what is deliberately out of
scope.

## Input

`data/corpus.tl-txt` is the byte-for-byte concatenation of four compiler
modules, so the classifier walks exactly the text the compiler's lexer walks
when it compiles itself:

| bytes     | module                    |
|-----------|---------------------------|
| 58,401    | `src/lex.tl`              |
| 88,542    | `src/compiler_liveness.tl` |
| 221,849   | `src/compiler_symbols.tl` |
| 2,101,534 | `src/compiler_lower.tl`   |
| **2,470,330** | **total**             |

Each module is followed by a newline if it does not already end in one, so a
module's last token cannot fuse with the next module's first token.

## Arguments

```
bench <corpus-path> <rounds>
```

`optimization.tsv` ships `benchmarks/lex_source/data/corpus.tl-txt 8`, which is
about 1.0G retired instructions for the TypeLisp build.

## Regenerating the corpus

From the repository root:

```sh
python3 benchmarks/lex_source/tools/export_corpus.py
```

The module list lives in `tools/export_corpus.py` (`SOURCES`). Regeneration is
deterministic, but any change to the listed modules changes the corpus and
therefore the benchmark checksum.
