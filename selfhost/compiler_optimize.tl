;; compiler_optimize.tl - Selfhost optimizer: pass framework + scalar constant
;; folding (#543, first slice of #519).
;;
;; Runs between lowering (`lower-compiler-program`) and backend emission
;; (`compiler-backend-emit-program`). It performs conservative, scalar-only
;; constant folding: within each basic block it tracks IR vars defined by a
;; `Mov` of a scalar literal, rewrites any `IrInstrBinOp`/`IrInstrUnOp` whose
;; operands resolve to those literals into an `IrInstrMov` of the computed
;; literal, and clears tracked facts when any other IR instruction redefines a
;; variable.
;;
;; Safety:
;; - Integer `+`, `-`, `*`, and `neg` wrap modulo 2^N per SPEC; this optimizer is
;;   itself TypeLisp using the same wrapping i64 arithmetic, so folding them is
;;   exact.
;; - Division, modulo, and shifts are intentionally NOT folded, preserving the
;;   runtime divide/modulo-by-zero traps and shift edge cases until the rules are
;;   made explicit.
;; - Tracking is block-local (reset per block), so no value is folded across a
;;   control-flow edge.
;;
;; Out of scope (tracked separately): dead-code elimination, copy propagation,
;; common-subexpression elimination, and aggregate/String/array IR.

(import "compiler_ir_types.tl")

;; --- block-local constant environment: IR var id -> known scalar literal -----

(defenum OptConstEnv
  (OptConstNil)
  (OptConstCons i64 CompilerIrValue OptConstEnv))

(define (opt-const-unbind [env : OptConstEnv] [var : i64]) : OptConstEnv
  (match env
    [(OptConstNil) (OptConstNil)]
    [(OptConstCons id value rest)
     (if (= id var)
         (opt-const-unbind rest var)
         (OptConstCons id value (opt-const-unbind rest var)))]))

(define (opt-const-bind [env : OptConstEnv] [var : i64] [value : CompilerIrValue]) : OptConstEnv
  (OptConstCons var value (opt-const-unbind env var)))

(define (opt-const-lookup [env : OptConstEnv] [var : i64]) : CompilerIrMaybeValue
  (match env
    [(OptConstNil) (IrNoValue)]
    [(OptConstCons id value rest)
     (if (= id var) (IrSomeValue value) (opt-const-lookup rest var))]))

;; A scalar literal we are willing to track and fold (i64 / bool only for v1).
(define (opt-const-value? [value : CompilerIrValue]) : bool
  (match value
    [(IrValueI64 _) true]
    [(IrValueBool _) true]
    [_ false]))

(define (opt-resolve [env : OptConstEnv] [value : CompilerIrValue]) : CompilerIrValue
  (match value
    [(IrValueVar id)
     (match (opt-const-lookup env id)
       [(IrSomeValue v) v]
       [(IrNoValue) value])]
    [_ value]))

;; --- folding rules -----------------------------------------------------------

;; Fold an integer binop with two i64 literals. Div/Mod/shifts/bitwise are left
;; unfolded (returns IrNoValue) to preserve runtime semantics for this slice.
(define (opt-fold-i64 [op : CompilerIrBinOp] [a : i64] [b : i64]) : CompilerIrMaybeValue
  (match op
    [(IrBinAdd) (IrSomeValue (IrValueI64 (+ a b)))]
    [(IrBinSub) (IrSomeValue (IrValueI64 (- a b)))]
    [(IrBinMul) (IrSomeValue (IrValueI64 (* a b)))]
    [(IrBinEq) (IrSomeValue (IrValueBool (= a b)))]
    [(IrBinNe) (IrSomeValue (IrValueBool (!= a b)))]
    [(IrBinLt) (IrSomeValue (IrValueBool (< a b)))]
    [(IrBinLe) (IrSomeValue (IrValueBool (<= a b)))]
    [(IrBinGt) (IrSomeValue (IrValueBool (> a b)))]
    [(IrBinGe) (IrSomeValue (IrValueBool (>= a b)))]
    [_ (IrNoValue)]))

(define (opt-fold-bool [op : CompilerIrBinOp] [a : bool] [b : bool]) : CompilerIrMaybeValue
  (match op
    [(IrBinAnd) (IrSomeValue (IrValueBool (and a b)))]
    [(IrBinOr) (IrSomeValue (IrValueBool (or a b)))]
    [_ (IrNoValue)]))

(define (opt-fold-binop [op : CompilerIrBinOp] [l : CompilerIrValue] [r : CompilerIrValue]) : CompilerIrMaybeValue
  (match l
    [(IrValueI64 a)
     (match r
       [(IrValueI64 b) (opt-fold-i64 op a b)]
       [_ (IrNoValue)])]
    [(IrValueBool a)
     (match r
       [(IrValueBool b) (opt-fold-bool op a b)]
       [_ (IrNoValue)])]
    [_ (IrNoValue)]))

(define (opt-fold-unop [op : CompilerIrUnOp] [v : CompilerIrValue]) : CompilerIrMaybeValue
  (match op
    [(IrUnNeg)
     (match v
       [(IrValueI64 a) (IrSomeValue (IrValueI64 (- 0 a)))]
       [_ (IrNoValue)])]
    [(IrUnNot)
     (match v
       [(IrValueBool a) (IrSomeValue (IrValueBool (not a)))]
       [_ (IrNoValue)])]
    [(IrUnBitNot) (IrNoValue)]))

;; --- instruction / block / function / program traversal ----------------------

(defenum OptInstrResult
  (OptInstrResult OptConstEnv CompilerIrInstr))

(define (opt-invalidate-def [env : OptConstEnv] [dst : i64] [instr : CompilerIrInstr]) : OptInstrResult
  (OptInstrResult (opt-const-unbind env dst) instr))

(define (opt-fold-instr [env : OptConstEnv] [instr : CompilerIrInstr]) : OptInstrResult
  (match instr
    [(IrInstrMov dst value ty)
     (if (opt-const-value? value)
         (OptInstrResult (opt-const-bind env dst value) instr)
         (OptInstrResult (opt-const-unbind env dst) instr))]
    [(IrInstrAlloc dst ty) (opt-invalidate-def env dst instr)]
    [(IrInstrAddrOf dst src) (opt-invalidate-def env dst instr)]
    [(IrInstrGep dst base offset ty) (opt-invalidate-def env dst instr)]
    [(IrInstrLoad dst src ty) (opt-invalidate-def env dst instr)]
    [(IrInstrCast dst src from-ty to-ty) (opt-invalidate-def env dst instr)]
    [(IrInstrBinOp dst op l r ty)
     (match (opt-fold-binop op (opt-resolve env l) (opt-resolve env r))
       [(IrSomeValue folded)
        (OptInstrResult (opt-const-bind env dst folded) (IrInstrMov dst folded ty))]
       [(IrNoValue) (OptInstrResult (opt-const-unbind env dst) instr)])]
    [(IrInstrUnOp dst op v ty)
     (match (opt-fold-unop op (opt-resolve env v))
       [(IrSomeValue folded)
        (OptInstrResult (opt-const-bind env dst folded) (IrInstrMov dst folded ty))]
       [(IrNoValue) (OptInstrResult (opt-const-unbind env dst) instr)])]
    [(IrInstrCall dst name args ty) (opt-invalidate-def env dst instr)]
    [(IrInstrPhi dst inputs ty) (opt-invalidate-def env dst instr)]
    [_ (OptInstrResult env instr)]))

(define (opt-fold-instrs [env : OptConstEnv] [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
     (match (opt-fold-instr env instr)
       [(OptInstrResult new-env new-instr)
        (IrInstrCons new-instr (opt-fold-instrs new-env rest))])]))

(define (optimize-block [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs) (IrBlock label (opt-fold-instrs (OptConstNil) instrs))]))

