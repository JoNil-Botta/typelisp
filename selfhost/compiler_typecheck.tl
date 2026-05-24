;; compiler_typecheck.tl - First scalar typechecker pass over compiler AstProgram (#426).

(import "compiler_symbols.tl")

(import "compiler_diagnostic.tl")

(defenum TcTypeEnv
  (TcTypeNil)
  (TcTypeBind String AstType TcTypeEnv))

(defenum TcContext
  (TcContext AstProgram CompilerSymbols CompilerRegistries))

(defenum ResultTcType
  (OkTcType AstType)
  (ErrTcType String))

(defenum ResultTcTypeList
  (OkTcTypeList AstTypeList)
  (ErrTcTypeList String))

(defenum ResultTcString
  (OkTcString String)
  (ErrTcString String))

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
  (ErrCompilerTypecheck CompilerDiagnostic))

;; The typechecker receives an already-loaded program and so does not know the

;; source path; it builds diagnostics with an empty path (the CLI driver stamps

;; the real path before rendering). Synthetic/internal errors fall back to 1:1.

(define (tc-diag-at-start [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start "" message))

(define (tc-expr-diag [expr : AstExpr] [message : String]) : CompilerDiagnostic
  (match expr
    [(AstExprSpanned _ span)
      (CompilerDiagnostic
        ""
        (struct-get span start-line)
        (struct-get span start-col)
        message)]
    [_ (tc-diag-at-start message)]))

;; Locate an error at the nearest available declaration body span. A top-level

;; `define` body is wrapped in `AstExprSpanned`, so its span points the

;; diagnostic at the offending declaration's expression; otherwise fall back 1:1.

(define (tc-decl-diag [decl : AstDecl] [message : String]) : CompilerDiagnostic
  (match decl
    [(AstDeclDef _ _ expr) (tc-expr-diag expr message)]
    [(AstDeclDefFn _ _ _ body) (tc-expr-diag body message)]
    [_ (tc-diag-at-start message)]))

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
      (let ([e2
          :
          TcTypeEnv
          (tc-bind e1 "print-bool" (tc-fn1 (AstTyBool) (AstTyUnit)))])
        (let ([e3
            :
            TcTypeEnv
            (tc-bind e2 "print-float" (tc-fn1 (AstTyF64) (AstTyUnit)))])
          (let ([e4
              :
              TcTypeEnv
              (tc-bind e3 "print-char" (tc-fn1 (AstTyChar) (AstTyUnit)))])
            (let ([e5
                :
                TcTypeEnv
                (tc-bind e4 "print-newline" (tc-fn0 (AstTyUnit)))])
              (let ([e6
                  :
                  TcTypeEnv
                  (tc-bind e5 "print-string" (tc-fn1 (AstTyString) (AstTyUnit)))])
                (let ([e7
                    :
                    TcTypeEnv
                    (tc-bind e6 "print-str" (tc-fn1 (AstTyString) (AstTyUnit)))])
                  (let ([e8
                      :
                      TcTypeEnv
                      (tc-bind
                        e7
                        "print-error"
                        (tc-fn1 (AstTyString) (AstTyUnit)))])
                    (let ([e9
                        :
                        TcTypeEnv
                        (tc-bind e8 "arg-count" (tc-fn0 (AstTyI64)))])
                      (let ([e10
                          :
                          TcTypeEnv
                          (tc-bind e9 "arg" (tc-fn1 (AstTyI64) (AstTyString)))])
                        (let ([e11
                            :
                            TcTypeEnv
                            (tc-bind
                              e10
                              "string-length"
                              (tc-fn1 (AstTyString) (AstTyI64)))])
                          (let ([e12
                              :
                              TcTypeEnv
                              (tc-bind
                                e11
                                "length"
                                (tc-fn1 (AstTyString) (AstTyI64)))])
                            (let ([e13
                                :
                                TcTypeEnv
                                (tc-bind
                                  e12
                                  "string-eq"
                                  (tc-fn2
                                    (AstTyString)
                                    (AstTyString)
                                    (AstTyBool)))])
                              (let ([e14
                                  :
                                  TcTypeEnv
                                  (tc-bind
                                    e13
                                    "string=?"
                                    (tc-fn2
                                      (AstTyString)
                                      (AstTyString)
                                      (AstTyBool)))])
                                (let ([e15
                                    :
                                    TcTypeEnv
                                    (tc-bind
                                      e14
                                      "string->int"
                                      (tc-fn1 (AstTyString) (AstTyI64)))])
                                  (let ([e16
                                      :
                                      TcTypeEnv
                                      (tc-bind
                                        e15
                                        "int->string"
                                        (tc-fn1 (AstTyI64) (AstTyString)))])
                                    (let ([e17
                                        :
                                        TcTypeEnv
                                        (tc-bind
                                          e16
                                          "read-file"
                                          (tc-fn1 (AstTyString) (AstTyString)))])
                                      (let ([e18
                                          :
                                          TcTypeEnv
                                          (tc-bind
                                            e17
                                            "write-file"
                                            (tc-fn2
                                              (AstTyString)
                                              (AstTyString)
                                              (AstTyUnit)))])
                                        (let ([e19
                                            :
                                            TcTypeEnv
                                            (tc-bind
                                              e18
                                              "file-exists?"
                                              (tc-fn1 (AstTyString) (AstTyBool)))])
                                          (let ([e20
                                              :
                                              TcTypeEnv
                                              (tc-bind
                                                e19
                                                "substring"
                                                (tc-fn3
                                                  (AstTyString)
                                                  (AstTyI64)
                                                  (AstTyI64)
                                                  (AstTyString)))])
                                            (let ([e21
                                                :
                                                TcTypeEnv
                                                (tc-bind
                                                  e20
                                                  "string-slice"
                                                  (tc-fn3
                                                    (AstTyString)
                                                    (AstTyI64)
                                                    (AstTyI64)
                                                    (AstTyString)))])
                                              (let ([e22
                                                  :
                                                  TcTypeEnv
                                                  (tc-bind
                                                    e21
                                                    "string-append"
                                                    (tc-fn2
                                                      (AstTyString)
                                                      (AstTyString)
                                                      (AstTyString)))])
                                                (let ([e23
                                                    :
                                                    TcTypeEnv
                                                    (tc-bind
                                                      e22
                                                      "string-concat"
                                                      (tc-fn2
                                                        (AstTyString)
                                                        (AstTyString)
                                                        (AstTyString)))])
                                                  (let ([e24
                                                      :
                                                      TcTypeEnv
                                                      (tc-bind
                                                        e23
                                                        "read-stdin-line"
                                                        (tc-fn0 (AstTyString)))])
                                                    (let ([e25
                                                        :
                                                        TcTypeEnv
                                                        (tc-bind
                                                          e24
                                                          "read-stdin-bytes"
                                                          (tc-fn1
                                                            (AstTyI64)
                                                            (AstTyString)))])
                                                      (let ([e26
                                                          :
                                                          TcTypeEnv
                                                          (tc-bind
                                                            e25
                                                            "stdin-eof?"
                                                            (tc-fn0 (AstTyBool)))])
                                                        (let ([e27
                                                            :
                                                            TcTypeEnv
                                                            (tc-bind
                                                              e26
                                                              "flush-stdout"
                                                              (tc-fn0
                                                                (AstTyUnit)))])
                                                          (let ([e28
                                                              :
                                                              TcTypeEnv
                                                              (tc-bind
                                                                e27
                                                                "panic"
                                                                (tc-fn1
                                                                  (AstTyString)
                                                                  (AstTyNever)))])
                                                            (tc-bind
                                                              e28
                                                              "error"
                                                              (tc-fn1
                                                                (AstTyString)
                                                                (AstTyNever)))))))))))))))))))))))))))))))))

