;; compiler_liveness_tests.tl - Liveness fixture builders and self-test checks
;; split from production compiler_liveness.tl (simplify.md A1, #5169 pattern).
;;
;; Main-less companion imported by src/tests/compiler_liveness_smoke.tl: it
;; holds the CompilerLiveI64Set/scratch -ok? checks, the IR function fixtures,
;; the analyzer -ok? assertions, and the compiler-live-self-test entry. The
;; production module keeps only the analyzer itself.
(import compiler_liveness as live)
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import stdlib.io)

(define (compiler-live-set5 [a : i64] [b : i64] [c : i64] [d : i64] [e : i64]) : live.CompilerLiveI64Set
  (let
    [words : (__tl_dyn-array i64)
      (live.compiler-live-set-builder
        (live.compiler-live-set-max
          (live.compiler-live-set-max (live.compiler-live-set-max a b) c)
          (live.compiler-live-set-max d e)))]
    (begin
      (live.compiler-live-set-builder-insert! words a)
      (live.compiler-live-set-builder-insert! words b)
      (live.compiler-live-set-builder-insert! words c)
      (live.compiler-live-set-builder-insert! words d)
      (live.compiler-live-set-builder-insert! words e)
      (live.CompilerLiveI64Set words))))

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
    (begin
      (live.compiler-live-set-builder-insert! words a)
      (live.compiler-live-set-builder-insert! words b)
      (live.compiler-live-set-builder-insert! words c)
      (live.compiler-live-set-builder-insert! words d)
      (live.compiler-live-set-builder-insert! words e)
      (live.compiler-live-set-builder-insert! words f)
      (live.CompilerLiveI64Set words))))

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
    (begin
      (live.compiler-live-set-builder-insert! words a)
      (live.compiler-live-set-builder-insert! words b)
      (live.compiler-live-set-builder-insert! words c)
      (live.compiler-live-set-builder-insert! words d)
      (live.compiler-live-set-builder-insert! words e)
      (live.compiler-live-set-builder-insert! words f)
      (live.compiler-live-set-builder-insert! words g)
      (live.CompilerLiveI64Set words))))

(define (compiler-live-set-ops-ok?) : bool
  (let
    [empty : live.CompilerLiveI64Set (live.compiler-live-set-empty)]
    [with-negative : live.CompilerLiveI64Set
      (live.compiler-live-set-insert empty -4)]
    [a : live.CompilerLiveI64Set (live.compiler-live-set4 0 31 32 66)]
    [b : live.CompilerLiveI64Set (live.compiler-live-set4 66 32 31 0)]
    [removed : live.CompilerLiveI64Set (live.compiler-live-set-remove a 31)]
    [unioned : live.CompilerLiveI64Set
      (live.compiler-live-set-union removed (live.compiler-live-set2 31 65))]
    [minus : live.CompilerLiveI64Set
      (live.compiler-live-set-minus unioned (live.compiler-live-set2 0 65))]
    [trimmed : live.CompilerLiveI64Set
      (live.compiler-live-set-remove (live.compiler-live-set-remove a 66) 32)]
    [deduplicated : live.CompilerLiveI64Set
      (live.compiler-live-set4 -1 31 31 66)]
    [ok : bool true]
    (begin
      (set! ok (and ok (live.compiler-live-set-eq? empty with-negative)))
      (set! ok (and ok (= (live.compiler-live-set-count a) 4)))
      (set! ok (and ok (live.compiler-live-set-contains? a 0)))
      (set! ok (and ok (live.compiler-live-set-contains? a 31)))
      (set! ok (and ok (live.compiler-live-set-contains? a 32)))
      (set! ok (and ok (live.compiler-live-set-contains? a 66)))
      (set! ok (and ok (not (live.compiler-live-set-contains? a -1))))
      (set! ok (and ok (not (live.compiler-live-set-contains? a 33))))
      (set! ok (and ok (live.compiler-live-set-eq? a b)))
      (set!
        ok
        (and
          ok
          (= (live.compiler-live-set-score a) (live.compiler-live-set-score b))))
      (set! ok (and ok (= (live.compiler-live-set-count removed) 3)))
      (set! ok (and ok (not (live.compiler-live-set-contains? removed 31))))
      (set! ok (and ok (= (live.compiler-live-set-count unioned) 5)))
      (set!
        ok
        (and
          ok
          (live.compiler-live-set-eq? minus (live.compiler-live-set3 31 32 66))))
      (set! ok (and ok (= (live.compiler-live-set-count trimmed) 2)))
      (set! ok (and ok (= (live.compiler-live-set-word-count trimmed) 1)))
      (set!
        ok
        (and
          ok
          (live.compiler-live-set-eq?
            deduplicated
            (live.compiler-live-set2 31 66))))
      ok)))

