# read_sexpr

The compiler reader's recursive descent into the dense `Sexpr` node pool.

`bench.tl` and `baseline.c` run the TypeLisp compiler's own s-expression
reader — the mutually recursive `form-result` / `list-result-with-close`
descent that turns the lexer's token array into `Sexpr` trees stored in a dense
node pool (a list's children are one contiguous id range, not a cons spine) —
followed by the recursive `sexpr-view` walk a parser performs over each
top-level form. It runs over the real token stream `src/lex.tl` produces for
four compiler modules.

This is the corpus's call/return-heavy case: 358,840 token dispatches,
270,063 enum-payload constructions into a growable array, and 543,128 recursive
view steps per pass, all through non-tail recursion in both languages.

## Mirrored compiler functions

All in `src/read.tl` unless noted:

| Compiler function | What the kernel replicates |
|---|---|
| `form-result` | the token-tag dispatch: `Int` / `Float` / `Sym` / `Str` / `Char` atoms, `LParen` -> `list-result`, `LBracket` -> `bracket-list-result`, the four prefix tags wrapping the following form, `RParen` / `RBracket` / `End` as errors; the token is borrowed once at entry and its payload read only in the arm that needs it |
| `list-result-with-close` | the RECURSIVE element loop: close tag seals the range, `End` is the unterminated error, anything else reads one form, pushes it into the builder and recurses |
| `list-result` / `bracket-list-result` | pool mark, fresh builder, and the error path that discards the builder and truncates the pool back to the mark |
| `prefix-tag?` / `prefix-symbol` / `prefix-form` | the two-element `(quote x)`-shaped wrapper, built through the same builder and sealed by `sexpr-list-from-builder` |
| `sexpr-builder-new` / `-push` / `sexpr-builder-grow!` | the builder stack: a start index into one global slot array, 1024-then-doubling growth |
| `sexpr-list-from-builder` | the single copy of the builder range into the node pool, the builder count reset, and the returned `Sexpr.List start len` |
| `sexpr-builder-discard!` | the error rollback of the builder count |
| `sexpr-node-push` / `sexpr-node-pool-grow!` | the node pool: capacity check, store, count bump; 1024 then doubling, contents copied forward |
| `sexpr-node-pool-len` / `-truncate!` / `-reset!` / `sexpr-node-get` | the pool's length, mark rollback, per-form reset, and id load |
| `result` / `read` | the entry point: reset the pool, read ONE top-level form; `read` panics on the error arm |
| `sexpr-view` | the `SexprView.Cons` / `.Nil` traversal step over a child range, and the six atom views |
| `cur-pos` / `peek-tag` / `advance` | the one-element cursor array the descent threads as a `(&mut cur (__tl_dyn-array i64))` |
| `ci.intern-syntax-id-from-renderable` (`src/compiler_intern.tl`) | the `InternId` -> `InternSyntaxId` transform every `Sym` atom passes through: a `u32` field value widened to `u64`, i.e. the id masked to 32 bits |
| `parse-ast-program-forms-into-vec` (`src/compiler_parse_core.tl`) | the loader's drive over a whole file: one top-level form at a time with the pool bounded to a single form, then the parser's recursive walk of that form |
| `token.tag-ref`, `token.tag-*` (`src/token.tl`) | the integer tag constants the descent compares against |

## Fidelity

**Kept.** The recursion, in both languages. `form-result` and
`list-result-with-close` call each other exactly as the compiler's do — a list
element that is itself a list re-enters `form-result` and unwinds a frame per
nesting level — and the consumer walk recurses over `sexpr-view` instead of
stepping an explicit stack. Neither side converts either recursion to a loop.

Also kept: the dense node pool (children are one contiguous id range, so a
`Sexpr.List` is a `start`/`len` pair), the builder stack with its start-index
`SexprBuilder` handle, the single builder-range copy that seals a list, the
pool-mark / builder-discard error rollback, the `Result`-returning signatures
of all four descent functions, the 1024-then-doubling geometric growth with
storage retained for the whole run (the compiler keeps its pool arena across
resets), and the per-top-level-form `sexpr-node-pool-reset!`. The C side
mirrors the same structures: a tagged struct array for the node pool, a
`{tag, a, b}` `Sexpr`, and `SexprView` / `ResultSexpr` structs that overlay
their payloads the way the TypeLisp enums do.

**Dropped, and why none of it changes what is measured.**

1. **`Sexpr.Int`'s source text.** The compiler's `Int` variant carries the
   parsed value *and* the literal `String`, which exists only so an
   out-of-range literal can be re-rendered in a diagnostic. The reader never
   reads it; the kernel carries the value alone. Keeping it would add a
   pointer-width field to every node and measure `String` copies, not the
   descent.
2. **The nominal id structs.** `Sexpr.Sym` carries `ci.InternSyntaxId` and
   `Sexpr.Str` carries `ci.InternId`, both one-field structs over a `u32`/`u64`
   word. The kernel carries the integer and still applies the exact transform
   `intern-syntax-id-from-renderable` performs (the 32-bit truncation of the
   renderable id), so the Sym path keeps its one arithmetic step.
3. **`Sexpr.Float`'s text.** The compiler keeps the literal spelling as a
   `String`; the corpus assigns a first-occurrence id instead. The four corpus
   modules contain no float literal at all, so this path is never taken.
4. **Error messages.** `ResultSexpr.Err` carries a `String` in the compiler and
   an integer code here. A well-formed corpus never reaches an error arm, but
   every error arm — including `list-result`'s builder discard and pool
   truncate — is still emitted in both languages, so the descent's branch
   structure is unchanged.
5. **`sexpr-node-get` is bounds-checked here.** The compiler reaches pool slots
   through `sexpr-node-pool-shared-view`, an `unsafe` `ptr-read`. The kernel
   uses the ordinary `array-ref`, which is the language-level shape this gate
   exists to measure (C indexes plainly, and that difference is the
   measurement).
6. **The growth arena.** The compiler grows both pools inside a dedicated
   `arena.tl_arena_make` root so the global stays valid across transient driver
   arenas. The kernel grows with a plain allocation, since the arena plumbing
   is a lifetime concern and not part of the descent; both sides still copy the
   live prefix forward on every doubling.
7. **The spanned reader.** `form-spanned-result` and friends are the production
   path. They are the same descent with a `token.SourceSpan` merged into every
   node and an extra `BracketList` variant; the unspanned twin the packet names
   measures the same control flow with a narrower node. The per-top-level-form
   pool discipline is taken from the spanned loader
   (`parse-ast-program-forms-into-vec`), which is where the reader is really
   driven over a whole file.
8. **The lexer.** The corpus *is* the lexer's output, so the byte scanner is
   not re-run per round; `benchmarks/lex_source` already covers it.

## Corpus

`data/tokens.txt` — 1,881,866 bytes, 358,840 tokens, 4 files.

Provenance: the token stream `src/lex.tl` produces for `src/lex.tl`,
`src/compiler_liveness.tl`, `src/compiler_symbols.tl` and
`src/compiler_lower.tl` — the same four modules the `lex_source` and
`intern_table` corpora use. Each file is lexed on its own and terminated with
its own `End` token, exactly as `lex.result` does, and the four streams are
concatenated; the kernel recovers the file boundaries by scanning for the four
`End` tags. No IR dump is involved, so the `--dump-ir` crash on current `main`
(tracked by the orchestrator) does not affect this corpus.

Layout: header comments, then `ntokens nfiles`, then one `tag payload` pair per
token. `#` starts a comment to end of line. `tag` is the integer
`src/token.tl`'s `tag-*` constants return (LParen 1, RParen 2, Int 3, Sym 4,
End 5, Str 6, Char 7, Float 8, LBracket 9, RBracket 10, Quote 11, Backtick 12,
Comma 13, CommaAt 14). `payload` is the one integer the reader pulls out of the
token: a `Sym`'s intern id (first occurrence over the whole stream, mirroring
`ci.intern-source-slice-id`), a `Str`'s intern id for its *unescaped* text
(`src/lex.tl` interns string literals through the same entry point as symbols,
so both share one pool here as they do in the compiler), an `Int`'s
`number-int-value` (decimal, or `0x`/`0X`/`0b`/`0B` through
`parse-prefixed-int`, wrapped to 64 signed bits), a `Char`'s code point, a
`Float`'s first-occurrence text id, and `0` for every delimiter, prefix token
and `End`.

