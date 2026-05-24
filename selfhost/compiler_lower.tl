;; compiler_lower.tl - First selfhost compiler AST-to-IR lowering slice (#446).

;;

;; The lowerer accepts the checked scalar subset and builds a deterministic

;; CompilerIrProgram. It also covers scalar match and heap-backed struct/enum

;; construction/projection; closure, array, and enum-match lowering remain

;; explicit future work.

(import "compiler_typecheck.tl")

(import "compiler_diagnostic.tl")

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
  (ErrLowerExpr CompilerDiagnostic))

(defenum ResultLowerArgs
  (OkLowerArgs LowerState CompilerIrValueList)
  (ErrLowerArgs CompilerDiagnostic))

(defenum ResultLowerState
  (OkLowerState LowerState)
  (ErrLowerState CompilerDiagnostic))

(defenum ResultLowerEnv
  (OkLowerEnv LowerState SymI64Env TcTypeEnv)
  (ErrLowerEnv CompilerDiagnostic))

(defenum ResultLowerValue
  (OkLowerValue CompilerIrValue)
  (ErrLowerValue CompilerDiagnostic))

(defenum ResultLowerFunction
  (OkLowerFunction CompilerIrFunction)
  (ErrLowerFunction CompilerDiagnostic))

(defenum ResultLowerDecls
  (OkLowerDecls
    CompilerIrGlobalList
    CompilerIrFunctionList
    CompilerIrExternList)
  (ErrLowerDecls CompilerDiagnostic))

(defenum ResultCompilerLower
  (OkCompilerLower CompilerIrProgram)
  (ErrCompilerLower CompilerDiagnostic))

(defenum LowerFieldInfo
  (LowerFieldInfo i64 AstType))

(defenum ResultLowerFieldInfo
  (OkLowerFieldInfo LowerFieldInfo)
  (ErrLowerFieldInfo CompilerDiagnostic))

(defenum LowerStringFields
  (LowerStringFields LowerState CompilerIrValue CompilerIrValue))

(define (lower-diagnostic [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start "" message))

(define (lower-diagnostic-at-expr [expr : AstExpr] [message : String]) : CompilerDiagnostic
  (match expr
    [(AstExprSpanned _ span)
      (compiler-diagnostic-from-ast-span "" span message)]
    [_ (lower-diagnostic message)]))

(define (lower-diagnostic-with-path [diag : CompilerDiagnostic] [path : String]) : CompilerDiagnostic
  (compiler-diagnostic-with-path diag path))

(define (lower-instr-list-append
  [instrs : CompilerIrInstrList]
  [instr : CompilerIrInstr]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (IrInstrCons instr IrInstrNil)]
    [(IrInstrCons head rest)
      (IrInstrCons head (lower-instr-list-append rest instr))]))

(define (lower-block-list-append
  [blocks : CompilerIrBlockList]
  [block : CompilerIrBlock]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) (IrBlockCons block IrBlockNil)]
    [(IrBlockCons head rest)
      (IrBlockCons head (lower-block-list-append rest block))]))

(define (lower-global-list-append
  [globals : CompilerIrGlobalList]
  [global : CompilerIrGlobal]) : CompilerIrGlobalList
  (match globals
    [(IrGlobalNil) (IrGlobalCons global IrGlobalNil)]
    [(IrGlobalCons head rest)
      (IrGlobalCons head (lower-global-list-append rest global))]))

(define (lower-function-list-append
  [functions : CompilerIrFunctionList]
  [func : CompilerIrFunction]) : CompilerIrFunctionList
  (match functions
    [(IrFunctionNil) (IrFunctionCons func IrFunctionNil)]
    [(IrFunctionCons head rest)
      (IrFunctionCons head (lower-function-list-append rest func))]))

(define (lower-extern-list-append
  [externs : CompilerIrExternList]
  [item : CompilerIrExtern]) : CompilerIrExternList
  (match externs
    [(IrExternNil) (IrExternCons item IrExternNil)]
    [(IrExternCons head rest)
      (IrExternCons head (lower-extern-list-append rest item))]))

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
        (LowerState
          (+ next-var 1)
          next-label
          current-label
          current-instrs
          blocks)
        next-var)]))

(define (lower-state-fresh-label [state : LowerState] [prefix : String]) : LowerLabel
  (match state
    [(LowerState next-var next-label current-label current-instrs blocks)
      (LowerLabel
        (LowerState
          next-var
          (+ next-label 1)
          current-label
          current-instrs
          blocks)
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

(define (lower-materialize
  [state : LowerState]
  [value : CompilerIrValue]
  [ty : AstType]) : ResultLowerExpr
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

(define (lower-align-up [n : i64] [align : i64]) : i64
  (if (<= align 1)
    n
    (* (/ (+ n (- align 1)) align) align)))

(define (lower-type-size [ctx : TcContext] [ty : AstType]) : i64
  (match (tc-resolve-type ctx ty)
    [(AstTyI64) 8]
    [(AstTyU64) 8]
    [(AstTyF64) 8]
    [(AstTyI32) 4]
    [(AstTyU32) 4]
    [(AstTyF32) 4]
    [(AstTyI16) 2]
    [(AstTyU16) 2]
    [(AstTyI8) 1]
    [(AstTyU8) 1]
    [(AstTyBool) 1]
    [(AstTyChar) 1]
    [(AstTyUnit) 0]
    [(AstTyNever) 0]
    [(AstTyFunc _ _) 8]
    [(AstTyTuple _) 8]
    [(AstTyArray elem count) (* (lower-type-size ctx elem) count)]
    [(AstTyDynArray _) 8]
    [(AstTyEnum _) 8]
    [(AstTyStruct _) 8]
    [(AstTyString) 8]
    [(AstTyVar _) 8]))

(define (lower-type-align [ctx : TcContext] [ty : AstType]) : i64
  (match (tc-resolve-type ctx ty)
    [(AstTyI64) 8]
    [(AstTyU64) 8]
    [(AstTyF64) 8]
    [(AstTyI32) 4]
    [(AstTyU32) 4]
    [(AstTyF32) 4]
    [(AstTyI16) 2]
    [(AstTyU16) 2]
    [(AstTyI8) 1]
    [(AstTyU8) 1]
    [(AstTyBool) 1]
    [(AstTyChar) 1]
    [(AstTyUnit) 1]
    [(AstTyNever) 1]
    [(AstTyFunc _ _) 8]
    [(AstTyTuple _) 8]
    [(AstTyArray elem _) (lower-type-align ctx elem)]
    [(AstTyDynArray _) 8]
    [(AstTyEnum _) 8]
    [(AstTyStruct _) 8]
    [(AstTyString) 8]
    [(AstTyVar _) 8]))

(define (lower-type-list-extent
  [ctx : TcContext]
  [types : AstTypeList]
  [cursor : i64]) : i64
  (match types
    [(AstTypeNil) cursor]
    [(AstTypeCons ty rest)
      (let ([resolved : AstType (tc-resolve-type ctx ty)])
        (let ([offset
            :
            i64
            (lower-align-up cursor (lower-type-align ctx resolved))])
          (lower-type-list-extent
            ctx
            rest
            (+ offset (lower-type-size ctx resolved)))))]))

(define (lower-type-list-storage-size [ctx : TcContext] [types : AstTypeList]) : i64
  (let ([extent : i64 (lower-type-list-extent ctx types 0)])
    (lower-align-up
      (if (= extent 0)
        1
        extent)
      8)))

(define (lower-variant-storage-size [ctx : TcContext] [variant : AstVariantDef]) : i64
  (match variant
    [(AstVariantDef _ fields)
      (lower-align-up (lower-type-list-extent ctx fields 8) 8)]))

(define (lower-enum-variants-storage-size
  [ctx : TcContext]
  [variants : AstVariantDefList]
  [max-size : i64]) : i64
  (match variants
    [(AstVariantDefNil) max-size]
    [(AstVariantDefCons variant rest)
      (let ([size : i64 (lower-variant-storage-size ctx variant)])
        (lower-enum-variants-storage-size
          ctx
          rest
          (if (> size max-size)
            size
            max-size)))]))

(define (lower-enum-storage-size [ctx : TcContext] [enum-name : String]) : i64
  (match ctx
    [(TcContext program _ _)
      (match (tc-program-enum-variants program enum-name)
        [(OkAstVariantDefList variants)
          (lower-enum-variants-storage-size ctx variants 8)]
        [(ErrAstVariantDefList _) 8])]))

(define (lower-struct-fields [ctx : TcContext] [struct-name : String]) : ResultAstFieldDefList
  (match ctx
    [(TcContext program symbols _)
      (match (compiler-symbols-lookup-type symbols struct-name)
        [(SomeI64 handle)
          (if (=
            (compiler-symbol-handle-kind handle)
            (compiler-symbol-kind-defstruct))
            (match (compiler-program-decl-at-index
              program
              (compiler-symbol-handle-index handle))
              [(OkAstDecl decl)
                (match decl
                  [(AstDeclDefStruct _ fields) (OkAstFieldDefList fields)]
                  [_
                    (ErrAstFieldDefList
                      "lower: struct symbol owner is not a struct")])]
              [(ErrAstDecl message) (ErrAstFieldDefList message)])
            (ErrAstFieldDefList
              (string-append "lower: unknown struct " struct-name)))]
        [(NoneI64)
          (ErrAstFieldDefList
            (string-append "lower: unknown struct " struct-name))])]))

(define (lower-reserve-heap-storage
  [state : LowerState]
  [size : i64]
  [ty : AstType]) : LowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc allocated var-id)
      (LowerExpr
        (lower-state-emit
          allocated
          (IrInstrCall
            var-id
            "tl_alloc"
            (IrValueCons (IrValueI64 size) IrValueNil)
            ty))
        (IrValueVar var-id)
        ty)]))

(define (lower-gep-byte
  [state : LowerState]
  [base : CompilerIrValue]
  [offset : i64]) : LowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc allocated var-id)
      (LowerExpr
        (lower-state-emit
          allocated
          (IrInstrGep var-id base (IrValueI64 offset) (AstTyU8)))
        (IrValueVar var-id)
        (AstTyU64))]))

(define (lower-store-at-offset
  [state : LowerState]
  [base : CompilerIrValue]
  [offset : i64]
  [value : CompilerIrValue]
  [ty : AstType]) : LowerState
  (match (lower-gep-byte state base offset)
    [(LowerExpr ptr-state ptr _)
      (lower-state-emit ptr-state (IrInstrStorePtr ptr value ty))]))

(define (lower-load-at-offset
  [state : LowerState]
  [base : CompilerIrValue]
  [offset : i64]
  [ty : AstType]) : LowerExpr
  (match (lower-gep-byte state base offset)
    [(LowerExpr ptr-state ptr _)
      (match (lower-state-alloc-var ptr-state)
        [(LowerAlloc allocated var-id)
          (LowerExpr
            (lower-state-emit allocated (IrInstrLoad var-id ptr ty))
            (IrValueVar var-id)
            ty)])]))

(define (lower-cast-value
  [state : LowerState]
  [value : CompilerIrValue]
  [from-ty : AstType]
  [to-ty : AstType]) : LowerExpr
  (if (tc-type-eq from-ty to-ty)
    (LowerExpr state value to-ty)
    (match (lower-state-alloc-var state)
      [(LowerAlloc allocated var-id)
        (LowerExpr
          (lower-state-emit allocated (IrInstrCast var-id value from-ty to-ty))
          (IrValueVar var-id)
          to-ty)])))

(define (lower-oob-abort [state : LowerState]) : LowerState
  (match (lower-state-alloc-var state)
    [(LowerAlloc allocated var-id)
      (lower-state-emit
        allocated
        (IrInstrCall var-id "tl_oob_abort" IrValueNil (AstTyUnit)))]))

(define (lower-string-fields [state : LowerState] [value : CompilerIrValue]) : LowerStringFields
  (match (lower-load-at-offset state value 0 (AstTyU64))
    [(LowerExpr ptr-state ptr _)
      (match (lower-load-at-offset ptr-state value 8 (AstTyI64))
        [(LowerExpr len-state len _) (LowerStringFields len-state ptr len)])]))

(define (lower-store-values
  [ctx : TcContext]
  [state : LowerState]
  [base : CompilerIrValue]
  [values : CompilerIrValueList]
  [types : AstTypeList]
  [cursor : i64]) : ResultLowerState
  (match values
    [(IrValueNil)
      (match types
        [(AstTypeNil) (OkLowerState state)]
        [_
          (ErrLowerState (lower-diagnostic "lower: constructor arity mismatch"))])]
    [(IrValueCons value rest-values)
      (match types
        [(AstTypeCons ty rest-types)
          (let ([resolved : AstType (tc-resolve-type ctx ty)])
            (let ([offset
                :
                i64
                (lower-align-up cursor (lower-type-align ctx resolved))])
              (lower-store-values
                ctx
                (lower-store-at-offset state base offset value resolved)
                base
                rest-values
                rest-types
                (+ offset (lower-type-size ctx resolved)))))]
        [(AstTypeNil)
          (ErrLowerState (lower-diagnostic "lower: constructor arity mismatch"))])]))