(define (tc-lookup [env : TcTypeEnv] [name : String]) : ResultTcType
  (match env
    [(TcTypeNil) (ErrTcType (string-append "typecheck: unbound name " name))]
    [(TcTypeBind key ty rest)
      (if (string-eq key name)
        (OkTcType ty)
        (tc-lookup rest name))]))

(define (tc-resolve-type-list [ctx : TcContext] [types : AstTypeList]) : AstTypeList
  (match types
    [(AstTypeNil) AstTypeNil]
    [(AstTypeCons head tail)
      (AstTypeCons (tc-resolve-type ctx head) (tc-resolve-type-list ctx tail))]))

(define (tc-resolve-type [ctx : TcContext] [ty : AstType]) : AstType
  (match ty
    [(AstTyFunc args ret)
      (AstTyFunc (tc-resolve-type-list ctx args) (tc-resolve-type ctx ret))]
    [(AstTyTuple elems) (AstTyTuple (tc-resolve-type-list ctx elems))]
    [(AstTyArray elem len) (AstTyArray (tc-resolve-type ctx elem) len)]
    [(AstTyDynArray elem) (AstTyDynArray (tc-resolve-type ctx elem))]
    [(AstTyVar name)
      (match ctx
        [(TcContext _ symbols _)
          (match (compiler-symbols-lookup-type symbols name)
            [(SomeI64 handle)
              (if (=
                (compiler-symbol-handle-kind handle)
                (compiler-symbol-kind-defenum))
                (AstTyEnum name)
                (if (=
                  (compiler-symbol-handle-kind handle)
                  (compiler-symbol-kind-defstruct))
                  (AstTyStruct name)
                  (AstTyVar name)))]
            [(NoneI64) (AstTyVar name)])])]
    [_ ty]))

(define (tc-type-list-eq [a : AstTypeList] [b : AstTypeList]) : bool
  (match a
    [(AstTypeNil)
      (match b
        [(AstTypeNil) true]
        [_ false])]
    [(AstTypeCons ah at)
      (match b
        [(AstTypeCons bh bt) (and (tc-type-eq ah bh) (tc-type-list-eq at bt))]
        [_ false])]))

(define (tc-type-eq [a : AstType] [b : AstType]) : bool
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

(define (tc-never-type? [ty : AstType]) : bool
  (match ty
    [(AstTyNever) true]
    [_ false]))

(define (tc-type-compatible? [expected : AstType] [actual : AstType]) : bool
  (if (tc-never-type? actual)
    true
    (tc-type-eq expected actual)))

(define (tc-merge-branch-type [a : AstType] [b : AstType]) : ResultTcType
  (if (tc-never-type? a)
    (OkTcType b)
    (if (tc-never-type? b)
      (OkTcType a)
      (if (tc-type-eq a b)
        (OkTcType a)
        (ErrTcType "typecheck: if branches must match")))))

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

(define (tc-float-type? [ty : AstType]) : bool
  (match ty
    [(AstTyF64) true]
    [_ false]))

(define (tc-ordered-comparison-type? [ty : AstType]) : bool
  (if (tc-integer-type? ty)
    true
    (if (tc-float-type? ty)
      true
      (match ty
        [(AstTyChar) true]
        [_ false]))))

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

(define (tc-param-type-list [ctx : TcContext] [params : AstParamList]) : AstTypeList
  (match params
    [(AstParamNil) AstTypeNil]
    [(AstParamCons param rest)
      (match param
        [(AstParam _ ty)
          (AstTypeCons (tc-resolve-type ctx ty) (tc-param-type-list ctx rest))])]))

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

(define (tc-expr-list-types
  [ctx : TcContext]
  [env : TcTypeEnv]
  [exprs : AstExprList]) : ResultTcTypeList
  (match exprs
    [(AstExprNil) (OkTcTypeList AstTypeNil)]
    [(AstExprCons expr rest)
      (match (tc-expr ctx env expr)
        [(OkTcType ty)
          (match (tc-expr-list-types ctx env rest)
            [(OkTcTypeList rest-types)
              (OkTcTypeList (AstTypeCons ty rest-types))]
            [(ErrTcTypeList message) (ErrTcTypeList message)])]
        [(ErrTcType message) (ErrTcTypeList message)])]))

(define (tc-check-array-rest
  [ctx : TcContext]
  [env : TcTypeEnv]
  [exprs : AstExprList]
  [elem-ty : AstType]) : ResultTcUnit
  (match exprs
    [(AstExprNil) OkTcUnit]
    [(AstExprCons expr rest)
      (match (tc-expr ctx env expr)
        [(OkTcType ty)
          (match (tc-expect
            ty
            elem-ty
            "typecheck: array elements must have same type")
            [(OkTcUnit) (tc-check-array-rest ctx env rest elem-ty)]
            [(ErrTcUnit message) (ErrTcUnit message)])]
        [(ErrTcType message) (ErrTcUnit message)])]))

(define (tc-bind-params
  [ctx : TcContext]
  [env : TcTypeEnv]
  [params : AstParamList]) : TcTypeEnv
  (match params
    [(AstParamNil) env]
    [(AstParamCons param rest)
      (match param
        [(AstParam name ty)
          (tc-bind-params ctx (tc-bind env name (tc-resolve-type ctx ty)) rest)])]))

(define (tc-top-decl-type [ctx : TcContext] [decl : AstDecl]) : ResultTcType
  (match decl
    [(AstDeclDef _ maybe-ty expr)
      (match maybe-ty
        [(AstSomeType ty) (OkTcType (tc-resolve-type ctx ty))]
        [(AstNoType)
          (match (ast-expr-unspan expr)
            [(AstExprLiteral lit) (OkTcType (tc-literal-type lit))]
            [(AstExprAnn _ ty) (OkTcType (tc-resolve-type ctx ty))]
            [_ (ErrTcType "typecheck: top-level value requires annotation")])])]
    [(AstDeclDefFn _ params ret _)
      (OkTcType
        (AstTyFunc (tc-param-type-list ctx params) (tc-resolve-type ctx ret)))]
    [(AstDeclExtern _ ty) (OkTcType (tc-resolve-type ctx ty))]
    [_ (ErrTcType "typecheck: declaration has no value type")]))

(define (tc-field-type-list [ctx : TcContext] [fields : AstFieldDefList]) : AstTypeList
  (match fields
    [(AstFieldDefNil) AstTypeNil]
    [(AstFieldDefCons field rest)
      (match field
        [(AstFieldDef _ ty)
          (AstTypeCons (tc-resolve-type ctx ty) (tc-field-type-list ctx rest))])]))

(define (tc-enum-variant-constructor-type
  [ctx : TcContext]
  [enum-name : String]
  [fields : AstTypeList]) : AstType
  (match fields
    [(AstTypeNil) (AstTyEnum enum-name)]
    [_ (AstTyFunc (tc-resolve-type-list ctx fields) (AstTyEnum enum-name))]))

(define (tc-bind-enum-variants
  [ctx : TcContext]
  [env : TcTypeEnv]
  [enum-name : String]
  [variants : AstVariantDefList]) : ResultTcEnv
  (match variants
    [(AstVariantDefNil) (OkTcEnv env)]
    [(AstVariantDefCons variant rest)
      (match variant
        [(AstVariantDef name fields)
          (tc-bind-enum-variants
            ctx
            (tc-bind
              env
              name
              (tc-enum-variant-constructor-type ctx enum-name fields))
            enum-name
            rest)])]))

(define (tc-build-top-env-list
  [ctx : TcContext]
  [decls : AstDeclList]
  [env : TcTypeEnv]) : ResultTcEnv
  (match decls
    [(AstDeclNil) (OkTcEnv env)]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclDef name _ _)
          (match (tc-top-decl-type ctx decl)
            [(OkTcType ty)
              (tc-build-top-env-list ctx rest (tc-bind env name ty))]
            [(ErrTcType message) (ErrTcEnv message)])]
        [(AstDeclDefFn name _ _ _)
          (match (tc-top-decl-type ctx decl)
            [(OkTcType ty)
              (tc-build-top-env-list ctx rest (tc-bind env name ty))]
            [(ErrTcType message) (ErrTcEnv message)])]
        [(AstDeclExtern name _)
          (match (tc-top-decl-type ctx decl)
            [(OkTcType ty)
              (tc-build-top-env-list ctx rest (tc-bind env name ty))]
            [(ErrTcType message) (ErrTcEnv message)])]
        [(AstDeclDefEnum name variants)
          (match (tc-bind-enum-variants ctx env name variants)
            [(OkTcEnv next-env) (tc-build-top-env-list ctx rest next-env)]
            [(ErrTcEnv message) (ErrTcEnv message)])]
        [(AstDeclDefStruct name fields)
          (tc-build-top-env-list
            ctx
            rest
            (tc-bind
              env
              name
              (AstTyFunc (tc-field-type-list ctx fields) (AstTyStruct name))))]
        [(AstDeclImport _) (tc-build-top-env-list ctx rest env)])]))

