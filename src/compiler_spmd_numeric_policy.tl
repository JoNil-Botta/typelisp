;; compiler_spmd_numeric_policy.tl - Canonical SPMD numeric admission matrix.
;;
;; Keep numeric operation/cast admission above IR and serialization.  Planning
;; queries consume this closed description; diagnostic strings are rendered
;; only after a query reports Unsupported.
(import compiler_ast_types as ast)
(cfg test (import stdlib.io))

(defenum CompilerSpmdNumericLane
  (I8)
  (U8)
  (I16)
  (U16)
  (I32)
  (U32)
  (I64)
  (U64)
  (F32)
  (F64)
  ;; Bool is a supported SPMD value lane, but not a numeric lane.
  (Bool)
  ;; Char participates in scalar casts but is deliberately excluded from the
  ;; public SPMD numeric lane set.
  (Char)
  (Other))

(defenum CompilerSpmdNumericContext
  (DirectMap)
  (FusedReduction)
  (MaskedControl)
  (InlineHelper)
  (PrivateHelper))

(defenum CompilerSpmdNumericBackend
  (Scalar)
  (Avx2)
  (Avx512))

(defenum CompilerSpmdNumericOperation
  (Binary ast.AstBinOp)
  (Conversion))

(defenum CompilerSpmdNumericStrategy
  (ScalarReference)
  (NativePacked)
  (OwnedVectorExpansion)
  (CheckedActiveLaneExpansion)
  ;; The direct planner delegates this row to the mask-capable planner.
  (MaskedPlannerExpansion)
  (Unsupported))

(defstruct CompilerSpmdNumericDecision
  (source CompilerSpmdNumericLane)
  (destination CompilerSpmdNumericLane)
  (context CompilerSpmdNumericContext)
  (backend CompilerSpmdNumericBackend)
  (operation CompilerSpmdNumericOperation)
  (strategy CompilerSpmdNumericStrategy))

(define (compiler-spmd-numeric-lane [ty : ast.AstType]) : CompilerSpmdNumericLane
  (match ty
    [(ast.AstType.I8) (CompilerSpmdNumericLane.I8)]
    [(ast.AstType.U8) (CompilerSpmdNumericLane.U8)]
    [(ast.AstType.I16) (CompilerSpmdNumericLane.I16)]
    [(ast.AstType.U16) (CompilerSpmdNumericLane.U16)]
    [(ast.AstType.I32) (CompilerSpmdNumericLane.I32)]
    [(ast.AstType.U32) (CompilerSpmdNumericLane.U32)]
    [(ast.AstType.I64) (CompilerSpmdNumericLane.I64)]
    [(ast.AstType.U64) (CompilerSpmdNumericLane.U64)]
    [(ast.AstType.F32) (CompilerSpmdNumericLane.F32)]
    [(ast.AstType.F64) (CompilerSpmdNumericLane.F64)]
    [(ast.AstType.Bool) (CompilerSpmdNumericLane.Bool)]
    [(ast.AstType.Char) (CompilerSpmdNumericLane.Char)]
    [_ (CompilerSpmdNumericLane.Other)]))

(define (compiler-spmd-numeric-lane? [lane : CompilerSpmdNumericLane]) : bool
  (match lane
    [(CompilerSpmdNumericLane.I8) true]
    [(CompilerSpmdNumericLane.U8) true]
    [(CompilerSpmdNumericLane.I16) true]
    [(CompilerSpmdNumericLane.U16) true]
    [(CompilerSpmdNumericLane.I32) true]
    [(CompilerSpmdNumericLane.U32) true]
    [(CompilerSpmdNumericLane.I64) true]
    [(CompilerSpmdNumericLane.U64) true]
    [(CompilerSpmdNumericLane.F32) true]
    [(CompilerSpmdNumericLane.F64) true]
    [(CompilerSpmdNumericLane.Bool) false]
    [(CompilerSpmdNumericLane.Char) false]
    [(CompilerSpmdNumericLane.Other) false]))

