;; compiler_typecheck.tl - First scalar typechecker pass over compiler AstProgram (#426).
(import "compiler_symbols.tl")

(import "compiler_diagnostic.tl")

(import "compiler_ctfe.tl")

(import "compiler_specialize.tl")

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

(defenum TcResultInfo
  (TcResultInfo String String AstType String AstType))

(defenum ResultTcResultInfo
  (OkTcResultInfo TcResultInfo)
  (ErrTcResultInfo String))

(defenum TcMaybeString
  (TcNoString)
  (TcSomeString String))

(defenum TcStringList
  (TcStringNil)
  (TcStringCons String TcStringList))

(defenum ResultTcEnv
  (OkTcEnv TcTypeEnv)
  (ErrTcEnv String))

(defenum ResultTcUnit
  (OkTcUnit)
  (ErrTcUnit String))

(defenum TcSpmdClass
  (TcSpmdUniform)
  (TcSpmdVarying))

(defenum TcSpmdScope
  (TcSpmdOuter)
  (TcSpmdLocal))

(defenum TcSpmdEnv
  (TcSpmdEnvNil)
  (TcSpmdEnvBind String AstType TcSpmdClass TcSpmdScope TcSpmdEnv))

(defenum TcSpmdLookup
  (TcSpmdMissing)
  (TcSpmdFound AstType TcSpmdClass TcSpmdScope))

(defenum TcSpmdExprInfo
  (TcSpmdExprInfo AstType TcSpmdClass TcSpmdEnv))

(defenum ResultTcSpmdExprInfo
  (OkTcSpmdExprInfo TcSpmdExprInfo)
  (ErrTcSpmdExprInfo String))

(defenum TcSpmdLetState
  (TcSpmdLetState TcTypeEnv TcSpmdEnv i64))

(defenum ResultTcSpmdLetState
  (OkTcSpmdLetState TcSpmdLetState)
  (ErrTcSpmdLetState String))

(defenum TcSpmdExprListInfo
  (TcSpmdExprListInfo TcSpmdClass TcSpmdEnv))

(defenum ResultTcSpmdExprListInfo
  (OkTcSpmdExprListInfo TcSpmdExprListInfo)
  (ErrTcSpmdExprListInfo String))

(defenum TcStructDecl
  (TcStructDecl AstStructRepr AstFieldDefList))

(defenum ResultTcStructDecl
  (OkTcStructDecl TcStructDecl)
  (ErrTcStructDecl String))

(defenum TcLayoutInfo
  (TcLayoutInfo i64 i64))

(defenum ResultTcLayoutInfo
  (OkTcLayoutInfo TcLayoutInfo)
  (ErrTcLayoutInfo String))

(defenum TcReprCFieldLayout
  (TcReprCFieldLayout String AstType i64))

(defenum TcReprCFieldLayoutList
  (TcReprCFieldLayoutNil)
  (TcReprCFieldLayoutCons TcReprCFieldLayout TcReprCFieldLayoutList))

(defenum TcReprCLayout
  (TcReprCLayout i64 i64 TcReprCFieldLayoutList))

(defenum ResultTcReprCLayout
  (OkTcReprCLayout TcReprCLayout)
  (ErrTcReprCLayout String))

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
    [(AstDeclTest _ _ span)
      (CompilerDiagnostic
        ""
        (struct-get span start-line)
        (struct-get span start-col)
        message)]
    [(AstDeclComptimeDecl template) (tc-decl-diag template message)]
    [_ (tc-diag-at-start message)]))

(define (tc-empty-env) : TcTypeEnv
  TcTypeNil)

(define (tc-bind [env : TcTypeEnv] [name : String] [ty : AstType]) : TcTypeEnv
  (TcTypeBind name ty env))

(define (tc-bind-alias-if-free [env : TcTypeEnv] [name : String] [ty : AstType]) : TcTypeEnv
  (if (tc-name-bound? env name)
    env
    (tc-bind env name ty)))

(define (tc-bind-module-name
  [env : TcTypeEnv]
  [module : String]
  [name : String]
  [ty : AstType]) : TcTypeEnv
  (let
    [key : String (compiler-symbol-module-key module name)]
    (tc-bind
      (if (string-eq key name)
        env
        (tc-bind-alias-if-free env name ty))
      key
      ty)))

(define (tc-default-boundary-name) : String
  "__tl_default_boundary")

(define (tc-region-marker-name) : String
  "__tl_active_region")

(define (tc-return-type-name) : String
  "__tl_return_type")

(define (tc-bind-return-type [env : TcTypeEnv] [ty : AstType]) : TcTypeEnv
  (tc-bind env (tc-return-type-name) ty))

(define (tc-current-return-type [env : TcTypeEnv]) : ResultTcType
  (match env
    [(TcTypeNil)
      (ErrTcType "typecheck: try requires enclosing Result-like function")]
    [(TcTypeBind key ty rest)
      (if (string-eq key (tc-return-type-name))
        (OkTcType ty)
        (tc-current-return-type rest))]))

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

(define (tc-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (tc-type-list-render [types : AstTypeList]) : String
  (match types
    [(AstTypeNil) ""]
    [(AstTypeCons head rest)
      (string-append
        (tc-type-render head)
        (match rest
          [(AstTypeNil) ""]
          [_ (string-append " " (tc-type-list-render rest))]))]))

(define (tc-type-render [ty : AstType]) : String
  (match ty
    [(AstTyI64) "i64"]
    [(AstTyI32) "i32"]
    [(AstTyI16) "i16"]
    [(AstTyI8) "i8"]
    [(AstTyU64) "u64"]
    [(AstTyU32) "u32"]
    [(AstTyU16) "u16"]
    [(AstTyU8) "u8"]
    [(AstTyF64) "f64"]
    [(AstTyF32) "f32"]
    [(AstTyBool) "bool"]
    [(AstTyChar) "char"]
    [(AstTyString) "String"]
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyFunc args ret)
      (tc-cat3
        "(-> "
        (tc-type-list-render args)
        (string-append " " (string-append (tc-type-render ret) ")")))]
    [(AstTyTuple elems) (tc-cat3 "(Tuple " (tc-type-list-render elems) ")")]
    [(AstTyArray elem count)
      (tc-cat3
        "(Array "
        (tc-type-render elem)
        (tc-cat3 " " (int->string count) ")"))]
    [(AstTyDynArray elem) (tc-cat3 "(Array " (tc-type-render elem) ")")]
    [(AstTyPtr elem) (tc-cat3 "(Ptr " (tc-type-render elem) ")")]
    [(AstTyMutPtr elem) (tc-cat3 "(MutPtr " (tc-type-render elem) ")")]
    [(AstTyRef region inner)
      (tc-cat3
        "(& "
        region
        (string-append " " (string-append (tc-type-render inner) ")")))]
    [(AstTyMutRef region inner)
      (tc-cat3
        "(&mut "
        region
        (string-append " " (string-append (tc-type-render inner) ")")))]
    [(AstTyRegion region inner)
      (tc-cat3
        "(Region "
        region
        (string-append " " (string-append (tc-type-render inner) ")")))]
    [(AstTyEnum name) name]
    [(AstTyStruct name) name]
    [(AstTyVar name) name]))

(define (tc-default-env) : TcTypeEnv
  (let
    [e0 : TcTypeEnv (tc-empty-env)]
    (let
      [e1 : TcTypeEnv (tc-bind e0 "print" (tc-fn1 (AstTyI64) (AstTyUnit)))]
      (let
        [e2 : TcTypeEnv
          (tc-bind e1 "print-bool" (tc-fn1 (AstTyBool) (AstTyUnit)))]
        (let
          [e3 : TcTypeEnv
            (tc-bind e2 "print-float" (tc-fn1 (AstTyF64) (AstTyUnit)))]
          (let
            [e4 : TcTypeEnv
              (tc-bind e3 "print-char" (tc-fn1 (AstTyChar) (AstTyUnit)))]
            (let
              [e5 : TcTypeEnv (tc-bind e4 "print-newline" (tc-fn0 (AstTyUnit)))]
              (let
                [e6 : TcTypeEnv
                  (tc-bind e5 "print-string" (tc-fn1 (AstTyString) (AstTyUnit)))]
                (let
                  [e7 : TcTypeEnv
                    (tc-bind e6 "print-str" (tc-fn1 (AstTyString) (AstTyUnit)))]
                  (let
                    [e8 : TcTypeEnv
                      (tc-bind
                        e7
                        "print-error"
                        (tc-fn1 (AstTyString) (AstTyUnit)))]
                    (let
                      [e9 : TcTypeEnv
                        (tc-bind e8 "arg-count" (tc-fn0 (AstTyI64)))]
                      (let
                        [e10 : TcTypeEnv
                          (tc-bind e9 "arg" (tc-fn1 (AstTyI64) (AstTyString)))]
                        (let
                          [e11 : TcTypeEnv
                            (tc-bind
                              e10
                              "string-length"
                              (tc-fn1 (AstTyString) (AstTyI64)))]
                          (let
                            [e12 : TcTypeEnv
                              (tc-bind
                                e11
                                "length"
                                (tc-fn1 (AstTyString) (AstTyI64)))]
                            (let
                              [e13 : TcTypeEnv
                                (tc-bind
                                  e12
                                  "string-eq"
                                  (tc-fn2
                                    (AstTyString)
                                    (AstTyString)
                                    (AstTyBool)))]
                              (let
                                [e14 : TcTypeEnv
                                  (tc-bind
                                    e13
                                    "string=?"
                                    (tc-fn2
                                      (AstTyString)
                                      (AstTyString)
                                      (AstTyBool)))]
                                (let
                                  [e15 : TcTypeEnv
                                    (tc-bind
                                      e14
                                      "string->int"
                                      (tc-fn1 (AstTyString) (AstTyI64)))]
                                  (let
                                    [e16 : TcTypeEnv
                                      (tc-bind
                                        e15
                                        "int->string"
                                        (tc-fn1 (AstTyI64) (AstTyString)))]
                                    (let
                                      [e17 : TcTypeEnv
                                        (tc-bind
                                          e16
                                          "read-file"
                                          (tc-fn1 (AstTyString) (AstTyString)))]
                                      (let
                                        [e18 : TcTypeEnv
                                          (tc-bind
                                            (tc-bind
                                              (tc-bind
                                                (tc-bind
                                                  e17
                                                  "read-file-status"
                                                  (tc-fn1
                                                    (AstTyString)
                                                    (AstTyI64)))
                                                "write-file"
                                                (tc-fn2
                                                  (AstTyString)
                                                  (AstTyString)
                                                  (AstTyUnit)))
                                              "write-file-status"
                                              (tc-fn2
                                                (AstTyString)
                                                (AstTyString)
                                                (AstTyI64)))
                                            "append-file-status"
                                            (tc-fn2
                                              (AstTyString)
                                              (AstTyString)
                                              (AstTyI64)))]
                                        (let
                                          [e19 : TcTypeEnv
                                            (tc-bind
                                              (tc-bind
                                                (tc-bind
                                                  (tc-bind
                                                    (tc-bind
                                                      (tc-bind
                                                        (tc-bind
                                                          (tc-bind
                                                            e18
                                                            "file-exists?"
                                                            (tc-fn1
                                                              (AstTyString)
                                                              (AstTyBool)))
                                                          "file-exists-status"
                                                          (tc-fn1
                                                            (AstTyString)
                                                            (AstTyI64)))
                                                        "file-open-status"
                                                        (tc-fn2
                                                          (AstTyString)
                                                          (AstTyI64)
                                                          (AstTyI64)))
                                                      "file-close-status"
                                                      (tc-fn1
                                                        (AstTyI64)
                                                        (AstTyI64)))
                                                    "fs-mkdir-status"
                                                    (tc-fn1
                                                      (AstTyString)
                                                      (AstTyI64)))
                                                  "fs-remove-file-status"
                                                  (tc-fn1
                                                    (AstTyString)
                                                    (AstTyI64)))
                                                "fs-remove-dir-status"
                                                (tc-fn1
                                                  (AstTyString)
                                                  (AstTyI64)))
                                              "fs-process-id"
                                              (tc-fn0 (AstTyI64)))]
                                          (let
                                            [e20 : TcTypeEnv
                                              (tc-bind
                                                (tc-bind
                                                  (tc-bind
                                                    e19
                                                    "cpuid"
                                                    (tc-fn2
                                                      (AstTyI64)
                                                      (AstTyI64)
                                                      (AstTyTuple
                                                        (AstTypeCons
                                                          (AstTyI32)
                                                          (AstTypeCons
                                                            (AstTyI32)
                                                            (AstTypeCons
                                                              (AstTyI32)
                                                              (AstTypeCons
                                                                (AstTyI32)
                                                                (AstTypeNil))))))))
                                                  "xgetbv"
                                                  (tc-fn1 (AstTyI64) (AstTyI64)))
                                                "substring"
                                                (tc-fn3
                                                  (AstTyString)
                                                  (AstTyI64)
                                                  (AstTyI64)
                                                  (AstTyString)))]
                                            (let
                                              [e21 : TcTypeEnv
                                                (tc-bind
                                                  e20
                                                  "string-slice"
                                                  (tc-fn3
                                                    (AstTyString)
                                                    (AstTyI64)
                                                    (AstTyI64)
                                                    (AstTyString)))]
                                              (let
                                                [e22 : TcTypeEnv
                                                  (tc-bind
                                                    e21
                                                    "string-append"
                                                    (tc-fn2
                                                      (AstTyString)
                                                      (AstTyString)
                                                      (AstTyString)))]
                                                (let
                                                  [e23 : TcTypeEnv
                                                    (tc-bind
                                                      e22
                                                      "string-concat"
                                                      (tc-fn2
                                                        (AstTyString)
                                                        (AstTyString)
                                                        (AstTyString)))]
                                                  (let
                                                    [e24 : TcTypeEnv
                                                      (tc-bind
                                                        e23
                                                        "read-stdin-line"
                                                        (tc-fn0 (AstTyString)))]
                                                    (let
                                                      [e25 : TcTypeEnv
                                                        (tc-bind
                                                          e24
                                                          "read-stdin-bytes"
                                                          (tc-fn1
                                                            (AstTyI64)
                                                            (AstTyString)))]
                                                      (let
                                                        [e26 : TcTypeEnv
                                                          (tc-bind
                                                            e25
                                                            "stdin-eof?"
                                                            (tc-fn0 (AstTyBool)))]
                                                        (let
                                                          [e27 : TcTypeEnv
                                                            (tc-bind
                                                              e26
                                                              "flush-stdout"
                                                              (tc-fn0
                                                                (AstTyUnit)))]
                                                          (let
                                                            [e28 : TcTypeEnv
                                                              (tc-bind
                                                                e27
                                                                "panic"
                                                                (tc-fn1
                                                                  (AstTyString)
                                                                  (AstTyNever)))]
                                                            (tc-bind
                                                              (tc-bind
                                                                (tc-bind
                                                                  (tc-bind
                                                                    (tc-bind
                                                                      e28
                                                                      "error"
                                                                      (tc-fn1
                                                                        (AstTyString)
                                                                        (AstTyNever)))
                                                                    "env-var-exists?"
                                                                    (tc-fn1
                                                                      (AstTyString)
                                                                      (AstTyBool)))
                                                                  "env-var-value"
                                                                  (tc-fn1
                                                                    (AstTyString)
                                                                    (AstTyString)))
                                                                "env-path-separator"
                                                                (tc-fn0
                                                                  (AstTyString)))
                                                              (tc-default-boundary-name)
                                                              (AstTyUnit))))))))))))))))))))))))))))))))

(define (tc-lookup [env : TcTypeEnv] [name : String]) : ResultTcType
  (match env
    [(TcTypeNil) (ErrTcType (string-append "typecheck: unbound name " name))]
    [(TcTypeBind key ty rest)
      (if (string-eq key name)
        (OkTcType ty)
        (tc-lookup rest name))]))

(define (tc-active-region [env : TcTypeEnv]) : TcMaybeString
  (match env
    [(TcTypeNil) (TcNoString)]
    [(TcTypeBind key ty rest)
      (if (string-eq key (tc-region-marker-name))
        (match ty
          [(AstTyVar region) (TcSomeString region)]
          [_ (tc-active-region rest)])
        (tc-active-region rest))]))

(define (tc-push-region [env : TcTypeEnv] [region : String]) : TcTypeEnv
  (tc-bind env (tc-region-marker-name) (AstTyVar region)))

(define (tc-string-list-contains [items : TcStringList] [name : String]) : bool
  (match items
    [(TcStringNil) false]
    [(TcStringCons item rest)
      (if (string-eq item name)
        true
        (tc-string-list-contains rest name))]))

(define (tc-string-list-add [items : TcStringList] [name : String]) : TcStringList
  (if (tc-string-list-contains items name)
    items
    (TcStringCons name items)))

(define (tc-string-list-eq [a : TcStringList] [b : TcStringList]) : bool
  (match a
    [(TcStringNil)
      (match b
        [(TcStringNil) true]
        [_ false])]
    [(TcStringCons item rest)
      (and (tc-string-list-contains b item) (tc-string-list-eq rest b))]))

(define (tc-type-strip-region [ty : AstType]) : AstType
  (match ty
    [(AstTyRegion _ inner) (tc-type-strip-region inner)]
    [_ ty]))

(define (tc-type-list-without-regions [types : AstTypeList]) : AstTypeList
  (match types
    [(AstTypeNil) AstTypeNil]
    [(AstTypeCons head tail)
      (AstTypeCons
        (tc-type-without-regions head)
        (tc-type-list-without-regions tail))]))

(define (tc-type-without-regions [ty : AstType]) : AstType
  (match ty
    [(AstTyFunc args ret)
      (AstTyFunc
        (tc-type-list-without-regions args)
        (tc-type-without-regions ret))]
    [(AstTyTuple elems) (AstTyTuple (tc-type-list-without-regions elems))]
    [(AstTyArray elem len) (AstTyArray (tc-type-without-regions elem) len)]
    [(AstTyDynArray elem) (AstTyDynArray (tc-type-without-regions elem))]
    [(AstTyPtr elem) (AstTyPtr (tc-type-without-regions elem))]
    [(AstTyMutPtr elem) (AstTyMutPtr (tc-type-without-regions elem))]
    [(AstTyRef region inner) (AstTyRef region (tc-type-without-regions inner))]
    [(AstTyMutRef region inner)
      (AstTyMutRef region (tc-type-without-regions inner))]
    [(AstTyRegion _ inner) (tc-type-without-regions inner)]
    [_ ty]))

(define (tc-type-list-contains-region [types : AstTypeList] [region : String]) : bool
  (match types
    [(AstTypeNil) false]
    [(AstTypeCons head tail)
      (or
        (tc-type-contains-region head region)
        (tc-type-list-contains-region tail region))]))

(define (tc-type-contains-region [ty : AstType] [region : String]) : bool
  (match ty
    [(AstTyFunc args ret)
      (or
        (tc-type-list-contains-region args region)
        (tc-type-contains-region ret region))]
    [(AstTyTuple elems) (tc-type-list-contains-region elems region)]
    [(AstTyArray elem _) (tc-type-contains-region elem region)]
    [(AstTyDynArray elem) (tc-type-contains-region elem region)]
    [(AstTyPtr elem) (tc-type-contains-region elem region)]
    [(AstTyMutPtr elem) (tc-type-contains-region elem region)]
    [(AstTyRef name inner)
      (or (string-eq name region) (tc-type-contains-region inner region))]
    [(AstTyMutRef name inner)
      (or (string-eq name region) (tc-type-contains-region inner region))]
    [(AstTyRegion name inner)
      (or (string-eq name region) (tc-type-contains-region inner region))]
    [_ false]))

(define (tc-type-list-contains-any-region [types : AstTypeList]) : bool
  (match types
    [(AstTypeNil) false]
    [(AstTypeCons head tail)
      (or
        (tc-type-contains-any-region head)
        (tc-type-list-contains-any-region tail))]))

(define (tc-type-contains-any-region [ty : AstType]) : bool
  (match ty
    [(AstTyFunc args ret)
      (or
        (tc-type-list-contains-any-region args)
        (tc-type-contains-any-region ret))]
    [(AstTyTuple elems) (tc-type-list-contains-any-region elems)]
    [(AstTyArray elem _) (tc-type-contains-any-region elem)]
    [(AstTyDynArray elem) (tc-type-contains-any-region elem)]
    [(AstTyPtr elem) (tc-type-contains-any-region elem)]
    [(AstTyMutPtr elem) (tc-type-contains-any-region elem)]
    [(AstTyRef _ _) true]
    [(AstTyMutRef _ _) true]
    [(AstTyRegion _ _) true]
    [_ false]))

(define (tc-type-list-collect-regions
  [types : AstTypeList]
  [out : TcStringList]) : TcStringList
  (match types
    [(AstTypeNil) out]
    [(AstTypeCons head tail)
      (tc-type-list-collect-regions
        tail
        (tc-type-collect-regions-into head out))]))