(define (tc-build-top-env [ctx : TcContext] [program : AstProgram]) : ResultTcEnv
  (match program
    [(AstProgram decls) (tc-build-top-env-list ctx decls (tc-default-env))]))

(define (tc-expect [actual : AstType] [expected : AstType] [message : String]) : ResultTcUnit
  (if (tc-type-compatible? expected actual)
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
    [(AstBinAdd) (tc-arithmetic-binop-type left right)]
    [(AstBinSub) (tc-arithmetic-binop-type left right)]
    [(AstBinMul) (tc-arithmetic-binop-type left right)]
    [(AstBinDiv) (tc-arithmetic-binop-type left right)]
    [_ (tc-integer-binop-type left right)]))

(define (tc-integer-binop-type [left : AstType] [right : AstType]) : ResultTcType
  (if (and (tc-integer-type? left) (tc-type-eq left right))
    (OkTcType left)
    (ErrTcType "typecheck: integer operator expects matching integer operands")))

(define (tc-arithmetic-binop-type [left : AstType] [right : AstType]) : ResultTcType
  (if (and (tc-float-type? left) (tc-type-eq left right))
    (OkTcType left)
    (tc-integer-binop-type left right)))

(define (tc-compare-binop-type [left : AstType] [right : AstType]) : ResultTcType
  (if (and (tc-ordered-comparison-type? left) (tc-type-eq left right))
    (OkTcType (AstTyBool))
    (ErrTcType "typecheck: comparison expects matching ordered scalar operands")))

(define (tc-unop-type [op : AstUnOp] [ty : AstType]) : ResultTcType
  (match op
    [(AstUnNot)
      (if (tc-type-eq ty (AstTyBool))
        (OkTcType (AstTyBool))
        (ErrTcType "typecheck: not expects bool"))]
    [(AstUnNeg)
      (if (or (tc-integer-type? ty) (tc-float-type? ty))
        (OkTcType ty)
        (ErrTcType "typecheck: neg expects integer"))]
    [(AstUnBitNot)
      (if (tc-integer-type? ty)
        (OkTcType ty)
        (ErrTcType "typecheck: bit-not expects integer"))]))

(define (tc-check-args
  [ctx : TcContext]
  [env : TcTypeEnv]
  [args : AstExprList]
  [params : AstTypeList]) : ResultTcUnit
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

(define (tc-call-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [func : AstExpr]
  [args : AstExprList]) : ResultTcType
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

;; Whether `name` resolves to any binding in `env` (a builtin, a top-level

;; user definition, or a local). Used to decide whether an unbound builtin

;; name like `string-ref`/`char-at` should be treated as the String-index

;; builtin (unbound) or as an ordinary direct call to a shadowing user

;; definition (bound). Mirrors the host compiler's shadowing check (#677).

(define (tc-name-bound? [env : TcTypeEnv] [name : String]) : bool
  (match (tc-lookup env name)
    [(OkTcType _) true]
    [(ErrTcType _) false]))

;; Typecheck the *unshadowed* `(string-ref s i)` / `(char-at s i)` builtin: a

;; String plus any integer index, yielding `char`. The parser emits this as an

;; ordinary `Call`; when `string-ref`/`char-at` is not bound to a user function

;; or local, recover the builtin String-index behavior (and its exact

;; diagnostics) here rather than via the generic call path (#677).

(define (tc-string-ref-call
  [ctx : TcContext]
  [env : TcTypeEnv]
  [args : AstExprList]) : ResultTcType
  (match args
    [(AstExprCons str (AstExprCons index (AstExprNil)))
      (match (tc-expr ctx env str)
        [(OkTcType str-ty)
          (match (tc-expect
            str-ty
            (AstTyString)
            "typecheck: string-ref requires String")
            [(OkTcUnit)
              (match (tc-expr ctx env index)
                [(OkTcType index-ty)
                  (if (tc-integer-type? index-ty)
                    (OkTcType (AstTyChar))
                    (ErrTcType "typecheck: string index must be integer"))]
                [(ErrTcType message) (ErrTcType message)])]
            [(ErrTcUnit message) (ErrTcType message)])]
        [(ErrTcType message) (ErrTcType message)])]
    [_ (ErrTcType "typecheck: arity mismatch")]))

(define (tc-array-length-call
  [ctx : TcContext]
  [env : TcTypeEnv]
  [name : String]
  [func : AstExpr]
  [args : AstExprList]) : ResultTcType
  (match args
    [(AstExprCons arg rest)
      (match rest
        [(AstExprNil)
          (match (tc-expr ctx env arg)
            [(OkTcType arg-ty)
              (match arg-ty
                [(AstTyDynArray _) (OkTcType (AstTyI64))]
                [_
                  (if (string-eq name "array-length")
                    (ErrTcType "typecheck: array-length requires dynamic array")
                    (tc-call-expr ctx env func args))])]
            [(ErrTcType message) (ErrTcType message)])]
        [_
          (if (string-eq name "array-length")
            (ErrTcType "typecheck: arity mismatch")
            (tc-call-expr ctx env func args))])]
    [_
      (if (string-eq name "array-length")
        (ErrTcType "typecheck: arity mismatch")
        (tc-call-expr ctx env func args))]))

(define (tc-call-or-array-length
  [ctx : TcContext]
  [env : TcTypeEnv]
  [func : AstExpr]
  [args : AstExprList]) : ResultTcType
  (match (ast-expr-unspan func)
    [(AstExprVar name)
      (if (or (string-eq name "array-length") (string-eq name "length"))
        (tc-array-length-call ctx env name func args)
        (if (and
          (or (string-eq name "string-ref") (string-eq name "char-at"))
          (not (tc-name-bound? env name)))
          (tc-string-ref-call ctx env args)
          (tc-call-expr ctx env func args)))]
    [_ (tc-call-expr ctx env func args)]))

(define (tc-let-bindings
  [ctx : TcContext]
  [env : TcTypeEnv]
  [bindings : AstLetBindingList]) : ResultTcEnv
  (match bindings
    [(AstLetBindingNil) (OkTcEnv env)]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding name maybe-ty init)
          (match (tc-expr ctx env init)
            [(OkTcType init-ty)
              (match maybe-ty
                [(AstSomeType want)
                  (match (tc-expect
                    init-ty
                    (tc-resolve-type ctx want)
                    "typecheck: let binding type mismatch")
                    [(OkTcUnit)
                      (tc-let-bindings
                        ctx
                        (tc-bind env name (tc-resolve-type ctx want))
                        rest)]
                    [(ErrTcUnit message) (ErrTcEnv message)])]
                [(AstNoType)
                  (tc-let-bindings ctx (tc-bind env name init-ty) rest)])]
            [(ErrTcType message) (ErrTcEnv message)])])]))