(define (lower-literal-payload-supported? [lit : AstLiteral]) : bool
  (match lit
    [(AstLitInt _) true]
    [(AstLitBool _) true]
    [(AstLitChar _) true]
    [_ false]))

;; Bind a matched variant's payload fields. Irrefutable subpatterns (wildcard,

;; binding) just load/bind; a refutable literal subpattern (#651) loads the

;; field, compares it to the literal, and on mismatch branches to `fail-label`

;; (the enclosing arm's next-arm test) so matching continues. Nested variant

;; subpatterns recurse on the field's tag. `fail-label` is unused when every subpattern

;; is irrefutable.

(define (lower-bind-variant-payloads
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [base : CompilerIrValue]
  [patterns : AstPatternList]
  [types : AstTypeList]
  [cursor : i64]
  [fail-label : String]) : ResultLowerEnv
  (match patterns
    [(AstPatternNil)
      (match types
        [(AstTypeNil) (OkLowerEnv state env type-env)]
        [_
          (ErrLowerEnv
            (lower-diagnostic "lower: enum payload pattern arity mismatch"))])]
    [(AstPatternCons pattern rest-patterns)
      (match types
        [(AstTypeCons ty rest-types)
          (let ([resolved : AstType (tc-resolve-type ctx ty)])
            (let ([offset
                :
                i64
                (lower-align-up cursor (lower-type-align ctx resolved))]
              [next-cursor : i64 (+ offset (lower-type-size ctx resolved))])
              (match pattern
                [(AstPatWildcard)
                  (lower-bind-variant-payloads
                    ctx
                    state
                    env
                    type-env
                    base
                    rest-patterns
                    rest-types
                    next-cursor
                    fail-label)]
                [(AstPatBinding name)
                  (match (lower-load-at-offset state base offset resolved)
                    [(LowerExpr load-state value _)
                      (match value
                        [(IrValueVar field-var)
                          (lower-bind-variant-payloads
                            ctx
                            load-state
                            (sym-i64-bind env name field-var)
                            (tc-bind type-env name resolved)
                            base
                            rest-patterns
                            rest-types
                            next-cursor
                            fail-label)]
                        [_
                          (ErrLowerEnv
                            (lower-diagnostic
                              "lower: internal enum payload load failed"))])])]
                [(AstPatLiteral lit)
                  (if (lower-literal-payload-supported? lit)
                    (match (lower-load-at-offset state base offset resolved)
                      [(LowerExpr load-state field-value _)
                        (match (lower-state-alloc-var load-state)
                          [(LowerAlloc eq-alloc eq-var)
                            (match (lower-state-fresh-label
                              (lower-state-emit
                                eq-alloc
                                (IrInstrBinOp
                                  eq-var
                                  IrBinEq
                                  field-value
                                  (lower-literal-value lit)
                                  resolved))
                              "payload_ok")
                              [(LowerLabel ok-state ok-label)
                                (lower-bind-variant-payloads
                                  ctx
                                  (lower-state-finish-block
                                    (lower-state-emit
                                      ok-state
                                      (IrInstrBranch
                                        (IrValueVar eq-var)
                                        ok-label
                                        fail-label))
                                    ok-label)
                                  env
                                  type-env
                                  base
                                  rest-patterns
                                  rest-types
                                  next-cursor
                                  fail-label)])])])
                    (ErrLowerEnv
                      (lower-diagnostic
                        "lower: unsupported enum payload literal pattern type")))]
                [(AstPatVariant nested-name nested-args)
                  ;; Refutable nested variant payload (#651): load the payload
                  ;; field (an enum pointer), test its tag against the nested
                  ;; variant, and on mismatch branch to the enclosing arm's
                  ;; next-arm test (`fail-label`); on match recurse into the
                  ;; nested variant's own payload fields (tag at offset 0,
                  ;; payloads from offset 8), then continue the outer payloads.
                  (match ctx
                    [(TcContext program _ registries)
                      (match (compiler-registries-lookup-variant
                        registries
                        nested-name)
                        [(NoneI64)
                          (ErrLowerEnv
                            (lower-diagnostic
                              (string-append
                                "lower: unknown nested variant "
                                nested-name)))]
                        [(SomeI64 handle)
                          (match (compiler-registries-variant-fields
                            program
                            handle)
                            [(ErrAstTypeList message)
                              (ErrLowerEnv (lower-diagnostic message))]
                            [(OkAstTypeList nested-fields)
                              (match (lower-load-at-offset
                                state
                                base
                                offset
                                resolved)
                                [(LowerExpr field-state field-value _)
                                  (match (lower-load-at-offset
                                    field-state
                                    field-value
                                    0
                                    (AstTyI64))
                                    [(LowerExpr tag-state tag-value _)
                                      (match (lower-state-alloc-var tag-state)
                                        [(LowerAlloc eq-alloc eq-var)
                                          (match (lower-state-fresh-label
                                            (lower-state-emit
                                              eq-alloc
                                              (IrInstrBinOp
                                                eq-var
                                                IrBinEq
                                                tag-value
                                                (IrValueI64
                                                  (compiler-registry-handle-child-index
                                                    handle))
                                                (AstTyI64)))
                                            "payload_ok")
                                            [(LowerLabel ok-state ok-label)
                                              (match (lower-bind-variant-payloads
                                                ctx
                                                (lower-state-finish-block
                                                  (lower-state-emit
                                                    ok-state
                                                    (IrInstrBranch
                                                      (IrValueVar eq-var)
                                                      ok-label
                                                      fail-label))
                                                  ok-label)
                                                env
                                                type-env
                                                field-value
                                                nested-args
                                                nested-fields
                                                8
                                                fail-label)
                                                [(OkLowerEnv
                                                    nested-state
                                                    nested-env
                                                    nested-type-env)
                                                  (lower-bind-variant-payloads
                                                    ctx
                                                    nested-state
                                                    nested-env
                                                    nested-type-env
                                                    base
                                                    rest-patterns
                                                    rest-types
                                                    next-cursor
                                                    fail-label)]
                                                [(ErrLowerEnv message)
                                                  (ErrLowerEnv message)])])])])])])])])]
                [_
                  (ErrLowerEnv
                    (lower-diagnostic "lower: unsupported enum payload pattern"))])))]
        [(AstTypeNil)
          (ErrLowerEnv
            (lower-diagnostic "lower: enum payload pattern arity mismatch"))])]))

;; A payload subpattern is refutable when it can fail to match at run time. Only

;; literal and nested-variant subpatterns are refutable here; binding,

;; var, wildcard, and tuple subpatterns always match structurally.

(define (lower-pattern-refutable? [pattern : AstPattern]) : bool
  (match pattern
    [(AstPatLiteral _) true]
    [(AstPatVariant _ _) true]
    [_ false]))

(define (lower-pattern-list-refutable? [patterns : AstPatternList]) : bool
  (match patterns
    [(AstPatternNil) false]
    [(AstPatternCons pattern rest)
      (if (lower-pattern-refutable? pattern)
        true
        (lower-pattern-list-refutable? rest))]))

(define (lower-field-info-from-list
  [ctx : TcContext]
  [fields : AstFieldDefList]
  [field-name : String]
  [cursor : i64]) : ResultLowerFieldInfo
  (match fields
    [(AstFieldDefNil)
      (ErrLowerFieldInfo
        (lower-diagnostic
          (string-append "lower: unknown struct field " field-name)))]
    [(AstFieldDefCons field rest)
      (match field
        [(AstFieldDef name ty)
          (let ([resolved : AstType (tc-resolve-type ctx ty)])
            (let ([offset
                :
                i64
                (lower-align-up cursor (lower-type-align ctx resolved))])
              (if (string-eq name field-name)
                (OkLowerFieldInfo (LowerFieldInfo offset resolved))
                (lower-field-info-from-list
                  ctx
                  rest
                  field-name
                  (+ offset (lower-type-size ctx resolved))))))])]))

(define (lower-struct-field-info
  [ctx : TcContext]
  [struct-name : String]
  [field-name : String]) : ResultLowerFieldInfo
  (match (lower-struct-fields ctx struct-name)
    [(OkAstFieldDefList fields)
      (lower-field-info-from-list ctx fields field-name 0)]
    [(ErrAstFieldDefList message)
      (ErrLowerFieldInfo (lower-diagnostic message))]))

(define (lower-var
  [state : LowerState]
  [env : SymI64Env]
  [name : String]
  [ty : AstType]) : ResultLowerExpr
  (match (sym-i64-lookup env name)
    [(SomeI64 id) (lower-materialize state (IrValueVar id) ty)]
    [(NoneI64) (lower-materialize state (IrValueGlobal name) ty)]))

(define (lower-return-maybe [value : CompilerIrValue] [ty : AstType]) : CompilerIrMaybeValue
  (match ty
    [(AstTyUnit) IrNoValue]
    [_ (IrSomeValue value)]))

(define (lower-top-level-value-defined? [ctx : TcContext] [name : String]) : bool
  (match ctx
    [(TcContext _ symbols _)
      (match (compiler-symbols-lookup-value symbols name)
        [(SomeI64 _) true]
        [(NoneI64) false])]))

(define (lower-builtin-call-available?
  [ctx : TcContext]
  [env : SymI64Env]
  [name : String]) : bool
  (and
    (not (sym-i64-contains env name))
    (not (lower-top-level-value-defined? ctx name))))

(define (lower-stdio-builtin? [name : String]) : bool
  (if (string-eq name "read-stdin-line")
    true
    (if (string-eq name "read-stdin-bytes")
      true
      (if (string-eq name "stdin-eof?")
        true
        (string-eq name "flush-stdout")))))

(define (lower-string-runtime-builtin? [name : String]) : bool
  (if (string-eq name "substring")
    true
    (if (string-eq name "string-slice")
      true
      (if (string-eq name "string-append")
        true
        (string-eq name "string-concat")))))

(define (lower-stdio-runtime-name [name : String]) : String
  (if (string-eq name "read-stdin-line")
    ".L_tl_read_stdin_line"
    (if (string-eq name "read-stdin-bytes")
      ".L_tl_read_stdin_bytes"
      (if (string-eq name "stdin-eof?")
        ".L_tl_stdin_eof"
        ".L_tl_flush_stdout"))))

(define (lower-args-as
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [types : AstTypeList]) : ResultLowerArgs
  (match args
    [(AstExprNil)
      (match types
        [(AstTypeNil) (OkLowerArgs state IrValueNil)]
        [_
          (ErrLowerArgs (lower-diagnostic "lower: constructor arity mismatch"))])]
    [(AstExprCons arg rest-args)
      (match types
        [(AstTypeCons _ rest-types)
          (match (lower-expr ctx state env type-env arg)
            [(OkLowerExpr lowered)
              (match lowered
                [(LowerExpr arg-state value _)
                  (match (lower-args-as
                    ctx
                    arg-state
                    env
                    type-env
                    rest-args
                    rest-types)
                    [(OkLowerArgs rest-state rest-values)
                      (OkLowerArgs rest-state (IrValueCons value rest-values))]
                    [(ErrLowerArgs message) (ErrLowerArgs message)])])]
            [(ErrLowerExpr message) (ErrLowerArgs message)])]
        [(AstTypeNil)
          (ErrLowerArgs (lower-diagnostic "lower: constructor arity mismatch"))])]))

(define (lower-construct-enum-with-handle
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [variant-name : String]
  [handle : i64]
  [args : AstExprList]
  [result-ty : AstType]) : ResultLowerExpr
  (match (tc-resolve-type ctx result-ty)
    [(AstTyEnum enum-name)
      (match ctx
        [(TcContext program _ _)
          (match (compiler-registries-variant-fields program handle)
            [(OkAstTypeList fields)
              (match (lower-args-as
                ctx
                state
                env
                type-env
                args
                (tc-resolve-type-list ctx fields))
                [(OkLowerArgs args-state values)
                  (let ([size : i64 (lower-enum-storage-size ctx enum-name)])
                    (match (lower-reserve-heap-storage
                      args-state
                      size
                      (AstTyEnum enum-name))
                      [(LowerExpr base-state base _)
                        (let ([tag-state
                            :
                            LowerState
                            (lower-store-at-offset
                              base-state
                              base
                              0
                              (IrValueI64
                                (compiler-registry-handle-child-index handle))
                              (AstTyI64))])
                          (match (lower-store-values
                            ctx
                            tag-state
                            base
                            values
                            fields
                            8)
                            [(OkLowerState done-state)
                              (OkLowerExpr
                                (LowerExpr
                                  done-state
                                  base
                                  (AstTyEnum enum-name)))]
                            [(ErrLowerState message) (ErrLowerExpr message)]))]))]
                [(ErrLowerArgs message) (ErrLowerExpr message)])]
            [(ErrAstTypeList message) (ErrLowerExpr (lower-diagnostic message))])])]
    [_
      (ErrLowerExpr
        (lower-diagnostic
          (string-append
            "lower: enum constructor result is not enum: "
            variant-name)))]))

(define (lower-construct-struct
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [struct-name : String]
  [args : AstExprList]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-struct-fields ctx struct-name)
    [(OkAstFieldDefList fields)
      (let ([field-types : AstTypeList (tc-field-type-list ctx fields)])
        (match (lower-args-as ctx state env type-env args field-types)
          [(OkLowerArgs args-state values)
            (let ([struct-ty : AstType (tc-resolve-type ctx result-ty)])
              (let ([size : i64 (lower-type-list-storage-size ctx field-types)])
                (match (lower-reserve-heap-storage args-state size struct-ty)
                  [(LowerExpr base-state base _)
                    (match (lower-store-values
                      ctx
                      base-state
                      base
                      values
                      field-types
                      0)
                      [(OkLowerState done-state)
                        (OkLowerExpr (LowerExpr done-state base struct-ty))]
                      [(ErrLowerState message) (ErrLowerExpr message)])])))]
          [(ErrLowerArgs message) (ErrLowerExpr message)]))]
    [(ErrAstFieldDefList message) (ErrLowerExpr (lower-diagnostic message))]))

(define (lower-var-or-nullary-variant
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [expr-ty : AstType]) : ResultLowerExpr
  (match (sym-i64-lookup env name)
    [(SomeI64 _) (lower-var state env name expr-ty)]
    [(NoneI64)
      (match ctx
        [(TcContext program _ registries)
          (match (compiler-registries-lookup-variant registries name)
            [(SomeI64 handle)
              (match (compiler-registries-variant-fields program handle)
                [(OkAstTypeList fields)
                  (match fields
                    [(AstTypeNil)
                      (lower-construct-enum-with-handle
                        ctx
                        state
                        env
                        type-env
                        name
                        handle
                        AstExprNil
                        expr-ty)]
                    [_ (lower-var state env name expr-ty)])]
                [(ErrAstTypeList _) (lower-var state env name expr-ty)])]
            [(NoneI64) (lower-var state env name expr-ty)])])]))

(define (lower-expr
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [expr : AstExpr]) : ResultLowerExpr
  (match (tc-expr ctx type-env expr)
    [(OkTcType expr-ty)
      (lower-expr-with-type ctx state env type-env expr expr expr-ty)]
    [(ErrTcType message) (ErrLowerExpr (lower-diagnostic-at-expr expr message))]))

(define (lower-expr-with-type
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [expr : AstExpr]
  [origin : AstExpr]
  [expr-ty : AstType]) : ResultLowerExpr
  (match expr
    [(AstExprSpanned inner _)
      (lower-expr-with-type ctx state env type-env inner origin expr-ty)]
    [(AstExprLiteral lit)
      (lower-materialize state (lower-literal-value lit) expr-ty)]
    [(AstExprVar name)
      (lower-var-or-nullary-variant ctx state env type-env name expr-ty)]
    [(AstExprAnn inner _)
      (match (lower-expr ctx state env type-env inner)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr inner-state value _)
              (OkLowerExpr (LowerExpr inner-state value expr-ty))])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprCast inner _)
      (match (lower-expr ctx state env type-env inner)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr inner-state value _)
              (lower-materialize inner-state value expr-ty)])]
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
                      (lower-state-emit
                        allocated
                        (IrInstrUnOp var-id (lower-unop op) value expr-ty))
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
                                (IrInstrBinOp
                                  var-id
                                  (lower-binop op)
                                  left-value
                                  right-value
                                  expr-ty))
                              (IrValueVar var-id)
                              expr-ty))])])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprCall func args)
      (lower-call ctx state env type-env func args expr-ty)]
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
                      (lower-state-emit
                        value-state
                        (IrInstrMov id value-ir value-ty))
                      IrValueUnit
                      expr-ty))]
                [(NoneI64)
                  (match (tc-lookup type-env name)
                    [(OkTcType store-ty)
                      (OkLowerExpr
                        (LowerExpr
                          (lower-state-emit
                            value-state
                            (IrInstrStore name value-ir store-ty))
                          IrValueUnit
                          expr-ty))]
                    [(ErrTcType _)
                      (ErrLowerExpr
                        (lower-diagnostic-at-expr
                          origin
                          (string-append
                            "lower: assignment to unknown local "
                            name)))])])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprIf cond then-branch else-branch)
      (lower-if ctx state env type-env cond then-branch else-branch expr-ty)]
    [(AstExprWhile cond body) (lower-while ctx state env type-env cond body)]
    [(AstExprMatch scrutinee arms)
      (lower-match ctx state env type-env scrutinee arms expr-ty)]
    [(AstExprStringRef str index)
      (lower-string-ref ctx state env type-env str index)]
    [(AstExprStructGet receiver field)
      (lower-struct-get ctx state env type-env receiver field expr-ty)]
    [(AstExprMakeArray elem-ty len)
      (lower-make-array ctx state env type-env elem-ty len)]
    [(AstExprArrayRef arr index)
      (lower-array-ref ctx state env type-env arr index)]
    [(AstExprArraySet arr index value)
      (lower-array-set ctx state env type-env arr index value)]
    ;; `(comptime expr)` is parsed and type-checked (#718) but not yet evaluated;
    ;; CTFE + folding to a literal lands in #719.
    [(AstExprComptime _)
      (ErrLowerExpr
        (lower-diagnostic-at-expr
          origin
          "lower: comptime evaluation not yet implemented (#719)"))]
    [_
      (ErrLowerExpr
        (lower-diagnostic-at-expr origin "lower: unsupported expression"))]))

