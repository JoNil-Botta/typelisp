# peephole_lines

Backend streaming peephole and dead-store sweep over the compiler's own
emitted assembly.

`bench.tl` and `baseline.c` run the TypeLisp backend's assembly-text optimizer:
the fallthrough-jump scan, the streaming peephole that classifies every emitted
line and applies the pair rule set and the per-register reload-elision owner map
while pushing line records, and the dead-store sweep over those records.

## Mirrored compiler functions

All in `src/compiler_backend.tl`:

| Compiler function | What the kernel replicates |
|---|---|
| `compiler-backend-drop-fallthrough-jumps` | one forward pass, at most one deferred `    jmp SYM` candidate, excised only when nothing but label definitions separates it from a matching label |
| `compiler-backend-asm-direct-jmp-line?` / `-asm-label-def-line?` / `-asm-jmp-prefix-at?` | the two line predicates that pass keys on |
| `compiler-backend-peephole-asm-once-records-chunks` | the streaming walk with one pending descriptor, `prev-abort?`, and owner state carried across lines |
| `compiler-backend-peephole-parse-line` | the transient descriptor: mnemonic token, the ten line predicates, the movq/zext operand split, owner keys, operand flags, register indices |
| `-movq-prefix-at-range?`, `-mnemonic-zext?`, `-mnemonic-call?`, `-mnemonic-single-dest?`, `-cmp-or-test-token?`, `-line-noreturn-abort?`, `-token-len`, `-find-comma-space-range` | the byte-level classifiers, including the packed three-byte mnemonic keys |
| `-register-range?`, `-reg-index-range`, `-last-operand-reg-index` | the 14 owner-tracked GP registers |
| `-memory-base-range`, `-owner-key-from-range`, `-stack-owner-key-from-parts`, `-decimal-range-valid?` / `-decimal-range-value`, `-stack-parens-range`, `-operand-flags` | the operand classification and the packed stack-slot owner keys |
| `compiler-backend-peephole-pair-action-desc` | the five rule outcomes: 0 emit pending, 1 replace pending, 2 drop next, 3 forward frame load, 4 r10 base fold |
| `-redundant-zext-pair-desc?` / `-redundant-zext-next-desc?`, `-line-self-move-desc?` | the two rules that gate the action table |
| `compiler-backend-peephole-emit-line-desc-record` | reload elision, the cross-register reuse rewrite, and the record push |
| `-movq-owners-transfer-keyed-index`, `-owners-clear-slot`, `-owners-clear-call-clobbers`, `-owners-find-reg-for-slot-index`, `-line-clobber-owners-desc` | the owner map transfers for stores, loads, clobbers and calls |
| `compiler-backend-deadstore-sweep-records!` / `compiler-backend-sweep-region-records!` | the two-pass region sweep: rsp-delta replay, address-taken watermark, read-range overlap test, `live` mask marking |

## Fidelity

**Kept.** The line classification, the whole pair rule set with its pending-line
state machine, the 14-register owner map with its store / load / clobber / call
transfers, the record array with its `live` deletion mask, and the two-pass
dead-store sweep with its rsp-delta replay, address-taken watermark and
read-range overlap test.

**Dropped, and why.**

1. **Rewritten line TEXT is never materialized.** An action 3 or 4 outcome, and
   the cross-register reload rewrite, produce `    movq SRC, DST` from two
   operand spans that already exist in the corpus, so the record keeps the two
   spans instead of the `str-cat` result. Every rule only ever re-reads those
   operands, and the checksum counts lines rather than bytes. The one observable
   consequence is handled explicitly: a reuse-rewritten line no longer reads its
   frame slot, so its sweep read is cleared.
2. **`SYM(%rip)` global owner keys are dropped.** They need the backend's live
   intern table, which the peephole runs after tearing down
   (`compiler-backend-peephole-owner-global-*` exists precisely because of
   that). Stack-slot keys, which drive every reload rule, are kept exactly.