(define (tc-begin-list
  [ctx : TcContext]
  [env : TcTypeEnv]
  [exprs : AstExprList]) : ResultTcType
  (match exprs
    [(AstExprNil) (OkTcType (AstTyUnit))]
    [(AstExprCons expr rest)
      (match rest
        [(AstExprNil) (tc-expr ctx env expr)]
        [_
          (match (tc-expr ctx env expr)
            [(OkTcType _) (tc-begin-list ctx env rest)]
            [(ErrTcType message) (ErrTcType message)])])]))

(define (tc-context-program [ctx : TcContext]) : AstProgram
  (match ctx
    [(TcContext program _ _) program]))

(define (tc-context-registries [ctx : TcContext]) : CompilerRegistries
  (match ctx
    [(TcContext _ _ registries) registries]))

(define (tc-program-enum-variants-list
  [decls : AstDeclList]
  [enum-name : String]) : ResultAstVariantDefList
  (match decls
    [(AstDeclNil)
      (ErrAstVariantDefList
        (string-append "typecheck: unknown enum " enum-name))]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclDefEnum name variants)
          (if (string-eq name enum-name)
            (OkAstVariantDefList variants)
            (tc-program-enum-variants-list rest enum-name))]
        [_ (tc-program-enum-variants-list rest enum-name)])]))

(define (tc-program-enum-variants [program : AstProgram] [enum-name : String]) : ResultAstVariantDefList
  (match program
    [(AstProgram decls) (tc-program-enum-variants-list decls enum-name)]))

(define (tc-variant-owner-name [ctx : TcContext] [handle : i64]) : ResultTcString
  (match (compiler-program-decl-at-index
    (tc-context-program ctx)
    (compiler-registry-handle-owner-index handle))
    [(OkAstDecl decl)
      (match decl
        [(AstDeclDefEnum name _) (OkTcString name)]
        [_ (ErrTcString "typecheck: variant owner is not enum")])]
    [(ErrAstDecl message) (ErrTcString message)]))

(define (tc-struct-field-type
  [ctx : TcContext]
  [struct-name : String]
  [field : String]) : ResultTcType
  (match (compiler-registries-lookup-struct-field
    (tc-context-registries ctx)
    struct-name
    field)
    [(SomeI64 handle)
      (match (compiler-registries-struct-field-type
        (tc-context-program ctx)
        handle)
        [(OkAstType ty) (OkTcType (tc-resolve-type ctx ty))]
        [(ErrAstType message) (ErrTcType message)])]
    [(NoneI64)
      (ErrTcType
        (string-append
          "typecheck: unknown struct field "
          (compiler-struct-field-key struct-name field)))]))

(define (tc-literal-pattern-compatible? [lit : AstLiteral] [scrut-ty : AstType]) : bool
  (let ([lit-ty : AstType (tc-literal-type lit)])
    (match lit
      [(AstLitInt _) (tc-integer-type? scrut-ty)]
      [_ (tc-type-eq lit-ty scrut-ty)])))

(define (tc-bind-sub-pattern-list
  [ctx : TcContext]
  [env : TcTypeEnv]
  [patterns : AstPatternList]
  [types : AstTypeList]) : ResultTcEnv
  (match patterns
    [(AstPatternNil)
      (match types
        [(AstTypeNil) (OkTcEnv env)]
        [_ (ErrTcEnv "typecheck: pattern arity mismatch")])]
    [(AstPatternCons pattern rest-patterns)
      (match types
        [(AstTypeCons ty rest-types)
          (match (tc-bind-sub-pattern ctx env pattern ty)
            [(OkTcEnv next-env)
              (tc-bind-sub-pattern-list ctx next-env rest-patterns rest-types)]
            [(ErrTcEnv message) (ErrTcEnv message)])]
        [(AstTypeNil) (ErrTcEnv "typecheck: pattern arity mismatch")])]))

(define (tc-bind-variant-pattern
  [ctx : TcContext]
  [env : TcTypeEnv]
  [enum-name : String]
  [variant-name : String]
  [args : AstPatternList]) : ResultTcEnv
  (match (compiler-registries-lookup-variant
    (tc-context-registries ctx)
    variant-name)
    [(SomeI64 handle)
      (match (tc-variant-owner-name ctx handle)
        [(OkTcString owner)
          (if (string-eq owner enum-name)
            (match (compiler-registries-variant-fields
              (tc-context-program ctx)
              handle)
              [(OkAstTypeList fields)
                (tc-bind-sub-pattern-list
                  ctx
                  env
                  args
                  (tc-resolve-type-list ctx fields))]
              [(ErrAstTypeList message) (ErrTcEnv message)])
            (ErrTcEnv
              (string-append
                "typecheck: variant "
                (string-append
                  variant-name
                  (string-append
                    " belongs to enum "
                    (string-append owner (string-append ", not " enum-name)))))))]
        [(ErrTcString message) (ErrTcEnv message)])]
    [(NoneI64)
      (ErrTcEnv (string-append "typecheck: unknown variant " variant-name))]))

(define (tc-bind-sub-pattern
  [ctx : TcContext]
  [env : TcTypeEnv]
  [pattern : AstPattern]
  [field-ty : AstType]) : ResultTcEnv
  (let ([ty : AstType (tc-resolve-type ctx field-ty)])
    (match pattern
      [(AstPatBinding name) (OkTcEnv (tc-bind env name ty))]
      [(AstPatWildcard) (OkTcEnv env)]
      [(AstPatLiteral lit)
        (if (tc-literal-pattern-compatible? lit ty)
          (OkTcEnv env)
          (ErrTcEnv "typecheck: literal pattern type mismatch"))]
      [(AstPatVariant name args)
        (match ty
          [(AstTyEnum enum-name)
            (tc-bind-variant-pattern ctx env enum-name name args)]
          [_ (ErrTcEnv "typecheck: nested variant pattern requires enum field")])]
      [_ (ErrTcEnv "typecheck: unsupported nested match pattern")])))

