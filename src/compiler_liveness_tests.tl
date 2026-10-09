;; compiler_liveness_tests.tl - Liveness fixture builders and self-test checks
;; split from production compiler_liveness.tl.
;;
;; Main-less companion imported by src/tests/compiler_liveness_smoke.tl: it
;; holds the CompilerLiveI64Set/scratch -ok? checks, the IR function fixtures,
;; the analyzer -ok? assertions, and the compiler-live-self-test entry. The
;; production module keeps only the analyzer itself.
(import compiler_liveness as live)
(import compiler_ir_types as ir)
(import compiler_ir_text as irt)
(import compiler_ast_types as ast)
(import stdlib.io)
(import compiler_owned_view as owned_view)

(define (compiler-live-set5 [a : i64] [b : i64] [c : i64] [d : i64] [e : i64]) : live.CompilerLiveI64Set
  (let
    [words : (__tl_dyn-array i64)
      (live.compiler-live-set-builder
        (live.compiler-live-set-max
          (live.compiler-live-set-max (live.compiler-live-set-max a b) c)
          (live.compiler-live-set-max d e)))]
    (live.compiler-live-set-builder-insert! (&mut words) a)
    (live.compiler-live-set-builder-insert! (&mut words) b)
    (live.compiler-live-set-builder-insert! (&mut words) c)
    (live.compiler-live-set-builder-insert! (&mut words) d)
    (live.compiler-live-set-builder-insert! (&mut words) e)
    (live.CompilerLiveI64Set words)))

(define (compiler-live-set6
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]) : live.CompilerLiveI64Set
  (let
    [words : (__tl_dyn-array i64)
      (live.compiler-live-set-builder
        (live.compiler-live-set-max
          (live.compiler-live-set-max (live.compiler-live-set-max a b) c)
          (live.compiler-live-set-max (live.compiler-live-set-max d e) f)))]
    (live.compiler-live-set-builder-insert! (&mut words) a)
    (live.compiler-live-set-builder-insert! (&mut words) b)
    (live.compiler-live-set-builder-insert! (&mut words) c)
    (live.compiler-live-set-builder-insert! (&mut words) d)
    (live.compiler-live-set-builder-insert! (&mut words) e)
    (live.compiler-live-set-builder-insert! (&mut words) f)
    (live.CompilerLiveI64Set words)))

(define (compiler-live-set7
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]) : live.CompilerLiveI64Set
  (let
    [words : (__tl_dyn-array i64)
      (live.compiler-live-set-builder
        (live.compiler-live-set-max
          (live.compiler-live-set-max
            (live.compiler-live-set-max (live.compiler-live-set-max a b) c)
            (live.compiler-live-set-max d e))
          (live.compiler-live-set-max f g)))]
    (live.compiler-live-set-builder-insert! (&mut words) a)
    (live.compiler-live-set-builder-insert! (&mut words) b)
    (live.compiler-live-set-builder-insert! (&mut words) c)
    (live.compiler-live-set-builder-insert! (&mut words) d)
    (live.compiler-live-set-builder-insert! (&mut words) e)
    (live.compiler-live-set-builder-insert! (&mut words) f)
    (live.compiler-live-set-builder-insert! (&mut words) g)
    (live.CompilerLiveI64Set words)))

