;; compiler_optimize.tl - Selfhost optimizer: pass framework + scalar constant
;; folding (#543, first slice of #519).
;;
;; Runs between lowering (`lower-compiler-program`) and backend emission
;; (`compiler-backend-emit-program`). It performs conservative, scalar-only
;; local rewrites: constant folding, algebraic strength reduction, CSE, copy
;; propagation, redundant bounds-check elimination, conservative CFG
;; simplification, and DCE.
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
(import "compiler_ir_types.tl")

(defenum ResultCompilerOptimizeLevel
  (OkCompilerOptimizeLevel i64)
  (ErrCompilerOptimizeLevel))

(defenum CompilerOptimizedProgram
  (CompilerOptimizedProgram CompilerIrProgram CompilerSourceSpans))

(define compiler-optimize-level-default : i64
  2)

(define (compiler-optimize-default-level) : i64
  compiler-optimize-level-default)

(define (compiler-optimize-level-valid? [level : i64]) : bool
  (and (>= level 0) (<= level 3)))

(define (compiler-optimize-parse-level [value : String]) : ResultCompilerOptimizeLevel
  (if (= (string-length value) 1)
    (let
      [c : char (string-ref value 0)]
      (if (or (= c #0') (or (= c #1') (or (= c #2') (= c #3'))))
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
  (OptConstCons i64 CompilerIrValue AstType OptConstEnv))

(define (opt-const-unbind [env : OptConstEnv] [var : i64]) : OptConstEnv
  (match env
    [(OptConstNil) (OptConstNil)]
    [(OptConstCons id value ty rest)
      (if (= id var)
        (opt-const-unbind rest var)
        (OptConstCons id value ty (opt-const-unbind rest var)))]))

(define (opt-const-bind
  [env : OptConstEnv]
  [var : i64]
  [value : CompilerIrValue]
  [ty : AstType]) : OptConstEnv
  (OptConstCons var value ty (opt-const-unbind env var)))

(define (opt-const-lookup [env : OptConstEnv] [var : i64]) : OptKnownConst
  (match env
    [(OptConstNil) (OptNoConst)]
    [(OptConstCons id value ty rest)
      (if (= id var)
        (OptSomeConst value ty)
        (opt-const-lookup rest var))]))

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
      (if (or (opt-i64-zero? resolved-lhs) (opt-i64-zero? resolved-rhs))
        (IrSomeValue (IrValueI64 0))
        (if (opt-i64-one? resolved-rhs)
          (IrSomeValue lhs)
          (if (opt-i64-one? resolved-lhs)
            (IrSomeValue rhs)
            (IrNoValue))))]
    [_ (IrNoValue)]))

(define (opt-strength-bool-binop
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [resolved-lhs : CompilerIrValue]
  [resolved-rhs : CompilerIrValue]) : CompilerIrMaybeValue
  (match op
    [(IrBinAnd)
      (if (or (opt-bool-false? resolved-lhs) (opt-bool-false? resolved-rhs))
        (IrSomeValue (IrValueBool false))
        (if (opt-bool-true? resolved-rhs)
          (IrSomeValue lhs)
          (if (opt-bool-true? resolved-lhs)
            (IrSomeValue rhs)
            (IrNoValue))))]
    [(IrBinOr)
      (if (or (opt-bool-true? resolved-lhs) (opt-bool-true? resolved-rhs))
        (IrSomeValue (IrValueBool true))
        (if (opt-bool-false? resolved-rhs)
          (IrSomeValue lhs)
          (if (opt-bool-false? resolved-lhs)
            (IrSomeValue rhs)
            (IrNoValue))))]
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
    [(IrInstrCall dst name args ty) (opt-invalidate-def env dst instr)]
    [(IrInstrTailCall _ _ _) (OptInstrResult env instr)]
    [(IrInstrPhi dst inputs ty) (opt-invalidate-def env dst instr)]
    [_ (OptInstrResult env instr)]))

(define (opt-fold-instrs [env : OptConstEnv] [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (match (opt-fold-instr env instr)
        [(OptInstrResult new-env new-instr)
          (IrInstrCons new-instr (opt-fold-instrs new-env rest))])]))

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
    [(IrInstrCall dst name args ty) (opt-invalidate-def env dst instr)]
    [(IrInstrTailCall _ _ _) (OptInstrResult env instr)]
    [(IrInstrPhi dst inputs ty) (opt-invalidate-def env dst instr)]
    [_ (OptInstrResult env instr)]))

(define (opt-strength-instrs [env : OptConstEnv] [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (match (opt-strength-instr env instr)
        [(OptInstrResult new-env new-instr)
          (IrInstrCons new-instr (opt-strength-instrs new-env rest))])]))

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
(defenum OptUsedSet
  (OptUsedNil)
  (OptUsedCons i64 OptUsedSet))

(define (opt-used-contains [set : OptUsedSet] [var : i64]) : bool
  (match set
    [(OptUsedNil) false]
    [(OptUsedCons id rest)
      (if (= id var)
        true
        (opt-used-contains rest var))]))

(define (opt-used-add [set : OptUsedSet] [var : i64]) : OptUsedSet
  (if (opt-used-contains set var)
    set
    (OptUsedCons var set)))

(define (opt-collect-value-uses [set : OptUsedSet] [value : CompilerIrValue]) : OptUsedSet
  (match value
    [(IrValueVar id) (opt-used-add set id)]
    [_ set]))

(define (opt-collect-value-list-uses
  [set : OptUsedSet]
  [values : CompilerIrValueList]) : OptUsedSet
  (match values
    [(IrValueNil) set]
    [(IrValueCons value rest)
      (opt-collect-value-list-uses (opt-collect-value-uses set value) rest)]))

(define (opt-collect-phi-uses
  [set : OptUsedSet]
  [inputs : CompilerIrPhiInputList]) : OptUsedSet
  (match inputs
    [(IrPhiInputNil) set]
    [(IrPhiInputCons input rest)
      (match input
        [(IrPhiInput value _)
          (opt-collect-phi-uses (opt-collect-value-uses set value) rest)])]))

(define (opt-collect-instr-uses [set : OptUsedSet] [instr : CompilerIrInstr]) : OptUsedSet
  (match instr
    [(IrInstrMov _ src _) (opt-collect-value-uses set src)]
    [(IrInstrBinOp _ _ l r _)
      (opt-collect-value-uses (opt-collect-value-uses set l) r)]
    [(IrInstrUnOp _ _ src _) (opt-collect-value-uses set src)]
    [(IrInstrCall _ _ args _) (opt-collect-value-list-uses set args)]
    [(IrInstrTailCall _ args _) (opt-collect-value-list-uses set args)]
    [(IrInstrStore _ value _) (opt-collect-value-uses set value)]
    ;; Pointer/memory ops carry operand uses too; missing any of these would let
    ;; DCE wrongly drop a definition that feeds an address/load/store/cast.
    [(IrInstrAddrOf _ src) (opt-used-add set src)]
    [(IrInstrGep _ base offset _)
      (opt-collect-value-uses (opt-collect-value-uses set base) offset)]
    [(IrInstrLoad _ src _) (opt-collect-value-uses set src)]
    [(IrInstrStorePtr ptr value _)
      (opt-collect-value-uses (opt-collect-value-uses set ptr) value)]
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
    [(IrInstrBranch cond _ _) (opt-collect-value-uses set cond)]
    [(IrInstrReturn maybe)
      (match maybe
        [(IrSomeValue value) (opt-collect-value-uses set value)]
        [(IrNoValue) set])]
    [(IrInstrPhi _ inputs _) (opt-collect-phi-uses set inputs)]
    ;; `IrInstrAlloc` has no operand uses; `IrInstrJump` has none either.
    [_ set]))

(define (opt-collect-instrs-uses
  [set : OptUsedSet]
  [instrs : CompilerIrInstrList]) : OptUsedSet
  (match instrs
    [(IrInstrNil) set]
    [(IrInstrCons instr rest)
      (opt-collect-instrs-uses (opt-collect-instr-uses set instr) rest)]))

(define (opt-collect-blocks-uses
  [set : OptUsedSet]
  [blocks : CompilerIrBlockList]) : OptUsedSet
  (match blocks
    [(IrBlockNil) set]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (opt-collect-blocks-uses (opt-collect-instrs-uses set instrs) rest)])]))

;; A pure temporary-producing instruction is dead when its result var is unused.
;; Calls (side-effecting) and control-flow instructions are never dead here.
(define (opt-instr-dead? [set : OptUsedSet] [instr : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrMov dst _ _) (not (opt-used-contains set dst))]
    [(IrInstrBinOp dst _ _ _ _) (not (opt-used-contains set dst))]
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

(define (opt-dce-instrs [set : OptUsedSet] [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (if (opt-instr-dead? set instr)
        (opt-dce-instrs set rest)
        (IrInstrCons instr (opt-dce-instrs set rest)))]))

(define (opt-dce-block [set : OptUsedSet] [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs) (IrBlock label (opt-dce-instrs set instrs))]))

(define (opt-dce-block-list [set : OptUsedSet] [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (IrBlockCons (opt-dce-block set block) (opt-dce-block-list set rest))]))

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
;; var as an operand — or whose result is that var — is dropped. Calls, stores
;; (`Store`/`StorePtr`), and all control-flow boundaries clear the whole table
;; (conservative, matching the spec). Commutative operands are NOT canonicalized
;; in this slice.
(defenum OptExprKey
  (OptBinKey CompilerIrBinOp CompilerIrValue CompilerIrValue)
  (OptUnKey CompilerIrUnOp CompilerIrValue))

(defenum OptExprTable
  (OptExprNil)
  (OptExprCons OptExprKey i64 OptExprTable))

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
      (match b
        [(AstTypeCons bh bt) (and (opt-type-eq ah bh) (opt-type-list-eq at bt))]
        [_ false])]))

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
    [(AstTyFunc a-params a-ret)
      (match b
        [(AstTyFunc b-params b-ret)
          (and (opt-type-list-eq a-params b-params) (opt-type-eq a-ret b-ret))]
        [_ false])]
    [(AstTyTuple a-items)
      (match b
        [(AstTyTuple b-items) (opt-type-list-eq a-items b-items)]
        [_ false])]
    [(AstTyArray a-item a-len)
      (match b
        [(AstTyArray b-item b-len)
          (and (= a-len b-len) (opt-type-eq a-item b-item))]
        [_ false])]
    [(AstTyDynArray a-item)
      (match b
        [(AstTyDynArray b-item) (opt-type-eq a-item b-item)]
        [_ false])]
    [(AstTyPtr a-item)
      (match b
        [(AstTyPtr b-item) (opt-type-eq a-item b-item)]
        [_ false])]
    [(AstTyMutPtr a-item)
      (match b
        [(AstTyMutPtr b-item) (opt-type-eq a-item b-item)]
        [_ false])]
    [(AstTyRef a-region a-inner)
      (match b
        [(AstTyRef b-region b-inner)
          (and (string-eq a-region b-region) (opt-type-eq a-inner b-inner))]
        [_ false])]
    [(AstTyMutRef a-region a-inner)
      (match b
        [(AstTyMutRef b-region b-inner)
          (and (string-eq a-region b-region) (opt-type-eq a-inner b-inner))]
        [_ false])]
    [(AstTyRegion a-region a-inner)
      (match b
        [(AstTyRegion b-region b-inner)
          (and (string-eq a-region b-region) (opt-type-eq a-inner b-inner))]
        [_ false])]
    [(AstTyEnum a-name)
      (match b
        [(AstTyEnum b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstTyStruct a-name)
      (match b
        [(AstTyStruct b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstTyVar a-name)
      (match b
        [(AstTyVar b-name) (string-eq a-name b-name)]
        [_ false])]))

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
          (and (opt-value-eq ah bh) (opt-value-list-eq at bt))]
        [_ false])]))

(define (opt-phi-input-eq [a : CompilerIrPhiInput] [b : CompilerIrPhiInput]) : bool
  (match a
    [(IrPhiInput av alabel)
      (match b
        [(IrPhiInput bv blabel)
          (and (string-eq alabel blabel) (opt-value-eq av bv))])]))

(define (opt-phi-input-list-eq
  [a : CompilerIrPhiInputList]
  [b : CompilerIrPhiInputList]) : bool
  (match a
    [(IrPhiInputNil)
      (match b
        [(IrPhiInputNil) true]
        [_ false])]
    [(IrPhiInputCons ah at)
      (match b
        [(IrPhiInputCons bh bt)
          (and (opt-phi-input-eq ah bh) (opt-phi-input-list-eq at bt))]
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
    [(IrInstrCall ad aname aargs aty)
      (match b
        [(IrInstrCall bd bname bargs bty)
          (and
            (= ad bd)
            (and
              (string-eq aname bname)
              (and (opt-value-list-eq aargs bargs) (opt-type-eq aty bty))))]
        [_ false])]
    [(IrInstrTailCall aname aargs aty)
      (match b
        [(IrInstrTailCall bname bargs bty)
          (and
            (string-eq aname bname)
            (and (opt-value-list-eq aargs bargs) (opt-type-eq aty bty)))]
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
          (and (opt-instr-eq ah bh) (opt-instr-list-eq at bt))]
        [_ false])]))

(define (opt-block-eq [a : CompilerIrBlock] [b : CompilerIrBlock]) : bool
  (match a
    [(IrBlock alabel ainstrs)
      (match b
        [(IrBlock blabel binstrs)
          (and (string-eq alabel blabel) (opt-instr-list-eq ainstrs binstrs))])]))

(define (opt-block-list-eq [a : CompilerIrBlockList] [b : CompilerIrBlockList]) : bool
  (match a
    [(IrBlockNil)
      (match b
        [(IrBlockNil) true]
        [_ false])]
    [(IrBlockCons ah at)
      (match b
        [(IrBlockCons bh bt)
          (and (opt-block-eq ah bh) (opt-block-list-eq at bt))]
        [_ false])]))

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
          (and (opt-param-eq ah bh) (opt-param-list-eq at bt))]
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
          (and (opt-function-eq ah bh) (opt-function-list-eq at bt))]
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
          (and (opt-global-eq ah bh) (opt-global-list-eq at bt))]
        [_ false])]))