(define (lower-struct-get
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [receiver : AstExpr]
  [field : String]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env receiver)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr receiver-state receiver-value receiver-ty)
          (match (tc-resolve-type ctx receiver-ty)
            [(AstTyStruct struct-name)
              (match (lower-struct-field-info ctx struct-name field)
                [(OkLowerFieldInfo info)
                  (match info
                    [(LowerFieldInfo offset field-ty)
                      (match (lower-gep-byte
                        receiver-state
                        receiver-value
                        offset)
                        [(LowerExpr ptr-state ptr _)
                          (match (lower-state-alloc-var ptr-state)
                            [(LowerAlloc allocated var-id)
                              (OkLowerExpr
                                (LowerExpr
                                  (lower-state-emit
                                    allocated
                                    (IrInstrLoad var-id ptr field-ty))
                                  (IrValueVar var-id)
                                  result-ty))])])])]
                [(ErrLowerFieldInfo message) (ErrLowerExpr message)])]
            [_
              (ErrLowerExpr
                (lower-diagnostic-at-expr
                  receiver
                  "lower: struct-get requires struct"))])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-string-ref-byte
  [state : LowerState]
  [data-ptr : CompilerIrValue]
  [index-value : CompilerIrValue]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc gep-alloc gep-var)
      (let ([gep-state
          :
          LowerState
          (lower-state-emit
            gep-alloc
            (IrInstrGep gep-var data-ptr index-value (AstTyChar)))])
        (match (lower-state-alloc-var gep-state)
          [(LowerAlloc load-alloc load-var)
            (OkLowerExpr
              (LowerExpr
                (lower-state-emit
                  load-alloc
                  (IrInstrLoad load-var (IrValueVar gep-var) (AstTyChar)))
                (IrValueVar load-var)
                (AstTyChar)))]))]))

(define (lower-string-ref-load
  [state : LowerState]
  [str-value : CompilerIrValue]
  [index-value : CompilerIrValue]) : ResultLowerExpr
  (match (lower-string-fields state str-value)
    [(LowerStringFields fields-state data-ptr str-len)
      (match (lower-cast-value fields-state index-value (AstTyI64) (AstTyU64))
        [(LowerExpr index-u-state index-u _)
          (match (lower-cast-value index-u-state str-len (AstTyI64) (AstTyU64))
            [(LowerExpr len-u-state len-u _)
              (match (lower-state-alloc-var len-u-state)
                [(LowerAlloc bounds-alloc bounds-var)
                  (let ([bounds-state
                      :
                      LowerState
                      (lower-state-emit
                        bounds-alloc
                        (IrInstrBinOp
                          bounds-var
                          IrBinLt
                          index-u
                          len-u
                          (AstTyU64)))])
                    (match (lower-state-fresh-label
                      bounds-state
                      "str_bounds_ok")
                      [(LowerLabel ok-label-state ok-label)
                        (match (lower-state-fresh-label
                          ok-label-state
                          "str_bounds_fail")
                          [(LowerLabel fail-label-state fail-label)
                            (let ([fail-start
                                :
                                LowerState
                                (lower-state-finish-block
                                  (lower-state-emit
                                    fail-label-state
                                    (IrInstrBranch
                                      (IrValueVar bounds-var)
                                      ok-label
                                      fail-label))
                                  fail-label)])
                              (let ([ok-start
                                  :
                                  LowerState
                                  (lower-state-finish-block
                                    (lower-state-emit
                                      (lower-oob-abort fail-start)
                                      (IrInstrJump ok-label))
                                    ok-label)])
                                (lower-string-ref-byte
                                  ok-start
                                  data-ptr
                                  index-value)))])]))])])])]))

(define (lower-string-ref
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [str : AstExpr]
  [index : AstExpr]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env str)
    [(OkLowerExpr lowered-str)
      (match lowered-str
        [(LowerExpr str-state str-value str-ty)
          (match (tc-resolve-type ctx str-ty)
            [(AstTyString)
              (match (lower-expr ctx str-state env type-env index)
                [(OkLowerExpr lowered-index)
                  (match lowered-index
                    [(LowerExpr index-state index-raw index-ty)
                      (match (lower-cast-value
                        index-state
                        index-raw
                        index-ty
                        (AstTyI64))
                        [(LowerExpr index-i-state index-value _)
                          (lower-string-ref-load
                            index-i-state
                            str-value
                            index-value)])])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])]
            [_
              (ErrLowerExpr
                (lower-diagnostic-at-expr
                  str
                  "lower: string-ref requires String"))])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-substring-call-runtime
  [state : LowerState]
  [src-ptr : CompilerIrValue]
  [start-value : CompilerIrValue]
  [len-value : CompilerIrValue]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc allocated var-id)
      (OkLowerExpr
        (LowerExpr
          (lower-state-emit
            allocated
            (IrInstrCall
              var-id
              "tl_substring"
              (IrValueCons
                src-ptr
                (IrValueCons start-value (IrValueCons len-value IrValueNil)))
              (AstTyString)))
          (IrValueVar var-id)
          (AstTyString)))]))

(define (lower-substring-finish-after-len-check
  [state : LowerState]
  [src-ptr : CompilerIrValue]
  [start-value : CompilerIrValue]
  [len-value : CompilerIrValue]
  [len-ok-var : i64]
  [fail-label : String]
  [copy-label : String]) : ResultLowerExpr
  (let ([fail-start
      :
      LowerState
      (lower-state-finish-block
        (lower-state-emit
          state
          (IrInstrBranch (IrValueVar len-ok-var) copy-label fail-label))
        fail-label)])
    (let ([copy-start
        :
        LowerState
        (lower-state-finish-block
          (lower-state-emit
            (lower-oob-abort fail-start)
            (IrInstrJump copy-label))
          copy-label)])
      (lower-substring-call-runtime copy-start src-ptr start-value len-value))))