(define (tc-bind-match-pattern
  [ctx : TcContext]
  [env : TcTypeEnv]
  [scrut-ty : AstType]
  [pattern : AstPattern]) : ResultTcEnv
  (match scrut-ty
    [(AstTyEnum enum-name)
      (match pattern
        [(AstPatWildcard) (OkTcEnv env)]
        [(AstPatBinding variant-name)
          (tc-bind-variant-pattern ctx env enum-name variant-name AstPatternNil)]
        [(AstPatVariant variant-name args)
          (tc-bind-variant-pattern ctx env enum-name variant-name args)]
        [_ (ErrTcEnv "typecheck: unsupported enum match pattern")])]
    [_
      (match pattern
        [(AstPatWildcard) (OkTcEnv env)]
        [(AstPatBinding name) (OkTcEnv (tc-bind env name scrut-ty))]
        [(AstPatLiteral lit)
          (if (tc-literal-pattern-compatible? lit scrut-ty)
            (OkTcEnv env)
            (ErrTcEnv "typecheck: literal pattern type mismatch"))]
        [_
          (ErrTcEnv
            "typecheck: scalar match only supports literal, binding, or wildcard patterns")])]))

(define (tc-match-arm-type
  [ctx : TcContext]
  [env : TcTypeEnv]
  [scrut-ty : AstType]
  [arm : AstMatchArm]) : ResultTcType
  (match arm
    [(AstMatchArm pattern body)
      (match (tc-bind-match-pattern ctx env scrut-ty pattern)
        [(OkTcEnv arm-env) (tc-expr ctx arm-env body)]
        [(ErrTcEnv message) (ErrTcType message)])]))

(define (tc-match-rest-types
  [ctx : TcContext]
  [env : TcTypeEnv]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]
  [want : AstType]) : ResultTcType
  (match arms
    [(AstMatchArmNil) (OkTcType want)]
    [(AstMatchArmCons arm rest)
      (match (tc-match-arm-type ctx env scrut-ty arm)
        [(OkTcType got)
          (if (tc-type-eq got want)
            (tc-match-rest-types ctx env scrut-ty rest want)
            (ErrTcType "typecheck: match arms must agree"))]
        [(ErrTcType message) (ErrTcType message)])]))

(define (tc-check-match-arm-types
  [ctx : TcContext]
  [env : TcTypeEnv]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]) : ResultTcType
  (match arms
    [(AstMatchArmNil) (ErrTcType "typecheck: match must have at least one arm")]
    [(AstMatchArmCons arm rest)
      (match (tc-match-arm-type ctx env scrut-ty arm)
        [(OkTcType first-ty)
          (tc-match-rest-types ctx env scrut-ty rest first-ty)]
        [(ErrTcType message) (ErrTcType message)])]))

(define (tc-enum-has-single-variant?
  [variants : AstVariantDefList]
  [variant-name : String]) : bool
  (match variants
    [(AstVariantDefCons variant rest)
      (match rest
        [(AstVariantDefNil)
          (match variant
            [(AstVariantDef name _) (string-eq name variant-name)])]
        [_ false])]
    [_ false]))

(define (tc-variant-pattern-irrefutable?
  [ctx : TcContext]
  [variant-name : String]
  [args : AstPatternList]) : bool
  (match (compiler-registries-lookup-variant
    (tc-context-registries ctx)
    variant-name)
    [(SomeI64 handle)
      (match (compiler-registries-variant-fields
        (tc-context-program ctx)
        handle)
        [(OkAstTypeList fields)
          (tc-pattern-list-irrefutable?
            ctx
            args
            (tc-resolve-type-list ctx fields))]
        [(ErrAstTypeList _) false])]
    [(NoneI64) false]))

(define (tc-sub-pattern-irrefutable?
  [ctx : TcContext]
  [pattern : AstPattern]
  [field-ty : AstType]) : bool
  (match pattern
    [(AstPatWildcard) true]
    [(AstPatBinding _) true]
    [(AstPatLiteral _) false]
    [(AstPatVariant name args)
      (match (tc-resolve-type ctx field-ty)
        [(AstTyEnum enum-name)
          (match (tc-program-enum-variants (tc-context-program ctx) enum-name)
            [(OkAstVariantDefList variants)
              (if (tc-enum-has-single-variant? variants name)
                (tc-variant-pattern-irrefutable? ctx name args)
                false)]
            [(ErrAstVariantDefList _) false])]
        [_ false])]
    [_ false]))

(define (tc-pattern-list-irrefutable?
  [ctx : TcContext]
  [patterns : AstPatternList]
  [types : AstTypeList]) : bool
  (match patterns
    [(AstPatternNil)
      (match types
        [(AstTypeNil) true]
        [_ false])]
    [(AstPatternCons pattern rest)
      (match types
        [(AstTypeCons ty rest-types)
          (if (tc-sub-pattern-irrefutable? ctx pattern ty)
            (tc-pattern-list-irrefutable? ctx rest rest-types)
            false)]
        [(AstTypeNil) false])]))

(define (tc-pattern-covers-variant?
  [ctx : TcContext]
  [pattern : AstPattern]
  [variant-name : String]) : bool
  (match pattern
    [(AstPatWildcard) true]
    [(AstPatBinding name) (string-eq name variant-name)]
    [(AstPatVariant name args)
      (and
        (string-eq name variant-name)
        (tc-variant-pattern-irrefutable? ctx name args))]
    [_ false]))

(define (tc-match-arms-cover-variant?
  [ctx : TcContext]
  [arms : AstMatchArmList]
  [variant-name : String]) : bool
  (match arms
    [(AstMatchArmNil) false]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm pattern _)
          (if (tc-pattern-covers-variant? ctx pattern variant-name)
            true
            (tc-match-arms-cover-variant? ctx rest variant-name))])]))

(define (tc-enum-variants-covered?
  [ctx : TcContext]
  [variants : AstVariantDefList]
  [arms : AstMatchArmList]) : bool
  (match variants
    [(AstVariantDefNil) true]
    [(AstVariantDefCons variant rest)
      (match variant
        [(AstVariantDef name _)
          (and
            (tc-match-arms-cover-variant? ctx arms name)
            (tc-enum-variants-covered? ctx rest arms))])]))

(define (tc-match-arms-have-catchall? [arms : AstMatchArmList]) : bool
  (match arms
    [(AstMatchArmNil) false]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm pattern _)
          (match pattern
            [(AstPatWildcard) true]
            [(AstPatBinding _) true]
            [_ (tc-match-arms-have-catchall? rest)])])]))

(define (tc-match-arms-cover-bool? [arms : AstMatchArmList] [want : bool]) : bool
  (match arms
    [(AstMatchArmNil) false]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm pattern _)
          (match pattern
            [(AstPatLiteral (AstLitBool value))
              (if (= value want)
                true
                (tc-match-arms-cover-bool? rest want))]
            [_ (tc-match-arms-cover-bool? rest want)])])]))

