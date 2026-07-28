# cfg_domloops

Optimizer CFG context construction over real compiler block graphs.

`bench.tl` and `baseline.c` run the TypeLisp optimizer's own per-function CFG
analysis over block graphs the compiler produced while compiling itself.

## Mirrored compiler functions

All in `src/compiler_optimize.tl`:

| Compiler function | What the kernel replicates |
|---|---|
| `opt-cfg-index-build` | dense block ids in block-list order, CSR successor and predecessor rows, DFS postorder, reverse postorder, RPO numbers |
| `opt-cfg-csr-build` / `opt-cfg-index-fill-rows!` | the two CSR builds, successor rows in `opt-cfg-instr-successors` discovery order, predecessor rows in ascending source order |
| `opt-cfg-index-dfs-postorder!` | mark on entry, append on exit, successors in row order |
| `opt-cfg-dominators-with` | Cooper/Harvey/Kennedy iterative immediate dominators |
| `opt-dom-idom-iterate-rpo!` / `opt-dom-idom-fixpoint!` | RPO sweeps repeated until a sweep changes nothing, bounded by `count + 1` |
| `opt-dom-idom-from-preds` / `opt-dom-intersect-idom` | the two-finger walk up the partial dominator tree keyed on RPO numbers |
| `opt-dom-build-euler!` / `opt-dom-euler-dfs!` | dominator-tree child CSR in ascending id order, then a DFS stamping `tin`/`tout` |
| `opt-dom-info-dominates-id?` | the O(1) Euler-interval dominance test |
| `opt-cfg-natural-loops-with-context` / `opt-cfg-natural-loop-block-seq-csr` | blocks scanned last to first, each CSR successor row forward |
| `opt-cfg-natural-loop-edges-csr` | a reachable successor that dominates its source closes a loop |
| `opt-natural-loop-build` / `opt-natural-loop-collect-body` | body collected backwards from the latch only (a self loop expands nothing), id-indexed marks array as the dedup, most recently added label taken first |
| `opt-natural-loop-find-preheader` / `-preheader-candidate-scan` / `-safe-preheader-block?` | the single outside predecessor whose only successor is the header |
| `opt-cfg-context-build` | the composition of index, reachability, entry label and dominators |

## Fidelity

**Kept.** Every algorithm above, edge for edge: the CSR construction and its row
orders, the DFS postorder, the RPO numbering, the iterative idom fixpoint with
its `count + 1` sweep bound, the Euler tour, the back-edge scan direction, the
loop-body worklist order, and the preheader `None`/`One`/`Many` state machine.

Each loop's body collection clears a whole `count`-entry marks array, which is
what `array.make-array bool (opt-cfg-index-block-count index)` costs per natural
loop in `opt-natural-loop-build`. That per-function loop-enumeration cost is the
one this benchmark exists to track.

**Dropped.**

- The label hash table (`opt-cfg-label-table-*`). The corpus already carries the
  dense ids that `opt-cfg-index-build` computes, so the kernel starts from them.
- The block VALUES. Only the graph shape reaches any of the mirrored algorithms.
- The loop body's label LIST. The checksum folds body sizes, so only the count
  is needed; the marks array, which is the compiler's actual dedup structure, is
  kept.
- The compiler's recursive DFS postorder and Euler tour are written with an
  explicit stack here. Both visit nodes in exactly the same order, so postorder,
  RPO and `tin`/`tout` are identical; only the stack lives in an array instead
  of the call frame.
- Scratch arrays are allocated once at the corpus's maximum block count and
  reused, instead of per function. This keeps the benchmark about the algorithm
  rather than the allocator; both implementations do the same.

## Corpus

`data/cfg-blocks.txt` — 691,629 bytes, 13,243 functions, 116,810 blocks,
123,859 edges.

Per function: block count, edge count, then the successor edges as `src dst`
pairs, blocks numbered 0..n-1 in dump (= block-list) order, which is the CFG id
numbering `opt-cfg-index-build` assigns. `#` starts a comment to end of line.

Provenance: the `--dump-ir after-ssa` text of `src/compiler_load.tl` and
`src/compiler_regalloc.tl`, compiled by the snapshot compiler at
`--opt-level 2`. `after-ssa` is the dump point where `optimize-function-once-
with-summaries` hands `ssa-context` to the dominator-gated passes, so these are
the block graphs the mirrored analyses actually consume. The two dumps together
contain one function snapshot per optimizer pipeline iteration, which is why
there are more records than source functions.

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

# 3. export (source order is part of the corpus identity)
python3 benchmarks/cfg_domloops/tools/export_cfg_blocks.py \
    benchmarks/cfg_domloops/data/cfg-blocks.txt \
    /tmp/compiler_load.ssa.ir /tmp/compiler_regalloc.ssa.ir
```

## Design parameters

| Parameter | Value | Why |
|---|---|---|
| corpus path | argument 1 | runtime-opaque; the corpus is fixed |
| rounds | argument 2, `12` in `optimization.tsv` | tunes TypeLisp Ir to 1.50 G and C to 0.42 G |
| round rotation | starting function advances by one per round | each round folds the same per-function checksums in a different order, so no round repeats an earlier accumulator and nothing can be hoisted |
| checksum | 64-bit FNV-1a, `h = (h ^ x) * 1099511628211` | wrapping multiply and xor only — no division or `%`, so TypeLisp i64 and C `uint64_t` produce identical bits (and the #5982 `%`-on-loop-carried-dividend shape never appears) |
| folded per function | block count, reachable count, the RPO vector, the idom vector, then per loop (header, latch, body size, preheader) and the loop count | covers RPO order, the idom vector, loop count and loop-body sizes |