(define (opt-extern-eq [a : CompilerIrExtern] [b : CompilerIrExtern]) : bool
  (match a
    [(IrExtern aname aty aabi asymbol)
      (match b
        [(IrExtern bname bty babi bsymbol)
          (and
            (string-eq aname bname)
            (and
              (opt-type-eq aty bty)
              (and (ast-extern-abi-eq? aabi babi) (string-eq asymbol bsymbol))))])]))

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
          (and (opt-extern-eq ah bh) (opt-extern-list-eq at bt))]
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
      (if (opt-expr-key-eq k key)
        (IrSomeValue (IrValueVar var))
        (opt-expr-lookup rest key))]))

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
        [rest2 : OptExprTable (opt-expr-invalidate-var rest var)]
        (if (or (opt-key-uses-var? k var) (= v var))
          rest2
          (OptExprCons k v rest2)))]))

(defenum OptCseResult
  (OptCseResult OptExprTable CompilerIrInstr))

(define (opt-cse-instr [table : OptExprTable] [instr : CompilerIrInstr]) : OptCseResult
  (match instr
    [(IrInstrBinOp dst op l r ty)
      (let
        [t1 : OptExprTable (opt-expr-invalidate-var table dst)]
        (let
          [key : OptExprKey (OptBinKey op l r)]
          (match (opt-expr-lookup t1 key)
            [(IrSomeValue earlier)
              (OptCseResult t1 (IrInstrMov dst earlier ty))]
            [(IrNoValue) (OptCseResult (OptExprCons key dst t1) instr)])))]
    [(IrInstrUnOp dst op v ty)
      (let
        [t1 : OptExprTable (opt-expr-invalidate-var table dst)]
        (let
          [key : OptExprKey (OptUnKey op v)]
          (match (opt-expr-lookup t1 key)
            [(IrSomeValue earlier)
              (OptCseResult t1 (IrInstrMov dst earlier ty))]
            [(IrNoValue) (OptCseResult (OptExprCons key dst t1) instr)])))]
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
    ;; Calls, stores, and control flow clear all available expressions.
    [(IrInstrCall _ _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrTailCall _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrStore _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrStorePtr _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrVectorStore _ _ _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrPredicatedStore _ _ _ _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrBoundsCheck _ _ _) (OptCseResult table instr)]
    [(IrInstrJump _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrBranch _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrReturn _) (OptCseResult (OptExprNil) instr)]))

(define (opt-cse-instrs [table : OptExprTable] [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (match (opt-cse-instr table instr)
        [(OptCseResult new-table new-instr)
          (IrInstrCons new-instr (opt-cse-instrs new-table rest))])]))

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
  (OptCopyCons i64 CompilerIrValue OptCopyEnv))

(define (opt-copy-lookup [env : OptCopyEnv] [var : i64]) : CompilerIrMaybeValue
  (match env
    [(OptCopyNil) (IrNoValue)]
    [(OptCopyCons id value rest)
      (if (= id var)
        (IrSomeValue value)
        (opt-copy-lookup rest var))]))

;; Drop the mapping for `var` and any mapping whose replacement is `IrValueVar
;; var`, so redefining either a copied destination or a copied source clears the
;; stale copy fact.
(define (opt-copy-invalidate-var [env : OptCopyEnv] [var : i64]) : OptCopyEnv
  (match env
    [(OptCopyNil) (OptCopyNil)]
    [(OptCopyCons id value rest)
      (let
        [rest2 : OptCopyEnv (opt-copy-invalidate-var rest var)]
        (if (or (= id var) (opt-value-is-var? value var))
          rest2
          (OptCopyCons id value rest2)))]))

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
    [(IrValueGlobal _) false]))

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
      (IrValueCons
        (opt-copy-resolve env value)
        (opt-copy-subst-value-list env rest))]))

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
    [(IrInstrCall dst name args ty)
      (IrInstrCall dst name (opt-copy-subst-value-list env args) ty)]
    [(IrInstrTailCall name args ty)
      (IrInstrTailCall name (opt-copy-subst-value-list env args) ty)]
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
    [(IrInstrPhi _ _ _) instr]))

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
          (OptCopyCons dst src e1)
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
    [(IrInstrCall dst _ _ _) (opt-copy-invalidate-var env dst)]
    [(IrInstrPhi dst _ _) (opt-copy-invalidate-var env dst)]
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
          (IrInstrCons new-instr (opt-copy-instrs new-env rest))])]))

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
  (OptBoundsCons OptBoundsFact OptBoundsFacts))

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
      (if (opt-bounds-fact-eq fact index length)
        true
        (opt-bounds-contains rest index length))]))

(define (opt-bounds-add
  [facts : OptBoundsFacts]
  [index : CompilerIrValue]
  [length : CompilerIrValue]) : OptBoundsFacts
  (if (opt-bounds-contains facts index length)
    facts
    (OptBoundsCons (OptBoundsFact index length) facts)))

(define (opt-bounds-fact-uses-var? [fact : OptBoundsFact] [var : i64]) : bool
  (match fact
    [(OptBoundsFact index length)
      (or (opt-value-is-var? index var) (opt-value-is-var? length var))]))

(define (opt-bounds-invalidate-var [facts : OptBoundsFacts] [var : i64]) : OptBoundsFacts
  (match facts
    [(OptBoundsNil) (OptBoundsNil)]
    [(OptBoundsCons fact rest)
      (let
        [rest2 : OptBoundsFacts (opt-bounds-invalidate-var rest var)]
        (if (opt-bounds-fact-uses-var? fact var)
          rest2
          (OptBoundsCons fact rest2)))]))

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
    [(IrInstrCall _ _ _ _) (OptBoundsNil)]
    [(IrInstrTailCall _ _ _) (OptBoundsNil)]
    [(IrInstrStore _ _ _) (OptBoundsNil)]
    [(IrInstrStorePtr _ _ _) (OptBoundsNil)]
    [(IrInstrVectorStore _ _ _ _ _) (OptBoundsNil)]
    [(IrInstrPredicatedStore _ _ _ _ _ _) (OptBoundsNil)]
    [(IrInstrJump _) (OptBoundsNil)]
    [(IrInstrBranch _ _ _) (OptBoundsNil)]
    [(IrInstrReturn _) (OptBoundsNil)]
    [(IrInstrPhi _ _ _) (OptBoundsNil)]
    [(IrInstrBoundsCheck _ _ _) facts]))

(define (opt-bounds-instrs
  [facts : OptBoundsFacts]
  [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrBoundsCheck index length _)
          (if (opt-bounds-contains facts index length)
            (opt-bounds-instrs facts rest)
            (IrInstrCons
              instr
              (opt-bounds-instrs (opt-bounds-add facts index length) rest)))]
        [_
          (IrInstrCons
            instr
            (opt-bounds-instrs (opt-bounds-update-facts facts instr) rest))])]))

;; --- conservative CFG simplification (#926) ---------------------------------
;;
;; Runs after block-local constant/copy propagation has exposed literal branch
;; conditions. It rewrites known boolean branches to jumps, computes reachable
;; blocks from the function entry block, drops unreachable blocks, and trims phi
;; inputs from predecessors that are no longer reachable.
(defenum OptLabelSet
  (OptLabelNil)
  (OptLabelCons String OptLabelSet))

(define (opt-label-contains [set : OptLabelSet] [label : String]) : bool
  (match set
    [(OptLabelNil) false]
    [(OptLabelCons head rest)
      (if (string-eq head label)
        true
        (opt-label-contains rest label))]))

(define (opt-label-add [set : OptLabelSet] [label : String]) : OptLabelSet
  (if (opt-label-contains set label)
    set
    (OptLabelCons label set)))

(define (opt-label-count [set : OptLabelSet]) : i64
  (match set
    [(OptLabelNil) 0]
    [(OptLabelCons _ rest) (+ 1 (opt-label-count rest))]))

(define (opt-label-subset? [a : OptLabelSet] [b : OptLabelSet]) : bool
  (match a
    [(OptLabelNil) true]
    [(OptLabelCons label rest)
      (and (opt-label-contains b label) (opt-label-subset? rest b))]))

(define (opt-label-set-eq? [a : OptLabelSet] [b : OptLabelSet]) : bool
  (and (opt-label-subset? a b) (opt-label-subset? b a)))

(define (opt-label-intersection [a : OptLabelSet] [b : OptLabelSet]) : OptLabelSet
  (match a
    [(OptLabelNil) (OptLabelNil)]
    [(OptLabelCons label rest)
      (let
        [tail : OptLabelSet (opt-label-intersection rest b)]
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
            (opt-cfg-find-block rest label))])]))

(define (opt-cfg-block-exists? [blocks : CompilerIrBlockList] [label : String]) : bool
  (match (opt-cfg-find-block blocks label)
    [(OptSomeBlock _) true]
    [(OptNoBlock) false]))

(define (opt-cfg-entry-label [blocks : CompilerIrBlockList]) : String
  (match blocks
    [(IrBlockNil) ""]
    [(IrBlockCons block _)
      (match block
        [(IrBlock label _) label])]))

(define (opt-cfg-block-labels [blocks : CompilerIrBlockList]) : OptLabelSet
  (match blocks
    [(IrBlockNil) (OptLabelNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _) (opt-label-add (opt-cfg-block-labels rest) label)])]))

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
            (opt-cfg-block-labels-unique-from? rest (opt-label-add seen label)))])]))

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
        (opt-label-subset? (opt-cfg-block-successors block) labels)
        (opt-cfg-successor-targets-known-in-blocks? rest labels))]))

(define (opt-cfg-predecessors [blocks : CompilerIrBlockList] [label : String]) : OptLabelSet
  (match blocks
    [(IrBlockNil) (OptLabelNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock block-label _)
          (let
            [tail : OptLabelSet (opt-cfg-predecessors rest label)]
            (if (opt-label-contains (opt-cfg-block-successors block) label)
              (opt-label-add tail block-label)
              tail))])]))

(define (opt-cfg-filter-blocks-by-labels
  [labels : OptLabelSet]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _)
          (if (opt-label-contains labels label)
            (IrBlockCons block (opt-cfg-filter-blocks-by-labels labels rest))
            (opt-cfg-filter-blocks-by-labels labels rest))])]))

(define (opt-cfg-reachable-block-order [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (opt-cfg-filter-blocks-by-labels (opt-cfg-reachable-blocks blocks) blocks))

(defenum OptDomEntry
  (OptDomEntry String OptLabelSet))

(defenum OptDomTable
  (OptDomNil)
  (OptDomCons OptDomEntry OptDomTable))

(define (opt-dom-table-lookup [table : OptDomTable] [label : String]) : OptLabelSet
  (match table
    [(OptDomNil) (OptLabelNil)]
    [(OptDomCons entry rest)
      (match entry
        [(OptDomEntry entry-label labels)
          (if (string-eq entry-label label)
            labels
            (opt-dom-table-lookup rest label))])]))

(define (opt-dom-entry-eq? [a : OptDomEntry] [b : OptDomEntry]) : bool
  (match a
    [(OptDomEntry a-label a-labels)
      (match b
        [(OptDomEntry b-label b-labels)
          (and
            (string-eq a-label b-label)
            (opt-label-set-eq? a-labels b-labels))])]))

(define (opt-dom-table-eq? [a : OptDomTable] [b : OptDomTable]) : bool
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
            (opt-dom-table-eq? a-rest b-rest))]
        [_ false])]))

(define (opt-dom-intersect-preds-rest
  [table : OptDomTable]
  [preds : OptLabelSet]
  [current : OptLabelSet]) : OptLabelSet
  (match preds
    [(OptLabelNil) current]
    [(OptLabelCons pred rest)
      (opt-dom-intersect-preds-rest
        table
        rest
        (opt-label-intersection current (opt-dom-table-lookup table pred)))]))

(define (opt-dom-intersect-preds [table : OptDomTable] [preds : OptLabelSet]) : OptLabelSet
  (match preds
    [(OptLabelNil) (OptLabelNil)]
    [(OptLabelCons pred rest)
      (opt-dom-intersect-preds-rest
        table
        rest
        (opt-dom-table-lookup table pred))]))

(define (opt-cfg-dominators-initial
  [blocks : CompilerIrBlockList]
  [reachable : OptLabelSet]
  [entry-label : String]
  [all-reachable : OptLabelSet]) : OptDomTable
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
              (opt-cfg-dominators-initial
                rest
                reachable
                entry-label
                all-reachable))
            (opt-cfg-dominators-initial
              rest
              reachable
              entry-label
              all-reachable))])]))

(define (opt-cfg-dominators-step-entry
  [blocks : CompilerIrBlockList]
  [reachable : OptLabelSet]
  [entry-label : String]
  [old : OptDomTable]
  [entry : OptDomEntry]) : OptDomEntry
  (match entry
    [(OptDomEntry label _)
      (if (string-eq label entry-label)
        (OptDomEntry label (opt-label-add (OptLabelNil) label))
        (let
          [preds : OptLabelSet
            (opt-label-intersection
              (opt-cfg-predecessors blocks label)
              reachable)]
          (OptDomEntry
            label
            (opt-label-add (opt-dom-intersect-preds old preds) label))))]))

(define (opt-cfg-dominators-step
  [blocks : CompilerIrBlockList]
  [reachable : OptLabelSet]
  [entry-label : String]
  [old : OptDomTable]
  [remaining : OptDomTable]) : OptDomTable
  (match remaining
    [(OptDomNil) (OptDomNil)]
    [(OptDomCons entry rest)
      (OptDomCons
        (opt-cfg-dominators-step-entry blocks reachable entry-label old entry)
        (opt-cfg-dominators-step blocks reachable entry-label old rest))]))

(define (opt-cfg-dominators-fixed
  [blocks : CompilerIrBlockList]
  [reachable : OptLabelSet]
  [entry-label : String]
  [table : OptDomTable]
  [remaining : i64]) : OptDomTable
  (if (<= remaining 0)
    table
    (let
      [next : OptDomTable
        (opt-cfg-dominators-step blocks reachable entry-label table table)]
      (if (opt-dom-table-eq? table next)
        next
        (opt-cfg-dominators-fixed
          blocks
          reachable
          entry-label
          next
          (- remaining 1))))))

(define (opt-cfg-dominators [blocks : CompilerIrBlockList]) : OptDomTable
  (let
    [reachable : OptLabelSet (opt-cfg-reachable-blocks blocks)]
    [entry-label : String (opt-cfg-entry-label blocks)]
    [initial : OptDomTable
      (opt-cfg-dominators-initial blocks reachable entry-label reachable)]
    (opt-cfg-dominators-fixed
      blocks
      reachable
      entry-label
      initial
      (+ (compiler-ir-block-list-count blocks) 1))))

(define (opt-dom-dominates?
  [table : OptDomTable]
  [dominator : String]
  [label : String]) : bool
  (opt-label-contains (opt-dom-table-lookup table label) dominator))