(define (tc-type-collect-regions-into [ty : AstType] [out : TcStringList]) : TcStringList
  (match ty
    [(AstTyFunc args ret)
      (tc-type-collect-regions-into ret (tc-type-list-collect-regions args out))]
    [(AstTyTuple elems) (tc-type-list-collect-regions elems out)]
    [(AstTyArray elem _) (tc-type-collect-regions-into elem out)]
    [(AstTyDynArray elem) (tc-type-collect-regions-into elem out)]
    [(AstTyPtr elem) (tc-type-collect-regions-into elem out)]
    [(AstTyMutPtr elem) (tc-type-collect-regions-into elem out)]
    [(AstTyRef name inner)
      (tc-type-collect-regions-into inner (tc-string-list-add out name))]
    [(AstTyMutRef name inner)
      (tc-type-collect-regions-into inner (tc-string-list-add out name))]
    [(AstTyRegion name inner)
      (tc-type-collect-regions-into inner (tc-string-list-add out name))]
    [_ out]))

(define (tc-type-collect-regions [ty : AstType]) : TcStringList
  (tc-type-collect-regions-into ty TcStringNil))

(define (tc-type-outer-region [ty : AstType]) : TcMaybeString
  (match ty
    [(AstTyRegion region _) (TcSomeString region)]
    [_ (TcNoString)]))

(define (tc-region-taggable-type? [ty : AstType]) : bool
  (match (tc-type-strip-region ty)
    [(AstTyString) true]
    [(AstTyDynArray _) true]
    [(AstTyTuple _) true]
    [(AstTyStruct _) true]
    [(AstTyEnum _) true]
    [_ false]))

(define (tc-tag-region [region : String] [ty : AstType]) : AstType
  (if (tc-region-taggable-type? ty)
    (AstTyRegion region ty)
    ty))

(define (tc-tag-active-region [env : TcTypeEnv] [ty : AstType]) : AstType
  (match (tc-active-region env)
    [(TcSomeString region) (tc-tag-region region ty)]
    [(TcNoString) ty]))

(define (tc-project-from-region-container
  [container-ty : AstType]
  [projected-ty : AstType]) : AstType
  (match (tc-type-outer-region container-ty)
    [(TcSomeString region) (tc-tag-region region projected-ty)]
    [(TcNoString) projected-ty]))

(define (tc-region-outlives-or-matches
  [env : TcTypeEnv]
  [value-region : String]
  [target-region : String]) : bool
  (if (string-eq value-region target-region)
    true
    (match env
      [(TcTypeNil) false]
      [(TcTypeBind key ty rest)
        (if (string-eq key (tc-region-marker-name))
          (match ty
            [(AstTyVar region)
              (if (string-eq region value-region)
                false
                (if (string-eq region target-region)
                  true
                  (tc-region-outlives-or-matches
                    rest
                    value-region
                    target-region)))]
            [_ (tc-region-outlives-or-matches rest value-region target-region)])
          (tc-region-outlives-or-matches rest value-region target-region))])))

(define (tc-region-can-flow-into-any
  [env : TcTypeEnv]
  [value-region : String]
  [target-regions : TcStringList]) : bool
  (match target-regions
    [(TcStringNil) false]
    [(TcStringCons target rest)
      (if (tc-region-outlives-or-matches env value-region target)
        true
        (tc-region-can-flow-into-any env value-region rest))]))

(define (tc-region-list-can-flow-into
  [env : TcTypeEnv]
  [value-regions : TcStringList]
  [target-regions : TcStringList]) : bool
  (match value-regions
    [(TcStringNil) true]
    [(TcStringCons value rest)
      (and
        (tc-region-can-flow-into-any env value target-regions)
        (tc-region-list-can-flow-into env rest target-regions))]))

(define (tc-ensure-region-value-can-flow-into
  [env : TcTypeEnv]
  [target-ty : AstType]
  [value-ty : AstType]
  [context : String]) : ResultTcUnit
  (let
    [value-regions : TcStringList (tc-type-collect-regions value-ty)]
    (match value-regions
      [(TcStringNil) OkTcUnit]
      [_
        (let
          [target-regions : TcStringList (tc-type-collect-regions target-ty)]
          (if (and
            (tc-type-contains-any-region target-ty)
            (tc-region-list-can-flow-into env value-regions target-regions))
            OkTcUnit
            (ErrTcUnit
              (string-append
                "typecheck: cannot store region-tagged value into "
                (string-append context "; region value would escape")))))])))

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
    [(AstTyPtr elem) (AstTyPtr (tc-resolve-type ctx elem))]
    [(AstTyMutPtr elem) (AstTyMutPtr (tc-resolve-type ctx elem))]
    [(AstTyRef region inner) (AstTyRef region (tc-resolve-type ctx inner))]
    [(AstTyMutRef region inner)
      (AstTyMutRef region (tc-resolve-type ctx inner))]
    [(AstTyRegion region inner)
      (AstTyRegion region (tc-resolve-type ctx inner))]
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

(define (tc-source-type-policy-message [name : String]) : String
  (string-append
    "typecheck: unknown type "
    (string-append
      name
      "; TypeLisp has no source-level type parameters; use comptime-generated concrete declarations instead (#893/#913/#483)")))

(define (tc-source-type-list-policy-ok [ctx : TcContext] [types : AstTypeList]) : ResultTcUnit
  (match types
    [(AstTypeNil) OkTcUnit]
    [(AstTypeCons head tail)
      (match (tc-source-type-policy-ok ctx head)
        [(OkTcUnit) (tc-source-type-list-policy-ok ctx tail)]
        [(ErrTcUnit message) (ErrTcUnit message)])]))

(define (tc-source-type-policy-ok [ctx : TcContext] [ty : AstType]) : ResultTcUnit
  (match (tc-resolve-type ctx ty)
    [(AstTyFunc args ret)
      (match (tc-source-type-list-policy-ok ctx args)
        [(OkTcUnit) (tc-source-type-policy-ok ctx ret)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstTyTuple elems) (tc-source-type-list-policy-ok ctx elems)]
    [(AstTyArray elem _) (tc-source-type-policy-ok ctx elem)]
    [(AstTyDynArray elem) (tc-source-type-policy-ok ctx elem)]
    [(AstTyPtr elem) (tc-source-type-policy-ok ctx elem)]
    [(AstTyMutPtr elem) (tc-source-type-policy-ok ctx elem)]
    [(AstTyRef _ inner)
      (match (tc-source-type-policy-ok ctx inner)
        [(OkTcUnit)
          (ErrTcUnit
            "typecheck: reference types require borrow checker support (#803/#806/#804)")]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstTyMutRef _ inner)
      (match (tc-source-type-policy-ok ctx inner)
        [(OkTcUnit)
          (ErrTcUnit
            "typecheck: reference types require borrow checker support (#803/#806/#804)")]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstTyRegion _ inner) (tc-source-type-policy-ok ctx inner)]
    [(AstTyVar name) (ErrTcUnit (tc-source-type-policy-message name))]
    [_ OkTcUnit]))

(define (tc-source-maybe-type-policy-ok
  [ctx : TcContext]
  [maybe-ty : AstMaybeType]) : ResultTcUnit
  (match maybe-ty
    [(AstNoType) OkTcUnit]
    [(AstSomeType ty) (tc-source-type-policy-ok ctx ty)]))

(define (tc-source-param-list-policy-ok
  [ctx : TcContext]
  [params : AstParamList]) : ResultTcUnit
  (match params
    [(AstParamNil) OkTcUnit]
    [(AstParamCons param rest)
      (match param
        [(AstParam _ ty _)
          (match (tc-source-type-policy-ok ctx ty)
            [(OkTcUnit) (tc-source-param-list-policy-ok ctx rest)]
            [(ErrTcUnit message) (ErrTcUnit message)])])]))

(define (tc-source-field-list-policy-ok
  [ctx : TcContext]
  [fields : AstFieldDefList]) : ResultTcUnit
  (match fields
    [(AstFieldDefNil) OkTcUnit]
    [(AstFieldDefCons field rest)
      (match field
        [(AstFieldDef _ ty)
          (match (tc-source-type-policy-ok ctx ty)
            [(OkTcUnit) (tc-source-field-list-policy-ok ctx rest)]
            [(ErrTcUnit message) (ErrTcUnit message)])])]))

(define (tc-source-variant-list-policy-ok
  [ctx : TcContext]
  [variants : AstVariantDefList]) : ResultTcUnit
  (match variants
    [(AstVariantDefNil) OkTcUnit]
    [(AstVariantDefCons variant rest)
      (match variant
        [(AstVariantDef _ fields)
          (match (tc-source-type-list-policy-ok ctx fields)
            [(OkTcUnit) (tc-source-variant-list-policy-ok ctx rest)]
            [(ErrTcUnit message) (ErrTcUnit message)])])]))

(define (tc-source-pattern-list-policy-ok
  [ctx : TcContext]
  [patterns : AstPatternList]) : ResultTcUnit
  (match patterns
    [(AstPatternNil) OkTcUnit]
    [(AstPatternCons pattern rest)
      (match (tc-source-pattern-policy-ok ctx pattern)
        [(OkTcUnit) (tc-source-pattern-list-policy-ok ctx rest)]
        [(ErrTcUnit message) (ErrTcUnit message)])]))

(define (tc-source-pattern-policy-ok [ctx : TcContext] [pattern : AstPattern]) : ResultTcUnit
  (match pattern
    [(AstPatVar _ maybe-ty) (tc-source-maybe-type-policy-ok ctx maybe-ty)]
    [(AstPatTuple patterns) (tc-source-pattern-list-policy-ok ctx patterns)]
    [(AstPatVariant _ patterns) (tc-source-pattern-list-policy-ok ctx patterns)]
    [_ OkTcUnit]))

(define (tc-source-match-arm-list-policy-ok
  [ctx : TcContext]
  [arms : AstMatchArmList]) : ResultTcUnit
  (match arms
    [(AstMatchArmNil) OkTcUnit]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm pattern body)
          (match (tc-source-pattern-policy-ok ctx pattern)
            [(OkTcUnit)
              (match (tc-source-expr-policy-ok ctx body)
                [(OkTcUnit) (tc-source-match-arm-list-policy-ok ctx rest)]
                [(ErrTcUnit message) (ErrTcUnit message)])]
            [(ErrTcUnit message) (ErrTcUnit message)])])]))

(define (tc-source-let-binding-list-policy-ok
  [ctx : TcContext]
  [bindings : AstLetBindingList]) : ResultTcUnit
  (match bindings
    [(AstLetBindingNil) OkTcUnit]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding _ maybe-ty init)
          (match (tc-source-maybe-type-policy-ok ctx maybe-ty)
            [(OkTcUnit)
              (match (tc-source-expr-policy-ok ctx init)
                [(OkTcUnit) (tc-source-let-binding-list-policy-ok ctx rest)]
                [(ErrTcUnit message) (ErrTcUnit message)])]
            [(ErrTcUnit message) (ErrTcUnit message)])])]))

(define (tc-source-expr-list-policy-ok [ctx : TcContext] [exprs : AstExprList]) : ResultTcUnit
  (match exprs
    [(AstExprNil) OkTcUnit]
    [(AstExprCons expr rest)
      (match (tc-source-expr-policy-ok ctx expr)
        [(OkTcUnit) (tc-source-expr-list-policy-ok ctx rest)]
        [(ErrTcUnit message) (ErrTcUnit message)])]))

(define (tc-source-expr-pair-policy-ok
  [ctx : TcContext]
  [left : AstExpr]
  [right : AstExpr]) : ResultTcUnit
  (match (tc-source-expr-policy-ok ctx left)
    [(OkTcUnit) (tc-source-expr-policy-ok ctx right)]
    [(ErrTcUnit message) (ErrTcUnit message)]))

(define (tc-source-expr-triple-policy-ok
  [ctx : TcContext]
  [first : AstExpr]
  [second : AstExpr]
  [third : AstExpr]) : ResultTcUnit
  (match (tc-source-expr-pair-policy-ok ctx first second)
    [(OkTcUnit) (tc-source-expr-policy-ok ctx third)]
    [(ErrTcUnit message) (ErrTcUnit message)]))