(define (compiler-spmd-numeric-integer-lane? [lane : CompilerSpmdNumericLane]) : bool
  (match lane
    [(CompilerSpmdNumericLane.I8) true]
    [(CompilerSpmdNumericLane.U8) true]
    [(CompilerSpmdNumericLane.I16) true]
    [(CompilerSpmdNumericLane.U16) true]
    [(CompilerSpmdNumericLane.I32) true]
    [(CompilerSpmdNumericLane.U32) true]
    [(CompilerSpmdNumericLane.I64) true]
    [(CompilerSpmdNumericLane.U64) true]
    [(CompilerSpmdNumericLane.F32) false]
    [(CompilerSpmdNumericLane.F64) false]
    [(CompilerSpmdNumericLane.Bool) false]
    [(CompilerSpmdNumericLane.Char) false]
    [(CompilerSpmdNumericLane.Other) false]))

(define (compiler-spmd-numeric-lane-eq?
  [left : CompilerSpmdNumericLane]
  [right : CompilerSpmdNumericLane]) : bool
  (match left
    [(CompilerSpmdNumericLane.I8)
      (match right
        [(CompilerSpmdNumericLane.I8) true]
        [_ false])]
    [(CompilerSpmdNumericLane.U8)
      (match right
        [(CompilerSpmdNumericLane.U8) true]
        [_ false])]
    [(CompilerSpmdNumericLane.I16)
      (match right
        [(CompilerSpmdNumericLane.I16) true]
        [_ false])]
    [(CompilerSpmdNumericLane.U16)
      (match right
        [(CompilerSpmdNumericLane.U16) true]
        [_ false])]
    [(CompilerSpmdNumericLane.I32)
      (match right
        [(CompilerSpmdNumericLane.I32) true]
        [_ false])]
    [(CompilerSpmdNumericLane.U32)
      (match right
        [(CompilerSpmdNumericLane.U32) true]
        [_ false])]
    [(CompilerSpmdNumericLane.I64)
      (match right
        [(CompilerSpmdNumericLane.I64) true]
        [_ false])]
    [(CompilerSpmdNumericLane.U64)
      (match right
        [(CompilerSpmdNumericLane.U64) true]
        [_ false])]
    [(CompilerSpmdNumericLane.F32)
      (match right
        [(CompilerSpmdNumericLane.F32) true]
        [_ false])]
    [(CompilerSpmdNumericLane.F64)
      (match right
        [(CompilerSpmdNumericLane.F64) true]
        [_ false])]
    [(CompilerSpmdNumericLane.Bool)
      (match right
        [(CompilerSpmdNumericLane.Bool) true]
        [_ false])]
    [(CompilerSpmdNumericLane.Char)
      (match right
        [(CompilerSpmdNumericLane.Char) true]
        [_ false])]
    [(CompilerSpmdNumericLane.Other)
      (match right
        [(CompilerSpmdNumericLane.Other) true]
        [_ false])]))

(define (compiler-spmd-numeric-comparison-op? [op : ast.AstBinOp]) : bool
  (match op
    [(ast.AstBinOp.Eq) true]
    [(ast.AstBinOp.Ne) true]
    [(ast.AstBinOp.Lt) true]
    [(ast.AstBinOp.Le) true]
    [(ast.AstBinOp.Gt) true]
    [(ast.AstBinOp.Ge) true]
    [(ast.AstBinOp.Add) false]
    [(ast.AstBinOp.Sub) false]
    [(ast.AstBinOp.Mul) false]
    [(ast.AstBinOp.Div) false]
    [(ast.AstBinOp.Mod) false]
    [(ast.AstBinOp.And) false]
    [(ast.AstBinOp.Or) false]
    [(ast.AstBinOp.BitAnd) false]
    [(ast.AstBinOp.BitOr) false]
    [(ast.AstBinOp.BitXor) false]
    [(ast.AstBinOp.Shl) false]
    [(ast.AstBinOp.Shr) false]))

