;; compiler_lower.tl - Selfhost compiler AST-to-IR lowering slice (#446).
;;
;; This pass lowers the checked scalar subset into a concrete CompilerIrProgram:
;; globals, externs, functions, basic blocks, and typed instructions. Aggregate,
;; enum/match, closure, and backend emission work stays explicit future work.

(import "compiler_typecheck.tl")
(import "compiler_ir_types.tl")

(defenum LowerState
  (LowerState i64 i64 String CompilerIrInstrList CompilerIrBlockList))

(defenum LowerAlloc
  (LowerAlloc LowerState i64))

(defenum LowerLabelAlloc
  (LowerLabelAlloc LowerState i64))

(defenum LowerExpr
  (LowerExpr LowerState CompilerIrValue AstType))

(defenum ResultLowerExpr
  (OkLowerExpr LowerExpr)
  (ErrLowerExpr String))

(defenum ResultLowerArgs
  (OkLowerArgs LowerState CompilerIrValueList)
  (ErrLowerArgs String))

(defenum LowerEnv
  (LowerEnv LowerState SymI64Env TcTypeEnv))

(defenum ResultLowerEnv
  (OkLowerEnv LowerEnv)
  (ErrLowerEnv String))

(defenum ResultLowerValue
  (OkLowerValue CompilerIrValue)
  (ErrLowerValue String))

(defenum ResultLowerFunction
  (OkLowerFunction CompilerIrFunction)
  (ErrLowerFunction String))

(defenum ResultCompilerLower
  (OkCompilerLower CompilerIrProgram)
  (ErrCompilerLower String))

(define (lower-type-unit? [ty : AstType]) : bool
  (match ty
    [(AstTyUnit) true]
    [_ false]))

(define (lower-state-emit [state : LowerState] [instr : CompilerIrInstr]) : LowerState
  (match state
    [(LowerState next-var next-label current-label instrs blocks)
     (LowerState next-var next-label current-label (IrInstrCons instr instrs) blocks)]))

(define (lower-state-alloc-var [state : LowerState]) : LowerAlloc
  (match state
    [(LowerState next-var next-label current-label instrs blocks)
     (LowerAlloc
       (LowerState (+ next-var 1) next-label current-label instrs blocks)
       next-var)]))

(define (lower-state-alloc-label [state : LowerState]) : LowerLabelAlloc
  (match state
    [(LowerState next-var next-label current-label instrs blocks)
     (LowerLabelAlloc
       (LowerState next-var (+ next-label 1) current-label instrs blocks)
       next-label)]))

(define (lower-state-start-block [state : LowerState] [label : String]) : LowerState
  (match state
    [(LowerState next-var next-label current-label instrs blocks)
     (LowerState
       next-var
       next-label
       label
       IrInstrNil
       (IrBlockCons
         (IrBlock current-label (compiler-ir-instr-list-reverse instrs))
         blocks))]))

(define (lower-state-finish-blocks [state : LowerState]) : CompilerIrBlockList
  (match state
    [(LowerState _ _ current-label instrs blocks)
     (compiler-ir-block-list-reverse
       (IrBlockCons
         (IrBlock current-label (compiler-ir-instr-list-reverse instrs))
         blocks))]))

(define (lower-label [prefix : String] [id : i64] [suffix : String]) : String
  (string-append (string-append prefix (int->string id)) suffix))

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

(define (lower-return-value [value : CompilerIrValue] [ty : AstType]) : CompilerIrMaybeValue
  (if (lower-type-unit? ty)
      IrNoValue
      (IrSomeValue value)))

(define (lower-var [state : LowerState] [env : SymI64Env] [tc-env : TcTypeEnv] [name : String]) : ResultLowerExpr
  (match (tc-lookup tc-env name)
    [(OkTcType ty)
     (match (sym-i64-lookup env name)
       [(SomeI64 id) (OkLowerExpr (LowerExpr state (IrValueVar id) ty))]
       [(NoneI64) (OkLowerExpr (LowerExpr state (IrValueGlobal name) ty))])]
    [(ErrTcType message) (ErrLowerExpr message)]))

(define (lower-emit-mov [state : LowerState] [value : CompilerIrValue] [ty : AstType]) : LowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc allocated var-id)
     (LowerExpr
       (lower-state-emit allocated (IrInstrMov var-id value ty))
       (IrValueVar var-id)
       ty)]))