(define (opt-dom-strict-dominates?
  [table : OptDomTable]
  [dominator : String]
  [label : String]) : bool
  (and
    (not (string-eq dominator label))
    (opt-dom-dominates? table dominator label)))

(define (opt-cfg-frontier-has-pred?
  [doms : OptDomTable]
  [label : String]
  [preds : OptLabelSet]) : bool
  (match preds
    [(OptLabelNil) false]
    [(OptLabelCons pred rest)
      (if (opt-dom-dominates? doms label pred)
        true
        (opt-cfg-frontier-has-pred? doms label rest))]))

(define (opt-cfg-dominance-frontier-blocks
  [all-blocks : CompilerIrBlockList]
  [remaining : CompilerIrBlockList]
  [reachable : OptLabelSet]
  [doms : OptDomTable]
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
                rest
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
                    (opt-cfg-predecessors all-blocks block-label)
                    reachable))
                (not (opt-dom-strict-dominates? doms label block-label))))
              (opt-label-add tail block-label)
              tail))])]))

(define (opt-cfg-dominance-frontier
  [blocks : CompilerIrBlockList]
  [label : String]) : OptLabelSet
  (let
    [reachable : OptLabelSet (opt-cfg-reachable-blocks blocks)]
    [doms : OptDomTable (opt-cfg-dominators blocks)]
    (opt-cfg-dominance-frontier-blocks blocks blocks reachable doms label)))

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
  (OptVarDefCons OptVarDef OptVarDefList))

(defenum OptMaybeVarDef
  (OptNoVarDef)
  (OptSomeVarDef OptVarDef))

(defenum OptVarSetResult
  (OptVarSetOk OptUsedSet)
  (OptVarSetErr))

(define (opt-var-set-add-unique [set : OptUsedSet] [var : i64]) : OptVarSetResult
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
    [(IrInstrCall dst _ _ _) (OptSomeI64 dst)]
    [(IrInstrPhi dst _ _) (OptSomeI64 dst)]
    [_ (OptNoI64)]))

(define (opt-instr-def-position [instr : CompilerIrInstr] [pos : i64]) : i64
  (match instr
    [(IrInstrPhi _ _ _) 0]
    [_ pos]))

(define (opt-verify-param-def-set
  [params : CompilerIrParamList]
  [set : OptUsedSet]) : OptVarSetResult
  (match params
    [(IrParamNil) (OptVarSetOk set)]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ _ var)
          (match (opt-var-set-add-unique set var)
            [(OptVarSetOk next) (opt-verify-param-def-set rest next)]
            [(OptVarSetErr) (OptVarSetErr)])])]))

(define (opt-verify-instr-def-set
  [instrs : CompilerIrInstrList]
  [set : OptUsedSet]) : OptVarSetResult
  (match instrs
    [(IrInstrNil) (OptVarSetOk set)]
    [(IrInstrCons instr rest)
      (match (opt-instr-def-var instr)
        [(OptSomeI64 var)
          (match (opt-var-set-add-unique set var)
            [(OptVarSetOk next) (opt-verify-instr-def-set rest next)]
            [(OptVarSetErr) (OptVarSetErr)])]
        [(OptNoI64) (opt-verify-instr-def-set rest set)])]))

(define (opt-verify-block-def-set
  [blocks : CompilerIrBlockList]
  [set : OptUsedSet]) : OptVarSetResult
  (match blocks
    [(IrBlockNil) (OptVarSetOk set)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (match (opt-verify-instr-def-set instrs set)
            [(OptVarSetOk next) (opt-verify-block-def-set rest next)]
            [(OptVarSetErr) (OptVarSetErr)])])]))

(define (opt-verify-single-defs?
  [params : CompilerIrParamList]
  [blocks : CompilerIrBlockList]) : bool
  (match (opt-verify-param-def-set params (OptUsedNil))
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
            rest
            entry-label
            (OptVarDefCons (OptVarDef var entry-label 0) defs))])]))

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
            rest
            block-label
            (+ pos 1)
            (OptVarDefCons
              (OptVarDef var block-label (opt-instr-def-position instr pos))
              defs))]
        [(OptNoI64) (opt-var-defs-from-instrs rest block-label (+ pos 1) defs)])]))

(define (opt-var-defs-from-blocks
  [blocks : CompilerIrBlockList]
  [defs : OptVarDefList]) : OptVarDefList
  (match blocks
    [(IrBlockNil) defs]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (opt-var-defs-from-blocks
            rest
            (opt-var-defs-from-instrs instrs label 1 defs))])]))

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
            (opt-var-def-lookup rest var))])]))

(define (opt-verify-var-use
  [defs : OptVarDefList]
  [doms : OptDomTable]
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
  [doms : OptDomTable]
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
  [doms : OptDomTable]
  [value : CompilerIrValue]
  [use-block : String]
  [use-pos : i64]) : ResultCompilerOptimizeVerify
  (match value
    [(IrValueVar var) (opt-verify-var-use defs doms var use-block use-pos)]
    [_ (OkCompilerOptimizeVerify)]))

(define (opt-verify-value-list-uses
  [defs : OptVarDefList]
  [doms : OptDomTable]
  [values : CompilerIrValueList]
  [use-block : String]
  [use-pos : i64]) : ResultCompilerOptimizeVerify
  (match values
    [(IrValueNil) (OkCompilerOptimizeVerify)]
    [(IrValueCons value rest)
      (match (opt-verify-value-use defs doms value use-block use-pos)
        [(OkCompilerOptimizeVerify)
          (opt-verify-value-list-uses defs doms rest use-block use-pos)]
        [(ErrCompilerOptimizeVerify message)
          (ErrCompilerOptimizeVerify message)])]))

(define (opt-verify-maybe-value-use
  [defs : OptVarDefList]
  [doms : OptDomTable]
  [value : CompilerIrMaybeValue]
  [use-block : String]
  [use-pos : i64]) : ResultCompilerOptimizeVerify
  (match value
    [(IrNoValue) (OkCompilerOptimizeVerify)]
    [(IrSomeValue inner)
      (opt-verify-value-use defs doms inner use-block use-pos)]))

(define (opt-verify-phi-input-uses
  [defs : OptVarDefList]
  [doms : OptDomTable]
  [inputs : CompilerIrPhiInputList]) : ResultCompilerOptimizeVerify
  (match inputs
    [(IrPhiInputNil) (OkCompilerOptimizeVerify)]
    [(IrPhiInputCons input rest)
      (match input
        [(IrPhiInput value pred-label)
          (match value
            [(IrValueVar var)
              (match (opt-verify-var-use-on-edge defs doms var pred-label)
                [(OkCompilerOptimizeVerify)
                  (opt-verify-phi-input-uses defs doms rest)]
                [(ErrCompilerOptimizeVerify message)
                  (ErrCompilerOptimizeVerify message)])]
            [_ (opt-verify-phi-input-uses defs doms rest)])])]))

(define (opt-verify-two
  [a : ResultCompilerOptimizeVerify]
  [b : ResultCompilerOptimizeVerify]) : ResultCompilerOptimizeVerify
  (match a
    [(OkCompilerOptimizeVerify) b]
    [(ErrCompilerOptimizeVerify message) (ErrCompilerOptimizeVerify message)]))

(define (opt-verify-instr-uses
  [defs : OptVarDefList]
  [doms : OptDomTable]
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
    [(IrInstrCall _ _ args _)
      (opt-verify-value-list-uses defs doms args block-label pos)]
    [(IrInstrTailCall _ args _)
      (opt-verify-value-list-uses defs doms args block-label pos)]
    [(IrInstrStore _ value _)
      (opt-verify-value-use defs doms value block-label pos)]
    [(IrInstrBranch cond _ _)
      (opt-verify-value-use defs doms cond block-label pos)]
    [(IrInstrReturn maybe)
      (opt-verify-maybe-value-use defs doms maybe block-label pos)]
    [(IrInstrPhi _ inputs _) (opt-verify-phi-input-uses defs doms inputs)]
    [(IrInstrAlloc _ _) (OkCompilerOptimizeVerify)]
    [(IrInstrLaneId _ _ _) (OkCompilerOptimizeVerify)]
    [(IrInstrJump _) (OkCompilerOptimizeVerify)]))

(define (opt-verify-instr-list-uses
  [defs : OptVarDefList]
  [doms : OptDomTable]
  [block-label : String]
  [instrs : CompilerIrInstrList]
  [pos : i64]) : ResultCompilerOptimizeVerify
  (match instrs
    [(IrInstrNil) (OkCompilerOptimizeVerify)]
    [(IrInstrCons instr rest)
      (match (opt-verify-instr-uses defs doms block-label pos instr)
        [(OkCompilerOptimizeVerify)
          (opt-verify-instr-list-uses defs doms block-label rest (+ pos 1))]
        [(ErrCompilerOptimizeVerify message)
          (ErrCompilerOptimizeVerify message)])]))

(define (opt-phi-input-labels [inputs : CompilerIrPhiInputList]) : OptLabelSet
  (match inputs
    [(IrPhiInputNil) (OptLabelNil)]
    [(IrPhiInputCons input rest)
      (match input
        [(IrPhiInput _ label) (opt-label-add (opt-phi-input-labels rest) label)])]))

(define (opt-phi-input-labels-unique-from?
  [inputs : CompilerIrPhiInputList]
  [seen : OptLabelSet]) : bool
  (match inputs
    [(IrPhiInputNil) true]
    [(IrPhiInputCons input rest)
      (match input
        [(IrPhiInput _ label)
          (if (opt-label-contains seen label)
            false
            (opt-phi-input-labels-unique-from? rest (opt-label-add seen label)))])]))

(define (opt-phi-input-labels-match?
  [inputs : CompilerIrPhiInputList]
  [preds : OptLabelSet]) : bool
  (and
    (opt-phi-input-labels-unique-from? inputs (OptLabelNil))
    (opt-label-set-eq? (opt-phi-input-labels inputs) preds)))

(define (opt-verify-phi-predecessors-instrs
  [blocks : CompilerIrBlockList]
  [block-label : String]
  [instrs : CompilerIrInstrList]) : ResultCompilerOptimizeVerify
  (match instrs
    [(IrInstrNil) (OkCompilerOptimizeVerify)]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrPhi _ inputs _)
          (if (opt-phi-input-labels-match?
            inputs
            (opt-cfg-predecessors blocks block-label))
            (opt-verify-phi-predecessors-instrs blocks block-label rest)
            (ErrCompilerOptimizeVerify
              "optimizer verify: phi predecessor mismatch"))]
        [_ (opt-verify-phi-predecessors-instrs blocks block-label rest)])]))

(define (opt-verify-phi-predecessors-blocks
  [blocks : CompilerIrBlockList]
  [remaining : CompilerIrBlockList]) : ResultCompilerOptimizeVerify
  (match remaining
    [(IrBlockNil) (OkCompilerOptimizeVerify)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (match (opt-verify-phi-predecessors-instrs blocks label instrs)
            [(OkCompilerOptimizeVerify)
              (opt-verify-phi-predecessors-blocks blocks rest)]
            [(ErrCompilerOptimizeVerify message)
              (ErrCompilerOptimizeVerify message)])])]))

(define (opt-verify-block-uses
  [defs : OptVarDefList]
  [doms : OptDomTable]
  [blocks : CompilerIrBlockList]) : ResultCompilerOptimizeVerify
  (match blocks
    [(IrBlockNil) (OkCompilerOptimizeVerify)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (match (opt-verify-instr-list-uses defs doms label instrs 1)
            [(OkCompilerOptimizeVerify) (opt-verify-block-uses defs doms rest)]
            [(ErrCompilerOptimizeVerify message)
              (ErrCompilerOptimizeVerify message)])])]))

(define (opt-verify-function [func : CompilerIrFunction]) : ResultCompilerOptimizeVerify
  (match func
    [(IrFunction _ params _ _ blocks)
      (cond
        [(not (opt-cfg-block-labels-unique? blocks))
          (ErrCompilerOptimizeVerify "optimizer verify: duplicate block label")]
        [(not (opt-cfg-successor-targets-known? blocks))
          (ErrCompilerOptimizeVerify
            "optimizer verify: unknown successor label")]
        [(not (opt-verify-single-defs? params blocks))
          (ErrCompilerOptimizeVerify
            "optimizer verify: duplicate var definition")]
        [else
          (let
            [doms : OptDomTable (opt-cfg-dominators blocks)]
            [defs : OptVarDefList (opt-var-defs-from-function params blocks)]
            (match (opt-verify-phi-predecessors-blocks blocks blocks)
              [(OkCompilerOptimizeVerify)
                (opt-verify-block-uses defs doms blocks)]
              [(ErrCompilerOptimizeVerify message)
                (ErrCompilerOptimizeVerify message)]))])]))

(define (opt-verify-function-list [functions : CompilerIrFunctionList]) : ResultCompilerOptimizeVerify
  (match functions
    [(IrFunctionNil) (OkCompilerOptimizeVerify)]
    [(IrFunctionCons func rest)
      (match (opt-verify-function func)
        [(OkCompilerOptimizeVerify) (opt-verify-function-list rest)]
        [(ErrCompilerOptimizeVerify message)
          (ErrCompilerOptimizeVerify message)])]))

(define (opt-verify-program [program : CompilerIrProgram]) : ResultCompilerOptimizeVerify
  (match program
    [(IrProgram _ functions _) (opt-verify-function-list functions)]))

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

(define (opt-cfg-fold-branches-instrs [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (IrInstrCons
        (opt-cfg-fold-branch instr)
        (opt-cfg-fold-branches-instrs rest))]))

(define (opt-cfg-fold-branches-block [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      (IrBlock label (opt-cfg-fold-branches-instrs instrs))]))

(define (opt-cfg-fold-branches-blocks [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (IrBlockCons
        (opt-cfg-fold-branches-block block)
        (opt-cfg-fold-branches-blocks rest))]))

(define (opt-cfg-instr-successors [set : OptLabelSet] [instr : CompilerIrInstr]) : OptLabelSet
  (match instr
    [(IrInstrJump label) (opt-label-add set label)]
    [(IrInstrBranch _ true-label false-label)
      (opt-label-add (opt-label-add set true-label) false-label)]
    [_ set]))

(define (opt-cfg-instrs-successors
  [set : OptLabelSet]
  [instrs : CompilerIrInstrList]) : OptLabelSet
  (match instrs
    [(IrInstrNil) set]
    [(IrInstrCons instr rest)
      (opt-cfg-instrs-successors (opt-cfg-instr-successors set instr) rest)]))

