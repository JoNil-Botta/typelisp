;; compiler_typecheck.tl - First scalar typechecker pass over compiler AstProgram (#426).

(import "compiler_symbols.tl")

(defenum TcTypeEnv
  (TcTypeNil)
  (TcTypeBind String AstType TcTypeEnv))

(defenum ResultTcType
  (OkTcType AstType)
  (ErrTcType String))

(defenum ResultTcTypeList
  (OkTcTypeList AstTypeList)
  (ErrTcTypeList String))

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

(define (tc-type-list1 [a : AstType]) : AstTypeList
  (AstTypeCons a AstTypeNil))

(define (tc-type-list2 [a : AstType] [b : AstType]) : AstTypeList
  (AstTypeCons a (AstTypeCons b AstTypeNil)))

(define (tc-type-list3 [a : AstType] [b : AstType] [c : AstType]) : AstTypeList
  (AstTypeCons a (AstTypeCons b (AstTypeCons c AstTypeNil))))

(define (tc-fn0 [ret : AstType]) : AstType
  (AstTyFunc AstTypeNil ret))

(define (tc-fn1 [a : AstType] [ret : AstType]) : AstType
  (AstTyFunc (tc-type-list1 a) ret))

(define (tc-fn2 [a : AstType] [b : AstType] [ret : AstType]) : AstType
  (AstTyFunc (tc-type-list2 a b) ret))

(define (tc-fn3 [a : AstType] [b : AstType] [c : AstType] [ret : AstType]) : AstType
  (AstTyFunc (tc-type-list3 a b c) ret))

(define (tc-default-env) : TcTypeEnv
  (let ([e0 : TcTypeEnv (tc-empty-env)])
    (let ([e1 : TcTypeEnv (tc-bind e0 "print" (tc-fn1 (AstTyI64) (AstTyUnit)))])
      (let ([e2 : TcTypeEnv (tc-bind e1 "print-bool" (tc-fn1 (AstTyBool) (AstTyUnit)))])
        (let ([e3 : TcTypeEnv (tc-bind e2 "print-float" (tc-fn1 (AstTyF64) (AstTyUnit)))])
          (let ([e4 : TcTypeEnv (tc-bind e3 "print-char" (tc-fn1 (AstTyChar) (AstTyUnit)))])
            (let ([e5 : TcTypeEnv (tc-bind e4 "print-newline" (tc-fn0 (AstTyUnit)))])
              (let ([e6 : TcTypeEnv (tc-bind e5 "print-string" (tc-fn1 (AstTyString) (AstTyUnit)))])
                (let ([e7 : TcTypeEnv (tc-bind e6 "print-str" (tc-fn1 (AstTyString) (AstTyUnit)))])
                  (let ([e8 : TcTypeEnv (tc-bind e7 "print-error" (tc-fn1 (AstTyString) (AstTyUnit)))])
                    (let ([e9 : TcTypeEnv (tc-bind e8 "arg-count" (tc-fn0 (AstTyI64)))])
                      (let ([e10 : TcTypeEnv (tc-bind e9 "arg" (tc-fn1 (AstTyI64) (AstTyString)))])
                        (let ([e11 : TcTypeEnv (tc-bind e10 "string-length" (tc-fn1 (AstTyString) (AstTyI64)))])
                          (let ([e12 : TcTypeEnv (tc-bind e11 "length" (tc-fn1 (AstTyString) (AstTyI64)))])
                            (let ([e13 : TcTypeEnv (tc-bind e12 "string-eq" (tc-fn2 (AstTyString) (AstTyString) (AstTyBool)))])
                              (let ([e14 : TcTypeEnv (tc-bind e13 "string=?" (tc-fn2 (AstTyString) (AstTyString) (AstTyBool)))])
                                (let ([e15 : TcTypeEnv (tc-bind e14 "string->int" (tc-fn1 (AstTyString) (AstTyI64)))])
                                  (let ([e16 : TcTypeEnv (tc-bind e15 "int->string" (tc-fn1 (AstTyI64) (AstTyString)))])
                                    (let ([e17 : TcTypeEnv (tc-bind e16 "read-file" (tc-fn1 (AstTyString) (AstTyString)))])
                                      (let ([e18 : TcTypeEnv (tc-bind e17 "write-file" (tc-fn2 (AstTyString) (AstTyString) (AstTyUnit)))])
                                        (let ([e19 : TcTypeEnv (tc-bind e18 "file-exists?" (tc-fn1 (AstTyString) (AstTyBool)))])
                                          (let ([e20 : TcTypeEnv (tc-bind e19 "substring" (tc-fn3 (AstTyString) (AstTyI64) (AstTyI64) (AstTyString)))])
                                            (let ([e21 : TcTypeEnv (tc-bind e20 "string-slice" (tc-fn3 (AstTyString) (AstTyI64) (AstTyI64) (AstTyString)))])
                                              (let ([e22 : TcTypeEnv (tc-bind e21 "string-append" (tc-fn2 (AstTyString) (AstTyString) (AstTyString)))])
                                                (let ([e23 : TcTypeEnv (tc-bind e22 "string-concat" (tc-fn2 (AstTyString) (AstTyString) (AstTyString)))])
                                                  (let ([e24 : TcTypeEnv (tc-bind e23 "panic" (tc-fn1 (AstTyString) (AstTyNever)))])
                                                    (tc-bind e24 "error" (tc-fn1 (AstTyString) (AstTyNever)))))))))))))))))))))))))))))

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

(define (tc-castable-type? [ty : AstType]) : bool
  (if (tc-integer-type? ty)
      true
      (match ty
        [(AstTyChar) true]
        [_ false])))

(define (tc-dyn-array-elem-supported? [ty : AstType]) : bool
  (if (tc-integer-type? ty)
      true
      (match ty
        [(AstTyBool) true]
        [(AstTyChar) true]
        [(AstTyF64) true]
        [(AstTyString) true]
        [(AstTyEnum _) true]
        [(AstTyStruct _) true]
        [(AstTyDynArray _) true]
        [_ false])))

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

(define (tc-type-list-ref [types : AstTypeList] [index : i64]) : ResultTcType
  (if (< index 0)
      (ErrTcType "typecheck: tuple index out of bounds")
      (match types
        [(AstTypeNil) (ErrTcType "typecheck: tuple index out of bounds")]
        [(AstTypeCons ty rest)
         (if (= index 0)
             (OkTcType ty)
             (tc-type-list-ref rest (- index 1)))])))

(define (tc-expr-list-len [exprs : AstExprList]) : i64
  (match exprs
    [(AstExprNil) 0]
    [(AstExprCons _ rest) (+ 1 (tc-expr-list-len rest))]))

(define (tc-expr-list-types [env : TcTypeEnv] [exprs : AstExprList]) : ResultTcTypeList
  (match exprs
    [(AstExprNil) (OkTcTypeList AstTypeNil)]
    [(AstExprCons expr rest)
     (match (tc-expr env expr)
       [(OkTcType ty)
        (match (tc-expr-list-types env rest)
          [(OkTcTypeList rest-types) (OkTcTypeList (AstTypeCons ty rest-types))]
          [(ErrTcTypeList message) (ErrTcTypeList message)])]
       [(ErrTcType message) (ErrTcTypeList message)])]))

(define (tc-check-array-rest [env : TcTypeEnv] [exprs : AstExprList] [elem-ty : AstType]) : ResultTcUnit
  (match exprs
    [(AstExprNil) OkTcUnit]
    [(AstExprCons expr rest)
     (match (tc-expr env expr)
       [(OkTcType ty)
        (match (tc-expect ty elem-ty "typecheck: array elements must have same type")
          [(OkTcUnit) (tc-check-array-rest env rest elem-ty)]
          [(ErrTcUnit message) (ErrTcUnit message)])]
       [(ErrTcType message) (ErrTcUnit message)])]))

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
    [(AstProgram decls) (tc-build-top-env-list decls (tc-default-env))]))

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