(define (tc-source-expr-policy-ok [ctx : TcContext] [expr : AstExpr]) : ResultTcUnit
  (match expr
    [(AstExprSpanned inner _) (tc-source-expr-policy-ok ctx inner)]
    [(AstExprBinary _ left right)
      (tc-source-expr-pair-policy-ok ctx left right)]
    [(AstExprUnary _ inner) (tc-source-expr-policy-ok ctx inner)]
    [(AstExprCall func args)
      (match (tc-source-expr-policy-ok ctx func)
        [(OkTcUnit) (tc-source-expr-list-policy-ok ctx args)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstExprTypeLiteral ty) (tc-source-type-policy-ok ctx ty)]
    [(AstExprIf cond then-branch else-branch)
      (tc-source-expr-triple-policy-ok ctx cond then-branch else-branch)]
    [(AstExprLet bindings body)
      (match (tc-source-let-binding-list-policy-ok ctx bindings)
        [(OkTcUnit) (tc-source-expr-policy-ok ctx body)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstExprLambda params maybe-ret body)
      (match (tc-source-param-list-policy-ok ctx params)
        [(OkTcUnit)
          (match (tc-source-maybe-type-policy-ok ctx maybe-ret)
            [(OkTcUnit) (tc-source-expr-policy-ok ctx body)]
            [(ErrTcUnit message) (ErrTcUnit message)])]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstExprTuple exprs) (tc-source-expr-list-policy-ok ctx exprs)]
    [(AstExprTupleRef tuple _) (tc-source-expr-policy-ok ctx tuple)]
    [(AstExprArray exprs) (tc-source-expr-list-policy-ok ctx exprs)]
    [(AstExprMakeArray elem-ty len)
      (match (tc-source-type-policy-ok ctx elem-ty)
        [(OkTcUnit) (tc-source-expr-policy-ok ctx len)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstExprArrayRef array index)
      (tc-source-expr-pair-policy-ok ctx array index)]
    [(AstExprArraySet array index value)
      (tc-source-expr-triple-policy-ok ctx array index value)]
    [(AstExprStringRef str index) (tc-source-expr-pair-policy-ok ctx str index)]
    [(AstExprWhile cond body) (tc-source-expr-pair-policy-ok ctx cond body)]
    [(AstExprBegin exprs) (tc-source-expr-list-policy-ok ctx exprs)]
    [(AstExprUnsafe exprs) (tc-source-expr-list-policy-ok ctx exprs)]
    [(AstExprSet _ value) (tc-source-expr-policy-ok ctx value)]
    [(AstExprAnn inner ty)
      (match (tc-source-expr-policy-ok ctx inner)
        [(OkTcUnit) (tc-source-type-policy-ok ctx ty)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstExprCast inner ty)
      (match (tc-source-expr-policy-ok ctx inner)
        [(OkTcUnit) (tc-source-type-policy-ok ctx ty)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstExprMatch scrutinee arms)
      (match (tc-source-expr-policy-ok ctx scrutinee)
        [(OkTcUnit) (tc-source-match-arm-list-policy-ok ctx arms)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstExprForeach _ index-ty start end body)
      (match (tc-source-type-policy-ok ctx index-ty)
        [(OkTcUnit) (tc-source-expr-triple-policy-ok ctx start end body)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstExprSpmdReduce _ _ index-ty start end init value)
      (match (tc-source-type-policy-ok ctx index-ty)
        [(OkTcUnit)
          (match (tc-source-expr-triple-policy-ok ctx start end init)
            [(OkTcUnit) (tc-source-expr-policy-ok ctx value)]
            [(ErrTcUnit message) (ErrTcUnit message)])]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstExprStructGet receiver _) (tc-source-expr-policy-ok ctx receiver)]
    [(AstExprWithRegion _ body) (tc-source-expr-list-policy-ok ctx body)]
    [(AstExprComptime inner) (tc-source-expr-policy-ok ctx inner)]
    [(AstExprTry inner) (tc-source-expr-policy-ok ctx inner)]
    [(AstExprPtrNullCheck inner) (tc-source-expr-policy-ok ctx inner)]
    [_ OkTcUnit]))

(define (tc-source-decl-policy-ok [ctx : TcContext] [decl : AstDecl]) : ResultTcUnit
  (match decl
    [(AstDeclDef _ maybe-ty expr)
      (match (tc-source-maybe-type-policy-ok ctx maybe-ty)
        [(OkTcUnit) (tc-source-expr-policy-ok ctx expr)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstDeclDefFn _ params ret body)
      (match (tc-source-param-list-policy-ok ctx params)
        [(OkTcUnit)
          (match (tc-source-type-policy-ok ctx ret)
            [(OkTcUnit) (tc-source-expr-policy-ok ctx body)]
            [(ErrTcUnit message) (ErrTcUnit message)])]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstDeclExtern _ ty) (tc-source-type-policy-ok ctx ty)]
    [(AstDeclDefEnum _ variants)
      (tc-source-variant-list-policy-ok ctx variants)]
    [(AstDeclDefStruct name repr fields)
      (match (tc-source-field-list-policy-ok ctx fields)
        [(OkTcUnit)
          (if (ast-struct-repr-c? repr)
            (match (tc-repr-c-struct-layout ctx name)
              [(OkTcReprCLayout _) OkTcUnit]
              [(ErrTcReprCLayout message) (ErrTcUnit message)])
            OkTcUnit)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstDeclImport _) OkTcUnit]
    [(AstDeclModule _) OkTcUnit]
    [(AstDeclTest _ body _) (tc-source-expr-policy-ok ctx body)]
    [(AstDeclComptimeDecl template) (tc-source-decl-policy-ok ctx template)]))

(define (tc-source-decl-list-policy-ok [ctx : TcContext] [decls : AstDeclList]) : ResultTcUnit
  (match decls
    [(AstDeclNil) OkTcUnit]
    [(AstDeclCons decl rest)
      (match (tc-source-decl-policy-ok ctx decl)
        [(OkTcUnit) (tc-source-decl-list-policy-ok ctx rest)]
        [(ErrTcUnit message) (ErrTcUnit message)])]))

(define (tc-program-source-types-policy-ok
  [ctx : TcContext]
  [program : AstProgram]) : ResultTcUnit
  (match program
    [(AstProgram decls) (tc-source-decl-list-policy-ok ctx decls)]))

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

(define (tc-type-eq-core [a : AstType] [b : AstType]) : bool
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
    [(AstTyPtr a-elem)
      (match b
        [(AstTyPtr b-elem) (tc-type-eq a-elem b-elem)]
        [_ false])]
    [(AstTyMutPtr a-elem)
      (match b
        [(AstTyMutPtr b-elem) (tc-type-eq a-elem b-elem)]
        [_ false])]
    [(AstTyRef a-region a-inner)
      (match b
        [(AstTyRef b-region b-inner)
          (and (string-eq a-region b-region) (tc-type-eq a-inner b-inner))]
        [_ false])]
    [(AstTyMutRef a-region a-inner)
      (match b
        [(AstTyMutRef b-region b-inner)
          (and (string-eq a-region b-region) (tc-type-eq a-inner b-inner))]
        [_ false])]
    [(AstTyRegion _ inner)
      (tc-type-eq-core
        (tc-type-without-regions inner)
        (tc-type-without-regions b))]
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

(define (tc-type-eq [a : AstType] [b : AstType]) : bool
  (tc-type-eq-core (tc-type-without-regions a) (tc-type-without-regions b)))

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
        (let
          [a-regions : TcStringList (tc-type-collect-regions a)]
          [b-regions : TcStringList (tc-type-collect-regions b)]
          (if (tc-string-list-eq a-regions b-regions)
            (OkTcType a)
            (match a-regions
              [(TcStringNil) (OkTcType b)]
              [_
                (match b-regions
                  [(TcStringNil) (OkTcType a)]
                  [_ (ErrTcType "typecheck: if branches must match")])])))
        (ErrTcType "typecheck: if branches must match")))))

(define (tc-integer-type? [ty : AstType]) : bool
  (match (tc-type-strip-region ty)
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
  (match (tc-type-strip-region ty)
    [(AstTyF64) true]
    [_ false]))

(define (tc-ordered-comparison-type? [ty : AstType]) : bool
  (if (tc-integer-type? ty)
    true
    (if (tc-float-type? ty)
      true
      (match (tc-type-strip-region ty)
        [(AstTyChar) true]
        [_ false]))))

(define (tc-castable-type? [ty : AstType]) : bool
  (if (tc-integer-type? ty)
    true
    (match (tc-type-strip-region ty)
      [(AstTyChar) true]
      [_ false])))

(define (tc-dyn-array-elem-supported? [ty : AstType]) : bool
  (if (tc-integer-type? ty)
    true
    (match (tc-type-strip-region ty)
      [(AstTyBool) true]
      [(AstTyChar) true]
      [(AstTyF64) true]
      [(AstTyString) true]
      [(AstTyEnum _) true]
      [(AstTyStruct _) true]
      [(AstTyDynArray _) true]
      [_ false])))

(define (tc-spmd-varying? [class : TcSpmdClass]) : bool
  (match class
    [(TcSpmdUniform) false]
    [(TcSpmdVarying) true]))

(define (tc-spmd-merge-class [a : TcSpmdClass] [b : TcSpmdClass]) : TcSpmdClass
  (if (tc-spmd-varying? a)
    TcSpmdVarying
    (if (tc-spmd-varying? b)
      TcSpmdVarying
      TcSpmdUniform)))

(define (tc-spmd-varying-value-type-supported? [ty : AstType]) : bool
  (match (tc-type-strip-region ty)
    [(AstTyI64) true]
    [(AstTyI32) true]
    [(AstTyF64) true]
    [(AstTyBool) true]
    [_ false]))

(define (tc-spmd-lane-type-supported? [ty : AstType]) : bool
  (match (tc-type-strip-region ty)
    [(AstTyI64) true]
    [(AstTyI32) true]
    [(AstTyF64) true]
    [_ false]))

(define (tc-spmd-finish [ty : AstType] [class : TcSpmdClass] [env : TcSpmdEnv]) : ResultTcSpmdExprInfo
  (if (and
    (tc-spmd-varying? class)
    (not (tc-spmd-varying-value-type-supported? ty)))
    (ErrTcSpmdExprInfo
      (string-append
        "typecheck: foreach varying value type is not supported: "
        (tc-type-render (tc-type-strip-region ty))))
    (OkTcSpmdExprInfo (TcSpmdExprInfo ty class env))))

(define (tc-spmd-finish-lane
  [ty : AstType]
  [class : TcSpmdClass]
  [env : TcSpmdEnv]) : ResultTcSpmdExprInfo
  (if (and (tc-spmd-varying? class) (not (tc-spmd-lane-type-supported? ty)))
    (ErrTcSpmdExprInfo
      (string-append
        "typecheck: foreach varying array lane type is not supported: "
        (tc-type-render (tc-type-strip-region ty))))
    (tc-spmd-finish ty class env)))

(define (tc-spmd-env-from-type-env [env : TcTypeEnv]) : TcSpmdEnv
  (match env
    [(TcTypeNil) TcSpmdEnvNil]
    [(TcTypeBind name ty rest)
      (TcSpmdEnvBind
        name
        ty
        TcSpmdUniform
        TcSpmdOuter
        (tc-spmd-env-from-type-env rest))]))

(define (tc-spmd-env-bind
  [env : TcSpmdEnv]
  [name : String]
  [ty : AstType]
  [class : TcSpmdClass]
  [scope : TcSpmdScope]) : TcSpmdEnv
  (TcSpmdEnvBind name ty class scope env))

(define (tc-spmd-env-lookup [env : TcSpmdEnv] [name : String]) : TcSpmdLookup
  (match env
    [(TcSpmdEnvNil) TcSpmdMissing]
    [(TcSpmdEnvBind key ty class scope rest)
      (if (string-eq key name)
        (TcSpmdFound ty class scope)
        (tc-spmd-env-lookup rest name))]))

(define (tc-spmd-env-has-local? [env : TcSpmdEnv] [name : String]) : bool
  (match env
    [(TcSpmdEnvNil) false]
    [(TcSpmdEnvBind key _ _ scope rest)
      (if (string-eq key name)
        (match scope
          [(TcSpmdLocal) true]
          [(TcSpmdOuter) (tc-spmd-env-has-local? rest name)])
        (tc-spmd-env-has-local? rest name))]))

(define (tc-spmd-env-has-outer? [env : TcSpmdEnv] [name : String]) : bool
  (match env
    [(TcSpmdEnvNil) false]
    [(TcSpmdEnvBind key _ _ scope rest)
      (if (string-eq key name)
        (match scope
          [(TcSpmdOuter) true]
          [(TcSpmdLocal) (tc-spmd-env-has-outer? rest name)])
        (tc-spmd-env-has-outer? rest name))]))

(define (tc-spmd-env-set-local-class
  [env : TcSpmdEnv]
  [name : String]
  [class : TcSpmdClass]) : TcSpmdEnv
  (match env
    [(TcSpmdEnvNil) TcSpmdEnvNil]
    [(TcSpmdEnvBind key ty old-class scope rest)
      (if (string-eq key name)
        (match scope
          [(TcSpmdLocal) (TcSpmdEnvBind key ty class scope rest)]
          [(TcSpmdOuter)
            (TcSpmdEnvBind
              key
              ty
              old-class
              scope
              (tc-spmd-env-set-local-class rest name class))])
        (TcSpmdEnvBind
          key
          ty
          old-class
          scope
          (tc-spmd-env-set-local-class rest name class)))]))

(define (tc-spmd-env-pop [env : TcSpmdEnv] [count : i64]) : TcSpmdEnv
  (if (<= count 0)
    env
    (match env
      [(TcSpmdEnvNil) TcSpmdEnvNil]
      [(TcSpmdEnvBind _ _ _ _ rest) (tc-spmd-env-pop rest (- count 1))])))

(define (tc-spmd-env-mark-outer [env : TcSpmdEnv]) : TcSpmdEnv
  (match env
    [(TcSpmdEnvNil) TcSpmdEnvNil]
    [(TcSpmdEnvBind name ty class _ rest)
      (TcSpmdEnvBind name ty class TcSpmdOuter (tc-spmd-env-mark-outer rest))]))

(define (tc-spmd-env-merge-classes [left : TcSpmdEnv] [right : TcSpmdEnv]) : TcSpmdEnv
  (match left
    [(TcSpmdEnvNil) TcSpmdEnvNil]
    [(TcSpmdEnvBind name ty class scope left-rest)
      (match right
        [(TcSpmdEnvNil) left]
        [(TcSpmdEnvBind _ _ right-class _ right-rest)
          (TcSpmdEnvBind
            name
            ty
            (tc-spmd-merge-class class right-class)
            scope
            (tc-spmd-env-merge-classes left-rest right-rest))])]))

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
        [(AstParam _ ty _)
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
        [(AstParam name ty _)
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

(define (tc-tag-type-list-region [region : String] [types : AstTypeList]) : AstTypeList
  (match types
    [(AstTypeNil) AstTypeNil]
    [(AstTypeCons head tail)
      (AstTypeCons
        (tc-tag-region region head)
        (tc-tag-type-list-region region tail))]))

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
  (tc-bind-enum-variants-in-module ctx env "" enum-name variants))

(define (tc-bind-enum-variants-in-module
  [ctx : TcContext]
  [env : TcTypeEnv]
  [module : String]
  [enum-name : String]
  [variants : AstVariantDefList]) : ResultTcEnv
  (match variants
    [(AstVariantDefNil) (OkTcEnv env)]
    [(AstVariantDefCons variant rest)
      (match variant
        [(AstVariantDef name fields)
          (let
            [scoped-enum : String (compiler-symbol-module-key module enum-name)]
            (tc-bind-enum-variants-in-module
              ctx
              (tc-bind-module-name
                env
                module
                name
                (tc-enum-variant-constructor-type ctx scoped-enum fields))
              module
              enum-name
              rest))])]))

(define (tc-build-top-env-list
  [ctx : TcContext]
  [decls : AstDeclList]
  [env : TcTypeEnv]) : ResultTcEnv
  (tc-build-top-env-list-in-module ctx decls env ""))

(define (tc-build-top-env-list-in-module
  [ctx : TcContext]
  [decls : AstDeclList]
  [env : TcTypeEnv]
  [module : String]) : ResultTcEnv
  (match decls
    [(AstDeclNil) (OkTcEnv env)]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclModule next-module)
          (tc-build-top-env-list-in-module ctx rest env next-module)]
        [(AstDeclDef name _ _)
          (match (tc-top-decl-type ctx decl)
            [(OkTcType ty)
              (tc-build-top-env-list-in-module
                ctx
                rest
                (tc-bind-module-name env module name ty)
                module)]
            [(ErrTcType message) (ErrTcEnv message)])]
        [(AstDeclDefFn name _ _ _)
          (match (tc-top-decl-type ctx decl)
            [(OkTcType ty)
              (tc-build-top-env-list-in-module
                ctx
                rest
                (tc-bind-module-name env module name ty)
                module)]
            [(ErrTcType message) (ErrTcEnv message)])]
        [(AstDeclExtern name _)
          (match (tc-top-decl-type ctx decl)
            [(OkTcType ty)
              (tc-build-top-env-list-in-module
                ctx
                rest
                (tc-bind-module-name env module name ty)
                module)]
            [(ErrTcType message) (ErrTcEnv message)])]
        [(AstDeclDefEnum name variants)
          (match (tc-bind-enum-variants-in-module ctx env module name variants)
            [(OkTcEnv next-env)
              (tc-build-top-env-list-in-module ctx rest next-env module)]
            [(ErrTcEnv message) (ErrTcEnv message)])]
        [(AstDeclDefStruct name _ fields)
          (let
            [scoped-name : String (compiler-symbol-module-key module name)]
            (tc-build-top-env-list-in-module
              ctx
              rest
              (tc-bind-module-name
                env
                module
                name
                (AstTyFunc
                  (tc-field-type-list ctx fields)
                  (AstTyStruct scoped-name)))
              module))]
        [(AstDeclComptimeDecl template)
          (match template
            [(AstDeclDefEnum name variants)
              (match (tc-bind-enum-variants-in-module
                ctx
                env
                module
                name
                variants)
                [(OkTcEnv next-env)
                  (tc-build-top-env-list-in-module ctx rest next-env module)]
                [(ErrTcEnv message) (ErrTcEnv message)])]
            [(AstDeclDefStruct name _ fields)
              (let
                [scoped-name : String (compiler-symbol-module-key module name)]
                (tc-build-top-env-list-in-module
                  ctx
                  rest
                  (tc-bind-module-name
                    env
                    module
                    name
                    (AstTyFunc
                      (tc-field-type-list ctx fields)
                      (AstTyStruct scoped-name)))
                  module))]
            [_ (tc-build-top-env-list-in-module ctx rest env module)])]
        [(AstDeclImport _)
          (tc-build-top-env-list-in-module ctx rest env module)]
        [(AstDeclTest _ _ _)
          (tc-build-top-env-list-in-module ctx rest env module)])]))

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

(define (tc-region-arg-builtin-name? [name : String]) : bool
  (if (string-eq name "print-string")
    true
    (if (string-eq name "print-str")
      true
      (if (string-eq name "print-error")
        true
        (if (string-eq name "string-length")
          true
          (if (string-eq name "length")
            true
            (if (string-eq name "string-eq")
              true
              (if (string-eq name "string=?")
                true
                (if (string-eq name "string->int")
                  true
                  (if (string-eq name "substring")
                    true
                    (if (string-eq name "string-slice")
                      true
                      (if (string-eq name "string-append")
                        true
                        (if (string-eq name "string-concat")
                          true
                          (if (string-eq name "read-file")
                            true
                            (if (string-eq name "read-file-status")
                              true
                              (if (string-eq name "write-file")
                                true
                                (if (string-eq name "write-file-status")
                                  true
                                  (if (string-eq name "append-file-status")
                                    true
                                    (if (string-eq name "file-exists?")
                                      true
                                      (if (string-eq name "file-exists-status")
                                        true
                                        (if (string-eq name "file-open-status")
                                          true
                                          (if (string-eq
                                            name
                                            "file-close-status")
                                            true
                                            (if (string-eq
                                              name
                                              "fs-mkdir-status")
                                              true
                                              (if (string-eq
                                                name
                                                "fs-remove-file-status")
                                                true
                                                (if (string-eq
                                                  name
                                                  "fs-remove-dir-status")
                                                  true
                                                  (if (string-eq
                                                    name
                                                    "fs-process-id")
                                                    true
                                                    (if (string-eq name "panic")
                                                      true
                                                      (if (string-eq
                                                        name
                                                        "error")
                                                        true
                                                        (if (string-eq
                                                          name
                                                          "env-var-exists?")
                                                          true
                                                          (string-eq
                                                            name
                                                            "env-var-value"))))))))))))))))))))))))))))))

(define (tc-default-builtin-unshadowed-scan? [env : TcTypeEnv] [name : String]) : bool
  (match env
    [(TcTypeNil) false]
    [(TcTypeBind key _ rest)
      (if (string-eq key name)
        false
        (if (string-eq key (tc-default-boundary-name))
          true
          (tc-default-builtin-unshadowed-scan? rest name)))]))

(define (tc-default-builtin-unshadowed? [env : TcTypeEnv] [name : String]) : bool
  (if (tc-region-arg-builtin-name? name)
    (tc-default-builtin-unshadowed-scan? env name)
    false))

(define (tc-constructor-name? [ctx : TcContext] [name : String]) : bool
  (match ctx
    [(TcContext _ symbols registries)
      (match (compiler-symbols-lookup-type symbols name)
        [(SomeI64 handle)
          (if (=
            (compiler-symbol-handle-kind handle)
            (compiler-symbol-kind-defstruct))
            true
            (match (compiler-registries-lookup-variant registries name)
              [(SomeI64 _) true]
              [(NoneI64) false]))]
        [(NoneI64)
          (match (compiler-registries-lookup-variant registries name)
            [(SomeI64 _) true]
            [(NoneI64) false])])]))

(define (tc-call-allows-region-args?
  [ctx : TcContext]
  [env : TcTypeEnv]
  [name : String]) : bool
  (if (tc-default-builtin-unshadowed? env name)
    true
    (match (tc-active-region env)
      [(TcSomeString _) (tc-constructor-name? ctx name)]
      [(TcNoString) false])))

(define (tc-expr-var-name [expr : AstExpr]) : TcMaybeString
  (match (ast-expr-unspan expr)
    [(AstExprVar name) (TcSomeString name)]
    [_ (TcNoString)]))

(define (tc-check-call-args
  [ctx : TcContext]
  [env : TcTypeEnv]
  [args : AstExprList]
  [params : AstTypeList]
  [allow-region-args : bool]
  [constructor-target : AstMaybeType]) : ResultTcUnit
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
                [(OkTcUnit)
                  (if (and
                    (tc-type-contains-any-region got)
                    (not allow-region-args))
                    (ErrTcUnit
                      "typecheck: cannot pass region-tagged value to function parameter; region value would escape")
                    (match constructor-target
                      [(AstSomeType target)
                        (match (tc-ensure-region-value-can-flow-into
                          env
                          target
                          got
                          "constructor result")
                          [(OkTcUnit)
                            (tc-check-call-args
                              ctx
                              env
                              rest-args
                              rest-params
                              allow-region-args
                              constructor-target)]
                          [(ErrTcUnit message) (ErrTcUnit message)])]
                      [(AstNoType)
                        (tc-check-call-args
                          ctx
                          env
                          rest-args
                          rest-params
                          allow-region-args
                          constructor-target)]))]
                [(ErrTcUnit message) (ErrTcUnit message)])]
            [(ErrTcType message) (ErrTcUnit message)])]
        [(AstTypeNil) (ErrTcUnit "typecheck: arity mismatch")])]))

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
          (let
            [call-name : TcMaybeString (tc-expr-var-name func)]
            (let
              [allow-region-args : bool
                (match call-name
                  [(TcSomeString name)
                    (tc-call-allows-region-args? ctx env name)]
                  [(TcNoString) false])]
              [constructor-target : AstMaybeType
                (match call-name
                  [(TcSomeString name)
                    (if (tc-constructor-name? ctx name)
                      (AstSomeType (tc-tag-active-region env ret))
                      (AstNoType))]
                  [(TcNoString) (AstNoType)])]
              (match (tc-check-call-args
                ctx
                env
                args
                params
                allow-region-args
                constructor-target)
                [(OkTcUnit) (OkTcType (tc-tag-active-region env ret))]
                [(ErrTcUnit message) (ErrTcType message)])))]
        [(AstTyRegion _ inner)
          (match inner
            [(AstTyFunc params ret)
              (match (tc-check-call-args ctx env args params false (AstNoType))
                [(OkTcUnit) (OkTcType (tc-tag-active-region env ret))]
                [(ErrTcUnit message) (ErrTcType message)])]
            [(AstTyEnum _)
              (match args
                [(AstExprNil) (OkTcType (tc-tag-active-region env inner))]
                [_ (ErrTcType "typecheck: arity mismatch")])]
            [_ (ErrTcType "typecheck: call target is not a function")])]
        [(AstTyEnum _)
          (match args
            [(AstExprNil) (OkTcType (tc-tag-active-region env fn-ty))]
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
              (match (tc-type-strip-region arg-ty)
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

;; `size-of`/`align-of` (#989) are comptime-only layout queries: a single type
;; argument, result `i64`. Typed here (intercepting before normal call resolution
;; so `size-of` isn't looked up as a function); CTFE computes the value when the
;; query is folded inside `(comptime ...)`. Slice 1 supports scalar types; struct
;; layout + `offset-of` are slice 2.
(define (tc-layout-query-call [name : String] [args : AstExprList]) : ResultTcType
  (match args
    [(AstExprCons _ rest)
      (match rest
        [(AstExprNil) (OkTcType (AstTyI64))]
        [_
          (ErrTcType
            (string-append
              "typecheck: "
              (string-append name " expects exactly one type argument")))])]
    [_
      (ErrTcType
        (string-append
          "typecheck: "
          (string-append name " expects exactly one type argument")))]))

(define (tc-call-or-array-length
  [ctx : TcContext]
  [env : TcTypeEnv]
  [func : AstExpr]
  [args : AstExprList]) : ResultTcType
  (match (ast-expr-unspan func)
    [(AstExprVar name)
      (if (and
        (or (string-eq name "size-of") (string-eq name "align-of"))
        (not (tc-name-bound? env name)))
        (tc-layout-query-call name args)
        (if (or (string-eq name "array-length") (string-eq name "length"))
          (tc-array-length-call ctx env name func args)
          (if (and
            (or (string-eq name "string-ref") (string-eq name "char-at"))
            (not (tc-name-bound? env name)))
            (tc-string-ref-call ctx env args)
            (tc-call-expr ctx env func args))))]
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
                        (tc-bind
                          env
                          name
                          (if (tc-type-contains-any-region init-ty)
                            init-ty
                            (tc-resolve-type ctx want)))
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

(define (tc-spmd-require-uniform [class : TcSpmdClass] [message : String]) : ResultTcUnit
  (if (tc-spmd-varying? class)
    (ErrTcUnit message)
    OkTcUnit))

(define (tc-spmd-let-bindings
  [ctx : TcContext]
  [env : TcTypeEnv]
  [spmd-env : TcSpmdEnv]
  [bindings : AstLetBindingList]
  [count : i64]) : ResultTcSpmdLetState
  (match bindings
    [(AstLetBindingNil) (OkTcSpmdLetState (TcSpmdLetState env spmd-env count))]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding name maybe-ty init)
          (match (tc-spmd-expr ctx env spmd-env init)
            [(OkTcSpmdExprInfo info)
              (match info
                [(TcSpmdExprInfo init-ty init-class next-spmd-env)
                  (let
                    [bound-ty : AstType
                      (match maybe-ty
                        [(AstSomeType want)
                          (if (tc-type-contains-any-region init-ty)
                            init-ty
                            (tc-resolve-type ctx want))]
                        [(AstNoType) init-ty])]
                    (tc-spmd-let-bindings
                      ctx
                      (tc-bind env name bound-ty)
                      (tc-spmd-env-bind
                        next-spmd-env
                        name
                        bound-ty
                        init-class
                        TcSpmdLocal)
                      rest
                      (+ count 1)))])]
            [(ErrTcSpmdExprInfo message) (ErrTcSpmdLetState message)])])]))

(define (tc-spmd-expr-list
  [ctx : TcContext]
  [env : TcTypeEnv]
  [spmd-env : TcSpmdEnv]
  [exprs : AstExprList]) : ResultTcSpmdExprListInfo
  (match exprs
    [(AstExprNil)
      (OkTcSpmdExprListInfo (TcSpmdExprListInfo TcSpmdUniform spmd-env))]
    [(AstExprCons expr rest)
      (match (tc-spmd-expr ctx env spmd-env expr)
        [(OkTcSpmdExprInfo info)
          (match info
            [(TcSpmdExprInfo _ class next-spmd-env)
              (match (tc-spmd-expr-list ctx env next-spmd-env rest)
                [(OkTcSpmdExprListInfo rest-info)
                  (match rest-info
                    [(TcSpmdExprListInfo rest-class rest-env)
                      (OkTcSpmdExprListInfo
                        (TcSpmdExprListInfo
                          (tc-spmd-merge-class class rest-class)
                          rest-env))])]
                [(ErrTcSpmdExprListInfo message)
                  (ErrTcSpmdExprListInfo message)])])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprListInfo message)])]))

(define (tc-spmd-begin-list
  [ctx : TcContext]
  [env : TcTypeEnv]
  [spmd-env : TcSpmdEnv]
  [exprs : AstExprList]) : ResultTcSpmdExprInfo
  (match exprs
    [(AstExprNil)
      (OkTcSpmdExprInfo (TcSpmdExprInfo (AstTyUnit) TcSpmdUniform spmd-env))]
    [(AstExprCons expr rest)
      (match rest
        [(AstExprNil) (tc-spmd-expr ctx env spmd-env expr)]
        [_
          (match (tc-spmd-expr ctx env spmd-env expr)
            [(OkTcSpmdExprInfo info)
              (match info
                [(TcSpmdExprInfo _ _ next-spmd-env)
                  (tc-spmd-begin-list ctx env next-spmd-env rest)])]
            [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])])]))

(define (tc-spmd-match-arms
  [ctx : TcContext]
  [env : TcTypeEnv]
  [spmd-env : TcSpmdEnv]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]
  [class : TcSpmdClass]) : ResultTcSpmdExprListInfo
  (match arms
    [(AstMatchArmNil)
      (OkTcSpmdExprListInfo (TcSpmdExprListInfo class spmd-env))]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm pattern body)
          (match (tc-bind-match-pattern ctx env scrut-ty pattern)
            [(OkTcEnv arm-env)
              (match (tc-spmd-expr ctx arm-env spmd-env body)
                [(OkTcSpmdExprInfo body-info)
                  (match body-info
                    [(TcSpmdExprInfo _ body-class body-env)
                      (match (tc-spmd-match-arms
                        ctx
                        env
                        spmd-env
                        scrut-ty
                        rest
                        (tc-spmd-merge-class class body-class))
                        [(OkTcSpmdExprListInfo rest-info)
                          (match rest-info
                            [(TcSpmdExprListInfo rest-class rest-env)
                              (OkTcSpmdExprListInfo
                                (TcSpmdExprListInfo
                                  rest-class
                                  (tc-spmd-env-merge-classes body-env rest-env)))])]
                        [(ErrTcSpmdExprListInfo message)
                          (ErrTcSpmdExprListInfo message)])])]
                [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprListInfo message)])]
            [(ErrTcEnv message) (ErrTcSpmdExprListInfo message)])])]))