(define (opt-cfg-block-successors [block : CompilerIrBlock]) : OptLabelSet
  (match block
    [(IrBlock _ instrs) (opt-cfg-instrs-successors (OptLabelNil) instrs)]))

(define (opt-cfg-blocks-successors
  [blocks : CompilerIrBlockList]
  [label : String]) : OptLabelSet
  (match blocks
    [(IrBlockNil) (OptLabelNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock block-label _)
          (if (string-eq block-label label)
            (opt-cfg-block-successors block)
            (opt-cfg-blocks-successors rest label))])]))

(define (opt-cfg-reachable-label
  [blocks : CompilerIrBlockList]
  [label : String]
  [seen : OptLabelSet]) : OptLabelSet
  (if (opt-label-contains seen label)
    seen
    (opt-cfg-reachable-label-list
      blocks
      (opt-cfg-blocks-successors blocks label)
      (opt-label-add seen label))))

(define (opt-cfg-reachable-label-list
  [blocks : CompilerIrBlockList]
  [labels : OptLabelSet]
  [seen : OptLabelSet]) : OptLabelSet
  (match labels
    [(OptLabelNil) seen]
    [(OptLabelCons label rest)
      (opt-cfg-reachable-label-list
        blocks
        rest
        (opt-cfg-reachable-label blocks label seen))]))

(define (opt-cfg-reachable-blocks [blocks : CompilerIrBlockList]) : OptLabelSet
  (match blocks
    [(IrBlockNil) (OptLabelNil)]
    [(IrBlockCons block _)
      (match block
        [(IrBlock label _) (opt-cfg-reachable-label blocks label (OptLabelNil))])]))

(define (opt-cfg-filter-phi-inputs
  [reachable : OptLabelSet]
  [inputs : CompilerIrPhiInputList]) : CompilerIrPhiInputList
  (match inputs
    [(IrPhiInputNil) (IrPhiInputNil)]
    [(IrPhiInputCons input rest)
      (match input
        [(IrPhiInput _ label)
          (if (opt-label-contains reachable label)
            (IrPhiInputCons input (opt-cfg-filter-phi-inputs reachable rest))
            (opt-cfg-filter-phi-inputs reachable rest))])]))

(define (opt-phi-input-count [inputs : CompilerIrPhiInputList]) : i64
  (match inputs
    [(IrPhiInputNil) 0]
    [(IrPhiInputCons _ rest) (+ 1 (opt-phi-input-count rest))]))

(define (opt-phi-single-value [inputs : CompilerIrPhiInputList]) : CompilerIrMaybeValue
  (match inputs
    [(IrPhiInputCons input rest)
      (match rest
        [(IrPhiInputNil)
          (match input
            [(IrPhiInput value _) (IrSomeValue value)])]
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

(define (opt-cfg-clean-instrs
  [reachable : OptLabelSet]
  [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
      (IrInstrCons
        (opt-cfg-clean-instr reachable instr)
        (opt-cfg-clean-instrs reachable rest))]))

(define (opt-cfg-clean-block
  [reachable : OptLabelSet]
  [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      (IrBlock label (opt-cfg-clean-instrs reachable instrs))]))

(define (opt-cfg-filter-clean-blocks
  [reachable : OptLabelSet]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _)
          (if (opt-label-contains reachable label)
            (IrBlockCons
              (opt-cfg-clean-block reachable block)
              (opt-cfg-filter-clean-blocks reachable rest))
            (opt-cfg-filter-clean-blocks reachable rest))])]))

(define (opt-cfg-simplify-blocks [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (let
    [folded : CompilerIrBlockList (opt-cfg-fold-branches-blocks blocks)]
    (let
      [reachable : OptLabelSet (opt-cfg-reachable-blocks folded)]
      (opt-cfg-filter-clean-blocks reachable folded))))

(defenum OptFunctionPassResult
  (OptFunctionPassResult CompilerIrFunction bool))

(define (optimize-function-max-iterations) : i64
  10)

(define (optimize-block [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      ;; Fold scalar constants, reduce algebraic identities, eliminate repeated
      ;; pure expressions, propagate the resulting copies, then remove duplicate
      ;; proven bounds checks; function-level DCE drops dead copies.
      (IrBlock
        label
        (opt-bounds-instrs
          (OptBoundsNil)
          (opt-copy-instrs
            (OptCopyNil)
            (opt-cse-instrs
              (OptExprNil)
              (opt-strength-instrs
                (OptConstNil)
                (opt-fold-instrs (OptConstNil) instrs))))))]))

(define (optimize-block-list [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (IrBlockCons (optimize-block block) (optimize-block-list rest))]))

(define (optimize-function-once [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(IrFunction name params ret-ty frame blocks)
      ;; Fold first (folding can expose constant branches and turn temporaries
      ;; dead), simplify the CFG, then collect uses across the reachable function
      ;; and eliminate dead pure assignments.
      (let
        [folded : CompilerIrBlockList (optimize-block-list blocks)]
        (let
          [cfg : CompilerIrBlockList (opt-cfg-simplify-blocks folded)]
          (let
            [used : OptUsedSet (opt-collect-blocks-uses (OptUsedNil) cfg)]
            (IrFunction name params ret-ty frame (opt-dce-block-list used cfg)))))]))

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

(define (optimize-function-with-level [func : CompilerIrFunction] [level : i64]) : CompilerIrFunction
  (if (= level 0)
    func
    (if (= level 1)
      (optimize-function-once func)
      (optimize-function func))))

(define (optimize-function-list [funcs : CompilerIrFunctionList]) : CompilerIrFunctionList
  (optimize-function-list-with-level funcs (compiler-optimize-default-level)))

(define (optimize-function-list-with-level
  [funcs : CompilerIrFunctionList]
  [level : i64]) : CompilerIrFunctionList
  (match funcs
    [(IrFunctionNil) (IrFunctionNil)]
    [(IrFunctionCons func rest)
      (IrFunctionCons
        (optimize-function-with-level func level)
        (optimize-function-list-with-level rest level))]))

(defenum OptStringSet
  (OptStringNil)
  (OptStringCons String OptStringSet))

(defenum OptMaybeFunction
  (OptNoFunction)
  (OptSomeFunction CompilerIrFunction))

(defenum OptReachState
  (OptReachState OptStringSet OptStringSet))

(define (opt-string-set-contains?
  [items : OptStringSet]
  [name : String]) : bool
  (match items
    [(OptStringNil) false]
    [(OptStringCons item rest)
      (if (string-eq item name)
        true
        (opt-string-set-contains? rest name))]))

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
            (opt-function-list-defines? rest name))])]))

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
            (opt-function-list-find rest name))])]))

(define (opt-reach-add-function
  [functions : CompilerIrFunctionList]
  [state : OptReachState]
  [name : String]) : OptReachState
  (match state
    [(OptReachState reachable worklist)
      (if (opt-function-list-defines? functions name)
        (if (opt-string-set-contains? reachable name)
          state
          (OptReachState
            (OptStringCons name reachable)
            (OptStringCons name worklist)))
        state)]))

(define (opt-reach-value
  [functions : CompilerIrFunctionList]
  [state : OptReachState]
  [value : CompilerIrValue]) : OptReachState
  (match value
    [(IrValueGlobal name) (opt-reach-add-function functions state name)]
    [_ state]))

(define (opt-reach-value-list
  [functions : CompilerIrFunctionList]
  [state : OptReachState]
  [values : CompilerIrValueList]) : OptReachState
  (match values
    [(IrValueNil) state]
    [(IrValueCons value rest)
      (opt-reach-value-list
        functions
        (opt-reach-value functions state value)
        rest)]))

(define (opt-reach-maybe-value
  [functions : CompilerIrFunctionList]
  [state : OptReachState]
  [maybe : CompilerIrMaybeValue]) : OptReachState
  (match maybe
    [(IrNoValue) state]
    [(IrSomeValue value) (opt-reach-value functions state value)]))

(define (opt-reach-phi-inputs
  [functions : CompilerIrFunctionList]
  [state : OptReachState]
  [inputs : CompilerIrPhiInputList]) : OptReachState
  (match inputs
    [(IrPhiInputNil) state]
    [(IrPhiInputCons input rest)
      (match input
        [(IrPhiInput value _)
          (opt-reach-phi-inputs
            functions
            (opt-reach-value functions state value)
            rest)])]))

(define (opt-reach-instr
  [functions : CompilerIrFunctionList]
  [state : OptReachState]
  [instr : CompilerIrInstr]) : OptReachState
  (match instr
    [(IrInstrMov _ src _) (opt-reach-value functions state src)]
    [(IrInstrAlloc _ _) state]
    [(IrInstrAddrOf _ _) state]
    [(IrInstrGep _ base offset _)
      (opt-reach-value
        functions
        (opt-reach-value functions state base)
        offset)]
    [(IrInstrLoad _ src _) (opt-reach-value functions state src)]
    [(IrInstrStorePtr dst src _)
      (opt-reach-value
        functions
        (opt-reach-value functions state dst)
        src)]
    [(IrInstrBoundsCheck index length _)
      (opt-reach-value
        functions
        (opt-reach-value functions state index)
        length)]
    [(IrInstrCast _ src _ _) (opt-reach-value functions state src)]
    [(IrInstrBinOp _ _ lhs rhs _)
      (opt-reach-value
        functions
        (opt-reach-value functions state lhs)
        rhs)]
    [(IrInstrUnOp _ _ src _) (opt-reach-value functions state src)]
    [(IrInstrLaneId _ _ _) state]
    [(IrInstrSplat _ value _ _) (opt-reach-value functions state value)]
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (opt-reach-value
        functions
        (opt-reach-value functions state lhs)
        rhs)]
    [(IrInstrVectorReduce _ _ src _ _) (opt-reach-value functions state src)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (opt-reach-value
        functions
        (opt-reach-value functions state lhs)
        rhs)]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (opt-reach-value
        functions
        (opt-reach-value functions state lhs)
        rhs)]
    [(IrInstrMaskNot _ src _) (opt-reach-value functions state src)]
    [(IrInstrMaskReduce _ _ src _) (opt-reach-value functions state src)]
    [(IrInstrSelect _ mask on-true on-false _ _)
      (opt-reach-value
        functions
        (opt-reach-value
          functions
          (opt-reach-value functions state mask)
          on-true)
        on-false)]
    [(IrInstrVectorLoad _ base index _ _)
      (opt-reach-value
        functions
        (opt-reach-value functions state base)
        index)]
    [(IrInstrVectorStore base index value _ _)
      (opt-reach-value
        functions
        (opt-reach-value
          functions
          (opt-reach-value functions state base)
          index)
        value)]
    [(IrInstrPredicatedStore base index value mask _ _)
      (opt-reach-value
        functions
        (opt-reach-value
          functions
          (opt-reach-value
            functions
            (opt-reach-value functions state base)
            index)
          value)
        mask)]
    [(IrInstrPredicatedLoad _ base index mask _ _)
      (opt-reach-value
        functions
        (opt-reach-value
          functions
          (opt-reach-value functions state base)
          index)
        mask)]
    [(IrInstrTailMask _ index length _)
      (opt-reach-value
        functions
        (opt-reach-value functions state index)
        length)]
    [(IrInstrCall _ name args _)
      (opt-reach-add-function
        functions
        (opt-reach-value-list functions state args)
        name)]
    [(IrInstrStore _ value _) (opt-reach-value functions state value)]
    [(IrInstrJump _) state]
    [(IrInstrBranch cond _ _) (opt-reach-value functions state cond)]
    [(IrInstrReturn maybe) (opt-reach-maybe-value functions state maybe)]
    [(IrInstrPhi _ inputs _) (opt-reach-phi-inputs functions state inputs)]))

(define (opt-reach-instrs
  [functions : CompilerIrFunctionList]
  [state : OptReachState]
  [instrs : CompilerIrInstrList]) : OptReachState
  (match instrs
    [(IrInstrNil) state]
    [(IrInstrCons instr rest)
      (opt-reach-instrs
        functions
        (opt-reach-instr functions state instr)
        rest)]))

(define (opt-reach-blocks
  [functions : CompilerIrFunctionList]
  [state : OptReachState]
  [blocks : CompilerIrBlockList]) : OptReachState
  (match blocks
    [(IrBlockNil) state]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (opt-reach-blocks
            functions
            (opt-reach-instrs functions state instrs)
            rest)])]))

(define (opt-reach-function
  [functions : CompilerIrFunctionList]
  [state : OptReachState]
  [func : CompilerIrFunction]) : OptReachState
  (match func
    [(IrFunction _ _ _ _ blocks) (opt-reach-blocks functions state blocks)]))

(define (opt-reach-process
  [functions : CompilerIrFunctionList]
  [state : OptReachState]) : OptReachState
  (match state
    [(OptReachState reachable worklist)
      (match worklist
        [(OptStringNil) state]
        [(OptStringCons name rest)
          (let
            [popped : OptReachState (OptReachState reachable rest)]
            (match (opt-function-list-find functions name)
              [(OptSomeFunction func)
                (opt-reach-process
                  functions
                  (opt-reach-function functions popped func))]
              [(OptNoFunction) (opt-reach-process functions popped)]))])]))

(define (opt-reach-global
  [functions : CompilerIrFunctionList]
  [state : OptReachState]
  [global : CompilerIrGlobal]) : OptReachState
  (match global
    [(IrGlobal _ _ value) (opt-reach-value functions state value)]))

(define (opt-reach-globals
  [functions : CompilerIrFunctionList]
  [state : OptReachState]
  [globals : CompilerIrGlobalList]) : OptReachState
  (match globals
    [(IrGlobalNil) state]
    [(IrGlobalCons global rest)
      (opt-reach-globals
        functions
        (opt-reach-global functions state global)
        rest)]))

(define (opt-filter-reachable-functions
  [functions : CompilerIrFunctionList]
  [reachable : OptStringSet]) : CompilerIrFunctionList
  (match functions
    [(IrFunctionNil) (IrFunctionNil)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction name _ _ _ _)
          (if (opt-string-set-contains? reachable name)
            (IrFunctionCons
              func
              (opt-filter-reachable-functions rest reachable))
            (opt-filter-reachable-functions rest reachable))])]))

