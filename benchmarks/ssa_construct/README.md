# ssa_construct

The optimizer's SSA construction — phi placement plus renaming — over the real
non-SSA functions the compiler hands its `ssa` pass.

`bench.tl` and `baseline.c` run the TypeLisp optimizer's `ssa` pass over the
function snapshots the compiler produced while compiling itself, taken at the
`after-rotation` dump point, which is exactly where
`optimize-function-once-with-summaries` calls
`opt-ssa-construct-function-from-context-and-representations-result`.

## Mirrored compiler functions

All in `src/compiler_optimize.tl`:

| Compiler function | What the kernel replicates |
|---|---|
| `opt-ssa-construct-function-from-context-and-representations-result` | the entry: build the CFG context, run the single-def gate, build facts, then the four early-outs, then construct |
| `opt-ssa-construct-with-context-result` | insert phis, rename, materialize, verify |
| `opt-verify-single-defs?` / `opt-verify-param-def-set` / `-instr-def-seq-from` / `opt-var-set-add-unique!` | the gate: a `vars`-sized presence array, params then every block's destinations, first repeat fails |
| `opt-instr-def-var` / `opt-instr-def-position` | which instructions define a vreg (Pack/Word included) and that a phi's definition position is 0 |
| `opt-ssa-facts-from-function-with-representations` / `-add-params` / `-add-blocks` / `-add-instr` | definition counts and the `bad` set in two open-addressed `i64 -> i64` maps, plus the dense var → type table with its insertion-order sidecar |
| `opt-ssa-facts-add-def-ty` / `-add-def-bad` / `opt-ssa-facts-bad-var` | count, then reject non-register types, conflicting redefinition types, `Alloc`/`Gep`/vector/mask/`Select`/`Syscall` destinations, and `AddrOf`'s *source* |
| `opt-ssa-register-value-type?` / `opt-ssa-fixed-register-value-type?` | the fixed one-word register boundary (the corpus type class carries its verdict per printed type) |
| `opt-ssa-var-types-set` / `-count` / `-newest-var` | the dense var → type table and the NEWEST-FIRST walk order every later phase uses |
| `opt-ssa-candidate?` | `count > 1`, not in `bad`, has a type |
| `opt-ssa-any-candidate?` / `opt-ssa-blocks-have-candidate-phi-dst?` / `opt-ssa-context-within-budget?` (4096 blocks) / `opt-ssa-entry-has-preds?` | the four early-outs, all four evaluated |
| `opt-ssa-def-blocks-from-function` / `-add-params` / `-add-blocks` / `opt-ssa-var-blocks-add` / `opt-ssa-label-add-with-members` | per candidate var, the set of defining blocks, deduplicated through a freshly zeroed block-count member array allocated on the var's first definition site |
| `opt-ssa-insert-phis` / `-types` / `-for-var` / `-worklist` | candidate vars in newest-first type order; `work-members` and `site-members` cleared for EVERY candidate; the worklist is a LIFO seeded with the def blocks |
| `opt-cfg-dominance-frontier-with-context` / `-blocks` / `-block?` / `opt-cfg-frontier-has-reachable-pred-id?` | DF(label) recomputed from scratch on every worklist pop: a full block scan, each block accepted when it is reachable, has a reachable predecessor `label` dominates, and is not strictly dominated by `label`; `opt-label-add` re-scans the growing set |
| `opt-ssa-phi-add-frontier` / `opt-ssa-phi-add-site` | frontier blocks in ascending id order; one site per (var, block); a new site pushes its block back on the worklist |
| `opt-ssa-env-with-capacity` / `-register` / `-slot` / `-lookup` / `-bind` / `-checkpoint` / `-rollback` | the compact candidate-slot environment and its exact-capacity undo log |
| `opt-ssa-env-snapshot` / `-snapshot-lookup` | the per-block clone of the compact `current`/`present` prefixes and the lookup through the shared `by-var` map |
| `opt-ssa-env-for-function` / `-candidate-count-from` / `-binding-count-from` / `-register-candidates-from` / `opt-ssa-env-from-params` | slot registration in newest-first order, then the parameter bindings |
| `opt-ssa-env-bind-phis` / `-bind-phis-from` | a full newest-first scan of every phi site for every block entered |
| `opt-ssa-rename-function-blocks` / `opt-ssa-rename-tree` / `-tree-work` | the dominator-tree walk on a dense enter/exit work stack, children linked highest-id-first so the LIFO pops them ascending, an exit record rolling the env back to the block's entry checkpoint |
| `opt-ssa-rename-instr-seq-from` / `opt-ssa-rename-instr` / `opt-ssa-rename-dst` / `opt-ssa-rewrite-value` | per instruction: rewrite each use through the env, then give a candidate destination a fresh vreg and bind it; a `Phi` passes through untouched |
| `opt-ssa-rename-missing-blocks` | blocks the dominator walk never reached, renamed from the initial env and rolled back |
| `opt-ssa-rename-blocks-lookup-index` / `opt-ssa-block-out-lookup` | the linear newest-first scans the compiler really performs, per block and per phi operand |
| `opt-ssa-materialize-blocks` / `opt-ssa-push-phis-for-label!` / `-from!` | per block: the inserted phis in newest-first site order, then the renamed body |
| `opt-ssa-phi-inputs` / `opt-ssa-phi-undef-input` | one operand per predecessor, in `opt-cfg-index-predecessors` order (the CSR row read newest-first), each resolved in that predecessor's OUT snapshot, an unbound candidate taking the typed undef constant |
| `opt-ssa-rewrite-preexisting-phi-inputs` / `opt-ssa-push-rewritten-preexisting-instrs!` | a lowerer-emitted phi's candidate operands re-resolved per edge in the predecessor's OUT snapshot |
| `opt-ssa-construct-checked` / `opt-verify-function-with-context` | the verify over the constructed function: single definitions, then every use in a reachable block dominated by its definition (phi operands checked at the end of their named predecessor); a failure is the real reject that throws the construction away |
| `opt-cfg-index-build` / `opt-cfg-csr-build` / `opt-cfg-index-dfs-postorder!` | dense block ids in block-list order, CSR successor and predecessor rows, DFS postorder, RPO, RPO numbers |
| `opt-cfg-dominators-with` / `opt-dom-idom-iterate-rpo!` / `opt-dom-intersect-idom` / `opt-dom-build-euler!` / `opt-dom-info-dominates-id?` | Cooper/Harvey/Kennedy iterative idoms bounded by `count + 1` sweeps, the Euler `tin`/`tout` stamping, the O(1) interval dominance test |
| `stdlib/hashmap.tl` `(hashmap i64 i64)` | `hash-key = key * 6364136223846793005`, mask by a power-of-two capacity, linear probing, `capacity - capacity/4` growth limit, doubling growth with a per-slot rehash — `opt_i64_i64_map` is this family |