(define (tc-spmd-check-foreach-body-with-env
  [ctx : TcContext]
  [env : TcTypeEnv]
  [spmd-env : TcSpmdEnv]
  [index : String]
  [index-ty : AstType]
  [body : AstExpr]) : ResultTcUnit
  (let
    [body-env : TcTypeEnv (tc-bind env index index-ty)]
    [body-spmd-env : TcSpmdEnv
      (tc-spmd-env-bind
        (tc-spmd-env-mark-outer spmd-env)
        index
        index-ty
        TcSpmdVarying
        TcSpmdLocal)]
    (match (tc-spmd-expr ctx body-env body-spmd-env body)
      [(OkTcSpmdExprInfo _) OkTcUnit]
      [(ErrTcSpmdExprInfo message) (ErrTcUnit message)])))

(define (tc-spmd-check-foreach-body
  [ctx : TcContext]
  [env : TcTypeEnv]
  [index : String]
  [index-ty : AstType]
  [body : AstExpr]) : ResultTcUnit
  (tc-spmd-check-foreach-body-with-env
    ctx
    env
    (tc-spmd-env-from-type-env env)
    index
    index-ty
    body))

(define (tc-spmd-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [spmd-env : TcSpmdEnv]
  [expr : AstExpr]) : ResultTcSpmdExprInfo
  (match (tc-expr ctx env expr)
    [(OkTcType ty) (tc-spmd-expr-typed ctx env spmd-env expr ty)]
    [(ErrTcType message) (ErrTcSpmdExprInfo message)]))