(define (opt-prune-unreachable-functions
  [globals : CompilerIrGlobalList]
  [functions : CompilerIrFunctionList]) : CompilerIrFunctionList
  (if (opt-function-list-defines? functions "main")
    (match
      (opt-reach-process
        functions
        (opt-reach-globals
          functions
          (opt-reach-add-function
            functions
            (OptReachState (OptStringNil) (OptStringNil))
            "main")
          globals))
      [(OptReachState reachable _)
        (opt-filter-reachable-functions functions reachable)])
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
        (if (= level 1)
          (IrProgram
            globals
            (optimize-function-list-with-level functions level)
            externs)
          (let
            [reachable-functions : CompilerIrFunctionList
              (opt-prune-unreachable-functions globals functions)]
            (let
              [optimized-functions : CompilerIrFunctionList
                (optimize-function-list-with-level reachable-functions level)]
              (IrProgram
                globals
                (opt-prune-unreachable-functions globals optimized-functions)
                externs)))))]))

(define (opt-remap-spans-prepend-entry
  [spans : CompilerSourceSpans]
  [key : String]
  [span : AstSourceSpan]) : CompilerSourceSpans
  (match spans
    [(CompilerSourceSpans entries instr-entries)
      (CompilerSourceSpans
        entries
        (CompilerSourceSpansEntryCons
          (CompilerSourceSpansEntry key span)
          instr-entries))]))

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
        rest)]))

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
            (opt-remap-spans-instrs source-spans out function instrs)
            function
            rest)])]))

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
        rest)]))

(define (opt-remap-spans-fast-path? [source-spans : CompilerSourceSpans]) : bool
  (> (compiler-source-spans-instr-count source-spans) 2048))

(define (opt-remap-spans-program
  [source-spans : CompilerSourceSpans]
  [program : CompilerIrProgram]) : CompilerSourceSpans
  (if (opt-remap-spans-fast-path? source-spans)
    source-spans
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
  (let
    [optimized : CompilerIrProgram (optimize-program-with-level program level)]
    (CompilerOptimizedProgram
      optimized
      (opt-remap-spans-program spans optimized))))

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
      (+ (opt-arith-instr-count instr) (opt-count-arith-instrs rest))]))

(define (opt-arith-instr-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrBinOp _ _ _ _ _) 1]
    [(IrInstrUnOp _ _ _ _) 1]
    [_ 0]))

(define (opt-sum-mov-i64 [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+ (opt-mov-i64-value instr) (opt-sum-mov-i64 rest))]))

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
        (opt-count-mov-i64-value rest needle))]))

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
        (opt-count-mov-bool-value rest needle))]))

(define (opt-sum-mov-var-src [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrMov _ (IrValueVar id) _) id]
          [_ 0])
        (opt-sum-mov-var-src rest))]))

(define (opt-mov-dst-type-tag [instrs : CompilerIrInstrList] [dst : i64]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrMov d _ ty)
          (if (= d dst)
            (ast-type-tag ty)
            (opt-mov-dst-type-tag rest dst))]
        [_ (opt-mov-dst-type-tag rest dst)])]))

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
            (opt-mov-dst-i64-value rest dst fallback))]
        [_ (opt-mov-dst-i64-value rest dst fallback)])]))

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
            (opt-mov-dst-bool-value? rest dst needle))]
        [_ (opt-mov-dst-bool-value? rest dst needle)])]))

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
            (opt-mov-dst-char-code rest dst fallback))]
        [_ (opt-mov-dst-char-code rest dst fallback)])]))

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
    (IrBlockCons (IrBlock "entry" instrs) IrBlockNil)))

(define (opt-spans-program [instrs : CompilerIrInstrList]) : CompilerIrProgram
  (IrProgram
    IrGlobalNil
    (IrFunctionCons (opt-spans-function instrs) IrFunctionNil)
    IrExternNil))

(define (opt-spans-base) : CompilerSourceSpans
  (compiler-source-spans-insert
    (compiler-source-spans-empty)
    "main"
    (opt-test-span 3 1)))

(define (compiler-optimize-spans-dce-ok?) : bool
  (let
    [dead : CompilerIrInstr (IrInstrMov 0 (IrValueI64 1) (AstTyI64))]
    [live : CompilerIrInstr (IrInstrCall 1 "opaque" IrValueNil (AstTyI64))]
    [instrs : CompilerIrInstrList
      (IrInstrCons
        dead
        (IrInstrCons
          live
          (IrInstrCons (IrInstrReturn (IrSomeValue (IrValueVar 1))) IrInstrNil)))]
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
      (IrInstrCons
        folded
        (IrInstrCons
          (IrInstrAddrOf 3 2)
          (IrInstrCons (IrInstrReturn (IrSomeValue (IrValueVar 3))) IrInstrNil)))]
    [spans : CompilerSourceSpans
      (compiler-source-spans-insert-instr
        (opt-spans-base)
        "main"
        folded
        (opt-test-span 41 7))]
    (match (optimize-program-with-spans-and-level
      (opt-spans-program instrs)
      spans
      1)
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
      (IrInstrCons
        first
        (IrInstrCons
          second
          (IrInstrCons
            (IrInstrAddrOf 4 3)
            (IrInstrCons
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
      1)
      [(CompilerOptimizedProgram _ optimized-spans)
        (and
          (opt-span-lookup-ok? optimized-spans "main" first 51 9)
          (opt-span-lookup-ok? optimized-spans "main" rewritten 61 11))])))

(define (compiler-optimize-spans-self-test) : i64
  (if (and
    (compiler-optimize-spans-dce-ok?)
    (and (compiler-optimize-spans-fold-ok?) (compiler-optimize-spans-cse-ok?)))
    42
    1))

(define (opt-count-cast-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrCast _ _ _ _) 1]
          [_ 0])
        (opt-count-cast-instrs rest))]))

;; Builds `[Mov v0=20, Mov v1=22, BinOp v2 = v0 + v1]` (one arithmetic instr).
(define (opt-self-test-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 0 (IrValueI64 20) (AstTyI64))
    (IrInstrCons
      (IrInstrMov 1 (IrValueI64 22) (AstTyI64))
      (IrInstrCons
        (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
        (IrInstrNil)))))

(define (opt-stale-load-test-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 0 (IrValueI64 41) (AstTyI64))
    (IrInstrCons
      (IrInstrLoad 0 (IrValueVar 9) (AstTyI64))
      (IrInstrCons
        (IrInstrBinOp 1 (IrBinAdd) (IrValueVar 0) (IrValueI64 1) (AstTyI64))
        (IrInstrNil)))))

(define (opt-vector-mask-test-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 0 (IrValueI64 3) (AstTyI64))
    (IrInstrCons
      (IrInstrMov 1 (IrValueI64 4) (AstTyI64))
      (IrInstrCons
        (IrInstrSplat 2 (IrValueVar 0) 4 (AstTyI64))
        (IrInstrCons
          (IrInstrLaneId 3 4 (AstTyI64))
          (IrInstrCons
            (IrInstrTailMask 4 (IrValueVar 0) (IrValueVar 1) 4)
            (IrInstrCons
              (IrInstrVectorBinOp
                5
                (IrBinAdd)
                (IrValueVar 2)
                (IrValueVar 3)
                4
                (AstTyI64))
              (IrInstrCons
                (IrInstrSelect
                  6
                  (IrValueVar 4)
                  (IrValueVar 5)
                  (IrValueVar 2)
                  4
                  (AstTyI64))
                (IrInstrCons
                  (IrInstrPredicatedStore
                    (IrValueVar 8)
                    (IrValueVar 0)
                    (IrValueVar 6)
                    (IrValueVar 4)
                    4
                    (AstTyI64))
                  IrInstrNil)))))))))

(define (opt-vector-cse-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrVectorBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) 4 (AstTyI64))
    (IrInstrCons
      (IrInstrVectorBinOp
        3
        (IrBinAdd)
        (IrValueVar 0)
        (IrValueVar 1)
        4
        (AstTyI64))
      IrInstrNil)))

(define (opt-vector-reduce-cse-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrVectorReduce 1 (IrVectorReduceSum) (IrValueVar 0) 4 (AstTyI64))
    (IrInstrCons
      (IrInstrVectorReduce 2 (IrVectorReduceSum) (IrValueVar 0) 4 (AstTyI64))
      IrInstrNil)))

(define (opt-vector-reduce-stale-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 1 (IrValueI64 10) (AstTyI64))
    (IrInstrCons
      (IrInstrVectorReduce 1 (IrVectorReduceSum) (IrValueVar 0) 4 (AstTyI64))
      (IrInstrCons
        (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 1) (IrValueI64 1) (AstTyI64))
        IrInstrNil))))

(define (opt-vector-copy-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 2 (IrValueVar 0) (AstTyI64))
    (IrInstrCons
      (IrInstrVectorBinOp
        3
        (IrBinAdd)
        (IrValueVar 2)
        (IrValueVar 1)
        4
        (AstTyI64))
      IrInstrNil)))

(define (opt-mask-copy-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 2 (IrValueVar 0) (AstTyBool))
    (IrInstrCons
      (IrInstrMaskBinOp 3 (IrMaskAnd) (IrValueVar 2) (IrValueVar 1) 4)
      IrInstrNil)))

(define (opt-mask-reduce-copy-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 1 (IrValueVar 0) (AstTyBool))
    (IrInstrCons
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
        (opt-count-vector-binop-instrs rest))]))

(define (opt-count-vector-reduce-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrVectorReduce _ _ _ _ _) 1]
          [_ 0])
        (opt-count-vector-reduce-instrs rest))]))

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
            (opt-vector-binop-lhs-var rest dst))]
        [_ (opt-vector-binop-lhs-var rest dst)])]))

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
            (opt-mask-binop-lhs-var rest dst))]
        [_ (opt-mask-binop-lhs-var rest dst)])]))

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
            (opt-mask-reduce-src-var rest dst))]
        [_ (opt-mask-reduce-src-var rest dst)])]))

(define (compiler-optimize-vector-mask-self-test) : i64
  (let
    [instrs : CompilerIrInstrList (opt-vector-mask-test-instrs)]
    [folded : CompilerIrInstrList (opt-fold-instrs (OptConstNil) instrs)]
    [dce : CompilerIrInstrList
      (opt-dce-instrs (opt-collect-instrs-uses (OptUsedNil) instrs) instrs)]
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
    (cond
      [(not (opt-instr-list-eq folded instrs)) 1]
      [(not (= (compiler-ir-instr-list-count dce) 8)) 2]
      [(not (= (compiler-ir-instr-list-count bounds) 8)) 3]
      [(not (= (opt-count-vector-binop-instrs vector-cse) 2)) 4]
      [(not (= (opt-mov-dst-type-tag vector-cse 3) 0)) 5]
      [(not (= (opt-count-vector-reduce-instrs vector-reduce-cse) 2)) 6]
      [(not (= (opt-mov-dst-type-tag vector-reduce-cse 2) 0)) 7]
      [(not (= (opt-count-arith-instrs vector-stale) 1)) 8]
      [(not (= (opt-count-mov-i64-value vector-stale 11) 0)) 9]
      [(not (= (opt-vector-binop-lhs-var vector-copy 3) 2)) 10]
      [(not (= (opt-mask-binop-lhs-var mask-copy 3) 2)) 11]
      [(not (= (opt-mask-reduce-src-var mask-reduce-copy 2) 1)) 12]
      [else 42])))

;; Returns 42 when folding turns the one arithmetic instruction into a `Mov`
;; literal whose value (20 + 22) is correct, and a later `Load` redefining a
;; formerly-constant var invalidates the stale fact before another arithmetic
;; instruction reads that var.
(define (compiler-optimize-self-test) : i64
  (let
    [instrs : CompilerIrInstrList (opt-self-test-instrs)]
    (let
      [optimized : CompilerIrInstrList (opt-fold-instrs (OptConstNil) instrs)]
      (if (= (opt-count-arith-instrs instrs) 1)
        (if (= (opt-count-arith-instrs optimized) 0)
          (if (= (opt-sum-mov-i64 optimized) 84)
            (let
              [stale-instrs : CompilerIrInstrList (opt-stale-load-test-instrs)]
              (let
                [stale-optimized : CompilerIrInstrList
                  (opt-fold-instrs (OptConstNil) stale-instrs)]
                (if (= (opt-count-arith-instrs stale-optimized) 1)
                  (if (= (compiler-optimize-vector-mask-self-test) 42)
                    42
                    5)
                  4)))
            3)
          2)
        1))))

(define (opt-typed-fold-u64-shr-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 20 (IrValueI64 (- 0 1)) (AstTyU64))
    (IrInstrCons
      (IrInstrMov 21 (IrValueI64 63) (AstTyU8))
      (IrInstrCons
        (IrInstrBinOp 22 (IrBinShr) (IrValueVar 20) (IrValueVar 21) (AstTyU64))
        (IrInstrNil)))))

(define (opt-typed-fold-shift-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 15 (IrValueI64 1) (AstTyI64))
    (IrInstrCons
      (IrInstrMov 16 (IrValueI64 3) (AstTyU8))
      (IrInstrCons
        (IrInstrBinOp 17 (IrBinShl) (IrValueVar 15) (IrValueVar 16) (AstTyI64))
        (IrInstrCons
          (IrInstrMov 18 (IrValueI64 (- 0 8)) (AstTyI64))
          (IrInstrCons
            (IrInstrBinOp
              19
              (IrBinShr)
              (IrValueVar 18)
              (IrValueI64 1)
              (AstTyI64))
            (opt-typed-fold-u64-shr-instrs)))))))

(define (opt-typed-fold-div-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrBinOp 13 (IrBinDiv) (IrValueI64 42) (IrValueI64 6) (AstTyI64))
    (IrInstrCons
      (IrInstrBinOp 14 (IrBinMod) (IrValueI64 22) (IrValueI64 7) (AstTyU8))
      (opt-typed-fold-shift-instrs))))

(define (opt-typed-fold-bool-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 11 (IrValueBool true) (AstTyBool))
    (IrInstrCons
      (IrInstrBinOp
        12
        (IrBinAnd)
        (IrValueVar 11)
        (IrValueBool false)
        (AstTyBool))
      (opt-typed-fold-div-instrs))))

(define (opt-typed-fold-cast-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrCast 7 (IrValueVar 0) (AstTyU8) (AstTyI64))
    (IrInstrCons
      (IrInstrCast 8 (IrValueI64 300) (AstTyU16) (AstTyChar))
      (IrInstrCons
        (IrInstrMov 9 (IrValueChar #A') (AstTyChar))
        (IrInstrCons
          (IrInstrCast 10 (IrValueVar 9) (AstTyChar) (AstTyI64))
          (opt-typed-fold-bool-instrs))))))

(define (opt-typed-fold-compare-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 3 (IrValueI64 (- 0 1)) (AstTyI8))
    (IrInstrCons
      (IrInstrMov 4 (IrValueI64 1) (AstTyI8))
      (IrInstrCons
        (IrInstrBinOp 5 (IrBinLt) (IrValueVar 3) (IrValueVar 4) (AstTyBool))
        (IrInstrCons
          (IrInstrBinOp 6 (IrBinLt) (IrValueVar 0) (IrValueVar 1) (AstTyBool))
          (opt-typed-fold-cast-instrs))))))