Per-file sizes and token counts:

| Module | bytes | tokens |
|---|---:|---:|
| `src/lex.tl` | 78,990 | 12,067 |
| `src/compiler_liveness.tl` | 116,812 | 14,333 |
| `src/compiler_symbols.tl` | 250,644 | 27,872 |
| `src/compiler_lower.tl` | 3,035,992 | 304,568 |

Structure of the stream, all computed by the exporter replaying the same
descent:

| Quantity | Value |
|---|---:|
| tokens | 358,840 |
| distinct interned symbols + string literals | 9,096 |
| top-level forms | 3,002 |
| nodes pushed into the pool per pass | 270,063 |
| lists sealed per pass (`(` 62,933 + `[` 23,010 + prefix 172) | 86,115 |
| max nesting depth | 43 |
| peak nodes in one top-level form | 4,523 |
| recursive `sexpr-walk` calls per pass | 543,128 |

Atom mix: `LParen` 62,933, `RParen` 62,933, `LBracket` 23,010, `RBracket`
23,010, `Sym` 180,980, `Int` 4,220, `Str` 1,454, `Char` 124, `Backtick` 44,
`Comma` 128, `Quote` 0, `CommaAt` 0, `Float` 0, `End` 4. Every `'` in these
modules opens a character literal, so `lex.tl` never emits a `Quote` token for
them; the prefix path is exercised by the 172 `` ` ``/`,` tokens in the
`defmacro` bodies.

The exporter confirms its own token count independently: it re-reads the file
it just wrote, recovers the record count and the `End`-token count from the
records themselves, checks both against the header, and checks that `(`/`)` and
`[`/`]` balance.

### Regeneration

The corpus is the lexer's output over four checked-in sources, so it needs no
compiler snapshot and no IR dump. From the repository root:

```sh
python3 benchmarks/read_sexpr/tools/export_tokens.py
```

which rewrites `benchmarks/read_sexpr/data/tokens.txt` byte-identically from
the four modules named at the top of the tool. Deterministic: the same sources
always produce the same file.

(For contrast, the IR-derived corpora in this directory —
`benchmarks/gvn_table`, `benchmarks/cfg_domloops` — are regenerated by
snapshotting a working compiler, e.g. `cp target/bootstrap-fixpoint/stage2
/tmp/tlsnap`, and running `--dump-ir after-ssa` over its own sources. This
benchmark needs neither step.)

## Design parameters

| Parameter | Value | Why |
|---|---|---|
| corpus path | argument 1 | runtime-opaque; the corpus is fixed |
| rounds | argument 2, `10` in `optimization.tsv` | tunes TypeLisp Ir to 0.80 G and C to 0.67 G |
| round rotation | the starting FILE advances by one per round | each round folds the same four per-file checksums in a different order, so no round repeats an earlier accumulator and nothing can be hoisted out of the round loop |
| pool reset | per top-level form (`sexpr-node-pool-reset!`) | exactly what `result` does, and what the loader's per-form pool bound achieves |
| pool storage | grown 1024-then-doubling, never freed or shrunk | the compiler retains its pool arena across resets; the pool settles at 4,523 slots after the first large form and never grows again |
| checksum | 64-bit FNV-1a, `h = (h ^ x) * 1099511628211`, basis `1469598103934665603` | wrapping multiply and xor only — no division or `%`, so TypeLisp `i64` and C `uint64_t` produce identical bits |
| folded per form | every atom payload and every `Nil` depth the recursive `sexpr-view` walk reaches, in walk order | covers the tree shape, the Sym ids, the Int values and the nesting depth |
| folded per round | top-level form count, pool node count, walk-call count, max walk depth | the self-check quantities plus the traversal's own totals |
| self-check | `3002` top-level forms and `270063` pool nodes per pass | both computed independently by `tools/export_tokens.py`, which replays `form-result` / `list-result-with-close` in Python; both kernels assert them every round and abort otherwise |
| shipped args | `benchmarks/read_sexpr/data/tokens.txt 10` | |