(define (tc-spmd-expr-typed
  [ctx : TcContext]
  [env : TcTypeEnv]
  [spmd-env : TcSpmdEnv]
  [expr : AstExpr]
  [expr-ty : AstType]) : ResultTcSpmdExprInfo
  (match expr
    [(AstExprSpanned inner _)
      (tc-spmd-expr-typed ctx env spmd-env inner expr-ty)]
    [(AstExprLiteral _) (tc-spmd-finish expr-ty TcSpmdUniform spmd-env)]
    [(AstExprVar name)
      (match (tc-spmd-env-lookup spmd-env name)
        [(TcSpmdFound _ class _) (tc-spmd-finish expr-ty class spmd-env)]
        [(TcSpmdMissing) (tc-spmd-finish expr-ty TcSpmdUniform spmd-env)])]
    [(AstExprTypeLiteral _) (tc-spmd-finish expr-ty TcSpmdUniform spmd-env)]
    [(AstExprAnn inner _)
      (match (tc-spmd-expr ctx env spmd-env inner)
        [(OkTcSpmdExprInfo info)
          (match info
            [(TcSpmdExprInfo _ class next-spmd-env)
              (tc-spmd-finish expr-ty class next-spmd-env)])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprCast inner _)
      (match (tc-spmd-expr ctx env spmd-env inner)
        [(OkTcSpmdExprInfo info)
          (match info
            [(TcSpmdExprInfo _ class next-spmd-env)
              (tc-spmd-finish expr-ty class next-spmd-env)])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprUnary _ inner)
      (match (tc-spmd-expr ctx env spmd-env inner)
        [(OkTcSpmdExprInfo info)
          (match info
            [(TcSpmdExprInfo _ class next-spmd-env)
              (tc-spmd-finish expr-ty class next-spmd-env)])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprBinary _ left right)
      (match (tc-spmd-expr ctx env spmd-env left)
        [(OkTcSpmdExprInfo left-info)
          (match left-info
            [(TcSpmdExprInfo _ left-class left-env)
              (match (tc-spmd-expr ctx env left-env right)
                [(OkTcSpmdExprInfo right-info)
                  (match right-info
                    [(TcSpmdExprInfo _ right-class right-env)
                      (tc-spmd-finish
                        expr-ty
                        (tc-spmd-merge-class left-class right-class)
                        right-env)])]
                [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprCall func args)
      (match (tc-spmd-expr ctx env spmd-env func)
        [(OkTcSpmdExprInfo func-info)
          (match func-info
            [(TcSpmdExprInfo _ _ func-env)
              (match (tc-spmd-expr-list ctx env func-env args)
                [(OkTcSpmdExprListInfo args-info)
                  (match args-info
                    [(TcSpmdExprListInfo args-class args-env)
                      (match (tc-spmd-require-uniform
                        args-class
                        "typecheck: foreach calls with varying arguments are not supported")
                        [(OkTcUnit)
                          (tc-spmd-finish expr-ty TcSpmdUniform args-env)]
                        [(ErrTcUnit message) (ErrTcSpmdExprInfo message)])])]
                [(ErrTcSpmdExprListInfo message) (ErrTcSpmdExprInfo message)])])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprIf cond then-branch else-branch)
      (match (tc-spmd-expr ctx env spmd-env cond)
        [(OkTcSpmdExprInfo cond-info)
          (match cond-info
            [(TcSpmdExprInfo _ cond-class cond-env)
              (match (tc-spmd-require-uniform
                cond-class
                "typecheck: foreach if condition must be uniform")
                [(OkTcUnit)
                  (match (tc-spmd-expr ctx env cond-env then-branch)
                    [(OkTcSpmdExprInfo then-info)
                      (match then-info
                        [(TcSpmdExprInfo _ then-class then-env)
                          (match (tc-spmd-expr ctx env cond-env else-branch)
                            [(OkTcSpmdExprInfo else-info)
                              (match else-info
                                [(TcSpmdExprInfo _ else-class else-env)
                                  (tc-spmd-finish
                                    expr-ty
                                    (tc-spmd-merge-class then-class else-class)
                                    (tc-spmd-env-merge-classes
                                      then-env
                                      else-env))])]
                            [(ErrTcSpmdExprInfo message)
                              (ErrTcSpmdExprInfo message)])])]
                    [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
                [(ErrTcUnit message) (ErrTcSpmdExprInfo message)])])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprLet bindings body)
      (match (tc-spmd-let-bindings ctx env spmd-env bindings 0)
        [(OkTcSpmdLetState state)
          (match state
            [(TcSpmdLetState body-env body-spmd-env count)
              (match (tc-spmd-expr ctx body-env body-spmd-env body)
                [(OkTcSpmdExprInfo body-info)
                  (match body-info
                    [(TcSpmdExprInfo _ body-class final-spmd-env)
                      (tc-spmd-finish
                        expr-ty
                        body-class
                        (tc-spmd-env-pop final-spmd-env count))])]
                [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])])]
        [(ErrTcSpmdLetState message) (ErrTcSpmdExprInfo message)])]
    [(AstExprLambda _ _ _) (tc-spmd-finish expr-ty TcSpmdUniform spmd-env)]
    [(AstExprTuple exprs)
      (match (tc-spmd-expr-list ctx env spmd-env exprs)
        [(OkTcSpmdExprListInfo info)
          (match info
            [(TcSpmdExprListInfo class next-spmd-env)
              (tc-spmd-finish expr-ty class next-spmd-env)])]
        [(ErrTcSpmdExprListInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprTupleRef tuple _)
      (match (tc-spmd-expr ctx env spmd-env tuple)
        [(OkTcSpmdExprInfo info)
          (match info
            [(TcSpmdExprInfo _ class next-spmd-env)
              (tc-spmd-finish expr-ty class next-spmd-env)])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprArray exprs)
      (match (tc-spmd-expr-list ctx env spmd-env exprs)
        [(OkTcSpmdExprListInfo info)
          (match info
            [(TcSpmdExprListInfo class next-spmd-env)
              (tc-spmd-finish expr-ty class next-spmd-env)])]
        [(ErrTcSpmdExprListInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprMakeArray _ len)
      (match (tc-spmd-expr ctx env spmd-env len)
        [(OkTcSpmdExprInfo info)
          (match info
            [(TcSpmdExprInfo _ class next-spmd-env)
              (tc-spmd-finish expr-ty class next-spmd-env)])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprArrayRef array index)
      (match (tc-spmd-expr ctx env spmd-env array)
        [(OkTcSpmdExprInfo array-info)
          (match array-info
            [(TcSpmdExprInfo _ array-class array-env)
              (match (tc-spmd-expr ctx env array-env index)
                [(OkTcSpmdExprInfo index-info)
                  (match index-info
                    [(TcSpmdExprInfo _ index-class index-env)
                      (tc-spmd-finish-lane
                        expr-ty
                        (tc-spmd-merge-class array-class index-class)
                        index-env)])]
                [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprArraySet array index value)
      (match (tc-spmd-expr ctx env spmd-env array)
        [(OkTcSpmdExprInfo array-info)
          (match array-info
            [(TcSpmdExprInfo array-ty array-class array-env)
              (match (tc-spmd-expr ctx env array-env index)
                [(OkTcSpmdExprInfo index-info)
                  (match index-info
                    [(TcSpmdExprInfo _ index-class index-env)
                      (match (tc-spmd-expr ctx env index-env value)
                        [(OkTcSpmdExprInfo value-info)
                          (match value-info
                            [(TcSpmdExprInfo _ value-class value-env)
                              (let
                                [write-class : TcSpmdClass
                                  (tc-spmd-merge-class
                                    array-class
                                    (tc-spmd-merge-class
                                      index-class
                                      value-class))]
                                (match (tc-type-strip-region array-ty)
                                  [(AstTyArray elem-ty _)
                                    (if (and
                                      (tc-spmd-varying? write-class)
                                      (not
                                        (tc-spmd-lane-type-supported? elem-ty)))
                                      (ErrTcSpmdExprInfo
                                        (string-append
                                          "typecheck: foreach varying array lane type is not supported: "
                                          (tc-type-render
                                            (tc-type-strip-region elem-ty))))
                                      (tc-spmd-finish
                                        expr-ty
                                        TcSpmdUniform
                                        value-env))]
                                  [(AstTyDynArray elem-ty)
                                    (if (and
                                      (tc-spmd-varying? write-class)
                                      (not
                                        (tc-spmd-lane-type-supported? elem-ty)))
                                      (ErrTcSpmdExprInfo
                                        (string-append
                                          "typecheck: foreach varying array lane type is not supported: "
                                          (tc-type-render
                                            (tc-type-strip-region elem-ty))))
                                      (tc-spmd-finish
                                        expr-ty
                                        TcSpmdUniform
                                        value-env))]
                                  [_
                                    (tc-spmd-finish
                                      expr-ty
                                      TcSpmdUniform
                                      value-env)]))])]
                        [(ErrTcSpmdExprInfo message)
                          (ErrTcSpmdExprInfo message)])])]
                [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprStringRef str index)
      (match (tc-spmd-expr ctx env spmd-env str)
        [(OkTcSpmdExprInfo str-info)
          (match str-info
            [(TcSpmdExprInfo _ str-class str-env)
              (match (tc-spmd-expr ctx env str-env index)
                [(OkTcSpmdExprInfo index-info)
                  (match index-info
                    [(TcSpmdExprInfo _ index-class index-env)
                      (tc-spmd-finish
                        expr-ty
                        (tc-spmd-merge-class str-class index-class)
                        index-env)])]
                [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprWhile cond body)
      (match (tc-spmd-expr ctx env spmd-env cond)
        [(OkTcSpmdExprInfo cond-info)
          (match cond-info
            [(TcSpmdExprInfo _ cond-class cond-env)
              (match (tc-spmd-require-uniform
                cond-class
                "typecheck: foreach while condition must be uniform")
                [(OkTcUnit)
                  (match (tc-spmd-expr ctx env cond-env body)
                    [(OkTcSpmdExprInfo body-info)
                      (match body-info
                        [(TcSpmdExprInfo _ _ body-env)
                          (tc-spmd-finish
                            expr-ty
                            TcSpmdUniform
                            (tc-spmd-env-merge-classes cond-env body-env))])]
                    [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
                [(ErrTcUnit message) (ErrTcSpmdExprInfo message)])])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprBegin exprs) (tc-spmd-begin-list ctx env spmd-env exprs)]
    [(AstExprUnsafe exprs) (tc-spmd-begin-list ctx env spmd-env exprs)]
    [(AstExprSet name value)
      (match (tc-spmd-expr ctx env spmd-env value)
        [(OkTcSpmdExprInfo value-info)
          (match value-info
            [(TcSpmdExprInfo _ value-class value-env)
              (if (tc-spmd-env-has-local? value-env name)
                (tc-spmd-finish
                  expr-ty
                  TcSpmdUniform
                  (tc-spmd-env-set-local-class value-env name value-class))
                (if (tc-spmd-env-has-outer? value-env name)
                  (ErrTcSpmdExprInfo
                    "typecheck: foreach cannot set binding declared outside foreach")
                  (tc-spmd-finish expr-ty TcSpmdUniform value-env)))])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprMatch scrutinee arms)
      (match (tc-spmd-expr ctx env spmd-env scrutinee)
        [(OkTcSpmdExprInfo scrut-info)
          (match scrut-info
            [(TcSpmdExprInfo scrut-ty scrut-class scrut-env)
              (match (tc-spmd-require-uniform
                scrut-class
                "typecheck: foreach match scrutinee must be uniform")
                [(OkTcUnit)
                  (match (tc-spmd-match-arms
                    ctx
                    env
                    scrut-env
                    scrut-ty
                    arms
                    TcSpmdUniform)
                    [(OkTcSpmdExprListInfo arms-info)
                      (match arms-info
                        [(TcSpmdExprListInfo arms-class arms-env)
                          (tc-spmd-finish expr-ty arms-class arms-env)])]
                    [(ErrTcSpmdExprListInfo message)
                      (ErrTcSpmdExprInfo message)])]
                [(ErrTcUnit message) (ErrTcSpmdExprInfo message)])])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprForeach index index-ty start end body)
      (match (tc-spmd-expr ctx env spmd-env start)
        [(OkTcSpmdExprInfo start-info)
          (match start-info
            [(TcSpmdExprInfo _ start-class start-env)
              (match (tc-spmd-require-uniform
                start-class
                "typecheck: foreach bounds must be uniform")
                [(OkTcUnit)
                  (match (tc-spmd-expr ctx env start-env end)
                    [(OkTcSpmdExprInfo end-info)
                      (match end-info
                        [(TcSpmdExprInfo _ end-class end-env)
                          (match (tc-spmd-require-uniform
                            end-class
                            "typecheck: foreach bounds must be uniform")
                            [(OkTcUnit)
                              (match (tc-spmd-check-foreach-body-with-env
                                ctx
                                env
                                end-env
                                index
                                (tc-resolve-type ctx index-ty)
                                body)
                                [(OkTcUnit)
                                  (tc-spmd-finish expr-ty TcSpmdUniform end-env)]
                                [(ErrTcUnit message)
                                  (ErrTcSpmdExprInfo message)])]
                            [(ErrTcUnit message) (ErrTcSpmdExprInfo message)])])]
                    [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
                [(ErrTcUnit message) (ErrTcSpmdExprInfo message)])])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprSpmdReduce _ _ _ _ _ _ _)
      (ErrTcSpmdExprInfo
        "typecheck: spmd-reduce inside foreach is not supported")]
    [(AstExprStructGet receiver _)
      (match (tc-spmd-expr ctx env spmd-env receiver)
        [(OkTcSpmdExprInfo info)
          (match info
            [(TcSpmdExprInfo _ class next-spmd-env)
              (tc-spmd-finish expr-ty class next-spmd-env)])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprWithRegion region body)
      (tc-spmd-begin-list ctx (tc-push-region env region) spmd-env body)]
    [(AstExprComptime inner)
      (match (tc-spmd-expr ctx env spmd-env inner)
        [(OkTcSpmdExprInfo info)
          (match info
            [(TcSpmdExprInfo _ class next-spmd-env)
              (tc-spmd-finish expr-ty class next-spmd-env)])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprTry inner)
      (match (tc-spmd-expr ctx env spmd-env inner)
        [(OkTcSpmdExprInfo info)
          (match info
            [(TcSpmdExprInfo _ class next-spmd-env)
              (tc-spmd-finish expr-ty class next-spmd-env)])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprPtrNull _) (tc-spmd-finish expr-ty TcSpmdUniform spmd-env)]
    [(AstExprPtrNullCheck inner)
      (match (tc-spmd-expr ctx env spmd-env inner)
        [(OkTcSpmdExprInfo info)
          (match info
            [(TcSpmdExprInfo _ class next-spmd-env)
              (tc-spmd-finish expr-ty class next-spmd-env)])]
        [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]))

(define (tc-param-list-add-bound-names
  [params : AstParamList]
  [bound : TcStringList]) : TcStringList
  (match params
    [(AstParamNil) bound]
    [(AstParamCons param rest)
      (match param
        [(AstParam name _ _)
          (tc-param-list-add-bound-names rest (tc-string-list-add bound name))])]))

(define (tc-param-bound-names [params : AstParamList]) : TcStringList
  (tc-param-list-add-bound-names params TcStringNil))

(define (tc-pattern-add-bound-names
  [pattern : AstPattern]
  [bound : TcStringList]) : TcStringList
  (match pattern
    [(AstPatVar name _) (tc-string-list-add bound name)]
    [(AstPatTuple patterns) (tc-pattern-list-add-bound-names patterns bound)]
    [(AstPatWildcard) bound]
    [(AstPatBinding name) (tc-string-list-add bound name)]
    [(AstPatVariant _ patterns)
      (tc-pattern-list-add-bound-names patterns bound)]
    [(AstPatLiteral _) bound]))

(define (tc-pattern-list-add-bound-names
  [patterns : AstPatternList]
  [bound : TcStringList]) : TcStringList
  (match patterns
    [(AstPatternNil) bound]
    [(AstPatternCons pattern rest)
      (tc-pattern-list-add-bound-names
        rest
        (tc-pattern-add-bound-names pattern bound))]))

(define (tc-let-binding-list-add-bound-names
  [bindings : AstLetBindingList]
  [bound : TcStringList]) : TcStringList
  (match bindings
    [(AstLetBindingNil) bound]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding name _ _)
          (tc-let-binding-list-add-bound-names
            rest
            (tc-string-list-add bound name))])]))

(define (tc-expr-list-uses-free-name?
  [exprs : AstExprList]
  [name : String]
  [bound : TcStringList]) : bool
  (match exprs
    [(AstExprNil) false]
    [(AstExprCons expr rest)
      (or
        (tc-expr-uses-free-name? expr name bound)
        (tc-expr-list-uses-free-name? rest name bound))]))

(define (tc-let-binding-list-uses-free-name?
  [bindings : AstLetBindingList]
  [name : String]
  [bound : TcStringList]) : bool
  (match bindings
    [(AstLetBindingNil) false]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding bind-name _ init)
          (or
            (tc-expr-uses-free-name? init name bound)
            (tc-let-binding-list-uses-free-name?
              rest
              name
              (tc-string-list-add bound bind-name)))])]))

(define (tc-match-arms-use-free-name?
  [arms : AstMatchArmList]
  [name : String]
  [bound : TcStringList]) : bool
  (match arms
    [(AstMatchArmNil) false]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm pattern body)
          (or
            (tc-expr-uses-free-name?
              body
              name
              (tc-pattern-add-bound-names pattern bound))
            (tc-match-arms-use-free-name? rest name bound))])]))

(define (tc-expr-uses-free-name?
  [expr : AstExpr]
  [name : String]
  [bound : TcStringList]) : bool
  (match expr
    [(AstExprSpanned inner _) (tc-expr-uses-free-name? inner name bound)]
    [(AstExprLiteral _) false]
    [(AstExprVar var-name)
      (and (string-eq var-name name) (not (tc-string-list-contains bound name)))]
    [(AstExprBinary _ left right)
      (or
        (tc-expr-uses-free-name? left name bound)
        (tc-expr-uses-free-name? right name bound))]
    [(AstExprUnary _ inner) (tc-expr-uses-free-name? inner name bound)]
    [(AstExprCall func args)
      (or
        (tc-expr-uses-free-name? func name bound)
        (tc-expr-list-uses-free-name? args name bound))]
    [(AstExprTypeLiteral _) false]
    [(AstExprIf cond then-branch else-branch)
      (or
        (tc-expr-uses-free-name? cond name bound)
        (or
          (tc-expr-uses-free-name? then-branch name bound)
          (tc-expr-uses-free-name? else-branch name bound)))]
    [(AstExprLet bindings body)
      (or
        (tc-let-binding-list-uses-free-name? bindings name bound)
        (tc-expr-uses-free-name?
          body
          name
          (tc-let-binding-list-add-bound-names bindings bound)))]
    [(AstExprLambda params _ body)
      (tc-expr-uses-free-name?
        body
        name
        (tc-param-list-add-bound-names params bound))]
    [(AstExprTuple exprs) (tc-expr-list-uses-free-name? exprs name bound)]
    [(AstExprTupleRef tuple _) (tc-expr-uses-free-name? tuple name bound)]
    [(AstExprArray exprs) (tc-expr-list-uses-free-name? exprs name bound)]
    [(AstExprMakeArray _ len) (tc-expr-uses-free-name? len name bound)]
    [(AstExprArrayRef array index)
      (or
        (tc-expr-uses-free-name? array name bound)
        (tc-expr-uses-free-name? index name bound))]
    [(AstExprArraySet array index value)
      (or
        (tc-expr-uses-free-name? array name bound)
        (or
          (tc-expr-uses-free-name? index name bound)
          (tc-expr-uses-free-name? value name bound)))]
    [(AstExprStringRef str index)
      (or
        (tc-expr-uses-free-name? str name bound)
        (tc-expr-uses-free-name? index name bound))]
    [(AstExprWhile cond body)
      (or
        (tc-expr-uses-free-name? cond name bound)
        (tc-expr-uses-free-name? body name bound))]
    [(AstExprBegin exprs) (tc-expr-list-uses-free-name? exprs name bound)]
    [(AstExprUnsafe exprs) (tc-expr-list-uses-free-name? exprs name bound)]
    [(AstExprSet var-name value)
      (or
        (and
          (string-eq var-name name)
          (not (tc-string-list-contains bound name)))
        (tc-expr-uses-free-name? value name bound))]
    [(AstExprAnn inner _) (tc-expr-uses-free-name? inner name bound)]
    [(AstExprCast inner _) (tc-expr-uses-free-name? inner name bound)]
    [(AstExprMatch scrutinee arms)
      (or
        (tc-expr-uses-free-name? scrutinee name bound)
        (tc-match-arms-use-free-name? arms name bound))]
    [(AstExprForeach index _ start end body)
      (or
        (tc-expr-uses-free-name? start name bound)
        (or
          (tc-expr-uses-free-name? end name bound)
          (tc-expr-uses-free-name? body name (tc-string-list-add bound index))))]
    [(AstExprSpmdReduce _ index _ start end init value)
      (or
        (tc-expr-uses-free-name? start name bound)
        (or
          (tc-expr-uses-free-name? end name bound)
          (or
            (tc-expr-uses-free-name? init name bound)
            (tc-expr-uses-free-name?
              value
              name
              (tc-string-list-add bound index)))))]
    [(AstExprStructGet receiver _)
      (tc-expr-uses-free-name? receiver name bound)]
    [(AstExprWithRegion _ body) (tc-expr-list-uses-free-name? body name bound)]
    [(AstExprTypeLiteral _) false]
    [(AstExprComptime inner) (tc-expr-uses-free-name? inner name bound)]
    [(AstExprTry inner) (tc-expr-uses-free-name? inner name bound)]
    [(AstExprPtrNull _) false]
    [(AstExprPtrNullCheck inner) (tc-expr-uses-free-name? inner name bound)]))

(define (tc-check-lambda-region-captures-scan
  [env : TcTypeEnv]
  [bound : TcStringList]
  [body : AstExpr]) : ResultTcUnit
  (match env
    [(TcTypeNil) OkTcUnit]
    [(TcTypeBind key ty rest)
      (if (or
        (string-eq key (tc-region-marker-name))
        (string-eq key (tc-default-boundary-name)))
        (tc-check-lambda-region-captures-scan rest bound body)
        (if (and
          (tc-type-contains-any-region ty)
          (tc-expr-uses-free-name? body key bound))
          (ErrTcUnit
            "typecheck: lambda cannot capture region-tagged value; region value would escape")
          (tc-check-lambda-region-captures-scan rest bound body)))]))

(define (tc-check-lambda-region-captures
  [env : TcTypeEnv]
  [params : AstParamList]
  [body : AstExpr]) : ResultTcUnit
  (tc-check-lambda-region-captures-scan env (tc-param-bound-names params) body))

(define (tc-context-program [ctx : TcContext]) : AstProgram
  (match ctx
    [(TcContext program _ _) program]))

(define (tc-context-registries [ctx : TcContext]) : CompilerRegistries
  (match ctx
    [(TcContext _ _ registries) registries]))

(define (tc-program-enum-variants-list
  [decls : AstDeclList]
  [enum-name : String]) : ResultAstVariantDefList
  (tc-program-enum-variants-list-in-module decls enum-name ""))

(define (tc-program-enum-variants-list-in-module
  [decls : AstDeclList]
  [enum-name : String]
  [module : String]) : ResultAstVariantDefList
  (match decls
    [(AstDeclNil)
      (ErrAstVariantDefList
        (string-append "typecheck: unknown enum " enum-name))]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclModule next-module)
          (tc-program-enum-variants-list-in-module rest enum-name next-module)]
        [(AstDeclDefEnum name variants)
          (if (or
            (string-eq name enum-name)
            (string-eq (compiler-symbol-module-key module name) enum-name))
            (OkAstVariantDefList variants)
            (tc-program-enum-variants-list-in-module rest enum-name module))]
        [(AstDeclComptimeDecl template)
          (match template
            [(AstDeclDefEnum name variants)
              (if (or
                (string-eq name enum-name)
                (string-eq (compiler-symbol-module-key module name) enum-name))
                (OkAstVariantDefList variants)
                (tc-program-enum-variants-list-in-module rest enum-name module))]
            [_ (tc-program-enum-variants-list-in-module rest enum-name module)])]
        [_ (tc-program-enum-variants-list-in-module rest enum-name module)])]))

(define (tc-program-enum-variants [program : AstProgram] [enum-name : String]) : ResultAstVariantDefList
  (match program
    [(AstProgram decls) (tc-program-enum-variants-list decls enum-name)]))

(define (tc-layout-info-size [info : TcLayoutInfo]) : i64
  (match info
    [(TcLayoutInfo size _) size]))

(define (tc-layout-info-align [info : TcLayoutInfo]) : i64
  (match info
    [(TcLayoutInfo _ align) align]))

(define (tc-repr-c-layout-size [layout : TcReprCLayout]) : i64
  (match layout
    [(TcReprCLayout size _ _) size]))

(define (tc-repr-c-layout-align [layout : TcReprCLayout]) : i64
  (match layout
    [(TcReprCLayout _ align _) align]))

(define (tc-repr-c-layout-fields [layout : TcReprCLayout]) : TcReprCFieldLayoutList
  (match layout
    [(TcReprCLayout _ _ fields) fields]))

(define (tc-repr-c-field-layout-name [field : TcReprCFieldLayout]) : String
  (match field
    [(TcReprCFieldLayout name _ _) name]))

(define (tc-repr-c-field-layout-type [field : TcReprCFieldLayout]) : AstType
  (match field
    [(TcReprCFieldLayout _ ty _) ty]))

(define (tc-repr-c-field-layout-offset [field : TcReprCFieldLayout]) : i64
  (match field
    [(TcReprCFieldLayout _ _ offset) offset]))

(define (tc-repr-c-layout-field-offset
  [fields : TcReprCFieldLayoutList]
  [name : String]) : i64
  (match fields
    [(TcReprCFieldLayoutNil) -1]
    [(TcReprCFieldLayoutCons field rest)
      (if (string-eq (tc-repr-c-field-layout-name field) name)
        (tc-repr-c-field-layout-offset field)
        (tc-repr-c-layout-field-offset rest name))]))

(define (tc-align-up [n : i64] [align : i64]) : i64
  (if (<= align 1)
    n
    (* (/ (+ n (- align 1)) align) align)))

(define (tc-max-i64 [a : i64] [b : i64]) : i64
  (if (> a b)
    a
    b))

(define (tc-struct-decl [ctx : TcContext] [struct-name : String]) : ResultTcStructDecl
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
                  [(AstDeclDefStruct _ repr fields)
                    (OkTcStructDecl (TcStructDecl repr fields))]
                  [_
                    (ErrTcStructDecl
                      "typecheck: struct symbol owner is not a struct")])]
              [(ErrAstDecl message) (ErrTcStructDecl message)])
            (ErrTcStructDecl
              (string-append "typecheck: unknown struct " struct-name)))]
        [(NoneI64)
          (ErrTcStructDecl
            (string-append "typecheck: unknown struct " struct-name))])]))

(define (tc-repr-c-unsupported-field-message
  [owner : String]
  [field : String]
  [ty : AstType]) : String
  (tc-cat3
    "typecheck: repr c struct "
    owner
    (tc-cat3
      " field "
      field
      (string-append " has unsupported field type " (tc-type-render ty)))))

(define (tc-repr-c-field-layout-info
  [ctx : TcContext]
  [owner : String]
  [field : String]
  [ty : AstType]
  [seen : TcStringList]) : ResultTcLayoutInfo
  (match (tc-resolve-type ctx ty)
    [(AstTyI64) (OkTcLayoutInfo (TcLayoutInfo 8 8))]
    [(AstTyU64) (OkTcLayoutInfo (TcLayoutInfo 8 8))]
    [(AstTyF64) (OkTcLayoutInfo (TcLayoutInfo 8 8))]
    [(AstTyI32) (OkTcLayoutInfo (TcLayoutInfo 4 4))]
    [(AstTyU32) (OkTcLayoutInfo (TcLayoutInfo 4 4))]
    [(AstTyI16) (OkTcLayoutInfo (TcLayoutInfo 2 2))]
    [(AstTyU16) (OkTcLayoutInfo (TcLayoutInfo 2 2))]
    [(AstTyI8) (OkTcLayoutInfo (TcLayoutInfo 1 1))]
    [(AstTyU8) (OkTcLayoutInfo (TcLayoutInfo 1 1))]
    [(AstTyBool) (OkTcLayoutInfo (TcLayoutInfo 1 1))]
    [(AstTyChar) (OkTcLayoutInfo (TcLayoutInfo 1 1))]
    [(AstTyPtr _) (OkTcLayoutInfo (TcLayoutInfo 8 8))]
    [(AstTyMutPtr _) (OkTcLayoutInfo (TcLayoutInfo 8 8))]
    [(AstTyStruct nested)
      (match (tc-struct-decl ctx nested)
        [(OkTcStructDecl decl)
          (match decl
            [(TcStructDecl repr _)
              (if (ast-struct-repr-c? repr)
                (match (tc-repr-c-struct-layout-with-seen ctx nested seen)
                  [(OkTcReprCLayout layout)
                    (OkTcLayoutInfo
                      (TcLayoutInfo
                        (tc-repr-c-layout-size layout)
                        (tc-repr-c-layout-align layout)))]
                  [(ErrTcReprCLayout message) (ErrTcLayoutInfo message)])
                (ErrTcLayoutInfo
                  (tc-cat3
                    "typecheck: repr c struct "
                    owner
                    (tc-cat3
                      " field "
                      field
                      (string-append
                        " references default-layout struct "
                        nested)))))])]
        [(ErrTcStructDecl message) (ErrTcLayoutInfo message)])]
    [_ (ErrTcLayoutInfo (tc-repr-c-unsupported-field-message owner field ty))]))

(define (tc-repr-c-fields-layout
  [ctx : TcContext]
  [owner : String]
  [fields : AstFieldDefList]
  [cursor : i64]
  [max-align : i64]
  [seen : TcStringList]) : ResultTcReprCLayout
  (match fields
    [(AstFieldDefNil)
      (if (= max-align 0)
        (ErrTcReprCLayout "typecheck: repr c struct needs at least one field")
        (OkTcReprCLayout
          (TcReprCLayout
            (tc-align-up cursor max-align)
            max-align
            TcReprCFieldLayoutNil)))]
    [(AstFieldDefCons field rest)
      (match field
        [(AstFieldDef name ty)
          (let
            [resolved : AstType (tc-resolve-type ctx ty)]
            (match (tc-repr-c-field-layout-info ctx owner name resolved seen)
              [(OkTcLayoutInfo info)
                (let
                  [field-align : i64 (tc-layout-info-align info)]
                  [field-size : i64 (tc-layout-info-size info)]
                  [offset : i64 (tc-align-up cursor field-align)]
                  [next-cursor : i64 (+ offset field-size)]
                  [next-align : i64 (tc-max-i64 max-align field-align)]
                  (match (tc-repr-c-fields-layout
                    ctx
                    owner
                    rest
                    next-cursor
                    next-align
                    seen)
                    [(OkTcReprCLayout rest-layout)
                      (OkTcReprCLayout
                        (TcReprCLayout
                          (tc-repr-c-layout-size rest-layout)
                          (tc-repr-c-layout-align rest-layout)
                          (TcReprCFieldLayoutCons
                            (TcReprCFieldLayout name resolved offset)
                            (tc-repr-c-layout-fields rest-layout))))]
                    [(ErrTcReprCLayout message) (ErrTcReprCLayout message)]))]
              [(ErrTcLayoutInfo message) (ErrTcReprCLayout message)]))])]))

(define (tc-repr-c-struct-layout-with-seen
  [ctx : TcContext]
  [struct-name : String]
  [seen : TcStringList]) : ResultTcReprCLayout
  (if (tc-string-list-contains seen struct-name)
    (ErrTcReprCLayout
      (string-append
        "typecheck: recursive repr c struct layout cycle involving "
        struct-name))
    (match (tc-struct-decl ctx struct-name)
      [(OkTcStructDecl decl)
        (match decl
          [(TcStructDecl repr fields)
            (if (ast-struct-repr-c? repr)
              (tc-repr-c-fields-layout
                ctx
                struct-name
                fields
                0
                0
                (tc-string-list-add seen struct-name))
              (ErrTcReprCLayout
                (string-append "typecheck: struct is not repr c: " struct-name)))])]
      [(ErrTcStructDecl message) (ErrTcReprCLayout message)])))

(define (tc-repr-c-struct-layout [ctx : TcContext] [struct-name : String]) : ResultTcReprCLayout
  (tc-repr-c-struct-layout-with-seen ctx struct-name TcStringNil))

(define (tc-string-prefix? [text : String] [prefix : String]) : bool
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
    (if (< text-len prefix-len)
      false
      (string-eq (substring text 0 prefix-len) prefix))))

(define (tc-result-info-enum-name [info : TcResultInfo]) : String
  (match info
    [(TcResultInfo enum-name _ _ _ _) enum-name]))

(define (tc-result-info-ok-name [info : TcResultInfo]) : String
  (match info
    [(TcResultInfo _ ok-name _ _ _) ok-name]))

(define (tc-result-info-ok-type [info : TcResultInfo]) : AstType
  (match info
    [(TcResultInfo _ _ ok-ty _ _) ok-ty]))

(define (tc-result-info-err-name [info : TcResultInfo]) : String
  (match info
    [(TcResultInfo _ _ _ err-name _) err-name]))

(define (tc-result-info-err-type [info : TcResultInfo]) : AstType
  (match info
    [(TcResultInfo _ _ _ _ err-ty) err-ty]))

(define (tc-ok-variant-name? [name : String]) : bool
  (tc-string-prefix? name "Ok"))

(define (tc-err-variant-name? [name : String]) : bool
  (tc-string-prefix? name "Err"))

(define (tc-result-variant-payload-type
  [ctx : TcContext]
  [variant-name : String]
  [fields : AstTypeList]) : ResultTcType
  (match fields
    [(AstTypeCons field AstTypeNil) (OkTcType (tc-resolve-type ctx field))]
    [_
      (ErrTcType
        (string-append
          "typecheck: try requires Result-like variant with one payload "
          variant-name))]))

(define (tc-result-info-build
  [ctx : TcContext]
  [enum-name : String]
  [ok-name : String]
  [ok-fields : AstTypeList]
  [err-name : String]
  [err-fields : AstTypeList]) : ResultTcResultInfo
  (match (tc-result-variant-payload-type ctx ok-name ok-fields)
    [(OkTcType ok-ty)
      (match (tc-result-variant-payload-type ctx err-name err-fields)
        [(OkTcType err-ty)
          (OkTcResultInfo
            (TcResultInfo enum-name ok-name ok-ty err-name err-ty))]
        [(ErrTcType message) (ErrTcResultInfo message)])]
    [(ErrTcType message) (ErrTcResultInfo message)]))

(define (tc-result-info-two-variants
  [ctx : TcContext]
  [enum-name : String]
  [first-name : String]
  [first-fields : AstTypeList]
  [second-name : String]
  [second-fields : AstTypeList]) : ResultTcResultInfo
  (if (and (tc-ok-variant-name? first-name) (tc-err-variant-name? second-name))
    (tc-result-info-build
      ctx
      enum-name
      first-name
      first-fields
      second-name
      second-fields)
    (if (and
      (tc-err-variant-name? first-name)
      (tc-ok-variant-name? second-name))
      (tc-result-info-build
        ctx
        enum-name
        second-name
        second-fields
        first-name
        first-fields)
      (ErrTcResultInfo
        "typecheck: try requires Result-like enum with Ok*/Err* variants"))))

(define (tc-result-info-from-variants
  [ctx : TcContext]
  [enum-name : String]
  [variants : AstVariantDefList]) : ResultTcResultInfo
  (match variants
    [(AstVariantDefCons first (AstVariantDefCons second AstVariantDefNil))
      (match first
        [(AstVariantDef first-name first-fields)
          (match second
            [(AstVariantDef second-name second-fields)
              (tc-result-info-two-variants
                ctx
                enum-name
                first-name
                first-fields
                second-name
                second-fields)])])]
    [_
      (ErrTcResultInfo
        "typecheck: try requires Result-like enum with exactly two variants")]))

(define (tc-result-info [ctx : TcContext] [ty : AstType]) : ResultTcResultInfo
  (match (tc-type-strip-region ty)
    [(AstTyEnum enum-name)
      (match (tc-program-enum-variants (tc-context-program ctx) enum-name)
        [(OkAstVariantDefList variants)
          (tc-result-info-from-variants ctx enum-name variants)]
        [(ErrAstVariantDefList message) (ErrTcResultInfo message)])]
    [_ (ErrTcResultInfo "typecheck: try requires Result-like enum")]))

(define (tc-try-expr [ctx : TcContext] [env : TcTypeEnv] [inner : AstExpr]) : ResultTcType
  (match (tc-expr ctx env inner)
    [(OkTcType operand-ty)
      (match (tc-result-info ctx operand-ty)
        [(OkTcResultInfo operand-info)
          (match (tc-current-return-type env)
            [(OkTcType return-ty)
              (match (tc-result-info ctx return-ty)
                [(OkTcResultInfo return-info)
                  (match (tc-expect
                    (tc-result-info-err-type operand-info)
                    (tc-result-info-err-type return-info)
                    "typecheck: try error type mismatch")
                    [(OkTcUnit)
                      (OkTcType (tc-result-info-ok-type operand-info))]
                    [(ErrTcUnit message) (ErrTcType message)])]
                [(ErrTcResultInfo _)
                  (ErrTcType
                    "typecheck: try requires enclosing Result-like function")])]
            [(ErrTcType _)
              (ErrTcType
                "typecheck: try requires enclosing Result-like function")])]
        [(ErrTcResultInfo _)
          (ErrTcType "typecheck: try operand must be Result-like enum")])]
    [(ErrTcType message) (ErrTcType message)]))

(define (tc-variant-owner-name [ctx : TcContext] [handle : i64]) : ResultTcString
  (match (tc-context-program ctx)
    [(AstProgram decls)
      (tc-variant-owner-name-list
        decls
        (compiler-registry-handle-owner-index handle)
        0
        "")]))

(define (tc-variant-owner-name-list
  [decls : AstDeclList]
  [target : i64]
  [index : i64]
  [module : String]) : ResultTcString
  (match decls
    [(AstDeclNil) (ErrTcString "typecheck: variant owner is not enum")]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclImport _)
          (tc-variant-owner-name-list rest target index module)]
        [(AstDeclModule next-module)
          (tc-variant-owner-name-list rest target index next-module)]
        [(AstDeclTest _ _ _)
          (tc-variant-owner-name-list rest target index module)]
        [(AstDeclComptimeDecl template)
          (if (= target index)
            (match template
              [(AstDeclDefEnum name _)
                (OkTcString (compiler-symbol-module-key module name))]
              [_ (ErrTcString "typecheck: variant owner is not enum")])
            (tc-variant-owner-name-list rest target (+ index 1) module))]
        [_
          (if (= target index)
            (match decl
              [(AstDeclDefEnum name _)
                (OkTcString (compiler-symbol-module-key module name))]
              [_ (ErrTcString "typecheck: variant owner is not enum")])
            (tc-variant-owner-name-list rest target (+ index 1) module))])]))

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
  (let
    [lit-ty : AstType (tc-literal-type lit)]
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
  [args : AstPatternList]
  [payload-region : TcMaybeString]) : ResultTcEnv
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
                (let
                  [resolved-fields : AstTypeList
                    (tc-resolve-type-list ctx fields)]
                  (tc-bind-sub-pattern-list
                    ctx
                    env
                    args
                    (match payload-region
                      [(TcSomeString region)
                        (tc-tag-type-list-region region resolved-fields)]
                      [(TcNoString) resolved-fields])))]
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
  (let
    [ty : AstType (tc-resolve-type ctx field-ty)]
    (match pattern
      [(AstPatBinding name) (OkTcEnv (tc-bind env name ty))]
      [(AstPatWildcard) (OkTcEnv env)]
      [(AstPatLiteral lit)
        (if (tc-literal-pattern-compatible? lit ty)
          (OkTcEnv env)
          (ErrTcEnv "typecheck: literal pattern type mismatch"))]
      [(AstPatVariant name args)
        (match (tc-type-strip-region ty)
          [(AstTyEnum enum-name)
            (tc-bind-variant-pattern
              ctx
              env
              enum-name
              name
              args
              (tc-type-outer-region ty))]
          [_ (ErrTcEnv "typecheck: nested variant pattern requires enum field")])]
      [_ (ErrTcEnv "typecheck: unsupported nested match pattern")])))

(define (tc-bind-match-pattern
  [ctx : TcContext]
  [env : TcTypeEnv]
  [scrut-ty : AstType]
  [pattern : AstPattern]) : ResultTcEnv
  (match (tc-type-strip-region scrut-ty)
    [(AstTyEnum enum-name)
      (match pattern
        [(AstPatWildcard) (OkTcEnv env)]
        [(AstPatBinding variant-name)
          (tc-bind-variant-pattern
            ctx
            env
            enum-name
            variant-name
            AstPatternNil
            (tc-type-outer-region scrut-ty))]
        [(AstPatVariant variant-name args)
          (tc-bind-variant-pattern
            ctx
            env
            enum-name
            variant-name
            args
            (tc-type-outer-region scrut-ty))]
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
          (match (tc-merge-branch-type want got)
            [(OkTcType merged)
              (tc-match-rest-types ctx env scrut-ty rest merged)]
            [(ErrTcType _) (ErrTcType "typecheck: match arms must agree")])]
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

(define (tc-qualified-name-last-slash [name : String]) : i64
  (let
    [i : i64 0]
    [n : i64 (string-length name)]
    [last : i64 -1]
    (begin
      (while (< i n)
        (begin
          (if (= (string-ref name i) #/')
            (set! last i)
            (set! last last))
          (set! i (+ i 1))))
      last)))

(define (tc-qualified-name-module [name : String]) : String
  (let
    [slash : i64 (tc-qualified-name-last-slash name)]
    (if (< slash 0)
      ""
      (substring name 0 slash))))

(define (tc-qualified-variant-name [enum-name : String] [variant-name : String]) : String
  (let
    [module : String (tc-qualified-name-module enum-name)]
    (if (string-eq module "")
      variant-name
      (compiler-symbol-module-key module variant-name))))

(define (tc-variant-name-matches?
  [enum-name : String]
  [pattern-name : String]
  [variant-name : String]) : bool
  (or
    (string-eq pattern-name variant-name)
    (string-eq pattern-name (tc-qualified-variant-name enum-name variant-name))))

(define (tc-enum-has-single-variant?
  [variants : AstVariantDefList]
  [enum-name : String]
  [variant-name : String]) : bool
  (match variants
    [(AstVariantDefCons variant rest)
      (match rest
        [(AstVariantDefNil)
          (match variant
            [(AstVariantDef name _)
              (tc-variant-name-matches? enum-name variant-name name)])]
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
      (match (tc-type-strip-region (tc-resolve-type ctx field-ty))
        [(AstTyEnum enum-name)
          (match (tc-program-enum-variants (tc-context-program ctx) enum-name)
            [(OkAstVariantDefList variants)
              (if (tc-enum-has-single-variant? variants enum-name name)
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
  [enum-name : String]
  [variant-name : String]) : bool
  (match pattern
    [(AstPatWildcard) true]
    [(AstPatBinding name)
      (tc-variant-name-matches? enum-name name variant-name)]
    [(AstPatVariant name args)
      (and
        (tc-variant-name-matches? enum-name name variant-name)
        (tc-variant-pattern-irrefutable? ctx name args))]
    [_ false]))

(define (tc-match-arms-cover-variant?
  [ctx : TcContext]
  [arms : AstMatchArmList]
  [enum-name : String]
  [variant-name : String]) : bool
  (match arms
    [(AstMatchArmNil) false]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm pattern _)
          (if (tc-pattern-covers-variant? ctx pattern enum-name variant-name)
            true
            (tc-match-arms-cover-variant? ctx rest enum-name variant-name))])]))

(define (tc-enum-variants-covered?
  [ctx : TcContext]
  [enum-name : String]
  [variants : AstVariantDefList]
  [arms : AstMatchArmList]) : bool
  (match variants
    [(AstVariantDefNil) true]
    [(AstVariantDefCons variant rest)
      (match variant
        [(AstVariantDef name _)
          (and
            (tc-match-arms-cover-variant? ctx arms enum-name name)
            (tc-enum-variants-covered? ctx enum-name rest arms))])]))

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
  (match (tc-type-strip-region scrut-ty)
    [(AstTyEnum enum-name)
      (match (tc-program-enum-variants (tc-context-program ctx) enum-name)
        [(OkAstVariantDefList variants)
          (tc-enum-variants-covered? ctx enum-name variants arms)]
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

;; spmd-reduce operator/type rules (#1011, SPEC 5.15): the init/value/result type
;; must be in the operator's supported set -- `sum` over i32/i64/f64, `min`/`max`
;; over i32/i64, `all`/`any` over bool.
(define (tc-reduce-op-type-ok? [op : AstReduceOp] [ty : AstType]) : bool
  (match op
    [(AstReduceSum)
      (match ty
        [(AstTyI32) true]
        [(AstTyI64) true]
        [(AstTyF64) true]
        [_ false])]
    [(AstReduceMin)
      (match ty
        [(AstTyI32) true]
        [(AstTyI64) true]
        [_ false])]
    [(AstReduceMax)
      (match ty
        [(AstTyI32) true]
        [(AstTyI64) true]
        [_ false])]
    [(AstReduceAll)
      (match ty
        [(AstTyBool) true]
        [_ false])]
    [(AstReduceAny)
      (match ty
        [(AstTyBool) true]
        [_ false])]))

(define (tc-reduce-op-type-msg [op : AstReduceOp]) : String
  (match op
    [(AstReduceSum)
      "typecheck: spmd-reduce sum requires an i32, i64, or f64 type"]
    [(AstReduceMin) "typecheck: spmd-reduce min requires an i32 or i64 type"]
    [(AstReduceMax) "typecheck: spmd-reduce max requires an i32 or i64 type"]
    [(AstReduceAll) "typecheck: spmd-reduce all requires a bool type"]
    [(AstReduceAny) "typecheck: spmd-reduce any requires a bool type"]))

;; spmd-reduce purity/effect rules (#1011, SPEC.md §5.16): mirror the Rust
;; typechecker's `check_spmd_reduce_value`. The first reduction slice accepts a
;; narrow, clearly-pure surface and rejects everything else with a focused
;; diagnostic rather than guessing at varying/uniform semantics not yet
;; implemented: the varying index, uniform variables, and literals;
;; arithmetic/comparison/boolean operators over those; `ann`/`cast` wrappers;
;; dynamic-array reads whose index is not itself another array read (direct,
;; non-gather indexing only); and local `let` bindings whose initializers obey
;; the same rules. Writes (`set!`, `array-set!`), function calls, nested
;; `foreach`/`spmd-reduce`, varying control flow (`if`/`while`/`match`),
;; sequencing, and aggregate constructors are rejected. The `in-index` flag is
;; set while walking an array-read index so a nested read (a gather) is
;; rejected. Uniformity of `start`/`end`/`init` is enforced by scoping: they are
;; typed outside the lane context, so referencing the index is an unbound error.
(define (tc-spmd-value-pure [expr : AstExpr]) : ResultTcUnit
  (tc-spmd-value-pure-at expr false))

(define (tc-spmd-value-pure-at [expr : AstExpr] [in-index : bool]) : ResultTcUnit
  (match expr
    [(AstExprSpanned inner _) (tc-spmd-value-pure-at inner in-index)]
    [(AstExprLiteral _) OkTcUnit]
    [(AstExprVar _) OkTcUnit]
    [(AstExprBinary _ left right)
      (match (tc-spmd-value-pure-at left in-index)
        [(OkTcUnit) (tc-spmd-value-pure-at right in-index)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstExprUnary _ inner) (tc-spmd-value-pure-at inner in-index)]
    [(AstExprAnn inner _) (tc-spmd-value-pure-at inner in-index)]
    [(AstExprCast inner _) (tc-spmd-value-pure-at inner in-index)]
    [(AstExprLet bindings body)
      (match (tc-spmd-value-let-bindings-pure-at bindings in-index)
        [(OkTcUnit) (tc-spmd-value-pure-at body in-index)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstExprArrayRef array index)
      (if in-index
        (ErrTcUnit
          "indirect array indexing is not allowed inside a spmd-reduce value expression; gather/scatter is deferred in the first slice (SPEC.md §5.16)")
        (match (tc-spmd-value-pure-at array false)
          [(OkTcUnit) (tc-spmd-value-pure-at index true)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprSet _ _)
      (ErrTcUnit
        "`set!` is not allowed inside a spmd-reduce value expression; reductions must use the explicit accumulator, not outer mutation (SPEC.md §5.16)")]
    [(AstExprArraySet _ _ _)
      (ErrTcUnit
        "`array-set!` is not allowed inside a spmd-reduce value expression; the value expression must be free of writes and other side effects (SPEC.md §5.16)")]
    [(AstExprCall _ _)
      (ErrTcUnit
        "function calls are not allowed inside a spmd-reduce value expression; side-effecting builtins and user calls with varying arguments are deferred in the first slice (SPEC.md §5.16)")]
    [(AstExprForeach _ _ _ _ _)
      (ErrTcUnit
        "a nested foreach is not allowed inside a spmd-reduce value expression (SPEC.md §5.16)")]
    [(AstExprSpmdReduce _ _ _ _ _ _ _)
      (ErrTcUnit
        "a nested spmd-reduce is not allowed inside a spmd-reduce value expression (SPEC.md §5.16)")]
    [(AstExprIf _ _ _)
      (ErrTcUnit
        "varying control flow is not allowed inside a spmd-reduce value expression; the first slice has no varying if/while/match (SPEC.md §5.16)")]
    [(AstExprWhile _ _)
      (ErrTcUnit
        "varying control flow is not allowed inside a spmd-reduce value expression; the first slice has no varying if/while/match (SPEC.md §5.16)")]
    [(AstExprMatch _ _)
      (ErrTcUnit
        "varying control flow is not allowed inside a spmd-reduce value expression; the first slice has no varying if/while/match (SPEC.md §5.16)")]
    [_
      (ErrTcUnit
        "this expression is not allowed inside a spmd-reduce value expression; the first slice allows only the varying index, uniform variables, literals, arithmetic/comparison/boolean operators, dynamic-array reads, and local let bindings (SPEC.md §5.16)")]))

(define (tc-spmd-value-let-bindings-pure-at
  [bindings : AstLetBindingList]
  [in-index : bool]) : ResultTcUnit
  (match bindings
    [(AstLetBindingNil) OkTcUnit]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding _ _ init)
          (match (tc-spmd-value-pure-at init in-index)
            [(OkTcUnit) (tc-spmd-value-let-bindings-pure-at rest in-index)]
            [(ErrTcUnit message) (ErrTcUnit message)])])]))

(define (tc-expr [ctx : TcContext] [env : TcTypeEnv] [expr : AstExpr]) : ResultTcType
  (match expr
    [(AstExprSpanned inner _) (tc-expr ctx env inner)]
    [(AstExprLiteral lit) (OkTcType (tc-literal-type lit))]
    [(AstExprVar name) (tc-lookup env name)]
    [(AstExprTypeLiteral ty)
      (ErrTcType
        (string-append
          "type value "
          (string-append
            (tc-type-render (tc-resolve-type ctx ty))
            " is compile-time only")))]
    [(AstExprAnn inner ty)
      (match (tc-expr ctx env inner)
        [(OkTcType got)
          (match (tc-expect
            got
            (tc-resolve-type ctx ty)
            "typecheck: annotation type mismatch")
            [(OkTcUnit)
              (OkTcType
                (if (tc-type-contains-any-region got)
                  got
                  (tc-resolve-type ctx ty)))]
            [(ErrTcUnit message) (ErrTcType message)])]
        [(ErrTcType message) (ErrTcType message)])]
    [(AstExprLet bindings body)
      (match (tc-let-bindings ctx env bindings)
        [(OkTcEnv next-env) (tc-expr ctx next-env body)]
        [(ErrTcEnv message) (ErrTcType message)])]
    [(AstExprLambda params maybe-ret body)
      (match (tc-check-lambda-region-captures env params body)
        [(OkTcUnit)
          (let
            [lambda-env : TcTypeEnv
              (match maybe-ret
                [(AstSomeType ret)
                  (tc-bind-return-type
                    (tc-bind-params ctx env params)
                    (tc-resolve-type ctx ret))]
                [(AstNoType)
                  (tc-bind-return-type
                    (tc-bind-params ctx env params)
                    (AstTyNever))])]
            (match (tc-expr ctx lambda-env body)
              [(OkTcType body-ty)
                (if (tc-type-contains-any-region body-ty)
                  (ErrTcType
                    "typecheck: lambda return value has region-tagged type; region value would escape")
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
                      (OkTcType
                        (AstTyFunc (tc-param-type-list ctx params) body-ty))]))]
              [(ErrTcType message) (ErrTcType message)]))]
        [(ErrTcUnit message) (ErrTcType message)])]
    [(AstExprTuple exprs)
      (match (tc-expr-list-types ctx env exprs)
        [(OkTcTypeList tys)
          (OkTcType (tc-tag-active-region env (AstTyTuple tys)))]
        [(ErrTcTypeList message) (ErrTcType message)])]
    [(AstExprTupleRef tuple index)
      (match (tc-expr ctx env tuple)
        [(OkTcType tuple-ty)
          (match (tc-type-strip-region tuple-ty)
            [(AstTyTuple tys)
              (match (tc-type-list-ref tys index)
                [(OkTcType elem-ty)
                  (OkTcType (tc-project-from-region-container tuple-ty elem-ty))]
                [(ErrTcType message) (ErrTcType message)])]
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
      (let
        [elem : AstType (tc-resolve-type ctx elem-ty)]
        (match (tc-expr ctx env len)
          [(OkTcType len-ty)
            (if (tc-integer-type? len-ty)
              (if (tc-dyn-array-elem-supported? elem)
                (OkTcType (tc-tag-active-region env (AstTyDynArray elem)))
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
                (match (tc-type-strip-region array-ty)
                  [(AstTyArray elem-ty _)
                    (OkTcType
                      (tc-project-from-region-container array-ty elem-ty))]
                  [(AstTyDynArray elem-ty)
                    (OkTcType
                      (tc-project-from-region-container array-ty elem-ty))]
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
                (match (tc-type-strip-region array-ty)
                  [(AstTyArray elem-ty _)
                    (match (tc-expr ctx env value)
                      [(OkTcType value-ty)
                        (match (tc-expect
                          value-ty
                          elem-ty
                          "typecheck: array-set! value type mismatch")
                          [(OkTcUnit)
                            (match (tc-ensure-region-value-can-flow-into
                              env
                              array-ty
                              value-ty
                              "array")
                              [(OkTcUnit) (OkTcType (AstTyUnit))]
                              [(ErrTcUnit message) (ErrTcType message)])]
                          [(ErrTcUnit message) (ErrTcType message)])]
                      [(ErrTcType message) (ErrTcType message)])]
                  [(AstTyDynArray elem-ty)
                    (match (tc-expr ctx env value)
                      [(OkTcType value-ty)
                        (match (tc-expect
                          value-ty
                          elem-ty
                          "typecheck: array-set! value type mismatch")
                          [(OkTcUnit)
                            (match (tc-ensure-region-value-can-flow-into
                              env
                              array-ty
                              value-ty
                              "array")
                              [(OkTcUnit) (OkTcType (AstTyUnit))]
                              [(ErrTcUnit message) (ErrTcType message)])]
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
    ;; `(unsafe ...)` types like `begin` in v1; the unsafe-context flag for
    ;; raw-pointer ops is added with their checks (#955).
    [(AstExprUnsafe exprs) (tc-begin-list ctx env exprs)]
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
                [(OkTcUnit)
                  (match (tc-ensure-region-value-can-flow-into
                    env
                    var-ty
                    value-ty
                    "assignment")
                    [(OkTcUnit) (OkTcType (AstTyUnit))]
                    [(ErrTcUnit message) (ErrTcType message)])]
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
      (let
        [resolved-index-ty : AstType (tc-resolve-type ctx index-ty)]
        (if (tc-integer-type? resolved-index-ty)
          (match (tc-expr ctx env start)
            [(OkTcType start-ty)
              (if (tc-integer-type? start-ty)
                (match (tc-expr ctx env end)
                  [(OkTcType end-ty)
                    (if (tc-integer-type? end-ty)
                      (let
                        [body-env : TcTypeEnv
                          (tc-bind env index resolved-index-ty)]
                        (match (tc-expr ctx body-env body)
                          [(OkTcType body-ty)
                            (match (tc-expect
                              body-ty
                              (AstTyUnit)
                              "typecheck: foreach body must be unit")
                              [(OkTcUnit)
                                (match (tc-spmd-check-foreach-body
                                  ctx
                                  env
                                  index
                                  resolved-index-ty
                                  body)
                                  [(OkTcUnit) (OkTcType (AstTyUnit))]
                                  [(ErrTcUnit message) (ErrTcType message)])]
                              [(ErrTcUnit message) (ErrTcType message)])]
                          [(ErrTcType message) (ErrTcType message)]))
                      (ErrTcType
                        "typecheck: foreach end expression must be integer"))]
                  [(ErrTcType message) (ErrTcType message)])
                (ErrTcType
                  "typecheck: foreach start expression must be integer"))]
            [(ErrTcType message) (ErrTcType message)])
          (ErrTcType "typecheck: foreach index type must be integer")))]
    [(AstExprSpmdReduce op index index-ty start end init value)
      (let
        [resolved-index-ty : AstType (tc-resolve-type ctx index-ty)]
        (if (tc-integer-type? resolved-index-ty)
          (match (tc-expr ctx env start)
            [(OkTcType start-ty)
              (if (tc-integer-type? start-ty)
                (match (tc-expr ctx env end)
                  [(OkTcType end-ty)
                    (if (tc-integer-type? end-ty)
                      (match (tc-expr ctx env init)
                        [(OkTcType init-ty)
                          (if (tc-reduce-op-type-ok?
                            op
                            (tc-resolve-type ctx init-ty))
                            (match (tc-spmd-value-pure value)
                              [(OkTcUnit)
                                (let
                                  [value-env : TcTypeEnv
                                    (tc-bind env index resolved-index-ty)]
                                  (match (tc-expr ctx value-env value)
                                    [(OkTcType value-ty)
                                      (match (tc-expect
                                        value-ty
                                        init-ty
                                        "typecheck: spmd-reduce init and value type mismatch")
                                        [(OkTcUnit) (OkTcType init-ty)]
                                        [(ErrTcUnit message)
                                          (ErrTcType message)])]
                                    [(ErrTcType message) (ErrTcType message)]))]
                              [(ErrTcUnit message) (ErrTcType message)])
                            (ErrTcType (tc-reduce-op-type-msg op)))]
                        [(ErrTcType message) (ErrTcType message)])
                      (ErrTcType
                        "typecheck: spmd-reduce end expression must be integer"))]
                  [(ErrTcType message) (ErrTcType message)])
                (ErrTcType
                  "typecheck: spmd-reduce start expression must be integer"))]
            [(ErrTcType message) (ErrTcType message)])
          (ErrTcType "typecheck: spmd-reduce index type must be integer")))]
    [(AstExprMatch scrutinee arms)
      (match (tc-expr ctx env scrutinee)
        [(OkTcType scrut-ty) (tc-match-expr ctx env scrut-ty arms)]
        [(ErrTcType message) (ErrTcType message)])]
    [(AstExprStructGet receiver field)
      (match (tc-expr ctx env receiver)
        [(OkTcType receiver-ty)
          (match (tc-type-strip-region receiver-ty)
            [(AstTyStruct struct-name)
              (match (tc-struct-field-type ctx struct-name field)
                [(OkTcType field-ty)
                  (OkTcType
                    (tc-project-from-region-container receiver-ty field-ty))]
                [(ErrTcType message) (ErrTcType message)])]
            [_ (ErrTcType "typecheck: struct-get requires struct")])]
        [(ErrTcType message) (ErrTcType message)])]
    [(AstExprWithRegion region body)
      (let
        [region-env : TcTypeEnv (tc-push-region env region)]
        (match (tc-begin-list ctx region-env body)
          [(OkTcType body-ty)
            (if (tc-type-contains-region body-ty region)
              (ErrTcType
                (string-append
                  "typecheck: region-tagged value cannot escape with-arena '"
                  (string-append region "'")))
              (OkTcType body-ty))]
          [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprComptime inner)
      (match (compiler-ctfe-eval inner (ctfe-env-empty) (ctfe-fuel-limit))
        [(OkCtfe value _)
          (match value
            [(CtfeI64 _) (OkTcType (AstTyI64))]
            [(CtfeBool _) (OkTcType (AstTyBool))]
            [(CtfeChar _) (OkTcType (AstTyChar))]
            [(CtfeUnit) (OkTcType (AstTyUnit))]
            [(CtfeType ty)
              (ErrTcType
                (string-append
                  "type value "
                  (string-append
                    (tc-type-render (tc-resolve-type ctx ty))
                    " is compile-time only")))]
            [(CtfeExpr _) (ErrTcType "Expr value is compile-time only (#1135)")]
            [(CtfeExprList _)
              (ErrTcType "ExprList value is compile-time only (#1135)")])]
        [(ErrCtfe diag) (ErrTcType (compiler-diagnostic-message diag))])]
    [(AstExprTry inner) (tc-try-expr ctx env inner)]
    [(AstExprPtrNull ty)
      (let
        [resolved : AstType (tc-resolve-type ctx ty)]
        (match resolved
          [(AstTyPtr _) (OkTcType resolved)]
          [(AstTyMutPtr _) (OkTcType resolved)]
          [_
            (ErrTcType
              "typecheck: ptr-null requires a pointer type, e.g. (ptr-null : (Ptr i64))")]))]
    [(AstExprPtrNullCheck inner)
      (match (tc-expr ctx env inner)
        [(OkTcType inner-ty)
          (match (tc-type-strip-region inner-ty)
            [(AstTyPtr _) (OkTcType (AstTyBool))]
            [(AstTyMutPtr _) (OkTcType (AstTyBool))]
            [_
              (ErrTcType "typecheck: ptr-null? requires a raw pointer operand")])]
        [(ErrTcType message) (ErrTcType message)])]
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
      (let
        [env : TcTypeEnv
          (tc-bind-return-type
            (tc-bind-params ctx top-env params)
            (tc-resolve-type ctx ret))]
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
      (let
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) ""])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest) path-rest]
            [(AstDeclPathNil) AstDeclPathNil])]
        (match (tc-check-decl ctx top-env decl)
          [(OkTcUnit)
            (tc-check-decls-with-paths
              ctx
              top-env
              rest
              rest-paths
              (tc-summary-add-decl summary decl))]
          [(ErrTcUnit message)
            (let
              [diag : CompilerDiagnostic (tc-decl-diag decl message)]
              (if (string-eq decl-path "")
                (ErrCompilerTypecheck diag)
                (ErrCompilerTypecheck
                  (compiler-diagnostic-with-path diag decl-path))))]))]))

(define (typecheck-compiler-specialized-program-with-paths
  [program : AstProgram]
  [paths : AstDeclPathList]) : ResultCompilerTypecheck
  (match (build-compiler-symbols program)
    [(OkCompilerSymbols symbols)
      (match (build-compiler-registries program)
        [(OkCompilerRegistries registries)
          (let
            [ctx : TcContext (TcContext program symbols registries)]
            (match (tc-program-source-types-policy-ok ctx program)
              [(OkTcUnit)
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
                    (ErrCompilerTypecheck (tc-diag-at-start message))])]
              [(ErrTcUnit message)
                (ErrCompilerTypecheck (tc-diag-at-start message))]))]
        [(ErrCompilerRegistries message)
          (ErrCompilerTypecheck (tc-diag-at-start message))])]
    [(ErrCompilerSymbols message)
      (ErrCompilerTypecheck (tc-diag-at-start message))]))

(define (typecheck-compiler-program-with-paths
  [program : AstProgram]
  [paths : AstDeclPathList]) : ResultCompilerTypecheck
  (let
    [specialized-paths : AstDeclPathList
      (if (compiler-specialize-needed? program)
        AstDeclPathNil
        paths)]
    (match (compiler-specialize-program program)
      [(OkSpecProgram specialized)
        (typecheck-compiler-specialized-program-with-paths
          specialized
          specialized-paths)]
      [(ErrSpecProgram diag) (ErrCompilerTypecheck diag)])))

(define (typecheck-compiler-program [program : AstProgram]) : ResultCompilerTypecheck
  (typecheck-compiler-program-with-paths program AstDeclPathNil))

(define (typecheck-compiler-repl-expr [decls : AstDeclList] [expr : AstExpr]) : ResultTcType
  (let
    [program : AstProgram (AstProgram decls)]
    (match (build-compiler-symbols program)
      [(OkCompilerSymbols symbols)
        (match (build-compiler-registries program)
          [(OkCompilerRegistries registries)
            (let
              [ctx : TcContext (TcContext program symbols registries)]
              (match (tc-program-source-types-policy-ok ctx program)
                [(OkTcUnit)
                  (match (tc-source-expr-policy-ok ctx expr)
                    [(OkTcUnit)
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
                        [(ErrTcEnv message) (ErrTcType message)])]
                    [(ErrTcUnit message) (ErrTcType message)])]
                [(ErrTcUnit message) (ErrTcType message)]))]
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
  (let
    [x : i64 (inc answer)]
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

(define (compiler-typecheck-type-parameter-source) : String
  "(define (id [x : T]) : T x)")

(define (compiler-typecheck-aggregate-source) : String
  "(define (id-lambda [n : i64]) : i64
  (let
    [f : (-> i64 i64) (lambda ([x : i64]) : i64 (+ x 1))]
    (f n)))
(define (main [n : i64] [s : String]) : i64
  (let
    [fixed : (Array i64 3) (array 1 2 3)]
    [t : (Tuple i64 bool) (tuple 7 true)]
    [a : (Array i64) (make-array i64 n)]
    (begin
      (array-set! a 0 (cast (string-ref s 0) : i64))
      (foreach ([i : i64 0 n])
        (array-set! a i (+ (array-ref a i) 1)))
      (+ (array-length a)
         (+ (tuple-ref t 0) (+ (array-ref fixed 1) (id-lambda 3)))))))")

(define (compiler-typecheck-builtin-source) : String
  "(define (main [s : String]) : String
  (begin
    (fs-mkdir-status s)
    (fs-remove-file-status s)
    (fs-remove-dir-status s)
    (fs-process-id)
    (string-append (substring s 0 (length s))
                   (int->string (string->int \"7\")))))")

(define (compiler-typecheck-stdio-source) : String
  "(define (main) : i64
  (begin
    (flush-stdout)
    (if (stdin-eof?)
        (string-length (read-stdin-line))
        (string-length (read-stdin-bytes 3)))))")

(define (compiler-typecheck-env-source) : String
  "(define (main [name : String]) : String
  (if (env-var-exists? name)
    (env-var-value name)
    (env-path-separator)))")

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

(define (compiler-typecheck-foreach-spmd-ok-source) : String
  "(define (main [n : i64]) : unit
  (let
    [a : (Array i64) (make-array i64 n)]
    [b : (Array i64) (make-array i64 n)]
    [out : (Array i64) (make-array i64 n)]
    (foreach ([i : i64 0 n])
      (let
        [sum : i64 (+ (array-ref a i) (array-ref b i))]
        (array-set! out i sum)))))")

(define (compiler-typecheck-foreach-varying-if-source) : String
  "(define (main [xs : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (if (= (array-ref xs i) 0) unit unit)))")

(define (compiler-typecheck-foreach-varying-while-source) : String
  "(define (main [xs : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (while (< (array-ref xs i) 0) unit)))")

(define (compiler-typecheck-foreach-varying-call-source) : String
  "(define (sink [x : i64]) : unit unit)
(define (main [xs : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (sink (array-ref xs i))))")

(define (compiler-typecheck-foreach-outer-set-source) : String
  "(define (main [xs : (Array i64)] [n : i64]) : i64
  (let
    [sum : i64 0]
    (begin
      (foreach ([i : i64 0 n])
        (set! sum (+ sum (array-ref xs i))))
      sum)))")

(define (compiler-typecheck-foreach-unsupported-lane-source) : String
  "(define (main [ss : (Array String)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [s : String (array-ref ss i)]
      unit)))")

(define (compiler-typecheck-foreach-if-local-set-source) : String
  "(define (sink [x : i64]) : unit unit)
(define (main [xs : (Array i64)] [flag : bool] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [x : i64 0]
      (begin
        (if flag (set! x (array-ref xs i)) unit)
        (sink x)))))")

(define (compiler-typecheck-foreach-while-local-set-source) : String
  "(define (sink [x : i64]) : unit unit)
(define (main [xs : (Array i64)] [flag : bool] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [x : i64 0]
      (begin
        (while flag (set! x (array-ref xs i)))
        (sink x)))))")

(define (compiler-typecheck-foreach-match-local-set-source) : String
  "(defenum Maybe (None) (Some i64))
(define (sink [x : i64]) : unit unit)
(define (main [m : Maybe] [xs : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [x : i64 0]
      (begin
        (match m [(Some v) (set! x (array-ref xs i))] [None unit])
        (sink x)))))")

(define (compiler-typecheck-foreach-local-set-ok-source) : String
  "(define (sink [x : i64]) : unit unit)
(define (main [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [x : i64 0]
      (begin
        (set! x 1)
        (sink x)))))")

(define (compiler-typecheck-foreach-control-flow-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-foreach-local-set-ok-source))
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-foreach-if-local-set-source)
        "typecheck: foreach calls with varying arguments are not supported")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-foreach-while-local-set-source)
          "typecheck: foreach calls with varying arguments are not supported")
        (compiler-typecheck-error-ok?
          (compiler-typecheck-foreach-match-local-set-source)
          "typecheck: foreach calls with varying arguments are not supported")))))

(define (compiler-typecheck-foreach-spmd-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-foreach-spmd-ok-source))
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-foreach-varying-if-source)
        "typecheck: foreach if condition must be uniform")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-foreach-varying-while-source)
          "typecheck: foreach while condition must be uniform")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-foreach-varying-call-source)
            "typecheck: foreach calls with varying arguments are not supported")
          (and
            (compiler-typecheck-error-ok?
              (compiler-typecheck-foreach-outer-set-source)
              "typecheck: foreach cannot set binding declared outside foreach")
            (and
              (compiler-typecheck-error-ok?
                (compiler-typecheck-foreach-unsupported-lane-source)
                "typecheck: foreach varying array lane type is not supported: String")
              (compiler-typecheck-foreach-control-flow-tests-ok?))))))))

(define (compiler-typecheck-abstraction-policy-tests-ok?) : bool
  (compiler-typecheck-error-ok?
    (compiler-typecheck-type-parameter-source)
    (tc-source-type-policy-message "T")))

(define (compiler-typecheck-aggregate-tests-ok?) : bool
  (and
    (compiler-typecheck-ok-score? (compiler-typecheck-aggregate-source) 20)
    (and
      (compiler-typecheck-ok-score? (compiler-typecheck-builtin-source) 10)
      (and
        (compiler-typecheck-ok-score? (compiler-typecheck-stdio-source) 10)
        (and
          (compiler-typecheck-ok-score? (compiler-typecheck-env-source) 10)
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
                            "typecheck: lambda return type mismatch"))))))))))))))

(define (compiler-typecheck-nominal-source) : String
  "(defenum Maybe (None) (Some i64))
(defstruct Point (x i64) (y i64))
(define (from-maybe [m : Maybe]) : i64
  (match m [(Some v) v] [None 0]))
(define (main) : i64
  (let
    [p : Point (Point 40 2)]
    (+ (struct-get p x) (from-maybe (Some (struct-get p y))))))")

(define (compiler-typecheck-comptime-decl-source) : String
  "(comptime-decl (defstruct Point (x i64) (y i64)))
(comptime-decl (defenum Maybe (None) (Some i64)))
(define (main) : i64
  (let
    [p : Point (Point 40 2)]
    (match (Some (struct-get p y))
      [(Some n) (+ (struct-get p x) n)]
      [None 0])))")

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

(define (compiler-typecheck-module-qualified-source) : String
  "(module left)
(define (get) : i64 20)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module right)
(define (get) : i64 22)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module main)
(define (main) : i64
  (+
    (left/get)
    (+
      (right/get)
      (+
        (let ([p : right/Point (right/Point 7)])
          (struct-get p x))
        (match (right/Some 1)
          [(right/Some v) v]
          [right/None 0])))))")

(define (compiler-typecheck-repr-c-layout-source) : String
  "(defstruct Packet
  (:repr c)
  (tag u8)
  (count i64)
  (flag bool))
(defstruct Inner
  (:repr c)
  (a u8)
  (b i32))
(defstruct Outer
  (:repr c)
  (tag u8)
  (inner Inner)
  (tail u16))")

(define (compiler-typecheck-repr-c-layout-ok?) : bool
  (match (parse-ast-source (compiler-typecheck-repr-c-layout-source))
    [(OkAstProgram program)
      (match (build-compiler-symbols program)
        [(OkCompilerSymbols symbols)
          (match (build-compiler-registries program)
            [(OkCompilerRegistries registries)
              (let
                [ctx : TcContext (TcContext program symbols registries)]
                (match (tc-repr-c-struct-layout ctx "Packet")
                  [(OkTcReprCLayout packet)
                    (match (tc-repr-c-struct-layout ctx "Outer")
                      [(OkTcReprCLayout outer)
                        (and
                          (= (tc-repr-c-layout-size packet) 24)
                          (and
                            (= (tc-repr-c-layout-align packet) 8)
                            (and
                              (=
                                (tc-repr-c-layout-field-offset
                                  (tc-repr-c-layout-fields packet)
                                  "tag")
                                0)
                              (and
                                (=
                                  (tc-repr-c-layout-field-offset
                                    (tc-repr-c-layout-fields packet)
                                    "count")
                                  8)
                                (and
                                  (=
                                    (tc-repr-c-layout-field-offset
                                      (tc-repr-c-layout-fields packet)
                                      "flag")
                                    16)
                                  (and
                                    (= (tc-repr-c-layout-size outer) 16)
                                    (and
                                      (= (tc-repr-c-layout-align outer) 4)
                                      (and
                                        (=
                                          (tc-repr-c-layout-field-offset
                                            (tc-repr-c-layout-fields outer)
                                            "inner")
                                          4)
                                        (=
                                          (tc-repr-c-layout-field-offset
                                            (tc-repr-c-layout-fields outer)
                                            "tail")
                                          12)))))))))]
                      [(ErrTcReprCLayout _) false])]
                  [(ErrTcReprCLayout _) false]))]
            [(ErrCompilerRegistries _) false])]
        [(ErrCompilerSymbols _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-typecheck-repr-c-string-source) : String
  "(defstruct Bad
  (:repr c)
  (s String))")

(define (compiler-typecheck-repr-c-default-nested-source) : String
  "(defstruct Inner (x i64))
(defstruct Bad
  (:repr c)
  (inner Inner))")

(define (compiler-typecheck-repr-c-recursive-source) : String
  "(defstruct Node
  (:repr c)
  (next Node))")

(define (compiler-typecheck-repr-c-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-repr-c-layout-source))
    (and
      (compiler-typecheck-repr-c-layout-ok?)
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-repr-c-string-source)
          "typecheck: repr c struct Bad field s has unsupported field type String")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-repr-c-default-nested-source)
            "typecheck: repr c struct Bad field inner references default-layout struct Inner")
          (compiler-typecheck-error-ok?
            (compiler-typecheck-repr-c-recursive-source)
            "typecheck: recursive repr c struct layout cycle involving Node"))))))

(define (compiler-typecheck-nominal-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-nominal-source))
    (and
      (compiler-typecheck-ok? (compiler-typecheck-comptime-decl-source))
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
            (and
              (compiler-typecheck-error-ok?
                (compiler-typecheck-duplicate-variant-source)
                "symbols: duplicate enum variant Same")
              (and
                (compiler-typecheck-ok?
                  (compiler-typecheck-module-qualified-source))
                (compiler-typecheck-repr-c-tests-ok?)))))))))

(define (compiler-typecheck-region-builtin-source) : String
  "(define (main) : i64
  (with-arena r
    (let
      [s : String (int->string 41)]
      (string-length s))))")

(define (compiler-typecheck-region-escape-source) : String
  "(define (main) : String
  (with-arena r (int->string 41)))")

(define (compiler-typecheck-region-user-call-source) : String
  "(define (sink [s : String]) : i64 (string-length s))
(define (main) : i64
  (with-arena r
    (let
      [s : String (int->string 41)]
      (sink s))))")

(define (compiler-typecheck-region-nested-escape-source) : String
  "(define (main) : i64
  (with-arena outer
    (let
      [s : String (with-arena inner (int->string 1))]
      0)))")

(define (compiler-typecheck-region-outer-in-inner-source) : String
  "(define (main) : i64
  (with-arena outer
    (let
      [s : String (int->string 1)]
      (with-arena inner (string-length s)))))")

(define (compiler-typecheck-region-array-source) : String
  "(define (main [n : i64]) : i64
  (with-arena r
    (let
      [a : (Array i64) (make-array i64 n)]
      (begin
        (array-set! a 0 7)
        (array-length a)))))")

(define (compiler-typecheck-region-struct-escape-source) : String
  "(defstruct Box (s String))
(define (main) : String
  (with-arena r
    (let
      [b : Box (Box (int->string 1))]
      (struct-get b s))))")

(define (compiler-typecheck-region-match-source) : String
  "(defenum Token (Text String) (End))
(define (main) : i64
  (with-arena r
    (match (Text (int->string 1))
      [(Text s) (string-length s)]
      [End 0])))")

(define (compiler-typecheck-region-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-region-builtin-source))
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-region-escape-source)
        "typecheck: region-tagged value cannot escape with-arena 'r'")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-region-user-call-source)
          "typecheck: cannot pass region-tagged value to function parameter; region value would escape")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-region-nested-escape-source)
            "typecheck: region-tagged value cannot escape with-arena 'inner'")
          (and
            (compiler-typecheck-ok?
              (compiler-typecheck-region-outer-in-inner-source))
            (and
              (compiler-typecheck-ok? (compiler-typecheck-region-array-source))
              (and
                (compiler-typecheck-error-ok?
                  (compiler-typecheck-region-struct-escape-source)
                  "typecheck: region-tagged value cannot escape with-arena 'r'")
                (compiler-typecheck-ok?
                  (compiler-typecheck-region-match-source))))))))))

(define (compiler-typecheck-result-try-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (read [flag : bool]) : ResultI64
  (if flag (OkI64 41) (ErrI64 \"read failed\")))
(define (step [flag : bool]) : ResultI64
  (OkI64 (try (read flag))))
(define (main [a : bool] [b : bool]) : ResultI64
  (let ([x : i64 (try (step a))]
        [y : i64 0])
    (begin
      (set! y (try (read b)))
      (OkI64 (+ x y)))))")

(define (compiler-typecheck-result-try-non-result-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (main) : ResultI64
  (OkI64 (try 1)))")

(define (compiler-typecheck-result-try-non-result-return-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (read) : ResultI64 (OkI64 1))
(define (main) : i64
  (try (read)))")

(define (compiler-typecheck-result-try-incompatible-error-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(defenum OtherResult (OkOther i64) (ErrOther i64))
(define (read) : OtherResult (ErrOther 7))
(define (main) : ResultI64
  (OkI64 (try (read))))")

(define (compiler-typecheck-result-try-panic-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (main [flag : bool]) : ResultI64
  (if flag (panic \"stop\") (OkI64 1)))")

(define (compiler-typecheck-result-try-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-result-try-source))
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-result-try-non-result-source)
        "typecheck: try operand must be Result-like enum")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-result-try-non-result-return-source)
          "typecheck: try requires enclosing Result-like function")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-result-try-incompatible-error-source)
            "typecheck: try error type mismatch")
          (compiler-typecheck-ok? (compiler-typecheck-result-try-panic-source)))))))

(define (compiler-typecheck-raw-pointer-source) : String
  "(extern raw-sink : (-> (Ptr i64) unit))
(extern raw-make : (-> (MutPtr (Ptr u8))))
(define (main [p : (Ptr i64)]) : unit
  (raw-sink p))")

(define (compiler-typecheck-raw-pointer-render-ok?) : bool
  (and
    (string-eq (tc-type-render (AstTyPtr (AstTyI64))) "(Ptr i64)")
    (and
      (string-eq
        (tc-type-render (AstTyMutPtr (AstTyPtr (AstTyU8))))
        "(MutPtr (Ptr u8))")
      (and
        (tc-type-eq (AstTyPtr (AstTyI64)) (AstTyPtr (AstTyI64)))
        (and
          (not (tc-type-eq (AstTyPtr (AstTyI64)) (AstTyMutPtr (AstTyI64))))
          (tc-type-eq
            (AstTyPtr (AstTyRegion "r" (AstTyI64)))
            (AstTyPtr (AstTyI64))))))))

(define (compiler-typecheck-raw-pointer-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-raw-pointer-source))
    (compiler-typecheck-raw-pointer-render-ok?)))

(define (compiler-typecheck-reference-source) : String
  "(define (use-string [s : (& r String)]) : i64
  (string-length s))")

(define (compiler-typecheck-reference-render-ok?) : bool
  (and
    (string-eq (tc-type-render (AstTyRef "r" (AstTyString))) "(& r String)")
    (and
      (string-eq
        (tc-type-render (AstTyMutRef "phase" (AstTyDynArray (AstTyI64))))
        "(&mut phase (Array i64))")
      (and
        (tc-type-eq
          (AstTyRef "r" (AstTyRegion "inner" (AstTyI64)))
          (AstTyRef "r" (AstTyI64)))
        (and
          (not (tc-type-eq (AstTyRef "r" (AstTyI64)) (AstTyRef "s" (AstTyI64))))
          (and
            (not
              (tc-type-eq
                (AstTyRef "r" (AstTyI64))
                (AstTyMutRef "r" (AstTyI64))))
            (and
              (tc-type-contains-region (AstTyRef "r" (AstTyI64)) "r")
              (tc-type-contains-region
                (AstTyMutRef "phase" (AstTyRegion "inner" (AstTyString)))
                "inner"))))))))

(define (compiler-typecheck-reference-tests-ok?) : bool
  (and
    (compiler-typecheck-reference-render-ok?)
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reference-source)
      "typecheck: reference types require borrow checker support (#803/#806/#804)")))

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

;; Statement and control-flow type rules (#1042): if/while conditions, the
;; while-body unit rule, set!/let annotation mismatches, and `ann` mismatch,
;; plus an accepting program exercising the same forms. Migrated from
;; src/typechecker.rs unit coverage.
(define (compiler-typecheck-stmt-if-cond-source) : String
  "(define (main) : i64 (if 1 2 3))")

(define (compiler-typecheck-stmt-while-cond-source) : String
  "(define (main [n : i64]) : unit
  (let [i : i64 n] (while i (set! i (- i 1)))))")

(define (compiler-typecheck-stmt-while-body-source) : String
  "(define (main [n : i64]) : unit
  (let [i : i64 n] (while (> i 0) i)))")

(define (compiler-typecheck-stmt-set-mismatch-source) : String
  "(define (main) : i64
  (let [x : i64 0] (begin (set! x true) x)))")

(define (compiler-typecheck-stmt-let-mismatch-source) : String
  "(define (main) : i64 (let [x : i64 true] x))")

(define (compiler-typecheck-stmt-ann-mismatch-source) : String
  "(define (main) : i64 (ann true : i64))")

(define (compiler-typecheck-stmt-ok-while-source) : String
  "(define (main [n : i64]) : unit
  (let [i : i64 n] (while (> i 0) (set! i (- i 1)))))")

(define (compiler-typecheck-stmt-ok-if-set-source) : String
  "(define (main [flag : bool]) : i64
  (let [x : i64 0] (begin (set! x 5) (if flag x 0))))")

(define (compiler-typecheck-stmt-ok-cast-ann-source) : String
  "(define (main [c : char]) : i64 (ann (cast c : i64) : i64))")

(define (compiler-typecheck-statement-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      (compiler-typecheck-stmt-if-cond-source)
      "typecheck: if condition must be bool")
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-stmt-while-cond-source)
        "typecheck: while condition must be bool")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-stmt-while-body-source)
          "typecheck: while body must be unit")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-stmt-set-mismatch-source)
            "typecheck: assignment type mismatch")
          (and
            (compiler-typecheck-error-ok?
              (compiler-typecheck-stmt-let-mismatch-source)
              "typecheck: let binding type mismatch")
            (and
              (compiler-typecheck-error-ok?
                (compiler-typecheck-stmt-ann-mismatch-source)
                "typecheck: annotation type mismatch")
              (and
                (compiler-typecheck-ok?
                  (compiler-typecheck-stmt-ok-while-source))
                (and
                  (compiler-typecheck-ok?
                    (compiler-typecheck-stmt-ok-if-set-source))
                  (compiler-typecheck-ok?
                    (compiler-typecheck-stmt-ok-cast-ann-source)))))))))))

