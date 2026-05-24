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

(defenum ResultTcPattern
  (OkTcPattern TcTypeEnv bool)
  (ErrTcPattern String))

(defenum ResultTcArm
  (OkTcArm AstType bool)
  (ErrTcArm String))

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

(defstruct TcContext
  (program AstProgram)
  (symbols CompilerSymbols)
  (registries CompilerRegistries))

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

(define (tc-resolve-type-list [ctx : TcContext] [types : AstTypeList]) : ResultTcTypeList
  (match types
    [(AstTypeNil) (OkTcTypeList AstTypeNil)]
    [(AstTypeCons ty rest)
     (match (tc-resolve-type ctx ty)
       [(OkTcType resolved-ty)
        (match (tc-resolve-type-list ctx rest)
          [(OkTcTypeList resolved-rest)
           (OkTcTypeList (AstTypeCons resolved-ty resolved-rest))]
          [(ErrTcTypeList message) (ErrTcTypeList message)])]
       [(ErrTcType message) (ErrTcTypeList message)])]))

(define (tc-resolve-type [ctx : TcContext] [ty : AstType]) : ResultTcType
  (match ty
    [(AstTyFunc args ret)
     (match (tc-resolve-type-list ctx args)
       [(OkTcTypeList resolved-args)
        (match (tc-resolve-type ctx ret)
          [(OkTcType resolved-ret) (OkTcType (AstTyFunc resolved-args resolved-ret))]
          [(ErrTcType message) (ErrTcType message)])]
       [(ErrTcTypeList message) (ErrTcType message)])]
    [(AstTyTuple elems)
     (match (tc-resolve-type-list ctx elems)
       [(OkTcTypeList resolved-elems) (OkTcType (AstTyTuple resolved-elems))]
       [(ErrTcTypeList message) (ErrTcType message)])]
    [(AstTyArray elem len)
     (match (tc-resolve-type ctx elem)
       [(OkTcType resolved-elem) (OkTcType (AstTyArray resolved-elem len))]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstTyDynArray elem)
     (match (tc-resolve-type ctx elem)
       [(OkTcType resolved-elem) (OkTcType (AstTyDynArray resolved-elem))]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstTyVar name)
     (match (compiler-symbols-lookup-type (struct-get ctx symbols) name)
       [(SomeI64 handle)
        (if (= (compiler-symbol-handle-kind handle) (compiler-symbol-kind-defenum))
            (OkTcType (AstTyEnum name))
            (if (= (compiler-symbol-handle-kind handle) (compiler-symbol-kind-defstruct))
                (OkTcType (AstTyStruct name))
                (ErrTcType "typecheck: unknown nominal type")))]
       [(NoneI64) (ErrTcType (string-append "typecheck: unknown type " name))])]
    [_ (OkTcType ty)]))

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

(define (tc-field-type-list [fields : AstFieldDefList]) : AstTypeList
  (match fields
    [(AstFieldDefNil) AstTypeNil]
    [(AstFieldDefCons field rest)
     (match field
       [(AstFieldDef _ ty) (AstTypeCons ty (tc-field-type-list rest))])]))

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

(define (tc-expr-list-types [ctx : TcContext] [env : TcTypeEnv] [exprs : AstExprList]) : ResultTcTypeList
  (match exprs
    [(AstExprNil) (OkTcTypeList AstTypeNil)]
    [(AstExprCons expr rest)
     (match (tc-expr ctx env expr)
       [(OkTcType ty)
        (match (tc-expr-list-types ctx env rest)
          [(OkTcTypeList rest-types) (OkTcTypeList (AstTypeCons ty rest-types))]
          [(ErrTcTypeList message) (ErrTcTypeList message)])]
       [(ErrTcType message) (ErrTcTypeList message)])]))

(define (tc-check-array-rest [ctx : TcContext] [env : TcTypeEnv] [exprs : AstExprList] [elem-ty : AstType]) : ResultTcUnit
  (match exprs
    [(AstExprNil) OkTcUnit]
    [(AstExprCons expr rest)
     (match (tc-expr ctx env expr)
       [(OkTcType ty)
        (match (tc-expect ty elem-ty "typecheck: array elements must have same type")
          [(OkTcUnit) (tc-check-array-rest ctx env rest elem-ty)]
          [(ErrTcUnit message) (ErrTcUnit message)])]
       [(ErrTcType message) (ErrTcUnit message)])]))

(define (tc-bind-param-types [env : TcTypeEnv] [params : AstParamList] [types : AstTypeList]) : TcTypeEnv
  (match params
    [(AstParamNil) env]
    [(AstParamCons param rest)
     (match param
       [(AstParam name _)
        (match types
          [(AstTypeCons ty rest-types)
           (tc-bind-param-types (tc-bind env name ty) rest rest-types)]
          [(AstTypeNil) env])])]))

