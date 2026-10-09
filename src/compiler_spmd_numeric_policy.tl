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
    [(I8) (I8)]
    [(U8) (U8)]
    [(I16) (I16)]
    [(U16) (U16)]
    [(I32) (I32)]
    [(U32) (U32)]
    [(I64) (I64)]
    [(U64) (U64)]
    [(F32) (F32)]
    [(F64) (F64)]
    [(Bool) (Bool)]
    [(Char) (Char)]
    [_ (Other)]))

(define (compiler-spmd-numeric-lane? [lane : CompilerSpmdNumericLane]) : bool
  (match lane
    [(or (I8) (U8) (I16) (U16) (I32) (U32) (I64) (U64) (F32) (F64)) true]
    [(or (Bool) (Char) (Other)) false]))

(define (compiler-spmd-numeric-integer-lane? [lane : CompilerSpmdNumericLane]) : bool
  (match lane
    [(or (I8) (U8) (I16) (U16) (I32) (U32) (I64) (U64)) true]
    [(or (F32) (F64) (Bool) (Char) (Other)) false]))

(define (compiler-spmd-numeric-lane-eq?
  [left : CompilerSpmdNumericLane]
  [right : CompilerSpmdNumericLane]) : bool
  (match left
    [(I8)
      (match right
        [(I8) true]
        [_ false])]
    [(U8)
      (match right
        [(U8) true]
        [_ false])]
    [(I16)
      (match right
        [(I16) true]
        [_ false])]
    [(U16)
      (match right
        [(U16) true]
        [_ false])]
    [(I32)
      (match right
        [(I32) true]
        [_ false])]
    [(U32)
      (match right
        [(U32) true]
        [_ false])]
    [(I64)
      (match right
        [(I64) true]
        [_ false])]
    [(U64)
      (match right
        [(U64) true]
        [_ false])]
    [(F32)
      (match right
        [(F32) true]
        [_ false])]
    [(F64)
      (match right
        [(F64) true]
        [_ false])]
    [(Bool)
      (match right
        [(Bool) true]
        [_ false])]
    [(Char)
      (match right
        [(Char) true]
        [_ false])]
    [(Other)
      (match right
        [(Other) true]
        [_ false])]))

(define (compiler-spmd-numeric-comparison-op? [op : ast.AstBinOp]) : bool
  (match op
    [(or (Eq) (Ne) (Lt) (Le) (Gt) (Ge)) true]
    [(or (Add) (Sub) (Mul) (Div) (Mod) (And) (Or) (BitAnd) (BitOr) (BitXor)
         (Shl) (Shr))
      false]))

(define (compiler-spmd-numeric-simd-binary-strategy
  [source : CompilerSpmdNumericLane]
  [context : CompilerSpmdNumericContext]
  [op : ast.AstBinOp]) : CompilerSpmdNumericStrategy
  (match op
    [(or (Add) (Sub) (Eq) (Ne) (Lt) (Le) (Gt) (Ge)) (NativePacked)]
    [(Mul)
      (match source
        [(or (I8) (U8)) (OwnedVectorExpansion)]
        [_ (NativePacked)])]
    [(or (Div) (And) (Or)) (Unsupported)]
    [(Mod)
      (if (compiler-spmd-numeric-integer-lane? source)
        (match context
          [(or (DirectMap) (InlineHelper)) (MaskedPlannerExpansion)]
          [(or (MaskedControl) (PrivateHelper)) (CheckedActiveLaneExpansion)]
          [(FusedReduction) (Unsupported)])
        (Unsupported))]
    [(or (BitAnd) (BitOr) (BitXor))
      (if (compiler-spmd-numeric-integer-lane? source)
        (NativePacked)
        (Unsupported))]
    [(or (Shl) (Shr))
      (if (compiler-spmd-numeric-integer-lane? source)
        (CheckedActiveLaneExpansion)
        (Unsupported))]))

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
          [(Bool) true]
          [_ false])
        (compiler-spmd-numeric-lane-eq? source destination))]
    [strategy : CompilerSpmdNumericStrategy
      (if (and (compiler-spmd-numeric-lane? source) destination-ok)
        (match backend
          [(Scalar)
            ;; Invalid scalar type/operator pairs are still excluded so the
            ;; matrix describes language-applicable rows, not parser tokens.
            (match op
              [(or (And) (Or)) (Unsupported)]
              [(or (Mod) (BitAnd) (BitOr) (BitXor) (Shl) (Shr))
                (if (compiler-spmd-numeric-integer-lane? source)
                  (ScalarReference)
                  (Unsupported))]
              [_ (ScalarReference)])]
          [(or (Avx2) (Avx512))
            (compiler-spmd-numeric-simd-binary-strategy source context op)])
        (Unsupported))]
    (CompilerSpmdNumericDecision
      source
      destination
      context
      backend
      (Binary op)
      strategy)))

