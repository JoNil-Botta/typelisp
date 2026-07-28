# gvn_table

Optimizer load-CSE table scan over real compiler instruction tapes.

`bench.tl` and `baseline.c` run the TypeLisp optimizer's block-local redundant
load elimination — the per-instruction dispatch that drives a linked-list load
table, an alias-fact hash map and a dense pointer-kind environment — over
instruction tapes captured immediately before the `gvn` pass while the compiler
compiled itself.

## Mirrored compiler functions

All in `src/compiler_optimize.tl`:

| Compiler function | What the kernel replicates |
|---|---|
| `opt-load-cse-dispatch` | the per-instruction switch: StorePtr / CopyBytes / Load / Call before the clear-all check |
| `opt-load-cse-core-load` | dst invalidation, key build from PRE-def kinds, lookup, rewrite-to-`Mov`, record |
| `opt-load-cse-state-store` | classify, granular filter, 8-byte and sub-word store-to-load forwarding |
| `opt-load-cse-state-copy-bytes` | classify both ends, filter, disjoint same-base field transfer |
| `opt-load-cse-state-direct-call` | `LookupMissing` arm: a `MemoryRead` callee keeps the table, everything else empties it |
| `opt-load-cse-state-clear-for-memory` / `-step-other` | table clear vs def-only invalidation, with facts and kinds surviving |
| `opt-load-key-for-address`, `opt-load-key-eq`, `opt-load-key-uses-var?` | `Raw` / `Field` / `ScaledField` keys and their equality |
| `opt-load-table-lookup` / `-bind` / `-len` / `-remove-key-scan` | list walk, prepend-on-bind, the O(n) length walk before a fresh bind, the cap |
| `opt-load-table-invalidate-var` / `-mentions-var?` | the mention pre-check and the whole-spine rebuild |
| `opt-load-table-filter-store`, `opt-load-entry-survives-store?`, `-survives-store-location?`, `opt-load-ranges-disjoint?`, `opt-load-entry-precedes-fresh-alloc?` | the three keep disjuncts: proven-disjoint root, allocation-epoch ordering, provable byte-range disjointness |
| `opt-load-table-transfer-copy-fields`, `opt-load-copy-entry-within?` | the field-to-field copy transfer |
| `opt-load-classify-store` | Element / Field / Unknown store classes |
| `opt-load-loc-kind-encode` / `-decode`, `opt-load-loc-field-checked`, `-scaled-field-checked` | the packed pointer-kind encoding and its range limits |
| `opt-load-kinds-step` / `-bind` / `-remove` / `-invalidate-def` / `-dense-drop-base-from` / `-dense-ref-add-kind!` | the Gep/Load/Mov kind transfer, the dense generation-stamped workspace, the active vector, the base refcounts and the refcount-gated sweep |
| `opt-load-alias-update-facts`, `opt-alias-update-value-facts`, `opt-alias-copy-var`, `opt-alias-derive-var`, `opt-alias-root-of-var`, `opt-alias-store-root-disjoint?`, `opt-alias-kind-encode` / `-decode` | the alias fact lattice and its packed i64 encoding |
| `opt-load-subword-store-forward-value`, `-subword-forward-const`, `opt-load-table-has-value-with-type?`, `opt-copy-safe-source?` | the sub-word forward gate |
| `opt-load-cse-table-cap-for-size` / `-kinds-cap-for-size` / `opt-load-cse-scaled-cap` | `clamp(max(floor, ninstr / 2), 2048)` for both caps |
| `stdlib/hashmap.tl` generated i64→i64 map (`probe`, `insert-ref!`, `remove-ref!`, `grow!`, `needs-grow?`) | the alias facts map's exact policy |

## Fidelity

**Kept.** The whole block-local state machine.