(define (lower-expr [ctx : TcContext] [state : LowerState] [env : SymI64Env] [tc-env : TcTypeEnv] [expr : AstExpr]) : ResultLowerExpr
  (match expr
    [(AstExprSpanned inner _) (lower-expr ctx state env tc-env inner)]
    [(AstExprLiteral lit)
     (OkLowerExpr (LowerExpr state (lower-literal-value lit) (tc-literal-type lit)))]
    [(AstExprVar name) (lower-var state env tc-env name)]
    [(AstExprAnn inner ty)
     (match (lower-expr ctx state env tc-env inner)
       [(OkLowerExpr lowered)
        (match lowered
          [(LowerExpr inner-state value _)
           (OkLowerExpr (LowerExpr inner-state value (tc-resolve-type ctx ty)))])]
       [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprCast inner ty)
     (match (lower-expr ctx state env tc-env inner)
       [(OkLowerExpr lowered)
        (match lowered
          [(LowerExpr inner-state value _)
           (OkLowerExpr (lower-emit-mov inner-state value (tc-resolve-type ctx ty)))])]
       [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprUnary op inner)
     (match (lower-expr ctx state env tc-env inner)
       [(OkLowerExpr lowered)
        (match lowered
          [(LowerExpr inner-state value value-ty)
           (match (tc-unop-type op value-ty)
             [(OkTcType result-ty)
              (match (lower-state-alloc-var inner-state)
                [(LowerAlloc allocated var-id)
                 (OkLowerExpr
                   (LowerExpr
                     (lower-state-emit allocated (IrInstrUnOp var-id (lower-unop op) value result-ty))
                     (IrValueVar var-id)
                     result-ty))])]
             [(ErrTcType message) (ErrLowerExpr message)])])]
       [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprBinary op left right)
     (match (lower-expr ctx state env tc-env left)
       [(OkLowerExpr left-lowered)
        (match left-lowered
          [(LowerExpr left-state left-value left-ty)
           (match (lower-expr ctx left-state env tc-env right)
             [(OkLowerExpr right-lowered)
              (match right-lowered
                [(LowerExpr right-state right-value right-ty)
                 (match (tc-binop-type op left-ty right-ty)
                   [(OkTcType result-ty)
                    (match (lower-state-alloc-var right-state)
                      [(LowerAlloc allocated var-id)
                       (OkLowerExpr
                         (LowerExpr
                           (lower-state-emit
                             allocated
                             (IrInstrBinOp var-id (lower-binop op) left-value right-value result-ty))
                           (IrValueVar var-id)
                           result-ty))])]
                   [(ErrTcType message) (ErrLowerExpr message)])])]
             [(ErrLowerExpr message) (ErrLowerExpr message)])])]
       [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprCall func args) (lower-call ctx state env tc-env func args)]
    [(AstExprLet bindings body)
     (match (lower-let-bindings ctx state env tc-env bindings)
       [(OkLowerEnv lowered-env)
        (match lowered-env
          [(LowerEnv binding-state body-env body-tc-env)
           (lower-expr ctx binding-state body-env body-tc-env body)])]
       [(ErrLowerEnv message) (ErrLowerExpr message)])]
    [(AstExprBegin exprs) (lower-begin ctx state env tc-env exprs)]
    [(AstExprSet name value)
     (match (sym-i64-lookup env name)
       [(SomeI64 _)
        (match (tc-lookup tc-env name)
          [(OkTcType target-ty)
           (match (lower-expr ctx state env tc-env value)
             [(OkLowerExpr lowered)
              (match lowered
                [(LowerExpr value-state value-ir _)
                 (OkLowerExpr
                   (LowerExpr
                     (lower-state-emit value-state (IrInstrStore name value-ir target-ty))
                     IrValueUnit
                     (AstTyUnit)))])]
             [(ErrLowerExpr message) (ErrLowerExpr message)])]
          [(ErrTcType message) (ErrLowerExpr message)])]
       [(NoneI64) (ErrLowerExpr (string-append "lower: assignment to unknown local " name))])]
    [(AstExprIf cond then-branch else-branch)
     (lower-if ctx state env tc-env cond then-branch else-branch)]
    [(AstExprWhile cond body)
     (lower-while ctx state env tc-env cond body)]
    [_ (ErrLowerExpr "lower: unsupported expression")]))

(define (lower-call [ctx : TcContext] [state : LowerState] [env : SymI64Env] [tc-env : TcTypeEnv] [func : AstExpr] [args : AstExprList]) : ResultLowerExpr
  (match func
    [(AstExprVar name)
     (match (lower-args ctx state env tc-env args)
       [(OkLowerArgs args-state arg-values)
        (match (tc-lookup tc-env name)
          [(OkTcType fn-ty)
           (match fn-ty
             [(AstTyFunc _ ret)
              (match (lower-state-alloc-var args-state)
                [(LowerAlloc allocated var-id)
                 (OkLowerExpr
                   (LowerExpr
                     (lower-state-emit allocated (IrInstrCall var-id name arg-values ret))
                     (IrValueVar var-id)
                     ret))])]
             [_ (ErrLowerExpr "lower: call target is not a function")])]
          [(ErrTcType message) (ErrLowerExpr message)])]
       [(ErrLowerArgs message) (ErrLowerExpr message)])]
    [_ (ErrLowerExpr "lower: only direct calls are supported")]))

(define (lower-args [ctx : TcContext] [state : LowerState] [env : SymI64Env] [tc-env : TcTypeEnv] [args : AstExprList]) : ResultLowerArgs
  (match args
    [(AstExprNil) (OkLowerArgs state IrValueNil)]
    [(AstExprCons arg rest)
     (match (lower-expr ctx state env tc-env arg)
       [(OkLowerExpr lowered)
        (match lowered
          [(LowerExpr arg-state value _)
           (match (lower-args ctx arg-state env tc-env rest)
             [(OkLowerArgs rest-state rest-values)
              (OkLowerArgs rest-state (IrValueCons value rest-values))]
             [(ErrLowerArgs message) (ErrLowerArgs message)])])]
       [(ErrLowerExpr message) (ErrLowerArgs message)])]))

(define (lower-let-binding-type [ctx : TcContext] [init-ty : AstType] [maybe-ty : AstMaybeType]) : AstType
  (match maybe-ty
    [(AstSomeType ty) (tc-resolve-type ctx ty)]
    [(AstNoType) init-ty]))

(define (lower-let-bindings [ctx : TcContext] [state : LowerState] [env : SymI64Env] [tc-env : TcTypeEnv] [bindings : AstLetBindingList]) : ResultLowerEnv
  (match bindings
    [(AstLetBindingNil) (OkLowerEnv (LowerEnv state env tc-env))]
    [(AstLetBindingCons binding rest)
     (match binding
       [(AstLetBinding name maybe-ty init)
        (match (lower-expr ctx state env tc-env init)
          [(OkLowerExpr lowered)
           (match lowered
             [(LowerExpr init-state value init-ty)
              (let ([binding-ty : AstType (lower-let-binding-type ctx init-ty maybe-ty)])
                (match (lower-state-alloc-var init-state)
                  [(LowerAlloc allocated var-id)
                   (lower-let-bindings
                     ctx
                     (lower-state-emit allocated (IrInstrMov var-id value binding-ty))
                     (sym-i64-bind env name var-id)
                     (tc-bind tc-env name binding-ty)
                     rest)]))])]
          [(ErrLowerExpr message) (ErrLowerEnv message)])])]))

(define (lower-begin [ctx : TcContext] [state : LowerState] [env : SymI64Env] [tc-env : TcTypeEnv] [exprs : AstExprList]) : ResultLowerExpr
  (match exprs
    [(AstExprNil) (OkLowerExpr (LowerExpr state IrValueUnit (AstTyUnit)))]
    [(AstExprCons expr rest)
     (match rest
       [(AstExprNil) (lower-expr ctx state env tc-env expr)]
       [_ (match (lower-expr ctx state env tc-env expr)
            [(OkLowerExpr lowered)
             (match lowered
               [(LowerExpr next-state _ _) (lower-begin ctx next-state env tc-env rest)])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])])]))

(define (lower-if [ctx : TcContext] [state : LowerState] [env : SymI64Env] [tc-env : TcTypeEnv] [cond : AstExpr] [then-branch : AstExpr] [else-branch : AstExpr]) : ResultLowerExpr
  (match (lower-expr ctx state env tc-env cond)
    [(OkLowerExpr cond-lowered)
     (match cond-lowered
       [(LowerExpr cond-state cond-value _)
        (match (tc-expr ctx tc-env then-branch)
          [(OkTcType result-ty)
           (match (lower-state-alloc-label cond-state)
             [(LowerLabelAlloc label-state label-id)
              (let ([then-label : String (lower-label "if_then_" label-id "")]
                    [else-label : String (lower-label "if_else_" label-id "")]
                    [join-label : String (lower-label "if_join_" label-id "")])
                (if (lower-type-unit? result-ty)
                    (lower-if-unit ctx label-state env tc-env cond-value then-branch else-branch then-label else-label join-label)
                    (match (lower-state-alloc-var label-state)
                      [(LowerAlloc result-state result-var)
                       (lower-if-value
                         ctx
                         result-state
                         env
                         tc-env
                         cond-value
                         then-branch
                         else-branch
                         result-ty
                         result-var
                         then-label
                         else-label
                         join-label)])))])]
          [(ErrTcType message) (ErrLowerExpr message)])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-if-unit [ctx : TcContext] [state : LowerState] [env : SymI64Env] [tc-env : TcTypeEnv] [cond-value : CompilerIrValue] [then-branch : AstExpr] [else-branch : AstExpr] [then-label : String] [else-label : String] [join-label : String]) : ResultLowerExpr
  (let ([branch-state : LowerState
         (lower-state-emit state (IrInstrBranch cond-value then-label else-label))])
    (match (lower-expr ctx (lower-state-start-block branch-state then-label) env tc-env then-branch)
      [(OkLowerExpr then-lowered)
       (match then-lowered
         [(LowerExpr then-state _ _)
          (let ([then-jump-state : LowerState (lower-state-emit then-state (IrInstrJump join-label))])
            (match (lower-expr ctx (lower-state-start-block then-jump-state else-label) env tc-env else-branch)
              [(OkLowerExpr else-lowered)
               (match else-lowered
                 [(LowerExpr else-state _ _)
                  (OkLowerExpr
                    (LowerExpr
                      (lower-state-start-block
                        (lower-state-emit else-state (IrInstrJump join-label))
                        join-label)
                      IrValueUnit
                      (AstTyUnit)))])]
              [(ErrLowerExpr message) (ErrLowerExpr message)]))])]
      [(ErrLowerExpr message) (ErrLowerExpr message)])))

(define (lower-if-value [ctx : TcContext] [state : LowerState] [env : SymI64Env] [tc-env : TcTypeEnv] [cond-value : CompilerIrValue] [then-branch : AstExpr] [else-branch : AstExpr] [result-ty : AstType] [result-var : i64] [then-label : String] [else-label : String] [join-label : String]) : ResultLowerExpr
  (let ([branch-state : LowerState
         (lower-state-emit state (IrInstrBranch cond-value then-label else-label))])
    (match (lower-expr ctx (lower-state-start-block branch-state then-label) env tc-env then-branch)
      [(OkLowerExpr then-lowered)
       (match then-lowered
         [(LowerExpr then-state then-value _)
          (let ([then-jump-state : LowerState
                 (lower-state-emit
                   (lower-state-emit then-state (IrInstrMov result-var then-value result-ty))
                   (IrInstrJump join-label))])
            (match (lower-expr ctx (lower-state-start-block then-jump-state else-label) env tc-env else-branch)
              [(OkLowerExpr else-lowered)
               (match else-lowered
                 [(LowerExpr else-state else-value _)
                  (OkLowerExpr
                    (LowerExpr
                      (lower-state-start-block
                        (lower-state-emit
                          (lower-state-emit else-state (IrInstrMov result-var else-value result-ty))
                          (IrInstrJump join-label))
                        join-label)
                      (IrValueVar result-var)
                      result-ty))])]
              [(ErrLowerExpr message) (ErrLowerExpr message)]))])]
      [(ErrLowerExpr message) (ErrLowerExpr message)])))

(define (lower-while [ctx : TcContext] [state : LowerState] [env : SymI64Env] [tc-env : TcTypeEnv] [cond : AstExpr] [body : AstExpr]) : ResultLowerExpr
  (match (lower-state-alloc-label state)
    [(LowerLabelAlloc label-state label-id)
     (let ([cond-label : String (lower-label "while_cond_" label-id "")]
           [body-label : String (lower-label "while_body_" label-id "")]
           [end-label : String (lower-label "while_end_" label-id "")])
       (let ([entry-state : LowerState (lower-state-emit label-state (IrInstrJump cond-label))])
         (match (lower-expr ctx (lower-state-start-block entry-state cond-label) env tc-env cond)
           [(OkLowerExpr cond-lowered)
            (match cond-lowered
              [(LowerExpr cond-state cond-value _)
               (let ([cond-branch-state : LowerState
                      (lower-state-emit cond-state (IrInstrBranch cond-value body-label end-label))])
                 (match (lower-expr ctx (lower-state-start-block cond-branch-state body-label) env tc-env body)
                   [(OkLowerExpr body-lowered)
                    (match body-lowered
                      [(LowerExpr body-state _ _)
                       (OkLowerExpr
                         (LowerExpr
                           (lower-state-start-block
                             (lower-state-emit body-state (IrInstrJump cond-label))
                             end-label)
                           IrValueUnit
                           (AstTyUnit)))])]
                   [(ErrLowerExpr message) (ErrLowerExpr message)]))])]
           [(ErrLowerExpr message) (ErrLowerExpr message)])))]))

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
          [tc-env : TcTypeEnv (tc-bind-params ctx top-env params)]
          [state : LowerState (LowerState param-count 0 "entry" IrInstrNil IrBlockNil)]
          [ret-ty : AstType (tc-resolve-type ctx ret)])
      (match (lower-expr ctx state env tc-env body)
        [(OkLowerExpr lowered)
         (match lowered
           [(LowerExpr body-state value value-ty)
            (OkLowerFunction
              (IrFunction
                name
                (lower-param-list ctx params 0)
                ret-ty
                (lower-state-finish-blocks
                  (lower-state-emit
                    body-state
                    (IrInstrReturn (lower-return-value value value-ty))))))])]
        [(ErrLowerExpr message) (ErrLowerFunction message)]))))

(define (lower-global-value [expr : AstExpr]) : ResultLowerValue
  (match expr
    [(AstExprSpanned inner _) (lower-global-value inner)]
    [(AstExprAnn inner _) (lower-global-value inner)]
    [(AstExprLiteral lit) (OkLowerValue (lower-literal-value lit))]
    [_ (ErrLowerValue "lower: top-level value must be a scalar constant")]))

(define (lower-program-prepend-global [program : CompilerIrProgram] [global : CompilerIrGlobal]) : CompilerIrProgram
  (match program
    [(IrProgram globals functions externs)
     (IrProgram (IrGlobalCons global globals) functions externs)]))

(define (lower-program-prepend-function [program : CompilerIrProgram] [fn : CompilerIrFunction]) : CompilerIrProgram
  (match program
    [(IrProgram globals functions externs)
     (IrProgram globals (IrFunctionCons fn functions) externs)]))

(define (lower-program-prepend-extern [program : CompilerIrProgram] [extern-ir : CompilerIrExtern]) : CompilerIrProgram
  (match program
    [(IrProgram globals functions externs)
     (IrProgram globals functions (IrExternCons extern-ir externs))]))

(define (lower-decls [ctx : TcContext] [top-env : TcTypeEnv] [decls : AstDeclList]) : ResultCompilerLower
  (match decls
    [(AstDeclNil) (OkCompilerLower (IrProgram IrGlobalNil IrFunctionNil IrExternNil))]
    [(AstDeclCons decl rest)
     (match decl
       [(AstDeclDef name _ expr)
        (match (tc-top-decl-type ctx decl)
          [(OkTcType ty)
           (match (lower-global-value expr)
             [(OkLowerValue value)
              (match (lower-decls ctx top-env rest)
                [(OkCompilerLower program)
                 (OkCompilerLower
                   (lower-program-prepend-global
                     program
                     (IrGlobal name ty value)))]
                [(ErrCompilerLower message) (ErrCompilerLower message)])]
             [(ErrLowerValue message) (ErrCompilerLower message)])]
          [(ErrTcType message) (ErrCompilerLower message)])]
       [(AstDeclExtern name ty)
        (match (lower-decls ctx top-env rest)
          [(OkCompilerLower program)
           (OkCompilerLower
             (lower-program-prepend-extern
               program
               (IrExtern name (tc-resolve-type ctx ty))))]
          [(ErrCompilerLower message) (ErrCompilerLower message)])]
       [(AstDeclDefFn name params ret body)
        (match (lower-function ctx top-env name params ret body)
          [(OkLowerFunction fn)
           (match (lower-decls ctx top-env rest)
             [(OkCompilerLower program)
              (OkCompilerLower (lower-program-prepend-function program fn))]
             [(ErrCompilerLower message) (ErrCompilerLower message)])]
          [(ErrLowerFunction message) (ErrCompilerLower message)])]
       [(AstDeclImport _) (lower-decls ctx top-env rest)]
       [(AstDeclDefEnum _ _) (lower-decls ctx top-env rest)]
       [(AstDeclDefStruct _ _) (lower-decls ctx top-env rest)])]))

(define (lower-compiler-program-checked [program : AstProgram]) : ResultCompilerLower
  (match (build-compiler-symbols program)
    [(OkCompilerSymbols symbols)
     (match (build-compiler-registries program)
       [(OkCompilerRegistries registries)
        (let ([ctx : TcContext (TcContext program symbols registries)])
          (match (tc-build-top-env ctx program)
            [(OkTcEnv top-env) (lower-decls ctx top-env (tc-context-program-decls ctx))]
            [(ErrTcEnv message) (ErrCompilerLower message)]))]
       [(ErrCompilerRegistries message) (ErrCompilerLower message)])]
    [(ErrCompilerSymbols message) (ErrCompilerLower message)]))

(define (lower-compiler-program [program : AstProgram]) : ResultCompilerLower
  (match (typecheck-compiler-program program)
    [(OkCompilerTypecheck _) (lower-compiler-program-checked program)]
    [(ErrCompilerTypecheck message) (ErrCompilerLower message)]))

(define (lower-compiler-source [src : String]) : ResultCompilerLower
  (match (parse-ast-source src)
    [(OkAstProgram program) (lower-compiler-program program)]
    [(ErrAstProgram message) (ErrCompilerLower message)]))

(define (tc-context-program-decls [ctx : TcContext]) : AstDeclList
  (match (tc-context-program ctx)
    [(AstProgram decls) decls]))

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

(define (compiler-lower-ok-summary? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program)
     (let ([summary : CompilerIrSummary (compiler-ir-program-summary program)])
       (and (= (compiler-ir-summary-globals summary) 1)
            (and (= (compiler-ir-summary-functions summary) 2)
                 (and (= (compiler-ir-summary-externs summary) 1)
                      (and (= (compiler-ir-summary-blocks summary) 8)
                           (and (= (compiler-ir-summary-instructions summary) 18)
                                (= (compiler-ir-summary-vars summary) 9)))))))]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-self-test) : i64
  (if (and (compiler-lower-ok-summary? (compiler-lower-smoke-source))
           (and (compiler-lower-error-ok? (compiler-typecheck-branch-mismatch-source)
                                          "typecheck: if branches must match")
                (compiler-lower-error-ok? (compiler-lower-unsupported-source)
                                          "lower: unsupported expression")))
      42
      (begin
        (panic "lower: smoke score mismatch")
        0)))