(define (compiler-live-scratch-ops-ok?) : bool
  (let
    [words : (__tl_dyn-array i64) (make-array i64 6)]
    [copy-count : i64
      (live.compiler-live-scratch-copy-set!
        words
        (live.compiler-live-set3 1 64 130))]
    [copy-ok : bool
      (and
        (= copy-count 5)
        (live.compiler-live-scratch-eq-set?
          words
          copy-count
          (live.compiler-live-set3 1 64 130)))]
    [union-count : i64
      (live.compiler-live-scratch-union-set!
        words
        copy-count
        (live.compiler-live-set2 65 191))]
    [union-ok : bool
      (and
        (= union-count 6)
        (live.compiler-live-scratch-eq-set?
          words
          union-count
          (compiler-live-set5 1 64 65 130 191)))]
    [step-count : i64
      (live.compiler-live-scratch-step!
        words
        union-count
        (live.compiler-live-set1 0)
        (live.compiler-live-set2 1 130))]
    [step-ok : bool
      (and
        (= step-count 6)
        (live.compiler-live-scratch-eq-set?
          words
          step-count
          (live.compiler-live-set4 0 64 65 191))
        (live.compiler-live-set-eq?
          (live.compiler-live-scratch-freeze words step-count)
          (live.compiler-live-set4 0 64 65 191)))]
    [short-count : i64
      (live.compiler-live-scratch-copy-set! words (live.compiler-live-set1 7))]
    [short-ok : bool
      (and
        (= short-count 1)
        (live.compiler-live-scratch-eq-set?
          words
          short-count
          (live.compiler-live-set1 7))
        (= (live.compiler-live-set-trim-length words 6) 1))]
    [_cleared : unit (live.compiler-live-scratch-clear! words)]
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
    [defs : live.CompilerLiveI64Set (live.compiler-live-instr-defs instr)]
    [def-var : i64 (live.compiler-live-instr-def-var instr)]
    [ids : (__tl_dyn-array i64) (live.compiler-live-instr-ids)]
    [id-count : i64 (live.compiler-live-instr-use-ids! instr)]
    [index : i64 0]
    [ok : bool (= id-count (live.compiler-live-set-count uses))]
    (begin
      (while (< index id-count)
        (begin
          (if (live.compiler-live-set-contains? uses (array-ref ids index))
            unit
            (set! ok false))
          (set! index (+ index 1))))
      (and
        ok
        (=
          (live.compiler-live-set-count defs)
          (if (< def-var 0)
            0
            1))
        (or (< def-var 0) (live.compiler-live-set-contains? defs def-var))))))

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
  (let
    [builder : ir.CompilerIrInstrBuilder
      (ir.compiler-ir-instr-builder-with-capacity 9)]
    (begin
      (ir.compiler-ir-instr-builder-push!
        (&mut builder)
        (ir.CompilerIrInstr.Mov
          0
          (ir.CompilerIrValue.Var 10)
          (compiler-live-i64-ty)))
      (ir.compiler-ir-instr-builder-push!
        (&mut builder)
        (ir.CompilerIrInstr.BinOp
          1
          ir.CompilerIrBinOp.Add
          (ir.CompilerIrValue.Var 7)
          (ir.CompilerIrValue.Var 7)
          (compiler-live-i64-ty)))
      (ir.compiler-ir-instr-builder-push!
        (&mut builder)
        (ir.CompilerIrInstr.AddrOf 2 33))
      (ir.compiler-ir-instr-builder-push!
        (&mut builder)
        (ir.CompilerIrInstr.Gep
          3
          (ir.CompilerIrValue.Var 40)
          (ir.CompilerIrValue.I64 8)
          (compiler-live-i64-ty)))
      (ir.compiler-ir-instr-builder-push!
        (&mut builder)
        (ir.CompilerIrInstr.Call
          4
          (ir.compiler-ir-test-symbol "f")
          (ir.CompilerIrCallArgs.Two
            (ir.CompilerIrValue.Var 41)
            (ir.CompilerIrValue.Var 41))
          (compiler-live-i64-ty)))
      (ir.compiler-ir-instr-builder-push!
        (&mut builder)
        (ir.CompilerIrInstr.Pack
          5
          (ir.compiler-ir-value-cons
            (ir.CompilerIrValue.Var 42)
            (ir.compiler-ir-value-cons
              (ir.CompilerIrValue.Var 43)
              ir.CompilerIrValueList.Nil))
          (compiler-live-i64-ty)))
      (ir.compiler-ir-instr-builder-push!
        (&mut builder)
        (ir.CompilerIrInstr.Phi
          6
          (ir.compiler-ir-phi-input-cons
            (ir.CompilerIrValue.Var 44)
            (ir.compiler-ir-label "a")
            (ir.compiler-ir-phi-input-cons
              (ir.CompilerIrValue.Var 44)
              (ir.compiler-ir-label "b")
              ir.CompilerIrPhiInputList.Nil))
          (compiler-live-i64-ty)))
      (ir.compiler-ir-instr-builder-push!
        (&mut builder)
        (ir.CompilerIrInstr.StorePtr
          (ir.CompilerIrValue.Var 45)
          (ir.CompilerIrValue.Var 46)
          (compiler-live-i64-ty)))
      (ir.compiler-ir-instr-builder-push!
        (&mut builder)
        (ir.CompilerIrInstr.Branch
          (ir.CompilerIrValue.Var 47)
          (ir.compiler-ir-label "a")
          (ir.compiler-ir-label "b")))
      (ir.compiler-ir-instr-builder-to-seq builder))))

