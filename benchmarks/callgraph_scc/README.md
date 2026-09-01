# callgraph_scc

The inliner's whole-program tables, over real pre-inline programs.

`bench.tl` and `baseline.c` run the TypeLisp optimizer's own whole-program
inline preparation — the dense function index, the cons-list call graph, the
loop-depth-weighted reference census and the iterative Tarjan SCC solve — over
the programs the compiler was handed at its first `--opt-level 1` dump point
while compiling ten of its own modules.

A round is one program: build the index, build the graph, build the census,
compute the SCCs, then read every table back once per function slot. The ten
programs rotate, so a run walks all of them.

## Mirrored compiler functions

All in `src/compiler_optimize.tl`:

| Compiler function | What the kernel replicates |
|---|---|
| `opt-function-index-capacity` | `count < 4 ? 8 : count * 2`, the map's requested capacity |
| `opt-function-index-build` / `-fill-from` | one `insert-ref!` per function, slot = position in the function sequence |
| `opt-function-index-slot` / `-slot-id` | the negative-id rejection and the `get-value-or ... -1` probe every reference resolution pays |
| `opt-slot-list-contains?` | the O(n) recursive membership walk of an `OptSlotList` |
| `opt-slot-list-add` | that walk followed by a prepend of a fresh `Cons` cell |
| `opt-slot-list-count` | the non-tail-recursive `1 + count rest` length walk |
| `opt-callgraph-add-callee` | name → slot, then `opt-slot-list-add` |
| `opt-callgraph-instr` / `-instr-seq` / `-blocks` / `-callees` | the per-function instruction walk, of which only `Call` / `TailCall` / `CallCAbiStoreResult` / `SpmdCall` callee names produce an edge |
| `opt-callgraph-init-edges` / `-build-slots` / `-build` | `Nil` in every slot, then one adjacency list per slot |
| `opt-callgraph-callee-count` | the range guard plus `opt-slot-list-count` |
| `opt-inline-census-depth-weight` | `8^min(depth, 2)`, computed by the same multiply loop |
| `opt-inline-census-depth-clear!` / `-edge!` / `-ranges!` / `-prefix!` | the block-order back-edge estimate: an edge whose target is at or before its source records `source + 1` in the header slot (furthest latch wins), a descending pass turns the coalesced ranges into a difference sequence, a prefix sum produces each block's depth |
| `opt-inline-census-depths-build!` | the `< 2 blocks` and `no back edge` early-outs that leave the estimate inactive |
| `opt-inline-census-depth-at` | the `active? && position < count` guard |
| `opt-inline-census-bump-map` | `get`, then `insert-ref!` with the old count plus the amount — two probes per counted reference |
| `opt-inline-census-add-ref` | one slot lookup, then a `refcount` bump of 1 and a `hotcount` bump of the site weight |
| `opt-inline-census-add-address` | one slot lookup, then `addrtaken[slot] = 1` |
| `opt-inline-census-blocks` | the site weight installed per block, in block order, whether or not the block holds a reference |
| `opt-inline-census-function` / `-function-seq-from` / `-build` | depths then blocks, per function, over three maps created at `opt-inline-census-capacity` |
| `opt-inline-census-refcount` / `-hot-refcount` / `-address-taken?` | the reader probes: name → slot, then a map `get` or `contains?` |
| `opt-inline-census-absorb-class`, `opt-inline-dup-max-refcount` | `refs < 1 || refs > 2 || self-call || address-taken → 0`, else `refs` |
| `opt-scc-set-low-min!` | the guarded `lowlink[slot] = min(...)` |
| `opt-scc-next-child-from` / `-next-child` | the next child is the smallest slot greater than `after`, found by scanning the **whole** cons list every step |
| `opt-scc-discover!` | index / lowlink / on-stack / node-stack update, returning `(next index, stack len)` through a single-variant payload enum |
| `opt-scc-frame-push!` | the explicit frame stack's `(slot, next = -1)` push |
| `opt-scc-pop-component!` | the pop-until-root loop, returning `(stack len, members)` through a payload enum |
| `opt-scc-copy-order` | the bottom-up order copy |
| `opt-scc-compute` | the whole iterative Tarjan driver, including the four `opt-cfg-fill-i64!` pre-passes |
| `stdlib/hashmap.tl` generated i64→i64 map (`round-capacity`, `growth-limit-for`, `with-capacity`, `clear-ref!`, `probe`, `get`, `contains?`, `insert-ref!`, `needs-grow?`, `grow!`) | the exact policy of `opt_i64_i64_map`, the map all four tables are built on |