(define (tc-match-exhaustive?
  [ctx : TcContext]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]) : bool
  (match scrut-ty
    [(AstTyEnum enum-name)
      (match (tc-program-enum-variants (tc-context-program ctx) enum-name)
        [(OkAstVariantDefList variants)
          (tc-enum-variants-covered? ctx variants arms)]
        [(ErrAstVariantDefList _) false])]
    [(AstTyBool)
      (or
        (tc-match-arms-have-catchall? arms)
        (and
          (tc-match-arms-cover-bool? arms true)
          (tc-match-arms-cover-bool? arms false)))]
    [_ (tc-match-arms-have-catchall? arms)]))

(define (tc-match-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]) : ResultTcType
  (match (tc-check-match-arm-types ctx env scrut-ty arms)
    [(OkTcType result-ty)
      (if (tc-match-exhaustive? ctx scrut-ty arms)
        (OkTcType result-ty)
        (ErrTcType "typecheck: non-exhaustive match"))]
    [(ErrTcType message) (ErrTcType message)]))

(define (tc-expr [ctx : TcContext] [env : TcTypeEnv] [expr : AstExpr]) : ResultTcType
  (match expr
    [(AstExprSpanned inner _) (tc-expr ctx env inner)]
    [(AstExprLiteral lit) (OkTcType (tc-literal-type lit))]
    [(AstExprVar name) (tc-lookup env name)]
    [(AstExprAnn inner ty)
      (match (tc-expr ctx env inner)
        [(OkTcType got)
          (match (tc-expect
            got
            (tc-resolve-type ctx ty)
            "typecheck: annotation type mismatch")
            [(OkTcUnit) (OkTcType (tc-resolve-type ctx ty))]
            [(ErrTcUnit message) (ErrTcType message)])]
        [(ErrTcType message) (ErrTcType message)])]
    [(AstExprLet bindings body)
      (match (tc-let-bindings ctx env bindings)
        [(OkTcEnv next-env) (tc-expr ctx next-env body)]
        [(ErrTcEnv message) (ErrTcType message)])]
    [(AstExprLambda params maybe-ret body)
      (let ([lambda-env : TcTypeEnv (tc-bind-params ctx env params)])
        (match (tc-expr ctx lambda-env body)
          [(OkTcType body-ty)
            (match maybe-ret
              [(AstSomeType ret)
                (match (tc-expect
                  body-ty
                  (tc-resolve-type ctx ret)
                  "typecheck: lambda return type mismatch")
                  [(OkTcUnit)
                    (OkTcType
                      (AstTyFunc
                        (tc-param-type-list ctx params)
                        (tc-resolve-type ctx ret)))]
                  [(ErrTcUnit message) (ErrTcType message)])]
              [(AstNoType)
                (OkTcType (AstTyFunc (tc-param-type-list ctx params) body-ty))])]
          [(ErrTcType message) (ErrTcType message)]))]
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
                [(OkTcUnit)
                  (OkTcType (AstTyArray first-ty (tc-expr-list-len exprs)))]
                [(ErrTcUnit message) (ErrTcType message)])]
            [(ErrTcType message) (ErrTcType message)])])]
    [(AstExprMakeArray elem-ty len)
      (let ([elem : AstType (tc-resolve-type ctx elem-ty)])
        (match (tc-expr ctx env len)
          [(OkTcType len-ty)
            (if (tc-integer-type? len-ty)
              (if (tc-dyn-array-elem-supported? elem)
                (OkTcType (AstTyDynArray elem))
                (ErrTcType
                  "typecheck: make-array element type is not supported"))
              (ErrTcType "typecheck: make-array length must be integer"))]
          [(ErrTcType message) (ErrTcType message)]))]
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
                        (match (tc-expect
                          value-ty
                          elem-ty
                          "typecheck: array-set! value type mismatch")
                          [(OkTcUnit) (OkTcType (AstTyUnit))]
                          [(ErrTcUnit message) (ErrTcType message)])]
                      [(ErrTcType message) (ErrTcType message)])]
                  [(AstTyDynArray elem-ty)
                    (match (tc-expr ctx env value)
                      [(OkTcType value-ty)
                        (match (tc-expect
                          value-ty
                          elem-ty
                          "typecheck: array-set! value type mismatch")
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
          (match (tc-expect
            str-ty
            (AstTyString)
            "typecheck: string-ref requires String")
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
          (match (tc-expect
            cond-ty
            (AstTyBool)
            "typecheck: if condition must be bool")
            [(OkTcUnit)
              (match (tc-expr ctx env then-branch)
                [(OkTcType then-ty)
                  (match (tc-expr ctx env else-branch)
                    [(OkTcType else-ty) (tc-merge-branch-type then-ty else-ty)]
                    [(ErrTcType message) (ErrTcType message)])]
                [(ErrTcType message) (ErrTcType message)])]
            [(ErrTcUnit message) (ErrTcType message)])]
        [(ErrTcType message) (ErrTcType message)])]
    [(AstExprSet name value)
      (match (tc-lookup env name)
        [(OkTcType var-ty)
          (match (tc-expr ctx env value)
            [(OkTcType value-ty)
              (match (tc-expect
                value-ty
                var-ty
                "typecheck: assignment type mismatch")
                [(OkTcUnit) (OkTcType (AstTyUnit))]
                [(ErrTcUnit message) (ErrTcType message)])]
            [(ErrTcType message) (ErrTcType message)])]
        [(ErrTcType message) (ErrTcType message)])]
    [(AstExprCast inner ty)
      (match (tc-expr ctx env inner)
        [(OkTcType inner-ty)
          (if (and
            (tc-castable-type? inner-ty)
            (tc-castable-type? (tc-resolve-type ctx ty)))
            (OkTcType (tc-resolve-type ctx ty))
            (ErrTcType
              "typecheck: cast requires integer/char source and target"))]
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
          (match (tc-expect
            cond-ty
            (AstTyBool)
            "typecheck: while condition must be bool")
            [(OkTcUnit)
              (match (tc-expr ctx env body)
                [(OkTcType body-ty)
                  (match (tc-expect
                    body-ty
                    (AstTyUnit)
                    "typecheck: while body must be unit")
                    [(OkTcUnit) (OkTcType (AstTyUnit))]
                    [(ErrTcUnit message) (ErrTcType message)])]
                [(ErrTcType message) (ErrTcType message)])]
            [(ErrTcUnit message) (ErrTcType message)])]
        [(ErrTcType message) (ErrTcType message)])]
    [(AstExprForeach index index-ty start end body)
      (let ([resolved-index-ty : AstType (tc-resolve-type ctx index-ty)])
        (if (tc-integer-type? resolved-index-ty)
          (match (tc-expr ctx env start)
            [(OkTcType start-ty)
              (if (tc-integer-type? start-ty)
                (match (tc-expr ctx env end)
                  [(OkTcType end-ty)
                    (if (tc-integer-type? end-ty)
                      (let ([body-env
                          :
                          TcTypeEnv
                          (tc-bind env index resolved-index-ty)])
                        (match (tc-expr ctx body-env body)
                          [(OkTcType body-ty)
                            (match (tc-expect
                              body-ty
                              (AstTyUnit)
                              "typecheck: foreach body must be unit")
                              [(OkTcUnit) (OkTcType (AstTyUnit))]
                              [(ErrTcUnit message) (ErrTcType message)])]
                          [(ErrTcType message) (ErrTcType message)]))
                      (ErrTcType
                        "typecheck: foreach end expression must be integer"))]
                  [(ErrTcType message) (ErrTcType message)])
                (ErrTcType
                  "typecheck: foreach start expression must be integer"))]
            [(ErrTcType message) (ErrTcType message)])
          (ErrTcType "typecheck: foreach index type must be integer")))]
    [(AstExprMatch scrutinee arms)
      (match (tc-expr ctx env scrutinee)
        [(OkTcType scrut-ty) (tc-match-expr ctx env scrut-ty arms)]
        [(ErrTcType message) (ErrTcType message)])]
    [(AstExprStructGet receiver field)
      (match (tc-expr ctx env receiver)
        [(OkTcType receiver-ty)
          (match receiver-ty
            [(AstTyStruct struct-name)
              (tc-struct-field-type ctx struct-name field)]
            [_ (ErrTcType "typecheck: struct-get requires struct")])]
        [(ErrTcType message) (ErrTcType message)])]
    ;; `(comptime expr)` in expression position yields the inner expression's
    ;; type (#718); compile-time evaluation is reserved for #719.
    [(AstExprComptime inner) (tc-expr ctx env inner)]
    [_ (ErrTcType "typecheck: unsupported expression")]))

