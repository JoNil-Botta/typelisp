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

(define (opt-const-bind
  [env : OptConstEnv]
  [var : i64]
  [value : CompilerIrValue]) : OptConstEnv
  (OptConstCons var value (opt-const-unbind env var)))

(define (opt-const-lookup [env : OptConstEnv] [var : i64]) : CompilerIrMaybeValue
  (match env
    [(OptConstNil) (IrNoValue)]
    [(OptConstCons id value rest)
      (if (= id var)
        (IrSomeValue value)
        (opt-const-lookup rest var))]))

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

(define (opt-fold-binop
  [op : CompilerIrBinOp]
  [l : CompilerIrValue]
  [r : CompilerIrValue]) : CompilerIrMaybeValue
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

(define (opt-invalidate-def
  [env : OptConstEnv]
  [dst : i64]
  [instr : CompilerIrInstr]) : OptInstrResult
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
          (OptInstrResult
            (opt-const-bind env dst folded)
            (IrInstrMov dst folded ty))]
        [(IrNoValue) (OptInstrResult (opt-const-unbind env dst) instr)])]
    [(IrInstrUnOp dst op v ty)
      (match (opt-fold-unop op (opt-resolve env v))
        [(IrSomeValue folded)
          (OptInstrResult
            (opt-const-bind env dst folded)
            (IrInstrMov dst folded ty))]
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

;; --- dead-code elimination (#544) --------------------------------------------

;;

;; Conservative DCE matching the Rust optimizer's first slice: collect every IR

;; var id referenced as an operand anywhere in the function, then drop pure

;; temporary-producing instructions (`Mov`/`BinOp`/`UnOp`/`Phi`) whose result is

;; never used. Calls, stores, jumps, branches, and returns are kept regardless

;; (they have side effects or drive control flow). The used set is gathered over

;; the *whole function* before any removal, so a var used in another block is

;; never dropped — no CFG analysis or unreachable-block removal is needed here.

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
    [(IrInstrStore _ value _) (opt-collect-value-uses set value)]
    ;; Pointer/memory ops carry operand uses too; missing any of these would let
    ;; DCE wrongly drop a definition that feeds an address/load/store/cast.
    [(IrInstrAddrOf _ src) (opt-used-add set src)]
    [(IrInstrGep _ base offset _)
      (opt-collect-value-uses (opt-collect-value-uses set base) offset)]
    [(IrInstrLoad _ src _) (opt-collect-value-uses set src)]
    [(IrInstrStorePtr ptr value _)
      (opt-collect-value-uses (opt-collect-value-uses set ptr) value)]
    [(IrInstrCast _ src _ _) (opt-collect-value-uses set src)]
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
        [(IrValueF64 fb) (= fa fb)]
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
      (let ([rest2 : OptExprTable (opt-expr-invalidate-var rest var)])
        (if (or (opt-key-uses-var? k var) (= v var))
          rest2
          (OptExprCons k v rest2)))]))

(defenum OptCseResult
  (OptCseResult OptExprTable CompilerIrInstr))