## Fidelity

**Kept.** All four tables, edge for edge.

- The function index, the three census maps and their reader probes are
  `stdlib/hashmap.tl`'s scalar family verbatim: power-of-two capacity rounded
  up from `opt-function-index-capacity`, `key * 6364136223846793005` hash,
  linear probing, first-tombstone reuse, the cached `growth-limit =
  capacity - capacity/4` threshold tested once before each insert, and
  `grow!`'s rehash. The four maps live in one interleaved
  `(state, key, value)` slot array with a four-word descriptor each, which is
  the layout the generated module emits (`GeneratedHashmapSlot` array plus
  `len` and `growth-limit`). This is the same policy `benchmarks/gvn_table`
  mirrors for the alias-facts map.
- `OptSlotList` is an index-linked node pool: `-1` is `Nil`, every other head
  is a pool index. The compiler `box`es each `Cons` cell into the optimizer
  arena, so the pool's bump cursor *is* that arena, and resetting the cursor
  per round is the arena rewind the compiler performs per compile. Membership,
  length and next-child are recursive here because they are recursive there.
- `opt-scc-discover!` and `opt-scc-pop-component!` return two values through a
  single-variant payload enum in the compiler; they do here too (and through a
  by-value struct in C).
- `opt-scc-next-child` rescans the entire callee list for every child step,
  making the SCC walk quadratic in a function's out-degree. That is the
  compiler's real cost and is kept.
- A round re-initialises the maps and the node pool without freeing them, as
  the packet requires; the map `clear-ref!` still touches every slot, which is
  what the compiler's fresh zeroed `with-capacity` array costs per compile.

**Dropped, and why none of it changes what is measured.**