(define (compiler-live-set-ops-ok?) : bool
  (let
    [empty : live.CompilerLiveI64Set (live.compiler-live-set-empty)]
    [with-negative : live.CompilerLiveI64Set
      (live.compiler-live-set-insert (live.compiler-live-shared-view empty) -4)]
    [a : live.CompilerLiveI64Set (compiler-live-set4 0 31 32 66)]
    [b : live.CompilerLiveI64Set (compiler-live-set4 66 32 31 0)]
    [removed : live.CompilerLiveI64Set
      (compiler-live-set-remove (live.compiler-live-shared-view a) 31)]
    [unioned : live.CompilerLiveI64Set
      (live.compiler-live-set-union
        (live.compiler-live-shared-view removed)
        (compiler-live-set2 31 65))]
    [minus : live.CompilerLiveI64Set
      (live.compiler-live-set-minus
        (live.compiler-live-shared-view unioned)
        (compiler-live-set2 0 65))]
    [trimmed : live.CompilerLiveI64Set
      (compiler-live-set-remove
        (compiler-live-set-remove (live.compiler-live-shared-view a) 66)
        32)]
    [deduplicated : live.CompilerLiveI64Set (compiler-live-set4 -1 31 31 66)]
    [ok : bool true]
    (set! ok (and ok (live.compiler-live-set-eq? empty with-negative)))
    (set! ok (and ok (= (live.compiler-live-set-count a) 4)))
    (set! ok (and ok (live.compiler-live-set-contains? a 0)))
    (set! ok (and ok (live.compiler-live-set-contains? a 31)))
    (set! ok (and ok (live.compiler-live-set-contains? a 32)))
    (set! ok (and ok (live.compiler-live-set-contains? a 66)))
    (set! ok (and ok (not (live.compiler-live-set-contains? a -1))))
    (set! ok (and ok (not (live.compiler-live-set-contains? a 33))))
    (set!
      ok
      (and
        ok
        (live.compiler-live-set-eq?
          (live.compiler-live-shared-view a)
          (live.compiler-live-shared-view b))))
    (set!
      ok
      (and ok (= (compiler-live-set-score a) (compiler-live-set-score b))))
    (set! ok (and ok (= (live.compiler-live-set-count removed) 3)))
    (set! ok (and ok (not (live.compiler-live-set-contains? removed 31))))
    (set! ok (and ok (= (live.compiler-live-set-count unioned) 5)))
    (set!
      ok
      (and ok (live.compiler-live-set-eq? minus (compiler-live-set3 31 32 66))))
    (set! ok (and ok (= (live.compiler-live-set-count trimmed) 2)))
    (set! ok (and ok (= (live.compiler-live-set-word-count trimmed) 1)))
    (set!
      ok
      (and
        ok
        (live.compiler-live-set-eq? deduplicated (compiler-live-set2 31 66))))
    ok))