3. **The carry-safe label set and the r10-dead forward scan are dropped.** Both
   depend on per-function backend state that is not in the assembly text, so a
   label always resets the owner map and rule 4 requires its own `%r10`
   destination instead of consulting `-r10-dead-after-desc?`.
4. **The sweep's frame window comes from the register allocator.** Here the
   whole function chunk is the region, which is what the sweep degrades to when
   the recorded window covers the frame. The candidate and read collection caps
   (4096 each) stand in for the compiler's growable push arrays.
5. **The fallthrough scan counts rather than excises.** It runs as its own
   forward pass over the chunk, exactly as `compiler-backend-drop-fallthrough-
   jumps` does over an assembled body, but the peephole then re-reads the
   original text. The scan's own work — the per-line label/jmp classification
   and the deferred-candidate state machine — is unchanged.
6. `-line-noreturn-abort?` is spelled as `call tl_*abort` rather than the
   compiler's explicit literal list.

## Corpus

`data/self-compile.asm` — 2,789,404 bytes, 101,747 lines, 1,190 function chunks
sampled from 16,652 with stride 14.

Provenance: the `.s` the snapshot compiler emits for `src/main.tl` at
`--opt-level 2` — literally the text
`compiler-backend-peephole-asm-once-records` streams over when the compiler
compiles itself. The full file is ~41 MB, so a strided sample of its function
chunks is kept. A chunk starts at a line whose first non-space bytes are
`.globl` and runs to just before the next one, matching
`compiler-backend-peephole-chunk-starts-global?`, which is where pending-pair
and owner state are conservatively reset anyway; everything before the first
`.globl` (the file prologue) is always kept.

The corpus is checked in as `.asm`, not `.s`: the repository's root
`.gitignore` ignores `*.s` (generated assembly), which would silently keep it
out of the commit and leave both implementations with no corpus to read.
`data/.gitattributes` pins it to LF so the line scan — and therefore the
printed checksum — is the same on Linux and on Windows CI runners.

Because the kept chunks are not adjacent in the original file, a `jmp` whose
target block was dropped simply stays (the fallthrough scan only excises a jump
whose target label it actually reaches), so the sample changes rule-hit counts
slightly relative to the whole file. Within one function every label is local
and present, which is where all the pair rules and nearly all the fallthrough
jumps live.

### Regeneration

```sh
# 1. snapshot the compiler (concurrent activity in the tree)
cp target/bootstrap-fixpoint/stage2 /tmp/tlsnap && chmod +x /tmp/tlsnap

# 2. emit the compiler's own assembly
/tmp/tlsnap compile src/main.tl -o /tmp/main.s \
    --stdlib-root stdlib --stdlib-root src --opt-level 2

# 3. sample it (the byte budget is part of the corpus identity)
python3 benchmarks/peephole_lines/tools/export_asm_slice.py \
    benchmarks/peephole_lines/data/self-compile.asm 3000000 /tmp/main.s
```

## Design parameters

| Parameter | Value | Why |
|---|---|---|
| corpus path | argument 1 | runtime-opaque; the corpus is fixed. A missing argument or an unreadable corpus is an empty text on both sides, so both print the same checksum and exit 0 |
| rounds | argument 2, `2` in `optimization.tsv` | tunes TypeLisp Ir to 1.72 G and C to 0.46 G |
| round rotation | starting chunk advances by one per round | each chunk is an independent peephole group, so rotating them is faithful and makes every round's accumulator differ |
| owner map | 14 registers, `%rbp`/`%rsp` untracked | `CompilerBackendPeepholeOwners` |
| sweep caps | 4096 candidates, 4096 reads per region | stands in for the compiler's growable `compiler-backend-sweep-i64-push` arrays |
| checksum | 64-bit FNV-1a, no division | identical bits in TypeLisp i64 and C `uint64_t`; no `%` on a live loop-carried dividend (#5982) |
| folded per chunk | record count, kept, dropped, rule 1..4 hits, elided reloads, cross-register reuses, fallthrough jumps dropped, dead stores swept | kept lines, dropped lines, and rule hits by class |