(define (tc-bind-params [ctx : TcContext] [env : TcTypeEnv] [params : AstParamList]) : ResultTcEnv
  (match (tc-resolve-type-list ctx (tc-param-type-list params))
    [(OkTcTypeList types) (OkTcEnv (tc-bind-param-types env params types))]
    [(ErrTcTypeList message) (ErrTcEnv message)]))

(define (tc-top-decl-type [ctx : TcContext] [decl : AstDecl]) : ResultTcType
  (match decl
    [(AstDeclDef _ maybe-ty expr)
     (match maybe-ty
       [(AstSomeType ty) (tc-resolve-type ctx ty)]
       [(AstNoType)
        (match expr
          [(AstExprLiteral lit) (OkTcType (tc-literal-type lit))]
          [(AstExprAnn _ ty) (tc-resolve-type ctx ty)]
          [_ (ErrTcType "typecheck: top-level value requires annotation")])])]
    [(AstDeclDefFn _ params ret _)
     (match (tc-resolve-type-list ctx (tc-param-type-list params))
       [(OkTcTypeList param-types)
        (match (tc-resolve-type ctx ret)
          [(OkTcType resolved-ret) (OkTcType (AstTyFunc param-types resolved-ret))]
          [(ErrTcType message) (ErrTcType message)])]
       [(ErrTcTypeList message) (ErrTcType message)])]
    [(AstDeclExtern _ ty) (tc-resolve-type ctx ty)]
    [_ (ErrTcType "typecheck: declaration has no value type")]))

(define (tc-bind-enum-constructors [ctx : TcContext] [enum-name : String] [variants : AstVariantDefList] [env : TcTypeEnv]) : ResultTcEnv
  (match variants
    [(AstVariantDefNil) (OkTcEnv env)]
    [(AstVariantDefCons variant rest)
     (match variant
       [(AstVariantDef variant-name fields)
        (match (tc-resolve-type-list ctx fields)
          [(OkTcTypeList field-types)
           (let ([ctor-ty : AstType
                  (match field-types
                    [(AstTypeNil) (AstTyEnum enum-name)]
                    [_ (AstTyFunc field-types (AstTyEnum enum-name))])])
             (tc-bind-enum-constructors
               ctx
               enum-name
               rest
               (tc-bind env variant-name ctor-ty)))]
          [(ErrTcTypeList message) (ErrTcEnv message)])])]))

(define (tc-bind-struct-constructor [ctx : TcContext] [struct-name : String] [fields : AstFieldDefList] [env : TcTypeEnv]) : ResultTcEnv
  (match (tc-resolve-type-list ctx (tc-field-type-list fields))
    [(OkTcTypeList field-types)
     (OkTcEnv (tc-bind env struct-name (AstTyFunc field-types (AstTyStruct struct-name))))]
    [(ErrTcTypeList message) (ErrTcEnv message)]))

(define (tc-build-top-env-list [ctx : TcContext] [decls : AstDeclList] [env : TcTypeEnv]) : ResultTcEnv
  (match decls
    [(AstDeclNil) (OkTcEnv env)]
    [(AstDeclCons decl rest)
     (match decl
       [(AstDeclDef name _ _)
        (match (tc-top-decl-type ctx decl)
          [(OkTcType ty) (tc-build-top-env-list ctx rest (tc-bind env name ty))]
          [(ErrTcType message) (ErrTcEnv message)])]
       [(AstDeclDefFn name _ _ _)
        (match (tc-top-decl-type ctx decl)
          [(OkTcType ty) (tc-build-top-env-list ctx rest (tc-bind env name ty))]
          [(ErrTcType message) (ErrTcEnv message)])]
       [(AstDeclExtern name _)
        (match (tc-top-decl-type ctx decl)
          [(OkTcType ty) (tc-build-top-env-list ctx rest (tc-bind env name ty))]
          [(ErrTcType message) (ErrTcEnv message)])]
       [(AstDeclDefEnum name variants)
        (match (tc-bind-enum-constructors ctx name variants env)
          [(OkTcEnv next-env) (tc-build-top-env-list ctx rest next-env)]
          [(ErrTcEnv message) (ErrTcEnv message)])]
       [(AstDeclDefStruct name fields)
        (match (tc-bind-struct-constructor ctx name fields env)
          [(OkTcEnv next-env) (tc-build-top-env-list ctx rest next-env)]
          [(ErrTcEnv message) (ErrTcEnv message)])]
       [_ (tc-build-top-env-list ctx rest env)])]))

