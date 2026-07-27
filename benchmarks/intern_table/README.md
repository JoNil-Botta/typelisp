# intern_table

The compiler's interner hash/probe/growth path, over the real identifier stream.

`bench.tl` and `baseline.c` implement the hash, open-address probe, slice
storage, and load-factor growth of `src/compiler_intern.tl` -- the interner the
`intern.slice_misses` and `intern.slice_hits` compile-profile rows instrument.
The hash is `intern-hash-words` exactly (seed `5381 + len`, 64-bit
little-endian words folded with `0x9E3779B97F4A7C15`, a `tail = tail * 256 +
byte` remainder, and an `h ^= h >> 29` finalizer); the probe is `intern-slice`'s
(linear step, `steps < capacity` bound, stored-hash test then a byte compare);
the growth rule is the structural table's `(count + 1) * 4 >= capacity * 3`
doubling plus rehash-all. See the header comment of either file for the
function-by-function correspondence.

A round is one compile. Pass A interns the whole stream into a freshly reset
table, so it sees the corpus's real miss-then-hit mix and drives the table
through every growth step. Pass B re-interns the same stream against the
populated table: the hit-dominated re-read of symbols that later frontend phases
perform.

## Input

`data/idents.txt` is every `Token.Sym` lexeme `src/lex.tl` produces for the same
four modules `benchmarks/lex_source` uses (`src/lex.tl`,
`src/compiler_liveness.tl`, `src/compiler_symbols.tl`, `src/compiler_lower.tl`),
one per line, **in encounter order**. Encounter order is the point: it carries
the interner's real first-occurrence-miss / repeat-hit ratio and its real
collision families.

| property                     | value               |
|------------------------------|---------------------|
| bytes                        | 1,484,510           |
| identifiers                  | 143,306             |
| distinct                     | 6,663               |
| repeat (hit) rate            | 95.35%              |
| length min / median / p90 / max | 1 / 6 / 22 / 114 |

Under the shipped growth rule the table doubles 1024 -> 2048 -> 4096 -> 8192 ->
16384 during pass A of every round, and the final id count is exactly 6,663 --
which is how the implementation is checked against the exporter's distinct
count.

String-literal interning (`Token.Str`, which also calls `intern-source-slice`)
is excluded so the corpus stays line oriented; symbol lexemes never contain
whitespace.

## Arguments

```
bench <idents-path> <rounds>
```

`optimization.tsv` ships `benchmarks/intern_table/data/idents.txt 6`, which is
about 1.1G retired instructions for the TypeLisp build.

## Regenerating the corpus

From the repository root:

```sh
python3 benchmarks/intern_table/tools/export_idents.py
```

The tool runs the same classifier `src/lex.tl` runs (ported, and reported
alongside the stream statistics). The module list lives in
`tools/export_idents.py` (`SOURCES`) and matches
`benchmarks/lex_source/tools/export_corpus.py`.