;; Operator and call type rules (#1042): equality/comparison/integer operator
;; operand matching and call arity, plus accepting arithmetic/comparison/call
;; programs. Migrated from src/typechecker.rs unit coverage.
(define (compiler-typecheck-op-eq-mismatch-source) : String
  "(define (main) : bool (= 1 true))")

(define (compiler-typecheck-op-int-mismatch-source) : String
  "(define (main) : i64 (+ 1 true))")

(define (compiler-typecheck-op-cmp-mismatch-source) : String
  "(define (main) : bool (< 1 true))")

(define (compiler-typecheck-op-arity-many-source) : String
  "(define (f [x : i64]) : i64 x)
(define (main) : i64 (f 1 2))")

(define (compiler-typecheck-op-arity-few-source) : String
  "(define (f [x : i64] [y : i64]) : i64 (+ x y))
(define (main) : i64 (f 1))")

(define (compiler-typecheck-op-ok-arith-source) : String
  "(define (main) : i64 (+ (* 2 3) (- 10 4)))")

(define (compiler-typecheck-op-ok-cmp-eq-source) : String
  "(define (main) : bool (and (< 1 2) (= 3 3)))")

(define (compiler-typecheck-op-ok-call-source) : String
  "(define (add [a : i64] [b : i64]) : i64 (+ a b))
(define (main) : i64 (add 2 3))")

(define (compiler-typecheck-operator-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      (compiler-typecheck-op-eq-mismatch-source)
      "typecheck: equality operands must match")
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-op-int-mismatch-source)
        "typecheck: integer operator expects matching integer operands")
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-op-cmp-mismatch-source)
          "typecheck: comparison expects matching ordered scalar operands")
        (and
          (compiler-typecheck-error-ok?
            (compiler-typecheck-op-arity-many-source)
            "typecheck: arity mismatch")
          (and
            (compiler-typecheck-error-ok?
              (compiler-typecheck-op-arity-few-source)
              "typecheck: arity mismatch")
            (and
              (compiler-typecheck-ok? (compiler-typecheck-op-ok-arith-source))
              (and
                (compiler-typecheck-ok?
                  (compiler-typecheck-op-ok-cmp-eq-source))
                (compiler-typecheck-ok? (compiler-typecheck-op-ok-call-source))))))))))

