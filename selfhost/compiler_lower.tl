;; compiler_lower.tl - First selfhost compiler AST-to-IR lowering slice (#446).
;;
;; The lowerer accepts the checked scalar subset and builds a deterministic
;; CompilerIrProgram. It also covers scalar match and heap-backed struct/enum
;; construction/projection; closure, array, and enum-match lowering remain
;; explicit future work.
(import "compiler_typecheck.tl")

(import "compiler_diagnostic.tl")

(import "compiler_ir_types.tl")

(import "compiler_clone.tl")

(import "compiler_ctfe.tl")

(import "stdlib/hashmap.tl")

(defenum LowerNameEnv
  (LowerNameNil)
  (LowerNameBind String String LowerNameEnv))

(defstruct LowerNameCache
  (ids StringI64Map)
  (values (Array String)))

(defenum LowerStringSet
  (LowerStringNil)
  (LowerStringCons String LowerStringSet))

(defenum LowerReachState
  (LowerReachState StringI64Map LowerStringSet))

(defenum LowerMaybeFunctionBody
  (LowerNoFunctionBody)
  (LowerSomeFunctionBody AstExpr))

(defstruct LowerFunctionBodyIndex
  (ids StringI64Map)
  (bodies (Array LowerMaybeFunctionBody))
  (next i64))

(defenum LowerPrunedProgram
  (LowerPrunedProgram AstProgram AstDeclPathList))

(defenum CompilerLowerMode
  (CompilerLowerScalar)
  (CompilerLowerAvx2)
  (CompilerLowerAvx512)
  (CompilerLowerInlineAggregates))

(defenum LowerState
  (LowerState
    i64
    i64
    i64
    String
    CompilerIrInstrList
    CompilerIrBlockList
    CompilerIrFunctionList
    String
    CompilerSourceSpans
    LowerNameCache
    CompilerLowerMode))

(defenum LowerMaybeArrayVar
  (LowerNoArrayVar)
  (LowerSomeArrayVar i64 AstType))

(defenum LowerMaybeVectorMap
  (LowerNoVectorMap)
  (LowerSomeVectorMap i64 i64 i64 CompilerIrBinOp AstType i64))

(defenum LowerMaybeVectorReduce
  (LowerNoVectorReduce)
  (LowerSomeVectorReduce i64 CompilerIrVectorReduceOp AstType i64))

(defenum LowerCapture
  (LowerCapture String i64 AstType i64))

(defenum LowerCaptureList
  (LowerCaptureNil)
  (LowerCaptureCons LowerCapture LowerCaptureList))

(defenum LowerCapturePlan
  (LowerCapturePlan LowerCaptureList i64))

(defenum ResultLowerCapturePlan
  (OkLowerCapturePlan LowerCapturePlan)
  (ErrLowerCapturePlan CompilerDiagnostic))

(defenum LowerAlloc
  (LowerAlloc LowerState i64))

(defenum LowerInlineStorage
  (LowerInlineStorage LowerState i64))

(defenum LowerLabel
  (LowerLabel LowerState String))

(defenum LowerLambdaName
  (LowerLambdaName LowerState String))

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
  (OkLowerFunction CompilerIrFunctionList CompilerSourceSpans)
  (ErrLowerFunction CompilerDiagnostic))

;; `lower-decls` also threads the `CompilerSourceSpans` provenance side table
;;
;; (#605) so each lowered function's source span is recorded alongside the IR.
(defenum ResultLowerDecls
  (OkLowerDecls
    CompilerIrGlobalList
    CompilerIrFunctionList
    CompilerIrExternList
    CompilerSourceSpans)
  (ErrLowerDecls CompilerDiagnostic))

;; A successful lowering returns the IR `CompilerIrProgram` plus a
;;
;; `CompilerSourceSpans` side table (#605) mapping each lowered function's name
;;
;; to the `AstSourceSpan` of its source body, so backend diagnostics can report a
;;
;; real source location. The provenance table is kept outside the IR so the
;;
;; optimizer and liveness data model stay unchanged.
(defenum ResultCompilerLower
  (OkCompilerLower CompilerIrProgram CompilerSourceSpans)
  (ErrCompilerLower CompilerDiagnostic))

(defenum LowerFieldInfo
  (LowerFieldInfo i64 AstType))

(defenum ResultLowerFieldInfo
  (OkLowerFieldInfo LowerFieldInfo)
  (ErrLowerFieldInfo CompilerDiagnostic))

(defenum LowerStringFields
  (LowerStringFields LowerState CompilerIrValue CompilerIrValue))

(defenum LowerCleanup
  (LowerCleanup String String))

(defenum LowerCleanupList
  (LowerCleanupNil)
  (LowerCleanupCons LowerCleanup LowerCleanupList))

(defenum LowerResourceBindings
  (LowerResourceBindings LowerState SymI64Env TcTypeEnv LowerCleanupList))

(defenum ResultLowerResourceBindings
  (OkLowerResourceBindings LowerResourceBindings)
  (ErrLowerResourceBindings CompilerDiagnostic))

(define (lower-diagnostic [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start "" message))

(define (lower-diagnostic-at-expr [expr : AstExpr] [message : String]) : CompilerDiagnostic
  (match expr
    [(AstExprSpanned _ span)
      (compiler-diagnostic-from-ast-span "" span message)]
    [_ (lower-diagnostic message)]))

;; Best-available source span for an expression: the outermost `AstExprSpanned`
;;
;; wrapper the parser attached (#605). Used to populate the lowering provenance
;;
;; side table from a function's body. Returns `CompilerNoSourceSpan` for an
;;
;; unspanned expression (synthesized IR has no source location).
(define (lower-ast-expr-span [expr : AstExpr]) : CompilerMaybeSourceSpan
  (match expr
    [(AstExprSpanned _ span) (CompilerSomeSourceSpan span)]
    [_ (CompilerNoSourceSpan)]))

(define (lower-diagnostic-with-path [diag : CompilerDiagnostic] [path : String]) : CompilerDiagnostic
  (compiler-diagnostic-with-path diag path))

(define (lower-reference-support-message) : String
  "lower: reference-typed programs require borrow/reference lowering support (#803/#806/#804)")

(define (lower-instr-list-reverse-onto
  [instrs : CompilerIrInstrList]
  [acc : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) acc]
    [(IrInstrCons head rest)
      (lower-instr-list-reverse-onto rest (IrInstrCons head acc))]))

(define (lower-instr-list-reverse [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (lower-instr-list-reverse-onto instrs IrInstrNil))

(define (lower-block-list-reverse-onto
  [blocks : CompilerIrBlockList]
  [acc : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) acc]
    [(IrBlockCons head rest)
      (lower-block-list-reverse-onto rest (IrBlockCons head acc))]))

(define (lower-block-list-reverse [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (lower-block-list-reverse-onto blocks IrBlockNil))

(define (lower-global-list-reverse-onto
  [globals : CompilerIrGlobalList]
  [acc : CompilerIrGlobalList]) : CompilerIrGlobalList
  (match globals
    [(IrGlobalNil) acc]
    [(IrGlobalCons head rest)
      (lower-global-list-reverse-onto rest (IrGlobalCons head acc))]))

(define (lower-global-list-reverse [globals : CompilerIrGlobalList]) : CompilerIrGlobalList
  (lower-global-list-reverse-onto globals IrGlobalNil))

(define (lower-function-list-reverse-onto
  [functions : CompilerIrFunctionList]
  [acc : CompilerIrFunctionList]) : CompilerIrFunctionList
  (match functions
    [(IrFunctionNil) acc]
    [(IrFunctionCons head rest)
      (lower-function-list-reverse-onto rest (IrFunctionCons head acc))]))

(define (lower-function-list-reverse [functions : CompilerIrFunctionList]) : CompilerIrFunctionList
  (lower-function-list-reverse-onto functions IrFunctionNil))

(define (lower-function-list-append
  [left : CompilerIrFunctionList]
  [right : CompilerIrFunctionList]) : CompilerIrFunctionList
  (match left
    [(IrFunctionNil) right]
    [(IrFunctionCons head rest)
      (IrFunctionCons head (lower-function-list-append rest right))]))

(define (lower-extern-list-reverse-onto
  [externs : CompilerIrExternList]
  [acc : CompilerIrExternList]) : CompilerIrExternList
  (match externs
    [(IrExternNil) acc]
    [(IrExternCons head rest)
      (lower-extern-list-reverse-onto rest (IrExternCons head acc))]))

(define (lower-extern-list-reverse [externs : CompilerIrExternList]) : CompilerIrExternList
  (lower-extern-list-reverse-onto externs IrExternNil))

(define (lower-name-env-lookup [names : LowerNameEnv] [source-name : String]) : TcMaybeString
  (match names
    [(LowerNameNil) (TcNoString)]
    [(LowerNameBind source logical rest)
      (if (string-eq source source-name)
        (TcSomeString logical)
        (lower-name-env-lookup rest source-name))]))

(define (lower-name-env-resolve [names : LowerNameEnv] [source-name : String]) : String
  (match (lower-name-env-lookup names source-name)
    [(TcSomeString logical) logical]
    [(TcNoString) source-name]))

(define (lower-name-env-count [names : LowerNameEnv]) : i64
  (match names
    [(LowerNameNil) 0]
    [(LowerNameBind _ _ rest) (+ 1 (lower-name-env-count rest))]))

(define (lower-name-cache-capacity [count : i64]) : i64
  (if (< count 4) 8 (* count 2)))

(define (lower-name-cache-add
  [cache : LowerNameCache]
  [source-name : String]
  [logical-name : String]) : LowerNameCache
  (let
    [ids : StringI64Map (struct-get cache ids)]
    [values : (Array String) (struct-get cache values)]
    (match (string-i64-map-get ids source-name)
      [(StringI64MapFound _) cache]
      [(StringI64MapMissing)
        (let
          [next : i64 (string-i64-map-len ids)]
          (begin
            (array-set! values next logical-name)
            (LowerNameCache
              (string-i64-map-put ids source-name next)
              values)))])))

(define (lower-name-cache-from-env-into
  [names : LowerNameEnv]
  [cache : LowerNameCache]) : LowerNameCache
  (match names
    [(LowerNameNil) cache]
    [(LowerNameBind source logical rest)
      (lower-name-cache-from-env-into
        rest
        (lower-name-cache-add cache source logical))]))

(define (lower-name-cache-from-env [names : LowerNameEnv]) : LowerNameCache
  (let
    [count : i64 (lower-name-env-count names)]
    (lower-name-cache-from-env-into
      names
      (LowerNameCache
        (string-i64-map-with-capacity (lower-name-cache-capacity count))
        (make-array String count)))))

(define (lower-name-cache-resolve
  [cache : LowerNameCache]
  [source-name : String]) : String
  (match (string-i64-map-get (struct-get cache ids) source-name)
    [(StringI64MapFound index) (array-ref (struct-get cache values) index)]
    [(StringI64MapMissing) source-name]))

(define (lower-name-env-add-alias-if-free
  [names : LowerNameEnv]
  [source-name : String]
  [logical-name : String]) : LowerNameEnv
  (match (lower-name-env-lookup names source-name)
    [(TcSomeString _) names]
    [(TcNoString) (LowerNameBind source-name logical-name names)]))

(define (lower-name-env-add-module-binding
  [names : LowerNameEnv]
  [module : String]
  [source-name : String]
  [logical-name : String]) : LowerNameEnv
  (if (string-eq module "")
    (LowerNameBind source-name logical-name names)
    (LowerNameBind
      (compiler-symbol-module-key module source-name)
      logical-name
      names)))

(define (lower-resolve-name [state : LowerState] [source-name : String]) : String
  (lower-name-cache-resolve (lower-state-names state) source-name))

(define (lower-resolve-call-name
  [state : LowerState]
  [env : SymI64Env]
  [source-name : String]) : String
  (match (sym-i64-lookup env source-name)
    [(SomeI64 _) source-name]
    [(NoneI64) (lower-resolve-name state source-name)]))

(define (lower-path-separator? [c : char]) : bool
  (or (= c #/') (= c #\\')))

(define (lower-dirname [path : String]) : String
  (let
    [n : i64 (string-length path)]
    [i : i64 0]
    [last : i64 -1]
    (begin
      (while (< i n)
        (begin
          (if (lower-path-separator? (string-ref path i))
            (set! last i)
            (set! last last))
          (set! i (+ i 1))))
      (if (< last 0)
        ""
        (substring path 0 (+ last 1))))))

(define (lower-string-prefix-at?
  [text : String]
  [prefix : String]
  [start : i64]) : bool
  (let
    [text-len : i64 (string-length text)]
    [prefix-len : i64 (string-length prefix)]
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let
          [i : i64 0]
          [ok : bool true]
          (begin
            (while ok
              (if (< i prefix-len)
                (if (=
                  (cast (string-ref text (+ start i)) : i64)
                  (cast (string-ref prefix i) : i64))
                  (set! i (+ i 1))
                  (set! ok false))
                (set! ok false)))
            (= i prefix-len)))))))

(define (lower-module-id [entry-path : String] [decl-path : String]) : String
  (let
    [base : String (lower-dirname entry-path)]
    [base-len : i64 (string-length base)]
    [decl-len : i64 (string-length decl-path)]
    (if (and (> base-len 0) (lower-string-prefix-at? decl-path base 0))
      (substring decl-path base-len (- decl-len base-len))
      decl-path)))

(define (lower-module-logical-name
  [entry-path : String]
  [decl-path : String]
  [source-name : String]) : String
  (if (and (string-eq decl-path entry-path) (string-eq source-name "main"))
    "main"
    (string-append
      (string-append (lower-module-id entry-path decl-path) "::")
      source-name)))

(define (lower-decl-entry-main?
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [source-name : String]) : bool
  (and
    (and (string-eq decl-path entry-path) (string-eq source-name "main"))
    (or (string-eq module "") (string-eq module "main"))))

(define (lower-decl-logical-name
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [source-name : String]) : String
  (if (lower-decl-entry-main? entry-path decl-path module source-name)
    "main"
    (if (string-eq module "")
      (lower-module-logical-name entry-path decl-path source-name)
      (lower-module-logical-name
        entry-path
        decl-path
        (compiler-symbol-module-key module source-name)))))

(define (lower-current-decl-logical-name
  [names : LowerNameEnv]
  [module : String]
  [source-name : String]) : String
  (let
    [key : String (compiler-symbol-module-key module source-name)]
    [resolved : String
      (lower-name-env-resolve
        names
        (compiler-symbol-module-key module source-name))]
    (if (and
      (and (string-eq module "main") (string-eq source-name "main"))
      (string-eq resolved key))
      "main"
      resolved)))

(define (lower-name-env-add-decl-in-module
  [names : LowerNameEnv]
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [decl : AstDecl]) : LowerNameEnv
  (match decl
    [(AstDeclDef name _ _)
      (lower-name-env-add-module-binding
        names
        module
        name
        (lower-decl-logical-name entry-path decl-path module name))]
    [(AstDeclDefFn name _ _ _)
      (lower-name-env-add-module-binding
        names
        module
        name
        (lower-decl-logical-name entry-path decl-path module name))]
    [(AstDeclExtern name _ _)
      ;; Calls resolve through the local declaration name; backend metadata owns
      ;; the exact external linker symbol.
      (lower-name-env-add-module-binding names module name name)]
    [_ names]))

(define (lower-name-env-add-decl
  [names : LowerNameEnv]
  [entry-path : String]
  [decl-path : String]
  [decl : AstDecl]) : LowerNameEnv
  (lower-name-env-add-decl-in-module names entry-path decl-path "" decl))

(define (lower-name-env-from-decls
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [names : LowerNameEnv]) : LowerNameEnv
  (let
    [base : LowerNameEnv
      (lower-name-env-from-decls-in-module decls paths entry-path names "")]
    (lower-name-env-with-import-aliases decls paths entry-path base true)))

(define (lower-name-env-from-decls-in-module
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [names : LowerNameEnv]
  [module : String]) : LowerNameEnv
  (match decls
    [(AstDeclNil) names]
    [(AstDeclCons decl rest)
      (let
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) entry-path])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest) path-rest]
            [(AstDeclPathNil) AstDeclPathNil])]
        (match decl
          [(AstDeclModule next-module)
            (lower-name-env-from-decls-in-module
              rest
              rest-paths
              entry-path
              names
              next-module)]
          [_
            (lower-name-env-from-decls-in-module
              rest
              rest-paths
              entry-path
              (lower-name-env-add-decl-in-module
                names
                entry-path
                decl-path
                module
                decl)
              module)]))]))

(define (lower-alias-logical-name
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [source-name : String]
  [path-aware : bool]) : String
  (if path-aware
    (lower-decl-logical-name entry-path decl-path module source-name)
    (compiler-symbol-module-key module source-name)))

(define (lower-name-env-add-decl-alias-in-module
  [names : LowerNameEnv]
  [entry-path : String]
  [decl-path : String]
  [alias : String]
  [module : String]
  [decl : AstDecl]
  [path-aware : bool]) : LowerNameEnv
  (match decl
    [(AstDeclDef name _ _)
      (LowerNameBind
        (compiler-symbol-module-key alias name)
        (lower-alias-logical-name entry-path decl-path module name path-aware)
        names)]
    [(AstDeclDefFn name _ _ _)
      (LowerNameBind
        (compiler-symbol-module-key alias name)
        (lower-alias-logical-name entry-path decl-path module name path-aware)
        names)]
    [(AstDeclExtern name _ _)
      (LowerNameBind (compiler-symbol-module-key alias name) name names)]
    [(AstDeclComptimeDecl template)
      (lower-name-env-add-decl-alias-in-module
        names
        entry-path
        decl-path
        alias
        module
        template
        path-aware)]
    [_ names]))

(define (lower-name-env-add-module-aliases
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [names : LowerNameEnv]
  [target-module : String]
  [alias : String]
  [module : String]
  [path-aware : bool]) : LowerNameEnv
  (match decls
    [(AstDeclNil) names]
    [(AstDeclCons decl rest)
      (let
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) entry-path])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest) path-rest]
            [(AstDeclPathNil) AstDeclPathNil])]
        (match decl
          [(AstDeclModule next-module)
            (lower-name-env-add-module-aliases
              rest
              rest-paths
              entry-path
              names
              target-module
              alias
              next-module
              path-aware)]
          [(AstDeclImport _)
            (lower-name-env-add-module-aliases
              rest
              rest-paths
              entry-path
              names
              target-module
              alias
              module
              path-aware)]
          [(AstDeclExport _)
            (lower-name-env-add-module-aliases
              rest
              rest-paths
              entry-path
              names
              target-module
              alias
              module
              path-aware)]
          [(AstDeclTest _ _ _)
            (lower-name-env-add-module-aliases
              rest
              rest-paths
              entry-path
              names
              target-module
              alias
              module
              path-aware)]
          [_
            (let
              [next-names : LowerNameEnv
                (if (string-eq module target-module)
                  (lower-name-env-add-decl-alias-in-module
                    names
                    entry-path
                    decl-path
                    alias
                    module
                    decl
                    path-aware)
                  names)]
              (lower-name-env-add-module-aliases
                rest
                rest-paths
                entry-path
                next-names
                target-module
                alias
                module
                path-aware))]))]))

(define (lower-name-env-from-import-aliases
  [all-decls : AstDeclList]
  [all-paths : AstDeclPathList]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [names : LowerNameEnv]
  [path-aware : bool]) : LowerNameEnv
  (match decls
    [(AstDeclNil) names]
    [(AstDeclCons decl rest)
      (let
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest) path-rest]
            [(AstDeclPathNil) AstDeclPathNil])]
        [next-names : LowerNameEnv
          (match decl
            [(AstDeclImport
                (AstImportSpec
                  _
                  (AstSomeModuleName target-module)
                  (AstSomeImportAlias alias)))
              (lower-name-env-add-module-aliases
                all-decls
                all-paths
                entry-path
                names
                target-module
                alias
                ""
                path-aware)]
            [_ names])]
        (lower-name-env-from-import-aliases
          all-decls
          all-paths
          rest
          rest-paths
          entry-path
          next-names
          path-aware))]))

(define (lower-name-env-with-import-aliases
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [names : LowerNameEnv]
  [path-aware : bool]) : LowerNameEnv
  (lower-name-env-from-import-aliases
    decls
    paths
    decls
    paths
    entry-path
    names
    path-aware))

(define (lower-name-env-add-local-decl
  [names : LowerNameEnv]
  [module : String]
  [decl : AstDecl]) : LowerNameEnv
  (match decl
    [(AstDeclDef name _ _)
      (LowerNameBind
        name
        (lower-current-decl-logical-name names module name)
        names)]
    [(AstDeclDefFn name _ _ _)
      (LowerNameBind
        name
        (lower-current-decl-logical-name names module name)
        names)]
    [(AstDeclExtern name _ _)
      (LowerNameBind
        name
        (lower-current-decl-logical-name names module name)
        names)]
    [_ names]))

(define (lower-module-local-names-list
  [decls : AstDeclList]
  [names : LowerNameEnv]
  [target-module : String]
  [module : String]) : LowerNameEnv
  (match decls
    [(AstDeclNil) names]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclModule next-module)
          (lower-module-local-names-list rest names target-module next-module)]
        [_
          (if (string-eq module target-module)
            (lower-module-local-names-list
              rest
              (lower-name-env-add-local-decl names target-module decl)
              target-module
              module)
            (lower-module-local-names-list rest names target-module module))])]))

(define (lower-module-local-names
  [ctx : TcContext]
  [names : LowerNameEnv]
  [module : String]) : LowerNameEnv
  (if (string-eq module "")
    names
    (match (tc-context-program ctx)
      [(AstProgram decls) (lower-module-local-names-list decls names module "")])))

(define (lower-string-set-contains? [items : LowerStringSet] [name : String]) : bool
  (match items
    [(LowerStringNil) false]
    [(LowerStringCons item rest)
      (if (string-eq item name)
        true
        (lower-string-set-contains? rest name))]))

(define (lower-string-set-insert [items : LowerStringSet] [name : String]) : LowerStringSet
  (if (lower-string-set-contains? items name)
    items
    (LowerStringCons name items)))

(define (lower-function-set-from-decls-in-module
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [module : String]
  [out : StringI64Map]) : StringI64Map
  (match decls
    [(AstDeclNil) out]
    [(AstDeclCons decl rest)
      (let
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) entry-path])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest) path-rest]
            [(AstDeclPathNil) AstDeclPathNil])]
        (match decl
          [(AstDeclModule next-module)
            (lower-function-set-from-decls-in-module
              rest
              rest-paths
              entry-path
              next-module
              out)]
          [(AstDeclDefFn name _ _ _)
            (lower-function-set-from-decls-in-module
              rest
              rest-paths
              entry-path
              module
              (string-i64-map-put
                out
                (lower-decl-logical-name entry-path decl-path module name)
                1))]
          [_
            (lower-function-set-from-decls-in-module
              rest
              rest-paths
              entry-path
              module
              out)]))]))

(define (lower-function-set-from-decls
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]) : StringI64Map
  (lower-function-set-from-decls-in-module
    decls
    paths
    entry-path
    ""
    (string-i64-map-with-capacity 8192)))

(define (lower-reach-add-logical
  [all-functions : StringI64Map]
  [state : LowerReachState]
  [logical-name : String]) : LowerReachState
  (match state
    [(LowerReachState reachable worklist)
      (if (string-i64-map-contains? all-functions logical-name)
        (if (string-i64-map-contains? reachable logical-name)
          state
          (LowerReachState
            (string-i64-map-put reachable logical-name 1)
            (LowerStringCons logical-name worklist)))
        state)]))

(define (lower-reach-add-source
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [source-name : String]) : LowerReachState
  (lower-reach-add-logical
    all-functions
    state
    (lower-name-cache-resolve names source-name)))

(define (lower-reach-expr-list
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [exprs : AstExprList]) : LowerReachState
  (match exprs
    [(AstExprNil) state]
    [(AstExprCons expr rest)
      (lower-reach-expr-list
        all-functions
        names
        (lower-reach-expr all-functions names state expr)
        rest)]))

(define (lower-reach-let-bindings
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [bindings : AstLetBindingList]) : LowerReachState
  (match bindings
    [(AstLetBindingNil) state]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding _ _ value)
          (lower-reach-let-bindings
            all-functions
            names
            (lower-reach-expr all-functions names state value)
            rest)])]))

(define (lower-reach-match-arms
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [arms : AstMatchArmList]) : LowerReachState
  (match arms
    [(AstMatchArmNil) state]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm _ body)
          (lower-reach-match-arms
            all-functions
            names
            (lower-reach-expr all-functions names state body)
            rest)])]))

(define (lower-reach-resource-bindings
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [bindings : AstResourceBindingList]) : LowerReachState
  (match bindings
    [(AstResourceBindingNil) state]
    [(AstResourceBindingCons binding rest)
      (match binding
        [(AstResourceBinding _ acquire cleanup)
          (lower-reach-resource-bindings
            all-functions
            names
            (lower-reach-expr
              all-functions
              names
              (lower-reach-expr all-functions names state acquire)
              cleanup)
            rest)])]))

(define (lower-reach-call-callee
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [callee : AstExpr]) : LowerReachState
  (match (ast-expr-unspan callee)
    [(AstExprVar name) (lower-reach-add-source all-functions names state name)]
    [_ (lower-reach-expr all-functions names state callee)]))

(define (lower-reach-expr
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [expr : AstExpr]) : LowerReachState
  (match expr
    [(AstExprSpanned inner _)
      (lower-reach-expr all-functions names state inner)]
    [(AstExprLiteral _) state]
    [(AstExprVar name) (lower-reach-add-source all-functions names state name)]
    [(AstExprBinary _ lhs rhs)
      (lower-reach-expr
        all-functions
        names
        (lower-reach-expr all-functions names state lhs)
        rhs)]
    [(AstExprUnary _ inner) (lower-reach-expr all-functions names state inner)]
    [(AstExprCall callee args)
      (lower-reach-expr-list
        all-functions
        names
        (lower-reach-call-callee all-functions names state callee)
        args)]
    [(AstExprIf cond then-expr else-expr)
      (lower-reach-expr
        all-functions
        names
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr all-functions names state cond)
          then-expr)
        else-expr)]
    [(AstExprLet bindings body)
      (lower-reach-expr
        all-functions
        names
        (lower-reach-let-bindings all-functions names state bindings)
        body)]
    [(AstExprLambda _ _ body) (lower-reach-expr all-functions names state body)]
    [(AstExprTuple values)
      (lower-reach-expr-list all-functions names state values)]
    [(AstExprTupleRef value _)
      (lower-reach-expr all-functions names state value)]
    [(AstExprArray values)
      (lower-reach-expr-list all-functions names state values)]
    [(AstExprMakeArray _ len) (lower-reach-expr all-functions names state len)]
    [(AstExprArrayRef array index)
      (lower-reach-expr
        all-functions
        names
        (lower-reach-expr all-functions names state array)
        index)]
    [(AstExprArraySet array index value)
      (lower-reach-expr
        all-functions
        names
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr all-functions names state array)
          index)
        value)]
    [(AstExprArrayPush array value)
      (lower-reach-expr
        all-functions
        names
        (lower-reach-expr all-functions names state array)
        value)]
    [(AstExprStringRef text index)
      (lower-reach-expr
        all-functions
        names
        (lower-reach-expr all-functions names state text)
        index)]
    [(AstExprWhile cond body)
      (lower-reach-expr
        all-functions
        names
        (lower-reach-expr all-functions names state cond)
        body)]
    [(AstExprBegin exprs)
      (lower-reach-expr-list all-functions names state exprs)]
    [(AstExprUnsafe exprs)
      (lower-reach-expr-list all-functions names state exprs)]
    [(AstExprSet _ value) (lower-reach-expr all-functions names state value)]
    [(AstExprAnn inner _) (lower-reach-expr all-functions names state inner)]
    [(AstExprCast inner _) (lower-reach-expr all-functions names state inner)]
    [(AstExprBorrow _ inner) (lower-reach-expr all-functions names state inner)]
    [(AstExprMatch value arms)
      (lower-reach-match-arms
        all-functions
        names
        (lower-reach-expr all-functions names state value)
        arms)]
    [(AstExprForeach _ _ source init body)
      (lower-reach-expr
        all-functions
        names
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr all-functions names state source)
          init)
        body)]
    [(AstExprSpmdReduce _ _ _ source init map-expr reduce-expr)
      (lower-reach-expr
        all-functions
        names
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr
            all-functions
            names
            (lower-reach-expr all-functions names state source)
            init)
          map-expr)
        reduce-expr)]
    [(AstExprStructGet value _)
      (lower-reach-expr all-functions names state value)]
    [(AstExprWithRegion _ exprs)
      (lower-reach-expr-list all-functions names state exprs)]
    [(AstExprWithEscape scratch exprs)
      (lower-reach-expr-list
        all-functions
        names
        (lower-reach-expr all-functions names state scratch)
        exprs)]
    [(AstExprWithResource bindings body)
      (lower-reach-expr-list
        all-functions
        names
        (lower-reach-resource-bindings all-functions names state bindings)
        body)]
    [(AstExprBox inner) (lower-reach-expr all-functions names state inner)]
    [(AstExprBoxGet inner) (lower-reach-expr all-functions names state inner)]
    [(AstExprTypeLiteral _) state]
    [(AstExprComptime inner) (lower-reach-expr all-functions names state inner)]
    [(AstExprQuote _) state]
    [(AstExprQuasiquote _) state]
    [(AstExprUnquote inner) (lower-reach-expr all-functions names state inner)]
    [(AstExprUnquoteSplicing inner)
      (lower-reach-expr all-functions names state inner)]
    [(AstExprTry inner) (lower-reach-expr all-functions names state inner)]
    [(AstExprReturn inner) (lower-reach-expr all-functions names state inner)]
    [(AstExprPtrNull _) state]
    [(AstExprPtrNullCheck value)
      (lower-reach-expr all-functions names state value)]
    [(AstExprPtrRead ptr) (lower-reach-expr all-functions names state ptr)]
    [(AstExprPtrWrite ptr value)
      (lower-reach-expr
        all-functions
        names
        (lower-reach-expr all-functions names state ptr)
        value)]
    [(AstExprPtrOffset ptr offset)
      (lower-reach-expr
        all-functions
        names
        (lower-reach-expr all-functions names state ptr)
        offset)]
    [(AstExprPtrCast ptr _) (lower-reach-expr all-functions names state ptr)]
    [(AstExprPtrToInt ptr) (lower-reach-expr all-functions names state ptr)]
    [(AstExprIntToPtr value _)
      (lower-reach-expr all-functions names state value)]))

(define (lower-reach-global-decls
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [decls : AstDeclList]) : LowerReachState
  (match decls
    [(AstDeclNil) state]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclDef _ _ expr)
          (lower-reach-global-decls
            all-functions
            names
            (lower-reach-expr all-functions names state expr)
            rest)]
        [(AstDeclComptimeDecl inner)
          (lower-reach-global-decls
            all-functions
            names
            (match inner
              [(AstDeclDef _ _ expr)
                (lower-reach-expr all-functions names state expr)]
              [_ state])
            rest)]
        [_ (lower-reach-global-decls all-functions names state rest)])]))

(define (lower-function-body-index-empty [count : i64]) : LowerFunctionBodyIndex
  (LowerFunctionBodyIndex
    (string-i64-map-with-capacity 8192)
    (make-array LowerMaybeFunctionBody count)
    0))

(define (lower-function-body-index-add
  [index : LowerFunctionBodyIndex]
  [logical-name : String]
  [body : AstExpr]) : LowerFunctionBodyIndex
  (let
    [ids : StringI64Map (struct-get index ids)]
    [bodies : (Array LowerMaybeFunctionBody) (struct-get index bodies)]
    [next : i64 (struct-get index next)]
    (begin
      (array-set! bodies next (LowerSomeFunctionBody body))
      (LowerFunctionBodyIndex
        (string-i64-map-put ids logical-name next)
        bodies
        (+ next 1)))))

(define (lower-function-body-index-find
  [index : LowerFunctionBodyIndex]
  [target : String]) : LowerMaybeFunctionBody
  (match (string-i64-map-get (struct-get index ids) target)
    [(StringI64MapFound body-index)
      (array-ref (struct-get index bodies) body-index)]
    [(StringI64MapMissing) (LowerNoFunctionBody)]))

(define (lower-function-body-index-from-decls-in-module
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [module : String]
  [index : LowerFunctionBodyIndex]) : LowerFunctionBodyIndex
  (match decls
    [(AstDeclNil) index]
    [(AstDeclCons decl rest)
      (let
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) entry-path])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest) path-rest]
            [(AstDeclPathNil) AstDeclPathNil])]
        (match decl
          [(AstDeclModule next-module)
            (lower-function-body-index-from-decls-in-module
              rest
              rest-paths
              entry-path
              next-module
              index)]
          [(AstDeclDefFn name _ _ body)
            (lower-function-body-index-from-decls-in-module
              rest
              rest-paths
              entry-path
              module
              (lower-function-body-index-add
                index
                (lower-decl-logical-name entry-path decl-path module name)
                body))]
          [_
            (lower-function-body-index-from-decls-in-module
              rest
              rest-paths
              entry-path
              module
              index)]))]))

(define (lower-function-body-index-from-decls
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [count : i64]) : LowerFunctionBodyIndex
  (lower-function-body-index-from-decls-in-module
    decls
    paths
    entry-path
    ""
    (lower-function-body-index-empty count)))

(define (lower-reach-process
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [body-index : LowerFunctionBodyIndex]
  [state : LowerReachState]) : LowerReachState
  (match state
    [(LowerReachState reachable worklist)
      (match worklist
        [(LowerStringNil) state]
        [(LowerStringCons name rest)
          (let
            [popped : LowerReachState (LowerReachState reachable rest)]
            (match (lower-function-body-index-find body-index name)
              [(LowerSomeFunctionBody body)
                (lower-reach-process
                  all-functions
                  names
                  body-index
                  (lower-reach-expr all-functions names popped body))]
              [(LowerNoFunctionBody)
                (lower-reach-process
                  all-functions
                  names
                  body-index
                  popped)]))])]))

(define (lower-filter-reachable-decls-in-module
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [module : String]
  [reachable : StringI64Map]) : AstDeclList
  (match decls
    [(AstDeclNil) AstDeclNil]
    [(AstDeclCons decl rest)
      (let
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) entry-path])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest) path-rest]
            [(AstDeclPathNil) AstDeclPathNil])]
        (match decl
          [(AstDeclModule next-module)
            (AstDeclCons
              decl
              (lower-filter-reachable-decls-in-module
                rest
                rest-paths
                entry-path
                next-module
                reachable))]
          [(AstDeclDefFn name _ _ _)
            (if (or
              (lower-name-has-clone-prefix? name)
              (string-i64-map-contains?
                reachable
                (lower-decl-logical-name entry-path decl-path module name)))
              (AstDeclCons
                decl
                (lower-filter-reachable-decls-in-module
                  rest
                  rest-paths
                  entry-path
                  module
                  reachable))
              (lower-filter-reachable-decls-in-module
                rest
                rest-paths
                entry-path
                module
                reachable))]
          [_
            (AstDeclCons
              decl
              (lower-filter-reachable-decls-in-module
                rest
                rest-paths
                entry-path
                module
                reachable))]))]))

(define (lower-filter-reachable-paths-in-module
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [module : String]
  [reachable : StringI64Map]) : AstDeclPathList
  (match decls
    [(AstDeclNil) AstDeclPathNil]
    [(AstDeclCons decl rest)
      (let
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) entry-path])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest) path-rest]
            [(AstDeclPathNil) AstDeclPathNil])]
        (match decl
          [(AstDeclModule next-module)
            (AstDeclPathCons
              decl-path
              (lower-filter-reachable-paths-in-module
                rest
                rest-paths
                entry-path
                next-module
                reachable))]
          [(AstDeclDefFn name _ _ _)
            (if (string-i64-map-contains?
              reachable
              (lower-decl-logical-name entry-path decl-path module name))
              (AstDeclPathCons
                decl-path
                (lower-filter-reachable-paths-in-module
                  rest
                  rest-paths
                  entry-path
                  module
                  reachable))
              (lower-filter-reachable-paths-in-module
                rest
                rest-paths
                entry-path
                module
                reachable))]
          [_
            (AstDeclPathCons
              decl-path
              (lower-filter-reachable-paths-in-module
                rest
                rest-paths
                entry-path
                module
                reachable))]))]))

;; The synthesized clone$<T> helpers (compiler_clone.tl) are reached only via
;; the `(clone x)` forms, which are not lowered to `clone$<T>` calls until after
;; this pre-lowering prune. So we seed them as reachability roots here; the
;; post-lowering optimizer prune (which sees the lowered calls) removes any that
;; are unused. #1633.
(define (lower-name-has-clone-prefix? [name : String]) : bool
  (if (>= (string-length name) 6)
    (string-eq (substring name 0 6) "clone$")
    false))

(define (lower-reach-add-clone-helpers
  [all-functions : StringI64Map]
  [decls : AstDeclList]
  [state : LowerReachState]) : LowerReachState
  (match decls
    [(AstDeclNil) state]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclDefFn name _ _ _)
          (lower-reach-add-clone-helpers
            all-functions
            rest
            (if (lower-name-has-clone-prefix? name)
              (lower-reach-add-logical all-functions state name)
              state))]
        [_ (lower-reach-add-clone-helpers all-functions rest state)])]))

(define (lower-prune-unreachable-functions
  [entry-path : String]
  [program : AstProgram]
  [paths : AstDeclPathList]
  [names : LowerNameEnv]) : LowerPrunedProgram
  (match program
    [(AstProgram decls)
      (let
        [all-functions : StringI64Map
          (lower-function-set-from-decls decls paths entry-path)]
        [body-index : LowerFunctionBodyIndex
          (lower-function-body-index-from-decls
            decls
            paths
            entry-path
            (string-i64-map-len all-functions))]
        [name-cache : LowerNameCache (lower-name-cache-from-env names)]
        (if (string-i64-map-contains? all-functions "main")
          (match (lower-reach-process
            all-functions
            name-cache
            body-index
            (lower-reach-global-decls
              all-functions
              name-cache
              (lower-reach-add-clone-helpers
                all-functions
                decls
                (lower-reach-add-logical
                  all-functions
                  (LowerReachState
                    (string-i64-map-with-capacity 8192)
                    LowerStringNil)
                  "main"))
              decls))
            [(LowerReachState reachable _)
              (LowerPrunedProgram
                (AstProgram
                  (lower-filter-reachable-decls-in-module
                    decls
                    paths
                    entry-path
                    ""
                    reachable))
                (lower-filter-reachable-paths-in-module
                  decls
                  paths
                  entry-path
                  ""
                  reachable))])
          (LowerPrunedProgram program paths)))]))

(define (lower-state-next-var [state : LowerState]) : i64
  (match state
    [(LowerState next-var _ _ _ _ _ _ _ _ _ _) next-var]))

(define (lower-state-current-label [state : LowerState]) : String
  (match state
    [(LowerState _ _ _ label _ _ _ _ _ _ _) label]))

(define (lower-state-current-function [state : LowerState]) : String
  (match state
    [(LowerState _ _ _ _ _ _ _ function _ _ _) function]))

(define (lower-state-spans [state : LowerState]) : CompilerSourceSpans
  (match state
    [(LowerState _ _ _ _ _ _ _ _ spans _ _) spans]))

(define (lower-state-names [state : LowerState]) : LowerNameCache
  (match state
    [(LowerState _ _ _ _ _ _ _ _ _ names _) names]))

(define (lower-state-functions [state : LowerState]) : CompilerIrFunctionList
  (match state
    [(LowerState _ _ _ _ _ _ functions _ _ _ _) functions]))

(define (lower-state-mode [state : LowerState]) : CompilerLowerMode
  (match state
    [(LowerState _ _ _ _ _ _ _ _ _ _ mode) mode]))

(define (lower-state-alloc-var [state : LowerState]) : LowerAlloc
  (match state
    [(LowerState
        next-var
        next-label
        next-lambda
        current-label
        current-instrs
        blocks
        functions
        function
        spans
        names
        mode)
      (LowerAlloc
        (LowerState
          (+ next-var 1)
          next-label
          next-lambda
          current-label
          current-instrs
          blocks
          functions
          function
          spans
          names
          mode)
        next-var)]))

(define (lower-state-fresh-label [state : LowerState] [prefix : String]) : LowerLabel
  (match state
    [(LowerState
        next-var
        next-label
        next-lambda
        current-label
        current-instrs
        blocks
        functions
        function
        spans
        names
        mode)
      (LowerLabel
        (LowerState
          next-var
          (+ next-label 1)
          next-lambda
          current-label
          current-instrs
          blocks
          functions
          function
          spans
          names
          mode)
        (string-append (string-append prefix ".") (int->string next-label)))]))

(define (lower-state-fresh-lambda-name [state : LowerState]) : LowerLambdaName
  (match state
    [(LowerState
        next-var
        next-label
        next-lambda
        current-label
        current-instrs
        blocks
        functions
        function
        spans
        names
        mode)
      (LowerLambdaName
        (LowerState
          next-var
          next-label
          (+ next-lambda 1)
          current-label
          current-instrs
          blocks
          functions
          function
          spans
          names
          mode)
        (string-append
          (string-append (string-append "__tl_lambda_" function) "_")
          (int->string next-lambda)))]))

(define (lower-state-emit [state : LowerState] [instr : CompilerIrInstr]) : LowerState
  (match state
    [(LowerState
        next-var
        next-label
        next-lambda
        current-label
        current-instrs
        blocks
        functions
        function
        spans
        names
        mode)
      (LowerState
        next-var
        next-label
        next-lambda
        current-label
        (IrInstrCons instr current-instrs)
        blocks
        functions
        function
        spans
        names
        mode)]))

(define (lower-state-record-instr-span
  [state : LowerState]
  [instr : CompilerIrInstr]
  [span : AstSourceSpan]) : LowerState
  (match state
    [(LowerState
        next-var
        next-label
        next-lambda
        current-label
        current-instrs
        blocks
        functions
        function
        spans
        names
        mode)
      (LowerState
        next-var
        next-label
        next-lambda
        current-label
        current-instrs
        blocks
        functions
        function
        (compiler-source-spans-insert-instr spans function instr span)
        names
        mode)]))

(define (lower-state-emit-at-expr
  [state : LowerState]
  [instr : CompilerIrInstr]
  [expr : AstExpr]) : LowerState
  ;; Per-instruction spans are allocated inside per-function scratch arenas and
  ;; are not escaped by `lower-function-escaping`; function-level spans are
  ;; recorded separately after escape.
  (lower-state-emit state instr))

(define (lower-state-finish-block [state : LowerState] [next-label : String]) : LowerState
  (match state
    [(LowerState
        next-var
        next-label-id
        next-lambda
        current-label
        current-instrs
        blocks
        functions
        function
        spans
        names
        mode)
      (let
        [block-instrs : CompilerIrInstrList
          (lower-instr-list-reverse current-instrs)]
        (LowerState
          next-var
          next-label-id
          next-lambda
          next-label
          IrInstrNil
          (IrBlockCons (IrBlock current-label block-instrs) blocks)
          functions
          function
          spans
          names
          mode))]))

(define (lower-state-build-blocks [state : LowerState]) : CompilerIrBlockList
  (match state
    [(LowerState _ _ _ current-label current-instrs blocks _ _ _ _ _)
      (lower-block-list-reverse
        (IrBlockCons
          (IrBlock current-label (lower-instr-list-reverse current-instrs))
          blocks))]))

(define (lower-state-add-functions
  [state : LowerState]
  [new-functions : CompilerIrFunctionList]
  [new-spans : CompilerSourceSpans]) : LowerState
  (match state
    [(LowerState
        next-var
        next-label
        next-lambda
        current-label
        current-instrs
        blocks
        functions
        function
        _
        names
        mode)
      (LowerState
        next-var
        next-label
        next-lambda
        current-label
        current-instrs
        blocks
        (lower-function-list-append new-functions functions)
        function
        new-spans
        names
        mode)]))

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

(define (lower-materialize-at-expr
  [state : LowerState]
  [value : CompilerIrValue]
  [ty : AstType]
  [expr : AstExpr]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc allocated var-id)
      (let
        [instr : CompilerIrInstr (IrInstrMov var-id value ty)]
        (OkLowerExpr
          (LowerExpr
            (lower-state-emit-at-expr allocated instr expr)
            (IrValueVar var-id)
            ty)))]))

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
    [(AstTyExpr) 0]
    [(AstTyExprList) 0]
    [(AstTyFunc _ _) 8]
    [(AstTyTuple _) 8]
    [(AstTyArray _ _) 8]
    [(AstTyDynArray _) 8]
    [(AstTyBox _) 8]
    [(AstTyPtr _) 8]
    [(AstTyMutPtr _) 8]
    [(AstTyRef _ _) 8]
    [(AstTyMutRef _ _) 8]
    [(AstTyRegion _ inner) (lower-type-size ctx inner)]
    [(AstTyEnum _) 8]
    [(AstTyStruct _) 8]
    [(AstTyString) 8]
    [(AstTyStr) 8]
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
    [(AstTyExpr) 1]
    [(AstTyExprList) 1]
    [(AstTyFunc _ _) 8]
    [(AstTyTuple _) 8]
    [(AstTyArray _ _) 8]
    [(AstTyDynArray _) 8]
    [(AstTyBox _) 8]
    [(AstTyPtr _) 8]
    [(AstTyMutPtr _) 8]
    [(AstTyRef _ _) 8]
    [(AstTyMutRef _ _) 8]
    [(AstTyRegion _ inner) (lower-type-align ctx inner)]
    [(AstTyEnum _) 8]
    [(AstTyStruct _) 8]
    [(AstTyString) 8]
    [(AstTyStr) 8]
    [(AstTyVar _) 8]))

(define (lower-type-list-extent
  [ctx : TcContext]
  [types : AstTypeList]
  [cursor : i64]) : i64
  (match types
    [(AstTypeNil) cursor]
    [(AstTypeCons ty rest)
      (let
        [resolved : AstType (tc-resolve-type ctx ty)]
        [offset : i64 (lower-align-up cursor (lower-type-align ctx resolved))]
        (lower-type-list-extent
          ctx
          rest
          (+ offset (lower-type-size ctx resolved))))]))

(define (lower-type-list-storage-size [ctx : TcContext] [types : AstTypeList]) : i64
  (let
    [extent : i64 (lower-type-list-extent ctx types 0)]
    (lower-align-up
      (if (= extent 0)
        1
        extent)
      8)))

(define (lower-variant-fields-storage-size
  [ctx : TcContext]
  [fields : AstTypeList]) : i64
  (lower-align-up (lower-type-list-extent ctx fields 8) 8))

(define (lower-variant-storage-size [ctx : TcContext] [variant : AstVariantDef]) : i64
  (match variant
    [(AstVariantDef _ fields) (lower-variant-fields-storage-size ctx fields)]))

(define (lower-nullary-variant-object-name
  [enum-name : String]
  [variant-name : String]) : String
  (string-append
    "__enum_obj_"
    (string-append enum-name (string-append "_" variant-name))))

(define (lower-nullary-variant-globals
  [enum-name : String]
  [variants : AstVariantDefList]
  [tag : i64]
  [globals : CompilerIrGlobalList]) : CompilerIrGlobalList
  (match variants
    [(AstVariantDefNil) globals]
    [(AstVariantDefCons variant rest)
      (match variant
        [(AstVariantDef variant-name fields)
          (let
            [next : CompilerIrGlobalList
              (match fields
                [(AstTypeNil)
                  (let
                    [object-name : String
                      (lower-nullary-variant-object-name enum-name variant-name)]
                    (IrGlobalCons
                      (IrGlobal object-name (AstTyI64) (IrValueI64 tag))
                      globals))]
                [_ globals])]
            (lower-nullary-variant-globals enum-name rest (+ tag 1) next))])]))

(define (lower-enum-variants-storage-size
  [ctx : TcContext]
  [variants : AstVariantDefList]
  [max-size : i64]) : i64
  (match variants
    [(AstVariantDefNil) max-size]
    [(AstVariantDefCons variant rest)
      (let
        [size : i64 (lower-variant-storage-size ctx variant)]
        (lower-enum-variants-storage-size
          ctx
          rest
          (if (> size max-size)
            size
            max-size)))]))

(define (lower-enum-storage-size [ctx : TcContext] [enum-name : String]) : i64
  (match ctx
    [(TcContext program _ _ _)
      (match (tc-program-enum-variants program enum-name)
        [(OkAstVariantDefList variants)
          (lower-enum-variants-storage-size ctx variants 8)]
        [(ErrAstVariantDefList _) 8])]))

(define (lower-struct-fields [ctx : TcContext] [struct-name : String]) : ResultAstFieldDefList
  (match ctx
    [(TcContext program symbols _ _)
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
                  [(AstDeclDefStruct _ _ _ fields) (OkAstFieldDefList fields)]
                  [_
                    (ErrAstFieldDefList
                      "lower: struct symbol owner is not a struct")])]
              [(ErrAstDecl message) (ErrAstFieldDefList message)])
            (ErrAstFieldDefList
              (string-append "lower: unknown struct " struct-name)))]
        [(NoneI64)
          (ErrAstFieldDefList
            (string-append "lower: unknown struct " struct-name))])]))

(define (lower-struct-repr-c? [ctx : TcContext] [struct-name : String]) : bool
  (match (tc-struct-decl ctx struct-name)
    [(OkTcStructDecl decl)
      (match decl
        [(TcStructDecl repr _) (ast-struct-repr-c? repr)])]
    [(ErrTcStructDecl _) false]))

(define (lower-repr-c-inline-field? [ctx : TcContext] [field-ty : AstType]) : bool
  (match (tc-resolve-type ctx field-ty)
    [(AstTyStruct nested) (lower-struct-repr-c? ctx nested)]
    [_ false]))

(define (lower-repr-c-field-size [ctx : TcContext] [field-ty : AstType]) : i64
  (match (tc-resolve-type ctx field-ty)
    [(AstTyStruct nested)
      (match (tc-repr-c-struct-layout ctx nested)
        [(OkTcReprCLayout layout) (tc-repr-c-layout-size layout)]
        [(ErrTcReprCLayout _) 8])]
    [_ (lower-type-size ctx field-ty)]))

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

(define (lower-inline-storage-slot-count [size : i64]) : i64
  (if (<= size 8)
    1
    (/ (+ size 7) 8)))

(define (lower-reserve-inline-slot-vars
  [state : LowerState]
  [slots : i64]
  [ty : AstType]) : LowerInlineStorage
  (match (lower-state-alloc-var state)
    [(LowerAlloc allocated var-id)
      (let
        [next-state : LowerState
          (lower-state-emit allocated (IrInstrAlloc var-id ty))]
        (if (<= slots 1)
          (LowerInlineStorage next-state var-id)
          (lower-reserve-inline-slot-vars next-state (- slots 1) ty)))]))

(define (lower-reserve-inline-storage
  [state : LowerState]
  [size : i64]
  [ty : AstType]) : LowerExpr
  (match (lower-reserve-inline-slot-vars
    state
    (lower-inline-storage-slot-count size)
    ty)
    [(LowerInlineStorage storage-state storage-var)
      (match (lower-state-alloc-var storage-state)
        [(LowerAlloc addr-alloc addr-var)
          (LowerExpr
            (lower-state-emit addr-alloc (IrInstrAddrOf addr-var storage-var))
            (IrValueVar addr-var)
            ty)])]))

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

(define (lower-copy-chunk-size [remaining : i64]) : i64
  (cond [(>= remaining 8) 8] [(>= remaining 4) 4] [(>= remaining 2) 2] [else 1]))

(define (lower-copy-chunk-type [chunk : i64]) : AstType
  (cond
    [(= chunk 8) (AstTyU64)]
    [(= chunk 4) (AstTyU32)]
    [(= chunk 2) (AstTyU16)]
    [else (AstTyU8)]))

(define (lower-copy-bytes
  [state : LowerState]
  [dst : CompilerIrValue]
  [dst-offset : i64]
  [src : CompilerIrValue]
  [src-offset : i64]
  [size : i64]) : LowerState
  (if (<= size 0)
    state
    (let
      [chunk : i64 (lower-copy-chunk-size size)]
      [chunk-ty : AstType (lower-copy-chunk-type chunk)]
      (match (lower-load-at-offset state src src-offset chunk-ty)
        [(LowerExpr loaded value _)
          (lower-copy-bytes
            (lower-store-at-offset loaded dst dst-offset value chunk-ty)
            dst
            (+ dst-offset chunk)
            src
            (+ src-offset chunk)
            (- size chunk))]))))

(define (lower-raw-pointer-ir-type [ty : AstType]) : AstType
  (match (tc-type-strip-region ty)
    [(AstTyPtr _) (AstTyU64)]
    [(AstTyMutPtr _) (AstTyU64)]
    [_ ty]))

(define (lower-cast-value
  [state : LowerState]
  [value : CompilerIrValue]
  [from-ty : AstType]
  [to-ty : AstType]) : LowerExpr
  (let
    [ir-from-ty : AstType (lower-raw-pointer-ir-type from-ty)]
    [ir-to-ty : AstType (lower-raw-pointer-ir-type to-ty)]
    (if (or (tc-type-eq from-ty to-ty) (tc-type-eq ir-from-ty ir-to-ty))
      (LowerExpr state value to-ty)
      (match (lower-state-alloc-var state)
        [(LowerAlloc allocated var-id)
          (LowerExpr
            (lower-state-emit
              allocated
              (IrInstrCast var-id value ir-from-ty ir-to-ty))
            (IrValueVar var-id)
            to-ty)]))))

(define (lower-coerce-value
  [state : LowerState]
  [value : CompilerIrValue]
  [from-ty : AstType]
  [to-ty : AstType]) : LowerExpr
  (if (or (tc-type-eq from-ty to-ty) (tc-never-type? from-ty))
    (LowerExpr state value to-ty)
    (if (tc-type-compatible? to-ty from-ty)
      (lower-cast-value state value from-ty to-ty)
      (LowerExpr state value to-ty))))

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

(define (lower-str-ref-type? [ctx : TcContext] [ty : AstType]) : bool
  (match (tc-type-strip-region (tc-resolve-type ctx ty))
    [(AstTyRef _ inner)
      (match (tc-type-strip-region (tc-resolve-type ctx inner))
        [(AstTyStr) true]
        [_ false])]
    [_ false]))

(define (lower-string-handle-type? [ctx : TcContext] [ty : AstType]) : bool
  (match (tc-type-strip-region (tc-resolve-type ctx ty))
    [(AstTyString) true]
    [_ (lower-str-ref-type? ctx ty)]))

(define (lower-supported-reference-referent-type?
  [ctx : TcContext]
  [ty : AstType]) : bool
  (match (tc-type-strip-region (tc-resolve-type ctx ty))
    [(AstTyI64) true]
    [(AstTyU64) true]
    [(AstTyF64) true]
    [(AstTyI32) true]
    [(AstTyU32) true]
    [(AstTyF32) true]
    [(AstTyI16) true]
    [(AstTyU16) true]
    [(AstTyI8) true]
    [(AstTyU8) true]
    [(AstTyBool) true]
    [(AstTyChar) true]
    [(AstTyStr) true]
    [_ false]))

(define (lower-supported-reference-type-list?
  [ctx : TcContext]
  [types : AstTypeList]) : bool
  (match types
    [(AstTypeNil) true]
    [(AstTypeCons head rest)
      (and
        (lower-supported-reference-type? ctx head)
        (lower-supported-reference-type-list? ctx rest))]))

(define (lower-supported-reference-type? [ctx : TcContext] [ty : AstType]) : bool
  (let
    [resolved : AstType (tc-type-strip-region (tc-resolve-type ctx ty))]
    (if (not (tc-type-contains-reference? resolved))
      true
      (match resolved
        [(AstTyRef _ inner)
          (lower-supported-reference-referent-type? ctx inner)]
        [(AstTyMutRef _ _) false]
        [(AstTyTuple elems) (lower-supported-reference-type-list? ctx elems)]
        [(AstTyArray elem _) (lower-supported-reference-type? ctx elem)]
        [(AstTyRegion _ inner) (lower-supported-reference-type? ctx inner)]
        [_ false]))))

(define (lower-borrowed-str-expr
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [inner : AstExpr]
  [origin : AstExpr]
  [expr-ty : AstType]) : ResultLowerExpr
  (if (lower-str-ref-type? ctx expr-ty)
    (match (lower-expr ctx state env type-env inner)
      [(OkLowerExpr lowered)
        (match lowered
          [(LowerExpr inner-state value _)
            (OkLowerExpr (LowerExpr inner-state value expr-ty))])]
      [(ErrLowerExpr message) (ErrLowerExpr message)])
    (ErrLowerExpr
      (lower-diagnostic-at-expr origin (lower-reference-support-message)))))

(define (lower-borrow-copy-to-storage
  [ctx : TcContext]
  [state : LowerState]
  [value : CompilerIrValue]
  [referent-ty : AstType]
  [result-ty : AstType]) : LowerExpr
  (let
    [resolved : AstType
      (tc-type-without-regions (tc-resolve-type ctx referent-ty))]
    [size : i64 (lower-type-size ctx resolved)]
    (match (lower-reserve-heap-storage
      state
      (if (= size 0)
        1
        size)
      result-ty)
      [(LowerExpr base-state base _)
        (LowerExpr
          (if (> size 0)
            (lower-store-at-offset base-state base 0 value resolved)
            base-state)
          base
          result-ty)])))

(define (lower-borrow-var-address
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [origin : AstExpr]
  [result-ty : AstType]) : ResultLowerExpr
  (match (tc-lookup type-env name)
    [(OkTcType place-ty)
      (if (tc-type-contains-reference? place-ty)
        (ErrLowerExpr
          (lower-diagnostic-at-expr origin (lower-reference-support-message)))
        (let
          [referent-ty : AstType (tc-borrow-referent-type place-ty)]
          (match (sym-i64-lookup env name)
            [(SomeI64 id)
              (OkLowerExpr
                (lower-borrow-copy-to-storage
                  ctx
                  state
                  (IrValueVar id)
                  referent-ty
                  result-ty))]
            [(NoneI64)
              (OkLowerExpr
                (LowerExpr
                  state
                  (IrValueGlobalAddr (lower-resolve-name state name))
                  result-ty))])))]
    [(ErrTcType message)
      (ErrLowerExpr (lower-diagnostic-at-expr origin message))]))

(define (lower-borrow-struct-field-address
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [receiver : AstExpr]
  [field : String]
  [origin : AstExpr]
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
                    [(LowerFieldInfo offset _)
                      (match (lower-gep-byte
                        receiver-state
                        receiver-value
                        offset)
                        [(LowerExpr ptr-state ptr _)
                          (OkLowerExpr (LowerExpr ptr-state ptr result-ty))])])]
                [(ErrLowerFieldInfo message) (ErrLowerExpr message)])]
            [_
              (ErrLowerExpr
                (lower-diagnostic-at-expr
                  origin
                  "lower: struct-get borrow requires struct place"))])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-borrow-tuple-field-address
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [tuple-expr : AstExpr]
  [index : i64]
  [origin : AstExpr]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env tuple-expr)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr tuple-state tuple-value tuple-ty)
          (match (tc-resolve-type ctx tuple-ty)
            [(AstTyTuple elem-tys)
              (match (lower-tuple-elem-info ctx elem-tys index 0 0)
                [(OkLowerFieldInfo info)
                  (match info
                    [(LowerFieldInfo offset _)
                      (match (lower-gep-byte tuple-state tuple-value offset)
                        [(LowerExpr ptr-state ptr _)
                          (OkLowerExpr (LowerExpr ptr-state ptr result-ty))])])]
                [(ErrLowerFieldInfo message) (ErrLowerExpr message)])]
            [_
              (ErrLowerExpr
                (lower-diagnostic-at-expr
                  origin
                  "lower: tuple-ref borrow requires tuple place"))])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-borrow-array-element-address
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [arr : AstExpr]
  [index : AstExpr]
  [origin : AstExpr]
  [result-ty : AstType]) : ResultLowerExpr
  (match (tc-expr ctx type-env arr)
    [(OkTcType arr-ty)
      (match (tc-type-strip-region arr-ty)
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
                                (tc-type-without-regions elem-ty))
                                [(LowerExpr addr-state elem-ptr _)
                                  (OkLowerExpr
                                    (LowerExpr addr-state elem-ptr result-ty))])])]
                        [(ErrLowerExpr message) (ErrLowerExpr message)])]
                    [(ErrTcType message)
                      (ErrLowerExpr (lower-diagnostic-at-expr index message))])])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])]
        [(AstTyArray elem-ty elem-count)
          (let
            [fixed-elem-ty : AstType (tc-type-without-regions elem-ty)]
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
                                (match (lower-fixed-array-element-addr
                                  idx-state
                                  arr-value
                                  idx-value
                                  idx-ty
                                  fixed-elem-ty
                                  elem-count)
                                  [(LowerExpr addr-state elem-ptr _)
                                    (OkLowerExpr
                                      (LowerExpr addr-state elem-ptr result-ty))])])]
                          [(ErrLowerExpr message) (ErrLowerExpr message)])]
                      [(ErrTcType message)
                        (ErrLowerExpr (lower-diagnostic-at-expr index message))])])]
              [(ErrLowerExpr message) (ErrLowerExpr message)]))]
        [_
          (ErrLowerExpr
            (lower-diagnostic-at-expr
              origin
              "lower: array-ref borrow requires array place"))])]
    [(ErrTcType message) (ErrLowerExpr (lower-diagnostic-at-expr arr message))]))

(define (lower-borrow-place-address
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [place : AstExpr]
  [origin : AstExpr]
  [result-ty : AstType]) : ResultLowerExpr
  (match (ast-expr-unspan place)
    [(AstExprVar name)
      (lower-borrow-var-address ctx state env type-env name origin result-ty)]
    [(AstExprStructGet receiver field)
      (lower-borrow-struct-field-address
        ctx
        state
        env
        type-env
        receiver
        field
        origin
        result-ty)]
    [(AstExprTupleRef tuple-expr index)
      (lower-borrow-tuple-field-address
        ctx
        state
        env
        type-env
        tuple-expr
        index
        origin
        result-ty)]
    [(AstExprArrayRef arr index)
      (lower-borrow-array-element-address
        ctx
        state
        env
        type-env
        arr
        index
        origin
        result-ty)]
    [_
      (ErrLowerExpr
        (lower-diagnostic-at-expr
          origin
          "lower: borrow requires a local, parameter, or aggregate place"))]))

(define (lower-borrow-expr
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [inner : AstExpr]
  [origin : AstExpr]
  [expr-ty : AstType]) : ResultLowerExpr
  (if (lower-str-ref-type? ctx expr-ty)
    (lower-borrowed-str-expr ctx state env type-env inner origin expr-ty)
    (match (tc-type-strip-region (tc-resolve-type ctx expr-ty))
      [(AstTyRef _ referent-ty)
        (if (lower-supported-reference-referent-type? ctx referent-ty)
          (lower-borrow-place-address
            ctx
            state
            env
            type-env
            inner
            origin
            expr-ty)
          (ErrLowerExpr
            (lower-diagnostic-at-expr origin (lower-reference-support-message))))]
      [_
        (ErrLowerExpr
          (lower-diagnostic-at-expr origin (lower-reference-support-message)))])))

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
          (let
            [resolved : AstType (tc-resolve-type ctx ty)]
            [offset : i64
              (lower-align-up cursor (lower-type-align ctx resolved))]
            (lower-store-values
              ctx
              (lower-store-at-offset state base offset value resolved)
              base
              rest-values
              rest-types
              (+ offset (lower-type-size ctx resolved))))]
        [(AstTypeNil)
          (ErrLowerState (lower-diagnostic "lower: constructor arity mismatch"))])]))

(define (lower-store-repr-c-values
  [ctx : TcContext]
  [state : LowerState]
  [base : CompilerIrValue]
  [values : CompilerIrValueList]
  [fields : TcReprCFieldLayoutList]) : ResultLowerState
  (match values
    [(IrValueNil)
      (match fields
        [(TcReprCFieldLayoutNil) (OkLowerState state)]
        [_
          (ErrLowerState (lower-diagnostic "lower: constructor arity mismatch"))])]
    [(IrValueCons value rest-values)
      (match fields
        [(TcReprCFieldLayoutCons field rest-fields)
          (match field
            [(TcReprCFieldLayout _ field-ty offset)
              (let
                [stored-state : LowerState
                  (if (lower-repr-c-inline-field? ctx field-ty)
                    (lower-copy-bytes
                      state
                      base
                      offset
                      value
                      0
                      (lower-repr-c-field-size ctx field-ty))
                    (lower-store-at-offset state base offset value field-ty))]
                (lower-store-repr-c-values
                  ctx
                  stored-state
                  base
                  rest-values
                  rest-fields))])]
        [(TcReprCFieldLayoutNil)
          (ErrLowerState (lower-diagnostic "lower: constructor arity mismatch"))])]))

(define (lower-store-inline-struct-values
  [ctx : TcContext]
  [state : LowerState]
  [base : CompilerIrValue]
  [values : CompilerIrValueList]
  [fields : AstFieldDefList]
  [layout : TcInlineAggregateLayout]) : ResultLowerState
  (match values
    [(IrValueNil)
      (match fields
        [(AstFieldDefNil) (OkLowerState state)]
        [_
          (ErrLowerState (lower-diagnostic "lower: constructor arity mismatch"))])]
    [(IrValueCons value rest-values)
      (match fields
        [(AstFieldDefCons field rest-fields)
          (match field
            [(AstFieldDef name ty _)
              (let
                [resolved : AstType (tc-resolve-type ctx ty)]
                [offset : i64
                  (tc-inline-aggregate-layout-field-offset layout name)]
                (if (< offset 0)
                  (ErrLowerState
                    (lower-diagnostic
                      (string-append
                        "lower: inline struct layout missing field "
                        name)))
                  (match (tc-inline-aggregate-type-layout ctx resolved)
                    [(OkTcLayoutInfo info)
                      (let
                        [stored-state : LowerState
                          (if (<= (tc-layout-info-size info) 0)
                            state
                            (lower-store-at-offset
                              state
                              base
                              offset
                              value
                              resolved))]
                        (lower-store-inline-struct-values
                          ctx
                          stored-state
                          base
                          rest-values
                          rest-fields
                          layout))]
                    [(ErrTcLayoutInfo message)
                      (ErrLowerState (lower-diagnostic message))])))])]
        [(AstFieldDefNil)
          (ErrLowerState (lower-diagnostic "lower: constructor arity mismatch"))])]))

(define (lower-store-inline-payload-values
  [ctx : TcContext]
  [state : LowerState]
  [base : CompilerIrValue]
  [values : CompilerIrValueList]
  [types : AstTypeList]
  [layout : TcInlineAggregateLayout]
  [variant-name : String]
  [index : i64]) : ResultLowerState
  (match values
    [(IrValueNil)
      (match types
        [(AstTypeNil) (OkLowerState state)]
        [_
          (ErrLowerState (lower-diagnostic "lower: constructor arity mismatch"))])]
    [(IrValueCons value rest-values)
      (match types
        [(AstTypeCons ty rest-types)
          (let
            [resolved : AstType (tc-resolve-type ctx ty)]
            [offset : i64
              (tc-inline-aggregate-layout-variant-payload-offset
                layout
                variant-name
                index)]
            (if (< offset 0)
              (ErrLowerState
                (lower-diagnostic
                  (string-append
                    "lower: inline enum layout missing payload for "
                    variant-name)))
              (match (tc-inline-aggregate-type-layout ctx resolved)
                [(OkTcLayoutInfo info)
                  (lower-store-inline-payload-values
                    ctx
                    (if (<= (tc-layout-info-size info) 0)
                      state
                      (lower-store-at-offset state base offset value resolved))
                    base
                    rest-values
                    rest-types
                    layout
                    variant-name
                    (+ index 1))]
                [(ErrTcLayoutInfo message)
                  (ErrLowerState (lower-diagnostic message))])))]
        [(AstTypeNil)
          (ErrLowerState (lower-diagnostic "lower: constructor arity mismatch"))])]))

(define (lower-literal-payload-supported? [lit : AstLiteral]) : bool
  (match lit
    [(AstLitInt _) true]
    [(AstLitBool _) true]
    [(AstLitChar _) true]
    [_ false]))

(define (lower-enum-type-name-or-empty [ty : AstType]) : String
  (match (tc-type-strip-region ty)
    [(AstTyEnum enum-name) enum-name]
    [_ ""]))

(define (lower-variant-payload-offset
  [ctx : TcContext]
  [mode : CompilerLowerMode]
  [enum-name : String]
  [variant-name : String]
  [index : i64]
  [cursor : i64]
  [resolved : AstType]) : i64
  (if (and (lower-mode-inline-aggregates? mode) (> (string-length enum-name) 0))
    (match (tc-inline-aggregate-layout-for ctx enum-name)
      [(OkTcInlineAggregateLayout layout)
        (tc-inline-aggregate-layout-variant-payload-offset
          layout
          (tc-qualified-name-base variant-name)
          index)]
      [(ErrTcInlineAggregateLayout _) (- 0 1)])
    (lower-align-up cursor (lower-type-align ctx resolved))))

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
  [mode : CompilerLowerMode]
  [enum-name : String]
  [variant-name : String]
  [index : i64]
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
          (let
            [resolved : AstType (tc-resolve-type ctx ty)]
            [default-offset : i64
              (lower-align-up cursor (lower-type-align ctx resolved))]
            [offset : i64
              (lower-variant-payload-offset
                ctx
                mode
                enum-name
                variant-name
                index
                cursor
                resolved)]
            [next-cursor : i64
              (+ default-offset (lower-type-size ctx resolved))]
            [next-index : i64 (+ index 1)]
            (if (< offset 0)
              (ErrLowerEnv
                (lower-diagnostic
                  (string-append
                    "lower: inline enum layout missing payload for "
                    variant-name)))
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
                    mode
                    enum-name
                    variant-name
                    next-index
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
                            mode
                            enum-name
                            variant-name
                            next-index
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
                                  mode
                                  enum-name
                                  variant-name
                                  next-index
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
                    [(TcContext program _ registries _)
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
                                                mode
                                                (lower-enum-type-name-or-empty
                                                  resolved)
                                                nested-name
                                                0
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
                                                    mode
                                                    enum-name
                                                    variant-name
                                                    next-index
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
        [(AstFieldDef name ty _)
          (let
            [resolved : AstType (tc-resolve-type ctx ty)]
            [offset : i64
              (lower-align-up cursor (lower-type-align ctx resolved))]
            (if (string-eq name field-name)
              (OkLowerFieldInfo (LowerFieldInfo offset resolved))
              (lower-field-info-from-list
                ctx
                rest
                field-name
                (+ offset (lower-type-size ctx resolved)))))])]))

(define (lower-field-info-from-repr-c-list
  [fields : TcReprCFieldLayoutList]
  [field-name : String]) : ResultLowerFieldInfo
  (match fields
    [(TcReprCFieldLayoutNil)
      (ErrLowerFieldInfo
        (lower-diagnostic
          (string-append "lower: unknown struct field " field-name)))]
    [(TcReprCFieldLayoutCons field rest)
      (match field
        [(TcReprCFieldLayout name ty offset)
          (if (string-eq name field-name)
            (OkLowerFieldInfo (LowerFieldInfo offset ty))
            (lower-field-info-from-repr-c-list rest field-name))])]))

(define (lower-struct-field-info
  [ctx : TcContext]
  [struct-name : String]
  [field-name : String]) : ResultLowerFieldInfo
  (if (lower-struct-repr-c? ctx struct-name)
    (match (tc-repr-c-struct-layout ctx struct-name)
      [(OkTcReprCLayout layout)
        (lower-field-info-from-repr-c-list
          (tc-repr-c-layout-fields layout)
          field-name)]
      [(ErrTcReprCLayout message)
        (ErrLowerFieldInfo (lower-diagnostic message))])
    (match (lower-struct-fields ctx struct-name)
      [(OkAstFieldDefList fields)
        (lower-field-info-from-list ctx fields field-name 0)]
      [(ErrAstFieldDefList message)
        (ErrLowerFieldInfo (lower-diagnostic message))])))

(define (lower-struct-field-info-for-mode
  [ctx : TcContext]
  [mode : CompilerLowerMode]
  [struct-name : String]
  [field-name : String]) : ResultLowerFieldInfo
  (if (and
    (lower-mode-inline-aggregates? mode)
    (not (lower-struct-repr-c? ctx struct-name)))
    (match (lower-struct-field-info ctx struct-name field-name)
      [(OkLowerFieldInfo info)
        (match info
          [(LowerFieldInfo _ field-ty)
            (match (tc-inline-aggregate-layout-for ctx struct-name)
              [(OkTcInlineAggregateLayout layout)
                (let
                  [offset : i64
                    (tc-inline-aggregate-layout-field-offset layout field-name)]
                  (if (< offset 0)
                    (ErrLowerFieldInfo
                      (lower-diagnostic
                        (string-append
                          "lower: inline struct layout missing field "
                          field-name)))
                    (OkLowerFieldInfo (LowerFieldInfo offset field-ty))))]
              [(ErrTcInlineAggregateLayout message)
                (ErrLowerFieldInfo (lower-diagnostic message))])])]
      [(ErrLowerFieldInfo message) (ErrLowerFieldInfo message)])
    (lower-struct-field-info ctx struct-name field-name)))

(define (lower-var
  [state : LowerState]
  [env : SymI64Env]
  [name : String]
  [ty : AstType]) : ResultLowerExpr
  (match (sym-i64-lookup env name)
    [(SomeI64 id) (OkLowerExpr (LowerExpr state (IrValueVar id) ty))]
    [(NoneI64)
      (lower-materialize
        state
        (IrValueGlobal (lower-resolve-name state name))
        ty)]))

(define (lower-function-type? [ty : AstType]) : bool
  (match (tc-type-strip-region ty)
    [(AstTyFunc _ _) true]
    [_ false]))

;; The symbol table is keyed by the module key (module/name) and the bare source
;; name alias, never by the `::` logical/mangled name returned by
;; lower-resolve-name. Look up the bare source name so a function used as a value
;; lowers to IrValueFunction (its closure-descriptor address) instead of falling
;; through to IrValueGlobal (which would load the function's code bytes and
;; miscompile an indirect call through it).
(define (lower-symbol-function-value?
  [ctx : TcContext]
  [state : LowerState]
  [name : String]) : bool
  (let
    [symbols : CompilerSymbols (tc-context-symbols ctx)]
    (match (compiler-symbols-lookup-value symbols name)
      [(SomeI64 handle)
        (or
          (=
            (compiler-symbol-handle-kind handle)
            (compiler-symbol-kind-function-define))
          (= (compiler-symbol-handle-kind handle) (compiler-symbol-kind-extern)))]
      [(NoneI64) false])))

(define (lower-function-value-or-var
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [name : String]
  [ty : AstType]) : ResultLowerExpr
  (if (and
    (lower-function-type? ty)
    (lower-symbol-function-value? ctx state name))
    (OkLowerExpr
      (LowerExpr state (IrValueFunction (lower-resolve-name state name)) ty))
    (lower-var state env name ty)))

(define (lower-lambda-captures-env?
  [outer-env : SymI64Env]
  [body : AstExpr]
  [bound : TcStringList]) : bool
  (match outer-env
    [(SymI64Nil) false]
    [(SymI64Bind name _ rest)
      (if (tc-expr-uses-free-name? body name bound)
        true
        (lower-lambda-captures-env? rest body bound))]))

(define (lower-lambda-ret-type
  [ctx : TcContext]
  [type-env : TcTypeEnv]
  [lambda-expr : AstExpr]
  [maybe-ret : AstMaybeType]) : ResultTcType
  (match maybe-ret
    [(AstSomeType ty) (OkTcType (tc-resolve-type ctx ty))]
    [(AstNoType)
      (match (tc-expr ctx type-env lambda-expr)
        [(OkTcType ty)
          (match (tc-type-strip-region ty)
            [(AstTyFunc _ ret) (OkTcType ret)]
            [_ (ErrTcType "lower: lambda did not typecheck as a function")])]
        [(ErrTcType message) (ErrTcType message)])]))

(define (lower-capture-list-contains-name?
  [captures : LowerCaptureList]
  [name : String]) : bool
  (match captures
    [(LowerCaptureNil) false]
    [(LowerCaptureCons capture rest)
      (match capture
        [(LowerCapture capture-name _ _ _)
          (if (string-eq capture-name name)
            true
            (lower-capture-list-contains-name? rest name))])]))

(define (lower-unsupported-capture-message) : String
  "lower: unsupported lambda capture type (#1553)")

(define (lower-capture-support-message [ctx : TcContext] [ty : AstType]) : String
  (match (tc-type-strip-region (tc-resolve-type ctx ty))
    [(AstTyRef _ _) (lower-reference-support-message)]
    [(AstTyMutRef _ _) (lower-reference-support-message)]
    [_ (lower-unsupported-capture-message)]))

(define (lower-supported-capture-type? [ctx : TcContext] [ty : AstType]) : bool
  (match (tc-type-strip-region (tc-resolve-type ctx ty))
    [(AstTyI64) true]
    [(AstTyU64) true]
    [(AstTyF64) true]
    [(AstTyI32) true]
    [(AstTyU32) true]
    [(AstTyF32) true]
    [(AstTyI16) true]
    [(AstTyU16) true]
    [(AstTyI8) true]
    [(AstTyU8) true]
    [(AstTyBool) true]
    [(AstTyChar) true]
    [(AstTyFunc _ _) true]
    [(AstTyTuple _) true]
    [(AstTyArray _ _) true]
    [(AstTyEnum _) true]
    [(AstTyStruct _) true]
    [(AstTyString) true]
    [(AstTyDynArray _) true]
    [_ false]))

(define (lower-capture-env-size [cursor : i64]) : i64
  (lower-align-up
    (if (= cursor 0)
      1
      cursor)
    8))

(define (lower-capture-slot-type [ty : AstType]) : AstType
  (match (tc-type-strip-region ty)
    [(AstTyFunc _ _) (AstTyU64)]
    [(AstTyTuple _) (AstTyU64)]
    [(AstTyArray _ _) (AstTyU64)]
    [(AstTyEnum _) (AstTyU64)]
    [(AstTyStruct _) (AstTyU64)]
    [(AstTyString) (AstTyU64)]
    [(AstTyDynArray _) (AstTyU64)]
    [_ ty]))

(define (lower-fixed-array-storage-size
  [ctx : TcContext]
  [elem-ty : AstType]
  [count : i64]) : i64
  (let
    [elem-size : i64 (lower-type-size ctx elem-ty)]
    [extent : i64 (* count elem-size)]
    (lower-align-up
      (if (= extent 0)
        1
        extent)
      8)))

(define (lower-capture-snapshot-value
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [value : CompilerIrValue]
  [ty : AstType]) : ResultLowerExpr
  (match (tc-resolve-type ctx ty)
    [(AstTyString) (lower-capture-snapshot-string-value state value)]
    [(AstTyDynArray elem-ty)
      (lower-capture-snapshot-dynarray-value
        ctx
        state
        value
        (tc-type-without-regions elem-ty)
        ty)]
    [(AstTyTuple elem-tys)
      (lower-capture-snapshot-tuple-value
        ctx
        state
        env
        type-env
        value
        elem-tys
        ty)]
    [(AstTyArray elem-ty count)
      (lower-capture-snapshot-fixed-array-value
        ctx
        state
        env
        type-env
        value
        (tc-type-without-regions elem-ty)
        count
        ty)]
    [(AstTyStruct name)
      (lower-capture-snapshot-struct-value ctx state env type-env value name ty)]
    [(AstTyEnum name)
      (lower-capture-snapshot-enum-value ctx state env type-env value name ty)]
    [_ (OkLowerExpr (LowerExpr state value ty))]))

(define (lower-capture-snapshot-string-value
  [state : LowerState]
  [value : CompilerIrValue]) : ResultLowerExpr
  (match (lower-string-fields state value)
    [(LowerStringFields fields-state ptr len)
      (lower-substring-call-runtime fields-state ptr (IrValueI64 0) len)]))

(define (lower-capture-snapshot-dynarray-copy
  [state : LowerState]
  [old-buf : CompilerIrValue]
  [new-buf : CompilerIrValue]
  [len : CompilerIrValue]
  [elem-ty : AstType]
  [elem-size : i64]) : LowerState
  (if (= elem-size 0)
    state
    (lower-array-push-copy-loop state old-buf new-buf len elem-ty)))

(define (lower-capture-snapshot-dynarray-finish
  [state : LowerState]
  [old-buf : CompilerIrValue]
  [len : CompilerIrValue]
  [elem-ty : AstType]
  [elem-size : i64]
  [buf-var : i64]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-reserve-heap-storage state 16 result-ty)
    [(LowerExpr arr-state arr-value _)
      (let
        [copied-state : LowerState
          (lower-capture-snapshot-dynarray-copy
            arr-state
            old-buf
            (IrValueVar buf-var)
            len
            elem-ty
            elem-size)]
        (OkLowerExpr
          (LowerExpr
            (lower-store-at-offset
              (lower-store-at-offset
                copied-state
                arr-value
                0
                (IrValueVar buf-var)
                (AstTyU64))
              arr-value
              8
              len
              (AstTyI64))
            arr-value
            result-ty)))]))

(define (lower-capture-snapshot-dynarray-value
  [ctx : TcContext]
  [state : LowerState]
  [value : CompilerIrValue]
  [elem-ty : AstType]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-load-at-offset state value 8 (AstTyI64))
    [(LowerExpr len-state len _)
      (match (lower-load-at-offset len-state value 0 (AstTyU64))
        [(LowerExpr ptr-state old-buf _)
          (let
            [elem-size : i64 (lower-type-size ctx elem-ty)]
            (match (if (= elem-size 0)
              (LowerExpr ptr-state (IrValueI64 1) (AstTyI64))
              (lower-emit-binop
                ptr-state
                IrBinMul
                len
                (IrValueI64 elem-size)
                (AstTyI64)))
              [(LowerExpr byte-state byte-count _)
                (match (lower-state-alloc-var byte-state)
                  [(LowerAlloc buf-alloc buf-var)
                    (lower-capture-snapshot-dynarray-finish
                      (lower-state-emit
                        buf-alloc
                        (IrInstrCall
                          buf-var
                          "tl_alloc"
                          (IrValueCons byte-count IrValueNil)
                          (AstTyU64)))
                      old-buf
                      len
                      elem-ty
                      elem-size
                      buf-var
                      result-ty)])]))])]))

(define (lower-capture-snapshot-type-list
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [src : CompilerIrValue]
  [dst : CompilerIrValue]
  [types : AstTypeList]
  [cursor : i64]) : ResultLowerState
  (match types
    [(AstTypeNil) (OkLowerState state)]
    [(AstTypeCons ty rest)
      (let
        [resolved : AstType (tc-type-without-regions (tc-resolve-type ctx ty))]
        [offset : i64 (lower-align-up cursor (lower-type-align ctx resolved))]
        [size : i64 (lower-type-size ctx resolved)]
        (if (> size 0)
          (match (lower-load-at-offset state src offset resolved)
            [(LowerExpr load-state field-value _)
              (match (lower-capture-snapshot-value
                ctx
                load-state
                env
                type-env
                field-value
                resolved)
                [(OkLowerExpr snap)
                  (match snap
                    [(LowerExpr snap-state snap-value _)
                      (lower-capture-snapshot-type-list
                        ctx
                        (lower-store-at-offset
                          snap-state
                          dst
                          offset
                          snap-value
                          resolved)
                        env
                        type-env
                        src
                        dst
                        rest
                        (+ offset size))])]
                [(ErrLowerExpr message) (ErrLowerState message)])])
          (lower-capture-snapshot-type-list
            ctx
            state
            env
            type-env
            src
            dst
            rest
            (+ offset size))))]))

(define (lower-capture-snapshot-tuple-value
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [value : CompilerIrValue]
  [elem-tys : AstTypeList]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-reserve-heap-storage
    state
    (lower-type-list-storage-size ctx elem-tys)
    result-ty)
    [(LowerExpr dst-state dst _)
      (match (lower-capture-snapshot-type-list
        ctx
        dst-state
        env
        type-env
        value
        dst
        elem-tys
        0)
        [(OkLowerState done-state)
          (OkLowerExpr (LowerExpr done-state dst result-ty))]
        [(ErrLowerState message) (ErrLowerExpr message)])]))

(define (lower-capture-snapshot-fixed-array-elems
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [src : CompilerIrValue]
  [dst : CompilerIrValue]
  [elem-ty : AstType]
  [elem-size : i64]
  [index : i64]
  [count : i64]) : ResultLowerState
  (if (>= index count)
    (OkLowerState state)
    (let
      [offset : i64 (* index elem-size)]
      (if (> elem-size 0)
        (match (lower-load-at-offset state src offset elem-ty)
          [(LowerExpr load-state elem-value _)
            (match (lower-capture-snapshot-value
              ctx
              load-state
              env
              type-env
              elem-value
              elem-ty)
              [(OkLowerExpr snap)
                (match snap
                  [(LowerExpr snap-state snap-value _)
                    (lower-capture-snapshot-fixed-array-elems
                      ctx
                      (lower-store-at-offset
                        snap-state
                        dst
                        offset
                        snap-value
                        elem-ty)
                      env
                      type-env
                      src
                      dst
                      elem-ty
                      elem-size
                      (+ index 1)
                      count)])]
              [(ErrLowerExpr message) (ErrLowerState message)])])
        (lower-capture-snapshot-fixed-array-elems
          ctx
          state
          env
          type-env
          src
          dst
          elem-ty
          elem-size
          (+ index 1)
          count)))))

(define (lower-capture-snapshot-fixed-array-value
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [value : CompilerIrValue]
  [elem-ty : AstType]
  [count : i64]
  [result-ty : AstType]) : ResultLowerExpr
  (let
    [elem-size : i64 (lower-type-size ctx elem-ty)]
    (match (lower-reserve-heap-storage
      state
      (lower-fixed-array-storage-size ctx elem-ty count)
      result-ty)
      [(LowerExpr dst-state dst _)
        (match (lower-capture-snapshot-fixed-array-elems
          ctx
          dst-state
          env
          type-env
          value
          dst
          elem-ty
          elem-size
          0
          count)
          [(OkLowerState done-state)
            (OkLowerExpr (LowerExpr done-state dst result-ty))]
          [(ErrLowerState message) (ErrLowerExpr message)])])))

(define (lower-capture-snapshot-struct-value
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [value : CompilerIrValue]
  [struct-name : String]
  [result-ty : AstType]) : ResultLowerExpr
  (if (lower-struct-repr-c? ctx struct-name)
    (ErrLowerExpr
      (lower-diagnostic
        "lower: repr-c aggregate lambda captures need repr-c snapshot lowering"))
    (match (lower-struct-fields ctx struct-name)
      [(OkAstFieldDefList fields)
        (let
          [field-types : AstTypeList (tc-field-type-list ctx fields)]
          (match (lower-reserve-heap-storage
            state
            (lower-type-list-storage-size ctx field-types)
            result-ty)
            [(LowerExpr dst-state dst _)
              (match (lower-capture-snapshot-type-list
                ctx
                dst-state
                env
                type-env
                value
                dst
                field-types
                0)
                [(OkLowerState done-state)
                  (OkLowerExpr (LowerExpr done-state dst result-ty))]
                [(ErrLowerState message) (ErrLowerExpr message)])]))]
      [(ErrAstFieldDefList message) (ErrLowerExpr (lower-diagnostic message))])))

(define (lower-capture-snapshot-enum-variants
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [src : CompilerIrValue]
  [dst : CompilerIrValue]
  [tag : CompilerIrValue]
  [variants : AstVariantDefList]
  [index : i64]
  [done-label : String]) : ResultLowerState
  (match variants
    [(AstVariantDefNil)
      (OkLowerState
        (lower-state-finish-block
          (lower-state-emit state (IrInstrJump done-label))
          done-label))]
    [(AstVariantDefCons variant rest)
      (match (lower-state-fresh-label state "capture_enum_variant")
        [(LowerLabel variant-label-state variant-label)
          (match (lower-state-fresh-label
            variant-label-state
            "capture_enum_next")
            [(LowerLabel next-label-state next-label)
              (match (lower-state-alloc-var next-label-state)
                [(LowerAlloc cond-state cond-var)
                  (let
                    [branch-state : LowerState
                      (lower-state-finish-block
                        (lower-state-emit
                          (lower-state-emit
                            cond-state
                            (IrInstrBinOp
                              cond-var
                              IrBinEq
                              tag
                              (IrValueI64 index)
                              (AstTyBool)))
                          (IrInstrBranch
                            (IrValueVar cond-var)
                            variant-label
                            next-label))
                        variant-label)]
                    (match variant
                      [(AstVariantDef _ fields)
                        (match (lower-capture-snapshot-type-list
                          ctx
                          branch-state
                          env
                          type-env
                          src
                          dst
                          fields
                          8)
                          [(OkLowerState copied-state)
                            (lower-capture-snapshot-enum-variants
                              ctx
                              (lower-state-finish-block
                                (lower-state-emit
                                  copied-state
                                  (IrInstrJump done-label))
                                next-label)
                              env
                              type-env
                              src
                              dst
                              tag
                              rest
                              (+ index 1)
                              done-label)]
                          [(ErrLowerState message) (ErrLowerState message)])]))])])])]))

(define (lower-capture-snapshot-enum-value
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [value : CompilerIrValue]
  [enum-name : String]
  [result-ty : AstType]) : ResultLowerExpr
  (match ctx
    [(TcContext program _ _ _)
      (match (tc-program-enum-variants program enum-name)
        [(OkAstVariantDefList variants)
          (match (lower-reserve-heap-storage
            state
            (lower-enum-storage-size ctx enum-name)
            result-ty)
            [(LowerExpr dst-state dst _)
              (match (lower-load-at-offset dst-state value 0 (AstTyI64))
                [(LowerExpr tag-state tag _)
                  (match (lower-state-fresh-label tag-state "capture_enum_done")
                    [(LowerLabel done-state done-label)
                      (match (lower-capture-snapshot-enum-variants
                        ctx
                        (lower-store-at-offset done-state dst 0 tag (AstTyI64))
                        env
                        type-env
                        value
                        dst
                        tag
                        variants
                        0
                        done-label)
                        [(OkLowerState final-state)
                          (OkLowerExpr (LowerExpr final-state dst result-ty))]
                        [(ErrLowerState message) (ErrLowerExpr message)])])])])]
        [(ErrAstVariantDefList message)
          (ErrLowerExpr (lower-diagnostic message))])]))

(define (lower-capture-plan-scan
  [ctx : TcContext]
  [outer-env : SymI64Env]
  [type-env : TcTypeEnv]
  [body : AstExpr]
  [bound : TcStringList]
  [cursor : i64]
  [captures : LowerCaptureList]
  [origin : AstExpr]) : ResultLowerCapturePlan
  (match outer-env
    [(SymI64Nil)
      (OkLowerCapturePlan
        (LowerCapturePlan captures (lower-capture-env-size cursor)))]
    [(SymI64Bind name var-id rest)
      (if (or
        (lower-capture-list-contains-name? captures name)
        (not (tc-expr-uses-free-name? body name bound)))
        (lower-capture-plan-scan
          ctx
          rest
          type-env
          body
          bound
          cursor
          captures
          origin)
        (match (tc-lookup type-env name)
          [(ErrTcType message)
            (ErrLowerCapturePlan (lower-diagnostic-at-expr origin message))]
          [(OkTcType found-ty)
            (let
              [capture-ty : AstType
                (tc-type-without-regions (tc-resolve-type ctx found-ty))]
              (if (lower-supported-capture-type? ctx capture-ty)
                (let
                  [slot-ty : AstType (lower-capture-slot-type capture-ty)]
                  [offset : i64
                    (lower-align-up cursor (lower-type-align ctx slot-ty))]
                  (lower-capture-plan-scan
                    ctx
                    rest
                    type-env
                    body
                    bound
                    (+ offset (lower-type-size ctx slot-ty))
                    (LowerCaptureCons
                      (LowerCapture name var-id capture-ty offset)
                      captures)
                    origin))
                (ErrLowerCapturePlan
                  (lower-diagnostic-at-expr
                    origin
                    (lower-capture-support-message ctx capture-ty)))))]))]))

(define (lower-capture-plan
  [ctx : TcContext]
  [outer-env : SymI64Env]
  [type-env : TcTypeEnv]
  [params : AstParamList]
  [body : AstExpr]
  [origin : AstExpr]) : ResultLowerCapturePlan
  (lower-capture-plan-scan
    ctx
    outer-env
    type-env
    body
    (tc-param-bound-names params)
    0
    (LowerCaptureNil)
    origin))

(define (lower-store-captures
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [env-value : CompilerIrValue]
  [captures : LowerCaptureList]) : ResultLowerState
  (match captures
    [(LowerCaptureNil) (OkLowerState state)]
    [(LowerCaptureCons capture rest)
      (match capture
        [(LowerCapture _ var-id capture-ty offset)
          (match (lower-capture-snapshot-value
            ctx
            state
            env
            type-env
            (IrValueVar var-id)
            capture-ty)
            [(OkLowerExpr snap)
              (match snap
                [(LowerExpr snap-state snap-value _)
                  (lower-store-captures
                    ctx
                    (lower-store-at-offset
                      snap-state
                      env-value
                      offset
                      snap-value
                      (lower-capture-slot-type capture-ty))
                    env
                    type-env
                    env-value
                    rest)])]
            [(ErrLowerExpr message) (ErrLowerState message)])])]))

(define (lower-store-capturing-lambda-descriptor
  [state : LowerState]
  [lambda-name : String]
  [env-value : CompilerIrValue]
  [expr-ty : AstType]) : LowerExpr
  (match (lower-reserve-heap-storage state 16 expr-ty)
    [(LowerExpr desc-state desc-value _)
      (LowerExpr
        (lower-store-at-offset
          (lower-store-at-offset
            desc-state
            desc-value
            0
            (IrValueGlobalAddr lambda-name)
            (AstTyU64))
          desc-value
          8
          env-value
          (AstTyU64))
        desc-value
        expr-ty)]))

(define (lower-capturing-lambda-value
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [lambda-name : String]
  [captures : LowerCaptureList]
  [capture-size : i64]
  [expr-ty : AstType]) : ResultLowerExpr
  (match (lower-reserve-heap-storage state capture-size (AstTyU64))
    [(LowerExpr env-state env-value _)
      (match (lower-store-captures
        ctx
        env-state
        env
        type-env
        env-value
        captures)
        [(OkLowerState captured-state)
          (match (lower-store-capturing-lambda-descriptor
            captured-state
            lambda-name
            env-value
            expr-ty)
            [(LowerExpr desc-state desc-value desc-ty)
              (OkLowerExpr (LowerExpr desc-state desc-value desc-ty))])]
        [(ErrLowerState message) (ErrLowerExpr message)])]))

(define (lower-load-captures
  [state : LowerState]
  [env-value : CompilerIrValue]
  [captures : LowerCaptureList]
  [env : SymI64Env]
  [type-env : TcTypeEnv]) : ResultLowerEnv
  (match captures
    [(LowerCaptureNil) (OkLowerEnv state env type-env)]
    [(LowerCaptureCons capture rest)
      (match capture
        [(LowerCapture name _ capture-ty offset)
          (match (lower-load-at-offset
            state
            env-value
            offset
            (lower-capture-slot-type capture-ty))
            [(LowerExpr loaded-state loaded-value _)
              (match loaded-value
                [(IrValueVar loaded-var)
                  (lower-load-captures
                    loaded-state
                    env-value
                    rest
                    (sym-i64-bind env name loaded-var)
                    (tc-bind type-env name capture-ty))]
                [_
                  (ErrLowerEnv
                    (lower-diagnostic
                      "lower: capture load did not materialize a variable"))])])])]))

(define (lower-captured-param-list [ctx : TcContext] [params : AstParamList]) : CompilerIrParamList
  (IrParamCons
    (IrParam "__tl_env" (AstTyU64) 0)
    (lower-param-list ctx params 1)))

(define (lower-function-with-captures
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [logical-name : String]
  [params : AstParamList]
  [ret : AstType]
  [body : AstExpr]
  [captures : LowerCaptureList]
  [spans : CompilerSourceSpans]
  [names : LowerNameCache]
  [mode : CompilerLowerMode]) : ResultLowerFunction
  (if (or
    (lower-param-list-contains-unsupported-reference? ctx params)
    (tc-type-contains-reference? (tc-resolve-type ctx ret)))
    (ErrLowerFunction (lower-diagnostic (lower-reference-support-message)))
    (if (and
      (lower-mode-inline-aggregates? mode)
      (or
        (lower-param-list-contains-inline-aggregate? ctx params)
        (lower-type-contains-inline-aggregate? ctx ret)))
      (ErrLowerFunction (lower-diagnostic (lower-inline-aggregate-abi-message)))
      (let
        [param-count : i64 (+ 1 (lower-param-count params))]
        [function-spans : CompilerSourceSpans
          (lower-record-function-span spans logical-name body)]
        [state : LowerState
          (LowerState
            param-count
            0
            0
            "entry"
            IrInstrNil
            IrBlockNil
            IrFunctionNil
            logical-name
            function-spans
            names
            mode)]
        [ret-ty : AstType (tc-type-without-regions (tc-resolve-type ctx ret))]
        (match (lower-load-captures
          state
          (IrValueVar 0)
          captures
          (sym-i64-empty)
          (tc-bind-return-type top-env ret-ty))
          [(OkLowerEnv captured-state captured-env captured-type-env)
            (let
              [env : SymI64Env (lower-bind-params params 1 captured-env)]
              [type-env : TcTypeEnv
                (tc-bind-params ctx captured-type-env params)]
              (match (lower-tail-expr
                ctx
                captured-state
                env
                type-env
                body
                ret-ty)
                [(OkLowerState final-state)
                  (OkLowerFunction
                    (IrFunctionCons
                      (IrFunction
                        logical-name
                        (lower-captured-param-list ctx params)
                        ret-ty
                        (lower-state-next-var final-state)
                        (lower-state-build-blocks final-state))
                      (lower-state-functions final-state))
                    (lower-state-spans final-state))]
                [(ErrLowerState message) (ErrLowerFunction message)]))]
          [(ErrLowerEnv message) (ErrLowerFunction message)])))))

(define (lower-lambda-noncapturing
  [ctx : TcContext]
  [state : LowerState]
  [type-env : TcTypeEnv]
  [params : AstParamList]
  [maybe-ret : AstMaybeType]
  [body : AstExpr]
  [origin : AstExpr]
  [expr-ty : AstType]) : ResultLowerExpr
  (match (lower-lambda-ret-type ctx type-env origin maybe-ret)
    [(ErrTcType message)
      (ErrLowerExpr (lower-diagnostic-at-expr origin message))]
    [(OkTcType ret-ty)
      (match (lower-state-fresh-lambda-name state)
        [(LowerLambdaName named-state lambda-name)
          (match (lower-function
            ctx
            type-env
            lambda-name
            params
            ret-ty
            body
            (lower-state-spans named-state)
            (lower-state-names named-state)
            (lower-state-mode named-state))
            [(OkLowerFunction lambda-functions lambda-spans)
              (OkLowerExpr
                (LowerExpr
                  (lower-state-add-functions
                    named-state
                    lambda-functions
                    lambda-spans)
                  (IrValueFunction lambda-name)
                  expr-ty))]
            [(ErrLowerFunction message) (ErrLowerExpr message)])])]))

(define (lower-lambda-capturing
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [params : AstParamList]
  [maybe-ret : AstMaybeType]
  [body : AstExpr]
  [origin : AstExpr]
  [expr-ty : AstType]) : ResultLowerExpr
  (match (lower-lambda-ret-type ctx type-env origin maybe-ret)
    [(ErrTcType message)
      (ErrLowerExpr (lower-diagnostic-at-expr origin message))]
    [(OkTcType ret-ty)
      (match (lower-capture-plan ctx env type-env params body origin)
        [(ErrLowerCapturePlan message) (ErrLowerExpr message)]
        [(OkLowerCapturePlan plan)
          (match plan
            [(LowerCapturePlan captures capture-size)
              (match (lower-state-fresh-lambda-name state)
                [(LowerLambdaName named-state lambda-name)
                  (match (lower-function-with-captures
                    ctx
                    type-env
                    lambda-name
                    params
                    ret-ty
                    body
                    captures
                    (lower-state-spans named-state)
                    (lower-state-names named-state)
                    (lower-state-mode named-state))
                    [(OkLowerFunction lambda-functions lambda-spans)
                      (match (lower-capturing-lambda-value
                        ctx
                        (lower-state-add-functions
                          named-state
                          lambda-functions
                          lambda-spans)
                        env
                        type-env
                        lambda-name
                        captures
                        capture-size
                        expr-ty)
                        [(OkLowerExpr lowered)
                          (match lowered
                            [(LowerExpr value-state value value-ty)
                              (OkLowerExpr
                                (LowerExpr value-state value value-ty))])]
                        [(ErrLowerExpr message) (ErrLowerExpr message)])]
                    [(ErrLowerFunction message) (ErrLowerExpr message)])])])])]))

(define (lower-lambda
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [params : AstParamList]
  [maybe-ret : AstMaybeType]
  [body : AstExpr]
  [origin : AstExpr]
  [expr-ty : AstType]) : ResultLowerExpr
  (if (lower-lambda-captures-env? env body (tc-param-bound-names params))
    (lower-lambda-capturing
      ctx
      state
      env
      type-env
      params
      maybe-ret
      body
      origin
      expr-ty)
    (lower-lambda-noncapturing
      ctx
      state
      type-env
      params
      maybe-ret
      body
      origin
      expr-ty)))

(define (lower-return-maybe [value : CompilerIrValue] [ty : AstType]) : CompilerIrMaybeValue
  (match ty
    [(AstTyUnit) IrNoValue]
    [_ (IrSomeValue value)]))

(define (lower-cleanup-marker-name) : String
  " __tl_active_cleanup")

(define (lower-region-reset-marker-name) : String
  " __tl_active_region_reset")

(define (lower-cleanup-hidden-name [var-id : i64]) : String
  (string-append "__tl_cleanup_resource." (int->string var-id)))

(define (lower-region-hidden-name [var-id : i64]) : String
  (string-append "__tl_region_mark." (int->string var-id)))

(define (lower-cleanup-metadata-type
  [hidden-name : String]
  [cleanup-name : String]) : AstType
  (AstTyTuple
    (AstTypeCons
      (AstTyVar hidden-name)
      (AstTypeCons (AstTyVar cleanup-name) AstTypeNil))))

(define (lower-region-reset-metadata-type [hidden-name : String]) : AstType
  (AstTyVar hidden-name))

(define (lower-type-env-push-cleanup
  [type-env : TcTypeEnv]
  [hidden-name : String]
  [cleanup-name : String]) : TcTypeEnv
  (tc-bind
    type-env
    (lower-cleanup-marker-name)
    (lower-cleanup-metadata-type hidden-name cleanup-name)))

(define (lower-type-env-push-region-reset
  [type-env : TcTypeEnv]
  [hidden-name : String]) : TcTypeEnv
  (tc-bind
    type-env
    (lower-region-reset-marker-name)
    (lower-region-reset-metadata-type hidden-name)))

(define (lower-cleanup-name-from-expr [cleanup : AstExpr]) : ResultTcString
  (match (ast-expr-unspan cleanup)
    [(AstExprVar name) (OkTcString name)]
    [_ (ErrTcString "lower: resource cleanup must be a direct function name")]))

(define (lower-emit-cleanup-call
  [state : LowerState]
  [env : SymI64Env]
  [hidden-name : String]
  [cleanup-name : String]) : ResultLowerState
  (match (sym-i64-lookup env hidden-name)
    [(SomeI64 resource-id)
      (match (lower-state-alloc-var state)
        [(LowerAlloc allocated var-id)
          (OkLowerState
            (lower-state-emit
              allocated
              (IrInstrCall
                var-id
                (lower-resolve-call-name allocated env cleanup-name)
                (IrValueCons (IrValueVar resource-id) IrValueNil)
                (AstTyUnit))))])]
    [(NoneI64)
      (ErrLowerState
        (lower-diagnostic "lower: missing resource cleanup binding"))]))

(define (lower-emit-region-reset
  [state : LowerState]
  [env : SymI64Env]
  [hidden-name : String]) : ResultLowerState
  (match (sym-i64-lookup env hidden-name)
    [(SomeI64 mark-var)
      (match (lower-state-alloc-var state)
        [(LowerAlloc allocated reset-var)
          (OkLowerState
            (lower-state-emit
              allocated
              (IrInstrCall
                reset-var
                "tl_region_reset"
                (IrValueCons (IrValueVar mark-var) IrValueNil)
                (AstTyUnit))))])]
    [(NoneI64)
      (ErrLowerState (lower-diagnostic "lower: missing region reset binding"))]))

(define (lower-emit-cleanup-list
  [state : LowerState]
  [env : SymI64Env]
  [cleanups : LowerCleanupList]) : ResultLowerState
  (match cleanups
    [(LowerCleanupNil) (OkLowerState state)]
    [(LowerCleanupCons cleanup rest)
      (match cleanup
        [(LowerCleanup hidden-name cleanup-name)
          (match (lower-emit-cleanup-call state env hidden-name cleanup-name)
            [(OkLowerState next-state)
              (lower-emit-cleanup-list next-state env rest)]
            [(ErrLowerState message) (ErrLowerState message)])])]))

(define (lower-emit-active-exits
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]) : ResultLowerState
  (match type-env
    [(TcTypeNil) (OkLowerState state)]
    [(TcTypeBind key ty rest)
      (if (string-eq key (lower-cleanup-marker-name))
        (match ty
          [(AstTyTuple
              (AstTypeCons
                (AstTyVar hidden-name)
                (AstTypeCons (AstTyVar cleanup-name) AstTypeNil)))
            (match (lower-emit-cleanup-call state env hidden-name cleanup-name)
              [(OkLowerState next-state)
                (lower-emit-active-exits next-state env rest)]
              [(ErrLowerState message) (ErrLowerState message)])]
          [_ (lower-emit-active-exits state env rest)])
        (if (string-eq key (lower-region-reset-marker-name))
          (match ty
            [(AstTyVar hidden-name)
              (match (lower-emit-region-reset state env hidden-name)
                [(OkLowerState next-state)
                  (lower-emit-active-exits next-state env rest)]
                [(ErrLowerState message) (ErrLowerState message)])]
            [_ (lower-emit-active-exits state env rest)])
          (lower-emit-active-exits state env rest)))]))

(define (lower-emit-active-cleanups
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]) : ResultLowerState
  (match type-env
    [(TcTypeNil) (OkLowerState state)]
    [(TcTypeBind key ty rest)
      (if (string-eq key (lower-cleanup-marker-name))
        (match ty
          [(AstTyTuple
              (AstTypeCons
                (AstTyVar hidden-name)
                (AstTypeCons (AstTyVar cleanup-name) AstTypeNil)))
            (match (lower-emit-cleanup-call state env hidden-name cleanup-name)
              [(OkLowerState next-state)
                (lower-emit-active-cleanups next-state env rest)]
              [(ErrLowerState message) (ErrLowerState message)])]
          [_ (lower-emit-active-cleanups state env rest)])
        (lower-emit-active-cleanups state env rest))]))

(define (lower-return-form
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [value : AstExpr]
  [origin : AstExpr]) : ResultLowerExpr
  (match (tc-current-return-type type-env)
    [(OkTcType return-ty)
      (match (lower-expr ctx state env type-env value)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr value-state value-ir _)
              (match (lower-emit-active-exits value-state env type-env)
                [(OkLowerState cleanup-state)
                  (OkLowerExpr
                    (LowerExpr
                      (lower-state-emit-at-expr
                        cleanup-state
                        (IrInstrReturn (lower-return-maybe value-ir return-ty))
                        origin)
                      IrValueUnit
                      (AstTyNever)))]
                [(ErrLowerState message) (ErrLowerExpr message)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(ErrTcType _)
      (ErrLowerExpr
        (lower-diagnostic-at-expr
          origin
          "typecheck: return requires enclosing function"))]))

(define (lower-load-single-payload
  [ctx : TcContext]
  [state : LowerState]
  [base : CompilerIrValue]
  [ty : AstType]) : LowerExpr
  (let
    [resolved : AstType (tc-type-without-regions (tc-resolve-type ctx ty))]
    (match resolved
      [(AstTyUnit) (LowerExpr state IrValueUnit resolved)]
      [_ (lower-load-at-offset state base 8 resolved)])))

(define (lower-return-result-err
  [ctx : TcContext]
  [state : LowerState]
  [return-info : TcResultInfo]
  [payload : CompilerIrValue]) : ResultLowerState
  (match ctx
    [(TcContext _ _ registries _)
      (let
        [enum-name : String (tc-result-info-enum-name return-info)]
        [err-name : String (tc-result-info-err-name return-info)]
        [err-ty : AstType
          (tc-type-without-regions (tc-result-info-err-type return-info))]
        (match (compiler-registries-lookup-variant registries err-name)
          [(SomeI64 handle)
            (match (lower-reserve-heap-storage
              state
              (lower-enum-storage-size ctx enum-name)
              (AstTyEnum enum-name))
              [(LowerExpr base-state base _)
                (let
                  [tag-state : LowerState
                    (lower-store-at-offset
                      base-state
                      base
                      0
                      (IrValueI64 (compiler-registry-handle-child-index handle))
                      (AstTyI64))]
                  [payload-state : LowerState
                    (match err-ty
                      [(AstTyUnit) tag-state]
                      [_
                        (lower-store-at-offset tag-state base 8 payload err-ty)])]
                  (OkLowerState
                    (lower-state-emit
                      payload-state
                      (IrInstrReturn
                        (lower-return-maybe base (AstTyEnum enum-name))))))])]
          [(NoneI64)
            (ErrLowerState
              (lower-diagnostic
                (string-append "lower: unknown variant " err-name)))]))]))

(define (lower-try-finish
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [result-value : CompilerIrValue]
  [operand-info : TcResultInfo]
  [return-info : TcResultInfo]
  [ok-label : String]
  [err-label : String]) : ResultLowerExpr
  (let
    [err-start : LowerState (lower-state-finish-block state err-label)]
    (match (lower-load-single-payload
      ctx
      err-start
      result-value
      (tc-result-info-err-type operand-info))
      [(LowerExpr err-payload-state err-payload _)
        (match (lower-emit-active-exits err-payload-state env type-env)
          [(OkLowerState cleanup-state)
            (match (lower-return-result-err
              ctx
              cleanup-state
              return-info
              err-payload)
              [(OkLowerState returned-state)
                (let
                  [ok-start : LowerState
                    (lower-state-finish-block returned-state ok-label)]
                  (match (lower-load-single-payload
                    ctx
                    ok-start
                    result-value
                    (tc-result-info-ok-type operand-info))
                    [(LowerExpr ok-state ok-payload ok-ty)
                      (OkLowerExpr (LowerExpr ok-state ok-payload ok-ty))]))]
              [(ErrLowerState message) (ErrLowerExpr message)])]
          [(ErrLowerState message) (ErrLowerExpr message)])])))

(define (lower-try-with-info
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [result-value : CompilerIrValue]
  [operand-info : TcResultInfo]
  [return-info : TcResultInfo]
  [origin : AstExpr]) : ResultLowerExpr
  (match ctx
    [(TcContext _ _ registries _)
      (let
        [ok-name : String (tc-result-info-ok-name operand-info)]
        (match (compiler-registries-lookup-variant registries ok-name)
          [(SomeI64 ok-handle)
            (match (lower-load-at-offset state result-value 0 (AstTyI64))
              [(LowerExpr tag-state tag-value _)
                (match (lower-state-alloc-var tag-state)
                  [(LowerAlloc eq-alloc eq-var)
                    (match (lower-state-fresh-label eq-alloc "try_ok")
                      [(LowerLabel ok-label-state ok-label)
                        (match (lower-state-fresh-label
                          ok-label-state
                          "try_err")
                          [(LowerLabel err-label-state err-label)
                            (let
                              [eq-state : LowerState
                                (lower-state-emit-at-expr
                                  err-label-state
                                  (IrInstrBinOp
                                    eq-var
                                    IrBinEq
                                    tag-value
                                    (IrValueI64
                                      (compiler-registry-handle-child-index
                                        ok-handle))
                                    (AstTyBool))
                                  origin)]
                              (lower-try-finish
                                ctx
                                (lower-state-emit
                                  eq-state
                                  (IrInstrBranch
                                    (IrValueVar eq-var)
                                    ok-label
                                    err-label))
                                env
                                type-env
                                result-value
                                operand-info
                                return-info
                                ok-label
                                err-label))])])])])]
          [(NoneI64)
            (ErrLowerExpr
              (lower-diagnostic-at-expr
                origin
                (string-append "lower: unknown variant " ok-name)))]))]))

(define (lower-try
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [inner : AstExpr]
  [origin : AstExpr]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env inner)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr result-state result-value result-ty)
          (match (tc-result-info ctx result-ty)
            [(OkTcResultInfo operand-info)
              (match (tc-current-return-type type-env)
                [(OkTcType return-ty)
                  (match (tc-result-info ctx return-ty)
                    [(OkTcResultInfo return-info)
                      (lower-try-with-info
                        ctx
                        result-state
                        env
                        type-env
                        result-value
                        operand-info
                        return-info
                        origin)]
                    [(ErrTcResultInfo _)
                      (ErrLowerExpr
                        (lower-diagnostic-at-expr
                          origin
                          "typecheck: try requires enclosing Result-like function"))])]
                [(ErrTcType _)
                  (ErrLowerExpr
                    (lower-diagnostic-at-expr
                      origin
                      "typecheck: try requires enclosing Result-like function"))])]
            [(ErrTcResultInfo _)
              (ErrLowerExpr
                (lower-diagnostic-at-expr
                  origin
                  "typecheck: try operand must be Result-like enum"))])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-top-level-value-defined? [ctx : TcContext] [name : String]) : bool
  (match ctx
    [(TcContext _ symbols _ module)
      (let
        [lookup-name : String
          (if (and (> (string-length module) 0) (not (tc-name-qualified? name)))
            (compiler-symbol-module-key module name)
            name)]
        (match (compiler-symbols-lookup-value symbols lookup-name)
          [(SomeI64 _) true]
          [(NoneI64) false]))]))

(define (lower-builtin-call-available?
  [ctx : TcContext]
  [env : SymI64Env]
  [name : String]) : bool
  (and
    (not (sym-i64-contains env name))
    (not (lower-top-level-value-defined? ctx name))))

(define (lower-stdio-builtin? [name : String]) : bool
  (cond
    [(string-eq name "read-stdin-line") true]
    [(string-eq name "read-stdin-bytes") true]
    [(string-eq name "stdin-eof?") true]
    [else (string-eq name "flush-stdout")]))

(define (lower-string-runtime-builtin? [name : String]) : bool
  (cond
    [(string-eq name "substring") true]
    [(string-eq name "string-slice") true]
    [(string-eq name "string-append") true]
    [else (string-eq name "string-concat")]))

;; First-class arena primitives (#1633). arena-mark/arena-rewind reuse the
;; existing region runtime (they snapshot/rewind the current arena's bump).
(define (lower-arena-builtin? [name : String]) : bool
  (cond
    [(string-eq name "arena-make") true]
    [(string-eq name "arena-current") true]
    [(string-eq name "arena-mark") true]
    [(string-eq name "arena-set!") true]
    [(string-eq name "arena-destroy") true]
    [else (string-eq name "arena-rewind")]))

(define (lower-arena-builtin-nullary? [name : String]) : bool
  (or
    (string-eq name "arena-make")
    (or (string-eq name "arena-current") (string-eq name "arena-mark"))))

(define (lower-arena-builtin-symbol [name : String]) : String
  (cond
    [(string-eq name "arena-make") "tl_arena_make"]
    [(string-eq name "arena-current") "tl_arena_current"]
    [(string-eq name "arena-mark") "tl_region_mark"]
    [(string-eq name "arena-set!") "tl_arena_set"]
    [(string-eq name "arena-destroy") "tl_arena_destroy"]
    [else "tl_region_reset"]))

(define (lower-profile-builtin? [name : String]) : bool
  (cond
    [(string-eq name "profile-now-ms") true]
    [(string-eq name "profile-alloc-total") true]
    [(string-eq name "profile-alloc-live") true]
    [(string-eq name "profile-alloc-peak") true]
    [else (string-eq name "profile-alloc-reset-peak")]))

(define (lower-profile-builtin-symbol [name : String]) : String
  (cond
    [(string-eq name "profile-now-ms") "tl_profile_now_ms"]
    [(string-eq name "profile-alloc-total") "tl_profile_alloc_total"]
    [(string-eq name "profile-alloc-live") "tl_profile_alloc_live"]
    [(string-eq name "profile-alloc-peak") "tl_profile_alloc_peak"]
    [else "tl_profile_alloc_reset_peak"]))

(define (lower-profile-builtin-call
  [state : LowerState]
  [name : String]
  [args : AstExprList]
  [result-ty : AstType]) : ResultLowerExpr
  (match args
    [(AstExprNil)
      (lower-runtime-call-values
        state
        (lower-profile-builtin-symbol name)
        IrValueNil
        result-ty)]
    [_
      (ErrLowerExpr
        (lower-diagnostic "lower: profile builtin expects no arguments"))]))

(define (lower-arena-builtin-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [result-ty : AstType]) : ResultLowerExpr
  (if (lower-arena-builtin-nullary? name)
    (lower-runtime-call-values
      state
      (lower-arena-builtin-symbol name)
      IrValueNil
      result-ty)
    (match args
      [(AstExprCons arg (AstExprNil))
        (match (lower-expr ctx state env type-env arg)
          [(OkLowerExpr lowered)
            (match lowered
              [(LowerExpr arg-state arg-value arg-ty)
                (match (lower-cast-value arg-state arg-value arg-ty (AstTyI64))
                  [(LowerExpr cast-state cast-value _)
                    (lower-runtime-call-values
                      cast-state
                      (lower-arena-builtin-symbol name)
                      (IrValueCons cast-value IrValueNil)
                      result-ty)])])]
          [(ErrLowerExpr message) (ErrLowerExpr message)])]
      [_
        (ErrLowerExpr
          (lower-diagnostic "lower: arena builtin expects one argument"))])))

;; Lower `(clone x)` (#1633): the canonical deep-copy / arena-escape. A String
;; copies its buffer through `tl_substring`; tuple, fixed-array, and dynamic-
;; array values allocate fresh storage and recursively clone each element; named
;; aggregates dispatch to synthesized `clone$<Name>` helpers (compiler_clone.tl)
;; so recursive enum/struct values recurse at runtime instead of lower time; and
;; scalar values are returned as-is.
(define (lower-clone-named
  [state : LowerState]
  [env : SymI64Env]
  [name : String]
  [value : CompilerIrValue]
  [ty : AstType]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc allocated var-id)
      (OkLowerExpr
        (LowerExpr
          (lower-state-emit
            allocated
            (IrInstrCall
              var-id
              (lower-resolve-call-name allocated env (clone-helper-name name))
              (IrValueCons value IrValueNil)
              ty))
          (IrValueVar var-id)
          ty))]))

(define (lower-clone-scalar-type? [ty : AstType]) : bool
  (match ty
    [(AstTyI64) true]
    [(AstTyI32) true]
    [(AstTyI16) true]
    [(AstTyI8) true]
    [(AstTyU64) true]
    [(AstTyU32) true]
    [(AstTyU16) true]
    [(AstTyU8) true]
    [(AstTyF64) true]
    [(AstTyF32) true]
    [(AstTyBool) true]
    [(AstTyChar) true]
    [(AstTyUnit) true]
    [(AstTyNever) true]
    [_ false]))

(define (lower-clone-type-list
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [src : CompilerIrValue]
  [dst : CompilerIrValue]
  [types : AstTypeList]
  [cursor : i64]) : ResultLowerState
  (match types
    [(AstTypeNil) (OkLowerState state)]
    [(AstTypeCons ty rest)
      (let
        [resolved : AstType (tc-type-without-regions (tc-resolve-type ctx ty))]
        [offset : i64 (lower-align-up cursor (lower-type-align ctx resolved))]
        [size : i64 (lower-type-size ctx resolved)]
        (if (> size 0)
          (match (lower-load-at-offset state src offset resolved)
            [(LowerExpr load-state field-value _)
              (match (lower-clone-dispatch
                ctx
                load-state
                env
                type-env
                field-value
                resolved)
                [(OkLowerExpr cloned)
                  (match cloned
                    [(LowerExpr clone-state clone-value _)
                      (lower-clone-type-list
                        ctx
                        (lower-store-at-offset
                          clone-state
                          dst
                          offset
                          clone-value
                          resolved)
                        env
                        type-env
                        src
                        dst
                        rest
                        (+ offset size))])]
                [(ErrLowerExpr message) (ErrLowerState message)])])
          (lower-clone-type-list
            ctx
            state
            env
            type-env
            src
            dst
            rest
            (+ offset size))))]))

(define (lower-clone-tuple-value
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [value : CompilerIrValue]
  [elem-tys : AstTypeList]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-reserve-heap-storage
    state
    (lower-type-list-storage-size ctx elem-tys)
    result-ty)
    [(LowerExpr dst-state dst _)
      (match (lower-clone-type-list
        ctx
        dst-state
        env
        type-env
        value
        dst
        elem-tys
        0)
        [(OkLowerState done-state)
          (OkLowerExpr (LowerExpr done-state dst result-ty))]
        [(ErrLowerState message) (ErrLowerExpr message)])]))

(define (lower-clone-fixed-array-elems
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [src : CompilerIrValue]
  [dst : CompilerIrValue]
  [elem-ty : AstType]
  [elem-size : i64]
  [index : i64]
  [count : i64]) : ResultLowerState
  (if (>= index count)
    (OkLowerState state)
    (let
      [offset : i64 (* index elem-size)]
      (if (> elem-size 0)
        (match (lower-load-at-offset state src offset elem-ty)
          [(LowerExpr load-state elem-value _)
            (match (lower-clone-dispatch
              ctx
              load-state
              env
              type-env
              elem-value
              elem-ty)
              [(OkLowerExpr cloned)
                (match cloned
                  [(LowerExpr clone-state clone-value _)
                    (lower-clone-fixed-array-elems
                      ctx
                      (lower-store-at-offset
                        clone-state
                        dst
                        offset
                        clone-value
                        elem-ty)
                      env
                      type-env
                      src
                      dst
                      elem-ty
                      elem-size
                      (+ index 1)
                      count)])]
              [(ErrLowerExpr message) (ErrLowerState message)])])
        (lower-clone-fixed-array-elems
          ctx
          state
          env
          type-env
          src
          dst
          elem-ty
          elem-size
          (+ index 1)
          count)))))

(define (lower-clone-fixed-array-value
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [value : CompilerIrValue]
  [elem-ty : AstType]
  [count : i64]
  [result-ty : AstType]) : ResultLowerExpr
  (let
    [elem-size : i64 (lower-type-size ctx elem-ty)]
    (match (lower-reserve-heap-storage
      state
      (lower-fixed-array-storage-size ctx elem-ty count)
      result-ty)
      [(LowerExpr dst-state dst _)
        (match (lower-clone-fixed-array-elems
          ctx
          dst-state
          env
          type-env
          value
          dst
          elem-ty
          elem-size
          0
          count)
          [(OkLowerState done-state)
            (OkLowerExpr (LowerExpr done-state dst result-ty))]
          [(ErrLowerState message) (ErrLowerExpr message)])])))

(define (lower-clone-dynarray-advance
  [state : LowerState]
  [index-var : i64]
  [header-label : String]
  [exit-label : String]) : ResultLowerState
  (match (lower-state-alloc-var state)
    [(LowerAlloc inc-alloc inc-var)
      (OkLowerState
        (lower-state-finish-block
          (lower-state-emit
            (lower-state-emit
              (lower-state-emit
                inc-alloc
                (IrInstrBinOp
                  inc-var
                  IrBinAdd
                  (IrValueVar index-var)
                  (IrValueI64 1)
                  (AstTyI64)))
              (IrInstrMov index-var (IrValueVar inc-var) (AstTyI64)))
            (IrInstrJump header-label))
          exit-label))]))

(define (lower-clone-dynarray-store-and-advance
  [state : LowerState]
  [new-buf : CompilerIrValue]
  [index-var : i64]
  [header-label : String]
  [exit-label : String]
  [clone-value : CompilerIrValue]
  [elem-ty : AstType]) : ResultLowerState
  (match (lower-emit-gep state new-buf (IrValueVar index-var) elem-ty)
    [(LowerExpr dst-gep-state dst-ptr _)
      (lower-clone-dynarray-advance
        (lower-state-emit
          dst-gep-state
          (IrInstrStorePtr dst-ptr clone-value elem-ty))
        index-var
        header-label
        exit-label)]))

(define (lower-clone-dynarray-copy-body
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [old-buf : CompilerIrValue]
  [new-buf : CompilerIrValue]
  [index-var : i64]
  [header-label : String]
  [exit-label : String]
  [elem-ty : AstType]) : ResultLowerState
  (match (lower-emit-gep state old-buf (IrValueVar index-var) elem-ty)
    [(LowerExpr src-gep-state src-ptr _)
      (match (lower-emit-load src-gep-state src-ptr elem-ty)
        [(LowerExpr load-state elem-value _)
          (match (lower-clone-dispatch
            ctx
            load-state
            env
            type-env
            elem-value
            elem-ty)
            [(OkLowerExpr cloned)
              (match cloned
                [(LowerExpr clone-state clone-value _)
                  (lower-clone-dynarray-store-and-advance
                    clone-state
                    new-buf
                    index-var
                    header-label
                    exit-label
                    clone-value
                    elem-ty)])]
            [(ErrLowerExpr message) (ErrLowerState message)])])]))

(define (lower-clone-dynarray-copy-nonempty
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [old-buf : CompilerIrValue]
  [new-buf : CompilerIrValue]
  [len : CompilerIrValue]
  [elem-ty : AstType]) : ResultLowerState
  (match (lower-state-fresh-label state "clone_array_header")
    [(LowerLabel header-label-state header-label)
      (match (lower-state-fresh-label header-label-state "clone_array_body")
        [(LowerLabel body-label-state body-label)
          (match (lower-state-fresh-label body-label-state "clone_array_exit")
            [(LowerLabel exit-label-state exit-label)
              (match (lower-state-alloc-var exit-label-state)
                [(LowerAlloc index-alloc index-var)
                  (let
                    [header-start : LowerState
                      (lower-state-finish-block
                        (lower-state-emit
                          (lower-state-emit
                            index-alloc
                            (IrInstrMov index-var (IrValueI64 0) (AstTyI64)))
                          (IrInstrJump header-label))
                        header-label)]
                    (match (lower-state-alloc-var header-start)
                      [(LowerAlloc cond-alloc cond-var)
                        (let
                          [body-start : LowerState
                            (lower-state-finish-block
                              (lower-state-emit
                                (lower-state-emit
                                  cond-alloc
                                  (IrInstrBinOp
                                    cond-var
                                    IrBinLt
                                    (IrValueVar index-var)
                                    len
                                    (AstTyBool)))
                                (IrInstrBranch
                                  (IrValueVar cond-var)
                                  body-label
                                  exit-label))
                              body-label)]
                          (lower-clone-dynarray-copy-body
                            ctx
                            body-start
                            env
                            type-env
                            old-buf
                            new-buf
                            index-var
                            header-label
                            exit-label
                            elem-ty))]))])])])]))

(define (lower-clone-dynarray-copy-loop
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [old-buf : CompilerIrValue]
  [new-buf : CompilerIrValue]
  [len : CompilerIrValue]
  [elem-ty : AstType]
  [elem-size : i64]) : ResultLowerState
  (if (= elem-size 0)
    (OkLowerState state)
    (lower-clone-dynarray-copy-nonempty
      ctx
      state
      env
      type-env
      old-buf
      new-buf
      len
      elem-ty)))

(define (lower-clone-dynarray-finish
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [old-buf : CompilerIrValue]
  [len : CompilerIrValue]
  [elem-ty : AstType]
  [elem-size : i64]
  [buf-var : i64]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-reserve-heap-storage state 16 result-ty)
    [(LowerExpr arr-state arr-value _)
      (match (lower-clone-dynarray-copy-loop
        ctx
        arr-state
        env
        type-env
        old-buf
        (IrValueVar buf-var)
        len
        elem-ty
        elem-size)
        [(OkLowerState copied-state)
          (OkLowerExpr
            (LowerExpr
              (lower-store-at-offset
                (lower-store-at-offset
                  copied-state
                  arr-value
                  0
                  (IrValueVar buf-var)
                  (AstTyU64))
                arr-value
                8
                len
                (AstTyI64))
              arr-value
              result-ty))]
        [(ErrLowerState message) (ErrLowerExpr message)])]))

(define (lower-clone-dynarray-value
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [value : CompilerIrValue]
  [elem-ty : AstType]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-load-at-offset state value 8 (AstTyI64))
    [(LowerExpr len-state len _)
      (match (lower-load-at-offset len-state value 0 (AstTyU64))
        [(LowerExpr ptr-state old-buf _)
          (let
            [elem-size : i64 (lower-type-size ctx elem-ty)]
            (match (if (= elem-size 0)
              (LowerExpr ptr-state (IrValueI64 1) (AstTyI64))
              (lower-emit-binop
                ptr-state
                IrBinMul
                len
                (IrValueI64 elem-size)
                (AstTyI64)))
              [(LowerExpr byte-state byte-count _)
                (match (lower-state-alloc-var byte-state)
                  [(LowerAlloc buf-alloc buf-var)
                    (lower-clone-dynarray-finish
                      ctx
                      (lower-state-emit
                        buf-alloc
                        (IrInstrCall
                          buf-var
                          "tl_alloc"
                          (IrValueCons byte-count IrValueNil)
                          (AstTyU64)))
                      env
                      type-env
                      old-buf
                      len
                      elem-ty
                      elem-size
                      buf-var
                      result-ty)])]))])]))

(define (lower-clone-dispatch
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [value : CompilerIrValue]
  [ty : AstType]) : ResultLowerExpr
  (let
    [clone-ty : AstType (tc-type-without-regions (tc-resolve-type ctx ty))]
    (match clone-ty
      [(AstTyString) (lower-capture-snapshot-string-value state value)]
      [(AstTyTuple elem-tys)
        (lower-clone-tuple-value ctx state env type-env value elem-tys clone-ty)]
      [(AstTyArray elem-ty count)
        (lower-clone-fixed-array-value
          ctx
          state
          env
          type-env
          value
          (tc-type-without-regions elem-ty)
          count
          clone-ty)]
      [(AstTyDynArray elem-ty)
        (lower-clone-dynarray-value
          ctx
          state
          env
          type-env
          value
          (tc-type-without-regions elem-ty)
          clone-ty)]
      [(AstTyEnum name) (lower-clone-named state env name value clone-ty)]
      [(AstTyStruct name) (lower-clone-named state env name value clone-ty)]
      [(AstTyVar name) (lower-clone-named state env name value clone-ty)]
      [_
        (if (lower-clone-scalar-type? clone-ty)
          (OkLowerExpr (LowerExpr state value clone-ty))
          (ErrLowerExpr
            (lower-diagnostic
              (string-append
                "lower: clone unsupported type "
                (tc-type-render clone-ty)))))])))

(define (lower-clone-value-dispatch
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [value : CompilerIrValue]
  [ty : AstType]) : ResultLowerExpr
  (match (tc-resolve-type ctx ty)
    [(AstTyString)
      (match (lower-string-fields state value)
        [(LowerStringFields fields-state ptr len)
          (lower-substring-bounds-checked
            fields-state
            ptr
            len
            (IrValueI64 0)
            len)])]
    [(AstTyEnum name) (lower-clone-named state env name value ty)]
    [(AstTyStruct name) (lower-clone-named state env name value ty)]
    [(AstTyVar name) (lower-clone-named state env name value ty)]
    [_ (OkLowerExpr (LowerExpr state value ty))]))

(define (lower-clone-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [arg : AstExpr]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env arg)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr arg-state arg-value arg-ty)
          (lower-clone-dispatch ctx arg-state env type-env arg-value arg-ty)])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-bootstrap-runtime-builtin? [name : String]) : bool
  (cond
    [(string-eq name "string-eq") true]
    [(string-eq name "string=?") true]
    [(string-eq name "string->int") true]
    [(string-eq name "int->string") true]
    [(string-eq name "arg-count") true]
    [(string-eq name "arg") true]
    [(string-eq name "read-file") true]
    [(string-eq name "read-file-status") true]
    [(string-eq name "write-file") true]
    [(string-eq name "write-file-status") true]
    [(string-eq name "append-file-status") true]
    [(string-eq name "file-exists?") true]
    [(string-eq name "file-exists-status") true]
    [(string-eq name "file-open-status") true]
    [(string-eq name "file-close-status") true]
    [(string-eq name "file-read-chunk-status") true]
    [(string-eq name "file-write-status") true]
    [(string-eq name "file-flush-status") true]
    [(string-eq name "file-read-chunk-bytes") true]
    [(string-eq name "file-read-chunk-eof?") true]
    [(string-eq name "fs-mkdir-status") true]
    [(string-eq name "fs-remove-file-status") true]
    [(string-eq name "fs-remove-dir-status") true]
    [(string-eq name "fs-rename-status") true]
    [(string-eq name "fs-process-id") true]
    [(string-eq name "fs-current-dir-status") true]
    [(string-eq name "fs-current-dir") true]
    [(string-eq name "panic") true]
    [(string-eq name "error") true]
    [else (string-eq name "print-error")]))

(define (lower-print-string-builtin? [name : String]) : bool
  (or (string-eq name "print-string") (string-eq name "print-str")))

(define (lower-stdio-runtime-name [name : String]) : String
  (cond
    [(string-eq name "read-stdin-line") ".L_tl_read_stdin_line"]
    [(string-eq name "read-stdin-bytes") ".L_tl_read_stdin_bytes"]
    [(string-eq name "stdin-eof?") ".L_tl_stdin_eof"]
    [else ".L_tl_flush_stdout"]))

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
        [(AstTypeCons expected rest-types)
          (let
            [arg-ty : AstType
              (tc-type-without-regions (tc-resolve-type ctx expected))]
            (match (lower-expr-expected ctx state env type-env arg arg-ty arg)
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
              [(ErrLowerExpr message) (ErrLowerArgs message)]))]
        [(AstTypeNil)
          (ErrLowerArgs (lower-diagnostic "lower: constructor arity mismatch"))])]))

(define (lower-construct-struct-inline-from-values
  [ctx : TcContext]
  [state : LowerState]
  [struct-name : String]
  [values : CompilerIrValueList]
  [fields : AstFieldDefList]
  [struct-ty : AstType]) : ResultLowerExpr
  (match (tc-inline-aggregate-layout-for ctx struct-name)
    [(OkTcInlineAggregateLayout layout)
      (match layout
        [(TcInlineStructLayout size _ _)
          (match (lower-reserve-inline-storage state size struct-ty)
            [(LowerExpr base-state base _)
              (match (lower-store-inline-struct-values
                ctx
                base-state
                base
                values
                fields
                layout)
                [(OkLowerState done-state)
                  (OkLowerExpr (LowerExpr done-state base struct-ty))]
                [(ErrLowerState message) (ErrLowerExpr message)])])]
        [(TcInlineEnumLayout _ _ _)
          (ErrLowerExpr
            (lower-diagnostic
              (string-append
                "lower: inline layout for struct is enum "
                struct-name)))])]
    [(ErrTcInlineAggregateLayout message)
      (ErrLowerExpr (lower-diagnostic message))]))

(define (lower-construct-enum-inline-from-values
  [ctx : TcContext]
  [state : LowerState]
  [variant-name : String]
  [handle : i64]
  [values : CompilerIrValueList]
  [fields : AstTypeList]
  [enum-name : String]) : ResultLowerExpr
  (match (tc-inline-aggregate-layout-for ctx enum-name)
    [(OkTcInlineAggregateLayout layout)
      (match layout
        [(TcInlineEnumLayout size _ _)
          (let
            [layout-variant-name : String (tc-qualified-name-base variant-name)]
            (match (lower-reserve-inline-storage
              state
              size
              (AstTyEnum enum-name))
              [(LowerExpr base-state base _)
                (let
                  [tag-state : LowerState
                    (lower-store-at-offset
                      base-state
                      base
                      0
                      (IrValueI64 (compiler-registry-handle-child-index handle))
                      (AstTyI64))]
                  (match (lower-store-inline-payload-values
                    ctx
                    tag-state
                    base
                    values
                    fields
                    layout
                    layout-variant-name
                    0)
                    [(OkLowerState done-state)
                      (OkLowerExpr
                        (LowerExpr done-state base (AstTyEnum enum-name)))]
                    [(ErrLowerState message) (ErrLowerExpr message)]))]))]
        [(TcInlineStructLayout _ _ _)
          (ErrLowerExpr
            (lower-diagnostic
              (string-append
                "lower: inline layout for enum is struct "
                enum-name)))])]
    [(ErrTcInlineAggregateLayout message)
      (ErrLowerExpr (lower-diagnostic message))]))

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
        [(TcContext program _ _ _)
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
                  (if (lower-mode-inline-aggregates?
                    (lower-state-mode args-state))
                    (lower-construct-enum-inline-from-values
                      ctx
                      args-state
                      variant-name
                      handle
                      values
                      fields
                      enum-name)
                    (match fields
                      [(AstTypeNil)
                        (OkLowerExpr
                          (LowerExpr
                            args-state
                            (IrValueGlobalAddr
                              (lower-nullary-variant-object-name
                                enum-name
                                variant-name))
                            (AstTyEnum enum-name)))]
                      [_
                        (let
                          [size : i64
                            (lower-variant-fields-storage-size ctx fields)]
                          (match (lower-reserve-heap-storage
                            args-state
                            size
                            (AstTyEnum enum-name))
                            [(LowerExpr base-state base _)
                              (let
                                [tag-state : LowerState
                                  (lower-store-at-offset
                                    base-state
                                    base
                                    0
                                    (IrValueI64
                                      (compiler-registry-handle-child-index
                                        handle))
                                    (AstTyI64))]
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
                                  [(ErrLowerState message)
                                    (ErrLowerExpr message)]))]))]))]
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
      (let
        [field-types : AstTypeList (tc-field-type-list ctx fields)]
        (match (lower-args-as ctx state env type-env args field-types)
          [(OkLowerArgs args-state values)
            (let
              [struct-ty : AstType (tc-resolve-type ctx result-ty)]
              (if (and
                (lower-mode-inline-aggregates? (lower-state-mode args-state))
                (not (lower-struct-repr-c? ctx struct-name)))
                (lower-construct-struct-inline-from-values
                  ctx
                  args-state
                  struct-name
                  values
                  fields
                  struct-ty)
                (if (lower-struct-repr-c? ctx struct-name)
                  (match (tc-repr-c-struct-layout ctx struct-name)
                    [(OkTcReprCLayout layout)
                      (match (lower-reserve-heap-storage
                        args-state
                        (tc-repr-c-layout-size layout)
                        struct-ty)
                        [(LowerExpr base-state base _)
                          (match (lower-store-repr-c-values
                            ctx
                            base-state
                            base
                            values
                            (tc-repr-c-layout-fields layout))
                            [(OkLowerState done-state)
                              (OkLowerExpr
                                (LowerExpr done-state base struct-ty))]
                            [(ErrLowerState message) (ErrLowerExpr message)])])]
                    [(ErrTcReprCLayout message)
                      (ErrLowerExpr (lower-diagnostic message))])
                  (let
                    [size : i64 (lower-type-list-storage-size ctx field-types)]
                    (match (lower-reserve-heap-storage
                      args-state
                      size
                      struct-ty)
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
                          [(ErrLowerState message) (ErrLowerExpr message)])])))))]
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
      (let
        [lookup-name : String
          (lower-variant-constructor-lookup-name ctx name expr-ty)]
        [program : AstProgram (tc-context-program ctx)]
        [registries : CompilerRegistries (tc-context-registries ctx)]
        (match (compiler-registries-lookup-variant registries lookup-name)
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
                      lookup-name
                      handle
                      AstExprNil
                      expr-ty)]
                  [_ (lower-function-value-or-var ctx state env name expr-ty)])]
              [(ErrAstTypeList _)
                (lower-function-value-or-var ctx state env name expr-ty)])]
          [(NoneI64) (lower-function-value-or-var ctx state env name expr-ty)]))]))

(define (lower-call-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [func : AstExpr]
  [args : AstExprList]) : ResultTcType
  (match (ast-expr-unspan func)
    [(AstExprVar name)
      (match (tc-lookup type-env name)
        [(OkTcType fn-ty)
          (match (tc-type-strip-region (tc-resolve-type ctx fn-ty))
            [(AstTyFunc _ ret)
              (OkTcType
                (tc-type-without-regions (tc-resolve-type ctx ret)))]
            [(AstTyEnum _)
              (OkTcType (tc-type-without-regions fn-ty))]
            [_ (ErrTcType "lower: call result type is not fast-pathable")])]
        [(ErrTcType message)
          (if (lower-builtin-call-available? ctx env name)
            (cond
              [(string-eq name "array-length") (OkTcType (AstTyI64))]
              [(or (string-eq name "string-ref") (string-eq name "char-at"))
                (OkTcType (AstTyChar))]
              [(string-eq name "clone")
                (match args
                  [(AstExprCons arg (AstExprNil))
                    (lower-expr-result-type-fast ctx env type-env arg)]
                  [_ (ErrTcType "lower: call result type is not fast-pathable")])]
              [else (ErrTcType message)])
            (ErrTcType message))])]
    [_ (ErrTcType "lower: call result type is not fast-pathable")]))

(define (lower-binary-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [op : AstBinOp]
  [left : AstExpr]) : ResultTcType
  (match op
    [(AstBinAnd) (OkTcType (AstTyBool))]
    [(AstBinOr) (OkTcType (AstTyBool))]
    [(AstBinEq) (OkTcType (AstTyBool))]
    [(AstBinNe) (OkTcType (AstTyBool))]
    [(AstBinLt) (OkTcType (AstTyBool))]
    [(AstBinLe) (OkTcType (AstTyBool))]
    [(AstBinGt) (OkTcType (AstTyBool))]
    [(AstBinGe) (OkTcType (AstTyBool))]
    [_
      (match (lower-expr-result-type-fast ctx env type-env left)
        [(OkTcType left-ty) (OkTcType left-ty)]
        [(ErrTcType message) (ErrTcType message)])]))

(define (lower-if-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [then-branch : AstExpr]
  [else-branch : AstExpr]) : ResultTcType
  (match (lower-expr-result-type-fast ctx env type-env then-branch)
    [(OkTcType then-ty)
      (match (lower-expr-result-type-fast ctx env type-env else-branch)
        [(OkTcType else-ty) (tc-merge-branch-type then-ty else-ty)]
        [(ErrTcType message) (ErrTcType message)])]
    [(ErrTcType message) (ErrTcType message)]))

(define (lower-expr-list-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [exprs : AstExprList]) : ResultTcType
  (match exprs
    [(AstExprNil) (OkTcType (AstTyUnit))]
    [(AstExprCons expr rest)
      (match rest
        [(AstExprNil) (lower-expr-result-type-fast ctx env type-env expr)]
        [_ (lower-expr-list-result-type-fast ctx env type-env rest)])]))

(define (lower-pattern-list-bind-local-names
  [env : SymI64Env]
  [patterns : AstPatternList]) : SymI64Env
  (match patterns
    [(AstPatternNil) env]
    [(AstPatternCons pattern rest)
      (lower-pattern-list-bind-local-names
        (lower-pattern-bind-local-names env pattern)
        rest)]))

(define (lower-pattern-bind-local-names
  [env : SymI64Env]
  [pattern : AstPattern]) : SymI64Env
  (match pattern
    [(AstPatVar name _) (sym-i64-bind env name 0)]
    [(AstPatTuple patterns) (lower-pattern-list-bind-local-names env patterns)]
    [(AstPatBinding name) (sym-i64-bind env name 0)]
    [(AstPatVariant _ args) (lower-pattern-list-bind-local-names env args)]
    [_ env]))

(define (lower-match-pattern-bind-local-names
  [ctx : TcContext]
  [env : SymI64Env]
  [scrut-ty : AstType]
  [pattern : AstPattern]) : SymI64Env
  (match (tc-type-strip-region (tc-resolve-type ctx scrut-ty))
    [(AstTyEnum _)
      (match pattern
        [(AstPatVariant _ args) (lower-pattern-list-bind-local-names env args)]
        [_ env])]
    [_ (lower-pattern-bind-local-names env pattern)]))

(define (lower-match-arm-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrut-ty : AstType]
  [arm : AstMatchArm]) : ResultTcType
  (match arm
    [(AstMatchArm pattern body)
      (match (tc-bind-match-pattern ctx type-env scrut-ty pattern)
        [(OkTcEnv arm-type-env)
          (lower-expr-result-type-fast
            ctx
            (lower-match-pattern-bind-local-names ctx env scrut-ty pattern)
            arm-type-env
            body)]
        [(ErrTcEnv message) (ErrTcType message)])]))

(define (lower-match-rest-result-types-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]
  [want : AstType]) : ResultTcType
  (match arms
    [(AstMatchArmNil) (OkTcType want)]
    [(AstMatchArmCons arm rest)
      (match (lower-match-arm-result-type-fast ctx env type-env scrut-ty arm)
        [(OkTcType got)
          (match (tc-merge-branch-type want got)
            [(OkTcType merged)
              (lower-match-rest-result-types-fast
                ctx
                env
                type-env
                scrut-ty
                rest
                merged)]
            [(ErrTcType message) (ErrTcType message)])]
        [(ErrTcType message) (ErrTcType message)])]))

(define (lower-match-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrutinee : AstExpr]
  [arms : AstMatchArmList]) : ResultTcType
  (match (lower-expr-result-type-fast ctx env type-env scrutinee)
    [(OkTcType scrut-ty)
      (match arms
        [(AstMatchArmNil) (ErrTcType "lower: match result type is not fast-pathable")]
        [(AstMatchArmCons arm rest)
          (match (lower-match-arm-result-type-fast ctx env type-env scrut-ty arm)
            [(OkTcType first-ty)
              (lower-match-rest-result-types-fast
                ctx
                env
                type-env
                scrut-ty
                rest
                first-ty)]
            [(ErrTcType message) (ErrTcType message)])])]
    [(ErrTcType message) (ErrTcType message)]))

(define (lower-let-binding-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [maybe-ty : AstMaybeType]
  [init : AstExpr]) : ResultTcType
  (match maybe-ty
    [(AstSomeType ty)
      (OkTcType (tc-type-without-regions (tc-resolve-type ctx ty)))]
    [(AstNoType) (lower-expr-result-type-fast ctx env type-env init)]))

(define (lower-let-bindings-type-env-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [bindings : AstLetBindingList]) : ResultTcEnv
  (match bindings
    [(AstLetBindingNil) (OkTcEnv type-env)]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding name maybe-ty init)
          (match (lower-let-binding-result-type-fast
            ctx
            env
            type-env
            maybe-ty
            init)
            [(OkTcType binding-ty)
              (lower-let-bindings-type-env-fast
                ctx
                (sym-i64-bind env name 0)
                (tc-bind type-env name binding-ty)
                rest)]
            [(ErrTcType message) (ErrTcEnv message)])])]))

(define (lower-let-bindings-local-env
  [env : SymI64Env]
  [bindings : AstLetBindingList]) : SymI64Env
  (match bindings
    [(AstLetBindingNil) env]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding name _ _)
          (lower-let-bindings-local-env (sym-i64-bind env name 0) rest)])]))

(define (lower-projected-result-type-fast
  [ctx : TcContext]
  [container-ty : AstType]
  [projected-ty : AstType]) : AstType
  (tc-type-without-regions
    (tc-resolve-type
      ctx
      (tc-project-from-region-container container-ty projected-ty))))

(define (lower-index-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : AstExpr]) : ResultTcType
  (match (lower-expr-result-type-fast ctx env type-env index)
    [(OkTcType index-ty)
      (if (tc-integer-type? index-ty)
        (OkTcType index-ty)
        (ErrTcType "lower: index result type is not fast-pathable"))]
    [(ErrTcType message) (ErrTcType message)]))

(define (lower-unary-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [op : AstUnOp]
  [inner : AstExpr]) : ResultTcType
  (match (lower-expr-result-type-fast ctx env type-env inner)
    [(OkTcType inner-ty)
      (match (tc-unop-type op inner-ty)
        [(OkTcType result-ty)
          (OkTcType (tc-type-without-regions (tc-resolve-type ctx result-ty)))]
        [(ErrTcType message) (ErrTcType message)])]
    [(ErrTcType message) (ErrTcType message)]))

(define (lower-tuple-ref-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [tuple-expr : AstExpr]
  [index : i64]) : ResultTcType
  (match (lower-expr-result-type-fast ctx env type-env tuple-expr)
    [(OkTcType tuple-ty)
      (match (tc-type-strip-region (tc-resolve-type ctx tuple-ty))
        [(AstTyTuple elem-tys)
          (match (tc-type-list-ref elem-tys index)
            [(OkTcType elem-ty)
              (OkTcType (lower-projected-result-type-fast ctx tuple-ty elem-ty))]
            [(ErrTcType message) (ErrTcType message)])]
        [_ (ErrTcType "lower: tuple-ref result type is not fast-pathable")])]
    [(ErrTcType message) (ErrTcType message)]))

(define (lower-array-ref-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [array-expr : AstExpr]
  [index : AstExpr]) : ResultTcType
  (match (lower-index-result-type-fast ctx env type-env index)
    [(OkTcType _)
      (match (lower-expr-result-type-fast ctx env type-env array-expr)
        [(OkTcType array-ty)
          (match (tc-type-strip-region (tc-resolve-type ctx array-ty))
            [(AstTyArray elem-ty _)
              (OkTcType
                (lower-projected-result-type-fast ctx array-ty elem-ty))]
            [(AstTyDynArray elem-ty)
              (OkTcType
                (lower-projected-result-type-fast ctx array-ty elem-ty))]
            [_ (ErrTcType "lower: array-ref result type is not fast-pathable")])]
        [(ErrTcType message) (ErrTcType message)])]
    [(ErrTcType message) (ErrTcType message)]))

(define (lower-string-ref-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [str : AstExpr]
  [index : AstExpr]) : ResultTcType
  (match (lower-index-result-type-fast ctx env type-env index)
    [(OkTcType _)
      (match (lower-expr-result-type-fast ctx env type-env str)
        [(OkTcType str-ty)
          (if (lower-string-handle-type? ctx str-ty)
            (OkTcType (AstTyChar))
            (ErrTcType "lower: string-ref result type is not fast-pathable"))]
        [(ErrTcType message) (ErrTcType message)])]
    [(ErrTcType message) (ErrTcType message)]))

(define (lower-struct-get-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [receiver : AstExpr]
  [field : String]) : ResultTcType
  (match (lower-expr-result-type-fast ctx env type-env receiver)
    [(OkTcType receiver-ty)
      (match (tc-type-strip-region (tc-resolve-type ctx receiver-ty))
        [(AstTyStruct struct-name)
          (match (tc-struct-field-type ctx struct-name field)
            [(OkTcType field-ty)
              (OkTcType
                (lower-projected-result-type-fast ctx receiver-ty field-ty))]
            [(ErrTcType message) (ErrTcType message)])]
        [_ (ErrTcType "lower: struct-get result type is not fast-pathable")])]
    [(ErrTcType message) (ErrTcType message)]))

(define (lower-box-get-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [box-expr : AstExpr]) : ResultTcType
  (match (lower-expr-result-type-fast ctx env type-env box-expr)
    [(OkTcType box-ty)
      (match (tc-type-strip-region (tc-resolve-type ctx box-ty))
        [(AstTyBox inner-ty)
          (OkTcType
            (lower-projected-result-type-fast ctx box-ty inner-ty))]
        [_ (ErrTcType "lower: box-get result type is not fast-pathable")])]
    [(ErrTcType message) (ErrTcType message)]))

(define (lower-expr-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [expr : AstExpr]) : ResultTcType
  (match expr
    [(AstExprSpanned inner _) (lower-expr-result-type-fast ctx env type-env inner)]
    [(AstExprLiteral lit) (OkTcType (tc-literal-type lit))]
    [(AstExprVar name)
      (match (tc-lookup type-env name)
        [(OkTcType expr-ty)
          (OkTcType (tc-type-without-regions expr-ty))]
        [(ErrTcType message) (ErrTcType message)])]
    [(AstExprAnn _ ty)
      (OkTcType (tc-type-without-regions (tc-resolve-type ctx ty)))]
    [(AstExprCast _ ty)
      (OkTcType (tc-type-without-regions (tc-resolve-type ctx ty)))]
    [(AstExprUnary op inner)
      (lower-unary-result-type-fast ctx env type-env op inner)]
    [(AstExprCall func args)
      (lower-call-result-type-fast ctx env type-env func args)]
    [(AstExprBinary op left _)
      (lower-binary-result-type-fast ctx env type-env op left)]
    [(AstExprIf _ then-branch else-branch)
      (lower-if-result-type-fast ctx env type-env then-branch else-branch)]
    [(AstExprBegin exprs)
      (lower-expr-list-result-type-fast ctx env type-env exprs)]
    [(AstExprUnsafe exprs)
      (lower-expr-list-result-type-fast ctx env (tc-enter-unsafe type-env) exprs)]
    [(AstExprMatch scrutinee arms)
      (lower-match-result-type-fast ctx env type-env scrutinee arms)]
    [(AstExprLet bindings body)
      (match (lower-let-bindings-type-env-fast ctx env type-env bindings)
        [(OkTcEnv body-type-env)
          (lower-expr-result-type-fast
            ctx
            (lower-let-bindings-local-env env bindings)
            body-type-env
            body)]
        [(ErrTcEnv message) (ErrTcType message)])]
    [(AstExprTupleRef tuple-expr index)
      (lower-tuple-ref-result-type-fast ctx env type-env tuple-expr index)]
    [(AstExprArrayRef array-expr index)
      (lower-array-ref-result-type-fast ctx env type-env array-expr index)]
    [(AstExprStringRef str index)
      (lower-string-ref-result-type-fast ctx env type-env str index)]
    [(AstExprStructGet receiver field)
      (lower-struct-get-result-type-fast ctx env type-env receiver field)]
    [(AstExprBoxGet box-expr)
      (lower-box-get-result-type-fast ctx env type-env box-expr)]
    [(AstExprSet _ _) (OkTcType (AstTyUnit))]
    [_ (ErrTcType "lower: expression result type is not fast-pathable")]))

(define (lower-expr-typechecked
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [expr : AstExpr]
  [origin : AstExpr]) : ResultLowerExpr
  (match (tc-expr ctx type-env expr)
    [(OkTcType expr-ty)
      (lower-expr-with-type
        ctx
        state
        env
        type-env
        expr
        origin
        (tc-type-without-regions expr-ty))]
    [(ErrTcType message) (ErrLowerExpr (lower-diagnostic-at-expr expr message))]))

;; Lowering runs after full-program typecheck. For result types that are
;; syntactically available, avoid re-running recursive expression typecheck;
;; the fallback below preserves the old path for anything ambiguous.
(define (lower-expr-origin
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [expr : AstExpr]
  [origin : AstExpr]) : ResultLowerExpr
  (match expr
    [(AstExprSpanned inner _)
      (lower-expr-origin ctx state env type-env inner origin)]
    [(AstExprLiteral lit)
      (lower-expr-with-type
        ctx
        state
        env
        type-env
        expr
        origin
        (tc-literal-type lit))]
    [(AstExprVar name)
      (match (tc-lookup type-env name)
        [(OkTcType expr-ty)
          (lower-expr-with-type
            ctx
            state
            env
            type-env
            expr
            origin
            (tc-type-without-regions expr-ty))]
        [(ErrTcType message)
          (ErrLowerExpr (lower-diagnostic-at-expr origin message))])]
    [(AstExprAnn _ ty)
      (lower-expr-with-type
        ctx
        state
        env
        type-env
        expr
        origin
        (tc-type-without-regions (tc-resolve-type ctx ty)))]
    [(AstExprCast _ ty)
      (lower-expr-with-type
        ctx
        state
        env
        type-env
        expr
        origin
        (tc-type-without-regions (tc-resolve-type ctx ty)))]
    [(AstExprBinary op left _)
      (match (lower-binary-result-type-fast ctx env type-env op left)
        [(OkTcType expr-ty)
          (lower-expr-with-type
            ctx
            state
            env
            type-env
            expr
            origin
            expr-ty)]
        [(ErrTcType _)
          (lower-expr-typechecked ctx state env type-env expr origin)])]
    [(AstExprCall func args)
      (match (lower-call-result-type-fast ctx env type-env func args)
        [(OkTcType expr-ty)
          (lower-expr-with-type
            ctx
            state
            env
            type-env
            expr
            origin
            expr-ty)]
        [(ErrTcType _)
          (lower-expr-typechecked ctx state env type-env expr origin)])]
    [(AstExprLet bindings body)
      (match (lower-let-bindings ctx state env type-env bindings)
        [(OkLowerEnv binding-state body-env body-type-env)
          (lower-expr ctx binding-state body-env body-type-env body)]
        [(ErrLowerEnv message) (ErrLowerExpr message)])]
    [(AstExprBegin exprs) (lower-begin ctx state env type-env exprs)]
    [(AstExprUnsafe exprs)
      (lower-begin ctx state env (tc-enter-unsafe type-env) exprs)]
    [(AstExprIf cond then-branch else-branch)
      (match (lower-if-result-type-fast ctx env type-env then-branch else-branch)
        [(OkTcType expr-ty)
          (lower-if ctx state env type-env cond then-branch else-branch expr-ty)]
        [(ErrTcType _)
          (lower-expr-typechecked ctx state env type-env expr origin)])]
    [(AstExprMatch scrutinee arms)
      (match (lower-match-result-type-fast ctx env type-env scrutinee arms)
        [(OkTcType expr-ty)
          (lower-match ctx state env type-env scrutinee arms expr-ty)]
        [(ErrTcType _)
          (lower-expr-typechecked ctx state env type-env expr origin)])]
    [_
      (match (lower-expr-result-type-fast ctx env type-env expr)
        [(OkTcType expr-ty)
          (lower-expr-with-type
            ctx
            state
            env
            type-env
            expr
            origin
            expr-ty)]
        [(ErrTcType _)
          (lower-expr-typechecked ctx state env type-env expr origin)])]))

(define (lower-expr
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [expr : AstExpr]) : ResultLowerExpr
  (lower-expr-origin ctx state env type-env expr expr))

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
      (lower-materialize-at-expr state (lower-literal-value lit) expr-ty origin)]
    [(AstExprVar name)
      (lower-var-or-nullary-variant ctx state env type-env name expr-ty)]
    [(AstExprAnn inner _)
      (match (lower-expr-expected ctx state env type-env inner expr-ty origin)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr inner-state value _)
              (OkLowerExpr (LowerExpr inner-state value expr-ty))])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprCast inner _)
      (match (lower-expr ctx state env type-env inner)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr inner-state value inner-ty)
              (OkLowerExpr
                (lower-cast-value inner-state value inner-ty expr-ty))])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprBorrow _ inner)
      (lower-borrow-expr ctx state env type-env inner origin expr-ty)]
    [(AstExprUnary op inner)
      (match (lower-expr ctx state env type-env inner)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr inner-state value _)
              (match (lower-state-alloc-var inner-state)
                [(LowerAlloc allocated var-id)
                  (OkLowerExpr
                    (LowerExpr
                      (lower-state-emit-at-expr
                        allocated
                        (IrInstrUnOp var-id (lower-unop op) value expr-ty)
                        origin)
                      (IrValueVar var-id)
                      expr-ty))])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprBinary op left right)
      ;; `and`/`or` short-circuit: desugar to a conditional branch so the right
      ;; operand is evaluated only when the left does not already decide the
      ;; result, matching the Rust lowerer in `src/lower.rs` (#1132 / #1165):
      ;; `(and a b)` -> `(if a b false)`, `(or a b)` -> `(if a true b)`. Every
      ;; other binop evaluates both operands eagerly into an `IrInstrBinOp`.
      (match op
        [(AstBinAnd)
          (lower-if
            ctx
            state
            env
            type-env
            left
            right
            (AstExprLiteral (AstLitBool false))
            expr-ty)]
        [(AstBinOr)
          (lower-if
            ctx
            state
            env
            type-env
            left
            (AstExprLiteral (AstLitBool true))
            right
            expr-ty)]
        [_
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
                                  (lower-state-emit-at-expr
                                    allocated
                                    (IrInstrBinOp
                                      var-id
                                      (lower-binop op)
                                      left-value
                                      right-value
                                      expr-ty)
                                    origin)
                                  (IrValueVar var-id)
                                  expr-ty))])])]
                    [(ErrLowerExpr message) (ErrLowerExpr message)])])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])])]
    [(AstExprCall func args)
      (lower-call ctx state env type-env func args expr-ty origin)]
    [(AstExprLambda params maybe-ret body)
      (lower-lambda ctx state env type-env params maybe-ret body origin expr-ty)]
    [(AstExprLet bindings body)
      (match (lower-let-bindings ctx state env type-env bindings)
        [(OkLowerEnv binding-state body-env body-type-env)
          (lower-expr ctx binding-state body-env body-type-env body)]
        [(ErrLowerEnv message) (ErrLowerExpr message)])]
    [(AstExprBegin exprs) (lower-begin ctx state env type-env exprs)]
    [(AstExprUnsafe exprs)
      (lower-begin ctx state env (tc-enter-unsafe type-env) exprs)]
    [(AstExprSet name value)
      (match (tc-lookup type-env name)
        [(OkTcType store-ty)
          (let
            [target-ty : AstType
              (tc-type-without-regions (tc-resolve-type ctx store-ty))]
            (match (lower-expr-expected
              ctx
              state
              env
              type-env
              value
              target-ty
              value)
              [(OkLowerExpr lowered)
                (match lowered
                  [(LowerExpr value-state value-ir _)
                    (match (sym-i64-lookup env name)
                      [(SomeI64 id)
                        (OkLowerExpr
                          (LowerExpr
                            (lower-state-emit-at-expr
                              value-state
                              (IrInstrMov id value-ir target-ty)
                              origin)
                            IrValueUnit
                            expr-ty))]
                      [(NoneI64)
                        (OkLowerExpr
                          (LowerExpr
                            (lower-state-emit-at-expr
                              value-state
                              (IrInstrStore
                                (lower-resolve-name value-state name)
                                value-ir
                                target-ty)
                              origin)
                            IrValueUnit
                            expr-ty))])])]
              [(ErrLowerExpr message) (ErrLowerExpr message)]))]
        [(ErrTcType _)
          (ErrLowerExpr
            (lower-diagnostic-at-expr
              origin
              (string-append "lower: assignment to unknown local " name)))])]
    [(AstExprIf cond then-branch else-branch)
      (lower-if ctx state env type-env cond then-branch else-branch expr-ty)]
    [(AstExprWhile cond body) (lower-while ctx state env type-env cond body)]
    [(AstExprForeach index index-ty start end body)
      (lower-foreach ctx state env type-env index index-ty start end body)]
    [(AstExprSpmdReduce op index index-ty start end init value)
      (lower-spmd-reduce
        ctx
        state
        env
        type-env
        op
        index
        index-ty
        start
        end
        init
        value)]
    [(AstExprMatch scrutinee arms)
      (lower-match ctx state env type-env scrutinee arms expr-ty)]
    [(AstExprStringRef str index)
      (lower-string-ref ctx state env type-env str index)]
    [(AstExprStructGet receiver field)
      (lower-struct-get ctx state env type-env receiver field expr-ty)]
    [(AstExprMakeArray elem-ty len)
      (lower-make-array ctx state env type-env elem-ty len)]
    [(AstExprArray values)
      (lower-array-literal ctx state env type-env values expr-ty origin)]
    [(AstExprArrayRef arr index)
      (lower-array-ref ctx state env type-env arr index)]
    [(AstExprArraySet arr index value)
      (lower-array-set ctx state env type-env arr index value)]
    [(AstExprArrayPush arr value)
      (lower-array-push ctx state env type-env arr value)]
    [(AstExprTuple values)
      (lower-tuple ctx state env type-env values expr-ty origin)]
    [(AstExprTupleRef tuple-expr index)
      (lower-tuple-ref ctx state env type-env tuple-expr index expr-ty)]
    [(AstExprWithRegion _ body) (lower-with-arena ctx state env type-env body)]
    [(AstExprWithEscape scratch body)
      (lower-with-escape ctx state env type-env scratch body)]
    [(AstExprWithResource bindings body)
      (lower-with-resource ctx state env type-env bindings body)]
    [(AstExprBox inner) (lower-box ctx state env type-env inner expr-ty)]
    [(AstExprBoxGet inner) (lower-box-get ctx state env type-env inner expr-ty)]
    [(AstExprTry inner) (lower-try ctx state env type-env inner origin)]
    [(AstExprReturn value)
      (lower-return-form ctx state env type-env value origin)]
    ;; `(comptime expr)` folds to a literal via the scalar CTFE evaluator (#719).
    ;; Successful folds reuse the ordinary literal path; CTFE rejections (free
    ;; runtime vars, unsupported forms, f64 -> #735) surface as lower errors.
    [(AstExprComptime inner)
      (match (compiler-ctfe-eval inner (tc-ctfe-env ctx) (ctfe-fuel-limit))
        [(OkCtfe value _)
          (match value
            [(CtfeType ty)
              (ErrLowerExpr
                (lower-diagnostic-at-expr
                  origin
                  (string-append
                    "type value "
                    (string-append
                      (tc-type-render (tc-resolve-type ctx ty))
                      " is compile-time only"))))]
            [(CtfeString _)
              (ErrLowerExpr
                (lower-diagnostic-at-expr
                  origin
                  "String value is compile-time only"))]
            [(CtfeExpr _ _)
              (ErrLowerExpr
                (lower-diagnostic-at-expr
                  origin
                  "Expr value is compile-time only"))]
            [(CtfeExprList _)
              (ErrLowerExpr
                (lower-diagnostic-at-expr
                  origin
                  "ExprList value is compile-time only"))]
            [_
              (lower-materialize
                state
                (lower-literal-value (ctfe-value-to-literal value))
                expr-ty)])]
        [(ErrCtfe diag) (ErrLowerExpr diag)])]
    [(AstExprQuote _)
      (ErrLowerExpr
        (lower-diagnostic-at-expr origin "Expr value is compile-time only"))]
    [(AstExprQuasiquote _)
      (ErrLowerExpr
        (lower-diagnostic-at-expr origin "Expr value is compile-time only"))]
    [(AstExprUnquote _)
      (ErrLowerExpr
        (lower-diagnostic-at-expr
          origin
          "unquote is only valid inside quasiquote"))]
    [(AstExprUnquoteSplicing _)
      (ErrLowerExpr
        (lower-diagnostic-at-expr
          origin
          "unquote-splicing is only valid inside quasiquote"))]
    [(AstExprTypeLiteral ty)
      (ErrLowerExpr
        (lower-diagnostic-at-expr
          origin
          (string-append
            "type value "
            (string-append
              (tc-type-render (tc-resolve-type ctx ty))
              " is compile-time only"))))]
    ;; `(ptr-null : T)` is a pointer-sized zero (pointer ABI size is 8);
    ;; `(ptr-null? p)` is `p == 0` producing a `bool`. No new IR/asm needed.
    [(AstExprPtrNull _)
      (match (lower-materialize state (IrValueI64 0) (AstTyU64))
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr null-state null-value _)
              (OkLowerExpr (LowerExpr null-state null-value expr-ty))])]
        [(ErrLowerExpr diag) (ErrLowerExpr diag)])]
    [(AstExprPtrNullCheck inner)
      (match (lower-expr ctx state env type-env inner)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr inner-state inner-value _)
              (OkLowerExpr
                (lower-emit-binop
                  inner-state
                  IrBinEq
                  inner-value
                  (IrValueI64 0)
                  (AstTyBool)))])]
        [(ErrLowerExpr diag) (ErrLowerExpr diag)])]
    [(AstExprPtrRead ptr)
      (match (lower-expr ctx state env type-env ptr)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr ptr-state ptr-value _)
              (match (lower-state-alloc-var ptr-state)
                [(LowerAlloc allocated var-id)
                  (OkLowerExpr
                    (LowerExpr
                      (lower-state-emit-at-expr
                        allocated
                        (IrInstrLoad var-id ptr-value expr-ty)
                        origin)
                      (IrValueVar var-id)
                      expr-ty))])])]
        [(ErrLowerExpr diag) (ErrLowerExpr diag)])]
    [(AstExprPtrWrite ptr value)
      (match (lower-expr ctx state env type-env ptr)
        [(OkLowerExpr ptr-lowered)
          (match ptr-lowered
            [(LowerExpr ptr-state ptr-value ptr-ty)
              ;; Preserve left-to-right evaluation: the value expression may
              ;; lower to calls or other effects, so keep the pointer in its own
              ;; raw pointer temp before lowering the value.
              (match (lower-state-alloc-var ptr-state)
                [(LowerAlloc ptr-allocated ptr-var)
                  (let
                    [ptr-home-state : LowerState
                      (lower-state-emit
                        ptr-allocated
                        (IrInstrMov
                          ptr-var
                          ptr-value
                          (lower-raw-pointer-ir-type ptr-ty)))]
                    (match (lower-expr ctx ptr-home-state env type-env value)
                      [(OkLowerExpr value-lowered)
                        (match value-lowered
                          [(LowerExpr value-state value-ir value-ty)
                            (OkLowerExpr
                              (LowerExpr
                                (lower-state-emit-at-expr
                                  value-state
                                  (IrInstrStorePtr
                                    (IrValueVar ptr-var)
                                    value-ir
                                    value-ty)
                                  origin)
                                IrValueUnit
                                expr-ty))])]
                      [(ErrLowerExpr diag) (ErrLowerExpr diag)]))])])]
        [(ErrLowerExpr diag) (ErrLowerExpr diag)])]
    [(AstExprPtrOffset ptr offset)
      (match (lower-expr ctx state env type-env ptr)
        [(OkLowerExpr ptr-lowered)
          (match ptr-lowered
            [(LowerExpr ptr-state ptr-value ptr-ty)
              (match (lower-expr ctx ptr-state env type-env offset)
                [(OkLowerExpr offset-lowered)
                  (match offset-lowered
                    [(LowerExpr offset-state offset-value _)
                      (match (tc-type-strip-region (tc-resolve-type ctx ptr-ty))
                        [(AstTyPtr elem-ty)
                          (match (lower-state-alloc-var offset-state)
                            [(LowerAlloc allocated var-id)
                              (OkLowerExpr
                                (LowerExpr
                                  (lower-state-emit-at-expr
                                    allocated
                                    (IrInstrGep
                                      var-id
                                      ptr-value
                                      offset-value
                                      elem-ty)
                                    origin)
                                  (IrValueVar var-id)
                                  expr-ty))])]
                        [(AstTyMutPtr elem-ty)
                          (match (lower-state-alloc-var offset-state)
                            [(LowerAlloc allocated var-id)
                              (OkLowerExpr
                                (LowerExpr
                                  (lower-state-emit-at-expr
                                    allocated
                                    (IrInstrGep
                                      var-id
                                      ptr-value
                                      offset-value
                                      elem-ty)
                                    origin)
                                  (IrValueVar var-id)
                                  expr-ty))])]
                        [_
                          (ErrLowerExpr
                            (lower-diagnostic-at-expr
                              origin
                              "lower: ptr-offset requires raw pointer"))])])]
                [(ErrLowerExpr diag) (ErrLowerExpr diag)])])]
        [(ErrLowerExpr diag) (ErrLowerExpr diag)])]
    [(AstExprPtrCast ptr _)
      (match (lower-expr ctx state env type-env ptr)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr ptr-state ptr-value ptr-ty)
              (OkLowerExpr
                (lower-cast-value ptr-state ptr-value ptr-ty expr-ty))])]
        [(ErrLowerExpr diag) (ErrLowerExpr diag)])]
    [(AstExprPtrToInt ptr)
      (match (lower-expr ctx state env type-env ptr)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr ptr-state ptr-value ptr-ty)
              (OkLowerExpr
                (lower-cast-value ptr-state ptr-value ptr-ty expr-ty))])]
        [(ErrLowerExpr diag) (ErrLowerExpr diag)])]
    [(AstExprIntToPtr value _)
      (match (lower-expr ctx state env type-env value)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr value-state value-ir value-ty)
              (OkLowerExpr
                (lower-cast-value value-state value-ir value-ty expr-ty))])]
        [(ErrLowerExpr diag) (ErrLowerExpr diag)])]
    [_
      (ErrLowerExpr
        (lower-diagnostic-at-expr origin "lower: unsupported expression"))]))

(define (lower-expr-with-type-and-coerce
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [expr : AstExpr]
  [origin : AstExpr]
  [expr-ty : AstType]
  [expected-ty : AstType]) : ResultLowerExpr
  (match (lower-expr-with-type ctx state env type-env expr origin expr-ty)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr next-state value actual-ty)
          (OkLowerExpr
            (lower-coerce-value next-state value actual-ty expected-ty))])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-expr-and-coerce
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [expr : AstExpr]
  [expected-ty : AstType]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env expr)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr next-state value actual-ty)
          (OkLowerExpr
            (lower-coerce-value next-state value actual-ty expected-ty))])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-expr-expected
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [expr : AstExpr]
  [expected-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match expr
    [(AstExprSpanned inner _)
      (lower-expr-expected ctx state env type-env inner expected-ty origin)]
    [(AstExprLiteral lit)
      (lower-materialize-at-expr
        state
        (lower-literal-value lit)
        expected-ty
        origin)]
    [(AstExprLet _ _)
      (lower-expr-with-type-and-coerce
        ctx
        state
        env
        type-env
        expr
        origin
        expected-ty
        expected-ty)]
    [(AstExprBegin _)
      (lower-expr-with-type-and-coerce
        ctx
        state
        env
        type-env
        expr
        origin
        expected-ty
        expected-ty)]
    [(AstExprUnsafe _)
      (lower-expr-with-type-and-coerce
        ctx
        state
        env
        type-env
        expr
        origin
        expected-ty
        expected-ty)]
    [(AstExprIf cond then-branch else-branch)
      (lower-if ctx state env type-env cond then-branch else-branch expected-ty)]
    [(AstExprCall func _)
      (match (ast-expr-unspan func)
        [(AstExprVar name)
          (match (tc-lookup type-env name)
            [(OkTcType fn-ty)
              (match (tc-type-strip-region (tc-resolve-type ctx fn-ty))
                [(AstTyFunc _ ret-ty)
                  (let
                    [actual-ty : AstType
                      (tc-type-without-regions (tc-resolve-type ctx ret-ty))]
                    [expected-resolved : AstType
                      (tc-type-without-regions
                        (tc-resolve-type ctx expected-ty))]
                    (if (tc-type-eq actual-ty expected-resolved)
                      (lower-expr-with-type-and-coerce
                        ctx
                        state
                        env
                        type-env
                        expr
                        origin
                        actual-ty
                        expected-ty)
                      (lower-expr-and-coerce
                        ctx
                        state
                        env
                        type-env
                        expr
                        expected-ty)))]
                [_
                  (lower-expr-and-coerce
                    ctx
                    state
                    env
                    type-env
                    expr
                    expected-ty)])]
            [(ErrTcType _)
              (lower-expr-and-coerce
                ctx
                state
                env
                type-env
                expr
                expected-ty)])]
        [_ (lower-expr-and-coerce ctx state env type-env expr expected-ty)])]
    [_
      (lower-expr-and-coerce ctx state env type-env expr expected-ty)]))

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
              (match (lower-struct-field-info-for-mode
                ctx
                (lower-state-mode receiver-state)
                struct-name
                field)
                [(OkLowerFieldInfo info)
                  (match info
                    [(LowerFieldInfo offset field-ty)
                      (match (lower-gep-byte
                        receiver-state
                        receiver-value
                        offset)
                        [(LowerExpr ptr-state ptr _)
                          (if (and
                            (lower-struct-repr-c? ctx struct-name)
                            (lower-repr-c-inline-field? ctx field-ty))
                            (OkLowerExpr (LowerExpr ptr-state ptr result-ty))
                            (match (lower-state-alloc-var ptr-state)
                              [(LowerAlloc allocated var-id)
                                (OkLowerExpr
                                  (LowerExpr
                                    (lower-state-emit
                                      allocated
                                      (IrInstrLoad var-id ptr field-ty))
                                    (IrValueVar var-id)
                                    result-ty))]))])])]
                [(ErrLowerFieldInfo message) (ErrLowerExpr message)])]
            [_
              (ErrLowerExpr
                (lower-diagnostic-at-expr
                  receiver
                  "lower: struct-get requires struct"))])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

;; Lower `(box expr)` (#1443): evaluate `expr`, reserve arena storage sized for
;; its (pointer-shaped) value via `tl_alloc`, store the value at offset 0, and
;; return the box handle (the storage pointer) typed as the `(Box T)` result.
(define (lower-box
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [inner : AstExpr]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env inner)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr inner-state inner-value inner-ty)
          (match (lower-reserve-heap-storage
            inner-state
            (lower-type-size ctx inner-ty)
            result-ty)
            [(LowerExpr base-state base _)
              (OkLowerExpr
                (LowerExpr
                  (lower-store-at-offset base-state base 0 inner-value inner-ty)
                  base
                  result-ty))])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

;; Lower `(box-get b)` (#1443): evaluate the box handle and load the boxed value
;; of type `T` (the result type) from offset 0 of the box storage.
(define (lower-box-get
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [inner : AstExpr]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env inner)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr box-state box-value _)
          (OkLowerExpr (lower-load-at-offset box-state box-value 0 result-ty))])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

;; Locate the byte offset and resolved type of tuple element `target` within the
;; element-type list, laying fields out exactly like a struct over those types
;; (each field aligned to its own alignment). Mirrors `lower-field-info-from-list`
;; but indexes by position rather than name.
(define (lower-tuple-elem-info
  [ctx : TcContext]
  [types : AstTypeList]
  [target : i64]
  [index : i64]
  [cursor : i64]) : ResultLowerFieldInfo
  (match types
    [(AstTypeNil)
      (ErrLowerFieldInfo
        (lower-diagnostic "lower: tuple-ref index out of range"))]
    [(AstTypeCons ty rest)
      (let
        [resolved : AstType (tc-resolve-type ctx ty)]
        [offset : i64 (lower-align-up cursor (lower-type-align ctx resolved))]
        (if (= index target)
          (OkLowerFieldInfo (LowerFieldInfo offset resolved))
          (lower-tuple-elem-info
            ctx
            rest
            target
            (+ index 1)
            (+ offset (lower-type-size ctx resolved)))))]))

;; Evaluate each tuple element (preserving side effects even for zero-sized
;; elements) and store the sized ones into the aggregate at their field offset,
;; threading the lowering state. Mirrors the per-field store loop of `lower-box`
;; generalized over the element-type list.
(define (lower-tuple-store-elems
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [base : CompilerIrValue]
  [values : AstExprList]
  [types : AstTypeList]
  [cursor : i64]) : ResultLowerState
  (match values
    [(AstExprNil) (OkLowerState state)]
    [(AstExprCons value rest-values)
      (match types
        [(AstTypeNil)
          (ErrLowerState (lower-diagnostic "lower: tuple arity mismatch"))]
        [(AstTypeCons ty rest-types)
          (let
            [resolved : AstType (tc-resolve-type ctx ty)]
            [offset : i64
              (lower-align-up cursor (lower-type-align ctx resolved))]
            [size : i64 (lower-type-size ctx resolved)]
            (match (lower-expr ctx state env type-env value)
              [(OkLowerExpr lowered)
                (match lowered
                  [(LowerExpr elem-state elem-value _)
                    (lower-tuple-store-elems
                      ctx
                      (if (> size 0)
                        (lower-store-at-offset
                          elem-state
                          base
                          offset
                          elem-value
                          resolved)
                        elem-state)
                      env
                      type-env
                      base
                      rest-values
                      rest-types
                      (+ offset size))])]
              [(ErrLowerExpr message) (ErrLowerState message)]))])]))

;; Lower `(tuple v0 v1 ...)`: reserve struct-shaped aggregate storage for the
;; element types, store each element at its field offset, and return the storage
;; pointer typed as the tuple. The tuple value is pointer-shaped (size 8), like a
;; struct/box handle. Mirrors `src/lower.rs` `lower_tuple`.
(define (lower-tuple
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [values : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match (tc-resolve-type ctx result-ty)
    [(AstTyTuple elem-tys)
      (match (lower-reserve-heap-storage
        state
        (lower-type-list-storage-size ctx elem-tys)
        result-ty)
        [(LowerExpr base-state base _)
          (match (lower-tuple-store-elems
            ctx
            base-state
            env
            type-env
            base
            values
            elem-tys
            0)
            [(OkLowerState final-state)
              (OkLowerExpr (LowerExpr final-state base result-ty))]
            [(ErrLowerState message) (ErrLowerExpr message)])])]
    [_
      (ErrLowerExpr
        (lower-diagnostic-at-expr origin "lower: tuple requires tuple type"))]))

;; Evaluate each fixed-array-literal element (preserving side effects even for
;; zero-sized elements) and store the sized ones at `index * elem-size` into the
;; reserved inline storage, threading the lowering state. Mirrors
;; `lower-tuple-store-elems`, specialized to a single homogeneous element type.
(define (lower-array-literal-store-elems
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [base : CompilerIrValue]
  [values : AstExprList]
  [elem-ty : AstType]
  [elem-size : i64]
  [offset : i64]) : ResultLowerState
  (match values
    [(AstExprNil) (OkLowerState state)]
    [(AstExprCons value rest-values)
      (match (lower-expr ctx state env type-env value)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr elem-state elem-value _)
              (lower-array-literal-store-elems
                ctx
                (if (> elem-size 0)
                  (lower-store-at-offset
                    elem-state
                    base
                    offset
                    elem-value
                    elem-ty)
                  elem-state)
                env
                type-env
                base
                rest-values
                elem-ty
                elem-size
                (+ offset elem-size))])]
        [(ErrLowerExpr message) (ErrLowerState message)])]))

;; Lower `(array v0 v1 ...)`: reserve inline storage for `count` elements of the
;; element type, store each element at `index * elem-size`, and return the
;; storage pointer typed as the fixed array. A fixed-array value is pointer-
;; shaped (a pointer to inline storage), matching `array-ref`/`array-set!`, which
;; index off the same base. Mirrors `src/lower.rs` `lower_array_literal`.
(define (lower-array-literal
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [values : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match (tc-resolve-type ctx result-ty)
    [(AstTyArray elem-ty count)
      (let
        [resolved-elem : AstType (tc-resolve-type ctx elem-ty)]
        [elem-size : i64 (lower-type-size ctx elem-ty)]
        [storage-size : i64
          (lower-align-up
            (if (= (* count elem-size) 0)
              1
              (* count elem-size))
            8)]
        (match (lower-reserve-heap-storage state storage-size result-ty)
          [(LowerExpr base-state base _)
            (match (lower-array-literal-store-elems
              ctx
              base-state
              env
              type-env
              base
              values
              resolved-elem
              elem-size
              0)
              [(OkLowerState final-state)
                (OkLowerExpr (LowerExpr final-state base result-ty))]
              [(ErrLowerState message) (ErrLowerExpr message)])]))]
    [_
      (ErrLowerExpr
        (lower-diagnostic-at-expr
          origin
          "lower: array literal requires fixed-array type"))]))

;; Lower `(tuple-ref t i)`: evaluate the tuple, compute element `i`'s offset, and
;; load it (returning the unit value for a zero-sized element, which was never
;; stored). Mirrors `src/lower.rs` `lower_tuple_ref`.
(define (lower-tuple-ref
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [tuple-expr : AstExpr]
  [index : i64]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env tuple-expr)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr tuple-state tuple-value tuple-ty)
          (match (tc-resolve-type ctx tuple-ty)
            [(AstTyTuple elem-tys)
              (match (lower-tuple-elem-info ctx elem-tys index 0 0)
                [(OkLowerFieldInfo info)
                  (match info
                    [(LowerFieldInfo offset elem-ty)
                      (if (> (lower-type-size ctx elem-ty) 0)
                        (match (lower-load-at-offset
                          tuple-state
                          tuple-value
                          offset
                          elem-ty)
                          [(LowerExpr load-state load-value _)
                            (OkLowerExpr
                              (LowerExpr load-state load-value result-ty))])
                        (OkLowerExpr
                          (LowerExpr tuple-state IrValueUnit result-ty)))])]
                [(ErrLowerFieldInfo message) (ErrLowerExpr message)])]
            [_
              (ErrLowerExpr
                (lower-diagnostic-at-expr
                  tuple-expr
                  "lower: tuple-ref requires tuple"))])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-string-ref-byte
  [state : LowerState]
  [data-ptr : CompilerIrValue]
  [index-value : CompilerIrValue]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc gep-alloc gep-var)
      (let
        [gep-state : LowerState
          (lower-state-emit
            gep-alloc
            (IrInstrGep gep-var data-ptr index-value (AstTyChar)))]
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
              (match (lower-state-fresh-label len-u-state "str_bounds_ok")
                [(LowerLabel bounds-ok-state bounds-ok-label)
                  (lower-string-ref-byte
                    (lower-state-emit
                      bounds-ok-state
                      (IrInstrBoundsCheck index-u len-u bounds-ok-label))
                    data-ptr
                    index-value)])])])]))

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
          (if (lower-string-handle-type? ctx str-ty)
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
              [(ErrLowerExpr message) (ErrLowerExpr message)])
            (ErrLowerExpr
              (lower-diagnostic-at-expr str "lower: string-ref requires String")))])]
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
  (let
    [fail-start : LowerState
      (lower-state-finish-block
        (lower-state-emit
          state
          (IrInstrBranch (IrValueVar len-ok-var) copy-label fail-label))
        fail-label)]
    [copy-start : LowerState
      (lower-state-finish-block
        (lower-state-emit (lower-oob-abort fail-start) (IrInstrJump copy-label))
        copy-label)]
    (lower-substring-call-runtime copy-start src-ptr start-value len-value)))

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
      (let
        [rem-state : LowerState
          (lower-state-emit
            rem-alloc
            (IrInstrBinOp rem-var IrBinSub src-len start-value (AstTyI64)))]
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
                    (let
                      [len-ok-state : LowerState
                        (lower-state-emit
                          len-ok-alloc
                          (IrInstrBinOp
                            len-ok-var
                            IrBinLe
                            len-u
                            rem-u
                            (AstTyU64)))]
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
              (let
                [start-ok-state : LowerState
                  (lower-state-emit
                    start-ok-alloc
                    (IrInstrBinOp
                      start-ok-var
                      IrBinLe
                      start-u
                      src-len-u
                      (AstTyU64)))]
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
                            (let
                              [rem-start : LowerState
                                (lower-state-finish-block
                                  (lower-state-emit
                                    copy-label-state
                                    (IrInstrBranch
                                      (IrValueVar start-ok-var)
                                      rem-label
                                      fail-label))
                                  rem-label)]
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
          (if (lower-string-handle-type? ctx str-ty)
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
                  [(ErrLowerExpr message) (ErrLowerExpr message)])])
            (ErrLowerExpr
              (lower-diagnostic-at-expr str "lower: substring requires String")))])]
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
          (if (lower-string-handle-type? ctx left-ty)
            (match (lower-expr ctx left-state env type-env right)
              [(OkLowerExpr lowered-right)
                (match lowered-right
                  [(LowerExpr right-state right-value right-ty)
                    (if (lower-string-handle-type? ctx right-ty)
                      (match (lower-string-fields right-state left-value)
                        [(LowerStringFields left-fields-state left-ptr left-len)
                          (match (lower-string-fields
                            left-fields-state
                            right-value)
                            [(LowerStringFields
                                done-fields-state
                                right-ptr
                                right-len)
                              (match (lower-state-alloc-var done-fields-state)
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
                                      (AstTyString)))])])])
                      (ErrLowerExpr
                        (lower-diagnostic-at-expr
                          right
                          "lower: string-concat requires String")))])]
              [(ErrLowerExpr message) (ErrLowerExpr message)])
            (ErrLowerExpr
              (lower-diagnostic-at-expr
                left
                "lower: string-concat requires String")))])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-direct-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match (match (tc-lookup type-env name)
    [(OkTcType fn-ty)
      (match (tc-type-strip-region (tc-resolve-type ctx fn-ty))
        [(AstTyFunc param-types _)
          (lower-args-as
            ctx
            state
            env
            type-env
            args
            (tc-resolve-type-list ctx param-types))]
        [_ (lower-args ctx state env type-env args)])]
    [(ErrTcType _) (lower-args ctx state env type-env args)])
    [(OkLowerArgs args-state values)
      (match (lower-state-alloc-var args-state)
        [(LowerAlloc allocated var-id)
          (let
            [instr : CompilerIrInstr
              (IrInstrCall
                var-id
                (lower-resolve-call-name allocated env name)
                values
                result-ty)]
            (OkLowerExpr
              (LowerExpr
                (lower-state-emit-at-expr allocated instr origin)
                (IrValueVar var-id)
                result-ty)))])]
    [(ErrLowerArgs message) (ErrLowerExpr message)]))

(define (lower-indirect-call-values
  [state : LowerState]
  [func-value : CompilerIrValue]
  [values : CompilerIrValueList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc allocated var-id)
      (let
        [instr : CompilerIrInstr
          (IrInstrCallIndirect var-id func-value values result-ty)]
        (OkLowerExpr
          (LowerExpr
            (lower-state-emit-at-expr allocated instr origin)
            (IrValueVar var-id)
            result-ty)))]))

(define (lower-indirect-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [func-value : CompilerIrValue]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match (lower-args ctx state env type-env args)
    [(OkLowerArgs args-state values)
      (lower-indirect-call-values args-state func-value values result-ty origin)]
    [(ErrLowerArgs message) (ErrLowerExpr message)]))

(define (lower-substring-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons str (AstExprCons start (AstExprCons len (AstExprNil))))
      (lower-substring ctx state env type-env str start len)]
    [_ (lower-direct-call ctx state env type-env name args result-ty origin)]))

(define (lower-string-concat-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons left (AstExprCons right (AstExprNil)))
      (lower-string-concat ctx state env type-env left right)]
    [_ (lower-direct-call ctx state env type-env name args result-ty origin)]))

(define (lower-string-runtime-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (if (or (string-eq name "substring") (string-eq name "string-slice"))
    (lower-substring-call ctx state env type-env name args result-ty origin)
    (lower-string-concat-call ctx state env type-env name args result-ty origin)))

(define (lower-runtime-call-values
  [state : LowerState]
  [name : String]
  [values : CompilerIrValueList]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc allocated var-id)
      (OkLowerExpr
        (LowerExpr
          (lower-state-emit
            allocated
            (IrInstrCall var-id name values result-ty))
          (IrValueVar var-id)
          result-ty))]))

(define (lower-one-arg-runtime-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [fallback-name : String]
  [runtime-name : String]
  [expected-ty : AstType]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons arg (AstExprNil))
      (match (lower-expr ctx state env type-env arg)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr arg-state arg-value arg-ty)
              (match (lower-cast-value arg-state arg-value arg-ty expected-ty)
                [(LowerExpr cast-state cast-value _)
                  (lower-runtime-call-values
                    cast-state
                    runtime-name
                    (IrValueCons cast-value IrValueNil)
                    result-ty)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        fallback-name
        args
        result-ty
        origin)]))

(define (lower-one-string-runtime-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [arg : AstExpr]
  [runtime-name : String]
  [result-ty : AstType]
  [message : String]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env arg)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr arg-state arg-value arg-ty)
          (if (lower-string-handle-type? ctx arg-ty)
            (match (lower-string-fields arg-state arg-value)
              [(LowerStringFields fields-state ptr len)
                (lower-runtime-call-values
                  fields-state
                  runtime-name
                  (IrValueCons ptr (IrValueCons len IrValueNil))
                  result-ty)])
            (ErrLowerExpr (lower-diagnostic-at-expr arg message)))])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-two-string-runtime-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [left : AstExpr]
  [right : AstExpr]
  [runtime-name : String]
  [result-ty : AstType]
  [message : String]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env left)
    [(OkLowerExpr lowered-left)
      (match lowered-left
        [(LowerExpr left-state left-value left-ty)
          (if (lower-string-handle-type? ctx left-ty)
            (match (lower-expr ctx left-state env type-env right)
              [(OkLowerExpr lowered-right)
                (match lowered-right
                  [(LowerExpr right-state right-value right-ty)
                    (if (lower-string-handle-type? ctx right-ty)
                      (match (lower-string-fields right-state left-value)
                        [(LowerStringFields left-fields-state left-ptr left-len)
                          (match (lower-string-fields
                            left-fields-state
                            right-value)
                            [(LowerStringFields
                                done-fields-state
                                right-ptr
                                right-len)
                              (lower-runtime-call-values
                                done-fields-state
                                runtime-name
                                (IrValueCons
                                  left-ptr
                                  (IrValueCons
                                    left-len
                                    (IrValueCons
                                      right-ptr
                                      (IrValueCons right-len IrValueNil))))
                                result-ty)])])
                      (ErrLowerExpr (lower-diagnostic-at-expr right message)))])]
              [(ErrLowerExpr message) (ErrLowerExpr message)])
            (ErrLowerExpr (lower-diagnostic-at-expr left message)))])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-string-to-int-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons arg (AstExprNil))
      (lower-one-string-runtime-call
        ctx
        state
        env
        type-env
        arg
        "tl_string_to_int"
        result-ty
        "lower: string->int requires String")]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "string->int"
        args
        result-ty
        origin)]))

(define (lower-int-to-string-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons arg (AstExprNil))
      (match (lower-expr ctx state env type-env arg)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr arg-state arg-value arg-ty)
              (match (lower-cast-value arg-state arg-value arg-ty (AstTyI64))
                [(LowerExpr cast-state cast-value _)
                  (lower-runtime-call-values
                    cast-state
                    "tl_int_to_string"
                    (IrValueCons cast-value IrValueNil)
                    result-ty)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "int->string"
        args
        result-ty
        origin)]))

;; A single newline byte, produced as an embedded string literal (the lexer has
;; no `\n` escape, so the backend uses embedded newlines the same way for its
;; emitted assembly). Used to terminate the line printed by the `print` builtin.
(define (lower-print-newline-text) : String
  "
")

;; The bare `print` builtin (i64 -> unit) has no dedicated runtime symbol of its
;; own; lower it to the already-supported `(print-string (int->string n))`
;; followed by a trailing newline (`print` always ends the line). Both halves
;; reuse the proven int->string / print-string runtime paths via `lower-expr`,
;; which re-typechecks the synthesized calls, so no new codegen is introduced.
(define (lower-print-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons number-arg (AstExprNil))
      (match (lower-expr
        ctx
        state
        env
        type-env
        (AstExprCall
          (AstExprVar "print-string")
          (AstExprCons
            (AstExprCall
              (AstExprVar "int->string")
              (AstExprCons number-arg AstExprNil))
            AstExprNil)))
        [(OkLowerExpr decimal-printed)
          (match decimal-printed
            [(LowerExpr decimal-state _ _)
              (lower-expr
                ctx
                decimal-state
                env
                type-env
                (AstExprCall
                  (AstExprVar "print-string")
                  (AstExprCons
                    (AstExprLiteral (AstLitString (lower-print-newline-text)))
                    AstExprNil)))])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [_ (lower-direct-call ctx state env type-env "print" args result-ty origin)]))

;; `(print-newline)` writes a single newline; lower it to `(print-string
;; <newline>)`, reusing the existing string runtime path (no dedicated runtime).
(define (lower-print-newline-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprNil)
      (lower-expr
        ctx
        state
        env
        type-env
        (AstExprCall
          (AstExprVar "print-string")
          (AstExprCons
            (AstExprLiteral (AstLitString (lower-print-newline-text)))
            AstExprNil)))]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "print-newline"
        args
        result-ty
        origin)]))

;; `(print-bool b)` writes `true`/`false` followed by a newline (matching the
;; print family's line-terminating behavior). Lower it to a conditional pair of
;; `print-string` calls plus the shared newline, all proven runtime paths.
(define (lower-print-bool-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons flag (AstExprNil))
      (match (lower-if
        ctx
        state
        env
        type-env
        flag
        (AstExprCall
          (AstExprVar "print-string")
          (AstExprCons (AstExprLiteral (AstLitString "true")) AstExprNil))
        (AstExprCall
          (AstExprVar "print-string")
          (AstExprCons (AstExprLiteral (AstLitString "false")) AstExprNil))
        (AstTyUnit))
        [(OkLowerExpr word-printed)
          (match word-printed
            [(LowerExpr word-state _ _)
              (lower-expr
                ctx
                word-state
                env
                type-env
                (AstExprCall
                  (AstExprVar "print-string")
                  (AstExprCons
                    (AstExprLiteral (AstLitString (lower-print-newline-text)))
                    AstExprNil)))])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "print-bool"
        args
        result-ty
        origin)]))

(define (lower-arg-count-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprNil)
      (lower-runtime-call-values state ".L_tl_arg_count" IrValueNil result-ty)]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "arg-count"
        args
        result-ty
        origin)]))

(define (lower-arg-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons arg (AstExprNil))
      (match (lower-expr ctx state env type-env arg)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr arg-state arg-value arg-ty)
              (match (lower-cast-value arg-state arg-value arg-ty (AstTyI64))
                [(LowerExpr cast-state cast-value _)
                  (lower-runtime-call-values
                    cast-state
                    ".L_tl_arg"
                    (IrValueCons cast-value IrValueNil)
                    result-ty)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [_ (lower-direct-call ctx state env type-env "arg" args result-ty origin)]))

(define (lower-read-file-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons arg (AstExprNil))
      (lower-one-string-runtime-call
        ctx
        state
        env
        type-env
        arg
        ".L_tl_read_file"
        result-ty
        "lower: read-file requires String")]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "read-file"
        args
        result-ty
        origin)]))

(define (lower-read-file-status-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons arg (AstExprNil))
      (lower-one-string-runtime-call
        ctx
        state
        env
        type-env
        arg
        ".L_tl_read_file_status"
        result-ty
        "lower: read-file-status requires String")]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "read-file-status"
        args
        result-ty
        origin)]))

(define (lower-file-exists-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons arg (AstExprNil))
      (lower-one-string-runtime-call
        ctx
        state
        env
        type-env
        arg
        ".L_tl_file_exists"
        result-ty
        "lower: file-exists? requires String")]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "file-exists?"
        args
        result-ty
        origin)]))

(define (lower-file-exists-status-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons arg (AstExprNil))
      (lower-one-string-runtime-call
        ctx
        state
        env
        type-env
        arg
        ".L_tl_file_exists_status"
        result-ty
        "lower: file-exists-status requires String")]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "file-exists-status"
        args
        result-ty
        origin)]))

(define (lower-fs-path-status-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [runtime-name : String]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons arg (AstExprNil))
      (lower-one-string-runtime-call
        ctx
        state
        env
        type-env
        arg
        runtime-name
        result-ty
        (string-append (string-append "lower: " name) " requires String"))]
    [_ (lower-direct-call ctx state env type-env name args result-ty origin)]))

(define (lower-fs-rename-status-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons source (AstExprCons destination (AstExprNil)))
      (lower-two-string-runtime-call
        ctx
        state
        env
        type-env
        source
        destination
        ".L_tl_fs_rename_status"
        result-ty
        "lower: fs-rename-status requires String")]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "fs-rename-status"
        args
        result-ty
        origin)]))

(define (lower-fs-process-id-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprNil)
      (lower-runtime-call-values
        state
        ".L_tl_fs_process_id"
        IrValueNil
        result-ty)]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "fs-process-id"
        args
        result-ty
        origin)]))

(define (lower-fs-current-dir-status-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprNil)
      (lower-runtime-call-values
        state
        "tl_fs_current_dir_status"
        IrValueNil
        result-ty)]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "fs-current-dir-status"
        args
        result-ty
        origin)]))

(define (lower-fs-current-dir-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprNil)
      (lower-runtime-call-values state "tl_fs_current_dir" IrValueNil result-ty)]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "fs-current-dir"
        args
        result-ty
        origin)]))

(define (lower-file-open-status-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons path (AstExprCons mode (AstExprNil)))
      (match (lower-expr ctx state env type-env path)
        [(OkLowerExpr lowered-path)
          (match lowered-path
            [(LowerExpr path-state path-value _)
              (match (lower-expr ctx path-state env type-env mode)
                [(OkLowerExpr lowered-mode)
                  (match lowered-mode
                    [(LowerExpr mode-state mode-value mode-ty)
                      (match (lower-cast-value
                        mode-state
                        mode-value
                        mode-ty
                        (AstTyI64))
                        [(LowerExpr cast-state cast-value _)
                          (match (lower-string-fields cast-state path-value)
                            [(LowerStringFields fields-state ptr len)
                              (lower-runtime-call-values
                                fields-state
                                ".L_tl_file_open_status"
                                (IrValueCons
                                  ptr
                                  (IrValueCons
                                    len
                                    (IrValueCons cast-value IrValueNil)))
                                result-ty)])])])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "file-open-status"
        args
        result-ty
        origin)]))

(define (lower-file-close-status-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons handle (AstExprNil))
      (match (lower-expr ctx state env type-env handle)
        [(OkLowerExpr lowered-handle)
          (match lowered-handle
            [(LowerExpr handle-state handle-value handle-ty)
              (match (lower-cast-value
                handle-state
                handle-value
                handle-ty
                (AstTyI64))
                [(LowerExpr cast-state cast-value _)
                  (lower-runtime-call-values
                    cast-state
                    ".L_tl_file_close_status"
                    (IrValueCons cast-value IrValueNil)
                    result-ty)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "file-close-status"
        args
        result-ty
        origin)]))

(define (lower-file-read-chunk-status-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons handle (AstExprCons count (AstExprNil)))
      (match (lower-expr ctx state env type-env handle)
        [(OkLowerExpr lowered-handle)
          (match lowered-handle
            [(LowerExpr handle-state handle-value handle-ty)
              (match (lower-cast-value
                handle-state
                handle-value
                handle-ty
                (AstTyI64))
                [(LowerExpr handle-cast-state handle-cast-value _)
                  (match (lower-expr ctx handle-cast-state env type-env count)
                    [(OkLowerExpr lowered-count)
                      (match lowered-count
                        [(LowerExpr count-state count-value count-ty)
                          (match (lower-cast-value
                            count-state
                            count-value
                            count-ty
                            (AstTyI64))
                            [(LowerExpr cast-state count-cast-value _)
                              (lower-runtime-call-values
                                cast-state
                                ".L_tl_file_read_chunk_status"
                                (IrValueCons
                                  handle-cast-value
                                  (IrValueCons count-cast-value IrValueNil))
                                result-ty)])])]
                    [(ErrLowerExpr message) (ErrLowerExpr message)])])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "file-read-chunk-status"
        args
        result-ty
        origin)]))

(define (lower-file-write-status-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons handle (AstExprCons contents (AstExprNil)))
      (match (lower-expr ctx state env type-env handle)
        [(OkLowerExpr lowered-handle)
          (match lowered-handle
            [(LowerExpr handle-state handle-value handle-ty)
              (match (lower-cast-value
                handle-state
                handle-value
                handle-ty
                (AstTyI64))
                [(LowerExpr handle-cast-state handle-cast-value _)
                  (match (lower-expr
                    ctx
                    handle-cast-state
                    env
                    type-env
                    contents)
                    [(OkLowerExpr lowered-contents)
                      (match lowered-contents
                        [(LowerExpr contents-state contents-value _)
                          (match (lower-string-fields
                            contents-state
                            contents-value)
                            [(LowerStringFields fields-state ptr len)
                              (lower-runtime-call-values
                                fields-state
                                ".L_tl_file_write_status"
                                (IrValueCons
                                  handle-cast-value
                                  (IrValueCons ptr (IrValueCons len IrValueNil)))
                                result-ty)])])]
                    [(ErrLowerExpr message) (ErrLowerExpr message)])])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "file-write-status"
        args
        result-ty
        origin)]))

(define (lower-file-flush-status-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons handle (AstExprNil))
      (match (lower-expr ctx state env type-env handle)
        [(OkLowerExpr lowered-handle)
          (match lowered-handle
            [(LowerExpr handle-state handle-value handle-ty)
              (match (lower-cast-value
                handle-state
                handle-value
                handle-ty
                (AstTyI64))
                [(LowerExpr cast-state cast-value _)
                  (lower-runtime-call-values
                    cast-state
                    ".L_tl_file_flush_status"
                    (IrValueCons cast-value IrValueNil)
                    result-ty)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "file-flush-status"
        args
        result-ty
        origin)]))

(define (lower-file-read-chunk-field-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [fallback-name : String]
  [runtime-name : String]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons handle (AstExprNil))
      (match (lower-expr ctx state env type-env handle)
        [(OkLowerExpr lowered-handle)
          (match lowered-handle
            [(LowerExpr handle-state handle-value handle-ty)
              (match (lower-cast-value
                handle-state
                handle-value
                handle-ty
                (AstTyI64))
                [(LowerExpr cast-state cast-value _)
                  (lower-runtime-call-values
                    cast-state
                    runtime-name
                    (IrValueCons cast-value IrValueNil)
                    result-ty)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        fallback-name
        args
        result-ty
        origin)]))

(define (lower-message-runtime-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [fallback-name : String]
  [runtime-name : String]
  [result-ty : AstType]
  [message : String]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons arg (AstExprNil))
      (lower-one-string-runtime-call
        ctx
        state
        env
        type-env
        arg
        runtime-name
        result-ty
        message)]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        fallback-name
        args
        result-ty
        origin)]))

(define (lower-string-eq-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons left (AstExprCons right (AstExprNil)))
      (match (lower-expr ctx state env type-env left)
        [(OkLowerExpr lowered-left)
          (match lowered-left
            [(LowerExpr left-state left-value _)
              (match (lower-expr ctx left-state env type-env right)
                [(OkLowerExpr lowered-right)
                  (match lowered-right
                    [(LowerExpr right-state right-value _)
                      (match (lower-string-fields right-state left-value)
                        [(LowerStringFields left-fields-state left-ptr left-len)
                          (match (lower-string-fields
                            left-fields-state
                            right-value)
                            [(LowerStringFields
                                done-fields-state
                                right-ptr
                                right-len)
                              (lower-runtime-call-values
                                done-fields-state
                                "tl_string_eq"
                                (IrValueCons
                                  left-ptr
                                  (IrValueCons
                                    left-len
                                    (IrValueCons
                                      right-ptr
                                      (IrValueCons right-len IrValueNil))))
                                result-ty)])])])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "string-eq"
        args
        result-ty
        origin)]))

(define (lower-write-file-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons path (AstExprCons contents (AstExprNil)))
      (match (lower-expr ctx state env type-env path)
        [(OkLowerExpr lowered-path)
          (match lowered-path
            [(LowerExpr path-state path-value _)
              (match (lower-expr ctx path-state env type-env contents)
                [(OkLowerExpr lowered-contents)
                  (match lowered-contents
                    [(LowerExpr contents-state contents-value _)
                      (match (lower-string-fields contents-state path-value)
                        [(LowerStringFields path-fields-state path-ptr path-len)
                          (match (lower-string-fields
                            path-fields-state
                            contents-value)
                            [(LowerStringFields
                                done-fields-state
                                contents-ptr
                                contents-len)
                              (lower-runtime-call-values
                                done-fields-state
                                ".L_tl_write_file"
                                (IrValueCons
                                  path-ptr
                                  (IrValueCons
                                    path-len
                                    (IrValueCons
                                      contents-ptr
                                      (IrValueCons contents-len IrValueNil))))
                                result-ty)])])])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "write-file"
        args
        result-ty
        origin)]))

(define (lower-write-file-status-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons path (AstExprCons contents (AstExprNil)))
      (match (lower-expr ctx state env type-env path)
        [(OkLowerExpr lowered-path)
          (match lowered-path
            [(LowerExpr path-state path-value _)
              (match (lower-expr ctx path-state env type-env contents)
                [(OkLowerExpr lowered-contents)
                  (match lowered-contents
                    [(LowerExpr contents-state contents-value _)
                      (match (lower-string-fields contents-state path-value)
                        [(LowerStringFields path-fields-state path-ptr path-len)
                          (match (lower-string-fields
                            path-fields-state
                            contents-value)
                            [(LowerStringFields
                                done-fields-state
                                contents-ptr
                                contents-len)
                              (lower-runtime-call-values
                                done-fields-state
                                ".L_tl_write_file_status"
                                (IrValueCons
                                  path-ptr
                                  (IrValueCons
                                    path-len
                                    (IrValueCons
                                      contents-ptr
                                      (IrValueCons contents-len IrValueNil))))
                                result-ty)])])])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "write-file-status"
        args
        result-ty
        origin)]))

(define (lower-append-file-status-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons path (AstExprCons contents (AstExprNil)))
      (match (lower-expr ctx state env type-env path)
        [(OkLowerExpr lowered-path)
          (match lowered-path
            [(LowerExpr path-state path-value _)
              (match (lower-expr ctx path-state env type-env contents)
                [(OkLowerExpr lowered-contents)
                  (match lowered-contents
                    [(LowerExpr contents-state contents-value _)
                      (match (lower-string-fields contents-state path-value)
                        [(LowerStringFields path-fields-state path-ptr path-len)
                          (match (lower-string-fields
                            path-fields-state
                            contents-value)
                            [(LowerStringFields
                                done-fields-state
                                contents-ptr
                                contents-len)
                              (lower-runtime-call-values
                                done-fields-state
                                ".L_tl_append_file_status"
                                (IrValueCons
                                  path-ptr
                                  (IrValueCons
                                    path-len
                                    (IrValueCons
                                      contents-ptr
                                      (IrValueCons contents-len IrValueNil))))
                                result-ty)])])])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [_
      (lower-direct-call
        ctx
        state
        env
        type-env
        "append-file-status"
        args
        result-ty
        origin)]))

(define (lower-bootstrap-runtime-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (cond
    [(or (string-eq name "string-eq") (string-eq name "string=?"))
      (lower-string-eq-call ctx state env type-env args result-ty origin)]
    [(string-eq name "string->int")
      (lower-string-to-int-call ctx state env type-env args result-ty origin)]
    [(string-eq name "int->string")
      (lower-int-to-string-call ctx state env type-env args result-ty origin)]
    [(string-eq name "arg-count")
      (lower-arg-count-call ctx state env type-env args result-ty origin)]
    [(string-eq name "arg")
      (lower-arg-call ctx state env type-env args result-ty origin)]
    [(string-eq name "read-file")
      (lower-read-file-call ctx state env type-env args result-ty origin)]
    [(string-eq name "read-file-status")
      (lower-read-file-status-call ctx state env type-env args result-ty origin)]
    [(string-eq name "write-file")
      (lower-write-file-call ctx state env type-env args result-ty origin)]
    [(string-eq name "write-file-status")
      (lower-write-file-status-call
        ctx
        state
        env
        type-env
        args
        result-ty
        origin)]
    [(string-eq name "append-file-status")
      (lower-append-file-status-call
        ctx
        state
        env
        type-env
        args
        result-ty
        origin)]
    [(string-eq name "file-exists?")
      (lower-file-exists-call ctx state env type-env args result-ty origin)]
    [(string-eq name "file-exists-status")
      (lower-file-exists-status-call
        ctx
        state
        env
        type-env
        args
        result-ty
        origin)]
    [(string-eq name "file-open-status")
      (lower-file-open-status-call ctx state env type-env args result-ty origin)]
    [(string-eq name "file-close-status")
      (lower-file-close-status-call
        ctx
        state
        env
        type-env
        args
        result-ty
        origin)]
    [(string-eq name "file-read-chunk-status")
      (lower-file-read-chunk-status-call
        ctx
        state
        env
        type-env
        args
        result-ty
        origin)]
    [(string-eq name "file-write-status")
      (lower-file-write-status-call
        ctx
        state
        env
        type-env
        args
        result-ty
        origin)]
    [(string-eq name "file-flush-status")
      (lower-file-flush-status-call
        ctx
        state
        env
        type-env
        args
        result-ty
        origin)]
    [(string-eq name "file-read-chunk-bytes")
      (lower-file-read-chunk-field-call
        ctx
        state
        env
        type-env
        args
        "file-read-chunk-bytes"
        ".L_tl_file_read_chunk_bytes"
        result-ty
        origin)]
    [(string-eq name "file-read-chunk-eof?")
      (lower-file-read-chunk-field-call
        ctx
        state
        env
        type-env
        args
        "file-read-chunk-eof?"
        ".L_tl_file_read_chunk_eof"
        result-ty
        origin)]
    [(string-eq name "fs-mkdir-status")
      (lower-fs-path-status-call
        ctx
        state
        env
        type-env
        name
        ".L_tl_fs_mkdir_status"
        args
        result-ty
        origin)]
    [(string-eq name "fs-remove-file-status")
      (lower-fs-path-status-call
        ctx
        state
        env
        type-env
        name
        ".L_tl_fs_remove_file_status"
        args
        result-ty
        origin)]
    [(string-eq name "fs-remove-dir-status")
      (lower-fs-path-status-call
        ctx
        state
        env
        type-env
        name
        ".L_tl_fs_remove_dir_status"
        args
        result-ty
        origin)]
    [(string-eq name "fs-rename-status")
      (lower-fs-rename-status-call ctx state env type-env args result-ty origin)]
    [(string-eq name "fs-process-id")
      (lower-fs-process-id-call ctx state env type-env args result-ty origin)]
    [(string-eq name "fs-current-dir-status")
      (lower-fs-current-dir-status-call
        ctx
        state
        env
        type-env
        args
        result-ty
        origin)]
    [(string-eq name "fs-current-dir")
      (lower-fs-current-dir-call ctx state env type-env args result-ty origin)]
    [(or (string-eq name "panic") (string-eq name "error"))
      (lower-message-runtime-call
        ctx
        state
        env
        type-env
        args
        name
        ".L_tl_abort"
        result-ty
        "lower: panic requires String"
        origin)]
    [else
      (lower-message-runtime-call
        ctx
        state
        env
        type-env
        args
        "print-error"
        "tl_print_err"
        result-ty
        "lower: print-error requires String"
        origin)]))

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
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons str (AstExprCons index (AstExprNil)))
      (lower-string-ref ctx state env type-env str index)]
    [_ (lower-direct-call ctx state env type-env name args result-ty origin)]))

(define (lower-module-lookup-name [ctx : TcContext] [name : String]) : String
  (let
    [module : String (tc-context-module ctx)]
    (if (and (> (string-length module) 0) (not (tc-name-qualified? name)))
      (compiler-symbol-module-key module name)
      name)))

(define (lower-call-name-matches-nominal?
  [ctx : TcContext]
  [name : String]
  [nominal-name : String]) : bool
  (if (tc-name-qualified? name)
    (string-eq name nominal-name)
    (and
      (string-eq
        (tc-qualified-name-module nominal-name)
        (tc-context-module ctx))
      (string-eq name (tc-qualified-name-base nominal-name)))))

(define (lower-variant-constructor-lookup-name
  [ctx : TcContext]
  [name : String]
  [result-ty : AstType]) : String
  (match (tc-type-strip-region result-ty)
    [(AstTyEnum enum-name)
      (if (or
        (tc-name-qualified? name)
        (string-eq (tc-qualified-name-module enum-name) (tc-context-module ctx)))
        (tc-variant-name-for-enum enum-name name)
        (lower-module-lookup-name ctx name))]
    [_ (lower-module-lookup-name ctx name)]))

(define (lower-call-non-builtin
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match (sym-i64-lookup env name)
    [(SomeI64 _)
      (lower-direct-call ctx state env type-env name args result-ty origin)]
    [(NoneI64)
      (let
        [symbols : CompilerSymbols (tc-context-symbols ctx)]
        [registries : CompilerRegistries (tc-context-registries ctx)]
        [variant-name : String
          (lower-variant-constructor-lookup-name ctx name result-ty)]
        [struct-name : String
          (match (tc-type-strip-region result-ty)
            [(AstTyStruct resolved-struct)
              (if (lower-call-name-matches-nominal? ctx name resolved-struct)
                resolved-struct
                (lower-module-lookup-name ctx name))]
            [_ (lower-module-lookup-name ctx name)])]
        (match (compiler-registries-lookup-variant registries variant-name)
          [(SomeI64 handle)
            (lower-construct-enum-with-handle
              ctx
              state
              env
              type-env
              variant-name
              handle
              args
              result-ty)]
          [(NoneI64)
            (match (compiler-symbols-lookup-type symbols struct-name)
              [(SomeI64 handle)
                (if (=
                  (compiler-symbol-handle-kind handle)
                  (compiler-symbol-kind-defstruct))
                  (lower-construct-struct
                    ctx
                    state
                    env
                    type-env
                    struct-name
                    args
                    result-ty)
                  (lower-direct-call
                    ctx
                    state
                    env
                    type-env
                    name
                    args
                    result-ty
                    origin))]
              [(NoneI64)
                (lower-direct-call
                  ctx
                  state
                  env
                  type-env
                  name
                  args
                  result-ty
                  origin)])]))]))

(define (lower-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [func : AstExpr]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match (ast-expr-unspan func)
    [(AstExprVar name)
      (match (sym-i64-lookup env name)
        [(SomeI64 local-id)
          (match (tc-expr ctx type-env func)
            [(OkTcType fn-ty)
              (if (lower-function-type? fn-ty)
                (lower-indirect-call
                  ctx
                  state
                  env
                  type-env
                  (IrValueVar local-id)
                  args
                  result-ty
                  origin)
                (ErrLowerExpr
                  (lower-diagnostic-at-expr
                    func
                    "lower: call target is not a function")))]
            [(ErrTcType message)
              (ErrLowerExpr (lower-diagnostic-at-expr func message))])]
        [(NoneI64)
          ;; `array-length`/`length` on a dynamic array, and
          ;; `string-length`/`length` on a String, load the fat value's length
          ;; field directly instead of calling a runtime symbol (#528, #527).
          ;; Other `length` argument types keep the ordinary direct-call path.
          ;; `string-ref`/`char-at` likewise recover their String byte-index
          ;; builtin here unless shadowed (#677).
          (cond
            [(and
                (lower-builtin-call-available? ctx env name)
                (tc-layout-query-name? name))
              (ErrLowerExpr
                (lower-diagnostic-at-expr
                  origin
                  (string-append
                    "lower: "
                    (string-append
                      name
                      " is compile-time only; wrap it in (comptime ...)"))))]
            [(and
                (lower-builtin-call-available? ctx env name)
                (or (string-eq name "string-ref") (string-eq name "char-at")))
              (lower-string-ref-call
                ctx
                state
                env
                type-env
                name
                args
                result-ty
                origin)]
            [(and
                (lower-builtin-call-available? ctx env name)
                (or
                  (string-eq name "array-length")
                  (or
                    (string-eq name "length")
                    (string-eq name "string-length"))))
              (lower-array-length
                ctx
                state
                env
                type-env
                name
                args
                result-ty
                origin)]
            [(and
                (lower-builtin-call-available? ctx env name)
                (lower-string-runtime-builtin? name))
              (lower-string-runtime-call
                ctx
                state
                env
                type-env
                name
                args
                result-ty
                origin)]
            [(and
                (lower-builtin-call-available? ctx env name)
                (lower-stdio-builtin? name))
              (lower-direct-call
                ctx
                state
                env
                type-env
                (lower-stdio-runtime-name name)
                args
                result-ty
                origin)]
            [(and
                (lower-builtin-call-available? ctx env name)
                (lower-print-string-builtin? name))
              (lower-message-runtime-call
                ctx
                state
                env
                type-env
                args
                name
                "tl_print_str"
                result-ty
                "lower: print-string requires String"
                origin)]
            [(and
                (lower-builtin-call-available? ctx env name)
                (string-eq name "print-char"))
              (lower-one-arg-runtime-call
                ctx
                state
                env
                type-env
                args
                "print-char"
                "tl_print_char"
                (AstTyChar)
                result-ty
                origin)]
            [(and
                (lower-builtin-call-available? ctx env name)
                (string-eq name "print-float"))
              (lower-one-arg-runtime-call
                ctx
                state
                env
                type-env
                args
                "print-float"
                "tl_print_f64"
                (AstTyF64)
                result-ty
                origin)]
            [(and
                (lower-builtin-call-available? ctx env name)
                (string-eq name "print"))
              (lower-print-call ctx state env type-env args result-ty origin)]
            [(and
                (lower-builtin-call-available? ctx env name)
                (string-eq name "print-newline"))
              (lower-print-newline-call
                ctx
                state
                env
                type-env
                args
                result-ty
                origin)]
            [(and
                (lower-builtin-call-available? ctx env name)
                (string-eq name "print-bool"))
              (lower-print-bool-call
                ctx
                state
                env
                type-env
                args
                result-ty
                origin)]
            [(and
                (lower-builtin-call-available? ctx env name)
                (string-eq name "clone"))
              (match args
                [(AstExprCons arg (AstExprNil))
                  (lower-clone-call ctx state env type-env arg)]
                [_
                  (ErrLowerExpr
                    (lower-diagnostic "lower: clone expects one argument"))])]
            [(and
                (lower-builtin-call-available? ctx env name)
                (lower-arena-builtin? name))
              (lower-arena-builtin-call
                ctx
                state
                env
                type-env
                name
                args
                result-ty)]
            [(and
                (lower-builtin-call-available? ctx env name)
                (lower-profile-builtin? name))
              (lower-profile-builtin-call state name args result-ty)]
            [(and
                (lower-builtin-call-available? ctx env name)
                (lower-bootstrap-runtime-builtin? name))
              (lower-bootstrap-runtime-call
                ctx
                state
                env
                type-env
                name
                args
                result-ty
                origin)]
            [else
              (lower-call-non-builtin
                ctx
                state
                env
                type-env
                name
                args
                result-ty
                origin)])])]
    [_
      (match (lower-expr ctx state env type-env func)
        [(OkLowerExpr lowered-func)
          (match lowered-func
            [(LowerExpr func-state func-value func-ty)
              (if (lower-function-type? func-ty)
                (lower-indirect-call
                  ctx
                  func-state
                  env
                  type-env
                  func-value
                  args
                  result-ty
                  origin)
                (ErrLowerExpr
                  (lower-diagnostic-at-expr
                    func
                    "lower: call target is not a function")))])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]))

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
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons arr (AstExprNil))
      (match (lower-expr-result-type-fast ctx env type-env arr)
        [(OkTcType arr-ty)
          (lower-array-length-with-type
            ctx
            state
            env
            type-env
            name
            args
            result-ty
            origin
            arr
            arr-ty)]
        [(ErrTcType _)
          (match (tc-expr ctx type-env arr)
            [(OkTcType arr-ty)
              (lower-array-length-with-type
                ctx
                state
                env
                type-env
                name
                args
                result-ty
                origin
                arr
                arr-ty)]
            [(ErrTcType _)
              (lower-direct-call
                ctx
                state
                env
                type-env
                name
                args
                result-ty
                origin)])])]
    [_ (lower-direct-call ctx state env type-env name args result-ty origin)]))

(define (lower-array-length-with-type
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]
  [arr : AstExpr]
  [arr-ty : AstType]) : ResultLowerExpr
  (match (tc-type-strip-region (tc-resolve-type ctx arr-ty))
    [(AstTyDynArray _) (lower-array-length-load ctx state env type-env arr)]
    [_
      (if (lower-string-handle-type? ctx arr-ty)
        (lower-array-length-load ctx state env type-env arr)
        (lower-direct-call
          ctx
          state
          env
          type-env
          name
          args
          result-ty
          origin))]))

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
              (let
                [gep-state : LowerState
                  (lower-state-emit
                    gep-alloc
                    (IrInstrGep gep-var arr-value (IrValueI64 1) (AstTyI64)))]
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

(define (lower-emit-bounds-check
  [state : LowerState]
  [index : CompilerIrValue]
  [length : CompilerIrValue]) : LowerState
  (match (lower-state-fresh-label state "bounds_ok")
    [(LowerLabel bounds-ok-state bounds-ok-label)
      (lower-state-emit
        bounds-ok-state
        (IrInstrBoundsCheck index length bounds-ok-label))]))

;; Tail of `lower-array-element-addr`: after the explicit bounds check, load the
;; buffer pointer (fat offset 0, a raw U64 address) and `Gep` it by the index,
;; scaled by the element type, to the element address.
(define (lower-array-element-addr-finish
  [state : LowerState]
  [arr-value : CompilerIrValue]
  [idx-off : CompilerIrValue]
  [elem-ty : AstType]) : LowerExpr
  (match (lower-emit-gep state arr-value (IrValueI64 0) (AstTyI64))
    [(LowerExpr buf-gep-state buf-gep _)
      (match (lower-emit-load buf-gep-state buf-gep (AstTyU64))
        [(LowerExpr buf-state buf-val _)
          (lower-emit-gep buf-state buf-val idx-off elem-ty)])]))

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
                      (lower-array-element-addr-finish
                        (lower-emit-bounds-check s5 idx-u len-u)
                        arr-value
                        idx-off
                        elem-ty)])])])])]))

;; Fixed arrays are inline element storage. Bounds check against the static
;; length, then Gep directly from the array handle without loading dynamic-array
;; fat fields.
(define (lower-fixed-array-element-addr
  [state : LowerState]
  [arr-value : CompilerIrValue]
  [idx-value : CompilerIrValue]
  [idx-ty : AstType]
  [elem-ty : AstType]
  [elem-count : i64]) : LowerExpr
  (match (lower-emit-cast state idx-value idx-ty (AstTyU64))
    [(LowerExpr s1 idx-u _)
      (match (lower-emit-cast s1 idx-value idx-ty (AstTyI64))
        [(LowerExpr s2 idx-off _)
          (lower-emit-gep
            (lower-emit-bounds-check s2 idx-u (IrValueI64 elem-count))
            arr-value
            idx-off
            elem-ty)])]))

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
  (let
    [fail-start : LowerState (lower-state-finish-block state fail-label)]
    [alloc-start : LowerState
      (lower-state-finish-block
        (lower-state-emit
          (lower-oob-abort fail-start)
          (IrInstrJump alloc-label))
        alloc-label)]
    (lower-make-array-alloc-buffer alloc-start arr-ty len-i64 elem-size)))

(define (lower-make-array-from-len
  [ctx : TcContext]
  [state : LowerState]
  [elem-ty : AstType]
  [len-value : CompilerIrValue]
  [len-ty : AstType]) : ResultLowerExpr
  (let
    [resolved-elem : AstType (tc-resolve-type ctx elem-ty)]
    (match (lower-cast-value state len-value len-ty (AstTyI64))
      [(LowerExpr len-state len-i64 _)
        (let
          [elem-size : i64 (lower-type-size ctx resolved-elem)]
          [arr-ty : AstType (AstTyDynArray resolved-elem)]
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
                          (let
                            [check-start : LowerState
                              (lower-state-finish-block
                                (lower-state-emit
                                  s4
                                  (IrInstrBranch
                                    non-negative
                                    check-max-label
                                    fail-label))
                                check-max-label)]
                            [max-len : i64
                              (if (= elem-size 0)
                                9223372036854775807
                                (/ 9223372036854775807 elem-size))]
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
                                  elem-size)]))])])])]))])))

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
      (match (tc-type-strip-region arr-ty)
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
                                (tc-type-without-regions elem-ty))
                                [(LowerExpr addr-state elem-ptr _)
                                  (match (lower-emit-load
                                    addr-state
                                    elem-ptr
                                    (tc-type-without-regions elem-ty))
                                    [(LowerExpr load-state load-value _)
                                      (OkLowerExpr
                                        (LowerExpr
                                          load-state
                                          load-value
                                          (tc-type-without-regions elem-ty)))])])])]
                        [(ErrLowerExpr message) (ErrLowerExpr message)])]
                    [(ErrTcType message)
                      (ErrLowerExpr (lower-diagnostic-at-expr index message))])])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])]
        [(AstTyArray elem-ty elem-count)
          (let
            [fixed-elem-ty : AstType (tc-type-without-regions elem-ty)]
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
                                (match (lower-fixed-array-element-addr
                                  idx-state
                                  arr-value
                                  idx-value
                                  idx-ty
                                  fixed-elem-ty
                                  elem-count)
                                  [(LowerExpr addr-state elem-ptr _)
                                    (if (=
                                      (lower-type-size ctx fixed-elem-ty)
                                      0)
                                      (OkLowerExpr
                                        (LowerExpr
                                          addr-state
                                          IrValueUnit
                                          fixed-elem-ty))
                                      (match (lower-emit-load
                                        addr-state
                                        elem-ptr
                                        fixed-elem-ty)
                                        [(LowerExpr load-state load-value _)
                                          (OkLowerExpr
                                            (LowerExpr
                                              load-state
                                              load-value
                                              fixed-elem-ty))]))])])]
                          [(ErrLowerExpr message) (ErrLowerExpr message)])]
                      [(ErrTcType message)
                        (ErrLowerExpr (lower-diagnostic-at-expr index message))])])]
              [(ErrLowerExpr message) (ErrLowerExpr message)]))]
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
      (match (tc-type-strip-region arr-ty)
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
                                        (tc-type-without-regions elem-ty))
                                        [(LowerExpr addr-state elem-ptr _)
                                          (OkLowerExpr
                                            (LowerExpr
                                              (lower-state-emit
                                                addr-state
                                                (IrInstrStorePtr
                                                  elem-ptr
                                                  value-ir
                                                  (tc-type-without-regions
                                                    elem-ty)))
                                              IrValueUnit
                                              (AstTyUnit)))])])]
                                [(ErrLowerExpr message) (ErrLowerExpr message)])])]
                        [(ErrLowerExpr message) (ErrLowerExpr message)])]
                    [(ErrTcType message)
                      (ErrLowerExpr (lower-diagnostic-at-expr index message))])])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])]
        [(AstTyArray elem-ty elem-count)
          (let
            [fixed-elem-ty : AstType (tc-type-without-regions elem-ty)]
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
                                        (match (lower-fixed-array-element-addr
                                          value-state
                                          arr-value
                                          idx-value
                                          idx-ty
                                          fixed-elem-ty
                                          elem-count)
                                          [(LowerExpr addr-state elem-ptr _)
                                            (if (=
                                              (lower-type-size
                                                ctx
                                                fixed-elem-ty)
                                              0)
                                              (OkLowerExpr
                                                (LowerExpr
                                                  addr-state
                                                  IrValueUnit
                                                  (AstTyUnit)))
                                              (OkLowerExpr
                                                (LowerExpr
                                                  (lower-state-emit
                                                    addr-state
                                                    (IrInstrStorePtr
                                                      elem-ptr
                                                      value-ir
                                                      fixed-elem-ty))
                                                  IrValueUnit
                                                  (AstTyUnit))))])])]
                                  [(ErrLowerExpr message)
                                    (ErrLowerExpr message)])])]
                          [(ErrLowerExpr message) (ErrLowerExpr message)])]
                      [(ErrTcType message)
                        (ErrLowerExpr (lower-diagnostic-at-expr index message))])])]
              [(ErrLowerExpr message) (ErrLowerExpr message)]))]
        [_
          (ErrLowerExpr
            (lower-diagnostic-at-expr
              arr
              "lower: array-set! requires a dynamic array"))])]
    [(ErrTcType message) (ErrLowerExpr (lower-diagnostic-at-expr arr message))]))

;; Copy old dynamic-array elements into a freshly allocated buffer. The loop is
;; emitted as explicit IR so `array-push!` works for runtime lengths.
(define (lower-array-push-copy-loop
  [state : LowerState]
  [old-buf : CompilerIrValue]
  [new-buf : CompilerIrValue]
  [old-len : CompilerIrValue]
  [elem-ty : AstType]) : LowerState
  (match (lower-state-fresh-label state "array_push_copy_header")
    [(LowerLabel header-label-state header-label)
      (match (lower-state-fresh-label header-label-state "array_push_copy_body")
        [(LowerLabel body-label-state body-label)
          (match (lower-state-fresh-label
            body-label-state
            "array_push_copy_exit")
            [(LowerLabel exit-label-state exit-label)
              (match (lower-state-alloc-var exit-label-state)
                [(LowerAlloc index-alloc index-var)
                  (let
                    [header-start : LowerState
                      (lower-state-finish-block
                        (lower-state-emit
                          (lower-state-emit
                            index-alloc
                            (IrInstrMov index-var (IrValueI64 0) (AstTyI64)))
                          (IrInstrJump header-label))
                        header-label)]
                    (match (lower-state-alloc-var header-start)
                      [(LowerAlloc cond-alloc cond-var)
                        (let
                          [body-start : LowerState
                            (lower-state-finish-block
                              (lower-state-emit
                                (lower-state-emit
                                  cond-alloc
                                  (IrInstrBinOp
                                    cond-var
                                    IrBinLt
                                    (IrValueVar index-var)
                                    old-len
                                    (AstTyBool)))
                                (IrInstrBranch
                                  (IrValueVar cond-var)
                                  body-label
                                  exit-label))
                              body-label)]
                          (match (lower-emit-gep
                            body-start
                            old-buf
                            (IrValueVar index-var)
                            elem-ty)
                            [(LowerExpr src-gep-state src-ptr _)
                              (match (lower-emit-load
                                src-gep-state
                                src-ptr
                                elem-ty)
                                [(LowerExpr load-state elem-value _)
                                  (match (lower-emit-gep
                                    load-state
                                    new-buf
                                    (IrValueVar index-var)
                                    elem-ty)
                                    [(LowerExpr dst-gep-state dst-ptr _)
                                      (match (lower-state-alloc-var
                                        (lower-state-emit
                                          dst-gep-state
                                          (IrInstrStorePtr
                                            dst-ptr
                                            elem-value
                                            elem-ty)))
                                        [(LowerAlloc inc-alloc inc-var)
                                          (lower-state-finish-block
                                            (lower-state-emit
                                              (lower-state-emit
                                                (lower-state-emit
                                                  inc-alloc
                                                  (IrInstrBinOp
                                                    inc-var
                                                    IrBinAdd
                                                    (IrValueVar index-var)
                                                    (IrValueI64 1)
                                                    (AstTyI64)))
                                                (IrInstrMov
                                                  index-var
                                                  (IrValueVar inc-var)
                                                  (AstTyI64)))
                                              (IrInstrJump header-label))
                                            exit-label)])])])]))]))])])])]))

(define (lower-array-push-finish
  [state : LowerState]
  [arr-value : CompilerIrValue]
  [old-buf : CompilerIrValue]
  [old-len : CompilerIrValue]
  [new-buf : CompilerIrValue]
  [new-len : CompilerIrValue]
  [elem-ty : AstType]
  [value-ir : CompilerIrValue]) : LowerExpr
  (match (lower-emit-gep
    (lower-array-push-copy-loop state old-buf new-buf old-len elem-ty)
    new-buf
    old-len
    elem-ty)
    [(LowerExpr tail-gep-state tail-ptr _)
      (LowerExpr
        (lower-store-at-offset
          (lower-store-at-offset
            (lower-state-emit
              tail-gep-state
              (IrInstrStorePtr tail-ptr value-ir elem-ty))
            arr-value
            0
            new-buf
            (AstTyU64))
          arr-value
          8
          new-len
          (AstTyI64))
        IrValueUnit
        (AstTyUnit))]))

(define (lower-array-push-alloc-buffer
  [state : LowerState]
  [arr-value : CompilerIrValue]
  [old-buf : CompilerIrValue]
  [old-len : CompilerIrValue]
  [elem-size : i64]
  [elem-ty : AstType]
  [value-ir : CompilerIrValue]) : LowerExpr
  (match (lower-emit-binop state IrBinAdd old-len (IrValueI64 1) (AstTyI64))
    [(LowerExpr len-state new-len _)
      (match (lower-emit-binop
        len-state
        IrBinMul
        new-len
        (IrValueI64 elem-size)
        (AstTyI64))
        [(LowerExpr byte-state byte-count _)
          (match (lower-state-alloc-var byte-state)
            [(LowerAlloc buf-alloc buf-var)
              (lower-array-push-finish
                (lower-state-emit
                  buf-alloc
                  (IrInstrCall
                    buf-var
                    "tl_alloc"
                    (IrValueCons byte-count IrValueNil)
                    (AstTyU64)))
                arr-value
                old-buf
                old-len
                (IrValueVar buf-var)
                new-len
                elem-ty
                value-ir)])])]))

(define (lower-array-push-after-max-check
  [state : LowerState]
  [fail-label : String]
  [alloc-label : String]
  [arr-value : CompilerIrValue]
  [old-buf : CompilerIrValue]
  [old-len : CompilerIrValue]
  [elem-size : i64]
  [elem-ty : AstType]
  [value-ir : CompilerIrValue]) : LowerExpr
  (let
    [fail-start : LowerState (lower-state-finish-block state fail-label)]
    [alloc-start : LowerState
      (lower-state-finish-block
        (lower-state-emit
          (lower-oob-abort fail-start)
          (IrInstrJump alloc-label))
        alloc-label)]
    (lower-array-push-alloc-buffer
      alloc-start
      arr-value
      old-buf
      old-len
      elem-size
      elem-ty
      value-ir)))

(define (lower-array-push-from-values
  [ctx : TcContext]
  [state : LowerState]
  [arr-value : CompilerIrValue]
  [elem-ty : AstType]
  [value-ir : CompilerIrValue]) : LowerExpr
  (match (lower-load-at-offset state arr-value 8 (AstTyI64))
    [(LowerExpr len-state old-len _)
      (match (lower-load-at-offset len-state arr-value 0 (AstTyU64))
        [(LowerExpr buf-state old-buf _)
          (let
            [elem-size : i64 (lower-type-size ctx elem-ty)]
            [max-old-len : i64
              (if (= elem-size 0)
                9223372036854775806
                (- (/ 9223372036854775807 elem-size) 1))]
            (match (lower-state-fresh-label buf-state "array_push_alloc")
              [(LowerLabel alloc-label-state alloc-label)
                (match (lower-state-fresh-label
                  alloc-label-state
                  "array_push_fail")
                  [(LowerLabel fail-label-state fail-label)
                    (match (lower-emit-binop
                      fail-label-state
                      IrBinLe
                      old-len
                      (IrValueI64 max-old-len)
                      (AstTyBool))
                      [(LowerExpr check-state within-max _)
                        (lower-array-push-after-max-check
                          (lower-state-emit
                            check-state
                            (IrInstrBranch within-max alloc-label fail-label))
                          fail-label
                          alloc-label
                          arr-value
                          old-buf
                          old-len
                          elem-size
                          elem-ty
                          value-ir)])])]))])]))

;; `(array-push! arr value)` -> allocate a new element buffer in the active
;; arena, copy old elements, append `value`, and update the fat `{ptr, len}`.
(define (lower-array-push
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [arr : AstExpr]
  [value : AstExpr]) : ResultLowerExpr
  (match (tc-expr ctx type-env arr)
    [(OkTcType arr-ty)
      (match (tc-type-strip-region arr-ty)
        [(AstTyDynArray elem-ty)
          (let
            [elem-ir-ty : AstType (tc-type-without-regions elem-ty)]
            (match (lower-expr ctx state env type-env arr)
              [(OkLowerExpr arr-lowered)
                (match arr-lowered
                  [(LowerExpr arr-state arr-value _)
                    (match (lower-expr ctx arr-state env type-env value)
                      [(OkLowerExpr value-lowered)
                        (match value-lowered
                          [(LowerExpr value-state value-ir _)
                            (OkLowerExpr
                              (lower-array-push-from-values
                                ctx
                                value-state
                                arr-value
                                elem-ir-ty
                                value-ir))])]
                      [(ErrLowerExpr message) (ErrLowerExpr message)])])]
              [(ErrLowerExpr message) (ErrLowerExpr message)]))]
        [(AstTyArray _ _)
          (ErrLowerExpr
            (lower-diagnostic-at-expr
              arr
              "lower: fixed-array array-push! is not supported"))]
        [_
          (ErrLowerExpr
            (lower-diagnostic-at-expr
              arr
              "lower: array-push! requires a dynamic array"))])]
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
    [(AstSomeType ty) (tc-type-without-regions (tc-resolve-type ctx ty))]
    [(AstNoType) (tc-type-without-regions init-ty)]))

(define (lower-let-init
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [maybe-ty : AstMaybeType]
  [init : AstExpr]) : ResultLowerExpr
  (match maybe-ty
    [(AstSomeType ty)
      (lower-expr-expected
        ctx
        state
        env
        type-env
        init
        (tc-type-without-regions (tc-resolve-type ctx ty))
        init)]
    [(AstNoType) (lower-expr ctx state env type-env init)]))

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
          (match (lower-let-init ctx state env type-env maybe-ty init)
            [(OkLowerExpr lowered)
              (match lowered
                [(LowerExpr init-state init-value init-ty)
                  (let
                    [binding-ty : AstType
                      (lower-let-binding-type ctx maybe-ty init-ty)]
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

(define (lower-resource-bindings
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [bindings : AstResourceBindingList]
  [cleanups : LowerCleanupList]) : ResultLowerResourceBindings
  (match bindings
    [(AstResourceBindingNil)
      (OkLowerResourceBindings
        (LowerResourceBindings state env type-env cleanups))]
    [(AstResourceBindingCons binding rest)
      (match binding
        [(AstResourceBinding name init cleanup)
          (match (lower-expr ctx state env type-env init)
            [(OkLowerExpr lowered)
              (match lowered
                [(LowerExpr init-state init-value init-ty)
                  (match (lower-cleanup-name-from-expr cleanup)
                    [(OkTcString cleanup-name)
                      (let
                        [binding-ty : AstType (tc-type-without-regions init-ty)]
                        (match (lower-state-alloc-var init-state)
                          [(LowerAlloc allocated var-id)
                            (let
                              [hidden-name : String
                                (lower-cleanup-hidden-name var-id)]
                              [bound-state : LowerState
                                (lower-state-emit
                                  allocated
                                  (IrInstrMov var-id init-value binding-ty))]
                              [bound-env : SymI64Env
                                (sym-i64-bind
                                  (sym-i64-bind env name var-id)
                                  hidden-name
                                  var-id)]
                              [bound-type-env : TcTypeEnv
                                (lower-type-env-push-cleanup
                                  (tc-bind type-env name binding-ty)
                                  hidden-name
                                  cleanup-name)]
                              (lower-resource-bindings
                                ctx
                                bound-state
                                bound-env
                                bound-type-env
                                rest
                                (LowerCleanupCons
                                  (LowerCleanup hidden-name cleanup-name)
                                  cleanups)))]))]
                    [(ErrTcString message)
                      (ErrLowerResourceBindings
                        (lower-diagnostic-at-expr cleanup message))])])]
            [(ErrLowerExpr message) (ErrLowerResourceBindings message)])])]))

(define (lower-with-resource
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [bindings : AstResourceBindingList]
  [body : AstExprList]) : ResultLowerExpr
  (match (lower-resource-bindings
    ctx
    state
    env
    type-env
    bindings
    LowerCleanupNil)
    [(OkLowerResourceBindings lowered-bindings)
      (match lowered-bindings
        [(LowerResourceBindings binding-state body-env body-type-env cleanups)
          (match (lower-begin ctx binding-state body-env body-type-env body)
            [(OkLowerExpr lowered-body)
              (match lowered-body
                [(LowerExpr body-state value body-ty)
                  (if (tc-never-type? body-ty)
                    (OkLowerExpr (LowerExpr body-state value body-ty))
                    (match (lower-emit-cleanup-list
                      body-state
                      body-env
                      cleanups)
                      [(OkLowerState cleanup-state)
                        (OkLowerExpr (LowerExpr cleanup-state value body-ty))]
                      [(ErrLowerState message) (ErrLowerExpr message)]))])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])])]
    [(ErrLowerResourceBindings message) (ErrLowerExpr message)]))

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
                [(LowerExpr next-state _ expr-ty)
                  (if (tc-never-type? expr-ty)
                    (OkLowerExpr
                      (LowerExpr next-state IrValueUnit (AstTyNever)))
                    (lower-begin ctx next-state env type-env rest))])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])])]))

(define (lower-with-arena
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [body : AstExprList]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc mark-allocated mark-var)
      (let
        [hidden-name : String (lower-region-hidden-name mark-var)]
        [marked-state : LowerState
          (lower-state-emit
            mark-allocated
            (IrInstrCall mark-var "tl_region_mark" IrValueNil (AstTyU64)))]
        [region-env : SymI64Env (sym-i64-bind env hidden-name mark-var)]
        [region-type-env : TcTypeEnv
          (lower-type-env-push-region-reset type-env hidden-name)]
        (match (lower-begin ctx marked-state region-env region-type-env body)
          [(OkLowerExpr lowered)
            (match lowered
              [(LowerExpr body-state value body-ty)
                (if (tc-never-type? body-ty)
                  (OkLowerExpr (LowerExpr body-state value body-ty))
                  (match (lower-state-alloc-var body-state)
                    [(LowerAlloc reset-allocated reset-var)
                      (OkLowerExpr
                        (LowerExpr
                          (lower-state-emit
                            reset-allocated
                            (IrInstrCall
                              reset-var
                              "tl_region_reset"
                              (IrValueCons (IrValueVar mark-var) IrValueNil)
                              (AstTyUnit)))
                          value
                          body-ty))]))])]
          [(ErrLowerExpr message) (ErrLowerExpr message)]))]))

(define (lower-with-escape-final
  [final-lowered : LowerExpr]
  [escaped-value : CompilerIrValue]
  [escaped-ty : AstType]) : ResultLowerExpr
  (match final-lowered
    [(LowerExpr final-state _ _)
      (OkLowerExpr (LowerExpr final-state escaped-value escaped-ty))]))

(define (lower-with-escape-rewind
  [state : LowerState]
  [mark-value : CompilerIrValue]
  [new-enclosing-value : CompilerIrValue]
  [escaped-value : CompilerIrValue]
  [escaped-ty : AstType]) : ResultLowerExpr
  (match (lower-runtime-call-values
    state
    "tl_region_reset"
    (IrValueCons mark-value IrValueNil)
    (AstTyUnit))
    [(OkLowerExpr rewind-lowered)
      (match rewind-lowered
        [(LowerExpr rewind-state _ _)
          (match (lower-runtime-call-values
            rewind-state
            "tl_arena_set"
            (IrValueCons new-enclosing-value IrValueNil)
            (AstTyUnit))
            [(OkLowerExpr final-lowered)
              (lower-with-escape-final final-lowered escaped-value escaped-ty)]
            [(ErrLowerExpr message) (ErrLowerExpr message)])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-with-escape-cleanup
  [state : LowerState]
  [scratch-head-value : CompilerIrValue]
  [mark-value : CompilerIrValue]
  [escaped-value : CompilerIrValue]
  [escaped-ty : AstType]) : ResultLowerExpr
  (match (lower-runtime-call-values
    state
    "tl_arena_current"
    IrValueNil
    (AstTyI64))
    [(OkLowerExpr new-enclosing-lowered)
      (match new-enclosing-lowered
        [(LowerExpr new-enclosing-state new-enclosing-value _)
          (match (lower-runtime-call-values
            new-enclosing-state
            "tl_arena_set"
            (IrValueCons scratch-head-value IrValueNil)
            (AstTyUnit))
            [(OkLowerExpr restore-scratch-lowered)
              (match restore-scratch-lowered
                [(LowerExpr restore-scratch-state _ _)
                  (lower-with-escape-rewind
                    restore-scratch-state
                    mark-value
                    new-enclosing-value
                    escaped-value
                    escaped-ty)])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-with-escape-clone
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [scratch-head-value : CompilerIrValue]
  [mark-value : CompilerIrValue]
  [body-value : CompilerIrValue]
  [body-ty : AstType]) : ResultLowerExpr
  (match (lower-clone-value-dispatch ctx state env body-value body-ty)
    [(OkLowerExpr escaped-lowered)
      (match escaped-lowered
        [(LowerExpr escaped-state escaped-value escaped-ty)
          (lower-with-escape-cleanup
            escaped-state
            scratch-head-value
            mark-value
            escaped-value
            escaped-ty)])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-with-escape-body
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [enclosing-value : CompilerIrValue]
  [mark-value : CompilerIrValue]
  [body : AstExprList]) : ResultLowerExpr
  (match (lower-begin ctx state env type-env body)
    [(OkLowerExpr body-lowered)
      (match body-lowered
        [(LowerExpr body-state body-value body-ty)
          (match (lower-runtime-call-values
            body-state
            "tl_arena_current"
            IrValueNil
            (AstTyI64))
            [(OkLowerExpr scratch-head-lowered)
              (match scratch-head-lowered
                [(LowerExpr scratch-head-state scratch-head-value _)
                  (match (lower-runtime-call-values
                    scratch-head-state
                    "tl_arena_set"
                    (IrValueCons enclosing-value IrValueNil)
                    (AstTyUnit))
                    [(OkLowerExpr restore-enclosing-lowered)
                      (match restore-enclosing-lowered
                        [(LowerExpr restore-state _ _)
                          (lower-with-escape-clone
                            ctx
                            restore-state
                            env
                            scratch-head-value
                            mark-value
                            body-value
                            body-ty)])]
                    [(ErrLowerExpr message) (ErrLowerExpr message)])])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-with-escape
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scratch : AstExpr]
  [body : AstExprList]) : ResultLowerExpr
  (match (lower-runtime-call-values
    state
    "tl_arena_current"
    IrValueNil
    (AstTyI64))
    [(OkLowerExpr enclosing-lowered)
      (match enclosing-lowered
        [(LowerExpr enclosing-state enclosing-value _)
          (match (lower-expr-expected
            ctx
            enclosing-state
            env
            type-env
            scratch
            (AstTyI64)
            scratch)
            [(OkLowerExpr scratch-lowered)
              (match scratch-lowered
                [(LowerExpr scratch-state scratch-value _)
                  (match (lower-runtime-call-values
                    scratch-state
                    "tl_arena_set"
                    (IrValueCons scratch-value IrValueNil)
                    (AstTyUnit))
                    [(OkLowerExpr set-scratch-lowered)
                      (match set-scratch-lowered
                        [(LowerExpr set-scratch-state _ _)
                          (match (lower-runtime-call-values
                            set-scratch-state
                            "tl_region_mark"
                            IrValueNil
                            (AstTyU64))
                            [(OkLowerExpr mark-lowered)
                              (match mark-lowered
                                [(LowerExpr mark-state mark-value _)
                                  (lower-with-escape-body
                                    ctx
                                    mark-state
                                    env
                                    type-env
                                    enclosing-value
                                    mark-value
                                    body)])]
                            [(ErrLowerExpr message) (ErrLowerExpr message)])])]
                    [(ErrLowerExpr message) (ErrLowerExpr message)])])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-if-merge
  [else-state : LowerState]
  [then-value : CompilerIrValue]
  [then-end-label : String]
  [else-value : CompilerIrValue]
  [merge-label : String]
  [expr-ty : AstType]) : ResultLowerExpr
  (let
    [else-end-label : String (lower-state-current-label else-state)]
    [merge-start : LowerState
      (lower-state-finish-block
        (lower-state-emit else-state (IrInstrJump merge-label))
        merge-label)]
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
            expr-ty))])))

(define (lower-if-single-merge
  [state : LowerState]
  [value : CompilerIrValue]
  [merge-label : String]
  [expr-ty : AstType]) : ResultLowerExpr
  (let
    [merge-start : LowerState
      (lower-state-finish-block
        (lower-state-emit state (IrInstrJump merge-label))
        merge-label)]
    (OkLowerExpr (LowerExpr merge-start value expr-ty))))

(define (lower-if-finish
  [then-value : CompilerIrValue]
  [then-ty : AstType]
  [then-end-label : String]
  [else-state : LowerState]
  [else-value : CompilerIrValue]
  [else-ty : AstType]
  [merge-label : String]
  [expr-ty : AstType]) : ResultLowerExpr
  (if (tc-never-type? then-ty)
    (if (tc-never-type? else-ty)
      (OkLowerExpr
        (LowerExpr
          (lower-state-finish-block else-state merge-label)
          IrValueUnit
          (AstTyNever)))
      (lower-if-single-merge else-state else-value merge-label expr-ty))
    (if (tc-never-type? else-ty)
      (OkLowerExpr
        (LowerExpr
          (lower-state-finish-block else-state merge-label)
          then-value
          expr-ty))
      (lower-if-merge
        else-state
        then-value
        then-end-label
        else-value
        merge-label
        expr-ty))))

(define (lower-if-else
  [ctx : TcContext]
  [else-start : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [else-branch : AstExpr]
  [then-value : CompilerIrValue]
  [then-ty : AstType]
  [then-end-label : String]
  [merge-label : String]
  [expr-ty : AstType]) : ResultLowerExpr
  (match (lower-expr-expected
    ctx
    else-start
    env
    type-env
    else-branch
    expr-ty
    else-branch)
    [(OkLowerExpr else-lowered)
      (match else-lowered
        [(LowerExpr else-state else-value else-ty)
          (lower-if-finish
            then-value
            then-ty
            then-end-label
            else-state
            else-value
            else-ty
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
  (match (lower-expr-expected
    ctx
    then-start
    env
    type-env
    then-branch
    expr-ty
    then-branch)
    [(OkLowerExpr then-lowered)
      (match then-lowered
        [(LowerExpr then-state then-value then-ty)
          (let
            [then-end-label : String (lower-state-current-label then-state)]
            [else-start : LowerState
              (if (tc-never-type? then-ty)
                (lower-state-finish-block then-state else-label)
                (lower-state-finish-block
                  (lower-state-emit then-state (IrInstrJump merge-label))
                  else-label))]
            (lower-if-else
              ctx
              else-start
              env
              type-env
              else-branch
              then-value
              then-ty
              then-end-label
              merge-label
              expr-ty))])]
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
        [(LowerExpr cond-state cond-value cond-ty)
          (if (tc-type-compatible? (AstTyBool) cond-ty)
            (match (lower-state-fresh-label cond-state "if_then")
              [(LowerLabel then-label-state then-label)
                (match (lower-state-fresh-label then-label-state "if_else")
                  [(LowerLabel else-label-state else-label)
                    (match (lower-state-fresh-label else-label-state "if_merge")
                      [(LowerLabel merge-label-state merge-label)
                        (let
                          [branch-state : LowerState
                            (lower-state-emit
                              merge-label-state
                              (IrInstrBranch cond-value then-label else-label))]
                          (lower-if-then
                            ctx
                            (lower-state-finish-block branch-state then-label)
                            env
                            type-env
                            then-branch
                            else-branch
                            else-label
                            merge-label
                            expr-ty))])])])
            (ErrLowerExpr
              (lower-diagnostic-at-expr
                cond
                "typecheck: if condition must be bool")))])]
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
              (let
                [header-start : LowerState
                  (lower-state-finish-block
                    (lower-state-emit
                      exit-label-state
                      (IrInstrJump header-label))
                    header-label)]
                (match (lower-expr ctx header-start env type-env cond)
                  [(OkLowerExpr cond-lowered)
                    (match cond-lowered
                      [(LowerExpr cond-state cond-value _)
                        (let
                          [body-start : LowerState
                            (lower-state-finish-block
                              (lower-state-emit
                                cond-state
                                (IrInstrBranch cond-value body-label exit-label))
                              body-label)]
                          (match (lower-expr ctx body-start env type-env body)
                            [(OkLowerExpr body-lowered)
                              (match body-lowered
                                [(LowerExpr body-state _ body-ty)
                                  (OkLowerExpr
                                    (LowerExpr
                                      (if (tc-never-type? body-ty)
                                        (lower-state-finish-block
                                          body-state
                                          exit-label)
                                        (lower-state-finish-block
                                          (lower-state-emit
                                            body-state
                                            (IrInstrJump header-label))
                                          exit-label))
                                      IrValueUnit
                                      (AstTyUnit)))])]
                            [(ErrLowerExpr message) (ErrLowerExpr message)]))])]
                  [(ErrLowerExpr message) (ErrLowerExpr message)]))])])]))

;; Per-iteration accumulator update for an associative binop fold
;; (`sum`/`all`/`any`): `(set! acc (<op> acc value))`. `value` appears once so it
;; is evaluated exactly once per iteration.
(define (spmd-reduce-acc-binop-update [op : AstBinOp] [value : AstExpr]) : AstExpr
  (AstExprSet
    "0spmd-reduce-acc"
    (AstExprBinary op (AstExprVar "0spmd-reduce-acc") value)))

;; Per-iteration accumulator update for a select fold (`min`/`max`): bind `value`
;; once into a temp, then keep it when `(<cmp> val acc)` holds, else keep `acc`.
;; The temp keeps `value` to a single evaluation even though the select names it
;; twice.
(define (spmd-reduce-acc-select-update [cmp : AstBinOp] [value : AstExpr]) : AstExpr
  (AstExprLet
    (AstLetBindingCons
      (AstLetBinding "0spmd-reduce-val" (AstNoType) value)
      (AstLetBindingNil))
    (AstExprSet
      "0spmd-reduce-acc"
      (AstExprIf
        (AstExprBinary
          cmp
          (AstExprVar "0spmd-reduce-val")
          (AstExprVar "0spmd-reduce-acc"))
        (AstExprVar "0spmd-reduce-val")
        (AstExprVar "0spmd-reduce-acc")))))

(define (spmd-reduce-acc-update-expr [op : AstReduceOp] [value : AstExpr]) : AstExpr
  (match op
    [(AstReduceSum) (spmd-reduce-acc-binop-update (AstBinAdd) value)]
    [(AstReduceAll) (spmd-reduce-acc-binop-update (AstBinAnd) value)]
    [(AstReduceAny) (spmd-reduce-acc-binop-update (AstBinOr) value)]
    [(AstReduceMin) (spmd-reduce-acc-select-update (AstBinLt) value)]
    [(AstReduceMax) (spmd-reduce-acc-select-update (AstBinGt) value)]))

;; Scalar `spmd-reduce` loop scaffold (#1013): desugar to an accumulator loop and
;; reuse the let/while/set lowering. `acc`/`end`/index are bound once before the
;; loop (so `init`/`end`/`start` evaluate exactly once); an empty range returns
;; `init` without evaluating `acc-update`. `acc`/`end`/temp use lexer-impossible
;; names so they cannot collide with a user binding. The ordered left-to-right
;; fold matches the spec reference semantics.
;;   (spmd-reduce <op> ([i : ty start end]) init value)
;;     === (let [acc init] [end' end] [i start]
;;           (begin (while (< i end') (begin <acc-update> (set! i (+ i 1)))) acc))
(define (lower-spmd-reduce-scaffold
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [index-ty : AstType]
  [start : AstExpr]
  [end : AstExpr]
  [init : AstExpr]
  [acc-update : AstExpr]) : ResultLowerExpr
  (lower-expr
    ctx
    state
    env
    type-env
    (AstExprLet
      (AstLetBindingCons
        (AstLetBinding "0spmd-reduce-acc" (AstNoType) init)
        (AstLetBindingCons
          (AstLetBinding "0spmd-reduce-end" (AstNoType) end)
          (AstLetBindingCons
            (AstLetBinding index (AstSomeType index-ty) start)
            (AstLetBindingNil))))
      (AstExprBegin
        (AstExprCons
          (AstExprWhile
            (AstExprBinary
              (AstBinLt)
              (AstExprVar index)
              (AstExprVar "0spmd-reduce-end"))
            (AstExprBegin
              (AstExprCons
                acc-update
                (AstExprCons
                  (AstExprSet
                    index
                    (AstExprBinary
                      (AstBinAdd)
                      (AstExprVar index)
                      (AstExprLiteral (AstLitInt 1))))
                  (AstExprNil)))))
          (AstExprCons (AstExprVar "0spmd-reduce-acc") (AstExprNil)))))))

;; Scalar lowering for all reduction ops (#1013): `sum` (wrapping `+`, also f64
;; ordered add), `all`/`any` (boolean `and`/`or`), and `min`/`max` (ordered
;; select). Each supplies its per-iteration accumulator update to the shared
;; loop scaffold.
(define (lower-spmd-reduce
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [op : AstReduceOp]
  [index : String]
  [index-ty : AstType]
  [start : AstExpr]
  [end : AstExpr]
  [init : AstExpr]
  [value : AstExpr]) : ResultLowerExpr
  (let
    [acc-update : AstExpr (spmd-reduce-acc-update-expr op value)]
    (if (and
      (lower-mode-simd? (lower-state-mode state))
      (lower-type-i64? index-ty))
      (match (lower-simple-vector-reduce
        (lower-state-mode state)
        env
        type-env
        op
        index
        value)
        [(LowerSomeVectorReduce _ _ _ _)
          (lower-avx2-spmd-reduce-lowered
            ctx
            state
            env
            type-env
            index-ty
            start
            end
            init
            op
            (lower-simple-vector-reduce
              (lower-state-mode state)
              env
              type-env
              op
              index
              value))]
        [LowerNoVectorReduce
          (lower-spmd-reduce-scaffold
            ctx
            state
            env
            type-env
            index
            index-ty
            start
            end
            init
            acc-update)])
      (lower-spmd-reduce-scaffold
        ctx
        state
        env
        type-env
        index
        index-ty
        start
        end
        init
        acc-update))))

(define (lower-mode-simd? [mode : CompilerLowerMode]) : bool
  (match mode
    [(CompilerLowerAvx2) true]
    [(CompilerLowerAvx512) true]
    [_ false]))

(define (lower-mode-avx512? [mode : CompilerLowerMode]) : bool
  (match mode
    [(CompilerLowerAvx512) true]
    [_ false]))

(define (lower-mode-inline-aggregates? [mode : CompilerLowerMode]) : bool
  (match mode
    [(CompilerLowerInlineAggregates) true]
    [_ false]))

(define (lower-type-i64? [ty : AstType]) : bool
  (match (tc-type-without-regions ty)
    [(AstTyI64) true]
    [_ false]))

(define (lower-simd-lanes-for-elem [mode : CompilerLowerMode] [ty : AstType]) : i64
  (match mode
    [(CompilerLowerAvx2)
      (match (tc-type-without-regions ty)
        [(AstTyI64) 4]
        [(AstTyU64) 4]
        [(AstTyF64) 4]
        [(AstTyI32) 8]
        [(AstTyU32) 8]
        [_ 0])]
    [(CompilerLowerAvx512)
      (match (tc-type-without-regions ty)
        [(AstTyI64) 8]
        [(AstTyU64) 8]
        [(AstTyF64) 8]
        [(AstTyI32) 16]
        [(AstTyU32) 16]
        [_ 0])]
    [_ 0]))

(define (lower-expr-is-var? [expr : AstExpr] [name : String]) : bool
  (match expr
    [(AstExprSpanned inner _) (lower-expr-is-var? inner name)]
    [(AstExprVar found) (string-eq found name)]
    [_ false]))

(define (lower-dynamic-array-var
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [expr : AstExpr]) : LowerMaybeArrayVar
  (match expr
    [(AstExprSpanned inner _) (lower-dynamic-array-var env type-env inner)]
    [(AstExprAnn inner _) (lower-dynamic-array-var env type-env inner)]
    [(AstExprVar name)
      (match (sym-i64-lookup env name)
        [(SomeI64 var-id)
          (match (tc-lookup type-env name)
            [(OkTcType ty)
              (match (tc-type-strip-region ty)
                [(AstTyDynArray elem-ty)
                  (LowerSomeArrayVar var-id (tc-type-without-regions elem-ty))]
                [_ LowerNoArrayVar])]
            [(ErrTcType _) LowerNoArrayVar])]
        [NoneI64 LowerNoArrayVar])]
    [_ LowerNoArrayVar]))

(define (lower-array-ref-var-for-index
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [expr : AstExpr]
  [index : String]) : LowerMaybeArrayVar
  (match expr
    [(AstExprSpanned inner _)
      (lower-array-ref-var-for-index env type-env inner index)]
    [(AstExprArrayRef arr idx)
      (if (lower-expr-is-var? idx index)
        (lower-dynamic-array-var env type-env arr)
        LowerNoArrayVar)]
    [_ LowerNoArrayVar]))

(define (lower-simple-vector-map-value
  [mode : CompilerLowerMode]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [dst-var : i64]
  [dst-elem : AstType]
  [value : AstExpr]) : LowerMaybeVectorMap
  (match value
    [(AstExprSpanned inner _)
      (lower-simple-vector-map-value
        mode
        env
        type-env
        index
        dst-var
        dst-elem
        inner)]
    [(AstExprBinary op lhs rhs)
      (match op
        [(AstBinAdd)
          (match (lower-array-ref-var-for-index env type-env lhs index)
            [(LowerSomeArrayVar lhs-var lhs-elem)
              (match (lower-array-ref-var-for-index env type-env rhs index)
                [(LowerSomeArrayVar rhs-var rhs-elem)
                  (let
                    [lanes : i64 (lower-simd-lanes-for-elem mode lhs-elem)]
                    (if (and
                      (> lanes 0)
                      (and
                        (tc-type-eq lhs-elem rhs-elem)
                        (tc-type-eq lhs-elem dst-elem)))
                      (LowerSomeVectorMap
                        dst-var
                        lhs-var
                        rhs-var
                        (IrBinAdd)
                        lhs-elem
                        lanes)
                      LowerNoVectorMap))]
                [LowerNoArrayVar LowerNoVectorMap])]
            [LowerNoArrayVar LowerNoVectorMap])]
        [_ LowerNoVectorMap])]
    [_ LowerNoVectorMap]))

(define (lower-simple-vector-map
  [mode : CompilerLowerMode]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [body : AstExpr]) : LowerMaybeVectorMap
  (match body
    [(AstExprSpanned inner _)
      (lower-simple-vector-map mode env type-env index inner)]
    [(AstExprArraySet arr set-index value)
      (if (lower-expr-is-var? set-index index)
        (match (lower-dynamic-array-var env type-env arr)
          [(LowerSomeArrayVar dst-var dst-elem)
            (lower-simple-vector-map-value
              mode
              env
              type-env
              index
              dst-var
              dst-elem
              value)]
          [LowerNoArrayVar LowerNoVectorMap])
        LowerNoVectorMap)]
    [_ LowerNoVectorMap]))

(define (lower-simple-vector-reduce
  [mode : CompilerLowerMode]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [op : AstReduceOp]
  [index : String]
  [value : AstExpr]) : LowerMaybeVectorReduce
  (if (lower-mode-simd? mode)
    (match value
      [(AstExprSpanned inner _)
        (lower-simple-vector-reduce mode env type-env op index inner)]
      [(AstExprAnn inner _)
        (lower-simple-vector-reduce mode env type-env op index inner)]
      [_
        (match (lower-array-ref-var-for-index env type-env value index)
          [(LowerSomeArrayVar array-var elem-ty)
            (let
              [elem : AstType (tc-type-without-regions elem-ty)]
              [lanes : i64 (lower-simd-lanes-for-elem mode elem)]
              (match op
                [(AstReduceSum)
                  (match elem
                    [(AstTyI64)
                      (LowerSomeVectorReduce
                        array-var
                        (IrVectorReduceSum)
                        elem
                        lanes)]
                    [(AstTyI32)
                      (LowerSomeVectorReduce
                        array-var
                        (IrVectorReduceSum)
                        elem
                        lanes)]
                    [_ LowerNoVectorReduce])]
                [(AstReduceMin)
                  (match elem
                    [(AstTyI32)
                      (LowerSomeVectorReduce
                        array-var
                        (IrVectorReduceMin)
                        elem
                        lanes)]
                    [_ LowerNoVectorReduce])]
                [(AstReduceMax)
                  (match elem
                    [(AstTyI32)
                      (LowerSomeVectorReduce
                        array-var
                        (IrVectorReduceMax)
                        elem
                        lanes)]
                    [_ LowerNoVectorReduce])]
                [_ LowerNoVectorReduce]))]
          [LowerNoArrayVar LowerNoVectorReduce])])
    LowerNoVectorReduce))

(define (lower-array-len-value
  [state : LowerState]
  [arr-value : CompilerIrValue]) : LowerExpr
  (match (lower-emit-gep state arr-value (IrValueI64 1) (AstTyI64))
    [(LowerExpr gep-state len-gep _)
      (lower-emit-load gep-state len-gep (AstTyI64))]))

(define (lower-emit-vector-load
  [state : LowerState]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]) : LowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc s v)
      (LowerExpr
        (lower-state-emit s (IrInstrVectorLoad v base index lanes elem-ty))
        (IrValueVar v)
        elem-ty)]))

(define (lower-emit-vector-binop
  [state : LowerState]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]) : LowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc s v)
      (LowerExpr
        (lower-state-emit s (IrInstrVectorBinOp v op lhs rhs lanes elem-ty))
        (IrValueVar v)
        elem-ty)]))

(define (lower-emit-vector-reduce
  [state : LowerState]
  [op : CompilerIrVectorReduceOp]
  [src : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]) : LowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc s v)
      (LowerExpr
        (lower-state-emit s (IrInstrVectorReduce v op src lanes elem-ty))
        (IrValueVar v)
        elem-ty)]))

(define (lower-spmd-reduce-apply-update
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [op : AstReduceOp]
  [acc-var : i64]
  [elem-ty : AstType]
  [value-var : i64]) : ResultLowerExpr
  (lower-expr
    ctx
    state
    (sym-i64-bind
      (sym-i64-bind env "0spmd-reduce-acc" acc-var)
      "0spmd-reduce-current"
      value-var)
    (tc-bind
      (tc-bind type-env "0spmd-reduce-acc" elem-ty)
      "0spmd-reduce-current"
      elem-ty)
    (spmd-reduce-acc-update-expr op (AstExprVar "0spmd-reduce-current"))))

(define (lower-avx2-reduce-ok
  [state : LowerState]
  [index-var : i64]
  [next-index : CompilerIrValue]
  [end-value : CompilerIrValue]
  [array-len : CompilerIrValue]
  [lanes : i64]) : LowerExpr
  (let
    [s : LowerState state]
    [ok : CompilerIrValue IrValueUnit]
    [within : CompilerIrValue IrValueUnit]
    (begin
      (match (lower-emit-binop
        s
        (IrBinGe)
        (IrValueVar index-var)
        (IrValueI64 0)
        (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! ok value))])
      (match (lower-emit-binop
        s
        (IrBinLe)
        (IrValueVar index-var)
        (IrValueI64 (- 9223372036854775807 lanes))
        (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! within value))])
      (match (lower-emit-binop s (IrBinAnd) ok within (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! ok value))])
      (match (lower-emit-binop s (IrBinLe) next-index end-value (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! within value))])
      (match (lower-emit-binop s (IrBinAnd) ok within (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! ok value))])
      (match (lower-emit-binop s (IrBinLe) next-index array-len (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! within value))])
      (lower-emit-binop s (IrBinAnd) ok within (AstTyBool)))))

(define (lower-avx2-reduce-vector-body
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [op : AstReduceOp]
  [index-var : i64]
  [next-index : CompilerIrValue]
  [acc-var : i64]
  [array-var : i64]
  [vector-op : CompilerIrVectorReduceOp]
  [elem-ty : AstType]
  [lanes : i64]) : ResultLowerExpr
  (match (lower-emit-vector-load
    state
    (IrValueVar array-var)
    (IrValueVar index-var)
    lanes
    elem-ty)
    [(LowerExpr load-state chunk-vec _)
      (match (lower-emit-vector-reduce
        load-state
        vector-op
        chunk-vec
        lanes
        elem-ty)
        [(LowerExpr reduce-state reduced _)
          (match reduced
            [(IrValueVar reduced-var)
              (match (lower-spmd-reduce-apply-update
                ctx
                reduce-state
                env
                type-env
                op
                acc-var
                elem-ty
                reduced-var)
                [(OkLowerExpr update-lowered)
                  (match update-lowered
                    [(LowerExpr update-state _ _)
                      (OkLowerExpr
                        (LowerExpr
                          (lower-state-emit
                            update-state
                            (IrInstrMov index-var next-index (AstTyI64)))
                          IrValueUnit
                          (AstTyUnit)))])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])]
            [_
              (ErrLowerExpr
                (lower-diagnostic "lower: invalid vector reduce result"))])])]))

(define (lower-spmd-reduce-scalar-tail-body
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [op : AstReduceOp]
  [index-var : i64]
  [index-ty : AstType]
  [acc-var : i64]
  [array-var : i64]
  [elem-ty : AstType]) : ResultLowerExpr
  (match (lower-array-element-addr
    state
    (IrValueVar array-var)
    (IrValueVar index-var)
    index-ty
    elem-ty)
    [(LowerExpr addr-state elem-ptr _)
      (match (lower-emit-load addr-state elem-ptr elem-ty)
        [(LowerExpr load-state loaded _)
          (match loaded
            [(IrValueVar loaded-var)
              (match (lower-spmd-reduce-apply-update
                ctx
                load-state
                env
                type-env
                op
                acc-var
                elem-ty
                loaded-var)
                [(OkLowerExpr update-lowered)
                  (match update-lowered
                    [(LowerExpr update-state _ _)
                      (match (lower-state-alloc-var update-state)
                        [(LowerAlloc inc-alloc inc-var)
                          (OkLowerExpr
                            (LowerExpr
                              (lower-state-emit
                                (lower-state-emit
                                  inc-alloc
                                  (IrInstrBinOp
                                    inc-var
                                    IrBinAdd
                                    (IrValueVar index-var)
                                    (IrValueI64 1)
                                    index-ty))
                                (IrInstrMov
                                  index-var
                                  (IrValueVar inc-var)
                                  index-ty))
                              IrValueUnit
                              (AstTyUnit)))])])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])]
            [_
              (ErrLowerExpr
                (lower-diagnostic "lower: invalid scalar reduce load"))])])]))

(define (lower-avx2-spmd-reduce-build
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index-ty : AstType]
  [init-value : CompilerIrValue]
  [end-value : CompilerIrValue]
  [start-value : CompilerIrValue]
  [op : AstReduceOp]
  [array-var : i64]
  [vector-op : CompilerIrVectorReduceOp]
  [elem-ty : AstType]
  [lanes : i64]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc acc-alloc acc-var)
      (match (lower-state-alloc-var
        (lower-state-emit acc-alloc (IrInstrMov acc-var init-value elem-ty)))
        [(LowerAlloc index-alloc index-var)
          (let
            [s : LowerState
              (lower-state-emit
                index-alloc
                (IrInstrMov index-var start-value index-ty))]
            [header-label : String ""]
            [body-label : String ""]
            [tail-header-label : String ""]
            [tail-body-label : String ""]
            [exit-label : String ""]
            [array-len : CompilerIrValue IrValueUnit]
            [next-index : CompilerIrValue IrValueUnit]
            [vector-ok : CompilerIrValue IrValueUnit]
            [tail-cond : CompilerIrValue IrValueUnit]
            (begin
              (match (lower-state-fresh-label s "spmd_reduce_avx2_header")
                [(LowerLabel next-s label)
                  (begin
                    (set! s next-s)
                    (set! header-label label))])
              (match (lower-state-fresh-label s "spmd_reduce_avx2_body")
                [(LowerLabel next-s label)
                  (begin
                    (set! s next-s)
                    (set! body-label label))])
              (match (lower-state-fresh-label s "spmd_reduce_tail_header")
                [(LowerLabel next-s label)
                  (begin
                    (set! s next-s)
                    (set! tail-header-label label))])
              (match (lower-state-fresh-label s "spmd_reduce_tail_body")
                [(LowerLabel next-s label)
                  (begin
                    (set! s next-s)
                    (set! tail-body-label label))])
              (match (lower-state-fresh-label s "spmd_reduce_exit")
                [(LowerLabel next-s label)
                  (begin
                    (set! s next-s)
                    (set! exit-label label))])
              (match (lower-array-len-value s (IrValueVar array-var))
                [(LowerExpr next-s value _)
                  (begin
                    (set! s next-s)
                    (set! array-len value))])
              (set!
                s
                (lower-state-finish-block
                  (lower-state-emit s (IrInstrJump header-label))
                  header-label))
              (match (lower-emit-binop
                s
                (IrBinAdd)
                (IrValueVar index-var)
                (IrValueI64 lanes)
                index-ty)
                [(LowerExpr next-s value _)
                  (begin
                    (set! s next-s)
                    (set! next-index value))])
              (match (lower-avx2-reduce-ok
                s
                index-var
                next-index
                end-value
                array-len
                lanes)
                [(LowerExpr next-s value _)
                  (begin
                    (set! s next-s)
                    (set! vector-ok value))])
              (set!
                s
                (lower-state-finish-block
                  (lower-state-emit
                    s
                    (IrInstrBranch vector-ok body-label tail-header-label))
                  body-label))
              (match (lower-avx2-reduce-vector-body
                ctx
                s
                env
                type-env
                op
                index-var
                next-index
                acc-var
                array-var
                vector-op
                elem-ty
                lanes)
                [(OkLowerExpr body-lowered)
                  (match body-lowered
                    [(LowerExpr body-state _ _)
                      (begin
                        (set! s body-state)
                        (set!
                          s
                          (lower-state-finish-block
                            (lower-state-emit s (IrInstrJump header-label))
                            tail-header-label))
                        (match (lower-emit-binop
                          s
                          (IrBinLt)
                          (IrValueVar index-var)
                          end-value
                          (AstTyBool))
                          [(LowerExpr next-s value _)
                            (begin
                              (set! s next-s)
                              (set! tail-cond value))])
                        (set!
                          s
                          (lower-state-finish-block
                            (lower-state-emit
                              s
                              (IrInstrBranch
                                tail-cond
                                tail-body-label
                                exit-label))
                            tail-body-label))
                        (match (lower-spmd-reduce-scalar-tail-body
                          ctx
                          s
                          env
                          type-env
                          op
                          index-var
                          index-ty
                          acc-var
                          array-var
                          elem-ty)
                          [(OkLowerExpr tail-lowered)
                            (match tail-lowered
                              [(LowerExpr tail-state _ _)
                                (OkLowerExpr
                                  (LowerExpr
                                    (lower-state-finish-block
                                      (lower-state-emit
                                        tail-state
                                        (IrInstrJump tail-header-label))
                                      exit-label)
                                    (IrValueVar acc-var)
                                    elem-ty))])]
                          [(ErrLowerExpr message) (ErrLowerExpr message)]))])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])))])]))

(define (lower-avx2-spmd-reduce-lowered
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index-ty : AstType]
  [start : AstExpr]
  [end : AstExpr]
  [init : AstExpr]
  [op : AstReduceOp]
  [plan : LowerMaybeVectorReduce]) : ResultLowerExpr
  (match plan
    [(LowerSomeVectorReduce array-var vector-op elem-ty lanes)
      (match (lower-expr ctx state env type-env init)
        [(OkLowerExpr init-lowered)
          (match init-lowered
            [(LowerExpr init-state init-value _)
              (match (lower-expr ctx init-state env type-env end)
                [(OkLowerExpr end-lowered)
                  (match end-lowered
                    [(LowerExpr end-state end-value _)
                      (match (lower-expr ctx end-state env type-env start)
                        [(OkLowerExpr start-lowered)
                          (match start-lowered
                            [(LowerExpr start-state start-value _)
                              (lower-avx2-spmd-reduce-build
                                ctx
                                start-state
                                env
                                type-env
                                index-ty
                                init-value
                                end-value
                                start-value
                                op
                                array-var
                                vector-op
                                elem-ty
                                lanes)])]
                        [(ErrLowerExpr message) (ErrLowerExpr message)])])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [LowerNoVectorReduce
      (ErrLowerExpr (lower-diagnostic "lower: missing vector reduce plan"))]))

(define (lower-emit-tail-mask
  [state : LowerState]
  [index : CompilerIrValue]
  [end-value : CompilerIrValue]
  [lanes : i64]) : LowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc s v)
      (LowerExpr
        (lower-state-emit s (IrInstrTailMask v index end-value lanes))
        (IrValueVar v)
        (AstTyBool))]))

(define (lower-emit-predicated-load
  [state : LowerState]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [mask : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]) : LowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc s v)
      (LowerExpr
        (lower-state-emit
          s
          (IrInstrPredicatedLoad v base index mask lanes elem-ty))
        (IrValueVar v)
        elem-ty)]))

(define (lower-emit-predicated-store
  [state : LowerState]
  [base : CompilerIrValue]
  [index : CompilerIrValue]
  [value : CompilerIrValue]
  [mask : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]) : LowerState
  (lower-state-emit
    state
    (IrInstrPredicatedStore base index value mask lanes elem-ty)))

(define (lower-avx2-vector-map-body
  [state : LowerState]
  [index-var : i64]
  [next-index : CompilerIrValue]
  [plan : LowerMaybeVectorMap]) : LowerState
  (match plan
    [(LowerSomeVectorMap dst-array lhs-array rhs-array op elem-ty lanes)
      (let
        [s : LowerState state]
        [lhs-vec : CompilerIrValue IrValueUnit]
        [rhs-vec : CompilerIrValue IrValueUnit]
        [result-vec : CompilerIrValue IrValueUnit]
        (begin
          (match (lower-emit-vector-load
            s
            (IrValueVar lhs-array)
            (IrValueVar index-var)
            lanes
            elem-ty)
            [(LowerExpr next-s value _)
              (begin
                (set! s next-s)
                (set! lhs-vec value))])
          (match (lower-emit-vector-load
            s
            (IrValueVar rhs-array)
            (IrValueVar index-var)
            lanes
            elem-ty)
            [(LowerExpr next-s value _)
              (begin
                (set! s next-s)
                (set! rhs-vec value))])
          (match (lower-emit-vector-binop s op lhs-vec rhs-vec lanes elem-ty)
            [(LowerExpr next-s value _)
              (begin
                (set! s next-s)
                (set! result-vec value))])
          (lower-state-emit
            (lower-state-emit
              s
              (IrInstrVectorStore
                (IrValueVar dst-array)
                (IrValueVar index-var)
                result-vec
                lanes
                elem-ty))
            (IrInstrMov index-var next-index (AstTyI64)))))]
    [LowerNoVectorMap state]))

(define (lower-avx2-vector-ok
  [state : LowerState]
  [index-var : i64]
  [next-index : CompilerIrValue]
  [end-value : CompilerIrValue]
  [out-len : CompilerIrValue]
  [lhs-len : CompilerIrValue]
  [rhs-len : CompilerIrValue]
  [lanes : i64]) : LowerExpr
  (let
    [s : LowerState state]
    [ok : CompilerIrValue IrValueUnit]
    [within : CompilerIrValue IrValueUnit]
    (begin
      (match (lower-emit-binop
        s
        (IrBinGe)
        (IrValueVar index-var)
        (IrValueI64 0)
        (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! ok value))])
      (match (lower-emit-binop
        s
        (IrBinLe)
        (IrValueVar index-var)
        (IrValueI64 (- 9223372036854775807 lanes))
        (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! within value))])
      (match (lower-emit-binop s (IrBinAnd) ok within (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! ok value))])
      (match (lower-emit-binop s (IrBinLe) next-index end-value (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! within value))])
      (match (lower-emit-binop s (IrBinAnd) ok within (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! ok value))])
      (match (lower-emit-binop s (IrBinLe) next-index out-len (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! within value))])
      (match (lower-emit-binop s (IrBinAnd) ok within (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! ok value))])
      (match (lower-emit-binop s (IrBinLe) next-index lhs-len (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! within value))])
      (match (lower-emit-binop s (IrBinAnd) ok within (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! ok value))])
      (match (lower-emit-binop s (IrBinLe) next-index rhs-len (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! within value))])
      (lower-emit-binop s (IrBinAnd) ok within (AstTyBool)))))

(define (lower-avx512-tail-ok
  [state : LowerState]
  [index-var : i64]
  [end-value : CompilerIrValue]
  [out-len : CompilerIrValue]
  [lhs-len : CompilerIrValue]
  [rhs-len : CompilerIrValue]) : LowerExpr
  (let
    [s : LowerState state]
    [ok : CompilerIrValue IrValueUnit]
    [within : CompilerIrValue IrValueUnit]
    (begin
      (match (lower-emit-binop
        s
        (IrBinGe)
        (IrValueVar index-var)
        (IrValueI64 0)
        (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! ok value))])
      (match (lower-emit-binop
        s
        (IrBinLe)
        (IrValueVar index-var)
        end-value
        (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! within value))])
      (match (lower-emit-binop s (IrBinAnd) ok within (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! ok value))])
      (match (lower-emit-binop s (IrBinLe) end-value out-len (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! within value))])
      (match (lower-emit-binop s (IrBinAnd) ok within (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! ok value))])
      (match (lower-emit-binop s (IrBinLe) end-value lhs-len (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! within value))])
      (match (lower-emit-binop s (IrBinAnd) ok within (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! ok value))])
      (match (lower-emit-binop s (IrBinLe) end-value rhs-len (AstTyBool))
        [(LowerExpr next-s value _)
          (begin
            (set! s next-s)
            (set! within value))])
      (lower-emit-binop s (IrBinAnd) ok within (AstTyBool)))))

(define (lower-avx512-tail-map-body
  [state : LowerState]
  [index-var : i64]
  [end-value : CompilerIrValue]
  [plan : LowerMaybeVectorMap]) : LowerState
  (match plan
    [(LowerSomeVectorMap dst-array lhs-array rhs-array op elem-ty lanes)
      (let
        [s : LowerState state]
        [mask : CompilerIrValue IrValueUnit]
        [lhs-vec : CompilerIrValue IrValueUnit]
        [rhs-vec : CompilerIrValue IrValueUnit]
        [result-vec : CompilerIrValue IrValueUnit]
        (begin
          (match (lower-emit-tail-mask s (IrValueVar index-var) end-value lanes)
            [(LowerExpr next-s value _)
              (begin
                (set! s next-s)
                (set! mask value))])
          (match (lower-emit-predicated-load
            s
            (IrValueVar lhs-array)
            (IrValueVar index-var)
            mask
            lanes
            elem-ty)
            [(LowerExpr next-s value _)
              (begin
                (set! s next-s)
                (set! lhs-vec value))])
          (match (lower-emit-predicated-load
            s
            (IrValueVar rhs-array)
            (IrValueVar index-var)
            mask
            lanes
            elem-ty)
            [(LowerExpr next-s value _)
              (begin
                (set! s next-s)
                (set! rhs-vec value))])
          (match (lower-emit-vector-binop s op lhs-vec rhs-vec lanes elem-ty)
            [(LowerExpr next-s value _)
              (begin
                (set! s next-s)
                (set! result-vec value))])
          (lower-emit-predicated-store
            s
            (IrValueVar dst-array)
            (IrValueVar index-var)
            result-vec
            mask
            lanes
            elem-ty)))]
    [LowerNoVectorMap state]))

;; Scalar `foreach` lowering (#1012). `(foreach ([i : ty start end]) body)`
;; lowers to the half-open reference loop `i = start; while (i < end) { body;
;; i = i + 1 }`, yielding unit. `start` and `end` are each lowered exactly once
;; before the loop; the index binding is scoped to the body. Mirrors lower-while
;; with an index var, a `<` guard, and a `+ 1` increment.
(define (lower-scalar-foreach-lowered
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [index-ty : AstType]
  [start-value : CompilerIrValue]
  [end-value : CompilerIrValue]
  [body : AstExpr]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc index-alloc index-var)
      (match (lower-state-fresh-label
        (lower-state-emit
          index-alloc
          (IrInstrMov index-var start-value index-ty))
        "foreach_header")
        [(LowerLabel header-ls header-label)
          (match (lower-state-fresh-label header-ls "foreach_body")
            [(LowerLabel body-ls body-label)
              (match (lower-state-fresh-label body-ls "foreach_exit")
                [(LowerLabel exit-ls exit-label)
                  (match (lower-state-alloc-var
                    (lower-state-finish-block
                      (lower-state-emit exit-ls (IrInstrJump header-label))
                      header-label))
                    [(LowerAlloc cond-alloc cond-var)
                      (match (lower-expr
                        ctx
                        (lower-state-finish-block
                          (lower-state-emit
                            (lower-state-emit
                              cond-alloc
                              (IrInstrBinOp
                                cond-var
                                IrBinLt
                                (IrValueVar index-var)
                                end-value
                                index-ty))
                            (IrInstrBranch
                              (IrValueVar cond-var)
                              body-label
                              exit-label))
                          body-label)
                        (sym-i64-bind env index index-var)
                        (tc-bind type-env index index-ty)
                        body)
                        [(OkLowerExpr body-lowered)
                          (match body-lowered
                            [(LowerExpr post-body-state _ _)
                              (match (lower-state-alloc-var post-body-state)
                                [(LowerAlloc inc-alloc inc-var)
                                  (OkLowerExpr
                                    (LowerExpr
                                      (lower-state-finish-block
                                        (lower-state-emit
                                          (lower-state-emit
                                            (lower-state-emit
                                              inc-alloc
                                              (IrInstrBinOp
                                                inc-var
                                                IrBinAdd
                                                (IrValueVar index-var)
                                                (IrValueI64 1)
                                                index-ty))
                                            (IrInstrMov
                                              index-var
                                              (IrValueVar inc-var)
                                              index-ty))
                                          (IrInstrJump header-label))
                                        exit-label)
                                      IrValueUnit
                                      (AstTyUnit)))])])]
                        [(ErrLowerExpr message) (ErrLowerExpr message)])])])])])]))

(define (lower-avx2-foreach-lowered
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [index-ty : AstType]
  [start-value : CompilerIrValue]
  [end-value : CompilerIrValue]
  [body : AstExpr]
  [plan : LowerMaybeVectorMap]) : ResultLowerExpr
  (match plan
    [(LowerSomeVectorMap dst-array lhs-array rhs-array _ _ lanes)
      (match (lower-state-alloc-var state)
        [(LowerAlloc index-alloc index-var)
          (let
            [s : LowerState
              (lower-state-emit
                index-alloc
                (IrInstrMov index-var start-value index-ty))]
            [header-label : String ""]
            [body-label : String ""]
            [tail-header-label : String ""]
            [tail-check-label : String ""]
            [tail-mask-label : String ""]
            [tail-body-label : String ""]
            [exit-label : String ""]
            [out-len : CompilerIrValue IrValueUnit]
            [lhs-len : CompilerIrValue IrValueUnit]
            [rhs-len : CompilerIrValue IrValueUnit]
            [next-index : CompilerIrValue IrValueUnit]
            [vector-ok : CompilerIrValue IrValueUnit]
            [tail-cond : CompilerIrValue IrValueUnit]
            [tail-safe : CompilerIrValue IrValueUnit]
            (begin
              (match (lower-state-fresh-label s "foreach_avx2_header")
                [(LowerLabel next-s label)
                  (begin
                    (set! s next-s)
                    (set! header-label label))])
              (match (lower-state-fresh-label s "foreach_avx2_body")
                [(LowerLabel next-s label)
                  (begin
                    (set! s next-s)
                    (set! body-label label))])
              (match (lower-state-fresh-label s "foreach_tail_header")
                [(LowerLabel next-s label)
                  (begin
                    (set! s next-s)
                    (set! tail-header-label label))])
              (match (lower-state-fresh-label s "foreach_tail_check")
                [(LowerLabel next-s label)
                  (begin
                    (set! s next-s)
                    (set! tail-check-label label))])
              (match (lower-state-fresh-label s "foreach_tail_mask")
                [(LowerLabel next-s label)
                  (begin
                    (set! s next-s)
                    (set! tail-mask-label label))])
              (match (lower-state-fresh-label s "foreach_tail_body")
                [(LowerLabel next-s label)
                  (begin
                    (set! s next-s)
                    (set! tail-body-label label))])
              (match (lower-state-fresh-label s "foreach_exit")
                [(LowerLabel next-s label)
                  (begin
                    (set! s next-s)
                    (set! exit-label label))])
              (match (lower-array-len-value s (IrValueVar dst-array))
                [(LowerExpr next-s value _)
                  (begin
                    (set! s next-s)
                    (set! out-len value))])
              (match (lower-array-len-value s (IrValueVar lhs-array))
                [(LowerExpr next-s value _)
                  (begin
                    (set! s next-s)
                    (set! lhs-len value))])
              (match (lower-array-len-value s (IrValueVar rhs-array))
                [(LowerExpr next-s value _)
                  (begin
                    (set! s next-s)
                    (set! rhs-len value))])
              (set!
                s
                (lower-state-finish-block
                  (lower-state-emit s (IrInstrJump header-label))
                  header-label))
              (match (lower-emit-binop
                s
                (IrBinAdd)
                (IrValueVar index-var)
                (IrValueI64 lanes)
                index-ty)
                [(LowerExpr next-s value _)
                  (begin
                    (set! s next-s)
                    (set! next-index value))])
              (match (lower-avx2-vector-ok
                s
                index-var
                next-index
                end-value
                out-len
                lhs-len
                rhs-len
                lanes)
                [(LowerExpr next-s value _)
                  (begin
                    (set! s next-s)
                    (set! vector-ok value))])
              (set!
                s
                (lower-state-finish-block
                  (lower-state-emit
                    s
                    (IrInstrBranch vector-ok body-label tail-header-label))
                  body-label))
              (set! s (lower-avx2-vector-map-body s index-var next-index plan))
              (set!
                s
                (lower-state-finish-block
                  (lower-state-emit s (IrInstrJump header-label))
                  tail-header-label))
              (match (lower-emit-binop
                s
                (IrBinLt)
                (IrValueVar index-var)
                end-value
                (AstTyBool))
                [(LowerExpr next-s value _)
                  (begin
                    (set! s next-s)
                    (set! tail-cond value))])
              (set!
                s
                (if (lower-mode-avx512? (lower-state-mode s))
                  (lower-state-finish-block
                    (lower-state-emit
                      s
                      (IrInstrBranch tail-cond tail-check-label exit-label))
                    tail-check-label)
                  (lower-state-finish-block
                    (lower-state-emit
                      s
                      (IrInstrBranch tail-cond tail-body-label exit-label))
                    tail-body-label)))
              (if (lower-mode-avx512? (lower-state-mode s))
                (begin
                  (match (lower-avx512-tail-ok
                    s
                    index-var
                    end-value
                    out-len
                    lhs-len
                    rhs-len)
                    [(LowerExpr next-s value _)
                      (begin
                        (set! s next-s)
                        (set! tail-safe value))])
                  (set!
                    s
                    (lower-state-finish-block
                      (lower-state-emit
                        s
                        (IrInstrBranch
                          tail-safe
                          tail-mask-label
                          tail-body-label))
                      tail-mask-label))
                  (set!
                    s
                    (lower-avx512-tail-map-body s index-var end-value plan))
                  (set!
                    s
                    (lower-state-finish-block
                      (lower-state-emit s (IrInstrJump exit-label))
                      tail-body-label)))
                unit)
              (match (lower-expr
                ctx
                s
                (sym-i64-bind env index index-var)
                (tc-bind type-env index index-ty)
                body)
                [(OkLowerExpr body-lowered)
                  (match body-lowered
                    [(LowerExpr post-body-state _ _)
                      (match (lower-state-alloc-var post-body-state)
                        [(LowerAlloc inc-alloc inc-var)
                          (OkLowerExpr
                            (LowerExpr
                              (lower-state-finish-block
                                (lower-state-emit
                                  (lower-state-emit
                                    (lower-state-emit
                                      inc-alloc
                                      (IrInstrBinOp
                                        inc-var
                                        IrBinAdd
                                        (IrValueVar index-var)
                                        (IrValueI64 1)
                                        index-ty))
                                    (IrInstrMov
                                      index-var
                                      (IrValueVar inc-var)
                                      index-ty))
                                  (IrInstrJump tail-header-label))
                                exit-label)
                              IrValueUnit
                              (AstTyUnit)))])])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])))])]
    [LowerNoVectorMap
      (lower-scalar-foreach-lowered
        ctx
        state
        env
        type-env
        index
        index-ty
        start-value
        end-value
        body)]))

(define (lower-foreach-lowered
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [index-ty : AstType]
  [start-value : CompilerIrValue]
  [end-value : CompilerIrValue]
  [body : AstExpr]) : ResultLowerExpr
  (if (and
    (lower-mode-simd? (lower-state-mode state))
    (lower-type-i64? index-ty))
    (match (lower-simple-vector-map
      (lower-state-mode state)
      env
      type-env
      index
      body)
      [(LowerSomeVectorMap _ _ _ _ _ _)
        (lower-avx2-foreach-lowered
          ctx
          state
          env
          type-env
          index
          index-ty
          start-value
          end-value
          body
          (lower-simple-vector-map
            (lower-state-mode state)
            env
            type-env
            index
            body))]
      [LowerNoVectorMap
        (lower-scalar-foreach-lowered
          ctx
          state
          env
          type-env
          index
          index-ty
          start-value
          end-value
          body)])
    (lower-scalar-foreach-lowered
      ctx
      state
      env
      type-env
      index
      index-ty
      start-value
      end-value
      body)))

(define (lower-foreach
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [index-ty : AstType]
  [start : AstExpr]
  [end : AstExpr]
  [body : AstExpr]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env start)
    [(OkLowerExpr start-lowered)
      (match start-lowered
        [(LowerExpr start-state start-value _)
          (match (lower-expr ctx start-state env type-env end)
            [(OkLowerExpr end-lowered)
              (match end-lowered
                [(LowerExpr end-state end-value _)
                  (lower-foreach-lowered
                    ctx
                    end-state
                    env
                    type-env
                    index
                    index-ty
                    start-value
                    end-value
                    body)])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

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
                    scrut-ty
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
                    scrut-ty
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
  [scrut-ty : AstType]
  [variant-name : String]
  [args : AstPatternList]
  [body : AstExpr]
  [merge-label : String]
  [expr-ty : AstType]
  [phi-inputs : CompilerIrPhiInputList]) : ResultLowerExpr
  (match ctx
    [(TcContext program _ registries _)
      (let
        [lookup-name : String
          (match (tc-type-strip-region scrut-ty)
            [(AstTyEnum enum-name)
              (tc-variant-name-for-enum enum-name variant-name)]
            [_ variant-name])]
        (match (compiler-registries-lookup-variant registries lookup-name)
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
                    (lower-state-mode state)
                    (lower-enum-type-name-or-empty scrut-ty)
                    variant-name
                    0
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
                            [(LowerExpr body-state body-value body-ty)
                              (let
                                [body-end-label : String
                                  (lower-state-current-label body-state)]
                                (if (tc-never-type? body-ty)
                                  (lower-match-finish
                                    body-state
                                    merge-label
                                    expr-ty
                                    phi-inputs)
                                  (lower-match-finish
                                    (lower-state-emit
                                      body-state
                                      (IrInstrJump merge-label))
                                    merge-label
                                    expr-ty
                                    (IrPhiInputCons
                                      (IrPhiInput body-value body-end-label)
                                      phi-inputs))))])]
                        [(ErrLowerExpr message) (ErrLowerExpr message)])]
                    [(ErrLowerEnv message) (ErrLowerExpr message)]))]
              [(ErrAstTypeList message)
                (ErrLowerExpr (lower-diagnostic message))])]
          [(NoneI64)
            (ErrLowerExpr
              (lower-diagnostic
                (string-append "lower: unknown variant " variant-name)))]))]))

(define (lower-match-variant-body
  [ctx : TcContext]
  [body-start : LowerState]
  [next-label : String]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrut-var : i64]
  [scrut-ty : AstType]
  [tag-var : i64]
  [variant-name : String]
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
    (lower-state-mode body-start)
    (lower-enum-type-name-or-empty scrut-ty)
    variant-name
    0
    8
    next-label)
    [(OkLowerEnv bound-state body-env body-type-env)
      (match (lower-expr ctx bound-state body-env body-type-env body)
        [(OkLowerExpr body-lowered)
          (match body-lowered
            [(LowerExpr body-state body-value body-ty)
              (let
                [body-end-label : String (lower-state-current-label body-state)]
                (lower-match-enum-arms
                  ctx
                  (if (tc-never-type? body-ty)
                    (lower-state-finish-block body-state next-label)
                    (lower-state-finish-block
                      (lower-state-emit body-state (IrInstrJump merge-label))
                      next-label))
                  env
                  type-env
                  scrut-var
                  scrut-ty
                  tag-var
                  rest
                  merge-label
                  expr-ty
                  (if (tc-never-type? body-ty)
                    phi-inputs
                    (IrPhiInputCons
                      (IrPhiInput body-value body-end-label)
                      phi-inputs))))])]
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
    [(TcContext program _ registries _)
      (let
        [lookup-name : String
          (match (tc-type-strip-region scrut-ty)
            [(AstTyEnum enum-name)
              (tc-variant-name-for-enum enum-name variant-name)]
            [_ variant-name])]
        (match (compiler-registries-lookup-variant registries lookup-name)
          [(SomeI64 handle)
            (match (compiler-registries-variant-fields program handle)
              [(OkAstTypeList fields)
                (match (lower-state-alloc-var state)
                  [(LowerAlloc eq-alloc eq-var)
                    (let
                      [eq-state : LowerState
                        (lower-state-emit
                          eq-alloc
                          (IrInstrBinOp
                            eq-var
                            IrBinEq
                            (IrValueVar tag-var)
                            (IrValueI64
                              (compiler-registry-handle-child-index handle))
                            (AstTyI64)))]
                      (match (lower-state-fresh-label eq-state "match_arm")
                        [(LowerLabel body-label-state body-label)
                          (match (lower-state-fresh-label
                            body-label-state
                            "match_next")
                            [(LowerLabel next-label-state next-label)
                              (let
                                [body-start : LowerState
                                  (lower-state-finish-block
                                    (lower-state-emit
                                      next-label-state
                                      (IrInstrBranch
                                        (IrValueVar eq-var)
                                        body-label
                                        next-label))
                                    body-label)]
                                (lower-match-variant-body
                                  ctx
                                  body-start
                                  next-label
                                  env
                                  type-env
                                  scrut-var
                                  scrut-ty
                                  tag-var
                                  variant-name
                                  fields
                                  args
                                  body
                                  rest
                                  merge-label
                                  expr-ty
                                  phi-inputs))])]))])]
              [(ErrAstTypeList message)
                (ErrLowerExpr (lower-diagnostic message))])]
          [(NoneI64)
            (ErrLowerExpr
              (lower-diagnostic
                (string-append "lower: unknown variant " variant-name)))]))]))

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
      (let
        [eq-state : LowerState
          (lower-state-emit
            eq-alloc
            (IrInstrBinOp
              eq-var
              IrBinEq
              (IrValueVar scrut-var)
              (lower-literal-value lit)
              scrut-ty))]
        (match (lower-state-fresh-label eq-state "match_arm")
          [(LowerLabel body-label-state body-label)
            (match (lower-state-fresh-label body-label-state "match_next")
              [(LowerLabel next-label-state next-label)
                (let
                  [body-start : LowerState
                    (lower-state-finish-block
                      (lower-state-emit
                        next-label-state
                        (IrInstrBranch
                          (IrValueVar eq-var)
                          body-label
                          next-label))
                      body-label)]
                  (match (lower-expr ctx body-start env type-env body)
                    [(OkLowerExpr body-lowered)
                      (match body-lowered
                        [(LowerExpr body-state body-value body-ty)
                          (let
                            [body-end-label : String
                              (lower-state-current-label body-state)]
                            (lower-match-arms
                              ctx
                              (if (tc-never-type? body-ty)
                                (lower-state-finish-block body-state next-label)
                                (lower-state-finish-block
                                  (lower-state-emit
                                    body-state
                                    (IrInstrJump merge-label))
                                  next-label))
                              env
                              type-env
                              scrut-var
                              scrut-ty
                              rest
                              merge-label
                              expr-ty
                              (if (tc-never-type? body-ty)
                                phi-inputs
                                (IrPhiInputCons
                                  (IrPhiInput body-value body-end-label)
                                  phi-inputs))))])]
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
      (let
        [body-env : SymI64Env
          (match pat
            [(AstPatBinding name) (sym-i64-bind env name scrut-var)]
            [_ env])]
        [body-type-env : TcTypeEnv
          (match pat
            [(AstPatBinding name) (tc-bind type-env name scrut-ty)]
            [_ type-env])]
        (match (lower-expr ctx state body-env body-type-env body)
          [(OkLowerExpr body-lowered)
            (match body-lowered
              [(LowerExpr body-state body-value body-ty)
                (let
                  [body-end-label : String
                    (lower-state-current-label body-state)]
                  (if (tc-never-type? body-ty)
                    (lower-match-finish
                      body-state
                      merge-label
                      expr-ty
                      phi-inputs)
                    (lower-match-finish
                      (lower-state-emit body-state (IrInstrJump merge-label))
                      merge-label
                      expr-ty
                      (IrPhiInputCons
                        (IrPhiInput body-value body-end-label)
                        phi-inputs))))])]
          [(ErrLowerExpr message) (ErrLowerExpr message)]))]))

(define (lower-phi-input-list-empty? [phi-inputs : CompilerIrPhiInputList]) : bool
  (match phi-inputs
    [(IrPhiInputNil) true]
    [_ false]))

(define (lower-match-finish
  [state : LowerState]
  [merge-label : String]
  [expr-ty : AstType]
  [phi-inputs : CompilerIrPhiInputList]) : ResultLowerExpr
  (let
    [merge-start : LowerState (lower-state-finish-block state merge-label)]
    (if (lower-phi-input-list-empty? phi-inputs)
      (OkLowerExpr (LowerExpr merge-start IrValueUnit (AstTyNever)))
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
                  expr-ty))])]))))

(define (lower-tail-call-target?
  [state : LowerState]
  [env : SymI64Env]
  [callee : AstExpr]) : bool
  (match (ast-expr-unspan callee)
    [(AstExprVar name)
      (match (sym-i64-lookup env name)
        [(SomeI64 _) false]
        [(NoneI64)
          (string-eq
            (lower-resolve-name state name)
            (lower-state-current-function state))])]
    [_ false]))

(define (lower-tail-let-bindings-candidate-env
  [env : SymI64Env]
  [bindings : AstLetBindingList]) : SymI64Env
  (match bindings
    [(AstLetBindingNil) env]
    [(AstLetBindingCons binding rest)
      (match binding
        [(AstLetBinding name _ _)
          (lower-tail-let-bindings-candidate-env (sym-i64-bind env name 0) rest)])]))

(define (lower-tail-begin-candidate?
  [state : LowerState]
  [env : SymI64Env]
  [exprs : AstExprList]) : bool
  (match exprs
    [(AstExprNil) false]
    [(AstExprCons expr rest)
      (match rest
        [(AstExprNil) (lower-tail-expr-candidate? state env expr)]
        [_ (lower-tail-begin-candidate? state env rest)])]))

(define (lower-tail-match-arms-candidate?
  [state : LowerState]
  [env : SymI64Env]
  [arms : AstMatchArmList]) : bool
  (match arms
    [(AstMatchArmNil) false]
    [(AstMatchArmCons arm rest)
      (match arm
        [(AstMatchArm pat body)
          (let
            [body-env : SymI64Env
              (match pat
                [(AstPatBinding name) (sym-i64-bind env name 0)]
                [_ env])]
            (if (lower-tail-expr-candidate? state body-env body)
              true
              (lower-tail-match-arms-candidate? state env rest)))])]))

(define (lower-tail-expr-candidate?
  [state : LowerState]
  [env : SymI64Env]
  [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner _) (lower-tail-expr-candidate? state env inner)]
    [(AstExprAnn inner _) (lower-tail-expr-candidate? state env inner)]
    [(AstExprCast inner _) (lower-tail-expr-candidate? state env inner)]
    [(AstExprCall callee _) (lower-tail-call-target? state env callee)]
    [(AstExprLet bindings body)
      (lower-tail-expr-candidate?
        state
        (lower-tail-let-bindings-candidate-env env bindings)
        body)]
    [(AstExprBegin exprs) (lower-tail-begin-candidate? state env exprs)]
    [(AstExprUnsafe exprs) (lower-tail-begin-candidate? state env exprs)]
    [(AstExprIf _ then-branch else-branch)
      (if (lower-tail-expr-candidate? state env then-branch)
        true
        (lower-tail-expr-candidate? state env else-branch))]
    [(AstExprMatch _ arms) (lower-tail-match-arms-candidate? state env arms)]
    [_ false]))

(define (lower-return-expr
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [expr : AstExpr]
  [ret-ty : AstType]) : ResultLowerState
  (match (lower-expr-expected ctx state env type-env expr ret-ty expr)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr body-state value expr-ty)
          (if (tc-never-type? expr-ty)
            (OkLowerState body-state)
            (OkLowerState
              (lower-state-emit
                body-state
                (IrInstrReturn (lower-return-maybe value ret-ty)))))])]
    [(ErrLowerExpr message) (ErrLowerState message)]))

(define (lower-tail-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [callee : AstExpr]
  [args : AstExprList]
  [ret-ty : AstType]
  [origin : AstExpr]) : ResultLowerState
  (if (lower-tail-call-target? state env callee)
    (match (lower-args ctx state env type-env args)
      [(OkLowerArgs args-state values)
        (OkLowerState
          (lower-state-emit-at-expr
            args-state
            (IrInstrTailCall
              (lower-state-current-function args-state)
              values
              ret-ty)
            origin))]
      [(ErrLowerArgs message) (ErrLowerState message)])
    (lower-return-expr ctx state env type-env origin ret-ty)))

(define (lower-tail-begin
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [exprs : AstExprList]
  [ret-ty : AstType]) : ResultLowerState
  (match exprs
    [(AstExprNil)
      (OkLowerState
        (lower-state-emit
          state
          (IrInstrReturn (lower-return-maybe IrValueUnit ret-ty))))]
    [(AstExprCons expr rest)
      (match rest
        [(AstExprNil) (lower-tail-expr ctx state env type-env expr ret-ty)]
        [_
          (match (lower-expr ctx state env type-env expr)
            [(OkLowerExpr lowered)
              (match lowered
                [(LowerExpr next-state _ expr-ty)
                  (if (tc-never-type? expr-ty)
                    (OkLowerState next-state)
                    (lower-tail-begin ctx next-state env type-env rest ret-ty))])]
            [(ErrLowerExpr message) (ErrLowerState message)])])]))

(define (lower-tail-if
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [cond : AstExpr]
  [then-branch : AstExpr]
  [else-branch : AstExpr]
  [ret-ty : AstType]) : ResultLowerState
  (match (lower-expr ctx state env type-env cond)
    [(OkLowerExpr cond-lowered)
      (match cond-lowered
        [(LowerExpr cond-state cond-value _)
          (match (lower-state-fresh-label cond-state "if_then")
            [(LowerLabel then-label-state then-label)
              (match (lower-state-fresh-label then-label-state "if_else")
                [(LowerLabel else-label-state else-label)
                  (let
                    [branch-state : LowerState
                      (lower-state-emit
                        else-label-state
                        (IrInstrBranch cond-value then-label else-label))]
                    (match (lower-tail-expr
                      ctx
                      (lower-state-finish-block branch-state then-label)
                      env
                      type-env
                      then-branch
                      ret-ty)
                      [(OkLowerState then-state)
                        (lower-tail-expr
                          ctx
                          (lower-state-finish-block then-state else-label)
                          env
                          type-env
                          else-branch
                          ret-ty)]
                      [(ErrLowerState message) (ErrLowerState message)]))])])])]
    [(ErrLowerExpr message) (ErrLowerState message)]))

(define (lower-tail-match-arms
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrut-var : i64]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]
  [ret-ty : AstType]) : ResultLowerState
  (match arms
    [(AstMatchArmNil)
      (ErrLowerState (lower-diagnostic "lower: match with no arms"))]
    [(AstMatchArmCons arm rest)
      (match rest
        [(AstMatchArmNil)
          (lower-tail-match-catch-all
            ctx
            state
            env
            type-env
            scrut-var
            scrut-ty
            arm
            ret-ty)]
        [_
          (match arm
            [(AstMatchArm pat body)
              (match pat
                [(AstPatLiteral lit)
                  (lower-tail-match-literal-arm
                    ctx
                    state
                    env
                    type-env
                    scrut-var
                    scrut-ty
                    lit
                    body
                    rest
                    ret-ty)]
                [(AstPatBinding _)
                  (lower-tail-match-catch-all
                    ctx
                    state
                    env
                    type-env
                    scrut-var
                    scrut-ty
                    arm
                    ret-ty)]
                [(AstPatWildcard)
                  (lower-tail-match-catch-all
                    ctx
                    state
                    env
                    type-env
                    scrut-var
                    scrut-ty
                    arm
                    ret-ty)]
                [_
                  (ErrLowerState
                    (lower-diagnostic "lower: unsupported match pattern"))])])])]))

(define (lower-tail-match-literal-arm
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrut-var : i64]
  [scrut-ty : AstType]
  [lit : AstLiteral]
  [body : AstExpr]
  [rest : AstMatchArmList]
  [ret-ty : AstType]) : ResultLowerState
  (match (lower-state-alloc-var state)
    [(LowerAlloc eq-alloc eq-var)
      (let
        [eq-state : LowerState
          (lower-state-emit
            eq-alloc
            (IrInstrBinOp
              eq-var
              IrBinEq
              (IrValueVar scrut-var)
              (lower-literal-value lit)
              scrut-ty))]
        (match (lower-state-fresh-label eq-state "match_arm")
          [(LowerLabel body-label-state body-label)
            (match (lower-state-fresh-label body-label-state "match_next")
              [(LowerLabel next-label-state next-label)
                (let
                  [body-start : LowerState
                    (lower-state-finish-block
                      (lower-state-emit
                        next-label-state
                        (IrInstrBranch
                          (IrValueVar eq-var)
                          body-label
                          next-label))
                      body-label)]
                  (match (lower-tail-expr
                    ctx
                    body-start
                    env
                    type-env
                    body
                    ret-ty)
                    [(OkLowerState body-state)
                      (lower-tail-match-arms
                        ctx
                        (lower-state-finish-block body-state next-label)
                        env
                        type-env
                        scrut-var
                        scrut-ty
                        rest
                        ret-ty)]
                    [(ErrLowerState message) (ErrLowerState message)]))])]))]))

(define (lower-tail-match-catch-all
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrut-var : i64]
  [scrut-ty : AstType]
  [arm : AstMatchArm]
  [ret-ty : AstType]) : ResultLowerState
  (match arm
    [(AstMatchArm pat body)
      (let
        [body-env : SymI64Env
          (match pat
            [(AstPatBinding name) (sym-i64-bind env name scrut-var)]
            [_ env])]
        [body-type-env : TcTypeEnv
          (match pat
            [(AstPatBinding name) (tc-bind type-env name scrut-ty)]
            [_ type-env])]
        (lower-tail-expr ctx state body-env body-type-env body ret-ty))]))

(define (lower-tail-match
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [scrutinee : AstExpr]
  [arms : AstMatchArmList]
  [ret-ty : AstType]
  [origin : AstExpr]) : ResultLowerState
  (match (lower-expr ctx state env type-env scrutinee)
    [(OkLowerExpr scrut-lowered)
      (match scrut-lowered
        [(LowerExpr scrut-state scrut-value scrut-ty)
          (match (tc-resolve-type ctx scrut-ty)
            [(AstTyEnum _)
              (lower-return-expr ctx state env type-env origin ret-ty)]
            [_
              (match (lower-state-alloc-var scrut-state)
                [(LowerAlloc scrut-alloc scrut-var)
                  (lower-tail-match-arms
                    ctx
                    (lower-state-emit
                      scrut-alloc
                      (IrInstrMov scrut-var scrut-value scrut-ty))
                    env
                    type-env
                    scrut-var
                    scrut-ty
                    arms
                    ret-ty)])])])]
    [(ErrLowerExpr message) (ErrLowerState message)]))

(define (lower-tail-expr
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [expr : AstExpr]
  [ret-ty : AstType]) : ResultLowerState
  (if (lower-tail-expr-candidate? state env expr)
    (match expr
      [(AstExprSpanned inner _)
        (lower-tail-expr ctx state env type-env inner ret-ty)]
      [(AstExprAnn inner _)
        (lower-tail-expr ctx state env type-env inner ret-ty)]
      [(AstExprCast inner _)
        (match (tc-expr ctx type-env inner)
          [(OkTcType inner-ty)
            (if (tc-type-eq (tc-type-without-regions inner-ty) ret-ty)
              (lower-tail-expr ctx state env type-env inner ret-ty)
              (lower-return-expr ctx state env type-env expr ret-ty))]
          [(ErrTcType message)
            (ErrLowerState (lower-diagnostic-at-expr inner message))])]
      [(AstExprCall callee args)
        (lower-tail-call ctx state env type-env callee args ret-ty expr)]
      [(AstExprLet bindings body)
        (match (lower-let-bindings ctx state env type-env bindings)
          [(OkLowerEnv binding-state body-env body-type-env)
            (lower-tail-expr
              ctx
              binding-state
              body-env
              body-type-env
              body
              ret-ty)]
          [(ErrLowerEnv message) (ErrLowerState message)])]
      [(AstExprBegin exprs)
        (lower-tail-begin ctx state env type-env exprs ret-ty)]
      [(AstExprUnsafe exprs)
        (lower-tail-begin ctx state env (tc-enter-unsafe type-env) exprs ret-ty)]
      [(AstExprIf cond then-branch else-branch)
        (lower-tail-if
          ctx
          state
          env
          type-env
          cond
          then-branch
          else-branch
          ret-ty)]
      [(AstExprMatch scrutinee arms)
        (lower-tail-match ctx state env type-env scrutinee arms ret-ty expr)]
      [_ (lower-return-expr ctx state env type-env expr ret-ty)])
    (lower-return-expr ctx state env type-env expr ret-ty)))

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
        [(AstParam name _ _)
          (lower-bind-params rest (+ idx 1) (sym-i64-bind env name idx))])]))

(define (lower-param-list [ctx : TcContext] [params : AstParamList] [idx : i64]) : CompilerIrParamList
  (match params
    [(AstParamNil) IrParamNil]
    [(AstParamCons param rest)
      (match param
        [(AstParam name ty _)
          (IrParamCons
            (IrParam
              name
              (tc-type-without-regions (tc-resolve-type ctx ty))
              idx)
            (lower-param-list ctx rest (+ idx 1)))])]))

(define (lower-supported-function-param-type? [ctx : TcContext] [ty : AstType]) : bool
  (lower-supported-reference-type? ctx ty))

(define (lower-inline-aggregate-abi-message) : String
  "lower: inline aggregate mode does not support aggregate function params or returns (#1724)")

(define (lower-type-contains-inline-aggregate? [ctx : TcContext] [ty : AstType]) : bool
  (match (tc-type-strip-region (tc-resolve-type ctx ty))
    [(AstTyStruct _) true]
    [(AstTyEnum _) true]
    [(AstTyTuple elems) (lower-type-list-contains-inline-aggregate? ctx elems)]
    [(AstTyArray elem _) (lower-type-contains-inline-aggregate? ctx elem)]
    [(AstTyRegion _ inner) (lower-type-contains-inline-aggregate? ctx inner)]
    [_ false]))

(define (lower-type-list-contains-inline-aggregate?
  [ctx : TcContext]
  [types : AstTypeList]) : bool
  (match types
    [(AstTypeNil) false]
    [(AstTypeCons ty rest)
      (or
        (lower-type-contains-inline-aggregate? ctx ty)
        (lower-type-list-contains-inline-aggregate? ctx rest))]))

(define (lower-param-list-contains-inline-aggregate?
  [ctx : TcContext]
  [params : AstParamList]) : bool
  (match params
    [(AstParamNil) false]
    [(AstParamCons param rest)
      (match param
        [(AstParam _ ty _)
          (or
            (lower-type-contains-inline-aggregate? ctx ty)
            (lower-param-list-contains-inline-aggregate? ctx rest))])]))

(define (lower-param-list-contains-unsupported-reference?
  [ctx : TcContext]
  [params : AstParamList]) : bool
  (match params
    [(AstParamNil) false]
    [(AstParamCons param rest)
      (match param
        [(AstParam _ ty _)
          (or
            (not (lower-supported-function-param-type? ctx ty))
            (lower-param-list-contains-unsupported-reference? ctx rest))])]))

(define (lower-function
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [logical-name : String]
  [params : AstParamList]
  [ret : AstType]
  [body : AstExpr]
  [spans : CompilerSourceSpans]
  [names : LowerNameCache]
  [mode : CompilerLowerMode]) : ResultLowerFunction
  (if (or
    (lower-param-list-contains-unsupported-reference? ctx params)
    (not (lower-supported-reference-type? ctx ret)))
    (ErrLowerFunction (lower-diagnostic (lower-reference-support-message)))
    (if (and
      (lower-mode-inline-aggregates? mode)
      (or
        (lower-param-list-contains-inline-aggregate? ctx params)
        (lower-type-contains-inline-aggregate? ctx ret)))
      (ErrLowerFunction (lower-diagnostic (lower-inline-aggregate-abi-message)))
      (let
        [param-count : i64 (lower-param-count params)]
        [env : SymI64Env (lower-bind-params params 0 (sym-i64-empty))]
        [type-env : TcTypeEnv
          (tc-bind-return-type
            (tc-bind-params ctx top-env params)
            (tc-type-without-regions (tc-resolve-type ctx ret)))]
        [function-spans : CompilerSourceSpans
          (lower-record-function-span spans logical-name body)]
        [state : LowerState
          (LowerState
            param-count
            0
            0
            "entry"
            IrInstrNil
            IrBlockNil
            IrFunctionNil
            logical-name
            function-spans
            names
            mode)]
        [ret-ty : AstType (tc-type-without-regions (tc-resolve-type ctx ret))]
        (match (lower-tail-expr ctx state env type-env body ret-ty)
          [(OkLowerState final-state)
            (OkLowerFunction
              (IrFunctionCons
                (IrFunction
                  logical-name
                  (lower-param-list ctx params 0)
                  ret-ty
                  (lower-state-next-var final-state)
                  (lower-state-build-blocks final-state))
                (lower-state-functions final-state))
              (lower-state-spans final-state))]
          [(ErrLowerState message) (ErrLowerFunction message)])))))

(define (lower-global-value [names : LowerNameCache] [expr : AstExpr]) : ResultLowerValue
  (match expr
    [(AstExprSpanned inner _) (lower-global-value names inner)]
    [(AstExprAnn inner _) (lower-global-value names inner)]
    [(AstExprCast inner _) (lower-global-value names inner)]
    [(AstExprLiteral lit) (OkLowerValue (lower-literal-value lit))]
    [(AstExprVar name)
      (OkLowerValue (IrValueGlobal (lower-name-cache-resolve names name)))]
    [_
      (ErrLowerValue (lower-diagnostic "lower: unsupported global initializer"))]))

(define (lower-global-init-function-name [global-name : String]) : String
  (string-append "__global_init_" global-name))

;; Record `name -> body span` into the provenance table (#605). A function whose
;;
;; body carries no source span leaves the table unchanged, so the backend simply
;;
;; falls back to its default location for that function.
(define (lower-record-function-span
  [spans : CompilerSourceSpans]
  [name : String]
  [body : AstExpr]) : CompilerSourceSpans
  (match (lower-ast-expr-span body)
    [(CompilerSomeSourceSpan span)
      (compiler-source-spans-insert spans name span)]
    [(CompilerNoSourceSpan) spans]))

;; Per-function arena escape for lowering (#1633). Lowering one function allocates
;; a fresh LowerState plus all the transient IR/AST-walk scratch that the bump
;; allocator never frees; across thousands of functions this is the ~9 GB the
;; lower phase adds. We lower each function inside its own scratch arena, deep-
;; `clone` ONLY the produced IR function list into the enclosing (program) arena,
;; then destroy the scratch — reclaiming the per-function transient. The growing
;; spans side-table is DROPPED (returns the unchanged input spans): it never
;; affects emitted assembly, only backend-error source locations, and cloning the
;; monotonically-growing accumulator per function would be O(n^2). `enclosing` is
;; captured fresh and `scratch`'s grown head re-read before destroy so nothing
;; leaks. Output stays byte-identical (same proof as the optimizer escape).
;; TODO(#1688): migrate this hand-rolled arena escape to `with-escape` after the
;; bootstrapping stage0 parser supports the new form.
(define (lower-function-escaping
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [logical-name : String]
  [params : AstParamList]
  [ret : AstType]
  [body : AstExpr]
  [spans : CompilerSourceSpans]
  [names : LowerNameCache]
  [mode : CompilerLowerMode]) : ResultLowerFunction
  (let
    [enclosing : i64 (arena-current)]
    [scratch : i64 (arena-make)]
    (begin
      (unsafe (arena-set! scratch))
      (match (lower-function
        ctx
        top-env
        logical-name
        params
        ret
        body
        spans
        names
        mode)
        [(OkLowerFunction fns _function-spans)
          (let
            [scratch-head : i64 (arena-current)]
            (begin
              (unsafe (arena-set! enclosing))
              (let
                [escaped-fns : CompilerIrFunctionList (clone fns)]
                [escaped-spans : CompilerSourceSpans
                  (lower-record-function-span spans logical-name body)]
                (begin
                  (unsafe (arena-destroy scratch-head))
                  (OkLowerFunction escaped-fns escaped-spans)))))]
        [(ErrLowerFunction message)
          (let
            [scratch-head : i64 (arena-current)]
            (begin
              (unsafe (arena-set! enclosing))
              (let
                [escaped-message : CompilerDiagnostic (clone message)]
                (begin
                  (unsafe (arena-destroy scratch-head))
                  (ErrLowerFunction escaped-message)))))]))))

(define (lower-decls
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [decls : AstDeclList]
  [globals : CompilerIrGlobalList]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [spans : CompilerSourceSpans]
  [names : LowerNameEnv]
  [mode : CompilerLowerMode]) : ResultLowerDecls
  (lower-decls-in-module
    ctx
    top-env
    top-env
    decls
    globals
    functions
    externs
    spans
    names
    (lower-name-cache-from-env names)
    mode
    ""))

(define (lower-decls-in-module
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [local-top-env : TcTypeEnv]
  [decls : AstDeclList]
  [globals : CompilerIrGlobalList]
  [functions : CompilerIrFunctionList]
  [externs : CompilerIrExternList]
  [spans : CompilerSourceSpans]
  [names : LowerNameEnv]
  [name-cache : LowerNameCache]
  [mode : CompilerLowerMode]
  [module : String]) : ResultLowerDecls
  (match decls
    [(AstDeclNil)
      (OkLowerDecls
        (lower-global-list-reverse globals)
        (lower-function-list-reverse functions)
        (lower-extern-list-reverse externs)
        spans)]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclDef name _ expr)
          (let
            [decl-ctx : TcContext (tc-context-with-module ctx module)]
            (match (tc-top-decl-type-with-env decl-ctx local-top-env decl)
              [(OkTcType ty)
                (let
                  [global-ty : AstType (tc-type-without-regions ty)]
                  [global-name : String
                    (lower-current-decl-logical-name names module name)]
                  (match (lower-global-value name-cache expr)
                    [(OkLowerValue value)
                      (lower-decls-in-module
                        ctx
                        top-env
                        local-top-env
                        rest
                        (IrGlobalCons
                          (IrGlobal global-name global-ty value)
                          globals)
                        functions
                        externs
                        spans
                        names
                        name-cache
                        mode
                        module)]
                    ;; A global whose initializer is not a compile-time
                    ;; constant is evaluated at startup by a hidden
                    ;; `__global_init_<name>` function whose return value the
                    ;; backend stores into the global before `main`. This
                    ;; applies to any non-unit type (scalars as well as
                    ;; aggregates), mirroring the former Rust lowerer, which
                    ;; emits an init function whenever `extract_const` yields
                    ;; no constant.
                    [(ErrLowerValue _)
                      (match (lower-function-escaping
                        decl-ctx
                        local-top-env
                        (lower-global-init-function-name global-name)
                        AstParamNil
                        global-ty
                        expr
                        spans
                        name-cache
                        mode)
                        [(OkLowerFunction init-funcs init-spans)
                          (lower-decls-in-module
                            ctx
                            top-env
                            local-top-env
                            rest
                            (IrGlobalCons
                              (IrGlobal global-name global-ty IrValueUnit)
                              globals)
                            (lower-function-list-append
                              init-funcs
                              functions)
                            externs
                            init-spans
                            names
                            name-cache
                            mode
                            module)]
                        [(ErrLowerFunction init-message)
                          (ErrLowerDecls init-message)])]))]
              [(ErrTcType message)
                (ErrLowerDecls (lower-diagnostic message))]))]
        [(AstDeclExtern name metadata ty)
          (let
            [decl-ctx : TcContext (tc-context-with-module ctx module)]
            (if (tc-type-contains-reference? (tc-resolve-type decl-ctx ty))
              (ErrLowerDecls
                (lower-diagnostic (lower-reference-support-message)))
              (lower-decls-in-module
                ctx
                top-env
                local-top-env
                rest
                globals
                functions
                (IrExternCons
                  (IrExtern
                    name
                    (tc-type-without-regions (tc-resolve-type decl-ctx ty))
                    (ast-extern-metadata-abi metadata)
                    (ast-extern-metadata-symbol metadata)
                    (ast-extern-metadata-link-inputs metadata))
                  externs)
                spans
                names
                name-cache
                mode
                module)))]
        [(AstDeclDefFn name params ret body)
          (let
            [decl-ctx : TcContext (tc-context-with-module ctx module)]
            (match (lower-function-escaping
              decl-ctx
              local-top-env
              (lower-current-decl-logical-name names module name)
              params
              ret
              body
              spans
              name-cache
              mode)
              [(OkLowerFunction lowered-functions function-spans)
                (lower-decls-in-module
                  ctx
                  top-env
                  local-top-env
                  rest
                  globals
                  (lower-function-list-append lowered-functions functions)
                  externs
                  function-spans
                  names
                  name-cache
                  mode
                  module)]
              [(ErrLowerFunction message) (ErrLowerDecls message)]))]
        [(AstDeclDefMacro _ _ _ _)
          (lower-decls-in-module
            ctx
            top-env
            local-top-env
            rest
            globals
            functions
            externs
            spans
            names
            name-cache
            mode
            module)]
        [(AstDeclImport _)
          (lower-decls-in-module
            ctx
            top-env
            local-top-env
            rest
            globals
            functions
            externs
            spans
            names
            name-cache
            mode
            module)]
        [(AstDeclExport _)
          (lower-decls-in-module
            ctx
            top-env
            local-top-env
            rest
            globals
            functions
            externs
            spans
            names
            name-cache
            mode
            module)]
        [(AstDeclModule next-module)
          (match (tc-module-local-env ctx top-env next-module)
            [(OkTcEnv next-local-top-env)
              (let
                [local-names : LowerNameEnv
                  (lower-module-local-names ctx names next-module)]
                (lower-decls-in-module
                  ctx
                  top-env
                  next-local-top-env
                  rest
                  globals
                  functions
                  externs
                  spans
                  names
                  (lower-name-cache-from-env local-names)
                  mode
                  next-module))]
            [(ErrTcEnv message) (ErrLowerDecls (lower-diagnostic message))])]
        [(AstDeclTest _ _ _)
          (lower-decls-in-module
            ctx
            top-env
            local-top-env
            rest
            globals
            functions
            externs
            spans
            names
            name-cache
            mode
            module)]
        [(AstDeclDefEnum name variants)
          (lower-decls-in-module
            ctx
            top-env
            local-top-env
            rest
            (lower-nullary-variant-globals
              (lower-current-decl-logical-name names module name)
              variants
              0
              globals)
            functions
            externs
            spans
            names
            name-cache
            mode
            module)]
        [(AstDeclDefStruct _ _ _ _)
          (lower-decls-in-module
            ctx
            top-env
            local-top-env
            rest
            globals
            functions
            externs
            spans
            names
            name-cache
            mode
            module)]
        [(AstDeclComptimeDecl _)
          (lower-decls-in-module
            ctx
            top-env
            local-top-env
            rest
            globals
            functions
            externs
            spans
            names
            name-cache
            mode
            module)])]))

(define (lower-compiler-program-checked-with-names-mode
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [program : AstProgram]
  [names : LowerNameEnv]
  [mode : CompilerLowerMode]) : ResultCompilerLower
  (match program
    [(AstProgram decls)
      (match (lower-decls
        ctx
        top-env
        decls
        IrGlobalNil
        IrFunctionNil
        IrExternNil
        (compiler-source-spans-empty)
        names
        mode)
        [(OkLowerDecls globals functions externs spans)
          (OkCompilerLower (IrProgram globals functions externs) spans)]
        [(ErrLowerDecls message) (ErrCompilerLower message)])]))

(define (lower-compiler-program-checked-with-names
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [program : AstProgram]
  [names : LowerNameEnv]) : ResultCompilerLower
  (lower-compiler-program-checked-with-names-mode
    ctx
    top-env
    program
    names
    (CompilerLowerScalar)))

(define (lower-compiler-program-checked
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [program : AstProgram]) : ResultCompilerLower
  (lower-compiler-program-checked-with-names ctx top-env program LowerNameNil))

;; Internal `expanded` workers assume macro expansion has already run; the
;; public `-mode` wrappers below own the expand -> specialize -> typecheck
;; boundary so every lowering path (scalar and SPMD) expands exactly once.
(define (lower-compiler-expanded-program-unlocated-mode
  [program : AstProgram]
  [mode : CompilerLowerMode]) : ResultCompilerLower
  (match (compiler-specialize-program program)
    [(OkSpecProgram specialized)
      (match (typecheck-compiler-specialized-program-with-paths
        specialized
        AstDeclPathNil)
        [(OkCompilerTypecheck _)
          (match (build-compiler-symbols specialized)
            [(OkCompilerSymbols symbols)
              (match (build-compiler-registries specialized)
                [(OkCompilerRegistries registries)
                  (let
                    [ctx : TcContext
                      (TcContext specialized symbols registries "")]
                    (match (tc-build-top-env ctx specialized)
                      [(OkTcEnv top-env)
                        (let
                          [alias-names : LowerNameEnv
                            (match specialized
                              [(AstProgram decls)
                                (lower-name-env-with-import-aliases
                                  decls
                                  AstDeclPathNil
                                  "<source>"
                                  LowerNameNil
                                  false)])]
                          (lower-compiler-program-checked-with-names-mode
                            ctx
                            top-env
                            specialized
                            alias-names
                            mode))]
                      [(ErrTcEnv message)
                        (ErrCompilerLower (lower-diagnostic message))]))]
                [(ErrCompilerRegistries message)
                  (ErrCompilerLower (lower-diagnostic message))])]
            [(ErrCompilerSymbols message)
              (ErrCompilerLower (lower-diagnostic message))])]
        [(ErrCompilerTypecheck diag) (ErrCompilerLower diag)])]
    [(ErrSpecProgram diag) (ErrCompilerLower diag)]))

(define (lower-compiler-program-unlocated-mode
  [program : AstProgram]
  [mode : CompilerLowerMode]) : ResultCompilerLower
  (match (macro-expand-program program)
    [(OkMacroExpand expanded)
      (lower-compiler-expanded-program-unlocated-mode expanded mode)]
    [(ErrMacroExpand diag) (ErrCompilerLower diag)]))

(define (lower-compiler-program-unlocated [program : AstProgram]) : ResultCompilerLower
  (lower-compiler-program-unlocated-mode program (CompilerLowerScalar)))

(define (lower-compiler-program-with-path-mode
  [path : String]
  [program : AstProgram]
  [mode : CompilerLowerMode]) : ResultCompilerLower
  (match (lower-compiler-program-unlocated-mode program mode)
    [(OkCompilerLower ir spans) (OkCompilerLower ir spans)]
    [(ErrCompilerLower diag)
      (ErrCompilerLower (lower-diagnostic-with-path diag path))]))

(define (lower-compiler-program-with-path
  [path : String]
  [program : AstProgram]) : ResultCompilerLower
  (lower-compiler-program-with-path-mode path program (CompilerLowerScalar)))

(define (lower-compiler-expanded-program-with-decl-paths-mode
  [entry-path : String]
  [program : AstProgram]
  [paths : AstDeclPathList]
  [mode : CompilerLowerMode]) : ResultCompilerLower
  (let
    [needs-specialization : bool (compiler-specialize-needed? program)]
    [specialized-paths : AstDeclPathList
      (if needs-specialization
        AstDeclPathNil
        paths)]
    [names : LowerNameEnv
      (match program
        [(AstProgram decls)
          (lower-name-env-from-decls decls paths entry-path LowerNameNil)])]
    (match (compiler-specialize-program program)
      [(OkSpecProgram specialized)
        (match (if needs-specialization
          (LowerPrunedProgram specialized specialized-paths)
          (lower-prune-unreachable-functions
            entry-path
            specialized
            specialized-paths
            names))
          [(LowerPrunedProgram checked-program checked-paths)
            (match (typecheck-compiler-specialized-program-with-paths
              checked-program
              checked-paths)
              [(OkCompilerTypecheck _)
                (match (build-compiler-symbols checked-program)
                  [(OkCompilerSymbols symbols)
                    (match (build-compiler-registries checked-program)
                      [(OkCompilerRegistries registries)
                        (let
                          [ctx : TcContext
                            (TcContext checked-program symbols registries "")]
                          (match (tc-build-top-env ctx checked-program)
                            [(OkTcEnv top-env)
                              (match (lower-compiler-program-checked-with-names-mode
                                ctx
                                top-env
                                checked-program
                                names
                                mode)
                                [(OkCompilerLower ir spans)
                                  (OkCompilerLower ir spans)]
                                [(ErrCompilerLower diag)
                                  (ErrCompilerLower
                                    (lower-diagnostic-with-path diag entry-path))])]
                            [(ErrTcEnv message)
                              (ErrCompilerLower
                                (lower-diagnostic-with-path
                                  (lower-diagnostic message)
                                  entry-path))]))]
                      [(ErrCompilerRegistries message)
                        (ErrCompilerLower
                          (lower-diagnostic-with-path
                            (lower-diagnostic message)
                            entry-path))])]
                  [(ErrCompilerSymbols message)
                    (ErrCompilerLower
                      (lower-diagnostic-with-path
                        (lower-diagnostic message)
                        entry-path))])]
              [(ErrCompilerTypecheck diag) (ErrCompilerLower diag)])])]
      [(ErrSpecProgram diag)
        (ErrCompilerLower (lower-diagnostic-with-path diag entry-path))])))

(define (lower-compiler-program-with-decl-paths-mode
  [entry-path : String]
  [program : AstProgram]
  [paths : AstDeclPathList]
  [mode : CompilerLowerMode]) : ResultCompilerLower
  (match (macro-expand-program program)
    [(OkMacroExpand expanded)
      (lower-compiler-expanded-program-with-decl-paths-mode
        entry-path
        (clone-augment-program expanded)
        paths
        mode)]
    [(ErrMacroExpand diag)
      (ErrCompilerLower (lower-diagnostic-with-path diag entry-path))]))

(define (lower-compiler-program-with-decl-paths
  [entry-path : String]
  [program : AstProgram]
  [paths : AstDeclPathList]) : ResultCompilerLower
  (lower-compiler-program-with-decl-paths-mode
    entry-path
    program
    paths
    (CompilerLowerScalar)))

(define (lower-compiler-program [program : AstProgram]) : ResultCompilerLower
  (lower-compiler-program-with-path "<source>" program))

(define (lower-compiler-source [src : String]) : ResultCompilerLower
  (lower-compiler-source-with-path "<source>" src))

(define (lower-compiler-source-with-mode
  [src : String]
  [mode : CompilerLowerMode]) : ResultCompilerLower
  (lower-compiler-source-with-path-mode "<source>" src mode))

(define (lower-compiler-source-with-path-mode
  [path : String]
  [src : String]
  [mode : CompilerLowerMode]) : ResultCompilerLower
  (match (parse-ast-source src)
    [(OkAstProgram program)
      (lower-compiler-program-with-path-mode path program mode)]
    [(ErrAstProgram message)
      (ErrCompilerLower
        (lower-diagnostic-with-path (lower-diagnostic message) path))]))

(define (lower-compiler-source-with-path [path : String] [src : String]) : ResultCompilerLower
  (lower-compiler-source-with-path-mode path src (CompilerLowerScalar)))

(define (compiler-lower-smoke-source) : String
  "(extern print-i64 : (-> i64 unit))
(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x 1))
(define (main [flag : bool]) : i64
  (let
    [x : i64 (inc answer)]
    (begin
      (set! x (+ x 1))
      (while (< x 45)
        (set! x (+ x 1)))
      (if flag x 0))))")

(define (compiler-lower-export-source) : String
  "(export (value answer))
(define answer : i64 42)
(define (main) : i64 answer)")

(define (compiler-lower-macro-expand-source) : String
  "(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(define (main) : i64 (if (and2 true true) 1 0))")

(define (compiler-lower-macro-arity-source) : String
  "(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(define (main) : i64 (if (and2 true) 1 0))")

;; A fixed-array literal `(array ...)`: it type-checks to `(Array i64 N)` and now
;; lowers to inline storage with each element stored at its offset, returning the
;; storage pointer (the same representation `array-ref`/`array-set!` index off).
(define (compiler-lower-array-literal-source) : String
  "(define (main) : (Array i64 3)
  (array 1 2 3))")

(define (compiler-lower-box-source) : String
  "(define (main) : i64 (box-get (box 7)))")

(define (compiler-lower-box-get-source) : String
  "(define (main [b : (Box i64)]) : i64 (box-get b))")

(define (compiler-lower-reference-source) : String
  "(define (take [r : (& n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (take (& n)))")

(define (compiler-lower-reference-return-source) : String
  "(define (ref-return [n : i64]) : (& n i64) (& n))
(define (ref-id [r : (& n i64)]) : (& n i64) r)
(define (ref-tuple [n : i64]) : (Tuple (& n i64) i64)
  (tuple (& n) 7))
(define (ref-array [n : i64]) : (Array (& n i64) 1)
  (array (& n)))
(define (main [n : i64]) : i64
  (begin
    (ref-id (ref-return n))
    (ref-tuple n)
    (ref-array n)
    42))")

(define (compiler-lower-reference-place-source) : String
  "(defstruct Pair (left i64) (right i64))
(define (borrow-pair [p : Pair]) : (& p i64)
  (& (struct-get p left)))
(define (borrow-tuple [t : (Tuple i64 bool)]) : (& t i64)
  (& (tuple-ref t 0)))
(define (borrow-array [items : (Array i64 2)]) : (& items i64)
  (& (array-ref items 0)))
(define (main) : i64
  (let
    [p : Pair (Pair 40 2)]
    [t : (Tuple i64 bool) (tuple 41 true)]
    [items : (Array i64 2) (array 42 7)]
    (begin
      (borrow-pair p)
      (borrow-tuple t)
      (borrow-array items)
      42)))")

(define (compiler-lower-function-value-source) : String
  "(define (inc [x : i64]) : i64 (+ x 1))
(define (apply1 [f : (-> i64 i64)] [x : i64]) : i64
  (f x))
(define (shadow-inc [inc : (-> i64 i64)] [x : i64]) : i64
  (inc x))
(define (main) : i64
  (+ (apply1 inc 41) (shadow-inc inc 1)))")

(define (compiler-lower-noncapturing-lambda-value-source) : String
  "(define (get-fn) : (-> i64 i64)
  (lambda ([x : i64]) : i64 (+ x 1)))")

(define (compiler-lower-immediate-lambda-call-source) : String
  "(define (main) : i64
  ((lambda ([x : i64]) : i64 (+ x 1)) 41))")

(define (compiler-lower-unit-lambda-call-source) : String
  "(extern print-i64 : (-> i64 unit))
(define (main) : unit
  ((lambda () : unit (print-i64 1))))")

(define (compiler-lower-capturing-lambda-scalar-source) : String
  "(define (main) : i64
  (let
    [n : i64 10]
    ((lambda ([x : i64]) : i64 (+ x n)) 32)))")

(define (compiler-lower-capturing-lambda-function-value-source) : String
  "(define (main) : i64
  (let
    [inc : (-> i64 i64) (lambda ([x : i64]) : i64 (+ x 1))]
    [n : i64 9]
    ((lambda ([x : i64]) : i64 (inc (+ x n))) 32)))")

(define (compiler-lower-capturing-lambda-fat-handle-source) : String
  "(define (main [n : i64]) : i64
  (let
    [s : String \"hello\"]
    [a : (Array i64) (make-array i64 2)]
    (begin
      (array-set! a 0 n)
      ((lambda () : i64 (+ (string-length s) (array-ref a 0)))))))")

(define (compiler-lower-capturing-lambda-aggregate-source) : String
  "(defstruct Point (x i64) (y i64))
(defenum Shape (Rect i64 i64) (None))
(define (main) : i64
  (let
    [t : (Tuple i64 i64) (tuple 5 99)]
    [p : Point (Point 7 1)]
    [a : (Array i64 2) (array 3 10)]
    [s : Shape (Rect 4 5)]
    ((lambda
       ()
       :
       i64
       (+
         (tuple-ref t 0)
         (+
           (struct-get p x)
           (+
             (array-ref a 1)
             (match s
               [(Rect w h) (* w h)]
               [(None) 0]))))))))")

(define (compiler-lower-capturing-lambda-shadow-source) : String
  "(define (main) : i64
  (let
    [n : i64 10]
    ((lambda
       ([x : i64])
       :
       i64
       (+
         n
         (let
           [n : i64 100]
           (+ x n))))
     32)))")

;; `(comptime expr)` folds to a literal via the scalar CTFE evaluator (#719).
;; These fixtures exercise arithmetic, `if`, and `let` folds, plus the
;; runtime-variable and deferred-f64 (#735) rejection paths.
(define (compiler-lower-comptime-arith-source) : String
  "(define (main) : i64 (comptime (+ 1 2)))")

(define (compiler-lower-comptime-if-source) : String
  "(define (main) : i64 (comptime (if (< 1 2) (* 6 7) 0)))")

(define (compiler-lower-comptime-let-source) : String
  "(define (main) : i64 (comptime (let [x 40] (+ x 2))))")

(define (compiler-lower-comptime-runtime-var-source) : String
  "(define (main [x : i64]) : i64 (comptime x))")

(define (compiler-lower-comptime-f64-source) : String
  "(define (main) : f64 (comptime 1.5))")

(define (compiler-lower-error-ok? [src : String] [want : String]) : bool
  (match (lower-compiler-source src)
    [(ErrCompilerLower diag)
      (string-eq (compiler-diagnostic-message diag) want)]
    [(OkCompilerLower _ _) false]))

(define (compiler-lower-inline-error-ok? [src : String] [want : String]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerInlineAggregates))
    [(ErrCompilerLower diag)
      (string-eq (compiler-diagnostic-message diag) want)]
    [(OkCompilerLower _ _) false]))

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

;; Fixed-array access lowers against inline array storage rather than the
;; dynamic-array fat `{ptr, len}` layout.
(define (compiler-lower-fixed-array-access-source) : String
  "(define (get [a : (Array i64 3)] [i : i64]) : i64 (array-ref a i))
(define (put [a : (Array i64 3)] [i : i64] [v : i64]) : unit (array-set! a i v))
(define (main) : i64 0)")

;; `array-push!` lowers to checked arena reallocation, a runtime-length copy,
;; a tail store, and in-place fat `{ptr, len}` updates.
(define (compiler-lower-array-push-source) : String
  "(define (grow [a : (Array i64)] [v : i64]) : unit (array-push! a v))
(define (main) : i64 0)")

;; Fixed arrays have no runtime capacity field and remain unsupported for push.
(define (compiler-lower-fixed-array-push-source) : String
  "(define (grow [a : (Array i64 3)] [v : i64]) : unit (array-push! a v))
(define (main) : i64 0)")

;; `make-array` lowers to checked byte-count math, a `tl_alloc` element buffer,
;; and a dynamic-array fat value. The fixture also immediately uses
;; `array-set!`, `array-ref`, and `array-length` so the generated IR exercises
;; the full dynamic-array primitive set.
(define (compiler-lower-make-array-source) : String
  "(define (main [n : i64]) : i64
  (let
    [a : (Array i64) (make-array i64 n)]
    (begin
      (array-set! a 0 40)
      (array-set! a 1 2)
      (+ (array-length a) (+ (array-ref a 0) (array-ref a 1))))))")

;; `string-length`/`length` on a String lower to the same fat `{ptr, len}`
;; length load as `array-length` (#527): both lay out the i64 length at offset 8.
(define (compiler-lower-string-length-source) : String
  "(define (str-len [s : String]) : i64 (string-length s))
(define (str-len-alias [s : String]) : i64 (length s))
(define (str-len-borrow [s : String]) : i64 (string-length (& s)))
(define (str-len-alias-borrow [s : String]) : i64 (length (& s)))
(define (main) : i64 0)")

(define (compiler-lower-string-runtime-source) : String
  "(define (main) : i64
  (let
    [left : String \"foo\"]
    [right : String \"bar\"]
    [joined : String (string-append (& left) (& right))]
    [mid : String (substring (& joined) 2 3)]
    [bang : String \"!\"]
    [extended : String (string-concat (& mid) (& bang))]
    [spaced : String \" x\"]
    [digits : String \"7\"]
    (begin
      (print-string (& joined))
      (print-str (& extended))
      (print-char #A')
      (print-float 1.5)
      (+ (string-length (& joined))
        (+ (string-length (& extended))
          (+ (string->int (& digits))
            (+ (if (string-eq (& joined) (& extended)) 1 0)
              (cast (char-at (& spaced) 0) : i64))))))))")

(define (compiler-lower-borrowed-str-param-source) : String
  "(define (borrowed-score [path : (& path str)]) : i64
  (begin
    (print-string path)
    (+ (string-length path) (file-exists-status path))))
(define (main [path : String]) : i64
  (borrowed-score (& path)))")

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

(define (compiler-lower-file-handle-status-source) : String
  "(define (main) : i64
  (let
    [path : String \"input.txt\"]
    [suffix : String \"x\"]
    [chunk : String \"chunk\"]
    [handle : i64 (file-open-status (& path) 0)]
    (+ handle
      (+ (append-file-status (& path) (& suffix))
        (+ (file-read-chunk-status handle 4)
          (+ (file-write-status handle (& chunk))
            (+ (file-flush-status handle)
              (+ (string-length (file-read-chunk-bytes handle))
                (+ (if (file-read-chunk-eof? handle) 1 0)
                   (file-close-status handle))))))))))")

(define (compiler-lower-fs-status-source) : String
  "(define (main) : i64
  (+ (fs-current-dir-status)
    (+ (string-length (fs-current-dir))
      (+ (fs-process-id)
        (+ (fs-mkdir-status \"target/typelisp-fs\")
          (+ (fs-remove-file-status \"target/typelisp-fs/artifact.o\")
            (+ (fs-remove-dir-status \"target/typelisp-fs\")
              (fs-rename-status
                \"target/typelisp-fs/from name\"
                \"target/typelisp-fs/to name\"))))))))")

(define (compiler-lower-raw-pointer-ops-source) : String
  "(extern raw-make : (-> (MutPtr i64)))
(define (main [n : u64]) : u64
  (let
    [p : (MutPtr i64) (raw-make)]
    (unsafe
      (ptr-write! p 41)
      (ptr-read p)
      (ptr->int (ptr-offset (ptr-cast (int->ptr n : (MutPtr i64)) : (Ptr i64)) 2)))))")

(define (compiler-lower-raw-pointer-direct-call-source) : String
  "(extern raw-make : (-> (MutPtr i64)))
(define (main) : unit
  (unsafe
    (ptr-write! (raw-make) 41)))")

(define (compiler-lower-raw-pointer-call-value-source) : String
  "(extern raw-make : (-> (MutPtr i64)))
(extern raw-value : (-> i64))
(define (main) : unit
  (unsafe
    (ptr-write! (raw-make) (raw-value))))")

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

;; Tuple construction + ref lowering (#1583): `(tuple true 42)` reserves
;; struct-shaped aggregate storage and stores each element at its field offset;
;; `(tuple-ref t 1)` gep+loads the indexed element. The whole computation lives
;; in `main` so it is not pruned as unreachable.
(define (compiler-lower-tuple-source) : String
  "(define (main) : i64
  (let
    [t : (Tuple bool i64) (tuple true 42)]
    (tuple-ref t 1)))")

(define (compiler-lower-clone-source) : String
  "(defstruct Holder
  (name String)
  (fixed (Array String 2))
  (items (Array String))
  (pair (Tuple String String)))
(defenum StringList
  (SNil)
  (SCons String StringList))
(define (clone-tuple [items : (Array String)]) : (Tuple String (Array String))
  (clone (tuple \"tuple\" items)))
(define (clone-fixed) : (Array String 2)
  (clone (array \"left\" \"right\")))
(define (clone-dyn [items : (Array String)]) : (Array String)
  (clone items))
(define (clone-holder [items : (Array String)]) : Holder
  (clone (Holder \"holder\" (array \"x\" \"y\") items (tuple \"p\" \"q\"))))
(define (clone-list [list : StringList]) : StringList
  (clone list))
(define (main [n : i64] [list : StringList]) : i64
  (let
    [items1 : (Array String) (make-array String n)]
    [items2 : (Array String) (make-array String n)]
    [items3 : (Array String) (make-array String n)]
    (begin
      (clone-tuple items1)
      (clone-dyn items2)
      (clone-holder items3)
      (clone-fixed)
      (clone-list list)
      0)))")

(define (compiler-lower-clone-unsupported-source) : String
  "(define (inc [x : i64]) : i64 (+ x 1))
(define (main) : (-> i64 i64)
  (clone inc))")

;; `main` must lower with both element stores (bool + i64 each written into the
;; aggregate) and a load for the `tuple-ref`.
(define (compiler-lower-tuple-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tuple-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (>= (lower-test-function-store-ptr-count functions "main") 2)
            (>= (lower-test-function-load-count functions "main") 1))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-inline-struct-source) : String
  "(defstruct Packet (tag i64) (small u8) (count i64))
(define (main) : i64
  (let
    [p : Packet (Packet 7 (cast 2 : u8) 40)]
    (+
      (struct-get p tag)
      (+
        (cast (struct-get p small) : i64)
        (struct-get p count)))))")

(define (compiler-lower-inline-enum-source) : String
  "(defenum Choice (Empty) (Wide u8 i64))
(define (main) : i64
  (let
    [c : Choice (Wide (cast 1 : u8) 41)]
    (match c
      [Empty 0]
      [(Wide b n) (+ (cast b : i64) n)])))")

(define (compiler-lower-inline-boxed-recursive-source) : String
  "(defenum ListI64 (Nil) (Cons i64 (Box ListI64)))
(define (main) : i64
  (let
    [tail : (Box ListI64) (box Nil)]
    (let
      [list : ListI64 (Cons 41 tail)]
      (match list
        [Nil 0]
        [(Cons head _) (+ head 1)]))))")

(define (compiler-lower-inline-recursive-error-source) : String
  "(defenum BadList (BadNil) (BadCons i64 BadList))
(define (main) : i64
  (let
    [x : BadList (BadCons 1 BadNil)]
    0))")

(define (compiler-lower-inline-struct-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-inline-struct-source)
    (CompilerLowerInlineAggregates))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-function-call-count functions "main" "tl_alloc")
                0)
                unit
                (set! ok false))
              (if (>= (lower-test-function-alloc-count functions "main") 3)
                unit
                (set! ok false))
              (if (= (lower-test-function-addr-of-count functions "main") 1)
                unit
                (set! ok false))
              (if (>= (lower-test-function-store-ptr-count functions "main") 3)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-gep-offset-count functions "main" 16)
                0)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-inline-enum-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-inline-enum-source)
    (CompilerLowerInlineAggregates))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-function-call-count functions "main" "tl_alloc")
                0)
                unit
                (set! ok false))
              (if (>= (lower-test-function-alloc-count functions "main") 3)
                unit
                (set! ok false))
              (if (= (lower-test-function-addr-of-count functions "main") 1)
                unit
                (set! ok false))
              (if (>= (lower-test-function-store-ptr-count functions "main") 3)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-gep-offset-count functions "main" 16)
                0)
                unit
                (set! ok false))
              (if (> (lower-test-function-branch-count functions "main") 0)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-inline-boxed-recursive-shape-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-inline-boxed-recursive-source)
    (CompilerLowerInlineAggregates))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-function-call-count functions "main" "tl_alloc")
                1)
                unit
                (set! ok false))
              (if (>= (lower-test-function-alloc-count functions "main") 6)
                unit
                (set! ok false))
              (if (>= (lower-test-function-addr-of-count functions "main") 2)
                unit
                (set! ok false))
              (if (>= (lower-test-function-store-ptr-count functions "main") 4)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-inline-aggregate-tests-ok?) : bool
  (and
    (compiler-lower-inline-struct-shape-ok?)
    (and
      (compiler-lower-inline-enum-shape-ok?)
      (and
        (compiler-lower-inline-boxed-recursive-shape-ok?)
        (compiler-lower-inline-error-ok?
          (compiler-lower-inline-recursive-error-source)
          "typecheck: inline aggregate layout cycle BadList -> BadList; insert (Box BadList) at the recursive edge")))))

(define (compiler-lower-comptime-decl-source) : String
  "(comptime-decl (defstruct Point (x i64) (y i64)))
(comptime-decl (defenum Shape (Nothing) (Circle i64) (Pair Point)))
(define (make-point [x : i64] [y : i64]) : Point
  (Point x y))
(define (get-y [p : Point]) : i64
  (struct-get p y))
(define (make-pair [x : i64]) : Shape
  (Pair (Point x (+ x 1))))
(define (main) : i64
  (get-y (make-point 20 22)))")

(define (compiler-lower-repr-c-source) : String
  "(defstruct Inner
  (:repr c)
  (a u8)
  (b i32))
(defstruct Outer
  (:repr c)
  (tag u8)
  (inner Inner)
  (tail u16))
(define (main) : i64
  (let
    [inner : Inner (Inner (cast 1 : u8) (cast 41 : i32))]
    [outer : Outer (Outer (cast 2 : u8) inner (cast 3 : u16))]
    (+
      (cast (struct-get (struct-get outer inner) b) : i64)
      (cast (struct-get outer tail) : i64))))")

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

(define (compiler-lower-result-try-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (read [flag : bool] [n : i64]) : ResultI64
  (if flag (OkI64 n) (ErrI64 \"read failed\")))
(define (sum [a : bool] [b : bool]) : ResultI64
  (let ([x : i64 (try (read a 40))]
        [y : i64 0])
    (begin
      (set! y (try (read b 2)))
      (OkI64 (+ x y)))))
(define (chain [flag : bool]) : ResultI64
  (OkI64 (try (sum flag true))))
(define (main [flag : bool]) : ResultI64
  (chain flag))")

(define (compiler-lower-return-source) : String
  "(define (main [flag : bool]) : i64
  (begin
    (if flag (return 7) unit)
    42))")

(define (compiler-lower-return-with-arena-source) : String
  "(define (main [flag : bool]) : i64
  (with-arena r
    (begin
      (if flag (return 7) unit)
      42)))")

(define (compiler-lower-resource-with-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (open-a [ok : bool]) : ResultI64
  (if ok (OkI64 10) (ErrI64 \"open a\")))
(define (open-b [ok : bool]) : ResultI64
  (if ok (OkI64 32) (ErrI64 \"open b\")))
(define (use-a [ok : bool] [h : i64]) : ResultI64
  (if ok (OkI64 h) (ErrI64 \"use a\")))
(define (close-a [h : i64]) : unit unit)
(define (close-b [h : i64]) : unit unit)
(define (main [a-ok : bool] [b-ok : bool] [use-ok : bool]) : ResultI64
  (with ([a (try (open-a a-ok)) close-a]
         [b (try (open-b b-ok)) close-b])
    (OkI64 (+ (try (use-a use-ok a)) b))))")

(define (compiler-lower-resource-with-nested-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (close-a [h : i64]) : unit unit)
(define (close-b [h : i64]) : unit unit)
(define (main) : ResultI64
  (with ([a 10 close-a])
    (with ([b 32 close-b])
      (OkI64 (+ a b)))))")

(define (compiler-lower-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower _ _) true]
    [(ErrCompilerLower _) false]))

;; Provenance side-table smoke (#605): the smoke source defines two functions
;;
;; (`inc` on line 3 and `main` on line 4 with its body on line 5). After lowering
;;
;; the function spans table must hold exactly those two entries, keyed by name,
;;
;; recording each function body's source start line. The instruction/value span
;;
;; side table should also receive entries from expression-backed emits (#744).
(define (compiler-lower-span-start-line-ok?
  [spans : CompilerSourceSpans]
  [name : String]
  [want-line : i64]) : bool
  (match (compiler-source-spans-lookup spans name)
    [(CompilerSomeSourceSpan span) (= (struct-get span start-line) want-line)]
    [(CompilerNoSourceSpan) false]))

(define (compiler-lower-spans-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower _ spans)
      (and
        (= (compiler-source-spans-count spans) 2)
        (and
          (compiler-lower-span-start-line-ok? spans "inc" 3)
          (compiler-lower-span-start-line-ok? spans "main" 5)))]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-ok-summary? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program _)
      (let
        [summary : CompilerIrSummary (compiler-ir-program-summary program)]
        [ok : bool true]
        (begin
          (if (= (compiler-ir-summary-globals summary) 1)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-functions summary) 2)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-externs summary) 1)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-blocks summary) 8)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-instructions summary) 29)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-vars summary) 21)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-empty-blocks summary) 0)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-max-instructions-function summary) 25)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-max-instructions-block summary) 8)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-call-arg-entries summary) 1)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-phi-input-entries summary) 2)
            unit
            (set! ok false))
          ok))]
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

(define (lower-test-instr-branch-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrBranch _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-bounds-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrBoundsCheck _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-return-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrReturn _) 1]
    [_ 0]))

(define (lower-test-instr-call-count [instr : CompilerIrInstr] [name : String]) : i64
  (match instr
    [(IrInstrCall _ call-name _ _)
      (if (string-eq call-name name)
        1
        0)]
    [_ 0]))

(define (lower-test-instr-indirect-call-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrCallIndirect _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-indirect-unit-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrCallIndirect _ _ _ ty)
      (match ty
        [(AstTyUnit) 1]
        [_ 0])]
    [_ 0]))

(define (lower-test-value-function-count
  [value : CompilerIrValue]
  [name : String]) : i64
  (match value
    [(IrValueFunction found)
      (if (string-eq found name)
        1
        0)]
    [_ 0]))

(define (lower-test-value-list-function-count
  [values : CompilerIrValueList]
  [name : String]) : i64
  (match values
    [(IrValueNil) 0]
    [(IrValueCons value rest)
      (+
        (lower-test-value-function-count value name)
        (lower-test-value-list-function-count rest name))]))

(define (lower-test-instr-return-function-count
  [instr : CompilerIrInstr]
  [function-name : String]) : i64
  (match instr
    [(IrInstrReturn maybe-value)
      (match maybe-value
        [(IrSomeValue value)
          (lower-test-value-function-count value function-name)]
        [(IrNoValue) 0])]
    [_ 0]))

(define (lower-test-instr-indirect-callee-function-count
  [instr : CompilerIrInstr]
  [function-name : String]) : i64
  (match instr
    [(IrInstrCallIndirect _ func _ _)
      (lower-test-value-function-count func function-name)]
    [_ 0]))

(define (lower-test-instr-call-arg-function-count
  [instr : CompilerIrInstr]
  [call-name : String]
  [function-name : String]) : i64
  (match instr
    [(IrInstrCall _ found args _)
      (if (string-eq found call-name)
        (lower-test-value-list-function-count args function-name)
        0)]
    [_ 0]))

(define (lower-test-instr-tail-call-count
  [instr : CompilerIrInstr]
  [name : String]) : i64
  (match instr
    [(IrInstrTailCall call-name _ _)
      (if (string-eq call-name name)
        1
        0)]
    [_ 0]))

(define (lower-test-instr-store-ptr-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrStorePtr _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-alloc-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrAlloc _ _) 1]
    [_ 0]))

(define (lower-test-instr-addr-of-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrAddrOf _ _) 1]
    [_ 0]))

(define (lower-test-instr-vector-load-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrVectorLoad _ _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-vector-binop-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrVectorBinOp _ _ _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-vector-reduce-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrVectorReduce _ _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-vector-store-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrVectorStore _ _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-predicated-load-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrPredicatedLoad _ _ _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-predicated-store-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrPredicatedStore _ _ _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-tail-mask-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrTailMask _ _ _ _) 1]
    [_ 0]))

(define (lower-test-vector-shape?
  [actual-lanes : i64]
  [actual-ty : AstType]
  [lanes : i64]
  [elem-ty : AstType]) : bool
  (and (= actual-lanes lanes) (tc-type-eq actual-ty elem-ty)))

(define (lower-test-instr-vector-shape-count
  [instr : CompilerIrInstr]
  [lanes : i64]
  [elem-ty : AstType]) : i64
  (match instr
    [(IrInstrVectorLoad _ _ _ actual-lanes actual-ty)
      (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
        1
        0)]
    [(IrInstrVectorBinOp _ _ _ _ actual-lanes actual-ty)
      (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
        1
        0)]
    [(IrInstrVectorReduce _ _ _ actual-lanes actual-ty)
      (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
        1
        0)]
    [(IrInstrVectorStore _ _ _ actual-lanes actual-ty)
      (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
        1
        0)]
    [(IrInstrPredicatedLoad _ _ _ _ actual-lanes actual-ty)
      (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
        1
        0)]
    [(IrInstrPredicatedStore _ _ _ _ actual-lanes actual-ty)
      (if (lower-test-vector-shape? actual-lanes actual-ty lanes elem-ty)
        1
        0)]
    [_ 0]))

(define (lower-test-instr-u64-mov-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrMov _ _ ty)
      (match ty
        [(AstTyU64) 1]
        [_ 0])]
    [_ 0]))

(define (lower-test-binop-same?
  [actual : CompilerIrBinOp]
  [want : CompilerIrBinOp]) : bool
  (match actual
    [(IrBinAdd)
      (match want
        [(IrBinAdd) true]
        [_ false])]
    [(IrBinSub)
      (match want
        [(IrBinSub) true]
        [_ false])]
    [(IrBinMul)
      (match want
        [(IrBinMul) true]
        [_ false])]
    [(IrBinDiv)
      (match want
        [(IrBinDiv) true]
        [_ false])]
    [(IrBinMod)
      (match want
        [(IrBinMod) true]
        [_ false])]
    [(IrBinEq)
      (match want
        [(IrBinEq) true]
        [_ false])]
    [(IrBinNe)
      (match want
        [(IrBinNe) true]
        [_ false])]
    [(IrBinLt)
      (match want
        [(IrBinLt) true]
        [_ false])]
    [(IrBinLe)
      (match want
        [(IrBinLe) true]
        [_ false])]
    [(IrBinGt)
      (match want
        [(IrBinGt) true]
        [_ false])]
    [(IrBinGe)
      (match want
        [(IrBinGe) true]
        [_ false])]
    [(IrBinAnd)
      (match want
        [(IrBinAnd) true]
        [_ false])]
    [(IrBinOr)
      (match want
        [(IrBinOr) true]
        [_ false])]
    [(IrBinBitAnd)
      (match want
        [(IrBinBitAnd) true]
        [_ false])]
    [(IrBinBitOr)
      (match want
        [(IrBinBitOr) true]
        [_ false])]
    [(IrBinBitXor)
      (match want
        [(IrBinBitXor) true]
        [_ false])]
    [(IrBinShl)
      (match want
        [(IrBinShl) true]
        [_ false])]
    [(IrBinShr)
      (match want
        [(IrBinShr) true]
        [_ false])]))

(define (lower-test-instr-binop-op-count
  [instr : CompilerIrInstr]
  [op : CompilerIrBinOp]) : i64
  (match instr
    [(IrInstrBinOp _ actual _ _ _)
      (if (lower-test-binop-same? actual op)
        1
        0)]
    [_ 0]))

(define (lower-test-instr-cast-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrCast _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-store-global-count
  [instr : CompilerIrInstr]
  [name : String]) : i64
  (match instr
    [(IrInstrStore store-name _ _)
      (if (string-eq store-name name)
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

(define (lower-test-instrs-branch-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-branch-count instr)
        (lower-test-instrs-branch-count rest))]))

(define (lower-test-instrs-bounds-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-bounds-count instr)
        (lower-test-instrs-bounds-count rest))]))

(define (lower-test-instrs-return-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-return-count instr)
        (lower-test-instrs-return-count rest))]))

(define (lower-test-instrs-call-count
  [instrs : CompilerIrInstrList]
  [name : String]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-call-count instr name)
        (lower-test-instrs-call-count rest name))]))

(define (lower-test-instrs-indirect-call-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-indirect-call-count instr)
        (lower-test-instrs-indirect-call-count rest))]))

(define (lower-test-instrs-indirect-unit-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-indirect-unit-count instr)
        (lower-test-instrs-indirect-unit-count rest))]))

(define (lower-test-instrs-return-function-count
  [instrs : CompilerIrInstrList]
  [function-name : String]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-return-function-count instr function-name)
        (lower-test-instrs-return-function-count rest function-name))]))

(define (lower-test-instrs-indirect-callee-function-count
  [instrs : CompilerIrInstrList]
  [function-name : String]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-indirect-callee-function-count instr function-name)
        (lower-test-instrs-indirect-callee-function-count rest function-name))]))

(define (lower-test-instrs-call-arg-function-count
  [instrs : CompilerIrInstrList]
  [call-name : String]
  [function-name : String]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-call-arg-function-count instr call-name function-name)
        (lower-test-instrs-call-arg-function-count rest call-name function-name))]))

(define (lower-test-instrs-tail-call-count
  [instrs : CompilerIrInstrList]
  [name : String]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-tail-call-count instr name)
        (lower-test-instrs-tail-call-count rest name))]))

(define (lower-test-instrs-store-ptr-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-store-ptr-count instr)
        (lower-test-instrs-store-ptr-count rest))]))

(define (lower-test-instrs-alloc-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-alloc-count instr)
        (lower-test-instrs-alloc-count rest))]))

(define (lower-test-instrs-addr-of-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-addr-of-count instr)
        (lower-test-instrs-addr-of-count rest))]))

(define (lower-test-instrs-vector-load-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-vector-load-count instr)
        (lower-test-instrs-vector-load-count rest))]))

(define (lower-test-instrs-vector-binop-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-vector-binop-count instr)
        (lower-test-instrs-vector-binop-count rest))]))

(define (lower-test-instrs-vector-reduce-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-vector-reduce-count instr)
        (lower-test-instrs-vector-reduce-count rest))]))

(define (lower-test-instrs-vector-store-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-vector-store-count instr)
        (lower-test-instrs-vector-store-count rest))]))

(define (lower-test-instrs-predicated-load-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-predicated-load-count instr)
        (lower-test-instrs-predicated-load-count rest))]))

(define (lower-test-instrs-predicated-store-count
  [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-predicated-store-count instr)
        (lower-test-instrs-predicated-store-count rest))]))

(define (lower-test-instrs-tail-mask-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-tail-mask-count instr)
        (lower-test-instrs-tail-mask-count rest))]))

(define (lower-test-instrs-vector-shape-count
  [instrs : CompilerIrInstrList]
  [lanes : i64]
  [elem-ty : AstType]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-vector-shape-count instr lanes elem-ty)
        (lower-test-instrs-vector-shape-count rest lanes elem-ty))]))

(define (lower-test-instrs-u64-mov-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-u64-mov-count instr)
        (lower-test-instrs-u64-mov-count rest))]))

(define (lower-test-instrs-binop-op-count
  [instrs : CompilerIrInstrList]
  [op : CompilerIrBinOp]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-binop-op-count instr op)
        (lower-test-instrs-binop-op-count rest op))]))

(define (lower-test-instrs-cast-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-cast-count instr)
        (lower-test-instrs-cast-count rest))]))

(define (lower-test-instrs-store-global-count
  [instrs : CompilerIrInstrList]
  [name : String]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-store-global-count instr name)
        (lower-test-instrs-store-global-count rest name))]))

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

(define (lower-test-blocks-branch-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-branch-count instrs)
            (lower-test-blocks-branch-count rest))])]))

(define (lower-test-blocks-bounds-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-bounds-count instrs)
            (lower-test-blocks-bounds-count rest))])]))

(define (lower-test-blocks-return-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-return-count instrs)
            (lower-test-blocks-return-count rest))])]))

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

(define (lower-test-blocks-indirect-call-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-indirect-call-count instrs)
            (lower-test-blocks-indirect-call-count rest))])]))

(define (lower-test-blocks-indirect-unit-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-indirect-unit-count instrs)
            (lower-test-blocks-indirect-unit-count rest))])]))

(define (lower-test-blocks-return-function-count
  [blocks : CompilerIrBlockList]
  [function-name : String]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-return-function-count instrs function-name)
            (lower-test-blocks-return-function-count rest function-name))])]))

(define (lower-test-blocks-indirect-callee-function-count
  [blocks : CompilerIrBlockList]
  [function-name : String]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-indirect-callee-function-count
              instrs
              function-name)
            (lower-test-blocks-indirect-callee-function-count
              rest
              function-name))])]))

(define (lower-test-blocks-call-arg-function-count
  [blocks : CompilerIrBlockList]
  [call-name : String]
  [function-name : String]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-call-arg-function-count
              instrs
              call-name
              function-name)
            (lower-test-blocks-call-arg-function-count
              rest
              call-name
              function-name))])]))

(define (lower-test-blocks-tail-call-count
  [blocks : CompilerIrBlockList]
  [name : String]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-tail-call-count instrs name)
            (lower-test-blocks-tail-call-count rest name))])]))

(define (lower-test-blocks-store-ptr-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-store-ptr-count instrs)
            (lower-test-blocks-store-ptr-count rest))])]))

(define (lower-test-blocks-alloc-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-alloc-count instrs)
            (lower-test-blocks-alloc-count rest))])]))

(define (lower-test-blocks-addr-of-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-addr-of-count instrs)
            (lower-test-blocks-addr-of-count rest))])]))

(define (lower-test-blocks-vector-load-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-vector-load-count instrs)
            (lower-test-blocks-vector-load-count rest))])]))

(define (lower-test-blocks-vector-binop-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-vector-binop-count instrs)
            (lower-test-blocks-vector-binop-count rest))])]))

(define (lower-test-blocks-vector-reduce-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-vector-reduce-count instrs)
            (lower-test-blocks-vector-reduce-count rest))])]))

(define (lower-test-blocks-vector-store-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-vector-store-count instrs)
            (lower-test-blocks-vector-store-count rest))])]))

(define (lower-test-blocks-predicated-load-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-predicated-load-count instrs)
            (lower-test-blocks-predicated-load-count rest))])]))

(define (lower-test-blocks-predicated-store-count
  [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-predicated-store-count instrs)
            (lower-test-blocks-predicated-store-count rest))])]))

(define (lower-test-blocks-tail-mask-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-tail-mask-count instrs)
            (lower-test-blocks-tail-mask-count rest))])]))

(define (lower-test-blocks-vector-shape-count
  [blocks : CompilerIrBlockList]
  [lanes : i64]
  [elem-ty : AstType]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-vector-shape-count instrs lanes elem-ty)
            (lower-test-blocks-vector-shape-count rest lanes elem-ty))])]))

(define (lower-test-blocks-u64-mov-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-u64-mov-count instrs)
            (lower-test-blocks-u64-mov-count rest))])]))

(define (lower-test-blocks-binop-op-count
  [blocks : CompilerIrBlockList]
  [op : CompilerIrBinOp]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-binop-op-count instrs op)
            (lower-test-blocks-binop-op-count rest op))])]))

(define (lower-test-blocks-cast-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-cast-count instrs)
            (lower-test-blocks-cast-count rest))])]))

(define (lower-test-blocks-store-global-count
  [blocks : CompilerIrBlockList]
  [name : String]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-store-global-count instrs name)
            (lower-test-blocks-store-global-count rest name))])]))

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

(define (lower-test-function-branch-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-branch-count blocks)
            (lower-test-function-branch-count rest name))])]))

(define (lower-test-function-bounds-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-bounds-count blocks)
            (lower-test-function-bounds-count rest name))])]))

(define (lower-test-function-return-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-return-count blocks)
            (lower-test-function-return-count rest name))])]))

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

(define (lower-test-function-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [call-name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-call-count blocks call-name)
            (lower-test-function-call-count rest name call-name))])]))

(define (lower-test-function-indirect-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-indirect-call-count blocks)
            (lower-test-function-indirect-call-count rest name))])]))

(define (lower-test-function-indirect-unit-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-indirect-unit-count blocks)
            (lower-test-function-indirect-unit-count rest name))])]))

(define (lower-test-function-return-function-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [function-name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-return-function-count blocks function-name)
            (lower-test-function-return-function-count rest name function-name))])]))

(define (lower-test-function-indirect-callee-function-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [function-name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-indirect-callee-function-count
              blocks
              function-name)
            (lower-test-function-indirect-callee-function-count
              rest
              name
              function-name))])]))

(define (lower-test-function-call-arg-function-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [call-name : String]
  [function-name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-call-arg-function-count
              blocks
              call-name
              function-name)
            (lower-test-function-call-arg-function-count
              rest
              name
              call-name
              function-name))])]))

(define (lower-test-function-tail-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [call-name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-tail-call-count blocks call-name)
            (lower-test-function-tail-call-count rest name call-name))])]))

(define (lower-test-function-store-ptr-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-store-ptr-count blocks)
            (lower-test-function-store-ptr-count rest name))])]))

(define (lower-test-function-alloc-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-alloc-count blocks)
            (lower-test-function-alloc-count rest name))])]))

(define (lower-test-function-addr-of-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-addr-of-count blocks)
            (lower-test-function-addr-of-count rest name))])]))

(define (lower-test-function-vector-load-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-vector-load-count blocks)
            (lower-test-function-vector-load-count rest name))])]))

(define (lower-test-function-vector-binop-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-vector-binop-count blocks)
            (lower-test-function-vector-binop-count rest name))])]))

(define (lower-test-function-vector-reduce-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-vector-reduce-count blocks)
            (lower-test-function-vector-reduce-count rest name))])]))

(define (lower-test-function-vector-store-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-vector-store-count blocks)
            (lower-test-function-vector-store-count rest name))])]))

(define (lower-test-function-predicated-load-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-predicated-load-count blocks)
            (lower-test-function-predicated-load-count rest name))])]))

(define (lower-test-function-predicated-store-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-predicated-store-count blocks)
            (lower-test-function-predicated-store-count rest name))])]))

(define (lower-test-function-tail-mask-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-tail-mask-count blocks)
            (lower-test-function-tail-mask-count rest name))])]))

(define (lower-test-function-vector-shape-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [lanes : i64]
  [elem-ty : AstType]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-vector-shape-count blocks lanes elem-ty)
            (lower-test-function-vector-shape-count rest name lanes elem-ty))])]))

(define (lower-test-function-u64-mov-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-u64-mov-count blocks)
            (lower-test-function-u64-mov-count rest name))])]))

(define (lower-test-function-binop-op-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [op : CompilerIrBinOp]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-binop-op-count blocks op)
            (lower-test-function-binop-op-count rest name op))])]))

(define (lower-test-function-cast-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-cast-count blocks)
            (lower-test-function-cast-count rest name))])]))

(define (lower-test-function-store-global-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [global-name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-store-global-count blocks global-name)
            (lower-test-function-store-global-count rest name global-name))])]))

(define (lower-test-global-list-has-name?
  [globals : CompilerIrGlobalList]
  [name : String]) : bool
  (match globals
    [(IrGlobalNil) false]
    [(IrGlobalCons global rest)
      (match global
        [(IrGlobal global-name _ _)
          (if (string-eq global-name name)
            true
            (lower-test-global-list-has-name? rest name))])]))

(define (compiler-lower-module-symbol-source) : String
  "(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x answer))
(define (main) : i64 (inc answer))")

(define (compiler-lower-module-symbol-paths) : AstDeclPathList
  (AstDeclPathCons
    "lib.tl"
    (AstDeclPathCons "lib.tl" (AstDeclPathCons "app.tl" AstDeclPathNil))))

(define (compiler-lower-module-symbols-ok?) : bool
  (match (parse-ast-source (compiler-lower-module-symbol-source))
    [(OkAstProgram program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-module-symbol-paths))
        [(OkCompilerLower lowered _)
          (match lowered
            [(IrProgram globals functions _)
              (and
                (lower-test-global-list-has-name? globals "lib.tl::answer")
                (and
                  (>
                    (lower-test-functions-call-count functions "lib.tl::inc")
                    0)
                  (and
                    (>
                      (lower-test-function-binop-count functions "lib.tl::inc")
                      0)
                    (>= (lower-test-function-binop-count functions "main") 0))))])]
        [(ErrCompilerLower _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-lower-module-qualified-source) : String
  "(module left)
(define same : i64 20)
(define (get) : i64 same)
(module right)
(define same : i64 22)
(define (get) : i64 same)
(module main)
(define (main) : i64 (+ (left/get) (right/get)))")

(define (compiler-lower-module-qualified-ok?) : bool
  (match (lower-compiler-source (compiler-lower-module-qualified-source))
    [(OkCompilerLower lowered _)
      (match lowered
        [(IrProgram globals functions _)
          (and
            (lower-test-global-list-has-name? globals "left/same")
            (and
              (lower-test-global-list-has-name? globals "right/same")
              (and
                (> (lower-test-functions-call-count functions "left/get") 0)
                (and
                  (> (lower-test-functions-call-count functions "right/get") 0)
                  (> (lower-test-function-binop-count functions "main") 0)))))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-import-alias-source) : String
  "(module data)
(define (get) : i64 20)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module main)
(import \"data.tl\" module data :as d)
(define (main) : i64
  (+
    (d/get)
    (+
      (let ([p : d/Point (d/Point 7)])
        (struct-get p x))
      (match (d/Some 3)
        [(d/Some v) v]
        [d/None 0]))))")

(define (compiler-lower-import-alias-ok?) : bool
  (match (lower-compiler-source (compiler-lower-import-alias-source))
    [(OkCompilerLower lowered _)
      (match lowered
        [(IrProgram _ functions _)
          (and
            (> (lower-test-functions-call-count functions "data/get") 0)
            (= (lower-test-functions-call-count functions "d/get") 0))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-module-function-returning-struct-source) : String
  "(module data)
(defstruct Candidate (number i64))
(defenum CandList (CandNil) (CandCons Candidate CandList))
(define (cand-nth [cands : CandList]) : Candidate
  (match cands
    [(CandNil) (Candidate 0)]
    [(CandCons head rest) head]))
(module main)
(define (main) : i64
  (let [c : data/Candidate
    (data/cand-nth (data/CandCons (data/Candidate 7) (data/CandNil)))]
    (struct-get c number)))")

(define (compiler-lower-module-function-returning-struct-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-module-function-returning-struct-source))
    [(OkCompilerLower lowered _)
      (match lowered
        [(IrProgram _ functions _)
          (> (lower-test-functions-call-count functions "data/cand-nth") 0)])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-module-function-returning-enum-source) : String
  "(module data)
(defenum Maybe (get))
(module main)
(define (get) : data/Maybe
  (data/get))
(define (main) : i64
  (match (get)
    [data/get 1]))")

(define (compiler-lower-module-function-returning-enum-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-module-function-returning-enum-source))
    [(OkCompilerLower lowered _)
      (match lowered
        [(IrProgram _ functions _)
          (> (lower-test-functions-call-count functions "main/get") 0)])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-module-specialize-source) : String
  "(define (alloc [comptime T : type] [n : i64]) : (Array i64)
  (make-array T n))
(define (main) : (Array i64)
  (alloc (type i64) 4))")

(define (compiler-lower-module-specialize-paths) : AstDeclPathList
  (AstDeclPathCons "app.tl" (AstDeclPathCons "app.tl" AstDeclPathNil)))

(define (compiler-lower-module-specialize-ok?) : bool
  (match (parse-ast-source (compiler-lower-module-specialize-source))
    [(OkAstProgram program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-module-specialize-paths))
        [(OkCompilerLower lowered _)
          (match lowered
            [(IrProgram _ functions _)
              (>
                (lower-test-functions-call-count
                  functions
                  "__tl_specialized_alloc_type_i64_none")
                0)])]
        [(ErrCompilerLower _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-lower-extern-link-metadata-source) : String
  "(extern ffi-add (:abi c) (:symbol \"ffi_add\") (:link-lib \"ffi\") (:link-search \"native\") (:link-arg \"-Wl,--as-needed\") : (-> i64 i64))
(define (main) : i64 (ffi-add 35))")

(define (compiler-lower-extern-link-inputs-ok?
  [inputs : AstExternLinkInputList]) : bool
  (match inputs
    [(AstExternLinkInputCons
        (AstExternLinkLib lib)
        (AstExternLinkInputCons
          (AstExternLinkSearch dir)
          (AstExternLinkInputCons
            (AstExternLinkArg arg-value)
            AstExternLinkInputNil)))
      (and
        (string-eq lib "ffi")
        (and (string-eq dir "native") (string-eq arg-value "-Wl,--as-needed")))]
    [_ false]))

(define (compiler-lower-extern-link-metadata-ok?) : bool
  (match (lower-compiler-source (compiler-lower-extern-link-metadata-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ _ externs)
          (match externs
            [(IrExternCons (IrExtern name _ abi symbol link-inputs) IrExternNil)
              (and
                (string-eq name "ffi-add")
                (and
                  (string-eq symbol "ffi_add")
                  (and
                    (ast-extern-abi-c? abi)
                    (compiler-lower-extern-link-inputs-ok? link-inputs))))]
            [_ false])])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-global-source) : String
  "(extern print-i64 : (-> i64 unit))
(define answer : i64 40)
(define flag : bool true)
(define widened : i64 (cast 7 : i64))
(define (main) : i64
  (begin
    (set! answer 41)
    (if flag (+ answer widened) 0)))")

(define (compiler-lower-global-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-global-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram globals functions externs)
          (let
            [ok : bool true]
            (begin
              (if (lower-test-global-list-has-name? globals "answer")
                unit
                (set! ok false))
              (if (lower-test-global-list-has-name? globals "flag")
                unit
                (set! ok false))
              (if (lower-test-global-list-has-name? globals "widened")
                unit
                (set! ok false))
              (if (match externs
                [(IrExternCons _ IrExternNil) true]
                [_ false])
                unit
                (set! ok false))
              (if (>
                (lower-test-function-store-global-count
                  functions
                  "main"
                  "answer")
                0)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-numeric-source) : String
  "(define (bits [a : i32] [b : i32] [s : i32]) : i32
  (bit-xor (bit-or (bit-and a b) (shl a s)) (shr b s)))
(define (floaty [a : f64] [b : f64]) : bool
  (< (+ a b) 10.0))
(define (casts [c : char] [x : i64]) : u8
  (cast (+ x (cast c : i64)) : u8))
(define (main) : i64
  (if (floaty 1.0 2.0)
    (+ (cast (bits (cast 7 : i32) (cast 3 : i32) (cast 1 : i32)) : i64) (cast (casts #A' 1) : i64))
    0))")

(define (compiler-lower-numeric-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-numeric-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>
                (lower-test-function-binop-op-count
                  functions
                  "bits"
                  IrBinBitAnd)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count functions "bits" IrBinBitOr)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count
                  functions
                  "bits"
                  IrBinBitXor)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count functions "bits" IrBinShl)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count functions "bits" IrBinShr)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count functions "floaty" IrBinAdd)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-binop-op-count functions "floaty" IrBinLt)
                0)
                unit
                (set! ok false))
              (if (> (lower-test-function-cast-count functions "casts") 0)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-tail-simple-source) : String
  "(define (loop [n : i64] [acc : i64]) : i64
  (if (= n 0)
    acc
    (loop (- n 1) (+ acc 1))))
(define (main) : i64 (loop 3 0))")

(define (compiler-lower-tail-context-source) : String
  "(define (loop [n : i64] [acc : i64]) : i64
  (let
    [next : i64 (- n 1)]
    (begin
      unit
      (ann
        (match n
          [0 acc]
          [_ (cast (loop next (+ acc 1)) : i64)])
        : i64))))
(define (main) : i64 (loop 3 0))")

(define (compiler-lower-tail-operand-source) : String
  "(define (loop [n : i64]) : i64
  (+ 1 (loop (- n 1))))
(define (main) : i64 (loop 3))")

(define (compiler-lower-tail-simple-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tail-simple-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (= (lower-test-function-tail-call-count functions "loop" "loop") 1)
            (= (lower-test-function-call-count functions "loop" "loop") 0))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-tail-context-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tail-context-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (= (lower-test-function-tail-call-count functions "loop" "loop") 1)
            (= (lower-test-function-call-count functions "loop" "loop") 0))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-tail-operand-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tail-operand-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (= (lower-test-function-tail-call-count functions "loop" "loop") 0)
            (> (lower-test-function-call-count functions "loop" "loop") 0))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-tail-call-shape-ok?) : bool
  (and
    (compiler-lower-tail-simple-shape-ok?)
    (and
      (compiler-lower-tail-context-shape-ok?)
      (compiler-lower-tail-operand-shape-ok?))))

;; CTFE fold verification (#719): a folded `(comptime ...)` lowers to a literal,
;; so the function body must contain a `Mov` of the expected i64 literal and no
;; `BinOp`/`UnOp` instructions (the arithmetic was evaluated at compile time).
(define (lower-test-instr-i64-mov-count [instr : CompilerIrInstr] [want : i64]) : i64
  (match instr
    [(IrInstrMov _ value _)
      (match value
        [(IrValueI64 n)
          (if (= n want)
            1
            0)]
        [_ 0])]
    [_ 0]))

(define (lower-test-instr-binop-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrBinOp _ _ _ _ _) 1]
    [(IrInstrUnOp _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-gep-offset-count
  [instr : CompilerIrInstr]
  [want : i64]) : i64
  (match instr
    [(IrInstrGep _ _ offset _)
      (match offset
        [(IrValueI64 n)
          (if (= n want)
            1
            0)]
        [_ 0])]
    [_ 0]))

(define (lower-test-instrs-i64-mov-count
  [instrs : CompilerIrInstrList]
  [want : i64]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-i64-mov-count instr want)
        (lower-test-instrs-i64-mov-count rest want))]))

(define (lower-test-instrs-binop-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-binop-count instr)
        (lower-test-instrs-binop-count rest))]))

(define (lower-test-instrs-gep-offset-count
  [instrs : CompilerIrInstrList]
  [want : i64]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-gep-offset-count instr want)
        (lower-test-instrs-gep-offset-count rest want))]))

(define (lower-test-blocks-i64-mov-count
  [blocks : CompilerIrBlockList]
  [want : i64]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-i64-mov-count instrs want)
            (lower-test-blocks-i64-mov-count rest want))])]))

(define (lower-test-blocks-binop-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-binop-count instrs)
            (lower-test-blocks-binop-count rest))])]))

(define (lower-test-blocks-gep-offset-count
  [blocks : CompilerIrBlockList]
  [want : i64]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instrs-gep-offset-count instrs want)
            (lower-test-blocks-gep-offset-count rest want))])]))

(define (lower-test-function-i64-mov-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [want : i64]) : i64
  (match funcs
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-i64-mov-count blocks want)
            (lower-test-function-i64-mov-count rest name want))])]))

(define (lower-test-function-binop-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-binop-count blocks)
            (lower-test-function-binop-count rest name))])]))

(define (lower-test-function-gep-offset-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [want : i64]) : i64
  (match funcs
    [(IrFunctionNil) (- 0 1)]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-gep-offset-count blocks want)
            (lower-test-function-gep-offset-count rest name want))])]))

(define (compiler-lower-comptime-fold-ok? [src : String] [want : i64]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (> (lower-test-function-i64-mov-count functions "main" want) 0)
            (= (lower-test-function-binop-count functions "main") 0))])]
    [(ErrCompilerLower _) false]))

;; The value-returning scalar matches (`classify`/`flag-score`/`sign`) each emit
;; a merge phi; the unit-typed match (`announce`) emits no value phi.
(define (compiler-lower-match-phi-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program _)
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
    [(OkCompilerLower program _)
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

(define (compiler-lower-result-try-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (> (lower-test-function-branch-count functions "sum") 1)
            (and
              (> (lower-test-function-return-count functions "sum") 2)
              (and
                (> (lower-test-function-return-count functions "chain") 1)
                (> (lower-test-function-load-count functions "sum") 3))))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-return-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-return-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (> (lower-test-function-return-count functions "main") 1)])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-return-with-arena-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-return-with-arena-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (> (lower-test-function-return-count functions "main") 1)
            (> (lower-test-functions-call-count functions "tl_region_reset") 1))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-resource-with-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-resource-with-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (= (lower-test-functions-call-count functions "close-a") 3)
            (and
              (= (lower-test-functions-call-count functions "close-b") 2)
              (and
                (> (lower-test-function-return-count functions "main") 2)
                (> (lower-test-function-branch-count functions "main") 2))))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-resource-with-nested-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-resource-with-nested-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (= (lower-test-functions-call-count functions "close-a") 1)
            (= (lower-test-functions-call-count functions "close-b") 1))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-array-access-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (> (lower-test-function-bounds-count functions "get") 0)
            (> (lower-test-function-bounds-count functions "put") 0))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-fixed-array-access-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (> (lower-test-function-bounds-count functions "get") 0)
                unit
                (set! ok false))
              (if (> (lower-test-function-load-count functions "get") 0)
                unit
                (set! ok false))
              (if (> (lower-test-function-bounds-count functions "put") 0)
                unit
                (set! ok false))
              (if (= (lower-test-function-gep-offset-count functions "get" 1) 0)
                unit
                (set! ok false))
              (if (= (lower-test-function-gep-offset-count functions "put" 1) 0)
                unit
                (set! ok false))
              (if (> (lower-test-function-store-ptr-count functions "put") 0)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-array-push-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (> (lower-test-functions-call-count functions "tl_alloc") 0)
            (and
              (> (lower-test-functions-call-count functions "tl_oob_abort") 0)
              (and
                (> (lower-test-function-binop-count functions "grow") 0)
                (> (lower-test-function-store-ptr-count functions "grow") 0))))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-make-array-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (> (lower-test-functions-call-count functions "tl_alloc") 1)
            (> (lower-test-functions-call-count functions "tl_oob_abort") 0))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-string-runtime-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>
                (lower-test-functions-call-count functions "tl_substring")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-call-count functions "tl_string_concat")
                1)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-call-count functions "tl_oob_abort")
                0)
                unit
                (set! ok false))
              (if (= (lower-test-functions-call-count functions "substring") 0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "string-append")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "string-concat")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-call-count functions "tl_print_str")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "print-string")
                0)
                unit
                (set! ok false))
              (if (= (lower-test-functions-call-count functions "print-str") 0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_print_char")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_print_f64")
                1)
                unit
                (set! ok false))
              (if (= (lower-test-functions-call-count functions "print-char") 0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "print-float")
                0)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-borrowed-str-param-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-borrowed-str-param-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>
                (lower-test-function-call-count
                  functions
                  "main"
                  "borrowed-score")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count
                  functions
                  "borrowed-score"
                  "tl_print_str")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count
                  functions
                  "borrowed-score"
                  ".L_tl_file_exists_status")
                1)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-gep-offset-count
                  functions
                  "borrowed-score"
                  1)
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "string-length")
                0)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-reference-values-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-reference-return-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>
                (lower-test-function-call-count
                  functions
                  "ref-return"
                  "tl_alloc")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count functions "ref-id" "tl_alloc")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-store-ptr-count functions "ref-tuple")
                1)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-store-ptr-count functions "ref-array")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-return-count functions "ref-return")
                1)
                unit
                (set! ok false))
              (if (= (lower-test-function-return-count functions "ref-id") 1)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-reference-place-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-reference-place-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>
                (lower-test-function-gep-offset-count functions "borrow-pair" 0)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-gep-offset-count
                  functions
                  "borrow-tuple"
                  0)
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-function-bounds-count functions "borrow-array")
                0)
                unit
                (set! ok false))
              (if (= (lower-test-function-load-count functions "borrow-pair") 0)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-string-shadow-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program _)
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

(define (compiler-lower-function-value-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-function-value-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-function-indirect-call-count functions "apply1")
                1)
                unit
                (set! ok false))
              (if (= (lower-test-function-call-count functions "apply1" "f") 0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-call-count functions "shadow-inc")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-count functions "shadow-inc" "inc")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-call-arg-function-count
                  functions
                  "main"
                  "apply1"
                  "inc")
                1)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-noncapturing-lambda-value-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-noncapturing-lambda-value-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [lambda-name : String "__tl_lambda_get-fn_0"]
            (and
              (= (compiler-ir-function-list-count functions) 2)
              (and
                (=
                  (lower-test-function-return-function-count
                    functions
                    "get-fn"
                    lambda-name)
                  1)
                (> (lower-test-function-binop-count functions lambda-name) 0))))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-immediate-lambda-call-ok?) : bool
  (match (lower-compiler-source (compiler-lower-immediate-lambda-call-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            (and
              (= (compiler-ir-function-list-count functions) 2)
              (and
                (= (lower-test-function-indirect-call-count functions "main") 1)
                (and
                  (=
                    (lower-test-function-indirect-callee-function-count
                      functions
                      "main"
                      lambda-name)
                    1)
                  (=
                    (lower-test-function-call-count
                      functions
                      "main"
                      lambda-name)
                    0)))))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-unit-lambda-call-ok?) : bool
  (match (lower-compiler-source (compiler-lower-unit-lambda-call-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            (and
              (= (compiler-ir-function-list-count functions) 2)
              (and
                (= (lower-test-function-indirect-unit-count functions "main") 1)
                (=
                  (lower-test-function-indirect-callee-function-count
                    functions
                    "main"
                    lambda-name)
                  1))))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-noncapturing-lambda-tests-ok?) : bool
  (and
    (compiler-lower-noncapturing-lambda-value-ok?)
    (and
      (compiler-lower-immediate-lambda-call-ok?)
      (compiler-lower-unit-lambda-call-ok?))))

(define (compiler-lower-capturing-lambda-scalar-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-capturing-lambda-scalar-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            [ok : bool true]
            (begin
              (if (= (compiler-ir-function-list-count functions) 2)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-call-count functions "main")
                1)
                unit
                (set! ok false))
              (if (>= (lower-test-function-store-ptr-count functions "main") 3)
                unit
                (set! ok false))
              (if (>= (lower-test-functions-call-count functions "tl_alloc") 2)
                unit
                (set! ok false))
              (if (>= (lower-test-function-load-count functions lambda-name) 1)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-capturing-lambda-function-value-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-capturing-lambda-function-value-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [capturing-name : String "__tl_lambda_main_1"]
            [ok : bool true]
            (begin
              (if (= (compiler-ir-function-list-count functions) 3)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-call-count functions "main")
                1)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-indirect-call-count
                  functions
                  capturing-name)
                1)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-load-count functions capturing-name)
                2)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-capturing-lambda-fat-handle-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-capturing-lambda-fat-handle-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            [ok : bool true]
            (begin
              (if (= (compiler-ir-function-list-count functions) 2)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-call-count functions "main")
                1)
                unit
                (set! ok false))
              (if (>= (lower-test-functions-call-count functions "tl_alloc") 3)
                unit
                (set! ok false))
              (if (>= (lower-test-function-load-count functions lambda-name) 2)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-capturing-lambda-aggregate-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-capturing-lambda-aggregate-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [lambda-name : String "__tl_lambda_main_0"]
            [ok : bool true]
            (begin
              (if (= (compiler-ir-function-list-count functions) 2)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-call-count functions "main")
                1)
                unit
                (set! ok false))
              (if (>= (lower-test-functions-call-count functions "tl_alloc") 5)
                unit
                (set! ok false))
              (if (>= (lower-test-function-store-ptr-count functions "main") 8)
                unit
                (set! ok false))
              (if (>= (lower-test-function-load-count functions lambda-name) 4)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-capturing-lambda-shadow-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-capturing-lambda-shadow-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (= (compiler-ir-function-list-count functions) 2)
            (= (lower-test-function-indirect-call-count functions "main") 1))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-capturing-lambda-tests-ok?) : bool
  (and
    (compiler-lower-capturing-lambda-scalar-shape-ok?)
    (and
      (compiler-lower-capturing-lambda-function-value-shape-ok?)
      (and
        (compiler-lower-capturing-lambda-fat-handle-shape-ok?)
        (and
          (compiler-lower-capturing-lambda-aggregate-shape-ok?)
          (compiler-lower-capturing-lambda-shadow-shape-ok?))))))

(define (compiler-lower-file-handle-status-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_file_open_status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_file_close_status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_append_file_status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_file_read_chunk_status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_file_write_status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_file_flush_status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_file_read_chunk_bytes")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_file_read_chunk_eof")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "file-open-status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "file-close-status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "append-file-status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  "file-read-chunk-status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "file-write-status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "file-flush-status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  "file-read-chunk-bytes")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  "file-read-chunk-eof?")
                0)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-fs-status-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-fs-status-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_mkdir_status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_remove_file_status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_remove_dir_status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_rename_status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_process_id")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  "tl_fs_current_dir_status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_fs_current_dir")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "fs-mkdir-status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "fs-rename-status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "fs-process-id")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  "fs-current-dir-status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "fs-current-dir")
                0)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-region-source) : String
  "(define (main) : i64
  (with-arena r
    (let
      [s : String (int->string 41)]
      (string-length s))))")

(define (compiler-lower-region-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-region-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (> (lower-test-functions-call-count functions "tl_region_mark") 0)
            (> (lower-test-functions-call-count functions "tl_region_reset") 0))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-with-escape-scalar-source) : String
  "(define (main) : i64
  (let
    [scratch : i64 (arena-make)]
    (with-escape scratch 40 42)))")

(define (compiler-lower-with-escape-string-source) : String
  "(define (main) : String
  (let
    [scratch : i64 (arena-make)]
    (with-escape scratch (int->string 42))))")

(define (compiler-lower-with-escape-arena-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (>=
              (lower-test-functions-call-count functions "tl_arena_current")
              3)
            (and
              (>= (lower-test-functions-call-count functions "tl_arena_set") 4)
              (and
                (>
                  (lower-test-functions-call-count functions "tl_region_mark")
                  0)
                (>
                  (lower-test-functions-call-count functions "tl_region_reset")
                  0))))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-with-escape-shape-ok?) : bool
  (and
    (compiler-lower-with-escape-arena-shape-ok?
      (compiler-lower-with-escape-scalar-source))
    (match (lower-compiler-source (compiler-lower-with-escape-string-source))
      [(OkCompilerLower program _)
        (match program
          [(IrProgram _ functions _)
            (and
              (compiler-lower-with-escape-arena-shape-ok?
                (compiler-lower-with-escape-string-source))
              (> (lower-test-functions-call-count functions "tl_substring") 0))])]
      [(ErrCompilerLower _) false])))

(define (compiler-lower-repr-c-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-repr-c-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (> (lower-test-functions-call-count functions "tl_alloc") 0)
            (and
              (> (lower-test-function-gep-offset-count functions "main" 4) 0)
              (> (lower-test-function-gep-offset-count functions "main" 12) 0)))])]
    [(ErrCompilerLower _) false]))

;; `foreach` scalar lowering (#1012): a foreach `main` lowers to a loop, so its
;; body holds at least the guard branch (`i < end`) and two binops (the `<`
;; guard and the `+ 1` increment).
(define (compiler-lower-foreach-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (> (lower-test-function-branch-count functions "main") 0)
            (> (lower-test-function-binop-count functions "main") 1))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-avx2-foreach-map-source) : String
  "(define (fill [a : (Array i64)] [b : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-i32-source) : String
  "(define (fill [a : (Array i32)] [b : (Array i32)] [out : (Array i32)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-map-f64-source) : String
  "(define (fill [a : (Array f64)] [b : (Array f64)] [out : (Array f64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-lower-avx2-foreach-scalar-fallback-source) : String
  "(define (fill [a : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) 1))))")

(define (compiler-lower-avx2-foreach-map-source-shape-ok?
  [src : String]
  [elem-ty : AstType]
  [lanes : i64]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerAvx2))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count functions "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count functions "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count functions "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                functions
                "fill"
                lanes
                elem-ty)]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count functions "fill")]
            (and
              (= load-count 2)
              (and
                (= binop-count 1)
                (and
                  (= store-count 1)
                  (and (= shape-count 4) (> tail-store-count 0))))))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-avx2-foreach-map-shape-ok?) : bool
  (and
    (compiler-lower-avx2-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-source)
      (AstTyI64)
      4)
    (and
      (compiler-lower-avx2-foreach-map-source-shape-ok?
        (compiler-lower-avx2-foreach-map-i32-source)
        (AstTyI32)
        8)
      (compiler-lower-avx2-foreach-map-source-shape-ok?
        (compiler-lower-avx2-foreach-map-f64-source)
        (AstTyF64)
        4))))

(define (compiler-lower-and8
  [a : bool]
  [b : bool]
  [c : bool]
  [d : bool]
  [e : bool]
  [f : bool]
  [g : bool]
  [h : bool]) : bool
  (and (and (and a b) (and c d)) (and (and e f) (and g h))))

(define (compiler-lower-avx512-foreach-map-source-shape-ok?
  [src : String]
  [elem-ty : AstType]
  [lanes : i64]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerAvx512))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count functions "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count functions "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count functions "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count functions "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count functions "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count functions "fill")]
            [shape-count : i64
              (lower-test-function-vector-shape-count
                functions
                "fill"
                lanes
                elem-ty)]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count functions "fill")]
            (compiler-lower-and8
              (= load-count 2)
              (= binop-count 2)
              (= store-count 1)
              (= pred-load-count 2)
              (= pred-store-count 1)
              (= tail-mask-count 1)
              (= shape-count 8)
              (> tail-store-count 0)))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-avx512-foreach-map-shape-ok?) : bool
  (and
    (compiler-lower-avx512-foreach-map-source-shape-ok?
      (compiler-lower-avx2-foreach-map-source)
      (AstTyI64)
      8)
    (and
      (compiler-lower-avx512-foreach-map-source-shape-ok?
        (compiler-lower-avx2-foreach-map-i32-source)
        (AstTyI32)
        16)
      (compiler-lower-avx512-foreach-map-source-shape-ok?
        (compiler-lower-avx2-foreach-map-f64-source)
        (AstTyF64)
        8))))

(define (compiler-lower-scalar-foreach-stays-scalar-ok?) : bool
  (match (lower-compiler-source (compiler-lower-avx2-foreach-map-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (= (lower-test-function-vector-load-count functions "fill") 0)])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-avx2-foreach-fallback-stays-scalar-ok?) : bool
  (match (lower-compiler-source-with-mode
    (compiler-lower-avx2-foreach-scalar-fallback-source)
    (CompilerLowerAvx2))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (= (lower-test-function-vector-load-count functions "fill") 0)
            (and
              (= (lower-test-function-vector-binop-count functions "fill") 0)
              (= (lower-test-function-vector-store-count functions "fill") 0)))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-foreach-tests-ok?) : bool
  (and
    (compiler-lower-and8
      (compiler-lower-ok?
        "(define (main) : i64 (begin (foreach ([i : i64 0 3]) unit) 0))")
      (compiler-lower-ok?
        "(define (f [a : (Array i64)] [n : i64]) : unit (foreach ([i : i64 0 n]) (array-set! a i i)))")
      (compiler-lower-ok?
        "(define (main) : i64 (begin (foreach ([i : i64 0 0]) unit) 0))")
      (compiler-lower-ok?
        "(define (main) : i64 (begin (foreach ([i : i64 0 3]) (foreach ([j : i64 0 2]) unit)) 0))")
      (compiler-lower-foreach-shape-ok?
        "(define (main) : i64 (begin (foreach ([i : i64 0 3]) unit) 0))")
      (compiler-lower-avx2-foreach-map-shape-ok?)
      (compiler-lower-avx512-foreach-map-shape-ok?)
      (compiler-lower-scalar-foreach-stays-scalar-ok?))
    (compiler-lower-avx2-foreach-fallback-stays-scalar-ok?)))

(define (compiler-lower-avx2-spmd-reduce-shape-ok?
  [src : String]
  [elem-ty : AstType]
  [lanes : i64]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerAvx2))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (= (lower-test-function-vector-load-count functions "f") 1)
            (and
              (= (lower-test-function-vector-reduce-count functions "f") 1)
              (and
                (=
                  (lower-test-function-vector-shape-count
                    functions
                    "f"
                    lanes
                    elem-ty)
                  2)
                (> (lower-test-function-bounds-count functions "f") 0))))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-avx2-spmd-reduce-stays-scalar-ok? [src : String]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerAvx2))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (= (lower-test-function-vector-reduce-count functions "f") 0)])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-avx2-spmd-reduce-tests-ok?) : bool
  (and
    (compiler-lower-and8
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))"
        (AstTyI64)
        4)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (Array i32)] [n : i64]) : i32 (spmd-reduce sum ([i : i64 0 n]) (cast 0 : i32) (array-ref xs i)))"
        (AstTyI32)
        8)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (Array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
        (AstTyI32)
        8)
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (Array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
        (AstTyI32)
        8)
      (compiler-lower-avx2-spmd-reduce-stays-scalar-ok?
        "(define (f [xs : (Array f64)] [n : i64]) : f64 (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref xs i)))")
      (compiler-lower-avx2-spmd-reduce-stays-scalar-ok?
        "(define (f [xs : (Array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))")
      true
      true)
    true))

;; `spmd-reduce` sum lowering (#1013): integer and f64 sum reductions lower (to
;; an accumulator loop, so `main` holds the guard branch + fold/increment
;; binops), while the not-yet-lowered min/max/all/any ops reject gracefully.
(define (compiler-lower-spmd-reduce-tests-ok?) : bool
  (and
    (compiler-lower-ok?
      "(define (f [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))")
    (and
      (compiler-lower-ok?
        "(define (f [xs : (Array f64)] [n : i64]) : f64 (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref xs i)))")
      (and
        (compiler-lower-foreach-shape-ok?
          "(define (main [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 i))")
        (and
          (compiler-lower-ok?
            "(define (f [xs : (Array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))")
          (and
            (compiler-lower-ok?
              "(define (f [xs : (Array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))")
            (and
              (compiler-lower-ok?
                "(define (f [xs : (Array bool)] [n : i64]) : bool (spmd-reduce all ([i : i64 0 n]) true (array-ref xs i)))")
              (and
                (compiler-lower-ok?
                  "(define (f [xs : (Array bool)] [n : i64]) : bool (spmd-reduce any ([i : i64 0 n]) false (array-ref xs i)))")
                (compiler-lower-avx2-spmd-reduce-tests-ok?)))))))))

;; Comptime folding of the remaining scalar operators: each `(comptime ...)`
;; must collapse to a single constant `mov` with no residual runtime binop,
;; complementing the `+`/`<`/`*`/`let` cases already in the self-test (#1043).
(define (compiler-lower-comptime-op-fold-tests-ok?) : bool
  (and
    (compiler-lower-comptime-fold-ok?
      "(define (main) : i64 (comptime (- 50 8)))"
      42)
    (and
      (compiler-lower-comptime-fold-ok?
        "(define (main) : i64 (comptime (/ 84 2)))"
        42)
      (and
        (compiler-lower-comptime-fold-ok?
          "(define (main) : i64 (comptime (% 142 100)))"
          42)
        (and
          (compiler-lower-comptime-fold-ok?
            "(define (main) : i64 (comptime (bit-and 63 42)))"
            42)
          (and
            (compiler-lower-comptime-fold-ok?
              "(define (main) : i64 (comptime (bit-or 40 2)))"
              42)
            (and
              (compiler-lower-comptime-fold-ok?
                "(define (main) : i64 (comptime (bit-xor 63 21)))"
                42)
              (and
                (compiler-lower-comptime-fold-ok?
                  "(define (main) : i64 (comptime (shl 21 1)))"
                  42)
                (and
                  (compiler-lower-comptime-fold-ok?
                    "(define (main) : i64 (comptime (shr 84 1)))"
                    42)
                  (compiler-lower-comptime-fold-ok?
                    "(define (main) : i64 (comptime (if (= 5 5) 42 0)))"
                    42))))))))))

;; `size-of`/`align-of` comptime layout queries (#989 slice 1): a scalar type
;; folds to its byte size / alignment (equal for primitives) inside `(comptime …)`.
(define (compiler-lower-layout-query-fold-tests-ok?) : bool
  (and
    (compiler-lower-comptime-fold-ok?
      "(define (main) : i64 (comptime (size-of (type i64))))"
      8)
    (and
      (compiler-lower-comptime-fold-ok?
        "(define (main) : i64 (comptime (align-of (type i64))))"
        8)
      (and
        (compiler-lower-comptime-fold-ok?
          "(define (main) : i64 (comptime (size-of (type i32))))"
          4)
        (and
          (compiler-lower-comptime-fold-ok?
            "(define (main) : i64 (comptime (size-of (type bool))))"
            1)
          (and
            (compiler-lower-comptime-fold-ok?
              "(define (main) : i64 (comptime (size-of (type char))))"
              1)
            (and
              (compiler-lower-comptime-fold-ok?
                "(defstruct Inner
  (:repr c)
  (x i32))
(defstruct Outer
  (:repr c)
  (tag u8)
  (inner Inner)
  (tail i64))
(define (main) : i64
  (comptime (+ (size-of (type Outer))
    (+ (align-of (type Outer))
      (+ (offset-of (type Outer) inner)
        (+ (offset-of (type Outer) tail) 6))))))"
                42)
              (compiler-lower-error-ok?
                "(define (main) : i64 (size-of (type i64)))"
                "typecheck: size-of is compile-time only; wrap it in (comptime ...)"))))))))

;; `and`/`or` short-circuit lowering (#1132 / #1165): `(and a b)` and `(or a b)`
;; desugar to a conditional branch, so a function whose body is a bare `and`/`or`
;; of two boolean params must emit at least one branch and NO eager binop (the
;; old `IrBinAnd`/`IrBinOr` path would have produced one binop and no branch).
(define (compiler-lower-and-short-circuit-source) : String
  "(define (f [a : bool] [b : bool]) : bool (and a b))")

(define (compiler-lower-or-short-circuit-source) : String
  "(define (f [a : bool] [b : bool]) : bool (or a b))")

(define (compiler-lower-short-circuit-branch? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (> (lower-test-function-branch-count functions "f") 0)
            (= (lower-test-function-binop-count functions "f") 0))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-and-or-short-circuit-shape-ok?) : bool
  (and
    (compiler-lower-short-circuit-branch?
      (compiler-lower-and-short-circuit-source))
    (compiler-lower-short-circuit-branch?
      (compiler-lower-or-short-circuit-source))))

(define (compiler-lower-raw-pointer-ops-ok?) : bool
  (and
    (compiler-lower-ok? (compiler-lower-raw-pointer-ops-source))
    (and
      (compiler-lower-ok? (compiler-lower-raw-pointer-direct-call-source))
      (compiler-lower-ok? (compiler-lower-raw-pointer-call-value-source)))))

(define (compiler-lower-raw-pointer-call-value-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-raw-pointer-call-value-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (= (lower-test-functions-call-count functions "raw-make") 1)
            (and
              (= (lower-test-functions-call-count functions "raw-value") 1)
              (and
                (= (lower-test-function-store-ptr-count functions "main") 1)
                (> (lower-test-function-u64-mov-count functions "main") 0))))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-string-length-ok?) : bool
  (match (parse-ast-source (compiler-lower-string-length-source))
    [(OkAstProgram program)
      (match (lower-compiler-program program)
        [(OkCompilerLower _ _) true]
        [(ErrCompilerLower _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-lower-string-runtime-ok?) : bool
  (match (parse-ast-source (compiler-lower-string-runtime-source))
    [(OkAstProgram program)
      (match (lower-compiler-program program)
        [(OkCompilerLower _ _) true]
        [(ErrCompilerLower _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-lower-stdio-ok?) : bool
  (match (parse-ast-source (compiler-lower-stdio-source))
    [(OkAstProgram program)
      (match (lower-compiler-program program)
        [(OkCompilerLower _ _) true]
        [(ErrCompilerLower _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-lower-runtime-helper-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-lower-string-length-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-string-runtime-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-string-runtime-shape-ok?
        (compiler-lower-string-runtime-source))
        unit
        (set! ok false))
      (if (compiler-lower-borrowed-str-param-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-string-shadow-shape-ok?
        (compiler-lower-string-shadow-source))
        unit
        (set! ok false))
      (if (compiler-lower-stdio-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-fs-status-shape-ok?)
        unit
        (set! ok false))
      ok)))

(define (compiler-lower-front-half-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-lower-and-or-short-circuit-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-ok-summary? (compiler-lower-smoke-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-macro-expand-source))
        unit
        (set! ok false))
      (if (compiler-lower-error-ok?
        (compiler-lower-macro-arity-source)
        "macro call has too few arguments")
        unit
        (set! ok false))
      (if (compiler-lower-spans-ok? (compiler-lower-smoke-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-match-source))
        unit
        (set! ok false))
      (if (compiler-lower-match-phi-shape-ok? (compiler-lower-match-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-enum-match-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-enum-literal-payload-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-enum-nested-payload-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-export-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-result-try-source))
        unit
        (set! ok false))
      (if (compiler-lower-error-ok?
        (compiler-lower-enum-string-literal-payload-source)
        "lower: unsupported enum payload literal pattern type")
        unit
        (set! ok false))
      ok)))

(define (compiler-lower-middle-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-lower-enum-match-shape-ok?
        (compiler-lower-enum-match-source))
        unit
        (set! ok false))
      (if (compiler-lower-result-try-shape-ok?
        (compiler-lower-result-try-source))
        unit
        (set! ok false))
      (if (compiler-lower-return-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-return-with-arena-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-resource-with-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-resource-with-nested-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-array-length-source))
        unit
        (set! ok false))
      (if (compiler-lower-array-access-shape-ok?
        (compiler-lower-array-access-source))
        unit
        (set! ok false))
      (if (compiler-lower-fixed-array-access-shape-ok?
        (compiler-lower-fixed-array-access-source))
        unit
        (set! ok false))
      (if (compiler-lower-array-push-shape-ok?
        (compiler-lower-array-push-source))
        unit
        (set! ok false))
      (if (compiler-lower-error-ok?
        (compiler-lower-fixed-array-push-source)
        "typecheck: array-push! requires dynamic array type")
        unit
        (set! ok false))
      (if (compiler-lower-make-array-shape-ok?
        (compiler-lower-make-array-source))
        unit
        (set! ok false))
      (if (compiler-lower-runtime-helper-tests-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-function-value-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-noncapturing-lambda-tests-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-capturing-lambda-tests-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-aggregate-source))
        unit
        (set! ok false))
      (if (compiler-lower-tuple-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-inline-aggregate-tests-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-comptime-decl-source))
        unit
        (set! ok false))
      (if (compiler-lower-module-symbols-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-module-qualified-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-import-alias-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-module-function-returning-struct-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-module-function-returning-enum-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-extern-link-metadata-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-global-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-raw-pointer-ops-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-raw-pointer-call-value-shape-ok?)
        unit
        (set! ok false))
      ok)))

(define (lower-test-decl-list-count [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons _ rest) (+ 1 (lower-test-decl-list-count rest))]))

(define (lower-test-decl-list-defines? [decls : AstDeclList] [name : String]) : bool
  (match decls
    [(AstDeclNil) false]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclDefFn found _ _ _)
          (if (string-eq found name)
            true
            (lower-test-decl-list-defines? rest name))]
        [_ (lower-test-decl-list-defines? rest name)])]))

(define (compiler-lower-ast-dce-program) : AstProgram
  (AstProgram
    (AstDeclCons
      (AstDeclDef "callback" AstNoType (AstExprVar "callback-target"))
      (AstDeclCons
        (AstDeclDefFn
          "main"
          AstParamNil
          (AstTyI64)
          (AstExprCall (AstExprVar "helper") AstExprNil))
        (AstDeclCons
          (AstDeclDefFn
            "helper"
            AstParamNil
            (AstTyI64)
            (AstExprLiteral (AstLitInt 7)))
          (AstDeclCons
            (AstDeclDefFn
              "callback-target"
              AstParamNil
              (AstTyI64)
              (AstExprLiteral (AstLitInt 11)))
            (AstDeclCons
              (AstDeclDefFn
                "dead"
                AstParamNil
                (AstTyI64)
                (AstExprLiteral (AstLitInt 9)))
              AstDeclNil)))))))

(define (compiler-lower-ast-dce-no-main-program) : AstProgram
  (AstProgram
    (AstDeclCons
      (AstDeclDefFn
        "helper"
        AstParamNil
        (AstTyI64)
        (AstExprLiteral (AstLitInt 7)))
      (AstDeclCons
        (AstDeclDefFn
          "dead"
          AstParamNil
          (AstTyI64)
          (AstExprLiteral (AstLitInt 9)))
        AstDeclNil))))

(define (compiler-lower-ast-dce-ok?) : bool
  (let
    [program : AstProgram (compiler-lower-ast-dce-program)]
    [no-main-program : AstProgram (compiler-lower-ast-dce-no-main-program)]
    [names : LowerNameEnv
      (match program
        [(AstProgram decls)
          (lower-name-env-from-decls
            decls
            AstDeclPathNil
            "entry.tl"
            LowerNameNil)])]
    [no-main-names : LowerNameEnv
      (match no-main-program
        [(AstProgram decls)
          (lower-name-env-from-decls
            decls
            AstDeclPathNil
            "entry.tl"
            LowerNameNil)])]
    [pruned : LowerPrunedProgram
      (lower-prune-unreachable-functions
        "entry.tl"
        program
        AstDeclPathNil
        names)]
    [no-main-pruned : LowerPrunedProgram
      (lower-prune-unreachable-functions
        "entry.tl"
        no-main-program
        AstDeclPathNil
        no-main-names)]
    (match pruned
      [(LowerPrunedProgram kept-program _)
        (match no-main-pruned
          [(LowerPrunedProgram kept-no-main _)
            (match kept-program
              [(AstProgram kept)
                (match kept-no-main
                  [(AstProgram no-main-kept)
                    (and
                      (= (lower-test-decl-list-count kept) 4)
                      (and
                        (lower-test-decl-list-defines? kept "main")
                        (and
                          (lower-test-decl-list-defines? kept "helper")
                          (and
                            (lower-test-decl-list-defines?
                              kept
                              "callback-target")
                            (and
                              (not (lower-test-decl-list-defines? kept "dead"))
                              (= (lower-test-decl-list-count no-main-kept) 2))))))])])])])))

(define (compiler-lower-back-half-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-lower-module-specialize-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-region-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-with-escape-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-repr-c-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-error-ok?
        (compiler-typecheck-branch-mismatch-source)
        "typecheck: if branches must match")
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-array-literal-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-box-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-box-get-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-reference-source))
        unit
        (set! ok false))
      (if (compiler-lower-reference-values-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-reference-place-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-comptime-fold-ok?
        (compiler-lower-comptime-arith-source)
        3)
        unit
        (set! ok false))
      (if (compiler-lower-comptime-fold-ok?
        (compiler-lower-comptime-if-source)
        42)
        unit
        (set! ok false))
      (if (compiler-lower-comptime-fold-ok?
        (compiler-lower-comptime-let-source)
        42)
        unit
        (set! ok false))
      (if (compiler-lower-error-ok?
        (compiler-lower-comptime-runtime-var-source)
        "compile-time evaluation cannot reference runtime variable 'x'")
        unit
        (set! ok false))
      (if (compiler-lower-error-ok?
        (compiler-lower-comptime-f64-source)
        "comptime: f64 compile-time evaluation not yet supported (#735)")
        unit
        (set! ok false))
      (if (compiler-lower-comptime-op-fold-tests-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-layout-query-fold-tests-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-numeric-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-tail-call-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-foreach-tests-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-spmd-reduce-tests-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-ast-dce-ok?)
        unit
        (set! ok false))
      ok)))

(define (compiler-lower-self-test) : i64
  (if (and
    (compiler-lower-front-half-tests-ok?)
    (and (compiler-lower-middle-tests-ok?) (compiler-lower-back-half-tests-ok?)))
    42
    (begin
      (panic "lower: smoke score mismatch")
      0)))