(define (compiler-spmd-numeric-simd-binary-strategy
  [source : CompilerSpmdNumericLane]
  [context : CompilerSpmdNumericContext]
  [op : ast.AstBinOp]) : CompilerSpmdNumericStrategy
  (match op
    [(ast.AstBinOp.Add) (CompilerSpmdNumericStrategy.NativePacked)]
    [(ast.AstBinOp.Sub) (CompilerSpmdNumericStrategy.NativePacked)]
    [(ast.AstBinOp.Mul)
      (match source
        [(CompilerSpmdNumericLane.I8)
          (CompilerSpmdNumericStrategy.OwnedVectorExpansion)]
        [(CompilerSpmdNumericLane.U8)
          (CompilerSpmdNumericStrategy.OwnedVectorExpansion)]
        [_ (CompilerSpmdNumericStrategy.NativePacked)])]
    [(ast.AstBinOp.Div) (CompilerSpmdNumericStrategy.Unsupported)]
    [(ast.AstBinOp.Mod)
      (if (compiler-spmd-numeric-integer-lane? source)
        (match context
          [(CompilerSpmdNumericContext.DirectMap)
            (CompilerSpmdNumericStrategy.MaskedPlannerExpansion)]
          [(CompilerSpmdNumericContext.InlineHelper)
            (CompilerSpmdNumericStrategy.MaskedPlannerExpansion)]
          [(CompilerSpmdNumericContext.MaskedControl)
            (CompilerSpmdNumericStrategy.CheckedActiveLaneExpansion)]
          [(CompilerSpmdNumericContext.PrivateHelper)
            (CompilerSpmdNumericStrategy.CheckedActiveLaneExpansion)]
          [(CompilerSpmdNumericContext.FusedReduction)
            (CompilerSpmdNumericStrategy.Unsupported)])
        (CompilerSpmdNumericStrategy.Unsupported))]
    [(ast.AstBinOp.Eq) (CompilerSpmdNumericStrategy.NativePacked)]
    [(ast.AstBinOp.Ne) (CompilerSpmdNumericStrategy.NativePacked)]
    [(ast.AstBinOp.Lt) (CompilerSpmdNumericStrategy.NativePacked)]
    [(ast.AstBinOp.Le) (CompilerSpmdNumericStrategy.NativePacked)]
    [(ast.AstBinOp.Gt) (CompilerSpmdNumericStrategy.NativePacked)]
    [(ast.AstBinOp.Ge) (CompilerSpmdNumericStrategy.NativePacked)]
    [(ast.AstBinOp.And) (CompilerSpmdNumericStrategy.Unsupported)]
    [(ast.AstBinOp.Or) (CompilerSpmdNumericStrategy.Unsupported)]
    [(ast.AstBinOp.BitAnd)
      (if (compiler-spmd-numeric-integer-lane? source)
        (CompilerSpmdNumericStrategy.NativePacked)
        (CompilerSpmdNumericStrategy.Unsupported))]
    [(ast.AstBinOp.BitOr)
      (if (compiler-spmd-numeric-integer-lane? source)
        (CompilerSpmdNumericStrategy.NativePacked)
        (CompilerSpmdNumericStrategy.Unsupported))]
    [(ast.AstBinOp.BitXor)
      (if (compiler-spmd-numeric-integer-lane? source)
        (CompilerSpmdNumericStrategy.NativePacked)
        (CompilerSpmdNumericStrategy.Unsupported))]
    [(ast.AstBinOp.Shl)
      (if (compiler-spmd-numeric-integer-lane? source)
        (CompilerSpmdNumericStrategy.CheckedActiveLaneExpansion)
        (CompilerSpmdNumericStrategy.Unsupported))]
    [(ast.AstBinOp.Shr)
      (if (compiler-spmd-numeric-integer-lane? source)
        (CompilerSpmdNumericStrategy.CheckedActiveLaneExpansion)
        (CompilerSpmdNumericStrategy.Unsupported))]))

