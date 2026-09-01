# sccp_lattice

Optimizer sparse conditional constant propagation over real instruction tapes.

`bench.tl` and `baseline.c` run the TypeLisp optimizer's `sccp` pass — the
scalar lattice held inline in a dense array indexed by var id, the
CFG-id-backed executable flags, the bounded fixpoint sweep, the integer
constant folder, and the rewrite phase counted rather than materialised — over
functions captured immediately before the `sccp` pass while the compiler
compiled itself.

## Mirrored compiler functions

All in `src/compiler_optimize.tl` unless noted:

| Compiler function | What the kernel replicates |
|---|---|
| `opt-sccp-blocks-with-context-result-raw` | the pass entry: analyse with the function frame, then rewrite only when the lattice ended up holding a `Const` |
| `opt-sccp-analyze-with-frame` / `-analyze-fixed` | sweep while something changed, bounded by `nblocks + 8 + 2 * ninstr` |
| `opt-sccp-initial-state-with-frame` | lattice sized by the frame, every parameter `Overdefined`, the entry block executable |
| `OptSccpValue` (`Unknown` / `Const value type` / `Overdefined`) | a `defenum` with an inline payload, held in a `(__tl_dyn-array SccpValue)` |
| `OptSccpEnv`, `opt-sccp-env-make` / `-fill-unknown!` / `-lookup` / `-set` | the dense array, its `max(cap, 1)` sizing, the Unknown refill, the range checks (out of range reads `Unknown` and drops the write) |
| `opt-sccp-env-any-const?` | the end-of-analysis scan that decides whether the rewrite is the identity |
| `opt-sccp-join`, `opt-sccp-value-eq` | the lattice join and its equality, over `opt-value-eq` / `opt-type-eq` |
| `opt-sccp-state-bind` | join onto the slot, store and raise `changed` only when the join moved it |
| `opt-sccp-state-mark-executable`, `-reset-changed` | the executable-flag set and the sweep's changed reset |
| `opt-cfg-index-id`, `-id-slot`, `-id-map-capacity`, `-fill-id-map!` | the label index: `(label ^ (label >> 5)) & mask` probing a table of `id + 1` entries sized at the next power of two ≥ `2 * nblocks`, insertion in block order, first block wins a duplicate label |
| `opt-sccp-process-blocks-from` / `-process-block` / `-process-instr-seq-from` / `-process-instr` | the block walk, the executable gate, the instruction walk, the per-instruction dispatch |
| `opt-sccp-value`, `opt-sccp-immediate`, `opt-normalize-const`, `opt-default-immediate-type` | var lookup vs. literal normalization, and the fallback-type rule |
| `opt-sccp-fold-binop-value` / `-fold-unop-value` / `-fold-cast-value` | the `Unknown` / `Overdefined` propagation around each folder |
| `opt-fold-binop`, `opt-binop-operand-type` | the operand-type rule (comparisons take the RHS type when the LHS is `i64`, bitwise and shifts take the LHS type, everything else the result type) |
| `opt-fold-int-char-binop`, `opt-fold-compare`, `opt-typed-lt?` / `-le?` / `-gt?` / `-ge?`, `opt-unsigned-lt?` | add/sub/mul/div/mod/safe-div/safe-mod/bit-and/bit-or/bit-xor, the six comparisons, `bit_test_eq` / `bit_test_ne`, and the `opt-integer-type?` gate that refuses `char` arithmetic |
| `opt-normalize-int-to-i64`, `opt-normalize-scalar-to-i64`, `opt-int-width` | the wrap-to-result-width and sign/zero re-extension for every width, and `char` as the 8-bit unsigned code unit |
| `opt-divmod-valid?`, `opt-signed-min`, `opt-fold-div-value`, `opt-fold-mod-value` | the divide-by-zero and `INT_MIN / -1` refusals, signed vs unsigned division |
| `opt-fold-shift`, `opt-shift-count-valid?`, `opt-fold-shl-value`, `opt-fold-shr-value` | the count-type validity rule (signed `0 <= c < width`, `u64` compared unsigned) and arithmetic vs logical right shift |
| `opt-fold-bool` | `and` / `or` / `eq` / `ne` on bool constants |
| `opt-fold-unop` | `Neg` and `BitNot` on integers, `Not` on bool, `Sqrt` refused |
| `opt-fold-cast` over `compiler_float.tl`'s `compiler-finite-cast-fold` / `-input-to-i64` / `-int-to-int-result` / `-normalize-i64` | integer-to-integer casts: normalize to the source type, then to the target |
| `opt-sccp-phi-value`, `opt-sccp-phi-input-value` | the right-folded join over the inputs, with an input from a non-executable predecessor contributing `Unknown`, resolved through the label index |
| `opt-sccp-mark-branch-targets` | a `Const` bool marks only the taken successor, a `Const` of any other shape and `Overdefined` mark both, `Unknown` marks none |
| `opt-sccp-mark-switch-targets` | the default label first, then every case |
| `opt-sccp-rewrite-value` | operand substitutions, counted |
| `opt-sccp-instr-changes-successors?` / `-blocks-change-successors?` | branches whose rewritten condition is a bool literal, counted |
| `opt-sccp-bounds-check-in-range?` | bounds checks whose rewritten index and length are non-negative `I64` constants with `index < length`, counted |