(define (lower-substring-check-len
  [state : LowerState]
  [src-ptr : CompilerIrValue]
  [src-len : CompilerIrValue]
  [start-value : CompilerIrValue]
  [len-value : CompilerIrValue]
  [fail-label : String]
  [copy-label : String]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc rem-alloc rem-var)
      (let ([rem-state
          :
          LowerState
          (lower-state-emit
            rem-alloc
            (IrInstrBinOp rem-var IrBinSub src-len start-value (AstTyI64)))])
        (match (lower-cast-value
          rem-state
          (IrValueVar rem-var)
          (AstTyI64)
          (AstTyU64))
          [(LowerExpr rem-u-state rem-u _)
            (match (lower-cast-value
              rem-u-state
              len-value
              (AstTyI64)
              (AstTyU64))
              [(LowerExpr len-u-state len-u _)
                (match (lower-state-alloc-var len-u-state)
                  [(LowerAlloc len-ok-alloc len-ok-var)
                    (let ([len-ok-state
                        :
                        LowerState
                        (lower-state-emit
                          len-ok-alloc
                          (IrInstrBinOp
                            len-ok-var
                            IrBinLe
                            len-u
                            rem-u
                            (AstTyU64)))])
                      (lower-substring-finish-after-len-check
                        len-ok-state
                        src-ptr
                        start-value
                        len-value
                        len-ok-var
                        fail-label
                        copy-label))])])]))]))

(define (lower-substring-bounds-checked
  [state : LowerState]
  [src-ptr : CompilerIrValue]
  [src-len : CompilerIrValue]
  [start-value : CompilerIrValue]
  [len-value : CompilerIrValue]) : ResultLowerExpr
  (match (lower-cast-value state start-value (AstTyI64) (AstTyU64))
    [(LowerExpr start-u-state start-u _)
      (match (lower-cast-value start-u-state src-len (AstTyI64) (AstTyU64))
        [(LowerExpr src-len-u-state src-len-u _)
          (match (lower-state-alloc-var src-len-u-state)
            [(LowerAlloc start-ok-alloc start-ok-var)
              (let ([start-ok-state
                  :
                  LowerState
                  (lower-state-emit
                    start-ok-alloc
                    (IrInstrBinOp
                      start-ok-var
                      IrBinLe
                      start-u
                      src-len-u
                      (AstTyU64)))])
                (match (lower-state-fresh-label
                  start-ok-state
                  "substr_start_ok")
                  [(LowerLabel rem-label-state rem-label)
                    (match (lower-state-fresh-label
                      rem-label-state
                      "substr_bounds_fail")
                      [(LowerLabel fail-label-state fail-label)
                        (match (lower-state-fresh-label
                          fail-label-state
                          "substr_ok")
                          [(LowerLabel copy-label-state copy-label)
                            (let ([rem-start
                                :
                                LowerState
                                (lower-state-finish-block
                                  (lower-state-emit
                                    copy-label-state
                                    (IrInstrBranch
                                      (IrValueVar start-ok-var)
                                      rem-label
                                      fail-label))
                                  rem-label)])
                              (lower-substring-check-len
                                rem-start
                                src-ptr
                                src-len
                                start-value
                                len-value
                                fail-label
                                copy-label))])])]))])])]))

(define (lower-substring
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [str : AstExpr]
  [start : AstExpr]
  [len : AstExpr]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env str)
    [(OkLowerExpr lowered-str)
      (match lowered-str
        [(LowerExpr str-state str-value str-ty)
          (match (tc-resolve-type ctx str-ty)
            [(AstTyString)
              (match (lower-string-fields str-state str-value)
                [(LowerStringFields fields-state src-ptr src-len)
                  (match (lower-expr ctx fields-state env type-env start)
                    [(OkLowerExpr lowered-start)
                      (match lowered-start
                        [(LowerExpr start-state start-raw start-ty)
                          (match (lower-cast-value
                            start-state
                            start-raw
                            start-ty
                            (AstTyI64))
                            [(LowerExpr start-i-state start-value _)
                              (match (lower-expr
                                ctx
                                start-i-state
                                env
                                type-env
                                len)
                                [(OkLowerExpr lowered-len)
                                  (match lowered-len
                                    [(LowerExpr len-state len-raw len-ty)
                                      (match (lower-cast-value
                                        len-state
                                        len-raw
                                        len-ty
                                        (AstTyI64))
                                        [(LowerExpr len-i-state len-value _)
                                          (lower-substring-bounds-checked
                                            len-i-state
                                            src-ptr
                                            src-len
                                            start-value
                                            len-value)])])]
                                [(ErrLowerExpr message) (ErrLowerExpr message)])])])]
                    [(ErrLowerExpr message) (ErrLowerExpr message)])])]
            [_
              (ErrLowerExpr
                (lower-diagnostic-at-expr
                  str
                  "lower: substring requires String"))])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-string-concat
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [left : AstExpr]
  [right : AstExpr]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env left)
    [(OkLowerExpr lowered-left)
      (match lowered-left
        [(LowerExpr left-state left-value left-ty)
          (match (tc-resolve-type ctx left-ty)
            [(AstTyString)
              (match (lower-expr ctx left-state env type-env right)
                [(OkLowerExpr lowered-right)
                  (match lowered-right
                    [(LowerExpr right-state right-value right-ty)
                      (match (tc-resolve-type ctx right-ty)
                        [(AstTyString)
                          (match (lower-string-fields right-state left-value)
                            [(LowerStringFields
                                left-fields-state
                                left-ptr
                                left-len)
                              (match (lower-string-fields
                                left-fields-state
                                right-value)
                                [(LowerStringFields
                                    done-fields-state
                                    right-ptr
                                    right-len)
                                  (match (lower-state-alloc-var
                                    done-fields-state)
                                    [(LowerAlloc allocated var-id)
                                      (OkLowerExpr
                                        (LowerExpr
                                          (lower-state-emit
                                            allocated
                                            (IrInstrCall
                                              var-id
                                              "tl_string_concat"
                                              (IrValueCons
                                                left-ptr
                                                (IrValueCons
                                                  left-len
                                                  (IrValueCons
                                                    right-ptr
                                                    (IrValueCons
                                                      right-len
                                                      IrValueNil))))
                                              (AstTyString)))
                                          (IrValueVar var-id)
                                          (AstTyString)))])])])]
                        [_
                          (ErrLowerExpr
                            (lower-diagnostic-at-expr
                              right
                              "lower: string-concat requires String"))])])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])]
            [_
              (ErrLowerExpr
                (lower-diagnostic-at-expr
                  left
                  "lower: string-concat requires String"))])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-direct-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-args ctx state env type-env args)
    [(OkLowerArgs args-state values)
      (match (lower-state-alloc-var args-state)
        [(LowerAlloc allocated var-id)
          (OkLowerExpr
            (LowerExpr
              (lower-state-emit
                allocated
                (IrInstrCall var-id name values result-ty))
              (IrValueVar var-id)
              result-ty))])]
    [(ErrLowerArgs message) (ErrLowerExpr message)]))

(define (lower-substring-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [result-ty : AstType]) : ResultLowerExpr
  (match args
    [(AstExprCons str (AstExprCons start (AstExprCons len (AstExprNil))))
      (lower-substring ctx state env type-env str start len)]
    [_ (lower-direct-call ctx state env type-env name args result-ty)]))

(define (lower-string-concat-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [result-ty : AstType]) : ResultLowerExpr
  (match args
    [(AstExprCons left (AstExprCons right (AstExprNil)))
      (lower-string-concat ctx state env type-env left right)]
    [_ (lower-direct-call ctx state env type-env name args result-ty)]))

(define (lower-string-runtime-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [result-ty : AstType]) : ResultLowerExpr
  (if (or (string-eq name "substring") (string-eq name "string-slice"))
    (lower-substring-call ctx state env type-env name args result-ty)
    (lower-string-concat-call ctx state env type-env name args result-ty)))

;; Lower an unshadowed `(string-ref s i)` / `(char-at s i)` builtin call to the

;; bounds-checked String byte index. Since #677 the parser emits these names as

;; ordinary calls, so `lower-call` routes the unshadowed builtin here to lower it

;; like the `AstExprStringRef` node.

(define (lower-string-ref-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [result-ty : AstType]) : ResultLowerExpr
  (match args
    [(AstExprCons str (AstExprCons index (AstExprNil)))
      (lower-string-ref ctx state env type-env str index)]
    [_ (lower-direct-call ctx state env type-env name args result-ty)]))

(define (lower-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [func : AstExpr]
  [args : AstExprList]
  [result-ty : AstType]) : ResultLowerExpr
  (match (ast-expr-unspan func)
    [(AstExprVar name)
      ;; `array-length`/`length` on a dynamic array, and `string-length`/`length`
      ;; on a String, load the fat value's length field directly instead of
      ;; calling a runtime symbol (#528, #527). Other `length` argument types
      ;; keep the ordinary direct-call path. `string-ref`/`char-at` likewise
      ;; recover their String byte-index builtin here unless shadowed (#677).
      (if (and
        (lower-builtin-call-available? ctx env name)
        (or (string-eq name "string-ref") (string-eq name "char-at")))
        (lower-string-ref-call ctx state env type-env name args result-ty)
        (if (and
          (lower-builtin-call-available? ctx env name)
          (or
            (string-eq name "array-length")
            (or (string-eq name "length") (string-eq name "string-length"))))
          (lower-array-length ctx state env type-env name args result-ty)
          (if (and
            (lower-builtin-call-available? ctx env name)
            (lower-string-runtime-builtin? name))
            (lower-string-runtime-call
              ctx
              state
              env
              type-env
              name
              args
              result-ty)
            (if (and
              (lower-builtin-call-available? ctx env name)
              (lower-stdio-builtin? name))
              (lower-direct-call
                ctx
                state
                env
                type-env
                (lower-stdio-runtime-name name)
                args
                result-ty)
              (match (sym-i64-lookup env name)
                [(SomeI64 _)
                  (lower-direct-call ctx state env type-env name args result-ty)]
                [(NoneI64)
                  (match ctx
                    [(TcContext _ symbols registries)
                      (match (compiler-registries-lookup-variant
                        registries
                        name)
                        [(SomeI64 handle)
                          (lower-construct-enum-with-handle
                            ctx
                            state
                            env
                            type-env
                            name
                            handle
                            args
                            result-ty)]
                        [(NoneI64)
                          (match (compiler-symbols-lookup-type symbols name)
                            [(SomeI64 handle)
                              (if (=
                                (compiler-symbol-handle-kind handle)
                                (compiler-symbol-kind-defstruct))
                                (lower-construct-struct
                                  ctx
                                  state
                                  env
                                  type-env
                                  name
                                  args
                                  result-ty)
                                (lower-direct-call
                                  ctx
                                  state
                                  env
                                  type-env
                                  name
                                  args
                                  result-ty))]
                            [(NoneI64)
                              (lower-direct-call
                                ctx
                                state
                                env
                                type-env
                                name
                                args
                                result-ty)])])])])))))]
    [_
      (ErrLowerExpr
        (lower-diagnostic-at-expr func "lower: only direct calls are supported"))]))

;; A dynamic-array value is a pointer to inline fat storage `{data_ptr, length}`

;; with the i64 length at byte offset 8. `Gep` scales the index by the element

;; size, so index 1 with element type i64 addresses that length field, which a

;; typed `Load` then reads. Dynamic-array and String arguments are both

;; intercepted; other `length` arguments fall back to the direct-call path so

;; their runtime helper is unchanged.

(define (lower-array-length
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [result-ty : AstType]) : ResultLowerExpr
  (match args
    [(AstExprCons arr (AstExprNil))
      (match (tc-expr ctx type-env arr)
        [(OkTcType arr-ty)
          (match arr-ty
            [(AstTyDynArray _)
              (lower-array-length-load ctx state env type-env arr)]
            [(AstTyString) (lower-array-length-load ctx state env type-env arr)]
            [_ (lower-direct-call ctx state env type-env name args result-ty)])]
        [(ErrTcType _)
          (lower-direct-call ctx state env type-env name args result-ty)])]
    [_ (lower-direct-call ctx state env type-env name args result-ty)]))

(define (lower-array-length-load
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [arr : AstExpr]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env arr)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr arr-state arr-value _)
          (match (lower-state-alloc-var arr-state)
            [(LowerAlloc gep-alloc gep-var)
              (let ([gep-state
                  :
                  LowerState
                  (lower-state-emit
                    gep-alloc
                    (IrInstrGep gep-var arr-value (IrValueI64 1) (AstTyI64)))])
                (match (lower-state-alloc-var gep-state)
                  [(LowerAlloc load-alloc load-var)
                    (OkLowerExpr
                      (LowerExpr
                        (lower-state-emit
                          load-alloc
                          (IrInstrLoad load-var (IrValueVar gep-var) (AstTyI64)))
                        (IrValueVar load-var)
                        (AstTyI64)))]))])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

;; Small emit helpers: allocate a fresh var, emit one instruction, and return a

;; `LowerExpr` carrying the updated state plus the result value. These flatten

;; the otherwise deeply-nested alloc/emit chains in the array-access lowering.

(define (lower-emit-cast
  [state : LowerState]
  [value : CompilerIrValue]
  [from-ty : AstType]
  [to-ty : AstType]) : LowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc s v)
      (LowerExpr
        (lower-state-emit s (IrInstrCast v value from-ty to-ty))
        (IrValueVar v)
        to-ty)]))

(define (lower-emit-gep
  [state : LowerState]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [gep-ty : AstType]) : LowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc s v)
      (LowerExpr
        (lower-state-emit s (IrInstrGep v base index gep-ty))
        (IrValueVar v)
        gep-ty)]))