(define (opt-typed-fold-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 0 (IrValueI64 255) (AstTyU8))
    (IrInstrCons
      (IrInstrMov 1 (IrValueI64 1) (AstTyU8))
      (IrInstrCons
        (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyU8))
        (opt-typed-fold-compare-instrs)))))

(define (opt-typed-fold-invalid-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrBinOp 30 (IrBinDiv) (IrValueI64 1) (IrValueI64 0) (AstTyI64))
    (IrInstrCons
      (IrInstrBinOp
        31
        (IrBinDiv)
        (IrValueI64 (- 0 128))
        (IrValueI64 (- 0 1))
        (AstTyI8))
      (IrInstrCons
        (IrInstrBinOp
          32
          (IrBinShl)
          (IrValueI64 1)
          (IrValueI64 (- 0 1))
          (AstTyI64))
        (IrInstrCons
          (IrInstrBinOp 33 (IrBinShl) (IrValueI64 1) (IrValueI64 8) (AstTyU8))
          (IrInstrNil))))))

(define (compiler-optimize-typed-fold-self-test) : i64
  (let
    [pos : CompilerIrInstrList
      (opt-fold-instrs (OptConstNil) (opt-typed-fold-instrs))]
    (let
      [neg : CompilerIrInstrList
        (opt-fold-instrs (OptConstNil) (opt-typed-fold-invalid-instrs))]
      (if (= (opt-count-arith-instrs pos) 0)
        (if (= (opt-count-cast-instrs pos) 0)
          (if (= (opt-mov-dst-i64-value pos 2 (- 0 999)) 0)
            (if (opt-mov-dst-bool-value? pos 5 true)
              (if (opt-mov-dst-bool-value? pos 6 false)
                (if (= (opt-mov-dst-i64-value pos 7 0) 255)
                  (if (= (opt-mov-dst-char-code pos 8 0) 44)
                    (if (= (opt-mov-dst-i64-value pos 10 0) 65)
                      (if (opt-mov-dst-bool-value? pos 12 false)
                        (if (= (opt-mov-dst-i64-value pos 13 0) 7)
                          (if (= (opt-mov-dst-i64-value pos 14 0) 1)
                            (if (= (opt-mov-dst-i64-value pos 17 0) 8)
                              (if (= (opt-mov-dst-i64-value pos 19 0) (- 0 4))
                                (if (= (opt-mov-dst-i64-value pos 22 0) 1)
                                  (if (= (opt-count-arith-instrs neg) 4)
                                    42
                                    16)
                                  15)
                                14)
                              13)
                            12)
                          11)
                        10)
                      9)
                    8)
                  7)
                6)
              5)
            4)
          3)
        1))))

;; Positive strength-reduction cases: integer neutral/absorbing identities and
;; boolean `and`/`or` identities. The first instruction uses `AstTyU8` to prove
;; non-i64 integer result types keep their original type.
(define (opt-strength-self-test-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrBinOp 10 (IrBinAdd) (IrValueVar 1) (IrValueI64 0) (AstTyU8))
    (IrInstrCons
      (IrInstrBinOp 11 (IrBinAdd) (IrValueI64 0) (IrValueVar 2) (AstTyI64))
      (IrInstrCons
        (IrInstrBinOp 12 (IrBinSub) (IrValueVar 3) (IrValueI64 0) (AstTyI64))
        (IrInstrCons
          (IrInstrBinOp 13 (IrBinMul) (IrValueVar 4) (IrValueI64 1) (AstTyI64))
          (IrInstrCons
            (IrInstrBinOp
              14
              (IrBinMul)
              (IrValueI64 1)
              (IrValueVar 5)
              (AstTyI64))
            (IrInstrCons
              (IrInstrBinOp
                15
                (IrBinMul)
                (IrValueVar 6)
                (IrValueI64 0)
                (AstTyI64))
              (IrInstrCons
                (IrInstrBinOp
                  16
                  (IrBinMul)
                  (IrValueI64 0)
                  (IrValueVar 7)
                  (AstTyI64))
                (IrInstrCons
                  (IrInstrBinOp
                    17
                    (IrBinAnd)
                    (IrValueVar 8)
                    (IrValueBool true)
                    (AstTyBool))
                  (IrInstrCons
                    (IrInstrBinOp
                      18
                      (IrBinAnd)
                      (IrValueBool true)
                      (IrValueVar 9)
                      (AstTyBool))
                    (IrInstrCons
                      (IrInstrBinOp
                        19
                        (IrBinAnd)
                        (IrValueVar 8)
                        (IrValueBool false)
                        (AstTyBool))
                      (IrInstrCons
                        (IrInstrBinOp
                          20
                          (IrBinAnd)
                          (IrValueBool false)
                          (IrValueVar 9)
                          (AstTyBool))
                        (IrInstrCons
                          (IrInstrBinOp
                            21
                            (IrBinOr)
                            (IrValueVar 8)
                            (IrValueBool false)
                            (AstTyBool))
                          (IrInstrCons
                            (IrInstrBinOp
                              22
                              (IrBinOr)
                              (IrValueBool false)
                              (IrValueVar 9)
                              (AstTyBool))
                            (IrInstrCons
                              (IrInstrBinOp
                                23
                                (IrBinOr)
                                (IrValueVar 8)
                                (IrValueBool true)
                                (AstTyBool))
                              (IrInstrCons
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
  (IrInstrCons
    (IrInstrBinOp 30 (IrBinDiv) (IrValueVar 1) (IrValueI64 0) (AstTyI64))
    (IrInstrCons
      (IrInstrBinOp 31 (IrBinMod) (IrValueVar 1) (IrValueI64 0) (AstTyI64))
      (IrInstrCons
        (IrInstrBinOp 32 (IrBinShl) (IrValueVar 1) (IrValueI64 0) (AstTyI64))
        (IrInstrCons
          (IrInstrBinOp 33 (IrBinShr) (IrValueVar 1) (IrValueI64 0) (AstTyI64))
          (IrInstrCons
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
    (let
      [neg : CompilerIrInstrList
        (opt-strength-instrs (OptConstNil) (opt-strength-negative-instrs))]
      (cond
        [(not (= (opt-count-arith-instrs pos) 0)) 1]
        [(not (= (opt-sum-mov-var-src pos) 49)) 2]
        [(not (= (opt-count-mov-i64-value pos 0) 2)) 3]
        [(not (= (opt-count-mov-bool-value pos false) 2)) 4]
        [(not (= (opt-count-mov-bool-value pos true) 2)) 5]
        [(not (= (opt-mov-dst-type-tag pos 10) (ast-type-tag (AstTyU8)))) 6]
        [(not (= (opt-count-arith-instrs neg) 5)) 7]
        [else 42]))))

;; Builds `[Mov v0=99 (unused), Call v1 = noop(), Return v1]`. `v0` is a dead
;; pure temporary; `v1` is produced by a side-effecting call and used by the
;; return, so DCE must drop only `v0`'s Mov (3 instrs -> 2).
(define (opt-dce-self-test-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 0 (IrValueI64 99) (AstTyI64))
    (IrInstrCons
      (IrInstrCall 1 "noop" (IrValueNil) (AstTyI64))
      (IrInstrCons (IrInstrReturn (IrSomeValue (IrValueVar 1))) (IrInstrNil)))))

;; Returns 42 when DCE keeps the used call result `v1` and the side-effecting
;; instructions, drops the unused `v0`, and is idempotent on a second pass.
(define (compiler-optimize-dce-self-test) : i64
  (let
    [instrs : CompilerIrInstrList (opt-dce-self-test-instrs)]
    (let
      [used : OptUsedSet (opt-collect-instrs-uses (OptUsedNil) instrs)]
      (let
        [cleaned : CompilerIrInstrList (opt-dce-instrs used instrs)]
        (let
          [again : CompilerIrInstrList
            (opt-dce-instrs
              (opt-collect-instrs-uses (OptUsedNil) cleaned)
              cleaned)]
          (cond
            [(not (opt-used-contains used 1)) 0]
            [(opt-used-contains used 0) 1]
            [(not (= (compiler-ir-instr-list-count instrs) 3)) 2]
            [(not (= (compiler-ir-instr-list-count cleaned) 2)) 3]
            [(not (= (compiler-ir-instr-list-count again) 2)) 4]
            [else 42]))))))

;; Builds `[Mov v0=4096 (an address), Load v1 = *v0, Return v1]`. `v0` feeds a
;; `Load`, so DCE must treat it as used and keep it; without collecting the
;; Load's operand uses, DCE would wrongly drop `v0`'s Mov and break the load.
(define (opt-dce-mem-self-test-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 0 (IrValueI64 4096) (AstTyI64))
    (IrInstrCons
      (IrInstrLoad 1 (IrValueVar 0) (AstTyI64))
      (IrInstrCons (IrInstrReturn (IrSomeValue (IrValueVar 1))) (IrInstrNil)))))

;; Returns 42 when DCE keeps the `Mov` that feeds the `Load` (operand uses of
;; pointer/memory ops are collected), leaving all three instructions intact.
(define (compiler-optimize-dce-mem-self-test) : i64
  (let
    [instrs : CompilerIrInstrList (opt-dce-mem-self-test-instrs)]
    (let
      [used : OptUsedSet (opt-collect-instrs-uses (OptUsedNil) instrs)]
      (let
        [cleaned : CompilerIrInstrList (opt-dce-instrs used instrs)]
        (if (opt-used-contains used 0)
          (if (= (compiler-ir-instr-list-count cleaned) 3)
            42
            2)
          1)))))

;; `[BinOp v2 = v0 + v1, BinOp v3 = v0 + v1]` with non-constant operands: CSE
;; rewrites the second into `Mov v3 = v2` (two arithmetic instrs -> one).
(define (opt-cse-self-test-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
    (IrInstrCons
      (IrInstrBinOp 3 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
      (IrInstrNil))))

;; A store between the two identical expressions clears the table, so the second
;; expression is preserved (no cross-store CSE).
(define (opt-cse-store-clears-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
    (IrInstrCons
      (IrInstrStore "g" (IrValueI64 0) (AstTyI64))
      (IrInstrCons
        (IrInstrBinOp 3 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
        (IrInstrNil)))))

;; Redefining an operand (`v0`) between the two expressions invalidates the
;; available entry, so the second expression is preserved (correctness on
;; non-SSA IR).
(define (opt-cse-operand-redef-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
    (IrInstrCons
      (IrInstrMov 0 (IrValueI64 5) (AstTyI64))
      (IrInstrCons
        (IrInstrBinOp 3 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
        (IrInstrNil)))))

;; Returns 42 when CSE eliminates the repeated pure expression (2 arithmetic
;; instrs -> 1) yet preserves the second expression both across an intervening
;; store and across an operand redefinition (still 2 arithmetic instrs each).
(define (compiler-optimize-cse-self-test) : i64
  (let
    [cse : CompilerIrInstrList
      (opt-cse-instrs (OptExprNil) (opt-cse-self-test-instrs))]
    (let
      [store : CompilerIrInstrList
        (opt-cse-instrs (OptExprNil) (opt-cse-store-clears-instrs))]
      (let
        [redef : CompilerIrInstrList
          (opt-cse-instrs (OptExprNil) (opt-cse-operand-redef-instrs))]
        (if (= (opt-count-arith-instrs cse) 1)
          (if (= (opt-count-arith-instrs store) 2)
            (if (= (opt-count-arith-instrs redef) 2)
              42
              3)
            2)
          1)))))

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
            (opt-copy-binop-lhs-var rest dst))]
        [_ (opt-copy-binop-lhs-var rest dst)])]))

;; `[Mov v1 = v0, BinOp v2 = v1 + 1]`: copy propagation rewrites the binop lhs
;; from v1 to v0.
(define (opt-copy-pos-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 1 (IrValueVar 0) (AstTyI64))
    (IrInstrCons
      (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 1) (IrValueI64 1) (AstTyI64))
      (IrInstrNil))))

;; `[Mov v1 = v0, Load v0 = *v9, BinOp v2 = v1 + 1]`: redefining the copy source
;; v0 invalidates the v1 -> v0 fact, so the binop lhs stays v1.
(define (opt-copy-src-redef-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 1 (IrValueVar 0) (AstTyI64))
    (IrInstrCons
      (IrInstrLoad 0 (IrValueVar 9) (AstTyI64))
      (IrInstrCons
        (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 1) (IrValueI64 1) (AstTyI64))
        (IrInstrNil)))))

;; `[Mov v1 = v0, Load v1 = *v9, BinOp v2 = v1 + 1]`: redefining the copy
;; destination v1 invalidates the fact, so the binop lhs stays v1.
(define (opt-copy-dst-redef-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 1 (IrValueVar 0) (AstTyI64))
    (IrInstrCons
      (IrInstrLoad 1 (IrValueVar 9) (AstTyI64))
      (IrInstrCons
        (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 1) (IrValueI64 1) (AstTyI64))
        (IrInstrNil)))))

;; `[BinOp v2 = v0 + v1, BinOp v3 = v0 + v1, BinOp v4 = v3 + 1, Return v4]`: CSE
;; rewrites the second expression to `Mov v3 = v2`; copy propagation then rewrites
;; the v4 lhs from v3 to v2, leaving the `Mov v3` copy dead for DCE to drop (the
;; `Return v4` keeps v4 live so only the copy is removed: 4 instrs -> 3).
(define (opt-copy-cse-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
    (IrInstrCons
      (IrInstrBinOp 3 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
      (IrInstrCons
        (IrInstrBinOp 4 (IrBinAdd) (IrValueVar 3) (IrValueI64 1) (AstTyI64))
        (IrInstrCons (IrInstrReturn (IrSomeValue (IrValueVar 4))) (IrInstrNil))))))

;; `[Mov v1 = 1.5f64, BinOp v2 = v1 + v1]`: an F64 source is not recorded as a
;; copy in this slice, so the binop lhs stays v1 (no unsafe literal propagation).
(define (opt-copy-f64-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 1 (IrValueF64 "1.5") (AstTyF64))
    (IrInstrCons
      (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 1) (IrValueVar 1) (AstTyF64))
      (IrInstrNil))))

(define (opt-copy-phi-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 1 (IrValueVar 0) (AstTyI64))
    (IrInstrCons
      (IrInstrPhi
        2
        (IrPhiInputCons (IrPhiInput (IrValueVar 1) "left") IrPhiInputNil)
        (AstTyI64))
      (IrInstrNil))))

(define (opt-phi-first-input-var
  [inputs : CompilerIrPhiInputList]
  [fallback : i64]) : i64
  (match inputs
    [(IrPhiInputNil) fallback]
    [(IrPhiInputCons input _)
      (match input
        [(IrPhiInput value _)
          (match value
            [(IrValueVar id) id]
            [_ fallback])])]))

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
            (opt-phi-dst-first-input-var rest dst fallback))]
        [_ (opt-phi-dst-first-input-var rest dst fallback)])]))

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
    (let
      [src-redef : CompilerIrInstrList
        (opt-copy-instrs (OptCopyNil) (opt-copy-src-redef-instrs))]
      (let
        [dst-redef : CompilerIrInstrList
          (opt-copy-instrs (OptCopyNil) (opt-copy-dst-redef-instrs))]
        (let
          [cse : CompilerIrInstrList
            (opt-copy-instrs
              (OptCopyNil)
              (opt-cse-instrs (OptExprNil) (opt-copy-cse-instrs)))]
          (let
            [cse-dce : CompilerIrInstrList
              (opt-dce-instrs (opt-collect-instrs-uses (OptUsedNil) cse) cse)]
            (let
              [f64 : CompilerIrInstrList
                (opt-copy-instrs (OptCopyNil) (opt-copy-f64-instrs))]
              (let
                [phi : CompilerIrInstrList
                  (opt-copy-instrs (OptCopyNil) (opt-copy-phi-instrs))]
                (cond
                  [(not (= (opt-copy-binop-lhs-var pos 2) 0)) 1]
                  [(not (= (opt-copy-binop-lhs-var src-redef 2) 1)) 2]
                  [(not (= (opt-copy-binop-lhs-var dst-redef 2) 1)) 3]
                  [(not (= (opt-copy-binop-lhs-var cse 4) 2)) 4]
                  [(not (= (compiler-ir-instr-list-count cse-dce) 3)) 5]
                  [(not (= (opt-copy-binop-lhs-var f64 2) 1)) 6]
                  [(not (= (opt-phi-dst-first-input-var phi 2 (- 0 1)) 1)) 7]
                  [else 42])))))))))