## Fidelity

**Kept.** The whole analysis, edge for edge.

- The lattice is a payload `defenum` stored inline in a dense array indexed by
  var id, which is exactly how `OptSccpValue` lives in `OptSccpEnv.Env`'s
  `(__tl_dyn-array OptSccpValue)`. The array is sized by the function frame —
  `vars N` in the dump *is* `bd-frame`, the value
  `optimize-function-once-with-summaries` hands
  `opt-sccp-blocks-with-context-result-raw` — and refilled with `Unknown` per
  function, which is what `opt-sccp-env-make` costs. Out-of-range reads return
  `Unknown` and out-of-range writes are dropped, as they are in the compiler.
- The executable flags are a `bool` array indexed by dense block id, and every
  label — branch and jump targets, switch cases, phi predecessors — is resolved
  through the compiler's own open-addressed label index with its exact hash,
  capacity rule, insertion order and duplicate-label behaviour.
- The sweep bound, the per-block executable gate, the per-instruction dispatch
  and the whole integer folder are the compiler's: wrapping per result width,
  signed and unsigned comparisons, the shift-count validity rule, the
  divide/remainder refusals, the bool ops, the `opt-integer-type?` gates that
  make `char` arithmetic unfoldable while `char` comparisons still fold.
- The recursive shapes are recursive: `opt-sccp-env-fill-unknown!`,
  `-process-instr-seq-from`, `-process-blocks-from`, `-analyze-fixed`,
  `-phi-value`, `-env-from-params-at` and `-env-any-const?` all recurse in both
  languages, as they do in the compiler.

**Dropped, and why the kept part dominates the real cost.**

1. **Float constants never enter the lattice.** `opt-normalize-const` accepts
   `F64`/`F32` values and `opt-fold-binop` has a float arm; this kernel covers
   the integer semantics the corpus is made of and classifies an `f64` literal
   as `NoConst`, so its instruction binds `Overdefined` — the same lattice
   element the compiler reaches for every non-finite or otherwise unfoldable
   float, at the same one fold call per instruction. Of the corpus's 100,839
   instructions, 592 mention an `f64`/`f32` type at all and 497 of those are on
   a folding opcode.
2. **The rewrite phase is counted, not materialised**, exactly as `gvn_table`
   counts its rewrites. The kernel walks every block (executable or not, as
   `opt-sccp-rewrite-blocks` does), resolves each operand and counts the
   substitutions, the branches that fold to jumps and the bounds checks proven
   in range, instead of allocating replacement IR. Building the replacement
   `CompilerIrInstr`s is allocation, not analysis, and the analysis is what this
   benchmark tracks.
3. **A call's argument list is not modelled.** The tape's fixed-width row
   carries at most two operands, so `opt-sccp-rewrite-call-args` substitutions
   are not counted. The analysis never reads call arguments — a `Call` binds
   `Overdefined` regardless — so no lattice value changes.
4. **`OptSccpState` is module-global state** (label index, executable flags,
   lattice) plus a `changed` flag, rather than a five-field enum threaded by
   value through every call. The arrays are the same objects either way; only
   the flag's home differs.
5. **`opt-cfg-context-build`'s successor/predecessor CSR, dominators and natural
   loops are the exporter's job.** SCCP only ever asks the context for
   `opt-cfg-index-id` and for the terminator's successor labels, both of which
   the tape and the rebuilt label index provide. (The full context build is what
   `benchmarks/cfg_domloops` measures.)
