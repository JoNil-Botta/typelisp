;; compiler_typecheck.tl - First scalar typechecker pass over compiler AstProgram (#426).

(import "compiler_symbols.tl")

(defenum TcTypeEnv
  (TcTypeNil)
  (TcTypeBind String AstType TcTypeEnv))

(defenum ResultTcType
  (OkTcType AstType)
  (ErrTcType String))

(defenum ResultTcEnv
  (OkTcEnv TcTypeEnv)
  (ErrTcEnv String))

(defenum ResultTcUnit
  (OkTcUnit)
  (ErrTcUnit String))

(defenum CompilerTypecheckSummary
  (CompilerTypecheckSummary i64 i64 i64))

(defenum ResultCompilerTypecheck
  (OkCompilerTypecheck CompilerTypecheckSummary)
  (ErrCompilerTypecheck String))

(define (tc-empty-env) : TcTypeEnv
  TcTypeNil)

(define (tc-bind [env : TcTypeEnv] [name : String] [ty : AstType]) : TcTypeEnv
  (TcTypeBind name ty env))

(define (tc-lookup [env : TcTypeEnv] [name : String]) : ResultTcType
  (match env
    [(TcTypeNil) (ErrTcType (string-append "typecheck: unbound name " name))]
    [(TcTypeBind key ty rest)
     (if (string-eq key name)
         (OkTcType ty)
         (tc-lookup rest name))]))

(define (tc-type-list-eq [a : AstTypeList] [b : AstTypeList]) : bool
  (match a
    [(AstTypeNil)
     (match b
       [(AstTypeNil) true]
       [_ false])]
    [(AstTypeCons ah at)
     (match b
       [(AstTypeCons bh bt)
        (and (tc-type-eq ah bh) (tc-type-list-eq at bt))]
       [_ false])]))

(define (tc-type-eq [a : AstType] [b : AstType]) : bool
  (match a
    [(AstTyI64) (match b [(AstTyI64) true] [_ false])]
    [(AstTyI32) (match b [(AstTyI32) true] [_ false])]
    [(AstTyI16) (match b [(AstTyI16) true] [_ false])]
    [(AstTyI8) (match b [(AstTyI8) true] [_ false])]
    [(AstTyU64) (match b [(AstTyU64) true] [_ false])]
    [(AstTyU32) (match b [(AstTyU32) true] [_ false])]
    [(AstTyU16) (match b [(AstTyU16) true] [_ false])]
    [(AstTyU8) (match b [(AstTyU8) true] [_ false])]
    [(AstTyF64) (match b [(AstTyF64) true] [_ false])]
    [(AstTyF32) (match b [(AstTyF32) true] [_ false])]
    [(AstTyBool) (match b [(AstTyBool) true] [_ false])]
    [(AstTyChar) (match b [(AstTyChar) true] [_ false])]
    [(AstTyString) (match b [(AstTyString) true] [_ false])]
    [(AstTyUnit) (match b [(AstTyUnit) true] [_ false])]
    [(AstTyNever) (match b [(AstTyNever) true] [_ false])]
    [(AstTyFunc a-args a-ret)
     (match b
       [(AstTyFunc b-args b-ret)
        (and (tc-type-list-eq a-args b-args) (tc-type-eq a-ret b-ret))]
       [_ false])]
    [(AstTyTuple a-elems)
     (match b
       [(AstTyTuple b-elems) (tc-type-list-eq a-elems b-elems)]
       [_ false])]
    [(AstTyArray a-elem a-len)
     (match b
       [(AstTyArray b-elem b-len)
        (and (= a-len b-len) (tc-type-eq a-elem b-elem))]
       [_ false])]
    [(AstTyDynArray a-elem)
     (match b
       [(AstTyDynArray b-elem) (tc-type-eq a-elem b-elem)]
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

(define (tc-integer-type? [ty : AstType]) : bool
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

(define (tc-literal-type [lit : AstLiteral]) : AstType
  (match lit
    [(AstLitInt _) (AstTyI64)]
    [(AstLitFloat _) (AstTyF64)]
    [(AstLitBool _) (AstTyBool)]
    [(AstLitChar _) (AstTyChar)]
    [(AstLitString _) (AstTyString)]
    [(AstLitUnit) (AstTyUnit)]))

(define (tc-param-type-list [params : AstParamList]) : AstTypeList
  (match params
    [(AstParamNil) AstTypeNil]
    [(AstParamCons param rest)
     (match param
       [(AstParam _ ty) (AstTypeCons ty (tc-param-type-list rest))])]))

(define (tc-bind-params [env : TcTypeEnv] [params : AstParamList]) : TcTypeEnv
  (match params
    [(AstParamNil) env]
    [(AstParamCons param rest)
     (match param
       [(AstParam name ty) (tc-bind-params (tc-bind env name ty) rest)])]))

(define (tc-top-decl-type [decl : AstDecl]) : ResultTcType
  (match decl
    [(AstDeclDef _ maybe-ty expr)
     (match maybe-ty
       [(AstSomeType ty) (OkTcType ty)]
       [(AstNoType)
        (match expr
          [(AstExprLiteral lit) (OkTcType (tc-literal-type lit))]
          [(AstExprAnn _ ty) (OkTcType ty)]
          [_ (ErrTcType "typecheck: top-level value requires annotation")])])]
    [(AstDeclDefFn _ params ret _) (OkTcType (AstTyFunc (tc-param-type-list params) ret))]
    [(AstDeclExtern _ ty) (OkTcType ty)]
    [_ (ErrTcType "typecheck: declaration has no value type")]))

(define (tc-build-top-env-list [decls : AstDeclList] [env : TcTypeEnv]) : ResultTcEnv
  (match decls
    [(AstDeclNil) (OkTcEnv env)]
    [(AstDeclCons decl rest)
     (match decl
       [(AstDeclDef name _ _)
        (match (tc-top-decl-type decl)
          [(OkTcType ty) (tc-build-top-env-list rest (tc-bind env name ty))]
          [(ErrTcType message) (ErrTcEnv message)])]
       [(AstDeclDefFn name _ _ _)
        (match (tc-top-decl-type decl)
          [(OkTcType ty) (tc-build-top-env-list rest (tc-bind env name ty))]
          [(ErrTcType message) (ErrTcEnv message)])]
       [(AstDeclExtern name _)
        (match (tc-top-decl-type decl)
          [(OkTcType ty) (tc-build-top-env-list rest (tc-bind env name ty))]
          [(ErrTcType message) (ErrTcEnv message)])]
       [_ (tc-build-top-env-list rest env)])]))

(define (tc-build-top-env [program : AstProgram]) : ResultTcEnv
  (match program
    [(AstProgram decls) (tc-build-top-env-list decls (tc-empty-env))]))

(define (tc-expect [actual : AstType] [expected : AstType] [message : String]) : ResultTcUnit
  (if (tc-type-eq actual expected)
      OkTcUnit
      (ErrTcUnit message)))

(define (tc-binop-type [op : AstBinOp] [left : AstType] [right : AstType]) : ResultTcType
  (match op
    [(AstBinAnd)
     (if (and (tc-type-eq left (AstTyBool)) (tc-type-eq right (AstTyBool)))
         (OkTcType (AstTyBool))
         (ErrTcType "typecheck: boolean operator expects bool operands"))]
    [(AstBinOr)
     (if (and (tc-type-eq left (AstTyBool)) (tc-type-eq right (AstTyBool)))
         (OkTcType (AstTyBool))
         (ErrTcType "typecheck: boolean operator expects bool operands"))]
    [(AstBinEq)
     (if (tc-type-eq left right)
         (OkTcType (AstTyBool))
         (ErrTcType "typecheck: equality operands must match"))]
    [(AstBinNe)
     (if (tc-type-eq left right)
         (OkTcType (AstTyBool))
         (ErrTcType "typecheck: equality operands must match"))]
    [(AstBinLt) (tc-compare-binop-type left right)]
    [(AstBinLe) (tc-compare-binop-type left right)]
    [(AstBinGt) (tc-compare-binop-type left right)]
    [(AstBinGe) (tc-compare-binop-type left right)]
    [_ (tc-integer-binop-type left right)]))

(define (tc-integer-binop-type [left : AstType] [right : AstType]) : ResultTcType
  (if (and (tc-integer-type? left) (tc-type-eq left right))
      (OkTcType left)
      (ErrTcType "typecheck: integer operator expects matching integer operands")))

(define (tc-compare-binop-type [left : AstType] [right : AstType]) : ResultTcType
  (if (and (tc-integer-type? left) (tc-type-eq left right))
      (OkTcType (AstTyBool))
      (ErrTcType "typecheck: comparison expects matching integer operands")))

(define (tc-unop-type [op : AstUnOp] [ty : AstType]) : ResultTcType
  (match op
    [(AstUnNot)
     (if (tc-type-eq ty (AstTyBool))
         (OkTcType (AstTyBool))
         (ErrTcType "typecheck: not expects bool"))]
    [(AstUnNeg)
     (if (tc-integer-type? ty)
         (OkTcType ty)
         (ErrTcType "typecheck: neg expects integer"))]
    [(AstUnBitNot)
     (if (tc-integer-type? ty)
         (OkTcType ty)
         (ErrTcType "typecheck: bit-not expects integer"))]))

(define (tc-check-args [env : TcTypeEnv] [args : AstExprList] [params : AstTypeList]) : ResultTcUnit
  (match args
    [(AstExprNil)
     (match params
       [(AstTypeNil) OkTcUnit]
       [_ (ErrTcUnit "typecheck: arity mismatch")])]
    [(AstExprCons arg rest-args)
     (match params
       [(AstTypeCons want rest-params)
        (match (tc-expr env arg)
          [(OkTcType got)
           (match (tc-expect got want "typecheck: argument type mismatch")
             [(OkTcUnit) (tc-check-args env rest-args rest-params)]
             [(ErrTcUnit message) (ErrTcUnit message)])]
          [(ErrTcType message) (ErrTcUnit message)])]
       [(AstTypeNil) (ErrTcUnit "typecheck: arity mismatch")])]))

(define (tc-let-bindings [env : TcTypeEnv] [bindings : AstLetBindingList]) : ResultTcEnv
  (match bindings
    [(AstLetBindingNil) (OkTcEnv env)]
    [(AstLetBindingCons binding rest)
     (match binding
       [(AstLetBinding name maybe-ty init)
        (match (tc-expr env init)
          [(OkTcType init-ty)
           (match maybe-ty
             [(AstSomeType want)
              (match (tc-expect init-ty want "typecheck: let binding type mismatch")
                [(OkTcUnit) (tc-let-bindings (tc-bind env name want) rest)]
                [(ErrTcUnit message) (ErrTcEnv message)])]
             [(AstNoType) (tc-let-bindings (tc-bind env name init-ty) rest)])]
          [(ErrTcType message) (ErrTcEnv message)])])]))

(define (tc-begin-list [env : TcTypeEnv] [exprs : AstExprList]) : ResultTcType
  (match exprs
    [(AstExprNil) (OkTcType (AstTyUnit))]
    [(AstExprCons expr rest)
     (match rest
       [(AstExprNil) (tc-expr env expr)]
       [_ (match (tc-expr env expr)
            [(OkTcType _) (tc-begin-list env rest)]
            [(ErrTcType message) (ErrTcType message)])])]))

(define (tc-expr [env : TcTypeEnv] [expr : AstExpr]) : ResultTcType
  (match expr
    [(AstExprSpanned inner _) (tc-expr env inner)]
    [(AstExprLiteral lit) (OkTcType (tc-literal-type lit))]
    [(AstExprVar name) (tc-lookup env name)]
    [(AstExprAnn inner ty)
     (match (tc-expr env inner)
       [(OkTcType got)
        (match (tc-expect got ty "typecheck: annotation type mismatch")
          [(OkTcUnit) (OkTcType ty)]
          [(ErrTcUnit message) (ErrTcType message)])]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprLet bindings body)
     (match (tc-let-bindings env bindings)
       [(OkTcEnv next-env) (tc-expr next-env body)]
       [(ErrTcEnv message) (ErrTcType message)])]
    [(AstExprBegin exprs) (tc-begin-list env exprs)]
    [(AstExprIf cond then-branch else-branch)
     (match (tc-expr env cond)
       [(OkTcType cond-ty)
        (match (tc-expect cond-ty (AstTyBool) "typecheck: if condition must be bool")
          [(OkTcUnit)
           (match (tc-expr env then-branch)
             [(OkTcType then-ty)
              (match (tc-expr env else-branch)
                [(OkTcType else-ty)
                 (if (tc-type-eq then-ty else-ty)
                     (OkTcType then-ty)
                     (ErrTcType "typecheck: if branches must match"))]
                [(ErrTcType message) (ErrTcType message)])]
             [(ErrTcType message) (ErrTcType message)])]
          [(ErrTcUnit message) (ErrTcType message)])]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprSet name value)
     (match (tc-lookup env name)
       [(OkTcType var-ty)
        (match (tc-expr env value)
          [(OkTcType value-ty)
           (match (tc-expect value-ty var-ty "typecheck: assignment type mismatch")
             [(OkTcUnit) (OkTcType (AstTyUnit))]
             [(ErrTcUnit message) (ErrTcType message)])]
          [(ErrTcType message) (ErrTcType message)])]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprUnary op inner)
     (match (tc-expr env inner)
       [(OkTcType ty) (tc-unop-type op ty)]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprBinary op left right)
     (match (tc-expr env left)
       [(OkTcType left-ty)
        (match (tc-expr env right)
          [(OkTcType right-ty) (tc-binop-type op left-ty right-ty)]
          [(ErrTcType message) (ErrTcType message)])]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprCall func args)
     (match func
       [(AstExprVar name)
        (match (tc-lookup env name)
          [(OkTcType fn-ty)
           (match fn-ty
             [(AstTyFunc params ret)
              (match (tc-check-args env args params)
                [(OkTcUnit) (OkTcType ret)]
                [(ErrTcUnit message) (ErrTcType message)])]
             [_ (ErrTcType "typecheck: call target is not a function")])]
          [(ErrTcType message) (ErrTcType message)])]
       [_ (ErrTcType "typecheck: direct call target must be a name")])]
    [(AstExprWhile cond body)
     (match (tc-expr env cond)
       [(OkTcType cond-ty)
        (match (tc-expect cond-ty (AstTyBool) "typecheck: while condition must be bool")
          [(OkTcUnit)
           (match (tc-expr env body)
             [(OkTcType body-ty)
              (match (tc-expect body-ty (AstTyUnit) "typecheck: while body must be unit")
                [(OkTcUnit) (OkTcType (AstTyUnit))]
                [(ErrTcUnit message) (ErrTcType message)])]
             [(ErrTcType message) (ErrTcType message)])]
          [(ErrTcUnit message) (ErrTcType message)])]
       [(ErrTcType message) (ErrTcType message)])]
    [_ (ErrTcType "typecheck: unsupported expression")]))

(define (tc-summary-add-decl [summary : CompilerTypecheckSummary] [decl : AstDecl]) : CompilerTypecheckSummary
  (match summary
    [(CompilerTypecheckSummary values functions externs)
     (match decl
       [(AstDeclDef _ _ _) (CompilerTypecheckSummary (+ values 1) functions externs)]
       [(AstDeclDefFn _ _ _ _) (CompilerTypecheckSummary values (+ functions 1) externs)]
       [(AstDeclExtern _ _) (CompilerTypecheckSummary values functions (+ externs 1))]
       [_ summary])]))

(define (tc-check-decl [top-env : TcTypeEnv] [decl : AstDecl]) : ResultTcUnit
  (match decl
    [(AstDeclDef _ maybe-ty expr)
     (match maybe-ty
       [(AstSomeType want)
        (match (tc-expr top-env expr)
          [(OkTcType got)
           (match (tc-expect got want "typecheck: value definition type mismatch")
             [(OkTcUnit) OkTcUnit]
             [(ErrTcUnit message) (ErrTcUnit message)])]
          [(ErrTcType message) (ErrTcUnit message)])]
       [(AstNoType)
        (match (tc-expr top-env expr)
          [(OkTcType _) OkTcUnit]
          [(ErrTcType message) (ErrTcUnit message)])])]
    [(AstDeclDefFn _ params ret body)
     (let ([env : TcTypeEnv (tc-bind-params top-env params)])
       (match (tc-expr env body)
         [(OkTcType got)
          (match (tc-expect got ret "typecheck: return type mismatch")
            [(OkTcUnit) OkTcUnit]
            [(ErrTcUnit message) (ErrTcUnit message)])]
         [(ErrTcType message) (ErrTcUnit message)]))]
    [(AstDeclExtern _ ty)
     (match ty
       [(AstTyFunc _ _) OkTcUnit]
       [_ (ErrTcUnit "typecheck: extern must have function type")])]
    [_ OkTcUnit]))

(define (tc-check-decls [top-env : TcTypeEnv] [decls : AstDeclList] [summary : CompilerTypecheckSummary]) : ResultCompilerTypecheck
  (match decls
    [(AstDeclNil) (OkCompilerTypecheck summary)]
    [(AstDeclCons decl rest)
     (match (tc-check-decl top-env decl)
       [(OkTcUnit)
        (tc-check-decls top-env rest (tc-summary-add-decl summary decl))]
       [(ErrTcUnit message) (ErrCompilerTypecheck message)])]))

(define (typecheck-compiler-program [program : AstProgram]) : ResultCompilerTypecheck
  (match (build-compiler-symbols program)
    [(OkCompilerSymbols _)
     (match (tc-build-top-env program)
       [(OkTcEnv top-env)
        (match program
          [(AstProgram decls)
           (tc-check-decls top-env decls (CompilerTypecheckSummary 0 0 0))])]
       [(ErrTcEnv message) (ErrCompilerTypecheck message)])]
    [(ErrCompilerSymbols message) (ErrCompilerTypecheck message)]))

(define (typecheck-compiler-source [src : String]) : ResultCompilerTypecheck
  (match (parse-ast-source src)
    [(OkAstProgram program) (typecheck-compiler-program program)]
    [(ErrAstProgram message) (ErrCompilerTypecheck message)]))

(define (compiler-typecheck-smoke-source) : String
  "(extern print-i64 : (-> i64 unit))
(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x 1))
(define (main [flag : bool]) : i64
  (let ([x : i64 (inc answer)])
    (begin
      (set! x (+ x 1))
      (if flag x 0))))")

(define (compiler-typecheck-summary-score [summary : CompilerTypecheckSummary]) : i64
  (match summary
    [(CompilerTypecheckSummary values functions externs)
     (+ values (+ (* functions 10) (* externs 100)))]))

(define (compiler-typecheck-error-ok? [src : String] [want : String]) : bool
  (match (typecheck-compiler-source src)
    [(ErrCompilerTypecheck message) (string-eq message want)]
    [(OkCompilerTypecheck _) false]))

(define (compiler-typecheck-unbound-source) : String
  "(define (main) : i64 missing)")

(define (compiler-typecheck-bad-call-source) : String
  "(define (id [x : i64]) : i64 x)
(define (main) : i64 (id true))")

(define (compiler-typecheck-branch-mismatch-source) : String
  "(define (main [flag : bool]) : i64
  (if flag 1 false))")

(define (compiler-typecheck-self-test) : i64
  (match (typecheck-compiler-source (compiler-typecheck-smoke-source))
    [(OkCompilerTypecheck summary)
     (if (and (= (compiler-typecheck-summary-score summary) 121)
              (and (compiler-typecheck-error-ok?
                     (compiler-typecheck-unbound-source)
                     "typecheck: unbound name missing")
                   (and (compiler-typecheck-error-ok?
                          (compiler-typecheck-bad-call-source)
                          "typecheck: argument type mismatch")
                        (compiler-typecheck-error-ok?
                          (compiler-typecheck-branch-mismatch-source)
                          "typecheck: if branches must match"))))
         42
         (begin
           (panic "typecheck: smoke score mismatch")
           0))]
    [(ErrCompilerTypecheck message)
     (begin
       (panic message)
       0)]))
