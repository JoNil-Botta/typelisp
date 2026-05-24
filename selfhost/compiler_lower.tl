;; compiler_lower.tl - First selfhost compiler AST-to-IR lowering slice (#446).
;;
;; The lowerer accepts the checked scalar subset and builds a deterministic
;; CompilerIrProgram. Aggregate, closure, match, and backend emission lowering
;; remain explicit future work.

(import "compiler_typecheck.tl")
(import "compiler_ir_types.tl")

(defenum LowerState
  (LowerState i64 i64 String CompilerIrInstrList CompilerIrBlockList))

(defenum LowerAlloc
  (LowerAlloc LowerState i64))

(defenum LowerLabel
  (LowerLabel LowerState String))

(defenum LowerExpr
  (LowerExpr LowerState CompilerIrValue AstType))

(defenum ResultLowerExpr
  (OkLowerExpr LowerExpr)
  (ErrLowerExpr String))

(defenum ResultLowerArgs
  (OkLowerArgs LowerState CompilerIrValueList)
  (ErrLowerArgs String))

(defenum ResultLowerEnv
  (OkLowerEnv LowerState SymI64Env TcTypeEnv)
  (ErrLowerEnv String))

(defenum ResultLowerValue
  (OkLowerValue CompilerIrValue)
  (ErrLowerValue String))

(defenum ResultLowerFunction
  (OkLowerFunction CompilerIrFunction)
  (ErrLowerFunction String))

(defenum ResultLowerDecls
  (OkLowerDecls CompilerIrGlobalList CompilerIrFunctionList CompilerIrExternList)
  (ErrLowerDecls String))

(defenum ResultCompilerLower
  (OkCompilerLower CompilerIrProgram)
  (ErrCompilerLower String))

(define (lower-instr-list-append [instrs : CompilerIrInstrList] [instr : CompilerIrInstr]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrCons instr IrInstrNil)]
    [(IrInstrCons head rest) (IrInstrCons head (lower-instr-list-append rest instr))]))

(define (lower-block-list-append [blocks : CompilerIrBlockList] [block : CompilerIrBlock]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockCons block IrBlockNil)]
    [(IrBlockCons head rest) (IrBlockCons head (lower-block-list-append rest block))]))

(define (lower-global-list-append [globals : CompilerIrGlobalList] [global : CompilerIrGlobal]) : CompilerIrGlobalList
  (match globals
    [(IrGlobalNil) (IrGlobalCons global IrGlobalNil)]
    [(IrGlobalCons head rest) (IrGlobalCons head (lower-global-list-append rest global))]))

(define (lower-function-list-append [functions : CompilerIrFunctionList] [func : CompilerIrFunction]) : CompilerIrFunctionList
  (match functions
    [(IrFunctionNil) (IrFunctionCons func IrFunctionNil)]
    [(IrFunctionCons head rest) (IrFunctionCons head (lower-function-list-append rest func))]))

(define (lower-extern-list-append [externs : CompilerIrExternList] [item : CompilerIrExtern]) : CompilerIrExternList
  (match externs
    [(IrExternNil) (IrExternCons item IrExternNil)]
    [(IrExternCons head rest) (IrExternCons head (lower-extern-list-append rest item))]))

(define (lower-state-next-var [state : LowerState]) : i64
  (match state
    [(LowerState next-var _ _ _ _) next-var]))

(define (lower-state-current-label [state : LowerState]) : String
  (match state
    [(LowerState _ _ label _ _) label]))

(define (lower-state-alloc-var [state : LowerState]) : LowerAlloc
  (match state
    [(LowerState next-var next-label current-label current-instrs blocks)
     (LowerAlloc
       (LowerState (+ next-var 1) next-label current-label current-instrs blocks)
       next-var)]))

(define (lower-state-fresh-label [state : LowerState] [prefix : String]) : LowerLabel
  (match state
    [(LowerState next-var next-label current-label current-instrs blocks)
     (LowerLabel
       (LowerState next-var (+ next-label 1) current-label current-instrs blocks)
       (string-append (string-append prefix ".") (int->string next-label)))]))

(define (lower-state-emit [state : LowerState] [instr : CompilerIrInstr]) : LowerState
  (match state
    [(LowerState next-var next-label current-label current-instrs blocks)
     (LowerState
       next-var
       next-label
       current-label
       (lower-instr-list-append current-instrs instr)
       blocks)]))