(define (compiler-live-scratch-ops-ok?) : bool
  (let
    [words : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    [copied : live.CompilerLiveI64Set (compiler-live-set3 1 64 130)]
    [copy-count : i64 (live.compiler-live-scratch-copy-set! (& words) copied)]
    [copy-ok : bool
      (and
        (= copy-count 5)
        (live.compiler-live-scratch-eq-set?
          (live.compiler-live-shared-view words)
          copy-count
          (compiler-live-set3 1 64 130)))]
    [union-count : i64
      (live.compiler-live-scratch-union-set!
        (live.compiler-live-shared-view words)
        copy-count
        (compiler-live-set2 65 191))]
    [union-ok : bool
      (and
        (= union-count 6)
        (live.compiler-live-scratch-eq-set?
          (live.compiler-live-shared-view words)
          union-count
          (compiler-live-set5 1 64 65 130 191)))]
    [step-uses : live.CompilerLiveI64Set (live.compiler-live-set1 0)]
    [step-defs : live.CompilerLiveI64Set (compiler-live-set2 1 130)]
    [step-count : i64
      (live.compiler-live-scratch-step!
        (& words)
        union-count
        step-uses
        step-defs)]
    [step-ok : bool
      (and
        (= step-count 6)
        (live.compiler-live-scratch-eq-set?
          (live.compiler-live-shared-view words)
          step-count
          (compiler-live-set4 0 64 65 191))
        (live.compiler-live-set-eq?
          (live.compiler-live-scratch-freeze (& words) step-count)
          (compiler-live-set4 0 64 65 191)))]
    [short : live.CompilerLiveI64Set (live.compiler-live-set1 7)]
    [short-count : i64 (live.compiler-live-scratch-copy-set! (& words) short)]
    [short-ok : bool
      (and
        (= short-count 1)
        (live.compiler-live-scratch-eq-set?
          (live.compiler-live-shared-view words)
          short-count
          (live.compiler-live-set1 7))
        (= (live.compiler-live-set-trim-length words 6) 1))]
    [_cleared : unit (live.compiler-live-scratch-clear! (& words))]
    (and
      copy-ok
      union-ok
      step-ok
      short-ok
      (= (live.compiler-live-set-trim-length words 6) 0))))

;; Differential proof for the direct-id API: the ids an instruction hands over
;; must describe exactly the sets the bitset decode builds. Every id-driven
;; consumer rests on this, so it is checked per instruction rather than per
;; consumer.
(define (compiler-live-instr-ids-match-set? [instr : ir.CompilerIrInstr]) : bool
  (let
    [uses : live.CompilerLiveI64Set (live.compiler-live-instr-uses instr)]
    [defs : live.CompilerLiveI64Set
      (live.compiler-live-instr-defs (& (clone instr)))]
    [def-var : i64 (ir.compiler-ir-instr-dst instr)]
    [ids : (__tl_dyn-array i64) (live.compiler-live-instr-ids)]
    [id-count : i64 (live.compiler-live-instr-use-ids! (& instr))]
    [index : i64 0]
    [ok : bool (= id-count (live.compiler-live-set-count uses))]
    (while (< index id-count)
      (if (live.compiler-live-set-contains? uses (array-ref ids index))
        unit
        (set! ok false))
      (set! index (+ index 1)))
    (and
      ok
      (=
        (live.compiler-live-set-count defs)
        (if (< def-var 0)
          0
          1))
      (or (< def-var 0) (live.compiler-live-set-contains? defs def-var)))))

(define (compiler-live-instr-ids-seq-match-set-from?
  [instrs : ir.CompilerIrInstrSeq]
  [index : i64]) : bool
  (if (>= index (ir.compiler-ir-instr-seq-count instrs))
    true
    (and
      (compiler-live-instr-ids-match-set?
        (ir.compiler-ir-instr-seq-ref instrs index))
      (compiler-live-instr-ids-seq-match-set-from? instrs (+ index 1)))))

(define (compiler-live-instr-ids-seq-match-set?
  [instrs : ir.CompilerIrInstrSeq]) : bool
  (compiler-live-instr-ids-seq-match-set-from? instrs 0))

;; Instruction shapes that exercise the parts of the decode a straight
;; one-operand arm does not: a repeated operand (the set de-duplicates, so the
;; id list must too), a two-arg call, a phi input list, a packed value list, a
;; raw-var AddrOf operand, and a def-less terminator.
(define (compiler-live-ids-sample-instrs) : ir.CompilerIrInstrSeq
  (irt.instrs
    "%0 = mov %10 : i64
     %1 = add %7, %7 : i64
     %2 = addr_of %33
     %3 = gep %40, 8 : i64
     %4 = call f(%41, %41) : i64
     %5 = pack [%42, %43] : i64
     %6 = phi [%44, a], [%44, b] : i64
     store_ptr %45, %46 : i64
     branch %47, a, b"))

;; The two id-driven scratch steps must leave the row -- and the trimmed active
;; count -- exactly where the bitset forms leave them.
(define (compiler-live-step-ids-ok?) : bool
  (let
    [set-words : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    [id-words : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    [ids : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [set-use-words : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    [set-def-words : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    [id-use-words : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    [id-def-words : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    [seed : live.CompilerLiveI64Set (compiler-live-set3 1 64 130)]
    [set-active : i64 (live.compiler-live-scratch-copy-set! (& set-words) seed)]
    [id-active : i64 (live.compiler-live-scratch-copy-set! (& id-words) seed)]
    ;; `130` is used and defined here, and `1` is only defined: the def clear
    ;; must lose `1`, the use must keep `130`, and the row must grow to hold the
    ;; new use `191`.
    [_ids-fill : unit
      (begin
        (set! (array-ref ids 0) 130)
        (set! (array-ref ids 1) 191))]
    [step-uses : live.CompilerLiveI64Set (compiler-live-set2 130 191)]
    [step-defs : live.CompilerLiveI64Set (live.compiler-live-set1 1)]
    [set-count : i64
      (live.compiler-live-scratch-step!
        (& set-words)
        set-active
        step-uses
        step-defs)]
    [id-count : i64
      (live.compiler-live-scratch-step-ids! (&mut id-words) id-active ids 2 1)]
    [step-ok : bool
      (and
        (= set-count id-count)
        (live.compiler-live-set-eq?
          (live.compiler-live-scratch-freeze (& set-words) set-count)
          (live.compiler-live-scratch-freeze (& id-words) id-count)))]
    ;; The block use/def accumulation: `9` is already defined by an earlier
    ;; instruction, so using it here must NOT make it a block use; `70` must.
    [_seed-defs : unit
      (begin
        (live.compiler-live-set-builder-insert! (&mut set-def-words) 9)
        (live.compiler-live-set-builder-insert! (&mut id-def-words) 9))]
    [_step2-ids : unit
      (begin
        (set! (array-ref ids 0) 9)
        (set! (array-ref ids 1) 70))]
    [instr-uses : live.CompilerLiveI64Set (compiler-live-set2 9 70)]
    [instr-defs : live.CompilerLiveI64Set (live.compiler-live-set1 130)]
    [_set-step : unit
      (live.compiler-live-block-use-def-step!
        (& set-use-words)
        (& set-def-words)
        instr-uses
        instr-defs)]
    [_id-step : unit
      (live.compiler-live-block-use-def-step-ids!
        (&mut id-use-words)
        (&mut id-def-words)
        ids
        2
        130)]
    [use-def-ok : bool
      (and
        (live.compiler-live-set-eq?
          (live.compiler-live-scratch-freeze (& set-use-words) 6)
          (live.compiler-live-set1 70))
        (live.compiler-live-set-eq?
          (live.compiler-live-scratch-freeze (& set-use-words) 6)
          (live.compiler-live-scratch-freeze (& id-use-words) 6))
        (live.compiler-live-set-eq?
          (live.compiler-live-scratch-freeze (& set-def-words) 6)
          (live.compiler-live-scratch-freeze (& id-def-words) 6)))]
    ;; A use list wider than the buffer reports -1 so the caller can fall back.
    [narrow : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [overflow-ok : bool
      (=
        (live.compiler-live-instr-use-ids-into!
          (& (irt.instr "store_ptr %3, %4 : i64"))
          (&mut narrow))
        -1)]
    (and
      step-ok
      use-def-ok
      overflow-ok
      (compiler-live-instr-ids-seq-match-set? (compiler-live-ids-sample-instrs)))))

(define (compiler-live-i64-ty) : ast.AstType
  (I64))

(define (compiler-live-instr-seq7
  [first : ir.CompilerIrInstr]
  [second : ir.CompilerIrInstr]
  [third : ir.CompilerIrInstr]
  [fourth : ir.CompilerIrInstr]
  [fifth : ir.CompilerIrInstr]
  [sixth : ir.CompilerIrInstr]
  [seventh : ir.CompilerIrInstr]) : ir.CompilerIrInstrSeq
  (let
    [slots : (__tl_dyn-array ir.CompilerIrInstr)
      (__tl_make-array ir.CompilerIrInstr 7)]
    (set! (array-ref slots 0) first)
    (set! (array-ref slots 1) second)
    (set! (array-ref slots 2) third)
    (set! (array-ref slots 3) fourth)
    (set! (array-ref slots 4) fifth)
    (set! (array-ref slots 5) sixth)
    (set! (array-ref slots 6) seventh)
    (ir.CompilerIrInstrSeq slots 7)))

(define (compiler-live-straight-function) : ir.CompilerIrFunction
  (irt.func
    "function @straight() -> i64 vars 3 {
     entry:
       %0 = mov 1 : i64
       %1 = add %0, %2 : i64
       return %1
     }"))

(define (compiler-live-branch-function) : ir.CompilerIrFunction
  (irt.func
    "function @branch() -> i64 vars 3 {
     entry:
       branch %0, then, else
     then:
       return %1
     else:
       return %2
     }"))

(define (compiler-live-phi-function) : ir.CompilerIrFunction
  (irt.func
    "function @phi() -> i64 vars 4 {
     entry:
       branch %0, left, right
     left:
       %1 = mov 10 : i64
       jump join
     right:
       %2 = mov 20 : i64
       jump join
     join:
       %3 = phi [%1, left], [%2, right] : i64
       return %3
     }"))

(define (compiler-live-use-def-ok?) : bool
  (let
    [use-def : live.CompilerLiveUseDef
      (compiler-live-block-use-def
        (irt.instrs
          "%0 = mov %10 : i64
           %1 = add %0, %11 : i64
           %2 = neg %12 : i64
           %3 = call f(%1, %13) : i64
           store @g, %14 : i64
           branch %15, a, b
           %4 = phi [%16, a] : i64
           return %4"))]
    (and
      (live.compiler-live-set-eq?
        use-def.uses
        (compiler-live-set7 10 11 12 13 14 15 16))
      (live.compiler-live-set-eq? use-def.defs (compiler-live-set5 0 1 2 3 4)))))

;; Leading phis read in parallel. In a loop block `i = phi [.., %5]` then
;; `a = phi [.., i]`, the second phi reads the PREVIOUS iteration's `i`, so `i`
;; is upward-exposed although the phi before it defines `i`; it must stay live
;; around the back edge instead of dying at the increment `%5 = i + 1`.
(define (compiler-live-parallel-phi-use-def-ok?) : bool
  (let
    [use-def : live.CompilerLiveUseDef
      (compiler-live-block-use-def
        (ir.compiler-ir-instr-seq4
          (irt.instr "%1 = phi [%5, body] : i64")
          (irt.instr "%2 = phi [%1, body] : i64")
          (irt.instr "%5 = add %1, 1 : i64")
          (irt.instr "branch %5, body, exit")))]
    (and
      (live.compiler-live-set-contains? use-def.uses 1)
      (live.compiler-live-set-contains? use-def.uses 5)
      (not (live.compiler-live-set-contains? use-def.uses 2))
      (live.compiler-live-set-contains? use-def.defs 1)
      (live.compiler-live-set-contains? use-def.defs 2)
      (live.compiler-live-set-contains? use-def.defs 5))))

(define (compiler-live-memory-use-def-ok?) : bool
  (let
    [use-def : live.CompilerLiveUseDef
      (compiler-live-block-use-def
        (irt.instrs
          "%0 = alloc i64
           %1 = addr_of %0
           %2 = gep %1, %10 : i64
           %3 = load %2 : i64
           store_ptr %2, %11 : i64
           %4 = cast %3 : i64 to i32"))]
    (and
      (live.compiler-live-set-eq? use-def.uses (compiler-live-set2 10 11))
      (live.compiler-live-set-eq? use-def.defs (compiler-live-set5 0 1 2 3 4)))))

;; StoreOwned defines nothing and reads both its address and its value.
(define (compiler-live-store-owned-use-def-ok?) : bool
  (let
    [store : ir.CompilerIrInstr (irt.instr "store_owned %71 -> %70 : String")]
    (and
      (= (ir.compiler-ir-instr-dst store) -1)
      (live.compiler-live-set-eq?
        (live.compiler-live-instr-defs (& (clone store)))
        (live.compiler-live-set-empty))
      (live.compiler-live-set-eq?
        (live.compiler-live-instr-uses store)
        (compiler-live-set2 70 71)))))

(define (compiler-live-vector-mask-use-def-ok?) : bool
  (let
    [use-def : live.CompilerLiveUseDef
      (compiler-live-block-use-def
        (compiler-live-instr-seq7
          (LaneId 0 4 (compiler-live-i64-ty))
          (irt.instr "%1 = splat %10 lanes 4 : i64")
          (ir.ir-instr-vector-bin-op
            2
            (Add)
            (Var 0)
            (Var 1)
            4
            (compiler-live-i64-ty))
          (irt.instr "%3 = tail_mask %11, %12 lanes 4")
          (ir.ir-instr-predicated-load
            4
            (Var 13)
            (Var 11)
            (Var 3)
            4
            (compiler-live-i64-ty))
          (ir.ir-instr-predicated-store
            (Var 14)
            (Var 11)
            (Var 2)
            (Var 3)
            4
            (compiler-live-i64-ty))
          (irt.instr "%5 = mask_reduce_any %3 lanes 4")))]
    (and
      (live.compiler-live-set-eq?
        use-def.uses
        (compiler-live-set5 10 11 12 13 14))
      (live.compiler-live-set-eq? use-def.defs (compiler-live-set6 0 1 2 3 4 5)))))

(define (compiler-live-straight-ok?) : bool
  (let
    [liveness : live.CompilerFunctionLiveness
      (live.compiler-live-analyze-function
        (& (compiler-live-straight-function)))]
    (match (live.compiler-live-function-find-block
      (& liveness)
      (ir.compiler-ir-label "entry"))
      [(Some block)
        (and
          (live.compiler-live-set-eq?
            (compiler-live-block-uses block)
            (live.compiler-live-set1 2))
          (live.compiler-live-set-eq?
            (live.compiler-live-block-defs
              (live.compiler-live-shared-view block))
            (compiler-live-set2 0 1))
          (live.compiler-live-set-eq?
            (live.compiler-live-block-live-in
              (live.compiler-live-shared-view block))
            (live.compiler-live-set1 2))
          (live.compiler-live-set-eq?
            (live.compiler-live-block-live-out block)
            (live.compiler-live-set-empty))
          (live.compiler-live-set-eq?
            (live.compiler-live-after
              (& liveness)
              (ir.compiler-ir-label "entry")
              0)
            (compiler-live-set2 0 2))
          (live.compiler-live-set-eq?
            (live.compiler-live-after
              (& liveness)
              (ir.compiler-ir-label "entry")
              1)
            (live.compiler-live-set1 1))
          (live.compiler-live-set-eq?
            (live.compiler-live-after
              (& liveness)
              (ir.compiler-ir-label "entry")
              2)
            (live.compiler-live-set-empty)))]
      [(No) false])))

(define (compiler-live-branch-ok?) : bool
  (let
    [liveness : live.CompilerFunctionLiveness
      (live.compiler-live-analyze-function (& (compiler-live-branch-function)))]
    (match (live.compiler-live-function-find-block
      (& liveness)
      (ir.compiler-ir-label "entry"))
      [(Some block)
        (and
          (=
            (live.compiler-live-label-set-count
              (& (compiler-live-block-successor-labels block)))
            2)
          (live.compiler-live-label-set-contains?
            (& (compiler-live-block-successor-labels block))
            (ir.compiler-ir-label "then"))
          (live.compiler-live-label-set-contains?
            (& (compiler-live-block-successor-labels block))
            (ir.compiler-ir-label "else"))
          (live.compiler-live-set-eq?
            (live.compiler-live-block-live-in block)
            (compiler-live-set3 0 1 2)))]
      [(No) false])))

(define (compiler-live-phi-ok?) : bool
  (let
    [liveness : live.CompilerFunctionLiveness
      (live.compiler-live-analyze-function (& (compiler-live-phi-function)))]
    (match (live.compiler-live-function-find-block
      (& liveness)
      (ir.compiler-ir-label "join"))
      [(Some block)
        (and
          (live.compiler-live-set-eq?
            (compiler-live-block-uses block)
            (compiler-live-set2 1 2))
          (live.compiler-live-set-eq?
            (live.compiler-live-block-defs
              (live.compiler-live-shared-view block))
            (live.compiler-live-set1 3))
          (live.compiler-live-set-eq?
            (live.compiler-live-block-live-in block)
            (compiler-live-set2 1 2))
          (live.compiler-live-set-eq?
            (live.compiler-live-after
              (& liveness)
              (ir.compiler-ir-label "join")
              0)
            (live.compiler-live-set1 3))
          (match (live.compiler-live-function-find-block
            (& liveness)
            (ir.compiler-ir-label "left"))
            [(Some left-block)
              (live.compiler-live-label-set-contains?
                (& (compiler-live-block-successor-labels left-block))
                (ir.compiler-ir-label "join"))]
            [(No) false]))]
      [(No) false])))

(define (compiler-live-phi-edge-precise-ok?) : bool
  (let
    [baseline : live.CompilerFunctionLiveness
      (live.compiler-live-analyze-function (& (compiler-live-phi-function)))]
    [edge-precise : live.CompilerFunctionLiveness
      (live.compiler-live-analyze-function-edge-precise
        (& (compiler-live-phi-function)))]
    (match (live.compiler-live-function-find-block
      (& baseline)
      (ir.compiler-ir-label "join"))
      [(Some baseline-join)
        (match (live.compiler-live-function-find-block
          (& edge-precise)
          (ir.compiler-ir-label "join"))
          [(Some edge-precise-join)
            (match (live.compiler-live-function-find-block
              (& baseline)
              (ir.compiler-ir-label "left"))
              [(Some baseline-left)
                (match (live.compiler-live-function-find-block
                  (& edge-precise)
                  (ir.compiler-ir-label "left"))
                  [(Some edge-precise-left)
                    (match (live.compiler-live-function-find-block
                      (& edge-precise)
                      (ir.compiler-ir-label "right"))
                      [(Some edge-precise-right)
                        (and
                          (live.compiler-live-set-eq?
                            (compiler-live-block-uses baseline-join)
                            (compiler-live-set2 1 2))
                          (live.compiler-live-set-eq?
                            (compiler-live-block-uses edge-precise-join)
                            (live.compiler-live-set-empty))
                          (live.compiler-live-set-eq?
                            (live.compiler-live-block-live-in edge-precise-join)
                            (live.compiler-live-set-empty))
                          (live.compiler-live-set-eq?
                            (live.compiler-live-block-live-out baseline-left)
                            (compiler-live-set2 1 2))
                          (live.compiler-live-set-eq?
                            (live.compiler-live-block-live-out
                              edge-precise-left)
                            (live.compiler-live-set1 1))
                          (live.compiler-live-set-eq?
                            (live.compiler-live-block-live-out
                              edge-precise-right)
                            (live.compiler-live-set1 2)))]
                      [(No) false])]
                  [(No) false])]
              [(No) false])]
          [(No) false])]
      [(No) false])))

(define (compiler-live-switch-ok?) : bool
  (let
    [instr : ir.CompilerIrInstr
      (irt.instr "switch %9 base 4 [4:four, 5:five] default other")]
    [instrs : ir.CompilerIrInstrSeq (ir.compiler-ir-instr-seq1 instr)]
    [block : ir.CompilerIrBlock
      (Block (ir.compiler-ir-label "entry") (clone instrs))]
    [successors : live.CompilerLiveLabelSet
      (live.compiler-live-block-successors (& block))]
    [use-def : live.CompilerLiveUseDef (compiler-live-block-use-def instrs)]
    (and
      (live.compiler-live-set-eq? use-def.uses (live.compiler-live-set1 9))
      (live.compiler-live-set-eq? use-def.defs (live.compiler-live-set-empty))
      (= (live.compiler-live-label-set-count (& successors)) 3)
      (live.compiler-live-label-set-contains?
        (& successors)
        (ir.compiler-ir-label "four"))
      (live.compiler-live-label-set-contains?
        (& successors)
        (ir.compiler-ir-label "five"))
      (live.compiler-live-label-set-contains?
        (& successors)
        (ir.compiler-ir-label "other")))))

(define (compiler-live-self-test) : i64
  (if (and
    (compiler-live-set-ops-ok?)
    (compiler-live-scratch-ops-ok?)
    (compiler-live-step-ids-ok?)
    (compiler-live-use-def-ok?)
    (compiler-live-parallel-phi-use-def-ok?)
    (compiler-live-memory-use-def-ok?)
    (compiler-live-store-owned-use-def-ok?)
    (compiler-live-vector-mask-use-def-ok?)
    (compiler-live-straight-ok?)
    (compiler-live-branch-ok?)
    (compiler-live-phi-ok?)
    (compiler-live-phi-edge-precise-ok?)
    (compiler-live-switch-ok?))
    42
    (io.panic "liveness: smoke mismatch")))

(define (compiler-live-set-remove [set : live.CompilerLiveI64Set] [value : i64]) : live.CompilerLiveI64Set
  (if (< value 0)
    set
    (let
      [word-index : i64 (live.compiler-live-set-word-index value)]
      [capacity : i64 (live.compiler-live-set-word-count set)]
      [mask : i64 (live.compiler-live-set-bit-mask value)]
      (if (>= word-index capacity)
        set
        (let
          [old-bits : i64
            (live.compiler-live-set-word-at-bounded set word-index)]
          (if (= (bit-and old-bits mask) 0)
            set
            (let
              [out : (__tl_dyn-array i64)
                (live.compiler-live-set-copy-with-capacity set capacity)]
              (set!
                (array-ref out word-index)
                (bit-and old-bits (bit-xor mask -1)))
              (live.compiler-live-set-from-words-trimmed out capacity))))))))

(define (compiler-live-set-score-word-desc
  [bits : i64]
  [base : i64]
  [bit : i64]
  [acc : i64]) : i64
  (if (< bit 0)
    acc
    (compiler-live-set-score-word-desc
      bits
      base
      (- bit 1)
      (if (= (bit-and bits (shl 1 bit)) 0)
        acc
        (+ (+ base (+ bit 1)) (* 17 acc))))))

(define (compiler-live-set-score [set : (& set live.CompilerLiveI64Set)]) : i64
  (let
    [index : i64 (- (live.compiler-live-set-word-count set) 1)]
    [score : i64 0]
    (while (>= index 0)
      (set!
        score
        (compiler-live-set-score-word-desc
          (live.compiler-live-set-word-at-bounded set index)
          (* index (live.compiler-live-set-word-bits))
          (- (live.compiler-live-set-word-bits) 1)
          score))
      (set! index (- index 1)))
    score))

(define (compiler-live-set2 [a : i64] [b : i64]) : live.CompilerLiveI64Set
  (let
    [words : (__tl_dyn-array i64)
      (live.compiler-live-set-builder (live.compiler-live-set-max a b))]
    (live.compiler-live-set-builder-insert! (&mut words) a)
    (live.compiler-live-set-builder-insert! (&mut words) b)
    (live.CompilerLiveI64Set words)))

(define (compiler-live-set3 [a : i64] [b : i64] [c : i64]) : live.CompilerLiveI64Set
  (let
    [words : (__tl_dyn-array i64)
      (live.compiler-live-set-builder
        (live.compiler-live-set-max (live.compiler-live-set-max a b) c))]
    (live.compiler-live-set-builder-insert! (&mut words) a)
    (live.compiler-live-set-builder-insert! (&mut words) b)
    (live.compiler-live-set-builder-insert! (&mut words) c)
    (live.CompilerLiveI64Set words)))

(define (compiler-live-set4 [a : i64] [b : i64] [c : i64] [d : i64]) : live.CompilerLiveI64Set
  (let
    [words : (__tl_dyn-array i64)
      (live.compiler-live-set-builder
        (live.compiler-live-set-max
          (live.compiler-live-set-max a b)
          (live.compiler-live-set-max c d)))]
    (live.compiler-live-set-builder-insert! (&mut words) a)
    (live.compiler-live-set-builder-insert! (&mut words) b)
    (live.compiler-live-set-builder-insert! (&mut words) c)
    (live.compiler-live-set-builder-insert! (&mut words) d)
    (live.CompilerLiveI64Set words)))

(define (compiler-live-block-use-def-instrs
  [instrs : ir.CompilerIrInstrSeq]
  [index : i64]
  [uses : live.CompilerLiveI64Set]
  [defs : live.CompilerLiveI64Set]) : live.CompilerLiveUseDef
  (let
    [cursor : i64 index]
    [count : i64 (ir.compiler-ir-instr-seq-count instrs)]
    ;; Leading phis read in parallel (see compiler-live-leading-phi-count).
    [phi-end : i64
      (if (= index 0)
        (live.compiler-live-leading-phi-count
          (live.compiler-live-shared-view instrs))
        0)]
    [out-uses : live.CompilerLiveI64Set uses]
    [out-defs : live.CompilerLiveI64Set defs]
    (while (< cursor count)
      (let
        [instr : ir.CompilerIrInstr
          (ir.compiler-ir-instr-seq-ref instrs cursor)]
        [instr-uses : live.CompilerLiveI64Set
          (live.compiler-live-instr-uses instr)]
        [instr-defs : live.CompilerLiveI64Set
          (if (< cursor phi-end)
            (live.compiler-live-set-empty)
            (live.compiler-live-instr-defs (& instr)))]
        (set!
          out-uses
          (live.compiler-live-set-union
            out-uses
            (live.compiler-live-set-minus
              instr-uses
              (live.compiler-live-shared-view out-defs))))
        (set! out-defs (live.compiler-live-set-union out-defs instr-defs))
        (when
          (= (+ cursor 1) phi-end)
          (let
            [j : i64 0]
            (while (< j phi-end)
              (set!
                out-defs
                (live.compiler-live-set-union
                  out-defs
                  (live.compiler-live-instr-defs
                    (& (ir.compiler-ir-instr-seq-ref instrs j)))))
              (set! j (+ j 1)))))
        (set! cursor (+ cursor 1))))
    (live.CompilerLiveUseDef out-uses out-defs)))

(define (compiler-live-block-use-def [instrs : ir.CompilerIrInstrSeq]) : live.CompilerLiveUseDef
  (compiler-live-block-use-def-instrs
    instrs
    0
    (live.compiler-live-set-empty)
    (live.compiler-live-set-empty)))

(define (compiler-live-block-uses [block : (& block live.CompilerLiveBlock)]) : live.CompilerLiveI64Set
  (let
    [block : live.CompilerLiveBlock
      (owned_view.compiler-owned-reference-shared-view block)]
    block.uses))

(define (compiler-live-block-successor-labels
  [block : (& block live.CompilerLiveBlock)]) : live.CompilerLiveLabelSet
  (let
    [block : live.CompilerLiveBlock
      (owned_view.compiler-owned-reference-shared-view block)]
    block.successors))