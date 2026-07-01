# next_session.md — Register-allocation / static-mov-count campaign handoff

Branch: `llvm-inlining`  •  HEAD: `32d7b0ba9` (SplitKit rewrite M4)  •  Session goal: reduce the
static `movq -N(%rbp),reg` reload count toward clang levels, then finish the backlog → PR → CI.

---

## 1. TL;DR — where we are

- **The static mov-count campaign is at its practical floor.** Census baseline was **212,384**
  reloads (66% spill traffic). We banked **−15.4%** (down to **179,714** at commit `8cd70e553`),
  entirely from a **register-allocation phase**: model-bug fixes (the "−16.3%" swarm batch),
  the CFG-aware cross-block reload-elision peephole, and loop-carry coalescing.
- **The full multi-week SplitKit rewrite (M1–M5) is DONE and is a rigorously-measured NEGATIVE.**
  M1–M4 (committed) built and proved the machinery byte-identically; **M5 (the payoff, uncommitted)
  recovers 0 self-host reloads (+385 regression).** Root cause: the post-call reloads it targets are
  **already served** without a `movq -N(%rbp)` — by the `#153` cross-block peephole and the `#62`
  load-fold (folded memory operands aren't reloads). Nothing left to remap.
- **Definitive conclusion:** even the full non-bounded SplitKit — the last remaining static lever —
  recovers ~0. The residual is **~16% genuine call-spanning pressure (clang pays it too)** + a
  **P≤5 quality gap that is folding-dominated** (not a movq-reload gap). See
  `target/reload-categorization.md` (the asm-grounded verdict).

### ⚠️ OPEN DECISION (was mid-`AskUserQuestion` when the session ended)
Pick the endgame for the static campaign:
1. **(Recommended) Revert the inert SplitKit infra (M1–M4), ship the −15.4% PR.** The SplitKit is a
   proven negative on the movq metric; the −15.4% + correctness fixes are the real, landable win.
   Then finish the pre-PR backlog → rebase onto `origin/main` → PR → green CI.
2. **Attempt the untried §4 region-based realization** (region-based on post-caller-save blocks, not
   verbatim-only + surgical live-occupant liberation, targeted by an *emit-time* reload proxy).
   Multi-day, miscompile-prone, and by the M5 agent's analysis **likely also ~0** (folding-dominated).
3. **Keep the SplitKit infra committed as a documented foundation + ship anyway** (small +code-size
   cost, preserves the machinery for a future §4).

---

## 2. Commits landed this session (newest first)

| commit | what |
|---|---|
| `32d7b0ba9` | SplitKit rewrite **M4** — enable safe-subset split on the real path (declines everything → byte-identical; safe subset is peephole-redundant) |
| `f66347893` | SplitKit rewrite **M3** — `splitkit-rewrite-blocks` realization pass (inert on self-host, stress-proven: 11 pieces realize + double self-compile) |
| `0eecbb305` | SplitKit rewrite **M2** — `trySplit` decision + minting/re-queue substrate (byte-identical; termination-bounded; stress-self-compiles at scale) |
| `fb5f26716` | SplitKit rewrite **M1** — `CompilerRegSplitPlan` + build the split-kit on the real allocation path (byte-identical infra, +42 code-size) |
| `8cd70e553` | **#147 coalesce** loop-carried phi pairs via edge-precise liveness (qs_partition 28→8 fixture; suite-neutral; found+fixed a real mis-coalesce via 14-step asm-splice bisection) |
| `5ec453f6e` | **#151 bomb** — fix scavenge occupancy-mask point for fused destructure loads (latent clobber → SIGSEGV) |
| `edd40f5e4` | **SplitKit Step 0** — preserve segment+coalesce structure through spill (byte-identical foundation) |
| `41a5f03ae` | **#153** — CFG-aware cross-block reload-elision (carry owner-map across non-jump-target labels): **−1,873 reloads (−1.03%), %r10 −1,302 (−2.49%)** |
| `598e123f2` | **#115 bomb** — route syscall arg setup through the parallel-move solver (fix pooled-arg aliasing → real `write(1,1,1)` miscompile) |

Earlier this session (the RA "model-bug" batch that delivered the bulk of the −15.4%): `a5d2f5be5`
(emergency-scavenge restore-before-branch + bounds-checks-not-clobber), `81f13f28d` (param-pin gate),
`a62f45c5d` (per-arg call marshalling, the biggest single: aggregate arg no longer spills scalars),
`b193f52f7` (precise intervals for large functions), `66d83bc56` (Pack not clobber), `fb6433336`
(constant shifts not %rcx clobber), `5beb72bbf` (**GEP-result register-eligible: −15k %r10 / −53k movq**),
`b97814cac` (SIMD full GP alloc), `492298ab3` (same-value coalescing). Plus the dormant/superseded
`bbc85426e`/`51a271e2a`/`9ddff428e` (RAGreedy C1 worklist + step1/2 homing — kept as substrate).

**Uncommitted in the working tree:** the M5 WIP (`src/compiler_regalloc.tl` +393/−114,
`src/compiler_backend.tl`, `splitkit_csr_across_call.tl` + manifest). Realization is **off by default**
(`--cfg splitkit-m5`/`splitkit-stress`), self-host declines → sound. Includes the **remat-threading
fix** (reorder loop-split→remat→SplitKit realization; kills M4's empty-operand miscompile) — worth
salvaging if §4 is pursued; otherwise revert with the rest.

---

## 3. Key findings / analysis docs to read first next session

All under `target/` (gitignored):
- **`reload-categorization.md`** — the definitive asm-grounded census: 70% call-dense spill (16% floor
  + P≤5 folding-dominated), 23% field/fat-ptr deref, LICM already realized (0.04% headroom left).
  **Verdict: no big sound buildable static lever remains.**
- **`splitkit-full-design.md`** — the 5-milestone architecture (per-sub-range model, selectOrSplit,
  occupant liberation, the #161 fix). M1–M4 built it; M5 proved it recovers 0.
- **`llvm-callee-saved-liberation.md`** — LLVM *forbids* caller-saved across a call by regmask
  interference (= our rule); the divergence is whole-interval-vs-split; LLVM *avoids* dirtying CSRs.
  Quality-vs-pressure resolved by P = max-live-among-call-spanning at a call (P≤5 quality, P>5 floor).
- **`whats-missing-vs-llvm.md`**, **`remeasure-post-147.md`**, **`greedy-proof-verdict.md`**,
  **`llvm-regalloc-strategy.md`**, **`splitkit-inventory.md`**, **`splitkit-plan-vs-code.md`**,
  **`llvm-gap-report.md`** — the full accumulated analysis chain.
- Saved WIP patches: `phaseB-callrun.patch`, `scavenge-fix-WIP.patch`, `llvm-phi-coalesce-ep-WIP.patch`,
  `ragreedy-*.patch`, `splitkit-step0.patch`, `greedy-ragreedy-plan.md`, `greedy-proof-verdict.md`.

**Traps confirmed dead (do not re-attempt):** caller-saved sub-range homing (peephole-redundant — Phase B
#154 + M4 both proved +regression); occupant-split for V-fits-hole (already realized by the greedy's
segment-aware interference, #159); LICM as a "top lever" (95.4% of reloads aren't in loops + memory-LICM
already exists at `compiler_optimize.tl:12176`); the `.data` fuse (#161: ~605 sites / −0.34% AND it
miscompiles — extends a base-derived value across a bounds-check-excluded abort).

---

## 4. How we work (operating methodology — keep doing this)

- **General-purpose agents BUILD; the coordinator drives.** Forks (context-inheriting) repeatedly
  balked at building (over-reading the safety mandate); fresh `general-purpose` agents just build.
  Give them the exact design + file:lines + the gate + "commit or report a precise obstacle."
- **Every change is gated by `target/gate-1b-safe.sh`** (memory-safe: `ulimit -v 24000000` + small-smoke
  first — the host OOM'd at 300GB from a miscompiled build). Green = **FIXPOINT3_OK** (s2==s3==s4
  byte-identical) + **scavcheck SELFCHECK_CLEAN** + **smoke-s1=42** + **verify-86** (loop_invariant_array_sum)
  + the forcing tests (`call_spanning_split(_single)`, `scavenge_destructure_clobber`, `loopcarry_coalesce`,
  `csr_occupant_split`, `callrun_subrange_home`, `splitkit_realize_*`).
- **The self-host FIXPOINT is the miscompile net.** Repeatedly caught real miscompiles that unit/forcing
  tests missed (phi-copy-branch elision, mis-coalesce of a live-out phi input, remat dropping minted vregs,
  the scavenge clobber). Trust it; a green fixpoint = sound.
- **Seed:** stage0-latest CANNOT bootstrap this branch. Agents self-build a clean seed via
  `build-stage0.sh` seeded from `target/raxpool/s2` (a working current-branch compiler).
- **WSL git bug:** after committing, verify the blob (`git show HEAD:<file> | grep <fn>`); if stale,
  `git reset --mixed HEAD~1` + `touch` + re-add + recommit. Agents do this.
- **Agents run gates in the background + Monitor-wait**, then commit. They often "park" between monitor
  checks (fires a spurious completion notification); nudge with SendMessage only if they stall without
  committing. For mechanical apply-WIP+gate+commit steps, the coordinator sometimes commits directly.
- **Measure RELIABLY, not with proxies.** The `#160` remeasure over-counted the ".data lever" 70× (a
  "reload deref'd within 3 insns" proxy); the real number was −0.34%. Always inspect actual asm sites.
- **Re-interrogate LLVM at every wall** (regmask, CSR cost, selectOrSplit) — every "impossible" turned
  out to be either already-realized or a missing mechanism we then located.
- **Big-rewrite milestones need not move the count** — commit a self-hosting byte-identical/neutral
  infra milestone; do NOT revert it. Only the final ON-switch milestone is held to a net drop.
- **Capture every finding + fork deferral as a task** immediately (we have the context now).

---

## 5. Remaining task list (pending)

### A. Pre-PR correctness bombs (audit #95 items — clear before shipping)
- **#99** — inline alloc/GC fast-path scratch `%r10/%r11/%r8` (needs a forcing test)
- **#100** — verify scavenge fallback `%r10/%r11` free-when-fires
- **#117** — loop-split candidate widening (rcx/rdx) needs a full clobber-scan
- **#123** — re-audit the caller-clobber model for other noreturn-cold-path mis-classifications
- **#24** — real clobber-model entries for tail-indirect-call + c-abi-return-stores `%r11`
- **#25** — Windows-only hardcoded `%r10` fast-alloc bump (11066)
- **#26** — SIMD index scratch `%r11` (1228) → freeness scavenge
- **#108** — c-abi struct-return FFI forcing test (validate the #65a folds)
- **#107** — stale fixture: `compiler-backend-binop-immediate-asm` 3-arg calls vs 5-arg def

### B. Cleanup / restructure (before PR)
- **#112** — delete confirmed-dead code + stale comments (allocator+backend); includes the dead
  `compiler-reg-function-phi-touched` (superseded by `-safe` in #147)
- **#113** — consolidate duplicate free-register/interference queries + parallel-move solvers
- **#114** — RS_Split stages: the inventory proved these were a blank; now trySplit (#93/M2) populates
  them — decide wire-through vs the SplitKit endgame
- **#116** — split allocator+backend into modules + ABI abstraction
- **#30** — dead-code + scratch cleanup from the scavenger work

### C. Register-count wins (Win64 + frame-pointer omission)
- **#54 [HIGH, user-flagged]** — Win64 callee save-set rewrite → reclaim rsi/rdi (14/14 on Win64)
- **#103/#104/#105** — FP-omission (#65b rsp-relative slots / #65c drop rbp + pool as 15th GP / #65d Win64 SEH)
- **#109** — c-abi scalar stack-arg dip → fully constant rsp (#65a-iii)
- **#65** — FP omission umbrella

### D. Mov-flood / arg-eligibility tail
- **#66** — arg-elig for tail/c-abi/indirect calls [blocked by #74, #75]
- **#67** — call-result/return %rax coalescing hints
- **#74/#75** — base-aware closure/indirect-call parallel-move (conflict detect + arg-moves)
- **#77/#78** — deferred stack-staging / peephole-reach parts
- **#98** — backend reload-CSE across the noreturn bounds-guard
- **#101** — binop reload-temps (use-reload engine branch)

### E. SplitKit follow-ups (gated on the §1 endgame decision)
- **#93** — the SplitKit rewrite umbrella (M1–M4 committed; M5 negative; §4 untried)
- **#157** — root scavenge-point fix (emission-order; recover #151's +85)
- **#150** — SplitKit #4 block-frequency split placement (moot if SplitKit reverted)
- **#155** — SplitKit Phase C phi-carried (superseded by the M-series; close)
- **#131** — merge-phi per-edge liveness (deferred: unsound standalone; needs paired phi-result reservation)
- **#121** — general interference-boundary splitting (the dispatch/branchy lever)

### F. Low tail / footguns / misc
- **#28/#29** — phi-temp register-when-free full swap / XMM float phi-temp
- **#32** — emergency-tier efficiency (~3696× in main.tl)
- **#68/#69/#70/#71/#72/#73** — scavenge-bit footguns / per-call-site clobber sets / 16-byte group
  assignment / isel-scratch-as-vregs / phi swap-cycle test
- **#33** — re-bootstrap published stage0 after the pooling codegen change
- **#84** — re-queue splitting-deferred tasks
- **#88** — track s3 binary size vs published stage0
- **#92/#94/#96** — Phase-4 constraints / retire scavenger / thread ABI into free-reg query
- **#97** — LICM (mostly realized; ≤0.04% headroom — likely close)

### G. After merge
- Float/XMM register pool (issue **#4043**).

---

## 6. Immediate next steps for the next session

1. **Resolve the §1 endgame decision** (revert SplitKit + ship — recommended — vs §4 vs keep-infra).
2. If shipping: clear bucket **A (bombs)** + relevant **B (cleanup)**, land the **C** register-count
   wins if desired (#54 is user-flagged HIGH), then **rebase onto `origin/main` → open PR → green CI**.
3. If reverting the SplitKit infra: `git revert`/reset the M1–M4 commits (they're byte-identical
   allocation, so reverting is clean) back to `8cd70e553` state (−15.4%); discard the M5 WIP.

**The banked win to protect:** −15.4% static reloads (212,384 → 179,714) + real correctness bomb
fixes (syscall aliasing, scavenge clobber, emergency-scavenger restore-before-branch), all
FIXPOINT-validated. That is the shippable result regardless of the SplitKit decision.
