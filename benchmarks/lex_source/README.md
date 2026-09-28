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

## Regenerating the corpus

Exported at `5fce734af` (#5989) from the checked-in compiler sources, and since
edited in place by language migrations; see
[Compiler-derived kernels](../README.md#compiler-derived-kernels).
