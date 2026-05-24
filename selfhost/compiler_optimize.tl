;; compiler_optimize.tl - Selfhost optimizer: pass framework + scalar constant
;; folding (#543, first slice of #519).
;;
;; Runs between lowering (`lower-compiler-program`) and backend emission
;; (`compiler-backend-emit-program`). It performs conservative, scalar-only
;; constant folding: within each basic block it tracks IR vars defined by a
;; `Mov` of a scalar literal, and rewrites any `IrInstrBinOp`/`IrInstrUnOp`
;; whose operands resolve to those literals into an `IrInstrMov` of the computed
;; literal.
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

(define (opt-fold-instr [env : OptConstEnv] [instr : CompilerIrInstr]) : OptInstrResult
  (match instr
    [(IrInstrMov dst value ty)
     (if (opt-const-value? value)
         (OptInstrResult (opt-const-bind env dst value) instr)
         (OptInstrResult (opt-const-unbind env dst) instr))]
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
    [(IrInstrCall dst name args ty) (OptInstrResult (opt-const-unbind env dst) instr)]
    [(IrInstrPhi dst inputs ty) (OptInstrResult (opt-const-unbind env dst) instr)]
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

;; --- dead-code elimination (#544) --------------------------------------------
;;
;; Conservative DCE: collect every IR var id used as an operand across the whole
;; function, then drop pure temporary-producing instructions (Mov/BinOp/UnOp)
;; whose destination var is never used. Calls, stores, jumps, branches, returns,
;; and phi nodes are always preserved (side effects / control flow / SSA merges),
;; matching the Rust optimizer's first DCE slice. No CFG rewriting.

(defenum OptIntSet
  (OptIntNil)
  (OptIntCons i64 OptIntSet))

(define (opt-int-member? [set : OptIntSet] [x : i64]) : bool
  (match set
    [(OptIntNil) false]
    [(OptIntCons v rest) (if (= v x) true (opt-int-member? rest x))]))

(define (opt-int-add [set : OptIntSet] [x : i64]) : OptIntSet
  (if (opt-int-member? set x) set (OptIntCons x set)))

(define (dce-collect-value [used : OptIntSet] [value : CompilerIrValue]) : OptIntSet
  (match value
    [(IrValueVar id) (opt-int-add used id)]
    [_ used]))

(define (dce-collect-args [used : OptIntSet] [args : CompilerIrValueList]) : OptIntSet
  (match args
    [(IrValueNil) used]
    [(IrValueCons value rest) (dce-collect-args (dce-collect-value used value) rest)]))

(define (dce-collect-phi-inputs [used : OptIntSet] [inputs : CompilerIrPhiInputList]) : OptIntSet
  (match inputs
    [(IrPhiInputNil) used]
    [(IrPhiInputCons input rest)
     (match input
       [(IrPhiInput value _) (dce-collect-phi-inputs (dce-collect-value used value) rest)])]))

(define (dce-collect-maybe [used : OptIntSet] [maybe : CompilerIrMaybeValue]) : OptIntSet
  (match maybe
    [(IrNoValue) used]
    [(IrSomeValue value) (dce-collect-value used value)]))

(define (dce-collect-instr [used : OptIntSet] [instr : CompilerIrInstr]) : OptIntSet
  (match instr
    [(IrInstrMov _ value _) (dce-collect-value used value)]
    [(IrInstrAlloc _ _) used]
    [(IrInstrAddrOf _ src) (opt-int-add used src)]
    [(IrInstrGep _ base offset _) (dce-collect-value (dce-collect-value used base) offset)]
    [(IrInstrLoad _ src _) (dce-collect-value used src)]
    [(IrInstrStorePtr ptr value _) (dce-collect-value (dce-collect-value used ptr) value)]
    [(IrInstrCast _ src _ _) (dce-collect-value used src)]
    [(IrInstrBinOp _ _ l r _) (dce-collect-value (dce-collect-value used l) r)]
    [(IrInstrUnOp _ _ value _) (dce-collect-value used value)]
    [(IrInstrCall _ _ args _) (dce-collect-args used args)]
    [(IrInstrStore _ value _) (dce-collect-value used value)]
    [(IrInstrJump _) used]
    [(IrInstrBranch cond _ _) (dce-collect-value used cond)]
    [(IrInstrReturn maybe) (dce-collect-maybe used maybe)]
    [(IrInstrPhi _ inputs _) (dce-collect-phi-inputs used inputs)]))

(define (dce-collect-instrs [used : OptIntSet] [instrs : CompilerIrInstrList]) : OptIntSet
  (match instrs
    [(IrInstrNil) used]
    [(IrInstrCons instr rest) (dce-collect-instrs (dce-collect-instr used instr) rest)]))

(define (dce-collect-blocks [used : OptIntSet] [blocks : CompilerIrBlockList]) : OptIntSet
  (match blocks
    [(IrBlockNil) used]
    [(IrBlockCons block rest)
     (match block
       [(IrBlock _ instrs) (dce-collect-blocks (dce-collect-instrs used instrs) rest)])]))

;; A pure temporary def whose destination is unused may be removed.
(define (dce-instr-removable? [instr : CompilerIrInstr] [used : OptIntSet]) : bool
  (match instr
    [(IrInstrMov dst _ _) (not (opt-int-member? used dst))]
    [(IrInstrBinOp dst _ _ _ _) (not (opt-int-member? used dst))]
    [(IrInstrUnOp dst _ _ _) (not (opt-int-member? used dst))]
    [_ false]))

(define (dce-filter-instrs [instrs : CompilerIrInstrList] [used : OptIntSet]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrNil)]
    [(IrInstrCons instr rest)
     (if (dce-instr-removable? instr used)
         (dce-filter-instrs rest used)
         (IrInstrCons instr (dce-filter-instrs rest used)))]))

(define (dce-filter-blocks [blocks : CompilerIrBlockList] [used : OptIntSet]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
     (match block
       [(IrBlock label instrs)
        (IrBlockCons (IrBlock label (dce-filter-instrs instrs used)) (dce-filter-blocks rest used))])]))

(define (optimize-dce-blocks [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (dce-filter-blocks blocks (dce-collect-blocks (OptIntNil) blocks)))

(define (optimize-function [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(IrFunction name params ret-ty frame blocks)
     (IrFunction name params ret-ty frame (optimize-dce-blocks (optimize-block-list blocks)))]))

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

(define (opt-count-instrs [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons _ rest) (+ 1 (opt-count-instrs rest))]))

;; `[Mov v0=20, Mov v1=22, BinOp v2=v0+v1, Mov v3=99, Return v2]`. After folding,
;; v0/v1/v3 become unused literal Movs; only v2 (returned) is live.
(define (opt-dce-self-test-instrs) : CompilerIrInstrList
  (IrInstrCons (IrInstrMov 0 (IrValueI64 20) (AstTyI64))
    (IrInstrCons (IrInstrMov 1 (IrValueI64 22) (AstTyI64))
      (IrInstrCons (IrInstrBinOp 2 (IrBinAdd) (IrValueVar 0) (IrValueVar 1) (AstTyI64))
        (IrInstrCons (IrInstrMov 3 (IrValueI64 99) (AstTyI64))
          (IrInstrCons (IrInstrReturn (IrSomeValue (IrValueVar 2)))
            (IrInstrNil)))))))

(define (opt-dce-once [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (dce-filter-instrs instrs (dce-collect-instrs (OptIntNil) instrs)))

;; Folds then runs DCE: 5 instrs -> 2 (`Mov v2=42` + `Return v2`), the only live
;; Mov keeps value 42, the Return (control flow) survives, and DCE is idempotent.
(define (compiler-optimize-dce-ok?) : bool
  (let ([folded : CompilerIrInstrList (opt-fold-instrs (OptConstNil) (opt-dce-self-test-instrs))])
    (let ([dced : CompilerIrInstrList (opt-dce-once folded)])
      (let ([dced2 : CompilerIrInstrList (opt-dce-once dced)])
        (and (= (opt-count-instrs folded) 5)
             (and (= (opt-count-instrs dced) 2)
                  (and (= (opt-count-instrs dced2) 2)
                       (= (opt-sum-mov-i64 dced) 42))))))))

;; Returns 42 when folding turns the one arithmetic instruction into a `Mov`
;; literal whose value (20 + 22) is correct (before has 1 arithmetic instr,
;; after has 0, sum of all Mov i64 values is 20 + 22 + 42 = 84) and DCE removes
;; the unused temporaries while keeping the live value and control flow.
(define (compiler-optimize-self-test) : i64
  (let ([instrs : CompilerIrInstrList (opt-self-test-instrs)])
    (let ([optimized : CompilerIrInstrList (opt-fold-instrs (OptConstNil) instrs)])
      (if (= (opt-count-arith-instrs instrs) 1)
          (if (= (opt-count-arith-instrs optimized) 0)
              (if (= (opt-sum-mov-i64 optimized) 84)
                  (if (compiler-optimize-dce-ok?)
                      42
                      4)
                  3)
              2)
          1))))
