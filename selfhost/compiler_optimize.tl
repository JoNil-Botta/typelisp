;; compiler_optimize.tl - Selfhost optimizer: pass framework + scalar constant
;; folding (#543, first slice of #519).
;;
;; Runs between lowering (`lower-compiler-program`) and backend emission
;; (`compiler-backend-emit-program`). It performs conservative, scalar-only
;; local rewrites: constant folding, algebraic strength reduction, CSE, copy
;; propagation, conservative global value numbering/cross-block copy
;; propagation, conservative loop-invariant scalar hoisting, redundant
;; bounds-check elimination, conservative CFG simplification, and DCE.
;;
;; Safety:
;; - Integer `+`, `-`, `*`, bitwise ops, shifts, and `neg` are folded through
;;   helpers that normalize the result back to the instruction type. This keeps
;;   narrow signed/unsigned widths and `char` byte semantics explicit.
;; - Division, modulo, and shifts fold only when the static operands avoid the
;;   same runtime traps emitted by lowering: zero divisors, signed MIN / -1, and
;;   out-of-range shift counts remain in the IR.
;; - Tracking is block-local (reset per block), so no value is folded across a
;;   control-flow edge.
;;
;; Out of scope: aggregate/String/array IR optimization.
(import "../stdlib/core_macros.tl" module stdlib.core-macros as core)

(import "../stdlib/io.tl")

(import "../stdlib/arena.tl")

(import "compiler_ir_types.tl")

(import "../stdlib/hash.tl")

(import "../stdlib/hashmap.tl")

(import "../stdlib/string.tl")

(defenum ResultCompilerOptimizeLevel
  (OkCompilerOptimizeLevel i64)
  (ErrCompilerOptimizeLevel))

(defenum CompilerOptimizedProgram
  (CompilerOptimizedProgram CompilerIrProgram CompilerSourceSpans))

(defenum OptAggregatePointer
  (OptAggregatePointer i64 i64))

(defenum OptAggregatePointerList
  (OptAggregatePointerNil)
  (OptAggregatePointerCons OptAggregatePointer (Box OptAggregatePointerList)))

(defenum OptAggregateAccess
  (OptAggregateStore i64 AstType)
  (OptAggregateLoad i64 i64 AstType))

(defenum OptAggregateAccessList
  (OptAggregateAccessNil)
  (OptAggregateAccessCons OptAggregateAccess (Box OptAggregateAccessList)))

(defenum OptAggregateAllocCandidate
  (OptAggregateAllocCandidate
    i64
    AstType
    i64
    OptAggregatePointerList
    OptAggregateAccessList))

(defenum OptAggregateAllocCandidateList
  (OptAggregateAllocCandidateNil)
  (OptAggregateAllocCandidateCons
    OptAggregateAllocCandidate
    (Box OptAggregateAllocCandidateList)))

(defenum OptMaybeAggregateAlloc
  (OptNoAggregateAlloc)
  (OptSomeAggregateAlloc i64 AstType i64))

(defenum OptAggregateScanResult
  (OptAggregateScanOk OptAggregatePointerList OptAggregateAccessList)
  (OptAggregateScanReject))

;; Aggregate field-load SROA (#1562) supporting types.
(defenum OptAggregateLocation
  (OptNoAggregateLocation)
  (OptSomeAggregateLocation i64 i64))

(defenum OptAggregateStoredValue
  (OptNoAggregateStoredValue)
  (OptSomeAggregateStoredValue CompilerIrValue AstType))

(defenum OptAggregateFieldFacts
  (OptAggregateFieldNil)
  (OptAggregateFieldCons
    i64
    i64
    CompilerIrValue
    AstType
    (Box OptAggregateFieldFacts)))

(defenum OptAggregateSroaResult
  (OptAggregateSroaResult OptAggregateFieldFacts CompilerIrInstr))

(defenum OptAggregatePromoteSlot
  (OptAggregatePromoteSlot i64 i64))

(defenum OptAggregatePromoteSlotList
  (OptAggregatePromoteSlotNil)
  (OptAggregatePromoteSlotCons
    OptAggregatePromoteSlot
    (Box OptAggregatePromoteSlotList)))

(defenum OptAggregatePromoteBuild
  (OptAggregatePromoteBuild OptAggregatePromoteSlotList i64))

(define compiler-optimize-level-default : i64
  1)

(cfg
  compile-profile
  (define compiler-opt-profile-start-ms : i64
    0))

(cfg
  compile-profile
  (define compiler-opt-profile-start-total : i64
    0))

(cfg
  compile-profile
  (define compiler-opt-profile-start-live : i64
    0))

(cfg
  compile-profile
  (define compiler-opt-profile-detail-start-ms : i64
    0))

(cfg
  compile-profile
  (define (compiler-opt-profile-field [value : i64]) : String
    (string-append "|" (int->string value))))

(cfg
  compile-profile
  (define (compiler-opt-profile-start) : unit
    (begin
      (set! compiler-opt-profile-start-ms (profile-now-ms))
      (set! compiler-opt-profile-start-total (profile-alloc-total))
      (set! compiler-opt-profile-start-live (profile-alloc-live))
      (profile-alloc-reset-peak))))

(cfg
  compile-profile
  (define (compiler-opt-profile-finish [phase : String]) : unit
    (let
      [end-ms : i64 (profile-now-ms)]
      [end-total : i64 (profile-alloc-total)]
      [end-live : i64 (profile-alloc-live)]
      [peak-delta : i64
        (- (profile-alloc-peak) compiler-opt-profile-start-live)]
      (print-error
        (string-append
          "compile-profile|optimize."
          (string-append
            phase
            (string-append
              (compiler-opt-profile-field
                (- end-ms compiler-opt-profile-start-ms))
              (string-append
                (compiler-opt-profile-field
                  (- end-total compiler-opt-profile-start-total))
                (string-append
                  (compiler-opt-profile-field
                    (- end-live compiler-opt-profile-start-live))
                  (string-append (compiler-opt-profile-field peak-delta) "\n"))))))))))

(cfg
  compile-profile
  (define (compiler-opt-profile-detail-start) : unit
    (set! compiler-opt-profile-detail-start-ms (profile-now-ms))))

(cfg
  compile-profile
  (define (compiler-opt-profile-detail-finish [phase : String] [name : String]) : unit
    (let
      [elapsed : i64 (- (profile-now-ms) compiler-opt-profile-detail-start-ms)]
      (if (>= elapsed 1)
        (print-error
          (string-append
            "compile-profile-detail|optimize."
            (string-append
              phase
              (string-append
                "|"
                (string-append
                  (int->string elapsed)
                  (string-append "|" (string-append name "\n")))))))
        unit))))

(cfg
  compile-profile
  (define (compiler-opt-profile-function-name [func : CompilerIrFunction]) : String
    (match func
      [(IrFunction name _ _ _ _) name])))

(define (compiler-optimize-default-level) : i64
  compiler-optimize-level-default)

(define (compiler-optimize-level-valid? [level : i64]) : bool
  (and (>= level 0) (<= level 2)))

(define (compiler-optimize-parse-level [value : String]) : ResultCompilerOptimizeLevel
  (if (= (string-length value) 1)
    (let
      [c : char (string-ref value 0)]
      (if (or (= c #0') (or (= c #1') (= c #2')))
        (OkCompilerOptimizeLevel (string->int value))
        (ErrCompilerOptimizeLevel)))
    (ErrCompilerOptimizeLevel)))

;; --- block-local constant environment: IR var id -> known typed scalar -------
(defenum OptMaybeI64
  (OptNoI64)
  (OptSomeI64 i64))

(defenum OptMaybeBool
  (OptNoBool)
  (OptSomeBool bool))

(defenum OptKnownConst
  (OptNoConst)
  (OptSomeConst CompilerIrValue AstType))

(defenum OptConstEnv
  (OptConstNil)
  (OptConstCons i64 CompilerIrValue AstType (Box OptConstEnv)))

(define (opt-const-unbind [env : OptConstEnv] [var : i64]) : OptConstEnv
  (match env
    [(OptConstNil) (OptConstNil)]
    [(OptConstCons id value ty rest)
      (let
        [rest : OptConstEnv (box-get rest)]
        (if (= id var)
          (opt-const-unbind rest var)
          (OptConstCons id value ty (box (opt-const-unbind rest var)))))]))

(define (opt-const-bind
  [env : OptConstEnv]
  [var : i64]
  [value : CompilerIrValue]
  [ty : AstType]) : OptConstEnv
  (OptConstCons var value ty (box (opt-const-unbind env var))))

(define (opt-const-lookup [env : OptConstEnv] [var : i64]) : OptKnownConst
  (match env
    [(OptConstNil) (OptNoConst)]
    [(OptConstCons id value ty rest)
      (let
        [rest : OptConstEnv (box-get rest)]
        (if (= id var)
          (OptSomeConst value ty)
          (opt-const-lookup rest var)))]))

(define (opt-integer-type? [ty : AstType]) : bool
  (match ty
    [(AstTyI64) true]
    [(AstTyI32) true]
    [(AstTyI16) true]
    [(AstTyI8) true]
    [(AstTyU64) true]
    [(AstTyU32) true]
    [(AstTyU16) true]
    [(AstTyU8) true]
    [_ false]))

(define (opt-signed-integer-type? [ty : AstType]) : bool
  (match ty
    [(AstTyI64) true]
    [(AstTyI32) true]
    [(AstTyI16) true]
    [(AstTyI8) true]
    [_ false]))

(define (opt-unsigned-integer-type? [ty : AstType]) : bool
  (match ty
    [(AstTyU64) true]
    [(AstTyU32) true]
    [(AstTyU16) true]
    [(AstTyU8) true]
    [_ false]))

(define (opt-int-or-char-type? [ty : AstType]) : bool
  (if (opt-integer-type? ty)
    true
    (match ty
      [(AstTyChar) true]
      [_ false])))

(define (opt-bool-type? [ty : AstType]) : bool
  (match ty
    [(AstTyBool) true]
    [_ false]))

(define (opt-int-width [ty : AstType]) : i64
  (match ty
    [(AstTyI64) 64]
    [(AstTyU64) 64]
    [(AstTyI32) 32]
    [(AstTyU32) 32]
    [(AstTyI16) 16]
    [(AstTyU16) 16]
    [(AstTyI8) 8]
    [(AstTyU8) 8]
    [(AstTyChar) 8]
    [_ 0]))

(define (opt-value-to-i64 [value : CompilerIrValue]) : OptMaybeI64
  (match value
    [(IrValueI64 n) (OptSomeI64 n)]
    [(IrValueChar c) (OptSomeI64 (cast c : i64))]
    [_ (OptNoI64)]))

(define (opt-value-to-bool [value : CompilerIrValue]) : OptMaybeBool
  (match value
    [(IrValueBool b) (OptSomeBool b)]
    [_ (OptNoBool)]))

(define (opt-normalize-int-to-i64 [value : i64] [ty : AstType]) : i64
  (match ty
    [(AstTyI64) (cast (cast value : i64) : i64)]
    [(AstTyI32) (cast (cast value : i32) : i64)]
    [(AstTyI16) (cast (cast value : i16) : i64)]
    [(AstTyI8) (cast (cast value : i8) : i64)]
    [(AstTyU64) (cast (cast value : u64) : i64)]
    [(AstTyU32) (cast (cast value : u32) : i64)]
    [(AstTyU16) (cast (cast value : u16) : i64)]
    [(AstTyU8) (cast (cast value : u8) : i64)]
    [(AstTyChar) (cast (cast value : char) : i64)]
    [_ value]))

(define (opt-normalize-const [value : CompilerIrValue] [ty : AstType]) : OptKnownConst
  (if (opt-integer-type? ty)
    (match (opt-value-to-i64 value)
      [(OptSomeI64 n)
        (OptSomeConst (IrValueI64 (opt-normalize-int-to-i64 n ty)) ty)]
      [(OptNoI64) (OptNoConst)])
    (match ty
      [(AstTyChar)
        (match (opt-value-to-i64 value)
          [(OptSomeI64 n)
            (OptSomeConst (IrValueChar (cast n : char)) (AstTyChar))]
          [(OptNoI64) (OptNoConst)])]
      [(AstTyBool)
        (match (opt-value-to-bool value)
          [(OptSomeBool b) (OptSomeConst (IrValueBool b) (AstTyBool))]
          [(OptNoBool) (OptNoConst)])]
      [_ (OptNoConst)])))

(define (opt-const-value? [value : CompilerIrValue] [ty : AstType]) : bool
  (match (opt-normalize-const value ty)
    [(OptSomeConst _ _) true]
    [(OptNoConst) false]))

(define (opt-default-immediate-type
  [value : CompilerIrValue]
  [fallback : AstType]) : AstType
  (match value
    [(IrValueI64 _)
      (if (opt-int-or-char-type? fallback)
        fallback
        (AstTyI64))]
    [(IrValueChar _) (AstTyChar)]
    [(IrValueBool _) (AstTyBool)]
    [(IrValueF64 _) (AstTyF64)]
    [(IrValueUnit) (AstTyUnit)]
    [_ fallback]))

(define (opt-resolve-known
  [env : OptConstEnv]
  [value : CompilerIrValue]
  [fallback-ty : AstType]) : OptKnownConst
  (match value
    [(IrValueVar id)
      (match (opt-const-lookup env id)
        [(OptSomeConst v ty) (OptSomeConst v ty)]
        [(OptNoConst) (OptNoConst)])]
    [_
      (opt-normalize-const value (opt-default-immediate-type value fallback-ty))]))

(define (opt-resolve-value [env : OptConstEnv] [value : CompilerIrValue]) : CompilerIrValue
  (match value
    [(IrValueVar id)
      (match (opt-const-lookup env id)
        [(OptSomeConst v _) v]
        [(OptNoConst) value])]
    [_ value]))

;; --- folding rules -----------------------------------------------------------
(define (opt-normalize-scalar-to-i64 [value : CompilerIrValue] [ty : AstType]) : OptMaybeI64
  (if (opt-int-or-char-type? ty)
    (match (opt-value-to-i64 value)
      [(OptSomeI64 n) (OptSomeI64 (opt-normalize-int-to-i64 n ty))]
      [(OptNoI64) (OptNoI64)])
    (OptNoI64)))

(define (opt-binop-operand-type
  [op : CompilerIrBinOp]
  [lhs-ty : AstType]
  [rhs-ty : AstType]
  [result-ty : AstType]) : AstType
  (match op
    [(IrBinEq)
      (if (opt-type-eq lhs-ty (AstTyI64))
        rhs-ty
        lhs-ty)]
    [(IrBinNe)
      (if (opt-type-eq lhs-ty (AstTyI64))
        rhs-ty
        lhs-ty)]
    [(IrBinLt)
      (if (opt-type-eq lhs-ty (AstTyI64))
        rhs-ty
        lhs-ty)]
    [(IrBinLe)
      (if (opt-type-eq lhs-ty (AstTyI64))
        rhs-ty
        lhs-ty)]
    [(IrBinGt)
      (if (opt-type-eq lhs-ty (AstTyI64))
        rhs-ty
        lhs-ty)]
    [(IrBinGe)
      (if (opt-type-eq lhs-ty (AstTyI64))
        rhs-ty
        lhs-ty)]
    [(IrBinBitAnd) lhs-ty]
    [(IrBinBitOr) lhs-ty]
    [(IrBinBitXor) lhs-ty]
    [(IrBinShl) lhs-ty]
    [(IrBinShr) lhs-ty]
    [_ result-ty]))

(define (opt-signed-min [ty : AstType]) : i64
  (match ty
    [(AstTyI64) (- (- 0 9223372036854775807) 1)]
    [(AstTyI32) (- 0 2147483648)]
    [(AstTyI16) (- 0 32768)]
    [(AstTyI8) (- 0 128)]
    [_ 0]))

(define (opt-divmod-valid? [a : i64] [b : i64] [ty : AstType]) : bool
  (if (= b 0)
    false
    (if (opt-signed-integer-type? ty)
      (not (and (= a (opt-signed-min ty)) (= b (- 0 1))))
      true)))

(define (opt-fold-div-value [a : i64] [b : i64] [ty : AstType]) : i64
  (match ty
    [(AstTyI64) (cast (/ (cast a : i64) (cast b : i64)) : i64)]
    [(AstTyI32) (cast (/ (cast a : i32) (cast b : i32)) : i64)]
    [(AstTyI16) (cast (/ (cast a : i16) (cast b : i16)) : i64)]
    [(AstTyI8) (cast (/ (cast a : i8) (cast b : i8)) : i64)]
    [(AstTyU64) (cast (/ (cast a : u64) (cast b : u64)) : i64)]
    [(AstTyU32) (cast (/ (cast a : u32) (cast b : u32)) : i64)]
    [(AstTyU16) (cast (/ (cast a : u16) (cast b : u16)) : i64)]
    [(AstTyU8) (cast (/ (cast a : u8) (cast b : u8)) : i64)]
    [_ 0]))

(define (opt-fold-mod-value [a : i64] [b : i64] [ty : AstType]) : i64
  (match ty
    [(AstTyI64) (cast (% (cast a : i64) (cast b : i64)) : i64)]
    [(AstTyI32) (cast (% (cast a : i32) (cast b : i32)) : i64)]
    [(AstTyI16) (cast (% (cast a : i16) (cast b : i16)) : i64)]
    [(AstTyI8) (cast (% (cast a : i8) (cast b : i8)) : i64)]
    [(AstTyU64) (cast (% (cast a : u64) (cast b : u64)) : i64)]
    [(AstTyU32) (cast (% (cast a : u32) (cast b : u32)) : i64)]
    [(AstTyU16) (cast (% (cast a : u16) (cast b : u16)) : i64)]
    [(AstTyU8) (cast (% (cast a : u8) (cast b : u8)) : i64)]
    [_ 0]))

(define (opt-unsigned-lt? [a : i64] [b : i64] [ty : AstType]) : bool
  (match ty
    [(AstTyU64) (< (cast a : u64) (cast b : u64))]
    [_ (< a b)]))

(define (opt-typed-lt? [a : i64] [b : i64] [ty : AstType]) : bool
  (if (opt-unsigned-integer-type? ty)
    (opt-unsigned-lt? a b ty)
    (< a b)))

(define (opt-typed-le? [a : i64] [b : i64] [ty : AstType]) : bool
  (or (= a b) (opt-typed-lt? a b ty)))

(define (opt-typed-gt? [a : i64] [b : i64] [ty : AstType]) : bool
  (opt-typed-lt? b a ty))

(define (opt-typed-ge? [a : i64] [b : i64] [ty : AstType]) : bool
  (or (= a b) (opt-typed-lt? b a ty)))

(define (opt-fold-compare
  [op : CompilerIrBinOp]
  [a : i64]
  [b : i64]
  [ty : AstType]) : CompilerIrMaybeValue
  (match op
    [(IrBinEq) (IrSomeValue (IrValueBool (= a b)))]
    [(IrBinNe) (IrSomeValue (IrValueBool (!= a b)))]
    [(IrBinLt) (IrSomeValue (IrValueBool (opt-typed-lt? a b ty)))]
    [(IrBinLe) (IrSomeValue (IrValueBool (opt-typed-le? a b ty)))]
    [(IrBinGt) (IrSomeValue (IrValueBool (opt-typed-gt? a b ty)))]
    [(IrBinGe) (IrSomeValue (IrValueBool (opt-typed-ge? a b ty)))]
    [_ (IrNoValue)]))

(define (opt-shift-count-valid?
  [count : i64]
  [count-ty : AstType]
  [width : i64]) : bool
  (if (not (opt-integer-type? count-ty))
    false
    (if (opt-signed-integer-type? count-ty)
      (and (>= count 0) (< count width))
      (match count-ty
        [(AstTyU64) (< (cast count : u64) (cast width : u64))]
        [_ (< count width)]))))

(define (opt-fold-shl-value [a : i64] [count : i64] [ty : AstType]) : i64
  (match ty
    [(AstTyI64) (cast (shl (cast a : i64) (cast count : i64)) : i64)]
    [(AstTyI32) (cast (shl (cast a : i32) (cast count : i32)) : i64)]
    [(AstTyI16) (cast (shl (cast a : i16) (cast count : i16)) : i64)]
    [(AstTyI8) (cast (shl (cast a : i8) (cast count : i8)) : i64)]
    [(AstTyU64) (cast (shl (cast a : u64) (cast count : u64)) : i64)]
    [(AstTyU32) (cast (shl (cast a : u32) (cast count : u32)) : i64)]
    [(AstTyU16) (cast (shl (cast a : u16) (cast count : u16)) : i64)]
    [(AstTyU8) (cast (shl (cast a : u8) (cast count : u8)) : i64)]
    [_ 0]))

(define (opt-fold-shr-value [a : i64] [count : i64] [ty : AstType]) : i64
  (match ty
    [(AstTyI64) (cast (shr (cast a : i64) (cast count : i64)) : i64)]
    [(AstTyI32) (cast (shr (cast a : i32) (cast count : i32)) : i64)]
    [(AstTyI16) (cast (shr (cast a : i16) (cast count : i16)) : i64)]
    [(AstTyI8) (cast (shr (cast a : i8) (cast count : i8)) : i64)]
    [(AstTyU64) (cast (shr (cast a : u64) (cast count : u64)) : i64)]
    [(AstTyU32) (cast (shr (cast a : u32) (cast count : u32)) : i64)]
    [(AstTyU16) (cast (shr (cast a : u16) (cast count : u16)) : i64)]
    [(AstTyU8) (cast (shr (cast a : u8) (cast count : u8)) : i64)]
    [_ 0]))

(define (opt-fold-shift
  [op : CompilerIrBinOp]
  [a : i64]
  [rhs : CompilerIrValue]
  [rhs-ty : AstType]
  [ty : AstType]) : CompilerIrMaybeValue
  (match (opt-normalize-scalar-to-i64 rhs rhs-ty)
    [(OptSomeI64 count)
      (if (opt-shift-count-valid? count rhs-ty (opt-int-width ty))
        (match op
          [(IrBinShl)
            (IrSomeValue
              (IrValueI64
                (opt-normalize-int-to-i64 (opt-fold-shl-value a count ty) ty)))]
          [(IrBinShr)
            (IrSomeValue
              (IrValueI64
                (opt-normalize-int-to-i64 (opt-fold-shr-value a count ty) ty)))]
          [_ (IrNoValue)])
        (IrNoValue))]
    [(OptNoI64) (IrNoValue)]))

(define (opt-fold-int-char-binop
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [operand-ty : AstType]
  [rhs-ty : AstType]) : CompilerIrMaybeValue
  (match (opt-normalize-scalar-to-i64 lhs operand-ty)
    [(OptSomeI64 a)
      (match op
        [(IrBinShl) (opt-fold-shift op a rhs rhs-ty operand-ty)]
        [(IrBinShr) (opt-fold-shift op a rhs rhs-ty operand-ty)]
        [_
          (match (opt-normalize-scalar-to-i64 rhs operand-ty)
            [(OptSomeI64 b)
              (match op
                [(IrBinAdd)
                  (if (opt-integer-type? operand-ty)
                    (IrSomeValue
                      (IrValueI64 (opt-normalize-int-to-i64 (+ a b) operand-ty)))
                    (IrNoValue))]
                [(IrBinSub)
                  (if (opt-integer-type? operand-ty)
                    (IrSomeValue
                      (IrValueI64 (opt-normalize-int-to-i64 (- a b) operand-ty)))
                    (IrNoValue))]
                [(IrBinMul)
                  (if (opt-integer-type? operand-ty)
                    (IrSomeValue
                      (IrValueI64 (opt-normalize-int-to-i64 (* a b) operand-ty)))
                    (IrNoValue))]
                [(IrBinDiv)
                  (if (and
                    (opt-integer-type? operand-ty)
                    (opt-divmod-valid? a b operand-ty))
                    (IrSomeValue
                      (IrValueI64 (opt-fold-div-value a b operand-ty)))
                    (IrNoValue))]
                [(IrBinMod)
                  (if (and
                    (opt-integer-type? operand-ty)
                    (opt-divmod-valid? a b operand-ty))
                    (IrSomeValue
                      (IrValueI64 (opt-fold-mod-value a b operand-ty)))
                    (IrNoValue))]
                [(IrBinBitAnd)
                  (if (opt-integer-type? operand-ty)
                    (IrSomeValue
                      (IrValueI64
                        (opt-normalize-int-to-i64 (bit-and a b) operand-ty)))
                    (IrNoValue))]
                [(IrBinBitOr)
                  (if (opt-integer-type? operand-ty)
                    (IrSomeValue
                      (IrValueI64
                        (opt-normalize-int-to-i64 (bit-or a b) operand-ty)))
                    (IrNoValue))]
                [(IrBinBitXor)
                  (if (opt-integer-type? operand-ty)
                    (IrSomeValue
                      (IrValueI64
                        (opt-normalize-int-to-i64 (bit-xor a b) operand-ty)))
                    (IrNoValue))]
                [(IrBinEq) (opt-fold-compare op a b operand-ty)]
                [(IrBinNe) (opt-fold-compare op a b operand-ty)]
                [(IrBinLt) (opt-fold-compare op a b operand-ty)]
                [(IrBinLe) (opt-fold-compare op a b operand-ty)]
                [(IrBinGt) (opt-fold-compare op a b operand-ty)]
                [(IrBinGe) (opt-fold-compare op a b operand-ty)]
                [_ (IrNoValue)])]
            [(OptNoI64) (IrNoValue)])])]
    [(OptNoI64) (IrNoValue)]))

(define (opt-fold-bool
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]) : CompilerIrMaybeValue
  (match (opt-value-to-bool lhs)
    [(OptSomeBool a)
      (match (opt-value-to-bool rhs)
        [(OptSomeBool b)
          (match op
            [(IrBinAnd) (IrSomeValue (IrValueBool (and a b)))]
            [(IrBinOr) (IrSomeValue (IrValueBool (or a b)))]
            [(IrBinEq) (IrSomeValue (IrValueBool (= a b)))]
            [(IrBinNe) (IrSomeValue (IrValueBool (!= a b)))]
            [_ (IrNoValue)])]
        [(OptNoBool) (IrNoValue)])]
    [(OptNoBool) (IrNoValue)]))

(define (opt-fold-cast
  [src : OptKnownConst]
  [from-ty : AstType]
  [to-ty : AstType]) : CompilerIrMaybeValue
  (if (and (opt-int-or-char-type? from-ty) (opt-int-or-char-type? to-ty))
    (match src
      [(OptSomeConst value _)
        (match (opt-normalize-scalar-to-i64 value from-ty)
          [(OptSomeI64 n)
            (match (opt-normalize-const (IrValueI64 n) to-ty)
              [(OptSomeConst folded _) (IrSomeValue folded)]
              [(OptNoConst) (IrNoValue)])]
          [(OptNoI64) (IrNoValue)])]
      [(OptNoConst) (IrNoValue)])
    (IrNoValue)))

(define (opt-fold-binop
  [op : CompilerIrBinOp]
  [lhs : OptKnownConst]
  [rhs : OptKnownConst]
  [result-ty : AstType]) : CompilerIrMaybeValue
  (match lhs
    [(OptSomeConst lhs-value lhs-ty)
      (match rhs
        [(OptSomeConst rhs-value rhs-ty)
          (let
            [operand-ty : AstType
              (opt-binop-operand-type op lhs-ty rhs-ty result-ty)]
            (if (opt-bool-type? operand-ty)
              (opt-fold-bool op lhs-value rhs-value)
              (if (opt-int-or-char-type? operand-ty)
                (opt-fold-int-char-binop
                  op
                  lhs-value
                  rhs-value
                  operand-ty
                  rhs-ty)
                (IrNoValue))))]
        [(OptNoConst) (IrNoValue)])]
    [(OptNoConst) (IrNoValue)]))

(define (opt-fold-unop
  [op : CompilerIrUnOp]
  [src : OptKnownConst]
  [result-ty : AstType]) : CompilerIrMaybeValue
  (match src
    [(OptSomeConst value _)
      (match op
        [(IrUnNeg)
          (if (opt-integer-type? result-ty)
            (match (opt-normalize-scalar-to-i64 value result-ty)
              [(OptSomeI64 a)
                (IrSomeValue
                  (IrValueI64 (opt-normalize-int-to-i64 (- 0 a) result-ty)))]
              [(OptNoI64) (IrNoValue)])
            (IrNoValue))]
        [(IrUnNot)
          (if (opt-bool-type? result-ty)
            (match (opt-value-to-bool value)
              [(OptSomeBool a) (IrSomeValue (IrValueBool (not a)))]
              [(OptNoBool) (IrNoValue)])
            (IrNoValue))]
        [(IrUnBitNot)
          (if (opt-integer-type? result-ty)
            (match (opt-normalize-scalar-to-i64 value result-ty)
              [(OptSomeI64 a)
                (IrSomeValue
                  (IrValueI64 (opt-normalize-int-to-i64 (bit-not a) result-ty)))]
              [(OptNoI64) (IrNoValue)])
            (IrNoValue))])]
    [(OptNoConst) (IrNoValue)]))

;; --- strength reduction / algebraic identities (#924) -----------------------
;;
;; Rewrite only identities that are valid for all values of the instruction's
;; type. Division, modulo, and shifts intentionally have no identities here, so
;; potentially trapping/edge-sensitive operations stay in the IR.
(define (opt-i64-zero? [value : CompilerIrValue]) : bool
  (match value
    [(IrValueI64 n) (= n 0)]
    [_ false]))

(define (opt-i64-one? [value : CompilerIrValue]) : bool
  (match value
    [(IrValueI64 n) (= n 1)]
    [_ false]))

(define (opt-bool-true? [value : CompilerIrValue]) : bool
  (match value
    [(IrValueBool b) b]
    [_ false]))

(define (opt-bool-false? [value : CompilerIrValue]) : bool
  (match value
    [(IrValueBool b) (not b)]
    [_ false]))

(define (opt-strength-int-binop
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [resolved-lhs : CompilerIrValue]
  [resolved-rhs : CompilerIrValue]) : CompilerIrMaybeValue
  (match op
    [(IrBinAdd)
      (if (opt-i64-zero? resolved-rhs)
        (IrSomeValue lhs)
        (if (opt-i64-zero? resolved-lhs)
          (IrSomeValue rhs)
          (IrNoValue)))]
    [(IrBinSub)
      (if (opt-i64-zero? resolved-rhs)
        (IrSomeValue lhs)
        (IrNoValue))]
    [(IrBinMul)
      (core/cond
        (or (opt-i64-zero? resolved-lhs) (opt-i64-zero? resolved-rhs))
        (IrSomeValue (IrValueI64 0))
        (opt-i64-one? resolved-rhs)
        (IrSomeValue lhs)
        (opt-i64-one? resolved-lhs)
        (IrSomeValue rhs)
        (IrNoValue))]
    [_ (IrNoValue)]))

(define (opt-strength-bool-binop
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [resolved-lhs : CompilerIrValue]
  [resolved-rhs : CompilerIrValue]) : CompilerIrMaybeValue
  (match op
    [(IrBinAnd)
      (core/cond
        (or (opt-bool-false? resolved-lhs) (opt-bool-false? resolved-rhs))
        (IrSomeValue (IrValueBool false))
        (opt-bool-true? resolved-rhs)
        (IrSomeValue lhs)
        (opt-bool-true? resolved-lhs)
        (IrSomeValue rhs)
        (IrNoValue))]
    [(IrBinOr)
      (core/cond
        (or (opt-bool-true? resolved-lhs) (opt-bool-true? resolved-rhs))
        (IrSomeValue (IrValueBool true))
        (opt-bool-false? resolved-rhs)
        (IrSomeValue lhs)
        (opt-bool-false? resolved-lhs)
        (IrSomeValue rhs)
        (IrNoValue))]
    [_ (IrNoValue)]))

(define (opt-strength-binop
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [resolved-lhs : CompilerIrValue]
  [resolved-rhs : CompilerIrValue]
  [ty : AstType]) : CompilerIrMaybeValue
  (if (opt-integer-type? ty)
    (opt-strength-int-binop op lhs rhs resolved-lhs resolved-rhs)
    (if (opt-bool-type? ty)
      (opt-strength-bool-binop op lhs rhs resolved-lhs resolved-rhs)
      (IrNoValue))))

;; --- instruction / block / function / program traversal ----------------------
(defenum OptInstrResult
  (OptInstrResult OptConstEnv CompilerIrInstr))

(define (opt-invalidate-def
  [env : OptConstEnv]
  [dst : i64]
  [instr : CompilerIrInstr]) : OptInstrResult
  (OptInstrResult (opt-const-unbind env dst) instr))

(define (opt-fold-instr [env : OptConstEnv] [instr : CompilerIrInstr]) : OptInstrResult
  (match instr
    [(IrInstrMov dst value ty)
      (match (opt-resolve-known env value ty)
        [(OptSomeConst folded _)
          (OptInstrResult
            (opt-const-bind env dst folded ty)
            (IrInstrMov dst folded ty))]
        [(OptNoConst) (OptInstrResult (opt-const-unbind env dst) instr)])]
    [(IrInstrAlloc dst ty) (opt-invalidate-def env dst instr)]
    [(IrInstrAddrOf dst src) (opt-invalidate-def env dst instr)]
    [(IrInstrGep dst base offset ty) (opt-invalidate-def env dst instr)]
    [(IrInstrLoad dst src ty) (opt-invalidate-def env dst instr)]
    [(IrInstrCast dst src from-ty to-ty)
      (match (opt-fold-cast (opt-resolve-known env src from-ty) from-ty to-ty)
        [(IrSomeValue folded)
          (OptInstrResult
            (opt-const-bind env dst folded to-ty)
            (IrInstrMov dst folded to-ty))]
        [(IrNoValue) (OptInstrResult (opt-const-unbind env dst) instr)])]
    [(IrInstrBinOp dst op l r ty)
      (match (opt-fold-binop
        op
        (opt-resolve-known env l ty)
        (opt-resolve-known env r ty)
        ty)
        [(IrSomeValue folded)
          (OptInstrResult
            (opt-const-bind env dst folded ty)
            (IrInstrMov dst folded ty))]
        [(IrNoValue) (OptInstrResult (opt-const-unbind env dst) instr)])]
    [(IrInstrUnOp dst op v ty)
      (match (opt-fold-unop op (opt-resolve-known env v ty) ty)
        [(IrSomeValue folded)
          (OptInstrResult
            (opt-const-bind env dst folded ty)
            (IrInstrMov dst folded ty))]
        [(IrNoValue) (OptInstrResult (opt-const-unbind env dst) instr)])]
    [(IrInstrLaneId dst _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrSplat dst _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrVectorBinOp dst _ _ _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrVectorReduce dst _ _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrVectorCompare dst _ _ _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrMaskBinOp dst _ _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrMaskNot dst _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrMaskReduce dst _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrSelect dst _ _ _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrVectorLoad dst _ _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrPredicatedLoad dst _ _ _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrTailMask dst _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrEntryArgc dst) (opt-invalidate-def env dst instr)]
    [(IrInstrEntryArgv dst) (opt-invalidate-def env dst instr)]
    [(IrInstrEntryEnvp dst) (opt-invalidate-def env dst instr)]
    [(IrInstrCpuId dst _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrXgetbv dst _) (opt-invalidate-def env dst instr)]
    [(IrInstrSyscall dst _) (opt-invalidate-def env dst instr)]
    [(IrInstrCall dst name args ty) (opt-invalidate-def env dst instr)]
    [(IrInstrCallIndirect dst _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrCallIndirectC dst _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrTailCall _ _ _) (OptInstrResult env instr)]
    [(IrInstrPhi dst inputs ty) (opt-invalidate-def env dst instr)]
    [_ (OptInstrResult env instr)]))

(define (opt-fold-instrs [env : OptConstEnv] [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (match (opt-fold-instr env instr)
        [(OptInstrResult new-env new-instr)
          (compiler-ir-instr-cons
            new-instr
            (opt-fold-instrs new-env (box-get rest)))])]))

(define (opt-fold-instr-seq-from
  [env : OptConstEnv]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : CompilerIrInstrList
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (IrInstrNil)
    (match (opt-fold-instr env (compiler-ir-instr-seq-ref instrs index))
      [(OptInstrResult new-env new-instr)
        (compiler-ir-instr-cons
          new-instr
          (opt-fold-instr-seq-from new-env instrs (+ index 1)))])))

(define (opt-fold-instr-seq [env : OptConstEnv] [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (opt-fold-instr-seq-from env instrs 0))

(define (opt-strength-instr [env : OptConstEnv] [instr : CompilerIrInstr]) : OptInstrResult
  (match instr
    [(IrInstrMov dst value ty)
      (match (opt-resolve-known env value ty)
        [(OptSomeConst folded _)
          (OptInstrResult
            (opt-const-bind env dst folded ty)
            (IrInstrMov dst folded ty))]
        [(OptNoConst) (OptInstrResult (opt-const-unbind env dst) instr)])]
    [(IrInstrAlloc dst ty) (opt-invalidate-def env dst instr)]
    [(IrInstrAddrOf dst src) (opt-invalidate-def env dst instr)]
    [(IrInstrGep dst base offset ty) (opt-invalidate-def env dst instr)]
    [(IrInstrLoad dst src ty) (opt-invalidate-def env dst instr)]
    [(IrInstrCast dst src from-ty to-ty) (opt-invalidate-def env dst instr)]
    [(IrInstrBinOp dst op l r ty)
      (match (opt-strength-binop
        op
        l
        r
        (opt-resolve-value env l)
        (opt-resolve-value env r)
        ty)
        [(IrSomeValue replacement)
          (if (opt-const-value? replacement ty)
            (OptInstrResult
              (opt-const-bind env dst replacement ty)
              (IrInstrMov dst replacement ty))
            (OptInstrResult
              (opt-const-unbind env dst)
              (IrInstrMov dst replacement ty)))]
        [(IrNoValue) (OptInstrResult (opt-const-unbind env dst) instr)])]
    [(IrInstrUnOp dst op v ty) (opt-invalidate-def env dst instr)]
    [(IrInstrLaneId dst _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrSplat dst _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrVectorBinOp dst _ _ _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrVectorReduce dst _ _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrVectorCompare dst _ _ _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrMaskBinOp dst _ _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrMaskNot dst _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrMaskReduce dst _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrSelect dst _ _ _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrVectorLoad dst _ _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrPredicatedLoad dst _ _ _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrTailMask dst _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrEntryArgc dst) (opt-invalidate-def env dst instr)]
    [(IrInstrEntryArgv dst) (opt-invalidate-def env dst instr)]
    [(IrInstrEntryEnvp dst) (opt-invalidate-def env dst instr)]
    [(IrInstrCpuId dst _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrXgetbv dst _) (opt-invalidate-def env dst instr)]
    [(IrInstrSyscall dst _) (opt-invalidate-def env dst instr)]
    [(IrInstrCall dst name args ty) (opt-invalidate-def env dst instr)]
    [(IrInstrCallIndirect dst _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrCallIndirectC dst _ _ _) (opt-invalidate-def env dst instr)]
    [(IrInstrTailCall _ _ _) (OptInstrResult env instr)]
    [(IrInstrPhi dst inputs ty) (opt-invalidate-def env dst instr)]
    [_ (OptInstrResult env instr)]))

(define (opt-strength-instrs [env : OptConstEnv] [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (match (opt-strength-instr env instr)
        [(OptInstrResult new-env new-instr)
          (compiler-ir-instr-cons
            new-instr
            (opt-strength-instrs new-env (box-get rest)))])]))

;; --- dead-code elimination (#544) --------------------------------------------
;;
;; Conservative DCE matching the Rust optimizer's first slice: collect every IR
;; var id referenced as an operand anywhere in the function, then drop pure
;; temporary-producing instructions (`Mov`/`BinOp`/`UnOp`/`Phi`) whose result is
;; never used. Calls, stores, jumps, branches, and returns are kept regardless
;; (they have side effects or drive control flow). The used set is gathered over
;; the *whole reachable function* after CFG simplification, so a var used in
;; another remaining block is never dropped. DCE itself does not decide
;; reachability.
;; Used-var set: var ids referenced somewhere in the function. Backed by
;; I64I64Map (stored value 1 = present) for O(1) membership; previously a linked
;; list with O(n) contains and O(n^2) dedup'd inserts.
(define (opt-used-contains [set : I64I64Map] [var : i64]) : bool
  (i64-i64-map-contains? set var))

(define (opt-used-add [set : I64I64Map] [var : i64]) : I64I64Map
  (i64-i64-map-put set var 1))

(define (opt-collect-value-uses [set : I64I64Map] [value : CompilerIrValue]) : I64I64Map
  (match value
    [(IrValueVar id) (opt-used-add set id)]
    [_ set]))

(define (opt-collect-value-list-uses
  [set : I64I64Map]
  [values : CompilerIrValueList]) : I64I64Map
  (match values
    [(IrValueNil) set]
    [(IrValueCons value rest)
      (opt-collect-value-list-uses
        (opt-collect-value-uses set value)
        (box-get rest))]))

(define (opt-collect-call-args-array-uses
  [set : I64I64Map]
  [values : (Array CompilerIrValue)]
  [index : i64]) : I64I64Map
  (if (>= index (array-length values))
    set
    (opt-collect-call-args-array-uses
      (opt-collect-value-uses set (array-ref values index))
      values
      (+ index 1))))

(define (opt-collect-call-args-uses
  [set : I64I64Map]
  [args : CompilerIrCallArgs]) : I64I64Map
  (match args
    [(IrCallArgsNil) set]
    [(IrCallArgsOne value) (opt-collect-value-uses set value)]
    [(IrCallArgsTwo a b)
      (opt-collect-value-uses (opt-collect-value-uses set a) b)]
    [(IrCallArgsArray values) (opt-collect-call-args-array-uses set values 0)]))

(define (opt-collect-phi-uses
  [set : I64I64Map]
  [inputs : CompilerIrPhiInputList]) : I64I64Map
  (match inputs
    [(IrPhiInputNil) set]
    [(IrPhiInputCons value _ rest)
      (opt-collect-phi-uses (opt-collect-value-uses set value) (box-get rest))]))

(define (opt-collect-instr-uses [set : I64I64Map] [instr : CompilerIrInstr]) : I64I64Map
  (match instr
    [(IrInstrMov _ src _) (opt-collect-value-uses set src)]
    [(IrInstrBinOp _ _ l r _)
      (opt-collect-value-uses (opt-collect-value-uses set l) r)]
    [(IrInstrUnOp _ _ src _) (opt-collect-value-uses set src)]
    [(IrInstrCall _ _ args _) (opt-collect-call-args-uses set args)]
    [(IrInstrCallIndirect _ func args _)
      (opt-collect-call-args-uses (opt-collect-value-uses set func) args)]
    [(IrInstrCallIndirectC _ func args _)
      (opt-collect-call-args-uses (opt-collect-value-uses set func) args)]
    [(IrInstrTailCall _ args _) (opt-collect-call-args-uses set args)]
    [(IrInstrStore _ value _) (opt-collect-value-uses set value)]
    ;; Pointer/memory ops carry operand uses too; missing any of these would let
    ;; DCE wrongly drop a definition that feeds an address/load/store/cast.
    [(IrInstrAddrOf _ src) (opt-used-add set src)]
    [(IrInstrGep _ base offset _)
      (opt-collect-value-uses (opt-collect-value-uses set base) offset)]
    [(IrInstrLoad _ src _) (opt-collect-value-uses set src)]
    [(IrInstrStorePtr ptr value _)
      (opt-collect-value-uses (opt-collect-value-uses set ptr) value)]
    [(IrInstrCopyBytes dst src _)
      (opt-collect-value-uses (opt-collect-value-uses set dst) src)]
    [(IrInstrBoundsCheck index length _)
      (opt-collect-value-uses (opt-collect-value-uses set index) length)]
    [(IrInstrCast _ src _ _) (opt-collect-value-uses set src)]
    [(IrInstrSplat _ value _ _) (opt-collect-value-uses set value)]
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (opt-collect-value-uses (opt-collect-value-uses set lhs) rhs)]
    [(IrInstrVectorReduce _ _ src _ _) (opt-collect-value-uses set src)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (opt-collect-value-uses (opt-collect-value-uses set lhs) rhs)]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (opt-collect-value-uses (opt-collect-value-uses set lhs) rhs)]
    [(IrInstrMaskNot _ src _) (opt-collect-value-uses set src)]
    [(IrInstrMaskReduce _ _ src _) (opt-collect-value-uses set src)]
    [(IrInstrSelect _ mask on-true on-false _ _)
      (opt-collect-value-uses
        (opt-collect-value-uses (opt-collect-value-uses set mask) on-true)
        on-false)]
    [(IrInstrVectorLoad _ base index _ _)
      (opt-collect-value-uses (opt-collect-value-uses set base) index)]
    [(IrInstrVectorStore base index value _ _)
      (opt-collect-value-uses
        (opt-collect-value-uses (opt-collect-value-uses set base) index)
        value)]
    [(IrInstrPredicatedStore base index value mask _ _)
      (opt-collect-value-uses
        (opt-collect-value-uses
          (opt-collect-value-uses (opt-collect-value-uses set base) index)
          value)
        mask)]
    [(IrInstrPredicatedLoad _ base index mask _ _)
      (opt-collect-value-uses
        (opt-collect-value-uses (opt-collect-value-uses set base) index)
        mask)]
    [(IrInstrTailMask _ index length _)
      (opt-collect-value-uses (opt-collect-value-uses set index) length)]
    [(IrInstrEntryArgc _) set]
    [(IrInstrEntryArgv _) set]
    [(IrInstrEntryEnvp _) set]
    [(IrInstrCpuId _ leaf subleaf _)
      (opt-collect-value-uses (opt-collect-value-uses set leaf) subleaf)]
    [(IrInstrXgetbv _ index) (opt-collect-value-uses set index)]
    [(IrInstrSyscall _ args) (opt-collect-call-args-uses set args)]
    [(IrInstrBranch cond _ _) (opt-collect-value-uses set cond)]
    [(IrInstrReturn maybe)
      (match maybe
        [(IrSomeValue value) (opt-collect-value-uses set value)]
        [(IrNoValue) set])]
    [(IrInstrPhi _ inputs _) (opt-collect-phi-uses set inputs)]
    ;; #2386: register-group ops use their operands -- Pack uses each word value,
    ;; Word uses the source group. Omitting these would let DCE drop a definition
    ;; that feeds a Pack/Word.
    [(IrInstrPack _ words _) (opt-collect-value-list-uses set words)]
    [(IrInstrWord _ src _ _) (opt-collect-value-uses set src)]
    ;; `IrInstrAlloc` has no operand uses; `IrInstrJump` has none either.
    [_ set]))

(define (opt-collect-instrs-uses
  [set : I64I64Map]
  [instrs : CompilerIrInstrList]) : I64I64Map
  (match instrs
    [(IrInstrNil) set]
    [(IrInstrCons instr rest)
      (opt-collect-instrs-uses
        (opt-collect-instr-uses set instr)
        (box-get rest))]))

(define (opt-collect-instr-seq-uses-from
  [set : I64I64Map]
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]) : I64I64Map
  (if (>= index count)
    set
    (opt-collect-instr-seq-uses-from
      (opt-collect-instr-uses set (array-ref slots index))
      slots
      (+ index 1)
      count)))

(define (opt-collect-instr-seq-uses
  [set : I64I64Map]
  [instrs : CompilerIrInstrSeq]) : I64I64Map
  (opt-collect-instr-seq-uses-from
    set
    (struct-get instrs slots)
    0
    (struct-get instrs len)))

(define (opt-collect-blocks-uses
  [set : I64I64Map]
  [blocks : CompilerIrBlockList]) : I64I64Map
  (match blocks
    [(IrBlockNil) set]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (opt-collect-blocks-uses
            (opt-collect-instr-seq-uses set instrs)
            (box-get rest))])]
    [(IrBlockArray seq)
      (opt-collect-blocks-uses set (compiler-ir-block-seq-to-list seq))]))

;; Division, modulo, and shift can trap at runtime (zero divisor, signed
;; MIN / -1, shift count out of range), so a BinOp using one of those operators
;; is NOT pure: dropping it as dead would elide the trap the safe-code contract
;; requires. These ops must stay in the IR even when their result is unused.
(define (opt-binop-traps? [op : CompilerIrBinOp]) : bool
  (match op
    [(IrBinDiv) true]
    [(IrBinMod) true]
    [(IrBinShl) true]
    [(IrBinShr) true]
    [_ false]))

;; A pure temporary-producing instruction is dead when its result var is unused.
;; Calls (side-effecting) and control-flow instructions are never dead here.
(define (opt-instr-dead? [set : I64I64Map] [instr : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrMov dst _ _) (not (opt-used-contains set dst))]
    [(IrInstrBinOp dst op _ _ _)
      (and (not (opt-binop-traps? op)) (not (opt-used-contains set dst)))]
    [(IrInstrUnOp dst _ _ _) (not (opt-used-contains set dst))]
    [(IrInstrPhi dst _ _) (not (opt-used-contains set dst))]
    [(IrInstrLaneId dst _ _) (not (opt-used-contains set dst))]
    [(IrInstrSplat dst _ _ _) (not (opt-used-contains set dst))]
    [(IrInstrVectorBinOp dst _ _ _ _ _) (not (opt-used-contains set dst))]
    [(IrInstrVectorReduce dst _ _ _ _) (not (opt-used-contains set dst))]
    [(IrInstrVectorCompare dst _ _ _ _ _) (not (opt-used-contains set dst))]
    [(IrInstrMaskBinOp dst _ _ _ _) (not (opt-used-contains set dst))]
    [(IrInstrMaskNot dst _ _) (not (opt-used-contains set dst))]
    [(IrInstrMaskReduce dst _ _ _) (not (opt-used-contains set dst))]
    [(IrInstrSelect dst _ _ _ _ _) (not (opt-used-contains set dst))]
    [(IrInstrTailMask dst _ _ _) (not (opt-used-contains set dst))]
    [_ false]))

(define (opt-dce-instrs [set : I64I64Map] [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (if (opt-instr-dead? set instr)
        (opt-dce-instrs set (box-get rest))
        (compiler-ir-instr-cons instr (opt-dce-instrs set (box-get rest))))]))

(define (opt-dce-instr-seq-from
  [set : I64I64Map]
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]) : CompilerIrInstrList
  (if (>= index count)
    (IrInstrNil)
    (let
      [instr : CompilerIrInstr (array-ref slots index)]
      [rest : CompilerIrInstrList
        (opt-dce-instr-seq-from set slots (+ index 1) count)]
      (if (opt-instr-dead? set instr)
        rest
        (compiler-ir-instr-cons instr rest)))))

(define (opt-dce-instr-seq [set : I64I64Map] [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (opt-dce-instr-seq-from
    set
    (struct-get instrs slots)
    0
    (struct-get instrs len)))

(define (opt-dce-block [set : I64I64Map] [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      (compiler-ir-block label (opt-dce-instr-seq set instrs))]))

(define (opt-dce-block-list [set : I64I64Map] [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (compiler-ir-block-cons
        (opt-dce-block set block)
        (opt-dce-block-list set (box-get rest)))]
    [(IrBlockArray seq)
      (opt-dce-block-list set (compiler-ir-block-seq-to-list seq))]))

(define (opt-used-array-fill
  [items : (Array bool)]
  [index : i64]
  [value : bool]) : unit
  (if (>= index (array-length items))
    unit
    (begin
      (array-set! items index value)
      (opt-used-array-fill items (+ index 1) value))))

(define (opt-used-array-new [count : i64]) : (Array bool)
  (let
    [items : (Array bool) (make-array bool count)]
    (begin
      (opt-used-array-fill items 0 false)
      items)))

(define (opt-used-array-add [items : (Array bool)] [var : i64]) : unit
  (if (< var 0)
    unit
    (if (>= var (array-length items))
      unit
      (begin
        (array-set! items var true)
        unit))))

(define (opt-used-array-contains [items : (Array bool)] [var : i64]) : bool
  (if (< var 0)
    false
    (if (>= var (array-length items))
      false
      (array-ref items var))))

(define (opt-collect-value-uses-array
  [items : (Array bool)]
  [value : CompilerIrValue]) : unit
  (match value
    [(IrValueVar id) (opt-used-array-add items id)]
    [_ unit]))

(define (opt-collect-value-list-uses-array
  [items : (Array bool)]
  [values : CompilerIrValueList]) : unit
  (match values
    [(IrValueNil) unit]
    [(IrValueCons value rest)
      (begin
        (opt-collect-value-uses-array items value)
        (opt-collect-value-list-uses-array items (box-get rest)))]))

(define (opt-collect-call-args-array-uses-array
  [items : (Array bool)]
  [values : (Array CompilerIrValue)]
  [index : i64]) : unit
  (if (>= index (array-length values))
    unit
    (begin
      (opt-collect-value-uses-array items (array-ref values index))
      (opt-collect-call-args-array-uses-array items values (+ index 1)))))

(define (opt-collect-call-args-uses-array
  [items : (Array bool)]
  [args : CompilerIrCallArgs]) : unit
  (match args
    [(IrCallArgsNil) unit]
    [(IrCallArgsOne value) (opt-collect-value-uses-array items value)]
    [(IrCallArgsTwo a b)
      (begin
        (opt-collect-value-uses-array items a)
        (opt-collect-value-uses-array items b))]
    [(IrCallArgsArray values)
      (opt-collect-call-args-array-uses-array items values 0)]))

(define (opt-collect-phi-uses-array
  [items : (Array bool)]
  [inputs : CompilerIrPhiInputList]) : unit
  (match inputs
    [(IrPhiInputNil) unit]
    [(IrPhiInputCons value _ rest)
      (begin
        (opt-collect-value-uses-array items value)
        (opt-collect-phi-uses-array items (box-get rest)))]))

(define (opt-collect-instr-uses-array
  [items : (Array bool)]
  [instr : CompilerIrInstr]) : unit
  (match instr
    [(IrInstrMov _ src _) (opt-collect-value-uses-array items src)]
    [(IrInstrBinOp _ _ l r _)
      (begin
        (opt-collect-value-uses-array items l)
        (opt-collect-value-uses-array items r))]
    [(IrInstrUnOp _ _ src _) (opt-collect-value-uses-array items src)]
    [(IrInstrCall _ _ args _) (opt-collect-call-args-uses-array items args)]
    [(IrInstrCallIndirect _ func args _)
      (begin
        (opt-collect-value-uses-array items func)
        (opt-collect-call-args-uses-array items args))]
    [(IrInstrCallIndirectC _ func args _)
      (begin
        (opt-collect-value-uses-array items func)
        (opt-collect-call-args-uses-array items args))]
    [(IrInstrTailCall _ args _) (opt-collect-call-args-uses-array items args)]
    [(IrInstrStore _ value _) (opt-collect-value-uses-array items value)]
    [(IrInstrAddrOf _ src) (opt-used-array-add items src)]
    [(IrInstrGep _ base offset _)
      (begin
        (opt-collect-value-uses-array items base)
        (opt-collect-value-uses-array items offset))]
    [(IrInstrLoad _ src _) (opt-collect-value-uses-array items src)]
    [(IrInstrStorePtr ptr value _)
      (begin
        (opt-collect-value-uses-array items ptr)
        (opt-collect-value-uses-array items value))]
    [(IrInstrCopyBytes dst src _)
      (begin
        (opt-collect-value-uses-array items dst)
        (opt-collect-value-uses-array items src))]
    [(IrInstrBoundsCheck index length _)
      (begin
        (opt-collect-value-uses-array items index)
        (opt-collect-value-uses-array items length))]
    [(IrInstrCast _ src _ _) (opt-collect-value-uses-array items src)]
    [(IrInstrSplat _ value _ _) (opt-collect-value-uses-array items value)]
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (begin
        (opt-collect-value-uses-array items lhs)
        (opt-collect-value-uses-array items rhs))]
    [(IrInstrVectorReduce _ _ src _ _) (opt-collect-value-uses-array items src)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (begin
        (opt-collect-value-uses-array items lhs)
        (opt-collect-value-uses-array items rhs))]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (begin
        (opt-collect-value-uses-array items lhs)
        (opt-collect-value-uses-array items rhs))]
    [(IrInstrMaskNot _ src _) (opt-collect-value-uses-array items src)]
    [(IrInstrMaskReduce _ _ src _) (opt-collect-value-uses-array items src)]
    [(IrInstrSelect _ mask on-true on-false _ _)
      (begin
        (opt-collect-value-uses-array items mask)
        (opt-collect-value-uses-array items on-true)
        (opt-collect-value-uses-array items on-false))]
    [(IrInstrVectorLoad _ base index _ _)
      (begin
        (opt-collect-value-uses-array items base)
        (opt-collect-value-uses-array items index))]
    [(IrInstrVectorStore base index value _ _)
      (begin
        (opt-collect-value-uses-array items base)
        (opt-collect-value-uses-array items index)
        (opt-collect-value-uses-array items value))]
    [(IrInstrPredicatedStore base index value mask _ _)
      (begin
        (opt-collect-value-uses-array items base)
        (opt-collect-value-uses-array items index)
        (opt-collect-value-uses-array items value)
        (opt-collect-value-uses-array items mask))]
    [(IrInstrPredicatedLoad _ base index mask _ _)
      (begin
        (opt-collect-value-uses-array items base)
        (opt-collect-value-uses-array items index)
        (opt-collect-value-uses-array items mask))]
    [(IrInstrTailMask _ index length _)
      (begin
        (opt-collect-value-uses-array items index)
        (opt-collect-value-uses-array items length))]
    [(IrInstrEntryArgc _) unit]
    [(IrInstrEntryArgv _) unit]
    [(IrInstrEntryEnvp _) unit]
    [(IrInstrCpuId _ leaf subleaf _)
      (begin
        (opt-collect-value-uses-array items leaf)
        (opt-collect-value-uses-array items subleaf))]
    [(IrInstrXgetbv _ index) (opt-collect-value-uses-array items index)]
    [(IrInstrSyscall _ args) (opt-collect-call-args-uses-array items args)]
    [(IrInstrBranch cond _ _) (opt-collect-value-uses-array items cond)]
    [(IrInstrReturn maybe)
      (match maybe
        [(IrSomeValue value) (opt-collect-value-uses-array items value)]
        [(IrNoValue) unit])]
    [(IrInstrPhi _ inputs _) (opt-collect-phi-uses-array items inputs)]
    ;; #2386: register-group ops use their operands (Pack: each word; Word: src).
    [(IrInstrPack _ words _) (opt-collect-value-list-uses-array items words)]
    [(IrInstrWord _ src _ _) (opt-collect-value-uses-array items src)]
    [_ unit]))

(define (opt-collect-instr-seq-uses-array
  [items : (Array bool)]
  [instrs : CompilerIrInstrSeq]) : unit
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (opt-collect-instr-uses-array items (array-ref slots index))
          (set! index (+ index 1))))
      unit)))

(define (opt-collect-blocks-uses-array-into
  [items : (Array bool)]
  [blocks : CompilerIrBlockList]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (begin
            (opt-collect-instr-seq-uses-array items instrs)
            (opt-collect-blocks-uses-array-into items (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-collect-blocks-uses-array-into
        items
        (compiler-ir-block-seq-to-list seq))]))

(define (opt-collect-blocks-uses-array
  [vars : i64]
  [blocks : CompilerIrBlockList]) : (Array bool)
  (let
    [items : (Array bool) (opt-used-array-new vars)]
    (begin
      (opt-collect-blocks-uses-array-into items blocks)
      items)))

(define (opt-instr-dead-array? [items : (Array bool)] [instr : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrMov dst _ _) (not (opt-used-array-contains items dst))]
    [(IrInstrBinOp dst op _ _ _)
      (and
        (not (opt-binop-traps? op))
        (not (opt-used-array-contains items dst)))]
    [(IrInstrUnOp dst _ _ _) (not (opt-used-array-contains items dst))]
    [(IrInstrPhi dst _ _) (not (opt-used-array-contains items dst))]
    [(IrInstrLaneId dst _ _) (not (opt-used-array-contains items dst))]
    [(IrInstrSplat dst _ _ _) (not (opt-used-array-contains items dst))]
    [(IrInstrVectorBinOp dst _ _ _ _ _)
      (not (opt-used-array-contains items dst))]
    [(IrInstrVectorReduce dst _ _ _ _)
      (not (opt-used-array-contains items dst))]
    [(IrInstrVectorCompare dst _ _ _ _ _)
      (not (opt-used-array-contains items dst))]
    [(IrInstrMaskBinOp dst _ _ _ _) (not (opt-used-array-contains items dst))]
    [(IrInstrMaskNot dst _ _) (not (opt-used-array-contains items dst))]
    [(IrInstrMaskReduce dst _ _ _) (not (opt-used-array-contains items dst))]
    [(IrInstrSelect dst _ _ _ _ _) (not (opt-used-array-contains items dst))]
    [(IrInstrTailMask dst _ _ _) (not (opt-used-array-contains items dst))]
    [_ false]))

(define (opt-dce-instr-seq-array
  [items : (Array bool)]
  [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [index : i64 (- (struct-get instrs len) 1)]
    [out : CompilerIrInstrList IrInstrNil]
    (begin
      (while (>= index 0)
        (begin
          (if (opt-instr-dead-array? items (array-ref slots index))
            unit
            (set! out (compiler-ir-instr-cons (array-ref slots index) out)))
          (set! index (- index 1))))
      out)))

(define (opt-dce-block-array [items : (Array bool)] [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      (compiler-ir-block label (opt-dce-instr-seq-array items instrs))]))

(define (opt-dce-block-list-array
  [items : (Array bool)]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (compiler-ir-block-cons
        (opt-dce-block-array items block)
        (opt-dce-block-list-array items (box-get rest)))]
    [(IrBlockArray seq)
      (opt-dce-block-list-array items (compiler-ir-block-seq-to-list seq))]))

;; --- aggregate allocation candidate analysis (#1487) ------------------------
;;
;; This is intentionally analysis-only. It recognizes heap aggregate allocations
;; that stay local to a function and records the constant-offset derived pointers
;; plus load/store accesses that a later scalar-replacement slice can consume.
(define (opt-aggregate-fixed-type? [ty : AstType]) : bool
  (match ty
    [(AstTyStruct _) true]
    [(AstTyStructArgs _ _) true]
    [(AstTyEnum _) true]
    [(AstTyEnumArgs _ _) true]
    [(AstTyTuple _) true]
    [(AstTyArray _ _) true]
    [_ false]))

(define (opt-aggregate-tl-alloc-size [args : CompilerIrCallArgs]) : OptMaybeI64
  (match args
    [(IrCallArgsOne value)
      (match value
        [(IrValueI64 size) (OptSomeI64 size)]
        [_ (OptNoI64)])]
    [_ (OptNoI64)]))

(define (opt-aggregate-direct-alloc [instr : CompilerIrInstr]) : OptMaybeAggregateAlloc
  (match instr
    [(IrInstrCall dst name args ty)
      (if (and (string-eq name "tl_alloc") (opt-aggregate-fixed-type? ty))
        (match (opt-aggregate-tl-alloc-size args)
          [(OptSomeI64 size)
            (if (> size 0)
              (OptSomeAggregateAlloc dst ty size)
              (OptNoAggregateAlloc))]
          [(OptNoI64) (OptNoAggregateAlloc)])
        (OptNoAggregateAlloc))]
    [_ (OptNoAggregateAlloc)]))

(define (opt-aggregate-pointer-list-lookup
  [ptrs : OptAggregatePointerList]
  [var : i64]) : OptMaybeI64
  (match ptrs
    [(OptAggregatePointerNil) (OptNoI64)]
    [(OptAggregatePointerCons ptr rest)
      (let
        [rest : OptAggregatePointerList (box-get rest)]
        (match ptr
          [(OptAggregatePointer ptr-var offset)
            (if (= ptr-var var)
              (OptSomeI64 offset)
              (opt-aggregate-pointer-list-lookup rest var))]))]))

(define (opt-aggregate-value-offset
  [base : i64]
  [ptrs : OptAggregatePointerList]
  [value : CompilerIrValue]) : OptMaybeI64
  (match value
    [(IrValueVar var)
      (if (= var base)
        (OptSomeI64 0)
        (opt-aggregate-pointer-list-lookup ptrs var))]
    [_ (OptNoI64)]))

(define (opt-aggregate-value-has-pointer?
  [base : i64]
  [ptrs : OptAggregatePointerList]
  [value : CompilerIrValue]) : bool
  (match (opt-aggregate-value-offset base ptrs value)
    [(OptSomeI64 _) true]
    [(OptNoI64) false]))

(define (opt-aggregate-value-list-has-pointer?
  [base : i64]
  [ptrs : OptAggregatePointerList]
  [values : CompilerIrValueList]) : bool
  (match values
    [(IrValueNil) false]
    [(IrValueCons value rest)
      (or
        (opt-aggregate-value-has-pointer? base ptrs value)
        (opt-aggregate-value-list-has-pointer? base ptrs (box-get rest)))]))

(define (opt-aggregate-call-args-array-has-pointer?
  [base : i64]
  [ptrs : OptAggregatePointerList]
  [values : (Array CompilerIrValue)]
  [index : i64]) : bool
  (if (>= index (array-length values))
    false
    (or
      (opt-aggregate-value-has-pointer? base ptrs (array-ref values index))
      (opt-aggregate-call-args-array-has-pointer? base ptrs values (+ index 1)))))

(define (opt-aggregate-call-args-has-pointer?
  [base : i64]
  [ptrs : OptAggregatePointerList]
  [args : CompilerIrCallArgs]) : bool
  (match args
    [(IrCallArgsNil) false]
    [(IrCallArgsOne value) (opt-aggregate-value-has-pointer? base ptrs value)]
    [(IrCallArgsTwo a b)
      (or
        (opt-aggregate-value-has-pointer? base ptrs a)
        (opt-aggregate-value-has-pointer? base ptrs b))]
    [(IrCallArgsArray values)
      (opt-aggregate-call-args-array-has-pointer? base ptrs values 0)]))

(define (opt-aggregate-maybe-value-has-pointer?
  [base : i64]
  [ptrs : OptAggregatePointerList]
  [maybe : CompilerIrMaybeValue]) : bool
  (match maybe
    [(IrNoValue) false]
    [(IrSomeValue value) (opt-aggregate-value-has-pointer? base ptrs value)]))

(define (opt-aggregate-phi-inputs-have-pointer?
  [base : i64]
  [ptrs : OptAggregatePointerList]
  [inputs : CompilerIrPhiInputList]) : bool
  (match inputs
    [(IrPhiInputNil) false]
    [(IrPhiInputCons value _ rest)
      (or
        (opt-aggregate-value-has-pointer? base ptrs value)
        (opt-aggregate-phi-inputs-have-pointer? base ptrs (box-get rest)))]))

(define (opt-aggregate-raw-var-is-pointer?
  [base : i64]
  [ptrs : OptAggregatePointerList]
  [var : i64]) : bool
  (or
    (= var base)
    (match (opt-aggregate-pointer-list-lookup ptrs var)
      [(OptSomeI64 _) true]
      [(OptNoI64) false])))

(define (opt-aggregate-instr-has-pointer?
  [instr : CompilerIrInstr]
  [base : i64]
  [ptrs : OptAggregatePointerList]) : bool
  (match instr
    [(IrInstrMov _ src _) (opt-aggregate-value-has-pointer? base ptrs src)]
    [(IrInstrAddrOf _ src) (opt-aggregate-raw-var-is-pointer? base ptrs src)]
    [(IrInstrGep _ src offset _)
      (or
        (opt-aggregate-value-has-pointer? base ptrs src)
        (opt-aggregate-value-has-pointer? base ptrs offset))]
    [(IrInstrLoad _ src _) (opt-aggregate-value-has-pointer? base ptrs src)]
    [(IrInstrStorePtr ptr value _)
      (or
        (opt-aggregate-value-has-pointer? base ptrs ptr)
        (opt-aggregate-value-has-pointer? base ptrs value))]
    [(IrInstrCopyBytes dst src _)
      (or
        (opt-aggregate-value-has-pointer? base ptrs dst)
        (opt-aggregate-value-has-pointer? base ptrs src))]
    [(IrInstrBoundsCheck index length _)
      (or
        (opt-aggregate-value-has-pointer? base ptrs index)
        (opt-aggregate-value-has-pointer? base ptrs length))]
    [(IrInstrCast _ src _ _) (opt-aggregate-value-has-pointer? base ptrs src)]
    [(IrInstrBinOp _ _ lhs rhs _)
      (or
        (opt-aggregate-value-has-pointer? base ptrs lhs)
        (opt-aggregate-value-has-pointer? base ptrs rhs))]
    [(IrInstrUnOp _ _ src _) (opt-aggregate-value-has-pointer? base ptrs src)]
    [(IrInstrSplat _ src _ _) (opt-aggregate-value-has-pointer? base ptrs src)]
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (or
        (opt-aggregate-value-has-pointer? base ptrs lhs)
        (opt-aggregate-value-has-pointer? base ptrs rhs))]
    [(IrInstrVectorReduce _ _ src _ _)
      (opt-aggregate-value-has-pointer? base ptrs src)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (or
        (opt-aggregate-value-has-pointer? base ptrs lhs)
        (opt-aggregate-value-has-pointer? base ptrs rhs))]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (or
        (opt-aggregate-value-has-pointer? base ptrs lhs)
        (opt-aggregate-value-has-pointer? base ptrs rhs))]
    [(IrInstrMaskNot _ src _) (opt-aggregate-value-has-pointer? base ptrs src)]
    [(IrInstrMaskReduce _ _ src _)
      (opt-aggregate-value-has-pointer? base ptrs src)]
    [(IrInstrSelect _ mask on-true on-false _ _)
      (or
        (opt-aggregate-value-has-pointer? base ptrs mask)
        (or
          (opt-aggregate-value-has-pointer? base ptrs on-true)
          (opt-aggregate-value-has-pointer? base ptrs on-false)))]
    [(IrInstrVectorLoad _ vector-base index _ _)
      (or
        (opt-aggregate-value-has-pointer? base ptrs vector-base)
        (opt-aggregate-value-has-pointer? base ptrs index))]
    [(IrInstrVectorStore vector-base index value _ _)
      (or
        (opt-aggregate-value-has-pointer? base ptrs vector-base)
        (or
          (opt-aggregate-value-has-pointer? base ptrs index)
          (opt-aggregate-value-has-pointer? base ptrs value)))]
    [(IrInstrPredicatedStore store-base index value mask _ _)
      (or
        (opt-aggregate-value-has-pointer? base ptrs store-base)
        (or
          (opt-aggregate-value-has-pointer? base ptrs index)
          (or
            (opt-aggregate-value-has-pointer? base ptrs value)
            (opt-aggregate-value-has-pointer? base ptrs mask))))]
    [(IrInstrPredicatedLoad _ load-base index mask _ _)
      (or
        (opt-aggregate-value-has-pointer? base ptrs load-base)
        (or
          (opt-aggregate-value-has-pointer? base ptrs index)
          (opt-aggregate-value-has-pointer? base ptrs mask)))]
    [(IrInstrTailMask _ index length _)
      (or
        (opt-aggregate-value-has-pointer? base ptrs index)
        (opt-aggregate-value-has-pointer? base ptrs length))]
    [(IrInstrEntryArgc _) false]
    [(IrInstrEntryArgv _) false]
    [(IrInstrEntryEnvp _) false]
    [(IrInstrCpuId _ leaf subleaf _)
      (or
        (opt-aggregate-value-has-pointer? base ptrs leaf)
        (opt-aggregate-value-has-pointer? base ptrs subleaf))]
    [(IrInstrXgetbv _ index) (opt-aggregate-value-has-pointer? base ptrs index)]
    [(IrInstrSyscall _ args)
      (opt-aggregate-call-args-has-pointer? base ptrs args)]
    [(IrInstrCall _ _ args _)
      (opt-aggregate-call-args-has-pointer? base ptrs args)]
    [(IrInstrTailCall _ args _)
      (opt-aggregate-call-args-has-pointer? base ptrs args)]
    [(IrInstrStore _ value _)
      (opt-aggregate-value-has-pointer? base ptrs value)]
    [(IrInstrBranch cond _ _) (opt-aggregate-value-has-pointer? base ptrs cond)]
    [(IrInstrReturn maybe)
      (opt-aggregate-maybe-value-has-pointer? base ptrs maybe)]
    [(IrInstrPhi _ inputs _)
      (opt-aggregate-phi-inputs-have-pointer? base ptrs inputs)]
    [_ false]))

(define (opt-aggregate-instrs-touch-candidate?
  [instrs : CompilerIrInstrList]
  [base : i64]
  [ptrs : OptAggregatePointerList]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr rest)
      (or
        (opt-aggregate-instr-has-pointer? instr base ptrs)
        (opt-aggregate-instrs-touch-candidate? (box-get rest) base ptrs))]))

(define (opt-aggregate-instr-known-safe?
  [instr : CompilerIrInstr]
  [base : i64]
  [ptrs : OptAggregatePointerList]) : bool
  (match instr
    [(IrInstrCall dst name _ _) (and (= dst base) (string-eq name "tl_alloc"))]
    [(IrInstrGep _ src offset _)
      (match (opt-aggregate-value-offset base ptrs src)
        [(OptSomeI64 _)
          (match offset
            [(IrValueI64 _) true]
            [_ false])]
        [(OptNoI64) false])]
    [(IrInstrLoad _ src _) (opt-aggregate-value-has-pointer? base ptrs src)]
    [(IrInstrStorePtr ptr value _)
      (and
        (opt-aggregate-value-has-pointer? base ptrs ptr)
        (not (opt-aggregate-value-has-pointer? base ptrs value)))]
    [(IrInstrCopyBytes _ _ _) false]
    [_ false]))

(define (opt-aggregate-instr-crosses-unknown-effect?
  [instr : CompilerIrInstr]
  [base : i64]
  [ptrs : OptAggregatePointerList]) : bool
  (if (opt-aggregate-instr-known-safe? instr base ptrs)
    false
    (compiler-ir-effect-invalidates-cse? (compiler-ir-instr-effect instr))))

(define (opt-aggregate-scan-instrs
  [base : i64]
  [ty : AstType]
  [size : i64]
  [instrs : CompilerIrInstrList]
  [ptrs : OptAggregatePointerList]
  [accesses : OptAggregateAccessList]
  [seen-alloc : bool]) : OptAggregateScanResult
  (match instrs
    [(IrInstrNil)
      (if seen-alloc
        (OptAggregateScanOk ptrs accesses)
        (OptAggregateScanReject))]
    [(IrInstrCons instr rest)
      (if (not seen-alloc)
        (match (opt-aggregate-direct-alloc instr)
          [(OptSomeAggregateAlloc dst alloc-ty alloc-size)
            (if (and
              (= dst base)
              (and (= alloc-size size) (opt-type-eq alloc-ty ty)))
              (opt-aggregate-scan-instrs
                base
                ty
                size
                (box-get rest)
                ptrs
                accesses
                true)
              (opt-aggregate-scan-instrs
                base
                ty
                size
                (box-get rest)
                ptrs
                accesses
                false))]
          [(OptNoAggregateAlloc)
            (opt-aggregate-scan-instrs
              base
              ty
              size
              (box-get rest)
              ptrs
              accesses
              false)])
        (match instr
          [(IrInstrGep dst src offset _)
            (match (opt-aggregate-value-offset base ptrs src)
              [(OptSomeI64 base-offset)
                (match offset
                  [(IrValueI64 field-offset)
                    (opt-aggregate-scan-instrs
                      base
                      ty
                      size
                      (box-get rest)
                      (OptAggregatePointerCons
                        (OptAggregatePointer dst (+ base-offset field-offset))
                        (box ptrs))
                      accesses
                      true)]
                  [_ (OptAggregateScanReject)])]
              [(OptNoI64)
                (if (opt-aggregate-value-has-pointer? base ptrs offset)
                  (OptAggregateScanReject)
                  (opt-aggregate-scan-instrs
                    base
                    ty
                    size
                    (box-get rest)
                    ptrs
                    accesses
                    true))])]
          [(IrInstrLoad dst src load-ty)
            (match (opt-aggregate-value-offset base ptrs src)
              [(OptSomeI64 offset)
                (opt-aggregate-scan-instrs
                  base
                  ty
                  size
                  (box-get rest)
                  ptrs
                  (OptAggregateAccessCons
                    (OptAggregateLoad dst offset load-ty)
                    (box accesses))
                  true)]
              [(OptNoI64)
                (if (opt-aggregate-instrs-touch-candidate?
                  (box-get rest)
                  base
                  ptrs)
                  (OptAggregateScanReject)
                  (opt-aggregate-scan-instrs
                    base
                    ty
                    size
                    (box-get rest)
                    ptrs
                    accesses
                    true))])]
          [(IrInstrStorePtr ptr value store-ty)
            (match (opt-aggregate-value-offset base ptrs ptr)
              [(OptSomeI64 offset)
                (if (opt-aggregate-value-has-pointer? base ptrs value)
                  (OptAggregateScanReject)
                  (opt-aggregate-scan-instrs
                    base
                    ty
                    size
                    (box-get rest)
                    ptrs
                    (OptAggregateAccessCons
                      (OptAggregateStore offset store-ty)
                      (box accesses))
                    true))]
              [(OptNoI64)
                (if (or
                  (opt-aggregate-value-has-pointer? base ptrs value)
                  (and
                    (compiler-ir-effect-invalidates-cse?
                      (compiler-ir-instr-effect instr))
                    (opt-aggregate-instrs-touch-candidate?
                      (box-get rest)
                      base
                      ptrs)))
                  (OptAggregateScanReject)
                  (opt-aggregate-scan-instrs
                    base
                    ty
                    size
                    (box-get rest)
                    ptrs
                    accesses
                    true))])]
          [_
            (if (opt-aggregate-instr-has-pointer? instr base ptrs)
              (OptAggregateScanReject)
              (if (and
                (opt-aggregate-instr-crosses-unknown-effect? instr base ptrs)
                (opt-aggregate-instrs-touch-candidate? (box-get rest) base ptrs))
                (OptAggregateScanReject)
                (opt-aggregate-scan-instrs
                  base
                  ty
                  size
                  (box-get rest)
                  ptrs
                  accesses
                  true)))]))]))

(define (opt-aggregate-classify-one
  [base : i64]
  [ty : AstType]
  [size : i64]
  [instrs : CompilerIrInstrList]) : OptAggregateScanResult
  (opt-aggregate-scan-instrs
    base
    ty
    size
    instrs
    (OptAggregatePointerNil)
    (OptAggregateAccessNil)
    false))

(define (opt-aggregate-candidates-from-instrs [scan : CompilerIrInstrList]) : OptAggregateAllocCandidateList
  (match scan
    [(IrInstrNil) (OptAggregateAllocCandidateNil)]
    [(IrInstrCons instr rest)
      (match (opt-aggregate-direct-alloc instr)
        [(OptSomeAggregateAlloc base ty size)
          (match (opt-aggregate-classify-one base ty size scan)
            [(OptAggregateScanOk ptrs accesses)
              (OptAggregateAllocCandidateCons
                (OptAggregateAllocCandidate base ty size ptrs accesses)
                (box (opt-aggregate-candidates-from-instrs (box-get rest))))]
            [(OptAggregateScanReject)
              (opt-aggregate-candidates-from-instrs (box-get rest))])]
        [(OptNoAggregateAlloc)
          (opt-aggregate-candidates-from-instrs (box-get rest))])]))

(define (opt-aggregate-instr-list-append
  [left : CompilerIrInstrList]
  [right : CompilerIrInstrList]) : CompilerIrInstrList
  (match left
    [(IrInstrNil) right]
    [(IrInstrCons head rest)
      (compiler-ir-instr-cons
        head
        (opt-aggregate-instr-list-append (box-get rest) right))]))

(define (opt-aggregate-instr-seq-append-from
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [right : CompilerIrInstrList]) : CompilerIrInstrList
  (if (>= index (compiler-ir-instr-seq-count instrs))
    right
    (compiler-ir-instr-cons
      (compiler-ir-instr-seq-ref instrs index)
      (opt-aggregate-instr-seq-append-from instrs (+ index 1) right))))

(define (opt-aggregate-flatten-blocks [blocks : CompilerIrBlockList]) : CompilerIrInstrList
  (match blocks
    [(IrBlockNil) (IrInstrNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (opt-aggregate-instr-seq-append-from
            instrs
            0
            (opt-aggregate-flatten-blocks (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-aggregate-flatten-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-aggregate-allocation-candidates-function
  [func : CompilerIrFunction]) : OptAggregateAllocCandidateList
  (match func
    [(IrFunction _ _ _ _ blocks)
      (let
        [instrs : CompilerIrInstrList (opt-aggregate-flatten-blocks blocks)]
        (opt-aggregate-candidates-from-instrs instrs))]))

(define (opt-aggregate-candidate-list-append
  [left : OptAggregateAllocCandidateList]
  [right : OptAggregateAllocCandidateList]) : OptAggregateAllocCandidateList
  (match left
    [(OptAggregateAllocCandidateNil) right]
    [(OptAggregateAllocCandidateCons head rest)
      (OptAggregateAllocCandidateCons
        head
        (box (opt-aggregate-candidate-list-append (box-get rest) right)))]))

(define (opt-aggregate-allocation-candidates-functions
  [functions : CompilerIrFunctionList]) : OptAggregateAllocCandidateList
  (match functions
    [(IrFunctionNil) (OptAggregateAllocCandidateNil)]
    [(IrFunctionCons func rest)
      (opt-aggregate-candidate-list-append
        (opt-aggregate-allocation-candidates-function func)
        (opt-aggregate-allocation-candidates-functions (box-get rest)))]))

(define (opt-aggregate-allocation-candidates [program : CompilerIrProgram]) : OptAggregateAllocCandidateList
  (match program
    [(IrProgram _ functions _)
      (opt-aggregate-allocation-candidates-functions functions)]))

(define (opt-aggregate-candidate-list-count
  [candidates : OptAggregateAllocCandidateList]) : i64
  (match candidates
    [(OptAggregateAllocCandidateNil) 0]
    [(OptAggregateAllocCandidateCons _ rest)
      (+ 1 (opt-aggregate-candidate-list-count (box-get rest)))]))

(define (opt-aggregate-pointer-list-count [ptrs : OptAggregatePointerList]) : i64
  (match ptrs
    [(OptAggregatePointerNil) 0]
    [(OptAggregatePointerCons _ rest)
      (+ 1 (opt-aggregate-pointer-list-count (box-get rest)))]))

(define (opt-aggregate-access-list-count [accesses : OptAggregateAccessList]) : i64
  (match accesses
    [(OptAggregateAccessNil) 0]
    [(OptAggregateAccessCons _ rest)
      (+ 1 (opt-aggregate-access-list-count (box-get rest)))]))

(define (opt-aggregate-access-list-load-count
  [accesses : OptAggregateAccessList]) : i64
  (match accesses
    [(OptAggregateAccessNil) 0]
    [(OptAggregateAccessCons access rest)
      (+
        (match access
          [(OptAggregateLoad _ _ _) 1]
          [_ 0])
        (opt-aggregate-access-list-load-count (box-get rest)))]))

(define (opt-aggregate-access-list-store-count
  [accesses : OptAggregateAccessList]) : i64
  (match accesses
    [(OptAggregateAccessNil) 0]
    [(OptAggregateAccessCons access rest)
      (+
        (match access
          [(OptAggregateStore _ _) 1]
          [_ 0])
        (opt-aggregate-access-list-store-count (box-get rest)))]))

;; --- aggregate stack promotion (#1489) --------------------------------------
;;
;; Reuse the non-escaping aggregate classifier, but keep this first promotion
;; slice conservative: only fixed handle-shaped structs/enums/tuples are moved
;; onto local frame storage. Dynamic arrays and array payloads stay heap-backed.
;;
;; The backend frame model exposes 8-byte slots. To preserve positive byte
;; offsets from the aggregate base, the address points at the lowest-addressed
;; reserved slot; offset +8 then walks back toward earlier reserved slots.
(define (opt-aggregate-stack-promote-type? [ty : AstType]) : bool
  (match ty
    [(AstTyStruct _) true]
    [(AstTyStructArgs _ _) true]
    [(AstTyEnum _) true]
    [(AstTyEnumArgs _ _) true]
    [(AstTyTuple _) true]
    [_ false]))

(define (opt-aggregate-stack-slot-count [size : i64]) : i64
  (/ (+ size 7) 8))

(define (opt-aggregate-promote-build
  [candidates : OptAggregateAllocCandidateList]
  [next-frame : i64]) : OptAggregatePromoteBuild
  (match candidates
    [(OptAggregateAllocCandidateNil)
      (OptAggregatePromoteBuild (OptAggregatePromoteSlotNil) next-frame)]
    [(OptAggregateAllocCandidateCons candidate rest)
      (match candidate
        [(OptAggregateAllocCandidate base ty size _ _)
          (if (opt-aggregate-stack-promote-type? ty)
            (let
              [slots : i64 (opt-aggregate-stack-slot-count size)]
              [storage : i64 (+ next-frame (- slots 1))]
              [after-frame : i64 (+ next-frame slots)]
              (match (opt-aggregate-promote-build (box-get rest) after-frame)
                [(OptAggregatePromoteBuild rest-slots final-frame)
                  (OptAggregatePromoteBuild
                    (OptAggregatePromoteSlotCons
                      (OptAggregatePromoteSlot base storage)
                      (box rest-slots))
                    final-frame)]))
            (opt-aggregate-promote-build (box-get rest) next-frame))])]))

(define (opt-aggregate-promote-lookup
  [slots : OptAggregatePromoteSlotList]
  [base : i64]) : OptMaybeI64
  (match slots
    [(OptAggregatePromoteSlotNil) (OptNoI64)]
    [(OptAggregatePromoteSlotCons slot rest)
      (let
        [rest : OptAggregatePromoteSlotList (box-get rest)]
        (match slot
          [(OptAggregatePromoteSlot found storage)
            (if (= found base)
              (OptSomeI64 storage)
              (opt-aggregate-promote-lookup rest base))]))]))

(define (opt-aggregate-promote-rewrite-instr
  [slots : OptAggregatePromoteSlotList]
  [instr : CompilerIrInstr]) : CompilerIrInstrList
  (match (opt-aggregate-direct-alloc instr)
    [(OptSomeAggregateAlloc base ty _)
      (match (opt-aggregate-promote-lookup slots base)
        [(OptSomeI64 storage)
          (compiler-ir-instr-cons
            (IrInstrAlloc storage ty)
            (compiler-ir-instr-cons (IrInstrAddrOf base storage) IrInstrNil))]
        [(OptNoI64) (compiler-ir-instr-cons instr IrInstrNil)])]
    [(OptNoAggregateAlloc) (compiler-ir-instr-cons instr IrInstrNil)]))

(define (opt-aggregate-promote-instrs
  [slots : OptAggregatePromoteSlotList]
  [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (opt-aggregate-instr-list-append
        (opt-aggregate-promote-rewrite-instr slots instr)
        (opt-aggregate-promote-instrs slots (box-get rest)))]))

(define (opt-aggregate-promote-instr-seq-from
  [slots : OptAggregatePromoteSlotList]
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [acc : CompilerIrInstrList]) : CompilerIrInstrList
  (if (< index 0)
    acc
    (opt-aggregate-promote-instr-seq-from
      slots
      instrs
      (- index 1)
      (opt-aggregate-instr-list-append
        (opt-aggregate-promote-rewrite-instr
          slots
          (compiler-ir-instr-seq-ref instrs index))
        acc))))

(define (opt-aggregate-promote-instr-seq
  [slots : OptAggregatePromoteSlotList]
  [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (opt-aggregate-promote-instr-seq-from
    slots
    instrs
    (- (compiler-ir-instr-seq-count instrs) 1)
    IrInstrNil))

(define (opt-aggregate-promote-block
  [slots : OptAggregatePromoteSlotList]
  [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      (compiler-ir-block label (opt-aggregate-promote-instr-seq slots instrs))]))

(define (opt-aggregate-promote-blocks
  [slots : OptAggregatePromoteSlotList]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (compiler-ir-block-cons
        (opt-aggregate-promote-block slots block)
        (opt-aggregate-promote-blocks slots (box-get rest)))]
    [(IrBlockArray seq)
      (opt-aggregate-promote-blocks slots (compiler-ir-block-seq-to-list seq))]))

(define (opt-aggregate-stack-promote-function [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(IrFunction name params ret-ty frame blocks)
      (match (opt-aggregate-promote-build
        (opt-aggregate-allocation-candidates-function func)
        frame)
        [(OptAggregatePromoteBuild slots promoted-frame)
          (IrFunction
            name
            params
            ret-ty
            promoted-frame
            (opt-aggregate-promote-blocks slots blocks))])]))

;; --- aggregate field-load scalar replacement (SROA, #1562) -------------------
;; Replaces loads of fields from non-escaping aggregate allocations with the
;; scalar value last stored to that field. Runs after stack promotion so it
;; handles aggregates that promotion left in memory.
(define (opt-aggregate-scalar-replace-type? [ty : AstType]) : bool
  (if (opt-int-or-char-type? ty)
    true
    (match ty
      [(AstTyBool) true]
      [(AstTyUnit) true]
      [_ false])))

(define (opt-aggregate-candidate-location
  [candidate : OptAggregateAllocCandidate]
  [value : CompilerIrValue]) : OptAggregateLocation
  (match candidate
    [(OptAggregateAllocCandidate base _ _ ptrs _)
      (match (opt-aggregate-value-offset base ptrs value)
        [(OptSomeI64 offset) (OptSomeAggregateLocation base offset)]
        [(OptNoI64) (OptNoAggregateLocation)])]))

(define (opt-aggregate-location-for-value
  [candidates : OptAggregateAllocCandidateList]
  [value : CompilerIrValue]) : OptAggregateLocation
  (match candidates
    [(OptAggregateAllocCandidateNil) (OptNoAggregateLocation)]
    [(OptAggregateAllocCandidateCons candidate rest)
      (match (opt-aggregate-candidate-location candidate value)
        [(OptSomeAggregateLocation base offset)
          (OptSomeAggregateLocation base offset)]
        [(OptNoAggregateLocation)
          (opt-aggregate-location-for-value (box-get rest) value)])]))

(define (opt-aggregate-value-is-candidate-pointer?
  [candidates : OptAggregateAllocCandidateList]
  [value : CompilerIrValue]) : bool
  (match (opt-aggregate-location-for-value candidates value)
    [(OptSomeAggregateLocation _ _) true]
    [(OptNoAggregateLocation) false]))

(define (opt-aggregate-field-facts-unbind
  [facts : OptAggregateFieldFacts]
  [base : i64]
  [offset : i64]) : OptAggregateFieldFacts
  (match facts
    [(OptAggregateFieldNil) (OptAggregateFieldNil)]
    [(OptAggregateFieldCons fact-base fact-offset value ty rest)
      (let
        [rest2 : OptAggregateFieldFacts
          (opt-aggregate-field-facts-unbind (box-get rest) base offset)]
        (if (and (= fact-base base) (= fact-offset offset))
          rest2
          (OptAggregateFieldCons fact-base fact-offset value ty (box rest2))))]))

(define (opt-aggregate-field-facts-unbind-base
  [facts : OptAggregateFieldFacts]
  [base : i64]) : OptAggregateFieldFacts
  (match facts
    [(OptAggregateFieldNil) (OptAggregateFieldNil)]
    [(OptAggregateFieldCons fact-base fact-offset value ty rest)
      (let
        [rest2 : OptAggregateFieldFacts
          (opt-aggregate-field-facts-unbind-base (box-get rest) base)]
        (if (= fact-base base)
          rest2
          (OptAggregateFieldCons fact-base fact-offset value ty (box rest2))))]))

(define (opt-aggregate-field-facts-bind
  [facts : OptAggregateFieldFacts]
  [base : i64]
  [offset : i64]
  [value : CompilerIrValue]
  [ty : AstType]) : OptAggregateFieldFacts
  (OptAggregateFieldCons
    base
    offset
    value
    ty
    (box (opt-aggregate-field-facts-unbind facts base offset))))

(define (opt-aggregate-field-facts-lookup
  [facts : OptAggregateFieldFacts]
  [base : i64]
  [offset : i64]
  [ty : AstType]) : OptAggregateStoredValue
  (match facts
    [(OptAggregateFieldNil) (OptNoAggregateStoredValue)]
    [(OptAggregateFieldCons fact-base fact-offset value fact-ty rest)
      (if (and
        (= fact-base base)
        (and (= fact-offset offset) (opt-type-eq fact-ty ty)))
        (OptSomeAggregateStoredValue value fact-ty)
        (opt-aggregate-field-facts-lookup (box-get rest) base offset ty))]))

(define (opt-aggregate-field-facts-invalidate-var
  [facts : OptAggregateFieldFacts]
  [var : i64]) : OptAggregateFieldFacts
  (match facts
    [(OptAggregateFieldNil) (OptAggregateFieldNil)]
    [(OptAggregateFieldCons base offset value ty rest)
      (let
        [rest2 : OptAggregateFieldFacts
          (opt-aggregate-field-facts-invalidate-var (box-get rest) var)]
        (if (or (= base var) (opt-value-is-var? value var))
          rest2
          (OptAggregateFieldCons base offset value ty (box rest2))))]))

(define (opt-aggregate-sroa-invalidate-def
  [facts : OptAggregateFieldFacts]
  [instr : CompilerIrInstr]) : OptAggregateFieldFacts
  (match instr
    [(IrInstrMov dst _ _) (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrAlloc dst _) (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrAddrOf dst _) (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrGep dst _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrLoad dst _ _) (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrCast dst _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrBinOp dst _ _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrUnOp dst _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrLaneId dst _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrSplat dst _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrVectorBinOp dst _ _ _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrVectorReduce dst _ _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrVectorCompare dst _ _ _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrMaskBinOp dst _ _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrMaskNot dst _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrMaskReduce dst _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrSelect dst _ _ _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrVectorLoad dst _ _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrPredicatedLoad dst _ _ _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrTailMask dst _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrEntryArgc dst)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrEntryArgv dst)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrEntryEnvp dst)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrCpuId dst _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrXgetbv dst _) (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrSyscall dst _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrCall dst _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrCallIndirect dst _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrCallIndirectC dst _ _ _)
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    [(IrInstrPhi dst _ _) (opt-aggregate-field-facts-invalidate-var facts dst)]
    [_ facts]))

(define (opt-aggregate-sroa-store
  [candidates : OptAggregateAllocCandidateList]
  [facts : OptAggregateFieldFacts]
  [ptr : CompilerIrValue]
  [value : CompilerIrValue]
  [ty : AstType]
  [instr : CompilerIrInstr]) : OptAggregateSroaResult
  (match (opt-aggregate-location-for-value candidates ptr)
    [(OptSomeAggregateLocation base offset)
      (if (and
        (opt-aggregate-scalar-replace-type? ty)
        (and
          (opt-copy-safe-source? value)
          (not (opt-aggregate-value-is-candidate-pointer? candidates value))))
        (OptAggregateSroaResult
          (opt-aggregate-field-facts-bind facts base offset value ty)
          instr)
        (OptAggregateSroaResult
          (opt-aggregate-field-facts-unbind-base facts base)
          instr))]
    [(OptNoAggregateLocation)
      (OptAggregateSroaResult (OptAggregateFieldNil) instr)]))

(define (opt-aggregate-sroa-load
  [candidates : OptAggregateAllocCandidateList]
  [facts : OptAggregateFieldFacts]
  [dst : i64]
  [src : CompilerIrValue]
  [ty : AstType]
  [instr : CompilerIrInstr]) : OptAggregateSroaResult
  (let
    [next-facts : OptAggregateFieldFacts
      (opt-aggregate-field-facts-invalidate-var facts dst)]
    (match (opt-aggregate-location-for-value candidates src)
      [(OptSomeAggregateLocation base offset)
        (match (opt-aggregate-field-facts-lookup facts base offset ty)
          [(OptSomeAggregateStoredValue value _)
            (OptAggregateSroaResult next-facts (IrInstrMov dst value ty))]
          [(OptNoAggregateStoredValue)
            (OptAggregateSroaResult next-facts instr)])]
      [(OptNoAggregateLocation) (OptAggregateSroaResult next-facts instr)])))

(define (opt-aggregate-sroa-instr
  [candidates : OptAggregateAllocCandidateList]
  [facts : OptAggregateFieldFacts]
  [instr : CompilerIrInstr]) : OptAggregateSroaResult
  (match instr
    [(IrInstrStorePtr ptr value ty)
      (opt-aggregate-sroa-store candidates facts ptr value ty instr)]
    [(IrInstrLoad dst src ty)
      (opt-aggregate-sroa-load candidates facts dst src ty instr)]
    [_
      (let
        [def-facts : OptAggregateFieldFacts
          (opt-aggregate-sroa-invalidate-def facts instr)]
        (if (compiler-ir-effect-invalidates-cse?
          (compiler-ir-instr-effect instr))
          (OptAggregateSroaResult (OptAggregateFieldNil) instr)
          (OptAggregateSroaResult def-facts instr)))]))

(define (opt-aggregate-sroa-instrs
  [candidates : OptAggregateAllocCandidateList]
  [facts : OptAggregateFieldFacts]
  [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (match (opt-aggregate-sroa-instr candidates facts instr)
        [(OptAggregateSroaResult next-facts next-instr)
          (compiler-ir-instr-cons
            next-instr
            (opt-aggregate-sroa-instrs candidates next-facts (box-get rest)))])]))

(define (opt-aggregate-sroa-instr-seq-from
  [candidates : OptAggregateAllocCandidateList]
  [facts : OptAggregateFieldFacts]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : CompilerIrInstrList
  (if (>= index (compiler-ir-instr-seq-count instrs))
    IrInstrNil
    (match (opt-aggregate-sroa-instr
      candidates
      facts
      (compiler-ir-instr-seq-ref instrs index))
      [(OptAggregateSroaResult next-facts next-instr)
        (compiler-ir-instr-cons
          next-instr
          (opt-aggregate-sroa-instr-seq-from
            candidates
            next-facts
            instrs
            (+ index 1)))])))

(define (opt-aggregate-sroa-instr-seq
  [candidates : OptAggregateAllocCandidateList]
  [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (opt-aggregate-sroa-instr-seq-from candidates (OptAggregateFieldNil) instrs 0))

(define (opt-aggregate-sroa-block
  [candidates : OptAggregateAllocCandidateList]
  [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      (compiler-ir-block label (opt-aggregate-sroa-instr-seq candidates instrs))]))

(define (opt-aggregate-sroa-blocks
  [candidates : OptAggregateAllocCandidateList]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (compiler-ir-block-cons
        (opt-aggregate-sroa-block candidates block)
        (opt-aggregate-sroa-blocks candidates (box-get rest)))]
    [(IrBlockArray seq)
      (opt-aggregate-sroa-blocks candidates (compiler-ir-block-seq-to-list seq))]))

(define (opt-aggregate-sroa-function [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(IrFunction name params ret-ty frame blocks)
      (let
        [candidates : OptAggregateAllocCandidateList
          (opt-aggregate-allocation-candidates-function func)]
        (IrFunction
          name
          params
          ret-ty
          frame
          (opt-aggregate-sroa-blocks candidates blocks)))]))

;; --- block-local common subexpression elimination (#546) --------------------
;;
;; Within a single basic block, track an available-expression table mapping a
;; pure scalar `BinOp`/`UnOp` expression (operator + operand values) to the var
;; that first computed it. A later identical expression is rewritten to an
;; `IrInstrMov` from that earlier var. Scope is intentionally block-local and
;; only covers pure scalar arithmetic; memory ops are not CSE'd.
;;
;; Invalidation keeps this correct even though the IR is not strictly SSA: when
;; an instruction (re)defines a var, every table entry whose key references that
;; var as an operand, or whose result is that var, is dropped. Calls, stores
;; (`Store`/`StorePtr`), and all control-flow boundaries clear the whole table
;; (conservative, matching the spec). Commutative operands are NOT canonicalized
;; in this slice.
(defenum OptExprKey
  (OptBinKey CompilerIrBinOp CompilerIrValue CompilerIrValue)
  (OptUnKey CompilerIrUnOp CompilerIrValue))

(defenum OptExprTable
  (OptExprNil)
  (OptExprCons OptExprKey i64 (Box OptExprTable)))

(define (opt-binop-tag [op : CompilerIrBinOp]) : i64
  (match op
    [(IrBinAdd) 0]
    [(IrBinSub) 1]
    [(IrBinMul) 2]
    [(IrBinDiv) 3]
    [(IrBinMod) 4]
    [(IrBinEq) 5]
    [(IrBinNe) 6]
    [(IrBinLt) 7]
    [(IrBinLe) 8]
    [(IrBinGt) 9]
    [(IrBinGe) 10]
    [(IrBinAnd) 11]
    [(IrBinOr) 12]
    [(IrBinBitAnd) 13]
    [(IrBinBitOr) 14]
    [(IrBinBitXor) 15]
    [(IrBinShl) 16]
    [(IrBinShr) 17]))

(define (opt-binop-eq [a : CompilerIrBinOp] [b : CompilerIrBinOp]) : bool
  (= (opt-binop-tag a) (opt-binop-tag b)))

(define (opt-unop-tag [op : CompilerIrUnOp]) : i64
  (match op
    [(IrUnNeg) 0]
    [(IrUnNot) 1]
    [(IrUnBitNot) 2]))

(define (opt-unop-eq [a : CompilerIrUnOp] [b : CompilerIrUnOp]) : bool
  (= (opt-unop-tag a) (opt-unop-tag b)))

(define (opt-mask-binop-tag [op : CompilerIrMaskBinOp]) : i64
  (match op
    [(IrMaskAnd) 0]
    [(IrMaskOr) 1]))

(define (opt-mask-binop-eq [a : CompilerIrMaskBinOp] [b : CompilerIrMaskBinOp]) : bool
  (= (opt-mask-binop-tag a) (opt-mask-binop-tag b)))

(define (opt-vector-reduce-tag [op : CompilerIrVectorReduceOp]) : i64
  (match op
    [(IrVectorReduceSum) 0]
    [(IrVectorReduceMin) 1]
    [(IrVectorReduceMax) 2]))

(define (opt-vector-reduce-eq
  [a : CompilerIrVectorReduceOp]
  [b : CompilerIrVectorReduceOp]) : bool
  (= (opt-vector-reduce-tag a) (opt-vector-reduce-tag b)))

(define (opt-mask-reduce-tag [op : CompilerIrMaskReduceOp]) : i64
  (match op
    [(IrMaskReduceAll) 0]
    [(IrMaskReduceAny) 1]))

(define (opt-mask-reduce-eq
  [a : CompilerIrMaskReduceOp]
  [b : CompilerIrMaskReduceOp]) : bool
  (= (opt-mask-reduce-tag a) (opt-mask-reduce-tag b)))

(define (opt-value-eq [a : CompilerIrValue] [b : CompilerIrValue]) : bool
  (match a
    [(IrValueVar ia)
      (match b
        [(IrValueVar ib) (= ia ib)]
        [_ false])]
    [(IrValueGlobal ga)
      (match b
        [(IrValueGlobal gb) (string-eq ga gb)]
        [_ false])]
    [(IrValueGlobalAddr ga)
      (match b
        [(IrValueGlobalAddr gb) (string-eq ga gb)]
        [_ false])]
    [(IrValueFunction fa)
      (match b
        [(IrValueFunction fb) (string-eq fa fb)]
        [_ false])]
    [(IrValueI64 na)
      (match b
        [(IrValueI64 nb) (= na nb)]
        [_ false])]
    [(IrValueF64 fa)
      (match b
        [(IrValueF64 fb) (string-eq fa fb)]
        [_ false])]
    [(IrValueBool ba)
      (match b
        [(IrValueBool bb)
          (if ba
            bb
            (not bb))]
        [_ false])]
    [(IrValueChar ca)
      (match b
        [(IrValueChar cb) (= ca cb)]
        [_ false])]
    [(IrValueString sa)
      (match b
        [(IrValueString sb) (string-eq sa sb)]
        [_ false])]
    [(IrValueUnit)
      (match b
        [(IrValueUnit) true]
        [_ false])]))

(define (opt-type-list-eq [a : AstTypeList] [b : AstTypeList]) : bool
  (match a
    [(AstTypeNil)
      (match b
        [(AstTypeNil) true]
        [_ false])]
    [(AstTypeCons ah at)
      (let
        [ah : AstType (ty-node-get ah)]
        [at : AstTypeList (box-get at)]
        (match b
          [(AstTypeCons bh bt)
            (let
              [bh : AstType (ty-node-get bh)]
              [bt : AstTypeList (box-get bt)]
              (and (opt-type-eq ah bh) (opt-type-list-eq at bt)))]
          [_ false]))]))

(define (opt-lifetime-list-eq [a : AstLifetimeList] [b : AstLifetimeList]) : bool
  (match a
    [(AstLifetimeNil)
      (match b
        [(AstLifetimeNil) true]
        [_ false])]
    [(AstLifetimeCons a-head a-rest)
      (let
        [a-rest : AstLifetimeList (box-get a-rest)]
        (match b
          [(AstLifetimeCons b-head b-rest)
            (let
              [b-rest : AstLifetimeList (box-get b-rest)]
              (and
                (string-eq a-head b-head)
                (opt-lifetime-list-eq a-rest b-rest)))]
          [_ false]))]))

(define (opt-type-eq [a : AstType] [b : AstType]) : bool
  (match a
    [(AstTyI64)
      (match b
        [(AstTyI64) true]
        [_ false])]
    [(AstTyI32)
      (match b
        [(AstTyI32) true]
        [_ false])]
    [(AstTyI16)
      (match b
        [(AstTyI16) true]
        [_ false])]
    [(AstTyI8)
      (match b
        [(AstTyI8) true]
        [_ false])]
    [(AstTyU64)
      (match b
        [(AstTyU64) true]
        [_ false])]
    [(AstTyU32)
      (match b
        [(AstTyU32) true]
        [_ false])]
    [(AstTyU16)
      (match b
        [(AstTyU16) true]
        [_ false])]
    [(AstTyU8)
      (match b
        [(AstTyU8) true]
        [_ false])]
    [(AstTyF64)
      (match b
        [(AstTyF64) true]
        [_ false])]
    [(AstTyF32)
      (match b
        [(AstTyF32) true]
        [_ false])]
    [(AstTyBool)
      (match b
        [(AstTyBool) true]
        [_ false])]
    [(AstTyChar)
      (match b
        [(AstTyChar) true]
        [_ false])]
    [(AstTyString)
      (match b
        [(AstTyString) true]
        [_ false])]
    [(AstTyStr)
      (match b
        [(AstTyStr) true]
        [_ false])]
    [(AstTyUnit)
      (match b
        [(AstTyUnit) true]
        [_ false])]
    [(AstTyNever)
      (match b
        [(AstTyNever) true]
        [_ false])]
    [(AstTyExpr)
      (match b
        [(AstTyExpr) true]
        [_ false])]
    [(AstTyExprList)
      (match b
        [(AstTyExprList) true]
        [_ false])]
    [(AstTyFunc a-params a-ret)
      (match b
        [(AstTyFunc b-params b-ret)
          (and
            (opt-type-list-eq a-params b-params)
            (opt-type-eq (ty-node-get a-ret) (ty-node-get b-ret)))]
        [_ false])]
    [(AstTyTuple a-items)
      (match b
        [(AstTyTuple b-items) (opt-type-list-eq a-items b-items)]
        [_ false])]
    [(AstTyArray a-item a-len)
      (match b
        [(AstTyArray b-item b-len)
          (and
            (= a-len b-len)
            (opt-type-eq (ty-node-get a-item) (ty-node-get b-item)))]
        [_ false])]
    [(AstTyDynArray a-item)
      (match b
        [(AstTyDynArray b-item)
          (opt-type-eq (ty-node-get a-item) (ty-node-get b-item))]
        [_ false])]
    [(AstTyBox a-item)
      (match b
        [(AstTyBox b-item)
          (opt-type-eq (ty-node-get a-item) (ty-node-get b-item))]
        [_ false])]
    [(AstTyPtr a-item)
      (match b
        [(AstTyPtr b-item)
          (opt-type-eq (ty-node-get a-item) (ty-node-get b-item))]
        [_ false])]
    [(AstTyMutPtr a-item)
      (match b
        [(AstTyMutPtr b-item)
          (opt-type-eq (ty-node-get a-item) (ty-node-get b-item))]
        [_ false])]
    [(AstTyRef a-region a-inner)
      (match b
        [(AstTyRef b-region b-inner)
          (and
            (string-eq a-region b-region)
            (opt-type-eq (ty-node-get a-inner) (ty-node-get b-inner)))]
        [_ false])]
    [(AstTyMutRef a-region a-inner)
      (match b
        [(AstTyMutRef b-region b-inner)
          (and
            (string-eq a-region b-region)
            (opt-type-eq (ty-node-get a-inner) (ty-node-get b-inner)))]
        [_ false])]
    [(AstTyRegion a-region a-inner)
      (match b
        [(AstTyRegion b-region b-inner)
          (and
            (string-eq a-region b-region)
            (opt-type-eq (ty-node-get a-inner) (ty-node-get b-inner)))]
        [_ false])]
    [(AstTyEnum a-name)
      (match b
        [(AstTyEnum b-name) (= a-name b-name)]
        [_ false])]
    [(AstTyEnumArgs a-name a-lifetimes)
      (match b
        [(AstTyEnumArgs b-name b-lifetimes)
          (and (= a-name b-name) (opt-lifetime-list-eq a-lifetimes b-lifetimes))]
        [_ false])]
    [(AstTyStruct a-name)
      (match b
        [(AstTyStruct b-name) (= a-name b-name)]
        [_ false])]
    [(AstTyStructArgs a-name a-lifetimes)
      (match b
        [(AstTyStructArgs b-name b-lifetimes)
          (and (= a-name b-name) (opt-lifetime-list-eq a-lifetimes b-lifetimes))]
        [_ false])]
    [(AstTyVar a-name)
      (match b
        [(AstTyVar b-name) (= a-name b-name)]
        [_ false])]
    [(AstTyVarArgs a-name a-lifetimes)
      (match b
        [(AstTyVarArgs b-name b-lifetimes)
          (and (= a-name b-name) (opt-lifetime-list-eq a-lifetimes b-lifetimes))]
        [_ false])]))

(define (opt-value-hash [value : CompilerIrValue]) : i64
  (match value
    [(IrValueVar id) (hash-combine 1 (hash-i64 id))]
    [(IrValueGlobal name) (hash-combine 2 (hash-string (& name)))]
    [(IrValueGlobalAddr name) (hash-combine 3 (hash-string (& name)))]
    [(IrValueFunction name) (hash-combine 4 (hash-string (& name)))]
    [(IrValueI64 value) (hash-combine 5 (hash-i64 value))]
    [(IrValueF64 value) (hash-combine 6 (hash-string (& value)))]
    [(IrValueBool value) (hash-combine 7 (hash-bool value))]
    [(IrValueChar value) (hash-combine 8 (hash-char value))]
    [(IrValueString value) (hash-combine 9 (hash-string (& value)))]
    [(IrValueUnit) (hash-i64 10)]))

(define (opt-expr-key-hash [key : OptExprKey]) : i64
  (match key
    [(OptBinKey op lhs rhs)
      (hash-combine
        1
        (hash-combine
          (hash-i64 (opt-binop-tag op))
          (hash-combine (opt-value-hash lhs) (opt-value-hash rhs))))]
    [(OptUnKey op value)
      (hash-combine
        2
        (hash-combine (hash-i64 (opt-unop-tag op)) (opt-value-hash value)))]))

(define (opt-type-list-hash [types : AstTypeList]) : i64
  (match types
    [(AstTypeNil) (hash-i64 0)]
    [(AstTypeCons head rest)
      (hash-combine
        1
        (hash-combine
          (opt-type-hash (ty-node-get head))
          (opt-type-list-hash (box-get rest))))]))

(define (opt-lifetime-list-hash [lifetimes : AstLifetimeList]) : i64
  (match lifetimes
    [(AstLifetimeNil) (hash-i64 0)]
    [(AstLifetimeCons head rest)
      (hash-combine
        1
        (hash-combine
          (hash-string (& head))
          (opt-lifetime-list-hash (box-get rest))))]))

(define (opt-type-hash [ty : AstType]) : i64
  (match ty
    [(AstTyI64) (hash-i64 1)]
    [(AstTyI32) (hash-i64 2)]
    [(AstTyI16) (hash-i64 3)]
    [(AstTyI8) (hash-i64 4)]
    [(AstTyU64) (hash-i64 5)]
    [(AstTyU32) (hash-i64 6)]
    [(AstTyU16) (hash-i64 7)]
    [(AstTyU8) (hash-i64 8)]
    [(AstTyF64) (hash-i64 9)]
    [(AstTyF32) (hash-i64 10)]
    [(AstTyBool) (hash-i64 11)]
    [(AstTyChar) (hash-i64 12)]
    [(AstTyString) (hash-i64 13)]
    [(AstTyStr) (hash-i64 14)]
    [(AstTyUnit) (hash-i64 15)]
    [(AstTyNever) (hash-i64 16)]
    [(AstTyExpr) (hash-i64 17)]
    [(AstTyExprList) (hash-i64 18)]
    [(AstTyFunc params ret)
      (hash-combine
        19
        (hash-combine
          (opt-type-list-hash params)
          (opt-type-hash (ty-node-get ret))))]
    [(AstTyTuple items) (hash-combine 20 (opt-type-list-hash items))]
    [(AstTyArray item len)
      (hash-combine
        21
        (hash-combine (opt-type-hash (ty-node-get item)) (hash-i64 len)))]
    [(AstTyDynArray item) (hash-combine 22 (opt-type-hash (ty-node-get item)))]
    [(AstTyBox item) (hash-combine 23 (opt-type-hash (ty-node-get item)))]
    [(AstTyPtr item) (hash-combine 24 (opt-type-hash (ty-node-get item)))]
    [(AstTyMutPtr item) (hash-combine 25 (opt-type-hash (ty-node-get item)))]
    [(AstTyRef region inner)
      (hash-combine
        26
        (hash-combine
          (hash-string (& region))
          (opt-type-hash (ty-node-get inner))))]
    [(AstTyMutRef region inner)
      (hash-combine
        27
        (hash-combine
          (hash-string (& region))
          (opt-type-hash (ty-node-get inner))))]
    [(AstTyRegion region inner)
      (hash-combine
        28
        (hash-combine
          (hash-string (& region))
          (opt-type-hash (ty-node-get inner))))]
    [(AstTyEnum name) (hash-combine 29 (hash-i64 name))]
    [(AstTyEnumArgs name lifetimes)
      (hash-combine
        30
        (hash-combine (hash-i64 name) (opt-lifetime-list-hash lifetimes)))]
    [(AstTyStruct name) (hash-combine 31 (hash-i64 name))]
    [(AstTyStructArgs name lifetimes)
      (hash-combine
        32
        (hash-combine (hash-i64 name) (opt-lifetime-list-hash lifetimes)))]
    [(AstTyVar name) (hash-combine 33 (hash-i64 name))]
    [(AstTyVarArgs name lifetimes)
      (hash-combine
        34
        (hash-combine (hash-i64 name) (opt-lifetime-list-hash lifetimes)))]))

(define (opt-maybe-value-eq
  [a : CompilerIrMaybeValue]
  [b : CompilerIrMaybeValue]) : bool
  (match a
    [(IrNoValue)
      (match b
        [(IrNoValue) true]
        [_ false])]
    [(IrSomeValue av)
      (match b
        [(IrSomeValue bv) (opt-value-eq av bv)]
        [_ false])]))

(define (opt-value-list-eq [a : CompilerIrValueList] [b : CompilerIrValueList]) : bool
  (match a
    [(IrValueNil)
      (match b
        [(IrValueNil) true]
        [_ false])]
    [(IrValueCons ah at)
      (match b
        [(IrValueCons bh bt)
          (and
            (opt-value-eq ah bh)
            (opt-value-list-eq (box-get at) (box-get bt)))]
        [_ false])]))

(define (opt-call-args-array-eq
  [a : (Array CompilerIrValue)]
  [b : (Array CompilerIrValue)]
  [index : i64]) : bool
  (if (>= index (array-length a))
    true
    (and
      (opt-value-eq (array-ref a index) (array-ref b index))
      (opt-call-args-array-eq a b (+ index 1)))))

(define (opt-call-args-eq [a : CompilerIrCallArgs] [b : CompilerIrCallArgs]) : bool
  (match a
    [(IrCallArgsNil)
      (match b
        [(IrCallArgsNil) true]
        [_ false])]
    [(IrCallArgsOne av)
      (match b
        [(IrCallArgsOne bv) (opt-value-eq av bv)]
        [_ false])]
    [(IrCallArgsTwo aa ab)
      (match b
        [(IrCallArgsTwo ba bb) (and (opt-value-eq aa ba) (opt-value-eq ab bb))]
        [_ false])]
    [(IrCallArgsArray av)
      (match b
        [(IrCallArgsArray bv)
          (and
            (= (array-length av) (array-length bv))
            (opt-call-args-array-eq av bv 0))]
        [_ false])]))

(define (opt-phi-input-eq
  [av : CompilerIrValue]
  [alabel : String]
  [bv : CompilerIrValue]
  [blabel : String]) : bool
  (and (string-eq alabel blabel) (opt-value-eq av bv)))

(define (opt-phi-input-list-eq
  [a : CompilerIrPhiInputList]
  [b : CompilerIrPhiInputList]) : bool
  (match a
    [(IrPhiInputNil)
      (match b
        [(IrPhiInputNil) true]
        [_ false])]
    [(IrPhiInputCons av alabel at)
      (match b
        [(IrPhiInputCons bv blabel bt)
          (and
            (opt-phi-input-eq av alabel bv blabel)
            (opt-phi-input-list-eq (box-get at) (box-get bt)))]
        [_ false])]))

(define (opt-instr-eq [a : CompilerIrInstr] [b : CompilerIrInstr]) : bool
  (match a
    [(IrInstrMov ad av aty)
      (match b
        [(IrInstrMov bd bv bty)
          (and (= ad bd) (and (opt-value-eq av bv) (opt-type-eq aty bty)))]
        [_ false])]
    [(IrInstrAlloc ad aty)
      (match b
        [(IrInstrAlloc bd bty) (and (= ad bd) (opt-type-eq aty bty))]
        [_ false])]
    [(IrInstrAddrOf ad av)
      (match b
        [(IrInstrAddrOf bd bv) (and (= ad bd) (= av bv))]
        [_ false])]
    [(IrInstrGep ad abase aoffset aty)
      (match b
        [(IrInstrGep bd bbase boffset bty)
          (and
            (= ad bd)
            (and
              (opt-value-eq abase bbase)
              (and (opt-value-eq aoffset boffset) (opt-type-eq aty bty))))]
        [_ false])]
    [(IrInstrLoad ad av aty)
      (match b
        [(IrInstrLoad bd bv bty)
          (and (= ad bd) (and (opt-value-eq av bv) (opt-type-eq aty bty)))]
        [_ false])]
    [(IrInstrStorePtr aptr av aty)
      (match b
        [(IrInstrStorePtr bptr bv bty)
          (and
            (opt-value-eq aptr bptr)
            (and (opt-value-eq av bv) (opt-type-eq aty bty)))]
        [_ false])]
    [(IrInstrCopyBytes adst asrc asize)
      (match b
        [(IrInstrCopyBytes bdst bsrc bsize)
          (and
            (= asize bsize)
            (and (opt-value-eq adst bdst) (opt-value-eq asrc bsrc)))]
        [_ false])]
    [(IrInstrCast ad av afrom ato)
      (match b
        [(IrInstrCast bd bv bfrom bto)
          (and
            (= ad bd)
            (and
              (opt-value-eq av bv)
              (and (opt-type-eq afrom bfrom) (opt-type-eq ato bto))))]
        [_ false])]
    [(IrInstrBinOp ad aop al ar aty)
      (match b
        [(IrInstrBinOp bd bop bl br bty)
          (and
            (= ad bd)
            (and
              (opt-binop-eq aop bop)
              (and
                (opt-value-eq al bl)
                (and (opt-value-eq ar br) (opt-type-eq aty bty)))))]
        [_ false])]
    [(IrInstrUnOp ad aop av aty)
      (match b
        [(IrInstrUnOp bd bop bv bty)
          (and
            (= ad bd)
            (and
              (opt-unop-eq aop bop)
              (and (opt-value-eq av bv) (opt-type-eq aty bty))))]
        [_ false])]
    [(IrInstrLaneId ad alanes aty)
      (match b
        [(IrInstrLaneId bd blanes bty)
          (and (= ad bd) (and (= alanes blanes) (opt-type-eq aty bty)))]
        [_ false])]
    [(IrInstrSplat ad av alanes aty)
      (match b
        [(IrInstrSplat bd bv blanes bty)
          (and
            (= ad bd)
            (and
              (opt-value-eq av bv)
              (and (= alanes blanes) (opt-type-eq aty bty))))]
        [_ false])]
    [(IrInstrVectorBinOp ad aop al ar alanes aty)
      (match b
        [(IrInstrVectorBinOp bd bop bl br blanes bty)
          (and
            (= ad bd)
            (and
              (opt-binop-eq aop bop)
              (and
                (opt-value-eq al bl)
                (and
                  (opt-value-eq ar br)
                  (and (= alanes blanes) (opt-type-eq aty bty))))))]
        [_ false])]
    [(IrInstrVectorReduce ad aop av alanes aty)
      (match b
        [(IrInstrVectorReduce bd bop bv blanes bty)
          (and
            (= ad bd)
            (and
              (opt-vector-reduce-eq aop bop)
              (and
                (opt-value-eq av bv)
                (and (= alanes blanes) (opt-type-eq aty bty)))))]
        [_ false])]
    [(IrInstrVectorCompare ad aop al ar alanes aty)
      (match b
        [(IrInstrVectorCompare bd bop bl br blanes bty)
          (and
            (= ad bd)
            (and
              (opt-binop-eq aop bop)
              (and
                (opt-value-eq al bl)
                (and
                  (opt-value-eq ar br)
                  (and (= alanes blanes) (opt-type-eq aty bty))))))]
        [_ false])]
    [(IrInstrMaskBinOp ad aop al ar alanes)
      (match b
        [(IrInstrMaskBinOp bd bop bl br blanes)
          (and
            (= ad bd)
            (and
              (opt-mask-binop-eq aop bop)
              (and
                (opt-value-eq al bl)
                (and (opt-value-eq ar br) (= alanes blanes)))))]
        [_ false])]
    [(IrInstrMaskNot ad av alanes)
      (match b
        [(IrInstrMaskNot bd bv blanes)
          (and (= ad bd) (and (opt-value-eq av bv) (= alanes blanes)))]
        [_ false])]
    [(IrInstrMaskReduce ad aop av alanes)
      (match b
        [(IrInstrMaskReduce bd bop bv blanes)
          (and
            (= ad bd)
            (and
              (opt-mask-reduce-eq aop bop)
              (and (opt-value-eq av bv) (= alanes blanes))))]
        [_ false])]
    [(IrInstrSelect ad amask at af alanes aty)
      (match b
        [(IrInstrSelect bd bmask bt bf blanes bty)
          (and
            (= ad bd)
            (and
              (opt-value-eq amask bmask)
              (and
                (opt-value-eq at bt)
                (and
                  (opt-value-eq af bf)
                  (and (= alanes blanes) (opt-type-eq aty bty))))))]
        [_ false])]
    [(IrInstrVectorLoad ad abase aindex alanes aty)
      (match b
        [(IrInstrVectorLoad bd bbase bindex blanes bty)
          (and
            (= ad bd)
            (and
              (opt-value-eq abase bbase)
              (and
                (opt-value-eq aindex bindex)
                (and (= alanes blanes) (opt-type-eq aty bty)))))]
        [_ false])]
    [(IrInstrVectorStore abase aindex av alanes aty)
      (match b
        [(IrInstrVectorStore bbase bindex bv blanes bty)
          (and
            (opt-value-eq abase bbase)
            (and
              (opt-value-eq aindex bindex)
              (and
                (opt-value-eq av bv)
                (and (= alanes blanes) (opt-type-eq aty bty)))))]
        [_ false])]
    [(IrInstrPredicatedStore abase aindex av amask alanes aty)
      (match b
        [(IrInstrPredicatedStore bbase bindex bv bmask blanes bty)
          (and
            (opt-value-eq abase bbase)
            (and
              (opt-value-eq aindex bindex)
              (and
                (opt-value-eq av bv)
                (and
                  (opt-value-eq amask bmask)
                  (and (= alanes blanes) (opt-type-eq aty bty))))))]
        [_ false])]
    [(IrInstrPredicatedLoad ad abase aindex amask alanes aty)
      (match b
        [(IrInstrPredicatedLoad bd bbase bindex bmask blanes bty)
          (and
            (= ad bd)
            (and
              (opt-value-eq abase bbase)
              (and
                (opt-value-eq aindex bindex)
                (and
                  (opt-value-eq amask bmask)
                  (and (= alanes blanes) (opt-type-eq aty bty))))))]
        [_ false])]
    [(IrInstrTailMask ad aindex alength alanes)
      (match b
        [(IrInstrTailMask bd bindex blength blanes)
          (and
            (= ad bd)
            (and
              (opt-value-eq aindex bindex)
              (and (opt-value-eq alength blength) (= alanes blanes))))]
        [_ false])]
    [(IrInstrEntryArgc ad)
      (match b
        [(IrInstrEntryArgc bd) (= ad bd)]
        [_ false])]
    [(IrInstrEntryArgv ad)
      (match b
        [(IrInstrEntryArgv bd) (= ad bd)]
        [_ false])]
    [(IrInstrEntryEnvp ad)
      (match b
        [(IrInstrEntryEnvp bd) (= ad bd)]
        [_ false])]
    [(IrInstrCpuId ad aleaf asubleaf areg)
      (match b
        [(IrInstrCpuId bd bleaf bsubleaf breg)
          (and
            (= ad bd)
            (and
              (opt-value-eq aleaf bleaf)
              (and (opt-value-eq asubleaf bsubleaf) (= areg breg))))]
        [_ false])]
    [(IrInstrXgetbv ad aindex)
      (match b
        [(IrInstrXgetbv bd bindex) (and (= ad bd) (opt-value-eq aindex bindex))]
        [_ false])]
    [(IrInstrSyscall ad aargs)
      (match b
        [(IrInstrSyscall bd bargs)
          (and (= ad bd) (opt-call-args-eq aargs bargs))]
        [_ false])]
    [(IrInstrCall ad aname aargs aty)
      (match b
        [(IrInstrCall bd bname bargs bty)
          (and
            (= ad bd)
            (and
              (string-eq aname bname)
              (and (opt-call-args-eq aargs bargs) (opt-type-eq aty bty))))]
        [_ false])]
    [(IrInstrCallIndirect ad afunc aargs aty)
      (match b
        [(IrInstrCallIndirect bd bfunc bargs bty)
          (and
            (= ad bd)
            (and
              (opt-value-eq afunc bfunc)
              (and (opt-call-args-eq aargs bargs) (opt-type-eq aty bty))))]
        [_ false])]
    [(IrInstrCallIndirectC ad afunc aargs aty)
      (match b
        [(IrInstrCallIndirectC bd bfunc bargs bty)
          (and
            (= ad bd)
            (and
              (opt-value-eq afunc bfunc)
              (and (opt-call-args-eq aargs bargs) (opt-type-eq aty bty))))]
        [_ false])]
    [(IrInstrTailCall aname aargs aty)
      (match b
        [(IrInstrTailCall bname bargs bty)
          (and
            (string-eq aname bname)
            (and (opt-call-args-eq aargs bargs) (opt-type-eq aty bty)))]
        [_ false])]
    [(IrInstrStore aname av aty)
      (match b
        [(IrInstrStore bname bv bty)
          (and
            (string-eq aname bname)
            (and (opt-value-eq av bv) (opt-type-eq aty bty)))]
        [_ false])]
    [(IrInstrBoundsCheck aindex alength alabel)
      (match b
        [(IrInstrBoundsCheck bindex blength blabel)
          (and
            (opt-value-eq aindex bindex)
            (and (opt-value-eq alength blength) (string-eq alabel blabel)))]
        [_ false])]
    [(IrInstrJump alabel)
      (match b
        [(IrInstrJump blabel) (string-eq alabel blabel)]
        [_ false])]
    [(IrInstrBranch av at bt)
      (match b
        [(IrInstrBranch bv af bf)
          (and (string-eq at af) (and (string-eq bt bf) (opt-value-eq av bv)))]
        [_ false])]
    [(IrInstrReturn av)
      (match b
        [(IrInstrReturn bv) (opt-maybe-value-eq av bv)]
        [_ false])]
    [(IrInstrPhi ad ainputs aty)
      (match b
        [(IrInstrPhi bd binputs bty)
          (and
            (= ad bd)
            (and (opt-phi-input-list-eq ainputs binputs) (opt-type-eq aty bty)))]
        [_ false])]
    [(IrInstrPack ad awords aty)
      (match b
        [(IrInstrPack bd bwords bty)
          (and
            (= ad bd)
            (and (opt-value-list-eq awords bwords) (opt-type-eq aty bty)))]
        [_ false])]
    [(IrInstrWord ad asrc ai aty)
      (match b
        [(IrInstrWord bd bsrc bi bty)
          (and
            (= ad bd)
            (and
              (opt-value-eq asrc bsrc)
              (and (= ai bi) (opt-type-eq aty bty))))]
        [_ false])]))

(define (opt-instr-list-eq [a : CompilerIrInstrList] [b : CompilerIrInstrList]) : bool
  (match a
    [(IrInstrNil)
      (match b
        [(IrInstrNil) true]
        [_ false])]
    [(IrInstrCons ah at)
      (match b
        [(IrInstrCons bh bt)
          (and
            (opt-instr-eq ah bh)
            (opt-instr-list-eq (box-get at) (box-get bt)))]
        [_ false])]))

(define (opt-block-eq [a : CompilerIrBlock] [b : CompilerIrBlock]) : bool
  (match a
    [(IrBlock alabel ainstrs)
      (match b
        [(IrBlock blabel binstrs)
          (and
            (string-eq alabel blabel)
            (opt-instr-list-eq
              (compiler-ir-instr-seq-to-list ainstrs)
              (compiler-ir-instr-seq-to-list binstrs)))])]))

(define (opt-block-list-eq [a : CompilerIrBlockList] [b : CompilerIrBlockList]) : bool
  (match a
    [(IrBlockNil)
      (match b
        [(IrBlockNil) true]
        [_ false])]
    [(IrBlockCons ah at)
      (match b
        [(IrBlockCons bh bt)
          (and
            (opt-block-eq ah bh)
            (opt-block-list-eq (box-get at) (box-get bt)))]
        [(IrBlockArray seq)
          (opt-block-list-eq a (compiler-ir-block-seq-to-list seq))]
        [_ false])]
    [(IrBlockArray seq)
      (opt-block-list-eq (compiler-ir-block-seq-to-list seq) b)]))

(define (opt-param-eq [a : CompilerIrParam] [b : CompilerIrParam]) : bool
  (match a
    [(IrParam aname aty aid)
      (match b
        [(IrParam bname bty bid)
          (and (string-eq aname bname) (and (= aid bid) (opt-type-eq aty bty)))])]))

(define (opt-param-list-eq [a : CompilerIrParamList] [b : CompilerIrParamList]) : bool
  (match a
    [(IrParamNil)
      (match b
        [(IrParamNil) true]
        [_ false])]
    [(IrParamCons ah at)
      (match b
        [(IrParamCons bh bt)
          (and
            (opt-param-eq ah bh)
            (opt-param-list-eq (box-get at) (box-get bt)))]
        [_ false])]))

(define (opt-function-eq [a : CompilerIrFunction] [b : CompilerIrFunction]) : bool
  (match a
    [(IrFunction aname aparams aret aframe ablocks)
      (match b
        [(IrFunction bname bparams bret bframe bblocks)
          (and
            (string-eq aname bname)
            (and
              (= aframe bframe)
              (and
                (opt-param-list-eq aparams bparams)
                (and
                  (opt-type-eq aret bret)
                  (opt-block-list-eq ablocks bblocks)))))])]))

(define (opt-function-list-eq
  [a : CompilerIrFunctionList]
  [b : CompilerIrFunctionList]) : bool
  (match a
    [(IrFunctionNil)
      (match b
        [(IrFunctionNil) true]
        [_ false])]
    [(IrFunctionCons ah at)
      (match b
        [(IrFunctionCons bh bt)
          (and
            (opt-function-eq ah bh)
            (opt-function-list-eq (box-get at) (box-get bt)))]
        [_ false])]))

(define (opt-global-eq [a : CompilerIrGlobal] [b : CompilerIrGlobal]) : bool
  (match a
    [(IrGlobal aname aty avalue)
      (match b
        [(IrGlobal bname bty bvalue)
          (and
            (string-eq aname bname)
            (and (opt-type-eq aty bty) (opt-value-eq avalue bvalue)))])]))

(define (opt-global-list-eq
  [a : CompilerIrGlobalList]
  [b : CompilerIrGlobalList]) : bool
  (match a
    [(IrGlobalNil)
      (match b
        [(IrGlobalNil) true]
        [_ false])]
    [(IrGlobalCons ah at)
      (match b
        [(IrGlobalCons bh bt)
          (and
            (opt-global-eq ah bh)
            (opt-global-list-eq (box-get at) (box-get bt)))]
        [_ false])]))

(define (opt-extern-eq [a : CompilerIrExtern] [b : CompilerIrExtern]) : bool
  (match a
    [(IrExtern aname aty aabi asymbol alinks aprovided)
      (match b
        [(IrExtern bname bty babi bsymbol blinks bprovided)
          (and
            (string-eq aname bname)
            (and
              (opt-type-eq aty bty)
              (and
                (ast-extern-abi-eq? aabi babi)
                (and
                  (string-eq asymbol bsymbol)
                  (and
                    (ast-extern-link-input-list-eq? alinks blinks)
                    (= aprovided bprovided))))))])]))

(define (opt-extern-list-eq
  [a : CompilerIrExternList]
  [b : CompilerIrExternList]) : bool
  (match a
    [(IrExternNil)
      (match b
        [(IrExternNil) true]
        [_ false])]
    [(IrExternCons ah at)
      (match b
        [(IrExternCons bh bt)
          (and
            (opt-extern-eq ah bh)
            (opt-extern-list-eq (box-get at) (box-get bt)))]
        [_ false])]))

(define (opt-program-eq [a : CompilerIrProgram] [b : CompilerIrProgram]) : bool
  (match a
    [(IrProgram aglobals afunctions aexterns)
      (match b
        [(IrProgram bglobals bfunctions bexterns)
          (and
            (opt-global-list-eq aglobals bglobals)
            (and
              (opt-function-list-eq afunctions bfunctions)
              (opt-extern-list-eq aexterns bexterns)))])]))

(define (opt-expr-key-eq [a : OptExprKey] [b : OptExprKey]) : bool
  (match a
    [(OptBinKey opa la ra)
      (match b
        [(OptBinKey opb lb rb)
          (and
            (opt-binop-eq opa opb)
            (and (opt-value-eq la lb) (opt-value-eq ra rb)))]
        [(OptUnKey _ _) false])]
    [(OptUnKey opa va)
      (match b
        [(OptUnKey opb vb) (and (opt-unop-eq opa opb) (opt-value-eq va vb))]
        [(OptBinKey _ _ _) false])]))

(define (opt-expr-lookup [table : OptExprTable] [key : OptExprKey]) : CompilerIrMaybeValue
  (match table
    [(OptExprNil) (IrNoValue)]
    [(OptExprCons k var rest)
      (let
        [rest : OptExprTable (box-get rest)]
        (if (opt-expr-key-eq k key)
          (IrSomeValue (IrValueVar var))
          (opt-expr-lookup rest key)))]))

(define (opt-value-is-var? [value : CompilerIrValue] [var : i64]) : bool
  (match value
    [(IrValueVar id) (= id var)]
    [_ false]))

(define (opt-key-uses-var? [key : OptExprKey] [var : i64]) : bool
  (match key
    [(OptBinKey _ l r) (or (opt-value-is-var? l var) (opt-value-is-var? r var))]
    [(OptUnKey _ v) (opt-value-is-var? v var)]))

;; Drop every entry whose key references `var` (a stale operand) or whose result
;; is `var` (a stale definition).
(define (opt-expr-invalidate-var [table : OptExprTable] [var : i64]) : OptExprTable
  (match table
    [(OptExprNil) (OptExprNil)]
    [(OptExprCons k v rest)
      (let
        [rest2 : OptExprTable (opt-expr-invalidate-var (box-get rest) var)]
        (if (or (opt-key-uses-var? k var) (= v var))
          rest2
          (OptExprCons k v (box rest2))))]))

(defenum OptCseResult
  (OptCseResult OptExprTable CompilerIrInstr))

(define (opt-cse-instr [table : OptExprTable] [instr : CompilerIrInstr]) : OptCseResult
  (match instr
    [(IrInstrBinOp dst op l r ty)
      (let
        [t1 : OptExprTable (opt-expr-invalidate-var table dst)]
        [key : OptExprKey (OptBinKey op l r)]
        (match (opt-expr-lookup t1 key)
          [(IrSomeValue earlier) (OptCseResult t1 (IrInstrMov dst earlier ty))]
          [(IrNoValue) (OptCseResult (OptExprCons key dst (box t1)) instr)]))]
    [(IrInstrUnOp dst op v ty)
      (let
        [t1 : OptExprTable (opt-expr-invalidate-var table dst)]
        [key : OptExprKey (OptUnKey op v)]
        (match (opt-expr-lookup t1 key)
          [(IrSomeValue earlier) (OptCseResult t1 (IrInstrMov dst earlier ty))]
          [(IrNoValue) (OptCseResult (OptExprCons key dst (box t1)) instr)]))]
    ;; Other defining instructions: invalidate their dst, keep the instruction.
    [(IrInstrMov dst _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrAlloc dst _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrAddrOf dst _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrGep dst _ _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrLoad dst _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrCast dst _ _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrPhi dst _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrLaneId dst _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrSplat dst _ _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrVectorBinOp dst _ _ _ _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrVectorReduce dst _ _ _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrVectorCompare dst _ _ _ _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrMaskBinOp dst _ _ _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrMaskNot dst _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrMaskReduce dst _ _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrSelect dst _ _ _ _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrVectorLoad dst _ _ _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrPredicatedLoad dst _ _ _ _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrTailMask dst _ _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrEntryArgc dst)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrEntryArgv dst)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrEntryEnvp dst)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrCpuId dst _ _ _)
      (OptCseResult (opt-expr-invalidate-var (OptExprNil) dst) instr)]
    [(IrInstrXgetbv dst _)
      (OptCseResult (opt-expr-invalidate-var (OptExprNil) dst) instr)]
    ;; Calls, stores, and control flow clear all available expressions.
    [(IrInstrSyscall _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrCall _ _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrCallIndirect _ _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrCallIndirectC _ _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrTailCall _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrStore _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrStorePtr _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrCopyBytes _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrVectorStore _ _ _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrPredicatedStore _ _ _ _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrBoundsCheck _ _ _) (OptCseResult table instr)]
    [(IrInstrJump _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrBranch _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrReturn _) (OptCseResult (OptExprNil) instr)]
    ;; #2386: register-group ops are plain defining instructions -- invalidate
    ;; their dst, keep the instruction (no CSE key for them yet).
    [(IrInstrPack dst _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]
    [(IrInstrWord dst _ _ _)
      (OptCseResult (opt-expr-invalidate-var table dst) instr)]))

(define (opt-cse-instrs [table : OptExprTable] [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (match (opt-cse-instr table instr)
        [(OptCseResult new-table new-instr)
          (compiler-ir-instr-cons
            new-instr
            (opt-cse-instrs new-table (box-get rest)))])]))

;; --- block-local copy propagation (#545) ------------------------------------
;;
;; The lowerer and the CSE pass both materialize values through `IrInstrMov`
;; into fresh vars (CSE rewrites a redundant expression to `Mov dst earlier`).
;; Within a single basic block, track copies `dst -> source` and rewrite later
;; operand uses of `IrValueVar dst` to `source`, so DCE can then drop the now
;; unused copy. This needs no register allocation or CFG dataflow.
;;
;; Conservative for the first slice: only `IrValueVar` and unambiguous scalar
;; literals are recorded as copy sources (`IrValueF64`, `IrValueString`, and
;; globals are excluded until their backend paths are settled); `IrInstrPhi`
;; inputs belong to predecessor edges and are never rewritten; and `IrInstrAddrOf`
;; carries a raw var id (a storage slot), not a value operand, so it is left
;; alone. On any instruction that defines var `v`, both the mapping for `v` and
;; any mapping whose source is `IrValueVar v` are dropped, so a reused var id in
;; the non-SSA IR never triggers a stale rewrite.
(defenum OptCopyEnv
  (OptCopyNil)
  (OptCopyCons i64 CompilerIrValue (Box OptCopyEnv)))

(define (opt-copy-lookup [env : OptCopyEnv] [var : i64]) : CompilerIrMaybeValue
  (match env
    [(OptCopyNil) (IrNoValue)]
    [(OptCopyCons id value rest)
      (let
        [rest : OptCopyEnv (box-get rest)]
        (if (= id var)
          (IrSomeValue value)
          (opt-copy-lookup rest var)))]))

;; Drop the mapping for `var` and any mapping whose replacement is `IrValueVar
;; var`, so redefining either a copied destination or a copied source clears the
;; stale copy fact.
(define (opt-copy-invalidate-var [env : OptCopyEnv] [var : i64]) : OptCopyEnv
  (match env
    [(OptCopyNil) (OptCopyNil)]
    [(OptCopyCons id value rest)
      (let
        [rest2 : OptCopyEnv (opt-copy-invalidate-var (box-get rest) var)]
        (if (or (= id var) (opt-value-is-var? value var))
          rest2
          (OptCopyCons id value (box rest2))))]))

;; Only var copies and unambiguous scalar literals are safe to propagate in this
;; slice; F64/String/global sources stay put until their backend paths exist.
(define (opt-copy-safe-source? [value : CompilerIrValue]) : bool
  (match value
    [(IrValueVar _) true]
    [(IrValueI64 _) true]
    [(IrValueBool _) true]
    [(IrValueChar _) true]
    [(IrValueUnit) true]
    [(IrValueF64 _) false]
    [(IrValueString _) false]
    [(IrValueGlobal _) false]
    [(IrValueGlobalAddr _) false]
    [(IrValueFunction _) false]))

(define (opt-copy-resolve [env : OptCopyEnv] [value : CompilerIrValue]) : CompilerIrValue
  (match value
    [(IrValueVar id)
      (match (opt-copy-lookup env id)
        [(IrSomeValue v) v]
        [(IrNoValue) value])]
    [_ value]))

(define (opt-copy-subst-value-list
  [env : OptCopyEnv]
  [values : CompilerIrValueList]) : CompilerIrValueList
  (match values
    [(IrValueNil) (IrValueNil)]
    [(IrValueCons value rest)
      (compiler-ir-value-cons
        (opt-copy-resolve env value)
        (opt-copy-subst-value-list env (box-get rest)))]))

(define (opt-copy-subst-call-args-array
  [env : OptCopyEnv]
  [src : (Array CompilerIrValue)]
  [dst : (Array CompilerIrValue)]
  [index : i64]) : unit
  (if (>= index (array-length src))
    unit
    (begin
      (array-set! dst index (opt-copy-resolve env (array-ref src index)))
      (opt-copy-subst-call-args-array env src dst (+ index 1)))))

(define (opt-copy-subst-call-args
  [env : OptCopyEnv]
  [args : CompilerIrCallArgs]) : CompilerIrCallArgs
  (match args
    [(IrCallArgsNil) (IrCallArgsNil)]
    [(IrCallArgsOne value) (IrCallArgsOne (opt-copy-resolve env value))]
    [(IrCallArgsTwo a b)
      (IrCallArgsTwo (opt-copy-resolve env a) (opt-copy-resolve env b))]
    [(IrCallArgsArray values)
      (let
        [out : (Array CompilerIrValue)
          (make-array CompilerIrValue (array-length values))]
        (begin
          (opt-copy-subst-call-args-array env values out 0)
          (IrCallArgsArray out)))]))

;; Rewrite the value-use operands of an instruction through the copy env. Phi
;; inputs and the raw var id of `IrInstrAddrOf` are intentionally not rewritten.
(define (opt-copy-subst-instr [env : OptCopyEnv] [instr : CompilerIrInstr]) : CompilerIrInstr
  (match instr
    [(IrInstrMov dst src ty) (IrInstrMov dst (opt-copy-resolve env src) ty)]
    [(IrInstrGep dst base offset ty)
      (IrInstrGep
        dst
        (opt-copy-resolve env base)
        (opt-copy-resolve env offset)
        ty)]
    [(IrInstrLoad dst src ty) (IrInstrLoad dst (opt-copy-resolve env src) ty)]
    [(IrInstrStorePtr ptr value ty)
      (IrInstrStorePtr
        (opt-copy-resolve env ptr)
        (opt-copy-resolve env value)
        ty)]
    [(IrInstrCopyBytes dst src size)
      (IrInstrCopyBytes
        (opt-copy-resolve env dst)
        (opt-copy-resolve env src)
        size)]
    [(IrInstrCast dst src from-ty to-ty)
      (IrInstrCast dst (opt-copy-resolve env src) from-ty to-ty)]
    [(IrInstrBinOp dst op l r ty)
      (IrInstrBinOp dst op (opt-copy-resolve env l) (opt-copy-resolve env r) ty)]
    [(IrInstrUnOp dst op v ty) (IrInstrUnOp dst op (opt-copy-resolve env v) ty)]
    [(IrInstrSplat dst value lanes ty)
      (IrInstrSplat dst (opt-copy-resolve env value) lanes ty)]
    ;; Vector/mask IR uses private aggregate values that the scalar copy pass
    ;; cannot type-check yet, so leave those operands untouched until a
    ;; vector-aware propagation pass exists.
    [(IrInstrVectorBinOp _ _ _ _ _ _) instr]
    [(IrInstrVectorReduce _ _ _ _ _) instr]
    [(IrInstrVectorCompare _ _ _ _ _ _) instr]
    [(IrInstrMaskBinOp _ _ _ _ _) instr]
    [(IrInstrMaskNot _ _ _) instr]
    [(IrInstrMaskReduce _ _ _ _) instr]
    [(IrInstrSelect _ _ _ _ _ _) instr]
    [(IrInstrVectorLoad _ _ _ _ _) instr]
    [(IrInstrVectorStore _ _ _ _ _) instr]
    [(IrInstrPredicatedStore _ _ _ _ _ _) instr]
    [(IrInstrPredicatedLoad _ _ _ _ _ _) instr]
    [(IrInstrTailMask _ _ _ _) instr]
    [(IrInstrEntryArgc _) instr]
    [(IrInstrEntryArgv _) instr]
    [(IrInstrEntryEnvp _) instr]
    [(IrInstrCpuId dst leaf subleaf reg-index)
      (IrInstrCpuId
        dst
        (opt-copy-resolve env leaf)
        (opt-copy-resolve env subleaf)
        reg-index)]
    [(IrInstrXgetbv dst index) (IrInstrXgetbv dst (opt-copy-resolve env index))]
    [(IrInstrSyscall dst args)
      (IrInstrSyscall dst (opt-copy-subst-call-args env args))]
    [(IrInstrCall dst name args ty)
      (IrInstrCall dst name (opt-copy-subst-call-args env args) ty)]
    [(IrInstrCallIndirect dst func args ty)
      (IrInstrCallIndirect
        dst
        (opt-copy-resolve env func)
        (opt-copy-subst-call-args env args)
        ty)]
    [(IrInstrCallIndirectC dst func args ty)
      (IrInstrCallIndirectC
        dst
        (opt-copy-resolve env func)
        (opt-copy-subst-call-args env args)
        ty)]
    [(IrInstrTailCall name args ty)
      (IrInstrTailCall name (opt-copy-subst-call-args env args) ty)]
    [(IrInstrStore name value ty)
      (IrInstrStore name (opt-copy-resolve env value) ty)]
    [(IrInstrBoundsCheck index length ok-label)
      (IrInstrBoundsCheck
        (opt-copy-resolve env index)
        (opt-copy-resolve env length)
        ok-label)]
    [(IrInstrBranch cond a b) (IrInstrBranch (opt-copy-resolve env cond) a b)]
    [(IrInstrReturn maybe)
      (match maybe
        [(IrSomeValue value)
          (IrInstrReturn (IrSomeValue (opt-copy-resolve env value)))]
        [(IrNoValue) instr])]
    ;; `IrInstrAddrOf` takes the address of a storage slot named by a raw var id,
    ;; not a value, so its operand must not be copy-substituted (#545).
    [(IrInstrAddrOf _ _) instr]
    ;; `IrInstrAlloc`/`IrInstrJump` have no value operands; `IrInstrPhi` inputs
    ;; belong to predecessor edges and are not block-local copies.
    [(IrInstrAlloc _ _) instr]
    [(IrInstrLaneId _ _ _) instr]
    [(IrInstrJump _) instr]
    [(IrInstrPhi _ _ _) instr]
    ;; #2386: register-group ops carry value operands -- substitute copies into
    ;; the packed words / the extracted source group.
    [(IrInstrPack dst words ty)
      (IrInstrPack dst (opt-copy-subst-value-list env words) ty)]
    [(IrInstrWord dst src index ty)
      (IrInstrWord dst (opt-copy-resolve env src) index ty)]))

;; Update the copy env after an instruction. A `Mov dst src` (with `src` already
;; substituted) records a copy when `src` is a safe, non-self source. Every other
;; defining instruction invalidates its destination. Stores and terminators
;; define no var, so the copy facts are unaffected (the env resets per block).
(define (opt-copy-update-env [env : OptCopyEnv] [instr : CompilerIrInstr]) : OptCopyEnv
  (match instr
    [(IrInstrMov dst src ty)
      (let
        [e1 : OptCopyEnv (opt-copy-invalidate-var env dst)]
        (if (and (opt-copy-safe-source? src) (not (opt-value-is-var? src dst)))
          (OptCopyCons dst src (box e1))
          e1))]
    [(IrInstrAlloc dst _) (opt-copy-invalidate-var env dst)]
    [(IrInstrAddrOf dst _) (opt-copy-invalidate-var env dst)]
    [(IrInstrGep dst _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrLoad dst _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrCast dst _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrBinOp dst _ _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrUnOp dst _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrLaneId dst _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrSplat dst _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrVectorBinOp dst _ _ _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrVectorReduce dst _ _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrVectorCompare dst _ _ _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrMaskBinOp dst _ _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrMaskNot dst _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrMaskReduce dst _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrSelect dst _ _ _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrVectorLoad dst _ _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrPredicatedLoad dst _ _ _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrTailMask dst _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrEntryArgc dst) (opt-copy-invalidate-var env dst)]
    [(IrInstrEntryArgv dst) (opt-copy-invalidate-var env dst)]
    [(IrInstrEntryEnvp dst) (opt-copy-invalidate-var env dst)]
    [(IrInstrCpuId dst _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrXgetbv dst _) (opt-copy-invalidate-var env dst)]
    [(IrInstrSyscall dst _) (opt-copy-invalidate-var env dst)]
    [(IrInstrCall dst _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrCallIndirect dst _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrCallIndirectC dst _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrPhi dst _ _) (opt-copy-invalidate-var env dst)]
    ;; #2386: register-group ops define their dst -- drop any stale copy fact for
    ;; it (a reused var id must not trigger a later stale rewrite).
    [(IrInstrPack dst _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrWord dst _ _ _) (opt-copy-invalidate-var env dst)]
    [_ env]))

(defenum OptCopyResult
  (OptCopyResult OptCopyEnv CompilerIrInstr))

(define (opt-copy-instr [env : OptCopyEnv] [instr : CompilerIrInstr]) : OptCopyResult
  (let
    [rewritten : CompilerIrInstr (opt-copy-subst-instr env instr)]
    (OptCopyResult (opt-copy-update-env env rewritten) rewritten)))

(define (opt-copy-instrs [env : OptCopyEnv] [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (match (opt-copy-instr env instr)
        [(OptCopyResult new-env new-instr)
          (compiler-ir-instr-cons
            new-instr
            (opt-copy-instrs new-env (box-get rest)))])]))

(define (opt-copy-instr-seq-from
  [env : OptCopyEnv]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : CompilerIrInstrList
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (IrInstrNil)
    (match (opt-copy-instr env (compiler-ir-instr-seq-ref instrs index))
      [(OptCopyResult new-env new-instr)
        (compiler-ir-instr-cons
          new-instr
          (opt-copy-instr-seq-from new-env instrs (+ index 1)))])))

(define (opt-copy-instr-seq [env : OptCopyEnv] [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (opt-copy-instr-seq-from env instrs 0))

;; --- block-local redundant bounds-check elimination (#930) ------------------
;;
;; `IrInstrBoundsCheck index length ok-label` is a trapping side-effect: it must be kept
;; unless the same `(index, length)` pair has already been checked on every
;; preceding path within the same basic block. This pass is deliberately local.
;; It records successful checks after copy propagation has resolved operands,
;; invalidates facts when either operand var is redefined, and clears all facts
;; across calls, stores, control-flow boundaries, and phi boundaries.
(defenum OptBoundsFact
  (OptBoundsFact CompilerIrValue CompilerIrValue))

(defenum OptBoundsFacts
  (OptBoundsNil)
  (OptBoundsCons OptBoundsFact (Box OptBoundsFacts)))

(define (opt-bounds-fact-eq
  [fact : OptBoundsFact]
  [index : CompilerIrValue]
  [length : CompilerIrValue]) : bool
  (match fact
    [(OptBoundsFact fact-index fact-length)
      (and (opt-value-eq fact-index index) (opt-value-eq fact-length length))]))

(define (opt-bounds-contains
  [facts : OptBoundsFacts]
  [index : CompilerIrValue]
  [length : CompilerIrValue]) : bool
  (match facts
    [(OptBoundsNil) false]
    [(OptBoundsCons fact rest)
      (let
        [rest : OptBoundsFacts (box-get rest)]
        (if (opt-bounds-fact-eq fact index length)
          true
          (opt-bounds-contains rest index length)))]))

(define (opt-bounds-add
  [facts : OptBoundsFacts]
  [index : CompilerIrValue]
  [length : CompilerIrValue]) : OptBoundsFacts
  (if (opt-bounds-contains facts index length)
    facts
    (OptBoundsCons (OptBoundsFact index length) (box facts))))

(define (opt-bounds-fact-uses-var? [fact : OptBoundsFact] [var : i64]) : bool
  (match fact
    [(OptBoundsFact index length)
      (or (opt-value-is-var? index var) (opt-value-is-var? length var))]))

(define (opt-bounds-invalidate-var [facts : OptBoundsFacts] [var : i64]) : OptBoundsFacts
  (match facts
    [(OptBoundsNil) (OptBoundsNil)]
    [(OptBoundsCons fact rest)
      (let
        [rest2 : OptBoundsFacts (opt-bounds-invalidate-var (box-get rest) var)]
        (if (opt-bounds-fact-uses-var? fact var)
          rest2
          (OptBoundsCons fact (box rest2))))]))

(define (opt-bounds-update-facts
  [facts : OptBoundsFacts]
  [instr : CompilerIrInstr]) : OptBoundsFacts
  (match instr
    [(IrInstrMov dst _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrAlloc dst _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrAddrOf dst _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrGep dst _ _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrLoad dst _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrCast dst _ _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrBinOp dst _ _ _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrUnOp dst _ _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrLaneId dst _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrSplat dst _ _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrVectorBinOp dst _ _ _ _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrVectorReduce dst _ _ _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrVectorCompare dst _ _ _ _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrMaskBinOp dst _ _ _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrMaskNot dst _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrMaskReduce dst _ _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrSelect dst _ _ _ _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrVectorLoad dst _ _ _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrPredicatedLoad dst _ _ _ _ _)
      (opt-bounds-invalidate-var facts dst)]
    [(IrInstrTailMask dst _ _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrEntryArgc dst) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrEntryArgv dst) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrEntryEnvp dst) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrCpuId _ _ _ _) (OptBoundsNil)]
    [(IrInstrXgetbv _ _) (OptBoundsNil)]
    [(IrInstrSyscall _ _) (OptBoundsNil)]
    [(IrInstrCall _ _ _ _) (OptBoundsNil)]
    [(IrInstrCallIndirect _ _ _ _) (OptBoundsNil)]
    [(IrInstrCallIndirectC _ _ _ _) (OptBoundsNil)]
    [(IrInstrTailCall _ _ _) (OptBoundsNil)]
    [(IrInstrStore _ _ _) (OptBoundsNil)]
    [(IrInstrStorePtr _ _ _) (OptBoundsNil)]
    [(IrInstrCopyBytes _ _ _) (OptBoundsNil)]
    [(IrInstrVectorStore _ _ _ _ _) (OptBoundsNil)]
    [(IrInstrPredicatedStore _ _ _ _ _ _) (OptBoundsNil)]
    [(IrInstrJump _) (OptBoundsNil)]
    [(IrInstrBranch _ _ _) (OptBoundsNil)]
    [(IrInstrReturn _) (OptBoundsNil)]
    [(IrInstrPhi _ _ _) (OptBoundsNil)]
    [(IrInstrBoundsCheck _ _ _) facts]
    ;; #2386: register-group ops define their dst -- invalidate any bounds fact.
    [(IrInstrPack dst _ _) (opt-bounds-invalidate-var facts dst)]
    [(IrInstrWord dst _ _ _) (opt-bounds-invalidate-var facts dst)]))

(define (opt-bounds-instrs
  [facts : OptBoundsFacts]
  [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrBoundsCheck index length _)
          (if (opt-bounds-contains facts index length)
            (opt-bounds-instrs facts (box-get rest))
            (compiler-ir-instr-cons
              instr
              (opt-bounds-instrs
                (opt-bounds-add facts index length)
                (box-get rest))))]
        [_
          (compiler-ir-instr-cons
            instr
            (opt-bounds-instrs
              (opt-bounds-update-facts facts instr)
              (box-get rest)))])]))

;; --- conservative CFG simplification (#926) ---------------------------------
;;
;; Runs after block-local constant/copy propagation has exposed literal branch
;; conditions. It rewrites known boolean branches to jumps, computes reachable
;; blocks from the function entry block, drops unreachable blocks, and trims phi
;; inputs from predecessors that are no longer reachable.
(defenum OptLabelSet
  (OptLabelNil)
  (OptLabelCons String (Box OptLabelSet)))

(define (opt-label-contains [set : OptLabelSet] [label : String]) : bool
  (let
    [cursor : OptLabelSet set]
    [found : bool false]
    (begin
      (while (not found)
        (match cursor
          [(OptLabelNil) (return false)]
          [(OptLabelCons head rest)
            (if (string-eq head label)
              (set! found true)
              (set! cursor (box-get rest)))]))
      true)))

(define (opt-label-add [set : OptLabelSet] [label : String]) : OptLabelSet
  (if (opt-label-contains set label)
    set
    (OptLabelCons label (box set))))

(define (opt-label-count [set : OptLabelSet]) : i64
  (match set
    [(OptLabelNil) 0]
    [(OptLabelCons _ rest) (+ 1 (opt-label-count (box-get rest)))]))

(define (opt-label-subset? [a : OptLabelSet] [b : OptLabelSet]) : bool
  (match a
    [(OptLabelNil) true]
    [(OptLabelCons label rest)
      (and (opt-label-contains b label) (opt-label-subset? (box-get rest) b))]))

(define (opt-label-set-eq? [a : OptLabelSet] [b : OptLabelSet]) : bool
  (and (opt-label-subset? a b) (opt-label-subset? b a)))

(define (opt-label-intersection [a : OptLabelSet] [b : OptLabelSet]) : OptLabelSet
  (match a
    [(OptLabelNil) (OptLabelNil)]
    [(OptLabelCons label rest)
      (let
        [tail : OptLabelSet (opt-label-intersection (box-get rest) b)]
        (if (opt-label-contains b label)
          (opt-label-add tail label)
          tail))]))

(defenum OptMaybeBlock
  (OptNoBlock)
  (OptSomeBlock CompilerIrBlock))

(define (opt-cfg-find-block [blocks : CompilerIrBlockList] [label : String]) : OptMaybeBlock
  (match blocks
    [(IrBlockNil) (OptNoBlock)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock block-label _)
          (if (string-eq block-label label)
            (OptSomeBlock block)
            (opt-cfg-find-block (box-get rest) label))])]
    [(IrBlockArray seq)
      (opt-cfg-find-block (compiler-ir-block-seq-to-list seq) label)]))

(define (opt-cfg-block-exists? [blocks : CompilerIrBlockList] [label : String]) : bool
  (match (opt-cfg-find-block blocks label)
    [(OptSomeBlock _) true]
    [(OptNoBlock) false]))

(define (opt-cfg-entry-label [blocks : CompilerIrBlockList]) : String
  (match blocks
    [(IrBlockNil) ""]
    [(IrBlockCons block _)
      (match block
        [(IrBlock label _) label])]
    [(IrBlockArray seq)
      (opt-cfg-entry-label (compiler-ir-block-seq-to-list seq))]))

(define (opt-cfg-block-labels [blocks : CompilerIrBlockList]) : OptLabelSet
  (match blocks
    [(IrBlockNil) (OptLabelNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _)
          (opt-label-add (opt-cfg-block-labels (box-get rest)) label)])]
    [(IrBlockArray seq)
      (opt-cfg-block-labels (compiler-ir-block-seq-to-list seq))]))

(define (opt-cfg-block-labels-unique-from?
  [blocks : CompilerIrBlockList]
  [seen : OptLabelSet]) : bool
  (match blocks
    [(IrBlockNil) true]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _)
          (if (opt-label-contains seen label)
            false
            (opt-cfg-block-labels-unique-from?
              (box-get rest)
              (opt-label-add seen label)))])]
    [(IrBlockArray seq)
      (opt-cfg-block-labels-unique-from?
        (compiler-ir-block-seq-to-list seq)
        seen)]))

(define (opt-cfg-block-labels-unique? [blocks : CompilerIrBlockList]) : bool
  (opt-cfg-block-labels-unique-from? blocks (OptLabelNil)))

(define (opt-cfg-successor-targets-known? [blocks : CompilerIrBlockList]) : bool
  (let
    [labels : OptLabelSet (opt-cfg-block-labels blocks)]
    (opt-cfg-successor-targets-known-in-blocks? blocks labels)))

(define (opt-cfg-successor-targets-known-in-blocks?
  [blocks : CompilerIrBlockList]
  [labels : OptLabelSet]) : bool
  (match blocks
    [(IrBlockNil) true]
    [(IrBlockCons block rest)
      (and
        (opt-label-subset?
          (opt-cfg-block-successors-with-next
            block
            (opt-cfg-entry-label (box-get rest)))
          labels)
        (opt-cfg-successor-targets-known-in-blocks? (box-get rest) labels))]
    [(IrBlockArray seq)
      (opt-cfg-successor-targets-known-in-blocks?
        (compiler-ir-block-seq-to-list seq)
        labels)]))

(define (opt-cfg-predecessors-scan
  [blocks : CompilerIrBlockList]
  [label : String]) : OptLabelSet
  (match blocks
    [(IrBlockNil) (OptLabelNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock block-label _)
          (let
            [tail : OptLabelSet
              (opt-cfg-predecessors-scan (box-get rest) label)]
            (if (opt-label-contains
              (opt-cfg-block-successors-with-next
                block
                (opt-cfg-entry-label (box-get rest)))
              label)
              (opt-label-add tail block-label)
              tail))])]
    [(IrBlockArray seq)
      (opt-cfg-predecessors-scan (compiler-ir-block-seq-to-list seq) label)]))

(define (opt-cfg-predecessors [blocks : CompilerIrBlockList] [label : String]) : OptLabelSet
  (opt-cfg-index-predecessors (opt-cfg-index-build blocks) label))

(define (opt-cfg-filter-blocks-by-labels
  [labels : OptLabelSet]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _)
          (if (opt-label-contains labels label)
            (compiler-ir-block-cons
              block
              (opt-cfg-filter-blocks-by-labels labels (box-get rest)))
            (opt-cfg-filter-blocks-by-labels labels (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-cfg-filter-blocks-by-labels
        labels
        (compiler-ir-block-seq-to-list seq))]))

(define (opt-cfg-reachable-block-order [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (opt-cfg-filter-blocks-by-labels (opt-cfg-reachable-blocks blocks) blocks))

(defenum OptDomEntry
  (OptDomEntry String OptLabelSet))

(defenum OptLegacyDomTable
  (OptDomNil)
  (OptDomCons OptDomEntry (Box OptLegacyDomTable)))

(define (opt-dom-table-lookup [table : OptLegacyDomTable] [label : String]) : OptLabelSet
  (match table
    [(OptDomNil) (OptLabelNil)]
    [(OptDomCons entry rest)
      (let
        [rest : OptLegacyDomTable (box-get rest)]
        (match entry
          [(OptDomEntry entry-label labels)
            (if (string-eq entry-label label)
              labels
              (opt-dom-table-lookup rest label))]))]))

(define (opt-dom-entry-eq? [a : OptDomEntry] [b : OptDomEntry]) : bool
  (match a
    [(OptDomEntry a-label a-labels)
      (match b
        [(OptDomEntry b-label b-labels)
          (and
            (string-eq a-label b-label)
            (opt-label-set-eq? a-labels b-labels))])]))

(define (opt-dom-table-eq? [a : OptLegacyDomTable] [b : OptLegacyDomTable]) : bool
  (match a
    [(OptDomNil)
      (match b
        [(OptDomNil) true]
        [_ false])]
    [(OptDomCons a-entry a-rest)
      (match b
        [(OptDomCons b-entry b-rest)
          (and
            (opt-dom-entry-eq? a-entry b-entry)
            (opt-dom-table-eq? (box-get a-rest) (box-get b-rest)))]
        [_ false])]))

(define (opt-dom-intersect-preds-rest
  [table : OptLegacyDomTable]
  [preds : OptLabelSet]
  [current : OptLabelSet]) : OptLabelSet
  (match preds
    [(OptLabelNil) current]
    [(OptLabelCons pred rest)
      (opt-dom-intersect-preds-rest
        table
        (box-get rest)
        (opt-label-intersection current (opt-dom-table-lookup table pred)))]))

(define (opt-dom-intersect-preds
  [table : OptLegacyDomTable]
  [preds : OptLabelSet]) : OptLabelSet
  (match preds
    [(OptLabelNil) (OptLabelNil)]
    [(OptLabelCons pred rest)
      (opt-dom-intersect-preds-rest
        table
        (box-get rest)
        (opt-dom-table-lookup table pred))]))

(define (opt-cfg-dominators-initial
  [blocks : CompilerIrBlockList]
  [reachable : OptLabelSet]
  [entry-label : String]
  [all-reachable : OptLabelSet]) : OptLegacyDomTable
  (match blocks
    [(IrBlockNil) (OptDomNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _)
          (if (opt-label-contains reachable label)
            (OptDomCons
              (OptDomEntry
                label
                (if (string-eq label entry-label)
                  (opt-label-add (OptLabelNil) label)
                  all-reachable))
              (box
                (opt-cfg-dominators-initial
                  (box-get rest)
                  reachable
                  entry-label
                  all-reachable)))
            (opt-cfg-dominators-initial
              (box-get rest)
              reachable
              entry-label
              all-reachable))])]
    [(IrBlockArray seq)
      (opt-cfg-dominators-initial
        (compiler-ir-block-seq-to-list seq)
        reachable
        entry-label
        all-reachable)]))

;; CFG index (#2175): integer block ids are assigned in block-list order and
;; reused for successor/predecessor CSR rows, reachability, RPO, and RPO slot
;; lookup. Existing callers still consume OptLabelSet adapters, but each CFG
;; snapshot is indexed once and rebuilt only after block-list-mutating
;; optimization passes.
(defenum OptI64List
  (OptI64Nil)
  (OptI64Cons i64 (Box OptI64List)))

(defstruct OptCfgCsr
  (offsets (Array i64))
  (edges (Array i64)))

(defstruct OptCfgIndex
  (ids StringI64Map)
  (labels (Array String))
  (succs OptCfgCsr)
  (preds OptCfgCsr)
  (reachable (Array bool))
  (reach-count i64)
  (rpo (Array i64))
  (rpo-num (Array i64)))

(defstruct OptPredMap
  (index OptCfgIndex))

(define (opt-pred-map-capacity [count : i64]) : i64
  (if (< count 4)
    8
    (* count 2)))

(define (opt-cfg-index-fill-labels!
  [blocks : CompilerIrBlockList]
  [ids : StringI64Map]
  [labels : (Array String)]
  [index : i64]) : StringI64Map
  (match blocks
    [(IrBlockNil) ids]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _)
          (begin
            (array-set! labels index label)
            (opt-cfg-index-fill-labels!
              (box-get rest)
              (string-i64-map-put ids label index)
              labels
              (+ index 1)))])]
    [(IrBlockArray seq)
      (opt-cfg-index-fill-labels!
        (compiler-ir-block-seq-to-list seq)
        ids
        labels
        index)]))

(define (opt-i64-list-contains? [items : OptI64List] [value : i64]) : bool
  (match items
    [(OptI64Nil) false]
    [(OptI64Cons head rest)
      (if (= head value)
        true
        (opt-i64-list-contains? (box-get rest) value))]))

(define (opt-i64-list-add [items : OptI64List] [value : i64]) : OptI64List
  (if (opt-i64-list-contains? items value)
    items
    (OptI64Cons value (box items))))

(define (opt-i64-list-reverse-onto [items : OptI64List] [acc : OptI64List]) : OptI64List
  (match items
    [(OptI64Nil) acc]
    [(OptI64Cons head rest)
      (opt-i64-list-reverse-onto (box-get rest) (OptI64Cons head (box acc)))]))

(define (opt-i64-list-reverse [items : OptI64List]) : OptI64List
  (opt-i64-list-reverse-onto items (OptI64Nil)))

(define (opt-i64-list-count [items : OptI64List]) : i64
  (match items
    [(OptI64Nil) 0]
    [(OptI64Cons _ rest) (+ 1 (opt-i64-list-count (box-get rest)))]))

(define (opt-i64-list-fill-edges!
  [items : OptI64List]
  [edges : (Array i64)]
  [index : i64]) : i64
  (match items
    [(OptI64Nil) index]
    [(OptI64Cons head rest)
      (begin
        (array-set! edges index head)
        (opt-i64-list-fill-edges! (box-get rest) edges (+ index 1)))]))

(define (opt-cfg-row-list-total
  [rows : (Array OptI64List)]
  [count : i64]
  [index : i64]
  [total : i64]) : i64
  (if (>= index count)
    total
    (opt-cfg-row-list-total
      rows
      count
      (+ index 1)
      (+ total (opt-i64-list-count (array-ref rows index))))))

(define (opt-cfg-i64-list-array-fill-empty!
  [rows : (Array OptI64List)]
  [count : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (array-set! rows i (OptI64Nil))
          (set! i (+ i 1))))
      unit)))

(define (opt-cfg-index-label-set-to-ids
  [labels : OptLabelSet]
  [ids : StringI64Map]) : OptI64List
  (match labels
    [(OptLabelNil) (OptI64Nil)]
    [(OptLabelCons label rest)
      (let
        [tail : OptI64List (opt-cfg-index-label-set-to-ids (box-get rest) ids)]
        (match (string-i64-map-get ids label)
          [(StringI64MapFound idx) (OptI64Cons idx (box tail))]
          [(StringI64MapMissing) tail]))]))

(define (opt-cfg-index-add-pred-edges!
  [pred-rows : (Array OptI64List)]
  [ids : StringI64Map]
  [source-id : i64]
  [succs : OptLabelSet]) : unit
  (match succs
    [(OptLabelNil) unit]
    [(OptLabelCons s rest)
      (begin
        (match (string-i64-map-get ids s)
          [(StringI64MapFound idx)
            (array-set!
              pred-rows
              idx
              (opt-i64-list-add (array-ref pred-rows idx) source-id))]
          [(StringI64MapMissing) unit])
        (opt-cfg-index-add-pred-edges! pred-rows ids source-id (box-get rest)))]))

(define (opt-cfg-index-fill-rows!
  [blocks : CompilerIrBlockList]
  [ids : StringI64Map]
  [succ-rows : (Array OptI64List)]
  [pred-rows : (Array OptI64List)]
  [index : i64]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ _)
          (let
            [succs : OptLabelSet
              (opt-cfg-block-successors-with-next
                block
                (opt-cfg-entry-label (box-get rest)))]
            (begin
              (array-set!
                succ-rows
                index
                (opt-cfg-index-label-set-to-ids succs ids))
              (opt-cfg-index-add-pred-edges! pred-rows ids index succs)
              (opt-cfg-index-fill-rows!
                (box-get rest)
                ids
                succ-rows
                pred-rows
                (+ index 1))))])]
    [(IrBlockArray seq)
      (opt-cfg-index-fill-rows!
        (compiler-ir-block-seq-to-list seq)
        ids
        succ-rows
        pred-rows
        index)]))

(define (opt-cfg-csr-fill-rows!
  [rows : (Array OptI64List)]
  [count : i64]
  [offsets : (Array i64)]
  [edges : (Array i64)]
  [row : i64]
  [edge-index : i64]) : unit
  (if (>= row count)
    (array-set! offsets count edge-index)
    (let
      [next-edge : i64
        (opt-i64-list-fill-edges!
          (opt-i64-list-reverse (array-ref rows row))
          edges
          edge-index)]
      (begin
        (array-set! offsets row edge-index)
        (opt-cfg-csr-fill-rows! rows count offsets edges (+ row 1) next-edge)))))

(define (opt-cfg-csr-build [rows : (Array OptI64List)] [count : i64]) : OptCfgCsr
  (let
    [edge-count : i64 (opt-cfg-row-list-total rows count 0 0)]
    [offsets : (Array i64) (make-array i64 (+ count 1))]
    [edges : (Array i64) (make-array i64 edge-count)]
    (begin
      (opt-cfg-csr-fill-rows! rows count offsets edges 0 0)
      (OptCfgCsr offsets edges))))

(define (opt-cfg-fill-bool!
  [values : (Array bool)]
  [count : i64]
  [value : bool]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (array-set! values i value)
          (set! i (+ i 1))))
      unit)))

(define (opt-cfg-fill-i64! [values : (Array i64)] [count : i64] [value : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (array-set! values i value)
          (set! i (+ i 1))))
      unit)))

(define (opt-cfg-index-dfs-edges!
  [succs : OptCfgCsr]
  [reachable : (Array bool)]
  [postorder : (Array i64)]
  [edge : i64]
  [end : i64]
  [post-count : i64]) : i64
  (if (>= edge end)
    post-count
    (opt-cfg-index-dfs-edges!
      succs
      reachable
      postorder
      (+ edge 1)
      end
      (opt-cfg-index-dfs-postorder!
        succs
        reachable
        postorder
        (array-ref (struct-get succs edges) edge)
        post-count))))

(define (opt-cfg-index-dfs-postorder!
  [succs : OptCfgCsr]
  [reachable : (Array bool)]
  [postorder : (Array i64)]
  [id : i64]
  [post-count : i64]) : i64
  (if (array-ref reachable id)
    post-count
    (let
      [edge : i64 (array-ref (struct-get succs offsets) id)]
      [end : i64 (array-ref (struct-get succs offsets) (+ id 1))]
      [next-count : i64
        (begin
          (array-set! reachable id true)
          (opt-cfg-index-dfs-edges!
            succs
            reachable
            postorder
            edge
            end
            post-count))]
      (begin
        (array-set! postorder next-count id)
        (+ next-count 1)))))

(define (opt-cfg-index-fill-rpo!
  [postorder : (Array i64)]
  [rpo : (Array i64)]
  [reach-count : i64]
  [index : i64]) : unit
  (if (>= index reach-count)
    unit
    (begin
      (array-set! rpo index (array-ref postorder (- (- reach-count 1) index)))
      (opt-cfg-index-fill-rpo! postorder rpo reach-count (+ index 1)))))

(define (opt-cfg-index-fill-rpo-num!
  [rpo : (Array i64)]
  [rpo-num : (Array i64)]
  [reach-count : i64]
  [slot : i64]) : unit
  (if (>= slot reach-count)
    unit
    (begin
      (array-set! rpo-num (array-ref rpo slot) slot)
      (opt-cfg-index-fill-rpo-num! rpo rpo-num reach-count (+ slot 1)))))

(define (opt-cfg-index-build [blocks : CompilerIrBlockList]) : OptCfgIndex
  (let
    [count : i64 (compiler-ir-block-list-count blocks)]
    [labels : (Array String) (make-array String count)]
    [ids : StringI64Map
      (opt-cfg-index-fill-labels!
        blocks
        (string-i64-map-with-capacity (opt-pred-map-capacity count))
        labels
        0)]
    [succ-rows : (Array OptI64List) (make-array OptI64List count)]
    [pred-rows : (Array OptI64List) (make-array OptI64List count)]
    [reachable : (Array bool) (make-array bool count)]
    [postorder : (Array i64) (make-array i64 count)]
    [rpo : (Array i64) (make-array i64 count)]
    [rpo-num : (Array i64) (make-array i64 count)]
    [reach-count : i64 0]
    (begin
      (opt-cfg-i64-list-array-fill-empty! succ-rows count)
      (opt-cfg-i64-list-array-fill-empty! pred-rows count)
      (opt-cfg-index-fill-rows! blocks ids succ-rows pred-rows 0)
      (opt-cfg-fill-bool! reachable count false)
      (opt-cfg-fill-i64! postorder count (- 0 1))
      (opt-cfg-fill-i64! rpo count (- 0 1))
      (opt-cfg-fill-i64! rpo-num count (- 0 1))
      (let
        [succ-csr : OptCfgCsr (opt-cfg-csr-build succ-rows count)]
        [pred-csr : OptCfgCsr (opt-cfg-csr-build pred-rows count)]
        (begin
          (if (> count 0)
            (set!
              reach-count
              (opt-cfg-index-dfs-postorder! succ-csr reachable postorder 0 0))
            unit)
          (opt-cfg-index-fill-rpo! postorder rpo reach-count 0)
          (opt-cfg-index-fill-rpo-num! rpo rpo-num reach-count 0)
          (OptCfgIndex
            ids
            labels
            succ-csr
            pred-csr
            reachable
            reach-count
            rpo
            rpo-num))))))

(define (opt-cfg-index-block-count [index : OptCfgIndex]) : i64
  (array-length (struct-get index labels)))

(define (opt-cfg-index-label [index : OptCfgIndex] [id : i64]) : String
  (if (and (>= id 0) (< id (opt-cfg-index-block-count index)))
    (array-ref (struct-get index labels) id)
    ""))

(define (opt-cfg-index-id [index : OptCfgIndex] [label : String]) : OptMaybeI64
  (match (string-i64-map-get (struct-get index ids) label)
    [(StringI64MapFound id) (OptSomeI64 id)]
    [(StringI64MapMissing) (OptNoI64)]))

(define (opt-cfg-index-row-labels-from
  [index : OptCfgIndex]
  [csr : OptCfgCsr]
  [edge : i64]
  [end : i64]
  [labels : OptLabelSet]) : OptLabelSet
  (if (>= edge end)
    labels
    (opt-cfg-index-row-labels-from
      index
      csr
      (+ edge 1)
      end
      (opt-label-add
        labels
        (opt-cfg-index-label index (array-ref (struct-get csr edges) edge))))))

(define (opt-cfg-index-row-labels
  [index : OptCfgIndex]
  [csr : OptCfgCsr]
  [id : i64]) : OptLabelSet
  (if (and (>= id 0) (< id (opt-cfg-index-block-count index)))
    (opt-cfg-index-row-labels-from
      index
      csr
      (array-ref (struct-get csr offsets) id)
      (array-ref (struct-get csr offsets) (+ id 1))
      (OptLabelNil))
    (OptLabelNil)))

(define (opt-cfg-index-successors [index : OptCfgIndex] [label : String]) : OptLabelSet
  (match (opt-cfg-index-id index label)
    [(OptSomeI64 id)
      (opt-cfg-index-row-labels index (struct-get index succs) id)]
    [(OptNoI64) (OptLabelNil)]))

(define (opt-cfg-index-predecessors [index : OptCfgIndex] [label : String]) : OptLabelSet
  (match (opt-cfg-index-id index label)
    [(OptSomeI64 id)
      (opt-cfg-index-row-labels index (struct-get index preds) id)]
    [(OptNoI64) (OptLabelNil)]))

(define (opt-cfg-index-reachable? [index : OptCfgIndex] [label : String]) : bool
  (match (opt-cfg-index-id index label)
    [(OptSomeI64 id) (array-ref (struct-get index reachable) id)]
    [(OptNoI64) false]))

(define (opt-cfg-index-reachable-labels-from
  [index : OptCfgIndex]
  [id : i64]
  [labels : OptLabelSet]) : OptLabelSet
  (if (>= id (opt-cfg-index-block-count index))
    labels
    (opt-cfg-index-reachable-labels-from
      index
      (+ id 1)
      (if (array-ref (struct-get index reachable) id)
        (opt-label-add labels (opt-cfg-index-label index id))
        labels))))

(define (opt-cfg-index-reachable-labels [index : OptCfgIndex]) : OptLabelSet
  (opt-cfg-index-reachable-labels-from index 0 (OptLabelNil)))

(define (opt-cfg-index-rpo-id [index : OptCfgIndex] [slot : i64]) : i64
  (if (and (>= slot 0) (< slot (struct-get index reach-count)))
    (array-ref (struct-get index rpo) slot)
    (- 0 1)))

(define (opt-cfg-index-rpo-num [index : OptCfgIndex] [id : i64]) : i64
  (if (and (>= id 0) (< id (opt-cfg-index-block-count index)))
    (array-ref (struct-get index rpo-num) id)
    (- 0 1)))

(define (opt-cfg-index-rpo-label [index : OptCfgIndex] [slot : i64]) : String
  (opt-cfg-index-label index (opt-cfg-index-rpo-id index slot)))

(define (opt-pred-map-build [blocks : CompilerIrBlockList]) : OptPredMap
  (OptPredMap (opt-cfg-index-build blocks)))

(define (opt-pred-map-lookup [map : OptPredMap] [label : String]) : OptLabelSet
  (opt-cfg-index-predecessors (struct-get map index) label))

(define (opt-pred-map-successors [map : OptPredMap] [label : String]) : OptLabelSet
  (opt-cfg-index-successors (struct-get map index) label))

(define (opt-cfg-dominators-step-entry
  [pred-map : OptPredMap]
  [reachable : OptLabelSet]
  [entry-label : String]
  [old : OptLegacyDomTable]
  [entry : OptDomEntry]) : OptDomEntry
  (match entry
    [(OptDomEntry label _)
      (if (string-eq label entry-label)
        (OptDomEntry label (opt-label-add (OptLabelNil) label))
        (let
          [preds : OptLabelSet
            (opt-label-intersection
              (opt-pred-map-lookup pred-map label)
              reachable)]
          (OptDomEntry
            label
            (opt-label-add (opt-dom-intersect-preds old preds) label))))]))

(define (opt-cfg-dominators-step
  [pred-map : OptPredMap]
  [reachable : OptLabelSet]
  [entry-label : String]
  [old : OptLegacyDomTable]
  [remaining : OptLegacyDomTable]) : OptLegacyDomTable
  (match remaining
    [(OptDomNil) (OptDomNil)]
    [(OptDomCons entry rest)
      (OptDomCons
        (opt-cfg-dominators-step-entry pred-map reachable entry-label old entry)
        (box
          (opt-cfg-dominators-step
            pred-map
            reachable
            entry-label
            old
            (box-get rest))))]))

(define (opt-cfg-dominators-fixed
  [pred-map : OptPredMap]
  [reachable : OptLabelSet]
  [entry-label : String]
  [table : OptLegacyDomTable]
  [remaining : i64]) : OptLegacyDomTable
  (if (<= remaining 0)
    table
    (let
      [next : OptLegacyDomTable
        (opt-cfg-dominators-step pred-map reachable entry-label table table)]
      (if (opt-dom-table-eq? table next)
        next
        (opt-cfg-dominators-fixed
          pred-map
          reachable
          entry-label
          next
          (- remaining 1))))))

(define (opt-cfg-dominators-legacy-with
  [blocks : CompilerIrBlockList]
  [pred-map : OptPredMap]
  [reachable : OptLabelSet]
  [entry-label : String]) : OptLegacyDomTable
  (let
    [initial : OptLegacyDomTable
      (opt-cfg-dominators-initial blocks reachable entry-label reachable)]
    (opt-cfg-dominators-fixed
      pred-map
      reachable
      entry-label
      initial
      (+ (compiler-ir-block-list-count blocks) 1))))

(define (opt-bits-words [bits : i64]) : i64
  (/ (+ bits 62) 63))

(define (opt-bits-full-word-mask) : i64
  9223372036854775807)

(define (opt-bits-tail-mask [bits : i64]) : i64
  (let
    [rem : i64 (% bits 63)]
    (if (= rem 0)
      (opt-bits-full-word-mask)
      (- (shl 1 rem) 1))))

(define (opt-bits-set! [row : (Array i64)] [base : i64] [bit : i64]) : unit
  (let
    [w : i64 (+ base (/ bit 63))]
    (array-set! row w (bit-or (array-ref row w) (shl 1 (% bit 63))))))

(define (opt-bits-test [row : (Array i64)] [base : i64] [bit : i64]) : bool
  (not (= (bit-and (array-ref row (+ base (/ bit 63))) (shl 1 (% bit 63))) 0)))

(define (opt-bits-clear! [row : (Array i64)] [base : i64] [words : i64]) : unit
  (let
    [w : i64 0]
    (begin
      (while (< w words)
        (begin
          (array-set! row (+ base w) 0)
          (set! w (+ w 1))))
      unit)))

(define (opt-bits-fill-universe! [row : (Array i64)] [base : i64] [bits : i64]) : unit
  (let
    [words : i64 (opt-bits-words bits)]
    [last : i64 (- words 1)]
    [w : i64 0]
    (begin
      (while (< w words)
        (begin
          (array-set!
            row
            (+ base w)
            (if (= w last)
              (opt-bits-tail-mask bits)
              (opt-bits-full-word-mask)))
          (set! w (+ w 1))))
      unit)))

(define (opt-bits-and-into!
  [dst : (Array i64)]
  [dst-base : i64]
  [src : (Array i64)]
  [src-base : i64]
  [words : i64]) : unit
  (let
    [w : i64 0]
    (begin
      (while (< w words)
        (begin
          (array-set!
            dst
            (+ dst-base w)
            (bit-and
              (array-ref dst (+ dst-base w))
              (array-ref src (+ src-base w))))
          (set! w (+ w 1))))
      unit)))

(define (opt-bits-copy!
  [dst : (Array i64)]
  [dst-base : i64]
  [src : (Array i64)]
  [src-base : i64]
  [words : i64]) : unit
  (let
    [w : i64 0]
    (begin
      (while (< w words)
        (begin
          (array-set! dst (+ dst-base w) (array-ref src (+ src-base w)))
          (set! w (+ w 1))))
      unit)))

(define (opt-bits-eq?
  [a : (Array i64)]
  [a-base : i64]
  [b : (Array i64)]
  [b-base : i64]
  [words : i64]) : bool
  (let
    [w : i64 0]
    [same : bool true]
    (begin
      (while (and same (< w words))
        (begin
          (if (= (array-ref a (+ a-base w)) (array-ref b (+ b-base w)))
            unit
            (set! same false))
          (set! w (+ w 1))))
      same)))

(defstruct OptDomInfo
  (index OptCfgIndex)
  (words i64)
  (rows (Array i64))
  (idom (Array i64))
  (tin (Array i64))
  (tout (Array i64)))

(define (opt-dom-row-base [words : i64] [id : i64]) : i64
  (* id words))

(define (opt-dom-fill-reachable-universe!
  [index : OptCfgIndex]
  [row : (Array i64)]
  [base : i64]) : unit
  (let
    [count : i64 (opt-cfg-index-block-count index)]
    [id : i64 0]
    (begin
      (while (< id count)
        (begin
          (if (array-ref (struct-get index reachable) id)
            (opt-bits-set! row base id)
            unit)
          (set! id (+ id 1))))
      unit)))

(define (opt-dom-init-row!
  [index : OptCfgIndex]
  [rows : (Array i64)]
  [words : i64]
  [entry-id : i64]
  [id : i64]) : unit
  (let
    [base : i64 (opt-dom-row-base words id)]
    (begin
      (opt-bits-clear! rows base words)
      (if (array-ref (struct-get index reachable) id)
        (if (= id entry-id)
          (opt-bits-set! rows base id)
          (opt-dom-fill-reachable-universe! index rows base))
        unit))))

(define (opt-dom-init-rows!
  [index : OptCfgIndex]
  [rows : (Array i64)]
  [words : i64]
  [entry-id : i64]) : unit
  (let
    [id : i64 0]
    [count : i64 (opt-cfg-index-block-count index)]
    (begin
      (while (< id count)
        (begin
          (opt-dom-init-row! index rows words entry-id id)
          (set! id (+ id 1))))
      unit)))

(define (opt-dom-row-from-preds!
  [index : OptCfgIndex]
  [rows : (Array i64)]
  [scratch : (Array i64)]
  [words : i64]
  [id : i64]) : unit
  (let
    [preds : OptCfgCsr (struct-get index preds)]
    [edge : i64 (array-ref (struct-get preds offsets) id)]
    [end : i64 (array-ref (struct-get preds offsets) (+ id 1))]
    [saw : bool false]
    (begin
      (opt-bits-clear! scratch 0 words)
      (opt-dom-fill-reachable-universe! index scratch 0)
      (while (< edge end)
        (let
          [pred : i64 (array-ref (struct-get preds edges) edge)]
          (begin
            (if (array-ref (struct-get index reachable) pred)
              (begin
                (opt-bits-and-into!
                  scratch
                  0
                  rows
                  (opt-dom-row-base words pred)
                  words)
                (set! saw true))
              unit)
            (set! edge (+ edge 1)))))
      (if saw
        unit
        (opt-bits-clear! scratch 0 words))
      (opt-bits-set! scratch 0 id))))

(define (opt-dom-update-row!
  [index : OptCfgIndex]
  [rows : (Array i64)]
  [scratch : (Array i64)]
  [words : i64]
  [entry-id : i64]
  [id : i64]) : bool
  (if (or (= id entry-id) (not (array-ref (struct-get index reachable) id)))
    false
    (let
      [base : i64 (opt-dom-row-base words id)]
      (begin
        (opt-dom-row-from-preds! index rows scratch words id)
        (if (opt-bits-eq? rows base scratch 0 words)
          false
          (begin
            (opt-bits-copy! rows base scratch 0 words)
            true))))))

(define (opt-dom-iterate-rpo!
  [index : OptCfgIndex]
  [rows : (Array i64)]
  [scratch : (Array i64)]
  [words : i64]
  [entry-id : i64]) : bool
  (let
    [slot : i64 0]
    [changed : bool false]
    (begin
      (while (< slot (struct-get index reach-count))
        (begin
          (if (opt-dom-update-row!
            index
            rows
            scratch
            words
            entry-id
            (opt-cfg-index-rpo-id index slot))
            (set! changed true)
            unit)
          (set! slot (+ slot 1))))
      changed)))

(define (opt-dom-fixpoint!
  [index : OptCfgIndex]
  [rows : (Array i64)]
  [scratch : (Array i64)]
  [words : i64]
  [entry-id : i64]
  [remaining : i64]) : unit
  (if (<= remaining 0)
    unit
    (if (opt-dom-iterate-rpo! index rows scratch words entry-id)
      (opt-dom-fixpoint! index rows scratch words entry-id (- remaining 1))
      unit)))

(define (opt-cfg-dominators-bitset-with
  [index : OptCfgIndex]
  [entry-label : String]) : OptDomInfo
  (let
    [count : i64 (opt-cfg-index-block-count index)]
    [words : i64 (opt-bits-words count)]
    [rows : (Array i64) (make-array i64 (* count words))]
    [scratch : (Array i64) (make-array i64 words)]
    [empty : (Array i64) (make-array i64 0)]
    [entry-id : i64 (- 0 1)]
    (begin
      (match (opt-cfg-index-id index entry-label)
        [(OptSomeI64 id) (set! entry-id id)]
        [(OptNoI64) unit])
      (opt-dom-init-rows! index rows words entry-id)
      (if (>= entry-id 0)
        (opt-dom-fixpoint! index rows scratch words entry-id (+ count 1))
        unit)
      (OptDomInfo index words rows empty empty empty))))

(define (opt-dom-intersect-idom
  [index : OptCfgIndex]
  [idom : (Array i64)]
  [left : i64]
  [right : i64]) : i64
  (let
    [a : i64 left]
    [b : i64 right]
    (begin
      (while (!= a b)
        (begin
          (while (>
            (opt-cfg-index-rpo-num index a)
            (opt-cfg-index-rpo-num index b))
            (set! a (array-ref idom a)))
          (while (>
            (opt-cfg-index-rpo-num index b)
            (opt-cfg-index-rpo-num index a))
            (set! b (array-ref idom b)))))
      a)))

(define (opt-dom-idom-from-preds
  [index : OptCfgIndex]
  [idom : (Array i64)]
  [id : i64]) : i64
  (let
    [preds : OptCfgCsr (struct-get index preds)]
    [edge : i64 (array-ref (struct-get preds offsets) id)]
    [end : i64 (array-ref (struct-get preds offsets) (+ id 1))]
    [candidate : i64 (- 0 1)]
    (begin
      (while (< edge end)
        (let
          [pred : i64 (array-ref (struct-get preds edges) edge)]
          (begin
            (if (and
              (array-ref (struct-get index reachable) pred)
              (>= (array-ref idom pred) 0))
              (if (< candidate 0)
                (set! candidate pred)
                (set!
                  candidate
                  (opt-dom-intersect-idom index idom pred candidate)))
              unit)
            (set! edge (+ edge 1)))))
      candidate)))

(define (opt-dom-idom-iterate-rpo!
  [index : OptCfgIndex]
  [idom : (Array i64)]
  [entry-id : i64]) : bool
  (let
    [slot : i64 1]
    [changed : bool false]
    (begin
      (while (< slot (struct-get index reach-count))
        (let
          [id : i64 (opt-cfg-index-rpo-id index slot)]
          [new-idom : i64 (opt-dom-idom-from-preds index idom id)]
          (begin
            (if (and
              (!= id entry-id)
              (and (>= new-idom 0) (!= (array-ref idom id) new-idom)))
              (begin
                (array-set! idom id new-idom)
                (set! changed true))
              unit)
            (set! slot (+ slot 1)))))
      changed)))

(define (opt-dom-idom-fixpoint!
  [index : OptCfgIndex]
  [idom : (Array i64)]
  [entry-id : i64]
  [remaining : i64]) : unit
  (if (<= remaining 0)
    unit
    (if (opt-dom-idom-iterate-rpo! index idom entry-id)
      (opt-dom-idom-fixpoint! index idom entry-id (- remaining 1))
      unit)))

(define (opt-dom-child-rows-fill!
  [index : OptCfgIndex]
  [idom : (Array i64)]
  [rows : (Array OptI64List)]) : unit
  (let
    [count : i64 (opt-cfg-index-block-count index)]
    [id : i64 0]
    (begin
      (while (< id count)
        (let
          [parent : i64 (array-ref idom id)]
          (begin
            (if (and
              (array-ref (struct-get index reachable) id)
              (and (>= parent 0) (!= parent id)))
              (array-set!
                rows
                parent
                (opt-i64-list-add (array-ref rows parent) id))
              unit)
            (set! id (+ id 1)))))
      unit)))

(define (opt-dom-euler-dfs!
  [children : OptCfgCsr]
  [tin : (Array i64)]
  [tout : (Array i64)]
  [id : i64]
  [time : i64]) : i64
  (let
    [next : i64 (+ time 1)]
    [edge : i64 (array-ref (struct-get children offsets) id)]
    [end : i64 (array-ref (struct-get children offsets) (+ id 1))]
    (begin
      (array-set! tin id time)
      (while (< edge end)
        (begin
          (set!
            next
            (opt-dom-euler-dfs!
              children
              tin
              tout
              (array-ref (struct-get children edges) edge)
              next))
          (set! edge (+ edge 1))))
      (array-set! tout id next)
      next)))

(define (opt-dom-build-euler!
  [index : OptCfgIndex]
  [idom : (Array i64)]
  [tin : (Array i64)]
  [tout : (Array i64)]
  [entry-id : i64]) : unit
  (let
    [count : i64 (opt-cfg-index-block-count index)]
    [child-rows : (Array OptI64List) (make-array OptI64List count)]
    (begin
      (opt-cfg-fill-i64! tin count (- 0 1))
      (opt-cfg-fill-i64! tout count (- 0 1))
      (if (>= entry-id 0)
        (begin
          (opt-cfg-i64-list-array-fill-empty! child-rows count)
          (opt-dom-child-rows-fill! index idom child-rows)
          (let
            [children : OptCfgCsr (opt-cfg-csr-build child-rows count)]
            (begin
              (opt-dom-euler-dfs! children tin tout entry-id 0)
              unit)))
        unit))))

(define (opt-cfg-dominators-with [index : OptCfgIndex] [entry-label : String]) : OptDomInfo
  (let
    [count : i64 (opt-cfg-index-block-count index)]
    [idom : (Array i64) (make-array i64 count)]
    [tin : (Array i64) (make-array i64 count)]
    [tout : (Array i64) (make-array i64 count)]
    [empty : (Array i64) (make-array i64 0)]
    [entry-id : i64 (- 0 1)]
    (begin
      (opt-cfg-fill-i64! idom count (- 0 1))
      (match (opt-cfg-index-id index entry-label)
        [(OptSomeI64 id) (set! entry-id id)]
        [(OptNoI64) unit])
      (if (and
        (>= entry-id 0)
        (array-ref (struct-get index reachable) entry-id))
        (begin
          (array-set! idom entry-id entry-id)
          (opt-dom-idom-fixpoint! index idom entry-id (+ count 1))
          (opt-dom-build-euler! index idom tin tout entry-id))
        (begin
          (opt-cfg-fill-i64! tin count (- 0 1))
          (opt-cfg-fill-i64! tout count (- 0 1))))
      (OptDomInfo index 0 empty idom tin tout))))

(define (opt-dom-info-dominates-id?
  [info : OptDomInfo]
  [dominator-id : i64]
  [label-id : i64]) : bool
  (let
    [index : OptCfgIndex (struct-get info index)]
    [count : i64 (opt-cfg-index-block-count index)]
    (if (and
      (and (>= dominator-id 0) (< dominator-id count))
      (and (>= label-id 0) (< label-id count)))
      (if (and
        (array-ref (struct-get index reachable) dominator-id)
        (array-ref (struct-get index reachable) label-id))
        (let
          [dom-tin : i64 (array-ref (struct-get info tin) dominator-id)]
          [dom-tout : i64 (array-ref (struct-get info tout) dominator-id)]
          [label-tin : i64 (array-ref (struct-get info tin) label-id)]
          [label-tout : i64 (array-ref (struct-get info tout) label-id)]
          (and
            (and (>= dom-tin 0) (>= label-tin 0))
            (and (<= dom-tin label-tin) (<= label-tout dom-tout))))
        false)
      false)))

(define (opt-dom-bitset-info-dominates-id?
  [info : OptDomInfo]
  [dominator-id : i64]
  [label-id : i64]) : bool
  (let
    [index : OptCfgIndex (struct-get info index)]
    [count : i64 (opt-cfg-index-block-count index)]
    (if (and
      (and (>= dominator-id 0) (< dominator-id count))
      (and (>= label-id 0) (< label-id count)))
      (if (and
        (array-ref (struct-get index reachable) dominator-id)
        (array-ref (struct-get index reachable) label-id))
        (opt-bits-test
          (struct-get info rows)
          (opt-dom-row-base (struct-get info words) label-id)
          dominator-id)
        false)
      false)))

(define (opt-dom-info-row-matches-legacy?
  [info : OptDomInfo]
  [legacy-labels : OptLabelSet]
  [label-id : i64]
  [dominator-id : i64]) : bool
  (let
    [index : OptCfgIndex (struct-get info index)]
    [count : i64 (opt-cfg-index-block-count index)]
    (if (>= dominator-id count)
      true
      (let
        [label : String (opt-cfg-index-label index dominator-id)]
        [legacy-has : bool (opt-label-contains legacy-labels label)]
        [info-has : bool
          (opt-dom-info-dominates-id? info dominator-id label-id)]
        (if (or (and legacy-has info-has) (and (not legacy-has) (not info-has)))
          (opt-dom-info-row-matches-legacy?
            info
            legacy-labels
            label-id
            (+ dominator-id 1))
          false)))))

(define (opt-dom-info-matches-legacy-from?
  [info : OptDomInfo]
  [legacy : OptLegacyDomTable]
  [id : i64]) : bool
  (let
    [index : OptCfgIndex (struct-get info index)]
    [count : i64 (opt-cfg-index-block-count index)]
    (if (>= id count)
      true
      (if (array-ref (struct-get index reachable) id)
        (let
          [label : String (opt-cfg-index-label index id)]
          [legacy-labels : OptLabelSet (opt-dom-table-lookup legacy label)]
          (if (opt-dom-info-row-matches-legacy? info legacy-labels id 0)
            (opt-dom-info-matches-legacy-from? info legacy (+ id 1))
            false))
        (opt-dom-info-matches-legacy-from? info legacy (+ id 1))))))

(define (opt-dom-info-matches-legacy?
  [info : OptDomInfo]
  [legacy : OptLegacyDomTable]) : bool
  (opt-dom-info-matches-legacy-from? info legacy 0))

(define (opt-dom-info-row-matches-bitset?
  [info : OptDomInfo]
  [bitset : OptDomInfo]
  [label-id : i64]
  [dominator-id : i64]) : bool
  (let
    [index : OptCfgIndex (struct-get info index)]
    [count : i64 (opt-cfg-index-block-count index)]
    (if (>= dominator-id count)
      true
      (let
        [info-has : bool
          (opt-dom-info-dominates-id? info dominator-id label-id)]
        [bitset-has : bool
          (opt-dom-bitset-info-dominates-id? bitset dominator-id label-id)]
        (if (or (and info-has bitset-has) (and (not info-has) (not bitset-has)))
          (opt-dom-info-row-matches-bitset?
            info
            bitset
            label-id
            (+ dominator-id 1))
          false)))))

(define (opt-dom-info-matches-bitset-from?
  [info : OptDomInfo]
  [bitset : OptDomInfo]
  [id : i64]) : bool
  (let
    [index : OptCfgIndex (struct-get info index)]
    [count : i64 (opt-cfg-index-block-count index)]
    (if (>= id count)
      true
      (if (opt-dom-info-row-matches-bitset? info bitset id 0)
        (opt-dom-info-matches-bitset-from? info bitset (+ id 1))
        false))))

(define (opt-dom-info-matches-bitset? [info : OptDomInfo] [bitset : OptDomInfo]) : bool
  (opt-dom-info-matches-bitset-from? info bitset 0))

(defstruct OptCfgContext
  (index OptCfgIndex)
  (pred-map OptPredMap)
  (reachable OptLabelSet)
  (entry-label String)
  (doms OptDomInfo))

(define (opt-cfg-context-build [blocks : CompilerIrBlockList]) : OptCfgContext
  (let
    [index : OptCfgIndex (opt-cfg-index-build blocks)]
    [pred-map : OptPredMap (OptPredMap index)]
    [reachable : OptLabelSet (opt-cfg-index-reachable-labels index)]
    [entry-label : String (opt-cfg-entry-label blocks)]
    [doms : OptDomInfo (opt-cfg-dominators-with index entry-label)]
    (OptCfgContext index pred-map reachable entry-label doms)))

(define (opt-cfg-dominators [blocks : CompilerIrBlockList]) : OptDomInfo
  (struct-get (opt-cfg-context-build blocks) doms))

(define (opt-cfg-dominators-match-legacy? [blocks : CompilerIrBlockList]) : bool
  (let
    [context : OptCfgContext (opt-cfg-context-build blocks)]
    (opt-dom-info-matches-legacy?
      (struct-get context doms)
      (opt-cfg-dominators-legacy-with
        blocks
        (struct-get context pred-map)
        (struct-get context reachable)
        (struct-get context entry-label)))))

(define (opt-cfg-dominators-match-bitset? [blocks : CompilerIrBlockList]) : bool
  (let
    [context : OptCfgContext (opt-cfg-context-build blocks)]
    (opt-dom-info-matches-bitset?
      (struct-get context doms)
      (opt-cfg-dominators-bitset-with
        (struct-get context index)
        (struct-get context entry-label)))))

(define (opt-dom-dominates?
  [table : OptDomInfo]
  [dominator : String]
  [label : String]) : bool
  (match (opt-cfg-index-id (struct-get table index) dominator)
    [(OptSomeI64 dominator-id)
      (match (opt-cfg-index-id (struct-get table index) label)
        [(OptSomeI64 label-id)
          (opt-dom-info-dominates-id? table dominator-id label-id)]
        [(OptNoI64) false])]
    [(OptNoI64) false]))

(define (opt-dom-strict-dominates?
  [table : OptDomInfo]
  [dominator : String]
  [label : String]) : bool
  (and
    (not (string-eq dominator label))
    (opt-dom-dominates? table dominator label)))

(define (opt-cfg-frontier-has-pred?
  [doms : OptDomInfo]
  [label : String]
  [preds : OptLabelSet]) : bool
  (match preds
    [(OptLabelNil) false]
    [(OptLabelCons pred rest)
      (if (opt-dom-dominates? doms label pred)
        true
        (opt-cfg-frontier-has-pred? doms label (box-get rest)))]))

(define (opt-cfg-dominance-frontier-blocks
  [all-blocks : CompilerIrBlockList]
  [remaining : CompilerIrBlockList]
  [pred-map : OptPredMap]
  [reachable : OptLabelSet]
  [doms : OptDomInfo]
  [label : String]) : OptLabelSet
  (match remaining
    [(IrBlockNil) (OptLabelNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock block-label _)
          (let
            [tail : OptLabelSet
              (opt-cfg-dominance-frontier-blocks
                all-blocks
                (box-get rest)
                pred-map
                reachable
                doms
                label)]
            (if (and
              (opt-label-contains reachable block-label)
              (and
                (opt-cfg-frontier-has-pred?
                  doms
                  label
                  (opt-label-intersection
                    (opt-pred-map-lookup pred-map block-label)
                    reachable))
                (not (opt-dom-strict-dominates? doms label block-label))))
              (opt-label-add tail block-label)
              tail))])]
    [(IrBlockArray seq)
      (opt-cfg-dominance-frontier-blocks
        all-blocks
        (compiler-ir-block-seq-to-list seq)
        pred-map
        reachable
        doms
        label)]))

(define (opt-cfg-dominance-frontier-with-context
  [blocks : CompilerIrBlockList]
  [context : OptCfgContext]
  [label : String]) : OptLabelSet
  (opt-cfg-dominance-frontier-blocks
    blocks
    blocks
    (struct-get context pred-map)
    (struct-get context reachable)
    (struct-get context doms)
    label))

(define (opt-cfg-dominance-frontier
  [blocks : CompilerIrBlockList]
  [label : String]) : OptLabelSet
  (opt-cfg-dominance-frontier-with-context
    blocks
    (opt-cfg-context-build blocks)
    label))

(defenum ResultCompilerOptimizeVerify
  (OkCompilerOptimizeVerify)
  (ErrCompilerOptimizeVerify String))

(define (opt-verify-ok? [result : ResultCompilerOptimizeVerify]) : bool
  (match result
    [(OkCompilerOptimizeVerify) true]
    [(ErrCompilerOptimizeVerify _) false]))

(define (opt-verify-error-ok?
  [result : ResultCompilerOptimizeVerify]
  [want : String]) : bool
  (match result
    [(ErrCompilerOptimizeVerify message) (string-eq message want)]
    [(OkCompilerOptimizeVerify) false]))

(defenum OptVarDef
  (OptVarDef i64 String i64))

(defenum OptVarDefList
  (OptVarDefNil)
  (OptVarDefCons OptVarDef (Box OptVarDefList)))

(defenum OptMaybeVarDef
  (OptNoVarDef)
  (OptSomeVarDef OptVarDef))

(defenum OptVarSetResult
  (OptVarSetOk I64I64Map)
  (OptVarSetErr))

(define (opt-var-set-add-unique [set : I64I64Map] [var : i64]) : OptVarSetResult
  (if (opt-used-contains set var)
    (OptVarSetErr)
    (OptVarSetOk (opt-used-add set var))))

(define (opt-instr-def-var [instr : CompilerIrInstr]) : OptMaybeI64
  (match instr
    [(IrInstrMov dst _ _) (OptSomeI64 dst)]
    [(IrInstrAlloc dst _) (OptSomeI64 dst)]
    [(IrInstrAddrOf dst _) (OptSomeI64 dst)]
    [(IrInstrGep dst _ _ _) (OptSomeI64 dst)]
    [(IrInstrLoad dst _ _) (OptSomeI64 dst)]
    [(IrInstrCast dst _ _ _) (OptSomeI64 dst)]
    [(IrInstrBinOp dst _ _ _ _) (OptSomeI64 dst)]
    [(IrInstrUnOp dst _ _ _) (OptSomeI64 dst)]
    [(IrInstrLaneId dst _ _) (OptSomeI64 dst)]
    [(IrInstrSplat dst _ _ _) (OptSomeI64 dst)]
    [(IrInstrVectorBinOp dst _ _ _ _ _) (OptSomeI64 dst)]
    [(IrInstrVectorReduce dst _ _ _ _) (OptSomeI64 dst)]
    [(IrInstrVectorCompare dst _ _ _ _ _) (OptSomeI64 dst)]
    [(IrInstrMaskBinOp dst _ _ _ _) (OptSomeI64 dst)]
    [(IrInstrMaskNot dst _ _) (OptSomeI64 dst)]
    [(IrInstrMaskReduce dst _ _ _) (OptSomeI64 dst)]
    [(IrInstrSelect dst _ _ _ _ _) (OptSomeI64 dst)]
    [(IrInstrVectorLoad dst _ _ _ _) (OptSomeI64 dst)]
    [(IrInstrPredicatedLoad dst _ _ _ _ _) (OptSomeI64 dst)]
    [(IrInstrTailMask dst _ _ _) (OptSomeI64 dst)]
    [(IrInstrEntryArgc dst) (OptSomeI64 dst)]
    [(IrInstrEntryArgv dst) (OptSomeI64 dst)]
    [(IrInstrEntryEnvp dst) (OptSomeI64 dst)]
    [(IrInstrCpuId dst _ _ _) (OptSomeI64 dst)]
    [(IrInstrXgetbv dst _) (OptSomeI64 dst)]
    [(IrInstrSyscall dst _) (OptSomeI64 dst)]
    [(IrInstrCall dst _ _ _) (OptSomeI64 dst)]
    [(IrInstrPhi dst _ _) (OptSomeI64 dst)]
    [_ (OptNoI64)]))

(define (opt-instr-def-position [instr : CompilerIrInstr] [pos : i64]) : i64
  (match instr
    [(IrInstrPhi _ _ _) 0]
    [_ pos]))

(define (opt-verify-param-def-set
  [params : CompilerIrParamList]
  [set : I64I64Map]) : OptVarSetResult
  (match params
    [(IrParamNil) (OptVarSetOk set)]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ _ var)
          (match (opt-var-set-add-unique set var)
            [(OptVarSetOk next) (opt-verify-param-def-set (box-get rest) next)]
            [(OptVarSetErr) (OptVarSetErr)])])]))

(define (opt-verify-instr-def-set
  [instrs : CompilerIrInstrList]
  [set : I64I64Map]) : OptVarSetResult
  (match instrs
    [(IrInstrNil) (OptVarSetOk set)]
    [(IrInstrCons instr rest)
      (match (opt-instr-def-var instr)
        [(OptSomeI64 var)
          (match (opt-var-set-add-unique set var)
            [(OptVarSetOk next) (opt-verify-instr-def-set (box-get rest) next)]
            [(OptVarSetErr) (OptVarSetErr)])]
        [(OptNoI64) (opt-verify-instr-def-set (box-get rest) set)])]))

(define (opt-verify-instr-def-seq-from
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [set : I64I64Map]) : OptVarSetResult
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (OptVarSetOk set)
    (match (opt-instr-def-var (compiler-ir-instr-seq-ref instrs index))
      [(OptSomeI64 var)
        (match (opt-var-set-add-unique set var)
          [(OptVarSetOk next)
            (opt-verify-instr-def-seq-from instrs (+ index 1) next)]
          [(OptVarSetErr) (OptVarSetErr)])]
      [(OptNoI64) (opt-verify-instr-def-seq-from instrs (+ index 1) set)])))

(define (opt-verify-block-def-set
  [blocks : CompilerIrBlockList]
  [set : I64I64Map]) : OptVarSetResult
  (match blocks
    [(IrBlockNil) (OptVarSetOk set)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (match (opt-verify-instr-def-seq-from instrs 0 set)
            [(OptVarSetOk next) (opt-verify-block-def-set (box-get rest) next)]
            [(OptVarSetErr) (OptVarSetErr)])])]
    [(IrBlockArray seq)
      (opt-verify-block-def-set (compiler-ir-block-seq-to-list seq) set)]))

(define (opt-verify-single-defs?
  [params : CompilerIrParamList]
  [blocks : CompilerIrBlockList]) : bool
  (match (opt-verify-param-def-set params (i64-i64-map-with-capacity 64))
    [(OptVarSetErr) false]
    [(OptVarSetOk param-set)
      (match (opt-verify-block-def-set blocks param-set)
        [(OptVarSetOk _) true]
        [(OptVarSetErr) false])]))

(define (opt-var-defs-from-params
  [params : CompilerIrParamList]
  [entry-label : String]
  [defs : OptVarDefList]) : OptVarDefList
  (match params
    [(IrParamNil) defs]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ _ var)
          (opt-var-defs-from-params
            (box-get rest)
            entry-label
            (OptVarDefCons (OptVarDef var entry-label 0) (box defs)))])]))

(define (opt-var-defs-from-instrs
  [instrs : CompilerIrInstrList]
  [block-label : String]
  [pos : i64]
  [defs : OptVarDefList]) : OptVarDefList
  (match instrs
    [(IrInstrNil) defs]
    [(IrInstrCons instr rest)
      (match (opt-instr-def-var instr)
        [(OptSomeI64 var)
          (opt-var-defs-from-instrs
            (box-get rest)
            block-label
            (+ pos 1)
            (OptVarDefCons
              (OptVarDef var block-label (opt-instr-def-position instr pos))
              (box defs)))]
        [(OptNoI64)
          (opt-var-defs-from-instrs (box-get rest) block-label (+ pos 1) defs)])]))

(define (opt-var-defs-from-instr-seq-from
  [instrs : CompilerIrInstrSeq]
  [block-label : String]
  [index : i64]
  [pos : i64]
  [defs : OptVarDefList]) : OptVarDefList
  (if (>= index (compiler-ir-instr-seq-count instrs))
    defs
    (let
      [instr : CompilerIrInstr (compiler-ir-instr-seq-ref instrs index)]
      (match (opt-instr-def-var instr)
        [(OptSomeI64 var)
          (opt-var-defs-from-instr-seq-from
            instrs
            block-label
            (+ index 1)
            (+ pos 1)
            (OptVarDefCons
              (OptVarDef var block-label (opt-instr-def-position instr pos))
              (box defs)))]
        [(OptNoI64)
          (opt-var-defs-from-instr-seq-from
            instrs
            block-label
            (+ index 1)
            (+ pos 1)
            defs)]))))

(define (opt-var-defs-from-blocks
  [blocks : CompilerIrBlockList]
  [defs : OptVarDefList]) : OptVarDefList
  (match blocks
    [(IrBlockNil) defs]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (opt-var-defs-from-blocks
            (box-get rest)
            (opt-var-defs-from-instr-seq-from instrs label 0 1 defs))])]
    [(IrBlockArray seq)
      (opt-var-defs-from-blocks (compiler-ir-block-seq-to-list seq) defs)]))

(define (opt-var-defs-from-function
  [params : CompilerIrParamList]
  [blocks : CompilerIrBlockList]) : OptVarDefList
  (opt-var-defs-from-blocks
    blocks
    (opt-var-defs-from-params
      params
      (opt-cfg-entry-label blocks)
      (OptVarDefNil))))

(define (opt-var-def-lookup [defs : OptVarDefList] [var : i64]) : OptMaybeVarDef
  (match defs
    [(OptVarDefNil) (OptNoVarDef)]
    [(OptVarDefCons def rest)
      (match def
        [(OptVarDef def-var _ _)
          (if (= def-var var)
            (OptSomeVarDef def)
            (opt-var-def-lookup (box-get rest) var))])]))

(define (opt-verify-var-use
  [defs : OptVarDefList]
  [doms : OptDomInfo]
  [var : i64]
  [use-block : String]
  [use-pos : i64]) : ResultCompilerOptimizeVerify
  (match (opt-var-def-lookup defs var)
    [(OptNoVarDef)
      (ErrCompilerOptimizeVerify "optimizer verify: use before definition")]
    [(OptSomeVarDef def)
      (match def
        [(OptVarDef _ def-block def-pos)
          (if (not (opt-dom-dominates? doms def-block use-block))
            (ErrCompilerOptimizeVerify
              "optimizer verify: use is not dominated by definition")
            (if (and (string-eq def-block use-block) (>= def-pos use-pos))
              (ErrCompilerOptimizeVerify
                "optimizer verify: use before definition")
              (OkCompilerOptimizeVerify)))])]))

(define (opt-verify-var-use-on-edge
  [defs : OptVarDefList]
  [doms : OptDomInfo]
  [var : i64]
  [pred-label : String]) : ResultCompilerOptimizeVerify
  (match (opt-var-def-lookup defs var)
    [(OptNoVarDef)
      (ErrCompilerOptimizeVerify "optimizer verify: use before definition")]
    [(OptSomeVarDef def)
      (match def
        [(OptVarDef _ def-block _)
          (if (opt-dom-dominates? doms def-block pred-label)
            (OkCompilerOptimizeVerify)
            (ErrCompilerOptimizeVerify
              "optimizer verify: use is not dominated by definition"))])]))

(define (opt-verify-value-use
  [defs : OptVarDefList]
  [doms : OptDomInfo]
  [value : CompilerIrValue]
  [use-block : String]
  [use-pos : i64]) : ResultCompilerOptimizeVerify
  (match value
    [(IrValueVar var) (opt-verify-var-use defs doms var use-block use-pos)]
    [_ (OkCompilerOptimizeVerify)]))

(define (opt-verify-value-list-uses
  [defs : OptVarDefList]
  [doms : OptDomInfo]
  [values : CompilerIrValueList]
  [use-block : String]
  [use-pos : i64]) : ResultCompilerOptimizeVerify
  (match values
    [(IrValueNil) (OkCompilerOptimizeVerify)]
    [(IrValueCons value rest)
      (match (opt-verify-value-use defs doms value use-block use-pos)
        [(OkCompilerOptimizeVerify)
          (opt-verify-value-list-uses
            defs
            doms
            (box-get rest)
            use-block
            use-pos)]
        [(ErrCompilerOptimizeVerify message)
          (ErrCompilerOptimizeVerify message)])]))

(define (opt-verify-call-args-array-uses
  [defs : OptVarDefList]
  [doms : OptDomInfo]
  [values : (Array CompilerIrValue)]
  [use-block : String]
  [use-pos : i64]
  [index : i64]) : ResultCompilerOptimizeVerify
  (if (>= index (array-length values))
    (OkCompilerOptimizeVerify)
    (match (opt-verify-value-use
      defs
      doms
      (array-ref values index)
      use-block
      use-pos)
      [(OkCompilerOptimizeVerify)
        (opt-verify-call-args-array-uses
          defs
          doms
          values
          use-block
          use-pos
          (+ index 1))]
      [(ErrCompilerOptimizeVerify message) (ErrCompilerOptimizeVerify message)])))

(define (opt-verify-call-args-uses
  [defs : OptVarDefList]
  [doms : OptDomInfo]
  [args : CompilerIrCallArgs]
  [use-block : String]
  [use-pos : i64]) : ResultCompilerOptimizeVerify
  (match args
    [(IrCallArgsNil) (OkCompilerOptimizeVerify)]
    [(IrCallArgsOne value)
      (opt-verify-value-use defs doms value use-block use-pos)]
    [(IrCallArgsTwo a b)
      (opt-verify-two
        (opt-verify-value-use defs doms a use-block use-pos)
        (opt-verify-value-use defs doms b use-block use-pos))]
    [(IrCallArgsArray values)
      (opt-verify-call-args-array-uses defs doms values use-block use-pos 0)]))

(define (opt-verify-maybe-value-use
  [defs : OptVarDefList]
  [doms : OptDomInfo]
  [value : CompilerIrMaybeValue]
  [use-block : String]
  [use-pos : i64]) : ResultCompilerOptimizeVerify
  (match value
    [(IrNoValue) (OkCompilerOptimizeVerify)]
    [(IrSomeValue inner)
      (opt-verify-value-use defs doms inner use-block use-pos)]))

(define (opt-verify-phi-input-uses
  [defs : OptVarDefList]
  [doms : OptDomInfo]
  [inputs : CompilerIrPhiInputList]) : ResultCompilerOptimizeVerify
  (match inputs
    [(IrPhiInputNil) (OkCompilerOptimizeVerify)]
    [(IrPhiInputCons value pred-label rest)
      (match value
        [(IrValueVar var)
          (match (opt-verify-var-use-on-edge defs doms var pred-label)
            [(OkCompilerOptimizeVerify)
              (opt-verify-phi-input-uses defs doms (box-get rest))]
            [(ErrCompilerOptimizeVerify message)
              (ErrCompilerOptimizeVerify message)])]
        [_ (opt-verify-phi-input-uses defs doms (box-get rest))])]))

(define (opt-verify-two
  [a : ResultCompilerOptimizeVerify]
  [b : ResultCompilerOptimizeVerify]) : ResultCompilerOptimizeVerify
  (match a
    [(OkCompilerOptimizeVerify) b]
    [(ErrCompilerOptimizeVerify message) (ErrCompilerOptimizeVerify message)]))

(define (opt-verify-instr-uses
  [defs : OptVarDefList]
  [doms : OptDomInfo]
  [block-label : String]
  [pos : i64]
  [instr : CompilerIrInstr]) : ResultCompilerOptimizeVerify
  (match instr
    [(IrInstrMov _ src _) (opt-verify-value-use defs doms src block-label pos)]
    [(IrInstrAddrOf _ src) (opt-verify-var-use defs doms src block-label pos)]
    [(IrInstrGep _ base offset _)
      (opt-verify-two
        (opt-verify-value-use defs doms base block-label pos)
        (opt-verify-value-use defs doms offset block-label pos))]
    [(IrInstrLoad _ src _) (opt-verify-value-use defs doms src block-label pos)]
    [(IrInstrStorePtr ptr value _)
      (opt-verify-two
        (opt-verify-value-use defs doms ptr block-label pos)
        (opt-verify-value-use defs doms value block-label pos))]
    [(IrInstrCopyBytes dst src _)
      (opt-verify-two
        (opt-verify-value-use defs doms dst block-label pos)
        (opt-verify-value-use defs doms src block-label pos))]
    [(IrInstrBoundsCheck index length _)
      (opt-verify-two
        (opt-verify-value-use defs doms index block-label pos)
        (opt-verify-value-use defs doms length block-label pos))]
    [(IrInstrCast _ src _ _)
      (opt-verify-value-use defs doms src block-label pos)]
    [(IrInstrBinOp _ _ lhs rhs _)
      (opt-verify-two
        (opt-verify-value-use defs doms lhs block-label pos)
        (opt-verify-value-use defs doms rhs block-label pos))]
    [(IrInstrUnOp _ _ src _)
      (opt-verify-value-use defs doms src block-label pos)]
    [(IrInstrSplat _ src _ _)
      (opt-verify-value-use defs doms src block-label pos)]
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (opt-verify-two
        (opt-verify-value-use defs doms lhs block-label pos)
        (opt-verify-value-use defs doms rhs block-label pos))]
    [(IrInstrVectorReduce _ _ src _ _)
      (opt-verify-value-use defs doms src block-label pos)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (opt-verify-two
        (opt-verify-value-use defs doms lhs block-label pos)
        (opt-verify-value-use defs doms rhs block-label pos))]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (opt-verify-two
        (opt-verify-value-use defs doms lhs block-label pos)
        (opt-verify-value-use defs doms rhs block-label pos))]
    [(IrInstrMaskNot _ src _)
      (opt-verify-value-use defs doms src block-label pos)]
    [(IrInstrMaskReduce _ _ src _)
      (opt-verify-value-use defs doms src block-label pos)]
    [(IrInstrSelect _ mask on-true on-false _ _)
      (opt-verify-two
        (opt-verify-value-use defs doms mask block-label pos)
        (opt-verify-two
          (opt-verify-value-use defs doms on-true block-label pos)
          (opt-verify-value-use defs doms on-false block-label pos)))]
    [(IrInstrVectorLoad _ base index _ _)
      (opt-verify-two
        (opt-verify-value-use defs doms base block-label pos)
        (opt-verify-value-use defs doms index block-label pos))]
    [(IrInstrVectorStore base index value _ _)
      (opt-verify-two
        (opt-verify-value-use defs doms base block-label pos)
        (opt-verify-two
          (opt-verify-value-use defs doms index block-label pos)
          (opt-verify-value-use defs doms value block-label pos)))]
    [(IrInstrPredicatedStore base index value mask _ _)
      (opt-verify-two
        (opt-verify-value-use defs doms base block-label pos)
        (opt-verify-two
          (opt-verify-value-use defs doms index block-label pos)
          (opt-verify-two
            (opt-verify-value-use defs doms value block-label pos)
            (opt-verify-value-use defs doms mask block-label pos))))]
    [(IrInstrPredicatedLoad _ base index mask _ _)
      (opt-verify-two
        (opt-verify-value-use defs doms base block-label pos)
        (opt-verify-two
          (opt-verify-value-use defs doms index block-label pos)
          (opt-verify-value-use defs doms mask block-label pos)))]
    [(IrInstrTailMask _ index length _)
      (opt-verify-two
        (opt-verify-value-use defs doms index block-label pos)
        (opt-verify-value-use defs doms length block-label pos))]
    [(IrInstrEntryArgc _) (OkCompilerOptimizeVerify)]
    [(IrInstrEntryArgv _) (OkCompilerOptimizeVerify)]
    [(IrInstrEntryEnvp _) (OkCompilerOptimizeVerify)]
    [(IrInstrCpuId _ leaf subleaf _)
      (opt-verify-two
        (opt-verify-value-use defs doms leaf block-label pos)
        (opt-verify-value-use defs doms subleaf block-label pos))]
    [(IrInstrXgetbv _ index)
      (opt-verify-value-use defs doms index block-label pos)]
    [(IrInstrSyscall _ args)
      (opt-verify-call-args-uses defs doms args block-label pos)]
    [(IrInstrCall _ _ args _)
      (opt-verify-call-args-uses defs doms args block-label pos)]
    [(IrInstrCallIndirect _ func args _)
      (opt-verify-two
        (opt-verify-value-use defs doms func block-label pos)
        (opt-verify-call-args-uses defs doms args block-label pos))]
    [(IrInstrCallIndirectC _ func args _)
      (opt-verify-two
        (opt-verify-value-use defs doms func block-label pos)
        (opt-verify-call-args-uses defs doms args block-label pos))]
    [(IrInstrTailCall _ args _)
      (opt-verify-call-args-uses defs doms args block-label pos)]
    [(IrInstrStore _ value _)
      (opt-verify-value-use defs doms value block-label pos)]
    [(IrInstrBranch cond _ _)
      (opt-verify-value-use defs doms cond block-label pos)]
    [(IrInstrReturn maybe)
      (opt-verify-maybe-value-use defs doms maybe block-label pos)]
    [(IrInstrPhi _ inputs _) (opt-verify-phi-input-uses defs doms inputs)]
    [(IrInstrAlloc _ _) (OkCompilerOptimizeVerify)]
    [(IrInstrLaneId _ _ _) (OkCompilerOptimizeVerify)]
    [(IrInstrJump _) (OkCompilerOptimizeVerify)]
    ;; #2386: verify register-group operands dominate their use.
    [(IrInstrPack _ words _)
      (opt-verify-value-list-uses defs doms words block-label pos)]
    [(IrInstrWord _ src _ _)
      (opt-verify-value-use defs doms src block-label pos)]))

(define (opt-verify-instr-list-uses
  [defs : OptVarDefList]
  [doms : OptDomInfo]
  [block-label : String]
  [instrs : CompilerIrInstrList]
  [pos : i64]) : ResultCompilerOptimizeVerify
  (match instrs
    [(IrInstrNil) (OkCompilerOptimizeVerify)]
    [(IrInstrCons instr rest)
      (match (opt-verify-instr-uses defs doms block-label pos instr)
        [(OkCompilerOptimizeVerify)
          (opt-verify-instr-list-uses
            defs
            doms
            block-label
            (box-get rest)
            (+ pos 1))]
        [(ErrCompilerOptimizeVerify message)
          (ErrCompilerOptimizeVerify message)])]))

(define (opt-verify-instr-seq-uses-from
  [defs : OptVarDefList]
  [doms : OptDomInfo]
  [block-label : String]
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [pos : i64]) : ResultCompilerOptimizeVerify
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (OkCompilerOptimizeVerify)
    (match (opt-verify-instr-uses
      defs
      doms
      block-label
      pos
      (compiler-ir-instr-seq-ref instrs index))
      [(OkCompilerOptimizeVerify)
        (opt-verify-instr-seq-uses-from
          defs
          doms
          block-label
          instrs
          (+ index 1)
          (+ pos 1))]
      [(ErrCompilerOptimizeVerify message) (ErrCompilerOptimizeVerify message)])))

(define (opt-phi-input-labels [inputs : CompilerIrPhiInputList]) : OptLabelSet
  (match inputs
    [(IrPhiInputNil) (OptLabelNil)]
    [(IrPhiInputCons _ label rest)
      (opt-label-add (opt-phi-input-labels (box-get rest)) label)]))

(define (opt-phi-input-labels-unique-from?
  [inputs : CompilerIrPhiInputList]
  [seen : OptLabelSet]) : bool
  (match inputs
    [(IrPhiInputNil) true]
    [(IrPhiInputCons _ label rest)
      (if (opt-label-contains seen label)
        false
        (opt-phi-input-labels-unique-from?
          (box-get rest)
          (opt-label-add seen label)))]))

(define (opt-phi-input-labels-match?
  [inputs : CompilerIrPhiInputList]
  [preds : OptLabelSet]) : bool
  (and
    (opt-phi-input-labels-unique-from? inputs (OptLabelNil))
    (opt-label-set-eq? (opt-phi-input-labels inputs) preds)))

(define (opt-verify-phi-predecessors-instrs
  [pred-map : OptPredMap]
  [block-label : String]
  [instrs : CompilerIrInstrList]) : ResultCompilerOptimizeVerify
  (match instrs
    [(IrInstrNil) (OkCompilerOptimizeVerify)]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrPhi _ inputs _)
          (if (opt-phi-input-labels-match?
            inputs
            (opt-pred-map-lookup pred-map block-label))
            (opt-verify-phi-predecessors-instrs
              pred-map
              block-label
              (box-get rest))
            (ErrCompilerOptimizeVerify
              "optimizer verify: phi predecessor mismatch"))]
        [_
          (opt-verify-phi-predecessors-instrs
            pred-map
            block-label
            (box-get rest))])]))

(define (opt-verify-phi-predecessors-instr-seq-from
  [pred-map : OptPredMap]
  [block-label : String]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : ResultCompilerOptimizeVerify
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (OkCompilerOptimizeVerify)
    (match (compiler-ir-instr-seq-ref instrs index)
      [(IrInstrPhi _ inputs _)
        (if (opt-phi-input-labels-match?
          inputs
          (opt-pred-map-lookup pred-map block-label))
          (opt-verify-phi-predecessors-instr-seq-from
            pred-map
            block-label
            instrs
            (+ index 1))
          (ErrCompilerOptimizeVerify
            "optimizer verify: phi predecessor mismatch"))]
      [_
        (opt-verify-phi-predecessors-instr-seq-from
          pred-map
          block-label
          instrs
          (+ index 1))])))

(define (opt-verify-phi-predecessors-blocks
  [pred-map : OptPredMap]
  [remaining : CompilerIrBlockList]) : ResultCompilerOptimizeVerify
  (match remaining
    [(IrBlockNil) (OkCompilerOptimizeVerify)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (match (opt-verify-phi-predecessors-instr-seq-from
            pred-map
            label
            instrs
            0)
            [(OkCompilerOptimizeVerify)
              (opt-verify-phi-predecessors-blocks pred-map (box-get rest))]
            [(ErrCompilerOptimizeVerify message)
              (ErrCompilerOptimizeVerify message)])])]
    [(IrBlockArray seq)
      (opt-verify-phi-predecessors-blocks
        pred-map
        (compiler-ir-block-seq-to-list seq))]))

(define (opt-verify-block-uses
  [defs : OptVarDefList]
  [doms : OptDomInfo]
  [blocks : CompilerIrBlockList]) : ResultCompilerOptimizeVerify
  (match blocks
    [(IrBlockNil) (OkCompilerOptimizeVerify)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (match (opt-verify-instr-seq-uses-from defs doms label instrs 0 1)
            [(OkCompilerOptimizeVerify)
              (opt-verify-block-uses defs doms (box-get rest))]
            [(ErrCompilerOptimizeVerify message)
              (ErrCompilerOptimizeVerify message)])])]
    [(IrBlockArray seq)
      (opt-verify-block-uses defs doms (compiler-ir-block-seq-to-list seq))]))

(define (opt-verify-function-with-context
  [func : CompilerIrFunction]
  [context : OptCfgContext]) : ResultCompilerOptimizeVerify
  (match func
    [(IrFunction _ params _ _ blocks)
      (core/cond
        (not (opt-cfg-block-labels-unique? blocks))
        (ErrCompilerOptimizeVerify "optimizer verify: duplicate block label")
        (not (opt-cfg-successor-targets-known? blocks))
        (ErrCompilerOptimizeVerify "optimizer verify: unknown successor label")
        (not (opt-verify-single-defs? params blocks))
        (ErrCompilerOptimizeVerify "optimizer verify: duplicate var definition")
        (let
          [doms : OptDomInfo (struct-get context doms)]
          [pred-map : OptPredMap (struct-get context pred-map)]
          [defs : OptVarDefList (opt-var-defs-from-function params blocks)]
          (match (opt-verify-phi-predecessors-blocks pred-map blocks)
            [(OkCompilerOptimizeVerify)
              (opt-verify-block-uses defs doms blocks)]
            [(ErrCompilerOptimizeVerify message)
              (ErrCompilerOptimizeVerify message)])))]))

(define (opt-verify-function [func : CompilerIrFunction]) : ResultCompilerOptimizeVerify
  (match func
    [(IrFunction _ params _ _ blocks)
      (core/cond
        (not (opt-cfg-block-labels-unique? blocks))
        (ErrCompilerOptimizeVerify "optimizer verify: duplicate block label")
        (not (opt-cfg-successor-targets-known? blocks))
        (ErrCompilerOptimizeVerify "optimizer verify: unknown successor label")
        (not (opt-verify-single-defs? params blocks))
        (ErrCompilerOptimizeVerify "optimizer verify: duplicate var definition")
        (opt-verify-function-with-context func (opt-cfg-context-build blocks)))]))

(define (opt-verify-function-list [functions : CompilerIrFunctionList]) : ResultCompilerOptimizeVerify
  (match functions
    [(IrFunctionNil) (OkCompilerOptimizeVerify)]
    [(IrFunctionCons func rest)
      (match (opt-verify-function func)
        [(OkCompilerOptimizeVerify) (opt-verify-function-list (box-get rest))]
        [(ErrCompilerOptimizeVerify message)
          (ErrCompilerOptimizeVerify message)])]))

(define (opt-verify-program [program : CompilerIrProgram]) : ResultCompilerOptimizeVerify
  (match program
    [(IrProgram _ functions _) (opt-verify-function-list functions)]))

;; --- standalone scalar SSA construction / mem2reg (#2188) ------------------
;;
;; This constructor rewrites repeated scalar virtual-register definitions into
;; single-assignment form and inserts phis at dominance frontiers. It is
;; deliberately verifier-gated: unsupported shapes leave the function unchanged.
;; This first slice handles functions without pre-existing phi nodes, which keeps
;; edge-sensitive phi-input rewriting separate from the lowering-time phis.
(defenum OptMaybeAstType
  (OptNoAstType)
  (OptSomeAstType AstType))

(defenum OptSsaVarTypes
  (OptSsaVarTypesNil)
  (OptSsaVarTypesCons i64 AstType (Box OptSsaVarTypes)))

(defenum OptSsaFacts
  (OptSsaFacts I64I64Map I64I64Map OptSsaVarTypes))

(defenum OptSsaVarBlocks
  (OptSsaVarBlocksNil)
  (OptSsaVarBlocksCons i64 OptLabelSet (Box OptSsaVarBlocks)))

(defenum OptSsaPhiSite
  (OptSsaPhiSite i64 String AstType i64))

(defenum OptSsaPhiSites
  (OptSsaPhiSitesNil)
  (OptSsaPhiSitesCons OptSsaPhiSite (Box OptSsaPhiSites)))

(defenum OptSsaPhiInsertState
  (OptSsaPhiInsertState OptSsaPhiSites i64 OptLabelSet))

(defenum OptSsaRenameEnv
  (OptSsaRenameNil)
  (OptSsaRenameCons i64 i64 (Box OptSsaRenameEnv)))

(defenum OptSsaRenameBlock
  (OptSsaRenameBlock String CompilerIrInstrList))

(defenum OptSsaRenameBlocks
  (OptSsaRenameBlocksNil)
  (OptSsaRenameBlocksCons OptSsaRenameBlock (Box OptSsaRenameBlocks)))

(defenum OptSsaBlockOut
  (OptSsaBlockOut String OptSsaRenameEnv))

(defenum OptSsaBlockOuts
  (OptSsaBlockOutsNil)
  (OptSsaBlockOutsCons OptSsaBlockOut (Box OptSsaBlockOuts)))

(defenum OptSsaRenameState
  (OptSsaRenameState OptSsaRenameBlocks OptSsaBlockOuts i64))

(defenum OptSsaDstResult
  (OptSsaDstResult i64 OptSsaRenameEnv i64))

(defenum OptSsaInstrResult
  (OptSsaInstrResult CompilerIrInstr OptSsaRenameEnv i64))

(defenum OptSsaBlockResult
  (OptSsaBlockResult CompilerIrInstrList OptSsaRenameEnv i64))

(define (opt-ssa-count [counts : I64I64Map] [var : i64]) : i64
  (match (i64-i64-map-get counts var)
    [(I64I64MapFound n) n]
    [(I64I64MapMissing) 0]))

(define (opt-ssa-count-add [counts : I64I64Map] [var : i64]) : I64I64Map
  (i64-i64-map-put counts var (+ 1 (opt-ssa-count counts var))))

(define (opt-ssa-scalar-type? [ty : AstType]) : bool
  (match ty
    [(AstTyI64) true]
    [(AstTyI32) true]
    [(AstTyI16) true]
    [(AstTyI8) true]
    [(AstTyU64) true]
    [(AstTyU32) true]
    [(AstTyU16) true]
    [(AstTyU8) true]
    [(AstTyF64) true]
    [(AstTyF32) true]
    [(AstTyBool) true]
    [(AstTyChar) true]
    [(AstTyPtr _) true]
    [(AstTyMutPtr _) true]
    [(AstTyRef _ _) true]
    [(AstTyMutRef _ _) true]
    [_ false]))

(define (opt-ssa-var-type-lookup [types : OptSsaVarTypes] [var : i64]) : OptMaybeAstType
  (match types
    [(OptSsaVarTypesNil) (OptNoAstType)]
    [(OptSsaVarTypesCons id ty rest)
      (if (= id var)
        (OptSomeAstType ty)
        (opt-ssa-var-type-lookup (box-get rest) var))]))

(define (opt-ssa-facts-bad-var [facts : OptSsaFacts] [var : i64]) : OptSsaFacts
  (match facts
    [(OptSsaFacts counts bad types)
      (OptSsaFacts counts (opt-used-add bad var) types)]))

(define (opt-ssa-facts-add-def-bad [facts : OptSsaFacts] [var : i64]) : OptSsaFacts
  (match facts
    [(OptSsaFacts counts bad types)
      (OptSsaFacts (opt-ssa-count-add counts var) (opt-used-add bad var) types)]))

(define (opt-ssa-facts-add-def-ty
  [facts : OptSsaFacts]
  [var : i64]
  [ty : AstType]) : OptSsaFacts
  (match facts
    [(OptSsaFacts counts bad types)
      (let
        [next-counts : I64I64Map (opt-ssa-count-add counts var)]
        (if (not (opt-ssa-scalar-type? ty))
          (OptSsaFacts next-counts (opt-used-add bad var) types)
          (match (opt-ssa-var-type-lookup types var)
            [(OptNoAstType)
              (OptSsaFacts
                next-counts
                bad
                (OptSsaVarTypesCons var ty (box types)))]
            [(OptSomeAstType old)
              (OptSsaFacts
                next-counts
                (if (opt-type-eq old ty)
                  bad
                  (opt-used-add bad var))
                types)])))]))

(define (opt-ssa-facts-add-param
  [facts : OptSsaFacts]
  [param : CompilerIrParam]) : OptSsaFacts
  (match param
    [(IrParam _ ty var) (opt-ssa-facts-add-def-ty facts var ty)]))

(define (opt-ssa-facts-add-params
  [params : CompilerIrParamList]
  [facts : OptSsaFacts]) : OptSsaFacts
  (match params
    [(IrParamNil) facts]
    [(IrParamCons param rest)
      (opt-ssa-facts-add-params
        (box-get rest)
        (opt-ssa-facts-add-param facts param))]))

(define (opt-ssa-facts-add-instr
  [facts : OptSsaFacts]
  [instr : CompilerIrInstr]) : OptSsaFacts
  (match instr
    [(IrInstrMov dst _ ty) (opt-ssa-facts-add-def-ty facts dst ty)]
    [(IrInstrLoad dst _ ty) (opt-ssa-facts-add-def-ty facts dst ty)]
    [(IrInstrCast dst _ _ ty) (opt-ssa-facts-add-def-ty facts dst ty)]
    [(IrInstrBinOp dst _ _ _ ty) (opt-ssa-facts-add-def-ty facts dst ty)]
    [(IrInstrUnOp dst _ _ ty) (opt-ssa-facts-add-def-ty facts dst ty)]
    [(IrInstrCall dst _ _ ty) (opt-ssa-facts-add-def-ty facts dst ty)]
    [(IrInstrCallIndirect dst _ _ ty) (opt-ssa-facts-add-def-ty facts dst ty)]
    [(IrInstrCallIndirectC dst _ _ ty) (opt-ssa-facts-add-def-ty facts dst ty)]
    [(IrInstrPhi dst _ ty) (opt-ssa-facts-add-def-ty facts dst ty)]
    [(IrInstrEntryArgc dst) (opt-ssa-facts-add-def-ty facts dst (AstTyI64))]
    [(IrInstrAddrOf dst src)
      (opt-ssa-facts-bad-var (opt-ssa-facts-add-def-bad facts dst) src)]
    [(IrInstrAlloc dst _) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrGep dst _ _ _) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrLaneId dst _ _) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrSplat dst _ _ _) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrVectorBinOp dst _ _ _ _ _) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrVectorReduce dst _ _ _ _) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrVectorCompare dst _ _ _ _ _) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrMaskBinOp dst _ _ _ _) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrMaskNot dst _ _) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrMaskReduce dst _ _ _) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrSelect dst _ _ _ _ _) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrVectorLoad dst _ _ _ _) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrPredicatedLoad dst _ _ _ _ _)
      (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrTailMask dst _ _ _) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrEntryArgv dst) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrEntryEnvp dst) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrCpuId dst _ _ _) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrXgetbv dst _) (opt-ssa-facts-add-def-bad facts dst)]
    [(IrInstrSyscall dst _) (opt-ssa-facts-add-def-bad facts dst)]
    [_ facts]))

(define (opt-ssa-facts-add-instr-seq-from
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [facts : OptSsaFacts]) : OptSsaFacts
  (if (>= index (compiler-ir-instr-seq-count instrs))
    facts
    (opt-ssa-facts-add-instr-seq-from
      instrs
      (+ index 1)
      (opt-ssa-facts-add-instr facts (compiler-ir-instr-seq-ref instrs index)))))

(define (opt-ssa-facts-add-blocks
  [blocks : CompilerIrBlockList]
  [facts : OptSsaFacts]) : OptSsaFacts
  (match blocks
    [(IrBlockNil) facts]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (opt-ssa-facts-add-blocks
            (box-get rest)
            (opt-ssa-facts-add-instr-seq-from instrs 0 facts))])]
    [(IrBlockArray seq)
      (opt-ssa-facts-add-blocks (compiler-ir-block-seq-to-list seq) facts)]))

(define (opt-ssa-facts-from-function
  [params : CompilerIrParamList]
  [blocks : CompilerIrBlockList]) : OptSsaFacts
  (opt-ssa-facts-add-blocks
    blocks
    (opt-ssa-facts-add-params
      params
      (OptSsaFacts
        (i64-i64-map-with-capacity 64)
        (i64-i64-map-with-capacity 64)
        (OptSsaVarTypesNil)))))

(define (opt-ssa-candidate? [facts : OptSsaFacts] [var : i64]) : bool
  (match facts
    [(OptSsaFacts counts bad types)
      (and
        (> (opt-ssa-count counts var) 1)
        (and
          (not (opt-used-contains bad var))
          (match (opt-ssa-var-type-lookup types var)
            [(OptSomeAstType _) true]
            [(OptNoAstType) false])))]))

(define (opt-ssa-any-candidate-types?
  [facts : OptSsaFacts]
  [types : OptSsaVarTypes]) : bool
  (match types
    [(OptSsaVarTypesNil) false]
    [(OptSsaVarTypesCons var _ rest)
      (if (opt-ssa-candidate? facts var)
        true
        (opt-ssa-any-candidate-types? facts (box-get rest)))]))

(define (opt-ssa-any-candidate? [facts : OptSsaFacts]) : bool
  (match facts
    [(OptSsaFacts _ _ types) (opt-ssa-any-candidate-types? facts types)]))

(define (opt-ssa-var-blocks-add
  [blocks : OptSsaVarBlocks]
  [var : i64]
  [label : String]) : OptSsaVarBlocks
  (match blocks
    [(OptSsaVarBlocksNil)
      (OptSsaVarBlocksCons
        var
        (opt-label-add (OptLabelNil) label)
        (box (OptSsaVarBlocksNil)))]
    [(OptSsaVarBlocksCons id labels rest)
      (if (= id var)
        (OptSsaVarBlocksCons id (opt-label-add labels label) rest)
        (OptSsaVarBlocksCons
          id
          labels
          (box (opt-ssa-var-blocks-add (box-get rest) var label))))]))

(define (opt-ssa-var-blocks-lookup [blocks : OptSsaVarBlocks] [var : i64]) : OptLabelSet
  (match blocks
    [(OptSsaVarBlocksNil) (OptLabelNil)]
    [(OptSsaVarBlocksCons id labels rest)
      (if (= id var)
        labels
        (opt-ssa-var-blocks-lookup (box-get rest) var))]))

(define (opt-ssa-def-blocks-add-param
  [facts : OptSsaFacts]
  [label : String]
  [defs : OptSsaVarBlocks]
  [param : CompilerIrParam]) : OptSsaVarBlocks
  (match param
    [(IrParam _ _ var)
      (if (opt-ssa-candidate? facts var)
        (opt-ssa-var-blocks-add defs var label)
        defs)]))

(define (opt-ssa-def-blocks-add-params
  [facts : OptSsaFacts]
  [label : String]
  [defs : OptSsaVarBlocks]
  [params : CompilerIrParamList]) : OptSsaVarBlocks
  (match params
    [(IrParamNil) defs]
    [(IrParamCons param rest)
      (opt-ssa-def-blocks-add-params
        facts
        label
        (opt-ssa-def-blocks-add-param facts label defs param)
        (box-get rest))]))

(define (opt-ssa-def-blocks-add-instr
  [facts : OptSsaFacts]
  [label : String]
  [defs : OptSsaVarBlocks]
  [instr : CompilerIrInstr]) : OptSsaVarBlocks
  (match (opt-instr-def-var instr)
    [(OptSomeI64 var)
      (if (opt-ssa-candidate? facts var)
        (opt-ssa-var-blocks-add defs var label)
        defs)]
    [(OptNoI64) defs]))

(define (opt-ssa-def-blocks-add-instr-seq-from
  [facts : OptSsaFacts]
  [label : String]
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [defs : OptSsaVarBlocks]) : OptSsaVarBlocks
  (if (>= index (compiler-ir-instr-seq-count instrs))
    defs
    (opt-ssa-def-blocks-add-instr-seq-from
      facts
      label
      instrs
      (+ index 1)
      (opt-ssa-def-blocks-add-instr
        facts
        label
        defs
        (compiler-ir-instr-seq-ref instrs index)))))

(define (opt-ssa-def-blocks-add-blocks
  [facts : OptSsaFacts]
  [blocks : CompilerIrBlockList]
  [defs : OptSsaVarBlocks]) : OptSsaVarBlocks
  (match blocks
    [(IrBlockNil) defs]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (opt-ssa-def-blocks-add-blocks
            facts
            (box-get rest)
            (opt-ssa-def-blocks-add-instr-seq-from facts label instrs 0 defs))])]
    [(IrBlockArray seq)
      (opt-ssa-def-blocks-add-blocks
        facts
        (compiler-ir-block-seq-to-list seq)
        defs)]))

(define (opt-ssa-def-blocks-from-function
  [facts : OptSsaFacts]
  [params : CompilerIrParamList]
  [blocks : CompilerIrBlockList]) : OptSsaVarBlocks
  (opt-ssa-def-blocks-add-blocks
    facts
    blocks
    (opt-ssa-def-blocks-add-params
      facts
      (opt-cfg-entry-label blocks)
      (OptSsaVarBlocksNil)
      params)))

(define (opt-ssa-phi-site-exists?
  [sites : OptSsaPhiSites]
  [var : i64]
  [label : String]) : bool
  (match sites
    [(OptSsaPhiSitesNil) false]
    [(OptSsaPhiSitesCons site rest)
      (match site
        [(OptSsaPhiSite site-var site-label _ _)
          (if (and (= site-var var) (string-eq site-label label))
            true
            (opt-ssa-phi-site-exists? (box-get rest) var label))])]))

(define (opt-ssa-phi-add-site
  [state : OptSsaPhiInsertState]
  [var : i64]
  [ty : AstType]
  [label : String]) : OptSsaPhiInsertState
  (match state
    [(OptSsaPhiInsertState sites next-var worklist)
      (if (opt-ssa-phi-site-exists? sites var label)
        state
        (OptSsaPhiInsertState
          (OptSsaPhiSitesCons (OptSsaPhiSite var label ty next-var) (box sites))
          (+ next-var 1)
          (opt-label-add worklist label)))]))

(define (opt-ssa-phi-add-frontier
  [var : i64]
  [ty : AstType]
  [frontier : OptLabelSet]
  [state : OptSsaPhiInsertState]) : OptSsaPhiInsertState
  (match frontier
    [(OptLabelNil) state]
    [(OptLabelCons label rest)
      (opt-ssa-phi-add-frontier
        var
        ty
        (box-get rest)
        (opt-ssa-phi-add-site state var ty label))]))

(define (opt-ssa-insert-phis-worklist
  [context : OptCfgContext]
  [blocks : CompilerIrBlockList]
  [var : i64]
  [ty : AstType]
  [state : OptSsaPhiInsertState]) : OptSsaPhiInsertState
  (match state
    [(OptSsaPhiInsertState sites next-var worklist)
      (match worklist
        [(OptLabelNil) state]
        [(OptLabelCons label rest)
          (opt-ssa-insert-phis-worklist
            context
            blocks
            var
            ty
            (opt-ssa-phi-add-frontier
              var
              ty
              (opt-cfg-dominance-frontier-with-context blocks context label)
              (OptSsaPhiInsertState sites next-var (box-get rest))))])]))

(define (opt-ssa-insert-phis-for-var
  [context : OptCfgContext]
  [blocks : CompilerIrBlockList]
  [defs : OptSsaVarBlocks]
  [state : OptSsaPhiInsertState]
  [var : i64]
  [ty : AstType]) : OptSsaPhiInsertState
  (match state
    [(OptSsaPhiInsertState sites next-var _)
      (opt-ssa-insert-phis-worklist
        context
        blocks
        var
        ty
        (OptSsaPhiInsertState
          sites
          next-var
          (opt-ssa-var-blocks-lookup defs var)))]))

(define (opt-ssa-insert-phis-types
  [facts : OptSsaFacts]
  [context : OptCfgContext]
  [blocks : CompilerIrBlockList]
  [defs : OptSsaVarBlocks]
  [types : OptSsaVarTypes]
  [state : OptSsaPhiInsertState]) : OptSsaPhiInsertState
  (match types
    [(OptSsaVarTypesNil) state]
    [(OptSsaVarTypesCons var ty rest)
      (opt-ssa-insert-phis-types
        facts
        context
        blocks
        defs
        (box-get rest)
        (if (opt-ssa-candidate? facts var)
          (opt-ssa-insert-phis-for-var context blocks defs state var ty)
          state))]))

(define (opt-ssa-insert-phis
  [facts : OptSsaFacts]
  [context : OptCfgContext]
  [params : CompilerIrParamList]
  [frame : i64]
  [blocks : CompilerIrBlockList]) : OptSsaPhiInsertState
  (match facts
    [(OptSsaFacts _ _ types)
      (opt-ssa-insert-phis-types
        facts
        context
        blocks
        (opt-ssa-def-blocks-from-function facts params blocks)
        types
        (OptSsaPhiInsertState (OptSsaPhiSitesNil) frame (OptLabelNil)))]))

(define (opt-ssa-env-lookup [env : OptSsaRenameEnv] [var : i64]) : OptMaybeI64
  (match env
    [(OptSsaRenameNil) (OptNoI64)]
    [(OptSsaRenameCons original current rest)
      (if (= original var)
        (OptSomeI64 current)
        (opt-ssa-env-lookup (box-get rest) var))]))

(define (opt-ssa-env-bind
  [env : OptSsaRenameEnv]
  [original : i64]
  [current : i64]) : OptSsaRenameEnv
  (OptSsaRenameCons original current (box env)))

(define (opt-ssa-env-from-params
  [facts : OptSsaFacts]
  [params : CompilerIrParamList]
  [env : OptSsaRenameEnv]) : OptSsaRenameEnv
  (match params
    [(IrParamNil) env]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ _ var)
          (opt-ssa-env-from-params
            facts
            (box-get rest)
            (if (opt-ssa-candidate? facts var)
              (opt-ssa-env-bind env var var)
              env))])]))

(define (opt-ssa-env-bind-phis
  [sites : OptSsaPhiSites]
  [label : String]
  [env : OptSsaRenameEnv]) : OptSsaRenameEnv
  (match sites
    [(OptSsaPhiSitesNil) env]
    [(OptSsaPhiSitesCons site rest)
      (match site
        [(OptSsaPhiSite var site-label _ phi-var)
          (opt-ssa-env-bind-phis
            (box-get rest)
            label
            (if (string-eq label site-label)
              (opt-ssa-env-bind env var phi-var)
              env))])]))

(define (opt-ssa-rewrite-value
  [env : OptSsaRenameEnv]
  [value : CompilerIrValue]) : CompilerIrValue
  (match value
    [(IrValueVar var)
      (match (opt-ssa-env-lookup env var)
        [(OptSomeI64 current) (IrValueVar current)]
        [(OptNoI64) value])]
    [_ value]))

(define (opt-ssa-rewrite-maybe-value
  [env : OptSsaRenameEnv]
  [value : CompilerIrMaybeValue]) : CompilerIrMaybeValue
  (match value
    [(IrNoValue) (IrNoValue)]
    [(IrSomeValue inner) (IrSomeValue (opt-ssa-rewrite-value env inner))]))

(define (opt-ssa-rewrite-value-list
  [env : OptSsaRenameEnv]
  [values : CompilerIrValueList]) : CompilerIrValueList
  (match values
    [(IrValueNil) (IrValueNil)]
    [(IrValueCons value rest)
      (compiler-ir-value-cons
        (opt-ssa-rewrite-value env value)
        (opt-ssa-rewrite-value-list env (box-get rest)))]))

(define (opt-ssa-rewrite-call-args-array
  [env : OptSsaRenameEnv]
  [src : (Array CompilerIrValue)]
  [dst : (Array CompilerIrValue)]
  [index : i64]) : unit
  (if (>= index (array-length src))
    unit
    (begin
      (array-set! dst index (opt-ssa-rewrite-value env (array-ref src index)))
      (opt-ssa-rewrite-call-args-array env src dst (+ index 1)))))

(define (opt-ssa-rewrite-call-args
  [env : OptSsaRenameEnv]
  [args : CompilerIrCallArgs]) : CompilerIrCallArgs
  (match args
    [(IrCallArgsNil) (IrCallArgsNil)]
    [(IrCallArgsOne value) (IrCallArgsOne (opt-ssa-rewrite-value env value))]
    [(IrCallArgsTwo a b)
      (IrCallArgsTwo
        (opt-ssa-rewrite-value env a)
        (opt-ssa-rewrite-value env b))]
    [(IrCallArgsArray values)
      (let
        [out : (Array CompilerIrValue)
          (make-array CompilerIrValue (array-length values))]
        (begin
          (opt-ssa-rewrite-call-args-array env values out 0)
          (IrCallArgsArray out)))]))

(define (opt-ssa-rename-dst
  [facts : OptSsaFacts]
  [env : OptSsaRenameEnv]
  [next-var : i64]
  [dst : i64]) : OptSsaDstResult
  (if (opt-ssa-candidate? facts dst)
    (OptSsaDstResult
      next-var
      (opt-ssa-env-bind env dst next-var)
      (+ next-var 1))
    (OptSsaDstResult dst env next-var)))

(define (opt-ssa-rename-instr
  [facts : OptSsaFacts]
  [env : OptSsaRenameEnv]
  [next-var : i64]
  [instr : CompilerIrInstr]) : OptSsaInstrResult
  (match instr
    [(IrInstrMov dst src ty)
      (match (opt-ssa-rename-dst facts env next-var dst)
        [(OptSsaDstResult out-dst next-env out-next)
          (OptSsaInstrResult
            (IrInstrMov out-dst (opt-ssa-rewrite-value env src) ty)
            next-env
            out-next)])]
    [(IrInstrLoad dst src ty)
      (match (opt-ssa-rename-dst facts env next-var dst)
        [(OptSsaDstResult out-dst next-env out-next)
          (OptSsaInstrResult
            (IrInstrLoad out-dst (opt-ssa-rewrite-value env src) ty)
            next-env
            out-next)])]
    [(IrInstrCast dst src from-ty to-ty)
      (match (opt-ssa-rename-dst facts env next-var dst)
        [(OptSsaDstResult out-dst next-env out-next)
          (OptSsaInstrResult
            (IrInstrCast out-dst (opt-ssa-rewrite-value env src) from-ty to-ty)
            next-env
            out-next)])]
    [(IrInstrBinOp dst op lhs rhs ty)
      (match (opt-ssa-rename-dst facts env next-var dst)
        [(OptSsaDstResult out-dst next-env out-next)
          (OptSsaInstrResult
            (IrInstrBinOp
              out-dst
              op
              (opt-ssa-rewrite-value env lhs)
              (opt-ssa-rewrite-value env rhs)
              ty)
            next-env
            out-next)])]
    [(IrInstrUnOp dst op src ty)
      (match (opt-ssa-rename-dst facts env next-var dst)
        [(OptSsaDstResult out-dst next-env out-next)
          (OptSsaInstrResult
            (IrInstrUnOp out-dst op (opt-ssa-rewrite-value env src) ty)
            next-env
            out-next)])]
    [(IrInstrCall dst name args ty)
      (match (opt-ssa-rename-dst facts env next-var dst)
        [(OptSsaDstResult out-dst next-env out-next)
          (OptSsaInstrResult
            (IrInstrCall out-dst name (opt-ssa-rewrite-call-args env args) ty)
            next-env
            out-next)])]
    [(IrInstrCallIndirect dst func args ty)
      (match (opt-ssa-rename-dst facts env next-var dst)
        [(OptSsaDstResult out-dst next-env out-next)
          (OptSsaInstrResult
            (IrInstrCallIndirect
              out-dst
              (opt-ssa-rewrite-value env func)
              (opt-ssa-rewrite-call-args env args)
              ty)
            next-env
            out-next)])]
    [(IrInstrCallIndirectC dst func args ty)
      (match (opt-ssa-rename-dst facts env next-var dst)
        [(OptSsaDstResult out-dst next-env out-next)
          (OptSsaInstrResult
            (IrInstrCallIndirectC
              out-dst
              (opt-ssa-rewrite-value env func)
              (opt-ssa-rewrite-call-args env args)
              ty)
            next-env
            out-next)])]
    [(IrInstrEntryArgc dst)
      (match (opt-ssa-rename-dst facts env next-var dst)
        [(OptSsaDstResult out-dst next-env out-next)
          (OptSsaInstrResult (IrInstrEntryArgc out-dst) next-env out-next)])]
    [(IrInstrGep dst base offset ty)
      (OptSsaInstrResult
        (IrInstrGep
          dst
          (opt-ssa-rewrite-value env base)
          (opt-ssa-rewrite-value env offset)
          ty)
        env
        next-var)]
    [(IrInstrStorePtr ptr value ty)
      (OptSsaInstrResult
        (IrInstrStorePtr
          (opt-ssa-rewrite-value env ptr)
          (opt-ssa-rewrite-value env value)
          ty)
        env
        next-var)]
    [(IrInstrCopyBytes dst src size)
      (OptSsaInstrResult
        (IrInstrCopyBytes
          (opt-ssa-rewrite-value env dst)
          (opt-ssa-rewrite-value env src)
          size)
        env
        next-var)]
    [(IrInstrBoundsCheck index length ok-label)
      (OptSsaInstrResult
        (IrInstrBoundsCheck
          (opt-ssa-rewrite-value env index)
          (opt-ssa-rewrite-value env length)
          ok-label)
        env
        next-var)]
    [(IrInstrSplat dst value lanes ty)
      (OptSsaInstrResult
        (IrInstrSplat dst (opt-ssa-rewrite-value env value) lanes ty)
        env
        next-var)]
    [(IrInstrVectorBinOp dst op lhs rhs lanes ty)
      (OptSsaInstrResult
        (IrInstrVectorBinOp
          dst
          op
          (opt-ssa-rewrite-value env lhs)
          (opt-ssa-rewrite-value env rhs)
          lanes
          ty)
        env
        next-var)]
    [(IrInstrVectorReduce dst op src lanes ty)
      (OptSsaInstrResult
        (IrInstrVectorReduce dst op (opt-ssa-rewrite-value env src) lanes ty)
        env
        next-var)]
    [(IrInstrVectorCompare dst op lhs rhs lanes ty)
      (OptSsaInstrResult
        (IrInstrVectorCompare
          dst
          op
          (opt-ssa-rewrite-value env lhs)
          (opt-ssa-rewrite-value env rhs)
          lanes
          ty)
        env
        next-var)]
    [(IrInstrMaskBinOp dst op lhs rhs lanes)
      (OptSsaInstrResult
        (IrInstrMaskBinOp
          dst
          op
          (opt-ssa-rewrite-value env lhs)
          (opt-ssa-rewrite-value env rhs)
          lanes)
        env
        next-var)]
    [(IrInstrMaskNot dst src lanes)
      (OptSsaInstrResult
        (IrInstrMaskNot dst (opt-ssa-rewrite-value env src) lanes)
        env
        next-var)]
    [(IrInstrMaskReduce dst op src lanes)
      (OptSsaInstrResult
        (IrInstrMaskReduce dst op (opt-ssa-rewrite-value env src) lanes)
        env
        next-var)]
    [(IrInstrSelect dst mask on-true on-false lanes ty)
      (OptSsaInstrResult
        (IrInstrSelect
          dst
          (opt-ssa-rewrite-value env mask)
          (opt-ssa-rewrite-value env on-true)
          (opt-ssa-rewrite-value env on-false)
          lanes
          ty)
        env
        next-var)]
    [(IrInstrVectorLoad dst base index lanes ty)
      (OptSsaInstrResult
        (IrInstrVectorLoad
          dst
          (opt-ssa-rewrite-value env base)
          (opt-ssa-rewrite-value env index)
          lanes
          ty)
        env
        next-var)]
    [(IrInstrVectorStore base index value lanes ty)
      (OptSsaInstrResult
        (IrInstrVectorStore
          (opt-ssa-rewrite-value env base)
          (opt-ssa-rewrite-value env index)
          (opt-ssa-rewrite-value env value)
          lanes
          ty)
        env
        next-var)]
    [(IrInstrPredicatedStore base index value mask lanes ty)
      (OptSsaInstrResult
        (IrInstrPredicatedStore
          (opt-ssa-rewrite-value env base)
          (opt-ssa-rewrite-value env index)
          (opt-ssa-rewrite-value env value)
          (opt-ssa-rewrite-value env mask)
          lanes
          ty)
        env
        next-var)]
    [(IrInstrPredicatedLoad dst base index mask lanes ty)
      (OptSsaInstrResult
        (IrInstrPredicatedLoad
          dst
          (opt-ssa-rewrite-value env base)
          (opt-ssa-rewrite-value env index)
          (opt-ssa-rewrite-value env mask)
          lanes
          ty)
        env
        next-var)]
    [(IrInstrTailMask dst index length lanes)
      (OptSsaInstrResult
        (IrInstrTailMask
          dst
          (opt-ssa-rewrite-value env index)
          (opt-ssa-rewrite-value env length)
          lanes)
        env
        next-var)]
    [(IrInstrCpuId dst leaf subleaf reg-index)
      (OptSsaInstrResult
        (IrInstrCpuId
          dst
          (opt-ssa-rewrite-value env leaf)
          (opt-ssa-rewrite-value env subleaf)
          reg-index)
        env
        next-var)]
    [(IrInstrXgetbv dst index)
      (OptSsaInstrResult
        (IrInstrXgetbv dst (opt-ssa-rewrite-value env index))
        env
        next-var)]
    [(IrInstrSyscall dst args)
      (OptSsaInstrResult
        (IrInstrSyscall dst (opt-ssa-rewrite-call-args env args))
        env
        next-var)]
    [(IrInstrStore name value ty)
      (OptSsaInstrResult
        (IrInstrStore name (opt-ssa-rewrite-value env value) ty)
        env
        next-var)]
    [(IrInstrBranch cond true-label false-label)
      (OptSsaInstrResult
        (IrInstrBranch (opt-ssa-rewrite-value env cond) true-label false-label)
        env
        next-var)]
    [(IrInstrReturn maybe)
      (OptSsaInstrResult
        (IrInstrReturn (opt-ssa-rewrite-maybe-value env maybe))
        env
        next-var)]
    [(IrInstrTailCall name args ty)
      (OptSsaInstrResult
        (IrInstrTailCall name (opt-ssa-rewrite-call-args env args) ty)
        env
        next-var)]
    [(IrInstrAlloc _ _) (OptSsaInstrResult instr env next-var)]
    [(IrInstrAddrOf _ _) (OptSsaInstrResult instr env next-var)]
    [(IrInstrLaneId _ _ _) (OptSsaInstrResult instr env next-var)]
    [(IrInstrEntryArgv _) (OptSsaInstrResult instr env next-var)]
    [(IrInstrEntryEnvp _) (OptSsaInstrResult instr env next-var)]
    [(IrInstrJump _) (OptSsaInstrResult instr env next-var)]
    [(IrInstrPhi _ _ _) (OptSsaInstrResult instr env next-var)]
    ;; #2386: SSA-rename register-group ops -- rewrite operands with the current
    ;; env, then rename the dst.
    [(IrInstrPack dst words ty)
      (match (opt-ssa-rename-dst facts env next-var dst)
        [(OptSsaDstResult out-dst next-env out-next)
          (OptSsaInstrResult
            (IrInstrPack out-dst (opt-ssa-rewrite-value-list env words) ty)
            next-env
            out-next)])]
    [(IrInstrWord dst src index ty)
      (match (opt-ssa-rename-dst facts env next-var dst)
        [(OptSsaDstResult out-dst next-env out-next)
          (OptSsaInstrResult
            (IrInstrWord out-dst (opt-ssa-rewrite-value env src) index ty)
            next-env
            out-next)])]))

(define (opt-ssa-rename-instr-seq-from
  [facts : OptSsaFacts]
  [env : OptSsaRenameEnv]
  [next-var : i64]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : OptSsaBlockResult
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (OptSsaBlockResult (IrInstrNil) env next-var)
    (match (opt-ssa-rename-instr
      facts
      env
      next-var
      (compiler-ir-instr-seq-ref instrs index))
      [(OptSsaInstrResult instr next-env instr-next)
        (match (opt-ssa-rename-instr-seq-from
          facts
          next-env
          instr-next
          instrs
          (+ index 1))
          [(OptSsaBlockResult rest out-env out-next)
            (OptSsaBlockResult
              (compiler-ir-instr-cons instr rest)
              out-env
              out-next)])])))

(define (opt-ssa-rename-blocks-contains?
  [blocks : OptSsaRenameBlocks]
  [label : String]) : bool
  (match blocks
    [(OptSsaRenameBlocksNil) false]
    [(OptSsaRenameBlocksCons block rest)
      (match block
        [(OptSsaRenameBlock block-label _)
          (if (string-eq block-label label)
            true
            (opt-ssa-rename-blocks-contains? (box-get rest) label))])]))

(define (opt-ssa-rename-blocks-lookup
  [blocks : OptSsaRenameBlocks]
  [label : String]) : CompilerIrInstrList
  (match blocks
    [(OptSsaRenameBlocksNil) (IrInstrNil)]
    [(OptSsaRenameBlocksCons block rest)
      (match block
        [(OptSsaRenameBlock block-label instrs)
          (if (string-eq block-label label)
            instrs
            (opt-ssa-rename-blocks-lookup (box-get rest) label))])]))

(define (opt-ssa-block-out-lookup [outs : OptSsaBlockOuts] [label : String]) : OptSsaRenameEnv
  (match outs
    [(OptSsaBlockOutsNil) (OptSsaRenameNil)]
    [(OptSsaBlockOutsCons out rest)
      (match out
        [(OptSsaBlockOut out-label env)
          (if (string-eq out-label label)
            env
            (opt-ssa-block-out-lookup (box-get rest) label))])]))

(define (opt-ssa-rename-state-add-block
  [state : OptSsaRenameState]
  [label : String]
  [instrs : CompilerIrInstrList]
  [env : OptSsaRenameEnv]
  [next-var : i64]) : OptSsaRenameState
  (match state
    [(OptSsaRenameState blocks outs _)
      (OptSsaRenameState
        (OptSsaRenameBlocksCons (OptSsaRenameBlock label instrs) (box blocks))
        (OptSsaBlockOutsCons (OptSsaBlockOut label env) (box outs))
        next-var)]))

(define (opt-ssa-rename-id
  [context : OptCfgContext]
  [blocks : CompilerIrBlockList]
  [facts : OptSsaFacts]
  [sites : OptSsaPhiSites]
  [id : i64]
  [env : OptSsaRenameEnv]
  [state : OptSsaRenameState]) : OptSsaRenameState
  (let
    [index : OptCfgIndex (struct-get context index)]
    [label : String (array-ref (struct-get index labels) id)]
    (match (opt-cfg-find-block blocks label)
      [(OptNoBlock) state]
      [(OptSomeBlock block)
        (match block
          [(IrBlock _ instrs)
            (let
              [entry-env : OptSsaRenameEnv
                (opt-ssa-env-bind-phis sites label env)]
              (match (opt-ssa-rename-instr-seq-from
                facts
                entry-env
                (match state
                  [(OptSsaRenameState _ _ next-var) next-var])
                instrs
                0)
                [(OptSsaBlockResult renamed out-env next-var)
                  (opt-ssa-rename-children
                    context
                    blocks
                    facts
                    sites
                    id
                    out-env
                    (opt-ssa-rename-state-add-block
                      state
                      label
                      renamed
                      out-env
                      next-var)
                    0)]))])])))

(define (opt-ssa-rename-children
  [context : OptCfgContext]
  [blocks : CompilerIrBlockList]
  [facts : OptSsaFacts]
  [sites : OptSsaPhiSites]
  [parent-id : i64]
  [env : OptSsaRenameEnv]
  [state : OptSsaRenameState]
  [child-id : i64]) : OptSsaRenameState
  (let
    [index : OptCfgIndex (struct-get context index)]
    [count : i64 (opt-cfg-index-block-count index)]
    (if (>= child-id count)
      state
      (let
        [idom : (Array i64) (struct-get (struct-get context doms) idom)]
        [next-state : OptSsaRenameState
          (if (and
            (not (= child-id parent-id))
            (and
              (array-ref (struct-get index reachable) child-id)
              (= (array-ref idom child-id) parent-id)))
            (opt-ssa-rename-id context blocks facts sites child-id env state)
            state)]
        (opt-ssa-rename-children
          context
          blocks
          facts
          sites
          parent-id
          env
          next-state
          (+ child-id 1))))))

(define (opt-ssa-rename-missing-blocks
  [blocks : CompilerIrBlockList]
  [facts : OptSsaFacts]
  [sites : OptSsaPhiSites]
  [initial-env : OptSsaRenameEnv]
  [state : OptSsaRenameState]) : OptSsaRenameState
  (match blocks
    [(IrBlockNil) state]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (let
            [next-state : OptSsaRenameState
              (match state
                [(OptSsaRenameState renamed _ next-var)
                  (if (opt-ssa-rename-blocks-contains? renamed label)
                    state
                    (match (opt-ssa-rename-instr-seq-from
                      facts
                      (opt-ssa-env-bind-phis sites label initial-env)
                      next-var
                      instrs
                      0)
                      [(OptSsaBlockResult out out-env out-next)
                        (opt-ssa-rename-state-add-block
                          state
                          label
                          out
                          out-env
                          out-next)]))])]
            (opt-ssa-rename-missing-blocks
              (box-get rest)
              facts
              sites
              initial-env
              next-state))])]
    [(IrBlockArray seq)
      (opt-ssa-rename-missing-blocks
        (compiler-ir-block-seq-to-list seq)
        facts
        sites
        initial-env
        state)]))

(define (opt-ssa-rename-function-blocks
  [context : OptCfgContext]
  [params : CompilerIrParamList]
  [facts : OptSsaFacts]
  [sites : OptSsaPhiSites]
  [frame : i64]
  [blocks : CompilerIrBlockList]) : OptSsaRenameState
  (let
    [initial-env : OptSsaRenameEnv
      (opt-ssa-env-from-params facts params (OptSsaRenameNil))]
    [entry-label : String (opt-cfg-entry-label blocks)]
    (match (opt-cfg-index-id (struct-get context index) entry-label)
      [(OptSomeI64 entry-id)
        (opt-ssa-rename-missing-blocks
          blocks
          facts
          sites
          initial-env
          (opt-ssa-rename-id
            context
            blocks
            facts
            sites
            entry-id
            initial-env
            (OptSsaRenameState
              (OptSsaRenameBlocksNil)
              (OptSsaBlockOutsNil)
              frame)))]
      [(OptNoI64)
        (OptSsaRenameState (OptSsaRenameBlocksNil) (OptSsaBlockOutsNil) frame)])))

(define (opt-ssa-phi-inputs
  [preds : OptLabelSet]
  [outs : OptSsaBlockOuts]
  [var : i64]) : CompilerIrPhiInputList
  (match preds
    [(OptLabelNil) (IrPhiInputNil)]
    [(OptLabelCons pred rest)
      (let
        [env : OptSsaRenameEnv (opt-ssa-block-out-lookup outs pred)]
        [value : CompilerIrValue
          (match (opt-ssa-env-lookup env var)
            [(OptSomeI64 current) (IrValueVar current)]
            [(OptNoI64) (IrValueVar var)])]
        (compiler-ir-phi-input-cons
          value
          pred
          (opt-ssa-phi-inputs (box-get rest) outs var)))]))

(define (opt-ssa-phis-for-label
  [pred-map : OptPredMap]
  [outs : OptSsaBlockOuts]
  [sites : OptSsaPhiSites]
  [label : String]) : CompilerIrInstrList
  (match sites
    [(OptSsaPhiSitesNil) (IrInstrNil)]
    [(OptSsaPhiSitesCons site rest)
      (let
        [tail : CompilerIrInstrList
          (opt-ssa-phis-for-label pred-map outs (box-get rest) label)]
        (match site
          [(OptSsaPhiSite var site-label ty phi-var)
            (if (string-eq site-label label)
              (compiler-ir-instr-cons
                (IrInstrPhi
                  phi-var
                  (opt-ssa-phi-inputs
                    (opt-pred-map-lookup pred-map label)
                    outs
                    var)
                  ty)
                tail)
              tail)]))]))

(define (opt-ssa-materialize-blocks
  [blocks : CompilerIrBlockList]
  [pred-map : OptPredMap]
  [renamed : OptSsaRenameBlocks]
  [outs : OptSsaBlockOuts]
  [sites : OptSsaPhiSites]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _)
          (let
            [phis : CompilerIrInstrList
              (opt-ssa-phis-for-label pred-map outs sites label)]
            [body : CompilerIrInstrList
              (opt-ssa-rename-blocks-lookup renamed label)]
            (compiler-ir-block-cons
              (compiler-ir-block
                label
                (opt-aggregate-instr-list-append phis body))
              (opt-ssa-materialize-blocks
                (box-get rest)
                pred-map
                renamed
                outs
                sites)))])]
    [(IrBlockArray seq)
      (opt-ssa-materialize-blocks
        (compiler-ir-block-seq-to-list seq)
        pred-map
        renamed
        outs
        sites)]))

(define (opt-ssa-instr-seq-has-phi? [instrs : CompilerIrInstrSeq] [index : i64]) : bool
  (if (>= index (compiler-ir-instr-seq-count instrs))
    false
    (match (compiler-ir-instr-seq-ref instrs index)
      [(IrInstrPhi _ _ _) true]
      [_ (opt-ssa-instr-seq-has-phi? instrs (+ index 1))])))

(define (opt-ssa-blocks-have-phi? [blocks : CompilerIrBlockList]) : bool
  (match blocks
    [(IrBlockNil) false]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (if (opt-ssa-instr-seq-has-phi? instrs 0)
            true
            (opt-ssa-blocks-have-phi? (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-ssa-blocks-have-phi? (compiler-ir-block-seq-to-list seq))]))

(define (opt-ssa-construct-checked
  [fallback : CompilerIrFunction]
  [next : CompilerIrFunction]) : CompilerIrFunction
  (match (opt-verify-function next)
    [(OkCompilerOptimizeVerify) next]
    [(ErrCompilerOptimizeVerify _) fallback]))

(define (opt-ssa-construct-materialized
  [fallback : CompilerIrFunction]
  [name : String]
  [params : CompilerIrParamList]
  [ret-ty : AstType]
  [blocks : CompilerIrBlockList]
  [context : OptCfgContext]
  [sites : OptSsaPhiSites]
  [state : OptSsaRenameState]) : CompilerIrFunction
  (match state
    [(OptSsaRenameState renamed outs next-frame)
      (opt-ssa-construct-checked
        fallback
        (IrFunction
          name
          params
          ret-ty
          next-frame
          (opt-ssa-materialize-blocks
            blocks
            (struct-get context pred-map)
            renamed
            outs
            sites)))]))

(define (opt-ssa-construct-function [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(IrFunction name params ret-ty frame blocks)
      (core/cond
        (opt-verify-single-defs? params blocks)
        func
        ;; Existing phi nodes have edge-local inputs that must be renamed
        ;; together with their predecessor edges. Leave them unchanged until
        ;; that rewrite is supported, keeping pipeline use verifier-safe.
        (opt-ssa-blocks-have-phi? blocks)
        func
        (let
          [facts : OptSsaFacts (opt-ssa-facts-from-function params blocks)]
          (if (not (opt-ssa-any-candidate? facts))
            func
            (let
              [context : OptCfgContext (opt-cfg-context-build blocks)]
              [phi-state : OptSsaPhiInsertState
                (opt-ssa-insert-phis facts context params frame blocks)]
              (match phi-state
                [(OptSsaPhiInsertState sites phi-next _)
                  (opt-ssa-construct-materialized
                    func
                    name
                    params
                    ret-ty
                    blocks
                    context
                    sites
                    (opt-ssa-rename-function-blocks
                      context
                      params
                      facts
                      sites
                      phi-next
                      blocks))])))))]))

;; --- conservative global value numbering / cross-block copies (#1349) -------
;;
;; This pass is deliberately SSA-gated. If the function verifier cannot prove
;; single definitions and dominance for every use, the pass leaves the function
;; unchanged and the existing block-local optimizer still runs. For verified
;; functions, a copy/expression fact is available only in the defining block
;; after the defining instruction, or in a block dominated by the definition's
;; block. Phi inputs are edge uses and are intentionally not rewritten.
(defenum OptGlobalExprKey
  (OptGlobalMovKey CompilerIrValue AstType)
  (OptGlobalGepKey CompilerIrValue CompilerIrValue AstType)
  (OptGlobalCastKey CompilerIrValue AstType AstType)
  (OptGlobalBinKey CompilerIrBinOp CompilerIrValue CompilerIrValue AstType)
  (OptGlobalUnKey CompilerIrUnOp CompilerIrValue AstType))

(defenum OptMaybeGlobalExprKey
  (OptNoGlobalExprKey)
  (OptSomeGlobalExprKey OptGlobalExprKey))

(defenum OptGlobalExprFact
  (OptGlobalExprFact OptGlobalExprKey i64 i64 i64))

(defenum OptGlobalExprFacts
  (OptGlobalExprNil)
  (OptGlobalExprCons OptGlobalExprFact (Box OptGlobalExprFacts)))

(defstruct OptGlobalExprFactTable
  (buckets (Array OptGlobalExprFacts)))

(defenum OptGlobalCopyFact
  (OptGlobalCopyFact i64 CompilerIrValue i64 i64))

(defenum OptGlobalCopyFacts
  (OptGlobalCopyNil)
  (OptGlobalCopyCons OptGlobalCopyFact (Box OptGlobalCopyFacts)))

(defstruct OptGlobalCopyFactTable
  (buckets (Array OptGlobalCopyFacts)))

(define (opt-global-expr-key-eq [a : OptGlobalExprKey] [b : OptGlobalExprKey]) : bool
  (match a
    [(OptGlobalMovKey av aty)
      (match b
        [(OptGlobalMovKey bv bty)
          (and (opt-value-eq av bv) (opt-type-eq aty bty))]
        [_ false])]
    [(OptGlobalGepKey abase aoff aty)
      (match b
        [(OptGlobalGepKey bbase boff bty)
          (and
            (opt-value-eq abase bbase)
            (and (opt-value-eq aoff boff) (opt-type-eq aty bty)))]
        [_ false])]
    [(OptGlobalCastKey av afrom ato)
      (match b
        [(OptGlobalCastKey bv bfrom bto)
          (and
            (opt-value-eq av bv)
            (and (opt-type-eq afrom bfrom) (opt-type-eq ato bto)))]
        [_ false])]
    [(OptGlobalBinKey aop al ar aty)
      (match b
        [(OptGlobalBinKey bop bl br bty)
          (and
            (opt-binop-eq aop bop)
            (and
              (opt-value-eq al bl)
              (and (opt-value-eq ar br) (opt-type-eq aty bty))))]
        [_ false])]
    [(OptGlobalUnKey aop av aty)
      (match b
        [(OptGlobalUnKey bop bv bty)
          (and
            (opt-unop-eq aop bop)
            (and (opt-value-eq av bv) (opt-type-eq aty bty)))]
        [_ false])]))

(define (opt-global-expr-key-hash [key : OptGlobalExprKey]) : i64
  (match key
    [(OptGlobalMovKey value ty)
      (hash-combine 1 (hash-combine (opt-value-hash value) (opt-type-hash ty)))]
    [(OptGlobalGepKey base offset ty)
      (hash-combine
        2
        (hash-combine
          (opt-value-hash base)
          (hash-combine (opt-value-hash offset) (opt-type-hash ty))))]
    [(OptGlobalCastKey value from-ty to-ty)
      (hash-combine
        3
        (hash-combine
          (opt-value-hash value)
          (hash-combine (opt-type-hash from-ty) (opt-type-hash to-ty))))]
    [(OptGlobalBinKey op lhs rhs ty)
      (hash-combine
        4
        (hash-combine
          (hash-i64 (opt-binop-tag op))
          (hash-combine
            (opt-value-hash lhs)
            (hash-combine (opt-value-hash rhs) (opt-type-hash ty)))))]
    [(OptGlobalUnKey op value ty)
      (hash-combine
        5
        (hash-combine
          (hash-i64 (opt-unop-tag op))
          (hash-combine (opt-value-hash value) (opt-type-hash ty))))]))

(define (opt-global-key-for-instr [instr : CompilerIrInstr]) : OptMaybeGlobalExprKey
  (match instr
    [(IrInstrMov _ src ty)
      (if (opt-copy-safe-source? src)
        (OptSomeGlobalExprKey (OptGlobalMovKey src ty))
        (OptNoGlobalExprKey))]
    [(IrInstrGep _ base offset ty)
      (OptSomeGlobalExprKey (OptGlobalGepKey base offset ty))]
    [(IrInstrCast _ src from-ty to-ty)
      (OptSomeGlobalExprKey (OptGlobalCastKey src from-ty to-ty))]
    [(IrInstrBinOp _ op lhs rhs ty)
      (OptSomeGlobalExprKey (OptGlobalBinKey op lhs rhs ty))]
    [(IrInstrUnOp _ op src ty)
      (OptSomeGlobalExprKey (OptGlobalUnKey op src ty))]
    [_ (OptNoGlobalExprKey)]))

(define (opt-global-fact-available?
  [def-block-id : i64]
  [def-pos : i64]
  [use-block-id : i64]
  [use-pos : i64]
  [doms : OptDomInfo]) : bool
  (if (= def-block-id use-block-id)
    (< def-pos use-pos)
    (opt-dom-info-dominates-id? doms def-block-id use-block-id)))

(define (opt-global-block-id [doms : OptDomInfo] [label : String]) : i64
  (match (opt-cfg-index-id (struct-get doms index) label)
    [(OptSomeI64 id) id]
    [(OptNoI64) (- 0 1)]))

(define (opt-global-copy-facts-from-instrs
  [block-id : i64]
  [pos : i64]
  [instrs : CompilerIrInstrList]
  [tail : OptGlobalCopyFacts]) : OptGlobalCopyFacts
  (match instrs
    [(IrInstrNil) tail]
    [(IrInstrCons instr rest)
      (let
        [rest-facts : OptGlobalCopyFacts
          (opt-global-copy-facts-from-instrs
            block-id
            (+ pos 1)
            (box-get rest)
            tail)]
        (match instr
          [(IrInstrMov dst src _)
            (if (and
              (opt-copy-safe-source? src)
              (not (opt-value-is-var? src dst)))
              (OptGlobalCopyCons
                (OptGlobalCopyFact dst src block-id pos)
                (box rest-facts))
              rest-facts)]
          [_ rest-facts]))]))

(define (opt-global-copy-facts-from-instr-seq-from
  [block-id : i64]
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [tail : OptGlobalCopyFacts]) : OptGlobalCopyFacts
  (if (< index 0)
    tail
    (let
      [instr : CompilerIrInstr (array-ref slots index)]
      [rest-facts : OptGlobalCopyFacts tail]
      [next-tail : OptGlobalCopyFacts
        (match instr
          [(IrInstrMov dst src _)
            (if (and
              (opt-copy-safe-source? src)
              (not (opt-value-is-var? src dst)))
              (OptGlobalCopyCons
                (OptGlobalCopyFact dst src block-id (+ index 1))
                (box rest-facts))
              rest-facts)]
          [_ rest-facts])]
      (opt-global-copy-facts-from-instr-seq-from
        block-id
        slots
        (- index 1)
        next-tail))))

(define (opt-global-copy-facts-from-instr-seq
  [block-id : i64]
  [instrs : CompilerIrInstrSeq]
  [tail : OptGlobalCopyFacts]) : OptGlobalCopyFacts
  (opt-global-copy-facts-from-instr-seq-from
    block-id
    (struct-get instrs slots)
    (- (struct-get instrs len) 1)
    tail))

(define (opt-global-copy-facts-from-blocks
  [doms : OptDomInfo]
  [blocks : CompilerIrBlockList]
  [tail : OptGlobalCopyFacts]) : OptGlobalCopyFacts
  (match blocks
    [(IrBlockNil) tail]
    [(IrBlockCons block rest)
      (let
        [rest-facts : OptGlobalCopyFacts
          (opt-global-copy-facts-from-blocks doms (box-get rest) tail)]
        (match block
          [(IrBlock label instrs)
            (opt-global-copy-facts-from-instr-seq
              (opt-global-block-id doms label)
              instrs
              rest-facts)]))]
    [(IrBlockArray seq)
      (opt-global-copy-facts-from-blocks
        doms
        (compiler-ir-block-seq-to-list seq)
        tail)]))

(define (opt-global-copy-facts-max-dst
  [facts : OptGlobalCopyFacts]
  [max-dst : i64]) : i64
  (match facts
    [(OptGlobalCopyNil) max-dst]
    [(OptGlobalCopyCons fact rest)
      (match fact
        [(OptGlobalCopyFact dst _ _ _)
          (opt-global-copy-facts-max-dst
            (box-get rest)
            (if (> dst max-dst)
              dst
              max-dst))])]))

(define (opt-global-copy-buckets-fill-empty!
  [buckets : (Array OptGlobalCopyFacts)]
  [index : i64]) : unit
  (if (>= index (array-length buckets))
    unit
    (begin
      (array-set! buckets index (OptGlobalCopyNil))
      (opt-global-copy-buckets-fill-empty! buckets (+ index 1)))))

(define (opt-global-copy-table-insert!
  [table : OptGlobalCopyFactTable]
  [fact : OptGlobalCopyFact]) : unit
  (match fact
    [(OptGlobalCopyFact dst _ _ _)
      (let
        [buckets : (Array OptGlobalCopyFacts) (struct-get table buckets)]
        (if (and (>= dst 0) (< dst (array-length buckets)))
          (array-set!
            buckets
            dst
            (OptGlobalCopyCons fact (box (array-ref buckets dst))))
          unit))]))

(define (opt-global-copy-table-insert-reversed!
  [table : OptGlobalCopyFactTable]
  [facts : OptGlobalCopyFacts]) : unit
  (match facts
    [(OptGlobalCopyNil) unit]
    [(OptGlobalCopyCons fact rest)
      (begin
        (opt-global-copy-table-insert-reversed! table (box-get rest))
        (opt-global-copy-table-insert! table fact))]))

(define (opt-global-copy-table-from-facts [facts : OptGlobalCopyFacts]) : OptGlobalCopyFactTable
  (let
    [max-dst : i64 (opt-global-copy-facts-max-dst facts (- 0 1))]
    [capacity : i64
      (if (< max-dst 0)
        1
        (+ max-dst 1))]
    [buckets : (Array OptGlobalCopyFacts)
      (make-array OptGlobalCopyFacts capacity)]
    [table : OptGlobalCopyFactTable (OptGlobalCopyFactTable buckets)]
    (begin
      (opt-global-copy-buckets-fill-empty! buckets 0)
      (opt-global-copy-table-insert-reversed! table facts)
      table)))

(define (opt-global-copy-lookup-list
  [facts : OptGlobalCopyFacts]
  [var : i64]
  [doms : OptDomInfo]
  [use-block-id : i64]
  [use-pos : i64]) : CompilerIrMaybeValue
  (match facts
    [(OptGlobalCopyNil) (IrNoValue)]
    [(OptGlobalCopyCons fact rest)
      (match fact
        [(OptGlobalCopyFact dst src def-block-id def-pos)
          (if (and
            (= dst var)
            (opt-global-fact-available?
              def-block-id
              def-pos
              use-block-id
              use-pos
              doms))
            (IrSomeValue src)
            (opt-global-copy-lookup-list
              (box-get rest)
              var
              doms
              use-block-id
              use-pos))])]))

(define (opt-global-copy-lookup
  [table : OptGlobalCopyFactTable]
  [var : i64]
  [doms : OptDomInfo]
  [use-block-id : i64]
  [use-pos : i64]) : CompilerIrMaybeValue
  (let
    [buckets : (Array OptGlobalCopyFacts) (struct-get table buckets)]
    (if (and (>= var 0) (< var (array-length buckets)))
      (opt-global-copy-lookup-list
        (array-ref buckets var)
        var
        doms
        use-block-id
        use-pos)
      (IrNoValue))))

(define (opt-global-copy-resolve-depth
  [facts : OptGlobalCopyFactTable]
  [doms : OptDomInfo]
  [use-block-id : i64]
  [use-pos : i64]
  [value : CompilerIrValue]
  [remaining : i64]) : CompilerIrValue
  (if (<= remaining 0)
    value
    (match value
      [(IrValueVar id)
        (match (opt-global-copy-lookup facts id doms use-block-id use-pos)
          [(IrSomeValue replacement)
            (opt-global-copy-resolve-depth
              facts
              doms
              use-block-id
              use-pos
              replacement
              (- remaining 1))]
          [(IrNoValue) value])]
      [_ value])))

(define (opt-global-copy-resolve
  [facts : OptGlobalCopyFactTable]
  [doms : OptDomInfo]
  [use-block-id : i64]
  [use-pos : i64]
  [value : CompilerIrValue]) : CompilerIrValue
  (opt-global-copy-resolve-depth facts doms use-block-id use-pos value 8))

(define (opt-global-copy-subst-value-list
  [facts : OptGlobalCopyFactTable]
  [doms : OptDomInfo]
  [use-block-id : i64]
  [use-pos : i64]
  [values : CompilerIrValueList]) : CompilerIrValueList
  (match values
    [(IrValueNil) (IrValueNil)]
    [(IrValueCons value rest)
      (compiler-ir-value-cons
        (opt-global-copy-resolve facts doms use-block-id use-pos value)
        (opt-global-copy-subst-value-list
          facts
          doms
          use-block-id
          use-pos
          (box-get rest)))]))

(define (opt-global-copy-subst-call-args-array
  [facts : OptGlobalCopyFactTable]
  [doms : OptDomInfo]
  [use-block-id : i64]
  [use-pos : i64]
  [src : (Array CompilerIrValue)]
  [dst : (Array CompilerIrValue)]
  [index : i64]) : unit
  (if (>= index (array-length src))
    unit
    (begin
      (array-set!
        dst
        index
        (opt-global-copy-resolve
          facts
          doms
          use-block-id
          use-pos
          (array-ref src index)))
      (opt-global-copy-subst-call-args-array
        facts
        doms
        use-block-id
        use-pos
        src
        dst
        (+ index 1)))))

(define (opt-global-copy-subst-call-args
  [facts : OptGlobalCopyFactTable]
  [doms : OptDomInfo]
  [use-block-id : i64]
  [use-pos : i64]
  [args : CompilerIrCallArgs]) : CompilerIrCallArgs
  (match args
    [(IrCallArgsNil) (IrCallArgsNil)]
    [(IrCallArgsOne value)
      (IrCallArgsOne
        (opt-global-copy-resolve facts doms use-block-id use-pos value))]
    [(IrCallArgsTwo a b)
      (IrCallArgsTwo
        (opt-global-copy-resolve facts doms use-block-id use-pos a)
        (opt-global-copy-resolve facts doms use-block-id use-pos b))]
    [(IrCallArgsArray values)
      (let
        [out : (Array CompilerIrValue)
          (make-array CompilerIrValue (array-length values))]
        (begin
          (opt-global-copy-subst-call-args-array
            facts
            doms
            use-block-id
            use-pos
            values
            out
            0)
          (IrCallArgsArray out)))]))

(define (opt-global-copy-subst-instr
  [facts : OptGlobalCopyFactTable]
  [doms : OptDomInfo]
  [block-id : i64]
  [pos : i64]
  [instr : CompilerIrInstr]) : CompilerIrInstr
  (match instr
    [(IrInstrMov dst src ty)
      (IrInstrMov dst (opt-global-copy-resolve facts doms block-id pos src) ty)]
    [(IrInstrGep dst base offset ty)
      (IrInstrGep
        dst
        (opt-global-copy-resolve facts doms block-id pos base)
        (opt-global-copy-resolve facts doms block-id pos offset)
        ty)]
    [(IrInstrLoad dst src ty)
      (IrInstrLoad dst (opt-global-copy-resolve facts doms block-id pos src) ty)]
    [(IrInstrStorePtr ptr value ty)
      (IrInstrStorePtr
        (opt-global-copy-resolve facts doms block-id pos ptr)
        (opt-global-copy-resolve facts doms block-id pos value)
        ty)]
    [(IrInstrCopyBytes dst src size)
      (IrInstrCopyBytes
        (opt-global-copy-resolve facts doms block-id pos dst)
        (opt-global-copy-resolve facts doms block-id pos src)
        size)]
    [(IrInstrBoundsCheck index length ok-label)
      (IrInstrBoundsCheck
        (opt-global-copy-resolve facts doms block-id pos index)
        (opt-global-copy-resolve facts doms block-id pos length)
        ok-label)]
    [(IrInstrCast dst src from-ty to-ty)
      (IrInstrCast
        dst
        (opt-global-copy-resolve facts doms block-id pos src)
        from-ty
        to-ty)]
    [(IrInstrBinOp dst op lhs rhs ty)
      (IrInstrBinOp
        dst
        op
        (opt-global-copy-resolve facts doms block-id pos lhs)
        (opt-global-copy-resolve facts doms block-id pos rhs)
        ty)]
    [(IrInstrUnOp dst op src ty)
      (IrInstrUnOp
        dst
        op
        (opt-global-copy-resolve facts doms block-id pos src)
        ty)]
    [(IrInstrSplat dst src lanes ty)
      (IrInstrSplat
        dst
        (opt-global-copy-resolve facts doms block-id pos src)
        lanes
        ty)]
    [(IrInstrCall dst name args ty)
      (IrInstrCall
        dst
        name
        (opt-global-copy-subst-call-args facts doms block-id pos args)
        ty)]
    [(IrInstrCallIndirect dst func args ty)
      (IrInstrCallIndirect
        dst
        (opt-global-copy-resolve facts doms block-id pos func)
        (opt-global-copy-subst-call-args facts doms block-id pos args)
        ty)]
    [(IrInstrCallIndirectC dst func args ty)
      (IrInstrCallIndirectC
        dst
        (opt-global-copy-resolve facts doms block-id pos func)
        (opt-global-copy-subst-call-args facts doms block-id pos args)
        ty)]
    [(IrInstrTailCall name args ty)
      (IrInstrTailCall
        name
        (opt-global-copy-subst-call-args facts doms block-id pos args)
        ty)]
    [(IrInstrStore name value ty)
      (IrInstrStore
        name
        (opt-global-copy-resolve facts doms block-id pos value)
        ty)]
    [(IrInstrBranch cond true-label false-label)
      (IrInstrBranch
        (opt-global-copy-resolve facts doms block-id pos cond)
        true-label
        false-label)]
    [(IrInstrReturn maybe)
      (match maybe
        [(IrSomeValue value)
          (IrInstrReturn
            (IrSomeValue
              (opt-global-copy-resolve facts doms block-id pos value)))]
        [(IrNoValue) instr])]
    [(IrInstrEntryArgc _) instr]
    [(IrInstrEntryArgv _) instr]
    [(IrInstrEntryEnvp _) instr]
    [(IrInstrCpuId dst leaf subleaf reg-index)
      (IrInstrCpuId
        dst
        (opt-global-copy-resolve facts doms block-id pos leaf)
        (opt-global-copy-resolve facts doms block-id pos subleaf)
        reg-index)]
    [(IrInstrXgetbv dst index)
      (IrInstrXgetbv
        dst
        (opt-global-copy-resolve facts doms block-id pos index))]
    [(IrInstrSyscall dst args)
      (IrInstrSyscall
        dst
        (opt-global-copy-subst-call-args facts doms block-id pos args))]
    [(IrInstrVectorBinOp _ _ _ _ _ _) instr]
    [(IrInstrVectorReduce _ _ _ _ _) instr]
    [(IrInstrVectorCompare _ _ _ _ _ _) instr]
    [(IrInstrMaskBinOp _ _ _ _ _) instr]
    [(IrInstrMaskNot _ _ _) instr]
    [(IrInstrMaskReduce _ _ _ _) instr]
    [(IrInstrSelect _ _ _ _ _ _) instr]
    [(IrInstrVectorLoad _ _ _ _ _) instr]
    [(IrInstrVectorStore _ _ _ _ _) instr]
    [(IrInstrPredicatedStore _ _ _ _ _ _) instr]
    [(IrInstrPredicatedLoad _ _ _ _ _ _) instr]
    [(IrInstrTailMask _ _ _ _) instr]
    [(IrInstrAddrOf _ _) instr]
    [(IrInstrAlloc _ _) instr]
    [(IrInstrLaneId _ _ _) instr]
    [(IrInstrJump _) instr]
    [(IrInstrPhi _ _ _) instr]
    ;; #2386: leave register-group ops un-substituted here; not propagating a
    ;; global copy into their operands is always sound (original vars stay valid).
    [(IrInstrPack _ _ _) instr]
    [(IrInstrWord _ _ _ _) instr]))

(define (opt-global-copy-instrs
  [facts : OptGlobalCopyFactTable]
  [doms : OptDomInfo]
  [block-id : i64]
  [pos : i64]
  [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (compiler-ir-instr-cons
        (opt-global-copy-subst-instr facts doms block-id pos instr)
        (opt-global-copy-instrs facts doms block-id (+ pos 1) (box-get rest)))]))

(define (opt-global-copy-instr-seq
  [facts : OptGlobalCopyFactTable]
  [doms : OptDomInfo]
  [block-label : String]
  [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [index : i64 (- (struct-get instrs len) 1)]
    [block-id : i64 (opt-global-block-id doms block-label)]
    [out : CompilerIrInstrList (IrInstrNil)]
    (begin
      (while (>= index 0)
        (begin
          (set!
            out
            (compiler-ir-instr-cons
              (opt-global-copy-subst-instr
                facts
                doms
                block-id
                (+ index 1)
                (array-ref slots index))
              out))
          (set! index (- index 1))))
      out)))

(define (opt-global-copy-blocks
  [facts : OptGlobalCopyFactTable]
  [doms : OptDomInfo]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (compiler-ir-block-cons
            (compiler-ir-block
              label
              (opt-global-copy-instr-seq facts doms label instrs))
            (opt-global-copy-blocks facts doms (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-global-copy-blocks facts doms (compiler-ir-block-seq-to-list seq))]))

(define (opt-global-expr-facts-from-instrs
  [block-id : i64]
  [pos : i64]
  [instrs : CompilerIrInstrList]
  [tail : OptGlobalExprFacts]) : OptGlobalExprFacts
  (match instrs
    [(IrInstrNil) tail]
    [(IrInstrCons instr rest)
      (let
        [rest-facts : OptGlobalExprFacts
          (opt-global-expr-facts-from-instrs
            block-id
            (+ pos 1)
            (box-get rest)
            tail)]
        (match (opt-global-key-for-instr instr)
          [(OptSomeGlobalExprKey key)
            (match (opt-instr-def-var instr)
              [(OptSomeI64 dst)
                (OptGlobalExprCons
                  (OptGlobalExprFact key dst block-id pos)
                  (box rest-facts))]
              [(OptNoI64) rest-facts])]
          [(OptNoGlobalExprKey) rest-facts]))]))

(define (opt-global-expr-facts-from-instr-seq-from
  [block-id : i64]
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [tail : OptGlobalExprFacts]) : OptGlobalExprFacts
  (if (< index 0)
    tail
    (let
      [instr : CompilerIrInstr (array-ref slots index)]
      [rest-facts : OptGlobalExprFacts tail]
      [next-tail : OptGlobalExprFacts
        (match (opt-global-key-for-instr instr)
          [(OptSomeGlobalExprKey key)
            (match (opt-instr-def-var instr)
              [(OptSomeI64 dst)
                (OptGlobalExprCons
                  (OptGlobalExprFact key dst block-id (+ index 1))
                  (box rest-facts))]
              [(OptNoI64) rest-facts])]
          [(OptNoGlobalExprKey) rest-facts])]
      (opt-global-expr-facts-from-instr-seq-from
        block-id
        slots
        (- index 1)
        next-tail))))

(define (opt-global-expr-facts-from-instr-seq
  [block-id : i64]
  [instrs : CompilerIrInstrSeq]
  [tail : OptGlobalExprFacts]) : OptGlobalExprFacts
  (opt-global-expr-facts-from-instr-seq-from
    block-id
    (struct-get instrs slots)
    (- (struct-get instrs len) 1)
    tail))

(define (opt-global-expr-facts-from-blocks
  [doms : OptDomInfo]
  [blocks : CompilerIrBlockList]
  [tail : OptGlobalExprFacts]) : OptGlobalExprFacts
  (match blocks
    [(IrBlockNil) tail]
    [(IrBlockCons block rest)
      (let
        [rest-facts : OptGlobalExprFacts
          (opt-global-expr-facts-from-blocks doms (box-get rest) tail)]
        (match block
          [(IrBlock label instrs)
            (opt-global-expr-facts-from-instr-seq
              (opt-global-block-id doms label)
              instrs
              rest-facts)]))]
    [(IrBlockArray seq)
      (opt-global-expr-facts-from-blocks
        doms
        (compiler-ir-block-seq-to-list seq)
        tail)]))

(define (opt-global-fact-bucket-capacity [count : i64]) : i64
  (let
    [target : i64
      (if (< count 1)
        1
        (* count 2))]
    [capacity : i64 1]
    (begin
      (while (< capacity target)
        (set! capacity (* capacity 2)))
      capacity)))

(define (opt-global-expr-facts-count [facts : OptGlobalExprFacts]) : i64
  (match facts
    [(OptGlobalExprNil) 0]
    [(OptGlobalExprCons _ rest)
      (+ 1 (opt-global-expr-facts-count (box-get rest)))]))

(define (opt-global-expr-buckets-fill-empty!
  [buckets : (Array OptGlobalExprFacts)]
  [index : i64]) : unit
  (if (>= index (array-length buckets))
    unit
    (begin
      (array-set! buckets index (OptGlobalExprNil))
      (opt-global-expr-buckets-fill-empty! buckets (+ index 1)))))

(define (opt-global-expr-bucket-index
  [buckets : (Array OptGlobalExprFacts)]
  [key : OptGlobalExprKey]) : i64
  (bit-and (opt-global-expr-key-hash key) (- (array-length buckets) 1)))

(define (opt-global-expr-table-insert!
  [table : OptGlobalExprFactTable]
  [fact : OptGlobalExprFact]) : unit
  (match fact
    [(OptGlobalExprFact key _ _ _)
      (let
        [buckets : (Array OptGlobalExprFacts) (struct-get table buckets)]
        [bucket : i64 (opt-global-expr-bucket-index buckets key)]
        (array-set!
          buckets
          bucket
          (OptGlobalExprCons fact (box (array-ref buckets bucket)))))]))

(define (opt-global-expr-table-insert-reversed!
  [table : OptGlobalExprFactTable]
  [facts : OptGlobalExprFacts]) : unit
  (match facts
    [(OptGlobalExprNil) unit]
    [(OptGlobalExprCons fact rest)
      (begin
        (opt-global-expr-table-insert-reversed! table (box-get rest))
        (opt-global-expr-table-insert! table fact))]))

(define (opt-global-expr-table-from-facts [facts : OptGlobalExprFacts]) : OptGlobalExprFactTable
  (let
    [capacity : i64
      (opt-global-fact-bucket-capacity (opt-global-expr-facts-count facts))]
    [buckets : (Array OptGlobalExprFacts)
      (make-array OptGlobalExprFacts capacity)]
    [table : OptGlobalExprFactTable (OptGlobalExprFactTable buckets)]
    (begin
      (opt-global-expr-buckets-fill-empty! buckets 0)
      (opt-global-expr-table-insert-reversed! table facts)
      table)))

(define (opt-global-expr-lookup-list
  [facts : OptGlobalExprFacts]
  [key : OptGlobalExprKey]
  [dst : i64]
  [doms : OptDomInfo]
  [use-block-id : i64]
  [use-pos : i64]) : CompilerIrMaybeValue
  (match facts
    [(OptGlobalExprNil) (IrNoValue)]
    [(OptGlobalExprCons fact rest)
      (match fact
        [(OptGlobalExprFact fact-key fact-dst def-block-id def-pos)
          (if (and
            (not (= fact-dst dst))
            (and
              (opt-global-expr-key-eq fact-key key)
              (opt-global-fact-available?
                def-block-id
                def-pos
                use-block-id
                use-pos
                doms)))
            (IrSomeValue (IrValueVar fact-dst))
            (opt-global-expr-lookup-list
              (box-get rest)
              key
              dst
              doms
              use-block-id
              use-pos))])]))

(define (opt-global-expr-lookup
  [table : OptGlobalExprFactTable]
  [key : OptGlobalExprKey]
  [dst : i64]
  [doms : OptDomInfo]
  [use-block-id : i64]
  [use-pos : i64]) : CompilerIrMaybeValue
  (let
    [buckets : (Array OptGlobalExprFacts) (struct-get table buckets)]
    (opt-global-expr-lookup-list
      (array-ref buckets (opt-global-expr-bucket-index buckets key))
      key
      dst
      doms
      use-block-id
      use-pos)))

(define (opt-global-cse-instr
  [facts : OptGlobalExprFactTable]
  [doms : OptDomInfo]
  [block-id : i64]
  [pos : i64]
  [instr : CompilerIrInstr]) : CompilerIrInstr
  (match (opt-global-key-for-instr instr)
    [(OptSomeGlobalExprKey key)
      (match (opt-instr-def-var instr)
        [(OptSomeI64 dst)
          (match (opt-global-expr-lookup facts key dst doms block-id pos)
            [(IrSomeValue earlier)
              (match instr
                [(IrInstrMov _ _ ty) (IrInstrMov dst earlier ty)]
                [(IrInstrGep _ _ _ ty) (IrInstrMov dst earlier ty)]
                [(IrInstrCast _ _ _ to-ty) (IrInstrMov dst earlier to-ty)]
                [(IrInstrBinOp _ _ _ _ ty) (IrInstrMov dst earlier ty)]
                [(IrInstrUnOp _ _ _ ty) (IrInstrMov dst earlier ty)]
                [_ instr])]
            [(IrNoValue) instr])]
        [(OptNoI64) instr])]
    [(OptNoGlobalExprKey) instr]))

(define (opt-global-cse-instrs
  [facts : OptGlobalExprFactTable]
  [doms : OptDomInfo]
  [block-id : i64]
  [pos : i64]
  [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (compiler-ir-instr-cons
        (opt-global-cse-instr facts doms block-id pos instr)
        (opt-global-cse-instrs facts doms block-id (+ pos 1) (box-get rest)))]))

(define (opt-global-cse-instr-seq
  [facts : OptGlobalExprFactTable]
  [doms : OptDomInfo]
  [block-label : String]
  [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [index : i64 (- (struct-get instrs len) 1)]
    [block-id : i64 (opt-global-block-id doms block-label)]
    [out : CompilerIrInstrList (IrInstrNil)]
    (begin
      (while (>= index 0)
        (begin
          (set!
            out
            (compiler-ir-instr-cons
              (opt-global-cse-instr
                facts
                doms
                block-id
                (+ index 1)
                (array-ref slots index))
              out))
          (set! index (- index 1))))
      out)))

(define (opt-global-cse-blocks
  [facts : OptGlobalExprFactTable]
  [doms : OptDomInfo]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (compiler-ir-block-cons
            (compiler-ir-block
              label
              (opt-global-cse-instr-seq facts doms label instrs))
            (opt-global-cse-blocks facts doms (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-global-cse-blocks facts doms (compiler-ir-block-seq-to-list seq))]))

(define (opt-global-value-number-blocks-with-context
  [context : OptCfgContext]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (let
    [doms : OptDomInfo (struct-get context doms)]
    [copy-fact-list : OptGlobalCopyFacts
      (opt-global-copy-facts-from-blocks doms blocks (OptGlobalCopyNil))]
    [copy-facts : OptGlobalCopyFactTable
      (opt-global-copy-table-from-facts copy-fact-list)]
    [copied : CompilerIrBlockList
      (opt-global-copy-blocks copy-facts doms blocks)]
    [expr-fact-list : OptGlobalExprFacts
      (opt-global-expr-facts-from-blocks doms copied (OptGlobalExprNil))]
    [expr-facts : OptGlobalExprFactTable
      (opt-global-expr-table-from-facts expr-fact-list)]
    [cse : CompilerIrBlockList (opt-global-cse-blocks expr-facts doms copied)]
    [cse-copy-fact-list : OptGlobalCopyFacts
      (opt-global-copy-facts-from-blocks doms cse (OptGlobalCopyNil))]
    [cse-copy-facts : OptGlobalCopyFactTable
      (opt-global-copy-table-from-facts cse-copy-fact-list)]
    (opt-global-copy-blocks cse-copy-facts doms cse)))

(define (opt-global-value-number-blocks [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (opt-global-value-number-blocks-with-context
    (opt-cfg-context-build blocks)
    blocks))

(define (opt-global-value-number-function-with-context
  [context : OptCfgContext]
  [func : CompilerIrFunction]) : CompilerIrFunction
  (match (opt-verify-function-with-context func context)
    [(OkCompilerOptimizeVerify)
      (match func
        [(IrFunction name params ret-ty frame blocks)
          (IrFunction
            name
            params
            ret-ty
            frame
            (opt-global-value-number-blocks-with-context context blocks))])]
    [(ErrCompilerOptimizeVerify _) func]))

(define (opt-global-value-number-function [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(IrFunction _ _ _ _ blocks)
      (opt-global-value-number-function-with-context
        (opt-cfg-context-build blocks)
        func)]))

(define (opt-cfg-fold-branch [instr : CompilerIrInstr]) : CompilerIrInstr
  (match instr
    [(IrInstrBranch cond true-label false-label)
      (match cond
        [(IrValueBool known)
          (if known
            (IrInstrJump true-label)
            (IrInstrJump false-label))]
        [_ instr])]
    [_ instr]))

(define (opt-cfg-fold-branches-instr-seq [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [index : i64 (- (struct-get instrs len) 1)]
    [out : CompilerIrInstrList IrInstrNil]
    (begin
      (while (>= index 0)
        (begin
          (set!
            out
            (compiler-ir-instr-cons
              (opt-cfg-fold-branch (array-ref slots index))
              out))
          (set! index (- index 1))))
      out)))

(define (opt-cfg-fold-branches-block [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      (compiler-ir-block label (opt-cfg-fold-branches-instr-seq instrs))]))

(define (opt-cfg-fold-branches-blocks [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (compiler-ir-block-cons
        (opt-cfg-fold-branches-block block)
        (opt-cfg-fold-branches-blocks (box-get rest)))]
    [(IrBlockArray seq)
      (opt-cfg-fold-branches-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-cfg-instr-successors [set : OptLabelSet] [instr : CompilerIrInstr]) : OptLabelSet
  (match instr
    [(IrInstrJump label) (opt-label-add set label)]
    [(IrInstrBranch _ true-label false-label)
      (opt-label-add (opt-label-add set true-label) false-label)]
    [_ set]))

(define (opt-cfg-instr-seq-successors
  [set : OptLabelSet]
  [instrs : CompilerIrInstrSeq]) : OptLabelSet
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [out : OptLabelSet set]
    (begin
      (while (< index count)
        (begin
          (set! out (opt-cfg-instr-successors out (array-ref slots index)))
          (set! index (+ index 1))))
      out)))

(define (opt-cfg-block-successors [block : CompilerIrBlock]) : OptLabelSet
  (match block
    [(IrBlock _ instrs) (opt-cfg-instr-seq-successors (OptLabelNil) instrs)]))

(define (opt-cfg-terminator-instr? [instr : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrJump _) true]
    [(IrInstrBranch _ _ _) true]
    [(IrInstrReturn _) true]
    [(IrInstrTailCall _ _ _) true]
    [_ false]))

(define (opt-cfg-instr-seq-can-fallthrough? [instrs : CompilerIrInstrSeq]) : bool
  (let
    [count : i64 (struct-get instrs len)]
    (if (= count 0)
      true
      (not
        (opt-cfg-terminator-instr?
          (array-ref (struct-get instrs slots) (- count 1)))))))

(define (opt-cfg-block-successors-with-next
  [block : CompilerIrBlock]
  [next-label : String]) : OptLabelSet
  (match block
    [(IrBlock _ instrs)
      (let
        [explicit : OptLabelSet
          (opt-cfg-instr-seq-successors (OptLabelNil) instrs)]
        (if (and
          (> (string-length next-label) 0)
          (opt-cfg-instr-seq-can-fallthrough? instrs))
          (opt-label-add explicit next-label)
          explicit))]))

(define (opt-cfg-blocks-successors-scan
  [blocks : CompilerIrBlockList]
  [label : String]) : OptLabelSet
  (match blocks
    [(IrBlockNil) (OptLabelNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock block-label _)
          (if (string-eq block-label label)
            (opt-cfg-block-successors-with-next
              block
              (opt-cfg-entry-label (box-get rest)))
            (opt-cfg-blocks-successors-scan (box-get rest) label))])]
    [(IrBlockArray seq)
      (opt-cfg-blocks-successors-scan (compiler-ir-block-seq-to-list seq) label)]))

(define (opt-cfg-blocks-successors
  [blocks : CompilerIrBlockList]
  [label : String]) : OptLabelSet
  (opt-cfg-index-successors (opt-cfg-index-build blocks) label))

(define (opt-cfg-reachable-blocks [blocks : CompilerIrBlockList]) : OptLabelSet
  (opt-cfg-index-reachable-labels (opt-cfg-index-build blocks)))

(defenum OptLoopPreheader
  (OptNoLoopPreheader)
  (OptSomeLoopPreheader String))

(defenum OptLoopPreheaderCandidate
  (OptLoopPreheaderNone)
  (OptLoopPreheaderOne String)
  (OptLoopPreheaderMany))

(defstruct OptLoopBody
  (labels OptLabelSet)
  (members (Array bool))
  (blocks CompilerIrBlockList))

(defenum OptNaturalLoop
  (OptNaturalLoop String String OptLoopBody OptLoopPreheader))

(defenum OptMaybeNaturalLoop
  (OptNoNaturalLoop)
  (OptSomeNaturalLoop OptNaturalLoop))

(defenum OptNaturalLoopList
  (OptNaturalLoopNil)
  (OptNaturalLoopCons OptNaturalLoop (Box OptNaturalLoopList)))

(defenum OptNaturalLoopCollectState
  (OptNaturalLoopCollectState OptLabelSet OptLabelSet))

(define (opt-loop-body-fill-members!
  [index : OptCfgIndex]
  [members : (Array bool)]
  [labels : OptLabelSet]) : unit
  (match labels
    [(OptLabelNil) unit]
    [(OptLabelCons label rest)
      (begin
        (match (opt-cfg-index-id index label)
          [(OptSomeI64 id)
            (if (and (>= id 0) (< id (array-length members)))
              (array-set! members id true)
              unit)]
          [(OptNoI64) unit])
        (opt-loop-body-fill-members! index members (box-get rest)))]))

(define (opt-loop-body-member-array-contains-id?
  [members : (Array bool)]
  [id : i64]) : bool
  (if (and (>= id 0) (< id (array-length members)))
    (array-ref members id)
    false))

(define (opt-loop-body-blocks-from
  [index : OptCfgIndex]
  [members : (Array bool)]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _)
          (let
            [tail : CompilerIrBlockList
              (opt-loop-body-blocks-from index members (box-get rest))]
            (match (opt-cfg-index-id index label)
              [(OptSomeI64 id)
                (if (opt-loop-body-member-array-contains-id? members id)
                  (compiler-ir-block-cons block tail)
                  tail)]
              [(OptNoI64) tail]))])]
    [(IrBlockArray seq)
      (opt-loop-body-blocks-from
        index
        members
        (compiler-ir-block-seq-to-list seq))]))

(define (opt-loop-body-build
  [blocks : CompilerIrBlockList]
  [index : OptCfgIndex]
  [labels : OptLabelSet]) : OptLoopBody
  (let
    [members : (Array bool) (make-array bool (opt-cfg-index-block-count index))]
    (begin
      (opt-cfg-fill-bool! members (array-length members) false)
      (opt-loop-body-fill-members! index members labels)
      (OptLoopBody
        labels
        members
        (opt-loop-body-blocks-from index members blocks)))))

(define (opt-loop-body-labels [body : OptLoopBody]) : OptLabelSet
  (struct-get body labels))

(define (opt-loop-body-blocks [body : OptLoopBody]) : CompilerIrBlockList
  (struct-get body blocks))

(define (opt-loop-body-contains-id? [body : OptLoopBody] [id : i64]) : bool
  (opt-loop-body-member-array-contains-id? (struct-get body members) id))

(define (opt-loop-body-label-member?
  [body : OptLoopBody]
  [index : OptCfgIndex]
  [label : String]) : bool
  (match (opt-cfg-index-id index label)
    [(OptSomeI64 id) (opt-loop-body-contains-id? body id)]
    [(OptNoI64) false]))

(define (opt-loop-body-current-blocks-from
  [body : OptLoopBody]
  [index : OptCfgIndex]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _)
          (let
            [tail : CompilerIrBlockList
              (opt-loop-body-current-blocks-from body index (box-get rest))]
            (match (opt-cfg-index-id index label)
              [(OptSomeI64 id)
                (if (opt-loop-body-contains-id? body id)
                  (compiler-ir-block-cons block tail)
                  tail)]
              [(OptNoI64) tail]))])]
    [(IrBlockArray seq)
      (opt-loop-body-current-blocks-from
        body
        index
        (compiler-ir-block-seq-to-list seq))]))

(define (opt-natural-loop-header [loop : OptNaturalLoop]) : String
  (match loop
    [(OptNaturalLoop header _ _ _) header]))

(define (opt-natural-loop-latch [loop : OptNaturalLoop]) : String
  (match loop
    [(OptNaturalLoop _ latch _ _) latch]))

(define (opt-natural-loop-body-info [loop : OptNaturalLoop]) : OptLoopBody
  (match loop
    [(OptNaturalLoop _ _ body _) body]))

(define (opt-natural-loop-body [loop : OptNaturalLoop]) : OptLabelSet
  (match loop
    [(OptNaturalLoop _ _ body _) (opt-loop-body-labels body)]))

(define (opt-natural-loop-body-blocks [loop : OptNaturalLoop]) : CompilerIrBlockList
  (opt-loop-body-blocks (opt-natural-loop-body-info loop)))

(define (opt-natural-loop-body-contains-id? [loop : OptNaturalLoop] [id : i64]) : bool
  (opt-loop-body-contains-id? (opt-natural-loop-body-info loop) id))

(define (opt-natural-loop-current-body-blocks
  [index : OptCfgIndex]
  [loop : OptNaturalLoop]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (opt-loop-body-current-blocks-from
    (opt-natural-loop-body-info loop)
    index
    blocks))

(define (opt-natural-loop-preheader [loop : OptNaturalLoop]) : OptLoopPreheader
  (match loop
    [(OptNaturalLoop _ _ _ preheader) preheader]))

(define (opt-natural-loop-list-count [loops : OptNaturalLoopList]) : i64
  (match loops
    [(OptNaturalLoopNil) 0]
    [(OptNaturalLoopCons _ rest)
      (+ 1 (opt-natural-loop-list-count (box-get rest)))]))

(define (opt-natural-loop-find
  [loops : OptNaturalLoopList]
  [header : String]
  [latch : String]) : OptMaybeNaturalLoop
  (match loops
    [(OptNaturalLoopNil) (OptNoNaturalLoop)]
    [(OptNaturalLoopCons loop rest)
      (if (and
        (string-eq (opt-natural-loop-header loop) header)
        (string-eq (opt-natural-loop-latch loop) latch))
        (OptSomeNaturalLoop loop)
        (opt-natural-loop-find (box-get rest) header latch))]))

(define (opt-natural-loop-collect-add-pred
  [reachable : OptLabelSet]
  [state : OptNaturalLoopCollectState]
  [pred : String]) : OptNaturalLoopCollectState
  (match state
    [(OptNaturalLoopCollectState body worklist)
      (if (and
        (opt-label-contains reachable pred)
        (not (opt-label-contains body pred)))
        (OptNaturalLoopCollectState
          (opt-label-add body pred)
          (opt-label-add worklist pred))
        state)]))

(define (opt-natural-loop-collect-add-preds
  [reachable : OptLabelSet]
  [preds : OptLabelSet]
  [state : OptNaturalLoopCollectState]) : OptNaturalLoopCollectState
  (match preds
    [(OptLabelNil) state]
    [(OptLabelCons pred rest)
      (opt-natural-loop-collect-add-preds
        reachable
        (box-get rest)
        (opt-natural-loop-collect-add-pred reachable state pred))]))

(define (opt-natural-loop-collect-body
  [pred-map : OptPredMap]
  [reachable : OptLabelSet]
  [body : OptLabelSet]
  [worklist : OptLabelSet]) : OptLabelSet
  (match worklist
    [(OptLabelNil) body]
    [(OptLabelCons label rest)
      (let
        [state : OptNaturalLoopCollectState
          (opt-natural-loop-collect-add-preds
            reachable
            (opt-pred-map-lookup pred-map label)
            (OptNaturalLoopCollectState body (box-get rest)))]
        (match state
          [(OptNaturalLoopCollectState next-body next-worklist)
            (opt-natural-loop-collect-body
              pred-map
              reachable
              next-body
              next-worklist)]))]))

(define (opt-natural-loop-safe-preheader-block?
  [pred-map : OptPredMap]
  [label : String]
  [header : String]) : bool
  (let
    [successors : OptLabelSet (opt-pred-map-successors pred-map label)]
    (and
      (= (opt-label-count successors) 1)
      (opt-label-contains successors header))))

(define (opt-natural-loop-preheader-candidate-add
  [pred-map : OptPredMap]
  [header : String]
  [candidate : OptLoopPreheaderCandidate]
  [pred : String]) : OptLoopPreheaderCandidate
  (match candidate
    [(OptLoopPreheaderMany) (OptLoopPreheaderMany)]
    [(OptLoopPreheaderNone)
      (if (opt-natural-loop-safe-preheader-block? pred-map pred header)
        (OptLoopPreheaderOne pred)
        (OptLoopPreheaderMany))]
    [(OptLoopPreheaderOne _) (OptLoopPreheaderMany)]))

(define (opt-natural-loop-preheader-candidate-scan
  [pred-map : OptPredMap]
  [reachable : OptLabelSet]
  [header : String]
  [body : OptLabelSet]
  [preds : OptLabelSet]
  [candidate : OptLoopPreheaderCandidate]) : OptLoopPreheaderCandidate
  (match preds
    [(OptLabelNil) candidate]
    [(OptLabelCons pred rest)
      (if (and
        (opt-label-contains reachable pred)
        (not (opt-label-contains body pred)))
        (opt-natural-loop-preheader-candidate-scan
          pred-map
          reachable
          header
          body
          (box-get rest)
          (opt-natural-loop-preheader-candidate-add
            pred-map
            header
            candidate
            pred))
        (opt-natural-loop-preheader-candidate-scan
          pred-map
          reachable
          header
          body
          (box-get rest)
          candidate))]))

(define (opt-natural-loop-preheader-from-candidate
  [candidate : OptLoopPreheaderCandidate]) : OptLoopPreheader
  (match candidate
    [(OptLoopPreheaderOne label) (OptSomeLoopPreheader label)]
    [_ (OptNoLoopPreheader)]))

(define (opt-natural-loop-find-preheader
  [blocks : CompilerIrBlockList]
  [pred-map : OptPredMap]
  [reachable : OptLabelSet]
  [header : String]
  [body : OptLabelSet]) : OptLoopPreheader
  (opt-natural-loop-preheader-from-candidate
    (opt-natural-loop-preheader-candidate-scan
      pred-map
      reachable
      header
      body
      (opt-pred-map-lookup pred-map header)
      (OptLoopPreheaderNone))))

(define (opt-natural-loop-build
  [blocks : CompilerIrBlockList]
  [pred-map : OptPredMap]
  [reachable : OptLabelSet]
  [header : String]
  [latch : String]) : OptNaturalLoop
  (let
    [body-labels : OptLabelSet
      (opt-natural-loop-collect-body
        pred-map
        reachable
        (opt-label-add (opt-label-add (OptLabelNil) header) latch)
        (opt-label-add (OptLabelNil) latch))]
    [body : OptLoopBody
      (opt-loop-body-build blocks (struct-get pred-map index) body-labels)]
    (OptNaturalLoop
      header
      latch
      body
      (opt-natural-loop-find-preheader
        blocks
        pred-map
        reachable
        header
        body-labels))))

(define (opt-cfg-natural-loop-successors
  [blocks : CompilerIrBlockList]
  [pred-map : OptPredMap]
  [reachable : OptLabelSet]
  [doms : OptDomInfo]
  [source-id : i64]
  [source : String]
  [successors : OptLabelSet]
  [tail : OptNaturalLoopList]) : OptNaturalLoopList
  (match successors
    [(OptLabelNil) tail]
    [(OptLabelCons header rest)
      (let
        [next : OptNaturalLoopList
          (opt-cfg-natural-loop-successors
            blocks
            pred-map
            reachable
            doms
            source-id
            source
            (box-get rest)
            tail)]
        (match (opt-cfg-index-id (struct-get doms index) header)
          [(OptSomeI64 header-id)
            (if (and
              (opt-label-contains reachable header)
              (opt-dom-info-dominates-id? doms header-id source-id))
              (OptNaturalLoopCons
                (opt-natural-loop-build blocks pred-map reachable header source)
                (box next))
              next)]
          [(OptNoI64) next]))]))

(define (opt-cfg-natural-loop-blocks
  [all-blocks : CompilerIrBlockList]
  [remaining : CompilerIrBlockList]
  [pred-map : OptPredMap]
  [reachable : OptLabelSet]
  [doms : OptDomInfo]) : OptNaturalLoopList
  (match remaining
    [(IrBlockNil) (OptNaturalLoopNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _)
          (let
            [tail : OptNaturalLoopList
              (opt-cfg-natural-loop-blocks
                all-blocks
                (box-get rest)
                pred-map
                reachable
                doms)]
            (if (opt-label-contains reachable label)
              (match (opt-cfg-index-id (struct-get doms index) label)
                [(OptSomeI64 source-id)
                  (opt-cfg-natural-loop-successors
                    all-blocks
                    pred-map
                    reachable
                    doms
                    source-id
                    label
                    (opt-cfg-block-successors-with-next
                      block
                      (opt-cfg-entry-label (box-get rest)))
                    tail)]
                [(OptNoI64) tail])
              tail))])]
    [(IrBlockArray seq)
      (opt-cfg-natural-loop-blocks
        all-blocks
        (compiler-ir-block-seq-to-list seq)
        pred-map
        reachable
        doms)]))

(define (opt-cfg-natural-loops-with-context
  [blocks : CompilerIrBlockList]
  [context : OptCfgContext]) : OptNaturalLoopList
  (opt-cfg-natural-loop-blocks
    blocks
    blocks
    (struct-get context pred-map)
    (struct-get context reachable)
    (struct-get context doms)))

(define (opt-cfg-natural-loops [blocks : CompilerIrBlockList]) : OptNaturalLoopList
  (opt-cfg-natural-loops-with-context blocks (opt-cfg-context-build blocks)))

;; --- safe loop preheader synthesis (#2457) ----------------------------------
;;
;; LICM and induction only operate on loops with a dedicated outside predecessor
;; whose only successor is the loop header. This pass creates that block for
;; conservative natural loops and falls back to the original function if the
;; verifier rejects the result.
(defenum OptLoopPreheadersResult
  (OptLoopPreheadersResult CompilerIrBlockList bool))

(defenum OptLoopPreheadersPhiRewriteResult
  (OptLoopPreheadersPhiRewriteResult CompilerIrPhiInputList bool))

(define (opt-loop-preheaders-outside-preds-scan
  [reachable : OptLabelSet]
  [doms : OptDomInfo]
  [header : String]
  [body : OptLabelSet]
  [preds : OptLabelSet]) : OptLabelSet
  (match preds
    [(OptLabelNil) (OptLabelNil)]
    [(OptLabelCons pred rest)
      (let
        [tail : OptLabelSet
          (opt-loop-preheaders-outside-preds-scan
            reachable
            doms
            header
            body
            (box-get rest))]
        (if (and
          (opt-label-contains reachable pred)
          (and
            (not (opt-label-contains body pred))
            (not (opt-dom-dominates? doms header pred))))
          (opt-label-add tail pred)
          tail))]))

(define (opt-loop-preheaders-outside-preds
  [pred-map : OptPredMap]
  [reachable : OptLabelSet]
  [doms : OptDomInfo]
  [header : String]
  [body : OptLabelSet]) : OptLabelSet
  (opt-loop-preheaders-outside-preds-scan
    reachable
    doms
    header
    body
    (opt-pred-map-lookup pred-map header)))

(define (opt-loop-preheaders-candidate-label [header : String] [suffix : i64]) : String
  (if (= suffix 0)
    (string-append header "__preheader")
    (string-append header (string-append "__preheader" (int->string suffix)))))

(define (opt-loop-preheaders-fresh-label
  [blocks : CompilerIrBlockList]
  [header : String]
  [suffix : i64]) : String
  (let
    [candidate : String (opt-loop-preheaders-candidate-label header suffix)]
    (if (opt-cfg-block-exists? blocks candidate)
      (opt-loop-preheaders-fresh-label blocks header (+ suffix 1))
      candidate)))

(define (opt-loop-preheaders-phi-outside-values-compatible?
  [outside : OptLabelSet]
  [inputs : CompilerIrPhiInputList]
  [seen : CompilerIrMaybeValue]) : bool
  (match inputs
    [(IrPhiInputNil) true]
    [(IrPhiInputCons value label rest)
      (if (opt-label-contains outside label)
        (match seen
          [(IrNoValue)
            (opt-loop-preheaders-phi-outside-values-compatible?
              outside
              (box-get rest)
              (IrSomeValue value))]
          [(IrSomeValue first)
            (and
              (opt-value-eq first value)
              (opt-loop-preheaders-phi-outside-values-compatible?
                outside
                (box-get rest)
                seen))])
        (opt-loop-preheaders-phi-outside-values-compatible?
          outside
          (box-get rest)
          seen))]))

(define (opt-loop-preheaders-header-instr-compatible?
  [outside : OptLabelSet]
  [instr : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrPhi _ inputs _)
      (opt-loop-preheaders-phi-outside-values-compatible?
        outside
        inputs
        (IrNoValue))]
    [_ true]))

(define (opt-loop-preheaders-header-instrs-compatible-from?
  [outside : OptLabelSet]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : bool
  (if (>= index (compiler-ir-instr-seq-count instrs))
    true
    (and
      (opt-loop-preheaders-header-instr-compatible?
        outside
        (compiler-ir-instr-seq-ref instrs index))
      (opt-loop-preheaders-header-instrs-compatible-from?
        outside
        instrs
        (+ index 1)))))

(define (opt-loop-preheaders-header-compatible?
  [blocks : CompilerIrBlockList]
  [header : String]
  [outside : OptLabelSet]) : bool
  (match (opt-cfg-find-block blocks header)
    [(OptNoBlock) false]
    [(OptSomeBlock block)
      (match block
        [(IrBlock _ instrs)
          (opt-loop-preheaders-header-instrs-compatible-from? outside instrs 0)])]))

(define (opt-loop-preheaders-existing-candidate-scan
  [pred-map : OptPredMap]
  [header : String]
  [outside : OptLabelSet]
  [candidate : OptLoopPreheaderCandidate]) : OptLoopPreheaderCandidate
  (match outside
    [(OptLabelNil) candidate]
    [(OptLabelCons pred rest)
      (opt-loop-preheaders-existing-candidate-scan
        pred-map
        header
        (box-get rest)
        (opt-natural-loop-preheader-candidate-add
          pred-map
          header
          candidate
          pred))]))

(define (opt-loop-preheaders-existing-safe-preheader?
  [pred-map : OptPredMap]
  [header : String]
  [outside : OptLabelSet]) : bool
  (match (opt-natural-loop-preheader-from-candidate
    (opt-loop-preheaders-existing-candidate-scan
      pred-map
      header
      outside
      (OptLoopPreheaderNone)))
    [(OptSomeLoopPreheader _) true]
    [(OptNoLoopPreheader) false]))

(define (opt-loop-preheaders-rewrite-phi-inputs-acc
  [inputs : CompilerIrPhiInputList]
  [outside : OptLabelSet]
  [preheader : String]
  [emitted : bool]
  [acc : CompilerIrPhiInputList]) : OptLoopPreheadersPhiRewriteResult
  (match inputs
    [(IrPhiInputNil)
      (OptLoopPreheadersPhiRewriteResult
        (compiler-ir-phi-input-list-reverse-onto acc (IrPhiInputNil))
        emitted)]
    [(IrPhiInputCons value label rest)
      (if (opt-label-contains outside label)
        (if emitted
          (opt-loop-preheaders-rewrite-phi-inputs-acc
            (box-get rest)
            outside
            preheader
            true
            acc)
          (opt-loop-preheaders-rewrite-phi-inputs-acc
            (box-get rest)
            outside
            preheader
            true
            (compiler-ir-phi-input-cons value preheader acc)))
        (opt-loop-preheaders-rewrite-phi-inputs-acc
          (box-get rest)
          outside
          preheader
          emitted
          (compiler-ir-phi-input-cons value label acc)))]))

(define (opt-loop-preheaders-rewrite-phi-inputs
  [inputs : CompilerIrPhiInputList]
  [outside : OptLabelSet]
  [preheader : String]) : CompilerIrPhiInputList
  (match (opt-loop-preheaders-rewrite-phi-inputs-acc
    inputs
    outside
    preheader
    false
    (IrPhiInputNil))
    [(OptLoopPreheadersPhiRewriteResult rewritten _) rewritten]))

(define (opt-loop-preheaders-rewrite-header-instr
  [outside : OptLabelSet]
  [preheader : String]
  [instr : CompilerIrInstr]) : CompilerIrInstr
  (match instr
    [(IrInstrPhi dst inputs ty)
      (IrInstrPhi
        dst
        (opt-loop-preheaders-rewrite-phi-inputs inputs outside preheader)
        ty)]
    [_ instr]))

(define (opt-loop-preheaders-rewrite-header-instrs-from
  [outside : OptLabelSet]
  [preheader : String]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : CompilerIrInstrList
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (IrInstrNil)
    (compiler-ir-instr-cons
      (opt-loop-preheaders-rewrite-header-instr
        outside
        preheader
        (compiler-ir-instr-seq-ref instrs index))
      (opt-loop-preheaders-rewrite-header-instrs-from
        outside
        preheader
        instrs
        (+ index 1)))))

(define (opt-loop-preheaders-retarget-label
  [label : String]
  [header : String]
  [preheader : String]) : String
  (if (string-eq label header)
    preheader
    label))

(define (opt-loop-preheaders-retarget-instr
  [instr : CompilerIrInstr]
  [header : String]
  [preheader : String]) : CompilerIrInstr
  (match instr
    [(IrInstrJump label)
      (IrInstrJump (opt-loop-preheaders-retarget-label label header preheader))]
    [(IrInstrBranch cond true-label false-label)
      (IrInstrBranch
        cond
        (opt-loop-preheaders-retarget-label true-label header preheader)
        (opt-loop-preheaders-retarget-label false-label header preheader))]
    [_ instr]))

(define (opt-loop-preheaders-retarget-instrs-from
  [instrs : CompilerIrInstrSeq]
  [header : String]
  [preheader : String]
  [index : i64]) : CompilerIrInstrList
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (IrInstrNil)
    (compiler-ir-instr-cons
      (opt-loop-preheaders-retarget-instr
        (compiler-ir-instr-seq-ref instrs index)
        header
        preheader)
      (opt-loop-preheaders-retarget-instrs-from
        instrs
        header
        preheader
        (+ index 1)))))

(define (opt-loop-preheaders-append-jump
  [instrs : CompilerIrInstrList]
  [target : String]) : CompilerIrInstrList
  (opt-aggregate-instr-list-append
    instrs
    (compiler-ir-instr-cons (IrInstrJump target) (IrInstrNil))))

(define (opt-loop-preheaders-rewrite-block
  [block : CompilerIrBlock]
  [next-label : String]
  [header : String]
  [outside : OptLabelSet]
  [preheader : String]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      (if (string-eq label header)
        (compiler-ir-block
          label
          (opt-loop-preheaders-rewrite-header-instrs-from
            outside
            preheader
            instrs
            0))
        (if (opt-label-contains outside label)
          (let
            [retargeted : CompilerIrInstrList
              (opt-loop-preheaders-retarget-instrs-from
                instrs
                header
                preheader
                0)]
            (compiler-ir-block
              label
              (if (and
                (string-eq next-label header)
                (opt-cfg-instr-seq-can-fallthrough? instrs))
                (opt-loop-preheaders-append-jump retargeted preheader)
                retargeted)))
          block))]))

(define (opt-loop-preheaders-rewrite-blocks
  [blocks : CompilerIrBlockList]
  [header : String]
  [outside : OptLabelSet]
  [preheader : String]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (compiler-ir-block-cons
        (opt-loop-preheaders-rewrite-block
          block
          (opt-cfg-entry-label (box-get rest))
          header
          outside
          preheader)
        (opt-loop-preheaders-rewrite-blocks
          (box-get rest)
          header
          outside
          preheader))]
    [(IrBlockArray seq)
      (opt-loop-preheaders-rewrite-blocks
        (compiler-ir-block-seq-to-list seq)
        header
        outside
        preheader)]))

(define (opt-loop-preheaders-new-block [preheader : String] [header : String]) : CompilerIrBlock
  (compiler-ir-block
    preheader
    (compiler-ir-instr-cons (IrInstrJump header) (IrInstrNil))))

(define (opt-loop-preheaders-insert-before-header
  [blocks : CompilerIrBlockList]
  [header : String]
  [preheader : String]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _)
          (if (string-eq label header)
            (compiler-ir-block-cons
              (opt-loop-preheaders-new-block preheader header)
              (compiler-ir-block-cons block (box-get rest)))
            (compiler-ir-block-cons
              block
              (opt-loop-preheaders-insert-before-header
                (box-get rest)
                header
                preheader)))])]
    [(IrBlockArray seq)
      (opt-loop-preheaders-insert-before-header
        (compiler-ir-block-seq-to-list seq)
        header
        preheader)]))

(define (opt-loop-preheaders-synthesize-loop
  [blocks : CompilerIrBlockList]
  [context : OptCfgContext]
  [loop : OptNaturalLoop]) : OptLoopPreheadersResult
  (match (opt-natural-loop-preheader loop)
    [(OptSomeLoopPreheader _) (OptLoopPreheadersResult blocks false)]
    [(OptNoLoopPreheader)
      (let
        [header : String (opt-natural-loop-header loop)]
        [body : OptLabelSet (opt-natural-loop-body loop)]
        [outside : OptLabelSet
          (opt-loop-preheaders-outside-preds
            (struct-get context pred-map)
            (struct-get context reachable)
            (struct-get context doms)
            header
            body)]
        (if (and
          (> (opt-label-count outside) 0)
          (and
            (not
              (opt-loop-preheaders-existing-safe-preheader?
                (struct-get context pred-map)
                header
                outside))
            (opt-loop-preheaders-header-compatible? blocks header outside)))
          (let
            [preheader : String
              (opt-loop-preheaders-fresh-label blocks header 0)]
            [rewritten : CompilerIrBlockList
              (opt-loop-preheaders-rewrite-blocks
                blocks
                header
                outside
                preheader)]
            (OptLoopPreheadersResult
              (opt-loop-preheaders-insert-before-header
                rewritten
                header
                preheader)
              true))
          (OptLoopPreheadersResult blocks false)))]))

(define (opt-loop-preheaders-synthesize-loops
  [blocks : CompilerIrBlockList]
  [context : OptCfgContext]
  [loops : OptNaturalLoopList]) : OptLoopPreheadersResult
  (match loops
    [(OptNaturalLoopNil) (OptLoopPreheadersResult blocks false)]
    [(OptNaturalLoopCons loop rest)
      (match (opt-loop-preheaders-synthesize-loop blocks context loop)
        [(OptLoopPreheadersResult next changed)
          (if changed
            (OptLoopPreheadersResult next true)
            (opt-loop-preheaders-synthesize-loops blocks context (box-get rest)))])]))

(define (opt-loop-preheaders-blocks-once [blocks : CompilerIrBlockList]) : OptLoopPreheadersResult
  (let
    [context : OptCfgContext (opt-cfg-context-build blocks)]
    (opt-loop-preheaders-synthesize-loops
      blocks
      context
      (opt-cfg-natural-loops-with-context blocks context))))

(define (opt-loop-preheaders-blocks-fixed
  [blocks : CompilerIrBlockList]
  [remaining : i64]) : CompilerIrBlockList
  (if (<= remaining 0)
    blocks
    (match (opt-loop-preheaders-blocks-once blocks)
      [(OptLoopPreheadersResult next changed)
        (if changed
          (opt-loop-preheaders-blocks-fixed next (- remaining 1))
          next)])))

(define (opt-loop-preheaders-blocks [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (opt-loop-preheaders-blocks-fixed
    blocks
    (+ 1 (compiler-ir-block-list-count blocks))))

(define (opt-loop-preheaders-function [func : CompilerIrFunction]) : CompilerIrFunction
  (match (opt-verify-function func)
    [(OkCompilerOptimizeVerify)
      (match func
        [(IrFunction name params ret-ty frame blocks)
          (let
            [next-blocks : CompilerIrBlockList
              (opt-loop-preheaders-blocks blocks)]
            [next : CompilerIrFunction
              (IrFunction name params ret-ty frame next-blocks)]
            (match (opt-verify-function next)
              [(OkCompilerOptimizeVerify) next]
              [(ErrCompilerOptimizeVerify _) func]))])]
    [(ErrCompilerOptimizeVerify _) func]))

;; --- conservative loop-invariant code motion (#1801) ------------------------
;;
;; LICM is deliberately scalar-only and verifier-gated. It moves only
;; non-trapping `BinOp` and `UnOp` definitions from natural loops with a single
;; safe preheader. A candidate's value operands must be defined outside the loop
;; or by an earlier instruction already selected for the same hoist. Loads,
;; stores, calls, allocations, bounds checks, GEPs, phis, vector memory ops, and
;; trapping arithmetic are left in place.
(defenum OptLicmInstrsResult
  (OptLicmInstrsResult CompilerIrInstrList CompilerIrInstrList I64I64Map bool))

(defenum OptLicmBlocksResult
  (OptLicmBlocksResult CompilerIrBlockList CompilerIrInstrList I64I64Map bool))

(define (opt-licm-body-map-capacity [body-blocks : CompilerIrBlockList]) : i64
  (+ 1 (compiler-ir-block-list-instruction-count body-blocks)))

(define (opt-licm-collect-defs-instrs
  [instrs : CompilerIrInstrList]
  [set : I64I64Map]) : I64I64Map
  (match instrs
    [(IrInstrNil) set]
    [(IrInstrCons instr rest)
      (match (opt-instr-def-var instr)
        [(OptSomeI64 var)
          (opt-licm-collect-defs-instrs (box-get rest) (opt-used-add set var))]
        [(OptNoI64) (opt-licm-collect-defs-instrs (box-get rest) set)])]))

(define (opt-licm-collect-defs-instr-seq-from
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [set : I64I64Map]) : I64I64Map
  (if (>= index (compiler-ir-instr-seq-count instrs))
    set
    (match (opt-instr-def-var (compiler-ir-instr-seq-ref instrs index))
      [(OptSomeI64 var)
        (opt-licm-collect-defs-instr-seq-from
          instrs
          (+ index 1)
          (opt-used-add set var))]
      [(OptNoI64) (opt-licm-collect-defs-instr-seq-from instrs (+ index 1) set)])))

(define (opt-licm-collect-defs-instr-seq
  [instrs : CompilerIrInstrSeq]
  [set : I64I64Map]) : I64I64Map
  (opt-licm-collect-defs-instr-seq-from instrs 0 set))

(define (opt-licm-collect-defs-blocks
  [blocks : CompilerIrBlockList]
  [set : I64I64Map]) : I64I64Map
  (match blocks
    [(IrBlockNil) set]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (opt-licm-collect-defs-blocks
            (box-get rest)
            (opt-licm-collect-defs-instr-seq instrs set))])]
    [(IrBlockArray seq)
      (opt-licm-collect-defs-blocks (compiler-ir-block-seq-to-list seq) set)]))

(define (opt-licm-value-invariant?
  [loop-defs : I64I64Map]
  [hoisted : I64I64Map]
  [value : CompilerIrValue]) : bool
  (match value
    [(IrValueVar var)
      (or
        (not (opt-used-contains loop-defs var))
        (opt-used-contains hoisted var))]
    [_ true]))

(define (opt-licm-candidate?
  [loop-defs : I64I64Map]
  [hoisted : I64I64Map]
  [instr : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrBinOp _ op lhs rhs _)
      (and
        (not (opt-binop-traps? op))
        (and
          (opt-licm-value-invariant? loop-defs hoisted lhs)
          (opt-licm-value-invariant? loop-defs hoisted rhs)))]
    [(IrInstrUnOp _ _ src _) (opt-licm-value-invariant? loop-defs hoisted src)]
    [_ false]))

(define (opt-licm-add-hoisted-def
  [hoisted : I64I64Map]
  [instr : CompilerIrInstr]) : I64I64Map
  (match (opt-instr-def-var instr)
    [(OptSomeI64 var) (opt-used-add hoisted var)]
    [(OptNoI64) hoisted]))

(define (opt-licm-filter-instrs
  [loop-defs : I64I64Map]
  [instrs : CompilerIrInstrList]
  [hoisted : I64I64Map]) : OptLicmInstrsResult
  (match instrs
    [(IrInstrNil) (OptLicmInstrsResult (IrInstrNil) (IrInstrNil) hoisted false)]
    [(IrInstrCons instr rest)
      (if (opt-licm-candidate? loop-defs hoisted instr)
        (match (opt-licm-filter-instrs
          loop-defs
          (box-get rest)
          (opt-licm-add-hoisted-def hoisted instr))
          [(OptLicmInstrsResult kept moved next-hoisted _)
            (OptLicmInstrsResult
              kept
              (compiler-ir-instr-cons instr moved)
              next-hoisted
              true)])
        (match (opt-licm-filter-instrs loop-defs (box-get rest) hoisted)
          [(OptLicmInstrsResult kept moved next-hoisted changed)
            (OptLicmInstrsResult
              (compiler-ir-instr-cons instr kept)
              moved
              next-hoisted
              changed)]))]))

(define (opt-licm-filter-instr-seq-from
  [loop-defs : I64I64Map]
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [hoisted : I64I64Map]) : OptLicmInstrsResult
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (OptLicmInstrsResult (IrInstrNil) (IrInstrNil) hoisted false)
    (let
      [instr : CompilerIrInstr (compiler-ir-instr-seq-ref instrs index)]
      (if (opt-licm-candidate? loop-defs hoisted instr)
        (match (opt-licm-filter-instr-seq-from
          loop-defs
          instrs
          (+ index 1)
          (opt-licm-add-hoisted-def hoisted instr))
          [(OptLicmInstrsResult kept moved next-hoisted _)
            (OptLicmInstrsResult
              kept
              (compiler-ir-instr-cons instr moved)
              next-hoisted
              true)])
        (match (opt-licm-filter-instr-seq-from
          loop-defs
          instrs
          (+ index 1)
          hoisted)
          [(OptLicmInstrsResult kept moved next-hoisted changed)
            (OptLicmInstrsResult
              (compiler-ir-instr-cons instr kept)
              moved
              next-hoisted
              changed)])))))

(define (opt-licm-filter-instr-seq
  [loop-defs : I64I64Map]
  [instrs : CompilerIrInstrSeq]
  [hoisted : I64I64Map]) : OptLicmInstrsResult
  (opt-licm-filter-instr-seq-from loop-defs instrs 0 hoisted))

(define (opt-licm-filter-body-blocks
  [loop-defs : I64I64Map]
  [blocks : CompilerIrBlockList]
  [hoisted : I64I64Map]) : OptLicmBlocksResult
  (match blocks
    [(IrBlockNil) (OptLicmBlocksResult (IrBlockNil) (IrInstrNil) hoisted false)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (match (opt-licm-filter-instr-seq loop-defs instrs hoisted)
            [(OptLicmInstrsResult kept moved next-hoisted block-changed)
              (match (opt-licm-filter-body-blocks
                loop-defs
                (box-get rest)
                next-hoisted)
                [(OptLicmBlocksResult
                    rest-blocks
                    rest-moved
                    final-hoisted
                    rest-changed)
                  (OptLicmBlocksResult
                    (compiler-ir-block-cons
                      (compiler-ir-block label kept)
                      rest-blocks)
                    (opt-aggregate-instr-list-append moved rest-moved)
                    final-hoisted
                    (or block-changed rest-changed))])])])]
    [(IrBlockArray seq)
      (opt-licm-filter-body-blocks
        loop-defs
        (compiler-ir-block-seq-to-list seq)
        hoisted)]))

(define (opt-licm-replace-body-blocks
  [blocks : CompilerIrBlockList]
  [body-blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match body-blocks
    [(IrBlockNil) blocks]
    [(IrBlockCons replacement replacement-rest)
      (match blocks
        [(IrBlockNil) (IrBlockNil)]
        [(IrBlockCons block rest)
          (match block
            [(IrBlock label _)
              (match replacement
                [(IrBlock replacement-label _)
                  (if (string-eq label replacement-label)
                    (compiler-ir-block-cons
                      replacement
                      (opt-licm-replace-body-blocks
                        (box-get rest)
                        (box-get replacement-rest)))
                    (compiler-ir-block-cons
                      block
                      (opt-licm-replace-body-blocks (box-get rest) body-blocks)))])])]
        [(IrBlockArray seq)
          (opt-licm-replace-body-blocks
            (compiler-ir-block-seq-to-list seq)
            body-blocks)])]
    [(IrBlockArray seq)
      (opt-licm-replace-body-blocks blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-licm-insert-before-terminator
  [hoisted : CompilerIrInstrList]
  [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match hoisted
    [(IrInstrNil) instrs]
    [_
      (match instrs
        [(IrInstrNil) hoisted]
        [(IrInstrCons instr rest)
          (if (opt-cfg-terminator-instr? instr)
            (opt-aggregate-instr-list-append hoisted instrs)
            (compiler-ir-instr-cons
              instr
              (opt-licm-insert-before-terminator hoisted (box-get rest))))])]))

(define (opt-licm-insert-before-terminator-seq-from
  [hoisted : CompilerIrInstrList]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : CompilerIrInstrList
  (match hoisted
    [(IrInstrNil) (opt-aggregate-instr-seq-append-from instrs index IrInstrNil)]
    [_
      (if (>= index (compiler-ir-instr-seq-count instrs))
        hoisted
        (let
          [instr : CompilerIrInstr (compiler-ir-instr-seq-ref instrs index)]
          (if (opt-cfg-terminator-instr? instr)
            (opt-aggregate-instr-list-append
              hoisted
              (opt-aggregate-instr-seq-append-from instrs index IrInstrNil))
            (compiler-ir-instr-cons
              instr
              (opt-licm-insert-before-terminator-seq-from
                hoisted
                instrs
                (+ index 1))))))]))

(define (opt-licm-insert-before-terminator-seq
  [hoisted : CompilerIrInstrList]
  [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (opt-licm-insert-before-terminator-seq-from hoisted instrs 0))

(define (opt-licm-insert-preheader-blocks
  [preheader : String]
  [hoisted : CompilerIrInstrList]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (compiler-ir-block-cons
            (if (string-eq label preheader)
              (compiler-ir-block
                label
                (opt-licm-insert-before-terminator-seq hoisted instrs))
              block)
            (opt-licm-insert-preheader-blocks preheader hoisted (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-licm-insert-preheader-blocks
        preheader
        hoisted
        (compiler-ir-block-seq-to-list seq))]))

(define (opt-licm-apply-loop
  [index : OptCfgIndex]
  [blocks : CompilerIrBlockList]
  [loop : OptNaturalLoop]) : CompilerIrBlockList
  (match (opt-natural-loop-preheader loop)
    [(OptSomeLoopPreheader preheader)
      (let
        [body-blocks : CompilerIrBlockList
          (opt-natural-loop-current-body-blocks index loop blocks)]
        [map-capacity : i64 (opt-licm-body-map-capacity body-blocks)]
        [loop-defs : I64I64Map
          (opt-licm-collect-defs-blocks
            body-blocks
            (i64-i64-map-with-capacity map-capacity))]
        (match (opt-licm-filter-body-blocks
          loop-defs
          body-blocks
          (i64-i64-map-with-capacity map-capacity))
          [(OptLicmBlocksResult filtered-body hoisted _ changed)
            (if changed
              (opt-licm-insert-preheader-blocks
                preheader
                hoisted
                (opt-licm-replace-body-blocks blocks filtered-body))
              blocks)]))]
    [(OptNoLoopPreheader) blocks]))

(define (opt-licm-apply-loops
  [index : OptCfgIndex]
  [loops : OptNaturalLoopList]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match loops
    [(OptNaturalLoopNil) blocks]
    [(OptNaturalLoopCons loop rest)
      (opt-licm-apply-loops
        index
        (box-get rest)
        (opt-licm-apply-loop index blocks loop))]))

(define (opt-licm-blocks-with-context
  [context : OptCfgContext]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (opt-licm-apply-loops
    (struct-get context index)
    (opt-cfg-natural-loops-with-context blocks context)
    blocks))

(define (opt-licm-blocks [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (opt-licm-blocks-with-context (opt-cfg-context-build blocks) blocks))

(define (opt-licm-function-with-context
  [context : OptCfgContext]
  [func : CompilerIrFunction]) : CompilerIrFunction
  (match (opt-verify-function-with-context func context)
    [(OkCompilerOptimizeVerify)
      (match func
        [(IrFunction name params ret-ty frame blocks)
          (let
            [hoisted-blocks : CompilerIrBlockList
              (opt-licm-blocks-with-context context blocks)]
            [hoisted : CompilerIrFunction
              (IrFunction name params ret-ty frame hoisted-blocks)]
            (match (opt-verify-function hoisted)
              [(OkCompilerOptimizeVerify) hoisted]
              [(ErrCompilerOptimizeVerify _) func]))])]
    [(ErrCompilerOptimizeVerify _) func]))

(define (opt-licm-function [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(IrFunction _ _ _ _ blocks)
      (opt-licm-function-with-context (opt-cfg-context-build blocks) func)]))

;; --- simple induction-derived cleanup (#1802) ------------------------------
;;
;; This first induction slice recognizes canonical `i64` loop-carried phis:
;; `i = phi(preheader_seed, latch_next)` where `latch_next` is `i +/- const`.
;; It then strength-reduces one repeated derived offset/address family per loop
;; by adding a matching derived phi. The pass deliberately rejects loops with
;; stores, calls, allocation, or unknown-effect instructions and leaves bounds
;; checks in place. The function verifier gates the final rewritten function.
(defenum OptInductionPhiInputs
  (OptNoInductionPhiInputs)
  (OptSomeInductionPhiInputs CompilerIrValue i64))

(defenum OptInductionFact
  (OptInductionFact i64 CompilerIrValue i64 i64 AstType))

(defenum OptMaybeInductionFact
  (OptNoInductionFact)
  (OptSomeInductionFact OptInductionFact))

(defenum OptInductionDerived
  (OptInductionDerivedMul i64 AstType)
  (OptInductionDerivedGep CompilerIrValue AstType))

(defenum OptInductionLoopCandidate
  (OptNoInductionLoopCandidate)
  (OptSomeInductionLoopCandidate OptInductionFact OptInductionDerived))

(defenum OptInductionApplyResult
  (OptInductionApplyResult CompilerIrBlockList i64 bool))

(define (opt-induction-fact-start [fact : OptInductionFact]) : CompilerIrValue
  (match fact
    [(OptInductionFact _ start _ _ _) start]))

(define (opt-induction-fact-step [fact : OptInductionFact]) : i64
  (match fact
    [(OptInductionFact _ _ _ step _) step]))

(define (opt-induction-i64-type? [ty : AstType]) : bool
  (match ty
    [(AstTyI64) true]
    [_ false]))

(define (opt-induction-nonzero-step [step : i64]) : OptMaybeI64
  (if (= step 0)
    (OptNoI64)
    (OptSomeI64 step)))

(define (opt-induction-phi-input-pair
  [a-value : CompilerIrValue]
  [a-label : String]
  [b-value : CompilerIrValue]
  [b-label : String]
  [preheader : String]
  [latch : String]) : OptInductionPhiInputs
  (if (and (string-eq a-label preheader) (string-eq b-label latch))
    (match b-value
      [(IrValueVar back) (OptSomeInductionPhiInputs a-value back)]
      [_ (OptNoInductionPhiInputs)])
    (if (and (string-eq b-label preheader) (string-eq a-label latch))
      (match a-value
        [(IrValueVar back) (OptSomeInductionPhiInputs b-value back)]
        [_ (OptNoInductionPhiInputs)])
      (OptNoInductionPhiInputs))))

(define (opt-induction-phi-inputs
  [inputs : CompilerIrPhiInputList]
  [preheader : String]
  [latch : String]) : OptInductionPhiInputs
  (match inputs
    [(IrPhiInputCons a-value a-label rest)
      (match (box-get rest)
        [(IrPhiInputCons b-value b-label rest2)
          (match (box-get rest2)
            [(IrPhiInputNil)
              (opt-induction-phi-input-pair
                a-value
                a-label
                b-value
                b-label
                preheader
                latch)]
            [_ (OptNoInductionPhiInputs)])]
        [_ (OptNoInductionPhiInputs)])]
    [_ (OptNoInductionPhiInputs)]))

(define (opt-induction-step-from-add
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [phi-var : i64]) : OptMaybeI64
  (match lhs
    [(IrValueVar var)
      (if (= var phi-var)
        (match rhs
          [(IrValueI64 step) (opt-induction-nonzero-step step)]
          [_ (OptNoI64)])
        (OptNoI64))]
    [(IrValueI64 step)
      (match rhs
        [(IrValueVar var)
          (if (= var phi-var)
            (opt-induction-nonzero-step step)
            (OptNoI64))]
        [_ (OptNoI64)])]
    [_ (OptNoI64)]))

(define (opt-induction-step-from-sub
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [phi-var : i64]) : OptMaybeI64
  (match lhs
    [(IrValueVar var)
      (if (= var phi-var)
        (match rhs
          [(IrValueI64 step) (opt-induction-nonzero-step (- 0 step))]
          [_ (OptNoI64)])
        (OptNoI64))]
    [_ (OptNoI64)]))

(define (opt-induction-step-from-binop
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [phi-var : i64]) : OptMaybeI64
  (match op
    [(IrBinAdd) (opt-induction-step-from-add lhs rhs phi-var)]
    [(IrBinSub) (opt-induction-step-from-sub lhs rhs phi-var)]
    [_ (OptNoI64)]))

(define (opt-induction-update-step-instr
  [instr : CompilerIrInstr]
  [phi-var : i64]
  [next-var : i64]
  [ty : AstType]) : OptMaybeI64
  (match instr
    [(IrInstrBinOp dst op lhs rhs instr-ty)
      (if (and
        (= dst next-var)
        (and (opt-type-eq instr-ty ty) (opt-induction-i64-type? ty)))
        (opt-induction-step-from-binop op lhs rhs phi-var)
        (OptNoI64))]
    [_ (OptNoI64)]))

(define (opt-induction-find-update-instrs
  [instrs : CompilerIrInstrList]
  [phi-var : i64]
  [next-var : i64]
  [ty : AstType]) : OptMaybeI64
  (match instrs
    [(IrInstrNil) (OptNoI64)]
    [(IrInstrCons instr rest)
      (match (opt-instr-def-var instr)
        [(OptSomeI64 dst)
          (if (= dst next-var)
            (opt-induction-update-step-instr instr phi-var next-var ty)
            (opt-induction-find-update-instrs
              (box-get rest)
              phi-var
              next-var
              ty))]
        [(OptNoI64)
          (opt-induction-find-update-instrs (box-get rest) phi-var next-var ty)])]))

(define (opt-induction-find-update-instr-seq-from
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [phi-var : i64]
  [next-var : i64]
  [ty : AstType]) : OptMaybeI64
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (OptNoI64)
    (let
      [instr : CompilerIrInstr (compiler-ir-instr-seq-ref instrs index)]
      (match (opt-instr-def-var instr)
        [(OptSomeI64 dst)
          (if (= dst next-var)
            (opt-induction-update-step-instr instr phi-var next-var ty)
            (opt-induction-find-update-instr-seq-from
              instrs
              (+ index 1)
              phi-var
              next-var
              ty))]
        [(OptNoI64)
          (opt-induction-find-update-instr-seq-from
            instrs
            (+ index 1)
            phi-var
            next-var
            ty)]))))

(define (opt-induction-find-update-instr-seq
  [instrs : CompilerIrInstrSeq]
  [phi-var : i64]
  [next-var : i64]
  [ty : AstType]) : OptMaybeI64
  (opt-induction-find-update-instr-seq-from instrs 0 phi-var next-var ty))

(define (opt-induction-find-update-blocks
  [body-blocks : CompilerIrBlockList]
  [phi-var : i64]
  [next-var : i64]
  [ty : AstType]) : OptMaybeI64
  (match body-blocks
    [(IrBlockNil) (OptNoI64)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (match (opt-induction-find-update-instr-seq
            instrs
            phi-var
            next-var
            ty)
            [(OptSomeI64 step) (OptSomeI64 step)]
            [(OptNoI64)
              (opt-induction-find-update-blocks
                (box-get rest)
                phi-var
                next-var
                ty)])])]
    [(IrBlockArray seq)
      (opt-induction-find-update-blocks
        (compiler-ir-block-seq-to-list seq)
        phi-var
        next-var
        ty)]))

(define (opt-induction-fact-from-phi
  [body-blocks : CompilerIrBlockList]
  [loop : OptNaturalLoop]
  [preheader : String]
  [instr : CompilerIrInstr]) : OptMaybeInductionFact
  (match instr
    [(IrInstrPhi phi-var inputs ty)
      (if (opt-induction-i64-type? ty)
        (match (opt-induction-phi-inputs
          inputs
          preheader
          (opt-natural-loop-latch loop))
          [(OptSomeInductionPhiInputs start next-var)
            (match (opt-induction-find-update-blocks
              body-blocks
              phi-var
              next-var
              ty)
              [(OptSomeI64 step)
                (OptSomeInductionFact
                  (OptInductionFact phi-var start next-var step ty))]
              [(OptNoI64) (OptNoInductionFact)])]
          [(OptNoInductionPhiInputs) (OptNoInductionFact)])
        (OptNoInductionFact))]
    [_ (OptNoInductionFact)]))

(define (opt-induction-find-fact-instrs
  [body-blocks : CompilerIrBlockList]
  [loop : OptNaturalLoop]
  [preheader : String]
  [instrs : CompilerIrInstrList]) : OptMaybeInductionFact
  (match instrs
    [(IrInstrNil) (OptNoInductionFact)]
    [(IrInstrCons instr rest)
      (match (opt-induction-fact-from-phi body-blocks loop preheader instr)
        [(OptSomeInductionFact fact) (OptSomeInductionFact fact)]
        [(OptNoInductionFact)
          (opt-induction-find-fact-instrs
            body-blocks
            loop
            preheader
            (box-get rest))])]))

(define (opt-induction-find-fact-instr-seq-from
  [body-blocks : CompilerIrBlockList]
  [loop : OptNaturalLoop]
  [preheader : String]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : OptMaybeInductionFact
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (OptNoInductionFact)
    (match (opt-induction-fact-from-phi
      body-blocks
      loop
      preheader
      (compiler-ir-instr-seq-ref instrs index))
      [(OptSomeInductionFact fact) (OptSomeInductionFact fact)]
      [(OptNoInductionFact)
        (opt-induction-find-fact-instr-seq-from
          body-blocks
          loop
          preheader
          instrs
          (+ index 1))])))

(define (opt-induction-find-fact-instr-seq
  [body-blocks : CompilerIrBlockList]
  [loop : OptNaturalLoop]
  [preheader : String]
  [instrs : CompilerIrInstrSeq]) : OptMaybeInductionFact
  (opt-induction-find-fact-instr-seq-from body-blocks loop preheader instrs 0))

(define (opt-induction-find-fact
  [body-blocks : CompilerIrBlockList]
  [loop : OptNaturalLoop]
  [preheader : String]) : OptMaybeInductionFact
  (match (opt-cfg-find-block body-blocks (opt-natural-loop-header loop))
    [(OptSomeBlock block)
      (match block
        [(IrBlock _ instrs)
          (opt-induction-find-fact-instr-seq body-blocks loop preheader instrs)])]
    [(OptNoBlock) (OptNoInductionFact)]))

(define (opt-induction-blocker-instr? [instr : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrAlloc _ _) true]
    [(IrInstrStorePtr _ _ _) true]
    [(IrInstrCopyBytes _ _ _) true]
    [(IrInstrVectorStore _ _ _ _ _) true]
    [(IrInstrPredicatedStore _ _ _ _ _ _) true]
    [(IrInstrCpuId _ _ _ _) true]
    [(IrInstrXgetbv _ _) true]
    [(IrInstrSyscall _ _) true]
    [(IrInstrCall _ _ _ _) true]
    [(IrInstrCallIndirect _ _ _ _) true]
    [(IrInstrCallIndirectC _ _ _ _) true]
    [(IrInstrTailCall _ _ _) true]
    [(IrInstrStore _ _ _) true]
    [_ false]))

(define (opt-induction-blocker-instrs? [instrs : CompilerIrInstrList]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr rest)
      (or
        (opt-induction-blocker-instr? instr)
        (opt-induction-blocker-instrs? (box-get rest)))]))

(define (opt-induction-blocker-instr-seq-from?
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : bool
  (if (>= index (compiler-ir-instr-seq-count instrs))
    false
    (or
      (opt-induction-blocker-instr? (compiler-ir-instr-seq-ref instrs index))
      (opt-induction-blocker-instr-seq-from? instrs (+ index 1)))))

(define (opt-induction-blocker-instr-seq? [instrs : CompilerIrInstrSeq]) : bool
  (opt-induction-blocker-instr-seq-from? instrs 0))

(define (opt-induction-loop-blocked? [body-blocks : CompilerIrBlockList]) : bool
  (match body-blocks
    [(IrBlockNil) false]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (if (opt-induction-blocker-instr-seq? instrs)
            true
            (opt-induction-loop-blocked? (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-induction-loop-blocked? (compiler-ir-block-seq-to-list seq))]))

(define (opt-induction-small-const? [value : i64]) : bool
  (and (>= value (- 0 1000000)) (<= value 1000000)))

(define (opt-induction-scale-ok? [step : i64] [scale : i64]) : bool
  (and
    (not (= scale 0))
    (and
      (not (= scale 1))
      (and (opt-induction-small-const? step) (opt-induction-small-const? scale)))))

(define (opt-induction-mul-scale
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [phi-var : i64]
  [step : i64]) : OptMaybeI64
  (match lhs
    [(IrValueVar var)
      (if (= var phi-var)
        (match rhs
          [(IrValueI64 scale)
            (if (opt-induction-scale-ok? step scale)
              (OptSomeI64 scale)
              (OptNoI64))]
          [_ (OptNoI64)])
        (OptNoI64))]
    [(IrValueI64 scale)
      (match rhs
        [(IrValueVar var)
          (if (and (= var phi-var) (opt-induction-scale-ok? step scale))
            (OptSomeI64 scale)
            (OptNoI64))]
        [_ (OptNoI64)])]
    [_ (OptNoI64)]))

;; Induction runs without a hoisted set, so GEP-base loop-invariance is
;; `opt-licm-value-invariant?` with an empty `hoisted` map: a var is invariant
;; iff it is not defined inside the loop body. Evaluating it directly avoids
;; allocating an empty sentinel map per GEP candidate (#2337).
(define (opt-induction-value-base-invariant?
  [loop-defs : I64I64Map]
  [value : CompilerIrValue]) : bool
  (match value
    [(IrValueVar var) (not (opt-used-contains loop-defs var))]
    [_ true]))

(define (opt-induction-find-derived-instr
  [fact : OptInductionFact]
  [loop-defs : I64I64Map]
  [instr : CompilerIrInstr]) : OptInductionLoopCandidate
  (match fact
    [(OptInductionFact phi-var _ _ step _)
      (match instr
        [(IrInstrBinOp _ op lhs rhs ty)
          (match op
            [(IrBinMul)
              (if (opt-induction-i64-type? ty)
                (match (opt-induction-mul-scale lhs rhs phi-var step)
                  [(OptSomeI64 scale)
                    (OptSomeInductionLoopCandidate
                      fact
                      (OptInductionDerivedMul scale ty))]
                  [(OptNoI64) (OptNoInductionLoopCandidate)])
                (OptNoInductionLoopCandidate))]
            [_ (OptNoInductionLoopCandidate)])]
        [(IrInstrGep _ base offset ty)
          (match offset
            [(IrValueVar offset-var)
              (if (and
                (= offset-var phi-var)
                (opt-induction-value-base-invariant? loop-defs base))
                (OptSomeInductionLoopCandidate
                  fact
                  (OptInductionDerivedGep base ty))
                (OptNoInductionLoopCandidate))]
            [_ (OptNoInductionLoopCandidate)])]
        [_ (OptNoInductionLoopCandidate)])]))

(define (opt-induction-find-derived-instrs
  [fact : OptInductionFact]
  [loop-defs : I64I64Map]
  [instrs : CompilerIrInstrList]) : OptInductionLoopCandidate
  (match instrs
    [(IrInstrNil) (OptNoInductionLoopCandidate)]
    [(IrInstrCons instr rest)
      (match (opt-induction-find-derived-instr fact loop-defs instr)
        [(OptSomeInductionLoopCandidate found-fact kind)
          (OptSomeInductionLoopCandidate found-fact kind)]
        [(OptNoInductionLoopCandidate)
          (opt-induction-find-derived-instrs fact loop-defs (box-get rest))])]))

(define (opt-induction-find-derived-instr-seq-from
  [fact : OptInductionFact]
  [loop-defs : I64I64Map]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : OptInductionLoopCandidate
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (OptNoInductionLoopCandidate)
    (match (opt-induction-find-derived-instr
      fact
      loop-defs
      (compiler-ir-instr-seq-ref instrs index))
      [(OptSomeInductionLoopCandidate found-fact kind)
        (OptSomeInductionLoopCandidate found-fact kind)]
      [(OptNoInductionLoopCandidate)
        (opt-induction-find-derived-instr-seq-from
          fact
          loop-defs
          instrs
          (+ index 1))])))

(define (opt-induction-find-derived-instr-seq
  [fact : OptInductionFact]
  [loop-defs : I64I64Map]
  [instrs : CompilerIrInstrSeq]) : OptInductionLoopCandidate
  (opt-induction-find-derived-instr-seq-from fact loop-defs instrs 0))

(define (opt-induction-find-derived-blocks
  [fact : OptInductionFact]
  [loop-defs : I64I64Map]
  [body-blocks : CompilerIrBlockList]) : OptInductionLoopCandidate
  (match body-blocks
    [(IrBlockNil) (OptNoInductionLoopCandidate)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (match (opt-induction-find-derived-instr-seq fact loop-defs instrs)
            [(OptSomeInductionLoopCandidate found-fact kind)
              (OptSomeInductionLoopCandidate found-fact kind)]
            [(OptNoInductionLoopCandidate)
              (opt-induction-find-derived-blocks fact loop-defs (box-get rest))])])]
    [(IrBlockArray seq)
      (opt-induction-find-derived-blocks
        fact
        loop-defs
        (compiler-ir-block-seq-to-list seq))]))

(define (opt-induction-derived-type [derived : OptInductionDerived]) : AstType
  (match derived
    [(OptInductionDerivedMul _ ty) ty]
    [(OptInductionDerivedGep _ ty) ty]))

(define (opt-induction-derived-matches?
  [fact : OptInductionFact]
  [derived : OptInductionDerived]
  [instr : CompilerIrInstr]) : bool
  (match fact
    [(OptInductionFact phi-var _ _ step _)
      (match derived
        [(OptInductionDerivedMul scale ty)
          (match instr
            [(IrInstrBinOp _ op lhs rhs instr-ty)
              (match op
                [(IrBinMul)
                  (and
                    (opt-type-eq instr-ty ty)
                    (match (opt-induction-mul-scale lhs rhs phi-var step)
                      [(OptSomeI64 found-scale) (= found-scale scale)]
                      [(OptNoI64) false]))]
                [_ false])]
            [_ false])]
        [(OptInductionDerivedGep base ty)
          (match instr
            [(IrInstrGep _ instr-base offset instr-ty)
              (and
                (opt-type-eq instr-ty ty)
                (and
                  (opt-value-eq instr-base base)
                  (match offset
                    [(IrValueVar offset-var) (= offset-var phi-var)]
                    [_ false])))]
            [_ false])])]))

(define (opt-induction-rewrite-instr
  [fact : OptInductionFact]
  [derived : OptInductionDerived]
  [derived-phi : i64]
  [instr : CompilerIrInstr]) : CompilerIrInstr
  (if (opt-induction-derived-matches? fact derived instr)
    (match (opt-instr-def-var instr)
      [(OptSomeI64 dst)
        (IrInstrMov
          dst
          (IrValueVar derived-phi)
          (opt-induction-derived-type derived))]
      [(OptNoI64) instr])
    instr))

(define (opt-induction-rewrite-instrs
  [fact : OptInductionFact]
  [derived : OptInductionDerived]
  [derived-phi : i64]
  [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (compiler-ir-instr-cons
        (opt-induction-rewrite-instr fact derived derived-phi instr)
        (opt-induction-rewrite-instrs fact derived derived-phi (box-get rest)))]))

(define (opt-induction-rewrite-instr-seq-from
  [fact : OptInductionFact]
  [derived : OptInductionDerived]
  [derived-phi : i64]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : CompilerIrInstrList
  (if (>= index (compiler-ir-instr-seq-count instrs))
    IrInstrNil
    (compiler-ir-instr-cons
      (opt-induction-rewrite-instr
        fact
        derived
        derived-phi
        (compiler-ir-instr-seq-ref instrs index))
      (opt-induction-rewrite-instr-seq-from
        fact
        derived
        derived-phi
        instrs
        (+ index 1)))))

(define (opt-induction-rewrite-instr-seq
  [fact : OptInductionFact]
  [derived : OptInductionDerived]
  [derived-phi : i64]
  [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (opt-induction-rewrite-instr-seq-from fact derived derived-phi instrs 0))

(define (opt-induction-rewrite-blocks
  [body : OptLoopBody]
  [index : OptCfgIndex]
  [fact : OptInductionFact]
  [derived : OptInductionDerived]
  [derived-phi : i64]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (compiler-ir-block-cons
            (if (opt-loop-body-label-member? body index label)
              (compiler-ir-block
                label
                (opt-induction-rewrite-instr-seq
                  fact
                  derived
                  derived-phi
                  instrs))
              block)
            (opt-induction-rewrite-blocks
              body
              index
              fact
              derived
              derived-phi
              (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-induction-rewrite-blocks
        body
        index
        fact
        derived
        derived-phi
        (compiler-ir-block-seq-to-list seq))]))

(define (opt-induction-seed-instr
  [fact : OptInductionFact]
  [derived : OptInductionDerived]
  [seed-var : i64]) : CompilerIrInstr
  (match derived
    [(OptInductionDerivedMul scale ty)
      (IrInstrBinOp
        seed-var
        (IrBinMul)
        (opt-induction-fact-start fact)
        (IrValueI64 scale)
        ty)]
    [(OptInductionDerivedGep base ty)
      (IrInstrGep seed-var base (opt-induction-fact-start fact) ty)]))

(define (opt-induction-next-instr
  [fact : OptInductionFact]
  [derived : OptInductionDerived]
  [derived-phi : i64]
  [next-var : i64]) : CompilerIrInstr
  (match derived
    [(OptInductionDerivedMul scale ty)
      (IrInstrBinOp
        next-var
        (IrBinAdd)
        (IrValueVar derived-phi)
        (IrValueI64 (* (opt-induction-fact-step fact) scale))
        ty)]
    [(OptInductionDerivedGep _ ty)
      (IrInstrGep
        next-var
        (IrValueVar derived-phi)
        (IrValueI64 (opt-induction-fact-step fact))
        ty)]))

(define (opt-induction-phi-instr
  [derived : OptInductionDerived]
  [preheader : String]
  [latch : String]
  [seed-var : i64]
  [derived-phi : i64]
  [next-var : i64]) : CompilerIrInstr
  (IrInstrPhi
    derived-phi
    (compiler-ir-phi-input-cons
      (IrValueVar seed-var)
      preheader
      (compiler-ir-phi-input-cons (IrValueVar next-var) latch (IrPhiInputNil)))
    (opt-induction-derived-type derived)))

(define (opt-induction-insert-support-blocks
  [header : String]
  [preheader : String]
  [latch : String]
  [seed-instr : CompilerIrInstr]
  [phi-instr : CompilerIrInstr]
  [next-instr : CompilerIrInstr]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (let
            [list-instrs : CompilerIrInstrList
              (opt-aggregate-instr-seq-append-from instrs 0 IrInstrNil)]
            [with-phi : CompilerIrInstrList
              (if (string-eq label header)
                (compiler-ir-instr-cons phi-instr list-instrs)
                list-instrs)]
            [with-seed : CompilerIrInstrList
              (if (string-eq label preheader)
                (opt-licm-insert-before-terminator
                  (compiler-ir-instr-cons seed-instr IrInstrNil)
                  with-phi)
                with-phi)]
            [with-next : CompilerIrInstrList
              (if (string-eq label latch)
                (opt-licm-insert-before-terminator
                  (compiler-ir-instr-cons next-instr IrInstrNil)
                  with-seed)
                with-seed)]
            (compiler-ir-block-cons
              (compiler-ir-block label with-next)
              (opt-induction-insert-support-blocks
                header
                preheader
                latch
                seed-instr
                phi-instr
                next-instr
                (box-get rest))))])]
    [(IrBlockArray seq)
      (opt-induction-insert-support-blocks
        header
        preheader
        latch
        seed-instr
        phi-instr
        next-instr
        (compiler-ir-block-seq-to-list seq))]))

(define (opt-induction-apply-loop
  [index : OptCfgIndex]
  [blocks : CompilerIrBlockList]
  [frame : i64]
  [loop : OptNaturalLoop]) : OptInductionApplyResult
  (match (opt-natural-loop-preheader loop)
    [(OptSomeLoopPreheader preheader)
      (let
        [body : OptLoopBody (opt-natural-loop-body-info loop)]
        [body-blocks : CompilerIrBlockList
          (opt-natural-loop-current-body-blocks index loop blocks)]
        (if (opt-induction-loop-blocked? body-blocks)
          (OptInductionApplyResult blocks frame false)
          (match (opt-induction-find-fact body-blocks loop preheader)
            [(OptSomeInductionFact fact)
              (let
                [loop-defs : I64I64Map
                  (opt-licm-collect-defs-blocks
                    body-blocks
                    (i64-i64-map-with-capacity
                      (opt-licm-body-map-capacity body-blocks)))]
                (match (opt-induction-find-derived-blocks
                  fact
                  loop-defs
                  body-blocks)
                  [(OptSomeInductionLoopCandidate _ derived)
                    (let
                      [seed-var : i64 frame]
                      [derived-phi : i64 (+ frame 1)]
                      [next-var : i64 (+ frame 2)]
                      [rewritten : CompilerIrBlockList
                        (opt-induction-rewrite-blocks
                          body
                          index
                          fact
                          derived
                          derived-phi
                          blocks)]
                      [seed-instr : CompilerIrInstr
                        (opt-induction-seed-instr fact derived seed-var)]
                      [phi-instr : CompilerIrInstr
                        (opt-induction-phi-instr
                          derived
                          preheader
                          (opt-natural-loop-latch loop)
                          seed-var
                          derived-phi
                          next-var)]
                      [next-instr : CompilerIrInstr
                        (opt-induction-next-instr
                          fact
                          derived
                          derived-phi
                          next-var)]
                      (OptInductionApplyResult
                        (opt-induction-insert-support-blocks
                          (opt-natural-loop-header loop)
                          preheader
                          (opt-natural-loop-latch loop)
                          seed-instr
                          phi-instr
                          next-instr
                          rewritten)
                        (+ frame 3)
                        true))]
                  [(OptNoInductionLoopCandidate)
                    (OptInductionApplyResult blocks frame false)]))]
            [(OptNoInductionFact) (OptInductionApplyResult blocks frame false)])))]
    [(OptNoLoopPreheader) (OptInductionApplyResult blocks frame false)]))

(define (opt-induction-apply-loops
  [index : OptCfgIndex]
  [loops : OptNaturalLoopList]
  [blocks : CompilerIrBlockList]
  [frame : i64]
  [changed : bool]) : OptInductionApplyResult
  (match loops
    [(OptNaturalLoopNil) (OptInductionApplyResult blocks frame changed)]
    [(OptNaturalLoopCons loop rest)
      (match (opt-induction-apply-loop index blocks frame loop)
        [(OptInductionApplyResult next-blocks next-frame loop-changed)
          (opt-induction-apply-loops
            index
            (box-get rest)
            next-blocks
            next-frame
            (or changed loop-changed))])]))

(define (opt-induction-function-with-context
  [context : OptCfgContext]
  [func : CompilerIrFunction]) : CompilerIrFunction
  (match (opt-verify-function-with-context func context)
    [(OkCompilerOptimizeVerify)
      (match func
        [(IrFunction name params ret-ty frame blocks)
          (match (opt-induction-apply-loops
            (struct-get context index)
            (opt-cfg-natural-loops-with-context blocks context)
            blocks
            frame
            false)
            [(OptInductionApplyResult next-blocks next-frame changed)
              (if changed
                (let
                  [next : CompilerIrFunction
                    (IrFunction name params ret-ty next-frame next-blocks)]
                  (match (opt-verify-function next)
                    [(OkCompilerOptimizeVerify) next]
                    [(ErrCompilerOptimizeVerify _) func]))
                func)])])]
    [(ErrCompilerOptimizeVerify _) func]))

(define (opt-induction-function [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(IrFunction _ _ _ _ blocks)
      (opt-induction-function-with-context (opt-cfg-context-build blocks) func)]))

(define (opt-cfg-filter-phi-inputs
  [reachable : OptLabelSet]
  [inputs : CompilerIrPhiInputList]) : CompilerIrPhiInputList
  (match inputs
    [(IrPhiInputNil) (IrPhiInputNil)]
    [(IrPhiInputCons value label rest)
      (if (opt-label-contains reachable label)
        (compiler-ir-phi-input-cons
          value
          label
          (opt-cfg-filter-phi-inputs reachable (box-get rest)))
        (opt-cfg-filter-phi-inputs reachable (box-get rest)))]))

(define (opt-phi-input-count [inputs : CompilerIrPhiInputList]) : i64
  (match inputs
    [(IrPhiInputNil) 0]
    [(IrPhiInputCons _ _ rest) (+ 1 (opt-phi-input-count (box-get rest)))]))

(define (opt-phi-single-value [inputs : CompilerIrPhiInputList]) : CompilerIrMaybeValue
  (match inputs
    [(IrPhiInputCons value _ rest)
      (match (box-get rest)
        [(IrPhiInputNil) (IrSomeValue value)]
        [_ (IrNoValue)])]
    [_ (IrNoValue)]))

(define (opt-cfg-clean-instr
  [reachable : OptLabelSet]
  [instr : CompilerIrInstr]) : CompilerIrInstr
  (match instr
    [(IrInstrPhi dst inputs ty)
      (let
        [kept : CompilerIrPhiInputList
          (opt-cfg-filter-phi-inputs reachable inputs)]
        (if (= (opt-phi-input-count kept) 1)
          (match (opt-phi-single-value kept)
            [(IrSomeValue value)
              (if (opt-value-is-var? value dst)
                (IrInstrPhi dst kept ty)
                (IrInstrMov dst value ty))]
            [(IrNoValue) (IrInstrPhi dst kept ty)])
          (IrInstrPhi dst kept ty)))]
    [_ instr]))

(define (opt-cfg-clean-instr-seq
  [reachable : OptLabelSet]
  [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [index : i64 (- (struct-get instrs len) 1)]
    [out : CompilerIrInstrList IrInstrNil]
    (begin
      (while (>= index 0)
        (begin
          (set!
            out
            (compiler-ir-instr-cons
              (opt-cfg-clean-instr reachable (array-ref slots index))
              out))
          (set! index (- index 1))))
      out)))

(define (opt-cfg-clean-block
  [reachable : OptLabelSet]
  [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      (compiler-ir-block label (opt-cfg-clean-instr-seq reachable instrs))]))

(define (opt-cfg-filter-clean-blocks
  [reachable : OptLabelSet]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _)
          (if (opt-label-contains reachable label)
            (compiler-ir-block-cons
              (opt-cfg-clean-block reachable block)
              (opt-cfg-filter-clean-blocks reachable (box-get rest)))
            (opt-cfg-filter-clean-blocks reachable (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-cfg-filter-clean-blocks
        reachable
        (compiler-ir-block-seq-to-list seq))]))

(define (opt-cfg-simplify-blocks [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (let
    [folded : CompilerIrBlockList (opt-cfg-fold-branches-blocks blocks)]
    [reachable : OptLabelSet (opt-cfg-reachable-blocks folded)]
    (opt-cfg-filter-clean-blocks reachable folded)))

;; --- sparse conditional constant propagation (#1348) -----------------------
;;
;; SCCP v1 runs after the local scalar simplifier. It keeps a small scalar
;; lattice for SSA vars and a growing set of executable blocks. Unknown values
;; are not rewritten; overdefined values keep the original instruction; proven
;; constants rewrite value uses and scalar-producing instructions. The evaluator
;; deliberately reuses the local folding helpers above so divide/modulo/shift
;; trap preservation stays identical.
(defenum OptSccpValue
  (OptSccpUnknown)
  (OptSccpConst CompilerIrValue AstType)
  (OptSccpOverdefined))

;; #2357 (orig #2386 2951f920): the SCCP lattice was a persistent assoc list
;; (OptSccpEnvCons id value rest) where opt-sccp-env-set rebuilt the WHOLE list on
;; every bind (via opt-sccp-env-remove) -> O(V) alloc per bind, O(V^2) per analysis
;; sweep, x fixpoint sweeps x all functions (~42s / ~12GB of the -O2 optimize
;; phase). The lattice is a single monotonically-rising map threaded linearly
;; through analysis (never branched), so it is now a mutable array indexed by var
;; id: O(1) lookup/set, no rebuild. Var ids are dense within a function; the array
;; is sized to cover every bound var (params + every instruction dst that
;; opt-sccp-process-instr binds). Out-of-range lookups return Unknown (the same
;; default the list gave for an unbound var), so the analysis result -- and the
;; folded output -- is byte-identical.
(defenum OptSccpEnv
  (OptSccpEnv i64 (Array OptSccpValue)))

(define (opt-sccp-env-fill-unknown!
  [slots : (Array OptSccpValue)]
  [n : i64]
  [i : i64]) : unit
  (if (>= i n)
    unit
    (begin
      (array-set! slots i (OptSccpUnknown))
      (opt-sccp-env-fill-unknown! slots n (+ i 1)))))

(define (opt-sccp-env-make [cap : i64]) : OptSccpEnv
  (let
    [n : i64 (if (< cap 1) 1 cap)]
    [slots : (Array OptSccpValue) (make-array OptSccpValue n)]
    (begin
      (opt-sccp-env-fill-unknown! slots n 0)
      (OptSccpEnv n slots))))

;; Destination var bound by `opt-sccp-process-instr`, or -1 for instructions that
;; bind nothing. MUST mirror the binding arms of opt-sccp-process-instr so the
;; environment array is sized to cover every var the analysis can bind.
(define (opt-sccp-instr-dst [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrMov dst _ _) dst]
    [(IrInstrCast dst _ _ _) dst]
    [(IrInstrBinOp dst _ _ _ _) dst]
    [(IrInstrUnOp dst _ _ _) dst]
    [(IrInstrPhi dst _ _) dst]
    [(IrInstrAlloc dst _) dst]
    [(IrInstrAddrOf dst _) dst]
    [(IrInstrGep dst _ _ _) dst]
    [(IrInstrLoad dst _ _) dst]
    [(IrInstrEntryArgc dst) dst]
    [(IrInstrEntryArgv dst) dst]
    [(IrInstrEntryEnvp dst) dst]
    [(IrInstrCpuId dst _ _ _) dst]
    [(IrInstrXgetbv dst _) dst]
    [(IrInstrSyscall dst _) dst]
    [(IrInstrLaneId dst _ _) dst]
    [(IrInstrSplat dst _ _ _) dst]
    [(IrInstrVectorBinOp dst _ _ _ _ _) dst]
    [(IrInstrVectorReduce dst _ _ _ _) dst]
    [(IrInstrVectorCompare dst _ _ _ _ _) dst]
    [(IrInstrMaskBinOp dst _ _ _ _) dst]
    [(IrInstrMaskNot dst _ _) dst]
    [(IrInstrMaskReduce dst _ _ _) dst]
    [(IrInstrSelect dst _ _ _ _ _) dst]
    [(IrInstrVectorLoad dst _ _ _ _) dst]
    [(IrInstrPredicatedLoad dst _ _ _ _ _) dst]
    [(IrInstrTailMask dst _ _ _) dst]
    [(IrInstrCall dst _ _ _) dst]
    [(IrInstrCallIndirect dst _ _ _) dst]
    [(IrInstrCallIndirectC dst _ _ _) dst]
    [_ (- 0 1)]))

(define (opt-sccp-max-var-instr-seq
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [acc : i64]) : i64
  (if (>= index (compiler-ir-instr-seq-count instrs))
    acc
    (let
      [dst : i64 (opt-sccp-instr-dst (compiler-ir-instr-seq-ref instrs index))]
      (opt-sccp-max-var-instr-seq
        instrs
        (+ index 1)
        (if (> dst acc) dst acc)))))

(define (opt-sccp-max-var-blocks
  [blocks : CompilerIrBlockList]
  [acc : i64]) : i64
  (match blocks
    [(IrBlockNil) acc]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (opt-sccp-max-var-blocks
            (box-get rest)
            (opt-sccp-max-var-instr-seq instrs 0 acc))])]))

(define (opt-sccp-max-var-params
  [params : CompilerIrParamList]
  [acc : i64]) : i64
  (match params
    [(IrParamNil) acc]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ _ id)
          (opt-sccp-max-var-params (box-get rest) (if (> id acc) id acc))])]))

(defenum OptSccpState
  (OptSccpState OptLabelSet OptSccpEnv bool))

(define (opt-sccp-value-eq [a : OptSccpValue] [b : OptSccpValue]) : bool
  (match a
    [(OptSccpUnknown)
      (match b
        [(OptSccpUnknown) true]
        [_ false])]
    [(OptSccpOverdefined)
      (match b
        [(OptSccpOverdefined) true]
        [_ false])]
    [(OptSccpConst av aty)
      (match b
        [(OptSccpConst bv bty) (and (opt-value-eq av bv) (opt-type-eq aty bty))]
        [_ false])]))

(define (opt-sccp-join [old : OptSccpValue] [new : OptSccpValue]) : OptSccpValue
  (match old
    [(OptSccpUnknown) new]
    [(OptSccpOverdefined) (OptSccpOverdefined)]
    [(OptSccpConst old-value old-ty)
      (match new
        [(OptSccpUnknown) old]
        [(OptSccpOverdefined) (OptSccpOverdefined)]
        [(OptSccpConst new-value new-ty)
          (if (and
            (opt-value-eq old-value new-value)
            (opt-type-eq old-ty new-ty))
            old
            (OptSccpOverdefined))])]))

(define (opt-sccp-env-lookup [env : OptSccpEnv] [var : i64]) : OptSccpValue
  (match env
    [(OptSccpEnv cap slots)
      (if (if (>= var 0) (< var cap) false)
        (array-ref slots var)
        (OptSccpUnknown))]))

;; Mutates the shared lattice array in place and returns the same env. The
;; environment is threaded linearly through the monotone analysis, so in-place
;; update is observationally identical to the old persistent cons/remove.
(define (opt-sccp-env-set [env : OptSccpEnv] [var : i64] [value : OptSccpValue]) : OptSccpEnv
  (match env
    [(OptSccpEnv cap slots)
      (begin
        (if (if (>= var 0) (< var cap) false)
          (array-set! slots var value)
          unit)
        env)]))

(define (opt-sccp-state-bind
  [state : OptSccpState]
  [var : i64]
  [value : OptSccpValue]) : OptSccpState
  (match state
    [(OptSccpState executable env changed)
      (let
        [old : OptSccpValue (opt-sccp-env-lookup env var)]
        [merged : OptSccpValue (opt-sccp-join old value)]
        (if (opt-sccp-value-eq old merged)
          state
          (OptSccpState executable (opt-sccp-env-set env var merged) true)))]))

(define (opt-sccp-state-mark-executable [state : OptSccpState] [label : String]) : OptSccpState
  (match state
    [(OptSccpState executable env changed)
      (if (opt-label-contains executable label)
        state
        (OptSccpState (opt-label-add executable label) env true))]))

(define (opt-sccp-state-reset-changed [state : OptSccpState]) : OptSccpState
  (match state
    [(OptSccpState executable env _) (OptSccpState executable env false)]))

(define (opt-sccp-immediate [value : CompilerIrValue] [ty : AstType]) : OptSccpValue
  (match (opt-normalize-const value (opt-default-immediate-type value ty))
    [(OptSomeConst folded folded-ty) (OptSccpConst folded folded-ty)]
    [(OptNoConst) (OptSccpOverdefined)]))

(define (opt-sccp-value
  [state : OptSccpState]
  [value : CompilerIrValue]
  [ty : AstType]) : OptSccpValue
  (match state
    [(OptSccpState _ env _)
      (match value
        [(IrValueVar id) (opt-sccp-env-lookup env id)]
        [_ (opt-sccp-immediate value ty)])]))

(define (opt-sccp-fold-cast-value
  [src : OptSccpValue]
  [from-ty : AstType]
  [to-ty : AstType]) : OptSccpValue
  (match src
    [(OptSccpUnknown) (OptSccpUnknown)]
    [(OptSccpOverdefined) (OptSccpOverdefined)]
    [(OptSccpConst value ty)
      (match (opt-fold-cast (OptSomeConst value ty) from-ty to-ty)
        [(IrSomeValue folded) (OptSccpConst folded to-ty)]
        [(IrNoValue) (OptSccpOverdefined)])]))

(define (opt-sccp-fold-binop-value
  [op : CompilerIrBinOp]
  [lhs : OptSccpValue]
  [rhs : OptSccpValue]
  [ty : AstType]) : OptSccpValue
  (match lhs
    [(OptSccpConst lhs-value lhs-ty)
      (match rhs
        [(OptSccpConst rhs-value rhs-ty)
          (match (opt-fold-binop
            op
            (OptSomeConst lhs-value lhs-ty)
            (OptSomeConst rhs-value rhs-ty)
            ty)
            [(IrSomeValue folded) (OptSccpConst folded ty)]
            [(IrNoValue) (OptSccpOverdefined)])]
        [(OptSccpUnknown) (OptSccpUnknown)]
        [(OptSccpOverdefined) (OptSccpOverdefined)])]
    [(OptSccpUnknown) (OptSccpUnknown)]
    [(OptSccpOverdefined) (OptSccpOverdefined)]))

(define (opt-sccp-fold-unop-value
  [op : CompilerIrUnOp]
  [src : OptSccpValue]
  [ty : AstType]) : OptSccpValue
  (match src
    [(OptSccpConst value value-ty)
      (match (opt-fold-unop op (OptSomeConst value value-ty) ty)
        [(IrSomeValue folded) (OptSccpConst folded ty)]
        [(IrNoValue) (OptSccpOverdefined)])]
    [(OptSccpUnknown) (OptSccpUnknown)]
    [(OptSccpOverdefined) (OptSccpOverdefined)]))

(define (opt-sccp-phi-input-value
  [state : OptSccpState]
  [value : CompilerIrValue]
  [pred : String]
  [ty : AstType]) : OptSccpValue
  (match state
    [(OptSccpState executable _ _)
      (if (opt-label-contains executable pred)
        (opt-sccp-value state value ty)
        (OptSccpUnknown))]))

(define (opt-sccp-phi-value
  [state : OptSccpState]
  [inputs : CompilerIrPhiInputList]
  [ty : AstType]) : OptSccpValue
  (match inputs
    [(IrPhiInputNil) (OptSccpUnknown)]
    [(IrPhiInputCons value pred rest)
      (opt-sccp-join
        (opt-sccp-phi-input-value state value pred ty)
        (opt-sccp-phi-value state (box-get rest) ty))]))

(define (opt-sccp-mark-branch-targets
  [state : OptSccpState]
  [cond : CompilerIrValue]
  [true-label : String]
  [false-label : String]) : OptSccpState
  (match (opt-sccp-value state cond (AstTyBool))
    [(OptSccpConst value _)
      (match value
        [(IrValueBool known)
          (if known
            (opt-sccp-state-mark-executable state true-label)
            (opt-sccp-state-mark-executable state false-label))]
        [_
          (opt-sccp-state-mark-executable
            (opt-sccp-state-mark-executable state true-label)
            false-label)])]
    [(OptSccpOverdefined)
      (opt-sccp-state-mark-executable
        (opt-sccp-state-mark-executable state true-label)
        false-label)]
    [(OptSccpUnknown) state]))

(define (opt-sccp-process-instr
  [state : OptSccpState]
  [instr : CompilerIrInstr]) : OptSccpState
  (match instr
    [(IrInstrMov dst value ty)
      (opt-sccp-state-bind state dst (opt-sccp-value state value ty))]
    [(IrInstrCast dst src from-ty to-ty)
      (opt-sccp-state-bind
        state
        dst
        (opt-sccp-fold-cast-value
          (opt-sccp-value state src from-ty)
          from-ty
          to-ty))]
    [(IrInstrBinOp dst op lhs rhs ty)
      (opt-sccp-state-bind
        state
        dst
        (opt-sccp-fold-binop-value
          op
          (opt-sccp-value state lhs ty)
          (opt-sccp-value state rhs ty)
          ty))]
    [(IrInstrUnOp dst op value ty)
      (opt-sccp-state-bind
        state
        dst
        (opt-sccp-fold-unop-value op (opt-sccp-value state value ty) ty))]
    [(IrInstrPhi dst inputs ty)
      (opt-sccp-state-bind state dst (opt-sccp-phi-value state inputs ty))]
    [(IrInstrJump label) (opt-sccp-state-mark-executable state label)]
    [(IrInstrBranch cond true-label false-label)
      (opt-sccp-mark-branch-targets state cond true-label false-label)]
    [(IrInstrAlloc dst _) (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrAddrOf dst _) (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrGep dst _ _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrLoad dst _ _) (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrEntryArgc dst)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrEntryArgv dst)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrEntryEnvp dst)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrCpuId dst _ _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrXgetbv dst _) (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrSyscall dst _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrLaneId dst _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrSplat dst _ _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrVectorBinOp dst _ _ _ _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrVectorReduce dst _ _ _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrVectorCompare dst _ _ _ _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrMaskBinOp dst _ _ _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrMaskNot dst _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrMaskReduce dst _ _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrSelect dst _ _ _ _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrVectorLoad dst _ _ _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrPredicatedLoad dst _ _ _ _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrTailMask dst _ _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrCall dst _ _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrCallIndirect dst _ _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [(IrInstrCallIndirectC dst _ _ _)
      (opt-sccp-state-bind state dst (OptSccpOverdefined))]
    [_ state]))

(define (opt-sccp-process-instrs
  [state : OptSccpState]
  [instrs : CompilerIrInstrList]) : OptSccpState
  (match instrs
    [(IrInstrNil) state]
    [(IrInstrCons instr rest)
      (opt-sccp-process-instrs
        (opt-sccp-process-instr state instr)
        (box-get rest))]))

(define (opt-sccp-process-instr-seq-from
  [state : OptSccpState]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : OptSccpState
  (if (>= index (compiler-ir-instr-seq-count instrs))
    state
    (opt-sccp-process-instr-seq-from
      (opt-sccp-process-instr state (compiler-ir-instr-seq-ref instrs index))
      instrs
      (+ index 1))))

(define (opt-sccp-process-instr-seq
  [state : OptSccpState]
  [instrs : CompilerIrInstrSeq]) : OptSccpState
  (opt-sccp-process-instr-seq-from state instrs 0))

(define (opt-sccp-process-block
  [state : OptSccpState]
  [block : CompilerIrBlock]) : OptSccpState
  (match state
    [(OptSccpState executable _ _)
      (match block
        [(IrBlock label instrs)
          (if (opt-label-contains executable label)
            (opt-sccp-process-instr-seq state instrs)
            state)])]))

(define (opt-sccp-process-blocks
  [state : OptSccpState]
  [blocks : CompilerIrBlockList]) : OptSccpState
  (match blocks
    [(IrBlockNil) state]
    [(IrBlockCons block rest)
      (opt-sccp-process-blocks
        (opt-sccp-process-block state block)
        (box-get rest))]
    [(IrBlockArray seq)
      (opt-sccp-process-blocks state (compiler-ir-block-seq-to-list seq))]))

(define (opt-sccp-env-from-params
  [params : CompilerIrParamList]
  [env : OptSccpEnv]) : OptSccpEnv
  (match params
    [(IrParamNil) env]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ _ id)
          (opt-sccp-env-from-params
            (box-get rest)
            (opt-sccp-env-set env id (OptSccpOverdefined)))])]))

(define (opt-sccp-initial-state
  [params : CompilerIrParamList]
  [blocks : CompilerIrBlockList]) : OptSccpState
  (let
    [max-var : i64
      (opt-sccp-max-var-params params (opt-sccp-max-var-blocks blocks (- 0 1)))]
    (OptSccpState
      (opt-label-add (OptLabelNil) (opt-cfg-entry-label blocks))
      (opt-sccp-env-from-params params (opt-sccp-env-make (+ max-var 1)))
      true)))

(define (opt-sccp-analyze-fixed
  [blocks : CompilerIrBlockList]
  [state : OptSccpState]
  [remaining : i64]) : OptSccpState
  (if (<= remaining 0)
    state
    (let
      [next : OptSccpState
        (opt-sccp-process-blocks (opt-sccp-state-reset-changed state) blocks)]
      (match next
        [(OptSccpState _ _ changed)
          (if changed
            (opt-sccp-analyze-fixed blocks next (- remaining 1))
            next)]))))

(define (opt-sccp-analyze
  [params : CompilerIrParamList]
  [blocks : CompilerIrBlockList]) : OptSccpState
  (opt-sccp-analyze-fixed
    blocks
    (opt-sccp-initial-state params blocks)
    (+
      (+ (compiler-ir-block-list-count blocks) 8)
      (* 2 (compiler-ir-block-list-instruction-count blocks)))))

(define (opt-sccp-rewrite-value [env : OptSccpEnv] [value : CompilerIrValue]) : CompilerIrValue
  (match value
    [(IrValueVar id)
      (match (opt-sccp-env-lookup env id)
        [(OptSccpConst folded _) folded]
        [_ value])]
    [_ value]))

(define (opt-sccp-rewrite-maybe-value
  [env : OptSccpEnv]
  [value : CompilerIrMaybeValue]) : CompilerIrMaybeValue
  (match value
    [(IrNoValue) (IrNoValue)]
    [(IrSomeValue inner) (IrSomeValue (opt-sccp-rewrite-value env inner))]))

(define (opt-sccp-rewrite-value-list
  [env : OptSccpEnv]
  [values : CompilerIrValueList]) : CompilerIrValueList
  (match values
    [(IrValueNil) (IrValueNil)]
    [(IrValueCons value rest)
      (compiler-ir-value-cons
        (opt-sccp-rewrite-value env value)
        (opt-sccp-rewrite-value-list env (box-get rest)))]))

(define (opt-sccp-rewrite-call-args-array
  [env : OptSccpEnv]
  [src : (Array CompilerIrValue)]
  [dst : (Array CompilerIrValue)]
  [index : i64]) : unit
  (if (>= index (array-length src))
    unit
    (begin
      (array-set! dst index (opt-sccp-rewrite-value env (array-ref src index)))
      (opt-sccp-rewrite-call-args-array env src dst (+ index 1)))))

(define (opt-sccp-rewrite-call-args
  [env : OptSccpEnv]
  [args : CompilerIrCallArgs]) : CompilerIrCallArgs
  (match args
    [(IrCallArgsNil) (IrCallArgsNil)]
    [(IrCallArgsOne value) (IrCallArgsOne (opt-sccp-rewrite-value env value))]
    [(IrCallArgsTwo a b)
      (IrCallArgsTwo
        (opt-sccp-rewrite-value env a)
        (opt-sccp-rewrite-value env b))]
    [(IrCallArgsArray values)
      (let
        [out : (Array CompilerIrValue)
          (make-array CompilerIrValue (array-length values))]
        (begin
          (opt-sccp-rewrite-call-args-array env values out 0)
          (IrCallArgsArray out)))]))

(define (opt-sccp-rewrite-phi-inputs
  [env : OptSccpEnv]
  [inputs : CompilerIrPhiInputList]) : CompilerIrPhiInputList
  (match inputs
    [(IrPhiInputNil) (IrPhiInputNil)]
    [(IrPhiInputCons value label rest)
      (compiler-ir-phi-input-cons
        (opt-sccp-rewrite-value env value)
        label
        (opt-sccp-rewrite-phi-inputs env (box-get rest)))]))

(define (opt-sccp-rewrite-scalar-def
  [env : OptSccpEnv]
  [dst : i64]
  [ty : AstType]
  [fallback : CompilerIrInstr]) : CompilerIrInstr
  (match (opt-sccp-env-lookup env dst)
    [(OptSccpConst value _) (IrInstrMov dst value ty)]
    [_ fallback]))

(define (opt-sccp-rewrite-instr [env : OptSccpEnv] [instr : CompilerIrInstr]) : CompilerIrInstr
  (match instr
    [(IrInstrMov dst value ty)
      (opt-sccp-rewrite-scalar-def
        env
        dst
        ty
        (IrInstrMov dst (opt-sccp-rewrite-value env value) ty))]
    [(IrInstrGep dst base offset ty)
      (IrInstrGep
        dst
        (opt-sccp-rewrite-value env base)
        (opt-sccp-rewrite-value env offset)
        ty)]
    [(IrInstrLoad dst src ty)
      (IrInstrLoad dst (opt-sccp-rewrite-value env src) ty)]
    [(IrInstrStorePtr ptr value ty)
      (IrInstrStorePtr
        (opt-sccp-rewrite-value env ptr)
        (opt-sccp-rewrite-value env value)
        ty)]
    [(IrInstrCopyBytes dst src size)
      (IrInstrCopyBytes
        (opt-sccp-rewrite-value env dst)
        (opt-sccp-rewrite-value env src)
        size)]
    [(IrInstrCast dst src from-ty to-ty)
      (opt-sccp-rewrite-scalar-def
        env
        dst
        to-ty
        (IrInstrCast dst (opt-sccp-rewrite-value env src) from-ty to-ty))]
    [(IrInstrBinOp dst op lhs rhs ty)
      (opt-sccp-rewrite-scalar-def
        env
        dst
        ty
        (IrInstrBinOp
          dst
          op
          (opt-sccp-rewrite-value env lhs)
          (opt-sccp-rewrite-value env rhs)
          ty))]
    [(IrInstrUnOp dst op value ty)
      (opt-sccp-rewrite-scalar-def
        env
        dst
        ty
        (IrInstrUnOp dst op (opt-sccp-rewrite-value env value) ty))]
    [(IrInstrSplat dst value lanes ty)
      (IrInstrSplat dst (opt-sccp-rewrite-value env value) lanes ty)]
    [(IrInstrCall dst name args ty)
      (IrInstrCall dst name (opt-sccp-rewrite-call-args env args) ty)]
    [(IrInstrCallIndirect dst callee args ty)
      (IrInstrCallIndirect
        dst
        (opt-sccp-rewrite-value env callee)
        (opt-sccp-rewrite-call-args env args)
        ty)]
    [(IrInstrCallIndirectC dst callee args ty)
      (IrInstrCallIndirectC
        dst
        (opt-sccp-rewrite-value env callee)
        (opt-sccp-rewrite-call-args env args)
        ty)]
    [(IrInstrTailCall name args ty)
      (IrInstrTailCall name (opt-sccp-rewrite-call-args env args) ty)]
    [(IrInstrStore name value ty)
      (IrInstrStore name (opt-sccp-rewrite-value env value) ty)]
    [(IrInstrBoundsCheck index length ok-label)
      (IrInstrBoundsCheck
        (opt-sccp-rewrite-value env index)
        (opt-sccp-rewrite-value env length)
        ok-label)]
    [(IrInstrEntryArgc _) instr]
    [(IrInstrEntryArgv _) instr]
    [(IrInstrEntryEnvp _) instr]
    [(IrInstrCpuId dst leaf subleaf reg-index)
      (IrInstrCpuId
        dst
        (opt-sccp-rewrite-value env leaf)
        (opt-sccp-rewrite-value env subleaf)
        reg-index)]
    [(IrInstrXgetbv dst index)
      (IrInstrXgetbv dst (opt-sccp-rewrite-value env index))]
    [(IrInstrSyscall dst args)
      (IrInstrSyscall dst (opt-sccp-rewrite-call-args env args))]
    [(IrInstrBranch cond true-label false-label)
      (let
        [rewritten-cond : CompilerIrValue (opt-sccp-rewrite-value env cond)]
        (match rewritten-cond
          [(IrValueBool known)
            (if known
              (IrInstrJump true-label)
              (IrInstrJump false-label))]
          [_ (IrInstrBranch rewritten-cond true-label false-label)]))]
    [(IrInstrReturn value)
      (IrInstrReturn (opt-sccp-rewrite-maybe-value env value))]
    [(IrInstrPhi dst inputs ty)
      (opt-sccp-rewrite-scalar-def
        env
        dst
        ty
        (IrInstrPhi dst (opt-sccp-rewrite-phi-inputs env inputs) ty))]
    [(IrInstrVectorBinOp dst op lhs rhs lanes ty)
      (IrInstrVectorBinOp
        dst
        op
        (opt-sccp-rewrite-value env lhs)
        (opt-sccp-rewrite-value env rhs)
        lanes
        ty)]
    [(IrInstrVectorReduce dst op src lanes ty)
      (IrInstrVectorReduce dst op (opt-sccp-rewrite-value env src) lanes ty)]
    [(IrInstrVectorCompare dst op lhs rhs lanes ty)
      (IrInstrVectorCompare
        dst
        op
        (opt-sccp-rewrite-value env lhs)
        (opt-sccp-rewrite-value env rhs)
        lanes
        ty)]
    [(IrInstrMaskBinOp dst op lhs rhs lanes)
      (IrInstrMaskBinOp
        dst
        op
        (opt-sccp-rewrite-value env lhs)
        (opt-sccp-rewrite-value env rhs)
        lanes)]
    [(IrInstrMaskNot dst src lanes)
      (IrInstrMaskNot dst (opt-sccp-rewrite-value env src) lanes)]
    [(IrInstrMaskReduce dst op src lanes)
      (IrInstrMaskReduce dst op (opt-sccp-rewrite-value env src) lanes)]
    [(IrInstrSelect dst mask true-value false-value lanes ty)
      (IrInstrSelect
        dst
        (opt-sccp-rewrite-value env mask)
        (opt-sccp-rewrite-value env true-value)
        (opt-sccp-rewrite-value env false-value)
        lanes
        ty)]
    [(IrInstrVectorLoad dst base index lanes ty)
      (IrInstrVectorLoad
        dst
        (opt-sccp-rewrite-value env base)
        (opt-sccp-rewrite-value env index)
        lanes
        ty)]
    [(IrInstrVectorStore base index value lanes ty)
      (IrInstrVectorStore
        (opt-sccp-rewrite-value env base)
        (opt-sccp-rewrite-value env index)
        (opt-sccp-rewrite-value env value)
        lanes
        ty)]
    [(IrInstrPredicatedStore base index value mask lanes ty)
      (IrInstrPredicatedStore
        (opt-sccp-rewrite-value env base)
        (opt-sccp-rewrite-value env index)
        (opt-sccp-rewrite-value env value)
        (opt-sccp-rewrite-value env mask)
        lanes
        ty)]
    [(IrInstrPredicatedLoad dst base index mask lanes ty)
      (IrInstrPredicatedLoad
        dst
        (opt-sccp-rewrite-value env base)
        (opt-sccp-rewrite-value env index)
        (opt-sccp-rewrite-value env mask)
        lanes
        ty)]
    [(IrInstrTailMask dst index length lanes)
      (IrInstrTailMask
        dst
        (opt-sccp-rewrite-value env index)
        (opt-sccp-rewrite-value env length)
        lanes)]
    [(IrInstrAlloc _ _) instr]
    [(IrInstrAddrOf _ _) instr]
    [(IrInstrLaneId _ _ _) instr]
    [(IrInstrJump _) instr]
    ;; #2386: register-group ops carry no SCCP-constant operands to fold.
    [(IrInstrPack _ _ _) instr]
    [(IrInstrWord _ _ _ _) instr]))

(define (opt-sccp-rewrite-instrs
  [env : OptSccpEnv]
  [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (compiler-ir-instr-cons
        (opt-sccp-rewrite-instr env instr)
        (opt-sccp-rewrite-instrs env (box-get rest)))]))

(define (opt-sccp-rewrite-instr-seq-from
  [env : OptSccpEnv]
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [out : CompilerIrInstrList]) : CompilerIrInstrList
  (if (< index 0)
    out
    (opt-sccp-rewrite-instr-seq-from
      env
      instrs
      (- index 1)
      (compiler-ir-instr-cons
        (opt-sccp-rewrite-instr env (compiler-ir-instr-seq-ref instrs index))
        out))))

(define (opt-sccp-rewrite-instr-seq
  [env : OptSccpEnv]
  [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (opt-sccp-rewrite-instr-seq-from
    env
    instrs
    (- (compiler-ir-instr-seq-count instrs) 1)
    IrInstrNil))

(define (opt-sccp-rewrite-block [env : OptSccpEnv] [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      (compiler-ir-block label (opt-sccp-rewrite-instr-seq env instrs))]))

(define (opt-sccp-rewrite-blocks
  [env : OptSccpEnv]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (compiler-ir-block-cons
        (opt-sccp-rewrite-block env block)
        (opt-sccp-rewrite-blocks env (box-get rest)))]
    [(IrBlockArray seq)
      (opt-sccp-rewrite-blocks env (compiler-ir-block-seq-to-list seq))]))

(define (opt-sccp-blocks
  [params : CompilerIrParamList]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match (opt-sccp-analyze params blocks)
    [(OptSccpState _ env _)
      (opt-cfg-simplify-blocks (opt-sccp-rewrite-blocks env blocks))]))

(defenum OptFunctionPassResult
  (OptFunctionPassResult CompilerIrFunction bool))

(define (optimize-function-max-iterations) : i64
  2)

;; --- cross-block global value numbering (#1349) -----------------------------
;;
;; Block-local CSE (`opt-cse-instr`) and copy propagation already collapse
;; redundant pure scalar expressions within a single basic block. This pass
;; lifts that to dominated blocks: a pure `BinOp`/`UnOp` is replaced by a `Mov`
;; from an equal expression computed in a strictly dominating block, after which
;; the existing copy propagation/DCE remove the dead intermediate. The IR is
;; non-SSA, so a value computed in a dominating block is only reusable at a use
;; if neither the result nor any operand can be reassigned between the two
;; points. The conservative-but-sound v1 condition is "exactly one value source"
;; per var: the value-source count = number of definitions plus one if the var
;; is a function parameter. A var with exactly one source has a single,
;; unchanging value throughout the function, so dominance alone authorizes the
;; reuse. Vars with two or more sources (a reassigned local, or a parameter that
;; is later overwritten) are excluded. Only `BinOp`/`UnOp` over single-source
;; operands and a single-source result are numbered; loads, stores, allocations,
;; calls, and other effectful or many-sourced instructions are left untouched.
;; Phi inputs belong to predecessor edges and are never rewritten. Sibling
;; expressions never global-CSE because a join block is not strictly dominated by
;; either arm.
;; GVN value-source multiset: maps each def-site var id to how many times it is
;; defined (parameter seed + instruction destinations). A var is reusable across
;; dominance only when its count is exactly 1. Backed by I64I64Map for O(1)
;; membership; previously a linked list scanned O(n) per query inside the
;; per-instruction build and rewrite loops (O(n^2) per GVN pass).
;; The expression table itself is scoped by dominator-tree traversal: each block
;; rewrites against facts inherited from strict dominators, then pushes its own
;; original recordable expressions while visiting children and restores those
;; bucket heads on return. That makes the nearest dominating expression the
;; first same-key bucket entry, without a dominance scan during lookup.
(defenum OptGvnEntry
  (OptGvnEntry OptExprKey i64 i64))

(defenum OptGvnBucket
  (OptGvnBucketNil)
  (OptGvnBucketCons OptGvnEntry (Box OptGvnBucket)))

(defstruct OptGvnMap
  (buckets (Array OptGvnBucket)))

(defenum OptGvnScopeChange
  (OptGvnScopeChange i64 OptGvnBucket))

(defenum OptGvnScopeChanges
  (OptGvnScopeNil)
  (OptGvnScopeCons OptGvnScopeChange (Box OptGvnScopeChanges)))

(defenum OptGvnBlockResult
  (OptGvnNoBlock)
  (OptGvnSomeBlock CompilerIrBlock))

;; Number of times `var` appears as a definition site (instruction destination
;; or seeded parameter) in the collected value-source list.
(define (opt-gvn-count [sources : I64I64Map] [var : i64]) : i64
  (match (i64-i64-map-get sources var)
    [(I64I64MapFound n) n]
    [(I64I64MapMissing) 0]))

;; Record one more definition of `var` in the value-source multiset.
(define (opt-gvn-defs-add [sources : I64I64Map] [var : i64]) : I64I64Map
  (i64-i64-map-put sources var (+ 1 (opt-gvn-count sources var))))

;; A var is reusable across dominance only when it has exactly one value source.
(define (opt-gvn-stable-var? [sources : I64I64Map] [var : i64]) : bool
  (= (opt-gvn-count sources var) 1))

;; Operand values that hold a single unchanging value: literals and single-source
;; vars. Globals, global addresses, function references, and float/string
;; literals are excluded to match the existing copy-propagation conservatism.
(define (opt-gvn-value-stable? [sources : I64I64Map] [value : CompilerIrValue]) : bool
  (match value
    [(IrValueVar id) (opt-gvn-stable-var? sources id)]
    [(IrValueI64 _) true]
    [(IrValueBool _) true]
    [(IrValueChar _) true]
    [(IrValueUnit) true]
    [(IrValueF64 _) false]
    [(IrValueString _) false]
    [(IrValueGlobal _) false]
    [(IrValueGlobalAddr _) false]
    [(IrValueFunction _) false]))

;; The destination var of a defining instruction, or -1 for instructions that do
;; not define a var. Mirrors the instruction set handled by `opt-cse-instr`.
(define (opt-gvn-instr-dst [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrMov dst _ _) dst]
    [(IrInstrAlloc dst _) dst]
    [(IrInstrAddrOf dst _) dst]
    [(IrInstrGep dst _ _ _) dst]
    [(IrInstrLoad dst _ _) dst]
    [(IrInstrCast dst _ _ _) dst]
    [(IrInstrBinOp dst _ _ _ _) dst]
    [(IrInstrUnOp dst _ _ _) dst]
    [(IrInstrLaneId dst _ _) dst]
    [(IrInstrSplat dst _ _ _) dst]
    [(IrInstrVectorBinOp dst _ _ _ _ _) dst]
    [(IrInstrVectorReduce dst _ _ _ _) dst]
    [(IrInstrVectorCompare dst _ _ _ _ _) dst]
    [(IrInstrMaskBinOp dst _ _ _ _) dst]
    [(IrInstrMaskNot dst _ _) dst]
    [(IrInstrMaskReduce dst _ _ _) dst]
    [(IrInstrSelect dst _ _ _ _ _) dst]
    [(IrInstrVectorLoad dst _ _ _ _) dst]
    [(IrInstrPredicatedLoad dst _ _ _ _ _) dst]
    [(IrInstrTailMask dst _ _ _) dst]
    [(IrInstrEntryArgc dst) dst]
    [(IrInstrEntryArgv dst) dst]
    [(IrInstrEntryEnvp dst) dst]
    [(IrInstrCpuId dst _ _ _) dst]
    [(IrInstrXgetbv dst _) dst]
    [(IrInstrSyscall dst _) dst]
    [(IrInstrCall dst _ _ _) dst]
    [(IrInstrCallIndirect dst _ _ _) dst]
    [(IrInstrCallIndirectC dst _ _ _) dst]
    [(IrInstrPhi dst _ _) dst]
    [(IrInstrStorePtr _ _ _) (- 0 1)]
    [(IrInstrCopyBytes _ _ _) (- 0 1)]
    [(IrInstrBoundsCheck _ _ _) (- 0 1)]
    [(IrInstrVectorStore _ _ _ _ _) (- 0 1)]
    [(IrInstrPredicatedStore _ _ _ _ _ _) (- 0 1)]
    [(IrInstrTailCall _ _ _) (- 0 1)]
    [(IrInstrStore _ _ _) (- 0 1)]
    [(IrInstrJump _) (- 0 1)]
    [(IrInstrBranch _ _ _) (- 0 1)]
    [(IrInstrReturn _) (- 0 1)]
    ;; #2386: register-group ops define their dst.
    [(IrInstrPack dst _ _) dst]
    [(IrInstrWord dst _ _ _) dst]))

(define (opt-gvn-sources-params
  [params : CompilerIrParamList]
  [acc : I64I64Map]) : I64I64Map
  (match params
    [(IrParamNil) acc]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ _ id)
          (opt-gvn-sources-params (box-get rest) (opt-gvn-defs-add acc id))])]))

(define (opt-gvn-sources-instrs
  [instrs : CompilerIrInstrList]
  [acc : I64I64Map]) : I64I64Map
  (match instrs
    [(IrInstrNil) acc]
    [(IrInstrCons instr rest)
      (let
        [dst : i64 (opt-gvn-instr-dst instr)]
        (opt-gvn-sources-instrs
          (box-get rest)
          (if (= dst (- 0 1))
            acc
            (opt-gvn-defs-add acc dst))))]))

(define (opt-gvn-sources-instr-seq-from
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [acc : I64I64Map]) : I64I64Map
  (if (>= index (compiler-ir-instr-seq-count instrs))
    acc
    (let
      [dst : i64 (opt-gvn-instr-dst (compiler-ir-instr-seq-ref instrs index))]
      (opt-gvn-sources-instr-seq-from
        instrs
        (+ index 1)
        (if (= dst (- 0 1))
          acc
          (opt-gvn-defs-add acc dst))))))

(define (opt-gvn-sources-blocks
  [blocks : CompilerIrBlockList]
  [acc : I64I64Map]) : I64I64Map
  (match blocks
    [(IrBlockNil) acc]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (opt-gvn-sources-blocks
            (box-get rest)
            (opt-gvn-sources-instr-seq-from instrs 0 acc))])]
    [(IrBlockArray seq)
      (opt-gvn-sources-blocks (compiler-ir-block-seq-to-list seq) acc)]))

(define (opt-gvn-block-id [doms : OptDomInfo] [label : String]) : i64
  (match (opt-cfg-index-id (struct-get doms index) label)
    [(OptSomeI64 id) id]
    [(OptNoI64) (- 0 1)]))

(define (opt-gvn-recordable-instr?
  [instr : CompilerIrInstr]
  [sources : I64I64Map]) : bool
  (match instr
    [(IrInstrBinOp dst _ l r _)
      (and
        (opt-gvn-stable-var? sources dst)
        (and
          (opt-gvn-value-stable? sources l)
          (opt-gvn-value-stable? sources r)))]
    [(IrInstrUnOp dst _ v _)
      (and (opt-gvn-stable-var? sources dst) (opt-gvn-value-stable? sources v))]
    [_ false]))

(define (opt-gvn-record-count-instr-seq-from
  [sources : I64I64Map]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : i64
  (if (>= index (compiler-ir-instr-seq-count instrs))
    0
    (+
      (if (opt-gvn-recordable-instr?
        (compiler-ir-instr-seq-ref instrs index)
        sources)
        1
        0)
      (opt-gvn-record-count-instr-seq-from sources instrs (+ index 1)))))

(define (opt-gvn-record-count-blocks
  [sources : I64I64Map]
  [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-gvn-record-count-instr-seq-from sources instrs 0)
            (opt-gvn-record-count-blocks sources (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-gvn-record-count-blocks sources (compiler-ir-block-seq-to-list seq))]))

(define (opt-gvn-bucket-capacity [count : i64]) : i64
  (opt-global-fact-bucket-capacity count))

(define (opt-gvn-buckets-fill-empty!
  [buckets : (Array OptGvnBucket)]
  [index : i64]) : unit
  (if (>= index (array-length buckets))
    unit
    (begin
      (array-set! buckets index (OptGvnBucketNil))
      (opt-gvn-buckets-fill-empty! buckets (+ index 1)))))

(define (opt-gvn-map-empty [record-count : i64]) : OptGvnMap
  (let
    [buckets : (Array OptGvnBucket)
      (make-array OptGvnBucket (opt-gvn-bucket-capacity record-count))]
    (begin
      (opt-gvn-buckets-fill-empty! buckets 0)
      (OptGvnMap buckets))))

(define (opt-gvn-bucket-index
  [buckets : (Array OptGvnBucket)]
  [key : OptExprKey]) : i64
  (bit-and (opt-expr-key-hash key) (- (array-length buckets) 1)))

(define (opt-gvn-table-push!
  [table : OptGvnMap]
  [entry : OptGvnEntry]
  [changes : OptGvnScopeChanges]) : OptGvnScopeChanges
  (match entry
    [(OptGvnEntry key _ _)
      (let
        [buckets : (Array OptGvnBucket) (struct-get table buckets)]
        [bucket : i64 (opt-gvn-bucket-index buckets key)]
        [old-head : OptGvnBucket (array-ref buckets bucket)]
        ;; #2357: under #1867 inline-by-value aggregates `array-ref` of a
        ;; memory-backed aggregate returns the element ADDRESS (in-place), not a
        ;; value snapshot the way main's old heap-handle GVN assumed. So the
        ;; scope-change MUST capture old-head's value BEFORE the array-set! below
        ;; overwrites the slot -- otherwise restore writes back the just-pushed
        ;; head and scoped dominance breaks (a dominated sibling reuses a value
        ;; that does not dominate it).
        [result : OptGvnScopeChanges
          (OptGvnScopeCons (OptGvnScopeChange bucket old-head) (box changes))]
        (begin
          (array-set! buckets bucket (OptGvnBucketCons entry (box old-head)))
          result))]))

(define (opt-gvn-table-insert! [table : OptGvnMap] [entry : OptGvnEntry]) : unit
  (begin
    (opt-gvn-table-push! table entry (OptGvnScopeNil))
    unit))

(define (opt-gvn-table-restore!
  [table : OptGvnMap]
  [changes : OptGvnScopeChanges]) : unit
  (match changes
    [(OptGvnScopeNil) unit]
    [(OptGvnScopeCons change rest)
      (match change
        [(OptGvnScopeChange bucket old-head)
          (let
            [buckets : (Array OptGvnBucket) (struct-get table buckets)]
            (begin
              (array-set! buckets bucket old-head)
              (opt-gvn-table-restore! table (box-get rest))))])]))

;; Record a `BinOp`/`UnOp` whose result and operands are all single-source as an
;; available value keyed by its expression and tagged with its defining block.
(define (opt-gvn-record
  [instr : CompilerIrInstr]
  [def-block-id : i64]
  [sources : I64I64Map]
  [table : OptGvnMap]
  [changes : OptGvnScopeChanges]) : OptGvnScopeChanges
  (match instr
    [(IrInstrBinOp dst op l r _)
      (if (opt-gvn-recordable-instr? instr sources)
        (opt-gvn-table-push!
          table
          (OptGvnEntry (OptBinKey op l r) dst def-block-id)
          changes)
        changes)]
    [(IrInstrUnOp dst op v _)
      (if (opt-gvn-recordable-instr? instr sources)
        (opt-gvn-table-push!
          table
          (OptGvnEntry (OptUnKey op v) dst def-block-id)
          changes)
        changes)]
    [_ changes]))

(define (opt-gvn-record-scope-instr-seq-from
  [sources : I64I64Map]
  [def-block-id : i64]
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [table : OptGvnMap]
  [changes : OptGvnScopeChanges]) : OptGvnScopeChanges
  (if (>= index (compiler-ir-instr-seq-count instrs))
    changes
    (opt-gvn-record-scope-instr-seq-from
      sources
      def-block-id
      instrs
      (+ index 1)
      table
      (opt-gvn-record
        (compiler-ir-instr-seq-ref instrs index)
        def-block-id
        sources
        table
        changes))))

;; Find the nearest scoped result var for `key`, or -1 if none qualifies.
;; Dominance is represented by the current table scope; the bucket walk only
;; handles hash collisions and older same-key ancestors.
(define (opt-gvn-lookup-bucket [bucket : OptGvnBucket] [key : OptExprKey]) : i64
  (match bucket
    [(OptGvnBucketNil) (- 0 1)]
    [(OptGvnBucketCons entry rest)
      (match entry
        [(OptGvnEntry ekey evar def-block-id)
          (if (and (>= def-block-id 0) (opt-expr-key-eq ekey key))
            evar
            (opt-gvn-lookup-bucket (box-get rest) key))])]))

(define (opt-gvn-lookup [table : OptGvnMap] [key : OptExprKey]) : i64
  (let
    [buckets : (Array OptGvnBucket) (struct-get table buckets)]
    (opt-gvn-lookup-bucket
      (array-ref buckets (opt-gvn-bucket-index buckets key))
      key)))

(define (opt-gvn-rewrite-instr
  [table : OptGvnMap]
  [sources : I64I64Map]
  [instr : CompilerIrInstr]) : CompilerIrInstr
  (match instr
    [(IrInstrBinOp dst op l r ty)
      (if (and
        (opt-gvn-value-stable? sources l)
        (opt-gvn-value-stable? sources r))
        (let
          [earlier : i64 (opt-gvn-lookup table (OptBinKey op l r))]
          (if (and (not (= earlier (- 0 1))) (not (= earlier dst)))
            (IrInstrMov dst (IrValueVar earlier) ty)
            instr))
        instr)]
    [(IrInstrUnOp dst op v ty)
      (if (opt-gvn-value-stable? sources v)
        (let
          [earlier : i64 (opt-gvn-lookup table (OptUnKey op v))]
          (if (and (not (= earlier (- 0 1))) (not (= earlier dst)))
            (IrInstrMov dst (IrValueVar earlier) ty)
            instr))
        instr)]
    [_ instr]))

(define (opt-gvn-rewrite-instr-seq-from
  [table : OptGvnMap]
  [sources : I64I64Map]
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [out : CompilerIrInstrList]) : CompilerIrInstrList
  (if (< index 0)
    out
    (opt-gvn-rewrite-instr-seq-from
      table
      sources
      instrs
      (- index 1)
      (compiler-ir-instr-cons
        (opt-gvn-rewrite-instr
          table
          sources
          (compiler-ir-instr-seq-ref instrs index))
        out))))

(define (opt-gvn-rewrite-instr-seq
  [table : OptGvnMap]
  [sources : I64I64Map]
  [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (opt-gvn-rewrite-instr-seq-from
    table
    sources
    instrs
    (- (compiler-ir-instr-seq-count instrs) 1)
    IrInstrNil))

(define (opt-gvn-rewrite-block
  [table : OptGvnMap]
  [sources : I64I64Map]
  [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      (compiler-ir-block label (opt-gvn-rewrite-instr-seq table sources instrs))]))

(define (opt-gvn-dom-children [doms : OptDomInfo]) : OptCfgCsr
  (let
    [index : OptCfgIndex (struct-get doms index)]
    [count : i64 (opt-cfg-index-block-count index)]
    [child-rows : (Array OptI64List) (make-array OptI64List count)]
    (begin
      (opt-cfg-i64-list-array-fill-empty! child-rows count)
      (opt-dom-child-rows-fill! index (struct-get doms idom) child-rows)
      (opt-cfg-csr-build child-rows count))))

(define (opt-gvn-block-results-fill-empty!
  [out : (Array OptGvnBlockResult)]
  [index : i64]) : unit
  (if (>= index (array-length out))
    unit
    (begin
      (array-set! out index (OptGvnNoBlock))
      (opt-gvn-block-results-fill-empty! out (+ index 1)))))

(define (opt-gvn-materialize-blocks
  [doms : OptDomInfo]
  [out : (Array OptGvnBlockResult)]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _)
          (let
            [block-id : i64 (opt-gvn-block-id doms label)]
            [material : CompilerIrBlock
              (if (and (>= block-id 0) (< block-id (array-length out)))
                (match (array-ref out block-id)
                  [(OptGvnSomeBlock rewritten) rewritten]
                  [(OptGvnNoBlock) block])
                block)]
            (compiler-ir-block-cons
              material
              (opt-gvn-materialize-blocks doms out (box-get rest))))])]
    [(IrBlockArray seq)
      (opt-gvn-materialize-blocks doms out (compiler-ir-block-seq-to-list seq))]))

(define (opt-gvn-rewrite-id
  [context : OptCfgContext]
  [children : OptCfgCsr]
  [table : OptGvnMap]
  [sources : I64I64Map]
  [blocks : CompilerIrBlockList]
  [out : (Array OptGvnBlockResult)]
  [id : i64]) : unit
  (let
    [index : OptCfgIndex (struct-get context index)]
    [count : i64 (opt-cfg-index-block-count index)]
    (if (and (>= id 0) (< id count))
      (let
        [label : String (array-ref (struct-get index labels) id)]
        (match (opt-cfg-find-block blocks label)
          [(OptNoBlock) unit]
          [(OptSomeBlock block)
            (match block
              [(IrBlock _ instrs)
                (let
                  [rewritten : CompilerIrBlock
                    (opt-gvn-rewrite-block table sources block)]
                  (begin
                    (array-set! out id (OptGvnSomeBlock rewritten))
                    (let
                      [changes : OptGvnScopeChanges
                        (opt-gvn-record-scope-instr-seq-from
                          sources
                          id
                          instrs
                          0
                          table
                          (OptGvnScopeNil))]
                      (begin
                        (opt-gvn-rewrite-children
                          context
                          children
                          table
                          sources
                          blocks
                          out
                          id)
                        (opt-gvn-table-restore! table changes)))))])]))
      unit)))

(define (opt-gvn-rewrite-children
  [context : OptCfgContext]
  [children : OptCfgCsr]
  [table : OptGvnMap]
  [sources : I64I64Map]
  [blocks : CompilerIrBlockList]
  [out : (Array OptGvnBlockResult)]
  [parent-id : i64]) : unit
  (let
    [offsets : (Array i64) (struct-get children offsets)]
    [edges : (Array i64) (struct-get children edges)]
    [edge : i64 (array-ref offsets parent-id)]
    [end : i64 (array-ref offsets (+ parent-id 1))]
    (begin
      (while (< edge end)
        (begin
          (opt-gvn-rewrite-id
            context
            children
            table
            sources
            blocks
            out
            (array-ref edges edge))
          (set! edge (+ edge 1))))
      unit)))

(define (opt-gvn-rewrite-dom
  [context : OptCfgContext]
  [table : OptGvnMap]
  [sources : I64I64Map]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (let
    [doms : OptDomInfo (struct-get context doms)]
    [index : OptCfgIndex (struct-get context index)]
    [count : i64 (opt-cfg-index-block-count index)]
    [children : OptCfgCsr (opt-gvn-dom-children doms)]
    [out : (Array OptGvnBlockResult) (make-array OptGvnBlockResult count)]
    (begin
      (opt-gvn-block-results-fill-empty! out 0)
      (match (opt-cfg-index-id index (struct-get context entry-label))
        [(OptSomeI64 entry-id)
          (if (and
            (>= entry-id 0)
            (array-ref (struct-get index reachable) entry-id))
            (opt-gvn-rewrite-id
              context
              children
              table
              sources
              blocks
              out
              entry-id)
            unit)]
        [(OptNoI64) unit])
      (opt-gvn-materialize-blocks doms out blocks))))

;; Replace dominated repeated pure scalar expressions with a copy from the first
;; dominating value; existing copy propagation and DCE remove the dead copies.
(define (opt-gvn-blocks-with-context
  [context : OptCfgContext]
  [params : CompilerIrParamList]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (let
    [sources : I64I64Map
      (opt-gvn-sources-blocks
        blocks
        (opt-gvn-sources-params params (i64-i64-map-with-capacity 64)))]
    [table : OptGvnMap
      (opt-gvn-map-empty (opt-gvn-record-count-blocks sources blocks))]
    [gvn : CompilerIrBlockList
      (opt-gvn-rewrite-dom context table sources blocks)]
    (opt-load-gvn-blocks-with-context context sources gvn)))

(define (opt-gvn-blocks
  [params : CompilerIrParamList]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (opt-gvn-blocks-with-context (opt-cfg-context-build blocks) params blocks))

(define (optimize-block [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      ;; Fold scalar constants, reduce algebraic identities, eliminate repeated
      ;; pure expressions, propagate the resulting copies, then remove duplicate
      ;; proven bounds checks; function-level DCE drops dead copies.
      (compiler-ir-block
        label
        (opt-bounds-instrs
          (OptBoundsNil)
          (opt-copy-instrs
            (OptCopyNil)
            (opt-load-cse-instrs
              (OptLoadCseState (OptAliasNil) (OptLoadNil))
              (opt-cse-instrs
                (OptExprNil)
                (opt-strength-instrs
                  (OptConstNil)
                  (opt-fold-instrs
                    (OptConstNil)
                    (opt-fold-instr-seq (OptConstNil) instrs))))))))]))

(define (optimize-block-fast [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      (compiler-ir-block label (opt-copy-instr-seq (OptCopyNil) instrs))]))

(define (optimize-block-list [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (compiler-ir-block-cons
        (optimize-block block)
        (optimize-block-list (box-get rest)))]
    [(IrBlockArray seq)
      (optimize-block-list (compiler-ir-block-seq-to-list seq))]))

(define (optimize-block-list-fast [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (compiler-ir-block-cons
        (optimize-block-fast block)
        (optimize-block-list-fast (box-get rest)))]
    [(IrBlockArray seq)
      (optimize-block-list-fast (compiler-ir-block-seq-to-list seq))]))

;; Block-count ceiling for the super-linear dominator-based passes (GVN, LICM,
;; induction, global GVN). Functions with more basic blocks than this skip those
;; passes at opt-level 2 so a few huge self-host functions cannot blow up compile
;; time; the linear passes and register allocation still run on them.
;; 1024 covers the current self-host max (806 blocks in opt-instr-eq) with
;; headroom while still keeping a finite guard for pathological inputs.
(define (opt-heavy-pass-block-limit) : i64
  1024)

;; --- self-tail-recursion -> loop (tail-rec-loop) ---------------------------
;;
;; A call to the CURRENT function in tail position (its result flows straight
;; into a `return`) is lowered as an `IrInstrTailCall` whose callee name equals
;; the function name. The backend currently emits a real `call` for it, which
;; grows the stack frame on every recursive step. This pass rewrites each such
;; self-tail-call into a back-edge to the function entry block, turning the
;; recursion into an in-place loop:
;;
;;   * evaluate every call argument into a fresh temp slot (so a parameter that
;;     is read by a *later* argument still sees its old value),
;;   * copy each temp into the matching parameter slot,
;;   * jump to the entry block.
;;
;; Reassigning a parameter slot via `IrInstrMov` is exactly what a source-level
;; `(set! param ...)` lowers to, so this stays inside the IR's existing
;; "reassignment is allowed; redundancy passes invalidate on (re)definition"
;; model. Re-running the whole entry block per iteration is precisely the
;; tail-recursion semantics (a real recursive call re-executes the entire body),
;; so no loop pre-header is required. The reassignments make the function
;; non-SSA, so the SSA-gated passes (LICM, induction) simply skip it; the
;; unconditional passes (GVN/SCCP/copy-prop/CFG/DCE) handle the reassignments
;; the same way they handle ordinary loops built from `while`/`set!`.
(define (opt-tailrec-param-count [params : CompilerIrParamList]) : i64
  (match params
    [(IrParamNil) 0]
    [(IrParamCons _ rest) (+ 1 (opt-tailrec-param-count (box-get rest)))]))

(define (opt-tailrec-array-values-to-list
  [values : (Array CompilerIrValue)]
  [index : i64]) : CompilerIrValueList
  (if (>= index (array-length values))
    IrValueNil
    (compiler-ir-value-cons
      (array-ref values index)
      (opt-tailrec-array-values-to-list values (+ index 1)))))

(define (opt-tailrec-args-to-list [args : CompilerIrCallArgs]) : CompilerIrValueList
  (match args
    [(IrCallArgsNil) IrValueNil]
    [(IrCallArgsOne a) (compiler-ir-value-cons a IrValueNil)]
    [(IrCallArgsTwo a b)
      (compiler-ir-value-cons a (compiler-ir-value-cons b IrValueNil))]
    [(IrCallArgsArray values) (opt-tailrec-array-values-to-list values 0)]))

;; Copy each parameter's staged temp back into the parameter slot, then append
;; `tail` (the back-edge jump). Run after all of the staging moves so the temps
;; already hold the new argument values.
(define (opt-tailrec-assign-movs
  [params : CompilerIrParamList]
  [base : i64]
  [index : i64]
  [tail : CompilerIrInstrList]) : CompilerIrInstrList
  (match params
    [(IrParamNil) tail]
    [(IrParamCons param prest)
      (match param
        [(IrParam _ ty var-id)
          (compiler-ir-instr-cons
            (IrInstrMov var-id (IrValueVar (+ base index)) ty)
            (opt-tailrec-assign-movs (box-get prest) base (+ index 1) tail))])]))

;; Evaluate each argument into a fresh temp slot (`base + i`) before any
;; parameter slot is overwritten, so argument aliasing on the parameters is
;; preserved.
(define (opt-tailrec-stage-movs
  [params : CompilerIrParamList]
  [args : CompilerIrValueList]
  [base : i64]
  [index : i64]
  [tail : CompilerIrInstrList]) : CompilerIrInstrList
  (match params
    [(IrParamNil) tail]
    [(IrParamCons param prest)
      (match args
        [(IrValueNil) tail]
        [(IrValueCons arg arest)
          (match param
            [(IrParam _ ty _)
              (compiler-ir-instr-cons
                (IrInstrMov (+ base index) arg ty)
                (opt-tailrec-stage-movs
                  (box-get prest)
                  (box-get arest)
                  base
                  (+ index 1)
                  tail))])])]))

(define (opt-tailrec-self-call?
  [instr : CompilerIrInstr]
  [fname : String]
  [n : i64]) : bool
  (match instr
    [(IrInstrTailCall name args _)
      (and (string-eq name fname) (= (compiler-ir-call-args-count args) n))]
    [_ false]))

(define (opt-tailrec-rewrite-instrs
  [instrs : CompilerIrInstrList]
  [fname : String]
  [params : CompilerIrParamList]
  [n : i64]
  [base : i64]
  [entry-label : String]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) IrInstrNil]
    [(IrInstrCons instr rest)
      (if (opt-tailrec-self-call? instr fname n)
        (match instr
          [(IrInstrTailCall _ args _)
            ;; `instr` is a terminator, so anything after it in `rest` is dead;
            ;; drop it and emit stage moves, parameter writebacks, then the
            ;; back-edge jump.
            (opt-tailrec-stage-movs
              params
              (opt-tailrec-args-to-list args)
              base
              0
              (opt-tailrec-assign-movs
                params
                base
                0
                (compiler-ir-instr-cons (IrInstrJump entry-label) IrInstrNil)))]
          [_ IrInstrNil])
        (compiler-ir-instr-cons
          instr
          (opt-tailrec-rewrite-instrs
            (box-get rest)
            fname
            params
            n
            base
            entry-label)))]))

(define (opt-tailrec-rewrite-instr-seq-from
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [fname : String]
  [params : CompilerIrParamList]
  [n : i64]
  [base : i64]
  [entry-label : String]) : CompilerIrInstrList
  (if (>= index (compiler-ir-instr-seq-count instrs))
    IrInstrNil
    (let
      [instr : CompilerIrInstr (compiler-ir-instr-seq-ref instrs index)]
      (if (opt-tailrec-self-call? instr fname n)
        (match instr
          [(IrInstrTailCall _ args _)
            (opt-tailrec-stage-movs
              params
              (opt-tailrec-args-to-list args)
              base
              0
              (opt-tailrec-assign-movs
                params
                base
                0
                (compiler-ir-instr-cons (IrInstrJump entry-label) IrInstrNil)))]
          [_ IrInstrNil])
        (compiler-ir-instr-cons
          instr
          (opt-tailrec-rewrite-instr-seq-from
            instrs
            (+ index 1)
            fname
            params
            n
            base
            entry-label))))))

(define (opt-tailrec-rewrite-instr-seq
  [instrs : CompilerIrInstrSeq]
  [fname : String]
  [params : CompilerIrParamList]
  [n : i64]
  [base : i64]
  [entry-label : String]) : CompilerIrInstrList
  (opt-tailrec-rewrite-instr-seq-from instrs 0 fname params n base entry-label))

(define (opt-tailrec-rewrite-blocks
  [blocks : CompilerIrBlockList]
  [fname : String]
  [params : CompilerIrParamList]
  [n : i64]
  [base : i64]
  [entry-label : String]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (compiler-ir-block-cons
            (compiler-ir-block
              label
              (opt-tailrec-rewrite-instr-seq
                instrs
                fname
                params
                n
                base
                entry-label))
            (opt-tailrec-rewrite-blocks
              (box-get rest)
              fname
              params
              n
              base
              entry-label))])]
    [(IrBlockArray seq)
      (opt-tailrec-rewrite-blocks
        (compiler-ir-block-seq-to-list seq)
        fname
        params
        n
        base
        entry-label)]))

(define (opt-tailrec-instrs-have-convertible?
  [instrs : CompilerIrInstrList]
  [fname : String]
  [n : i64]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr rest)
      (if (opt-tailrec-self-call? instr fname n)
        true
        (opt-tailrec-instrs-have-convertible? (box-get rest) fname n))]))

(define (opt-tailrec-instr-seq-has-convertible-from?
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [fname : String]
  [n : i64]) : bool
  (if (>= index (compiler-ir-instr-seq-count instrs))
    false
    (if (opt-tailrec-self-call?
      (compiler-ir-instr-seq-ref instrs index)
      fname
      n)
      true
      (opt-tailrec-instr-seq-has-convertible-from? instrs (+ index 1) fname n))))

(define (opt-tailrec-instr-seq-has-convertible?
  [instrs : CompilerIrInstrSeq]
  [fname : String]
  [n : i64]) : bool
  (opt-tailrec-instr-seq-has-convertible-from? instrs 0 fname n))

(define (opt-tailrec-blocks-have-convertible?
  [blocks : CompilerIrBlockList]
  [fname : String]
  [n : i64]) : bool
  (match blocks
    [(IrBlockNil) false]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (if (opt-tailrec-instr-seq-has-convertible? instrs fname n)
            true
            (opt-tailrec-blocks-have-convertible? (box-get rest) fname n))])]
    [(IrBlockArray seq)
      (opt-tailrec-blocks-have-convertible?
        (compiler-ir-block-seq-to-list seq)
        fname
        n)]))

(define (opt-tailrec-function [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(IrFunction name params ret vars blocks)
      (let
        [n : i64 (opt-tailrec-param-count params)]
        (if (opt-tailrec-blocks-have-convertible? blocks name n)
          (IrFunction
            name
            params
            ret
            (+ vars n)
            (opt-tailrec-rewrite-blocks
              blocks
              name
              params
              n
              vars
              (opt-cfg-entry-label blocks)))
          func))]))

(define (optimize-function-once [func : CompilerIrFunction]) : CompilerIrFunction
  (match (opt-tailrec-function func)
    [(IrFunction name params ret-ty frame blocks)
      ;; Fold first so SCCP can reuse local facts, then simplify the reachable
      ;; CFG and eliminate dead pure assignments.
      (let
        [folded : CompilerIrBlockList (optimize-block-list blocks)]
        [promoted : CompilerIrFunction
          (opt-aggregate-stack-promote-function
            (IrFunction name params ret-ty frame folded))]
        (match promoted
          [(IrFunction _ _ _ promoted-frame promoted-blocks)
            ;; Aggregate field-load SROA (#1562) runs on the post-promotion
            ;; blocks/frame (it leaves the frame unchanged), so the slots stay
            ;; consistent with the later #1530 global-GVN pass below.
            (match (opt-aggregate-sroa-function
              (IrFunction name params ret-ty promoted-frame promoted-blocks))
              [(IrFunction _ _ _ _ sroa-blocks)
                (let
                  ;; #perf: the dominator-based passes (GVN, LICM, induction,
                  ;; global GVN) are super-linear in block count (their dominance
                  ;; queries walk string label-sets), so on the handful of huge
                  ;; self-host functions (hundreds of blocks) they dominate
                  ;; compile time. Gate them off above a block-count threshold;
                  ;; register allocation and the linear cleanups still run, so
                  ;; only the incremental redundancy elimination is skipped on
                  ;; those few functions, which bounds opt-level-3 compile time.
                  [run-heavy? : bool
                    (<=
                      (compiler-ir-block-list-count sroa-blocks)
                      (opt-heavy-pass-block-limit))]
                  ;; Scalar SSA construction feeds the verifier-gated
                  ;; dominator passes below. Unsupported cases fall back to the
                  ;; original function, so the optimization path remains safe.
                  [ssa : CompilerIrFunction
                    (if run-heavy?
                      (opt-ssa-construct-function
                        (IrFunction
                          name
                          params
                          ret-ty
                          promoted-frame
                          sroa-blocks))
                      (IrFunction name params ret-ty promoted-frame sroa-blocks))]
                  [ssa-frame : i64 (opt-function-frame ssa)]
                  [ssa-blocks : CompilerIrBlockList (opt-function-blocks ssa)]
                  [gvn : CompilerIrBlockList
                    (if run-heavy?
                      (let
                        [gvn-context : OptCfgContext
                          (opt-cfg-context-build ssa-blocks)]
                        (opt-gvn-blocks-with-context
                          gvn-context
                          params
                          ssa-blocks))
                      ssa-blocks)]
                  [sccp : CompilerIrBlockList (opt-sccp-blocks params gvn)]
                  [cfg : CompilerIrBlockList (opt-cfg-simplify-blocks sccp)]
                  [preheaders : CompilerIrFunction
                    (if run-heavy?
                      (opt-loop-preheaders-function
                        (IrFunction name params ret-ty ssa-frame cfg))
                      (IrFunction name params ret-ty ssa-frame cfg))]
                  [preheader-frame : i64 (opt-function-frame preheaders)]
                  [preheader-blocks : CompilerIrBlockList
                    (opt-function-blocks preheaders)]
                  [licm : CompilerIrFunction
                    (if run-heavy?
                      (let
                        [licm-context : OptCfgContext
                          (opt-cfg-context-build preheader-blocks)]
                        (opt-licm-function-with-context
                          licm-context
                          (IrFunction
                            name
                            params
                            ret-ty
                            preheader-frame
                            preheader-blocks)))
                      preheaders)]
                  [licm-blocks : CompilerIrBlockList (opt-function-blocks licm)]
                  [induction : CompilerIrFunction
                    (if run-heavy?
                      (let
                        [induction-context : OptCfgContext
                          (opt-cfg-context-build licm-blocks)]
                        (opt-induction-function-with-context
                          induction-context
                          licm))
                      licm)]
                  [induction-frame : i64 (opt-function-frame induction)]
                  [induction-blocks : CompilerIrBlockList
                    (opt-function-blocks induction)]
                  ;; Cross-block global value numbering + copy propagation
                  ;; (#1530) runs after local GVN/SCCP/CFG/LICM cleanup, on
                  ;; the post-stack-promotion frame so its slots stay
                  ;; consistent with the promoted blocks.
                  [global : CompilerIrFunction
                    (if run-heavy?
                      (let
                        [global-context : OptCfgContext
                          (opt-cfg-context-build induction-blocks)]
                        (opt-global-value-number-function-with-context
                          global-context
                          (IrFunction
                            name
                            params
                            ret-ty
                            induction-frame
                            induction-blocks)))
                      (IrFunction
                        name
                        params
                        ret-ty
                        induction-frame
                        induction-blocks))]
                  [global-blocks : CompilerIrBlockList
                    (opt-function-blocks global)]
                  [used : (Array bool)
                    (opt-collect-blocks-uses-array
                      induction-frame
                      global-blocks)]
                  (IrFunction
                    name
                    params
                    ret-ty
                    induction-frame
                    (opt-dce-block-list-array used global-blocks)))])]))]))

;; Level 2 keeps the self-build path lightweight while preserving the explicit
;; optimized-level checks for local scalar cleanup, bounds checks, stack
;; promotion, CFG cleanup, DCE, and program-level reachability pruning.
(define (optimize-function-once-level2 [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(IrFunction name params ret-ty frame blocks)
      (let
        [folded : CompilerIrBlockList (optimize-block-list blocks)]
        [promoted : CompilerIrFunction
          (opt-aggregate-stack-promote-function
            (IrFunction name params ret-ty frame folded))]
        (match promoted
          [(IrFunction _ _ _ promoted-frame promoted-blocks)
            (let
              [cfg : CompilerIrBlockList
                (opt-cfg-simplify-blocks promoted-blocks)]
              [used : (Array bool)
                (opt-collect-blocks-uses-array promoted-frame cfg)]
              (IrFunction
                name
                params
                ret-ty
                promoted-frame
                (opt-dce-block-list-array used cfg)))]))]))

(define (optimize-function-once-fast [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(IrFunction name params ret-ty frame blocks)
      (let
        [folded : CompilerIrBlockList (optimize-block-list-fast blocks)]
        [cfg : CompilerIrBlockList (opt-cfg-simplify-blocks folded)]
        [used : (Array bool) (opt-collect-blocks-uses-array frame cfg)]
        (IrFunction
          name
          params
          ret-ty
          frame
          (opt-dce-block-list-array used cfg)))]))

(define (optimize-function-pass [func : CompilerIrFunction]) : OptFunctionPassResult
  (let
    [next : CompilerIrFunction (optimize-function-once func)]
    (OptFunctionPassResult next (not (opt-function-eq func next)))))

(define (optimize-function-fixed [func : CompilerIrFunction] [remaining : i64]) : CompilerIrFunction
  (if (<= remaining 0)
    func
    (match (optimize-function-pass func)
      [(OptFunctionPassResult next changed)
        (if changed
          (optimize-function-fixed next (- remaining 1))
          next)])))

(define (optimize-function [func : CompilerIrFunction]) : CompilerIrFunction
  (optimize-function-fixed func (optimize-function-max-iterations)))

;; Opt levels (0/1/2): 0 = none, 1 = cheap stack-only (the fast self-compile
;; path), 2 = the full optimizer + scalar register allocation + inlining (the
;; quality "ship" build). The old four-level scheme (with a redundant -fast level
;; between 0 and the cheap level) was collapsed: old level 2 became level 1 and
;; old level 3 became level 2.
(define (optimize-function-with-level [func : CompilerIrFunction] [level : i64]) : CompilerIrFunction
  (core/cond
    (= level 0)
    func
    (= level 1)
    (optimize-function-once-level2 func)
    (optimize-function func)))

(define (optimize-function-list [funcs : CompilerIrFunctionList]) : CompilerIrFunctionList
  (optimize-function-list-with-level funcs (compiler-optimize-default-level)))

;; Per-function arena escape (#1633). The optimizer fixpoint allocates up to
;; ~80 throwaway IR copies per function (10 iterations x ~8 passes), none freed
;; by the bump allocator. To cap peak memory we run each function's optimization
;; in a reusable scratch arena, deep-`clone` only the final result back into the
;; enclosing (program) arena, then rewind the scratch so a single function's
;; transient generations are reclaimed before the next function is processed.
(define (optimize-function-list-with-level
  [funcs : CompilerIrFunctionList]
  [level : i64]) : CompilerIrFunctionList
  (if (= level 0)
    funcs
    (let
      [scratch : i64 (arena-make)]
      [result : CompilerIrFunctionList
        (optimize-function-list-escaping funcs level scratch)]
      (begin
        (unsafe
          (arena-destroy scratch))
        result))))

(define (optimize-function-list-escaping
  [funcs : CompilerIrFunctionList]
  [level : i64]
  [scratch : i64]) : CompilerIrFunctionList
  (match funcs
    [(IrFunctionNil) (IrFunctionNil)]
    [(IrFunctionCons func rest)
      (begin
        (cfg compile-profile (compiler-opt-profile-detail-start))
        (let
          [optimized : CompilerIrFunction
            (optimize-function-escaping func level scratch)]
          (begin
            (cfg
              compile-profile
              (compiler-opt-profile-detail-finish
                "function"
                (compiler-opt-profile-function-name func)))
            (compiler-ir-function-cons
              optimized
              (optimize-function-list-escaping (box-get rest) level scratch)))))]))

;; Optimize one function inside `scratch`, then escape the result by deep-cloning
;; it into the enclosing arena and rewinding `scratch` for reuse. The enclosing
;; arena is captured fresh on entry, so the grown head is never stale across the
;; recursion and no overflow arenas leak.
;; TODO(#1688): once the published stage0 parser carries `with-escape`, rewrite
;; this hand-rolled switch/clone/rewind sequence as `(with-escape scratch ...)`.
(define (optimize-function-escaping
  [func : CompilerIrFunction]
  [level : i64]
  [scratch : i64]) : CompilerIrFunction
  (let
    [enclosing : i64 (arena-current)]
    (begin
      (unsafe
        (arena-set! scratch))
      (let
        [mark : i64 (arena-mark)]
        [raw : CompilerIrFunction (optimize-function-with-level func level)]
        [scratch-head : i64 (arena-current)]
        (begin
          (unsafe
            (arena-set! enclosing))
          (let
            [escaped : CompilerIrFunction (compiler-ir-clone-function raw)]
            [new-enclosing : i64 (arena-current)]
            (begin
              (unsafe
                (arena-set! scratch-head)
                (arena-rewind mark)
                (arena-set! new-enclosing))
              escaped)))))))

(defenum OptStringSet
  (OptStringNil)
  (OptStringCons String (Box OptStringSet)))

(defenum OptMaybeFunction
  (OptNoFunction)
  (OptSomeFunction CompilerIrFunction))

(defenum OptSlotList
  (OptSlotNil)
  (OptSlotCons i64 (Box OptSlotList)))

(defstruct OptFunctionIndex
  (ids StringI64Map)
  (values (Array CompilerIrFunction)))

(defstruct OptCallGraph
  (count i64)
  (edges (Array OptSlotList)))

(defstruct OptInlineCensus
  (refcount StringI64Map)
  (addrtaken StringI64Map))

(defstruct OptSccResult
  (scc-of (Array i64))
  (order (Array i64)))

(defenum OptSccDiscoverState
  (OptSccDiscoverState i64 i64))

(defenum OptSccPopState
  (OptSccPopState i64 i64))

(defenum OptReachState
  (OptReachState StringI64Map OptStringSet))

(define (opt-function-index-capacity [count : i64]) : i64
  (if (< count 4)
    8
    (* count 2)))

(define (opt-function-list-count [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(IrFunctionNil) 0]
    [(IrFunctionCons _ rest) (+ 1 (opt-function-list-count (box-get rest)))]))

(define (opt-function-index-fill
  [functions : CompilerIrFunctionList]
  [ids : StringI64Map]
  [values : (Array CompilerIrFunction)]
  [index : i64]) : StringI64Map
  (match functions
    [(IrFunctionNil) ids]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction name _ _ _ _)
          (begin
            (array-set! values index func)
            (opt-function-index-fill
              (box-get rest)
              (string-i64-map-put ids name index)
              values
              (+ index 1)))])]))

(define (opt-function-index-build [functions : CompilerIrFunctionList]) : OptFunctionIndex
  (let
    [count : i64 (opt-function-list-count functions)]
    [values : (Array CompilerIrFunction) (make-array CompilerIrFunction count)]
    [ids : StringI64Map
      (opt-function-index-fill
        functions
        (string-i64-map-with-capacity (opt-function-index-capacity count))
        values
        0)]
    (OptFunctionIndex ids values)))

(define (opt-function-index-defines? [index : OptFunctionIndex] [name : String]) : bool
  (string-i64-map-contains? (struct-get index ids) name))

(define (opt-function-index-count [index : OptFunctionIndex]) : i64
  (array-length (struct-get index values)))

(define (opt-function-index-slot [index : OptFunctionIndex] [name : String]) : OptMaybeI64
  (if (opt-function-index-defines? index name)
    (match (string-i64-map-get (struct-get index ids) name)
      [(StringI64MapFound slot) (OptSomeI64 slot)]
      [(StringI64MapMissing) (OptNoI64)])
    (OptNoI64)))

(define (opt-function-index-find [index : OptFunctionIndex] [name : String]) : OptMaybeFunction
  (match (string-i64-map-get (struct-get index ids) name)
    [(StringI64MapFound slot)
      (OptSomeFunction (array-ref (struct-get index values) slot))]
    [(StringI64MapMissing) (OptNoFunction)]))

(define (opt-slot-list-contains? [slots : OptSlotList] [slot : i64]) : bool
  (match slots
    [(OptSlotNil) false]
    [(OptSlotCons item rest)
      (if (= item slot)
        true
        (opt-slot-list-contains? (box-get rest) slot))]))

(define (opt-slot-list-add [slots : OptSlotList] [slot : i64]) : OptSlotList
  (if (opt-slot-list-contains? slots slot)
    slots
    (OptSlotCons slot (box slots))))

(define (opt-slot-list-count [slots : OptSlotList]) : i64
  (match slots
    [(OptSlotNil) 0]
    [(OptSlotCons _ rest) (+ 1 (opt-slot-list-count (box-get rest)))]))

(define (opt-callgraph-add-callee
  [index : OptFunctionIndex]
  [callees : OptSlotList]
  [name : String]) : OptSlotList
  (match (opt-function-index-slot index name)
    [(OptSomeI64 slot) (opt-slot-list-add callees slot)]
    [(OptNoI64) callees]))

;; Deliberately call-only: address-taken function values are reachability roots,
;; but they are not direct call-graph edges for the inliner.
(define (opt-callgraph-instr
  [index : OptFunctionIndex]
  [callees : OptSlotList]
  [instr : CompilerIrInstr]) : OptSlotList
  (match instr
    [(IrInstrCall _ name _ _) (opt-callgraph-add-callee index callees name)]
    [(IrInstrTailCall name _ _) (opt-callgraph-add-callee index callees name)]
    [_ callees]))

(define (opt-callgraph-instr-seq-from
  [index : OptFunctionIndex]
  [callees : OptSlotList]
  [slots : (Array CompilerIrInstr)]
  [instr-index : i64]
  [count : i64]) : OptSlotList
  (if (>= instr-index count)
    callees
    (opt-callgraph-instr-seq-from
      index
      (opt-callgraph-instr index callees (array-ref slots instr-index))
      slots
      (+ instr-index 1)
      count)))

(define (opt-callgraph-instr-seq
  [index : OptFunctionIndex]
  [callees : OptSlotList]
  [instrs : CompilerIrInstrSeq]) : OptSlotList
  (opt-callgraph-instr-seq-from
    index
    callees
    (struct-get instrs slots)
    0
    (struct-get instrs len)))

(define (opt-callgraph-blocks
  [index : OptFunctionIndex]
  [callees : OptSlotList]
  [blocks : CompilerIrBlockList]) : OptSlotList
  (match blocks
    [(IrBlockNil) callees]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (opt-callgraph-blocks
            index
            (opt-callgraph-instr-seq index callees instrs)
            (box-get rest))])]
    [(IrBlockArray seq)
      (opt-callgraph-blocks index callees (compiler-ir-block-seq-to-list seq))]))

(define (opt-callgraph-callees
  [index : OptFunctionIndex]
  [func : CompilerIrFunction]) : OptSlotList
  (match func
    [(IrFunction _ _ _ _ blocks) (opt-callgraph-blocks index OptSlotNil blocks)]))

(define (opt-callgraph-init-edges
  [edges : (Array OptSlotList)]
  [slot : i64]
  [count : i64]) : unit
  (if (>= slot count)
    unit
    (begin
      (array-set! edges slot OptSlotNil)
      (opt-callgraph-init-edges edges (+ slot 1) count))))

(define (opt-callgraph-build-slots
  [index : OptFunctionIndex]
  [edges : (Array OptSlotList)]
  [values : (Array CompilerIrFunction)]
  [slot : i64]
  [count : i64]) : unit
  (if (>= slot count)
    unit
    (begin
      (array-set!
        edges
        slot
        (opt-callgraph-callees index (array-ref values slot)))
      (opt-callgraph-build-slots index edges values (+ slot 1) count))))

(define (opt-callgraph-build [index : OptFunctionIndex]) : OptCallGraph
  (let
    [count : i64 (opt-function-index-count index)]
    [edges : (Array OptSlotList) (make-array OptSlotList count)]
    [values : (Array CompilerIrFunction) (struct-get index values)]
    (begin
      (opt-callgraph-init-edges edges 0 count)
      (opt-callgraph-build-slots index edges values 0 count)
      (OptCallGraph count edges))))

(define (opt-inline-census-capacity [index : OptFunctionIndex]) : i64
  (opt-function-index-capacity (opt-function-index-count index)))

(define (opt-inline-census-bump-map [map : StringI64Map] [name : String]) : StringI64Map
  (match (string-i64-map-get map name)
    [(StringI64MapFound count) (string-i64-map-put map name (+ count 1))]
    [(StringI64MapMissing) (string-i64-map-put map name 1)]))

(define (opt-inline-census-add-ref
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [name : String]) : OptInlineCensus
  (if (opt-function-index-defines? index name)
    (OptInlineCensus
      (opt-inline-census-bump-map (struct-get census refcount) name)
      (struct-get census addrtaken))
    census))

(define (opt-inline-census-add-address
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [name : String]) : OptInlineCensus
  (if (opt-function-index-defines? index name)
    (OptInlineCensus
      (struct-get census refcount)
      (string-i64-map-put (struct-get census addrtaken) name 1))
    census))

(define (opt-inline-census-value
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [value : CompilerIrValue]) : OptInlineCensus
  (match value
    [(IrValueFunction name) (opt-inline-census-add-address index census name)]
    [_ census]))

(define (opt-inline-census-args-array
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [values : (Array CompilerIrValue)]
  [arg-index : i64]) : OptInlineCensus
  (if (>= arg-index (array-length values))
    census
    (opt-inline-census-args-array
      index
      (opt-inline-census-value index census (array-ref values arg-index))
      values
      (+ arg-index 1))))

(define (opt-inline-census-args
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [args : CompilerIrCallArgs]) : OptInlineCensus
  (match args
    [(IrCallArgsNil) census]
    [(IrCallArgsOne value) (opt-inline-census-value index census value)]
    [(IrCallArgsTwo a b)
      (opt-inline-census-value index (opt-inline-census-value index census a) b)]
    [(IrCallArgsArray values)
      (opt-inline-census-args-array index census values 0)]))

(define (opt-inline-census-maybe-value
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [maybe : CompilerIrMaybeValue]) : OptInlineCensus
  (match maybe
    [(IrNoValue) census]
    [(IrSomeValue value) (opt-inline-census-value index census value)]))

(define (opt-inline-census-phi-inputs
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [inputs : CompilerIrPhiInputList]) : OptInlineCensus
  (match inputs
    [(IrPhiInputNil) census]
    [(IrPhiInputCons value _ rest)
      (opt-inline-census-phi-inputs
        index
        (opt-inline-census-value index census value)
        (box-get rest))]))

(define (opt-inline-census-value-list
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [values : CompilerIrValueList]) : OptInlineCensus
  (match values
    [(IrValueNil) census]
    [(IrValueCons value rest)
      (opt-inline-census-value-list
        index
        (opt-inline-census-value index census value)
        (box-get rest))]))

(define (opt-inline-census-instr
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [instr : CompilerIrInstr]) : OptInlineCensus
  (match instr
    [(IrInstrMov _ src _) (opt-inline-census-value index census src)]
    [(IrInstrAlloc _ _) census]
    [(IrInstrAddrOf _ _) census]
    [(IrInstrGep _ base offset _)
      (opt-inline-census-value
        index
        (opt-inline-census-value index census base)
        offset)]
    [(IrInstrLoad _ src _) (opt-inline-census-value index census src)]
    [(IrInstrStorePtr dst src _)
      (opt-inline-census-value
        index
        (opt-inline-census-value index census dst)
        src)]
    [(IrInstrCopyBytes dst src _)
      (opt-inline-census-value
        index
        (opt-inline-census-value index census dst)
        src)]
    [(IrInstrBoundsCheck idx length _)
      (opt-inline-census-value
        index
        (opt-inline-census-value index census idx)
        length)]
    [(IrInstrCast _ src _ _) (opt-inline-census-value index census src)]
    [(IrInstrBinOp _ _ lhs rhs _)
      (opt-inline-census-value
        index
        (opt-inline-census-value index census lhs)
        rhs)]
    [(IrInstrUnOp _ _ src _) (opt-inline-census-value index census src)]
    [(IrInstrLaneId _ _ _) census]
    [(IrInstrSplat _ value _ _) (opt-inline-census-value index census value)]
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (opt-inline-census-value
        index
        (opt-inline-census-value index census lhs)
        rhs)]
    [(IrInstrVectorReduce _ _ src _ _)
      (opt-inline-census-value index census src)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (opt-inline-census-value
        index
        (opt-inline-census-value index census lhs)
        rhs)]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (opt-inline-census-value
        index
        (opt-inline-census-value index census lhs)
        rhs)]
    [(IrInstrMaskNot _ src _) (opt-inline-census-value index census src)]
    [(IrInstrMaskReduce _ _ src _) (opt-inline-census-value index census src)]
    [(IrInstrSelect _ mask on-true on-false _ _)
      (opt-inline-census-value
        index
        (opt-inline-census-value
          index
          (opt-inline-census-value index census mask)
          on-true)
        on-false)]
    [(IrInstrVectorLoad _ base idx _ _)
      (opt-inline-census-value
        index
        (opt-inline-census-value index census base)
        idx)]
    [(IrInstrVectorStore base idx value _ _)
      (opt-inline-census-value
        index
        (opt-inline-census-value
          index
          (opt-inline-census-value index census base)
          idx)
        value)]
    [(IrInstrPredicatedStore base idx value mask _ _)
      (opt-inline-census-value
        index
        (opt-inline-census-value
          index
          (opt-inline-census-value
            index
            (opt-inline-census-value index census base)
            idx)
          value)
        mask)]
    [(IrInstrPredicatedLoad _ base idx mask _ _)
      (opt-inline-census-value
        index
        (opt-inline-census-value
          index
          (opt-inline-census-value index census base)
          idx)
        mask)]
    [(IrInstrTailMask _ idx length _)
      (opt-inline-census-value
        index
        (opt-inline-census-value index census idx)
        length)]
    [(IrInstrEntryArgc _) census]
    [(IrInstrEntryArgv _) census]
    [(IrInstrEntryEnvp _) census]
    [(IrInstrCpuId _ leaf subleaf _)
      (opt-inline-census-value
        index
        (opt-inline-census-value index census leaf)
        subleaf)]
    [(IrInstrXgetbv _ idx) (opt-inline-census-value index census idx)]
    [(IrInstrSyscall _ args) (opt-inline-census-args index census args)]
    [(IrInstrCall _ name args _)
      (opt-inline-census-add-ref
        index
        (opt-inline-census-args index census args)
        name)]
    [(IrInstrCallIndirect _ func args _)
      (opt-inline-census-args
        index
        (opt-inline-census-value index census func)
        args)]
    [(IrInstrCallIndirectC _ func args _)
      (opt-inline-census-args
        index
        (opt-inline-census-value index census func)
        args)]
    [(IrInstrTailCall name args _)
      (opt-inline-census-add-ref
        index
        (opt-inline-census-args index census args)
        name)]
    [(IrInstrStore _ value _) (opt-inline-census-value index census value)]
    [(IrInstrJump _) census]
    [(IrInstrBranch cond _ _) (opt-inline-census-value index census cond)]
    [(IrInstrReturn maybe) (opt-inline-census-maybe-value index census maybe)]
    [(IrInstrPhi _ inputs _) (opt-inline-census-phi-inputs index census inputs)]
    ;; #2386: register-group ops use their operands (Pack: each word; Word: src).
    [(IrInstrPack _ words _) (opt-inline-census-value-list index census words)]
    [(IrInstrWord _ src _ _) (opt-inline-census-value index census src)]))

(define (opt-inline-census-instr-seq-from
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [instrs : CompilerIrInstrSeq]
  [instr-index : i64]) : OptInlineCensus
  (if (>= instr-index (compiler-ir-instr-seq-count instrs))
    census
    (opt-inline-census-instr-seq-from
      index
      (opt-inline-census-instr
        index
        census
        (compiler-ir-instr-seq-ref instrs instr-index))
      instrs
      (+ instr-index 1))))

(define (opt-inline-census-instr-seq
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [instrs : CompilerIrInstrSeq]) : OptInlineCensus
  (opt-inline-census-instr-seq-from index census instrs 0))

(define (opt-inline-census-blocks
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [blocks : CompilerIrBlockList]) : OptInlineCensus
  (match blocks
    [(IrBlockNil) census]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (opt-inline-census-blocks
            index
            (opt-inline-census-instr-seq index census instrs)
            (box-get rest))])]
    [(IrBlockArray seq)
      (opt-inline-census-blocks
        index
        census
        (compiler-ir-block-seq-to-list seq))]))

(define (opt-inline-census-function
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [func : CompilerIrFunction]) : OptInlineCensus
  (match func
    [(IrFunction _ _ _ _ blocks) (opt-inline-census-blocks index census blocks)]))

(define (opt-inline-census-functions
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [functions : CompilerIrFunctionList]) : OptInlineCensus
  (match functions
    [(IrFunctionNil) census]
    [(IrFunctionCons func rest)
      (opt-inline-census-functions
        index
        (opt-inline-census-function index census func)
        (box-get rest))]))

(define (opt-inline-census-build
  [index : OptFunctionIndex]
  [functions : CompilerIrFunctionList]) : OptInlineCensus
  (let
    [capacity : i64 (opt-inline-census-capacity index)]
    (opt-inline-census-functions
      index
      (OptInlineCensus
        (string-i64-map-with-capacity capacity)
        (string-i64-map-with-capacity capacity))
      functions)))

(define (opt-inline-census-refcount [census : OptInlineCensus] [name : String]) : i64
  (match (string-i64-map-get (struct-get census refcount) name)
    [(StringI64MapFound count) count]
    [(StringI64MapMissing) 0]))

(define (opt-inline-census-address-taken?
  [census : OptInlineCensus]
  [name : String]) : bool
  (string-i64-map-contains? (struct-get census addrtaken) name))

(define (opt-inline-census-absorbable?
  [census : OptInlineCensus]
  [caller-name : String]
  [callee-name : String]) : bool
  (and
    (= (opt-inline-census-refcount census callee-name) 1)
    (and
      (not (opt-inline-census-address-taken? census callee-name))
      (and
        (not (string-eq callee-name "main"))
        (not (string-eq caller-name callee-name))))))

(define (opt-callgraph-callee-count [graph : OptCallGraph] [from-slot : i64]) : i64
  (if (or (< from-slot 0) (>= from-slot (struct-get graph count)))
    -1
    (opt-slot-list-count (array-ref (struct-get graph edges) from-slot))))

(define (opt-callgraph-has-edge?
  [graph : OptCallGraph]
  [from-slot : i64]
  [to-slot : i64]) : bool
  (if (or
    (< from-slot 0)
    (or
      (< to-slot 0)
      (or
        (>= from-slot (struct-get graph count))
        (>= to-slot (struct-get graph count)))))
    false
    (opt-slot-list-contains?
      (array-ref (struct-get graph edges) from-slot)
      to-slot)))

(define (opt-scc-set-low-min!
  [lowlink : (Array i64)]
  [slot : i64]
  [candidate : i64]) : unit
  (let
    [old : i64 (array-ref lowlink slot)]
    (if (< candidate old)
      (array-set! lowlink slot candidate)
      unit)))

(define (opt-scc-next-child-from
  [slots : OptSlotList]
  [after : i64]
  [best : i64]) : i64
  (match slots
    [(OptSlotNil) best]
    [(OptSlotCons slot rest)
      (opt-scc-next-child-from
        (box-get rest)
        after
        (if (and (> slot after) (or (< best 0) (< slot best)))
          slot
          best))]))

(define (opt-scc-next-child [graph : OptCallGraph] [slot : i64] [after : i64]) : i64
  (if (or (< slot 0) (>= slot (struct-get graph count)))
    (- 0 1)
    (opt-scc-next-child-from
      (array-ref (struct-get graph edges) slot)
      after
      (- 0 1))))

(define (opt-scc-discover!
  [slot : i64]
  [indices : (Array i64)]
  [lowlink : (Array i64)]
  [on-stack : (Array bool)]
  [node-stack : (Array i64)]
  [node-stack-len : i64]
  [next-index : i64]) : OptSccDiscoverState
  (begin
    (array-set! indices slot next-index)
    (array-set! lowlink slot next-index)
    (array-set! on-stack slot true)
    (array-set! node-stack node-stack-len slot)
    (OptSccDiscoverState (+ next-index 1) (+ node-stack-len 1))))

(define (opt-scc-frame-push!
  [frame-slots : (Array i64)]
  [frame-nexts : (Array i64)]
  [frame-len : i64]
  [slot : i64]) : i64
  (begin
    (array-set! frame-slots frame-len slot)
    (array-set! frame-nexts frame-len (- 0 1))
    (+ frame-len 1)))

(define (opt-scc-pop-component!
  [node-stack : (Array i64)]
  [node-stack-len : i64]
  [on-stack : (Array bool)]
  [scc-of : (Array i64)]
  [root : i64]
  [scc-id : i64]) : OptSccPopState
  (let
    [len : i64 node-stack-len]
    [done : bool false]
    [members : i64 0]
    (begin
      (while (not done)
        (let
          [next-len : i64 (- len 1)]
          [slot : i64 (array-ref node-stack next-len)]
          (begin
            (set! len next-len)
            (array-set! on-stack slot false)
            (array-set! scc-of slot scc-id)
            (set! members (+ members 1))
            (if (= slot root)
              (set! done true)
              unit))))
      (OptSccPopState len members))))

(define (opt-scc-copy-order [source : (Array i64)] [count : i64]) : (Array i64)
  (let
    [out : (Array i64) (make-array i64 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set! out index (array-ref source index))
          (set! index (+ index 1))))
      out)))

(define (opt-scc-compute [graph : OptCallGraph]) : OptSccResult
  (let
    [count : i64 (struct-get graph count)]
    [indices : (Array i64) (make-array i64 count)]
    [lowlink : (Array i64) (make-array i64 count)]
    [on-stack : (Array bool) (make-array bool count)]
    [scc-of : (Array i64) (make-array i64 count)]
    [node-stack : (Array i64) (make-array i64 count)]
    [frame-slots : (Array i64) (make-array i64 count)]
    [frame-nexts : (Array i64) (make-array i64 count)]
    [order-scratch : (Array i64) (make-array i64 count)]
    [root : i64 0]
    [next-index : i64 0]
    [node-stack-len : i64 0]
    [frame-len : i64 0]
    [scc-count : i64 0]
    (begin
      (opt-cfg-fill-i64! indices count (- 0 1))
      (opt-cfg-fill-i64! lowlink count (- 0 1))
      (opt-cfg-fill-bool! on-stack count false)
      (opt-cfg-fill-i64! scc-of count (- 0 1))
      (opt-cfg-fill-i64! order-scratch count (- 0 1))
      (while (< root count)
        (begin
          (if (= (array-ref indices root) (- 0 1))
            (begin
              (match (opt-scc-discover!
                root
                indices
                lowlink
                on-stack
                node-stack
                node-stack-len
                next-index)
                [(OptSccDiscoverState next stack-len)
                  (begin
                    (set! next-index next)
                    (set! node-stack-len stack-len))])
              (set!
                frame-len
                (opt-scc-frame-push! frame-slots frame-nexts frame-len root))
              (while (> frame-len 0)
                (let
                  [frame-index : i64 (- frame-len 1)]
                  [slot : i64 (array-ref frame-slots frame-index)]
                  [child : i64
                    (opt-scc-next-child
                      graph
                      slot
                      (array-ref frame-nexts frame-index))]
                  (if (>= child 0)
                    (begin
                      (array-set! frame-nexts frame-index child)
                      (if (= (array-ref indices child) (- 0 1))
                        (begin
                          (match (opt-scc-discover!
                            child
                            indices
                            lowlink
                            on-stack
                            node-stack
                            node-stack-len
                            next-index)
                            [(OptSccDiscoverState next stack-len)
                              (begin
                                (set! next-index next)
                                (set! node-stack-len stack-len))])
                          (set!
                            frame-len
                            (opt-scc-frame-push!
                              frame-slots
                              frame-nexts
                              frame-len
                              child)))
                        (if (array-ref on-stack child)
                          (opt-scc-set-low-min!
                            lowlink
                            slot
                            (array-ref indices child))
                          unit)))
                    (begin
                      (if (= (array-ref lowlink slot) (array-ref indices slot))
                        (match (opt-scc-pop-component!
                          node-stack
                          node-stack-len
                          on-stack
                          scc-of
                          slot
                          scc-count)
                          [(OptSccPopState stack-len _)
                            (begin
                              (set! node-stack-len stack-len)
                              (array-set! order-scratch scc-count scc-count)
                              (set! scc-count (+ scc-count 1)))])
                        unit)
                      (set! frame-len (- frame-len 1))
                      (if (> frame-len 0)
                        (let
                          [parent : i64 (array-ref frame-slots (- frame-len 1))]
                          (opt-scc-set-low-min!
                            lowlink
                            parent
                            (array-ref lowlink slot)))
                        unit))))))
            unit)
          (set! root (+ root 1))))
      (OptSccResult scc-of (opt-scc-copy-order order-scratch scc-count)))))

;; Devirtualize syntactically known function values before program-level
;; inlining, so the existing direct-call inliner can see them.
(define (opt-devirt-known-function-instr [instr : CompilerIrInstr]) : CompilerIrInstr
  (match instr
    [(IrInstrCallIndirect dst (IrValueFunction name) args ty)
      (IrInstrCall dst name args ty)]
    [_ instr]))

(define (opt-devirt-known-function-instrs [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (compiler-ir-instr-cons
        (opt-devirt-known-function-instr instr)
        (opt-devirt-known-function-instrs (box-get rest)))]))

(define (opt-devirt-known-function-instr-seq-from
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : CompilerIrInstrList
  (if (>= index (compiler-ir-instr-seq-count instrs))
    IrInstrNil
    (compiler-ir-instr-cons
      (opt-devirt-known-function-instr (compiler-ir-instr-seq-ref instrs index))
      (opt-devirt-known-function-instr-seq-from instrs (+ index 1)))))

(define (opt-devirt-known-function-instr-seq [instrs : CompilerIrInstrSeq]) : CompilerIrInstrList
  (opt-devirt-known-function-instr-seq-from instrs 0))

(define (opt-devirt-known-function-block [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      (compiler-ir-block label (opt-devirt-known-function-instr-seq instrs))]))

(define (opt-devirt-known-function-blocks [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (compiler-ir-block-cons
        (opt-devirt-known-function-block block)
        (opt-devirt-known-function-blocks (box-get rest)))]
    [(IrBlockArray seq)
      (opt-devirt-known-function-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-devirt-known-function-function [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(IrFunction name params ret vars blocks)
      (IrFunction
        name
        params
        ret
        vars
        (opt-devirt-known-function-blocks blocks))]))

(define (opt-devirt-known-function-list [functions : CompilerIrFunctionList]) : CompilerIrFunctionList
  (match functions
    [(IrFunctionNil) (IrFunctionNil)]
    [(IrFunctionCons func rest)
      (compiler-ir-function-cons
        (opt-devirt-known-function-function func)
        (opt-devirt-known-function-list (box-get rest)))]))

;; ---------------------------------------------------------------------------
;; Function inlining (opt level 2 only). Splices the body of small single-block
;; leaf callees into their call sites, removing call/return overhead and exposing
;; the callee's instructions to the caller's folding/DCE/GVN and to register
;; allocation. Reserved for opt2 (the quality build) so the cheap opt1
;; self-compile path pays nothing for it.
;;
;; Determinism: fresh var ids are minted from the caller function's `vars`
;; counter (the same per-function sequential scheme lowering uses), callee bodies
;; are walked in list order, and callees are resolved through the deterministic
;; OptFunctionIndex. Param var ids (0..nparams-1) are substituted with the call's
;; argument values; other callee var ids are compacted by subtracting the dead
;; read-only param slots before shifting by the caller's var count.
;; ---------------------------------------------------------------------------
(defenum OptInlineState
  (OptInlineState CompilerIrInstrList i64 i64))

(defenum OptInlineBlocks
  (OptInlineBlocks CompilerIrBlockList i64 i64))

(defenum OptInlineSpanState
  (OptInlineSpanState CompilerIrInstrList i64 i64 CompilerSourceSpans))

(defenum OptInlineSpanBlocks
  (OptInlineSpanBlocks CompilerIrBlockList i64 i64 CompilerSourceSpans))

(defenum OptInlineSpanProgram
  (OptInlineSpanProgram CompilerIrFunctionList CompilerSourceSpans))

(define (opt-inline-max-body) : i64
  8)

(define (opt-inline-cost-block-weight) : i64
  6)

(define (opt-inline-cost-call-bonus) : i64
  6)

(define (opt-inline-cost-const-arg-bonus) : i64
  3)

(define (opt-inline-cost-threshold) : i64
  4)

(define (opt-inline-cost-absorb-bonus) : i64
  1000)

(define (opt-inline-cost-block-fuel) : i64
  32)

(define (opt-inline-param-count [params : CompilerIrParamList]) : i64
  (match params
    [(IrParamNil) 0]
    [(IrParamCons _ rest) (+ 1 (opt-inline-param-count (box-get rest)))]))

(define (opt-inline-params-sequential? [params : CompilerIrParamList] [i : i64]) : bool
  (match params
    [(IrParamNil) true]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ _ vid)
          (if (= vid i)
            (opt-inline-params-sequential? (box-get rest) (+ i 1))
            false)])]))

(define (opt-inline-is-return? [instr : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrReturn _) true]
    [_ false]))

(define (opt-inline-body-instr-ok? [instr : CompilerIrInstr] [np : i64]) : bool
  (match instr
    [(IrInstrMov dst _ _) (>= dst np)]
    [(IrInstrGep dst _ _ _) (>= dst np)]
    [(IrInstrLoad dst _ _) (>= dst np)]
    [(IrInstrCast dst _ _ _) (>= dst np)]
    [(IrInstrBinOp dst _ _ _ _) (>= dst np)]
    [(IrInstrUnOp dst _ _ _) (>= dst np)]
    [(IrInstrCall dst _ _ _) (>= dst np)]
    [(IrInstrCallIndirect dst _ _ _) (>= dst np)]
    [(IrInstrCallIndirectC dst _ _ _) (>= dst np)]
    ;; IrInstrBoundsCheck carries a backend label in its String field; copying it
    ;; into a call site duplicates that label (assembler "symbol already defined"),
    ;; so callees containing one are not inlinable.
    [(IrInstrStorePtr _ _ _) true]
    [(IrInstrCopyBytes _ _ _) true]
    [_ false]))

(define (opt-inline-seq-ok? [instrs : CompilerIrInstrList] [np : i64]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr rest)
      (match (box-get rest)
        [(IrInstrNil) (opt-inline-is-return? instr)]
        [_
          (if (opt-inline-body-instr-ok? instr np)
            (opt-inline-seq-ok? (box-get rest) np)
            false)])]))

(define (opt-inline-instr-seq-ok-from?
  [instrs : CompilerIrInstrSeq]
  [np : i64]
  [index : i64]
  [last : i64]) : bool
  (if (> index last)
    false
    (let
      [instr : CompilerIrInstr (compiler-ir-instr-seq-ref instrs index)]
      (if (= index last)
        (opt-inline-is-return? instr)
        (if (opt-inline-body-instr-ok? instr np)
          (opt-inline-instr-seq-ok-from? instrs np (+ index 1) last)
          false)))))

(define (opt-inline-instr-seq-ok? [instrs : CompilerIrInstrSeq] [np : i64]) : bool
  (opt-inline-instr-seq-ok-from?
    instrs
    np
    0
    (- (compiler-ir-instr-seq-count instrs) 1)))

(define (opt-inline-single-block-ok? [blocks : CompilerIrBlockList] [np : i64]) : bool
  (match blocks
    [(IrBlockCons block rest)
      (match (box-get rest)
        [(IrBlockNil)
          (match block
            [(IrBlock _ seq)
              (let
                [n : i64 (compiler-ir-instr-seq-count seq)]
                (if (< n 1)
                  false
                  (if (> (- n 1) (opt-inline-max-body))
                    false
                    (opt-inline-instr-seq-ok? seq np))))])]
        [_ false])]
    [_ false]))

(define (opt-inline-single-block-cost-instrs [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockCons block _)
      (match block
        [(IrBlock _ seq) (- (compiler-ir-instr-seq-count seq) 1)])]
    [_ 0]))

(define (opt-inline-callee-ok?
  [callee : CompilerIrFunction]
  [caller-name : String]) : bool
  (match callee
    [(IrFunction cname cparams _ cvars cblocks)
      (if (string-eq cname caller-name)
        false
        (let
          [np : i64 (opt-inline-param-count cparams)]
          (if (opt-inline-params-sequential? cparams 0)
            (if (>= cvars np)
              (opt-inline-single-block-ok? cblocks np)
              false)
            false)))]))

(define (opt-inline-arity-ok? [args : CompilerIrCallArgs] [np : i64]) : bool
  (match args
    [(IrCallArgsNil) (= np 0)]
    [(IrCallArgsOne _) (= np 1)]
    [(IrCallArgsTwo _ _) (= np 2)]
    [(IrCallArgsArray arr) (= np (array-length arr))]))

(define (opt-inline-value-constant? [value : CompilerIrValue]) : bool
  (match value
    [(IrValueVar _) false]
    [_ true]))

(define (opt-inline-args-array-const-count
  [values : (Array CompilerIrValue)]
  [index : i64]
  [count : i64]) : i64
  (if (>= index (array-length values))
    count
    (opt-inline-args-array-const-count
      values
      (+ index 1)
      (if (opt-inline-value-constant? (array-ref values index))
        (+ count 1)
        count))))

(define (opt-inline-args-const-count [args : CompilerIrCallArgs]) : i64
  (match args
    [(IrCallArgsNil) 0]
    [(IrCallArgsOne value)
      (if (opt-inline-value-constant? value)
        1
        0)]
    [(IrCallArgsTwo a b)
      (+
        (if (opt-inline-value-constant? a)
          1
          0)
        (if (opt-inline-value-constant? b)
          1
          0))]
    [(IrCallArgsArray values) (opt-inline-args-array-const-count values 0 0)]))

(define (opt-inline-cost-min [a : i64] [b : i64]) : i64
  (if (< a b)
    a
    b))

(define (opt-inline-cost-crosses-heavy-gate?
  [caller-blocks : i64]
  [added-so-far : i64]
  [added-blocks : i64]) : bool
  (and
    (<= caller-blocks (opt-heavy-pass-block-limit))
    (>
      (+ caller-blocks (+ added-so-far added-blocks))
      (opt-heavy-pass-block-limit))))

(define (opt-inline-cost-inline?
  [callee-instrs : i64]
  [added-blocks : i64]
  [const-args : i64]
  [absorbable : bool]
  [caller-blocks : i64]
  [added-so-far : i64]) : bool
  (if (opt-inline-cost-crosses-heavy-gate?
    caller-blocks
    added-so-far
    added-blocks)
    false
    (if (> (+ added-so-far added-blocks) (opt-inline-cost-block-fuel))
      false
      (let
        [raw : i64
          (+ callee-instrs (* (opt-inline-cost-block-weight) added-blocks))]
        [const-savings : i64
          (opt-inline-cost-min
            raw
            (* (opt-inline-cost-const-arg-bonus) const-args))]
        [net : i64
          (-
            (- (- raw const-savings) (opt-inline-cost-call-bonus))
            (if absorbable
              (opt-inline-cost-absorb-bonus)
              0))]
        (<= net (opt-inline-cost-threshold))))))

(define (opt-inline-rebase-var [id : i64] [np : i64] [base : i64]) : i64
  (+ base (- id np)))

(define (opt-inline-frame-growth [frame : i64] [np : i64]) : i64
  (- frame np))

(define (opt-inline-clone-arg-at [sa : CompilerIrCallArgs] [id : i64]) : CompilerIrValue
  (match sa
    [(IrCallArgsNil) (IrValueUnit)]
    [(IrCallArgsOne a) (compiler-ir-clone-value a)]
    [(IrCallArgsTwo a b)
      (if (= id 0)
        (compiler-ir-clone-value a)
        (compiler-ir-clone-value b))]
    [(IrCallArgsArray arr) (compiler-ir-clone-value (array-ref arr id))]))

(define (opt-inline-remap-value
  [v : CompilerIrValue]
  [sa : CompilerIrCallArgs]
  [np : i64]
  [base : i64]) : CompilerIrValue
  (match v
    [(IrValueVar id)
      (if (< id np)
        (opt-inline-clone-arg-at sa id)
        (IrValueVar (opt-inline-rebase-var id np base)))]
    [(IrValueGlobal name) (IrValueGlobal (clone name))]
    [(IrValueGlobalAddr name) (IrValueGlobalAddr (clone name))]
    [(IrValueFunction name) (IrValueFunction (clone name))]
    [(IrValueI64 n) (IrValueI64 n)]
    [(IrValueF64 s) (IrValueF64 (clone s))]
    [(IrValueBool b) (IrValueBool b)]
    [(IrValueChar c) (IrValueChar c)]
    [(IrValueString s) (IrValueString (clone s))]
    [(IrValueUnit) (IrValueUnit)]))

(define (opt-inline-remap-args
  [a : CompilerIrCallArgs]
  [sa : CompilerIrCallArgs]
  [np : i64]
  [base : i64]) : CompilerIrCallArgs
  (match a
    [(IrCallArgsNil) (IrCallArgsNil)]
    [(IrCallArgsOne x) (IrCallArgsOne (opt-inline-remap-value x sa np base))]
    [(IrCallArgsTwo x y)
      (IrCallArgsTwo
        (opt-inline-remap-value x sa np base)
        (opt-inline-remap-value y sa np base))]
    [(IrCallArgsArray arr)
      (let
        [n : i64 (array-length arr)]
        [out : (Array CompilerIrValue) (make-array CompilerIrValue n)]
        [i : i64 0]
        (begin
          (while (< i n)
            (begin
              (array-set!
                out
                i
                (opt-inline-remap-value (array-ref arr i) sa np base))
              (set! i (+ i 1))))
          (IrCallArgsArray out)))]))

(define (opt-inline-clone-instr
  [instr : CompilerIrInstr]
  [sa : CompilerIrCallArgs]
  [np : i64]
  [base : i64]) : CompilerIrInstr
  (match instr
    [(IrInstrMov dst src ty)
      (IrInstrMov
        (opt-inline-rebase-var dst np base)
        (opt-inline-remap-value src sa np base)
        (clone ty))]
    [(IrInstrGep dst b o ty)
      (IrInstrGep
        (opt-inline-rebase-var dst np base)
        (opt-inline-remap-value b sa np base)
        (opt-inline-remap-value o sa np base)
        (clone ty))]
    [(IrInstrLoad dst src ty)
      (IrInstrLoad
        (opt-inline-rebase-var dst np base)
        (opt-inline-remap-value src sa np base)
        (clone ty))]
    [(IrInstrCast dst src from to)
      (IrInstrCast
        (opt-inline-rebase-var dst np base)
        (opt-inline-remap-value src sa np base)
        (clone from)
        (clone to))]
    [(IrInstrBinOp dst op lhs rhs ty)
      (IrInstrBinOp
        (opt-inline-rebase-var dst np base)
        op
        (opt-inline-remap-value lhs sa np base)
        (opt-inline-remap-value rhs sa np base)
        (clone ty))]
    [(IrInstrUnOp dst op src ty)
      (IrInstrUnOp
        (opt-inline-rebase-var dst np base)
        op
        (opt-inline-remap-value src sa np base)
        (clone ty))]
    [(IrInstrBoundsCheck idx len msg)
      (IrInstrBoundsCheck
        (opt-inline-remap-value idx sa np base)
        (opt-inline-remap-value len sa np base)
        (clone msg))]
    [(IrInstrStorePtr d s ty)
      (IrInstrStorePtr
        (opt-inline-remap-value d sa np base)
        (opt-inline-remap-value s sa np base)
        (clone ty))]
    [(IrInstrCopyBytes d s size)
      (IrInstrCopyBytes
        (opt-inline-remap-value d sa np base)
        (opt-inline-remap-value s sa np base)
        size)]
    [(IrInstrCall dst name a ty)
      (IrInstrCall
        (opt-inline-rebase-var dst np base)
        (clone name)
        (opt-inline-remap-args a sa np base)
        (clone ty))]
    [(IrInstrCallIndirect dst callee a ty)
      (IrInstrCallIndirect
        (opt-inline-rebase-var dst np base)
        (opt-inline-remap-value callee sa np base)
        (opt-inline-remap-args a sa np base)
        (clone ty))]
    [(IrInstrCallIndirectC dst callee a ty)
      (IrInstrCallIndirectC
        (opt-inline-rebase-var dst np base)
        (opt-inline-remap-value callee sa np base)
        (opt-inline-remap-args a sa np base)
        (clone ty))]
    [_ instr]))

(define (opt-inline-return->mov
  [instr : CompilerIrInstr]
  [dst : i64]
  [ret : AstType]
  [sa : CompilerIrCallArgs]
  [np : i64]
  [base : i64]) : CompilerIrInstr
  (match instr
    [(IrInstrReturn maybe)
      (match maybe
        [(IrSomeValue v)
          (IrInstrMov dst (opt-inline-remap-value v sa np base) (clone ret))]
        [(IrNoValue) (IrInstrMov dst (IrValueUnit) (clone ret))])]
    [_ (IrInstrMov dst (IrValueUnit) (clone ret))]))

(define (opt-inline-expand-instrs
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [ret : AstType]
  [sa : CompilerIrCallArgs]
  [np : i64]
  [base : i64]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) IrInstrNil]
    [(IrInstrCons instr rest)
      (match (box-get rest)
        [(IrInstrNil)
          (compiler-ir-instr-cons
            (opt-inline-return->mov instr dst ret sa np base)
            IrInstrNil)]
        [_
          (compiler-ir-instr-cons
            (opt-inline-clone-instr instr sa np base)
            (opt-inline-expand-instrs (box-get rest) dst ret sa np base))])]))

;; Span policy for inlined clones: prefer the callee instruction's original
;; source span under the clone's new caller/value key. If the callee instruction
;; has no recorded span (notably the synthetic return->mov), use the call-site
;; span so the cloned instruction still points at useful user code.
(define (opt-inline-record-clone-span
  [source-spans : CompilerSourceSpans]
  [out : CompilerSourceSpans]
  [caller : String]
  [call-instr : CompilerIrInstr]
  [callee : String]
  [callee-instr : CompilerIrInstr]
  [cloned : CompilerIrInstr]) : CompilerSourceSpans
  (match (compiler-source-spans-lookup-instr source-spans callee callee-instr)
    [(CompilerSomeSourceSpan span)
      (compiler-source-spans-insert-instr out caller cloned span)]
    [(CompilerNoSourceSpan)
      (match (compiler-source-spans-lookup-instr source-spans caller call-instr)
        [(CompilerSomeSourceSpan span)
          (compiler-source-spans-insert-instr out caller cloned span)]
        [(CompilerNoSourceSpan) out])]))

(define (opt-inline-expand-instrs-with-spans
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [ret : AstType]
  [sa : CompilerIrCallArgs]
  [np : i64]
  [base : i64]
  [source-spans : CompilerSourceSpans]
  [out-spans : CompilerSourceSpans]
  [caller : String]
  [call-instr : CompilerIrInstr]
  [callee : String]) : OptInlineSpanState
  (match instrs
    [(IrInstrNil) (OptInlineSpanState IrInstrNil base 0 out-spans)]
    [(IrInstrCons instr rest)
      (match (box-get rest)
        [(IrInstrNil)
          (let
            [moved : CompilerIrInstr
              (opt-inline-return->mov instr dst ret sa np base)]
            [next-spans : CompilerSourceSpans
              (opt-inline-record-clone-span
                source-spans
                out-spans
                caller
                call-instr
                callee
                instr
                moved)]
            (OptInlineSpanState
              (compiler-ir-instr-cons moved IrInstrNil)
              base
              0
              next-spans))]
        [_
          (let
            [cloned : CompilerIrInstr (opt-inline-clone-instr instr sa np base)]
            [next-spans : CompilerSourceSpans
              (opt-inline-record-clone-span
                source-spans
                out-spans
                caller
                call-instr
                callee
                instr
                cloned)]
            (match (opt-inline-expand-instrs-with-spans
              (box-get rest)
              dst
              ret
              sa
              np
              base
              source-spans
              next-spans
              caller
              call-instr
              callee)
              [(OptInlineSpanState rest-instrs next-vars _ final-spans)
                (OptInlineSpanState
                  (compiler-ir-instr-cons cloned rest-instrs)
                  next-vars
                  0
                  final-spans)]))])]))

(define (opt-inline-single-block-instrs [blocks : CompilerIrBlockList]) : CompilerIrInstrList
  (match blocks
    [(IrBlockCons block _)
      (match block
        [(IrBlock _ seq) (opt-aggregate-instr-seq-append-from seq 0 IrInstrNil)])]
    [_ IrInstrNil]))

(define (opt-inline-append [a : CompilerIrInstrList] [b : CompilerIrInstrList]) : CompilerIrInstrList
  (match a
    [(IrInstrNil) b]
    [(IrInstrCons instr rest)
      (compiler-ir-instr-cons instr (opt-inline-append (box-get rest) b))]))

(define (opt-inline-lookup-inlinable
  [index : OptFunctionIndex]
  [cname : String]
  [caller-name : String]
  [scc-result : OptSccResult]
  [caller-scc : i64]) : OptMaybeFunction
  (match (opt-function-index-slot index cname)
    [(OptSomeI64 callee-slot)
      (if (and
        (>= caller-scc 0)
        (= (array-ref (struct-get scc-result scc-of) callee-slot) caller-scc))
        (OptNoFunction)
        (let
          [callee : CompilerIrFunction
            (array-ref (struct-get index values) callee-slot)]
          (if (opt-inline-callee-ok? callee caller-name)
            (OptSomeFunction callee)
            (OptNoFunction))))]
    [(OptNoI64) (OptNoFunction)]))

(define (opt-inline-try
  [instr : CompilerIrInstr]
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [func-name : String]
  [vars : i64]
  [caller-blocks : i64]
  [added-so-far : i64]
  [scc-result : OptSccResult]
  [caller-scc : i64]) : OptInlineState
  (match instr
    [(IrInstrCall dst cname cargs cret)
      (match (opt-inline-lookup-inlinable
        index
        cname
        func-name
        scc-result
        caller-scc)
        [(OptSomeFunction callee)
          (match callee
            [(IrFunction callee-name cparams _ cvars cblocks)
              (let
                [np : i64 (opt-inline-param-count cparams)]
                (if (opt-inline-arity-ok? cargs np)
                  (let
                    [added-blocks : i64 0]
                    (if (opt-inline-cost-inline?
                      (opt-inline-single-block-cost-instrs cblocks)
                      added-blocks
                      (opt-inline-args-const-count cargs)
                      (opt-inline-census-absorbable?
                        census
                        func-name
                        callee-name)
                      caller-blocks
                      added-so-far)
                      (OptInlineState
                        (opt-inline-expand-instrs
                          (opt-inline-single-block-instrs cblocks)
                          dst
                          cret
                          cargs
                          np
                          vars)
                        (+ vars (opt-inline-frame-growth cvars np))
                        (+ added-so-far added-blocks))
                      (OptInlineState
                        (compiler-ir-instr-cons
                          (IrInstrCall dst cname cargs cret)
                          IrInstrNil)
                        vars
                        added-so-far)))
                  (OptInlineState
                    (compiler-ir-instr-cons
                      (IrInstrCall dst cname cargs cret)
                      IrInstrNil)
                    vars
                    added-so-far)))])]
        [(OptNoFunction)
          (OptInlineState
            (compiler-ir-instr-cons
              (IrInstrCall dst cname cargs cret)
              IrInstrNil)
            vars
            added-so-far)])]
    [_
      (OptInlineState
        (compiler-ir-instr-cons instr IrInstrNil)
        vars
        added-so-far)]))

(define (opt-inline-try-with-spans
  [instr : CompilerIrInstr]
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [func-name : String]
  [vars : i64]
  [caller-blocks : i64]
  [added-so-far : i64]
  [scc-result : OptSccResult]
  [caller-scc : i64]
  [source-spans : CompilerSourceSpans]
  [out-spans : CompilerSourceSpans]) : OptInlineSpanState
  (match instr
    [(IrInstrCall dst cname cargs cret)
      (match (opt-inline-lookup-inlinable
        index
        cname
        func-name
        scc-result
        caller-scc)
        [(OptSomeFunction callee)
          (match callee
            [(IrFunction callee-name cparams _ cvars cblocks)
              (let
                [np : i64 (opt-inline-param-count cparams)]
                (if (opt-inline-arity-ok? cargs np)
                  (let
                    [added-blocks : i64 0]
                    (if (opt-inline-cost-inline?
                      (opt-inline-single-block-cost-instrs cblocks)
                      added-blocks
                      (opt-inline-args-const-count cargs)
                      (opt-inline-census-absorbable?
                        census
                        func-name
                        callee-name)
                      caller-blocks
                      added-so-far)
                      (match (opt-inline-expand-instrs-with-spans
                        (opt-inline-single-block-instrs cblocks)
                        dst
                        cret
                        cargs
                        np
                        vars
                        source-spans
                        out-spans
                        func-name
                        instr
                        cname)
                        [(OptInlineSpanState expanded _ _ next-spans)
                          (OptInlineSpanState
                            expanded
                            (+ vars (opt-inline-frame-growth cvars np))
                            (+ added-so-far added-blocks)
                            next-spans)])
                      (OptInlineSpanState
                        (compiler-ir-instr-cons
                          (IrInstrCall dst cname cargs cret)
                          IrInstrNil)
                        vars
                        added-so-far
                        out-spans)))
                  (OptInlineSpanState
                    (compiler-ir-instr-cons
                      (IrInstrCall dst cname cargs cret)
                      IrInstrNil)
                    vars
                    added-so-far
                    out-spans)))])]
        [(OptNoFunction)
          (OptInlineSpanState
            (compiler-ir-instr-cons
              (IrInstrCall dst cname cargs cret)
              IrInstrNil)
            vars
            added-so-far
            out-spans)])]
    [_
      (OptInlineSpanState
        (compiler-ir-instr-cons instr IrInstrNil)
        vars
        added-so-far
        out-spans)]))

(define (opt-inline-walk-instrs
  [instrs : CompilerIrInstrList]
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [func-name : String]
  [vars : i64]
  [caller-blocks : i64]
  [added-so-far : i64]
  [scc-result : OptSccResult]
  [caller-scc : i64]) : OptInlineState
  (match instrs
    [(IrInstrNil) (OptInlineState IrInstrNil vars added-so-far)]
    [(IrInstrCons instr rest)
      (match (opt-inline-try
        instr
        index
        census
        func-name
        vars
        caller-blocks
        added-so-far
        scc-result
        caller-scc)
        [(OptInlineState expanded vars2 added2)
          (match (opt-inline-walk-instrs
            (box-get rest)
            index
            census
            func-name
            vars2
            caller-blocks
            added2
            scc-result
            caller-scc)
            [(OptInlineState rest-list vars3 added3)
              (OptInlineState
                (opt-inline-append expanded rest-list)
                vars3
                added3)])])]))

(define (opt-inline-walk-instr-seq-from
  [instrs : CompilerIrInstrSeq]
  [pos : i64]
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [func-name : String]
  [vars : i64]
  [caller-blocks : i64]
  [added-so-far : i64]
  [scc-result : OptSccResult]
  [caller-scc : i64]) : OptInlineState
  (if (>= pos (compiler-ir-instr-seq-count instrs))
    (OptInlineState IrInstrNil vars added-so-far)
    (match (opt-inline-try
      (compiler-ir-instr-seq-ref instrs pos)
      index
      census
      func-name
      vars
      caller-blocks
      added-so-far
      scc-result
      caller-scc)
      [(OptInlineState expanded vars2 added2)
        (match (opt-inline-walk-instr-seq-from
          instrs
          (+ pos 1)
          index
          census
          func-name
          vars2
          caller-blocks
          added2
          scc-result
          caller-scc)
          [(OptInlineState rest-list vars3 added3)
            (OptInlineState (opt-inline-append expanded rest-list) vars3 added3)])])))

(define (opt-inline-walk-instr-seq
  [instrs : CompilerIrInstrSeq]
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [func-name : String]
  [vars : i64]
  [caller-blocks : i64]
  [added-so-far : i64]
  [scc-result : OptSccResult]
  [caller-scc : i64]) : OptInlineState
  (opt-inline-walk-instr-seq-from
    instrs
    0
    index
    census
    func-name
    vars
    caller-blocks
    added-so-far
    scc-result
    caller-scc))

(define (opt-inline-walk-instrs-with-spans
  [instrs : CompilerIrInstrList]
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [func-name : String]
  [vars : i64]
  [caller-blocks : i64]
  [added-so-far : i64]
  [scc-result : OptSccResult]
  [caller-scc : i64]
  [source-spans : CompilerSourceSpans]
  [out-spans : CompilerSourceSpans]) : OptInlineSpanState
  (match instrs
    [(IrInstrNil) (OptInlineSpanState IrInstrNil vars added-so-far out-spans)]
    [(IrInstrCons instr rest)
      (match (opt-inline-try-with-spans
        instr
        index
        census
        func-name
        vars
        caller-blocks
        added-so-far
        scc-result
        caller-scc
        source-spans
        out-spans)
        [(OptInlineSpanState expanded vars2 added2 spans2)
          (match (opt-inline-walk-instrs-with-spans
            (box-get rest)
            index
            census
            func-name
            vars2
            caller-blocks
            added2
            scc-result
            caller-scc
            source-spans
            spans2)
            [(OptInlineSpanState rest-list vars3 added3 spans3)
              (OptInlineSpanState
                (opt-inline-append expanded rest-list)
                vars3
                added3
                spans3)])])]))

(define (opt-inline-walk-instr-seq-with-spans-from
  [instrs : CompilerIrInstrSeq]
  [pos : i64]
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [func-name : String]
  [vars : i64]
  [caller-blocks : i64]
  [added-so-far : i64]
  [scc-result : OptSccResult]
  [caller-scc : i64]
  [source-spans : CompilerSourceSpans]
  [out-spans : CompilerSourceSpans]) : OptInlineSpanState
  (if (>= pos (compiler-ir-instr-seq-count instrs))
    (OptInlineSpanState IrInstrNil vars added-so-far out-spans)
    (match (opt-inline-try-with-spans
      (compiler-ir-instr-seq-ref instrs pos)
      index
      census
      func-name
      vars
      caller-blocks
      added-so-far
      scc-result
      caller-scc
      source-spans
      out-spans)
      [(OptInlineSpanState expanded vars2 added2 spans2)
        (match (opt-inline-walk-instr-seq-with-spans-from
          instrs
          (+ pos 1)
          index
          census
          func-name
          vars2
          caller-blocks
          added2
          scc-result
          caller-scc
          source-spans
          spans2)
          [(OptInlineSpanState rest-list vars3 added3 spans3)
            (OptInlineSpanState
              (opt-inline-append expanded rest-list)
              vars3
              added3
              spans3)])])))

(define (opt-inline-walk-instr-seq-with-spans
  [instrs : CompilerIrInstrSeq]
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [func-name : String]
  [vars : i64]
  [caller-blocks : i64]
  [added-so-far : i64]
  [scc-result : OptSccResult]
  [caller-scc : i64]
  [source-spans : CompilerSourceSpans]
  [out-spans : CompilerSourceSpans]) : OptInlineSpanState
  (opt-inline-walk-instr-seq-with-spans-from
    instrs
    0
    index
    census
    func-name
    vars
    caller-blocks
    added-so-far
    scc-result
    caller-scc
    source-spans
    out-spans))

(define (opt-inline-blocks
  [blocks : CompilerIrBlockList]
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [func-name : String]
  [vars : i64]
  [caller-blocks : i64]
  [added-so-far : i64]
  [scc-result : OptSccResult]
  [caller-scc : i64]) : OptInlineBlocks
  (match blocks
    [(IrBlockNil) (OptInlineBlocks IrBlockNil vars added-so-far)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label seq)
          (match (opt-inline-walk-instr-seq
            seq
            index
            census
            func-name
            vars
            caller-blocks
            added-so-far
            scc-result
            caller-scc)
            [(OptInlineState new-instrs vars2 added2)
              (match (opt-inline-blocks
                (box-get rest)
                index
                census
                func-name
                vars2
                caller-blocks
                added2
                scc-result
                caller-scc)
                [(OptInlineBlocks rest-blocks vars3 added3)
                  (OptInlineBlocks
                    (compiler-ir-block-cons
                      (compiler-ir-block label new-instrs)
                      rest-blocks)
                    vars3
                    added3)])])])]
    [(IrBlockArray seq)
      (opt-inline-blocks
        (compiler-ir-block-seq-to-list seq)
        index
        census
        func-name
        vars
        caller-blocks
        added-so-far
        scc-result
        caller-scc)]))

(define (opt-inline-blocks-with-spans
  [blocks : CompilerIrBlockList]
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [func-name : String]
  [vars : i64]
  [caller-blocks : i64]
  [added-so-far : i64]
  [scc-result : OptSccResult]
  [caller-scc : i64]
  [source-spans : CompilerSourceSpans]
  [out-spans : CompilerSourceSpans]) : OptInlineSpanBlocks
  (match blocks
    [(IrBlockNil) (OptInlineSpanBlocks IrBlockNil vars added-so-far out-spans)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label seq)
          (match (opt-inline-walk-instr-seq-with-spans
            seq
            index
            census
            func-name
            vars
            caller-blocks
            added-so-far
            scc-result
            caller-scc
            source-spans
            out-spans)
            [(OptInlineSpanState new-instrs vars2 added2 spans2)
              (match (opt-inline-blocks-with-spans
                (box-get rest)
                index
                census
                func-name
                vars2
                caller-blocks
                added2
                scc-result
                caller-scc
                source-spans
                spans2)
                [(OptInlineSpanBlocks rest-blocks vars3 added3 spans3)
                  (OptInlineSpanBlocks
                    (compiler-ir-block-cons
                      (compiler-ir-block label new-instrs)
                      rest-blocks)
                    vars3
                    added3
                    spans3)])])])]
    [(IrBlockArray seq)
      (opt-inline-blocks-with-spans
        (compiler-ir-block-seq-to-list seq)
        index
        census
        func-name
        vars
        caller-blocks
        added-so-far
        scc-result
        caller-scc
        source-spans
        out-spans)]))

(define (opt-inline-structure-ok? [blocks : CompilerIrBlockList]) : bool
  (if (opt-cfg-block-labels-unique? blocks)
    (if (opt-cfg-successor-targets-known? blocks)
      (let
        [pred-map : OptPredMap (OptPredMap (opt-cfg-index-build blocks))]
        (opt-verify-ok? (opt-verify-phi-predecessors-blocks pred-map blocks)))
      false)
    false))

(define (opt-inline-revert-or-keep
  [fallback : CompilerIrFunction]
  [next : CompilerIrFunction]) : CompilerIrFunction
  (match next
    [(IrFunction _ _ _ _ blocks)
      (if (opt-inline-structure-ok? blocks)
        next
        fallback)]))

(define (opt-inline-function
  [func : CompilerIrFunction]
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [scc-result : OptSccResult]
  [caller-scc : i64]) : CompilerIrFunction
  (match func
    [(IrFunction name params ret vars blocks)
      (let
        [caller-blocks : i64 (compiler-ir-block-list-count blocks)]
        (match (opt-inline-blocks
          blocks
          index
          census
          name
          vars
          caller-blocks
          0
          scc-result
          caller-scc)
          [(OptInlineBlocks new-blocks new-vars _)
            (opt-inline-revert-or-keep
              func
              (IrFunction name params ret new-vars new-blocks))]))]))

(define (opt-inline-function-with-spans
  [func : CompilerIrFunction]
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [scc-result : OptSccResult]
  [caller-scc : i64]
  [source-spans : CompilerSourceSpans]
  [out-spans : CompilerSourceSpans]) : OptInlineSpanProgram
  (match func
    [(IrFunction name params ret vars blocks)
      (let
        [caller-blocks : i64 (compiler-ir-block-list-count blocks)]
        (match (opt-inline-blocks-with-spans
          blocks
          index
          census
          name
          vars
          caller-blocks
          0
          scc-result
          caller-scc
          source-spans
          out-spans)
          [(OptInlineSpanBlocks new-blocks new-vars _ next-spans)
            (let
              [next : CompilerIrFunction
                (IrFunction name params ret new-vars new-blocks)]
              (if (opt-inline-structure-ok? new-blocks)
                (OptInlineSpanProgram
                  (compiler-ir-function-cons next IrFunctionNil)
                  next-spans)
                (OptInlineSpanProgram
                  (compiler-ir-function-cons func IrFunctionNil)
                  out-spans)))]))]))

(define (opt-function-index-to-list-from
  [index : OptFunctionIndex]
  [slot : i64]
  [count : i64]) : CompilerIrFunctionList
  (if (>= slot count)
    IrFunctionNil
    (compiler-ir-function-cons
      (array-ref (struct-get index values) slot)
      (opt-function-index-to-list-from index (+ slot 1) count))))

(define (opt-function-index-to-list [index : OptFunctionIndex]) : CompilerIrFunctionList
  (opt-function-index-to-list-from index 0 (opt-function-index-count index)))

(define (opt-inline-slot-order [scc-result : OptSccResult]) : (Array i64)
  (let
    [order : (Array i64) (struct-get scc-result order)]
    [scc-of : (Array i64) (struct-get scc-result scc-of)]
    [slot-count : i64 (array-length scc-of)]
    [scc-count : i64 (array-length order)]
    [counts : (Array i64) (make-array i64 scc-count)]
    [starts : (Array i64) (make-array i64 scc-count)]
    [next : (Array i64) (make-array i64 scc-count)]
    [slots : (Array i64) (make-array i64 slot-count)]
    [slot : i64 0]
    [order-index : i64 0]
    [offset : i64 0]
    (begin
      (opt-cfg-fill-i64! counts scc-count 0)
      (while (< slot slot-count)
        (let
          [scc-id : i64 (array-ref scc-of slot)]
          (begin
            (array-set! counts scc-id (+ (array-ref counts scc-id) 1))
            (set! slot (+ slot 1)))))
      (while (< order-index scc-count)
        (let
          [scc-id : i64 (array-ref order order-index)]
          (begin
            (array-set! starts scc-id offset)
            (array-set! next scc-id offset)
            (set! offset (+ offset (array-ref counts scc-id)))
            (set! order-index (+ order-index 1)))))
      (set! slot 0)
      (while (< slot slot-count)
        (let
          [scc-id : i64 (array-ref scc-of slot)]
          [slot-index : i64 (array-ref next scc-id)]
          (begin
            (array-set! slots slot-index slot)
            (array-set! next scc-id (+ slot-index 1))
            (set! slot (+ slot 1)))))
      slots)))

(define (opt-inline-process-scc-order!
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [scc-result : OptSccResult]) : unit
  (let
    [scc-of : (Array i64) (struct-get scc-result scc-of)]
    [values : (Array CompilerIrFunction) (struct-get index values)]
    [slot-order : (Array i64) (opt-inline-slot-order scc-result)]
    [index-pos : i64 0]
    [slot-count : i64 (array-length slot-order)]
    (while (< index-pos slot-count)
      (begin
        (let
          [slot : i64 (array-ref slot-order index-pos)]
          [caller-scc : i64 (array-ref scc-of slot)]
          (array-set!
            values
            slot
            (opt-inline-function
              (array-ref values slot)
              index
              census
              scc-result
              caller-scc)))
        (set! index-pos (+ index-pos 1))))))

(define (opt-inline-process-scc-order-with-spans
  [index : OptFunctionIndex]
  [census : OptInlineCensus]
  [scc-result : OptSccResult]
  [spans : CompilerSourceSpans]) : CompilerSourceSpans
  (let
    [scc-of : (Array i64) (struct-get scc-result scc-of)]
    [values : (Array CompilerIrFunction) (struct-get index values)]
    [slot-order : (Array i64) (opt-inline-slot-order scc-result)]
    [index-pos : i64 0]
    [slot-count : i64 (array-length slot-order)]
    [current-spans : CompilerSourceSpans spans]
    (begin
      (while (< index-pos slot-count)
        (begin
          (let
            [slot : i64 (array-ref slot-order index-pos)]
            [caller-scc : i64 (array-ref scc-of slot)]
            (match (opt-inline-function-with-spans
              (array-ref values slot)
              index
              census
              scc-result
              caller-scc
              current-spans
              current-spans)
              [(OptInlineSpanProgram one next-spans)
                (begin
                  (match one
                    [(IrFunctionCons head _) (array-set! values slot head)]
                    [(IrFunctionNil) unit])
                  (set! current-spans next-spans))]))
          (set! index-pos (+ index-pos 1))))
      current-spans)))

;; Inline small single-block leaf callees across the whole program. Only at opt
;; level 2 (the register-allocated quality build).
(define (opt-inline-program-functions
  [functions : CompilerIrFunctionList]
  [level : i64]) : CompilerIrFunctionList
  (if (< level 2)
    functions
    (let
      [devirt : CompilerIrFunctionList
        (opt-devirt-known-function-list functions)]
      [index : OptFunctionIndex (opt-function-index-build devirt)]
      [graph : OptCallGraph (opt-callgraph-build index)]
      [scc-result : OptSccResult (opt-scc-compute graph)]
      [census : OptInlineCensus (opt-inline-census-build index devirt)]
      (begin
        (opt-inline-process-scc-order! index census scc-result)
        (opt-function-index-to-list index)))))

(define (opt-inline-program-functions-with-spans
  [functions : CompilerIrFunctionList]
  [level : i64]
  [spans : CompilerSourceSpans]) : OptInlineSpanProgram
  (if (< level 2)
    (OptInlineSpanProgram functions spans)
    (let
      [devirt : CompilerIrFunctionList
        (opt-devirt-known-function-list functions)]
      [index : OptFunctionIndex (opt-function-index-build devirt)]
      [graph : OptCallGraph (opt-callgraph-build index)]
      [scc-result : OptSccResult (opt-scc-compute graph)]
      [census : OptInlineCensus (opt-inline-census-build index devirt)]
      [next-spans : CompilerSourceSpans
        (opt-inline-process-scc-order-with-spans index census scc-result spans)]
      (OptInlineSpanProgram (opt-function-index-to-list index) next-spans))))

(define (opt-string-set-contains? [items : OptStringSet] [name : String]) : bool
  (match items
    [(OptStringNil) false]
    [(OptStringCons item rest)
      (let
        [rest : OptStringSet (box-get rest)]
        (if (string-eq item name)
          true
          (opt-string-set-contains? rest name)))]))

(define (opt-function-list-defines?
  [functions : CompilerIrFunctionList]
  [name : String]) : bool
  (match functions
    [(IrFunctionNil) false]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction func-name _ _ _ _)
          (if (string-eq func-name name)
            true
            (opt-function-list-defines? (box-get rest) name))])]))

(define (opt-function-list-find
  [functions : CompilerIrFunctionList]
  [name : String]) : OptMaybeFunction
  (match functions
    [(IrFunctionNil) (OptNoFunction)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction func-name _ _ _ _)
          (if (string-eq func-name name)
            (OptSomeFunction func)
            (opt-function-list-find (box-get rest) name))])]))

(define (opt-reach-add-function
  [index : OptFunctionIndex]
  [state : OptReachState]
  [name : String]) : OptReachState
  (match state
    [(OptReachState reachable worklist)
      (if (opt-function-index-defines? index name)
        (if (string-i64-map-contains? reachable name)
          state
          (OptReachState
            (string-i64-map-put reachable name 1)
            (OptStringCons name (box worklist))))
        state)]))

(define (opt-reach-value
  [index : OptFunctionIndex]
  [state : OptReachState]
  [value : CompilerIrValue]) : OptReachState
  (match value
    [(IrValueGlobal name) (opt-reach-add-function index state name)]
    [(IrValueGlobalAddr name) (opt-reach-add-function index state name)]
    [(IrValueFunction name) (opt-reach-add-function index state name)]
    [_ state]))

(define (opt-reach-value-list
  [index : OptFunctionIndex]
  [state : OptReachState]
  [values : CompilerIrValueList]) : OptReachState
  (match values
    [(IrValueNil) state]
    [(IrValueCons value rest)
      (opt-reach-value-list
        index
        (opt-reach-value index state value)
        (box-get rest))]))

(define (opt-reach-call-args-array
  [index : OptFunctionIndex]
  [state : OptReachState]
  [values : (Array CompilerIrValue)]
  [arg-index : i64]) : OptReachState
  (if (>= arg-index (array-length values))
    state
    (opt-reach-call-args-array
      index
      (opt-reach-value index state (array-ref values arg-index))
      values
      (+ arg-index 1))))

(define (opt-reach-call-args
  [index : OptFunctionIndex]
  [state : OptReachState]
  [args : CompilerIrCallArgs]) : OptReachState
  (match args
    [(IrCallArgsNil) state]
    [(IrCallArgsOne value) (opt-reach-value index state value)]
    [(IrCallArgsTwo a b)
      (opt-reach-value index (opt-reach-value index state a) b)]
    [(IrCallArgsArray values) (opt-reach-call-args-array index state values 0)]))

(define (opt-reach-maybe-value
  [index : OptFunctionIndex]
  [state : OptReachState]
  [maybe : CompilerIrMaybeValue]) : OptReachState
  (match maybe
    [(IrNoValue) state]
    [(IrSomeValue value) (opt-reach-value index state value)]))

(define (opt-reach-phi-inputs
  [index : OptFunctionIndex]
  [state : OptReachState]
  [inputs : CompilerIrPhiInputList]) : OptReachState
  (match inputs
    [(IrPhiInputNil) state]
    [(IrPhiInputCons value _ rest)
      (opt-reach-phi-inputs
        index
        (opt-reach-value index state value)
        (box-get rest))]))

(define (opt-reach-instr
  [index : OptFunctionIndex]
  [state : OptReachState]
  [instr : CompilerIrInstr]) : OptReachState
  (match instr
    [(IrInstrMov _ src _) (opt-reach-value index state src)]
    [(IrInstrAlloc _ _) state]
    [(IrInstrAddrOf _ _) state]
    [(IrInstrGep _ base offset _)
      (opt-reach-value index (opt-reach-value index state base) offset)]
    [(IrInstrLoad _ src _) (opt-reach-value index state src)]
    [(IrInstrStorePtr dst src _)
      (opt-reach-value index (opt-reach-value index state dst) src)]
    [(IrInstrCopyBytes dst src _)
      (opt-reach-value index (opt-reach-value index state dst) src)]
    [(IrInstrBoundsCheck idx length _)
      (opt-reach-value index (opt-reach-value index state idx) length)]
    [(IrInstrCast _ src _ _) (opt-reach-value index state src)]
    [(IrInstrBinOp _ _ lhs rhs _)
      (opt-reach-value index (opt-reach-value index state lhs) rhs)]
    [(IrInstrUnOp _ _ src _) (opt-reach-value index state src)]
    [(IrInstrLaneId _ _ _) state]
    [(IrInstrSplat _ value _ _) (opt-reach-value index state value)]
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (opt-reach-value index (opt-reach-value index state lhs) rhs)]
    [(IrInstrVectorReduce _ _ src _ _) (opt-reach-value index state src)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (opt-reach-value index (opt-reach-value index state lhs) rhs)]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (opt-reach-value index (opt-reach-value index state lhs) rhs)]
    [(IrInstrMaskNot _ src _) (opt-reach-value index state src)]
    [(IrInstrMaskReduce _ _ src _) (opt-reach-value index state src)]
    [(IrInstrSelect _ mask on-true on-false _ _)
      (opt-reach-value
        index
        (opt-reach-value index (opt-reach-value index state mask) on-true)
        on-false)]
    [(IrInstrVectorLoad _ base idx _ _)
      (opt-reach-value index (opt-reach-value index state base) idx)]
    [(IrInstrVectorStore base idx value _ _)
      (opt-reach-value
        index
        (opt-reach-value index (opt-reach-value index state base) idx)
        value)]
    [(IrInstrPredicatedStore base idx value mask _ _)
      (opt-reach-value
        index
        (opt-reach-value
          index
          (opt-reach-value index (opt-reach-value index state base) idx)
          value)
        mask)]
    [(IrInstrPredicatedLoad _ base idx mask _ _)
      (opt-reach-value
        index
        (opt-reach-value index (opt-reach-value index state base) idx)
        mask)]
    [(IrInstrTailMask _ idx length _)
      (opt-reach-value index (opt-reach-value index state idx) length)]
    [(IrInstrEntryArgc _) state]
    [(IrInstrEntryArgv _) state]
    [(IrInstrEntryEnvp _) state]
    [(IrInstrCpuId _ leaf subleaf _)
      (opt-reach-value index (opt-reach-value index state leaf) subleaf)]
    [(IrInstrXgetbv _ idx) (opt-reach-value index state idx)]
    [(IrInstrSyscall _ args) (opt-reach-call-args index state args)]
    [(IrInstrCall _ name args _)
      (opt-reach-add-function index (opt-reach-call-args index state args) name)]
    [(IrInstrCallIndirect _ func args _)
      (opt-reach-call-args index (opt-reach-value index state func) args)]
    [(IrInstrCallIndirectC _ func args _)
      (opt-reach-call-args index (opt-reach-value index state func) args)]
    [(IrInstrTailCall name args _)
      (opt-reach-add-function index (opt-reach-call-args index state args) name)]
    [(IrInstrStore _ value _) (opt-reach-value index state value)]
    [(IrInstrJump _) state]
    [(IrInstrBranch cond _ _) (opt-reach-value index state cond)]
    [(IrInstrReturn maybe) (opt-reach-maybe-value index state maybe)]
    [(IrInstrPhi _ inputs _) (opt-reach-phi-inputs index state inputs)]
    ;; #2386: register-group ops carry word-class scalar operands (vars/consts);
    ;; lowering materializes any global/function reference into a var before
    ;; packing, so the group operands themselves reach nothing new.
    [(IrInstrPack _ _ _) state]
    [(IrInstrWord _ src _ _) (opt-reach-value index state src)]))

(define (opt-reach-instrs
  [index : OptFunctionIndex]
  [state : OptReachState]
  [instrs : CompilerIrInstrList]) : OptReachState
  (match instrs
    [(IrInstrNil) state]
    [(IrInstrCons instr rest)
      (opt-reach-instrs
        index
        (opt-reach-instr index state instr)
        (box-get rest))]))

(define (opt-reach-instr-seq-from
  [index : OptFunctionIndex]
  [state : OptReachState]
  [slots : (Array CompilerIrInstr)]
  [instr-index : i64]
  [count : i64]) : OptReachState
  (if (>= instr-index count)
    state
    (opt-reach-instr-seq-from
      index
      (opt-reach-instr index state (array-ref slots instr-index))
      slots
      (+ instr-index 1)
      count)))

(define (opt-reach-instr-seq
  [index : OptFunctionIndex]
  [state : OptReachState]
  [instrs : CompilerIrInstrSeq]) : OptReachState
  (opt-reach-instr-seq-from
    index
    state
    (struct-get instrs slots)
    0
    (struct-get instrs len)))

(define (opt-reach-blocks
  [index : OptFunctionIndex]
  [state : OptReachState]
  [blocks : CompilerIrBlockList]) : OptReachState
  (match blocks
    [(IrBlockNil) state]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (opt-reach-blocks
            index
            (opt-reach-instr-seq index state instrs)
            (box-get rest))])]
    [(IrBlockArray seq)
      (opt-reach-blocks index state (compiler-ir-block-seq-to-list seq))]))

(define (opt-reach-function
  [index : OptFunctionIndex]
  [state : OptReachState]
  [func : CompilerIrFunction]) : OptReachState
  (match func
    [(IrFunction _ _ _ _ blocks) (opt-reach-blocks index state blocks)]))

(define (opt-reach-process [index : OptFunctionIndex] [state : OptReachState]) : OptReachState
  (match state
    [(OptReachState reachable worklist)
      (match worklist
        [(OptStringNil) state]
        [(OptStringCons name rest)
          (let
            [popped : OptReachState (OptReachState reachable (box-get rest))]
            (match (opt-function-index-find index name)
              [(OptSomeFunction func)
                (opt-reach-process index (opt-reach-function index popped func))]
              [(OptNoFunction) (opt-reach-process index popped)]))])]))

(define (opt-reach-global
  [index : OptFunctionIndex]
  [state : OptReachState]
  [global : CompilerIrGlobal]) : OptReachState
  (match global
    [(IrGlobal name _ value)
      ;; A global with a non-constant initializer is set up before main by a
      ;; generated `__global_init_<name>` function (mirrors
      ;; compiler-backend-global-init-name) that the backend calls from the
      ;; startup sequence; it is NOT referenced from the global's IR value, so it
      ;; must be added as a reachability root or the prune drops its definition
      ;; (unresolved-symbol link failure). opt-reach-add-function no-ops when the
      ;; function does not exist (constant-initialized globals).
      (opt-reach-add-function
        index
        (opt-reach-value index state value)
        (string-append "__global_init_" name))]))

(define (opt-reach-globals
  [index : OptFunctionIndex]
  [state : OptReachState]
  [globals : CompilerIrGlobalList]) : OptReachState
  (match globals
    [(IrGlobalNil) state]
    [(IrGlobalCons global rest)
      (opt-reach-globals
        index
        (opt-reach-global index state global)
        (box-get rest))]))

(define (opt-filter-reachable-functions
  [functions : CompilerIrFunctionList]
  [reachable : StringI64Map]) : CompilerIrFunctionList
  (match functions
    [(IrFunctionNil) (IrFunctionNil)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction name _ _ _ _)
          (if (string-i64-map-contains? reachable name)
            (compiler-ir-function-cons
              func
              (opt-filter-reachable-functions (box-get rest) reachable))
            (opt-filter-reachable-functions (box-get rest) reachable))])]))

;; Functions exported via #2143 are lowered to a `provided` IrExtern whose name
;; is the function's logical name. Such functions may be called only from outside
;; TypeLisp IR (e.g. the backend-emitted bounds/division/shift checks call the
;; runtime-prelude handlers), so seed them as roots for the function-level DCE.
(define (opt-reach-add-provided-externs
  [index : OptFunctionIndex]
  [externs : CompilerIrExternList]
  [state : OptReachState]) : OptReachState
  (match externs
    [(IrExternNil) state]
    [(IrExternCons ext rest)
      (match ext
        [(IrExtern name _ _ _ _ provided)
          (opt-reach-add-provided-externs
            index
            (box-get rest)
            (if provided
              (opt-reach-add-function index state name)
              state))])]))

(define (opt-prune-unreachable-functions
  [globals : CompilerIrGlobalList]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : CompilerIrFunctionList
  (if (opt-function-list-defines? functions "main")
    (let
      [index : OptFunctionIndex (opt-function-index-build functions)]
      [reachable : StringI64Map
        (string-i64-map-with-capacity
          (opt-function-index-capacity (opt-function-list-count functions)))]
      (match (opt-reach-process
        index
        (opt-reach-globals
          index
          (opt-reach-add-provided-externs
            index
            externs
            (opt-reach-add-function
              index
              (OptReachState reachable (OptStringNil))
              "main"))
          globals))
        [(OptReachState reachable-out _)
          (opt-filter-reachable-functions functions reachable-out)]))
    functions))

(define (optimize-program [program : CompilerIrProgram]) : CompilerIrProgram
  (optimize-program-with-level program (compiler-optimize-default-level)))

(define (optimize-program-with-level
  [program : CompilerIrProgram]
  [level : i64]) : CompilerIrProgram
  (match program
    [(IrProgram globals functions externs)
      (if (= level 0)
        program
        ;; Levels 1 (cheap) and 2 (quality) both prune unreachable functions;
        ;; inlining self-gates to level 2 inside opt-inline-program-functions.
        (begin
          (cfg compile-profile (compiler-opt-profile-start))
          (let
            [reachable-functions : CompilerIrFunctionList
              (opt-inline-program-functions functions level)]
            (begin
              (cfg compile-profile (compiler-opt-profile-finish "pre_prune"))
              (cfg compile-profile (compiler-opt-profile-start))
              (let
                [optimized-functions : CompilerIrFunctionList
                  (optimize-function-list-with-level reachable-functions level)]
                (begin
                  (cfg
                    compile-profile
                    (compiler-opt-profile-finish "functions"))
                  (cfg compile-profile (compiler-opt-profile-start))
                  (let
                    [final-functions : CompilerIrFunctionList
                      (opt-prune-unreachable-functions
                        globals
                        optimized-functions
                        externs)]
                    (begin
                      (cfg
                        compile-profile
                        (compiler-opt-profile-finish "post_prune"))
                      (IrProgram globals final-functions externs)))))))))]))

(define (opt-remap-spans-prepend-entry
  [spans : CompilerSourceSpans]
  [key : String]
  [span : AstSourceSpan]) : CompilerSourceSpans
  (match spans
    [(CompilerSourceSpans entries instr-entries instr-count)
      (CompilerSourceSpans
        entries
        (CompilerSourceSpansEntryCons
          (CompilerSourceSpansEntry key span)
          (box instr-entries))
        (+ instr-count 1))]))

(define (opt-remap-spans-prepend-instr
  [spans : CompilerSourceSpans]
  [function : String]
  [instr : CompilerIrInstr]
  [span : AstSourceSpan]) : CompilerSourceSpans
  (match instr
    [(IrInstrMov dst _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrAlloc dst _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrAddrOf dst _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrGep dst _ _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrLoad dst _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrCast dst _ _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrBinOp dst _ _ _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrUnOp dst _ _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrLaneId dst _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrSplat dst _ _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrVectorBinOp dst _ _ _ _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrVectorReduce dst _ _ _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrVectorCompare dst _ _ _ _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrMaskBinOp dst _ _ _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrMaskNot dst _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrMaskReduce dst _ _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrSelect dst _ _ _ _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrVectorLoad dst _ _ _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrPredicatedLoad dst _ _ _ _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrTailMask dst _ _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrEntryArgc dst)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrEntryArgv dst)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrEntryEnvp dst)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrCpuId dst _ _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrXgetbv dst _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrSyscall dst _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrCall dst _ _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [(IrInstrStore name _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-store-key function name)
        span)]
    [(IrInstrPhi dst _ _)
      (opt-remap-spans-prepend-entry
        spans
        (compiler-source-spans-value-key function dst)
        span)]
    [_ spans]))

(define (opt-remap-spans-instr
  [source-spans : CompilerSourceSpans]
  [out : CompilerSourceSpans]
  [function : String]
  [instr : CompilerIrInstr]) : CompilerSourceSpans
  (match (compiler-source-spans-lookup-instr source-spans function instr)
    [(CompilerSomeSourceSpan span)
      (opt-remap-spans-prepend-instr out function instr span)]
    [(CompilerNoSourceSpan) out]))

(define (opt-remap-spans-instrs
  [source-spans : CompilerSourceSpans]
  [out : CompilerSourceSpans]
  [function : String]
  [instrs : CompilerIrInstrList]) : CompilerSourceSpans
  (match instrs
    [(IrInstrNil) out]
    [(IrInstrCons instr rest)
      (opt-remap-spans-instrs
        source-spans
        (opt-remap-spans-instr source-spans out function instr)
        function
        (box-get rest))]))

(define (opt-remap-spans-instr-seq-from
  [source-spans : CompilerSourceSpans]
  [out : CompilerSourceSpans]
  [function : String]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : CompilerSourceSpans
  (if (>= index (compiler-ir-instr-seq-count instrs))
    out
    (opt-remap-spans-instr-seq-from
      source-spans
      (opt-remap-spans-instr
        source-spans
        out
        function
        (compiler-ir-instr-seq-ref instrs index))
      function
      instrs
      (+ index 1))))

(define (opt-remap-spans-instr-seq
  [source-spans : CompilerSourceSpans]
  [out : CompilerSourceSpans]
  [function : String]
  [instrs : CompilerIrInstrSeq]) : CompilerSourceSpans
  (opt-remap-spans-instr-seq-from source-spans out function instrs 0))

(define (opt-remap-spans-blocks
  [source-spans : CompilerSourceSpans]
  [out : CompilerSourceSpans]
  [function : String]
  [blocks : CompilerIrBlockList]) : CompilerSourceSpans
  (match blocks
    [(IrBlockNil) out]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (opt-remap-spans-blocks
            source-spans
            (opt-remap-spans-instr-seq source-spans out function instrs)
            function
            (box-get rest))])]
    [(IrBlockArray seq)
      (opt-remap-spans-blocks
        source-spans
        out
        function
        (compiler-ir-block-seq-to-list seq))]))

(define (opt-remap-spans-function
  [source-spans : CompilerSourceSpans]
  [out : CompilerSourceSpans]
  [func : CompilerIrFunction]) : CompilerSourceSpans
  (match func
    [(IrFunction name _ _ _ blocks)
      (opt-remap-spans-blocks source-spans out name blocks)]))

(define (opt-remap-spans-functions
  [source-spans : CompilerSourceSpans]
  [out : CompilerSourceSpans]
  [funcs : CompilerIrFunctionList]) : CompilerSourceSpans
  (match funcs
    [(IrFunctionNil) out]
    [(IrFunctionCons func rest)
      (opt-remap-spans-functions
        source-spans
        (opt-remap-spans-function source-spans out func)
        (box-get rest))]))

(define (opt-remap-spans-fast-path? [source-spans : CompilerSourceSpans]) : bool
  (compiler-source-spans-instr-count-at-least? source-spans 2049))

(define (opt-remap-spans-program
  [source-spans : CompilerSourceSpans]
  [program : CompilerIrProgram]) : CompilerSourceSpans
  (if (opt-remap-spans-fast-path? source-spans)
    (compiler-source-spans-clear-instrs source-spans)
    (match program
      [(IrProgram _ functions _)
        (opt-remap-spans-functions
          source-spans
          (compiler-source-spans-clear-instrs source-spans)
          functions)])))

(define (optimize-program-with-spans-and-level
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]
  [level : i64]) : CompilerOptimizedProgram
  (match program
    [(IrProgram globals functions externs)
      (if (= level 0)
        (CompilerOptimizedProgram
          program
          (opt-remap-spans-program spans program))
        (begin
          (cfg compile-profile (compiler-opt-profile-start))
          (match (opt-inline-program-functions-with-spans functions level spans)
            [(OptInlineSpanProgram reachable-functions inline-spans)
              (begin
                (cfg compile-profile (compiler-opt-profile-finish "pre_prune"))
                (cfg compile-profile (compiler-opt-profile-start))
                (let
                  [optimized-functions : CompilerIrFunctionList
                    (optimize-function-list-with-level
                      reachable-functions
                      level)]
                  (begin
                    (cfg
                      compile-profile
                      (compiler-opt-profile-finish "functions"))
                    (cfg compile-profile (compiler-opt-profile-start))
                    (let
                      [final-functions : CompilerIrFunctionList
                        (opt-prune-unreachable-functions
                          globals
                          optimized-functions
                          externs)]
                      [optimized : CompilerIrProgram
                        (IrProgram globals final-functions externs)]
                      (begin
                        (cfg
                          compile-profile
                          (compiler-opt-profile-finish "post_prune"))
                        (CompilerOptimizedProgram
                          optimized
                          (opt-remap-spans-program inline-spans optimized)))))))])))]))

(define (optimize-program-with-spans
  [program : CompilerIrProgram]
  [spans : CompilerSourceSpans]) : CompilerOptimizedProgram
  (optimize-program-with-spans-and-level
    program
    spans
    (compiler-optimize-default-level)))

;; --- self-test ---------------------------------------------------------------
(define (opt-count-arith-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+ (opt-arith-instr-count instr) (opt-count-arith-instrs (box-get rest)))]))

(define (opt-arith-instr-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrBinOp _ _ _ _ _) 1]
    [(IrInstrUnOp _ _ _ _) 1]
    [_ 0]))

(define (opt-count-arith-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-arith-instr-seq-from
      slots
      (+ index 1)
      count
      (+ acc (opt-arith-instr-count (array-ref slots index))))))

(define (opt-count-arith-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-arith-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-sum-mov-i64 [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+ (opt-mov-i64-value instr) (opt-sum-mov-i64 (box-get rest)))]))

(define (opt-mov-i64-value [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrMov _ (IrValueI64 n) _) n]
    [_ 0]))

(define (opt-count-mov-i64-value [instrs : CompilerIrInstrList] [needle : i64]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrMov _ (IrValueI64 n) _)
            (if (= n needle)
              1
              0)]
          [_ 0])
        (opt-count-mov-i64-value (box-get rest) needle))]))

(define (opt-count-mov-i64-value-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [needle : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-mov-i64-value-instr-seq-from
      slots
      (+ index 1)
      count
      needle
      (+
        acc
        (match (array-ref slots index)
          [(IrInstrMov _ (IrValueI64 n) _)
            (if (= n needle)
              1
              0)]
          [_ 0])))))

(define (opt-count-mov-i64-value-instr-seq
  [instrs : CompilerIrInstrSeq]
  [needle : i64]) : i64
  (opt-count-mov-i64-value-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    needle
    0))

(define (opt-count-mov-bool-value
  [instrs : CompilerIrInstrList]
  [needle : bool]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrMov _ (IrValueBool b) _)
            (if needle
              (if b
                1
                0)
              (if b
                0
                1))]
          [_ 0])
        (opt-count-mov-bool-value (box-get rest) needle))]))

(define (opt-sum-mov-var-src [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrMov _ (IrValueVar id) _) id]
          [_ 0])
        (opt-sum-mov-var-src (box-get rest)))]))

(define (opt-mov-dst-type-tag [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrMov d _ ty)
          (if (= d dst)
            (ast-type-tag ty)
            (opt-mov-dst-type-tag (box-get rest) dst))]
        [_ (opt-mov-dst-type-tag (box-get rest) dst)])]))

(define (opt-mov-dst-i64-value
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [fallback : i64]) : i64
  (match instrs
    [(IrInstrNil) fallback]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrMov d (IrValueI64 n) _)
          (if (= d dst)
            n
            (opt-mov-dst-i64-value (box-get rest) dst fallback))]
        [_ (opt-mov-dst-i64-value (box-get rest) dst fallback)])]))

(define (opt-mov-dst-i64-value-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [dst : i64]
  [fallback : i64]) : i64
  (if (>= index count)
    fallback
    (match (array-ref slots index)
      [(IrInstrMov d (IrValueI64 n) _)
        (if (= d dst)
          n
          (opt-mov-dst-i64-value-instr-seq-from
            slots
            (+ index 1)
            count
            dst
            fallback))]
      [_
        (opt-mov-dst-i64-value-instr-seq-from
          slots
          (+ index 1)
          count
          dst
          fallback)])))

(define (opt-mov-dst-i64-value-instr-seq
  [instrs : CompilerIrInstrSeq]
  [dst : i64]
  [fallback : i64]) : i64
  (opt-mov-dst-i64-value-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    dst
    fallback))

(define (opt-mov-dst-bool-value?
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [needle : bool]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrMov d (IrValueBool b) _)
          (if (= d dst)
            (if needle
              b
              (not b))
            (opt-mov-dst-bool-value? (box-get rest) dst needle))]
        [_ (opt-mov-dst-bool-value? (box-get rest) dst needle)])]))

(define (opt-mov-dst-char-code
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [fallback : i64]) : i64
  (match instrs
    [(IrInstrNil) fallback]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrMov d (IrValueChar c) _)
          (if (= d dst)
            (cast c : i64)
            (opt-mov-dst-char-code (box-get rest) dst fallback))]
        [_ (opt-mov-dst-char-code (box-get rest) dst fallback)])]))

(define (opt-test-span [line : i64] [col : i64]) : AstSourceSpan
  (AstSourceSpan line col line col))

(define (opt-source-span-line-col-ok?
  [span : AstSourceSpan]
  [line : i64]
  [col : i64]) : bool
  (and
    (= (struct-get span start-line) line)
    (= (struct-get span start-col) col)))

(define (opt-span-lookup-ok?
  [spans : CompilerSourceSpans]
  [function : String]
  [instr : CompilerIrInstr]
  [line : i64]
  [col : i64]) : bool
  (match (compiler-source-spans-lookup-instr spans function instr)
    [(CompilerSomeSourceSpan span) (opt-source-span-line-col-ok? span line col)]
    [(CompilerNoSourceSpan) false]))

(define (opt-span-lookup-missing?
  [spans : CompilerSourceSpans]
  [function : String]
  [instr : CompilerIrInstr]) : bool
  (match (compiler-source-spans-lookup-instr spans function instr)
    [(CompilerSomeSourceSpan _) false]
    [(CompilerNoSourceSpan) true]))

(define (opt-spans-function [instrs : CompilerIrInstrList]) : CompilerIrFunction
  (IrFunction
    "main"
    IrParamNil
    (AstTyI64)
    4
    (compiler-ir-block-cons (compiler-ir-block "entry" instrs) IrBlockNil)))

(define (opt-spans-program [instrs : CompilerIrInstrList]) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (compiler-ir-function-cons (opt-spans-function instrs) IrFunctionNil)
    IrExternNil))

(define (opt-spans-base) : CompilerSourceSpans
  (compiler-source-spans-insert
    (compiler-source-spans-empty)
    "main"
    (opt-test-span 3 1)))

(define (compiler-optimize-spans-dce-ok?) : bool
  (let
    [dead : CompilerIrInstr (IrInstrMov 0 (IrValueI64 1) (AstTyI64))]
    [live : CompilerIrInstr (IrInstrCall 1 "opaque" (IrCallArgsNil) (AstTyI64))]
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        dead
        (compiler-ir-instr-cons
          live
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 1)))
            IrInstrNil)))]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-insert-instr
          (opt-spans-base)
          "main"
          dead
          (opt-test-span 21 3))
        "main"
        live
        (opt-test-span 31 5))]
    (match (optimize-program-with-spans-and-level
      (opt-spans-program instrs)
      spans
      1)
      [(CompilerOptimizedProgram _ optimized-spans)
        (and
          (= (compiler-source-spans-instr-count optimized-spans) 1)
          (and
            (opt-span-lookup-missing? optimized-spans "main" dead)
            (opt-span-lookup-ok? optimized-spans "main" live 31 5)))])))

(define (compiler-optimize-spans-fold-ok?) : bool
  (let
    [folded : CompilerIrInstr
      (IrInstrBinOp 2 (IrBinAdd) (IrValueI64 20) (IrValueI64 22) (AstTyI64))]
    [rewritten : CompilerIrInstr (IrInstrMov 2 (IrValueI64 42) (AstTyI64))]
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        folded
        (compiler-ir-instr-cons
          (IrInstrAddrOf 3 2)
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 3)))
            IrInstrNil)))]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (opt-spans-base)
        "main"
        folded
        (opt-test-span 41 7))]
    (match (optimize-program-with-spans-and-level
      (opt-spans-program instrs)
      spans
      2)
      [(CompilerOptimizedProgram _ optimized-spans)
        (opt-span-lookup-ok? optimized-spans "main" rewritten 41 7)])))

(define (compiler-optimize-spans-cse-ok?) : bool
  (let
    [first : CompilerIrInstr
      (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))]
    [second : CompilerIrInstr
      (IrInstrBinOp 3 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))]
    [rewritten : CompilerIrInstr (IrInstrMov 3 (IrValueVar 2) (AstTyI64))]
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        first
        (compiler-ir-instr-cons
          second
          (compiler-ir-instr-cons
            (IrInstrAddrOf 4 3)
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 4)))
              IrInstrNil))))]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-insert-instr
          (opt-spans-base)
          "main"
          first
          (opt-test-span 51 9))
        "main"
        second
        (opt-test-span 61 11))]
    (match (optimize-program-with-spans-and-level
      (opt-spans-program instrs)
      spans
      2)
      [(CompilerOptimizedProgram _ optimized-spans)
        (and
          (opt-span-lookup-ok? optimized-spans "main" first 51 9)
          (opt-span-lookup-ok? optimized-spans "main" rewritten 61 11))])))

(define (opt-inline-span-callee-call) : CompilerIrInstr
  (IrInstrCall 1 "opaque" (IrCallArgsOne (IrValueVar 0)) (AstTyI64)))

(define (opt-inline-span-callee) : CompilerIrFunction
  (IrFunction
    "inline_span"
    (compiler-ir-param-cons (IrParam "value" (AstTyI64) 0) IrParamNil)
    (AstTyI64)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (opt-inline-span-callee-call)
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 1)))
            IrInstrNil)))
      IrBlockNil)))

(define (opt-inline-span-caller-call) : CompilerIrInstr
  (IrInstrCall 0 "inline_span" (IrCallArgsOne (IrValueI64 7)) (AstTyI64)))

(define (opt-inline-span-caller) : CompilerIrFunction
  (IrFunction
    "main"
    IrParamNil
    (AstTyI64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (opt-inline-span-caller-call)
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 0)))
            IrInstrNil)))
      IrBlockNil)))

(define (opt-inline-span-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (compiler-ir-function-cons
      (opt-inline-span-caller)
      (compiler-ir-function-cons (opt-inline-span-callee) IrFunctionNil))
    IrExternNil))

(define (compiler-optimize-spans-inline-callee-ok?) : bool
  (let
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (compiler-source-spans-insert-instr
          (opt-spans-base)
          "inline_span"
          (opt-inline-span-callee-call)
          (opt-test-span 71 13))
        "main"
        (opt-inline-span-caller-call)
        (opt-test-span 81 15))]
    [cloned-call : CompilerIrInstr
      (IrInstrCall 1 "opaque" (IrCallArgsOne (IrValueI64 7)) (AstTyI64))]
    (match (optimize-program-with-spans-and-level
      (opt-inline-span-program)
      spans
      2)
      [(CompilerOptimizedProgram _ optimized-spans)
        (opt-span-lookup-ok? optimized-spans "main" cloned-call 71 13)])))

(define (compiler-optimize-spans-inline-fallback-ok?) : bool
  (let
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (opt-spans-base)
        "main"
        (opt-inline-span-caller-call)
        (opt-test-span 91 17))]
    [cloned-call : CompilerIrInstr
      (IrInstrCall 1 "opaque" (IrCallArgsOne (IrValueI64 7)) (AstTyI64))]
    (match (optimize-program-with-spans-and-level
      (opt-inline-span-program)
      spans
      2)
      [(CompilerOptimizedProgram _ optimized-spans)
        (opt-span-lookup-ok? optimized-spans "main" cloned-call 91 17)])))

(define (compiler-optimize-spans-non-inline-call-ok?) : bool
  (let
    [call : CompilerIrInstr
      (IrInstrCall 1 "opaque" (IrCallArgsOne (IrValueI64 5)) (AstTyI64))]
    [instrs : CompilerIrInstrList
      (compiler-ir-instr-cons
        call
        (compiler-ir-instr-cons
          (IrInstrReturn (IrSomeValue (IrValueVar 1)))
          IrInstrNil))]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (opt-spans-base)
        "main"
        call
        (opt-test-span 101 19))]
    (match (optimize-program-with-spans-and-level
      (opt-spans-program instrs)
      spans
      2)
      [(CompilerOptimizedProgram _ optimized-spans)
        (opt-span-lookup-ok? optimized-spans "main" call 101 19)])))

(define (compiler-optimize-spans-self-test) : i64
  (if (and
    (compiler-optimize-spans-dce-ok?)
    (and
      (compiler-optimize-spans-fold-ok?)
      (and
        (compiler-optimize-spans-cse-ok?)
        (and
          (compiler-optimize-spans-inline-callee-ok?)
          (and
            (compiler-optimize-spans-inline-fallback-ok?)
            (compiler-optimize-spans-non-inline-call-ok?))))))
    42
    1))

(define (opt-aggregate-test-alloc) : CompilerIrInstr
  (IrInstrCall
    1
    "tl_alloc"
    (IrCallArgsOne (IrValueI64 16))
    (AstTyStruct (intern "Pair"))))

(define (opt-aggregate-positive-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (IrInstrGep 2 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
      (compiler-ir-instr-cons
        (IrInstrStorePtr (IrValueVar 2) (IrValueI64 10) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrGep 3 (IrValueVar 1) (IrValueI64 8) (AstTyU8))
          (compiler-ir-instr-cons
            (IrInstrStorePtr (IrValueVar 3) (IrValueBool true) (AstTyBool))
            (compiler-ir-instr-cons
              (IrInstrGep 4 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
              (compiler-ir-instr-cons
                (IrInstrLoad 5 (IrValueVar 4) (AstTyI64))
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 5)))
                  IrInstrNil)))))))))

(define (opt-aggregate-returned-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (IrInstrReturn (IrSomeValue (IrValueVar 1)))
      IrInstrNil)))

(define (opt-aggregate-passed-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (IrInstrCall 2 "touch" (IrCallArgsOne (IrValueVar 1)) (AstTyUnit))
      (compiler-ir-instr-cons
        (IrInstrReturn (IrSomeValue (IrValueI64 0)))
        IrInstrNil))))

(define (opt-aggregate-global-store-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (IrInstrStore "escaped" (IrValueVar 1) (AstTyU64))
      (compiler-ir-instr-cons
        (IrInstrReturn (IrSomeValue (IrValueI64 0)))
        IrInstrNil))))

(define (opt-aggregate-store-through-other-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (IrInstrStorePtr (IrValueVar 99) (IrValueVar 1) (AstTyU64))
      (compiler-ir-instr-cons
        (IrInstrReturn (IrSomeValue (IrValueI64 0)))
        IrInstrNil))))

(define (opt-aggregate-unknown-offset-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (IrInstrGep 2 (IrValueVar 1) (IrValueVar 9) (AstTyU8))
      (compiler-ir-instr-cons
        (IrInstrReturn (IrSomeValue (IrValueI64 0)))
        IrInstrNil))))

(define (opt-aggregate-call-separated-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (IrInstrGep 2 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
      (compiler-ir-instr-cons
        (IrInstrStorePtr (IrValueVar 2) (IrValueI64 10) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrCall 9 "touch" (IrCallArgsNil) (AstTyUnit))
          (compiler-ir-instr-cons
            (IrInstrGep 3 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
            (compiler-ir-instr-cons
              (IrInstrLoad 4 (IrValueVar 3) (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 4)))
                IrInstrNil))))))))

(define (opt-aggregate-predicated-memory-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (IrInstrGep 2 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
      (compiler-ir-instr-cons
        (IrInstrStorePtr (IrValueVar 2) (IrValueI64 10) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrPredicatedLoad
            8
            (IrValueVar 99)
            (IrValueI64 0)
            (IrValueBool true)
            4
            (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrGep 3 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
            (compiler-ir-instr-cons
              (IrInstrLoad 4 (IrValueVar 3) (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 4)))
                IrInstrNil))))))))

(define (opt-aggregate-phi-flowed-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (opt-aggregate-test-alloc)
        (compiler-ir-instr-cons (IrInstrJump "join") IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "join"
        (compiler-ir-instr-cons
          (IrInstrPhi
            2
            (compiler-ir-phi-input-cons (IrValueVar 1) "entry" (IrPhiInputNil))
            (AstTyU64))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueI64 0)))
            IrInstrNil)))
      IrBlockNil)))

(define (opt-aggregate-no-candidates? [instrs : CompilerIrInstrList]) : bool
  (=
    (opt-aggregate-candidate-list-count
      (opt-aggregate-allocation-candidates (opt-spans-program instrs)))
    0))

(define (opt-aggregate-phi-flowed-rejected?) : bool
  (=
    (opt-aggregate-candidate-list-count
      (opt-aggregate-allocation-candidates
        (IrProgram
          IrGlobalNil
          (compiler-ir-function-cons
            (IrFunction
              "main"
              IrParamNil
              (AstTyI64)
              4
              (opt-aggregate-phi-flowed-blocks))
            IrFunctionNil)
          IrExternNil)))
    0))

(define (opt-aggregate-positive-classified?) : bool
  (match (opt-aggregate-allocation-candidates
    (opt-spans-program (opt-aggregate-positive-instrs)))
    [(OptAggregateAllocCandidateCons candidate rest)
      (match (box-get rest)
        [(OptAggregateAllocCandidateNil)
          (match candidate
            [(OptAggregateAllocCandidate base ty size ptrs accesses)
              (and
                (= base 1)
                (and
                  (= size 16)
                  (and
                    (opt-type-eq ty (AstTyStruct (intern "Pair")))
                    (and
                      (= (opt-aggregate-pointer-list-count ptrs) 3)
                      (and
                        (= (opt-aggregate-access-list-count accesses) 3)
                        (and
                          (= (opt-aggregate-access-list-store-count accesses) 2)
                          (= (opt-aggregate-access-list-load-count accesses) 1)))))))])]
        [_ false])]
    [_ false]))

(define (compiler-optimize-aggregate-candidate-self-test) : i64
  (core/cond
    (not (opt-aggregate-positive-classified?))
    1
    (not (opt-aggregate-no-candidates? (opt-aggregate-returned-instrs)))
    2
    (not (opt-aggregate-no-candidates? (opt-aggregate-passed-instrs)))
    3
    (not (opt-aggregate-no-candidates? (opt-aggregate-global-store-instrs)))
    4
    (not
      (opt-aggregate-no-candidates? (opt-aggregate-store-through-other-instrs)))
    5
    (not (opt-aggregate-no-candidates? (opt-aggregate-unknown-offset-instrs)))
    6
    (not (opt-aggregate-no-candidates? (opt-aggregate-call-separated-instrs)))
    7
    (not (opt-aggregate-phi-flowed-rejected?))
    8
    (not
      (opt-aggregate-no-candidates? (opt-aggregate-predicated-memory-instrs)))
    9
    42))

(define (opt-aggregate-array-local-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrCall
      1
      "tl_alloc"
      (IrCallArgsOne (IrValueI64 16))
      (ast-ty-array (AstTyI64) 2))
    (compiler-ir-instr-cons
      (IrInstrGep 2 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
      (compiler-ir-instr-cons
        (IrInstrStorePtr
          (IrValueVar 2)
          (IrValueVar 9)
          (ast-ty-array (AstTyI64) 2))
        (compiler-ir-instr-cons
          (IrInstrGep 3 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
          (compiler-ir-instr-cons
            (IrInstrLoad 4 (IrValueVar 3) (ast-ty-array (AstTyI64) 2))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueI64 0)))
              IrInstrNil)))))))

(define (opt-count-tl-alloc-calls [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrCall _ name _ _)
            (if (string-eq name "tl_alloc")
              1
              0)]
          [_ 0])
        (opt-count-tl-alloc-calls (box-get rest)))]))

(define (opt-count-ir-alloc-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrAlloc _ _) 1]
          [_ 0])
        (opt-count-ir-alloc-instrs (box-get rest)))]))

(define (opt-count-addr-of-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrAddrOf _ _) 1]
          [_ 0])
        (opt-count-addr-of-instrs (box-get rest)))]))

(define (opt-aggregate-promote-test-function [instrs : CompilerIrInstrList]) : CompilerIrFunction
  (opt-aggregate-stack-promote-function (opt-spans-function instrs)))

(define (opt-aggregate-promote-test-instrs [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match (opt-aggregate-promote-test-function instrs)
    [(IrFunction _ _ _ _ blocks)
      (match (compiler-ir-block-list-force-cons blocks)
        [(IrBlockCons block _)
          (match block
            [(IrBlock _ optimized) (compiler-ir-instr-seq-to-list optimized)])]
        [(IrBlockArray _) IrInstrNil]
        [(IrBlockNil) IrInstrNil])]))

(define (opt-aggregate-promote-test-frame [instrs : CompilerIrInstrList]) : i64
  (match (opt-aggregate-promote-test-function instrs)
    [(IrFunction _ _ _ frame _) frame]))

(define (compiler-optimize-aggregate-promote-self-test) : i64
  (let
    [positive : CompilerIrInstrList
      (opt-aggregate-promote-test-instrs (opt-aggregate-positive-instrs))]
    [returned : CompilerIrInstrList
      (opt-aggregate-promote-test-instrs (opt-aggregate-returned-instrs))]
    [passed : CompilerIrInstrList
      (opt-aggregate-promote-test-instrs (opt-aggregate-passed-instrs))]
    [stored : CompilerIrInstrList
      (opt-aggregate-promote-test-instrs (opt-aggregate-global-store-instrs))]
    [unknown-offset : CompilerIrInstrList
      (opt-aggregate-promote-test-instrs (opt-aggregate-unknown-offset-instrs))]
    [call-separated : CompilerIrInstrList
      (opt-aggregate-promote-test-instrs (opt-aggregate-call-separated-instrs))]
    [array-local : CompilerIrInstrList
      (opt-aggregate-promote-test-instrs (opt-aggregate-array-local-instrs))]
    [level0 : CompilerIrProgram
      (optimize-program-with-level
        (opt-spans-program (opt-aggregate-positive-instrs))
        0)]
    [level2 : CompilerIrProgram
      (optimize-program-with-level
        (opt-spans-program (opt-aggregate-positive-instrs))
        2)]
    (core/cond
      (not (= (opt-count-tl-alloc-calls positive) 0))
      1
      (not (= (opt-count-ir-alloc-instrs positive) 1))
      2
      (not (= (opt-count-addr-of-instrs positive) 1))
      3
      (not
        (= (opt-aggregate-promote-test-frame (opt-aggregate-positive-instrs)) 6))
      4
      (not (= (opt-count-tl-alloc-calls returned) 1))
      5
      (not (= (opt-count-tl-alloc-calls passed) 1))
      6
      (not (= (opt-count-tl-alloc-calls stored) 1))
      7
      (not (= (opt-count-tl-alloc-calls unknown-offset) 1))
      8
      (not (= (opt-count-tl-alloc-calls call-separated) 1))
      9
      (not (= (opt-count-tl-alloc-calls array-local) 1))
      10
      (not (= (opt-count-tl-alloc-calls (opt-program-first-instrs level0)) 1))
      11
      (not (= (opt-count-tl-alloc-calls (opt-program-first-instrs level2)) 0))
      12
      42)))

(define (opt-aggregate-repeated-load-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (IrInstrGep 2 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
      (compiler-ir-instr-cons
        (IrInstrStorePtr (IrValueVar 2) (IrValueI64 10) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrGep 3 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
          (compiler-ir-instr-cons
            (IrInstrLoad 4 (IrValueVar 3) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrGep 5 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
              (compiler-ir-instr-cons
                (IrInstrLoad 6 (IrValueVar 5) (AstTyI64))
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 6)))
                  IrInstrNil)))))))))

(define (opt-aggregate-overwritten-load-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (IrInstrGep 2 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
      (compiler-ir-instr-cons
        (IrInstrStorePtr (IrValueVar 2) (IrValueI64 10) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrStorePtr (IrValueVar 2) (IrValueI64 20) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrGep 3 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
            (compiler-ir-instr-cons
              (IrInstrLoad 4 (IrValueVar 3) (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 4)))
                IrInstrNil))))))))

(define (opt-aggregate-escaped-then-load-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (IrInstrStore "escaped" (IrValueVar 1) (AstTyU64))
      (compiler-ir-instr-cons
        (IrInstrGep 2 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
        (compiler-ir-instr-cons
          (IrInstrStorePtr (IrValueVar 2) (IrValueI64 10) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrGep 3 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
            (compiler-ir-instr-cons
              (IrInstrLoad 4 (IrValueVar 3) (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 4)))
                IrInstrNil))))))))

(define (opt-aggregate-array-typed-load-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (opt-aggregate-test-alloc)
    (compiler-ir-instr-cons
      (IrInstrGep 2 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
      (compiler-ir-instr-cons
        (IrInstrStorePtr
          (IrValueVar 2)
          (IrValueVar 9)
          (ast-ty-array (AstTyI64) 2))
        (compiler-ir-instr-cons
          (IrInstrGep 3 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
          (compiler-ir-instr-cons
            (IrInstrLoad 4 (IrValueVar 3) (ast-ty-array (AstTyI64) 2))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueI64 0)))
              IrInstrNil)))))))

(define (opt-aggregate-branch-load-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (opt-aggregate-test-alloc)
        (compiler-ir-instr-cons
          (IrInstrGep 2 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
          (compiler-ir-instr-cons
            (IrInstrStorePtr (IrValueVar 2) (IrValueI64 10) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrBranch (IrValueBool true) "then" "else")
              IrInstrNil)))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "then"
        (compiler-ir-instr-cons
          (IrInstrGep 3 (IrValueVar 1) (IrValueI64 0) (AstTyU8))
          (compiler-ir-instr-cons
            (IrInstrLoad 4 (IrValueVar 3) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 4)))
              IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "else"
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueI64 0)))
            IrInstrNil))
        IrBlockNil))))

(define (opt-count-load-dst-instrs [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrLoad d _ _)
            (if (= d dst)
              1
              0)]
          [_ 0])
        (opt-count-load-dst-instrs (box-get rest) dst))]))

(define (opt-count-load-dst-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [dst : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-load-dst-instr-seq-from
      slots
      (+ index 1)
      count
      dst
      (+
        acc
        (match (array-ref slots index)
          [(IrInstrLoad d _ _)
            (if (= d dst)
              1
              0)]
          [_ 0])))))

(define (opt-count-load-dst-instr-seq [instrs : CompilerIrInstrSeq] [dst : i64]) : i64
  (opt-count-load-dst-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    dst
    0))

(define (opt-count-load-dst-blocks [blocks : CompilerIrBlockList] [dst : i64]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-count-load-dst-instr-seq instrs dst)
            (opt-count-load-dst-blocks (box-get rest) dst))])]
    [(IrBlockArray seq)
      (opt-count-load-dst-blocks (compiler-ir-block-seq-to-list seq) dst)]))

(define (opt-count-mov-i64-value-blocks
  [blocks : CompilerIrBlockList]
  [needle : i64]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-count-mov-i64-value-instr-seq instrs needle)
            (opt-count-mov-i64-value-blocks (box-get rest) needle))])]
    [(IrBlockArray seq)
      (opt-count-mov-i64-value-blocks
        (compiler-ir-block-seq-to-list seq)
        needle)]))

(define (opt-aggregate-sroa-test-instrs [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match (opt-aggregate-sroa-function (opt-spans-function instrs))
    [(IrFunction _ _ _ _ blocks)
      (match (compiler-ir-block-list-force-cons blocks)
        [(IrBlockCons block _)
          (match block
            [(IrBlock _ optimized) (compiler-ir-instr-seq-to-list optimized)])]
        [(IrBlockArray _) IrInstrNil]
        [(IrBlockNil) IrInstrNil])]))

(define (opt-aggregate-sroa-test-blocks [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match (opt-aggregate-sroa-function
    (IrFunction "main" IrParamNil (AstTyI64) 4 blocks))
    [(IrFunction _ _ _ _ optimized) optimized]))

(define (compiler-optimize-aggregate-sroa-self-test) : i64
  (let
    [positive : CompilerIrInstrList
      (opt-aggregate-sroa-test-instrs (opt-aggregate-positive-instrs))]
    [repeated : CompilerIrInstrList
      (opt-aggregate-sroa-test-instrs (opt-aggregate-repeated-load-instrs))]
    [overwritten : CompilerIrInstrList
      (opt-aggregate-sroa-test-instrs (opt-aggregate-overwritten-load-instrs))]
    [barrier : CompilerIrInstrList
      (opt-aggregate-sroa-test-instrs (opt-aggregate-call-separated-instrs))]
    [escaped : CompilerIrInstrList
      (opt-aggregate-sroa-test-instrs (opt-aggregate-escaped-then-load-instrs))]
    [array-typed : CompilerIrInstrList
      (opt-aggregate-sroa-test-instrs (opt-aggregate-array-typed-load-instrs))]
    [branched : CompilerIrBlockList
      (opt-aggregate-sroa-test-blocks (opt-aggregate-branch-load-blocks))]
    (core/cond
      (not (= (opt-count-load-dst-instrs positive 5) 0))
      1
      (not (= (opt-mov-dst-i64-value positive 5 -1) 10))
      2
      (not (= (opt-count-load-dst-instrs repeated 4) 0))
      3
      (not (= (opt-count-load-dst-instrs repeated 6) 0))
      4
      (not (= (opt-count-mov-i64-value repeated 10) 2))
      5
      (not (= (opt-count-load-dst-instrs overwritten 4) 0))
      6
      (not (= (opt-mov-dst-i64-value overwritten 4 -1) 20))
      7
      (not (= (opt-count-mov-i64-value overwritten 10) 0))
      8
      (not (= (opt-count-load-dst-instrs barrier 4) 1))
      9
      (not (= (opt-count-mov-i64-value barrier 10) 0))
      10
      (not (= (opt-count-load-dst-instrs escaped 4) 1))
      11
      (not (= (opt-count-mov-i64-value escaped 10) 0))
      12
      (not (= (opt-count-load-dst-instrs array-typed 4) 1))
      13
      (not (= (opt-count-load-dst-blocks branched 4) 1))
      14
      (not (= (opt-count-mov-i64-value-blocks branched 10) 0))
      15
      42)))

(define (opt-count-cast-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrCast _ _ _ _) 1]
          [_ 0])
        (opt-count-cast-instrs (box-get rest)))]))

(define (opt-count-cast-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-cast-instr-seq-from
      slots
      (+ index 1)
      count
      (+
        acc
        (match (array-ref slots index)
          [(IrInstrCast _ _ _ _) 1]
          [_ 0])))))

(define (opt-count-cast-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-cast-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

;; Builds `[Mov v0=20, Mov v1=22, BinOp v2 = v0 + v1]` (one arithmetic instr).
(define (opt-self-test-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 0 (IrValueI64 20) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrMov 1 (IrValueI64 22) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
        (IrInstrNil)))))

(define (opt-stale-load-test-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 0 (IrValueI64 41) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrLoad 0 (IrValueVar 9) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBinOp 1 (IrBinAdd) (IrValueVar 0) (IrValueI64 1) (AstTyI64))
        (IrInstrNil)))))

(define (opt-vector-mask-test-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 0 (IrValueI64 3) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrMov 1 (IrValueI64 4) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrSplat 2 (IrValueVar 0) 4 (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrLaneId 3 4 (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrTailMask 4 (IrValueVar 0) (IrValueVar 1) 4)
            (compiler-ir-instr-cons
              (IrInstrVectorBinOp
                5
                (IrBinAdd)
                (IrValueVar 2)
                (IrValueVar 3)
                4
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrSelect
                  6
                  (IrValueVar 4)
                  (IrValueVar 5)
                  (IrValueVar 2)
                  4
                  (AstTyI64))
                (compiler-ir-instr-cons
                  (IrInstrPredicatedStore
                    (IrValueVar 8)
                    (IrValueVar 0)
                    (IrValueVar 6)
                    (IrValueVar 4)
                    4
                    (AstTyI64))
                  IrInstrNil)))))))))

(define (opt-vector-cse-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrVectorBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) 4 (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrVectorBinOp
        3
        (IrBinAdd)
        (IrValueVar 0)
        (IrValueVar 1)
        4
        (AstTyI64))
      IrInstrNil)))

(define (opt-vector-reduce-cse-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrVectorReduce 1 (IrVectorReduceSum) (IrValueVar 0) 4 (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrVectorReduce 2 (IrVectorReduceSum) (IrValueVar 0) 4 (AstTyI64))
      IrInstrNil)))

(define (opt-vector-reduce-stale-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 1 (IrValueI64 10) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrVectorReduce 1 (IrVectorReduceSum) (IrValueVar 0) 4 (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 1) (IrValueI64 1) (AstTyI64))
        IrInstrNil))))

(define (opt-vector-copy-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 2 (IrValueVar 0) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrVectorBinOp
        3
        (IrBinAdd)
        (IrValueVar 2)
        (IrValueVar 1)
        4
        (AstTyI64))
      IrInstrNil)))

(define (opt-mask-copy-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 2 (IrValueVar 0) (AstTyBool))
    (compiler-ir-instr-cons
      (IrInstrMaskBinOp 3 (IrMaskAnd) (IrValueVar 2) (IrValueVar 1) 4)
      IrInstrNil)))

(define (opt-mask-reduce-copy-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 1 (IrValueVar 0) (AstTyBool))
    (compiler-ir-instr-cons
      (IrInstrMaskReduce 2 (IrMaskReduceAny) (IrValueVar 1) 4)
      IrInstrNil)))

(define (opt-count-vector-binop-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrVectorBinOp _ _ _ _ _ _) 1]
          [_ 0])
        (opt-count-vector-binop-instrs (box-get rest)))]))

(define (opt-count-vector-reduce-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrVectorReduce _ _ _ _ _) 1]
          [_ 0])
        (opt-count-vector-reduce-instrs (box-get rest)))]))

(define (opt-vector-binop-lhs-var [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(IrInstrNil) (- 0 1)]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrVectorBinOp d _ lhs _ _ _)
          (if (= d dst)
            (match lhs
              [(IrValueVar id) id]
              [_ (- 0 1)])
            (opt-vector-binop-lhs-var (box-get rest) dst))]
        [_ (opt-vector-binop-lhs-var (box-get rest) dst)])]))

(define (opt-mask-binop-lhs-var [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(IrInstrNil) (- 0 1)]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrMaskBinOp d _ lhs _ _)
          (if (= d dst)
            (match lhs
              [(IrValueVar id) id]
              [_ (- 0 1)])
            (opt-mask-binop-lhs-var (box-get rest) dst))]
        [_ (opt-mask-binop-lhs-var (box-get rest) dst)])]))

(define (opt-mask-reduce-src-var [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(IrInstrNil) (- 0 1)]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrMaskReduce d _ src _)
          (if (= d dst)
            (match src
              [(IrValueVar id) id]
              [_ (- 0 1)])
            (opt-mask-reduce-src-var (box-get rest) dst))]
        [_ (opt-mask-reduce-src-var (box-get rest) dst)])]))

(define (compiler-optimize-vector-mask-self-test) : i64
  (let
    [instrs : CompilerIrInstrList (opt-vector-mask-test-instrs)]
    [folded : CompilerIrInstrList (opt-fold-instrs (OptConstNil) instrs)]
    [dce : CompilerIrInstrList
      (opt-dce-instrs
        (opt-collect-instrs-uses (i64-i64-map-with-capacity 64) instrs)
        instrs)]
    [bounds : CompilerIrInstrList (opt-bounds-instrs (OptBoundsNil) instrs)]
    [vector-cse : CompilerIrInstrList
      (opt-cse-instrs (OptExprNil) (opt-vector-cse-instrs))]
    [vector-reduce-cse : CompilerIrInstrList
      (opt-cse-instrs (OptExprNil) (opt-vector-reduce-cse-instrs))]
    [vector-stale : CompilerIrInstrList
      (opt-fold-instrs (OptConstNil) (opt-vector-reduce-stale-instrs))]
    [vector-copy : CompilerIrInstrList
      (opt-copy-instrs (OptCopyNil) (opt-vector-copy-instrs))]
    [mask-copy : CompilerIrInstrList
      (opt-copy-instrs (OptCopyNil) (opt-mask-copy-instrs))]
    [mask-reduce-copy : CompilerIrInstrList
      (opt-copy-instrs (OptCopyNil) (opt-mask-reduce-copy-instrs))]
    (core/cond
      (not (opt-instr-list-eq folded instrs))
      1
      (not (= (compiler-ir-instr-list-count dce) 8))
      2
      (not (= (compiler-ir-instr-list-count bounds) 8))
      3
      (not (= (opt-count-vector-binop-instrs vector-cse) 2))
      4
      (not (= (opt-mov-dst-type-tag vector-cse 3) 0))
      5
      (not (= (opt-count-vector-reduce-instrs vector-reduce-cse) 2))
      6
      (not (= (opt-mov-dst-type-tag vector-reduce-cse 2) 0))
      7
      (not (= (opt-count-arith-instrs vector-stale) 1))
      8
      (not (= (opt-count-mov-i64-value vector-stale 11) 0))
      9
      (not (= (opt-vector-binop-lhs-var vector-copy 3) 2))
      10
      (not (= (opt-mask-binop-lhs-var mask-copy 3) 2))
      11
      (not (= (opt-mask-reduce-src-var mask-reduce-copy 2) 1))
      12
      42)))

;; Returns 42 when folding turns the one arithmetic instruction into a `Mov`
;; literal whose value (20 + 22) is correct, and a later `Load` redefining a
;; formerly-constant var invalidates the stale fact before another arithmetic
;; instruction reads that var.
(define (compiler-optimize-self-test) : i64
  (let
    [instrs : CompilerIrInstrList (opt-self-test-instrs)]
    [optimized : CompilerIrInstrList (opt-fold-instrs (OptConstNil) instrs)]
    (begin
      (unless (= (opt-count-arith-instrs instrs) 1) (return 1))
      (unless (= (opt-count-arith-instrs optimized) 0) (return 2))
      (unless (= (opt-sum-mov-i64 optimized) 84) (return 3))
      (let
        [stale-instrs : CompilerIrInstrList (opt-stale-load-test-instrs)]
        [stale-optimized : CompilerIrInstrList
          (opt-fold-instrs (OptConstNil) stale-instrs)]
        (begin
          (unless (= (opt-count-arith-instrs stale-optimized) 1) (return 4))
          (unless (= (compiler-optimize-vector-mask-self-test) 42) (return 5))
          42)))))

(define (opt-typed-fold-u64-shr-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 20 (IrValueI64 (- 0 1)) (AstTyU64))
    (compiler-ir-instr-cons
      (IrInstrMov 21 (IrValueI64 63) (AstTyU8))
      (compiler-ir-instr-cons
        (IrInstrBinOp 22 (IrBinShr) (IrValueVar 20) (IrValueVar 21) (AstTyU64))
        (IrInstrNil)))))

(define (opt-typed-fold-shift-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 15 (IrValueI64 1) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrMov 16 (IrValueI64 3) (AstTyU8))
      (compiler-ir-instr-cons
        (IrInstrBinOp 17 (IrBinShl) (IrValueVar 15) (IrValueVar 16) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrMov 18 (IrValueI64 (- 0 8)) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBinOp
              19
              (IrBinShr)
              (IrValueVar 18)
              (IrValueI64 1)
              (AstTyI64))
            (opt-typed-fold-u64-shr-instrs)))))))

(define (opt-typed-fold-div-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrBinOp 13 (IrBinDiv) (IrValueI64 42) (IrValueI64 6) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrBinOp 14 (IrBinMod) (IrValueI64 22) (IrValueI64 7) (AstTyU8))
      (opt-typed-fold-shift-instrs))))

(define (opt-typed-fold-bool-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 11 (IrValueBool true) (AstTyBool))
    (compiler-ir-instr-cons
      (IrInstrBinOp
        12
        (IrBinAnd)
        (IrValueVar 11)
        (IrValueBool false)
        (AstTyBool))
      (opt-typed-fold-div-instrs))))

(define (opt-typed-fold-cast-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrCast 7 (IrValueVar 0) (AstTyU8) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrCast 8 (IrValueI64 300) (AstTyU16) (AstTyChar))
      (compiler-ir-instr-cons
        (IrInstrMov 9 (IrValueChar #A') (AstTyChar))
        (compiler-ir-instr-cons
          (IrInstrCast 10 (IrValueVar 9) (AstTyChar) (AstTyI64))
          (opt-typed-fold-bool-instrs))))))

(define (opt-typed-fold-compare-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 3 (IrValueI64 (- 0 1)) (AstTyI8))
    (compiler-ir-instr-cons
      (IrInstrMov 4 (IrValueI64 1) (AstTyI8))
      (compiler-ir-instr-cons
        (IrInstrBinOp 5 (IrBinLt) (IrValueVar 3) (IrValueVar 4) (AstTyBool))
        (compiler-ir-instr-cons
          (IrInstrBinOp 6 (IrBinLt) (IrValueVar 0) (IrValueVar 1) (AstTyBool))
          (opt-typed-fold-cast-instrs))))))

(define (opt-typed-fold-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 0 (IrValueI64 255) (AstTyU8))
    (compiler-ir-instr-cons
      (IrInstrMov 1 (IrValueI64 1) (AstTyU8))
      (compiler-ir-instr-cons
        (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyU8))
        (opt-typed-fold-compare-instrs)))))

(define (opt-typed-fold-invalid-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrBinOp 30 (IrBinDiv) (IrValueI64 1) (IrValueI64 0) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrBinOp
        31
        (IrBinDiv)
        (IrValueI64 (- 0 128))
        (IrValueI64 (- 0 1))
        (AstTyI8))
      (compiler-ir-instr-cons
        (IrInstrBinOp
          32
          (IrBinShl)
          (IrValueI64 1)
          (IrValueI64 (- 0 1))
          (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrBinOp 33 (IrBinShl) (IrValueI64 1) (IrValueI64 8) (AstTyU8))
          (IrInstrNil))))))

(define (compiler-optimize-typed-fold-self-test) : i64
  (let
    [pos : CompilerIrInstrList
      (opt-fold-instrs (OptConstNil) (opt-typed-fold-instrs))]
    [neg : CompilerIrInstrList
      (opt-fold-instrs (OptConstNil) (opt-typed-fold-invalid-instrs))]
    (begin
      (unless (= (opt-count-arith-instrs pos) 0) (return 1))
      (unless (= (opt-count-cast-instrs pos) 0) (return 3))
      (unless (= (opt-mov-dst-i64-value pos 2 (- 0 999)) 0) (return 4))
      (unless (opt-mov-dst-bool-value? pos 5 true) (return 5))
      (unless (opt-mov-dst-bool-value? pos 6 false) (return 6))
      (unless (= (opt-mov-dst-i64-value pos 7 0) 255) (return 7))
      (unless (= (opt-mov-dst-char-code pos 8 0) 44) (return 8))
      (unless (= (opt-mov-dst-i64-value pos 10 0) 65) (return 9))
      (unless (opt-mov-dst-bool-value? pos 12 false) (return 10))
      (unless (= (opt-mov-dst-i64-value pos 13 0) 7) (return 11))
      (unless (= (opt-mov-dst-i64-value pos 14 0) 1) (return 12))
      (unless (= (opt-mov-dst-i64-value pos 17 0) 8) (return 13))
      (unless (= (opt-mov-dst-i64-value pos 19 0) (- 0 4)) (return 14))
      (unless (= (opt-mov-dst-i64-value pos 22 0) 1) (return 15))
      (unless (= (opt-count-arith-instrs neg) 4) (return 16))
      42)))

;; Positive strength-reduction cases: integer neutral/absorbing identities and
;; boolean `and`/`or` identities. The first instruction uses `AstTyU8` to prove
;; non-i64 integer result types keep their original type.
(define (opt-strength-self-test-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrBinOp 10 (IrBinAdd) (IrValueVar 1) (IrValueI64 0) (AstTyU8))
    (compiler-ir-instr-cons
      (IrInstrBinOp 11 (IrBinAdd) (IrValueI64 0) (IrValueVar 2) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBinOp 12 (IrBinSub) (IrValueVar 3) (IrValueI64 0) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrBinOp 13 (IrBinMul) (IrValueVar 4) (IrValueI64 1) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBinOp
              14
              (IrBinMul)
              (IrValueI64 1)
              (IrValueVar 5)
              (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrBinOp
                15
                (IrBinMul)
                (IrValueVar 6)
                (IrValueI64 0)
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrBinOp
                  16
                  (IrBinMul)
                  (IrValueI64 0)
                  (IrValueVar 7)
                  (AstTyI64))
                (compiler-ir-instr-cons
                  (IrInstrBinOp
                    17
                    (IrBinAnd)
                    (IrValueVar 8)
                    (IrValueBool true)
                    (AstTyBool))
                  (compiler-ir-instr-cons
                    (IrInstrBinOp
                      18
                      (IrBinAnd)
                      (IrValueBool true)
                      (IrValueVar 9)
                      (AstTyBool))
                    (compiler-ir-instr-cons
                      (IrInstrBinOp
                        19
                        (IrBinAnd)
                        (IrValueVar 8)
                        (IrValueBool false)
                        (AstTyBool))
                      (compiler-ir-instr-cons
                        (IrInstrBinOp
                          20
                          (IrBinAnd)
                          (IrValueBool false)
                          (IrValueVar 9)
                          (AstTyBool))
                        (compiler-ir-instr-cons
                          (IrInstrBinOp
                            21
                            (IrBinOr)
                            (IrValueVar 8)
                            (IrValueBool false)
                            (AstTyBool))
                          (compiler-ir-instr-cons
                            (IrInstrBinOp
                              22
                              (IrBinOr)
                              (IrValueBool false)
                              (IrValueVar 9)
                              (AstTyBool))
                            (compiler-ir-instr-cons
                              (IrInstrBinOp
                                23
                                (IrBinOr)
                                (IrValueVar 8)
                                (IrValueBool true)
                                (AstTyBool))
                              (compiler-ir-instr-cons
                                (IrInstrBinOp
                                  24
                                  (IrBinOr)
                                  (IrValueBool true)
                                  (IrValueVar 9)
                                  (AstTyBool))
                                (IrInstrNil)))))))))))))))))

;; Negative cases for edge-sensitive operations and non-identities: division,
;; modulo, shifts, and `0 - x` must stay as `BinOp`s.
(define (opt-strength-negative-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrBinOp 30 (IrBinDiv) (IrValueVar 1) (IrValueI64 0) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrBinOp 31 (IrBinMod) (IrValueVar 1) (IrValueI64 0) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBinOp 32 (IrBinShl) (IrValueVar 1) (IrValueI64 0) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrBinOp 33 (IrBinShr) (IrValueVar 1) (IrValueI64 0) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBinOp
              34
              (IrBinSub)
              (IrValueI64 0)
              (IrValueVar 1)
              (AstTyI64))
            (IrInstrNil)))))))

;; Returns 42 when every positive identity is rewritten to `Mov`, the typed U8
;; identity keeps its result type, and the negative cases stay untouched.
(define (compiler-optimize-strength-self-test) : i64
  (let
    [pos : CompilerIrInstrList
      (opt-strength-instrs (OptConstNil) (opt-strength-self-test-instrs))]
    [neg : CompilerIrInstrList
      (opt-strength-instrs (OptConstNil) (opt-strength-negative-instrs))]
    (core/cond
      (not (= (opt-count-arith-instrs pos) 0))
      1
      (not (= (opt-sum-mov-var-src pos) 49))
      2
      (not (= (opt-count-mov-i64-value pos 0) 2))
      3
      (not (= (opt-count-mov-bool-value pos false) 2))
      4
      (not (= (opt-count-mov-bool-value pos true) 2))
      5
      (not (= (opt-mov-dst-type-tag pos 10) (ast-type-tag (AstTyU8))))
      6
      (not (= (opt-count-arith-instrs neg) 5))
      7
      42)))

;; Builds `[Mov v0=99 (unused), Call v1 = noop(), Return v1]`. `v0` is a dead
;; pure temporary; `v1` is produced by a side-effecting call and used by the
;; return, so DCE must drop only `v0`'s Mov (3 instrs -> 2).
(define (opt-dce-self-test-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 0 (IrValueI64 99) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrCall 1 "noop" (IrCallArgsNil) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrReturn (IrSomeValue (IrValueVar 1)))
        (IrInstrNil)))))

;; Returns 42 when DCE keeps the used call result `v1` and the side-effecting
;; instructions, drops the unused `v0`, and is idempotent on a second pass.
(define (compiler-optimize-dce-self-test) : i64
  (let
    [instrs : CompilerIrInstrList (opt-dce-self-test-instrs)]
    [used : I64I64Map
      (opt-collect-instrs-uses (i64-i64-map-with-capacity 64) instrs)]
    [cleaned : CompilerIrInstrList (opt-dce-instrs used instrs)]
    [again : CompilerIrInstrList
      (opt-dce-instrs
        (opt-collect-instrs-uses (i64-i64-map-with-capacity 64) cleaned)
        cleaned)]
    (core/cond
      (not (opt-used-contains used 1))
      0
      (opt-used-contains used 0)
      1
      (not (= (compiler-ir-instr-list-count instrs) 3))
      2
      (not (= (compiler-ir-instr-list-count cleaned) 2))
      3
      (not (= (compiler-ir-instr-list-count again) 2))
      4
      42)))

;; Builds `[Mov v0=4096 (an address), Load v1 = *v0, Return v1]`. `v0` feeds a
;; `Load`, so DCE must treat it as used and keep it; without collecting the
;; Load's operand uses, DCE would wrongly drop `v0`'s Mov and break the load.
(define (opt-dce-mem-self-test-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 0 (IrValueI64 4096) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrLoad 1 (IrValueVar 0) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrReturn (IrSomeValue (IrValueVar 1)))
        (IrInstrNil)))))

;; Returns 42 when DCE keeps the `Mov` that feeds the `Load` (operand uses of
;; pointer/memory ops are collected), leaving all three instructions intact.
(define (compiler-optimize-dce-mem-self-test) : i64
  (let
    [instrs : CompilerIrInstrList (opt-dce-mem-self-test-instrs)]
    [used : I64I64Map
      (opt-collect-instrs-uses (i64-i64-map-with-capacity 64) instrs)]
    [cleaned : CompilerIrInstrList (opt-dce-instrs used instrs)]
    (if (opt-used-contains used 0)
      (if (= (compiler-ir-instr-list-count cleaned) 3)
        42
        2)
      1)))

;; `[BinOp v2 = v0 + v1, BinOp v3 = v0 + v1]` with non-constant operands: CSE
;; rewrites the second into `Mov v3 = v2` (two arithmetic instrs -> one).
(define (opt-cse-self-test-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrBinOp 3 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
      (IrInstrNil))))

;; A store between the two identical expressions clears the table, so the second
;; expression is preserved (no cross-store CSE).
(define (opt-cse-store-clears-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrStore "g" (IrValueI64 0) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBinOp 3 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
        (IrInstrNil)))))

;; Redefining an operand (`v0`) between the two expressions invalidates the
;; available entry, so the second expression is preserved (correctness on
;; non-SSA IR).
(define (opt-cse-operand-redef-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrMov 0 (IrValueI64 5) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBinOp 3 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
        (IrInstrNil)))))

;; Returns 42 when CSE eliminates the repeated pure expression (2 arithmetic
;; instrs -> 1) yet preserves the second expression both across an intervening
;; store and across an operand redefinition (still 2 arithmetic instrs each).
(define (compiler-optimize-cse-self-test) : i64
  (let
    [cse : CompilerIrInstrList
      (opt-cse-instrs (OptExprNil) (opt-cse-self-test-instrs))]
    [store : CompilerIrInstrList
      (opt-cse-instrs (OptExprNil) (opt-cse-store-clears-instrs))]
    [redef : CompilerIrInstrList
      (opt-cse-instrs (OptExprNil) (opt-cse-operand-redef-instrs))]
    (begin
      (unless (= (opt-count-arith-instrs cse) 1) (return 1))
      (unless (= (opt-count-arith-instrs store) 2) (return 2))
      (unless (= (opt-count-arith-instrs redef) 2) (return 3))
      42)))

;; --- cross-block GVN self-tests (#1349) -------------------------------------
(define (opt-gvn-test-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (IrParam "a" (AstTyI64) 0)
    (compiler-ir-param-cons (IrParam "b" (AstTyI64) 1) (IrParamNil))))

(define (opt-gvn-count-binops-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-count-arith-instr-seq instrs)
            (opt-gvn-count-binops-blocks (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-gvn-count-binops-blocks (compiler-ir-block-seq-to-list seq))]))

;; Diamond: `a + b` computed in the entry block and recomputed in the
;; post-dominating join. The entry strictly dominates the join, so the join's
;; expression is rewritten to a copy and the binop count drops from 2 to 1.
(define (opt-gvn-diamond-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBinOp 10 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrBranch (IrValueVar 0) "l" "r")
          (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "l"
        (compiler-ir-instr-cons (IrInstrJump "j") (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "r"
          (compiler-ir-instr-cons (IrInstrJump "j") (IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "j"
            (compiler-ir-instr-cons
              (IrInstrBinOp
                11
                (IrBinAdd)
                (IrValueVar 0)
                (IrValueVar 1)
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 11)))
                (IrInstrNil))))
          (IrBlockNil))))))

;; Two sibling arms each compute `a + b`, and the join recomputes it. Neither arm
;; strictly dominates the join, so no cross-block CSE fires and all 3 binops stay.
(define (opt-gvn-siblings-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBranch (IrValueVar 0) "l" "r")
        (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "l"
        (compiler-ir-instr-cons
          (IrInstrBinOp 10 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
          (compiler-ir-instr-cons (IrInstrJump "j") (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "r"
          (compiler-ir-instr-cons
            (IrInstrBinOp
              11
              (IrBinAdd)
              (IrValueVar 0)
              (IrValueVar 1)
              (AstTyI64))
            (compiler-ir-instr-cons (IrInstrJump "j") (IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "j"
            (compiler-ir-instr-cons
              (IrInstrBinOp
                12
                (IrBinAdd)
                (IrValueVar 0)
                (IrValueVar 1)
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 12)))
                (IrInstrNil))))
          (IrBlockNil))))))

;; The shared operand `v2` is reassigned in each block, so it has two value
;; sources and is not stable. Even though the entry dominates the join, the two
;; `v0 + v2` expressions compute different values and must not be CSE'd: 2 binops.
(define (opt-gvn-redef-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrMov 2 (IrValueI64 5) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrBinOp 10 (IrBinAdd) (IrValueVar 0) (IrValueVar 2) (AstTyI64))
          (compiler-ir-instr-cons (IrInstrJump "j") (IrInstrNil)))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "j"
        (compiler-ir-instr-cons
          (IrInstrMov 2 (IrValueI64 7) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBinOp
              11
              (IrBinAdd)
              (IrValueVar 0)
              (IrValueVar 2)
              (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 11)))
              (IrInstrNil)))))
      (IrBlockNil))))

;; Loop: the header computes `a + b` and the body recomputes it. The header
;; strictly dominates the body, so the body's expression is rewritten: 2 -> 1.
(define (opt-gvn-loop-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons (IrInstrJump "h") (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "h"
        (compiler-ir-instr-cons
          (IrInstrBinOp 10 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBranch (IrValueVar 0) "body" "exit")
            (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "body"
          (compiler-ir-instr-cons
            (IrInstrBinOp
              11
              (IrBinAdd)
              (IrValueVar 0)
              (IrValueVar 1)
              (AstTyI64))
            (compiler-ir-instr-cons (IrInstrJump "h") (IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "exit"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 10)))
              (IrInstrNil)))
          (IrBlockNil))))))

;; Returns 42 only when cross-block GVN rewrites dominated repeats (diamond and
;; loop drop to 1 binop), leaves non-dominating siblings alone (3 binops), and
;; refuses to CSE across a reassigned operand (2 binops).
(define (compiler-optimize-gvn-self-test) : i64
  (begin
    (unless
      (=
        (opt-gvn-count-binops-blocks
          (opt-gvn-blocks (opt-gvn-test-params) (opt-gvn-diamond-blocks)))
        1)
      (return 1))
    (unless
      (=
        (opt-gvn-count-binops-blocks
          (opt-gvn-blocks (opt-gvn-test-params) (opt-gvn-siblings-blocks)))
        3)
      (return 2))
    (unless
      (=
        (opt-gvn-count-binops-blocks
          (opt-gvn-blocks (opt-gvn-test-params) (opt-gvn-redef-blocks)))
        2)
      (return 3))
    (unless
      (=
        (opt-gvn-count-binops-blocks
          (opt-gvn-blocks (opt-gvn-test-params) (opt-gvn-loop-blocks)))
        1)
      (return 4))
    42))

;; Returns the lhs var id of the `BinOp` whose destination is `dst`, or -1 if it
;; is absent or its lhs is not a var. Used to inspect copy-propagation rewrites.
(define (opt-copy-binop-lhs-var [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(IrInstrNil) (- 0 1)]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrBinOp d _ l _ _)
          (if (= d dst)
            (match l
              [(IrValueVar id) id]
              [_ (- 0 1)])
            (opt-copy-binop-lhs-var (box-get rest) dst))]
        [_ (opt-copy-binop-lhs-var (box-get rest) dst)])]))

(define (opt-copy-binop-lhs-var-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [dst : i64]) : i64
  (if (>= index count)
    (- 0 1)
    (match (array-ref slots index)
      [(IrInstrBinOp d _ l _ _)
        (if (= d dst)
          (match l
            [(IrValueVar id) id]
            [_ (- 0 1)])
          (opt-copy-binop-lhs-var-instr-seq-from slots (+ index 1) count dst))]
      [_ (opt-copy-binop-lhs-var-instr-seq-from slots (+ index 1) count dst)])))

(define (opt-copy-binop-lhs-var-instr-seq
  [instrs : CompilerIrInstrSeq]
  [dst : i64]) : i64
  (opt-copy-binop-lhs-var-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    dst))

;; `[Mov v1 = v0, BinOp v2 = v1 + 1]`: copy propagation rewrites the binop lhs
;; from v1 to v0.
(define (opt-copy-pos-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 1 (IrValueVar 0) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 1) (IrValueI64 1) (AstTyI64))
      (IrInstrNil))))

;; `[Mov v1 = v0, Load v0 = *v9, BinOp v2 = v1 + 1]`: redefining the copy source
;; v0 invalidates the v1 -> v0 fact, so the binop lhs stays v1.
(define (opt-copy-src-redef-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 1 (IrValueVar 0) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrLoad 0 (IrValueVar 9) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 1) (IrValueI64 1) (AstTyI64))
        (IrInstrNil)))))

;; `[Mov v1 = v0, Load v1 = *v9, BinOp v2 = v1 + 1]`: redefining the copy
;; destination v1 invalidates the fact, so the binop lhs stays v1.
(define (opt-copy-dst-redef-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 1 (IrValueVar 0) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrLoad 1 (IrValueVar 9) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 1) (IrValueI64 1) (AstTyI64))
        (IrInstrNil)))))

;; `[BinOp v2 = v0 + v1, BinOp v3 = v0 + v1, BinOp v4 = v3 + 1, Return v4]`: CSE
;; rewrites the second expression to `Mov v3 = v2`; copy propagation then rewrites
;; the v4 lhs from v3 to v2, leaving the `Mov v3` copy dead for DCE to drop (the
;; `Return v4` keeps v4 live so only the copy is removed: 4 instrs -> 3).
(define (opt-copy-cse-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrBinOp 3 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBinOp 4 (IrBinAdd) (IrValueVar 3) (IrValueI64 1) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrReturn (IrSomeValue (IrValueVar 4)))
          (IrInstrNil))))))

;; `[Mov v1 = 1.5f64, BinOp v2 = v1 + v1]`: an F64 source is not recorded as a
;; copy in this slice, so the binop lhs stays v1 (no unsafe literal propagation).
(define (opt-copy-f64-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 1 (IrValueF64 "1.5") (AstTyF64))
    (compiler-ir-instr-cons
      (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 1) (IrValueVar 1) (AstTyF64))
      (IrInstrNil))))

(define (opt-copy-phi-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 1 (IrValueVar 0) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrPhi
        2
        (compiler-ir-phi-input-cons (IrValueVar 1) "left" IrPhiInputNil)
        (AstTyI64))
      (IrInstrNil))))

(define (opt-phi-first-input-var
  [inputs : CompilerIrPhiInputList]
  [fallback : i64]) : i64
  (match inputs
    [(IrPhiInputNil) fallback]
    [(IrPhiInputCons value _ _)
      (match value
        [(IrValueVar id) id]
        [_ fallback])]))

(define (opt-phi-dst-first-input-var
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [fallback : i64]) : i64
  (match instrs
    [(IrInstrNil) fallback]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrPhi found inputs _)
          (if (= found dst)
            (opt-phi-first-input-var inputs fallback)
            (opt-phi-dst-first-input-var (box-get rest) dst fallback))]
        [_ (opt-phi-dst-first-input-var (box-get rest) dst fallback)])]))

;; Returns 42 when block-local copy propagation: rewrites a var copy into a later
;; use (pos: lhs v1 -> v0); does not propagate after the source (src-redef) or
;; destination (dst-redef) var is redefined; rewrites a CSE-introduced copy so
;; DCE can drop it (cse: lhs v3 -> v2, leaving 3 instrs); does not propagate an
;; unsafe F64 source (f64: lhs stays v1); and leaves phi inputs untouched because
;; they are edge operands rather than block-local value uses (#1043).
(define (compiler-optimize-copy-self-test) : i64
  (let
    [pos : CompilerIrInstrList
      (opt-copy-instrs (OptCopyNil) (opt-copy-pos-instrs))]
    [src-redef : CompilerIrInstrList
      (opt-copy-instrs (OptCopyNil) (opt-copy-src-redef-instrs))]
    [dst-redef : CompilerIrInstrList
      (opt-copy-instrs (OptCopyNil) (opt-copy-dst-redef-instrs))]
    [cse : CompilerIrInstrList
      (opt-copy-instrs
        (OptCopyNil)
        (opt-cse-instrs (OptExprNil) (opt-copy-cse-instrs)))]
    [cse-dce : CompilerIrInstrList
      (opt-dce-instrs
        (opt-collect-instrs-uses (i64-i64-map-with-capacity 64) cse)
        cse)]
    [f64 : CompilerIrInstrList
      (opt-copy-instrs (OptCopyNil) (opt-copy-f64-instrs))]
    [phi : CompilerIrInstrList
      (opt-copy-instrs (OptCopyNil) (opt-copy-phi-instrs))]
    (core/cond
      (not (= (opt-copy-binop-lhs-var pos 2) 0))
      1
      (not (= (opt-copy-binop-lhs-var src-redef 2) 1))
      2
      (not (= (opt-copy-binop-lhs-var dst-redef 2) 1))
      3
      (not (= (opt-copy-binop-lhs-var cse 4) 2))
      4
      (not (= (compiler-ir-instr-list-count cse-dce) 3))
      5
      (not (= (opt-copy-binop-lhs-var f64 2) 1))
      6
      (not (= (opt-phi-dst-first-input-var phi 2 (- 0 1)) 1))
      7
      42)))

;; Count explicit trapping bounds checks after the dedicated bounds pass.
(define (opt-count-bounds-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrBoundsCheck _ _ _) 1]
          [_ 0])
        (opt-count-bounds-instrs (box-get rest)))]))

(define (opt-count-bounds-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-bounds-instr-seq-from
      slots
      (+ index 1)
      count
      (+
        acc
        (match (array-ref slots index)
          [(IrInstrBoundsCheck _ _ _) 1]
          [_ 0])))))

(define (opt-count-bounds-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-bounds-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-bounds-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-count-bounds-instr-seq instrs)
            (opt-count-bounds-blocks (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-count-bounds-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-bounds-duplicate-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.0")
    (compiler-ir-instr-cons
      (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.1")
      (IrInstrNil))))

(define (opt-bounds-different-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.0")
    (compiler-ir-instr-cons
      (IrInstrBoundsCheck (IrValueVar 1) (IrValueVar 0) "bounds_ok.1")
      (IrInstrNil))))

(define (opt-bounds-redef-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.0")
    (compiler-ir-instr-cons
      (IrInstrMov 0 (IrValueI64 7) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.1")
        (IrInstrNil)))))

(define (opt-bounds-call-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.0")
    (compiler-ir-instr-cons
      (IrInstrCall 9 "touch" (IrCallArgsNil) (AstTyUnit))
      (compiler-ir-instr-cons
        (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.1")
        (IrInstrNil)))))

(define (opt-bounds-branch-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.0")
    (compiler-ir-instr-cons
      (IrInstrBranch (IrValueBool true) "ok" "fail")
      (compiler-ir-instr-cons
        (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.1")
        (IrInstrNil)))))

(define (opt-bounds-copy-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 2 (IrValueVar 0) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrBoundsCheck (IrValueVar 2) (IrValueVar 1) "bounds_ok.0")
      (compiler-ir-instr-cons
        (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.1")
        (IrInstrNil)))))

(define (opt-bounds-dce-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 0 (IrValueI64 1) (AstTyU64))
    (compiler-ir-instr-cons
      (IrInstrMov 1 (IrValueI64 2) (AstTyU64))
      (compiler-ir-instr-cons
        (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.0")
        (IrInstrNil)))))

(define (opt-bounds-cross-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.0")
        (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "next"
        (compiler-ir-instr-cons
          (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.1")
          (IrInstrNil)))
      (IrBlockNil))))

(define (compiler-optimize-bounds-self-test) : i64
  (let
    [duplicate : CompilerIrInstrList
      (opt-bounds-instrs (OptBoundsNil) (opt-bounds-duplicate-instrs))]
    [different : CompilerIrInstrList
      (opt-bounds-instrs (OptBoundsNil) (opt-bounds-different-instrs))]
    [redef : CompilerIrInstrList
      (opt-bounds-instrs (OptBoundsNil) (opt-bounds-redef-instrs))]
    [call : CompilerIrInstrList
      (opt-bounds-instrs (OptBoundsNil) (opt-bounds-call-instrs))]
    [branch : CompilerIrInstrList
      (opt-bounds-instrs (OptBoundsNil) (opt-bounds-branch-instrs))]
    [copy : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsNil)
        (opt-copy-instrs (OptCopyNil) (opt-bounds-copy-instrs)))]
    [dce : CompilerIrInstrList
      (opt-dce-instrs
        (opt-collect-instrs-uses
          (i64-i64-map-with-capacity 64)
          (opt-bounds-dce-instrs))
        (opt-bounds-dce-instrs))]
    [cross : CompilerIrBlockList
      (optimize-block-list (opt-bounds-cross-blocks))]
    (core/cond
      (not (= (opt-count-bounds-instrs duplicate) 1))
      1
      (not (= (opt-count-bounds-instrs different) 2))
      2
      (not (= (opt-count-bounds-instrs redef) 2))
      3
      (not (= (opt-count-bounds-instrs call) 2))
      4
      (not (= (opt-count-bounds-instrs branch) 2))
      5
      (not (= (opt-count-bounds-instrs copy) 1))
      6
      (not (= (compiler-ir-instr-list-count dce) 3))
      7
      (not (= (opt-count-bounds-blocks cross) 2))
      8
      42)))

;; Copy propagation can expose a repeated expression only after CSE has already
;; run for that iteration. A second pass then CSEs `v3` to `v2`; copy propagation
;; rewrites `v4`, and DCE drops the now-unused copy.
(define (opt-fixed-point-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 1 (IrValueVar 0) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueI64 1) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBinOp 3 (IrBinAdd) (IrValueVar 1) (IrValueI64 1) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrBinOp 4 (IrBinAdd) (IrValueVar 2) (IrValueVar 3) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 4)))
            (IrInstrNil)))))))

(define (opt-test-function-named [name : String] [instrs : CompilerIrInstrList]) : CompilerIrFunction
  (IrFunction
    name
    (IrParamNil)
    (AstTyI64)
    5
    (compiler-ir-block-cons (compiler-ir-block "entry" instrs) (IrBlockNil))))

(define (opt-test-function [instrs : CompilerIrInstrList]) : CompilerIrFunction
  (opt-test-function-named "fixed" instrs))

(define (opt-test-program [instrs : CompilerIrInstrList]) : CompilerIrProgram
  (IrProgram
    (IrGlobalNil)
    (compiler-ir-function-cons (opt-test-function instrs) (IrFunctionNil))
    (IrExternNil)))

(define (opt-function-first-instrs [func : CompilerIrFunction]) : CompilerIrInstrList
  (match func
    [(IrFunction _ _ _ _ blocks)
      (match (compiler-ir-block-list-force-cons blocks)
        [(IrBlockCons block _)
          (match block
            [(IrBlock _ instrs) (compiler-ir-instr-seq-to-list instrs)])]
        [(IrBlockArray _) (IrInstrNil)]
        [(IrBlockNil) (IrInstrNil)])]))

(define (opt-program-first-instrs [program : CompilerIrProgram]) : CompilerIrInstrList
  (match program
    [(IrProgram _ funcs _)
      (match funcs
        [(IrFunctionCons func _) (opt-function-first-instrs func)]
        [(IrFunctionNil) (IrInstrNil)])]))

(define (opt-program-functions [program : CompilerIrProgram]) : CompilerIrFunctionList
  (match program
    [(IrProgram _ funcs _) funcs]))

(define (opt-level-parse-ok? [value : String] [expected : i64]) : bool
  (match (compiler-optimize-parse-level value)
    [(OkCompilerOptimizeLevel level) (= level expected)]
    [(ErrCompilerOptimizeLevel) false]))

(define (opt-level-parse-err? [value : String]) : bool
  (match (compiler-optimize-parse-level value)
    [(OkCompilerOptimizeLevel _) false]
    [(ErrCompilerOptimizeLevel) true]))

(define (compiler-optimize-level-policy-ok?) : bool
  (and
    (= (compiler-optimize-default-level) 1)
    (and
      (compiler-optimize-level-valid? 0)
      (and
        (compiler-optimize-level-valid? 1)
        (and
          (compiler-optimize-level-valid? 2)
          (and
            (not (compiler-optimize-level-valid? 3))
            (and
              (not (compiler-optimize-level-valid? (- 0 1)))
              (and
                (not (compiler-optimize-level-valid? 4))
                (and
                  (opt-level-parse-ok? "0" 0)
                  (and
                    (opt-level-parse-ok? "1" 1)
                    (and
                      (opt-level-parse-ok? "2" 2)
                      (and
                        (opt-level-parse-err? "3")
                        (and
                          (opt-level-parse-err? "")
                          (and
                            (opt-level-parse-err? "4")
                            (opt-level-parse-err? "10")))))))))))))))

(define (compiler-optimize-level-program-ok?) : bool
  (let
    [program : CompilerIrProgram (opt-test-program (opt-self-test-instrs))]
    [level0 : CompilerIrProgram (optimize-program-with-level program 0)]
    [level1 : CompilerIrProgram (optimize-program-with-level program 1)]
    [level2 : CompilerIrProgram (optimize-program-with-level program 2)]
    [defaulted : CompilerIrProgram (optimize-program program)]
    [fixed-program : CompilerIrProgram
      (opt-test-program (opt-fixed-point-instrs))]
    [level1-fixed : CompilerIrProgram
      (optimize-program-with-level fixed-program 1)]
    [level2-fixed : CompilerIrProgram
      (optimize-program-with-level fixed-program 2)]
    [level0-instrs : CompilerIrInstrList (opt-program-first-instrs level0)]
    [level1-instrs : CompilerIrInstrList (opt-program-first-instrs level1)]
    [level2-instrs : CompilerIrInstrList (opt-program-first-instrs level2)]
    [level1-fixed-instrs : CompilerIrInstrList
      (opt-program-first-instrs level1-fixed)]
    [level2-fixed-instrs : CompilerIrInstrList
      (opt-program-first-instrs level2-fixed)]
    (core/cond
      (not (opt-program-eq program level0))
      false
      (not (= (opt-count-arith-instrs level0-instrs) 1))
      false
      (not (= (compiler-ir-instr-list-count level1-instrs) 0))
      false
      (not (= (compiler-ir-instr-list-count level2-instrs) 0))
      false
      (not (opt-program-eq level1 defaulted))
      false
      (not (= (compiler-ir-instr-list-count level1-fixed-instrs) 4))
      false
      (not (= (opt-count-arith-instrs level1-fixed-instrs) 3))
      false
      (not (= (compiler-ir-instr-list-count level2-fixed-instrs) 3))
      false
      (not (= (opt-count-arith-instrs level2-fixed-instrs) 2))
      false
      true)))

(define (compiler-optimize-level-self-test) : i64
  (if (compiler-optimize-level-policy-ok?)
    (if (compiler-optimize-level-program-ok?)
      42
      2)
    1))

(define (opt-global-dce-main-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrCall 1 "helper" (IrCallArgsNil) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrReturn (IrSomeValue (IrValueVar 1)))
      (IrInstrNil))))

(define (opt-global-dce-return-instrs [value : i64]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrReturn (IrSomeValue (IrValueI64 value)))
    (IrInstrNil)))

(define (opt-global-dce-program) : CompilerIrProgram
  (IrProgram
    (compiler-ir-global-cons
      (IrGlobal "callback" (AstTyI64) (IrValueGlobal "callback-target"))
      (IrGlobalNil))
    (compiler-ir-function-cons
      (opt-test-function-named "main" (opt-global-dce-main-instrs))
      (compiler-ir-function-cons
        (opt-test-function-named "helper" (opt-global-dce-return-instrs 7))
        (compiler-ir-function-cons
          (opt-test-function-named "dead" (opt-global-dce-return-instrs 9))
          (compiler-ir-function-cons
            (opt-test-function-named
              "callback-target"
              (opt-global-dce-return-instrs 11))
            (IrFunctionNil)))))
    (IrExternNil)))

(define (opt-global-dce-no-main-program) : CompilerIrProgram
  (IrProgram
    (IrGlobalNil)
    (compiler-ir-function-cons
      (opt-test-function-named "helper" (opt-global-dce-return-instrs 7))
      (compiler-ir-function-cons
        (opt-test-function-named "dead" (opt-global-dce-return-instrs 9))
        (IrFunctionNil)))
    (IrExternNil)))

(define (compiler-optimize-global-dce-ok?) : bool
  (let
    [program : CompilerIrProgram (opt-global-dce-program)]
    ;; Level 0 keeps every function; level 1 (the cheap optimized build) prunes
    ;; functions unreachable from the roots without inlining the survivors.
    [level0 : CompilerIrProgram (optimize-program-with-level program 0)]
    [level1 : CompilerIrProgram (optimize-program-with-level program 1)]
    [no-main : CompilerIrProgram
      (optimize-program-with-level (opt-global-dce-no-main-program) 1)]
    [level0-functions : CompilerIrFunctionList (opt-program-functions level0)]
    [level1-functions : CompilerIrFunctionList (opt-program-functions level1)]
    [no-main-functions : CompilerIrFunctionList (opt-program-functions no-main)]
    (and
      (= (compiler-ir-function-list-count level0-functions) 4)
      (and
        (= (compiler-ir-function-list-count level1-functions) 3)
        (and
          (opt-function-list-defines? level1-functions "main")
          (and
            (opt-function-list-defines? level1-functions "helper")
            (and
              (opt-function-list-defines? level1-functions "callback-target")
              (and
                (not (opt-function-list-defines? level1-functions "dead"))
                (= (compiler-ir-function-list-count no-main-functions) 2)))))))))

(define (compiler-optimize-global-dce-self-test) : i64
  (if (compiler-optimize-global-dce-ok?)
    42
    1))

(define (opt-callgraph-test-slot [index : OptFunctionIndex] [name : String]) : i64
  (match (opt-function-index-slot index name)
    [(OptSomeI64 slot) slot]
    [(OptNoI64) -1]))

(define (opt-callgraph-test-edge?
  [index : OptFunctionIndex]
  [graph : OptCallGraph]
  [caller : String]
  [callee : String]) : bool
  (opt-callgraph-has-edge?
    graph
    (opt-callgraph-test-slot index caller)
    (opt-callgraph-test-slot index callee)))

(define (opt-callgraph-test-edge-count
  [index : OptFunctionIndex]
  [graph : OptCallGraph]
  [caller : String]) : i64
  (opt-callgraph-callee-count graph (opt-callgraph-test-slot index caller)))

(define (opt-callgraph-main-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrCall 0 "a" IrCallArgsNil (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrCall 1 "external" IrCallArgsNil (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrCallIndirect 2 (IrValueFunction "c") IrCallArgsNil (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrMov 3 (IrValueGlobal "address_taken") (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrTailCall "b" IrCallArgsNil (AstTyI64))
            IrInstrNil))))))

(define (opt-callgraph-call-instrs [name : String]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrCall 0 name IrCallArgsNil (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrReturn (IrSomeValue (IrValueI64 0)))
      IrInstrNil)))

(define (opt-callgraph-tail-instrs [name : String]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrTailCall name IrCallArgsNil (AstTyI64))
    IrInstrNil))

(define (opt-callgraph-return-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrReturn (IrSomeValue (IrValueI64 0)))
    IrInstrNil))

(define (opt-callgraph-acyclic-functions) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-test-function-named "main" (opt-callgraph-main-instrs))
    (compiler-ir-function-cons
      (opt-test-function-named "a" (opt-callgraph-call-instrs "c"))
      (compiler-ir-function-cons
        (opt-test-function-named "b" (opt-callgraph-return-instrs))
        (compiler-ir-function-cons
          (opt-test-function-named "c" (opt-callgraph-tail-instrs "b"))
          (compiler-ir-function-cons
            (opt-test-function-named
              "address_taken"
              (opt-callgraph-return-instrs))
            IrFunctionNil))))))

(define (opt-callgraph-rec-even-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrCall 0 "rec_odd" IrCallArgsNil (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrCall 1 "rec_odd" IrCallArgsNil (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrReturn (IrSomeValue (IrValueI64 0)))
        IrInstrNil))))

(define (opt-callgraph-recursive-functions) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-test-function-named "rec_even" (opt-callgraph-rec-even-instrs))
    (compiler-ir-function-cons
      (opt-test-function-named "rec_odd" (opt-callgraph-tail-instrs "rec_even"))
      (compiler-ir-function-cons
        (opt-test-function-named "lonely" (opt-callgraph-return-instrs))
        IrFunctionNil))))

(define (compiler-optimize-callgraph-acyclic-ok?) : bool
  (let
    [functions : CompilerIrFunctionList (opt-callgraph-acyclic-functions)]
    [index : OptFunctionIndex (opt-function-index-build functions)]
    [graph : OptCallGraph (opt-callgraph-build index)]
    (core/cond
      (not (= (struct-get graph count) 5))
      false
      (not (= (opt-callgraph-test-edge-count index graph "main") 2))
      false
      (not (opt-callgraph-test-edge? index graph "main" "a"))
      false
      (not (opt-callgraph-test-edge? index graph "main" "b"))
      false
      (opt-callgraph-test-edge? index graph "main" "c")
      false
      (opt-callgraph-test-edge? index graph "main" "address_taken")
      false
      (not (= (opt-callgraph-test-edge-count index graph "a") 1))
      false
      (not (opt-callgraph-test-edge? index graph "a" "c"))
      false
      (not (= (opt-callgraph-test-edge-count index graph "b") 0))
      false
      (not (= (opt-callgraph-test-edge-count index graph "c") 1))
      false
      (not (opt-callgraph-test-edge? index graph "c" "b"))
      false
      (not (= (opt-callgraph-test-edge-count index graph "address_taken") 0))
      false
      true)))

(define (compiler-optimize-callgraph-recursive-ok?) : bool
  (let
    [functions : CompilerIrFunctionList (opt-callgraph-recursive-functions)]
    [index : OptFunctionIndex (opt-function-index-build functions)]
    [graph : OptCallGraph (opt-callgraph-build index)]
    (core/cond
      (not (= (struct-get graph count) 3))
      false
      (not (= (opt-callgraph-test-edge-count index graph "rec_even") 1))
      false
      (not (opt-callgraph-test-edge? index graph "rec_even" "rec_odd"))
      false
      (opt-callgraph-test-edge? index graph "rec_even" "rec_even")
      false
      (not (= (opt-callgraph-test-edge-count index graph "rec_odd") 1))
      false
      (not (opt-callgraph-test-edge? index graph "rec_odd" "rec_even"))
      false
      (not (= (opt-callgraph-test-edge-count index graph "lonely") 0))
      false
      true)))

(define (opt-scc-result-component [result : OptSccResult] [slot : i64]) : i64
  (array-ref (struct-get result scc-of) slot))

(define (opt-scc-component-size [result : OptSccResult] [scc-id : i64]) : i64
  (let
    [scc-of : (Array i64) (struct-get result scc-of)]
    [count : i64 (array-length scc-of)]
    [slot : i64 0]
    [size : i64 0]
    (begin
      (while (< slot count)
        (begin
          (if (= (array-ref scc-of slot) scc-id)
            (set! size (+ size 1))
            unit)
          (set! slot (+ slot 1))))
      size)))

(define (opt-scc-order-position [result : OptSccResult] [scc-id : i64]) : i64
  (let
    [order : (Array i64) (struct-get result order)]
    [count : i64 (array-length order)]
    [index : i64 0]
    [position : i64 (- 0 1)]
    (begin
      (while (and (< index count) (< position 0))
        (begin
          (if (= (array-ref order index) scc-id)
            (set! position index)
            unit)
          (set! index (+ index 1))))
      position)))

(define (opt-scc-before? [result : OptSccResult] [left : i64] [right : i64]) : bool
  (let
    [left-pos : i64 (opt-scc-order-position result left)]
    [right-pos : i64 (opt-scc-order-position result right)]
    (and (>= left-pos 0) (and (>= right-pos 0) (< left-pos right-pos)))))

(define (opt-scc-self-recursive-functions) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-test-function-named "self" (opt-callgraph-tail-instrs "self"))
    (compiler-ir-function-cons
      (opt-test-function-named "leaf" (opt-callgraph-return-instrs))
      IrFunctionNil)))

(define (compiler-optimize-scc-self-recursive-ok?) : bool
  (let
    [functions : CompilerIrFunctionList (opt-scc-self-recursive-functions)]
    [index : OptFunctionIndex (opt-function-index-build functions)]
    [graph : OptCallGraph (opt-callgraph-build index)]
    [result : OptSccResult (opt-scc-compute graph)]
    [self-slot : i64 (opt-callgraph-test-slot index "self")]
    [leaf-slot : i64 (opt-callgraph-test-slot index "leaf")]
    [self-scc : i64 (opt-scc-result-component result self-slot)]
    [leaf-scc : i64 (opt-scc-result-component result leaf-slot)]
    (core/cond
      (not (opt-callgraph-has-edge? graph self-slot self-slot))
      false
      (< self-scc 0)
      false
      (< leaf-scc 0)
      false
      (= self-scc leaf-scc)
      false
      (not (= (opt-scc-component-size result self-scc) 1))
      false
      (not (= (opt-scc-component-size result leaf-scc) 1))
      false
      true)))

(define (compiler-optimize-scc-mutual-recursive-ok?) : bool
  (let
    [functions : CompilerIrFunctionList (opt-callgraph-recursive-functions)]
    [index : OptFunctionIndex (opt-function-index-build functions)]
    [graph : OptCallGraph (opt-callgraph-build index)]
    [result : OptSccResult (opt-scc-compute graph)]
    [even-slot : i64 (opt-callgraph-test-slot index "rec_even")]
    [odd-slot : i64 (opt-callgraph-test-slot index "rec_odd")]
    [lonely-slot : i64 (opt-callgraph-test-slot index "lonely")]
    [even-scc : i64 (opt-scc-result-component result even-slot)]
    [odd-scc : i64 (opt-scc-result-component result odd-slot)]
    [lonely-scc : i64 (opt-scc-result-component result lonely-slot)]
    (core/cond
      (< even-scc 0)
      false
      (not (= even-scc odd-scc))
      false
      (= even-scc lonely-scc)
      false
      (not (= (opt-scc-component-size result even-scc) 2))
      false
      (not (= (opt-scc-component-size result lonely-scc) 1))
      false
      true)))

(define (compiler-optimize-scc-reverse-topo-ok?) : bool
  (let
    [functions : CompilerIrFunctionList (opt-callgraph-acyclic-functions)]
    [index : OptFunctionIndex (opt-function-index-build functions)]
    [graph : OptCallGraph (opt-callgraph-build index)]
    [result : OptSccResult (opt-scc-compute graph)]
    [order : (Array i64) (struct-get result order)]
    [main-scc : i64
      (opt-scc-result-component result (opt-callgraph-test-slot index "main"))]
    [a-scc : i64
      (opt-scc-result-component result (opt-callgraph-test-slot index "a"))]
    [b-scc : i64
      (opt-scc-result-component result (opt-callgraph-test-slot index "b"))]
    [c-scc : i64
      (opt-scc-result-component result (opt-callgraph-test-slot index "c"))]
    [address-scc : i64
      (opt-scc-result-component
        result
        (opt-callgraph-test-slot index "address_taken"))]
    (core/cond
      (not (= (array-length order) 5))
      false
      (not (= (array-ref order 0) b-scc))
      false
      (not (= (array-ref order 1) c-scc))
      false
      (not (= (array-ref order 2) a-scc))
      false
      (not (= (array-ref order 3) main-scc))
      false
      (not (= (array-ref order 4) address-scc))
      false
      (not (opt-scc-before? result b-scc c-scc))
      false
      (not (opt-scc-before? result c-scc a-scc))
      false
      (not (opt-scc-before? result a-scc main-scc))
      false
      (not (opt-scc-before? result b-scc main-scc))
      false
      true)))

(define (compiler-optimize-scc-self-test) : i64
  (core/cond
    (not (compiler-optimize-scc-self-recursive-ok?))
    1
    (not (compiler-optimize-scc-mutual-recursive-ok?))
    2
    (not (compiler-optimize-scc-reverse-topo-ok?))
    3
    42))

(define (compiler-optimize-callgraph-self-test) : i64
  (if (compiler-optimize-callgraph-acyclic-ok?)
    (if (compiler-optimize-callgraph-recursive-ok?)
      42
      2)
    1))

(define (opt-function-blocks [func : CompilerIrFunction]) : CompilerIrBlockList
  (match func
    [(IrFunction _ _ _ _ blocks) blocks]))

(define (opt-function-frame [func : CompilerIrFunction]) : i64
  (match func
    [(IrFunction _ _ _ frame _) frame]))

(define (opt-inline-frame-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (IrParam "left" (AstTyI64) 0)
    (compiler-ir-param-cons (IrParam "right" (AstTyI64) 1) IrParamNil)))

(define (opt-inline-frame-callee) : CompilerIrFunction
  (IrFunction
    "inline_add"
    (opt-inline-frame-params)
    (AstTyI64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 2)))
            IrInstrNil)))
      IrBlockNil)))

(define (opt-inline-frame-caller) : CompilerIrFunction
  (IrFunction
    "main"
    IrParamNil
    (AstTyI64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 10) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueI64 32) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrCall
                2
                "inline_add"
                (IrCallArgsTwo (IrValueVar 0) (IrValueVar 1))
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 2)))
                IrInstrNil)))))
      IrBlockNil)))

(define (opt-inline-frame-functions) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-frame-caller)
    (compiler-ir-function-cons (opt-inline-frame-callee) IrFunctionNil)))

(define (opt-inline-known-indirect-caller) : CompilerIrFunction
  (IrFunction
    "main"
    IrParamNil
    (AstTyI64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 10) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueI64 32) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrCallIndirect
                2
                (IrValueFunction "inline_add")
                (IrCallArgsTwo (IrValueVar 0) (IrValueVar 1))
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 2)))
                IrInstrNil)))))
      IrBlockNil)))

(define (opt-inline-known-indirect-functions) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-known-indirect-caller)
    (compiler-ir-function-cons (opt-inline-frame-callee) IrFunctionNil)))

(define (opt-inline-level-functions [level : i64]) : CompilerIrFunctionList
  (opt-inline-program-functions (opt-inline-frame-functions) level))

(define (opt-inline-self-recursive) : CompilerIrFunction
  (IrFunction
    "self_inline"
    IrParamNil
    (AstTyI64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrCall 0 "self_inline" IrCallArgsNil (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 0)))
            IrInstrNil)))
      IrBlockNil)))

(define (opt-inline-large-callee-instrs [idx : i64]) : CompilerIrInstrList
  (if (> idx (opt-inline-max-body))
    (compiler-ir-instr-cons
      (IrInstrReturn (IrSomeValue (IrValueVar idx)))
      IrInstrNil)
    (compiler-ir-instr-cons
      (IrInstrBinOp
        (+ idx 1)
        (IrBinAdd)
        (if (= idx 0)
          (IrValueI64 0)
          (IrValueVar idx))
        (IrValueI64 1)
        (AstTyI64))
      (opt-inline-large-callee-instrs (+ idx 1)))))

(define (opt-inline-large-callee) : CompilerIrFunction
  (IrFunction
    "too_large_inline"
    IrParamNil
    (AstTyI64)
    (+ (opt-inline-max-body) 2)
    (compiler-ir-block-cons
      (compiler-ir-block "entry" (opt-inline-large-callee-instrs 0))
      IrBlockNil)))

(define (opt-inline-bounds-callee) : CompilerIrFunction
  (IrFunction
    "bounds_inline"
    (compiler-ir-param-cons
      (IrParam "idx" (AstTyI64) 0)
      (compiler-ir-param-cons (IrParam "len" (AstTyI64) 1) IrParamNil))
    (AstTyI64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_inline.ok")
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 0)))
            IrInstrNil)))
      IrBlockNil)))

(define (opt-inline-call-one [dst : i64] [callee : String]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrCall dst callee IrCallArgsNil (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrReturn (IrSomeValue (IrValueVar dst)))
      IrInstrNil)))

(define (opt-inline-call-large) : CompilerIrFunction
  (IrFunction
    "main"
    IrParamNil
    (AstTyI64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block "entry" (opt-inline-call-one 0 "too_large_inline"))
      IrBlockNil)))

(define (opt-inline-call-bounds) : CompilerIrFunction
  (IrFunction
    "main"
    IrParamNil
    (AstTyI64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrCall
            2
            "bounds_inline"
            (IrCallArgsTwo (IrValueI64 0) (IrValueI64 4))
            (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 2)))
            IrInstrNil)))
      IrBlockNil)))

(define (opt-inline-large-functions) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-call-large)
    (compiler-ir-function-cons (opt-inline-large-callee) IrFunctionNil)))

(define (opt-inline-bounds-functions) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-call-bounds)
    (compiler-ir-function-cons (opt-inline-bounds-callee) IrFunctionNil)))

(define (opt-inline-multi-call-caller) : CompilerIrFunction
  (IrFunction
    "main"
    IrParamNil
    (AstTyI64)
    6
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 10) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueI64 20) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrCall
                2
                "inline_add"
                (IrCallArgsTwo (IrValueVar 0) (IrValueVar 1))
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrCall
                  3
                  "inline_add"
                  (IrCallArgsTwo (IrValueVar 1) (IrValueVar 2))
                  (AstTyI64))
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 3)))
                  IrInstrNil))))))
      IrBlockNil)))

(define (opt-inline-multi-call-functions) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-multi-call-caller)
    (compiler-ir-function-cons (opt-inline-frame-callee) IrFunctionNil)))

(define (opt-inline-cascade-mid) : CompilerIrFunction
  (IrFunction
    "inline_mid"
    (opt-inline-frame-params)
    (AstTyI64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrCall
            2
            "inline_add"
            (IrCallArgsTwo (IrValueVar 0) (IrValueVar 1))
            (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 2)))
            IrInstrNil)))
      IrBlockNil)))

(define (opt-inline-cascade-main) : CompilerIrFunction
  (IrFunction
    "main"
    IrParamNil
    (AstTyI64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 20) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueI64 22) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrCall
                2
                "inline_mid"
                (IrCallArgsTwo (IrValueVar 0) (IrValueVar 1))
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 2)))
                IrInstrNil)))))
      IrBlockNil)))

(define (opt-inline-cascade-functions) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-cascade-main)
    (compiler-ir-function-cons
      (opt-inline-cascade-mid)
      (compiler-ir-function-cons (opt-inline-frame-callee) IrFunctionNil))))

(define (opt-inline-mutual-a) : CompilerIrFunction
  (IrFunction
    "inline_mut_a"
    IrParamNil
    (AstTyI64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrCall 0 "inline_mut_b" IrCallArgsNil (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 0)))
            IrInstrNil)))
      IrBlockNil)))

(define (opt-inline-mutual-b) : CompilerIrFunction
  (IrFunction
    "inline_mut_b"
    IrParamNil
    (AstTyI64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrCall 0 "inline_mut_a" IrCallArgsNil (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 0)))
            IrInstrNil)))
      IrBlockNil)))

(define (opt-inline-mutual-functions) : CompilerIrFunctionList
  (compiler-ir-function-cons
    (opt-inline-mutual-a)
    (compiler-ir-function-cons (opt-inline-mutual-b) IrFunctionNil)))

(define (opt-devirt-dynamic-caller) : CompilerIrFunction
  (IrFunction
    "dynamic"
    IrParamNil
    (AstTyI64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 0) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrCallIndirect
              2
              (IrValueVar 0)
              (IrCallArgsOne (IrValueI64 1))
              (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 2)))
              IrInstrNil))))
      IrBlockNil)))

(define (opt-devirt-reach-target) : CompilerIrFunction
  (IrFunction
    "kept_target"
    IrParamNil
    (AstTyI64)
    1
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons (IrInstrJump "exit") IrInstrNil))
      (compiler-ir-block-cons
        (compiler-ir-block
          "exit"
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueI64 7)))
            IrInstrNil))
        IrBlockNil))))

(define (opt-devirt-reach-main) : CompilerIrFunction
  (IrFunction
    "main"
    IrParamNil
    (AstTyI64)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrCallIndirect
            1
            (IrValueFunction "kept_target")
            IrCallArgsNil
            (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 1)))
            IrInstrNil)))
      IrBlockNil)))

(define (opt-devirt-reach-program) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (compiler-ir-function-cons
      (opt-devirt-reach-main)
      (compiler-ir-function-cons
        (opt-devirt-reach-target)
        (compiler-ir-function-cons
          (opt-test-function-named "dead" (opt-global-dce-return-instrs 9))
          IrFunctionNil)))
    IrExternNil))

(define (opt-inline-count-binop-dst [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrBinOp d _ _ _ _)
            (if (= d dst)
              1
              0)]
          [_ 0])
        (opt-inline-count-binop-dst (box-get rest) dst))]))

(define (opt-count-direct-call-name
  [instrs : CompilerIrInstrList]
  [name : String]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrCall _ call-name _ _)
            (if (string-eq call-name name)
              1
              0)]
          [_ 0])
        (opt-count-direct-call-name (box-get rest) name))]))

(define (opt-count-indirect-call-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrCallIndirect _ _ _ _) 1]
          [(IrInstrCallIndirectC _ _ _ _) 1]
          [_ 0])
        (opt-count-indirect-call-instrs (box-get rest)))]))

(define (opt-inline-mov-dst-src?
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [src : i64]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrMov d (IrValueVar s) _)
          (if (and (= d dst) (= s src))
            true
            (opt-inline-mov-dst-src? (box-get rest) dst src))]
        [_ (opt-inline-mov-dst-src? (box-get rest) dst src)])]))

(define (opt-inline-function-instrs
  [functions : CompilerIrFunctionList]
  [name : String]) : CompilerIrInstrList
  (match (opt-function-list-find functions name)
    [(OptSomeFunction func) (opt-function-first-instrs func)]
    [(OptNoFunction) IrInstrNil]))

(define (opt-inline-function-frame
  [functions : CompilerIrFunctionList]
  [name : String]) : i64
  (match (opt-function-list-find functions name)
    [(OptSomeFunction func) (opt-function-frame func)]
    [(OptNoFunction) (- 0 1)]))

(define (compiler-optimize-inline-level-gate-ok?) : bool
  (let
    [level0 : CompilerIrInstrList
      (opt-inline-function-instrs (opt-inline-level-functions 0) "main")]
    [level1 : CompilerIrInstrList
      (opt-inline-function-instrs (opt-inline-level-functions 1) "main")]
    [level2 : CompilerIrInstrList
      (opt-inline-function-instrs (opt-inline-level-functions 2) "main")]
    (and
      (= (opt-count-direct-call-name level0 "inline_add") 1)
      (and
        (= (opt-count-direct-call-name level1 "inline_add") 1)
        (= (opt-count-direct-call-name level2 "inline_add") 0)))))

(define (compiler-optimize-inline-self-recursive-ok?) : bool
  (let
    [functions : CompilerIrFunctionList
      (compiler-ir-function-cons (opt-inline-self-recursive) IrFunctionNil)]
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions functions 2)]
    [instrs : CompilerIrInstrList
      (opt-inline-function-instrs optimized "self_inline")]
    (= (opt-count-direct-call-name instrs "self_inline") 1)))

(define (compiler-optimize-inline-large-callee-ok?) : bool
  (let
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-large-functions) 2)]
    [instrs : CompilerIrInstrList (opt-inline-function-instrs optimized "main")]
    (= (opt-count-direct-call-name instrs "too_large_inline") 1)))

(define (compiler-optimize-inline-bounds-callee-ok?) : bool
  (let
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-bounds-functions) 2)]
    [instrs : CompilerIrInstrList (opt-inline-function-instrs optimized "main")]
    (= (opt-count-direct-call-name instrs "bounds_inline") 1)))

(define (compiler-optimize-inline-multi-call-ok?) : bool
  (let
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-multi-call-functions) 2)]
    [instrs : CompilerIrInstrList (opt-inline-function-instrs optimized "main")]
    [frame : i64 (opt-inline-function-frame optimized "main")]
    (core/cond
      (not (= frame 8))
      false
      (not (= (compiler-ir-instr-list-count instrs) 7))
      false
      (not (= (opt-count-direct-call-name instrs "inline_add") 0))
      false
      (not (= (opt-inline-count-binop-dst instrs 6) 1))
      false
      (not (= (opt-inline-count-binop-dst instrs 7) 1))
      false
      (not (opt-inline-mov-dst-src? instrs 2 6))
      false
      (not (opt-inline-mov-dst-src? instrs 3 7))
      false
      true)))

(define (compiler-optimize-inline-bottom-up-writeback-ok?) : bool
  (let
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-cascade-functions) 2)]
    [main-instrs : CompilerIrInstrList
      (opt-inline-function-instrs optimized "main")]
    [mid-instrs : CompilerIrInstrList
      (opt-inline-function-instrs optimized "inline_mid")]
    (and
      (= (opt-count-direct-call-name main-instrs "inline_mid") 0)
      (and
        (= (opt-count-direct-call-name main-instrs "inline_add") 0)
        (and
          (= (opt-inline-count-binop-dst main-instrs 4) 1)
          (and
            (= (opt-count-direct-call-name mid-instrs "inline_add") 0)
            (= (opt-inline-count-binop-dst mid-instrs 3) 1)))))))

(define (compiler-optimize-inline-mutual-scc-refusal-ok?) : bool
  (let
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-mutual-functions) 2)]
    [a-instrs : CompilerIrInstrList
      (opt-inline-function-instrs optimized "inline_mut_a")]
    [b-instrs : CompilerIrInstrList
      (opt-inline-function-instrs optimized "inline_mut_b")]
    (and
      (= (opt-count-direct-call-name a-instrs "inline_mut_b") 1)
      (and
        (= (opt-count-direct-call-name a-instrs "inline_mut_a") 0)
        (and
          (= (opt-count-direct-call-name b-instrs "inline_mut_a") 1)
          (= (opt-count-direct-call-name b-instrs "inline_mut_b") 0))))))

(define (compiler-optimize-inline-census-direct-ok?) : bool
  (let
    [functions : CompilerIrFunctionList (opt-inline-frame-functions)]
    [index : OptFunctionIndex (opt-function-index-build functions)]
    [census : OptInlineCensus (opt-inline-census-build index functions)]
    (and
      (= (opt-inline-census-refcount census "inline_add") 1)
      (and
        (not (opt-inline-census-address-taken? census "inline_add"))
        (opt-inline-census-absorbable? census "main" "inline_add")))))

(define (compiler-optimize-inline-census-address-ok?) : bool
  (let
    [functions : CompilerIrFunctionList (opt-inline-known-indirect-functions)]
    [index : OptFunctionIndex (opt-function-index-build functions)]
    [census : OptInlineCensus (opt-inline-census-build index functions)]
    (and
      (opt-inline-census-address-taken? census "inline_add")
      (not (opt-inline-census-absorbable? census "main" "inline_add")))))

(define (compiler-optimize-inline-cost-model-ok?) : bool
  (and
    (opt-inline-value-constant? (IrValueI64 7))
    (and
      (not (opt-inline-value-constant? (IrValueVar 7)))
      (and
        (=
          (opt-inline-args-const-count
            (IrCallArgsTwo (IrValueI64 1) (IrValueVar 2)))
          1)
        (and
          (opt-inline-cost-inline? 8 0 0 false 64 0)
          (and
            (not (opt-inline-cost-inline? 10 3 0 false 10 0))
            (and
              (opt-inline-cost-inline? 10 3 0 true 10 0)
              (and
                (not
                  (opt-inline-cost-inline?
                    1
                    1
                    0
                    true
                    (opt-heavy-pass-block-limit)
                    0))
                (and
                  (not (opt-inline-cost-inline? 1 1 0 true 80 32))
                  (opt-inline-cost-inline? 8 1 8 false 10 0))))))))))

(define (compiler-optimize-inline-self-test) : i64
  (let
    [optimized : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-frame-functions) 2)]
    [devirt-direct : CompilerIrFunction
      (opt-devirt-known-function-function (opt-inline-known-indirect-caller))]
    [devirt-dynamic : CompilerIrFunction
      (opt-devirt-known-function-function (opt-devirt-dynamic-caller))]
    [devirt-inlined : CompilerIrFunctionList
      (opt-inline-program-functions (opt-inline-known-indirect-functions) 2)]
    [devirt-reach : CompilerIrFunctionList
      (opt-program-functions
        (optimize-program-with-level (opt-devirt-reach-program) 2))]
    [valid-structure : bool
      (opt-inline-structure-ok? (opt-function-blocks (opt-inline-frame-caller)))]
    [duplicate-def-structure : bool
      (opt-inline-structure-ok?
        (opt-function-blocks (opt-ssa-duplicate-def-function)))]
    [duplicate-label-revert : CompilerIrFunction
      (opt-inline-revert-or-keep
        (opt-inline-frame-caller)
        (opt-ssa-duplicate-label-function))]
    [unknown-successor-revert : CompilerIrFunction
      (opt-inline-revert-or-keep
        (opt-inline-frame-caller)
        (opt-ssa-unknown-successor-function))]
    [bad-phi-revert : CompilerIrFunction
      (opt-inline-revert-or-keep
        (opt-inline-frame-caller)
        (opt-ssa-bad-phi-function))]
    [valid-keep : CompilerIrFunction
      (opt-inline-revert-or-keep
        (opt-inline-frame-caller)
        (opt-inline-frame-callee))]
    (match (opt-function-list-find optimized "main")
      [(OptSomeFunction main)
        (let
          [instrs : CompilerIrInstrList (opt-function-first-instrs main)]
          (core/cond
            (not (= (opt-function-frame main) 4))
            1
            (not (= (compiler-ir-instr-list-count instrs) 5))
            2
            (not (= (opt-inline-count-binop-dst instrs 3) 1))
            3
            (not (= (opt-inline-count-binop-dst instrs 5) 0))
            4
            (not (opt-inline-mov-dst-src? instrs 2 3))
            5
            (not (= (opt-count-direct-call-name instrs "inline_add") 0))
            6
            (not
              (=
                (opt-count-direct-call-name
                  (opt-function-first-instrs devirt-direct)
                  "inline_add")
                1))
            7
            (not
              (=
                (opt-count-indirect-call-instrs
                  (opt-function-first-instrs devirt-direct))
                0))
            8
            (not
              (=
                (opt-count-indirect-call-instrs
                  (opt-function-first-instrs devirt-dynamic))
                1))
            9
            (not
              (=
                (opt-count-direct-call-name
                  (opt-function-first-instrs devirt-dynamic)
                  "inline_add")
                0))
            10
            (match (opt-function-list-find devirt-inlined "main")
              [(OptSomeFunction indirect-main)
                (let
                  [indirect-instrs : CompilerIrInstrList
                    (opt-function-first-instrs indirect-main)]
                  (core/cond
                    (not (= (opt-function-frame indirect-main) 4))
                    11
                    (not (= (compiler-ir-instr-list-count indirect-instrs) 5))
                    12
                    (not (= (opt-inline-count-binop-dst indirect-instrs 3) 1))
                    13
                    (not (= (opt-count-indirect-call-instrs indirect-instrs) 0))
                    14
                    (not (opt-inline-mov-dst-src? indirect-instrs 2 3))
                    15
                    (not (= (compiler-ir-function-list-count devirt-reach) 2))
                    16
                    (not (opt-function-list-defines? devirt-reach "main"))
                    17
                    (not
                      (opt-function-list-defines? devirt-reach "kept_target"))
                    18
                    (opt-function-list-defines? devirt-reach "dead")
                    19
                    (not valid-structure)
                    20
                    (not duplicate-def-structure)
                    21
                    (not
                      (opt-function-eq
                        duplicate-label-revert
                        (opt-inline-frame-caller)))
                    22
                    (not
                      (opt-function-eq
                        unknown-successor-revert
                        (opt-inline-frame-caller)))
                    23
                    (not
                      (opt-function-eq bad-phi-revert (opt-inline-frame-caller)))
                    24
                    (not (opt-function-eq valid-keep (opt-inline-frame-callee)))
                    25
                    (not (compiler-optimize-inline-level-gate-ok?))
                    26
                    (not (compiler-optimize-inline-self-recursive-ok?))
                    27
                    (not (compiler-optimize-inline-large-callee-ok?))
                    28
                    (not (compiler-optimize-inline-bounds-callee-ok?))
                    29
                    (not (compiler-optimize-inline-multi-call-ok?))
                    30
                    (not (compiler-optimize-inline-census-direct-ok?))
                    31
                    (not (compiler-optimize-inline-census-address-ok?))
                    32
                    (not (compiler-optimize-inline-cost-model-ok?))
                    33
                    (not (compiler-optimize-inline-bottom-up-writeback-ok?))
                    34
                    (not (compiler-optimize-inline-mutual-scc-refusal-ok?))
                    35
                    42))]
              [(OptNoFunction) 36])))]
      [(OptNoFunction) 37])))

(define (opt-block-list-has-label?
  [blocks : CompilerIrBlockList]
  [label : String]) : bool
  (match blocks
    [(IrBlockNil) false]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock block-label _)
          (if (string-eq block-label label)
            true
            (opt-block-list-has-label? (box-get rest) label))])]
    [(IrBlockArray seq)
      (opt-block-list-has-label? (compiler-ir-block-seq-to-list seq) label)]))

(define (opt-block-list-label-at?
  [blocks : CompilerIrBlockList]
  [index : i64]
  [label : String]) : bool
  (match blocks
    [(IrBlockNil) false]
    [(IrBlockCons block rest)
      (if (= index 0)
        (match block
          [(IrBlock block-label _) (string-eq block-label label)])
        (opt-block-list-label-at? (box-get rest) (- index 1) label))]
    [(IrBlockArray seq)
      (opt-block-list-label-at? (compiler-ir-block-seq-to-list seq) index label)]))

(define (opt-count-branches-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrBranch _ _ _) 1]
          [_ 0])
        (opt-count-branches-instrs (box-get rest)))]))

(define (opt-count-branches-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-branches-instr-seq-from
      slots
      (+ index 1)
      count
      (+
        acc
        (match (array-ref slots index)
          [(IrInstrBranch _ _ _) 1]
          [_ 0])))))

(define (opt-count-branches-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-branches-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-branches-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-count-branches-instr-seq instrs)
            (opt-count-branches-blocks (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-count-branches-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-count-jump-to-instrs
  [instrs : CompilerIrInstrList]
  [target : String]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrJump label)
            (if (string-eq label target)
              1
              0)]
          [_ 0])
        (opt-count-jump-to-instrs (box-get rest) target))]))

(define (opt-count-jump-to-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [target : String]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-jump-to-instr-seq-from
      slots
      (+ index 1)
      count
      target
      (+
        acc
        (match (array-ref slots index)
          [(IrInstrJump label)
            (if (string-eq label target)
              1
              0)]
          [_ 0])))))

(define (opt-count-jump-to-instr-seq
  [instrs : CompilerIrInstrSeq]
  [target : String]) : i64
  (opt-count-jump-to-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    target
    0))

(define (opt-count-jump-to-blocks
  [blocks : CompilerIrBlockList]
  [target : String]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-count-jump-to-instr-seq instrs target)
            (opt-count-jump-to-blocks (box-get rest) target))])]
    [(IrBlockArray seq)
      (opt-count-jump-to-blocks (compiler-ir-block-seq-to-list seq) target)]))

(define (opt-count-tail-call-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrTailCall _ _ _) 1]
          [_ 0])
        (opt-count-tail-call-instrs (box-get rest)))]))

(define (opt-count-tail-call-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-tail-call-instr-seq-from
      slots
      (+ index 1)
      count
      (+
        acc
        (match (array-ref slots index)
          [(IrInstrTailCall _ _ _) 1]
          [_ 0])))))

(define (opt-count-tail-call-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-tail-call-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-tail-call-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-count-tail-call-instr-seq instrs)
            (opt-count-tail-call-blocks (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-count-tail-call-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-tailrec-test-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (IrParam "a" (AstTyI64) 0)
    (compiler-ir-param-cons (IrParam "b" (AstTyI64) 1) (IrParamNil))))

(define (opt-tailrec-test-function) : CompilerIrFunction
  (IrFunction
    "tail_swap"
    (opt-tailrec-test-params)
    (AstTyI64)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrTailCall
            "tail_swap"
            (IrCallArgsTwo (IrValueVar 1) (IrValueVar 0))
            (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 0)))
            (IrInstrNil))))
      (IrBlockNil))))

(define (opt-tailrec-expected-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrMov 2 (IrValueVar 1) (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrMov 3 (IrValueVar 0) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrMov 0 (IrValueVar 2) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrMov 1 (IrValueVar 3) (AstTyI64))
          (compiler-ir-instr-cons (IrInstrJump "entry") (IrInstrNil)))))))

(define (compiler-optimize-tailrec-self-test) : i64
  (let
    [rewritten : CompilerIrFunction
      (opt-tailrec-function (opt-tailrec-test-function))]
    [once : CompilerIrFunction
      (optimize-function-once (opt-tailrec-test-function))]
    [rewritten-blocks : CompilerIrBlockList (opt-function-blocks rewritten)]
    [once-blocks : CompilerIrBlockList (opt-function-blocks once)]
    [rewritten-instrs : CompilerIrInstrList
      (opt-function-first-instrs rewritten)]
    (core/cond
      (not (= (opt-function-frame rewritten) 4))
      1
      (not (opt-instr-list-eq rewritten-instrs (opt-tailrec-expected-instrs)))
      2
      (not (= (opt-count-tail-call-blocks rewritten-blocks) 0))
      3
      (not (= (opt-count-jump-to-blocks rewritten-blocks "entry") 1))
      4
      (not (= (opt-count-tail-call-blocks once-blocks) 0))
      5
      (not (= (opt-count-jump-to-blocks once-blocks "entry") 1))
      6
      42)))

(define (opt-count-phi-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrPhi _ _ _) 1]
          [_ 0])
        (opt-count-phi-instrs (box-get rest)))]))

(define (opt-count-phi-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-phi-instr-seq-from
      slots
      (+ index 1)
      count
      (+
        acc
        (match (array-ref slots index)
          [(IrInstrPhi _ _ _) 1]
          [_ 0])))))

(define (opt-count-phi-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-phi-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-phi-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-count-phi-instr-seq instrs)
            (opt-count-phi-blocks (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-count-phi-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-count-mov-dst-instrs [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrMov mov-dst _ _)
            (if (= mov-dst dst)
              1
              0)]
          [_ 0])
        (opt-count-mov-dst-instrs (box-get rest) dst))]))

(define (opt-count-mov-dst-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [dst : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-mov-dst-instr-seq-from
      slots
      (+ index 1)
      count
      dst
      (+
        acc
        (match (array-ref slots index)
          [(IrInstrMov mov-dst _ _)
            (if (= mov-dst dst)
              1
              0)]
          [_ 0])))))

(define (opt-count-mov-dst-instr-seq [instrs : CompilerIrInstrSeq] [dst : i64]) : i64
  (opt-count-mov-dst-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    dst
    0))

(define (opt-count-mov-dst-blocks [blocks : CompilerIrBlockList] [dst : i64]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-count-mov-dst-instr-seq instrs dst)
            (opt-count-mov-dst-blocks (box-get rest) dst))])]
    [(IrBlockArray seq)
      (opt-count-mov-dst-blocks (compiler-ir-block-seq-to-list seq) dst)]))

(define (opt-count-arith-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-count-arith-instr-seq instrs)
            (opt-count-arith-blocks (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-count-arith-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-count-arith-label-blocks
  [blocks : CompilerIrBlockList]
  [label : String]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock block-label instrs)
          (if (string-eq block-label label)
            (opt-count-arith-instr-seq instrs)
            (opt-count-arith-label-blocks (box-get rest) label))])]
    [(IrBlockArray seq)
      (opt-count-arith-label-blocks (compiler-ir-block-seq-to-list seq) label)]))

(define (opt-count-mul-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrBinOp _ op _ _ _)
            (match op
              [(IrBinMul) 1]
              [_ 0])]
          [_ 0])
        (opt-count-mul-instrs (box-get rest)))]))

(define (opt-count-mul-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-mul-instr-seq-from
      slots
      (+ index 1)
      count
      (+
        acc
        (match (array-ref slots index)
          [(IrInstrBinOp _ op _ _ _)
            (match op
              [(IrBinMul) 1]
              [_ 0])]
          [_ 0])))))

(define (opt-count-mul-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-mul-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-mul-label-blocks
  [blocks : CompilerIrBlockList]
  [label : String]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock block-label instrs)
          (if (string-eq block-label label)
            (opt-count-mul-instr-seq instrs)
            (opt-count-mul-label-blocks (box-get rest) label))])]
    [(IrBlockArray seq)
      (opt-count-mul-label-blocks (compiler-ir-block-seq-to-list seq) label)]))

(define (opt-blocks-mov-dst-i64-value
  [blocks : CompilerIrBlockList]
  [dst : i64]
  [fallback : i64]) : i64
  (match blocks
    [(IrBlockNil) fallback]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (let
            [value : i64 (opt-mov-dst-i64-value-instr-seq instrs dst fallback)]
            (if (= value fallback)
              (opt-blocks-mov-dst-i64-value (box-get rest) dst fallback)
              value))])]
    [(IrBlockArray seq)
      (opt-blocks-mov-dst-i64-value
        (compiler-ir-block-seq-to-list seq)
        dst
        fallback)]))

(define (opt-count-cast-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-count-cast-instr-seq instrs)
            (opt-count-cast-blocks (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-count-cast-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-count-gep-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrGep _ _ _ _) 1]
          [_ 0])
        (opt-count-gep-instrs (box-get rest)))]))

(define (opt-count-gep-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-gep-instr-seq-from
      slots
      (+ index 1)
      count
      (+
        acc
        (match (array-ref slots index)
          [(IrInstrGep _ _ _ _) 1]
          [_ 0])))))

(define (opt-count-gep-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-gep-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-gep-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-count-gep-instr-seq instrs)
            (opt-count-gep-blocks (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-count-gep-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-count-gep-label-blocks
  [blocks : CompilerIrBlockList]
  [label : String]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock block-label instrs)
          (if (string-eq block-label label)
            (opt-count-gep-instr-seq instrs)
            (opt-count-gep-label-blocks (box-get rest) label))])]
    [(IrBlockArray seq)
      (opt-count-gep-label-blocks (compiler-ir-block-seq-to-list seq) label)]))

(define (opt-count-load-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrLoad _ _ _) 1]
          [_ 0])
        (opt-count-load-instrs (box-get rest)))]))

(define (opt-count-load-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [acc : i64]) : i64
  (if (>= index count)
    acc
    (opt-count-load-instr-seq-from
      slots
      (+ index 1)
      count
      (+
        acc
        (match (array-ref slots index)
          [(IrInstrLoad _ _ _) 1]
          [_ 0])))))

(define (opt-count-load-instr-seq [instrs : CompilerIrInstrSeq]) : i64
  (opt-count-load-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    0))

(define (opt-count-load-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-count-load-instr-seq instrs)
            (opt-count-load-blocks (box-get rest)))])]
    [(IrBlockArray seq)
      (opt-count-load-blocks (compiler-ir-block-seq-to-list seq))]))

(define (opt-blocks-binop-lhs-var
  [blocks : CompilerIrBlockList]
  [dst : i64]
  [fallback : i64]) : i64
  (match blocks
    [(IrBlockNil) fallback]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (let
            [value : i64 (opt-copy-binop-lhs-var-instr-seq instrs dst)]
            (if (= value (- 0 1))
              (opt-blocks-binop-lhs-var (box-get rest) dst fallback)
              value))])]
    [(IrBlockArray seq)
      (opt-blocks-binop-lhs-var
        (compiler-ir-block-seq-to-list seq)
        dst
        fallback)]))

(define (opt-blocks-mov-src-var
  [blocks : CompilerIrBlockList]
  [dst : i64]
  [fallback : i64]) : i64
  (match blocks
    [(IrBlockNil) fallback]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (let
            [value : i64 (opt-mov-src-var-instr-seq instrs dst fallback)]
            (if (= value fallback)
              (opt-blocks-mov-src-var (box-get rest) dst fallback)
              value))])]
    [(IrBlockArray seq)
      (opt-blocks-mov-src-var (compiler-ir-block-seq-to-list seq) dst fallback)]))

(define (opt-mov-src-var
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [fallback : i64]) : i64
  (match instrs
    [(IrInstrNil) fallback]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrMov mov-dst (IrValueVar src) _)
          (if (= mov-dst dst)
            src
            (opt-mov-src-var (box-get rest) dst fallback))]
        [_ (opt-mov-src-var (box-get rest) dst fallback)])]))

(define (opt-mov-src-var-instr-seq-from
  [slots : (Array CompilerIrInstr)]
  [index : i64]
  [count : i64]
  [dst : i64]
  [fallback : i64]) : i64
  (if (>= index count)
    fallback
    (match (array-ref slots index)
      [(IrInstrMov mov-dst (IrValueVar src) _)
        (if (= mov-dst dst)
          src
          (opt-mov-src-var-instr-seq-from slots (+ index 1) count dst fallback))]
      [_ (opt-mov-src-var-instr-seq-from slots (+ index 1) count dst fallback)])))

(define (opt-mov-src-var-instr-seq
  [instrs : CompilerIrInstrSeq]
  [dst : i64]
  [fallback : i64]) : i64
  (opt-mov-src-var-instr-seq-from
    (struct-get instrs slots)
    0
    (struct-get instrs len)
    dst
    fallback))

(define (opt-cfg-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (IrFunction "cfg" (IrParamNil) (AstTyI64) 16 blocks))

(define (opt-sccp-cond-params) : CompilerIrParamList
  (compiler-ir-param-cons (IrParam "cond" (AstTyBool) 0) (IrParamNil)))

(define (opt-sccp-loop-params) : CompilerIrParamList
  (compiler-ir-param-cons (IrParam "cond" (AstTyBool) 4) (IrParamNil)))

(define (opt-gvn-scalar-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (IrParam "cond" (AstTyBool) 0)
    (compiler-ir-param-cons
      (IrParam "lhs" (AstTyI64) 1)
      (compiler-ir-param-cons (IrParam "rhs" (AstTyI64) 2) (IrParamNil)))))

(define (opt-gvn-pointer-params) : CompilerIrParamList
  (compiler-ir-param-cons (IrParam "ptr" (AstTyI64) 1) (IrParamNil)))

(define (opt-gvn-pointer-cond-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (IrParam "cond" (AstTyBool) 0)
    (compiler-ir-param-cons (IrParam "ptr" (AstTyI64) 1) (IrParamNil))))

(define (opt-gvn-function
  [name : String]
  [params : CompilerIrParamList]
  [ret-ty : AstType]
  [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (IrFunction name params ret-ty 16 blocks))

(define (opt-gvn-dominated-diamond-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBinOp 3 (IrBinAdd) (IrValueVar 1) (IrValueVar 2) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrBranch (IrValueVar 0) "then" "else")
          (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "then"
        (compiler-ir-instr-cons
          (IrInstrBinOp 4 (IrBinAdd) (IrValueVar 1) (IrValueVar 2) (AstTyI64))
          (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "else"
          (compiler-ir-instr-cons
            (IrInstrBinOp 5 (IrBinAdd) (IrValueVar 1) (IrValueVar 2) (AstTyI64))
            (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "join"
            (compiler-ir-instr-cons
              (IrInstrPhi
                6
                (compiler-ir-phi-input-cons
                  (IrValueVar 4)
                  "then"
                  (compiler-ir-phi-input-cons
                    (IrValueVar 5)
                    "else"
                    (IrPhiInputNil)))
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 6)))
                (IrInstrNil))))
          (IrBlockNil))))))

(define (opt-gvn-sibling-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBranch (IrValueVar 0) "then" "else")
        (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "then"
        (compiler-ir-instr-cons
          (IrInstrBinOp 3 (IrBinAdd) (IrValueVar 1) (IrValueVar 2) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 3)))
            (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "else"
          (compiler-ir-instr-cons
            (IrInstrBinOp 4 (IrBinAdd) (IrValueVar 1) (IrValueVar 2) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 4)))
              (IrInstrNil))))
        (IrBlockNil)))))

(define (opt-gvn-phi-loop-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "loop"
        (compiler-ir-instr-cons
          (IrInstrPhi
            5
            (compiler-ir-phi-input-cons
              (IrValueVar 1)
              "entry"
              (compiler-ir-phi-input-cons (IrValueVar 4) "body" (IrPhiInputNil)))
            (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBinOp 3 (IrBinAdd) (IrValueVar 5) (IrValueVar 2) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrBranch (IrValueVar 0) "body" "exit")
              (IrInstrNil)))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "body"
          (compiler-ir-instr-cons
            (IrInstrBinOp 4 (IrBinAdd) (IrValueVar 5) (IrValueVar 2) (AstTyI64))
            (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "exit"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 3)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-gvn-load-barrier-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrLoad 3 (IrValueVar 1) (AstTyI64))
        (compiler-ir-instr-cons (IrInstrJump "use") (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "use"
        (compiler-ir-instr-cons
          (IrInstrLoad 4 (IrValueVar 1) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 4)))
            (IrInstrNil))))
      (IrBlockNil))))

(define (opt-gvn-load-join-safe-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrLoad 3 (IrValueVar 1) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrBranch (IrValueVar 0) "then" "else")
          (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "then"
        (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "else"
          (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "join"
            (compiler-ir-instr-cons
              (IrInstrLoad 4 (IrValueVar 1) (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 4)))
                (IrInstrNil))))
          (IrBlockNil))))))

(define (opt-gvn-load-store-path-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrLoad 3 (IrValueVar 1) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrBranch (IrValueVar 0) "then" "else")
          (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "then"
        (compiler-ir-instr-cons
          (IrInstrStorePtr (IrValueVar 1) (IrValueI64 9) (AstTyI64))
          (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "else"
          (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "join"
            (compiler-ir-instr-cons
              (IrInstrLoad 4 (IrValueVar 1) (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 4)))
                (IrInstrNil))))
          (IrBlockNil))))))

(define (opt-gvn-load-call-path-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrLoad 3 (IrValueVar 1) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrBranch (IrValueVar 0) "then" "else")
          (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "then"
        (compiler-ir-instr-cons
          (IrInstrCall 9 "touch" (IrCallArgsNil) (AstTyI64))
          (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "else"
          (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "join"
            (compiler-ir-instr-cons
              (IrInstrLoad 4 (IrValueVar 1) (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 4)))
                (IrInstrNil))))
          (IrBlockNil))))))

(define (opt-gvn-load-address-redef-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrLoad 3 (IrValueVar 1) (AstTyI64))
        (compiler-ir-instr-cons (IrInstrJump "use") (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "use"
        (compiler-ir-instr-cons
          (IrInstrMov 1 (IrValueI64 7) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrLoad 4 (IrValueVar 1) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 4)))
              (IrInstrNil)))))
      (IrBlockNil))))

(define (opt-gvn-load-type-mismatch-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrLoad 3 (IrValueVar 1) (AstTyI64))
        (compiler-ir-instr-cons (IrInstrJump "use") (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "use"
        (compiler-ir-instr-cons
          (IrInstrLoad 4 (IrValueVar 1) (AstTyBool))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 4)))
            (IrInstrNil))))
      (IrBlockNil))))

(define (opt-gvn-copy-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrMov 3 (IrValueVar 1) (AstTyI64))
        (compiler-ir-instr-cons (IrInstrJump "use") (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "use"
        (compiler-ir-instr-cons
          (IrInstrBinOp 4 (IrBinAdd) (IrValueVar 3) (IrValueI64 1) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 4)))
            (IrInstrNil))))
      (IrBlockNil))))

(define (opt-gvn-cast-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrCast 3 (IrValueVar 1) (AstTyI64) (AstTyI32))
        (compiler-ir-instr-cons (IrInstrJump "use") (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "use"
        (compiler-ir-instr-cons
          (IrInstrCast 4 (IrValueVar 1) (AstTyI64) (AstTyI32))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 4)))
            (IrInstrNil))))
      (IrBlockNil))))

(define (opt-gvn-gep-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrGep 3 (IrValueVar 1) (IrValueI64 8) (AstTyU8))
        (compiler-ir-instr-cons (IrInstrJump "use") (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "use"
        (compiler-ir-instr-cons
          (IrInstrGep 4 (IrValueVar 1) (IrValueI64 8) (AstTyU8))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 4)))
            (IrInstrNil))))
      (IrBlockNil))))

(define (opt-global-expr-hash-collision-guard-ok?) : bool
  (let
    [key : OptGlobalExprKey
      (OptGlobalBinKey (IrBinAdd) (IrValueVar 1) (IrValueVar 2) (AstTyI64))]
    [other-key : OptGlobalExprKey
      (OptGlobalBinKey (IrBinSub) (IrValueVar 1) (IrValueVar 2) (AstTyI64))]
    [buckets : (Array OptGlobalExprFacts) (make-array OptGlobalExprFacts 1)]
    [table : OptGlobalExprFactTable (OptGlobalExprFactTable buckets)]
    [doms : OptDomInfo
      (opt-cfg-dominators
        (compiler-ir-block-cons
          (compiler-ir-block "entry" (IrInstrNil))
          (IrBlockNil)))]
    (begin
      (array-set!
        buckets
        0
        (OptGlobalExprCons
          (OptGlobalExprFact key 7 0 1)
          (box (OptGlobalExprNil))))
      (and
        (match (opt-global-expr-lookup table key 8 doms 0 2)
          [(IrSomeValue value)
            (match value
              [(IrValueVar id) (= id 7)]
              [_ false])]
          [(IrNoValue) false])
        (match (opt-global-expr-lookup table other-key 8 doms 0 2)
          [(IrNoValue) true]
          [(IrSomeValue _) false])))))

(define (opt-gvn-hash-collision-guard-ok?) : bool
  (let
    [key : OptExprKey (OptBinKey (IrBinAdd) (IrValueVar 1) (IrValueVar 2))]
    [other-key : OptExprKey
      (OptBinKey (IrBinSub) (IrValueVar 1) (IrValueVar 2))]
    [buckets : (Array OptGvnBucket) (make-array OptGvnBucket 1)]
    [table : OptGvnMap (OptGvnMap buckets)]
    (begin
      (array-set! buckets 0 (OptGvnBucketNil))
      (opt-gvn-table-insert! table (OptGvnEntry key 7 0))
      (and
        (= (opt-gvn-lookup table key) 7)
        (= (opt-gvn-lookup table other-key) (- 0 1))))))

(define (opt-gvn-nearest-scope-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBinOp 3 (IrBinAdd) (IrValueVar 1) (IrValueVar 2) (AstTyI64))
        (compiler-ir-instr-cons (IrInstrJump "mid") (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "mid"
        (compiler-ir-instr-cons
          (IrInstrBinOp 4 (IrBinAdd) (IrValueVar 1) (IrValueVar 2) (AstTyI64))
          (compiler-ir-instr-cons (IrInstrJump "use") (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "use"
          (compiler-ir-instr-cons
            (IrInstrBinOp 5 (IrBinAdd) (IrValueVar 1) (IrValueVar 2) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 5)))
              (IrInstrNil))))
        (IrBlockNil)))))

(define (opt-gvn-scoped-nearest-dominator-ok?) : bool
  (let
    [out : CompilerIrBlockList
      (opt-gvn-blocks (opt-gvn-scalar-params) (opt-gvn-nearest-scope-blocks))]
    (and
      (= (opt-blocks-mov-src-var out 4 (- 0 1)) 3)
      (= (opt-blocks-mov-src-var out 5 (- 0 1)) 4))))

(define (compiler-optimize-global-value-number-self-test) : i64
  (let
    [dominated : CompilerIrBlockList
      (opt-function-blocks
        (optimize-function
          (opt-gvn-function
            "gvn_dominated"
            (opt-gvn-scalar-params)
            (AstTyI64)
            (opt-gvn-dominated-diamond-blocks))))]
    [sibling : CompilerIrBlockList
      (opt-function-blocks
        (optimize-function
          (opt-gvn-function
            "gvn_sibling"
            (opt-gvn-scalar-params)
            (AstTyI64)
            (opt-gvn-sibling-blocks))))]
    [loop : CompilerIrBlockList
      (opt-function-blocks
        (optimize-function
          (opt-gvn-function
            "gvn_loop"
            (opt-gvn-scalar-params)
            (AstTyI64)
            (opt-gvn-phi-loop-blocks))))]
    [load-safe : CompilerIrBlockList
      (opt-gvn-blocks (opt-gvn-pointer-params) (opt-gvn-load-barrier-blocks))]
    [load-join-safe : CompilerIrBlockList
      (opt-gvn-blocks
        (opt-gvn-pointer-cond-params)
        (opt-gvn-load-join-safe-blocks))]
    [load-store-path : CompilerIrBlockList
      (opt-gvn-blocks
        (opt-gvn-pointer-cond-params)
        (opt-gvn-load-store-path-blocks))]
    [load-call-path : CompilerIrBlockList
      (opt-gvn-blocks
        (opt-gvn-pointer-cond-params)
        (opt-gvn-load-call-path-blocks))]
    [load-address-redef : CompilerIrBlockList
      (opt-gvn-blocks
        (opt-gvn-pointer-params)
        (opt-gvn-load-address-redef-blocks))]
    [load-type-mismatch : CompilerIrBlockList
      (opt-gvn-blocks
        (opt-gvn-pointer-params)
        (opt-gvn-load-type-mismatch-blocks))]
    [copy : CompilerIrBlockList
      (opt-function-blocks
        (optimize-function
          (opt-gvn-function
            "gvn_copy"
            (opt-gvn-pointer-params)
            (AstTyI64)
            (opt-gvn-copy-blocks))))]
    [cast : CompilerIrBlockList
      (opt-function-blocks
        (optimize-function
          (opt-gvn-function
            "gvn_cast"
            (opt-gvn-pointer-params)
            (AstTyI32)
            (opt-gvn-cast-blocks))))]
    [gep : CompilerIrBlockList
      (opt-function-blocks
        (optimize-function
          (opt-gvn-function
            "gvn_gep"
            (opt-gvn-pointer-params)
            (AstTyU8)
            (opt-gvn-gep-blocks))))]
    (core/cond
      (not (= (opt-count-arith-blocks dominated) 1))
      1
      (not (= (opt-blocks-mov-src-var dominated 4 (- 0 1)) 3))
      2
      (not (= (opt-blocks-mov-src-var dominated 5 (- 0 1)) 3))
      3
      (not (= (opt-count-arith-blocks sibling) 2))
      4
      (not (= (opt-count-arith-blocks loop) 1))
      5
      (not (= (opt-blocks-mov-src-var loop 4 (- 0 1)) 3))
      6
      (not (= (opt-count-load-blocks load-safe) 1))
      7
      (not (= (opt-blocks-mov-src-var load-safe 4 (- 0 1)) 3))
      8
      (not (= (opt-count-load-blocks load-join-safe) 1))
      9
      (not (= (opt-blocks-mov-src-var load-join-safe 4 (- 0 1)) 3))
      10
      (not (= (opt-count-load-blocks load-store-path) 2))
      11
      (not (= (opt-blocks-mov-src-var load-store-path 4 (- 0 1)) (- 0 1)))
      12
      (not (= (opt-count-load-blocks load-call-path) 2))
      13
      (not (= (opt-blocks-mov-src-var load-call-path 4 (- 0 1)) (- 0 1)))
      14
      (not (= (opt-count-load-blocks load-address-redef) 2))
      15
      (not (= (opt-blocks-mov-src-var load-address-redef 4 (- 0 1)) (- 0 1)))
      16
      (not (= (opt-count-load-blocks load-type-mismatch) 2))
      17
      (not (= (opt-blocks-binop-lhs-var copy 4 (- 0 1)) 1))
      18
      (not (= (opt-count-mov-dst-blocks copy 3) 0))
      19
      (not (= (opt-count-cast-blocks cast) 1))
      20
      (not (= (opt-count-mov-dst-blocks cast 4) 0))
      21
      (not (= (opt-count-gep-blocks gep) 1))
      22
      (not (= (opt-count-mov-dst-blocks gep 4) 0))
      23
      (not (opt-global-expr-hash-collision-guard-ok?))
      24
      (not (opt-gvn-hash-collision-guard-ok?))
      25
      (not (opt-gvn-scoped-nearest-dominator-ok?))
      26
      42)))

(define (opt-sccp-cross-block-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrMov 0 (IrValueI64 20) (AstTyI64))
        (compiler-ir-instr-cons (IrInstrJump "rhs") (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "rhs"
        (compiler-ir-instr-cons
          (IrInstrBinOp 1 (IrBinAdd) (IrValueVar 0) (IrValueI64 22) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 1)))
            (IrInstrNil))))
      (IrBlockNil))))

(define (opt-sccp-diamond-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBranch (IrValueVar 0) "then" "else")
        (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "then"
        (compiler-ir-instr-cons
          (IrInstrMov 1 (IrValueI64 7) (AstTyI64))
          (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "else"
          (compiler-ir-instr-cons
            (IrInstrMov 2 (IrValueI64 7) (AstTyI64))
            (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "join"
            (compiler-ir-instr-cons
              (IrInstrPhi
                3
                (compiler-ir-phi-input-cons
                  (IrValueVar 1)
                  "then"
                  (compiler-ir-phi-input-cons
                    (IrValueVar 2)
                    "else"
                    (IrPhiInputNil)))
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 3)))
                (IrInstrNil))))
          (IrBlockNil))))))

(define (opt-sccp-constant-branch-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrMov 0 (IrValueBool true) (AstTyBool))
        (compiler-ir-instr-cons
          (IrInstrBranch (IrValueVar 0) "then" "else")
          (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "then"
        (compiler-ir-instr-cons
          (IrInstrReturn (IrSomeValue (IrValueI64 1)))
          (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "else"
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueI64 2)))
            (IrInstrNil)))
        (IrBlockNil)))))

(define (opt-sccp-loop-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrMov 0 (IrValueI64 0) (AstTyI64))
        (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "loop"
        (compiler-ir-instr-cons
          (IrInstrPhi
            1
            (compiler-ir-phi-input-cons
              (IrValueVar 0)
              "entry"
              (compiler-ir-phi-input-cons (IrValueVar 2) "body" (IrPhiInputNil)))
            (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBranch (IrValueVar 4) "body" "exit")
            (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "body"
          (compiler-ir-instr-cons
            (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 1) (IrValueI64 1) (AstTyI64))
            (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "exit"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 1)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-sccp-trap-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBinOp 1 (IrBinDiv) (IrValueI64 1) (IrValueI64 0) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrReturn (IrSomeValue (IrValueVar 1)))
          (IrInstrNil))))
    (IrBlockNil)))

(define (compiler-optimize-sccp-self-test) : i64
  (let
    [cross : CompilerIrBlockList
      (opt-sccp-blocks (IrParamNil) (opt-sccp-cross-block-blocks))]
    [diamond : CompilerIrBlockList
      (opt-sccp-blocks (opt-sccp-cond-params) (opt-sccp-diamond-blocks))]
    [branch : CompilerIrBlockList
      (opt-sccp-blocks (IrParamNil) (opt-sccp-constant-branch-blocks))]
    [loop : CompilerIrBlockList
      (opt-sccp-blocks (opt-sccp-loop-params) (opt-sccp-loop-blocks))]
    [trap : CompilerIrBlockList
      (opt-sccp-blocks (IrParamNil) (opt-sccp-trap-blocks))]
    (core/cond
      (not (= (opt-count-arith-blocks cross) 0))
      1
      (not (= (opt-blocks-mov-dst-i64-value cross 1 (- 0 999)) 42))
      2
      (not (= (opt-count-phi-blocks diamond) 0))
      3
      (not (= (opt-blocks-mov-dst-i64-value diamond 3 (- 0 999)) 7))
      4
      (not (= (compiler-ir-block-list-count branch) 2))
      5
      (opt-block-list-has-label? branch "else")
      6
      (not (= (opt-count-branches-blocks branch) 0))
      7
      (not (= (opt-count-jump-to-blocks branch "then") 1))
      8
      (not (= (compiler-ir-block-list-count loop) 4))
      9
      (not (= (opt-count-phi-blocks loop) 1))
      10
      (not (= (opt-count-mov-dst-blocks loop 1) 0))
      11
      (not (= (opt-count-arith-blocks loop) 1))
      12
      (not (= (opt-count-arith-blocks trap) 1))
      13
      (not (= (opt-count-mov-dst-blocks trap 1) 0))
      14
      42)))

(define (opt-cfg-constant-if-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBranch (IrValueBool true) "then" "else")
        (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "then"
        (compiler-ir-instr-cons
          (IrInstrReturn (IrSomeValue (IrValueI64 1)))
          (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "else"
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueI64 2)))
            (IrInstrNil)))
        (IrBlockNil)))))

(define (opt-cfg-loop-guard-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "loop"
        (compiler-ir-instr-cons
          (IrInstrBranch (IrValueBool false) "body" "exit")
          (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "body"
          (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "exit"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueI64 0)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-cfg-phi-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBranch (IrValueBool true) "then" "else")
        (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "then"
        (compiler-ir-instr-cons
          (IrInstrMov 1 (IrValueI64 10) (AstTyI64))
          (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "else"
          (compiler-ir-instr-cons
            (IrInstrMov 2 (IrValueI64 20) (AstTyI64))
            (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "join"
            (compiler-ir-instr-cons
              (IrInstrPhi
                3
                (compiler-ir-phi-input-cons
                  (IrValueVar 1)
                  "then"
                  (compiler-ir-phi-input-cons
                    (IrValueVar 2)
                    "else"
                    (IrPhiInputNil)))
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 3)))
                (IrInstrNil))))
          (IrBlockNil))))))

(define (opt-cfg-trap-path-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBranch (IrValueVar 0) "ok" "trap")
        (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "ok"
        (compiler-ir-instr-cons
          (IrInstrReturn (IrSomeValue (IrValueI64 0)))
          (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "trap"
          (compiler-ir-instr-cons
            (IrInstrCall 9 "panic" (IrCallArgsNil) (AstTyUnit))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueI64 1)))
              (IrInstrNil))))
        (IrBlockNil)))))

(define (opt-cfg-fallthrough-prune-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block "entry" (IrInstrNil))
    (compiler-ir-block-cons
      (compiler-ir-block "reachable-empty" (IrInstrNil))
      (compiler-ir-block-cons
        (compiler-ir-block
          "exit"
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueI64 1)))
            (IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block "dead-empty" (IrInstrNil))
          (compiler-ir-block-cons
            (compiler-ir-block
              "dead-exit"
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueI64 2)))
                (IrInstrNil)))
            (IrBlockNil)))))))

(define (opt-cfg-fallthrough-prune-ok? [blocks : CompilerIrBlockList]) : bool
  (and
    (= (compiler-ir-block-list-count blocks) 3)
    (and
      (opt-block-list-has-label? blocks "entry")
      (and
        (opt-block-list-has-label? blocks "reachable-empty")
        (and
          (opt-block-list-has-label? blocks "exit")
          (and
            (not (opt-block-list-has-label? blocks "dead-empty"))
            (and
              (not (opt-block-list-has-label? blocks "dead-exit"))
              (and
                (opt-cfg-successor-targets-known? blocks)
                (opt-verify-ok?
                  (opt-verify-function (opt-cfg-test-function blocks)))))))))))

(define (opt-ssa-cond-params) : CompilerIrParamList
  (compiler-ir-param-cons (IrParam "cond" (AstTyBool) 0) (IrParamNil)))

(define (opt-ssa-loop-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (IrParam "seed" (AstTyI64) 0)
    (compiler-ir-param-cons (IrParam "cond" (AstTyBool) 4) (IrParamNil))))

(define (opt-ssa-diamond-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBranch (IrValueVar 0) "then" "else")
        (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "then"
        (compiler-ir-instr-cons
          (IrInstrMov 1 (IrValueI64 10) (AstTyI64))
          (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "else"
          (compiler-ir-instr-cons
            (IrInstrMov 2 (IrValueI64 20) (AstTyI64))
            (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "join"
            (compiler-ir-instr-cons
              (IrInstrPhi
                3
                (compiler-ir-phi-input-cons
                  (IrValueVar 1)
                  "then"
                  (compiler-ir-phi-input-cons
                    (IrValueVar 2)
                    "else"
                    (IrPhiInputNil)))
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 3)))
                (IrInstrNil))))
          (IrBlockNil))))))

(define (opt-ssa-diamond-function) : CompilerIrFunction
  (IrFunction
    "ssa_diamond"
    (opt-ssa-cond-params)
    (AstTyI64)
    16
    (opt-ssa-diamond-blocks)))

(define (opt-ssa-loop-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "loop"
        (compiler-ir-instr-cons
          (IrInstrPhi
            1
            (compiler-ir-phi-input-cons
              (IrValueVar 0)
              "entry"
              (compiler-ir-phi-input-cons (IrValueVar 2) "body" (IrPhiInputNil)))
            (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBranch (IrValueVar 4) "body" "exit")
            (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "body"
          (compiler-ir-instr-cons
            (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 1) (IrValueI64 1) (AstTyI64))
            (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "exit"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 1)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-ssa-loop-function) : CompilerIrFunction
  (IrFunction
    "ssa_loop"
    (opt-ssa-loop-params)
    (AstTyI64)
    16
    (opt-ssa-loop-blocks)))

(define (opt-ssa-construct-diamond-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBranch (IrValueVar 0) "then" "else")
        (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "then"
        (compiler-ir-instr-cons
          (IrInstrMov 1 (IrValueI64 10) (AstTyI64))
          (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "else"
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueI64 20) (AstTyI64))
            (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "join"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 1)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-ssa-construct-diamond-function) : CompilerIrFunction
  (IrFunction
    "ssa_construct_diamond"
    (opt-ssa-cond-params)
    (AstTyI64)
    2
    (opt-ssa-construct-diamond-blocks)))

(define (opt-ssa-construct-loop-params) : CompilerIrParamList
  (compiler-ir-param-cons (IrParam "cond" (AstTyBool) 4) (IrParamNil)))

(define (opt-ssa-construct-loop-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrMov 1 (IrValueI64 0) (AstTyI64))
        (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "loop"
        (compiler-ir-instr-cons
          (IrInstrBranch (IrValueVar 4) "body" "exit")
          (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "body"
          (compiler-ir-instr-cons
            (IrInstrBinOp 1 (IrBinAdd) (IrValueVar 1) (IrValueI64 1) (AstTyI64))
            (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "exit"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 1)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-ssa-construct-loop-function) : CompilerIrFunction
  (IrFunction
    "ssa_construct_loop"
    (opt-ssa-construct-loop-params)
    (AstTyI64)
    5
    (opt-ssa-construct-loop-blocks)))

(define (opt-ssa-construct-mutated-param-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (IrParam "value" (AstTyI64) 0)
    (compiler-ir-param-cons (IrParam "cond" (AstTyBool) 1) (IrParamNil))))

(define (opt-ssa-construct-mutated-param-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBranch (IrValueVar 1) "then" "else")
        (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "then"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 10) (AstTyI64))
          (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "else"
          (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "join"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 0)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-ssa-construct-mutated-param-function) : CompilerIrFunction
  (IrFunction
    "ssa_construct_mutated_param"
    (opt-ssa-construct-mutated-param-params)
    (AstTyI64)
    2
    (opt-ssa-construct-mutated-param-blocks)))

(define (opt-ssa-construct-address-taken-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrMov 1 (IrValueI64 1) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrAddrOf 2 1)
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueI64 2) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 1)))
              (IrInstrNil))))))
    (IrBlockNil)))

(define (opt-ssa-construct-address-taken-function) : CompilerIrFunction
  (IrFunction
    "ssa_construct_address_taken"
    (IrParamNil)
    (AstTyI64)
    3
    (opt-ssa-construct-address-taken-blocks)))

(define (opt-natural-loop-nested-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons (IrInstrJump "outer") (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "outer"
        (compiler-ir-instr-cons (IrInstrJump "inner") (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "inner"
          (compiler-ir-instr-cons
            (IrInstrBranch (IrValueVar 4) "inner-body" "outer-latch")
            (IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "inner-body"
            (compiler-ir-instr-cons (IrInstrJump "inner") (IrInstrNil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              "outer-latch"
              (compiler-ir-instr-cons
                (IrInstrBranch (IrValueVar 8) "outer" "exit")
                (IrInstrNil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                "exit"
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueI64 0)))
                  (IrInstrNil)))
              (IrBlockNil))))))))

(define (opt-natural-loop-irreducible-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBranch (IrValueBool true) "left" "right")
        (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "left"
        (compiler-ir-instr-cons (IrInstrJump "right") (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "right"
          (compiler-ir-instr-cons
            (IrInstrBranch (IrValueBool true) "left" "exit")
            (IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "exit"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueI64 0)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-natural-loop-no-preheader-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBranch (IrValueBool true) "pre-one" "pre-two")
        (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "pre-one"
        (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "pre-two"
          (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "loop"
            (compiler-ir-instr-cons
              (IrInstrBranch (IrValueBool true) "body" "exit")
              (IrInstrNil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              "body"
              (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                "exit"
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueI64 0)))
                  (IrInstrNil)))
              (IrBlockNil))))))))

(define (opt-natural-loop-multi-backedge-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "loop"
        (compiler-ir-instr-cons
          (IrInstrBranch (IrValueBool true) "left" "right")
          (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "left"
          (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "right"
            (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-natural-loop-maybe-body-count [maybe : OptMaybeNaturalLoop]) : i64
  (match maybe
    [(OptNoNaturalLoop) 0]
    [(OptSomeNaturalLoop loop) (opt-label-count (opt-natural-loop-body loop))]))

(define (opt-natural-loop-maybe-body-block-count [maybe : OptMaybeNaturalLoop]) : i64
  (match maybe
    [(OptNoNaturalLoop) 0]
    [(OptSomeNaturalLoop loop)
      (compiler-ir-block-list-count (opt-natural-loop-body-blocks loop))]))

(define (opt-natural-loop-maybe-body-contains?
  [maybe : OptMaybeNaturalLoop]
  [label : String]) : bool
  (match maybe
    [(OptNoNaturalLoop) false]
    [(OptSomeNaturalLoop loop)
      (opt-label-contains (opt-natural-loop-body loop) label)]))

(define (opt-natural-loop-maybe-body-contains-id?
  [index : OptCfgIndex]
  [maybe : OptMaybeNaturalLoop]
  [label : String]) : bool
  (match maybe
    [(OptNoNaturalLoop) false]
    [(OptSomeNaturalLoop loop)
      (match (opt-cfg-index-id index label)
        [(OptSomeI64 id) (opt-natural-loop-body-contains-id? loop id)]
        [(OptNoI64) false])]))

(define (opt-natural-loop-maybe-body-block-label-at?
  [maybe : OptMaybeNaturalLoop]
  [index : i64]
  [label : String]) : bool
  (match maybe
    [(OptNoNaturalLoop) false]
    [(OptSomeNaturalLoop loop)
      (opt-block-list-label-at? (opt-natural-loop-body-blocks loop) index label)]))

(define (opt-natural-loop-maybe-preheader-label?
  [maybe : OptMaybeNaturalLoop]
  [label : String]) : bool
  (match maybe
    [(OptNoNaturalLoop) false]
    [(OptSomeNaturalLoop loop)
      (match (opt-natural-loop-preheader loop)
        [(OptSomeLoopPreheader actual) (string-eq actual label)]
        [(OptNoLoopPreheader) false])]))

(define (opt-natural-loop-maybe-no-preheader? [maybe : OptMaybeNaturalLoop]) : bool
  (match maybe
    [(OptNoNaturalLoop) false]
    [(OptSomeNaturalLoop loop)
      (match (opt-natural-loop-preheader loop)
        [(OptNoLoopPreheader) true]
        [(OptSomeLoopPreheader _) false])]))

(define (opt-licm-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (IrParam "cond" (AstTyBool) 0)
    (compiler-ir-param-cons
      (IrParam "lhs" (AstTyI64) 1)
      (compiler-ir-param-cons (IrParam "rhs" (AstTyI64) 2) (IrParamNil)))))

(define (opt-licm-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (IrFunction "licm" (opt-licm-params) (AstTyI64) 16 blocks))

(define (opt-licm-optimized-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (opt-licm-function (opt-licm-test-function blocks)))

(define (opt-licm-arithmetic-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrMov 3 (IrValueI64 0) (AstTyI64))
        (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil))))
    (compiler-ir-block-cons
      (compiler-ir-block
        "loop"
        (compiler-ir-instr-cons
          (IrInstrPhi
            4
            (compiler-ir-phi-input-cons
              (IrValueVar 3)
              "entry"
              (compiler-ir-phi-input-cons (IrValueVar 5) "body" IrPhiInputNil))
            (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBinOp
              10
              (IrBinAdd)
              (IrValueVar 1)
              (IrValueVar 2)
              (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrBinOp
                11
                (IrBinMul)
                (IrValueVar 10)
                (IrValueI64 2)
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrBranch (IrValueVar 0) "body" "exit")
                (IrInstrNil))))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "body"
          (compiler-ir-instr-cons
            (IrInstrBinOp 5 (IrBinAdd) (IrValueVar 4) (IrValueI64 1) (AstTyI64))
            (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "exit"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 11)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-licm-trap-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "loop"
        (compiler-ir-instr-cons
          (IrInstrBinOp 10 (IrBinDiv) (IrValueVar 1) (IrValueVar 2) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBranch (IrValueVar 0) "body" "exit")
            (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "body"
          (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "exit"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 10)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-licm-call-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "loop"
        (compiler-ir-instr-cons
          (IrInstrCall 8 "tl_noop" (IrCallArgsNil) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBinOp
              10
              (IrBinAdd)
              (IrValueVar 8)
              (IrValueVar 1)
              (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrBranch (IrValueVar 0) "body" "exit")
              (IrInstrNil)))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "body"
          (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "exit"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 10)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-licm-no-preheader-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBranch (IrValueVar 0) "pre-one" "pre-two")
        (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "pre-one"
        (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "pre-two"
          (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "loop"
            (compiler-ir-instr-cons
              (IrInstrBinOp
                10
                (IrBinAdd)
                (IrValueVar 1)
                (IrValueVar 2)
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrBranch (IrValueVar 0) "body" "exit")
                (IrInstrNil))))
          (compiler-ir-block-cons
            (compiler-ir-block
              "body"
              (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                "exit"
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 10)))
                  (IrInstrNil)))
              (IrBlockNil))))))))

(define (opt-licm-nested-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons (IrInstrJump "outer") (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "outer"
        (compiler-ir-instr-cons (IrInstrJump "inner") (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "inner"
          (compiler-ir-instr-cons
            (IrInstrBinOp
              10
              (IrBinAdd)
              (IrValueVar 1)
              (IrValueVar 2)
              (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrBranch (IrValueVar 0) "inner-body" "outer-latch")
              (IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "inner-body"
            (compiler-ir-instr-cons (IrInstrJump "inner") (IrInstrNil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              "outer-latch"
              (compiler-ir-instr-cons
                (IrInstrBranch (IrValueVar 0) "outer" "exit")
                (IrInstrNil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                "exit"
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 10)))
                  (IrInstrNil)))
              (IrBlockNil))))))))

(define (compiler-optimize-licm-self-test) : i64
  (let
    [arith-func : CompilerIrFunction
      (opt-licm-optimized-function (opt-licm-arithmetic-blocks))]
    [arith : CompilerIrBlockList (opt-function-blocks arith-func)]
    [trap-func : CompilerIrFunction
      (opt-licm-optimized-function (opt-licm-trap-blocks))]
    [trap : CompilerIrBlockList (opt-function-blocks trap-func)]
    [call-func : CompilerIrFunction
      (opt-licm-optimized-function (opt-licm-call-blocks))]
    [call-blocks : CompilerIrBlockList (opt-function-blocks call-func)]
    [no-preheader-func : CompilerIrFunction
      (opt-licm-optimized-function (opt-licm-no-preheader-blocks))]
    [no-preheader : CompilerIrBlockList (opt-function-blocks no-preheader-func)]
    [nested-func : CompilerIrFunction
      (opt-licm-optimized-function (opt-licm-nested-blocks))]
    [nested : CompilerIrBlockList (opt-function-blocks nested-func)]
    (core/cond
      (not (opt-verify-ok? (opt-verify-function arith-func)))
      1
      (not (= (opt-count-arith-label-blocks arith "entry") 2))
      2
      (not (= (opt-count-arith-label-blocks arith "loop") 0))
      3
      (not (= (opt-count-arith-label-blocks arith "body") 1))
      4
      (not (opt-verify-ok? (opt-verify-function trap-func)))
      5
      (not (= (opt-count-arith-label-blocks trap "loop") 1))
      6
      (not (opt-verify-ok? (opt-verify-function call-func)))
      7
      (not (= (opt-count-arith-label-blocks call-blocks "loop") 1))
      8
      (not (opt-verify-ok? (opt-verify-function no-preheader-func)))
      9
      (not (= (opt-count-arith-label-blocks no-preheader "loop") 1))
      10
      (not (= (opt-count-arith-blocks no-preheader) 1))
      11
      (not (opt-verify-ok? (opt-verify-function nested-func)))
      12
      (not (= (opt-count-arith-label-blocks nested "inner") 0))
      13
      (not (= (opt-count-arith-blocks nested) 1))
      14
      42)))

(define (opt-induction-params) : CompilerIrParamList
  (compiler-ir-param-cons
    (IrParam "cond" (AstTyBool) 0)
    (compiler-ir-param-cons
      (IrParam "seed" (AstTyI64) 1)
      (compiler-ir-param-cons (IrParam "ptr" (AstTyI64) 2) (IrParamNil)))))

(define (opt-induction-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (IrFunction "induction" (opt-induction-params) (AstTyI64) 32 blocks))

(define (opt-induction-optimized-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (opt-induction-function (opt-induction-test-function blocks)))

(define (opt-induction-offset-blocks [step : i64] [scale : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "loop"
        (compiler-ir-instr-cons
          (IrInstrPhi
            3
            (compiler-ir-phi-input-cons
              (IrValueVar 1)
              "entry"
              (compiler-ir-phi-input-cons (IrValueVar 5) "body" (IrPhiInputNil)))
            (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBranch (IrValueVar 0) "body" "exit")
            (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "body"
          (compiler-ir-instr-cons
            (IrInstrBinOp
              4
              (IrBinMul)
              (IrValueVar 3)
              (IrValueI64 scale)
              (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrBinOp
                6
                (IrBinAdd)
                (IrValueVar 4)
                (IrValueI64 7)
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrBinOp
                  5
                  (IrBinAdd)
                  (IrValueVar 3)
                  (IrValueI64 step)
                  (AstTyI64))
                (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "exit"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 3)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-induction-gep-blocks [step : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "loop"
        (compiler-ir-instr-cons
          (IrInstrPhi
            3
            (compiler-ir-phi-input-cons
              (IrValueVar 1)
              "entry"
              (compiler-ir-phi-input-cons (IrValueVar 5) "body" (IrPhiInputNil)))
            (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBranch (IrValueVar 0) "body" "exit")
            (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "body"
          (compiler-ir-instr-cons
            (IrInstrGep 4 (IrValueVar 2) (IrValueVar 3) (AstTyU8))
            (compiler-ir-instr-cons
              (IrInstrLoad 6 (IrValueVar 4) (AstTyU8))
              (compiler-ir-instr-cons
                (IrInstrBinOp
                  5
                  (IrBinAdd)
                  (IrValueVar 3)
                  (IrValueI64 step)
                  (AstTyI64))
                (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "exit"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 3)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-induction-unsupported-step-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "loop"
        (compiler-ir-instr-cons
          (IrInstrPhi
            3
            (compiler-ir-phi-input-cons
              (IrValueVar 1)
              "entry"
              (compiler-ir-phi-input-cons (IrValueVar 5) "body" (IrPhiInputNil)))
            (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBranch (IrValueVar 0) "body" "exit")
            (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "body"
          (compiler-ir-instr-cons
            (IrInstrBinOp 4 (IrBinMul) (IrValueVar 3) (IrValueI64 4) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrBinOp
                6
                (IrBinAdd)
                (IrValueVar 4)
                (IrValueI64 7)
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrBinOp
                  5
                  (IrBinMul)
                  (IrValueVar 3)
                  (IrValueI64 2)
                  (AstTyI64))
                (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "exit"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 3)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-induction-call-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "loop"
        (compiler-ir-instr-cons
          (IrInstrPhi
            3
            (compiler-ir-phi-input-cons
              (IrValueVar 1)
              "entry"
              (compiler-ir-phi-input-cons (IrValueVar 5) "body" (IrPhiInputNil)))
            (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBranch (IrValueVar 0) "body" "exit")
            (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "body"
          (compiler-ir-instr-cons
            (IrInstrBinOp 4 (IrBinMul) (IrValueVar 3) (IrValueI64 4) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrCall 7 "tl_noop" (IrCallArgsNil) (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrBinOp
                  6
                  (IrBinAdd)
                  (IrValueVar 4)
                  (IrValueI64 7)
                  (AstTyI64))
                (compiler-ir-instr-cons
                  (IrInstrBinOp
                    5
                    (IrBinAdd)
                    (IrValueVar 3)
                    (IrValueI64 1)
                    (AstTyI64))
                  (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "exit"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 3)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-induction-store-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "loop"
        (compiler-ir-instr-cons
          (IrInstrPhi
            3
            (compiler-ir-phi-input-cons
              (IrValueVar 1)
              "entry"
              (compiler-ir-phi-input-cons (IrValueVar 5) "body" (IrPhiInputNil)))
            (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrBranch (IrValueVar 0) "body" "exit")
            (IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          "body"
          (compiler-ir-instr-cons
            (IrInstrBinOp 4 (IrBinMul) (IrValueVar 3) (IrValueI64 4) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrStore "sink" (IrValueVar 4) (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrBinOp
                  5
                  (IrBinAdd)
                  (IrValueVar 3)
                  (IrValueI64 1)
                  (AstTyI64))
                (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "exit"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 3)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-induction-no-preheader-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrBranch (IrValueVar 0) "pre-one" "pre-two")
        (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "pre-one"
        (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "pre-two"
          (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "loop"
            (compiler-ir-instr-cons
              (IrInstrPhi
                3
                (compiler-ir-phi-input-cons
                  (IrValueVar 1)
                  "pre-one"
                  (compiler-ir-phi-input-cons
                    (IrValueVar 1)
                    "pre-two"
                    (compiler-ir-phi-input-cons
                      (IrValueVar 5)
                      "body"
                      (IrPhiInputNil))))
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrBranch (IrValueVar 0) "body" "exit")
                (IrInstrNil))))
          (compiler-ir-block-cons
            (compiler-ir-block
              "body"
              (compiler-ir-instr-cons
                (IrInstrBinOp
                  4
                  (IrBinMul)
                  (IrValueVar 3)
                  (IrValueI64 4)
                  (AstTyI64))
                (compiler-ir-instr-cons
                  (IrInstrBinOp
                    6
                    (IrBinAdd)
                    (IrValueVar 4)
                    (IrValueI64 7)
                    (AstTyI64))
                  (compiler-ir-instr-cons
                    (IrInstrBinOp
                      5
                      (IrBinAdd)
                      (IrValueVar 3)
                      (IrValueI64 1)
                      (AstTyI64))
                    (compiler-ir-instr-cons (IrInstrJump "loop") (IrInstrNil))))))
            (compiler-ir-block-cons
              (compiler-ir-block
                "exit"
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 3)))
                  (IrInstrNil)))
              (IrBlockNil))))))))

(define (compiler-optimize-induction-self-test) : i64
  (let
    [blocks : CompilerIrBlockList (opt-induction-offset-blocks 1 4)]
    [func : CompilerIrFunction (opt-induction-optimized-function blocks)]
    [out : CompilerIrBlockList (opt-function-blocks func)]
    [nonunit-func : CompilerIrFunction
      (opt-induction-optimized-function (opt-induction-offset-blocks 3 4))]
    [nonunit : CompilerIrBlockList (opt-function-blocks nonunit-func)]
    [negative-func : CompilerIrFunction
      (opt-induction-optimized-function (opt-induction-offset-blocks (- 0 2) 4))]
    [negative : CompilerIrBlockList (opt-function-blocks negative-func)]
    [gep-func : CompilerIrFunction
      (opt-induction-optimized-function (opt-induction-gep-blocks 1))]
    [gep : CompilerIrBlockList (opt-function-blocks gep-func)]
    [unsupported-func : CompilerIrFunction
      (opt-induction-optimized-function (opt-induction-unsupported-step-blocks))]
    [unsupported : CompilerIrBlockList (opt-function-blocks unsupported-func)]
    [call-func : CompilerIrFunction
      (opt-induction-optimized-function (opt-induction-call-blocks))]
    [call-blocks : CompilerIrBlockList (opt-function-blocks call-func)]
    [store-func : CompilerIrFunction
      (opt-induction-optimized-function (opt-induction-store-blocks))]
    [store-blocks : CompilerIrBlockList (opt-function-blocks store-func)]
    [no-preheader-func : CompilerIrFunction
      (opt-induction-optimized-function (opt-induction-no-preheader-blocks))]
    [no-preheader : CompilerIrBlockList (opt-function-blocks no-preheader-func)]
    (core/cond
      (not (opt-verify-ok? (opt-verify-function func)))
      1
      (not (= (opt-count-phi-blocks out) 2))
      2
      (not (= (opt-blocks-mov-src-var out 4 (- 0 1)) 33))
      3
      (not (= (opt-count-mul-label-blocks out "body") 0))
      4
      (not (opt-verify-ok? (opt-verify-function nonunit-func)))
      5
      (not (= (opt-blocks-mov-src-var nonunit 4 (- 0 1)) 33))
      6
      (not (= (opt-count-mul-label-blocks nonunit "body") 0))
      7
      (not (opt-verify-ok? (opt-verify-function negative-func)))
      8
      (not (= (opt-blocks-mov-src-var negative 4 (- 0 1)) 33))
      9
      (not (= (opt-count-mul-label-blocks negative "body") 0))
      10
      (not (opt-verify-ok? (opt-verify-function gep-func)))
      11
      (not (= (opt-count-gep-label-blocks gep "body") 1))
      12
      (not (= (opt-blocks-mov-src-var gep 4 (- 0 1)) 33))
      13
      (not (opt-verify-ok? (opt-verify-function unsupported-func)))
      14
      (not (= (opt-blocks-mov-src-var unsupported 4 (- 0 1)) (- 0 1)))
      15
      (not (= (opt-count-mul-label-blocks unsupported "body") 2))
      16
      (not (opt-verify-ok? (opt-verify-function call-func)))
      17
      (not (= (opt-blocks-mov-src-var call-blocks 4 (- 0 1)) (- 0 1)))
      18
      (not (= (opt-count-mul-label-blocks call-blocks "body") 1))
      19
      (not (opt-verify-ok? (opt-verify-function store-func)))
      20
      (not (= (opt-blocks-mov-src-var store-blocks 4 (- 0 1)) (- 0 1)))
      21
      (not (= (opt-count-mul-label-blocks store-blocks "body") 1))
      22
      (not (opt-verify-ok? (opt-verify-function no-preheader-func)))
      23
      (not (= (opt-count-phi-blocks no-preheader) 1))
      24
      (not (= (opt-count-mul-label-blocks no-preheader "body") 1))
      25
      42)))

(define (opt-ssa-unreachable-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (compiler-ir-block
      "entry"
      (compiler-ir-instr-cons
        (IrInstrReturn (IrSomeValue (IrValueI64 1)))
        (IrInstrNil)))
    (compiler-ir-block-cons
      (compiler-ir-block
        "dead"
        (compiler-ir-instr-cons
          (IrInstrReturn (IrSomeValue (IrValueI64 2)))
          (IrInstrNil)))
      (IrBlockNil))))

(define (opt-ssa-unreachable-function) : CompilerIrFunction
  (IrFunction
    "ssa_unreachable"
    (IrParamNil)
    (AstTyI64)
    0
    (opt-ssa-unreachable-blocks)))

(define (opt-ssa-bad-phi-function) : CompilerIrFunction
  (IrFunction
    "ssa_bad_phi"
    (opt-ssa-cond-params)
    (AstTyI64)
    16
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrBranch (IrValueVar 0) "then" "else")
          (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "then"
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueI64 10) (AstTyI64))
            (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "else"
            (compiler-ir-instr-cons
              (IrInstrMov 2 (IrValueI64 20) (AstTyI64))
              (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil))))
          (compiler-ir-block-cons
            (compiler-ir-block
              "join"
              (compiler-ir-instr-cons
                (IrInstrPhi
                  3
                  (compiler-ir-phi-input-cons
                    (IrValueVar 1)
                    "then"
                    (compiler-ir-phi-input-cons
                      (IrValueVar 2)
                      "ghost"
                      (IrPhiInputNil)))
                  (AstTyI64))
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 3)))
                  (IrInstrNil))))
            (IrBlockNil)))))))

(define (opt-ssa-duplicate-label-function) : CompilerIrFunction
  (IrFunction
    "ssa_duplicate_label"
    (IrParamNil)
    (AstTyI64)
    0
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrReturn (IrSomeValue (IrValueI64 1)))
          (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueI64 2)))
            (IrInstrNil)))
        (IrBlockNil)))))

(define (opt-ssa-unknown-successor-function) : CompilerIrFunction
  (IrFunction
    "ssa_unknown_successor"
    (IrParamNil)
    (AstTyI64)
    0
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons (IrInstrJump "missing") (IrInstrNil)))
      (IrBlockNil))))

(define (opt-ssa-duplicate-def-function) : CompilerIrFunction
  (IrFunction
    "ssa_duplicate_def"
    (IrParamNil)
    (AstTyI64)
    0
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 1 (IrValueI64 1) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueI64 2) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 1)))
              (IrInstrNil)))))
      (IrBlockNil))))

(define (opt-ssa-use-before-def-function) : CompilerIrFunction
  (IrFunction
    "ssa_use_before_def"
    (IrParamNil)
    (AstTyI64)
    0
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrReturn (IrSomeValue (IrValueVar 9)))
          (IrInstrNil)))
      (IrBlockNil))))

(define (opt-ssa-dominance-fail-function) : CompilerIrFunction
  (IrFunction
    "ssa_dominance_fail"
    (opt-ssa-cond-params)
    (AstTyI64)
    16
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrBranch (IrValueVar 0) "then" "else")
          (IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "then"
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueI64 10) (AstTyI64))
            (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "else"
            (compiler-ir-instr-cons (IrInstrJump "join") (IrInstrNil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              "join"
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 1)))
                (IrInstrNil)))
            (IrBlockNil)))))))

(define (compiler-optimize-natural-loop-self-test) : i64
  (let
    [single-index : OptCfgIndex (opt-cfg-index-build (opt-ssa-loop-blocks))]
    [single-loops : OptNaturalLoopList
      (opt-cfg-natural-loops (opt-ssa-loop-blocks))]
    [single : OptMaybeNaturalLoop
      (opt-natural-loop-find single-loops "loop" "body")]
    [nested-index : OptCfgIndex
      (opt-cfg-index-build (opt-natural-loop-nested-blocks))]
    [nested-loops : OptNaturalLoopList
      (opt-cfg-natural-loops (opt-natural-loop-nested-blocks))]
    [inner : OptMaybeNaturalLoop
      (opt-natural-loop-find nested-loops "inner" "inner-body")]
    [outer : OptMaybeNaturalLoop
      (opt-natural-loop-find nested-loops "outer" "outer-latch")]
    [diamond-loops : OptNaturalLoopList
      (opt-cfg-natural-loops (opt-ssa-diamond-blocks))]
    [irreducible-loops : OptNaturalLoopList
      (opt-cfg-natural-loops (opt-natural-loop-irreducible-blocks))]
    [no-preheader-loops : OptNaturalLoopList
      (opt-cfg-natural-loops (opt-natural-loop-no-preheader-blocks))]
    [no-preheader : OptMaybeNaturalLoop
      (opt-natural-loop-find no-preheader-loops "loop" "body")]
    [multi-index : OptCfgIndex
      (opt-cfg-index-build (opt-natural-loop-multi-backedge-blocks))]
    [multi-loops : OptNaturalLoopList
      (opt-cfg-natural-loops (opt-natural-loop-multi-backedge-blocks))]
    [multi-left : OptMaybeNaturalLoop
      (opt-natural-loop-find multi-loops "loop" "left")]
    [multi-right : OptMaybeNaturalLoop
      (opt-natural-loop-find multi-loops "loop" "right")]
    [preheadered-single-blocks : CompilerIrBlockList
      (opt-loop-preheaders-blocks (opt-ssa-loop-blocks))]
    [preheadered-nested-blocks : CompilerIrBlockList
      (opt-loop-preheaders-blocks (opt-natural-loop-nested-blocks))]
    [preheadered-multi-blocks : CompilerIrBlockList
      (opt-loop-preheaders-blocks (opt-natural-loop-multi-backedge-blocks))]
    [synth-blocks : CompilerIrBlockList
      (opt-loop-preheaders-blocks (opt-natural-loop-no-preheader-blocks))]
    [synth-index : OptCfgIndex (opt-cfg-index-build synth-blocks)]
    [synth-loops : OptNaturalLoopList (opt-cfg-natural-loops synth-blocks)]
    [synth-loop : OptMaybeNaturalLoop
      (opt-natural-loop-find synth-loops "loop" "body")]
    [preheadered-induction : CompilerIrFunction
      (opt-loop-preheaders-function
        (opt-induction-test-function (opt-induction-no-preheader-blocks)))]
    [preheadered-induction-blocks : CompilerIrBlockList
      (opt-function-blocks preheadered-induction)]
    [induction-after-preheader : CompilerIrFunction
      (opt-induction-function preheadered-induction)]
    [induction-after-preheader-blocks : CompilerIrBlockList
      (opt-function-blocks induction-after-preheader)]
    (core/cond
      (not (= (opt-natural-loop-list-count single-loops) 1))
      1
      (not (= (opt-natural-loop-maybe-body-count single) 2))
      2
      (not (opt-natural-loop-maybe-body-contains? single "loop"))
      3
      (not (opt-natural-loop-maybe-body-contains? single "body"))
      4
      (not (opt-natural-loop-maybe-preheader-label? single "entry"))
      5
      (not (= (opt-natural-loop-list-count nested-loops) 2))
      6
      (not (= (opt-natural-loop-maybe-body-count inner) 2))
      7
      (not (opt-natural-loop-maybe-body-contains? inner "inner"))
      8
      (not (opt-natural-loop-maybe-body-contains? inner "inner-body"))
      9
      (not (opt-natural-loop-maybe-preheader-label? inner "outer"))
      10
      (not (= (opt-natural-loop-maybe-body-count outer) 4))
      11
      (not (opt-natural-loop-maybe-body-contains? outer "outer"))
      12
      (not (opt-natural-loop-maybe-body-contains? outer "inner"))
      13
      (not (opt-natural-loop-maybe-body-contains? outer "inner-body"))
      14
      (not (opt-natural-loop-maybe-body-contains? outer "outer-latch"))
      15
      (not (opt-natural-loop-maybe-preheader-label? outer "entry"))
      16
      (not (= (opt-natural-loop-list-count diamond-loops) 0))
      17
      (not (= (opt-natural-loop-list-count irreducible-loops) 0))
      18
      (not (= (opt-natural-loop-list-count no-preheader-loops) 1))
      19
      (not (= (opt-natural-loop-maybe-body-count no-preheader) 2))
      20
      (not (opt-natural-loop-maybe-no-preheader? no-preheader))
      21
      (not (= (opt-natural-loop-list-count multi-loops) 2))
      22
      (not (= (opt-natural-loop-maybe-body-count multi-left) 2))
      23
      (not (opt-natural-loop-maybe-body-contains? multi-left "left"))
      24
      (not (opt-natural-loop-maybe-body-contains? multi-left "loop"))
      25
      (not (= (opt-natural-loop-maybe-body-count multi-right) 2))
      26
      (not (opt-natural-loop-maybe-body-contains? multi-right "right"))
      27
      (not (opt-natural-loop-maybe-body-contains? multi-right "loop"))
      28
      (not (= (opt-natural-loop-maybe-body-block-count single) 2))
      29
      (not (opt-natural-loop-maybe-body-block-label-at? single 0 "loop"))
      30
      (not (opt-natural-loop-maybe-body-block-label-at? single 1 "body"))
      31
      (not
        (opt-natural-loop-maybe-body-contains-id? single-index single "loop"))
      32
      (not
        (opt-natural-loop-maybe-body-contains-id? single-index single "body"))
      33
      (opt-natural-loop-maybe-body-contains-id? single-index single "entry")
      34
      (not (= (opt-natural-loop-maybe-body-block-count outer) 4))
      35
      (not (opt-natural-loop-maybe-body-block-label-at? outer 0 "outer"))
      36
      (not (opt-natural-loop-maybe-body-block-label-at? outer 1 "inner"))
      37
      (not (opt-natural-loop-maybe-body-block-label-at? outer 2 "inner-body"))
      38
      (not (opt-natural-loop-maybe-body-block-label-at? outer 3 "outer-latch"))
      39
      (not
        (opt-natural-loop-maybe-body-contains-id?
          nested-index
          outer
          "outer-latch"))
      40
      (not (= (opt-natural-loop-maybe-body-block-count multi-left) 2))
      41
      (not (opt-natural-loop-maybe-body-block-label-at? multi-left 0 "loop"))
      43
      (not (opt-natural-loop-maybe-body-block-label-at? multi-left 1 "left"))
      44
      (not (= (opt-natural-loop-maybe-body-block-count multi-right) 2))
      45
      (not (opt-natural-loop-maybe-body-block-label-at? multi-right 0 "loop"))
      46
      (not (opt-natural-loop-maybe-body-block-label-at? multi-right 1 "right"))
      47
      (not
        (opt-natural-loop-maybe-body-contains-id?
          multi-index
          multi-right
          "right"))
      48
      (not (opt-block-list-eq preheadered-single-blocks (opt-ssa-loop-blocks)))
      49
      (not
        (opt-block-list-eq
          preheadered-nested-blocks
          (opt-natural-loop-nested-blocks)))
      50
      (not
        (opt-block-list-eq
          preheadered-multi-blocks
          (opt-natural-loop-multi-backedge-blocks)))
      51
      (not (= (compiler-ir-block-list-count synth-blocks) 7))
      52
      (not (opt-block-list-has-label? synth-blocks "loop__preheader"))
      53
      (not
        (opt-natural-loop-maybe-preheader-label? synth-loop "loop__preheader"))
      54
      (not
        (opt-label-contains
          (opt-cfg-index-successors synth-index "pre-one")
          "loop__preheader"))
      55
      (opt-label-contains
        (opt-cfg-index-successors synth-index "pre-one")
        "loop")
      56
      (not
        (opt-label-contains
          (opt-cfg-index-successors synth-index "loop__preheader")
          "loop"))
      57
      (not
        (opt-verify-ok?
          (opt-verify-function (opt-cfg-test-function synth-blocks))))
      58
      (not (opt-verify-ok? (opt-verify-function preheadered-induction)))
      59
      (not
        (opt-block-list-has-label?
          preheadered-induction-blocks
          "loop__preheader"))
      60
      (not
        (=
          (opt-count-mul-label-blocks induction-after-preheader-blocks "body")
          0))
      61
      42)))

(define (compiler-optimize-ssa-self-test) : i64
  (let
    [diamond-blocks : CompilerIrBlockList (opt-ssa-diamond-blocks)]
    [diamond-index : OptCfgIndex (opt-cfg-index-build diamond-blocks)]
    [diamond-doms : OptDomInfo (opt-cfg-dominators diamond-blocks)]
    [then-frontier : OptLabelSet
      (opt-cfg-dominance-frontier diamond-blocks "then")]
    [else-frontier : OptLabelSet
      (opt-cfg-dominance-frontier diamond-blocks "else")]
    [loop-blocks : CompilerIrBlockList (opt-ssa-loop-blocks)]
    [loop-index : OptCfgIndex (opt-cfg-index-build loop-blocks)]
    [loop-doms : OptDomInfo (opt-cfg-dominators loop-blocks)]
    [loop-frontier : OptLabelSet
      (opt-cfg-dominance-frontier loop-blocks "loop")]
    [unreachable-index : OptCfgIndex
      (opt-cfg-index-build (opt-ssa-unreachable-blocks))]
    [unreachable-order : CompilerIrBlockList
      (opt-cfg-reachable-block-order (opt-ssa-unreachable-blocks))]
    [constructed-diamond : CompilerIrFunction
      (opt-ssa-construct-function (opt-ssa-construct-diamond-function))]
    [constructed-diamond-blocks : CompilerIrBlockList
      (opt-function-blocks constructed-diamond)]
    [constructed-loop : CompilerIrFunction
      (opt-ssa-construct-function (opt-ssa-construct-loop-function))]
    [constructed-loop-blocks : CompilerIrBlockList
      (opt-function-blocks constructed-loop)]
    [constructed-param : CompilerIrFunction
      (opt-ssa-construct-function (opt-ssa-construct-mutated-param-function))]
    [constructed-param-blocks : CompilerIrBlockList
      (opt-function-blocks constructed-param)]
    [address-taken : CompilerIrFunction
      (opt-ssa-construct-address-taken-function)]
    [address-taken-out : CompilerIrFunction
      (opt-ssa-construct-function address-taken)]
    [existing-phi : CompilerIrFunction
      (opt-cfg-test-function (opt-cfg-phi-blocks))]
    [existing-phi-out : CompilerIrFunction
      (opt-ssa-construct-function existing-phi)]
    [pipeline-loop : CompilerIrFunction
      (optimize-function-once (opt-ssa-construct-loop-function))]
    [pipeline-loop-blocks : CompilerIrBlockList
      (opt-function-blocks pipeline-loop)]
    (core/cond
      (not (= (opt-label-count (opt-cfg-predecessors diamond-blocks "join")) 2))
      1
      (not (= (opt-cfg-index-block-count diamond-index) 4))
      2
      (not (opt-verify-ok? (opt-verify-function (opt-ssa-diamond-function))))
      3
      (not
        (opt-label-set-eq?
          (opt-cfg-index-predecessors diamond-index "join")
          (opt-cfg-predecessors-scan diamond-blocks "join")))
      4
      (not
        (opt-label-set-eq?
          (opt-cfg-index-successors diamond-index "entry")
          (opt-cfg-blocks-successors-scan diamond-blocks "entry")))
      5
      (not (= (struct-get unreachable-index reach-count) 1))
      6
      (not (opt-cfg-index-reachable? unreachable-index "entry"))
      7
      (opt-cfg-index-reachable? unreachable-index "dead")
      8
      (not (string-eq (opt-cfg-index-rpo-label unreachable-index 0) "entry"))
      9
      (not (string-eq (opt-cfg-index-rpo-label loop-index 0) "entry"))
      10
      (not (opt-dom-dominates? diamond-doms "entry" "join"))
      11
      (opt-dom-dominates? diamond-doms "then" "join")
      12
      (not (opt-label-contains then-frontier "join"))
      13
      (not (opt-label-contains else-frontier "join"))
      14
      (not (opt-dom-dominates? loop-doms "loop" "body"))
      15
      (not (opt-label-contains loop-frontier "loop"))
      16
      (not (= (compiler-ir-block-list-count unreachable-order) 1))
      17
      (not (opt-block-list-has-label? unreachable-order "entry"))
      18
      (not (opt-verify-ok? (opt-verify-function (opt-ssa-loop-function))))
      19
      (not
        (opt-verify-ok? (opt-verify-function (opt-ssa-unreachable-function))))
      20
      (not
        (opt-verify-error-ok?
          (opt-verify-function (opt-ssa-duplicate-label-function))
          "optimizer verify: duplicate block label"))
      21
      (not
        (opt-verify-error-ok?
          (opt-verify-function (opt-ssa-unknown-successor-function))
          "optimizer verify: unknown successor label"))
      22
      (not
        (opt-verify-error-ok?
          (opt-verify-function (opt-ssa-bad-phi-function))
          "optimizer verify: phi predecessor mismatch"))
      23
      (not
        (opt-verify-error-ok?
          (opt-verify-function (opt-ssa-duplicate-def-function))
          "optimizer verify: duplicate var definition"))
      24
      (not
        (opt-verify-error-ok?
          (opt-verify-function (opt-ssa-use-before-def-function))
          "optimizer verify: use before definition"))
      25
      (not
        (opt-verify-error-ok?
          (opt-verify-function (opt-ssa-dominance-fail-function))
          "optimizer verify: use is not dominated by definition"))
      26
      (not
        (=
          (opt-cfg-index-rpo-num loop-index (opt-cfg-index-rpo-id loop-index 0))
          0))
      27
      (not (opt-cfg-dominators-match-legacy? diamond-blocks))
      28
      (not (opt-cfg-dominators-match-legacy? loop-blocks))
      29
      (not (opt-cfg-dominators-match-legacy? (opt-ssa-unreachable-blocks)))
      30
      (not
        (opt-cfg-dominators-match-legacy? (opt-natural-loop-irreducible-blocks)))
      31
      (not (opt-cfg-dominators-match-bitset? diamond-blocks))
      32
      (not (opt-cfg-dominators-match-bitset? loop-blocks))
      33
      (not (opt-cfg-dominators-match-bitset? (opt-ssa-unreachable-blocks)))
      34
      (not
        (opt-cfg-dominators-match-bitset? (opt-natural-loop-irreducible-blocks)))
      35
      (not (opt-verify-ok? (opt-verify-function constructed-diamond)))
      36
      (not (= (opt-count-phi-blocks constructed-diamond-blocks) 1))
      37
      (not (= (opt-count-mov-dst-blocks constructed-diamond-blocks 1) 0))
      38
      (not (opt-verify-ok? (opt-verify-function constructed-loop)))
      39
      (not (= (opt-count-phi-blocks constructed-loop-blocks) 1))
      40
      (not (= (opt-count-mov-dst-blocks constructed-loop-blocks 1) 0))
      41
      (not (opt-verify-ok? (opt-verify-function constructed-param)))
      46
      (not (= (opt-count-phi-blocks constructed-param-blocks) 1))
      47
      (not (= (opt-count-mov-dst-blocks constructed-param-blocks 0) 0))
      48
      (not (opt-function-eq address-taken address-taken-out))
      49
      (not (opt-function-eq existing-phi existing-phi-out))
      50
      (not (opt-verify-ok? (opt-verify-function pipeline-loop)))
      51
      (not (= (opt-count-mov-dst-blocks pipeline-loop-blocks 1) 0))
      52
      42)))

(define (compiler-optimize-cfg-self-test) : i64
  (let
    [constant-if : CompilerIrBlockList
      (opt-cfg-simplify-blocks (opt-cfg-constant-if-blocks))]
    [loop-guard : CompilerIrBlockList
      (opt-cfg-simplify-blocks (opt-cfg-loop-guard-blocks))]
    [phi-cfg : CompilerIrBlockList
      (opt-cfg-simplify-blocks (opt-cfg-phi-blocks))]
    [phi-blocks : CompilerIrBlockList
      (opt-function-blocks
        (optimize-function (opt-cfg-test-function (opt-cfg-phi-blocks))))]
    [trap-blocks : CompilerIrBlockList
      (opt-function-blocks
        (optimize-function (opt-cfg-test-function (opt-cfg-trap-path-blocks))))]
    [fallthrough-blocks : CompilerIrBlockList
      (opt-cfg-simplify-blocks (opt-cfg-fallthrough-prune-blocks))]
    (begin
      (unless (= (compiler-ir-block-list-count constant-if) 2) (return 1))
      (unless (not (opt-block-list-has-label? constant-if "else")) (return 2))
      (unless (= (opt-count-jump-to-blocks constant-if "then") 1) (return 3))
      (unless (= (opt-count-branches-blocks constant-if) 0) (return 4))
      (unless (= (compiler-ir-block-list-count loop-guard) 3) (return 5))
      (unless (not (opt-block-list-has-label? loop-guard "body")) (return 6))
      (unless (= (opt-count-jump-to-blocks loop-guard "exit") 1) (return 7))
      (unless (= (compiler-ir-block-list-count phi-blocks) 3) (return 8))
      (unless (not (opt-block-list-has-label? phi-blocks "else")) (return 9))
      (unless (= (opt-count-phi-blocks phi-blocks) 0) (return 10))
      (unless (= (opt-count-mov-dst-blocks phi-cfg 3) 1) (return 11))
      (unless (= (compiler-ir-block-list-count trap-blocks) 3) (return 12))
      (unless (opt-block-list-has-label? trap-blocks "trap") (return 13))
      (unless (= (opt-count-branches-blocks trap-blocks) 1) (return 14))
      (unless (opt-cfg-fallthrough-prune-ok? fallthrough-blocks) (return 15))
      42)))

(define (compiler-optimize-fixed-point-self-test) : i64
  (let
    [func : CompilerIrFunction (opt-test-function (opt-fixed-point-instrs))]
    [once : CompilerIrFunction (optimize-function-once func)]
    [fixed : CompilerIrFunction (optimize-function func)]
    [once-instrs : CompilerIrInstrList (opt-function-first-instrs once)]
    [fixed-instrs : CompilerIrInstrList (opt-function-first-instrs fixed)]
    [optimized-program : CompilerIrProgram
      (optimize-program-with-level
        (opt-test-program (opt-fixed-point-instrs))
        3)]
    [again-program : CompilerIrProgram
      (optimize-program-with-level optimized-program 3)]
    (core/cond
      (not (= (compiler-ir-instr-list-count once-instrs) 4))
      1
      (not (= (opt-count-arith-instrs once-instrs) 3))
      2
      (not (= (compiler-ir-instr-list-count fixed-instrs) 3))
      3
      (not (= (opt-count-arith-instrs fixed-instrs) 2))
      4
      (not (opt-program-eq optimized-program again-program))
      5
      42)))

;; --- noalias / alias fact model (#1510) -------------------------------------
;;
;; Optimizer-internal alias facts for IR temporaries. This section models facts
;; and conservative invalidation, proves the conservatism with self-tests, and
;; feeds the first local redundant-load CSE consumer (#2342). Later issues derive
;; richer facts from
;; borrow/move analysis (#1048/#1049/#1050/#806) and consume them in load/store,
;; bounds-check, scalar-replacement, and loop passes.
;;
;; A fact binds an IR temporary (var id) to one of four deliberately
;; conservative kinds:
;;   - Unique       : a freshly allocated root no other tracked pointer aliases
;;   - Derived base : a pointer derived from root/base var `base` by safe
;;                    pointer arithmetic (Gep); it aliases only that root's
;;                    allocation
;;   - MayAlias     : unknown provenance; may alias anything tracked
;;   - Invalidated  : a previously known fact a memory effect explicitly cleared
;;
;; Invalidation keys off `compiler-ir-instr-effect`: pure instructions keep the
;; surrounding facts (and (re)bind only their destination), memory reads keep
;; facts (the loaded value itself is MayAlias), and any instruction that can
;; mutate or unknown-observe memory (stores, vector/predicated stores, direct
;; and indirect calls, tail calls) conservatively clears ALL facts rather than
;; assuming C-style noalias. Control-flow joins intersect the per-edge sets.
(defenum OptAliasKind
  (OptAliasUnique)
  (OptAliasDerived i64)
  (OptAliasMayAlias)
  (OptAliasInvalidated))

(defenum OptAliasFact
  (OptAliasFact i64 OptAliasKind))

(defenum OptAliasFacts
  (OptAliasNil)
  (OptAliasCons OptAliasFact (Box OptAliasFacts)))

(defenum OptMaybeAliasKind
  (OptNoAliasKind)
  (OptSomeAliasKind OptAliasKind))

(define (opt-alias-kind-eq [a : OptAliasKind] [b : OptAliasKind]) : bool
  (match a
    [(OptAliasUnique)
      (match b
        [(OptAliasUnique) true]
        [_ false])]
    [(OptAliasDerived ba)
      (match b
        [(OptAliasDerived bb) (= ba bb)]
        [_ false])]
    [(OptAliasMayAlias)
      (match b
        [(OptAliasMayAlias) true]
        [_ false])]
    [(OptAliasInvalidated)
      (match b
        [(OptAliasInvalidated) true]
        [_ false])]))

(define (opt-alias-fact-var [fact : OptAliasFact]) : i64
  (match fact
    [(OptAliasFact var _) var]))

(define (opt-alias-fact-kind [fact : OptAliasFact]) : OptAliasKind
  (match fact
    [(OptAliasFact _ kind) kind]))

(define (opt-alias-lookup [facts : OptAliasFacts] [var : i64]) : OptMaybeAliasKind
  (match facts
    [(OptAliasNil) (OptNoAliasKind)]
    [(OptAliasCons fact rest)
      (let
        [rest : OptAliasFacts (box-get rest)]
        (if (= (opt-alias-fact-var fact) var)
          (OptSomeAliasKind (opt-alias-fact-kind fact))
          (opt-alias-lookup rest var)))]))

;; Drop any binding for `var` (a redefined/escaped temporary).
(define (opt-alias-remove-var [facts : OptAliasFacts] [var : i64]) : OptAliasFacts
  (match facts
    [(OptAliasNil) (OptAliasNil)]
    [(OptAliasCons fact rest)
      (let
        [rest : OptAliasFacts (box-get rest)]
        (if (= (opt-alias-fact-var fact) var)
          (opt-alias-remove-var rest var)
          (OptAliasCons fact (box (opt-alias-remove-var rest var)))))]))

;; Bind `var` to `kind`, replacing any prior binding for that var.
(define (opt-alias-bind
  [facts : OptAliasFacts]
  [var : i64]
  [kind : OptAliasKind]) : OptAliasFacts
  (OptAliasCons (OptAliasFact var kind) (box (opt-alias-remove-var facts var))))

(define (opt-alias-mark-unique [facts : OptAliasFacts] [var : i64]) : OptAliasFacts
  (opt-alias-bind facts var (OptAliasUnique)))

(define (opt-alias-mark-may-alias [facts : OptAliasFacts] [var : i64]) : OptAliasFacts
  (opt-alias-bind facts var (OptAliasMayAlias)))

(define (opt-alias-mark-invalidated [facts : OptAliasFacts] [var : i64]) : OptAliasFacts
  (opt-alias-bind facts var (OptAliasInvalidated)))

;; Copy a value's fact onto `dst` (Mov/Cast of a tracked var). An untracked
;; source conservatively yields a MayAlias destination.
(define (opt-alias-copy-var [facts : OptAliasFacts] [dst : i64] [src : i64]) : OptAliasFacts
  (match (opt-alias-lookup facts src)
    [(OptSomeAliasKind kind) (opt-alias-bind facts dst kind)]
    [(OptNoAliasKind) (opt-alias-mark-may-alias facts dst)]))

;; Derive `dst` through safe pointer arithmetic (Gep) from base var `base`.
;; A unique or already-derived base propagates the underlying root; anything
;; else is conservatively MayAlias.
(define (opt-alias-derive-var [facts : OptAliasFacts] [dst : i64] [base : i64]) : OptAliasFacts
  (match (opt-alias-lookup facts base)
    [(OptSomeAliasKind kind)
      (match kind
        [(OptAliasUnique) (opt-alias-bind facts dst (OptAliasDerived base))]
        [(OptAliasDerived root)
          (opt-alias-bind facts dst (OptAliasDerived root))]
        [(OptAliasMayAlias) (opt-alias-mark-may-alias facts dst)]
        [(OptAliasInvalidated) (opt-alias-mark-may-alias facts dst)])]
    [(OptNoAliasKind) (opt-alias-mark-may-alias facts dst)]))

(define (opt-alias-contains?
  [facts : OptAliasFacts]
  [var : i64]
  [kind : OptAliasKind]) : bool
  (match (opt-alias-lookup facts var)
    [(OptSomeAliasKind found) (opt-alias-kind-eq found kind)]
    [(OptNoAliasKind) false]))

(define (opt-alias-absent? [facts : OptAliasFacts] [var : i64]) : bool
  (match (opt-alias-lookup facts var)
    [(OptNoAliasKind) true]
    [(OptSomeAliasKind _) false]))

;; Conservative control-flow join: keep only facts that appear with an
;; identical kind on both incoming edges.
(define (opt-alias-intersect [a : OptAliasFacts] [b : OptAliasFacts]) : OptAliasFacts
  (match a
    [(OptAliasNil) (OptAliasNil)]
    [(OptAliasCons fact rest)
      (let
        [rest2 : OptAliasFacts (opt-alias-intersect (box-get rest) b)]
        (if (opt-alias-contains?
          b
          (opt-alias-fact-var fact)
          (opt-alias-fact-kind fact))
          (OptAliasCons fact (box rest2))
          rest2))]))

(define (opt-alias-facts-len [facts : OptAliasFacts]) : i64
  (match facts
    [(OptAliasNil) 0]
    [(OptAliasCons _ rest) (+ 1 (opt-alias-facts-len (box-get rest)))]))

;; A memory effect that can mutate or unknown-observe memory clears all facts.
;; `Alloc` is the one MemoryWrite that instead binds a fresh unique root, so it
;; is excluded by the caller below.
(define (opt-alias-effect-clears-facts? [effect : CompilerIrEffect]) : bool
  (match effect
    [(IrEffectPure) false]
    [(IrEffectMemoryRead) false]
    [(IrEffectMemoryWrite) true]
    [(IrEffectControlFlow) false]
    [(IrEffectUnknown) true]))

;; True when the instruction conservatively clears ALL alias facts. The
;; call family is listed explicitly because a tail call carries a control-flow
;; IR effect yet still mutates memory; `Alloc` is excluded because it binds a
;; unique root instead of clearing.
(define (opt-alias-instr-clears-all? [instr : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrAlloc _ _) false]
    [(IrInstrCall _ _ _ _) true]
    [(IrInstrCallIndirect _ _ _ _) true]
    [(IrInstrCallIndirectC _ _ _ _) true]
    [(IrInstrTailCall _ _ _) true]
    [_ (opt-alias-effect-clears-facts? (compiler-ir-instr-effect instr))]))

(define (opt-alias-update-gep
  [facts : OptAliasFacts]
  [dst : i64]
  [base : CompilerIrValue]) : OptAliasFacts
  (match base
    [(IrValueVar base-var) (opt-alias-derive-var facts dst base-var)]
    [_ (opt-alias-mark-may-alias facts dst)]))

(define (opt-alias-update-copy
  [facts : OptAliasFacts]
  [dst : i64]
  [value : CompilerIrValue]) : OptAliasFacts
  (match value
    [(IrValueVar src) (opt-alias-copy-var facts dst src)]
    [_ (opt-alias-mark-may-alias facts dst)]))

;; Transfer function for one instruction. Memory-mutating/unknown instructions
;; clear all facts; otherwise pure value-producers (re)bind only their
;; destination and the surrounding facts survive.
(define (opt-alias-update-facts
  [facts : OptAliasFacts]
  [instr : CompilerIrInstr]) : OptAliasFacts
  (if (opt-alias-instr-clears-all? instr)
    (OptAliasNil)
    (match instr
      [(IrInstrAlloc dst _) (opt-alias-mark-unique facts dst)]
      [(IrInstrGep dst base _ _) (opt-alias-update-gep facts dst base)]
      [(IrInstrMov dst value _) (opt-alias-update-copy facts dst value)]
      [(IrInstrCast dst value _ _) (opt-alias-update-copy facts dst value)]
      [(IrInstrLoad dst _ _) (opt-alias-mark-may-alias facts dst)]
      [(IrInstrEntryArgc dst) (opt-alias-remove-var facts dst)]
      [(IrInstrEntryArgv dst) (opt-alias-mark-may-alias facts dst)]
      [(IrInstrEntryEnvp dst) (opt-alias-mark-may-alias facts dst)]
      [(IrInstrAddrOf dst _) (opt-alias-mark-may-alias facts dst)]
      [(IrInstrVectorLoad dst _ _ _ _) (opt-alias-mark-may-alias facts dst)]
      [(IrInstrPredicatedLoad dst _ _ _ _ _)
        (opt-alias-mark-may-alias facts dst)]
      [_ facts])))

(define (opt-alias-run [facts : OptAliasFacts] [instrs : CompilerIrInstrList]) : OptAliasFacts
  (match instrs
    [(IrInstrNil) facts]
    [(IrInstrCons instr rest)
      (opt-alias-run (opt-alias-update-facts facts instr) (box-get rest))]))

;; --- block-local redundant-load CSE (#2342) ---------------------------------
(defenum OptLoadKey
  (OptLoadKey CompilerIrValue AstType))

(defenum OptLoadEntry
  (OptLoadEntry OptLoadKey i64))

(defenum OptLoadTable
  (OptLoadNil)
  (OptLoadCons OptLoadEntry (Box OptLoadTable)))

(defenum OptLoadCseState
  (OptLoadCseState OptAliasFacts OptLoadTable))

(defenum OptLoadCseResult
  (OptLoadCseResult OptLoadCseState CompilerIrInstr))

(define (opt-load-key-eq [a : OptLoadKey] [b : OptLoadKey]) : bool
  (match a
    [(OptLoadKey av aty)
      (match b
        [(OptLoadKey bv bty) (and (opt-value-eq av bv) (opt-type-eq aty bty))])]))

(define (opt-load-key-uses-var? [key : OptLoadKey] [var : i64]) : bool
  (match key
    [(OptLoadKey value _) (opt-value-is-var? value var)]))

(define (opt-load-entry-key [entry : OptLoadEntry]) : OptLoadKey
  (match entry
    [(OptLoadEntry key _) key]))

(define (opt-load-entry-var [entry : OptLoadEntry]) : i64
  (match entry
    [(OptLoadEntry _ var) var]))

(define (opt-load-table-lookup [table : OptLoadTable] [key : OptLoadKey]) : OptMaybeI64
  (match table
    [(OptLoadNil) (OptNoI64)]
    [(OptLoadCons entry rest)
      (if (opt-load-key-eq (opt-load-entry-key entry) key)
        (OptSomeI64 (opt-load-entry-var entry))
        (opt-load-table-lookup (box-get rest) key))]))

(define (opt-load-table-remove-key [table : OptLoadTable] [key : OptLoadKey]) : OptLoadTable
  (match table
    [(OptLoadNil) (OptLoadNil)]
    [(OptLoadCons entry rest)
      (let
        [tail : OptLoadTable (opt-load-table-remove-key (box-get rest) key)]
        (if (opt-load-key-eq (opt-load-entry-key entry) key)
          tail
          (OptLoadCons entry (box tail))))]))

(define (opt-load-table-bind
  [table : OptLoadTable]
  [key : OptLoadKey]
  [var : i64]) : OptLoadTable
  (OptLoadCons
    (OptLoadEntry key var)
    (box (opt-load-table-remove-key table key))))

;; Drop entries whose address expression references `var`, or whose cached load
;; result was `var`. The IR is not globally SSA, so any reused var id must make
;; old load facts disappear before the new instruction is processed.
(define (opt-load-table-invalidate-var [table : OptLoadTable] [var : i64]) : OptLoadTable
  (match table
    [(OptLoadNil) (OptLoadNil)]
    [(OptLoadCons entry rest)
      (let
        [rest2 : OptLoadTable
          (opt-load-table-invalidate-var (box-get rest) var)]
        (if (or
          (= (opt-load-entry-var entry) var)
          (opt-load-key-uses-var? (opt-load-entry-key entry) var))
          rest2
          (OptLoadCons entry (box rest2))))]))

(define (opt-load-cse-state-invalidate-def
  [state : OptLoadCseState]
  [instr : CompilerIrInstr]) : OptLoadCseState
  (match state
    [(OptLoadCseState facts table)
      (match (opt-instr-def-var instr)
        [(OptSomeI64 dst)
          (OptLoadCseState facts (opt-load-table-invalidate-var table dst))]
        [(OptNoI64) state])]))

(define (opt-load-cse-state-update-facts
  [state : OptLoadCseState]
  [instr : CompilerIrInstr]) : OptLoadCseState
  (match state
    [(OptLoadCseState facts table)
      (OptLoadCseState (opt-alias-update-facts facts instr) table)]))

(define (opt-load-cse-state-clear-for-memory
  [state : OptLoadCseState]
  [instr : CompilerIrInstr]) : OptLoadCseState
  (match state
    [(OptLoadCseState facts _)
      (OptLoadCseState (opt-alias-update-facts facts instr) (OptLoadNil))]))

(define (opt-load-cse-record-load
  [state : OptLoadCseState]
  [key : OptLoadKey]
  [dst : i64]) : OptLoadCseState
  (match state
    [(OptLoadCseState facts table)
      (if (opt-load-key-uses-var? key dst)
        state
        (OptLoadCseState facts (opt-load-table-bind table key dst)))]))

(define (opt-load-cse-load
  [state : OptLoadCseState]
  [dst : i64]
  [src : CompilerIrValue]
  [ty : AstType]
  [instr : CompilerIrInstr]) : OptLoadCseResult
  (let
    [invalidated : OptLoadCseState
      (opt-load-cse-state-invalidate-def state instr)]
    [key : OptLoadKey (OptLoadKey src ty)]
    (match invalidated
      [(OptLoadCseState _ table)
        (match (opt-load-table-lookup table key)
          [(OptSomeI64 earlier)
            (let
              [new-instr : CompilerIrInstr
                (IrInstrMov dst (IrValueVar earlier) ty)]
              [updated : OptLoadCseState
                (opt-load-cse-state-update-facts invalidated new-instr)]
              (OptLoadCseResult
                (opt-load-cse-record-load updated key dst)
                new-instr))]
          [(OptNoI64)
            (let
              [updated : OptLoadCseState
                (opt-load-cse-state-update-facts invalidated instr)]
              (OptLoadCseResult
                (opt-load-cse-record-load updated key dst)
                instr))])])))

(define (opt-load-cse-instr [state : OptLoadCseState] [instr : CompilerIrInstr]) : OptLoadCseResult
  (if (opt-alias-instr-clears-all? instr)
    (OptLoadCseResult (opt-load-cse-state-clear-for-memory state instr) instr)
    (match instr
      [(IrInstrLoad dst src ty) (opt-load-cse-load state dst src ty instr)]
      [_
        (OptLoadCseResult
          (opt-load-cse-state-update-facts
            (opt-load-cse-state-invalidate-def state instr)
            instr)
          instr)])))

(define (opt-load-cse-instrs
  [state : OptLoadCseState]
  [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (match (opt-load-cse-instr state instr)
        [(OptLoadCseResult next-state new-instr)
          (compiler-ir-instr-cons
            new-instr
            (opt-load-cse-instrs next-state (box-get rest)))])]))

;; --- cross-block redundant-load GVN (#2343) ---------------------------------
(defenum OptMaybeLoadCseState
  (OptNoLoadCseState)
  (OptSomeLoadCseState OptLoadCseState))

(defenum OptLoadGvnBlockRewrite
  (OptLoadGvnBlockRewrite OptLoadCseState CompilerIrInstrList))

(define (opt-load-cse-empty-state) : OptLoadCseState
  (OptLoadCseState (OptAliasNil) (OptLoadNil)))

(define (opt-load-table-contains-entry?
  [table : OptLoadTable]
  [entry : OptLoadEntry]) : bool
  (match entry
    [(OptLoadEntry key var)
      (match (opt-load-table-lookup table key)
        [(OptSomeI64 found) (= found var)]
        [(OptNoI64) false])]))

(define (opt-load-table-intersect [a : OptLoadTable] [b : OptLoadTable]) : OptLoadTable
  (match a
    [(OptLoadNil) (OptLoadNil)]
    [(OptLoadCons entry rest)
      (let
        [tail : OptLoadTable (opt-load-table-intersect (box-get rest) b)]
        (if (opt-load-table-contains-entry? b entry)
          (OptLoadCons entry (box tail))
          tail))]))

(define (opt-load-cse-state-intersect
  [a : OptLoadCseState]
  [b : OptLoadCseState]) : OptLoadCseState
  (match a
    [(OptLoadCseState afacts atable)
      (match b
        [(OptLoadCseState bfacts btable)
          (OptLoadCseState
            (opt-alias-intersect afacts bfacts)
            (opt-load-table-intersect atable btable))])]))

(define (opt-load-state-array-fill-empty!
  [states : (Array OptMaybeLoadCseState)]
  [count : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (array-set! states i (OptNoLoadCseState))
          (set! i (+ i 1))))
      unit)))

(define (opt-load-gvn-entry-from-preds
  [index : OptCfgIndex]
  [exit-states : (Array OptMaybeLoadCseState)]
  [processed : (Array bool)]
  [edge : i64]
  [end : i64]
  [has-state : bool]
  [acc : OptLoadCseState]) : OptLoadCseState
  (if (>= edge end)
    acc
    (let
      [pred : i64 (array-ref (struct-get (struct-get index preds) edges) edge)]
      (if (not (array-ref (struct-get index reachable) pred))
        (opt-load-gvn-entry-from-preds
          index
          exit-states
          processed
          (+ edge 1)
          end
          has-state
          acc)
        (if (not (array-ref processed pred))
          (opt-load-cse-empty-state)
          (match (array-ref exit-states pred)
            [(OptSomeLoadCseState pred-state)
              (opt-load-gvn-entry-from-preds
                index
                exit-states
                processed
                (+ edge 1)
                end
                true
                (if has-state
                  (opt-load-cse-state-intersect acc pred-state)
                  pred-state))]
            [(OptNoLoadCseState) (opt-load-cse-empty-state)]))))))

(define (opt-load-gvn-entry-state
  [context : OptCfgContext]
  [exit-states : (Array OptMaybeLoadCseState)]
  [processed : (Array bool)]
  [id : i64]) : OptLoadCseState
  (let
    [index : OptCfgIndex (struct-get context index)]
    [preds : OptCfgCsr (struct-get index preds)]
    [entry-label : String (struct-get context entry-label)]
    (match (opt-cfg-index-id index entry-label)
      [(OptSomeI64 entry-id)
        (if (= id entry-id)
          (opt-load-cse-empty-state)
          (opt-load-gvn-entry-from-preds
            index
            exit-states
            processed
            (array-ref (struct-get preds offsets) id)
            (array-ref (struct-get preds offsets) (+ id 1))
            false
            (opt-load-cse-empty-state)))]
      [(OptNoI64) (opt-load-cse-empty-state)])))

(define (opt-load-gvn-load
  [state : OptLoadCseState]
  [sources : I64I64Map]
  [dst : i64]
  [src : CompilerIrValue]
  [ty : AstType]
  [instr : CompilerIrInstr]) : OptLoadCseResult
  (let
    [invalidated : OptLoadCseState
      (opt-load-cse-state-invalidate-def state instr)]
    [key : OptLoadKey (OptLoadKey src ty)]
    (if (and
      (opt-gvn-stable-var? sources dst)
      (opt-gvn-value-stable? sources src))
      (match invalidated
        [(OptLoadCseState _ table)
          (match (opt-load-table-lookup table key)
            [(OptSomeI64 earlier)
              (let
                [new-instr : CompilerIrInstr
                  (IrInstrMov dst (IrValueVar earlier) ty)]
                [updated : OptLoadCseState
                  (opt-load-cse-state-update-facts invalidated new-instr)]
                (OptLoadCseResult
                  (opt-load-cse-record-load updated key dst)
                  new-instr))]
            [(OptNoI64)
              (let
                [updated : OptLoadCseState
                  (opt-load-cse-state-update-facts invalidated instr)]
                (OptLoadCseResult
                  (opt-load-cse-record-load updated key dst)
                  instr))])])
      (OptLoadCseResult
        (opt-load-cse-state-update-facts invalidated instr)
        instr))))

(define (opt-load-gvn-instr
  [state : OptLoadCseState]
  [sources : I64I64Map]
  [instr : CompilerIrInstr]) : OptLoadCseResult
  (if (opt-alias-instr-clears-all? instr)
    (OptLoadCseResult (opt-load-cse-state-clear-for-memory state instr) instr)
    (match instr
      [(IrInstrLoad dst src ty)
        (opt-load-gvn-load state sources dst src ty instr)]
      [_
        (OptLoadCseResult
          (opt-load-cse-state-update-facts
            (opt-load-cse-state-invalidate-def state instr)
            instr)
          instr)])))

(define (opt-load-gvn-instr-seq-from
  [state : OptLoadCseState]
  [sources : I64I64Map]
  [instrs : CompilerIrInstrSeq]
  [index : i64]
  [out-rev : CompilerIrInstrList]) : OptLoadGvnBlockRewrite
  (if (>= index (compiler-ir-instr-seq-count instrs))
    (OptLoadGvnBlockRewrite
      state
      (compiler-ir-instr-list-reverse-onto out-rev IrInstrNil))
    (match (opt-load-gvn-instr
      state
      sources
      (compiler-ir-instr-seq-ref instrs index))
      [(OptLoadCseResult next-state new-instr)
        (opt-load-gvn-instr-seq-from
          next-state
          sources
          instrs
          (+ index 1)
          (compiler-ir-instr-cons new-instr out-rev))])))

(define (opt-load-gvn-rewrite-block
  [entry-state : OptLoadCseState]
  [sources : I64I64Map]
  [block : CompilerIrBlock]) : OptLoadGvnBlockRewrite
  (match block
    [(IrBlock _ instrs)
      (opt-load-gvn-instr-seq-from entry-state sources instrs 0 IrInstrNil)]))

(define (opt-load-gvn-process-id
  [context : OptCfgContext]
  [sources : I64I64Map]
  [blocks : CompilerIrBlockList]
  [exit-states : (Array OptMaybeLoadCseState)]
  [processed : (Array bool)]
  [out : (Array OptGvnBlockResult)]
  [id : i64]) : unit
  (let
    [index : OptCfgIndex (struct-get context index)]
    [label : String (opt-cfg-index-label index id)]
    [entry-state : OptLoadCseState
      (opt-load-gvn-entry-state context exit-states processed id)]
    (match (opt-cfg-find-block blocks label)
      [(OptNoBlock) unit]
      [(OptSomeBlock block)
        (match block
          [(IrBlock block-label _)
            (match (opt-load-gvn-rewrite-block entry-state sources block)
              [(OptLoadGvnBlockRewrite exit-state instrs)
                (begin
                  (array-set!
                    out
                    id
                    (OptGvnSomeBlock (compiler-ir-block block-label instrs)))
                  (array-set! exit-states id (OptSomeLoadCseState exit-state))
                  (array-set! processed id true))])])])))

(define (opt-load-gvn-process-rpo
  [context : OptCfgContext]
  [sources : I64I64Map]
  [blocks : CompilerIrBlockList]
  [exit-states : (Array OptMaybeLoadCseState)]
  [processed : (Array bool)]
  [out : (Array OptGvnBlockResult)]
  [slot : i64]) : unit
  (let
    [index : OptCfgIndex (struct-get context index)]
    [reach-count : i64 (struct-get index reach-count)]
    (if (>= slot reach-count)
      unit
      (let
        [id : i64 (opt-cfg-index-rpo-id index slot)]
        (begin
          (opt-load-gvn-process-id
            context
            sources
            blocks
            exit-states
            processed
            out
            id)
          (opt-load-gvn-process-rpo
            context
            sources
            blocks
            exit-states
            processed
            out
            (+ slot 1)))))))

(define (opt-load-gvn-blocks-with-context
  [context : OptCfgContext]
  [sources : I64I64Map]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (let
    [index : OptCfgIndex (struct-get context index)]
    [count : i64 (opt-cfg-index-block-count index)]
    [exit-states : (Array OptMaybeLoadCseState)
      (make-array OptMaybeLoadCseState count)]
    [processed : (Array bool) (make-array bool count)]
    [out : (Array OptGvnBlockResult) (make-array OptGvnBlockResult count)]
    (begin
      (opt-load-state-array-fill-empty! exit-states count)
      (opt-cfg-fill-bool! processed count false)
      (opt-gvn-block-results-fill-empty! out 0)
      (opt-load-gvn-process-rpo
        context
        sources
        blocks
        exit-states
        processed
        out
        0)
      (opt-gvn-materialize-blocks (struct-get context doms) out blocks))))

;; --- noalias fact model self-test (#1510) -----------------------------------
(define (opt-alias-test-unique-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrAlloc 0 (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrGep 1 (IrValueVar 0) (IrValueI64 8) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrBinOp 2 (IrBinAdd) (IrValueI64 1) (IrValueI64 2) (AstTyI64))
        (IrInstrNil)))))

(define (opt-alias-test-transitive-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrAlloc 0 (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrGep 1 (IrValueVar 0) (IrValueI64 8) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrGep 2 (IrValueVar 1) (IrValueI64 8) (AstTyI64))
        (IrInstrNil)))))

(define (opt-alias-test-load-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrAlloc 0 (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrLoad 1 (IrValueVar 0) (AstTyI64))
      (IrInstrNil))))

(define (opt-alias-test-store-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrAlloc 0 (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrStorePtr (IrValueVar 0) (IrValueI64 5) (AstTyI64))
      (IrInstrNil))))

(define (opt-alias-test-call-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrAlloc 0 (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrCall 9 "tl_noop" (IrCallArgsNil) (AstTyI64))
      (IrInstrNil))))

(define (opt-alias-test-copy-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrAlloc 0 (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrMov 1 (IrValueVar 0) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrMov 2 (IrValueI64 7) (AstTyI64))
        (IrInstrNil)))))

(define (opt-alias-join-facts-a) : OptAliasFacts
  (opt-alias-bind
    (opt-alias-bind
      (opt-alias-bind (OptAliasNil) 0 (OptAliasUnique))
      1
      (OptAliasDerived 0))
    2
    (OptAliasMayAlias)))

(define (opt-alias-join-facts-b) : OptAliasFacts
  (opt-alias-bind
    (opt-alias-bind
      (opt-alias-bind (OptAliasNil) 0 (OptAliasUnique))
      1
      (OptAliasMayAlias))
    3
    (OptAliasUnique)))

(define (opt-alias-sample-store) : CompilerIrInstr
  (IrInstrStorePtr (IrValueVar 0) (IrValueI64 5) (AstTyI64)))

(define (opt-alias-sample-tail-call) : CompilerIrInstr
  (IrInstrTailCall "tl_noop" (IrCallArgsNil) (AstTyI64)))

(define (opt-alias-sample-binop) : CompilerIrInstr
  (IrInstrBinOp 9 (IrBinAdd) (IrValueI64 1) (IrValueI64 2) (AstTyI64)))

(define (compiler-optimize-alias-self-test) : i64
  (let
    [unique : OptAliasFacts
      (opt-alias-run (OptAliasNil) (opt-alias-test-unique-instrs))]
    [transitive : OptAliasFacts
      (opt-alias-run (OptAliasNil) (opt-alias-test-transitive-instrs))]
    [loaded : OptAliasFacts
      (opt-alias-run (OptAliasNil) (opt-alias-test-load-instrs))]
    [stored : OptAliasFacts
      (opt-alias-run (OptAliasNil) (opt-alias-test-store-instrs))]
    [called : OptAliasFacts
      (opt-alias-run (OptAliasNil) (opt-alias-test-call-instrs))]
    [copied : OptAliasFacts
      (opt-alias-run (OptAliasNil) (opt-alias-test-copy-instrs))]
    [joined : OptAliasFacts
      (opt-alias-intersect (opt-alias-join-facts-a) (opt-alias-join-facts-b))]
    [invalidated : OptAliasFacts
      (opt-alias-mark-invalidated (opt-alias-mark-unique (OptAliasNil) 0) 0)]
    (core/cond
      ;; unique root + derived pointer + survival across a pure scalar instr
      (not (opt-alias-contains? unique 0 (OptAliasUnique)))
      1
      (not (opt-alias-contains? unique 1 (OptAliasDerived 0)))
      2
      (not (opt-alias-absent? unique 2))
      3
      (not (= (opt-alias-facts-len unique) 2))
      4
      ;; transitive derive collapses to the underlying root
      (not (opt-alias-contains? transitive 2 (OptAliasDerived 0)))
      5
      ;; memory read makes the loaded value MayAlias but keeps the root
      (not (opt-alias-contains? loaded 0 (OptAliasUnique)))
      6
      (not (opt-alias-contains? loaded 1 (OptAliasMayAlias)))
      7
      ;; a raw-pointer store conservatively clears every fact
      (not (= (opt-alias-facts-len stored) 0))
      8
      (not (opt-alias-instr-clears-all? (opt-alias-sample-store)))
      9
      ;; calls and tail calls conservatively clear every fact
      (not (= (opt-alias-facts-len called) 0))
      10
      (not (opt-alias-instr-clears-all? (opt-alias-sample-tail-call)))
      11
      ;; copy through Mov preserves kind; a non-var move is MayAlias
      (not (opt-alias-contains? copied 1 (OptAliasUnique)))
      12
      (not (opt-alias-contains? copied 2 (OptAliasMayAlias)))
      13
      ;; control-flow join intersects to agreeing facts only
      (not (= (opt-alias-facts-len joined) 1))
      14
      (not (opt-alias-contains? joined 0 (OptAliasUnique)))
      15
      (opt-alias-contains? joined 1 (OptAliasDerived 0))
      16
      ;; a pure instruction never clears facts
      (opt-alias-instr-clears-all? (opt-alias-sample-binop))
      17
      ;; explicit invalidation tombstones a prior fact
      (not (opt-alias-contains? invalidated 0 (OptAliasInvalidated)))
      18
      42)))

(define (opt-load-cse-run [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (opt-load-cse-instrs (OptLoadCseState (OptAliasNil) (OptLoadNil)) instrs))

(define (opt-load-cse-positive-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrAlloc 0 (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrGep 1 (IrValueVar 0) (IrValueI64 0) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrLoad 2 (IrValueVar 1) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrBinOp 4 (IrBinAdd) (IrValueI64 1) (IrValueI64 2) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrLoad 3 (IrValueVar 1) (AstTyI64))
            (IrInstrNil)))))))

(define (opt-load-cse-barrier-instrs [barrier : CompilerIrInstr]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrAlloc 0 (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrGep 1 (IrValueVar 0) (IrValueI64 0) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrLoad 2 (IrValueVar 1) (AstTyI64))
        (compiler-ir-instr-cons
          barrier
          (compiler-ir-instr-cons
            (IrInstrLoad 3 (IrValueVar 1) (AstTyI64))
            (IrInstrNil)))))))

(define (opt-load-cse-address-redef-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrAlloc 0 (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrGep 1 (IrValueVar 0) (IrValueI64 0) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrLoad 2 (IrValueVar 1) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrMov 1 (IrValueI64 7) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrLoad 3 (IrValueVar 1) (AstTyI64))
            (IrInstrNil)))))))

(define (opt-load-cse-result-redef-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrAlloc 0 (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrGep 1 (IrValueVar 0) (IrValueI64 0) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrLoad 2 (IrValueVar 1) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrMov 2 (IrValueI64 7) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrLoad 3 (IrValueVar 1) (AstTyI64))
            (IrInstrNil)))))))

(define (opt-load-cse-type-mismatch-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrAlloc 0 (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrGep 1 (IrValueVar 0) (IrValueI64 0) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrLoad 2 (IrValueVar 1) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrLoad 3 (IrValueVar 1) (AstTyBool))
          (IrInstrNil))))))

(define (opt-load-cse-different-address-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrAlloc 0 (AstTyI64))
    (compiler-ir-instr-cons
      (IrInstrGep 1 (IrValueVar 0) (IrValueI64 0) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrGep 4 (IrValueVar 0) (IrValueI64 8) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrLoad 2 (IrValueVar 1) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrLoad 3 (IrValueVar 4) (AstTyI64))
            (IrInstrNil)))))))

(define (opt-load-cse-barrier-blocked? [barrier : CompilerIrInstr]) : bool
  (let
    [optimized : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-barrier-instrs barrier))]
    (and
      (= (opt-count-load-instrs optimized) 2)
      (= (opt-count-mov-dst-instrs optimized 3) 0))))

(define (compiler-optimize-load-cse-self-test) : i64
  (let
    [positive : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-positive-instrs))]
    [store : bool
      (opt-load-cse-barrier-blocked?
        (IrInstrStorePtr (IrValueVar 1) (IrValueI64 9) (AstTyI64)))]
    [global-store : bool
      (opt-load-cse-barrier-blocked?
        (IrInstrStore "g" (IrValueI64 9) (AstTyI64)))]
    [vector-store : bool
      (opt-load-cse-barrier-blocked?
        (IrInstrVectorStore
          (IrValueVar 1)
          (IrValueI64 0)
          (IrValueI64 9)
          4
          (AstTyI64)))]
    [pred-store : bool
      (opt-load-cse-barrier-blocked?
        (IrInstrPredicatedStore
          (IrValueVar 1)
          (IrValueI64 0)
          (IrValueI64 9)
          (IrValueBool true)
          4
          (AstTyI64)))]
    [direct-call : bool
      (opt-load-cse-barrier-blocked?
        (IrInstrCall 9 "touch" (IrCallArgsNil) (AstTyI64)))]
    [indirect-call : bool
      (opt-load-cse-barrier-blocked?
        (IrInstrCallIndirect
          9
          (IrValueFunction "touch")
          (IrCallArgsNil)
          (AstTyI64)))]
    [tail-call : bool
      (opt-load-cse-barrier-blocked?
        (IrInstrTailCall "touch" (IrCallArgsNil) (AstTyI64)))]
    [syscall : bool
      (opt-load-cse-barrier-blocked? (IrInstrSyscall 9 (IrCallArgsNil)))]
    [address-redef : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-address-redef-instrs))]
    [result-redef : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-result-redef-instrs))]
    [type-mismatch : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-type-mismatch-instrs))]
    [different-address : CompilerIrInstrList
      (opt-load-cse-run (opt-load-cse-different-address-instrs))]
    [pipeline : CompilerIrBlock
      (optimize-block
        (compiler-ir-block "entry" (opt-load-cse-positive-instrs)))]
    [pipeline-instrs : CompilerIrInstrList
      (match pipeline
        [(IrBlock _ instrs) (compiler-ir-instr-seq-to-list instrs)])]
    (core/cond
      (not (= (opt-count-load-instrs positive) 1))
      1
      (not (= (opt-count-mov-dst-instrs positive 3) 1))
      2
      (not store)
      3
      (not global-store)
      4
      (not vector-store)
      5
      (not pred-store)
      6
      (not direct-call)
      7
      (not indirect-call)
      8
      (not tail-call)
      9
      (not syscall)
      10
      (not (= (opt-count-load-instrs address-redef) 2))
      11
      (not (= (opt-count-mov-dst-instrs address-redef 3) 0))
      12
      (not (= (opt-count-load-instrs result-redef) 2))
      13
      (not (= (opt-count-mov-dst-instrs result-redef 3) 0))
      14
      (not (= (opt-count-load-instrs type-mismatch) 2))
      15
      (not (= (opt-count-load-instrs different-address) 2))
      16
      (not (= (opt-count-load-instrs pipeline-instrs) 1))
      17
      (not (= (opt-count-mov-dst-instrs pipeline-instrs 3) 1))
      18
      42)))