(define (optimize-block-list [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
     (IrBlockCons (optimize-block block) (optimize-block-list rest))]))

(define (optimize-function [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(IrFunction name params ret-ty frame blocks)
     (IrFunction name params ret-ty frame (optimize-block-list blocks))]))

(define (optimize-function-list [funcs : CompilerIrFunctionList]) : CompilerIrFunctionList
  (match funcs
    [(IrFunctionNil) (IrFunctionNil)]
    [(IrFunctionCons func rest)
     (IrFunctionCons (optimize-function func) (optimize-function-list rest))]))

(define (optimize-program [program : CompilerIrProgram]) : CompilerIrProgram
  (match program
    [(IrProgram globals functions externs)
     (IrProgram globals (optimize-function-list functions) externs)]))

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

;; Builds `[Mov v0=20, Mov v1=22, BinOp v2 = v0 + v1]` (one arithmetic instr).
(define (opt-self-test-instrs) : CompilerIrInstrList
  (IrInstrCons (IrInstrMov 0 (IrValueI64 20) (AstTyI64))
    (IrInstrCons (IrInstrMov 1 (IrValueI64 22) (AstTyI64))
      (IrInstrCons (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
        (IrInstrNil)))))

(define (opt-stale-load-test-instrs) : CompilerIrInstrList
  (IrInstrCons (IrInstrMov 0 (IrValueI64 41) (AstTyI64))
    (IrInstrCons (IrInstrLoad 0 (IrValueVar 9) (AstTyI64))
      (IrInstrCons (IrInstrBinOp 1 (IrBinAdd) (IrValueVar 0) (IrValueI64 1) (AstTyI64))
        (IrInstrNil)))))

;; Returns 42 when folding turns the one arithmetic instruction into a `Mov`
;; literal whose value (20 + 22) is correct, and a later `Load` redefining a
;; formerly-constant var invalidates the stale fact before another arithmetic
;; instruction reads that var.
(define (compiler-optimize-self-test) : i64
  (let ([instrs : CompilerIrInstrList (opt-self-test-instrs)])
    (let ([optimized : CompilerIrInstrList (opt-fold-instrs (OptConstNil) instrs)])
      (if (= (opt-count-arith-instrs instrs) 1)
          (if (= (opt-count-arith-instrs optimized) 0)
              (if (= (opt-sum-mov-i64 optimized) 84)
                  (let ([stale-instrs : CompilerIrInstrList (opt-stale-load-test-instrs)])
                    (let ([stale-optimized : CompilerIrInstrList (opt-fold-instrs (OptConstNil) stale-instrs)])
                      (if (= (opt-count-arith-instrs stale-optimized) 1)
                          42
                          4)))
                  3)
              2)
          1))))