;; The two id-driven scratch steps must leave the row -- and the trimmed active
;; count -- exactly where the bitset forms leave them.
(define (compiler-live-step-ids-ok?) : bool
  (let
    [set-words : (__tl_dyn-array i64) (make-array i64 6)]
    [id-words : (__tl_dyn-array i64) (make-array i64 6)]
    [ids : (__tl_dyn-array i64) (make-array i64 4)]
    [set-use-words : (__tl_dyn-array i64) (make-array i64 6)]
    [set-def-words : (__tl_dyn-array i64) (make-array i64 6)]
    [id-use-words : (__tl_dyn-array i64) (make-array i64 6)]
    [id-def-words : (__tl_dyn-array i64) (make-array i64 6)]
    [seed : live.CompilerLiveI64Set (live.compiler-live-set3 1 64 130)]
    [set-active : i64 (live.compiler-live-scratch-copy-set! set-words seed)]
    [id-active : i64 (live.compiler-live-scratch-copy-set! id-words seed)]
    ;; `130` is used and defined here, and `1` is only defined: the def clear
    ;; must lose `1`, the use must keep `130`, and the row must grow to hold the
    ;; new use `191`.
    [_ids-fill : unit
      (begin
        (set! (array-ref ids 0) 130)
        (set! (array-ref ids 1) 191))]
    [set-count : i64
      (live.compiler-live-scratch-step!
        set-words
        set-active
        (live.compiler-live-set2 130 191)
        (live.compiler-live-set1 1))]
    [id-count : i64
      (live.compiler-live-scratch-step-ids! id-words id-active ids 2 1)]
    [step-ok : bool
      (and
        (= set-count id-count)
        (live.compiler-live-set-eq?
          (live.compiler-live-scratch-freeze set-words set-count)
          (live.compiler-live-scratch-freeze id-words id-count)))]
    ;; The block use/def accumulation: `9` is already defined by an earlier
    ;; instruction, so using it here must NOT make it a block use; `70` must.
    [_seed-defs : unit
      (begin
        (live.compiler-live-set-builder-insert! set-def-words 9)
        (live.compiler-live-set-builder-insert! id-def-words 9))]
    [_step2-ids : unit
      (begin
        (set! (array-ref ids 0) 9)
        (set! (array-ref ids 1) 70))]
    [_set-step : unit
      (live.compiler-live-block-use-def-step!
        set-use-words
        set-def-words
        (live.compiler-live-set2 9 70)
        (live.compiler-live-set1 130))]
    [_id-step : unit
      (live.compiler-live-block-use-def-step-ids!
        id-use-words
        id-def-words
        ids
        2
        130)]
    [use-def-ok : bool
      (and
        (live.compiler-live-set-eq?
          (live.compiler-live-scratch-freeze set-use-words 6)
          (live.compiler-live-set1 70))
        (live.compiler-live-set-eq?
          (live.compiler-live-scratch-freeze set-use-words 6)
          (live.compiler-live-scratch-freeze id-use-words 6))
        (live.compiler-live-set-eq?
          (live.compiler-live-scratch-freeze set-def-words 6)
          (live.compiler-live-scratch-freeze id-def-words 6)))]
    ;; A use list wider than the buffer reports -1 so the caller can fall back.
    [narrow : (__tl_dyn-array i64) (make-array i64 1)]
    [overflow-ok : bool
      (=
        (live.compiler-live-instr-use-ids-into!
          (ir.CompilerIrInstr.StorePtr
            (ir.CompilerIrValue.Var 3)
            (ir.CompilerIrValue.Var 4)
            (compiler-live-i64-ty))
          narrow)
        -1)]
    (and
      step-ok
      use-def-ok
      overflow-ok
      (compiler-live-instr-ids-seq-match-set? (compiler-live-ids-sample-instrs)))))