(define (tc-build-top-env [ctx : TcContext]) : ResultTcEnv
  (match (struct-get ctx program)
    [(AstProgram decls) (tc-build-top-env-list ctx decls (tc-default-env))]))

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

(define (tc-check-args [ctx : TcContext] [env : TcTypeEnv] [args : AstExprList] [params : AstTypeList]) : ResultTcUnit
  (match args
    [(AstExprNil)
     (match params
       [(AstTypeNil) OkTcUnit]
       [_ (ErrTcUnit "typecheck: arity mismatch")])]
    [(AstExprCons arg rest-args)
     (match params
       [(AstTypeCons want rest-params)
        (match (tc-expr ctx env arg)
          [(OkTcType got)
           (match (tc-expect got want "typecheck: argument type mismatch")
             [(OkTcUnit) (tc-check-args ctx env rest-args rest-params)]
             [(ErrTcUnit message) (ErrTcUnit message)])]
          [(ErrTcType message) (ErrTcUnit message)])]
       [(AstTypeNil) (ErrTcUnit "typecheck: arity mismatch")])]))

(define (tc-call-expr [ctx : TcContext] [env : TcTypeEnv] [func : AstExpr] [args : AstExprList]) : ResultTcType
  (match (tc-expr ctx env func)
    [(OkTcType fn-ty)
     (match fn-ty
       [(AstTyFunc params ret)
        (match (tc-check-args ctx env args params)
          [(OkTcUnit) (OkTcType ret)]
          [(ErrTcUnit message) (ErrTcType message)])]
       [(AstTyEnum _)
        (match args
          [(AstExprNil) (OkTcType fn-ty)]
          [_ (ErrTcType "typecheck: arity mismatch")])]
       [_ (ErrTcType "typecheck: call target is not a function")])]
    [(ErrTcType message) (ErrTcType message)]))

(define (tc-array-length-call [ctx : TcContext] [env : TcTypeEnv] [name : String] [func : AstExpr] [args : AstExprList]) : ResultTcType
  (match args
    [(AstExprCons arg rest)
     (match rest
       [(AstExprNil)
        (match (tc-expr ctx env arg)
          [(OkTcType arg-ty)
           (match arg-ty
             [(AstTyDynArray _) (OkTcType (AstTyI64))]
             [_ (if (string-eq name "array-length")
                    (ErrTcType "typecheck: array-length requires dynamic array")
                    (tc-call-expr ctx env func args))])]
          [(ErrTcType message) (ErrTcType message)])]
       [_ (if (string-eq name "array-length")
              (ErrTcType "typecheck: arity mismatch")
              (tc-call-expr ctx env func args))])]
    [_ (if (string-eq name "array-length")
           (ErrTcType "typecheck: arity mismatch")
           (tc-call-expr ctx env func args))]))

(define (tc-call-or-array-length [ctx : TcContext] [env : TcTypeEnv] [func : AstExpr] [args : AstExprList]) : ResultTcType
  (match func
    [(AstExprVar name)
     (if (or (string-eq name "array-length") (string-eq name "length"))
         (tc-array-length-call ctx env name func args)
         (tc-call-expr ctx env func args))]
    [_ (tc-call-expr ctx env func args)]))

(define (tc-let-bindings [ctx : TcContext] [env : TcTypeEnv] [bindings : AstLetBindingList]) : ResultTcEnv
  (match bindings
    [(AstLetBindingNil) (OkTcEnv env)]
    [(AstLetBindingCons binding rest)
     (match binding
       [(AstLetBinding name maybe-ty init)
        (match (tc-expr ctx env init)
          [(OkTcType init-ty)
           (match maybe-ty
             [(AstSomeType want)
              (match (tc-resolve-type ctx want)
                [(OkTcType resolved-want)
                 (match (tc-expect init-ty resolved-want "typecheck: let binding type mismatch")
                   [(OkTcUnit) (tc-let-bindings ctx (tc-bind env name resolved-want) rest)]
                   [(ErrTcUnit message) (ErrTcEnv message)])]
                [(ErrTcType message) (ErrTcEnv message)])]
             [(AstNoType) (tc-let-bindings ctx (tc-bind env name init-ty) rest)])]
          [(ErrTcType message) (ErrTcEnv message)])])]))

(define (tc-begin-list [ctx : TcContext] [env : TcTypeEnv] [exprs : AstExprList]) : ResultTcType
  (match exprs
    [(AstExprNil) (OkTcType (AstTyUnit))]
    [(AstExprCons expr rest)
     (match rest
       [(AstExprNil) (tc-expr ctx env expr)]
       [_ (match (tc-expr ctx env expr)
            [(OkTcType _) (tc-begin-list ctx env rest)]
            [(ErrTcType message) (ErrTcType message)])])]))