(define (lower-emit-load
  [state : LowerState]
  [addr : CompilerIrValue]
  [ty : AstType]) : LowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc s v)
      (LowerExpr (lower-state-emit s (IrInstrLoad v addr ty)) (IrValueVar v) ty)]))

(define (lower-emit-binop
  [state : LowerState]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [ty : AstType]) : LowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc s v)
      (LowerExpr
        (lower-state-emit s (IrInstrBinOp v op lhs rhs ty))
        (IrValueVar v)
        ty)]))

;; CFG tail of `lower-array-element-addr`: branch on the in-bounds condition to

;; an OK block, or a fail block that calls `tl_oob_abort` (a diverging call kept

;; by the optimizer) then jumps to OK to keep the CFG well formed. In the OK

;; block, load the buffer pointer (fat offset 0, a raw U64 address) and `Gep` it

;; by the index, scaled by the element type, to the element address.

(define (lower-array-element-addr-finish
  [state : LowerState]
  [arr-value : CompilerIrValue]
  [idx-off : CompilerIrValue]
  [cond-val : CompilerIrValue]
  [ok-label : String]
  [fail-label : String]
  [elem-ty : AstType]) : LowerExpr
  (let ([fail-start
      :
      LowerState
      (lower-state-finish-block
        (lower-state-emit state (IrInstrBranch cond-val ok-label fail-label))
        fail-label)])
    (match (lower-state-alloc-var fail-start)
      [(LowerAlloc abort-state abort-var)
        (let ([ok-start
            :
            LowerState
            (lower-state-finish-block
              (lower-state-emit
                (lower-state-emit
                  abort-state
                  (IrInstrCall abort-var "tl_oob_abort" IrValueNil (AstTyUnit)))
                (IrInstrJump ok-label))
              ok-label)])
          (match (lower-emit-gep ok-start arr-value (IrValueI64 0) (AstTyI64))
            [(LowerExpr buf-gep-state buf-gep _)
              (match (lower-emit-load buf-gep-state buf-gep (AstTyU64))
                [(LowerExpr buf-state buf-val _)
                  (lower-emit-gep buf-state buf-val idx-off elem-ty)])]))])))

;; Compute the address of element `idx-value` in dynamic array `arr-value`,

;; emitting an unsigned bounds check (negative indices wrap large and also

;; fail). Returns the element pointer as an `elem-ty`-typed value.

(define (lower-array-element-addr
  [state : LowerState]
  [arr-value : CompilerIrValue]
  [idx-value : CompilerIrValue]
  [idx-ty : AstType]
  [elem-ty : AstType]) : LowerExpr
  (match (lower-emit-cast state idx-value idx-ty (AstTyU64))
    [(LowerExpr s1 idx-u _)
      (match (lower-emit-cast s1 idx-value idx-ty (AstTyI64))
        [(LowerExpr s2 idx-off _)
          (match (lower-emit-gep s2 arr-value (IrValueI64 1) (AstTyI64))
            [(LowerExpr s3 len-gep _)
              (match (lower-emit-load s3 len-gep (AstTyI64))
                [(LowerExpr s4 len-val _)
                  (match (lower-emit-cast s4 len-val (AstTyI64) (AstTyU64))
                    [(LowerExpr s5 len-u _)
                      (match (lower-emit-binop
                        s5
                        (IrBinLt)
                        idx-u
                        len-u
                        (AstTyBool))
                        [(LowerExpr s6 cond-val _)
                          (match (lower-state-fresh-label s6 "bounds_ok")
                            [(LowerLabel s7 ok-label)
                              (match (lower-state-fresh-label s7 "bounds_fail")
                                [(LowerLabel s8 fail-label)
                                  (lower-array-element-addr-finish
                                    s8
                                    arr-value
                                    idx-off
                                    cond-val
                                    ok-label
                                    fail-label
                                    elem-ty)])])])])])])])]))

;; `(make-array T len)` -> checked length, `tl_alloc` element buffer, and a

;; heap-backed dynamic-array fat value `{ ptr, len }`.

(define (lower-make-array-store-fat
  [state : LowerState]
  [arr-ty : AstType]
  [buf-var : i64]
  [len-i64 : CompilerIrValue]) : ResultLowerExpr
  (match (lower-reserve-heap-storage state 16 arr-ty)
    [(LowerExpr arr-state arr-value _)
      (OkLowerExpr
        (LowerExpr
          (lower-store-at-offset
            (lower-store-at-offset
              arr-state
              arr-value
              0
              (IrValueVar buf-var)
              (AstTyU64))
            arr-value
            8
            len-i64
            (AstTyI64))
          arr-value
          arr-ty))]))

(define (lower-make-array-alloc-buffer
  [state : LowerState]
  [arr-ty : AstType]
  [len-i64 : CompilerIrValue]
  [elem-size : i64]) : ResultLowerExpr
  (match (lower-emit-binop
    state
    (IrBinMul)
    len-i64
    (IrValueI64 elem-size)
    (AstTyI64))
    [(LowerExpr byte-state byte-count _)
      (match (lower-state-alloc-var byte-state)
        [(LowerAlloc buf-alloc buf-var)
          (lower-make-array-store-fat
            (lower-state-emit
              buf-alloc
              (IrInstrCall
                buf-var
                "tl_alloc"
                (IrValueCons byte-count IrValueNil)
                (AstTyU64)))
            arr-ty
            buf-var
            len-i64)])]))

(define (lower-make-array-after-max-check
  [state : LowerState]
  [fail-label : String]
  [alloc-label : String]
  [arr-ty : AstType]
  [len-i64 : CompilerIrValue]
  [elem-size : i64]) : ResultLowerExpr
  (let ([fail-start : LowerState (lower-state-finish-block state fail-label)])
    (let ([alloc-start
        :
        LowerState
        (lower-state-finish-block
          (lower-state-emit
            (lower-oob-abort fail-start)
            (IrInstrJump alloc-label))
          alloc-label)])
      (lower-make-array-alloc-buffer alloc-start arr-ty len-i64 elem-size))))

(define (lower-make-array-from-len
  [ctx : TcContext]
  [state : LowerState]
  [elem-ty : AstType]
  [len-value : CompilerIrValue]
  [len-ty : AstType]) : ResultLowerExpr
  (let ([resolved-elem : AstType (tc-resolve-type ctx elem-ty)])
    (match (lower-cast-value state len-value len-ty (AstTyI64))
      [(LowerExpr len-state len-i64 _)
        (let ([elem-size : i64 (lower-type-size ctx resolved-elem)]
          [arr-ty : AstType (AstTyDynArray resolved-elem)])
          (match (lower-state-fresh-label len-state "make_array_len_nonneg")
            [(LowerLabel s1 check-max-label)
              (match (lower-state-fresh-label s1 "make_array_len_fail")
                [(LowerLabel s2 fail-label)
                  (match (lower-state-fresh-label s2 "make_array_len_ok")
                    [(LowerLabel s3 alloc-label)
                      (match (lower-emit-binop
                        s3
                        (IrBinLe)
                        (IrValueI64 0)
                        len-i64
                        (AstTyBool))
                        [(LowerExpr s4 non-negative _)
                          (let ([check-start
                              :
                              LowerState
                              (lower-state-finish-block
                                (lower-state-emit
                                  s4
                                  (IrInstrBranch
                                    non-negative
                                    check-max-label
                                    fail-label))
                                check-max-label)])
                            (let ([max-len
                                :
                                i64
                                (if (= elem-size 0)
                                  9223372036854775807
                                  (/ 9223372036854775807 elem-size))])
                              (match (lower-emit-binop
                                check-start
                                (IrBinLe)
                                len-i64
                                (IrValueI64 max-len)
                                (AstTyBool))
                                [(LowerExpr s5 within-max _)
                                  (lower-make-array-after-max-check
                                    (lower-state-emit
                                      s5
                                      (IrInstrBranch
                                        within-max
                                        alloc-label
                                        fail-label))
                                    fail-label
                                    alloc-label
                                    arr-ty
                                    len-i64
                                    elem-size)])))])])])]))])))

(define (lower-make-array
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [elem-ty : AstType]
  [len : AstExpr]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env len)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr len-state len-value len-ty)
          (lower-make-array-from-len ctx len-state elem-ty len-value len-ty)])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

;; `(array-ref arr index)` -> bounds-checked typed element load.

(define (lower-array-ref
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [arr : AstExpr]
  [index : AstExpr]) : ResultLowerExpr
  (match (tc-expr ctx type-env arr)
    [(OkTcType arr-ty)
      (match arr-ty
        [(AstTyDynArray elem-ty)
          (match (lower-expr ctx state env type-env arr)
            [(OkLowerExpr arr-lowered)
              (match arr-lowered
                [(LowerExpr arr-state arr-value _)
                  (match (tc-expr ctx type-env index)
                    [(OkTcType idx-ty)
                      (match (lower-expr ctx arr-state env type-env index)
                        [(OkLowerExpr idx-lowered)
                          (match idx-lowered
                            [(LowerExpr idx-state idx-value _)
                              (match (lower-array-element-addr
                                idx-state
                                arr-value
                                idx-value
                                idx-ty
                                elem-ty)
                                [(LowerExpr addr-state elem-ptr _)
                                  (match (lower-emit-load
                                    addr-state
                                    elem-ptr
                                    elem-ty)
                                    [(LowerExpr load-state load-value _)
                                      (OkLowerExpr
                                        (LowerExpr
                                          load-state
                                          load-value
                                          elem-ty))])])])]
                        [(ErrLowerExpr message) (ErrLowerExpr message)])]
                    [(ErrTcType message)
                      (ErrLowerExpr (lower-diagnostic-at-expr index message))])])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])]
        [(AstTyArray _ _)
          (ErrLowerExpr
            (lower-diagnostic-at-expr
              arr
              "lower: fixed-array array-ref not yet supported"))]
        [_
          (ErrLowerExpr
            (lower-diagnostic-at-expr
              arr
              "lower: array-ref requires a dynamic array"))])]
    [(ErrTcType message) (ErrLowerExpr (lower-diagnostic-at-expr arr message))]))

;; `(array-set! arr index value)` -> bounds-checked typed element store.

(define (lower-array-set
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [arr : AstExpr]
  [index : AstExpr]
  [value : AstExpr]) : ResultLowerExpr
  (match (tc-expr ctx type-env arr)
    [(OkTcType arr-ty)
      (match arr-ty
        [(AstTyDynArray elem-ty)
          (match (lower-expr ctx state env type-env arr)
            [(OkLowerExpr arr-lowered)
              (match arr-lowered
                [(LowerExpr arr-state arr-value _)
                  (match (tc-expr ctx type-env index)
                    [(OkTcType idx-ty)
                      (match (lower-expr ctx arr-state env type-env index)
                        [(OkLowerExpr idx-lowered)
                          (match idx-lowered
                            [(LowerExpr idx-state idx-value _)
                              (match (lower-expr
                                ctx
                                idx-state
                                env
                                type-env
                                value)
                                [(OkLowerExpr value-lowered)
                                  (match value-lowered
                                    [(LowerExpr value-state value-ir _)
                                      (match (lower-array-element-addr
                                        value-state
                                        arr-value
                                        idx-value
                                        idx-ty
                                        elem-ty)
                                        [(LowerExpr addr-state elem-ptr _)
                                          (OkLowerExpr
                                            (LowerExpr
                                              (lower-state-emit
                                                addr-state
                                                (IrInstrStorePtr
                                                  elem-ptr
                                                  value-ir
                                                  elem-ty))
                                              IrValueUnit
                                              (AstTyUnit)))])])]
                                [(ErrLowerExpr message) (ErrLowerExpr message)])])]
                        [(ErrLowerExpr message) (ErrLowerExpr message)])]
                    [(ErrTcType message)
                      (ErrLowerExpr (lower-diagnostic-at-expr index message))])])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])]
        [(AstTyArray _ _)
          (ErrLowerExpr
            (lower-diagnostic-at-expr
              arr
              "lower: fixed-array array-set! not yet supported"))]
        [_
          (ErrLowerExpr
            (lower-diagnostic-at-expr
              arr
              "lower: array-set! requires a dynamic array"))])]
    [(ErrTcType message) (ErrLowerExpr (lower-diagnostic-at-expr arr message))]))