(define (tc-call-expr [env : TcTypeEnv] [func : AstExpr] [args : AstExprList]) : ResultTcType
  (match (tc-expr env func)
    [(OkTcType fn-ty)
     (match fn-ty
       [(AstTyFunc params ret)
        (match (tc-check-args env args params)
          [(OkTcUnit) (OkTcType ret)]
          [(ErrTcUnit message) (ErrTcType message)])]
       [_ (ErrTcType "typecheck: call target is not a function")])]
    [(ErrTcType message) (ErrTcType message)]))

(define (tc-array-length-call [env : TcTypeEnv] [name : String] [func : AstExpr] [args : AstExprList]) : ResultTcType
  (match args
    [(AstExprCons arg rest)
     (match rest
       [(AstExprNil)
        (match (tc-expr env arg)
          [(OkTcType arg-ty)
           (match arg-ty
             [(AstTyDynArray _) (OkTcType (AstTyI64))]
             [_ (if (string-eq name "array-length")
                    (ErrTcType "typecheck: array-length requires dynamic array")
                    (tc-call-expr env func args))])]
          [(ErrTcType message) (ErrTcType message)])]
       [_ (if (string-eq name "array-length")
              (ErrTcType "typecheck: arity mismatch")
              (tc-call-expr env func args))])]
    [_ (if (string-eq name "array-length")
           (ErrTcType "typecheck: arity mismatch")
           (tc-call-expr env func args))]))