(define (compiler-spmd-numeric-binary-decision
  [source-ty : ast.AstType]
  [destination-ty : ast.AstType]
  [context : CompilerSpmdNumericContext]
  [backend : CompilerSpmdNumericBackend]
  [op : ast.AstBinOp]) : CompilerSpmdNumericDecision
  (let
    [source : CompilerSpmdNumericLane (compiler-spmd-numeric-lane source-ty)]
    [destination : CompilerSpmdNumericLane
      (compiler-spmd-numeric-lane destination-ty)]
    [destination-ok : bool
      (if (compiler-spmd-numeric-comparison-op? op)
        (match destination
          [(CompilerSpmdNumericLane.Bool) true]
          [_ false])
        (compiler-spmd-numeric-lane-eq? source destination))]
    [strategy : CompilerSpmdNumericStrategy
      (if (and (compiler-spmd-numeric-lane? source) destination-ok)
        (match backend
          [(CompilerSpmdNumericBackend.Scalar)
            ;; Invalid scalar type/operator pairs are still excluded so the
            ;; matrix describes language-applicable rows, not parser tokens.
            (match op
              [(ast.AstBinOp.And) (CompilerSpmdNumericStrategy.Unsupported)]
              [(ast.AstBinOp.Or) (CompilerSpmdNumericStrategy.Unsupported)]
              [(ast.AstBinOp.Mod)
                (if (compiler-spmd-numeric-integer-lane? source)
                  (CompilerSpmdNumericStrategy.ScalarReference)
                  (CompilerSpmdNumericStrategy.Unsupported))]
              [(ast.AstBinOp.BitAnd)
                (if (compiler-spmd-numeric-integer-lane? source)
                  (CompilerSpmdNumericStrategy.ScalarReference)
                  (CompilerSpmdNumericStrategy.Unsupported))]
              [(ast.AstBinOp.BitOr)
                (if (compiler-spmd-numeric-integer-lane? source)
                  (CompilerSpmdNumericStrategy.ScalarReference)
                  (CompilerSpmdNumericStrategy.Unsupported))]
              [(ast.AstBinOp.BitXor)
                (if (compiler-spmd-numeric-integer-lane? source)
                  (CompilerSpmdNumericStrategy.ScalarReference)
                  (CompilerSpmdNumericStrategy.Unsupported))]
              [(ast.AstBinOp.Shl)
                (if (compiler-spmd-numeric-integer-lane? source)
                  (CompilerSpmdNumericStrategy.ScalarReference)
                  (CompilerSpmdNumericStrategy.Unsupported))]
              [(ast.AstBinOp.Shr)
                (if (compiler-spmd-numeric-integer-lane? source)
                  (CompilerSpmdNumericStrategy.ScalarReference)
                  (CompilerSpmdNumericStrategy.Unsupported))]
              [_ (CompilerSpmdNumericStrategy.ScalarReference)])]
          [(CompilerSpmdNumericBackend.Avx2)
            (compiler-spmd-numeric-simd-binary-strategy source context op)]
          [(CompilerSpmdNumericBackend.Avx512)
            (compiler-spmd-numeric-simd-binary-strategy source context op)])
        (CompilerSpmdNumericStrategy.Unsupported))]
    (CompilerSpmdNumericDecision
      source
      destination
      context
      backend
      (CompilerSpmdNumericOperation.Binary op)
      strategy)))

(define (compiler-spmd-numeric-conversion-replan-context?
  [context : CompilerSpmdNumericContext]) : bool
  (match context
    [(CompilerSpmdNumericContext.DirectMap) true]
    [(CompilerSpmdNumericContext.FusedReduction) true]
    [(CompilerSpmdNumericContext.InlineHelper) true]
    [(CompilerSpmdNumericContext.MaskedControl) false]
    [(CompilerSpmdNumericContext.PrivateHelper) false]))

(define (compiler-spmd-numeric-conversion-decision
  [source-ty : ast.AstType]
  [destination-ty : ast.AstType]
  [context : CompilerSpmdNumericContext]
  [backend : CompilerSpmdNumericBackend]) : CompilerSpmdNumericDecision
  (let
    [source : CompilerSpmdNumericLane (compiler-spmd-numeric-lane source-ty)]
    [destination : CompilerSpmdNumericLane
      (compiler-spmd-numeric-lane destination-ty)]
    [strategy : CompilerSpmdNumericStrategy
      (if (and
        (compiler-spmd-numeric-lane? source)
        (compiler-spmd-numeric-lane? destination))
        (match backend
          [(CompilerSpmdNumericBackend.Scalar)
            (CompilerSpmdNumericStrategy.ScalarReference)]
          [(CompilerSpmdNumericBackend.Avx2)
            (cond
              [(compiler-spmd-numeric-lane-eq? source destination)
                (CompilerSpmdNumericStrategy.NativePacked)]
              [(and
                  (compiler-spmd-numeric-integer-lane? source)
                  (compiler-spmd-numeric-integer-lane? destination)
                  (compiler-spmd-numeric-conversion-replan-context? context))
                (CompilerSpmdNumericStrategy.OwnedVectorExpansion)]
              [else (CompilerSpmdNumericStrategy.Unsupported)])]
          [(CompilerSpmdNumericBackend.Avx512)
            (cond
              [(compiler-spmd-numeric-lane-eq? source destination)
                (CompilerSpmdNumericStrategy.NativePacked)]
              [(and
                  (compiler-spmd-numeric-integer-lane? source)
                  (compiler-spmd-numeric-integer-lane? destination)
                  (compiler-spmd-numeric-conversion-replan-context? context))
                (CompilerSpmdNumericStrategy.OwnedVectorExpansion)]
              [else (CompilerSpmdNumericStrategy.Unsupported)])])
        (CompilerSpmdNumericStrategy.Unsupported))]
    (CompilerSpmdNumericDecision
      source
      destination
      context
      backend
      (CompilerSpmdNumericOperation.Conversion)
      strategy)))