(define (lower-args
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]) : ResultLowerArgs
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

(define (lower-let-binding-type
  [ctx : TcContext]
  [maybe-ty : AstMaybeType]
  [init-ty : AstType]) : AstType
  (match maybe-ty
    [(AstSomeType ty) (tc-resolve-type ctx ty)]
    [(AstNoType) init-ty]))

(define (lower-let-bindings
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [bindings : AstLetBindingList]) : ResultLowerEnv
  (match bindings
    [(AstLetBindingNil) (OkLowerEnv state env type-env)]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding name maybe-ty init)
          (match (lower-expr ctx state env type-env init)
            [(OkLowerExpr lowered)
              (match lowered
                [(LowerExpr init-state init-value init-ty)
                  (let ([binding-ty
                      :
                      AstType
                      (lower-let-binding-type ctx maybe-ty init-ty)])
                    (match (lower-state-alloc-var init-state)
                      [(LowerAlloc allocated var-id)
                        (lower-let-bindings
                          ctx
                          (lower-state-emit
                            allocated
                            (IrInstrMov var-id init-value binding-ty))
                          (sym-i64-bind env name var-id)
                          (tc-bind type-env name binding-ty)
                          rest)]))])]
            [(ErrLowerExpr message) (ErrLowerEnv message)])])]))

(define (lower-begin
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [exprs : AstExprList]) : ResultLowerExpr
  (match exprs
    [(AstExprNil) (OkLowerExpr (LowerExpr state IrValueUnit (AstTyUnit)))]
    [(AstExprCons expr rest)
      (match rest
        [(AstExprNil) (lower-expr ctx state env type-env expr)]
        [_
          (match (lower-expr ctx state env type-env expr)
            [(OkLowerExpr lowered)
              (match lowered
                [(LowerExpr next-state _ _)
                  (lower-begin ctx next-state env type-env rest)])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])])]))