;; Count explicit trapping bounds checks after the dedicated bounds pass.
(define (opt-count-bounds-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrBoundsCheck _ _ _) 1]
          [_ 0])
        (opt-count-bounds-instrs rest))]))

(define (opt-count-bounds-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+ (opt-count-bounds-instrs instrs) (opt-count-bounds-blocks rest))])]))

(define (opt-bounds-duplicate-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.0")
    (IrInstrCons
      (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.1")
      (IrInstrNil))))

(define (opt-bounds-different-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.0")
    (IrInstrCons
      (IrInstrBoundsCheck (IrValueVar 1) (IrValueVar 0) "bounds_ok.1")
      (IrInstrNil))))

(define (opt-bounds-redef-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.0")
    (IrInstrCons
      (IrInstrMov 0 (IrValueI64 7) (AstTyI64))
      (IrInstrCons
        (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.1")
        (IrInstrNil)))))

(define (opt-bounds-call-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.0")
    (IrInstrCons
      (IrInstrCall 9 "touch" (IrValueNil) (AstTyUnit))
      (IrInstrCons
        (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.1")
        (IrInstrNil)))))

(define (opt-bounds-branch-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.0")
    (IrInstrCons
      (IrInstrBranch (IrValueBool true) "ok" "fail")
      (IrInstrCons
        (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.1")
        (IrInstrNil)))))

(define (opt-bounds-copy-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 2 (IrValueVar 0) (AstTyI64))
    (IrInstrCons
      (IrInstrBoundsCheck (IrValueVar 2) (IrValueVar 1) "bounds_ok.0")
      (IrInstrCons
        (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.1")
        (IrInstrNil)))))

(define (opt-bounds-dce-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 0 (IrValueI64 1) (AstTyU64))
    (IrInstrCons
      (IrInstrMov 1 (IrValueI64 2) (AstTyU64))
      (IrInstrCons
        (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.0")
        (IrInstrNil)))))

(define (opt-bounds-cross-blocks) : CompilerIrBlockList
  (IrBlockCons
    (IrBlock
      "entry"
      (IrInstrCons
        (IrInstrBoundsCheck (IrValueVar 0) (IrValueVar 1) "bounds_ok.0")
        (IrInstrNil)))
    (IrBlockCons
      (IrBlock
        "next"
        (IrInstrCons
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
        (opt-collect-instrs-uses (OptUsedNil) (opt-bounds-dce-instrs))
        (opt-bounds-dce-instrs))]
    [cross : CompilerIrBlockList
      (optimize-block-list (opt-bounds-cross-blocks))]
    (cond
      [(not (= (opt-count-bounds-instrs duplicate) 1)) 1]
      [(not (= (opt-count-bounds-instrs different) 2)) 2]
      [(not (= (opt-count-bounds-instrs redef) 2)) 3]
      [(not (= (opt-count-bounds-instrs call) 2)) 4]
      [(not (= (opt-count-bounds-instrs branch) 2)) 5]
      [(not (= (opt-count-bounds-instrs copy) 1)) 6]
      [(not (= (compiler-ir-instr-list-count dce) 3)) 7]
      [(not (= (opt-count-bounds-blocks cross) 2)) 8]
      [else 42])))

;; Copy propagation can expose a repeated expression only after CSE has already
;; run for that iteration. A second pass then CSEs `v3` to `v2`; copy propagation
;; rewrites `v4`, and DCE drops the now-unused copy.
(define (opt-fixed-point-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrMov 1 (IrValueVar 0) (AstTyI64))
    (IrInstrCons
      (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueI64 1) (AstTyI64))
      (IrInstrCons
        (IrInstrBinOp 3 (IrBinAdd) (IrValueVar 1) (IrValueI64 1) (AstTyI64))
        (IrInstrCons
          (IrInstrBinOp 4 (IrBinAdd) (IrValueVar 2) (IrValueVar 3) (AstTyI64))
          (IrInstrCons
            (IrInstrReturn (IrSomeValue (IrValueVar 4)))
            (IrInstrNil)))))))

(define (opt-test-function-named
  [name : String]
  [instrs : CompilerIrInstrList]) : CompilerIrFunction
  (IrFunction
    name
    (IrParamNil)
    (AstTyI64)
    5
    (IrBlockCons (IrBlock "entry" instrs) (IrBlockNil))))

(define (opt-test-function [instrs : CompilerIrInstrList]) : CompilerIrFunction
  (opt-test-function-named "fixed" instrs))

(define (opt-test-program [instrs : CompilerIrInstrList]) : CompilerIrProgram
  (IrProgram
    (IrGlobalNil)
    (IrFunctionCons (opt-test-function instrs) (IrFunctionNil))
    (IrExternNil)))

(define (opt-function-first-instrs [func : CompilerIrFunction]) : CompilerIrInstrList
  (match func
    [(IrFunction _ _ _ _ blocks)
      (match blocks
        [(IrBlockCons block _)
          (match block
            [(IrBlock _ instrs) instrs])]
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
    (= (compiler-optimize-default-level) 2)
    (and
      (compiler-optimize-level-valid? 0)
      (and
        (compiler-optimize-level-valid? 1)
        (and
          (compiler-optimize-level-valid? 2)
          (and
            (compiler-optimize-level-valid? 3)
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
                        (opt-level-parse-ok? "3" 3)
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
    [level3 : CompilerIrProgram (optimize-program-with-level program 3)]
    [defaulted : CompilerIrProgram (optimize-program program)]
    [level0-instrs : CompilerIrInstrList (opt-program-first-instrs level0)]
    [level1-instrs : CompilerIrInstrList (opt-program-first-instrs level1)]
    [level2-instrs : CompilerIrInstrList (opt-program-first-instrs level2)]
    (and
      (opt-program-eq program level0)
      (and
        (= (opt-count-arith-instrs level0-instrs) 1)
        (and
          (= (opt-count-arith-instrs level1-instrs) 0)
          (and
            (= (compiler-ir-instr-list-count level2-instrs) 0)
            (and
              (opt-program-eq level2 level3)
              (opt-program-eq level2 defaulted))))))))

(define (compiler-optimize-level-self-test) : i64
  (if (compiler-optimize-level-policy-ok?)
    (if (compiler-optimize-level-program-ok?)
      42
      2)
    1))

(define (opt-global-dce-main-instrs) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrCall 1 "helper" (IrValueNil) (AstTyI64))
    (IrInstrCons
      (IrInstrReturn (IrSomeValue (IrValueVar 1)))
      (IrInstrNil))))

(define (opt-global-dce-return-instrs [value : i64]) : CompilerIrInstrList
  (IrInstrCons
    (IrInstrReturn (IrSomeValue (IrValueI64 value)))
    (IrInstrNil)))

(define (opt-global-dce-program) : CompilerIrProgram
  (IrProgram
    (IrGlobalCons
      (IrGlobal "callback" (AstTyI64) (IrValueGlobal "callback-target"))
      (IrGlobalNil))
    (IrFunctionCons
      (opt-test-function-named "main" (opt-global-dce-main-instrs))
      (IrFunctionCons
        (opt-test-function-named "helper" (opt-global-dce-return-instrs 7))
        (IrFunctionCons
          (opt-test-function-named "dead" (opt-global-dce-return-instrs 9))
          (IrFunctionCons
            (opt-test-function-named
              "callback-target"
              (opt-global-dce-return-instrs 11))
            (IrFunctionNil)))))
    (IrExternNil)))

(define (opt-global-dce-no-main-program) : CompilerIrProgram
  (IrProgram
    (IrGlobalNil)
    (IrFunctionCons
      (opt-test-function-named "helper" (opt-global-dce-return-instrs 7))
      (IrFunctionCons
        (opt-test-function-named "dead" (opt-global-dce-return-instrs 9))
        (IrFunctionNil)))
    (IrExternNil)))

(define (compiler-optimize-global-dce-ok?) : bool
  (let
    [program : CompilerIrProgram (opt-global-dce-program)]
    [level1 : CompilerIrProgram (optimize-program-with-level program 1)]
    [level2 : CompilerIrProgram (optimize-program-with-level program 2)]
    [no-main : CompilerIrProgram
      (optimize-program-with-level (opt-global-dce-no-main-program) 2)]
    [level1-functions : CompilerIrFunctionList (opt-program-functions level1)]
    [level2-functions : CompilerIrFunctionList (opt-program-functions level2)]
    [no-main-functions : CompilerIrFunctionList (opt-program-functions no-main)]
    (and
      (= (compiler-ir-function-list-count level1-functions) 4)
      (and
        (= (compiler-ir-function-list-count level2-functions) 3)
        (and
          (opt-function-list-defines? level2-functions "main")
          (and
            (opt-function-list-defines? level2-functions "helper")
            (and
              (opt-function-list-defines? level2-functions "callback-target")
              (and
                (not (opt-function-list-defines? level2-functions "dead"))
                (= (compiler-ir-function-list-count no-main-functions) 2)))))))))

(define (compiler-optimize-global-dce-self-test) : i64
  (if (compiler-optimize-global-dce-ok?)
    42
    1))

(define (opt-function-blocks [func : CompilerIrFunction]) : CompilerIrBlockList
  (match func
    [(IrFunction _ _ _ _ blocks) blocks]))

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
            (opt-block-list-has-label? rest label))])]))

(define (opt-count-branches-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrBranch _ _ _) 1]
          [_ 0])
        (opt-count-branches-instrs rest))]))

(define (opt-count-branches-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-count-branches-instrs instrs)
            (opt-count-branches-blocks rest))])]))

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
        (opt-count-jump-to-instrs rest target))]))

(define (opt-count-jump-to-blocks
  [blocks : CompilerIrBlockList]
  [target : String]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-count-jump-to-instrs instrs target)
            (opt-count-jump-to-blocks rest target))])]))

(define (opt-count-phi-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (match instr
          [(IrInstrPhi _ _ _) 1]
          [_ 0])
        (opt-count-phi-instrs rest))]))

(define (opt-count-phi-blocks [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+ (opt-count-phi-instrs instrs) (opt-count-phi-blocks rest))])]))

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
        (opt-count-mov-dst-instrs rest dst))]))

(define (opt-count-mov-dst-blocks [blocks : CompilerIrBlockList] [dst : i64]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (opt-count-mov-dst-instrs instrs dst)
            (opt-count-mov-dst-blocks rest dst))])]))

(define (opt-cfg-test-function [blocks : CompilerIrBlockList]) : CompilerIrFunction
  (IrFunction "cfg" (IrParamNil) (AstTyI64) 16 blocks))

(define (opt-cfg-constant-if-blocks) : CompilerIrBlockList
  (IrBlockCons
    (IrBlock
      "entry"
      (IrInstrCons
        (IrInstrBranch (IrValueBool true) "then" "else")
        (IrInstrNil)))
    (IrBlockCons
      (IrBlock
        "then"
        (IrInstrCons (IrInstrReturn (IrSomeValue (IrValueI64 1))) (IrInstrNil)))
      (IrBlockCons
        (IrBlock
          "else"
          (IrInstrCons
            (IrInstrReturn (IrSomeValue (IrValueI64 2)))
            (IrInstrNil)))
        (IrBlockNil)))))

(define (opt-cfg-loop-guard-blocks) : CompilerIrBlockList
  (IrBlockCons
    (IrBlock "entry" (IrInstrCons (IrInstrJump "loop") (IrInstrNil)))
    (IrBlockCons
      (IrBlock
        "loop"
        (IrInstrCons
          (IrInstrBranch (IrValueBool false) "body" "exit")
          (IrInstrNil)))
      (IrBlockCons
        (IrBlock "body" (IrInstrCons (IrInstrJump "loop") (IrInstrNil)))
        (IrBlockCons
          (IrBlock
            "exit"
            (IrInstrCons
              (IrInstrReturn (IrSomeValue (IrValueI64 0)))
              (IrInstrNil)))
          (IrBlockNil))))))