(define (compiler-live-i64-ty) : ast.AstType
  (ast.AstType.I64))

(define (compiler-live-instr-seq6
  [first : ir.CompilerIrInstr]
  [second : ir.CompilerIrInstr]
  [third : ir.CompilerIrInstr]
  [fourth : ir.CompilerIrInstr]
  [fifth : ir.CompilerIrInstr]
  [sixth : ir.CompilerIrInstr]) : ir.CompilerIrInstrSeq
  (let
    [slots : (__tl_dyn-array ir.CompilerIrInstr)
      (make-array ir.CompilerIrInstr 6)]
    (begin
      (set! (array-ref slots 0) first)
      (set! (array-ref slots 1) second)
      (set! (array-ref slots 2) third)
      (set! (array-ref slots 3) fourth)
      (set! (array-ref slots 4) fifth)
      (set! (array-ref slots 5) sixth)
      (ir.CompilerIrInstrSeq slots 6))))

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
      (make-array ir.CompilerIrInstr 7)]
    (begin
      (set! (array-ref slots 0) first)
      (set! (array-ref slots 1) second)
      (set! (array-ref slots 2) third)
      (set! (array-ref slots 3) fourth)
      (set! (array-ref slots 4) fifth)
      (set! (array-ref slots 5) sixth)
      (set! (array-ref slots 6) seventh)
      (ir.CompilerIrInstrSeq slots 7))))

(define (compiler-live-instr-seq8
  [first : ir.CompilerIrInstr]
  [second : ir.CompilerIrInstr]
  [third : ir.CompilerIrInstr]
  [fourth : ir.CompilerIrInstr]
  [fifth : ir.CompilerIrInstr]
  [sixth : ir.CompilerIrInstr]
  [seventh : ir.CompilerIrInstr]
  [eighth : ir.CompilerIrInstr]) : ir.CompilerIrInstrSeq
  (let
    [slots : (__tl_dyn-array ir.CompilerIrInstr)
      (make-array ir.CompilerIrInstr 8)]
    (begin
      (set! (array-ref slots 0) first)
      (set! (array-ref slots 1) second)
      (set! (array-ref slots 2) third)
      (set! (array-ref slots 3) fourth)
      (set! (array-ref slots 4) fifth)
      (set! (array-ref slots 5) sixth)
      (set! (array-ref slots 6) seventh)
      (set! (array-ref slots 7) eighth)
      (ir.CompilerIrInstrSeq slots 8))))

