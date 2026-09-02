# regalloc_greedy

The compiler's RAGreedy `selectOrSplit` pass over real live intervals.

`bench.tl` and `baseline.c` run the TypeLisp register allocator's single
allocation algorithm — a spill-weight priority worklist, a per-physreg live
interval union, call clobber as interference, copy-hint and ABI-argument
biasing, eviction with requeue under a cascade cap, and the `RS_*` stage
machine — over the live intervals, spill weights, copy hints, argument
preferences and clobber points that the compiler derived while compiling
itself.

## Mirrored compiler functions

All in `src/compiler_regalloc.tl` unless noted.

| Compiler function | What the kernel replicates |
|---|---|
| `compiler-reg-greedy-alloc-all!` (33891) and its caller `compiler-reg-greedy-state-with-scratch-exclusions` (35216) | the real order of operations: collect the candidate roots, `sort!` them, allocate the pending/evict-count/heap/occupancy state once per function, seed, run |
| `compiler-reg-greedy-collect-vars` | the candidate roots taken out of the candidate sequence in candidate order |
| `compiler-reg-greedy-sort!` / `-merge-pass!` / `-merge-run!` / `-copy-range!` / `-weight-before?` | the stable bottom-up merge sort by (weight desc, var asc), including the strict "tie goes left" rule that makes it stable and the flip-buffer copy-back |
| `compiler-reg-greedy-worklist-seed!` (33745) | the recursive seed: mark each root pending, push it on the heap |
| `compiler-reg-greedy-worklist-run!` (33792) | the recursive pop / dequeue / `alloc-one!` / record-stage loop |
| `compiler-reg-greedy-heap-weight` / `-heap-better?` / `-heap-swap!` / `-heap-sift-up!` / `-heap-sift-down!` / `-heap-push!` / `-heap-pop!` | the binary max-heap over (weight desc, var asc) with the pending array authoritative for membership and lazy discard on pop |
| `compiler-reg-greedy-alloc-one!` (33154) | the whole stage machine: `already-assigned?`, the group-var skip, `var-spans-clobber?` for call/div/shift, the CSR-only restriction for call-spanning and parameter roots, `forbidden-regs`, `arg-pref-reg`, `hint-free-reg`, `first-free`, `first-evictable` + `evict-requeue!`, then spill with `RS_Split` / `RS_Spill` |
| `compiler-reg-greedy-arg-pref-reg` | the free-only ABI argument-register bias, declined for CSR-only roots |
| `compiler-reg-greedy-hint-free-reg` | the copy-hint pick through `assignment-table-lookup` + `pool-index` + the allowed-bank membership scan |
| `compiler-reg-greedy-first-free` / `-first-evictable` | the recursive pool scans from `start-idx` |
| `compiler-reg-greedy-reg-free?` (the sound segmented interference test) | the union fast path plus the per-resident `interferer-max` backstop, with the same three guards (candidate has segments, no coarse resident, candidate is not itself a resident) |
| `compiler-reg-greedy-interferer-max` / `-interferer-max-capped` | the recursive per-word bitset walk, the `evict-cascade-cap` gate and `evict-inf` |
| `compiler-reg-greedy-evict-requeue!` | unassign + re-enqueue + cascade bump, per occupancy word, recursively |
| `compiler-reg-greedy-forbidden-regs` and `compiler-reg-id-seq-contains?` | `{rcx}` for a shift-spanning root, `{rax,rdx}` for a div-spanning one, as a short array scanned linearly |
| `compiler-reg-greedy-occupancy-make` / `-word-index` / `-set-bit!` / `-clear!` / `-assign!` / `-record-location!` | the flat `[register][var-word]` bitset, the primary/secondary home arrays, and the rule that the union is touched only when a bit actually flips |
| `compiler-reg-greedy-pool-index-build` / `-pool-index` | the 104-entry register-id → pool-slot table, first occurrence wins |
| `compiler-reg-live-union-entry-words` / `-neg-inf` / `-effective-start` / `-lower-bound` / `-segment-hits?` / `-interferes?` / `-refresh-max!` / `-insert-segment!` / `-add!` / `-remove!` | the LiveIntervalUnion: three i64 per entry (effective start, end, prefix maximum of end), sorted by effective start, one binary search plus one load per candidate segment, the shift-up insert, and the single merge pass that compacts a removed var's segments out |
| `compiler-reg-greedy-assignment-register!` / `-spill!` / `-unassign!`, `compiler-reg-assignment-table-insert` / `-unassign` / `-lookup` | the present/kind/register assignment table |
| `compiler-reg-interval-overlap?`, `compiler-reg-interval-seq-overlaps?`, `compiler-reg-vars-interfere-segmented-index?`, `compiler-reg-vars-interfere-index?` | the two-cursor segment scan with the half-open rule and the point-0 exception, and the coarse fallback |
| `compiler-reg-call-set-in-range?` / `-call-set-in-range-words?` / `-call-word-in-range?`, `compiler-reg-segments-span-clobber?`, `compiler-reg-greedy-var-spans-clobber?` (34166) | the word-bounded clobber-point scan, the hull gate and the segment-aware answer with its inclusive/exclusive start rule |
| `compiler-reg-low-bit-index32` / `-low-bit-index32-nonzero` | the De Bruijn `0x077cb531` multiply-and-look-up table |
| `compiler-reg-greedy-combine-spill-weights` / `-combine-tie-span`, `compiler-reg-spill-weight-clamp` | `weight = clamp(discounted) * 1024 + (raw scaled into [0,1024))` |
| `compiler-reg-priority-keys!` (14260) / `-priority-band-value` / `-priority-band-span` / `-priority-local-span` / `-block-index-of-point` / `-priority-key-weight` | the local-first band packed under the weight, with the binary search for the owning block and the band-free weight recovered by division for every eviction comparison |
| `compiler-reg-greedy-integer-pool-for-abi` Linux (34072) / `-caller-saved-count` | the 14-register SysV pool in order — `rax rsi rdi r9 rcx rdx r10 r11 r8 \| r12 r13 r14 r15 rbx` — with the caller-saved prefix of 9 |
| `compiler-reg-assignment-table-location-conflicts?` (8663) | the self-check: no two vars holding one register may have overlapping segments |
| `compiler-reg-function-spill-weights` (14453), `compiler-reg-loop-depth-weight` (11497), `compiler-reg-ref-counts-blocks-weighted!` | computed by the exporter (`tools/export_intervals.py`) and shipped as the per-var raw weight; the kernel does the combine and the band packing |
| `compiler-reg-live-intervals`, `compiler-reg-live-interval-selection`, `-instr-seq`, `-blocks-with-live`, `compiler-reg-extend-interval*`, `compiler-reg-segment-note-point!` / `-flush-var!` (`src/compiler_liveness.tl`'s `compiler-live-analyze-function-edge-precise` and `compiler-live-instr-seq-fill-after!` underneath) | ported to Python in the exporter, which is where the shipped segments come from |

## Fidelity

**Kept.** The whole `selectOrSplit` pass, decision for decision.

- The priority order is the compiler's: combined spill weight in the high
  digits and the LLVM local/global enqueue band in the low ones, sorted by the
  same stable merge sort, then re-selected by a binary max-heap whose
  comparator is the same total order. The pending array stays authoritative for
  membership, so a requeued root needs no decrease-key and stale heap entries
  are discarded on pop.
- `reg-free?` is the sound segmented test, answered through the per-register
  LiveIntervalUnion exactly as the compiler answers it: the union is a
  materialised view of the residents' segments, kept sorted by effective start
  with a prefix maximum of `end`, so one binary search plus one load answers a
  whole candidate segment, and the per-resident bitset scan remains as the
  backstop and as the eviction scan.
- Call clobber is interference: a call-spanning root (or one in a parameter
  class) starts its search at the callee-saved offset and takes its copy hints
  only from the callee-saved bank; a div-spanning root loses `{rax,rdx}` and a
  shift-spanning root `{rcx}` while keeping the rest of the caller-saved pool.
  "Spanning" is the segment-aware answer, so a hole in a live range is genuine
  deadness and does not pin the value.
- Eviction is present with its cascade cap and `evict-inf` pinning. On this
  corpus it never fires — the strict descending-weight pop order makes
  `tryEvict` dead on the initial pass, which is exactly what the compiler
  documents for its own forward pass — but `first-evictable` runs for every
  root that reaches it (911 of them), scanning the pool with
  `interferer-max-capped`, so the eviction machinery is on the measured path.
- The De Bruijn bit walks, the assignment table, the occupancy bitset with its
  primary/secondary homes, and the flip-buffer merge sort are all the
  compiler's own data representations.

**Dropped, and why the kept part is what costs.**

1. **The region-split post-pass.** `alloc-one!` returns `RS_Split` for a
   spilled root with a split-eligible (multi-segment) range and the kernel
   counts it; the splitter itself rewrites IR in a separate backend pass and is
   not part of `selectOrSplit`.
2. **Group/pair roots and scratch pseudos.** The compiler leaves both
   unassigned: the group set is empty here (the membership test still runs on
   every pop) and `unspillable-from` is `-1`, which is the value every ordinary
   function passes.
3. **The AVX/XMM and SIMD-integer classes.** They are the same function over a
   different pool with a different caller-saved boundary; running the integer
   class twice would measure nothing new.
4. **The coalescer and the call-spanning save/restore rescue.** Both run
   outside `selectOrSplit`. Consequently the corpus carries per-var intervals
   rather than merged coalesce-class roots, and the copy hint is the direct
   move neighbour rather than its class root.
5. **The remat discount** (`compiler-reg-remat-discount-single-def-spill-weights!`)
   and the foldable-mention rebate. The exporter has no rematerialisability
   judgement, so the combine's discounted input equals its raw input. The
   combine, the clamp, the tie compression and the band packing all still run;
   only the input differs, and the tie-break then never has to break a tie the
   discount created.
6. **Pre-seeded ABI pins.** Every function starts from an empty assignment
   table, so `occupancy-make`'s seeding loop finds nothing to record. That only
   removes residents at t = 0; every resident the pass then creates is
   modelled.
7. **The conflict verification runs on the first round only.** It is a
   per-function property of the finished plan, so checking each function once
   per run is what the self-check needs; the compiler runs it as a debug
   predicate, not on its hot path, and leaving it in every round would have
   made the verifier half the measurement.

## Self-check

Both kernels assert two things and fold both into the checksum.

1. **The plan is conflict-free.** For every pool register, the residents are
   read back out of the occupancy bitset and checked pairwise with the same
   segment interference predicate the allocator used — this is
   `compiler-reg-assignment-table-location-conflicts?`. Expected value: **0**
   conflicts, over every function, for the shipped corpus.
2. **The call-spanning population matches the exporter.** After each function
   the kernel recomputes `compiler-reg-greedy-var-spans-clobber?` for every var
   with a live interval and accumulates the count; at the end it folds
   `seen - expected * rounds` into the checksum, where `expected` is line 3 of
   the corpus. The exporter derived that number independently, in Python, from
   the IR dump. Expected value: **2788** per round.

The exporter also runs the same greedy in Python over the shipped corpus
(`--verify`). Its totals, which both kernels reproduce exactly:

| Quantity | Value |
|---|---|
| register assignments | 29,702 |
| spills | 911 |
| `RS_Split` marks | 911 |
| evictions | 0 |
| conflicts | 0 |
| vars spanning a call | 2,788 |

## Corpus

`data/intervals.txt` — 846,635 bytes, 766 functions, 6,132 blocks, 38,465
instructions, 30,682 vars with a live interval (30,613 of them integer-class
candidates), 34,211 live segments (1.12 per var, up to 52), 2,998 call points,
32 div points, 0 shift points, 1,981 parameter roots, 1,580 copy hints, 6,590
ABI-argument/result preferences. Stride 10.

Variable-count shifts are genuinely rare in this compiler — 54 of them in the
two whole dumps — so the strided sample contains none. The shift-clobber query
still runs for every root; it just always answers "no".

Layout: format version, function count, and the exporter's independent
call-spanning total; then per function `vars nblocks ncand ncall ndiv nshift
nseg nrows`, the `nblocks + 1` block start points, the candidate var ids in
candidate order, the call / div / shift points (doubled instruction indices),
and one row per var that has a live interval:
`var k (start end)*k weight hint argpref flags`. `#` starts a comment to end of
line. Every field and the compiler function it comes from is documented at the
top of `tools/export_intervals.py`.

Provenance: the `--dump-ir` final optimized IR of `src/compiler_load.tl` and
`src/compiler_regalloc.tl`, compiled by the 2026-08-25 snapshot compiler
(typelisp `98bdc6f5`, the bootstrap-fixpoint stage2 of that day) over its own
sources, at `--opt-level 2`. The final IR is what the liveness pass and the
register allocator actually consume, so these are the exact functions the
greedy plans. The exporter then re-derives, in Python, edge-precise liveness
(`compiler-live-analyze-function-edge-precise`), the per-instruction live-after
sets, the segmented live intervals (`compiler-reg-live-interval-selection`, with
the block-entry live-in bridge), the loop-depth-weighted reference counts
(`compiler-reg-function-loop-depths` + `compiler-reg-ref-counts-blocks-weighted!`),
the copy hints, the SysV argument/result preferences and the clobber point
sets. Functions are deduplicated by rendered body, then the encoded stream is
strided so the corpus samples the whole self-compile uniformly instead of
truncating to its stdlib-heavy prefix.

### Regeneration

```sh
# 1. snapshot the compiler (concurrent activity in the tree)
cp target/bootstrap-fixpoint/stage2 /tmp/tlsnap && chmod +x /tmp/tlsnap

# 2. dump the final optimized IR of the two modules
/tmp/tlsnap compile src/compiler_load.tl --dump-ir \
    -o /tmp/compiler_load.final.opt2.ir \
    --stdlib-root stdlib --stdlib-root src --opt-level 2
/tmp/tlsnap compile src/compiler_regalloc.tl --dump-ir \
    -o /tmp/compiler_regalloc.final.opt2.ir \
    --stdlib-root stdlib --stdlib-root src --opt-level 2

# 3. export (byte budget and source order are part of the corpus identity;
#    --verify additionally runs the Python greedy and prints the totals above)
python3 benchmarks/regalloc_greedy/tools/export_intervals.py \
    benchmarks/regalloc_greedy/data/intervals.txt 900000 --verify \
    /tmp/compiler_load.final.opt2.ir /tmp/compiler_regalloc.final.opt2.ir
```

The dumps shipped for this benchmark were produced that way by the 2026-08-25
snapshot compiler and live in `target/bench6-dumps/aug25/`. `--dump-ir` on the
current `main` compilers segfaults for every compiler module; that crash is
tracked separately by the orchestrator, which is why the snapshot route is the
documented one.

## Design parameters

| Parameter | Value | Why |
|---|---|---|
| corpus path | argument 1 | runtime-opaque; the corpus is fixed |
| rounds | argument 2, `7` in `optimization.tsv` | tunes TypeLisp Ir to 0.83 G and C to 0.42 G |
| round rotation | the starting function advances by one per round | each round folds the same per-function checksums in a different order, so no round repeats an earlier accumulator |
| register pool | 14 SysV integer registers, caller-saved prefix 9 | `compiler-reg-greedy-integer-pool-for-abi Linux` with `compiler-reg-rbp-pool-enabled` false |
| eviction cascade cap | 4, `evict-inf` 2^45 | `compiler-reg-greedy-evict-cascade-cap` / `-evict-inf` |
| priority band | weight `* 2097152 + band`, local span 2^20 | `compiler-reg-priority-band-span` / `-priority-local-span` |
| tie compression | raw scaled into 1024 buckets | `compiler-reg-greedy-combine-tie-span` |
| union entry | 3 i64: effective start, end, prefix max of end; start 0 maps to -10^9 | `compiler-reg-live-union-entry-words` / `-neg-inf` |
| var-indexed arrays | 19 arrays of `max vars + 1` = 2,720 i64 | corpus maximum, allocated once, cleared per function |
| segment arrays | 2 arrays of `max segments + 1` = 1,745 i64 | corpus maximum |
| occupancy words | `14 * ceil(max vars / 32)` = 1,190 i64 | one bitset row per pool register |
| live union | `14 * (max segments + 1) * 3` = 73,290 i64 | worst case is one register holding every segment; the compiler grows each union geometrically instead, which the one-shot allocation replaces |
| heap array | `5 * max vars + 16` = 13,611 i64 | a root is pushed once by the seed and at most `cascade cap` = 4 more times by eviction |
| clobber bitsets | 3 arrays of `max point / 32 + 2` = 132 i64 | 32-bit words, matching `compiler-live-set-word-bits` |
| checksum | 64-bit FNV-1a, no division on loop-carried values | identical bits in TypeLisp i64 and C `uint64_t` |
| folded per function | vars, candidates, assignments, spills, `RS_Split` marks, evictions, call-spanning count, conflicts, then every candidate's stage / location kind / register | the whole plan, not a summary of it |