(define (tc-summary-add-decl
  [summary : CompilerTypecheckSummary]
  [decl : AstDecl]) : CompilerTypecheckSummary
  (match summary
    [(CompilerTypecheckSummary values functions externs)
      (match decl
        [(AstDeclDef _ _ _)
          (CompilerTypecheckSummary (+ values 1) functions externs)]
        [(AstDeclDefFn _ _ _ _)
          (CompilerTypecheckSummary values (+ functions 1) externs)]
        [(AstDeclExtern _ _)
          (CompilerTypecheckSummary values functions (+ externs 1))]
        [_ summary])]))

(define (tc-check-decl [ctx : TcContext] [top-env : TcTypeEnv] [decl : AstDecl]) : ResultTcUnit
  (match decl
    [(AstDeclDef _ maybe-ty expr)
      (match maybe-ty
        [(AstSomeType want)
          (match (tc-expr ctx top-env expr)
            [(OkTcType got)
              (match (tc-expect
                got
                (tc-resolve-type ctx want)
                "typecheck: value definition type mismatch")
                [(OkTcUnit) OkTcUnit]
                [(ErrTcUnit message) (ErrTcUnit message)])]
            [(ErrTcType message) (ErrTcUnit message)])]
        [(AstNoType)
          (match (tc-expr ctx top-env expr)
            [(OkTcType _) OkTcUnit]
            [(ErrTcType message) (ErrTcUnit message)])])]
    [(AstDeclDefFn _ params ret body)
      (let ([env : TcTypeEnv (tc-bind-params ctx top-env params)])
        (match (tc-expr ctx env body)
          [(OkTcType got)
            (match (tc-expect
              got
              (tc-resolve-type ctx ret)
              "typecheck: return type mismatch")
              [(OkTcUnit) OkTcUnit]
              [(ErrTcUnit message) (ErrTcUnit message)])]
          [(ErrTcType message) (ErrTcUnit message)]))]
    [(AstDeclExtern _ ty)
      (match (tc-resolve-type ctx ty)
        [(AstTyFunc _ _) OkTcUnit]
        [_ (ErrTcUnit "typecheck: extern must have function type")])]
    [_ OkTcUnit]))

(define (tc-check-decls
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [decls : AstDeclList]
  [summary : CompilerTypecheckSummary]) : ResultCompilerTypecheck
  (match decls
    [(AstDeclNil) (OkCompilerTypecheck summary)]
    [(AstDeclCons decl rest)
      (match (tc-check-decl ctx top-env decl)
        [(OkTcUnit)
          (tc-check-decls ctx top-env rest (tc-summary-add-decl summary decl))]
        [(ErrTcUnit message) (ErrCompilerTypecheck (tc-decl-diag decl message))])]))

(define (tc-check-decls-with-paths
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [summary : CompilerTypecheckSummary]) : ResultCompilerTypecheck
  (match decls
    [(AstDeclNil) (OkCompilerTypecheck summary)]
    [(AstDeclCons decl rest)
      (let ([decl-path
          :
          String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) ""])]
        [rest-paths
          :
          AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest) path-rest]
            [(AstDeclPathNil) AstDeclPathNil])])
        (match (tc-check-decl ctx top-env decl)
          [(OkTcUnit)
            (tc-check-decls-with-paths
              ctx
              top-env
              rest
              rest-paths
              (tc-summary-add-decl summary decl))]
          [(ErrTcUnit message)
            (let ([diag : CompilerDiagnostic (tc-decl-diag decl message)])
              (if (string-eq decl-path "")
                (ErrCompilerTypecheck diag)
                (ErrCompilerTypecheck
                  (compiler-diagnostic-with-path diag decl-path))))]))]))

(define (typecheck-compiler-program-with-paths
  [program : AstProgram]
  [paths : AstDeclPathList]) : ResultCompilerTypecheck
  (match (build-compiler-symbols program)
    [(OkCompilerSymbols symbols)
      (match (build-compiler-registries program)
        [(OkCompilerRegistries registries)
          (let ([ctx : TcContext (TcContext program symbols registries)])
            (match (tc-build-top-env ctx program)
              [(OkTcEnv top-env)
                (match program
                  [(AstProgram decls)
                    (tc-check-decls-with-paths
                      ctx
                      top-env
                      decls
                      paths
                      (CompilerTypecheckSummary 0 0 0))])]
              [(ErrTcEnv message)
                (ErrCompilerTypecheck (tc-diag-at-start message))]))]
        [(ErrCompilerRegistries message)
          (ErrCompilerTypecheck (tc-diag-at-start message))])]
    [(ErrCompilerSymbols message)
      (ErrCompilerTypecheck (tc-diag-at-start message))]))

(define (typecheck-compiler-program [program : AstProgram]) : ResultCompilerTypecheck
  (typecheck-compiler-program-with-paths program AstDeclPathNil))

(define (typecheck-compiler-repl-expr [decls : AstDeclList] [expr : AstExpr]) : ResultTcType
  (let ([program : AstProgram (AstProgram decls)])
    (match (build-compiler-symbols program)
      [(OkCompilerSymbols symbols)
        (match (build-compiler-registries program)
          [(OkCompilerRegistries registries)
            (let ([ctx : TcContext (TcContext program symbols registries)])
              (match (tc-build-top-env ctx program)
                [(OkTcEnv top-env)
                  (match (tc-check-decls
                    ctx
                    top-env
                    decls
                    (CompilerTypecheckSummary 0 0 0))
                    [(OkCompilerTypecheck _) (tc-expr ctx top-env expr)]
                    [(ErrCompilerTypecheck diag)
                      (ErrTcType (compiler-diagnostic-message diag))])]
                [(ErrTcEnv message) (ErrTcType message)]))]
          [(ErrCompilerRegistries message) (ErrTcType message)])]
      [(ErrCompilerSymbols message) (ErrTcType message)])))

(define (typecheck-compiler-source [src : String]) : ResultCompilerTypecheck
  (match (parse-ast-source src)
    [(OkAstProgram program) (typecheck-compiler-program program)]
    [(ErrAstProgram message) (ErrCompilerTypecheck (tc-diag-at-start message))]))

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
    [(ErrCompilerTypecheck diag)
      (string-eq (compiler-diagnostic-message diag) want)]
    [(OkCompilerTypecheck _) false]))