(define (lower-if-merge
  [else-state : LowerState]
  [then-value : CompilerIrValue]
  [then-end-label : String]
  [else-value : CompilerIrValue]
  [merge-label : String]
  [expr-ty : AstType]) : ResultLowerExpr
  (let ([else-end-label : String (lower-state-current-label else-state)])
    (let ([merge-start
        :
        LowerState
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

(define (lower-if-else
  [ctx : TcContext]
  [else-start : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [else-branch : AstExpr]
  [then-value : CompilerIrValue]
  [then-end-label : String]
  [merge-label : String]
  [expr-ty : AstType]) : ResultLowerExpr
  (match (lower-expr ctx else-start env type-env else-branch)
    [(OkLowerExpr else-lowered)
      (match else-lowered
        [(LowerExpr else-state else-value _)
          (lower-if-merge
            else-state
            then-value
            then-end-label
            else-value
            merge-label
            expr-ty)])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-if-then
  [ctx : TcContext]
  [then-start : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [then-branch : AstExpr]
  [else-branch : AstExpr]
  [else-label : String]
  [merge-label : String]
  [expr-ty : AstType]) : ResultLowerExpr
  (match (lower-expr ctx then-start env type-env then-branch)
    [(OkLowerExpr then-lowered)
      (match then-lowered
        [(LowerExpr then-state then-value _)
          (let ([then-end-label : String (lower-state-current-label then-state)])
            (let ([else-start
                :
                LowerState
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

(define (lower-if
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [cond : AstExpr]
  [then-branch : AstExpr]
  [else-branch : AstExpr]
  [expr-ty : AstType]) : ResultLowerExpr
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
                      (let ([branch-state
                          :
                          LowerState
                          (lower-state-emit
                            merge-label-state
                            (IrInstrBranch cond-value then-label else-label))])
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

(define (lower-while
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [cond : AstExpr]
  [body : AstExpr]) : ResultLowerExpr
  (match (lower-state-fresh-label state "while_header")
    [(LowerLabel header-label-state header-label)
      (match (lower-state-fresh-label header-label-state "while_body")
        [(LowerLabel body-label-state body-label)
          (match (lower-state-fresh-label body-label-state "while_exit")
            [(LowerLabel exit-label-state exit-label)
              (let ([header-start
                  :
                  LowerState
                  (lower-state-finish-block
                    (lower-state-emit
                      exit-label-state
                      (IrInstrJump header-label))
                    header-label)])
                (match (lower-expr ctx header-start env type-env cond)
                  [(OkLowerExpr cond-lowered)
                    (match cond-lowered
                      [(LowerExpr cond-state cond-value _)
                        (let ([body-start
                            :
                            LowerState
                            (lower-state-finish-block
                              (lower-state-emit
                                cond-state
                                (IrInstrBranch cond-value body-label exit-label))
                              body-label)])
                          (match (lower-expr ctx body-start env type-env body)
                            [(OkLowerExpr body-lowered)
                              (match body-lowered
                                [(LowerExpr body-state _ _)
                                  (OkLowerExpr
                                    (LowerExpr
                                      (lower-state-finish-block
                                        (lower-state-emit
                                          body-state
                                          (IrInstrJump header-label))
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

;; match emits no value phi. Enum matches reuse the same merge path, but load the

;; heap tag once and dispatch variant arms by tag (#517).

(define (lower-match
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrutinee : AstExpr]
  [arms : AstMatchArmList]
  [expr-ty : AstType]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env scrutinee)
    [(OkLowerExpr scrut-lowered)
      (match scrut-lowered
        [(LowerExpr scrut-state scrut-value scrut-ty)
          (match (lower-state-alloc-var scrut-state)
            [(LowerAlloc scrut-alloc scrut-var)
              (match (lower-state-fresh-label
                (lower-state-emit
                  scrut-alloc
                  (IrInstrMov scrut-var scrut-value scrut-ty))
                "match_merge")
                [(LowerLabel merge-state merge-label)
                  (match (tc-resolve-type ctx scrut-ty)
                    [(AstTyEnum _)
                      (lower-match-enum
                        ctx
                        merge-state
                        env
                        type-env
                        scrut-var
                        scrut-ty
                        arms
                        merge-label
                        expr-ty)]
                    [_
                      (lower-match-arms
                        ctx
                        merge-state
                        env
                        type-env
                        scrut-var
                        scrut-ty
                        arms
                        merge-label
                        expr-ty
                        IrPhiInputNil)])])])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-match-enum
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrut-var : i64]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]
  [merge-label : String]
  [expr-ty : AstType]) : ResultLowerExpr
  (match (lower-load-at-offset state (IrValueVar scrut-var) 0 (AstTyI64))
    [(LowerExpr tag-state tag-value _)
      (match tag-value
        [(IrValueVar tag-var)
          (lower-match-enum-arms
            ctx
            tag-state
            env
            type-env
            scrut-var
            scrut-ty
            tag-var
            arms
            merge-label
            expr-ty
            IrPhiInputNil)]
        [_
          (ErrLowerExpr
            (lower-diagnostic "lower: internal enum tag load failed"))])]))

(define (lower-match-arms
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrut-var : i64]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]
  [merge-label : String]
  [expr-ty : AstType]
  [phi-inputs : CompilerIrPhiInputList]) : ResultLowerExpr
  (match arms
    [(AstMatchArmNil)
      (ErrLowerExpr (lower-diagnostic "lower: match with no arms"))]
    [(AstMatchArmCons arm rest)
      (match rest
        [(AstMatchArmNil)
          (lower-match-catch-all
            ctx
            state
            env
            type-env
            scrut-var
            scrut-ty
            arm
            merge-label
            expr-ty
            phi-inputs)]
        [_
          (match arm
            [(AstMatchArm pat body)
              (match pat
                [(AstPatLiteral lit)
                  (lower-match-literal-arm
                    ctx
                    state
                    env
                    type-env
                    scrut-var
                    scrut-ty
                    lit
                    body
                    rest
                    merge-label
                    expr-ty
                    phi-inputs)]
                [(AstPatBinding _)
                  (lower-match-catch-all
                    ctx
                    state
                    env
                    type-env
                    scrut-var
                    scrut-ty
                    arm
                    merge-label
                    expr-ty
                    phi-inputs)]
                [(AstPatWildcard)
                  (lower-match-catch-all
                    ctx
                    state
                    env
                    type-env
                    scrut-var
                    scrut-ty
                    arm
                    merge-label
                    expr-ty
                    phi-inputs)]
                [_
                  (ErrLowerExpr
                    (lower-diagnostic "lower: unsupported match pattern"))])])])]))

(define (lower-match-enum-arms
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrut-var : i64]
  [scrut-ty : AstType]
  [tag-var : i64]
  [arms : AstMatchArmList]
  [merge-label : String]
  [expr-ty : AstType]
  [phi-inputs : CompilerIrPhiInputList]) : ResultLowerExpr
  (match arms
    [(AstMatchArmNil)
      (ErrLowerExpr (lower-diagnostic "lower: match with no arms"))]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm pat body)
          (match rest
            [(AstMatchArmNil)
              (match pat
                [(AstPatWildcard)
                  (lower-match-catch-all
                    ctx
                    state
                    env
                    type-env
                    scrut-var
                    scrut-ty
                    arm
                    merge-label
                    expr-ty
                    phi-inputs)]
                [(AstPatBinding variant-name)
                  (lower-match-variant-final
                    ctx
                    state
                    env
                    type-env
                    scrut-var
                    variant-name
                    AstPatternNil
                    body
                    merge-label
                    expr-ty
                    phi-inputs)]
                [(AstPatVariant variant-name args)
                  (lower-match-variant-final
                    ctx
                    state
                    env
                    type-env
                    scrut-var
                    variant-name
                    args
                    body
                    merge-label
                    expr-ty
                    phi-inputs)]
                [_
                  (ErrLowerExpr
                    (lower-diagnostic "lower: unsupported enum match pattern"))])]
            [_
              (match pat
                [(AstPatWildcard)
                  (lower-match-catch-all
                    ctx
                    state
                    env
                    type-env
                    scrut-var
                    scrut-ty
                    arm
                    merge-label
                    expr-ty
                    phi-inputs)]
                [(AstPatBinding variant-name)
                  (lower-match-variant-arm
                    ctx
                    state
                    env
                    type-env
                    scrut-var
                    scrut-ty
                    tag-var
                    variant-name
                    AstPatternNil
                    body
                    rest
                    merge-label
                    expr-ty
                    phi-inputs)]
                [(AstPatVariant variant-name args)
                  (lower-match-variant-arm
                    ctx
                    state
                    env
                    type-env
                    scrut-var
                    scrut-ty
                    tag-var
                    variant-name
                    args
                    body
                    rest
                    merge-label
                    expr-ty
                    phi-inputs)]
                [_
                  (ErrLowerExpr
                    (lower-diagnostic "lower: unsupported enum match pattern"))])])])]))

(define (lower-match-variant-final
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrut-var : i64]
  [variant-name : String]
  [args : AstPatternList]
  [body : AstExpr]
  [merge-label : String]
  [expr-ty : AstType]
  [phi-inputs : CompilerIrPhiInputList]) : ResultLowerExpr
  (match ctx
    [(TcContext program _ registries)
      (match (compiler-registries-lookup-variant registries variant-name)
        [(SomeI64 handle)
          (match (compiler-registries-variant-fields program handle)
            [(OkAstTypeList fields)
              ;; The final arm has no next-arm continuation, so a refutable
              ;; payload subpattern here would have nowhere to fall through to;
              ;; require a trailing catch-all instead (#651).
              (if (lower-pattern-list-refutable? args)
                (ErrLowerExpr
                  (lower-diagnostic
                    "lower: refutable payload pattern in final match arm requires a trailing catch-all"))
                (match (lower-bind-variant-payloads
                  ctx
                  state
                  env
                  type-env
                  (IrValueVar scrut-var)
                  args
                  fields
                  8
                  merge-label)
                  [(OkLowerEnv body-start body-env body-type-env)
                    (match (lower-expr
                      ctx
                      body-start
                      body-env
                      body-type-env
                      body)
                      [(OkLowerExpr body-lowered)
                        (match body-lowered
                          [(LowerExpr body-state body-value _)
                            (let ([body-end-label
                                :
                                String
                                (lower-state-current-label body-state)])
                              (lower-match-finish
                                (lower-state-emit
                                  body-state
                                  (IrInstrJump merge-label))
                                merge-label
                                expr-ty
                                (IrPhiInputCons
                                  (IrPhiInput body-value body-end-label)
                                  phi-inputs)))])]
                      [(ErrLowerExpr message) (ErrLowerExpr message)])]
                  [(ErrLowerEnv message) (ErrLowerExpr message)]))]
            [(ErrAstTypeList message) (ErrLowerExpr (lower-diagnostic message))])]
        [(NoneI64)
          (ErrLowerExpr
            (lower-diagnostic
              (string-append "lower: unknown variant " variant-name)))])]))

(define (lower-match-variant-body
  [ctx : TcContext]
  [body-start : LowerState]
  [next-label : String]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrut-var : i64]
  [scrut-ty : AstType]
  [tag-var : i64]
  [fields : AstTypeList]
  [args : AstPatternList]
  [body : AstExpr]
  [rest : AstMatchArmList]
  [merge-label : String]
  [expr-ty : AstType]
  [phi-inputs : CompilerIrPhiInputList]) : ResultLowerExpr
  (match (lower-bind-variant-payloads
    ctx
    body-start
    env
    type-env
    (IrValueVar scrut-var)
    args
    fields
    8
    next-label)
    [(OkLowerEnv bound-state body-env body-type-env)
      (match (lower-expr ctx bound-state body-env body-type-env body)
        [(OkLowerExpr body-lowered)
          (match body-lowered
            [(LowerExpr body-state body-value _)
              (let ([body-end-label
                  :
                  String
                  (lower-state-current-label body-state)])
                (lower-match-enum-arms
                  ctx
                  (lower-state-finish-block
                    (lower-state-emit body-state (IrInstrJump merge-label))
                    next-label)
                  env
                  type-env
                  scrut-var
                  scrut-ty
                  tag-var
                  rest
                  merge-label
                  expr-ty
                  (IrPhiInputCons
                    (IrPhiInput body-value body-end-label)
                    phi-inputs)))])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(ErrLowerEnv message) (ErrLowerExpr message)]))

(define (lower-match-variant-arm
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrut-var : i64]
  [scrut-ty : AstType]
  [tag-var : i64]
  [variant-name : String]
  [args : AstPatternList]
  [body : AstExpr]
  [rest : AstMatchArmList]
  [merge-label : String]
  [expr-ty : AstType]
  [phi-inputs : CompilerIrPhiInputList]) : ResultLowerExpr
  (match ctx
    [(TcContext program _ registries)
      (match (compiler-registries-lookup-variant registries variant-name)
        [(SomeI64 handle)
          (match (compiler-registries-variant-fields program handle)
            [(OkAstTypeList fields)
              (match (lower-state-alloc-var state)
                [(LowerAlloc eq-alloc eq-var)
                  (let ([eq-state
                      :
                      LowerState
                      (lower-state-emit
                        eq-alloc
                        (IrInstrBinOp
                          eq-var
                          IrBinEq
                          (IrValueVar tag-var)
                          (IrValueI64
                            (compiler-registry-handle-child-index handle))
                          (AstTyI64)))])
                    (match (lower-state-fresh-label eq-state "match_arm")
                      [(LowerLabel body-label-state body-label)
                        (match (lower-state-fresh-label
                          body-label-state
                          "match_next")
                          [(LowerLabel next-label-state next-label)
                            (let ([body-start
                                :
                                LowerState
                                (lower-state-finish-block
                                  (lower-state-emit
                                    next-label-state
                                    (IrInstrBranch
                                      (IrValueVar eq-var)
                                      body-label
                                      next-label))
                                  body-label)])
                              (lower-match-variant-body
                                ctx
                                body-start
                                next-label
                                env
                                type-env
                                scrut-var
                                scrut-ty
                                tag-var
                                fields
                                args
                                body
                                rest
                                merge-label
                                expr-ty
                                phi-inputs))])]))])]
            [(ErrAstTypeList message) (ErrLowerExpr (lower-diagnostic message))])]
        [(NoneI64)
          (ErrLowerExpr
            (lower-diagnostic
              (string-append "lower: unknown variant " variant-name)))])]))

(define (lower-match-literal-arm
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrut-var : i64]
  [scrut-ty : AstType]
  [lit : AstLiteral]
  [body : AstExpr]
  [rest : AstMatchArmList]
  [merge-label : String]
  [expr-ty : AstType]
  [phi-inputs : CompilerIrPhiInputList]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc eq-alloc eq-var)
      (let ([eq-state
          :
          LowerState
          (lower-state-emit
            eq-alloc
            (IrInstrBinOp
              eq-var
              IrBinEq
              (IrValueVar scrut-var)
              (lower-literal-value lit)
              scrut-ty))])
        (match (lower-state-fresh-label eq-state "match_arm")
          [(LowerLabel body-label-state body-label)
            (match (lower-state-fresh-label body-label-state "match_next")
              [(LowerLabel next-label-state next-label)
                (let ([body-start
                    :
                    LowerState
                    (lower-state-finish-block
                      (lower-state-emit
                        next-label-state
                        (IrInstrBranch
                          (IrValueVar eq-var)
                          body-label
                          next-label))
                      body-label)])
                  (match (lower-expr ctx body-start env type-env body)
                    [(OkLowerExpr body-lowered)
                      (match body-lowered
                        [(LowerExpr body-state body-value _)
                          (let ([body-end-label
                              :
                              String
                              (lower-state-current-label body-state)])
                            (lower-match-arms
                              ctx
                              (lower-state-finish-block
                                (lower-state-emit
                                  body-state
                                  (IrInstrJump merge-label))
                                next-label)
                              env
                              type-env
                              scrut-var
                              scrut-ty
                              rest
                              merge-label
                              expr-ty
                              (IrPhiInputCons
                                (IrPhiInput body-value body-end-label)
                                phi-inputs)))])]
                    [(ErrLowerExpr message) (ErrLowerExpr message)]))])]))]))

(define (lower-match-catch-all
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrut-var : i64]
  [scrut-ty : AstType]
  [arm : AstMatchArm]
  [merge-label : String]
  [expr-ty : AstType]
  [phi-inputs : CompilerIrPhiInputList]) : ResultLowerExpr
  (match arm
    [(AstMatchArm pat body)
      (let ([body-env
          :
          SymI64Env
          (match pat
            [(AstPatBinding name) (sym-i64-bind env name scrut-var)]
            [_ env])]
        [body-type-env
          :
          TcTypeEnv
          (match pat
            [(AstPatBinding name) (tc-bind type-env name scrut-ty)]
            [_ type-env])])
        (match (lower-expr ctx state body-env body-type-env body)
          [(OkLowerExpr body-lowered)
            (match body-lowered
              [(LowerExpr body-state body-value _)
                (let ([body-end-label
                    :
                    String
                    (lower-state-current-label body-state)])
                  (lower-match-finish
                    (lower-state-emit body-state (IrInstrJump merge-label))
                    merge-label
                    expr-ty
                    (IrPhiInputCons
                      (IrPhiInput body-value body-end-label)
                      phi-inputs)))])]
          [(ErrLowerExpr message) (ErrLowerExpr message)]))]))

(define (lower-match-finish
  [state : LowerState]
  [merge-label : String]
  [expr-ty : AstType]
  [phi-inputs : CompilerIrPhiInputList]) : ResultLowerExpr
  (let ([merge-start : LowerState (lower-state-finish-block state merge-label)])
    (match expr-ty
      [(AstTyUnit) (OkLowerExpr (LowerExpr merge-start IrValueUnit expr-ty))]
      [_
        (match (lower-state-alloc-var merge-start)
          [(LowerAlloc allocated var-id)
            (OkLowerExpr
              (LowerExpr
                (lower-state-emit
                  allocated
                  (IrInstrPhi var-id phi-inputs expr-ty))
                (IrValueVar var-id)
                expr-ty))])])))

(define (lower-param-count [params : AstParamList]) : i64
  (match params
    [(AstParamNil) 0]
    [(AstParamCons _ rest) (+ 1 (lower-param-count rest))]))

(define (lower-bind-params
  [params : AstParamList]
  [idx : i64]
  [env : SymI64Env]) : SymI64Env
  (match params
    [(AstParamNil) env]
    [(AstParamCons param rest)
      (match param
        [(AstParam name _)
          (lower-bind-params rest (+ idx 1) (sym-i64-bind env name idx))])]))

(define (lower-param-list [ctx : TcContext] [params : AstParamList] [idx : i64]) : CompilerIrParamList
  (match params
    [(AstParamNil) IrParamNil]
    [(AstParamCons param rest)
      (match param
        [(AstParam name ty)
          (IrParamCons
            (IrParam name (tc-resolve-type ctx ty) idx)
            (lower-param-list ctx rest (+ idx 1)))])]))

(define (lower-function
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [name : String]
  [params : AstParamList]
  [ret : AstType]
  [body : AstExpr]) : ResultLowerFunction
  (let ([param-count : i64 (lower-param-count params)])
    (let ([env : SymI64Env (lower-bind-params params 0 (sym-i64-empty))]
      [type-env : TcTypeEnv (tc-bind-params ctx top-env params)]
      [state
        :
        LowerState
        (LowerState param-count 0 "entry" IrInstrNil IrBlockNil)]
      [ret-ty : AstType (tc-resolve-type ctx ret)])
      (match (lower-expr ctx state env type-env body)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr body-state value _)
              (let ([final-state
                  :
                  LowerState
                  (lower-state-emit
                    body-state
                    (IrInstrReturn (lower-return-maybe value ret-ty)))])
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
    [_
      (ErrLowerValue (lower-diagnostic "lower: unsupported global initializer"))]))

(define (lower-decls
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [decls : AstDeclList]
  [globals : CompilerIrGlobalList]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]) : ResultLowerDecls
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
            [(ErrTcType message) (ErrLowerDecls (lower-diagnostic message))])]
        [(AstDeclExtern name ty)
          (lower-decls
            ctx
            top-env
            rest
            globals
            functions
            (lower-extern-list-append
              externs
              (IrExtern name (tc-resolve-type ctx ty))))]
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
        [(AstDeclImport _)
          (lower-decls ctx top-env rest globals functions externs)]
        [(AstDeclDefEnum _ _)
          (lower-decls ctx top-env rest globals functions externs)]
        [(AstDeclDefStruct _ _)
          (lower-decls ctx top-env rest globals functions externs)])]))

(define (lower-compiler-program-checked
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [program : AstProgram]) : ResultCompilerLower
  (match program
    [(AstProgram decls)
      (match (lower-decls
        ctx
        top-env
        decls
        IrGlobalNil
        IrFunctionNil
        IrExternNil)
        [(OkLowerDecls globals functions externs)
          (OkCompilerLower (IrProgram globals functions externs))]
        [(ErrLowerDecls message) (ErrCompilerLower message)])]))

(define (lower-compiler-program-unlocated [program : AstProgram]) : ResultCompilerLower
  (match (typecheck-compiler-program program)
    [(OkCompilerTypecheck _)
      (match (build-compiler-symbols program)
        [(OkCompilerSymbols symbols)
          (match (build-compiler-registries program)
            [(OkCompilerRegistries registries)
              (let ([ctx : TcContext (TcContext program symbols registries)])
                (match (tc-build-top-env ctx program)
                  [(OkTcEnv top-env)
                    (lower-compiler-program-checked ctx top-env program)]
                  [(ErrTcEnv message)
                    (ErrCompilerLower (lower-diagnostic message))]))]
            [(ErrCompilerRegistries message)
              (ErrCompilerLower (lower-diagnostic message))])]
        [(ErrCompilerSymbols message)
          (ErrCompilerLower (lower-diagnostic message))])]
    [(ErrCompilerTypecheck diag) (ErrCompilerLower diag)]))

(define (lower-compiler-program-with-path
  [path : String]
  [program : AstProgram]) : ResultCompilerLower
  (match (lower-compiler-program-unlocated program)
    [(OkCompilerLower ir) (OkCompilerLower ir)]
    [(ErrCompilerLower diag)
      (ErrCompilerLower (lower-diagnostic-with-path diag path))]))

(define (lower-compiler-program [program : AstProgram]) : ResultCompilerLower
  (lower-compiler-program-with-path "<source>" program))

(define (lower-compiler-source [src : String]) : ResultCompilerLower
  (lower-compiler-source-with-path "<source>" src))

(define (lower-compiler-source-with-path [path : String] [src : String]) : ResultCompilerLower
  (match (parse-ast-source src)
    [(OkAstProgram program) (lower-compiler-program-with-path path program)]
    [(ErrAstProgram message)
      (ErrCompilerLower
        (lower-diagnostic-with-path (lower-diagnostic message) path))]))

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

;; `(comptime expr)` parses and type-checks (inner type), but lowering reserves

;; it until the evaluator (#719) lands (#718).

(define (compiler-lower-comptime-reserved-source) : String
  "(define (main) : i64 (comptime (+ 1 2)))")

(define (compiler-lower-error-ok? [src : String] [want : String]) : bool
  (match (lower-compiler-source src)
    [(ErrCompilerLower diag)
      (string-eq (compiler-diagnostic-message diag) want)]
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

;; Dynamic-array length lowering smoke (#528): `array-length` and `length` on a

;; dynamic array lower to a fat-value length load rather than a runtime call.

(define (compiler-lower-array-length-source) : String
  "(define (dyn-len [a : (Array i64)]) : i64 (array-length a))
(define (dyn-len-alias [a : (Array i64)]) : i64 (length a))
(define (main) : i64 0)")

;; `array-ref`/`array-set!` lower to a bounds-checked typed element load/store

;; (#528). Taking the array as a parameter avoids needing `make-array` here.

(define (compiler-lower-array-access-source) : String
  "(define (get [a : (Array i64)] [i : i64]) : i64 (array-ref a i))
(define (put [a : (Array i64)] [i : i64] [v : i64]) : unit (array-set! a i v))
(define (main) : i64 0)")

;; `make-array` lowers to checked byte-count math, a `tl_alloc` element buffer,

;; and a dynamic-array fat value. The fixture also immediately uses

;; `array-set!`, `array-ref`, and `array-length` so the generated IR exercises

;; the full dynamic-array primitive set.

(define (compiler-lower-make-array-source) : String
  "(define (main [n : i64]) : i64
  (let ([a : (Array i64) (make-array i64 n)])
    (begin
      (array-set! a 0 40)
      (array-set! a 1 2)
      (+ (array-length a) (+ (array-ref a 0) (array-ref a 1))))))")

;; `string-length`/`length` on a String lower to the same fat `{ptr, len}`

;; length load as `array-length` (#527): both lay out the i64 length at offset 8.

(define (compiler-lower-string-length-source) : String
  "(define (str-len [s : String]) : i64 (string-length s))
(define (str-len-alias [s : String]) : i64 (length s))
(define (main) : i64 0)")

(define (compiler-lower-string-runtime-source) : String
  "(define (main) : i64
  (let ([joined : String (string-append \"foo\" \"bar\")]
        [mid : String (substring \"abcdef\" 2 3)]
        [extended : String (string-concat mid \"!\")])
    (+ (string-length joined)
      (+ (string-length extended)
        (cast (char-at \" x\" 0) : i64)))))")

(define (compiler-lower-string-shadow-source) : String
  "(define (string-length [s : String]) : i64 40)
(define (string-append [a : i64] [b : i64]) : i64 (+ a b))
(define (string-ref [a : i64] [b : i64]) : i64 (+ a b))
(define (char-at [a : i64] [b : i64]) : i64 (* a b))
(define (main) : i64
  (+ (string-length \"abc\")
    (+ (string-append 1 1)
      (+ (string-ref 10 7) (char-at 3 4)))))")

(define (compiler-lower-stdio-source) : String
  "(define (main) : i64
  (begin
    (flush-stdout)
    (if (stdin-eof?)
        (string-length (read-stdin-line))
        (string-length (read-stdin-bytes 3)))))")

(define (compiler-lower-aggregate-source) : String
  "(defstruct Point (x i64) (y i64))
(defenum Shape (Nothing) (Circle i64) (Pair Point))
(define (make-point [x : i64] [y : i64]) : Point
  (Point x y))
(define (get-y [p : Point]) : i64
  (struct-get p y))
(define (make-none) : Shape
  Nothing)
(define (make-none-call) : Shape
  (Nothing))
(define (make-circle [r : i64]) : Shape
  (Circle r))
(define (make-pair [x : i64]) : Shape
  (Pair (Point x (+ x 1))))
(define (main) : i64
  (get-y (make-point 20 22)))")

(define (compiler-lower-enum-match-source) : String
  "(defenum Maybe (None) (Some i64) (Pair i64 i64))
(define (score [m : Maybe]) : i64
  (match m
    [None 0]
    [(Some v) (+ v 1)]
    [(Pair left _) left]))
(define (zero-call [m : Maybe]) : i64
  (match m
    [(None) 0]
    [_ 1]))
(define (or-zero [m : Maybe]) : i64
  (match m
    [(Some v) v]
    [_ 0]))
(define (touch [m : Maybe]) : unit
  (match m
    [None unit]
    [(Some _) unit]
    [(Pair _ _) unit]))
(define (main) : i64
  (+ (score (Some 4)) (+ (zero-call None) (or-zero (Pair 3 4)))))")

;; A refutable literal payload subpattern (#651): `(Some 0)` tests the payload

;; and, on mismatch, falls through to the `(Some n)` binding arm. The trailing

;; `(Some n)` keeps the match exhaustive.

(define (compiler-lower-enum-literal-payload-source) : String
  "(defenum Maybe (None) (Some i64))
(define (classify [m : Maybe]) : i64
  (match m
    [(Some 0) 100]
    [(Some n) n]
    [None 5]))
(define (main) : i64 0)")

;; A refutable nested-variant payload subpattern (#651): `(Wrap (A n))` tests

;; the inner enum's tag and, on mismatch, falls through to `(Wrap inner)` (the

;; irrefutable Wrap arm keeps the match exhaustive).

(define (compiler-lower-enum-nested-payload-source) : String
  "(defenum Inner (A i64) (B i64))
(defenum Outer (Wrap Inner) (Empty))
(define (classify [o : Outer]) : i64
  (match o
    [(Wrap (A n)) n]
    [(Wrap inner) 50]
    [Empty 0]))
(define (main) : i64 0)")

(define (compiler-lower-enum-string-literal-payload-source) : String
  "(defenum Token (TIdent String) (TEnd))
(define (classify [t : Token]) : i64
  (match t
    [(TIdent \"if\") 10]
    [(TIdent _) 1]
    [TEnd 0]))
(define (main) : i64 0)")

(define (compiler-lower-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower _) true]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-ok-summary? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program)
      (let ([summary : CompilerIrSummary (compiler-ir-program-summary program)])
        (and
          (= (compiler-ir-summary-globals summary) 1)
          (and
            (= (compiler-ir-summary-functions summary) 2)
            (and
              (= (compiler-ir-summary-externs summary) 1)
              (and
                (= (compiler-ir-summary-blocks summary) 8)
                (and
                  (= (compiler-ir-summary-instructions summary) 29)
                  (= (compiler-ir-summary-vars summary) 21)))))))]
    [(ErrCompilerLower _) false]))

;; Count `IrInstrPhi` nodes, to assert the merge-phi shape of lowered scalar

;; matches (#602): value-returning matches emit a merge phi, unit matches none.

(define (lower-test-instr-phi-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrPhi _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-load-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrLoad _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-call-count [instr : CompilerIrInstr] [name : String]) : i64
  (match instr
    [(IrInstrCall _ call-name _ _)
      (if (string-eq call-name name)
        1
        0)]
    [_ 0]))

(define (lower-test-instrs-phi-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+ (lower-test-instr-phi-count instr) (lower-test-instrs-phi-count rest))]))

(define (lower-test-instrs-load-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-load-count instr)
        (lower-test-instrs-load-count rest))]))

(define (lower-test-instrs-call-count
  [instrs : CompilerIrInstrList]
  [name : String]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-call-count instr name)
        (lower-test-instrs-call-count rest name))]))

(define (lower-test-blocks-phi-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-phi-count instrs)
            (lower-test-blocks-phi-count rest))])]))

(define (lower-test-blocks-load-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-load-count instrs)
            (lower-test-blocks-load-count rest))])]))

(define (lower-test-blocks-call-count
  [blocks : CompilerIrBlockList]
  [name : String]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-call-count instrs name)
            (lower-test-blocks-call-count rest name))])]))

;; Phi count of the function named `name`, or -1 when no such function exists

;; (so a missing function fails both the `> 0` and `= 0` assertions below).

(define (lower-test-function-phi-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-phi-count blocks)
            (lower-test-function-phi-count rest name))])]))

(define (lower-test-function-load-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-load-count blocks)
            (lower-test-function-load-count rest name))])]))

(define (lower-test-functions-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (+
            (lower-test-blocks-call-count blocks name)
            (lower-test-functions-call-count rest name))])]))

;; The value-returning scalar matches (`classify`/`flag-score`/`sign`) each emit

;; a merge phi; the unit-typed match (`announce`) emits no value phi.

(define (compiler-lower-match-phi-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program)
      (match program
        [(IrProgram _ functions _)
          (and
            (> (lower-test-function-phi-count functions "classify") 0)
            (and
              (> (lower-test-function-phi-count functions "flag-score") 0)
              (and
                (> (lower-test-function-phi-count functions "sign") 0)
                (= (lower-test-function-phi-count functions "announce") 0))))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-enum-match-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program)
      (match program
        [(IrProgram _ functions _)
          (and
            (> (lower-test-function-phi-count functions "score") 0)
            (and
              (> (lower-test-function-phi-count functions "zero-call") 0)
              (and
                (> (lower-test-function-phi-count functions "or-zero") 0)
                (and
                  (= (lower-test-function-phi-count functions "touch") 0)
                  (and
                    (> (lower-test-function-load-count functions "score") 1)
                    (> (lower-test-function-load-count functions "or-zero") 1))))))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-make-array-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program)
      (match program
        [(IrProgram _ functions _)
          (and
            (> (lower-test-functions-call-count functions "tl_alloc") 1)
            (> (lower-test-functions-call-count functions "tl_oob_abort") 0))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-string-runtime-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program)
      (match program
        [(IrProgram _ functions _)
          (and
            (> (lower-test-functions-call-count functions "tl_substring") 0)
            (and
              (>
                (lower-test-functions-call-count functions "tl_string_concat")
                1)
              (and
                (> (lower-test-functions-call-count functions "tl_oob_abort") 0)
                (and
                  (= (lower-test-functions-call-count functions "substring") 0)
                  (and
                    (=
                      (lower-test-functions-call-count
                        functions
                        "string-append")
                      0)
                    (=
                      (lower-test-functions-call-count
                        functions
                        "string-concat")
                      0))))))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-string-shadow-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program)
      (match program
        [(IrProgram _ functions _)
          (and
            (> (lower-test-functions-call-count functions "string-length") 0)
            (and
              (> (lower-test-functions-call-count functions "string-append") 0)
              (and
                (> (lower-test-functions-call-count functions "string-ref") 0)
                (and
                  (> (lower-test-functions-call-count functions "char-at") 0)
                  (and
                    (=
                      (lower-test-functions-call-count
                        functions
                        "tl_string_concat")
                      0)
                    (=
                      (lower-test-functions-call-count functions "tl_oob_abort")
                      0))))))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-self-test) : i64
  (if (and
    (compiler-lower-ok-summary? (compiler-lower-smoke-source))
    (and
      (compiler-lower-ok? (compiler-lower-match-source))
      (and
        (compiler-lower-match-phi-shape-ok? (compiler-lower-match-source))
        (and
          (and
            (and
              (compiler-lower-ok? (compiler-lower-enum-match-source))
              (and
                (compiler-lower-ok?
                  (compiler-lower-enum-literal-payload-source))
                (compiler-lower-ok? (compiler-lower-enum-nested-payload-source))))
            (compiler-lower-error-ok?
              (compiler-lower-enum-string-literal-payload-source)
              "lower: unsupported enum payload literal pattern type"))
          (and
            (compiler-lower-enum-match-shape-ok?
              (compiler-lower-enum-match-source))
            (and
              (and
                (compiler-lower-ok? (compiler-lower-array-length-source))
                (and
                  (compiler-lower-ok? (compiler-lower-array-access-source))
                  (compiler-lower-make-array-shape-ok?
                    (compiler-lower-make-array-source))))
              (and
                (compiler-lower-ok? (compiler-lower-string-length-source))
                (and
                  (compiler-lower-ok? (compiler-lower-string-runtime-source))
                  (and
                    (compiler-lower-string-runtime-shape-ok?
                      (compiler-lower-string-runtime-source))
                    (and
                      (compiler-lower-string-shadow-shape-ok?
                        (compiler-lower-string-shadow-source))
                      (and
                        (compiler-lower-ok? (compiler-lower-stdio-source))
                        (and
                          (compiler-lower-ok? (compiler-lower-aggregate-source))
                          (and
                            (compiler-lower-error-ok?
                              (compiler-typecheck-branch-mismatch-source)
                              "typecheck: if branches must match")
                            (and
                              (compiler-lower-error-ok?
                                (compiler-lower-unsupported-source)
                                "lower: unsupported expression")
                              (compiler-lower-error-ok?
                                (compiler-lower-comptime-reserved-source)
                                "lower: comptime evaluation not yet implemented (#719)")))))))))))))))
    42
    (begin
      (panic "lower: smoke score mismatch")
      0)))