(define (compiler-live-straight-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "straight")
    ir.CompilerIrParamList.Nil
    (compiler-live-i64-ty)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (ir.compiler-ir-instr-seq3
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.I64 1)
            (compiler-live-i64-ty))
          (ir.CompilerIrInstr.BinOp
            1
            ir.CompilerIrBinOp.Add
            (ir.CompilerIrValue.Var 0)
            (ir.CompilerIrValue.Var 2)
            (compiler-live-i64-ty))
          (ir.CompilerIrInstr.Return
            (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 1)))))
      ir.CompilerIrBlockList.Nil)))

(define (compiler-live-branch-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "branch")
    ir.CompilerIrParamList.Nil
    (compiler-live-i64-ty)
    3
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (ir.compiler-ir-instr-seq1
          (ir.CompilerIrInstr.Branch
            (ir.CompilerIrValue.Var 0)
            (ir.compiler-ir-label "then")
            (ir.compiler-ir-label "else"))))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "then")
          (ir.compiler-ir-instr-seq1
            (ir.CompilerIrInstr.Return
              (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 1)))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "else")
            (ir.compiler-ir-instr-seq1
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))))
          ir.CompilerIrBlockList.Nil)))))

(define (compiler-live-phi-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (ir.compiler-ir-test-symbol "phi")
    ir.CompilerIrParamList.Nil
    (compiler-live-i64-ty)
    4
    (ir.compiler-ir-block-cons
      (ir.CompilerIrBlock.Block
        (ir.compiler-ir-label "entry")
        (ir.compiler-ir-instr-seq1
          (ir.CompilerIrInstr.Branch
            (ir.CompilerIrValue.Var 0)
            (ir.compiler-ir-label "left")
            (ir.compiler-ir-label "right"))))
      (ir.compiler-ir-block-cons
        (ir.CompilerIrBlock.Block
          (ir.compiler-ir-label "left")
          (ir.compiler-ir-instr-seq2
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.I64 10)
              (compiler-live-i64-ty))
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "join"))))
        (ir.compiler-ir-block-cons
          (ir.CompilerIrBlock.Block
            (ir.compiler-ir-label "right")
            (ir.compiler-ir-instr-seq2
              (ir.CompilerIrInstr.Mov
                2
                (ir.CompilerIrValue.I64 20)
                (compiler-live-i64-ty))
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "join"))))
          (ir.compiler-ir-block-cons
            (ir.CompilerIrBlock.Block
              (ir.compiler-ir-label "join")
              (ir.compiler-ir-instr-seq2
                (ir.CompilerIrInstr.Phi
                  3
                  (ir.compiler-ir-phi-input-cons
                    (ir.CompilerIrValue.Var 1)
                    (ir.compiler-ir-label "left")
                    (ir.compiler-ir-phi-input-cons
                      (ir.CompilerIrValue.Var 2)
                      (ir.compiler-ir-label "right")
                      ir.CompilerIrPhiInputList.Nil))
                  (compiler-live-i64-ty))
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 3)))))
            ir.CompilerIrBlockList.Nil))))))

(define (compiler-live-use-def-ok?) : bool
  (let
    [use-def : live.CompilerLiveUseDef
      (live.compiler-live-block-use-def
        (compiler-live-instr-seq8
          (ir.CompilerIrInstr.Mov
            0
            (ir.CompilerIrValue.Var 10)
            (compiler-live-i64-ty))
          (ir.CompilerIrInstr.BinOp
            1
            ir.CompilerIrBinOp.Add
            (ir.CompilerIrValue.Var 0)
            (ir.CompilerIrValue.Var 11)
            (compiler-live-i64-ty))
          (ir.CompilerIrInstr.UnOp
            2
            ir.CompilerIrUnOp.Neg
            (ir.CompilerIrValue.Var 12)
            (compiler-live-i64-ty))
          (ir.CompilerIrInstr.Call
            3
            (ir.compiler-ir-test-symbol "f")
            (ir.CompilerIrCallArgs.Two
              (ir.CompilerIrValue.Var 1)
              (ir.CompilerIrValue.Var 13))
            (compiler-live-i64-ty))
          (ir.CompilerIrInstr.Store
            (ir.compiler-ir-test-symbol "g")
            (ir.CompilerIrValue.Var 14)
            (compiler-live-i64-ty))
          (ir.CompilerIrInstr.Branch
            (ir.CompilerIrValue.Var 15)
            (ir.compiler-ir-label "a")
            (ir.compiler-ir-label "b"))
          (ir.CompilerIrInstr.Phi
            4
            (ir.compiler-ir-phi-input-cons
              (ir.CompilerIrValue.Var 16)
              (ir.compiler-ir-label "a")
              ir.CompilerIrPhiInputList.Nil)
            (compiler-live-i64-ty))
          (ir.CompilerIrInstr.Return
            (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 4)))))]
    (and
      (live.compiler-live-set-eq?
        use-def.uses
        (compiler-live-set7 10 11 12 13 14 15 16))
      (live.compiler-live-set-eq? use-def.defs (compiler-live-set5 0 1 2 3 4)))))