(define (opt-cse-instr [table : OptExprTable] [instr : CompilerIrInstr]) : OptCseResult
  (match instr
    [(IrInstrBinOp dst op l r ty)
      (let ([t1 : OptExprTable (opt-expr-invalidate-var table dst)])
        (let ([key : OptExprKey (OptBinKey op l r)])
          (match (opt-expr-lookup t1 key)
            [(IrSomeValue earlier)
              (OptCseResult t1 (IrInstrMov dst earlier ty))]
            [(IrNoValue) (OptCseResult (OptExprCons key dst t1) instr)])))]
    [(IrInstrUnOp dst op v ty)
      (let ([t1 : OptExprTable (opt-expr-invalidate-var table dst)])
        (let ([key : OptExprKey (OptUnKey op v)])
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
    ;; Calls, stores, and control flow clear all available expressions.
    [(IrInstrCall _ _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrStore _ _ _) (OptCseResult (OptExprNil) instr)]
    [(IrInstrStorePtr _ _ _) (OptCseResult (OptExprNil) instr)]
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

(define (optimize-block [block : CompilerIrBlock]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      ;; Fold scalar constants first, then eliminate repeated pure expressions.
      (IrBlock
        label
        (opt-cse-instrs (OptExprNil) (opt-fold-instrs (OptConstNil) instrs)))]))

(define (optimize-block-list [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockNil)]
    [(IrBlockCons block rest)
      (IrBlockCons (optimize-block block) (optimize-block-list rest))]))

(define (optimize-function [func : CompilerIrFunction]) : CompilerIrFunction
  (match func
    [(IrFunction name params ret-ty frame blocks)
      ;; Fold first (folding can turn used temporaries dead), then collect uses
      ;; across the folded function and eliminate dead pure assignments.
      (let ([folded : CompilerIrBlockList (optimize-block-list blocks)])
        (let ([used : OptUsedSet (opt-collect-blocks-uses (OptUsedNil) folded)])
          (IrFunction name params ret-ty frame (opt-dce-block-list used folded))))]))

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

;; Returns 42 when folding turns the one arithmetic instruction into a `Mov`

;; literal whose value (20 + 22) is correct, and a later `Load` redefining a

;; formerly-constant var invalidates the stale fact before another arithmetic

;; instruction reads that var.

(define (compiler-optimize-self-test) : i64
  (let ([instrs : CompilerIrInstrList (opt-self-test-instrs)])
    (let ([optimized
        :
        CompilerIrInstrList
        (opt-fold-instrs (OptConstNil) instrs)])
      (if (= (opt-count-arith-instrs instrs) 1)
        (if (= (opt-count-arith-instrs optimized) 0)
          (if (= (opt-sum-mov-i64 optimized) 84)
            (let ([stale-instrs
                :
                CompilerIrInstrList
                (opt-stale-load-test-instrs)])
              (let ([stale-optimized
                  :
                  CompilerIrInstrList
                  (opt-fold-instrs (OptConstNil) stale-instrs)])
                (if (= (opt-count-arith-instrs stale-optimized) 1)
                  42
                  4)))
            3)
          2)
        1))))

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
  (let ([instrs : CompilerIrInstrList (opt-dce-self-test-instrs)])
    (let ([used : OptUsedSet (opt-collect-instrs-uses (OptUsedNil) instrs)])
      (let ([cleaned : CompilerIrInstrList (opt-dce-instrs used instrs)])
        (let ([again
            :
            CompilerIrInstrList
            (opt-dce-instrs
              (opt-collect-instrs-uses (OptUsedNil) cleaned)
              cleaned)])
          (if (opt-used-contains used 1)
            (if (not (opt-used-contains used 0))
              (if (= (compiler-ir-instr-list-count instrs) 3)
                (if (= (compiler-ir-instr-list-count cleaned) 2)
                  (if (= (compiler-ir-instr-list-count again) 2)
                    42
                    4)
                  3)
                2)
              1)
            0))))))

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
  (let ([instrs : CompilerIrInstrList (opt-dce-mem-self-test-instrs)])
    (let ([used : OptUsedSet (opt-collect-instrs-uses (OptUsedNil) instrs)])
      (let ([cleaned : CompilerIrInstrList (opt-dce-instrs used instrs)])
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
  (let ([cse
      :
      CompilerIrInstrList
      (opt-cse-instrs (OptExprNil) (opt-cse-self-test-instrs))])
    (let ([store
        :
        CompilerIrInstrList
        (opt-cse-instrs (OptExprNil) (opt-cse-store-clears-instrs))])
      (let ([redef
          :
          CompilerIrInstrList
          (opt-cse-instrs (OptExprNil) (opt-cse-operand-redef-instrs))])
        (if (= (opt-count-arith-instrs cse) 1)
          (if (= (opt-count-arith-instrs store) 2)
            (if (= (opt-count-arith-instrs redef) 2)
              42
              3)
            2)
          1)))))