(define (lower-state-finish-block [state : LowerState] [next-label : String]) : LowerState
  (match state
    [(LowerState next-var next-label-id current-label current-instrs blocks)
     (LowerState
       next-var
       next-label-id
       next-label
       IrInstrNil
       (lower-block-list-append blocks (IrBlock current-label current-instrs)))]))

(define (lower-state-build-blocks [state : LowerState]) : CompilerIrBlockList
  (match state
    [(LowerState _ _ current-label current-instrs blocks)
     (lower-block-list-append blocks (IrBlock current-label current-instrs))]))

(define (lower-materialize [state : LowerState] [value : CompilerIrValue] [ty : AstType]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc allocated var-id)
     (OkLowerExpr
       (LowerExpr
         (lower-state-emit allocated (IrInstrMov var-id value ty))
         (IrValueVar var-id)
         ty))]))

(define (lower-literal-value [lit : AstLiteral]) : CompilerIrValue
  (match lit
    [(AstLitInt n) (IrValueI64 n)]
    [(AstLitFloat n) (IrValueF64 n)]
    [(AstLitBool b) (IrValueBool b)]
    [(AstLitChar c) (IrValueChar c)]
    [(AstLitString s) (IrValueString s)]
    [(AstLitUnit) IrValueUnit]))

(define (lower-binop [op : AstBinOp]) : CompilerIrBinOp
  (match op
    [(AstBinAdd) IrBinAdd]
    [(AstBinSub) IrBinSub]
    [(AstBinMul) IrBinMul]
    [(AstBinDiv) IrBinDiv]
    [(AstBinMod) IrBinMod]
    [(AstBinEq) IrBinEq]
    [(AstBinNe) IrBinNe]
    [(AstBinLt) IrBinLt]
    [(AstBinLe) IrBinLe]
    [(AstBinGt) IrBinGt]
    [(AstBinGe) IrBinGe]
    [(AstBinAnd) IrBinAnd]
    [(AstBinOr) IrBinOr]
    [(AstBinBitAnd) IrBinBitAnd]
    [(AstBinBitOr) IrBinBitOr]
    [(AstBinBitXor) IrBinBitXor]
    [(AstBinShl) IrBinShl]
    [(AstBinShr) IrBinShr]))

(define (lower-unop [op : AstUnOp]) : CompilerIrUnOp
  (match op
    [(AstUnNeg) IrUnNeg]
    [(AstUnNot) IrUnNot]
    [(AstUnBitNot) IrUnBitNot]))

(define (lower-var [state : LowerState] [env : SymI64Env] [name : String] [ty : AstType]) : ResultLowerExpr
  (match (sym-i64-lookup env name)
    [(SomeI64 id) (lower-materialize state (IrValueVar id) ty)]
    [(NoneI64) (lower-materialize state (IrValueGlobal name) ty)]))

(define (lower-return-maybe [value : CompilerIrValue] [ty : AstType]) : CompilerIrMaybeValue
  (match ty
    [(AstTyUnit) IrNoValue]
    [_ (IrSomeValue value)]))

(define (lower-expr [ctx : TcContext] [state : LowerState] [env : SymI64Env] [type-env : TcTypeEnv] [expr : AstExpr]) : ResultLowerExpr
  (match (tc-expr ctx type-env expr)
    [(OkTcType expr-ty) (lower-expr-with-type ctx state env type-env expr expr-ty)]
    [(ErrTcType message) (ErrLowerExpr message)]))