- The load table is the compiler's singly linked list of `(key, value,
  allocation epoch)` entries with the same size cap, the same prepend-on-bind
  rule, the same whole-spine rebuild on every invalidation, and the same O(n)
  length walk before a fresh bind. A node pool with a free list makes a rebuilt
  spine cost one allocation per surviving entry, which is what the compiler's
  `Cons` rebuild costs.
- The alias facts are an open-addressing i64→i64 map with `stdlib/hashmap.tl`'s
  exact policy: power-of-two capacity, `key * 6364136223846793005` hash, linear
  probing, first-tombstone reuse, tombstones on remove, and growth once
  `(len + deleted) * 4 >= capacity * 3`.
- The pointer kinds are the dense generation-stamped workspace with the active
  vector, the swap-remove, the base refcounts and the refcount-gated
  base-invalidation sweep, plus the same packed encoding. The encoding is
  spelled with shifts and masks here; every packing scale (`2^32`, `4096`, `8`,
  `4`) and every limit (`2^30`, `2^20`, `512`) is a power of two and every
  component is non-negative, so this is the compiler's `/` and `%` arithmetic
  exactly — and it keeps the #5982 `%`-on-live-loop-carried-dividend shape out
  of the kernel.

**Dropped, and why the kept part dominates the real cost.**

1. **Cross-block driver.** The pass is block-local, so the cross-block sweep's
   per-edge `opt-load-cse-state-clone-facts` and `opt-load-cse-state-intersect`
   join are not modelled. Joins run once per CFG edge; the dispatch runs once
   per instruction, and every table/facts/kinds operation a join would perform
   (lookup, bind, rebuild) is already on the per-instruction path.
2. **The GVN stability gate** (`gated?`) is `false` on the block-local path,
   which is the path this tape reproduces (`opt-load-copy-instr-seq-rewrite!`
   passes `false`).
3. **The callee memory-summary map** is empty on the block-local path
   (`opt_i64_i64_map.with-capacity 1`), so a call takes the `LookupMissing` arm
   exactly as it does in the compiler.
4. **Instruction values are not rewritten.** The kernel counts the rewrites the
   compiler would perform instead of allocating replacement IR.
5. **The header set is precomputed by the exporter.** The compiler also builds
   it in one pre-pass per function (`opt-load-header-set-from-function`) rather
   than inside the dispatch.
6. **Literal store values collapse to one identity.** That only reaches
   `opt-load-subword-forward-const`, a constant-normalizing path that never
   consults the table, so no lookup result changes.
7. `opt-load-table-transfer-copy-fields` snapshots its source list before
   binding. The compiler walks an immutable persistent list while threading a
   fresh output list, so snapshotting first is equivalent.

## Corpus

`data/gvn-tape.txt` — 2,446,106 bytes, 2,106 functions, 143,714 instructions,
570 distinct types, stride 5.

Layout: type count, then per type `byte-width is-integer-or-char-or-bool`; then
function count, then per function `nvars nheaders nblocks`, the header var ids,
then per block the instruction count followed by fixed 6-integer rows
`op dst a b c d`. `#` starts a comment to end of line. The opcode table and the
meaning of every field are documented at the top of `tools/export_gvn_tape.py`.

Provenance: the `--dump-ir after-ssa` text of `src/compiler_load.tl` and
`src/compiler_regalloc.tl`, compiled by the snapshot compiler at
`--opt-level 2`. `after-ssa` is the dump point immediately before the `gvn` pass
in `optimize-function-once-with-summaries`, so these are the exact instruction
sequences the load-CSE dispatcher walks. Functions are deduplicated by exact
rendered body (the dump holds one snapshot per pipeline iteration), then the
deduplicated stream is strided so the corpus samples the whole dump uniformly
instead of truncating to its stdlib-heavy prefix.

### Regeneration

```sh
# 1. snapshot the compiler (concurrent activity in the tree)
cp target/bootstrap-fixpoint/stage2 /tmp/tlsnap && chmod +x /tmp/tlsnap

# 2. dump the two modules
/tmp/tlsnap compile src/compiler_load.tl --dump-ir after-ssa \
    -o /tmp/compiler_load.ssa.ir \
    --stdlib-root stdlib --stdlib-root src --opt-level 2
/tmp/tlsnap compile src/compiler_regalloc.tl --dump-ir after-ssa \
    -o /tmp/compiler_regalloc.ssa.ir \
    --stdlib-root stdlib --stdlib-root src --opt-level 2

# 3. export (byte budget and source order are part of the corpus identity)
python3 benchmarks/gvn_table/tools/export_gvn_tape.py \
    benchmarks/gvn_table/data/gvn-tape.txt 3000000 \
    /tmp/compiler_load.ssa.ir /tmp/compiler_regalloc.ssa.ir
```

## Design parameters

| Parameter | Value | Why |
|---|---|---|
| corpus path | argument 1 | runtime-opaque; the corpus is fixed |
| rounds | argument 2, `14` in `optimization.tsv` | tunes TypeLisp Ir to 1.62 G and C to 0.62 G |
| round rotation | starting function advances by one per round | each round folds the same per-function checksums in a different order |
| table cap | `clamp(max(128, ninstr / 2), 2048)` per block | `opt-load-cse-table-cap-for-size` |
| kinds cap | `clamp(max(96, ninstr / 2), 2048)` per block | `opt-load-cse-kinds-cap-for-size` |
| kinds generation | `2 * block-index + 1`, stamps zeroed per function | `optimize-block-seq-hs-dense` |
| facts map | fresh `with-capacity 17` (rounds to 32) per block | `opt-alias-empty` |
| node pool | `4 * max-table-cap + 128`, free list | peak live is bounded by `2 * cap + 2` (a rebuild's old and new spines) |
| checksum | 64-bit FNV-1a, no division | identical bits in TypeLisp i64 and C `uint64_t` |
| folded per block | hits, misses, invalidations, final table size | the four required quantities |