(define (compiler-spmd-numeric-decision-supported?
  [decision : CompilerSpmdNumericDecision]) : bool
  (match decision.strategy
    [(CompilerSpmdNumericStrategy.ScalarReference) true]
    [(CompilerSpmdNumericStrategy.NativePacked) true]
    [(CompilerSpmdNumericStrategy.OwnedVectorExpansion) true]
    [(CompilerSpmdNumericStrategy.CheckedActiveLaneExpansion) true]
    [(CompilerSpmdNumericStrategy.MaskedPlannerExpansion) true]
    [(CompilerSpmdNumericStrategy.Unsupported) false]))

(define (compiler-spmd-numeric-operation-name [op : ast.AstBinOp]) : String
  (match op
    [(ast.AstBinOp.Add) "+"]
    [(ast.AstBinOp.Sub) "-"]
    [(ast.AstBinOp.Mul) "*"]
    [(ast.AstBinOp.Div) "/"]
    [(ast.AstBinOp.Mod) "%"]
    [(ast.AstBinOp.Eq) "="]
    [(ast.AstBinOp.Ne) "!="]
    [(ast.AstBinOp.Lt) "<"]
    [(ast.AstBinOp.Le) "<="]
    [(ast.AstBinOp.Gt) ">"]
    [(ast.AstBinOp.Ge) ">="]
    [(ast.AstBinOp.And) "and"]
    [(ast.AstBinOp.Or) "or"]
    [(ast.AstBinOp.BitAnd) "bit-and"]
    [(ast.AstBinOp.BitOr) "bit-or"]
    [(ast.AstBinOp.BitXor) "bit-xor"]
    [(ast.AstBinOp.Shl) "shl"]
    [(ast.AstBinOp.Shr) "shr"]))

(define (compiler-spmd-numeric-context-name
  [context : CompilerSpmdNumericContext]) : String
  (match context
    [(CompilerSpmdNumericContext.DirectMap) "direct map"]
    [(CompilerSpmdNumericContext.FusedReduction) "map-fused reduction"]
    [(CompilerSpmdNumericContext.MaskedControl) "masked control"]
    [(CompilerSpmdNumericContext.InlineHelper) "inline helper"]
    [(CompilerSpmdNumericContext.PrivateHelper) "private helper"]))

(define (compiler-spmd-numeric-backend-name
  [backend : CompilerSpmdNumericBackend]) : String
  (match backend
    [(CompilerSpmdNumericBackend.Scalar) "scalar"]
    [(CompilerSpmdNumericBackend.Avx2) "AVX2"]
    [(CompilerSpmdNumericBackend.Avx512) "AVX-512"]))

(define (compiler-spmd-numeric-lane-name [lane : CompilerSpmdNumericLane]) : String
  (match lane
    [(CompilerSpmdNumericLane.I8) "i8"]
    [(CompilerSpmdNumericLane.U8) "u8"]
    [(CompilerSpmdNumericLane.I16) "i16"]
    [(CompilerSpmdNumericLane.U16) "u16"]
    [(CompilerSpmdNumericLane.I32) "i32"]
    [(CompilerSpmdNumericLane.U32) "u32"]
    [(CompilerSpmdNumericLane.I64) "i64"]
    [(CompilerSpmdNumericLane.U64) "u64"]
    [(CompilerSpmdNumericLane.F32) "f32"]
    [(CompilerSpmdNumericLane.F64) "f64"]
    [(CompilerSpmdNumericLane.Bool) "bool"]
    [(CompilerSpmdNumericLane.Char) "char"]
    [(CompilerSpmdNumericLane.Other) "non-numeric"]))