(define (tc-literal-pattern-compatible? [lit : AstLiteral] [ty : AstType]) : bool
  (match lit
    [(AstLitInt _) (tc-integer-type? ty)]
    [_ (tc-type-eq (tc-literal-type lit) ty)]))

(define (tc-variant-belongs-to? [ctx : TcContext] [enum-name : String] [handle : i64]) : bool
  (match (compiler-program-decl-at-index
           (struct-get ctx program)
           (compiler-registry-handle-owner-index handle))
    [(OkAstDecl decl)
     (match decl
       [(AstDeclDefEnum owner-name _) (string-eq owner-name enum-name)]
       [_ false])]
    [(ErrAstDecl _) false]))

(define (tc-variant-field-types [ctx : TcContext] [handle : i64]) : ResultTcTypeList
  (match (compiler-registries-variant-fields (struct-get ctx program) handle)
    [(OkAstTypeList fields) (tc-resolve-type-list ctx fields)]
    [(ErrAstTypeList message) (ErrTcTypeList message)]))

(define (tc-struct-field-type [ctx : TcContext] [struct-name : String] [field-name : String]) : ResultTcType
  (match (compiler-registries-lookup-struct-field
           (struct-get ctx registries)
           struct-name
           field-name)
    [(SomeI64 handle)
     (match (compiler-registries-struct-field-type (struct-get ctx program) handle)
       [(OkAstType ty) (tc-resolve-type ctx ty)]
       [(ErrAstType message) (ErrTcType message)])]
    [(NoneI64) (ErrTcType "typecheck: struct field not found")]))

(define (tc-check-pattern-list [ctx : TcContext] [env : TcTypeEnv] [patterns : AstPatternList] [types : AstTypeList]) : ResultTcPattern
  (match patterns
    [(AstPatternNil)
     (match types
       [(AstTypeNil) (OkTcPattern env false)]
       [_ (ErrTcPattern "typecheck: variant pattern arity mismatch")])]
    [(AstPatternCons pat rest-patterns)
     (match types
       [(AstTypeCons ty rest-types)
        (match (tc-check-sub-pattern ctx env pat ty)
          [(OkTcPattern next-env _)
           (tc-check-pattern-list ctx next-env rest-patterns rest-types)]
          [(ErrTcPattern message) (ErrTcPattern message)])]
       [(AstTypeNil) (ErrTcPattern "typecheck: variant pattern arity mismatch")])]))

(define (tc-check-variant-pattern [ctx : TcContext] [env : TcTypeEnv] [enum-name : String] [variant-name : String] [patterns : AstPatternList]) : ResultTcPattern
  (match (compiler-registries-lookup-variant (struct-get ctx registries) variant-name)
    [(SomeI64 handle)
     (if (tc-variant-belongs-to? ctx enum-name handle)
         (match (tc-variant-field-types ctx handle)
           [(OkTcTypeList field-types)
            (tc-check-pattern-list ctx env patterns field-types)]
           [(ErrTcTypeList message) (ErrTcPattern message)])
         (ErrTcPattern "typecheck: variant belongs to different enum"))]
    [(NoneI64) (ErrTcPattern "typecheck: unknown variant in match")]))

(define (tc-check-sub-pattern [ctx : TcContext] [env : TcTypeEnv] [pat : AstPattern] [field-ty : AstType]) : ResultTcPattern
  (match pat
    [(AstPatWildcard) (OkTcPattern env false)]
    [(AstPatBinding name) (OkTcPattern (tc-bind env name field-ty) false)]
    [(AstPatLiteral lit)
     (if (tc-literal-pattern-compatible? lit field-ty)
         (OkTcPattern env false)
         (ErrTcPattern "typecheck: literal pattern type mismatch"))]
    [(AstPatVariant name args)
     (match field-ty
       [(AstTyEnum enum-name) (tc-check-variant-pattern ctx env enum-name name args)]
       [_ (ErrTcPattern "typecheck: nested variant pattern requires enum field")])]
    [_ (ErrTcPattern "typecheck: unsupported nested match pattern")]))