## Fidelity

**Kept.** Every algorithm above, including the parts that make the pass
expensive and that a "textbook" SSA construction would not have:

- The dominance frontier is **recomputed from scratch on every worklist pop**
  (`opt-cfg-dominance-frontier-blocks` walks the whole block list and, per
  block, its whole predecessor row). There is no DF cache in the compiler and
  there is none here.
- `opt-ssa-insert-phis-for-var` **clears both block-sized member arrays for
  every candidate var**, which is what `opt-cfg-fill-bool!` costs per candidate.
- `opt-ssa-var-blocks-add` **allocates and zeroes a fresh block-count member
  array** the first time a var gets a definition site.
- `opt-ssa-env-bind-phis`, `opt-ssa-rename-blocks-lookup-index` and
  `opt-ssa-block-out-lookup` are **linear newest-first scans**, run per block
  entered and per phi operand resolved. That is O(blocks × sites) and
  O(blocks²) work the compiler really performs.
- `opt-ssa-env-snapshot` **clones the compact current/present prefixes per
  block exit**.
- The definition counts and the `bad` set are a real open-addressed
  `i64 -> i64` hash map with the stdlib's hash, probe order, growth limit and
  doubling rehash — not a dense array.
- The newest-first order of `opt-ssa-var-types-newest-var`, which determines
  which candidate is processed first and therefore the numbering of every
  inserted phi vreg and every renamed definition.
- All four early-outs are evaluated on every record even though this corpus
  never trips one (see Corpus).
- The post-construction verify, including the 42 records where it legitimately
  fails and the pass throws its work away.

**Dropped.**

- The IR itself. Phi operands are resolved and folded into the checksum rather
  than materialized as `ir.CompilerIrInstr.Phi` values; the renamed body is
  written into a flat integer pool with the same per-instruction record the
  corpus uses. Every lookup, snapshot read and resolution the compiler performs
  is performed; only the allocation of the result instruction is not.
- The label hash table (`opt-cfg-label-table-*`, `opt-cfg-index-id`). The
  corpus already carries the dense block ids `opt-cfg-index-build` computes, so
  every `label` here is already an id. This does not change which blocks the
  algorithms visit or in what order.