(define (opt-cfg-phi-blocks) : CompilerIrBlockList
  (IrBlockCons
    (IrBlock
      "entry"
      (IrInstrCons
        (IrInstrBranch (IrValueBool true) "then" "else")
        (IrInstrNil)))
    (IrBlockCons
      (IrBlock
        "then"
        (IrInstrCons
          (IrInstrMov 1 (IrValueI64 10) (AstTyI64))
          (IrInstrCons (IrInstrJump "join") (IrInstrNil))))
      (IrBlockCons
        (IrBlock
          "else"
          (IrInstrCons
            (IrInstrMov 2 (IrValueI64 20) (AstTyI64))
            (IrInstrCons (IrInstrJump "join") (IrInstrNil))))
        (IrBlockCons
          (IrBlock
            "join"
            (IrInstrCons
              (IrInstrPhi
                3
                (IrPhiInputCons
                  (IrPhiInput (IrValueVar 1) "then")
                  (IrPhiInputCons
                    (IrPhiInput (IrValueVar 2) "else")
                    (IrPhiInputNil)))
                (AstTyI64))
              (IrInstrCons
                (IrInstrReturn (IrSomeValue (IrValueVar 3)))
                (IrInstrNil))))
          (IrBlockNil))))))

(define (opt-cfg-trap-path-blocks) : CompilerIrBlockList
  (IrBlockCons
    (IrBlock
      "entry"
      (IrInstrCons (IrInstrBranch (IrValueVar 0) "ok" "trap") (IrInstrNil)))
    (IrBlockCons
      (IrBlock
        "ok"
        (IrInstrCons (IrInstrReturn (IrSomeValue (IrValueI64 0))) (IrInstrNil)))
      (IrBlockCons
        (IrBlock
          "trap"
          (IrInstrCons
            (IrInstrCall 9 "panic" (IrValueNil) (AstTyUnit))
            (IrInstrCons
              (IrInstrReturn (IrSomeValue (IrValueI64 1)))
              (IrInstrNil))))
        (IrBlockNil)))))

(define (opt-ssa-cond-params) : CompilerIrParamList
  (IrParamCons (IrParam "cond" (AstTyBool) 0) (IrParamNil)))

(define (opt-ssa-loop-params) : CompilerIrParamList
  (IrParamCons
    (IrParam "seed" (AstTyI64) 0)
    (IrParamCons (IrParam "cond" (AstTyBool) 4) (IrParamNil))))

(define (opt-ssa-diamond-blocks) : CompilerIrBlockList
  (IrBlockCons
    (IrBlock
      "entry"
      (IrInstrCons (IrInstrBranch (IrValueVar 0) "then" "else") (IrInstrNil)))
    (IrBlockCons
      (IrBlock
        "then"
        (IrInstrCons
          (IrInstrMov 1 (IrValueI64 10) (AstTyI64))
          (IrInstrCons (IrInstrJump "join") (IrInstrNil))))
      (IrBlockCons
        (IrBlock
          "else"
          (IrInstrCons
            (IrInstrMov 2 (IrValueI64 20) (AstTyI64))
            (IrInstrCons (IrInstrJump "join") (IrInstrNil))))
        (IrBlockCons
          (IrBlock
            "join"
            (IrInstrCons
              (IrInstrPhi
                3
                (IrPhiInputCons
                  (IrPhiInput (IrValueVar 1) "then")
                  (IrPhiInputCons
                    (IrPhiInput (IrValueVar 2) "else")
                    (IrPhiInputNil)))
                (AstTyI64))
              (IrInstrCons
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
  (IrBlockCons
    (IrBlock "entry" (IrInstrCons (IrInstrJump "loop") (IrInstrNil)))
    (IrBlockCons
      (IrBlock
        "loop"
        (IrInstrCons
          (IrInstrPhi
            1
            (IrPhiInputCons
              (IrPhiInput (IrValueVar 0) "entry")
              (IrPhiInputCons
                (IrPhiInput (IrValueVar 2) "body")
                (IrPhiInputNil)))
            (AstTyI64))
          (IrInstrCons
            (IrInstrBranch (IrValueVar 4) "body" "exit")
            (IrInstrNil))))
      (IrBlockCons
        (IrBlock
          "body"
          (IrInstrCons
            (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 1) (IrValueI64 1) (AstTyI64))
            (IrInstrCons (IrInstrJump "loop") (IrInstrNil))))
        (IrBlockCons
          (IrBlock
            "exit"
            (IrInstrCons
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

(define (opt-ssa-unreachable-blocks) : CompilerIrBlockList
  (IrBlockCons
    (IrBlock
      "entry"
      (IrInstrCons (IrInstrReturn (IrSomeValue (IrValueI64 1))) (IrInstrNil)))
    (IrBlockCons
      (IrBlock
        "dead"
        (IrInstrCons (IrInstrReturn (IrSomeValue (IrValueI64 2))) (IrInstrNil)))
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
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons (IrInstrBranch (IrValueVar 0) "then" "else") (IrInstrNil)))
      (IrBlockCons
        (IrBlock
          "then"
          (IrInstrCons
            (IrInstrMov 1 (IrValueI64 10) (AstTyI64))
            (IrInstrCons (IrInstrJump "join") (IrInstrNil))))
        (IrBlockCons
          (IrBlock
            "else"
            (IrInstrCons
              (IrInstrMov 2 (IrValueI64 20) (AstTyI64))
              (IrInstrCons (IrInstrJump "join") (IrInstrNil))))
          (IrBlockCons
            (IrBlock
              "join"
              (IrInstrCons
                (IrInstrPhi
                  3
                  (IrPhiInputCons
                    (IrPhiInput (IrValueVar 1) "then")
                    (IrPhiInputCons
                      (IrPhiInput (IrValueVar 2) "ghost")
                      (IrPhiInputNil)))
                  (AstTyI64))
                (IrInstrCons
                  (IrInstrReturn (IrSomeValue (IrValueVar 3)))
                  (IrInstrNil))))
            (IrBlockNil)))))))

(define (opt-ssa-duplicate-label-function) : CompilerIrFunction
  (IrFunction
    "ssa_duplicate_label"
    (IrParamNil)
    (AstTyI64)
    0
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons (IrInstrReturn (IrSomeValue (IrValueI64 1))) (IrInstrNil)))
      (IrBlockCons
        (IrBlock
          "entry"
          (IrInstrCons
            (IrInstrReturn (IrSomeValue (IrValueI64 2)))
            (IrInstrNil)))
        (IrBlockNil)))))

(define (opt-ssa-unknown-successor-function) : CompilerIrFunction
  (IrFunction
    "ssa_unknown_successor"
    (IrParamNil)
    (AstTyI64)
    0
    (IrBlockCons
      (IrBlock "entry" (IrInstrCons (IrInstrJump "missing") (IrInstrNil)))
      (IrBlockNil))))

(define (opt-ssa-duplicate-def-function) : CompilerIrFunction
  (IrFunction
    "ssa_duplicate_def"
    (IrParamNil)
    (AstTyI64)
    0
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons
          (IrInstrMov 1 (IrValueI64 1) (AstTyI64))
          (IrInstrCons
            (IrInstrMov 1 (IrValueI64 2) (AstTyI64))
            (IrInstrCons
              (IrInstrReturn (IrSomeValue (IrValueVar 1)))
              (IrInstrNil)))))
      (IrBlockNil))))

(define (opt-ssa-use-before-def-function) : CompilerIrFunction
  (IrFunction
    "ssa_use_before_def"
    (IrParamNil)
    (AstTyI64)
    0
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons (IrInstrReturn (IrSomeValue (IrValueVar 9))) (IrInstrNil)))
      (IrBlockNil))))

(define (opt-ssa-dominance-fail-function) : CompilerIrFunction
  (IrFunction
    "ssa_dominance_fail"
    (opt-ssa-cond-params)
    (AstTyI64)
    16
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons (IrInstrBranch (IrValueVar 0) "then" "else") (IrInstrNil)))
      (IrBlockCons
        (IrBlock
          "then"
          (IrInstrCons
            (IrInstrMov 1 (IrValueI64 10) (AstTyI64))
            (IrInstrCons (IrInstrJump "join") (IrInstrNil))))
        (IrBlockCons
          (IrBlock "else" (IrInstrCons (IrInstrJump "join") (IrInstrNil)))
          (IrBlockCons
            (IrBlock
              "join"
              (IrInstrCons
                (IrInstrReturn (IrSomeValue (IrValueVar 1)))
                (IrInstrNil)))
            (IrBlockNil)))))))

(define (compiler-optimize-ssa-self-test) : i64
  (let
    [diamond-blocks : CompilerIrBlockList (opt-ssa-diamond-blocks)]
    [diamond-doms : OptDomTable (opt-cfg-dominators diamond-blocks)]
    [then-frontier : OptLabelSet
      (opt-cfg-dominance-frontier diamond-blocks "then")]
    [else-frontier : OptLabelSet
      (opt-cfg-dominance-frontier diamond-blocks "else")]
    [loop-blocks : CompilerIrBlockList (opt-ssa-loop-blocks)]
    [loop-doms : OptDomTable (opt-cfg-dominators loop-blocks)]
    [loop-frontier : OptLabelSet
      (opt-cfg-dominance-frontier loop-blocks "loop")]
    [unreachable-order : CompilerIrBlockList
      (opt-cfg-reachable-block-order (opt-ssa-unreachable-blocks))]
    (cond
      [(not
          (= (opt-label-count (opt-cfg-predecessors diamond-blocks "join")) 2))
        1]
      [(not (opt-dom-dominates? diamond-doms "entry" "join")) 2]
      [(opt-dom-dominates? diamond-doms "then" "join") 3]
      [(not (opt-label-contains then-frontier "join")) 4]
      [(not (opt-label-contains else-frontier "join")) 5]
      [(not (opt-dom-dominates? loop-doms "loop" "body")) 6]
      [(not (opt-label-contains loop-frontier "loop")) 7]
      [(not (= (compiler-ir-block-list-count unreachable-order) 1)) 8]
      [(not (opt-block-list-has-label? unreachable-order "entry")) 9]
      [(not (opt-verify-ok? (opt-verify-function (opt-ssa-diamond-function))))
        10]
      [(not (opt-verify-ok? (opt-verify-function (opt-ssa-loop-function)))) 11]
      [(not
          (opt-verify-ok? (opt-verify-function (opt-ssa-unreachable-function))))
        12]
      [(not
          (opt-verify-error-ok?
            (opt-verify-function (opt-ssa-duplicate-label-function))
            "optimizer verify: duplicate block label"))
        13]
      [(not
          (opt-verify-error-ok?
            (opt-verify-function (opt-ssa-unknown-successor-function))
            "optimizer verify: unknown successor label"))
        14]
      [(not
          (opt-verify-error-ok?
            (opt-verify-function (opt-ssa-bad-phi-function))
            "optimizer verify: phi predecessor mismatch"))
        15]
      [(not
          (opt-verify-error-ok?
            (opt-verify-function (opt-ssa-duplicate-def-function))
            "optimizer verify: duplicate var definition"))
        16]
      [(not
          (opt-verify-error-ok?
            (opt-verify-function (opt-ssa-use-before-def-function))
            "optimizer verify: use before definition"))
        17]
      [(not
          (opt-verify-error-ok?
            (opt-verify-function (opt-ssa-dominance-fail-function))
            "optimizer verify: use is not dominated by definition"))
        18]
      [else 42])))

(define (compiler-optimize-cfg-self-test) : i64
  (let
    [constant-if : CompilerIrBlockList
      (opt-cfg-simplify-blocks (opt-cfg-constant-if-blocks))]
    (let
      [loop-guard : CompilerIrBlockList
        (opt-cfg-simplify-blocks (opt-cfg-loop-guard-blocks))]
      (let
        [phi-cfg : CompilerIrBlockList
          (opt-cfg-simplify-blocks (opt-cfg-phi-blocks))]
        (let
          [phi-blocks : CompilerIrBlockList
            (opt-function-blocks
              (optimize-function (opt-cfg-test-function (opt-cfg-phi-blocks))))]
          (let
            [trap-blocks : CompilerIrBlockList
              (opt-function-blocks
                (optimize-function
                  (opt-cfg-test-function (opt-cfg-trap-path-blocks))))]
            (if (= (compiler-ir-block-list-count constant-if) 2)
              (if (not (opt-block-list-has-label? constant-if "else"))
                (if (= (opt-count-jump-to-blocks constant-if "then") 1)
                  (if (= (opt-count-branches-blocks constant-if) 0)
                    (if (= (compiler-ir-block-list-count loop-guard) 3)
                      (if (not (opt-block-list-has-label? loop-guard "body"))
                        (if (= (opt-count-jump-to-blocks loop-guard "exit") 1)
                          (if (= (compiler-ir-block-list-count phi-blocks) 3)
                            (if (not
                              (opt-block-list-has-label? phi-blocks "else"))
                              (if (= (opt-count-phi-blocks phi-blocks) 0)
                                (if (= (opt-count-mov-dst-blocks phi-cfg 3) 1)
                                  (if (=
                                    (compiler-ir-block-list-count trap-blocks)
                                    3)
                                    (if (opt-block-list-has-label?
                                      trap-blocks
                                      "trap")
                                      (if (=
                                        (opt-count-branches-blocks trap-blocks)
                                        1)
                                        42
                                        14)
                                      13)
                                    12)
                                  11)
                                10)
                              9)
                            8)
                          7)
                        6)
                      5)
                    4)
                  3)
                2)
              1)))))))

(define (compiler-optimize-fixed-point-self-test) : i64
  (let
    [func : CompilerIrFunction (opt-test-function (opt-fixed-point-instrs))]
    (let
      [once : CompilerIrFunction (optimize-function-once func)]
      (let
        [fixed : CompilerIrFunction (optimize-function func)]
        (let
          [once-instrs : CompilerIrInstrList (opt-function-first-instrs once)]
          (let
            [fixed-instrs : CompilerIrInstrList
              (opt-function-first-instrs fixed)]
            (let
              [optimized-program : CompilerIrProgram
                (optimize-program (opt-test-program (opt-fixed-point-instrs)))]
              (let
                [again-program : CompilerIrProgram
                  (optimize-program optimized-program)]
                (cond
                  [(not (= (compiler-ir-instr-list-count once-instrs) 4)) 1]
                  [(not (= (opt-count-arith-instrs once-instrs) 3)) 2]
                  [(not (= (compiler-ir-instr-list-count fixed-instrs) 3)) 3]
                  [(not (= (opt-count-arith-instrs fixed-instrs) 2)) 4]
                  [(not (opt-program-eq optimized-program again-program)) 5]
                  [else 42])))))))))