(define (tc-check-match-pattern [ctx : TcContext] [env : TcTypeEnv] [scrut-ty : AstType] [pat : AstPattern]) : ResultTcPattern
  (match pat
    [(AstPatWildcard) (OkTcPattern env true)]
    [(AstPatBinding name)
     (match scrut-ty
       [(AstTyEnum enum-name)
        (match (compiler-registries-lookup-variant (struct-get ctx registries) name)
          [(SomeI64 handle)
           (if (tc-variant-belongs-to? ctx enum-name handle)
               (match (tc-variant-field-types ctx handle)
                 [(OkTcTypeList fields)
                  (match fields
                    [(AstTypeNil) (OkTcPattern env false)]
                    [_ (ErrTcPattern "typecheck: nullary variant pattern has payload fields")])]
                 [(ErrTcTypeList message) (ErrTcPattern message)])
               (ErrTcPattern "typecheck: variant belongs to different enum"))]
          [(NoneI64) (OkTcPattern (tc-bind env name scrut-ty) true)])]
       [_ (OkTcPattern (tc-bind env name scrut-ty) true)])]
    [(AstPatLiteral lit)
     (if (tc-literal-pattern-compatible? lit scrut-ty)
         (OkTcPattern env false)
         (ErrTcPattern "typecheck: literal pattern type mismatch"))]
    [(AstPatVariant name args)
     (match scrut-ty
       [(AstTyEnum enum-name) (tc-check-variant-pattern ctx env enum-name name args)]
       [_ (ErrTcPattern "typecheck: variant pattern requires enum scrutinee")])]
    [_ (ErrTcPattern "typecheck: unsupported match pattern")]))

(define (tc-check-match-arm [ctx : TcContext] [env : TcTypeEnv] [scrut-ty : AstType] [arm : AstMatchArm]) : ResultTcArm
  (match arm
    [(AstMatchArm pat body)
     (match (tc-check-match-pattern ctx env scrut-ty pat)
       [(OkTcPattern arm-env is-wildcard)
        (match (tc-expr ctx arm-env body)
          [(OkTcType body-ty) (OkTcArm body-ty is-wildcard)]
          [(ErrTcType message) (ErrTcArm message)])]
       [(ErrTcPattern message) (ErrTcArm message)])]))

(define (tc-check-match-arms-rest [ctx : TcContext] [env : TcTypeEnv] [scrut-ty : AstType] [arms : AstMatchArmList] [expected : AstType] [has-wildcard : bool]) : ResultTcType
  (match arms
    [(AstMatchArmNil)
     (if has-wildcard
         (OkTcType expected)
         (ErrTcType "typecheck: match requires wildcard arm"))]
    [(AstMatchArmCons arm rest)
     (if has-wildcard
         (ErrTcType "typecheck: unreachable match arm after wildcard")
         (match (tc-check-match-arm ctx env scrut-ty arm)
           [(OkTcArm body-ty is-wildcard)
            (if (tc-type-eq body-ty expected)
                (tc-check-match-arms-rest ctx env scrut-ty rest expected is-wildcard)
                (ErrTcType "typecheck: match arms must have same type"))]
           [(ErrTcArm message) (ErrTcType message)]))]))

(define (tc-check-match [ctx : TcContext] [env : TcTypeEnv] [scrutinee : AstExpr] [arms : AstMatchArmList]) : ResultTcType
  (match (tc-expr ctx env scrutinee)
    [(OkTcType scrut-ty)
     (match arms
       [(AstMatchArmNil) (ErrTcType "typecheck: match must have at least one arm")]
       [(AstMatchArmCons first rest)
        (match (tc-check-match-arm ctx env scrut-ty first)
          [(OkTcArm first-ty is-wildcard)
           (tc-check-match-arms-rest ctx env scrut-ty rest first-ty is-wildcard)]
          [(ErrTcArm message) (ErrTcType message)])])]
    [(ErrTcType message) (ErrTcType message)]))