(define (tc-call-or-array-length [env : TcTypeEnv] [func : AstExpr] [args : AstExprList]) : ResultTcType
  (match func
    [(AstExprVar name)
     (if (or (string-eq name "array-length") (string-eq name "length"))
         (tc-array-length-call env name func args)
         (tc-call-expr env func args))]
    [_ (tc-call-expr env func args)]))

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
    [(AstExprLambda params maybe-ret body)
     (let ([lambda-env : TcTypeEnv (tc-bind-params env params)])
       (match (tc-expr lambda-env body)
         [(OkTcType body-ty)
          (match maybe-ret
            [(AstSomeType ret)
             (match (tc-expect body-ty ret "typecheck: lambda return type mismatch")
               [(OkTcUnit) (OkTcType (AstTyFunc (tc-param-type-list params) ret))]
               [(ErrTcUnit message) (ErrTcType message)])]
            [(AstNoType) (OkTcType (AstTyFunc (tc-param-type-list params) body-ty))])]
         [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprTuple exprs)
     (match (tc-expr-list-types env exprs)
       [(OkTcTypeList tys) (OkTcType (AstTyTuple tys))]
       [(ErrTcTypeList message) (ErrTcType message)])]
    [(AstExprTupleRef tuple index)
     (match (tc-expr env tuple)
       [(OkTcType tuple-ty)
        (match tuple-ty
          [(AstTyTuple tys) (tc-type-list-ref tys index)]
          [_ (ErrTcType "typecheck: tuple-ref requires tuple type")])]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprArray exprs)
     (match exprs
       [(AstExprNil) (ErrTcType "typecheck: cannot infer type of empty array")]
       [(AstExprCons first rest)
        (match (tc-expr env first)
          [(OkTcType first-ty)
           (match (tc-check-array-rest env rest first-ty)
             [(OkTcUnit) (OkTcType (AstTyArray first-ty (tc-expr-list-len exprs)))]
             [(ErrTcUnit message) (ErrTcType message)])]
          [(ErrTcType message) (ErrTcType message)])])]
    [(AstExprMakeArray elem-ty len)
     (match (tc-expr env len)
       [(OkTcType len-ty)
        (if (tc-integer-type? len-ty)
            (if (tc-dyn-array-elem-supported? elem-ty)
                (OkTcType (AstTyDynArray elem-ty))
                (ErrTcType "typecheck: make-array element type is not supported"))
            (ErrTcType "typecheck: make-array length must be integer"))]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprArrayRef array index)
     (match (tc-expr env array)
       [(OkTcType array-ty)
        (match (tc-expr env index)
          [(OkTcType index-ty)
           (if (tc-integer-type? index-ty)
               (match array-ty
                 [(AstTyArray elem-ty _) (OkTcType elem-ty)]
                 [(AstTyDynArray elem-ty) (OkTcType elem-ty)]
                 [_ (ErrTcType "typecheck: array-ref requires array type")])
               (ErrTcType "typecheck: array index must be integer"))]
          [(ErrTcType message) (ErrTcType message)])]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprArraySet array index value)
     (match (tc-expr env array)
       [(OkTcType array-ty)
        (match (tc-expr env index)
          [(OkTcType index-ty)
           (if (tc-integer-type? index-ty)
               (match array-ty
                 [(AstTyArray elem-ty _)
                  (match (tc-expr env value)
                    [(OkTcType value-ty)
                     (match (tc-expect value-ty elem-ty "typecheck: array-set! value type mismatch")
                       [(OkTcUnit) (OkTcType (AstTyUnit))]
                       [(ErrTcUnit message) (ErrTcType message)])]
                    [(ErrTcType message) (ErrTcType message)])]
                 [(AstTyDynArray elem-ty)
                  (match (tc-expr env value)
                    [(OkTcType value-ty)
                     (match (tc-expect value-ty elem-ty "typecheck: array-set! value type mismatch")
                       [(OkTcUnit) (OkTcType (AstTyUnit))]
                       [(ErrTcUnit message) (ErrTcType message)])]
                    [(ErrTcType message) (ErrTcType message)])]
                 [_ (ErrTcType "typecheck: array-set! requires array type")])
               (ErrTcType "typecheck: array index must be integer"))]
          [(ErrTcType message) (ErrTcType message)])]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprStringRef str index)
     (match (tc-expr env str)
       [(OkTcType str-ty)
        (match (tc-expect str-ty (AstTyString) "typecheck: string-ref requires String")
          [(OkTcUnit)
           (match (tc-expr env index)
             [(OkTcType index-ty)
              (if (tc-integer-type? index-ty)
                  (OkTcType (AstTyChar))
                  (ErrTcType "typecheck: string index must be integer"))]
             [(ErrTcType message) (ErrTcType message)])]
          [(ErrTcUnit message) (ErrTcType message)])]
       [(ErrTcType message) (ErrTcType message)])]
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
    [(AstExprCast inner ty)
     (match (tc-expr env inner)
       [(OkTcType inner-ty)
        (if (and (tc-castable-type? inner-ty) (tc-castable-type? ty))
            (OkTcType ty)
            (ErrTcType "typecheck: cast requires integer/char source and target"))]
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
    [(AstExprCall func args) (tc-call-or-array-length env func args)]
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
    [(AstExprForeach index index-ty start end body)
     (if (tc-integer-type? index-ty)
         (match (tc-expr env start)
           [(OkTcType start-ty)
            (if (tc-integer-type? start-ty)
                (match (tc-expr env end)
                  [(OkTcType end-ty)
                   (if (tc-integer-type? end-ty)
                       (let ([body-env : TcTypeEnv (tc-bind env index index-ty)])
                         (match (tc-expr body-env body)
                           [(OkTcType body-ty)
                            (match (tc-expect body-ty (AstTyUnit) "typecheck: foreach body must be unit")
                              [(OkTcUnit) (OkTcType (AstTyUnit))]
                              [(ErrTcUnit message) (ErrTcType message)])]
                           [(ErrTcType message) (ErrTcType message)]))
                       (ErrTcType "typecheck: foreach end expression must be integer"))]
                  [(ErrTcType message) (ErrTcType message)])
                (ErrTcType "typecheck: foreach start expression must be integer"))]
           [(ErrTcType message) (ErrTcType message)])
         (ErrTcType "typecheck: foreach index type must be integer"))]
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

(define (compiler-typecheck-ok-score? [src : String] [want : i64]) : bool
  (match (typecheck-compiler-source src)
    [(OkCompilerTypecheck summary) (= (compiler-typecheck-summary-score summary) want)]
    [(ErrCompilerTypecheck _) false]))

(define (compiler-typecheck-unbound-source) : String
  "(define (main) : i64 missing)")

(define (compiler-typecheck-bad-call-source) : String
  "(define (id [x : i64]) : i64 x)
(define (main) : i64 (id true))")

(define (compiler-typecheck-branch-mismatch-source) : String
  "(define (main [flag : bool]) : i64
  (if flag 1 false))")

(define (compiler-typecheck-aggregate-source) : String
  "(define (id-lambda [n : i64]) : i64
  (let ([f : (-> i64 i64) (lambda ([x : i64]) : i64 (+ x 1))])
    (f n)))
(define (main [n : i64] [s : String]) : i64
  (let ([fixed : (Array i64 3) (array 1 2 3)]
        [t : (Tuple i64 bool) (tuple 7 true)]
        [a : (Array i64) (make-array i64 n)])
    (begin
      (array-set! a 0 (cast (string-ref s 0) : i64))
      (foreach ([i : i64 0 n])
        (array-set! a i (+ (array-ref a i) 1)))
      (+ (array-length a)
         (+ (tuple-ref t 0) (+ (array-ref fixed 1) (id-lambda 3)))))))")

(define (compiler-typecheck-builtin-source) : String
  "(define (main [s : String]) : String
  (string-append (substring s 0 (length s))
                 (int->string (string->int \"7\"))))")

(define (compiler-typecheck-tuple-oob-source) : String
  "(define (main) : i64 (tuple-ref (tuple 1 true) 2))")

(define (compiler-typecheck-array-mismatch-source) : String
  "(define bad : (Array i64 2) (array 1 true))")

(define (compiler-typecheck-string-index-source) : String
  "(define (main) : char (string-ref \"hi\" true))")

(define (compiler-typecheck-cast-bad-source) : String
  "(define (main) : i64 (cast true : i64))")

(define (compiler-typecheck-foreach-body-source) : String
  "(define (main [n : i64]) : unit
  (foreach ([i : i64 0 n]) i))")

(define (compiler-typecheck-lambda-ret-source) : String
  "(define (main) : (-> i64 i64)
  (lambda ([x : i64]) : i64 true))")

(define (compiler-typecheck-aggregate-tests-ok?) : bool
  (and (compiler-typecheck-ok-score? (compiler-typecheck-aggregate-source) 20)
       (and (compiler-typecheck-ok-score? (compiler-typecheck-builtin-source) 10)
            (and (compiler-typecheck-error-ok?
                   (compiler-typecheck-tuple-oob-source)
                   "typecheck: tuple index out of bounds")
                 (and (compiler-typecheck-error-ok?
                        (compiler-typecheck-array-mismatch-source)
                        "typecheck: array elements must have same type")
                      (and (compiler-typecheck-error-ok?
                             (compiler-typecheck-string-index-source)
                             "typecheck: string index must be integer")
                           (and (compiler-typecheck-error-ok?
                                  (compiler-typecheck-cast-bad-source)
                                  "typecheck: cast requires integer/char source and target")
                                (and (compiler-typecheck-error-ok?
                                       (compiler-typecheck-foreach-body-source)
                                       "typecheck: foreach body must be unit")
                                     (compiler-typecheck-error-ok?
                                       (compiler-typecheck-lambda-ret-source)
                                       "typecheck: lambda return type mismatch")))))))))

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
                        (and (compiler-typecheck-error-ok?
                               (compiler-typecheck-branch-mismatch-source)
                               "typecheck: if branches must match")
                             (compiler-typecheck-aggregate-tests-ok?)))))
         42
         (begin
           (panic "typecheck: smoke score mismatch")
           0))]
    [(ErrCompilerTypecheck message)
     (begin
       (panic message)
       0)]))