(define (compiler-typecheck-ok-score? [src : String] [want : i64]) : bool
  (match (typecheck-compiler-source src)
    [(OkCompilerTypecheck summary)
      (= (compiler-typecheck-summary-score summary) want)]
    [(ErrCompilerTypecheck _) false]))

(define (compiler-typecheck-ok? [src : String]) : bool
  (match (typecheck-compiler-source src)
    [(OkCompilerTypecheck _) true]
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

(define (compiler-typecheck-stdio-source) : String
  "(define (main) : i64
  (begin
    (flush-stdout)
    (if (stdin-eof?)
        (string-length (read-stdin-line))
        (string-length (read-stdin-bytes 3)))))")

(define (compiler-typecheck-tuple-oob-source) : String
  "(define (main) : i64 (tuple-ref (tuple 1 true) 2))")

(define (compiler-typecheck-array-mismatch-source) : String
  "(define bad : (Array i64 2) (array 1 true))")

(define (compiler-typecheck-string-index-source) : String
  "(define (main) : char (string-ref \"hi\" true))")

(define (compiler-typecheck-string-shadow-source) : String
  "(define (string-ref [a : i64] [b : i64]) : i64 (+ a b))
(define (char-at [a : i64] [b : i64]) : i64 (* a b))
(define (main) : i64 (+ (string-ref 10 7) (char-at 3 4)))")

(define (compiler-typecheck-char-range-source) : String
  "(define (is-digit [c : char]) : bool
  (and (>= c #0') (<= c #9')))
(define (main [c : char]) : bool (is-digit c))")

(define (compiler-typecheck-never-branch-source) : String
  "(define (main [flag : bool]) : i64
  (if flag 42 (panic \"stop\")))")

(define (compiler-typecheck-cast-bad-source) : String
  "(define (main) : i64 (cast true : i64))")

(define (compiler-typecheck-foreach-body-source) : String
  "(define (main [n : i64]) : unit
  (foreach ([i : i64 0 n]) i))")

(define (compiler-typecheck-lambda-ret-source) : String
  "(define (main) : (-> i64 i64)
  (lambda ([x : i64]) : i64 true))")

(define (compiler-typecheck-aggregate-tests-ok?) : bool
  (and
    (compiler-typecheck-ok-score? (compiler-typecheck-aggregate-source) 20)
    (and
      (compiler-typecheck-ok-score? (compiler-typecheck-builtin-source) 10)
      (and
        (compiler-typecheck-ok-score? (compiler-typecheck-stdio-source) 10)
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-tuple-oob-source)
            "typecheck: tuple index out of bounds")
          (and
            (compiler-typecheck-error-ok?
              (compiler-typecheck-array-mismatch-source)
              "typecheck: array elements must have same type")
            (and
              (compiler-typecheck-error-ok?
                (compiler-typecheck-string-index-source)
                "typecheck: string index must be integer")
              (and
                (compiler-typecheck-ok-score?
                  (compiler-typecheck-string-shadow-source)
                  30)
                (and
                  (compiler-typecheck-error-ok?
                    (compiler-typecheck-cast-bad-source)
                    "typecheck: cast requires integer/char source and target")
                  (and
                    (compiler-typecheck-ok-score?
                      (compiler-typecheck-char-range-source)
                      20)
                    (and
                      (compiler-typecheck-ok-score?
                        (compiler-typecheck-never-branch-source)
                        10)
                      (and
                        (compiler-typecheck-error-ok?
                          (compiler-typecheck-foreach-body-source)
                          "typecheck: foreach body must be unit")
                        (compiler-typecheck-error-ok?
                          (compiler-typecheck-lambda-ret-source)
                          "typecheck: lambda return type mismatch")))))))))))))

(define (compiler-typecheck-nominal-source) : String
  "(defenum Maybe (None) (Some i64))
(defstruct Point (x i64) (y i64))
(define (from-maybe [m : Maybe]) : i64
  (match m [(Some v) v] [None 0]))
(define (main) : i64
  (let ([p : Point (Point 40 2)])
    (+ (struct-get p x) (from-maybe (Some (struct-get p y))))))")

(define (compiler-typecheck-match-mismatch-source) : String
  "(defenum Maybe (None) (Some i64))
(define (main [m : Maybe]) : i64
  (match m [(Some v) v] [None false]))")

(define (compiler-typecheck-unknown-variant-source) : String
  "(defenum Maybe (None) (Some i64))
(define (main [m : Maybe]) : i64
  (match m [(Other) 1] [_ 0]))")

(define (compiler-typecheck-unknown-field-source) : String
  "(defstruct Point (x i64) (y i64))
(define (main [p : Point]) : i64
  (struct-get p z))")

(define (compiler-typecheck-duplicate-variant-source) : String
  "(defenum Left (Same))
(defenum Right (Same))
(define (main) : i64 0)")

(define (compiler-typecheck-nominal-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-nominal-source))
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-match-mismatch-source)
        "typecheck: match arms must agree")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-unknown-variant-source)
          "typecheck: unknown variant Other")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-unknown-field-source)
            "typecheck: unknown struct field Point.z")
          (compiler-typecheck-error-ok?
            (compiler-typecheck-duplicate-variant-source)
            "symbols: duplicate enum variant Same"))))))

;; A type error whose offending expression (`missing`) is on source line 2, so

;; the diagnostic must locate it there (not at the 1:1 fallback) — proving the

;; typechecker carries the nearest declaration-body `AstExprSpanned` span (#681).

(define (compiler-typecheck-located-fn-source) : String
  "(define (main) : i64
  missing)")

(define (compiler-typecheck-located-value-source) : String
  "(define bad : i64
  missing)")

(define (compiler-typecheck-located-source-ok? [src : String]) : bool
  (match (typecheck-compiler-source src)
    [(ErrCompilerTypecheck diag)
      (if (= (compiler-diagnostic-line diag) 2)
        (if (> (compiler-diagnostic-col diag) 0)
          (string-eq
            (compiler-diagnostic-message diag)
            "typecheck: unbound name missing")
          false)
        false)]
    [(OkCompilerTypecheck _) false]))

(define (compiler-typecheck-located-ok?) : bool
  (and
    (compiler-typecheck-located-source-ok?
      (compiler-typecheck-located-fn-source))
    (compiler-typecheck-located-source-ok?
      (compiler-typecheck-located-value-source))))

(define (compiler-typecheck-self-test) : i64
  (match (typecheck-compiler-source (compiler-typecheck-smoke-source))
    [(OkCompilerTypecheck summary)
      (if (and
        (= (compiler-typecheck-summary-score summary) 121)
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-unbound-source)
            "typecheck: unbound name missing")
          (and
            (compiler-typecheck-error-ok?
              (compiler-typecheck-bad-call-source)
              "typecheck: argument type mismatch")
            (and
              (compiler-typecheck-error-ok?
                (compiler-typecheck-branch-mismatch-source)
                "typecheck: if branches must match")
              (and
                (compiler-typecheck-aggregate-tests-ok?)
                (and
                  (compiler-typecheck-nominal-tests-ok?)
                  (compiler-typecheck-located-ok?)))))))
        42
        (begin
          (panic "typecheck: smoke score mismatch")
          0))]
    [(ErrCompilerTypecheck diag)
      (begin
        (panic (compiler-diagnostic-message diag))
        0)]))