(define (compiler-spmd-numeric-conversion-replan-context?
  [context : CompilerSpmdNumericContext]) : bool
  (match context
    [(or (DirectMap) (FusedReduction) (InlineHelper)) true]
    [(or (MaskedControl) (PrivateHelper)) false]))

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
          [(Scalar) (ScalarReference)]
          [(or (Avx2) (Avx512))
            (cond
              [(compiler-spmd-numeric-lane-eq? source destination)
                (NativePacked)]
              [(and
                  (compiler-spmd-numeric-integer-lane? source)
                  (compiler-spmd-numeric-integer-lane? destination)
                  (compiler-spmd-numeric-conversion-replan-context? context))
                (OwnedVectorExpansion)]
              [else (Unsupported)])])
        (Unsupported))]
    (CompilerSpmdNumericDecision
      source
      destination
      context
      backend
      (Conversion)
      strategy)))

(define (compiler-spmd-numeric-decision-supported?
  [decision : CompilerSpmdNumericDecision]) : bool
  (match decision.strategy
    [(or (ScalarReference) (NativePacked) (OwnedVectorExpansion)
         (CheckedActiveLaneExpansion) (MaskedPlannerExpansion))
      true]
    [(Unsupported) false]))

(define (compiler-spmd-numeric-operation-name [op : ast.AstBinOp]) : String
  (match op
    [(Add) "+"]
    [(Sub) "-"]
    [(Mul) "*"]
    [(Div) "/"]
    [(Mod) "%"]
    [(Eq) "="]
    [(Ne) "!="]
    [(Lt) "<"]
    [(Le) "<="]
    [(Gt) ">"]
    [(Ge) ">="]
    [(And) "and"]
    [(Or) "or"]
    [(BitAnd) "bit-and"]
    [(BitOr) "bit-or"]
    [(BitXor) "bit-xor"]
    [(Shl) "shl"]
    [(Shr) "shr"]))

(define (compiler-spmd-numeric-context-name
  [context : CompilerSpmdNumericContext]) : String
  (match context
    [(DirectMap) "direct map"]
    [(FusedReduction) "map-fused reduction"]
    [(MaskedControl) "masked control"]
    [(InlineHelper) "inline helper"]
    [(PrivateHelper) "private helper"]))

(define (compiler-spmd-numeric-backend-name
  [backend : CompilerSpmdNumericBackend]) : String
  (match backend
    [(Scalar) "scalar"]
    [(Avx2) "AVX2"]
    [(Avx512) "AVX-512"]))

(define (compiler-spmd-numeric-lane-name [lane : CompilerSpmdNumericLane]) : String
  (match lane
    [(I8) "i8"]
    [(U8) "u8"]
    [(I16) "i16"]
    [(U16) "u16"]
    [(I32) "i32"]
    [(U32) "u32"]
    [(I64) "i64"]
    [(U64) "u64"]
    [(F32) "f32"]
    [(F64) "f64"]
    [(Bool) "bool"]
    [(Char) "char"]
    [(Other) "non-numeric"]))

;; Called only for an emitted diagnostic. Admission queries above stay typed
;; and allocation-free on the successful planning path.
(define (compiler-spmd-numeric-limitation
  [decision : CompilerSpmdNumericDecision]) : String
  (match decision.operation
    [(Conversion)
      "SIMD cross-lane conversion has no implemented strategy; use scalar backend"]
    [(Binary op)
      (match op
        [(Div) "SIMD division has no implemented strategy; use scalar backend"]
        [(Mod)
          "SIMD remainder requires checked active-lane expansion in masked control; use scalar backend for this context"]
        [_
          "this numeric row has no implemented SIMD strategy; use scalar backend"])]))

(cfg
  test
  (define (compiler-spmd-numeric-lane-at [index : i64]) : ast.AstType
    (match index
      [0 (I8)]
      [1 (U8)]
      [2 (I16)]
      [3 (U16)]
      [4 (I32)]
      [5 (U32)]
      [6 (I64)]
      [7 (U64)]
      [8 (F32)]
      [_ (F64)])))

(cfg
  test
  (define (compiler-spmd-numeric-context-at [index : i64]) : CompilerSpmdNumericContext
    (match index
      [0 (DirectMap)]
      [1 (FusedReduction)]
      [2 (MaskedControl)]
      [3 (InlineHelper)]
      [_ (PrivateHelper)])))

(cfg
  test
  (define (compiler-spmd-numeric-backend-at [index : i64]) : CompilerSpmdNumericBackend
    (match index
      [0 (Scalar)]
      [1 (Avx2)]
      [_ (Avx512)])))