;; Match / pattern type rules (#1042): arm-type agreement and unknown-variant
;; rejection, plus accepting enum-payload, bool, and wildcard-on-scalar matches.
;; Migrated from src/typechecker.rs unit coverage.
(define (compiler-typecheck-match-arm-mismatch-source) : String
  "(defenum E (A) (B))
(define (main [e : E]) : i64 (match e [(A) 1] [(B) true]))")

(define (compiler-typecheck-match-unknown-variant-source) : String
  "(defenum E (A) (B))
(define (main [e : E]) : i64 (match e [(A) 1] [(C) 2]))")

(define (compiler-typecheck-match-ok-payload-source) : String
  "(defenum E (A i64) (B))
(define (main [e : E]) : i64 (match e [(A x) x] [(B) 0]))")

(define (compiler-typecheck-match-ok-bool-source) : String
  "(define (main [b : bool]) : i64 (match b [true 1] [false 0]))")

(define (compiler-typecheck-match-ok-wildcard-source) : String
  "(define (main) : i64 (match 1 [_ 0]))")

;; A diverging arm (panic : never) must unify with a value arm rather than
;; being reported as a disagreement; mirrors never-in-if branch handling.
(define (compiler-typecheck-match-ok-never-arm-source) : String
  "(defenum E (A) (B))
(define (main [e : E]) : i64 (match e [(A) 1] [(B) (panic \"no\")]))")

(define (compiler-typecheck-match-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      (compiler-typecheck-match-arm-mismatch-source)
      "typecheck: match arms must agree")
    (and
      (compiler-typecheck-error-ok?
        (compiler-typecheck-match-unknown-variant-source)
        "typecheck: unknown variant C")
      (and
        (compiler-typecheck-ok? (compiler-typecheck-match-ok-payload-source))
        (and
          (compiler-typecheck-ok? (compiler-typecheck-match-ok-bool-source))
          (and
            (compiler-typecheck-ok?
              (compiler-typecheck-match-ok-wildcard-source))
            (compiler-typecheck-ok?
              (compiler-typecheck-match-ok-never-arm-source))))))))

(define (compiler-typecheck-string-builtin-ok-length-source) : String
  "(define (main) : i64 (string-length \"hi\"))")

(define (compiler-typecheck-string-builtin-ok-append-source) : String
  "(define (f) : String (string-append \"a\" \"b\"))")

(define (compiler-typecheck-string-builtin-ok-substring-source) : String
  "(define (f) : String (substring \"abc\" 0 1))")

(define (compiler-typecheck-string-builtin-ok-eq-source) : String
  "(define (f) : bool (string-eq \"a\" \"b\"))")

(define (compiler-typecheck-string-builtin-bad-arg-source) : String
  "(define (main) : i64 (string-length 5))")

(define (compiler-typecheck-string-builtin-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-string-builtin-ok-length-source))
    (and
      (compiler-typecheck-ok?
        (compiler-typecheck-string-builtin-ok-append-source))
      (and
        (compiler-typecheck-ok?
          (compiler-typecheck-string-builtin-ok-substring-source))
        (and
          (compiler-typecheck-ok?
            (compiler-typecheck-string-builtin-ok-eq-source))
          (compiler-typecheck-error-ok?
            (compiler-typecheck-string-builtin-bad-arg-source)
            "typecheck: argument type mismatch"))))))

(define (compiler-typecheck-lambda-ok-typed-source) : String
  "(define (main) : i64 (let [f : (-> i64 i64) (lambda ([x : i64]) : i64 x)] (f 5)))")

(define (compiler-typecheck-lambda-ok-nullary-source) : String
  "(define (main) : i64 (let [g : (-> i64) (lambda () : i64 42)] (g)))")

(define (compiler-typecheck-lambda-ok-inferred-ret-source) : String
  "(define (main) : i64 (let [h : (-> i64 i64) (lambda ([x : i64]) (+ x 1))] (h 7)))")

(define (compiler-typecheck-lambda-bad-ret-source) : String
  "(define (main) : i64 (begin (lambda ([x : i64]) : bool x) 0))")

(define (compiler-typecheck-lambda-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-lambda-ok-typed-source))
    (and
      (compiler-typecheck-ok? (compiler-typecheck-lambda-ok-nullary-source))
      (and
        (compiler-typecheck-ok?
          (compiler-typecheck-lambda-ok-inferred-ret-source))
        (compiler-typecheck-error-ok?
          (compiler-typecheck-lambda-bad-ret-source)
          "typecheck: lambda return type mismatch")))))

(define (compiler-typecheck-cast-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? "(define (f [x : i32]) : i64 (cast x : i64))")
    (and
      (compiler-typecheck-ok? "(define (f [x : i64]) : u8 (cast x : u8))")
      (and
        (compiler-typecheck-ok? "(define (f [x : i64]) : char (cast x : char))")
        (and
          (compiler-typecheck-ok?
            "(define (f [c : char]) : i64 (cast c : i64))")
          (and
            (compiler-typecheck-error-ok?
              "(define (f [x : f64]) : i64 (cast x : i64))"
              "typecheck: cast requires integer/char source and target")
            (compiler-typecheck-error-ok?
              "(define (f [b : bool]) : i64 (cast b : i64))"
              "typecheck: cast requires integer/char source and target")))))))

;; spmd-reduce operator/type rules (#1011, SPEC 5.15): `sum` accepts i32/i64/f64,
;; `min`/`max` accept i32/i64, `all`/`any` accept bool. (The varying-value
;; purity/effect rules are a separate slice.)
(define (compiler-typecheck-spmd-reduce-op-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))")
    (and
      (compiler-typecheck-ok?
        "(define (main [bs : (Array bool)] [n : i64]) : bool (spmd-reduce all ([i : i64 0 n]) true (array-ref bs i)))")
      (and
        (compiler-typecheck-error-ok?
          "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce all ([i : i64 0 n]) 0 (array-ref xs i)))"
          "typecheck: spmd-reduce all requires a bool type")
        (compiler-typecheck-error-ok?
          "(define (main [bs : (Array bool)] [n : i64]) : bool (spmd-reduce sum ([i : i64 0 n]) true (array-ref bs i)))"
          "typecheck: spmd-reduce sum requires an i32, i64, or f64 type")))))

;; spmd-reduce purity rules (#1011, SPEC.md §5.16): the per-lane value
;; expression accepts pure arithmetic over dynamic-array reads and the varying
;; index, but rejects writes (`array-set!`), function calls (also covers
;; `print*`/`panic`/file I/O and varying-argument user calls), varying control
;; flow (`if`/`while`/`match`), and indirect/gather array indexing.
(define (compiler-typecheck-spmd-reduce-purity-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (+ (array-ref xs i) 1)))")
    (and
      (compiler-typecheck-error-ok?
        "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-set! xs i 1)))"
        "`array-set!` is not allowed inside a spmd-reduce value expression; the value expression must be free of writes and other side effects (SPEC.md §5.16)")
      (and
        (compiler-typecheck-error-ok?
          "(define (helper [x : i64]) : i64 x) (define (main [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (helper i)))"
          "function calls are not allowed inside a spmd-reduce value expression; side-effecting builtins and user calls with varying arguments are deferred in the first slice (SPEC.md §5.16)")
        (and
          (compiler-typecheck-error-ok?
            "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (if (< (array-ref xs i) 0) 0 1)))"
            "varying control flow is not allowed inside a spmd-reduce value expression; the first slice has no varying if/while/match (SPEC.md §5.16)")
          (compiler-typecheck-error-ok?
            "(define (main [xs : (Array i64)] [ys : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs (array-ref ys i))))"
            "indirect array indexing is not allowed inside a spmd-reduce value expression; gather/scatter is deferred in the first slice (SPEC.md §5.16)"))))))