;; Called only for an emitted diagnostic. Admission queries above stay typed
;; and allocation-free on the successful planning path.
(define (compiler-spmd-numeric-limitation
  [decision : CompilerSpmdNumericDecision]) : String
  (match decision.operation
    [(CompilerSpmdNumericOperation.Conversion)
      "SIMD cross-lane conversion has no implemented strategy; use scalar backend"]
    [(CompilerSpmdNumericOperation.Binary op)
      (match op
        [(ast.AstBinOp.Div)
          "SIMD division has no implemented strategy; use scalar backend"]
        [(ast.AstBinOp.Mod)
          "SIMD remainder requires checked active-lane expansion in masked control; use scalar backend for this context"]
        [_
          "this numeric row has no implemented SIMD strategy; use scalar backend"])]))

(cfg
  test
  (define (compiler-spmd-numeric-lane-at [index : i64]) : ast.AstType
    (match index
      [0 (ast.AstType.I8)]
      [1 (ast.AstType.U8)]
      [2 (ast.AstType.I16)]
      [3 (ast.AstType.U16)]
      [4 (ast.AstType.I32)]
      [5 (ast.AstType.U32)]
      [6 (ast.AstType.I64)]
      [7 (ast.AstType.U64)]
      [8 (ast.AstType.F32)]
      [_ (ast.AstType.F64)])))

(cfg
  test
  (define (compiler-spmd-numeric-context-at [index : i64]) : CompilerSpmdNumericContext
    (match index
      [0 (CompilerSpmdNumericContext.DirectMap)]
      [1 (CompilerSpmdNumericContext.FusedReduction)]
      [2 (CompilerSpmdNumericContext.MaskedControl)]
      [3 (CompilerSpmdNumericContext.InlineHelper)]
      [_ (CompilerSpmdNumericContext.PrivateHelper)])))

(cfg
  test
  (define (compiler-spmd-numeric-backend-at [index : i64]) : CompilerSpmdNumericBackend
    (match index
      [0 (CompilerSpmdNumericBackend.Scalar)]
      [1 (CompilerSpmdNumericBackend.Avx2)]
      [_ (CompilerSpmdNumericBackend.Avx512)])))

(cfg
  test
  (define (compiler-spmd-numeric-binop-at [index : i64]) : ast.AstBinOp
    (match index
      [0 (ast.AstBinOp.Add)]
      [1 (ast.AstBinOp.Sub)]
      [2 (ast.AstBinOp.Mul)]
      [3 (ast.AstBinOp.Div)]
      [4 (ast.AstBinOp.Mod)]
      [5 (ast.AstBinOp.Eq)]
      [6 (ast.AstBinOp.Ne)]
      [7 (ast.AstBinOp.Lt)]
      [8 (ast.AstBinOp.Le)]
      [9 (ast.AstBinOp.Gt)]
      [10 (ast.AstBinOp.Ge)]
      [11 (ast.AstBinOp.And)]
      [12 (ast.AstBinOp.Or)]
      [13 (ast.AstBinOp.BitAnd)]
      [14 (ast.AstBinOp.BitOr)]
      [15 (ast.AstBinOp.BitXor)]
      [16 (ast.AstBinOp.Shl)]
      [_ (ast.AstBinOp.Shr)])))

