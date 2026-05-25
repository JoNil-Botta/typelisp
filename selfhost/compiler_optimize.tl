;; compiler_optimize.tl - Selfhost optimizer: pass framework + scalar constant
;; folding (#543, first slice of #519).
;;
;; Runs between lowering (`lower-compiler-program`) and backend emission
;; (`compiler-backend-emit-program`). It performs conservative, scalar-only
;; local rewrites: constant folding, algebraic strength reduction, CSE, copy
;; propagation, conservative CFG simplification, and DCE.
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
;; Out of scope: aggregate/String/array IR optimization.
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

;; --- strength reduction / algebraic identities (#924) -----------------------
;;
;; Rewrite only identities that are valid for all values of the instruction's
;; type. Division, modulo, and shifts intentionally have no identities here, so
;; potentially trapping/edge-sensitive operations stay in the IR.
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

(define (opt-bool-type? [ty : AstType]) : bool
  (match ty
    [(AstTyBool) true]
    [_ false]))

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

(define (opt-strength-instr [env : OptConstEnv] [instr : CompilerIrInstr]) : OptInstrResult
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
      (match (opt-strength-binop
        op
        l
        r
        (opt-resolve env l)
        (opt-resolve env r)
        ty)
        [(IrSomeValue replacement)
          (if (opt-const-value? replacement)
            (OptInstrResult
              (opt-const-bind env dst replacement)
              (IrInstrMov dst replacement ty))
            (OptInstrResult
              (opt-const-unbind env dst)
              (IrInstrMov dst replacement ty)))]
        [(IrNoValue) (OptInstrResult (opt-const-unbind env dst) instr)])]
    [(IrInstrUnOp dst op v ty) (opt-invalidate-def env dst instr)]
    [(IrInstrCall dst name args ty) (opt-invalidate-def env dst instr)]
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
    [(IrInstrCall ad aname aargs aty)
      (match b
        [(IrInstrCall bd bname bargs bty)
          (and
            (= ad bd)
            (and
              (string-eq aname bname)
              (and (opt-value-list-eq aargs bargs) (opt-type-eq aty bty))))]
        [_ false])]
    [(IrInstrStore aname av aty)
      (match b
        [(IrInstrStore bname bv bty)
          (and
            (string-eq aname bname)
            (and (opt-value-eq av bv) (opt-type-eq aty bty)))]
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
    [(IrExtern aname aty)
      (match b
        [(IrExtern bname bty)
          (and (string-eq aname bname) (opt-type-eq aty bty))])]))

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
    [(IrInstrCall dst name args ty)
      (IrInstrCall dst name (opt-copy-subst-value-list env args) ty)]
    [(IrInstrStore name value ty)
      (IrInstrStore name (opt-copy-resolve env value) ty)]
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
      ;; pure expressions, then propagate the resulting copies; function-level
      ;; DCE drops the dead copies.
      (IrBlock
        label
        (opt-copy-instrs
          (OptCopyNil)
          (opt-cse-instrs
            (OptExprNil)
            (opt-strength-instrs
              (OptConstNil)
              (opt-fold-instrs (OptConstNil) instrs)))))]))

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
                  42
                  4)))
            3)
          2)
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
      (if (= (opt-count-arith-instrs pos) 0)
        (if (= (opt-sum-mov-var-src pos) 49)
          (if (= (opt-count-mov-i64-value pos 0) 2)
            (if (= (opt-count-mov-bool-value pos false) 2)
              (if (= (opt-count-mov-bool-value pos true) 2)
                (if (= (opt-mov-dst-type-tag pos 10) (ast-type-tag (AstTyU8)))
                  (if (= (opt-count-arith-instrs neg) 5)
                    42
                    7)
                  6)
                5)
              4)
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

;; Returns 42 when block-local copy propagation: rewrites a var copy into a later
;; use (pos: lhs v1 -> v0); does not propagate after the source (src-redef) or
;; destination (dst-redef) var is redefined; rewrites a CSE-introduced copy so
;; DCE can drop it (cse: lhs v3 -> v2, then 3 instrs -> 2); and does not
;; propagate an unsafe F64 source (f64: lhs stays v1).
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
              (if (= (opt-copy-binop-lhs-var pos 2) 0)
                (if (= (opt-copy-binop-lhs-var src-redef 2) 1)
                  (if (= (opt-copy-binop-lhs-var dst-redef 2) 1)
                    (if (= (opt-copy-binop-lhs-var cse 4) 2)
                      (if (= (compiler-ir-instr-list-count cse-dce) 3)
                        (if (= (opt-copy-binop-lhs-var f64 2) 1)
                          42
                          6)
                        5)
                      4)
                    3)
                  2)
                1))))))))

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

(define (opt-test-function [instrs : CompilerIrInstrList]) : CompilerIrFunction
  (IrFunction
    "fixed"
    (IrParamNil)
    (AstTyI64)
    5
    (IrBlockCons (IrBlock "entry" instrs) (IrBlockNil))))

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
                (if (= (compiler-ir-instr-list-count once-instrs) 4)
                  (if (= (opt-count-arith-instrs once-instrs) 3)
                    (if (= (compiler-ir-instr-list-count fixed-instrs) 3)
                      (if (= (opt-count-arith-instrs fixed-instrs) 2)
                        (if (opt-program-eq optimized-program again-program)
                          42
                          5)
                        4)
                      3)
                    2)
                  1)))))))))