;; array-builtin signature rules (#1042): make-array length, array-ref array/index
;; types, and array-set! value-type agreement, with valid accepts.
(define (compiler-typecheck-array-builtin-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (f [a : (Array i64)]) : i64 (begin (array-set! a 0 5) (array-ref a 0)))")
    (and
      (compiler-typecheck-ok?
        "(define (f) : i64 (let [a : (Array i64) (make-array i64 4)] (array-length a)))")
      (and
        (compiler-typecheck-error-ok?
          "(define (f [a : (Array i64)]) : i64 (array-ref a true))"
          "typecheck: array index must be integer")
        (and
          (compiler-typecheck-error-ok?
            "(define (f) : i64 (make-array i64 true))"
            "typecheck: make-array length must be integer")
          (compiler-typecheck-error-ok?
            "(define (f [a : (Array i64)]) : unit (array-set! a 0 true))"
            "typecheck: array-set! value type mismatch"))))))

;; comptime typecheck rules (#1042): a `(comptime ...)` form is typed by its
;; inner expression and flows that type to the use site (so an `i64` body is an
;; `i64`, a `bool` comparison is a `bool`, and a `let`/`if` body keeps its type);
;; `comptime` cannot reference a runtime variable, and a comptime result that
;; disagrees with the surrounding type is rejected like any other mismatch.
(define (compiler-typecheck-comptime-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? "(define (main) : i64 (comptime (+ 1 2)))")
    (and
      (compiler-typecheck-ok? "(define (main) : bool (comptime (< 1 2)))")
      (and
        (compiler-typecheck-ok?
          "(define (main) : i64 (comptime (let [a : i64 1] (if (< a 2) a 0))))")
        (and
          (compiler-typecheck-ok?
            "(define (main) : i64 (+ (comptime (* 6 7)) 0))")
          (and
            (compiler-typecheck-error-ok?
              "(define (f [x : i64]) : i64 (comptime x))"
              "compile-time evaluation cannot reference runtime variable 'x'")
            (compiler-typecheck-error-ok?
              "(define (main) : i64 (comptime (< 1 2)))"
              "typecheck: return type mismatch")))))))

;; IO-builtin signature rules (#1042): whole-file helpers and file-handle status
;; primitives accept, plus wrong-argument, wrong-arity, and result-type-mismatch
;; rejections. Migrated from src/typechecker.rs read-file/write-file coverage.
(define (compiler-typecheck-io-builtin-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? "(define (f [p : String]) : String (read-file p))")
    (and
      (compiler-typecheck-ok?
        "(define (f [p : String] [c : String]) : unit (write-file p c))")
      (and
        (compiler-typecheck-ok?
          "(define (f [p : String] [c : String]) : i64 (append-file-status p c))")
        (and
          (compiler-typecheck-ok?
            "(define (f [p : String]) : bool (file-exists? p))")
          (and
            (compiler-typecheck-ok?
              "(define (f [p : String]) : i64 (file-open-status p 0))")
            (and
              (compiler-typecheck-ok?
                "(define (f [h : i64]) : i64 (file-close-status h))")
              (and
                (compiler-typecheck-error-ok?
                  "(define (f [c : String]) : unit (write-file 5 c))"
                  "typecheck: argument type mismatch")
                (and
                  (compiler-typecheck-error-ok?
                    "(define (f [p : String]) : unit (write-file p))"
                    "typecheck: arity mismatch")
                  (and
                    (compiler-typecheck-error-ok?
                      "(define (f [p : i64]) : String (read-file p))"
                      "typecheck: argument type mismatch")
                    (and
                      (compiler-typecheck-error-ok?
                        "(define (f [p : String]) : i64 (file-open-status p \"r\"))"
                        "typecheck: argument type mismatch")
                      (and
                        (compiler-typecheck-error-ok?
                          "(define (f) : i64 (file-close-status \"h\"))"
                          "typecheck: argument type mismatch")
                        (compiler-typecheck-error-ok?
                          "(define (f [p : String] [c : String]) : i64 (write-file p c))"
                          "typecheck: return type mismatch")))))))))))))

;; Raw-pointer null construction / check (#1054).
(define (compiler-typecheck-ptr-null-ok-source) : String
  "(define (main) : i64 (if (ptr-null? (ptr-null : (Ptr i64))) 1 0))")

(define (compiler-typecheck-ptr-null-mut-source) : String
  "(define (main) : i64 (if (ptr-null? (ptr-null : (MutPtr i64))) 1 0))")

(define (compiler-typecheck-ptr-null-bad-type-source) : String
  "(define (main) : i64 (if (ptr-null? (ptr-null : i64)) 1 0))")

(define (compiler-typecheck-ptr-null-check-bad-source) : String
  "(define (main) : i64 (if (ptr-null? 5) 1 0))")

(define (compiler-typecheck-ptr-null-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-ptr-null-ok-source))
    (and
      (compiler-typecheck-ok? (compiler-typecheck-ptr-null-mut-source))
      (and
        (compiler-typecheck-error-ok?
          (compiler-typecheck-ptr-null-bad-type-source)
          "typecheck: ptr-null requires a pointer type, e.g. (ptr-null : (Ptr i64))")
        (compiler-typecheck-error-ok?
          (compiler-typecheck-ptr-null-check-bad-source)
          "typecheck: ptr-null? requires a raw pointer operand")))))

;; Unsafe blocks (#1053): parse + typecheck like `begin`; empty `(unsafe)`
;; rejects at parse.
(define (compiler-typecheck-unsafe-ok-source) : String
  "(define (main) : i64 (unsafe 1 2 42))")

(define (compiler-typecheck-unsafe-empty-source) : String
  "(define (main) : i64 (unsafe))")

(define (compiler-typecheck-unsafe-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-unsafe-ok-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-unsafe-empty-source)
      "parse: unsafe requires a non-empty body")))

;; `size-of`/`align-of` comptime layout queries (#989 slice 1): accepted with a
;; single type argument (result `i64`), rejected with wrong arity.
(define (compiler-typecheck-layout-query-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (f) : i64 (comptime (size-of (type i64))))")
    (and
      (compiler-typecheck-ok?
        "(define (f) : i64 (comptime (align-of (type bool))))")
      (compiler-typecheck-error-ok?
        "(define (f) : i64 (comptime (size-of (type i64) (type bool))))"
        "size-of expects exactly one type argument"))))

(define (compiler-typecheck-self-test) : i64
  (begin
    (if (compiler-typecheck-ptr-null-tests-ok?)
      unit
      (panic "typecheck: ptr-null construction/check tests failed"))
    (if (compiler-typecheck-unsafe-tests-ok?)
      unit
      (panic "typecheck: unsafe block tests failed"))
    (if (compiler-typecheck-statement-tests-ok?)
      unit
      (panic "typecheck: statement/control-flow tests failed"))
    (if (compiler-typecheck-operator-tests-ok?)
      unit
      (panic "typecheck: operator/arity tests failed"))
    (if (compiler-typecheck-match-tests-ok?)
      unit
      (panic "typecheck: match/pattern tests failed"))
    (if (compiler-typecheck-spmd-reduce-op-tests-ok?)
      unit
      (panic "typecheck: spmd-reduce operator/type tests failed"))
    (if (compiler-typecheck-spmd-reduce-purity-tests-ok?)
      unit
      (panic "typecheck: spmd-reduce purity tests failed"))
    (if (compiler-typecheck-array-builtin-tests-ok?)
      unit
      (panic "typecheck: array-builtin signature tests failed"))
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
                    (compiler-typecheck-foreach-spmd-tests-ok?)
                    (and
                      (compiler-typecheck-nominal-tests-ok?)
                      (and
                        (compiler-typecheck-abstraction-policy-tests-ok?)
                        (and
                          (compiler-typecheck-region-tests-ok?)
                          (and
                            (compiler-typecheck-result-try-tests-ok?)
                            (and
                              (compiler-typecheck-raw-pointer-tests-ok?)
                              (and
                                (compiler-typecheck-reference-tests-ok?)
                                (and
                                  (compiler-typecheck-located-ok?)
                                  (and
                                    (compiler-typecheck-string-builtin-tests-ok?)
                                    (and
                                      (compiler-typecheck-lambda-tests-ok?)
                                      (and
                                        (compiler-typecheck-cast-tests-ok?)
                                        (and
                                          (compiler-typecheck-comptime-tests-ok?)
                                          (and
                                            (compiler-typecheck-io-builtin-tests-ok?)
                                            (compiler-typecheck-layout-query-tests-ok?)))))))))))))))))))
          42
          (begin
            (panic "typecheck: smoke score mismatch")
            0))]
      [(ErrCompilerTypecheck diag)
        (begin
          (panic (compiler-diagnostic-message diag))
          0)])))