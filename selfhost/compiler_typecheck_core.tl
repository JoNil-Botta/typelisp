;; compiler_typecheck_core.tl - Specialization-free scalar typechecker core (#1436).
(import "../stdlib/io.tl")

(import "../stdlib/arena.tl")

(import "compiler_symbols.tl")

(import "compiler_diagnostic.tl")

(import "compiler_ctfe.tl")

(import "compiler_clone.tl")

(defenum TcTypeEnv
  (TcTypeNil)
  (TcTypeBind String AstType (Box TcTypeEnv))
  (TcTypeCache
    StringI64Map
    (Array AstType)
    (Array i64)
    StringI64Map
    (Box TcTypeEnv)))

(defenum TcContext
  (TcContext AstProgram CompilerSymbols CompilerRegistries String))

(defenum ResultTcType
  (OkTcType AstType)
  (ErrTcType String))

(defenum ResultTcTypeUnsafe
  (OkTcTypeUnsafe AstType bool)
  (ErrTcTypeUnsafe String))

(defenum ResultTcTypeList
  (OkTcTypeList AstTypeList)
  (ErrTcTypeList String))

(defenum TcBorrowPlace
  (TcBorrowPlace String AstType))

(defenum ResultTcBorrowPlace
  (OkTcBorrowPlace TcBorrowPlace)
  (ErrTcBorrowPlace String))

(defenum ResultTcString
  (OkTcString String)
  (ErrTcString String))

(defenum TcTryKind
  (TcTryResult)
  (TcTryOption))

(defenum TcTypeNameLookupCache
  (TcTypeNameLookupCacheMiss)
  (TcTypeNameLookupCacheFound i64)
  (TcTypeNameLookupCacheMissing))

(defenum TcResultInfo
  (TcResultInfo TcTryKind String String AstType String AstType))

(defenum ResultTcResultInfo
  (OkTcResultInfo TcResultInfo)
  (ErrTcResultInfo String))

(defenum TcMaybeString
  (TcNoString)
  (TcSomeString String))

(defenum TcStringList
  (TcStringNil)
  (TcStringCons String (Box TcStringList)))

(defenum ResultTcLifetimeList
  (OkTcLifetimeList AstLifetimeList)
  (ErrTcLifetimeList String))

(defenum TcLifetimeSubst
  (TcLifetimeSubstNil)
  (TcLifetimeSubstCons String String (Box TcLifetimeSubst)))

(defenum ResultTcLifetimeSubst
  (OkTcLifetimeSubst TcLifetimeSubst)
  (ErrTcLifetimeSubst String))

(defenum TcMaybeTypeEnv
  (TcNoTypeEnv)
  (TcSomeTypeEnv TcTypeEnv))

(defenum TcModuleLocalEnvCache
  (TcModuleLocalEnvNil)
  (TcModuleLocalEnvCons String TcTypeEnv (Box TcModuleLocalEnvCache)))

(defenum ResultTcModuleLocalEnv
  (OkTcModuleLocalEnv TcTypeEnv TcModuleLocalEnvCache)
  (ErrTcModuleLocalEnv String))

(defenum ResultTcEnv
  (OkTcEnv TcTypeEnv)
  (ErrTcEnv String))

(defenum ResultTcUnit
  (OkTcUnit)
  (ErrTcUnit String))

(defenum TcMoveKind
  (TcCopyable)
  (TcMoveOnly))

(defenum TcSpmdClass
  (TcSpmdUniform)
  (TcSpmdVarying))

(defenum TcSpmdScope
  (TcSpmdOuter)
  (TcSpmdLocal))

(defenum TcSpmdEnv
  (TcSpmdEnvNil)
  (TcSpmdEnvBind String AstType TcSpmdClass TcSpmdScope (Box TcSpmdEnv)))

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
  (TcStructDecl AstStructRepr AstStructCleanup AstFieldDefList))

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
  (TcReprCFieldLayoutCons TcReprCFieldLayout (Box TcReprCFieldLayoutList)))

(defenum TcReprCLayout
  (TcReprCLayout i64 i64 TcReprCFieldLayoutList))

(defenum ResultTcReprCLayout
  (OkTcReprCLayout TcReprCLayout)
  (ErrTcReprCLayout String))

(defenum TcInlineFieldLayout
  (TcInlineFieldLayout String AstType i64))

(defenum TcInlineFieldLayoutList
  (TcInlineFieldLayoutNil)
  (TcInlineFieldLayoutCons TcInlineFieldLayout (Box TcInlineFieldLayoutList)))

(defenum TcInlinePayloadLayout
  (TcInlinePayloadLayout i64 AstType i64))

(defenum TcInlinePayloadLayoutList
  (TcInlinePayloadLayoutNil)
  (TcInlinePayloadLayoutCons
    TcInlinePayloadLayout
    (Box TcInlinePayloadLayoutList)))

(defenum TcInlineVariantLayout
  (TcInlineVariantLayout String i64 i64 TcInlinePayloadLayoutList))

(defenum TcInlineVariantLayoutList
  (TcInlineVariantLayoutNil)
  (TcInlineVariantLayoutCons
    TcInlineVariantLayout
    (Box TcInlineVariantLayoutList)))

(defenum TcInlineFieldsLayout
  (TcInlineFieldsLayout i64 i64 TcInlineFieldLayoutList))

(defenum ResultTcInlineFieldsLayout
  (OkTcInlineFieldsLayout TcInlineFieldsLayout)
  (ErrTcInlineFieldsLayout String))

(defenum TcInlinePayloadFieldsLayout
  (TcInlinePayloadFieldsLayout i64 i64 TcInlinePayloadLayoutList))

(defenum ResultTcInlinePayloadFieldsLayout
  (OkTcInlinePayloadFieldsLayout TcInlinePayloadFieldsLayout)
  (ErrTcInlinePayloadFieldsLayout String))

(defenum TcInlineAggregateLayout
  (TcInlineStructLayout i64 i64 TcInlineFieldLayoutList)
  (TcInlineEnumLayout i64 i64 TcInlineVariantLayoutList))

(defenum ResultTcInlineAggregateLayout
  (OkTcInlineAggregateLayout TcInlineAggregateLayout)
  (ErrTcInlineAggregateLayout String))

(defenum CompilerTypecheckSummary
  (CompilerTypecheckSummary i64 i64 i64))

(defenum ResultCompilerTypecheck
  (OkCompilerTypecheck CompilerTypecheckSummary)
  (ErrCompilerTypecheck CompilerDiagnostic))

(defenum ResultCompilerTypecheckChecked
  (OkCompilerTypecheckChecked CompilerTypecheckSummary TcContext TcTypeEnv)
  (ErrCompilerTypecheckChecked CompilerDiagnostic))

(define (tc-context-with-module [ctx : TcContext] [module : String]) : TcContext
  (match ctx
    [(TcContext program symbols registries _)
      (TcContext program symbols registries module)]))

(define (tc-context-module [ctx : TcContext]) : String
  (match ctx
    [(TcContext _ _ _ module) module]))

;; The typechecker receives an already-loaded program and so does not know the
;; source path; it builds diagnostics with an empty path (the CLI driver stamps
;; the real path before rendering). Synthetic/internal errors fall back to 1:1.
(define (tc-diag-at-start [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start "" message))

(cfg
  compile-profile
  (define compiler-tc-profile-start-ms : i64
    0))

(cfg
  compile-profile
  (define compiler-tc-profile-start-total : i64
    0))

(cfg
  compile-profile
  (define compiler-tc-profile-start-live : i64
    0))

(cfg
  compile-profile
  (define (compiler-tc-profile-field [value : i64]) : String
    (string-append "|" (int->string value))))

(cfg
  compile-profile
  (define (compiler-tc-profile-start) : unit
    (begin
      (set! compiler-tc-profile-start-ms (profile-now-ms))
      (set! compiler-tc-profile-start-total (profile-alloc-total))
      (set! compiler-tc-profile-start-live (profile-alloc-live))
      (profile-alloc-reset-peak))))

(cfg
  compile-profile
  (define (compiler-tc-profile-finish [phase : String]) : unit
    (let
      [end-ms : i64 (profile-now-ms)]
      [end-total : i64 (profile-alloc-total)]
      [end-live : i64 (profile-alloc-live)]
      [peak-delta : i64 (- (profile-alloc-peak) compiler-tc-profile-start-live)]
      (print-error
        (string-append
          "compile-profile|typecheck."
          (string-append
            phase
            (string-append
              (compiler-tc-profile-field
                (- end-ms compiler-tc-profile-start-ms))
              (string-append
                (compiler-tc-profile-field
                  (- end-total compiler-tc-profile-start-total))
                (string-append
                  (compiler-tc-profile-field
                    (- end-live compiler-tc-profile-start-live))
                  (string-append (compiler-tc-profile-field peak-delta) "\n"))))))))))

(cfg
  compile-profile
  (define compiler-tc-decl-profile-start-ms : i64
    0))

(cfg
  compile-profile
  (define compiler-tc-decl-profile-local-env-ms : i64
    0))

(cfg
  compile-profile
  (define compiler-tc-decl-profile-arena-ms : i64
    0))

(cfg
  compile-profile
  (define compiler-tc-decl-profile-def-expr-ms : i64
    0))

(cfg
  compile-profile
  (define compiler-tc-decl-profile-fn-expr-ms : i64
    0))

(cfg
  compile-profile
  (define compiler-tc-decl-profile-fn-move-ms : i64
    0))

(cfg
  compile-profile
  (define compiler-tc-decl-profile-macro-ms : i64
    0))

(cfg
  compile-profile
  (define compiler-tc-decl-profile-extern-ms : i64
    0))

(cfg
  compile-profile
  (define compiler-tc-decl-profile-decl-count : i64
    0))

(cfg
  compile-profile
  (define compiler-tc-decl-profile-def-count : i64
    0))

(cfg
  compile-profile
  (define compiler-tc-decl-profile-fn-count : i64
    0))

(cfg
  compile-profile
  (define compiler-tc-decl-profile-macro-count : i64
    0))

(cfg
  compile-profile
  (define compiler-tc-decl-profile-extern-count : i64
    0))

(cfg
  compile-profile
  (define compiler-tc-decl-profile-other-count : i64
    0))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-reset) : unit
    (begin
      (set! compiler-tc-decl-profile-start-ms 0)
      (set! compiler-tc-decl-profile-local-env-ms 0)
      (set! compiler-tc-decl-profile-arena-ms 0)
      (set! compiler-tc-decl-profile-def-expr-ms 0)
      (set! compiler-tc-decl-profile-fn-expr-ms 0)
      (set! compiler-tc-decl-profile-fn-move-ms 0)
      (set! compiler-tc-decl-profile-macro-ms 0)
      (set! compiler-tc-decl-profile-extern-ms 0)
      (set! compiler-tc-decl-profile-decl-count 0)
      (set! compiler-tc-decl-profile-def-count 0)
      (set! compiler-tc-decl-profile-fn-count 0)
      (set! compiler-tc-decl-profile-macro-count 0)
      (set! compiler-tc-decl-profile-extern-count 0)
      (set! compiler-tc-decl-profile-other-count 0))))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-start-section) : unit
    (set! compiler-tc-decl-profile-start-ms (profile-now-ms))))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-add-local-env) : unit
    (set!
      compiler-tc-decl-profile-local-env-ms
      (+
        compiler-tc-decl-profile-local-env-ms
        (- (profile-now-ms) compiler-tc-decl-profile-start-ms)))))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-add-arena) : unit
    (set!
      compiler-tc-decl-profile-arena-ms
      (+
        compiler-tc-decl-profile-arena-ms
        (- (profile-now-ms) compiler-tc-decl-profile-start-ms)))))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-add-def-expr) : unit
    (set!
      compiler-tc-decl-profile-def-expr-ms
      (+
        compiler-tc-decl-profile-def-expr-ms
        (- (profile-now-ms) compiler-tc-decl-profile-start-ms)))))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-add-fn-expr) : unit
    (set!
      compiler-tc-decl-profile-fn-expr-ms
      (+
        compiler-tc-decl-profile-fn-expr-ms
        (- (profile-now-ms) compiler-tc-decl-profile-start-ms)))))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-add-fn-expr-named [name : String]) : unit
    (let
      [elapsed : i64 (- (profile-now-ms) compiler-tc-decl-profile-start-ms)]
      (begin
        (set!
          compiler-tc-decl-profile-fn-expr-ms
          (+ compiler-tc-decl-profile-fn-expr-ms elapsed))
        (if (>= elapsed 1)
          (print-error
            (string-append
              "compile-profile-detail|typecheck.fn_expr|"
              (string-append
                (int->string elapsed)
                (string-append "|" (string-append name "\n")))))
          unit)))))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-add-fn-move) : unit
    (set!
      compiler-tc-decl-profile-fn-move-ms
      (+
        compiler-tc-decl-profile-fn-move-ms
        (- (profile-now-ms) compiler-tc-decl-profile-start-ms)))))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-add-macro) : unit
    (set!
      compiler-tc-decl-profile-macro-ms
      (+
        compiler-tc-decl-profile-macro-ms
        (- (profile-now-ms) compiler-tc-decl-profile-start-ms)))))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-add-extern) : unit
    (set!
      compiler-tc-decl-profile-extern-ms
      (+
        compiler-tc-decl-profile-extern-ms
        (- (profile-now-ms) compiler-tc-decl-profile-start-ms)))))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-count-def) : unit
    (begin
      (set!
        compiler-tc-decl-profile-decl-count
        (+ compiler-tc-decl-profile-decl-count 1))
      (set!
        compiler-tc-decl-profile-def-count
        (+ compiler-tc-decl-profile-def-count 1)))))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-count-fn) : unit
    (begin
      (set!
        compiler-tc-decl-profile-decl-count
        (+ compiler-tc-decl-profile-decl-count 1))
      (set!
        compiler-tc-decl-profile-fn-count
        (+ compiler-tc-decl-profile-fn-count 1)))))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-count-macro) : unit
    (begin
      (set!
        compiler-tc-decl-profile-decl-count
        (+ compiler-tc-decl-profile-decl-count 1))
      (set!
        compiler-tc-decl-profile-macro-count
        (+ compiler-tc-decl-profile-macro-count 1)))))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-count-extern) : unit
    (begin
      (set!
        compiler-tc-decl-profile-decl-count
        (+ compiler-tc-decl-profile-decl-count 1))
      (set!
        compiler-tc-decl-profile-extern-count
        (+ compiler-tc-decl-profile-extern-count 1)))))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-count-other) : unit
    (begin
      (set!
        compiler-tc-decl-profile-decl-count
        (+ compiler-tc-decl-profile-decl-count 1))
      (set!
        compiler-tc-decl-profile-other-count
        (+ compiler-tc-decl-profile-other-count 1)))))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-record [decl : AstDecl]) : unit
    (match decl
      [(AstDeclDef _ _ _)
        (begin
          (compiler-tc-decl-profile-count-def)
          (compiler-tc-decl-profile-add-def-expr))]
      [(AstDeclDefFn name _ _ _)
        (begin
          (compiler-tc-decl-profile-count-fn)
          (compiler-tc-decl-profile-add-fn-expr-named name))]
      [(AstDeclDefMacro _ _ _ _)
        (begin
          (compiler-tc-decl-profile-count-macro)
          (compiler-tc-decl-profile-add-macro))]
      [(AstDeclExtern _ _ _)
        (begin
          (compiler-tc-decl-profile-count-extern)
          (compiler-tc-decl-profile-add-extern))]
      [_
        (begin
          (compiler-tc-decl-profile-count-other)
          (compiler-tc-decl-profile-add-arena))])))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-line [phase : String] [value : i64]) : unit
    (print-error
      (string-append
        "compile-profile|typecheck.decl."
        (string-append
          phase
          (string-append (compiler-tc-profile-field value) "|0|0|0\n"))))))

(cfg
  compile-profile
  (define (compiler-tc-decl-profile-finish) : unit
    (begin
      (compiler-tc-decl-profile-line
        "local_env"
        compiler-tc-decl-profile-local-env-ms)
      (compiler-tc-decl-profile-line "arena" compiler-tc-decl-profile-arena-ms)
      (compiler-tc-decl-profile-line
        "def_expr"
        compiler-tc-decl-profile-def-expr-ms)
      (compiler-tc-decl-profile-line
        "fn_expr"
        compiler-tc-decl-profile-fn-expr-ms)
      (compiler-tc-decl-profile-line
        "fn_move"
        compiler-tc-decl-profile-fn-move-ms)
      (compiler-tc-decl-profile-line "macro" compiler-tc-decl-profile-macro-ms)
      (compiler-tc-decl-profile-line
        "extern"
        compiler-tc-decl-profile-extern-ms)
      (compiler-tc-decl-profile-line
        "decl_count"
        compiler-tc-decl-profile-decl-count)
      (compiler-tc-decl-profile-line
        "def_count"
        compiler-tc-decl-profile-def-count)
      (compiler-tc-decl-profile-line
        "fn_count"
        compiler-tc-decl-profile-fn-count)
      (compiler-tc-decl-profile-line
        "macro_count"
        compiler-tc-decl-profile-macro-count)
      (compiler-tc-decl-profile-line
        "extern_count"
        compiler-tc-decl-profile-extern-count)
      (compiler-tc-decl-profile-line
        "other_count"
        compiler-tc-decl-profile-other-count))))

(define (tc-expr-diag [expr : AstExpr] [message : String]) : CompilerDiagnostic
  (match expr
    [(AstExprSpanned _ span)
      (compiler-diagnostic-from-ast-span "" span message)]
    [_ (tc-diag-at-start message)]))

;; Locate an error at the nearest available declaration body span. A top-level
;; `define` body is wrapped in `AstExprSpanned`, so its span points the
;; diagnostic at the offending declaration's expression; otherwise fall back 1:1.
(define (tc-generated-decl-diag
  [meta : AstGeneratedDeclMeta]
  [diag : CompilerDiagnostic]) : CompilerDiagnostic
  (match meta
    [(AstSomeGeneratedDeclMeta generator item _ key)
      (let
        [with-context : CompilerDiagnostic
          (compiler-diagnostic-with-note
            diag
            (string-append
              "generated declaration: "
              (string-append item (string-append " from " generator))))]
        (if (> (string-length key) 0)
          (compiler-diagnostic-with-note
            with-context
            (string-append "generated identity: " key))
          with-context))]
    [(AstNoGeneratedDeclMeta) diag]))

(define (tc-decl-diag [decl : AstDecl] [message : String]) : CompilerDiagnostic
  (match decl
    [(AstDeclDef _ _ expr-box)
      (let
        [expr : AstExpr (box-get expr-box)]
        (tc-expr-diag expr message))]
    [(AstDeclDefFn _ _ _ body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (tc-expr-diag body message))]
    [(AstDeclDefMacro _ _ _ body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (tc-expr-diag body message))]
    [(AstDeclTest _ _ span) (compiler-diagnostic-from-ast-span "" span message)]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tc-decl-diag inner message))]
    [(AstDeclComptimeDecl meta template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (tc-generated-decl-diag meta (tc-decl-diag template message)))]
    [_ (tc-diag-at-start message)]))

(define (tc-empty-env) : TcTypeEnv
  TcTypeNil)

(define (tc-bind [env : TcTypeEnv] [name : String] [ty : AstType]) : TcTypeEnv
  (TcTypeBind name ty (box env)))

(define (tc-unsafe-decl-marker-name [name : String]) : String
  (string-append " __tl_unsafe_decl:" name))

(define (tc-bind-unsafe [env : TcTypeEnv] [name : String] [ty : AstType]) : TcTypeEnv
  (tc-bind (tc-bind env (tc-unsafe-decl-marker-name name) (AstTyUnit)) name ty))

(define (tc-binding-unsafe-marker-head? [env : TcTypeEnv] [name : String]) : bool
  (match env
    [(TcTypeBind key _ _) (string-eq key (tc-unsafe-decl-marker-name name))]
    [_ false]))

(define (tc-binding-unsafe? [env : TcTypeEnv] [name : String]) : bool
  (match env
    [(TcTypeNil) false]
    [(TcTypeCache ids _ unsafe-flags _ rest)
      (match (string-i64-map-get ids name)
        [(StringI64MapFound index) (= (array-ref unsafe-flags index) 1)]
        [(StringI64MapMissing) false])]
    [(TcTypeBind key _ rest)
      (if (string-eq key name)
        (tc-binding-unsafe-marker-head? (box-get rest) name)
        (tc-binding-unsafe? (box-get rest) name))]))

(define (tc-env-cache-count [env : TcTypeEnv]) : i64
  (match env
    [(TcTypeNil) 0]
    [(TcTypeBind _ _ rest) (+ 1 (tc-env-cache-count (box-get rest)))]
    [(TcTypeCache _ _ _ _ rest) (tc-env-cache-count (box-get rest))]))

(define (tc-env-cache-capacity [count : i64]) : i64
  (if (< count 4)
    8
    (* count 2)))

(define (tc-env-cache-add
  [ids : StringI64Map]
  [values : (Array AstType)]
  [unsafe-flags : (Array i64)]
  [name : String]
  [ty : AstType]
  [unsafe : bool]) : StringI64Map
  (match (string-i64-map-get ids name)
    [(StringI64MapFound _) ids]
    [(StringI64MapMissing)
      (let
        [next : i64 (string-i64-map-len ids)]
        (begin
          (array-set! values next ty)
          (array-set!
            unsafe-flags
            next
            (if unsafe
              1
              0))
          (string-i64-map-put ids name next)))]))

(define (tc-env-cache-fill
  [env : TcTypeEnv]
  [ids : StringI64Map]
  [values : (Array AstType)]
  [unsafe-flags : (Array i64)]) : StringI64Map
  (match env
    [(TcTypeNil) ids]
    [(TcTypeBind name ty rest)
      (tc-env-cache-fill
        (box-get rest)
        (tc-env-cache-add
          ids
          values
          unsafe-flags
          name
          ty
          (tc-binding-unsafe-marker-head? (box-get rest) name))
        values
        unsafe-flags)]
    [(TcTypeCache _ _ _ _ rest)
      (tc-env-cache-fill (box-get rest) ids values unsafe-flags)]))

(define (tc-env-default-shadow-count [env : TcTypeEnv]) : i64
  (match env
    [(TcTypeNil) 0]
    [(TcTypeBind name _ rest)
      (if (string-eq name (tc-default-boundary-name))
        0
        (+ 1 (tc-env-default-shadow-count (box-get rest))))]
    [(TcTypeCache _ _ _ _ rest) (tc-env-default-shadow-count (box-get rest))]))

(define (tc-env-default-shadow-fill [env : TcTypeEnv] [shadows : StringI64Map]) : StringI64Map
  (match env
    [(TcTypeNil) shadows]
    [(TcTypeBind name _ rest)
      (if (string-eq name (tc-default-boundary-name))
        shadows
        (tc-env-default-shadow-fill
          (box-get rest)
          (string-i64-map-put shadows name 1)))]
    [(TcTypeCache _ _ _ _ rest)
      (tc-env-default-shadow-fill (box-get rest) shadows)]))

(define (tc-env-with-cache [env : TcTypeEnv]) : TcTypeEnv
  (let
    [count : i64 (tc-env-cache-count env)]
    [shadow-count : i64 (tc-env-default-shadow-count env)]
    [values : (Array AstType) (make-array AstType count)]
    [unsafe-flags : (Array i64) (make-array i64 count)]
    [ids : StringI64Map
      (tc-env-cache-fill
        env
        (string-i64-map-with-capacity (tc-env-cache-capacity count))
        values
        unsafe-flags)]
    [shadows : StringI64Map
      (tc-env-default-shadow-fill
        env
        (string-i64-map-with-capacity (tc-env-cache-capacity shadow-count)))]
    (TcTypeCache ids values unsafe-flags shadows (box env))))

(define (tc-bind-alias-if-free [env : TcTypeEnv] [name : String] [ty : AstType]) : TcTypeEnv
  (if (tc-name-bound? env name)
    env
    (tc-bind env name ty)))

(define (tc-bind-module-name
  [env : TcTypeEnv]
  [module : String]
  [name : String]
  [ty : AstType]) : TcTypeEnv
  (if (string-eq module "")
    (tc-bind env name ty)
    (tc-bind env (compiler-symbol-module-key module name) ty)))

(define (tc-bind-module-name-unsafe
  [env : TcTypeEnv]
  [module : String]
  [name : String]
  [ty : AstType]) : TcTypeEnv
  (if (string-eq module "")
    (tc-bind-unsafe env name ty)
    (tc-bind-unsafe env (compiler-symbol-module-key module name) ty)))

(define (tc-default-boundary-name) : String
  "__tl_default_boundary")

(define (tc-region-marker-name) : String
  "__tl_active_region")

(define (tc-cleanup-owner-marker-name) : String
  " __tl_cleanup_owner")

(define (tc-return-type-name) : String
  "__tl_return_type")

(define (tc-hygiene-global-boundary-name) : String
  "__tl_hygiene_global_boundary")

(define (tc-hygiene-template-prefix) : String
  "__tl_macro_template$")

(define (tc-hygiene-global-prefix) : String
  "__tl_macro_global$")

(define (tc-hygiene-local-prefix) : String
  "__tl_macro_local$")

(define (tc-hygiene-string-prefix? [text : String] [prefix : String]) : bool
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
    (if (< text-len prefix-len)
      false
      (if (= (string-ref text 0) (string-ref prefix 0))
        (string-eq (substring text 0 prefix-len) prefix)
        false))))

(define (tc-hygiene-name-base [name : String] [prefix : String]) : String
  (substring
    name
    (string-length prefix)
    (- (string-length name) (string-length prefix))))

(define (tc-hygiene-template-name? [name : String]) : bool
  (tc-hygiene-string-prefix? name (tc-hygiene-template-prefix)))

(define (tc-hygiene-template-base [name : String]) : String
  (tc-hygiene-name-base name (tc-hygiene-template-prefix)))

(define (tc-hygiene-global-name? [name : String]) : bool
  (tc-hygiene-string-prefix? name (tc-hygiene-global-prefix)))

(define (tc-hygiene-global-base [name : String]) : String
  (tc-hygiene-name-base name (tc-hygiene-global-prefix)))

(define (tc-hygiene-global-name [name : String]) : String
  (string-append (tc-hygiene-global-prefix) name))

(define (tc-hygiene-global-env [top-env : TcTypeEnv]) : TcTypeEnv
  (tc-bind top-env (tc-hygiene-global-boundary-name) (AstTyUnit)))

(define (tc-unsafe-marker-name) : String
  " __tl_unsafe_context")

(define (tc-enter-unsafe [env : TcTypeEnv]) : TcTypeEnv
  (tc-bind env (tc-unsafe-marker-name) (AstTyUnit)))

(define (tc-in-unsafe? [env : TcTypeEnv]) : bool
  (match env
    [(TcTypeNil) false]
    [(TcTypeCache _ _ _ _ _) false]
    [(TcTypeBind key _ rest)
      (if (string-eq key (tc-unsafe-marker-name))
        true
        (tc-in-unsafe? (box-get rest)))]))

(define (tc-bind-return-type [env : TcTypeEnv] [ty : AstType]) : TcTypeEnv
  (tc-bind env (tc-return-type-name) ty))

(define (tc-current-return-type [env : TcTypeEnv]) : ResultTcType
  (match env
    [(TcTypeNil)
      (ErrTcType "typecheck: try requires enclosing Result-like function")]
    [(TcTypeCache _ _ _ _ _)
      (ErrTcType "typecheck: try requires enclosing Result-like function")]
    [(TcTypeBind key ty rest)
      (if (string-eq key (tc-return-type-name))
        (OkTcType ty)
        (tc-current-return-type (box-get rest)))]))

(define (tc-type-list1 [a : AstType]) : AstTypeList
  (ast-type-cons a AstTypeNil))

(define (tc-type-list2 [a : AstType] [b : AstType]) : AstTypeList
  (ast-type-cons a (ast-type-cons b AstTypeNil)))

(define (tc-type-list3 [a : AstType] [b : AstType] [c : AstType]) : AstTypeList
  (ast-type-cons a (ast-type-cons b (ast-type-cons c AstTypeNil))))

(define (tc-fn0 [ret : AstType]) : AstType
  (ast-ty-func AstTypeNil ret))

(define (tc-fn1 [a : AstType] [ret : AstType]) : AstType
  (ast-ty-func (tc-type-list1 a) ret))

(define (tc-fn2 [a : AstType] [b : AstType] [ret : AstType]) : AstType
  (ast-ty-func (tc-type-list2 a b) ret))

(define (tc-fn3 [a : AstType] [b : AstType] [c : AstType] [ret : AstType]) : AstType
  (ast-ty-func (tc-type-list3 a b c) ret))

(define (tc-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (tc-type-list-render [types : AstTypeList]) : String
  (match types
    [(AstTypeNil) ""]
    [(AstTypeCons head rest)
      (let
        [head : AstType (box-get head)]
        [rest : AstTypeList (box-get rest)]
        (string-append
          (tc-type-render head)
          (match rest
            [(AstTypeNil) ""]
            [_ (string-append " " (tc-type-list-render rest))])))]))

(define (tc-lifetime-list-render [lifetimes : AstLifetimeList]) : String
  (match lifetimes
    [(AstLifetimeNil) ""]
    [(AstLifetimeCons head rest)
      (let
        [rest : AstLifetimeList (box-get rest)]
        (string-append
          head
          (match rest
            [(AstLifetimeNil) ""]
            [_ (string-append " " (tc-lifetime-list-render rest))])))]))

(define (tc-render-nominal-lifetime-type
  [name : String]
  [lifetimes : AstLifetimeList]) : String
  (tc-cat3
    "("
    name
    (string-append " " (string-append (tc-lifetime-list-render lifetimes) ")"))))

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
    [(AstTyStr) "str"]
    [(AstTyUnit) "unit"]
    [(AstTyNever) "never"]
    [(AstTyExpr) "Expr"]
    [(AstTyExprList) "ExprList"]
    [(AstTyFunc args ret)
      (tc-cat3
        "(-> "
        (tc-type-list-render args)
        (string-append " " (string-append (tc-type-render (box-get ret)) ")")))]
    [(AstTyTuple elems) (tc-cat3 "(Tuple " (tc-type-list-render elems) ")")]
    [(AstTyArray elem count)
      (tc-cat3
        "(Array "
        (tc-type-render (box-get elem))
        (tc-cat3 " " (int->string count) ")"))]
    [(AstTyDynArray elem)
      (tc-cat3 "(Array " (tc-type-render (box-get elem)) ")")]
    [(AstTyBox elem) (tc-cat3 "(Box " (tc-type-render (box-get elem)) ")")]
    [(AstTyPtr elem) (tc-cat3 "(Ptr " (tc-type-render (box-get elem)) ")")]
    [(AstTyMutPtr elem)
      (tc-cat3 "(MutPtr " (tc-type-render (box-get elem)) ")")]
    [(AstTyRef region inner)
      (tc-cat3
        "(& "
        region
        (string-append " " (string-append (tc-type-render (box-get inner)) ")")))]
    [(AstTyMutRef region inner)
      (tc-cat3
        "(&mut "
        region
        (string-append " " (string-append (tc-type-render (box-get inner)) ")")))]
    [(AstTyRegion region inner)
      (tc-cat3
        "(Region "
        region
        (string-append " " (string-append (tc-type-render (box-get inner)) ")")))]
    [(AstTyEnum name) name]
    [(AstTyEnumArgs name lifetimes)
      (tc-render-nominal-lifetime-type name lifetimes)]
    [(AstTyStruct name) name]
    [(AstTyStructArgs name lifetimes)
      (tc-render-nominal-lifetime-type name lifetimes)]
    [(AstTyVar name) name]
    [(AstTyVarArgs name lifetimes)
      (tc-render-nominal-lifetime-type name lifetimes)]))

(define (tc-default-env) : TcTypeEnv
  (tc-bind (tc-default-env-base) (tc-default-boundary-name) (AstTyUnit)))

(define (tc-default-env-base) : TcTypeEnv
  (let
    [e0 : TcTypeEnv (tc-empty-env)]
    [e1 : TcTypeEnv
      (tc-bind e0 "string-length" (tc-fn1 (AstTyString) (AstTyI64)))]
    [e2 : TcTypeEnv (tc-bind e1 "length" (tc-fn1 (AstTyString) (AstTyI64)))]
    [e3 : TcTypeEnv
      (tc-bind e2 "string-eq" (tc-fn2 (AstTyString) (AstTyString) (AstTyBool)))]
    [e4 : TcTypeEnv
      (tc-bind e3 "string=?" (tc-fn2 (AstTyString) (AstTyString) (AstTyBool)))]
    [e5 : TcTypeEnv
      (tc-bind e4 "string->int" (tc-fn1 (AstTyString) (AstTyI64)))]
    [e6 : TcTypeEnv
      (tc-bind e5 "int->string" (tc-fn1 (AstTyI64) (AstTyString)))]
    [e7 : TcTypeEnv
      (tc-bind
        (tc-bind
          e6
          "cpuid"
          (tc-fn2
            (AstTyI64)
            (AstTyI64)
            (AstTyTuple
              (ast-type-cons
                (AstTyI32)
                (ast-type-cons
                  (AstTyI32)
                  (ast-type-cons
                    (AstTyI32)
                    (ast-type-cons (AstTyI32) (AstTypeNil))))))))
        "xgetbv"
        (tc-fn1 (AstTyI64) (AstTyI64)))]
    [e8 : TcTypeEnv
      (tc-bind
        e7
        "substring"
        (tc-fn3 (AstTyString) (AstTyI64) (AstTyI64) (AstTyString)))]
    [e9 : TcTypeEnv
      (tc-bind
        e8
        "string-slice"
        (tc-fn3 (AstTyString) (AstTyI64) (AstTyI64) (AstTyString)))]
    [e10 : TcTypeEnv
      (tc-bind
        e9
        "string-append"
        (tc-fn2 (AstTyString) (AstTyString) (AstTyString)))]
    [e11 : TcTypeEnv
      (tc-bind
        e10
        "string-concat"
        (tc-fn2 (AstTyString) (AstTyString) (AstTyString)))]
    (tc-bind e11 (tc-default-boundary-name) (AstTyUnit))))

(define (tc-macro-helper-env [env : TcTypeEnv]) : TcTypeEnv
  (let
    [expr : AstType (AstTyExpr)]
    [out : TcTypeEnv env]
    (begin
      (set! out (tc-bind out "expr-bool" (tc-fn1 (AstTyBool) expr)))
      (set! out (tc-bind out "expr-splice" (tc-fn1 expr expr)))
      (set! out (tc-bind out "expr-if" (tc-fn3 expr expr expr expr)))
      (set! out (tc-bind out "expr-bool?" (tc-fn1 expr (AstTyBool))))
      (set! out (tc-bind out "expr-bool-value" (tc-fn1 expr (AstTyBool))))
      (set! out (tc-bind out "expr-if?" (tc-fn1 expr (AstTyBool))))
      (set! out (tc-bind out "expr-if-cond" (tc-fn1 expr expr)))
      (set! out (tc-bind out "expr-if-then" (tc-fn1 expr expr)))
      (set! out (tc-bind out "expr-if-else" (tc-fn1 expr expr)))
      (set!
        out
        (tc-bind out "expr-list-empty?" (tc-fn1 (AstTyExprList) (AstTyBool))))
      (set! out (tc-bind out "expr-list-head" (tc-fn1 (AstTyExprList) expr)))
      (set!
        out
        (tc-bind out "expr-list-tail" (tc-fn1 (AstTyExprList) (AstTyExprList))))
      out)))

(define (tc-lookup [env : TcTypeEnv] [name : String]) : ResultTcType
  (match env
    [(TcTypeNil) (ErrTcType (string-append "typecheck: unbound name " name))]
    [(TcTypeCache ids values _ _ rest)
      (match (string-i64-map-get ids name)
        [(StringI64MapFound index) (OkTcType (array-ref values index))]
        [(StringI64MapMissing)
          (ErrTcType (string-append "typecheck: unbound name " name))])]
    [(TcTypeBind key ty rest)
      (if (string-eq key name)
        (OkTcType ty)
        (tc-lookup (box-get rest) name))]))

(define (tc-lookup-unsafe [env : TcTypeEnv] [name : String]) : ResultTcTypeUnsafe
  (match env
    [(TcTypeNil)
      (ErrTcTypeUnsafe (string-append "typecheck: unbound name " name))]
    [(TcTypeCache ids values unsafe-flags _ rest)
      (match (string-i64-map-get ids name)
        [(StringI64MapFound index)
          (OkTcTypeUnsafe
            (array-ref values index)
            (= (array-ref unsafe-flags index) 1))]
        [(StringI64MapMissing)
          (ErrTcTypeUnsafe (string-append "typecheck: unbound name " name))])]
    [(TcTypeBind key ty rest)
      (if (string-eq key name)
        (OkTcTypeUnsafe ty (tc-binding-unsafe-marker-head? (box-get rest) name))
        (tc-lookup-unsafe (box-get rest) name))]))

(define (tc-lookup-visible [ctx : TcContext] [env : TcTypeEnv] [name : String]) : ResultTcType
  (match (tc-lookup env name)
    [(OkTcType ty)
      (match (tc-qualified-value-visible-ok ctx name)
        [(OkTcUnit) (OkTcType ty)]
        [(ErrTcUnit message) (ErrTcType message)])]
    [(ErrTcType message) (ErrTcType message)]))

(define (tc-lookup-hygiene-global-scan
  [root : TcTypeEnv]
  [env : TcTypeEnv]
  [name : String]) : ResultTcType
  (match env
    [(TcTypeNil) (tc-lookup root name)]
    [(TcTypeCache _ _ _ _ rest)
      (tc-lookup-hygiene-global-scan root (box-get rest) name)]
    [(TcTypeBind key _ rest)
      (if (string-eq key (tc-hygiene-global-boundary-name))
        (tc-lookup (box-get rest) name)
        (tc-lookup-hygiene-global-scan root (box-get rest) name))]))

(define (tc-lookup-hygiene-global [env : TcTypeEnv] [name : String]) : ResultTcType
  (tc-lookup-hygiene-global-scan env env name))

(define (tc-lookup-hygiene-global-visible
  [ctx : TcContext]
  [env : TcTypeEnv]
  [name : String]) : ResultTcType
  (match (tc-lookup-hygiene-global env name)
    [(OkTcType ty)
      (match (tc-qualified-value-visible-ok ctx name)
        [(OkTcUnit) (OkTcType ty)]
        [(ErrTcUnit message) (ErrTcType message)])]
    [(ErrTcType message) (ErrTcType message)]))

(define (tc-hygiene-global-binding-unsafe-scan
  [root : TcTypeEnv]
  [env : TcTypeEnv]
  [name : String]) : bool
  (match env
    [(TcTypeNil) (tc-binding-unsafe? root name)]
    [(TcTypeCache _ _ _ _ rest)
      (tc-hygiene-global-binding-unsafe-scan root (box-get rest) name)]
    [(TcTypeBind key _ rest)
      (if (string-eq key (tc-hygiene-global-boundary-name))
        (tc-binding-unsafe? (box-get rest) name)
        (tc-hygiene-global-binding-unsafe-scan root (box-get rest) name))]))

(define (tc-hygiene-global-binding-unsafe? [env : TcTypeEnv] [name : String]) : bool
  (tc-hygiene-global-binding-unsafe-scan env env name))

(define (tc-active-region [env : TcTypeEnv]) : TcMaybeString
  (match env
    [(TcTypeNil) (TcNoString)]
    [(TcTypeCache _ _ _ _ _) (TcNoString)]
    [(TcTypeBind key ty rest)
      (if (string-eq key (tc-region-marker-name))
        (match ty
          [(AstTyVar region) (TcSomeString region)]
          [_ (tc-active-region (box-get rest))])
        (tc-active-region (box-get rest)))]))

(define (tc-push-region [env : TcTypeEnv] [region : String]) : TcTypeEnv
  (tc-bind env (tc-region-marker-name) (AstTyVar region)))

(define (tc-string-list-contains [items : TcStringList] [name : String]) : bool
  (match items
    [(TcStringNil) false]
    [(TcStringCons item rest)
      (if (string-eq item name)
        true
        (tc-string-list-contains (box-get rest) name))]))

(define (tc-string-list-add [items : TcStringList] [name : String]) : TcStringList
  (if (tc-string-list-contains items name)
    items
    (TcStringCons name (box items))))

(define (tc-bind-cleanup-owner [env : TcTypeEnv] [name : String]) : TcTypeEnv
  (tc-bind env (tc-cleanup-owner-marker-name) (AstTyVar name)))

(define (tc-cleanup-owner-marker-for?
  [key : String]
  [ty : AstType]
  [name : String]) : bool
  (if (string-eq key (tc-cleanup-owner-marker-name))
    (match ty
      [(AstTyVar owner) (string-eq owner name)]
      [_ false])
    false))

(define (tc-cleanup-owner-marker-entry? [key : String] [ty : AstType]) : bool
  (if (string-eq key (tc-cleanup-owner-marker-name))
    (match ty
      [(AstTyVar _) true]
      [_ false])
    false))

(define (tc-cleanup-owner-marker-head? [env : TcTypeEnv] [name : String]) : bool
  (match env
    [(TcTypeNil) false]
    [(TcTypeCache _ _ _ _ _) false]
    [(TcTypeBind key ty _) (tc-cleanup-owner-marker-for? key ty name)]))

(define (tc-cleanup-owner-active? [env : TcTypeEnv] [name : String]) : bool
  (match env
    [(TcTypeNil) false]
    [(TcTypeCache _ _ _ _ _) false]
    [(TcTypeBind key ty rest)
      (if (string-eq key name)
        (tc-cleanup-owner-marker-head? (box-get rest) name)
        (tc-cleanup-owner-active? (box-get rest) name))]))

(define (tc-active-cleanup-owners-scan [root : TcTypeEnv] [env : TcTypeEnv]) : TcStringList
  (match env
    [(TcTypeNil) TcStringNil]
    [(TcTypeCache _ _ _ _ _) TcStringNil]
    [(TcTypeBind key ty rest)
      (let
        [owners : TcStringList
          (tc-active-cleanup-owners-scan root (box-get rest))]
        (if (string-eq key (tc-cleanup-owner-marker-name))
          (match ty
            [(AstTyVar owner)
              (if (tc-cleanup-owner-active? root owner)
                (tc-string-list-add owners owner)
                owners)]
            [_ owners])
          owners))]))

(define (tc-active-cleanup-owners [env : TcTypeEnv]) : TcStringList
  (tc-active-cleanup-owners-scan env env))

(define (tc-string-list-eq [a : TcStringList] [b : TcStringList]) : bool
  (match a
    [(TcStringNil)
      (match b
        [(TcStringNil) true]
        [_ false])]
    [(TcStringCons item rest)
      (and
        (tc-string-list-contains b item)
        (tc-string-list-eq (box-get rest) b))]))

(define (tc-string-list-overlaps? [a : TcStringList] [b : TcStringList]) : bool
  (match a
    [(TcStringNil) false]
    [(TcStringCons item rest)
      (if (tc-string-list-contains b item)
        true
        (tc-string-list-overlaps? (box-get rest) b))]))

(define (tc-string-list-all-in? [items : TcStringList] [allowed : TcStringList]) : bool
  (match items
    [(TcStringNil) true]
    [(TcStringCons item rest)
      (and
        (tc-string-list-contains allowed item)
        (tc-string-list-all-in? (box-get rest) allowed))]))

(define (tc-lifetime-list-count [items : AstLifetimeList]) : i64
  (match items
    [(AstLifetimeNil) 0]
    [(AstLifetimeCons _ rest)
      (let
        [rest : AstLifetimeList (box-get rest)]
        (+ 1 (tc-lifetime-list-count rest)))]))

(define (tc-lifetime-list-contains [items : AstLifetimeList] [name : String]) : bool
  (match items
    [(AstLifetimeNil) false]
    [(AstLifetimeCons item rest)
      (let
        [rest : AstLifetimeList (box-get rest)]
        (if (string-eq item name)
          true
          (tc-lifetime-list-contains rest name)))]))

(define (tc-lifetime-list-duplicates? [items : AstLifetimeList]) : bool
  (match items
    [(AstLifetimeNil) false]
    [(AstLifetimeCons item rest)
      (let
        [rest : AstLifetimeList (box-get rest)]
        (or
          (tc-lifetime-list-contains rest item)
          (tc-lifetime-list-duplicates? rest)))]))

(define (tc-lifetime-list-eq [a : AstLifetimeList] [b : AstLifetimeList]) : bool
  (match a
    [(AstLifetimeNil)
      (match b
        [(AstLifetimeNil) true]
        [_ false])]
    [(AstLifetimeCons a-head a-rest)
      (let
        [a-rest : AstLifetimeList (box-get a-rest)]
        (match b
          [(AstLifetimeCons b-head b-rest)
            (let
              [b-rest : AstLifetimeList (box-get b-rest)]
              (and
                (string-eq a-head b-head)
                (tc-lifetime-list-eq a-rest b-rest)))]
          [_ false]))]))

(define (tc-lifetime-list-all-in?
  [items : AstLifetimeList]
  [allowed : AstLifetimeList]) : bool
  (match items
    [(AstLifetimeNil) true]
    [(AstLifetimeCons item rest)
      (let
        [rest : AstLifetimeList (box-get rest)]
        (and
          (or
            (string-eq item "program")
            (tc-lifetime-list-contains allowed item))
          (tc-lifetime-list-all-in? rest allowed)))]))

(define (tc-lifetime-list-to-string-list-into
  [items : AstLifetimeList]
  [out : TcStringList]) : TcStringList
  (match items
    [(AstLifetimeNil) out]
    [(AstLifetimeCons item rest)
      (let
        [rest : AstLifetimeList (box-get rest)]
        (tc-lifetime-list-to-string-list-into
          rest
          (tc-string-list-add out item)))]))

(define (tc-string-list-to-lifetime-list [items : TcStringList]) : AstLifetimeList
  (match items
    [(TcStringNil) AstLifetimeNil]
    [(TcStringCons item rest)
      (ast-lifetime-cons item (tc-string-list-to-lifetime-list (box-get rest)))]))

(define (tc-lifetime-subst-lookup [subst : TcLifetimeSubst] [name : String]) : TcMaybeString
  (match subst
    [(TcLifetimeSubstNil) (TcNoString)]
    [(TcLifetimeSubstCons from to rest)
      (if (string-eq from name)
        (TcSomeString to)
        (tc-lifetime-subst-lookup (box-get rest) name))]))

(define (tc-lifetime-subst-bind
  [subst : TcLifetimeSubst]
  [from : String]
  [to : String]) : ResultTcLifetimeSubst
  (match (tc-lifetime-subst-lookup subst from)
    [(TcSomeString existing)
      (if (string-eq existing to)
        (OkTcLifetimeSubst subst)
        (ErrTcLifetimeSubst "typecheck: constructor lifetime mismatch"))]
    [(TcNoString) (OkTcLifetimeSubst (TcLifetimeSubstCons from to (box subst)))]))

(define (tc-lifetime-subst-apply [subst : TcLifetimeSubst] [name : String]) : String
  (match (tc-lifetime-subst-lookup subst name)
    [(TcSomeString replacement) replacement]
    [(TcNoString) name]))

(define (tc-lifetime-subst-list
  [subst : TcLifetimeSubst]
  [items : AstLifetimeList]) : AstLifetimeList
  (match items
    [(AstLifetimeNil) AstLifetimeNil]
    [(AstLifetimeCons item rest)
      (let
        [rest : AstLifetimeList (box-get rest)]
        (ast-lifetime-cons
          (tc-lifetime-subst-apply subst item)
          (tc-lifetime-subst-list subst rest)))]))

;; V1 lifetime names are owner names. Normal environment bindings own stack
;; slots, and the synthetic region marker owns a with-arena scope. Environment
;; order is the lexical outlives relation: older owners appear farther down the
;; list and outlive nested stack bindings or scoped arenas. The default program
;; arena is inferred for untagged aggregate handles, so it has no lexical
;; binder in this environment walk.
(define (tc-env-binding-matches-lifetime?
  [key : String]
  [ty : AstType]
  [lifetime : String]) : bool
  (if (string-eq key lifetime)
    true
    (if (string-eq key (tc-region-marker-name))
      (match ty
        [(AstTyVar region) (string-eq region lifetime)]
        [_ false])
      false)))

(define (tc-lifetime-visible? [env : TcTypeEnv] [lifetime : String]) : bool
  (match env
    [(TcTypeNil) false]
    [(TcTypeCache _ _ _ _ _) false]
    [(TcTypeBind key ty rest)
      (if (tc-env-binding-matches-lifetime? key ty lifetime)
        true
        (tc-lifetime-visible? (box-get rest) lifetime))]))

(define (tc-reference-lifetimes-visible?
  [env : TcTypeEnv]
  [lifetimes : TcStringList]) : bool
  (match lifetimes
    [(TcStringNil) true]
    [(TcStringCons lifetime rest)
      (and
        (tc-lifetime-visible? env lifetime)
        (tc-reference-lifetimes-visible? env (box-get rest)))]))

(define (tc-lifetime-outlives-binding-scan
  [env : TcTypeEnv]
  [lifetime : String]
  [target : String]
  [seen-target : bool]) : bool
  (match env
    [(TcTypeNil) false]
    [(TcTypeCache _ _ _ _ _) false]
    [(TcTypeBind key ty rest)
      (if (tc-env-binding-matches-lifetime? key ty lifetime)
        seen-target
        (tc-lifetime-outlives-binding-scan
          (box-get rest)
          lifetime
          target
          (or seen-target (string-eq key target))))]))

(define (tc-lifetime-outlives-binding?
  [env : TcTypeEnv]
  [lifetime : String]
  [target : String]) : bool
  (tc-lifetime-outlives-binding-scan env lifetime target false))

(define (tc-reference-lifetimes-outlive-binding?
  [env : TcTypeEnv]
  [lifetimes : TcStringList]
  [target : String]) : bool
  (match lifetimes
    [(TcStringNil) true]
    [(TcStringCons lifetime rest)
      (and
        (tc-lifetime-outlives-binding? env lifetime target)
        (tc-reference-lifetimes-outlive-binding? env (box-get rest) target))]))

(define (tc-lifetime-outlives-lifetime-scan
  [env : TcTypeEnv]
  [value-lifetime : String]
  [target-lifetime : String]
  [seen-target : bool]) : bool
  (if (string-eq value-lifetime target-lifetime)
    true
    (match env
      [(TcTypeNil) false]
      [(TcTypeCache _ _ _ _ _) false]
      [(TcTypeBind key ty rest)
        (if (tc-env-binding-matches-lifetime? key ty value-lifetime)
          seen-target
          (tc-lifetime-outlives-lifetime-scan
            (box-get rest)
            value-lifetime
            target-lifetime
            (or
              seen-target
              (tc-env-binding-matches-lifetime? key ty target-lifetime))))])))

(define (tc-lifetime-outlives-lifetime?
  [env : TcTypeEnv]
  [value-lifetime : String]
  [target-lifetime : String]) : bool
  (tc-lifetime-outlives-lifetime-scan env value-lifetime target-lifetime false))

(define (tc-reference-lifetimes-outlive-lifetime?
  [env : TcTypeEnv]
  [lifetimes : TcStringList]
  [target-lifetime : String]) : bool
  (match lifetimes
    [(TcStringNil) true]
    [(TcStringCons lifetime rest)
      (and
        (tc-lifetime-outlives-lifetime? env lifetime target-lifetime)
        (tc-reference-lifetimes-outlive-lifetime?
          env
          (box-get rest)
          target-lifetime))]))

(define (tc-ensure-reference-value-can-bind
  [env : TcTypeEnv]
  [value-ty : AstType]) : ResultTcUnit
  (let
    [lifetimes : TcStringList (tc-type-collect-regions value-ty)]
    (if (tc-reference-lifetimes-visible? env lifetimes)
      OkTcUnit
      (ErrTcUnit "typecheck: reference value would escape lexical scope"))))

(define (tc-ensure-reference-value-can-assign
  [env : TcTypeEnv]
  [target : String]
  [value-ty : AstType]) : ResultTcUnit
  (let
    [lifetimes : TcStringList (tc-type-collect-reference-lifetimes value-ty)]
    (if (tc-reference-lifetimes-outlive-binding? env lifetimes target)
      OkTcUnit
      (ErrTcUnit
        "typecheck: cannot store reference into longer-lived binding; reference value would escape lexical scope"))))

(define (tc-ensure-reference-type-does-not-escape-names
  [ty : AstType]
  [names : TcStringList]) : ResultTcUnit
  (if (tc-string-list-overlaps? (tc-type-collect-regions ty) names)
    (ErrTcUnit "typecheck: reference value would escape lexical scope")
    OkTcUnit))

(define (tc-type-strip-region [ty : AstType]) : AstType
  (match ty
    [(AstTyRegion _ inner) (tc-type-strip-region (box-get inner))]
    [_ ty]))

(define (tc-type-list-contains-region-tag? [types : AstTypeList]) : bool
  (match types
    [(AstTypeNil) false]
    [(AstTypeCons head tail)
      (let
        [head : AstType (box-get head)]
        [tail : AstTypeList (box-get tail)]
        (if (tc-type-contains-region-tag? head)
          true
          (tc-type-list-contains-region-tag? tail)))]))

(define (tc-type-contains-region-tag? [ty : AstType]) : bool
  (match ty
    [(AstTyFunc args ret)
      (if (tc-type-list-contains-region-tag? args)
        true
        (tc-type-contains-region-tag? (box-get ret)))]
    [(AstTyTuple elems) (tc-type-list-contains-region-tag? elems)]
    [(AstTyArray elem _) (tc-type-contains-region-tag? (box-get elem))]
    [(AstTyDynArray elem) (tc-type-contains-region-tag? (box-get elem))]
    [(AstTyBox elem) (tc-type-contains-region-tag? (box-get elem))]
    [(AstTyPtr elem) (tc-type-contains-region-tag? (box-get elem))]
    [(AstTyMutPtr elem) (tc-type-contains-region-tag? (box-get elem))]
    [(AstTyRef _ inner) (tc-type-contains-region-tag? (box-get inner))]
    [(AstTyMutRef _ inner) (tc-type-contains-region-tag? (box-get inner))]
    [(AstTyRegion _ _) true]
    [_ false]))

(define (tc-type-list-without-regions [types : AstTypeList]) : AstTypeList
  (if (tc-type-list-contains-region-tag? types)
    (match types
      [(AstTypeNil) AstTypeNil]
      [(AstTypeCons head tail)
        (let
          [head : AstType (box-get head)]
          [tail : AstTypeList (box-get tail)]
          (ast-type-cons
            (tc-type-without-regions head)
            (tc-type-list-without-regions tail)))])
    types))

(define (tc-type-without-regions [ty : AstType]) : AstType
  (if (tc-type-contains-region-tag? ty)
    (match ty
      [(AstTyFunc args ret)
        (ast-ty-func
          (tc-type-list-without-regions args)
          (tc-type-without-regions (box-get ret)))]
      [(AstTyTuple elems) (AstTyTuple (tc-type-list-without-regions elems))]
      [(AstTyArray elem len)
        (ast-ty-array (tc-type-without-regions (box-get elem)) len)]
      [(AstTyDynArray elem)
        (ast-ty-dyn-array (tc-type-without-regions (box-get elem)))]
      [(AstTyBox elem) (ast-ty-box (tc-type-without-regions (box-get elem)))]
      [(AstTyPtr elem) (ast-ty-ptr (tc-type-without-regions (box-get elem)))]
      [(AstTyMutPtr elem)
        (ast-ty-mut-ptr (tc-type-without-regions (box-get elem)))]
      [(AstTyRef region inner)
        (ast-ty-ref region (tc-type-without-regions (box-get inner)))]
      [(AstTyMutRef region inner)
        (ast-ty-mut-ref region (tc-type-without-regions (box-get inner)))]
      [(AstTyRegion _ inner) (tc-type-without-regions (box-get inner))]
      [(AstTyEnumArgs name lifetimes) (AstTyEnumArgs name lifetimes)]
      [(AstTyStructArgs name lifetimes) (AstTyStructArgs name lifetimes)]
      [(AstTyVarArgs name lifetimes) (AstTyVarArgs name lifetimes)]
      [_ ty])
    ty))

(define (tc-type-list-contains-region [types : AstTypeList] [region : String]) : bool
  (match types
    [(AstTypeNil) false]
    [(AstTypeCons head tail)
      (let
        [head : AstType (box-get head)]
        [tail : AstTypeList (box-get tail)]
        (or
          (tc-type-contains-region head region)
          (tc-type-list-contains-region tail region)))]))

(define (tc-type-contains-region [ty : AstType] [region : String]) : bool
  (match ty
    [(AstTyFunc args ret)
      (or
        (tc-type-list-contains-region args region)
        (tc-type-contains-region (box-get ret) region))]
    [(AstTyTuple elems) (tc-type-list-contains-region elems region)]
    [(AstTyArray elem _) (tc-type-contains-region (box-get elem) region)]
    [(AstTyDynArray elem) (tc-type-contains-region (box-get elem) region)]
    [(AstTyBox elem) (tc-type-contains-region (box-get elem) region)]
    [(AstTyPtr elem) (tc-type-contains-region (box-get elem) region)]
    [(AstTyMutPtr elem) (tc-type-contains-region (box-get elem) region)]
    [(AstTyRef name inner)
      (or
        (string-eq name region)
        (tc-type-contains-region (box-get inner) region))]
    [(AstTyMutRef name inner)
      (or
        (string-eq name region)
        (tc-type-contains-region (box-get inner) region))]
    [(AstTyRegion name inner)
      (or
        (string-eq name region)
        (tc-type-contains-region (box-get inner) region))]
    [(AstTyEnumArgs _ lifetimes) (tc-lifetime-list-contains lifetimes region)]
    [(AstTyStructArgs _ lifetimes) (tc-lifetime-list-contains lifetimes region)]
    [(AstTyVarArgs _ lifetimes) (tc-lifetime-list-contains lifetimes region)]
    [_ false]))

(define (tc-type-list-contains-any-region [types : AstTypeList]) : bool
  (match types
    [(AstTypeNil) false]
    [(AstTypeCons head tail)
      (let
        [head : AstType (box-get head)]
        [tail : AstTypeList (box-get tail)]
        (or
          (tc-type-contains-any-region head)
          (tc-type-list-contains-any-region tail)))]))

(define (tc-type-contains-any-region [ty : AstType]) : bool
  (match ty
    [(AstTyFunc args ret)
      (or
        (tc-type-list-contains-any-region args)
        (tc-type-contains-any-region (box-get ret)))]
    [(AstTyTuple elems) (tc-type-list-contains-any-region elems)]
    [(AstTyArray elem _) (tc-type-contains-any-region (box-get elem))]
    [(AstTyDynArray elem) (tc-type-contains-any-region (box-get elem))]
    [(AstTyBox elem) (tc-type-contains-any-region (box-get elem))]
    [(AstTyPtr elem) (tc-type-contains-any-region (box-get elem))]
    [(AstTyMutPtr elem) (tc-type-contains-any-region (box-get elem))]
    [(AstTyRef _ _) true]
    [(AstTyMutRef _ _) true]
    [(AstTyRegion _ _) true]
    [(AstTyEnumArgs _ lifetimes) (> (tc-lifetime-list-count lifetimes) 0)]
    [(AstTyStructArgs _ lifetimes) (> (tc-lifetime-list-count lifetimes) 0)]
    [(AstTyVarArgs _ lifetimes) (> (tc-lifetime-list-count lifetimes) 0)]
    [_ false]))

(define (tc-type-list-contains-reference? [types : AstTypeList]) : bool
  (match types
    [(AstTypeNil) false]
    [(AstTypeCons head tail)
      (let
        [head : AstType (box-get head)]
        [tail : AstTypeList (box-get tail)]
        (or
          (tc-type-contains-reference? head)
          (tc-type-list-contains-reference? tail)))]))

(define (tc-type-contains-reference? [ty : AstType]) : bool
  (match ty
    [(AstTyFunc args ret)
      (or
        (tc-type-list-contains-reference? args)
        (tc-type-contains-reference? (box-get ret)))]
    [(AstTyTuple elems) (tc-type-list-contains-reference? elems)]
    [(AstTyArray elem _) (tc-type-contains-reference? (box-get elem))]
    [(AstTyDynArray elem) (tc-type-contains-reference? (box-get elem))]
    [(AstTyBox elem) (tc-type-contains-reference? (box-get elem))]
    [(AstTyPtr elem) (tc-type-contains-reference? (box-get elem))]
    [(AstTyMutPtr elem) (tc-type-contains-reference? (box-get elem))]
    [(AstTyRef _ _) true]
    [(AstTyMutRef _ _) true]
    [(AstTyRegion _ inner) (tc-type-contains-reference? (box-get inner))]
    [(AstTyEnumArgs _ lifetimes) (> (tc-lifetime-list-count lifetimes) 0)]
    [(AstTyStructArgs _ lifetimes) (> (tc-lifetime-list-count lifetimes) 0)]
    [(AstTyVarArgs _ lifetimes) (> (tc-lifetime-list-count lifetimes) 0)]
    [_ false]))

(define (tc-type-list-collect-reference-lifetimes
  [types : AstTypeList]
  [out : TcStringList]) : TcStringList
  (match types
    [(AstTypeNil) out]
    [(AstTypeCons head tail)
      (let
        [head : AstType (box-get head)]
        [tail : AstTypeList (box-get tail)]
        (tc-type-list-collect-reference-lifetimes
          tail
          (tc-type-collect-reference-lifetimes-into head out)))]))

(define (tc-type-collect-reference-lifetimes-into
  [ty : AstType]
  [out : TcStringList]) : TcStringList
  (match ty
    [(AstTyFunc args ret)
      (tc-type-collect-reference-lifetimes-into
        (box-get ret)
        (tc-type-list-collect-reference-lifetimes args out))]
    [(AstTyTuple elems) (tc-type-list-collect-reference-lifetimes elems out)]
    [(AstTyArray elem _)
      (tc-type-collect-reference-lifetimes-into (box-get elem) out)]
    [(AstTyDynArray elem)
      (tc-type-collect-reference-lifetimes-into (box-get elem) out)]
    [(AstTyBox elem)
      (tc-type-collect-reference-lifetimes-into (box-get elem) out)]
    [(AstTyPtr elem)
      (tc-type-collect-reference-lifetimes-into (box-get elem) out)]
    [(AstTyMutPtr elem)
      (tc-type-collect-reference-lifetimes-into (box-get elem) out)]
    [(AstTyRef lifetime inner)
      (tc-type-collect-reference-lifetimes-into
        (box-get inner)
        (tc-string-list-add out lifetime))]
    [(AstTyMutRef lifetime inner)
      (tc-type-collect-reference-lifetimes-into
        (box-get inner)
        (tc-string-list-add out lifetime))]
    [(AstTyRegion _ inner)
      (tc-type-collect-reference-lifetimes-into (box-get inner) out)]
    [(AstTyEnumArgs _ lifetimes)
      (tc-lifetime-list-to-string-list-into lifetimes out)]
    [(AstTyStructArgs _ lifetimes)
      (tc-lifetime-list-to-string-list-into lifetimes out)]
    [(AstTyVarArgs _ lifetimes)
      (tc-lifetime-list-to-string-list-into lifetimes out)]
    [_ out]))

(define (tc-type-collect-reference-lifetimes [ty : AstType]) : TcStringList
  (tc-type-collect-reference-lifetimes-into ty TcStringNil))

(define (tc-maybe-type-contains-reference? [maybe-ty : AstMaybeType]) : bool
  (match maybe-ty
    [(AstNoType) false]
    [(AstSomeType ty) (tc-type-contains-reference? ty)]))

(define (tc-param-list-contains-reference? [params : AstParamList]) : bool
  (match params
    [(AstParamNil) false]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam _ ty _)
            (or
              (tc-type-contains-reference? ty)
              (tc-param-list-contains-reference? rest))]))]))

(define (tc-param-list-reference-return-lifetimes-into
  [ctx : TcContext]
  [params : AstParamList]
  [out : TcStringList]) : TcStringList
  (match params
    [(AstParamNil) out]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam name ty _)
            (tc-param-list-reference-return-lifetimes-into
              ctx
              rest
              (tc-type-collect-reference-lifetimes-into
                (tc-resolve-type ctx ty)
                (tc-string-list-add out name)))]))]))

(define (tc-reference-return-lifetimes-allowed?
  [ctx : TcContext]
  [params : AstParamList]
  [ret : AstType]) : bool
  (tc-string-list-all-in?
    (tc-type-collect-reference-lifetimes (tc-resolve-type ctx ret))
    (tc-param-list-reference-return-lifetimes-into ctx params TcStringNil)))

(define (tc-reference-return-policy-ok
  [ctx : TcContext]
  [params : AstParamList]
  [ret : AstType]) : ResultTcUnit
  (if (tc-type-contains-reference? (tc-resolve-type ctx ret))
    (if (tc-reference-return-lifetimes-allowed? ctx params ret)
      OkTcUnit
      (ErrTcUnit
        "typecheck: returned reference lifetime must be tied to a parameter"))
    OkTcUnit))

(define (tc-type-list-collect-regions
  [types : AstTypeList]
  [out : TcStringList]) : TcStringList
  (match types
    [(AstTypeNil) out]
    [(AstTypeCons head tail)
      (let
        [head : AstType (box-get head)]
        [tail : AstTypeList (box-get tail)]
        (tc-type-list-collect-regions
          tail
          (tc-type-collect-regions-into head out)))]))

(define (tc-type-collect-regions-into [ty : AstType] [out : TcStringList]) : TcStringList
  (match ty
    [(AstTyFunc args ret)
      (tc-type-collect-regions-into
        (box-get ret)
        (tc-type-list-collect-regions args out))]
    [(AstTyTuple elems) (tc-type-list-collect-regions elems out)]
    [(AstTyArray elem _) (tc-type-collect-regions-into (box-get elem) out)]
    [(AstTyDynArray elem) (tc-type-collect-regions-into (box-get elem) out)]
    [(AstTyBox elem) (tc-type-collect-regions-into (box-get elem) out)]
    [(AstTyPtr elem) (tc-type-collect-regions-into (box-get elem) out)]
    [(AstTyMutPtr elem) (tc-type-collect-regions-into (box-get elem) out)]
    [(AstTyRef name inner)
      (tc-type-collect-regions-into
        (box-get inner)
        (tc-string-list-add out name))]
    [(AstTyMutRef name inner)
      (tc-type-collect-regions-into
        (box-get inner)
        (tc-string-list-add out name))]
    [(AstTyRegion name inner)
      (tc-type-collect-regions-into
        (box-get inner)
        (tc-string-list-add out name))]
    [(AstTyEnumArgs _ lifetimes)
      (tc-lifetime-list-to-string-list-into lifetimes out)]
    [(AstTyStructArgs _ lifetimes)
      (tc-lifetime-list-to-string-list-into lifetimes out)]
    [(AstTyVarArgs _ lifetimes)
      (tc-lifetime-list-to-string-list-into lifetimes out)]
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
    [(AstTyBox _) true]
    [(AstTyTuple _) true]
    [(AstTyStruct _) true]
    [(AstTyStructArgs _ _) true]
    [(AstTyEnum _) true]
    [(AstTyEnumArgs _ _) true]
    [_ false]))

(define (tc-tag-region [region : String] [ty : AstType]) : AstType
  (if (tc-region-taggable-type? ty)
    (ast-ty-region region ty)
    ty))

(define (tc-tag-active-region [env : TcTypeEnv] [ty : AstType]) : AstType
  (match (tc-active-region env)
    [(TcSomeString region) (tc-tag-region region ty)]
    [(TcNoString) ty]))

;; Nominal aggregate types have no lifetime-argument surface yet. Until they do,
;; constructor results carry stored-reference lifetimes as local region facts so
;; existing flow/escape checks can reject boundary escapes.
(define (tc-tag-reference-lifetimes [lifetimes : TcStringList] [ty : AstType]) : AstType
  (match lifetimes
    [(TcStringNil) ty]
    [(TcStringCons lifetime rest)
      (tc-tag-region lifetime (tc-tag-reference-lifetimes (box-get rest) ty))]))

(define (tc-constructor-target-type
  [env : TcTypeEnv]
  [params : AstTypeList]
  [ret : AstType]) : AstType
  (tc-tag-active-region
    env
    (tc-tag-reference-lifetimes
      (tc-type-list-collect-reference-lifetimes params TcStringNil)
      ret)))

(define (tc-project-from-region-container
  [container-ty : AstType]
  [projected-ty : AstType]) : AstType
  (match (tc-type-outer-region container-ty)
    [(TcSomeString region) (tc-tag-region region projected-ty)]
    [(TcNoString) projected-ty]))

;; Region-tagged aggregate flow uses the same lexical owner ordering as
;; references, but only considers arena owners. A value from an outer region can
;; flow into an inner target; an inner-region value cannot flow outward.
(define (tc-region-outlives-or-matches
  [env : TcTypeEnv]
  [value-region : String]
  [target-region : String]) : bool
  (if (string-eq value-region target-region)
    true
    (match env
      [(TcTypeNil) false]
      [(TcTypeCache _ _ _ _ _) false]
      [(TcTypeBind key ty rest)
        (if (string-eq key (tc-region-marker-name))
          (match ty
            [(AstTyVar region)
              (if (string-eq region value-region)
                false
                (if (string-eq region target-region)
                  true
                  (tc-region-outlives-or-matches
                    (box-get rest)
                    value-region
                    target-region)))]
            [_
              (tc-region-outlives-or-matches
                (box-get rest)
                value-region
                target-region)])
          (tc-region-outlives-or-matches
            (box-get rest)
            value-region
            target-region))])))

(define (tc-region-can-flow-into-any
  [env : TcTypeEnv]
  [value-region : String]
  [target-regions : TcStringList]) : bool
  (match target-regions
    [(TcStringNil) false]
    [(TcStringCons target rest)
      (if (tc-region-outlives-or-matches env value-region target)
        true
        (tc-region-can-flow-into-any env value-region (box-get rest)))]))

(define (tc-region-list-can-flow-into
  [env : TcTypeEnv]
  [value-regions : TcStringList]
  [target-regions : TcStringList]) : bool
  (match value-regions
    [(TcStringNil) true]
    [(TcStringCons value rest)
      (and
        (tc-region-can-flow-into-any env value target-regions)
        (tc-region-list-can-flow-into env (box-get rest) target-regions))]))

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
  (if (tc-type-list-needs-resolution? types)
    (match types
      [(AstTypeNil) AstTypeNil]
      [(AstTypeCons head tail)
        (let
          [head : AstType (box-get head)]
          [tail : AstTypeList (box-get tail)]
          (ast-type-cons
            (tc-resolve-type ctx head)
            (tc-resolve-type-list ctx tail)))])
    types))

(define (tc-type-list-needs-resolution? [types : AstTypeList]) : bool
  (match types
    [(AstTypeNil) false]
    [(AstTypeCons head tail)
      (let
        [head : AstType (box-get head)]
        [tail : AstTypeList (box-get tail)]
        (if (tc-type-needs-resolution? head)
          true
          (tc-type-list-needs-resolution? tail)))]))

(define (tc-type-needs-resolution? [ty : AstType]) : bool
  (match ty
    [(AstTyFunc args ret)
      (if (tc-type-list-needs-resolution? args)
        true
        (tc-type-needs-resolution? (box-get ret)))]
    [(AstTyTuple elems) (tc-type-list-needs-resolution? elems)]
    [(AstTyArray elem _) (tc-type-needs-resolution? (box-get elem))]
    [(AstTyDynArray elem) (tc-type-needs-resolution? (box-get elem))]
    [(AstTyBox elem) (tc-type-needs-resolution? (box-get elem))]
    [(AstTyPtr elem) (tc-type-needs-resolution? (box-get elem))]
    [(AstTyMutPtr elem) (tc-type-needs-resolution? (box-get elem))]
    [(AstTyRef _ inner) (tc-type-needs-resolution? (box-get inner))]
    [(AstTyMutRef _ inner) (tc-type-needs-resolution? (box-get inner))]
    [(AstTyRegion _ inner) (tc-type-needs-resolution? (box-get inner))]
    [(AstTyVarArgs _ _) true]
    [(AstTyVar _) true]
    [_ false]))

(define (tc-name-qualified? [name : String]) : bool
  (let
    [i : i64 0]
    [n : i64 (string-length name)]
    (begin
      (while (< i n)
        (if (= (string-ref name i) #/')
          (return true)
          (set! i (+ i 1))))
      false)))

(define (tc-qualified-access-target-module
  [ctx : TcContext]
  [qualifier : String]) : String
  (match ctx
    [(TcContext program _ _ current-module)
      (match program
        [(AstProgram decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            (macro-resolve-qualified-module decls current-module qualifier))])]))

(define (tc-qualified-access-private-message
  [kind-name : String]
  [name : String]
  [target-module : String]) : String
  (string-append
    "typecheck: private "
    (string-append
      kind-name
      (string-append
        " "
        (string-append name (string-append " from module " target-module))))))

(define (tc-qualified-export-visible-ok
  [ctx : TcContext]
  [kind-name : String]
  [display-name : String]
  [target-module : String]
  [export-name : String]) : ResultTcUnit
  (if (string-eq target-module (tc-context-module ctx))
    OkTcUnit
    (match (build-compiler-exports-with
      (tc-context-program ctx)
      (tc-context-symbols ctx)
      (tc-context-registries ctx))
      [(OkCompilerExports exports)
        (match (compiler-exports-lookup
          exports
          kind-name
          target-module
          export-name)
          [(SomeI64 _) OkTcUnit]
          [(NoneI64)
            (ErrTcUnit
              (tc-qualified-access-private-message
                kind-name
                display-name
                target-module))])]
      [(ErrCompilerExports message) (ErrTcUnit message)])))

(define (tc-qualified-name-export-visible-ok
  [ctx : TcContext]
  [kind-name : String]
  [name : String]) : ResultTcUnit
  (if (tc-name-qualified? name)
    (let
      [qualifier : String (tc-qualified-name-module name)]
      [base : String (tc-qualified-name-base name)]
      [target-module : String (tc-qualified-access-target-module ctx qualifier)]
      (tc-qualified-export-visible-ok ctx kind-name name target-module base))
    OkTcUnit))

(define (tc-qualified-type-visible-ok [ctx : TcContext] [name : String]) : ResultTcUnit
  (tc-qualified-name-export-visible-ok ctx (compiler-export-kind-type) name))

(define (tc-value-export-kind-for-handle [handle : i64]) : String
  (let
    [kind : i64 (compiler-symbol-handle-kind handle)]
    (if (= kind (compiler-symbol-kind-defstruct))
      (compiler-export-kind-constructor)
      (if (= kind (compiler-symbol-kind-enum-variant))
        (compiler-export-kind-variant)
        (compiler-export-kind-value)))))

(define (tc-qualified-value-export-kind
  [ctx : TcContext]
  [target-module : String]
  [base : String]) : String
  (match (compiler-symbols-lookup-value-in-module
    (tc-context-symbols ctx)
    target-module
    base)
    [(SomeI64 handle) (tc-value-export-kind-for-handle handle)]
    [(NoneI64) (compiler-export-kind-value)]))

(define (tc-qualified-value-visible-ok [ctx : TcContext] [name : String]) : ResultTcUnit
  (if (tc-name-qualified? name)
    (let
      [qualifier : String (tc-qualified-name-module name)]
      [base : String (tc-qualified-name-base name)]
      [target-module : String (tc-qualified-access-target-module ctx qualifier)]
      [kind-name : String
        (tc-qualified-value-export-kind ctx target-module base)]
      (tc-qualified-export-visible-ok ctx kind-name name target-module base))
    OkTcUnit))

(define (tc-qualified-field-visible-ok
  [ctx : TcContext]
  [struct-name : String]
  [field : String]) : ResultTcUnit
  (if (tc-name-qualified? struct-name)
    (let
      [qualifier : String (tc-qualified-name-module struct-name)]
      [type-base : String (tc-qualified-name-base struct-name)]
      [target-module : String (tc-qualified-access-target-module ctx qualifier)]
      [export-name : String (compiler-export-field-name type-base field)]
      [display-name : String (compiler-export-field-name struct-name field)]
      (tc-qualified-export-visible-ok
        ctx
        (compiler-export-kind-field)
        display-name
        target-module
        export-name))
    OkTcUnit))

(define (tc-qualified-variant-visible-ok
  [ctx : TcContext]
  [variant-name : String]) : ResultTcUnit
  (tc-qualified-name-export-visible-ok
    ctx
    (compiler-export-kind-variant)
    variant-name))

(define (tc-resolved-nominal-type [name : String] [handle : i64]) : AstType
  (if (= (compiler-symbol-handle-kind handle) (compiler-symbol-kind-defenum))
    (AstTyEnum name)
    (if (=
      (compiler-symbol-handle-kind handle)
      (compiler-symbol-kind-defstruct))
      (AstTyStruct name)
      (AstTyVar name))))

(define (tc-resolved-nominal-type-with-args
  [name : String]
  [handle : i64]
  [lifetimes : AstLifetimeList]) : AstType
  (if (= (compiler-symbol-handle-kind handle) (compiler-symbol-kind-defenum))
    (AstTyEnumArgs name lifetimes)
    (if (=
      (compiler-symbol-handle-kind handle)
      (compiler-symbol-kind-defstruct))
      (AstTyStructArgs name lifetimes)
      (AstTyVarArgs name lifetimes))))

(define tc-nominal-owner-cache-handle : i64
  0)

(define tc-nominal-owner-cache-name : String
  "")

(define tc-nominal-owner-cache-handle1 : i64
  0)

(define tc-nominal-owner-cache-name1 : String
  "")

(define tc-nominal-owner-cache-handle2 : i64
  0)

(define tc-nominal-owner-cache-name2 : String
  "")

(define tc-nominal-owner-cache-handle3 : i64
  0)

(define tc-nominal-owner-cache-name3 : String
  "")

(define tc-nominal-owner-cache-handle4 : i64
  0)

(define tc-nominal-owner-cache-name4 : String
  "")

(define tc-nominal-owner-cache-handle5 : i64
  0)

(define tc-nominal-owner-cache-name5 : String
  "")

(define tc-nominal-owner-cache-handle6 : i64
  0)

(define tc-nominal-owner-cache-name6 : String
  "")

(define tc-nominal-owner-cache-handle7 : i64
  0)

(define tc-nominal-owner-cache-name7 : String
  "")

(define tc-resolve-type-name-cache-valid : bool
  false)

(define tc-resolve-type-name-cache-found : bool
  false)

(define tc-resolve-type-name-cache-key : String
  "")

(define tc-resolve-type-name-cache-handle : i64
  0)

(define (tc-nominal-owner-cache-reset!) : unit
  (begin
    (set! tc-nominal-owner-cache-handle 0)
    (set! tc-nominal-owner-cache-handle1 0)
    (set! tc-nominal-owner-cache-handle2 0)
    (set! tc-nominal-owner-cache-handle3 0)
    (set! tc-nominal-owner-cache-handle4 0)
    (set! tc-nominal-owner-cache-handle5 0)
    (set! tc-nominal-owner-cache-handle6 0)
    (set! tc-nominal-owner-cache-handle7 0)
    (set! tc-resolve-type-name-cache-valid false)))

(define (tc-resolve-type-name-cache-lookup [lookup-name : String]) : TcTypeNameLookupCache
  (if (and
    tc-resolve-type-name-cache-valid
    (string-eq tc-resolve-type-name-cache-key lookup-name))
    (if tc-resolve-type-name-cache-found
      (TcTypeNameLookupCacheFound tc-resolve-type-name-cache-handle)
      (TcTypeNameLookupCacheMissing))
    (TcTypeNameLookupCacheMiss)))

(define (tc-resolve-type-name-cache-store!
  [lookup-name : String]
  [found : bool]
  [handle : i64]) : unit
  (begin
    (set! tc-resolve-type-name-cache-key lookup-name)
    (set! tc-resolve-type-name-cache-found found)
    (set! tc-resolve-type-name-cache-handle handle)
    (set! tc-resolve-type-name-cache-valid true)))

(define (tc-resolve-type-name-symbol-lookup
  [symbols : CompilerSymbols]
  [lookup-name : String]) : MaybeI64
  (match (tc-resolve-type-name-cache-lookup lookup-name)
    [(TcTypeNameLookupCacheFound handle) (SomeI64 handle)]
    [(TcTypeNameLookupCacheMissing) NoneI64]
    [(TcTypeNameLookupCacheMiss)
      (match (compiler-symbols-lookup-type symbols lookup-name)
        [(SomeI64 handle)
          (begin
            (tc-resolve-type-name-cache-store! lookup-name true handle)
            (SomeI64 handle))]
        [(NoneI64)
          (begin
            (tc-resolve-type-name-cache-store! lookup-name false 0)
            NoneI64)])]))

(define (tc-nominal-owner-cache-slot [handle : i64]) : i64
  (% (compiler-symbol-handle-index handle) 8))

(define (tc-nominal-owner-cache-entry-lookup
  [ctx : TcContext]
  [handle : i64]
  [cached-handle : i64]
  [cached-name : String]) : ResultTcString
  (if (= cached-handle handle)
    (match (tc-resolve-type-name-symbol-lookup
      (tc-context-symbols ctx)
      cached-name)
      [(SomeI64 cached-handle)
        (if (= cached-handle handle)
          (OkTcString cached-name)
          (ErrTcString ""))]
      [(NoneI64) (ErrTcString "")])
    (ErrTcString "")))

(define (tc-nominal-owner-cache-lookup [ctx : TcContext] [handle : i64]) : ResultTcString
  (let
    [slot : i64 (tc-nominal-owner-cache-slot handle)]
    (cond
      [(= slot 0)
        (tc-nominal-owner-cache-entry-lookup
          ctx
          handle
          tc-nominal-owner-cache-handle
          tc-nominal-owner-cache-name)]
      [(= slot 1)
        (tc-nominal-owner-cache-entry-lookup
          ctx
          handle
          tc-nominal-owner-cache-handle1
          tc-nominal-owner-cache-name1)]
      [(= slot 2)
        (tc-nominal-owner-cache-entry-lookup
          ctx
          handle
          tc-nominal-owner-cache-handle2
          tc-nominal-owner-cache-name2)]
      [(= slot 3)
        (tc-nominal-owner-cache-entry-lookup
          ctx
          handle
          tc-nominal-owner-cache-handle3
          tc-nominal-owner-cache-name3)]
      [(= slot 4)
        (tc-nominal-owner-cache-entry-lookup
          ctx
          handle
          tc-nominal-owner-cache-handle4
          tc-nominal-owner-cache-name4)]
      [(= slot 5)
        (tc-nominal-owner-cache-entry-lookup
          ctx
          handle
          tc-nominal-owner-cache-handle5
          tc-nominal-owner-cache-name5)]
      [(= slot 6)
        (tc-nominal-owner-cache-entry-lookup
          ctx
          handle
          tc-nominal-owner-cache-handle6
          tc-nominal-owner-cache-name6)]
      [else
        (tc-nominal-owner-cache-entry-lookup
          ctx
          handle
          tc-nominal-owner-cache-handle7
          tc-nominal-owner-cache-name7)])))

(define (tc-nominal-owner-cache-store-if-safe! [handle : i64] [name : String]) : unit
  (if (tc-name-qualified? name)
    unit
    (let
      [slot : i64 (tc-nominal-owner-cache-slot handle)]
      (cond
        [(= slot 0)
          (begin
            (set! tc-nominal-owner-cache-handle handle)
            (set! tc-nominal-owner-cache-name name))]
        [(= slot 1)
          (begin
            (set! tc-nominal-owner-cache-handle1 handle)
            (set! tc-nominal-owner-cache-name1 name))]
        [(= slot 2)
          (begin
            (set! tc-nominal-owner-cache-handle2 handle)
            (set! tc-nominal-owner-cache-name2 name))]
        [(= slot 3)
          (begin
            (set! tc-nominal-owner-cache-handle3 handle)
            (set! tc-nominal-owner-cache-name3 name))]
        [(= slot 4)
          (begin
            (set! tc-nominal-owner-cache-handle4 handle)
            (set! tc-nominal-owner-cache-name4 name))]
        [(= slot 5)
          (begin
            (set! tc-nominal-owner-cache-handle5 handle)
            (set! tc-nominal-owner-cache-name5 name))]
        [(= slot 6)
          (begin
            (set! tc-nominal-owner-cache-handle6 handle)
            (set! tc-nominal-owner-cache-name6 name))]
        [else
          (begin
            (set! tc-nominal-owner-cache-handle7 handle)
            (set! tc-nominal-owner-cache-name7 name))]))))

(define (tc-nominal-owner-name-list
  [decls : AstDeclList]
  [target : i64]
  [index : i64]
  [module : String]) : ResultTcString
  (match decls
    [(AstDeclNil) (ErrTcString "typecheck: nominal owner not found")]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport _)
            (tc-nominal-owner-name-list rest target index module)]
          [(AstDeclIncludeStr _ _)
            (tc-nominal-owner-name-list rest target index module)]
          [(AstDeclExport _)
            (tc-nominal-owner-name-list rest target index module)]
          [(AstDeclModule next-module)
            (tc-nominal-owner-name-list rest target index next-module)]
          [(AstDeclTest _ _ _)
            (tc-nominal-owner-name-list rest target index module)]
          [(AstDeclDefEnum name _)
            (if (= target index)
              (OkTcString (compiler-symbol-module-key module name))
              (tc-nominal-owner-name-list rest target (+ index 1) module))]
          [(AstDeclDefEnumLifetimes name _ _)
            (if (= target index)
              (OkTcString (compiler-symbol-module-key module name))
              (tc-nominal-owner-name-list rest target (+ index 1) module))]
          [(AstDeclDefStruct name _ _ _)
            (if (= target index)
              (OkTcString (compiler-symbol-module-key module name))
              (tc-nominal-owner-name-list rest target (+ index 1) module))]
          [(AstDeclDefStructLifetimes name _ _ _ _)
            (if (= target index)
              (OkTcString (compiler-symbol-module-key module name))
              (tc-nominal-owner-name-list rest target (+ index 1) module))]
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (match template
                [(AstDeclDefEnum name _)
                  (if (= target index)
                    (OkTcString (compiler-symbol-module-key module name))
                    (tc-nominal-owner-name-list rest target (+ index 1) module))]
                [(AstDeclDefEnumLifetimes name _ _)
                  (if (= target index)
                    (OkTcString (compiler-symbol-module-key module name))
                    (tc-nominal-owner-name-list rest target (+ index 1) module))]
                [(AstDeclDefStruct name _ _ _)
                  (if (= target index)
                    (OkTcString (compiler-symbol-module-key module name))
                    (tc-nominal-owner-name-list rest target (+ index 1) module))]
                [(AstDeclDefStructLifetimes name _ _ _ _)
                  (if (= target index)
                    (OkTcString (compiler-symbol-module-key module name))
                    (tc-nominal-owner-name-list rest target (+ index 1) module))]
                [_ (tc-nominal-owner-name-list rest target (+ index 1) module)]))]
          [_ (tc-nominal-owner-name-list rest target (+ index 1) module)]))]))

(define (tc-nominal-owner-name-scan
  [program : AstProgram]
  [handle : i64]
  [index : i64]) : ResultTcString
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (tc-nominal-owner-name-list decls index 0 "")
          [(OkTcString name)
            (begin
              (tc-nominal-owner-cache-store-if-safe! handle name)
              (OkTcString name))]
          [(ErrTcString message) (ErrTcString message)]))]))

(define (tc-nominal-owner-name [ctx : TcContext] [handle : i64]) : ResultTcString
  (match (tc-nominal-owner-cache-lookup ctx handle)
    [(OkTcString cached) (OkTcString cached)]
    [(ErrTcString _)
      (match ctx
        [(TcContext program symbols _ _)
          (match (compiler-symbols-owner-name-at-index
            symbols
            (compiler-symbol-handle-index handle))
            [(CompilerSomeString name)
              (begin
                (tc-nominal-owner-cache-store-if-safe! handle name)
                (OkTcString name))]
            [(CompilerNoString)
              (tc-nominal-owner-name-scan
                program
                handle
                (compiler-symbol-handle-index handle))])])]))

(define (tc-resolve-type-name [ctx : TcContext] [name : String]) : AstType
  (match ctx
    [(TcContext _ symbols _ module)
      (let
        [lookup-name : String
          (if (and (> (string-length module) 0) (not (tc-name-qualified? name)))
            (compiler-symbol-module-key module name)
            name)]
        (match (tc-resolve-type-name-symbol-lookup symbols lookup-name)
          [(SomeI64 handle)
            (match (tc-nominal-owner-name ctx handle)
              [(OkTcString canonical-name)
                (tc-resolved-nominal-type canonical-name handle)]
              [(ErrTcString _) (tc-resolved-nominal-type lookup-name handle)])]
          [(NoneI64)
            (if (string-eq name "Expr")
              (AstTyExpr)
              (if (string-eq name "ExprList")
                (AstTyExprList)
                (AstTyVar name)))]))]))

(define (tc-resolve-type [ctx : TcContext] [ty : AstType]) : AstType
  (if (tc-type-needs-resolution? ty)
    (match ty
      [(AstTyFunc args ret)
        (ast-ty-func
          (tc-resolve-type-list ctx args)
          (tc-resolve-type ctx (box-get ret)))]
      [(AstTyTuple elems) (AstTyTuple (tc-resolve-type-list ctx elems))]
      [(AstTyArray elem len)
        (ast-ty-array (tc-resolve-type ctx (box-get elem)) len)]
      [(AstTyDynArray elem)
        (ast-ty-dyn-array (tc-resolve-type ctx (box-get elem)))]
      [(AstTyBox elem) (ast-ty-box (tc-resolve-type ctx (box-get elem)))]
      [(AstTyPtr elem) (ast-ty-ptr (tc-resolve-type ctx (box-get elem)))]
      [(AstTyMutPtr elem) (ast-ty-mut-ptr (tc-resolve-type ctx (box-get elem)))]
      [(AstTyRef region inner)
        (ast-ty-ref region (tc-resolve-type ctx (box-get inner)))]
      [(AstTyMutRef region inner)
        (ast-ty-mut-ref region (tc-resolve-type ctx (box-get inner)))]
      [(AstTyRegion region inner)
        (ast-ty-region region (tc-resolve-type ctx (box-get inner)))]
      [(AstTyVarArgs name lifetimes)
        (tc-resolve-type-name-with-args ctx name lifetimes)]
      [(AstTyVar name) (tc-resolve-type-name ctx name)]
      [_ ty])
    ty))

(define (tc-resolve-type-name-with-args
  [ctx : TcContext]
  [name : String]
  [lifetimes : AstLifetimeList]) : AstType
  (match ctx
    [(TcContext _ symbols _ module)
      (let
        [lookup-name : String
          (if (and (> (string-length module) 0) (not (tc-name-qualified? name)))
            (compiler-symbol-module-key module name)
            name)]
        (match (tc-resolve-type-name-symbol-lookup symbols lookup-name)
          [(SomeI64 handle)
            (match (tc-nominal-owner-name ctx handle)
              [(OkTcString canonical-name)
                (tc-resolved-nominal-type-with-args
                  canonical-name
                  handle
                  lifetimes)]
              [(ErrTcString _)
                (tc-resolved-nominal-type-with-args
                  lookup-name
                  handle
                  lifetimes)])]
          [(NoneI64) (AstTyVarArgs name lifetimes)]))]))

(define (tc-source-str-value-policy-message) : String
  "typecheck: str is a borrowed string-slice referent; use (& lifetime str)")

(define (tc-source-str-mut-ref-policy-message) : String
  "typecheck: mutable references to str are reserved; use immutable (& lifetime str)")

(define (tc-source-type-policy-message [name : String]) : String
  (string-append
    "typecheck: unknown type "
    (string-append
      name
      "; TypeLisp has no source-level type parameters; use comptime-generated concrete declarations instead (#893/#913/#970/#902)")))

(define (tc-nominal-lifetimes-from-decl [decl : AstDecl]) : ResultTcLifetimeList
  (match decl
    [(AstDeclDefEnum _ _) (OkTcLifetimeList AstLifetimeNil)]
    [(AstDeclDefEnumLifetimes _ lifetimes _) (OkTcLifetimeList lifetimes)]
    [(AstDeclDefStruct _ _ _ _) (OkTcLifetimeList AstLifetimeNil)]
    [(AstDeclDefStructLifetimes _ lifetimes _ _ _) (OkTcLifetimeList lifetimes)]
    [_ (ErrTcLifetimeList "typecheck: nominal type not found")]))

(define (tc-nominal-lifetimes [ctx : TcContext] [name : String]) : ResultTcLifetimeList
  (match ctx
    [(TcContext _ symbols _ _)
      (match (compiler-symbols-lookup-type symbols name)
        [(SomeI64 handle)
          (match (compiler-symbols-decl-at-index
            symbols
            (compiler-symbol-handle-index handle))
            [(OkAstDecl decl) (tc-nominal-lifetimes-from-decl decl)]
            [(ErrAstDecl message) (ErrTcLifetimeList message)])]
        [(NoneI64) (ErrTcLifetimeList "typecheck: nominal type not found")])]))

(define (tc-nominal-lifetime-use-policy-ok
  [ctx : TcContext]
  [name : String]
  [lifetimes : AstLifetimeList]) : ResultTcUnit
  (match (tc-nominal-lifetimes ctx name)
    [(OkTcLifetimeList params)
      (if (= (tc-lifetime-list-count params) (tc-lifetime-list-count lifetimes))
        OkTcUnit
        (ErrTcUnit "typecheck: nominal lifetime argument arity mismatch"))]
    [(ErrTcLifetimeList message) (ErrTcUnit message)]))

(define (tc-bare-nominal-lifetime-policy-ok [ctx : TcContext] [name : String]) : ResultTcUnit
  (match (tc-nominal-lifetimes ctx name)
    [(OkTcLifetimeList params)
      (match params
        [(AstLifetimeNil) OkTcUnit]
        [_ (ErrTcUnit "typecheck: missing nominal lifetime arguments")])]
    [(ErrTcLifetimeList message) (ErrTcUnit message)]))

(define (tc-source-type-list-policy-ok [ctx : TcContext] [types : AstTypeList]) : ResultTcUnit
  (match types
    [(AstTypeNil) OkTcUnit]
    [(AstTypeCons head tail)
      (let
        [head : AstType (box-get head)]
        [tail : AstTypeList (box-get tail)]
        (match (tc-source-type-policy-ok ctx head)
          [(OkTcUnit) (tc-source-type-list-policy-ok ctx tail)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]))

(define (tc-source-type-policy-ok [ctx : TcContext] [ty : AstType]) : ResultTcUnit
  (match (tc-resolve-type ctx ty)
    [(AstTyFunc args ret)
      (match (tc-source-type-list-policy-ok ctx args)
        [(OkTcUnit) (tc-source-type-policy-ok ctx (box-get ret))]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstTyTuple elems) (tc-source-type-list-policy-ok ctx elems)]
    [(AstTyArray elem _) (tc-source-type-policy-ok ctx (box-get elem))]
    [(AstTyDynArray elem) (tc-source-type-policy-ok ctx (box-get elem))]
    [(AstTyBox elem) (tc-source-type-policy-ok ctx (box-get elem))]
    [(AstTyPtr elem) (tc-source-type-policy-ok ctx (box-get elem))]
    [(AstTyMutPtr elem) (tc-source-type-policy-ok ctx (box-get elem))]
    [(AstTyRef _ inner)
      (match (tc-resolve-type ctx (box-get inner))
        [(AstTyStr) OkTcUnit]
        [_ (tc-source-type-policy-ok ctx (box-get inner))])]
    [(AstTyMutRef _ inner)
      (match (tc-resolve-type ctx (box-get inner))
        [(AstTyStr) (ErrTcUnit (tc-source-str-mut-ref-policy-message))]
        [_
          (match (tc-source-type-policy-ok ctx (box-get inner))
            [(OkTcUnit)
              (ErrTcUnit
                "typecheck: mutable reference types require mutable borrow checker support (#806)")]
            [(ErrTcUnit message) (ErrTcUnit message)])])]
    [(AstTyRegion _ inner) (tc-source-type-policy-ok ctx (box-get inner))]
    [(AstTyStr) (ErrTcUnit (tc-source-str-value-policy-message))]
    [(AstTyEnum name)
      (match (tc-qualified-type-visible-ok ctx name)
        [(OkTcUnit) (tc-bare-nominal-lifetime-policy-ok ctx name)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstTyStruct name)
      (match (tc-qualified-type-visible-ok ctx name)
        [(OkTcUnit) (tc-bare-nominal-lifetime-policy-ok ctx name)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstTyEnumArgs name lifetimes)
      (match (tc-qualified-type-visible-ok ctx name)
        [(OkTcUnit) (tc-nominal-lifetime-use-policy-ok ctx name lifetimes)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstTyStructArgs name lifetimes)
      (match (tc-qualified-type-visible-ok ctx name)
        [(OkTcUnit) (tc-nominal-lifetime-use-policy-ok ctx name lifetimes)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstTyVarArgs name _) (ErrTcUnit (tc-source-type-policy-message name))]
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
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam _ ty _)
            (match (tc-source-type-policy-ok ctx ty)
              [(OkTcUnit) (tc-source-param-list-policy-ok ctx rest)]
              [(ErrTcUnit message) (ErrTcUnit message)])]))]))

(define (tc-source-macro-param-list-policy-ok
  [ctx : TcContext]
  [params : AstMacroParamList]) : ResultTcUnit
  (match params
    [(AstMacroParamNil) OkTcUnit]
    [(AstMacroParamCons param rest)
      (let
        [rest : AstMacroParamList (box-get rest)]
        (match param
          [(AstMacroParam _ ty _)
            (match (tc-source-type-policy-ok ctx ty)
              [(OkTcUnit) (tc-source-macro-param-list-policy-ok ctx rest)]
              [(ErrTcUnit message) (ErrTcUnit message)])]))]))

(define (tc-source-field-list-policy-ok
  [ctx : TcContext]
  [fields : AstFieldDefList]) : ResultTcUnit
  (match fields
    [(AstFieldDefNil) OkTcUnit]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef _ ty _)
            (match (tc-source-type-policy-ok ctx ty)
              [(OkTcUnit) (tc-source-field-list-policy-ok ctx rest)]
              [(ErrTcUnit message) (ErrTcUnit message)])]))]))

(define (tc-struct-cleanup-repr-c-message [struct-name : String]) : String
  (tc-cat3 "typecheck: cleanup-owning struct " struct-name " cannot use repr c"))

(define (tc-source-variant-list-policy-ok
  [ctx : TcContext]
  [variants : AstVariantDefList]) : ResultTcUnit
  (match variants
    [(AstVariantDefNil) OkTcUnit]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef _ fields)
            (match (tc-source-type-list-policy-ok ctx fields)
              [(OkTcUnit) (tc-source-variant-list-policy-ok ctx rest)]
              [(ErrTcUnit message) (ErrTcUnit message)])]))]))

(define (tc-decl-lifetime-name-allowed?
  [params : AstLifetimeList]
  [name : String]) : bool
  (or (string-eq name "program") (tc-lifetime-list-contains params name)))

(define (tc-decl-lifetime-string-list-all-in?
  [lifetimes : TcStringList]
  [params : AstLifetimeList]) : bool
  (match lifetimes
    [(TcStringNil) true]
    [(TcStringCons lifetime rest)
      (and
        (tc-decl-lifetime-name-allowed? params lifetime)
        (tc-decl-lifetime-string-list-all-in? (box-get rest) params))]))

(define (tc-source-type-decl-lifetimes-ok
  [ctx : TcContext]
  [params : AstLifetimeList]
  [ty : AstType]) : ResultTcUnit
  (let
    [lifetimes : TcStringList
      (tc-type-collect-reference-lifetimes (tc-resolve-type ctx ty))]
    (if (tc-decl-lifetime-string-list-all-in? lifetimes params)
      OkTcUnit
      (ErrTcUnit "typecheck: unknown aggregate lifetime parameter"))))

(define (tc-source-field-list-lifetimes-policy-ok
  [ctx : TcContext]
  [params : AstLifetimeList]
  [fields : AstFieldDefList]) : ResultTcUnit
  (match fields
    [(AstFieldDefNil) OkTcUnit]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef _ ty _)
            (match (tc-source-type-policy-ok ctx ty)
              [(OkTcUnit)
                (match (tc-source-type-decl-lifetimes-ok ctx params ty)
                  [(OkTcUnit)
                    (tc-source-field-list-lifetimes-policy-ok ctx params rest)]
                  [(ErrTcUnit message) (ErrTcUnit message)])]
              [(ErrTcUnit message) (ErrTcUnit message)])]))]))

(define (tc-source-type-list-lifetimes-policy-ok
  [ctx : TcContext]
  [params : AstLifetimeList]
  [types : AstTypeList]) : ResultTcUnit
  (match types
    [(AstTypeNil) OkTcUnit]
    [(AstTypeCons head tail)
      (let
        [head : AstType (box-get head)]
        [tail : AstTypeList (box-get tail)]
        (match (tc-source-type-policy-ok ctx head)
          [(OkTcUnit)
            (match (tc-source-type-decl-lifetimes-ok ctx params head)
              [(OkTcUnit)
                (tc-source-type-list-lifetimes-policy-ok ctx params tail)]
              [(ErrTcUnit message) (ErrTcUnit message)])]
          [(ErrTcUnit message) (ErrTcUnit message)]))]))

(define (tc-source-variant-list-lifetimes-policy-ok
  [ctx : TcContext]
  [params : AstLifetimeList]
  [variants : AstVariantDefList]) : ResultTcUnit
  (match variants
    [(AstVariantDefNil) OkTcUnit]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef _ fields)
            (match (tc-source-type-list-lifetimes-policy-ok ctx params fields)
              [(OkTcUnit)
                (tc-source-variant-list-lifetimes-policy-ok ctx params rest)]
              [(ErrTcUnit message) (ErrTcUnit message)])]))]))

(define (tc-source-default-aggregate-layout-finite-ok
  [ctx : TcContext]
  [name : String]) : ResultTcUnit
  (tc-inline-aggregate-layout-finite-ok
    ctx
    (compiler-symbol-module-key (tc-context-module ctx) name)))

(define (tc-source-default-struct-layout-finite-ok
  [ctx : TcContext]
  [name : String]
  [repr : AstStructRepr]) : ResultTcUnit
  (if (ast-struct-repr-c? repr)
    OkTcUnit
    (tc-source-default-aggregate-layout-finite-ok ctx name)))

(define (tc-source-pattern-list-policy-ok
  [ctx : TcContext]
  [patterns : AstPatternList]) : ResultTcUnit
  (match patterns
    [(AstPatternNil) OkTcUnit]
    [(AstPatternCons pattern rest)
      (let
        [pattern : AstPattern (box-get pattern)]
        [rest : AstPatternList (box-get rest)]
        (match (tc-source-pattern-policy-ok ctx pattern)
          [(OkTcUnit) (tc-source-pattern-list-policy-ok ctx rest)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]))

(define (tc-source-pattern-policy-ok [ctx : TcContext] [pattern : AstPattern]) : ResultTcUnit
  (match pattern
    [(AstPatVar _ maybe-ty) (tc-source-maybe-type-policy-ok ctx maybe-ty)]
    [(AstPatTuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (tc-source-pattern-list-policy-ok ctx patterns))]
    [(AstPatVariant _ patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (tc-source-pattern-list-policy-ok ctx patterns))]
    [_ OkTcUnit]))

(define (tc-source-match-arm-list-policy-ok
  [ctx : TcContext]
  [arms : AstMatchArmList]) : ResultTcUnit
  (match arms
    [(AstMatchArmNil) OkTcUnit]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern body-box)
            (let
              [body : AstExpr (box-get body-box)]
              (match (tc-source-pattern-policy-ok ctx pattern)
                [(OkTcUnit)
                  (match (tc-source-expr-policy-ok ctx body)
                    [(OkTcUnit) (tc-source-match-arm-list-policy-ok ctx rest)]
                    [(ErrTcUnit message) (ErrTcUnit message)])]
                [(ErrTcUnit message) (ErrTcUnit message)]))]))]))

(define (tc-source-let-binding-list-policy-ok
  [ctx : TcContext]
  [bindings : AstLetBindingList]) : ResultTcUnit
  (match bindings
    [(AstLetBindingNil) OkTcUnit]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding _ maybe-ty init-box)
            (let
              [init : AstExpr (box-get init-box)]
              (match (tc-source-maybe-type-policy-ok ctx maybe-ty)
                [(OkTcUnit)
                  (match (tc-source-expr-policy-ok ctx init)
                    [(OkTcUnit) (tc-source-let-binding-list-policy-ok ctx rest)]
                    [(ErrTcUnit message) (ErrTcUnit message)])]
                [(ErrTcUnit message) (ErrTcUnit message)]))]))]))

(define (tc-source-resource-binding-list-policy-ok
  [ctx : TcContext]
  [bindings : AstResourceBindingList]) : ResultTcUnit
  (match bindings
    [(AstResourceBindingNil) OkTcUnit]
    [(AstResourceBindingCons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding _ init-box cleanup-box)
            (let
              [init : AstExpr (box-get init-box)]
              [cleanup : AstExpr (box-get cleanup-box)]
              (match (tc-source-expr-policy-ok ctx init)
                [(OkTcUnit)
                  (match (tc-source-expr-policy-ok ctx cleanup)
                    [(OkTcUnit)
                      (tc-source-resource-binding-list-policy-ok ctx rest)]
                    [(ErrTcUnit message) (ErrTcUnit message)])]
                [(ErrTcUnit message) (ErrTcUnit message)]))]))]))

(define (tc-source-expr-list-policy-ok [ctx : TcContext] [exprs : AstExprList]) : ResultTcUnit
  (match exprs
    [(AstExprNil) OkTcUnit]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (box-get expr)]
        [rest : AstExprList (box-get rest)]
        (match (tc-source-expr-policy-ok ctx expr)
          [(OkTcUnit) (tc-source-expr-list-policy-ok ctx rest)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]))

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
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-source-expr-policy-ok ctx inner))]
    [(AstExprBinary _ left-box right-box)
      (let
        [left : AstExpr (box-get left-box)]
        [right : AstExpr (box-get right-box)]
        (tc-source-expr-pair-policy-ok ctx left right))]
    [(AstExprUnary _ inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-source-expr-policy-ok ctx inner))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (box-get func-box)]
        (match (tc-source-expr-policy-ok ctx func)
          [(OkTcUnit) (tc-source-expr-list-policy-ok ctx args)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprTypeLiteral ty) (tc-source-type-policy-ok ctx ty)]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [then-branch : AstExpr (box-get then-branch-box)]
        [else-branch : AstExpr (box-get else-branch-box)]
        (tc-source-expr-triple-policy-ok ctx cond then-branch else-branch))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (match (tc-source-let-binding-list-policy-ok ctx bindings)
          [(OkTcUnit) (tc-source-expr-policy-ok ctx body)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprLambda params maybe-ret body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (match (tc-source-param-list-policy-ok ctx params)
          [(OkTcUnit)
            (match (tc-source-maybe-type-policy-ok ctx maybe-ret)
              [(OkTcUnit)
                (if (tc-maybe-type-contains-reference? maybe-ret)
                  (ErrTcUnit
                    "typecheck: returning references requires lifetime support (#804)")
                  (tc-source-expr-policy-ok ctx body))]
              [(ErrTcUnit message) (ErrTcUnit message)])]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprTuple exprs) (tc-source-expr-list-policy-ok ctx exprs)]
    [(AstExprTupleRef tuple-box _)
      (let
        [tuple : AstExpr (box-get tuple-box)]
        (tc-source-expr-policy-ok ctx tuple))]
    [(AstExprArray exprs) (tc-source-expr-list-policy-ok ctx exprs)]
    [(AstExprMakeArray elem-ty len-box)
      (let
        [len : AstExpr (box-get len-box)]
        (match (tc-source-type-policy-ok ctx elem-ty)
          [(OkTcUnit) (tc-source-expr-policy-ok ctx len)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        (tc-source-expr-pair-policy-ok ctx array index))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        [value : AstExpr (box-get value-box)]
        (tc-source-expr-triple-policy-ok ctx array index value))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (box-get array-box)]
        [value : AstExpr (box-get value-box)]
        (tc-source-expr-pair-policy-ok ctx array value))]
    [(AstExprStringRef str-box index-box)
      (let
        [str : AstExpr (box-get str-box)]
        [index : AstExpr (box-get index-box)]
        (tc-source-expr-pair-policy-ok ctx str index))]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [body : AstExpr (box-get body-box)]
        (tc-source-expr-pair-policy-ok ctx cond body))]
    [(AstExprBegin exprs) (tc-source-expr-list-policy-ok ctx exprs)]
    [(AstExprUnsafe exprs) (tc-source-expr-list-policy-ok ctx exprs)]
    [(AstExprSet _ value-box)
      (let
        [value : AstExpr (box-get value-box)]
        (tc-source-expr-policy-ok ctx value))]
    [(AstExprAnn inner-box ty)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-source-expr-policy-ok ctx inner)
          [(OkTcUnit) (tc-source-type-policy-ok ctx ty)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprCast inner-box ty)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-source-expr-policy-ok ctx inner)
          [(OkTcUnit) (tc-source-type-policy-ok ctx ty)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprBorrow _ place-box)
      (let
        [place : AstExpr (box-get place-box)]
        (tc-source-expr-policy-ok ctx place))]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-source-expr-policy-ok ctx inner))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-source-expr-policy-ok ctx inner))]
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (box-get scrutinee-box)]
        (match (tc-source-expr-policy-ok ctx scrutinee)
          [(OkTcUnit) (tc-source-match-arm-list-policy-ok ctx arms)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprForeach _ index-ty start-box end-box body-box)
      (let
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [body : AstExpr (box-get body-box)]
        (match (tc-source-type-policy-ok ctx index-ty)
          [(OkTcUnit) (tc-source-expr-triple-policy-ok ctx start end body)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprSpmdReduce _ _ index-ty start-box end-box init-box value-box)
      (let
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [init : AstExpr (box-get init-box)]
        [value : AstExpr (box-get value-box)]
        (match (tc-source-type-policy-ok ctx index-ty)
          [(OkTcUnit)
            (match (tc-source-expr-triple-policy-ok ctx start end init)
              [(OkTcUnit) (tc-source-expr-policy-ok ctx value)]
              [(ErrTcUnit message) (ErrTcUnit message)])]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprStructGet receiver-box _)
      (let
        [receiver : AstExpr (box-get receiver-box)]
        (tc-source-expr-policy-ok ctx receiver))]
    [(AstExprWithRegion _ body) (tc-source-expr-list-policy-ok ctx body)]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (box-get scratch-box)]
        (match (tc-source-expr-policy-ok ctx scratch)
          [(OkTcUnit) (tc-source-expr-list-policy-ok ctx body)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprWithResource bindings body)
      (match (tc-source-resource-binding-list-policy-ok ctx bindings)
        [(OkTcUnit) (tc-source-expr-list-policy-ok ctx body)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-source-expr-policy-ok ctx inner))]
    [(AstExprQuote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-source-expr-policy-ok ctx inner))]
    [(AstExprQuasiquote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-source-expr-policy-ok ctx inner))]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-source-expr-policy-ok ctx inner))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-source-expr-policy-ok ctx inner))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-source-expr-policy-ok ctx inner))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-source-expr-policy-ok ctx inner))]
    [(AstExprPtrNullCheck inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-source-expr-policy-ok ctx inner))]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (tc-source-expr-policy-ok ctx ptr))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [value : AstExpr (box-get value-box)]
        (tc-source-expr-pair-policy-ok ctx ptr value))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [offset : AstExpr (box-get offset-box)]
        (tc-source-expr-pair-policy-ok ctx ptr offset))]
    [(AstExprPtrCast ptr-box ty)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (match (tc-source-expr-policy-ok ctx ptr)
          [(OkTcUnit) (tc-source-type-policy-ok ctx ty)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (tc-source-expr-policy-ok ctx ptr))]
    [(AstExprIntToPtr value-box ty)
      (let
        [value : AstExpr (box-get value-box)]
        (match (tc-source-expr-policy-ok ctx value)
          [(OkTcUnit) (tc-source-type-policy-ok ctx ty)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprStringData str-box)
      (let
        [str : AstExpr (box-get str-box)]
        (tc-source-expr-policy-ok ctx str))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [len : AstExpr (box-get len-box)]
        (tc-source-expr-pair-policy-ok ctx ptr len))]
    [(AstExprArrayData array-box)
      (let
        [array : AstExpr (box-get array-box)]
        (tc-source-expr-policy-ok ctx array))]
    [(AstExprProgramArgc) OkTcUnit]
    [(AstExprProgramArgv) OkTcUnit]
    [(AstExprProgramEnvp) OkTcUnit]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (tc-source-expr-pair-policy-ok ctx leaf subleaf))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (tc-source-expr-pair-policy-ok ctx leaf subleaf))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (tc-source-expr-pair-policy-ok ctx leaf subleaf))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (tc-source-expr-pair-policy-ok ctx leaf subleaf))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (box-get index-box)]
        (tc-source-expr-policy-ok ctx index))]
    [_ OkTcUnit]))

(define (tc-source-decl-policy-ok [ctx : TcContext] [decl : AstDecl]) : ResultTcUnit
  (match decl
    [(AstDeclDef _ maybe-ty expr-box)
      (let
        [expr : AstExpr (box-get expr-box)]
        (match (tc-source-maybe-type-policy-ok ctx maybe-ty)
          [(OkTcUnit)
            (if (tc-maybe-type-contains-reference? maybe-ty)
              (ErrTcUnit
                "typecheck: storing references in top-level values requires lifetime support (#804)")
              (tc-source-expr-policy-ok ctx expr))]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstDeclDefFn _ params ret body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (match (tc-source-param-list-policy-ok ctx params)
          [(OkTcUnit)
            (match (tc-source-type-policy-ok ctx ret)
              [(OkTcUnit)
                (match (tc-reference-return-policy-ok ctx params ret)
                  [(OkTcUnit) (tc-source-expr-policy-ok ctx body)]
                  [(ErrTcUnit message) (ErrTcUnit message)])]
              [(ErrTcUnit message) (ErrTcUnit message)])]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstDeclDefMacro _ params ret body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (match (tc-source-macro-param-list-policy-ok ctx params)
          [(OkTcUnit)
            (match (tc-source-type-policy-ok ctx ret)
              [(OkTcUnit) (tc-source-expr-policy-ok ctx body)]
              [(ErrTcUnit message) (ErrTcUnit message)])]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstDeclExtern _ _ ty) (tc-source-type-policy-ok ctx ty)]
    [(AstDeclDefEnum name variants)
      (match (tc-source-variant-list-policy-ok ctx variants)
        [(OkTcUnit) (tc-source-default-aggregate-layout-finite-ok ctx name)]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstDeclDefEnumLifetimes name lifetimes variants)
      (if (tc-lifetime-list-duplicates? lifetimes)
        (ErrTcUnit "typecheck: duplicate lifetime parameter")
        (match (tc-source-variant-list-lifetimes-policy-ok
          ctx
          lifetimes
          variants)
          [(OkTcUnit) (tc-source-default-aggregate-layout-finite-ok ctx name)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstDeclDefStruct name repr cleanup fields)
      (match (tc-source-field-list-policy-ok ctx fields)
        [(OkTcUnit)
          (if (and (ast-struct-repr-c? repr) (ast-struct-cleanup? cleanup))
            (ErrTcUnit
              (tc-struct-cleanup-repr-c-message
                (compiler-symbol-module-key (tc-context-module ctx) name)))
            (tc-source-default-struct-layout-finite-ok ctx name repr))]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [(AstDeclDefStructLifetimes name lifetimes repr cleanup fields)
      (if (tc-lifetime-list-duplicates? lifetimes)
        (ErrTcUnit "typecheck: duplicate lifetime parameter")
        (match (tc-source-field-list-lifetimes-policy-ok ctx lifetimes fields)
          [(OkTcUnit)
            (if (and (ast-struct-repr-c? repr) (ast-struct-cleanup? cleanup))
              (ErrTcUnit
                (tc-struct-cleanup-repr-c-message
                  (compiler-symbol-module-key (tc-context-module ctx) name)))
              (tc-source-default-struct-layout-finite-ok ctx name repr))]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstDeclDefDispatch _ _) OkTcUnit]
    [(AstDeclIncludeStr _ _)
      (ErrTcUnit "typecheck: include-str must be expanded by compiler loader")]
    [(AstDeclImport _) OkTcUnit]
    [(AstDeclExport _) OkTcUnit]
    [(AstDeclModule _) OkTcUnit]
    [(AstDeclTest _ body-box _)
      (let
        [body : AstExpr (box-get body-box)]
        (tc-source-expr-policy-ok ctx body))]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tc-source-decl-policy-ok ctx inner))]
    [(AstDeclComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (tc-source-decl-policy-ok ctx template))]))

(define (tc-source-decl-list-policy-ok [ctx : TcContext] [decls : AstDeclList]) : ResultTcUnit
  (tc-source-decl-list-policy-ok-in-module ctx decls ""))

(define (tc-source-decl-list-policy-ok-in-module
  [ctx : TcContext]
  [decls : AstDeclList]
  [module : String]) : ResultTcUnit
  (match decls
    [(AstDeclNil) OkTcUnit]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule next-module)
            (tc-source-decl-list-policy-ok-in-module ctx rest next-module)]
          [_
            (match (tc-source-decl-policy-ok
              (tc-context-with-module ctx module)
              decl)
              [(OkTcUnit)
                (tc-source-decl-list-policy-ok-in-module ctx rest module)]
              [(ErrTcUnit message) (ErrTcUnit message)])]))]))

(define (tc-program-source-types-policy-ok
  [ctx : TcContext]
  [program : AstProgram]) : ResultTcUnit
  (begin
    (tc-nominal-owner-cache-reset!)
    (match program
      [(AstProgram decls-box)
        (let
          [decls : AstDeclList (box-get decls-box)]
          (tc-source-decl-list-policy-ok ctx decls))])))

(define (tc-type-list-eq [a : AstTypeList] [b : AstTypeList]) : bool
  (match a
    [(AstTypeNil)
      (match b
        [(AstTypeNil) true]
        [_ false])]
    [(AstTypeCons ah at)
      (let
        [ah : AstType (box-get ah)]
        [at : AstTypeList (box-get at)]
        (match b
          [(AstTypeCons bh bt)
            (let
              [bh : AstType (box-get bh)]
              [bt : AstTypeList (box-get bt)]
              (and (tc-type-eq ah bh) (tc-type-list-eq at bt)))]
          [_ false]))]))

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
    [(AstTyStr)
      (match b
        [(AstTyStr) true]
        [_ false])]
    [(AstTyUnit)
      (match b
        [(AstTyUnit) true]
        [_ false])]
    [(AstTyNever)
      (match b
        [(AstTyNever) true]
        [_ false])]
    [(AstTyExpr)
      (match b
        [(AstTyExpr) true]
        [_ false])]
    [(AstTyExprList)
      (match b
        [(AstTyExprList) true]
        [_ false])]
    [(AstTyFunc a-args a-ret)
      (match b
        [(AstTyFunc b-args b-ret)
          (and
            (tc-type-list-eq a-args b-args)
            (tc-type-eq (box-get a-ret) (box-get b-ret)))]
        [_ false])]
    [(AstTyTuple a-elems)
      (match b
        [(AstTyTuple b-elems) (tc-type-list-eq a-elems b-elems)]
        [_ false])]
    [(AstTyArray a-elem a-len)
      (match b
        [(AstTyArray b-elem b-len)
          (and (= a-len b-len) (tc-type-eq (box-get a-elem) (box-get b-elem)))]
        [_ false])]
    [(AstTyDynArray a-elem)
      (match b
        [(AstTyDynArray b-elem) (tc-type-eq (box-get a-elem) (box-get b-elem))]
        [_ false])]
    [(AstTyBox a-elem)
      (match b
        [(AstTyBox b-elem) (tc-type-eq (box-get a-elem) (box-get b-elem))]
        [_ false])]
    [(AstTyPtr a-elem)
      (match b
        [(AstTyPtr b-elem) (tc-type-eq (box-get a-elem) (box-get b-elem))]
        [_ false])]
    [(AstTyMutPtr a-elem)
      (match b
        [(AstTyMutPtr b-elem) (tc-type-eq (box-get a-elem) (box-get b-elem))]
        [_ false])]
    [(AstTyRef a-region a-inner)
      (match b
        [(AstTyRef b-region b-inner)
          (and
            (string-eq a-region b-region)
            (tc-type-eq (box-get a-inner) (box-get b-inner)))]
        [_ false])]
    [(AstTyMutRef a-region a-inner)
      (match b
        [(AstTyMutRef b-region b-inner)
          (and
            (string-eq a-region b-region)
            (tc-type-eq (box-get a-inner) (box-get b-inner)))]
        [_ false])]
    [(AstTyRegion _ inner)
      (tc-type-eq-core
        (tc-type-without-regions (box-get inner))
        (tc-type-without-regions b))]
    [(AstTyEnum a-name)
      (match b
        [(AstTyEnum b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstTyEnumArgs a-name a-lifetimes)
      (match b
        [(AstTyEnumArgs b-name b-lifetimes)
          (and
            (string-eq a-name b-name)
            (tc-lifetime-list-eq a-lifetimes b-lifetimes))]
        [_ false])]
    [(AstTyStruct a-name)
      (match b
        [(AstTyStruct b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstTyStructArgs a-name a-lifetimes)
      (match b
        [(AstTyStructArgs b-name b-lifetimes)
          (and
            (string-eq a-name b-name)
            (tc-lifetime-list-eq a-lifetimes b-lifetimes))]
        [_ false])]
    [(AstTyVar a-name)
      (match b
        [(AstTyVar b-name) (string-eq a-name b-name)]
        [_ false])]
    [(AstTyVarArgs a-name a-lifetimes)
      (match b
        [(AstTyVarArgs b-name b-lifetimes)
          (and
            (string-eq a-name b-name)
            (tc-lifetime-list-eq a-lifetimes b-lifetimes))]
        [_ false])]))

(define (tc-type-eq [a : AstType] [b : AstType]) : bool
  (match a
    [(AstTyRegion _ inner) (tc-type-eq (box-get inner) b)]
    [_
      (match b
        [(AstTyRegion _ inner) (tc-type-eq a (box-get inner))]
        [_ (tc-type-eq-core a b)])]))

(define (tc-never-type? [ty : AstType]) : bool
  (match ty
    [(AstTyNever) true]
    [_ false]))

(define (tc-f32-to-f64-compatible? [expected : AstType] [actual : AstType]) : bool
  (match (tc-type-strip-region expected)
    [(AstTyF64)
      (match (tc-type-strip-region actual)
        [(AstTyF32) true]
        [_ false])]
    [_ false]))

(define (tc-type-compatible? [expected : AstType] [actual : AstType]) : bool
  (if (tc-never-type? actual)
    true
    (if (tc-type-eq expected actual)
      true
      (tc-f32-to-f64-compatible? expected actual))))

(define (tc-merge-branch-type [a : AstType] [b : AstType]) : ResultTcType
  (cond
    [(tc-never-type? a) (OkTcType b)]
    [(tc-never-type? b) (OkTcType a)]
    [(tc-type-eq a b)
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
                [_ (ErrTcType "typecheck: if branches must match")])])))]
    [else
      (if (tc-type-compatible? a b)
        (OkTcType a)
        (if (tc-type-compatible? b a)
          (OkTcType b)
          (ErrTcType "typecheck: if branches must match")))]))

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
    [(AstTyF32) true]
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
      [(AstTyF64) true]
      [(AstTyF32) true]
      [_ false])))

(define (tc-raw-pointer-type? [ty : AstType]) : bool
  (match (tc-type-strip-region ty)
    [(AstTyPtr _) true]
    [(AstTyMutPtr _) true]
    [_ false]))

(define (tc-type-move-kind [ty : AstType]) : TcMoveKind
  (match ty
    [(AstTyI64) (TcCopyable)]
    [(AstTyI32) (TcCopyable)]
    [(AstTyI16) (TcCopyable)]
    [(AstTyI8) (TcCopyable)]
    [(AstTyU64) (TcCopyable)]
    [(AstTyU32) (TcCopyable)]
    [(AstTyU16) (TcCopyable)]
    [(AstTyU8) (TcCopyable)]
    [(AstTyF64) (TcCopyable)]
    [(AstTyF32) (TcCopyable)]
    [(AstTyBool) (TcCopyable)]
    [(AstTyChar) (TcCopyable)]
    [(AstTyUnit) (TcCopyable)]
    [(AstTyNever) (TcCopyable)]
    [(AstTyExpr) (TcCopyable)]
    [(AstTyExprList) (TcCopyable)]
    [(AstTyFunc _ _) (TcCopyable)]
    [(AstTyPtr _) (TcCopyable)]
    [(AstTyMutPtr _) (TcCopyable)]
    [(AstTyRef _ _) (TcCopyable)]
    [(AstTyRegion _ inner) (tc-type-move-kind (box-get inner))]
    [(AstTyString) (TcMoveOnly)]
    [(AstTyStr) (TcMoveOnly)]
    [(AstTyTuple _) (TcMoveOnly)]
    [(AstTyArray _ _) (TcMoveOnly)]
    [(AstTyDynArray _) (TcMoveOnly)]
    [(AstTyBox _) (TcMoveOnly)]
    [(AstTyMutRef _ _) (TcMoveOnly)]
    [(AstTyEnum _) (TcMoveOnly)]
    [(AstTyEnumArgs _ _) (TcMoveOnly)]
    [(AstTyStruct _) (TcMoveOnly)]
    [(AstTyStructArgs _ _) (TcMoveOnly)]
    [(AstTyVar _) (TcMoveOnly)]
    [(AstTyVarArgs _ _) (TcMoveOnly)]))

(define (tc-move-kind-copyable? [kind : TcMoveKind]) : bool
  (match kind
    [(TcCopyable) true]
    [(TcMoveOnly) false]))

(define (tc-type-copyable? [ty : AstType]) : bool
  (tc-move-kind-copyable? (tc-type-move-kind ty)))

(define (tc-type-move-only? [ty : AstType]) : bool
  (not (tc-type-copyable? ty)))

(define (tc-raw-pointer-elem [ty : AstType] [message : String]) : ResultTcType
  (match (tc-type-strip-region ty)
    [(AstTyPtr elem) (OkTcType (box-get elem))]
    [(AstTyMutPtr elem) (OkTcType (box-get elem))]
    [_ (ErrTcType message)]))

(define (tc-mut-pointer-elem [ty : AstType] [message : String]) : ResultTcType
  (match (tc-type-strip-region ty)
    [(AstTyMutPtr elem) (OkTcType (box-get elem))]
    [_ (ErrTcType message)]))

(define (tc-require-unsafe [env : TcTypeEnv] [name : String]) : ResultTcUnit
  (if (tc-in-unsafe? env)
    OkTcUnit
    (ErrTcUnit
      (string-append
        "typecheck: "
        (string-append name " requires unsafe context")))))

(define (tc-dyn-array-elem-supported? [env : TcTypeEnv] [ty : AstType]) : bool
  (if (tc-integer-type? ty)
    true
    (match (tc-type-strip-region ty)
      [(AstTyBool) true]
      [(AstTyChar) true]
      [(AstTyF64) true]
      [(AstTyF32) true]
      [(AstTyString) true]
      [(AstTyEnum _) true]
      [(AstTyEnumArgs _ _) true]
      [(AstTyStruct _) true]
      [(AstTyStructArgs _ _) true]
      [(AstTyDynArray _) true]
      [(AstTyRef _ _)
        (tc-reference-lifetimes-visible?
          env
          (tc-type-collect-reference-lifetimes ty))]
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
    [(AstTyF32) true]
    [(AstTyBool) true]
    [_ false]))

(define (tc-spmd-lane-type-supported? [ty : AstType]) : bool
  (match (tc-type-strip-region ty)
    [(AstTyI64) true]
    [(AstTyI32) true]
    [(AstTyF64) true]
    [(AstTyF32) true]
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

(define (tc-spmd-cpuid-like
  [ctx : TcContext]
  [env : TcTypeEnv]
  [spmd-env : TcSpmdEnv]
  [expr-ty : AstType]
  [leaf : AstExpr]
  [subleaf : AstExpr]) : ResultTcSpmdExprInfo
  (match (tc-spmd-expr ctx env spmd-env leaf)
    [(OkTcSpmdExprInfo leaf-info)
      (match leaf-info
        [(TcSpmdExprInfo _ leaf-class leaf-env)
          (match (tc-spmd-expr ctx env leaf-env subleaf)
            [(OkTcSpmdExprInfo subleaf-info)
              (match subleaf-info
                [(TcSpmdExprInfo _ subleaf-class subleaf-env)
                  (tc-spmd-finish
                    expr-ty
                    (tc-spmd-merge-class leaf-class subleaf-class)
                    subleaf-env)])]
            [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])])]
    [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))

(define (tc-spmd-env-from-type-env [env : TcTypeEnv]) : TcSpmdEnv
  (match env
    [(TcTypeNil) TcSpmdEnvNil]
    [(TcTypeCache _ _ _ _ rest) (tc-spmd-env-from-type-env (box-get rest))]
    [(TcTypeBind name ty rest)
      (TcSpmdEnvBind
        name
        ty
        TcSpmdUniform
        TcSpmdOuter
        (box (tc-spmd-env-from-type-env (box-get rest))))]))

(define (tc-spmd-env-bind
  [env : TcSpmdEnv]
  [name : String]
  [ty : AstType]
  [class : TcSpmdClass]
  [scope : TcSpmdScope]) : TcSpmdEnv
  (TcSpmdEnvBind name ty class scope (box env)))

(define (tc-spmd-env-lookup [env : TcSpmdEnv] [name : String]) : TcSpmdLookup
  (match env
    [(TcSpmdEnvNil) TcSpmdMissing]
    [(TcSpmdEnvBind key ty class scope rest)
      (if (string-eq key name)
        (TcSpmdFound ty class scope)
        (tc-spmd-env-lookup (box-get rest) name))]))

(define (tc-spmd-env-has-local? [env : TcSpmdEnv] [name : String]) : bool
  (match env
    [(TcSpmdEnvNil) false]
    [(TcSpmdEnvBind key _ _ scope rest)
      (if (string-eq key name)
        (match scope
          [(TcSpmdLocal) true]
          [(TcSpmdOuter) (tc-spmd-env-has-local? (box-get rest) name)])
        (tc-spmd-env-has-local? (box-get rest) name))]))

(define (tc-spmd-env-has-outer? [env : TcSpmdEnv] [name : String]) : bool
  (match env
    [(TcSpmdEnvNil) false]
    [(TcSpmdEnvBind key _ _ scope rest)
      (if (string-eq key name)
        (match scope
          [(TcSpmdOuter) true]
          [(TcSpmdLocal) (tc-spmd-env-has-outer? (box-get rest) name)])
        (tc-spmd-env-has-outer? (box-get rest) name))]))

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
              (box (tc-spmd-env-set-local-class (box-get rest) name class)))])
        (TcSpmdEnvBind
          key
          ty
          old-class
          scope
          (box (tc-spmd-env-set-local-class (box-get rest) name class))))]))

(define (tc-spmd-env-pop [env : TcSpmdEnv] [count : i64]) : TcSpmdEnv
  (if (<= count 0)
    env
    (match env
      [(TcSpmdEnvNil) TcSpmdEnvNil]
      [(TcSpmdEnvBind _ _ _ _ rest)
        (tc-spmd-env-pop (box-get rest) (- count 1))])))

(define (tc-spmd-env-mark-outer [env : TcSpmdEnv]) : TcSpmdEnv
  (match env
    [(TcSpmdEnvNil) TcSpmdEnvNil]
    [(TcSpmdEnvBind name ty class _ rest)
      (TcSpmdEnvBind
        name
        ty
        class
        TcSpmdOuter
        (box (tc-spmd-env-mark-outer (box-get rest))))]))

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
            (box
              (tc-spmd-env-merge-classes
                (box-get left-rest)
                (box-get right-rest))))])]))

(define (tc-type-env-box-smoke?) : bool
  (let
    [env : TcTypeEnv
      (tc-bind-return-type
        (tc-bind
          (tc-bind (tc-push-region (tc-empty-env) "arena") "x" (AstTyI64))
          "x"
          (AstTyBool))
        (AstTyI64))]
    [cached : TcTypeEnv (tc-env-with-cache env)]
    (and
      (= (tc-env-cache-count cached) 4)
      (and
        (match (tc-lookup cached "x")
          [(OkTcType (AstTyBool)) true]
          [_ false])
        (and
          (match (tc-current-return-type env)
            [(OkTcType (AstTyI64)) true]
            [_ false])
          (and
            (match (tc-active-region env)
              [(TcSomeString region) (string-eq region "arena")]
              [_ false])
            (tc-lifetime-visible? env "arena")))))))

(define (tc-spmd-env-box-smoke?) : bool
  (let
    [env : TcTypeEnv
      (tc-bind (tc-bind (tc-empty-env) "x" (AstTyI64)) "flag" (AstTyBool))]
    [outer : TcSpmdEnv (tc-spmd-env-from-type-env env)]
    [local : TcSpmdEnv
      (tc-spmd-env-bind outer "lane" (AstTyI64) TcSpmdVarying TcSpmdLocal)]
    [updated : TcSpmdEnv
      (tc-spmd-env-set-local-class local "lane" TcSpmdUniform)]
    (and
      (match (tc-spmd-env-lookup updated "lane")
        [(TcSpmdFound (AstTyI64) (TcSpmdUniform) (TcSpmdLocal)) true]
        [_ false])
      (and
        (tc-spmd-env-has-local? updated "lane")
        (and
          (tc-spmd-env-has-outer? updated "x")
          (match (tc-spmd-env-lookup (tc-spmd-env-pop updated 1) "lane")
            [(TcSpmdMissing) true]
            [_ false]))))))

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
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam _ ty _)
            (ast-type-cons
              (tc-resolve-type ctx ty)
              (tc-param-type-list ctx rest))]))]))

(define (tc-type-list-ref [types : AstTypeList] [index : i64]) : ResultTcType
  (if (< index 0)
    (ErrTcType "typecheck: tuple index out of bounds")
    (match types
      [(AstTypeNil) (ErrTcType "typecheck: tuple index out of bounds")]
      [(AstTypeCons ty rest)
        (let
          [ty : AstType (box-get ty)]
          [rest : AstTypeList (box-get rest)]
          (if (= index 0)
            (OkTcType ty)
            (tc-type-list-ref rest (- index 1))))])))

(define (tc-expr-list-len [exprs : AstExprList]) : i64
  (match exprs
    [(AstExprNil) 0]
    [(AstExprCons _ rest)
      (let
        [rest : AstExprList (box-get rest)]
        (+ 1 (tc-expr-list-len rest)))]))

(define (tc-expr-list-types
  [ctx : TcContext]
  [env : TcTypeEnv]
  [exprs : AstExprList]) : ResultTcTypeList
  (match exprs
    [(AstExprNil) (OkTcTypeList AstTypeNil)]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (box-get expr)]
        [rest : AstExprList (box-get rest)]
        (match (tc-expr ctx env expr)
          [(OkTcType ty)
            (match (tc-expr-list-types ctx env rest)
              [(OkTcTypeList rest-types)
                (OkTcTypeList (ast-type-cons ty rest-types))]
              [(ErrTcTypeList message) (ErrTcTypeList message)])]
          [(ErrTcType message) (ErrTcTypeList message)]))]))

(define (tc-check-array-rest
  [ctx : TcContext]
  [env : TcTypeEnv]
  [exprs : AstExprList]
  [elem-ty : AstType]) : ResultTcUnit
  (match exprs
    [(AstExprNil) OkTcUnit]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (box-get expr)]
        [rest : AstExprList (box-get rest)]
        (match (tc-expr-with-expected-or-actual ctx env expr elem-ty)
          [(OkTcType ty)
            (match (tc-expect
              ty
              elem-ty
              "typecheck: array elements must have same type")
              [(OkTcUnit) (tc-check-array-rest ctx env rest elem-ty)]
              [(ErrTcUnit message) (ErrTcUnit message)])]
          [(ErrTcType message) (ErrTcUnit message)]))]))

(define (tc-bind-params
  [ctx : TcContext]
  [env : TcTypeEnv]
  [params : AstParamList]) : TcTypeEnv
  (match params
    [(AstParamNil) env]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam name ty _)
            (tc-bind-params
              ctx
              (tc-bind env name (tc-resolve-type ctx ty))
              rest)]))]))

(define (tc-bind-macro-params
  [ctx : TcContext]
  [env : TcTypeEnv]
  [params : AstMacroParamList]) : TcTypeEnv
  (match params
    [(AstMacroParamNil) env]
    [(AstMacroParamCons param rest)
      (let
        [rest : AstMacroParamList (box-get rest)]
        (match param
          [(AstMacroParam name _ variadic)
            (tc-bind-macro-params
              ctx
              (tc-bind
                env
                name
                (if variadic
                  (AstTyExprList)
                  (AstTyExpr)))
              rest)]))]))

(define (tc-ctfe-env-extend-macro-params
  [ctx : TcContext]
  [env : CtfeEnv]
  [params : AstMacroParamList]) : CtfeEnv
  (match params
    [(AstMacroParamNil) env]
    [(AstMacroParamCons param rest)
      (let
        [rest : AstMacroParamList (box-get rest)]
        (match param
          [(AstMacroParam name ty variadic)
            (tc-ctfe-env-extend-macro-params
              ctx
              (ctfe-env-extend
                env
                name
                (if variadic
                  (CtfeExprList AstExprNil)
                  (CtfeExpr (AstExprVar name) (tc-resolve-type ctx ty))))
              rest)]))]))

(define (tc-dispatch-isa-eq? [a : AstDispatchIsa] [b : AstDispatchIsa]) : bool
  (match a
    [(AstDispatchScalar)
      (match b
        [(AstDispatchScalar) true]
        [_ false])]
    [(AstDispatchAvx2)
      (match b
        [(AstDispatchAvx2) true]
        [_ false])]
    [(AstDispatchAvx512)
      (match b
        [(AstDispatchAvx512) true]
        [_ false])]))

(define (tc-dispatch-variant-list-contains-isa?
  [variants : AstDispatchVariantList]
  [isa : AstDispatchIsa]) : bool
  (match variants
    [(AstDispatchVariantNil) false]
    [(AstDispatchVariantCons variant rest)
      (let
        [rest : AstDispatchVariantList (box-get rest)]
        (match variant
          [(AstDispatchVariant found-isa _)
            (if (tc-dispatch-isa-eq? found-isa isa)
              true
              (tc-dispatch-variant-list-contains-isa? rest isa))]))]))

(define (tc-dispatch-variant-list-duplicate-isa?
  [variants : AstDispatchVariantList]) : bool
  (match variants
    [(AstDispatchVariantNil) false]
    [(AstDispatchVariantCons variant rest)
      (let
        [rest : AstDispatchVariantList (box-get rest)]
        (match variant
          [(AstDispatchVariant isa _)
            (or
              (tc-dispatch-variant-list-contains-isa? rest isa)
              (tc-dispatch-variant-list-duplicate-isa? rest))]))]))

(define (tc-dispatch-variant-list-scalar-count
  [variants : AstDispatchVariantList]) : i64
  (match variants
    [(AstDispatchVariantNil) 0]
    [(AstDispatchVariantCons variant rest)
      (let
        [rest : AstDispatchVariantList (box-get rest)]
        (match variant
          [(AstDispatchVariant isa _)
            (+
              (match isa
                [(AstDispatchScalar) 1]
                [_ 0])
              (tc-dispatch-variant-list-scalar-count rest))]))]))

(define (tc-dispatch-symbol-name [module : String] [name : String]) : String
  (if (and (> (string-length module) 0) (not (tc-name-qualified? name)))
    (compiler-symbol-module-key module name)
    name))

(define (tc-dispatch-variant-non-function-message [name : String]) : String
  (string-append "typecheck: defdispatch variant is not a function " name))

(define (tc-dispatch-variant-type
  [ctx : TcContext]
  [dispatch-name : String]
  [variant-name : String]) : ResultTcType
  (let
    [module : String (tc-context-module ctx)]
    [logical-name : String (tc-dispatch-symbol-name module dispatch-name)]
    [lookup-name : String (tc-dispatch-symbol-name module variant-name)]
    (if (string-eq lookup-name logical-name)
      (ErrTcType "typecheck: defdispatch cannot use itself as a variant")
      (match (compiler-symbols-lookup-value
        (tc-context-symbols ctx)
        lookup-name)
        [(SomeI64 handle)
          (let
            [kind : i64 (compiler-symbol-handle-kind handle)]
            (cond
              [(= kind (compiler-symbol-kind-defdispatch))
                (ErrTcType
                  "typecheck: defdispatch variant cannot be another dispatch")]
              [(or
                  (= kind (compiler-symbol-kind-function-define))
                  (= kind (compiler-symbol-kind-extern)))
                (match (compiler-program-decl-at-index
                  (tc-context-program ctx)
                  (compiler-symbol-handle-index handle))
                  [(OkAstDecl decl)
                    (match (tc-top-decl-type ctx decl)
                      [(OkTcType ty)
                        (match ty
                          [(AstTyFunc _ _) (OkTcType ty)]
                          [_
                            (ErrTcType
                              (tc-dispatch-variant-non-function-message
                                variant-name))])]
                      [(ErrTcType message) (ErrTcType message)])]
                  [(ErrAstDecl message) (ErrTcType message)])]
              [else
                (ErrTcType
                  (tc-dispatch-variant-non-function-message variant-name))]))]
        [(NoneI64)
          (ErrTcType
            (string-append
              "typecheck: unknown defdispatch variant "
              variant-name))]))))

(define (tc-dispatch-variant-signatures
  [ctx : TcContext]
  [dispatch-name : String]
  [variants : AstDispatchVariantList]
  [expected : AstMaybeType]) : ResultTcType
  (match variants
    [(AstDispatchVariantNil)
      (match expected
        [(AstSomeType ty) (OkTcType ty)]
        [(AstNoType) (ErrTcType "typecheck: defdispatch has no variants")])]
    [(AstDispatchVariantCons variant rest)
      (let
        [rest : AstDispatchVariantList (box-get rest)]
        (match variant
          [(AstDispatchVariant _ variant-name)
            (match (tc-dispatch-variant-type ctx dispatch-name variant-name)
              [(OkTcType ty)
                (match expected
                  [(AstNoType)
                    (tc-dispatch-variant-signatures
                      ctx
                      dispatch-name
                      rest
                      (AstSomeType ty))]
                  [(AstSomeType want)
                    (if (tc-type-eq ty want)
                      (tc-dispatch-variant-signatures
                        ctx
                        dispatch-name
                        rest
                        expected)
                      (ErrTcType
                        "typecheck: defdispatch variant signatures must match"))])]
              [(ErrTcType message) (ErrTcType message)])]))]))

(define (tc-dispatch-decl-type
  [ctx : TcContext]
  [name : String]
  [variants : AstDispatchVariantList]) : ResultTcType
  (if (!= (tc-dispatch-variant-list-scalar-count variants) 1)
    (ErrTcType "typecheck: defdispatch requires exactly one scalar variant")
    (if (tc-dispatch-variant-list-duplicate-isa? variants)
      (ErrTcType "typecheck: duplicate defdispatch ISA variant")
      (tc-dispatch-variant-signatures ctx name variants AstNoType))))

(define (tc-top-decl-type [ctx : TcContext] [decl : AstDecl]) : ResultTcType
  (match decl
    [(AstDeclDef _ maybe-ty expr-box)
      (let
        [expr : AstExpr (box-get expr-box)]
        (match maybe-ty
          [(AstSomeType ty) (OkTcType (tc-resolve-type ctx ty))]
          [(AstNoType)
            (match (ast-expr-unspan expr)
              [(AstExprLiteral lit) (OkTcType (tc-literal-type lit))]
              [(AstExprAnn _ ty) (OkTcType (tc-resolve-type ctx ty))]
              [_ (ErrTcType "typecheck: top-level value requires annotation")])]))]
    [(AstDeclDefFn _ params ret _)
      (OkTcType
        (ast-ty-func (tc-param-type-list ctx params) (tc-resolve-type ctx ret)))]
    [(AstDeclExtern _ _ ty) (OkTcType (tc-resolve-type ctx ty))]
    [(AstDeclDefDispatch name variants)
      (tc-dispatch-decl-type ctx name variants)]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tc-top-decl-type ctx inner))]
    [_ (ErrTcType "typecheck: declaration has no value type")]))

;; Like `tc-top-decl-type`, but infers an un-annotated top-level `define`'s type
;; from its initializer expression when it is neither a literal nor an annotated
;; expression. The `env` carries the bindings of all preceding declarations
;; (functions, enum/struct constructors, earlier globals), so a global such as
;; `(define result (factorial 5))` or `(define pair (Pair 10 11))` resolves
;; through the ordinary expression typechecker instead of demanding an
;; annotation. This mirrors the former Rust typechecker, whose first pass over
;; the declarations runs `check_expr(value)` for an un-annotated `Decl::Def`.
(define (tc-top-decl-type-with-env
  [ctx : TcContext]
  [env : TcTypeEnv]
  [decl : AstDecl]) : ResultTcType
  (match decl
    [(AstDeclDef _ maybe-ty expr-box)
      (let
        [expr : AstExpr (box-get expr-box)]
        (match maybe-ty
          [(AstSomeType ty) (OkTcType (tc-resolve-type ctx ty))]
          [(AstNoType)
            (match (ast-expr-unspan expr)
              [(AstExprLiteral lit) (OkTcType (tc-literal-type lit))]
              [(AstExprAnn _ ty) (OkTcType (tc-resolve-type ctx ty))]
              [_ (tc-expr ctx env expr)])]))]
    [_ (tc-top-decl-type ctx decl)]))

(define (tc-field-type-list [ctx : TcContext] [fields : AstFieldDefList]) : AstTypeList
  (match fields
    [(AstFieldDefNil) AstTypeNil]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef _ ty _)
            (ast-type-cons
              (tc-resolve-type ctx ty)
              (tc-field-type-list ctx rest))]))]))

(define (tc-tag-type-list-region [region : String] [types : AstTypeList]) : AstTypeList
  (match types
    [(AstTypeNil) AstTypeNil]
    [(AstTypeCons head tail)
      (let
        [head : AstType (box-get head)]
        [tail : AstTypeList (box-get tail)]
        (ast-type-cons
          (tc-tag-region region head)
          (tc-tag-type-list-region region tail)))]))

(define (tc-enum-variant-constructor-type
  [ctx : TcContext]
  [enum-name : String]
  [lifetimes : AstLifetimeList]
  [fields : AstTypeList]) : AstType
  (let
    [ret : AstType
      (match lifetimes
        [(AstLifetimeNil) (AstTyEnum enum-name)]
        [_ (AstTyEnumArgs enum-name lifetimes)])]
    (match fields
      [(AstTypeNil) ret]
      [_ (ast-ty-func (tc-resolve-type-list ctx fields) ret)])))

(define (tc-bind-enum-variants
  [ctx : TcContext]
  [env : TcTypeEnv]
  [enum-name : String]
  [variants : AstVariantDefList]) : ResultTcEnv
  (tc-bind-enum-variants-in-module ctx env "" enum-name AstLifetimeNil variants))

(define (tc-bind-enum-variants-in-module
  [ctx : TcContext]
  [env : TcTypeEnv]
  [module : String]
  [enum-name : String]
  [lifetimes : AstLifetimeList]
  [variants : AstVariantDefList]) : ResultTcEnv
  (match variants
    [(AstVariantDefNil) (OkTcEnv env)]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef name fields)
            (let
              [scoped-enum : String
                (compiler-symbol-module-key module enum-name)]
              (tc-bind-enum-variants-in-module
                ctx
                (tc-bind-module-name
                  env
                  module
                  name
                  (tc-enum-variant-constructor-type
                    ctx
                    scoped-enum
                    lifetimes
                    fields))
                module
                enum-name
                lifetimes
                rest))]))]))

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
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule next-module)
            (tc-build-top-env-list-in-module ctx rest env next-module)]
          [(AstDeclUnsafe inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (match inner
                [(AstDeclDefFn name _ _ _)
                  (match (tc-top-decl-type
                    (tc-context-with-module ctx module)
                    inner)
                    [(OkTcType ty)
                      (tc-build-top-env-list-in-module
                        ctx
                        rest
                        (tc-bind-module-name-unsafe env module name ty)
                        module)]
                    [(ErrTcType message) (ErrTcEnv message)])]
                [(AstDeclExtern name _ _)
                  (match (tc-top-decl-type
                    (tc-context-with-module ctx module)
                    inner)
                    [(OkTcType ty)
                      (tc-build-top-env-list-in-module
                        ctx
                        rest
                        (tc-bind-module-name-unsafe env module name ty)
                        module)]
                    [(ErrTcType message) (ErrTcEnv message)])]
                [_ (tc-build-top-env-list-in-module ctx rest env module)]))]
          [(AstDeclDef name _ _)
            (match (tc-top-decl-type-with-env
              (tc-context-with-module ctx module)
              env
              decl)
              [(OkTcType ty)
                (tc-build-top-env-list-in-module
                  ctx
                  rest
                  (tc-bind-module-name env module name ty)
                  module)]
              [(ErrTcType message) (ErrTcEnv message)])]
          [(AstDeclDefFn name _ _ _)
            (match (tc-top-decl-type (tc-context-with-module ctx module) decl)
              [(OkTcType ty)
                (tc-build-top-env-list-in-module
                  ctx
                  rest
                  (tc-bind-module-name env module name ty)
                  module)]
              [(ErrTcType message) (ErrTcEnv message)])]
          [(AstDeclDefDispatch name _)
            (match (tc-top-decl-type (tc-context-with-module ctx module) decl)
              [(OkTcType ty)
                (tc-build-top-env-list-in-module
                  ctx
                  rest
                  (tc-bind-module-name env module name ty)
                  module)]
              [(ErrTcType message) (ErrTcEnv message)])]
          [(AstDeclDefMacro _ _ _ _)
            (tc-build-top-env-list-in-module ctx rest env module)]
          [(AstDeclExtern name _ _)
            (match (tc-top-decl-type (tc-context-with-module ctx module) decl)
              [(OkTcType ty)
                (tc-build-top-env-list-in-module
                  ctx
                  rest
                  (tc-bind-module-name env module name ty)
                  module)]
              [(ErrTcType message) (ErrTcEnv message)])]
          [(AstDeclDefEnum name variants)
            (match (tc-bind-enum-variants-in-module
              (tc-context-with-module ctx module)
              env
              module
              name
              AstLifetimeNil
              variants)
              [(OkTcEnv next-env)
                (tc-build-top-env-list-in-module ctx rest next-env module)]
              [(ErrTcEnv message) (ErrTcEnv message)])]
          [(AstDeclDefEnumLifetimes name lifetimes variants)
            (match (tc-bind-enum-variants-in-module
              (tc-context-with-module ctx module)
              env
              module
              name
              lifetimes
              variants)
              [(OkTcEnv next-env)
                (tc-build-top-env-list-in-module ctx rest next-env module)]
              [(ErrTcEnv message) (ErrTcEnv message)])]
          [(AstDeclDefStruct name _ _ fields)
            (let
              [scoped-name : String (compiler-symbol-module-key module name)]
              (tc-build-top-env-list-in-module
                ctx
                rest
                (tc-bind-module-name
                  env
                  module
                  name
                  (ast-ty-func
                    (tc-field-type-list
                      (tc-context-with-module ctx module)
                      fields)
                    (AstTyStruct scoped-name)))
                module))]
          [(AstDeclDefStructLifetimes name lifetimes _ _ fields)
            (let
              [scoped-name : String (compiler-symbol-module-key module name)]
              (tc-build-top-env-list-in-module
                ctx
                rest
                (tc-bind-module-name
                  env
                  module
                  name
                  (ast-ty-func
                    (tc-field-type-list
                      (tc-context-with-module ctx module)
                      fields)
                    (AstTyStructArgs scoped-name lifetimes)))
                module))]
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (match template
                [(AstDeclDef name _ _)
                  (match (tc-top-decl-type-with-env
                    (tc-context-with-module ctx module)
                    env
                    template)
                    [(OkTcType ty)
                      (tc-build-top-env-list-in-module
                        ctx
                        rest
                        (tc-bind-module-name env module name ty)
                        module)]
                    [(ErrTcType message) (ErrTcEnv message)])]
                [(AstDeclDefFn name _ _ _)
                  (match (tc-top-decl-type
                    (tc-context-with-module ctx module)
                    template)
                    [(OkTcType ty)
                      (tc-build-top-env-list-in-module
                        ctx
                        rest
                        (tc-bind-module-name env module name ty)
                        module)]
                    [(ErrTcType message) (ErrTcEnv message)])]
                [(AstDeclDefDispatch name _)
                  (match (tc-top-decl-type
                    (tc-context-with-module ctx module)
                    template)
                    [(OkTcType ty)
                      (tc-build-top-env-list-in-module
                        ctx
                        rest
                        (tc-bind-module-name env module name ty)
                        module)]
                    [(ErrTcType message) (ErrTcEnv message)])]
                [(AstDeclExtern name _ _)
                  (match (tc-top-decl-type
                    (tc-context-with-module ctx module)
                    template)
                    [(OkTcType ty)
                      (tc-build-top-env-list-in-module
                        ctx
                        rest
                        (tc-bind-module-name env module name ty)
                        module)]
                    [(ErrTcType message) (ErrTcEnv message)])]
                [(AstDeclDefEnum name variants)
                  (match (tc-bind-enum-variants-in-module
                    (tc-context-with-module ctx module)
                    env
                    module
                    name
                    AstLifetimeNil
                    variants)
                    [(OkTcEnv next-env)
                      (tc-build-top-env-list-in-module ctx rest next-env module)]
                    [(ErrTcEnv message) (ErrTcEnv message)])]
                [(AstDeclDefEnumLifetimes name lifetimes variants)
                  (match (tc-bind-enum-variants-in-module
                    (tc-context-with-module ctx module)
                    env
                    module
                    name
                    lifetimes
                    variants)
                    [(OkTcEnv next-env)
                      (tc-build-top-env-list-in-module ctx rest next-env module)]
                    [(ErrTcEnv message) (ErrTcEnv message)])]
                [(AstDeclDefStruct name _ _ fields)
                  (let
                    [scoped-name : String
                      (compiler-symbol-module-key module name)]
                    (tc-build-top-env-list-in-module
                      ctx
                      rest
                      (tc-bind-module-name
                        env
                        module
                        name
                        (ast-ty-func
                          (tc-field-type-list
                            (tc-context-with-module ctx module)
                            fields)
                          (AstTyStruct scoped-name)))
                      module))]
                [(AstDeclDefStructLifetimes name lifetimes _ _ fields)
                  (let
                    [scoped-name : String
                      (compiler-symbol-module-key module name)]
                    (tc-build-top-env-list-in-module
                      ctx
                      rest
                      (tc-bind-module-name
                        env
                        module
                        name
                        (ast-ty-func
                          (tc-field-type-list
                            (tc-context-with-module ctx module)
                            fields)
                          (AstTyStructArgs scoped-name lifetimes)))
                      module))]
                [_ (tc-build-top-env-list-in-module ctx rest env module)]))]
          [(AstDeclImport _)
            (tc-build-top-env-list-in-module ctx rest env module)]
          [(AstDeclIncludeStr _ _)
            (tc-build-top-env-list-in-module ctx rest env module)]
          [(AstDeclExport _)
            (tc-build-top-env-list-in-module ctx rest env module)]
          [(AstDeclTest _ _ _)
            (tc-build-top-env-list-in-module ctx rest env module)]))]))

(define (tc-bind-enum-variant-aliases
  [ctx : TcContext]
  [env : TcTypeEnv]
  [alias : String]
  [enum-name : String]
  [lifetimes : AstLifetimeList]
  [variants : AstVariantDefList]) : TcTypeEnv
  (match variants
    [(AstVariantDefNil) env]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef name fields)
            (tc-bind-enum-variant-aliases
              ctx
              (tc-bind
                env
                (compiler-symbol-module-key alias name)
                (tc-enum-variant-constructor-type
                  ctx
                  enum-name
                  lifetimes
                  fields))
              alias
              enum-name
              lifetimes
              rest)]))]))

(define (tc-bind-import-alias-decl-in-module
  [ctx : TcContext]
  [env : TcTypeEnv]
  [alias : String]
  [module : String]
  [decl : AstDecl]) : ResultTcEnv
  (match decl
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (match inner
          [(AstDeclDefFn name _ _ _)
            (match (tc-top-decl-type (tc-context-with-module ctx module) inner)
              [(OkTcType ty)
                (OkTcEnv
                  (tc-bind-unsafe
                    env
                    (compiler-symbol-module-key alias name)
                    ty))]
              [(ErrTcType message) (ErrTcEnv message)])]
          [(AstDeclExtern name _ _)
            (match (tc-top-decl-type (tc-context-with-module ctx module) inner)
              [(OkTcType ty)
                (OkTcEnv
                  (tc-bind-unsafe
                    env
                    (compiler-symbol-module-key alias name)
                    ty))]
              [(ErrTcType message) (ErrTcEnv message)])]
          [_ (OkTcEnv env)]))]
    [(AstDeclDef name _ _)
      (match (tc-top-decl-type (tc-context-with-module ctx module) decl)
        [(OkTcType ty)
          (OkTcEnv (tc-bind env (compiler-symbol-module-key alias name) ty))]
        [(ErrTcType message) (ErrTcEnv message)])]
    [(AstDeclDefFn name _ _ _)
      (match (tc-top-decl-type (tc-context-with-module ctx module) decl)
        [(OkTcType ty)
          (OkTcEnv (tc-bind env (compiler-symbol-module-key alias name) ty))]
        [(ErrTcType message) (ErrTcEnv message)])]
    [(AstDeclDefDispatch name _)
      (match (tc-top-decl-type (tc-context-with-module ctx module) decl)
        [(OkTcType ty)
          (OkTcEnv (tc-bind env (compiler-symbol-module-key alias name) ty))]
        [(ErrTcType message) (ErrTcEnv message)])]
    [(AstDeclExtern name _ _)
      (match (tc-top-decl-type (tc-context-with-module ctx module) decl)
        [(OkTcType ty)
          (OkTcEnv (tc-bind env (compiler-symbol-module-key alias name) ty))]
        [(ErrTcType message) (ErrTcEnv message)])]
    [(AstDeclDefEnum name variants)
      (OkTcEnv
        (tc-bind-enum-variant-aliases
          (tc-context-with-module ctx module)
          env
          alias
          (compiler-symbol-module-key module name)
          AstLifetimeNil
          variants))]
    [(AstDeclDefEnumLifetimes name lifetimes variants)
      (OkTcEnv
        (tc-bind-enum-variant-aliases
          (tc-context-with-module ctx module)
          env
          alias
          (compiler-symbol-module-key module name)
          lifetimes
          variants))]
    [(AstDeclDefStruct name _ _ fields)
      (OkTcEnv
        (tc-bind
          env
          (compiler-symbol-module-key alias name)
          (ast-ty-func
            (tc-field-type-list (tc-context-with-module ctx module) fields)
            (AstTyStruct (compiler-symbol-module-key module name)))))]
    [(AstDeclDefStructLifetimes name lifetimes _ _ fields)
      (OkTcEnv
        (tc-bind
          env
          (compiler-symbol-module-key alias name)
          (ast-ty-func
            (tc-field-type-list (tc-context-with-module ctx module) fields)
            (AstTyStructArgs (compiler-symbol-module-key module name) lifetimes))))]
    [(AstDeclComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (tc-bind-import-alias-decl-in-module ctx env alias module template))]
    [_ (OkTcEnv env)]))

(define (tc-bind-import-alias-module-list
  [ctx : TcContext]
  [decls : AstDeclList]
  [env : TcTypeEnv]
  [target-module : String]
  [alias : String]
  [module : String]) : ResultTcEnv
  (match decls
    [(AstDeclNil) (OkTcEnv env)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule next-module)
            (tc-bind-import-alias-module-list
              ctx
              rest
              env
              target-module
              alias
              next-module)]
          [(AstDeclImport _)
            (tc-bind-import-alias-module-list
              ctx
              rest
              env
              target-module
              alias
              module)]
          [(AstDeclIncludeStr _ _)
            (tc-bind-import-alias-module-list
              ctx
              rest
              env
              target-module
              alias
              module)]
          [(AstDeclExport _)
            (tc-bind-import-alias-module-list
              ctx
              rest
              env
              target-module
              alias
              module)]
          [(AstDeclTest _ _ _)
            (tc-bind-import-alias-module-list
              ctx
              rest
              env
              target-module
              alias
              module)]
          [_
            (if (string-eq module target-module)
              (match (tc-bind-import-alias-decl-in-module
                ctx
                env
                alias
                module
                decl)
                [(OkTcEnv next-env)
                  (tc-bind-import-alias-module-list
                    ctx
                    rest
                    next-env
                    target-module
                    alias
                    module)]
                [(ErrTcEnv message) (ErrTcEnv message)])
              (tc-bind-import-alias-module-list
                ctx
                rest
                env
                target-module
                alias
                module))]))]))

(define (tc-bind-import-alias-module
  [ctx : TcContext]
  [decls : AstDeclList]
  [env : TcTypeEnv]
  [target-module : String]
  [alias : String]) : ResultTcEnv
  (tc-bind-import-alias-module-list ctx decls env target-module alias ""))

(define (tc-build-top-env-aliases-list
  [ctx : TcContext]
  [all-decls : AstDeclList]
  [decls : AstDeclList]
  [env : TcTypeEnv]) : ResultTcEnv
  (match decls
    [(AstDeclNil) (OkTcEnv env)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport
              (AstImportSpec
                _
                (AstSomeModuleName target-module)
                (AstSomeImportAlias alias)))
            (match (tc-bind-import-alias-module
              ctx
              all-decls
              env
              target-module
              alias)
              [(OkTcEnv next-env)
                (tc-build-top-env-aliases-list ctx all-decls rest next-env)]
              [(ErrTcEnv message) (ErrTcEnv message)])]
          [_ (tc-build-top-env-aliases-list ctx all-decls rest env)]))]))

(define (tc-build-top-env [ctx : TcContext] [program : AstProgram]) : ResultTcEnv
  (begin
    (tc-nominal-owner-cache-reset!)
    (match program
      [(AstProgram decls-box)
        (let
          [decls : AstDeclList (box-get decls-box)]
          (match (tc-build-top-env-list ctx decls (tc-default-env))
            [(OkTcEnv env)
              (match (tc-build-top-env-aliases-list ctx decls decls env)
                [(OkTcEnv aliases) (OkTcEnv (tc-env-with-cache aliases))]
                [(ErrTcEnv message) (ErrTcEnv message)])]
            [(ErrTcEnv message) (ErrTcEnv message)]))])))

(define (tc-bind-enum-variants-local
  [ctx : TcContext]
  [env : TcTypeEnv]
  [enum-name : String]
  [scoped-enum : String]
  [lifetimes : AstLifetimeList]
  [variants : AstVariantDefList]) : TcTypeEnv
  (match variants
    [(AstVariantDefNil) env]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef name fields)
            (tc-bind-enum-variants-local
              ctx
              (tc-bind
                env
                name
                (tc-enum-variant-constructor-type
                  ctx
                  scoped-enum
                  lifetimes
                  fields))
              enum-name
              scoped-enum
              lifetimes
              rest)]))]))

(define (tc-module-local-env-add-decl
  [ctx : TcContext]
  [env : TcTypeEnv]
  [module : String]
  [decl : AstDecl]) : ResultTcEnv
  (match decl
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (match inner
          [(AstDeclDefFn name _ _ _)
            (match (tc-top-decl-type ctx inner)
              [(OkTcType ty) (OkTcEnv (tc-bind-unsafe env name ty))]
              [(ErrTcType message) (ErrTcEnv message)])]
          [(AstDeclExtern name _ _)
            (match (tc-top-decl-type ctx inner)
              [(OkTcType ty) (OkTcEnv (tc-bind-unsafe env name ty))]
              [(ErrTcType message) (ErrTcEnv message)])]
          [_ (OkTcEnv env)]))]
    [(AstDeclDef name _ _)
      (match (tc-top-decl-type-with-env ctx env decl)
        [(OkTcType ty) (OkTcEnv (tc-bind env name ty))]
        [(ErrTcType message) (ErrTcEnv message)])]
    [(AstDeclDefFn name _ _ _)
      (match (tc-top-decl-type ctx decl)
        [(OkTcType ty) (OkTcEnv (tc-bind env name ty))]
        [(ErrTcType message) (ErrTcEnv message)])]
    [(AstDeclDefDispatch name _)
      (match (tc-top-decl-type ctx decl)
        [(OkTcType ty) (OkTcEnv (tc-bind env name ty))]
        [(ErrTcType message) (ErrTcEnv message)])]
    [(AstDeclExtern name _ _)
      (match (tc-top-decl-type ctx decl)
        [(OkTcType ty) (OkTcEnv (tc-bind env name ty))]
        [(ErrTcType message) (ErrTcEnv message)])]
    [(AstDeclDefEnum name variants)
      (OkTcEnv
        (tc-bind-enum-variants-local
          ctx
          env
          name
          (compiler-symbol-module-key module name)
          AstLifetimeNil
          variants))]
    [(AstDeclDefEnumLifetimes name lifetimes variants)
      (OkTcEnv
        (tc-bind-enum-variants-local
          ctx
          env
          name
          (compiler-symbol-module-key module name)
          lifetimes
          variants))]
    [(AstDeclDefStruct name _ _ fields)
      (OkTcEnv
        (tc-bind
          env
          name
          (ast-ty-func
            (tc-field-type-list ctx fields)
            (AstTyStruct (compiler-symbol-module-key module name)))))]
    [(AstDeclDefStructLifetimes name lifetimes _ _ fields)
      (OkTcEnv
        (tc-bind
          env
          name
          (ast-ty-func
            (tc-field-type-list ctx fields)
            (AstTyStructArgs (compiler-symbol-module-key module name) lifetimes))))]
    [(AstDeclComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (tc-module-local-env-add-decl ctx env module template))]
    [_ (OkTcEnv env)]))

(define (tc-module-local-env-list
  [ctx : TcContext]
  [decls : AstDeclList]
  [env : TcTypeEnv]
  [target-module : String]
  [module : String]) : ResultTcEnv
  (match decls
    [(AstDeclNil) (OkTcEnv env)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule next-module)
            (tc-module-local-env-list ctx rest env target-module next-module)]
          [_
            (if (string-eq module target-module)
              (match (tc-module-local-env-add-decl ctx env target-module decl)
                [(OkTcEnv next-env)
                  (tc-module-local-env-list
                    ctx
                    rest
                    next-env
                    target-module
                    module)]
                [(ErrTcEnv message) (ErrTcEnv message)])
              (tc-module-local-env-list ctx rest env target-module module))]))]))

(define (tc-module-local-env
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [module : String]) : ResultTcEnv
  (if (string-eq module "")
    (OkTcEnv top-env)
    (match (tc-context-program ctx)
      [(AstProgram decls-box)
        (let
          [decls : AstDeclList (box-get decls-box)]
          (tc-module-local-env-list
            (tc-context-with-module ctx module)
            decls
            top-env
            module
            ""))])))

(define (tc-module-local-env-cache-lookup
  [cache : TcModuleLocalEnvCache]
  [module : String]) : TcMaybeTypeEnv
  (match cache
    [(TcModuleLocalEnvNil) (TcNoTypeEnv)]
    [(TcModuleLocalEnvCons cached-module env rest)
      (if (string-eq cached-module module)
        (TcSomeTypeEnv env)
        (tc-module-local-env-cache-lookup (box-get rest) module))]))

(define (tc-module-local-env-cached
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [module : String]
  [cache : TcModuleLocalEnvCache]) : ResultTcModuleLocalEnv
  (if (string-eq module "")
    (OkTcModuleLocalEnv top-env cache)
    (match (tc-module-local-env-cache-lookup cache module)
      [(TcSomeTypeEnv env) (OkTcModuleLocalEnv env cache)]
      [(TcNoTypeEnv)
        (match (tc-module-local-env ctx top-env module)
          [(OkTcEnv env)
            (OkTcModuleLocalEnv
              env
              (TcModuleLocalEnvCons module env (box cache)))]
          [(ErrTcEnv message) (ErrTcModuleLocalEnv message)])])))

(define (tc-expect [actual : AstType] [expected : AstType] [message : String]) : ResultTcUnit
  (if (tc-type-compatible? expected actual)
    OkTcUnit
    (ErrTcUnit message)))

(define (tc-contextual-result-type [expected : AstType] [actual : AstType]) : AstType
  (if (tc-type-contains-any-region actual)
    actual
    expected))

(define (tc-float-literal-expr? [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-float-literal-expr? inner))]
    [(AstExprLiteral lit)
      (match lit
        [(AstLitFloat _) true]
        [_ false])]
    [_ false]))

(define (tc-expr-list-with-expected-elements
  [ctx : TcContext]
  [env : TcTypeEnv]
  [exprs : AstExprList]
  [elem-ty : AstType]) : ResultTcUnit
  (match exprs
    [(AstExprNil) OkTcUnit]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (box-get expr)]
        [rest : AstExprList (box-get rest)]
        (match (tc-expr-with-expected-or-actual ctx env expr elem-ty)
          [(OkTcType got)
            (match (tc-expect
              got
              elem-ty
              "typecheck: array elements must have same type")
              [(OkTcUnit)
                (tc-expr-list-with-expected-elements ctx env rest elem-ty)]
              [(ErrTcUnit message) (ErrTcUnit message)])]
          [(ErrTcType message) (ErrTcUnit message)]))]))

(define (tc-expr-array-with-expected-or-actual
  [ctx : TcContext]
  [env : TcTypeEnv]
  [exprs : AstExprList]
  [elem-ty : AstType]
  [expected-len : i64]) : ResultTcType
  (if (= (tc-expr-list-len exprs) expected-len)
    (match (tc-ensure-cleanup-resource-not-stored-list env exprs)
      [(OkTcUnit)
        (match (tc-expr-list-with-expected-elements ctx env exprs elem-ty)
          [(OkTcUnit) (OkTcType (ast-ty-array elem-ty expected-len))]
          [(ErrTcUnit message) (ErrTcType message)])]
      [(ErrTcUnit message) (ErrTcType message)])
    (tc-expr ctx env (AstExprArray exprs))))

(define (tc-expr-if-with-expected-or-actual
  [ctx : TcContext]
  [env : TcTypeEnv]
  [cond : AstExpr]
  [then-branch : AstExpr]
  [else-branch : AstExpr]
  [expected : AstType]) : ResultTcType
  (match (tc-expr ctx env cond)
    [(OkTcType cond-ty)
      (match (tc-expect
        cond-ty
        (AstTyBool)
        "typecheck: if condition must be bool")
        [(OkTcUnit)
          (match (tc-expr-with-expected-or-actual ctx env then-branch expected)
            [(OkTcType then-ty)
              (match (tc-expr-with-expected-or-actual
                ctx
                env
                else-branch
                expected)
                [(OkTcType else-ty)
                  (if (and
                    (tc-type-compatible? expected then-ty)
                    (tc-type-compatible? expected else-ty))
                    (OkTcType expected)
                    (tc-merge-branch-type then-ty else-ty))]
                [(ErrTcType message) (ErrTcType message)])]
            [(ErrTcType message) (ErrTcType message)])]
        [(ErrTcUnit message) (ErrTcType message)])]
    [(ErrTcType message) (ErrTcType message)]))

(define (tc-type-list-len [types : AstTypeList]) : i64
  (match types
    [(AstTypeNil) 0]
    [(AstTypeCons _ rest)
      (let
        [rest : AstTypeList (box-get rest)]
        (+ 1 (tc-type-list-len rest)))]))

;; Flow each tuple element into its expected element type so contextual
;; literals (e.g. f32 floats) resolve against the tuple's declared element
;; type instead of their default. Returns the resolved element types.
(define (tc-check-tuple-elements-with-expected
  [ctx : TcContext]
  [env : TcTypeEnv]
  [exprs : AstExprList]
  [types : AstTypeList]) : ResultTcTypeList
  (match exprs
    [(AstExprNil)
      (match types
        [(AstTypeNil) (OkTcTypeList AstTypeNil)]
        [_ (ErrTcTypeList "typecheck: tuple element type mismatch")])]
    [(AstExprCons expr rest-exprs)
      (let
        [expr : AstExpr (box-get expr)]
        [rest-exprs : AstExprList (box-get rest-exprs)]
        (match types
          [(AstTypeCons want rest-types)
            (let
              [want : AstType (box-get want)]
              [rest-types : AstTypeList (box-get rest-types)]
              (match (tc-expr-with-expected-or-actual ctx env expr want)
                [(OkTcType got)
                  (match (tc-expect
                    got
                    want
                    "typecheck: tuple element type mismatch")
                    [(OkTcUnit)
                      (match (tc-check-tuple-elements-with-expected
                        ctx
                        env
                        rest-exprs
                        rest-types)
                        [(OkTcTypeList rest-result)
                          (OkTcTypeList
                            (ast-type-cons
                              (tc-contextual-result-type want got)
                              rest-result))]
                        [(ErrTcTypeList message) (ErrTcTypeList message)])]
                    [(ErrTcUnit message) (ErrTcTypeList message)])]
                [(ErrTcType message) (ErrTcTypeList message)]))]
          [(AstTypeNil)
            (ErrTcTypeList "typecheck: tuple element type mismatch")]))]))

(define (tc-expr-tuple-with-expected-or-actual
  [ctx : TcContext]
  [env : TcTypeEnv]
  [exprs : AstExprList]
  [expected-elems : AstTypeList]) : ResultTcType
  (if (= (tc-expr-list-len exprs) (tc-type-list-len expected-elems))
    (match (tc-ensure-cleanup-resource-not-stored-list env exprs)
      [(OkTcUnit)
        (match (tc-check-tuple-elements-with-expected
          ctx
          env
          exprs
          expected-elems)
          [(OkTcTypeList result-elems) (OkTcType (AstTyTuple result-elems))]
          [(ErrTcTypeList message) (ErrTcType message)])]
      [(ErrTcUnit message) (ErrTcType message)])
    (tc-expr ctx env (AstExprTuple exprs))))

;; Flow the expected type into a begin's final expression so a contextual
;; literal in tail position resolves against it; non-final expressions keep
;; the non-contextual policy (any type is allowed).
(define (tc-begin-list-with-expected
  [ctx : TcContext]
  [env : TcTypeEnv]
  [exprs : AstExprList]
  [expected : AstType]) : ResultTcType
  (match exprs
    [(AstExprNil) (OkTcType (AstTyUnit))]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (box-get expr)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil) (tc-expr-with-expected-or-actual ctx env expr expected)]
          [_
            (match (tc-expr ctx env expr)
              [(OkTcType _) (tc-begin-list-with-expected ctx env rest expected)]
              [(ErrTcType message) (ErrTcType message)])]))]))

(define (tc-expr-with-expected-or-actual
  [ctx : TcContext]
  [env : TcTypeEnv]
  [expr : AstExpr]
  [expected : AstType]) : ResultTcType
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-with-expected-or-actual ctx env inner expected))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [then-branch : AstExpr (box-get then-branch-box)]
        [else-branch : AstExpr (box-get else-branch-box)]
        (tc-expr-if-with-expected-or-actual
          ctx
          env
          cond
          then-branch
          else-branch
          expected))]
    [(AstExprArray exprs)
      (match (tc-type-strip-region expected)
        [(AstTyArray elem-ty len)
          (tc-expr-array-with-expected-or-actual
            ctx
            env
            exprs
            (box-get elem-ty)
            len)]
        [_ (tc-expr ctx env expr)])]
    [(AstExprTuple exprs)
      (match (tc-type-strip-region expected)
        [(AstTyTuple expected-elems)
          (tc-expr-tuple-with-expected-or-actual ctx env exprs expected-elems)]
        [_ (tc-expr ctx env expr)])]
    [(AstExprBegin exprs) (tc-begin-list-with-expected ctx env exprs expected)]
    [_
      (if (and
        (tc-type-eq (tc-type-strip-region expected) (AstTyF32))
        (tc-float-literal-expr? expr))
        (OkTcType expected)
        (match (tc-expr ctx env expr)
          [(OkTcType actual)
            (if (tc-type-compatible? expected actual)
              (OkTcType (tc-contextual-result-type expected actual))
              (OkTcType actual))]
          [(ErrTcType message) (ErrTcType message)]))]))

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
    [(AstBinShl) (tc-shift-binop-type left right)]
    [(AstBinShr) (tc-shift-binop-type left right)]
    [_ (tc-integer-binop-type left right)]))

(define (tc-integer-binop-type [left : AstType] [right : AstType]) : ResultTcType
  (if (and (tc-integer-type? left) (tc-type-eq left right))
    (OkTcType left)
    (ErrTcType "typecheck: integer operator expects matching integer operands")))

(define (tc-arithmetic-binop-type [left : AstType] [right : AstType]) : ResultTcType
  (if (and (tc-float-type? left) (tc-type-eq left right))
    (OkTcType left)
    (tc-integer-binop-type left right)))

(define (tc-shift-binop-type [left : AstType] [right : AstType]) : ResultTcType
  (if (tc-integer-type? left)
    (if (tc-integer-type? right)
      (OkTcType left)
      (ErrTcType "typecheck: shift count must be integer"))
    (ErrTcType "typecheck: shift left operand must be integer")))

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
  (cond
    [(string-eq name "string-length") true]
    [(string-eq name "length") true]
    [(string-eq name "string-eq") true]
    [(string-eq name "string=?") true]
    [(string-eq name "string->int") true]
    [(string-eq name "substring") true]
    [(string-eq name "string-slice") true]
    [(string-eq name "string-append") true]
    [(string-eq name "string-concat") true]
    [else false]))

(define (tc-default-builtin-unshadowed-scan? [env : TcTypeEnv] [name : String]) : bool
  (match env
    [(TcTypeNil) false]
    [(TcTypeCache _ _ _ shadows _)
      (not (string-i64-map-contains? shadows name))]
    [(TcTypeBind key _ rest)
      (if (string-eq key name)
        false
        (if (string-eq key (tc-default-boundary-name))
          true
          (tc-default-builtin-unshadowed-scan? (box-get rest) name)))]))

(define (tc-default-builtin-unshadowed? [env : TcTypeEnv] [name : String]) : bool
  (if (tc-region-arg-builtin-name? name)
    (tc-default-builtin-unshadowed-scan? env name)
    false))

(define (tc-constructor-name? [ctx : TcContext] [name : String]) : bool
  (match ctx
    [(TcContext _ symbols registries module)
      (let
        [lookup-name : String
          (if (and (> (string-length module) 0) (not (tc-name-qualified? name)))
            (compiler-symbol-module-key module name)
            name)]
        (match (compiler-symbols-lookup-type symbols lookup-name)
          [(SomeI64 handle)
            (if (=
              (compiler-symbol-handle-kind handle)
              (compiler-symbol-kind-defstruct))
              true
              (match (compiler-registries-lookup-variant registries lookup-name)
                [(SomeI64 _) true]
                [(NoneI64) false]))]
          [(NoneI64)
            (match (compiler-registries-lookup-variant registries lookup-name)
              [(SomeI64 _) true]
              [(NoneI64) false])]))]))

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

(define (tc-nullary-variant-call-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [func : AstExpr]
  [enum-name : String]
  [ret : AstType]) : ResultTcType
  (match (tc-expr-var-name func)
    [(TcSomeString name)
      (match (compiler-registries-lookup-variant
        (tc-context-registries ctx)
        (tc-variant-name-for-enum enum-name name))
        [(SomeI64 handle)
          (let
            [lookup-name : String (tc-variant-name-for-enum enum-name name)]
            (match (tc-qualified-variant-visible-ok ctx lookup-name)
              [(OkTcUnit)
                (match (tc-variant-owner-name ctx handle)
                  [(OkTcString owner)
                    (if (string-eq owner enum-name)
                      (match (compiler-registries-variant-fields-indexed
                        (tc-context-symbols ctx)
                        handle)
                        [(OkAstTypeList fields)
                          (match fields
                            [(AstTypeNil)
                              (OkTcType (tc-tag-active-region env ret))]
                            [_ (ErrTcType "typecheck: arity mismatch")])]
                        [(ErrAstTypeList message) (ErrTcType message)])
                      (ErrTcType "typecheck: call target is not a function"))]
                  [(ErrTcString message) (ErrTcType message)])]
              [(ErrTcUnit message) (ErrTcType message)]))]
        [(NoneI64)
          (if (tc-name-qualified? name)
            (OkTcType (tc-tag-active-region env ret))
            (ErrTcType "typecheck: call target is not a function"))])]
    [(TcNoString) (ErrTcType "typecheck: call target is not a function")]))

(define (tc-call-region-args-allowed-for-func
  [ctx : TcContext]
  [env : TcTypeEnv]
  [func : AstExpr]) : bool
  (match (tc-expr-var-name func)
    [(TcSomeString name) (tc-call-allows-region-args? ctx env name)]
    [(TcNoString) false]))

(define (tc-call-constructor-target-for-func
  [ctx : TcContext]
  [env : TcTypeEnv]
  [func : AstExpr]
  [params : AstTypeList]
  [ret : AstType]) : AstMaybeType
  (match (tc-expr-var-name func)
    [(TcSomeString name)
      (if (tc-constructor-name? ctx name)
        (AstSomeType (tc-constructor-target-type env params ret))
        (AstNoType))]
    [(TcNoString) (AstNoType)]))

(define (tc-lifetime-constructor-ret? [ret : AstType]) : bool
  (match ret
    [(AstTyStructArgs _ lifetimes) (> (tc-lifetime-list-count lifetimes) 0)]
    [(AstTyEnumArgs _ lifetimes) (> (tc-lifetime-list-count lifetimes) 0)]
    [_ false]))

(define (tc-call-lifetime-constructor-for-func?
  [ctx : TcContext]
  [func : AstExpr]
  [ret : AstType]) : bool
  (if (tc-lifetime-constructor-ret? ret)
    (match (tc-expr-var-name func)
      [(TcSomeString name) (tc-constructor-name? ctx name)]
      [(TcNoString) false])
    false))

(define (tc-lifetime-subst-type-list
  [subst : TcLifetimeSubst]
  [types : AstTypeList]) : AstTypeList
  (match types
    [(AstTypeNil) AstTypeNil]
    [(AstTypeCons head tail)
      (let
        [head : AstType (box-get head)]
        [tail : AstTypeList (box-get tail)]
        (ast-type-cons
          (tc-lifetime-subst-type subst head)
          (tc-lifetime-subst-type-list subst tail)))]))

(define (tc-lifetime-subst-type [subst : TcLifetimeSubst] [ty : AstType]) : AstType
  (match ty
    [(AstTyFunc args ret)
      (ast-ty-func
        (tc-lifetime-subst-type-list subst args)
        (tc-lifetime-subst-type subst (box-get ret)))]
    [(AstTyTuple elems) (AstTyTuple (tc-lifetime-subst-type-list subst elems))]
    [(AstTyArray elem len)
      (ast-ty-array (tc-lifetime-subst-type subst (box-get elem)) len)]
    [(AstTyDynArray elem)
      (ast-ty-dyn-array (tc-lifetime-subst-type subst (box-get elem)))]
    [(AstTyBox elem) (ast-ty-box (tc-lifetime-subst-type subst (box-get elem)))]
    [(AstTyPtr elem) (ast-ty-ptr (tc-lifetime-subst-type subst (box-get elem)))]
    [(AstTyMutPtr elem)
      (ast-ty-mut-ptr (tc-lifetime-subst-type subst (box-get elem)))]
    [(AstTyRef lifetime inner)
      (ast-ty-ref
        (tc-lifetime-subst-apply subst lifetime)
        (tc-lifetime-subst-type subst (box-get inner)))]
    [(AstTyMutRef lifetime inner)
      (ast-ty-mut-ref
        (tc-lifetime-subst-apply subst lifetime)
        (tc-lifetime-subst-type subst (box-get inner)))]
    [(AstTyRegion region inner)
      (ast-ty-region region (tc-lifetime-subst-type subst (box-get inner)))]
    [(AstTyEnumArgs name lifetimes)
      (AstTyEnumArgs name (tc-lifetime-subst-list subst lifetimes))]
    [(AstTyStructArgs name lifetimes)
      (AstTyStructArgs name (tc-lifetime-subst-list subst lifetimes))]
    [(AstTyVarArgs name lifetimes)
      (AstTyVarArgs name (tc-lifetime-subst-list subst lifetimes))]
    [_ ty]))

(define (tc-infer-lifetime-name
  [params : AstLifetimeList]
  [subst : TcLifetimeSubst]
  [formal : String]
  [actual : String]) : ResultTcLifetimeSubst
  (if (tc-lifetime-list-contains params formal)
    (tc-lifetime-subst-bind subst formal actual)
    (if (string-eq formal actual)
      (OkTcLifetimeSubst subst)
      (ErrTcLifetimeSubst "typecheck: argument type mismatch"))))

(define (tc-infer-lifetime-list
  [params : AstLifetimeList]
  [subst : TcLifetimeSubst]
  [formal : AstLifetimeList]
  [actual : AstLifetimeList]) : ResultTcLifetimeSubst
  (match formal
    [(AstLifetimeNil)
      (match actual
        [(AstLifetimeNil) (OkTcLifetimeSubst subst)]
        [_ (ErrTcLifetimeSubst "typecheck: argument type mismatch")])]
    [(AstLifetimeCons formal-head formal-rest)
      (let
        [formal-rest : AstLifetimeList (box-get formal-rest)]
        (match actual
          [(AstLifetimeCons actual-head actual-rest)
            (let
              [actual-rest : AstLifetimeList (box-get actual-rest)]
              (match (tc-infer-lifetime-name
                params
                subst
                formal-head
                actual-head)
                [(OkTcLifetimeSubst next-subst)
                  (tc-infer-lifetime-list
                    params
                    next-subst
                    formal-rest
                    actual-rest)]
                [(ErrTcLifetimeSubst message) (ErrTcLifetimeSubst message)]))]
          [_ (ErrTcLifetimeSubst "typecheck: argument type mismatch")]))]))

(define (tc-infer-lifetime-subst-from-type
  [ctx : TcContext]
  [params : AstLifetimeList]
  [subst : TcLifetimeSubst]
  [formal : AstType]
  [actual : AstType]) : ResultTcLifetimeSubst
  (let
    [want : AstType (tc-resolve-type ctx formal)]
    [got : AstType (tc-resolve-type ctx actual)]
    (match want
      [(AstTyRef formal-lifetime formal-inner)
        (match got
          [(AstTyRef actual-lifetime actual-inner)
            (match (tc-infer-lifetime-name
              params
              subst
              formal-lifetime
              actual-lifetime)
              [(OkTcLifetimeSubst next-subst)
                (tc-infer-lifetime-subst-from-type
                  ctx
                  params
                  next-subst
                  (box-get formal-inner)
                  (box-get actual-inner))]
              [(ErrTcLifetimeSubst message) (ErrTcLifetimeSubst message)])]
          [_ (ErrTcLifetimeSubst "typecheck: argument type mismatch")])]
      [(AstTyMutRef formal-lifetime formal-inner)
        (match got
          [(AstTyMutRef actual-lifetime actual-inner)
            (match (tc-infer-lifetime-name
              params
              subst
              formal-lifetime
              actual-lifetime)
              [(OkTcLifetimeSubst next-subst)
                (tc-infer-lifetime-subst-from-type
                  ctx
                  params
                  next-subst
                  (box-get formal-inner)
                  (box-get actual-inner))]
              [(ErrTcLifetimeSubst message) (ErrTcLifetimeSubst message)])]
          [_ (ErrTcLifetimeSubst "typecheck: argument type mismatch")])]
      [(AstTyEnumArgs formal-name formal-lifetimes)
        (match got
          [(AstTyEnumArgs actual-name actual-lifetimes)
            (if (string-eq formal-name actual-name)
              (tc-infer-lifetime-list
                params
                subst
                formal-lifetimes
                actual-lifetimes)
              (ErrTcLifetimeSubst "typecheck: argument type mismatch"))]
          [_ (ErrTcLifetimeSubst "typecheck: argument type mismatch")])]
      [(AstTyStructArgs formal-name formal-lifetimes)
        (match got
          [(AstTyStructArgs actual-name actual-lifetimes)
            (if (string-eq formal-name actual-name)
              (tc-infer-lifetime-list
                params
                subst
                formal-lifetimes
                actual-lifetimes)
              (ErrTcLifetimeSubst "typecheck: argument type mismatch"))]
          [_ (ErrTcLifetimeSubst "typecheck: argument type mismatch")])]
      [(AstTyTuple formal-elems)
        (match got
          [(AstTyTuple actual-elems)
            (tc-infer-lifetime-subst-from-type-list
              ctx
              params
              subst
              formal-elems
              actual-elems)]
          [_ (ErrTcLifetimeSubst "typecheck: argument type mismatch")])]
      [(AstTyArray formal-elem formal-len)
        (match got
          [(AstTyArray actual-elem actual-len)
            (if (= formal-len actual-len)
              (tc-infer-lifetime-subst-from-type
                ctx
                params
                subst
                (box-get formal-elem)
                (box-get actual-elem))
              (ErrTcLifetimeSubst "typecheck: argument type mismatch"))]
          [_ (ErrTcLifetimeSubst "typecheck: argument type mismatch")])]
      [(AstTyDynArray formal-elem)
        (match got
          [(AstTyDynArray actual-elem)
            (tc-infer-lifetime-subst-from-type
              ctx
              params
              subst
              (box-get formal-elem)
              (box-get actual-elem))]
          [_ (ErrTcLifetimeSubst "typecheck: argument type mismatch")])]
      [(AstTyBox formal-elem)
        (match got
          [(AstTyBox actual-elem)
            (tc-infer-lifetime-subst-from-type
              ctx
              params
              subst
              (box-get formal-elem)
              (box-get actual-elem))]
          [_ (ErrTcLifetimeSubst "typecheck: argument type mismatch")])]
      [_
        (if (tc-type-compatible? want got)
          (OkTcLifetimeSubst subst)
          (ErrTcLifetimeSubst "typecheck: argument type mismatch"))])))

(define (tc-infer-lifetime-subst-from-type-list
  [ctx : TcContext]
  [params : AstLifetimeList]
  [subst : TcLifetimeSubst]
  [formal : AstTypeList]
  [actual : AstTypeList]) : ResultTcLifetimeSubst
  (match formal
    [(AstTypeNil)
      (match actual
        [(AstTypeNil) (OkTcLifetimeSubst subst)]
        [_ (ErrTcLifetimeSubst "typecheck: argument type mismatch")])]
    [(AstTypeCons formal-head formal-rest)
      (let
        [formal-head : AstType (box-get formal-head)]
        [formal-rest : AstTypeList (box-get formal-rest)]
        (match actual
          [(AstTypeCons actual-head actual-rest)
            (let
              [actual-head : AstType (box-get actual-head)]
              [actual-rest : AstTypeList (box-get actual-rest)]
              (match (tc-infer-lifetime-subst-from-type
                ctx
                params
                subst
                formal-head
                actual-head)
                [(OkTcLifetimeSubst next-subst)
                  (tc-infer-lifetime-subst-from-type-list
                    ctx
                    params
                    next-subst
                    formal-rest
                    actual-rest)]
                [(ErrTcLifetimeSubst message) (ErrTcLifetimeSubst message)]))]
          [_ (ErrTcLifetimeSubst "typecheck: argument type mismatch")]))]))

(define (tc-infer-call-lifetime-subst
  [ctx : TcContext]
  [env : TcTypeEnv]
  [args : AstExprList]
  [params : AstTypeList]
  [lifetimes : AstLifetimeList]
  [subst : TcLifetimeSubst]) : ResultTcLifetimeSubst
  (match args
    [(AstExprNil)
      (match params
        [(AstTypeNil) (OkTcLifetimeSubst subst)]
        [_ (ErrTcLifetimeSubst "typecheck: arity mismatch")])]
    [(AstExprCons arg rest-args)
      (let
        [arg : AstExpr (box-get arg)]
        [rest-args : AstExprList (box-get rest-args)]
        (match params
          [(AstTypeCons want rest-params)
            (let
              [want : AstType (box-get want)]
              [rest-params : AstTypeList (box-get rest-params)]
              (match (tc-expr ctx env arg)
                [(OkTcType got)
                  (match (tc-infer-lifetime-subst-from-type
                    ctx
                    lifetimes
                    subst
                    want
                    got)
                    [(OkTcLifetimeSubst next-subst)
                      (tc-infer-call-lifetime-subst
                        ctx
                        env
                        rest-args
                        rest-params
                        lifetimes
                        next-subst)]
                    [(ErrTcLifetimeSubst message) (ErrTcLifetimeSubst message)])]
                [(ErrTcType message) (ErrTcLifetimeSubst message)]))]
          [(AstTypeNil) (ErrTcLifetimeSubst "typecheck: arity mismatch")]))]))

(define (tc-call-lifetime-constructor-type
  [ctx : TcContext]
  [env : TcTypeEnv]
  [func : AstExpr]
  [args : AstExprList]
  [params : AstTypeList]
  [ret : AstType]
  [allow-region-args : bool]) : ResultTcType
  (let
    [lifetimes : AstLifetimeList
      (match ret
        [(AstTyStructArgs _ params-lifetimes) params-lifetimes]
        [(AstTyEnumArgs _ params-lifetimes) params-lifetimes]
        [_ AstLifetimeNil])]
    (match (tc-infer-call-lifetime-subst
      ctx
      env
      args
      params
      lifetimes
      TcLifetimeSubstNil)
      [(OkTcLifetimeSubst subst)
        (let
          [target : AstType
            (tc-tag-active-region env (tc-lifetime-subst-type subst ret))]
          [resolved-params : AstTypeList
            (tc-lifetime-subst-type-list subst params)]
          (match (tc-check-call-args
            ctx
            env
            args
            resolved-params
            allow-region-args
            (AstSomeType target))
            [(OkTcUnit) (OkTcType target)]
            [(ErrTcUnit message) (ErrTcType message)]))]
      [(ErrTcLifetimeSubst message) (ErrTcType message)])))

(define (tc-call-function-lifetimes [params : AstTypeList] [ret : AstType]) : AstLifetimeList
  (tc-string-list-to-lifetime-list
    (tc-type-collect-reference-lifetimes-into
      ret
      (tc-type-list-collect-reference-lifetimes params TcStringNil))))

(define (tc-call-lifetime-function-type
  [ctx : TcContext]
  [env : TcTypeEnv]
  [args : AstExprList]
  [params : AstTypeList]
  [ret : AstType]
  [lifetimes : AstLifetimeList]
  [allow-region-args : bool]) : ResultTcType
  (match (tc-infer-call-lifetime-subst
    ctx
    env
    args
    params
    lifetimes
    TcLifetimeSubstNil)
    [(OkTcLifetimeSubst subst)
      (let
        [resolved-ret : AstType (tc-lifetime-subst-type subst ret)]
        [resolved-params : AstTypeList
          (tc-lifetime-subst-type-list subst params)]
        (match (tc-check-call-args
          ctx
          env
          args
          resolved-params
          allow-region-args
          (AstNoType))
          [(OkTcUnit) (OkTcType (tc-tag-active-region env resolved-ret))]
          [(ErrTcUnit message) (ErrTcType message)]))]
    [(ErrTcLifetimeSubst message) (ErrTcType message)]))

(define (tc-call-function-type
  [ctx : TcContext]
  [env : TcTypeEnv]
  [func : AstExpr]
  [args : AstExprList]
  [params : AstTypeList]
  [ret : AstType]) : ResultTcType
  (let
    [allow-region-args : bool
      (tc-call-region-args-allowed-for-func ctx env func)]
    (if (tc-call-lifetime-constructor-for-func? ctx func ret)
      (tc-call-lifetime-constructor-type
        ctx
        env
        func
        args
        params
        ret
        allow-region-args)
      (let
        [constructor-target : AstMaybeType
          (tc-call-constructor-target-for-func ctx env func params ret)]
        (match constructor-target
          [(AstSomeType _)
            (match (tc-check-call-args
              ctx
              env
              args
              params
              allow-region-args
              constructor-target)
              [(OkTcUnit)
                (match constructor-target
                  [(AstSomeType target) (OkTcType target)]
                  [(AstNoType) (OkTcType (tc-tag-active-region env ret))])]
              [(ErrTcUnit message) (ErrTcType message)])]
          [(AstNoType)
            (let
              [lifetimes : AstLifetimeList
                (tc-call-function-lifetimes params ret)]
              (match lifetimes
                [(AstLifetimeNil)
                  (match (tc-check-call-args
                    ctx
                    env
                    args
                    params
                    allow-region-args
                    constructor-target)
                    [(OkTcUnit) (OkTcType (tc-tag-active-region env ret))]
                    [(ErrTcUnit message) (ErrTcType message)])]
                [_
                  (tc-call-lifetime-function-type
                    ctx
                    env
                    args
                    params
                    ret
                    lifetimes
                    allow-region-args)]))])))))

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
      (let
        [arg : AstExpr (box-get arg)]
        [rest-args : AstExprList (box-get rest-args)]
        (match params
          [(AstTypeCons want rest-params)
            (let
              [want : AstType (box-get want)]
              [rest-params : AstTypeList (box-get rest-params)]
              (match (tc-expr-with-expected-or-actual ctx env arg want)
                [(OkTcType got)
                  (match (tc-expect
                    got
                    want
                    "typecheck: argument type mismatch")
                    [(OkTcUnit)
                      (if (and
                        (tc-type-contains-any-region got)
                        (and
                          (not allow-region-args)
                          (not (tc-type-contains-reference? got))))
                        (ErrTcUnit
                          "typecheck: cannot pass region-tagged value to function parameter; region value would escape")
                        (match constructor-target
                          [(AstSomeType target)
                            (match (tc-ensure-cleanup-resource-not-stored-expr
                              env
                              arg)
                              [(OkTcUnit)
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
                [(ErrTcType message) (ErrTcUnit message)]))]
          [(AstTypeNil) (ErrTcUnit "typecheck: arity mismatch")]))]))

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
      (let
        [arg : AstExpr (box-get arg)]
        [rest-args : AstExprList (box-get rest-args)]
        (match params
          [(AstTypeCons want rest-params)
            (let
              [want : AstType (box-get want)]
              [rest-params : AstTypeList (box-get rest-params)]
              (match (tc-expr-with-expected-or-actual ctx env arg want)
                [(OkTcType got)
                  (match (tc-expect
                    got
                    want
                    "typecheck: argument type mismatch")
                    [(OkTcUnit) (tc-check-args ctx env rest-args rest-params)]
                    [(ErrTcUnit message) (ErrTcUnit message)])]
                [(ErrTcType message) (ErrTcUnit message)]))]
          [(AstTypeNil) (ErrTcUnit "typecheck: arity mismatch")]))]))

(define (tc-call-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [func : AstExpr]
  [args : AstExprList]) : ResultTcType
  (match (tc-expr ctx env func)
    [(OkTcType fn-ty)
      (match fn-ty
        [(AstTyFunc params ret)
          (tc-call-function-type ctx env func args params (box-get ret))]
        [(AstTyRegion _ inner)
          (match (box-get inner)
            [(AstTyFunc params ret)
              (match (tc-check-call-args ctx env args params false (AstNoType))
                [(OkTcUnit) (OkTcType (tc-tag-active-region env (box-get ret)))]
                [(ErrTcUnit message) (ErrTcType message)])]
            [(AstTyEnum enum-name)
              (match args
                [(AstExprNil)
                  (tc-nullary-variant-call-expr
                    ctx
                    env
                    func
                    enum-name
                    (box-get inner))]
                [_ (ErrTcType "typecheck: arity mismatch")])]
            [(AstTyEnumArgs enum-name _)
              (match args
                [(AstExprNil)
                  (tc-nullary-variant-call-expr
                    ctx
                    env
                    func
                    enum-name
                    (box-get inner))]
                [_ (ErrTcType "typecheck: arity mismatch")])]
            [_ (ErrTcType "typecheck: call target is not a function")])]
        [(AstTyEnum enum-name)
          (match args
            [(AstExprNil)
              (tc-nullary-variant-call-expr ctx env func enum-name fn-ty)]
            [_ (ErrTcType "typecheck: arity mismatch")])]
        [(AstTyEnumArgs enum-name _)
          (match args
            [(AstExprNil)
              (tc-nullary-variant-call-expr ctx env func enum-name fn-ty)]
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

(define (tc-str-ref-type? [ty : AstType]) : bool
  (match (tc-type-strip-region ty)
    [(AstTyRef _ inner)
      (match (tc-type-strip-region (box-get inner))
        [(AstTyStr) true]
        [_ false])]
    [_ false]))

(define (tc-string-handle-type? [ty : AstType]) : bool
  (match (tc-type-strip-region ty)
    [(AstTyString) true]
    [_ (tc-str-ref-type? ty)]))

(define (tc-check-string-handle-arg
  [ctx : TcContext]
  [env : TcTypeEnv]
  [arg : AstExpr]
  [message : String]) : ResultTcUnit
  (match (tc-expr ctx env arg)
    [(OkTcType arg-ty)
      (if (tc-string-handle-type? arg-ty)
        OkTcUnit
        (ErrTcUnit message))]
    [(ErrTcType message) (ErrTcUnit message)]))

(define (tc-check-exact-arg
  [ctx : TcContext]
  [env : TcTypeEnv]
  [arg : AstExpr]
  [want : AstType]
  [message : String]) : ResultTcUnit
  (match (tc-expr ctx env arg)
    [(OkTcType arg-ty) (tc-expect arg-ty want message)]
    [(ErrTcType message) (ErrTcUnit message)]))

(define (tc-one-string-handle-builtin-call
  [ctx : TcContext]
  [env : TcTypeEnv]
  [args : AstExprList]
  [ret : AstType]) : ResultTcType
  (match args
    [(AstExprCons arg tail)
      (let
        [arg : AstExpr (box-get arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprNil)
            (match (tc-check-string-handle-arg
              ctx
              env
              arg
              "typecheck: argument type mismatch")
              [(OkTcUnit) (OkTcType (tc-tag-active-region env ret))]
              [(ErrTcUnit message) (ErrTcType message)])]
          [_ (ErrTcType "typecheck: arity mismatch")]))]
    [_ (ErrTcType "typecheck: arity mismatch")]))

(define (tc-two-string-handle-builtin-call
  [ctx : TcContext]
  [env : TcTypeEnv]
  [args : AstExprList]
  [ret : AstType]) : ResultTcType
  (match args
    [(AstExprCons left tail)
      (let
        [left : AstExpr (box-get left)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons right rest)
            (let
              [right : AstExpr (box-get right)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (tc-check-string-handle-arg
                    ctx
                    env
                    left
                    "typecheck: argument type mismatch")
                    [(OkTcUnit)
                      (match (tc-check-string-handle-arg
                        ctx
                        env
                        right
                        "typecheck: argument type mismatch")
                        [(OkTcUnit) (OkTcType (tc-tag-active-region env ret))]
                        [(ErrTcUnit message) (ErrTcType message)])]
                    [(ErrTcUnit message) (ErrTcType message)])]
                [_ (ErrTcType "typecheck: arity mismatch")]))]
          [_ (ErrTcType "typecheck: arity mismatch")]))]
    [_ (ErrTcType "typecheck: arity mismatch")]))

(define (tc-string-i64-i64-builtin-call
  [ctx : TcContext]
  [env : TcTypeEnv]
  [args : AstExprList]
  [ret : AstType]) : ResultTcType
  (match args
    [(AstExprCons text tail)
      (let
        [text : AstExpr (box-get text)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons start rest1)
            (let
              [start : AstExpr (box-get start)]
              [rest1 : AstExprList (box-get rest1)]
              (match rest1
                [(AstExprCons len rest2)
                  (let
                    [len : AstExpr (box-get len)]
                    [rest2 : AstExprList (box-get rest2)]
                    (match rest2
                      [(AstExprNil)
                        (match (tc-check-string-handle-arg
                          ctx
                          env
                          text
                          "typecheck: argument type mismatch")
                          [(OkTcUnit)
                            (match (tc-check-exact-arg
                              ctx
                              env
                              start
                              (AstTyI64)
                              "typecheck: argument type mismatch")
                              [(OkTcUnit)
                                (match (tc-check-exact-arg
                                  ctx
                                  env
                                  len
                                  (AstTyI64)
                                  "typecheck: argument type mismatch")
                                  [(OkTcUnit)
                                    (OkTcType (tc-tag-active-region env ret))]
                                  [(ErrTcUnit message) (ErrTcType message)])]
                              [(ErrTcUnit message) (ErrTcType message)])]
                          [(ErrTcUnit message) (ErrTcType message)])]
                      [_ (ErrTcType "typecheck: arity mismatch")]))]
                [_ (ErrTcType "typecheck: arity mismatch")]))]
          [_ (ErrTcType "typecheck: arity mismatch")]))]
    [_ (ErrTcType "typecheck: arity mismatch")]))

(define (tc-string-i64-builtin-call
  [ctx : TcContext]
  [env : TcTypeEnv]
  [args : AstExprList]
  [ret : AstType]) : ResultTcType
  (match args
    [(AstExprCons text tail)
      (let
        [text : AstExpr (box-get text)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons value rest)
            (let
              [value : AstExpr (box-get value)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (tc-check-string-handle-arg
                    ctx
                    env
                    text
                    "typecheck: argument type mismatch")
                    [(OkTcUnit)
                      (match (tc-check-exact-arg
                        ctx
                        env
                        value
                        (AstTyI64)
                        "typecheck: argument type mismatch")
                        [(OkTcUnit) (OkTcType (tc-tag-active-region env ret))]
                        [(ErrTcUnit message) (ErrTcType message)])]
                    [(ErrTcUnit message) (ErrTcType message)])]
                [_ (ErrTcType "typecheck: arity mismatch")]))]
          [_ (ErrTcType "typecheck: arity mismatch")]))]
    [_ (ErrTcType "typecheck: arity mismatch")]))

(define (tc-i64-string-builtin-call
  [ctx : TcContext]
  [env : TcTypeEnv]
  [args : AstExprList]
  [ret : AstType]) : ResultTcType
  (match args
    [(AstExprCons value tail)
      (let
        [value : AstExpr (box-get value)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons text rest)
            (let
              [text : AstExpr (box-get text)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (tc-check-exact-arg
                    ctx
                    env
                    value
                    (AstTyI64)
                    "typecheck: argument type mismatch")
                    [(OkTcUnit)
                      (match (tc-check-string-handle-arg
                        ctx
                        env
                        text
                        "typecheck: argument type mismatch")
                        [(OkTcUnit) (OkTcType (tc-tag-active-region env ret))]
                        [(ErrTcUnit message) (ErrTcType message)])]
                    [(ErrTcUnit message) (ErrTcType message)])]
                [_ (ErrTcType "typecheck: arity mismatch")]))]
          [_ (ErrTcType "typecheck: arity mismatch")]))]
    [_ (ErrTcType "typecheck: arity mismatch")]))

(define (tc-borrowed-string-builtin-name? [name : String]) : bool
  (cond
    [(string-eq name "string-eq") true]
    [(string-eq name "string=?") true]
    [(string-eq name "string->int") true]
    [(string-eq name "substring") true]
    [(string-eq name "string-slice") true]
    [(string-eq name "string-append") true]
    [(string-eq name "string-concat") true]
    [else false]))

(define (tc-borrowed-string-builtin-call
  [ctx : TcContext]
  [env : TcTypeEnv]
  [name : String]
  [args : AstExprList]) : ResultTcType
  (cond
    [(or (string-eq name "string-eq") (string-eq name "string=?"))
      (tc-two-string-handle-builtin-call ctx env args (AstTyBool))]
    [(string-eq name "string->int")
      (tc-one-string-handle-builtin-call ctx env args (AstTyI64))]
    [(or (string-eq name "substring") (string-eq name "string-slice"))
      (tc-string-i64-i64-builtin-call ctx env args (AstTyString))]
    [(or (string-eq name "string-append") (string-eq name "string-concat"))
      (tc-two-string-handle-builtin-call ctx env args (AstTyString))]
    [else (ErrTcType "typecheck: unknown borrowed string builtin")]))

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
    [(AstExprCons str tail)
      (let
        [str : AstExpr (box-get str)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons index rest)
            (let
              [index : AstExpr (box-get index)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (tc-expr ctx env str)
                    [(OkTcType str-ty)
                      (if (tc-string-handle-type? str-ty)
                        (match (tc-expr ctx env index)
                          [(OkTcType index-ty)
                            (if (tc-integer-type? index-ty)
                              (OkTcType (AstTyChar))
                              (ErrTcType
                                "typecheck: string index must be integer"))]
                          [(ErrTcType message) (ErrTcType message)])
                        (ErrTcType "typecheck: string-ref requires String"))]
                    [(ErrTcType message) (ErrTcType message)])]
                [_ (ErrTcType "typecheck: arity mismatch")]))]
          [_ (ErrTcType "typecheck: arity mismatch")]))]
    [_ (ErrTcType "typecheck: arity mismatch")]))

(define (tc-length-string-call
  [ctx : TcContext]
  [env : TcTypeEnv]
  [name : String]
  [func : AstExpr]
  [args : AstExprList]
  [arg-ty : AstType]) : ResultTcType
  (if (and
    (tc-default-builtin-unshadowed? env name)
    (tc-string-handle-type? arg-ty))
    (OkTcType (AstTyI64))
    (if (string-eq name "string-length")
      (if (tc-default-builtin-unshadowed? env name)
        (ErrTcType "typecheck: argument type mismatch")
        (tc-call-expr ctx env func args))
      (tc-call-expr ctx env func args))))

(define (tc-array-length-non-array-call
  [ctx : TcContext]
  [env : TcTypeEnv]
  [name : String]
  [func : AstExpr]
  [args : AstExprList]
  [arg-ty : AstType]) : ResultTcType
  (if (string-eq name "array-length")
    (ErrTcType "typecheck: array-length requires dynamic array")
    (tc-length-string-call ctx env name func args arg-ty)))

(define (tc-array-length-array-call
  [ctx : TcContext]
  [env : TcTypeEnv]
  [name : String]
  [func : AstExpr]
  [args : AstExprList]) : ResultTcType
  (if (string-eq name "string-length")
    (if (tc-default-builtin-unshadowed? env name)
      (ErrTcType "typecheck: argument type mismatch")
      (tc-call-expr ctx env func args))
    (OkTcType (AstTyI64))))

;; `array-length` remains dynamic-array-only. `length` and `string-length` keep
;; their legacy owned-String path while also accepting explicit borrowed `str`
;; handles for the unshadowed default builtin.
(define (tc-array-length-call
  [ctx : TcContext]
  [env : TcTypeEnv]
  [name : String]
  [func : AstExpr]
  [args : AstExprList]) : ResultTcType
  (match args
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (box-get arg)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (match (tc-expr ctx env arg)
              [(OkTcType arg-ty)
                (match (tc-type-strip-region arg-ty)
                  [(AstTyDynArray _)
                    (tc-array-length-array-call ctx env name func args)]
                  [_
                    (tc-array-length-non-array-call
                      ctx
                      env
                      name
                      func
                      args
                      arg-ty)])]
              [(ErrTcType message) (ErrTcType message)])]
          [_
            (if (string-eq name "array-length")
              (ErrTcType "typecheck: arity mismatch")
              (tc-call-expr ctx env func args))]))]
    [_
      (if (string-eq name "array-length")
        (ErrTcType "typecheck: arity mismatch")
        (tc-call-expr ctx env func args))]))

(define (tc-layout-query-name? [name : String]) : bool
  (if (string-eq name "size-of")
    true
    (if (string-eq name "align-of")
      true
      (string-eq name "offset-of"))))

;; Layout queries are CTFE-only. Inside `(comptime ...)` the typechecker gets the
;; folded value from `compiler-ctfe-eval`; if an unshadowed query reaches normal
;; expression typing, it is a runtime use and must be rejected.
(define (tc-one-arg-layout-query-runtime-call
  [name : String]
  [args : AstExprList]) : ResultTcType
  (match args
    [(AstExprCons _ rest)
      (let
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (ErrTcType
              (string-append
                "typecheck: "
                (string-append
                  name
                  " is compile-time only; wrap it in (comptime ...)")))]
          [_
            (ErrTcType
              (string-append
                "typecheck: "
                (string-append name " expects exactly one type argument")))]))]
    [_
      (ErrTcType
        (string-append
          "typecheck: "
          (string-append name " expects exactly one type argument")))]))

(define (tc-offset-layout-query-runtime-call [args : AstExprList]) : ResultTcType
  (match args
    [(AstExprCons _ tail)
      (let
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons _ rest)
            (let
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (ErrTcType
                    "typecheck: offset-of is compile-time only; wrap it in (comptime ...)")]
                [_
                  (ErrTcType
                    "typecheck: offset-of expects exactly one type argument and one field name")]))]
          [_
            (ErrTcType
              "typecheck: offset-of expects exactly one type argument and one field name")]))]
    [_
      (ErrTcType
        "typecheck: offset-of expects exactly one type argument and one field name")]))

(define (tc-layout-query-runtime-call [name : String] [args : AstExprList]) : ResultTcType
  (if (string-eq name "offset-of")
    (tc-offset-layout-query-runtime-call args)
    (tc-one-arg-layout-query-runtime-call name args)))

(define (tc-reflection-query-runtime-call [name : String]) : ResultTcType
  (ErrTcType
    (string-append
      "typecheck: "
      (string-append name " is compile-time only; wrap it in (comptime ...)"))))

(define (tc-clone-able-type? [ctx : TcContext] [ty : AstType]) : bool
  (match (tc-context-program ctx)
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (clone-field-type-able?
          (tc-type-without-regions (tc-resolve-type ctx ty))
          (clone-fixpoint
            decls
            (clone-all-type-names decls (clone-name-set-empty)))))]))

;; `(clone x)` deep-copies x into the current arena (#1633). Type-directed: the
;; result is the argument's type, stripped of any inner-region tag (the copy
;; lands in the enclosing arena, not the source's region). Unsupported types are
;; rejected here so no heap-backed value silently lowers as a shallow handle copy.
(define (tc-clone-call [ctx : TcContext] [env : TcTypeEnv] [args : AstExprList]) : ResultTcType
  (match args
    [(AstExprCons arg tail)
      (let
        [arg : AstExpr (box-get arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprNil)
            (match (tc-expr ctx env arg)
              [(OkTcType arg-ty)
                (let
                  [clone-ty : AstType (tc-type-without-regions arg-ty)]
                  (if (tc-clone-able-type? ctx clone-ty)
                    (OkTcType clone-ty)
                    (ErrTcType
                      (string-append
                        "typecheck: clone unsupported type "
                        (tc-type-render
                          (tc-type-without-regions (tc-resolve-type ctx arg-ty)))))))]
              [(ErrTcType message) (ErrTcType message)])]
          [_ (ErrTcType "typecheck: clone expects exactly one argument")]))]
    [_ (ErrTcType "typecheck: clone expects exactly one argument")]))

(define (tc-call-or-array-length
  [ctx : TcContext]
  [env : TcTypeEnv]
  [func : AstExpr]
  [args : AstExprList]) : ResultTcType
  (match (ast-expr-unspan func)
    [(AstExprVar name)
      (cond
        [(and (tc-layout-query-name? name) (not (tc-name-bound? env name)))
          (tc-layout-query-runtime-call name args)]
        [(or
            (string-eq name "array-length")
            (or (string-eq name "length") (string-eq name "string-length")))
          (tc-array-length-call ctx env name func args)]
        [(and
            (or (string-eq name "string-ref") (string-eq name "char-at"))
            (not (tc-name-bound? env name)))
          (tc-string-ref-call ctx env args)]
        [(and
            (tc-borrowed-string-builtin-name? name)
            (tc-default-builtin-unshadowed? env name))
          (tc-borrowed-string-builtin-call ctx env name args)]
        [(and
            (ctfe-reflection-query-name? name)
            (not (tc-name-bound? env name)))
          (tc-reflection-query-runtime-call name)]
        [(and (string-eq name "clone") (not (tc-name-bound? env name)))
          (tc-clone-call ctx env args)]
        [else (tc-call-expr ctx env func args)])]
    [_ (tc-call-expr ctx env func args)]))

(define (tc-let-bindings
  [ctx : TcContext]
  [env : TcTypeEnv]
  [bindings : AstLetBindingList]) : ResultTcEnv
  (match bindings
    [(AstLetBindingNil) (OkTcEnv env)]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name maybe-ty init-box)
            (let
              [init : AstExpr (box-get init-box)]
              (match maybe-ty
                [(AstSomeType want)
                  (let
                    [resolved-want : AstType (tc-resolve-type ctx want)]
                    (match (tc-expr-with-expected-or-actual
                      ctx
                      env
                      init
                      resolved-want)
                      [(OkTcType init-ty)
                        (match (tc-expect
                          init-ty
                          resolved-want
                          "typecheck: let binding type mismatch")
                          [(OkTcUnit)
                            (match (tc-ensure-cleanup-resource-not-let-bound
                              env
                              init)
                              [(OkTcUnit)
                                (match (tc-ensure-reference-value-can-bind
                                  env
                                  init-ty)
                                  [(OkTcUnit)
                                    (tc-let-bindings
                                      ctx
                                      (tc-bind
                                        env
                                        name
                                        (if (tc-type-contains-any-region
                                          init-ty)
                                          init-ty
                                          resolved-want))
                                      rest)]
                                  [(ErrTcUnit message) (ErrTcEnv message)])]
                              [(ErrTcUnit message) (ErrTcEnv message)])]
                          [(ErrTcUnit message) (ErrTcEnv message)])]
                      [(ErrTcType message) (ErrTcEnv message)]))]
                [(AstNoType)
                  (match (tc-expr ctx env init)
                    [(OkTcType init-ty)
                      (match (tc-ensure-cleanup-resource-not-let-bound env init)
                        [(OkTcUnit)
                          (match (tc-ensure-reference-value-can-bind
                            env
                            init-ty)
                            [(OkTcUnit)
                              (tc-let-bindings
                                ctx
                                (tc-bind env name init-ty)
                                rest)]
                            [(ErrTcUnit message) (ErrTcEnv message)])]
                        [(ErrTcUnit message) (ErrTcEnv message)])]
                    [(ErrTcType message) (ErrTcEnv message)])]))]))]))

(define (tc-resource-cleanup-direct-name-ok [cleanup : AstExpr]) : ResultTcUnit
  (match (ast-expr-unspan cleanup)
    [(AstExprVar _) OkTcUnit]
    [_ (ErrTcUnit "typecheck: with cleanup must be a direct function name")]))

(define (tc-resource-cleanup-ok
  [ctx : TcContext]
  [env : TcTypeEnv]
  [cleanup : AstExpr]
  [resource-ty : AstType]) : ResultTcUnit
  (match (tc-resource-cleanup-direct-name-ok cleanup)
    [(OkTcUnit)
      (match (tc-expr ctx env cleanup)
        [(OkTcType cleanup-ty)
          (tc-expect
            cleanup-ty
            (tc-fn1 (tc-type-without-regions resource-ty) (AstTyUnit))
            "typecheck: with cleanup function type mismatch")]
        [(ErrTcType message) (ErrTcUnit message)])]
    [(ErrTcUnit message) (ErrTcUnit message)]))

(define (tc-resource-bindings
  [ctx : TcContext]
  [env : TcTypeEnv]
  [bindings : AstResourceBindingList]) : ResultTcEnv
  (match bindings
    [(AstResourceBindingNil) (OkTcEnv env)]
    [(AstResourceBindingCons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding name init-box cleanup-box)
            (let
              [init : AstExpr (box-get init-box)]
              [cleanup : AstExpr (box-get cleanup-box)]
              (match (tc-expr ctx env init)
                [(OkTcType init-ty)
                  (match (tc-ensure-cleanup-resource-not-transferred env init)
                    [(OkTcUnit)
                      (match (tc-resource-cleanup-ok ctx env cleanup init-ty)
                        [(OkTcUnit)
                          (tc-resource-bindings
                            ctx
                            (tc-bind
                              (tc-bind-cleanup-owner env name)
                              name
                              (tc-type-without-regions init-ty))
                            rest)]
                        [(ErrTcUnit message) (ErrTcEnv message)])]
                    [(ErrTcUnit message) (ErrTcEnv message)])]
                [(ErrTcType message) (ErrTcEnv message)]))]))]))

(define (tc-begin-list
  [ctx : TcContext]
  [env : TcTypeEnv]
  [exprs : AstExprList]) : ResultTcType
  (match exprs
    [(AstExprNil) (OkTcType (AstTyUnit))]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (box-get expr)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil) (tc-expr ctx env expr)]
          [_
            (match (tc-expr ctx env expr)
              [(OkTcType _) (tc-begin-list ctx env rest)]
              [(ErrTcType message) (ErrTcType message)])]))]))

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
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name maybe-ty init-box)
            (let
              [init : AstExpr (box-get init-box)]
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
                [(ErrTcSpmdExprInfo message) (ErrTcSpmdLetState message)]))]))]))

(define (tc-spmd-expr-list
  [ctx : TcContext]
  [env : TcTypeEnv]
  [spmd-env : TcSpmdEnv]
  [exprs : AstExprList]) : ResultTcSpmdExprListInfo
  (match exprs
    [(AstExprNil)
      (OkTcSpmdExprListInfo (TcSpmdExprListInfo TcSpmdUniform spmd-env))]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (box-get expr)]
        [rest : AstExprList (box-get rest)]
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
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprListInfo message)]))]))

(define (tc-spmd-begin-list
  [ctx : TcContext]
  [env : TcTypeEnv]
  [spmd-env : TcSpmdEnv]
  [exprs : AstExprList]) : ResultTcSpmdExprInfo
  (match exprs
    [(AstExprNil)
      (OkTcSpmdExprInfo (TcSpmdExprInfo (AstTyUnit) TcSpmdUniform spmd-env))]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (box-get expr)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil) (tc-spmd-expr ctx env spmd-env expr)]
          [_
            (match (tc-spmd-expr ctx env spmd-env expr)
              [(OkTcSpmdExprInfo info)
                (match info
                  [(TcSpmdExprInfo _ _ next-spmd-env)
                    (tc-spmd-begin-list ctx env next-spmd-env rest)])]
              [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]))]))

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
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern body-box)
            (let
              [body : AstExpr (box-get body-box)]
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
                                      (tc-spmd-env-merge-classes
                                        body-env
                                        rest-env)))])]
                            [(ErrTcSpmdExprListInfo message)
                              (ErrTcSpmdExprListInfo message)])])]
                    [(ErrTcSpmdExprInfo message)
                      (ErrTcSpmdExprListInfo message)])]
                [(ErrTcEnv message) (ErrTcSpmdExprListInfo message)]))]))]))

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
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-spmd-expr-typed ctx env spmd-env inner expr-ty))]
    [(AstExprLiteral _) (tc-spmd-finish expr-ty TcSpmdUniform spmd-env)]
    [(AstExprVar name)
      (match (tc-spmd-env-lookup spmd-env name)
        [(TcSpmdFound _ class _) (tc-spmd-finish expr-ty class spmd-env)]
        [(TcSpmdMissing) (tc-spmd-finish expr-ty TcSpmdUniform spmd-env)])]
    [(AstExprTypeLiteral _) (tc-spmd-finish expr-ty TcSpmdUniform spmd-env)]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-spmd-expr ctx env spmd-env inner)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-spmd-expr ctx env spmd-env inner)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprUnary _ inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-spmd-expr ctx env spmd-env inner)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprBinary _ left-box right-box)
      (let
        [left : AstExpr (box-get left-box)]
        [right : AstExpr (box-get right-box)]
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
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (box-get func-box)]
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
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [then-branch : AstExpr (box-get then-branch-box)]
        [else-branch : AstExpr (box-get else-branch-box)]
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
                                      (tc-spmd-merge-class
                                        then-class
                                        else-class)
                                      (tc-spmd-env-merge-classes
                                        then-env
                                        else-env))])]
                              [(ErrTcSpmdExprInfo message)
                                (ErrTcSpmdExprInfo message)])])]
                      [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
                  [(ErrTcUnit message) (ErrTcSpmdExprInfo message)])])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (box-get body-box)]
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
          [(ErrTcSpmdLetState message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprLambda _ _ _) (tc-spmd-finish expr-ty TcSpmdUniform spmd-env)]
    [(AstExprTuple exprs)
      (match (tc-spmd-expr-list ctx env spmd-env exprs)
        [(OkTcSpmdExprListInfo info)
          (match info
            [(TcSpmdExprListInfo class next-spmd-env)
              (tc-spmd-finish expr-ty class next-spmd-env)])]
        [(ErrTcSpmdExprListInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprTupleRef tuple-box _)
      (let
        [tuple : AstExpr (box-get tuple-box)]
        (match (tc-spmd-expr ctx env spmd-env tuple)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprArray exprs)
      (match (tc-spmd-expr-list ctx env spmd-env exprs)
        [(OkTcSpmdExprListInfo info)
          (match info
            [(TcSpmdExprListInfo class next-spmd-env)
              (tc-spmd-finish expr-ty class next-spmd-env)])]
        [(ErrTcSpmdExprListInfo message) (ErrTcSpmdExprInfo message)])]
    [(AstExprMakeArray _ len-box)
      (let
        [len : AstExpr (box-get len-box)]
        (match (tc-spmd-expr ctx env spmd-env len)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
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
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        [value : AstExpr (box-get value-box)]
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
                                          (tc-spmd-lane-type-supported?
                                            (box-get elem-ty))))
                                        (ErrTcSpmdExprInfo
                                          (string-append
                                            "typecheck: foreach varying array lane type is not supported: "
                                            (tc-type-render
                                              (tc-type-strip-region
                                                (box-get elem-ty)))))
                                        (tc-spmd-finish
                                          expr-ty
                                          TcSpmdUniform
                                          value-env))]
                                    [(AstTyDynArray elem-ty)
                                      (if (and
                                        (tc-spmd-varying? write-class)
                                        (not
                                          (tc-spmd-lane-type-supported?
                                            (box-get elem-ty))))
                                        (ErrTcSpmdExprInfo
                                          (string-append
                                            "typecheck: foreach varying array lane type is not supported: "
                                            (tc-type-render
                                              (tc-type-strip-region
                                                (box-get elem-ty)))))
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
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (box-get array-box)]
        [value : AstExpr (box-get value-box)]
        (match (tc-spmd-expr ctx env spmd-env array)
          [(OkTcSpmdExprInfo array-info)
            (match array-info
              [(TcSpmdExprInfo array-ty array-class array-env)
                (match (tc-spmd-expr ctx env array-env value)
                  [(OkTcSpmdExprInfo value-info)
                    (match value-info
                      [(TcSpmdExprInfo _ value-class value-env)
                        (let
                          [write-class : TcSpmdClass
                            (tc-spmd-merge-class array-class value-class)]
                          (match (tc-type-strip-region array-ty)
                            [(AstTyDynArray elem-ty)
                              (if (and
                                (tc-spmd-varying? write-class)
                                (not
                                  (tc-spmd-lane-type-supported?
                                    (box-get elem-ty))))
                                (ErrTcSpmdExprInfo
                                  (string-append
                                    "typecheck: foreach varying array lane type is not supported: "
                                    (tc-type-render
                                      (tc-type-strip-region (box-get elem-ty)))))
                                (tc-spmd-finish expr-ty TcSpmdUniform value-env))]
                            [_ (tc-spmd-finish expr-ty TcSpmdUniform value-env)]))])]
                  [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprStringRef str-box index-box)
      (let
        [str : AstExpr (box-get str-box)]
        [index : AstExpr (box-get index-box)]
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
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [body : AstExpr (box-get body-box)]
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
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprBegin exprs) (tc-spmd-begin-list ctx env spmd-env exprs)]
    [(AstExprUnsafe exprs)
      (tc-spmd-begin-list ctx (tc-enter-unsafe env) spmd-env exprs)]
    [(AstExprSet name value-box)
      (let
        [value : AstExpr (box-get value-box)]
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
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (box-get scrutinee-box)]
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
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprForeach index index-ty start-box end-box body-box)
      (let
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [body : AstExpr (box-get body-box)]
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
                                    (tc-spmd-finish
                                      expr-ty
                                      TcSpmdUniform
                                      end-env)]
                                  [(ErrTcUnit message)
                                    (ErrTcSpmdExprInfo message)])]
                              [(ErrTcUnit message) (ErrTcSpmdExprInfo message)])])]
                      [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])]
                  [(ErrTcUnit message) (ErrTcSpmdExprInfo message)])])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprSpmdReduce _ _ _ _ _ _ _)
      (ErrTcSpmdExprInfo
        "typecheck: spmd-reduce inside foreach is not supported")]
    [(AstExprBorrow _ place-box)
      (let
        [place : AstExpr (box-get place-box)]
        (match (tc-spmd-expr ctx env spmd-env place)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprStructGet receiver-box _)
      (let
        [receiver : AstExpr (box-get receiver-box)]
        (match (tc-spmd-expr ctx env spmd-env receiver)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-spmd-expr ctx env spmd-env inner)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-spmd-expr ctx env spmd-env inner)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprWithRegion region body)
      (tc-spmd-begin-list ctx (tc-push-region env region) spmd-env body)]
    [(AstExprWithEscape _ _)
      (ErrTcSpmdExprInfo "typecheck: with-escape inside spmd is not supported")]
    [(AstExprWithResource _ _)
      (ErrTcSpmdExprInfo
        "typecheck: resource with is not implemented yet (#907)")]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-spmd-expr ctx env spmd-env inner)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprQuote _) (tc-spmd-finish expr-ty TcSpmdUniform spmd-env)]
    [(AstExprQuasiquote _) (tc-spmd-finish expr-ty TcSpmdUniform spmd-env)]
    [(AstExprUnquote _)
      (ErrTcSpmdExprInfo "typecheck: unquote is only valid inside quasiquote")]
    [(AstExprUnquoteSplicing _)
      (ErrTcSpmdExprInfo
        "typecheck: unquote-splicing is only valid inside quasiquote")]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-spmd-expr ctx env spmd-env inner)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprReturn _)
      (ErrTcSpmdExprInfo "typecheck: return inside foreach is not supported")]
    [(AstExprPtrNull _) (tc-spmd-finish expr-ty TcSpmdUniform spmd-env)]
    [(AstExprPtrNullCheck inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-spmd-expr ctx env spmd-env inner)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (match (tc-spmd-expr ctx env spmd-env ptr)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [value : AstExpr (box-get value-box)]
        (match (tc-spmd-expr ctx env spmd-env ptr)
          [(OkTcSpmdExprInfo ptr-info)
            (match ptr-info
              [(TcSpmdExprInfo _ ptr-class ptr-env)
                (match (tc-spmd-expr ctx env ptr-env value)
                  [(OkTcSpmdExprInfo value-info)
                    (match value-info
                      [(TcSpmdExprInfo _ value-class value-env)
                        (tc-spmd-finish
                          expr-ty
                          (tc-spmd-merge-class ptr-class value-class)
                          value-env)])]
                  [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [offset : AstExpr (box-get offset-box)]
        (match (tc-spmd-expr ctx env spmd-env ptr)
          [(OkTcSpmdExprInfo ptr-info)
            (match ptr-info
              [(TcSpmdExprInfo _ ptr-class ptr-env)
                (match (tc-spmd-expr ctx env ptr-env offset)
                  [(OkTcSpmdExprInfo offset-info)
                    (match offset-info
                      [(TcSpmdExprInfo _ offset-class offset-env)
                        (tc-spmd-finish
                          expr-ty
                          (tc-spmd-merge-class ptr-class offset-class)
                          offset-env)])]
                  [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprPtrCast ptr-box _)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (match (tc-spmd-expr ctx env spmd-env ptr)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (match (tc-spmd-expr ctx env spmd-env ptr)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprIntToPtr value-box _)
      (let
        [value : AstExpr (box-get value-box)]
        (match (tc-spmd-expr ctx env spmd-env value)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprStringData str-box)
      (let
        [str : AstExpr (box-get str-box)]
        (match (tc-spmd-expr ctx env spmd-env str)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [len : AstExpr (box-get len-box)]
        (match (tc-spmd-expr ctx env spmd-env ptr)
          [(OkTcSpmdExprInfo ptr-info)
            (match ptr-info
              [(TcSpmdExprInfo _ ptr-class ptr-env)
                (match (tc-spmd-expr ctx env ptr-env len)
                  [(OkTcSpmdExprInfo len-info)
                    (match len-info
                      [(TcSpmdExprInfo _ len-class len-env)
                        (tc-spmd-finish
                          expr-ty
                          (tc-spmd-merge-class ptr-class len-class)
                          len-env)])]
                  [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)])])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprArrayData array-box)
      (let
        [array : AstExpr (box-get array-box)]
        (match (tc-spmd-expr ctx env spmd-env array)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]
    [(AstExprProgramArgc) (tc-spmd-finish expr-ty TcSpmdUniform spmd-env)]
    [(AstExprProgramArgv) (tc-spmd-finish expr-ty TcSpmdUniform spmd-env)]
    [(AstExprProgramEnvp) (tc-spmd-finish expr-ty TcSpmdUniform spmd-env)]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (tc-spmd-cpuid-like ctx env spmd-env expr-ty leaf subleaf))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (tc-spmd-cpuid-like ctx env spmd-env expr-ty leaf subleaf))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (tc-spmd-cpuid-like ctx env spmd-env expr-ty leaf subleaf))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (tc-spmd-cpuid-like ctx env spmd-env expr-ty leaf subleaf))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (box-get index-box)]
        (match (tc-spmd-expr ctx env spmd-env index)
          [(OkTcSpmdExprInfo info)
            (match info
              [(TcSpmdExprInfo _ class next-spmd-env)
                (tc-spmd-finish expr-ty class next-spmd-env)])]
          [(ErrTcSpmdExprInfo message) (ErrTcSpmdExprInfo message)]))]))

(define (tc-param-list-add-bound-names
  [params : AstParamList]
  [bound : TcStringList]) : TcStringList
  (match params
    [(AstParamNil) bound]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam name _ _)
            (tc-param-list-add-bound-names rest (tc-string-list-add bound name))]))]))

(define (tc-param-bound-names [params : AstParamList]) : TcStringList
  (tc-param-list-add-bound-names params TcStringNil))

(define (tc-pattern-add-bound-names
  [pattern : AstPattern]
  [bound : TcStringList]) : TcStringList
  (match pattern
    [(AstPatVar name _) (tc-string-list-add bound name)]
    [(AstPatTuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (tc-pattern-list-add-bound-names patterns bound))]
    [(AstPatWildcard) bound]
    [(AstPatBinding name) (tc-string-list-add bound name)]
    [(AstPatVariant _ patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (tc-pattern-list-add-bound-names patterns bound))]
    [(AstPatLiteral _) bound]))

(define (tc-pattern-list-add-bound-names
  [patterns : AstPatternList]
  [bound : TcStringList]) : TcStringList
  (match patterns
    [(AstPatternNil) bound]
    [(AstPatternCons pattern rest)
      (let
        [pattern : AstPattern (box-get pattern)]
        [rest : AstPatternList (box-get rest)]
        (tc-pattern-list-add-bound-names
          rest
          (tc-pattern-add-bound-names pattern bound)))]))

(define (tc-let-binding-list-add-bound-names
  [bindings : AstLetBindingList]
  [bound : TcStringList]) : TcStringList
  (match bindings
    [(AstLetBindingNil) bound]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name _ _)
            (tc-let-binding-list-add-bound-names
              rest
              (tc-string-list-add bound name))]))]))

(define (tc-resource-binding-list-add-bound-names
  [bindings : AstResourceBindingList]
  [bound : TcStringList]) : TcStringList
  (match bindings
    [(AstResourceBindingNil) bound]
    [(AstResourceBindingCons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding name _ _)
            (tc-resource-binding-list-add-bound-names
              rest
              (tc-string-list-add bound name))]))]))

(define (tc-expr-list-uses-free-name?
  [exprs : AstExprList]
  [name : String]
  [bound : TcStringList]) : bool
  (match exprs
    [(AstExprNil) false]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (box-get expr)]
        [rest : AstExprList (box-get rest)]
        (or
          (tc-expr-uses-free-name? expr name bound)
          (tc-expr-list-uses-free-name? rest name bound)))]))

(define (tc-let-binding-list-uses-free-name?
  [bindings : AstLetBindingList]
  [name : String]
  [bound : TcStringList]) : bool
  (match bindings
    [(AstLetBindingNil) false]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding bind-name _ init-box)
            (let
              [init : AstExpr (box-get init-box)]
              (or
                (tc-expr-uses-free-name? init name bound)
                (tc-let-binding-list-uses-free-name?
                  rest
                  name
                  (tc-string-list-add bound bind-name))))]))]))

(define (tc-resource-binding-list-uses-free-name?
  [bindings : AstResourceBindingList]
  [name : String]
  [bound : TcStringList]) : bool
  (match bindings
    [(AstResourceBindingNil) false]
    [(AstResourceBindingCons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding bind-name init-box cleanup-box)
            (let
              [init : AstExpr (box-get init-box)]
              [cleanup : AstExpr (box-get cleanup-box)]
              (or
                (tc-expr-uses-free-name? init name bound)
                (or
                  (tc-expr-uses-free-name? cleanup name bound)
                  (tc-resource-binding-list-uses-free-name?
                    rest
                    name
                    (tc-string-list-add bound bind-name)))))]))]))

(define (tc-match-arms-use-free-name?
  [arms : AstMatchArmList]
  [name : String]
  [bound : TcStringList]) : bool
  (match arms
    [(AstMatchArmNil) false]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern body-box)
            (let
              [body : AstExpr (box-get body-box)]
              (or
                (tc-expr-uses-free-name?
                  body
                  name
                  (tc-pattern-add-bound-names pattern bound))
                (tc-match-arms-use-free-name? rest name bound)))]))]))

(define (tc-expr-uses-free-name?
  [expr : AstExpr]
  [name : String]
  [bound : TcStringList]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-uses-free-name? inner name bound))]
    [(AstExprLiteral _) false]
    [(AstExprVar var-name)
      (and (string-eq var-name name) (not (tc-string-list-contains bound name)))]
    [(AstExprBinary _ left-box right-box)
      (let
        [left : AstExpr (box-get left-box)]
        [right : AstExpr (box-get right-box)]
        (or
          (tc-expr-uses-free-name? left name bound)
          (tc-expr-uses-free-name? right name bound)))]
    [(AstExprUnary _ inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-uses-free-name? inner name bound))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (box-get func-box)]
        (or
          (tc-expr-uses-free-name? func name bound)
          (tc-expr-list-uses-free-name? args name bound)))]
    [(AstExprTypeLiteral _) false]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [then-branch : AstExpr (box-get then-branch-box)]
        [else-branch : AstExpr (box-get else-branch-box)]
        (or
          (tc-expr-uses-free-name? cond name bound)
          (or
            (tc-expr-uses-free-name? then-branch name bound)
            (tc-expr-uses-free-name? else-branch name bound))))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (or
          (tc-let-binding-list-uses-free-name? bindings name bound)
          (tc-expr-uses-free-name?
            body
            name
            (tc-let-binding-list-add-bound-names bindings bound))))]
    [(AstExprLambda params _ body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (tc-expr-uses-free-name?
          body
          name
          (tc-param-list-add-bound-names params bound)))]
    [(AstExprTuple exprs) (tc-expr-list-uses-free-name? exprs name bound)]
    [(AstExprTupleRef tuple-box _)
      (let
        [tuple : AstExpr (box-get tuple-box)]
        (tc-expr-uses-free-name? tuple name bound))]
    [(AstExprArray exprs) (tc-expr-list-uses-free-name? exprs name bound)]
    [(AstExprMakeArray _ len-box)
      (let
        [len : AstExpr (box-get len-box)]
        (tc-expr-uses-free-name? len name bound))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        (or
          (tc-expr-uses-free-name? array name bound)
          (tc-expr-uses-free-name? index name bound)))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        [value : AstExpr (box-get value-box)]
        (or
          (tc-expr-uses-free-name? array name bound)
          (or
            (tc-expr-uses-free-name? index name bound)
            (tc-expr-uses-free-name? value name bound))))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (box-get array-box)]
        [value : AstExpr (box-get value-box)]
        (or
          (tc-expr-uses-free-name? array name bound)
          (tc-expr-uses-free-name? value name bound)))]
    [(AstExprStringRef str-box index-box)
      (let
        [str : AstExpr (box-get str-box)]
        [index : AstExpr (box-get index-box)]
        (or
          (tc-expr-uses-free-name? str name bound)
          (tc-expr-uses-free-name? index name bound)))]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [body : AstExpr (box-get body-box)]
        (or
          (tc-expr-uses-free-name? cond name bound)
          (tc-expr-uses-free-name? body name bound)))]
    [(AstExprBegin exprs) (tc-expr-list-uses-free-name? exprs name bound)]
    [(AstExprUnsafe exprs) (tc-expr-list-uses-free-name? exprs name bound)]
    [(AstExprSet var-name value-box)
      (let
        [value : AstExpr (box-get value-box)]
        (or
          (and
            (string-eq var-name name)
            (not (tc-string-list-contains bound name)))
          (tc-expr-uses-free-name? value name bound)))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-uses-free-name? inner name bound))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-uses-free-name? inner name bound))]
    [(AstExprBorrow _ place-box)
      (let
        [place : AstExpr (box-get place-box)]
        (tc-expr-uses-free-name? place name bound))]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-uses-free-name? inner name bound))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-uses-free-name? inner name bound))]
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (box-get scrutinee-box)]
        (or
          (tc-expr-uses-free-name? scrutinee name bound)
          (tc-match-arms-use-free-name? arms name bound)))]
    [(AstExprForeach index _ start-box end-box body-box)
      (let
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [body : AstExpr (box-get body-box)]
        (or
          (tc-expr-uses-free-name? start name bound)
          (or
            (tc-expr-uses-free-name? end name bound)
            (tc-expr-uses-free-name? body name (tc-string-list-add bound index)))))]
    [(AstExprSpmdReduce _ index _ start-box end-box init-box value-box)
      (let
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [init : AstExpr (box-get init-box)]
        [value : AstExpr (box-get value-box)]
        (or
          (tc-expr-uses-free-name? start name bound)
          (or
            (tc-expr-uses-free-name? end name bound)
            (or
              (tc-expr-uses-free-name? init name bound)
              (tc-expr-uses-free-name?
                value
                name
                (tc-string-list-add bound index))))))]
    [(AstExprStructGet receiver-box _)
      (let
        [receiver : AstExpr (box-get receiver-box)]
        (tc-expr-uses-free-name? receiver name bound))]
    [(AstExprWithRegion _ body) (tc-expr-list-uses-free-name? body name bound)]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (box-get scratch-box)]
        (or
          (tc-expr-uses-free-name? scratch name bound)
          (tc-expr-list-uses-free-name? body name bound)))]
    [(AstExprWithResource bindings body)
      (or
        (tc-resource-binding-list-uses-free-name? bindings name bound)
        (tc-expr-list-uses-free-name?
          body
          name
          (tc-resource-binding-list-add-bound-names bindings bound)))]
    [(AstExprTypeLiteral _) false]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-uses-free-name? inner name bound))]
    [(AstExprQuote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-uses-free-name? inner name bound))]
    [(AstExprQuasiquote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-uses-free-name? inner name bound))]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-uses-free-name? inner name bound))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-uses-free-name? inner name bound))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-uses-free-name? inner name bound))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-uses-free-name? inner name bound))]
    [(AstExprPtrNull _) false]
    [(AstExprPtrNullCheck inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-uses-free-name? inner name bound))]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (tc-expr-uses-free-name? ptr name bound))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [value : AstExpr (box-get value-box)]
        (or
          (tc-expr-uses-free-name? ptr name bound)
          (tc-expr-uses-free-name? value name bound)))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [offset : AstExpr (box-get offset-box)]
        (or
          (tc-expr-uses-free-name? ptr name bound)
          (tc-expr-uses-free-name? offset name bound)))]
    [(AstExprPtrCast ptr-box _)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (tc-expr-uses-free-name? ptr name bound))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (tc-expr-uses-free-name? ptr name bound))]
    [(AstExprIntToPtr value-box _)
      (let
        [value : AstExpr (box-get value-box)]
        (tc-expr-uses-free-name? value name bound))]
    [(AstExprStringData str-box)
      (let
        [str : AstExpr (box-get str-box)]
        (tc-expr-uses-free-name? str name bound))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [len : AstExpr (box-get len-box)]
        (or
          (tc-expr-uses-free-name? ptr name bound)
          (tc-expr-uses-free-name? len name bound)))]
    [(AstExprArrayData array-box)
      (let
        [array : AstExpr (box-get array-box)]
        (tc-expr-uses-free-name? array name bound))]
    [(AstExprProgramArgc) false]
    [(AstExprProgramArgv) false]
    [(AstExprProgramEnvp) false]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (or
          (tc-expr-uses-free-name? leaf name bound)
          (tc-expr-uses-free-name? subleaf name bound)))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (or
          (tc-expr-uses-free-name? leaf name bound)
          (tc-expr-uses-free-name? subleaf name bound)))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (or
          (tc-expr-uses-free-name? leaf name bound)
          (tc-expr-uses-free-name? subleaf name bound)))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (or
          (tc-expr-uses-free-name? leaf name bound)
          (tc-expr-uses-free-name? subleaf name bound)))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (box-get index-box)]
        (tc-expr-uses-free-name? index name bound))]))

;; Same shadowing rules as `tc-expr-uses-free-name?`, but it only returns true
;; when the expression assigns to the free name. Lambda capture checks use this
;; to reject mutation of captured bindings while allowing local parameter/let
;; assignment inside the lambda.
(define (tc-expr-list-sets-free-name?
  [exprs : AstExprList]
  [name : String]
  [bound : TcStringList]) : bool
  (match exprs
    [(AstExprNil) false]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (box-get expr)]
        [rest : AstExprList (box-get rest)]
        (or
          (tc-expr-sets-free-name? expr name bound)
          (tc-expr-list-sets-free-name? rest name bound)))]))

(define (tc-let-binding-list-sets-free-name?
  [bindings : AstLetBindingList]
  [name : String]
  [bound : TcStringList]) : bool
  (match bindings
    [(AstLetBindingNil) false]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding bind-name _ init-box)
            (let
              [init : AstExpr (box-get init-box)]
              (or
                (tc-expr-sets-free-name? init name bound)
                (tc-let-binding-list-sets-free-name?
                  rest
                  name
                  (tc-string-list-add bound bind-name))))]))]))

(define (tc-resource-binding-list-sets-free-name?
  [bindings : AstResourceBindingList]
  [name : String]
  [bound : TcStringList]) : bool
  (match bindings
    [(AstResourceBindingNil) false]
    [(AstResourceBindingCons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding bind-name init-box cleanup-box)
            (let
              [init : AstExpr (box-get init-box)]
              [cleanup : AstExpr (box-get cleanup-box)]
              (or
                (tc-expr-sets-free-name? init name bound)
                (or
                  (tc-expr-sets-free-name? cleanup name bound)
                  (tc-resource-binding-list-sets-free-name?
                    rest
                    name
                    (tc-string-list-add bound bind-name)))))]))]))

(define (tc-match-arms-set-free-name?
  [arms : AstMatchArmList]
  [name : String]
  [bound : TcStringList]) : bool
  (match arms
    [(AstMatchArmNil) false]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern body-box)
            (let
              [body : AstExpr (box-get body-box)]
              (or
                (tc-expr-sets-free-name?
                  body
                  name
                  (tc-pattern-add-bound-names pattern bound))
                (tc-match-arms-set-free-name? rest name bound)))]))]))

(define (tc-expr-sets-free-name?
  [expr : AstExpr]
  [name : String]
  [bound : TcStringList]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-sets-free-name? inner name bound))]
    [(AstExprLiteral _) false]
    [(AstExprVar _) false]
    [(AstExprBinary _ left-box right-box)
      (let
        [left : AstExpr (box-get left-box)]
        [right : AstExpr (box-get right-box)]
        (or
          (tc-expr-sets-free-name? left name bound)
          (tc-expr-sets-free-name? right name bound)))]
    [(AstExprUnary _ inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-sets-free-name? inner name bound))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (box-get func-box)]
        (or
          (tc-expr-sets-free-name? func name bound)
          (tc-expr-list-sets-free-name? args name bound)))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [then-branch : AstExpr (box-get then-branch-box)]
        [else-branch : AstExpr (box-get else-branch-box)]
        (or
          (tc-expr-sets-free-name? cond name bound)
          (or
            (tc-expr-sets-free-name? then-branch name bound)
            (tc-expr-sets-free-name? else-branch name bound))))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (or
          (tc-let-binding-list-sets-free-name? bindings name bound)
          (tc-expr-sets-free-name?
            body
            name
            (tc-let-binding-list-add-bound-names bindings bound))))]
    [(AstExprLambda params _ body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (tc-expr-sets-free-name?
          body
          name
          (tc-param-list-add-bound-names params bound)))]
    [(AstExprTuple exprs) (tc-expr-list-sets-free-name? exprs name bound)]
    [(AstExprTupleRef tuple-box _)
      (let
        [tuple : AstExpr (box-get tuple-box)]
        (tc-expr-sets-free-name? tuple name bound))]
    [(AstExprArray exprs) (tc-expr-list-sets-free-name? exprs name bound)]
    [(AstExprMakeArray _ len-box)
      (let
        [len : AstExpr (box-get len-box)]
        (tc-expr-sets-free-name? len name bound))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        (or
          (tc-expr-sets-free-name? array name bound)
          (tc-expr-sets-free-name? index name bound)))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        [value : AstExpr (box-get value-box)]
        (or
          (tc-expr-sets-free-name? array name bound)
          (or
            (tc-expr-sets-free-name? index name bound)
            (tc-expr-sets-free-name? value name bound))))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (box-get array-box)]
        [value : AstExpr (box-get value-box)]
        (or
          (tc-expr-sets-free-name? array name bound)
          (tc-expr-sets-free-name? value name bound)))]
    [(AstExprStringRef str-box index-box)
      (let
        [str : AstExpr (box-get str-box)]
        [index : AstExpr (box-get index-box)]
        (or
          (tc-expr-sets-free-name? str name bound)
          (tc-expr-sets-free-name? index name bound)))]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [body : AstExpr (box-get body-box)]
        (or
          (tc-expr-sets-free-name? cond name bound)
          (tc-expr-sets-free-name? body name bound)))]
    [(AstExprBegin exprs) (tc-expr-list-sets-free-name? exprs name bound)]
    [(AstExprUnsafe exprs) (tc-expr-list-sets-free-name? exprs name bound)]
    [(AstExprSet var-name value-box)
      (let
        [value : AstExpr (box-get value-box)]
        (or
          (and
            (string-eq var-name name)
            (not (tc-string-list-contains bound name)))
          (tc-expr-sets-free-name? value name bound)))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-sets-free-name? inner name bound))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-sets-free-name? inner name bound))]
    [(AstExprBorrow _ place-box)
      (let
        [place : AstExpr (box-get place-box)]
        (tc-expr-sets-free-name? place name bound))]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-sets-free-name? inner name bound))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-sets-free-name? inner name bound))]
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (box-get scrutinee-box)]
        (or
          (tc-expr-sets-free-name? scrutinee name bound)
          (tc-match-arms-set-free-name? arms name bound)))]
    [(AstExprForeach index _ start-box end-box body-box)
      (let
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [body : AstExpr (box-get body-box)]
        (or
          (tc-expr-sets-free-name? start name bound)
          (or
            (tc-expr-sets-free-name? end name bound)
            (tc-expr-sets-free-name? body name (tc-string-list-add bound index)))))]
    [(AstExprSpmdReduce _ index _ start-box end-box init-box value-box)
      (let
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [init : AstExpr (box-get init-box)]
        [value : AstExpr (box-get value-box)]
        (or
          (tc-expr-sets-free-name? start name bound)
          (or
            (tc-expr-sets-free-name? end name bound)
            (or
              (tc-expr-sets-free-name? init name bound)
              (tc-expr-sets-free-name?
                value
                name
                (tc-string-list-add bound index))))))]
    [(AstExprStructGet receiver-box _)
      (let
        [receiver : AstExpr (box-get receiver-box)]
        (tc-expr-sets-free-name? receiver name bound))]
    [(AstExprWithRegion _ body) (tc-expr-list-sets-free-name? body name bound)]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (box-get scratch-box)]
        (or
          (tc-expr-sets-free-name? scratch name bound)
          (tc-expr-list-sets-free-name? body name bound)))]
    [(AstExprWithResource bindings body)
      (or
        (tc-resource-binding-list-sets-free-name? bindings name bound)
        (tc-expr-list-sets-free-name?
          body
          name
          (tc-resource-binding-list-add-bound-names bindings bound)))]
    [(AstExprTypeLiteral _) false]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-sets-free-name? inner name bound))]
    [(AstExprQuote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-sets-free-name? inner name bound))]
    [(AstExprQuasiquote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-sets-free-name? inner name bound))]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-sets-free-name? inner name bound))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-sets-free-name? inner name bound))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-sets-free-name? inner name bound))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-sets-free-name? inner name bound))]
    [(AstExprPtrNull _) false]
    [(AstExprPtrNullCheck inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-sets-free-name? inner name bound))]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (tc-expr-sets-free-name? ptr name bound))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [value : AstExpr (box-get value-box)]
        (or
          (tc-expr-sets-free-name? ptr name bound)
          (tc-expr-sets-free-name? value name bound)))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [offset : AstExpr (box-get offset-box)]
        (or
          (tc-expr-sets-free-name? ptr name bound)
          (tc-expr-sets-free-name? offset name bound)))]
    [(AstExprPtrCast ptr-box _)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (tc-expr-sets-free-name? ptr name bound))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (tc-expr-sets-free-name? ptr name bound))]
    [(AstExprIntToPtr value-box _)
      (let
        [value : AstExpr (box-get value-box)]
        (tc-expr-sets-free-name? value name bound))]
    [(AstExprStringData str-box)
      (let
        [str : AstExpr (box-get str-box)]
        (tc-expr-sets-free-name? str name bound))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [len : AstExpr (box-get len-box)]
        (or
          (tc-expr-sets-free-name? ptr name bound)
          (tc-expr-sets-free-name? len name bound)))]
    [(AstExprArrayData array-box)
      (let
        [array : AstExpr (box-get array-box)]
        (tc-expr-sets-free-name? array name bound))]
    [(AstExprProgramArgc) false]
    [(AstExprProgramArgv) false]
    [(AstExprProgramEnvp) false]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (or
          (tc-expr-sets-free-name? leaf name bound)
          (tc-expr-sets-free-name? subleaf name bound)))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (or
          (tc-expr-sets-free-name? leaf name bound)
          (tc-expr-sets-free-name? subleaf name bound)))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (or
          (tc-expr-sets-free-name? leaf name bound)
          (tc-expr-sets-free-name? subleaf name bound)))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (or
          (tc-expr-sets-free-name? leaf name bound)
          (tc-expr-sets-free-name? subleaf name bound)))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (box-get index-box)]
        (tc-expr-sets-free-name? index name bound))]))

(define (tc-name-is-free-cleanup-owner?
  [owners : TcStringList]
  [name : String]
  [bound : TcStringList]) : bool
  (and
    (tc-string-list-contains owners name)
    (not (tc-string-list-contains bound name))))

(define (tc-expr-list-result-uses-cleanup-owner?
  [exprs : AstExprList]
  [owners : TcStringList]
  [bound : TcStringList]) : bool
  (match exprs
    [(AstExprNil) false]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (box-get expr)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil) (tc-expr-result-uses-cleanup-owner? expr owners bound)]
          [_ (tc-expr-list-result-uses-cleanup-owner? rest owners bound)]))]))

(define (tc-expr-list-any-result-uses-cleanup-owner?
  [exprs : AstExprList]
  [owners : TcStringList]
  [bound : TcStringList]) : bool
  (match exprs
    [(AstExprNil) false]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (box-get expr)]
        [rest : AstExprList (box-get rest)]
        (or
          (tc-expr-result-uses-cleanup-owner? expr owners bound)
          (tc-expr-list-any-result-uses-cleanup-owner? rest owners bound)))]))

(define (tc-match-arms-result-use-cleanup-owner?
  [arms : AstMatchArmList]
  [owners : TcStringList]
  [bound : TcStringList]) : bool
  (match arms
    [(AstMatchArmNil) false]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern body-box)
            (let
              [body : AstExpr (box-get body-box)]
              (or
                (tc-expr-result-uses-cleanup-owner?
                  body
                  owners
                  (tc-pattern-add-bound-names pattern bound))
                (tc-match-arms-result-use-cleanup-owner? rest owners bound)))]))]))

(define (tc-expr-result-uses-cleanup-owner?
  [expr : AstExpr]
  [owners : TcStringList]
  [bound : TcStringList]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-result-uses-cleanup-owner? inner owners bound))]
    [(AstExprVar name) (tc-name-is-free-cleanup-owner? owners name bound)]
    [(AstExprIf _ then-branch-box else-branch-box)
      (let
        [then-branch : AstExpr (box-get then-branch-box)]
        [else-branch : AstExpr (box-get else-branch-box)]
        (or
          (tc-expr-result-uses-cleanup-owner? then-branch owners bound)
          (tc-expr-result-uses-cleanup-owner? else-branch owners bound)))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (tc-expr-result-uses-cleanup-owner?
          body
          owners
          (tc-let-binding-list-add-bound-names bindings bound)))]
    [(AstExprMatch _ arms)
      (tc-match-arms-result-use-cleanup-owner? arms owners bound)]
    [(AstExprForeach index _ _ _ body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (tc-expr-result-uses-cleanup-owner?
          body
          owners
          (tc-string-list-add bound index)))]
    [(AstExprSpmdReduce _ index _ _ _ _ value-box)
      (let
        [value : AstExpr (box-get value-box)]
        (tc-expr-result-uses-cleanup-owner?
          value
          owners
          (tc-string-list-add bound index)))]
    [(AstExprBegin exprs)
      (tc-expr-list-result-uses-cleanup-owner? exprs owners bound)]
    [(AstExprUnsafe exprs)
      (tc-expr-list-result-uses-cleanup-owner? exprs owners bound)]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-result-uses-cleanup-owner? inner owners bound))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-result-uses-cleanup-owner? inner owners bound))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-result-uses-cleanup-owner? inner owners bound))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-result-uses-cleanup-owner? inner owners bound))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-result-uses-cleanup-owner? inner owners bound))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr-result-uses-cleanup-owner? inner owners bound))]
    [(AstExprWithRegion _ body)
      (tc-expr-list-result-uses-cleanup-owner? body owners bound)]
    [(AstExprWithEscape _ body)
      (tc-expr-list-result-uses-cleanup-owner? body owners bound)]
    [(AstExprWithResource bindings body)
      (tc-expr-list-result-uses-cleanup-owner?
        body
        owners
        (tc-resource-binding-list-add-bound-names bindings bound))]
    [_ false]))

(define (tc-expr-result-uses-active-cleanup-owner?
  [env : TcTypeEnv]
  [expr : AstExpr]) : bool
  (tc-expr-result-uses-cleanup-owner?
    expr
    (tc-active-cleanup-owners env)
    TcStringNil))

(define (tc-expr-list-any-result-uses-active-cleanup-owner?
  [env : TcTypeEnv]
  [exprs : AstExprList]) : bool
  (tc-expr-list-any-result-uses-cleanup-owner?
    exprs
    (tc-active-cleanup-owners env)
    TcStringNil))

(define (tc-ensure-cleanup-resource-not-let-bound
  [env : TcTypeEnv]
  [expr : AstExpr]) : ResultTcUnit
  (if (tc-expr-result-uses-active-cleanup-owner? env expr)
    (ErrTcUnit
      "typecheck: ordinary let cannot own cleanup-required resource; use with")
    OkTcUnit))

(define (tc-ensure-cleanup-resource-not-transferred
  [env : TcTypeEnv]
  [expr : AstExpr]) : ResultTcUnit
  (if (tc-expr-result-uses-active-cleanup-owner? env expr)
    (ErrTcUnit
      "typecheck: cleanup-required resource already has a cleanup owner")
    OkTcUnit))

(define (tc-ensure-cleanup-resource-not-stored-expr
  [env : TcTypeEnv]
  [expr : AstExpr]) : ResultTcUnit
  (if (tc-expr-result-uses-active-cleanup-owner? env expr)
    (ErrTcUnit
      "typecheck: cannot store cleanup-required resource in ordinary aggregate")
    OkTcUnit))

(define (tc-ensure-cleanup-resource-not-stored-list
  [env : TcTypeEnv]
  [exprs : AstExprList]) : ResultTcUnit
  (if (tc-expr-list-any-result-uses-active-cleanup-owner? env exprs)
    (ErrTcUnit
      "typecheck: cannot store cleanup-required resource in ordinary aggregate")
    OkTcUnit))

(define (tc-ensure-cleanup-resource-not-assigned
  [env : TcTypeEnv]
  [expr : AstExpr]) : ResultTcUnit
  (if (tc-expr-result-uses-active-cleanup-owner? env expr)
    (ErrTcUnit
      "typecheck: cannot store cleanup-required resource in longer-lived binding")
    OkTcUnit))

(define (tc-check-lambda-region-captures-scan-root
  [root : TcTypeEnv]
  [env : TcTypeEnv]
  [bound : TcStringList]
  [body : AstExpr]) : ResultTcUnit
  (match env
    [(TcTypeNil) OkTcUnit]
    [(TcTypeCache _ _ _ _ _) OkTcUnit]
    [(TcTypeBind key ty rest)
      (cond
        [(or
            (string-eq key (tc-region-marker-name))
            (or
              (string-eq key (tc-default-boundary-name))
              (tc-cleanup-owner-marker-entry? key ty)))
          (tc-check-lambda-region-captures-scan-root
            root
            (box-get rest)
            bound
            body)]
        [(not (tc-expr-uses-free-name? body key bound))
          (tc-check-lambda-region-captures-scan-root
            root
            (box-get rest)
            bound
            body)]
        [(tc-expr-sets-free-name? body key bound)
          (ErrTcUnit "typecheck: lambda cannot assign captured binding")]
        [(tc-cleanup-owner-active? root key)
          (ErrTcUnit
            "typecheck: lambda cannot capture cleanup-required resource; resource value would escape")]
        [(tc-type-contains-reference? ty)
          (ErrTcUnit
            "typecheck: lambda cannot capture immutable reference; reference value would escape lexical scope")]
        [(tc-type-contains-any-region ty)
          (ErrTcUnit
            "typecheck: lambda cannot capture region-tagged value; region value would escape")]
        [else
          (tc-check-lambda-region-captures-scan-root
            root
            (box-get rest)
            bound
            body)])]))

(define (tc-check-lambda-region-captures-scan
  [env : TcTypeEnv]
  [bound : TcStringList]
  [body : AstExpr]) : ResultTcUnit
  (tc-check-lambda-region-captures-scan-root env env bound body))

(define (tc-check-lambda-region-captures
  [env : TcTypeEnv]
  [params : AstParamList]
  [body : AstExpr]) : ResultTcUnit
  (tc-check-lambda-region-captures-scan env (tc-param-bound-names params) body))

(define (tc-context-program [ctx : TcContext]) : AstProgram
  (match ctx
    [(TcContext program _ _ _) program]))

(define (tc-context-symbols [ctx : TcContext]) : CompilerSymbols
  (match ctx
    [(TcContext _ symbols _ _) symbols]))

(define (tc-context-registries [ctx : TcContext]) : CompilerRegistries
  (match ctx
    [(TcContext _ _ registries _) registries]))

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
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule next-module)
            (tc-program-enum-variants-list-in-module rest enum-name next-module)]
          [(AstDeclDefEnum name variants)
            (if (or
              (string-eq name enum-name)
              (string-eq (compiler-symbol-module-key module name) enum-name))
              (OkAstVariantDefList variants)
              (tc-program-enum-variants-list-in-module rest enum-name module))]
          [(AstDeclDefEnumLifetimes name _ variants)
            (if (or
              (string-eq name enum-name)
              (string-eq (compiler-symbol-module-key module name) enum-name))
              (OkAstVariantDefList variants)
              (tc-program-enum-variants-list-in-module rest enum-name module))]
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (match template
                [(AstDeclDefEnum name variants)
                  (if (or
                    (string-eq name enum-name)
                    (string-eq
                      (compiler-symbol-module-key module name)
                      enum-name))
                    (OkAstVariantDefList variants)
                    (tc-program-enum-variants-list-in-module
                      rest
                      enum-name
                      module))]
                [(AstDeclDefEnumLifetimes name _ variants)
                  (if (or
                    (string-eq name enum-name)
                    (string-eq
                      (compiler-symbol-module-key module name)
                      enum-name))
                    (OkAstVariantDefList variants)
                    (tc-program-enum-variants-list-in-module
                      rest
                      enum-name
                      module))]
                [_
                  (tc-program-enum-variants-list-in-module
                    rest
                    enum-name
                    module)]))]
          [_ (tc-program-enum-variants-list-in-module rest enum-name module)]))]))

(define (tc-program-enum-variants [program : AstProgram] [enum-name : String]) : ResultAstVariantDefList
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (tc-program-enum-variants-list decls enum-name))]))

(define (tc-context-enum-variants [ctx : TcContext] [enum-name : String]) : ResultAstVariantDefList
  (match (compiler-symbols-lookup-type (tc-context-symbols ctx) enum-name)
    [(SomeI64 handle)
      (if (=
        (compiler-symbol-handle-kind handle)
        (compiler-symbol-kind-defenum))
        (match (compiler-symbols-decl-at-index
          (tc-context-symbols ctx)
          (compiler-symbol-handle-index handle))
          [(OkAstDecl decl)
            (match decl
              [(AstDeclDefEnum _ variants) (OkAstVariantDefList variants)]
              [(AstDeclDefEnumLifetimes _ _ variants)
                (OkAstVariantDefList variants)]
              [_
                (ErrAstVariantDefList
                  (string-append "typecheck: unknown enum " enum-name))])]
          [(ErrAstDecl message) (ErrAstVariantDefList message)])
        (ErrAstVariantDefList
          (string-append "typecheck: unknown enum " enum-name)))]
    [(NoneI64) (tc-program-enum-variants (tc-context-program ctx) enum-name)]))

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
        (tc-repr-c-layout-field-offset (box-get rest) name))]))

(define (tc-inline-field-layout-name [field : TcInlineFieldLayout]) : String
  (match field
    [(TcInlineFieldLayout name _ _) name]))

(define (tc-inline-field-layout-type [field : TcInlineFieldLayout]) : AstType
  (match field
    [(TcInlineFieldLayout _ ty _) ty]))

(define (tc-inline-field-layout-offset [field : TcInlineFieldLayout]) : i64
  (match field
    [(TcInlineFieldLayout _ _ offset) offset]))

(define (tc-inline-field-layout-list-offset
  [fields : TcInlineFieldLayoutList]
  [name : String]) : i64
  (match fields
    [(TcInlineFieldLayoutNil) -1]
    [(TcInlineFieldLayoutCons field rest)
      (if (string-eq (tc-inline-field-layout-name field) name)
        (tc-inline-field-layout-offset field)
        (tc-inline-field-layout-list-offset (box-get rest) name))]))

(define (tc-inline-payload-layout-index [payload : TcInlinePayloadLayout]) : i64
  (match payload
    [(TcInlinePayloadLayout index _ _) index]))

(define (tc-inline-payload-layout-type [payload : TcInlinePayloadLayout]) : AstType
  (match payload
    [(TcInlinePayloadLayout _ ty _) ty]))

(define (tc-inline-payload-layout-offset [payload : TcInlinePayloadLayout]) : i64
  (match payload
    [(TcInlinePayloadLayout _ _ offset) offset]))

(define (tc-inline-payload-layout-list-offset
  [payloads : TcInlinePayloadLayoutList]
  [index : i64]) : i64
  (match payloads
    [(TcInlinePayloadLayoutNil) -1]
    [(TcInlinePayloadLayoutCons payload rest)
      (if (= (tc-inline-payload-layout-index payload) index)
        (tc-inline-payload-layout-offset payload)
        (tc-inline-payload-layout-list-offset (box-get rest) index))]))

(define (tc-inline-variant-layout-name [variant : TcInlineVariantLayout]) : String
  (match variant
    [(TcInlineVariantLayout name _ _ _) name]))

(define (tc-inline-variant-layout-size [variant : TcInlineVariantLayout]) : i64
  (match variant
    [(TcInlineVariantLayout _ size _ _) size]))

(define (tc-inline-variant-layout-align [variant : TcInlineVariantLayout]) : i64
  (match variant
    [(TcInlineVariantLayout _ _ align _) align]))

(define (tc-inline-variant-layout-payloads [variant : TcInlineVariantLayout]) : TcInlinePayloadLayoutList
  (match variant
    [(TcInlineVariantLayout _ _ _ payloads) payloads]))

(define (tc-inline-variant-layout-list-size
  [variants : TcInlineVariantLayoutList]
  [name : String]) : i64
  (match variants
    [(TcInlineVariantLayoutNil) -1]
    [(TcInlineVariantLayoutCons variant rest)
      (if (string-eq (tc-inline-variant-layout-name variant) name)
        (tc-inline-variant-layout-size variant)
        (tc-inline-variant-layout-list-size (box-get rest) name))]))

(define (tc-inline-variant-layout-list-payload-offset
  [variants : TcInlineVariantLayoutList]
  [name : String]
  [index : i64]) : i64
  (match variants
    [(TcInlineVariantLayoutNil) -1]
    [(TcInlineVariantLayoutCons variant rest)
      (if (string-eq (tc-inline-variant-layout-name variant) name)
        (tc-inline-payload-layout-list-offset
          (tc-inline-variant-layout-payloads variant)
          index)
        (tc-inline-variant-layout-list-payload-offset (box-get rest) name index))]))

(define (tc-inline-aggregate-layout-size [layout : TcInlineAggregateLayout]) : i64
  (match layout
    [(TcInlineStructLayout size _ _) size]
    [(TcInlineEnumLayout size _ _) size]))

(define (tc-inline-aggregate-layout-align [layout : TcInlineAggregateLayout]) : i64
  (match layout
    [(TcInlineStructLayout _ align _) align]
    [(TcInlineEnumLayout _ align _) align]))

(define (tc-inline-aggregate-layout-field-offset
  [layout : TcInlineAggregateLayout]
  [name : String]) : i64
  (match layout
    [(TcInlineStructLayout _ _ fields)
      (tc-inline-field-layout-list-offset fields name)]
    [(TcInlineEnumLayout _ _ _) -1]))

(define (tc-inline-aggregate-layout-variant-size
  [layout : TcInlineAggregateLayout]
  [name : String]) : i64
  (match layout
    [(TcInlineStructLayout _ _ _) -1]
    [(TcInlineEnumLayout _ _ variants)
      (tc-inline-variant-layout-list-size variants name)]))

(define (tc-inline-aggregate-layout-variant-payload-offset
  [layout : TcInlineAggregateLayout]
  [name : String]
  [index : i64]) : i64
  (match layout
    [(TcInlineStructLayout _ _ _) -1]
    [(TcInlineEnumLayout _ _ variants)
      (tc-inline-variant-layout-list-payload-offset variants name index)]))

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
    [(TcContext _ symbols _ _)
      (match (compiler-symbols-lookup-type symbols struct-name)
        [(SomeI64 handle)
          (if (=
            (compiler-symbol-handle-kind handle)
            (compiler-symbol-kind-defstruct))
            (match (compiler-symbols-decl-at-index
              symbols
              (compiler-symbol-handle-index handle))
              [(OkAstDecl decl)
                (match decl
                  [(AstDeclDefStruct _ repr cleanup fields)
                    (OkTcStructDecl (TcStructDecl repr cleanup fields))]
                  [(AstDeclDefStructLifetimes _ _ repr cleanup fields)
                    (OkTcStructDecl (TcStructDecl repr cleanup fields))]
                  [_
                    (ErrTcStructDecl
                      "typecheck: struct symbol owner is not a struct")])]
              [(ErrAstDecl message) (ErrTcStructDecl message)])
            (ErrTcStructDecl
              (string-append "typecheck: unknown struct " struct-name)))]
        [(NoneI64)
          (ErrTcStructDecl
            (string-append "typecheck: unknown struct " struct-name))])]))

(define (tc-inline-aggregate-cycle-stack-render [stack : TcStringList]) : String
  (match stack
    [(TcStringNil) ""]
    [(TcStringCons head rest)
      (let
        [tail : String (tc-inline-aggregate-cycle-stack-render (box-get rest))]
        (if (string-eq tail "")
          head
          (tc-cat3 tail " -> " head)))]))

(define (tc-inline-aggregate-cycle-path [stack : TcStringList] [name : String]) : String
  (let
    [prefix : String (tc-inline-aggregate-cycle-stack-render stack)]
    (if (string-eq prefix "")
      name
      (tc-cat3 prefix " -> " name))))

(define (tc-inline-aggregate-cycle-message
  [name : String]
  [stack : TcStringList]) : String
  (tc-cat3
    "typecheck: inline aggregate layout cycle "
    (tc-inline-aggregate-cycle-path stack name)
    (tc-cat3 "; insert (Box " name ") at the recursive edge")))

(define (tc-inline-aggregate-type-list-finite-ok
  [ctx : TcContext]
  [types : AstTypeList]
  [stack : TcStringList]) : ResultTcUnit
  (match types
    [(AstTypeNil) OkTcUnit]
    [(AstTypeCons head rest)
      (let
        [head : AstType (box-get head)]
        [rest : AstTypeList (box-get rest)]
        (match (tc-inline-aggregate-type-finite-ok ctx head stack)
          [(OkTcUnit) (tc-inline-aggregate-type-list-finite-ok ctx rest stack)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]))

(define (tc-inline-aggregate-fields-finite-ok
  [ctx : TcContext]
  [fields : AstFieldDefList]
  [stack : TcStringList]) : ResultTcUnit
  (match fields
    [(AstFieldDefNil) OkTcUnit]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef _ ty _)
            (match (tc-inline-aggregate-type-finite-ok ctx ty stack)
              [(OkTcUnit) (tc-inline-aggregate-fields-finite-ok ctx rest stack)]
              [(ErrTcUnit message) (ErrTcUnit message)])]))]))

(define (tc-inline-aggregate-variants-finite-ok
  [ctx : TcContext]
  [variants : AstVariantDefList]
  [stack : TcStringList]) : ResultTcUnit
  (match variants
    [(AstVariantDefNil) OkTcUnit]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef _ fields)
            (match (tc-inline-aggregate-type-list-finite-ok ctx fields stack)
              [(OkTcUnit)
                (tc-inline-aggregate-variants-finite-ok ctx rest stack)]
              [(ErrTcUnit message) (ErrTcUnit message)])]))]))

(define (tc-inline-aggregate-nominal-finite-ok
  [ctx : TcContext]
  [name : String]
  [stack : TcStringList]) : ResultTcUnit
  (if (tc-string-list-contains stack name)
    (ErrTcUnit (tc-inline-aggregate-cycle-message name stack))
    (match (compiler-symbols-lookup-type (tc-context-symbols ctx) name)
      [(SomeI64 handle)
        (if (=
          (compiler-symbol-handle-kind handle)
          (compiler-symbol-kind-defenum))
          (match (tc-context-enum-variants ctx name)
            [(OkAstVariantDefList variants)
              (tc-inline-aggregate-variants-finite-ok
                ctx
                variants
                (TcStringCons name (box stack)))]
            [(ErrAstVariantDefList message) (ErrTcUnit message)])
          (if (=
            (compiler-symbol-handle-kind handle)
            (compiler-symbol-kind-defstruct))
            (match (tc-struct-decl ctx name)
              [(OkTcStructDecl decl)
                (match decl
                  [(TcStructDecl _ _ fields)
                    (tc-inline-aggregate-fields-finite-ok
                      ctx
                      fields
                      (TcStringCons name (box stack)))])]
              [(ErrTcStructDecl message) (ErrTcUnit message)])
            (ErrTcUnit (string-append "typecheck: unknown aggregate " name))))]
      [(NoneI64)
        (ErrTcUnit (string-append "typecheck: unknown aggregate " name))])))

(define (tc-inline-aggregate-type-finite-ok
  [ctx : TcContext]
  [ty : AstType]
  [stack : TcStringList]) : ResultTcUnit
  (match (tc-type-strip-region (tc-resolve-type ctx ty))
    [(AstTyTuple elems)
      (tc-inline-aggregate-type-list-finite-ok ctx elems stack)]
    [(AstTyArray elem _)
      (tc-inline-aggregate-type-finite-ok ctx (box-get elem) stack)]
    [(AstTyEnum name) (tc-inline-aggregate-nominal-finite-ok ctx name stack)]
    [(AstTyEnumArgs name _)
      (tc-inline-aggregate-nominal-finite-ok ctx name stack)]
    [(AstTyStruct name) (tc-inline-aggregate-nominal-finite-ok ctx name stack)]
    [(AstTyStructArgs name _)
      (tc-inline-aggregate-nominal-finite-ok ctx name stack)]
    [_ OkTcUnit]))

(define (tc-inline-aggregate-layout-finite-ok [ctx : TcContext] [name : String]) : ResultTcUnit
  (tc-inline-aggregate-nominal-finite-ok ctx name TcStringNil))

(define (tc-inline-aggregate-layout-info [size : i64] [align : i64]) : TcLayoutInfo
  (TcLayoutInfo size align))

(define (tc-inline-aggregate-pointer-layout-info) : TcLayoutInfo
  (tc-inline-aggregate-layout-info 8 8))

(define (tc-inline-aggregate-zero-layout-info) : TcLayoutInfo
  (tc-inline-aggregate-layout-info 0 1))

(define (tc-inline-aggregate-finish-layout [cursor : i64] [max-align : i64]) : TcLayoutInfo
  (let
    [align : i64
      (if (= max-align 0)
        1
        max-align)]
    (tc-inline-aggregate-layout-info (tc-align-up cursor align) align)))

(define (tc-inline-aggregate-array-size
  [elem-size : i64]
  [elem-align : i64]
  [count : i64]) : i64
  (if (<= count 0)
    0
    (* (tc-align-up elem-size elem-align) count)))

(define (tc-inline-aggregate-type-list-layout-info
  [ctx : TcContext]
  [types : AstTypeList]
  [cursor : i64]
  [max-align : i64]
  [stack : TcStringList]) : ResultTcLayoutInfo
  (match types
    [(AstTypeNil)
      (OkTcLayoutInfo (tc-inline-aggregate-finish-layout cursor max-align))]
    [(AstTypeCons ty rest)
      (let
        [ty : AstType (box-get ty)]
        [rest : AstTypeList (box-get rest)]
        (match (tc-inline-aggregate-type-layout-with-stack ctx ty stack)
          [(OkTcLayoutInfo info)
            (let
              [field-align : i64 (tc-layout-info-align info)]
              [field-size : i64 (tc-layout-info-size info)]
              [offset : i64 (tc-align-up cursor field-align)]
              [next-cursor : i64 (+ offset field-size)]
              [next-align : i64 (tc-max-i64 max-align field-align)]
              (tc-inline-aggregate-type-list-layout-info
                ctx
                rest
                next-cursor
                next-align
                stack))]
          [(ErrTcLayoutInfo message) (ErrTcLayoutInfo message)]))]))

(define (tc-inline-aggregate-field-defs-layout
  [ctx : TcContext]
  [fields : AstFieldDefList]
  [cursor : i64]
  [max-align : i64]
  [stack : TcStringList]) : ResultTcInlineFieldsLayout
  (match fields
    [(AstFieldDefNil)
      (match (tc-inline-aggregate-finish-layout cursor max-align)
        [(TcLayoutInfo size align)
          (OkTcInlineFieldsLayout
            (TcInlineFieldsLayout size align TcInlineFieldLayoutNil))])]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef name ty _)
            (let
              [resolved : AstType (tc-resolve-type ctx ty)]
              (match (tc-inline-aggregate-type-layout-with-stack
                ctx
                resolved
                stack)
                [(OkTcLayoutInfo info)
                  (let
                    [field-align : i64 (tc-layout-info-align info)]
                    [field-size : i64 (tc-layout-info-size info)]
                    [offset : i64 (tc-align-up cursor field-align)]
                    [next-cursor : i64 (+ offset field-size)]
                    [next-align : i64 (tc-max-i64 max-align field-align)]
                    (match (tc-inline-aggregate-field-defs-layout
                      ctx
                      rest
                      next-cursor
                      next-align
                      stack)
                      [(OkTcInlineFieldsLayout rest-layout)
                        (match rest-layout
                          [(TcInlineFieldsLayout size align rest-fields)
                            (OkTcInlineFieldsLayout
                              (TcInlineFieldsLayout
                                size
                                align
                                (TcInlineFieldLayoutCons
                                  (TcInlineFieldLayout name resolved offset)
                                  (box rest-fields))))])]
                      [(ErrTcInlineFieldsLayout message)
                        (ErrTcInlineFieldsLayout message)]))]
                [(ErrTcLayoutInfo message) (ErrTcInlineFieldsLayout message)]))]))]))

(define (tc-inline-aggregate-payloads-layout
  [ctx : TcContext]
  [types : AstTypeList]
  [index : i64]
  [cursor : i64]
  [max-align : i64]
  [stack : TcStringList]) : ResultTcInlinePayloadFieldsLayout
  (match types
    [(AstTypeNil)
      (match (tc-inline-aggregate-finish-layout cursor max-align)
        [(TcLayoutInfo size align)
          (OkTcInlinePayloadFieldsLayout
            (TcInlinePayloadFieldsLayout size align TcInlinePayloadLayoutNil))])]
    [(AstTypeCons ty rest)
      (let
        [ty : AstType (box-get ty)]
        [rest : AstTypeList (box-get rest)]
        [resolved : AstType (tc-resolve-type ctx ty)]
        (match (tc-inline-aggregate-type-layout-with-stack ctx resolved stack)
          [(OkTcLayoutInfo info)
            (let
              [field-align : i64 (tc-layout-info-align info)]
              [field-size : i64 (tc-layout-info-size info)]
              [offset : i64 (tc-align-up cursor field-align)]
              [next-cursor : i64 (+ offset field-size)]
              [next-align : i64 (tc-max-i64 max-align field-align)]
              (match (tc-inline-aggregate-payloads-layout
                ctx
                rest
                (+ index 1)
                next-cursor
                next-align
                stack)
                [(OkTcInlinePayloadFieldsLayout rest-layout)
                  (match rest-layout
                    [(TcInlinePayloadFieldsLayout size align rest-payloads)
                      (OkTcInlinePayloadFieldsLayout
                        (TcInlinePayloadFieldsLayout
                          size
                          align
                          (TcInlinePayloadLayoutCons
                            (TcInlinePayloadLayout index resolved offset)
                            (box rest-payloads))))])]
                [(ErrTcInlinePayloadFieldsLayout message)
                  (ErrTcInlinePayloadFieldsLayout message)]))]
          [(ErrTcLayoutInfo message) (ErrTcInlinePayloadFieldsLayout message)]))]))

(define (tc-inline-aggregate-struct-layout-with-stack
  [ctx : TcContext]
  [struct-name : String]
  [stack : TcStringList]) : ResultTcInlineAggregateLayout
  (if (tc-string-list-contains stack struct-name)
    (ErrTcInlineAggregateLayout
      (tc-inline-aggregate-cycle-message struct-name stack))
    (match (tc-struct-decl ctx struct-name)
      [(OkTcStructDecl decl)
        (match decl
          [(TcStructDecl _ _ fields)
            (match (tc-inline-aggregate-field-defs-layout
              ctx
              fields
              0
              0
              (TcStringCons struct-name (box stack)))
              [(OkTcInlineFieldsLayout layout)
                (match layout
                  [(TcInlineFieldsLayout size align fields-layout)
                    (OkTcInlineAggregateLayout
                      (TcInlineStructLayout size align fields-layout))])]
              [(ErrTcInlineFieldsLayout message)
                (ErrTcInlineAggregateLayout message)])])]
      [(ErrTcStructDecl message) (ErrTcInlineAggregateLayout message)])))

(define (tc-inline-aggregate-variants-layout
  [ctx : TcContext]
  [variants : AstVariantDefList]
  [max-size : i64]
  [max-align : i64]
  [stack : TcStringList]) : ResultTcInlineAggregateLayout
  (match variants
    [(AstVariantDefNil)
      (OkTcInlineAggregateLayout
        (TcInlineEnumLayout
          (tc-align-up max-size max-align)
          max-align
          TcInlineVariantLayoutNil))]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef variant-name fields)
            (match (tc-inline-aggregate-payloads-layout ctx fields 0 8 8 stack)
              [(OkTcInlinePayloadFieldsLayout payload-layout)
                (match payload-layout
                  [(TcInlinePayloadFieldsLayout
                      variant-size
                      variant-align
                      payloads)
                    (let
                      [next-size : i64 (tc-max-i64 max-size variant-size)]
                      [next-align : i64 (tc-max-i64 max-align variant-align)]
                      (match (tc-inline-aggregate-variants-layout
                        ctx
                        rest
                        next-size
                        next-align
                        stack)
                        [(OkTcInlineAggregateLayout rest-layout)
                          (match rest-layout
                            [(TcInlineEnumLayout
                                enum-size
                                enum-align
                                rest-variants)
                              (OkTcInlineAggregateLayout
                                (TcInlineEnumLayout
                                  enum-size
                                  enum-align
                                  (TcInlineVariantLayoutCons
                                    (TcInlineVariantLayout
                                      variant-name
                                      variant-size
                                      variant-align
                                      payloads)
                                    (box rest-variants))))]
                            [(TcInlineStructLayout _ _ _)
                              (ErrTcInlineAggregateLayout
                                "typecheck: internal inline enum layout mismatch")])]
                        [(ErrTcInlineAggregateLayout message)
                          (ErrTcInlineAggregateLayout message)]))])]
              [(ErrTcInlinePayloadFieldsLayout message)
                (ErrTcInlineAggregateLayout message)])]))]))

(define (tc-inline-aggregate-enum-layout-with-stack
  [ctx : TcContext]
  [enum-name : String]
  [stack : TcStringList]) : ResultTcInlineAggregateLayout
  (if (tc-string-list-contains stack enum-name)
    (ErrTcInlineAggregateLayout
      (tc-inline-aggregate-cycle-message enum-name stack))
    (match (tc-context-enum-variants ctx enum-name)
      [(OkAstVariantDefList variants)
        (tc-inline-aggregate-variants-layout
          ctx
          variants
          8
          8
          (TcStringCons enum-name (box stack)))]
      [(ErrAstVariantDefList message) (ErrTcInlineAggregateLayout message)])))

(define (tc-inline-aggregate-layout-for-with-stack
  [ctx : TcContext]
  [name : String]
  [stack : TcStringList]) : ResultTcInlineAggregateLayout
  (match (compiler-symbols-lookup-type (tc-context-symbols ctx) name)
    [(SomeI64 handle)
      (if (=
        (compiler-symbol-handle-kind handle)
        (compiler-symbol-kind-defenum))
        (tc-inline-aggregate-enum-layout-with-stack ctx name stack)
        (if (=
          (compiler-symbol-handle-kind handle)
          (compiler-symbol-kind-defstruct))
          (tc-inline-aggregate-struct-layout-with-stack ctx name stack)
          (ErrTcInlineAggregateLayout
            (string-append "typecheck: unknown aggregate " name))))]
    [(NoneI64)
      (ErrTcInlineAggregateLayout
        (string-append "typecheck: unknown aggregate " name))]))

(define (tc-inline-aggregate-type-layout-with-stack
  [ctx : TcContext]
  [ty : AstType]
  [stack : TcStringList]) : ResultTcLayoutInfo
  (match (tc-type-strip-region (tc-resolve-type ctx ty))
    [(AstTyI64) (OkTcLayoutInfo (tc-inline-aggregate-layout-info 8 8))]
    [(AstTyU64) (OkTcLayoutInfo (tc-inline-aggregate-layout-info 8 8))]
    [(AstTyF64) (OkTcLayoutInfo (tc-inline-aggregate-layout-info 8 8))]
    [(AstTyI32) (OkTcLayoutInfo (tc-inline-aggregate-layout-info 4 4))]
    [(AstTyU32) (OkTcLayoutInfo (tc-inline-aggregate-layout-info 4 4))]
    [(AstTyF32) (OkTcLayoutInfo (tc-inline-aggregate-layout-info 4 4))]
    [(AstTyI16) (OkTcLayoutInfo (tc-inline-aggregate-layout-info 2 2))]
    [(AstTyU16) (OkTcLayoutInfo (tc-inline-aggregate-layout-info 2 2))]
    [(AstTyI8) (OkTcLayoutInfo (tc-inline-aggregate-layout-info 1 1))]
    [(AstTyU8) (OkTcLayoutInfo (tc-inline-aggregate-layout-info 1 1))]
    [(AstTyBool) (OkTcLayoutInfo (tc-inline-aggregate-layout-info 1 1))]
    [(AstTyChar) (OkTcLayoutInfo (tc-inline-aggregate-layout-info 1 1))]
    [(AstTyUnit) (OkTcLayoutInfo (tc-inline-aggregate-zero-layout-info))]
    [(AstTyNever) (OkTcLayoutInfo (tc-inline-aggregate-zero-layout-info))]
    [(AstTyExpr) (OkTcLayoutInfo (tc-inline-aggregate-zero-layout-info))]
    [(AstTyExprList) (OkTcLayoutInfo (tc-inline-aggregate-zero-layout-info))]
    [(AstTyFunc _ _) (OkTcLayoutInfo (tc-inline-aggregate-pointer-layout-info))]
    [(AstTyDynArray _)
      (OkTcLayoutInfo (tc-inline-aggregate-pointer-layout-info))]
    [(AstTyBox _) (OkTcLayoutInfo (tc-inline-aggregate-pointer-layout-info))]
    [(AstTyPtr _) (OkTcLayoutInfo (tc-inline-aggregate-pointer-layout-info))]
    [(AstTyMutPtr _) (OkTcLayoutInfo (tc-inline-aggregate-pointer-layout-info))]
    [(AstTyRef _ _) (OkTcLayoutInfo (tc-inline-aggregate-pointer-layout-info))]
    [(AstTyMutRef _ _)
      (OkTcLayoutInfo (tc-inline-aggregate-pointer-layout-info))]
    [(AstTyRegion _ inner)
      (tc-inline-aggregate-type-layout-with-stack ctx (box-get inner) stack)]
    [(AstTyString) (OkTcLayoutInfo (tc-inline-aggregate-pointer-layout-info))]
    [(AstTyStr) (OkTcLayoutInfo (tc-inline-aggregate-pointer-layout-info))]
    [(AstTyVar _) (OkTcLayoutInfo (tc-inline-aggregate-pointer-layout-info))]
    [(AstTyVarArgs _ _)
      (OkTcLayoutInfo (tc-inline-aggregate-pointer-layout-info))]
    [(AstTyTuple elems)
      (tc-inline-aggregate-type-list-layout-info ctx elems 0 0 stack)]
    [(AstTyArray elem count)
      (match (tc-inline-aggregate-type-layout-with-stack
        ctx
        (box-get elem)
        stack)
        [(OkTcLayoutInfo elem-info)
          (OkTcLayoutInfo
            (TcLayoutInfo
              (tc-inline-aggregate-array-size
                (tc-layout-info-size elem-info)
                (tc-layout-info-align elem-info)
                count)
              (tc-layout-info-align elem-info)))]
        [(ErrTcLayoutInfo message) (ErrTcLayoutInfo message)])]
    [(AstTyStruct name)
      (match (tc-inline-aggregate-layout-for-with-stack ctx name stack)
        [(OkTcInlineAggregateLayout layout)
          (OkTcLayoutInfo
            (TcLayoutInfo
              (tc-inline-aggregate-layout-size layout)
              (tc-inline-aggregate-layout-align layout)))]
        [(ErrTcInlineAggregateLayout message) (ErrTcLayoutInfo message)])]
    [(AstTyStructArgs name _)
      (match (tc-inline-aggregate-layout-for-with-stack ctx name stack)
        [(OkTcInlineAggregateLayout layout)
          (OkTcLayoutInfo
            (TcLayoutInfo
              (tc-inline-aggregate-layout-size layout)
              (tc-inline-aggregate-layout-align layout)))]
        [(ErrTcInlineAggregateLayout message) (ErrTcLayoutInfo message)])]
    [(AstTyEnum name)
      (match (tc-inline-aggregate-layout-for-with-stack ctx name stack)
        [(OkTcInlineAggregateLayout layout)
          (OkTcLayoutInfo
            (TcLayoutInfo
              (tc-inline-aggregate-layout-size layout)
              (tc-inline-aggregate-layout-align layout)))]
        [(ErrTcInlineAggregateLayout message) (ErrTcLayoutInfo message)])]
    [(AstTyEnumArgs name _)
      (match (tc-inline-aggregate-layout-for-with-stack ctx name stack)
        [(OkTcInlineAggregateLayout layout)
          (OkTcLayoutInfo
            (TcLayoutInfo
              (tc-inline-aggregate-layout-size layout)
              (tc-inline-aggregate-layout-align layout)))]
        [(ErrTcInlineAggregateLayout message) (ErrTcLayoutInfo message)])]))

(define (tc-inline-aggregate-type-layout [ctx : TcContext] [ty : AstType]) : ResultTcLayoutInfo
  (match (tc-inline-aggregate-type-finite-ok ctx ty TcStringNil)
    [(OkTcUnit) (tc-inline-aggregate-type-layout-with-stack ctx ty TcStringNil)]
    [(ErrTcUnit message) (ErrTcLayoutInfo message)]))

(define (tc-inline-aggregate-layout-for [ctx : TcContext] [name : String]) : ResultTcInlineAggregateLayout
  (match (tc-inline-aggregate-layout-finite-ok ctx name)
    [(OkTcUnit)
      (tc-inline-aggregate-layout-for-with-stack ctx name TcStringNil)]
    [(ErrTcUnit message) (ErrTcInlineAggregateLayout message)]))

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
            [(TcStructDecl repr _ _)
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
    [(AstTyStructArgs nested _)
      (match (tc-struct-decl ctx nested)
        [(OkTcStructDecl decl)
          (match decl
            [(TcStructDecl repr _ _)
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
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef name ty _)
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
                              (box (tc-repr-c-layout-fields rest-layout)))))]
                      [(ErrTcReprCLayout message) (ErrTcReprCLayout message)]))]
                [(ErrTcLayoutInfo message) (ErrTcReprCLayout message)]))]))]))

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
          [(TcStructDecl repr _ fields)
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

(define (tc-ctfe-inline-layout-fields [fields : TcInlineFieldLayoutList]) : CtfeLayoutFieldList
  (match fields
    [(TcInlineFieldLayoutNil) CtfeLayoutFieldNil]
    [(TcInlineFieldLayoutCons field rest)
      (match field
        [(TcInlineFieldLayout name _ offset)
          (CtfeLayoutFieldCons
            (CtfeLayoutField name offset)
            (box (tc-ctfe-inline-layout-fields (box-get rest))))])]))

(define (tc-ctfe-inline-aggregate-layout-info
  [name : String]
  [layout : TcInlineAggregateLayout]) : CtfeLayoutInfo
  (match layout
    [(TcInlineStructLayout size align fields)
      (CtfeLayoutInfo
        name
        true
        size
        align
        (tc-ctfe-inline-layout-fields fields))]
    [(TcInlineEnumLayout size align _)
      (CtfeLayoutInfo name false size align CtfeLayoutFieldNil)]))

(define (tc-ctfe-struct-layout-info [ctx : TcContext] [struct-name : String]) : CtfeLayoutInfo
  (match (tc-inline-aggregate-layout-for ctx struct-name)
    [(OkTcInlineAggregateLayout layout)
      (tc-ctfe-inline-aggregate-layout-info struct-name layout)]
    [(ErrTcInlineAggregateLayout _)
      (CtfeLayoutInfo struct-name false 8 8 CtfeLayoutFieldNil)]))

(define (tc-ctfe-type-layout-info [ctx : TcContext] [type-name : String]) : CtfeLayoutInfo
  (match (tc-inline-aggregate-layout-for ctx type-name)
    [(OkTcInlineAggregateLayout layout)
      (tc-ctfe-inline-aggregate-layout-info type-name layout)]
    [(ErrTcInlineAggregateLayout _)
      (CtfeLayoutInfo type-name false 8 8 CtfeLayoutFieldNil)]))

(define (tc-ctfe-layout-add-alias
  [layouts : CtfeLayoutInfoList]
  [info : CtfeLayoutInfo]
  [alias : String]) : CtfeLayoutInfoList
  (match info
    [(CtfeLayoutInfo _ repr-c? size align fields)
      (ctfe-layout-info-list-add-if-missing
        layouts
        (CtfeLayoutInfo alias repr-c? size align fields))]))

(define (tc-ctfe-layout-add-names
  [layouts : CtfeLayoutInfoList]
  [info : CtfeLayoutInfo]
  [name : String]
  [module : String]) : CtfeLayoutInfoList
  (let
    [with-key : CtfeLayoutInfoList
      (ctfe-layout-info-list-add-if-missing layouts info)]
    (if (= (string-length module) 0)
      with-key
      (tc-ctfe-layout-add-alias with-key info name))))

(define (tc-ctfe-layouts-from-decls
  [ctx : TcContext]
  [decls : AstDeclList]
  [module : String]
  [layouts : CtfeLayoutInfoList]) : CtfeLayoutInfoList
  (match decls
    [(AstDeclNil) layouts]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule next-module)
            (tc-ctfe-layouts-from-decls ctx rest next-module layouts)]
          [(AstDeclDefStruct name _ _ _)
            (let
              [key : String (compiler-symbol-module-key module name)]
              [info : CtfeLayoutInfo (tc-ctfe-struct-layout-info ctx key)]
              (tc-ctfe-layouts-from-decls
                ctx
                rest
                module
                (tc-ctfe-layout-add-names layouts info name module)))]
          [(AstDeclDefStructLifetimes name _ _ _ _)
            (let
              [key : String (compiler-symbol-module-key module name)]
              [info : CtfeLayoutInfo (tc-ctfe-struct-layout-info ctx key)]
              (tc-ctfe-layouts-from-decls
                ctx
                rest
                module
                (tc-ctfe-layout-add-names layouts info name module)))]
          [(AstDeclDefEnum name _)
            (let
              [key : String (compiler-symbol-module-key module name)]
              [info : CtfeLayoutInfo (tc-ctfe-type-layout-info ctx key)]
              (tc-ctfe-layouts-from-decls
                ctx
                rest
                module
                (tc-ctfe-layout-add-names layouts info name module)))]
          [(AstDeclDefEnumLifetimes name _ _)
            (let
              [key : String (compiler-symbol-module-key module name)]
              [info : CtfeLayoutInfo (tc-ctfe-type-layout-info ctx key)]
              (tc-ctfe-layouts-from-decls
                ctx
                rest
                module
                (tc-ctfe-layout-add-names layouts info name module)))]
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (match template
                [(AstDeclDefStruct name _ _ _)
                  (let
                    [key : String (compiler-symbol-module-key module name)]
                    [info : CtfeLayoutInfo (tc-ctfe-struct-layout-info ctx key)]
                    (tc-ctfe-layouts-from-decls
                      ctx
                      rest
                      module
                      (tc-ctfe-layout-add-names layouts info name module)))]
                [(AstDeclDefStructLifetimes name _ _ _ _)
                  (let
                    [key : String (compiler-symbol-module-key module name)]
                    [info : CtfeLayoutInfo (tc-ctfe-struct-layout-info ctx key)]
                    (tc-ctfe-layouts-from-decls
                      ctx
                      rest
                      module
                      (tc-ctfe-layout-add-names layouts info name module)))]
                [(AstDeclDefEnum name _)
                  (let
                    [key : String (compiler-symbol-module-key module name)]
                    [info : CtfeLayoutInfo (tc-ctfe-type-layout-info ctx key)]
                    (tc-ctfe-layouts-from-decls
                      ctx
                      rest
                      module
                      (tc-ctfe-layout-add-names layouts info name module)))]
                [(AstDeclDefEnumLifetimes name _ _)
                  (let
                    [key : String (compiler-symbol-module-key module name)]
                    [info : CtfeLayoutInfo (tc-ctfe-type-layout-info ctx key)]
                    (tc-ctfe-layouts-from-decls
                      ctx
                      rest
                      module
                      (tc-ctfe-layout-add-names layouts info name module)))]
                [_ (tc-ctfe-layouts-from-decls ctx rest module layouts)]))]
          [_ (tc-ctfe-layouts-from-decls ctx rest module layouts)]))]))

(define (tc-ctfe-layouts [ctx : TcContext]) : CtfeLayoutInfoList
  (match ctx
    [(TcContext program _ _ _)
      (match program
        [(AstProgram decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            (tc-ctfe-layouts-from-decls ctx decls "" CtfeLayoutInfoNil))])]))

(define (tc-ctfe-env [ctx : TcContext]) : CtfeEnv
  (ctfe-env-with-metadata
    (tc-ctfe-layouts ctx)
    (ctfe-reflections-from-program (tc-context-program ctx))))

(define (tc-string-prefix? [text : String] [prefix : String]) : bool
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
    (if (< text-len prefix-len)
      false
      (string-eq (substring text 0 prefix-len) prefix))))

(define (tc-result-info-enum-name [info : TcResultInfo]) : String
  (match info
    [(TcResultInfo _ enum-name _ _ _ _) enum-name]))

(define (tc-result-info-kind [info : TcResultInfo]) : TcTryKind
  (match info
    [(TcResultInfo kind _ _ _ _ _) kind]))

(define (tc-result-info-ok-name [info : TcResultInfo]) : String
  (match info
    [(TcResultInfo _ _ ok-name _ _ _) ok-name]))

(define (tc-result-info-ok-type [info : TcResultInfo]) : AstType
  (match info
    [(TcResultInfo _ _ _ ok-ty _ _) ok-ty]))

(define (tc-result-info-err-name [info : TcResultInfo]) : String
  (match info
    [(TcResultInfo _ _ _ _ err-name _) err-name]))

(define (tc-result-info-err-type [info : TcResultInfo]) : AstType
  (match info
    [(TcResultInfo _ _ _ _ _ err-ty) err-ty]))

(define (tc-ok-variant-name? [name : String]) : bool
  (tc-string-prefix? name "Ok"))

(define (tc-err-variant-name? [name : String]) : bool
  (tc-string-prefix? name "Err"))

(define (tc-some-variant-name? [name : String]) : bool
  (tc-string-prefix? name "Some"))

(define (tc-none-variant-name? [name : String]) : bool
  (tc-string-prefix? name "None"))

(define (tc-result-variant-payload-type
  [ctx : TcContext]
  [variant-name : String]
  [fields : AstTypeList]) : ResultTcType
  (match fields
    [(AstTypeCons field tail)
      (let
        [field : AstType (box-get field)]
        [tail : AstTypeList (box-get tail)]
        (match tail
          [(AstTypeNil) (OkTcType (tc-resolve-type ctx field))]
          [_
            (ErrTcType
              (string-append
                "typecheck: try requires Result-like variant with one payload "
                variant-name))]))]
    [_
      (ErrTcType
        (string-append
          "typecheck: try requires Result-like variant with one payload "
          variant-name))]))

(define (tc-result-info-build
  [ctx : TcContext]
  [try-kind : TcTryKind]
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
            (TcResultInfo try-kind enum-name ok-name ok-ty err-name err-ty))]
        [(ErrTcType message) (ErrTcResultInfo message)])]
    [(ErrTcType message) (ErrTcResultInfo message)]))

(define (tc-option-none-variant-type
  [variant-name : String]
  [fields : AstTypeList]) : ResultTcType
  (match fields
    [(AstTypeNil) (OkTcType (AstTyUnit))]
    [_
      (ErrTcType
        (string-append
          "typecheck: try requires Option-like variant with no payload "
          variant-name))]))

(define (tc-option-info-build
  [ctx : TcContext]
  [enum-name : String]
  [some-name : String]
  [some-fields : AstTypeList]
  [none-name : String]
  [none-fields : AstTypeList]) : ResultTcResultInfo
  (match (tc-result-variant-payload-type ctx some-name some-fields)
    [(OkTcType some-ty)
      (match (tc-option-none-variant-type none-name none-fields)
        [(OkTcType none-ty)
          (OkTcResultInfo
            (TcResultInfo
              TcTryOption
              enum-name
              some-name
              some-ty
              none-name
              none-ty))]
        [(ErrTcType message) (ErrTcResultInfo message)])]
    [(ErrTcType message) (ErrTcResultInfo message)]))

(define (tc-result-info-two-variants
  [ctx : TcContext]
  [enum-name : String]
  [first-name : String]
  [first-fields : AstTypeList]
  [second-name : String]
  [second-fields : AstTypeList]) : ResultTcResultInfo
  (cond
    [(and (tc-ok-variant-name? first-name) (tc-err-variant-name? second-name))
      (tc-result-info-build
        ctx
        TcTryResult
        enum-name
        first-name
        first-fields
        second-name
        second-fields)]
    [(and (tc-err-variant-name? first-name) (tc-ok-variant-name? second-name))
      (tc-result-info-build
        ctx
        TcTryResult
        enum-name
        second-name
        second-fields
        first-name
        first-fields)]
    [(and
        (tc-some-variant-name? first-name)
        (tc-none-variant-name? second-name))
      (tc-option-info-build
        ctx
        enum-name
        first-name
        first-fields
        second-name
        second-fields)]
    [(and
        (tc-none-variant-name? first-name)
        (tc-some-variant-name? second-name))
      (tc-option-info-build
        ctx
        enum-name
        second-name
        second-fields
        first-name
        first-fields)]
    [else
      (ErrTcResultInfo
        "typecheck: try requires Result-like Ok*/Err* or Option-like Some*/None* variants")]))

(define (tc-result-info-from-variants
  [ctx : TcContext]
  [enum-name : String]
  [variants : AstVariantDefList]) : ResultTcResultInfo
  (match variants
    [(AstVariantDefCons first tail)
      (let
        [tail : AstVariantDefList (box-get tail)]
        (match tail
          [(AstVariantDefCons second AstVariantDefNil)
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
              "typecheck: try requires Result-like enum with exactly two variants")]))]
    [_
      (ErrTcResultInfo
        "typecheck: try requires Result-like enum with exactly two variants")]))

(define (tc-result-info [ctx : TcContext] [ty : AstType]) : ResultTcResultInfo
  (match (tc-type-strip-region ty)
    [(AstTyEnum enum-name)
      (match (tc-context-enum-variants ctx enum-name)
        [(OkAstVariantDefList variants)
          (tc-result-info-from-variants ctx enum-name variants)]
        [(ErrAstVariantDefList message) (ErrTcResultInfo message)])]
    [(AstTyEnumArgs enum-name _)
      (match (tc-program-enum-variants (tc-context-program ctx) enum-name)
        [(OkAstVariantDefList variants)
          (tc-result-info-from-variants ctx enum-name variants)]
        [(ErrAstVariantDefList message) (ErrTcResultInfo message)])]
    [_ (ErrTcResultInfo "typecheck: try requires Result-like enum")]))

(define (tc-try-infos-compatible
  [operand-info : TcResultInfo]
  [return-info : TcResultInfo]) : ResultTcUnit
  (match (tc-result-info-kind operand-info)
    [(TcTryResult)
      (match (tc-result-info-kind return-info)
        [(TcTryResult)
          (tc-expect
            (tc-result-info-err-type operand-info)
            (tc-result-info-err-type return-info)
            "typecheck: try error type mismatch")]
        [(TcTryOption) (ErrTcUnit "typecheck: try carrier mismatch")])]
    [(TcTryOption)
      (match (tc-result-info-kind return-info)
        [(TcTryOption) OkTcUnit]
        [(TcTryResult) (ErrTcUnit "typecheck: try carrier mismatch")])]))

(define (tc-try-expr [ctx : TcContext] [env : TcTypeEnv] [inner : AstExpr]) : ResultTcType
  (match (tc-expr ctx env inner)
    [(OkTcType operand-ty)
      (match (tc-result-info ctx operand-ty)
        [(OkTcResultInfo operand-info)
          (match (tc-current-return-type env)
            [(OkTcType return-ty)
              (match (tc-result-info ctx return-ty)
                [(OkTcResultInfo return-info)
                  (match (tc-try-infos-compatible operand-info return-info)
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

(define (tc-return-expr [ctx : TcContext] [env : TcTypeEnv] [value : AstExpr]) : ResultTcType
  (match (tc-current-return-type env)
    [(OkTcType return-ty)
      (match (tc-expr-with-expected-or-actual ctx env value return-ty)
        [(OkTcType value-ty)
          (match (tc-expect
            value-ty
            return-ty
            "typecheck: return type mismatch")
            [(OkTcUnit)
              (if (tc-expr-result-uses-active-cleanup-owner? env value)
                (ErrTcType
                  "typecheck: cleanup-required resource would escape with scope")
                (OkTcType (AstTyNever)))]
            [(ErrTcUnit message) (ErrTcType message)])]
        [(ErrTcType message) (ErrTcType message)])]
    [(ErrTcType _) (ErrTcType "typecheck: return requires enclosing function")]))

(define (tc-variant-owner-name [ctx : TcContext] [handle : i64]) : ResultTcString
  (match (compiler-symbols-owner-name-at-index
    (tc-context-symbols ctx)
    (compiler-registry-handle-owner-index handle))
    [(CompilerSomeString name) (OkTcString name)]
    [(CompilerNoString)
      (match (tc-context-program ctx)
        [(AstProgram decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            (tc-variant-owner-name-list
              decls
              (compiler-registry-handle-owner-index handle)
              0
              ""))])]))

(define (tc-variant-owner-name-list
  [decls : AstDeclList]
  [target : i64]
  [index : i64]
  [module : String]) : ResultTcString
  (match decls
    [(AstDeclNil) (ErrTcString "typecheck: variant owner is not enum")]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport _)
            (tc-variant-owner-name-list rest target index module)]
          [(AstDeclIncludeStr _ _)
            (tc-variant-owner-name-list rest target index module)]
          [(AstDeclExport _)
            (tc-variant-owner-name-list rest target index module)]
          [(AstDeclModule next-module)
            (tc-variant-owner-name-list rest target index next-module)]
          [(AstDeclTest _ _ _)
            (tc-variant-owner-name-list rest target index module)]
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (if (= target index)
                (match template
                  [(AstDeclDefEnum name _)
                    (OkTcString (compiler-symbol-module-key module name))]
                  [(AstDeclDefEnumLifetimes name _ _)
                    (OkTcString (compiler-symbol-module-key module name))]
                  [_ (ErrTcString "typecheck: variant owner is not enum")])
                (tc-variant-owner-name-list rest target (+ index 1) module)))]
          [_
            (if (= target index)
              (match decl
                [(AstDeclDefEnum name _)
                  (OkTcString (compiler-symbol-module-key module name))]
                [(AstDeclDefEnumLifetimes name _ _)
                  (OkTcString (compiler-symbol-module-key module name))]
                [_ (ErrTcString "typecheck: variant owner is not enum")])
              (tc-variant-owner-name-list rest target (+ index 1) module))]))]))

(define (tc-struct-field-type
  [ctx : TcContext]
  [struct-name : String]
  [field : String]) : ResultTcType
  (match (compiler-registries-lookup-struct-field
    (tc-context-registries ctx)
    struct-name
    field)
    [(SomeI64 handle)
      (match (tc-qualified-field-visible-ok ctx struct-name field)
        [(OkTcUnit)
          (match (compiler-registries-struct-field-type-indexed
            (tc-context-symbols ctx)
            handle)
            [(OkAstType ty) (OkTcType (tc-resolve-type ctx ty))]
            [(ErrAstType message) (ErrTcType message)])]
        [(ErrTcUnit message) (ErrTcType message)])]
    [(NoneI64)
      (ErrTcType
        (string-append
          "typecheck: unknown struct field "
          (compiler-struct-field-key struct-name field)))]))

(define (tc-lifetime-subst-from-nominal-args
  [ctx : TcContext]
  [name : String]
  [args : AstLifetimeList]) : ResultTcLifetimeSubst
  (match (tc-nominal-lifetimes ctx name)
    [(OkTcLifetimeList params)
      (tc-infer-lifetime-list params TcLifetimeSubstNil params args)]
    [(ErrTcLifetimeList message) (ErrTcLifetimeSubst message)]))

(define (tc-struct-field-type-with-args
  [ctx : TcContext]
  [struct-name : String]
  [lifetimes : AstLifetimeList]
  [field : String]) : ResultTcType
  (match (compiler-registries-lookup-struct-field
    (tc-context-registries ctx)
    struct-name
    field)
    [(SomeI64 handle)
      (match (tc-qualified-field-visible-ok ctx struct-name field)
        [(OkTcUnit)
          (match (compiler-registries-struct-field-type
            (tc-context-program ctx)
            handle)
            [(OkAstType ty)
              (match (tc-lifetime-subst-from-nominal-args
                ctx
                struct-name
                lifetimes)
                [(OkTcLifetimeSubst subst)
                  (OkTcType
                    (tc-resolve-type ctx (tc-lifetime-subst-type subst ty)))]
                [(ErrTcLifetimeSubst message) (ErrTcType message)])]
            [(ErrAstType message) (ErrTcType message)])]
        [(ErrTcUnit message) (ErrTcType message)])]
    [(NoneI64)
      (ErrTcType
        (string-append
          "typecheck: unknown struct field "
          (compiler-struct-field-key struct-name field)))]))

(define (tc-borrow-place-var [name : String] [ty : AstType]) : ResultTcBorrowPlace
  (if (tc-type-contains-reference? ty)
    (ErrTcBorrowPlace
      "typecheck: borrowing reference-typed places is not implemented (#804)")
    (match (tc-type-outer-region ty)
      [(TcSomeString region)
        (OkTcBorrowPlace (TcBorrowPlace region (tc-borrow-referent-type ty)))]
      [(TcNoString)
        (OkTcBorrowPlace (TcBorrowPlace name (tc-borrow-referent-type ty)))])))

(define (tc-borrow-referent-type [ty : AstType]) : AstType
  (match (tc-type-without-regions ty)
    [(AstTyString) (AstTyStr)]
    [_ (tc-type-without-regions ty)]))

(define (tc-borrow-place-struct-field
  [ctx : TcContext]
  [place : TcBorrowPlace]
  [field : String]) : ResultTcBorrowPlace
  (match place
    [(TcBorrowPlace lifetime receiver-ty)
      (match (tc-type-strip-region (tc-resolve-type ctx receiver-ty))
        [(AstTyStruct struct-name)
          (match (tc-struct-field-type ctx struct-name field)
            [(OkTcType field-ty)
              (OkTcBorrowPlace
                (TcBorrowPlace lifetime (tc-borrow-referent-type field-ty)))]
            [(ErrTcType message) (ErrTcBorrowPlace message)])]
        [(AstTyStructArgs struct-name lifetimes)
          (match (tc-struct-field-type-with-args
            ctx
            struct-name
            lifetimes
            field)
            [(OkTcType field-ty)
              (OkTcBorrowPlace
                (TcBorrowPlace lifetime (tc-borrow-referent-type field-ty)))]
            [(ErrTcType message) (ErrTcBorrowPlace message)])]
        [_
          (ErrTcBorrowPlace
            "typecheck: struct-get borrow requires struct place")])]))

(define (tc-borrow-place-tuple-field
  [ctx : TcContext]
  [place : TcBorrowPlace]
  [index : i64]) : ResultTcBorrowPlace
  (match place
    [(TcBorrowPlace lifetime tuple-ty)
      (match (tc-type-strip-region (tc-resolve-type ctx tuple-ty))
        [(AstTyTuple elems)
          (match (tc-type-list-ref elems index)
            [(OkTcType elem-ty)
              (OkTcBorrowPlace
                (TcBorrowPlace lifetime (tc-borrow-referent-type elem-ty)))]
            [(ErrTcType message) (ErrTcBorrowPlace message)])]
        [_
          (ErrTcBorrowPlace "typecheck: tuple-ref borrow requires tuple place")])]))

(define (tc-borrow-place-array-element
  [ctx : TcContext]
  [place : TcBorrowPlace]) : ResultTcBorrowPlace
  (match place
    [(TcBorrowPlace lifetime array-ty)
      (match (tc-type-strip-region (tc-resolve-type ctx array-ty))
        [(AstTyArray elem-ty _)
          (OkTcBorrowPlace
            (TcBorrowPlace lifetime (tc-borrow-referent-type (box-get elem-ty))))]
        [(AstTyDynArray elem-ty)
          (OkTcBorrowPlace
            (TcBorrowPlace lifetime (tc-borrow-referent-type (box-get elem-ty))))]
        [_
          (ErrTcBorrowPlace "typecheck: array-ref borrow requires array place")])]))

(define (tc-borrow-place [ctx : TcContext] [env : TcTypeEnv] [expr : AstExpr]) : ResultTcBorrowPlace
  (match (ast-expr-unspan expr)
    [(AstExprVar name)
      (match (tc-lookup-visible ctx env name)
        [(OkTcType ty) (tc-borrow-place-var name ty)]
        [(ErrTcType message) (ErrTcBorrowPlace message)])]
    [(AstExprStructGet receiver-box field)
      (let
        [receiver : AstExpr (box-get receiver-box)]
        (match (tc-borrow-place ctx env receiver)
          [(OkTcBorrowPlace place)
            (tc-borrow-place-struct-field ctx place field)]
          [(ErrTcBorrowPlace message) (ErrTcBorrowPlace message)]))]
    [(AstExprTupleRef tuple-box index)
      (let
        [tuple : AstExpr (box-get tuple-box)]
        (match (tc-borrow-place ctx env tuple)
          [(OkTcBorrowPlace place)
            (tc-borrow-place-tuple-field ctx place index)]
          [(ErrTcBorrowPlace message) (ErrTcBorrowPlace message)]))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        (match (tc-expr ctx env index)
          [(OkTcType index-ty)
            (if (tc-integer-type? index-ty)
              (match (tc-borrow-place ctx env array)
                [(OkTcBorrowPlace place)
                  (tc-borrow-place-array-element ctx place)]
                [(ErrTcBorrowPlace message) (ErrTcBorrowPlace message)])
              (ErrTcBorrowPlace "typecheck: array index must be integer"))]
          [(ErrTcType message) (ErrTcBorrowPlace message)]))]
    [_
      (ErrTcBorrowPlace
        "typecheck: borrow requires a local, parameter, or aggregate place")]))

(define (tc-store-place-lifetime-var [name : String] [ty : AstType]) : ResultTcString
  (match (tc-type-outer-region ty)
    [(TcSomeString region) (OkTcString region)]
    [(TcNoString) (OkTcString name)]))

(define (tc-store-place-lifetime
  [ctx : TcContext]
  [env : TcTypeEnv]
  [expr : AstExpr]) : ResultTcString
  (match (ast-expr-unspan expr)
    [(AstExprVar name)
      (match (tc-lookup-visible ctx env name)
        [(OkTcType ty) (tc-store-place-lifetime-var name ty)]
        [(ErrTcType message) (ErrTcString message)])]
    [(AstExprStructGet receiver-box _)
      (let
        [receiver : AstExpr (box-get receiver-box)]
        (tc-store-place-lifetime ctx env receiver))]
    [(AstExprTupleRef tuple-box _)
      (let
        [tuple : AstExpr (box-get tuple-box)]
        (tc-store-place-lifetime ctx env tuple))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        (match (tc-expr ctx env index)
          [(OkTcType index-ty)
            (if (tc-integer-type? index-ty)
              (tc-store-place-lifetime ctx env array)
              (ErrTcString "typecheck: array index must be integer"))]
          [(ErrTcType message) (ErrTcString message)]))]
    [_ (ErrTcString "typecheck: expression is not a storage place")]))

(define (tc-ensure-reference-value-can-store-in-place
  [ctx : TcContext]
  [env : TcTypeEnv]
  [place-expr : AstExpr]
  [value-ty : AstType]
  [context : String]) : ResultTcUnit
  (let
    [lifetimes : TcStringList (tc-type-collect-reference-lifetimes value-ty)]
    (match lifetimes
      [(TcStringNil) OkTcUnit]
      [_
        (match (tc-store-place-lifetime ctx env place-expr)
          [(OkTcString target-lifetime)
            (if (tc-reference-lifetimes-outlive-lifetime?
              env
              lifetimes
              target-lifetime)
              OkTcUnit
              (ErrTcUnit
                (string-append
                  "typecheck: cannot store reference into longer-lived "
                  (string-append
                    context
                    "; reference value would escape lexical scope"))))]
          [(ErrTcString _)
            (ErrTcUnit
              (string-append
                "typecheck: cannot store reference into non-place "
                (string-append
                  context
                  "; reference value would escape lexical scope")))])])))

(define (tc-borrow-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [lifetime : AstBorrowLifetime]
  [place-expr : AstExpr]) : ResultTcType
  (match (tc-borrow-place ctx env place-expr)
    [(OkTcBorrowPlace place)
      (match place
        [(TcBorrowPlace inferred referent-ty)
          (match lifetime
            [(AstBorrowLifetimeInferred)
              (OkTcType (ast-ty-ref inferred referent-ty))]
            [(AstBorrowLifetimeNamed requested)
              (if (string-eq requested inferred)
                (OkTcType (ast-ty-ref inferred referent-ty))
                (ErrTcType "typecheck: borrow lifetime mismatch"))])])]
    [(ErrTcBorrowPlace message) (ErrTcType message)]))

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
      (let
        [pattern : AstPattern (box-get pattern)]
        [rest-patterns : AstPatternList (box-get rest-patterns)]
        (match types
          [(AstTypeCons ty rest-types)
            (let
              [ty : AstType (box-get ty)]
              [rest-types : AstTypeList (box-get rest-types)]
              (match (tc-bind-sub-pattern ctx env pattern ty)
                [(OkTcEnv next-env)
                  (tc-bind-sub-pattern-list
                    ctx
                    next-env
                    rest-patterns
                    rest-types)]
                [(ErrTcEnv message) (ErrTcEnv message)]))]
          [(AstTypeNil) (ErrTcEnv "typecheck: pattern arity mismatch")]))]))

(define (tc-bind-variant-pattern
  [ctx : TcContext]
  [env : TcTypeEnv]
  [enum-name : String]
  [variant-name : String]
  [enum-lifetimes : AstLifetimeList]
  [args : AstPatternList]
  [payload-region : TcMaybeString]) : ResultTcEnv
  (let
    [lookup-name : String (tc-variant-name-for-enum enum-name variant-name)]
    (match (compiler-registries-lookup-variant
      (tc-context-registries ctx)
      lookup-name)
      [(SomeI64 handle)
        (match (tc-qualified-variant-visible-ok ctx lookup-name)
          [(OkTcUnit)
            (match (tc-variant-owner-name ctx handle)
              [(OkTcString owner)
                (if (string-eq owner enum-name)
                  (match (compiler-registries-variant-fields-indexed
                    (tc-context-symbols ctx)
                    handle)
                    [(OkAstTypeList fields)
                      (match enum-lifetimes
                        [(AstLifetimeNil)
                          (let
                            [resolved-fields : AstTypeList
                              (tc-resolve-type-list ctx fields)]
                            (tc-bind-sub-pattern-list
                              ctx
                              env
                              args
                              (match payload-region
                                [(TcSomeString region)
                                  (tc-tag-type-list-region
                                    region
                                    resolved-fields)]
                                [(TcNoString) resolved-fields])))]
                        [_
                          (match (tc-lifetime-subst-from-nominal-args
                            ctx
                            enum-name
                            enum-lifetimes)
                            [(OkTcLifetimeSubst subst)
                              (let
                                [resolved-fields : AstTypeList
                                  (tc-resolve-type-list
                                    ctx
                                    (tc-lifetime-subst-type-list subst fields))]
                                (tc-bind-sub-pattern-list
                                  ctx
                                  env
                                  args
                                  (match payload-region
                                    [(TcSomeString region)
                                      (tc-tag-type-list-region
                                        region
                                        resolved-fields)]
                                    [(TcNoString) resolved-fields])))]
                            [(ErrTcLifetimeSubst message) (ErrTcEnv message)])])]
                    [(ErrAstTypeList message) (ErrTcEnv message)])
                  (ErrTcEnv
                    (string-append
                      "typecheck: variant "
                      (string-append
                        variant-name
                        (string-append
                          " belongs to enum "
                          (string-append
                            owner
                            (string-append ", not " enum-name)))))))]
              [(ErrTcString message) (ErrTcEnv message)])]
          [(ErrTcUnit message) (ErrTcEnv message)])]
      [(NoneI64)
        (ErrTcEnv (string-append "typecheck: unknown variant " variant-name))])))

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
      [(AstPatVariant name args-box)
        (let
          [args : AstPatternList (box-get args-box)]
          (match (tc-type-strip-region ty)
            [(AstTyEnum enum-name)
              (tc-bind-variant-pattern
                ctx
                env
                enum-name
                name
                AstLifetimeNil
                args
                (tc-type-outer-region ty))]
            [(AstTyEnumArgs enum-name lifetimes)
              (tc-bind-variant-pattern
                ctx
                env
                enum-name
                name
                lifetimes
                args
                (tc-type-outer-region ty))]
            [_
              (ErrTcEnv "typecheck: nested variant pattern requires enum field")]))]
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
            AstLifetimeNil
            AstPatternNil
            (tc-type-outer-region scrut-ty))]
        [(AstPatVariant variant-name args-box)
          (let
            [args : AstPatternList (box-get args-box)]
            (tc-bind-variant-pattern
              ctx
              env
              enum-name
              variant-name
              AstLifetimeNil
              args
              (tc-type-outer-region scrut-ty)))]
        [_ (ErrTcEnv "typecheck: unsupported enum match pattern")])]
    [(AstTyEnumArgs enum-name lifetimes)
      (match pattern
        [(AstPatWildcard) (OkTcEnv env)]
        [(AstPatBinding variant-name)
          (tc-bind-variant-pattern
            ctx
            env
            enum-name
            variant-name
            lifetimes
            AstPatternNil
            (tc-type-outer-region scrut-ty))]
        [(AstPatVariant variant-name args-box)
          (let
            [args : AstPatternList (box-get args-box)]
            (tc-bind-variant-pattern
              ctx
              env
              enum-name
              variant-name
              lifetimes
              args
              (tc-type-outer-region scrut-ty)))]
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
    [(AstMatchArm pattern body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (match (tc-bind-match-pattern ctx env scrut-ty pattern)
          [(OkTcEnv arm-env) (tc-expr ctx arm-env body)]
          [(ErrTcEnv message) (ErrTcType message)]))]))

(define (tc-match-rest-types
  [ctx : TcContext]
  [env : TcTypeEnv]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]
  [want : AstType]) : ResultTcType
  (match arms
    [(AstMatchArmNil) (OkTcType want)]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match (tc-match-arm-type ctx env scrut-ty arm)
          [(OkTcType got)
            (match (tc-merge-branch-type want got)
              [(OkTcType merged)
                (tc-match-rest-types ctx env scrut-ty rest merged)]
              [(ErrTcType _) (ErrTcType "typecheck: match arms must agree")])]
          [(ErrTcType message) (ErrTcType message)]))]))

(define (tc-check-match-arm-types
  [ctx : TcContext]
  [env : TcTypeEnv]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]) : ResultTcType
  (match arms
    [(AstMatchArmNil) (ErrTcType "typecheck: match must have at least one arm")]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match (tc-match-arm-type ctx env scrut-ty arm)
          [(OkTcType first-ty)
            (tc-match-rest-types ctx env scrut-ty rest first-ty)]
          [(ErrTcType message) (ErrTcType message)]))]))

(define (tc-qualified-name-last-slash [name : String]) : i64
  (let
    [i : i64 (- (string-length name) 1)]
    (begin
      (while (>= i 0)
        (if (= (string-ref name i) #/')
          (return i)
          (set! i (- i 1))))
      -1)))

(define (tc-qualified-name-module [name : String]) : String
  (let
    [slash : i64 (tc-qualified-name-last-slash name)]
    (if (< slash 0)
      ""
      (substring name 0 slash))))

(define (tc-qualified-name-base [name : String]) : String
  (let
    [slash : i64 (tc-qualified-name-last-slash name)]
    (if (< slash 0)
      name
      (substring name (+ slash 1) (- (string-length name) (+ slash 1))))))

(define (tc-qualified-variant-name [enum-name : String] [variant-name : String]) : String
  (let
    [module : String (tc-qualified-name-module enum-name)]
    (if (string-eq module "")
      variant-name
      (compiler-symbol-module-key module variant-name))))

(define (tc-variant-name-for-enum [enum-name : String] [variant-name : String]) : String
  (if (tc-name-qualified? variant-name)
    variant-name
    (tc-qualified-variant-name enum-name variant-name)))

(define (tc-variant-name-matches?
  [ctx : TcContext]
  [enum-name : String]
  [pattern-name : String]
  [variant-name : String]) : bool
  (if (or
    (string-eq pattern-name variant-name)
    (string-eq pattern-name (tc-qualified-variant-name enum-name variant-name)))
    true
    (let
      [pattern-key : String (tc-variant-name-for-enum enum-name pattern-name)]
      [candidate-key : String
        (tc-qualified-variant-name enum-name variant-name)]
      (match (compiler-registries-lookup-variant
        (tc-context-registries ctx)
        pattern-key)
        [(SomeI64 pattern-handle)
          (match (compiler-registries-lookup-variant
            (tc-context-registries ctx)
            candidate-key)
            [(SomeI64 candidate-handle) (= pattern-handle candidate-handle)]
            [(NoneI64) false])]
        [(NoneI64) false]))))

(define (tc-enum-has-single-variant?
  [ctx : TcContext]
  [variants : AstVariantDefList]
  [enum-name : String]
  [variant-name : String]) : bool
  (match variants
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match rest
          [(AstVariantDefNil)
            (match variant
              [(AstVariantDef name _)
                (tc-variant-name-matches? ctx enum-name variant-name name)])]
          [_ false]))]
    [_ false]))

(define (tc-variant-pattern-irrefutable?
  [ctx : TcContext]
  [enum-name : String]
  [variant-name : String]
  [args : AstPatternList]) : bool
  (let
    [lookup-name : String (tc-variant-name-for-enum enum-name variant-name)]
    (match (compiler-registries-lookup-variant
      (tc-context-registries ctx)
      lookup-name)
      [(SomeI64 handle)
        (match (compiler-registries-variant-fields-indexed
          (tc-context-symbols ctx)
          handle)
          [(OkAstTypeList fields)
            (tc-pattern-list-irrefutable?
              ctx
              args
              (tc-resolve-type-list ctx fields))]
          [(ErrAstTypeList _) false])]
      [(NoneI64) false])))

(define (tc-sub-pattern-irrefutable?
  [ctx : TcContext]
  [pattern : AstPattern]
  [field-ty : AstType]) : bool
  (match pattern
    [(AstPatWildcard) true]
    [(AstPatBinding _) true]
    [(AstPatLiteral _) false]
    [(AstPatVariant name args-box)
      (let
        [args : AstPatternList (box-get args-box)]
        (match (tc-type-strip-region (tc-resolve-type ctx field-ty))
          [(AstTyEnum enum-name)
            (match (tc-context-enum-variants ctx enum-name)
              [(OkAstVariantDefList variants)
                (if (tc-enum-has-single-variant? ctx variants enum-name name)
                  (tc-variant-pattern-irrefutable? ctx enum-name name args)
                  false)]
              [(ErrAstVariantDefList _) false])]
          [(AstTyEnumArgs enum-name _)
            (match (tc-program-enum-variants (tc-context-program ctx) enum-name)
              [(OkAstVariantDefList variants)
                (if (tc-enum-has-single-variant? ctx variants enum-name name)
                  (tc-variant-pattern-irrefutable? ctx enum-name name args)
                  false)]
              [(ErrAstVariantDefList _) false])]
          [_ false]))]
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
      (let
        [pattern : AstPattern (box-get pattern)]
        [rest : AstPatternList (box-get rest)]
        (match types
          [(AstTypeCons ty rest-types)
            (let
              [ty : AstType (box-get ty)]
              [rest-types : AstTypeList (box-get rest-types)]
              (if (tc-sub-pattern-irrefutable? ctx pattern ty)
                (tc-pattern-list-irrefutable? ctx rest rest-types)
                false))]
          [(AstTypeNil) false]))]))

(define (tc-pattern-covers-variant?
  [ctx : TcContext]
  [pattern : AstPattern]
  [enum-name : String]
  [variant-name : String]) : bool
  (match pattern
    [(AstPatWildcard) true]
    [(AstPatBinding name)
      (tc-variant-name-matches? ctx enum-name name variant-name)]
    [(AstPatVariant name args-box)
      (let
        [args : AstPatternList (box-get args-box)]
        (and
          (tc-variant-name-matches? ctx enum-name name variant-name)
          (tc-variant-pattern-irrefutable? ctx enum-name name args)))]
    [_ false]))

(define (tc-match-arms-cover-variant?
  [ctx : TcContext]
  [arms : AstMatchArmList]
  [enum-name : String]
  [variant-name : String]) : bool
  (match arms
    [(AstMatchArmNil) false]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern _)
            (if (tc-pattern-covers-variant? ctx pattern enum-name variant-name)
              true
              (tc-match-arms-cover-variant? ctx rest enum-name variant-name))]))]))

(define (tc-enum-variants-covered?
  [ctx : TcContext]
  [enum-name : String]
  [variants : AstVariantDefList]
  [arms : AstMatchArmList]) : bool
  (match variants
    [(AstVariantDefNil) true]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef name _)
            (and
              (tc-match-arms-cover-variant? ctx arms enum-name name)
              (tc-enum-variants-covered? ctx enum-name rest arms))]))]))

(define (tc-match-arms-have-catchall? [arms : AstMatchArmList]) : bool
  (match arms
    [(AstMatchArmNil) false]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern _)
            (match pattern
              [(AstPatWildcard) true]
              [(AstPatBinding _) true]
              [_ (tc-match-arms-have-catchall? rest)])]))]))

(define (tc-match-arms-cover-bool? [arms : AstMatchArmList] [want : bool]) : bool
  (match arms
    [(AstMatchArmNil) false]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern _)
            (match pattern
              [(AstPatLiteral (AstLitBool value))
                (if (= value want)
                  true
                  (tc-match-arms-cover-bool? rest want))]
              [_ (tc-match-arms-cover-bool? rest want)])]))]))

(define (tc-match-pattern-catchall-for-type?
  [ctx : TcContext]
  [scrut-ty : AstType]
  [pattern : AstPattern]) : bool
  (match (tc-type-strip-region (tc-resolve-type ctx scrut-ty))
    [(AstTyEnum _)
      (match pattern
        [(AstPatWildcard) true]
        [_ false])]
    [(AstTyEnumArgs _ _)
      (match pattern
        [(AstPatWildcard) true]
        [_ false])]
    [_
      (match pattern
        [(AstPatWildcard) true]
        [(AstPatBinding _) true]
        [_ false])]))

(define (tc-match-arm-reachability-loop
  [ctx : TcContext]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]
  [seen-catchall : bool]) : ResultTcUnit
  (match arms
    [(AstMatchArmNil) OkTcUnit]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (if seen-catchall
          (ErrTcUnit "typecheck: unreachable match arm after wildcard `_`")
          (match arm
            [(AstMatchArm pattern _)
              (tc-match-arm-reachability-loop
                ctx
                scrut-ty
                rest
                (tc-match-pattern-catchall-for-type? ctx scrut-ty pattern))])))]))

(define (tc-match-arm-reachability-ok
  [ctx : TcContext]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]) : ResultTcUnit
  (tc-match-arm-reachability-loop ctx scrut-ty arms false))

(define (tc-match-exhaustive?
  [ctx : TcContext]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]) : bool
  (match (tc-type-strip-region scrut-ty)
    [(AstTyEnum enum-name)
      (match (tc-context-enum-variants ctx enum-name)
        [(OkAstVariantDefList variants)
          (tc-enum-variants-covered? ctx enum-name variants arms)]
        [(ErrAstVariantDefList _) false])]
    [(AstTyEnumArgs enum-name _)
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
  (match (tc-match-arm-reachability-ok ctx scrut-ty arms)
    [(OkTcUnit)
      (match (tc-check-match-arm-types ctx env scrut-ty arms)
        [(OkTcType result-ty)
          (if (tc-match-exhaustive? ctx scrut-ty arms)
            (OkTcType result-ty)
            (ErrTcType "typecheck: non-exhaustive match"))]
        [(ErrTcType message) (ErrTcType message)])]
    [(ErrTcUnit message) (ErrTcType message)]))

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

;; spmd-reduce purity/effect rules (#1011, SPEC.md §5.15): mirror the Rust
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
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-spmd-value-pure-at inner in-index))]
    [(AstExprLiteral _) OkTcUnit]
    [(AstExprVar _) OkTcUnit]
    [(AstExprBinary _ left-box right-box)
      (let
        [left : AstExpr (box-get left-box)]
        [right : AstExpr (box-get right-box)]
        (match (tc-spmd-value-pure-at left in-index)
          [(OkTcUnit) (tc-spmd-value-pure-at right in-index)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprUnary _ inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-spmd-value-pure-at inner in-index))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-spmd-value-pure-at inner in-index))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-spmd-value-pure-at inner in-index))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (match (tc-spmd-value-let-bindings-pure-at bindings in-index)
          [(OkTcUnit) (tc-spmd-value-pure-at body in-index)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        (if in-index
          (ErrTcUnit
            "indirect array indexing is not allowed inside a spmd-reduce value expression; gather/scatter is deferred in the first slice (SPEC.md §5.15)")
          (match (tc-spmd-value-pure-at array false)
            [(OkTcUnit) (tc-spmd-value-pure-at index true)]
            [(ErrTcUnit message) (ErrTcUnit message)])))]
    [(AstExprSet _ _)
      (ErrTcUnit
        "`set!` is not allowed inside a spmd-reduce value expression; reductions must use the explicit accumulator, not outer mutation (SPEC.md §5.15)")]
    [(AstExprArraySet _ _ _)
      (ErrTcUnit
        "`array-set!` is not allowed inside a spmd-reduce value expression; the value expression must be free of writes and other side effects (SPEC.md §5.15)")]
    [(AstExprArrayPush _ _)
      (ErrTcUnit
        "`array-push!` is not allowed inside a spmd-reduce value expression; the value expression must be free of writes and other side effects (SPEC.md §5.15)")]
    [(AstExprCall _ _)
      (ErrTcUnit
        "function calls are not allowed inside a spmd-reduce value expression; side-effecting builtins and user calls with varying arguments are deferred in the first slice (SPEC.md §5.15)")]
    [(AstExprForeach _ _ _ _ _)
      (ErrTcUnit
        "a nested foreach is not allowed inside a spmd-reduce value expression (SPEC.md §5.15)")]
    [(AstExprSpmdReduce _ _ _ _ _ _ _)
      (ErrTcUnit
        "a nested spmd-reduce is not allowed inside a spmd-reduce value expression (SPEC.md §5.15)")]
    [(AstExprIf _ _ _)
      (ErrTcUnit
        "varying control flow is not allowed inside a spmd-reduce value expression; the first slice has no varying if/while/match (SPEC.md §5.15)")]
    [(AstExprWhile _ _)
      (ErrTcUnit
        "varying control flow is not allowed inside a spmd-reduce value expression; the first slice has no varying if/while/match (SPEC.md §5.15)")]
    [(AstExprMatch _ _)
      (ErrTcUnit
        "varying control flow is not allowed inside a spmd-reduce value expression; the first slice has no varying if/while/match (SPEC.md §5.15)")]
    [_
      (ErrTcUnit
        "this expression is not allowed inside a spmd-reduce value expression; the first slice allows only the varying index, uniform variables, literals, arithmetic/comparison/boolean operators, dynamic-array reads, and local let bindings (SPEC.md §5.15)")]))

(define (tc-spmd-value-let-bindings-pure-at
  [bindings : AstLetBindingList]
  [in-index : bool]) : ResultTcUnit
  (match bindings
    [(AstLetBindingNil) OkTcUnit]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding _ _ init-box)
            (let
              [init : AstExpr (box-get init-box)]
              (match (tc-spmd-value-pure-at init in-index)
                [(OkTcUnit) (tc-spmd-value-let-bindings-pure-at rest in-index)]
                [(ErrTcUnit message) (ErrTcUnit message)]))]))]))

(define (tc-ptr-read-expr [ctx : TcContext] [env : TcTypeEnv] [ptr : AstExpr]) : ResultTcType
  (match (tc-require-unsafe env "ptr-read")
    [(OkTcUnit)
      (match (tc-expr ctx env ptr)
        [(OkTcType ptr-ty)
          (match (tc-raw-pointer-elem
            (tc-resolve-type ctx ptr-ty)
            "typecheck: ptr-read requires a raw pointer operand")
            [(OkTcType elem) (OkTcType (tc-resolve-type ctx elem))]
            [(ErrTcType message) (ErrTcType message)])]
        [(ErrTcType message) (ErrTcType message)])]
    [(ErrTcUnit message) (ErrTcType message)]))

(define (tc-ptr-write-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [ptr : AstExpr]
  [value : AstExpr]) : ResultTcType
  (match (tc-require-unsafe env "ptr-write!")
    [(OkTcUnit)
      (match (tc-expr ctx env ptr)
        [(OkTcType ptr-ty)
          (match (tc-mut-pointer-elem
            (tc-resolve-type ctx ptr-ty)
            "typecheck: ptr-write! requires a MutPtr pointer operand")
            [(OkTcType elem)
              (match (tc-expr ctx env value)
                [(OkTcType value-ty)
                  (match (tc-expect
                    value-ty
                    (tc-resolve-type ctx elem)
                    "typecheck: ptr-write! value type mismatch")
                    [(OkTcUnit) (OkTcType (AstTyUnit))]
                    [(ErrTcUnit message) (ErrTcType message)])]
                [(ErrTcType message) (ErrTcType message)])]
            [(ErrTcType message) (ErrTcType message)])]
        [(ErrTcType message) (ErrTcType message)])]
    [(ErrTcUnit message) (ErrTcType message)]))

(define (tc-ptr-offset-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [ptr : AstExpr]
  [offset : AstExpr]) : ResultTcType
  (match (tc-require-unsafe env "ptr-offset")
    [(OkTcUnit)
      (match (tc-expr ctx env ptr)
        [(OkTcType ptr-ty)
          (let
            [resolved-ptr : AstType (tc-resolve-type ctx ptr-ty)]
            (match (tc-raw-pointer-elem
              resolved-ptr
              "typecheck: ptr-offset requires a raw pointer operand")
              [(OkTcType _)
                (match (tc-expr ctx env offset)
                  [(OkTcType offset-ty)
                    (if (tc-integer-type? offset-ty)
                      (OkTcType resolved-ptr)
                      (ErrTcType
                        "typecheck: ptr-offset requires an integer offset"))]
                  [(ErrTcType message) (ErrTcType message)])]
              [(ErrTcType message) (ErrTcType message)]))]
        [(ErrTcType message) (ErrTcType message)])]
    [(ErrTcUnit message) (ErrTcType message)]))

(define (tc-ptr-cast-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [ptr : AstExpr]
  [target : AstType]) : ResultTcType
  (match (tc-require-unsafe env "ptr-cast")
    [(OkTcUnit)
      (let
        [resolved-target : AstType (tc-resolve-type ctx target)]
        (if (tc-raw-pointer-type? resolved-target)
          (match (tc-expr ctx env ptr)
            [(OkTcType ptr-ty)
              (if (tc-raw-pointer-type? (tc-resolve-type ctx ptr-ty))
                (OkTcType resolved-target)
                (ErrTcType "typecheck: ptr-cast requires a raw pointer operand"))]
            [(ErrTcType message) (ErrTcType message)])
          (ErrTcType "typecheck: ptr-cast target must be a raw pointer type")))]
    [(ErrTcUnit message) (ErrTcType message)]))

(define (tc-ptr-to-int-expr [ctx : TcContext] [env : TcTypeEnv] [ptr : AstExpr]) : ResultTcType
  (match (tc-require-unsafe env "ptr->int")
    [(OkTcUnit)
      (match (tc-expr ctx env ptr)
        [(OkTcType ptr-ty)
          (if (tc-raw-pointer-type? (tc-resolve-type ctx ptr-ty))
            (OkTcType (AstTyU64))
            (ErrTcType "typecheck: ptr->int requires a raw pointer operand"))]
        [(ErrTcType message) (ErrTcType message)])]
    [(ErrTcUnit message) (ErrTcType message)]))

(define (tc-int-to-ptr-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [value : AstExpr]
  [target : AstType]) : ResultTcType
  (match (tc-require-unsafe env "int->ptr")
    [(OkTcUnit)
      (let
        [resolved-target : AstType (tc-resolve-type ctx target)]
        (if (tc-raw-pointer-type? resolved-target)
          (match (tc-expr ctx env value)
            [(OkTcType value-ty)
              (if (tc-integer-type? value-ty)
                (OkTcType resolved-target)
                (ErrTcType "typecheck: int->ptr requires an integer operand"))]
            [(ErrTcType message) (ErrTcType message)])
          (ErrTcType "typecheck: int->ptr target must be a raw pointer type")))]
    [(ErrTcUnit message) (ErrTcType message)]))

(define (tc-string-data-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [str : AstExpr]) : ResultTcType
  (match (tc-require-unsafe env "string-data")
    [(OkTcUnit)
      (match (tc-expr ctx env str)
        [(OkTcType str-ty)
          (if (tc-string-handle-type? str-ty)
            (OkTcType (ast-ty-ptr (AstTyU8)))
            (ErrTcType "typecheck: string-data requires String"))]
        [(ErrTcType message) (ErrTcType message)])]
    [(ErrTcUnit message) (ErrTcType message)]))

(define (tc-string-from-bytes-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [ptr : AstExpr]
  [len : AstExpr]) : ResultTcType
  (match (tc-require-unsafe env "string-from-bytes")
    [(OkTcUnit)
      (match (tc-expr ctx env ptr)
        [(OkTcType ptr-ty)
          (match (tc-type-strip-region (tc-resolve-type ctx ptr-ty))
            [(AstTyPtr elem)
              (if (tc-type-compatible? (box-get elem) (AstTyU8))
                (match (tc-expr ctx env len)
                  [(OkTcType len-ty)
                    (if (tc-integer-type? len-ty)
                      (OkTcType (AstTyString))
                      (ErrTcType
                        "typecheck: string-from-bytes length must be integer"))]
                  [(ErrTcType message) (ErrTcType message)])
                (ErrTcType
                  "typecheck: string-from-bytes pointer must point at u8"))]
            [(AstTyMutPtr elem)
              (if (tc-type-compatible? (box-get elem) (AstTyU8))
                (match (tc-expr ctx env len)
                  [(OkTcType len-ty)
                    (if (tc-integer-type? len-ty)
                      (OkTcType (AstTyString))
                      (ErrTcType
                        "typecheck: string-from-bytes length must be integer"))]
                  [(ErrTcType message) (ErrTcType message)])
                (ErrTcType
                  "typecheck: string-from-bytes pointer must point at u8"))]
            [_
              (ErrTcType
                "typecheck: string-from-bytes requires a raw u8 pointer")])]
        [(ErrTcType message) (ErrTcType message)])]
    [(ErrTcUnit message) (ErrTcType message)]))

(define (tc-array-data-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [array : AstExpr]) : ResultTcType
  (match (tc-require-unsafe env "array-data")
    [(OkTcUnit)
      (match (tc-expr ctx env array)
        [(OkTcType array-ty)
          (match (tc-type-strip-region (tc-resolve-type ctx array-ty))
            [(AstTyArray elem-ty _)
              (OkTcType (ast-ty-mut-ptr (box-get elem-ty)))]
            [(AstTyDynArray elem-ty)
              (OkTcType (ast-ty-mut-ptr (box-get elem-ty)))]
            [_ (ErrTcType "typecheck: array-data requires an array")])]
        [(ErrTcType message) (ErrTcType message)])]
    [(ErrTcUnit message) (ErrTcType message)]))

(define (tc-program-entry-ptr-expr [env : TcTypeEnv] [name : String]) : ResultTcType
  (match (tc-require-unsafe env name)
    [(OkTcUnit) (OkTcType (ast-ty-ptr (ast-ty-ptr (AstTyU8))))]
    [(ErrTcUnit message) (ErrTcType message)]))

(define (tc-cpuid-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [leaf : AstExpr]
  [subleaf : AstExpr]) : ResultTcType
  (match (tc-expr ctx env leaf)
    [(OkTcType leaf-ty)
      (if (tc-integer-type? leaf-ty)
        (match (tc-expr ctx env subleaf)
          [(OkTcType subleaf-ty)
            (if (tc-integer-type? subleaf-ty)
              (OkTcType (AstTyI64))
              (ErrTcType "typecheck: cpuid subleaf must be integer"))]
          [(ErrTcType message) (ErrTcType message)])
        (ErrTcType "typecheck: cpuid leaf must be integer"))]
    [(ErrTcType message) (ErrTcType message)]))

(define (tc-xgetbv-expr [ctx : TcContext] [env : TcTypeEnv] [index : AstExpr]) : ResultTcType
  (match (tc-expr ctx env index)
    [(OkTcType index-ty)
      (if (tc-integer-type? index-ty)
        (OkTcType (AstTyI64))
        (ErrTcType "typecheck: xgetbv index must be integer"))]
    [(ErrTcType message) (ErrTcType message)]))

(define (tc-box-expr [ctx : TcContext] [env : TcTypeEnv] [inner : AstExpr]) : ResultTcType
  (match (tc-ensure-cleanup-resource-not-stored-expr env inner)
    [(OkTcUnit)
      (match (tc-expr ctx env inner)
        [(OkTcType inner-ty)
          (OkTcType (tc-tag-active-region env (ast-ty-box inner-ty)))]
        [(ErrTcType message) (ErrTcType message)])]
    [(ErrTcUnit message) (ErrTcType message)]))

(define (tc-box-get-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [box-expr : AstExpr]) : ResultTcType
  (match (tc-expr ctx env box-expr)
    [(OkTcType box-ty)
      (match (tc-type-strip-region (tc-resolve-type ctx box-ty))
        [(AstTyBox inner-ty)
          (OkTcType
            (tc-project-from-region-container box-ty (box-get inner-ty)))]
        [_ (ErrTcType "typecheck: box-get requires Box type")])]
    [(ErrTcType message) (ErrTcType message)]))

(define (tc-quasiquote-template-list-ok
  [ctx : TcContext]
  [env : TcTypeEnv]
  [exprs : AstExprList]) : ResultTcUnit
  (match exprs
    [(AstExprNil) OkTcUnit]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (box-get head)]
        [rest : AstExprList (box-get rest)]
        (match (tc-quasiquote-template-ok ctx env head)
          [(OkTcUnit) (tc-quasiquote-template-list-ok ctx env rest)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]))

(define (tc-quasiquote-template-ok
  [ctx : TcContext]
  [env : TcTypeEnv]
  [expr : AstExpr]) : ResultTcUnit
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-quasiquote-template-ok ctx env inner))]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-expr ctx env inner)
          [(OkTcType ty)
            (tc-expect ty (AstTyExpr) "typecheck: unquote expects Expr")]
          [(ErrTcType message) (ErrTcUnit message)]))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-expr ctx env inner)
          [(OkTcType ty)
            (tc-expect
              ty
              (AstTyExprList)
              "typecheck: unquote-splicing expects ExprList")]
          [(ErrTcType message) (ErrTcUnit message)]))]
    [(AstExprBinary _ left-box right-box)
      (let
        [left : AstExpr (box-get left-box)]
        [right : AstExpr (box-get right-box)]
        (match (tc-quasiquote-template-ok ctx env left)
          [(OkTcUnit) (tc-quasiquote-template-ok ctx env right)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprUnary _ inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-quasiquote-template-ok ctx env inner))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (box-get func-box)]
        (match (tc-quasiquote-template-ok ctx env func)
          [(OkTcUnit) (tc-quasiquote-template-list-ok ctx env args)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [then-branch : AstExpr (box-get then-branch-box)]
        [else-branch : AstExpr (box-get else-branch-box)]
        (match (tc-quasiquote-template-ok ctx env cond)
          [(OkTcUnit)
            (match (tc-quasiquote-template-ok ctx env then-branch)
              [(OkTcUnit) (tc-quasiquote-template-ok ctx env else-branch)]
              [(ErrTcUnit message) (ErrTcUnit message)])]
          [(ErrTcUnit message) (ErrTcUnit message)]))]
    [(AstExprTuple exprs) (tc-quasiquote-template-list-ok ctx env exprs)]
    [(AstExprArray exprs) (tc-quasiquote-template-list-ok ctx env exprs)]
    [(AstExprBegin exprs) (tc-quasiquote-template-list-ok ctx env exprs)]
    [(AstExprUnsafe exprs) (tc-quasiquote-template-list-ok ctx env exprs)]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-quasiquote-template-ok ctx env inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-quasiquote-template-ok ctx env inner))]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-quasiquote-template-ok ctx env inner))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-quasiquote-template-ok ctx env inner))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-quasiquote-template-ok ctx env inner))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-quasiquote-template-ok ctx env inner))]
    [(AstExprQuote _) OkTcUnit]
    [(AstExprQuasiquote inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-quasiquote-template-ok ctx env inner))]
    [_ OkTcUnit]))

(define (tc-with-escape-unsupported-message [ctx : TcContext] [ty : AstType]) : String
  (string-append
    "typecheck: with-escape result type is not clone-supported: "
    (tc-type-render (tc-type-without-regions (tc-resolve-type ctx ty)))))

;; with-escape is a first-class scratch-arena clone path, not a lexical
;; lifetime binder. The scratch expression is just an arena handle, and
;; supported results leave the form with scratch-region tags erased.
(define (tc-with-escape-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [scratch : AstExpr]
  [body : AstExprList]) : ResultTcType
  (match (tc-expr ctx env scratch)
    [(OkTcType scratch-ty)
      (if (tc-type-eq scratch-ty (AstTyI64))
        (match (tc-begin-list ctx env body)
          [(OkTcType body-ty)
            (if (tc-clone-able-type? ctx body-ty)
              (OkTcType (tc-type-without-regions body-ty))
              (ErrTcType (tc-with-escape-unsupported-message ctx body-ty)))]
          [(ErrTcType message) (ErrTcType message)])
        (ErrTcType "typecheck: with-escape arena must be i64"))]
    [(ErrTcType message) (ErrTcType message)]))

(define (tc-expr [ctx : TcContext] [env : TcTypeEnv] [expr : AstExpr]) : ResultTcType
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-expr ctx env inner))]
    [(AstExprLiteral lit) (OkTcType (tc-literal-type lit))]
    [(AstExprVar name)
      (if (tc-hygiene-global-name? name)
        (let
          [global-name : String (tc-hygiene-global-base name)]
          (if (tc-hygiene-global-binding-unsafe? env global-name)
            (match (tc-require-unsafe env global-name)
              [(OkTcUnit)
                (tc-lookup-hygiene-global-visible ctx env global-name)]
              [(ErrTcUnit message) (ErrTcType message)])
            (tc-lookup-hygiene-global-visible ctx env global-name)))
        (match (tc-lookup-unsafe env name)
          [(OkTcTypeUnsafe ty unsafe)
            (if unsafe
              (match (tc-require-unsafe env name)
                [(OkTcUnit)
                  (match (tc-qualified-value-visible-ok ctx name)
                    [(OkTcUnit) (OkTcType ty)]
                    [(ErrTcUnit message) (ErrTcType message)])]
                [(ErrTcUnit message) (ErrTcType message)])
              (match (tc-qualified-value-visible-ok ctx name)
                [(OkTcUnit) (OkTcType ty)]
                [(ErrTcUnit message) (ErrTcType message)]))]
          [(ErrTcTypeUnsafe message) (ErrTcType message)]))]
    [(AstExprTypeLiteral ty)
      (ErrTcType
        (string-append
          "type value "
          (string-append
            (tc-type-render (tc-resolve-type ctx ty))
            " is compile-time only")))]
    [(AstExprAnn inner-box ty)
      (let
        [inner : AstExpr (box-get inner-box)]
        [want-ty : AstType (tc-resolve-type ctx ty)]
        (match (tc-expr-with-expected-or-actual ctx env inner want-ty)
          [(OkTcType got)
            (match (tc-expect got want-ty "typecheck: annotation type mismatch")
              [(OkTcUnit)
                (OkTcType
                  (if (tc-type-contains-any-region got)
                    got
                    want-ty))]
              [(ErrTcUnit message) (ErrTcType message)])]
          [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (match (tc-let-bindings ctx env bindings)
          [(OkTcEnv next-env)
            (match (tc-expr ctx next-env body)
              [(OkTcType body-ty)
                (match (tc-ensure-reference-type-does-not-escape-names
                  body-ty
                  (tc-let-binding-list-add-bound-names bindings TcStringNil))
                  [(OkTcUnit) (OkTcType body-ty)]
                  [(ErrTcUnit message) (ErrTcType message)])]
              [(ErrTcType message) (ErrTcType message)])]
          [(ErrTcEnv message) (ErrTcType message)]))]
    [(AstExprLambda params maybe-ret body-box)
      (let
        [body : AstExpr (box-get body-box)]
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
              (match (match maybe-ret
                [(AstSomeType ret)
                  (tc-expr-with-expected-or-actual
                    ctx
                    lambda-env
                    body
                    (tc-resolve-type ctx ret))]
                [(AstNoType) (tc-expr ctx lambda-env body)])
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
                              (ast-ty-func
                                (tc-param-type-list ctx params)
                                (tc-resolve-type ctx ret)))]
                          [(ErrTcUnit message) (ErrTcType message)])]
                      [(AstNoType)
                        (OkTcType
                          (ast-ty-func (tc-param-type-list ctx params) body-ty))]))]
                [(ErrTcType message) (ErrTcType message)]))]
          [(ErrTcUnit message) (ErrTcType message)]))]
    [(AstExprTuple exprs)
      (match (tc-ensure-cleanup-resource-not-stored-list env exprs)
        [(OkTcUnit)
          (match (tc-expr-list-types ctx env exprs)
            [(OkTcTypeList tys)
              (OkTcType (tc-tag-active-region env (AstTyTuple tys)))]
            [(ErrTcTypeList message) (ErrTcType message)])]
        [(ErrTcUnit message) (ErrTcType message)])]
    [(AstExprTupleRef tuple-box index)
      (let
        [tuple : AstExpr (box-get tuple-box)]
        (match (tc-expr ctx env tuple)
          [(OkTcType tuple-ty)
            (match (tc-type-strip-region tuple-ty)
              [(AstTyTuple tys)
                (match (tc-type-list-ref tys index)
                  [(OkTcType elem-ty)
                    (OkTcType
                      (tc-project-from-region-container tuple-ty elem-ty))]
                  [(ErrTcType message) (ErrTcType message)])]
              [_ (ErrTcType "typecheck: tuple-ref requires tuple type")])]
          [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprArray exprs)
      (match (tc-ensure-cleanup-resource-not-stored-list env exprs)
        [(OkTcUnit)
          (match exprs
            [(AstExprNil)
              (ErrTcType "typecheck: cannot infer type of empty array")]
            [(AstExprCons first rest)
              (let
                [first : AstExpr (box-get first)]
                [rest : AstExprList (box-get rest)]
                (match (tc-expr ctx env first)
                  [(OkTcType first-ty)
                    (match (tc-check-array-rest ctx env rest first-ty)
                      [(OkTcUnit)
                        (OkTcType
                          (ast-ty-array first-ty (tc-expr-list-len exprs)))]
                      [(ErrTcUnit message) (ErrTcType message)])]
                  [(ErrTcType message) (ErrTcType message)]))])]
        [(ErrTcUnit message) (ErrTcType message)])]
    [(AstExprMakeArray elem-ty len-box)
      (let
        [len : AstExpr (box-get len-box)]
        [elem : AstType (tc-resolve-type ctx elem-ty)]
        (match (tc-expr ctx env len)
          [(OkTcType len-ty)
            (if (tc-integer-type? len-ty)
              (if (tc-dyn-array-elem-supported? env elem)
                (OkTcType (tc-tag-active-region env (ast-ty-dyn-array elem)))
                (ErrTcType
                  "typecheck: make-array element type is not supported"))
              (ErrTcType "typecheck: make-array length must be integer"))]
          [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        (match (tc-expr ctx env array)
          [(OkTcType array-ty)
            (match (tc-expr ctx env index)
              [(OkTcType index-ty)
                (if (tc-integer-type? index-ty)
                  (match (tc-type-strip-region array-ty)
                    [(AstTyArray elem-ty _)
                      (OkTcType
                        (tc-project-from-region-container
                          array-ty
                          (box-get elem-ty)))]
                    [(AstTyDynArray elem-ty)
                      (OkTcType
                        (tc-project-from-region-container
                          array-ty
                          (box-get elem-ty)))]
                    [_ (ErrTcType "typecheck: array-ref requires array type")])
                  (ErrTcType "typecheck: array index must be integer"))]
              [(ErrTcType message) (ErrTcType message)])]
          [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        [value : AstExpr (box-get value-box)]
        (match (tc-expr ctx env array)
          [(OkTcType array-ty)
            (match (tc-expr ctx env index)
              [(OkTcType index-ty)
                (if (tc-integer-type? index-ty)
                  (match (tc-type-strip-region array-ty)
                    [(AstTyArray elem-ty _)
                      (match (tc-expr-with-expected-or-actual
                        ctx
                        env
                        value
                        (box-get elem-ty))
                        [(OkTcType value-ty)
                          (match (tc-expect
                            value-ty
                            (box-get elem-ty)
                            "typecheck: array-set! value type mismatch")
                            [(OkTcUnit)
                              (match (tc-ensure-cleanup-resource-not-stored-expr
                                env
                                value)
                                [(OkTcUnit)
                                  (match (tc-ensure-region-value-can-flow-into
                                    env
                                    array-ty
                                    value-ty
                                    "array")
                                    [(OkTcUnit)
                                      (match (tc-ensure-reference-value-can-store-in-place
                                        ctx
                                        env
                                        array
                                        value-ty
                                        "array")
                                        [(OkTcUnit) (OkTcType (AstTyUnit))]
                                        [(ErrTcUnit message)
                                          (ErrTcType message)])]
                                    [(ErrTcUnit message) (ErrTcType message)])]
                                [(ErrTcUnit message) (ErrTcType message)])]
                            [(ErrTcUnit message) (ErrTcType message)])]
                        [(ErrTcType message) (ErrTcType message)])]
                    [(AstTyDynArray elem-ty)
                      (match (tc-expr-with-expected-or-actual
                        ctx
                        env
                        value
                        (box-get elem-ty))
                        [(OkTcType value-ty)
                          (match (tc-expect
                            value-ty
                            (box-get elem-ty)
                            "typecheck: array-set! value type mismatch")
                            [(OkTcUnit)
                              (match (tc-ensure-cleanup-resource-not-stored-expr
                                env
                                value)
                                [(OkTcUnit)
                                  (match (tc-ensure-region-value-can-flow-into
                                    env
                                    array-ty
                                    value-ty
                                    "array")
                                    [(OkTcUnit)
                                      (match (tc-ensure-reference-value-can-store-in-place
                                        ctx
                                        env
                                        array
                                        value-ty
                                        "array")
                                        [(OkTcUnit) (OkTcType (AstTyUnit))]
                                        [(ErrTcUnit message)
                                          (ErrTcType message)])]
                                    [(ErrTcUnit message) (ErrTcType message)])]
                                [(ErrTcUnit message) (ErrTcType message)])]
                            [(ErrTcUnit message) (ErrTcType message)])]
                        [(ErrTcType message) (ErrTcType message)])]
                    [_ (ErrTcType "typecheck: array-set! requires array type")])
                  (ErrTcType "typecheck: array index must be integer"))]
              [(ErrTcType message) (ErrTcType message)])]
          [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (box-get array-box)]
        [value : AstExpr (box-get value-box)]
        (match (tc-expr ctx env array)
          [(OkTcType array-ty)
            (match (tc-type-strip-region array-ty)
              [(AstTyDynArray elem-ty)
                (match (tc-expr-with-expected-or-actual
                  ctx
                  env
                  value
                  (box-get elem-ty))
                  [(OkTcType value-ty)
                    (match (tc-expect
                      value-ty
                      (box-get elem-ty)
                      "typecheck: array-push! value type mismatch")
                      [(OkTcUnit)
                        (match (tc-ensure-cleanup-resource-not-stored-expr
                          env
                          value)
                          [(OkTcUnit)
                            (match (tc-ensure-region-value-can-flow-into
                              env
                              array-ty
                              value-ty
                              "array")
                              [(OkTcUnit)
                                (match (tc-ensure-reference-value-can-store-in-place
                                  ctx
                                  env
                                  array
                                  value-ty
                                  "array")
                                  [(OkTcUnit) (OkTcType (AstTyUnit))]
                                  [(ErrTcUnit message) (ErrTcType message)])]
                              [(ErrTcUnit message) (ErrTcType message)])]
                          [(ErrTcUnit message) (ErrTcType message)])]
                      [(ErrTcUnit message) (ErrTcType message)])]
                  [(ErrTcType message) (ErrTcType message)])]
              [_
                (ErrTcType "typecheck: array-push! requires dynamic array type")])]
          [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprStringRef str-box index-box)
      (let
        [str : AstExpr (box-get str-box)]
        [index : AstExpr (box-get index-box)]
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
          [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprBegin exprs) (tc-begin-list ctx env exprs)]
    ;; `(unsafe ...)` types like `begin` in v1; the unsafe-context flag for
    ;; raw-pointer ops is added with their checks (#955).
    [(AstExprUnsafe exprs) (tc-begin-list ctx (tc-enter-unsafe env) exprs)]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [then-branch : AstExpr (box-get then-branch-box)]
        [else-branch : AstExpr (box-get else-branch-box)]
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
                      [(OkTcType else-ty)
                        (tc-merge-branch-type then-ty else-ty)]
                      [(ErrTcType message) (ErrTcType message)])]
                  [(ErrTcType message) (ErrTcType message)])]
              [(ErrTcUnit message) (ErrTcType message)])]
          [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprSet name value-box)
      (let
        [value : AstExpr (box-get value-box)]
        (match (tc-lookup-visible ctx env name)
          [(OkTcType var-ty)
            (match (tc-expr-with-expected-or-actual ctx env value var-ty)
              [(OkTcType value-ty)
                (match (tc-expect
                  value-ty
                  var-ty
                  "typecheck: assignment type mismatch")
                  [(OkTcUnit)
                    (match (tc-ensure-cleanup-resource-not-assigned env value)
                      [(OkTcUnit)
                        (match (tc-ensure-region-value-can-flow-into
                          env
                          var-ty
                          value-ty
                          "assignment")
                          [(OkTcUnit)
                            (match (tc-ensure-reference-value-can-assign
                              env
                              name
                              value-ty)
                              [(OkTcUnit) (OkTcType (AstTyUnit))]
                              [(ErrTcUnit message) (ErrTcType message)])]
                          [(ErrTcUnit message) (ErrTcType message)])]
                      [(ErrTcUnit message) (ErrTcType message)])]
                  [(ErrTcUnit message) (ErrTcType message)])]
              [(ErrTcType message) (ErrTcType message)])]
          [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprCast inner-box ty)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-expr ctx env inner)
          [(OkTcType inner-ty)
            (if (and
              (tc-castable-type? inner-ty)
              (tc-castable-type? (tc-resolve-type ctx ty)))
              (OkTcType (tc-resolve-type ctx ty))
              (ErrTcType
                "typecheck: cast requires scalar numeric (integer/char/float) source and target"))]
          [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprBorrow lifetime place-box)
      (let
        [place : AstExpr (box-get place-box)]
        (tc-borrow-expr ctx env lifetime place))]
    [(AstExprUnary op inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-expr ctx env inner)
          [(OkTcType ty) (tc-unop-type op ty)]
          [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (box-get left-box)]
        [right : AstExpr (box-get right-box)]
        (match (tc-expr ctx env left)
          [(OkTcType left-ty)
            (match (tc-expr-with-expected-or-actual ctx env right left-ty)
              [(OkTcType right-ty) (tc-binop-type op left-ty right-ty)]
              [(ErrTcType message) (ErrTcType message)])]
          [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (box-get func-box)]
        (tc-call-or-array-length ctx env func args))]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [body : AstExpr (box-get body-box)]
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
          [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprForeach index index-ty start-box end-box body-box)
      (let
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [body : AstExpr (box-get body-box)]
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
    [(AstExprSpmdReduce op index index-ty start-box end-box init-box value-box)
      (let
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [init : AstExpr (box-get init-box)]
        [value : AstExpr (box-get value-box)]
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
                                  (match (tc-expr-with-expected-or-actual
                                    ctx
                                    value-env
                                    value
                                    init-ty)
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
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (box-get scrutinee-box)]
        (match (tc-expr ctx env scrutinee)
          [(OkTcType scrut-ty) (tc-match-expr ctx env scrut-ty arms)]
          [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprStructGet receiver-box field)
      (let
        [receiver : AstExpr (box-get receiver-box)]
        (match (tc-expr ctx env receiver)
          [(OkTcType receiver-ty)
            (match (tc-type-strip-region receiver-ty)
              [(AstTyStruct struct-name)
                (match (tc-struct-field-type ctx struct-name field)
                  [(OkTcType field-ty)
                    (OkTcType
                      (tc-project-from-region-container receiver-ty field-ty))]
                  [(ErrTcType message) (ErrTcType message)])]
              [(AstTyStructArgs struct-name lifetimes)
                (match (tc-struct-field-type-with-args
                  ctx
                  struct-name
                  lifetimes
                  field)
                  [(OkTcType field-ty)
                    (OkTcType
                      (tc-project-from-region-container receiver-ty field-ty))]
                  [(ErrTcType message) (ErrTcType message)])]
              [_ (ErrTcType "typecheck: struct-get requires struct")])]
          [(ErrTcType message) (ErrTcType message)]))]
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
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (box-get scratch-box)]
        (tc-with-escape-expr ctx env scratch body))]
    [(AstExprWithResource bindings body)
      (match (tc-resource-bindings ctx env bindings)
        [(OkTcEnv body-env)
          (match (tc-begin-list ctx body-env body)
            [(OkTcType body-ty)
              (if (tc-expr-list-result-uses-cleanup-owner?
                body
                (tc-resource-binding-list-add-bound-names bindings TcStringNil)
                TcStringNil)
                (ErrTcType
                  "typecheck: cleanup-required resource would escape with scope")
                (OkTcType body-ty))]
            [(ErrTcType message) (ErrTcType message)])]
        [(ErrTcEnv message) (ErrTcType message)])]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-box-expr ctx env inner))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-box-get-expr ctx env inner))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (compiler-ctfe-eval inner (tc-ctfe-env ctx) (ctfe-fuel-limit))
          [(OkCtfe value _)
            (match value
              [(CtfeI64 _) (OkTcType (AstTyI64))]
              [(CtfeBool _) (OkTcType (AstTyBool))]
              [(CtfeChar _) (OkTcType (AstTyChar))]
              [(CtfeString _) (ErrTcType "String value is compile-time only")]
              [(CtfeUnit) (OkTcType (AstTyUnit))]
              [(CtfeExpr _ _) (OkTcType (AstTyExpr))]
              [(CtfeType ty)
                (ErrTcType
                  (string-append
                    "type value "
                    (string-append
                      (tc-type-render (tc-resolve-type ctx ty))
                      " is compile-time only")))]
              [(CtfeExprList _) (OkTcType (AstTyExprList))])]
          [(ErrCtfe diag) (ErrTcType (compiler-diagnostic-message diag))]))]
    [(AstExprQuote _) (OkTcType (AstTyExpr))]
    [(AstExprQuasiquote template-box)
      (let
        [template : AstExpr (box-get template-box)]
        (match (tc-quasiquote-template-ok ctx env template)
          [(OkTcUnit) (OkTcType (AstTyExpr))]
          [(ErrTcUnit message) (ErrTcType message)]))]
    [(AstExprUnquote _)
      (ErrTcType "typecheck: unquote is only valid inside quasiquote")]
    [(AstExprUnquoteSplicing _)
      (ErrTcType "typecheck: unquote-splicing is only valid inside quasiquote")]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-try-expr ctx env inner))]
    [(AstExprReturn value-box)
      (let
        [value : AstExpr (box-get value-box)]
        (tc-return-expr ctx env value))]
    [(AstExprPtrNull ty)
      (let
        [resolved : AstType (tc-resolve-type ctx ty)]
        (match resolved
          [(AstTyPtr _) (OkTcType resolved)]
          [(AstTyMutPtr _) (OkTcType resolved)]
          [_
            (ErrTcType
              "typecheck: ptr-null requires a pointer type, e.g. (ptr-null : (Ptr i64))")]))]
    [(AstExprPtrNullCheck inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-expr ctx env inner)
          [(OkTcType inner-ty)
            (match (tc-type-strip-region inner-ty)
              [(AstTyPtr _) (OkTcType (AstTyBool))]
              [(AstTyMutPtr _) (OkTcType (AstTyBool))]
              [_
                (ErrTcType
                  "typecheck: ptr-null? requires a raw pointer operand")])]
          [(ErrTcType message) (ErrTcType message)]))]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (tc-ptr-read-expr ctx env ptr))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [value : AstExpr (box-get value-box)]
        (tc-ptr-write-expr ctx env ptr value))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [offset : AstExpr (box-get offset-box)]
        (tc-ptr-offset-expr ctx env ptr offset))]
    [(AstExprPtrCast ptr-box target)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (tc-ptr-cast-expr ctx env ptr target))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (tc-ptr-to-int-expr ctx env ptr))]
    [(AstExprIntToPtr value-box target)
      (let
        [value : AstExpr (box-get value-box)]
        (tc-int-to-ptr-expr ctx env value target))]
    [(AstExprStringData str-box)
      (let
        [str : AstExpr (box-get str-box)]
        (tc-string-data-expr ctx env str))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [len : AstExpr (box-get len-box)]
        (tc-string-from-bytes-expr ctx env ptr len))]
    [(AstExprArrayData array-box)
      (let
        [array : AstExpr (box-get array-box)]
        (tc-array-data-expr ctx env array))]
    [(AstExprProgramArgc) (OkTcType (AstTyI64))]
    [(AstExprProgramArgv) (tc-program-entry-ptr-expr env "program-argv")]
    [(AstExprProgramEnvp) (tc-program-entry-ptr-expr env "program-envp")]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (tc-cpuid-expr ctx env leaf subleaf))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (tc-cpuid-expr ctx env leaf subleaf))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (tc-cpuid-expr ctx env leaf subleaf))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (tc-cpuid-expr ctx env leaf subleaf))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (box-get index-box)]
        (tc-xgetbv-expr ctx env index))]
    [_ (ErrTcType "typecheck: unsupported expression")]))

(define (tc-extern-abi-value-type-ok? [ty : AstType]) : bool
  (match (tc-type-without-regions ty)
    [(AstTyI64) true]
    [(AstTyI32) true]
    [(AstTyI16) true]
    [(AstTyI8) true]
    [(AstTyU64) true]
    [(AstTyU32) true]
    [(AstTyU16) true]
    [(AstTyU8) true]
    [(AstTyF64) true]
    [(AstTyBool) true]
    [(AstTyChar) true]
    [(AstTyUnit) true]
    [(AstTyNever) true]
    [(AstTyFunc _ _) true]
    [(AstTyPtr _) true]
    [(AstTyMutPtr _) true]
    [(AstTyString) true]
    [(AstTyDynArray _) true]
    [(AstTyEnum _) true]
    [(AstTyEnumArgs _ _) true]
    [(AstTyStruct _) true]
    [(AstTyStructArgs _ _) true]
    [_ false]))

(define (tc-extern-abi-unsupported-message [position : String] [ty : AstType]) : String
  (string-append
    "typecheck: extern ABI c does not support "
    (string-append position (string-append " type " (tc-type-render ty)))))

(define (tc-check-extern-arg-abi [args : AstTypeList]) : ResultTcUnit
  (match args
    [(AstTypeNil) OkTcUnit]
    [(AstTypeCons head rest)
      (let
        [head : AstType (box-get head)]
        [rest : AstTypeList (box-get rest)]
        (if (tc-extern-abi-value-type-ok? head)
          (tc-check-extern-arg-abi rest)
          (ErrTcUnit (tc-extern-abi-unsupported-message "parameter" head))))]))

(define (tc-check-extern-c-abi [ty : AstType]) : ResultTcUnit
  (match ty
    [(AstTyFunc args ret)
      (match (tc-check-extern-arg-abi args)
        [(OkTcUnit)
          (if (tc-extern-abi-value-type-ok? (box-get ret))
            OkTcUnit
            (ErrTcUnit
              (tc-extern-abi-unsupported-message "return" (box-get ret))))]
        [(ErrTcUnit message) (ErrTcUnit message)])]
    [_ (ErrTcUnit "typecheck: extern must have function type")]))

(define (tc-check-extern-varargs-fixed-count [fixed-count : i64] [ty : AstType]) : ResultTcUnit
  (match ty
    [(AstTyFunc args _)
      (if (<= fixed-count (tc-type-list-len args))
        OkTcUnit
        (ErrTcUnit
          "typecheck: extern c-varargs fixed argument count exceeds parameter count"))]
    [_ (ErrTcUnit "typecheck: extern must have function type")]))

(define (tc-check-extern-decl
  [ctx : TcContext]
  [metadata : AstExternMetadata]
  [ty : AstType]) : ResultTcUnit
  (match metadata
    [(AstExternMetadata abi _ _)
      (if (ast-extern-abi-c? abi)
        (let
          [resolved : AstType (tc-resolve-type ctx ty)]
          (match (tc-check-extern-c-abi resolved)
            [(OkTcUnit)
              (if (ast-extern-abi-c-varargs? abi)
                (tc-check-extern-varargs-fixed-count
                  (ast-extern-abi-varargs-fixed-count abi)
                  resolved)
                OkTcUnit)]
            [(ErrTcUnit message) (ErrTcUnit message)]))
        (ErrTcUnit "typecheck: unsupported extern ABI"))]))

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
        [(AstDeclExtern _ _ _)
          (CompilerTypecheckSummary values functions (+ externs 1))]
        [(AstDeclComptimeDecl _ template-box)
          (let
            [template : AstDecl (box-get template-box)]
            (tc-summary-add-decl summary template))]
        [(AstDeclUnsafe inner-box)
          (let
            [inner : AstDecl (box-get inner-box)]
            (tc-summary-add-decl summary inner))]
        [_ summary])]))

(define (tc-check-defmacro-produced-type
  [ctx : TcContext]
  [ret : AstType]
  [value : CompilerCtfeValue]) : ResultTcUnit
  (match value
    [(CtfeExpr _ produced)
      (if (or
        (tc-type-eq produced (AstTyExpr))
        (tc-type-compatible?
          (tc-resolve-type ctx ret)
          (tc-resolve-type ctx produced)))
        OkTcUnit
        (ErrTcUnit
          "typecheck: macro body produced type does not match declaration"))]
    [_ (ErrTcUnit "typecheck: macro body must return Expr")]))

(define (tc-check-defmacro
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [params : AstMacroParamList]
  [ret : AstType]
  [body : AstExpr]) : ResultTcUnit
  (let
    [macro-env : TcTypeEnv
      (tc-bind-macro-params ctx (tc-macro-helper-env top-env) params)]
    (match (tc-expr ctx macro-env body)
      [(OkTcType got)
        (match (tc-expect
          got
          (AstTyExpr)
          "typecheck: macro body must return Expr")
          [(OkTcUnit)
            (match (compiler-ctfe-eval
              body
              (tc-ctfe-env-extend-macro-params ctx (tc-ctfe-env ctx) params)
              (ctfe-fuel-limit))
              [(OkCtfe value _) (tc-check-defmacro-produced-type ctx ret value)]
              [(ErrCtfe diag) (ErrTcUnit (compiler-diagnostic-message diag))])]
          [(ErrTcUnit message) (ErrTcUnit message)])]
      [(ErrTcType message) (ErrTcUnit message)])))

;; --- whole-local move checker (#1048/#1049) ---------------------------------
;;
;; Reject use-after-move for move-only whole locals/parameters in source
;; evaluation order. The staged owner-only policy keeps ordinary aggregate
;; sharing compatible, while consuming only by-value sites whose target is an
;; owner today: cleanup-owning structs and Box values. Reads never move; branches
;; merge by union (a place moved on any arm is moved afterward). Loops reject
;; owner moves from values visible before the repeated body, then discard body
;; moves for the post-state because they may run zero times; lambdas still
;; discard their body's moves because they may be deferred. Reassigning a slot
;; with `set!` clears its moved mark. Owner-consuming struct fields, tuple
;; elements, and fixed-array literal elements are tracked as root paths so
;; unrelated entries remain usable. Nested direct-root struct/tuple/fixed-array
;; literal chains are represented by stable path strings. Box and non-literal
;; aggregate projections stay rejected until their path/reinitialization policy
;; lands; dynamic arrays have a separate diagnostic because element ownership
;; cannot be made sound without an index policy.
(defstruct TcMovedSet
  (map StringI64Map))

(defenum TcMoveResult
  (OkTcMove TcMovedSet)
  (ErrTcMove String))

(defenum TcMoveBindings
  (OkTcMoveBindings TcTypeEnv TcMovedSet TcMovedSet TcMovedSet)
  (ErrTcMoveBindings String))

(defenum TcMoveMaybeIndex
  (TcMoveNoIndex)
  (TcMoveSomeIndex i64))

(define (tc-moved-empty) : TcMovedSet
  (TcMovedSet (string-i64-map-with-capacity 8)))

(define (tc-moved-map [set : TcMovedSet]) : StringI64Map
  (struct-get set map))

(define (tc-moved-len [set : TcMovedSet]) : i64
  (string-i64-map-len (tc-moved-map set)))

(define (tc-moved-capacity [set : TcMovedSet]) : i64
  (string-i64-map-capacity (tc-moved-map set)))

(define (tc-moved-clone [set : TcMovedSet]) : TcMovedSet
  (let
    [map : StringI64Map (tc-moved-map set)]
    (TcMovedSet (string-i64-map-resized map (string-i64-map-capacity map)))))

(define (tc-moved-contains? [set : TcMovedSet] [name : String]) : bool
  (string-i64-map-contains? (tc-moved-map set) name))

(define (tc-moved-add [set : TcMovedSet] [name : String]) : TcMovedSet
  (TcMovedSet (string-i64-map-put (tc-moved-map set) name 1)))

(define (tc-moved-remove [set : TcMovedSet] [name : String]) : TcMovedSet
  (match (string-i64-map-remove (tc-moved-map set) name)
    [(StringI64MapRemoveOk map) (TcMovedSet map)]
    [(StringI64MapRemoveMissing map) (TcMovedSet map)]))

(define (tc-move-use-message [name : String]) : String
  (string-append (string-append "typecheck: use of moved value `" name) "`"))

(define (tc-move-loop-carried-message [name : String]) : String
  (string-append
    (string-append "typecheck: cannot move loop-carried owner value `" name)
    "`"))

(define (tc-moved-path-key [path : String]) : String
  (string-append "\npath:" path))

(define (tc-moved-partial-key [name : String]) : String
  (string-append "\npartial:" name))

(define (tc-moved-partial? [set : TcMovedSet] [name : String]) : bool
  (tc-moved-contains? set (tc-moved-partial-key name)))

(define (tc-moved-path-key? [key : String]) : bool
  (tc-move-string-prefix-at? key (tc-moved-path-key "") 0))

(define (tc-moved-path-key-conflicts? [key : String] [path : String]) : bool
  (let
    [new-key : String (tc-moved-path-key path)]
    [descendant-prefix : String (tc-moved-path-key (string-append path "."))]
    [ancestor-prefix : String (string-append key ".")]
    (if (tc-moved-path-key? key)
      (or
        (string-eq key new-key)
        (or
          (tc-move-string-prefix-at? key descendant-prefix 0)
          (tc-move-string-prefix-at? new-key ancestor-prefix 0)))
      false)))

(define (tc-moved-path-conflict-loop
  [map : StringI64Map]
  [path : String]
  [index : i64]) : bool
  (if (>= index (string-i64-map-capacity map))
    false
    (match (string-i64-map-entry-at map index)
      [(StringI64MapEntrySome key _)
        (if (tc-moved-path-key-conflicts? key path)
          true
          (tc-moved-path-conflict-loop
            map
            path
            (string-i64-map-next-occupied map (+ index 1))))]
      [(StringI64MapEntryNone)
        (tc-moved-path-conflict-loop
          map
          path
          (string-i64-map-next-occupied map (+ index 1)))])))

(define (tc-moved-path-conflict? [set : TcMovedSet] [path : String]) : bool
  (tc-moved-path-conflict-loop
    (tc-moved-map set)
    path
    (string-i64-map-next-occupied (tc-moved-map set) 0)))

(define (tc-move-string-prefix-at-loop
  [text : String]
  [prefix : String]
  [start : i64]
  [index : i64]
  [prefix-len : i64]) : bool
  (if (>= index prefix-len)
    true
    (if (= (string-ref text (+ start index)) (string-ref prefix index))
      (tc-move-string-prefix-at-loop text prefix start (+ index 1) prefix-len)
      false)))

(define (tc-move-string-prefix-at?
  [text : String]
  [prefix : String]
  [start : i64]) : bool
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
    (if (or (< start 0) (> (+ start prefix-len) text-len))
      false
      (tc-move-string-prefix-at-loop text prefix start 0 prefix-len))))

(define (tc-moved-remove-prefix-loop
  [map : StringI64Map]
  [prefix : String]
  [index : i64]
  [out : TcMovedSet]) : TcMovedSet
  (if (>= index (string-i64-map-capacity map))
    out
    (match (string-i64-map-entry-at map index)
      [(StringI64MapEntrySome key _)
        (let
          [next : i64 (string-i64-map-next-occupied map (+ index 1))]
          [out2 : TcMovedSet
            (if (tc-move-string-prefix-at? key prefix 0)
              (tc-moved-remove out key)
              out)]
          (tc-moved-remove-prefix-loop map prefix next out2))]
      [(StringI64MapEntryNone)
        (tc-moved-remove-prefix-loop
          map
          prefix
          (string-i64-map-next-occupied map (+ index 1))
          out)])))

(define (tc-moved-remove-prefix [set : TcMovedSet] [prefix : String]) : TcMovedSet
  (tc-moved-remove-prefix-loop
    (tc-moved-map set)
    prefix
    (string-i64-map-next-occupied (tc-moved-map set) 0)
    set))

(define (tc-moved-remove-root-state [set : TcMovedSet] [name : String]) : TcMovedSet
  (tc-moved-remove-prefix
    (tc-moved-remove (tc-moved-remove set name) (tc-moved-partial-key name))
    (tc-moved-path-key (string-append name "."))))

(define (tc-moved-union-loop
  [a : StringI64Map]
  [index : i64]
  [out : TcMovedSet]) : TcMovedSet
  (if (>= index (string-i64-map-capacity a))
    out
    (match (string-i64-map-entry-at a index)
      [(StringI64MapEntrySome key _)
        (tc-moved-union-loop
          a
          (string-i64-map-next-occupied a (+ index 1))
          (tc-moved-add out key))]
      [(StringI64MapEntryNone)
        (tc-moved-union-loop a (string-i64-map-next-occupied a (+ index 1)) out)])))

(define (tc-moved-union [a : TcMovedSet] [b : TcMovedSet]) : TcMovedSet
  (tc-moved-union-loop
    (tc-moved-map a)
    (string-i64-map-next-occupied (tc-moved-map a) 0)
    b))

(define (tc-move-var-move-only? [env : TcTypeEnv] [name : String]) : bool
  (match (tc-lookup env name)
    [(OkTcType ty) (tc-type-move-only? ty)]
    [(ErrTcType _) false]))

(define (tc-type-consuming-by-value-now? [ctx : TcContext] [ty : AstType]) : bool
  (let
    [resolved : AstType (tc-type-strip-region (tc-resolve-type ctx ty))]
    (match resolved
      [(AstTyBox _) true]
      [(AstTyStruct _) (tc-cleanup-owning-struct-type? ctx resolved)]
      [(AstTyStructArgs _ _) (tc-cleanup-owning-struct-type? ctx resolved)]
      [_ false])))

;; Cleanup-owning enum metadata is not represented yet, so match scrutinees stay
;; compatibility-non-consuming until that owner shape exists.
(define (tc-type-consuming-match-scrutinee-now?
  [ctx : TcContext]
  [ty : AstType]) : bool
  false)

;; The bare variable named by an init/rhs expression, unwrapping spans and
;; annotations, or none if the expression is not a whole-variable reference.
(define (tc-move-bare-var [expr : AstExpr]) : TcMaybeString
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-bare-var inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-bare-var inner))]
    [(AstExprVar name) (TcSomeString name)]
    [_ (TcNoString)]))

;; The root local named by a projection chain. This intentionally returns bare
;; variables too so consuming sites can share one helper for whole values and
;; projected owner fields/elements.
(define (tc-move-root-projection-var [expr : AstExpr]) : TcMaybeString
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-root-projection-var inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-root-projection-var inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-root-projection-var inner))]
    [(AstExprStructGet inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-root-projection-var inner))]
    [(AstExprTupleRef inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-root-projection-var inner))]
    [(AstExprArrayRef array-box _)
      (let
        [array : AstExpr (box-get array-box)]
        (tc-move-root-projection-var array))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-root-projection-var inner))]
    [(AstExprVar name) (TcSomeString name)]
    [_ (TcNoString)]))

(define (tc-move-dynamic-array-element-message) : String
  "typecheck: cannot move owner-consuming value out of dynamic array element")

(define (tc-move-box-projection-message) : String
  "typecheck: cannot move owner-consuming value out of box")

(define (tc-move-aggregate-path-message) : String
  "typecheck: cannot move owner-consuming value out of aggregate path")

(define (tc-move-aggregate-path-projection? [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-aggregate-path-projection? inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-aggregate-path-projection? inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-aggregate-path-projection? inner))]
    [(AstExprStructGet _ _) true]
    [(AstExprTupleRef _ _) true]
    [(AstExprArrayRef _ _) true]
    [(AstExprBoxGet _) true]
    [_ false]))

(define (tc-move-path-append [base : String] [field : String]) : String
  (string-append (string-append base ".") field))

(define (tc-move-tuple-index-path [base : String] [index : i64]) : String
  (string-append (string-append base ".#tuple.") (int->string index)))

(define (tc-move-array-index-path [base : String] [index : i64]) : String
  (string-append (string-append base ".#array.") (int->string index)))

(define (tc-move-literal-index [expr : AstExpr]) : TcMoveMaybeIndex
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-literal-index inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-literal-index inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-literal-index inner))]
    [(AstExprLiteral lit)
      (match lit
        [(AstLitInt index) (TcMoveSomeIndex index)]
        [_ (TcMoveNoIndex)])]
    [_ (TcMoveNoIndex)]))

(define (tc-move-direct-root-base-path [expr : AstExpr]) : TcMaybeString
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-direct-root-base-path inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-direct-root-base-path inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-direct-root-base-path inner))]
    [(AstExprStructGet inner-box field)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-move-direct-root-base-path inner)
          [(TcSomeString base) (TcSomeString (tc-move-path-append base field))]
          [(TcNoString) (TcNoString)]))]
    [(AstExprTupleRef inner-box index)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-move-direct-root-base-path inner)
          [(TcSomeString base)
            (TcSomeString (tc-move-tuple-index-path base index))]
          [(TcNoString) (TcNoString)]))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index-expr : AstExpr (box-get index-box)]
        (match (tc-move-direct-root-base-path array)
          [(TcSomeString base)
            (match (tc-move-literal-index index-expr)
              [(TcMoveSomeIndex index)
                (TcSomeString (tc-move-array-index-path base index))]
              [(TcMoveNoIndex) (TcNoString)])]
          [(TcNoString) (TcNoString)]))]
    [(AstExprVar name) (TcSomeString name)]
    [_ (TcNoString)]))

(define (tc-move-struct-field-path [expr : AstExpr]) : TcMaybeString
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-struct-field-path inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-struct-field-path inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-struct-field-path inner))]
    [(AstExprStructGet inner-box field)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-move-direct-root-base-path inner)
          [(TcSomeString base) (TcSomeString (tc-move-path-append base field))]
          [(TcNoString) (TcNoString)]))]
    [_ (TcNoString)]))

(define (tc-move-tuple-element-path [expr : AstExpr]) : TcMaybeString
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-tuple-element-path inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-tuple-element-path inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-tuple-element-path inner))]
    [(AstExprTupleRef inner-box index)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-move-direct-root-base-path inner)
          [(TcSomeString base)
            (TcSomeString (tc-move-tuple-index-path base index))]
          [(TcNoString) (TcNoString)]))]
    [_ (TcNoString)]))

(define (tc-move-array-element-path [expr : AstExpr]) : TcMaybeString
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-array-element-path inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-array-element-path inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-array-element-path inner))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index-expr : AstExpr (box-get index-box)]
        (match (tc-move-direct-root-base-path array)
          [(TcSomeString base)
            (match (tc-move-literal-index index-expr)
              [(TcMoveSomeIndex index)
                (TcSomeString (tc-move-array-index-path base index))]
              [(TcMoveNoIndex) (TcNoString)])]
          [(TcNoString) (TcNoString)]))]
    [_ (TcNoString)]))

(define (tc-move-projection-path [expr : AstExpr]) : TcMaybeString
  (match (tc-move-struct-field-path expr)
    [(TcSomeString path) (TcSomeString path)]
    [(TcNoString)
      (match (tc-move-tuple-element-path expr)
        [(TcSomeString path) (TcSomeString path)]
        [(TcNoString) (tc-move-array-element-path expr)])]))

(define (tc-moved-add-projection-path
  [moved : TcMovedSet]
  [root : String]
  [path : String]) : TcMovedSet
  (tc-moved-add
    (tc-moved-add moved (tc-moved-path-key path))
    (tc-moved-partial-key root)))

(define (tc-move-box-projection? [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-box-projection? inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-box-projection? inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-box-projection? inner))]
    [(AstExprStructGet inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-box-projection? inner))]
    [(AstExprTupleRef inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-box-projection? inner))]
    [(AstExprArrayRef array-box _)
      (let
        [array : AstExpr (box-get array-box)]
        (tc-move-box-projection? array))]
    [(AstExprBoxGet _) true]
    [_ false]))

(define (tc-move-dynamic-array-element-projection?
  [ctx : TcContext]
  [env : TcTypeEnv]
  [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-dynamic-array-element-projection? ctx env inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-dynamic-array-element-projection? ctx env inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-dynamic-array-element-projection? ctx env inner))]
    [(AstExprStructGet inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-dynamic-array-element-projection? ctx env inner))]
    [(AstExprTupleRef inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-dynamic-array-element-projection? ctx env inner))]
    [(AstExprArrayRef array-box _)
      (let
        [array : AstExpr (box-get array-box)]
        (match (tc-expr ctx env array)
          [(OkTcType array-ty)
            (match (tc-type-strip-region (tc-resolve-type ctx array-ty))
              [(AstTyDynArray _) true]
              [_ (tc-move-dynamic-array-element-projection? ctx env array)])]
          [(ErrTcType _)
            (tc-move-dynamic-array-element-projection? ctx env array)]))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-dynamic-array-element-projection? ctx env inner))]
    [_ false]))

(define (tc-move-binding-type
  [ctx : TcContext]
  [env : TcTypeEnv]
  [maybe-ty : AstMaybeType]
  [init : AstExpr]) : AstType
  (match maybe-ty
    [(AstSomeType t) (tc-resolve-type ctx t)]
    [(AstNoType)
      (match (tc-expr ctx env init)
        [(OkTcType t) t]
        [(ErrTcType _) (AstTyI64)])]))

;; The names that are genuine local/parameter bindings, seeded from a function's
;; parameter list. Only these are tracked as movable places; enum constructors,
;; globals, and function references share the variable syntax but are never moved.
(define (tc-move-params-locals [params : AstParamList] [acc : TcMovedSet]) : TcMovedSet
  (match params
    [(AstParamNil) acc]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam name _ _)
            (tc-move-params-locals rest (tc-moved-add acc name))]))]))

;; Mark the source variable moved when an init/rhs is a bare move-only variable
;; that names a tracked local/parameter (not an enum constructor or global).
(define (tc-move-after-bind
  [ctx : TcContext]
  [env : TcTypeEnv]
  [locals : TcMovedSet]
  [loop-carried : TcMovedSet]
  [moved : TcMovedSet]
  [init : AstExpr]) : TcMoveResult
  (match (tc-move-bare-var init)
    [(TcSomeString v)
      (if (and (tc-moved-contains? locals v) (tc-move-var-move-only? env v))
        (if (tc-moved-partial? moved v)
          (ErrTcMove (tc-move-use-message v))
          (if (tc-moved-contains? loop-carried v)
            (ErrTcMove (tc-move-loop-carried-message v))
            (OkTcMove (tc-moved-add moved v))))
        (OkTcMove moved))]
    [(TcNoString)
      (match (tc-expr ctx env init)
        [(OkTcType init-ty)
          (if (tc-type-consuming-by-value-now? ctx init-ty)
            (if (tc-move-dynamic-array-element-projection? ctx env init)
              (ErrTcMove (tc-move-dynamic-array-element-message))
              (if (tc-move-box-projection? init)
                (ErrTcMove (tc-move-box-projection-message))
                (match (tc-move-projection-path init)
                  [(TcSomeString path)
                    (match (tc-move-root-projection-var init)
                      [(TcSomeString root)
                        (if (tc-moved-contains? locals root)
                          (if (tc-moved-path-conflict? moved path)
                            (ErrTcMove (tc-move-use-message path))
                            (OkTcMove
                              (tc-moved-add-projection-path moved root path)))
                          (OkTcMove moved))]
                      [(TcNoString) (OkTcMove moved)])]
                  [(TcNoString)
                    (if (tc-move-aggregate-path-projection? init)
                      (ErrTcMove (tc-move-aggregate-path-message))
                      (match (tc-move-root-projection-var init)
                        [(TcSomeString root)
                          (if (tc-moved-contains? locals root)
                            (if (tc-moved-partial? moved root)
                              (ErrTcMove (tc-move-use-message root))
                              (if (tc-moved-contains? loop-carried root)
                                (ErrTcMove (tc-move-loop-carried-message root))
                                (OkTcMove (tc-moved-add moved root))))
                            (OkTcMove moved))]
                        [(TcNoString) (OkTcMove moved)]))])))
            (OkTcMove moved))]
        [(ErrTcType _) (OkTcMove moved)])]))

(define (tc-move-after-consuming-value
  [ctx : TcContext]
  [env : TcTypeEnv]
  [locals : TcMovedSet]
  [loop-carried : TcMovedSet]
  [moved : TcMovedSet]
  [expr : AstExpr]
  [target-ty : AstType]) : TcMoveResult
  (if (tc-type-consuming-by-value-now? ctx target-ty)
    (if (tc-move-dynamic-array-element-projection? ctx env expr)
      (ErrTcMove (tc-move-dynamic-array-element-message))
      (if (tc-move-box-projection? expr)
        (ErrTcMove (tc-move-box-projection-message))
        (match (tc-move-projection-path expr)
          [(TcSomeString path)
            (match (tc-move-root-projection-var expr)
              [(TcSomeString root)
                (if (tc-moved-contains? locals root)
                  (if (tc-moved-path-conflict? moved path)
                    (ErrTcMove (tc-move-use-message path))
                    (OkTcMove (tc-moved-add-projection-path moved root path)))
                  (OkTcMove moved))]
              [(TcNoString) (OkTcMove moved)])]
          [(TcNoString)
            (if (tc-move-aggregate-path-projection? expr)
              (ErrTcMove (tc-move-aggregate-path-message))
              (match (tc-move-root-projection-var expr)
                [(TcSomeString root)
                  (if (tc-moved-contains? locals root)
                    (if (tc-moved-partial? moved root)
                      (ErrTcMove (tc-move-use-message root))
                      (if (tc-moved-contains? loop-carried root)
                        (ErrTcMove (tc-move-loop-carried-message root))
                        (OkTcMove (tc-moved-add moved root))))
                    (OkTcMove moved))]
                [(TcNoString) (OkTcMove moved)]))])))
    (OkTcMove moved)))

(define (tc-move-after-match-scrutinee
  [ctx : TcContext]
  [locals : TcMovedSet]
  [moved : TcMovedSet]
  [expr : AstExpr]
  [scrut-ty : AstType]) : TcMovedSet
  (match (tc-move-bare-var expr)
    [(TcSomeString v)
      (if (and
        (tc-moved-contains? locals v)
        (tc-type-consuming-match-scrutinee-now? ctx scrut-ty))
        (tc-moved-add moved v)
        moved)]
    [(TcNoString) moved]))

(define (tc-move-check-exprs-with-types
  [ctx : TcContext]
  [env : TcTypeEnv]
  [locals : TcMovedSet]
  [loop-carried : TcMovedSet]
  [moved : TcMovedSet]
  [exprs : AstExprList]
  [types : AstTypeList]) : TcMoveResult
  (match exprs
    [(AstExprNil)
      (match types
        [(AstTypeNil) (OkTcMove moved)]
        [_ (ErrTcMove "typecheck: arity mismatch")])]
    [(AstExprCons head rest)
      (let
        [head-expr : AstExpr (box-get head)]
        [rest : AstExprList (box-get rest)]
        (match types
          [(AstTypeCons ty rest-types)
            (let
              [ty : AstType (box-get ty)]
              [rest-types : AstTypeList (box-get rest-types)]
              (match (tc-move-check-expr
                ctx
                env
                locals
                loop-carried
                moved
                head-expr)
                [(OkTcMove moved1)
                  (match (tc-move-after-consuming-value
                    ctx
                    env
                    locals
                    loop-carried
                    moved1
                    head-expr
                    ty)
                    [(OkTcMove moved2)
                      (tc-move-check-exprs-with-types
                        ctx
                        env
                        locals
                        loop-carried
                        moved2
                        rest
                        rest-types)]
                    [(ErrTcMove message) (ErrTcMove message)])]
                [(ErrTcMove message) (ErrTcMove message)]))]
          [(AstTypeNil) (ErrTcMove "typecheck: arity mismatch")]))]))

(define (tc-move-call-param-types
  [ctx : TcContext]
  [env : TcTypeEnv]
  [func : AstExpr]) : ResultTcTypeList
  (match (tc-expr ctx env func)
    [(OkTcType fn-ty)
      (match (tc-type-strip-region fn-ty)
        [(AstTyFunc params _) (OkTcTypeList params)]
        [(AstTyEnum _) (OkTcTypeList AstTypeNil)]
        [(AstTyEnumArgs _ _) (OkTcTypeList AstTypeNil)]
        [_ (ErrTcTypeList "typecheck: call target is not a function")])]
    [(ErrTcType message) (ErrTcTypeList message)]))

(define (tc-move-check-exprs
  [ctx : TcContext]
  [env : TcTypeEnv]
  [locals : TcMovedSet]
  [loop-carried : TcMovedSet]
  [moved : TcMovedSet]
  [exprs : AstExprList]) : TcMoveResult
  (match exprs
    [(AstExprNil) (OkTcMove moved)]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (box-get head)]
        [rest : AstExprList (box-get rest)]
        (match (tc-move-check-expr ctx env locals loop-carried moved head)
          [(OkTcMove moved1)
            (tc-move-check-exprs ctx env locals loop-carried moved1 rest)]
          [(ErrTcMove message) (ErrTcMove message)]))]))

(define (tc-move-check-let-bindings
  [ctx : TcContext]
  [env : TcTypeEnv]
  [locals : TcMovedSet]
  [loop-carried : TcMovedSet]
  [moved : TcMovedSet]
  [bindings : AstLetBindingList]) : TcMoveBindings
  (match bindings
    [(AstLetBindingNil) (OkTcMoveBindings env moved locals loop-carried)]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name maybe-ty init-box)
            (let
              [init : AstExpr (box-get init-box)]
              (match (tc-move-check-expr ctx env locals loop-carried moved init)
                [(OkTcMove moved1)
                  (match (tc-move-after-bind
                    ctx
                    env
                    locals
                    loop-carried
                    moved1
                    init)
                    [(OkTcMove moved2)
                      (tc-move-check-let-bindings
                        ctx
                        (tc-bind
                          env
                          name
                          (tc-move-binding-type ctx env maybe-ty init))
                        (tc-moved-add locals name)
                        (tc-moved-remove-root-state loop-carried name)
                        (tc-moved-remove-root-state moved2 name)
                        rest)]
                    [(ErrTcMove message) (ErrTcMoveBindings message)])]
                [(ErrTcMove message) (ErrTcMoveBindings message)]))]))]))

;; Each arm is checked from the same post-scrutinee state; results are unioned so
;; a place moved on any arm is considered moved after the match.
(define (tc-move-check-arms
  [ctx : TcContext]
  [env : TcTypeEnv]
  [locals : TcMovedSet]
  [loop-carried : TcMovedSet]
  [moved : TcMovedSet]
  [arms : AstMatchArmList]) : TcMoveResult
  (match arms
    [(AstMatchArmNil) (OkTcMove moved)]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm _ body-box)
            (let
              [body : AstExpr (box-get body-box)]
              (match (tc-move-check-expr
                ctx
                env
                (tc-moved-clone locals)
                (tc-moved-clone loop-carried)
                (tc-moved-clone moved)
                body)
                [(OkTcMove arm-moved)
                  (match (tc-move-check-arms
                    ctx
                    env
                    (tc-moved-clone locals)
                    (tc-moved-clone loop-carried)
                    (tc-moved-clone moved)
                    rest)
                    [(OkTcMove rest-moved)
                      (OkTcMove (tc-moved-union arm-moved rest-moved))]
                    [(ErrTcMove message) (ErrTcMove message)])]
                [(ErrTcMove message) (ErrTcMove message)]))]))]))

(define (tc-move-check-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [locals : TcMovedSet]
  [loop-carried : TcMovedSet]
  [moved : TcMovedSet]
  [expr : AstExpr]) : TcMoveResult
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprLiteral _) (OkTcMove moved)]
    [(AstExprVar name)
      (if (tc-moved-contains? moved name)
        (ErrTcMove (tc-move-use-message name))
        (OkTcMove moved))]
    [(AstExprBinary _ left-box right-box)
      (let
        [left : AstExpr (box-get left-box)]
        [right : AstExpr (box-get right-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved left)
          [(OkTcMove moved1)
            (tc-move-check-expr ctx env locals loop-carried moved1 right)]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprUnary _ inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (box-get func-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved func)
          [(OkTcMove moved1)
            (match (tc-move-call-param-types ctx env func)
              [(OkTcTypeList params)
                (tc-move-check-exprs-with-types
                  ctx
                  env
                  locals
                  loop-carried
                  moved1
                  args
                  params)]
              [(ErrTcTypeList _)
                (tc-move-check-exprs ctx env locals loop-carried moved1 args)])]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [then-branch : AstExpr (box-get then-branch-box)]
        [else-branch : AstExpr (box-get else-branch-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved cond)
          [(OkTcMove movedc)
            (match (tc-move-check-expr
              ctx
              env
              (tc-moved-clone locals)
              (tc-moved-clone loop-carried)
              (tc-moved-clone movedc)
              then-branch)
              [(OkTcMove movedt)
                (match (tc-move-check-expr
                  ctx
                  env
                  (tc-moved-clone locals)
                  (tc-moved-clone loop-carried)
                  (tc-moved-clone movedc)
                  else-branch)
                  [(OkTcMove movede) (OkTcMove (tc-moved-union movedt movede))]
                  [(ErrTcMove message) (ErrTcMove message)])]
              [(ErrTcMove message) (ErrTcMove message)])]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (match (tc-move-check-let-bindings
          ctx
          env
          (tc-moved-clone locals)
          (tc-moved-clone loop-carried)
          moved
          bindings)
          [(OkTcMoveBindings env2 moved2 locals2 loop-carried2)
            (tc-move-check-expr ctx env2 locals2 loop-carried2 moved2 body)]
          [(ErrTcMoveBindings message) (ErrTcMove message)]))]
    [(AstExprLambda _ _ body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (match (tc-move-check-expr
          ctx
          env
          (tc-moved-clone locals)
          (tc-moved-empty)
          (tc-moved-clone moved)
          body)
          [(OkTcMove _) (OkTcMove moved)]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprTuple exprs)
      (match (tc-expr-list-types ctx env exprs)
        [(OkTcTypeList types)
          (tc-move-check-exprs-with-types
            ctx
            env
            locals
            loop-carried
            moved
            exprs
            types)]
        [(ErrTcTypeList _)
          (tc-move-check-exprs ctx env locals loop-carried moved exprs)])]
    [(AstExprTupleRef inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved inner)
          [(OkTcMove moved1)
            (match (tc-move-tuple-element-path expr)
              [(TcSomeString path)
                (if (tc-moved-contains? moved1 (tc-moved-path-key path))
                  (ErrTcMove (tc-move-use-message path))
                  (OkTcMove moved1))]
              [(TcNoString) (OkTcMove moved1)])]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprArray exprs)
      (match (tc-expr-list-types ctx env exprs)
        [(OkTcTypeList types)
          (tc-move-check-exprs-with-types
            ctx
            env
            locals
            loop-carried
            moved
            exprs
            types)]
        [(ErrTcTypeList _)
          (tc-move-check-exprs ctx env locals loop-carried moved exprs)])]
    [(AstExprMakeArray _ inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved array)
          [(OkTcMove moved1)
            (match (tc-move-check-expr ctx env locals loop-carried moved1 index)
              [(OkTcMove moved2)
                (match (tc-move-array-element-path expr)
                  [(TcSomeString path)
                    (if (tc-moved-contains? moved2 (tc-moved-path-key path))
                      (ErrTcMove (tc-move-use-message path))
                      (OkTcMove moved2))]
                  [(TcNoString) (OkTcMove moved2)])]
              [(ErrTcMove message) (ErrTcMove message)])]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        [value : AstExpr (box-get value-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved array)
          [(OkTcMove moved1)
            (match (tc-move-check-expr ctx env locals loop-carried moved1 index)
              [(OkTcMove moved2)
                (tc-move-check-expr ctx env locals loop-carried moved2 value)]
              [(ErrTcMove message) (ErrTcMove message)])]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (box-get array-box)]
        [value : AstExpr (box-get value-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved array)
          [(OkTcMove moved1)
            (tc-move-check-expr ctx env locals loop-carried moved1 value)]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprStringRef str-box index-box)
      (let
        [str : AstExpr (box-get str-box)]
        [index : AstExpr (box-get index-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved str)
          [(OkTcMove moved1)
            (tc-move-check-expr ctx env locals loop-carried moved1 index)]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [body : AstExpr (box-get body-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved cond)
          [(OkTcMove movedc)
            (let
              [body-loop-carried : TcMovedSet
                (tc-moved-union locals (tc-moved-clone loop-carried))]
              (match (tc-move-check-expr
                ctx
                env
                (tc-moved-clone locals)
                body-loop-carried
                (tc-moved-clone movedc)
                body)
                [(OkTcMove _) (OkTcMove movedc)]
                [(ErrTcMove message) (ErrTcMove message)]))]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprBegin exprs)
      (tc-move-check-exprs ctx env locals loop-carried moved exprs)]
    [(AstExprUnsafe exprs)
      (tc-move-check-exprs ctx env locals loop-carried moved exprs)]
    [(AstExprSet name rhs-box)
      (let
        [rhs : AstExpr (box-get rhs-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved rhs)
          [(OkTcMove moved1)
            (match (tc-move-after-bind ctx env locals loop-carried moved1 rhs)
              [(OkTcMove moved2)
                (OkTcMove (tc-moved-remove-root-state moved2 name))]
              [(ErrTcMove message) (ErrTcMove message)])]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprBorrow _ inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprMatch scrut-box arms)
      (let
        [scrut : AstExpr (box-get scrut-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved scrut)
          [(OkTcMove moveds)
            (match (tc-expr ctx env scrut)
              [(OkTcType scrut-ty)
                (tc-move-check-arms
                  ctx
                  env
                  locals
                  loop-carried
                  (tc-move-after-match-scrutinee
                    ctx
                    locals
                    moveds
                    scrut
                    scrut-ty)
                  arms)]
              [(ErrTcType _)
                (tc-move-check-arms ctx env locals loop-carried moveds arms)])]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprForeach index index-ty start-box end-box body-box)
      (let
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [body : AstExpr (box-get body-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved start)
          [(OkTcMove moved1)
            (match (tc-move-check-expr ctx env locals loop-carried moved1 end)
              [(OkTcMove moved2)
                (let
                  [body-loop-carried : TcMovedSet
                    (tc-moved-union locals (tc-moved-clone loop-carried))]
                  (match (tc-move-check-expr
                    ctx
                    (tc-bind env index (tc-resolve-type ctx index-ty))
                    (tc-moved-add (tc-moved-clone locals) index)
                    (tc-moved-remove-root-state body-loop-carried index)
                    (tc-moved-clone moved2)
                    body)
                    [(OkTcMove _) (OkTcMove moved2)]
                    [(ErrTcMove message) (ErrTcMove message)]))]
              [(ErrTcMove message) (ErrTcMove message)])]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprSpmdReduce _ _ _ a-box b-box c-box d-box)
      (let
        [a : AstExpr (box-get a-box)]
        [b : AstExpr (box-get b-box)]
        [c : AstExpr (box-get c-box)]
        [d : AstExpr (box-get d-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved a)
          [(OkTcMove m1)
            (match (tc-move-check-expr ctx env locals loop-carried m1 b)
              [(OkTcMove m2)
                (match (tc-move-check-expr ctx env locals loop-carried m2 c)
                  [(OkTcMove m3)
                    (tc-move-check-expr ctx env locals loop-carried m3 d)]
                  [(ErrTcMove message) (ErrTcMove message)])]
              [(ErrTcMove message) (ErrTcMove message)])]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprStructGet inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved inner)
          [(OkTcMove moved1)
            (match (tc-move-struct-field-path expr)
              [(TcSomeString path)
                (if (tc-moved-contains? moved1 (tc-moved-path-key path))
                  (ErrTcMove (tc-move-use-message path))
                  (OkTcMove moved1))]
              [(TcNoString) (OkTcMove moved1)])]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprWithRegion _ exprs)
      (tc-move-check-exprs ctx env locals loop-carried moved exprs)]
    [(AstExprWithEscape scratch-box exprs)
      (let
        [scratch : AstExpr (box-get scratch-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved scratch)
          [(OkTcMove moved1)
            (tc-move-check-exprs ctx env locals loop-carried moved1 exprs)]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprWithResource _ exprs)
      (tc-move-check-exprs ctx env locals loop-carried moved exprs)]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprTypeLiteral _) (OkTcMove moved)]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprQuote _) (OkTcMove moved)]
    [(AstExprQuasiquote _) (OkTcMove moved)]
    [(AstExprUnquote _) (OkTcMove moved)]
    [(AstExprUnquoteSplicing _) (OkTcMove moved)]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved inner)
          [(OkTcMove moved1)
            (match (tc-current-return-type env)
              [(OkTcType return-ty)
                (tc-move-after-consuming-value
                  ctx
                  env
                  locals
                  loop-carried
                  moved1
                  inner
                  return-ty)]
              [(ErrTcType _) (OkTcMove moved1)])]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprPtrNull _) (OkTcMove moved)]
    [(AstExprPtrNullCheck inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprPtrRead inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [value : AstExpr (box-get value-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved ptr)
          [(OkTcMove moved1)
            (tc-move-check-expr ctx env locals loop-carried moved1 value)]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [offset : AstExpr (box-get offset-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved ptr)
          [(OkTcMove moved1)
            (tc-move-check-expr ctx env locals loop-carried moved1 offset)]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprPtrCast inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprPtrToInt inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprIntToPtr inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprStringData inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [len : AstExpr (box-get len-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved ptr)
          [(OkTcMove moved1)
            (tc-move-check-expr ctx env locals loop-carried moved1 len)]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprArrayData inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (tc-move-check-expr ctx env locals loop-carried moved inner))]
    [(AstExprProgramArgc) (OkTcMove moved)]
    [(AstExprProgramArgv) (OkTcMove moved)]
    [(AstExprProgramEnvp) (OkTcMove moved)]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved leaf)
          [(OkTcMove moved1)
            (tc-move-check-expr ctx env locals loop-carried moved1 subleaf)]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved leaf)
          [(OkTcMove moved1)
            (tc-move-check-expr ctx env locals loop-carried moved1 subleaf)]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved leaf)
          [(OkTcMove moved1)
            (tc-move-check-expr ctx env locals loop-carried moved1 subleaf)]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (match (tc-move-check-expr ctx env locals loop-carried moved leaf)
          [(OkTcMove moved1)
            (tc-move-check-expr ctx env locals loop-carried moved1 subleaf)]
          [(ErrTcMove message) (ErrTcMove message)]))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (box-get index-box)]
        (tc-move-check-expr ctx env locals loop-carried moved index))]))

(define (tc-move-check-body
  [ctx : TcContext]
  [env : TcTypeEnv]
  [params : AstParamList]
  [body : AstExpr]) : ResultTcUnit
  (match (tc-move-check-expr
    ctx
    env
    (tc-move-params-locals params (tc-moved-empty))
    (tc-moved-empty)
    (tc-moved-empty)
    body)
    [(OkTcMove _) OkTcUnit]
    [(ErrTcMove message) (ErrTcUnit message)]))

;; --- macro expansion phase (#1139) ------------------------------------------
;;
;; Pipeline: parse -> EXPAND -> typecheck. When a call head names a `defmacro`,
;; the unevaluated operand forms are passed as `Expr` values (CtfeExpr) to the
;; transformer, which is run via CTFE; the produced `Expr` is spliced at the
;; call site and re-expanded to a fixpoint (depth-limited). Macro calls in
;; ordinary evaluated positions are expanded; quoted/quasiquoted code is left
;; as data. Programs without macro calls pass through unchanged. The normal
;; typechecker then runs over the expanded program as the post-expansion safety
;; net. Call-site arity and operand signature checks run before the transformer
;; so obvious operand type errors are reported at the macro call site.
(defenum MacroMaybeDecl
  (MacroNoDecl)
  (MacroSomeDecl String AstMacroParamList AstType AstExpr))

(defenum ResultMacroCallDecl
  (OkMacroCallDecl MacroMaybeDecl)
  (ErrMacroCallDecl CompilerDiagnostic))

(defenum ResultMacroExpr
  (OkMacroExpr AstExpr)
  (ErrMacroExpr CompilerDiagnostic))

(defenum ResultMacroCompatCall
  (OkMacroCompatCall AstExpr)
  (NoMacroCompatCall)
  (ErrMacroCompatCall CompilerDiagnostic))

(defenum ResultMacroExprList
  (OkMacroExprList AstExprList)
  (ErrMacroExprList CompilerDiagnostic))

(defenum ResultMacroArms
  (OkMacroArms AstMatchArmList)
  (ErrMacroArms CompilerDiagnostic))

(defenum ResultMacroLetBindings
  (OkMacroLetBindings AstLetBindingList TcTypeEnv)
  (ErrMacroLetBindings CompilerDiagnostic))

(defenum ResultMacroEnv
  (OkMacroEnv CtfeEnv)
  (ErrMacroEnv CompilerDiagnostic))

(defenum ResultMacroCheck
  (OkMacroCheck)
  (ErrMacroCheck CompilerDiagnostic))

(defenum ResultMacroDecl
  (OkMacroDecl AstDecl)
  (ErrMacroDecl CompilerDiagnostic))

(defenum ResultMacroDecls
  (OkMacroDecls AstDeclList)
  (ErrMacroDecls CompilerDiagnostic))

(defenum ResultMacroExpand
  (OkMacroExpand AstProgram)
  (ErrMacroExpand CompilerDiagnostic))

(defenum MacroHygieneEnv
  (MacroHygieneNil)
  (MacroHygieneBind String String (Box MacroHygieneEnv)))

(defenum MacroHygieneName
  (MacroHygieneName String MacroHygieneEnv))

(defenum MacroHygieneParams
  (MacroHygieneParams AstParamList MacroHygieneEnv))

(defenum MacroHygieneLetBindings
  (MacroHygieneLetBindings AstLetBindingList MacroHygieneEnv))

(defenum MacroHygieneResourceBindings
  (MacroHygieneResourceBindings AstResourceBindingList MacroHygieneEnv))

(defenum MacroHygienePattern
  (MacroHygienePattern AstPattern MacroHygieneEnv))

(defenum MacroHygienePatternList
  (MacroHygienePatternList AstPatternList MacroHygieneEnv))

(define macro-expand-active-module : String
  "")

(define macro-expand-active-index : i64
  0)

(define (macro-hygiene-env-lookup [env : MacroHygieneEnv] [name : String]) : TcMaybeString
  (match env
    [(MacroHygieneNil) (TcNoString)]
    [(MacroHygieneBind key value rest)
      (if (string-eq key name)
        (TcSomeString value)
        (macro-hygiene-env-lookup (box-get rest) name))]))

(define (macro-hygiene-fresh-local
  [macro-name : String]
  [depth : i64]
  [base : String]) : String
  (string-append
    (tc-hygiene-local-prefix)
    (string-append
      (int->string depth)
      (string-append "$" (string-append macro-name (string-append "$" base))))))

(define (macro-hygiene-rename-var [env : MacroHygieneEnv] [name : String]) : String
  (if (tc-hygiene-template-name? name)
    (let
      [base : String (tc-hygiene-template-base name)]
      (match (macro-hygiene-env-lookup env base)
        [(TcSomeString renamed) renamed]
        [(TcNoString) (tc-hygiene-global-name base)]))
    name))

(define (macro-hygiene-bind-name
  [env : MacroHygieneEnv]
  [macro-name : String]
  [depth : i64]
  [name : String]) : MacroHygieneName
  (if (tc-hygiene-template-name? name)
    (let
      [base : String (tc-hygiene-template-base name)]
      [renamed : String (macro-hygiene-fresh-local macro-name depth base)]
      (MacroHygieneName renamed (MacroHygieneBind base renamed (box env))))
    (MacroHygieneName name env)))

(define (macro-hygiene-expr-list
  [exprs : AstExprList]
  [env : MacroHygieneEnv]
  [macro-name : String]
  [depth : i64]) : AstExprList
  (match exprs
    [(AstExprNil) AstExprNil]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (box-get head)]
        [rest : AstExprList (box-get rest)]
        (ast-expr-cons
          (macro-hygiene-expr head env macro-name depth)
          (macro-hygiene-expr-list rest env macro-name depth)))]))

(define (macro-hygiene-param-list
  [params : AstParamList]
  [env : MacroHygieneEnv]
  [macro-name : String]
  [depth : i64]) : MacroHygieneParams
  (match params
    [(AstParamNil) (MacroHygieneParams AstParamNil env)]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam name ty comptime?)
            (match (macro-hygiene-bind-name env macro-name depth name)
              [(MacroHygieneName renamed next-env)
                (match (macro-hygiene-param-list rest next-env macro-name depth)
                  [(MacroHygieneParams nrest final-env)
                    (MacroHygieneParams
                      (ast-param-cons (AstParam renamed ty comptime?) nrest)
                      final-env)])])]))]))

(define (macro-hygiene-pattern-list
  [patterns : AstPatternList]
  [env : MacroHygieneEnv]
  [macro-name : String]
  [depth : i64]) : MacroHygienePatternList
  (match patterns
    [(AstPatternNil) (MacroHygienePatternList AstPatternNil env)]
    [(AstPatternCons pattern rest)
      (let
        [pattern : AstPattern (box-get pattern)]
        [rest : AstPatternList (box-get rest)]
        (match (macro-hygiene-pattern pattern env macro-name depth)
          [(MacroHygienePattern npattern next-env)
            (match (macro-hygiene-pattern-list rest next-env macro-name depth)
              [(MacroHygienePatternList nrest final-env)
                (MacroHygienePatternList
                  (ast-pattern-cons npattern nrest)
                  final-env)])]))]))

(define (macro-hygiene-pattern
  [pattern : AstPattern]
  [env : MacroHygieneEnv]
  [macro-name : String]
  [depth : i64]) : MacroHygienePattern
  (match pattern
    [(AstPatVar name maybe-ty)
      (match (macro-hygiene-bind-name env macro-name depth name)
        [(MacroHygieneName renamed next-env)
          (MacroHygienePattern (AstPatVar renamed maybe-ty) next-env)])]
    [(AstPatTuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (match (macro-hygiene-pattern-list patterns env macro-name depth)
          [(MacroHygienePatternList npatterns next-env)
            (MacroHygienePattern (ast-pat-tuple npatterns) next-env)]))]
    [(AstPatWildcard) (MacroHygienePattern AstPatWildcard env)]
    [(AstPatBinding name)
      (match (macro-hygiene-bind-name env macro-name depth name)
        [(MacroHygieneName renamed next-env)
          (MacroHygienePattern (AstPatBinding renamed) next-env)])]
    [(AstPatVariant name args-box)
      (let
        [args : AstPatternList (box-get args-box)]
        (match (macro-hygiene-pattern-list args env macro-name depth)
          [(MacroHygienePatternList nargs next-env)
            (MacroHygienePattern (ast-pat-variant name nargs) next-env)]))]
    [(AstPatLiteral lit) (MacroHygienePattern (AstPatLiteral lit) env)]))

(define (macro-hygiene-let-bindings
  [bindings : AstLetBindingList]
  [env : MacroHygieneEnv]
  [macro-name : String]
  [depth : i64]) : MacroHygieneLetBindings
  (match bindings
    [(AstLetBindingNil) (MacroHygieneLetBindings AstLetBindingNil env)]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name maybe-ty init-box)
            (let
              [init : AstExpr (box-get init-box)]
              [ninit : AstExpr (macro-hygiene-expr init env macro-name depth)]
              (match (macro-hygiene-bind-name env macro-name depth name)
                [(MacroHygieneName renamed next-env)
                  (match (macro-hygiene-let-bindings
                    rest
                    next-env
                    macro-name
                    depth)
                    [(MacroHygieneLetBindings nrest final-env)
                      (MacroHygieneLetBindings
                        (ast-let-binding-cons
                          (ast-let-binding renamed maybe-ty ninit)
                          nrest)
                        final-env)])]))]))]))

(define (macro-hygiene-resource-bindings
  [bindings : AstResourceBindingList]
  [env : MacroHygieneEnv]
  [macro-name : String]
  [depth : i64]) : MacroHygieneResourceBindings
  (match bindings
    [(AstResourceBindingNil)
      (MacroHygieneResourceBindings AstResourceBindingNil env)]
    [(AstResourceBindingCons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding name init-box cleanup-box)
            (let
              [init : AstExpr (box-get init-box)]
              [cleanup : AstExpr (box-get cleanup-box)]
              [ninit : AstExpr (macro-hygiene-expr init env macro-name depth)]
              [ncleanup : AstExpr
                (macro-hygiene-expr cleanup env macro-name depth)]
              (match (macro-hygiene-bind-name env macro-name depth name)
                [(MacroHygieneName renamed next-env)
                  (match (macro-hygiene-resource-bindings
                    rest
                    next-env
                    macro-name
                    depth)
                    [(MacroHygieneResourceBindings nrest final-env)
                      (MacroHygieneResourceBindings
                        (ast-resource-binding-cons
                          (ast-resource-binding renamed ninit ncleanup)
                          nrest)
                        final-env)])]))]))]))

(define (macro-hygiene-arm-list
  [arms : AstMatchArmList]
  [env : MacroHygieneEnv]
  [macro-name : String]
  [depth : i64]) : AstMatchArmList
  (match arms
    [(AstMatchArmNil) AstMatchArmNil]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern body-box)
            (let
              [body : AstExpr (box-get body-box)]
              (match (macro-hygiene-pattern pattern env macro-name depth)
                [(MacroHygienePattern npattern arm-env)
                  (ast-match-arm-cons
                    (ast-match-arm
                      npattern
                      (macro-hygiene-expr body arm-env macro-name depth))
                    (macro-hygiene-arm-list rest env macro-name depth))]))]))]))

(define (macro-hygiene-expr
  [expr : AstExpr]
  [env : MacroHygieneEnv]
  [macro-name : String]
  [depth : i64]) : AstExpr
  (match expr
    [(AstExprSpanned inner-box span)
      (let
        [inner : AstExpr (box-get inner-box)]
        (ast-expr-spanned (macro-hygiene-expr inner env macro-name depth) span))]
    [(AstExprVar name) (AstExprVar (macro-hygiene-rename-var env name))]
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (box-get left-box)]
        [right : AstExpr (box-get right-box)]
        (ast-expr-binary
          op
          (macro-hygiene-expr left env macro-name depth)
          (macro-hygiene-expr right env macro-name depth)))]
    [(AstExprUnary op inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (ast-expr-unary op (macro-hygiene-expr inner env macro-name depth)))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (box-get func-box)]
        (ast-expr-call
          (macro-hygiene-expr func env macro-name depth)
          (macro-hygiene-expr-list args env macro-name depth)))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [then-branch : AstExpr (box-get then-branch-box)]
        [else-branch : AstExpr (box-get else-branch-box)]
        (ast-expr-if
          (macro-hygiene-expr cond env macro-name depth)
          (macro-hygiene-expr then-branch env macro-name depth)
          (macro-hygiene-expr else-branch env macro-name depth)))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (match (macro-hygiene-let-bindings bindings env macro-name depth)
          [(MacroHygieneLetBindings nbindings body-env)
            (ast-expr-let
              nbindings
              (macro-hygiene-expr body body-env macro-name depth))]))]
    [(AstExprLambda params maybe-ret body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (match (macro-hygiene-param-list params env macro-name depth)
          [(MacroHygieneParams nparams body-env)
            (ast-expr-lambda
              nparams
              maybe-ret
              (macro-hygiene-expr body body-env macro-name depth))]))]
    [(AstExprTuple exprs)
      (AstExprTuple (macro-hygiene-expr-list exprs env macro-name depth))]
    [(AstExprTupleRef tuple-expr-box index)
      (let
        [tuple-expr : AstExpr (box-get tuple-expr-box)]
        (ast-expr-tuple-ref
          (macro-hygiene-expr tuple-expr env macro-name depth)
          index))]
    [(AstExprArray exprs)
      (AstExprArray (macro-hygiene-expr-list exprs env macro-name depth))]
    [(AstExprMakeArray ty len-box)
      (let
        [len : AstExpr (box-get len-box)]
        (ast-expr-make-array ty (macro-hygiene-expr len env macro-name depth)))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        (ast-expr-array-ref
          (macro-hygiene-expr array env macro-name depth)
          (macro-hygiene-expr index env macro-name depth)))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (box-get array-box)]
        [index : AstExpr (box-get index-box)]
        [value : AstExpr (box-get value-box)]
        (ast-expr-array-set
          (macro-hygiene-expr array env macro-name depth)
          (macro-hygiene-expr index env macro-name depth)
          (macro-hygiene-expr value env macro-name depth)))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (box-get array-box)]
        [value : AstExpr (box-get value-box)]
        (ast-expr-array-push
          (macro-hygiene-expr array env macro-name depth)
          (macro-hygiene-expr value env macro-name depth)))]
    [(AstExprStringRef text-box index-box)
      (let
        [text : AstExpr (box-get text-box)]
        [index : AstExpr (box-get index-box)]
        (ast-expr-string-ref
          (macro-hygiene-expr text env macro-name depth)
          (macro-hygiene-expr index env macro-name depth)))]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (box-get cond-box)]
        [body : AstExpr (box-get body-box)]
        (ast-expr-while
          (macro-hygiene-expr cond env macro-name depth)
          (macro-hygiene-expr body env macro-name depth)))]
    [(AstExprBegin exprs)
      (AstExprBegin (macro-hygiene-expr-list exprs env macro-name depth))]
    [(AstExprUnsafe exprs)
      (AstExprUnsafe (macro-hygiene-expr-list exprs env macro-name depth))]
    [(AstExprSet name rhs-box)
      (let
        [rhs : AstExpr (box-get rhs-box)]
        (ast-expr-set
          (macro-hygiene-rename-var env name)
          (macro-hygiene-expr rhs env macro-name depth)))]
    [(AstExprAnn inner-box ty)
      (let
        [inner : AstExpr (box-get inner-box)]
        (ast-expr-ann (macro-hygiene-expr inner env macro-name depth) ty))]
    [(AstExprCast inner-box ty)
      (let
        [inner : AstExpr (box-get inner-box)]
        (ast-expr-cast (macro-hygiene-expr inner env macro-name depth) ty))]
    [(AstExprBorrow lifetime place-box)
      (let
        [place : AstExpr (box-get place-box)]
        (ast-expr-borrow
          lifetime
          (macro-hygiene-expr place env macro-name depth)))]
    [(AstExprMatch scrut-box arms)
      (let
        [scrut : AstExpr (box-get scrut-box)]
        (ast-expr-match
          (macro-hygiene-expr scrut env macro-name depth)
          (macro-hygiene-arm-list arms env macro-name depth)))]
    [(AstExprForeach index index-ty start-box end-box body-box)
      (let
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [body : AstExpr (box-get body-box)]
        (match (macro-hygiene-bind-name env macro-name depth index)
          [(MacroHygieneName nindex body-env)
            (ast-expr-foreach
              nindex
              index-ty
              (macro-hygiene-expr start env macro-name depth)
              (macro-hygiene-expr end env macro-name depth)
              (macro-hygiene-expr body body-env macro-name depth))]))]
    [(AstExprSpmdReduce op index index-ty start-box end-box init-box value-box)
      (let
        [start : AstExpr (box-get start-box)]
        [end : AstExpr (box-get end-box)]
        [init : AstExpr (box-get init-box)]
        [value : AstExpr (box-get value-box)]
        (match (macro-hygiene-bind-name env macro-name depth index)
          [(MacroHygieneName nindex body-env)
            (ast-expr-spmd-reduce
              op
              nindex
              index-ty
              (macro-hygiene-expr start env macro-name depth)
              (macro-hygiene-expr end env macro-name depth)
              (macro-hygiene-expr init env macro-name depth)
              (macro-hygiene-expr value body-env macro-name depth))]))]
    [(AstExprStructGet inner-box field)
      (let
        [inner : AstExpr (box-get inner-box)]
        (ast-expr-struct-get
          (macro-hygiene-expr inner env macro-name depth)
          field))]
    [(AstExprWithRegion name body)
      (match (macro-hygiene-bind-name env macro-name depth name)
        [(MacroHygieneName nname body-env)
          (AstExprWithRegion
            nname
            (macro-hygiene-expr-list body body-env macro-name depth))])]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (box-get scratch-box)]
        (ast-expr-with-escape
          (macro-hygiene-expr scratch env macro-name depth)
          (macro-hygiene-expr-list body env macro-name depth)))]
    [(AstExprWithResource bindings body)
      (match (macro-hygiene-resource-bindings bindings env macro-name depth)
        [(MacroHygieneResourceBindings nbindings body-env)
          (AstExprWithResource
            nbindings
            (macro-hygiene-expr-list body body-env macro-name depth))])]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (ast-expr-box (macro-hygiene-expr inner env macro-name depth)))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (ast-expr-box-get (macro-hygiene-expr inner env macro-name depth)))]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (ast-expr-comptime (macro-hygiene-expr inner env macro-name depth)))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (ast-expr-return (macro-hygiene-expr inner env macro-name depth)))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (ast-expr-try (macro-hygiene-expr inner env macro-name depth)))]
    [(AstExprPtrNull ty) (AstExprPtrNull ty)]
    [(AstExprPtrNullCheck ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (ast-expr-ptr-null-check (macro-hygiene-expr ptr env macro-name depth)))]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (ast-expr-ptr-read (macro-hygiene-expr ptr env macro-name depth)))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [value : AstExpr (box-get value-box)]
        (ast-expr-ptr-write
          (macro-hygiene-expr ptr env macro-name depth)
          (macro-hygiene-expr value env macro-name depth)))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [offset : AstExpr (box-get offset-box)]
        (ast-expr-ptr-offset
          (macro-hygiene-expr ptr env macro-name depth)
          (macro-hygiene-expr offset env macro-name depth)))]
    [(AstExprPtrCast ptr-box ty)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (ast-expr-ptr-cast (macro-hygiene-expr ptr env macro-name depth) ty))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        (ast-expr-ptr-to-int (macro-hygiene-expr ptr env macro-name depth)))]
    [(AstExprIntToPtr value-box ty)
      (let
        [value : AstExpr (box-get value-box)]
        (ast-expr-int-to-ptr (macro-hygiene-expr value env macro-name depth) ty))]
    [(AstExprStringData inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (ast-expr-string-data (macro-hygiene-expr inner env macro-name depth)))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (box-get ptr-box)]
        [len : AstExpr (box-get len-box)]
        (ast-expr-string-from-bytes
          (macro-hygiene-expr ptr env macro-name depth)
          (macro-hygiene-expr len env macro-name depth)))]
    [(AstExprArrayData inner-box)
      (let
        [inner : AstExpr (box-get inner-box)]
        (ast-expr-array-data (macro-hygiene-expr inner env macro-name depth)))]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (ast-expr-cpuid-eax
          (macro-hygiene-expr leaf env macro-name depth)
          (macro-hygiene-expr subleaf env macro-name depth)))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (ast-expr-cpuid-ebx
          (macro-hygiene-expr leaf env macro-name depth)
          (macro-hygiene-expr subleaf env macro-name depth)))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (ast-expr-cpuid-ecx
          (macro-hygiene-expr leaf env macro-name depth)
          (macro-hygiene-expr subleaf env macro-name depth)))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (box-get leaf-box)]
        [subleaf : AstExpr (box-get subleaf-box)]
        (ast-expr-cpuid-edx
          (macro-hygiene-expr leaf env macro-name depth)
          (macro-hygiene-expr subleaf env macro-name depth)))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (box-get index-box)]
        (ast-expr-xgetbv (macro-hygiene-expr index env macro-name depth)))]
    [(AstExprQuote _) expr]
    [(AstExprQuasiquote _) expr]
    [(AstExprUnquote _) expr]
    [(AstExprUnquoteSplicing _) expr]
    [_ expr]))

(define (macro-expand-depth-limit) : i64
  64)

(define (macro-find-decl [decls : AstDeclList] [name : String]) : MacroMaybeDecl
  (match decls
    [(AstDeclNil) (MacroNoDecl)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclDefMacro mname params ret body-box)
            (let
              [body : AstExpr (box-get body-box)]
              (if (string-eq mname name)
                (MacroSomeDecl mname params ret body)
                (macro-find-decl rest name)))]
          [_ (macro-find-decl rest name)]))]))

(define (macro-decl-from-decl [decl : AstDecl]) : MacroMaybeDecl
  (match decl
    [(AstDeclDefMacro name params ret body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (MacroSomeDecl name params ret body))]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (macro-decl-from-decl inner))]
    [(AstDeclComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (macro-decl-from-decl template))]
    [_ (MacroNoDecl)]))

(define (macro-decl-counts-for-symbol-index? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclImport _) false]
    [(AstDeclIncludeStr _ _) false]
    [(AstDeclExport _) false]
    [(AstDeclModule _) false]
    [(AstDeclTest _ _ _) false]
    [_ true]))

(define (macro-find-decl-by-index-loop
  [decls : AstDeclList]
  [target : i64]
  [index : i64]) : MacroMaybeDecl
  (match decls
    [(AstDeclNil) (MacroNoDecl)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (if (macro-decl-counts-for-symbol-index? decl)
          (if (= index target)
            (macro-decl-from-decl decl)
            (macro-find-decl-by-index-loop rest target (+ index 1)))
          (macro-find-decl-by-index-loop rest target index)))]))

(define (macro-find-decl-by-index [decls : AstDeclList] [target : i64]) : MacroMaybeDecl
  (macro-find-decl-by-index-loop decls target 0))

(define (macro-import-alias-target-list
  [decls : AstDeclList]
  [current-module : String]
  [alias : String]
  [module : String]) : TcMaybeString
  (match decls
    [(AstDeclNil) (TcNoString)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule next-module)
            (macro-import-alias-target-list
              rest
              current-module
              alias
              next-module)]
          [(AstDeclImport (AstImportSpec _ expected maybe-alias))
            (match maybe-alias
              [(AstSomeImportAlias import-alias)
                (if (and
                  (string-eq module current-module)
                  (string-eq import-alias alias))
                  (match expected
                    [(AstSomeModuleName target) (TcSomeString target)]
                    [(AstNoModuleName) (TcSomeString alias)])
                  (macro-import-alias-target-list
                    rest
                    current-module
                    alias
                    module))]
              [(AstNoImportAlias)
                (macro-import-alias-target-list
                  rest
                  current-module
                  alias
                  module)])]
          [_ (macro-import-alias-target-list rest current-module alias module)]))]))

(define (macro-resolve-qualified-module
  [decls : AstDeclList]
  [current-module : String]
  [qualifier : String]) : String
  (match (macro-import-alias-target-list decls current-module qualifier "")
    [(TcSomeString target) target]
    [(TcNoString) qualifier]))

(define (macro-missing-export-message [name : String]) : String
  (string-append "typecheck: missing macro export " name))

(define (macro-private-message [name : String]) : String
  (string-append "typecheck: private macro " name))

(define (macro-late-local-message [name : String]) : String
  (string-append
    "typecheck: local macro "
    (string-append name " is defined later")))

(define (macro-qualified-call-decl-with-exports
  [ctx : TcContext]
  [exports : CompilerExports]
  [decls : AstDeclList]
  [target-module : String]
  [base : String]
  [name : String]
  [call-expr : AstExpr]) : ResultMacroCallDecl
  (match (compiler-exports-lookup
    exports
    (compiler-export-kind-macro)
    target-module
    base)
    [(SomeI64 handle)
      (match (macro-find-decl-by-index
        decls
        (compiler-symbol-handle-index handle))
        [(MacroSomeDecl macro-name params ret body)
          (OkMacroCallDecl (MacroSomeDecl macro-name params ret body))]
        [(MacroNoDecl)
          (ErrMacroCallDecl
            (ctfe-diagnostic-at-expr
              call-expr
              (macro-missing-export-message name)))])]
    [(NoneI64)
      (match (compiler-symbols-lookup-macro-in-module
        (tc-context-symbols ctx)
        target-module
        base)
        [(SomeI64 _)
          (ErrMacroCallDecl
            (ctfe-diagnostic-at-expr call-expr (macro-private-message name)))]
        [(NoneI64)
          (ErrMacroCallDecl
            (ctfe-diagnostic-at-expr
              call-expr
              (macro-missing-export-message name)))])]))

(define (macro-qualified-call-decl
  [ctx : TcContext]
  [decls : AstDeclList]
  [name : String]
  [call-expr : AstExpr]) : ResultMacroCallDecl
  (let
    [qualifier : String (tc-qualified-name-module name)]
    [base : String (tc-qualified-name-base name)]
    [target-module : String
      (macro-resolve-qualified-module decls (tc-context-module ctx) qualifier)]
    (match (build-compiler-exports-with
      (tc-context-program ctx)
      (tc-context-symbols ctx)
      (tc-context-registries ctx))
      [(OkCompilerExports exports)
        (macro-qualified-call-decl-with-exports
          ctx
          exports
          decls
          target-module
          base
          name
          call-expr)]
      [(ErrCompilerExports message)
        (ErrMacroCallDecl (ctfe-diagnostic-at-expr call-expr message))])))

;; If `func` names a visible macro, return that macro's decl. Bare local macros
;; are source-order visible; qualified macro calls must pass the export table.
(define (macro-call-decl
  [ctx : TcContext]
  [func : AstExpr]
  [decls : AstDeclList]
  [call-expr : AstExpr]) : ResultMacroCallDecl
  (match func
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (box-get inner-box)]
        (macro-call-decl ctx inner decls call-expr))]
    [(AstExprVar name)
      (let
        [lookup-name : String
          (if (tc-hygiene-global-name? name)
            (tc-hygiene-global-base name)
            name)]
        (if (tc-name-qualified? lookup-name)
          (macro-qualified-call-decl ctx decls lookup-name call-expr)
          (match (compiler-symbols-lookup-macro-in-module
            (tc-context-symbols ctx)
            (tc-context-module ctx)
            lookup-name)
            [(SomeI64 handle)
              (if (<
                (compiler-symbol-handle-index handle)
                macro-expand-active-index)
                (match (macro-find-decl-by-index
                  decls
                  (compiler-symbol-handle-index handle))
                  [(MacroSomeDecl macro-name params ret body)
                    (OkMacroCallDecl (MacroSomeDecl macro-name params ret body))]
                  [(MacroNoDecl) (OkMacroCallDecl (MacroNoDecl))])
                (ErrMacroCallDecl
                  (ctfe-diagnostic-at-expr
                    call-expr
                    (macro-late-local-message lookup-name))))]
            [(NoneI64) (OkMacroCallDecl (MacroNoDecl))])))]
    [_ (OkMacroCallDecl (MacroNoDecl))]))

(define (macro-local-decl-index-step! [decl : AstDecl]) : unit
  (if (macro-decl-counts-for-symbol-index? decl)
    (set! macro-expand-active-index (+ macro-expand-active-index 1))
    unit))

(define (macro-operand-mismatch-message [expected : AstType] [actual : AstType]) : String
  (tc-cat3
    "typecheck: macro operand type mismatch: expected "
    (tc-type-render expected)
    (tc-cat3 ", got " (tc-type-render actual) "")))

(define (macro-check-operand
  [ctx : TcContext]
  [env : TcTypeEnv]
  [expected : AstType]
  [arg : AstExpr]) : ResultMacroCheck
  (let
    [resolved-expected : AstType (tc-resolve-type ctx expected)]
    (match (tc-expr ctx env arg)
      [(OkTcType actual)
        (if (tc-type-compatible? resolved-expected actual)
          OkMacroCheck
          (ErrMacroCheck
            (tc-expr-diag
              arg
              (macro-operand-mismatch-message resolved-expected actual))))]
      [(ErrTcType message)
        (ErrMacroCheck
          (tc-expr-diag
            arg
            (string-append
              "typecheck: macro operand typecheck failed: "
              message)))])))

(define (macro-check-variadic-operands
  [ctx : TcContext]
  [env : TcTypeEnv]
  [expected : AstType]
  [args : AstExprList]) : ResultMacroCheck
  (match args
    [(AstExprNil) OkMacroCheck]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (box-get head)]
        [rest : AstExprList (box-get rest)]
        (match (macro-check-operand ctx env expected head)
          [(OkMacroCheck) (macro-check-variadic-operands ctx env expected rest)]
          [(ErrMacroCheck diag) (ErrMacroCheck diag)]))]))

;; Bind the unevaluated operand forms to the macro parameters as `Expr` values.
;; A trailing variadic parameter collects the remaining operands as an ExprList.
(define (macro-bind-params
  [ctx : TcContext]
  [type-env : TcTypeEnv]
  [params : AstMacroParamList]
  [args : AstExprList]
  [env : CtfeEnv]
  [call-expr : AstExpr]) : ResultMacroEnv
  (match params
    [(AstMacroParamNil)
      (match args
        [(AstExprNil) (OkMacroEnv env)]
        [_
          (ErrMacroEnv
            (ctfe-diagnostic-at-expr
              call-expr
              "macro call has too many arguments"))])]
    [(AstMacroParamCons param rest-params)
      (let
        [rest-params : AstMacroParamList (box-get rest-params)]
        (match param
          [(AstMacroParam pname pty variadic)
            (if variadic
              (match (macro-check-variadic-operands ctx type-env pty args)
                [(OkMacroCheck)
                  (OkMacroEnv (CtfeEnvCons pname (CtfeExprList args) (box env)))]
                [(ErrMacroCheck diag) (ErrMacroEnv diag)])
              (match args
                [(AstExprNil)
                  (ErrMacroEnv
                    (ctfe-diagnostic-at-expr
                      call-expr
                      "macro call has too few arguments"))]
                [(AstExprCons arg rest-args)
                  (let
                    [arg : AstExpr (box-get arg)]
                    [rest-args : AstExprList (box-get rest-args)]
                    (match (macro-check-operand ctx type-env pty arg)
                      [(OkMacroCheck)
                        (macro-bind-params
                          ctx
                          type-env
                          rest-params
                          rest-args
                          (CtfeEnvCons
                            pname
                            (CtfeExpr arg (tc-resolve-type ctx pty))
                            (box env))
                          call-expr)]
                      [(ErrMacroCheck diag) (ErrMacroEnv diag)]))]))]))]))

;; Run a macro transformer via CTFE and re-expand its produced form to a fixpoint.
(define (macro-expand-call
  [ctx : TcContext]
  [type-env : TcTypeEnv]
  [decls : AstDeclList]
  [macro-name : String]
  [params : AstMacroParamList]
  [ret : AstType]
  [body : AstExpr]
  [args : AstExprList]
  [depth : i64]
  [call-expr : AstExpr]) : ResultMacroExpr
  (match (macro-bind-params
    ctx
    type-env
    params
    args
    (tc-ctfe-env ctx)
    call-expr)
    [(OkMacroEnv env)
      (match (ctfe-eval-node
        body
        (ctfe-env-extend env (ctfe-hygiene-enabled-name) (CtfeBool true))
        (ctfe-fuel-limit))
        [(OkCtfe value _)
          (match value
            [(CtfeExpr expanded produced)
              (if (or
                (tc-type-eq produced (AstTyExpr))
                (tc-type-compatible?
                  (tc-resolve-type ctx ret)
                  (tc-resolve-type ctx produced)))
                (macro-expand-expr
                  ctx
                  type-env
                  decls
                  (+ depth 1)
                  (macro-hygiene-expr
                    expanded
                    MacroHygieneNil
                    macro-name
                    (+ depth 1)))
                (ErrMacroExpr
                  (ctfe-diagnostic-at-expr
                    call-expr
                    "typecheck: macro expansion produced type does not match declaration")))]
            [_
              (ErrMacroExpr
                (ctfe-diagnostic-at-expr
                  call-expr
                  "macro transformer did not produce an Expr"))])]
        [(ErrCtfe diag) (ErrMacroExpr diag)])]
    [(ErrMacroEnv diag) (ErrMacroExpr diag)]))

(define (macro-expand-exprs
  [ctx : TcContext]
  [env : TcTypeEnv]
  [decls : AstDeclList]
  [depth : i64]
  [exprs : AstExprList]) : ResultMacroExprList
  (match exprs
    [(AstExprNil) (OkMacroExprList (AstExprNil))]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (box-get head)]
        [rest : AstExprList (box-get rest)]
        (match (macro-expand-expr ctx env decls depth head)
          [(OkMacroExpr nhead)
            (match (macro-expand-exprs ctx env decls depth rest)
              [(OkMacroExprList nrest)
                (OkMacroExprList (ast-expr-cons nhead nrest))]
              [(ErrMacroExprList diag) (ErrMacroExprList diag)])]
          [(ErrMacroExpr diag) (ErrMacroExprList diag)]))]))

(define (macro-expand-arms
  [ctx : TcContext]
  [env : TcTypeEnv]
  [decls : AstDeclList]
  [depth : i64]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]) : ResultMacroArms
  (match arms
    [(AstMatchArmNil) (OkMacroArms (AstMatchArmNil))]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern body-box)
            (let
              [body : AstExpr (box-get body-box)]
              (match (tc-bind-match-pattern ctx env scrut-ty pattern)
                [(OkTcEnv arm-env)
                  (match (macro-expand-expr ctx arm-env decls depth body)
                    [(OkMacroExpr nbody)
                      (match (macro-expand-arms
                        ctx
                        env
                        decls
                        depth
                        scrut-ty
                        rest)
                        [(OkMacroArms nrest)
                          (OkMacroArms
                            (ast-match-arm-cons
                              (ast-match-arm pattern nbody)
                              nrest))]
                        [(ErrMacroArms diag) (ErrMacroArms diag)])]
                    [(ErrMacroExpr diag) (ErrMacroArms diag)])]
                [(ErrTcEnv message) (ErrMacroArms (tc-expr-diag body message))]))]))]))

(define (macro-expand-bindings
  [ctx : TcContext]
  [env : TcTypeEnv]
  [decls : AstDeclList]
  [depth : i64]
  [bindings : AstLetBindingList]) : ResultMacroLetBindings
  (match bindings
    [(AstLetBindingNil) (OkMacroLetBindings (AstLetBindingNil) env)]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name maybe-ty init-box)
            (let
              [init : AstExpr (box-get init-box)]
              (match (macro-expand-expr ctx env decls depth init)
                [(OkMacroExpr ninit)
                  (match (tc-let-bindings
                    ctx
                    env
                    (ast-let-binding-cons
                      (ast-let-binding name maybe-ty ninit)
                      AstLetBindingNil))
                    [(OkTcEnv next-env)
                      (match (macro-expand-bindings
                        ctx
                        next-env
                        decls
                        depth
                        rest)
                        [(OkMacroLetBindings nrest final-env)
                          (OkMacroLetBindings
                            (ast-let-binding-cons
                              (ast-let-binding name maybe-ty ninit)
                              nrest)
                            final-env)]
                        [(ErrMacroLetBindings diag) (ErrMacroLetBindings diag)])]
                    [(ErrTcEnv message)
                      (ErrMacroLetBindings (tc-expr-diag ninit message))])]
                [(ErrMacroExpr diag) (ErrMacroLetBindings diag)]))]))]))

(define (macro-compat-unit-expr) : AstExpr
  (AstExprLiteral AstLitUnit))

(define (macro-compat-append-unit [exprs : AstExprList]) : AstExprList
  (match exprs
    [(AstExprNil) (ast-expr-cons (macro-compat-unit-expr) AstExprNil)]
    [(AstExprCons head rest)
      (let
        [head : AstExpr (box-get head)]
        [rest : AstExprList (box-get rest)]
        (ast-expr-cons head (macro-compat-append-unit rest)))]))

(define (macro-compat-call-name [func : AstExpr]) : TcMaybeString
  (match (ast-expr-unspan func)
    [(AstExprVar name) (TcSomeString name)]
    [_ (TcNoString)]))

(define (macro-compat-guard-message [name : String]) : String
  (if (string-eq name "unless")
    "parse: unless expects a condition and at least one body expression"
    "parse: when expects a condition and at least one body expression"))

(define (macro-expand-compat-guard-body
  [ctx : TcContext]
  [env : TcTypeEnv]
  [decls : AstDeclList]
  [depth : i64]
  [cond : AstExpr]
  [body : AstExprList]
  [is-unless : bool]) : ResultMacroCompatCall
  (match (macro-expand-expr ctx env decls depth cond)
    [(OkMacroExpr ncond)
      (match (macro-expand-exprs ctx env decls depth body)
        [(OkMacroExprList nbody)
          (let
            [unit-expr : AstExpr (macro-compat-unit-expr)]
            [body-expr : AstExpr
              (AstExprBegin (macro-compat-append-unit nbody))]
            (if is-unless
              (OkMacroCompatCall (ast-expr-if ncond unit-expr body-expr))
              (OkMacroCompatCall (ast-expr-if ncond body-expr unit-expr))))]
        [(ErrMacroExprList diag) (ErrMacroCompatCall diag)])]
    [(ErrMacroExpr diag) (ErrMacroCompatCall diag)]))

(define (macro-expand-compat-guard-call
  [ctx : TcContext]
  [env : TcTypeEnv]
  [decls : AstDeclList]
  [depth : i64]
  [name : String]
  [args : AstExprList]
  [is-unless : bool]
  [call-expr : AstExpr]) : ResultMacroCompatCall
  (match args
    [(AstExprCons cond body)
      (let
        [cond : AstExpr (box-get cond)]
        [body : AstExprList (box-get body)]
        (match body
          [(AstExprNil)
            (ErrMacroCompatCall
              (ctfe-diagnostic-at-expr
                call-expr
                (macro-compat-guard-message name)))]
          [_
            (macro-expand-compat-guard-body
              ctx
              env
              decls
              depth
              cond
              body
              is-unless)]))]
    [_
      (ErrMacroCompatCall
        (ctfe-diagnostic-at-expr call-expr (macro-compat-guard-message name)))]))

(define (macro-expand-compat-call
  [ctx : TcContext]
  [env : TcTypeEnv]
  [decls : AstDeclList]
  [depth : i64]
  [func : AstExpr]
  [args : AstExprList]
  [call-expr : AstExpr]) : ResultMacroCompatCall
  (match (macro-compat-call-name func)
    [(TcSomeString name)
      (cond
        [(string-eq name "when")
          (macro-expand-compat-guard-call
            ctx
            env
            decls
            depth
            name
            args
            false
            call-expr)]
        [(string-eq name "unless")
          (macro-expand-compat-guard-call
            ctx
            env
            decls
            depth
            name
            args
            true
            call-expr)]
        [else (NoMacroCompatCall)])]
    [(TcNoString) (NoMacroCompatCall)]))

(define (macro-expand-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [decls : AstDeclList]
  [depth : i64]
  [expr : AstExpr]) : ResultMacroExpr
  (if (< (macro-expand-depth-limit) depth)
    (ErrMacroExpr
      (ctfe-diagnostic-at-expr expr "macro expansion exceeded depth limit"))
    (match expr
      [(AstExprSpanned inner-box span)
        (let
          [inner : AstExpr (box-get inner-box)]
          (match (macro-expand-expr ctx env decls depth inner)
            [(OkMacroExpr ninner) (OkMacroExpr (ast-expr-spanned ninner span))]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprCall func-box args)
        (let
          [func : AstExpr (box-get func-box)]
          (match (macro-call-decl ctx func decls expr)
            [(OkMacroCallDecl maybe-decl)
              (match maybe-decl
                [(MacroSomeDecl macro-name params ret body)
                  (macro-expand-call
                    ctx
                    env
                    decls
                    macro-name
                    params
                    ret
                    body
                    args
                    depth
                    expr)]
                [(MacroNoDecl)
                  (match (macro-expand-compat-call
                    ctx
                    env
                    decls
                    depth
                    func
                    args
                    expr)
                    [(OkMacroCompatCall expanded) (OkMacroExpr expanded)]
                    [(NoMacroCompatCall)
                      (match (macro-expand-expr ctx env decls depth func)
                        [(OkMacroExpr nfunc)
                          (match (macro-expand-exprs ctx env decls depth args)
                            [(OkMacroExprList nargs)
                              (OkMacroExpr (ast-expr-call nfunc nargs))]
                            [(ErrMacroExprList diag) (ErrMacroExpr diag)])]
                        [(ErrMacroExpr diag) (ErrMacroExpr diag)])]
                    [(ErrMacroCompatCall diag) (ErrMacroExpr diag)])])]
            [(ErrMacroCallDecl diag) (ErrMacroExpr diag)]))]
      [(AstExprBinary op left-box right-box)
        (let
          [left : AstExpr (box-get left-box)]
          [right : AstExpr (box-get right-box)]
          (match (macro-expand-expr ctx env decls depth left)
            [(OkMacroExpr nleft)
              (match (macro-expand-expr ctx env decls depth right)
                [(OkMacroExpr nright)
                  (OkMacroExpr (ast-expr-binary op nleft nright))]
                [(ErrMacroExpr diag) (ErrMacroExpr diag)])]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprUnary op inner-box)
        (let
          [inner : AstExpr (box-get inner-box)]
          (match (macro-expand-expr ctx env decls depth inner)
            [(OkMacroExpr ninner) (OkMacroExpr (ast-expr-unary op ninner))]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprIf cond-box then-branch-box else-branch-box)
        (let
          [cond : AstExpr (box-get cond-box)]
          [then-branch : AstExpr (box-get then-branch-box)]
          [else-branch : AstExpr (box-get else-branch-box)]
          (match (macro-expand-expr ctx env decls depth cond)
            [(OkMacroExpr ncond)
              (match (macro-expand-expr ctx env decls depth then-branch)
                [(OkMacroExpr nthen)
                  (match (macro-expand-expr ctx env decls depth else-branch)
                    [(OkMacroExpr nelse)
                      (OkMacroExpr (ast-expr-if ncond nthen nelse))]
                    [(ErrMacroExpr diag) (ErrMacroExpr diag)])]
                [(ErrMacroExpr diag) (ErrMacroExpr diag)])]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprLet bindings body-box)
        (let
          [body : AstExpr (box-get body-box)]
          (match (macro-expand-bindings ctx env decls depth bindings)
            [(OkMacroLetBindings nbindings body-env)
              (match (macro-expand-expr ctx body-env decls depth body)
                [(OkMacroExpr nbody)
                  (OkMacroExpr (ast-expr-let nbindings nbody))]
                [(ErrMacroExpr diag) (ErrMacroExpr diag)])]
            [(ErrMacroLetBindings diag) (ErrMacroExpr diag)]))]
      [(AstExprBegin exprs)
        (match (macro-expand-exprs ctx env decls depth exprs)
          [(OkMacroExprList nexprs) (OkMacroExpr (AstExprBegin nexprs))]
          [(ErrMacroExprList diag) (ErrMacroExpr diag)])]
      [(AstExprUnsafe exprs)
        (match (macro-expand-exprs ctx env decls depth exprs)
          [(OkMacroExprList nexprs) (OkMacroExpr (AstExprUnsafe nexprs))]
          [(ErrMacroExprList diag) (ErrMacroExpr diag)])]
      [(AstExprTuple exprs)
        (match (macro-expand-exprs ctx env decls depth exprs)
          [(OkMacroExprList nexprs) (OkMacroExpr (AstExprTuple nexprs))]
          [(ErrMacroExprList diag) (ErrMacroExpr diag)])]
      [(AstExprArray exprs)
        (match (macro-expand-exprs ctx env decls depth exprs)
          [(OkMacroExprList nexprs) (OkMacroExpr (AstExprArray nexprs))]
          [(ErrMacroExprList diag) (ErrMacroExpr diag)])]
      [(AstExprMatch scrut-box arms)
        (let
          [scrut : AstExpr (box-get scrut-box)]
          (match (macro-expand-expr ctx env decls depth scrut)
            [(OkMacroExpr nscrut)
              (match (tc-expr ctx env nscrut)
                [(OkTcType scrut-ty)
                  (match (macro-expand-arms ctx env decls depth scrut-ty arms)
                    [(OkMacroArms narms)
                      (OkMacroExpr (ast-expr-match nscrut narms))]
                    [(ErrMacroArms diag) (ErrMacroExpr diag)])]
                [(ErrTcType message)
                  (ErrMacroExpr (tc-expr-diag nscrut message))])]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprWhile cond-box body-box)
        (let
          [cond : AstExpr (box-get cond-box)]
          [body : AstExpr (box-get body-box)]
          (match (macro-expand-expr ctx env decls depth cond)
            [(OkMacroExpr ncond)
              (match (macro-expand-expr ctx env decls depth body)
                [(OkMacroExpr nbody) (OkMacroExpr (ast-expr-while ncond nbody))]
                [(ErrMacroExpr diag) (ErrMacroExpr diag)])]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprForeach index index-ty start-box end-box body-box)
        (let
          [start : AstExpr (box-get start-box)]
          [end : AstExpr (box-get end-box)]
          [body : AstExpr (box-get body-box)]
          (match (macro-expand-expr ctx env decls depth start)
            [(OkMacroExpr nstart)
              (match (macro-expand-expr ctx env decls depth end)
                [(OkMacroExpr nend)
                  (match (macro-expand-expr
                    ctx
                    (tc-bind env index (tc-resolve-type ctx index-ty))
                    decls
                    depth
                    body)
                    [(OkMacroExpr nbody)
                      (OkMacroExpr
                        (ast-expr-foreach index index-ty nstart nend nbody))]
                    [(ErrMacroExpr diag) (ErrMacroExpr diag)])]
                [(ErrMacroExpr diag) (ErrMacroExpr diag)])]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprLambda params maybe-ret body-box)
        (let
          [body : AstExpr (box-get body-box)]
          (match (macro-expand-expr
            ctx
            (match maybe-ret
              [(AstSomeType ret)
                (tc-bind-return-type
                  (tc-bind-params ctx env params)
                  (tc-resolve-type ctx ret))]
              [(AstNoType)
                (tc-bind-return-type
                  (tc-bind-params ctx env params)
                  (AstTyNever))])
            decls
            depth
            body)
            [(OkMacroExpr nbody)
              (OkMacroExpr (ast-expr-lambda params maybe-ret nbody))]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprAnn inner-box ty)
        (let
          [inner : AstExpr (box-get inner-box)]
          (match (macro-expand-expr ctx env decls depth inner)
            [(OkMacroExpr ninner) (OkMacroExpr (ast-expr-ann ninner ty))]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprCast inner-box ty)
        (let
          [inner : AstExpr (box-get inner-box)]
          (match (macro-expand-expr ctx env decls depth inner)
            [(OkMacroExpr ninner) (OkMacroExpr (ast-expr-cast ninner ty))]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprStructGet inner-box field)
        (let
          [inner : AstExpr (box-get inner-box)]
          (match (macro-expand-expr ctx env decls depth inner)
            [(OkMacroExpr ninner)
              (OkMacroExpr (ast-expr-struct-get ninner field))]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprArrayRef array-box index-box)
        (let
          [array : AstExpr (box-get array-box)]
          [index : AstExpr (box-get index-box)]
          (match (macro-expand-expr ctx env decls depth array)
            [(OkMacroExpr narray)
              (match (macro-expand-expr ctx env decls depth index)
                [(OkMacroExpr nindex)
                  (OkMacroExpr (ast-expr-array-ref narray nindex))]
                [(ErrMacroExpr diag) (ErrMacroExpr diag)])]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprArraySet array-box index-box value-box)
        (let
          [array : AstExpr (box-get array-box)]
          [index : AstExpr (box-get index-box)]
          [value : AstExpr (box-get value-box)]
          (match (macro-expand-expr ctx env decls depth array)
            [(OkMacroExpr narray)
              (match (macro-expand-expr ctx env decls depth index)
                [(OkMacroExpr nindex)
                  (match (macro-expand-expr ctx env decls depth value)
                    [(OkMacroExpr nvalue)
                      (OkMacroExpr (ast-expr-array-set narray nindex nvalue))]
                    [(ErrMacroExpr diag) (ErrMacroExpr diag)])]
                [(ErrMacroExpr diag) (ErrMacroExpr diag)])]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprBox inner-box)
        (let
          [inner : AstExpr (box-get inner-box)]
          (match (macro-expand-expr ctx env decls depth inner)
            [(OkMacroExpr ninner) (OkMacroExpr (ast-expr-box ninner))]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprBoxGet inner-box)
        (let
          [inner : AstExpr (box-get inner-box)]
          (match (macro-expand-expr ctx env decls depth inner)
            [(OkMacroExpr ninner) (OkMacroExpr (ast-expr-box-get ninner))]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprComptime inner-box)
        (let
          [inner : AstExpr (box-get inner-box)]
          (match (macro-expand-expr ctx env decls depth inner)
            [(OkMacroExpr ninner) (OkMacroExpr (ast-expr-comptime ninner))]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprReturn inner-box)
        (let
          [inner : AstExpr (box-get inner-box)]
          (match (macro-expand-expr ctx env decls depth inner)
            [(OkMacroExpr ninner) (OkMacroExpr (ast-expr-return ninner))]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprSet name rhs-box)
        (let
          [rhs : AstExpr (box-get rhs-box)]
          (match (macro-expand-expr ctx env decls depth rhs)
            [(OkMacroExpr nrhs) (OkMacroExpr (ast-expr-set name nrhs))]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprStringData inner-box)
        (let
          [inner : AstExpr (box-get inner-box)]
          (match (macro-expand-expr ctx env decls depth inner)
            [(OkMacroExpr ninner) (OkMacroExpr (ast-expr-string-data ninner))]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprStringFromBytes ptr-box len-box)
        (let
          [ptr : AstExpr (box-get ptr-box)]
          [len : AstExpr (box-get len-box)]
          (match (macro-expand-expr ctx env decls depth ptr)
            [(OkMacroExpr nptr)
              (match (macro-expand-expr ctx env decls depth len)
                [(OkMacroExpr nlen)
                  (OkMacroExpr (ast-expr-string-from-bytes nptr nlen))]
                [(ErrMacroExpr diag) (ErrMacroExpr diag)])]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprArrayData inner-box)
        (let
          [inner : AstExpr (box-get inner-box)]
          (match (macro-expand-expr ctx env decls depth inner)
            [(OkMacroExpr ninner) (OkMacroExpr (ast-expr-array-data ninner))]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprCpuIdEax leaf-box subleaf-box)
        (let
          [leaf : AstExpr (box-get leaf-box)]
          [subleaf : AstExpr (box-get subleaf-box)]
          (match (macro-expand-expr ctx env decls depth leaf)
            [(OkMacroExpr nleaf)
              (match (macro-expand-expr ctx env decls depth subleaf)
                [(OkMacroExpr nsubleaf)
                  (OkMacroExpr (ast-expr-cpuid-eax nleaf nsubleaf))]
                [(ErrMacroExpr diag) (ErrMacroExpr diag)])]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprCpuIdEbx leaf-box subleaf-box)
        (let
          [leaf : AstExpr (box-get leaf-box)]
          [subleaf : AstExpr (box-get subleaf-box)]
          (match (macro-expand-expr ctx env decls depth leaf)
            [(OkMacroExpr nleaf)
              (match (macro-expand-expr ctx env decls depth subleaf)
                [(OkMacroExpr nsubleaf)
                  (OkMacroExpr (ast-expr-cpuid-ebx nleaf nsubleaf))]
                [(ErrMacroExpr diag) (ErrMacroExpr diag)])]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprCpuIdEcx leaf-box subleaf-box)
        (let
          [leaf : AstExpr (box-get leaf-box)]
          [subleaf : AstExpr (box-get subleaf-box)]
          (match (macro-expand-expr ctx env decls depth leaf)
            [(OkMacroExpr nleaf)
              (match (macro-expand-expr ctx env decls depth subleaf)
                [(OkMacroExpr nsubleaf)
                  (OkMacroExpr (ast-expr-cpuid-ecx nleaf nsubleaf))]
                [(ErrMacroExpr diag) (ErrMacroExpr diag)])]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprCpuIdEdx leaf-box subleaf-box)
        (let
          [leaf : AstExpr (box-get leaf-box)]
          [subleaf : AstExpr (box-get subleaf-box)]
          (match (macro-expand-expr ctx env decls depth leaf)
            [(OkMacroExpr nleaf)
              (match (macro-expand-expr ctx env decls depth subleaf)
                [(OkMacroExpr nsubleaf)
                  (OkMacroExpr (ast-expr-cpuid-edx nleaf nsubleaf))]
                [(ErrMacroExpr diag) (ErrMacroExpr diag)])]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [(AstExprXgetbv index-box)
        (let
          [index : AstExpr (box-get index-box)]
          (match (macro-expand-expr ctx env decls depth index)
            [(OkMacroExpr nindex) (OkMacroExpr (ast-expr-xgetbv nindex))]
            [(ErrMacroExpr diag) (ErrMacroExpr diag)]))]
      [_ (OkMacroExpr expr)])))

(define (macro-expand-decl
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [decls : AstDeclList]
  [decl : AstDecl]) : ResultMacroDecl
  (let
    [global-env : TcTypeEnv (tc-hygiene-global-env top-env)]
    (match decl
      [(AstDeclDef name maybe-ty expr-box)
        (let
          [expr : AstExpr (box-get expr-box)]
          (match (macro-expand-expr ctx global-env decls 0 expr)
            [(OkMacroExpr nexpr)
              (OkMacroDecl (ast-decl-def name maybe-ty nexpr))]
            [(ErrMacroExpr diag) (ErrMacroDecl diag)]))]
      [(AstDeclDefFn name params ret body-box)
        (let
          [body : AstExpr (box-get body-box)]
          (match (macro-expand-expr
            ctx
            (tc-bind-return-type
              (tc-bind-params ctx global-env params)
              (tc-resolve-type ctx ret))
            decls
            0
            body)
            [(OkMacroExpr nbody)
              (OkMacroDecl (ast-decl-def-fn name params ret nbody))]
            [(ErrMacroExpr diag) (ErrMacroDecl diag)]))]
      [(AstDeclTest name expr-box span)
        (let
          [expr : AstExpr (box-get expr-box)]
          (match (macro-expand-expr ctx global-env decls 0 expr)
            [(OkMacroExpr nexpr) (OkMacroDecl (ast-decl-test name nexpr span))]
            [(ErrMacroExpr diag) (ErrMacroDecl diag)]))]
      [(AstDeclUnsafe inner-box)
        (let
          [inner : AstDecl (box-get inner-box)]
          (match (macro-expand-decl ctx top-env decls inner)
            [(OkMacroDecl ninner) (OkMacroDecl (ast-decl-unsafe ninner))]
            [(ErrMacroDecl diag) (ErrMacroDecl diag)]))]
      [_ (OkMacroDecl decl)])))

(define (macro-expand-decls
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [orig-decls : AstDeclList]
  [decls : AstDeclList]
  [compat-only : bool]) : ResultMacroDecls
  (match decls
    [(AstDeclNil) (OkMacroDecls (AstDeclNil))]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule next-module)
            (begin
              (set! macro-expand-active-module next-module)
              (match (macro-expand-decls
                ctx
                top-env
                orig-decls
                rest
                compat-only)
                [(OkMacroDecls nrest) (OkMacroDecls (ast-decl-cons decl nrest))]
                [(ErrMacroDecls diag) (ErrMacroDecls diag)]))]
          [_
            (if (and compat-only (not (macro-decl-needs-expansion? decl)))
              (begin
                (macro-local-decl-index-step! decl)
                (match (macro-expand-decls
                  ctx
                  top-env
                  orig-decls
                  rest
                  compat-only)
                  [(OkMacroDecls nrest)
                    (OkMacroDecls (ast-decl-cons decl nrest))]
                  [(ErrMacroDecls diag) (ErrMacroDecls diag)]))
              (let
                [decl-ctx : TcContext
                  (tc-context-with-module ctx macro-expand-active-module)]
                (match (macro-expand-decl decl-ctx top-env orig-decls decl)
                  [(OkMacroDecl ndecl)
                    (begin
                      (macro-local-decl-index-step! decl)
                      (match (macro-expand-decls
                        ctx
                        top-env
                        orig-decls
                        rest
                        compat-only)
                        [(OkMacroDecls nrest)
                          (OkMacroDecls (ast-decl-cons ndecl nrest))]
                        [(ErrMacroDecls diag) (ErrMacroDecls diag)]))]
                  [(ErrMacroDecl diag) (ErrMacroDecls diag)])))]))]))

(define (macro-expr-needs-compat-expansion? [expr : AstExpr]) : bool
  (or
    (tc-expr-uses-free-name? expr "when" TcStringNil)
    (tc-expr-uses-free-name? expr "unless" TcStringNil)))

(define (macro-decl-needs-expansion? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclDef _ _ expr-box)
      (let
        [expr : AstExpr (box-get expr-box)]
        (macro-expr-needs-compat-expansion? expr))]
    [(AstDeclDefFn _ _ _ body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (macro-expr-needs-compat-expansion? body))]
    [(AstDeclDefMacro _ _ _ _) true]
    [(AstDeclTest _ body-box _)
      (let
        [body : AstExpr (box-get body-box)]
        (macro-expr-needs-compat-expansion? body))]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (macro-decl-needs-expansion? inner))]
    [(AstDeclComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (macro-decl-needs-expansion? template))]
    [_ false]))

(define (macro-decl-has-defmacro? [decl : AstDecl]) : bool
  (match decl
    [(AstDeclDefMacro _ _ _ _) true]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (macro-decl-has-defmacro? inner))]
    [(AstDeclComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (macro-decl-has-defmacro? template))]
    [_ false]))

;; Whether a program needs the macro expansion pass.
(define (macro-program-needs-expansion? [decls : AstDeclList]) : bool
  (match decls
    [(AstDeclNil) false]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (or
          (macro-decl-needs-expansion? decl)
          (macro-program-needs-expansion? rest)))]))

(define (macro-program-has-defmacro? [decls : AstDeclList]) : bool
  (match decls
    [(AstDeclNil) false]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (or (macro-decl-has-defmacro? decl) (macro-program-has-defmacro? rest)))]))

;; Expand all macro calls in a parsed program before typechecking. Programs that
;; need no macro or guard-compatibility expansion are returned unchanged without
;; rebuilding the AST, so the expansion phase adds no allocation for the common
;; case.
(define (macro-expand-program [program : AstProgram]) : ResultMacroExpand
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        [has-defmacro : bool (macro-program-has-defmacro? decls)]
        (if (or has-defmacro (macro-program-needs-expansion? decls))
          (match (build-compiler-symbols program)
            [(OkCompilerSymbols symbols)
              (match (build-compiler-registries-with-symbols program symbols)
                [(OkCompilerRegistries registries)
                  (match (build-compiler-exports-with
                    program
                    symbols
                    registries)
                    [(OkCompilerExports _)
                      (begin
                        (set! macro-expand-active-module "")
                        (set! macro-expand-active-index 0)
                        (let
                          [ctx : TcContext
                            (TcContext program symbols registries "")]
                          (match (tc-build-top-env ctx program)
                            [(OkTcEnv top-env)
                              (match (macro-expand-decls
                                ctx
                                top-env
                                decls
                                decls
                                (not has-defmacro))
                                [(OkMacroDecls ndecls)
                                  (OkMacroExpand (ast-program ndecls))]
                                [(ErrMacroDecls diag) (ErrMacroExpand diag)])]
                            [(ErrTcEnv message)
                              (ErrMacroExpand (tc-diag-at-start message))])))]
                    [(ErrCompilerExports message)
                      (ErrMacroExpand (tc-diag-at-start message))])]
                [(ErrCompilerRegistries message)
                  (ErrMacroExpand (tc-diag-at-start message))])]
            [(ErrCompilerSymbols message)
              (ErrMacroExpand (tc-diag-at-start message))])
          (OkMacroExpand program)))]))

(define (tc-cleanup-owning-struct-type? [ctx : TcContext] [ty : AstType]) : bool
  (match (tc-type-strip-region (tc-resolve-type ctx ty))
    [(AstTyStruct struct-name)
      (match (tc-struct-decl ctx struct-name)
        [(OkTcStructDecl decl)
          (match decl
            [(TcStructDecl _ cleanup _) (ast-struct-cleanup? cleanup)])]
        [(ErrTcStructDecl _) false])]
    [(AstTyStructArgs struct-name _)
      (match (tc-struct-decl ctx struct-name)
        [(OkTcStructDecl decl)
          (match decl
            [(TcStructDecl _ cleanup _) (ast-struct-cleanup? cleanup)])]
        [(ErrTcStructDecl _) false])]
    [_ false]))

(define (tc-struct-field-cleanup-outside-message
  [struct-name : String]
  [field-name : String]) : String
  (tc-cat3
    "typecheck: struct "
    struct-name
    (tc-cat3
      " field "
      field-name
      " has cleanup metadata but struct is not cleanup-owning")))

(define (tc-struct-field-cleanup-owning-without-owned-message
  [struct-name : String]
  [field-name : String]
  [ty : AstType]) : String
  (tc-cat3
    "typecheck: struct "
    struct-name
    (tc-cat3
      " field "
      field-name
      (tc-cat3
        " stores cleanup-owning type "
        (tc-type-render ty)
        " without :owned"))))

(define (tc-struct-field-owned-non-cleanup-message
  [struct-name : String]
  [field-name : String]
  [ty : AstType]) : String
  (tc-cat3
    "typecheck: struct "
    struct-name
    (tc-cat3
      " field "
      field-name
      (tc-cat3
        " uses :owned but type "
        (tc-type-render ty)
        " is not cleanup-owning"))))

(define (tc-struct-field-cleanup-fn-mismatch-message
  [struct-name : String]
  [field-name : String]
  [cleanup-name : String]) : String
  (tc-cat3
    "typecheck: struct "
    struct-name
    (tc-cat3
      " field "
      field-name
      (tc-cat3 " cleanup function " cleanup-name " type mismatch"))))

(define (tc-check-struct-field-cleanup-fn
  [ctx : TcContext]
  [env : TcTypeEnv]
  [struct-name : String]
  [field-name : String]
  [cleanup-name : String]
  [field-ty : AstType]) : ResultTcUnit
  (match (tc-lookup-visible ctx env cleanup-name)
    [(OkTcType cleanup-ty)
      (tc-expect
        cleanup-ty
        (tc-fn1 (tc-type-without-regions field-ty) (AstTyUnit))
        (tc-struct-field-cleanup-fn-mismatch-message
          struct-name
          field-name
          cleanup-name))]
    [(ErrTcType message) (ErrTcUnit message)]))

(define (tc-check-cleanup-struct-field
  [ctx : TcContext]
  [env : TcTypeEnv]
  [struct-name : String]
  [struct-cleanup : AstStructCleanup]
  [field : AstFieldDef]) : ResultTcUnit
  (match field
    [(AstFieldDef field-name ty field-cleanup)
      (let
        [resolved-ty : AstType (tc-type-strip-region (tc-resolve-type ctx ty))]
        [field-cleanup-owning : bool
          (tc-cleanup-owning-struct-type? ctx resolved-ty)]
        (if (not (ast-struct-cleanup? struct-cleanup))
          (if (ast-field-cleanup? field-cleanup)
            (ErrTcUnit
              (tc-struct-field-cleanup-outside-message struct-name field-name))
            (if field-cleanup-owning
              (ErrTcUnit
                (tc-struct-field-cleanup-owning-without-owned-message
                  struct-name
                  field-name
                  resolved-ty))
              OkTcUnit))
          (match field-cleanup
            [(AstFieldOwnedCleanup)
              (if field-cleanup-owning
                OkTcUnit
                (ErrTcUnit
                  (tc-struct-field-owned-non-cleanup-message
                    struct-name
                    field-name
                    resolved-ty)))]
            [(AstFieldCleanupFn cleanup-name)
              (if field-cleanup-owning
                (ErrTcUnit
                  (tc-struct-field-cleanup-owning-without-owned-message
                    struct-name
                    field-name
                    resolved-ty))
                (tc-check-struct-field-cleanup-fn
                  ctx
                  env
                  struct-name
                  field-name
                  cleanup-name
                  resolved-ty))]
            [(AstFieldNoCleanup)
              (if field-cleanup-owning
                (ErrTcUnit
                  (tc-struct-field-cleanup-owning-without-owned-message
                    struct-name
                    field-name
                    resolved-ty))
                OkTcUnit)])))]))

(define (tc-check-cleanup-struct-fields
  [ctx : TcContext]
  [env : TcTypeEnv]
  [struct-name : String]
  [cleanup : AstStructCleanup]
  [fields : AstFieldDefList]) : ResultTcUnit
  (match fields
    [(AstFieldDefNil) OkTcUnit]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match (tc-check-cleanup-struct-field ctx env struct-name cleanup field)
          [(OkTcUnit)
            (tc-check-cleanup-struct-fields ctx env struct-name cleanup rest)]
          [(ErrTcUnit message) (ErrTcUnit message)]))]))

(define (tc-check-cleanup-struct-decl
  [ctx : TcContext]
  [env : TcTypeEnv]
  [name : String]
  [repr : AstStructRepr]
  [cleanup : AstStructCleanup]
  [fields : AstFieldDefList]) : ResultTcUnit
  (let
    [struct-name : String
      (compiler-symbol-module-key (tc-context-module ctx) name)]
    (if (and (ast-struct-repr-c? repr) (ast-struct-cleanup? cleanup))
      (ErrTcUnit (tc-struct-cleanup-repr-c-message struct-name))
      (tc-check-cleanup-struct-fields ctx env struct-name cleanup fields))))

(define (tc-check-decl-with-global-env
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [global-env : TcTypeEnv]
  [decl : AstDecl]) : ResultTcUnit
  (match decl
    [(AstDeclDef _ maybe-ty expr-box)
      (let
        [expr : AstExpr (box-get expr-box)]
        (match maybe-ty
          [(AstSomeType want)
            (match (tc-expr-with-expected-or-actual
              ctx
              global-env
              expr
              (tc-resolve-type ctx want))
              [(OkTcType got)
                (match (tc-expect
                  got
                  (tc-resolve-type ctx want)
                  "typecheck: value definition type mismatch")
                  [(OkTcUnit)
                    (tc-ensure-region-value-can-flow-into
                      global-env
                      (tc-resolve-type ctx want)
                      got
                      "top-level value")]
                  [(ErrTcUnit message) (ErrTcUnit message)])]
              [(ErrTcType message) (ErrTcUnit message)])]
          [(AstNoType)
            (match (tc-expr ctx global-env expr)
              [(OkTcType _) OkTcUnit]
              [(ErrTcType message) (ErrTcUnit message)])]))]
    [(AstDeclDefFn _ params ret body-box)
      (let
        [body : AstExpr (box-get body-box)]
        [env : TcTypeEnv
          (tc-bind-return-type
            (tc-bind-params ctx global-env params)
            (tc-resolve-type ctx ret))]
        (match (tc-expr-with-expected-or-actual
          ctx
          env
          body
          (tc-resolve-type ctx ret))
          [(OkTcType got)
            (match (tc-expect
              got
              (tc-resolve-type ctx ret)
              "typecheck: return type mismatch")
              [(OkTcUnit)
                (match (tc-ensure-region-value-can-flow-into
                  env
                  (tc-resolve-type ctx ret)
                  got
                  "return value")
                  [(OkTcUnit) (tc-move-check-body ctx env params body)]
                  [(ErrTcUnit message) (ErrTcUnit message)])]
              [(ErrTcUnit message) (ErrTcUnit message)])]
          [(ErrTcType message) (ErrTcUnit message)]))]
    [(AstDeclDefMacro _ params ret body-box)
      (let
        [body : AstExpr (box-get body-box)]
        (tc-check-defmacro ctx top-env params ret body))]
    [(AstDeclExtern _ metadata ty) (tc-check-extern-decl ctx metadata ty)]
    [(AstDeclDefDispatch name variants)
      (match (tc-dispatch-decl-type ctx name variants)
        [(OkTcType _) OkTcUnit]
        [(ErrTcType message) (ErrTcUnit message)])]
    [(AstDeclDefStruct name repr cleanup fields)
      (tc-check-cleanup-struct-decl ctx top-env name repr cleanup fields)]
    [(AstDeclDefStructLifetimes name _ repr cleanup fields)
      (tc-check-cleanup-struct-decl ctx top-env name repr cleanup fields)]
    [(AstDeclComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (tc-check-decl-with-global-env ctx top-env global-env template))]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (tc-check-decl-with-global-env ctx top-env global-env inner))]
    [_ OkTcUnit]))

(define (tc-check-decl [ctx : TcContext] [top-env : TcTypeEnv] [decl : AstDecl]) : ResultTcUnit
  (tc-check-decl-with-global-env
    ctx
    top-env
    (tc-hygiene-global-env top-env)
    decl))

(define (tc-check-decls
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [decls : AstDeclList]
  [summary : CompilerTypecheckSummary]) : ResultCompilerTypecheck
  (tc-check-decls-in-module ctx top-env decls summary ""))

(define (tc-check-decls-in-module
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [decls : AstDeclList]
  [summary : CompilerTypecheckSummary]
  [module : String]) : ResultCompilerTypecheck
  (match decls
    [(AstDeclNil) (OkCompilerTypecheck summary)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule next-module)
            (tc-check-decls-in-module ctx top-env rest summary next-module)]
          [_
            (match (tc-module-local-env ctx top-env module)
              [(OkTcEnv local-env)
                (let
                  [decl-ctx : TcContext (tc-context-with-module ctx module)]
                  (match (tc-check-decl decl-ctx local-env decl)
                    [(OkTcUnit)
                      (tc-check-decls-in-module
                        ctx
                        top-env
                        rest
                        (tc-summary-add-decl summary decl)
                        module)]
                    [(ErrTcUnit message)
                      (ErrCompilerTypecheck (tc-decl-diag decl message))]))]
              [(ErrTcEnv message)
                (ErrCompilerTypecheck (tc-decl-diag decl message))])]))]))

(define (tc-check-decls-with-paths
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [summary : CompilerTypecheckSummary]) : ResultCompilerTypecheck
  (begin
    (cfg compile-profile (compiler-tc-decl-profile-reset))
    (tc-check-decls-with-paths-in-module
      ctx
      top-env
      decls
      paths
      summary
      ""
      (TcModuleLocalEnvNil))))

(define (tc-generated-clone-name? [name : String]) : bool
  (if (>= (string-length name) 6)
    (string-eq (substring name 0 6) "clone$")
    false))

(define (tc-generated-clone-decl-with-path? [decl : AstDecl] [path : String]) : bool
  (if (string-eq path "")
    (match decl
      [(AstDeclDefFn name _ _ _) (tc-generated-clone-name? name)]
      [_ false])
    false))

(define (tc-typecheck-diag-with-path
  [decl : AstDecl]
  [path : String]
  [message : String]) : CompilerDiagnostic
  (let
    [diag : CompilerDiagnostic (tc-decl-diag decl message)]
    (if (string-eq path "")
      diag
      (compiler-diagnostic-with-path diag path))))

;; Direct declaration typechecking stays below the self-build memory budget and
;; avoids the per-declaration scratch arena overhead.
(define (tc-check-decl-escaping
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [decl : AstDecl]) : ResultTcUnit
  (tc-check-decl ctx top-env decl))

(define (tc-check-one-decl-with-module
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [decl : AstDecl]
  [module : String]) : ResultTcUnit
  (match (tc-module-local-env ctx top-env module)
    [(OkTcEnv local-env)
      (let
        [decl-ctx : TcContext (tc-context-with-module ctx module)]
        (tc-check-decl-escaping decl-ctx local-env decl))]
    [(ErrTcEnv message) (ErrTcUnit message)]))

(define (tc-check-decls-with-paths-in-module
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [summary : CompilerTypecheckSummary]
  [module : String]
  [cache : TcModuleLocalEnvCache]) : ResultCompilerTypecheck
  (begin
    (cfg compile-profile (compiler-tc-decl-profile-start-section))
    (match (tc-module-local-env-cached ctx top-env module cache)
      [(OkTcModuleLocalEnv local-env next-cache)
        (begin
          (cfg compile-profile (compiler-tc-decl-profile-add-local-env))
          (tc-check-decls-with-paths-in-module-env
            ctx
            top-env
            decls
            paths
            summary
            module
            next-cache
            local-env
            (tc-hygiene-global-env local-env)))]
      [(ErrTcModuleLocalEnv message)
        (begin
          (cfg compile-profile (compiler-tc-decl-profile-add-local-env))
          (ErrCompilerTypecheck (tc-diag-at-start message)))])))

(define (tc-check-decls-with-paths-in-module-env
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [summary : CompilerTypecheckSummary]
  [module : String]
  [cache : TcModuleLocalEnvCache]
  [local-env : TcTypeEnv]
  [global-env : TcTypeEnv]) : ResultCompilerTypecheck
  (match decls
    [(AstDeclNil)
      (begin
        (cfg compile-profile (compiler-tc-decl-profile-finish))
        (OkCompilerTypecheck summary))]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) ""])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest)
              (let
                [path-rest : AstDeclPathList (box-get path-rest)]
                path-rest)]
            [(AstDeclPathNil) AstDeclPathNil])]
        (match decl
          [(AstDeclModule next-module)
            (begin
              (cfg compile-profile (compiler-tc-decl-profile-start-section))
              (match (tc-module-local-env-cached ctx top-env next-module cache)
                [(OkTcModuleLocalEnv next-local-env next-cache)
                  (begin
                    (cfg
                      compile-profile
                      (compiler-tc-decl-profile-add-local-env))
                    (tc-check-decls-with-paths-in-module-env
                      ctx
                      top-env
                      rest
                      rest-paths
                      summary
                      next-module
                      next-cache
                      next-local-env
                      (tc-hygiene-global-env next-local-env)))]
                [(ErrTcModuleLocalEnv message)
                  (begin
                    (cfg
                      compile-profile
                      (compiler-tc-decl-profile-add-local-env))
                    (ErrCompilerTypecheck
                      (tc-typecheck-diag-with-path decl decl-path message)))]))]
          [_
            (if (tc-generated-clone-decl-with-path? decl decl-path)
              (tc-check-decls-with-paths-in-module-env
                ctx
                top-env
                rest
                rest-paths
                (tc-summary-add-decl summary decl)
                module
                cache
                local-env
                global-env)
              (let
                [decl-ctx : TcContext (tc-context-with-module ctx module)]
                (begin
                  (cfg compile-profile (compiler-tc-decl-profile-start-section))
                  (match (tc-check-decl-with-global-env
                    decl-ctx
                    local-env
                    global-env
                    decl)
                    [(OkTcUnit)
                      (begin
                        (cfg
                          compile-profile
                          (compiler-tc-decl-profile-record decl))
                        (tc-check-decls-with-paths-in-module-env
                          ctx
                          top-env
                          rest
                          rest-paths
                          (tc-summary-add-decl summary decl)
                          module
                          cache
                          local-env
                          global-env))]
                    [(ErrTcUnit message)
                      (ErrCompilerTypecheck
                        (tc-typecheck-diag-with-path decl decl-path message))]))))]))]))

(define (typecheck-compiler-specialized-program-with-paths-checked
  [program : AstProgram]
  [paths : AstDeclPathList]) : ResultCompilerTypecheckChecked
  (match (build-compiler-symbols program)
    [(OkCompilerSymbols symbols)
      (match (build-compiler-registries-with-symbols program symbols)
        [(OkCompilerRegistries registries)
          (match (build-compiler-exports-with program symbols registries)
            [(OkCompilerExports _)
              (let
                [ctx : TcContext (TcContext program symbols registries "")]
                (match (tc-program-source-types-policy-ok ctx program)
                  [(OkTcUnit)
                    (match (tc-build-top-env ctx program)
                      [(OkTcEnv top-env)
                        (match program
                          [(AstProgram decls-box)
                            (let
                              [decls : AstDeclList (box-get decls-box)]
                              (match (tc-check-decls-with-paths
                                ctx
                                top-env
                                decls
                                paths
                                (CompilerTypecheckSummary 0 0 0))
                                [(OkCompilerTypecheck summary)
                                  (OkCompilerTypecheckChecked
                                    summary
                                    ctx
                                    top-env)]
                                [(ErrCompilerTypecheck diag)
                                  (ErrCompilerTypecheckChecked diag)]))])]
                      [(ErrTcEnv message)
                        (ErrCompilerTypecheckChecked (tc-diag-at-start message))])]
                  [(ErrTcUnit message)
                    (ErrCompilerTypecheckChecked (tc-diag-at-start message))]))]
            [(ErrCompilerExports message)
              (ErrCompilerTypecheckChecked (tc-diag-at-start message))])]
        [(ErrCompilerRegistries message)
          (ErrCompilerTypecheckChecked (tc-diag-at-start message))])]
    [(ErrCompilerSymbols message)
      (ErrCompilerTypecheckChecked (tc-diag-at-start message))]))

(define (typecheck-compiler-specialized-program-with-paths
  [program : AstProgram]
  [paths : AstDeclPathList]) : ResultCompilerTypecheck
  (match (typecheck-compiler-specialized-program-with-paths-checked
    program
    paths)
    [(OkCompilerTypecheckChecked summary _ _) (OkCompilerTypecheck summary)]
    [(ErrCompilerTypecheckChecked diag) (ErrCompilerTypecheck diag)]))