6. **The dump does not print a shift's independently typed RHS**
   (`CompilerIrBinOp.Shl ast.AstType` is metadata, not printed), so the tape
   records the count type as `i64`, which is what the lowerer emits and what
   `opt-shift-count-valid?` therefore sees in practice.
7. **`ir.CompilerIrValue.Char` literals are indistinguishable from `I64`
   literals in the dump** (both print as decimals). Both are accepted
   identically by `opt-value-to-i64`, and `opt-default-immediate-type` agrees on
   them whenever the fallback type is `char`, which is the only context a char
   literal appears in.
8. **The lattice payload is flattened.** `OptSccpValue.Const` carries an
   `ir.CompilerIrValue` and an `ast.AstType`; here it carries (value kind, value
   bits, dense type id). The exporter interns every `AstType` spelling, so
   `opt-type-eq` becomes an id compare and `opt-value-eq` a (kind, bits)
   compare — the same decisions on the same inputs.
9. **`opt-sccp-env-make` allocates a fresh array per function; the kernel
   allocates once at the corpus maximum** and re-stamps the capacity to the
   frame, so the range checks and the Unknown refill are the ones the compiler
   performs. Only the `tl_alloc` call per function is gone.

## Corpus

`data/sccp-tape.txt` — 2,287,127 bytes, 973,977 integers: 2,033 functions,
19,251 blocks, 100,839 instructions, 4,069 parameters, 21,535 successor labels,
9,298 phi inputs, 619 distinct types, stride 3. Largest function frame 3,737
vars; largest block count 257; total lattice slots refilled per round 98,631.

Instruction mix: 42,246 bind `Overdefined` (loads, geps, calls, allocs, packs,
words, bitcasts, addr_of), 15,508 `Mov`, 12,128 bind nothing (stores,
copy_bytes, returns, tailcalls), 7,165 `Jump`, 6,970 `Branch`, 4,293 `Phi`,
1,623 `BoundsCheck`, 1,033 `Cast`, 26 `Switch`, 314 unops and 9,533 binops
(3,059 `eq`, 1,844 `add`, 1,237 `lt`, 944 `mul`, 555 `sub`, 520 `le`, 397 `ge`,
234 `bit_and`, 207 `gt`, 181 `shr`, 152 `ne`, 41 `shl`, 36 `safe_mod`, 34 `div`,
23 `mod`, 21 `bit_or`, 16 `bit_xor`, 15 `safe_div`, 14 `bit_test_ne`, 3
`bit_test_eq`).

Layout: type count, then per type `class byte-width` (`class` 0 other, 1 signed
int, 2 unsigned int, 3 char, 4 bool, 5 f64, 6 f32); then the five self-check
totals; then the function count, then per function
`frame nparams nblocks nsucc nphi ninstr`, the `var type` parameter pairs, the
successor-label pool, the `pred kind value` phi-input pool, the
`label succ-base succ-count instr-base instr-count` block rows, and the
fixed-width `op dst ty ty2 a a-kind b b-kind` instruction rows. `#` starts a
comment to end of line. The opcode table, the operand kinds and the meaning of
every field are documented at the top of `tools/export_sccp_tape.py`.

Provenance: the `--dump-ir after-bounds_dom` text of ten compiler modules,
compiled at `--opt-level 2` by the snapshot compiler. `after-bounds_dom` is the
dump point immediately before the `sccp` pass in
`optimize-function-once-with-summaries`, so these are the exact functions
`opt-sccp-blocks-with-context-result-raw` analyses. Each dump is a whole program
(the module plus everything it imports, including the stdlib and
`compiler_intern`), so functions are deduplicated across the whole file list by
their parameter list, frame size and rendered body, first occurrence winning;
the deduplicated stream is then strided so the corpus samples all ten dumps
uniformly instead of truncating to their shared stdlib prefix.

Labels: the dump spells a block label `<role>.<id>` (`if_then.0`,
`while_exit.10`, `while_body.9__unroll_body`), where the trailing number is the
compiler's own label id. The exporter gives `entry` label 0 and every other
label `id + 1`, falling through to the next free integer when an inlined body
repeats a suffix. The result is the near-contiguous, distinct label set
`opt-cfg-index-id-slot`'s hash is designed for.

**Self-check.** The exporter runs its own SCCP over the encoded tape (`analyse`
in `tools/export_sccp_tape.py`, an independent transcription of
`opt-sccp-analyze-fixed` in Python) and writes its result into the corpus header
as data. Both kernels recompute all five totals and `main` returns 1 if any
disagrees. For the shipped corpus, per round:

| Quantity | Expected |
|---|---|
| vars that end `Const` | 8,938 |
| blocks that end non-executable | 119 |
| operand substitutions the rewrite would make | 2,965 |
| branches that fold to jumps | 250 |
| bounds checks proven in range | 13 |

The exporter also reports 4,368 fixpoint sweeps per round over the 2,033
functions (2.15 on average, 5 at most).

### Regeneration

```sh
# 1. the snapshot compiler and its own sources (see
#    target/bench6-dumps/aug25/README.txt for the provenance model)
S=<extracted 98bdc6f5 sources>; TL=target/dev/tl-aug25s2

# 2. dump the ten modules (16G is enough for each of these; the per-pass dump
#    path is quadratic in the function count, which is why the two largest
#    compiler modules are not in the list)
for m in lex read format_rules format_tokens token compiler_object_elf \
         package_lock_core tlci_loader compiler_clone compiler_diagnostic; do
  systemd-run --user --scope -q -p MemoryMax=16G -p MemorySwapMax=0 \
      $TL compile $S/src/$m.tl --dump-ir after-bounds_dom \
      -o /tmp/$m.bounds_dom.opt2.ir \
      --stdlib-root $S/stdlib --stdlib-root $S/src --opt-level 2
done

# 3. export (byte budget and source order are part of the corpus identity)
python3 benchmarks/sccp_lattice/tools/export_sccp_tape.py \
    benchmarks/sccp_lattice/data/sccp-tape.txt 3000000 \
    /tmp/lex.bounds_dom.opt2.ir /tmp/read.bounds_dom.opt2.ir \
    /tmp/format_rules.bounds_dom.opt2.ir /tmp/format_tokens.bounds_dom.opt2.ir \
    /tmp/token.bounds_dom.opt2.ir /tmp/compiler_object_elf.bounds_dom.opt2.ir \
    /tmp/package_lock_core.bounds_dom.opt2.ir /tmp/tlci_loader.bounds_dom.opt2.ir \
    /tmp/compiler_clone.bounds_dom.opt2.ir \
    /tmp/compiler_diagnostic.bounds_dom.opt2.ir
```

The shipped corpus was produced from the pre-made dumps in
`target/bench6-dumps/aug25/`, so its `# sources:` line names those paths; the
byte order of the file list is part of the corpus identity because
deduplication keeps the first occurrence. `--dump-ir` on any compiler module
crashes in current-main compilers, which is why the dumps come from the
2026-08-25 snapshot compiler compiling its own sources; the crash is tracked by
the orchestrator.

## Design parameters

| Parameter | Value | Why |
|---|---|---|
| corpus path | argument 1 | runtime-opaque; the corpus is fixed |
| rounds | argument 2, `16` in `optimization.tsv` | tunes TypeLisp Ir to 0.86 G and C to 0.42 G |
| round rotation | starting function advances by one per round | each round folds the same per-function checksums in a different order |
| lattice sizing | `max(frame, 1)` slots, where `frame` is the function's `vars N` | `opt-sccp-env-make` called from `opt-sccp-initial-state-with-frame` with the pipeline's `bd-frame` |
| lattice allocation | one array at the corpus maximum (3,737 slots), capacity re-stamped and slots `[0, frame)` refilled with `Unknown` per function | `opt-sccp-env-make` allocates and fills per function; only the allocation is hoisted |
| executable flags | one `bool` array at the corpus maximum (257), cleared over `[0, nblocks)` per function | `__tl_make-array bool (opt-cfg-index-block-count index)` |
| label index capacity | next power of two ≥ `2 * nblocks`, minimum 2 | `opt-cfg-index-id-map-capacity` |
| sweep bound | `nblocks + 8 + 2 * ninstr` | `opt-sccp-analyze` / `-analyze-with-frame` |
| checksum | 64-bit FNV-1a, no division on loop-carried values | identical bits in TypeLisp `i64` and C `uint64_t` |
| folded per function | every `Const` slot's `(index, kind, value, type)`, every executable flag, the const count, the dead-block count, the sweep count, and the running substitution / folded-branch / dropped-bounds-check totals | ties the checksum to the fold results, not just to their count |
| self-check | the five totals above, compared against the exporter's independent Python SCCP carried in the corpus header | a mismatch makes both binaries exit 1 |