(cfg
  test
  (define (compiler-spmd-numeric-matrix-coverage-ok?) : bool
    (let
      [backend-index : i64 0]
      [binary-rows : i64 0]
      [cast-rows : i64 0]
      [supported-binary : i64 0]
      [supported-casts : i64 0]
      (begin
        (while (< backend-index 3)
          (let
            [context-index : i64 0]
            [backend : CompilerSpmdNumericBackend
              (compiler-spmd-numeric-backend-at backend-index)]
            (begin
              (while (< context-index 5)
                (let
                  [lane-index : i64 0]
                  [context : CompilerSpmdNumericContext
                    (compiler-spmd-numeric-context-at context-index)]
                  (begin
                    (while (< lane-index 10)
                      (let
                        [source : ast.AstType
                          (compiler-spmd-numeric-lane-at lane-index)]
                        [op-index : i64 0]
                        [destination-index : i64 0]
                        (begin
                          (while (< op-index 18)
                            (let
                              [op : ast.AstBinOp
                                (compiler-spmd-numeric-binop-at op-index)]
                              [decision : CompilerSpmdNumericDecision
                                (compiler-spmd-numeric-binary-decision
                                  (clone source)
                                  (if (compiler-spmd-numeric-comparison-op? op)
                                    (ast.AstType.Bool)
                                    (clone source))
                                  context
                                  backend
                                  op)]
                              (begin
                                (set! binary-rows (+ binary-rows 1))
                                (if (compiler-spmd-numeric-decision-supported?
                                  decision)
                                  (set! supported-binary (+ supported-binary 1))
                                  unit)
                                (set! op-index (+ op-index 1)))))
                          (while (< destination-index 10)
                            (let
                              [decision : CompilerSpmdNumericDecision
                                (compiler-spmd-numeric-conversion-decision
                                  (clone source)
                                  (compiler-spmd-numeric-lane-at
                                    destination-index)
                                  context
                                  backend)]
                              (begin
                                (set! cast-rows (+ cast-rows 1))
                                (if (compiler-spmd-numeric-decision-supported?
                                  decision)
                                  (set! supported-casts (+ supported-casts 1))
                                  unit)
                                (set! destination-index (+ destination-index 1)))))
                          (set! lane-index (+ lane-index 1)))))
                    (set! context-index (+ context-index 1)))))
              (set! backend-index (+ backend-index 1)))))
        (and
          (= binary-rows 2700)
          (= cast-rows 1500)
          (= supported-binary 2104)
          (= supported-casts 936)
          (match (compiler-spmd-numeric-binary-decision
            (ast.AstType.I8)
            (ast.AstType.I8)
            (CompilerSpmdNumericContext.DirectMap)
            (CompilerSpmdNumericBackend.Avx2)
            (ast.AstBinOp.Mul)).strategy
            [(CompilerSpmdNumericStrategy.OwnedVectorExpansion) true]
            [_ false])
          (match (compiler-spmd-numeric-binary-decision
            (ast.AstType.I64)
            (ast.AstType.I64)
            (CompilerSpmdNumericContext.DirectMap)
            (CompilerSpmdNumericBackend.Avx512)
            (ast.AstBinOp.Mod)).strategy
            [(CompilerSpmdNumericStrategy.MaskedPlannerExpansion) true]
            [_ false])
          (match (compiler-spmd-numeric-binary-decision
            (ast.AstType.I64)
            (ast.AstType.I64)
            (CompilerSpmdNumericContext.MaskedControl)
            (CompilerSpmdNumericBackend.Avx512)
            (ast.AstBinOp.Shl)).strategy
            [(CompilerSpmdNumericStrategy.CheckedActiveLaneExpansion) true]
            [_ false])
          (match (compiler-spmd-numeric-conversion-decision
            (ast.AstType.I64)
            (ast.AstType.I32)
            (CompilerSpmdNumericContext.DirectMap)
            (CompilerSpmdNumericBackend.Avx2)).strategy
            [(CompilerSpmdNumericStrategy.OwnedVectorExpansion) true]
            [_ false])
          (not
            (compiler-spmd-numeric-decision-supported?
              (compiler-spmd-numeric-conversion-decision
                (ast.AstType.I32)
                (ast.AstType.F32)
                (CompilerSpmdNumericContext.PrivateHelper)
                (CompilerSpmdNumericBackend.Avx512))))
          (not
            (compiler-spmd-numeric-decision-supported?
              (compiler-spmd-numeric-conversion-decision
                (ast.AstType.Char)
                (ast.AstType.I64)
                (CompilerSpmdNumericContext.DirectMap)
                (CompilerSpmdNumericBackend.Avx512))))
          (not
            (compiler-spmd-numeric-decision-supported?
              (compiler-spmd-numeric-binary-decision
                (ast.AstType.Bool)
                (ast.AstType.Bool)
                (CompilerSpmdNumericContext.MaskedControl)
                (CompilerSpmdNumericBackend.Avx512)
                (ast.AstBinOp.Add)))))))))

(cfg
  test
  (test
    compiler-spmd-numeric-matrix-coverage
    (unless
      (compiler-spmd-numeric-matrix-coverage-ok?)
      (io.panic "SPMD numeric matrix coverage drifted"))))