1. **The non-counting arms of `opt-inline-census-instr`.** That match has ~50
   arms; every arm except `Call` / `TailCall` / `CallCAbiStoreResult` /
   `SpmdCall` (which add a reference) and the operand walks that can reach a
   `Function` value (which add an address) is pure structural recursion into
   `opt-inline-census-value`, whose `_` case returns the census unchanged. The
   corpus carries exactly the references the counting arms produce, in the
   order they produce them (a call's arguments are censused before its callee
   name, so a `fn@` operand of a call precedes that call's own reference).
   The same holds for `opt-callgraph-instr`.
2. **The block label hash table** (`opt-cfg-label-table-put!` / `-get`) that
   `opt-inline-census-depths-build!` uses to turn a terminator's label into a
   block index. The corpus already carries dense block-order indices, which is
   what that table computes; `benchmarks/cfg_domloops` drops it for the same
   reason. The `(>= id 0)` guard the lookup feeds is kept.
3. **`opt-function-index-fill-from`'s `leaf-starts` and `values`.**
   `opt-symbol-leaf-start` is a scan of the name *text*, and `values` is the
   `ir.CompilerIrFunction` handle; neither is read by any function mirrored
   here, and the corpus is name-text free by construction (the map is keyed by
   the symbol *id*, which is what the kernel hashes).
4. **The `string.eq (compiler-ir-symbol-text name) "main"` disqualifier** in
   `opt-inline-census-single-site?` / `-absorb-class`. No function in any of
   the ten dumps is named `main`, so the test is constant-false over this
   corpus; dropping it cannot change an absorb class.
5. **`opt-scc-copy-order` allocates its result.** Here it copies into a scratch
   array reserved once at the corpus maximum, as rule 5 of the benchmark
   conventions requires. The copy itself is unchanged.
6. **Address-taken references are represented but unexercised.** Both kernels
   implement `opt-inline-census-add-address` and the corpus format carries
   kind 1, but none of the ten `after-fold` dumps contains a `fn@` operand, so
   the `addrtaken` map stays empty. Its *read* path is still exercised: every
   `opt-inline-census-absorb-class` in the fold probes it once per slot.

## Corpus

`data/callgraph.txt` — 1,542,480 bytes, 10 program records, 10,701 functions,
79,274 blocks, 83,141 block-order CFG edges, 34,470 references, 14,383
deduplicated call-graph edges, 10,565 SCCs.

Layout: format version, program count, then per program
`nfuncs dedup-edges scc-count`, then per function
`name-id nblocks nedges nrefs`, `nedges` `src dst` pairs and `nrefs`
`block callee-name-id kind` triples. `#` starts a comment to end of line. The
grammar, the reference kinds and the two self-check quantities are documented
at the top of `tools/export_callgraph.py`.

`name-id` is a 64-bit FNV-1a of the function's mangled name text, masked to 62
bits. The compiler keys `OptFunctionNameIndex.ids` by the name's interned
symbol id, so the kernel must hash the *id*, not the text; the mask keeps the
id inside the compiler's non-negative symbol-id domain, which is what
`opt-function-index-slot-id`'s `(< name-id 0)` rejection tests.

| Program (dump) | functions | blocks | CFG edges | references | graph edges | distinct callees | SCCs | largest SCC |
|---|---|---|---|---|---|---|---|---|
| `lex` | 1034 | 8483 | 9098 | 3769 | 1358 | 597 | 1032 | 2 |
| `read` | 1134 | 9293 | 9972 | 4140 | 1588 | 666 | 1125 | 4 |
| `format_rules` | 643 | 5214 | 5319 | 1388 | 811 | 397 | 595 | 41 |
| `format_tokens` | 505 | 4466 | 4653 | 878 | 510 | 283 | 505 | 1 |
| `token` | 351 | 2687 | 3029 | 1126 | 468 | 186 | 349 | 2 |
| `compiler_object_elf` | 251 | 1777 | 1893 | 672 | 376 | 178 | 251 | 1 |
| `package_lock_core` | 1469 | 10865 | 11415 | 5082 | 2177 | 889 | 1460 | 4 |
| `tlci_loader` | 1487 | 12294 | 13182 | 6030 | 2342 | 956 | 1478 | 4 |
| `compiler_clone` | 1884 | 12057 | 12252 | 5679 | 2392 | 1036 | 1850 | 13 |
| `compiler_diagnostic` | 1943 | 12138 | 12328 | 5706 | 2361 | 1046 | 1920 | 13 |
| **total** | **10701** | **79274** | **83141** | **34470** | **14383** | — | **10565** | **41** |

Provenance: the `--dump-ir after-fold` text of ten compiler modules, compiled
by the 2026-08-25 snapshot compiler (`typelisp` 98bdc6f5, the perf-1
bootstrap-fixpoint stage2 of that day) against its own sources at
`--opt-level 1`. `after-fold` is the **first** opt1 dump point in
`optimize-function-once-with-summaries`, so these are the pre-inline programs
the whole-program inline stage's index, graph, census and SCC solve actually
see. Each dump is a whole program (the module plus everything it imports,
including `stdlib` and `compiler_intern`), so each dump is one program record;
functions repeat between records only through those shared imports, which is
correct because each program is indexed and censused on its own. Within a
record, functions are deduplicated by name, keeping the first occurrence (a
per-pass dump holds one snapshot per pipeline iteration; the census sees each
function once).

The two whole-compiler modules `compiler_load` and `compiler_regalloc` used by
`cfg_domloops` and `gvn_table` are **not** in this corpus: the per-pass dump
path clones the accumulated snapshot buffer on every observation, so its memory
is quadratic in the function count and both modules OOM at 16 GB. Ten modules
in the ~250–2000 function range were dumped instead. Regenerating `--dump-ir`
of any compiler module with a current-main compiler segfaults; that is tracked
by the orchestrator, and the snapshot route below is the supported one, exactly
as in `benchmarks/gvn_table/README.md`.

### Regeneration

```sh
# 1. snapshot compiler and its own sources (git archive 98bdc6f5 src stdlib)
S=<extracted 98bdc6f5 sources>; TL=<snapshot typelisp 98bdc6f5>

# 2. dump each module at the first opt1 dump point
for M in lex read format_rules format_tokens token compiler_object_elf \
         package_lock_core tlci_loader compiler_clone compiler_diagnostic; do
  systemd-run --user --scope -q -p MemoryMax=32G -p MemorySwapMax=0 \
      $TL compile $S/src/$M.tl --dump-ir after-fold -o /tmp/$M.fold.opt1.ir \
      --stdlib-root $S/stdlib --stdlib-root $S/src --opt-level 1
done

# 3. export (the source order is part of the corpus identity)
python3 benchmarks/callgraph_scc/tools/export_callgraph.py \
    benchmarks/callgraph_scc/data/callgraph.txt \
    /tmp/lex.fold.opt1.ir /tmp/read.fold.opt1.ir \
    /tmp/format_rules.fold.opt1.ir /tmp/format_tokens.fold.opt1.ir \
    /tmp/token.fold.opt1.ir /tmp/compiler_object_elf.fold.opt1.ir \
    /tmp/package_lock_core.fold.opt1.ir /tmp/tlci_loader.fold.opt1.ir \
    /tmp/compiler_clone.fold.opt1.ir /tmp/compiler_diagnostic.fold.opt1.ir
```

The exporter writes the corpus byte-identically from the same inputs; only the
`# sources:` comment records the paths it was given.

## Design parameters

| Parameter | Value | Why |
|---|---|---|
| corpus path | argument 1 | runtime-opaque; the corpus is fixed |
| rounds | argument 2, `200` in `optimization.tsv` | tunes TypeLisp Ir to 0.79 G and C to 0.35 G; 200 rounds is 20 passes over each of the ten programs |
| round rotation | program advances by one per round, and the fold's starting slot advances by one | each round folds a different program, and inside a round a different rotation of that program's slots |
| index / census map capacity | `round-up-pow2(count < 4 ? 8 : count * 2)` | `opt-function-index-capacity`, `opt-inline-census-capacity` and `round-capacity` |
| map growth threshold | `len >= capacity - capacity / 4` | `growth-limit-for` for `stdlib/hashmap.tl`'s scalar family. Capacity is at least twice the function count, so `grow!` never fires on this corpus; the test itself is on every insert |
| node pool | one node per reference across the whole corpus, bump cursor reset per round | peak live is one `Cons` per deduplicated edge; the reset is the compiler's arena rewind |
| depth weight | `8^min(depth, 2)` | `opt-inline-census-depth-base` / `-depth-cap` |
| absorb class ceiling | 2 | `opt-inline-dup-max-refcount` |
| checksum | 64-bit FNV-1a, no division | identical bits in TypeLisp i64 and C `uint64_t` |
| folded per slot | SCC id, callee count, refcount, hot refcount, absorb class | the five quantities every inline site reads back; the bottom-up SCC order and the edge total are folded once per round |
| self-check | deduplicated call-graph edge count and SCC count, per program | both are computed independently by the exporter (the edge count from a Python replay of `opt-slot-list-add`'s dedup, the SCC count from an independent recursive Tarjan) and carried in the corpus; each round compares them against its own tables and aborts with exit 134 on a mismatch |

### Expected values

For the shipped corpus the per-program self-check values are the
`dedup-edges` / `scc-count` pair at the head of each program record — for the
ten programs in order: 1358/1032, 1588/1125, 811/595, 510/505, 468/349,
376/251, 2177/1460, 2342/1478, 2392/1850, 2361/1920. Both kernels print

```
$ bench benchmarks/callgraph_scc/data/callgraph.txt 200
-1654139876616047302
$ bench benchmarks/callgraph_scc/data/callgraph.txt 1
-3981303867462412906
```