(define (lower-expr-with-type [ctx : TcContext] [state : LowerState] [env : SymI64Env] [type-env : TcTypeEnv] [expr : AstExpr] [expr-ty : AstType]) : ResultLowerExpr
  (match expr
    [(AstExprSpanned inner _) (lower-expr ctx state env type-env inner)]
    [(AstExprLiteral lit) (lower-materialize state (lower-literal-value lit) expr-ty)]
    [(AstExprVar name) (lower-var state env name expr-ty)]
    [(AstExprAnn inner _)
     (match (lower-expr ctx state env type-env inner)
       [(OkLowerExpr lowered)
        (match lowered
          [(LowerExpr inner-state value _) (OkLowerExpr (LowerExpr inner-state value expr-ty))])]
       [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprCast inner _)
     (match (lower-expr ctx state env type-env inner)
       [(OkLowerExpr lowered)
        (match lowered
          [(LowerExpr inner-state value _) (lower-materialize inner-state value expr-ty)])]
       [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprUnary op inner)
     (match (lower-expr ctx state env type-env inner)
       [(OkLowerExpr lowered)
        (match lowered
          [(LowerExpr inner-state value _)
           (match (lower-state-alloc-var inner-state)
             [(LowerAlloc allocated var-id)
              (OkLowerExpr
                (LowerExpr
                  (lower-state-emit allocated (IrInstrUnOp var-id (lower-unop op) value expr-ty))
                  (IrValueVar var-id)
                  expr-ty))])])]
       [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprBinary op left right)
     (match (lower-expr ctx state env type-env left)
       [(OkLowerExpr left-lowered)
        (match left-lowered
          [(LowerExpr left-state left-value _)
           (match (lower-expr ctx left-state env type-env right)
             [(OkLowerExpr right-lowered)
              (match right-lowered
                [(LowerExpr right-state right-value _)
                 (match (lower-state-alloc-var right-state)
                   [(LowerAlloc allocated var-id)
                    (OkLowerExpr
                      (LowerExpr
                        (lower-state-emit
                          allocated
                          (IrInstrBinOp var-id (lower-binop op) left-value right-value expr-ty))
                        (IrValueVar var-id)
                        expr-ty))])])]
             [(ErrLowerExpr message) (ErrLowerExpr message)])])]
       [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprCall func args) (lower-call ctx state env type-env func args expr-ty)]
    [(AstExprLet bindings body)
     (match (lower-let-bindings ctx state env type-env bindings)
       [(OkLowerEnv binding-state body-env body-type-env)
        (lower-expr ctx binding-state body-env body-type-env body)]
       [(ErrLowerEnv message) (ErrLowerExpr message)])]
    [(AstExprBegin exprs) (lower-begin ctx state env type-env exprs)]
    [(AstExprSet name value)
     (match (lower-expr ctx state env type-env value)
       [(OkLowerExpr lowered)
        (match lowered
          [(LowerExpr value-state value-ir value-ty)
           (match (sym-i64-lookup env name)
             [(SomeI64 id)
              (OkLowerExpr
                (LowerExpr
                  (lower-state-emit value-state (IrInstrMov id value-ir value-ty))
                  IrValueUnit
                  expr-ty))]
             [(NoneI64)
              (match (tc-lookup type-env name)
                [(OkTcType store-ty)
                 (OkLowerExpr
                   (LowerExpr
                     (lower-state-emit value-state (IrInstrStore name value-ir store-ty))
                     IrValueUnit
                     expr-ty))]
                [(ErrTcType _) (ErrLowerExpr (string-append "lower: assignment to unknown local " name))])])])]
       [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprIf cond then-branch else-branch)
     (lower-if ctx state env type-env cond then-branch else-branch expr-ty)]
    [(AstExprWhile cond body)
     (lower-while ctx state env type-env cond body)]
    [(AstExprMatch scrutinee arms)
     (lower-match ctx state env type-env scrutinee arms expr-ty)]
    [_ (ErrLowerExpr "lower: unsupported expression")]))

(define (lower-call [ctx : TcContext] [state : LowerState] [env : SymI64Env] [type-env : TcTypeEnv] [func : AstExpr] [args : AstExprList] [result-ty : AstType]) : ResultLowerExpr
  (match func
    [(AstExprVar name)
     (match (lower-args ctx state env type-env args)
       [(OkLowerArgs args-state values)
        (match (lower-state-alloc-var args-state)
          [(LowerAlloc allocated var-id)
           (OkLowerExpr
             (LowerExpr
               (lower-state-emit allocated (IrInstrCall var-id name values result-ty))
               (IrValueVar var-id)
               result-ty))])]
       [(ErrLowerArgs message) (ErrLowerExpr message)])]
    [_ (ErrLowerExpr "lower: only direct calls are supported")]))

(define (lower-args [ctx : TcContext] [state : LowerState] [env : SymI64Env] [type-env : TcTypeEnv] [args : AstExprList]) : ResultLowerArgs
  (match args
    [(AstExprNil) (OkLowerArgs state IrValueNil)]
    [(AstExprCons arg rest)
     (match (lower-expr ctx state env type-env arg)
       [(OkLowerExpr lowered)
        (match lowered
          [(LowerExpr arg-state value _)
           (match (lower-args ctx arg-state env type-env rest)
             [(OkLowerArgs rest-state rest-values)
              (OkLowerArgs rest-state (IrValueCons value rest-values))]
             [(ErrLowerArgs message) (ErrLowerArgs message)])])]
       [(ErrLowerExpr message) (ErrLowerArgs message)])]))

(define (lower-let-binding-type [ctx : TcContext] [maybe-ty : AstMaybeType] [init-ty : AstType]) : AstType
  (match maybe-ty
    [(AstSomeType ty) (tc-resolve-type ctx ty)]
    [(AstNoType) init-ty]))

(define (lower-let-bindings [ctx : TcContext] [state : LowerState] [env : SymI64Env] [type-env : TcTypeEnv] [bindings : AstLetBindingList]) : ResultLowerEnv
  (match bindings
    [(AstLetBindingNil) (OkLowerEnv state env type-env)]
    [(AstLetBindingCons binding rest)
     (match binding
       [(AstLetBinding name maybe-ty init)
        (match (lower-expr ctx state env type-env init)
          [(OkLowerExpr lowered)
           (match lowered
             [(LowerExpr init-state init-value init-ty)
              (let ([binding-ty : AstType (lower-let-binding-type ctx maybe-ty init-ty)])
                (match (lower-state-alloc-var init-state)
                  [(LowerAlloc allocated var-id)
                   (lower-let-bindings
                     ctx
                     (lower-state-emit allocated (IrInstrMov var-id init-value binding-ty))
                     (sym-i64-bind env name var-id)
                     (tc-bind type-env name binding-ty)
                     rest)]))])]
          [(ErrLowerExpr message) (ErrLowerEnv message)])])]))

(define (lower-begin [ctx : TcContext] [state : LowerState] [env : SymI64Env] [type-env : TcTypeEnv] [exprs : AstExprList]) : ResultLowerExpr
  (match exprs
    [(AstExprNil) (OkLowerExpr (LowerExpr state IrValueUnit (AstTyUnit)))]
    [(AstExprCons expr rest)
     (match rest
       [(AstExprNil) (lower-expr ctx state env type-env expr)]
       [_ (match (lower-expr ctx state env type-env expr)
            [(OkLowerExpr lowered)
             (match lowered
               [(LowerExpr next-state _ _) (lower-begin ctx next-state env type-env rest)])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])])]))

(define (lower-if-merge [else-state : LowerState] [then-value : CompilerIrValue] [then-end-label : String] [else-value : CompilerIrValue] [merge-label : String] [expr-ty : AstType]) : ResultLowerExpr
  (let ([else-end-label : String (lower-state-current-label else-state)])
    (let ([merge-start : LowerState
           (lower-state-finish-block
             (lower-state-emit else-state (IrInstrJump merge-label))
             merge-label)])
      (match (lower-state-alloc-var merge-start)
        [(LowerAlloc allocated var-id)
         (OkLowerExpr
           (LowerExpr
             (lower-state-emit
               allocated
               (IrInstrPhi
                 var-id
                 (IrPhiInputCons
                   (IrPhiInput then-value then-end-label)
                   (IrPhiInputCons
                     (IrPhiInput else-value else-end-label)
                     IrPhiInputNil))
                 expr-ty))
             (IrValueVar var-id)
             expr-ty))]))))

(define (lower-if-else [ctx : TcContext] [else-start : LowerState] [env : SymI64Env] [type-env : TcTypeEnv] [else-branch : AstExpr] [then-value : CompilerIrValue] [then-end-label : String] [merge-label : String] [expr-ty : AstType]) : ResultLowerExpr
  (match (lower-expr ctx else-start env type-env else-branch)
    [(OkLowerExpr else-lowered)
     (match else-lowered
       [(LowerExpr else-state else-value _)
        (lower-if-merge else-state then-value then-end-label else-value merge-label expr-ty)])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-if-then [ctx : TcContext] [then-start : LowerState] [env : SymI64Env] [type-env : TcTypeEnv] [then-branch : AstExpr] [else-branch : AstExpr] [else-label : String] [merge-label : String] [expr-ty : AstType]) : ResultLowerExpr
  (match (lower-expr ctx then-start env type-env then-branch)
    [(OkLowerExpr then-lowered)
     (match then-lowered
       [(LowerExpr then-state then-value _)
        (let ([then-end-label : String (lower-state-current-label then-state)])
          (let ([else-start : LowerState
                 (lower-state-finish-block
                   (lower-state-emit then-state (IrInstrJump merge-label))
                   else-label)])
            (lower-if-else
              ctx
              else-start
              env
              type-env
              else-branch
              then-value
              then-end-label
              merge-label
              expr-ty)))])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-if [ctx : TcContext] [state : LowerState] [env : SymI64Env] [type-env : TcTypeEnv] [cond : AstExpr] [then-branch : AstExpr] [else-branch : AstExpr] [expr-ty : AstType]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env cond)
    [(OkLowerExpr cond-lowered)
     (match cond-lowered
       [(LowerExpr cond-state cond-value _)
        (match (lower-state-fresh-label cond-state "if_then")
          [(LowerLabel then-label-state then-label)
           (match (lower-state-fresh-label then-label-state "if_else")
             [(LowerLabel else-label-state else-label)
              (match (lower-state-fresh-label else-label-state "if_merge")
                [(LowerLabel merge-label-state merge-label)
                 (let ([branch-state : LowerState
                        (lower-state-emit merge-label-state (IrInstrBranch cond-value then-label else-label))])
                   (lower-if-then
                     ctx
                     (lower-state-finish-block branch-state then-label)
                     env
                     type-env
                     then-branch
                     else-branch
                     else-label
                     merge-label
                     expr-ty))])])])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-while [ctx : TcContext] [state : LowerState] [env : SymI64Env] [type-env : TcTypeEnv] [cond : AstExpr] [body : AstExpr]) : ResultLowerExpr
  (match (lower-state-fresh-label state "while_header")
    [(LowerLabel header-label-state header-label)
     (match (lower-state-fresh-label header-label-state "while_body")
       [(LowerLabel body-label-state body-label)
        (match (lower-state-fresh-label body-label-state "while_exit")
          [(LowerLabel exit-label-state exit-label)
           (let ([header-start : LowerState
                  (lower-state-finish-block
                    (lower-state-emit exit-label-state (IrInstrJump header-label))
                    header-label)])
             (match (lower-expr ctx header-start env type-env cond)
               [(OkLowerExpr cond-lowered)
                (match cond-lowered
                  [(LowerExpr cond-state cond-value _)
                   (let ([body-start : LowerState
                          (lower-state-finish-block
                            (lower-state-emit cond-state (IrInstrBranch cond-value body-label exit-label))
                            body-label)])
                     (match (lower-expr ctx body-start env type-env body)
                       [(OkLowerExpr body-lowered)
                        (match body-lowered
                          [(LowerExpr body-state _ _)
                           (OkLowerExpr
                             (LowerExpr
                               (lower-state-finish-block
                                 (lower-state-emit body-state (IrInstrJump header-label))
                                 exit-label)
                               IrValueUnit
                               (AstTyUnit)))])]
                       [(ErrLowerExpr message) (ErrLowerExpr message)]))])]
               [(ErrLowerExpr message) (ErrLowerExpr message)]))])])]))

;; Scalar `match` lowering (#568). The scrutinee is lowered once into a fresh
;; local, then literal arms become a chain of `IrBinEq` tests + `IrInstrBranch`
;; (mirroring `lower-if`). The typechecker guarantees exhaustiveness and arm-type
;; agreement, so the final arm reached must match: it is lowered as an
;; irrefutable catch-all (no test, jump straight to the merge block). A
;; value-typed match merges arm results with an `IrInstrPhi`; a `unit`-typed
;; match emits no value phi. Enum/variant dispatch stays in #517.
(define (lower-match [ctx : TcContext] [state : LowerState] [env : SymI64Env] [type-env : TcTypeEnv] [scrutinee : AstExpr] [arms : AstMatchArmList] [expr-ty : AstType]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env scrutinee)
    [(OkLowerExpr scrut-lowered)
     (match scrut-lowered
       [(LowerExpr scrut-state scrut-value scrut-ty)
        (match (lower-state-alloc-var scrut-state)
          [(LowerAlloc scrut-alloc scrut-var)
           (match (lower-state-fresh-label
                    (lower-state-emit scrut-alloc (IrInstrMov scrut-var scrut-value scrut-ty))
                    "match_merge")
             [(LowerLabel merge-state merge-label)
              (lower-match-arms ctx merge-state env type-env scrut-var scrut-ty arms merge-label expr-ty IrPhiInputNil)])])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-match-arms [ctx : TcContext] [state : LowerState] [env : SymI64Env] [type-env : TcTypeEnv] [scrut-var : i64] [scrut-ty : AstType] [arms : AstMatchArmList] [merge-label : String] [expr-ty : AstType] [phi-inputs : CompilerIrPhiInputList]) : ResultLowerExpr
  (match arms
    [(AstMatchArmNil) (ErrLowerExpr "lower: match with no arms")]
    [(AstMatchArmCons arm rest)
     (match rest
       [(AstMatchArmNil)
        (lower-match-catch-all ctx state env type-env scrut-var scrut-ty arm merge-label expr-ty phi-inputs)]
       [_
        (match arm
          [(AstMatchArm pat body)
           (match pat
             [(AstPatLiteral lit)
              (lower-match-literal-arm ctx state env type-env scrut-var scrut-ty lit body rest merge-label expr-ty phi-inputs)]
             [(AstPatBinding _)
              (lower-match-catch-all ctx state env type-env scrut-var scrut-ty arm merge-label expr-ty phi-inputs)]
             [(AstPatWildcard)
              (lower-match-catch-all ctx state env type-env scrut-var scrut-ty arm merge-label expr-ty phi-inputs)]
             [_ (ErrLowerExpr "lower: unsupported match pattern")])])])]))

(define (lower-match-literal-arm [ctx : TcContext] [state : LowerState] [env : SymI64Env] [type-env : TcTypeEnv] [scrut-var : i64] [scrut-ty : AstType] [lit : AstLiteral] [body : AstExpr] [rest : AstMatchArmList] [merge-label : String] [expr-ty : AstType] [phi-inputs : CompilerIrPhiInputList]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc eq-alloc eq-var)
     (let ([eq-state : LowerState
            (lower-state-emit eq-alloc
              (IrInstrBinOp eq-var IrBinEq (IrValueVar scrut-var) (lower-literal-value lit) scrut-ty))])
       (match (lower-state-fresh-label eq-state "match_arm")
         [(LowerLabel body-label-state body-label)
          (match (lower-state-fresh-label body-label-state "match_next")
            [(LowerLabel next-label-state next-label)
             (let ([body-start : LowerState
                    (lower-state-finish-block
                      (lower-state-emit next-label-state (IrInstrBranch (IrValueVar eq-var) body-label next-label))
                      body-label)])
               (match (lower-expr ctx body-start env type-env body)
                 [(OkLowerExpr body-lowered)
                  (match body-lowered
                    [(LowerExpr body-state body-value _)
                     (let ([body-end-label : String (lower-state-current-label body-state)])
                       (lower-match-arms
                         ctx
                         (lower-state-finish-block
                           (lower-state-emit body-state (IrInstrJump merge-label))
                           next-label)
                         env
                         type-env
                         scrut-var
                         scrut-ty
                         rest
                         merge-label
                         expr-ty
                         (IrPhiInputCons (IrPhiInput body-value body-end-label) phi-inputs)))])]
                 [(ErrLowerExpr message) (ErrLowerExpr message)]))])]))]))

(define (lower-match-catch-all [ctx : TcContext] [state : LowerState] [env : SymI64Env] [type-env : TcTypeEnv] [scrut-var : i64] [scrut-ty : AstType] [arm : AstMatchArm] [merge-label : String] [expr-ty : AstType] [phi-inputs : CompilerIrPhiInputList]) : ResultLowerExpr
  (match arm
    [(AstMatchArm pat body)
     (let ([body-env : SymI64Env
            (match pat
              [(AstPatBinding name) (sym-i64-bind env name scrut-var)]
              [_ env])]
           [body-type-env : TcTypeEnv
            (match pat
              [(AstPatBinding name) (tc-bind type-env name scrut-ty)]
              [_ type-env])])
       (match (lower-expr ctx state body-env body-type-env body)
         [(OkLowerExpr body-lowered)
          (match body-lowered
            [(LowerExpr body-state body-value _)
             (let ([body-end-label : String (lower-state-current-label body-state)])
               (lower-match-finish
                 (lower-state-emit body-state (IrInstrJump merge-label))
                 merge-label
                 expr-ty
                 (IrPhiInputCons (IrPhiInput body-value body-end-label) phi-inputs)))])]
         [(ErrLowerExpr message) (ErrLowerExpr message)]))]))

(define (lower-match-finish [state : LowerState] [merge-label : String] [expr-ty : AstType] [phi-inputs : CompilerIrPhiInputList]) : ResultLowerExpr
  (let ([merge-start : LowerState (lower-state-finish-block state merge-label)])
    (match expr-ty
      [(AstTyUnit) (OkLowerExpr (LowerExpr merge-start IrValueUnit expr-ty))]
      [_
       (match (lower-state-alloc-var merge-start)
         [(LowerAlloc allocated var-id)
          (OkLowerExpr
            (LowerExpr
              (lower-state-emit allocated (IrInstrPhi var-id phi-inputs expr-ty))
              (IrValueVar var-id)
              expr-ty))])])))

(define (lower-param-count [params : AstParamList]) : i64
  (match params
    [(AstParamNil) 0]
    [(AstParamCons _ rest) (+ 1 (lower-param-count rest))]))

(define (lower-bind-params [params : AstParamList] [idx : i64] [env : SymI64Env]) : SymI64Env
  (match params
    [(AstParamNil) env]
    [(AstParamCons param rest)
     (match param
       [(AstParam name _) (lower-bind-params rest (+ idx 1) (sym-i64-bind env name idx))])]))

(define (lower-param-list [ctx : TcContext] [params : AstParamList] [idx : i64]) : CompilerIrParamList
  (match params
    [(AstParamNil) IrParamNil]
    [(AstParamCons param rest)
     (match param
       [(AstParam name ty)
        (IrParamCons
          (IrParam name (tc-resolve-type ctx ty) idx)
          (lower-param-list ctx rest (+ idx 1)))])]))

(define (lower-function [ctx : TcContext] [top-env : TcTypeEnv] [name : String] [params : AstParamList] [ret : AstType] [body : AstExpr]) : ResultLowerFunction
  (let ([param-count : i64 (lower-param-count params)])
    (let ([env : SymI64Env (lower-bind-params params 0 (sym-i64-empty))]
          [type-env : TcTypeEnv (tc-bind-params ctx top-env params)]
          [state : LowerState (LowerState param-count 0 "entry" IrInstrNil IrBlockNil)]
          [ret-ty : AstType (tc-resolve-type ctx ret)])
      (match (lower-expr ctx state env type-env body)
        [(OkLowerExpr lowered)
         (match lowered
           [(LowerExpr body-state value _)
            (let ([final-state : LowerState
                   (lower-state-emit body-state (IrInstrReturn (lower-return-maybe value ret-ty)))])
              (OkLowerFunction
                (IrFunction
                  name
                  (lower-param-list ctx params 0)
                  ret-ty
                  (lower-state-next-var final-state)
                  (lower-state-build-blocks final-state))))])]
        [(ErrLowerExpr message) (ErrLowerFunction message)]))))

(define (lower-global-value [expr : AstExpr]) : ResultLowerValue
  (match expr
    [(AstExprSpanned inner _) (lower-global-value inner)]
    [(AstExprAnn inner _) (lower-global-value inner)]
    [(AstExprCast inner _) (lower-global-value inner)]
    [(AstExprLiteral lit) (OkLowerValue (lower-literal-value lit))]
    [(AstExprVar name) (OkLowerValue (IrValueGlobal name))]
    [_ (ErrLowerValue "lower: unsupported global initializer")]))

(define (lower-decls [ctx : TcContext] [top-env : TcTypeEnv] [decls : AstDeclList] [globals : CompilerIrGlobalList] [functions : CompilerIrFunctionList] [externs : CompilerIrExternList]) : ResultLowerDecls
  (match decls
    [(AstDeclNil) (OkLowerDecls globals functions externs)]
    [(AstDeclCons decl rest)
     (match decl
       [(AstDeclDef name _ expr)
        (match (tc-top-decl-type ctx decl)
          [(OkTcType ty)
           (match (lower-global-value expr)
             [(OkLowerValue value)
              (lower-decls
                ctx
                top-env
                rest
                (lower-global-list-append globals (IrGlobal name ty value))
                functions
                externs)]
             [(ErrLowerValue message) (ErrLowerDecls message)])]
          [(ErrTcType message) (ErrLowerDecls message)])]
       [(AstDeclExtern name ty)
        (lower-decls
          ctx
          top-env
          rest
          globals
          functions
          (lower-extern-list-append externs (IrExtern name (tc-resolve-type ctx ty))))]
       [(AstDeclDefFn name params ret body)
        (match (lower-function ctx top-env name params ret body)
          [(OkLowerFunction func)
           (lower-decls
             ctx
             top-env
             rest
             globals
             (lower-function-list-append functions func)
             externs)]
          [(ErrLowerFunction message) (ErrLowerDecls message)])]
       [(AstDeclImport _) (lower-decls ctx top-env rest globals functions externs)]
       [(AstDeclDefEnum _ _) (lower-decls ctx top-env rest globals functions externs)]
       [(AstDeclDefStruct _ _) (lower-decls ctx top-env rest globals functions externs)])]))

(define (lower-compiler-program-checked [ctx : TcContext] [top-env : TcTypeEnv] [program : AstProgram]) : ResultCompilerLower
  (match program
    [(AstProgram decls)
     (match (lower-decls ctx top-env decls IrGlobalNil IrFunctionNil IrExternNil)
       [(OkLowerDecls globals functions externs)
        (OkCompilerLower (IrProgram globals functions externs))]
       [(ErrLowerDecls message) (ErrCompilerLower message)])]))

(define (lower-compiler-program [program : AstProgram]) : ResultCompilerLower
  (match (typecheck-compiler-program program)
    [(OkCompilerTypecheck _)
     (match (build-compiler-symbols program)
       [(OkCompilerSymbols symbols)
        (match (build-compiler-registries program)
          [(OkCompilerRegistries registries)
           (let ([ctx : TcContext (TcContext program symbols registries)])
             (match (tc-build-top-env ctx program)
               [(OkTcEnv top-env) (lower-compiler-program-checked ctx top-env program)]
               [(ErrTcEnv message) (ErrCompilerLower message)]))]
          [(ErrCompilerRegistries message) (ErrCompilerLower message)])]
       [(ErrCompilerSymbols message) (ErrCompilerLower message)])]
    [(ErrCompilerTypecheck message) (ErrCompilerLower message)]))

(define (lower-compiler-source [src : String]) : ResultCompilerLower
  (match (parse-ast-source src)
    [(OkAstProgram program) (lower-compiler-program program)]
    [(ErrAstProgram message) (ErrCompilerLower message)]))

(define (compiler-lower-smoke-source) : String
  "(extern print-i64 : (-> i64 unit))
(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x 1))
(define (main [flag : bool]) : i64
  (let ([x : i64 (inc answer)])
    (begin
      (set! x (+ x 1))
      (while (< x 45)
        (set! x (+ x 1)))
      (if flag x 0))))")

(define (compiler-lower-unsupported-source) : String
  "(define (main) : (Tuple i64 bool)
  (tuple 1 true))")

(define (compiler-lower-error-ok? [src : String] [want : String]) : bool
  (match (lower-compiler-source src)
    [(ErrCompilerLower message) (string-eq message want)]
    [(OkCompilerLower _) false]))

;; Scalar match lowering smoke (#568): an i64 literal match with a binding
;; catch-all (value-returning), an exhaustive bool match, and a unit-typed match.
(define (compiler-lower-match-source) : String
  "(extern print-i64 : (-> i64 unit))
(define (classify [n : i64]) : i64
  (match n
    [0 100]
    [1 200]
    [other (+ other 1)]))
(define (flag-score [b : bool]) : i64
  (match b
    [true 1]
    [false 0]))
(define (sign [n : i64]) : i64
  (match n
    [0 0]
    [_ 1]))
(define (announce [n : i64]) : unit
  (match n
    [0 (print-i64 0)]
    [other (print-i64 other)]))
(define (main) : i64
  (begin
    (announce (classify 1))
    (+ (sign 7) (+ (classify 1) (flag-score true)))))")

(define (compiler-lower-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower _) true]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-ok-summary? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program)
     (let ([summary : CompilerIrSummary (compiler-ir-program-summary program)])
       (and (= (compiler-ir-summary-globals summary) 1)
            (and (= (compiler-ir-summary-functions summary) 2)
                 (and (= (compiler-ir-summary-externs summary) 1)
                      (and (= (compiler-ir-summary-blocks summary) 8)
                           (and (= (compiler-ir-summary-instructions summary) 29)
                                (= (compiler-ir-summary-vars summary) 21)))))))]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-self-test) : i64
  (if (and (compiler-lower-ok-summary? (compiler-lower-smoke-source))
           (and (compiler-lower-ok? (compiler-lower-match-source))
                (and (compiler-lower-error-ok? (compiler-typecheck-branch-mismatch-source)
                                               "typecheck: if branches must match")
                     (compiler-lower-error-ok? (compiler-lower-unsupported-source)
                                               "lower: unsupported expression"))))
      42
      (begin
        (panic "lower: smoke score mismatch")
        0)))
