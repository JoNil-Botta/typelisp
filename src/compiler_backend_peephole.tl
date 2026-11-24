;; compiler_backend_peephole.tl - Post-emission peephole passes over x86_64 text lines.
(import compiler_backend_operands as be_operand)
(import compiler_backend_program_facts as be_facts)
(import compiler_backend_state as be_state)
(import stdlib.iterator)
(import compiler_ir_types)
(import compiler_optimize)
(import compiler_abi)
(import compiler_regalloc)
(import stdlib.text_buf)
(import stdlib.text_buf_borrowed)
(import stdlib.vector)
(import compiler_intern as ci)
(import stdlib.arena)
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as backend_string_i64_map)

;; Block labels are interned ids, so their maps are integer-keyed.
(import (hashmap.hashmap i64 i64) as backend_label_i64_map)
(import stdlib.string)
(import compiler_str_cat as str_cat)
(import compiler_owned_view as owned_view)

;; True when `label`'s entry carries phi copies: the block starts with a Phi, so
;; `compiler-backend-leading-phi-copies-seq` builds a (possibly empty) copy list
;; for every incoming edge and the emitter renders it on the way in.
(define (compiler-backend-phi-target?
  [function-state : be_state.CompilerBackendFunctionState]
  [label : i64]) : bool
  (if (=
    (be_state.compiler-backend-function-state-i64
      function-state
      be_state.compiler-backend-function-i64-current-phi-target-count)
    0)
    false
    (let
      [targets : be_state.BackendSymbolSeq
        (be_state.compiler-backend-function-state-phi-targets function-state)]
      (be_state.compiler-backend-symbol-list-contains-id? (& targets) label))))

(define (compiler-backend-branch-needs-phi-copies?
  [function-state : be_state.CompilerBackendFunctionState]
  [true-label : i64]
  [false-label : i64]) : bool
  (or
    (compiler-backend-phi-target? function-state true-label)
    (compiler-backend-phi-target? function-state false-label)))

;; Increment the predecessor count for every label in `labels` (a deduped CFG
;; successor set for one block). Each block contributes at most once per
;; successor, so the resulting count is the number of DISTINCT predecessor
;; blocks -- exactly the "is this label a merge?" signal we need.
(define (compiler-backend-peephole-predcount-bump
  [counts : backend_label_i64_map.Map]
  [labels : compiler_optimize.OptLabelSet]) : backend_label_i64_map.Map
  (match labels
    [(Nil) counts]
    [(Dense _ _)
      (let
        [label : i64 (compiler_optimize.opt-label-ref labels 0)]
        [out : backend_label_i64_map.Map counts]
        (backend_label_i64_map.insert-ref!
          (&mut out)
          label
          (+ 1 (backend_label_i64_map.get-value-or (& out) label 0)))
        (compiler-backend-peephole-predcount-bump
          out
          (compiler_optimize.opt-label-tail labels)))]))

(define (compiler-backend-block-seq-label-or-empty
  [blocks : (& compiler_ir_types.CompilerIrBlockSeq)]
  [index : i64]) : i64
  (if (>= index (compiler_ir_types.compiler-ir-block-seq-count blocks))
    (compiler_ir_types.compiler-ir-label-none)
    (match (compiler_ir_types.compiler-ir-block-seq-borrow blocks index)
      [(Block label _) label])))

;; Count predecessors of every block from the AUTHORITATIVE CFG successor set
;; (explicit Jump / Branch / Switch targets PLUS the
;; implicit fall-through to the layout-next block), reusing the optimizer's own
;; successor enumeration so jump-table (switch) case + default targets are all
;; included. Under-counting an edge is the only way carry could go wrong, and
;; this enumeration is complete (those are the only label-bearing terminators).
(define (compiler-backend-peephole-predcount-build-seq
  [blocks : (& blocks compiler_ir_types.CompilerIrBlockSeq)]
  [index : i64]
  [counts : backend_label_i64_map.Map]) : backend_label_i64_map.Map
  (if (>= index (compiler_ir_types.compiler-ir-block-seq-count blocks))
    counts
    (compiler-backend-peephole-predcount-build-seq
      blocks
      (+ index 1)
      (compiler-backend-peephole-predcount-bump
        counts
        (compiler_optimize.opt-cfg-block-successors-with-next
          (compiler_ir_types.compiler-ir-block-seq-borrow blocks index)
          (compiler-backend-block-seq-label-or-empty (& blocks) (+ index 1)))))))

;; True iff `block`'s terminator is a conditional branch that NEEDS phi-copy edge
;; blocks. SOUNDNESS-CRITICAL: such a branch does NOT lower to a clean
;; fall-through into its layout-next arm -- compiler-backend-emit-branch-with-phi-
;; copies emits a SYNTHETIC edge-copy block (`<label>_branch_<suffix>`) on the
;; fall-through path and reaches the layout-next arm via an explicit jcc. So the
;; layout-next block is a JUMP target with foreign code (the other edge's copies)
;; textually preceding it -- its running owner map is NOT this block's exit map,
;; and carrying across it miscompiles (a wrong reload reuse). A branch that
;; needs NO phi copies lowers to `jcc <other-arm>` + clean fall-through
;; (emit-compare-branch-jumps), which IS safe. Jump terminators keep copies on
;; their single edge. Switches with phi targets also split through synthetic
;; edge blocks, so they must reset the carry state before any layout-next block.
(define (compiler-backend-peephole-prev-splits-edge?
  [function-state : be_state.CompilerBackendFunctionState]
  [block : compiler_ir_types.CompilerIrBlock]) : bool
  (match block
    [(Block _ instrs)
      (let
        [n : i64 instrs.len]
        (if (= n 0)
          false
          (match (owned_view.compiler-owned-element-view instrs.slots (- n 1))
            [(or (Branch _ true-label false-label)
                 (TotalEnumBranch _ true-label false-label))
              (compiler-backend-branch-needs-phi-copies?
                function-state
                true-label
                false-label)]
            [(or (Switch _ _ cases default-label)
                 (TotalEnumSwitch _ _ cases default-label _))
              (be_facts.compiler-backend-switch-target-phi?
                (be_state.compiler-backend-function-state-phi-targets
                  function-state)
                cases
                default-label)]
            [_ false])))]))

;; Walk blocks in LAYOUT order (prev = the textually-preceding block). A block B
;; is carry-safe -- the peephole may carry the owner map across B's label rather
;; than reset -- iff ALL hold:
;;   (1) B is not the function entry (the entry is reached by `call` with caller
;;       register state, never by fall-through; it is `prev` here, never `cur`,
;;       and is additionally guarded by entry-label);
;;   (2) B has exactly ONE predecessor in the CFG (predcount == 1) -- so it is
;;       not a merge / multi-pred branch/switch/jump-table target; and
;;   (3) that single predecessor is `prev`, the layout-adjacent block (prev's
;;       successor set contains B). (2)+(3) together prove B is reached ONLY by
;;       continuing from prev, so the peephole's running owner map at B's label
;;       equals prev's exit map. If B's lone predecessor were laid out elsewhere
;;       (e.g. a far switch case), (3) fails and we reset -- the sound default;
;;   (4) prev does NOT end in a phi-copy branch (compiler-backend-peephole-prev-
;;       splits-edge?), which would insert a synthetic edge-copy block between
;;       prev and B and reach B via an explicit jcc rather than fall-through --
;;       so B's running map would be the OTHER edge's, not prev's exit.
(define (compiler-backend-peephole-carry-safe-scan-seq
  [backend-state : be_state.CompilerBackendState]
  [stream : be_state.CompilerBackendStreamState]
  [function-state : be_state.CompilerBackendFunctionState]
  [label-scope : String]
  [entry-label : i64]
  [predcount : backend_label_i64_map.Map]
  [prev : compiler_ir_types.CompilerIrBlock]
  [blocks : compiler_ir_types.CompilerIrBlockSeq]
  [index : i64]) : unit
  (if (>= index (compiler_ir_types.compiler-ir-block-seq-count blocks))
    unit
    (let
      [block (compiler_ir_types.compiler-ir-block-seq-ref blocks index)]
      (match (be_state.compiler-backend-global-shared-view block)
        [(Block cur-label _)
          (if (and
            (not (= cur-label entry-label))
            (not
              (compiler-backend-peephole-prev-splits-edge?
                function-state
                (be_state.compiler-backend-global-shared-view prev)))
            (= 1 (backend_label_i64_map.get-value-or (& predcount) cur-label 0))
            (compiler_optimize.opt-label-contains
              (compiler_optimize.opt-cfg-block-successors-with-next
                (& prev)
                cur-label)
              cur-label))
            (be_state.compiler-backend-peephole-carry-safe-insert!
              backend-state
              stream
              (be_operand.compiler-backend-asm-label
                (be_state.compiler-backend-global-shared-view label-scope)
                cur-label))
            unit)
          (compiler-backend-peephole-carry-safe-scan-seq
            backend-state
            stream
            function-state
            label-scope
            entry-label
            predcount
            block
            blocks
            (+ index 1))]))))

;; Accumulate carry-safe block labels for one function's FINAL emitted blocks
;; into the global peephole carry-safe set. `label-scope` MUST be the same value
;; emit-blocks passes to compiler-backend-asm-label, so the keys match the
;; emitted label lines exactly. Computed from the post-transform emit-blocks so
;; the CFG it analyzes is the one actually emitted.
(define (compiler-backend-peephole-collect-carry-safe!
  [backend-state : be_state.CompilerBackendState]
  [stream : be_state.CompilerBackendStreamState]
  [function-state : be_state.CompilerBackendFunctionState]
  [label-scope : String]
  [blocks : compiler_ir_types.CompilerIrBlockList]) : unit
  (match blocks
    [(Array seq)
      (if (= (compiler_ir_types.compiler-ir-block-seq-count seq) 0)
        unit
        (let
          [entry (compiler_ir_types.compiler-ir-block-seq-ref seq 0)]
          (match (be_state.compiler-backend-global-shared-view entry)
            [(Block entry-label _)
              (compiler-backend-peephole-carry-safe-scan-seq
                backend-state
                stream
                function-state
                label-scope
                entry-label
                (compiler-backend-peephole-predcount-build-seq
                  (& seq)
                  0
                  (backend_label_i64_map.with-capacity 64))
                entry
                seq
                1)])))]))

;; ============================================================================
;; M-G3 stage 1: rsp-relative frame addressing (behavior-neutral rebase).
;;
;; Every frame slot is emitted rbp-relative (`-K(%rbp)`; prologue: pushq %rbp /
;; movq %rsp,%rbp / subq $frame,%rsp), so `-K(%rbp)` == `(frame-K)(%rsp)`
;; whenever %rsp still sits at its post-prologue value. The final frame constant
;; is only known AFTER the body is emitted (emergency-scavenge use grows the
;; callee-save area and appends extra slots), so the rebase runs as a
;; post-emission text pass over the function's post-prologue text -- this is the
;; single point where the per-function frame model (frame constant + rbp-or-rsp
;; choice) is applied; stage 2 (frame-pointer omission) changes only the
;; prologue/epilogue and the bias fed to this pass.
;;
;; The pass PROVES rsp-constancy line by line instead of assuming it:
;;   * `delta` tracks any in-body %rsp displacement (bytes pushed beyond the
;;     prologue sub), such as a runtime-abort tail's operand pushes or a
;;     conservative fallback emitter's window. (The SIMD staging sequences
;;     use a frame region instead, #7497.) All such windows are straight-line
;;     and balanced within one instruction emission; a label inside a
;;     nonzero-delta window, or a net-negative delta, fails the audit. C-ABI
;;     outgoing args and arg/phi cycle temps are pre-reserved frame uses and
;;     create no such dips.
;;   * `pushq MEM` computes its address BEFORE %rsp moves; `popq MEM` AFTER --
;;     the delta updates are ordered accordingly.
;;   * `leave` and any other %rsp write (`leaq slot,%rsp` pop-restore
;;     epilogues, the closure adapters' `movq %rbp,%rsp`) end rsp validity;
;;     validity resumes at the next label (labels are only reachable at
;;     delta 0). A frame reference while %rsp is unknown fails the audit.
;;   * POSITIVE rbp offsets (incoming stack args at 16+8k(%rbp) and tail-call
;;     final stack-arg stores into those same slots) are LEFT on rbp: %rbp is
;;     still materialized in stage 1, and those accesses stay valid regardless
;;     of %rsp motion. Stage 2 rebases them with its adjusted constant.
;;   * Indexed rbp forms (`(%rbp,...`), a bare `(%rbp)`, or a rewritten offset
;;     that would go negative fail the audit (none are emitted today).
;; On ANY audit failure the ORIGINAL text is returned unchanged -- that
;; function simply keeps rbp addressing (needs-rbp), preserving behavior.
;;
;; The post-emission peephole recognizes both slot spellings through its
;; parsed stack-slot range predicate. Within any owner-map
;; lifetime every %rsp-mutating line (pushq/popq/subq/addq/leave/movq-to-rsp/
;; leaq-to-rsp/ret) conservatively clears the map; a returned call restores
;; %rsp and keeps only callee-saved stack-slot owners. Equal operand strings
;; therefore imply equal addresses in both worlds and the elision behavior
;; carries over 1:1.
(defstruct CompilerBackendRspRebaseResult
  (text String)
  (ok bool)
  ;; RG-1: the callee-saved registers some instruction of the body NAMES --
  ;; every line the pass did not classify as a CSR save/restore or as one of
  ;; the epilogue's own CSR pops. Zero on a failed audit and on the non-push
  ;; path, where nothing consumes it.
  (csr-ref-mask i64))

;; Index of the first "(%rbp" occurrence in [start,end), or -1. Jumps between
;; '(' bytes a word at a time instead of stepping every byte.
(define (compiler-backend-rsp-rebase-find-rbp
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : i64
  (let
    [stop : i64 (- end 4)]
    [i : i64 start]
    [found : i64 -1]
    [done : bool false]
    (while (and (not done) (<= (+ i 5) end))
      (let
        [pos : i64
          (be_operand.compiler-backend-peephole-scan-byte-range data i stop 40)]
        (if (>= pos stop)
          (set! done true)
          (if (and
            (= (be_state.compiler-backend-peephole-byte-at data (+ pos 1)) 37)
            (= (be_state.compiler-backend-peephole-byte-at data (+ pos 2)) 114)
            (= (be_state.compiler-backend-peephole-byte-at data (+ pos 3)) 98)
            (= (be_state.compiler-backend-peephole-byte-at data (+ pos 4)) 112))
            (begin
              (set! found pos)
              (set! done true))
            (set! i (+ pos 1))))))
    found))

;; Start index of the signed decimal immediately preceding `pos`, or -1 when
;; there is none (a bare/indexed form the audit must reject).
(define (compiler-backend-rsp-rebase-int-start
  [data : (Ptr u8)]
  [line-start : i64]
  [pos : i64]) : i64
  (let
    [j : i64 pos]
    (while (and
      (> j line-start)
      (let
        [b : i64 (be_state.compiler-backend-peephole-byte-at data (- j 1))]
        (and (>= b 48) (<= b 57))))
      (-= j 1))
    (if (= j pos)
      -1
      (if (and
        (> j line-start)
        (= (be_state.compiler-backend-peephole-byte-at data (- j 1)) 45))
        (- j 1)
        j))))

;; Parse the (optionally '-'-signed) decimal in [start,end).
(define (compiler-backend-rsp-rebase-parse-int
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : i64
  (let
    [neg : bool (= (be_state.compiler-backend-peephole-byte-at data start) 45)]
    [v : i64 0]
    (for [j
      (iterator.range
        (if neg
          (+ start 1)
          start)
        end)]
      (set!
        v
        (+ (* v 10) (- (be_state.compiler-backend-peephole-byte-at data j) 48))))
    (if neg
      (- 0 v)
      v)))

;; ============================================================================
;; GAP1 / Win64 FPO: push-style CSR prologue saves.
;;
;; The mov-form CSR save/restore (`movq %rXX, -K(%rbp)` / `movq -K(%rbp), %rXX`
;; / the pop-run `leaq -K(%rbp), %rsp; popq ...`) is converted AT THE REBASE
;; SEAM into clang's push form: the caller's prologue becomes
;;     pushq %r12 [.. pushq %rbp]      (plan-saved CSRs, slot-idx order)
;;     subq $S, %rsp                   (S = frame + pad; pad keeps alignment)
;; and the pass (push mode = fpo AND push-count > 0):
;;   * DELETES the save/restore movq lines (their slots -- the callee-save
;;     reservation inside `frame` -- become dead pad; the frame constant is
;;     NOT shrunk because the reservation sits mid-frame between the var area
;;     and the group/outgoing/emergency regions, so the offset span is fixed),
;;   * rewrites the pop-run entry `leaq CSRSLOT(%rbp), %rsp` to
;;     `addq $(S+delta), %rsp` (rsp -> the pushed area; the existing popq run
;;     then restores the same registers in the same order: the pop-run pops
;;     lowest-address-slot first = highest slot idx = exactly reverse push
;;     order) and the trailing `leave` folds to NOTHING (rsp is already at
;;     the return address; the fold amount D+delta must be exactly 0),
;;   * rewrites a bare `leave` (mov-restore epilogues, whose restore movs were
;;     deleted) to `addq $(S+delta), %rsp` + the full popq run.
;; Frame model: total displacement D = 8*n + S with S = frame + (n odd ? 0 : 8)
;; so D % 16 == 8 exactly like the no-push subq $(frame+8) -- call alignment
;; holds.
;; The pushes occupy [entry_rsp-8n, entry_rsp-8), so local slots shift down 8n:
;;   negative K:  -K(%rbp) -> (S + delta - K)(%rsp)      (bias_neg = S)
;;   positive X:  +X(%rbp) -> (S + 8n - 8 + delta + X)(%rsp)  (bias_pos; the
;;     incoming-arg area is caller memory at fixed absolute addresses)
;; (n = 0 keeps the stage-2 single-bias formulas byte-identical.)
;; Soundness of the line classification: the ONLY emitters that reference the
;; callee-save slots (offset -(8*(slot-vars+idx+1)), idx in the plan-saved set)
;; are emit-save-callee-reg / emit-restore-callee-reg / the pop-run leaq --
;; group word1 slots start at frame-slots+1 (above every reserved CSR slot) and
;; emergency slots sit below frame-slots-emergency-max, so a saved-CSR-slot
;; offset is unambiguous. Any OTHER line shape referencing one fails the audit
;; (keep-rbp fallback on the ORIGINAL text stays correct: mov saves intact).
;; Win64 uses the same conversion, with every prologue push described by
;; `.seh_pushreg` and no `.seh_setframe`. Both Internal save maps use slots
;; 0..4 = r12..r15,rbx and 5 = rbp. "" = not saved.
(define (compiler-backend-rsp-rebase-make-push-regs) : (__tl_dyn-array String)
  (let
    [regs : (__tl_dyn-array String) (__tl_make-array String 8)]
    [idx : i64 0]
    (while (< idx (array-length regs))
      (set! (array-ref regs idx) "")
      (+= idx 1))
    regs))

;; Shared no-push array for the stage-1 / adapter / fallback call sites.
(define compiler-backend-rsp-rebase-no-push : (__tl_dyn-array String)
  (compiler-backend-rsp-rebase-make-push-regs))

;; ============================================================================
;; T1-6 (a): System V red-zone leaf frames.
;;
;; The SysV AMD64 ABI reserves the 128 bytes below %rsp -- the RED ZONE -- to
;; the running function: the kernel skips them when it builds a signal frame,
;; and nothing else (interrupt, debugger stub) may write there either. A
;; function that makes no RETURNING call therefore needs no stack pointer
;; adjustment at all: it can leave %rsp at its entry value and address every
;; frame slot at a NEGATIVE displacement. This is X86FrameLowering's red-zone
;; rule (SysV, no frame pointer, stack size <= 128) and it deletes both the
;; prologue `subq $N, %rsp` and the epilogue `addq`.
;;
;; Three facts make it sound here, and every one of them is checked:
;;
;;  1. NO RETURNING CALL. `compiler-backend-function-bool-call-align-needed` is
;;     the FINAL-TEXT census of calls that come back to this function. The
;;     out-of-line `never` handlers (tl_oob_abort*, tl_div_abort*,
;;     tl_shift_abort*, tl_panic_at, tl_oom_abort, tl_region_abort) are excluded
;;     from it for the alignment argument and are excluded from the red zone for
;;     the same reason: control never returns, so whatever the handler does to
;;     the stack below %rsp -- including the return address its `call` pushes --
;;     cannot be observed here, and by the time the `call` is reached every
;;     reported value already sits in an argument register. A tail `jmp` is not
;;     a call: the epilogue has already restored the entry %rsp (with a red-zone
;;     frame it never moved), so the tail target opens a fresh frame below it
;;     and our slots are dead. A `syscall` fails the FPO audit outright.
;;
;;  2. NOTHING WRITES BELOW %rsp WHILE A SLOT IS LIVE. The body's own stack
;;     motion -- abort-site argument staging (`pushq LEN; pushq IDX; ...; popq;
;;     popq`), c-ABI dip windows (`subq $X,%rsp ... addq $X,%rsp`), phi
;;     cycle-break pushes -- dips BELOW %rsp, exactly where red-zone slots
;;     would sit. (SIMD staging is a frame region, so it is one of those
;;     slots, #7497.) Instead of refusing those functions the slot region is
;;     anchored `guard` bytes LOWER, `guard` being the deepest dip the body
;;     reaches (compiler-backend-text-max-rsp-dip runs the rebase audit's own
;;     delta walk over the final text). Every transient
;;     push then lands strictly ABOVE every slot -- and still READS the slots it
;;     stages from correctly, because the rebase re-biases each reference by the
;;     running delta. This is the "push above the red-zone slots" resolution of
;;     the abort-site edge: no extra instruction is emitted at any abort site.
;;
;;  3. EVERYTHING FITS: `guard + frame <= 128`.
;;
;; Alignment: with no adjustment %rsp keeps its entry value, so `%rsp % 16 == 8`
;; at an abort `call` where a framed function would have had 0. That is exactly
;; the situation the dropped alignment pad already produces for a bare frame,
;; and the argument is the one recorded on call-align-needed: the abort chain
;; links no libc, prints through raw syscalls and never spills through a
;; 16-byte-aligned SSE move, so it inherits no alignment duty.
;;
;; Excluded: Windows (the x64 ABI has NO red zone -- the kernel may write below
;; %rsp freely, so :71008 and every Win64 path keep their frame), any function
;; with outgoing stack-argument space (those are POSITIVE `N(%rsp)` offsets and
;; would land on the return address once the prologue stops moving %rsp), and
;; shrink-wrapped functions (their prologue is spliced at an interior label,
;; outside this pass's displacement model).
(define compiler-backend-red-zone-limit : i64
  128)

(define (compiler-backend-red-zone-guard
  [backend-state : be_state.CompilerBackendState]) : i64
  (be_state.compiler-backend-function-state-i64
    (be_state.compiler-backend-state-function-state backend-state)
    be_state.compiler-backend-function-i64-red-zone-guard))

;; Deepest point BELOW the post-prologue %rsp that `text` reaches through its
;; own tracked stack motion, in bytes, or -1 when the walk cannot bound it.
;; Mirrors the rsp-rebase audit line for line: a label restores tracking and
;; resets the running delta (dip windows are straight-line), `pushq` costs 8,
;; `popq` gives 8 back, `subq $imm, %rsp` / `addq $imm, %rsp` move it by imm,
;; and any OTHER write to %rsp (an epilogue `leaq slot, %rsp`, `movq %rbp,%rsp`)
;; or a `leave` ends tracking until the next label -- an epilogue shape, where
;; no slot is live any more and a write below %rsp can hurt nothing. A `pushq`
;; taken while untracked is not boundable and refuses the red zone outright, as
;; does a delta that would go negative outside an epilogue.
;;
;; ABT-1: a dip taken ONLY on a never-returning path is not a dip this guard has
;; to pay for. The located runtime-abort tails (`tl_oob_abort_at`,
;; `tl_div_abort_at`, `tl_shift_abort_at`) save their two operands with `pushq`
;; before loading the descriptor pointer, and those pushes land exactly where a
;; red-zone body's local slots live -- but the path they are on ends in a call
;; that never returns to this function's own code, so no later read of a local
;; slot can observe the clobber. The pushed words themselves are read back only
;; by the tail's own two `popq`s, and the operands the pushes READ are safe by
;; construction: the first push happens while %rsp is still the body's own, and
;; the second one's operand is never memory (the bounds tail's index is a
;; register or an imm32, the shift tail's width is an immediate, and the div
;; tail's saves are registers, normalized through %r11 when narrow). Charging
;; the guard for them costs a body whose frame sits near the 128-byte limit its
;; red zone -- a real prologue and epilogue on every call -- to arm a
;; diagnostic on a path that cannot come back.
;;
;; So a push (or an `%rsp`-lowering `subq`) does not commit its depth at once:
;; it enters a two-slot pending window, and the third one displaces the oldest
;; into `deepest`. The `# tl_abort_operand_stage` that only a located abort
;; tail emits HOLDS the window's entries -- its own two pushes, and never more,
;; since nothing else is enqueued between them and it -- and the noreturn abort
;; call that follows DISCARDS them, which is the continuation that proves the
;; path never returns. Anything else -- a label, another push, the end of the
;; text -- commits the held entries instead, so a shape that is not an abort
;; tail is still counted in full. Every other dip (a c-ABI window, a phi
;; cycle-break push, a real `subq`) reaches `deepest` exactly as before.
(define (compiler-backend-text-max-rsp-dip [text : (& text str)]) : i64
  (let
    [n : i64 (string.string-length text)]
    [data : (Ptr u8)
      (unsafe
        (string-data text))]
    [i : i64 0]
    [delta : i64 0]
    [valid : bool true]
    [deepest : i64 0]
    [ok : bool true]
    ;; The pending window and the entries an abort-site marker is holding.
    [pend-count : i64 0]
    [pend0 : i64 0]
    [pend1 : i64 0]
    [held-count : i64 0]
    [held0 : i64 0]
    [held1 : i64 0]
    (while (and ok (< i n))
      (let
        [end : i64
          (be_operand.compiler-backend-peephole-scan-byte-range data i n 10)]
        [m : i64 i]
        (while (and
          (< m end)
          (= (be_state.compiler-backend-peephole-byte-at data m) 32))
          (+= m 1))
        (if (>= m end)
          unit
          (if (= (be_state.compiler-backend-peephole-byte-at data (- end 1)) 58)
            (begin
              ;; A label ends the straight-line window: nothing after it can
              ;; be the continuation an abort tail's pushes were held for.
              (if (>= held-count 1)
                (if (> held0 deepest)
                  (set! deepest held0)
                  unit)
                unit)
              (if (>= held-count 2)
                (if (> held1 deepest)
                  (set! deepest held1)
                  unit)
                unit)
              (set! held-count 0)
              (if (>= pend-count 1)
                (if (> pend0 deepest)
                  (set! deepest pend0)
                  unit)
                unit)
              (if (>= pend-count 2)
                (if (> pend1 deepest)
                  (set! deepest pend1)
                  unit)
                unit)
              (set! pend-count 0)
              (set! delta 0)
              (set! valid true))
            (let
              [tok : i64
                (-
                  (be_operand.compiler-backend-peephole-scan-byte-range
                    data
                    m
                    end
                    32)
                  m)]
              [te : i64 (+ m tok)]
              [kind : i64
                (be_operand.compiler-backend-control-mnemonic-kind data m tok)]
              [rsp-dst? : bool
                (and
                  (>= (- end i) 6)
                  (=
                    (be_state.compiler-backend-peephole-byte-at data (- end 1))
                    112)
                  (=
                    (be_state.compiler-backend-peephole-byte-at data (- end 6))
                    44)
                  (=
                    (be_state.compiler-backend-peephole-byte-at data (- end 5))
                    32)
                  (=
                    (be_state.compiler-backend-peephole-byte-at data (- end 4))
                    37)
                  (=
                    (be_state.compiler-backend-peephole-byte-at data (- end 3))
                    114)
                  (=
                    (be_state.compiler-backend-peephole-byte-at data (- end 2))
                    115))]
              (cond
                ;; The located abort tail's staging marker: hold the two
                ;; pushes in front of it until the continuation says whether
                ;; the path returns. Only reachable while something is
                ;; pending, so an ordinary line pays one integer compare.
                [(and
                  (> pend-count 0)
                  (<= (+ m 24) end)
                  (be_operand.compiler-backend-peephole-range-eq?
                    data
                    m
                    (+ m 24)
                    "# tl_abort_operand_stage"))
                  (if (>= held-count 1)
                    (if (> held0 deepest)
                      (set! deepest held0)
                      unit)
                    unit)
                  (if (>= held-count 2)
                    (if (> held1 deepest)
                      (set! deepest held1)
                      unit)
                    unit)
                  (set! held-count 0)
                  (set! held0 pend0)
                  (set! held1 pend1)
                  (set! held-count pend-count)
                  (set! pend-count 0)]
                ;; ...and the noreturn abort call is that continuation: the
                ;; held dip is on a path that never comes back, so no local
                ;; slot it reached can be read again.
                [(and
                    (> held-count 0)
                    (compiler-backend-peephole-line-noreturn-abort? data m end))
                  (set! held-count 0)]
                [(= kind be_operand.compiler-backend-control-mnemonic-push)
                  (if valid
                    (begin
                      (+= delta 8)
                      (if (>= held-count 1)
                        (if (> held0 deepest)
                          (set! deepest held0)
                          unit)
                        unit)
                      (if (>= held-count 2)
                        (if (> held1 deepest)
                          (set! deepest held1)
                          unit)
                        unit)
                      (set! held-count 0)
                      (if (>= pend-count 2)
                        (begin
                          (if (> pend0 deepest)
                            (set! deepest pend0)
                            unit)
                          (set! pend0 pend1)
                          (set! pend1 delta))
                        (if (= pend-count 1)
                          (begin
                            (set! pend1 delta)
                            (set! pend-count 2))
                          (begin
                            (set! pend0 delta)
                            (set! pend-count 1)))))
                    (set! ok false))]
                [(= kind be_operand.compiler-backend-control-mnemonic-pop)
                  (when
                    valid
                    (-= delta 8)
                    (if (< delta 0)
                      (set! ok false)
                      unit))]
                [(= kind be_operand.compiler-backend-control-mnemonic-leave)
                  (set! valid false)]
                [rsp-dst?
                  (if (and
                    valid
                    (= kind be_operand.compiler-backend-control-mnemonic-subq)
                    (< (+ te 1) end)
                    (=
                      (be_state.compiler-backend-peephole-byte-at data (+ te 1))
                      36))
                    (begin
                      (+=
                        delta
                        (compiler-backend-rsp-rebase-parse-int
                          data
                          (+ te 2)
                          (- end 6)))
                      (if (>= held-count 1)
                        (if (> held0 deepest)
                          (set! deepest held0)
                          unit)
                        unit)
                      (if (>= held-count 2)
                        (if (> held1 deepest)
                          (set! deepest held1)
                          unit)
                        unit)
                      (set! held-count 0)
                      (if (>= pend-count 2)
                        (begin
                          (if (> pend0 deepest)
                            (set! deepest pend0)
                            unit)
                          (set! pend0 pend1)
                          (set! pend1 delta))
                        (if (= pend-count 1)
                          (begin
                            (set! pend1 delta)
                            (set! pend-count 2))
                          (begin
                            (set! pend0 delta)
                            (set! pend-count 1)))))
                    (if (and
                      valid
                      (= kind be_operand.compiler-backend-control-mnemonic-addq)
                      (< (+ te 1) end)
                      (=
                        (be_state.compiler-backend-peephole-byte-at
                          data
                          (+ te 1))
                        36))
                      (begin
                        (-=
                          delta
                          (compiler-backend-rsp-rebase-parse-int
                            data
                            (+ te 2)
                            (- end 6)))
                        (if (< delta 0)
                          (set! ok false)
                          unit))
                      (set! valid false)))]
                [else unit]))))
        (set!
          i
          (if (< end n)
            (+ end 1)
            end))))
    ;; The text ran out before any continuation: count everything still owed.
    (if (>= held-count 1)
      (if (> held0 deepest)
        (set! deepest held0)
        unit)
      unit)
    (if (>= held-count 2)
      (if (> held1 deepest)
        (set! deepest held1)
        unit)
      unit)
    (set! held-count 0)
    (if (>= pend-count 1)
      (if (> pend0 deepest)
        (set! deepest pend0)
        unit)
      unit)
    (if (>= pend-count 2)
      (if (> pend1 deepest)
        (set! deepest pend1)
        unit)
      unit)
    (set! pend-count 0)
    (if ok
      deepest
      -1)))

;; Return the required red-zone guard, or -1 when a real frame is needed.
(define (compiler-backend-red-zone-guard-for
  [backend-state : be_state.CompilerBackendState]
  [text : (& text str)]
  [fpo-attempt : bool]
  [frame : i64]
  [outgoing : i64]
  [shrinkwrap-active? : bool]) : i64
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [eligible : bool
      (and
        fpo-attempt
        (be_state.compiler-backend-state-emission-target-policy backend-state).red-zone
        (not (be_state.compiler-backend-current-fn-win64? backend-state))
        (not shrinkwrap-active?)
        (> frame 0)
        (<= frame compiler-backend-red-zone-limit)
        (= outgoing 0)
        (not
          (be_state.compiler-backend-function-state-bool?
            function-state
            be_state.compiler-backend-function-bool-call-align-needed)))]
    [dip : i64
      (if eligible
        (compiler-backend-text-max-rsp-dip text)
        -1)]
    [guard : i64
      (if (< dip 0)
        -1
        (be_operand.compiler-backend-round-up-16 dip))]
    (if (and
      eligible
      (>= guard 0)
      (<= (+ guard frame) compiler-backend-red-zone-limit))
      guard
      -1)))

;; Always writes both facts, so an abandoned attempt cannot leave stale frame
;; state for the prologue, rebase or dead-frame-store sweep.
(define (compiler-backend-red-zone-decide!
  [backend-state : be_state.CompilerBackendState]
  [text : (& text str)]
  [fpo-attempt : bool]
  [frame : i64]
  [outgoing : i64]
  [shrinkwrap-active? : bool]) : unit
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [guard : i64
      (if (> frame 0)
        (compiler-backend-red-zone-guard-for
          backend-state
          text
          fpo-attempt
          frame
          outgoing
          shrinkwrap-active?)
        -1)]
    [accept : bool (and (> frame 0) (>= guard 0))]
    (be_state.compiler-backend-function-state-set-bool!
      function-state
      be_state.compiler-backend-function-bool-red-zone
      accept)
    (be_state.compiler-backend-function-state-set-i64!
      function-state
      be_state.compiler-backend-function-i64-red-zone-guard
      (if accept
        guard
        0))))

;; The two biases the rsp-rebase pass rewrites frame references with, shared
;; with the dead-frame-store sweep so both describe the SAME layout.
;;
;; `bias-pos` is the distance from the final %rsp up to the VIRTUAL %rbp the
;; positive (incoming stack argument, tail-call stack-arg store) offsets were
;; spelled against: `8n + S - 8`, the whole prologue displacement minus the
;; omitted `pushq %rbp`. `bias-neg` is the distance up to the LOCAL slot
;; region's anchor, which is not the same word: under pushes the locals sit
;; directly below the pushed CSRs (anchor `S`), without pushes they sit below
;; the omitted saved-rbp word (anchor `frame` = `S - 8`), and under the red zone
;; (`S = 0`) they are pushed a further `guard` bytes BELOW %rsp so a transient
;; push cannot land on a live slot.
;;
;; Both take the pass's own `fpo` flag: the stage-1 keep-rbp fallback re-runs
;; the SAME text with fpo=false after a failed audit, and there the prologue is
;; the ordinary `pushq %rbp; movq %rsp,%rbp; subq $frame` -- no pushes, no red
;; zone, bias `frame` in both directions.
(define (compiler-backend-frame-bias-neg
  [backend-state : be_state.CompilerBackendState]
  [fpo : bool]
  [frame : i64]
  [push-count : i64]) : i64
  (if (and fpo (be_operand.compiler-backend-red-zone? backend-state))
    (- 0 (compiler-backend-red-zone-guard backend-state))
    (if (and fpo (> push-count 0))
      (be_operand.compiler-backend-rsp-rebase-push-sub
        backend-state
        frame
        push-count)
      frame)))

(define (compiler-backend-frame-bias-pos
  [backend-state : be_state.CompilerBackendState]
  [fpo : bool]
  [frame : i64]
  [push-count : i64]) : i64
  ;; Under FPO there is no `pushq %rbp`, so total prologue %rsp motion is
  ;; `push-sub + 8*push-count` across all shapes (pushed CSRs, red zone,
  ;; zero-frame bare/no-call leaves where push-sub == 0 -> bias -8, and
  ;; ordinary no-push frames where push-sub == frame + 8 -> bias frame).
  (if fpo
    (-
      (+
        (be_operand.compiler-backend-rsp-rebase-push-sub
          backend-state
          frame
          push-count)
        (* push-count 8))
      8)
    frame))

;; The prologue subq constant S under n pushes: frame + pad where pad keeps
;; the total displacement (8n + S) % 16 == 8 (frame is a 16-multiple), i.e.
;; the same call alignment as the no-push `subq $(frame+8)`.
;;
;; The pad is bought for ONE purpose: a call in this body must see
;; %rsp % 16 == 0. A function that makes no RETURNING call
;; (compiler-backend-function-bool-call-align-needed, set from the final text
;; just before the rebase) has nothing to align for, so the pad is dead weight
;; and the whole stack adjustment disappears with it.
;;
;; Dropping it is gated on `frame == 0`, and that guard is load-bearing, not
;; conservatism: every frame reference is rebased off `%rsp` with a bias derived
;; from this same S. With frame > 0 the negative (local slot) bias is `S - 8n`
;; in push mode and `S - 8` without pushes, so shortening S by 8 would move
;; every slot. With frame == 0 there is no negative reference left to move --
;; the slot region is dead (or, in push mode, holds only callee-save slots the
;; rebase deletes) -- and the positive (incoming stack argument) bias
;; `S + 8n - 8` is computed from S and therefore follows it exactly.
;; ---------------------------------------------------------------------------
;; RG-1 fix B: a callee-saved register the BODY never names.
;;
;; The prologue saves exactly the callee-saved registers the allocator plan
;; homes a value in (compiler-backend-callee-needs-save?). That set is a
;; property of the PLAN, and emission can leave it behind: a value can lose its
;; last materialized reference between the plan and the text -- its defining
;; copy becomes a self-move inside a coalesce class and the peephole drops it,
;; its use folds into a memory operand, a rewrite remaps the region that
;; mentioned it. The register is then pushed in the prologue and popped in the
;; epilogue with nothing in between: two instructions per CALL of the function,
;; paid on the hot path for nothing.
;;
;; The question "does an instruction of this function name %r13" can only be
;; answered on the final text, and the rsp-rebase pass is where that text is
;; walked line by line WITH the save/restore lines already classified
;; (compiler-backend-rsp-rebase-csr-classify). So the mask is collected there,
;; and the trim is applied by re-running that same pass with a smaller push
;; set: the classification set stays the full one, so every save/restore movq
;; is still deleted, and the pushes and pops the pass synthesizes come from the
;; trimmed set. The frame adjustment follows automatically --
;; compiler-backend-rsp-rebase-push-sub derives the `subq` from the push count
;; and its parity, so a function that loses a push gains the 8-byte pad that
;; keeps `%rsp % 16 == 8` at every call, and the Windows `.seh_pushreg`
;; program is generated from the same trimmed array as the pushes.
;;
;; A trimmed run that fails the audit falls back to the untrimmed text, so the
;; trim can never cost a function its FPO frame.
;; The callee-saved register named at `pos` (which must be the '%' of a
;; register spelling), or `compiler_abi.compiler-reg-id-invalid`.
;;
;; `%rbp` immediately after '(' is a FRAME BASE, not a value reference: at this
;; seam every local is still spelled `-K(%rbp)` and the pass rewrites it to
;; %rsp, so counting it would report %rbp used by every framed function. The
;; converse -- a value homed in %rbp and dereferenced as `(%rbp)` -- cannot
;; occur, because this pass rewrites every `(%rbp)` as a frame reference and a
;; body that contained one would already be mis-rebased.
;;
;; EVERY width counts. A register named only through a narrow spelling --
;; `%ebx` for an i32 compare, `%bpl` for a bool store, `%r12d` for a widened
;; load -- is used exactly as much as one named through `%rbx`, and reading
;; only the 64-bit spellings makes the body look empty and trims a save the
;; function needs, clobbering the caller's register.
(define (compiler-backend-csr-spelling-reg
  [data : (Ptr u8)]
  [pos : i64]
  [prev : i64]
  [end : i64]) : i64
  (if (> (+ pos 2) end)
    compiler_abi.compiler-reg-id-invalid
    (let
      [b1 : i64 (be_state.compiler-backend-peephole-byte-at data (+ pos 1))]
      [b2 : i64 (be_state.compiler-backend-peephole-byte-at data (+ pos 2))]
      [b3 : i64
        (if (> (+ pos 3) end)
          0
          (be_state.compiler-backend-peephole-byte-at data (+ pos 3)))]
      (cond
        ;; 64-bit spellings. %rbp is the one that has to be told apart from a
        ;; frame base, which is always written `K(%rbp)`.
        [(and (= b1 114) (= b2 98) (= b3 120)) compiler_abi.compiler-reg-id-rbx]
        [(and (= b1 114) (= b2 98) (= b3 112))
          (if (= prev 40)
            compiler_abi.compiler-reg-id-invalid
            compiler_abi.compiler-reg-id-rbp)]
        ;; %r12 .. %r15 and their d/w/b suffixes share this prefix.
        [(and (= b1 114) (= b2 49) (= b3 50)) compiler_abi.compiler-reg-id-r12]
        [(and (= b1 114) (= b2 49) (= b3 51)) compiler_abi.compiler-reg-id-r13]
        [(and (= b1 114) (= b2 49) (= b3 52)) compiler_abi.compiler-reg-id-r14]
        [(and (= b1 114) (= b2 49) (= b3 53)) compiler_abi.compiler-reg-id-r15]
        [(and (= b1 114) (= b2 115) (= b3 105))
          compiler_abi.compiler-reg-id-rsi]
        [(and (= b1 114) (= b2 100) (= b3 105))
          compiler_abi.compiler-reg-id-rdi]
        ;; 32-bit spellings: %ebx, %ebp, %esi, %edi.
        [(and (= b1 101) (= b2 98) (= b3 120)) compiler_abi.compiler-reg-id-rbx]
        [(and (= b1 101) (= b2 98) (= b3 112)) compiler_abi.compiler-reg-id-rbp]
        [(and (= b1 101) (= b2 115) (= b3 105))
          compiler_abi.compiler-reg-id-rsi]
        [(and (= b1 101) (= b2 100) (= b3 105))
          compiler_abi.compiler-reg-id-rdi]
        ;; 16- and 8-bit spellings: %bx/%bl/%bh, %bp/%bpl, %si/%sil, %di/%dil.
        ;; Two bytes are enough to name the register: the third, when there is
        ;; one, only narrows the width.
        [(and (= b1 98) (or (= b2 120) (= b2 108) (= b2 104)))
          compiler_abi.compiler-reg-id-rbx]
        [(and (= b1 98) (= b2 112)) compiler_abi.compiler-reg-id-rbp]
        [(and (= b1 115) (= b2 105)) compiler_abi.compiler-reg-id-rsi]
        [(and (= b1 100) (= b2 105)) compiler_abi.compiler-reg-id-rdi]
        [else compiler_abi.compiler-reg-id-invalid]))))

(define (compiler-backend-csr-line-mask
  [data : (Ptr u8)]
  [from : i64]
  [to : i64]
  [mask : i64]) : i64
  (let
    [out : i64 mask]
    (for [i (iterator.range from to)]
      (if (= (be_state.compiler-backend-peephole-byte-at data i) 37)
        (let
          [reg : i64
            (compiler-backend-csr-spelling-reg
              data
              i
              (if (> i from)
                (be_state.compiler-backend-peephole-byte-at data (- i 1))
                0)
              to)]
          (if (= reg compiler_abi.compiler-reg-id-invalid)
            unit
            (set!
              out
              (bit-or out (be_operand.compiler-backend-plan-reg-id-bit reg)))))
        unit))
    out))

;; A copy of `push-regs` with every entry the body never names cleared. The
;; entries are register SPELLINGS in callee-save slot order, so the copy keeps
;; the slot indexing the pop run and the SEH program read.
(define (compiler-backend-csr-trimmed-push-regs
  [push-regs : (__tl_dyn-array String)]
  [ref-mask : i64]
  [backend-state : be_state.CompilerBackendState]) : (__tl_dyn-array String)
  (let
    [out : (__tl_dyn-array String) (compiler-backend-rsp-rebase-make-push-regs)]
    [idx : i64 0]
    (while (< idx (array-length out))
      (let
        [name : String
          (be_state.compiler-backend-global-array-element-shared-view
            push-regs
            idx)]
        [reg-id : i64
          (be_operand.compiler-backend-trace-csr-name-at backend-state idx)]
        (set!
          (array-ref out idx)
          (if (string.eq name "")
            ""
            (if (=
              (bit-and
                ref-mask
                (be_operand.compiler-backend-plan-reg-id-bit reg-id))
              0)
              ""
              (string.copy (& name))))))
      (+= idx 1))
    out))

(define (compiler-backend-csr-drop-mask
  [push-regs : (__tl_dyn-array String)]
  [save-regs : (__tl_dyn-array String)]
  [backend-state : be_state.CompilerBackendState]) : i64
  (let
    [out : i64 0]
    (for [idx (iterator.range 0 (array-length save-regs))]
      (if (and
        (not (string.eq (array-ref save-regs idx) ""))
        (or
          (>= idx (array-length push-regs))
          (string.eq (array-ref push-regs idx) "")))
        (set!
          out
          (bit-or
            out
            (be_operand.compiler-backend-plan-reg-id-bit
              (be_operand.compiler-backend-trace-csr-name-at backend-state idx))))
        unit))
    out))

(define (compiler-backend-csr-push-reg-mask
  [push-regs : (__tl_dyn-array String)]
  [backend-state : be_state.CompilerBackendState]) : i64
  (let
    [out : i64 0]
    (for [idx (iterator.range 0 (array-length push-regs))]
      (if (string.eq (array-ref push-regs idx) "")
        unit
        (set!
          out
          (bit-or
            out
            (be_operand.compiler-backend-plan-reg-id-bit
              (be_operand.compiler-backend-trace-csr-name-at backend-state idx))))))
    out))

;; The popq run restoring the pushed CSRs: highest slot idx first (lowest
;; address = last pushed), matching the existing pop-run epilogue order.
;; Lines joined by newlines with NO trailing newline (append-line adds it).
(define (compiler-backend-rsp-rebase-pop-run
  [push-regs : (__tl_dyn-array String)]) : String
  (let
    [idx : i64 (- (array-length push-regs) 1)]
    [acc : String ""]
    (while (>= idx 0)
      (if (string.eq
        (be_state.compiler-backend-global-array-element-shared-view
          push-regs
          idx)
        "")
        unit
        (set!
          acc
          (str_cat.str-cat
            acc
            (if (string.eq acc "")
              ""
              "\n")
            "    popq "
            (be_state.compiler-backend-global-array-element-shared-view
              push-regs
              idx)
            "")))
      (-= idx 1))
    acc))

;; Classify a line whose first frame ref hits a SAVED callee-save slot
;; (push mode only). Returns:
;;   0 = not a saved-CSR-slot line (normal handling)
;;   1 = CSR save/restore movq (delete)
;;   2 = pop-run entry `leaq CSRSLOT(%rbp), %rsp`
;;   3 = malformed saved-CSR-slot reference (fail the audit)
(define (compiler-backend-rsp-rebase-csr-classify
  [data : (Ptr u8)]
  [line-start : i64]
  [m : i64]
  [te : i64]
  [end : i64]
  [mnemonic-kind : i64]
  [push-regs : (__tl_dyn-array String)]
  [slot-vars : i64]) : i64
  (let
    [p : i64 (compiler-backend-rsp-rebase-find-rbp data m end)]
    (if (or
      (< p 0)
      (>= (+ p 5) end)
      (not (= (be_state.compiler-backend-peephole-byte-at data (+ p 5)) 41)))
      0
      (let
        [ks : i64 (compiler-backend-rsp-rebase-int-start data line-start p)]
        (if (< ks 0)
          0
          (let
            [k : i64 (compiler-backend-rsp-rebase-parse-int data ks p)]
            (if (>= k 0)
              0
              (let
                [unit-idx : i64 (/ (- 0 k) 8)]
                (if (not (= (* unit-idx 8) (- 0 k)))
                  0
                  (let
                    [idx : i64 (- unit-idx (+ slot-vars 1))]
                    (if (or (< idx 0) (>= idx (array-length push-regs)))
                      0
                      (let
                        [reg : String
                          (be_state.compiler-backend-global-array-element-shared-view
                            push-regs
                            idx)]
                        (if (string.eq reg "")
                          0
                          (cond
                            [(=
                                mnemonic-kind
                                be_operand.compiler-backend-control-mnemonic-movq)
                              ;; restore: movq -K(%rbp), %rXX
                              (if (and
                                (= ks (+ te 1))
                                (= (+ p 12) end)
                                (=
                                  (be_state.compiler-backend-peephole-byte-at
                                    data
                                    (+ p 6))
                                  44)
                                (=
                                  (be_state.compiler-backend-peephole-byte-at
                                    data
                                    (+ p 7))
                                  32)
                                (be_operand.compiler-backend-peephole-range-eq?
                                  data
                                  (+ p 8)
                                  (+ p 12)
                                  reg))
                                1
                                ;; save: movq %rXX, -K(%rbp)
                                (if (and
                                  (= (+ p 6) end)
                                  (be_operand.compiler-backend-peephole-range-eq?
                                    data
                                    (+ te 1)
                                    (+ te 5)
                                    reg)
                                  (=
                                    (be_state.compiler-backend-peephole-byte-at
                                      data
                                      (+ te 5))
                                    44)
                                  (=
                                    (be_state.compiler-backend-peephole-byte-at
                                      data
                                      (+ te 6))
                                    32)
                                  (= ks (+ te 7)))
                                  1
                                  3))]
                            [(=
                                mnemonic-kind
                                be_operand.compiler-backend-control-mnemonic-leaq)
                              ;; pop-run entry: leaq -K(%rbp), %rsp
                              (if (and
                                (= ks (+ te 1))
                                (= (+ p 12) end)
                                (=
                                  (be_state.compiler-backend-peephole-byte-at
                                    data
                                    (+ p 6))
                                  44)
                                (=
                                  (be_state.compiler-backend-peephole-byte-at
                                    data
                                    (+ p 7))
                                  32)
                                (be_operand.compiler-backend-peephole-range-eq?
                                  data
                                  (+ p 8)
                                  (+ p 12)
                                  "%rsp"))
                                2
                                3)]
                            [else 3]))))))))))))))

;; Rewrite one function's POST-PROLOGUE text to rsp-relative frame addressing
;; (`X(%rbp)` -> `(frame+delta+X)(%rsp)`); returns the ORIGINAL text when the
;; rsp-constancy audit fails (the function keeps rbp addressing).
;;
;; With `fpo = true` the function is emitted frame-pointer-free. A no-CSR
;; prologue uses `subq $(frame+8), %rsp`; a CSR plan uses push saves plus an
;; aligned sub-allocation. Win64 describes those operations with SEH unwind
;; codes. Differences from the stage-1 (behavior-neutral) mode:
;;   * POSITIVE rbp offsets (incoming stack args 16+8k(%rbp), tail-call final
;;     stack-arg stores) are rebased with the SAME formula -- the virtual rbp
;;     sits at rsp+frame post-prologue in both worlds.
;;   * `leave` becomes `addq $(frame+8+delta), %rsp` (there is no rbp frame to
;;     reset from). Requires a tracked rsp (valid); delta is normally 0.
;;   * the pop-restore epilogue `leaq slot,%rsp; popq CSR...` is TRACKED instead
;;     of ending validity: the leaq operand was just rebased on the same line
;;     (exactly one frame ref), so the new rsp is known (delta goes negative --
;;     the "epilogue tail"); the pops keep decrementing delta and the final
;;     `leave` rewrite folds the remainder. Negative delta stays a hard audit
;;     failure outside this recognized shape.
;;   * any OTHER rsp write (`movq %rbp,%rsp`, untracked leaq) FAILS the audit
;;     (stage 1 merely ended validity) -- without a frame pointer there is no
;;     way to re-establish rsp.
;; On audit failure the caller either re-runs in stage-1 mode (plan has no %rbp
;; home -> keep-rbp, byte-identical) or DEMOTES (re-plans the function without
;; %rbp in the pool and re-emits).
;;
;; #rbp-base invariant: in fpo mode every "(%rbp" occurrence is a frame
;; reference. Emitters structurally distinguish %rbp pool VALUES with a
;; spaced spelling `( %rbp)` where possible and otherwise stage through
;; a scratch (see address-base-filter); bare `%rbp` register operands also
;; contain no "(%rbp".
;; GAP1: 3-arg spelling for the stage-1 / adapter / fallback call sites (no
;; push mode).
(define (compiler-backend-rsp-rebase
  [text : String]
  [frame : i64]
  [fpo : bool]
  [backend-state : be_state.CompilerBackendState]) : String
  (compiler-backend-rsp-rebase-full
    text
    frame
    fpo
    (be_state.compiler-backend-string-array-shared-view
      (& compiler-backend-rsp-rebase-no-push))
    0
    0
    backend-state))

(define (compiler-backend-rsp-rebase-full-result
  [text : String]
  [frame : i64]
  [fpo : bool]
  [push-regs : (__tl_dyn-array String)]
  [push-count : i64]
  [slot-vars : i64]
  [backend-state : be_state.CompilerBackendState]) : CompilerBackendRspRebaseResult
  (compiler-backend-rsp-rebase-full-result-with-saves
    text
    frame
    fpo
    (be_state.compiler-backend-global-shared-view push-regs)
    push-count
    push-regs
    push-count
    slot-vars
    backend-state))

;; Copy the kept source bytes [start, end) of the rebase input to `out`.
(define (compiler-backend-rsp-rebase-copy-run!
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : unit
  (when
    (> end start)
    (let
      [off : i64 out.len]
      [count : i64 (- end start)]
      (be_state.compiler-backend-asm-buf-reserve! out (+ off count))
      (unsafe
        (string.str-copy-bytes-into (ptr-offset data start) out.data off count))
      (set! out.len (+ off count)))))

;; Start of the line after the one ending at `end` in a text of `n` bytes.
(define (compiler-backend-rsp-rebase-next-line [end : i64] [n : i64]) : i64
  (if (< end n)
    (+ end 1)
    end))

;; `NOFF(%rsp)`, the rewritten spelling of one frame reference. Almost every
;; displacement is a small non-negative number, so that case reserves once and
;; writes its digits and the base in place; any other value takes the general
;; decimal writer. Both spell `NOFF` exactly as `string.int->string` does.
(define (compiler-backend-rsp-rebase-rsp-ref!
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [noff : i64]) : unit
  (if (or (< noff 0) (>= noff 10000))
    (begin
      (be_state.compiler-backend-asm-append-decimal! out noff)
      (be_state.compiler-backend-asm-append out "(%rsp)"))
    (let
      [digits : i64
        (cond [(< noff 10) 1] [(< noff 100) 2] [(< noff 1000) 3] [else 4])]
      [off : i64 out.len]
      [base : i64 (+ off digits)]
      (be_state.compiler-backend-asm-buf-reserve! out (+ base 6))
      (let
        [dst : (MutPtr u8) out.data]
        [rest : i64 noff]
        [pos : i64 (- base 1)]
        (while (>= pos off)
          (unsafe
            (ptr-write! (ptr-offset dst pos) (cast (+ 48 (% rest 10)) : u8)))
          (set! rest (/ rest 10))
          (-= pos 1))
        (unsafe
          (ptr-write! (ptr-offset dst base) (cast 40 : u8))
          (ptr-write! (ptr-offset dst (+ base 1)) (cast 37 : u8))
          (ptr-write! (ptr-offset dst (+ base 2)) (cast 114 : u8))
          (ptr-write! (ptr-offset dst (+ base 3)) (cast 115 : u8))
          (ptr-write! (ptr-offset dst (+ base 4)) (cast 112 : u8))
          (ptr-write! (ptr-offset dst (+ base 5)) (cast 41 : u8))))
      (set! out.len (+ base 6)))))

;; `    addq $AMOUNT, %rsp`, newline-terminated when `newline`.
(define (compiler-backend-rsp-rebase-addq-line!
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [amount : i64]
  [newline : bool]) : unit
  (be_state.compiler-backend-asm-append out "    addq $")
  (be_state.compiler-backend-asm-append-decimal! out amount)
  (be_state.compiler-backend-asm-append
    out
    (if newline
      ", %rsp\n"
      ", %rsp")))

;; RG-1 fix B. `save-regs` is the set the PROLOGUE ORIGINALLY SAVED and is what
;; classifies (and so deletes) the save/restore movq lines and the pop-run
;; entry; `push-regs` is the set the pass EMITS pushes and pops for. They are
;; the same array on the ordinary call above. When fix B trims one, a register
;; in `save-regs` but not in `push-regs` has its save/restore deleted like any
;; other and its epilogue `popq` dropped with it, so the pass emits neither
;; half of a pair the body had no use for.
(define (compiler-backend-rsp-rebase-full-result-with-saves
  [text : String]
  [frame : i64]
  [fpo : bool]
  [push-regs : (__tl_dyn-array String)]
  [push-count : i64]
  [save-regs : (__tl_dyn-array String)]
  [save-count : i64]
  [slot-vars : i64]
  [backend-state : be_state.CompilerBackendState]) : CompilerBackendRspRebaseResult
  (let
    [n : i64 (string.string-length text)]
    [data : (Ptr u8)
      (unsafe
        (string-data text))]
    ;; The rebased text goes straight into a byte buffer. A kept line is not
    ;; copied on its own: `run` is the start of the kept source bytes not yet
    ;; copied, which always reach up to the current line, and they are copied
    ;; in one piece when a line is dropped or replaced or has a frame reference
    ;; rewritten.
    [out : be_state.CompilerBackendAsmBuf
      (be_state.compiler-backend-asm-buf-with-capacity (+ n (+ (/ n 8) 64)))]
    [run : i64 0]
    [i : i64 0]
    [delta : i64 0]
    [valid : bool true]
    [ok : bool true]
    [tail : bool false]
    [last-noff : i64 -1]
    [ref-count : i64 0]
    ;; RG-1: the callee-saved registers the body NAMES, and the ones fix B
    ;; trimmed away (present in the save set, absent from the push set) whose
    ;; epilogue pops must be dropped with their pushes.
    [csr-mask : i64 0]
    ;; The scan below only has to find the registers the PUSH set carries: once
    ;; every one of them is named, no line can change the answer, so the rest of
    ;; the function costs one bit test per line instead of a byte scan. Most
    ;; functions name their callee-saved homes within a few instructions of the
    ;; prologue.
    [push-mask : i64
      (compiler-backend-csr-push-reg-mask
        (be_state.compiler-backend-global-shared-view push-regs)
        backend-state)]
    [drop-mask : i64
      (compiler-backend-csr-drop-mask
        (be_state.compiler-backend-global-shared-view push-regs)
        (be_state.compiler-backend-global-shared-view save-regs)
        backend-state)]
    ;; GAP1 push mode: prologue = pushes + subq $sub-s; disp = the total
    ;; prologue rsp displacement (plays frame+8's role in the leave fold).
    ;; Keyed on the SAVE count: a function whose every push fix B trimmed still
    ;; has save/restore movq lines in its text, and push mode is what deletes
    ;; them. `push-count` (0 there) still drives the pushes, the pops and the
    ;; frame adjustment.
    [pm : bool (and fpo (> save-count 0))]
    ;; Win64 unwind codes describe one fixed post-prologue %rsp. Unlike SysV
    ;; FPO, a Win64 FPO body cannot contain a transient stack dip: any ordinary
    ;; push/pop/sub/add/mov-to-rsp fails the audit. The recognized terminal
    ;; add/pop epilogue is still legal and is synthesized by this pass.
    [seh-fpo : bool
      (and fpo (be_state.compiler-backend-current-fn-win64? backend-state))]
    [sub-s : i64
      (be_operand.compiler-backend-rsp-rebase-push-sub
        backend-state
        frame
        push-count)]
    [disp : i64 (+ (* push-count 8) sub-s)]
    ;; Red zone: sub-s is 0 and the local anchor sits `guard` bytes BELOW the
    ;; final %rsp, so local references come out NEGATIVE. Both biases come from
    ;; the shared helpers the sweep also reads.
    [rz : bool (and fpo (be_operand.compiler-backend-red-zone? backend-state))]
    [bias-neg : i64
      (compiler-backend-frame-bias-neg backend-state fpo frame push-count)]
    [bias-pos : i64
      (compiler-backend-frame-bias-pos backend-state fpo frame push-count)]
    (while (and ok (< i n))
      (let
        ;; The line ends at its newline, or at the text end.
        [end : i64
          (be_operand.compiler-backend-peephole-scan-byte-range data i n 10)]
        [nl : bool (< end n)]
        [m : i64 i]
        (while (and
          (< m end)
          (= (be_state.compiler-backend-peephole-byte-at data m) 32))
          (+= m 1))
        (if (>= m end)
          ;; blank line: kept
          unit
          (if (= (be_state.compiler-backend-peephole-byte-at data (- end 1)) 58)
            ;; a label: only reachable at delta 0 (dip windows are
            ;; straight-line); it also re-establishes rsp validity after an
            ;; epilogue's terminal rsp motion.
            (begin
              (if (and valid (not (= delta 0)))
                (set! ok false)
                unit)
              (set! delta 0)
              (set! valid true)
              (set! tail false))
            (let
              [tok : i64
                (-
                  (be_operand.compiler-backend-peephole-scan-byte-range
                    data
                    m
                    end
                    32)
                  m)]
              [te : i64 (+ m tok)]
              [mnemonic-kind : i64
                (be_operand.compiler-backend-control-mnemonic-kind data m tok)]
              [push? : bool
                (=
                  mnemonic-kind
                  be_operand.compiler-backend-control-mnemonic-push)]
              [pop? : bool
                (=
                  mnemonic-kind
                  be_operand.compiler-backend-control-mnemonic-pop)]
              [leave? : bool
                (=
                  mnemonic-kind
                  be_operand.compiler-backend-control-mnemonic-leave)]
              ;; A raw `syscall` can REPLACE %rsp in a way this textual
              ;; audit cannot track -- `clone` (syscall 56, the raw-thread
              ;; spawn) hands the CHILD a fresh stack, and rt_sigreturn loads
              ;; a saved rsp. After such a syscall rsp is no longer provably
              ;; rbp-frame, so every post-syscall frame ref rebased to
              ;; N(%rsp) would read the wrong stack in the child. Most
              ;; syscalls (write / read / futex / exit) leave rsp untouched,
              ;; but the number is not reliably knowable at this text seam,
              ;; so ANY syscall makes the WHOLE function keep rbp (frame refs
              ;; via %rbp survive clone in both parent and child -- CLONE_VM
              ;; shares the address space and rbp is never in clone's
              ;; register set).
              [syscall? : bool
                (=
                  mnemonic-kind
                  be_operand.compiler-backend-control-mnemonic-syscall)]
              [rsp-dst? : bool
                (and
                  (>= (- end i) 6)
                  (=
                    (be_state.compiler-backend-peephole-byte-at data (- end 1))
                    112)
                  (=
                    (be_state.compiler-backend-peephole-byte-at data (- end 6))
                    44)
                  (=
                    (be_state.compiler-backend-peephole-byte-at data (- end 5))
                    32)
                  (=
                    (be_state.compiler-backend-peephole-byte-at data (- end 4))
                    37)
                  (=
                    (be_state.compiler-backend-peephole-byte-at data (- end 3))
                    114)
                  (=
                    (be_state.compiler-backend-peephole-byte-at data (- end 2))
                    115))]
              ;; GAP1 push mode: classify saved-CSR-slot lines FIRST --
              ;; the save/restore movs are deleted (the prologue pushes /
              ;; epilogue pops replace them) and the pop-run leaq is
              ;; redirected at the pushed area. Only when rsp is tracked
              ;; (an untracked CSR ref falls through and fails like any
              ;; other frame ref).
              [csr-kind : i64
                (if (and pm valid)
                  (compiler-backend-rsp-rebase-csr-classify
                    data
                    i
                    m
                    te
                    end
                    mnemonic-kind
                    (be_state.compiler-backend-global-shared-view save-regs)
                    slot-vars)
                  0)]
              ;; A `popq %rXX` of a trimmed register inside the epilogue
              ;; tail: the pop run in the text was built for the untrimmed
              ;; save set, and the pass has already replaced its `leaq`
              ;; anchor with an `addq` sized by the TRIMMED push count, so
              ;; this pop has to go with the push it restores. Dropping it
              ;; leaves `disp + delta` at exactly 0 after the remaining
              ;; pops, which is what the `leave` fold below checks.
              [drop-pop? : bool
                (and
                  pm
                  pop?
                  tail
                  (not (= drop-mask 0))
                  (not
                    (=
                      (bit-and
                        drop-mask
                        (be_operand.compiler-backend-plan-reg-id-bit
                          (compiler-backend-csr-spelling-reg
                            data
                            (+ te 1)
                            0
                            end)))
                      0)))]
              (set! last-noff -1)
              (set! ref-count 0)
              ;; Unprovable rsp shape -> keep rbp for the whole
              ;; function (audit fail). ok=false terminates the pass loop;
              ;; the caller falls back to rbp addressing (or demotes an
              ;; rbp-planned function). Placed before the per-line frame /
              ;; rsp logic: a syscall line carries no frame ref, so the
              ;; remaining arms are inert on it.
              (if syscall?
                (set! ok false)
                unit)
              (if (and
                seh-fpo
                (or
                  push?
                  (and pop? (not tail))
                  (and rsp-dst? (not (= csr-kind 2)))))
                (set! ok false)
                unit)
              ;; RG-1: every line that is not a CSR save/restore, not
              ;; the pop-run anchor and not one of the epilogue's own CSR
              ;; pops is a real instruction of the body: what it names,
              ;; the function uses.
              (if (and
                pm
                (= csr-kind 0)
                (not (and pop? tail))
                (not (= (bit-and csr-mask push-mask) push-mask)))
                (set!
                  csr-mask
                  (compiler-backend-csr-line-mask data i end csr-mask))
                unit)
              ;; lint-allow: nested-if-ladder
              (if (or (= csr-kind 1) drop-pop?)
                ;; CSR save/restore movq, or a trimmed register's pop:
                ;; drop the line.
                (begin
                  (compiler-backend-rsp-rebase-copy-run! (&mut out) data run i)
                  (set! run (compiler-backend-rsp-rebase-next-line end n)))
                (if (= csr-kind 2)
                  ;; pop-run entry: point rsp at the pushed area
                  ;; (entry_rsp - 8n = rsp_f + sub-s); the following
                  ;; pops restore the pushed CSRs in reverse push
                  ;; order and the final leave folds to 0.
                  (if tail
                    (set! ok false)
                    (begin
                      (compiler-backend-rsp-rebase-copy-run!
                        (&mut out)
                        data
                        run
                        i)
                      (set! run (compiler-backend-rsp-rebase-next-line end n))
                      ;; `addq $0` would point rsp where it already is:
                      ;; with a dead slot region the pushed area starts at
                      ;; the current rsp, so the pop run needs no rebase
                      ;; line at all. (The rewrite already replaces a
                      ;; flag-free `leaq` with a flag-setting `addq`, so
                      ;; dropping the line cannot lose a live flag.)
                      (if (= (+ sub-s delta) 0)
                        unit
                        (compiler-backend-rsp-rebase-addq-line!
                          (&mut out)
                          (+ sub-s delta)
                          nl))
                      (set! tail true)
                      (set! delta (- 0 sub-s))))
                  (if (= csr-kind 3)
                    ;; unrecognized saved-CSR-slot reference: the slot
                    ;; is unwritten under push saves -- keep rbp.
                    (set! ok false)
                    (begin
                      ;; popq MEM computes its address AFTER the rsp increment.
                      (when
                        (and valid pop?)
                        (-= delta 8)
                        ;; negative delta is legal only inside the FPO epilogue
                        ;; tail (the pops after a rebased `leaq slot,%rsp`).
                        (if (and (< delta 0) (not (and fpo tail)))
                          (set! ok false)
                          unit))
                      (if (and fpo leave?)
                        ;; FPO: no rbp frame to `leave` from -- unwind rsp
                        ;; directly (prologue reserved frame+8, push mode
                        ;; 8n+sub-s; a negative delta folds the pop-restore
                        ;; epilogue tail when present).
                        (begin
                          (compiler-backend-rsp-rebase-copy-run!
                            (&mut out)
                            data
                            run
                            i)
                          (set!
                            run
                            (compiler-backend-rsp-rebase-next-line end n))
                          ;; lint-allow: nested-if-ladder
                          (if (not valid)
                            (set! ok false)
                            (if (and pm tail)
                              ;; GAP1 push mode after a pop run: every pushed
                              ;; CSR was popped, rsp already sits at the return
                              ;; address -- the fold must be EXACTLY 0 and the
                              ;; leave vanishes.
                              (if (= (+ disp delta) 0)
                                unit
                                (set! ok false))
                              (if pm
                                ;; GAP1 push mode, mov-restore epilogue (the
                                ;; restore movs were deleted): deallocate the
                                ;; subq area and pop the pushed CSRs.
                                (let
                                  [amount : i64 (+ sub-s delta)]
                                  (if (< amount 0)
                                    (set! ok false)
                                    (begin
                                      (unless
                                        (= amount 0)
                                        (compiler-backend-rsp-rebase-addq-line!
                                          (&mut out)
                                          amount
                                          true))
                                      (be_state.compiler-backend-asm-append
                                        (&mut out)
                                        (compiler-backend-rsp-rebase-pop-run
                                          (be_state.compiler-backend-global-shared-view
                                            push-regs)))
                                      (when
                                        nl
                                        (be_state.compiler-backend-asm-append
                                          (&mut out)
                                          "\n")))))
                                (let
                                  ;; `sub-s` IS the emitted no-push
                                  ;; prologue adjustment -- `frame + 8`
                                  ;; ordinarily, 0 for a bare frame and 0
                                  ;; again when the pad was dropped for
                                  ;; want of a returning call -- so the
                                  ;; epilogue folds it back verbatim.
                                  [amount : i64 (+ sub-s delta)]
                                  (if (< amount 0)
                                    (set! ok false)
                                    (if (= amount 0)
                                      unit
                                      (compiler-backend-rsp-rebase-addq-line!
                                        (&mut out)
                                        amount
                                        nl)))))))
                          (set! valid false)
                          (set! tail false))
                        (begin
                          ;; frame-reference rewrite
                          (let
                            [rbp-stop : i64 (- end 4)]
                            [first-paren : i64
                              (if (<= (+ m 5) end)
                                (be_operand.compiler-backend-peephole-scan-byte-range
                                  data
                                  m
                                  rbp-stop
                                  40)
                                rbp-stop)]
                            [p : i64
                              (if (>= first-paren rbp-stop)
                                -1
                                (if (and
                                  (=
                                    (be_state.compiler-backend-peephole-byte-at
                                      data
                                      (+ first-paren 1))
                                    37)
                                  (=
                                    (be_state.compiler-backend-peephole-byte-at
                                      data
                                      (+ first-paren 2))
                                    114)
                                  (=
                                    (be_state.compiler-backend-peephole-byte-at
                                      data
                                      (+ first-paren 3))
                                    98)
                                  (=
                                    (be_state.compiler-backend-peephole-byte-at
                                      data
                                      (+ first-paren 4))
                                    112))
                                  first-paren
                                  (compiler-backend-rsp-rebase-find-rbp
                                    data
                                    (+ first-paren 1)
                                    end)))]
                            (if (< p 0)
                              unit
                              (if (not valid)
                                (set! ok false)
                                (while (and ok (>= p 0))
                                  (if (or
                                    (>= (+ p 5) end)
                                    (not
                                      (=
                                        (be_state.compiler-backend-peephole-byte-at
                                          data
                                          (+ p 5))
                                        41)))
                                    ;; "(%rbp," indexed or truncated.
                                    ;; BE-4: in an rbp-planned
                                    ;; function an INDEXED form is a
                                    ;; pool base with a SIB index --
                                    ;; the emitter never spells a
                                    ;; frame slot with an index (a
                                    ;; stack array is addressed
                                    ;; through a leaq of its slot) --
                                    ;; so the audit steps over it and
                                    ;; leaves the text as it is.
                                    ;; Anywhere else it refuses as
                                    ;; before.
                                    (if (and
                                      compiler_regalloc.compiler-reg-rbp-pool-enabled
                                      (< (+ p 5) end)
                                      (=
                                        (be_state.compiler-backend-peephole-byte-at
                                          data
                                          (+ p 5))
                                        44))
                                      unit
                                      (set! ok false))
                                    (let
                                      [ks : i64
                                        (compiler-backend-rsp-rebase-int-start
                                          data
                                          i
                                          p)]
                                      (if (< ks 0)
                                        ;; bare "(%rbp)"
                                        (set! ok false)
                                        (let
                                          [k : i64
                                            (compiler-backend-rsp-rebase-parse-int
                                              data
                                              ks
                                              p)]
                                          (if (and (>= k 0) (not fpo))
                                            ;; incoming stack-arg slot: keep
                                            ;; rbp (stage 1 -- %rbp is live).
                                            ;; In FPO mode positive offsets
                                            ;; rebase with the SAME formula
                                            ;; (virtual rbp = rsp+frame).
                                            unit
                                            (let
                                              ;; GAP1 push mode: negative
                                              ;; (local) offsets shift down by
                                              ;; the pushed bytes (bias sub-s);
                                              ;; positive (incoming-arg)
                                              ;; offsets keep their absolute
                                              ;; caller-side addresses (bias
                                              ;; sub-s+8n-8). Both equal
                                              ;; `frame` when push-count = 0.
                                              [noff : i64
                                                (+
                                                  (+
                                                    (if (>= k 0)
                                                      bias-pos
                                                      bias-neg)
                                                    delta)
                                                  k)]
                                              ;; A negative
                                              ;; displacement is a
                                              ;; RED-ZONE slot and
                                              ;; is legal only
                                              ;; there, and only
                                              ;; inside the 128
                                              ;; bytes the ABI
                                              ;; reserves.
                                              (if (or
                                                (and (< noff 0) (not rz))
                                                (<
                                                  noff
                                                  (-
                                                    0
                                                    compiler-backend-red-zone-limit)))
                                                (set! ok false)
                                                (begin
                                                  (compiler-backend-rsp-rebase-copy-run!
                                                    (&mut out)
                                                    data
                                                    run
                                                    ks)
                                                  (compiler-backend-rsp-rebase-rsp-ref!
                                                    (&mut out)
                                                    noff)
                                                  (set! last-noff noff)
                                                  (+= ref-count 1)
                                                  (set! run (+ p 6))))))))))
                                  (set!
                                    p
                                    (if ok
                                      (let
                                        [next-start : i64 (+ p 6)]
                                        [next-paren : i64
                                          (if (<= (+ next-start 5) end)
                                            (be_operand.compiler-backend-peephole-scan-byte-range
                                              data
                                              next-start
                                              rbp-stop
                                              40)
                                            rbp-stop)]
                                        (if (>= next-paren rbp-stop)
                                          -1
                                          (if (and
                                            (=
                                              (be_state.compiler-backend-peephole-byte-at
                                                data
                                                (+ next-paren 1))
                                              37)
                                            (=
                                              (be_state.compiler-backend-peephole-byte-at
                                                data
                                                (+ next-paren 2))
                                              114)
                                            (=
                                              (be_state.compiler-backend-peephole-byte-at
                                                data
                                                (+ next-paren 3))
                                              98)
                                            (=
                                              (be_state.compiler-backend-peephole-byte-at
                                                data
                                                (+ next-paren 4))
                                              112))
                                            next-paren
                                            (compiler-backend-rsp-rebase-find-rbp
                                              data
                                              (+ next-paren 1)
                                              end))))
                                      -1))))))
                          ;; pushq MEM computes its address BEFORE the rsp decrement.
                          (if (and valid push?)
                            (+= delta 8)
                            unit)
                          ;; explicit %rsp writes
                          (if (and rsp-dst? (not pop?))
                            ;; lint-allow: nested-if-ladder
                            (if (and
                              valid
                              (=
                                mnemonic-kind
                                be_operand.compiler-backend-control-mnemonic-subq)
                              (< (+ te 1) end)
                              (=
                                (be_state.compiler-backend-peephole-byte-at
                                  data
                                  (+ te 1))
                                36))
                              (+=
                                delta
                                (compiler-backend-rsp-rebase-parse-int
                                  data
                                  (+ te 2)
                                  (- end 6)))
                              (if (and
                                valid
                                (=
                                  mnemonic-kind
                                  be_operand.compiler-backend-control-mnemonic-addq)
                                (< (+ te 1) end)
                                (=
                                  (be_state.compiler-backend-peephole-byte-at
                                    data
                                    (+ te 1))
                                  36))
                                (begin
                                  (-=
                                    delta
                                    (compiler-backend-rsp-rebase-parse-int
                                      data
                                      (+ te 2)
                                      (- end 6)))
                                  (if (< delta 0)
                                    (set! ok false)
                                    unit))
                                (if fpo
                                  ;; FPO: only the pop-restore epilogue's
                                  ;; `leaq slot,%rsp` is provable -- the slot operand
                                  ;; was rebased on THIS line (exactly one frame
                                  ;; ref), so the new rsp is P + last-noff, i.e.
                                  ;; delta -= last-noff (the epilogue tail). Any
                                  ;; other rsp write is unrecoverable without a
                                  ;; frame pointer.
                                  (if (and
                                    valid
                                    (not tail)
                                    (= ref-count 1)
                                    (=
                                      mnemonic-kind
                                      be_operand.compiler-backend-control-mnemonic-leaq))
                                    (begin
                                      (set! tail true)
                                      (-= delta last-noff))
                                    (set! ok false))
                                  ;; unknown rsp write (leaq slot,%rsp epilogue,
                                  ;; movq %rbp,%rsp, ...): rsp no longer tracked.
                                  (set! valid false))))
                            unit)
                          (if leave?
                            (set! valid false)
                            unit))))))))))
        (set!
          i
          (if (< end n)
            (+ end 1)
            end))))
    (if ok
      (begin
        (cfg
          test
          (begin
            (be_state.compiler-backend-metric-set!
              backend-state
              be_state.compiler-backend-rsp-rebase-last-ok-metric
              1)
            (be_state.compiler-backend-metric-add!
              backend-state
              be_state.compiler-backend-rsp-rebase-ok-metric
              1))
          unit)
        (CompilerBackendRspRebaseResult
          (begin
            (compiler-backend-rsp-rebase-copy-run! (&mut out) data run n)
            (be_state.compiler-backend-asm-buf-finish (& out)))
          true
          csr-mask))
      (begin
        (cfg
          test
          (begin
            (be_state.compiler-backend-metric-set!
              backend-state
              be_state.compiler-backend-rsp-rebase-last-ok-metric
              0)
            (be_state.compiler-backend-metric-add!
              backend-state
              be_state.compiler-backend-rsp-rebase-keep-metric
              1))
          unit)
        (CompilerBackendRspRebaseResult text false 0)))))

(define (compiler-backend-rsp-rebase-full
  [text : String]
  [frame : i64]
  [fpo : bool]
  [push-regs : (__tl_dyn-array String)]
  [push-count : i64]
  [slot-vars : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [result : CompilerBackendRspRebaseResult
      (compiler-backend-rsp-rebase-full-result
        text
        frame
        fpo
        push-regs
        push-count
        slot-vars
        backend-state)]
    result.text))

;; ============================================================================
;; GAP5: post-emission dead frame-store sweep.
;;
;; M-B elided IR-dead call-result stores, but a store whose every READ was
;; register-forwarded by the owner-map peephole (or that was asm-dead all
;; along, e.g. a syscall-result store whose return reload collapsed to an
;; elided self-move) is invisible at IR level. This pass runs on the FINAL
;; program text (after the peephole fixpoint) and deletes
;; `movq %rX|$imm, N(%rsp)` stores to LOCAL VAR-REGION frame slots that are
;; never read anywhere in the function body. It participates for Linux FPO
;; functions and for Win64 rbp-framed functions whose negative frame slots were
;; successfully rebased to rsp-relative text.
;;
;; Soundness ledger (conservative-by-class; when in doubt the store stays):
;;  * Only functions that passed an rsp-rebase audit participate.
;;    emit-function records (symbol, lo, hi, disp) into POINTER-FREE global
;;    tables (an `(__tl_dyn-array String)` global dangles by peephole time -- the
;;    carry-safe lesson) where [lo, hi] is the VAR-REGION slot-start span in
;;    canonical (delta-0, rsp-relative) bytes: lo = bias_neg - 8*slot-vars,
;;    hi = bias_neg - 8 with bias_neg = sub-s (push mode) / frame -- exactly
;;    the rebase pass's negative-offset bias. The CSR save area, group word1
;;    region and emergency slots all sit at LARGER frame depths (canonical
;;    < lo); outgoing stack args (`(shadow+8k)(%rsp)`), c-abi dip windows and
;;    phi cycle-break push slots sit below the locals (canonical
;;    < outgoing+extra <= lo); rebased POSITIVE offsets (incoming stack args,
;;    tail-call stack-arg stores = caller memory) sit at canonical > hi. A
;;    candidate must land on an 8-aligned slot inside [lo, hi], so every
;;    protected class is excluded by construction.
;;  * The per-line rsp delta is re-tracked exactly like the audit that
;;    already validated this function: the region starts at delta = -disp so
;;    the prologue's pushes + subq land the body at 0; labels reset to 0;
;;    subq/addq $imm, %rsp and push/pop are tracked -- so refs inside c-abi
;;    dip windows canonicalize correctly.
;;  * Reads: EVERY frame ref that is not itself a candidate store marks
;;    [C, C+w) read, w = 16/32/64 when the line mentions %xmm/%ymm/%zmm (64
;;    for unmatched v*/k* vector mnemonics), else 8 -- a 16-byte movups
;;    covering two slots protects both. Presence-of-a-read ANYWHERE keeps all
;;    stores to the slot: no text-level flow analysis, so loops, shared
;;    epilogues and jump-table arms are covered by the whole-function scan.
;;  * Win64 keeps the rbp frame for SEH unwind (`pushq %rbp; movq %rsp,%rbp;
;;    subq $frame,%rsp`, `.seh_*` directives, `leave`). The unwind metadata
;;    describes prologue actions only; it does not expose local var slots to
;;    the runtime. For Win64 records the scanner therefore admits the rbp-set
;;    prologue line, terminal CSR pop-run `leaq K(%rsp),%rsp` where K is below
;;    the var span, and `leave`. Any non-terminal untracked rsp mutation still
;;    disables the function.
;;  * Address-taken slots: a `leaq L(%rsp)` resolves, per leaq, to the
;;    recorded frame object whose span contains L (`AddrOf`'s storage words,
;;    `sweep-addr-rbp`/`sweep-addr-ext`), and poisons exactly that object's
;;    span -- so a field/element leaq inside an object is covered by the WHOLE
;;    object while unrelated slots above it stay sweepable. A leaq with no
;;    recorded span at its offset keeps the old rule and poisons every slot at
;;    canonical >= L: an emitter this recording does not know (rebase-folded
;;    leaqs, adapters, epilogue forms) is conservative by construction.
;;    An object pointer only ever indexes upward within its extent (gep field
;;    and element offsets are non-negative and in-bounds). Indexed rsp
;;    addressing "(%rsp,", popq with a frame operand (post-increment
;;    addressing), bare %rsp outside a tracked subq/addq dst or the proven
;;    Win64 prologue/epilogue shapes, and any other untracked rsp write each
;;    disable the WHOLE function.
;;  * Only whole `movq SRC, N(%rsp)` lines are removed, SRC a single %reg
;;    (not %rsp) or $imm token: a pure 8-byte store to a private, never-read,
;;    never-address-taken local slot has no observable effect (the runtime
;;    has no GC stack walk -- the M-B argument).
;; Driven from compiler-backend-peephole-asm (all text-emission paths); with
;; an empty metadata table (hand-written text or raw peephole callers) the
;; pass returns its input unchanged.
(define compiler-backend-sweep-initial-capacity : i64
  128)
(define compiler-backend-sweep-initial-bytes-capacity : i64
  4096)
(define compiler-backend-sweep-bytes-capacity : i64
  8388608)

;; Sentinel for "this line is not a candidate store".
(define compiler-backend-sweep-no-candidate : i64
  -4611686018427387904)

;; Per-line sweep classes stored on the record (`sweep-kind`).
;;  * Skip: blank lines, `.`-directives and `#` comments -- invisible to the
;;    scan, exactly like the byte walk's `unit` arms.
;;  * Label: resets the running rsp delta to 0 (or ends a Win64 tail).
;;  * Instruction: everything else; `sweep-flags` and the offset fields below
;;    describe it.
(define compiler-backend-sweep-line-kind-skip : i64
  0)
(define compiler-backend-sweep-line-kind-label : i64
  1)
(define compiler-backend-sweep-line-kind-instruction : i64
  2)

;; Packed delta-independent predicates for one instruction line (`sweep-flags`).
;; `win64-rbp-set` is the SHAPE only (`movq %rsp, %rbp`); the Win64 gate is
;; applied by the sweep, which alone knows the function's record.
(define compiler-backend-sweep-line-flag-push : i64
  1)
(define compiler-backend-sweep-line-flag-pop : i64
  2)
(define compiler-backend-sweep-line-flag-leaq : i64
  4)
(define compiler-backend-sweep-line-flag-leave : i64
  8)
(define compiler-backend-sweep-line-flag-ret : i64
  16)
(define compiler-backend-sweep-line-flag-jmp : i64
  32)
(define compiler-backend-sweep-line-flag-subq : i64
  64)
(define compiler-backend-sweep-line-flag-rsp-dst : i64
  128)
(define compiler-backend-sweep-line-flag-tracked-rsp-write : i64
  256)
(define compiler-backend-sweep-line-flag-win64-rbp-set : i64
  512)

;; An indexed / truncated `(%rsp` reference: disables the whole function
;; unconditionally (the sweep cannot bound what such a line touches).
;;
;; A `popq` whose operand addresses the frame is NOT fatal: a pop's frame
;; operand is a perfectly ordinary bounded reference, it just sits at a %rsp
;; that has ALREADY been incremented, so the replay canonicalizes it at delta-8
;; (matching the FPO rebase pass, which lowers delta before rewriting a pop's
;; refs). Production emission contains no `popq MEM` today, but treating one as
;; fatal would silently disqualify its whole function from the dead-frame-store
;; sweep.
(define compiler-backend-sweep-line-flag-fatal-mem : i64
  1024)

;; Bare `%rsp` occurrences, split by whether they sit at the line's final
;; operand position (`, %rsp`), which is the only position the tracked
;; subq/addq and Win64 epilogue shapes may write.
(define compiler-backend-sweep-line-flag-bare-rsp : i64
  2048)
(define compiler-backend-sweep-line-flag-bare-rsp-tail : i64
  4096)

(define (compiler-backend-sweep-storage-ensure!
  [backend-state : be_state.CompilerBackendState]
  [stream : be_state.CompilerBackendStreamState]) : unit
  (let
    [data : (MutPtr be_state.CompilerBackendStreamStateData)
      (be_state.compiler-backend-stream-state-ptr stream)]
    (unsafe
      (if (> (array-length (deref data).sweep-sym-off) 0)
        unit
        (let
          [owner : arena.Arena
            (be_state.compiler-backend-state-lazy-table-arena-ensure!
              backend-state)]
          (in-arena
            owner
            (let
              [cap : i64 compiler-backend-sweep-initial-capacity]
              (set! (deref data).sweep-sym-off (__tl_make-array i64 cap))
              (set! (deref data).sweep-sym-len (__tl_make-array i64 cap))
              (set! (deref data).sweep-lo-arr (__tl_make-array i64 cap))
              (set! (deref data).sweep-hi-arr (__tl_make-array i64 cap))
              (set! (deref data).sweep-disp-arr (__tl_make-array i64 cap))
              (set! (deref data).sweep-win64-arr (__tl_make-array i64 cap))
              (set! (deref data).sweep-em-lo-arr (__tl_make-array i64 cap))
              (set! (deref data).sweep-em-hi-arr (__tl_make-array i64 cap))
              (set!
                (deref data).sweep-sym-bytes
                (__tl_make-array
                  u8
                  compiler-backend-sweep-initial-bytes-capacity)))))))))

(define (compiler-backend-sweep-bytes-grow!
  [backend-state : be_state.CompilerBackendState]
  [stream : be_state.CompilerBackendStreamState]
  [required : i64]) : bool
  (unsafe
    (let
      [data : (MutPtr be_state.CompilerBackendStreamStateData)
        (be_state.compiler-backend-stream-state-ptr stream)]
      [old : (__tl_dyn-array u8) (deref data).sweep-sym-bytes]
      [new-cap : i64 (array-length old)]
      (while (and
        (< new-cap required)
        (< new-cap compiler-backend-sweep-bytes-capacity))
        (set!
          new-cap
          (if (> (* new-cap 4) compiler-backend-sweep-bytes-capacity)
            compiler-backend-sweep-bytes-capacity
            (* new-cap 4))))
      (if (< new-cap required)
        false
        (let
          [owner : arena.Arena
            (be_state.compiler-backend-state-lazy-table-arena-ensure!
              backend-state)]
          (in-arena
            owner
            (let
              [bytes : (__tl_dyn-array u8) (__tl_make-array u8 new-cap)]
              [i : i64 0]
              (while (< i (deref data).sweep-sym-bytes-count)
                (set! (array-ref bytes i) (array-ref old i))
                (+= i 1))
              (set! (deref data).sweep-sym-bytes bytes)
              true)))))))

;; Start the address-extent staging for one function emission attempt: move
;; the flush mark past anything an abandoned attempt left behind, so the slice
;; the accepted body's commit records holds exactly that body's addresses.
(define (compiler-backend-sweep-addr-begin!
  [backend-state : be_state.CompilerBackendState]) : unit
  (let
    [stream : be_state.CompilerBackendStreamState
      (be_state.compiler-backend-state-stream-state backend-state)]
    [_storage : unit
      (compiler-backend-sweep-storage-ensure! backend-state stream)]
    [data : (MutPtr be_state.CompilerBackendStreamStateData)
      (be_state.compiler-backend-stream-state-ptr stream)]
    (unsafe
      (set! (deref data).sweep-addr-flushed (deref data).sweep-addr-count)
      (set! (deref data).sweep-addr-overflow false))))

;; First function or helper boundary at/after `start`, or `count`. The
;; probe is a packed bit decided once, when the record was built.
(define (compiler-backend-sweep-region-end-records
  [recs : (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord)]
  [start : i64]
  [count : i64]) : i64
  (for [i (iterator.range start count)]
    (when
      (compiler-backend-peephole-record-sweep-boundary?
        (be_state.compiler-backend-global-array-element-shared-view recs i))
      (return i)))
  count)

;; First '%' index in [start, end-4], or -1: every position that can start a
;; four-byte "%rsp" reference. Jumps straight to it a word at a time.
(define (compiler-backend-sweep-next-percent
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : i64
  (let
    [stop : i64 (- end 3)]
    [hit : i64
      (be_operand.compiler-backend-peephole-scan-byte-range data start stop 37)]
    (if (>= hit stop)
      -1
      hit)))

;; If line [m,end) (mnemonic token ending at te) is exactly
;; `movq SRC, N(%rsp)` with SRC a single 64-bit GP %r* register (not %rsp) or
;; $imm token and a
;; digits-only offset, return the store's canonical offset N-delta; else the
;; no-candidate sentinel.
(define (compiler-backend-sweep-candidate-c
  [data : (Ptr u8)]
  [m : i64]
  [te : i64]
  [end : i64]
  [mnemonic-kind : i64]
  [comma-hint : i64]
  [delta : i64]) : i64
  (let
    [none : i64 compiler-backend-sweep-no-candidate]
    ;; lint-allow: nested-if-ladder
    (if (not
      (= mnemonic-kind be_operand.compiler-backend-control-mnemonic-movq))
      none
      (if (or (>= (+ te 1) end) (< (- end te) 10))
        none
        (if (not
          (and
            (= (be_state.compiler-backend-peephole-byte-at data (- end 1)) 41)
            (be_operand.compiler-backend-peephole-range-eq?
              data
              (- end 6)
              (- end 1)
              "(%rsp")))
          none
          (let
            [s0 : i64 (+ te 1)]
            [b0 : i64 (be_state.compiler-backend-peephole-byte-at data s0)]
            (if (not
              (or
                (= b0 36)
                (and
                  (= b0 37)
                  (< (+ s0 1) end)
                  (=
                    (be_state.compiler-backend-peephole-byte-at data (+ s0 1))
                    114))))
              none
              (let
                [c
                  : i64
                  ;; >= 0: the caller's descriptor already found this ", " at
                  ;; the same position the scan below would return.
                  (if (>= comma-hint 0)
                    comma-hint
                    (let
                      [q : i64 s0]
                      [found : i64 -1]
                      (while (and (= found -1) (< (+ q 1) end))
                        (if (and
                          (=
                            (be_state.compiler-backend-peephole-byte-at data q)
                            44)
                          (=
                            (be_state.compiler-backend-peephole-byte-at
                              data
                              (+ q 1))
                            32))
                          (set! found q)
                          (+= q 1)))
                      found))]
                (if (< c 0)
                  none
                  (let
                    [bad : bool false]
                    (for [j (iterator.range s0 c)]
                      (if (=
                        (be_state.compiler-backend-peephole-byte-at data j)
                        40)
                        (set! bad true)
                        unit))
                    (if (be_operand.compiler-backend-peephole-range-eq?
                      data
                      s0
                      c
                      "%rsp")
                      (set! bad true)
                      unit)
                    (if bad
                      none
                      (let
                        [ds : i64 (+ c 2)]
                        [de : i64 (- end 6)]
                        (if (>= ds de)
                          ;; bare "(%rsp)" store dst: not a rebased local.
                          none
                          (let
                            [ks : i64
                              (compiler-backend-rsp-rebase-int-start data m de)]
                            (if (not (= ks ds))
                              none
                              (-
                                (compiler-backend-rsp-rebase-parse-int
                                  data
                                  ks
                                  de)
                                delta))))))))))))))))

;; If line [m,end) is exactly `leaq N(%rsp), %rsp`, return the canonical N-delta.
;; Win64 uses this only for terminal CSR pop-run epilogues; callers still check
;; that the target is outside the local var span before admitting it.
(define (compiler-backend-sweep-rsp-leaq-to-rsp-c
  [data : (Ptr u8)]
  [m : i64]
  [te : i64]
  [end : i64]
  [mnemonic-kind : i64]
  [delta : i64]) : i64
  (let
    [none : i64 compiler-backend-sweep-no-candidate]
    ;; lint-allow: nested-if-ladder
    (if (not
      (= mnemonic-kind be_operand.compiler-backend-control-mnemonic-leaq))
      none
      (if (or (>= (+ te 1) end) (< (- end te) 14))
        none
        (if (not
          (be_operand.compiler-backend-peephole-range-eq?
            data
            (- end 6)
            end
            ", %rsp"))
          none
          (let
            [c : i64 (- end 6)]
            (if (or
              (< c (+ te 7))
              (not
                (= (be_state.compiler-backend-peephole-byte-at data (- c 1)) 41))
              (not
                (be_operand.compiler-backend-peephole-range-eq?
                  data
                  (- c 6)
                  (- c 1)
                  "(%rsp")))
              none
              (let
                [ds : i64 (+ te 1)]
                [de : i64 (- c 6)]
                (if (>= ds de)
                  none
                  (let
                    [ks : i64 (compiler-backend-rsp-rebase-int-start data m de)]
                    (if (not (= ks ds))
                      none
                      (-
                        (compiler-backend-rsp-rebase-parse-int data ks de)
                        delta))))))))))))

;; True iff the "%rsp" at `q` on line [m,end) opens a MEMORY base reference,
;; i.e. it is preceded by '('. Whether that reference is CLOSED by ')' is asked
;; separately (below), because an unclosed one is the indexed/truncated form
;; that disables the function rather than a readable frame reference.
(define (compiler-backend-sweep-rsp-ref-memory-base?
  [data : (Ptr u8)]
  [m : i64]
  [q : i64]) : bool
  (and (> q m) (= (be_state.compiler-backend-peephole-byte-at data (- q 1)) 40)))

(define (compiler-backend-sweep-rsp-ref-closed?
  [data : (Ptr u8)]
  [q : i64]
  [end : i64]) : bool
  (and
    (< (+ q 4) end)
    (= (be_state.compiler-backend-peephole-byte-at data (+ q 4)) 41)))

;; Raw frame displacement of the `N(%rsp)` reference that starts at `q`.
;; A missing/indexed decimal reads as 0, exactly like the byte walk.
(define (compiler-backend-sweep-rsp-ref-offset
  [data : (Ptr u8)]
  [m : i64]
  [q : i64]) : i64
  (let
    [ks : i64 (compiler-backend-rsp-rebase-int-start data m (- q 1))]
    (if (< ks 0)
      0
      (compiler-backend-rsp-rebase-parse-int data ks (- q 1)))))

;; Raw displacement of the k-th closed `N(%rsp)` memory reference on line
;; [m,end). The record caches k = 0; x86 encodes at most one memory operand
;; per instruction, so this walk only ever serves a hand-written or future
;; multi-reference line (k >= 1) and keeps that case exact instead of
;; approximating it.
(define (compiler-backend-sweep-line-mem-off-nth
  [data : (Ptr u8)]
  [m : i64]
  [end : i64]
  [k : i64]) : i64
  (let
    [seen : i64 0]
    [q : i64 m]
    (while (<= (+ q 4) end)
      (let
        [pct : i64 (compiler-backend-sweep-next-percent data q end)]
        (if (< pct 0)
          (set! q end)
          (set! q pct))
        (if (and
          (>= pct 0)
          (= (be_state.compiler-backend-peephole-byte-at data (+ q 1)) 114)
          (= (be_state.compiler-backend-peephole-byte-at data (+ q 2)) 115)
          (= (be_state.compiler-backend-peephole-byte-at data (+ q 3)) 112))
          (begin
            (when
              (and
                (compiler-backend-sweep-rsp-ref-memory-base? data m q)
                (compiler-backend-sweep-rsp-ref-closed? data q end))
              (when
                (= seen k)
                (return (compiler-backend-sweep-rsp-ref-offset data m q)))
              (+= seen 1))
            (+= q 4))
          (+= q 1))))
    0))

;; Canonical register bit for the `%name` at `pos`: 0..15 for the general
;; purpose file in encoding order, 16 for the whole vector file (collapsed --
;; the saving prologue never needs finer resolution), -1 for anything that is
;; not a register operand (`%rip`).
(define (compiler-backend-swb-gp-pair-bit [c1 : i64] [c2 : i64]) : i64
  (cond
    [(and (= c1 97) (= c2 120)) 0]
    [(and (= c1 99) (= c2 120)) 1]
    [(and (= c1 100) (= c2 120)) 2]
    [(and (= c1 98) (= c2 120)) 3]
    [(and (= c1 115) (= c2 112)) 4]
    [(and (= c1 98) (= c2 112)) 5]
    [(and (= c1 115) (= c2 105)) 6]
    [(and (= c1 100) (= c2 105)) 7]
    [(and (= c1 97) (or (= c2 108) (= c2 104))) 0]
    [(and (= c1 99) (or (= c2 108) (= c2 104))) 1]
    [(and (= c1 100) (or (= c2 108) (= c2 104))) 2]
    [(and (= c1 98) (or (= c2 108) (= c2 104))) 3]
    [else -1]))

(define (compiler-backend-swb-reg-bit
  [data : (Ptr u8)]
  [pos : i64]
  [stop : i64]) : i64
  (let
    [b1 : i64
      (if (< (+ pos 1) stop)
        (be_state.compiler-backend-peephole-byte-at data (+ pos 1))
        0)]
    [b2 : i64
      (if (< (+ pos 2) stop)
        (be_state.compiler-backend-peephole-byte-at data (+ pos 2))
        0)]
    [b3 : i64
      (if (< (+ pos 3) stop)
        (be_state.compiler-backend-peephole-byte-at data (+ pos 3))
        0)]
    (cond
      [(and (or (= b1 120) (= b1 121) (= b1 122)) (= b2 109) (= b3 109)) 16]
      [(= b1 114)
        (cond
          [(or (= b2 56) (= b2 57)) (- b2 48)]
          [(and (= b2 49) (>= b3 48) (<= b3 53)) (+ 10 (- b3 48))]
          [else (compiler-backend-swb-gp-pair-bit b2 b3)])]
      [(= b1 101) (compiler-backend-swb-gp-pair-bit b2 b3)]
      [else (compiler-backend-swb-gp-pair-bit b1 b2)])))

;; The register file a stretch of emitted text names, as a bitmask.
(define (compiler-backend-swb-reg-mask-range
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : i64
  (let
    [i : i64 start]
    [mask : i64 0]
    (while (< i end)
      (let
        [at : i64
          (be_operand.compiler-backend-peephole-scan-byte-range data i end 37)]
        (when (= at end) (return mask))
        (let
          [bit : i64 (compiler-backend-swb-reg-bit data at end)]
          (when (>= bit 0) (set! mask (bit-or mask (shl 1 bit)))))
        (set! i (+ at 1))))
    mask))

(define (compiler-backend-peephole-append-line
  [buf : (text_buf_borrowed.TextBufBorrowed asm)]
  [line : String]
  [newline : bool]) : (text_buf_borrowed.TextBufBorrowed asm)
  (if newline
    (text_buf_borrowed.append-char
      (text_buf_borrowed.append-owned buf line)
      '\n')
    (text_buf_borrowed.append-owned buf line)))

(define (compiler-backend-peephole-append-line-range
  [buf : (text_buf_borrowed.TextBufBorrowed asm)]
  [asm : (& asm str)]
  [start : i64]
  [end : i64]
  [newline : bool]) : (text_buf_borrowed.TextBufBorrowed asm)
  (let
    [slice-end : i64
      (if newline
        (+ end 1)
        end)]
    (if (> slice-end start)
      (unsafe
        ;; Line/record scanning bounds the optional newline extension by asm.
        (text_buf_borrowed.append-slice-unchecked
          buf
          (& asm)
          start
          (- slice-end start)))
      buf)))

(define (compiler-backend-peephole-movq-prefix-len) : i64
  9)

(define (compiler-backend-peephole-movq-prefix-at-range?
  [asm-data : (Ptr u8)]
  [start : i64]
  [end : i64]) : bool
  (if (> (+ start (compiler-backend-peephole-movq-prefix-len)) end)
    false
    (and
      (= (be_state.compiler-backend-peephole-byte-at asm-data start) 32)
      (= (be_state.compiler-backend-peephole-byte-at asm-data (+ start 1)) 32)
      (= (be_state.compiler-backend-peephole-byte-at asm-data (+ start 2)) 32)
      (= (be_state.compiler-backend-peephole-byte-at asm-data (+ start 3)) 32)
      (= (be_state.compiler-backend-peephole-byte-at asm-data (+ start 4)) 109)
      (= (be_state.compiler-backend-peephole-byte-at asm-data (+ start 5)) 111)
      (= (be_state.compiler-backend-peephole-byte-at asm-data (+ start 6)) 118)
      (= (be_state.compiler-backend-peephole-byte-at asm-data (+ start 7)) 113)
      (= (be_state.compiler-backend-peephole-byte-at asm-data (+ start 8)) 32))))

;; First ", " in [start, end), or -1. Jumps between ',' bytes a word at a time
;; instead of stepping every byte.
(define (compiler-backend-peephole-find-comma-space-range
  [asm-data : (Ptr u8)]
  [start : i64]
  [end : i64]) : i64
  (let
    [stop : i64 (- end 1)]
    [i : i64 start]
    [found : i64 -1]
    [done : bool false]
    (while (and (not done) (< (+ i 1) end))
      (let
        [pos : i64
          (be_operand.compiler-backend-peephole-scan-byte-range
            asm-data
            i
            stop
            44)]
        (if (>= pos stop)
          (set! done true)
          (if (=
            (be_state.compiler-backend-peephole-byte-at asm-data (+ pos 1))
            32)
            (begin
              (set! found pos)
              (set! done true))
            (set! i (+ pos 1))))))
    found))

;; M-G3 stage 1: frame slots are emitted rsp-relative (`N(%rsp)`); rbp forms
;; survive in needs-rbp functions and at positive incoming-stack-arg offsets.
;; Recognizing `(%rsp)` operands as slots is sound with the same argument as
;; rbp: every %rsp-mutating line (pushq/popq/subq/addq/leave/leaq-to-rsp/
;; movq-to-rsp/ret) is a non-movq/movq-to-untracked line that clears the whole
;; owner map; a returned call restores %rsp and keeps only callee-saved
;; stack-slot owners. Within any owner-map lifetime %rsp is therefore constant
;; for a tracked owner, and equal operand strings imply equal addresses (and
;; distinct strings, distinct addresses). Indexed forms contain "(%rsp," /
;; "(%rbp," and stay excluded.
;; SCAV2: true iff `operand` is a RIP-relative global reference `SYM(%rip)` -- a
;; load of a module-level global's contents. Its address is a fixed symbol, so
;; the operand string uniquely identifies the memory location (equal strings =>
;; equal addresses, distinct strings => distinct addresses), exactly like a stack
;; slot. Indexed rip forms do not exist on x86-64, so a trailing "(%rip)" is
;; unambiguous. Distinct from stack slots (which spell "(%rbp)"/"(%rsp)").
;; SCAV2: memory operands the owner map may track with structured identity:
;; rbp/rsp stack slots AND SYM(%rip) globals. Both are stable addresses whose contents
;; change only via a store to that exact operand: a store to a slot clears just
;; that slot's mirrors (movq-owners-transfer stack-slot arm); a store to a global
;; or through any pointer clears the whole map (the else arm /
;; line-clobber-owners). Calls clear all global mirrors and caller-saved stack
;; mirrors, while preserving only callee-saved stack-slot mirrors. Since a stack
;; store cannot alias a global and vice versa, keeping a global mirror across a
;; stack store (and a slot mirror across a global store's whole-map clear is
;; moot) is sound.
(define (compiler-backend-peephole-owner-key-unknown) : i64
  0)

(define (compiler-backend-peephole-owner-key-known? [key : i64]) : bool
  (not (= key 0)))

;; Provenance bit carried ABOVE every key an owner slot holds: set when the
;; mirror was established by a STORE `movq %reg, SLOT`, clear when a LOAD
;; established it. Only a call reads it (see call-preserved-owner); every other
;; consumer compares keys through `owner-key-eq?`, which strips it, so a mirror
;; behaves identically either way inside a call-free run. Keys parsed from a
;; line never carry it. Stack keys are small positives and global keys are
;; negative, so bit 62 is free and setting it on a stack key keeps it positive.
(define compiler-backend-peephole-owner-key-store-bit : i64
  4611686018427387904)

(define (compiler-backend-peephole-owner-key-base [key : i64]) : i64
  (if (= (bit-and key compiler-backend-peephole-owner-key-store-bit) 0)
    key
    (- key compiler-backend-peephole-owner-key-store-bit)))

(define (compiler-backend-peephole-owner-key-from-store? [key : i64]) : bool
  (not (= (bit-and key compiler-backend-peephole-owner-key-store-bit) 0)))

(define (compiler-backend-peephole-owner-key-mark-store [key : i64]) : i64
  (if (compiler-backend-peephole-owner-key-stack? key)
    (bit-or key compiler-backend-peephole-owner-key-store-bit)
    key))

(define (compiler-backend-peephole-owner-key-stack? [key : i64]) : bool
  (> (compiler-backend-peephole-owner-key-base key) 0))

(define (compiler-backend-peephole-owner-key-eq? [left : i64] [right : i64]) : bool
  (=
    (compiler-backend-peephole-owner-key-base left)
    (compiler-backend-peephole-owner-key-base right)))

;; `owner-key-eq?` against a key whose base the caller has already taken, for
;; the scans that compare one location against all fourteen registers.
(define (compiler-backend-peephole-owner-key-base-eq? [key : i64] [base : i64]) : bool
  (= (compiler-backend-peephole-owner-key-base key) base))

(define compiler-backend-peephole-owner-global-initial-capacity : i64
  64)
(define compiler-backend-peephole-owner-global-capacity : i64
  16384)
(define compiler-backend-peephole-owner-global-initial-bytes-capacity : i64
  1024)
(define compiler-backend-peephole-owner-global-bytes-capacity : i64
  1048576)

;; The offsets table is generation-stamped instead of cleared: an entry packs
;; the generation that wrote it above the byte offset it holds, so a reset is a
;; counter bump rather than a 16384-slot store loop. A slot is EMPTY for the
;; current generation exactly when its stamp differs, so probe order, insertion
;; order and the returned keys are bit-for-bit what a table cleared on every
;; reset would produce.
;;
;; The offset field is 20 bits wide because the byte pool is 2^20 bytes and a
;; stored symbol is at least one byte long, so a stored start is at most
;; 2^20 - 1. A freshly allocated (zeroed) table reads as generation 0 and the
;; counter starts at 1, so every slot of a newly allocated table is empty.
(define compiler-backend-peephole-owner-global-generation-shift : i64
  20)
(define compiler-backend-peephole-owner-global-offset-mask : i64
  1048575)

(define (compiler-backend-peephole-owner-global-entry-live?
  [generation : i64]
  [entry : i64]) : bool
  (=
    (shr entry compiler-backend-peephole-owner-global-generation-shift)
    generation))

(define (compiler-backend-peephole-owner-global-entry-offset [entry : i64]) : i64
  (bit-and entry compiler-backend-peephole-owner-global-offset-mask))

(define (compiler-backend-peephole-owner-global-entry-pack
  [generation : i64]
  [offset : i64]) : i64
  (bit-or
    offset
    (shl generation compiler-backend-peephole-owner-global-generation-shift)))

(define (compiler-backend-peephole-owner-global-storage-ensure-with-backend-state!
  [backend-state : be_state.CompilerBackendState]
  [stream : be_state.CompilerBackendStreamState]) : unit
  (let
    [data : (MutPtr be_state.CompilerBackendStreamStateData)
      (be_state.compiler-backend-stream-state-ptr stream)]
    (if (>
      (array-length
        (unsafe
          (deref data).owner-global-offsets))
      0)
      unit
      (let
        [owner : arena.Arena
          (be_state.compiler-backend-state-lazy-table-arena-ensure!
            backend-state)]
        (in-arena
          owner
          (let
            [offsets : (__tl_dyn-array i64)
              (__tl_make-array
                i64
                compiler-backend-peephole-owner-global-initial-capacity)]
            [lengths : (__tl_dyn-array i64)
              (__tl_make-array
                i64
                compiler-backend-peephole-owner-global-initial-capacity)]
            [bytes : (__tl_dyn-array u8)
              (__tl_make-array
                u8
                compiler-backend-peephole-owner-global-initial-bytes-capacity)]
            (unsafe
              (set! (deref data).owner-global-offsets offsets)
              (set! (deref data).owner-global-lengths lengths)
              (set! (deref data).owner-global-bytes bytes)
              (set! (deref data).owner-global-bytes-count 0)
              (set! (deref data).owner-global-generation 1))))))))

(define (compiler-backend-peephole-owner-global-table-grow!
  [backend-state : be_state.CompilerBackendState]
  [stream : be_state.CompilerBackendStreamState]) : bool
  (let
    [data : be_state.CompilerBackendStreamStateData
      (be_state.compiler-backend-stream-state-data stream)]
    [old-offsets : (__tl_dyn-array i64) data.owner-global-offsets]
    [old-lengths : (__tl_dyn-array i64) data.owner-global-lengths]
    [old-cap : i64 (array-length old-offsets)]
    [new-cap : i64
      (if (> (* old-cap 2) compiler-backend-peephole-owner-global-capacity)
        compiler-backend-peephole-owner-global-capacity
        (* old-cap 2))]
    (if (<= new-cap old-cap)
      false
      (let
        [owner : arena.Arena
          (be_state.compiler-backend-state-lazy-table-arena-ensure!
            backend-state)]
        (in-arena
          owner
          (let
            [offsets : (__tl_dyn-array i64) (__tl_make-array i64 new-cap)]
            [lengths : (__tl_dyn-array i64) (__tl_make-array i64 new-cap)]
            [bytes : (__tl_dyn-array u8) data.owner-global-bytes]
            [generation : i64 data.owner-global-generation]
            (for [i (iterator.range 0 old-cap)]
              (let
                [entry : i64 (array-ref old-offsets i)]
                (when
                  (compiler-backend-peephole-owner-global-entry-live?
                    generation
                    entry)
                  (let
                    [off : i64
                      (compiler-backend-peephole-owner-global-entry-offset
                        entry)]
                    [len : i64 (array-ref old-lengths i)]
                    [hash : i64
                      (ci.intern-hash-words
                        (unsafe
                          (ptr-cast (__tl_array-data bytes) : (Ptr u8)))
                        off
                        len)]
                    [slot : i64 (bit-and hash (- new-cap 1))]
                    (while (compiler-backend-peephole-owner-global-entry-live?
                      generation
                      (array-ref offsets slot))
                      (set!
                        slot
                        (if (= (+ slot 1) new-cap)
                          0
                          (+ slot 1))))
                    (set!
                      (array-ref offsets slot)
                      (compiler-backend-peephole-owner-global-entry-pack
                        generation
                        off))
                    (set! (array-ref lengths slot) len)))))
            (set! data.owner-global-offsets offsets)
            (set! data.owner-global-lengths lengths)
            (be_state.compiler-backend-stream-state-data-set!
              stream
              (be_state.compiler-backend-global-shared-view data))
            true))))))

(define (compiler-backend-peephole-owner-global-bytes-grow!
  [backend-state : be_state.CompilerBackendState]
  [stream : be_state.CompilerBackendStreamState]
  [required : i64]) : bool
  (let
    [data : (MutPtr be_state.CompilerBackendStreamStateData)
      (be_state.compiler-backend-stream-state-ptr stream)]
    [old : (__tl_dyn-array u8)
      (unsafe
        (deref data).owner-global-bytes)]
    [old-cap : i64 (array-length old)]
    [new-cap : i64 old-cap]
    (while (and
      (< new-cap required)
      (< new-cap compiler-backend-peephole-owner-global-bytes-capacity))
      (set!
        new-cap
        (if (>
          (* new-cap 2)
          compiler-backend-peephole-owner-global-bytes-capacity)
          compiler-backend-peephole-owner-global-bytes-capacity
          (* new-cap 2))))
    (if (< new-cap required)
      false
      (let
        [owner : arena.Arena
          (be_state.compiler-backend-state-lazy-table-arena-ensure!
            backend-state)]
        (in-arena
          owner
          (let
            [bytes : (__tl_dyn-array u8) (__tl_make-array u8 new-cap)]
            (for [i
              (iterator.range
                0
                (unsafe
                  (deref data).owner-global-bytes-count))]
              (set! (array-ref bytes i) (array-ref old i)))
            (unsafe
              (set! (deref data).owner-global-bytes bytes))
            true))))))

(define (compiler-backend-peephole-owner-global-reset-with-backend-state!
  [backend-state : be_state.CompilerBackendState]
  [stream : be_state.CompilerBackendStreamState]) : unit
  (let
    [_storage : unit
      (compiler-backend-peephole-owner-global-storage-ensure-with-backend-state!
        backend-state
        stream)]
    [data : (MutPtr be_state.CompilerBackendStreamStateData)
      (be_state.compiler-backend-stream-state-ptr stream)]
    (unsafe
      (set!
        (deref data).owner-global-generation
        (+ (deref data).owner-global-generation 1))
      (set! (deref data).owner-global-bytes-count 0))
    unit))

(define (compiler-backend-peephole-owner-global-bytes-eq?
  [bytes : (& bytes (__tl_dyn-array u8))]
  [off : i64]
  [len : i64]
  [data : (Ptr u8)]
  [data-start : i64]
  [klen : i64]) : bool
  (if (not (= len klen))
    false
    (let
      [j : i64 0]
      [ok : bool true]
      (while (and ok (< j len))
        (if (=
          (cast (array-ref bytes (+ off j)) : i64)
          (be_state.compiler-backend-peephole-byte-at data (+ data-start j)))
          unit
          (set! ok false))
        (+= j 1))
      ok)))

(define (compiler-backend-peephole-owner-global-key-range
  [context : be_state.CompilerBackendPeepholeParseContext]
  [operand-start : i64]
  [symbol-len : i64]) : i64
  (let
    [backend-state : be_state.CompilerBackendState
      (be_state.CompilerBackendState context.backend-state-address)]
    [stream : be_state.CompilerBackendStreamState
      (be_state.CompilerBackendStreamState context.stream-address)]
    [key-data : (Ptr u8) context.data]
    [hash : i64 (ci.intern-hash-words key-data operand-start symbol-len)]
    [state-data : (Ptr be_state.CompilerBackendStreamStateData)
      (be_state.compiler-backend-stream-state-view stream)]
    [offsets : (__tl_dyn-array i64)
      (unsafe
        (deref state-data).owner-global-offsets)]
    [lengths : (__tl_dyn-array i64)
      (unsafe
        (deref state-data).owner-global-lengths)]
    [bytes : (__tl_dyn-array u8)
      (unsafe
        (deref state-data).owner-global-bytes)]
    [generation : i64
      (unsafe
        (deref state-data).owner-global-generation)]
    [cap : i64 (array-length offsets)]
    [slot : i64 (bit-and hash (- cap 1))]
    (for [walked (iterator.range 0 cap)]
      (let
        [entry : i64 (array-ref offsets slot)]
        (if (not
          (compiler-backend-peephole-owner-global-entry-live? generation entry))
          (let
            [start : i64
              (unsafe
                (deref state-data).owner-global-bytes-count)]
            (if (or
              (<=
                (+ start symbol-len)
                (array-length
                  (unsafe
                    (deref state-data).owner-global-bytes)))
              (compiler-backend-peephole-owner-global-bytes-grow!
                backend-state
                stream
                (+ start symbol-len)))
              (let
                [current : (MutPtr be_state.CompilerBackendStreamStateData)
                  (be_state.compiler-backend-stream-state-ptr stream)]
                [bytes : (__tl_dyn-array u8)
                  (unsafe
                    (deref current).owner-global-bytes)]
                (for [j (iterator.range 0 symbol-len)]
                  (set!
                    (array-ref bytes (+ start j))
                    (cast
                      (be_state.compiler-backend-peephole-byte-at
                        key-data
                        (+ operand-start j))
                      : u8)))
                (set!
                  (array-ref offsets slot)
                  (compiler-backend-peephole-owner-global-entry-pack
                    generation
                    start))
                (set! (array-ref lengths slot) symbol-len)
                (unsafe
                  (set!
                    (deref current).owner-global-bytes-count
                    (+ start symbol-len)))
                (return (- 0 (+ start 1))))
              (return (compiler-backend-peephole-owner-key-unknown))))
          (if (compiler-backend-peephole-owner-global-bytes-eq?
            bytes
            (compiler-backend-peephole-owner-global-entry-offset entry)
            (array-ref lengths slot)
            key-data
            operand-start
            symbol-len)
            (return
              (-
                0
                (+
                  (compiler-backend-peephole-owner-global-entry-offset entry)
                  1)))
            (set!
              slot
              (if (>= (+ slot 1) cap)
                0
                (+ slot 1)))))))
    (if (compiler-backend-peephole-owner-global-table-grow!
      backend-state
      stream)
      (compiler-backend-peephole-owner-global-key-range
        context
        operand-start
        symbol-len)
      (compiler-backend-peephole-owner-key-unknown))))

(define (compiler-backend-peephole-stack-owner-key-from-parts
  [base : i64]
  [offset : i64]
  [explicit : bool]) : i64
  (let
    [bias : i64 be_state.compiler-backend-peephole-owner-key-stack-bias]
    (if (or (< offset (- 0 bias)) (> offset bias))
      (compiler-backend-peephole-owner-key-unknown)
      (+
        1
        (+
          (* 4 (+ offset bias))
          (+
            (* base 2)
            (if explicit
              1
              0)))))))

(define compiler-backend-peephole-memory-base-none : i64
  0)
(define compiler-backend-peephole-memory-base-rbp : i64
  1)
(define compiler-backend-peephole-memory-base-rsp : i64
  2)
(define compiler-backend-peephole-memory-base-rip : i64
  3)
(define compiler-backend-peephole-memory-base-r10 : i64
  4)

;; Fixed memory bases emitted by the backend all have a six-byte suffix. Parse
;; that suffix once per movq operand, then share the compact result between
;; owner-key construction and the operand flags instead of independently
;; comparing or searching the same bytes for rbp, rsp, rip, and r10.
(define (compiler-backend-peephole-memory-base-range
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : i64
  (if (< (- end start) 6)
    compiler-backend-peephole-memory-base-none
    (let
      [s : i64 (- end 6)]
      (if (and
        (= (be_state.compiler-backend-peephole-byte-at data s) 40)
        (= (be_state.compiler-backend-peephole-byte-at data (+ s 1)) 37)
        (= (be_state.compiler-backend-peephole-byte-at data (+ s 2)) 114)
        (= (be_state.compiler-backend-peephole-byte-at data (+ s 5)) 41))
        (let
          [b3 : i64 (be_state.compiler-backend-peephole-byte-at data (+ s 3))]
          [b4 : i64 (be_state.compiler-backend-peephole-byte-at data (+ s 4))]
          (if (= b4 112)
            (cond
              [(= b3 98) compiler-backend-peephole-memory-base-rbp]
              [(= b3 115) compiler-backend-peephole-memory-base-rsp]
              [(= b3 105) compiler-backend-peephole-memory-base-rip]
              [else compiler-backend-peephole-memory-base-none])
            (if (and (= b3 49) (= b4 48))
              compiler-backend-peephole-memory-base-r10
              compiler-backend-peephole-memory-base-none)))
        compiler-backend-peephole-memory-base-none))))

(define (compiler-backend-peephole-owner-key-from-range
  [context : be_state.CompilerBackendPeepholeParseContext]
  [start : i64]
  [end : i64]
  [memory-base : i64]) : i64
  (let
    [data : (Ptr u8) context.data]
    [prefix-end : i64 (- end 6)]
    (cond
      [(or
          (= memory-base compiler-backend-peephole-memory-base-rbp)
          (= memory-base compiler-backend-peephole-memory-base-rsp))
        (let
          [base : i64
            (if (= memory-base compiler-backend-peephole-memory-base-rbp)
              0
              1)]
          (cond
            [(= prefix-end start)
              (compiler-backend-peephole-stack-owner-key-from-parts
                base
                0
                false)]
            [else
              ;; Validate and accumulate the displacement together. The former
              ;; valid?/value pair walked every digit twice on the overwhelmingly
              ;; common explicit stack-slot spelling.
              (let
                [neg : bool
                  (= (be_state.compiler-backend-peephole-byte-at data start) 45)]
                [i : i64
                  (if neg
                    (+ start 1)
                    start)]
                [valid : bool (< i prefix-end)]
                [value : i64 0]
                (while (and valid (< i prefix-end))
                  (let
                    [b : i64
                      (be_state.compiler-backend-peephole-byte-at data i)]
                    (if (and (>= b 48) (<= b 57))
                      (set! value (+ (* value 10) (- b 48)))
                      (set! valid false))
                    (+= i 1)))
                (if valid
                  (compiler-backend-peephole-stack-owner-key-from-parts
                    base
                    (if neg
                      (- 0 value)
                      value)
                    true)
                  (compiler-backend-peephole-owner-key-unknown)))]))]
      [(and
          (= memory-base compiler-backend-peephole-memory-base-rip)
          (> prefix-end start))
        (compiler-backend-peephole-owner-global-key-range
          context
          start
          (- prefix-end start))]
      [else (compiler-backend-peephole-owner-key-unknown)])))

;; ---- Fold `movq SRC,%r10 ; movq DISP(%r10),DST` -> `movq DISP(SRC),DST` ----
;; SRC must be a register (not %r10); the deref source must be a base-only %r10
;; memory operand DISP(%r10) (no index). Sound iff %r10 is dead after the deref:
;; either DST==%r10 (the staged value is immediately overwritten by the load), or
;; the forward scan proves %r10's next textual touch is a clean re-write with only
;; non-%r10 movq lines in between (conservative: any non-movq / control flow stops
;; the scan as "not provably dead").
(define (compiler-backend-peephole-r10-base-rewrite
  [operand : String]
  [base : String]) : String
  (let
    [len : i64 (string.string-length operand)]
    (str_cat.str-cat (string.substring operand 0 (- len 6)) "(" base ")")))

;; Is %r10 dead after `start`? Conservative movq-only scan: the first line that
;; touches %r10 must be a clean write; the scan passes only over non-%r10 movq
;; lines; any other line (ALU / call / jmp / label / ret / directive) stops the
;; scan as "not provably dead". Returns true only on a definite clean re-write.
(define compiler-backend-peephole-r10-dead-scan-line-cap : i64
  128)

;; Zext dedup: the 64-bit destination register of a `movzbq`/`movzbl` line over
;; [start,end), or "" when the line is not a byte zero-extend into a tracked GP
;; register. Both forms leave the full 64-bit destination holding a value in
;; [0,255] (32-bit writes zero the upper half), so a following
;; `movzbq %<dst-low-byte>, %<dst>` re-extend is an identity.
;; True when the line [ns,ne) is exactly `movzbq %B, R` with %B the low-byte
;; sub-register of R. Paired with a pending byte zero-extend into R, this
;; re-extend is an identity and is dropped (pair-action 2). The source token
;; must be a byte register ('l'/'b' suffix); 16/32-bit sub-register tokens and
;; memory operands never match.
;; True when pending is a byte zero-extend into register R and next is the
;; identity re-extend `movzbq %<R-low-byte>, R`.
;; All-unknown owner map: every tracked register mirrors no known location.
(define (compiler-backend-peephole-owners-empty) : be_state.CompilerBackendPeepholeOwners
  (be_state.CompilerBackendPeepholeOwners
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)))

(define (compiler-backend-peephole-owners-copy
  [owners : be_state.CompilerBackendPeepholeOwners]) : be_state.CompilerBackendPeepholeOwners
  (be_state.CompilerBackendPeepholeOwners
    owners.rax
    owners.rcx
    owners.rdx
    owners.rbx
    owners.rsi
    owners.rdi
    owners.r8
    owners.r9
    owners.r10
    owners.r11
    owners.r12
    owners.r13
    owners.r14
    owners.r15))

;; Dense index 0..13 for the 14 general-purpose registers owned by the register
;; allocator, or -1 for anything else (immediates, stack slots, %rbp/%rsp/%rip,
;; xmm/untracked registers). Register operands are a fixed tiny set, so classify
;; them by their bytes in a single pass instead of up to 14 sequential
;; `eq-mnemonic` calls: this is the hot dispatch behind the peephole owner map and
;; the byte scan short-circuits the overwhelmingly common non-register operand on
;; the first one or two bytes. The mapping is exact (the same accept set and
;; ordering as a string-compare chain), so owner-map decisions do not depend on
;; which classifier answers.
(define (compiler-backend-peephole-reg-index-range
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : i64
  (let
    [n : i64 (- end start)]
    (if (or (< n 3) (> n 4))
      -1
      (let
        [b0 : i64 (be_state.compiler-backend-peephole-byte-at data start)]
        [b1 : i64 (be_state.compiler-backend-peephole-byte-at data (+ start 1))]
        [b2 : i64 (be_state.compiler-backend-peephole-byte-at data (+ start 2))]
        (if (or (not (= b0 37)) (not (= b1 114)))
          -1
          (if (= n 3)
            (cond [(= b2 56) 6] [(= b2 57) 7] [else -1])
            (let
              [b3 : i64
                (be_state.compiler-backend-peephole-byte-at data (+ start 3))]
              (cond
                [(= b2 97)
                  (if (= b3 120)
                    0
                    -1)]
                [(= b2 99)
                  (if (= b3 120)
                    1
                    -1)]
                [(= b2 100) (cond [(= b3 120) 2] [(= b3 105) 5] [else -1])]
                [(= b2 98)
                  (if (= b3 120)
                    3
                    -1)]
                [(= b2 115)
                  (if (= b3 105)
                    4
                    -1)]
                [(= b2 49)
                  (cond
                    [(= b3 48) 8]
                    [(= b3 49) 9]
                    [(= b3 50) 10]
                    [(= b3 51) 11]
                    [(= b3 52) 12]
                    [(= b3 53) 13]
                    [else -1])]
                [else -1]))))))))

;; True iff `operand` is exactly one of the 14 general-purpose registers owned
;; by the register allocator. %rbp and %rsp are deliberately excluded.
;; Location currently mirrored by `reg`, or Unknown if unknown / `reg` is not tracked.
(define (compiler-backend-peephole-owners-get-index
  [owners : be_state.CompilerBackendPeepholeOwners]
  [idx : i64]) : i64
  (cond
    [(= idx 0) owners.rax]
    [(= idx 1) owners.rcx]
    [(= idx 2) owners.rdx]
    [(= idx 3) owners.rbx]
    [(= idx 4) owners.rsi]
    [(= idx 5) owners.rdi]
    [(= idx 6) owners.r8]
    [(= idx 7) owners.r9]
    [(= idx 8) owners.r10]
    [(= idx 9) owners.r11]
    [(= idx 10) owners.r12]
    [(= idx 11) owners.r13]
    [(= idx 12) owners.r14]
    [(= idx 13) owners.r15]
    [else (compiler-backend-peephole-owner-key-unknown)]))

;; The first tracked GP register whose mirrored location equals `slot`, other than
;; `exclude`, or "" if none. Drives cross-register reload reuse: a redundant
;; `movq SLOT, exclude` becomes `movq <found>, exclude` (reg-reg, cheaper) when
;; another register already holds SLOT's value. The per-location owner-clear
;; invariant guarantees `found` still holds SLOT (not written since it loaded it,
;; and SLOT not written since -- a location write clears every mirror). Unknown
;; matches nothing (a reg with unknown owner must never be "reused").
(define (compiler-backend-peephole-owners-find-reg-for-slot-index
  [owners : be_state.CompilerBackendPeepholeOwners]
  [slot : i64]
  [exclude : i64]) : String
  (if (not (compiler-backend-peephole-owner-key-known? slot))
    ""
    (let
      [ex : i64 exclude]
      [base : i64 (compiler-backend-peephole-owner-key-base slot)]
      (cond
        [(and
            (not (= ex 0))
            (compiler-backend-peephole-owner-key-base-eq? owners.rax base))
          "%rax"]
        [(and
            (not (= ex 1))
            (compiler-backend-peephole-owner-key-base-eq? owners.rcx base))
          "%rcx"]
        [(and
            (not (= ex 2))
            (compiler-backend-peephole-owner-key-base-eq? owners.rdx base))
          "%rdx"]
        [(and
            (not (= ex 3))
            (compiler-backend-peephole-owner-key-base-eq? owners.rbx base))
          "%rbx"]
        [(and
            (not (= ex 4))
            (compiler-backend-peephole-owner-key-base-eq? owners.rsi base))
          "%rsi"]
        [(and
            (not (= ex 5))
            (compiler-backend-peephole-owner-key-base-eq? owners.rdi base))
          "%rdi"]
        [(and
            (not (= ex 6))
            (compiler-backend-peephole-owner-key-base-eq? owners.r8 base))
          "%r8"]
        [(and
            (not (= ex 7))
            (compiler-backend-peephole-owner-key-base-eq? owners.r9 base))
          "%r9"]
        [(and
            (not (= ex 8))
            (compiler-backend-peephole-owner-key-base-eq? owners.r10 base))
          "%r10"]
        [(and
            (not (= ex 9))
            (compiler-backend-peephole-owner-key-base-eq? owners.r11 base))
          "%r11"]
        [(and
            (not (= ex 10))
            (compiler-backend-peephole-owner-key-base-eq? owners.r12 base))
          "%r12"]
        [(and
            (not (= ex 11))
            (compiler-backend-peephole-owner-key-base-eq? owners.r13 base))
          "%r13"]
        [(and
            (not (= ex 12))
            (compiler-backend-peephole-owner-key-base-eq? owners.r14 base))
          "%r14"]
        [(and
            (not (= ex 13))
            (compiler-backend-peephole-owner-key-base-eq? owners.r15 base))
          "%r15"]
        [else ""]))))

;; Owner map with `reg`'s owner set to `slot` (Unknown clears it). No-op when `reg`
;; is not a tracked register (e.g. an immediate or untracked register source).
(define (compiler-backend-peephole-owners-set-reg-index
  [owners : be_state.CompilerBackendPeepholeOwners]
  [idx : i64]
  [slot : i64]) : be_state.CompilerBackendPeepholeOwners
  (be_state.CompilerBackendPeepholeOwners
    (if (= idx 0)
      slot
      owners.rax)
    (if (= idx 1)
      slot
      owners.rcx)
    (if (= idx 2)
      slot
      owners.rdx)
    (if (= idx 3)
      slot
      owners.rbx)
    (if (= idx 4)
      slot
      owners.rsi)
    (if (= idx 5)
      slot
      owners.rdi)
    (if (= idx 6)
      slot
      owners.r8)
    (if (= idx 7)
      slot
      owners.r9)
    (if (= idx 8)
      slot
      owners.r10)
    (if (= idx 9)
      slot
      owners.r11)
    (if (= idx 10)
      slot
      owners.r12)
    (if (= idx 11)
      slot
      owners.r13)
    (if (= idx 12)
      slot
      owners.r14)
    (if (= idx 13)
      slot
      owners.r15)))

;; A complete movq mirror covers eight bytes. A narrow or unaligned write
;; can overlap it at a different offset. Keys have four values per byte,
;; so clear on the intersecting range and drop any mirror using another
;; stack base, whose relationship to this one is unknown here.
(define (compiler-backend-peephole-clear-overlapping-owner
  [owner : i64]
  [base : i64]
  [first : i64]
  [last : i64]) : i64
  (if (<= owner 0)
    owner
    (let
      [key : i64 (- (compiler-backend-peephole-owner-key-base owner) 1)]
      (if (or (!= (bit-and key 2) base) (and (>= key first) (< key last)))
        (compiler-backend-peephole-owner-key-unknown)
        owner))))

(define (compiler-backend-peephole-owners-clear-extent
  [owners : be_state.CompilerBackendPeepholeOwners]
  [slot : i64]
  [bytes : i64]) : be_state.CompilerBackendPeepholeOwners
  (when
    (=
      (bit-or
        owners.rax
        owners.rcx
        owners.rdx
        owners.rbx
        owners.rsi
        owners.rdi
        owners.r8
        owners.r9
        owners.r10
        owners.r11
        owners.r12
        owners.r13
        owners.r14
        owners.r15)
      0)
    (return owners))
  (let
    [key : i64 (- slot 1)]
    [base : i64 (bit-and key 2)]
    [aligned : i64 (bit-and key (- 0 4))]
    [first : i64 (- aligned 28)]
    [last : i64 (+ aligned (* bytes 4))]
    (be_state.CompilerBackendPeepholeOwners
      (compiler-backend-peephole-clear-overlapping-owner
        owners.rax
        base
        first
        last)
      (compiler-backend-peephole-clear-overlapping-owner
        owners.rcx
        base
        first
        last)
      (compiler-backend-peephole-clear-overlapping-owner
        owners.rdx
        base
        first
        last)
      (compiler-backend-peephole-clear-overlapping-owner
        owners.rbx
        base
        first
        last)
      (compiler-backend-peephole-clear-overlapping-owner
        owners.rsi
        base
        first
        last)
      (compiler-backend-peephole-clear-overlapping-owner
        owners.rdi
        base
        first
        last)
      (compiler-backend-peephole-clear-overlapping-owner
        owners.r8
        base
        first
        last)
      (compiler-backend-peephole-clear-overlapping-owner
        owners.r9
        base
        first
        last)
      (compiler-backend-peephole-clear-overlapping-owner
        owners.r10
        base
        first
        last)
      (compiler-backend-peephole-clear-overlapping-owner
        owners.r11
        base
        first
        last)
      (compiler-backend-peephole-clear-overlapping-owner
        owners.r12
        base
        first
        last)
      (compiler-backend-peephole-clear-overlapping-owner
        owners.r13
        base
        first
        last)
      (compiler-backend-peephole-clear-overlapping-owner
        owners.r14
        base
        first
        last)
      (compiler-backend-peephole-clear-overlapping-owner
        owners.r15
        base
        first
        last))))

;; Owner key that can survive a normal call. Calls may mutate globals, so a
;; callee-saved register keeps only stack-slot ownership across the boundary --
;; and only a mirror a LOAD established.
;;
;; A STORE-established one cannot be kept, because of the OUTGOING ARGUMENT AREA
;; at 0(%rsp) upward: that area is the CALLEE's incoming argument area, which the
;; callee owns and may overwrite -- this backend's own tail-call marshalling
;; provably does, since it rewrites its incoming stack args in place before
;; jumping -- and after the FPO rebase a local frame slot and an outgoing
;; argument slot are both spelled `N(%rsp)`, so a text pass cannot tell them
;; apart (the boundary is the per-function outgoing size, which is nowhere in
;; the text). Keeping one let a second identical `movq %r14, 0(%rsp)` argument
;; store be elided as a dead spill store (P22-A1) against a slot the callee had
;; already overwritten, and the argument was never passed at all. A LOAD is
;; never issued against the outgoing area, so a load-established mirror can only
;; name this function's own frame and survives the call unharmed -- and that is
;; the mirror the rule was written for, since the emergency-scavenge
;; `restore ... resave` pair is a load followed by the store it elides.
(define (compiler-backend-peephole-call-preserved-owner [owner : i64]) : i64
  (if (and
    (compiler-backend-peephole-owner-key-stack? owner)
    (not (compiler-backend-peephole-owner-key-from-store? owner)))
    owner
    (compiler-backend-peephole-owner-key-unknown)))

;; Owner map after a normal call returns. Preserve only stack-slot owners in the
;; tracked registers whose values are guaranteed across both SysV and Win64
;; Internal calls; RSI/RDI are volatile under both, and RBP is intentionally
;; untracked.
(define (compiler-backend-peephole-owners-clear-call-clobbers
  [owners : be_state.CompilerBackendPeepholeOwners]) : be_state.CompilerBackendPeepholeOwners
  (be_state.CompilerBackendPeepholeOwners
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-call-preserved-owner owners.rbx)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-owner-key-unknown)
    (compiler-backend-peephole-call-preserved-owner owners.r12)
    (compiler-backend-peephole-call-preserved-owner owners.r13)
    (compiler-backend-peephole-call-preserved-owner owners.r14)
    (compiler-backend-peephole-call-preserved-owner owners.r15)))

;; Owner-map transfer for a recognized `movq SRC, DST` line.
;;  * DST is a clean stack slot (a store): SRC's value is written to
;;    the slot. Every OTHER register that mirrored the slot becomes stale and is
;;    dropped (`owners-clear-extent`, which also drops SRC's entry when it happened
;;    to mirror this slot). SRC's value itself is unchanged, so any slot SRC
;;    already mirrors is preserved; only when SRC is a tracked register with no
;;    known location do we record that it now mirrors DST (a sound store-to-reload
;;    forward). Preserving an existing SRC owner is required: it keeps reloads of
;;    a *different* slot still resident in SRC eligible for elision.
;;  * DST is a tracked GP register (a load or reg-reg move): DST is overwritten,
;;    so it mirrors SRC when SRC is a known stack/global key, otherwise becomes unknown.
;;  * anything else for DST (%rbp/%rsp, an xmm/untracked register, or any memory
;;    operand that is not a clean stack slot -- indexed, pointer, rip-relative,
;;    or segment relative) may change the frame base or alias an unknown slot, so
;;    conservatively clear the whole map.
(define (compiler-backend-peephole-movq-owners-transfer-keyed-index
  [owners : be_state.CompilerBackendPeepholeOwners]
  [src-reg : i64]
  [dst-reg : i64]
  [src-key : i64]
  [dst-key : i64]) : be_state.CompilerBackendPeepholeOwners
  (cond
    [(compiler-backend-peephole-owner-key-stack? dst-key)
      (let
        [cleared : be_state.CompilerBackendPeepholeOwners
          (compiler-backend-peephole-owners-clear-extent owners dst-key 8)]
        (if (and
          (>= src-reg 0)
          (not
            (compiler-backend-peephole-owner-key-known?
              (compiler-backend-peephole-owners-get-index cleared src-reg))))
          (compiler-backend-peephole-owners-set-reg-index
            cleared
            src-reg
            (compiler-backend-peephole-owner-key-mark-store dst-key))
          cleared))]
    [(>= dst-reg 0)
      (compiler-backend-peephole-owners-set-reg-index owners dst-reg src-key)]
    [else (compiler-backend-peephole-owners-empty)]))

(define (compiler-backend-peephole-size-suffix-byte? [b : i64]) : bool
  (or (= b 113) (= b 108) (= b 119) (= b 98)))

;; True iff the mnemonic token at `i` is exactly a cmp/test compare (cmp, cmpq,
;; cmpl, cmpw, cmpb, test, testq, testl, testw, testb). These write only the
;; flags, never a GP register or memory, so they need no owner invalidation.
;; cmpxchg, cmps, and similar (which DO write registers/memory) are excluded by
;; the strict token-length / suffix check.
(define (compiler-backend-peephole-cmp-or-test-token?
  [data : (Ptr u8)]
  [i : i64]
  [tlen : i64]) : bool
  (or
    (and
      (>= tlen 3)
      (= (be_state.compiler-backend-peephole-byte-at data i) 99)
      (= (be_state.compiler-backend-peephole-byte-at data (+ i 1)) 109)
      (= (be_state.compiler-backend-peephole-byte-at data (+ i 2)) 112)
      (or
        (= tlen 3)
        (and
          (= tlen 4)
          (compiler-backend-peephole-size-suffix-byte?
            (be_state.compiler-backend-peephole-byte-at data (+ i 3))))))
    (and
      (>= tlen 4)
      (= (be_state.compiler-backend-peephole-byte-at data i) 116)
      (= (be_state.compiler-backend-peephole-byte-at data (+ i 1)) 101)
      (= (be_state.compiler-backend-peephole-byte-at data (+ i 2)) 115)
      (= (be_state.compiler-backend-peephole-byte-at data (+ i 3)) 116)
      (or
        (= tlen 4)
        (and
          (= tlen 5)
          (compiler-backend-peephole-size-suffix-byte?
            (be_state.compiler-backend-peephole-byte-at data (+ i 4))))))))

;; SCAV2: true iff line [start,end) is `call <F>` where F is a runtime NORETURN
;; abort helper (including the location-aware `_at` variants). A noreturn call
;; never returns, so the textual fall-through into
;; the next line is DEAD: the owner map is carried unchanged across it, so the
;; guard-ok continuation label immediately after it (reached ONLY via the guard's
;; own conditional jump, across which the register map is identical) sees the
;; live map from the guard test -- see line-clobber-owners' label arm.
(define (compiler-backend-peephole-line-noreturn-abort?
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : bool
  (let
    [i : i64 start]
    (while (and
      (< i end)
      (= (be_state.compiler-backend-peephole-byte-at data i) 32))
      (+= i 1))
    (let
      [e : i64 end]
      (while (and
        (> e i)
        (= (be_state.compiler-backend-peephole-byte-at data (- e 1)) 32))
        (-= e 1))
      (or
        (compiler-backend-cold-prefix? data i e "call .L_tl_abort_tl_")
        (be_operand.compiler-backend-peephole-range-eq?
          data
          i
          e
          "call tl_oob_abort")
        (be_operand.compiler-backend-peephole-range-eq?
          data
          i
          e
          "call tl_oob_abort_at")
        (be_operand.compiler-backend-peephole-range-eq?
          data
          i
          e
          "call tl_shift_abort")
        (be_operand.compiler-backend-peephole-range-eq?
          data
          i
          e
          "call tl_shift_abort_at")
        (be_operand.compiler-backend-peephole-range-eq?
          data
          i
          e
          "call tl_div_abort")
        (be_operand.compiler-backend-peephole-range-eq?
          data
          i
          e
          "call tl_div_abort_at")
        (be_operand.compiler-backend-peephole-range-eq?
          data
          i
          e
          "call tl_panic_at")
        (be_operand.compiler-backend-peephole-range-eq?
          data
          i
          e
          "call tl_region_abort")
        (be_operand.compiler-backend-peephole-range-eq?
          data
          i
          e
          "call tl_oom_abort")))))

;; True iff `text` holds at least one `call`/`callq` line that RETURNS to this
;; function -- i.e. a call line that is not one of the `never` abort handlers
;; classified by compiler-backend-peephole-line-noreturn-abort?. Tail transfers
;; are `jmp`, not `call`, so they are invisible here by construction, and a bare
;; `syscall` is not a call mnemonic. This is the fact
;; compiler-backend-function-bool-call-align-needed records; its comment carries
;; the alignment argument.
(define (compiler-backend-text-has-returning-call? [text : (& text str)]) : bool
  (let
    [n : i64 (string.string-length text)]
    [data : (Ptr u8)
      (unsafe
        (string-data text))]
    [i : i64 0]
    [found : bool false]
    (while (and (not found) (< i n))
      (let
        [end : i64
          (be_operand.compiler-backend-peephole-scan-byte-range data i n 10)]
        [m : i64 i]
        (while (and
          (< m end)
          (= (be_state.compiler-backend-peephole-byte-at data m) 32))
          (+= m 1))
        (if (and
          (< m end)
          (compiler-backend-peephole-mnemonic-call?
            data
            m
            (-
              (be_operand.compiler-backend-peephole-scan-byte-range
                data
                m
                end
                32)
              m))
          (not (compiler-backend-peephole-line-noreturn-abort? data i end)))
          (set! found true)
          unit)
        (set! i (+ end 1))))
    found))

;; True iff the byte range [start,end) of `data` contains `needle` as a substring.
(define (compiler-backend-peephole-range-contains-substr?
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]
  [needle : String]) : bool
  (let
    [nlen : i64 (string.string-length needle)]
    [nd : (Ptr u8)
      (unsafe
        (string-data needle))]
    [i : i64 start]
    [found : bool false]
    (while (and (not found) (<= (+ i nlen) end))
      (let
        [k : i64 0]
        [ok : bool true]
        (while (and ok (< k nlen))
          (if (=
            (be_state.compiler-backend-peephole-byte-at data (+ i k))
            (be_state.compiler-backend-peephole-byte-at nd k))
            unit
            (set! ok false))
          (+= k 1))
        (if ok
          (set! found true)
          (+= i 1))))
    found))

;; SCAV2: true iff label line [start,end) is a guard-check CONTINUATION label --
;; its name contains "_ok" (`..._bounds_ok.N`, `..._str_bounds_ok.N`,
;; `..._make_array_len_ok.N`, ...) and does NOT contain "_fail". Such labels are
;; backend-emitted per guard and targeted ONLY by that guard's own conditional
;; jump (single live predecessor), so when the map was carried across a preceding
;; noreturn abort it is valid here. Excluding any "_fail" is essential: inlined
;; compound labels like `..._make_array_len_ok.2.8.array_push_fail.4:` are FAIL
;; handlers (last component wins) that happen to carry an "_ok" inline-context
;; prefix; carrying across them would be unsound. Numeric `1:` labels lack "_ok".
;; Only consulted when prev-abort? holds.
(define (compiler-backend-peephole-label-guard-ok?
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : bool
  (and
    (compiler-backend-peephole-range-contains-substr? data start end "_ok")
    (not
      (compiler-backend-peephole-range-contains-substr? data start end "_fail"))))

;; Owner-map transfer for a non-movq line (everything `line-movq` does not parse
;; as a clean two-operand movq). `line-clears-owners?` returns true when the line
;; needs conservative owner invalidation. The line is classified from its raw
;; bytes:
;;  * blank / whitespace-only -> no effect.
;;  * a label (ends in ':') -> a control-flow merge target; arbitrary predecessors
;;    can reach it with different register contents -> clear all.
;;  * an assembler directive (first non-space byte '.') -> no register/memory
;;    effect -> no clear.
;;  * a jump ('j...': jmp/jcc/jrcxz/jecxz) -> writes no register; the fall-through
;;    keeps the current state and every branch target is itself a label that
;;    clears -> no clear.
;;  * cmp / test -> flags only -> no clear.
;;  * everything else (call, ret, leave, syscall, every arithmetic/vector op, any
;;    store through a pointer/index/segment, and any unrecognized mnemonic) may
;;    write a GP register or alias a frame slot -> invalidate conservatively.
;; True iff the mnemonic token is a call instruction (`call` or `callq`).
(define (compiler-backend-peephole-mnemonic-call?
  [data : (Ptr u8)]
  [i : i64]
  [mlen : i64]) : bool
  (and
    (or (= mlen 4) (= mlen 5))
    (= (be_state.compiler-backend-peephole-byte-at data i) 99)
    (= (be_state.compiler-backend-peephole-byte-at data (+ i 1)) 97)
    (= (be_state.compiler-backend-peephole-byte-at data (+ i 2)) 108)
    (= (be_state.compiler-backend-peephole-byte-at data (+ i 3)) 108)
    (or
      (= mlen 4)
      (= (be_state.compiler-backend-peephole-byte-at data (+ i 4)) 113))))

(define (compiler-backend-peephole-register-range?
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : bool
  (and
    (< start end)
    (= (be_state.compiler-backend-peephole-byte-at data start) 37)))

;; One pass over the operand finds "(%rbp)" and "(%rsp)" occurrences (indexed
;; forms place them mid-operand where the end-anchored memory-base probe
;; cannot see them): bit 1 = has "(%rbp)", bit 2 = has "(%rsp)". Replaces up
;; to three separate substring searches per operand with the same existence
;; answers. Jumps between '(' bytes a word at a time instead of stepping every
;; byte (the same form compiler-backend-rsp-rebase-find-rbp uses). The absent
;; answer `end` fails the six-byte room test, so it needs no separate arm.
(define (compiler-backend-peephole-stack-parens-range
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : i64
  (let
    [i : i64 start]
    [bits : i64 0]
    [done : bool false]
    (while (and (not done) (< bits 3) (<= (+ i 6) end))
      (let
        [pos : i64
          (be_operand.compiler-backend-peephole-scan-byte-range data i end 40)]
        (if (> (+ pos 6) end)
          (set! done true)
          (begin
            (if (and
              (= (be_state.compiler-backend-peephole-byte-at data (+ pos 1)) 37)
              (=
                (be_state.compiler-backend-peephole-byte-at data (+ pos 2))
                114)
              (=
                (be_state.compiler-backend-peephole-byte-at data (+ pos 4))
                112)
              (= (be_state.compiler-backend-peephole-byte-at data (+ pos 5)) 41))
              (let
                [b3 : i64
                  (be_state.compiler-backend-peephole-byte-at data (+ pos 3))]
                (cond
                  [(= b3 98) (set! bits (bit-or bits 1))]
                  [(= b3 115) (set! bits (bit-or bits 2))]
                  [else unit]))
              unit)
            (set! i (+ pos 1))))))
    bits))

(define compiler-backend-peephole-op-register-flag : i64
  1)
(define compiler-backend-peephole-op-stack-flag : i64
  2)
(define compiler-backend-peephole-op-local-frame-flag : i64
  4)
(define compiler-backend-peephole-op-r10-base-flag : i64
  8)

(define (compiler-backend-peephole-operand-flags
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]
  [key : i64]
  [memory-base : i64]) : i64
  ;; Treat the already classified operand kind as a dispatch. Registers and
  ;; canonical stack keys dominate generated movq operands; neither needs the
  ;; general parenthetical scan or the predicates for unrelated kinds.
  (cond
    [(compiler-backend-peephole-register-range? data start end)
      compiler-backend-peephole-op-register-flag]
    [(compiler-backend-peephole-owner-key-stack? key)
      (bit-or
        compiler-backend-peephole-op-stack-flag
        (if (or
          (not (= (bit-and (- key 1) 2) 0))
          (= (be_state.compiler-backend-peephole-byte-at data start) 45))
          compiler-backend-peephole-op-local-frame-flag
          0))]
    [(= memory-base compiler-backend-peephole-memory-base-rsp)
      (bit-or
        compiler-backend-peephole-op-stack-flag
        compiler-backend-peephole-op-local-frame-flag)]
    [else
      (let
        [base-rbp? : bool
          (= memory-base compiler-backend-peephole-memory-base-rbp)]
        [leading-minus? : bool
          (and
            (< start end)
            (= (be_state.compiler-backend-peephole-byte-at data start) 45))]
        ;; This is the general stack probe plus the rbp-base arm's
        ;; additional "(%rsp)" check. Earlier arms proved there is no packed
        ;; key and no end-anchored rsp base.
        [parens : i64
          (if (or base-rbp? (>= (- end start) 6))
            (compiler-backend-peephole-stack-parens-range data start end)
            0)]
        [stack? : bool (or base-rbp? (not (= parens 0)))]
        [local-frame? : bool
          (if base-rbp?
            (or leading-minus? (not (= (bit-and parens 2) 0)))
            (and
              stack?
              (or
                (not (= (bit-and parens 2) 0))
                (and leading-minus? (not (= (bit-and parens 1) 0))))))]
        (bit-or
          (if stack?
            compiler-backend-peephole-op-stack-flag
            0)
          (bit-or
            (if local-frame?
              compiler-backend-peephole-op-local-frame-flag
              0)
            (if (= memory-base compiler-backend-peephole-memory-base-r10)
              compiler-backend-peephole-op-r10-base-flag
              0))))]))

(define (compiler-backend-peephole-op-flag? [flags : i64] [flag : i64]) : bool
  (not (= (bit-and flags flag) 0)))

;; SCAV3: the 64-bit parent of a 32/16/8-bit sub-register token [ts,te), or ""
;; if it is not a sub-register of one of the 14 owner-tracked GP registers. A
;; write to a sub-register (movl/xorl/movb/setcc dest) changes the full parent
;; register's value (32-bit forms zero-extend; 8/16-bit forms overwrite low
;; bytes), so the parent's slot mirror must be dropped -- returning the parent
;; here lets `last-operand-reg` clear exactly that register instead of forcing a
;; whole-map clear. %rbp/%rsp sub-registers (%ebp/%esp/%bp/%sp/%bpl/%spl) are
;; DELIBERATELY unmapped -> "" -> whole-map clear, preserving the frame/stack
;; pointer invalidation invariant (owner-reg? already excludes %rbp/%rsp).
;; Dense owner-register index for a full or partial GP register token. The
;; token grammar is a fixed set, so classify its 3--5 bytes once instead of
;; walking 56 literal comparisons. Partial-register writes map to their 64-bit
;; owner; rbp/rsp and their partial forms remain deliberately untracked.
(define (compiler-backend-peephole-token-reg-index-range
  [data : (Ptr u8)]
  [ts : i64]
  [te : i64]) : i64
  (let
    [n : i64 (- te ts)]
    (if (or
      (< n 3)
      (> n 5)
      (not (= (be_state.compiler-backend-peephole-byte-at data ts) 37)))
      -1
      (let
        [b1 : i64 (be_state.compiler-backend-peephole-byte-at data (+ ts 1))]
        [b2 : i64 (be_state.compiler-backend-peephole-byte-at data (+ ts 2))]
        (cond
          [(= n 3)
            (cond
              [(= b1 114) (cond [(= b2 56) 6] [(= b2 57) 7] [else -1])]
              [(= b1 97)
                (if (or (= b2 120) (= b2 108))
                  0
                  -1)]
              [(= b1 99)
                (if (or (= b2 120) (= b2 108))
                  1
                  -1)]
              [(= b1 100)
                (cond [(or (= b2 120) (= b2 108)) 2] [(= b2 105) 5] [else -1])]
              [(= b1 98)
                (if (or (= b2 120) (= b2 108))
                  3
                  -1)]
              [(= b1 115)
                (if (= b2 105)
                  4
                  -1)]
              [else -1])]
          [(= n 4)
            (let
              [b3 : i64
                (be_state.compiler-backend-peephole-byte-at data (+ ts 3))]
              (cond
                [(= b1 114)
                  (cond
                    [(= b2 97)
                      (if (= b3 120)
                        0
                        -1)]
                    [(= b2 99)
                      (if (= b3 120)
                        1
                        -1)]
                    [(= b2 100) (cond [(= b3 120) 2] [(= b3 105) 5] [else -1])]
                    [(= b2 98)
                      (if (= b3 120)
                        3
                        -1)]
                    [(= b2 115)
                      (if (= b3 105)
                        4
                        -1)]
                    [(= b2 56)
                      (if (or (= b3 100) (= b3 119) (= b3 98))
                        6
                        -1)]
                    [(= b2 57)
                      (if (or (= b3 100) (= b3 119) (= b3 98))
                        7
                        -1)]
                    [(= b2 49)
                      (cond
                        [(= b3 48) 8]
                        [(= b3 49) 9]
                        [(= b3 50) 10]
                        [(= b3 51) 11]
                        [(= b3 52) 12]
                        [(= b3 53) 13]
                        [else -1])]
                    [else -1])]
                [(= b1 101)
                  (cond
                    [(= b2 97)
                      (if (= b3 120)
                        0
                        -1)]
                    [(= b2 99)
                      (if (= b3 120)
                        1
                        -1)]
                    [(= b2 100) (cond [(= b3 120) 2] [(= b3 105) 5] [else -1])]
                    [(= b2 98)
                      (if (= b3 120)
                        3
                        -1)]
                    [(= b2 115)
                      (if (= b3 105)
                        4
                        -1)]
                    [else -1])]
                [(and (= b1 115) (= b2 105) (= b3 108)) 4]
                [(and (= b1 100) (= b2 105) (= b3 108)) 5]
                [else -1]))]
          [else
            (let
              [b3 : i64
                (be_state.compiler-backend-peephole-byte-at data (+ ts 3))]
              [b4 : i64
                (be_state.compiler-backend-peephole-byte-at data (+ ts 4))]
              (if (and
                (= b1 114)
                (= b2 49)
                (or (= b4 100) (= b4 119) (= b4 98)))
                (cond
                  [(= b3 48) 8]
                  [(= b3 49) 9]
                  [(= b3 50) 10]
                  [(= b3 51) 11]
                  [(= b3 52) 12]
                  [(= b3 53) 13]
                  [else -1])
                -1))])))))

;; The single tracked GP register that is the LAST operand of the line [start,end),
;; or "" if the last operand is not a simple tracked register (memory, immediate,
;; xmm, or an untracked reg). Used to invalidate exactly the register a single-dest
;; instruction writes. A memory last operand ends in ')' so the backward reg-token
;; scan yields an empty token -> "".
(define (compiler-backend-peephole-last-operand-reg-index
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : i64
  (let
    [te : i64 end]
    (while (and
      (> te start)
      (= (be_state.compiler-backend-peephole-byte-at data (- te 1)) 32))
      (-= te 1))
    (let
      [ts : i64 te]
      (while (and
        (> ts start)
        (let
          [b : i64 (be_state.compiler-backend-peephole-byte-at data (- ts 1))]
          (or (= b 37) (and (>= b 97) (<= b 122)) (and (>= b 48) (<= b 57)))))
        (-= ts 1))
      (if (and
        (< ts te)
        (= (be_state.compiler-backend-peephole-byte-at data ts) 37)
        (or
          (= ts start)
          (let
            [pb : i64
              (be_state.compiler-backend-peephole-byte-at data (- ts 1))]
            (or (= pb 32) (= pb 44) (= pb 9)))))
        (compiler-backend-peephole-token-reg-index-range data ts te)
        -1))))

;; AVX instructions with a vector-register destination do not change any GP
;; register or memory slot tracked by the reload-elision owner map. Preserve
;; those owners across the instruction so one spilled scalar address index can
;; be loaded once and reused by an adjacent vector load/binop sequence. A GP
;; destination (for example `vpmovmskb ..., %r8`) or a memory destination stays
;; on the conservative clobber path.
(define (compiler-backend-peephole-vector-preserves-gp-owners?
  [data : (Ptr u8)]
  [mnemonic-start : i64]
  [mnemonic-len : i64]
  [start : i64]
  [end : i64]) : bool
  (if (or
    (= mnemonic-len 0)
    (not
      (= (be_state.compiler-backend-peephole-byte-at data mnemonic-start) 118)))
    false
    (let
      [last-comma : i64 -1]
      [paren-depth : i64 0]
      (for [index (iterator.range start end)]
        (let
          [byte : i64 (be_state.compiler-backend-peephole-byte-at data index)]
          (cond
            [(= byte 40) (+= paren-depth 1)]
            [(= byte 41) (-= paren-depth 1)]
            [(and (= byte 44) (= paren-depth 0)) (set! last-comma index)]
            [else unit])))
      (let
        [dest-start : i64
          (if (< last-comma 0)
            (+ mnemonic-start mnemonic-len)
            (+ last-comma 1))]
        [cursor : i64 dest-start]
        [memory-dest : bool false]
        (while (and (not memory-dest) (< cursor end))
          (if (= (be_state.compiler-backend-peephole-byte-at data cursor) 40)
            (set! memory-dest true)
            unit)
          (+= cursor 1))
        (and
          (not memory-dest)
          (<
            (compiler-backend-peephole-last-operand-reg-index data start end)
            0))))))

;; True iff the mnemonic token [i,i+mlen) is an instruction whose ONLY written GP
;; register is its last operand (so invalidating just that register is sound):
;; the fixed q/l/w/b base set, the movabsq imm->reg load, any set<cc> (8-bit
;; dest), or one of the five widening moves. Classify the token from its length
;; and bytes once: this runs for every non-movq assembly line, and the former
;; chain re-entered the generic range/string comparator up to twenty times.
;; Excludes multi-writers (imul/mul/div/cqo/call/xchg); plain movq remains on the
;; dedicated move-transfer path and is deliberately not classified here.
(define (compiler-backend-peephole-mnemonic-single-dest?
  [data : (Ptr u8)]
  [i : i64]
  [mlen : i64]) : bool
  (if (< mlen 3)
    false
    (let
      [b0 : i64 (be_state.compiler-backend-peephole-byte-at data i)]
      [b1 : i64 (be_state.compiler-backend-peephole-byte-at data (+ i 1))]
      [b2 : i64 (be_state.compiler-backend-peephole-byte-at data (+ i 2))]
      [base3 : i64 (+ b0 (+ (* b1 256) (* b2 65536)))]
      (cond
        ;; set<cc>: preserve the existing prefix classification.
        [(and (= b0 115) (= b1 101) (= b2 116)) true]
        ;; movabsq
        [(= mlen 7)
          (and
            (= base3 7761773)
            (= (be_state.compiler-backend-peephole-byte-at data (+ i 3)) 97)
            (= (be_state.compiler-backend-peephole-byte-at data (+ i 4)) 98)
            (= (be_state.compiler-backend-peephole-byte-at data (+ i 5)) 115)
            (= (be_state.compiler-backend-peephole-byte-at data (+ i 6)) 113))]
        ;; Byte/word zero-extension can write either GP width.
        [(= mlen 6)
          (let
            [kind : i64
              (be_state.compiler-backend-peephole-byte-at data (+ i 3))]
            [width : i64
              (be_state.compiler-backend-peephole-byte-at data (+ i 4))]
            [suffix : i64
              (be_state.compiler-backend-peephole-byte-at data (+ i 5))]
            (and
              (= base3 7761773)
              (or
                (and
                  (= kind 122)
                  (or (= suffix 113) (= suffix 108))
                  (or (= width 98) (= width 119)))
                (and
                  (= kind 115)
                  (= suffix 113)
                  (or (= width 98) (= width 119) (= width 108))))))]
        [else
          (let
            [suffix : i64
              (be_state.compiler-backend-peephole-byte-at data (+ i (- mlen 1)))]
            [width-suffix? : bool
              (or (= suffix 113) (= suffix 108) (= suffix 119) (= suffix 98))]
            (and
              width-suffix?
              (or
                ;; or{q,l,w,b}
                (and (= mlen 3) (= b0 111) (= b1 114))
                (and
                  (= mlen 4)
                  ;; mov{l,w,b}; movq stays on the dedicated move path. leaq
                  ;; is the most common mlen-4 mnemonic, so test it first.
                  (or
                    (= base3 6382956)
                    (and (not (= suffix 113)) (= base3 7761773))
                    (= base3 6579297)
                    (= base3 6452595)
                    (= base3 6581857)
                    (= base3 7499640)
                    (= base3 7104627)
                    (= base3 7497843)
                    (= base3 7496051)
                    (= base3 7102835)
                    (= base3 6776174)
                    (= base3 7630702)
                    (= base3 6516329)
                    (= base3 6514020))))))]))))

(define (compiler-backend-peephole-range-mentions-r10-data?
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : bool
  (let
    [i : i64 start]
    [found : bool false]
    (while (and (not found) (<= (+ i 4) end))
      (if (and
        (= (be_state.compiler-backend-peephole-byte-at data i) 37)
        (= (be_state.compiler-backend-peephole-byte-at data (+ i 1)) 114)
        (= (be_state.compiler-backend-peephole-byte-at data (+ i 2)) 49)
        (= (be_state.compiler-backend-peephole-byte-at data (+ i 3)) 48))
        (set! found true)
        (+= i 1)))
    found))

;; P22-A2: true iff the operand range [start,end) READS the tracked GP register
;; whose dense owner index is `reg`. Every register mention in an AT&T operand
;; starts with '%', so scan '%'-prefixed tokens and classify each through the
;; same table the owner map uses; sub-register spellings (%r9d/%r9w/%r9b/%eax)
;; map to their 64-bit parent, so a partial read still counts. Memory operands
;; (`8(%rax,%r9,4)`) are covered because their base/index tokens are '%'-
;; prefixed too, and untracked tokens (%rbp/%rsp/%xmmN/%rip) classify to -1 and
;; never match a tracked `reg` >= 0.
(define (compiler-backend-peephole-range-mentions-reg-index?
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]
  [reg : i64]) : bool
  (if (< reg 0)
    false
    (let
      [i : i64 start]
      [found : bool false]
      (while (and (not found) (< i end))
        (if (= (be_state.compiler-backend-peephole-byte-at data i) 37)
          (let
            [j : i64 (+ i 1)]
            (while (and
              (< j end)
              (let
                [b : i64 (be_state.compiler-backend-peephole-byte-at data j)]
                (or (and (>= b 97) (<= b 122)) (and (>= b 48) (<= b 57)))))
              (+= j 1))
            (if (=
              (compiler-backend-peephole-token-reg-index-range data i j)
              reg)
              (set! found true)
              unit)
            (set! i j))
          (+= i 1)))
      found)))

;; ---- transient line descriptor packing -------------------------------------
;; Low/high halves of the `span` and `mnemonic` words.
(define compiler-backend-peephole-desc-pack-shift : i64
  32)
(define compiler-backend-peephole-desc-pack-mask : i64
  4294967295)

;; One bit per line predicate in `flags`.
(define compiler-backend-peephole-desc-flag-newline : i64
  1)
(define compiler-backend-peephole-desc-flag-owned : i64
  2)
(define compiler-backend-peephole-desc-flag-movq : i64
  4)
(define compiler-backend-peephole-desc-flag-label : i64
  8)
(define compiler-backend-peephole-desc-flag-noreturn-abort : i64
  16)
(define compiler-backend-peephole-desc-flag-clears-owners : i64
  32)
(define compiler-backend-peephole-desc-flag-call : i64
  64)
(define compiler-backend-peephole-desc-flag-single-dest : i64
  128)
(define compiler-backend-peephole-desc-flag-zext : i64
  256)
(define compiler-backend-peephole-desc-flag-has-operands : i64
  512)

;; `op-flags` holds the 4-bit operand flag sets side by side.
(define compiler-backend-peephole-desc-op-flags-mask : i64
  15)
(define compiler-backend-peephole-desc-op-flags-dst-shift : i64
  4)

;; `regs` holds three 1-biased register indices (-1 becomes 0).
(define compiler-backend-peephole-desc-reg-mask : i64
  255)
(define compiler-backend-peephole-desc-reg-dst-shift : i64
  8)
(define compiler-backend-peephole-desc-reg-last-shift : i64
  16)

(define (compiler-backend-peephole-desc-start
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : i64
  (bit-and line.span compiler-backend-peephole-desc-pack-mask))

(define (compiler-backend-peephole-desc-end
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : i64
  (bit-and
    (shr line.span compiler-backend-peephole-desc-pack-shift)
    compiler-backend-peephole-desc-pack-mask))

(define (compiler-backend-peephole-desc-mnemonic-start
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : i64
  (bit-and line.mnemonic compiler-backend-peephole-desc-pack-mask))

(define (compiler-backend-peephole-desc-mnemonic-len
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : i64
  (bit-and
    (shr line.mnemonic compiler-backend-peephole-desc-pack-shift)
    compiler-backend-peephole-desc-pack-mask))

(define (compiler-backend-peephole-desc-newline?
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : bool
  (not (= (bit-and line.flags compiler-backend-peephole-desc-flag-newline) 0)))

(define (compiler-backend-peephole-desc-owned?
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : bool
  (not (= (bit-and line.flags compiler-backend-peephole-desc-flag-owned) 0)))

(define (compiler-backend-peephole-desc-movq?
  [line : be_state.CompilerBackendPeepholeLine]) : bool
  (not (= (bit-and line.flags compiler-backend-peephole-desc-flag-movq) 0)))

(define (compiler-backend-peephole-desc-label?
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : bool
  (not (= (bit-and line.flags compiler-backend-peephole-desc-flag-label) 0)))

(define (compiler-backend-peephole-desc-noreturn-abort?
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : bool
  (not
    (=
      (bit-and line.flags compiler-backend-peephole-desc-flag-noreturn-abort)
      0)))

(define (compiler-backend-peephole-desc-clears-owners?
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : bool
  (not
    (= (bit-and line.flags compiler-backend-peephole-desc-flag-clears-owners) 0)))

(define (compiler-backend-peephole-desc-call?
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : bool
  (not (= (bit-and line.flags compiler-backend-peephole-desc-flag-call) 0)))

(define (compiler-backend-peephole-desc-single-dest?
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : bool
  (not
    (= (bit-and line.flags compiler-backend-peephole-desc-flag-single-dest) 0)))

;; A generated guard branches over its cold abort preparation to an `_ok`
;; continuation. Remember the owner map at that branch so extra value/site
;; argument setup on the dead textual path cannot force reloads on the real
;; success path.
(define (compiler-backend-peephole-desc-guard-ok-branch?
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : bool
  (let
    [data : (Ptr u8) line.data]
    [start : i64 (compiler-backend-peephole-desc-start line)]
    [end : i64 (compiler-backend-peephole-desc-end line)]
    [ms : i64 (compiler-backend-peephole-desc-mnemonic-start line)]
    [mlen : i64 (compiler-backend-peephole-desc-mnemonic-len line)]
    (and
      (> mlen 1)
      (= (be_state.compiler-backend-peephole-byte-at data ms) 106)
      (not
        (be_operand.compiler-backend-peephole-range-eq?
          data
          ms
          (+ ms mlen)
          "jmp"))
      (compiler-backend-peephole-range-contains-substr? data start end "_ok")
      (not
        (compiler-backend-peephole-range-contains-substr?
          data
          start
          end
          "_fail")))))

(define (compiler-backend-peephole-desc-guard-ok-label?
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : bool
  (and
    (compiler-backend-peephole-desc-label? line)
    (compiler-backend-peephole-label-guard-ok?
      line.data
      (compiler-backend-peephole-desc-start line)
      (compiler-backend-peephole-desc-end line))))

(define (compiler-backend-peephole-desc-pushq?
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : bool
  (let
    [data : (Ptr u8) line.data]
    [ms : i64 (compiler-backend-peephole-desc-mnemonic-start line)]
    [mlen : i64 (compiler-backend-peephole-desc-mnemonic-len line)]
    (and
      (= mlen 5)
      (= (be_state.compiler-backend-peephole-byte-at data ms) 112)
      (= (be_state.compiler-backend-peephole-byte-at data (+ ms 1)) 117)
      (= (be_state.compiler-backend-peephole-byte-at data (+ ms 2)) 115)
      (= (be_state.compiler-backend-peephole-byte-at data (+ ms 3)) 104)
      (= (be_state.compiler-backend-peephole-byte-at data (+ ms 4)) 113))))

(define (compiler-backend-peephole-desc-has-operands?
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : bool
  (not
    (= (bit-and line.flags compiler-backend-peephole-desc-flag-has-operands) 0)))

(define (compiler-backend-peephole-desc-op-src-start
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : i64
  line.op-src-start)

(define (compiler-backend-peephole-desc-op-src-end
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : i64
  line.op-src-end)

(define (compiler-backend-peephole-desc-op-dst-start
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : i64
  line.op-dst-start)

;; The destination operand always runs to the end of the line.
(define (compiler-backend-peephole-desc-op-dst-end
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : i64
  (bit-and
    (shr line.span compiler-backend-peephole-desc-pack-shift)
    compiler-backend-peephole-desc-pack-mask))

(define (compiler-backend-peephole-desc-op-src-flags
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : i64
  (bit-and line.op-flags compiler-backend-peephole-desc-op-flags-mask))

(define (compiler-backend-peephole-desc-op-dst-flags
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : i64
  (bit-and
    (shr line.op-flags compiler-backend-peephole-desc-op-flags-dst-shift)
    compiler-backend-peephole-desc-op-flags-mask))

(define (compiler-backend-peephole-desc-op-src-reg
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : i64
  (- (bit-and line.regs compiler-backend-peephole-desc-reg-mask) 1))

(define (compiler-backend-peephole-desc-op-dst-reg
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : i64
  (-
    (bit-and
      (shr line.regs compiler-backend-peephole-desc-reg-dst-shift)
      compiler-backend-peephole-desc-reg-mask)
    1))

(define (compiler-backend-peephole-desc-last-reg
  [line : be_state.CompilerBackendPeepholeLine]) : i64
  (-
    (bit-and
      (shr line.regs compiler-backend-peephole-desc-reg-last-shift)
      compiler-backend-peephole-desc-reg-mask)
    1))

;; The zext pair rule reads the widening move's destination register; it is the
;; last-operand register of a `movzb{q,l}` line and "none" everywhere else.
(define (compiler-backend-peephole-desc-zext-dst
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : i64
  (if (= (bit-and line.flags compiler-backend-peephole-desc-flag-zext) 0)
    -1
    (-
      (bit-and
        (shr line.regs compiler-backend-peephole-desc-reg-last-shift)
        compiler-backend-peephole-desc-reg-mask)
      1)))

(define (compiler-backend-peephole-line-mnemonic-eq?
  [line : (& line be_state.CompilerBackendPeepholeLine)]
  [name : String]) : bool
  (let
    [ms : i64 (compiler-backend-peephole-desc-mnemonic-start line)]
    (be_operand.compiler-backend-peephole-range-eq?
      line.data
      ms
      (+ ms (compiler-backend-peephole-desc-mnemonic-len line))
      name)))

(define (compiler-backend-peephole-line-text
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : String
  (let
    [start : i64 (compiler-backend-peephole-desc-start line)]
    (string.substring
      line.src
      start
      (- (compiler-backend-peephole-desc-end line) start))))

(define (compiler-backend-peephole-line-op-src-text
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : String
  (let
    [start : i64 (compiler-backend-peephole-desc-op-src-start line)]
    (string.substring
      line.src
      start
      (- (compiler-backend-peephole-desc-op-src-end line) start))))

(define (compiler-backend-peephole-line-op-dst-text
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : String
  (let
    [start : i64 (compiler-backend-peephole-desc-op-dst-start line)]
    (string.substring
      line.src
      start
      (- (compiler-backend-peephole-desc-op-dst-end line) start))))

(define (compiler-backend-peephole-mnemonic-zext?
  [data : (Ptr u8)]
  [i : i64]
  [mlen : i64]) : bool
  (and
    (= mlen 6)
    (= (be_state.compiler-backend-peephole-byte-at data i) 109)
    (= (be_state.compiler-backend-peephole-byte-at data (+ i 1)) 111)
    (= (be_state.compiler-backend-peephole-byte-at data (+ i 2)) 118)
    (= (be_state.compiler-backend-peephole-byte-at data (+ i 3)) 122)
    (= (be_state.compiler-backend-peephole-byte-at data (+ i 4)) 98)
    (let
      [suffix : i64 (be_state.compiler-backend-peephole-byte-at data (+ i 5))]
      (or (= suffix 113) (= suffix 108)))))

(define (compiler-backend-peephole-parse-line
  [context : be_state.CompilerBackendPeepholeParseContext]
  [src : String]
  [start : i64]
  [end : i64]
  [newline : bool]
  [owned : bool]) : be_state.CompilerBackendPeepholeLine
  (let
    [data : (Ptr u8) context.data]
    [ms : i64 start]
    (if (and
      (< (+ start 4) end)
      (= (be_state.compiler-backend-peephole-byte-at data start) 32)
      (= (be_state.compiler-backend-peephole-byte-at data (+ start 1)) 32)
      (= (be_state.compiler-backend-peephole-byte-at data (+ start 2)) 32)
      (= (be_state.compiler-backend-peephole-byte-at data (+ start 3)) 32)
      (not (= (be_state.compiler-backend-peephole-byte-at data (+ start 4)) 32)))
      (set! ms (+ start 4))
      (while (and
        (< ms end)
        (= (be_state.compiler-backend-peephole-byte-at data ms) 32))
        (+= ms 1)))
    (let
      [mlen : i64
        (if (and
          (< (+ ms 4) end)
          (= (be_state.compiler-backend-peephole-byte-at data (+ ms 4)) 32))
          4
          (-
            (be_operand.compiler-backend-peephole-scan-byte-range
              data
              ms
              end
              32)
            ms))]
      [operand-start : i64 (+ ms mlen)]
      [has-operands : bool false]
      [comma : i64 -1]
      [mnemonic-first : i64
        (if (< ms end)
          (be_state.compiler-backend-peephole-byte-at data ms)
          0)]
      [movq-prefix?
        : bool
        ;; Derive from facts already in hand: ms is the first non-space
        ;; byte, so ms=start+4 iff exactly four leading spaces; mlen=4 with
        ;; ms+4<end iff memchr found ' ' at exactly ms+4. With the four
        ;; mnemonic bytes this is exactly "    movq ".
        (and
          (= mlen 4)
          (= ms (+ start 4))
          (< (+ ms 4) end)
          (= mnemonic-first 109)
          (= (be_state.compiler-backend-peephole-byte-at data (+ ms 1)) 111)
          (= (be_state.compiler-backend-peephole-byte-at data (+ ms 2)) 118)
          (= (be_state.compiler-backend-peephole-byte-at data (+ ms 3)) 113))]
      [zext? : bool
        (and
          (= mlen 6)
          (= mnemonic-first 109)
          (compiler-backend-peephole-mnemonic-zext? data ms mlen))]
      ;; Only move/zext pair rules consume split operands. Most assembly
      ;; lines need just their mnemonic classification, so do not rescan
      ;; their full text looking for a comma that no rule will read.
      (when
        (or movq-prefix? zext?)
        ;; token-len already proved byte[operand-start] is a space when
        ;; operand-start<end, so the first skip iteration is free.
        (if (< operand-start end)
          (+= operand-start 1)
          unit)
        (while (and
          (< operand-start end)
          (= (be_state.compiler-backend-peephole-byte-at data operand-start) 32))
          (+= operand-start 1))
        (set!
          comma
          (compiler-backend-peephole-find-comma-space-range
            data
            operand-start
            end))
        (if (and (> comma operand-start) (< (+ comma 2) end))
          (set! has-operands true)
          unit))
      (let
        [is-movq : bool (and has-operands movq-prefix?)]
        [op-src-start : i64 operand-start]
        [op-src-end : i64
          (if has-operands
            comma
            operand-start)]
        [op-dst-start : i64
          (if has-operands
            (+ comma 2)
            end)]
        [op-dst-end : i64 end]
        [is-label : bool
          (and
            (< ms end)
            (= (be_state.compiler-backend-peephole-byte-at data (- end 1)) 58))]
        [cmp-or-test? : bool
          (and
            (or (= mnemonic-first 99) (= mnemonic-first 116))
            (compiler-backend-peephole-cmp-or-test-token? data ms mlen))]
        [clears : bool
          (cond
            [(>= ms end) false]
            [is-label true]
            [(= mnemonic-first 46) false]
            [(= mnemonic-first 106) false]
            ;; A movq line fails cmp-or-test ('m' is not 'c'/'t') and
            ;; vector-preserves ('m' is not 'v'), so it clears.
            [movq-prefix? true]
            [cmp-or-test? false]
            [(and
                (= mnemonic-first 118)
                (compiler-backend-peephole-vector-preserves-gp-owners?
                  data
                  ms
                  mlen
                  start
                  end))
              false]
            [else true])]
        [call? : bool
          (and
            (= mnemonic-first 99)
            (compiler-backend-peephole-mnemonic-call? data ms mlen))]
        [single-dest?
          : bool
          ;; The clobber transfer handles moves, labels, non-clobbering
          ;; directives/branches, and calls before consulting this field.
          (and
            (not is-movq)
            (not is-label)
            clears
            (not call?)
            (compiler-backend-peephole-mnemonic-single-dest? data ms mlen))]
        [last-reg : i64
          (if (or single-dest? zext?)
            (compiler-backend-peephole-last-operand-reg-index data start end)
            -1)]
        ;; A pure register token cannot produce a memory owner key. Keep a
        ;; trailing-')' spelling on the general path so even unusual input
        ;; that begins with '%' keeps the memory-suffix behavior.
        [src-register? : bool
          (and
            is-movq
            (< op-src-start op-src-end)
            (=
              (be_state.compiler-backend-peephole-byte-at data op-src-start)
              37)
            (not
              (=
                (be_state.compiler-backend-peephole-byte-at
                  data
                  (- op-src-end 1))
                41)))]
        [dst-register? : bool
          (and
            is-movq
            (< op-dst-start op-dst-end)
            (=
              (be_state.compiler-backend-peephole-byte-at data op-dst-start)
              37)
            (not
              (=
                (be_state.compiler-backend-peephole-byte-at
                  data
                  (- op-dst-end 1))
                41)))]
        [src-memory-base : i64
          (if (and is-movq (not src-register?))
            (compiler-backend-peephole-memory-base-range
              data
              op-src-start
              op-src-end)
            compiler-backend-peephole-memory-base-none)]
        [dst-memory-base : i64
          (if (and is-movq (not dst-register?))
            (compiler-backend-peephole-memory-base-range
              data
              op-dst-start
              op-dst-end)
            compiler-backend-peephole-memory-base-none)]
        [src-key : i64
          (if (and is-movq (not src-register?))
            (compiler-backend-peephole-owner-key-from-range
              context
              op-src-start
              op-src-end
              src-memory-base)
            (compiler-backend-peephole-owner-key-unknown))]
        [dst-key : i64
          (if (and is-movq (not dst-register?))
            (compiler-backend-peephole-owner-key-from-range
              context
              op-dst-start
              op-dst-end
              dst-memory-base)
            (compiler-backend-peephole-owner-key-unknown))]
        [src-reg : i64
          (if src-register?
            (compiler-backend-peephole-reg-index-range
              data
              op-src-start
              op-src-end)
            -1)]
        [dst-reg : i64
          (if dst-register?
            (compiler-backend-peephole-reg-index-range
              data
              op-dst-start
              op-dst-end)
            -1)]
        [src-flags : i64
          (cond
            [src-register? compiler-backend-peephole-op-register-flag]
            [is-movq
              (compiler-backend-peephole-operand-flags
                data
                op-src-start
                op-src-end
                src-key
                src-memory-base)]
            [else 0])]
        [dst-flags : i64
          (cond
            [dst-register? compiler-backend-peephole-op-register-flag]
            [is-movq
              (compiler-backend-peephole-operand-flags
                data
                op-dst-start
                op-dst-end
                dst-key
                dst-memory-base)]
            [else 0])]
        (be_state.CompilerBackendPeepholeLine
          src
          data
          (bit-or start (shl end compiler-backend-peephole-desc-pack-shift))
          (bit-or ms (shl mlen compiler-backend-peephole-desc-pack-shift))
          (bit-or
            (bit-or
              (if newline
                compiler-backend-peephole-desc-flag-newline
                0)
              (bit-or
                (if owned
                  compiler-backend-peephole-desc-flag-owned
                  0)
                (if is-movq
                  compiler-backend-peephole-desc-flag-movq
                  0)))
            (bit-or
              (bit-or
                (if is-label
                  compiler-backend-peephole-desc-flag-label
                  0)
                (if (and
                  call?
                  (compiler-backend-peephole-line-noreturn-abort? data ms end))
                  compiler-backend-peephole-desc-flag-noreturn-abort
                  0))
              (bit-or
                (bit-or
                  (if clears
                    compiler-backend-peephole-desc-flag-clears-owners
                    0)
                  (if call?
                    compiler-backend-peephole-desc-flag-call
                    0))
                (bit-or
                  (if single-dest?
                    compiler-backend-peephole-desc-flag-single-dest
                    0)
                  (bit-or
                    (if zext?
                      compiler-backend-peephole-desc-flag-zext
                      0)
                    (if has-operands
                      compiler-backend-peephole-desc-flag-has-operands
                      0))))))
          op-src-start
          op-src-end
          op-dst-start
          src-key
          dst-key
          (bit-or
            src-flags
            (shl dst-flags compiler-backend-peephole-desc-op-flags-dst-shift))
          (bit-or
            (+ src-reg 1)
            (bit-or
              (shl (+ dst-reg 1) compiler-backend-peephole-desc-reg-dst-shift)
              (shl (+ last-reg 1) compiler-backend-peephole-desc-reg-last-shift))))))))

(define (compiler-backend-peephole-owned-line
  [backend-state : be_state.CompilerBackendState]
  [stream : be_state.CompilerBackendStreamState]
  [line : String]
  [newline : bool]) : be_state.CompilerBackendPeepholeLine
  (let
    [context : be_state.CompilerBackendPeepholeParseContext
      (be_state.CompilerBackendPeepholeParseContext
        backend-state.address
        stream.address
        (unsafe
          (string-data line)))]
    (compiler-backend-peephole-parse-line
      context
      (be_state.compiler-backend-global-shared-view line)
      0
      (string.string-length line)
      newline
      true)))

(define (compiler-backend-peephole-empty-line) : be_state.CompilerBackendPeepholeLine
  (be_state.CompilerBackendPeepholeLine
    ""
    (unsafe
      (string-data ""))
    0
    0
    0
    0
    0
    0
    0
    0
    0
    0))

(define (compiler-backend-peephole-line-copy
  [line : be_state.CompilerBackendPeepholeLine]) : be_state.CompilerBackendPeepholeLine
  (be_state.CompilerBackendPeepholeLine
    line.src
    line.data
    line.span
    line.mnemonic
    line.flags
    line.op-src-start
    line.op-src-end
    line.op-dst-start
    line.op-src-key
    line.op-dst-key
    line.op-flags
    line.regs))

;; ---- compact line-record packing -------------------------------------------
;; `span` holds start in the low 32 bits and end in the high 32. Assembly group
;; strings (and the whole-program text of the non-streaming path) are orders of
;; magnitude below 2^31 bytes, and both halves stay non-negative, so the shifts
;; never touch the sign bit.
(define compiler-backend-peephole-record-span-shift : i64
  32)
(define compiler-backend-peephole-record-span-mask : i64
  4294967295)

;; `meta` low half: sweep line kind, the 13 sweep line flags in their own bit
;; values, the two render bits, the sweep boundary bit and the access
;; width. High half: the count of `(%rsp)` memory references, which is bounded
;; by the line length and so always fits.
(define compiler-backend-peephole-record-kind-mask : i64
  3)
(define compiler-backend-peephole-record-flags-shift : i64
  2)
(define compiler-backend-peephole-record-flags-mask : i64
  8191)
(define compiler-backend-peephole-record-newline-bit : i64
  32768)
(define compiler-backend-peephole-record-owned-bit : i64
  65536)
(define compiler-backend-peephole-record-sweep-boundary-bit : i64
  131072)
(define compiler-backend-peephole-record-width-shift : i64
  18)
(define compiler-backend-peephole-record-width-mask : i64
  255)
(define compiler-backend-peephole-record-mem-count-shift : i64
  32)

;; Sweep-inert marker, the first free low-half bit after the width field: set
;; at record build when the line is an instruction with no sweep flags, no
;; candidate, no epilogue effect and no `(%rsp)` memory references. By the
;; classifier's construction such a record has no rsp motion, read, candidate
;; or epilogue effect in the region sweep; only Win64-tail poisoning remains.
(define compiler-backend-peephole-record-sweep-inert-bit : i64
  67108864)

(define (compiler-backend-peephole-record-start
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]) : i64
  (bit-and rec.span compiler-backend-peephole-record-span-mask))

(define (compiler-backend-peephole-record-end
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]) : i64
  (bit-and
    (shr rec.span compiler-backend-peephole-record-span-shift)
    compiler-backend-peephole-record-span-mask))

(define (compiler-backend-peephole-record-data
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]) : (Ptr u8)
  (unsafe
    (string-data rec.src)))

(define (compiler-backend-peephole-record-kind
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]) : i64
  (bit-and rec.meta compiler-backend-peephole-record-kind-mask))

(define (compiler-backend-peephole-record-flags
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]) : i64
  (bit-and
    (shr rec.meta compiler-backend-peephole-record-flags-shift)
    compiler-backend-peephole-record-flags-mask))

(define (compiler-backend-peephole-record-newline?
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]) : bool
  (not (= (bit-and rec.meta compiler-backend-peephole-record-newline-bit) 0)))

(define (compiler-backend-peephole-record-owned?
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]) : bool
  (not (= (bit-and rec.meta compiler-backend-peephole-record-owned-bit) 0)))

(define (compiler-backend-peephole-record-sweep-boundary?
  [rec : be_state.CompilerBackendPeepholeLineRecord]) : bool
  (not
    (= (bit-and rec.meta compiler-backend-peephole-record-sweep-boundary-bit) 0)))

(define (compiler-backend-peephole-record-width
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]) : i64
  (bit-and
    (shr rec.meta compiler-backend-peephole-record-width-shift)
    compiler-backend-peephole-record-width-mask))

(define (compiler-backend-peephole-record-mem-count
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]) : i64
  (shr rec.meta compiler-backend-peephole-record-mem-count-shift))

(define (compiler-backend-peephole-simple-stack-lea? [meta : i64]) : bool
  (and
    (=
      (bit-and
        (shr meta compiler-backend-peephole-record-flags-shift)
        (bit-or
          compiler-backend-sweep-line-flag-leaq
          compiler-backend-sweep-line-flag-fatal-mem))
      compiler-backend-sweep-line-flag-leaq)
    (= (shr meta compiler-backend-peephole-record-mem-count-shift) 1)))

;; First non-space index of the record's line. Only the never-in-practice
;; multi-reference fallback needs it, so it is recomputed instead of stored.
(define (compiler-backend-peephole-record-mnemonic-start
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]) : i64
  (let
    [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
    [end : i64 (compiler-backend-peephole-record-end rec)]
    [m : i64 (compiler-backend-peephole-record-start rec)]
    (while (and
      (< m end)
      (= (be_state.compiler-backend-peephole-byte-at data m) 32))
      (+= m 1))
    m))

;; Compact one emitted streaming descriptor into its array record. This is where
;; the GAP5 extraction runs -- once per SURVIVING line, from that line's final
;; bytes, so peephole-synthesized lines are summarized from their own rewritten
;; text and lines the pair rules drop or the lookahead parses cost nothing.
;;
;; The extraction is FUSED into the record build: the classification writes
;; straight into the record's packed words, with no per-line summary struct,
;; and ONE word-at-a-time `%` walk answers both the `%rsp` reference question
;; and the vector access width. The walk visits exactly the `%` positions that
;; have a byte after them, in ascending order, and each rule looks only at that
;; one following byte; the `%rsp` rule additionally needs four bytes of room,
;; which it tests per position. `rsp` holds no `%`, so visiting every `%` finds
;; every `%rsp` reference.
(define (compiler-backend-peephole-line-record
  [line : be_state.CompilerBackendPeepholeLine]) : be_state.CompilerBackendPeepholeLineRecord
  (let
    [data : (Ptr u8) line.data]
    [end : i64 (compiler-backend-peephole-desc-end line)]
    [ms : i64 (compiler-backend-peephole-desc-mnemonic-start line)]
    [mlen : i64 (compiler-backend-peephole-desc-mnemonic-len line)]
    [none : i64 compiler-backend-sweep-no-candidate]
    [span : i64
      (bit-or
        (compiler-backend-peephole-desc-start line)
        (shl end compiler-backend-peephole-record-span-shift))]
    ;; Newline, ownership and sweep boundary bits plus the width every non-instruction
    ;; record carries. Shared by all four record shapes below.
    [base-meta : i64
      (bit-or
        (bit-or
          (if (compiler-backend-peephole-desc-newline? line)
            compiler-backend-peephole-record-newline-bit
            0)
          (if (compiler-backend-peephole-desc-owned? line)
            compiler-backend-peephole-record-owned-bit
            0))
        (if (and
          (<= (+ ms 6) end)
          (= (be_state.compiler-backend-peephole-byte-at data ms) 46)
          (or
            (and
              (= (be_state.compiler-backend-peephole-byte-at data (+ ms 1)) 103)
              (= (be_state.compiler-backend-peephole-byte-at data (+ ms 2)) 108)
              (= (be_state.compiler-backend-peephole-byte-at data (+ ms 3)) 111)
              (= (be_state.compiler-backend-peephole-byte-at data (+ ms 4)) 98)
              (= (be_state.compiler-backend-peephole-byte-at data (+ ms 5)) 108))
            ;; The conditional lookup helper is object-local. Its frame is
            ;; independent of the preceding user's function, like a .globl.
            (and
              (= (be_state.compiler-backend-peephole-byte-at data (+ ms 1)) 105)
              (be_operand.compiler-backend-peephole-range-eq?
                data
                ms
                end
                ".ifdef .L_tl_abort_table"))))
          compiler-backend-peephole-record-sweep-boundary-bit
          0))]
    [plain-meta : i64
      (bit-or base-meta (shl 8 compiler-backend-peephole-record-width-shift))]
    (when
      (>= ms end)
      (return
        (be_state.CompilerBackendPeepholeLineRecord
          line.src
          span
          (bit-or compiler-backend-sweep-line-kind-skip plain-meta)
          none
          none
          0)))
    (when
      (compiler-backend-peephole-desc-label? line)
      (return
        (be_state.CompilerBackendPeepholeLineRecord
          line.src
          span
          (bit-or compiler-backend-sweep-line-kind-label plain-meta)
          none
          none
          0)))
    ;; The streaming descriptor has already walked both movq operands. When
    ;; neither can mention rsp, the dead-frame sweep has no fact to extract:
    ;; this is an ordinary 8-byte instruction with no candidate, rsp effect,
    ;; or memory reference. Tracked registers prove they are not rsp; an
    ;; untracked register stays on the byte-audit path because it may be rsp.
    (when
      (compiler-backend-peephole-desc-movq?
        (be_state.compiler-backend-global-shared-view line))
      (let
        [src-flags : i64 (compiler-backend-peephole-desc-op-src-flags line)]
        [dst-flags : i64 (compiler-backend-peephole-desc-op-dst-flags line)]
        [src-stack? : bool
          (compiler-backend-peephole-op-flag?
            src-flags
            compiler-backend-peephole-op-stack-flag)]
        [dst-stack? : bool
          (compiler-backend-peephole-op-flag?
            dst-flags
            compiler-backend-peephole-op-stack-flag)]
        [src-register? : bool
          (compiler-backend-peephole-op-flag?
            src-flags
            compiler-backend-peephole-op-register-flag)]
        [dst-register? : bool
          (compiler-backend-peephole-op-flag?
            dst-flags
            compiler-backend-peephole-op-register-flag)]
        [src-reg : i64 (compiler-backend-peephole-desc-op-src-reg line)]
        [dst-reg : i64 (compiler-backend-peephole-desc-op-dst-reg line)]
        (when
          (and
            (not src-stack?)
            (or (not src-register?) (>= src-reg 0))
            (not dst-stack?)
            (or (not dst-register?) (>= dst-reg 0)))
          (return
            (be_state.CompilerBackendPeepholeLineRecord
              line.src
              span
              (bit-or
                compiler-backend-sweep-line-kind-instruction
                (bit-or
                  base-meta
                  (bit-or
                    compiler-backend-peephole-record-sweep-inert-bit
                    (shl 8 compiler-backend-peephole-record-width-shift))))
              none
              none
              0)))
        ;; A positive owner key proves the whole operand is one canonical
        ;; rbp/rsp spelling and encodes its base, displacement and explicit
        ;; displacement bit. Decode that summary instead of finding `%rsp`
        ;; again. Indexed/odd stack spellings and untracked registers retain
        ;; the general byte audit below.
        (let
          [src-key : i64 line.op-src-key]
          [dst-key : i64 line.op-dst-key]
          (when
            (and
              (=
                (compiler-backend-peephole-desc-op-src-start line)
                (+ ms mlen 1))
              (or (not src-register?) (>= src-reg 0))
              (or (not dst-register?) (>= dst-reg 0))
              (or
                (not src-stack?)
                (compiler-backend-peephole-owner-key-stack? src-key))
              (or
                (not dst-stack?)
                (compiler-backend-peephole-owner-key-stack? dst-key)))
            (let
              [src-bits : i64 (- src-key 1)]
              [dst-bits : i64 (- dst-key 1)]
              [src-rsp? : bool
                (and src-stack? (not (= (bit-and src-bits 2) 0)))]
              [dst-rsp? : bool
                (and dst-stack? (not (= (bit-and dst-bits 2) 0)))]
              [src-off : i64
                (-
                  (shr src-bits 2)
                  be_state.compiler-backend-peephole-owner-key-stack-bias)]
              [dst-off : i64
                (-
                  (shr dst-bits 2)
                  be_state.compiler-backend-peephole-owner-key-stack-bias)]
              [immediate-source? : bool
                (and
                  (not src-register?)
                  (not src-stack?)
                  (=
                    (be_state.compiler-backend-peephole-byte-at
                      data
                      (compiler-backend-peephole-desc-op-src-start line))
                    36)
                  (=
                    (be_operand.compiler-backend-peephole-scan-byte-range
                      data
                      (compiler-backend-peephole-desc-op-src-start line)
                      (compiler-backend-peephole-desc-op-src-end line)
                      40)
                    (compiler-backend-peephole-desc-op-src-end line)))]
              [cand : i64
                (if (and
                  dst-rsp?
                  (not (= (bit-and dst-bits 1) 0))
                  (or (>= src-reg 0) immediate-source?))
                  dst-off
                  none)]
              [raw-mem-count : i64
                (+
                  (if src-rsp?
                    1
                    0)
                  (if dst-rsp?
                    1
                    0))]
              [mem-count : i64
                (if (= cand none)
                  raw-mem-count
                  0)]
              [mem-off : i64
                (if src-rsp?
                  src-off
                  (if dst-rsp?
                    dst-off
                    0))]
              (return
                (be_state.CompilerBackendPeepholeLineRecord
                  line.src
                  span
                  (bit-or
                    compiler-backend-sweep-line-kind-instruction
                    (bit-or
                      base-meta
                      (bit-or
                        (if (and (= cand none) (= mem-count 0))
                          compiler-backend-peephole-record-sweep-inert-bit
                          0)
                        (bit-or
                          (shl 8 compiler-backend-peephole-record-width-shift)
                          (shl
                            mem-count
                            compiler-backend-peephole-record-mem-count-shift)))))
                  cand
                  none
                  (if (= cand none)
                    mem-off
                    0))))))))
    (let
      [b0 : i64 (be_state.compiler-backend-peephole-byte-at data ms)]
      (when
        (or (= b0 46) (= b0 35))
        (return
          (be_state.CompilerBackendPeepholeLineRecord
            line.src
            span
            (bit-or compiler-backend-sweep-line-kind-skip plain-meta)
            none
            none
            0)))
      (let
        [te : i64 (+ ms mlen)]
        ;; A descriptor-proven movq line forces the token, so its
        ;; control kind needs no re-derivation from the bytes.
        [mnemonic-kind : i64
          (if (compiler-backend-peephole-desc-movq?
            (be_state.compiler-backend-global-shared-view line))
            be_operand.compiler-backend-control-mnemonic-movq
            (be_operand.compiler-backend-control-mnemonic-kind data ms mlen))]
        [pop? : bool
          (= mnemonic-kind be_operand.compiler-backend-control-mnemonic-pop)]
        [leaq? : bool
          (= mnemonic-kind be_operand.compiler-backend-control-mnemonic-leaq)]
        [subq? : bool
          (= mnemonic-kind be_operand.compiler-backend-control-mnemonic-subq)]
        [addq? : bool
          (= mnemonic-kind be_operand.compiler-backend-control-mnemonic-addq)]
        ;; `, %rsp` at the line end, spelled as its six bytes: the range
        ;; comparator's own length test is a tautology here, so the last
        ;; byte rejects most lines in one compare.
        [rsp-dst? : bool
          (and
            (>= (- end ms) 6)
            (= (be_state.compiler-backend-peephole-byte-at data (- end 1)) 112)
            (= (be_state.compiler-backend-peephole-byte-at data (- end 6)) 44)
            (= (be_state.compiler-backend-peephole-byte-at data (- end 5)) 32)
            (= (be_state.compiler-backend-peephole-byte-at data (- end 4)) 37)
            (= (be_state.compiler-backend-peephole-byte-at data (- end 3)) 114)
            (= (be_state.compiler-backend-peephole-byte-at data (- end 2)) 115))]
        [imm? : bool
          (and
            (< (+ te 1) end)
            (= (be_state.compiler-backend-peephole-byte-at data (+ te 1)) 36))]
        [tracked-rsp-write? : bool (and rsp-dst? (or subq? addq?) imm?)]
        [cand : i64
          (compiler-backend-sweep-candidate-c
            data
            ms
            te
            end
            mnemonic-kind
            ;; The descriptor already found the operand comma; reuse it
            ;; exactly where the verifier's own scan would start (the
            ;; one-space form), and let it scan everywhere else.
            (if (and
              (compiler-backend-peephole-desc-movq?
                (be_state.compiler-backend-global-shared-view line))
              (= (compiler-backend-peephole-desc-op-src-start line) (+ te 1)))
              (compiler-backend-peephole-desc-op-src-end line)
              -1)
            0)]
        [flags : i64
          (+
            (+
              (+
                (if (=
                  mnemonic-kind
                  be_operand.compiler-backend-control-mnemonic-push)
                  compiler-backend-sweep-line-flag-push
                  0)
                (+
                  (if pop?
                    compiler-backend-sweep-line-flag-pop
                    0)
                  (if leaq?
                    compiler-backend-sweep-line-flag-leaq
                    0)))
              (+
                (+
                  (if (=
                    mnemonic-kind
                    be_operand.compiler-backend-control-mnemonic-leave)
                    compiler-backend-sweep-line-flag-leave
                    0)
                  (if (=
                    mnemonic-kind
                    be_operand.compiler-backend-control-mnemonic-ret)
                    compiler-backend-sweep-line-flag-ret
                    0))
                (+
                  (if (=
                    mnemonic-kind
                    be_operand.compiler-backend-control-mnemonic-jmp)
                    compiler-backend-sweep-line-flag-jmp
                    0)
                  (if subq?
                    compiler-backend-sweep-line-flag-subq
                    0))))
            (+
              (+
                (if rsp-dst?
                  compiler-backend-sweep-line-flag-rsp-dst
                  0)
                (if tracked-rsp-write?
                  compiler-backend-sweep-line-flag-tracked-rsp-write
                  0))
              (if (be_operand.compiler-backend-peephole-range-eq?
                data
                ms
                end
                "movq %rsp, %rbp")
                compiler-backend-sweep-line-flag-win64-rbp-set
                0)))]
        [walk-flags : i64 0]
        [mem-count : i64 0]
        [mem-off : i64 0]
        [vec-width : i64 0]
        ;; A verified pure store has no other rsp effect, so the byte
        ;; walk is skipped for it.
        (when
          (= cand none)
          (let
            ;; 0x0101010101010101, 0x8080808080808080, 2^57-1,
            ;; 0x0001020304050607 -- the scan-byte-range constants.
            [ones : i64 72340172838076673]
            [highs : i64 -9187201950435737472]
            [low-bit-mask : i64 144115188075855871]
            [byte-index : i64 283686952306183]
            [broadcast : i64 (* 37 ones)]
            [limit : i64 (- end 8)]
            [i : i64 ms]
            [q : i64 0]
            [nb : i64 0]
            [hits : i64 0]
            (while (<= i limit)
              (let
                [word : i64
                  (unsafe
                    (ptr-read (ptr-cast (ptr-offset data i) : (Ptr i64))))]
                [x : i64 (bit-xor word broadcast)]
                (set! hits (bit-and (bit-and (- x ones) (bit-xor x -1)) highs))
                (while (not (= hits 0))
                  (set!
                    q
                    (+
                      i
                      (shr
                        (*
                          (bit-and
                            (shr (bit-and hits (- 0 hits)) 7)
                            low-bit-mask)
                          byte-index)
                        56)))
                  (when
                    (< (+ q 1) end)
                    (set!
                      nb
                      (be_state.compiler-backend-peephole-byte-at data (+ q 1)))
                    ;; lint-allow: nested-if-ladder
                    (if (= nb 122)
                      (set! vec-width 64)
                      (if (= nb 121)
                        (if (< vec-width 32)
                          (set! vec-width 32)
                          unit)
                        (if (= nb 120)
                          (if (< vec-width 16)
                            (set! vec-width 16)
                            unit)
                          unit)))
                    (when
                      (and
                        (<= (+ q 4) end)
                        (= nb 114)
                        (=
                          (be_state.compiler-backend-peephole-byte-at
                            data
                            (+ q 2))
                          115)
                        (=
                          (be_state.compiler-backend-peephole-byte-at
                            data
                            (+ q 3))
                          112))
                      (if (and
                        (> q ms)
                        (=
                          (be_state.compiler-backend-peephole-byte-at
                            data
                            (- q 1))
                          40))
                        ;; lint-allow: nested-if-ladder
                        (if (not
                          (and
                            (< (+ q 4) end)
                            (=
                              (be_state.compiler-backend-peephole-byte-at
                                data
                                (+ q 4))
                              41)))
                          (set!
                            walk-flags
                            (bit-or
                              walk-flags
                              compiler-backend-sweep-line-flag-fatal-mem))
                          ;; A `popq MEM` frame operand is recorded
                          ;; like any other; the sweep replay
                          ;; canonicalizes it at delta-8.
                          (begin
                            (when
                              (= mem-count 0)
                              (set!
                                mem-off
                                (compiler-backend-sweep-rsp-ref-offset
                                  data
                                  ms
                                  q)))
                            (+= mem-count 1)))
                        (set!
                          walk-flags
                          (bit-or
                            walk-flags
                            (if (= q (- end 4))
                              compiler-backend-sweep-line-flag-bare-rsp-tail
                              compiler-backend-sweep-line-flag-bare-rsp))))))
                  (set! hits (bit-and hits (- hits 1))))
                (+= i 8)))
            (while (< i end)
              (when
                (and
                  (= (be_state.compiler-backend-peephole-byte-at data i) 37)
                  (< (+ i 1) end))
                (set!
                  nb
                  (be_state.compiler-backend-peephole-byte-at data (+ i 1)))
                ;; lint-allow: nested-if-ladder
                (if (= nb 122)
                  (set! vec-width 64)
                  (if (= nb 121)
                    (if (< vec-width 32)
                      (set! vec-width 32)
                      unit)
                    (if (= nb 120)
                      (if (< vec-width 16)
                        (set! vec-width 16)
                        unit)
                      unit)))
                (when
                  (and
                    (<= (+ i 4) end)
                    (= nb 114)
                    (=
                      (be_state.compiler-backend-peephole-byte-at data (+ i 2))
                      115)
                    (=
                      (be_state.compiler-backend-peephole-byte-at data (+ i 3))
                      112))
                  (if (and
                    (> i ms)
                    (=
                      (be_state.compiler-backend-peephole-byte-at data (- i 1))
                      40))
                    ;; lint-allow: nested-if-ladder
                    (if (not
                      (and
                        (< (+ i 4) end)
                        (=
                          (be_state.compiler-backend-peephole-byte-at
                            data
                            (+ i 4))
                          41)))
                      (set!
                        walk-flags
                        (bit-or
                          walk-flags
                          compiler-backend-sweep-line-flag-fatal-mem))
                      (begin
                        (when
                          (= mem-count 0)
                          (set!
                            mem-off
                            (compiler-backend-sweep-rsp-ref-offset data ms i)))
                        (+= mem-count 1)))
                    (set!
                      walk-flags
                      (bit-or
                        walk-flags
                        (if (= i (- end 4))
                          compiler-backend-sweep-line-flag-bare-rsp-tail
                          compiler-backend-sweep-line-flag-bare-rsp))))))
              (+= i 1))))
        (let
          [all-flags : i64 (bit-or flags walk-flags)]
          [epilogue : i64
            (compiler-backend-sweep-rsp-leaq-to-rsp-c
              data
              ms
              te
              end
              mnemonic-kind
              0)]
          [width : i64
            (if (and (> mem-count 0) (not leaq?))
              ;; lint-allow: nested-if-ladder
              (if (> vec-width 0)
                vec-width
                (if (or (= b0 118) (= b0 107))
                  64
                  8))
              8)]
          (be_state.CompilerBackendPeepholeLineRecord
            line.src
            span
            (bit-or
              (bit-or
                (bit-or
                  compiler-backend-sweep-line-kind-instruction
                  (shl all-flags compiler-backend-peephole-record-flags-shift))
                base-meta)
              (bit-or
                (if (and
                  (= all-flags 0)
                  (= cand none)
                  (= epilogue none)
                  (= mem-count 0))
                  compiler-backend-peephole-record-sweep-inert-bit
                  0)
                (bit-or
                  (shl width compiler-backend-peephole-record-width-shift)
                  (shl
                    mem-count
                    compiler-backend-peephole-record-mem-count-shift))))
            cand
            epilogue
            (if tracked-rsp-write?
              (compiler-backend-rsp-rebase-parse-int data (+ te 2) (- end 6))
              mem-off)))))))

;; Emitted assembly averages ~27 bytes per line. This estimate avoids a second
;; byte scan in the common path; adversarial short-line input grows the active
;; group's borrowed view geometrically before the final view is published.
(define (compiler-backend-peephole-line-vec-capacity-for [n : i64]) : i64
  (+ (/ n 20) 16))

;; The streaming walk's record sink. The dense arrays and their fill level live
;; here rather than in a struct rebuilt for every emitted line, since only the
;; fill level changes per line and the arrays are reallocated at most once per
;; group: the walk opens the sink once per group, appends in place, and closes
;; it into the LineVec its consumers take.
;;
;; The arrays are ordinary group-arena storage.
;; Publish them to the owning stream at open/close, but keep the hot fill cursor
;; in a small borrowed view while walking lines. Copying and writing the entire
;; 35-field stream aggregate for every line is prohibitively expensive in the
;; self-hosted compiler.
;; The last two fields are RMW-2's candidate spans: the record index of every
;; foldable ALU op the walk appended, in emission order. They are ordinary walk
;; cursors, kept here for the same reason `len` is -- the sink is the only place
;; that sees every surviving line exactly once, in emission order.
(defstruct CompilerBackendPeepholeWalkState
  (backend-state-address i64)
  (stream-address i64)
  (carry-safe be_state.CompilerBackendPeepholeCarrySafeView)
  (lines (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord))
  (live (__tl_dyn-array i64))
  (len i64)
  (rmw-cands (__tl_dyn-array i64))
  (rmw-cand-len i64)
  ;; COLD-1's candidates; see CompilerBackendPeepholeLineVec.
  (abort-cands (__tl_dyn-array i64))
  (abort-cand-len i64)
  (close-cands (__tl_dyn-array i64))
  (close-cand-len i64)
  ;; FLAGS-1: the tracked register the last pushed line wrote with an
  ;; arithmetic that sets ZF and SF from its result (sub/add/and/or/xor and
  ;; the one-operand inc/dec/neg), or -1 after any other line.
  (flags-reg i64)
  (probe-cands (__tl_dyn-array i64))
  (probe-cand-len i64)
  (stack-lea-cands (__tl_dyn-array i64))
  (stack-lea-cand-len i64))

(define (compiler-backend-peephole-records-publish!
  [walk : CompilerBackendPeepholeWalkState]) : unit
  (let
    [stream : be_state.CompilerBackendStreamState
      (be_state.CompilerBackendStreamState walk.stream-address)]
    [data : (MutPtr be_state.CompilerBackendStreamStateData)
      (be_state.compiler-backend-stream-state-ptr stream)]
    (unsafe
      (set! (deref data).records-lines walk.lines)
      (set! (deref data).records-live walk.live)
      (set! (deref data).records-len walk.len))))

(define (compiler-backend-peephole-records-publish-len!
  [stream : be_state.CompilerBackendStreamState]
  [len : i64]) : unit
  (unsafe
    (set!
      (deref (be_state.compiler-backend-stream-state-ptr stream)).records-len
      len)))

(define (compiler-backend-peephole-records-close
  [walk : CompilerBackendPeepholeWalkState]) : be_state.CompilerBackendPeepholeLineVec
  (compiler-backend-peephole-records-publish!
    (be_state.compiler-backend-global-shared-view walk))
  (be_state.CompilerBackendPeepholeLineVec
    walk.lines
    walk.live
    walk.len
    walk.rmw-cands
    walk.rmw-cand-len
    walk.abort-cands
    walk.abort-cand-len
    walk.close-cands
    walk.close-cand-len
    walk.probe-cands
    walk.probe-cand-len
    walk.stack-lea-cands
    walk.stack-lea-cand-len))

(define (compiler-backend-peephole-records-state-grow!
  [stream : be_state.CompilerBackendStreamState]) : unit
  (unsafe
    (let
      [data : (MutPtr be_state.CompilerBackendStreamStateData)
        (be_state.compiler-backend-stream-state-ptr stream)]
      [old-lines : (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord)
        (deref data).records-lines]
      [old-live : (__tl_dyn-array i64) (deref data).records-live]
      [len : i64 (deref data).records-len]
      [new-cap : i64
        (if (< (array-length old-lines) 1)
          1
          (* (array-length old-lines) 2))]
      [lines : (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord)
        (__tl_make-array be_state.CompilerBackendPeepholeLineRecord new-cap)]
      [live : (__tl_dyn-array i64) (__tl_make-array i64 new-cap)]
      (for [k (iterator.range 0 len)]
        (set!
          (array-ref lines k)
          (owned_view.compiler-owned-element-view old-lines k))
        (set! (array-ref live k) (array-ref old-live k)))
      (set! (deref data).records-lines lines)
      (set! (deref data).records-live live))))

(define (compiler-backend-peephole-records-grow!
  [walk : (&mut walk CompilerBackendPeepholeWalkState)]) : unit
  (let
    [stream : be_state.CompilerBackendStreamState
      (be_state.CompilerBackendStreamState walk.stream-address)]
    [_publish : unit
      (compiler-backend-peephole-records-publish-len! stream walk.len)]
    [_grow : unit (compiler-backend-peephole-records-state-grow! stream)]
    [data : be_state.CompilerBackendStreamStateData
      (be_state.compiler-backend-stream-state-data stream)]
    (set! walk.lines data.records-lines)
    (set! walk.live data.records-live)))

;; ---------------------------------------------------------------------------
;; RMW-2: recognition of the load / ALU / store triple, fused into the walk.
;;
;; The fold itself lives below (`compiler-backend-peephole-rmw-fold-candidates!`);
;; what happens here is only that the MIDDLE line of a window gets its record
;; index written down. The op is by far the rarest of the three shapes, and its
;; two neighbours are already in the record array by the time the pass below
;; runs, so naming the op names the whole window. Recognition therefore costs
;; ONE mask test on the descriptor's flag word for every emitted line: the
;; parser has already decided whether a line's only written register is its
;; last operand, and no line without that flag can be the middle of a window. A
;; standalone pass would re-walk every emitted line to find the same triples.
;; 1 for a two-operand foldable ALU mnemonic, 2 for a one-operand one, 0 for
;; anything else. Classified from the token's bytes rather than through the
;; literal comparator: recognition asks this of every emitted line whose
;; mnemonic opens with a/s/o/x/n, and seven literal compares there cost more
;; than the fold saves. The three-byte packing is the one
;; `compiler-backend-peephole-mnemonic-single-dest?` already uses, so the two
;; classifiers read the same bytes the same way.
(define (compiler-backend-peephole-rmw-alu-kind
  [data : (Ptr u8)]
  [ms : i64]
  [me : i64]) : i64
  (let
    [mlen : i64 (- me ms)]
    (cond
      ;; `orq` is the only three-byte member.
      [(= mlen 3)
        (if (and
          (= (be_state.compiler-backend-peephole-byte-at data ms) 111)
          (= (be_state.compiler-backend-peephole-byte-at data (+ ms 1)) 114)
          (= (be_state.compiler-backend-peephole-byte-at data (+ ms 2)) 113))
          1
          0)]
      [(not (= mlen 4)) 0]
      ;; Every remaining member is a 64-bit form; a narrower width writes only
      ;; part of the register and is not the shape the fold rewrites.
      [(not (= (be_state.compiler-backend-peephole-byte-at data (+ ms 3)) 113))
        0]
      [else
        (let
          [base3 : i64
            (+
              (be_state.compiler-backend-peephole-byte-at data ms)
              (+
                (*
                  (be_state.compiler-backend-peephole-byte-at data (+ ms 1))
                  256)
                (*
                  (be_state.compiler-backend-peephole-byte-at data (+ ms 2))
                  65536)))]
          (cond
            [(= base3 6579297) 1]
            [(= base3 6452595) 1]
            [(= base3 6581857) 1]
            [(= base3 7499640) 1]
            [(= base3 6776174) 2]
            [(= base3 7630702) 2]
            [else 0]))])))

;; End of the mnemonic token that starts at `ms`.
(define (compiler-backend-peephole-rmw-mnemonic-end
  [data : (Ptr u8)]
  [ms : i64]
  [end : i64]) : i64
  (be_operand.compiler-backend-peephole-scan-byte-range data ms end 32))

;; Candidate spans are rare next to emitted lines, so the array starts empty and
;; is only ever allocated for a group that has one.
(define compiler-backend-peephole-rmw-cands-initial-capacity : i64
  16)

(define (compiler-backend-peephole-rmw-cands-grow!
  [walk : (&mut walk CompilerBackendPeepholeWalkState)]) : unit
  (let
    [old : (__tl_dyn-array i64) walk.rmw-cands]
    [len : i64 walk.rmw-cand-len]
    [cap : i64
      (if (<
        (array-length old)
        compiler-backend-peephole-rmw-cands-initial-capacity)
        compiler-backend-peephole-rmw-cands-initial-capacity
        (* (array-length old) 2))]
    [grown : (__tl_dyn-array i64) (__tl_make-array i64 cap)]
    (for [k (iterator.range 0 len)]
      (set! (array-ref grown k) (array-ref old k)))
    (set! walk.rmw-cands grown)))

;; Reuse the ALU sink's already classified untracked destinations. Keep the
;; original subtraction through every rsp/owner/dead-store pass; expand only
;; the surviving records immediately before their final render.
(define (compiler-backend-note-stack-probe!
  [walk : (&mut walk CompilerBackendPeepholeWalkState)]
  [line : (& line be_state.CompilerBackendPeepholeLine)]
  [index : i64]) : unit
  (let
    [data : (Ptr u8) line.data]
    [ms : i64 (compiler-backend-peephole-desc-mnemonic-start line)]
    [end : i64 (compiler-backend-peephole-desc-end line)]
    [start : i64 (+ ms 6)]
    [stop : i64 (- end 6)]
    (when
      (and
        ;; Reject the common small immediates before inspecting their text.
        (>= (- stop start) 4)
        (or
          (> (- stop start) 4)
          (>= (be_state.compiler-backend-peephole-byte-at data start) 52))
        (> (- end ms) 12)
        (be_operand.compiler-backend-peephole-range-eq? data ms (+ ms 4) "subq")
        (= (be_state.compiler-backend-peephole-byte-at data (+ ms 4)) 32)
        (be_operand.compiler-backend-peephole-range-eq?
          data
          (- end 6)
          end
          ", %rsp")
        (= (be_state.compiler-backend-peephole-byte-at data (- start 1)) 36)
        (= (compiler-backend-rsp-rebase-int-start data start stop) start)
        (> (compiler-backend-rsp-rebase-parse-int data start stop) 4096))
      (when
        (>= walk.probe-cand-len (array-length walk.probe-cands))
        (let
          [old : (__tl_dyn-array i64) walk.probe-cands]
          [grown : (__tl_dyn-array i64)
            (__tl_make-array i64 (+ 16 (* 2 (array-length old))))]
          (for [i (iterator.range 0 walk.probe-cand-len)]
            (set! (array-ref grown i) (array-ref old i)))
          (set! walk.probe-cands grown)))
      (let
        [entry? : bool
          (and
            (> index 0)
            (let
              [previous : (& walk be_state.CompilerBackendPeepholeLineRecord)
                (& (array-ref walk.lines (- index 1)))]
              [first : i64 (compiler-backend-peephole-record-start previous)]
              [last : i64 (compiler-backend-peephole-record-end previous)]
              (and
                (= (- last first) 16)
                (be_operand.compiler-backend-peephole-range-eq?
                  (compiler-backend-peephole-record-data previous)
                  first
                  last
                  "# tl-stack-entry"))))]
        (when entry? (set! (array-ref walk.live (- index 1)) 0))
        ;; Low bit is producer classification; the remaining bits are the
        ;; record index. No extra per-line/per-function state or scan is needed.
        (set!
          (array-ref walk.probe-cands walk.probe-cand-len)
          (+
            (* index 2)
            (if entry?
              1
              0)))
        (+= walk.probe-cand-len 1)))))

(define (compiler-backend-expand-stack-probes!
  [backend-state : be_state.CompilerBackendState]
  [records : (&mut records be_state.CompilerBackendPeepholeLineVec)]) : unit
  (when
    (be_state.compiler-backend-state-emission-target-policy backend-state).linux
    (for [i (iterator.range 0 records.probe-cand-len)]
      (let
        [candidate : i64 (array-ref records.probe-cands i)]
        [at : i64 (shr candidate 1)]
        (when
          (and
            (= (array-ref records.live at) 1)
            (or
              (= (bit-and candidate 1) 0)
              (> (array-ref records.lines at).value 32768)))
          (let
            [amount : i64 (array-ref records.lines at).value]
            [text : String
              (be_operand.compiler-backend-emit-stack-probe amount)]
            [span : i64
              (shl
                (string.string-length (& text))
                compiler-backend-peephole-record-span-shift)]
            ;; All semantic consumers have finished. This owned render-only
            ;; record may contain the complete multi-line probe sequence.
            (set!
              (array-ref records.lines at)
              (be_state.CompilerBackendPeepholeLineRecord
                text
                span
                compiler-backend-peephole-record-owned-bit
                compiler-backend-sweep-no-candidate
                compiler-backend-sweep-no-candidate
                0))))))))

;; Record a foldable ALU window candidate. Neither this recognition nor stack
;; probe recognition changes the line that the remaining analyses consume.
(define (compiler-backend-peephole-rmw-note-alu!
  [walk : (&mut walk CompilerBackendPeepholeWalkState)]
  [line : (& line be_state.CompilerBackendPeepholeLine)]
  [index : i64]) : unit
  (let
    [mnemonic : i64 line.mnemonic]
    [data : (Ptr u8) line.data]
    [ms : i64 (bit-and mnemonic compiler-backend-peephole-desc-pack-mask)]
    [b0 : i64 (be_state.compiler-backend-peephole-byte-at data ms)]
    (when
      (or (= b0 97) (= b0 115) (= b0 111) (= b0 120) (= b0 110))
      (let
        [last-reg : i64
          (-
            (bit-and
              (shr line.regs compiler-backend-peephole-desc-reg-last-shift)
              compiler-backend-peephole-desc-reg-mask)
            1)]
        (when
          (and (= b0 115) (< last-reg 0))
          (compiler-backend-note-stack-probe! walk line index))
        (when
          (and
            (>= last-reg 0)
            (>
              (compiler-backend-peephole-rmw-alu-kind
                data
                ms
                (+
                  ms
                  (bit-and
                    (shr mnemonic compiler-backend-peephole-desc-pack-shift)
                    compiler-backend-peephole-desc-pack-mask)))
              0))
          (unless
            (< walk.rmw-cand-len (array-length walk.rmw-cands))
            (compiler-backend-peephole-rmw-cands-grow! walk))
          (set! (array-ref walk.rmw-cands walk.rmw-cand-len) index)
          (+= walk.rmw-cand-len 1))))))

;; Append one surviving line, compacted. Records are live until the sweep marks
;; them dead, and the arrays are never rebuilt.
;; --- FLAGS-1: a test of the register an arithmetic just wrote --------------
;;
;;     subq $1, %r        (or addq/andq/orq/xorq ..., %r; incq/decq/negq %r)
;;     testq %r, %r
;;     jcc L
;;
;; The arithmetic already set ZF and SF from the very value the `test` reads,
;; so the `test` is dead for a branch that reads only those two flags: je/jne
;; (ZF) and js/jns (SF) stay as they are, and `jge`/`jl` -- which after a
;; `test` (OF = 0) mean SF = 0 / SF = 1 -- become `jns`/`js`, since after an
;; add or sub OF may be set. `and`/`or`/`xor` clear OF and CF exactly like
;; `test`, but the branch set is kept to the flag-exact four for every writer.
;; IV-AFF's counted-down loops end in exactly this triple (`sub $1; test;
;; jge`); clang emits `dec; jns`.
;;
;; Adjacency is what makes "nothing wrote flags in between" true: the writer
;; is the line pushed immediately before the `test` (records-push! notes its
;; register; any other line, a label included, clears the note), and the
;; branch is the line after the `test`. The rewrite drops the `test` and
;; keeps the branch, respelled when it must be.
(define (compiler-backend-peephole-flags-writer-desc?
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : bool
  ;; The mnemonic's bytes read as one little-endian word, compared against the
  ;; packed spellings, the way compiler-backend-control-mnemonic-kind does:
  ;; subq addq andq xorq incq decq negq, and orq.
  (let
    [ml : i64 (compiler-backend-peephole-desc-mnemonic-len line)]
    [data : (Ptr u8) line.data]
    [ms : i64 (compiler-backend-peephole-desc-mnemonic-start line)]
    (if (or (< ml 3) (> ml 4))
      false
      (let
        [key3 : i64
          (+
            (be_state.compiler-backend-peephole-byte-at data ms)
            (+
              (* (be_state.compiler-backend-peephole-byte-at data (+ ms 1)) 256)
              (*
                (be_state.compiler-backend-peephole-byte-at data (+ ms 2))
                65536)))]
        (if (= ml 3)
          (= key3 7434863)
          (let
            [key4 : i64
              (+
                key3
                (*
                  (be_state.compiler-backend-peephole-byte-at data (+ ms 3))
                  16777216))]
            (or
              (= key4 1902278003)
              (= key4 1902404705)
              (= key4 1902407265)
              (= key4 1903325048)
              (= key4 1902341737)
              (= key4 1902339428)
              (= key4 1902601582))))))))

;; The register `line` leaves ZF/SF for, or -1.
(define (compiler-backend-peephole-flags-next-desc
  [line : be_state.CompilerBackendPeepholeLine]) : i64
  (if (compiler-backend-peephole-flags-writer-desc? line)
    (compiler-backend-peephole-desc-last-reg line)
    (- 0 1)))

;; `pending` is `testq %r, %r` on the register the previous line wrote
;; (flags-reg), and `next` is a branch on ZF or SF alone.
(define (compiler-backend-peephole-flags-branch-desc?
  [flags-reg : i64]
  [pending : (& pending be_state.CompilerBackendPeepholeLine)]
  [next : (& next be_state.CompilerBackendPeepholeLine)]) : bool
  (if (or
    (< flags-reg 0)
    (not (compiler-backend-peephole-line-mnemonic-eq? pending "testq"))
    (not
      (or
        (compiler-backend-peephole-line-mnemonic-eq? next "je")
        (compiler-backend-peephole-line-mnemonic-eq? next "jne")
        (compiler-backend-peephole-line-mnemonic-eq? next "js")
        (compiler-backend-peephole-line-mnemonic-eq? next "jns")
        (compiler-backend-peephole-line-mnemonic-eq? next "jge")
        (compiler-backend-peephole-line-mnemonic-eq? next "jl"))))
    false
    (let
      [pd : (Ptr u8) pending.data]
      [pms : i64 (compiler-backend-peephole-desc-mnemonic-start pending)]
      [pmlen : i64 (compiler-backend-peephole-desc-mnemonic-len pending)]
      [pend : i64 (compiler-backend-peephole-desc-end pending)]
      [pops : i64
        (compiler-backend-peephole-operand-start-range pd (+ pms pmlen) pend)]
      [pcomma : i64
        (compiler-backend-peephole-find-comma-space-range pd pops pend)]
      ;; `test` writes no destination, so the parser records no register for
      ;; it; the operand is read off the text here.
      (and
        (> pcomma pops)
        (< (+ pcomma 2) pend)
        (= (be_state.compiler-backend-peephole-byte-at pd pops) 37)
        (= (be_state.compiler-backend-peephole-byte-at pd (+ pcomma 2)) 37)
        (be_operand.compiler-backend-peephole-ranges-eq?
          pd
          pops
          pcomma
          pd
          (+ pcomma 2)
          pend)
        (=
          (compiler-backend-peephole-last-operand-reg-index pd pops pend)
          flags-reg)))))

;; The branch line with `jge`/`jl` respelled `jns`/`js`; other branches as
;; they are.
(define (compiler-backend-peephole-flags-branch-line-desc
  [next : be_state.CompilerBackendPeepholeLine]) : String
  (let
    [text : String (compiler-backend-peephole-line-text next)]
    [start : i64 (compiler-backend-peephole-desc-start next)]
    [ms : i64 (- (compiler-backend-peephole-desc-mnemonic-start next) start)]
    [ml : i64 (compiler-backend-peephole-desc-mnemonic-len next)]
    [spelling : String
      (cond
        [(compiler-backend-peephole-line-mnemonic-eq? next "jge") "jns"]
        [(compiler-backend-peephole-line-mnemonic-eq? next "jl") "js"]
        [else ""])]
    (if (= (string.string-length spelling) 0)
      text
      (str_cat.str-cat
        (string.substring text 0 ms)
        spelling
        (string.substring
          text
          (+ ms ml)
          (- (string.string-length text) (+ ms ml)))))))

(define (compiler-backend-peephole-note-stack-lea!
  [walk : (&mut walk CompilerBackendPeepholeWalkState)]
  [index : i64]) : unit
  (let
    [len : i64 walk.stack-lea-cand-len]
    (when
      (>= len (array-length walk.stack-lea-cands))
      (let
        [old : (__tl_dyn-array i64) walk.stack-lea-cands]
        [grown : (__tl_dyn-array i64)
          (__tl_make-array i64 (+ 16 (* 2 (array-length old))))]
        (for [i (iterator.range 0 len)]
          (set! (array-ref grown i) (array-ref old i)))
        (set! walk.stack-lea-cands grown)))
    (set! (array-ref walk.stack-lea-cands len) index)
    (set! walk.stack-lea-cand-len (+ len 1))))

(define (compiler-backend-peephole-records-push!
  [walk : (&mut walk CompilerBackendPeepholeWalkState)]
  [line : be_state.CompilerBackendPeepholeLine]) : unit
  (let
    [index : i64 walk.len]
    [flags-next : i64
      (compiler-backend-peephole-flags-next-desc
        (be_state.compiler-backend-global-shared-view line))]
    ;; RMW-2 recognition rides here, on the descriptor and before the record
    ;; build consumes it. This mask is the whole per-line cost for a line that
    ;; cannot be the middle of a window.
    (unless
      (= (bit-and line.flags compiler-backend-peephole-desc-flag-single-dest) 0)
      (compiler-backend-peephole-rmw-note-alu! walk (& line) index))
    ;; COLD-1's candidates: the parser already flagged abort calls, and only
    ;; a line whose first byte is `.` can close a function.
    (unless
      (=
        (bit-and line.flags compiler-backend-peephole-desc-flag-noreturn-abort)
        0)
      (compiler-backend-cold-note-abort! walk index))
    (let
      [first : i64
        (bit-and line.mnemonic compiler-backend-peephole-desc-pack-mask)]
      (when
        (and
          (<
            first
            (bit-and
              (shr line.span compiler-backend-peephole-desc-pack-shift)
              compiler-backend-peephole-desc-pack-mask))
          (= (be_state.compiler-backend-peephole-byte-at line.data first) 46))
        (compiler-backend-cold-note-closing! walk (& line) index)))
    (unless
      (< index (array-length walk.lines))
      (compiler-backend-peephole-records-grow! walk))
    (set!
      (array-ref walk.lines index)
      (compiler-backend-peephole-line-record line))
    (when
      (compiler-backend-peephole-simple-stack-lea?
        (array-ref walk.lines index).meta)
      (compiler-backend-peephole-note-stack-lea! walk index))
    (set! (array-ref walk.live index) 1)
    (set! walk.flags-reg flags-next)
    (set! walk.len (+ index 1))))

;; True iff the line [start,end) is a label (non-blank after leading spaces and
;; ends in ':'). Mirrors the label arm of line-clears-owners?.
;; True iff the label on line [start,end) (its name = first-non-space..':') is in
;; the backend-collected carry-safe set -- i.e. a block reached only by
;; fall-through from its single layout-adjacent predecessor, so the running owner
;; map may be CARRIED across it. Any label absent from the set (every merge /
;; branch / switch / jump-table target, every synthetic non-block label, and the
;; function entry) is NOT carry-safe and must reset. `src` is the String the
;; byte offsets index into (the asm buffer or a rewritten pending line). The
;; label name is interned and looked up in the i64-id carry-safe set.
(define (compiler-backend-peephole-label-carry-safe?
  [view : (& view be_state.CompilerBackendPeepholeCarrySafeView)]
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : bool
  (let
    [i : i64 start]
    (while (and
      (< i end)
      (= (be_state.compiler-backend-peephole-byte-at data i) 32))
      (+= i 1))
    (if (>= i (- end 1))
      false
      (let
        [klen : i64 (- (- end 1) i)]
        (be_state.compiler-backend-peephole-carry-safe-contains-view?
          view
          data
          i
          klen
          (ci.intern-hash-words data i klen))))))

;; Per-destination owner invalidation for a non-movq line.
;;  * A NORETURN abort call (SCAV2): keep the map unchanged -- the fall-through is
;;    dead, so nothing observes it until the guard-ok label below.
;;  * A LABEL: reset the whole map UNLESS the label is carry-safe (a provably
;;    single-pred fall-through block), OR (SCAV2) it is a guard-ok continuation
;;    label reached immediately after a noreturn abort (`prev-abort?`): its only
;;    live predecessor is the guard's conditional jump, across which the register
;;    map is identical to the map carried through the abort, so the map is valid.
;;  * A normal call: preserve callee-saved register owners, clear caller-saved
;;    owners.
;;  * A whitelisted single-GP-dest q-op whose last operand is a tracked register:
;;    clear only that register's owner (everything else's reg<->slot mirror
;;    survives).
;;  * Otherwise fall back to the conservative whole-map clear.
;; A spelled stack operand starts with a signed decimal or a bare base.
;; Reject symbol addends, indexed forms, and segment overrides.
(define (compiler-backend-peephole-stack-destination-key
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : i64
  (let
    [base : i64 (compiler-backend-peephole-memory-base-range data start end)]
    (if (or (= base 1) (= base 2))
      (let
        [paren : i64 (- end 6)]
        [first : i64 (compiler-backend-rsp-rebase-int-start data start paren)]
        [operand : i64
          (if (>= first 0)
            first
            paren)]
        (if (and
          (> operand start)
          (= (be_state.compiler-backend-peephole-byte-at data (- operand 1)) 32)
          (<= (- paren operand) 10))
          (compiler-backend-peephole-stack-owner-key-from-parts
            (- base 1)
            (if (>= first 0)
              (compiler-backend-rsp-rebase-parse-int data first paren)
              0)
            (>= first 0))
          0))
      0)))

(define (compiler-backend-peephole-single-memory-write-owners
  [owners : be_state.CompilerBackendPeepholeOwners]
  [line : (& line be_state.CompilerBackendPeepholeLine)]) : be_state.CompilerBackendPeepholeOwners
  (let
    [ms : i64 (compiler-backend-peephole-desc-mnemonic-start line)]
    [ml : i64 (compiler-backend-peephole-desc-mnemonic-len line)]
    [slot : i64
      (compiler-backend-peephole-stack-destination-key
        line.data
        (+ ms ml)
        (compiler-backend-peephole-desc-end line))]
    (when (<= slot 0) (return (compiler-backend-peephole-owners-empty)))
    (let
      [suffix : i64
        (be_state.compiler-backend-peephole-byte-at line.data (- (+ ms ml) 1))]
      [width : i64
        (cond
          [(and
              (= (be_state.compiler-backend-peephole-byte-at line.data ms) 115)
              (=
                (be_state.compiler-backend-peephole-byte-at line.data (+ ms 1))
                101))
            1]
          [(= suffix 98) 1]
          [(= suffix 119) 2]
          [(= suffix 108) 4]
          [else 8])]
      (compiler-backend-peephole-owners-clear-extent owners slot width))))

(define (compiler-backend-peephole-line-clobber-owners-desc
  [carry-safe : (& carry-safe be_state.CompilerBackendPeepholeCarrySafeView)]
  [owners : be_state.CompilerBackendPeepholeOwners]
  [line : be_state.CompilerBackendPeepholeLine]
  [prev-abort? : bool]) : be_state.CompilerBackendPeepholeOwners
  (cond
    [(compiler-backend-peephole-desc-noreturn-abort? line) owners]
    [(compiler-backend-peephole-desc-label? line)
      (if (or
        (compiler-backend-peephole-label-carry-safe?
          carry-safe
          line.data
          (compiler-backend-peephole-desc-start line)
          (compiler-backend-peephole-desc-end line))
        (and
          prev-abort?
          (compiler-backend-peephole-label-guard-ok?
            line.data
            (compiler-backend-peephole-desc-start line)
            (compiler-backend-peephole-desc-end line))))
        owners
        (compiler-backend-peephole-owners-empty))]
    [(not (compiler-backend-peephole-desc-clears-owners? line)) owners]
    [(compiler-backend-peephole-desc-call? line)
      (compiler-backend-peephole-owners-clear-call-clobbers owners)]
    [(compiler-backend-peephole-desc-single-dest? line)
      (let
        [dreg : i64
          (compiler-backend-peephole-desc-last-reg
            (be_state.compiler-backend-global-shared-view line))]
        (if (< dreg 0)
          (compiler-backend-peephole-single-memory-write-owners owners (& line))
          (compiler-backend-peephole-owners-set-reg-index
            owners
            dreg
            (compiler-backend-peephole-owner-key-unknown))))]
    [else (compiler-backend-peephole-owners-empty)]))

(define (compiler-backend-peephole-line-self-move-desc?
  [line : be_state.CompilerBackendPeepholeLine]) : bool
  (and
    (compiler-backend-peephole-desc-movq?
      (be_state.compiler-backend-global-shared-view line))
    (not (= (bit-and (compiler-backend-peephole-desc-op-src-flags line) 3) 0))
    (be_operand.compiler-backend-peephole-ranges-eq?
      line.data
      (compiler-backend-peephole-desc-op-src-start line)
      (compiler-backend-peephole-desc-op-src-end line)
      line.data
      (compiler-backend-peephole-desc-op-dst-start line)
      (compiler-backend-peephole-desc-op-dst-end line))))

(define (compiler-backend-peephole-redundant-zext-next-desc?
  [next : be_state.CompilerBackendPeepholeLine]
  [reg : i64]) : bool
  (if (or
    (not (compiler-backend-peephole-desc-has-operands? next))
    (!= (compiler-backend-peephole-desc-zext-dst next) reg))
    false
    (let
      [data : (Ptr u8) next.data]
      [src-start : i64 (compiler-backend-peephole-desc-op-src-start next)]
      [src-end : i64 (compiler-backend-peephole-desc-op-src-end next)]
      [src-len : i64 (- src-end src-start)]
      (if (or
        (= src-len 0)
        (not (= (be_state.compiler-backend-peephole-byte-at data src-start) 37)))
        false
        (let
          [last : i64
            (be_state.compiler-backend-peephole-byte-at data (- src-end 1))]
          (if (not (or (= last 108) (= last 98)))
            false
            (=
              (compiler-backend-peephole-token-reg-index-range
                data
                src-start
                src-end)
              reg)))))))

(define (compiler-backend-peephole-redundant-zext-pair-desc?
  [pending : be_state.CompilerBackendPeepholeLine]
  [next : be_state.CompilerBackendPeepholeLine]) : bool
  (let
    [dst : i64 (compiler-backend-peephole-desc-zext-dst pending)]
    (if (< dst 0)
      false
      (compiler-backend-peephole-redundant-zext-next-desc? next dst))))

;; First non-space byte at or after `start`, i.e. where a line's operands begin
;; once the mnemonic has been stepped over.
(define (compiler-backend-peephole-operand-start-range
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : i64
  (let
    [i : i64 start]
    (while (and
      (< i end)
      (= (be_state.compiler-backend-peephole-byte-at data i) 32))
      (+= i 1))
    i))

;; `andq X, %r` writes %r and sets ZF/SF/PF from the result while clearing
;; OF/CF; `testq %r, %r` on that same register recomputes exactly those flags
;; and clears the same two, so it is dead -- for every consumer, not just the
;; equality branches (CF is 0 either way, so the unsigned predicates agree too).
;;
;; The pair is ADJACENT in the emitted text, which is what makes "nothing wrote
;; flags in between" true: every instruction is a line of its own, and a label
;; between the two would be the pending line here instead (the deferred-jmp path
;; is the only thing that buffers labels, and it only ever defers a `jmp`, then
;; replays the labels through the ordinary emit rule). Operand ranges are not
;; pre-split for these mnemonics -- only the move/zext rules consume the split --
;; so both operands are located here, and the `%` test keeps the destination a
;; register rather than a memory location.
(define (compiler-backend-peephole-dead-test-after-and-desc?
  [pending : (& pending be_state.CompilerBackendPeepholeLine)]
  [next : (& next be_state.CompilerBackendPeepholeLine)]) : bool
  (let
    [pd : (Ptr u8) pending.data]
    [pms : i64 (compiler-backend-peephole-desc-mnemonic-start pending)]
    [pmlen : i64 (compiler-backend-peephole-desc-mnemonic-len pending)]
    (if (or
      (not (= pmlen 4))
      (not (= (be_state.compiler-backend-peephole-byte-at pd pms) 97))
      (not
        (be_operand.compiler-backend-peephole-range-eq?
          pd
          pms
          (+ pms pmlen)
          "andq")))
      false
      (let
        [nd : (Ptr u8) next.data]
        [nms : i64 (compiler-backend-peephole-desc-mnemonic-start next)]
        [nmlen : i64 (compiler-backend-peephole-desc-mnemonic-len next)]
        (if (or
          (not (= nmlen 5))
          (not
            (be_operand.compiler-backend-peephole-range-eq?
              nd
              nms
              (+ nms nmlen)
              "testq")))
          false
          (let
            [pend : i64 (compiler-backend-peephole-desc-end pending)]
            [nend : i64 (compiler-backend-peephole-desc-end next)]
            [pops : i64
              (compiler-backend-peephole-operand-start-range
                pd
                (+ pms pmlen)
                pend)]
            [nops : i64
              (compiler-backend-peephole-operand-start-range
                nd
                (+ nms nmlen)
                nend)]
            [pcomma : i64
              (compiler-backend-peephole-find-comma-space-range pd pops pend)]
            [ncomma : i64
              (compiler-backend-peephole-find-comma-space-range nd nops nend)]
            (and
              (> pcomma pops)
              (> ncomma nops)
              (< (+ pcomma 2) pend)
              (< (+ ncomma 2) nend)
              (=
                (be_state.compiler-backend-peephole-byte-at pd (+ pcomma 2))
                37)
              (be_operand.compiler-backend-peephole-ranges-eq?
                nd
                nops
                ncomma
                nd
                (+ ncomma 2)
                nend)
              (be_operand.compiler-backend-peephole-ranges-eq?
                pd
                (+ pcomma 2)
                pend
                nd
                nops
                ncomma))))))))

;; True iff any assembly text is left at or after chunk `chunk` offset `start`.
;; The scan below stops on its line cap, and the cap census counts only the
;; stops that left text unexamined.
(define (compiler-backend-peephole-chunks-text-remaining?
  [chunks : (& chunks be_state.CompilerBackendPeepholeChunkArray)]
  [chunk : i64]
  [start : i64]) : bool
  (let
    [items : (__tl_dyn-array String) chunks.items]
    [count : i64 chunks.count]
    [c : i64 chunk]
    [i : i64 start]
    [found : bool false]
    (while (and (not found) (< c count))
      (if (< i (string.string-length (array-ref items c)))
        (set! found true)
        (begin
          (+= c 1)
          (set! i 0))))
    found))

;; Scan forward from chunk `chunk` offset `start`, across chunk boundaries
;; exactly as over one contiguous group text.
(define (compiler-backend-peephole-r10-dead-after-desc?
  [backend-state : be_state.CompilerBackendState]
  [stream : be_state.CompilerBackendStreamState]
  [chunks : (& chunks be_state.CompilerBackendPeepholeChunkArray)]
  [chunk : i64]
  [start : i64]) : bool
  (let
    [items : (__tl_dyn-array String) chunks.items]
    [count : i64 chunks.count]
    [c : i64 chunk]
    [i : i64 start]
    [k : i64 0]
    [result : i64 -1]
    (while (and
      (< c count)
      (< result 0)
      (< k compiler-backend-peephole-r10-dead-scan-line-cap))
      (let
        [asm : String
          (be_state.compiler-backend-global-array-element-shared-view items c)]
        [n : i64 (string.string-length asm)]
        (if (>= i n)
          (begin
            (+= c 1)
            (set! i 0))
          (let
            [asm-data : (Ptr u8)
              (unsafe
                (string-data asm))]
            [context : be_state.CompilerBackendPeepholeParseContext
              (be_state.CompilerBackendPeepholeParseContext
                backend-state.address
                stream.address
                asm-data)]
            ;; The line ends at its newline, or at the chunk end.
            [end : i64
              (be_operand.compiler-backend-peephole-scan-byte-range
                asm-data
                i
                n
                10)]
            [next-start : i64
              (if (< end n)
                (+ end 1)
                end)]
            [line : be_state.CompilerBackendPeepholeLine
              (compiler-backend-peephole-parse-line
                context
                asm
                i
                end
                (< end n)
                false)]
            [mentions-r10 : bool
              (compiler-backend-peephole-range-mentions-r10-data?
                asm-data
                i
                end)]
            [clean-writes-r10 : bool
              (and
                (compiler-backend-peephole-desc-movq?
                  (be_state.compiler-backend-global-shared-view line))
                (= (compiler-backend-peephole-desc-op-dst-reg line) 8)
                (not
                  (compiler-backend-peephole-range-mentions-r10-data?
                    line.data
                    (compiler-backend-peephole-desc-op-src-start line)
                    (compiler-backend-peephole-desc-op-src-end line))))]
            (if mentions-r10
              (if clean-writes-r10
                (set! result 1)
                (set! result 0))
              (if (compiler-backend-peephole-desc-movq? line)
                unit
                (set! result 0)))
            (set! i next-start)
            (+= k 1)))))
    (if (and
      (< result 0)
      (compiler-backend-peephole-chunks-text-remaining? chunks c i))
      (cfg
        test
        (be_state.compiler-backend-metric-add!
          backend-state
          be_state.compiler-backend-peephole-r10-dead-scan-cap-hits-metric
          1)
        unit)
      unit)
    (= result 1)))

(define (compiler-backend-peephole-pair-action-desc
  [walk : (& walk CompilerBackendPeepholeWalkState)]
  [chunks : (& chunks be_state.CompilerBackendPeepholeChunkArray)]
  [chunk : i64]
  [pending : be_state.CompilerBackendPeepholeLine]
  [next : be_state.CompilerBackendPeepholeLine]) : i64
  ;; lint-allow: nested-if-ladder
  (if (or
    (compiler-backend-peephole-redundant-zext-pair-desc?
      (be_state.compiler-backend-global-shared-view pending)
      (be_state.compiler-backend-global-shared-view next))
    (compiler-backend-peephole-dead-test-after-and-desc? pending next))
    2
    (if (compiler-backend-peephole-flags-branch-desc?
      walk.flags-reg
      pending
      next)
      5
      (if (compiler-backend-peephole-desc-movq?
        (be_state.compiler-backend-global-shared-view pending))
        (if (compiler-backend-peephole-line-self-move-desc?
          (be_state.compiler-backend-global-shared-view pending))
          1
          (if (compiler-backend-peephole-desc-movq?
            (be_state.compiler-backend-global-shared-view next))
            (let
              [pd : (Ptr u8) pending.data]
              [nd : (Ptr u8) next.data]
              [pss : i64 (compiler-backend-peephole-desc-op-src-start pending)]
              [pse : i64 (compiler-backend-peephole-desc-op-src-end pending)]
              [pds : i64 (compiler-backend-peephole-desc-op-dst-start pending)]
              [pde : i64 (compiler-backend-peephole-desc-op-dst-end pending)]
              [nss : i64 (compiler-backend-peephole-desc-op-src-start next)]
              [nse : i64 (compiler-backend-peephole-desc-op-src-end next)]
              [nds : i64 (compiler-backend-peephole-desc-op-dst-start next)]
              [nde : i64 (compiler-backend-peephole-desc-op-dst-end next)]
              [psf : i64 (compiler-backend-peephole-desc-op-src-flags pending)]
              [pdf : i64 (compiler-backend-peephole-desc-op-dst-flags pending)]
              [nsf : i64 (compiler-backend-peephole-desc-op-src-flags next)]
              [ndf : i64 (compiler-backend-peephole-desc-op-dst-flags next)]
              (cond
                [(and
                    (compiler-backend-peephole-op-flag?
                      psf
                      compiler-backend-peephole-op-register-flag)
                    (compiler-backend-peephole-op-flag?
                      pdf
                      compiler-backend-peephole-op-local-frame-flag)
                    (compiler-backend-peephole-op-flag?
                      nsf
                      compiler-backend-peephole-op-register-flag)
                    (compiler-backend-peephole-op-flag?
                      ndf
                      compiler-backend-peephole-op-local-frame-flag)
                    (be_operand.compiler-backend-peephole-ranges-eq?
                      pd
                      pds
                      pde
                      nd
                      nds
                      nde))
                  1]
                [(and
                    (not (= (bit-and psf 3) 0))
                    (not (= (bit-and pdf 3) 0))
                    (not (= (bit-and nsf 3) 0))
                    (not (= (bit-and ndf 3) 0))
                    (or
                      (and
                        (be_operand.compiler-backend-peephole-ranges-eq?
                          pd
                          pss
                          pse
                          nd
                          nss
                          nse)
                        (be_operand.compiler-backend-peephole-ranges-eq?
                          pd
                          pds
                          pde
                          nd
                          nds
                          nde))
                      (and
                        (be_operand.compiler-backend-peephole-ranges-eq?
                          pd
                          pds
                          pde
                          nd
                          nss
                          nse)
                        (be_operand.compiler-backend-peephole-ranges-eq?
                          pd
                          pss
                          pse
                          nd
                          nds
                          nde))))
                  2]
                [(and
                    (compiler-backend-peephole-op-flag?
                      psf
                      compiler-backend-peephole-op-register-flag)
                    (compiler-backend-peephole-op-flag?
                      pdf
                      compiler-backend-peephole-op-local-frame-flag)
                    (compiler-backend-peephole-op-flag?
                      nsf
                      compiler-backend-peephole-op-local-frame-flag)
                    (compiler-backend-peephole-op-flag?
                      ndf
                      compiler-backend-peephole-op-register-flag)
                    (be_operand.compiler-backend-peephole-ranges-eq?
                      pd
                      pds
                      pde
                      nd
                      nss
                      nse))
                  3]
                [(and
                    (compiler-backend-peephole-op-flag?
                      psf
                      compiler-backend-peephole-op-register-flag)
                    (not
                      (be_operand.compiler-backend-peephole-range-eq?
                        pd
                        pss
                        pse
                        "%r10"))
                    (not
                      (be_operand.compiler-backend-peephole-range-eq?
                        pd
                        pss
                        pse
                        "%rbp"))
                    (= (compiler-backend-peephole-desc-op-dst-reg pending) 8)
                    (compiler-backend-peephole-op-flag?
                      nsf
                      compiler-backend-peephole-op-r10-base-flag)
                    (compiler-backend-peephole-op-flag?
                      ndf
                      compiler-backend-peephole-op-register-flag)
                    (or
                      (= (compiler-backend-peephole-desc-op-dst-reg next) 8)
                      (let
                        [nend : i64 (compiler-backend-peephole-desc-end next)]
                        [nlen : i64
                          (string.string-length (array-ref chunks.items chunk))]
                        (compiler-backend-peephole-r10-dead-after-desc?
                          (be_state.CompilerBackendState
                            walk.backend-state-address)
                          (be_state.CompilerBackendStreamState
                            walk.stream-address)
                          chunks
                          chunk
                          (if (< nend nlen)
                            (+ nend 1)
                            nend)))))
                  4]
                ;; P22-A2: dead definition. `movq SRC, %rX` immediately followed
                ;; by `movq SRC2, %rX` that does not read %rX rewrites the whole
                ;; 64-bit register before anything can observe the first value, so
                ;; the first line is dead and is dropped (action 1). Nothing may
                ;; sit between the two lines -- the pair rules only see textually
                ;; adjacent lines -- and `movq` touches no flags, so the drop has
                ;; no other effect. `desc-op-dst-reg` is the dense OWNER index, so
                ;; %rbp/%rsp/%xmm destinations classify to -1 and are excluded, and
                ;; the mention scan maps sub-register reads to their 64-bit parent.
                ;; The dropped line's owner transfer is skipped with it, which is
                ;; exactly right: it would have set owners[%rX] and the surviving
                ;; line overwrites that same entry.
                [(and
                    (>= (compiler-backend-peephole-desc-op-dst-reg pending) 0)
                    (=
                      (compiler-backend-peephole-desc-op-dst-reg next)
                      (compiler-backend-peephole-desc-op-dst-reg pending))
                    (not
                      (compiler-backend-peephole-range-mentions-reg-index?
                        nd
                        nss
                        nse
                        (compiler-backend-peephole-desc-op-dst-reg pending))))
                  1]
                [else 0]))
            0))
        0))))

(define (compiler-backend-peephole-forward-frame-load-line-desc
  [pending : be_state.CompilerBackendPeepholeLine]
  [next : be_state.CompilerBackendPeepholeLine]) : String
  (if (and
    (compiler-backend-peephole-desc-movq?
      (be_state.compiler-backend-global-shared-view pending))
    (compiler-backend-peephole-desc-movq?
      (be_state.compiler-backend-global-shared-view next)))
    (str_cat.str-cat
      "    movq "
      (compiler-backend-peephole-line-op-src-text pending)
      ", "
      (compiler-backend-peephole-line-op-dst-text next))
    (compiler-backend-peephole-line-text next)))

(define (compiler-backend-peephole-r10-base-fold-line-desc
  [pending : be_state.CompilerBackendPeepholeLine]
  [next : be_state.CompilerBackendPeepholeLine]) : String
  (if (and
    (compiler-backend-peephole-desc-movq?
      (be_state.compiler-backend-global-shared-view pending))
    (compiler-backend-peephole-desc-movq?
      (be_state.compiler-backend-global-shared-view next)))
    (str_cat.str-cat
      "    movq "
      (compiler-backend-peephole-r10-base-rewrite
        (compiler-backend-peephole-line-op-src-text next)
        (compiler-backend-peephole-line-op-src-text pending))
      ", "
      (compiler-backend-peephole-line-op-dst-text next))
    (compiler-backend-peephole-line-text next)))

;; Emit one line as a RECORD. Identical rule semantics to the text emitter this
;; replaces: an elided reload pushes nothing, a reload rewritten onto a register
;; that already owns the slot pushes the synthesized `movq %rY, DST` line (whose
;; own sweep summary is extracted by the owned-line builder), everything else
;; pushes the parsed record unchanged.
(define (compiler-backend-peephole-emit-movq-line-desc-record
  [walk : (&mut walk CompilerBackendPeepholeWalkState)]
  [line : be_state.CompilerBackendPeepholeLine]
  [owners : be_state.CompilerBackendPeepholeOwners]) : be_state.CompilerBackendPeepholeOwners
  (let
    [src-reg : i64 (compiler-backend-peephole-desc-op-src-reg line)]
    [dst-reg : i64 (compiler-backend-peephole-desc-op-dst-reg line)]
    [src-key : i64 line.op-src-key]
    [dst-key : i64 line.op-dst-key]
    [is-slot : bool (compiler-backend-peephole-owner-key-known? src-key)]
    [dst-owns : bool
      (and
        is-slot
        (compiler-backend-peephole-owner-key-eq?
          (compiler-backend-peephole-owners-get-index owners dst-reg)
          src-key))]
    ;; P22-A1: dead spill store. `movq %rX, SLOT` where the owner map already
    ;; records %rX as mirroring SLOT writes back the value SLOT already holds,
    ;; so the store is a no-op. The invariant is exactly the one the reload
    ;; elision above relies on: an owner entry survives only while neither the
    ;; register nor the location has been written since the mirror was
    ;; established (a location write runs `owners-clear-extent`, a register write
    ;; clears that register, a call keeps only stack owners in callee-saved
    ;; registers), so `owners[%rX] == SLOT` means memory at SLOT equals %rX.
    ;; Restricted to packed stack keys, matching the store arm of the owner
    ;; transfer: a global (SYM(%rip)) destination clears the whole map there
    ;; and is deliberately not elided here either. This is what removes the
    ;; emergency-scavenge `restore ... resave` pairs, which are separated by
    ;; carry-safe block labels and so are invisible to the adjacent pair rules.
    [src-mirrors-dst : bool
      (and
        (>= src-reg 0)
        (compiler-backend-peephole-owner-key-stack? dst-key)
        (compiler-backend-peephole-owner-key-eq?
          (compiler-backend-peephole-owners-get-index owners src-reg)
          dst-key))]
    [ry : String
      (if (and is-slot (not dst-owns) (>= dst-reg 0))
        (compiler-backend-peephole-owners-find-reg-for-slot-index
          owners
          src-key
          dst-reg)
        "")]
    [_pushed : unit
      (cond
        [dst-owns unit]
        [src-mirrors-dst unit]
        [(not (string.eq ry ""))
          (compiler-backend-peephole-records-push!
            walk
            (compiler-backend-peephole-owned-line
              (be_state.CompilerBackendState walk.backend-state-address)
              (be_state.CompilerBackendStreamState walk.stream-address)
              (str_cat.str-cat
                "    movq "
                ry
                ", "
                (compiler-backend-peephole-line-op-dst-text line))
              (compiler-backend-peephole-desc-newline? line)))]
        [else (compiler-backend-peephole-records-push! walk line)])]
    (compiler-backend-peephole-movq-owners-transfer-keyed-index
      owners
      src-reg
      dst-reg
      src-key
      dst-key)))

;; Keep the common non-move path in its caller: it only appends the parsed
;; record and applies the owner transition. Move rewrites stay in the helper
;; above so their larger rule body is emitted once.
(defmacro (compiler-backend-peephole-emit-line-desc-record
  [walk : Expr]
  [line : Expr]
  [owners : Expr]
  [prev-abort : Expr]) : Expr
  `(if (compiler-backend-peephole-desc-movq? ,line)
    (compiler-backend-peephole-emit-movq-line-desc-record
      (&mut ,walk)
      ,line
      ,owners)
    (begin
      (compiler-backend-peephole-records-push! (&mut ,walk) ,line)
      (compiler-backend-peephole-line-clobber-owners-desc
        (& (__tl-project-field-name ,walk "carry-safe"))
        ,owners
        ,line
        ,prev-abort))))

(define (compiler-backend-peephole-chunk-newline-terminated? [chunk : String]) : bool
  (let
    [n : i64 (string.string-length chunk)]
    (and (> n 0) (= (string.string-ref chunk (- n 1)) '\n'))))

;; How many chunks continue an assembly line into their successor. Zero for
;; every group the backend emits (each chunk is one whole function text), so
;; this pass is the invariant check that keeps the walk render-free.
(define (compiler-backend-peephole-chunks-split-line-count
  [items : (__tl_dyn-array String)]
  [count : i64]) : i64
  (let
    [split : i64 0]
    (for [k (iterator.range 0 (- count 1))]
      (unless
        (compiler-backend-peephole-chunk-newline-terminated?
          (be_state.compiler-backend-global-array-element-shared-view items k))
        (+= split 1)))
    split))

;; Join any run of chunks that a line spans into one chunk, so the walk holds a
;; single invariant: a line is always contained in the chunk it starts in. The
;; join allocates only when a caller appended a partial line.
(define (compiler-backend-peephole-chunks-normalize
  [items : (__tl_dyn-array String)]
  [count : i64]
  [total : i64]) : be_state.CompilerBackendPeepholeChunkArray
  (let
    [split : i64
      (compiler-backend-peephole-chunks-split-line-count
        (be_state.compiler-backend-global-shared-view items)
        count)]
    (if (= split 0)
      (be_state.CompilerBackendPeepholeChunkArray items count total)
      (let
        [joined : (__tl_dyn-array String)
          (__tl_make-array String (- count split))]
        [w : i64 0]
        [k : i64 0]
        (while (< k count)
          (let
            [buf : text_buf.TextBuf
              (text_buf.append
                (text_buf.empty)
                (be_state.compiler-backend-global-array-element-shared-view
                  items
                  k))]
            (while (and
              (< k (- count 1))
              (not
                (compiler-backend-peephole-chunk-newline-terminated?
                  (be_state.compiler-backend-global-array-element-shared-view
                    items
                    k))))
              (+= k 1)
              (set!
                buf
                (text_buf.append
                  buf
                  (be_state.compiler-backend-global-array-element-shared-view
                    items
                    k))))
            (set! (array-ref joined w) (text_buf.render buf))
            (+= w 1)
            (+= k 1)))
        (be_state.CompilerBackendPeepholeChunkArray joined w total)))))

;; Materialize a group's physical chunks in emission order. The chunk Strings
;; themselves are borrowed, not copied: the peephole parses them in place.
(define (compiler-backend-peephole-chunk-array [group : text_buf.TextBuf]) : be_state.CompilerBackendPeepholeChunkArray
  (let
    [chunks : text_buf.TextBufChunkList group.chunks]
    [count : i64 (text_buf.chunk-count (& chunks) 0)]
    [items : (__tl_dyn-array String) (__tl_make-array String count)]
    (text_buf.chunks-fill-array-rev chunks (&mut items) (- count 1))
    (compiler-backend-peephole-chunks-normalize items count group.len)))

;; One String holding one chunk's worth of assembly, wrapped as a chunk array
;; so the whole-string peephole entry points share the chunk walk.
(define (compiler-backend-peephole-single-chunk-array [asm : String]) : be_state.CompilerBackendPeepholeChunkArray
  (let
    [items : (__tl_dyn-array String) (__tl_make-array String 1)]
    (set!
      (array-ref items 0)
      (be_state.compiler-backend-global-shared-view asm))
    (be_state.CompilerBackendPeepholeChunkArray
      items
      1
      (string.string-length asm))))

;; Rendered byte count of the surviving records: each keeps its own source
;; range plus its newline.
(define (compiler-backend-peephole-records-length
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]) : i64
  (let
    [recs : (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord) v.lines]
    [live : (__tl_dyn-array i64) v.live]
    [count : i64 v.len]
    [total : i64 0]
    (for [i (iterator.range 0 count)]
      (when
        (= (array-ref live i) 1)
        (let
          [rec : be_state.CompilerBackendPeepholeLineRecord
            (be_state.compiler-backend-global-array-element-shared-view recs i)]
          (+=
            total
            (+
              (-
                (compiler-backend-peephole-record-end rec)
                (compiler-backend-peephole-record-start rec))
              (if (compiler-backend-peephole-record-newline? rec)
                1
                0))))))
    total))

;; Copy the surviving records into `dst`. Adjacent survivors that are contiguous
;; in the same source string are copied as one run, so a group the sweep did not
;; touch still renders as a single copy of its range, without building a chunk
;; list.
(define (compiler-backend-peephole-records-blit!
  [v : be_state.CompilerBackendPeepholeLineVec]
  [dst : (MutPtr u8)]) : unit
  (let
    [count : i64 v.len]
    (compiler-backend-peephole-records-blit-range! v 0 count dst 0)
    unit))

;; Copy the surviving records of [lo, hi) into `dst` at `out-pos`; the next
;; free position is returned.
(define (compiler-backend-peephole-records-blit-range!
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [lo : i64]
  [count : i64]
  [dst : (MutPtr u8)]
  [start-pos : i64]) : i64
  (let
    [recs : (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord) v.lines]
    [live : (__tl_dyn-array i64) v.live]
    [out-pos : i64 start-pos]
    [run-active : bool false]
    [run-data : (Ptr u8)
      (unsafe
        (string-data ""))]
    [run-addr : u64
      (unsafe
        (ptr->int (string-data "")))]
    [run-start : i64 0]
    [run-end : i64 0]
    (for [i (iterator.range lo count)]
      (when
        (= (array-ref live i) 1)
        (let
          [rec : be_state.CompilerBackendPeepholeLineRecord
            (be_state.compiler-backend-global-array-element-shared-view recs i)]
          [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
          [addr : u64
            (unsafe
              (ptr->int data))]
          [start : i64 (compiler-backend-peephole-record-start rec)]
          [end : i64 (compiler-backend-peephole-record-end rec)]
          [newline? : bool (compiler-backend-peephole-record-newline? rec)]
          [owned? : bool (compiler-backend-peephole-record-owned? rec)]
          [hi : i64
            (if (and newline? (not owned?))
              (+ end 1)
              end)]
          (if (and run-active (= addr run-addr) (= start run-end))
            (set! run-end hi)
            (begin
              (when
                run-active
                (text_buf_borrowed.copy-byte-range-into
                  run-data
                  run-start
                  (- run-end run-start)
                  dst
                  out-pos)
                (+= out-pos (- run-end run-start)))
              (set! run-active true)
              (set! run-data data)
              (set! run-addr addr)
              (set! run-start start)
              (set! run-end hi)))
          (when
            (and newline? owned?)
            (text_buf_borrowed.copy-byte-range-into
              run-data
              run-start
              (- run-end run-start)
              dst
              out-pos)
            (+= out-pos (- run-end run-start))
            (unsafe
              (ptr-write! (ptr-offset dst out-pos) (cast 10 : u8)))
            (+= out-pos 1)
            (set! run-active false)))))
    (when
      run-active
      (text_buf_borrowed.copy-byte-range-into
        run-data
        run-start
        (- run-end run-start)
        dst
        out-pos)
      (+= out-pos (- run-end run-start)))
    out-pos))

;; The single render of the group: one allocation in the active arena, then the
;; surviving records' bytes blitted straight in. Records carry their own source
;; string, so the group never has to be flattened first.
;; These edits run after the last alias analysis. A stack pointer already
;; materialized by LEA can encode a later reference more cheaply. Keep it
;; only inside a straight-line run and stop at unknown instructions or any
;; mention of its register, including subregister writes.
(define (compiler-backend-peephole-stack-address-cost
  [offset : i64]
  [sib? : bool]
  [zero-disp? : bool]) : i64
  (+
    (if sib?
      1
      0)
    (cond
      [(and (= offset 0) (not zero-disp?)) 0]
      [(and (>= offset -128) (<= offset 127)) 1]
      [else 4])))

(define (compiler-backend-peephole-stack-address-barrier?
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]
  [flags : i64]) : bool
  (or
    (!=
      (compiler-backend-peephole-record-kind rec)
      compiler-backend-sweep-line-kind-instruction)
    (!=
      (bit-and
        flags
        (bit-or
          compiler-backend-sweep-line-flag-bare-rsp
          compiler-backend-sweep-line-flag-bare-rsp-tail))
      0)))

(define (compiler-backend-peephole-compact-stack-address-window!
  [records : (&mut records be_state.CompilerBackendPeepholeLineVec)]
  [index : i64]) : unit
  (let
    [anchor : (& records be_state.CompilerBackendPeepholeLineRecord)
      (& (array-ref records.lines index))]
    (when
      (compiler-backend-peephole-stack-address-barrier?
        anchor
        (compiler-backend-peephole-record-flags anchor))
      (return unit))
    (let
      [data : (Ptr u8) (compiler-backend-peephole-record-data anchor)]
      [ms : i64 (compiler-backend-peephole-record-mnemonic-start anchor)]
      [end-of-anchor : i64 (compiler-backend-peephole-record-end anchor)]
      [comma : i64
        (compiler-backend-peephole-find-comma-space-range data ms end-of-anchor)]
      (when
        (or
          (< comma 0)
          (<=
            (compiler-backend-peephole-stack-destination-key
              data
              (+ ms 4)
              comma)
            0))
        (return unit))
      (let
        [reg-start : i64 (+ comma 2)]
        [base : i64
          (compiler-backend-peephole-token-reg-index-range
            data
            reg-start
            end-of-anchor)]
        [bias : i64 anchor.value]
        (when (< base 0) (return unit))
        (for [i (iterator.range (+ index 1) records.len)]
          (when
            (= (array-ref records.live i) 1)
            (let
              [rec : (& records be_state.CompilerBackendPeepholeLineRecord)
                (& (array-ref records.lines i))]
              [flags : i64 (compiler-backend-peephole-record-flags rec)]
              ;; A simple LEA always ends this window, even if its operand
              ;; spelling or destination prevents it from opening a new one.
              (when
                (or
                  (compiler-backend-peephole-stack-address-barrier? rec flags)
                  (compiler-backend-peephole-simple-stack-lea? rec.meta))
                (return unit))
              (let
                [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
                [end : i64 (compiler-backend-peephole-record-end rec)]
                [ms : i64 (compiler-backend-peephole-record-mnemonic-start rec)]
                [mention? : bool
                  (compiler-backend-peephole-range-mentions-reg-index?
                    data
                    ms
                    end
                    base)]
                (if (and
                  (<= (+ ms 5) end)
                  (be_operand.compiler-backend-peephole-range-eq?
                    data
                    ms
                    (+ ms 5)
                    "movq "))
                  (begin
                    (when
                      (and
                        (= (compiler-backend-peephole-record-mem-count rec) 1)
                        (=
                          (bit-and
                            flags
                            compiler-backend-sweep-line-flag-fatal-mem)
                          0))
                      (let
                        [disp : i64 (- rec.value bias)]
                        (when
                          (and
                            (be_operand.compiler-backend-imm32? disp)
                            (<
                              (compiler-backend-peephole-stack-address-cost
                                disp
                                (= base 10)
                                (= base 11))
                              (compiler-backend-peephole-stack-address-cost
                                rec.value
                                true
                                false)))
                          (let
                            [base-text : String
                              (string.substring
                                (array-ref records.lines index).src
                                reg-start
                                (- end-of-anchor reg-start))]
                            [text : String
                              (compiler-backend-peephole-rewrite-stack-address
                                rec
                                (compiler-backend-peephole-record-start rec)
                                end
                                ms
                                disp
                                base-text)]
                            (unless
                              (string.eq text "")
                              (let
                                [span : i64
                                  (shl (string.string-length text) 32)]
                                (set!
                                  (array-ref records.lines i)
                                  (be_state.CompilerBackendPeepholeLineRecord
                                    text
                                    span
                                    (bit-or
                                      rec.meta
                                      compiler-backend-peephole-record-owned-bit)
                                    rec.cand
                                    rec.epilogue
                                    rec.value))))))))
                    (when mention? (return unit)))
                  (let
                    [space : i64
                      (be_operand.compiler-backend-peephole-scan-byte-range
                        data
                        ms
                        end
                        32)]
                    (unless
                      (and
                        (not mention?)
                        (>=
                          (compiler-backend-peephole-last-operand-reg-index
                            data
                            space
                            end)
                          0)
                        (compiler-backend-peephole-mnemonic-single-dest?
                          data
                          ms
                          (- space ms)))
                      (return unit))))))))))))

(define (compiler-backend-peephole-compact-stack-addresses!
  [records : (&mut records be_state.CompilerBackendPeepholeLineVec)]) : unit
  (for [i (iterator.range 0 records.stack-lea-cand-len)]
    (let
      [index : i64 (array-ref records.stack-lea-cands i)]
      (when
        (= (array-ref records.live index) 1)
        (compiler-backend-peephole-compact-stack-address-window! records index)))))

(define (compiler-backend-peephole-rewrite-stack-address
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]
  [start : i64]
  [end : i64]
  [ms : i64]
  [disp : i64]
  [base : String]) : String
  (let
    [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
    [paren : i64
      (be_operand.compiler-backend-peephole-scan-byte-range data ms end 40)]
    (when
      (and
        (<= (+ paren 6) end)
        (be_operand.compiler-backend-peephole-range-eq?
          data
          paren
          (+ paren 6)
          "(%rsp)"))
      (let
        [first : i64 (compiler-backend-rsp-rebase-int-start data ms paren)]
        [from : i64
          (if (>= first 0)
            first
            paren)]
        (when
          (and
            (> from ms)
            (= (be_state.compiler-backend-peephole-byte-at data (- from 1)) 32))
          (return
            (str_cat.str-cat
              (string.substring rec.src start (- from start))
              (be_operand.compiler-backend-mem-base-address disp base)
              (string.substring rec.src (+ paren 6) (- end (+ paren 6))))))))
    ""))

(define (compiler-backend-peephole-records-render-plain
  [v : be_state.CompilerBackendPeepholeLineVec]) : String
  (let
    [total : i64 (compiler-backend-peephole-records-length v)]
    (if (= total 0)
      ""
      (let
        [out : (__tl_dyn-array u8) (__tl_make-array u8 total)]
        [dst : (MutPtr u8)
          (unsafe
            (__tl_array-data out))]
        (compiler-backend-peephole-records-blit! v dst)
        (unsafe
          (string-from-bytes (ptr-cast dst : (Ptr u8)) total))))))

;; ---------------------------------------------------------------------------
;; COLD-1: move runtime abort stubs out of the hot path.
;;
;; Every checked operation the emitter lowers -- a bounds check, a division's
;; zero and overflow guards, a shift-count guard -- is spelled as a conditional
;; jump OVER an inline call to a noreturn runtime abort helper:
;;
;;       cmpq %r9, %rdi                       cmpq %r9, %rdi
;;       jb .Lf27_bounds_ok.3                 jae .Lf27_bounds_ok.3.cold
;;       pushq %r9                          .Lf27_bounds_ok.3:
;;       ...                                  ...
;;       call .L_tl_abort_tl_oob_abort_at      (last line of the function body)
;;     .L_tl_abort_site_1_bounds:             .Lf27_bounds_ok.3.cold:
;;       .tl_abort_row ...                    ...
;;     .Lf27_bounds_ok.3:                     call .L_tl_abort_tl_oob_abort_at
;;                                          .L_tl_abort_site_1_bounds:
;;                                            .tl_abort_row ...
;;
;; Inline, every passed check costs a TAKEN branch and leaves 40-80 bytes of
;; never-executed code between two hot instructions, which
;; spreads a loop over more fetch blocks, i-cache lines and uop-cache ways. This
;; is the placement LLVM gives a noreturn path (cold-block placement): out of
;; line, so the passing check falls through, not-taken, into the next hot
;; instruction. The executed instruction count is unchanged; only the order of
;; the text is.
;;
;; The rewrite runs at render time, after every peephole, sweep and fold has
;; finished with the record stream, so no textual analysis ever sees the new
;; order. It preserves semantics by construction: the inverted jump reaches the
;; stub under exactly the condition that falls into it inline. The stub runs
;; with the same registers and stack and the abort call has no return edge.
;;
;; A stub moves only when the records between the jump and its target label are
;; all stub-shaped: at least one noreturn abort call
;; (`compiler-backend-peephole-line-noreturn-abort?`), no other call, no `ret`,
;; no jump, and no label except the stub's own `.L_tl_abort_site_` return
;; address labels. The row directive and operand staging comment travel with
;; the stub. Position-dependent directives (`.loc`, CFI, SEH) stay in place. The moved stub
;; is named after its unique continuation label (`T.cold`); a stub that closes
;; at a numeric `1:` is named after its unique abort-site label instead, keeps
;; `1:` in place for any other `1f` that targets it, and returns through a
;; named `.back` label beside it. A numeric-target stub without a site label
;; (the location-free helpers) is named after the closest preceding named label
;; `L` and its ordinal among the stubs since `L`: `L.stub1.cold`, `L.stub2.cold`,
;; ... returning through `L.stub1.back`, ...
;;
;; Stubs are appended before the function's first closing line (`.size`,
;; `.cfi_endproc`, `.seh_endproc`, the debug or backtrace end label) so they
;; stay inside the function's symbol, unwind and backtrace ranges; a following
;; `.globl`, or the end of the group, flushes anything still pending. The only
;; CFI this backend emits sits in the prologue, so the frame rule at the end of
;; the body is the one every moved stub already ran under. Each moved stub is
;; prefixed with the `.loc`/`.cv_loc` line that was in force at its jump, so a
;; debug line table attributes it to its check rather than to the function's
;; last statement.
;;
;; Stubs of one function whose whole body is the same argument-free abort call
;; (`call tl_oob_abort`, `tl_div_abort`, ...) are emitted once: every such check
;; jumps to the first one's label (`compiler-backend-cold-shared-body`). The
;; body runs the same instruction from any check, and the shared stub stays
;; inside the function, so only the never-used return address differs. A stub
;; with staged arguments, a site row or a `.loc` line keeps its own.
(define compiler-backend-cold-stub-scan-limit : i64
  48)

;; Instructions a stub may stage before its abort call (arguments, pushes, the
;; site address, Win64 call space).
(define compiler-backend-cold-stub-setup-limit : i64
  12)

;; How far back a stub looks for the label that names it, or for the `.loc`
;; line in force at its check.
(define compiler-backend-cold-label-scan-limit : i64
  4096)

;; First non-space byte of the record's line, or its end.
(define (compiler-backend-cold-line-first
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : i64
  (if (and
    ;; The emitter's four-space instruction indent, decided in two loads.
    (< (+ start 4) end)
    (= (be_state.compiler-backend-peephole-byte-at data start) 32)
    (= (be_state.compiler-backend-peephole-byte-at data (+ start 3)) 32)
    (not (= (be_state.compiler-backend-peephole-byte-at data (+ start 4)) 32))
    (= (be_state.compiler-backend-peephole-byte-at data (+ start 1)) 32)
    (= (be_state.compiler-backend-peephole-byte-at data (+ start 2)) 32))
    (+ start 4)
    (let
      [i : i64 start]
      (while (and
        (< i end)
        (= (be_state.compiler-backend-peephole-byte-at data i) 32))
        (+= i 1))
      i)))

;; End of the line with trailing spaces removed.
(define (compiler-backend-cold-line-last
  [data : (Ptr u8)]
  [first : i64]
  [end : i64]) : i64
  (let
    [e : i64 end]
    (while (and
      (> e first)
      (= (be_state.compiler-backend-peephole-byte-at data (- e 1)) 32))
      (-= e 1))
    e))

;; End of the first space-delimited token starting at `first`.
(define (compiler-backend-cold-token-end
  [data : (Ptr u8)]
  [first : i64]
  [end : i64]) : i64
  (let
    [i : i64 first]
    (while (and
      (< i end)
      (not (= (be_state.compiler-backend-peephole-byte-at data i) 32)))
      (+= i 1))
    i))

(define (compiler-backend-cold-prefix?
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]
  [lit : String]) : bool
  (let
    [n : i64 (string.string-length lit)]
    (and
      (<= (+ s n) e)
      (be_operand.compiler-backend-peephole-range-eq? data s (+ s n) lit))))

;; A label line: unindented and colon-terminated.
(define (compiler-backend-cold-label-line?
  [data : (Ptr u8)]
  [start : i64]
  [first : i64]
  [last : i64]) : bool
  (and
    (= first start)
    (> last first)
    (= (be_state.compiler-backend-peephole-byte-at data (- last 1)) 58)))

;; The inverse of a conditional-jump mnemonic, or "" when the mnemonic is not a
;; flag-condition jump this pass knows how to invert (`jmp`, `jrcxz`, ...).
(define (compiler-backend-cold-jcc-inverse
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : String
  (let
    [n : i64 (- e s)]
    [c1 : i64
      (if (> n 1)
        (be_state.compiler-backend-peephole-byte-at data (+ s 1))
        0)]
    [c2 : i64
      (if (> n 2)
        (be_state.compiler-backend-peephole-byte-at data (+ s 2))
        0)]
    [c3 : i64
      (if (> n 3)
        (be_state.compiler-backend-peephole-byte-at data (+ s 3))
        0)]
    (cond
      [(or (< n 2) (> n 4)) ""]
      ;; `jn<cc>`: the positive condition, or its named synonym.
      [(and (= c1 110) (= n 3))
        (cond
          [(= c2 101) "je"]
          [(= c2 122) "jz"]
          [(= c2 98) "jb"]
          [(= c2 99) "jc"]
          [(= c2 97) "ja"]
          [(= c2 108) "jl"]
          [(= c2 103) "jg"]
          [(= c2 115) "js"]
          [(= c2 111) "jo"]
          [(= c2 112) "jp"]
          [else ""])]
      [(and (= c1 110) (= n 4))
        (cond
          [(and (= c2 97) (= c3 101)) "jae"]
          [(and (= c2 98) (= c3 101)) "jbe"]
          [(and (= c2 103) (= c3 101)) "jge"]
          [(and (= c2 108) (= c3 101)) "jle"]
          [else ""])]
      [(= n 2)
        (cond
          [(= c1 101) "jne"]
          [(= c1 122) "jnz"]
          [(= c1 98) "jae"]
          [(= c1 99) "jnc"]
          [(= c1 97) "jbe"]
          [(= c1 108) "jge"]
          [(= c1 103) "jle"]
          [(= c1 115) "jns"]
          [(= c1 111) "jno"]
          [(= c1 112) "jnp"]
          [else ""])]
      ;; three letters, second is `e`: `jae` `jbe` `jge` `jle` `jpe`
      [(and (= n 3) (= c2 101))
        (cond
          [(= c1 97) "jb"]
          [(= c1 98) "ja"]
          [(= c1 103) "jl"]
          [(= c1 108) "jg"]
          [(= c1 112) "jpo"]
          [else ""])]
      [(and (= n 3) (= c1 112) (= c2 111)) "jpe"]
      [else ""])))

;; A line that closes the current function's text: stubs must land before it.
;; Dispatches on the bytes after the `.` first, since every block label also
;; starts with one.
(define (compiler-backend-cold-closing-line?
  [data : (Ptr u8)]
  [start : i64]
  [first : i64]
  [last : i64]) : bool
  (let
    [b1 : i64
      (if (< (+ first 2) last)
        (be_state.compiler-backend-peephole-byte-at data (+ first 1))
        0)]
    [b2 : i64
      (if (< (+ first 2) last)
        (be_state.compiler-backend-peephole-byte-at data (+ first 2))
        0)]
    (cond
      [(= b1 115)
        (or
          (compiler-backend-cold-prefix? data first last ".size ")
          (compiler-backend-cold-prefix? data first last ".seh_endproc"))]
      [(= b1 99) (compiler-backend-cold-prefix? data first last ".cfi_endproc")]
      [(= b1 103) (compiler-backend-cold-prefix? data first last ".globl ")]
      [(and (= b1 76) (= first start))
        (cond
          [(= b2 99)
            (compiler-backend-cold-prefix? data first last ".Lcv_func_end_")]
          [(= b2 95)
            (compiler-backend-cold-prefix?
              data
              first
              last
              ".L_tl_backtrace_function_end_")]
          [else false])]
      [else false])))

(define (compiler-backend-cold-loc-line?
  [data : (Ptr u8)]
  [first : i64]
  [last : i64]) : bool
  (or
    (compiler-backend-cold-prefix? data first last ".loc ")
    (compiler-backend-cold-prefix? data first last ".cv_loc ")))

;; Index of the live record holding the continuation label that closes the
;; abort stub opened by the conditional jump at live record `i`, or -1 when the
;; records after it are not a movable stub (see COLD-1 above).
(define (compiler-backend-cold-stub-scan
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [i : i64]) : i64
  (let
    [recs : (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord) v.lines]
    [live : (__tl_dyn-array i64) v.live]
    [count : i64 v.len]
    [jrec : be_state.CompilerBackendPeepholeLineRecord
      (be_state.compiler-backend-global-array-element-shared-view recs i)]
    [jdata : (Ptr u8) (compiler-backend-peephole-record-data jrec)]
    [jstart : i64 (compiler-backend-peephole-record-start jrec)]
    [jend : i64 (compiler-backend-peephole-record-end jrec)]
    [jfirst : i64 (compiler-backend-cold-line-first jdata jstart jend)]
    [jlast : i64 (compiler-backend-cold-line-last jdata jfirst jend)]
    [mend : i64 (compiler-backend-cold-token-end jdata jfirst jlast)]
    [tfirst : i64 (compiler-backend-cold-line-first jdata mend jlast)]
    (if (or
      (= jfirst jstart)
      (>= jfirst jlast)
      (not (= (be_state.compiler-backend-peephole-byte-at jdata jfirst) 106))
      (=
        (string.string-length
          (compiler-backend-cold-jcc-inverse jdata jfirst mend))
        0)
      (>= tfirst jlast)
      (not (= (compiler-backend-cold-token-end jdata tfirst jlast) jlast)))
      (- 0 1)
      (let
        [numeric? : bool
          (be_operand.compiler-backend-peephole-range-eq?
            jdata
            tfirst
            jlast
            "1f")]
        [j : i64 (+ i 1)]
        [limit : i64 (+ i compiler-backend-cold-stub-scan-limit)]
        [saw-abort : bool false]
        [setup : i64 0]
        [result : i64 (- 0 2)]
        (while (and (= result (- 0 2)) (< j count))
          (if (>= j limit)
            (set! result (- 0 1))
            (begin
              (when
                (= (array-ref live j) 1)
                (let
                  [rec : be_state.CompilerBackendPeepholeLineRecord
                    (be_state.compiler-backend-global-array-element-shared-view
                      recs
                      j)]
                  [kind : i64 (compiler-backend-peephole-record-kind rec)]
                  [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
                  [start : i64 (compiler-backend-peephole-record-start rec)]
                  [end : i64 (compiler-backend-peephole-record-end rec)]
                  (cond
                    [(= kind compiler-backend-sweep-line-kind-label)
                      (let
                        [last : i64
                          (compiler-backend-cold-line-last data start end)]
                        (cond
                          [(if numeric?
                              (be_operand.compiler-backend-peephole-range-eq?
                                data
                                start
                                last
                                "1:")
                              (and
                                (> last start)
                                (be_operand.compiler-backend-peephole-ranges-eq?
                                  data
                                  start
                                  (- last 1)
                                  jdata
                                  tfirst
                                  jlast)))
                            (set!
                              result
                              (if saw-abort
                                j
                                (- 0 1)))]
                          [(compiler-backend-cold-prefix?
                              data
                              start
                              last
                              ".L_tl_abort_site_")
                            unit]
                          [else (set! result (- 0 1))]))]
                    [(= kind compiler-backend-sweep-line-kind-instruction)
                      (let
                        [first : i64
                          (compiler-backend-cold-line-first data start end)]
                        [lead : i64
                          (if (< first end)
                            (be_state.compiler-backend-peephole-byte-at
                              data
                              first)
                            0)]
                        (cond
                          ;; `c`: only a noreturn abort call belongs in a stub.
                          [(= lead 99)
                            (let
                              [last : i64
                                (compiler-backend-cold-line-last data first end)]
                              (cond
                                [(compiler-backend-peephole-line-noreturn-abort?
                                    data
                                    first
                                    last)
                                  (set! saw-abort true)]
                                [(compiler-backend-cold-prefix?
                                    data
                                    first
                                    last
                                    "call")
                                  (set! result (- 0 1))]
                                [else unit]))]
                          [(or
                              (= lead 106)
                              (and
                                (= lead 114)
                                (compiler-backend-cold-prefix?
                                  data
                                  first
                                  end
                                  "ret")))
                            (set! result (- 0 1))]
                          ;; A stub stages at most a handful of abort arguments
                          ;; before its call; a longer run is ordinary code.
                          [saw-abort unit]
                          [(>= setup compiler-backend-cold-stub-setup-limit)
                            (set! result (- 0 1))]
                          [else (+= setup 1)]))]
                    [else
                      (let
                        [first : i64
                          (compiler-backend-cold-line-first data start end)]
                        [last : i64
                          (compiler-backend-cold-line-last data first end)]
                        (if (or
                          (>= first last)
                          (compiler-backend-cold-prefix?
                            data
                            first
                            last
                            "# tl_abort_operand_stage")
                          (and
                            saw-abort
                            (compiler-backend-cold-prefix?
                              data
                              first
                              last
                              ".tl_abort_row ")))
                          unit
                          (set! result (- 0 1))))])))
              (+= j 1))))
        (if (< result 0)
          (- 0 1)
          result)))))

;; Name the moved stub. A named continuation label `T` gives `T.cold`. A
;; numeric `1:` continuation gives the stub's first `.L_tl_abort_site_` label
;; plus `.cold`, or "" when the stub has none.
(define (compiler-backend-cold-stub-name
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [i : i64]
  [t : i64]) : String
  (let
    [recs : (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord) v.lines]
    [live : (__tl_dyn-array i64) v.live]
    [trec : be_state.CompilerBackendPeepholeLineRecord
      (be_state.compiler-backend-global-array-element-shared-view recs t)]
    [tdata : (Ptr u8) (compiler-backend-peephole-record-data trec)]
    [tstart : i64 (compiler-backend-peephole-record-start trec)]
    [tend : i64 (compiler-backend-peephole-record-end trec)]
    [tlast : i64 (compiler-backend-cold-line-last tdata tstart tend)]
    (if (not
      (be_operand.compiler-backend-peephole-range-eq? tdata tstart tlast "1:"))
      (string.substring trec.src tstart (- tlast (+ tstart 1)))
      (let
        [j : i64 (+ i 1)]
        [name : String ""]
        (while (and (< j t) (= (string.string-length name) 0))
          (when
            (= (array-ref live j) 1)
            (let
              [rec : be_state.CompilerBackendPeepholeLineRecord
                (be_state.compiler-backend-global-array-element-shared-view
                  recs
                  j)]
              [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
              [start : i64 (compiler-backend-peephole-record-start rec)]
              [end : i64 (compiler-backend-peephole-record-end rec)]
              [last : i64 (compiler-backend-cold-line-last data start end)]
              (when
                (and
                  (compiler-backend-cold-label-line? data start start last)
                  (compiler-backend-cold-prefix?
                    data
                    start
                    last
                    ".L_tl_abort_site_"))
                (set!
                  name
                  (string.substring rec.src start (- last (+ start 1)))))))
          (+= j 1))
        name))))

;; The edits COLD-1 makes to one group, in record order. Stub `k` opens with the
;; conditional jump at record `jcc[k]` and closes at the continuation label at
;; record `target[k]`; `inverse[k]` replaces the jump, `back[k]` (numeric
;; continuations only, else "") is emitted before the kept `1:`, and at the
;; next flush point the stub is emitted as `head[k]`, the `.loc` record
;; `loc[k]` (or none when -1), records (jcc[k], target[k]) and `tail[k]`. A
;; flush point `flush-at[f]` emits stubs up to `flush-end[f]` right before that
;; record; stubs still pending at the end of the group follow its last record.
;; `extra` is the rendered byte count the edits add to the plain render.
(defstruct CompilerBackendColdPlan
  (stubs i64)
  (jcc (__tl_dyn-array i64))
  (target (__tl_dyn-array i64))
  (loc (__tl_dyn-array i64))
  (inverse (__tl_dyn-array String))
  (head (__tl_dyn-array String))
  ;; -1, or the earlier stub of the same function whose identical body this
  ;; stub's jump reaches instead of emitting its own (`compiler-backend-cold-
  ;; shared-body`).
  (share (__tl_dyn-array i64))
  (flushes i64)
  (flush-at (__tl_dyn-array i64))
  (flush-end (__tl_dyn-array i64))
  (extra i64))

(define (compiler-backend-cold-plan-empty) : CompilerBackendColdPlan
  (CompilerBackendColdPlan
    0
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array String 0)
    (__tl_make-array String 0)
    (__tl_make-array i64 0)
    0
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    0))

(define (compiler-backend-cold-grow-i64
  [items : (__tl_dyn-array i64)]
  [len : i64]) : (__tl_dyn-array i64)
  (if (< len (array-length items))
    items
    (let
      [fresh : (__tl_dyn-array i64)
        (__tl_make-array i64 (+ (* (array-length items) 2) 8))]
      (for [k (iterator.range 0 len)]
        (set! (array-ref fresh k) (array-ref items k)))
      fresh)))

(define (compiler-backend-cold-grow-strings
  [items : (__tl_dyn-array String)]
  [len : i64]) : (__tl_dyn-array String)
  (if (< len (array-length items))
    items
    (let
      [fresh : (__tl_dyn-array String)
        (__tl_make-array String (+ (* (array-length items) 2) 8))]
      (for [k (iterator.range 0 len)]
        (set!
          (array-ref fresh k)
          (owned_view.compiler-owned-element-view items k)))
      fresh)))

;; Rendered bytes of one record: its line plus the newline it carries.
(define (compiler-backend-cold-record-bytes
  [rec : be_state.CompilerBackendPeepholeLineRecord]) : i64
  (+
    (-
      (compiler-backend-peephole-record-end rec)
      (compiler-backend-peephole-record-start rec))
    (if (compiler-backend-peephole-record-newline? rec)
      1
      0)))

;; COLD-1 candidate: the record index of a noreturn abort call. Grown like
;; RMW-2's candidate array: empty until a group has one.
(define (compiler-backend-cold-note-abort!
  [walk : (&mut walk CompilerBackendPeepholeWalkState)]
  [index : i64]) : unit
  (unless
    (< walk.abort-cand-len (array-length walk.abort-cands))
    (let
      [old : (__tl_dyn-array i64) walk.abort-cands]
      [len : i64 walk.abort-cand-len]
      [grown : (__tl_dyn-array i64)
        (__tl_make-array i64 (+ (* (array-length old) 2) 16))]
      (for [k (iterator.range 0 len)]
        (set! (array-ref grown k) (array-ref old k)))
      (set! walk.abort-cands grown)))
  (set! (array-ref walk.abort-cands walk.abort-cand-len) index)
  (+= walk.abort-cand-len 1))

;; COLD-1 candidate: the record index of a line that closes a function. Only a
;; line whose first byte is `.` is examined further.
(define (compiler-backend-cold-note-closing!
  [walk : (&mut walk CompilerBackendPeepholeWalkState)]
  [line : (& line be_state.CompilerBackendPeepholeLine)]
  [index : i64]) : unit
  (let
    [data : (Ptr u8) line.data]
    [start : i64 (bit-and line.span compiler-backend-peephole-desc-pack-mask)]
    [end : i64
      (bit-and
        (shr line.span compiler-backend-peephole-desc-pack-shift)
        compiler-backend-peephole-desc-pack-mask)]
    [first : i64
      (bit-and line.mnemonic compiler-backend-peephole-desc-pack-mask)]
    (when
      (and
        (< first end)
        (= (be_state.compiler-backend-peephole-byte-at data first) 46)
        (compiler-backend-cold-closing-line?
          data
          start
          first
          (compiler-backend-cold-line-last data first end)))
      (unless
        (< walk.close-cand-len (array-length walk.close-cands))
        (let
          [old : (__tl_dyn-array i64) walk.close-cands]
          [len : i64 walk.close-cand-len]
          [grown : (__tl_dyn-array i64)
            (__tl_make-array i64 (+ (* (array-length old) 2) 16))]
          (for [k (iterator.range 0 len)]
            (set! (array-ref grown k) (array-ref old k)))
          (set! walk.close-cands grown)))
      (set! (array-ref walk.close-cands walk.close-cand-len) index)
      (+= walk.close-cand-len 1))))

;; The conditional jump that opens the stub whose abort call is record `call`:
;; walking back over the call's argument staging -- live instructions that are
;; not jumps, calls or returns, at most compiler-backend-cold-stub-setup-limit
;; of them -- the first record must be that jump. -1 otherwise.
(define (compiler-backend-cold-stub-jump
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [call : i64]) : i64
  (let
    [recs : (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord) v.lines]
    [live : (__tl_dyn-array i64) v.live]
    [j : i64 (- call 1)]
    [setup : i64 0]
    [result : i64 (- 0 2)]
    (while (= result (- 0 2))
      (cond
        [(< j 0) (set! result (- 0 1))]
        [(not (= (array-ref live j) 1)) (-= j 1)]
        [else
          (let
            [rec : be_state.CompilerBackendPeepholeLineRecord
              (be_state.compiler-backend-global-array-element-shared-view
                recs
                j)]
            [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
            [start : i64 (compiler-backend-peephole-record-start rec)]
            [end : i64 (compiler-backend-peephole-record-end rec)]
            [first : i64 (compiler-backend-cold-line-first data start end)]
            [lead : i64
              (if (< first end)
                (be_state.compiler-backend-peephole-byte-at data first)
                0)]
            (cond
              [(compiler-backend-cold-prefix?
                  data
                  first
                  end
                  "# tl_abort_operand_stage")
                (-= j 1)]
              [(not
                  (=
                    (compiler-backend-peephole-record-kind rec)
                    compiler-backend-sweep-line-kind-instruction))
                (set! result (- 0 1))]
              [(= lead 106)
                (set!
                  result
                  (if (be_operand.compiler-backend-peephole-range-eq?
                    data
                    first
                    (compiler-backend-cold-token-end data first end)
                    "jmp")
                    (- 0 1)
                    j))]
              [(or
                  (= lead 99)
                  (= lead 114)
                  (>= setup compiler-backend-cold-stub-setup-limit))
                (set! result (- 0 1))]
              [else
                (+= setup 1)
                (-= j 1)]))]))
    result))

;; The closest live named label (not the numeric `1:`) before record `j`, or
;; -1 within compiler-backend-cold-label-scan-limit records.
(define (compiler-backend-cold-label-before
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [j : i64]) : i64
  (let
    [recs : (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord) v.lines]
    [live : (__tl_dyn-array i64) v.live]
    [k : i64 (- j 1)]
    [stop : i64 (- j compiler-backend-cold-label-scan-limit)]
    [result : i64 (- 0 2)]
    (while (= result (- 0 2))
      (if (or (< k 0) (< k stop))
        (set! result (- 0 1))
        (let
          [rec : be_state.CompilerBackendPeepholeLineRecord
            (be_state.compiler-backend-global-array-element-shared-view recs k)]
          (when
            (and
              (= (array-ref live k) 1)
              (=
                (compiler-backend-peephole-record-kind rec)
                compiler-backend-sweep-line-kind-label))
            (let
              [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
              [start : i64 (compiler-backend-peephole-record-start rec)]
              [last : i64
                (compiler-backend-cold-line-last
                  data
                  start
                  (compiler-backend-peephole-record-end rec))]
              (when
                (and
                  (compiler-backend-cold-label-line? data start start last)
                  (not
                    (be_operand.compiler-backend-peephole-range-eq?
                      data
                      start
                      last
                      "1:")))
                (set! result k))))
          (-= k 1))))
    result))

;; The `.loc`/`.cv_loc` line in force at record `j`: the closest one before it
;; in the same function, or -1. Only a debug build carries such lines.
(define (compiler-backend-cold-loc-before
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [j : i64]) : i64
  (if (not (compiler_ir_types.compiler-debug-info-enabled?))
    (- 0 1)
    (let
      [recs : (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord)
        v.lines]
      [live : (__tl_dyn-array i64) v.live]
      [k : i64 (- j 1)]
      [stop : i64 (- j compiler-backend-cold-label-scan-limit)]
      [result : i64 (- 0 2)]
      (while (= result (- 0 2))
        (if (or (< k 0) (< k stop))
          (set! result (- 0 1))
          (let
            [rec : be_state.CompilerBackendPeepholeLineRecord
              (be_state.compiler-backend-global-array-element-shared-view
                recs
                k)]
            (when
              (and
                (= (array-ref live k) 1)
                (not
                  (=
                    (compiler-backend-peephole-record-kind rec)
                    compiler-backend-sweep-line-kind-instruction)))
              (let
                [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
                [start : i64 (compiler-backend-peephole-record-start rec)]
                [end : i64 (compiler-backend-peephole-record-end rec)]
                [first : i64 (compiler-backend-cold-line-first data start end)]
                [last : i64 (compiler-backend-cold-line-last data first end)]
                (cond
                  [(compiler-backend-cold-loc-line? data first last)
                    (set! result k)]
                  [(compiler-backend-cold-closing-line? data start first last)
                    (set! result (- 0 1))]
                  [else unit])))
            (-= k 1))))
      result)))

;; Kind 0..4 for an argument-free abort call (`call [.L_tl_abort_]tl_*_abort`),
;; or -1 otherwise.
(define (compiler-backend-cold-argless-abort-kind
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : i64
  (let
    [first : i64 (compiler-backend-cold-line-first data s e)]
    [last : i64 (compiler-backend-cold-line-last data first e)]
    (if (not (compiler-backend-cold-prefix? data first last "call "))
      -1
      (let
        [callee : i64
          (if (compiler-backend-cold-prefix?
            data
            first
            last
            "call .L_tl_abort_")
            (+ first 17)
            (+ first 5))]
        (cond
          [(be_operand.compiler-backend-peephole-range-eq?
              data
              callee
              last
              "tl_oob_abort")
            0]
          [(be_operand.compiler-backend-peephole-range-eq?
              data
              callee
              last
              "tl_shift_abort")
            1]
          [(be_operand.compiler-backend-peephole-range-eq?
              data
              callee
              last
              "tl_div_abort")
            2]
          [(be_operand.compiler-backend-peephole-range-eq?
              data
              callee
              last
              "tl_region_abort")
            3]
          [(be_operand.compiler-backend-peephole-range-eq?
              data
              callee
              last
              "tl_oom_abort")
            4]
          [else -1])))))

;; The body of the stub between jump `j` and continuation `t` when it is one
;; argument-free abort call and nothing else, else "". Such a body runs the
;; same instruction whichever check reaches it, so the stubs of one function
;; that share it are emitted once and every check jumps there. A stub that
;; stages arguments, carries a site descriptor or a debug line keeps its own.
(define (compiler-backend-cold-shared-body
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [j : i64]
  [t : i64]) : String
  (let
    [recs : (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord) v.lines]
    [live : (__tl_dyn-array i64) v.live]
    [found : i64 (- 0 1)]
    [count : i64 0]
    [k : i64 (+ j 1)]
    (while (< k t)
      (when (= (array-ref live k) 1) (set! count (+ count 1)) (set! found k))
      (set! k (+ k 1)))
    (if (not (= count 1))
      ""
      (let
        [rec : be_state.CompilerBackendPeepholeLineRecord
          (be_state.compiler-backend-global-array-element-shared-view
            recs
            found)]
        [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
        [start : i64 (compiler-backend-peephole-record-start rec)]
        [end : i64 (compiler-backend-peephole-record-end rec)]
        [first : i64 (compiler-backend-cold-line-first data start end)]
        [last : i64 (compiler-backend-cold-line-last data first end)]
        (if (and
          (=
            (compiler-backend-peephole-record-kind rec)
            compiler-backend-sweep-line-kind-instruction)
          (>= (compiler-backend-cold-argless-abort-kind data first last) 0))
          (string.substring rec.src first (- last first))
          "")))))

;; Plan COLD-1 for one group (see above) from the walk's candidates alone: each
;; abort call locates its stub by a short walk back to the opening jump and a
;; checked walk forward to the continuation, and is flushed before the first
;; closing line after it. Nothing else in the group is examined.
(define (compiler-backend-cold-plan
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]) : CompilerBackendColdPlan
  (let
    [recs : (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord) v.lines]
    [count : i64 v.len]
    [aborts : (__tl_dyn-array i64) v.abort-cands]
    [abort-count : i64 v.abort-cand-len]
    [closes : (__tl_dyn-array i64) v.close-cands]
    [close-count : i64 v.close-cand-len]
    [plan : CompilerBackendColdPlan (compiler-backend-cold-plan-empty)]
    [c : i64 0]
    [done-to : i64 (- 0 1)]
    [pending-at : i64 count]
    [fallback-label : i64 (- 0 1)]
    [fallback-ord : i64 0]
    ;; The shareable bodies of the function whose stubs are pending: the body
    ;; text and the stub that emits it.
    [share-group : i64 (- 0 1)]
    [share-bodies : (__tl_dyn-array String) (__tl_make-array String 0)]
    [share-stubs : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [share-count : i64 0]
    (for [a (iterator.range 0 abort-count)]
      (let
        [call : i64 (array-ref aborts a)]
        (when
          (> call done-to)
          (let
            [j : i64 (compiler-backend-cold-stub-jump v call)]
            [t : i64
              (if (>= j 0)
                (compiler-backend-cold-stub-scan v j)
                (- 0 1))]
            (when
              (> t call)
              (let
                [site-name : String (compiler-backend-cold-stub-name v j t)]
                [label : i64
                  (if (> (string.string-length site-name) 0)
                    (- 0 1)
                    (compiler-backend-cold-label-before v j))]
                [name : String
                  (if (or (> (string.string-length site-name) 0) (< label 0))
                    site-name
                    (let
                      [lrec : be_state.CompilerBackendPeepholeLineRecord
                        (be_state.compiler-backend-global-array-element-shared-view
                          recs
                          label)]
                      [lstart : i64
                        (compiler-backend-peephole-record-start lrec)]
                      [llast : i64
                        (compiler-backend-cold-line-last
                          (compiler-backend-peephole-record-data lrec)
                          lstart
                          (compiler-backend-peephole-record-end lrec))]
                      (if (= label fallback-label)
                        (+= fallback-ord 1)
                        (begin
                          (set! fallback-label label)
                          (set! fallback-ord 1)))
                      (str_cat.str-cat
                        (string.substring
                          lrec.src
                          lstart
                          (- llast (+ lstart 1)))
                        ".stub"
                        (string.int->string fallback-ord))))]
                (when
                  (> (string.string-length name) 0)
                  (let
                    [rec : be_state.CompilerBackendPeepholeLineRecord
                      (be_state.compiler-backend-global-array-element-shared-view
                        recs
                        j)]
                    [data : (Ptr u8)
                      (compiler-backend-peephole-record-data rec)]
                    [start : i64 (compiler-backend-peephole-record-start rec)]
                    [end : i64 (compiler-backend-peephole-record-end rec)]
                    [first : i64
                      (compiler-backend-cold-line-first data start end)]
                    [last : i64
                      (compiler-backend-cold-line-last data first end)]
                    [mend : i64
                      (compiler-backend-cold-token-end data first last)]
                    [cold-label : String (str_cat.str-cat name ".cold")]
                    [inverse : String
                      (str_cat.str-cat
                        "    "
                        (compiler-backend-cold-jcc-inverse data first mend)
                        " "
                        cold-label)]
                    [head : String (str_cat.str-cat cold-label ":")]
                    [loc : i64 (compiler-backend-cold-loc-before v j)]
                    [loc-bytes : i64
                      (if (< loc 0)
                        0
                        (compiler-backend-cold-record-bytes
                          (be_state.compiler-backend-global-array-element-shared-view
                            recs
                            loc)))]
                    [k : i64 plan.stubs]
                    [added : i64
                      (+
                        (-
                          (+ (string.string-length inverse) 1)
                          (compiler-backend-cold-record-bytes rec))
                        (+ (+ (string.string-length head) 1) loc-bytes))]
                    [flush-at : i64 count]
                    ;; This stub's flush point: the first closing line
                    ;; after its continuation.
                    (while (and (< c close-count) (<= (array-ref closes c) t))
                      (+= c 1))
                    (set!
                      flush-at
                      (if (< c close-count)
                        (array-ref closes c)
                        count))
                    ;; Stubs still pending for an earlier function are
                    ;; flushed at that function's closing line.
                    (when
                      (and (> k 0) (not (= flush-at pending-at)))
                      (set!
                        plan.flush-at
                        (compiler-backend-cold-grow-i64
                          plan.flush-at
                          plan.flushes))
                      (set!
                        plan.flush-end
                        (compiler-backend-cold-grow-i64
                          plan.flush-end
                          plan.flushes))
                      (set! (array-ref plan.flush-at plan.flushes) pending-at)
                      (set! (array-ref plan.flush-end plan.flushes) k)
                      (+= plan.flushes 1))
                    (set! pending-at flush-at)
                    (unless
                      (= share-group flush-at)
                      (set! share-group flush-at)
                      (set! share-count 0))
                    (set! plan.jcc (compiler-backend-cold-grow-i64 plan.jcc k))
                    (set!
                      plan.share
                      (compiler-backend-cold-grow-i64 plan.share k))
                    (set! (array-ref plan.share k) (- 0 1))
                    (set!
                      plan.target
                      (compiler-backend-cold-grow-i64 plan.target k))
                    (set! plan.loc (compiler-backend-cold-grow-i64 plan.loc k))
                    (set!
                      plan.inverse
                      (compiler-backend-cold-grow-strings plan.inverse k))
                    (set!
                      plan.head
                      (compiler-backend-cold-grow-strings plan.head k))
                    (set! (array-ref plan.jcc k) j)
                    (set! (array-ref plan.target k) t)
                    (set! (array-ref plan.loc k) loc)
                    (set! (array-ref plan.inverse k) inverse)
                    (set! (array-ref plan.head k) head)
                    (let
                      [body : String
                        (if (< loc 0)
                          (compiler-backend-cold-shared-body v j t)
                          "")]
                      [canonical : i64 (- 0 1)]
                      [s : i64 0]
                      (when
                        (> (string.string-length body) 0)
                        (while (and (< canonical 0) (< s share-count))
                          (when
                            (string.eq
                              (be_state.compiler-backend-global-array-element-shared-view
                                share-bodies
                                s)
                              body)
                            (set! canonical (array-ref share-stubs s)))
                          (set! s (+ s 1)))
                        (if (>= canonical 0)
                          (let
                            ;; Jump to the earlier stub's label; this one adds
                            ;; at most its jump and drops its head and body.
                            [shared-inverse : String
                              (str_cat.str-cat
                                "    "
                                (compiler-backend-cold-jcc-inverse
                                  data
                                  first
                                  mend)
                                " "
                                (string.substring
                                  (be_state.compiler-backend-global-array-element-shared-view
                                    plan.head
                                    canonical)
                                  0
                                  (-
                                    (string.string-length
                                      (be_state.compiler-backend-global-array-element-shared-view
                                        plan.head
                                        canonical))
                                    1)))]
                            (set! (array-ref plan.share k) canonical)
                            (set!
                              plan.extra
                              (+
                                plan.extra
                                (+ (string.string-length shared-inverse) 1)))
                            (set! (array-ref plan.inverse k) shared-inverse))
                          (begin
                            (set!
                              share-bodies
                              (compiler-backend-cold-grow-strings
                                share-bodies
                                share-count))
                            (set!
                              share-stubs
                              (compiler-backend-cold-grow-i64
                                share-stubs
                                share-count))
                            (set! (array-ref share-bodies share-count) body)
                            (set! (array-ref share-stubs share-count) k)
                            (set! share-count (+ share-count 1)))))
                      (when
                        (< canonical 0)
                        (set! plan.extra (+ plan.extra added))))
                    (set! plan.stubs (+ k 1))
                    (set! done-to t)))))))))
    ;; The last group of stubs lands before its function's closing line, or
    ;; after the group's last record when the group has none.
    (when
      (and (> plan.stubs 0) (< pending-at count))
      (set!
        plan.flush-at
        (compiler-backend-cold-grow-i64 plan.flush-at plan.flushes))
      (set!
        plan.flush-end
        (compiler-backend-cold-grow-i64 plan.flush-end plan.flushes))
      (set! (array-ref plan.flush-at plan.flushes) pending-at)
      (set! (array-ref plan.flush-end plan.flushes) plan.stubs)
      (+= plan.flushes 1))
    plan))

;; Write `text` and a newline at `pos`; the next free position is returned.
(define (compiler-backend-cold-write-line!
  [dst : (MutPtr u8)]
  [pos : i64]
  [text : String]) : i64
  (let
    [n : i64 (string.string-length text)]
    (text_buf_borrowed.copy-byte-range-into
      (unsafe
        (string-data text))
      0
      n
      dst
      pos)
    (unsafe
      (ptr-write! (ptr-offset dst (+ pos n)) (cast 10 : u8)))
    (+ pos (+ n 1))))

;; Emit planned stubs [from, to) out of line. Each call and its row move together.
(define (compiler-backend-cold-emit-stubs!
  [v : be_state.CompilerBackendPeepholeLineVec]
  [plan : CompilerBackendColdPlan]
  [from : i64]
  [to : i64]
  [dst : (MutPtr u8)]
  [start-pos : i64]) : i64
  (let
    [pos : i64 start-pos]
    (for [k (iterator.range from to)]
      (let
        [loc : i64 (array-ref plan.loc k)]
        (when
          (< (array-ref plan.share k) 0)
          (set!
            pos
            (compiler-backend-cold-write-line!
              dst
              pos
              (be_state.compiler-backend-global-array-element-shared-view
                plan.head
                k)))
          (when
            (>= loc 0)
            (set!
              pos
              (compiler-backend-peephole-records-blit-range!
                v
                loc
                (+ loc 1)
                dst
                pos)))
          (set!
            pos
            (compiler-backend-peephole-records-blit-range!
              v
              (+ (array-ref plan.jcc k) 1)
              (array-ref plan.target k)
              dst
              pos)))))
    pos))

;; Render the group in COLD-1 order: the plain render's bytes, ranges of
;; records blitted in place, with each stub's jump inverted and the stubs
;; themselves emitted at their flush points.
(define (compiler-backend-cold-render
  [v : be_state.CompilerBackendPeepholeLineVec]
  [plan : CompilerBackendColdPlan]) : String
  (let
    [total : i64 (+ (compiler-backend-peephole-records-length v) plan.extra)]
    [count : i64 v.len]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 total)]
    [dst : (MutPtr u8)
      (unsafe
        (__tl_array-data out))]
    [pos : i64 0]
    [cursor : i64 0]
    [flushed : i64 0]
    [f : i64 0]
    (for [k (iterator.range 0 plan.stubs)]
      (let
        [jcc : i64 (array-ref plan.jcc k)]
        [t : i64 (array-ref plan.target k)]
        (while (and (< f plan.flushes) (<= (array-ref plan.flush-at f) jcc))
          (let
            [at : i64 (array-ref plan.flush-at f)]
            [upto : i64 (array-ref plan.flush-end f)]
            (set!
              pos
              (compiler-backend-peephole-records-blit-range!
                v
                cursor
                at
                dst
                pos))
            (set!
              pos
              (compiler-backend-cold-emit-stubs!
                (be_state.compiler-backend-global-shared-view v)
                (be_state.compiler-backend-global-shared-view plan)
                flushed
                upto
                dst
                pos))
            (set! cursor at)
            (set! flushed upto)
            (+= f 1)))
        (set!
          pos
          (compiler-backend-peephole-records-blit-range! v cursor jcc dst pos))
        (set!
          pos
          (compiler-backend-cold-write-line!
            dst
            pos
            (be_state.compiler-backend-global-array-element-shared-view
              plan.inverse
              k)))
        (set! cursor t)))
    (while (< f plan.flushes)
      (let
        [at : i64 (array-ref plan.flush-at f)]
        [upto : i64 (array-ref plan.flush-end f)]
        (set!
          pos
          (compiler-backend-peephole-records-blit-range! v cursor at dst pos))
        (set!
          pos
          (compiler-backend-cold-emit-stubs!
            (be_state.compiler-backend-global-shared-view v)
            (be_state.compiler-backend-global-shared-view plan)
            flushed
            upto
            dst
            pos))
        (set! cursor at)
        (set! flushed upto)
        (+= f 1)))
    (set!
      pos
      (compiler-backend-peephole-records-blit-range! v cursor count dst pos))
    (set!
      pos
      (compiler-backend-cold-emit-stubs!
        v
        (be_state.compiler-backend-global-shared-view plan)
        flushed
        plan.stubs
        dst
        pos))
    (unsafe
      (string-from-bytes (ptr-cast dst : (Ptr u8)) pos))))

;; Final-record tail merging. Text equality is checked after hashing, and the
;; earlier surviving run always supplies the shared instructions.
(defstruct CompilerBackendTailRun
  (first i64)
  (last i64)
  (label i64)
  (end-hash i64))

(import (vector.vector CompilerBackendTailRun core) as tail_runs)

;; ASCII digits, letters and the emitter's three punctuation bytes in symbols.
(define compiler-backend-tail-symbol-bytes : String
  "00000000000000000000000000000000000010000000001011111111110000000111111111111111111111111110000101111111111111111111111111100000")

(define (compiler-backend-tail-symbol-byte? [b : i64]) : bool
  (and
    (< b 128)
    (=
      (be_state.compiler-backend-peephole-byte-at
        (unsafe
          (string-data compiler-backend-tail-symbol-bytes))
        b)
      49)))

(define (compiler-backend-tail-symbol-end
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : i64
  (let
    [i : i64 start]
    (while (and
      (< i end)
      (compiler-backend-tail-symbol-byte?
        (be_state.compiler-backend-peephole-byte-at data i)))
      (+= i 1))
    i))

;; A direct jmp must name a symbol. Numeric local labels such as 1f acquire a
;; different meaning at another site, even when the two instructions match.
(define (compiler-backend-tail-jmp? [data : (Ptr u8)] [s : i64] [e : i64]) : bool
  (let
    [operand : i64 (+ s 8)]
    (and
      (> e operand)
      (compiler-backend-asm-jmp-prefix-at? data s)
      (let
        [b : i64 (be_state.compiler-backend-peephole-byte-at data operand)]
        (or (< b 48) (> b 57)))
      (= (compiler-backend-tail-symbol-end data operand e) e))))

(define (compiler-backend-tail-abort? [data : (Ptr u8)] [s : i64] [e : i64]) : bool
  (and
    (compiler-backend-cold-prefix? data s e "    call ")
    (>= (compiler-backend-cold-argless-abort-kind data s e) 0)))

(define (compiler-backend-tail-line-hash
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]) : i64
  (let
    [s : i64 (compiler-backend-peephole-record-start rec)]
    (ci.intern-hash-words
      (compiler-backend-peephole-record-data rec)
      s
      (- (compiler-backend-peephole-record-end rec) s))))

(define (compiler-backend-tail-prev-live
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [i : i64]
  [lo : i64]) : i64
  (let
    [prev : i64 (- i 1)]
    (while (and (>= prev lo) (= (array-ref v.live prev) 0))
      (-= prev 1))
    prev))

(define (compiler-backend-tail-lines-eq?
  [x : (& x be_state.CompilerBackendPeepholeLineRecord)]
  [y : (& y be_state.CompilerBackendPeepholeLineRecord)]) : bool
  (be_operand.compiler-backend-peephole-ranges-eq?
    (compiler-backend-peephole-record-data x)
    (compiler-backend-peephole-record-start x)
    (compiler-backend-peephole-record-end x)
    (compiler-backend-peephole-record-data y)
    (compiler-backend-peephole-record-start y)
    (compiler-backend-peephole-record-end y)))

;; Record indices survive all plans, even when the store sweep left holes.
(define (compiler-backend-tail-equal?
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [a : i64]
  [b : i64]
  [last : i64]) : bool
  (let
    [rhs : i64 b]
    (for [lhs (iterator.range a (+ last 1))]
      (when
        (= (array-ref v.live lhs) 1)
        (while (= (array-ref v.live rhs) 0)
          (+= rhs 1))
        (let
          [x : (& v be_state.CompilerBackendPeepholeLineRecord)
            (& (array-ref v.lines lhs))]
          [y : (& v be_state.CompilerBackendPeepholeLineRecord)
            (& (array-ref v.lines rhs))]
          (unless (compiler-backend-tail-lines-eq? x y) (return false)))
        (+= rhs 1)))
    true))

;; Only already-renderable owned records are installed here. The sweeps and
;; cold plan have finished, so the replacement needs only its text and newline.
(define (compiler-backend-tail-replace!
  [v : (&mut v be_state.CompilerBackendPeepholeLineVec)]
  [index : i64]
  [text : String]) : unit
  (let
    [len : i64 (string.string-length text)]
    [meta : i64
      (bit-or
        compiler-backend-peephole-record-owned-bit
        (bit-and
          (array-ref v.lines index).meta
          compiler-backend-peephole-record-newline-bit))]
    (set!
      (array-ref v.lines index)
      (be_state.CompilerBackendPeepholeLineRecord
        text
        (shl len compiler-backend-peephole-record-span-shift)
        meta
        0
        0
        0))))

;; A lower bound on encoded size, including a possible rel8 jump. MOV
;; immediates and displaced qword memory operands give stronger bounds than
;; the register forms, so can pay for a replacement jump even in a two-line tail.
(define (compiler-backend-tail-insn-bytes [data : (Ptr u8)] [s : i64] [e : i64]) : i64
  (let
    [imm? : bool
      (and
        (< (+ s 9) e)
        (= (be_state.compiler-backend-peephole-byte-at data (+ s 9)) 36))]
    (cond
      [(compiler-backend-cold-prefix? data s e "    movabsq ") 10]
      [(and imm? (compiler-backend-cold-prefix? data s e "    movq ")) 7]
      [(or
          (compiler-backend-cold-prefix? data s e "    movq ")
          (compiler-backend-cold-prefix? data s e "    leaq "))
        (let
          [paren : i64
            (be_operand.compiler-backend-peephole-scan-byte-range
              data
              (+ s 9)
              e
              40)]
          (if (>= paren e)
            3
            (let
              [disp : i64
                (compiler-backend-rsp-rebase-int-start data (+ s 9) paren)]
              (if (or
                (compiler-backend-cold-prefix? data paren e "(%rsp")
                (compiler-backend-cold-prefix? data paren e "(%rbp")
                (compiler-backend-cold-prefix? data paren e "(%r12")
                (compiler-backend-cold-prefix? data paren e "(%r13")
                (and
                  (>= disp 0)
                  (!= (compiler-backend-rsp-rebase-parse-int data disp paren) 0)))
                4
                3))))]
      [(compiler-backend-cold-prefix? data s e "    movl ")
        (if imm?
          5
          2)]
      [else 1])))

(define (compiler-backend-tail-eligible-insn?
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]) : bool
  (let
    [s : i64 (compiler-backend-peephole-record-start rec)]
    [e : i64 (compiler-backend-peephole-record-end rec)]
    [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
    (when
      (or
        (<= e (+ s 4))
        (!=
          (unsafe
            (ptr-read (ptr-cast (ptr-offset data s) : (Ptr i32))))
          538976288))
      (return false))
    (let
      [head : i64 (be_state.compiler-backend-peephole-byte-at data (+ s 4))]
      (and
        ;; A bare dot is position dependent. Dot-based symbols are kept in
        ;; place as well.
        (!= head 32)
        (>=
          (be_operand.compiler-backend-peephole-scan-byte-range data s e 46)
          e)
        (cond
          [(= head 108)
            (not
              (or
                (compiler-backend-cold-prefix? data (+ s 4) e "loop")
                (compiler-backend-cold-prefix? data (+ s 4) e "lret")))]
          [(= head 105)
            (not
              (or
                (compiler-backend-cold-prefix? data (+ s 4) e "int")
                (compiler-backend-cold-prefix? data (+ s 4) e "iret")))]
          [(= head 115)
            (not (compiler-backend-cold-prefix? data (+ s 4) e "sys"))]
          [else true])))))

;; A body is fingerprinted backwards so the same recurrence can identify its
;; whole block and every proper suffix.
(define (compiler-backend-tail-extend-hash
  [hash : i64]
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]) : i64
  (bit-xor (* hash 1000003) (compiler-backend-tail-line-hash rec)))

(define (compiler-backend-tail-alias-label?
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [index : i64]
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : bool
  (let
    [label : (& v be_state.CompilerBackendPeepholeLineRecord)
      (& (array-ref v.lines index))]
    (be_operand.compiler-backend-peephole-ranges-eq?
      data
      s
      e
      (compiler-backend-peephole-record-data label)
      (compiler-backend-peephole-record-start label)
      (- (compiler-backend-peephole-record-end label) 1))))

(define (compiler-backend-tail-label-text
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [index : i64]) : String
  (let
    [label : (& v be_state.CompilerBackendPeepholeLineRecord)
      (& (array-ref v.lines index))]
    [s : i64 (compiler-backend-peephole-record-start label)]
    (string.substring
      label.src
      s
      (- (compiler-backend-peephole-record-end label) (+ s 1)))))

;; Inspect every reference to a proposed alias. A bare operand of a direct
;; branch can be rewritten. All other references pin the definition, including
;; RIP-relative addresses, table entries and assembler/debug expressions.
(define (compiler-backend-tail-alias-refs!
  [v : (&mut v be_state.CompilerBackendPeepholeLineVec)]
  [aliases : (& aliases backend_label_i64_map.Map)]
  [redirects : (&mut redirects (__tl_dyn-array i64))]
  [lo : i64]
  [hi : i64]
  [home : arena.Arena]
  [rewrite? : bool]) : unit
  (for [i (iterator.range lo hi)]
    (when
      (= (array-ref v.live i) 1)
      (let
        [replacement : String ""]
        (let
          [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
            (& (array-ref v.lines i))]
          [kind : i64 (compiler-backend-peephole-record-kind rec)]
          [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
          [s : i64 (compiler-backend-peephole-record-start rec)]
          [e : i64 (compiler-backend-peephole-record-end rec)]
          (unless
            (= kind compiler-backend-sweep-line-kind-label)
            (let
              [dot : i64
                (be_operand.compiler-backend-peephole-scan-byte-range
                  data
                  s
                  e
                  46)]
              (while (< (+ dot 2) e)
                (when
                  (compiler-backend-layout-local-label? data dot e)
                  (let
                    [end : i64 (compiler-backend-tail-symbol-end data dot e)]
                    [key : i64 (compiler-backend-layout-hash data dot end)]
                    [index : i64
                      (backend_label_i64_map.get-value-or aliases key -1)]
                    (when
                      (and
                        (>= index lo)
                        (> (array-ref redirects (- index lo)) 0)
                        (compiler-backend-tail-alias-label?
                          v
                          index
                          data
                          dot
                          end))
                      (let
                        [flags : i64
                          (if (and
                            (= end e)
                            (=
                              kind
                              compiler-backend-sweep-line-kind-instruction))
                            (compiler-backend-layout-classify-line data s e)
                            0)]
                        [branch? : bool
                          (and
                            (not (= (bit-and flags 6) 0))
                            (=
                              (+
                                s
                                (shr
                                  flags
                                  compiler-backend-layout-flag-ops-shift))
                              dot))]
                        (cond
                          [(and rewrite? branch?)
                            (set!
                              replacement
                              (unsafe
                                (in-arena
                                  (arena.Arena (arena.raw-handle home))
                                  (let
                                    [target : i64
                                      (- (array-ref redirects (- index lo)) 1)]
                                    (str_cat.str-cat
                                      (string.substring rec.src s (- dot s))
                                      (compiler-backend-tail-label-text
                                        v
                                        target))))))]
                          [else
                            (unless
                              branch?
                              (set! (array-ref redirects (- index lo)) 0))])))
                    (set! dot (- end 1))))
                (set!
                  dot
                  (be_operand.compiler-backend-peephole-scan-byte-range
                    data
                    (+ dot 1)
                    e
                    46))))))
        (unless
          (string.eq (& replacement) "")
          (compiler-backend-tail-replace! v i replacement))))))

(define (compiler-backend-tail-whole-blocks!
  [v : (&mut v be_state.CompilerBackendPeepholeLineVec)]
  [runs : (& runs tail_runs.Vec)]
  [ends : (& ends backend_label_i64_map.Map)]
  [lo : i64]
  [hi : i64]
  [home : arena.Arena]) : unit
  (let
    [bodies : backend_label_i64_map.Map (backend_label_i64_map.with-capacity 8)]
    [aliases : backend_label_i64_map.Map
      (backend_label_i64_map.with-capacity 8)]
    [redirects : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    (for [k (iterator.range 0 runs.len)]
      (let
        [run : CompilerBackendTailRun (array-ref (tail_runs.slots runs) k)]
        (when
          (and
            (>= run.label lo)
            (> (backend_label_i64_map.get-value-or ends run.end-hash 0) 1))
          (let
            [hash : i64 run.end-hash]
            [i : i64 (compiler-backend-tail-prev-live v run.last run.first)]
            (while (>= i run.first)
              (set!
                hash
                (compiler-backend-tail-extend-hash
                  hash
                  (& (array-ref v.lines i))))
              (set! i (compiler-backend-tail-prev-live v i run.first)))
            (when
              (< i run.first)
              (let
                [prev : i64
                  (backend_label_i64_map.get-value-or (& bodies) hash -1)]
                (if (< prev 0)
                  (backend_label_i64_map.insert-ref! (&mut bodies) hash k)
                  (let
                    [canonical : CompilerBackendTailRun
                      (array-ref (tail_runs.slots runs) prev)]
                    (when
                      (compiler-backend-tail-equal?
                        v
                        run.first
                        canonical.first
                        run.last)
                      (let
                        [label : (&
                          v
                          be_state.CompilerBackendPeepholeLineRecord)
                          (& (array-ref v.lines run.label))]
                        [key : i64
                          (compiler-backend-layout-hash
                            (compiler-backend-peephole-record-data label)
                            (compiler-backend-peephole-record-start label)
                            (- (compiler-backend-peephole-record-end label) 1))]
                        (when
                          (= (array-length redirects) 0)
                          (set! redirects (__tl_make-array i64 (- hi lo))))
                        (when
                          (<
                            (backend_label_i64_map.get-value-or
                              (& aliases)
                              key
                              -1)
                            0)
                          (backend_label_i64_map.insert-ref!
                            (&mut aliases)
                            key
                            run.label)
                          (set!
                            (array-ref redirects (- run.label lo))
                            (+ canonical.label 1)))))))))))))
    (unless
      (= (array-length redirects) 0)
      (compiler-backend-tail-alias-refs!
        v
        (& aliases)
        (&mut redirects)
        lo
        hi
        home
        false)
      (compiler-backend-tail-alias-refs!
        v
        (& aliases)
        (&mut redirects)
        lo
        hi
        home
        true)
      (for [run (tail_runs.view runs)]
        (when
          (and (>= run.label lo) (> (array-ref redirects (- run.label lo)) 0))
          (for [i (iterator.range run.label (+ run.last 1))]
            (set! (array-ref v.live i) 0)))))))

(define (compiler-backend-tail-suffix-name
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [anchor : i64]
  [canonical : i64]) : String
  (str_cat.str-cat
    ".L_tail_"
    (compiler-backend-tail-label-text v anchor)
    "."
    (string.int->string (- canonical anchor))))

(define (compiler-backend-tail-share-suffix!
  [v : (&mut v be_state.CompilerBackendPeepholeLineVec)]
  [first : i64]
  [last : i64]
  [canonical : i64]
  [anchor : i64]
  [home : arena.Arena]) : unit
  (unsafe
    (in-arena
      (arena.Arena (arena.raw-handle home))
      (let
        [name : String (compiler-backend-tail-suffix-name v anchor canonical)]
        (compiler-backend-tail-replace!
          v
          first
          (str_cat.str-cat "    jmp " name)))))
  (for [i (iterator.range (+ first 1) (+ last 1))]
    (set! (array-ref v.live i) 0)))

(define (compiler-backend-tail-emit-suffix-label!
  [v : (&mut v be_state.CompilerBackendPeepholeLineVec)]
  [anchor : i64]
  [canonical : i64]
  [home : arena.Arena]) : unit
  (unsafe
    (in-arena
      (arena.Arena (arena.raw-handle home))
      (let
        [text : String
          (let
            [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
              (& (array-ref v.lines canonical))]
            [s : i64 (compiler-backend-peephole-record-start rec)]
            [name : String
              (compiler-backend-tail-suffix-name v anchor canonical)]
            (str_cat.str-cat
              name
              ":\n"
              (string.substring
                rec.src
                s
                (- (compiler-backend-peephole-record-end rec) s))))]
        (compiler-backend-tail-replace! v canonical text)))))

;; A branch tail can share instructions with the fallthrough into its
;; destination. The replacement jump is then the only jump it executes.
;; An explicit final jump that already targets the immediately following label
;; is also a fallthrough host once that jump is removed.
(define (compiler-backend-tail-match-fallthrough
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [run : (& run CompilerBackendTailRun)]
  [targets : (& targets backend_label_i64_map.Map)]
  [anchor : i64]) : (Tuple i64 i64 i64)
  (let
    [term : (& v be_state.CompilerBackendPeepholeLineRecord)
      (& (array-ref v.lines run.last))]
    [data : (Ptr u8) (compiler-backend-peephole-record-data term)]
    [s : i64 (+ (compiler-backend-peephole-record-start term) 8)]
    [e : i64 (compiler-backend-peephole-record-end term)]
    [target : i64
      (backend_label_i64_map.get-value-or
        targets
        (compiler-backend-layout-hash data s e)
        -1)]
    (when
      (or
        (<= target anchor)
        (not (compiler-backend-tail-alias-label? v target data s e)))
      (return (tuple -1 -1 -1)))
    (let
      [host : i64 (compiler-backend-tail-prev-live v target anchor)]
      [drop : i64 -1]
      [left : i64 (compiler-backend-tail-prev-live v run.last run.first)]
      [right : i64 host]
      [bytes : i64 2]
      [first : i64 -1]
      [canonical : i64 -1]
      (when (= host run.last) (return (tuple -1 -1 -1)))
      (when
        (compiler-backend-tail-lines-eq? term (& (array-ref v.lines host)))
        (set! drop host)
        (set! right (compiler-backend-tail-prev-live v host anchor)))
      (while (and (>= left run.first) (>= right anchor))
        (let
          [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
            (& (array-ref v.lines left))]
          (unless
            (and
              (compiler-backend-tail-eligible-insn? rec)
              (compiler-backend-tail-lines-eq?
                rec
                (& (array-ref v.lines right))))
            (break))
          (+=
            bytes
            (compiler-backend-tail-insn-bytes
              (compiler-backend-peephole-record-data rec)
              (compiler-backend-peephole-record-start rec)
              (compiler-backend-peephole-record-end rec)))
          (when (> bytes 5) (set! first left) (set! canonical right)))
        (set! left (compiler-backend-tail-prev-live v left run.first))
        (set! right (compiler-backend-tail-prev-live v right anchor)))
      (tuple first canonical drop))))

(define (compiler-backend-tail-index-targets
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [labels : (& labels (__tl_dyn-array i64))]
  [count : i64]) : backend_label_i64_map.Map
  (let
    [targets : backend_label_i64_map.Map
      (backend_label_i64_map.with-capacity count)]
    (for [k (iterator.range 0 count)]
      (let
        [index : i64 (array-ref labels k)]
        [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
          (& (array-ref v.lines index))]
        (when
          (= (array-ref v.live index) 1)
          (backend_label_i64_map.insert-ref!
            (&mut targets)
            (compiler-backend-layout-hash
              (compiler-backend-peephole-record-data rec)
              (compiler-backend-peephole-record-start rec)
              (- (compiler-backend-peephole-record-end rec) 1))
            index))))
    targets))

(define (compiler-backend-tail-suffixes!
  [v : (&mut v be_state.CompilerBackendPeepholeLineVec)]
  [runs : (& runs tail_runs.Vec)]
  [ends : (& ends backend_label_i64_map.Map)]
  [targets : (& targets backend_label_i64_map.Map)]
  [anchor : i64]
  [hi : i64]
  [home : arena.Arena]) : unit
  (let
    [suffixes : backend_label_i64_map.Map
      (backend_label_i64_map.with-capacity 8)]
    [labels : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    (for [run (tail_runs.view runs)]
      (when
        (and
          (> run.last run.first)
          (= (array-ref v.live run.last) 1)
          (> (backend_label_i64_map.get-value-or ends run.end-hash 0) 1))
        (let
          [term : (& v be_state.CompilerBackendPeepholeLineRecord)
            (& (array-ref v.lines run.last))]
          [jump? : bool
            (=
              (be_state.compiler-backend-peephole-byte-at
                (compiler-backend-peephole-record-data term)
                (+ (compiler-backend-peephole-record-start term) 4))
              106)]
          (if jump?
            (let
              [matched-run : (Tuple i64 i64 i64)
                (compiler-backend-tail-match-fallthrough v run targets anchor)]
              [first : i64 (tuple-ref matched-run 0)]
              [canonical : i64 (tuple-ref matched-run 1)]
              [drop : i64 (tuple-ref matched-run 2)]
              (when
                (>= first 0)
                (when
                  (= (array-length labels) 0)
                  (set! labels (__tl_make-array i64 (- hi anchor))))
                (set! (array-ref labels (- canonical anchor)) 1)
                (when (>= drop 0) (set! (array-ref labels (- drop anchor)) 2))
                (compiler-backend-tail-share-suffix!
                  v
                  first
                  run.last
                  canonical
                  anchor
                  home)))
            (let
              [hash : i64 run.end-hash]
              ;; Abort paths have no return edge and can always share a copy.
              [bytes : i64 5]
              [matched : i64 -1]
              [canonical : i64 -1]
              [i : i64 (compiler-backend-tail-prev-live v run.last run.first)]
              [oldest : i64 i]
              (while (>= i run.first)
                (let
                  [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
                    (& (array-ref v.lines i))]
                  (+=
                    bytes
                    (compiler-backend-tail-insn-bytes
                      (compiler-backend-peephole-record-data rec)
                      (compiler-backend-peephole-record-start rec)
                      (compiler-backend-peephole-record-end rec)))
                  (set! hash (compiler-backend-tail-extend-hash hash rec))
                  (when
                    (> bytes 5)
                    (let
                      [prev : i64
                        (backend_label_i64_map.get-value-or
                          (& suffixes)
                          hash
                          -1)]
                      (when (>= prev 0) (set! matched i) (set! canonical prev))))
                  (set! i (compiler-backend-tail-prev-live v i run.first))))
              (if (and
                (>= matched 0)
                (compiler-backend-tail-equal? v matched canonical run.last))
                (begin
                  (when
                    (= (array-length labels) 0)
                    (set! labels (__tl_make-array i64 (- hi anchor))))
                  (set! (array-ref labels (- canonical anchor)) 1)
                  (compiler-backend-tail-share-suffix!
                    v
                    matched
                    run.last
                    canonical
                    anchor
                    home))
                (let
                  [key : i64 run.end-hash]
                  [at : i64 oldest]
                  ;; Publish only runs that retain their entire suffix. The first
                  ;; definition remains canonical even after a label is emitted.
                  (while (> at i)
                    (set!
                      key
                      (compiler-backend-tail-extend-hash
                        key
                        (& (array-ref v.lines at))))
                    (when
                      (<
                        (backend_label_i64_map.get-value-or (& suffixes) key -1)
                        0)
                      (backend_label_i64_map.insert-ref! (&mut suffixes) key at))
                    (set! at (compiler-backend-tail-prev-live v at run.first))))))))))
    (for [i (iterator.range 0 (array-length labels))]
      (cond
        [(= (array-ref labels i) 1)
          (compiler-backend-tail-emit-suffix-label! v anchor (+ anchor i) home)]
        [(= (array-ref labels i) 2) (set! (array-ref v.live (+ anchor i)) 0)]
        [else unit]))))

;; Walk backwards only for a repeated terminator, stopping at the first live
;; line that cannot be part of its straight-line suffix.
(define (compiler-backend-tail-resolve-run
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [run : CompilerBackendTailRun]) : CompilerBackendTailRun
  (let
    [at : i64 (compiler-backend-tail-prev-live v run.last run.first)]
    [first : i64 run.last]
    [label : i64 -1]
    (while (>= at run.first)
      (let
        [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
          (& (array-ref v.lines at))]
        [kind : i64 (compiler-backend-peephole-record-kind rec)]
        [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
        [s : i64 (compiler-backend-peephole-record-start rec)]
        [e : i64 (compiler-backend-peephole-record-end rec)]
        (when
          (= kind compiler-backend-sweep-line-kind-label)
          (when
            (and
              (compiler-backend-layout-local-label? data s e)
              (not (compiler-backend-cold-prefix? data s e ".L_tl_"))
              (not (compiler-backend-cold-prefix? data s e ".Lcv"))
              (not (compiler-backend-cold-prefix? data s e ".Ldebug")))
            (let
              [prev : i64 (compiler-backend-tail-prev-live v at run.first)]
              (when
                (>= prev run.first)
                (let
                  [prev-rec : (& v be_state.CompilerBackendPeepholeLineRecord)
                    (& (array-ref v.lines prev))]
                  [flags : i64
                    (compiler-backend-peephole-record-flags prev-rec)]
                  (when
                    (or
                      (!=
                        0
                        (bit-and
                          flags
                          (bit-or
                            compiler-backend-sweep-line-flag-jmp
                            compiler-backend-sweep-line-flag-ret)))
                      (compiler-backend-tail-abort?
                        (compiler-backend-peephole-record-data prev-rec)
                        (compiler-backend-peephole-record-start prev-rec)
                        (compiler-backend-peephole-record-end prev-rec)))
                    (set! label at))))))
          (break))
        (unless
          (and
            (= kind compiler-backend-sweep-line-kind-instruction)
            (compiler-backend-tail-eligible-insn? rec)
            (!= (be_state.compiler-backend-peephole-byte-at data (+ s 4)) 106)
            (not (compiler-backend-cold-prefix? data s e "    call"))
            (=
              0
              (bit-and
                (compiler-backend-peephole-record-flags rec)
                (bit-or
                  compiler-backend-sweep-line-flag-ret
                  (bit-or
                    compiler-backend-sweep-line-flag-rsp-dst
                    (bit-or
                      compiler-backend-sweep-line-flag-push
                      (bit-or
                        compiler-backend-sweep-line-flag-pop
                        compiler-backend-sweep-line-flag-leave)))))))
          (break))
        (set! first at))
      (set! at (compiler-backend-tail-prev-live v at run.first)))
    (CompilerBackendTailRun first run.last label run.end-hash)))

;; Scan ordinary instructions in a leaf loop using just the cached metadata.
;; The caller cuts this range at its next recorded abort call.
(define (compiler-backend-tail-next-candidate
  [lines : (MutPtr be_state.CompilerBackendPeepholeLineRecord)]
  [start : i64]
  [stop : i64]) : i64
  (let
    [at : i64 start]
    [mask : i64
      (bit-or
        compiler-backend-peephole-record-kind-mask
        (shl
          compiler-backend-sweep-line-flag-jmp
          compiler-backend-peephole-record-flags-shift))]
    (while (and
      (< at stop)
      (=
        compiler-backend-sweep-line-kind-instruction
        (bit-and
          mask
          (unsafe
            (deref (ptr-offset lines at)).meta))))
      (+= at 1))
    at))

;; The cheap discovery walk visits instruction text only at a cached jump or
;; abort. Label references and straight-line bytes are examined after finding a
;; repeated exit, within the same function and outside planned cold stubs.
(define (compiler-backend-tail-function!
  [v : (&mut v be_state.CompilerBackendPeepholeLineVec)]
  [cold : (& cold CompilerBackendColdPlan)]
  [stub-start : i64]
  [lo : i64]
  [hi : i64]
  [abort-start : i64]
  [abort-end : i64]
  [home : arena.Arena]) : unit
  (let
    [runs : tail_runs.Vec (tail_runs.new)]
    [ends : backend_label_i64_map.Map (backend_label_i64_map.with-capacity 8)]
    [targets : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [target-count : i64 0]
    ;; lo and hi bound the initialized portion of both arrays.
    [lines : (MutPtr be_state.CompilerBackendPeepholeLineRecord)
      (unsafe
        (__tl_array-data v.lines))]
    [live : (MutPtr i64)
      (unsafe
        (__tl_array-data v.live))]
    [jump-mask : i64
      (shl
        compiler-backend-sweep-line-flag-jmp
        compiler-backend-peephole-record-flags-shift)]
    [stub : i64 stub-start]
    [stub-entry : i64
      (if (< stub-start cold.stubs)
        (array-ref cold.jcc stub-start)
        hi)]
    [stub-end : i64
      (if (< stub-start cold.stubs)
        (array-ref cold.target stub-start)
        hi)]
    [lower : i64 lo]
    [abort : i64 abort-start]
    [next-abort : i64
      (if (< abort-start abort-end)
        (array-ref v.abort-cands abort-start)
        hi)]
    [anchor : i64 -1]
    [global? : bool false]
    [repeated? : bool false]
    [indirect-exit? : bool false]
    [i : i64 lo]
    (while (< i hi)
      (set! i (compiler-backend-tail-next-candidate lines i next-abort))
      (when (>= i hi) (break))
      (let
        [abort? : bool (= i next-abort)]
        (when
          abort?
          (+= abort 1)
          (set!
            next-abort
            (if (< abort abort-end)
              (array-ref v.abort-cands abort)
              hi)))
        (when
          (=
            (unsafe
              (ptr-read (ptr-offset live i)))
            1)
          (while (> i stub-end)
            (set! lower (+ stub-end 1))
            (+= stub 1)
            (set!
              stub-entry
              (if (< stub cold.stubs)
                (array-ref cold.jcc stub)
                hi))
            (set!
              stub-end
              (if (< stub cold.stubs)
                (array-ref cold.target stub)
                hi)))
          (when
            (< i stub-entry)
            (let
              [meta : i64
                (unsafe
                  (deref (ptr-offset lines i)).meta)]
              [kind : i64
                (bit-and meta compiler-backend-peephole-record-kind-mask)]
              [jmp? : bool (!= (bit-and meta jump-mask) 0)]
              [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
                (& (array-ref v.lines i))]
              [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
              [s : i64 (compiler-backend-peephole-record-start rec)]
              [e : i64 (compiler-backend-peephole-record-end rec)]
              (cond
                [(= kind compiler-backend-sweep-line-kind-label)
                  (let
                    [head : i64
                      (be_state.compiler-backend-peephole-byte-at data s)]
                    [local? : bool
                      (compiler-backend-layout-local-label? data s e)]
                    (when
                      (and
                        (compiler-backend-tail-symbol-byte? head)
                        (or (< head 48) (> head 57)))
                      (unless
                        local?
                        (when global? (return unit))
                        (set! global? true))
                      (when (< anchor 0) (set! anchor i))
                      (when
                        local?
                        (set!
                          targets
                          (compiler-backend-cold-grow-i64 targets target-count))
                        (set! (array-ref targets target-count) i)
                        (+= target-count 1))))]
                [(= kind compiler-backend-sweep-line-kind-skip)
                  (let
                    [head : i64 (compiler-backend-cold-line-first data s e)]
                    (when
                      (and
                        (< head e)
                        (=
                          (be_state.compiler-backend-peephole-byte-at data head)
                          46)
                        (or
                          (compiler-backend-cold-prefix? data head e ".seh_")
                          (compiler-backend-cold-prefix? data head e ".cfi_")
                          (compiler-backend-cold-loc-line? data head e)))
                      (return unit)))]
                [else
                  (let
                    [direct? : bool
                      (and jmp? (compiler-backend-tail-jmp? data s e))]
                    (when
                      (and
                        jmp?
                        (not direct?)
                        (<
                          (be_operand.compiler-backend-peephole-scan-byte-range
                            data
                            s
                            e
                            42)
                          e))
                      (set! indirect-exit? true))
                    (when
                      (and
                        (>= anchor 0)
                        (or
                          direct?
                          (and
                            abort?
                            (compiler-backend-tail-abort? data s e)
                            (not
                              (compiler-backend-tail-abort-site-follows? v i hi)))))
                      (let
                        [hash : i64 (compiler-backend-tail-line-hash rec)]
                        [count : i64
                          (backend_label_i64_map.get-value-or (& ends) hash 0)]
                        (when (> count 0) (set! repeated? true))
                        (backend_label_i64_map.insert-ref!
                          (&mut ends)
                          hash
                          (+ count 1))
                        (tail_runs.push-ref!
                          (&mut runs)
                          (CompilerBackendTailRun
                            (if (> anchor lower)
                              anchor
                              lower)
                            i
                            -1
                            hash)))))])))))
      (+= i 1))
    (when
      (and repeated? (>= anchor 0))
      (for [k (iterator.range 0 runs.len)]
        (let
          [run : CompilerBackendTailRun (array-ref runs.slots k)]
          (when
            (> (backend_label_i64_map.get-value-or (& ends) run.end-hash 0) 1)
            (set!
              (array-ref runs.slots k)
              (compiler-backend-tail-resolve-run v run)))))
      ;; Switch tables can live in a program-wide .rodata group that this
      ;; function cannot see. An indirect dispatch pins its possible entries.
      (unless
        indirect-exit?
        (compiler-backend-tail-whole-blocks! v (& runs) (& ends) lo hi home))
      (let
        [by-label : backend_label_i64_map.Map
          (compiler-backend-tail-index-targets v (& targets) target-count)]
        (compiler-backend-tail-suffixes!
          v
          (& runs)
          (& ends)
          (& by-label)
          anchor
          hi
          home)))))

(define (compiler-backend-tail-abort-site-follows?
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [i : i64]
  [hi : i64]) : bool
  (let
    [next : i64 (+ i 1)]
    (while (and (< next hi) (= (array-ref v.live next) 0))
      (+= next 1))
    (when (>= next hi) (return false))
    (let
      [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
        (& (array-ref v.lines next))]
      (compiler-backend-cold-prefix?
        (compiler-backend-peephole-record-data rec)
        (compiler-backend-peephole-record-start rec)
        (compiler-backend-peephole-record-end rec)
        ".L_tl_abort_site_"))))

;; Most small functions have no pair of terminating branches. Filter them with
;; the cached jmp bits and abort candidate count before allocating any tables.
(define (compiler-backend-tail-candidates?
  [lines : (MutPtr be_state.CompilerBackendPeepholeLineRecord)]
  [lo : i64]
  [hi : i64]
  [abort-count : i64]) : bool
  (let
    [count : i64 abort-count]
    [index : i64 lo]
    [jump-mask : i64
      (shl
        compiler-backend-sweep-line-flag-jmp
        compiler-backend-peephole-record-flags-shift)]
    (while (and (< count 2) (< index hi))
      (when
        (not
          (=
            (bit-and
              jump-mask
              (unsafe
                (deref (ptr-offset lines index)).meta))
            0))
        (+= count 1))
      (+= index 1))
    (>= count 2)))

(define (compiler-backend-peephole-merge-tails!
  [v : (&mut v be_state.CompilerBackendPeepholeLineVec)]
  [cold : (& cold CompilerBackendColdPlan)]) : unit
  (when (< v.len 5) (return unit))
  (let
    [home : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    [lo : i64 0]
    [stub : i64 0]
    [abort : i64 0]
    [lines : (MutPtr be_state.CompilerBackendPeepholeLineRecord)
      (unsafe
        (__tl_array-data v.lines))]
    (for [close (iterator.range 0 (+ v.close-cand-len 1))]
      (let
        [hi : i64
          (if (< close v.close-cand-len)
            (array-ref v.close-cands close)
            v.len)]
        (while (and
          (< abort v.abort-cand-len)
          (< (array-ref v.abort-cands abort) lo))
          (+= abort 1))
        (let
          [first-abort : i64 abort]
          (while (and
            (< abort v.abort-cand-len)
            (< (array-ref v.abort-cands abort) hi))
            (+= abort 1))
          (when
            (and
              (>= (- hi lo) 5)
              (compiler-backend-tail-candidates?
                lines
                lo
                hi
                (- abort first-abort)))
            (let
              [phase : arena.ArenaPhase (arena.phase scratch)]
              (in-arena
                scratch
                (unsafe
                  ;; Replacement strings are explicitly allocated in home.
                  (compiler-backend-tail-function!
                    v
                    cold
                    stub
                    lo
                    hi
                    first-abort
                    abort
                    home)))
              (arena.rewind-safe! phase))))
        (set! lo (+ hi 1))
        (while (and (< stub cold.stubs) (< (array-ref cold.target stub) lo))
          (+= stub 1))))
    (arena.destroy-safe! scratch)))

;; The single render of the group, with COLD-1's out-of-line abort stubs. A
;; group without an abort call renders in record order; otherwise the cold
;; plan stays in scratch while the final string is rendered into the caller's
;; arena.
(define (compiler-backend-peephole-records-render
  [v : be_state.CompilerBackendPeepholeLineVec]
  [merge-tails? : bool]
  [compact-branches? : bool]) : String
  (if (= v.abort-cand-len 0)
    (begin
      (when
        merge-tails?
        (let
          [plan : CompilerBackendColdPlan (compiler-backend-cold-plan-empty)]
          (compiler-backend-peephole-merge-tails! (&mut v) (& plan))
          (when
            compact-branches?
            (compiler-backend-peephole-compact-branch-jumps! (&mut v) (& plan)))))
      (compiler-backend-peephole-records-render-plain v))
    (let
      [scratch : arena.Arena (arena.make)]
      ;; The plan owns the cold labels and inverses until rendering copies them.
      [plan : CompilerBackendColdPlan
        (unsafe
          (in-arena
            (arena.Arena (arena.raw-handle scratch))
            (compiler-backend-cold-plan v)))]
      [_merge : unit
        (when
          merge-tails?
          (compiler-backend-peephole-merge-tails! (&mut v) (& plan))
          (when
            compact-branches?
            (compiler-backend-peephole-compact-branch-jumps! (&mut v) (& plan))))]
      [rendered : String (compiler-backend-cold-render v plan)]
      (arena.destroy-safe! scratch)
      rendered)))

;; ---------------------------------------------------------------------------
;; Win64 unwind lowering: shared `.xdata` records and leaf omission.
;;
;; A `.seh_proc` function gets one UNWIND_INFO record from the assembler, and
;; most functions spell one of a few hundred prologues. On the group's final
;; text -- after the stack rebase, the save splice and COLD-1 have placed every
;; prologue byte and every out-of-line stub -- a prologue made only of pushes,
;; a stack allocation and the `__chkstk` probe is encoded here, byte for byte
;; as the assembler encodes its `.seh_*` directives, and interned per emission:
;; the function keeps its `.pdata` row (`.rva start, end, record`) and names
;; the emission's single copy of its record. A function whose record would hold
;; no codes and whose body neither calls nor moves %rsp is a Win64 leaf: the
;; unwinder treats a function without a `.pdata` row exactly so, and the row is
;; dropped. Any other prologue (frame register, register or XMM saves, unknown
;; bytes) keeps its directives for the assembler.
;; The UNWIND_INFO bytes of one encodable prologue: `info` is their `.byte`
;; operand text (the intern key), `record` the same bytes as `.byte` lines, one
;; per unwind code and named in its comment. `body` is the first byte after
;; `.seh_endprologue`, or -1 when the prologue is not encodable; `empty` marks
;; a record with no prologue bytes and no codes.
(defstruct CompilerBackendWin64Prologue
  (body i64)
  (info String)
  (record String)
  (empty bool))

;; The `.seh_endproc` line that closes a function body (-1 when the body holds
;; another `.seh_` directive or never closes), and whether the body calls or
;; moves %rsp.
(defstruct CompilerBackendWin64UnwindBody
  (close i64)
  (close-end i64)
  (stack? bool))

;; One span of the group text the lowering replaces.
(defstruct CompilerBackendWin64UnwindEdit
  (start i64)
  (end i64)
  (text String))

(import (vector.vector CompilerBackendWin64UnwindEdit core) as win64_unwind_edits)

(define (compiler-backend-win64-line-end
  [data : (Ptr u8)]
  [start : i64]
  [n : i64]) : i64
  (let
    [i : i64 start]
    (while (and
      (< i n)
      (not (= (be_state.compiler-backend-peephole-byte-at data i) 10)))
      (+= i 1))
    i))

;; Hardware number of the 64-bit GP register spelled in [s,e), or -1.
(define (compiler-backend-win64-unwind-reg
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : i64
  (let
    [names : (Array String 16)
      (array
        "%rax"
        "%rcx"
        "%rdx"
        "%rbx"
        "%rsp"
        "%rbp"
        "%rsi"
        "%rdi"
        "%r8"
        "%r9"
        "%r10"
        "%r11"
        "%r12"
        "%r13"
        "%r14"
        "%r15")]
    [found : i64 -1]
    (for [r (iterator.range 0 16)]
      (when
        (and
          (< found 0)
          (be_operand.compiler-backend-peephole-range-eq?
            data
            s
            e
            (& (array-ref names r))))
        (set! found r)))
    found))

;; The unsigned decimal in [s,e), or -1 when it is empty, not all digits, or
;; does not fit a 32-bit immediate.
(define (compiler-backend-win64-unwind-int
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : i64
  (let
    [v : i64
      (if (< s e)
        0
        -1)]
    (for [j (iterator.range s e)]
      (let
        [b : i64 (be_state.compiler-backend-peephole-byte-at data j)]
        (if (and (>= v 0) (>= b 48) (<= b 57) (< v 214748364))
          (set! v (+ (* v 10) (- b 48)))
          (set! v -1))))
    v))

;; The immediate of `PREFIX$N, SUFFIX` spelled in [first,last), or -1.
(define (compiler-backend-win64-unwind-imm
  [data : (Ptr u8)]
  [first : i64]
  [last : i64]
  [prefix : String]
  [suffix : String]) : i64
  (let
    [p : i64 (string.string-length (& prefix))]
    [q : i64 (string.string-length (& suffix))]
    (if (and
      (<= (+ first p q) last)
      (compiler-backend-cold-prefix? data first last prefix)
      (be_operand.compiler-backend-peephole-range-eq?
        data
        (- last q)
        last
        (& suffix)))
      (compiler-backend-win64-unwind-int data (+ first p) (- last q))
      -1)))

;; Encoded size of the prologue instruction in [first,last), or -1 for any
;; instruction the lowering does not encode.
(define (compiler-backend-win64-unwind-instr-size
  [data : (Ptr u8)]
  [first : i64]
  [last : i64]) : i64
  (cond
    [(compiler-backend-cold-prefix? data first last "pushq ")
      (let
        [reg : i64 (compiler-backend-win64-unwind-reg data (+ first 6) last)]
        (cond [(< reg 0) -1] [(>= reg 8) 2] [else 1]))]
    [(be_operand.compiler-backend-peephole-range-eq?
        data
        first
        last
        "subq %rax, %rsp")
      3]
    [(or
        (be_operand.compiler-backend-peephole-range-eq?
          data
          first
          last
          "callq __chkstk")
        (be_operand.compiler-backend-peephole-range-eq?
          data
          first
          last
          "call __chkstk"))
      5]
    [(>=
        (compiler-backend-win64-unwind-imm data first last "movl $" ", %eax")
        0)
      5]
    [else
      (let
        [amount : i64
          (compiler-backend-win64-unwind-imm data first last "subq $" ", %rsp")]
        (cond [(< amount 0) -1] [(< amount 128) 4] [else 7]))]))

(define (compiler-backend-win64-unwind-slot-text [slot : i64]) : String
  (str_cat.str-cat
    ", "
    (string.int->string (bit-and slot 255))
    ", "
    (string.int->string (shr slot 8))))

;; Record one unwind code of 1-3 slots and the comment that names it.
(define (compiler-backend-win64-unwind-code!
  [slots : (&mut slots (__tl_dyn-array i64))]
  [starts : (&mut starts (__tl_dyn-array i64))]
  [names : (&mut names (__tl_dyn-array String))]
  [first : i64]
  [second : i64]
  [third : i64]
  [name : String]) : unit
  (__tl_array-push! starts (array-length slots))
  (__tl_array-push! names name)
  (__tl_array-push! slots first)
  (when (>= second 0) (__tl_array-push! slots second))
  (when (>= third 0) (__tl_array-push! slots third)))

;; Parse the prologue of the `.seh_proc` line [proc-first,proc-end): the
;; function label must follow it, then only encodable instructions,
;; `.seh_pushreg` and `.seh_stackalloc` up to `.seh_endprologue`. Codes are
;; recorded as 16-bit slots in prologue order, each at the offset just past
;; the instruction it describes; UNWIND_INFO lists them newest first.
(define (compiler-backend-win64-unwind-prologue
  [data : (Ptr u8)]
  [text : (& text str)]
  [proc-first : i64]
  [proc-end : i64]
  [n : i64]) : CompilerBackendWin64Prologue
  (let
    [fail : CompilerBackendWin64Prologue
      (CompilerBackendWin64Prologue -1 "" "" false)]
    [sym : i64 (+ proc-first 10)]
    [sym-end : i64 (compiler-backend-cold-line-last data sym proc-end)]
    [label : i64 (+ proc-end 1)]
    [label-end : i64 (compiler-backend-win64-line-end data label n)]
    (unless
      (and
        (< sym sym-end)
        (= (- label-end label) (+ (- sym-end sym) 1))
        (= (be_state.compiler-backend-peephole-byte-at data (- label-end 1)) 58)
        (let
          [same : bool true]
          (for [k (iterator.range 0 (- sym-end sym))]
            (unless
              (=
                (be_state.compiler-backend-peephole-byte-at data (+ sym k))
                (be_state.compiler-backend-peephole-byte-at data (+ label k)))
              (set! same false)))
          same))
      (return fail))
    (let
      [slots : (__tl_dyn-array i64) (__tl_make-array i64 0)]
      [starts : (__tl_dyn-array i64) (__tl_make-array i64 0)]
      [names : (__tl_dyn-array String) (__tl_make-array String 0)]
      [offset : i64 0]
      [body : i64 -1]
      [ok : bool true]
      [i : i64 (+ label-end 1)]
      (while (and ok (< body 0) (< i n))
        (let
          [e : i64 (compiler-backend-win64-line-end data i n)]
          [first : i64 (compiler-backend-cold-line-first data i e)]
          [last : i64 (compiler-backend-cold-line-last data first e)]
          (cond
            [(or
                (= first last)
                (= (be_state.compiler-backend-peephole-byte-at data first) 35))
              unit]
            [(compiler-backend-cold-prefix? data first last ".seh_endprologue")
              (set! body (+ e 1))]
            [(compiler-backend-cold-prefix? data first last ".seh_pushreg ")
              (let
                [reg : i64
                  (compiler-backend-win64-unwind-reg data (+ first 13) last)]
                (if (< reg 0)
                  (set! ok false)
                  (compiler-backend-win64-unwind-code!
                    (&mut slots)
                    (&mut starts)
                    (&mut names)
                    (+ offset (shl reg 12))
                    -1
                    -1
                    (str_cat.str-cat
                      "UWOP_PUSH_NONVOL "
                      (string.substring text (+ first 13) (- last (+ first 13)))))))]
            [(compiler-backend-cold-prefix? data first last ".seh_stackalloc ")
              (let
                [size : i64
                  (compiler-backend-win64-unwind-int data (+ first 16) last)]
                [amount : String (string.int->string size)]
                (cond
                  [(or (<= size 0) (not (= (% size 8) 0))) (set! ok false)]
                  [(<= size 128)
                    (compiler-backend-win64-unwind-code!
                      (&mut slots)
                      (&mut starts)
                      (&mut names)
                      (+ offset (shl (+ 2 (shl (- (/ size 8) 1) 4)) 8))
                      -1
                      -1
                      (str_cat.str-cat "UWOP_ALLOC_SMALL " amount))]
                  [(<= size 524280)
                    (compiler-backend-win64-unwind-code!
                      (&mut slots)
                      (&mut starts)
                      (&mut names)
                      (+ offset (shl 1 8))
                      (/ size 8)
                      -1
                      (str_cat.str-cat "UWOP_ALLOC_LARGE " amount))]
                  [else
                    (compiler-backend-win64-unwind-code!
                      (&mut slots)
                      (&mut starts)
                      (&mut names)
                      (+ offset (shl 17 8))
                      (bit-and size 65535)
                      (shr size 16)
                      (str_cat.str-cat "UWOP_ALLOC_LARGE " amount))]))]
            [else
              (let
                [size : i64
                  (if (compiler-backend-cold-prefix? data first last ".seh_")
                    -1
                    (compiler-backend-win64-unwind-instr-size data first last))]
                (if (< size 0)
                  (set! ok false)
                  (+= offset size)))])
          (set! i (+ e 1))))
      (let
        [count : i64 (array-length slots)]
        (if (or (not ok) (< body 0) (> offset 255) (> count 255))
          fail
          (let
            [header : String
              (str_cat.str-cat
                "1, "
                (string.int->string offset)
                ", "
                (string.int->string count)
                ", 0")]
            [info : String (string.copy (& header))]
            [record : String (str_cat.str-cat "    .byte " header "\n")]
            [code : i64 (- (array-length starts) 1)]
            (while (>= code 0)
              (let
                [lo : i64 (array-ref starts code)]
                [hi : i64
                  (if (= code (- (array-length starts) 1))
                    count
                    (array-ref starts (+ code 1)))]
                [line : String ""]
                (for [k (iterator.range lo hi)]
                  (set!
                    line
                    (str_cat.str-cat
                      line
                      (compiler-backend-win64-unwind-slot-text
                        (array-ref slots k)))))
                (set! info (str_cat.str-cat info line))
                ;; `line` starts with ", ": the record line drops that comma.
                (set!
                  record
                  (str_cat.str-cat
                    record
                    "    .byte "
                    (string.substring
                      (& line)
                      2
                      (- (string.string-length (& line)) 2))
                    "    # "
                    (string.copy (& (array-ref names code)))
                    "\n")))
              (-= code 1))
            ;; Even slot count; a record without codes still spans 8 bytes.
            (cond
              [(= count 0)
                (set! info (str_cat.str-cat info ", 0, 0, 0, 0"))
                (set! record (str_cat.str-cat record "    .byte 0, 0, 0, 0\n"))]
              [(= (% count 2) 1)
                (set! info (str_cat.str-cat info ", 0, 0"))
                (set! record (str_cat.str-cat record "    .byte 0, 0\n"))]
              [else unit])
            (CompilerBackendWin64Prologue
              body
              info
              record
              (and (= offset 0) (= count 0)))))))))

;; Scan the body from `start` to its `.seh_endproc` line; `leaf-check?` also
;; asks whether any line calls, pushes, pops or writes %rsp.
(define (compiler-backend-win64-unwind-body
  [data : (Ptr u8)]
  [start : i64]
  [n : i64]
  [leaf-check? : bool]) : CompilerBackendWin64UnwindBody
  (let
    [close : i64 -1]
    [close-end : i64 -1]
    [stack? : bool false]
    [done : bool false]
    [i : i64 start]
    (while (and (not done) (< i n))
      (let
        [e : i64 (compiler-backend-win64-line-end data i n)]
        [first : i64 (compiler-backend-cold-line-first data i e)]
        (when
          (< first e)
          (if (= (be_state.compiler-backend-peephole-byte-at data first) 46)
            (when
              (compiler-backend-cold-prefix? data first e ".seh_")
              (set! done true)
              (when
                (compiler-backend-cold-prefix? data first e ".seh_endproc")
                (set! close i)
                (set!
                  close-end
                  (if (< e n)
                    (+ e 1)
                    n))))
            (when
              (and leaf-check? (not stack?))
              (let
                [last : i64 (compiler-backend-cold-line-last data first e)]
                (when
                  (or
                    (compiler-backend-cold-prefix? data first last "call")
                    (compiler-backend-cold-prefix? data first last "push")
                    (compiler-backend-cold-prefix? data first last "pop")
                    (compiler-backend-cold-prefix? data first last "leave")
                    (compiler-backend-cold-prefix? data first last "enter")
                    (and
                      (>= (- last first) 4)
                      (be_operand.compiler-backend-peephole-range-eq?
                        data
                        (- last 4)
                        last
                        "%rsp")))
                  (set! stack? true))))))
        (set! i (+ e 1))))
    (CompilerBackendWin64UnwindBody close close-end stack?)))

;; The `.xdata` label of `info`, interning it in the emission's table on first
;; use; the returned flag says the record is new and must be emitted.
(define (compiler-backend-win64-unwind-intern!
  [stream : be_state.CompilerBackendStreamState]
  [info : String]
  [home : arena.Arena]) : (Tuple i64 bool)
  (let
    [data : (MutPtr be_state.CompilerBackendStreamStateData)
      (be_state.compiler-backend-stream-state-ptr stream)]
    [ids : backend_string_i64_map.Map
      (unsafe
        (deref data).win64-xdata-ids)]
    (match (backend_string_i64_map.get-borrowed (& ids) (& info))
      [(LookupFound id) (tuple id false)]
      [(LookupMissing)
        (let
          [id : i64
            (unsafe
              (deref data).win64-xdata-count)]
          (unsafe
            (in-arena
              (arena.Arena (arena.raw-handle home))
              (backend_string_i64_map.insert-ref!
                (&mut ids)
                (string.copy (& info))
                id))
            (set! (deref data).win64-xdata-ids ids)
            (set! (deref data).win64-xdata-count (+ id 1)))
          (tuple id true))])))

;; The text that replaces a lowered function's `.seh_endproc` line: its end
;; label, the record on first use, and its `.pdata` row.
(define (compiler-backend-win64-unwind-close-text
  [stream : be_state.CompilerBackendStreamState]
  [symbol : String]
  [pro : (& pro CompilerBackendWin64Prologue)]
  [home : arena.Arena]) : String
  (let
    [data : (MutPtr be_state.CompilerBackendStreamStateData)
      (be_state.compiler-backend-stream-state-ptr stream)]
    [end-id : i64
      (unsafe
        (deref data).win64-unwind-end-count)]
    [_count : unit
      (unsafe
        (set! (deref data).win64-unwind-end-count (+ end-id 1)))]
    [end : String
      (str_cat.str-cat ".L_tl_seh_end_" (string.int->string end-id))]
    [interned : (Tuple i64 bool)
      (compiler-backend-win64-unwind-intern!
        stream
        (string.copy (& pro.info))
        home)]
    [xdata : String
      (str_cat.str-cat
        ".L_tl_xdata_"
        (string.int->string (tuple-ref interned 0)))]
    (str_cat.str-cat
      end
      ":\n"
      (if (tuple-ref interned 1)
        (str_cat.str-cat
          "    .pushsection .xdata,\"dr\"\n    .p2align 2\n"
          xdata
          ":\n"
          (string.copy (& pro.record))
          "    .popsection\n")
        "")
      "    .pushsection .pdata,\"dr\"\n    .rva "
      symbol
      ", "
      end
      ", "
      xdata
      "\n    .popsection\n")))

;; Lower every encodable `.seh_proc` function of the rendered group `text`.
;; The edits are planned in the active (scratch) arena; the lowered group is
;; one allocation in `home`, written once.
(define (compiler-backend-win64-lower-unwind
  [stream : be_state.CompilerBackendStreamState]
  [text : String]
  [home : arena.Arena]) : String
  (let
    [data : (Ptr u8)
      (unsafe
        (string-data (& text)))]
    [n : i64 (string.string-length (& text))]
    [edits : win64_unwind_edits.Vec (win64_unwind_edits.new)]
    [delta : i64 0]
    [i : i64 0]
    (while (< i n)
      (let
        [e : i64 (compiler-backend-win64-line-end data i n)]
        [first : i64 (compiler-backend-cold-line-first data i e)]
        [next : i64 (+ e 1)]
        (when
          (and
            (< first e)
            (= (be_state.compiler-backend-peephole-byte-at data first) 46)
            (compiler-backend-cold-prefix? data first e ".seh_proc "))
          (let
            [pro : CompilerBackendWin64Prologue
              (compiler-backend-win64-unwind-prologue data (& text) first e n)]
            (when
              (>= pro.body 0)
              (let
                [body : CompilerBackendWin64UnwindBody
                  (compiler-backend-win64-unwind-body data pro.body n pro.empty)]
                (when
                  (>= body.close 0)
                  (let
                    [symbol : String
                      (string.substring
                        (& text)
                        (+ first 10)
                        (-
                          (compiler-backend-cold-line-last data (+ first 10) e)
                          (+ first 10)))]
                    [close-text : String
                      (if (and pro.empty (not body.stack?))
                        ""
                        (compiler-backend-win64-unwind-close-text
                          stream
                          symbol
                          (& pro)
                          home))]
                    [j : i64 i]
                    ;; Drop every `.seh_` line of the prologue.
                    (while (< j pro.body)
                      (let
                        [je : i64 (compiler-backend-win64-line-end data j n)]
                        [jf : i64 (compiler-backend-cold-line-first data j je)]
                        [jn : i64
                          (if (< je n)
                            (+ je 1)
                            n)]
                        (when
                          (compiler-backend-cold-prefix? data jf je ".seh_")
                          (win64_unwind_edits.push-ref!
                            (&mut edits)
                            (CompilerBackendWin64UnwindEdit j jn ""))
                          (-= delta (- jn j)))
                        (set! j jn)))
                    (+=
                      delta
                      (-
                        (string.string-length (& close-text))
                        (- body.close-end body.close)))
                    (win64_unwind_edits.push-ref!
                      (&mut edits)
                      (CompilerBackendWin64UnwindEdit
                        body.close
                        body.close-end
                        close-text))
                    (set! next body.close-end)))))))
        (set! i next)))
    (unsafe
      (in-arena
        (arena.Arena (arena.raw-handle home))
        (let
          [total : i64 (+ n delta)]
          [out : (__tl_dyn-array u8)
            (__tl_make-array
              u8
              (if (< total 1)
                1
                total))]
          [dst : (MutPtr u8) (__tl_array-data out)]
          [from : i64 0]
          [pos : i64 0]
          [slots : (& edits (__tl_dyn-array CompilerBackendWin64UnwindEdit))
            (win64_unwind_edits.slots (& edits))]
          (for [k (iterator.range 0 edits.len)]
            (let
              [edit : (& edits CompilerBackendWin64UnwindEdit)
                (& (array-ref slots k))]
              [len : i64 (string.string-length (& edit.text))]
              (text_buf_borrowed.copy-byte-range-into
                data
                from
                (- edit.start from)
                dst
                pos)
              (+= pos (- edit.start from))
              (text_buf_borrowed.copy-byte-range-into
                (string-data (& edit.text))
                0
                len
                dst
                pos)
              (+= pos len)
              (set! from edit.end)))
          (text_buf_borrowed.copy-byte-range-into data from (- n from) dst pos)
          (string-from-bytes (ptr-cast dst : (Ptr u8)) total))))))

;; ---------------------------------------------------------------------------
;; RMW-2/RMW-3: fold an adjacent load / ALU / store of ONE memory location into
;; a memory-operand ALU instruction, with a reload when the result register
;; remains live.
;;
;;     movq   M, %rX          -->    op {$imm|%rY}, M          (%rX dead)
;;     op     {$imm|%rY}, %rX
;;     movq   %rX, M          -->    op {$imm|%rY}, M          (%rX live)
;;                                  movq M, %rX
;;
;; x86 executes the dead form as one instruction and the live form as two where
;; we emit three. The three are TEXTUALLY ADJACENT in our output at every site:
;; the scalar-global counter bumps (`g += 1`) and the frame-slot accumulator
;; bumps (`slot += k`) the emitter produces from a load/binop/store IR triple.
;;
;; ADMISSION -- LLVM's `isFusableLoadOpStorePattern`
;; (llvm/lib/Target/X86/X86ISelDAGToDAG.cpp:3732) plus `foldLoadStoreIntoMemOperand`
;; (:3863), transposed to text:
;;   * the load's value has exactly one use, the op   -- guaranteed here by
;;     ADJACENCY: nothing sits between the load and the op, and the op reads %rX;
;;   * adjacency proves the store is the first consumer of the op result. The
;;     bounded register-death scan chooses RMW-2's one-instruction form when it
;;     is the only use; otherwise RMW-3 reloads the stored word into %rX before
;;     any later use;
;;   * load and store name the SAME address -- byte-identical operand text, and
;;     both shapes are addressed by a register the triple cannot write (`%rip`
;;     is not writable; `%rsp`/`%rbp` are outside the allocator's tracked set, so
;;     the folded triple's %rX is never one of them);
;;   * the op is in {add,sub,and,or,xor,neg,not}. LLVM's list also names inc/dec;
;;     our emitter never spells those (an increment is `addq $1`), which is why
;;     no carry-flag analysis is needed here: `incq m` differs from
;;     `addq $1, m` only in CF, and we emit the `addq` form on both sides of
;;     the fold.
;;   * `%rY` != `%rX`: `addq %rax, %rax` doubles the LOADED value, which the
;;     folded `addq %rax, M` would not reproduce.
;;
;; FLAGS. The fold is flags-exact by construction, in both directions:
;;   * `movq` writes no flags, so the flags after the original triple are exactly
;;     the flags the ALU op wrote, and the flags after the folded instruction are
;;     the flags the same ALU op writes on the same operand values. A following
;;     `jcc` reading the op's flags therefore reads an IDENTICAL EFLAGS word,
;;     so no flags-consumer refusal is needed.
;;   * a `jcc` reading the LOAD's flags is impossible: `movq` sets none, so any
;;     flags live INTO the triple are killed by the op in both forms alike.
;;   * nothing can sit between the op and the store to observe an intermediate
;;     state, because the three lines are adjacent.
;;
;; SPLIT. RECOGNITION rides the streaming walk and is spelled next to the record
;; sink above: every emitted line is parsed there already, so naming the window
;; costs a flag test per line and the candidate array is only allocated for a
;; group that has one. What is left here is the VALIDATION -- the shape re-check
;; and the bounded deadness DFS -- and the rewrite.
;;
;; PLACEMENT. That remainder runs over the FINAL record stream -- after the
;; walk's pair rules, after the owner-map reload rewrites, and after the
;; dead-frame-store sweep. It is a soundness requirement, not a convenience:
;; the owner map may have rewritten a LATER reload `movq M, %rY` into
;; `movq %rX, %rY` (reload reuse from the register that mirrors the slot). That
;; rewrite is a genuine use of %rX, and it exists only in the emitted text.
;; Scanning the post-walk stream is what makes the death scan below see it and
;; choose RMW-3's reload; the later rewritten copy then reads the restored
;; value. Recognition may run early because it only NAMES a window and decides
;; nothing: the three records are re-read and re-checked here, and a candidate
;; whose store the sweep proved dead -- or whose lines are no longer all live --
;; is dropped before any rewrite.
;;
;; FOLD ORDER. Candidates are folded in a forward pass, and an earlier fold can
;; delete the very `movq M, %rX` a later candidate's death scan used as its kill
;; of %rX. That stays sound: the fold that deletes the kill deletes, in the same
;; step, the only two reads of %rX between it and its own store (the op and the
;; store), and its own scan proves nothing reads %rX after it. Composing the two
;; proofs leaves the whole region read-free for %rX, which is what deadness
;; means.
;; How many records one death scan may visit, and how many branch arms it may
;; hold pending.
(define compiler-backend-peephole-rmw-scan-cap : i64
  48)
(define compiler-backend-peephole-rmw-branch-cap : i64
  32)

;; How far from the branch a label definition may sit to be resolvable, and how
;; many resolutions one candidate may spend. These and the scan cap above are
;; COST bounds, not correctness bounds: exceeding any of them refuses the fold.
;; Without them the scan is quadratic -- one unresolved branch walks the whole
;; group, a group is up to 64 emitted functions, and the walk over a
;; self-compile's output then costs more than the fold saves. Emitted
;; branch targets are function-local and overwhelmingly within a few dozen
;; lines, and a register that is not dead within a few dozen records is not
;; going to be, so these values keep nearly every fold the unbounded scan finds.
(define compiler-backend-peephole-rmw-label-window : i64
  64)
(define compiler-backend-peephole-rmw-label-lookup-cap : i64
  8)

;; The death scan's revisit stamps live in ONE fixed window around the store
;; rather than an array as long as the group. The bounds above put every record
;; the scan can reach inside [start - back, start - back + window): a branch
;; target is within `label-window` of a pc the scan reached, and the scan
;; reaches at most `scan-cap` records from the store. A pc outside the window is
;; refused like any other unclassifiable step, so the bound is sound as well as
;; cheap -- and a group with candidates pays no allocation or clear
;; proportional to its own length.
(define compiler-backend-peephole-rmw-visit-back : i64
  128)
(define compiler-backend-peephole-rmw-visit-window : i64
  512)

;; `%ah`/`%ch`/`%dh`/`%bh` -- the four high-byte spellings the shared owner-map
;; token classifier deliberately leaves unmapped. It can afford to: the one
;; emitter that spells a high byte writes `%al` on the same line, so the owner
;; map invalidates %rax anyway. A liveness scan cannot afford to, so they are
;; classified HERE rather than added to the shared table, which would change
;; owner-map decisions and therefore emitted assembly.
(define (compiler-backend-peephole-rmw-high-byte-reg-index
  [data : (Ptr u8)]
  [ts : i64]
  [te : i64]) : i64
  (cond
    [(not (= (- te ts) 3)) -1]
    [(not (= (be_state.compiler-backend-peephole-byte-at data ts) 37)) -1]
    [(not (= (be_state.compiler-backend-peephole-byte-at data (+ ts 2)) 104))
      -1]
    [else
      (let
        [b1 : i64 (be_state.compiler-backend-peephole-byte-at data (+ ts 1))]
        (cond
          [(= b1 97) 0]
          [(= b1 99) 1]
          [(= b1 100) 2]
          [(= b1 98) 3]
          [else -1]))]))

;; True iff [start,end) mentions the tracked GP register `reg` in any spelling.
;; Every register mention in an AT&T operand starts with '%', so the scan walks
;; '%'-prefixed tokens and classifies each; sub-register and high-byte spellings
;; map to their 64-bit parent, and memory operands are covered because their
;; base/index tokens are '%'-prefixed too. A MENTION is treated as a READ, which
;; is the conservative direction: over-counting reads only refuses folds.
(define (compiler-backend-peephole-rmw-mentions-reg?
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]
  [reg : i64]) : bool
  (if (< reg 0)
    false
    (let
      [i : i64 start]
      [found : bool false]
      (while (and (not found) (< i end))
        (if (= (be_state.compiler-backend-peephole-byte-at data i) 37)
          (let
            [j : i64 (+ i 1)]
            (while (and
              (< j end)
              (let
                [b : i64 (be_state.compiler-backend-peephole-byte-at data j)]
                (or (and (>= b 97) (<= b 122)) (and (>= b 48) (<= b 57)))))
              (+= j 1))
            (when
              (or
                (=
                  (compiler-backend-peephole-token-reg-index-range data i j)
                  reg)
                (=
                  (compiler-backend-peephole-rmw-high-byte-reg-index data i j)
                  reg))
              (set! found true))
            (set! i j))
          (+= i 1)))
      found)))

;; True iff [start,end) is exactly one of the two foldable memory shapes: a
;; rip-relative global (`sym(%rip)`, `sym+8(%rip)`) or a frame slot (`N(%rsp)`,
;; `-N(%rbp)`, `(%rsp)`). The single-'%' requirement is what rejects every other
;; memory operand -- indexed forms, r10 bases, bare registers -- and with it the
;; only way the triple's own register could appear in the address.
(define (compiler-backend-peephole-rmw-mem-operand?
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : bool
  (if (< (- end start) 6)
    false
    (let
      [suffix : i64 (- end 6)]
      [base-ok : bool
        (or
          (be_operand.compiler-backend-peephole-range-eq?
            data
            suffix
            end
            "(%rip)")
          (be_operand.compiler-backend-peephole-range-eq?
            data
            suffix
            end
            "(%rsp)")
          (be_operand.compiler-backend-peephole-range-eq?
            data
            suffix
            end
            "(%rbp)"))]
      [i : i64 start]
      [clean : bool true]
      (unless base-ok (return false))
      (while (and clean (< i suffix))
        (when
          (= (be_state.compiler-backend-peephole-byte-at data i) 37)
          (set! clean false))
        (+= i 1))
      clean)))

;; Mnemonics whose register reads and writes are ENTIRELY explicit in their
;; operand text, so "the line does not mention %rX" proves "the line does not
;; read %rX". This is an ALLOW list and the default is refusal, which is what
;; keeps the scan sound against every instruction with an implicit register
;; operand: `cqto`/`cltq`/`cdq`/`cbw` (read %rax), `divq`/`idivq`/`mulq`
;; (read %rdx:%rax), `rep movsb` (reads %rcx/%rsi/%rdi), `syscall`, `leave`,
;; `cpuid` -- none of them is on this list, so a scan that reaches one refuses.
;; `call` and `ret` are classified before this test, not here.
;;
;; `pushq`/`popq` ARE listed: their only implicit operand is %rsp, which the
;; token classifier maps to -1 and which can never be the folded register.
;; `%cl`-counted shifts spell `%cl`, so the mention scan sees them.
(define (compiler-backend-peephole-rmw-transparent-mnemonic?
  [data : (Ptr u8)]
  [ms : i64]
  [me : i64]) : bool
  (let
    [b0 : i64 (be_state.compiler-backend-peephole-byte-at data ms)]
    (cond
      [(= b0 109)
        (or
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movl")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movb")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movw")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movabsq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movzbq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movzbl")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movzwq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movzwl")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movsbq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movsbl")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movswq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movswl")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movslq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movups")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movaps")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movsd")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movss")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movdqu")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movdqa"))]
      [(= b0 97)
        (or
          (be_operand.compiler-backend-peephole-range-eq? data ms me "addq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "addl")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "addb")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "addw")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "andq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "andl")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "andb")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "andw"))]
      [(= b0 115)
        (or
          (be_operand.compiler-backend-peephole-range-eq? data ms me "subq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "subl")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "shlq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "shll")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "shrq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "shrl")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "sarq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "sarl")
          (and
            (>= (- me ms) 4)
            (be_operand.compiler-backend-peephole-range-eq?
              data
              ms
              (+ ms 3)
              "set")))]
      [(= b0 111)
        (or
          (be_operand.compiler-backend-peephole-range-eq? data ms me "orq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "orl")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "orb")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "orw"))]
      [(= b0 120)
        (or
          (be_operand.compiler-backend-peephole-range-eq? data ms me "xorq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "xorl")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "xorb")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "xorw"))]
      [(= b0 99)
        (or
          (be_operand.compiler-backend-peephole-range-eq? data ms me "cmpq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "cmpl")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "cmpb")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "cmpw")
          (and
            (>= (- me ms) 5)
            (be_operand.compiler-backend-peephole-range-eq?
              data
              ms
              (+ ms 4)
              "cmov")))]
      [(= b0 116)
        (or
          (be_operand.compiler-backend-peephole-range-eq? data ms me "testq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "testl")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "testb")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "testw"))]
      [(= b0 105)
        (or
          (be_operand.compiler-backend-peephole-range-eq? data ms me "imulq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "imull"))]
      [(= b0 110)
        (or
          (be_operand.compiler-backend-peephole-range-eq? data ms me "negq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "negl")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "notq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "notl")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "nop")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "nopl")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "nopw"))]
      [(= b0 112)
        (or
          (be_operand.compiler-backend-peephole-range-eq? data ms me "pushq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "popq"))]
      [(= b0 100)
        (or
          (be_operand.compiler-backend-peephole-range-eq? data ms me "decq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "decl"))]
      [(= b0 108)
        (or
          (be_operand.compiler-backend-peephole-range-eq? data ms me "leaq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "leal"))]
      [(= b0 98)
        (or
          (be_operand.compiler-backend-peephole-range-eq? data ms me "btq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "btsq")
          (be_operand.compiler-backend-peephole-range-eq? data ms me "btrq"))]
      ;; Every AVX form reads and writes exactly the registers it names, with
      ;; ONE exception: `vmaskmovdqu` stores through an implicit %rdi.
      [(= b0 118)
        (not
          (be_operand.compiler-backend-peephole-range-eq?
            data
            ms
            me
            "vmaskmovdqu"))]
      [else false])))

(define (compiler-backend-leaq-full-load?
  [data : (Ptr u8)]
  [ms : i64]
  [me : i64]) : bool
  (and
    (>= (- me ms) 4)
    (compiler-backend-cold-prefix? data ms me "mov")
    (let
      [b3 : i64 (be_state.compiler-backend-peephole-byte-at data (+ ms 3))]
      (or
        (and (= (- me ms) 4) (or (= b3 113) (= b3 108)))
        (and
          (>= (- me ms) 6)
          (or (= b3 122) (= b3 115))
          (let
            [last : i64
              (be_state.compiler-backend-peephole-byte-at data (- me 1))]
            (or (= last 113) (= last 108))))))))

;; True iff the record's line fully overwrites `reg` without reading it, which
;; ends the death scan on this path. Restricted to `movq SRC, %rX`: the kill set
;; may be UNDER-approximated (a missed kill only refuses a fold), so the one
;; shape the emitter reloads with is enough and no wider parse is needed.
(define (compiler-backend-peephole-rmw-clean-overwrite?
  [data : (Ptr u8)]
  [ms : i64]
  [me : i64]
  [end : i64]
  [reg : i64]
  [full-loads? : bool]) : bool
  (let
    [ops : i64
      (if (< me end)
        (+ me 1)
        end)]
    [comma : i64
      (compiler-backend-peephole-find-comma-space-range data ops end)]
    [dst : i64
      (if (and (> comma ops) (< (+ comma 2) end))
        (compiler-backend-peephole-token-reg-index-range data (+ comma 2) end)
        -1)]
    (cond
      [(not (= dst reg)) false]
      ;; `xorl %eX, %eX` / `xorq %rX, %rX` is the zeroing idiom: it names the
      ;; register twice but reads neither copy, so it is a kill even though the
      ;; mention scan would call it a use. Tested BEFORE the width list because
      ;; the general arm below would reject it on exactly that mention.
      [(and
          (or
            (be_operand.compiler-backend-peephole-range-eq? data ms me "xorl")
            (be_operand.compiler-backend-peephole-range-eq? data ms me "xorq"))
          (=
            (compiler-backend-peephole-token-reg-index-range data ops comma)
            reg))
        true]
      ;; Every mnemonic here writes its destination register in FULL: `movq`,
      ;; `movabsq` and `leaq` at 64 bits, `movl` at 32 with the zero-extension
      ;; x86-64 gives every 32-bit destination (plus zero/sign-extending loads
      ;; when `full-loads?` is set). A narrower write (`movb`, `setcc`) would
      ;; leave the upper bytes live and is deliberately absent.
      [(not
          (or
            (be_operand.compiler-backend-peephole-range-eq? data ms me "movq")
            (be_operand.compiler-backend-peephole-range-eq? data ms me "movl")
            (be_operand.compiler-backend-peephole-range-eq?
              data
              ms
              me
              "movabsq")
            (be_operand.compiler-backend-peephole-range-eq? data ms me "leaq")
            (and full-loads? (compiler-backend-leaq-full-load? data ms me))))
        false]
      [else
        (not (compiler-backend-peephole-rmw-mentions-reg? data ops comma reg))])))

;; The record index of the label definition named [ts,te), or -1 when it is not
;; in this group's window. Labels are file-scope in the emitted assembly -- the
;; assembler rejects a duplicate -- so the first match IS the only match.
(define (compiler-backend-peephole-rmw-find-label
  [recs : (& recs (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord))]
  [live : (& live (__tl_dyn-array i64))]
  [lo : i64]
  [hi : i64]
  [from : i64]
  [data : (Ptr u8)]
  [ts : i64]
  [te : i64]) : i64
  (let
    [wlo : i64
      (if (> (- from compiler-backend-peephole-rmw-label-window) lo)
        (- from compiler-backend-peephole-rmw-label-window)
        lo)]
    [whi : i64
      (if (< (+ from compiler-backend-peephole-rmw-label-window) hi)
        (+ from compiler-backend-peephole-rmw-label-window)
        hi)]
    (for [i (iterator.range wlo whi)]
      (when
        (= (array-ref live i) 1)
        (let
          [rec : (& recs be_state.CompilerBackendPeepholeLineRecord)
            (& (array-ref recs i))]
          (when
            (and
              (=
                (compiler-backend-peephole-record-kind rec)
                compiler-backend-sweep-line-kind-label)
              (>
                (compiler-backend-peephole-record-end rec)
                (compiler-backend-peephole-record-start rec))
              (be_operand.compiler-backend-peephole-ranges-eq?
                (compiler-backend-peephole-record-data rec)
                (compiler-backend-peephole-record-start rec)
                (- (compiler-backend-peephole-record-end rec) 1)
                data
                ts
                te))
            (return i)))))
    -1))

;; The bare-symbol branch operand of [start,end), as a [lo,hi) range, or an
;; empty range when the operand is not a bare symbol (an indirect `jmp *%rax`,
;; a memory or table form, anything with a suffix or comment).
(define (compiler-backend-peephole-rmw-branch-target-end
  [data : (Ptr u8)]
  [ops : i64]
  [end : i64]) : i64
  (let
    [i : i64 ops]
    [ok : bool (< ops end)]
    (while (and ok (< i end))
      (let
        [b : i64 (be_state.compiler-backend-peephole-byte-at data i)]
        (when
          (or (= b 32) (= b 9) (= b 42) (= b 37) (= b 40) (= b 44))
          (set! ok false))
        (+= i 1)))
    (if ok
      end
      ops)))

;; Is `reg` a register whose value a `ret` may still carry? %rax and %rdx are
;; the SysV integer return pair; Win64 returns in %rax alone, so refusing both
;; is correct for either target. Nothing else can be read by a return.
(define (compiler-backend-peephole-rmw-return-reg? [reg : i64]) : bool
  (or (= reg 0) (= reg 2)))

;; Is `reg` callee-saved under BOTH supported ABIs (SysV and Win64)? Such a
;; register is never an argument register on either, so a `call` cannot read the
;; value it holds: the callee may save and restore it, which is not a use of the
;; value. Every other register is refused at a call, because if the folded
;; register happened to be an argument register the call WOULD read it and no
;; text between the store and the call would say so.
(define (compiler-backend-peephole-rmw-callee-saved-reg? [reg : i64]) : bool
  (or (= reg 3) (= reg 10) (= reg 11) (= reg 12) (= reg 13)))

;; True iff `reg` is dead at record `start`: on every path forward from there,
;; `reg` is fully overwritten, the function returns without carrying it, or a
;; call that cannot read it is reached -- and no path reads it first.
;;
;; This is a bounded forward reachability walk over the record stream, not a
;; dataflow fixpoint: deadness at a point depends only on what is REACHABLE from
;; that point, so a DFS with a visited stamp answers it exactly. Every arm that
;; cannot be classified refuses, so the answer is conservative by construction:
;; an unknown mnemonic, an unresolvable or indirect branch, a directive (which
;; is where a function body ends), an exhausted budget, and a call that could be
;; passing the register all return false.
(define (compiler-backend-peephole-rmw-reg-dead-after?
  [recs : (& recs (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord))]
  [live : (& live (__tl_dyn-array i64))]
  [lo : i64]
  [hi : i64]
  [visited : (&mut visited (__tl_dyn-array i64))]
  [generation : i64]
  [start : i64]
  [reg : i64]
  [opt2-ext? : bool]) : bool
  (let
    [pending : (__tl_dyn-array i64)
      (__tl_make-array i64 compiler-backend-peephole-rmw-branch-cap)]
    [pending-len : i64 1]
    [budget : i64 compiler-backend-peephole-rmw-scan-cap]
    [lookups : i64 0]
    [pc : i64 0]
    ;; The revisit window's origin -- see the note on the visit bounds.
    [base : i64
      (if (> (- start compiler-backend-peephole-rmw-visit-back) lo)
        (- start compiler-backend-peephole-rmw-visit-back)
        lo)]
    [slot : i64 0]
    [walking : bool false]
    (set! (array-ref pending 0) start)
    (while (or walking (> pending-len 0))
      (unless
        walking
        (-= pending-len 1)
        (set! pc (array-ref pending pending-len))
        (set! walking true))
      (when (or (< pc lo) (>= pc hi)) (return false))
      (set! slot (- pc base))
      (when
        (or (< slot 0) (>= slot compiler-backend-peephole-rmw-visit-window))
        (return false))
      (if (= (array-ref visited slot) generation)
        ;; This record, and therefore everything reachable from it, was
        ;; already proven safe on an earlier path.
        (set! walking false)
        (begin
          (set! (array-ref visited slot) generation)
          (-= budget 1)
          (when (<= budget 0) (return false))
          (if (not (= (array-ref live pc) 1))
            (+= pc 1)
            (let
              [rec : (& recs be_state.CompilerBackendPeepholeLineRecord)
                (& (array-ref recs pc))]
              [kind : i64 (compiler-backend-peephole-record-kind rec)]
              [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
              [rend : i64 (compiler-backend-peephole-record-end rec)]
              [ms : i64 (compiler-backend-peephole-record-mnemonic-start rec)]
              (if (not (= kind compiler-backend-sweep-line-kind-instruction))
                ;; A blank line or a label definition emits no bytes and
                ;; reads nothing; fall through it.
                (+= pc 1)
                (let
                  [me : i64
                    (compiler-backend-peephole-rmw-mnemonic-end data ms rend)]
                  [b0 : i64
                    (be_state.compiler-backend-peephole-byte-at data ms)]
                  (cond
                    ;; A directive ends the function body. Nothing after it
                    ;; is reachable from here, and reading on would classify
                    ;; the NEXT function's text as this path's successor.
                    [(= b0 46) (return false)]
                    [(compiler-backend-peephole-rmw-clean-overwrite?
                        data
                        ms
                        me
                        rend
                        reg
                        opt2-ext?)
                      (set! walking false)]
                    [(compiler-backend-peephole-rmw-mentions-reg?
                        data
                        ms
                        rend
                        reg)
                      (return false)]
                    [(be_operand.compiler-backend-peephole-range-eq?
                        data
                        ms
                        me
                        "ret")
                      (if (compiler-backend-peephole-rmw-return-reg? reg)
                        (return false)
                        (set! walking false))]
                    [(be_operand.compiler-backend-peephole-range-eq?
                        data
                        ms
                        me
                        "call")
                      (cond
                        [(and
                            opt2-ext?
                            (>=
                              (compiler-backend-cold-argless-abort-kind
                                data
                                ms
                                rend)
                              0))
                          (set! walking false)]
                        [(compiler-backend-peephole-rmw-callee-saved-reg? reg)
                          (+= pc 1)]
                        [else (return false)])]
                    [(= b0 106)
                      (let
                        [ops : i64
                          (if (< (+ me 1) rend)
                            (+ me 1)
                            rend)]
                        [te : i64
                          (compiler-backend-peephole-rmw-branch-target-end
                            data
                            ops
                            rend)]
                        [_spend : unit (+= lookups 1)]
                        [target : i64
                          (if (and
                            (> te ops)
                            (<=
                              lookups
                              compiler-backend-peephole-rmw-label-lookup-cap))
                            (compiler-backend-peephole-rmw-find-label
                              recs
                              live
                              lo
                              hi
                              pc
                              data
                              ops
                              te)
                            -1)]
                        (when (< target 0) (return false))
                        (if (be_operand.compiler-backend-peephole-range-eq?
                          data
                          ms
                          me
                          "jmp")
                          (set! pc target)
                          (begin
                            (when
                              (>=
                                pending-len
                                compiler-backend-peephole-rmw-branch-cap)
                              (return false))
                            (set! (array-ref pending pending-len) target)
                            (+= pending-len 1)
                            (+= pc 1))))]
                    [(and
                        (compiler-backend-peephole-rmw-transparent-mnemonic?
                          data
                          ms
                          me)
                        ;; 1-operand `imulq`/`imull` implicitly reads %rax and writes %rdx:%rax.
                        (or
                          (!= b0 105)
                          (>
                            (compiler-backend-peephole-find-comma-space-range
                              data
                              (if (< (+ me 1) rend)
                                (+ me 1)
                                rend)
                              rend)
                            me)))
                      (+= pc 1)]
                    [else (return false)]))))))))
    true))

;; The folded line's text, built from the three records' own bytes.
(define (compiler-backend-peephole-rmw-folded-line
  [op-src : String]
  [op-ms : i64]
  [op-me : i64]
  [src-start : i64]
  [src-end : i64]
  [mem-src : String]
  [mem-start : i64]
  [mem-end : i64]
  [two-operand? : bool]) : String
  (let
    [mnemonic : String (string.substring op-src op-ms (- op-me op-ms))]
    [mem : String (string.substring mem-src mem-start (- mem-end mem-start))]
    (if two-operand?
      (str_cat.str-cat
        (str_cat.str-cat
          "    "
          mnemonic
          " "
          (string.substring op-src src-start (- src-end src-start)))
        ", "
        mem
        "")
      (str_cat.str-cat "    " mnemonic " " mem))))

;; Fold every triple the walk recognized in one group's record stream. The walk
;; recorded the OP's record index; the load is the record before it and the
;; store the record after, because recognition ran over this same sink in
;; emission order.
;;
;; Two candidate spans can overlap only by sharing one end record, and then at
;; most one of them is admissible: the shared record would have to be a store
;; for the earlier span and a load for the later one, and `movq %rX, M` is not
;; `movq M, %rX`. An earlier fold can therefore never rewrite a later
;; candidate's lines -- and if it somehow did, the liveness re-check below would
;; drop the later span rather than fold a rewritten line.
;;
;; Everything the walk could not know is decided HERE: whether
;; the two neighbours are moves at all, whether the dead-frame-store sweep has
;; since killed one of the three lines, whether the two memory operands are one
;; of the two stable-address shapes and name the same address, whether the ALU
;; source is admissible, and whether register death permits the one-instruction
;; form or the result must be reloaded.
(define (compiler-backend-peephole-rmw-fold-candidates!
  [backend-state : be_state.CompilerBackendState]
  [stream : be_state.CompilerBackendStreamState]
  [v : be_state.CompilerBackendPeepholeLineVec]) : unit
  ;; A group the walk found no window in reaches this and stops: no array is
  ;; allocated, no record is read, and nothing below runs.
  (if (= v.rmw-cand-len 0)
    unit
    (compiler-backend-peephole-rmw-fold-candidate-spans! backend-state stream v)))

(define (compiler-backend-peephole-rmw-fold-candidate-spans!
  [backend-state : be_state.CompilerBackendState]
  [stream : be_state.CompilerBackendStreamState]
  [v : be_state.CompilerBackendPeepholeLineVec]) : unit
  (let
    [cands : (__tl_dyn-array i64) v.rmw-cands]
    [cand-count : i64 v.rmw-cand-len]
    [recs : (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord) v.lines]
    [live : (__tl_dyn-array i64) v.live]
    [count : i64 v.len]
    [visited : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [visited-ready : bool false]
    [generation : i64 0]
    (for [ci (iterator.range 0 cand-count)]
      (let
        [alu-at : i64 (array-ref cands ci)]
        [load-at : i64 (- alu-at 1)]
        [store-at : i64 (+ alu-at 1)]
        (when
          (and
            (>= load-at 0)
            (< store-at count)
            (= (array-ref live load-at) 1)
            (= (array-ref live alu-at) 1)
            (= (array-ref live store-at) 1))
          (let
            [lrec : be_state.CompilerBackendPeepholeLineRecord
              (be_state.compiler-backend-global-array-element-shared-view
                recs
                load-at)]
            [arec : be_state.CompilerBackendPeepholeLineRecord
              (be_state.compiler-backend-global-array-element-shared-view
                recs
                alu-at)]
            [srec : be_state.CompilerBackendPeepholeLineRecord
              (be_state.compiler-backend-global-array-element-shared-view
                recs
                store-at)]
            [ldata : (Ptr u8) (compiler-backend-peephole-record-data lrec)]
            [lstart : i64 (compiler-backend-peephole-record-start lrec)]
            [lend : i64 (compiler-backend-peephole-record-end lrec)]
            [adata : (Ptr u8) (compiler-backend-peephole-record-data arec)]
            [aend : i64 (compiler-backend-peephole-record-end arec)]
            [sdata : (Ptr u8) (compiler-backend-peephole-record-data srec)]
            [sstart : i64 (compiler-backend-peephole-record-start srec)]
            [send : i64 (compiler-backend-peephole-record-end srec)]
            [lops : i64 (+ lstart (compiler-backend-peephole-movq-prefix-len))]
            [sops : i64 (+ sstart (compiler-backend-peephole-movq-prefix-len))]
            ;; The two ends of the window, cheapest test first. Most
            ;; foldable ops do not sit between two moves; of those that do,
            ;; the load's source has to be something other than a bare
            ;; register and the store's source has to be one, which is two
            ;; bytes and retires many more before an operand is scanned.
            [moves? : bool
              (and
                (compiler-backend-peephole-movq-prefix-at-range?
                  ldata
                  lstart
                  lend)
                (compiler-backend-peephole-movq-prefix-at-range?
                  sdata
                  sstart
                  send)
                (not
                  (= (be_state.compiler-backend-peephole-byte-at ldata lops) 37))
                (= (be_state.compiler-backend-peephole-byte-at sdata sops) 37))]
            ;; The op's own mnemonic is re-read from the RECORDED bytes, so
            ;; a line the walk rewrote after the sink classified it cannot
            ;; carry a stale answer into the fold -- but only once the
            ;; neighbours have proven they are the moves the fold needs.
            [ams : i64
              (if moves?
                (compiler-backend-peephole-record-mnemonic-start arec)
                0)]
            [ame : i64
              (if moves?
                (compiler-backend-peephole-rmw-mnemonic-end adata ams aend)
                ams)]
            [alu-kind : i64
              (if moves?
                (compiler-backend-peephole-rmw-alu-kind adata ams ame)
                0)]
            [candidate? : bool (> alu-kind 0)]
            [lcomma : i64
              (if candidate?
                (compiler-backend-peephole-find-comma-space-range
                  ldata
                  lops
                  lend)
                -1)]
            [scomma : i64
              (if candidate?
                (compiler-backend-peephole-find-comma-space-range
                  sdata
                  sops
                  send)
                -1)]
            [aops : i64
              (if (< (+ ame 1) aend)
                (+ ame 1)
                aend)]
            [acomma : i64
              (if (and candidate? (= alu-kind 1))
                (compiler-backend-peephole-find-comma-space-range
                  adata
                  aops
                  aend)
                -1)]
            ;; The register the triple loads, operates on and stores.
            [reg : i64
              (if (and candidate? (> lcomma lops) (< (+ lcomma 2) lend))
                (compiler-backend-peephole-reg-index-range
                  ldata
                  (+ lcomma 2)
                  lend)
                -1)]
            [alu-dst : i64
              (cond
                [(not candidate?) -1]
                [(= alu-kind 2)
                  (compiler-backend-peephole-reg-index-range adata aops aend)]
                [(and (> acomma aops) (< (+ acomma 2) aend))
                  (compiler-backend-peephole-reg-index-range
                    adata
                    (+ acomma 2)
                    aend)]
                [else -1])]
            [store-src : i64
              (if (and candidate? (> scomma sops) (< (+ scomma 2) send))
                (compiler-backend-peephole-reg-index-range sdata sops scomma)
                -1)]
            ;; The ALU source: `$imm`, or a tracked register that is not
            ;; the triple's own register.
            [alu-src-ok : bool
              (or
                (= alu-kind 2)
                (and
                  (> acomma aops)
                  (or
                    (=
                      (be_state.compiler-backend-peephole-byte-at adata aops)
                      36)
                    (let
                      [sreg : i64
                        (compiler-backend-peephole-reg-index-range
                          adata
                          aops
                          acomma)]
                      (and (>= sreg 0) (not (= sreg reg)))))))]
            [shape-ok : bool
              (and
                candidate?
                (>= reg 0)
                (= alu-dst reg)
                (= store-src reg)
                alu-src-ok
                (compiler-backend-peephole-rmw-mem-operand? ldata lops lcomma)
                (be_operand.compiler-backend-peephole-ranges-eq?
                  ldata
                  lops
                  lcomma
                  sdata
                  (+ scomma 2)
                  send))]
            (when
              shape-ok
              ;; One fixed-size stamp window for the whole group, cleared
              ;; once and then distinguished per candidate by the
              ;; generation counter.
              (unless
                visited-ready
                (set!
                  visited
                  (__tl_make-array
                    i64
                    compiler-backend-peephole-rmw-visit-window))
                (for [k
                  (iterator.range 0 compiler-backend-peephole-rmw-visit-window)]
                  (set! (array-ref visited k) 0))
                (set! visited-ready true))
              (+= generation 1)
              (let
                [dead? : bool
                  (compiler-backend-peephole-rmw-reg-dead-after?
                    (& recs)
                    (& live)
                    0
                    count
                    (&mut visited)
                    generation
                    (+ store-at 1)
                    reg
                    false)]
                ;; RMW-3: the register still holds the result after the
                ;; store (or the bounded scan could not prove otherwise).
                ;; The triple folds all the same, and the store's line
                ;; becomes the LOAD's line: `op src, M ; movq M, %rX` is
                ;; two instructions for the three, reads back exactly the
                ;; word the folded op wrote, and leaves %rX and EFLAGS as
                ;; the triple did (`movq` writes no flags). The text of
                ;; the reload is taken BEFORE the load's record is
                ;; overwritten.
                [reload-text : String
                  (if dead?
                    ""
                    (string.substring lrec.src lstart (- lend lstart)))]
                [store-newline? : bool
                  (compiler-backend-peephole-record-newline? srec)]
                [load-newline? : bool
                  (compiler-backend-peephole-record-newline? lrec)]
                [folded : String
                  (compiler-backend-peephole-rmw-folded-line
                    arec.src
                    ams
                    ame
                    aops
                    acomma
                    lrec.src
                    lops
                    lcomma
                    (= alu-kind 1))]
                [line : be_state.CompilerBackendPeepholeLine
                  (compiler-backend-peephole-owned-line
                    backend-state
                    stream
                    folded
                    (if dead?
                      store-newline?
                      load-newline?))]
                (begin
                  (set!
                    (array-ref recs load-at)
                    (compiler-backend-peephole-line-record line))
                  (set! (array-ref live alu-at) 0)
                  (if dead?
                    (set! (array-ref live store-at) 0)
                    (let
                      [reload : be_state.CompilerBackendPeepholeLine
                        (compiler-backend-peephole-owned-line
                          backend-state
                          stream
                          reload-text
                          store-newline?)]
                      (set!
                        (array-ref recs store-at)
                        (compiler-backend-peephole-line-record reload))))
                  (cfg
                    test
                    (if dead?
                      (be_state.compiler-backend-metric-add!
                        backend-state
                        be_state.compiler-backend-peephole-rmw-folded-metric
                        1)
                      (be_state.compiler-backend-metric-add!
                        backend-state
                        be_state.compiler-backend-peephole-rmw-refused-metric
                        1))
                    unit))))))))
    unit))

;; ---------------------------------------------------------------------------
;; Post-emission `.text` compactions (gated at opt-level-full?, >= 2):
;;   1. Dead-in-block `leaq -> mem` folding
;;   2. Contiguous zero-store coalescing (`xorps` + `movups` / `movq`)
;;   3. `jcc; jmp` inversion, multi-label fallthrough `jmp` drop, and
;;      per-function argless cold abort-stub deduplication.
;; All temporary tables stay in per-function scratch arenas; replacement lines
;; live in the caller's peephole arena (or home arena for post-tail cleanup).
;; ---------------------------------------------------------------------------
(define (compiler-backend-compact-replace-insn!
  [v : (&mut v be_state.CompilerBackendPeepholeLineVec)]
  [index : i64]
  [text : String]
  [home : arena.Arena]
  [jmp? : bool]) : unit
  (let
    [len : i64 (string.string-length (& text))]
    [owned : String
      (unsafe
        (in-arena
          (arena.Arena (arena.raw-handle home))
          (string.substring text 0 len)))]
    [old-meta : i64 (array-ref v.lines index).meta]
    [meta : i64
      (bit-or
        compiler-backend-peephole-record-owned-bit
        (bit-or
          compiler-backend-sweep-line-kind-instruction
          (bit-or
            (bit-and old-meta compiler-backend-peephole-record-newline-bit)
            (if jmp?
              (shl
                compiler-backend-sweep-line-flag-jmp
                compiler-backend-peephole-record-flags-shift)
              0))))]
    (set!
      (array-ref v.lines index)
      (be_state.CompilerBackendPeepholeLineRecord
        owned
        (shl len compiler-backend-peephole-record-span-shift)
        meta
        0
        0
        0))))

(define (compiler-backend-compact-step-live
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [idx : i64]
  [bound : i64]
  [delta : i64]) : i64
  (let
    [k : i64 (+ idx delta)]
    (while (and
      (if (> delta 0)
        (< k bound)
        (>= k bound))
      (= (array-ref v.live k) 0))
      (+= k delta))
    (if (if (> delta 0)
      (< k bound)
      (>= k bound))
      k
      -1)))

;; Skip Win64 SEH prologue directives/instructions so `.seh_*` unwind metadata
;; never drifts. Returns `lo` for non-SEH functions, the first record after
;; `.seh_endprologue` for SEH functions, or -1 if `.seh_proc` has no end marker.
(define (compiler-backend-compact-body-start
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [lo : i64]
  [hi : i64]) : i64
  (let
    [saw-seh : bool false]
    [after-pro : i64 -1]
    (for [i (iterator.range lo hi)]
      (when
        (= (array-ref v.live i) 1)
        (let
          [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
            (& (array-ref v.lines i))]
          (when
            (=
              (compiler-backend-peephole-record-kind rec)
              compiler-backend-sweep-line-kind-skip)
            (let
              [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
              [s : i64 (compiler-backend-peephole-record-start rec)]
              [e : i64 (compiler-backend-peephole-record-end rec)]
              [first : i64 (compiler-backend-cold-line-first data s e)]
              (when
                (and
                  (< first e)
                  (= (be_state.compiler-backend-peephole-byte-at data first) 46))
                (cond
                  [(compiler-backend-cold-prefix? data first e ".seh_proc")
                    (set! saw-seh true)]
                  [(compiler-backend-cold-prefix?
                      data
                      first
                      e
                      ".seh_endprologue")
                    (set! after-pro (+ i 1))]
                  [else unit])))))))
    (if saw-seh
      after-pro
      lo)))

;; 64-bit GP register id: 0..13 tracked, 14 %rsp, 15 %rbp, -1 otherwise.
(define (compiler-backend-compact-gp64-id [data : (Ptr u8)] [s : i64] [e : i64]) : i64
  (let
    [r : i64 (compiler-backend-peephole-reg-index-range data s e)]
    (cond
      [(>= r 0) r]
      [(be_operand.compiler-backend-peephole-range-eq? data s e "%rsp") 14]
      [(be_operand.compiler-backend-peephole-range-eq? data s e "%rbp") 15]
      [else -1])))

(define (compiler-backend-compact-gp64-name [id : i64]) : String
  (cond
    [(= id 0) "%rax"]
    [(= id 1) "%rcx"]
    [(= id 2) "%rdx"]
    [(= id 3) "%rbx"]
    [(= id 4) "%rsi"]
    [(= id 5) "%rdi"]
    [(= id 6) "%r8"]
    [(= id 7) "%r9"]
    [(= id 8) "%r10"]
    [(= id 9) "%r11"]
    [(= id 10) "%r12"]
    [(= id 11) "%r13"]
    [(= id 12) "%r14"]
    [(= id 13) "%r15"]
    [(= id 14) "%rsp"]
    [else "%rbp"]))

(define (compiler-backend-compact-base-extra [id : i64] [disp : i64]) : i64
  (+
    (if (or (= id 14) (= id 10))
      1
      0)
    (cond
      [(and (= disp 0) (!= id 15) (!= id 11)) 0]
      [(and (>= disp -128) (<= disp 127)) 1]
      [else 4])))

(define (compiler-backend-compact-signed-int?
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : bool
  (if (>= s e)
    false
    (let
      [p : i64
        (if (= (be_state.compiler-backend-peephole-byte-at data s) 45)
          (+ s 1)
          s)]
      (if (or (>= p e) (> (- e p) 10))
        false
        (let
          [i : i64 p]
          (while (< i e)
            (let
              [b : i64 (be_state.compiler-backend-peephole-byte-at data i)]
              (when (or (< b 48) (> b 57)) (return false)))
            (+= i 1))
          true)))))

;; Parse [s,e) as `[disp](%reg)` where %reg is a 64-bit GP reg.
;; Writes (base-id, disp, lparen) into `out[off..off+2]` and returns true on match.
(define (compiler-backend-compact-parse-base-mem!
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]
  [out : (&mut out (__tl_dyn-array i64))]
  [off : i64]) : bool
  (let
    [lp : i64
      (be_operand.compiler-backend-peephole-scan-byte-range data s e 40)]
    (when
      (or
        (>= lp e)
        (<= (- e lp) 3)
        (!= (be_state.compiler-backend-peephole-byte-at data (- e 1)) 41))
      (return false))
    (let
      [id : i64 (compiler-backend-compact-gp64-id data (+ lp 1) (- e 1))]
      (when (< id 0) (return false))
      (let
        [d : i64
          (cond
            [(= lp s) 0]
            [(compiler-backend-compact-signed-int? data s lp)
              (compiler-backend-rsp-rebase-parse-int data s lp)]
            [else (return false)])]
        (unless (be_operand.compiler-backend-imm32? d) (return false))
        (set! (array-ref out off) id)
        (set! (array-ref out (+ off 1)) d)
        (set! (array-ref out (+ off 2)) lp)
        true))))

;; Parse [s,e) as LEA memory operand into `out[0..5]`:
;;   out[0]=kind (1=rip, 2=base, 3=idx), out[1]=disp, out[2]=reg-mask,
;;   out[3]=extra, out[4]=ext-bit(0/1), out[5]=lparen.
(define (compiler-backend-compact-parse-lea-addr!
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]
  [out : (&mut out (__tl_dyn-array i64))]) : bool
  (let
    [lp : i64
      (be_operand.compiler-backend-peephole-scan-byte-range data s e 40)]
    (when
      (or
        (>= lp e)
        (<= (- e lp) 3)
        (!= (be_state.compiler-backend-peephole-byte-at data (- e 1)) 41))
      (return false))
    (when
      (and
        (> lp s)
        (be_operand.compiler-backend-peephole-range-eq? data lp e "(%rip)"))
      (when
        (<
          (be_operand.compiler-backend-peephole-scan-byte-range data s lp 37)
          lp)
        (return false))
      (set! (array-ref out 0) 1)
      (set! (array-ref out 1) 0)
      (set! (array-ref out 2) 0)
      (set! (array-ref out 3) 4)
      (set! (array-ref out 4) 0)
      (set! (array-ref out 5) lp)
      (return true))
    (let
      [disp : i64
        (cond
          [(= lp s) 0]
          [(compiler-backend-compact-signed-int? data s lp)
            (compiler-backend-rsp-rebase-parse-int data s lp)]
          [else (return false)])]
      (unless (be_operand.compiler-backend-imm32? disp) (return false))
      (let
        [c1 : i64
          (be_operand.compiler-backend-peephole-scan-byte-range
            data
            (+ lp 1)
            (- e 1)
            44)]
        (if (>= c1 (- e 1))
          (let
            [bid : i64 (compiler-backend-compact-gp64-id data (+ lp 1) (- e 1))]
            (when (< bid 0) (return false))
            (set! (array-ref out 0) 2)
            (set! (array-ref out 1) disp)
            (set! (array-ref out 2) (shl 1 bid))
            (set!
              (array-ref out 3)
              (compiler-backend-compact-base-extra bid disp))
            (set!
              (array-ref out 4)
              (if (and (>= bid 6) (<= bid 13))
                1
                0))
            (set! (array-ref out 5) lp)
            true)
          (let
            [has-base? : bool (> c1 (+ lp 1))]
            [bid : i64
              (if has-base?
                (compiler-backend-compact-gp64-id data (+ lp 1) c1)
                -1)]
            [c2 : i64
              (be_operand.compiler-backend-peephole-scan-byte-range
                data
                (+ c1 1)
                (- e 1)
                44)]
            [iid : i64
              (compiler-backend-compact-gp64-id
                data
                (+ c1 1)
                (if (< c2 (- e 1))
                  c2
                  (- e 1)))]
            (when
              (or
                (and has-base? (< bid 0))
                (< iid 0)
                (= iid 14)
                (and
                  (< c2 (- e 1))
                  (or
                    (!= (- (- e 1) (+ c2 1)) 1)
                    (let
                      [sb : i64
                        (be_state.compiler-backend-peephole-byte-at
                          data
                          (+ c2 1))]
                      (and (!= sb 49) (!= sb 50) (!= sb 52) (!= sb 56))))))
              (return false))
            (set! (array-ref out 0) 3)
            (set! (array-ref out 1) disp)
            (set!
              (array-ref out 2)
              (bit-or
                (if has-base?
                  (shl 1 bid)
                  0)
                (shl 1 iid)))
            (set!
              (array-ref out 3)
              (+
                1
                (if has-base?
                  (cond
                    [(and (= disp 0) (!= bid 15) (!= bid 11)) 0]
                    [(and (>= disp -128) (<= disp 127)) 1]
                    [else 4])
                  4)))
            (set!
              (array-ref out 4)
              (if (or
                (and has-base? (>= bid 6) (<= bid 13))
                (and (>= iid 6) (<= iid 13)))
                1
                0))
            (set! (array-ref out 5) lp)
            true))))))

;; ---------------------------------------------------------------------------
;; Compaction 1: Dead-in-block `leaq -> mem` folding (1..6 consumers)
;; ---------------------------------------------------------------------------
;; Reuse RMW's transparent mnemonic list and exclude mnemonics that cannot take
;; a general memory operand in place of `d(%R)` (`push`/`pop`/`set`/`cmov`/
;; `nop`/`dec`/`bt`/`shl`/`shr`/`sar`/`neg`/`not`/`movabsq`/`leal`, plus
;; `imul`/`leaq` when the memory operand is in dst position).
(define (compiler-backend-leaq-consumer-mnemonic?
  [data : (Ptr u8)]
  [ms : i64]
  [me : i64]
  [op1-is-mem? : bool]) : bool
  (unless
    (compiler-backend-peephole-rmw-transparent-mnemonic? data ms me)
    (return false))
  (let
    [b0 : i64 (be_state.compiler-backend-peephole-byte-at data ms)]
    [b1 : i64
      (if (< (+ ms 1) me)
        (be_state.compiler-backend-peephole-byte-at data (+ ms 1))
        0)]
    (cond
      [(or (= b0 112) (= b0 110) (= b0 100) (= b0 98) (= b0 118)) false]
      [(= b0 109)
        (not
          (be_operand.compiler-backend-peephole-range-eq? data ms me "movabsq"))]
      [(= b0 99)
        (and
          (= b1 109)
          (not
            (= (be_state.compiler-backend-peephole-byte-at data (+ ms 2)) 111)))]
      [(= b0 115) (= b1 117)]
      [(= b0 105) op1-is-mem?]
      [(= b0 108)
        (and
          op1-is-mem?
          (be_operand.compiler-backend-peephole-range-eq? data ms me "leaq"))]
      [else true])))

(define (compiler-backend-leaq-intervening-safe?
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]
  [addr-mask : i64]) : bool
  (when
    (!=
      (compiler-backend-peephole-record-kind rec)
      compiler-backend-sweep-line-kind-instruction)
    (return false))
  (let
    [flags : i64 (compiler-backend-peephole-record-flags rec)]
    [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
    [rend : i64 (compiler-backend-peephole-record-end rec)]
    [ms : i64 (compiler-backend-peephole-record-mnemonic-start rec)]
    [me : i64 (compiler-backend-peephole-rmw-mnemonic-end data ms rend)]
    [b0 : i64 (be_state.compiler-backend-peephole-byte-at data ms)]
    (when
      (or
        (= b0 46)
        (= b0 106)
        (= b0 112)
        (not (compiler-backend-peephole-rmw-transparent-mnemonic? data ms me))
        (and (!= (bit-and addr-mask 16384) 0) (!= (bit-and flags 139) 0)))
      (return false))
    (let
      [ops : i64
        (if (< (+ me 1) rend)
          (+ me 1)
          rend)]
      [comma : i64
        (compiler-backend-peephole-find-comma-space-range data ops rend)]
      (when (or (<= comma ops) (>= (+ comma 2) rend)) (return false))
      (let
        [ds : i64 (+ comma 2)]
        ;; Reject 3-operand forms (`imulq $imm, (%rsp), %rbx`, `vpextrq $0, %xmm0, %rbx`)
        ;; so the destination register after the second `, ` cannot be mistaken for a
        ;; safe memory/XMM second operand.
        (when
          (>=
            (compiler-backend-peephole-find-comma-space-range data ds rend)
            ds)
          (return false))
        (when
          (or
            (and (= b0 99) (compiler-backend-cold-prefix? data ms me "cmp"))
            (and (= b0 116) (compiler-backend-cold-prefix? data ms me "test")))
          (return true))
        (cond
          [(<
              (be_operand.compiler-backend-peephole-scan-byte-range
                data
                ds
                rend
                40)
              rend)
            true]
          [(and
              (>= (- rend ds) 5)
              (= (be_state.compiler-backend-peephole-byte-at data ds) 37)
              (= (be_state.compiler-backend-peephole-byte-at data (+ ds 2)) 109)
              (= (be_state.compiler-backend-peephole-byte-at data (+ ds 3)) 109))
            true]
          [else
            (let
              [tr : i64
                (compiler-backend-peephole-token-reg-index-range data ds rend)]
              [hr : i64
                (if (< tr 0)
                  (compiler-backend-peephole-rmw-high-byte-reg-index
                    data
                    ds
                    rend)
                  tr)]
              (cond
                [(>= hr 0) (= (bit-and addr-mask (shl 1 hr)) 0)]
                [(be_operand.compiler-backend-peephole-range-eq?
                    data
                    ds
                    rend
                    "%rsp")
                  (= (bit-and addr-mask 16384) 0)]
                [(be_operand.compiler-backend-peephole-range-eq?
                    data
                    ds
                    rend
                    "%rbp")
                  (= (bit-and addr-mask 32768) 0)]
                [else false]))])))))

(define (compiler-backend-leaq-new-extra
  [lrec : (& lrec be_state.CompilerBackendPeepholeLineRecord)]
  [addr-kind : i64]
  [addr-lp : i64]
  [addr-end : i64]
  [d-new : i64]) : i64
  (cond
    [(= addr-kind 1) 4]
    [(= addr-kind 2)
      (compiler-backend-compact-base-extra
        (compiler-backend-compact-gp64-id
          (compiler-backend-peephole-record-data lrec)
          (+ addr-lp 1)
          (- addr-end 1))
        d-new)]
    [else
      (let
        [ldata : (Ptr u8) (compiler-backend-peephole-record-data lrec)]
        [c1 : i64
          (be_operand.compiler-backend-peephole-scan-byte-range
            ldata
            (+ addr-lp 1)
            (- addr-end 1)
            44)]
        (+
          1
          (if (> c1 (+ addr-lp 1))
            (let
              [bid : i64
                (compiler-backend-compact-gp64-id ldata (+ addr-lp 1) c1)]
              (cond
                [(and (= d-new 0) (!= bid 15) (!= bid 11)) 0]
                [(and (>= d-new -128) (<= d-new 127)) 1]
                [else 4]))
            4)))]))

(define (compiler-backend-leaq-direct-reg-op?
  [data : (Ptr u8)]
  [ms : i64]
  [me : i64]) : i64
  ;; Returns 1 for `movq`, 2 for `cmpq`, 3 for `addq`/`subq`/`andq`/`orq`/`xorq`, 0 otherwise.
  (cond
    [(be_operand.compiler-backend-peephole-range-eq? data ms me "movq") 1]
    [(be_operand.compiler-backend-peephole-range-eq? data ms me "cmpq") 2]
    [(or
        (be_operand.compiler-backend-peephole-range-eq? data ms me "addq")
        (be_operand.compiler-backend-peephole-range-eq? data ms me "subq")
        (be_operand.compiler-backend-peephole-range-eq? data ms me "andq")
        (be_operand.compiler-backend-peephole-range-eq? data ms me "orq")
        (be_operand.compiler-backend-peephole-range-eq? data ms me "xorq"))
      3]
    [else 0]))

(define (compiler-backend-leaq-fold-function!
  [v : (&mut v be_state.CompilerBackendPeepholeLineVec)]
  [lo : i64]
  [hi : i64]
  [home : arena.Arena]) : unit
  (let
    [body-lo : i64 (compiler-backend-compact-body-start v lo hi)]
    (when (or (< body-lo 0) (>= (+ body-lo 1) hi)) (return unit))
    ;; One scratch buffer holds parsed LEA/MOV fields [0..5], base-mem scratch [6..11],
    ;; and up to 6 consumers (ci, op1m, d-new) in [12..29].
    (let
      [buf : (__tl_dyn-array i64) (__tl_make-array i64 30)]
      [visited : (__tl_dyn-array i64) (__tl_make-array i64 0)]
      [visited-ready : bool false]
      [generation : i64 0]
      (for [i (iterator.range body-lo (- hi 1))]
        (when
          (= (array-ref v.live i) 1)
          (let
            [mode : i64 0]
            ;; mode: 0=none, 1=leaq, 2=movq reg->reg, 3=movq mem->reg,
            ;;       4=movzbl mem->reg32, 5=movq reg->mem (store-reload)
            [dst-reg : i64 -1]
            [src-reg : i64 -1]
            [addr-start : i64 0]
            [addr-end : i64 0]
            (let
              [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
                (& (array-ref v.lines i))]
              (when
                (=
                  (compiler-backend-peephole-record-kind rec)
                  compiler-backend-sweep-line-kind-instruction)
                (let
                  [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
                  [rs : i64 (compiler-backend-peephole-record-start rec)]
                  [re : i64 (compiler-backend-peephole-record-end rec)]
                  (cond
                    [(compiler-backend-cold-prefix? data rs re "    leaq ")
                      (let
                        [ops : i64 (+ rs 9)]
                        [comma : i64
                          (compiler-backend-peephole-find-comma-space-range
                            data
                            ops
                            re)]
                        (when
                          (and (> comma ops) (< (+ comma 2) re))
                          (let
                            [r : i64
                              (compiler-backend-peephole-reg-index-range
                                data
                                (+ comma 2)
                                re)]
                            (when
                              (and
                                (>= r 0)
                                (compiler-backend-compact-parse-lea-addr!
                                  data
                                  ops
                                  comma
                                  (&mut buf)))
                              (set! mode 1)
                              (set! dst-reg r)
                              (set! addr-start ops)
                              (set! addr-end comma)
                              (when
                                (and
                                  (= (array-ref buf 0) 2)
                                  (= (array-ref buf 1) 0))
                                (set!
                                  src-reg
                                  (compiler-backend-compact-gp64-id
                                    data
                                    (+ (array-ref buf 5) 1)
                                    (- comma 1))))))))]
                    [(compiler-backend-cold-prefix? data rs re "    movq ")
                      (let
                        [ops : i64 (+ rs 9)]
                        [comma : i64
                          (compiler-backend-peephole-find-comma-space-range
                            data
                            ops
                            re)]
                        (when
                          (and (> comma ops) (< (+ comma 2) re))
                          (let
                            [r : i64
                              (compiler-backend-peephole-reg-index-range
                                data
                                (+ comma 2)
                                re)]
                            [sr : i64
                              (compiler-backend-compact-gp64-id data ops comma)]
                            (cond
                              [(and (>= r 0) (>= sr 0))
                                (set! mode 2)
                                (set! dst-reg r)
                                (set! src-reg sr)
                                (set! addr-start ops)
                                (set! addr-end comma)
                                (set! (array-ref buf 0) 2)
                                (set! (array-ref buf 1) 0)
                                (set! (array-ref buf 2) (shl 1 sr))
                                (set! (array-ref buf 3) 0)
                                (set! (array-ref buf 4) 0)
                                (set! (array-ref buf 5) ops)]
                              [(and
                                (>= r 0)
                                (<
                                  (be_operand.compiler-backend-peephole-scan-byte-range
                                    data
                                    ops
                                    comma
                                    40)
                                  comma)
                                (=
                                  (be_operand.compiler-backend-peephole-scan-byte-range
                                    data
                                    ops
                                    comma
                                    58)
                                  comma))
                                (set! mode 3)
                                (set! dst-reg r)
                                (set! addr-start ops)
                                (set! addr-end comma)]
                              [(and
                                (>= sr 0)
                                (compiler-backend-compact-parse-base-mem!
                                  data
                                  (+ comma 2)
                                  re
                                  (&mut buf)
                                  6))
                                (set! mode 5)
                                (set! src-reg sr)
                                (set! addr-start (+ comma 2))
                                (set! addr-end re)]
                              [else unit]))))]
                    [(compiler-backend-cold-prefix? data rs re "    movzbl ")
                      (let
                        [ops : i64 (+ rs 11)]
                        [comma : i64
                          (compiler-backend-peephole-find-comma-space-range
                            data
                            ops
                            re)]
                        (when
                          (and
                            (> comma ops)
                            (< (+ comma 2) re)
                            (<
                              (be_operand.compiler-backend-peephole-scan-byte-range
                                data
                                ops
                                comma
                                40)
                              comma)
                            (=
                              (be_operand.compiler-backend-peephole-scan-byte-range
                                data
                                ops
                                comma
                                58)
                              comma))
                          (let
                            [r : i64
                              (compiler-backend-peephole-token-reg-index-range
                                data
                                (+ comma 2)
                                re)]
                            (when
                              (>= r 0)
                              (set! mode 4)
                              (set! dst-reg r)
                              (set! addr-start ops)
                              (set! addr-end comma)))))]
                    [else unit]))))
            (cond
              [(and
                  (or (= mode 1) (= mode 2))
                  (= src-reg dst-reg)
                  (>= src-reg 0))
                ;; `leaq (%R), %R` or `movq %R, %R` is a pure no-op.
                (set! (array-ref v.live i) 0)]
              [(= mode 5)
                ;; Store-reload: `movq %r1, d(%base); movq d(%base), %r2` ->
                ;; drop if r1 == r2, else `movq %r1, %r2` when strictly smaller.
                (let
                  [ci : i64 (compiler-backend-compact-step-live v i hi 1)]
                  [r2 : i64 -1]
                  (when
                    (>= ci 0)
                    (let
                      [lrec : (& v be_state.CompilerBackendPeepholeLineRecord)
                        (& (array-ref v.lines i))]
                      [crec : (& v be_state.CompilerBackendPeepholeLineRecord)
                        (& (array-ref v.lines ci))]
                      (when
                        (=
                          (compiler-backend-peephole-record-kind crec)
                          compiler-backend-sweep-line-kind-instruction)
                        (let
                          [cdata : (Ptr u8)
                            (compiler-backend-peephole-record-data crec)]
                          [cs : i64
                            (compiler-backend-peephole-record-start crec)]
                          [ce : i64 (compiler-backend-peephole-record-end crec)]
                          (when
                            (compiler-backend-cold-prefix?
                              cdata
                              cs
                              ce
                              "    movq ")
                            (let
                              [cc : i64
                                (compiler-backend-peephole-find-comma-space-range
                                  cdata
                                  (+ cs 9)
                                  ce)]
                              (when
                                (and
                                  (> cc (+ cs 9))
                                  (< (+ cc 2) ce)
                                  (be_operand.compiler-backend-peephole-ranges-eq?
                                    cdata
                                    (+ cs 9)
                                    cc
                                    (compiler-backend-peephole-record-data lrec)
                                    addr-start
                                    addr-end))
                                (let
                                  [dr2 : i64
                                    (compiler-backend-peephole-reg-index-range
                                      cdata
                                      (+ cc 2)
                                      ce)]
                                  (when (>= dr2 0) (set! r2 dr2))))))))))
                  (when
                    (>= r2 0)
                    (if (= r2 src-reg)
                      (set! (array-ref v.live ci) 0)
                      (when
                        (>
                          (compiler-backend-compact-base-extra
                            (array-ref buf 6)
                            (array-ref buf 7))
                          0)
                        (compiler-backend-compact-replace-insn!
                          v
                          ci
                          (str_cat.str-cat
                            "    movq "
                            (compiler-backend-compact-gp64-name src-reg)
                            ", "
                            (compiler-backend-compact-gp64-name r2))
                          home
                          false)))))]
              [(= mode 4)
                ;; Dead 1-use `movzbl MEM, %eR; testq %rR, %rR; je/jne` -> `cmpb $0, MEM`.
                (let
                  [ci : i64 (compiler-backend-compact-step-live v i hi 1)]
                  [ok4? : bool false]
                  (when
                    (>= ci 0)
                    (let
                      [crec : (& v be_state.CompilerBackendPeepholeLineRecord)
                        (& (array-ref v.lines ci))]
                      (when
                        (=
                          (compiler-backend-peephole-record-kind crec)
                          compiler-backend-sweep-line-kind-instruction)
                        (let
                          [cdata : (Ptr u8)
                            (compiler-backend-peephole-record-data crec)]
                          [cs : i64
                            (compiler-backend-peephole-record-start crec)]
                          [ce : i64 (compiler-backend-peephole-record-end crec)]
                          (when
                            (compiler-backend-cold-prefix?
                              cdata
                              cs
                              ce
                              "    testq ")
                            (let
                              [cc : i64
                                (compiler-backend-peephole-find-comma-space-range
                                  cdata
                                  (+ cs 10)
                                  ce)]
                              (when
                                (and
                                  (> cc (+ cs 10))
                                  (< (+ cc 2) ce)
                                  (=
                                    (compiler-backend-peephole-reg-index-range
                                      cdata
                                      (+ cs 10)
                                      cc)
                                    dst-reg)
                                  (=
                                    (compiler-backend-peephole-reg-index-range
                                      cdata
                                      (+ cc 2)
                                      ce)
                                    dst-reg))
                                (let
                                  [ci2 : i64
                                    (compiler-backend-compact-step-live
                                      v
                                      ci
                                      hi
                                      1)]
                                  (when
                                    (>= ci2 0)
                                    (let
                                      [r2 : (&
                                        v
                                        be_state.CompilerBackendPeepholeLineRecord)
                                        (& (array-ref v.lines ci2))]
                                      [d2 : (Ptr u8)
                                        (compiler-backend-peephole-record-data
                                          r2)]
                                      [s2 : i64
                                        (compiler-backend-peephole-record-start
                                          r2)]
                                      [e2 : i64
                                        (compiler-backend-peephole-record-end
                                          r2)]
                                      (when
                                        (and
                                          (=
                                            (compiler-backend-peephole-record-kind
                                              r2)
                                            compiler-backend-sweep-line-kind-instruction)
                                          (or
                                            (compiler-backend-cold-prefix?
                                              d2
                                              s2
                                              e2
                                              "    je ")
                                            (compiler-backend-cold-prefix?
                                              d2
                                              s2
                                              e2
                                              "    jne ")))
                                        (let
                                          [ci3 : i64
                                            (compiler-backend-compact-step-live
                                              v
                                              ci2
                                              hi
                                              1)]
                                          (when
                                            (or
                                              (< ci3 0)
                                              (!=
                                                (compiler-backend-peephole-record-kind
                                                  (& (array-ref v.lines ci3)))
                                                compiler-backend-sweep-line-kind-instruction)
                                              (let
                                                [r3 : (&
                                                  v
                                                  be_state.CompilerBackendPeepholeLineRecord)
                                                  (& (array-ref v.lines ci3))]
                                                [d3 : (Ptr u8)
                                                  (compiler-backend-peephole-record-data
                                                    r3)]
                                                [ms3 : i64
                                                  (compiler-backend-peephole-record-mnemonic-start
                                                    r3)]
                                                [e3 : i64
                                                  (compiler-backend-peephole-record-end
                                                    r3)]
                                                (and
                                                  (not
                                                    (compiler-backend-cold-prefix?
                                                      d3
                                                      ms3
                                                      e3
                                                      "j"))
                                                  (not
                                                    (compiler-backend-cold-prefix?
                                                      d3
                                                      ms3
                                                      e3
                                                      "set"))
                                                  (not
                                                    (compiler-backend-cold-prefix?
                                                      d3
                                                      ms3
                                                      e3
                                                      "cmov")))))
                                            (set! ok4? true))))))))))))))
                  (when
                    ok4?
                    (unless
                      visited-ready
                      (set!
                        visited
                        (__tl_make-array
                          i64
                          compiler-backend-peephole-rmw-visit-window))
                      (set! visited-ready true))
                    (+= generation 1)
                    (when
                      (compiler-backend-peephole-rmw-reg-dead-after?
                        (& v.lines)
                        (& v.live)
                        lo
                        hi
                        (&mut visited)
                        generation
                        (+ ci 1)
                        dst-reg
                        true)
                      (compiler-backend-compact-replace-insn!
                        v
                        ci
                        (str_cat.str-cat
                          "    cmpb $0, "
                          (string.substring
                            (array-ref v.lines i).src
                            addr-start
                            (- addr-end addr-start)))
                        home
                        false)
                      (set! (array-ref v.live i) 0))))]
              [(= mode 3)
                ;; Dead 1-use `movq MEM, %r` followed by:
                ;;   `movq %r, %r2`   -> `movq MEM, %r2`
                ;;   `testq %r, %r`   -> `cmpq $0, MEM`
                ;;   `cmpq $imm, %r`  -> `cmpq $imm, MEM`
                ;;   `cmpq %r2, %r`   -> `cmpq %r2, MEM`
                ;;   `cmpq %r, %r2`   -> `cmpq MEM, %r2`
                (let
                  [ci : i64 (compiler-backend-compact-step-live v i hi 1)]
                  [m3-kind : i64 0]
                  [m3-reg : i64 -1]
                  [m3-is : i64 0]
                  [m3-ie : i64 0]
                  (when
                    (>= ci 0)
                    (let
                      [crec : (& v be_state.CompilerBackendPeepholeLineRecord)
                        (& (array-ref v.lines ci))]
                      (when
                        (=
                          (compiler-backend-peephole-record-kind crec)
                          compiler-backend-sweep-line-kind-instruction)
                        (let
                          [cdata : (Ptr u8)
                            (compiler-backend-peephole-record-data crec)]
                          [cs : i64
                            (compiler-backend-peephole-record-start crec)]
                          [ce : i64 (compiler-backend-peephole-record-end crec)]
                          (cond
                            [(compiler-backend-cold-prefix?
                                cdata
                                cs
                                ce
                                "    movq ")
                              (let
                                [cc : i64
                                  (compiler-backend-peephole-find-comma-space-range
                                    cdata
                                    (+ cs 9)
                                    ce)]
                                (when
                                  (and
                                    (> cc (+ cs 9))
                                    (< (+ cc 2) ce)
                                    (=
                                      (compiler-backend-peephole-reg-index-range
                                        cdata
                                        (+ cs 9)
                                        cc)
                                      dst-reg))
                                  (let
                                    [dr2 : i64
                                      (compiler-backend-peephole-reg-index-range
                                        cdata
                                        (+ cc 2)
                                        ce)]
                                    (when
                                      (and (>= dr2 0) (!= dr2 dst-reg))
                                      (set! m3-kind 1)
                                      (set! m3-reg dr2)))))]
                            [(compiler-backend-cold-prefix?
                                cdata
                                cs
                                ce
                                "    testq ")
                              (let
                                [cc : i64
                                  (compiler-backend-peephole-find-comma-space-range
                                    cdata
                                    (+ cs 10)
                                    ce)]
                                (when
                                  (and
                                    (> cc (+ cs 10))
                                    (< (+ cc 2) ce)
                                    (=
                                      (compiler-backend-peephole-reg-index-range
                                        cdata
                                        (+ cs 10)
                                        cc)
                                      dst-reg)
                                    (=
                                      (compiler-backend-peephole-reg-index-range
                                        cdata
                                        (+ cc 2)
                                        ce)
                                      dst-reg))
                                  (set! m3-kind 2)))]
                            [(compiler-backend-cold-prefix?
                                cdata
                                cs
                                ce
                                "    cmpq ")
                              (let
                                [cc : i64
                                  (compiler-backend-peephole-find-comma-space-range
                                    cdata
                                    (+ cs 9)
                                    ce)]
                                (when
                                  (and (> cc (+ cs 9)) (< (+ cc 2) ce))
                                  (let
                                    [r1c : i64
                                      (compiler-backend-compact-gp64-id
                                        cdata
                                        (+ cs 9)
                                        cc)]
                                    [r2c : i64
                                      (compiler-backend-compact-gp64-id
                                        cdata
                                        (+ cc 2)
                                        ce)]
                                    (cond
                                      [(and
                                        (= r2c dst-reg)
                                        (=
                                          (be_state.compiler-backend-peephole-byte-at
                                            cdata
                                            (+ cs 9))
                                          36)
                                        (compiler-backend-compact-signed-int?
                                          cdata
                                          (+ cs 10)
                                          cc))
                                        (set! m3-kind 3)
                                        (set! m3-is (+ cs 9))
                                        (set! m3-ie cc)]
                                      [(and
                                        (= r2c dst-reg)
                                        (>= r1c 0)
                                        (!= r1c dst-reg))
                                        (set! m3-kind 4)
                                        (set! m3-reg r1c)]
                                      [(and
                                        (= r1c dst-reg)
                                        (>= r2c 0)
                                        (!= r2c dst-reg))
                                        (set! m3-kind 5)
                                        (set! m3-reg r2c)]
                                      [else unit]))))]
                            [else unit])))))
                  (when
                    (> m3-kind 0)
                    (unless
                      visited-ready
                      (set!
                        visited
                        (__tl_make-array
                          i64
                          compiler-backend-peephole-rmw-visit-window))
                      (set! visited-ready true))
                    (+= generation 1)
                    (when
                      (compiler-backend-peephole-rmw-reg-dead-after?
                        (& v.lines)
                        (& v.live)
                        lo
                        hi
                        (&mut visited)
                        generation
                        (+ ci 1)
                        dst-reg
                        true)
                      (let
                        [mem : String
                          (string.substring
                            (array-ref v.lines i).src
                            addr-start
                            (- addr-end addr-start))]
                        [repl : String
                          (cond
                            [(= m3-kind 1)
                              (str_cat.str-cat
                                "    movq "
                                mem
                                ", "
                                (compiler-backend-compact-gp64-name m3-reg))]
                            [(= m3-kind 2)
                              (str_cat.str-cat "    cmpq $0, " mem)]
                            [(= m3-kind 3)
                              (str_cat.str-cat
                                "    cmpq "
                                (string.substring
                                  (array-ref v.lines ci).src
                                  m3-is
                                  (- m3-ie m3-is))
                                ", "
                                mem)]
                            [(= m3-kind 4)
                              (str_cat.str-cat
                                "    cmpq "
                                (compiler-backend-compact-gp64-name m3-reg)
                                ", "
                                mem)]
                            [else
                              (str_cat.str-cat
                                "    cmpq "
                                mem
                                ", "
                                (compiler-backend-compact-gp64-name m3-reg))])]
                        (compiler-backend-compact-replace-insn!
                          v
                          ci
                          repl
                          home
                          false)
                        (set! (array-ref v.live i) 0)))))]
              [(or (= mode 1) (= mode 2))
                (let
                  [addr-kind : i64 (array-ref buf 0)]
                  [addr-disp : i64 (array-ref buf 1)]
                  [addr-mask : i64 (array-ref buf 2)]
                  [lea-bytes : i64
                    (if (= mode 2)
                      3
                      (+ 3 (array-ref buf 3)))]
                  [rex-pen : i64
                    (if (and
                      (= (array-ref buf 4) 1)
                      (or (< dst-reg 6) (> dst-reg 13)))
                      1
                      0)]
                  [addr-lp : i64 (array-ref buf 5)]
                  [use-count : i64 0]
                  [total-delta : i64 0]
                  [self-dead? : bool false]
                  [last-ci : i64 -1]
                  [direct-ci : i64 -1]
                  [direct-pos : i64 0]
                  [direct-nop? : bool false]
                  [ci : i64 (compiler-backend-compact-step-live v i hi 1)]
                  [gap : i64 0]
                  [done : bool false]
                  (while (and (not done) (>= ci 0) (<= gap 5) (< use-count 6))
                    (let
                      [crec : (& v be_state.CompilerBackendPeepholeLineRecord)
                        (& (array-ref v.lines ci))]
                      (if (!=
                        (compiler-backend-peephole-record-kind crec)
                        compiler-backend-sweep-line-kind-instruction)
                        (set! done true)
                        (let
                          [cdata : (Ptr u8)
                            (compiler-backend-peephole-record-data crec)]
                          [ce : i64 (compiler-backend-peephole-record-end crec)]
                          [cms : i64
                            (compiler-backend-peephole-record-mnemonic-start
                              crec)]
                          (if (not
                            (compiler-backend-peephole-rmw-mentions-reg?
                              cdata
                              cms
                              ce
                              dst-reg))
                            (if (compiler-backend-leaq-intervening-safe?
                              crec
                              addr-mask)
                              (begin
                                (+= gap 1)
                                (set!
                                  ci
                                  (compiler-backend-compact-step-live v ci hi 1)))
                              (set! done true))
                            (let
                              [cme : i64
                                (compiler-backend-peephole-rmw-mnemonic-end
                                  cdata
                                  cms
                                  ce)]
                              [cops : i64
                                (if (< (+ cme 1) ce)
                                  (+ cme 1)
                                  ce)]
                              [ccomma : i64
                                (compiler-backend-peephole-find-comma-space-range
                                  cdata
                                  cops
                                  ce)]
                              [ok? : bool false]
                              [is-self-ov? : bool false]
                              [can-cont? : bool false]
                              (when
                                (and (> ccomma cops) (< (+ ccomma 2) ce))
                                (let
                                  [m1? : bool
                                    (and
                                      (compiler-backend-compact-parse-base-mem!
                                        cdata
                                        cops
                                        ccomma
                                        (&mut buf)
                                        6)
                                      (= (array-ref buf 6) dst-reg))]
                                  [m2? : bool
                                    (and
                                      (compiler-backend-compact-parse-base-mem!
                                        cdata
                                        (+ ccomma 2)
                                        ce
                                        (&mut buf)
                                        9)
                                      (= (array-ref buf 9) dst-reg))]
                                  (cond
                                    [(and
                                        (!= m1? m2?)
                                        (compiler-backend-leaq-consumer-mnemonic?
                                          cdata
                                          cms
                                          cme
                                          m1?))
                                      (let
                                        [d-use : i64
                                          (if m1?
                                            (array-ref buf 7)
                                            (array-ref buf 10))]
                                        [d-new : i64 (+ addr-disp d-use)]
                                        (when
                                          (if (= addr-kind 1)
                                            (= d-use 0)
                                            (be_operand.compiler-backend-imm32?
                                              d-new))
                                          (let
                                            [new-ex : i64
                                              (if (= mode 2)
                                                (compiler-backend-compact-base-extra
                                                  src-reg
                                                  d-new)
                                                (compiler-backend-leaq-new-extra
                                                  (& (array-ref v.lines i))
                                                  addr-kind
                                                  addr-lp
                                                  addr-end
                                                  d-new))]
                                            [delta : i64
                                              (-
                                                (+ new-ex rex-pen)
                                                (compiler-backend-compact-base-extra
                                                  dst-reg
                                                  d-use))]
                                            [other-s : i64
                                              (if m1?
                                                (+ ccomma 2)
                                                cops)]
                                            [other-e : i64
                                              (if m1?
                                                ce
                                                ccomma)]
                                            [is-leaq-c? : bool
                                              (be_operand.compiler-backend-peephole-range-eq?
                                                cdata
                                                cms
                                                cme
                                                "leaq")]
                                            [self-ov? : bool
                                              (and
                                                m1?
                                                (or
                                                  (compiler-backend-leaq-full-load?
                                                    cdata
                                                    cms
                                                    cme)
                                                  is-leaq-c?)
                                                (=
                                                  (compiler-backend-peephole-token-reg-index-range
                                                    cdata
                                                    other-s
                                                    other-e)
                                                  dst-reg))]
                                            (when
                                              (and
                                                (<
                                                  (+ total-delta delta)
                                                  lea-bytes)
                                                (or
                                                  (not is-leaq-c?)
                                                  (>=
                                                    (compiler-backend-peephole-reg-index-range
                                                      cdata
                                                      other-s
                                                      other-e)
                                                    0))
                                                (or
                                                  self-ov?
                                                  (not
                                                    (compiler-backend-peephole-rmw-mentions-reg?
                                                      cdata
                                                      other-s
                                                      other-e
                                                      dst-reg))))
                                              (let
                                                [slot : i64
                                                  (+ 12 (* use-count 3))]
                                                (set! (array-ref buf slot) ci)
                                                (set!
                                                  (array-ref buf (+ slot 1))
                                                  (if m1?
                                                    1
                                                    0))
                                                (set!
                                                  (array-ref buf (+ slot 2))
                                                  d-new)
                                                (+= total-delta delta)
                                                (+= use-count 1)
                                                (set! last-ci ci)
                                                (set! ok? true)
                                                (set! is-self-ov? self-ov?)
                                                (set!
                                                  can-cont?
                                                  (and
                                                    (not self-ov?)
                                                    (compiler-backend-leaq-intervening-safe?
                                                      crec
                                                      addr-mask))))))))]
                                    ;; Single direct register-operand consumer for
                                    ;; zero-disp `movq %rA, %rB` or `leaq (%rA), %rB`.
                                    [(and (= use-count 0) (>= src-reg 0))
                                      (let
                                        [dop : i64
                                          (compiler-backend-leaq-direct-reg-op?
                                            cdata
                                            cms
                                            cme)]
                                        (when
                                          (> dop 0)
                                          (cond
                                            [(and
                                              (=
                                                (compiler-backend-peephole-reg-index-range
                                                  cdata
                                                  cops
                                                  ccomma)
                                                dst-reg)
                                              (not
                                                (compiler-backend-peephole-rmw-mentions-reg?
                                                  cdata
                                                  (+ ccomma 2)
                                                  ce
                                                  dst-reg)))
                                              (set! direct-ci ci)
                                              (set! direct-pos 1)
                                              (when
                                                (and
                                                  (= dop 1)
                                                  (=
                                                    (compiler-backend-compact-gp64-id
                                                      cdata
                                                      (+ ccomma 2)
                                                      ce)
                                                    src-reg))
                                                (set! direct-nop? true))
                                              (set! last-ci ci)
                                              (set! ok? true)]
                                            [(and
                                              (= dop 2)
                                              (=
                                                (compiler-backend-peephole-reg-index-range
                                                  cdata
                                                  (+ ccomma 2)
                                                  ce)
                                                dst-reg)
                                              (not
                                                (compiler-backend-peephole-rmw-mentions-reg?
                                                  cdata
                                                  cops
                                                  ccomma
                                                  dst-reg)))
                                              (set! direct-ci ci)
                                              (set! direct-pos 2)
                                              (set! last-ci ci)
                                              (set! ok? true)]
                                            [else unit])))]
                                    [else unit])))
                              (cond
                                [(not ok?)
                                  (if (and
                                    (> use-count 0)
                                    (compiler-backend-peephole-rmw-clean-overwrite?
                                      cdata
                                      cms
                                      cme
                                      ce
                                      dst-reg
                                      true))
                                    (set! self-dead? true)
                                    (set! use-count 0))
                                  (set! done true)]
                                [is-self-ov?
                                  (set! self-dead? true)
                                  (set! done true)]
                                [(>= direct-ci 0) (set! done true)]
                                [(not can-cont?) (set! done true)]
                                [else
                                  (set! gap 0)
                                  (set!
                                    ci
                                    (compiler-backend-compact-step-live
                                      v
                                      ci
                                      hi
                                      1))])))))))
                  (let
                    [folded? : bool false]
                    (when
                      (and
                        (or (> use-count 0) (>= direct-ci 0))
                        (or
                          self-dead?
                          (begin
                            (unless
                              visited-ready
                              (set!
                                visited
                                (__tl_make-array
                                  i64
                                  compiler-backend-peephole-rmw-visit-window))
                              (set! visited-ready true))
                            (+= generation 1)
                            (compiler-backend-peephole-rmw-reg-dead-after?
                              (& v.lines)
                              (& v.live)
                              lo
                              hi
                              (&mut visited)
                              generation
                              (+ last-ci 1)
                              dst-reg
                              true))))
                      (set! folded? true)
                      (if (>= direct-ci 0)
                        (if direct-nop?
                          (set! (array-ref v.live direct-ci) 0)
                          (let
                            [crec : (&
                              v
                              be_state.CompilerBackendPeepholeLineRecord)
                              (& (array-ref v.lines direct-ci))]
                            [cdata : (Ptr u8)
                              (compiler-backend-peephole-record-data crec)]
                            [cs : i64
                              (compiler-backend-peephole-record-start crec)]
                            [ce : i64
                              (compiler-backend-peephole-record-end crec)]
                            [cms : i64
                              (compiler-backend-peephole-record-mnemonic-start
                                crec)]
                            [op1s : i64
                              (+
                                (compiler-backend-peephole-rmw-mnemonic-end
                                  cdata
                                  cms
                                  ce)
                                1)]
                            [comma : i64
                              (compiler-backend-peephole-find-comma-space-range
                                cdata
                                op1s
                                ce)]
                            [sname : String
                              (compiler-backend-compact-gp64-name src-reg)]
                            [repl : String
                              (if (= direct-pos 1)
                                (str_cat.str-cat
                                  (string.substring crec.src cs (- op1s cs))
                                  sname
                                  (string.substring crec.src comma (- ce comma)))
                                (str_cat.str-cat
                                  (string.substring
                                    crec.src
                                    cs
                                    (- (+ comma 2) cs))
                                  sname))]
                            (compiler-backend-compact-replace-insn!
                              v
                              direct-ci
                              repl
                              home
                              false)))
                        (for [u (iterator.range 0 use-count)]
                          (let
                            [slot : i64 (+ 12 (* u 3))]
                            [uci : i64 (array-ref buf slot)]
                            [op1m? : bool (= (array-ref buf (+ slot 1)) 1)]
                            [d-new : i64 (array-ref buf (+ slot 2))]
                            [lrec : (&
                              v
                              be_state.CompilerBackendPeepholeLineRecord)
                              (& (array-ref v.lines i))]
                            [crec : (&
                              v
                              be_state.CompilerBackendPeepholeLineRecord)
                              (& (array-ref v.lines uci))]
                            [cdata : (Ptr u8)
                              (compiler-backend-peephole-record-data crec)]
                            [cs : i64
                              (compiler-backend-peephole-record-start crec)]
                            [ce : i64
                              (compiler-backend-peephole-record-end crec)]
                            [cms : i64
                              (compiler-backend-peephole-record-mnemonic-start
                                crec)]
                            [op1s : i64
                              (+
                                (compiler-backend-peephole-rmw-mnemonic-end
                                  cdata
                                  cms
                                  ce)
                                1)]
                            [comma : i64
                              (compiler-backend-peephole-find-comma-space-range
                                cdata
                                op1s
                                ce)]
                            [new-addr : String
                              (cond
                                [(= mode 2)
                                  (let
                                    [sn : String
                                      (compiler-backend-compact-gp64-name
                                        src-reg)]
                                    (compiler-backend-zero-format-addr
                                      d-new
                                      (& sn)))]
                                [(= addr-kind 1)
                                  (string.substring
                                    lrec.src
                                    addr-start
                                    (- addr-end addr-start))]
                                [else
                                  (let
                                    [tail : String
                                      (string.substring
                                        lrec.src
                                        addr-lp
                                        (- addr-end addr-lp))]
                                    (if (= d-new 0)
                                      tail
                                      (str_cat.str-cat
                                        (string.int->string d-new)
                                        tail)))])]
                            [folded-text : String
                              (if op1m?
                                (str_cat.str-cat
                                  (string.substring crec.src cs (- op1s cs))
                                  new-addr
                                  (string.substring crec.src comma (- ce comma)))
                                (str_cat.str-cat
                                  (string.substring
                                    crec.src
                                    cs
                                    (- (+ comma 2) cs))
                                  new-addr))]
                            (compiler-backend-compact-replace-insn!
                              v
                              uci
                              folded-text
                              home
                              false))))
                      (set! (array-ref v.live i) 0))
                    ;; Unfolded `leaq (%rA), %rB` (4B) -> `movq %rA, %rB` (3B).
                    (when
                      (and (not folded?) (= mode 1) (>= src-reg 0))
                      (compiler-backend-compact-replace-insn!
                        v
                        i
                        (str_cat.str-cat
                          "    movq "
                          (compiler-backend-compact-gp64-name src-reg)
                          ", "
                          (compiler-backend-compact-gp64-name dst-reg))
                        home
                        false))))]
              [else unit])))))))

;; ---------------------------------------------------------------------------
;; Compaction 2: Contiguous zero-store coalescing (whole-function XMM liveness)
;; ---------------------------------------------------------------------------
(define (compiler-backend-zero-scan-xmm-mask
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : i64
  (let
    [mask : i64 0]
    [i : i64 (be_operand.compiler-backend-peephole-scan-byte-range data s e 37)]
    (while (< (+ i 4) e)
      (let
        [b1 : i64 (be_state.compiler-backend-peephole-byte-at data (+ i 1))]
        (when
          (and
            (or (= b1 120) (= b1 121) (= b1 122))
            (= (be_state.compiler-backend-peephole-byte-at data (+ i 2)) 109)
            (= (be_state.compiler-backend-peephole-byte-at data (+ i 3)) 109))
          (let
            [d0 : i64 (be_state.compiler-backend-peephole-byte-at data (+ i 4))]
            (when
              (and (>= d0 48) (<= d0 57))
              (let
                [num : i64 (- d0 48)]
                [p : i64 (+ i 5)]
                (when
                  (< p e)
                  (let
                    [d1 : i64
                      (be_state.compiler-backend-peephole-byte-at data p)]
                    (when
                      (and (>= d1 48) (<= d1 57))
                      (set! num (+ (* num 10) (- d1 48))))))
                (when (< num 32) (set! mask (bit-or mask (shl 1 num)))))))))
      (set!
        i
        (be_operand.compiler-backend-peephole-scan-byte-range data (+ i 1) e 37)))
    mask))

(define (compiler-backend-zero-pick-xmm
  [used-mask : i64]
  [linux? : bool]
  [has-tail-jmp? : bool]) : i64
  (cond
    [(and (not has-tail-jmp?) (= (bit-and used-mask 16) 0)) 4]
    [(and (not has-tail-jmp?) (= (bit-and used-mask 32) 0)) 5]
    [(and (not has-tail-jmp?) (= (bit-and used-mask 4) 0)) 2]
    [(and (not has-tail-jmp?) (= (bit-and used-mask 8) 0)) 3]
    [linux?
      (for [k (iterator.range 8 16)]
        (when (= (bit-and used-mask (shl 1 k)) 0) (return k)))
      -1]
    [else -1]))

;; Returns width 8/4/2/1 for `    mov[qlwb] $0, MEM`, or 0.
(define (compiler-backend-zero-store-width
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : i64
  (if (or
    (<= (- e s) 14)
    (not (compiler-backend-cold-prefix? data s e "    mov"))
    (not
      (be_operand.compiler-backend-peephole-range-eq?
        data
        (+ s 8)
        (+ s 13)
        " $0, "))
    (>=
      (be_operand.compiler-backend-peephole-scan-byte-range data (+ s 13) e 40)
      e))
    0
    (let
      [wb : i64 (be_state.compiler-backend-peephole-byte-at data (+ s 7))]
      (cond [(= wb 113) 8] [(= wb 108) 4] [(= wb 119) 2] [(= wb 98) 1] [else 0]))))

(define (compiler-backend-zero-store-bytes
  [is-xmm? : bool]
  [is-16? : bool]
  [w : i64]
  [xmm-id : i64]
  [base-id : i64]
  [disp : i64]) : i64
  (let
    [extra : i64 (compiler-backend-compact-base-extra base-id disp)]
    [ext? : bool (and (>= base-id 6) (<= base-id 13))]
    (if is-xmm?
      (+
        extra
        (+
          (if is-16?
            3
            4)
          (if (or (>= xmm-id 8) ext?)
            1
            0)))
      (+
        extra
        (+
          (if (or (= w 8) ext?)
            1
            0)
          (cond [(= w 1) 3] [(= w 2) 5] [else 6]))))))

(define (compiler-backend-zero-unsafe-line?
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : bool
  (let
    [first : i64 (compiler-backend-cold-line-first data s e)]
    (and
      (< first e)
      (let
        [b0 : i64 (be_state.compiler-backend-peephole-byte-at data first)]
        (cond
          [(= b0 35) (compiler-backend-cold-prefix? data first e "#APP")]
          [(= b0 46) (compiler-backend-cold-prefix? data first e ".byte")]
          [(= b0 115) (compiler-backend-cold-prefix? data first e "syscall")]
          [(= b0 105) (compiler-backend-cold-prefix? data first e "int ")]
          [(= b0 99) (compiler-backend-cold-prefix? data first e "cpuid")]
          [(= b0 120) (compiler-backend-cold-prefix? data first e "xsave")]
          [(= b0 102) (compiler-backend-cold-prefix? data first e "fxsave")]
          [(= b0 118) (compiler-backend-cold-prefix? data first e "vzeroupper")]
          [else false])))))

(define (compiler-backend-zero-format-addr
  [disp : i64]
  [base-text : (& base-text str)]) : String
  (if (= disp 0)
    (str_cat.str-cat "(" base-text ")")
    (str_cat.str-cat (string.int->string disp) "(" base-text ")")))

(define (compiler-backend-zero-xorl-reg [data : (Ptr u8)] [s : i64] [e : i64]) : i64
  (if (not (compiler-backend-cold-prefix? data s e "    xorl "))
    -1
    (let
      [comma : i64
        (compiler-backend-peephole-find-comma-space-range data (+ s 9) e)]
      (if (or (<= comma (+ s 9)) (>= (+ comma 2) e))
        -1
        (let
          [r1 : i64
            (compiler-backend-peephole-token-reg-index-range data (+ s 9) comma)]
          (if (and
            (>= r1 0)
            (=
              (compiler-backend-peephole-token-reg-index-range
                data
                (+ comma 2)
                e)
              r1))
            r1
            -1))))))

(define (compiler-backend-zero-coalesce-function!
  [v : (&mut v be_state.CompilerBackendPeepholeLineVec)]
  [lo : i64]
  [hi : i64]
  [linux? : bool]
  [home : arena.Arena]) : unit
  (let
    [body-lo : i64 (compiler-backend-compact-body-start v lo hi)]
    (when (or (< body-lo 0) (>= (+ body-lo 1) hi)) (return unit))
    (let
      [used-xmm : i64 0]
      [has-tail-jmp? : bool false]
      [has-unsafe? : bool false]
      [zero-count : i64 0]
      [has-xorl? : bool false]
      (for [i (iterator.range lo hi)]
        (when
          (= (array-ref v.live i) 1)
          (let
            [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
              (& (array-ref v.lines i))]
            [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
            [rs : i64 (compiler-backend-peephole-record-start rec)]
            [re : i64 (compiler-backend-peephole-record-end rec)]
            (set!
              used-xmm
              (bit-or used-xmm (compiler-backend-zero-scan-xmm-mask data rs re)))
            (when
              (compiler-backend-zero-unsafe-line? data rs re)
              (set! has-unsafe? true))
            (when
              (=
                (compiler-backend-peephole-record-kind rec)
                compiler-backend-sweep-line-kind-instruction)
              (when
                (>= i body-lo)
                (when
                  (> (compiler-backend-zero-store-width data rs re) 0)
                  (+= zero-count 1))
                (when
                  (>= (compiler-backend-zero-xorl-reg data rs re) 0)
                  (set! has-xorl? true)))
              (let
                [ms : i64 (compiler-backend-peephole-record-mnemonic-start rec)]
                (when
                  (and
                    (< ms re)
                    (= (be_state.compiler-backend-peephole-byte-at data ms) 106))
                  (let
                    [ops : i64
                      (+
                        (compiler-backend-peephole-rmw-mnemonic-end data ms re)
                        1)]
                    (when
                      (or
                        (>= ops re)
                        (not (compiler-backend-layout-local-label? data ops re)))
                      (set! has-tail-jmp? true)))))))))
      (when (or has-unsafe? (= zero-count 0)) (return unit))
      (let
        [xmm-id : i64
          (if (>= zero-count 2)
            (compiler-backend-zero-pick-xmm used-xmm linux? has-tail-jmp?)
            -1)]
        (when (and (< xmm-id 0) (not has-xorl?)) (return unit))
        ;; Single flat scratch buffer:
        ;;   [0..2]   parse-base-mem scratch
        ;;   [3..3+3*cap)  run entries (rec, disp, w)
        ;;   [used..emit)  coalesced used-recs and emit (disp, is16) pairs
        (let
          [cap : i64 (+ zero-count 2)]
          [work : (__tl_dyn-array i64) (__tl_make-array i64 (+ 3 (* cap 6)))]
          [off-run : i64 3]
          [off-used : i64 (+ 3 (* cap 3))]
          [off-emit : i64 (+ 3 (* cap 4))]
          [xmm-name : String
            (if (>= xmm-id 0)
              (str_cat.str-cat "%xmm" (string.int->string xmm-id))
              "")]
          [xorps-bytes : i64
            (if (< xmm-id 8)
              3
              4)]
          [xmm-valid? : bool false]
          [zero-gp : i64 -1]
          [i : i64 body-lo]
          (while (< i hi)
            (if (= (array-ref v.live i) 0)
              (+= i 1)
              (let
                [kind : i64 0]
                [is-ctrl? : bool false]
                [store-w : i64 0]
                [base-ok? : bool false]
                [base-id : i64 -1]
                [base-disp : i64 0]
                [base-lp : i64 0]
                [rec-s : i64 0]
                [rec-e : i64 0]
                [new-zgp : i64 -1]
                [kills-zgp? : bool false]
                (let
                  [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
                    (& (array-ref v.lines i))]
                  [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
                  [rs : i64 (compiler-backend-peephole-record-start rec)]
                  [re : i64 (compiler-backend-peephole-record-end rec)]
                  (set! kind (compiler-backend-peephole-record-kind rec))
                  (set! rec-s rs)
                  (set! rec-e re)
                  (when
                    (= kind compiler-backend-sweep-line-kind-instruction)
                    (let
                      [ms : i64
                        (compiler-backend-peephole-record-mnemonic-start rec)]
                      [b0 : i64
                        (if (< ms re)
                          (be_state.compiler-backend-peephole-byte-at data ms)
                          0)]
                      (if (or
                        (= b0 46)
                        (= b0 106)
                        (compiler-backend-cold-prefix? data ms re "call")
                        (compiler-backend-cold-prefix? data ms re "ret"))
                        (set! is-ctrl? true)
                        (begin
                          (set!
                            store-w
                            (compiler-backend-zero-store-width data rs re))
                          (cond
                            [(> store-w 0)
                              (when
                                (>= xmm-id 0)
                                (set!
                                  base-ok?
                                  (compiler-backend-compact-parse-base-mem!
                                    data
                                    (+ rs 13)
                                    re
                                    (&mut work)
                                    0))
                                (when
                                  base-ok?
                                  (set! base-id (array-ref work 0))
                                  (set! base-disp (array-ref work 1))
                                  (set! base-lp (array-ref work 2))))]
                            [else
                              (let
                                [xr : i64
                                  (compiler-backend-zero-xorl-reg data rs re)]
                                (if (>= xr 0)
                                  (set! new-zgp xr)
                                  (when
                                    (and
                                      (>= zero-gp 0)
                                      (let
                                        [me : i64
                                          (compiler-backend-peephole-rmw-mnemonic-end
                                            data
                                            ms
                                            re)]
                                        (or
                                          (compiler-backend-peephole-rmw-mentions-reg?
                                            data
                                            ms
                                            re
                                            zero-gp)
                                          (not
                                            (compiler-backend-peephole-rmw-transparent-mnemonic?
                                              data
                                              ms
                                              me))
                                          (and
                                            (= b0 105)
                                            (<=
                                              (compiler-backend-peephole-find-comma-space-range
                                                data
                                                (if (< (+ me 1) re)
                                                  (+ me 1)
                                                  re)
                                                re)
                                              me)))))
                                    (set! kills-zgp? true))))]))))))
                (cond
                  [(or
                    (!= kind compiler-backend-sweep-line-kind-instruction)
                    is-ctrl?)
                    (set! xmm-valid? false)
                    (set! zero-gp -1)
                    (+= i 1)]
                  [(= store-w 0)
                    (cond
                      [(>= new-zgp 0) (set! zero-gp new-zgp)]
                      [kills-zgp? (set! zero-gp -1)]
                      [else unit])
                    (+= i 1)]
                  [(not base-ok?)
                    (when
                      (= store-w 8)
                      (cond
                        [(>= zero-gp 0)
                          (compiler-backend-compact-replace-insn!
                            v
                            i
                            (str_cat.str-cat
                              "    movq "
                              (compiler-backend-compact-gp64-name zero-gp)
                              ", "
                              (string.substring
                                (array-ref v.lines i).src
                                (+ rec-s 13)
                                (- rec-e (+ rec-s 13))))
                            home
                            false)]
                        [xmm-valid?
                          (compiler-backend-compact-replace-insn!
                            v
                            i
                            (str_cat.str-cat
                              "    movq "
                              xmm-name
                              ", "
                              (string.substring
                                (array-ref v.lines i).src
                                (+ rec-s 13)
                                (- rec-e (+ rec-s 13))))
                            home
                            false)]
                        [else unit]))
                    (+= i 1)]
                  [else
                    ;; Collect consecutive zero-stores to `base-id`.
                    (let
                      [run-len : i64 1]
                      [j : i64 (+ i 1)]
                      (set! (array-ref work off-run) i)
                      (set! (array-ref work (+ off-run 1)) base-disp)
                      (set! (array-ref work (+ off-run 2)) store-w)
                      (while (< j hi)
                        (if (= (array-ref v.live j) 0)
                          (+= j 1)
                          (let
                            [jrec : (&
                              v
                              be_state.CompilerBackendPeepholeLineRecord)
                              (& (array-ref v.lines j))]
                            [jdata : (Ptr u8)
                              (compiler-backend-peephole-record-data jrec)]
                            [jrs : i64
                              (compiler-backend-peephole-record-start jrec)]
                            [jre : i64
                              (compiler-backend-peephole-record-end jrec)]
                            [jw : i64
                              (if (=
                                (compiler-backend-peephole-record-kind jrec)
                                compiler-backend-sweep-line-kind-instruction)
                                (compiler-backend-zero-store-width
                                  jdata
                                  jrs
                                  jre)
                                0)]
                            (if (and
                              (> jw 0)
                              (compiler-backend-compact-parse-base-mem!
                                jdata
                                (+ jrs 13)
                                jre
                                (&mut work)
                                0)
                              (= (array-ref work 0) base-id))
                              (let
                                [slot : i64 (+ off-run (* run-len 3))]
                                (set! (array-ref work slot) j)
                                (set!
                                  (array-ref work (+ slot 1))
                                  (array-ref work 1))
                                (set! (array-ref work (+ slot 2)) jw)
                                (+= run-len 1)
                                (+= j 1))
                              (break)))))
                      ;; Insertion-sort run entries by disp ascending.
                      (for [a (iterator.range 1 run-len)]
                        (let
                          [aslot : i64 (+ off-run (* a 3))]
                          [kr : i64 (array-ref work aslot)]
                          [kd : i64 (array-ref work (+ aslot 1))]
                          [kw : i64 (array-ref work (+ aslot 2))]
                          [b : i64 (- a 1)]
                          (while (and
                            (>= b 0)
                            (> (array-ref work (+ off-run (+ (* b 3) 1))) kd))
                            (let
                              [bs : i64 (+ off-run (* b 3))]
                              (set!
                                (array-ref work (+ bs 3))
                                (array-ref work bs))
                              (set!
                                (array-ref work (+ bs 4))
                                (array-ref work (+ bs 1)))
                              (set!
                                (array-ref work (+ bs 5))
                                (array-ref work (+ bs 2))))
                            (-= b 1))
                          (let
                            [ins : i64 (+ off-run (* (+ b 1) 3))]
                            (set! (array-ref work ins) kr)
                            (set! (array-ref work (+ ins 1)) kd)
                            (set! (array-ref work (+ ins 2)) kw))))
                      ;; Merge contiguous spans; keep stray <8B stores untouched.
                      (let
                        [used-len : i64 0]
                        [emit-len : i64 0]
                        [pair-count : i64 0]
                        [orig-bytes : i64 0]
                        [new-bytes : i64
                          (if xmm-valid?
                            0
                            xorps-bytes)]
                        [k : i64 0]
                        (while (< k run-len)
                          (let
                            [first-k : i64 k]
                            [ks : i64 (+ off-run (* k 3))]
                            [s0 : i64 (array-ref work (+ ks 1))]
                            [e0 : i64 (+ s0 (array-ref work (+ ks 2)))]
                            (+= k 1)
                            (while (and
                              (< k run-len)
                              (<= (array-ref work (+ off-run (+ (* k 3) 1))) e0))
                              (let
                                [ek : i64
                                  (+
                                    (array-ref work (+ off-run (+ (* k 3) 1)))
                                    (array-ref work (+ off-run (+ (* k 3) 2))))]
                                (when (> ek e0) (set! e0 ek)))
                              (+= k 1))
                            (let
                              [span : i64 (- e0 s0)]
                              (when
                                (or
                                  (>= span 16)
                                  (and
                                    (= span 8)
                                    (= (- k first-k) 1)
                                    (=
                                      (array-ref
                                        work
                                        (+ off-run (+ (* first-k 3) 2)))
                                      8)))
                                (for [uk (iterator.range first-k k)]
                                  (let
                                    [us : i64 (+ off-run (* uk 3))]
                                    (set!
                                      (array-ref work (+ off-used used-len))
                                      (array-ref work us))
                                    (+= used-len 1)
                                    (+=
                                      orig-bytes
                                      (compiler-backend-zero-store-bytes
                                        false
                                        false
                                        (array-ref work (+ us 2))
                                        xmm-id
                                        base-id
                                        (array-ref work (+ us 1))))))
                                (if (>= span 16)
                                  (let
                                    [pos : i64 s0]
                                    (while (<= (+ pos 16) e0)
                                      (let
                                        [es : i64 (+ off-emit (* emit-len 2))]
                                        (set! (array-ref work es) pos)
                                        (set! (array-ref work (+ es 1)) 1)
                                        (+= emit-len 1)
                                        (+= pair-count 1)
                                        (+=
                                          new-bytes
                                          (compiler-backend-zero-store-bytes
                                            true
                                            true
                                            16
                                            xmm-id
                                            base-id
                                            pos)))
                                      (+= pos 16))
                                    (when
                                      (< pos e0)
                                      (let
                                        [t16? : bool (!= (- e0 pos) 8)]
                                        [td : i64
                                          (if t16?
                                            (- e0 16)
                                            pos)]
                                        [es : i64 (+ off-emit (* emit-len 2))]
                                        (set! (array-ref work es) td)
                                        (set!
                                          (array-ref work (+ es 1))
                                          (if t16?
                                            1
                                            0))
                                        (+= emit-len 1)
                                        (when t16? (+= pair-count 1))
                                        (+=
                                          new-bytes
                                          (compiler-backend-zero-store-bytes
                                            true
                                            t16?
                                            8
                                            xmm-id
                                            base-id
                                            td)))))
                                  (let
                                    [es : i64 (+ off-emit (* emit-len 2))]
                                    (set! (array-ref work es) s0)
                                    (set! (array-ref work (+ es 1)) 0)
                                    (+= emit-len 1)
                                    (+=
                                      new-bytes
                                      (compiler-backend-zero-store-bytes
                                        true
                                        false
                                        8
                                        xmm-id
                                        base-id
                                        s0))))))))
                        (let
                          [need-xor? : bool (not xmm-valid?)]
                          [total-insns : i64
                            (+
                              emit-len
                              (if need-xor?
                                1
                                0))]
                          (if (and
                            (> emit-len 0)
                            (or (> pair-count 0) xmm-valid?)
                            (<= total-insns used-len)
                            (< new-bytes orig-bytes))
                            (let
                              [base-text : String
                                (string.substring
                                  (array-ref v.lines i).src
                                  (+ base-lp 1)
                                  (- (- rec-e 1) (+ base-lp 1)))]
                              [out-idx : i64 0]
                              ;; Sort used-recs ascending so xorps precedes stores.
                              (for [a (iterator.range 1 used-len)]
                                (let
                                  [kr : i64 (array-ref work (+ off-used a))]
                                  [b : i64 (- a 1)]
                                  (while (and
                                    (>= b 0)
                                    (> (array-ref work (+ off-used b)) kr))
                                    (set!
                                      (array-ref work (+ off-used (+ b 1)))
                                      (array-ref work (+ off-used b)))
                                    (-= b 1))
                                  (set!
                                    (array-ref work (+ off-used (+ b 1)))
                                    kr)))
                              (when
                                need-xor?
                                (compiler-backend-compact-replace-insn!
                                  v
                                  (array-ref work off-used)
                                  (str_cat.str-cat
                                    "    xorps "
                                    xmm-name
                                    ", "
                                    xmm-name)
                                  home
                                  false)
                                (set! out-idx 1))
                              (for [eidx (iterator.range 0 emit-len)]
                                (let
                                  [es : i64 (+ off-emit (* eidx 2))]
                                  [d : i64 (array-ref work es)]
                                  [is16? : bool (= (array-ref work (+ es 1)) 1)]
                                  [line : String
                                    (str_cat.str-cat
                                      (if is16?
                                        "    movups "
                                        "    movq ")
                                      xmm-name
                                      ", "
                                      (compiler-backend-zero-format-addr
                                        d
                                        (& base-text)))]
                                  (compiler-backend-compact-replace-insn!
                                    v
                                    (array-ref work (+ off-used out-idx))
                                    line
                                    home
                                    false)
                                  (+= out-idx 1)))
                              (for [dead-idx (iterator.range out-idx used-len)]
                                (set!
                                  (array-ref
                                    v.live
                                    (array-ref work (+ off-used dead-idx)))
                                  0))
                              (set! xmm-valid? true))
                            (when
                              (>= zero-gp 0)
                              (let
                                [gp-name : String
                                  (compiler-backend-compact-gp64-name zero-gp)]
                                (for [rk (iterator.range 0 run-len)]
                                  (let
                                    [rs0 : i64 (+ off-run (* rk 3))]
                                    (when
                                      (= (array-ref work (+ rs0 2)) 8)
                                      (let
                                        [ridx : i64 (array-ref work rs0)]
                                        [rrec : (&
                                          v
                                          be_state.CompilerBackendPeepholeLineRecord)
                                          (& (array-ref v.lines ridx))]
                                        [rrs : i64
                                          (compiler-backend-peephole-record-start
                                            rrec)]
                                        [rre : i64
                                          (compiler-backend-peephole-record-end
                                            rrec)]
                                        [repl : String
                                          (str_cat.str-cat
                                            "    movq "
                                            gp-name
                                            ", "
                                            (string.substring
                                              rrec.src
                                              (+ rrs 13)
                                              (- rre (+ rrs 13))))]
                                        (compiler-backend-compact-replace-insn!
                                          v
                                          ridx
                                          repl
                                          home
                                          false))))))))))
                      (set! i j))])))))))))

;; ---------------------------------------------------------------------------
;; Compaction 3: `jcc; jmp` inversion, multi-label fallthrough `jmp` drop,
;; trampoline threading, and per-function argless cold abort-stub dedup.
;; ---------------------------------------------------------------------------
(define (compiler-backend-branch-label-match
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]
  [tdata : (Ptr u8)]
  [ts : i64]
  [te : i64]) : i64
  (let
    [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
    [s : i64 (compiler-backend-peephole-record-start rec)]
    [e : i64 (compiler-backend-peephole-record-end rec)]
    (cond
      [(and
          (=
            (compiler-backend-peephole-record-kind rec)
            compiler-backend-sweep-line-kind-label)
          (> e s)
          (= (be_state.compiler-backend-peephole-byte-at data (- e 1)) 58))
        (if (be_operand.compiler-backend-peephole-ranges-eq?
          data
          s
          (- e 1)
          tdata
          ts
          te)
          1
          2)]
      [(and
          (compiler-backend-peephole-record-owned? rec)
          (> e s)
          (= (be_state.compiler-backend-peephole-byte-at data s) 46))
        (let
          [nl : i64
            (be_operand.compiler-backend-peephole-scan-byte-range data s e 10)]
          (if (and
            (> nl (+ s 1))
            (= (be_state.compiler-backend-peephole-byte-at data (- nl 1)) 58)
            (be_operand.compiler-backend-peephole-ranges-eq?
              data
              s
              (- nl 1)
              tdata
              ts
              te))
            1
            0))]
      [else 0])))

(define (compiler-backend-branch-find-fallthrough-label
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [start : i64]
  [hi : i64]
  [tdata : (Ptr u8)]
  [ts : i64]
  [te : i64]) : i64
  (let
    [k : i64 start]
    (while (< k hi)
      (if (= (array-ref v.live k) 0)
        (+= k 1)
        (let
          [m : i64
            (compiler-backend-branch-label-match
              (& (array-ref v.lines k))
              tdata
              ts
              te)]
          (cond [(= m 1) (return k)] [(= m 2) (+= k 1)] [else (return -1)]))))
    -1))

(define (compiler-backend-branch-local-jmp?
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : bool
  (and
    (> e (+ s 10))
    (compiler-backend-cold-prefix? data s e "    jmp ")
    (compiler-backend-layout-local-label? data (+ s 8) e)
    (= (compiler-backend-tail-symbol-end data (+ s 8) e) e)))

(define (compiler-backend-branch-local-dedup-label?
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : bool
  (and
    (compiler-backend-layout-local-label? data s e)
    (> e (+ s 2))
    (= (be_state.compiler-backend-peephole-byte-at data (- e 1)) 58)
    (not (compiler-backend-cold-prefix? data s e ".L_tl_"))
    (not (compiler-backend-cold-prefix? data s e ".Lcv"))
    (not (compiler-backend-cold-prefix? data s e ".Ldebug"))))

;; Returns inverse mnemonic for `    j<cc> .L...`, or "" if not invertible.
(define (compiler-backend-branch-local-jcc-inv
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : String
  (if (or (<= (- e s) 7) (not (compiler-backend-cold-prefix? data s e "    j")))
    ""
    (let
      [me : i64 (compiler-backend-cold-token-end data (+ s 4) e)]
      [ts : i64 (+ me 1)]
      (if (and
        (< ts e)
        (= (be_state.compiler-backend-peephole-byte-at data me) 32)
        (compiler-backend-layout-local-label? data ts e)
        (= (compiler-backend-tail-symbol-end data ts e) e))
        (compiler-backend-cold-jcc-inverse data (+ s 4) me)
        ""))))

(define (compiler-backend-compact-uncond-transfer?
  [rec : (& rec be_state.CompilerBackendPeepholeLineRecord)]) : bool
  (or
    (!=
      (bit-and
        (compiler-backend-peephole-record-flags rec)
        (bit-or
          compiler-backend-sweep-line-flag-jmp
          compiler-backend-sweep-line-flag-ret))
      0)
    (compiler-backend-peephole-line-noreturn-abort?
      (compiler-backend-peephole-record-data rec)
      (compiler-backend-peephole-record-start rec)
      (compiler-backend-peephole-record-end rec))))

;; Check if `jidx` is `jcc .Lok` where `nxt` defines `.Lok:`; return inverted `j!cc`
;; mnemonic (non-empty) when matched, else `""`.
(define (compiler-backend-compact-match-inline-abort-jcc
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [jidx : i64]
  [nxt : i64]) : String
  (let
    [jrec : (& v be_state.CompilerBackendPeepholeLineRecord)
      (& (array-ref v.lines jidx))]
    (if (!=
      (compiler-backend-peephole-record-kind jrec)
      compiler-backend-sweep-line-kind-instruction)
      ""
      (let
        [jdata : (Ptr u8) (compiler-backend-peephole-record-data jrec)]
        [js : i64 (compiler-backend-peephole-record-start jrec)]
        [je : i64 (compiler-backend-peephole-record-end jrec)]
        [inv : String (compiler-backend-branch-local-jcc-inv jdata js je)]
        (if (and
          (> (string.string-length (& inv)) 0)
          (=
            (compiler-backend-branch-label-match
              (& (array-ref v.lines nxt))
              jdata
              (+ (compiler-backend-cold-token-end jdata (+ js 4) je) 1)
              je)
            1))
          inv
          "")))))

;; Full-byte FNV-1a hash + chained bucket lookup so no two distinct local labels
;; can ever collide or be dropped (even 60+ char inlined labels sharing head/mid/tail).
(define (compiler-backend-compact-label-hash
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : i64
  (let
    [h : i64 2166136261]
    (for [k (iterator.range s e)]
      (set!
        h
        (bit-and
          (*
            (bit-xor h (be_state.compiler-backend-peephole-byte-at data k))
            16777619)
          2147483647)))
    h))

(define (compiler-backend-compact-lookup-label
  [v : (& v be_state.CompilerBackendPeepholeLineVec)]
  [lo : i64]
  [buckets : (& buckets (__tl_dyn-array i64))]
  [bmask : i64]
  [info : (& info (__tl_dyn-array i64))]
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : i64
  (let
    [cur : i64
      (array-ref
        buckets
        (bit-and (compiler-backend-compact-label-hash data s e) bmask))]
    (while (>= cur lo)
      (when (compiler-backend-tail-alias-label? v cur data s e) (return cur))
      (set! cur (- (array-ref info (+ (* (- cur lo) 4) 3)) 1)))
    -1))

(define (compiler-backend-compact-aborts-and-trampolines-function!
  [v : (&mut v be_state.CompilerBackendPeepholeLineVec)]
  [lo : i64]
  [hi : i64]
  [home : arena.Arena]) : unit
  (let
    [body-lo : i64 (compiler-backend-compact-body-start v lo hi)]
    (when (or (< body-lo 0) (>= (+ body-lo 1) hi)) (return unit))
    ;; Pack 5 abort counts [0..4] and 5 canonical labels [5..9] in one small array.
    (let
      [meta : (__tl_dyn-array i64) (__tl_make-array i64 10)]
      [indirect-jmp? : bool false]
      [has-loc? : bool false]
      [total-aborts : i64 0]
      [jmp-count : i64 0]
      [lbl-count : i64 0]
      (for [k (iterator.range 5 10)]
        (set! (array-ref meta k) -1))
      (for [i (iterator.range lo hi)]
        (when
          (= (array-ref v.live i) 1)
          (let
            [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
              (& (array-ref v.lines i))]
            [kind : i64 (compiler-backend-peephole-record-kind rec)]
            [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
            [s : i64 (compiler-backend-peephole-record-start rec)]
            [e : i64 (compiler-backend-peephole-record-end rec)]
            (cond
              [(= kind compiler-backend-sweep-line-kind-label) (+= lbl-count 1)]
              [(= kind compiler-backend-sweep-line-kind-skip)
                (let
                  [first : i64 (compiler-backend-cold-line-first data s e)]
                  (when
                    (and
                      (< first e)
                      (=
                        (be_state.compiler-backend-peephole-byte-at data first)
                        46)
                      (compiler-backend-cold-loc-line? data first e))
                    (set! has-loc? true)))]
              [(= kind compiler-backend-sweep-line-kind-instruction)
                (when
                  (compiler-backend-cold-prefix? data s e "    jmp ")
                  (+= jmp-count 1)
                  (when
                    (<
                      (be_operand.compiler-backend-peephole-scan-byte-range
                        data
                        (+ s 8)
                        e
                        42)
                      e)
                    (set! indirect-jmp? true)))
                (when
                  (and
                    (>= i body-lo)
                    (compiler-backend-cold-prefix? data s e "    call "))
                  (let
                    [ak : i64
                      (compiler-backend-cold-argless-abort-kind data s e)]
                    (when
                      (and
                        (>= ak 0)
                        (not (compiler-backend-tail-abort-site-follows? v i hi)))
                      (set! (array-ref meta ak) (+ (array-ref meta ak) 1))
                      (+= total-aborts 1))))]
              [else unit]))))
      (when
        (or
          has-loc?
          indirect-jmp?
          (= lbl-count 0)
          (and (< total-aborts 2) (= jmp-count 0)))
        (return unit))
      ;; One flat per-record array of size `span * 4`:
      ;;   [slot*4 + 0]: (ref-count << 1) | pinned-bit
      ;;   [slot*4 + 1]: tramp-next (target + 1, or 0)
      ;;   [slot*4 + 2]: redirect (canonical + 1, or 0)
      ;;   [slot*4 + 3]: hash-chain next (next-idx + 1, or 0)
      (let
        [span : i64 (- hi lo)]
        [bcap : i64 16]
        [_grow : unit
          (while (< bcap (* lbl-count 2))
            (set! bcap (* bcap 2)))]
        [bmask : i64 (- bcap 1)]
        [buckets : (__tl_dyn-array i64) (__tl_make-array i64 bcap)]
        [info : (__tl_dyn-array i64) (__tl_make-array i64 (* span 4))]
        [any-redirect? : bool false]
        (for [b (iterator.range 0 bcap)]
          (set! (array-ref buckets b) -1))
        (for [i (iterator.range lo hi)]
          (when
            (= (array-ref v.live i) 1)
            (let
              [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
                (& (array-ref v.lines i))]
              (when
                (=
                  (compiler-backend-peephole-record-kind rec)
                  compiler-backend-sweep-line-kind-label)
                (let
                  [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
                  [s : i64 (compiler-backend-peephole-record-start rec)]
                  [e : i64 (compiler-backend-peephole-record-end rec)]
                  (when
                    (compiler-backend-branch-local-dedup-label? data s e)
                    (let
                      [b : i64
                        (bit-and
                          (compiler-backend-compact-label-hash data s (- e 1))
                          bmask)]
                      [prev-head : i64 (array-ref buckets b)]
                      (set!
                        (array-ref info (+ (* (- i lo) 4) 3))
                        (+ prev-head 1))
                      (set! (array-ref buckets b) i))))))))
        (for [i (iterator.range lo hi)]
          (when
            (= (array-ref v.live i) 1)
            (let
              [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
                (& (array-ref v.lines i))]
              [kind : i64 (compiler-backend-peephole-record-kind rec)]
              (unless
                (= kind compiler-backend-sweep-line-kind-label)
                (let
                  [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
                  [s : i64 (compiler-backend-peephole-record-start rec)]
                  [e : i64 (compiler-backend-peephole-record-end rec)]
                  [dot : i64
                    (be_operand.compiler-backend-peephole-scan-byte-range
                      data
                      s
                      e
                      46)]
                  (while (< (+ dot 2) e)
                    (when
                      (compiler-backend-layout-local-label? data dot e)
                      (let
                        [end : i64
                          (compiler-backend-tail-symbol-end data dot e)]
                        [idx : i64
                          (compiler-backend-compact-lookup-label
                            v
                            lo
                            (& buckets)
                            bmask
                            (& info)
                            data
                            dot
                            end)]
                        (when
                          (>= idx lo)
                          (let
                            [base : i64 (* (- idx lo) 4)]
                            [cur : i64 (array-ref info base)]
                            [branch? : bool
                              (and
                                (= end e)
                                (=
                                  kind
                                  compiler-backend-sweep-line-kind-instruction)
                                (compiler-backend-cold-prefix? data s e "    j")
                                (=
                                  (+
                                    (compiler-backend-cold-token-end
                                      data
                                      (+ s 4)
                                      e)
                                    1)
                                  dot))]
                            (set!
                              (array-ref info base)
                              (bit-or
                                (+ cur 2)
                                (if branch?
                                  0
                                  1)))))
                        (set! dot (- end 1))))
                    (set!
                      dot
                      (be_operand.compiler-backend-peephole-scan-byte-range
                        data
                        (+ dot 1)
                        e
                        46))))))))
        ;; Step 1: Thread jump-to-jump trampolines (`.L1: jmp .L2`) and drop
        ;; unreachable trampolines preceded by an unconditional transfer.
        (when
          (> jmp-count 0)
          (let
            [any-tramp? : bool false]
            (for [i (iterator.range body-lo hi)]
              (when
                (and
                  (= (array-ref v.live i) 1)
                  (= (bit-and (array-ref info (* (- i lo) 4)) 1) 0))
                (let
                  [lrec : (& v be_state.CompilerBackendPeepholeLineRecord)
                    (& (array-ref v.lines i))]
                  (when
                    (and
                      (=
                        (compiler-backend-peephole-record-kind lrec)
                        compiler-backend-sweep-line-kind-label)
                      (compiler-backend-branch-local-dedup-label?
                        (compiler-backend-peephole-record-data lrec)
                        (compiler-backend-peephole-record-start lrec)
                        (compiler-backend-peephole-record-end lrec)))
                    (let
                      [nxt : i64 (compiler-backend-compact-step-live v i hi 1)]
                      (when
                        (>= nxt 0)
                        (let
                          [nrec : (&
                            v
                            be_state.CompilerBackendPeepholeLineRecord)
                            (& (array-ref v.lines nxt))]
                          [ndata : (Ptr u8)
                            (compiler-backend-peephole-record-data nrec)]
                          [ns : i64
                            (compiler-backend-peephole-record-start nrec)]
                          [ne : i64 (compiler-backend-peephole-record-end nrec)]
                          (when
                            (and
                              (=
                                (compiler-backend-peephole-record-kind nrec)
                                compiler-backend-sweep-line-kind-instruction)
                              (compiler-backend-branch-local-jmp? ndata ns ne))
                            (let
                              [tgt : i64
                                (compiler-backend-compact-lookup-label
                                  v
                                  lo
                                  (& buckets)
                                  bmask
                                  (& info)
                                  ndata
                                  (+ ns 8)
                                  ne)]
                              (when
                                (and
                                  (>= tgt lo)
                                  (!= tgt i)
                                  ;; Leave `.Lok: jmp ...` after an abort stub intact so
                                  ;; COLD-1 can hoist the preceding inline abort out of line.
                                  (let
                                    [p : i64
                                      (compiler-backend-compact-step-live
                                        v
                                        i
                                        lo
                                        -1)]
                                    (or
                                      (< p lo)
                                      (let
                                        [prec : (&
                                          v
                                          be_state.CompilerBackendPeepholeLineRecord)
                                          (& (array-ref v.lines p))]
                                        [pdata : (Ptr u8)
                                          (compiler-backend-peephole-record-data
                                            prec)]
                                        [ps : i64
                                          (compiler-backend-peephole-record-start
                                            prec)]
                                        [pe : i64
                                          (compiler-backend-peephole-record-end
                                            prec)]
                                        [pf : i64
                                          (compiler-backend-cold-line-first
                                            pdata
                                            ps
                                            pe)]
                                        (and
                                          (not
                                            (compiler-backend-peephole-line-noreturn-abort?
                                              pdata
                                              ps
                                              pe))
                                          (not
                                            (compiler-backend-cold-prefix?
                                              pdata
                                              pf
                                              pe
                                              ".tl_abort_row"))
                                          (not
                                            (compiler-backend-cold-prefix?
                                              pdata
                                              ps
                                              pe
                                              ".L_tl_abort_site_")))))))
                                (set!
                                  (array-ref info (+ (* (- i lo) 4) 1))
                                  (+ tgt 1))
                                (set! any-tramp? true)))))))))))
            (when
              any-tramp?
              (for [i (iterator.range body-lo hi)]
                (let
                  [t : i64 (array-ref info (+ (* (- i lo) 4) 1))]
                  (when
                    (> t 0)
                    (let
                      [cur : i64 (- t 1)]
                      [steps : i64 0]
                      (while (and
                        (< steps 8)
                        (> (array-ref info (+ (* (- cur lo) 4) 1)) 0)
                        (!= (- (array-ref info (+ (* (- cur lo) 4) 1)) 1) i))
                        (set! cur (- (array-ref info (+ (* (- cur lo) 4) 1)) 1))
                        (+= steps 1))
                      (when
                        (and
                          (!= cur i)
                          (= (array-ref info (+ (* (- cur lo) 4) 1)) 0))
                        (set! (array-ref info (+ (* (- i lo) 4) 2)) (+ cur 1))
                        (set! any-redirect? true)
                        (let
                          [prev : i64
                            (compiler-backend-compact-step-live v i lo -1)]
                          (when
                            (and
                              (>= prev lo)
                              (compiler-backend-compact-uncond-transfer?
                                (& (array-ref v.lines prev))))
                            (let
                              [nxt : i64
                                (compiler-backend-compact-step-live v i hi 1)]
                              (set! (array-ref v.live i) 0)
                              (when (>= nxt 0) (set! (array-ref v.live nxt) 0)))))))))))))
        ;; Step 2: Unified per-function argless cold abort-stub dedup.
        (when
          (>= total-aborts 2)
          (for [i (iterator.range body-lo hi)]
            (when
              (= (array-ref v.live i) 1)
              (let
                [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
                  (& (array-ref v.lines i))]
                (when
                  (=
                    (compiler-backend-peephole-record-kind rec)
                    compiler-backend-sweep-line-kind-instruction)
                  (let
                    [ak : i64
                      (compiler-backend-cold-argless-abort-kind
                        (compiler-backend-peephole-record-data rec)
                        (compiler-backend-peephole-record-start rec)
                        (compiler-backend-peephole-record-end rec))]
                    (when
                      (and
                        (>= ak 0)
                        (>= (array-ref meta ak) 2)
                        (not (compiler-backend-tail-abort-site-follows? v i hi)))
                      (let
                        [lbl : i64
                          (compiler-backend-compact-step-live v i body-lo -1)]
                        (when
                          (and
                            (>= lbl body-lo)
                            (= (bit-and (array-ref info (* (- lbl lo) 4)) 1) 0))
                          (let
                            [lrec : (&
                              v
                              be_state.CompilerBackendPeepholeLineRecord)
                              (& (array-ref v.lines lbl))]
                            (when
                              (and
                                (=
                                  (compiler-backend-peephole-record-kind lrec)
                                  compiler-backend-sweep-line-kind-label)
                                (compiler-backend-branch-local-dedup-label?
                                  (compiler-backend-peephole-record-data lrec)
                                  (compiler-backend-peephole-record-start lrec)
                                  (compiler-backend-peephole-record-end lrec)))
                              (let
                                [p2 : i64
                                  (compiler-backend-compact-step-live
                                    v
                                    lbl
                                    lo
                                    -1)]
                                [cur : i64 (array-ref meta (+ 5 ak))]
                                (cond
                                  [(and
                                      (>= p2 lo)
                                      (compiler-backend-compact-uncond-transfer?
                                        (& (array-ref v.lines p2))))
                                    (when
                                      (< cur 0)
                                      (set! (array-ref meta (+ 5 ak)) lbl))]
                                  [(and
                                      (< cur 0)
                                      (>
                                        (shr
                                          (array-ref info (* (- lbl lo) 4))
                                          1)
                                        0))
                                    (set! (array-ref meta (+ 5 ak)) lbl)]
                                  [else unit]))))))))))))
          ;; Rewrite every duplicate standalone or inline stub to canon-lbl[ak],
          ;; or strip unreferenced `.Lfail:`.
          (for [i (iterator.range body-lo hi)]
            (when
              (= (array-ref v.live i) 1)
              (let
                [ak : i64 -1]
                (let
                  [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
                    (& (array-ref v.lines i))]
                  (when
                    (=
                      (compiler-backend-peephole-record-kind rec)
                      compiler-backend-sweep-line-kind-instruction)
                    (let
                      [k : i64
                        (compiler-backend-cold-argless-abort-kind
                          (compiler-backend-peephole-record-data rec)
                          (compiler-backend-peephole-record-start rec)
                          (compiler-backend-peephole-record-end rec))]
                      (when
                        (and
                          (>= k 0)
                          (>= (array-ref meta k) 2)
                          (not
                            (compiler-backend-tail-abort-site-follows? v i hi)))
                        (set! ak k)))))
                (when
                  (>= ak 0)
                  (let
                    [prev1 : i64
                      (compiler-backend-compact-step-live v i body-lo -1)]
                    [nxt : i64 (compiler-backend-compact-step-live v i hi 1)]
                    [canon : i64 (array-ref meta (+ 5 ak))]
                    (when
                      (>= prev1 body-lo)
                      (let
                        [p1-kind : i64
                          (compiler-backend-peephole-record-kind
                            (& (array-ref v.lines prev1)))]
                        (cond
                          ;; Unlabeled inline `jcc .Lok; call <abort>; .Lok:`
                          [(and
                              (>= canon 0)
                              (>= nxt 0)
                              (=
                                p1-kind
                                compiler-backend-sweep-line-kind-instruction))
                            (let
                              [inv : String
                                (compiler-backend-compact-match-inline-abort-jcc
                                  v
                                  prev1
                                  nxt)]
                              (when
                                (> (string.string-length (& inv)) 0)
                                (compiler-backend-compact-replace-insn!
                                  v
                                  prev1
                                  (str_cat.str-cat
                                    "    "
                                    inv
                                    " "
                                    (compiler-backend-tail-label-text v canon))
                                  home
                                  false)
                                (set! (array-ref v.live i) 0)))]
                          ;; Labeled `.Lfail:; call <abort>` (skip canonical itself)
                          [(and
                              (!= prev1 canon)
                              (= p1-kind compiler-backend-sweep-line-kind-label)
                              (=
                                (bit-and (array-ref info (* (- prev1 lo) 4)) 1)
                                0)
                              (compiler-backend-branch-local-dedup-label?
                                (compiler-backend-peephole-record-data
                                  (& (array-ref v.lines prev1)))
                                (compiler-backend-peephole-record-start
                                  (& (array-ref v.lines prev1)))
                                (compiler-backend-peephole-record-end
                                  (& (array-ref v.lines prev1)))))
                            (let
                              [prev2 : i64
                                (compiler-backend-compact-step-live
                                  v
                                  prev1
                                  lo
                                  -1)]
                              [standalone? : bool
                                (and
                                  (>= prev2 lo)
                                  (compiler-backend-compact-uncond-transfer?
                                    (& (array-ref v.lines prev2))))]
                              (if standalone?
                                (when
                                  (>= canon 0)
                                  (set!
                                    (array-ref info (+ (* (- prev1 lo) 4) 2))
                                    (+ canon 1))
                                  (set! any-redirect? true)
                                  (set! (array-ref v.live prev1) 0)
                                  (set! (array-ref v.live i) 0))
                                (when
                                  (and (>= prev2 body-lo) (>= nxt 0))
                                  (let
                                    [inv : String
                                      (compiler-backend-compact-match-inline-abort-jcc
                                        v
                                        prev2
                                        nxt)]
                                    (when
                                      (> (string.string-length (& inv)) 0)
                                      (cond
                                        [(>= canon 0)
                                          (compiler-backend-compact-replace-insn!
                                            v
                                            prev2
                                            (str_cat.str-cat
                                              "    "
                                              inv
                                              " "
                                              (compiler-backend-tail-label-text
                                                v
                                                canon))
                                            home
                                            false)
                                          (when
                                            (>
                                              (shr
                                                (array-ref
                                                  info
                                                  (* (- prev1 lo) 4))
                                                1)
                                              0)
                                            (set!
                                              (array-ref
                                                info
                                                (+ (* (- prev1 lo) 4) 2))
                                              (+ canon 1))
                                            (set! any-redirect? true))
                                          (set! (array-ref v.live prev1) 0)
                                          (set! (array-ref v.live i) 0)]
                                        [(=
                                            (shr
                                              (array-ref
                                                info
                                                (* (- prev1 lo) 4))
                                              1)
                                            0)
                                          (set! (array-ref v.live prev1) 0)]
                                        [else unit]))))))]
                          [else unit]))))))))
          ;; After dedup completes, drop any surviving `call <abort>` that falls
          ;; straight through (across labels only) into an identical surviving
          ;; `call <abort>`.
          (for [i (iterator.range body-lo hi)]
            (when
              (= (array-ref v.live i) 1)
              (let
                [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
                  (& (array-ref v.lines i))]
                (when
                  (=
                    (compiler-backend-peephole-record-kind rec)
                    compiler-backend-sweep-line-kind-instruction)
                  (let
                    [ak : i64
                      (compiler-backend-cold-argless-abort-kind
                        (compiler-backend-peephole-record-data rec)
                        (compiler-backend-peephole-record-start rec)
                        (compiler-backend-peephole-record-end rec))]
                    (when
                      (and
                        (>= ak 0)
                        (not (compiler-backend-tail-abort-site-follows? v i hi)))
                      (let
                        [scan : i64
                          (compiler-backend-compact-step-live v i hi 1)]
                        (while (and
                          (>= scan 0)
                          (=
                            (compiler-backend-peephole-record-kind
                              (& (array-ref v.lines scan)))
                            compiler-backend-sweep-line-kind-label))
                          (set!
                            scan
                            (compiler-backend-compact-step-live v scan hi 1)))
                        (when
                          (and
                            (>= scan 0)
                            (=
                              (compiler-backend-peephole-record-kind
                                (& (array-ref v.lines scan)))
                              compiler-backend-sweep-line-kind-instruction)
                            (=
                              (compiler-backend-cold-argless-abort-kind
                                (compiler-backend-peephole-record-data
                                  (& (array-ref v.lines scan)))
                                (compiler-backend-peephole-record-start
                                  (& (array-ref v.lines scan)))
                                (compiler-backend-peephole-record-end
                                  (& (array-ref v.lines scan))))
                              ak)
                            (not
                              (compiler-backend-tail-abort-site-follows?
                                v
                                scan
                                hi)))
                          (set! (array-ref v.live i) 0))))))))))
        ;; Apply all recorded branch redirects (trampolines + deduplicated aborts).
        (when
          any-redirect?
          (for [i (iterator.range lo hi)]
            (when
              (= (array-ref v.live i) 1)
              (let
                [replacement : String ""]
                [is-jmp? : bool false]
                (let
                  [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
                    (& (array-ref v.lines i))]
                  (when
                    (=
                      (compiler-backend-peephole-record-kind rec)
                      compiler-backend-sweep-line-kind-instruction)
                    (let
                      [data : (Ptr u8)
                        (compiler-backend-peephole-record-data rec)]
                      [s : i64 (compiler-backend-peephole-record-start rec)]
                      [e : i64 (compiler-backend-peephole-record-end rec)]
                      (when
                        (compiler-backend-cold-prefix? data s e "    j")
                        (let
                          [me : i64
                            (compiler-backend-cold-token-end data (+ s 4) e)]
                          [ts : i64 (+ me 1)]
                          (when
                            (and
                              (< ts e)
                              (=
                                (be_state.compiler-backend-peephole-byte-at
                                  data
                                  me)
                                32)
                              (compiler-backend-layout-local-label? data ts e)
                              (= (compiler-backend-tail-symbol-end data ts e) e))
                            (let
                              [lbl : i64
                                (compiler-backend-compact-lookup-label
                                  v
                                  lo
                                  (& buckets)
                                  bmask
                                  (& info)
                                  data
                                  ts
                                  e)]
                              (when
                                (and
                                  (>= lbl lo)
                                  (> (array-ref info (+ (* (- lbl lo) 4) 2)) 0))
                                (let
                                  [canon : i64
                                    (-
                                      (array-ref info (+ (* (- lbl lo) 4) 2))
                                      1)]
                                  [hops : i64 0]
                                  (while (and
                                    (< hops 8)
                                    (>
                                      (array-ref info (+ (* (- canon lo) 4) 2))
                                      0))
                                    (set!
                                      canon
                                      (-
                                        (array-ref
                                          info
                                          (+ (* (- canon lo) 4) 2))
                                        1))
                                    (+= hops 1))
                                  (set!
                                    is-jmp?
                                    (be_operand.compiler-backend-peephole-range-eq?
                                      data
                                      (+ s 4)
                                      me
                                      "jmp"))
                                  (set!
                                    replacement
                                    (str_cat.str-cat
                                      (string.substring rec.src s (- ts s))
                                      (compiler-backend-tail-label-text v canon))))))))))))
                (unless
                  (string.eq (& replacement) "")
                  (compiler-backend-compact-replace-insn!
                    v
                    i
                    replacement
                    home
                    is-jmp?))))))))))

;; Invert `jcc .Lskip; jmp .Ltarget; [labels...] .Lskip:` -> `j!cc .Ltarget`
;; and drop trivial fallthrough `jmp .Lnext` across consecutive labels (including
;; `.L_tail_...:\n` suffix records), staying outside COLD-1's planned stub spans.
(define (compiler-backend-peephole-compact-branch-jumps!
  [v : (&mut v be_state.CompilerBackendPeepholeLineVec)]
  [cold : (& cold CompilerBackendColdPlan)]) : unit
  (when (< v.len 2) (return unit))
  (let
    [home : arena.Arena (arena.current)]
    [count : i64 v.len]
    [stub : i64 0]
    [stub-jcc : i64
      (if (< 0 cold.stubs)
        (array-ref cold.jcc 0)
        count)]
    [stub-end : i64
      (if (< 0 cold.stubs)
        (array-ref cold.target 0)
        count)]
    (for [i (iterator.range 0 count)]
      (while (>= i stub-end)
        (+= stub 1)
        (set!
          stub-jcc
          (if (< stub cold.stubs)
            (array-ref cold.jcc stub)
            count))
        (set!
          stub-end
          (if (< stub cold.stubs)
            (array-ref cold.target stub)
            count)))
      (when
        (and (< i stub-jcc) (= (array-ref v.live i) 1))
        (let
          [action : i64 0]
          [inv-text : String ""]
          [drop-idx : i64 -1]
          (let
            [rec : (& v be_state.CompilerBackendPeepholeLineRecord)
              (& (array-ref v.lines i))]
            [data : (Ptr u8) (compiler-backend-peephole-record-data rec)]
            [s : i64 (compiler-backend-peephole-record-start rec)]
            [e : i64 (compiler-backend-peephole-record-end rec)]
            (cond
              [(compiler-backend-branch-local-jmp? data s e)
                (when
                  (>=
                    (compiler-backend-branch-find-fallthrough-label
                      v
                      (+ i 1)
                      stub-jcc
                      data
                      (+ s 8)
                      e)
                    0)
                  (set! action 1))]
              [(compiler-backend-cold-prefix? data s e "    j")
                (let
                  [inv : String
                    (compiler-backend-branch-local-jcc-inv data s e)]
                  (when
                    (> (string.string-length (& inv)) 0)
                    (let
                      [ts : i64
                        (+ (compiler-backend-cold-token-end data (+ s 4) e) 1)]
                      [nxt : i64
                        (compiler-backend-compact-step-live v i stub-jcc 1)]
                      (when
                        (>= nxt 0)
                        (let
                          [nrec : (&
                            v
                            be_state.CompilerBackendPeepholeLineRecord)
                            (& (array-ref v.lines nxt))]
                          [ndata : (Ptr u8)
                            (compiler-backend-peephole-record-data nrec)]
                          [ns : i64
                            (compiler-backend-peephole-record-start nrec)]
                          [ne : i64 (compiler-backend-peephole-record-end nrec)]
                          (when
                            (and
                              (compiler-backend-branch-local-jmp? ndata ns ne)
                              (>=
                                (compiler-backend-branch-find-fallthrough-label
                                  v
                                  (+ nxt 1)
                                  stub-jcc
                                  data
                                  ts
                                  e)
                                0))
                            (set! action 2)
                            (set! drop-idx nxt)
                            (set!
                              inv-text
                              (str_cat.str-cat
                                "    "
                                inv
                                " "
                                (string.substring
                                  nrec.src
                                  (+ ns 8)
                                  (- ne (+ ns 8)))))))))))]
              [else unit]))
          (cond
            [(= action 1) (set! (array-ref v.live i) 0)]
            [(= action 2)
              (compiler-backend-compact-replace-insn! v i inv-text home false)
              (set! (array-ref v.live drop-idx) 0)]
            [else unit]))))))

;; Unified opt-level-full? (>= 2) record compaction driver.
(define (compiler-backend-peephole-compact-records!
  [backend-state : be_state.CompilerBackendState]
  [v : (&mut v be_state.CompilerBackendPeepholeLineVec)]) : unit
  (when (< v.len 2) (return unit))
  (let
    [linux? : bool
      (be_state.compiler-backend-state-emission-target-policy backend-state).linux]
    [home : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    [lo : i64 0]
    (for [close (iterator.range 0 (+ v.close-cand-len 1))]
      (let
        [hi : i64
          (if (< close v.close-cand-len)
            (array-ref v.close-cands close)
            v.len)]
        (when
          (>= (- hi lo) 2)
          (let
            [phase : arena.ArenaPhase (arena.phase scratch)]
            (in-arena
              scratch
              (unsafe
                (compiler-backend-leaq-fold-function! v lo hi home)
                (compiler-backend-zero-coalesce-function! v lo hi linux? home)
                (compiler-backend-compact-aborts-and-trampolines-function!
                  v
                  lo
                  hi
                  home)))
            (arena.rewind-safe! phase)))
        (set! lo (+ hi 1))))
    (arena.destroy-safe! scratch)
    (let
      [plan : CompilerBackendColdPlan (compiler-backend-cold-plan-empty)]
      (compiler-backend-peephole-compact-branch-jumps! v (& plan)))))

(define (compiler-backend-asm-jmp-prefix-len) : i64
  8)

;; A line that is a label followed by `:` and nothing else. Whitespace anywhere
;; (an indented directive, `.globl sym`, a label with a trailing comment) or an
;; interior colon disqualifies it, so only real label definitions -- the one
;; thing that emits zero bytes -- can separate a `jmp` from its target.
;; Is [start, end) `name:` with nothing but name bytes before the colon? The
;; name is checked eight bytes at a time, for the same reason the line splitter
;; is: emitted local names run to thirty-odd bytes, this is asked of every
;; unindented line of every function, and a byte loop here would be the single
;; most expensive piece of the layout index. One word rejects a space, a
;; tab and a second colon at once -- three `x - ones & ~x & highs` probes ORed
;; together -- and the sub-word tail is covered by one final word that OVERLAPS
;; the last full one, so no byte loop remains for a name of eight bytes or more.
(define (compiler-backend-asm-label-def-line?
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : bool
  (if (< (- end start) 2)
    false
    (if (not (= (be_state.compiler-backend-peephole-byte-at data (- end 1)) 58))
      false
      (compiler-backend-asm-label-name-clean? data start end))))

;; The walk itself, for a caller that has already established the length and the
;; trailing colon.
(define (compiler-backend-asm-label-name-clean?
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : bool
  (let
    ;; 0x0101..., 0x8080..., 0x2020..., 0x0909..., 0x3a3a...
    [ones : i64 72340172838076673]
    [highs : i64 -9187201950435737472]
    [spaces : i64 2314885530818453536]
    [tabs : i64 651061555542690057]
    [colons : i64 4195730024608447034]
    [limit : i64 (- end 1)]
    [word-limit : i64 (- limit 8)]
    [i : i64 start]
    (while (<= i word-limit)
      (let
        [w : i64
          (unsafe
            (ptr-read (ptr-cast (ptr-offset data i) : (Ptr i64))))]
        [xs : i64 (bit-xor w spaces)]
        [xt : i64 (bit-xor w tabs)]
        [xc : i64 (bit-xor w colons)]
        (unless
          (=
            (bit-and
              (bit-or
                (bit-and (- xs ones) (bit-xor xs -1))
                (bit-or
                  (bit-and (- xt ones) (bit-xor xt -1))
                  (bit-and (- xc ones) (bit-xor xc -1))))
              highs)
            0)
          (return false))
        (+= i 8)))
    (if (> i start)
      ;; One overlapping word covers whatever the stride left behind.
      (if (>= word-limit start)
        (let
          [w : i64
            (unsafe
              (ptr-read (ptr-cast (ptr-offset data word-limit) : (Ptr i64))))]
          [xs : i64 (bit-xor w spaces)]
          [xt : i64 (bit-xor w tabs)]
          [xc : i64 (bit-xor w colons)]
          (=
            (bit-and
              (bit-or
                (bit-and (- xs ones) (bit-xor xs -1))
                (bit-or
                  (bit-and (- xt ones) (bit-xor xt -1))
                  (bit-and (- xc ones) (bit-xor xc -1))))
              highs)
            0))
        true)
      (begin
        (while (< i limit)
          (let
            [b : i64 (be_state.compiler-backend-peephole-byte-at data i)]
            (when (or (= b 32) (= b 9) (= b 58)) (return false))
            (+= i 1)))
        true))))

;; Does the line begin with the emitted direct-jump prefix `"    jmp "`?
;; Tested byte-wise, `j` first: this runs on every line of the body, and the `j`
;; alone rejects all but a handful of them for one load and compare. A string
;; literal compare here costs too much for a per-line test.
(define (compiler-backend-asm-jmp-prefix-at? [data : (Ptr u8)] [start : i64]) : bool
  (and
    (= (be_state.compiler-backend-peephole-byte-at data (+ start 4)) 106)
    (= (be_state.compiler-backend-peephole-byte-at data (+ start 5)) 109)
    (= (be_state.compiler-backend-peephole-byte-at data (+ start 6)) 112)
    (= (be_state.compiler-backend-peephole-byte-at data (+ start 7)) 32)
    (= (be_state.compiler-backend-peephole-byte-at data start) 32)
    (= (be_state.compiler-backend-peephole-byte-at data (+ start 1)) 32)
    (= (be_state.compiler-backend-peephole-byte-at data (+ start 2)) 32)
    (= (be_state.compiler-backend-peephole-byte-at data (+ start 3)) 32)))

;; A line that is exactly `    jmp <symbol>`. The operand must be a bare
;; symbol: `*`, `%`, `(` and `,` reject the indirect register/memory/table
;; forms, and whitespace rejects operands with a suffix or comment.
(define (compiler-backend-asm-direct-jmp-line?
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : bool
  (let
    [operand-start : i64 (+ start (compiler-backend-asm-jmp-prefix-len))]
    (if (<= end operand-start)
      false
      (if (not (compiler-backend-asm-jmp-prefix-at? data start))
        false
        (let
          [i : i64 operand-start]
          [ok : bool true]
          (while (and ok (< i end))
            (let
              [b : i64 (be_state.compiler-backend-peephole-byte-at data i)]
              (if (or (= b 32) (= b 9) (= b 42) (= b 37) (= b 40) (= b 44))
                (set! ok false)
                unit)
              (+= i 1)))
          ok)))))

;; ---------------------------------------------------------------------------
;; #block-layout: post-register-allocation block layout of one emitted
;; function's assembly text, run INSIDE the streaming peephole's line walk:
;; the walk's own line split is the layout index, the analysis reorders that
;; index into a plan, and the walk then visits the plan's lines instead of the
;; text's, so the layout rewrites cost no second parse and no second copy of
;; the text. Two independent rewrites share the one index;
;; `compiler-backend-layout-mode` selects which run, so each can be measured on
;; its own.
;;
;;  1. TAIL DUPLICATION (mode bit 1). A `jmp L` whose target block starts a
;;     short straight-line run that ends in an unconditional `jmp` is replaced
;;     by a copy of that run. Every exit of the run is an explicit jump naming
;;     the ORIGINAL labels, so the copy defines no label of its own and L stays
;;     where it is for its other predecessors; the path through the site loses
;;     exactly one instruction, the `jmp`. Runs that end in `ret`, touch the
;;     stack (`pushq`/`popq`/`leave`), call, or carry a directive are refused:
;;     an epilogue copy would need its own unwind description, and a directive
;;     (a switch/abort data blob, a `.seh_` note) is not something a second copy
;;     may define twice.
;;
;;  2. PREDICTED-COLD ARM OUT-OF-LINING (mode bit 2). `jmp T` followed by a
;;     region that ends exactly where `T:` is defined is a two-arm branch whose
;;     second arm was laid out between the first arm and the join. When every
;;     branch entering that region is predicted NOT-TAKEN, the region moves to
;;     the end of its function body -- still inside the function's label range,
;;     before the trailing `.size`/`.seh_endproc` -- and the `jmp T` is dropped:
;;     the hot arm falls into the join and only the cold arm pays a jump back.
;;     Moving a contiguous run of emitted lines is safe because every operand
;;     the backend emits names a symbol, never a numeric displacement from the
;;     instruction pointer, so a region carries its own data blobs and internal
;;     branches with it.
;;
;; The static prediction is the standard opcode set (Ball & Larus 1993, "Branch
;; prediction for free"; GCC's PRED_OPCODE_*), read off the flag setter that
;; immediately precedes the branch:
;;   * `x < 0` / `x <= 0` predicted FALSE and `x >= 0` / `x > 0` predicted TRUE
;;     (flag setter `testq r, r` or `cmpq $0, r`);
;;   * `x == c` predicted FALSE and `x != c` predicted TRUE (`cmpq $c, r`);
;;   * GUARD CHAIN: a branch bailing to the label the previous predicted-cold
;;     branch already bailed to is predicted FALSE as well. The `and`-lowered
;;     clauses of one guard share a failure arm, so the second clause of a range
;;     check (`i >= n` after `i < 0`) inherits the first clause's prediction.
;;   * SENTINEL ARM (out-of-lining only): an arm that is nothing but one or two
;;     constant materialisations and falls into the join is the failure arm of a
;;     checked read -- `(if (and (>= i 0) (< i n)) (array-ref s i) -1)` lowers to
;;     exactly that -- which is GCC's constant-return heuristic in its
;;     non-return form. Only used when no branch into the arm is predicted TRUE
;;     and no unconditional jump enters it.
;; A branch the set says nothing about predicts nothing, and a region with any
;; such entry keeps its place: layout follows IR order everywhere else.
(define compiler-backend-layout-flag-label : i64
  1)
(define compiler-backend-layout-flag-jmp : i64
  2)
(define compiler-backend-layout-flag-jcc : i64
  4)
(define compiler-backend-layout-flag-directive : i64
  8)
(define compiler-backend-layout-flag-barrier : i64
  16)
(define compiler-backend-layout-flag-ret : i64
  32)
(define compiler-backend-layout-flag-call : i64
  64)
(define compiler-backend-layout-flag-stack : i64
  128)
(define compiler-backend-layout-flag-blank : i64
  256)

;; Prediction codes stored per branch line.
(define compiler-backend-layout-predict-unknown : i64
  0)
(define compiler-backend-layout-predict-cold : i64
  1)
(define compiler-backend-layout-predict-hot : i64
  2)
(define compiler-backend-layout-mode-dup : i64
  1)
(define compiler-backend-layout-mode-sink : i64
  2)

;; Production layout: both mechanisms.
(define compiler-backend-layout-mode : i64
  3)

;; Emitted instructions copied at one duplication site. Three is LLVM's
;; post-allocation tail-duplication budget; four admits the two-block
;; `cmp/jcc` + `mov/jmp` join.
(define compiler-backend-layout-dup-run-cap : i64
  4)

;; Lines in an out-of-lined region. A cold arm longer than this is a whole
;; slow-path loop version, and moving it stops paying for the index it costs.
(define compiler-backend-layout-region-line-cap : i64
  256)

;; Instructions in a sentinel arm.
(define compiler-backend-layout-sentinel-arm-cap : i64
  2)

;; Predicted-cold entries an arm needs before the opcode heuristics alone are
;; taken as evidence. One opcode-predicted branch is a coin flip weighted about
;; two to one (Ball & Larus measured the opcode heuristics at roughly 60-70%),
;; and paying a jump on the arm that keeps executing costs exactly what the
;; other arm saves. Two clauses bailing to the SAME arm is the guard shape --
;; the `and`-lowered clauses of a bounds or range check. At one entry the rule
;; loses on lone `x < 0` / `x == c` tests that are true on every trip.
(define compiler-backend-layout-guard-chain-entries : i64
  2)

;; Per-line index of one emitted assembly text, shared by the standalone entry
;; and by the streaming peephole's record walk. Two words per line:
;;
;;  * `starts`  line k runs from `starts[k]` to `starts[k + 1] - 1`. The split
;;              the peephole performs anyway IS the index, so there is no
;;              second scan and no `ends` array; the array holds `lines + 1`
;;              entries and its last one closes the last line.
;;  * `flags`   the nine line predicates in the low bits, plus -- for a branch
;;              line only -- its operand's byte offset from the line start, in
;;              bits `flag-ops-shift` and up. A label line's name is its whole
;;              span minus the trailing colon and no other line carries an
;;              operand either rewrite reads, so the operand-range arrays are
;;              gone as well. The offset stays OUT of a non-branch word on
;;              purpose: `flag-setter-kind` recognises a plain instruction by a
;;              flags word of exactly zero.
;;
;; The lines a rewrite ever revisits are listed as the index is built --
;; `labels` for the label table, `flow` for every branch, return and delimiting
;; directive -- so each analysis pass walks its own short list instead of every
;; line of the function again.
(define compiler-backend-layout-flag-ops-shift : i64
  16)

;; Lines to size the index for, from the byte count. Emitted assembly averages
;; well over twenty bytes per line; a text that beats the estimate is served by
;; one doubling retry rather than by a counting pass over every text.
(define (compiler-backend-layout-line-capacity [n : i64]) : i64
  (+ (/ n 20) 16))

;; The plan the analysis hands its two consumers. `len` = 0 is the identity: no
;; line moved, so the walk visits `lines` lines in order and the standalone
;; entry returns its input String untouched.
(defstruct CompilerBackendLayoutPlan
  (starts (__tl_dyn-array i64))
  (plan (__tl_dyn-array i64))
  (lines i64)
  (len i64))

(define (compiler-backend-layout-flag? [flags : i64] [bit : i64]) : bool
  (not (= (bit-and flags bit) 0)))

(define (compiler-backend-layout-space-byte? [b : i64]) : bool
  (or (= b 32) (= b 9)))

(define (compiler-backend-layout-skip-spaces
  [data : (Ptr u8)]
  [i : i64]
  [end : i64]) : i64
  (let
    [k : i64 i]
    (while (and
      (< k end)
      (compiler-backend-layout-space-byte?
        (be_state.compiler-backend-peephole-byte-at data k)))
      (+= k 1))
    k))

(define (compiler-backend-layout-token-end
  [data : (Ptr u8)]
  [i : i64]
  [end : i64]) : i64
  (let
    [k : i64 i]
    (while (and
      (< k end)
      (not
        (compiler-backend-layout-space-byte?
          (be_state.compiler-backend-peephole-byte-at data k))))
      (+= k 1))
    k))

(define (compiler-backend-layout-bare-symbol?
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : bool
  (if (<= e s)
    false
    (let
      [b : i64 (be_state.compiler-backend-peephole-byte-at data s)]
      (and
        (not (= b 42))
        (not (= b 37))
        (not (= b 40))
        (not (= b 44))
        (>=
          (be_operand.compiler-backend-peephole-scan-byte-range data s e 32)
          e)))))

;; Directives that delimit a function or an object: nothing may move across one,
;; and the first of them after a join is where an out-of-lined region is
;; re-inserted. Debug range ends and CFI closure delimit the same body.
;; Every `.seh_` note counts -- Windows unwind describes a
;; prologue/epilogue by position, so no `.seh_` line may be moved or copied.
;;
;; The second byte selects the arm: the `s` and `c` spellings share it,
;; so a directive pays one byte compare and a short name dispatch
;; name compares -- and the token
;; end, which is a walk of its own, is only measured once that byte has already
;; said a barrier is possible. Every emitted `.quad`, `.byte` and `.zero` leaves
;; here on the byte compare alone.
(define (compiler-backend-layout-barrier-line?
  [data : (Ptr u8)]
  [t : i64]
  [e : i64]) : bool
  (if (< (+ t 1) e)
    (let
      [b1 : i64 (be_state.compiler-backend-peephole-byte-at data (+ t 1))]
      (if (or (= b1 103) (= b1 115) (= b1 116) (= b1 100) (= b1 99) (= b1 101))
        (let
          [tend : i64 (compiler-backend-layout-token-end data t e)]
          (cond
            [(= b1 103)
              (be_operand.compiler-backend-peephole-range-eq?
                data
                t
                tend
                ".globl")]
            [(= b1 115)
              (or
                (be_operand.compiler-backend-peephole-range-eq?
                  data
                  t
                  tend
                  ".size")
                (be_operand.compiler-backend-peephole-range-eq?
                  data
                  t
                  tend
                  ".section")
                (and
                  (>= (- tend t) 5)
                  (be_operand.compiler-backend-peephole-range-eq?
                    data
                    t
                    (+ t 5)
                    ".seh_")))]
            [(= b1 116)
              (or
                (be_operand.compiler-backend-peephole-range-eq?
                  data
                  t
                  tend
                  ".type")
                (be_operand.compiler-backend-peephole-range-eq?
                  data
                  t
                  tend
                  ".text"))]
            [(= b1 100)
              (be_operand.compiler-backend-peephole-range-eq?
                data
                t
                tend
                ".data")]
            [(= b1 99)
              (or
                (be_operand.compiler-backend-peephole-range-eq?
                  data
                  t
                  tend
                  ".comm")
                (compiler-backend-cold-closing-line? data t t e))]
            [else
              (be_operand.compiler-backend-peephole-range-eq?
                data
                t
                tend
                ".extern")]))
        false))
    false))

;; Are two label names equal? Eight bytes at a time: emitted local names run to
;; thirty-odd bytes and share long prefixes, so the byte-wise compare the rest
;; of the peephole uses would spend most of the pass here. The tail is folded
;; into one more word read that overlaps the last full word, which is in range
;; whenever the name is at least eight bytes -- shorter names take the byte
;; loop.
(define (compiler-backend-layout-name-eq?
  [data : (Ptr u8)]
  [ls : i64]
  [le : i64]
  [rs : i64]
  [re : i64]) : bool
  (let
    [len : i64 (- le ls)]
    (if (not (= len (- re rs)))
      false
      (if (< len 8)
        (be_operand.compiler-backend-peephole-ranges-eq? data ls le data rs re)
        (let
          [i : i64 0]
          [stop : i64 (- len 8)]
          [ok : bool true]
          (while (and ok (< i stop))
            (unless
              (=
                (unsafe
                  (ptr-read (ptr-cast (ptr-offset data (+ ls i)) : (Ptr i64))))
                (unsafe
                  (ptr-read (ptr-cast (ptr-offset data (+ rs i)) : (Ptr i64)))))
              (set! ok false))
            (+= i 8))
          (and
            ok
            (=
              (unsafe
                (ptr-read (ptr-cast (ptr-offset data (- le 8)) : (Ptr i64))))
              (unsafe
                (ptr-read (ptr-cast (ptr-offset data (- re 8)) : (Ptr i64)))))))))))

;; Only the backend's own function-local labels take part in either rewrite.
;; A global symbol operand is a tail call into another function, and pinning the
;; rewrites to `.L` names also makes this pass agree with itself whether it is
;; handed one function's text or a whole program's: local names are unique per
;; function, global ones are not scoped at all.
(define (compiler-backend-layout-local-label?
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : bool
  (and
    (>= (- e s) 2)
    (= (be_state.compiler-backend-peephole-byte-at data s) 46)
    (= (be_state.compiler-backend-peephole-byte-at data (+ s 1)) 76)))

;; `movq $c, %reg` / `movl $c, %reg` / `movabsq $c, %reg` / `xorl %r, %r`: an
;; instruction whose whole effect is to place a numeric literal in a register.
;; A local address load should keep its layout whether it uses LEA or MOV.
;; Asked only of the handful of lines inside a candidate arm.
(define (compiler-backend-layout-const-line?
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : bool
  (let
    [t : i64 (compiler-backend-layout-skip-spaces data s e)]
    [tend : i64 0]
    (set! tend (compiler-backend-layout-token-end data t e))
    (let
      [ops : i64 (compiler-backend-layout-skip-spaces data tend e)]
      [comma : i64
        (be_operand.compiler-backend-peephole-scan-byte-range data tend e 44)]
      (if (or (>= comma e) (>= ops e))
        false
        (let
          [rhs : i64 (compiler-backend-layout-skip-spaces data (+ comma 1) e)]
          (if (>= rhs e)
            false
            (if (or
              (be_operand.compiler-backend-peephole-range-eq?
                data
                t
                tend
                "movq")
              (be_operand.compiler-backend-peephole-range-eq?
                data
                t
                tend
                "movl")
              (be_operand.compiler-backend-peephole-range-eq?
                data
                t
                tend
                "movabsq"))
              (and
                (= (be_state.compiler-backend-peephole-byte-at data ops) 36)
                (not
                  (=
                    (be_state.compiler-backend-peephole-byte-at data (+ ops 1))
                    46))
                (= (be_state.compiler-backend-peephole-byte-at data rhs) 37)
                (>=
                  (be_operand.compiler-backend-peephole-scan-byte-range
                    data
                    rhs
                    e
                    40)
                  e))
              (and
                (or
                  (be_operand.compiler-backend-peephole-range-eq?
                    data
                    t
                    tend
                    "xorl")
                  (be_operand.compiler-backend-peephole-range-eq?
                    data
                    t
                    tend
                    "xorq"))
                (= (be_state.compiler-backend-peephole-byte-at data ops) 37)
                (be_operand.compiler-backend-peephole-ranges-eq?
                  data
                  ops
                  comma
                  data
                  rhs
                  e)))))))))

;; Is this `call` line one of the runtime's noreturn aborts? Asked only of the
;; line behind a duplication site.
(define (compiler-backend-layout-abort-line?
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : bool
  (compiler-backend-peephole-line-noreturn-abort? data s e))

;; One line's predicate set, packed with the operand offset its consumers need:
;; the jump target for a branch line. A label line needs no offset (its name
;; starts at the line start) and no other line has an operand at all.
;;
;; This runs on every line of every emitted function and almost every line is of
;; no interest to either rewrite, so the reject is what it is written around.
;; An emitted instruction is indented and a label definition is not, which the
;; first byte settles; the mnemonic then starts four bytes in, and its first
;; byte alone rules out everything but a jump, a return, a call, a stack
;; instruction and a directive. Only those, and the unindented lines, are looked
;; at further. The literal-materialisation and noreturn-abort questions are NOT
;; asked here: only a candidate arm and the line behind a duplication site ever
;; need them.
(define (compiler-backend-layout-classify-token
  [data : (Ptr u8)]
  [s : i64]
  [t : i64]
  [e : i64]) : i64
  (let
    [b0 : i64 (be_state.compiler-backend-peephole-byte-at data t)]
    (if (= b0 46)
      ;; A directive is settled by its name; the bytes behind the head are of
      ;; no use to it, so they are not read on this arm at all.
      (bit-or
        compiler-backend-layout-flag-directive
        (if (compiler-backend-layout-barrier-line? data t e)
          compiler-backend-layout-flag-barrier
          0))
      (let
        [b1 : i64
          (if (< (+ t 1) e)
            (be_state.compiler-backend-peephole-byte-at data (+ t 1))
            0)]
        [b2 : i64
          (if (< (+ t 2) e)
            (be_state.compiler-backend-peephole-byte-at data (+ t 2))
            0)]
        [b3 : i64
          (if (< (+ t 3) e)
            (be_state.compiler-backend-peephole-byte-at data (+ t 3))
            0)]
        (cond
          [(= b0 106)
            (let
              [jmp? : bool (and (= b1 109) (= b2 112) (= b3 32))]
              [tend : i64
                (if jmp?
                  (+ t 3)
                  (compiler-backend-layout-token-end data t e))]
              [ops : i64 (compiler-backend-layout-skip-spaces data tend e)]
              (if (and
                (>= (- tend t) 2)
                (compiler-backend-layout-bare-symbol? data ops e))
                (bit-or
                  (if jmp?
                    compiler-backend-layout-flag-jmp
                    compiler-backend-layout-flag-jcc)
                  (shl (- ops s) compiler-backend-layout-flag-ops-shift))
                0))]
          [(and (= b0 114) (= b1 101) (= b2 116) (or (= b3 32) (= b3 113)))
            compiler-backend-layout-flag-ret]
          [(and (= b0 99) (= b1 97) (= b2 108) (= b3 108))
            compiler-backend-layout-flag-call]
          [(and (= b0 112) (or (= b1 117) (= b1 111)) (not (= b2 32)))
            compiler-backend-layout-flag-stack]
          [(and (= b0 108) (= b1 101) (= b2 97) (= b3 118))
            compiler-backend-layout-flag-stack]
          [else 0])))))

;; The one-shape mnemonics, settled by the three bytes behind the head: `ret`,
;; `call`, `pushq`/`popq` and `leave` carry a flag and nothing else, so they
;; never need the token walk a directive or a branch does. `kind` is the head
;; table's answer, and the byte reads keep that table's zero-past-the-line
;; convention, so this agrees with `classify-token` on every line either can
;; see.
(define (compiler-backend-layout-classify-simple
  [data : (Ptr u8)]
  [t : i64]
  [e : i64]
  [kind : i64]) : i64
  (let
    [b1 : i64
      (if (< (+ t 1) e)
        (be_state.compiler-backend-peephole-byte-at data (+ t 1))
        0)]
    [b2 : i64
      (if (< (+ t 2) e)
        (be_state.compiler-backend-peephole-byte-at data (+ t 2))
        0)]
    [b3 : i64
      (if (< (+ t 3) e)
        (be_state.compiler-backend-peephole-byte-at data (+ t 3))
        0)]
    (cond
      [(= kind 50)
        (if (and (= b1 101) (= b2 116) (or (= b3 32) (= b3 113)))
          compiler-backend-layout-flag-ret
          0)]
      [(= kind 51)
        (if (and (= b1 97) (= b2 108) (= b3 108))
          compiler-backend-layout-flag-call
          0)]
      [(= kind 52)
        (if (and (or (= b1 117) (= b1 111)) (not (= b2 32)))
          compiler-backend-layout-flag-stack
          0)]
      [else
        (if (and (= b1 101) (= b2 97) (= b3 118))
          compiler-backend-layout-flag-stack
          0)])))

(define (compiler-backend-layout-classify-line
  [data : (Ptr u8)]
  [s : i64]
  [e : i64]) : i64
  (if (= (be_state.compiler-backend-peephole-byte-at data s) 32)
    (let
      [t : i64
        (if (and
          (< (+ s 4) e)
          (= (be_state.compiler-backend-peephole-byte-at data (+ s 3)) 32)
          (not (= (be_state.compiler-backend-peephole-byte-at data (+ s 4)) 32)))
          (+ s 4)
          (compiler-backend-layout-skip-spaces data s e))]
      (if (>= t e)
        compiler-backend-layout-flag-blank
        (let
          [head : i64 (be_state.compiler-backend-peephole-byte-at data t)]
          (if (or
            (= head 106)
            (= head 46)
            (= head 114)
            (= head 99)
            (= head 112)
            (= head 108))
            (compiler-backend-layout-classify-token data s t e)
            0))))
    (let
      [head : i64 (be_state.compiler-backend-peephole-byte-at data s)]
      [t : i64
        (if (or (= head 32) (= head 9))
          (compiler-backend-layout-skip-spaces data s e)
          s)]
      (cond
        [(>= t e) compiler-backend-layout-flag-blank]
        [(and
            (= (be_state.compiler-backend-peephole-byte-at data (- e 1)) 58)
            (>= (- e s) 2)
            (compiler-backend-asm-label-name-clean? data s e))
          (bit-or
            compiler-backend-layout-flag-label
            (if (compiler-backend-cold-closing-line? data s s e)
              compiler-backend-layout-flag-barrier
              0))]
        [else (compiler-backend-layout-classify-token data s t e)]))))

;; What a mnemonic's first byte can make of a line, as a byte per possible head:
;; `0` nothing, `1` walk the token (`.` 46 for a directive, `j` 106 for a
;; branch), `2` `ret` (114), `3` `call` (99), `4` `pushq`/`popq` (112), `5`
;; `leave` (108). Most emitted lines are `0`, and for them this is one indexed
;; byte load; the four one-shape kinds are then settled by three byte compares
;; in a leaf instead of a call into the token dispatch and its spill frame. A
;; shift over a bit set would filter as well but costs the shift-amount guards
;; the language inserts around a variable shift, and would not carry the kind.
(define compiler-backend-layout-head-table : String
  "0000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000003000000105000402000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")

(define (compiler-backend-layout-split-lines
  [data : (Ptr u8)]
  [n : i64]
  [cap : i64]
  [starts : (MutPtr i64)]) : i64
  (let
    [k : i64 0]
    [i : i64 0]
    (while (< i n)
      (when (>= k cap) (return -1))
      (unsafe
        (ptr-write! (ptr-offset starts k) i))
      (set!
        i
        (+ (be_operand.compiler-backend-peephole-scan-byte-range data i n 10) 1))
      (+= k 1))
    (unsafe
      (ptr-write! (ptr-offset starts k) i))
    k))

;; Classify each split line into `flags`.
;;
;; The emitted instruction shape -- four leading spaces, then a mnemonic -- is
;; recognised inline here, because it is the shape of nearly every line and the
;; general classifier's call, frame and dispatch cost more than its answer.
;; Anything else (a label definition, a directive at column zero, an oddly
;; indented or very short line) falls out to `classify-line`, which is the
;; function this fast path is a specialisation of.
;;
;; Listing the classified lines is a SEPARATE walk below, not a tail of this
;; loop: the four list cursors and their counters are dead weight on the ninety
;; per cent of lines that are never listed, and holding them here pushed the
;; span and flag cursors into memory, where every iteration paid for reloading
;; them.
(define (compiler-backend-layout-classify-lines!
  [data : (Ptr u8)]
  [lines : i64]
  [starts : (MutPtr i64)]
  [flags : (MutPtr i64)]) : unit
  (let
    [head-table : (Ptr u8)
      (unsafe
        (string-data compiler-backend-layout-head-table))]
    [i : i64
      (unsafe
        (ptr-read (ptr-offset starts 0)))]
    (for [k (iterator.range 0 lines)]
      (let
        [next : i64
          (unsafe
            (ptr-read (ptr-offset starts (+ k 1))))]
        [e : i64 (- next 1)]
        [head : i64
          (if (< (+ i 4) e)
            (be_state.compiler-backend-peephole-byte-at data (+ i 4))
            32)]
        (unsafe
          (ptr-write!
            (ptr-offset flags k)
            (if (and
              (not (= head 32))
              (= (be_state.compiler-backend-peephole-byte-at data i) 32)
              (= (be_state.compiler-backend-peephole-byte-at data (+ i 3)) 32))
              (let
                [kind : i64
                  (be_state.compiler-backend-peephole-byte-at head-table head)]
                (cond
                  [(= kind 48) 0]
                  [(= kind 49)
                    (compiler-backend-layout-classify-token data i (+ i 4) e)]
                  [else
                    (compiler-backend-layout-classify-simple
                      data
                      (+ i 4)
                      e
                      kind)]))
              (compiler-backend-layout-classify-line data i e))))
        (set! i next)))
    unit))

;; List the lines the analysis revisits -- `labels` for the label table, `flow`
;; for every branch, return and delimiting directive -- so each later pass walks
;; its own short list instead of every line of the function again. `counts`
;; returns the label, flow and `jmp` totals; the `jmp` total decides whether
;; either rewrite has anything to look at.
(define (compiler-backend-layout-list-lines!
  [lines : i64]
  [flags : (MutPtr i64)]
  [labels : (MutPtr i64)]
  [flow : (MutPtr i64)]
  [counts : (&mut counts (__tl_dyn-array i64))]) : unit
  (let
    [flow-bits : i64
      (bit-or
        compiler-backend-layout-flag-jmp
        (bit-or
          compiler-backend-layout-flag-jcc
          (bit-or
            compiler-backend-layout-flag-ret
            compiler-backend-layout-flag-barrier)))]
    [listed-bits : i64 (bit-or flow-bits compiler-backend-layout-flag-label)]
    [label-count : i64 0]
    [flow-count : i64 0]
    [jumps : i64 0]
    (for [k (iterator.range 0 lines)]
      (let
        [line-flags : i64
          (unsafe
            (ptr-read (ptr-offset flags k)))]
        (unless
          (= (bit-and line-flags listed-bits) 0)
          (unless
            (= (bit-and line-flags compiler-backend-layout-flag-label) 0)
            (unsafe
              (ptr-write! (ptr-offset labels label-count) k))
            ;; The label's ORDINAL rides in the same high half a branch
            ;; line spends on its operand offset -- no line is both --
            ;; so the reference counters are four words per label
            ;; instead of four per line.
            (unsafe
              (ptr-write!
                (ptr-offset flags k)
                (bit-or
                  line-flags
                  (shl label-count compiler-backend-layout-flag-ops-shift))))
            (+= label-count 1))
          (unless
            (= (bit-and line-flags flow-bits) 0)
            (unsafe
              (ptr-write! (ptr-offset flow flow-count) k))
            (+= flow-count 1)
            (unless
              (= (bit-and line-flags compiler-backend-layout-flag-jmp) 0)
              (+= jumps 1))))))
    (set! (array-ref counts 0) label-count)
    (set! (array-ref counts 1) flow-count)
    (set! (array-ref counts 2) jumps)
    unit))

;; Label name hash: three word reads and a multiply-shift. Emitted local labels
;; share a long per-function prefix AND, once inlining has run, a long common
;; tail (`.Lf7_inl.entry.4.if_then` beside `.Lf7_inl.entry.9.if_then`), so both
;; ends alone leave the distinguishing bytes unread -- the middle word is what
;; separates them. The multiply is the standard Fibonacci-constant scramble and
;; wraps deliberately; the ranked bits are the high ones, which every input bit
;; reaches. The hash is private to one analysis and only ever orders probes, so
;; its spelling is free to change.
(define (compiler-backend-layout-hash [data : (Ptr u8)] [s : i64] [e : i64]) : i64
  (let
    [len : i64 (- e s)]
    (if (< len 8)
      (let
        [h : i64 (bit-and (+ 2166136261 (* 131 len)) 1073741823)]
        (for [k (iterator.range s e)]
          (set!
            h
            (bit-and
              (+ (* h 131) (be_state.compiler-backend-peephole-byte-at data k))
              1073741823)))
        h)
      (let
        [head : i64
          (unsafe
            (ptr-read (ptr-cast (ptr-offset data s) : (Ptr i64))))]
        [tail : i64
          (unsafe
            (ptr-read (ptr-cast (ptr-offset data (- e 8)) : (Ptr i64))))]
        [middle : i64
          (unsafe
            (ptr-read
              (ptr-cast (ptr-offset data (+ s (- (shr len 1) 4))) : (Ptr i64))))]
        [mixed : i64
          (bit-xor (bit-xor head tail) (bit-xor (* 3 middle) (* 131 len)))]
        [folded : i64 (bit-xor mixed (shr mixed 32))]
        (bit-and (shr (* folded 2654435761) 34) 1073741823)))))

;; Power-of-two table for `count` names. The extra slots are zero words the
;; allocator already cleared.
(define (compiler-backend-layout-table-capacity [count : i64]) : i64
  (let
    [cap : i64 16]
    (while (< cap (* 2 (+ count 1)))
      (set! cap (* cap 2)))
    cap))

;; Open-addressed label table, two words per slot: the defining line index plus
;; one -- so zero stays the empty marker -- and the name's hash. Holding the
;; hash means a probe that lands on another name is rejected by one integer
;; compare instead of a name compare. A duplicate name keeps its FIRST
;; definition: the emitter never repeats one inside a function, and keeping the
;; first is the conservative answer if a caller ever hands this pass a whole
;; program.
(define (compiler-backend-layout-table-insert!
  [data : (Ptr u8)]
  [starts : (MutPtr i64)]
  [table : (MutPtr i64)]
  [cap : i64]
  [line : i64]) : unit
  (let
    [s : i64
      (unsafe
        (ptr-read (ptr-offset starts line)))]
    [e : i64
      (-
        (unsafe
          (ptr-read (ptr-offset starts (+ line 1))))
        2)]
    [h : i64 (compiler-backend-layout-hash data s e)]
    [mask : i64 (- cap 1)]
    [slot : i64 (bit-and h mask)]
    [placed : bool false]
    [probes : i64 0]
    (while (and (not placed) (< probes cap))
      (let
        [cell : i64 (* 2 slot)]
        [held : i64
          (unsafe
            (ptr-read (ptr-offset table cell)))]
        (cond
          [(= held 0)
            (unsafe
              (ptr-write! (ptr-offset table cell) (+ line 1)))
            (unsafe
              (ptr-write! (ptr-offset table (+ cell 1)) h))
            (set! placed true)]
          [(and
              (=
                (unsafe
                  (ptr-read (ptr-offset table (+ cell 1))))
                h)
              (compiler-backend-layout-name-eq?
                data
                s
                e
                (unsafe
                  (ptr-read (ptr-offset starts (- held 1))))
                (-
                  (unsafe
                    (ptr-read (ptr-offset starts held)))
                  2)))
            (set! placed true)]
          [else (set! slot (bit-and (+ slot 1) mask))])
        (+= probes 1)))
    unit))

;; Defining line of the label spelled in [s, e), or -1.
(define (compiler-backend-layout-table-lookup
  [data : (Ptr u8)]
  [starts : (MutPtr i64)]
  [table : (MutPtr i64)]
  [cap : i64]
  [s : i64]
  [e : i64]) : i64
  (let
    [h : i64 (compiler-backend-layout-hash data s e)]
    [mask : i64 (- cap 1)]
    [slot : i64 (bit-and h mask)]
    [found : i64 -1]
    [done : bool false]
    [probes : i64 0]
    (while (and (not done) (< probes cap))
      (let
        [cell : i64 (* 2 slot)]
        [held : i64
          (unsafe
            (ptr-read (ptr-offset table cell)))]
        (cond
          [(= held 0) (set! done true)]
          [(and
            (=
              (unsafe
                (ptr-read (ptr-offset table (+ cell 1))))
              h)
            (compiler-backend-layout-name-eq?
              data
              s
              e
              (unsafe
                (ptr-read (ptr-offset starts (- held 1))))
              (-
                (unsafe
                  (ptr-read (ptr-offset starts held)))
                2)))
            (set! found (- held 1))
            (set! done true)]
          [else (set! slot (bit-and (+ slot 1) mask))])
        (+= probes 1)))
    found))

;; Fill the label table from the label lines.
(define (compiler-backend-layout-build-table!
  [data : (Ptr u8)]
  [starts : (MutPtr i64)]
  [labels : (MutPtr i64)]
  [label-count : i64]
  [table : (MutPtr i64)]
  [cap : i64]) : unit
  (for [k (iterator.range 0 label-count)]
    (compiler-backend-layout-table-insert!
      data
      starts
      table
      cap
      (unsafe
        (ptr-read (ptr-offset labels k)))))
  unit)

;; Resolve the direct branch operands selected by `which` to the lines that
;; define them. The unconditional jumps are resolved first because both
;; rewrites are stated over them; the conditional ones are resolved only if a
;; region shape turns out to want a prediction, which is the only thing that
;; ever reads their targets.
(define (compiler-backend-layout-resolve-targets!
  [data : (Ptr u8)]
  [starts : (MutPtr i64)]
  [flags : (MutPtr i64)]
  [flow : (MutPtr i64)]
  [flow-count : i64]
  [which : i64]
  [target : (MutPtr i64)]
  [table : (MutPtr i64)]
  [cap : i64]) : unit
  (for [k (iterator.range 0 flow-count)]
    (let
      [i : i64
        (unsafe
          (ptr-read (ptr-offset flow k)))]
      [line-flags : i64
        (unsafe
          (ptr-read (ptr-offset flags i)))]
      (unless
        (= (bit-and line-flags which) 0)
        (let
          [ops : i64
            (+
              (unsafe
                (ptr-read (ptr-offset starts i)))
              (shr line-flags compiler-backend-layout-flag-ops-shift))]
          [ope : i64
            (-
              (unsafe
                (ptr-read (ptr-offset starts (+ i 1))))
              1)]
          (unsafe
            (ptr-write!
              (ptr-offset target i)
              (if (compiler-backend-layout-local-label? data ops ope)
                (compiler-backend-layout-table-lookup
                  data
                  starts
                  table
                  cap
                  ops
                  ope)
                -1)))))))
  unit)

;; The flag setter a branch reads: 0 none, 1 a comparison against zero
;; (`testq r, r` or `cmpq $0, r`), 2 a comparison against a non-zero literal.
(define (compiler-backend-layout-flag-setter-kind
  [data : (Ptr u8)]
  [starts : (MutPtr i64)]
  [flags : (MutPtr i64)]
  [i : i64]) : i64
  (let
    [j : i64 (- i 1)]
    [kind : i64 0]
    [done : bool false]
    (while (and (not done) (>= j 0))
      (if (=
        (bit-and
          (unsafe
            (ptr-read (ptr-offset flags j)))
          (bit-or
            compiler-backend-layout-flag-label
            compiler-backend-layout-flag-blank))
        0)
        (set! done true)
        (-= j 1)))
    (when
      (>= j 0)
      (when
        (=
          (unsafe
            (ptr-read (ptr-offset flags j)))
          0)
        (let
          [s : i64
            (unsafe
              (ptr-read (ptr-offset starts j)))]
          [e : i64
            (-
              (unsafe
                (ptr-read (ptr-offset starts (+ j 1))))
              1)]
          [t : i64 (compiler-backend-layout-skip-spaces data s e)]
          [tend : i64 (compiler-backend-layout-token-end data t e)]
          [ops : i64 (compiler-backend-layout-skip-spaces data tend e)]
          [comma : i64
            (be_operand.compiler-backend-peephole-scan-byte-range
              data
              tend
              e
              44)]
          (when
            (< comma e)
            (let
              [rhs : i64
                (compiler-backend-layout-skip-spaces data (+ comma 1) e)]
              [b0 : i64 (be_state.compiler-backend-peephole-byte-at data t)]
              (cond
                [(and
                    (= b0 116)
                    (or
                      (be_operand.compiler-backend-peephole-range-eq?
                        data
                        t
                        tend
                        "testq")
                      (be_operand.compiler-backend-peephole-range-eq?
                        data
                        t
                        tend
                        "testl")
                      (be_operand.compiler-backend-peephole-range-eq?
                        data
                        t
                        tend
                        "test"))
                    (= (be_state.compiler-backend-peephole-byte-at data ops) 37)
                    (be_operand.compiler-backend-peephole-ranges-eq?
                      data
                      ops
                      comma
                      data
                      rhs
                      e))
                  (set! kind 1)]
                [(and
                    (= b0 99)
                    (or
                      (be_operand.compiler-backend-peephole-range-eq?
                        data
                        t
                        tend
                        "cmpq")
                      (be_operand.compiler-backend-peephole-range-eq?
                        data
                        t
                        tend
                        "cmpl")
                      (be_operand.compiler-backend-peephole-range-eq?
                        data
                        t
                        tend
                        "cmp"))
                    (= (be_state.compiler-backend-peephole-byte-at data ops) 36))
                  (set!
                    kind
                    (if (and
                      (= (- comma ops) 2)
                      (=
                        (be_state.compiler-backend-peephole-byte-at
                          data
                          (+ ops 1))
                        48))
                      1
                      2))]
                [else unit]))))))
    kind))

;; Ball-Larus opcode prediction for one conditional branch, or "unknown". The
;; condition code is read as bytes: one for `l` `g` `s` `e` `z`, two for `le`
;; `ge` `ns` `ne` `nz`. Everything else -- the unsigned codes, the flag codes --
;; predicts nothing.
(define (compiler-backend-layout-opcode-prediction
  [data : (Ptr u8)]
  [starts : (MutPtr i64)]
  [flags : (MutPtr i64)]
  [i : i64]) : i64
  (let
    [kind : i64 (compiler-backend-layout-flag-setter-kind data starts flags i)]
    (if (= kind 0)
      compiler-backend-layout-predict-unknown
      (let
        [s : i64
          (unsafe
            (ptr-read (ptr-offset starts i)))]
        [e : i64
          (-
            (unsafe
              (ptr-read (ptr-offset starts (+ i 1))))
            1)]
        [t : i64 (compiler-backend-layout-skip-spaces data s e)]
        [tend : i64 (compiler-backend-layout-token-end data t e)]
        [n : i64 (- (- tend t) 1)]
        [c0 : i64 (be_state.compiler-backend-peephole-byte-at data (+ t 1))]
        [c1 : i64
          (if (>= n 2)
            (be_state.compiler-backend-peephole-byte-at data (+ t 2))
            0)]
        (cond
          [(and (= n 1) (or (= c0 101) (= c0 122)))
            compiler-backend-layout-predict-cold]
          [(and (= n 2) (= c0 110) (or (= c1 101) (= c1 122)))
            compiler-backend-layout-predict-hot]
          [(not (= kind 1)) compiler-backend-layout-predict-unknown]
          [(and (= n 1) (or (= c0 108) (= c0 115)))
            compiler-backend-layout-predict-cold]
          [(and (= n 2) (= c0 108) (= c1 101))
            compiler-backend-layout-predict-cold]
          [(and (= n 1) (= c0 103)) compiler-backend-layout-predict-hot]
          [(and (= n 2) (= c0 103) (= c1 101))
            compiler-backend-layout-predict-hot]
          [(and (= n 2) (= c0 110) (= c1 115))
            compiler-backend-layout-predict-hot]
          [else compiler-backend-layout-predict-unknown])))))

;; Per-branch prediction and the per-label reference tally, in one walk of the
;; flow list. The guard chain is applied in emission order: a branch the opcode
;; set cannot call inherits COLD when it bails to the same label the previous
;; predicted-cold branch bailed to. The chain breaks at any unconditional
;; transfer and at any branch naming a different label. `refs` holds four
;; counters per LABEL line (all / unconditional / predicted-cold /
;; predicted-hot), so a region's entry set is a sum over its own label lines
;; instead of a scan; tallying in this same walk is exact because the only
;; prediction a branch's tally reads is its own.
(define (compiler-backend-layout-predict-and-tally!
  [data : (Ptr u8)]
  [starts : (MutPtr i64)]
  [flags : (MutPtr i64)]
  [target : (MutPtr i64)]
  [pred : (MutPtr i64)]
  [refs : (MutPtr i64)]
  [flow : (MutPtr i64)]
  [flow-count : i64]) : unit
  (let
    [chain : i64 -1]
    (for [k (iterator.range 0 flow-count)]
      (let
        [i : i64
          (unsafe
            (ptr-read (ptr-offset flow k)))]
        [line-flags : i64
          (unsafe
            (ptr-read (ptr-offset flags i)))]
        (cond
          [(not (= (bit-and line-flags compiler-backend-layout-flag-jcc) 0))
            (let
              [to : i64
                (unsafe
                  (ptr-read (ptr-offset target i)))]
              [base : i64
                (compiler-backend-layout-opcode-prediction data starts flags i)]
              [final : i64 0]
              (set!
                final
                (if (and
                  (= base compiler-backend-layout-predict-unknown)
                  (>= to 0)
                  (= to chain))
                  compiler-backend-layout-predict-cold
                  base))
              (unsafe
                (ptr-write! (ptr-offset pred i) final))
              (if (= final compiler-backend-layout-predict-cold)
                (set! chain to)
                (unless (= to chain) (set! chain -1)))
              (when
                (>= to 0)
                (let
                  [cell : i64
                    (*
                      4
                      (shr
                        (unsafe
                          (ptr-read (ptr-offset flags to)))
                        compiler-backend-layout-flag-ops-shift))]
                  [slot : i64
                    (cond
                      [(= final compiler-backend-layout-predict-cold) 2]
                      [(= final compiler-backend-layout-predict-hot) 3]
                      [else 0])]
                  (unsafe
                    (ptr-write!
                      (ptr-offset refs cell)
                      (+
                        (unsafe
                          (ptr-read (ptr-offset refs cell)))
                        1)))
                  (when
                    (> slot 0)
                    (unsafe
                      (ptr-write!
                        (ptr-offset refs (+ cell slot))
                        (+
                          (unsafe
                            (ptr-read (ptr-offset refs (+ cell slot))))
                          1))))
                  unit)))]
          [(not (= (bit-and line-flags compiler-backend-layout-flag-jmp) 0))
            (let
              [to : i64
                (unsafe
                  (ptr-read (ptr-offset target i)))]
              (set! chain -1)
              (when
                (>= to 0)
                (let
                  [cell : i64
                    (*
                      4
                      (shr
                        (unsafe
                          (ptr-read (ptr-offset flags to)))
                        compiler-backend-layout-flag-ops-shift))]
                  (unsafe
                    (ptr-write!
                      (ptr-offset refs cell)
                      (+
                        (unsafe
                          (ptr-read (ptr-offset refs cell)))
                        1)))
                  (unsafe
                    (ptr-write!
                      (ptr-offset refs (+ cell 1))
                      (+
                        (unsafe
                          (ptr-read (ptr-offset refs (+ cell 1))))
                        1)))
                  unit)))]
          [else (set! chain -1)])))
    unit))

;; Everything the selector needs to know about the region [rs, re) -- the lines
;; between a `jmp T` and the definition of `T` -- packed into one word by one
;; walk, because this runs for every forward `jmp` in every function:
;;   bit 0   the shape is a candidate at all: the region starts at a label,
;;           carries at least one real line, stays under the line cap and holds
;;           no function- or object-delimiting directive;
;;   bit 1   a jump must follow the region where it lands. Only a region whose
;;           LAST line is itself an unconditional transfer needs none: a region
;;           ending in label definitions needs one even when the instruction
;;           before those labels is a `jmp`, because the labels are entry points
;;           of their own and where they stood they fell into the join;
;;   bit 2   the sentinel shape: the region is nothing but one or two literal
;;           materialisations.
(define compiler-backend-layout-region-shape-ok : i64
  1)
(define compiler-backend-layout-region-needs-jump : i64
  2)
(define compiler-backend-layout-region-sentinel : i64
  4)

(define (compiler-backend-layout-region-scan
  [data : (Ptr u8)]
  [starts : (MutPtr i64)]
  [flags : (MutPtr i64)]
  [rs : i64]
  [re : i64]) : i64
  (if (or
    (>= rs re)
    (> (- re rs) compiler-backend-layout-region-line-cap)
    (=
      (bit-and
        (unsafe
          (ptr-read (ptr-offset flags rs)))
        compiler-backend-layout-flag-label)
      0))
    0
    (let
      [skip-bits : i64
        (bit-or
          compiler-backend-layout-flag-label
          compiler-backend-layout-flag-blank)]
      [stop-bits : i64
        (bit-or
          compiler-backend-layout-flag-jmp
          compiler-backend-layout-flag-ret)]
      [body : i64 0]
      [barrier : bool false]
      [only-const : bool true]
      (for [k (iterator.range rs re)]
        (let
          [line-flags : i64
            (unsafe
              (ptr-read (ptr-offset flags k)))]
          (unless
            (= (bit-and line-flags compiler-backend-layout-flag-barrier) 0)
            (set! barrier true))
          (when
            (= (bit-and line-flags skip-bits) 0)
            (+= body 1)
            (when
              (and
                only-const
                (<= body compiler-backend-layout-sentinel-arm-cap))
              (unless
                (compiler-backend-layout-const-line?
                  data
                  (unsafe
                    (ptr-read (ptr-offset starts k)))
                  (-
                    (unsafe
                      (ptr-read (ptr-offset starts (+ k 1))))
                    1))
                (set! only-const false))))))
      (if (or barrier (= body 0))
        0
        (bit-or
          compiler-backend-layout-region-shape-ok
          (bit-or
            (if (=
              (bit-and
                (unsafe
                  (ptr-read (ptr-offset flags (- re 1))))
                stop-bits)
              0)
              compiler-backend-layout-region-needs-jump
              0)
            (if (and
              only-const
              (<= body compiler-backend-layout-sentinel-arm-cap))
              compiler-backend-layout-region-sentinel
              0)))))))

;; Is every branch into the region predicted NOT-TAKEN? Counted as a sum over
;; the region's own label lines minus the branches that stay inside it: an
;; internal back edge is not an entry. The opcode heuristics carry the arm only
;; in the guard shape -- at least `guard-chain-entries` clauses bailing to it,
;; every one of them predicted NOT-TAKEN. `sentinel?` swaps that in for the
;; constant-arm heuristic, which needs only that nothing entering the arm is
;; predicted TAKEN and that no unconditional jump names it.
(define (compiler-backend-layout-region-cold?
  [flags : (MutPtr i64)]
  [target : (MutPtr i64)]
  [pred : (MutPtr i64)]
  [refs : (MutPtr i64)]
  [rs : i64]
  [re : i64]
  [sentinel? : bool]) : bool
  (let
    [branch-bits : i64
      (bit-or compiler-backend-layout-flag-jmp compiler-backend-layout-flag-jcc)]
    [total : i64 0]
    [uncond : i64 0]
    [cold : i64 0]
    [hot : i64 0]
    (for [k (iterator.range rs re)]
      (let
        [line-flags : i64
          (unsafe
            (ptr-read (ptr-offset flags k)))]
        (unless
          (= (bit-and line-flags compiler-backend-layout-flag-label) 0)
          (let
            [cell : i64
              (* 4 (shr line-flags compiler-backend-layout-flag-ops-shift))]
            (+=
              total
              (unsafe
                (ptr-read (ptr-offset refs cell))))
            (+=
              uncond
              (unsafe
                (ptr-read (ptr-offset refs (+ cell 1)))))
            (+=
              cold
              (unsafe
                (ptr-read (ptr-offset refs (+ cell 2)))))
            (+=
              hot
              (unsafe
                (ptr-read (ptr-offset refs (+ cell 3)))))
            unit))
        (unless
          (= (bit-and line-flags branch-bits) 0)
          (let
            [to : i64
              (unsafe
                (ptr-read (ptr-offset target k)))]
            (when
              (and (>= to rs) (< to re))
              (-= total 1)
              (cond
                [(not
                    (= (bit-and line-flags compiler-backend-layout-flag-jmp) 0))
                  (-= uncond 1)]
                [(=
                    (unsafe
                      (ptr-read (ptr-offset pred k)))
                    compiler-backend-layout-predict-cold)
                  (-= cold 1)]
                [(=
                    (unsafe
                      (ptr-read (ptr-offset pred k)))
                    compiler-backend-layout-predict-hot)
                  (-= hot 1)]
                [else unit]))))))
    (and
      (> total 0)
      (= uncond 0)
      (if sentinel?
        (= hot 0)
        (and
          (= cold total)
          (>= cold compiler-backend-layout-guard-chain-entries))))))

;; Choose the regions to lay out of line, walking the flow list rather than
;; every line. Accepted regions never overlap: a candidate whose `jmp` sits
;; inside one already taken is skipped, so each line moves at most once. An
;; accepted region is re-inserted at the first delimiting directive at or after
;; its join -- the first debug end label or closing directive of the function the join
;; belongs to -- found by advancing one cursor along the same flow list, which
;; is sound because the accepted joins only ever move forward. Returns the
;; number selected.
;; Collect the regions whose SHAPE admits out-of-lining: a forward `jmp` whose
;; target block starts right behind it, holds a real line, stays under the line
;; cap and carries no delimiting directive. Nothing here needs a prediction, so
;; a function without a single candidate never pays for one -- which is what
;; this phase is separated out for. The non-overlap guard is NOT applied here:
;; it turns on acceptance, which the second phase decides, and scanning a region
;; the guard will later drop costs a walk and changes no answer.
(define (compiler-backend-layout-collect-sink-shapes!
  [data : (Ptr u8)]
  [starts : (MutPtr i64)]
  [flags : (MutPtr i64)]
  [target : (MutPtr i64)]
  [flow : (MutPtr i64)]
  [flow-count : i64]
  [cand-p : (MutPtr i64)]
  [cand-q : (MutPtr i64)]
  [cand-shape : (MutPtr i64)]) : i64
  (let
    [count : i64 0]
    (for [k (iterator.range 0 flow-count)]
      (let
        [i : i64
          (unsafe
            (ptr-read (ptr-offset flow k)))]
        (unless
          (=
            (bit-and
              (unsafe
                (ptr-read (ptr-offset flags i)))
              compiler-backend-layout-flag-jmp)
            0)
          (let
            [q : i64
              (unsafe
                (ptr-read (ptr-offset target i)))]
            [rs : i64 (+ i 1)]
            (when
              (> q rs)
              (let
                [shape : i64
                  (compiler-backend-layout-region-scan data starts flags rs q)]
                (unless
                  (= (bit-and shape compiler-backend-layout-region-shape-ok) 0)
                  (unsafe
                    (ptr-write! (ptr-offset cand-p count) i))
                  (unsafe
                    (ptr-write! (ptr-offset cand-q count) q))
                  (unsafe
                    (ptr-write! (ptr-offset cand-shape count) shape))
                  (+= count 1))))))))
    count))

;; Emitted lines (labels and blanks aside) in a sunk region that is placed at
;; the nearest island rather than the function end. A slow-path stub (`call`)
;; or a sentinel arm (one or two constant moves) fits. A longer cold region
;; keeps the function end, so it does not lengthen the hot branches that would
;; span it.
(define compiler-backend-layout-island-line-cap : i64
  2)

(define (compiler-backend-layout-region-small?
  [flags : (MutPtr i64)]
  [rs : i64]
  [q : i64]) : bool
  (let
    [skip-bits : i64
      (bit-or
        compiler-backend-layout-flag-label
        compiler-backend-layout-flag-blank)]
    [count : i64 0]
    [i : i64 rs]
    (while (and (< i q) (<= count compiler-backend-layout-island-line-cap))
      (when
        (=
          (bit-and
            (unsafe
              (ptr-read (ptr-offset flags i)))
            skip-bits)
          0)
        (+= count 1))
      (+= i 1))
    (<= count compiler-backend-layout-island-line-cap)))

;; Does the `jmp` on line `u` reach the label run that starts at line `t`? The
;; fallthrough peephole deletes such a `jmp`; a region placed between the two
;; would keep it.
(define (compiler-backend-layout-jmp-into-labels?
  [flags : (MutPtr i64)]
  [target : (MutPtr i64)]
  [lines : i64]
  [u : i64]
  [t : i64]) : bool
  (let
    [dest : i64
      (unsafe
        (ptr-read (ptr-offset target u)))]
    [i : i64 t]
    [found : bool false]
    (while (and
      (not found)
      (< i lines)
      (not
        (=
          (bit-and
            (unsafe
              (ptr-read (ptr-offset flags i)))
            (bit-or
              compiler-backend-layout-flag-label
              compiler-backend-layout-flag-blank))
          0)))
      (when (= i dest) (set! found true))
      (+= i 1))
    found))

;; Is line `i` a `ret`? The line classifier flags `ret` only with an operand
;; or as `retq`, since a bare `ret` reads the zero past its line, so a bare one
;; is read from the text.
(define (compiler-backend-layout-ret-line?
  [data : (Ptr u8)]
  [starts : (MutPtr i64)]
  [flags : (MutPtr i64)]
  [i : i64]) : bool
  (or
    (not
      (=
        (bit-and
          (unsafe
            (ptr-read (ptr-offset flags i)))
          compiler-backend-layout-flag-ret)
        0))
    (let
      [e : i64
        (-
          (unsafe
            (ptr-read (ptr-offset starts (+ i 1))))
          1)]
      [t : i64
        (compiler-backend-layout-skip-spaces
          data
          (unsafe
            (ptr-read (ptr-offset starts i)))
          e)]
      (and
        (= (- e t) 3)
        (= (be_state.compiler-backend-peephole-byte-at data t) 114)
        (= (be_state.compiler-backend-peephole-byte-at data (+ t 1)) 101)
        (= (be_state.compiler-backend-peephole-byte-at data (+ t 2)) 116)))))

;; ISLAND PLACEMENT. A small sunk region goes in front of the first label after
;; its join that control cannot fall into: the line emitted before it is an
;; unconditional `jmp` (not one into that label run) or a `ret`, counted as the
;; text reads once every sunk region has left. Every branch into the region and
;; its jump back then spans a few blocks instead of the rest of the function,
;; which keeps most of them in the short encoding. No island before the
;; function end leaves the region there. `sink-class` records the choice: 1 for
;; an island, 0 for the function end. Islands only move forward with the
;; sinks, and so do function ends, so each class is placed by its own cursor.
(define (compiler-backend-layout-place-islands!
  [data : (Ptr u8)]
  [starts : (MutPtr i64)]
  [flags : (MutPtr i64)]
  [target : (MutPtr i64)]
  [lines : i64]
  [sinks : i64]
  [sink-p : (MutPtr i64)]
  [sink-q : (MutPtr i64)]
  [sink-tail : (MutPtr i64)]
  [sink-class : (MutPtr i64)]
  [dups : i64]
  [dup-p : (MutPtr i64)]
  [dup-to : (MutPtr i64)]) : unit
  (let
    [dup-start : i64 0]
    (for [k (iterator.range 0 sinks)]
      (let
        [p : i64
          (unsafe
            (ptr-read (ptr-offset sink-p k)))]
        [q : i64
          (unsafe
            (ptr-read (ptr-offset sink-q k)))]
        [tail : i64
          (unsafe
            (ptr-read (ptr-offset sink-tail k)))]
        (unsafe
          (ptr-write! (ptr-offset sink-class k) 0))
        (when
          (compiler-backend-layout-region-small? flags (+ p 1) q)
          (let
            ;; `prev` is the last line the text emits before line `i`, labels
            ;; and blanks aside, or -1 when that is a label (a label run is
            ;; one island). A `jmp` that is a duplication site is emitted as
            ;; its copied run, so the run's terminating `jmp` (`dup-to`) is
            ;; the one that must not reach the label run.
            [prev : i64 -1]
            [j : i64 (+ k 1)]
            [d : i64
              (begin
                (while (and
                  (< dup-start dups)
                  (<
                    (unsafe
                      (ptr-read (ptr-offset dup-p dup-start)))
                    q))
                  (+= dup-start 1))
                dup-start)]
            [i : i64 (+ q 1)]
            [done : bool false]
            (while (and (not done) (< i tail))
              (if (and
                (< j sinks)
                (=
                  i
                  (unsafe
                    (ptr-read (ptr-offset sink-p j)))))
                ;; A later sunk region leaves together with its `jmp`.
                (begin
                  (set!
                    i
                    (unsafe
                      (ptr-read (ptr-offset sink-q j))))
                  (+= j 1))
                (let
                  [line-flags : i64
                    (unsafe
                      (ptr-read (ptr-offset flags i)))]
                  (cond
                    [(not
                      (=
                        (bit-and line-flags compiler-backend-layout-flag-label)
                        0))
                      (when
                        (and
                          (>= prev 0)
                          (or
                            (compiler-backend-layout-ret-line?
                              data
                              starts
                              flags
                              prev)
                            (and
                              (not
                                (=
                                  (bit-and
                                    (unsafe
                                      (ptr-read (ptr-offset flags prev)))
                                    compiler-backend-layout-flag-jmp)
                                  0))
                              (not
                                (compiler-backend-layout-jmp-into-labels?
                                  flags
                                  target
                                  lines
                                  (begin
                                    (while (and
                                      (< d dups)
                                      (<
                                        (unsafe
                                          (ptr-read (ptr-offset dup-p d)))
                                        prev))
                                      (+= d 1))
                                    (if (and
                                      (< d dups)
                                      (=
                                        (unsafe
                                          (ptr-read (ptr-offset dup-p d)))
                                        prev))
                                      (unsafe
                                        (ptr-read (ptr-offset dup-to d)))
                                      prev))
                                  i)))))
                        (unsafe
                          (ptr-write! (ptr-offset sink-tail k) i))
                        (unsafe
                          (ptr-write! (ptr-offset sink-class k) 1))
                        (set! done true))
                      (set! prev -1)]
                    [(not
                        (=
                          (bit-and
                            line-flags
                            compiler-backend-layout-flag-blank)
                          0))
                      unit]
                    [else (set! prev i)])
                  (+= i 1))))))))))

;; Choose the regions to lay out of line from the shape candidates, in emission
;; order. Accepted regions never overlap: a candidate whose `jmp` sits inside
;; one already taken is skipped, so each line moves at most once. An accepted
;; region is re-inserted at the first delimiting directive at or after its join
;; -- the first debug end label or closing directive of the function the join belongs to
;; -- found by advancing one cursor along the flow list, which is sound because
;; the accepted joins only ever move forward. The candidate arrays are compacted
;; in place: the write index never runs ahead of the read index. Returns the
;; number selected.
(define (compiler-backend-layout-select-sinks!
  [flags : (MutPtr i64)]
  [target : (MutPtr i64)]
  [pred : (MutPtr i64)]
  [refs : (MutPtr i64)]
  [flow : (MutPtr i64)]
  [flow-count : i64]
  [lines : i64]
  [candidates : i64]
  [sink-p : (MutPtr i64)]
  [sink-q : (MutPtr i64)]
  [cand-shape : (MutPtr i64)]
  [sink-tail : (MutPtr i64)]
  [sink-jump : (MutPtr i64)]) : i64
  (let
    [count : i64 0]
    [guard : i64 0]
    [tail-cursor : i64 0]
    (for [k (iterator.range 0 candidates)]
      (let
        [i : i64
          (unsafe
            (ptr-read (ptr-offset sink-p k)))]
        [q : i64
          (unsafe
            (ptr-read (ptr-offset sink-q k)))]
        [shape : i64
          (unsafe
            (ptr-read (ptr-offset cand-shape k)))]
        [rs : i64 (+ i 1)]
        (when
          (and
            (>= i guard)
            (or
              (compiler-backend-layout-region-cold?
                flags
                target
                pred
                refs
                rs
                q
                false)
              (and
                (not
                  (= (bit-and shape compiler-backend-layout-region-sentinel) 0))
                (compiler-backend-layout-region-cold?
                  flags
                  target
                  pred
                  refs
                  rs
                  q
                  true))))
          (while (and
            (< tail-cursor flow-count)
            (or
              (<
                (unsafe
                  (ptr-read (ptr-offset flow tail-cursor)))
                q)
              (=
                (bit-and
                  (unsafe
                    (ptr-read
                      (ptr-offset
                        flags
                        (unsafe
                          (ptr-read (ptr-offset flow tail-cursor))))))
                  compiler-backend-layout-flag-barrier)
                0)))
            (+= tail-cursor 1))
          (unsafe
            (ptr-write! (ptr-offset sink-p count) i))
          (unsafe
            (ptr-write! (ptr-offset sink-q count) q))
          (unsafe
            (ptr-write!
              (ptr-offset sink-tail count)
              (if (< tail-cursor flow-count)
                (unsafe
                  (ptr-read (ptr-offset flow tail-cursor)))
                lines)))
          (unsafe
            (ptr-write!
              (ptr-offset sink-jump count)
              (if (=
                (bit-and shape compiler-backend-layout-region-needs-jump)
                0)
                0
                1)))
          (+= count 1)
          (set! guard q))))
    count))

;; The straight-line run a `jmp L` may absorb: the instructions from L onward,
;; label definitions skipped (the copy defines none), up to and including the
;; first unconditional `jmp`. Returns that terminator's line, or -1 when the run
;; is too long or holds anything a copy must not carry.
(define (compiler-backend-layout-dup-run-end
  [flags : (MutPtr i64)]
  [lines : i64]
  [site : i64]
  [label : i64]) : i64
  (let
    [refuse-bits : i64
      (bit-or
        compiler-backend-layout-flag-blank
        (bit-or
          compiler-backend-layout-flag-directive
          (bit-or
            compiler-backend-layout-flag-call
            (bit-or
              compiler-backend-layout-flag-ret
              compiler-backend-layout-flag-stack))))]
    [k : i64 (+ label 1)]
    [taken : i64 0]
    [term : i64 -1]
    [failed : bool false]
    (while (and (not failed) (< term 0) (< k lines))
      (let
        [line-flags : i64
          (unsafe
            (ptr-read (ptr-offset flags k)))]
        (cond
          [(not (= (bit-and line-flags compiler-backend-layout-flag-label) 0))
            (+= k 1)]
          [(or (= k site) (not (= (bit-and line-flags refuse-bits) 0)))
            (set! failed true)]
          [else
            (+= taken 1)
            (if (> taken compiler-backend-layout-dup-run-cap)
              (set! failed true)
              (if (= (bit-and line-flags compiler-backend-layout-flag-jmp) 0)
                (+= k 1)
                (set! term k)))])))
    (if failed
      -1
      term)))

;; Is the target already where execution would arrive by falling through nothing
;; but label definitions? Then the `jmp` is not a jump at all -- the assembled
;; peephole deletes it outright -- and copying a run over it would replace a
;; free edge with real instructions.
(define (compiler-backend-layout-fallthrough-target?
  [flags : (MutPtr i64)]
  [site : i64]
  [label : i64]) : bool
  (if (< label site)
    false
    (let
      [skip-bits : i64
        (bit-or
          compiler-backend-layout-flag-label
          compiler-backend-layout-flag-blank)]
      [k : i64 (+ site 1)]
      [only-labels : bool true]
      (while (and only-labels (< k label))
        (when
          (=
            (bit-and
              (unsafe
                (ptr-read (ptr-offset flags k)))
              skip-bits)
            0)
          (set! only-labels false))
        (+= k 1))
      only-labels)))

;; Is the line before this site a call that never returns? The `jmp` behind an
;; abort call is dead text; copying a run into it only grows the function.
(define (compiler-backend-layout-after-abort?
  [data : (Ptr u8)]
  [starts : (MutPtr i64)]
  [flags : (MutPtr i64)]
  [i : i64]) : bool
  (let
    [skip-bits : i64
      (bit-or
        compiler-backend-layout-flag-label
        compiler-backend-layout-flag-blank)]
    [j : i64 (- i 1)]
    [done : bool false]
    (while (and (not done) (>= j 0))
      (if (=
        (bit-and
          (unsafe
            (ptr-read (ptr-offset flags j)))
          skip-bits)
        0)
        (set! done true)
        (-= j 1)))
    (and
      (>= j 0)
      (not
        (=
          (bit-and
            (unsafe
              (ptr-read (ptr-offset flags j)))
            compiler-backend-layout-flag-call)
          0))
      (compiler-backend-layout-abort-line?
        data
        (unsafe
          (ptr-read (ptr-offset starts j)))
        (-
          (unsafe
            (ptr-read (ptr-offset starts (+ j 1))))
          1)))))

;; Choose the duplication sites, again over the flow list. A `jmp` inside a
;; region already chosen for out-of-lining is left alone, so the two mechanisms
;; never rewrite the same line. Returns the number selected.
(define (compiler-backend-layout-select-dups!
  [data : (Ptr u8)]
  [starts : (MutPtr i64)]
  [flags : (MutPtr i64)]
  [target : (MutPtr i64)]
  [flow : (MutPtr i64)]
  [flow-count : i64]
  [lines : i64]
  [sink-p : (MutPtr i64)]
  [sink-q : (MutPtr i64)]
  [sinks : i64]
  [dup-p : (MutPtr i64)]
  [dup-from : (MutPtr i64)]
  [dup-to : (MutPtr i64)]) : i64
  (let
    [count : i64 0]
    [cursor : i64 0]
    (for [k (iterator.range 0 flow-count)]
      (let
        [i : i64
          (unsafe
            (ptr-read (ptr-offset flow k)))]
        (unless
          (=
            (bit-and
              (unsafe
                (ptr-read (ptr-offset flags i)))
              compiler-backend-layout-flag-jmp)
            0)
          (while (and
            (< cursor sinks)
            (<
              (unsafe
                (ptr-read (ptr-offset sink-q cursor)))
              i))
            (+= cursor 1))
          (unless
            (and
              (< cursor sinks)
              (>=
                i
                (unsafe
                  (ptr-read (ptr-offset sink-p cursor))))
              (<
                i
                (unsafe
                  (ptr-read (ptr-offset sink-q cursor)))))
            (let
              [label : i64
                (unsafe
                  (ptr-read (ptr-offset target i)))]
              (when
                (>= label 0)
                (let
                  [term : i64
                    (compiler-backend-layout-dup-run-end flags lines i label)]
                  (when
                    (and
                      (>= term 0)
                      (not
                        (compiler-backend-layout-fallthrough-target?
                          flags
                          i
                          label))
                      (not
                        (compiler-backend-layout-after-abort?
                          data
                          starts
                          flags
                          i)))
                    (unsafe
                      (ptr-write! (ptr-offset dup-p count) i))
                    (unsafe
                      (ptr-write! (ptr-offset dup-from count) (+ label 1)))
                    (unsafe
                      (ptr-write! (ptr-offset dup-to count) term))
                    (+= count 1)))))))))
    count))

;; Append sunk region `k` to the plan at `len`: its lines after the `jmp`, then
;; the `jmp` itself when the region needs a jump back to its join. Returns the
;; new length.
(define (compiler-backend-layout-plan-region!
  [sink-p : (MutPtr i64)]
  [sink-q : (MutPtr i64)]
  [sink-jump : (MutPtr i64)]
  [k : i64]
  [plan : (MutPtr i64)]
  [len : i64]) : i64
  (let
    [p : i64
      (unsafe
        (ptr-read (ptr-offset sink-p k)))]
    [q : i64
      (unsafe
        (ptr-read (ptr-offset sink-q k)))]
    [out : i64 len]
    (for [line (iterator.range (+ p 1) q)]
      (unsafe
        (ptr-write! (ptr-offset plan out) line))
      (+= out 1))
    (when
      (=
        (unsafe
          (ptr-read (ptr-offset sink-jump k)))
        1)
      (unsafe
        (ptr-write! (ptr-offset plan out) p))
      (+= out 1))
    out))

;; The next sink at or after `k` whose `sink-class` is `class`, or `sinks`.
(define (compiler-backend-layout-next-of-class
  [sink-class : (MutPtr i64)]
  [sinks : i64]
  [k : i64]
  [class : i64]) : i64
  (let
    [i : i64 k]
    (while (and
      (< i sinks)
      (not
        (=
          (unsafe
            (ptr-read (ptr-offset sink-class i)))
          class)))
      (+= i 1))
    i))

;; The output as a sequence of source lines: every entry names a line of the
;; input, so a duplicated run is that run's lines listed twice and an
;; out-of-lined region is its lines listed at the insertion point instead of
;; where they stood. The jump appended behind a moved region is the very `jmp T`
;; line the move deleted, so no text is ever synthesized. A sunk region leaves
;; its place with its `jmp` and is emitted in front of its tail line. Island tails and
;; function-end tails each rise with the sinks (`place-islands!`), so one
;; cursor per class finds every region whose tail is the current line, and a
;; region is always emitted after its own `jmp` was skipped.
(define (compiler-backend-layout-build-plan
  [flags : (MutPtr i64)]
  [lines : i64]
  [sink-p : (MutPtr i64)]
  [sink-q : (MutPtr i64)]
  [sink-tail : (MutPtr i64)]
  [sink-jump : (MutPtr i64)]
  [sink-class : (MutPtr i64)]
  [sinks : i64]
  [dup-p : (MutPtr i64)]
  [dup-from : (MutPtr i64)]
  [dup-to : (MutPtr i64)]
  [dups : i64]
  [plan : (MutPtr i64)]) : i64
  (let
    [skip-bits : i64
      (bit-or
        compiler-backend-layout-flag-label
        compiler-backend-layout-flag-blank)]
    [len : i64 0]
    [skipped : i64 0]
    [island : i64 (compiler-backend-layout-next-of-class sink-class sinks 0 1)]
    [ending : i64 (compiler-backend-layout-next-of-class sink-class sinks 0 0)]
    [di : i64 0]
    [i : i64 0]
    (while (< i lines)
      (while (and
        (< island skipped)
        (=
          (unsafe
            (ptr-read (ptr-offset sink-tail island)))
          i))
        (set!
          len
          (compiler-backend-layout-plan-region!
            sink-p
            sink-q
            sink-jump
            island
            plan
            len))
        (set!
          island
          (compiler-backend-layout-next-of-class
            sink-class
            sinks
            (+ island 1)
            1)))
      (while (and
        (< ending skipped)
        (=
          (unsafe
            (ptr-read (ptr-offset sink-tail ending)))
          i))
        (set!
          len
          (compiler-backend-layout-plan-region!
            sink-p
            sink-q
            sink-jump
            ending
            plan
            len))
        (set!
          ending
          (compiler-backend-layout-next-of-class
            sink-class
            sinks
            (+ ending 1)
            0)))
      (cond
        [(and
          (< skipped sinks)
          (=
            i
            (unsafe
              (ptr-read (ptr-offset sink-p skipped)))))
          (set!
            i
            (unsafe
              (ptr-read (ptr-offset sink-q skipped))))
          (+= skipped 1)]
        [(and
            (< di dups)
            (=
              i
              (unsafe
                (ptr-read (ptr-offset dup-p di)))))
          (let
            [stop : i64
              (unsafe
                (ptr-read (ptr-offset dup-to di)))]
            (for [k
              (iterator.range
                (unsafe
                  (ptr-read (ptr-offset dup-from di)))
                (+ stop 1))]
              (when
                (=
                  (bit-and
                    (unsafe
                      (ptr-read (ptr-offset flags k)))
                    skip-bits)
                  0)
                (unsafe
                  (ptr-write! (ptr-offset plan len) k))
                (+= len 1)))
            (+= di 1)
            (+= i 1))]
        [else
          (unsafe
            (ptr-write! (ptr-offset plan len) i))
          (+= len 1)
          (+= i 1)]))
    ;; Regions whose tail is the end of the text, in emission order. Each
    ;; cursor stops only at its own class, so a sink is unplaced exactly when
    ;; it lies at or after its class's cursor.
    (for [k
      (iterator.range
        (if (< island ending)
          island
          ending)
        sinks)]
      (when
        (if (=
          (unsafe
            (ptr-read (ptr-offset sink-class k)))
          1)
          (>= k island)
          (>= k ending))
        (set!
          len
          (compiler-backend-layout-plan-region!
            sink-p
            sink-q
            sink-jump
            k
            plan
            len))))
    len))

;; The analysis proper. Everything here is scratch except the two words the plan
;; carries out: `starts`, which the caller's line walk reads instead of
;; splitting the text a second time, and `plan` itself. `len` = 0 means neither
;; mechanism fired and the caller walks the lines in order. With `layout?` off
;; -- the bare peephole the unit tests exercise -- only the line split runs.
(define (compiler-backend-layout-analyze
  [asm : (& asm str)]
  [n : i64]
  [mode : i64]
  [layout? : bool]) : CompilerBackendLayoutPlan
  (let
    [data : (Ptr u8)
      (unsafe
        (string-data asm))]
    [classify? : bool
      (and
        layout?
        (> n 0)
        (= (be_state.compiler-backend-peephole-byte-at data (- n 1)) 10))]
    [cap : i64 (compiler-backend-layout-line-capacity n)]
    [list-cap : i64
      (if classify?
        cap
        0)]
    [counts : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [starts : (__tl_dyn-array i64) (__tl_make-array i64 (+ cap 1))]
    [flags : (__tl_dyn-array i64) (__tl_make-array i64 list-cap)]
    [labels : (__tl_dyn-array i64) (__tl_make-array i64 list-cap)]
    [flow : (__tl_dyn-array i64) (__tl_make-array i64 list-cap)]
    [lines : i64
      (compiler-backend-layout-split-lines
        data
        n
        cap
        (unsafe
          (__tl_array-data starts)))]
    ;; The estimate is generous for emitted assembly; a text that beats it is
    ;; served by doubling and splitting again. This second call site is also
    ;; what keeps the split OUT of line: absorbed into this function it lost
    ;; its SWAR constants to the register pressure of everything below.
    (while (< lines 0)
      (set! cap (* 2 cap))
      (set!
        list-cap
        (if classify?
          cap
          0))
      (set! starts (__tl_make-array i64 (+ cap 1)))
      (set! flags (__tl_make-array i64 list-cap))
      (set! labels (__tl_make-array i64 list-cap))
      (set! flow (__tl_make-array i64 list-cap))
      (set!
        lines
        (compiler-backend-layout-split-lines
          data
          n
          cap
          (unsafe
            (__tl_array-data starts)))))
    (when
      classify?
      (let
        [flags-out : (MutPtr i64)
          (unsafe
            (__tl_array-data flags))]
        (compiler-backend-layout-classify-lines!
          data
          lines
          (unsafe
            (__tl_array-data starts))
          flags-out)
        (compiler-backend-layout-list-lines!
          lines
          flags-out
          (unsafe
            (__tl_array-data labels))
          (unsafe
            (__tl_array-data flow))
          (&mut counts))))
    (let
      [jumps : i64
        (if classify?
          (array-ref counts 2)
          0)]
      (if (= jumps 0)
        (CompilerBackendLayoutPlan starts (__tl_make-array i64 0) lines 0)
        (let
          [label-count : i64 (array-ref counts 0)]
          [flow-count : i64 (array-ref counts 1)]
          [table-cap : i64 (compiler-backend-layout-table-capacity label-count)]
          [table : (__tl_dyn-array i64) (__tl_make-array i64 (* 2 table-cap))]
          [target : (__tl_dyn-array i64) (__tl_make-array i64 lines)]
          [pred : (__tl_dyn-array i64) (__tl_make-array i64 lines)]
          [refs : (__tl_dyn-array i64)
            (__tl_make-array i64 (* 4 (+ label-count 1)))]
          ;; One allocation for the eight per-`jmp` site columns.
          [sites : (__tl_dyn-array i64) (__tl_make-array i64 (* 8 jumps))]
          [sites-raw : (MutPtr i64)
            (unsafe
              (__tl_array-data sites))]
          [sink-p-raw : (MutPtr i64) sites-raw]
          [sink-q-raw : (MutPtr i64)
            (unsafe
              (ptr-offset sites-raw jumps))]
          [cand-shape-raw : (MutPtr i64)
            (unsafe
              (ptr-offset sites-raw (* 2 jumps)))]
          [sink-tail-raw : (MutPtr i64)
            (unsafe
              (ptr-offset sites-raw (* 3 jumps)))]
          [sink-jump-raw : (MutPtr i64)
            (unsafe
              (ptr-offset sites-raw (* 4 jumps)))]
          [dup-p-raw : (MutPtr i64)
            (unsafe
              (ptr-offset sites-raw (* 5 jumps)))]
          [dup-from-raw : (MutPtr i64)
            (unsafe
              (ptr-offset sites-raw (* 6 jumps)))]
          [dup-to-raw : (MutPtr i64)
            (unsafe
              (ptr-offset sites-raw (* 7 jumps)))]
          [starts-raw : (MutPtr i64)
            (unsafe
              (__tl_array-data starts))]
          [flags-raw : (MutPtr i64)
            (unsafe
              (__tl_array-data flags))]
          [flow-raw : (MutPtr i64)
            (unsafe
              (__tl_array-data flow))]
          [target-raw : (MutPtr i64)
            (unsafe
              (__tl_array-data target))]
          [pred-raw : (MutPtr i64)
            (unsafe
              (__tl_array-data pred))]
          [refs-raw : (MutPtr i64)
            (unsafe
              (__tl_array-data refs))]
          [table-raw : (MutPtr i64)
            (unsafe
              (__tl_array-data table))]
          [_table : unit
            (compiler-backend-layout-build-table!
              data
              starts-raw
              (unsafe
                (__tl_array-data labels))
              label-count
              table-raw
              table-cap)]
          [_resolve : unit
            (compiler-backend-layout-resolve-targets!
              data
              starts-raw
              flags-raw
              flow-raw
              flow-count
              compiler-backend-layout-flag-jmp
              target-raw
              table-raw
              table-cap)]
          [candidates : i64
            (if (compiler-backend-layout-flag?
              mode
              compiler-backend-layout-mode-sink)
              (compiler-backend-layout-collect-sink-shapes!
                data
                starts-raw
                flags-raw
                target-raw
                flow-raw
                flow-count
                sink-p-raw
                sink-q-raw
                cand-shape-raw)
              0)]
          ;; The prediction and the conditional branches' targets feed
          ;; nothing but the coldness test, so a function whose shapes all
          ;; failed never runs either.
          [_resolve-jcc : unit
            (if (> candidates 0)
              (compiler-backend-layout-resolve-targets!
                data
                starts-raw
                flags-raw
                flow-raw
                flow-count
                compiler-backend-layout-flag-jcc
                target-raw
                table-raw
                table-cap)
              unit)]
          [_predict : unit
            (if (> candidates 0)
              (compiler-backend-layout-predict-and-tally!
                data
                starts-raw
                flags-raw
                target-raw
                pred-raw
                refs-raw
                flow-raw
                flow-count)
              unit)]
          [sinks : i64
            (if (> candidates 0)
              (compiler-backend-layout-select-sinks!
                flags-raw
                target-raw
                pred-raw
                refs-raw
                flow-raw
                flow-count
                lines
                candidates
                sink-p-raw
                sink-q-raw
                cand-shape-raw
                sink-tail-raw
                sink-jump-raw)
              0)]
          [dups : i64
            (if (compiler-backend-layout-flag?
              mode
              compiler-backend-layout-mode-dup)
              (compiler-backend-layout-select-dups!
                data
                starts-raw
                flags-raw
                target-raw
                flow-raw
                flow-count
                lines
                sink-p-raw
                sink-q-raw
                sinks
                dup-p-raw
                dup-from-raw
                dup-to-raw)
              0)]
          ;; `cand-shape` is spent once the sinks are chosen; it carries each
          ;; sink's placement class from here on. Islands are chosen last
          ;; because a duplication site changes which `jmp` precedes one.
          [sink-class-raw : (MutPtr i64) cand-shape-raw]
          [_islands : unit
            (compiler-backend-layout-place-islands!
              data
              starts-raw
              flags-raw
              target-raw
              lines
              sinks
              sink-p-raw
              sink-q-raw
              sink-tail-raw
              sink-class-raw
              dups
              dup-p-raw
              dup-to-raw)]
          (if (and (= sinks 0) (= dups 0))
            (CompilerBackendLayoutPlan starts (__tl_make-array i64 0) lines 0)
            (let
              [plan : (__tl_dyn-array i64)
                (__tl_make-array
                  i64
                  (+
                    lines
                    (+ (* dups compiler-backend-layout-dup-run-cap) (+ sinks 4))))]
              [len : i64
                (compiler-backend-layout-build-plan
                  flags-raw
                  lines
                  sink-p-raw
                  sink-q-raw
                  sink-tail-raw
                  sink-jump-raw
                  sink-class-raw
                  sinks
                  dup-p-raw
                  dup-from-raw
                  dup-to-raw
                  dups
                  (unsafe
                    (__tl_array-data plan)))]
              (CompilerBackendLayoutPlan starts plan lines len))))))))

;; Streaming peephole over line RECORDS: each surviving emit step pushes its
;; record into a dense arena-backed array instead of appending bytes. The array
;; is the pipeline: the dead-store sweep consumes it and the group is rendered
;; exactly once, afterwards.
;;
;; The walk runs over the group's physical chunks, parsing each in place; a
;; record's `src` is the chunk its line came from. Chunk boundaries are NOT
;; pass boundaries: `pending`, the owner map and `prev-abort?` all carry across
;; them, so a pair whose two lines sit in different chunks still forms exactly
;; as it would in one flattened text.
;;
;; With `drop-fallthrough?` the fallthrough-`jmp` deletion runs in this same
;; walk (one .globl unit per group). At most one candidate direct `jmp`
;; is deferred at a time: its descriptor and target operand range are held,
;; and the label-definition lines seen since are buffered unprocessed. A
;; buffered label matching the held target deletes the `jmp` -- it never
;; reaches emit-line-desc-record, so the owner map and prev-abort? evolve
;; exactly as if the line were absent -- and the buffered labels are replayed
;; through the ordinary rule set. Any other line keeps the `jmp`: it is
;; emitted before the buffered labels, in its original record position. A
;; candidate still held at group end is kept and emitted like ordinary
;; pending. Intervening label definitions never pair (not movq/zext), and a held
;; `jmp` is neither a guard-ok branch (desc-guard-ok-branch? excludes jmp)
;; nor a guard-ok label, so the held emit and the replay need no guard-owner
;; snapshot handling.
(define (compiler-backend-peephole-held-labels-push
  [labels : (__tl_dyn-array be_state.CompilerBackendPeepholeLine)]
  [count : i64]
  [line : be_state.CompilerBackendPeepholeLine]) : (__tl_dyn-array
    be_state.CompilerBackendPeepholeLine)
  (if (< count (array-length labels))
    (begin
      (set! (array-ref labels count) line)
      labels)
    (let
      [bigger : (__tl_dyn-array be_state.CompilerBackendPeepholeLine)
        (__tl_make-array
          be_state.CompilerBackendPeepholeLine
          (* 2 (array-length labels)))]
      (for [j (iterator.range 0 count)]
        (set!
          (array-ref bigger j)
          (owned_view.compiler-owned-element-view labels j)))
      (set! (array-ref bigger count) line)
      bigger)))

(define (compiler-backend-peephole-asm-once-records-chunks
  [backend-state : be_state.CompilerBackendState]
  [stream : be_state.CompilerBackendStreamState]
  [chunks : be_state.CompilerBackendPeepholeChunkArray]
  [drop-fallthrough? : bool]) : be_state.CompilerBackendPeepholeLineVec
  (let
    [items : (__tl_dyn-array String)
      (be_state.compiler-backend-global-shared-view chunks.items)]
    [chunk-count : i64 chunks.count]
    [sink-capacity : i64
      (compiler-backend-peephole-line-vec-capacity-for chunks.total)]
    [stream-data : (Ptr be_state.CompilerBackendStreamStateData)
      (be_state.compiler-backend-stream-state-view stream)]
    [carry-safe : be_state.CompilerBackendPeepholeCarrySafeView
      (be_state.CompilerBackendPeepholeCarrySafeView
        (unsafe
          (deref stream-data).carry-safe-offsets)
        (unsafe
          (deref stream-data).carry-safe-lengths)
        (unsafe
          (deref stream-data).carry-safe-bytes))]
    [walk : CompilerBackendPeepholeWalkState
      (CompilerBackendPeepholeWalkState
        backend-state.address
        stream.address
        carry-safe
        (__tl_make-array
          be_state.CompilerBackendPeepholeLineRecord
          sink-capacity)
        (__tl_make-array i64 sink-capacity)
        0
        (__tl_make-array i64 0)
        0
        (__tl_make-array i64 0)
        0
        (__tl_make-array i64 0)
        0
        (- 0 1)
        (__tl_make-array i64 0)
        0
        (__tl_make-array i64 0)
        0)]
    [_walk-open : unit
      (compiler-backend-peephole-records-publish!
        (be_state.compiler-backend-global-shared-view walk))]
    [has-pending : bool false]
    [pending : be_state.CompilerBackendPeepholeLine
      (compiler-backend-peephole-empty-line)]
    ;; SCAV2: was the last EMITTED line a noreturn abort call?
    [prev-abort? : bool false]
    [owners : be_state.CompilerBackendPeepholeOwners
      (compiler-backend-peephole-owners-empty)]
    [guard-owners-active? : bool false]
    [guard-owners : be_state.CompilerBackendPeepholeOwners
      (compiler-backend-peephole-owners-empty)]
    [held-jmp? : bool false]
    [held-line : be_state.CompilerBackendPeepholeLine
      (compiler-backend-peephole-empty-line)]
    [held-target-start : i64 0]
    [held-target-stop : i64 0]
    [held-labels : (__tl_dyn-array be_state.CompilerBackendPeepholeLine)
      (__tl_make-array be_state.CompilerBackendPeepholeLine 8)]
    [held-label-count : i64 0]
    ;; The parser returns its memory-class descriptor through a callsite-owned
    ;; result slot. Alternate between two distinct callsites only when pending
    ;; takes the current descriptor: if a pair rule drops the current line,
    ;; reuse that now-dead slot while pending remains in the other one. This is
    ;; the two-slot streaming discipline used by production parser pipelines;
    ;; it keeps pending stable without materializing another 96-byte copy.
    [parse-slot-b? : bool false]
    (compiler-backend-peephole-owner-global-reset-with-backend-state!
      backend-state
      stream)
    (for [c (iterator.range 0 chunk-count)]
      (let
        [asm : String
          (be_state.compiler-backend-global-array-element-shared-view items c)]
        [n : i64 (string.string-length asm)]
        [asm-data : (Ptr u8)
          (unsafe
            (string-data asm))]
        [context : be_state.CompilerBackendPeepholeParseContext
          (be_state.CompilerBackendPeepholeParseContext
            backend-state.address
            stream.address
            asm-data)]
        ;; #block-layout: split and classify this chunk once. `starts` is the
        ;; line split the walk below would have performed anyway, and `plan`
        ;; -- when either rewrite fired -- is the order the walk visits those
        ;; lines in, which is exactly the text the standalone entry would have
        ;; rendered and re-parsed.
        [laid-out : CompilerBackendLayoutPlan
          (compiler-backend-layout-analyze
            asm
            n
            compiler-backend-layout-mode
            drop-fallthrough?)]
        [lay-starts : (MutPtr i64)
          (unsafe
            (__tl_array-data laid-out.starts))]
        [lay-plan : (MutPtr i64)
          (unsafe
            (__tl_array-data laid-out.plan))]
        [lay-len : i64 laid-out.len]
        [steps : i64
          (if (= lay-len 0)
            laid-out.lines
            lay-len)]
        (for [step (iterator.range 0 steps)]
          (let
            ;; The line ends at its newline, or at the chunk end.
            [source-line : i64
              (if (= lay-len 0)
                step
                (unsafe
                  (ptr-read (ptr-offset lay-plan step))))]
            [i : i64
              (unsafe
                (ptr-read (ptr-offset lay-starts source-line)))]
            [end : i64
              (-
                (unsafe
                  (ptr-read (ptr-offset lay-starts (+ source-line 1))))
                1)]
            [line-newline : bool (< end n)]
            [line : be_state.CompilerBackendPeepholeLine
              (if parse-slot-b?
                (compiler-backend-peephole-parse-line
                  context
                  (be_state.compiler-backend-global-shared-view asm)
                  i
                  end
                  line-newline
                  false)
                (compiler-backend-peephole-parse-line
                  context
                  (be_state.compiler-backend-global-shared-view asm)
                  i
                  end
                  line-newline
                  false))]
            [consumed? : bool false]
            (if held-jmp?
              (if (compiler-backend-asm-label-def-line? asm-data i end)
                (if (be_operand.compiler-backend-peephole-ranges-eq?
                  held-line.data
                  held-target-start
                  held-target-stop
                  asm-data
                  i
                  (- end 1))
                  ;; Target reached across label definitions only: the
                  ;; `jmp` is deleted (never emitted, so the owner map
                  ;; and prev-abort? evolve exactly as if it were
                  ;; absent); the buffered labels replay below.
                  (begin
                    (set! held-jmp? false)
                    (set! has-pending false))
                  ;; Not the target: candidacy stays alive; buffer the
                  ;; label and take no further action on it.
                  (begin
                    (set!
                      held-labels
                      (compiler-backend-peephole-held-labels-push
                        held-labels
                        held-label-count
                        (be_state.compiler-backend-global-shared-view line)))
                    (+= held-label-count 1)
                    (set! consumed? true)))
                ;; Emitted bytes intervene: the `jmp` stays. Emit it
                ;; before the buffered labels (replayed below), then
                ;; let the ordinary walk process this line.
                (begin
                  (set!
                    owners
                    (compiler-backend-peephole-emit-line-desc-record
                      walk
                      (be_state.compiler-backend-global-shared-view held-line)
                      owners
                      prev-abort?))
                  (set!
                    prev-abort?
                    (compiler-backend-peephole-desc-noreturn-abort? held-line))
                  (set! held-jmp? false)
                  (set! has-pending false)))
              unit)
            (if (and (not held-jmp?) (> held-label-count 0))
              ;; Replay the buffered label definitions through the
              ;; ordinary emit rule; labels never pair, never snapshot
              ;; guard owners and are never abort calls.
              (begin
                (set!
                  pending
                  (compiler-backend-peephole-line-copy
                    (be_state.compiler-backend-global-array-element-shared-view
                      held-labels
                      0)))
                (set! has-pending true)
                (for [replay-j (iterator.range 1 held-label-count)]
                  (let
                    [restore-guard-owners? : bool
                      (and
                        guard-owners-active?
                        (compiler-backend-peephole-desc-guard-ok-label? pending))]
                    [emit : be_state.CompilerBackendPeepholeOwners
                      (compiler-backend-peephole-emit-line-desc-record
                        walk
                        (be_state.compiler-backend-global-shared-view pending)
                        (if restore-guard-owners?
                          (compiler-backend-peephole-owners-copy guard-owners)
                          owners)
                        (or prev-abort? restore-guard-owners?))]
                    (set! owners emit)
                    (when
                      restore-guard-owners?
                      (set! guard-owners-active? false))
                    (set!
                      prev-abort?
                      (compiler-backend-peephole-desc-noreturn-abort? pending))
                    (set!
                      pending
                      (compiler-backend-peephole-line-copy
                        (be_state.compiler-backend-global-array-element-shared-view
                          held-labels
                          replay-j)))))
                (set! held-label-count 0))
              unit)
            (unless
              consumed?
              (if has-pending
                (let
                  [action : i64
                    (compiler-backend-peephole-pair-action-desc
                      (& walk)
                      chunks
                      c
                      (be_state.compiler-backend-global-shared-view pending)
                      (be_state.compiler-backend-global-shared-view line))]
                  (cond
                    [(= action 1)
                      (set! pending line)
                      (set! parse-slot-b? (not parse-slot-b?))]
                    [(= action 2) unit]
                    [(= action 3)
                      (let
                        [forwarded-line : String
                          (compiler-backend-peephole-forward-frame-load-line-desc
                            (be_state.compiler-backend-global-shared-view
                              pending)
                            line)]
                        (set!
                          owners
                          (compiler-backend-peephole-emit-line-desc-record
                            walk
                            (be_state.compiler-backend-global-shared-view
                              pending)
                            owners
                            prev-abort?))
                        (set!
                          prev-abort?
                          (compiler-backend-peephole-desc-noreturn-abort?
                            pending))
                        (set!
                          pending
                          (compiler-backend-peephole-owned-line
                            backend-state
                            stream
                            forwarded-line
                            line-newline)))]
                    [(= action 4)
                      (let
                        [folded-line : String
                          (compiler-backend-peephole-r10-base-fold-line-desc
                            (be_state.compiler-backend-global-shared-view
                              pending)
                            line)]
                        (set!
                          pending
                          (compiler-backend-peephole-owned-line
                            backend-state
                            stream
                            folded-line
                            line-newline)))]
                    ;; FLAGS-1: the `test` is dropped and the branch,
                    ;; respelled where it must be, takes its place as
                    ;; the pending line.
                    [(= action 5)
                      (let
                        [fused-line : String
                          (compiler-backend-peephole-flags-branch-line-desc
                            line)]
                        (set!
                          pending
                          (compiler-backend-peephole-owned-line
                            backend-state
                            stream
                            fused-line
                            line-newline)))]
                    [else
                      (let
                        [restore-guard-owners? : bool
                          (and
                            guard-owners-active?
                            (compiler-backend-peephole-desc-guard-ok-label?
                              pending))]
                        [emit : be_state.CompilerBackendPeepholeOwners
                          (compiler-backend-peephole-emit-line-desc-record
                            walk
                            (be_state.compiler-backend-global-shared-view
                              pending)
                            (if restore-guard-owners?
                              (compiler-backend-peephole-owners-copy
                                guard-owners)
                              owners)
                            (or prev-abort? restore-guard-owners?))]
                        (set! owners emit)
                        (when
                          restore-guard-owners?
                          (set! guard-owners-active? false))
                        (when
                          (and
                            (compiler-backend-peephole-desc-pushq? line)
                            (compiler-backend-peephole-desc-guard-ok-branch?
                              pending))
                          (set!
                            guard-owners
                            (compiler-backend-peephole-owners-copy owners))
                          (set! guard-owners-active? true))
                        (set!
                          prev-abort?
                          (compiler-backend-peephole-desc-noreturn-abort?
                            pending))
                        (set!
                          pending
                          (be_state.compiler-backend-global-shared-view line))
                        (set! parse-slot-b? (not parse-slot-b?)))]))
                (begin
                  (set! has-pending true)
                  (set! pending line)
                  (set! parse-slot-b? (not parse-slot-b?))))
              (when
                (and
                  drop-fallthrough?
                  (= (compiler-backend-peephole-desc-mnemonic-len pending) 3)
                  (compiler-backend-asm-direct-jmp-line?
                    pending.data
                    (compiler-backend-peephole-desc-start pending)
                    (compiler-backend-peephole-desc-end pending)))
                (set! held-jmp? true)
                (set!
                  held-line
                  (compiler-backend-peephole-line-copy
                    (be_state.compiler-backend-global-shared-view pending)))
                (set!
                  held-target-start
                  (+
                    (compiler-backend-peephole-desc-start pending)
                    (compiler-backend-asm-jmp-prefix-len)))
                (set!
                  held-target-stop
                  (compiler-backend-peephole-desc-end pending))))))))
    (when
      held-jmp?
      ;; Group end with a candidate still deferred: keep it, emitting it
      ;; before any buffered labels, like ordinary pending.
      (set!
        owners
        (compiler-backend-peephole-emit-line-desc-record
          walk
          (be_state.compiler-backend-global-shared-view held-line)
          owners
          prev-abort?))
      (set!
        prev-abort?
        (compiler-backend-peephole-desc-noreturn-abort? held-line))
      (set! has-pending false)
      (if (> held-label-count 0)
        (begin
          (set!
            pending
            (compiler-backend-peephole-line-copy
              (be_state.compiler-backend-global-array-element-shared-view
                held-labels
                0)))
          (set! has-pending true)
          (for [replay-j (iterator.range 1 held-label-count)]
            (let
              [restore-guard-owners? : bool
                (and
                  guard-owners-active?
                  (compiler-backend-peephole-desc-guard-ok-label? pending))]
              [emit : be_state.CompilerBackendPeepholeOwners
                (compiler-backend-peephole-emit-line-desc-record
                  walk
                  (be_state.compiler-backend-global-shared-view pending)
                  (if restore-guard-owners?
                    (compiler-backend-peephole-owners-copy guard-owners)
                    owners)
                  (or prev-abort? restore-guard-owners?))]
              (set! owners emit)
              (when restore-guard-owners? (set! guard-owners-active? false))
              (set!
                prev-abort?
                (compiler-backend-peephole-desc-noreturn-abort? pending))
              (set!
                pending
                (compiler-backend-peephole-line-copy
                  (be_state.compiler-backend-global-array-element-shared-view
                    held-labels
                    replay-j))))))
        unit))
    (if (and
      has-pending
      (not
        (compiler-backend-peephole-line-self-move-desc?
          (be_state.compiler-backend-global-shared-view pending))))
      (set!
        owners
        (compiler-backend-peephole-emit-line-desc-record
          walk
          (be_state.compiler-backend-global-shared-view pending)
          owners
          prev-abort?))
      unit)
    (compiler-backend-peephole-records-close walk)))

(define (compiler-backend-peephole-asm-once-records
  [backend-state : be_state.CompilerBackendState]
  [stream : be_state.CompilerBackendStreamState]
  [asm : String]
  [drop-fallthrough? : bool]) : be_state.CompilerBackendPeepholeLineVec
  (compiler-backend-peephole-asm-once-records-chunks
    backend-state
    stream
    (compiler-backend-peephole-single-chunk-array asm)
    drop-fallthrough?))

;; The single render of the group: append each surviving record's exact bytes
;; plus its newline flag. Runs of adjacent surviving asm lines coalesce into
;; one borrowed slice, so a group that the sweep did not touch renders as a
;; single copy of its range.
(define (compiler-backend-peephole-records-buffer
  [out : (text_buf_borrowed.TextBufBorrowed asm)]
  [v : be_state.CompilerBackendPeepholeLineVec]
  [asm : (& asm str)]
  [merge-tails? : bool]
  [compact-branches? : bool]) : (text_buf_borrowed.TextBufBorrowed asm)
  (when
    merge-tails?
    (let
      [plan : CompilerBackendColdPlan (compiler-backend-cold-plan-empty)]
      (compiler-backend-peephole-merge-tails! (&mut v) (& plan))
      (when
        compact-branches?
        (compiler-backend-peephole-compact-branch-jumps! (&mut v) (& plan)))))
  (let
    [recs : (__tl_dyn-array be_state.CompilerBackendPeepholeLineRecord) v.lines]
    [live : (__tl_dyn-array i64) v.live]
    [count : i64 v.len]
    [buf : (text_buf_borrowed.TextBufBorrowed asm) out]
    (for [i (iterator.range 0 count)]
      (when
        (= (array-ref live i) 1)
        (let
          [rec : be_state.CompilerBackendPeepholeLineRecord
            (be_state.compiler-backend-global-array-element-shared-view recs i)]
          (set!
            buf
            (if (compiler-backend-peephole-record-owned? rec)
              (compiler-backend-peephole-append-line
                buf
                (be_state.compiler-backend-global-shared-view rec.src)
                (compiler-backend-peephole-record-newline? rec))
              (compiler-backend-peephole-append-line-range
                buf
                asm
                (compiler-backend-peephole-record-start rec)
                (compiler-backend-peephole-record-end rec)
                (compiler-backend-peephole-record-newline? rec)))))))
    buf))

;; One event per candidate move, plus each ordinary entry. Only one candidate
;; at a call can match that callee's chosen pair, so selected events are
;; already in splice order even though we find each call's moves backwards.
(defstruct CompilerBackendArgEntryEvent
  (callee i64)
  (pair i64)
  (move-start i64)
  (move-end i64)
  (call-start i64)
  (call-end i64))

(import (vector.vector CompilerBackendArgEntryEvent core) as arg_entry_events)

(define (compiler-backend-arg-entry-enabled?
  [backend-state : be_state.CompilerBackendState]
  [target : be_state.CompilerBackendTarget]
  [emit-entry : bool]) : bool
  (and
    emit-entry
    (be_state.compiler-backend-target-elf? target)
    (be_state.compiler-backend-state-scalar-registers-enabled? backend-state)
    (not
      (be_state.compiler-backend-state-shared-object-code-model? backend-state))
    (not (compiler_ir_types.compiler-debug-info-enabled?))))

(define (compiler-backend-arg-entry-prepare!
  [index : be_state.CompilerBackendProgramIndex]
  [target : be_state.CompilerBackendTarget]
  [emit-entry : bool]
  [functions : (& functions compiler_ir_types.CompilerIrFunctionSeq)]) : unit
  (let
    [stream : be_state.CompilerBackendStreamState
      (be_state.compiler-backend-state-stream-state index.backend-state)]
    (when
      (and
        (compiler-backend-arg-entry-enabled?
          index.backend-state
          target
          emit-entry)
        (be_facts.compiler-backend-assembly-stream-active? stream))
      (let
        [symbols : backend_string_i64_map.Map
          (backend_string_i64_map.with-capacity functions.len)]
        (for [slot (iterator.range 0 functions.len)]
          (match (compiler_ir_types.compiler-ir-function-seq-borrow
            functions
            slot)
            [(Function name _ _ _ _ _)
              (backend_string_i64_map.insert!
                symbols
                (be_operand.compiler-backend-function-symbol-index index name)
                slot)]))
        (let
          [metadata : (Box be_state.CompilerBackendArgEntries)
            (box (be_state.CompilerBackendArgEntries symbols functions.len))]
          ;; This box and its map live in the program emission arena. The
          ;; finalizer clears the handle before that arena is released.
          (unsafe
            (set!
              (deref (be_state.compiler-backend-stream-state-ptr stream)).arg-entries
              (cast
                (ptr-read (ptr-cast (ptr-addr-of metadata) : (Ptr u64)))
                : i64))))))))

;; Convert the peephole's dense GP index (which skips rsp/rbp) to the ABI id.
(define (compiler-backend-arg-entry-reg-id [dense : i64]) : i64
  (if (>= dense 4)
    (+ dense 2)
    dense))

(define (compiler-backend-arg-entry-operand-reg
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : i64
  (let
    [reg : i64 (compiler-backend-peephole-token-reg-index-range data start end)]
    (if (< reg 0)
      (compiler-backend-peephole-rmw-high-byte-reg-index data start end)
      reg)))

(define (compiler-backend-arg-entry-collect-call!
  [data : (Ptr u8)]
  [call-start : i64]
  [call-end : i64]
  [callee : i64]
  [counts : (&mut counts (__tl_dyn-array u16))]
  [best : (&mut best (__tl_dyn-array i64))]
  [events : (&mut events arg_entry_events.Vec)]) : unit
  (let
    [end : i64 (- call-start 1)]
    [reads : i64 0]
    [writes : i64 0]
    ;; Consecutive calls scan disjoint setup ranges. A call, label, directive
    ;; or any instruction outside the explicit-destination subset stops us.
    (while (> end 0)
      (let
        [start : i64 (be_operand.compiler-backend-asm-prev-line-start data end)]
        [ms : i64 (+ start 4)]
        (unless
          (and (< ms end) (compiler-backend-cold-prefix? data start end "    "))
          (return unit))
        (let
          [me : i64
            (be_operand.compiler-backend-peephole-scan-byte-range
              data
              ms
              end
              32)]
          [movq? : bool
            (be_operand.compiler-backend-peephole-range-eq? data ms me "movq")]
          (unless
            (or
              movq?
              (compiler-backend-peephole-mnemonic-single-dest?
                data
                ms
                (- me ms)))
            (return unit))
          (let
            [src-start : i64 (+ me 1)]
            [comma : i64
              (compiler-backend-peephole-find-comma-space-range
                data
                src-start
                end)]
            (unless (and (> comma src-start) (< (+ comma 2) end)) (return unit))
            (let
              [src : i64
                (compiler-backend-arg-entry-operand-reg data src-start comma)]
              [dst : i64
                (compiler-backend-arg-entry-operand-reg data (+ comma 2) end)]
              ;; Only register destinations: no stack/frame pointer changes or
              ;; stack stores. XMM parks are untracked bare register sources.
              (when
                (or
                  (< dst 0)
                  (and
                    (< src 0)
                    (=
                      (be_state.compiler-backend-peephole-byte-at
                        data
                        src-start)
                      37)))
                (return unit))
              (let
                [dst-id : i64 (compiler-backend-arg-entry-reg-id dst)]
                [dst-bit : i64 (shl 1 dst-id)]
                (when
                  (and
                    movq?
                    (compiler-backend-peephole-rmw-callee-saved-reg? src)
                    (or (and (>= dst 1) (<= dst 2)) (and (>= dst 4) (<= dst 7)))
                    (= (bit-and (bit-or reads writes) dst-bit) 0))
                  (let
                    [src-id : i64 (compiler-backend-arg-entry-reg-id src)]
                    (when
                      (= (bit-and writes (shl 1 src-id)) 0)
                      (let
                        ;; Dense columns are rcx, rdx, rsi, rdi, r8, r9;
                        ;; rows are rbx, r12, r13, r14, r15.
                        [pair : i64
                          (+
                            (*
                              (if (= src 3)
                                0
                                (- src 9))
                              6)
                            (-
                              dst
                              (if (< dst 3)
                                1
                                2)))]
                        [row : i64 (* callee 30)]
                        [cell : i64 (+ row pair)]
                        [previous : u16 (array-ref counts cell)]
                        ;; Saturation keeps very large programs eligible.
                        [count : u16
                          (if (= previous 65535)
                            previous
                            (+ previous 1))]
                        [winner : i64 (array-ref best callee)]
                        (set! (array-ref counts cell) count)
                        (when
                          (or
                            (> count (array-ref counts (+ row winner)))
                            (and
                              (= count (array-ref counts (+ row winner)))
                              (< pair winner)))
                          (set! (array-ref best callee) pair))
                        (arg_entry_events.push-ref!
                          events
                          (CompilerBackendArgEntryEvent
                            callee
                            pair
                            start
                            (+ end 1)
                            call-start
                            call-end))))))
                (set! writes (bit-or writes dst-bit))
                ;; The destination is already in writes whether or not the
                ;; instruction also reads it. This includes emergency
                ;; restores from frame slots. Address base/index uses count.
                (set!
                  reads
                  (bit-or
                    reads
                    (compiler-backend-swb-reg-mask-range data src-start comma)))
                (set! end (- start 1))))))))))

;; A quoted ELF-local name contains ':' which cannot occur in the backend's
;; assembler identifiers. Keep it in the symbol table with a three-byte range
;; so the public entry's address and size still describe only the original body.
(define (compiler-backend-arg-entry-symbol [callee : i64]) : String
  (str_cat.str-cat "\"__tl_arg_entry:" (string.int->string callee) "\""))

;; The assembly chunks and their replacement buffer share the same home
;; arena. The String header can therefore point directly into the immutable
;; input chunk for as long as the output is live.
(define (compiler-backend-arg-entry-append-range
  [out : text_buf.TextBuf]
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : text_buf.TextBuf
  (if (= start end)
    out
    (text_buf.append
      out
      (unsafe
        (string-from-bytes (ptr-offset data start) (- end start))))))

(define (compiler-backend-arg-entry-splice
  [out : text_buf.TextBuf]
  [asm : String]
  [counts : (& counts (__tl_dyn-array u16))]
  [best : (& best (__tl_dyn-array i64))]
  [defined : (& defined (__tl_dyn-array bool))]
  [events : (& events (Slice CompilerBackendArgEntryEvent))]) : text_buf.TextBuf
  (let
    [result : text_buf.TextBuf out]
    [data : (Ptr u8)
      (unsafe
        (string-data (& asm)))]
    [copied : i64 0]
    (for [event events]
      (let
        [pair : i64 (array-ref best event.callee)]
        (when
          (and
            (array-ref defined event.callee)
            (>= (array-ref counts (+ (* event.callee 30) pair)) 2)
            (or (< event.pair 0) (= event.pair pair)))
          (let
            [entry : String (compiler-backend-arg-entry-symbol event.callee)]
            (set!
              result
              (compiler-backend-arg-entry-append-range
                result
                data
                copied
                event.move-start))
            (if (< event.pair 0)
              (let
                [src : i64 (/ pair 6)]
                [dst : i64 (% pair 6)]
                (text_buf.append!
                  result
                  (str_cat.str-cat
                    "    .local "
                    entry
                    "\n"
                    (be_operand.compiler-backend-emit-function-type-directive
                      (Linux)
                      entry)
                    entry
                    ":\n    movq "
                    (compiler_abi.compiler-abi-register-spelling
                      (if (= src 0)
                        compiler_abi.compiler-reg-id-rbx
                        (+ compiler_abi.compiler-reg-id-r12 (- src 1))))
                    ", "
                    (compiler_abi.compiler-abi-register-spelling
                      (+
                        dst
                        (if (< dst 2)
                          1
                          4)))
                    "\n"
                    (be_operand.compiler-backend-emit-function-size-directive
                      (Linux)
                      entry)))
                (set! copied event.move-start))
              (begin
                (set!
                  result
                  (compiler-backend-arg-entry-append-range
                    result
                    data
                    event.move-end
                    event.call-start))
                (text_buf.append!
                  result
                  (str_cat.str-cat "    call " entry "\n"))
                (set! copied event.call-end)))))))
    (if (= copied 0)
      (text_buf.append result asm)
      (compiler-backend-arg-entry-append-range
        result
        data
        copied
        (string.string-length asm)))))

(define (compiler-backend-arg-entry-scan-chunk!
  [asm : String]
  [symbols : (& symbols backend_string_i64_map.Map)]
  [counts : (&mut counts (__tl_dyn-array u16))]
  [best : (&mut best (__tl_dyn-array i64))]
  [defined : (&mut defined (__tl_dyn-array bool))]
  [events : (&mut events arg_entry_events.Vec)]) : unit
  (let
    [data : (Ptr u8)
      (unsafe
        (string-data (& asm)))]
    [end : i64 (string.string-length asm)]
    [inside-function : bool false]
    [start : i64 0]
    (while (< start end)
      (let
        [stop : i64
          (be_operand.compiler-backend-peephole-scan-byte-range
            data
            start
            end
            10)]
        (cond
          [(and
              inside-function
              (compiler-backend-cold-prefix? data start stop "    call "))
            (match (backend_string_i64_map.get-borrowed
              symbols
              (string.slice-view (& asm) (+ start 9) (- stop (+ start 9))))
              [(LookupFound callee)
                (compiler-backend-arg-entry-collect-call!
                  data
                  start
                  (+ stop 1)
                  callee
                  counts
                  best
                  events)]
              [(LookupMissing) unit])]
          [(compiler-backend-cold-prefix? data start stop "    .type ")
            (set! inside-function false)
            (let
              [name-start : i64 (+ start 10)]
              [name-end : i64 (- stop 10)]
              [label : i64 (+ stop 1)]
              [label-end : i64 (+ label (- name-end name-start))]
              (when
                (and
                  (> name-end name-start)
                  (< (+ label-end 1) end)
                  (be_operand.compiler-backend-peephole-range-eq?
                    data
                    name-end
                    stop
                    ",@function")
                  (=
                    (be_state.compiler-backend-peephole-byte-at data label-end)
                    58)
                  (=
                    (be_state.compiler-backend-peephole-byte-at
                      data
                      (+ label-end 1))
                    10)
                  (be_operand.compiler-backend-peephole-ranges-eq?
                    data
                    name-start
                    name-end
                    data
                    label
                    label-end))
                (match (backend_string_i64_map.get-borrowed
                  symbols
                  (string.slice-view (& asm) name-start (- name-end name-start)))
                  [(LookupFound slot)
                    (set! inside-function true)
                    (set! (array-ref defined slot) true)
                    (arg_entry_events.push-ref!
                      events
                      (CompilerBackendArgEntryEvent slot -1 label 0 0 0))]
                  [(LookupMissing) unit])))]
          [(compiler-backend-cold-prefix? data start stop "    .size ")
            (set! inside-function false)]
          [else unit])
        (set! start (+ stop 1))))))

(define (compiler-backend-arg-entry-optimize
  [final : text_buf.TextBuf]
  [metadata : be_state.CompilerBackendArgEntries]
  [home : arena.Arena]) : text_buf.TextBuf
  (let
    [chunks : text_buf.TextBufChunkList final.chunks]
    [chunk-count : i64 (text_buf.chunk-count (& chunks) 0)]
    [items : (__tl_dyn-array String) (__tl_make-array String chunk-count)]
    [event-ends : (__tl_dyn-array i64) (__tl_make-array i64 chunk-count)]
    [function-count : i64 metadata.function-count]
    [best : (__tl_dyn-array i64) (__tl_make-array i64 function-count)]
    [counts : (__tl_dyn-array u16) (__tl_make-array u16 (* function-count 30))]
    [defined : (__tl_dyn-array bool) (__tl_make-array bool function-count)]
    [events : arg_entry_events.Vec (arg_entry_events.new)]
    (text_buf.chunks-fill-array-rev chunks (&mut items) (- chunk-count 1))
    ;; The stream flushes whole function groups into individual chunks.
    (for [i (iterator.range 0 chunk-count)]
      (compiler-backend-arg-entry-scan-chunk!
        (be_state.compiler-backend-global-array-element-shared-view items i)
        (& metadata.symbols)
        (&mut counts)
        (&mut best)
        (&mut defined)
        (&mut events))
      (set! (array-ref event-ends i) events.len))
    (unsafe
      (in-arena
        (arena.Arena (arena.raw-handle home))
        (let
          [out : text_buf.TextBuf (text_buf.empty)]
          [view : (& events (Slice CompilerBackendArgEntryEvent))
            (arg_entry_events.view (& events))]
          [start : i64 0]
          (for [i (iterator.range 0 chunk-count)]
            (let
              [end : i64 (array-ref event-ends i)]
              (set!
                out
                (compiler-backend-arg-entry-splice
                  out
                  (be_state.compiler-backend-global-array-element-shared-view
                    items
                    i)
                  (& counts)
                  (& best)
                  (& defined)
                  (slice-view view start (- end start))))
              (set! start end)))
          out)))))

(cfg test (import stdlib.test))

(test
  arg-entry-emergency-restore-register-writes
  (for [restore (iterator.range 0 3)]
    (let
      [register : String
        (cond [(= restore 0) "%r10"] [(= restore 1) "%r12"] [else "%rdi"])]
      [setup : String
        (str_cat.str-cat
          "    movq %r12, %rdi\n    movq 112(%rsp), "
          register
          "\n")]
      [asm : String (str_cat.str-cat setup "    call target\n")]
      [counts : (__tl_dyn-array u16) (__tl_make-array u16 30)]
      [best : (__tl_dyn-array i64) (__tl_make-array i64 1)]
      [events : arg_entry_events.Vec (arg_entry_events.new)]
      (compiler-backend-arg-entry-collect-call!
        (unsafe
          (string-data (& asm)))
        (string.string-length setup)
        (string.string-length asm)
        0
        (&mut counts)
        (&mut best)
        (&mut events))
      (test.assert-i64-eq
        events.len
        (if (= restore 0)
          1
          0)
        "a restore can be crossed only when it leaves both copy registers intact"))))