- The geometric regrowth inside a function: `OptLabelSet.Dense` doubling, the
  `opt_ssa_dense_vec` pushes for phi sites / rename blocks / block outs, and
  `opt-ssa-var-types-set`'s vector growth. Each of those buffers is a slice of
  one array sized at the corpus maximum here. The element *counts*, the
  insertion orders and the scan orders are identical; only the amortized
  `realloc`+copy is gone, and it is gone from both languages equally.
- `opt-ssa-register-value-type-with-representations?`'s representation index.
  The dumps do not carry `ir.CompilerIrRepresentationIndex`, so the kernel uses
  the compat entry `opt-ssa-register-value-type?` (the fixed one-word boundary),
  which is what the corpus type classes encode. This can only *shrink* the
  candidate set relative to a run with representations; the exporter and both
  kernels agree on it exactly.
- The context is always built (`entry-context-valid? = false`). The `rotation`
  pass usually hands a valid context down; the kernel takes the documented
  fallback branch, which it needs anyway because every dominance-frontier query
  reads the dominator tree.
- The compiler's recursive walks (`opt-ssa-facts-add-instr-seq-from`,
  `opt-cfg-dominance-frontier-blocks`, `opt-ssa-phi-add-frontier`,
  `opt-ssa-rename-missing-blocks`, the DFS postorder and the Euler tour) are
  written as loops with explicit stacks. Every one of them is either tail
  recursive or visits nodes in an order the loop reproduces exactly; the
  dominance frontier's set-build order and the phi-site order were checked
  against the `OptLabelSet.Dense` read convention (`opt-label-ref 0` is the
  newest element) and are unchanged.
- Scratch arrays are allocated once at the corpus maxima and reused instead of
  per function. Both implementations do the same.

## Corpus

`data/ssa-funcs.txt` — 477,119 bytes, 475 function snapshots, 6,983 blocks,
40,285 instructions, 1,328 candidate vregs, 2,812 inserted phis, 721 distinct
type classes.

Per function: `frame nparams nblocks ninstrs expect-candidates expect-phis
expect-verify`, then the parameters as `var typeclass` pairs, then per block
`nsucc succ... ninstr` followed by the instructions. Blocks are numbered
0..n-1 in dump (= block-list) order, which is the CFG id numbering
`opt-cfg-index-build` assigns; successor edges are in `opt-cfg-instr-successors`
discovery order (the terminator rules of
`benchmarks/cfg_domloops/tools/export_cfg_blocks.py`). Instruction records name
the `opt-ssa-facts-add-instr` arm they land in:

```
0 nuses use...            no destination
1 nuses use... def ty     opt-ssa-facts-add-def-ty
2 nuses use... def        opt-ssa-facts-add-def-bad
3 nuses use... def        addr_of: def bad AND use[0] poisoned
4 nuses use... def        pack/word: defines def, facts ignore it
5 def ty nin (val pred)*  a lowerer-emitted phi; val -1 is a constant
```

`ty` is a nonzero signed type-class id: the magnitude interns the printed
TypeLisp type, the sign is `opt-ssa-register-value-type?`. `#` starts a comment
to end of line.

Provenance: the `--dump-ir after-rotation` text at `--opt-level 2` of ten
compiler modules, compiled by the 2026-08-25 snapshot compiler
(`98bdc6f51bc491097fa81c1c7fdf980e65156674`) on its own sources —
`src/lex.tl`, `src/read.tl`, `src/format_rules.tl`, `src/format_tokens.tl`,
`src/token.tl`, `src/compiler_object_elf.tl`, `src/package_lock_core.tl`,
`src/tlci_loader.tl`, `src/compiler_clone.tl`, `src/compiler_diagnostic.tl`.
`after-rotation` is the dump point where `optimize-function-once-with-summaries`
hands the function to `ssa`, so these are the exact non-SSA functions the
mirrored pass consumes. Each dump is a whole program (the module plus
everything it imports, including `stdlib` and `compiler_intern`) and holds one
snapshot per optimizer pipeline iteration, so the exporter deduplicates by
exact rendered body ACROSS all ten files, first occurrence winning.

Of the 18,943 snapshots in those ten dumps, 6,366 bodies are distinct; 5,738 of
those already satisfy `opt-verify-single-defs?` (the pass returns them
unchanged) and are dropped, 153 could not be parsed (a `message "…"` operand
whose string spans lines breaks the line-oriented reader) and are dropped, and
the remaining 475 — the records the pass actually transforms — are the corpus.
The rendered corpus is 0.48 MB, under the 3 MB budget, so the stride is 1.

None of the 475 trips an early-out: every one of them has at least one
candidate, none has a candidate phi destination, none exceeds the 4096-block
budget, and none has predecessors on its entry block (the `rotation` pass has
already inserted the `entry__ssa_entry` preheader where one was needed). The
four checks still run on every record because they are part of the pass.