(define (tc-expr [ctx : TcContext] [env : TcTypeEnv] [expr : AstExpr]) : ResultTcType
  (match expr
    [(AstExprSpanned inner _) (tc-expr ctx env inner)]
    [(AstExprLiteral lit) (OkTcType (tc-literal-type lit))]
    [(AstExprVar name) (tc-lookup env name)]
    [(AstExprAnn inner ty)
     (match (tc-expr ctx env inner)
       [(OkTcType got)
        (match (tc-resolve-type ctx ty)
          [(OkTcType resolved-ty)
           (match (tc-expect got resolved-ty "typecheck: annotation type mismatch")
             [(OkTcUnit) (OkTcType resolved-ty)]
             [(ErrTcUnit message) (ErrTcType message)])]
          [(ErrTcType message) (ErrTcType message)])]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprLet bindings body)
     (match (tc-let-bindings ctx env bindings)
       [(OkTcEnv next-env) (tc-expr ctx next-env body)]
       [(ErrTcEnv message) (ErrTcType message)])]
    [(AstExprLambda params maybe-ret body)
     (match (tc-bind-params ctx env params)
       [(OkTcEnv lambda-env)
        (match (tc-expr ctx lambda-env body)
          [(OkTcType body-ty)
           (match (tc-resolve-type-list ctx (tc-param-type-list params))
             [(OkTcTypeList param-types)
              (match maybe-ret
                [(AstSomeType ret)
                 (match (tc-resolve-type ctx ret)
                   [(OkTcType resolved-ret)
                    (match (tc-expect body-ty resolved-ret "typecheck: lambda return type mismatch")
                      [(OkTcUnit) (OkTcType (AstTyFunc param-types resolved-ret))]
                      [(ErrTcUnit message) (ErrTcType message)])]
                   [(ErrTcType message) (ErrTcType message)])]
                [(AstNoType) (OkTcType (AstTyFunc param-types body-ty))])]
             [(ErrTcTypeList message) (ErrTcType message)])]
          [(ErrTcType message) (ErrTcType message)])]
       [(ErrTcEnv message) (ErrTcType message)])]
    [(AstExprTuple exprs)
     (match (tc-expr-list-types ctx env exprs)
       [(OkTcTypeList tys) (OkTcType (AstTyTuple tys))]
       [(ErrTcTypeList message) (ErrTcType message)])]
    [(AstExprTupleRef tuple index)
     (match (tc-expr ctx env tuple)
       [(OkTcType tuple-ty)
        (match tuple-ty
          [(AstTyTuple tys) (tc-type-list-ref tys index)]
          [_ (ErrTcType "typecheck: tuple-ref requires tuple type")])]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprArray exprs)
     (match exprs
       [(AstExprNil) (ErrTcType "typecheck: cannot infer type of empty array")]
       [(AstExprCons first rest)
        (match (tc-expr ctx env first)
          [(OkTcType first-ty)
           (match (tc-check-array-rest ctx env rest first-ty)
             [(OkTcUnit) (OkTcType (AstTyArray first-ty (tc-expr-list-len exprs)))]
             [(ErrTcUnit message) (ErrTcType message)])]
          [(ErrTcType message) (ErrTcType message)])])]
    [(AstExprMakeArray elem-ty len)
     (match (tc-expr ctx env len)
       [(OkTcType len-ty)
        (if (tc-integer-type? len-ty)
            (match (tc-resolve-type ctx elem-ty)
              [(OkTcType resolved-elem)
               (if (tc-dyn-array-elem-supported? resolved-elem)
                   (OkTcType (AstTyDynArray resolved-elem))
                   (ErrTcType "typecheck: make-array element type is not supported"))]
              [(ErrTcType message) (ErrTcType message)])
            (ErrTcType "typecheck: make-array length must be integer"))]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprArrayRef array index)
     (match (tc-expr ctx env array)
       [(OkTcType array-ty)
        (match (tc-expr ctx env index)
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
     (match (tc-expr ctx env array)
       [(OkTcType array-ty)
        (match (tc-expr ctx env index)
          [(OkTcType index-ty)
           (if (tc-integer-type? index-ty)
               (match array-ty
                 [(AstTyArray elem-ty _)
                  (match (tc-expr ctx env value)
                    [(OkTcType value-ty)
                     (match (tc-expect value-ty elem-ty "typecheck: array-set! value type mismatch")
                       [(OkTcUnit) (OkTcType (AstTyUnit))]
                       [(ErrTcUnit message) (ErrTcType message)])]
                    [(ErrTcType message) (ErrTcType message)])]
                 [(AstTyDynArray elem-ty)
                  (match (tc-expr ctx env value)
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
     (match (tc-expr ctx env str)
       [(OkTcType str-ty)
        (match (tc-expect str-ty (AstTyString) "typecheck: string-ref requires String")
          [(OkTcUnit)
           (match (tc-expr ctx env index)
             [(OkTcType index-ty)
              (if (tc-integer-type? index-ty)
                  (OkTcType (AstTyChar))
                  (ErrTcType "typecheck: string index must be integer"))]
             [(ErrTcType message) (ErrTcType message)])]
          [(ErrTcUnit message) (ErrTcType message)])]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprBegin exprs) (tc-begin-list ctx env exprs)]
    [(AstExprIf cond then-branch else-branch)
     (match (tc-expr ctx env cond)
       [(OkTcType cond-ty)
        (match (tc-expect cond-ty (AstTyBool) "typecheck: if condition must be bool")
          [(OkTcUnit)
           (match (tc-expr ctx env then-branch)
             [(OkTcType then-ty)
              (match (tc-expr ctx env else-branch)
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
        (match (tc-expr ctx env value)
          [(OkTcType value-ty)
           (match (tc-expect value-ty var-ty "typecheck: assignment type mismatch")
             [(OkTcUnit) (OkTcType (AstTyUnit))]
             [(ErrTcUnit message) (ErrTcType message)])]
          [(ErrTcType message) (ErrTcType message)])]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprCast inner ty)
     (match (tc-expr ctx env inner)
       [(OkTcType inner-ty)
        (match (tc-resolve-type ctx ty)
          [(OkTcType resolved-ty)
           (if (and (tc-castable-type? inner-ty) (tc-castable-type? resolved-ty))
               (OkTcType resolved-ty)
               (ErrTcType "typecheck: cast requires integer/char source and target"))]
          [(ErrTcType message) (ErrTcType message)])]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprUnary op inner)
     (match (tc-expr ctx env inner)
       [(OkTcType ty) (tc-unop-type op ty)]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprBinary op left right)
     (match (tc-expr ctx env left)
       [(OkTcType left-ty)
        (match (tc-expr ctx env right)
          [(OkTcType right-ty) (tc-binop-type op left-ty right-ty)]
          [(ErrTcType message) (ErrTcType message)])]
       [(ErrTcType message) (ErrTcType message)])]
    [(AstExprCall func args) (tc-call-or-array-length ctx env func args)]
    [(AstExprWhile cond body)
     (match (tc-expr ctx env cond)
       [(OkTcType cond-ty)
        (match (tc-expect cond-ty (AstTyBool) "typecheck: while condition must be bool")
          [(OkTcUnit)
           (match (tc-expr ctx env body)
             [(OkTcType body-ty)
              (match (tc-expect body-ty (AstTyUnit) "typecheck: while body must be unit")
                [(OkTcUnit) (OkTcType (AstTyUnit))]
                [(ErrTcUnit message) (ErrTcType message)])]
             [(ErrTcType message) (ErrTcType message)])]
          [(ErrTcUnit message) (ErrTcType message)])]
       [(ErrTcType message) (ErrTcType message)])]
     [(AstExprForeach index index-ty start end body)
      (match (tc-resolve-type ctx index-ty)
        [(OkTcType resolved-index-ty)
         (if (tc-integer-type? resolved-index-ty)
            (match (tc-expr ctx env start)
              [(OkTcType start-ty)
               (if (tc-integer-type? start-ty)
                   (match (tc-expr ctx env end)
                     [(OkTcType end-ty)
                      (if (tc-integer-type? end-ty)
                          (let ([body-env : TcTypeEnv (tc-bind env index resolved-index-ty)])
                            (match (tc-expr ctx body-env body)
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
        [(ErrTcType message) (ErrTcType message)])]
     [(AstExprStructGet receiver field)
      (match (tc-expr ctx env receiver)
        [(OkTcType receiver-ty)
         (match receiver-ty
           [(AstTyStruct struct-name) (tc-struct-field-type ctx struct-name field)]
           [_ (ErrTcType "typecheck: struct-get requires struct")])]
        [(ErrTcType message) (ErrTcType message)])]
     [(AstExprMatch scrutinee arms) (tc-check-match ctx env scrutinee arms)]
     [_ (ErrTcType "typecheck: unsupported expression")]))

(define (tc-summary-add-decl [summary : CompilerTypecheckSummary] [decl : AstDecl]) : CompilerTypecheckSummary
  (match summary
    [(CompilerTypecheckSummary values functions externs)
     (match decl
       [(AstDeclDef _ _ _) (CompilerTypecheckSummary (+ values 1) functions externs)]
       [(AstDeclDefFn _ _ _ _) (CompilerTypecheckSummary values (+ functions 1) externs)]
       [(AstDeclExtern _ _) (CompilerTypecheckSummary values functions (+ externs 1))]
       [_ summary])]))

(define (tc-check-decl [ctx : TcContext] [top-env : TcTypeEnv] [decl : AstDecl]) : ResultTcUnit
  (match decl
    [(AstDeclDef _ maybe-ty expr)
     (match maybe-ty
        [(AstSomeType want)
         (match (tc-expr ctx top-env expr)
           [(OkTcType got)
            (match (tc-resolve-type ctx want)
              [(OkTcType resolved-want)
               (match (tc-expect got resolved-want "typecheck: value definition type mismatch")
                 [(OkTcUnit) OkTcUnit]
                 [(ErrTcUnit message) (ErrTcUnit message)])]
              [(ErrTcType message) (ErrTcUnit message)])]
           [(ErrTcType message) (ErrTcUnit message)])]
        [(AstNoType)
         (match (tc-expr ctx top-env expr)
           [(OkTcType _) OkTcUnit]
           [(ErrTcType message) (ErrTcUnit message)])])]
    [(AstDeclDefFn _ params ret body)
     (match (tc-bind-params ctx top-env params)
       [(OkTcEnv env)
        (match (tc-expr ctx env body)
          [(OkTcType got)
           (match (tc-resolve-type ctx ret)
             [(OkTcType resolved-ret)
              (match (tc-expect got resolved-ret "typecheck: return type mismatch")
                [(OkTcUnit) OkTcUnit]
                [(ErrTcUnit message) (ErrTcUnit message)])]
             [(ErrTcType message) (ErrTcUnit message)])]
          [(ErrTcType message) (ErrTcUnit message)])]
       [(ErrTcEnv message) (ErrTcUnit message)])]
    [(AstDeclExtern _ ty)
     (match (tc-resolve-type ctx ty)
       [(OkTcType resolved-ty)
        (match resolved-ty
          [(AstTyFunc _ _) OkTcUnit]
          [_ (ErrTcUnit "typecheck: extern must have function type")])]
       [(ErrTcType message) (ErrTcUnit message)])]
     [_ OkTcUnit]))

(define (tc-check-decls [ctx : TcContext] [top-env : TcTypeEnv] [decls : AstDeclList] [summary : CompilerTypecheckSummary]) : ResultCompilerTypecheck
  (match decls
    [(AstDeclNil) (OkCompilerTypecheck summary)]
    [(AstDeclCons decl rest)
     (match (tc-check-decl ctx top-env decl)
       [(OkTcUnit)
        (tc-check-decls ctx top-env rest (tc-summary-add-decl summary decl))]
       [(ErrTcUnit message) (ErrCompilerTypecheck message)])]))

(define (typecheck-compiler-program [program : AstProgram]) : ResultCompilerTypecheck
  (match (build-compiler-symbols program)
    [(OkCompilerSymbols symbols)
     (match (build-compiler-registries program)
       [(OkCompilerRegistries registries)
        (let ([ctx : TcContext (TcContext program symbols registries)])
          (match (tc-build-top-env ctx)
            [(OkTcEnv top-env)
             (match program
               [(AstProgram decls)
                (tc-check-decls ctx top-env decls (CompilerTypecheckSummary 0 0 0))])]
            [(ErrTcEnv message) (ErrCompilerTypecheck message)]))]
       [(ErrCompilerRegistries message) (ErrCompilerTypecheck message)])]
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

(define (compiler-typecheck-nominal-source) : String
  "(defenum Maybe (Some i64) (None))
(defstruct Point (x i64) (y i64))
(define value : Maybe (Some 5))
(define point : Point (Point 4 6))
(define (main [flag : bool]) : i64
  (let ([m : Maybe (if flag value (None))]
        [p : Point point])
    (+ (struct-get p x)
       (match m
         [(Some value) value]
         [(None) 0]
         [_ 0]))))")

(define (compiler-typecheck-missing-field-source) : String
  "(defstruct Point (x i64))
(define (main [p : Point]) : i64
  (struct-get p y))")

(define (compiler-typecheck-match-mismatch-source) : String
  "(defenum Maybe (Some i64) (None))
(define (main [m : Maybe]) : i64
  (match m
    [(Some value) value]
    [None false]
    [_ 0]))")

(define (compiler-typecheck-unknown-variant-source) : String
  "(defenum Maybe (Some i64) (None))
(define (main [m : Maybe]) : i64
  (match m
    [(Other value) value]
    [_ 0]))")

(define (compiler-typecheck-unknown-type-source) : String
  "(define (main [m : Missing]) : i64 0)")

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

(define (compiler-typecheck-nominal-tests-ok?) : bool
  (and (compiler-typecheck-ok-score? (compiler-typecheck-nominal-source) 12)
       (and (compiler-typecheck-error-ok?
              (compiler-typecheck-missing-field-source)
              "typecheck: struct field not found")
            (and (compiler-typecheck-error-ok?
                   (compiler-typecheck-match-mismatch-source)
                   "typecheck: match arms must have same type")
                 (and (compiler-typecheck-error-ok?
                        (compiler-typecheck-unknown-variant-source)
                        "typecheck: unknown variant in match")
                      (compiler-typecheck-error-ok?
                        (compiler-typecheck-unknown-type-source)
                        "typecheck: unknown type Missing"))))))

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
                              (and (compiler-typecheck-aggregate-tests-ok?)
                                   (compiler-typecheck-nominal-tests-ok?))))))
          42
          (begin
            (panic "typecheck: smoke score mismatch")
           0))]
    [(ErrCompilerTypecheck message)
     (begin
       (panic message)
       0)]))
