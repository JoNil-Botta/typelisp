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
| 69,079    | `src/lex.tl`              |
| 108,355   | `src/compiler_liveness.tl` |
| 229,084   | `src/compiler_symbols.tl` |
| 2,472,778 | `src/compiler_lower.tl`   |
| **2,879,300** | **total**             |

Each module is followed by a newline if it does not already end in one, so a
module's last token cannot fuse with the next module's first token.

## Arguments

```
bench <corpus-path> <rounds>
```

`optimization.tsv` ships `benchmarks/lex_source/data/corpus.tl-txt 8`, which is
about 1.0G retired instructions for the TypeLisp build.

## Regenerating the corpus

The corpus is frozen: the committed `Ir` baselines pin it byte for byte. It was
exported at commit `5fce734af` (#5989) by a Python exporter that read the
checked-in compiler sources of that time. The exporter and its regeneration
commands were deleted once the corpus was committed;
`git log --diff-filter=D -- benchmarks/lex_source/tools` finds the deleting
commit, whose parent still has both, including the exporter's header that
documents the full corpus format. Later language migrations edited the corpus in
place; `git log -- benchmarks/lex_source/data` lists them.