42 of the 475 fail the post-construction verify. That is not a defect: those
functions contain a NON-candidate vreg that is already defined more than once
(an `alloc`/`gep` destination, or a vreg redefined at a conflicting type), so
the constructed function still fails `opt-verify-single-defs?` and
`opt-ssa-construct-checked` discards the construction and keeps the pre-SSA
function. The exporter predicts this independently and the kernels assert it.

### Regeneration

```sh
# 1. the snapshot compiler and its sources (see target/bench6-dumps/aug25/README.txt)
S=<extracted 98bdc6f5 sources>; TL=target/dev/tl-aug25s2

# 2. dump each module after the rotation pass (16G is enough for these modules;
#    compiler_load / compiler_regalloc OOM in the per-pass dump path, which is
#    why the corpus comes from medium modules)
for m in lex read format_rules format_tokens token compiler_object_elf \
         package_lock_core tlci_loader compiler_clone compiler_diagnostic; do
  systemd-run --user --scope -q -p MemoryMax=16G -p MemorySwapMax=0 \
      $TL compile $S/src/$m.tl --dump-ir after-rotation \
      -o target/bench6-dumps/aug25/$m.rotation.opt2.ir \
      --stdlib-root $S/stdlib --stdlib-root $S/src --opt-level 2
done

# 3. export (file order is part of the corpus identity: first occurrence wins)
python3 benchmarks/ssa_construct/tools/export_ssa_funcs.py \
    benchmarks/ssa_construct/data/ssa-funcs.txt 3000000 \
    target/bench6-dumps/aug25/lex.rotation.opt2.ir \
    target/bench6-dumps/aug25/read.rotation.opt2.ir \
    target/bench6-dumps/aug25/format_rules.rotation.opt2.ir \
    target/bench6-dumps/aug25/format_tokens.rotation.opt2.ir \
    target/bench6-dumps/aug25/token.rotation.opt2.ir \
    target/bench6-dumps/aug25/compiler_object_elf.rotation.opt2.ir \
    target/bench6-dumps/aug25/package_lock_core.rotation.opt2.ir \
    target/bench6-dumps/aug25/tlci_loader.rotation.opt2.ir \
    target/bench6-dumps/aug25/compiler_clone.rotation.opt2.ir \
    target/bench6-dumps/aug25/compiler_diagnostic.rotation.opt2.ir
```

`--dump-ir` of any compiler module segfaults on the current `main` compiler;
that is tracked separately by the orchestrator, which is why the corpus is
produced by the pinned 2026-08-25 snapshot compiler, exactly as
`benchmarks/cfg_domloops` and `benchmarks/gvn_table` are.

## Self-check

Both kernels check three quantities the exporter computed independently, in
Python, from the dump text, and fold each verdict into the checksum:

| Check | Value on the shipped corpus |
|---|---|
| candidate vregs (`opt-ssa-candidate?` over the newest-first type table) | 1,328 over 475 functions, all matching |
| inserted phis (the iterated-dominance-frontier worklist) | 2,812 over 475 functions, all matching |
| post-construction `opt-verify-single-defs?` + use dominance | passes on 433 functions, legitimately rejects 42, all matching |

The kernels additionally re-run the compiler's own single-definition check over
the constructed function and test that every use in a reachable block is
dominated by its definition (the Euler interval test; a phi operand is tested at
the end of the predecessor that names it). A regression in any of these changes
the printed number.

`benchmarks/ssa_construct/data/ssa-funcs.txt 12` prints
`-6337438944309563842` from both binaries. Round 1 alone prints
`-2669433236562809599`.

## Design parameters

| Parameter | Value | Why |
|---|---|---|
| corpus path | argument 1 | runtime-opaque; the corpus is fixed |
| rounds | argument 2, `12` in `optimization.tsv` | tunes TypeLisp Ir to 0.83 G and C to 0.43 G |
| round rotation | starting function advances by one per round | each round folds the same per-function checksums in a different order, so no round repeats an earlier accumulator and nothing can be hoisted |
| checksum | 64-bit FNV-1a, `h = (h ^ x) * 1099511628211`, basis `1469598103934665603` | wrapping multiply and xor only — no division or `%`, so TypeLisp i64 and C `uint64_t` produce identical bits |
| folded per function | the early-out taken (or 6 for a full construction), the candidate count, the inserted-phi count, the final vreg count, the number of renamed definitions, the verify verdict, the three self-check verdicts, and then every materialized instruction's kind, destination and resolved operands | covers the phi placement, the renaming, and every phi-operand resolution id |