(define (compiler-live-memory-use-def-ok?) : bool
  (let
    [use-def : live.CompilerLiveUseDef
      (live.compiler-live-block-use-def
        (compiler-live-instr-seq6
          (ir.CompilerIrInstr.Alloc 0 (compiler-live-i64-ty))
          (ir.CompilerIrInstr.AddrOf 1 0)
          (ir.CompilerIrInstr.Gep
            2
            (ir.CompilerIrValue.Var 1)
            (ir.CompilerIrValue.Var 10)
            (compiler-live-i64-ty))
          (ir.CompilerIrInstr.Load
            3
            (ir.CompilerIrValue.Var 2)
            (compiler-live-i64-ty))
          (ir.CompilerIrInstr.StorePtr
            (ir.CompilerIrValue.Var 2)
            (ir.CompilerIrValue.Var 11)
            (compiler-live-i64-ty))
          (ir.CompilerIrInstr.Cast
            4
            (ir.CompilerIrValue.Var 3)
            (compiler-live-i64-ty)
            (ast.AstType.I32))))]
    (and
      (live.compiler-live-set-eq? use-def.uses (live.compiler-live-set2 10 11))
      (live.compiler-live-set-eq? use-def.defs (compiler-live-set5 0 1 2 3 4)))))

(define (compiler-live-vector-mask-use-def-ok?) : bool
  (let
    [use-def : live.CompilerLiveUseDef
      (live.compiler-live-block-use-def
        (compiler-live-instr-seq7
          (ir.CompilerIrInstr.LaneId 0 4 (compiler-live-i64-ty))
          (ir.CompilerIrInstr.Splat
            1
            (ir.CompilerIrValue.Var 10)
            4
            (compiler-live-i64-ty))
          (ir.ir-instr-vector-bin-op
            2
            (ir.CompilerIrBinOp.Add)
            (ir.CompilerIrValue.Var 0)
            (ir.CompilerIrValue.Var 1)
            4
            (compiler-live-i64-ty))
          (ir.CompilerIrInstr.TailMask
            3
            (ir.CompilerIrValue.Var 11)
            (ir.CompilerIrValue.Var 12)
            4)
          (ir.ir-instr-predicated-load
            4
            (ir.CompilerIrValue.Var 13)
            (ir.CompilerIrValue.Var 11)
            (ir.CompilerIrValue.Var 3)
            4
            (compiler-live-i64-ty))
          (ir.ir-instr-predicated-store
            (ir.CompilerIrValue.Var 14)
            (ir.CompilerIrValue.Var 11)
            (ir.CompilerIrValue.Var 2)
            (ir.CompilerIrValue.Var 3)
            4
            (compiler-live-i64-ty))
          (ir.CompilerIrInstr.MaskReduce
            5
            (ir.CompilerIrMaskReduceOp.Any)
            (ir.CompilerIrValue.Var 3)
            4)))]
    (and
      (live.compiler-live-set-eq?
        use-def.uses
        (compiler-live-set5 10 11 12 13 14))
      (live.compiler-live-set-eq? use-def.defs (compiler-live-set6 0 1 2 3 4 5)))))