(cfg
  test
  (define (compiler-spmd-numeric-binop-at [index : i64]) : ast.AstBinOp
    (match index
      [0 (Add)]
      [1 (Sub)]
      [2 (Mul)]
      [3 (Div)]
      [4 (Mod)]
      [5 (Eq)]
      [6 (Ne)]
      [7 (Lt)]
      [8 (Le)]
      [9 (Gt)]
      [10 (Ge)]
      [11 (And)]
      [12 (Or)]
      [13 (BitAnd)]
      [14 (BitOr)]
      [15 (BitXor)]
      [16 (Shl)]
      [_ (Shr)])))

(cfg
  test
  (define (compiler-spmd-numeric-matrix-coverage-ok?) : bool
    (let
      [backend-index : i64 0]
      [binary-rows : i64 0]
      [cast-rows : i64 0]
      [supported-binary : i64 0]
      [supported-casts : i64 0]
      (while (< backend-index 3)
        (let
          [context-index : i64 0]
          [backend : CompilerSpmdNumericBackend
            (compiler-spmd-numeric-backend-at backend-index)]
          (while (< context-index 5)
            (let
              [lane-index : i64 0]
              [context : CompilerSpmdNumericContext
                (compiler-spmd-numeric-context-at context-index)]
              (while (< lane-index 10)
                (let
                  [source : ast.AstType
                    (compiler-spmd-numeric-lane-at lane-index)]
                  [op-index : i64 0]
                  [destination-index : i64 0]
                  (while (< op-index 18)
                    (let
                      [op : ast.AstBinOp
                        (compiler-spmd-numeric-binop-at op-index)]
                      [decision : CompilerSpmdNumericDecision
                        (compiler-spmd-numeric-binary-decision
                          (clone source)
                          (if (compiler-spmd-numeric-comparison-op? op)
                            (Bool)
                            (clone source))
                          context
                          backend
                          op)]
                      (set! binary-rows (+ binary-rows 1))
                      (if (compiler-spmd-numeric-decision-supported? decision)
                        (set! supported-binary (+ supported-binary 1))
                        unit)
                      (set! op-index (+ op-index 1))))
                  (while (< destination-index 10)
                    (let
                      [decision : CompilerSpmdNumericDecision
                        (compiler-spmd-numeric-conversion-decision
                          (clone source)
                          (compiler-spmd-numeric-lane-at destination-index)
                          context
                          backend)]
                      (set! cast-rows (+ cast-rows 1))
                      (if (compiler-spmd-numeric-decision-supported? decision)
                        (set! supported-casts (+ supported-casts 1))
                        unit)
                      (set! destination-index (+ destination-index 1))))
                  (set! lane-index (+ lane-index 1))))
              (set! context-index (+ context-index 1))))
          (set! backend-index (+ backend-index 1))))
      (and
        (= binary-rows 2700)
        (= cast-rows 1500)
        (= supported-binary 2104)
        (= supported-casts 936)
        (match (compiler-spmd-numeric-binary-decision
          (I8)
          (I8)
          (DirectMap)
          (Avx2)
          (Mul)).strategy
          [(OwnedVectorExpansion) true]
          [_ false])
        (match (compiler-spmd-numeric-binary-decision
          (I64)
          (I64)
          (DirectMap)
          (Avx512)
          (Mod)).strategy
          [(MaskedPlannerExpansion) true]
          [_ false])
        (match (compiler-spmd-numeric-binary-decision
          (I64)
          (I64)
          (MaskedControl)
          (Avx512)
          (Shl)).strategy
          [(CheckedActiveLaneExpansion) true]
          [_ false])
        (match (compiler-spmd-numeric-conversion-decision
          (I64)
          (I32)
          (DirectMap)
          (Avx2)).strategy
          [(OwnedVectorExpansion) true]
          [_ false])
        (not
          (compiler-spmd-numeric-decision-supported?
            (compiler-spmd-numeric-conversion-decision
              (I32)
              (F32)
              (PrivateHelper)
              (Avx512))))
        (not
          (compiler-spmd-numeric-decision-supported?
            (compiler-spmd-numeric-conversion-decision
              (Char)
              (I64)
              (DirectMap)
              (Avx512))))
        (not
          (compiler-spmd-numeric-decision-supported?
            (compiler-spmd-numeric-binary-decision
              (Bool)
              (Bool)
              (MaskedControl)
              (Avx512)
              (Add))))))))

(cfg
  test
  (test
    compiler-spmd-numeric-matrix-coverage
    (unless
      (compiler-spmd-numeric-matrix-coverage-ok?)
      (io.panic "SPMD numeric matrix coverage drifted"))))