(define (compiler-live-straight-ok?) : bool
  (let
    [liveness : live.CompilerFunctionLiveness
      (live.compiler-live-analyze-function (compiler-live-straight-function))]
    (match (live.compiler-live-function-find-block
      liveness
      (ir.compiler-ir-label "entry"))
      [(live.CompilerLiveMaybeBlock.Some block)
        (and
          (live.compiler-live-set-eq?
            (live.compiler-live-block-uses block)
            (live.compiler-live-set1 2))
          (live.compiler-live-set-eq?
            (live.compiler-live-block-defs block)
            (live.compiler-live-set2 0 1))
          (live.compiler-live-set-eq?
            (live.compiler-live-block-live-in block)
            (live.compiler-live-set1 2))
          (live.compiler-live-set-eq?
            (live.compiler-live-block-live-out block)
            (live.compiler-live-set-empty))
          (live.compiler-live-set-eq?
            (live.compiler-live-after liveness (ir.compiler-ir-label "entry") 0)
            (live.compiler-live-set2 0 2))
          (live.compiler-live-set-eq?
            (live.compiler-live-after liveness (ir.compiler-ir-label "entry") 1)
            (live.compiler-live-set1 1))
          (live.compiler-live-set-eq?
            (live.compiler-live-after liveness (ir.compiler-ir-label "entry") 2)
            (live.compiler-live-set-empty)))]
      [(live.CompilerLiveMaybeBlock.No) false])))

(define (compiler-live-branch-ok?) : bool
  (let
    [liveness : live.CompilerFunctionLiveness
      (live.compiler-live-analyze-function (compiler-live-branch-function))]
    (match (live.compiler-live-function-find-block
      liveness
      (ir.compiler-ir-label "entry"))
      [(live.CompilerLiveMaybeBlock.Some block)
        (and
          (=
            (live.compiler-live-label-set-count
              (live.compiler-live-block-successor-labels block))
            2)
          (live.compiler-live-label-set-contains?
            (live.compiler-live-block-successor-labels block)
            (ir.compiler-ir-label "then"))
          (live.compiler-live-label-set-contains?
            (live.compiler-live-block-successor-labels block)
            (ir.compiler-ir-label "else"))
          (live.compiler-live-set-eq?
            (live.compiler-live-block-live-in block)
            (live.compiler-live-set3 0 1 2)))]
      [(live.CompilerLiveMaybeBlock.No) false])))

(define (compiler-live-phi-ok?) : bool
  (let
    [liveness : live.CompilerFunctionLiveness
      (live.compiler-live-analyze-function (compiler-live-phi-function))]
    (match (live.compiler-live-function-find-block
      liveness
      (ir.compiler-ir-label "join"))
      [(live.CompilerLiveMaybeBlock.Some block)
        (and
          (live.compiler-live-set-eq?
            (live.compiler-live-block-uses block)
            (live.compiler-live-set2 1 2))
          (live.compiler-live-set-eq?
            (live.compiler-live-block-defs block)
            (live.compiler-live-set1 3))
          (live.compiler-live-set-eq?
            (live.compiler-live-block-live-in block)
            (live.compiler-live-set2 1 2))
          (live.compiler-live-set-eq?
            (live.compiler-live-after liveness (ir.compiler-ir-label "join") 0)
            (live.compiler-live-set1 3))
          (match (live.compiler-live-function-find-block
            liveness
            (ir.compiler-ir-label "left"))
            [(live.CompilerLiveMaybeBlock.Some left-block)
              (live.compiler-live-label-set-contains?
                (live.compiler-live-block-successor-labels left-block)
                (ir.compiler-ir-label "join"))]
            [(live.CompilerLiveMaybeBlock.No) false]))]
      [(live.CompilerLiveMaybeBlock.No) false])))

(define (compiler-live-phi-edge-precise-ok?) : bool
  (let
    [baseline : live.CompilerFunctionLiveness
      (live.compiler-live-analyze-function (compiler-live-phi-function))]
    [edge-precise : live.CompilerFunctionLiveness
      (live.compiler-live-analyze-function-edge-precise
        (compiler-live-phi-function))]
    (match (live.compiler-live-function-find-block
      baseline
      (ir.compiler-ir-label "join"))
      [(live.CompilerLiveMaybeBlock.Some baseline-join)
        (match (live.compiler-live-function-find-block
          edge-precise
          (ir.compiler-ir-label "join"))
          [(live.CompilerLiveMaybeBlock.Some edge-precise-join)
            (match (live.compiler-live-function-find-block
              baseline
              (ir.compiler-ir-label "left"))
              [(live.CompilerLiveMaybeBlock.Some baseline-left)
                (match (live.compiler-live-function-find-block
                  edge-precise
                  (ir.compiler-ir-label "left"))
                  [(live.CompilerLiveMaybeBlock.Some edge-precise-left)
                    (match (live.compiler-live-function-find-block
                      edge-precise
                      (ir.compiler-ir-label "right"))
                      [(live.CompilerLiveMaybeBlock.Some edge-precise-right)
                        (and
                          (live.compiler-live-set-eq?
                            (live.compiler-live-block-uses baseline-join)
                            (live.compiler-live-set2 1 2))
                          (live.compiler-live-set-eq?
                            (live.compiler-live-block-uses edge-precise-join)
                            (live.compiler-live-set-empty))
                          (live.compiler-live-set-eq?
                            (live.compiler-live-block-live-in edge-precise-join)
                            (live.compiler-live-set-empty))
                          (live.compiler-live-set-eq?
                            (live.compiler-live-block-live-out baseline-left)
                            (live.compiler-live-set2 1 2))
                          (live.compiler-live-set-eq?
                            (live.compiler-live-block-live-out
                              edge-precise-left)
                            (live.compiler-live-set1 1))
                          (live.compiler-live-set-eq?
                            (live.compiler-live-block-live-out
                              edge-precise-right)
                            (live.compiler-live-set1 2)))]
                      [(live.CompilerLiveMaybeBlock.No) false])]
                  [(live.CompilerLiveMaybeBlock.No) false])]
              [(live.CompilerLiveMaybeBlock.No) false])]
          [(live.CompilerLiveMaybeBlock.No) false])]
      [(live.CompilerLiveMaybeBlock.No) false])))

(define (compiler-live-switch-ok?) : bool
  (let
    [cases : ir.CompilerIrSwitchCaseList
      (ir.compiler-ir-switch-case-cons
        4
        (ir.compiler-ir-label "four")
        (ir.compiler-ir-switch-case-cons
          5
          (ir.compiler-ir-label "five")
          ir.CompilerIrSwitchCaseList.Nil))]
    [instr : ir.CompilerIrInstr
      (ir.CompilerIrInstr.Switch
        (ir.CompilerIrValue.Var 9)
        4
        cases
        (ir.compiler-ir-label "other"))]
    [instrs : ir.CompilerIrInstrSeq (ir.compiler-ir-instr-seq1 instr)]
    [block : ir.CompilerIrBlock
      (ir.CompilerIrBlock.Block (ir.compiler-ir-label "entry") instrs)]
    [successors : live.CompilerLiveLabelSet
      (live.compiler-live-block-successors block)]
    [use-def : live.CompilerLiveUseDef
      (live.compiler-live-block-use-def instrs)]
    (and
      (live.compiler-live-set-eq? use-def.uses (live.compiler-live-set1 9))
      (live.compiler-live-set-eq? use-def.defs (live.compiler-live-set-empty))
      (= (live.compiler-live-label-set-count successors) 3)
      (live.compiler-live-label-set-contains?
        successors
        (ir.compiler-ir-label "four"))
      (live.compiler-live-label-set-contains?
        successors
        (ir.compiler-ir-label "five"))
      (live.compiler-live-label-set-contains?
        successors
        (ir.compiler-ir-label "other")))))

(define (compiler-live-self-test) : i64
  (if (and
    (compiler-live-set-ops-ok?)
    (compiler-live-scratch-ops-ok?)
    (compiler-live-step-ids-ok?)
    (compiler-live-use-def-ok?)
    (compiler-live-memory-use-def-ok?)
    (compiler-live-vector-mask-use-def-ok?)
    (compiler-live-straight-ok?)
    (compiler-live-branch-ok?)
    (compiler-live-phi-ok?)
    (compiler-live-phi-edge-precise-ok?)
    (compiler-live-switch-ok?))
    42
    (io.panic "liveness: smoke mismatch")))