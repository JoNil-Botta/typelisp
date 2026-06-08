;; compiler_lower.tl - First selfhost compiler AST-to-IR lowering slice (#446).
;;
;; The lowerer accepts the checked scalar subset and builds a deterministic
;; CompilerIrProgram. It also covers scalar match and heap-backed struct/enum
;; construction/projection; closure, array, and enum-match lowering remain
;; explicit future work.
(import "../stdlib/io.tl")

(import "../stdlib/arena.tl")

(import "compiler_typecheck.tl")

(import "compiler_diagnostic.tl")

(import "compiler_ir_types.tl")

(import "compiler_clone.tl")

(import "compiler_ctfe.tl")

(import "../stdlib/hashmap.tl")

(import "../stdlib/string.tl")

(defenum LowerNameEnv
  (LowerNameNil)
  (LowerNameBind String String (Box LowerNameEnv)))

(defstruct LowerNameCache
  (ids StringI64Map)
  (values (Array String)))

(defenum LowerTypeCache
  (LowerNoTypeCache)
  (LowerSomeTypeCache StringI64Map (Array AstType) i64))

(defenum LowerStringSet
  (LowerStringNil)
  (LowerStringCons String (Box LowerStringSet)))

(defenum LowerReachState
  (LowerReachState StringI64Map LowerStringSet))

(defenum LowerMaybeFunctionBody
  (LowerNoFunctionBody)
  (LowerSomeFunctionBody AstExpr))

(defenum LowerCloneRootEnv
  (LowerCloneRootEnv CloneNameList TcTypeEnv))

(defstruct LowerFunctionBodyIndex
  (ids StringI64Map)
  (bodies (Array LowerMaybeFunctionBody))
  (next i64))

(defenum LowerPrunedProgram
  (LowerPrunedProgram AstProgram AstDeclPathList))

(defenum ResultLowerCloneRoots
  (OkLowerCloneRoots CloneNameList)
  (ErrLowerCloneRoots CompilerDiagnostic))

(defenum CompilerLowerMode
  (CompilerLowerScalar)
  (CompilerLowerLinuxScalar)
  (CompilerLowerWindowsScalar)
  (CompilerLowerAvx2)
  (CompilerLowerLinuxAvx2)
  (CompilerLowerWindowsAvx2)
  (CompilerLowerAvx512)
  (CompilerLowerLinuxAvx512)
  (CompilerLowerWindowsAvx512)
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
    LowerTypeCache
    CompilerLowerMode))

(defenum LowerMaybeArrayVar
  (LowerNoArrayVar)
  (LowerSomeArrayVar i64 AstType))

(defenum LowerMaybeVectorMap
  (LowerNoVectorMap)
  (LowerSomeVectorMap i64 i64 i64 CompilerIrBinOp AstType i64))

(defenum LowerMaybeMaskedVectorMap
  (LowerNoMaskedVectorMap)
  (LowerSomeMaskedVectorMap i64))

(defenum LowerMaybeVectorReduce
  (LowerNoVectorReduce)
  (LowerSomeVectorReduce i64 CompilerIrVectorReduceOp AstType i64))

(defenum LowerArrayVarList
  (LowerArrayVarNil)
  (LowerArrayVarCons i64 i64 (Box LowerArrayVarList)))

(defenum LowerCapture
  (LowerCapture String i64 AstType i64))

(defenum LowerCaptureList
  (LowerCaptureNil)
  (LowerCaptureCons LowerCapture (Box LowerCaptureList)))

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

(defenum LowerCAbiAggregate
  (LowerCAbiNoAggregate)
  (LowerCAbiIntegerAggregate AstType i64)
  (LowerCAbiUnsupportedAggregate String))

(defenum ResultLowerState
  (OkLowerState LowerState)
  (ErrLowerState CompilerDiagnostic))

(defenum ResultLowerEnv
  (OkLowerEnv LowerState SymI64Env TcTypeEnv)
  (ErrLowerEnv CompilerDiagnostic))

(defenum ResultLowerModuleLocalEnv
  (OkLowerModuleLocalEnv TcTypeEnv LowerNameEnv)
  (ErrLowerModuleLocalEnv String))

(defenum ResultLowerValue
  (OkLowerValue CompilerIrValue)
  (ErrLowerValue CompilerDiagnostic))

(defenum ResultLowerSize
  (OkLowerSize i64)
  (ErrLowerSize String))

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

(defenum LowerDispatchDecl
  (LowerDispatchDecl
    CompilerIrGlobal
    CompilerIrFunctionList
    CompilerSourceSpans))

(defenum ResultLowerDispatchDecl
  (OkLowerDispatchDecl LowerDispatchDecl)
  (ErrLowerDispatchDecl CompilerDiagnostic))

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

(defenum LowerMaybeStringConcatCall
  (LowerNoStringConcatCall)
  (LowerSomeStringConcatCall AstExpr AstExpr))

(defenum ResultLowerStringValues
  (OkLowerStringValues LowerState CompilerIrValueList i64)
  (ErrLowerStringValues CompilerDiagnostic))

(defenum LowerCleanup
  (LowerCleanup String String))

(defenum LowerCleanupList
  (LowerCleanupNil)
  (LowerCleanupCons LowerCleanup (Box LowerCleanupList)))

(defenum LowerResourceBindings
  (LowerResourceBindings LowerState SymI64Env TcTypeEnv LowerCleanupList))

(defenum ResultLowerResourceBindings
  (OkLowerResourceBindings LowerResourceBindings)
  (ErrLowerResourceBindings CompilerDiagnostic))

(define (lower-diagnostic [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start "" message))

(cfg
  compile-profile
  (define compiler-lower-profile-start-ms : i64
    0))

(cfg
  compile-profile
  (define compiler-lower-profile-start-total : i64
    0))

(cfg
  compile-profile
  (define compiler-lower-profile-start-live : i64
    0))

(cfg
  compile-profile
  (define compiler-lower-profile-detail-start-ms : i64
    0))

(cfg
  compile-profile
  (define (compiler-lower-profile-field [value : i64]) : String
    (string-append "|" (int->string value))))

(cfg
  compile-profile
  (define (compiler-lower-profile-start) : unit
    (begin
      (set! compiler-lower-profile-start-ms (profile-now-ms))
      (set! compiler-lower-profile-start-total (profile-alloc-total))
      (set! compiler-lower-profile-start-live (profile-alloc-live))
      (profile-alloc-reset-peak))))

(cfg
  compile-profile
  (define (compiler-lower-profile-finish [phase : String]) : unit
    (let
      [end-ms : i64 (profile-now-ms)]
      [end-total : i64 (profile-alloc-total)]
      [end-live : i64 (profile-alloc-live)]
      [peak-delta : i64
        (- (profile-alloc-peak) compiler-lower-profile-start-live)]
      (print-error
        (string-append
          "compile-profile|lower."
          (string-append
            phase
            (string-append
              (compiler-lower-profile-field
                (- end-ms compiler-lower-profile-start-ms))
              (string-append
                (compiler-lower-profile-field
                  (- end-total compiler-lower-profile-start-total))
                (string-append
                  (compiler-lower-profile-field
                    (- end-live compiler-lower-profile-start-live))
                  (string-append (compiler-lower-profile-field peak-delta) "\n"))))))))))

(cfg
  compile-profile
  (define (compiler-lower-profile-detail-start) : unit
    (set! compiler-lower-profile-detail-start-ms (profile-now-ms))))

(cfg
  compile-profile
  (define (compiler-lower-profile-detail-finish
    [phase : String]
    [name : String]) : unit
    (let
      [elapsed : i64
        (- (profile-now-ms) compiler-lower-profile-detail-start-ms)]
      (if (>= elapsed 1)
        (print-error
          (string-append
            "compile-profile-detail|lower."
            (string-append
              phase
              (string-append
                "|"
                (string-append
                  (int->string elapsed)
                  (string-append "|" (string-append name "\n")))))))
        unit))))

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

(define (lower-instr-list-fill-array-reversed
  [instrs : CompilerIrInstrList]
  [slots : (Array CompilerIrInstr)]
  [index : i64]) : unit
  (match instrs
    [(IrInstrNil) unit]
    [(IrInstrCons head rest)
      (begin
        (array-set! slots index head)
        (lower-instr-list-fill-array-reversed (box-get rest) slots (- index 1)))]))

(define (lower-instr-seq-from-reversed-list [instrs : CompilerIrInstrList]) : CompilerIrInstrSeq
  (let
    [count : i64 (compiler-ir-instr-list-count instrs)]
    [slots : (Array CompilerIrInstr) (make-array CompilerIrInstr count)]
    (begin
      (lower-instr-list-fill-array-reversed instrs slots (- count 1))
      (CompilerIrInstrSeq slots count))))

(define (lower-block-list-reverse-onto
  [blocks : CompilerIrBlockList]
  [acc : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) acc]
    [(IrBlockCons head rest)
      (lower-block-list-reverse-onto
        (box-get rest)
        (compiler-ir-block-cons head acc))]))

(define (lower-block-list-reverse [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (lower-block-list-reverse-onto blocks IrBlockNil))

(define (lower-global-list-reverse-onto
  [globals : CompilerIrGlobalList]
  [acc : CompilerIrGlobalList]) : CompilerIrGlobalList
  (match globals
    [(IrGlobalNil) acc]
    [(IrGlobalCons head rest)
      (lower-global-list-reverse-onto
        (box-get rest)
        (compiler-ir-global-cons head acc))]))

(define (lower-global-list-reverse [globals : CompilerIrGlobalList]) : CompilerIrGlobalList
  (lower-global-list-reverse-onto globals IrGlobalNil))

(define (lower-function-list-reverse-onto
  [functions : CompilerIrFunctionList]
  [acc : CompilerIrFunctionList]) : CompilerIrFunctionList
  (match functions
    [(IrFunctionNil) acc]
    [(IrFunctionCons head rest)
      (lower-function-list-reverse-onto
        (box-get rest)
        (compiler-ir-function-cons head acc))]))

(define (lower-function-list-reverse [functions : CompilerIrFunctionList]) : CompilerIrFunctionList
  (lower-function-list-reverse-onto functions IrFunctionNil))

(define (lower-function-list-append
  [left : CompilerIrFunctionList]
  [right : CompilerIrFunctionList]) : CompilerIrFunctionList
  (match left
    [(IrFunctionNil) right]
    [(IrFunctionCons head rest)
      (compiler-ir-function-cons
        head
        (lower-function-list-append (box-get rest) right))]))

(define (lower-extern-list-reverse-onto
  [externs : CompilerIrExternList]
  [acc : CompilerIrExternList]) : CompilerIrExternList
  (match externs
    [(IrExternNil) acc]
    [(IrExternCons head rest)
      (lower-extern-list-reverse-onto
        (box-get rest)
        (compiler-ir-extern-cons head acc))]))

(define (lower-extern-list-reverse [externs : CompilerIrExternList]) : CompilerIrExternList
  (lower-extern-list-reverse-onto externs IrExternNil))

(define (lower-name-env-lookup [names : LowerNameEnv] [source-name : String]) : TcMaybeString
  (match names
    [(LowerNameNil) (TcNoString)]
    [(LowerNameBind source logical rest)
      (if (string-eq source source-name)
        (TcSomeString logical)
        (lower-name-env-lookup (box-get rest) source-name))]))

(define (lower-name-env-resolve [names : LowerNameEnv] [source-name : String]) : String
  (match (lower-name-env-lookup names source-name)
    [(TcSomeString logical) logical]
    [(TcNoString) source-name]))

(define (lower-name-env-count [names : LowerNameEnv]) : i64
  (match names
    [(LowerNameNil) 0]
    [(LowerNameBind _ _ rest) (+ 1 (lower-name-env-count (box-get rest)))]))

(define (lower-name-cache-capacity [count : i64]) : i64
  (if (< count 4)
    8
    (* count 2)))

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
            (LowerNameCache (string-i64-map-put ids source-name next) values)))])))

(define (lower-name-cache-from-env-into
  [names : LowerNameEnv]
  [cache : LowerNameCache]) : LowerNameCache
  (match names
    [(LowerNameNil) cache]
    [(LowerNameBind source logical rest)
      (lower-name-cache-from-env-into
        (box-get rest)
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

(define (lower-type-env-count [env : TcTypeEnv]) : i64
  (match env
    [(TcTypeNil) 0]
    [(TcTypeCache _ _ _ _ rest) (lower-type-env-count (box-get rest))]
    [(TcTypeBind _ _ rest) (+ 1 (lower-type-env-count (box-get rest)))]))

(define (lower-type-cache-capacity [count : i64]) : i64
  (if (< count 4)
    8
    (* count 2)))

(define (lower-type-cache-add
  [cache : LowerTypeCache]
  [name : String]
  [ty : AstType]) : LowerTypeCache
  (match cache
    [(LowerNoTypeCache) cache]
    [(LowerSomeTypeCache ids values next)
      (match (string-i64-map-get ids name)
        [(StringI64MapFound _) cache]
        [(StringI64MapMissing)
          (begin
            (array-set! values next ty)
            (LowerSomeTypeCache
              (string-i64-map-put ids name next)
              values
              (+ next 1)))])]))

(define (lower-type-cache-from-env-into
  [env : TcTypeEnv]
  [cache : LowerTypeCache]) : LowerTypeCache
  (match env
    [(TcTypeNil) cache]
    [(TcTypeCache _ _ _ _ rest)
      (lower-type-cache-from-env-into (box-get rest) cache)]
    [(TcTypeBind name-id ty rest)
      (lower-type-cache-from-env-into
        (box-get rest)
        (lower-type-cache-add cache (intern-str name-id) ty))]))

(define (lower-type-cache-from-env [env : TcTypeEnv]) : LowerTypeCache
  (let
    [count : i64 (lower-type-env-count env)]
    (lower-type-cache-from-env-into
      env
      (LowerSomeTypeCache
        (string-i64-map-with-capacity (lower-type-cache-capacity count))
        (make-array AstType count)
        0))))

(define (lower-type-cache-lookup [cache : LowerTypeCache] [name : String]) : ResultTcType
  (match cache
    [(LowerNoTypeCache)
      (ErrTcType (string-append "typecheck: unbound name " name))]
    [(LowerSomeTypeCache ids values _)
      (match (string-i64-map-get ids name)
        [(StringI64MapFound index) (OkTcType (array-ref values index))]
        [(StringI64MapMissing)
          (ErrTcType (string-append "typecheck: unbound name " name))])]))

(define (lower-hygiene-source-name [name : String]) : String
  (if (tc-hygiene-global-name? name)
    (tc-hygiene-global-base name)
    name))

(define (lower-lookup-type
  [type-cache : LowerTypeCache]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]) : ResultTcType
  (if (tc-hygiene-global-name? name)
    (lower-type-cache-lookup type-cache (tc-hygiene-global-base name))
    (match (sym-i64-lookup env name)
      [(SomeI64 _) (tc-lookup type-env name)]
      [(NoneI64)
        (match (tc-lookup type-env name)
          [(OkTcType ty) (OkTcType ty)]
          [(ErrTcType _) (lower-type-cache-lookup type-cache name)])])))

(define (lower-lookup-type-id
  [type-cache : LowerTypeCache]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name-id : i64]) : ResultTcType
  (let
    [name : String (intern-str name-id)]
    (if (tc-hygiene-global-name? name)
      (lower-type-cache-lookup type-cache (tc-hygiene-global-base name))
      (match (sym-i64-lookup-id env name-id)
        [(SomeI64 _) (tc-lookup-id type-env name-id)]
        [(NoneI64) (lower-lookup-type type-cache env type-env name)]))))

(define (lower-name-env-add-alias-if-free
  [names : LowerNameEnv]
  [source-name : String]
  [logical-name : String]) : LowerNameEnv
  (match (lower-name-env-lookup names source-name)
    [(TcSomeString _) names]
    [(TcNoString) (LowerNameBind source-name logical-name (box names))]))

(define (lower-name-env-add-module-binding
  [names : LowerNameEnv]
  [module : String]
  [source-name : String]
  [logical-name : String]) : LowerNameEnv
  (if (string-eq module "")
    (LowerNameBind source-name logical-name (box names))
    (LowerNameBind
      (compiler-symbol-module-key module source-name)
      logical-name
      (box names))))

(define (lower-name-env-add-struct-cleanup-in-module
  [names : LowerNameEnv]
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [cleanup : AstStructCleanup]) : LowerNameEnv
  (match cleanup
    [(AstStructNoCleanup) names]
    [(AstStructCleanupFn cleanup-name)
      (lower-name-env-add-module-binding
        names
        module
        cleanup-name
        (lower-decl-logical-name entry-path decl-path module cleanup-name))]))

(define (lower-name-env-add-enum-cleanup-in-module
  [names : LowerNameEnv]
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [cleanup : AstEnumCleanup]) : LowerNameEnv
  (match cleanup
    [(AstEnumNoCleanup) names]
    [(AstEnumCleanupFn cleanup-name)
      (lower-name-env-add-module-binding
        names
        module
        cleanup-name
        (lower-decl-logical-name entry-path decl-path module cleanup-name))]))

(define (lower-name-env-add-local-struct-cleanup
  [names : LowerNameEnv]
  [name-cache : LowerNameCache]
  [module : String]
  [cleanup : AstStructCleanup]) : LowerNameEnv
  (match cleanup
    [(AstStructNoCleanup) names]
    [(AstStructCleanupFn cleanup-name)
      (LowerNameBind
        cleanup-name
        (lower-current-decl-logical-name-cache name-cache module cleanup-name)
        (box names))]))

(define (lower-name-env-add-local-enum-cleanup
  [names : LowerNameEnv]
  [name-cache : LowerNameCache]
  [module : String]
  [cleanup : AstEnumCleanup]) : LowerNameEnv
  (match cleanup
    [(AstEnumNoCleanup) names]
    [(AstEnumCleanupFn cleanup-name)
      (LowerNameBind
        cleanup-name
        (lower-current-decl-logical-name-cache name-cache module cleanup-name)
        (box names))]))

(define (lower-name-has-clone-prefix? [name : String]) : bool
  (if (>= (string-length name) 6)
    (string-eq (substring name 0 6) "clone$")
    false))

(define (lower-resolve-name [state : LowerState] [source-name : String]) : String
  (lower-name-cache-resolve
    (lower-state-names state)
    (lower-hygiene-source-name source-name)))

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

(define (lower-dispatch-source-name [module : String] [name : String]) : String
  (if (and (> (string-length module) 0) (not (tc-name-qualified? name)))
    (compiler-symbol-module-key module name)
    name))

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

(define (lower-current-decl-logical-name-cache
  [names : LowerNameCache]
  [module : String]
  [source-name : String]) : String
  (let
    [key : String (compiler-symbol-module-key module source-name)]
    [resolved : String (lower-name-cache-resolve names key)]
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
    [(AstDeclDefFn name _ _ _ _)
      (lower-name-env-add-module-binding
        names
        module
        name
        (lower-decl-logical-name entry-path decl-path module name))]
    [(AstDeclDefDispatch name _)
      (lower-name-env-add-module-binding
        names
        module
        name
        (lower-decl-logical-name entry-path decl-path module name))]
    [(AstDeclExtern name _ _)
      ;; Calls resolve through the local declaration name; backend metadata owns
      ;; the exact external linker symbol.
      (lower-name-env-add-module-binding names module name name)]
    [(AstDeclDefEnum _ cleanup _)
      (lower-name-env-add-enum-cleanup-in-module
        names
        entry-path
        decl-path
        module
        cleanup)]
    [(AstDeclDefEnumLifetimes _ _ cleanup _)
      (lower-name-env-add-enum-cleanup-in-module
        names
        entry-path
        decl-path
        module
        cleanup)]
    [(AstDeclDefStruct _ _ cleanup _)
      (lower-name-env-add-struct-cleanup-in-module
        names
        entry-path
        decl-path
        module
        cleanup)]
    [(AstDeclDefStructLifetimes _ _ _ cleanup _)
      (lower-name-env-add-struct-cleanup-in-module
        names
        entry-path
        decl-path
        module
        cleanup)]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (lower-name-env-add-decl-in-module
          names
          entry-path
          decl-path
          module
          inner))]
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
        [rest : AstDeclList (box-get rest)]
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) entry-path])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest)
              (let
                [path-rest : AstDeclPathList (box-get path-rest)]
                path-rest)]
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

(define (lower-name-env-add-clone-decl-in-module
  [names : LowerNameEnv]
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [decl : AstDecl]) : LowerNameEnv
  (match decl
    [(AstDeclDefFn name _ _ _ _)
      (if (lower-name-has-clone-prefix? name)
        (lower-name-env-add-module-binding
          names
          module
          name
          (lower-decl-logical-name entry-path decl-path module name))
        names)]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (lower-name-env-add-clone-decl-in-module
          names
          entry-path
          decl-path
          module
          inner))]
    [_ names]))

(define (lower-name-env-add-clone-decls-in-module
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [names : LowerNameEnv]
  [module : String]) : LowerNameEnv
  (match decls
    [(AstDeclNil) names]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) entry-path])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest)
              (let
                [path-rest : AstDeclPathList (box-get path-rest)]
                path-rest)]
            [(AstDeclPathNil) AstDeclPathNil])]
        (match decl
          [(AstDeclModule next-module)
            (lower-name-env-add-clone-decls-in-module
              rest
              rest-paths
              entry-path
              names
              next-module)]
          [_
            (lower-name-env-add-clone-decls-in-module
              rest
              rest-paths
              entry-path
              (lower-name-env-add-clone-decl-in-module
                names
                entry-path
                decl-path
                module
                decl)
              module)]))]))

(define (lower-name-env-add-clone-decls
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [names : LowerNameEnv]) : LowerNameEnv
  (lower-name-env-add-clone-decls-in-module decls paths entry-path names ""))

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
        (box names))]
    [(AstDeclDefFn name _ _ _ _)
      (LowerNameBind
        (compiler-symbol-module-key alias name)
        (lower-alias-logical-name entry-path decl-path module name path-aware)
        (box names))]
    [(AstDeclDefDispatch name _)
      (LowerNameBind
        (compiler-symbol-module-key alias name)
        (lower-alias-logical-name entry-path decl-path module name path-aware)
        (box names))]
    [(AstDeclExtern name _ _)
      (LowerNameBind (compiler-symbol-module-key alias name) name (box names))]
    [(AstDeclDefStruct _ _ cleanup _)
      (match cleanup
        [(AstStructNoCleanup) names]
        [(AstStructCleanupFn cleanup-name)
          (LowerNameBind
            (compiler-symbol-module-key alias cleanup-name)
            (lower-alias-logical-name
              entry-path
              decl-path
              module
              cleanup-name
              path-aware)
            (box names))])]
    [(AstDeclDefStructLifetimes _ _ _ cleanup _)
      (match cleanup
        [(AstStructNoCleanup) names]
        [(AstStructCleanupFn cleanup-name)
          (LowerNameBind
            (compiler-symbol-module-key alias cleanup-name)
            (lower-alias-logical-name
              entry-path
              decl-path
              module
              cleanup-name
              path-aware)
            (box names))])]
    [(AstDeclComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (lower-name-env-add-decl-alias-in-module
          names
          entry-path
          decl-path
          alias
          module
          template
          path-aware))]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (lower-name-env-add-decl-alias-in-module
          names
          entry-path
          decl-path
          alias
          module
          inner
          path-aware))]
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
        [rest : AstDeclList (box-get rest)]
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) entry-path])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest)
              (let
                [path-rest : AstDeclPathList (box-get path-rest)]
                path-rest)]
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
          [(AstDeclIncludeStr _ _)
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
        [rest : AstDeclList (box-get rest)]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest)
              (let
                [path-rest : AstDeclPathList (box-get path-rest)]
                path-rest)]
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
  [name-cache : LowerNameCache]
  [module : String]
  [decl : AstDecl]) : LowerNameEnv
  (match decl
    [(AstDeclDef name _ _)
      (LowerNameBind
        name
        (lower-current-decl-logical-name-cache name-cache module name)
        (box names))]
    [(AstDeclDefFn name _ _ _ _)
      (LowerNameBind
        name
        (lower-current-decl-logical-name-cache name-cache module name)
        (box names))]
    [(AstDeclDefDispatch name _)
      (LowerNameBind
        name
        (lower-current-decl-logical-name names module name)
        (box names))]
    [(AstDeclExtern name _ _)
      (LowerNameBind
        name
        (lower-current-decl-logical-name-cache name-cache module name)
        (box names))]
    [(AstDeclDefEnum _ cleanup _)
      (lower-name-env-add-local-enum-cleanup names name-cache module cleanup)]
    [(AstDeclDefEnumLifetimes _ _ cleanup _)
      (lower-name-env-add-local-enum-cleanup names name-cache module cleanup)]
    [(AstDeclDefStruct _ _ cleanup _)
      (lower-name-env-add-local-struct-cleanup names name-cache module cleanup)]
    [(AstDeclDefStructLifetimes _ _ _ cleanup _)
      (lower-name-env-add-local-struct-cleanup names name-cache module cleanup)]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (lower-name-env-add-local-decl names name-cache module inner))]
    [_ names]))

(define (lower-module-local-type-env-bind-qualified
  [top-env : TcTypeEnv]
  [env : TcTypeEnv]
  [module : String]
  [name : String]) : ResultTcEnv
  (match (tc-lookup top-env (compiler-symbol-module-key module name))
    [(OkTcType ty) (OkTcEnv (tc-bind env name ty))]
    [(ErrTcType message) (ErrTcEnv message)]))

(define (lower-module-local-type-env-add-variants
  [top-env : TcTypeEnv]
  [env : TcTypeEnv]
  [module : String]
  [variants : AstVariantDefList]) : ResultTcEnv
  (match variants
    [(AstVariantDefNil) (OkTcEnv env)]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef name _ _)
            (match (lower-module-local-type-env-bind-qualified
              top-env
              env
              module
              name)
              [(OkTcEnv next-env)
                (lower-module-local-type-env-add-variants
                  top-env
                  next-env
                  module
                  rest)]
              [(ErrTcEnv message) (ErrTcEnv message)])]))]))

(define (lower-module-local-type-env-add-decl
  [top-env : TcTypeEnv]
  [env : TcTypeEnv]
  [module : String]
  [decl : AstDecl]) : ResultTcEnv
  (match decl
    [(AstDeclDef name _ _)
      (lower-module-local-type-env-bind-qualified top-env env module name)]
    [(AstDeclDefFn name _ _ _ _)
      (lower-module-local-type-env-bind-qualified top-env env module name)]
    [(AstDeclDefDispatch name _)
      (lower-module-local-type-env-bind-qualified top-env env module name)]
    [(AstDeclExtern name _ _)
      (lower-module-local-type-env-bind-qualified top-env env module name)]
    [(AstDeclDefEnum _ cleanup variants)
      (match (lower-module-local-type-env-add-variants
        top-env
        env
        module
        variants)
        [(OkTcEnv next-env)
          (match cleanup
            [(AstEnumNoCleanup) (OkTcEnv next-env)]
            [(AstEnumCleanupFn cleanup-name)
              (lower-module-local-type-env-bind-qualified
                top-env
                next-env
                module
                cleanup-name)])]
        [(ErrTcEnv message) (ErrTcEnv message)])]
    [(AstDeclDefEnumLifetimes _ _ cleanup variants)
      (match (lower-module-local-type-env-add-variants
        top-env
        env
        module
        variants)
        [(OkTcEnv next-env)
          (match cleanup
            [(AstEnumNoCleanup) (OkTcEnv next-env)]
            [(AstEnumCleanupFn cleanup-name)
              (lower-module-local-type-env-bind-qualified
                top-env
                next-env
                module
                cleanup-name)])]
        [(ErrTcEnv message) (ErrTcEnv message)])]
    [(AstDeclDefStruct name _ cleanup _)
      (match (lower-module-local-type-env-bind-qualified
        top-env
        env
        module
        name)
        [(OkTcEnv next-env)
          (match cleanup
            [(AstStructNoCleanup) (OkTcEnv next-env)]
            [(AstStructCleanupFn cleanup-name)
              (lower-module-local-type-env-bind-qualified
                top-env
                next-env
                module
                cleanup-name)])]
        [(ErrTcEnv message) (ErrTcEnv message)])]
    [(AstDeclDefStructLifetimes name _ _ cleanup _)
      (match (lower-module-local-type-env-bind-qualified
        top-env
        env
        module
        name)
        [(OkTcEnv next-env)
          (match cleanup
            [(AstStructNoCleanup) (OkTcEnv next-env)]
            [(AstStructCleanupFn cleanup-name)
              (lower-module-local-type-env-bind-qualified
                top-env
                next-env
                module
                cleanup-name)])]
        [(ErrTcEnv message) (ErrTcEnv message)])]
    [(AstDeclComptimeDecl _ template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (lower-module-local-type-env-add-decl top-env env module template))]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (lower-module-local-type-env-add-decl top-env env module inner))]
    [_ (OkTcEnv env)]))

(define (lower-module-local-envs-list
  [top-env : TcTypeEnv]
  [decls : AstDeclList]
  [type-env : TcTypeEnv]
  [names : LowerNameEnv]
  [name-cache : LowerNameCache]
  [target-module : String]
  [module : String]) : ResultLowerModuleLocalEnv
  (match decls
    [(AstDeclNil) (OkLowerModuleLocalEnv type-env names)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule next-module)
            (lower-module-local-envs-list
              top-env
              rest
              type-env
              names
              name-cache
              target-module
              next-module)]
          [_
            (if (string-eq module target-module)
              (match (lower-module-local-type-env-add-decl
                top-env
                type-env
                target-module
                decl)
                [(OkTcEnv next-type-env)
                  (lower-module-local-envs-list
                    top-env
                    rest
                    next-type-env
                    (lower-name-env-add-local-decl
                      names
                      name-cache
                      target-module
                      decl)
                    name-cache
                    target-module
                    module)]
                [(ErrTcEnv message) (ErrLowerModuleLocalEnv message)])
              (lower-module-local-envs-list
                top-env
                rest
                type-env
                names
                name-cache
                target-module
                module))]))]))

(define (lower-module-local-envs
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [names : LowerNameEnv]
  [module : String]) : ResultLowerModuleLocalEnv
  (if (string-eq module "")
    (OkLowerModuleLocalEnv top-env names)
    (match (tc-context-program ctx)
      [(AstProgram decls-box)
        (let
          [decls : AstDeclList (box-get decls-box)]
          (lower-module-local-envs-list
            top-env
            decls
            top-env
            names
            (lower-name-cache-from-env names)
            module
            ""))])))

(define (lower-string-set-contains? [items : LowerStringSet] [name : String]) : bool
  (match items
    [(LowerStringNil) false]
    [(LowerStringCons item rest)
      (if (string-eq item name)
        true
        (lower-string-set-contains? (box-get rest) name))]))

(define (lower-string-set-insert [items : LowerStringSet] [name : String]) : LowerStringSet
  (if (lower-string-set-contains? items name)
    items
    (LowerStringCons name (box items))))

(define (lower-function-logical-name-from-decl
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [decl : AstDecl]) : TcMaybeString
  (match decl
    [(AstDeclDefFn name _ _ _ _)
      (TcSomeString (lower-decl-logical-name entry-path decl-path module name))]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (lower-function-logical-name-from-decl
          entry-path
          decl-path
          module
          inner))]
    [_ (TcNoString)]))

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
        [rest : AstDeclList (box-get rest)]
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) entry-path])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest)
              (let
                [path-rest : AstDeclPathList (box-get path-rest)]
                path-rest)]
            [(AstDeclPathNil) AstDeclPathNil])]
        (match decl
          [(AstDeclModule next-module)
            (lower-function-set-from-decls-in-module
              rest
              rest-paths
              entry-path
              next-module
              out)]
          [_
            (lower-function-set-from-decls-in-module
              rest
              rest-paths
              entry-path
              module
              (match (lower-function-logical-name-from-decl
                entry-path
                decl-path
                module
                decl)
                [(TcSomeString logical-name)
                  (string-i64-map-put out logical-name 1)]
                [(TcNoString) out]))]))]))

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

(define (lower-clone-root-add-type-list
  [ctx : TcContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [types : AstTypeList]) : CloneNameList
  (match types
    [(AstTypeNil) roots]
    [(AstTypeCons head rest)
      (let
        [head : AstType (ty-node-get head)]
        [rest : AstTypeList (box-get rest)]
        (lower-clone-root-add-type-list
          ctx
          decls
          able
          (lower-clone-root-add-type ctx decls able roots head)
          rest))]))

(define (lower-clone-root-add-field-list
  [ctx : TcContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [fields : AstFieldDefList]) : CloneNameList
  (match fields
    [(AstFieldDefNil) roots]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef _ ty _)
            (lower-clone-root-add-field-list
              ctx
              decls
              able
              (lower-clone-root-add-type ctx decls able roots ty)
              rest)]))]))

(define (lower-clone-root-add-variant-list
  [ctx : TcContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [variants : AstVariantDefList]) : CloneNameList
  (match variants
    [(AstVariantDefNil) roots]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef _ fields _)
            (lower-clone-root-add-variant-list
              ctx
              decls
              able
              (lower-clone-root-add-type-list ctx decls able roots fields)
              rest)]))]))

(define (lower-clone-root-add-named-deps
  [ctx : TcContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [name : String]) : CloneNameList
  (match decls
    [(AstDeclNil) roots]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclDefEnum decl-name _ variants)
            (if (string-eq decl-name name)
              (lower-clone-root-add-variant-list ctx decls able roots variants)
              (lower-clone-root-add-named-deps ctx rest able roots name))]
          [(AstDeclDefStruct decl-name _ _ fields)
            (if (string-eq decl-name name)
              (lower-clone-root-add-field-list ctx decls able roots fields)
              (lower-clone-root-add-named-deps ctx rest able roots name))]
          [_ (lower-clone-root-add-named-deps ctx rest able roots name)]))]))

(define (lower-clone-root-add-named
  [ctx : TcContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [name : String]) : CloneNameList
  (let
    [helper-name : String (tc-qualified-name-base name)]
    (if (clone-name-set-contains? able helper-name)
      (if (clone-name-list-contains? roots helper-name)
        roots
        (lower-clone-root-add-named-deps
          ctx
          decls
          able
          (CloneNameCons helper-name (box roots))
          helper-name))
      roots)))

(define (lower-clone-root-add-type
  [ctx : TcContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [ty : AstType]) : CloneNameList
  (let
    [resolved : AstType (tc-type-without-regions (tc-resolve-type ctx ty))]
    (match resolved
      [(AstTyTuple elems)
        (lower-clone-root-add-type-list ctx decls able roots elems)]
      [(AstTyArray elem _)
        (lower-clone-root-add-type ctx decls able roots (ty-node-get elem))]
      [(AstTyDynArray elem)
        (lower-clone-root-add-type ctx decls able roots (ty-node-get elem))]
      [(AstTyBox elem)
        (lower-clone-root-add-type ctx decls able roots (ty-node-get elem))]
      [(AstTyEnum name) (lower-clone-root-add-named ctx decls able roots name)]
      [(AstTyStruct name)
        (lower-clone-root-add-named ctx decls able roots name)]
      [(AstTyVar name) (lower-clone-root-add-named ctx decls able roots name)]
      [_ roots])))

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
            (LowerStringCons logical-name (box worklist))))
        state)]))

(define (lower-reach-add-source
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [source-name : String])
  :
  LowerReachState
  ;; References introduced by macro expansion carry the hygiene-global prefix
  ;; (e.g. `__tl_macro_global$string-append`); strip it before resolving so the
  ;; underlying function counts as reachable. Otherwise a function called only
  ;; from a macro expansion is pruned, then fails to resolve during lowering.
  (lower-reach-add-logical
    all-functions
    state
    (lower-name-cache-resolve names (lower-hygiene-source-name source-name))))

(define (lower-reach-expr-list
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [exprs : AstExprList]) : LowerReachState
  (match exprs
    [(AstExprNil) state]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (ast-node-get expr)]
        [rest : AstExprList (box-get rest)]
        (lower-reach-expr-list
          all-functions
          names
          (lower-reach-expr all-functions names state expr)
          rest))]))

(define (lower-reach-let-bindings
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [bindings : AstLetBindingList]) : LowerReachState
  (match bindings
    [(AstLetBindingNil) state]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding _ _ value-box)
            (let
              [value : AstExpr (ast-node-get value-box)]
              (lower-reach-let-bindings
                all-functions
                names
                (lower-reach-expr all-functions names state value)
                rest))]))]))

(define (lower-reach-match-arms
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [arms : AstMatchArmList]) : LowerReachState
  (match arms
    [(AstMatchArmNil) state]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm _ body-box)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (lower-reach-match-arms
                all-functions
                names
                (lower-reach-expr all-functions names state body)
                rest))]))]))

(define (lower-reach-resource-bindings
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [bindings : AstResourceBindingList]) : LowerReachState
  (match bindings
    [(AstResourceBindingNil) state]
    [(AstResourceBindingCons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding _ acquire-box cleanup-box)
            (let
              [acquire : AstExpr (ast-node-get acquire-box)]
              [cleanup : AstExpr (ast-node-get cleanup-box)]
              (lower-reach-resource-bindings
                all-functions
                names
                (lower-reach-expr
                  all-functions
                  names
                  (lower-reach-expr all-functions names state acquire)
                  cleanup)
                rest))]))]))

(define (lower-clone-roots-expr-list
  [ctx : TcContext]
  [env : TcTypeEnv]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [exprs : AstExprList]) : CloneNameList
  (match exprs
    [(AstExprNil) roots]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (ast-node-get expr)]
        [rest : AstExprList (box-get rest)]
        (lower-clone-roots-expr-list
          ctx
          env
          decls
          able
          (lower-clone-roots-expr ctx env decls able roots expr)
          rest))]))

(define (lower-clone-roots-bind-let
  [ctx : TcContext]
  [env : TcTypeEnv]
  [name : String]
  [maybe-ty : AstMaybeType]
  [init : AstExpr]) : TcTypeEnv
  (match maybe-ty
    [(AstSomeType want) (tc-bind env name (tc-resolve-type ctx want))]
    [(AstNoType)
      (match (tc-expr ctx env init)
        [(OkTcType init-ty) (tc-bind env name init-ty)]
        [(ErrTcType _) env])]))

(define (lower-clone-roots-let-bindings
  [ctx : TcContext]
  [env : TcTypeEnv]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [bindings : AstLetBindingList]) : LowerCloneRootEnv
  (match bindings
    [(AstLetBindingNil) (LowerCloneRootEnv roots env)]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name maybe-ty init-box)
            (let
              [init : AstExpr (ast-node-get init-box)]
              [next-roots : CloneNameList
                (lower-clone-roots-expr ctx env decls able roots init)]
              [next-env : TcTypeEnv
                (lower-clone-roots-bind-let ctx env name maybe-ty init)]
              (lower-clone-roots-let-bindings
                ctx
                next-env
                decls
                able
                next-roots
                rest))]))]))

(define (lower-clone-roots-match-arms
  [ctx : TcContext]
  [env : TcTypeEnv]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]) : CloneNameList
  (match arms
    [(AstMatchArmNil) roots]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pattern body-box)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [arm-env : TcTypeEnv
                (match (tc-bind-match-pattern ctx env scrut-ty pattern)
                  [(OkTcEnv next-env) next-env]
                  [(ErrTcEnv _) env])]
              (lower-clone-roots-match-arms
                ctx
                env
                decls
                able
                (lower-clone-roots-expr ctx arm-env decls able roots body)
                scrut-ty
                rest))]))]))

(define (lower-clone-roots-resource-bindings
  [ctx : TcContext]
  [env : TcTypeEnv]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [bindings : AstResourceBindingList]) : CloneNameList
  (match bindings
    [(AstResourceBindingNil) roots]
    [(AstResourceBindingCons binding rest)
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding _ acquire-box cleanup-box)
            (let
              [acquire : AstExpr (ast-node-get acquire-box)]
              [cleanup : AstExpr (ast-node-get cleanup-box)]
              (lower-clone-roots-resource-bindings
                ctx
                env
                decls
                able
                (lower-clone-roots-expr
                  ctx
                  env
                  decls
                  able
                  (lower-clone-roots-expr ctx env decls able roots acquire)
                  cleanup)
                rest))]))]))

(define (lower-clone-roots-call
  [ctx : TcContext]
  [env : TcTypeEnv]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [callee : AstExpr]
  [args : AstExprList]) : CloneNameList
  (let
    [walked : CloneNameList
      (lower-clone-roots-expr-list
        ctx
        env
        decls
        able
        (lower-clone-roots-expr ctx env decls able roots callee)
        args)]
    (match (ast-expr-unspan callee)
      [(AstExprVar name)
        (if (and
          (string-eq (intern-str name) "clone")
          (not (tc-name-bound? env (intern-str name))))
          (match args
            [(AstExprCons arg rest)
              (let
                [arg : AstExpr (ast-node-get arg)]
                [rest : AstExprList (box-get rest)]
                (match rest
                  [(AstExprNil)
                    (match (tc-expr ctx env arg)
                      [(OkTcType arg-ty)
                        (lower-clone-root-add-type ctx decls able walked arg-ty)]
                      [(ErrTcType _) walked])]
                  [_ walked]))]
            [_ walked])
          walked)]
      [_ walked])))

(define (lower-clone-roots-expr
  [ctx : TcContext]
  [env : TcTypeEnv]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [expr : AstExpr]) : CloneNameList
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-clone-roots-expr ctx env decls able roots inner))]
    [(AstExprLiteral _) roots]
    [(AstExprVar _) roots]
    [(AstExprBinary _ lhs-box rhs-box)
      (let
        [lhs : AstExpr (ast-node-get lhs-box)]
        [rhs : AstExpr (ast-node-get rhs-box)]
        (lower-clone-roots-expr
          ctx
          env
          decls
          able
          (lower-clone-roots-expr ctx env decls able roots lhs)
          rhs))]
    [(AstExprUnary _ inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-clone-roots-expr ctx env decls able roots inner))]
    [(AstExprCall callee-box args)
      (let
        [callee : AstExpr (ast-node-get callee-box)]
        (lower-clone-roots-call ctx env decls able roots callee args))]
    [(AstExprIf cond-box then-box else-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-expr : AstExpr (ast-node-get then-box)]
        [else-expr : AstExpr (ast-node-get else-box)]
        (lower-clone-roots-expr
          ctx
          env
          decls
          able
          (lower-clone-roots-expr
            ctx
            env
            decls
            able
            (lower-clone-roots-expr ctx env decls able roots cond)
            then-expr)
          else-expr))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (lower-clone-roots-let-bindings
          ctx
          env
          decls
          able
          roots
          bindings)
          [(LowerCloneRootEnv binding-roots body-env)
            (lower-clone-roots-expr ctx body-env decls able binding-roots body)]))]
    [(AstExprLambda params _ body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lower-clone-roots-expr
          ctx
          (tc-bind-params ctx env params)
          decls
          able
          roots
          body))]
    [(AstExprTuple values)
      (lower-clone-roots-expr-list ctx env decls able roots values)]
    [(AstExprTupleRef value-box _)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (lower-clone-roots-expr ctx env decls able roots value))]
    [(AstExprArray values)
      (lower-clone-roots-expr-list ctx env decls able roots values)]
    [(AstExprMakeArray _ len-box)
      (let
        [len : AstExpr (ast-node-get len-box)]
        (lower-clone-roots-expr ctx env decls able roots len))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        (lower-clone-roots-expr
          ctx
          env
          decls
          able
          (lower-clone-roots-expr ctx env decls able roots array)
          index))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lower-clone-roots-expr
          ctx
          env
          decls
          able
          (lower-clone-roots-expr
            ctx
            env
            decls
            able
            (lower-clone-roots-expr ctx env decls able roots array)
            index)
          value))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lower-clone-roots-expr
          ctx
          env
          decls
          able
          (lower-clone-roots-expr ctx env decls able roots array)
          value))]
    [(AstExprStringRef text-box index-box)
      (let
        [text : AstExpr (ast-node-get text-box)]
        [index : AstExpr (ast-node-get index-box)]
        (lower-clone-roots-expr
          ctx
          env
          decls
          able
          (lower-clone-roots-expr ctx env decls able roots text)
          index))]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [body : AstExpr (ast-node-get body-box)]
        (lower-clone-roots-expr
          ctx
          env
          decls
          able
          (lower-clone-roots-expr ctx env decls able roots cond)
          body))]
    [(AstExprBegin exprs)
      (lower-clone-roots-expr-list ctx env decls able roots exprs)]
    [(AstExprUnsafe exprs)
      (lower-clone-roots-expr-list ctx env decls able roots exprs)]
    [(AstExprSet _ value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (lower-clone-roots-expr ctx env decls able roots value))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-clone-roots-expr ctx env decls able roots inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-clone-roots-expr ctx env decls able roots inner))]
    [(AstExprBorrow _ _ inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-clone-roots-expr ctx env decls able roots inner))]
    [(AstExprMatch value-box arms)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [value-roots : CloneNameList
          (lower-clone-roots-expr ctx env decls able roots value)]
        (match (tc-expr ctx env value)
          [(OkTcType scrut-ty)
            (lower-clone-roots-match-arms
              ctx
              env
              decls
              able
              value-roots
              scrut-ty
              arms)]
          [(ErrTcType _) value-roots]))]
    [(AstExprForeach index index-ty start-box end-box body-box)
      (let
        [start : AstExpr (ast-node-get start-box)]
        [end : AstExpr (ast-node-get end-box)]
        [body : AstExpr (ast-node-get body-box)]
        [body-env : TcTypeEnv
          (tc-bind env index (tc-resolve-type ctx index-ty))]
        (lower-clone-roots-expr
          ctx
          body-env
          decls
          able
          (lower-clone-roots-expr
            ctx
            env
            decls
            able
            (lower-clone-roots-expr ctx env decls able roots start)
            end)
          body))]
    [(AstExprSpmdReduce _ index index-ty start-box end-box init-box value-box)
      (let
        [start : AstExpr (ast-node-get start-box)]
        [end : AstExpr (ast-node-get end-box)]
        [init : AstExpr (ast-node-get init-box)]
        [value : AstExpr (ast-node-get value-box)]
        [value-env : TcTypeEnv
          (tc-bind env index (tc-resolve-type ctx index-ty))]
        (lower-clone-roots-expr
          ctx
          value-env
          decls
          able
          (lower-clone-roots-expr
            ctx
            env
            decls
            able
            (lower-clone-roots-expr
              ctx
              env
              decls
              able
              (lower-clone-roots-expr ctx env decls able roots start)
              end)
            init)
          value))]
    [(AstExprStructGet value-box _)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (lower-clone-roots-expr ctx env decls able roots value))]
    [(AstExprWithRegion region exprs)
      (lower-clone-roots-expr-list
        ctx
        (tc-push-region env region)
        decls
        able
        roots
        exprs)]
    [(AstExprWithEscape scratch-box exprs)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        [walked : CloneNameList
          (lower-clone-roots-expr-list
            ctx
            env
            decls
            able
            (lower-clone-roots-expr ctx env decls able roots scratch)
            exprs)]
        (match (tc-with-escape-expr ctx env scratch exprs)
          [(OkTcType result-ty)
            (lower-clone-root-add-type ctx decls able walked result-ty)]
          [(ErrTcType _) walked]))]
    [(AstExprWithResource bindings body)
      (let
        [binding-roots : CloneNameList
          (lower-clone-roots-resource-bindings
            ctx
            env
            decls
            able
            roots
            bindings)]
        [body-env : TcTypeEnv
          (match (tc-resource-bindings ctx env bindings)
            [(OkTcEnv next-env) next-env]
            [(ErrTcEnv _) env])]
        (lower-clone-roots-expr-list ctx body-env decls able binding-roots body))]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-clone-roots-expr ctx env decls able roots inner))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-clone-roots-expr ctx env decls able roots inner))]
    [(AstExprTypeLiteral _) roots]
    [(AstExprInit _) roots]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-clone-roots-expr ctx env decls able roots inner))]
    [(AstExprQuote _) roots]
    [(AstExprQuasiquote _) roots]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-clone-roots-expr ctx env decls able roots inner))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-clone-roots-expr ctx env decls able roots inner))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-clone-roots-expr ctx env decls able roots inner))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-clone-roots-expr ctx env decls able roots inner))]
    [(AstExprPtrNull _) roots]
    [(AstExprPtrNullCheck value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (lower-clone-roots-expr ctx env decls able roots value))]
    [(AstExprPtrAddrOf _) roots]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (lower-clone-roots-expr ctx env decls able roots ptr))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lower-clone-roots-expr
          ctx
          env
          decls
          able
          (lower-clone-roots-expr ctx env decls able roots ptr)
          value))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [offset : AstExpr (ast-node-get offset-box)]
        (lower-clone-roots-expr
          ctx
          env
          decls
          able
          (lower-clone-roots-expr ctx env decls able roots ptr)
          offset))]
    [(AstExprPtrCast ptr-box _)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (lower-clone-roots-expr ctx env decls able roots ptr))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (lower-clone-roots-expr ctx env decls able roots ptr))]
    [(AstExprIntToPtr value-box _)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (lower-clone-roots-expr ctx env decls able roots value))]
    [(AstExprStringData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-clone-roots-expr ctx env decls able roots inner))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [len : AstExpr (ast-node-get len-box)]
        (lower-clone-roots-expr
          ctx
          env
          decls
          able
          (lower-clone-roots-expr ctx env decls able roots ptr)
          len))]
    [(AstExprArrayData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-clone-roots-expr ctx env decls able roots inner))]
    [(AstExprProgramArgc) roots]
    [(AstExprProgramArgv) roots]
    [(AstExprProgramEnvp) roots]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lower-clone-roots-expr
          ctx
          env
          decls
          able
          (lower-clone-roots-expr ctx env decls able roots leaf)
          subleaf))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lower-clone-roots-expr
          ctx
          env
          decls
          able
          (lower-clone-roots-expr ctx env decls able roots leaf)
          subleaf))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lower-clone-roots-expr
          ctx
          env
          decls
          able
          (lower-clone-roots-expr ctx env decls able roots leaf)
          subleaf))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lower-clone-roots-expr
          ctx
          env
          decls
          able
          (lower-clone-roots-expr ctx env decls able roots leaf)
          subleaf))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (ast-node-get index-box)]
        (lower-clone-roots-expr ctx env decls able roots index))]
    [(AstExprSyscall args)
      (lower-clone-roots-expr-list ctx env decls able roots args)]))

(define (lower-clone-roots-decls-in-module
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [local-env : TcTypeEnv]
  [decls : AstDeclList]
  [all-decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [names : LowerNameEnv]
  [module : String]) : CloneNameList
  (match decls
    [(AstDeclNil) roots]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclUnsafe inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (lower-clone-roots-decls-in-module
                ctx
                top-env
                local-env
                (ast-decl-cons inner rest)
                all-decls
                able
                roots
                names
                module))]
          [(AstDeclDef _ _ expr-box)
            (let
              [expr : AstExpr (ast-node-get expr-box)]
              (lower-clone-roots-decls-in-module
                ctx
                top-env
                local-env
                rest
                all-decls
                able
                (lower-clone-roots-expr
                  (tc-context-with-module ctx module)
                  local-env
                  all-decls
                  able
                  roots
                  expr)
                names
                module))]
          [(AstDeclDefFn _ params ret body-box _)
            (let
              [decl-ctx : TcContext (tc-context-with-module ctx module)]
              [body : AstExpr (ast-node-get body-box)]
              [fn-env : TcTypeEnv
                (tc-bind-return-type
                  (tc-bind-params decl-ctx local-env params)
                  (tc-resolve-type decl-ctx ret))]
              (lower-clone-roots-decls-in-module
                ctx
                top-env
                local-env
                rest
                all-decls
                able
                (lower-clone-roots-expr
                  decl-ctx
                  fn-env
                  all-decls
                  able
                  roots
                  body)
                names
                module))]
          [(AstDeclModule next-module)
            (match (lower-module-local-envs ctx top-env names next-module)
              [(OkLowerModuleLocalEnv next-local-env _)
                (lower-clone-roots-decls-in-module
                  ctx
                  top-env
                  next-local-env
                  rest
                  all-decls
                  able
                  roots
                  names
                  next-module)]
              [(ErrLowerModuleLocalEnv _)
                (lower-clone-roots-decls-in-module
                  ctx
                  top-env
                  top-env
                  rest
                  all-decls
                  able
                  roots
                  names
                  next-module)])]
          [_
            (lower-clone-roots-decls-in-module
              ctx
              top-env
              local-env
              rest
              all-decls
              able
              roots
              names
              module)]))]))

(define (lower-clone-roots-program
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [names : LowerNameEnv]
  [program : AstProgram]) : CloneNameList
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (lower-clone-roots-decls-in-module
          ctx
          top-env
          top-env
          decls
          decls
          (clone-fixpoint
            decls
            (clone-all-type-names decls (clone-name-set-empty)))
          (CloneNameNil)
          names
          ""))]))

(define (lower-reachable-clone-roots
  [program : AstProgram]
  [paths : AstDeclPathList]
  [names : LowerNameEnv]) : ResultLowerCloneRoots
  (match (build-compiler-symbols program)
    [(OkCompilerSymbols symbols)
      (match (build-compiler-registries-with-symbols program symbols)
        [(OkCompilerRegistries registries)
          (let
            [ctx : TcContext (TcContext program symbols registries "")]
            (match (tc-build-top-env ctx program)
              [(OkTcEnv top-env)
                (OkLowerCloneRoots
                  (lower-clone-roots-program ctx top-env names program))]
              [(ErrTcEnv message)
                (ErrLowerCloneRoots (lower-diagnostic message))]))]
        [(ErrCompilerRegistries message)
          (ErrLowerCloneRoots (lower-diagnostic message))])]
    [(ErrCompilerSymbols message)
      (ErrLowerCloneRoots (lower-diagnostic message))]))

(define (lower-reach-call-callee
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [callee : AstExpr]) : LowerReachState
  (match (ast-expr-unspan callee)
    [(AstExprVar name)
      (lower-reach-add-source all-functions names state (intern-str name))]
    [_ (lower-reach-expr all-functions names state callee)]))

(define (lower-reach-expr
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [expr : AstExpr]) : LowerReachState
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-reach-expr all-functions names state inner))]
    [(AstExprLiteral _) state]
    [(AstExprVar name)
      (lower-reach-add-source all-functions names state (intern-str name))]
    [(AstExprBinary _ lhs-box rhs-box)
      (let
        [lhs : AstExpr (ast-node-get lhs-box)]
        [rhs : AstExpr (ast-node-get rhs-box)]
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr all-functions names state lhs)
          rhs))]
    [(AstExprUnary _ inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-reach-expr all-functions names state inner))]
    [(AstExprCall callee-box args)
      (let
        [callee : AstExpr (ast-node-get callee-box)]
        (lower-reach-expr-list
          all-functions
          names
          (lower-reach-call-callee all-functions names state callee)
          args))]
    [(AstExprIf cond-box then-expr-box else-expr-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-expr : AstExpr (ast-node-get then-expr-box)]
        [else-expr : AstExpr (ast-node-get else-expr-box)]
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr
            all-functions
            names
            (lower-reach-expr all-functions names state cond)
            then-expr)
          else-expr))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lower-reach-expr
          all-functions
          names
          (lower-reach-let-bindings all-functions names state bindings)
          body))]
    [(AstExprLambda _ _ body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lower-reach-expr all-functions names state body))]
    [(AstExprTuple values)
      (lower-reach-expr-list all-functions names state values)]
    [(AstExprTupleRef value-box _)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (lower-reach-expr all-functions names state value))]
    [(AstExprArray values)
      (lower-reach-expr-list all-functions names state values)]
    [(AstExprMakeArray _ len-box)
      (let
        [len : AstExpr (ast-node-get len-box)]
        (lower-reach-expr all-functions names state len))]
    [(AstExprArrayRef array-box index-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr all-functions names state array)
          index))]
    [(AstExprArraySet array-box index-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [index : AstExpr (ast-node-get index-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr
            all-functions
            names
            (lower-reach-expr all-functions names state array)
            index)
          value))]
    [(AstExprArrayPush array-box value-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr all-functions names state array)
          value))]
    [(AstExprStringRef text-box index-box)
      (let
        [text : AstExpr (ast-node-get text-box)]
        [index : AstExpr (ast-node-get index-box)]
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr all-functions names state text)
          index))]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [body : AstExpr (ast-node-get body-box)]
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr all-functions names state cond)
          body))]
    [(AstExprBegin exprs)
      (lower-reach-expr-list all-functions names state exprs)]
    [(AstExprUnsafe exprs)
      (lower-reach-expr-list all-functions names state exprs)]
    [(AstExprSet _ value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (lower-reach-expr all-functions names state value))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-reach-expr all-functions names state inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-reach-expr all-functions names state inner))]
    [(AstExprBorrow _ _ inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-reach-expr all-functions names state inner))]
    [(AstExprMatch value-box arms)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (lower-reach-match-arms
          all-functions
          names
          (lower-reach-expr all-functions names state value)
          arms))]
    [(AstExprForeach _ _ source-box init-box body-box)
      (let
        [source : AstExpr (ast-node-get source-box)]
        [init : AstExpr (ast-node-get init-box)]
        [body : AstExpr (ast-node-get body-box)]
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr
            all-functions
            names
            (lower-reach-expr all-functions names state source)
            init)
          body))]
    [(AstExprSpmdReduce _ _ _ source-box init-box map-expr-box reduce-expr-box)
      (let
        [source : AstExpr (ast-node-get source-box)]
        [init : AstExpr (ast-node-get init-box)]
        [map-expr : AstExpr (ast-node-get map-expr-box)]
        [reduce-expr : AstExpr (ast-node-get reduce-expr-box)]
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
          reduce-expr))]
    [(AstExprStructGet value-box _)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (lower-reach-expr all-functions names state value))]
    [(AstExprWithRegion _ exprs)
      (lower-reach-expr-list all-functions names state exprs)]
    [(AstExprWithEscape scratch-box exprs)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        (lower-reach-expr-list
          all-functions
          names
          (lower-reach-expr all-functions names state scratch)
          exprs))]
    [(AstExprWithResource bindings body)
      (lower-reach-expr-list
        all-functions
        names
        (lower-reach-resource-bindings all-functions names state bindings)
        body)]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-reach-expr all-functions names state inner))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-reach-expr all-functions names state inner))]
    [(AstExprTypeLiteral _) state]
    [(AstExprInit _) state]
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-reach-expr all-functions names state inner))]
    [(AstExprQuote _) state]
    [(AstExprQuasiquote _) state]
    [(AstExprUnquote inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-reach-expr all-functions names state inner))]
    [(AstExprUnquoteSplicing inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-reach-expr all-functions names state inner))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-reach-expr all-functions names state inner))]
    [(AstExprReturn inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-reach-expr all-functions names state inner))]
    [(AstExprPtrNull _) state]
    [(AstExprPtrNullCheck value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (lower-reach-expr all-functions names state value))]
    [(AstExprPtrAddrOf _) state]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (lower-reach-expr all-functions names state ptr))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr all-functions names state ptr)
          value))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [offset : AstExpr (ast-node-get offset-box)]
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr all-functions names state ptr)
          offset))]
    [(AstExprPtrCast ptr-box _)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (lower-reach-expr all-functions names state ptr))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (lower-reach-expr all-functions names state ptr))]
    [(AstExprIntToPtr value-box _)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (lower-reach-expr all-functions names state value))]
    [(AstExprStringData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-reach-expr all-functions names state inner))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [len : AstExpr (ast-node-get len-box)]
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr all-functions names state ptr)
          len))]
    [(AstExprArrayData inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-reach-expr all-functions names state inner))]
    [(AstExprProgramArgc) state]
    [(AstExprProgramArgv) state]
    [(AstExprProgramEnvp) state]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr all-functions names state leaf)
          subleaf))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr all-functions names state leaf)
          subleaf))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr all-functions names state leaf)
          subleaf))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lower-reach-expr
          all-functions
          names
          (lower-reach-expr all-functions names state leaf)
          subleaf))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (ast-node-get index-box)]
        (lower-reach-expr all-functions names state index))]
    [(AstExprSyscall args)
      (lower-reach-expr-list all-functions names state args)]))

(define (lower-reach-global-decl
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [decl : AstDecl]) : LowerReachState
  (match decl
    [(AstDeclDef _ _ expr-box)
      (let
        [expr : AstExpr (ast-node-get expr-box)]
        (lower-reach-expr all-functions names state expr))]
    [(AstDeclComptimeDecl _ inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (lower-reach-global-decl all-functions names state inner))]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (lower-reach-global-decl all-functions names state inner))]
    [_ state]))

(define (lower-reach-global-decls
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [state : LowerReachState]
  [decls : AstDeclList]) : LowerReachState
  (match decls
    [(AstDeclNil) state]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclDef _ _ expr-box)
            (let
              [expr : AstExpr (ast-node-get expr-box)]
              (lower-reach-global-decls
                all-functions
                names
                (lower-reach-expr all-functions names state expr)
                rest))]
          [(AstDeclComptimeDecl _ inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (lower-reach-global-decls
                all-functions
                names
                (match inner
                  [(AstDeclDef _ _ expr-box)
                    (let
                      [expr : AstExpr (ast-node-get expr-box)]
                      (lower-reach-expr all-functions names state expr))]
                  [_ state])
                rest))]
          [_ (lower-reach-global-decls all-functions names state rest)]))]))

(define (lower-function-body-index-empty [count : i64]) : LowerFunctionBodyIndex
  (LowerFunctionBodyIndex
    (string-i64-map-with-capacity 8192)
    (make-array LowerMaybeFunctionBody count)
    0))

(define (lower-function-decl-count [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclDefFn _ _ _ _ _) (+ 1 (lower-function-decl-count rest))]
          [(AstDeclComptimeDecl _ inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (match inner
                [(AstDeclDefFn _ _ _ _ _)
                  (+ 1 (lower-function-decl-count rest))]
                [_ (lower-function-decl-count rest)]))]
          [(AstDeclUnsafe inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (match inner
                [(AstDeclDefFn _ _ _ _ _)
                  (+ 1 (lower-function-decl-count rest))]
                [(AstDeclComptimeDecl _ comptime-box)
                  (let
                    [template : AstDecl (box-get comptime-box)]
                    (match template
                      [(AstDeclDefFn _ _ _ _ _)
                        (+ 1 (lower-function-decl-count rest))]
                      [_ (lower-function-decl-count rest)]))]
                [_ (lower-function-decl-count rest)]))]
          [_ (lower-function-decl-count rest)]))]))

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
        [rest : AstDeclList (box-get rest)]
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) entry-path])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest)
              (let
                [path-rest : AstDeclPathList (box-get path-rest)]
                path-rest)]
            [(AstDeclPathNil) AstDeclPathNil])]
        (match decl
          [(AstDeclModule next-module)
            (lower-function-body-index-from-decls-in-module
              rest
              rest-paths
              entry-path
              next-module
              index)]
          [(AstDeclDefFn name _ _ body-box _)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (lower-function-body-index-from-decls-in-module
                rest
                rest-paths
                entry-path
                module
                (lower-function-body-index-add
                  index
                  (lower-decl-logical-name entry-path decl-path module name)
                  body)))]
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (lower-function-body-index-from-decls-in-module
                (ast-decl-cons template rest)
                (ast-decl-path-cons decl-path rest-paths)
                entry-path
                module
                index))]
          [(AstDeclUnsafe inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (match inner
                [(AstDeclDefFn name _ _ body-box _)
                  (let
                    [body : AstExpr (ast-node-get body-box)]
                    (lower-function-body-index-from-decls-in-module
                      rest
                      rest-paths
                      entry-path
                      module
                      (lower-function-body-index-add
                        index
                        (lower-decl-logical-name
                          entry-path
                          decl-path
                          module
                          name)
                        body)))]
                [(AstDeclComptimeDecl _ _)
                  (lower-function-body-index-from-decls-in-module
                    (ast-decl-cons inner rest)
                    (ast-decl-path-cons decl-path rest-paths)
                    entry-path
                    module
                    index)]
                [_
                  (lower-function-body-index-from-decls-in-module
                    rest
                    rest-paths
                    entry-path
                    module
                    index)]))]
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
            [popped : LowerReachState
              (LowerReachState reachable (box-get rest))]
            (match (lower-function-body-index-find body-index name)
              [(LowerSomeFunctionBody body)
                (lower-reach-process
                  all-functions
                  names
                  body-index
                  (lower-reach-expr all-functions names popped body))]
              [(LowerNoFunctionBody)
                (lower-reach-process all-functions names body-index popped)]))])]))

(define (lower-dispatch-variant-logical-name
  [module : String]
  [names : LowerNameCache]
  [variant-name : String]) : String
  (lower-name-cache-resolve
    names
    (lower-dispatch-source-name module variant-name)))

(define (lower-dispatch-variant-set-add-list
  [variants : AstDispatchVariantList]
  [module : String]
  [names : LowerNameCache]
  [out : StringI64Map]) : StringI64Map
  (match variants
    [(AstDispatchVariantNil) out]
    [(AstDispatchVariantCons variant rest)
      (let
        [rest : AstDispatchVariantList (box-get rest)]
        (match variant
          [(AstDispatchVariant _ variant-name)
            (lower-dispatch-variant-set-add-list
              rest
              module
              names
              (string-i64-map-put
                out
                (lower-dispatch-variant-logical-name module names variant-name)
                1))]))]))

(define (lower-dispatch-variant-set-add-decl
  [decl : AstDecl]
  [module : String]
  [names : LowerNameCache]
  [out : StringI64Map]) : StringI64Map
  (match decl
    [(AstDeclDefDispatch _ variants)
      (lower-dispatch-variant-set-add-list variants module names out)]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (lower-dispatch-variant-set-add-decl inner module names out))]
    [_ out]))

(define (lower-dispatch-variant-set-from-decls-in-module
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [module : String]
  [names : LowerNameCache]
  [out : StringI64Map]) : StringI64Map
  (match decls
    [(AstDeclNil) out]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest)
              (let
                [path-rest : AstDeclPathList (box-get path-rest)]
                path-rest)]
            [(AstDeclPathNil) AstDeclPathNil])]
        (match decl
          [(AstDeclModule next-module)
            (lower-dispatch-variant-set-from-decls-in-module
              rest
              rest-paths
              entry-path
              next-module
              names
              out)]
          [_
            (lower-dispatch-variant-set-from-decls-in-module
              rest
              rest-paths
              entry-path
              module
              names
              (lower-dispatch-variant-set-add-decl decl module names out))]))]))

(define (lower-dispatch-variant-set-from-decls
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [names : LowerNameCache]) : StringI64Map
  (lower-dispatch-variant-set-from-decls-in-module
    decls
    paths
    entry-path
    ""
    names
    (string-i64-map-with-capacity 1024)))

(define (lower-reach-add-dispatch-variant-list
  [all-functions : StringI64Map]
  [module : String]
  [names : LowerNameCache]
  [variants : AstDispatchVariantList]
  [state : LowerReachState]) : LowerReachState
  (match variants
    [(AstDispatchVariantNil) state]
    [(AstDispatchVariantCons variant rest)
      (let
        [rest : AstDispatchVariantList (box-get rest)]
        (match variant
          [(AstDispatchVariant _ variant-name)
            (lower-reach-add-dispatch-variant-list
              all-functions
              module
              names
              rest
              (lower-reach-add-logical
                all-functions
                state
                (lower-dispatch-variant-logical-name module names variant-name)))]))]))

(define (lower-reach-add-dispatch-variant-decl
  [all-functions : StringI64Map]
  [module : String]
  [names : LowerNameCache]
  [decl : AstDecl]
  [state : LowerReachState]) : LowerReachState
  (match decl
    [(AstDeclDefDispatch _ variants)
      (lower-reach-add-dispatch-variant-list
        all-functions
        module
        names
        variants
        state)]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (lower-reach-add-dispatch-variant-decl
          all-functions
          module
          names
          inner
          state))]
    [_ state]))

(define (lower-reach-add-dispatch-variant-roots-in-module
  [all-functions : StringI64Map]
  [decls : AstDeclList]
  [module : String]
  [names : LowerNameCache]
  [state : LowerReachState]) : LowerReachState
  (match decls
    [(AstDeclNil) state]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule next-module)
            (lower-reach-add-dispatch-variant-roots-in-module
              all-functions
              rest
              next-module
              names
              state)]
          [_
            (lower-reach-add-dispatch-variant-roots-in-module
              all-functions
              rest
              module
              names
              (lower-reach-add-dispatch-variant-decl
                all-functions
                module
                names
                decl
                state))]))]))

(define (lower-reach-add-dispatch-variant-roots
  [all-functions : StringI64Map]
  [decls : AstDeclList]
  [names : LowerNameCache]
  [state : LowerReachState]) : LowerReachState
  (lower-reach-add-dispatch-variant-roots-in-module
    all-functions
    decls
    ""
    names
    state))

(define (lower-function-kept-by-reach-or-dispatch?
  [reachable : StringI64Map]
  [dispatch-variants : StringI64Map]
  [logical-name : String]) : bool
  (or
    (string-i64-map-contains? reachable logical-name)
    (string-i64-map-contains? dispatch-variants logical-name)))

(define (lower-decl-kept-by-reach-or-dispatch?
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [reachable : StringI64Map]
  [dispatch-variants : StringI64Map]
  [decl : AstDecl]) : bool
  (match (lower-function-logical-name-from-decl
    entry-path
    decl-path
    module
    decl)
    [(TcSomeString logical-name)
      (lower-function-kept-by-reach-or-dispatch?
        reachable
        dispatch-variants
        logical-name)]
    [(TcNoString) true]))

(define (lower-filter-reachable-decls-in-module
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [module : String]
  [reachable : StringI64Map]
  [dispatch-variants : StringI64Map]) : AstDeclList
  (match decls
    [(AstDeclNil) AstDeclNil]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) entry-path])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest)
              (let
                [path-rest : AstDeclPathList (box-get path-rest)]
                path-rest)]
            [(AstDeclPathNil) AstDeclPathNil])]
        (match decl
          [(AstDeclModule next-module)
            (ast-decl-cons
              decl
              (lower-filter-reachable-decls-in-module
                rest
                rest-paths
                entry-path
                next-module
                reachable
                dispatch-variants))]
          [_
            (if (lower-decl-kept-by-reach-or-dispatch?
              entry-path
              decl-path
              module
              reachable
              dispatch-variants
              decl)
              (ast-decl-cons
                decl
                (lower-filter-reachable-decls-in-module
                  rest
                  rest-paths
                  entry-path
                  module
                  reachable
                  dispatch-variants))
              (lower-filter-reachable-decls-in-module
                rest
                rest-paths
                entry-path
                module
                reachable
                dispatch-variants))]))]))

(define (lower-filter-reachable-paths-in-module
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [module : String]
  [reachable : StringI64Map]
  [dispatch-variants : StringI64Map]) : AstDeclPathList
  (match decls
    [(AstDeclNil) AstDeclPathNil]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) entry-path])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest)
              (let
                [path-rest : AstDeclPathList (box-get path-rest)]
                path-rest)]
            [(AstDeclPathNil) AstDeclPathNil])]
        (match decl
          [(AstDeclModule next-module)
            (ast-decl-path-cons
              decl-path
              (lower-filter-reachable-paths-in-module
                rest
                rest-paths
                entry-path
                next-module
                reachable
                dispatch-variants))]
          [_
            (if (lower-decl-kept-by-reach-or-dispatch?
              entry-path
              decl-path
              module
              reachable
              dispatch-variants
              decl)
              (ast-decl-path-cons
                decl-path
                (lower-filter-reachable-paths-in-module
                  rest
                  rest-paths
                  entry-path
                  module
                  reachable
                  dispatch-variants))
              (lower-filter-reachable-paths-in-module
                rest
                rest-paths
                entry-path
                module
                reachable
                dispatch-variants))]))]))

;; The synthesized clone$<T> helpers (compiler_clone.tl) are referenced by
;; `(clone x)` forms only after lowering. Seed exactly the helpers needed by
;; clone calls found in already-reachable source functions.
(define (lower-reach-add-clone-root-helpers
  [all-functions : StringI64Map]
  [names : LowerNameCache]
  [roots : CloneNameList]
  [state : LowerReachState]) : LowerReachState
  (match roots
    [(CloneNameNil) state]
    [(CloneNameCons name rest)
      (lower-reach-add-clone-root-helpers
        all-functions
        names
        (box-get rest)
        (lower-reach-add-source
          all-functions
          names
          state
          (clone-helper-name name)))]))

;; Functions with an `(:export-symbol …)` declaration (#2143) publish a fixed
;; ABI symbol and may be called only from outside TypeLisp IR (e.g. the
;; backend-emitted bounds/division/shift checks call the runtime-prelude
;; handlers). Seed every exported function as a reachability root so the prune
;; keeps it and its transitive callees even with no IR caller.
(define (lower-reach-add-export-root-decl
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [all-functions : StringI64Map]
  [state : LowerReachState]
  [decl : AstDecl]) : LowerReachState
  (match decl
    [(AstDeclDefFn name _ _ _ export)
      (match export
        [(AstFnExport _)
          (lower-reach-add-logical
            all-functions
            state
            (lower-decl-logical-name entry-path decl-path module name))]
        [(AstFnNoExport) state])]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (lower-reach-add-export-root-decl
          entry-path
          decl-path
          module
          all-functions
          state
          inner))]
    [_ state]))

(define (lower-reach-add-export-roots-in-module
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [entry-path : String]
  [module : String]
  [all-functions : StringI64Map]
  [state : LowerReachState]) : LowerReachState
  (match decls
    [(AstDeclNil) state]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        [decl-path : String
          (match paths
            [(AstDeclPathCons path _) path]
            [(AstDeclPathNil) entry-path])]
        [rest-paths : AstDeclPathList
          (match paths
            [(AstDeclPathCons _ path-rest) (box-get path-rest)]
            [(AstDeclPathNil) AstDeclPathNil])]
        (match decl
          [(AstDeclModule next-module)
            (lower-reach-add-export-roots-in-module
              rest
              rest-paths
              entry-path
              next-module
              all-functions
              state)]
          [_
            (lower-reach-add-export-roots-in-module
              rest
              rest-paths
              entry-path
              module
              all-functions
              (lower-reach-add-export-root-decl
                entry-path
                decl-path
                module
                all-functions
                state
                decl))]))]))

(define (lower-prune-unreachable-functions-with-clone-roots
  [entry-path : String]
  [program : AstProgram]
  [paths : AstDeclPathList]
  [names : LowerNameEnv]
  [clone-roots : CloneNameList]) : LowerPrunedProgram
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        [all-functions : StringI64Map
          (lower-function-set-from-decls decls paths entry-path)]
        [body-index : LowerFunctionBodyIndex
          (lower-function-body-index-from-decls
            decls
            paths
            entry-path
            (lower-function-decl-count decls))]
        [name-cache : LowerNameCache (lower-name-cache-from-env names)]
        [dispatch-variants : StringI64Map
          (lower-dispatch-variant-set-from-decls
            decls
            paths
            entry-path
            name-cache)]
        (if (string-i64-map-contains? all-functions "main")
          (match (lower-reach-process
            all-functions
            name-cache
            body-index
            (lower-reach-global-decls
              all-functions
              name-cache
              (lower-reach-add-dispatch-variant-roots
                all-functions
                decls
                name-cache
                (lower-reach-add-clone-root-helpers
                  all-functions
                  name-cache
                  clone-roots
                  (lower-reach-add-export-roots-in-module
                    decls
                    paths
                    entry-path
                    ""
                    all-functions
                    (lower-reach-add-logical
                      all-functions
                      (LowerReachState
                        (string-i64-map-with-capacity 8192)
                        LowerStringNil)
                      "main"))))
              decls))
            [(LowerReachState reachable _)
              (LowerPrunedProgram
                (ast-program
                  (lower-filter-reachable-decls-in-module
                    decls
                    paths
                    entry-path
                    ""
                    reachable
                    dispatch-variants))
                (lower-filter-reachable-paths-in-module
                  decls
                  paths
                  entry-path
                  ""
                  reachable
                  dispatch-variants))])
          (LowerPrunedProgram program paths)))]))

(define (lower-prune-unreachable-functions
  [entry-path : String]
  [program : AstProgram]
  [paths : AstDeclPathList]
  [names : LowerNameEnv]) : LowerPrunedProgram
  (lower-prune-unreachable-functions-with-clone-roots
    entry-path
    program
    paths
    names
    (CloneNameNil)))

(define (lower-state-next-var [state : LowerState]) : i64
  (match state
    [(LowerState next-var _ _ _ _ _ _ _ _ _ _ _) next-var]))

(define (lower-state-current-label [state : LowerState]) : String
  (match state
    [(LowerState _ _ _ label _ _ _ _ _ _ _ _) label]))

(define (lower-state-current-function [state : LowerState]) : String
  (match state
    [(LowerState _ _ _ _ _ _ _ function _ _ _ _) function]))

(define (lower-state-spans [state : LowerState]) : CompilerSourceSpans
  (match state
    [(LowerState _ _ _ _ _ _ _ _ spans _ _ _) spans]))

(define (lower-state-names [state : LowerState]) : LowerNameCache
  (match state
    [(LowerState _ _ _ _ _ _ _ _ _ names _ _) names]))

(define (lower-state-type-cache [state : LowerState]) : LowerTypeCache
  (match state
    [(LowerState _ _ _ _ _ _ _ _ _ _ type-cache _) type-cache]))

(define (lower-state-functions [state : LowerState]) : CompilerIrFunctionList
  (match state
    [(LowerState _ _ _ _ _ _ functions _ _ _ _ _) functions]))

(define (lower-state-mode [state : LowerState]) : CompilerLowerMode
  (match state
    [(LowerState _ _ _ _ _ _ _ _ _ _ _ mode) mode]))

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
        type-cache
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
          type-cache
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
        type-cache
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
          type-cache
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
        type-cache
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
          type-cache
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
        type-cache
        mode)
      (LowerState
        next-var
        next-label
        next-lambda
        current-label
        (compiler-ir-instr-cons instr current-instrs)
        blocks
        functions
        function
        spans
        names
        type-cache
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
        type-cache
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
        type-cache
        mode)]))

(define (lower-state-emit-at-expr
  [state : LowerState]
  [instr : CompilerIrInstr]
  [expr : AstExpr])
  :
  LowerState
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
        type-cache
        mode)
      (LowerState
        next-var
        next-label-id
        next-lambda
        next-label
        IrInstrNil
        (compiler-ir-block-cons
          (IrBlock
            current-label
            (lower-instr-seq-from-reversed-list current-instrs))
          blocks)
        functions
        function
        spans
        names
        type-cache
        mode)]))

(define (lower-state-build-blocks [state : LowerState]) : CompilerIrBlockList
  (match state
    [(LowerState _ _ _ current-label current-instrs blocks _ _ _ _ _ _)
      (let
        [current-block : CompilerIrBlock
          (IrBlock
            current-label
            (lower-instr-seq-from-reversed-list current-instrs))]
        (lower-block-list-reverse-onto
          blocks
          (compiler-ir-block-cons current-block IrBlockNil)))]))

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
        type-cache
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
        type-cache
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
    [(AstTyRegion _ inner) (lower-type-size ctx (ty-node-get inner))]
    [(AstTyEnum _) 8]
    [(AstTyEnumArgs _ _) 8]
    [(AstTyStruct _) 8]
    [(AstTyStructArgs _ _) 8]
    [(AstTyString) 8]
    [(AstTyStr) 8]
    [(AstTyVar _) 8]
    [(AstTyVarArgs _ _) 8]))

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
    [(AstTyRegion _ inner) (lower-type-align ctx (ty-node-get inner))]
    [(AstTyEnum _) 8]
    [(AstTyEnumArgs _ _) 8]
    [(AstTyStruct _) 8]
    [(AstTyStructArgs _ _) 8]
    [(AstTyString) 8]
    [(AstTyStr) 8]
    [(AstTyVar _) 8]
    [(AstTyVarArgs _ _) 8]))

(define (lower-type-list-extent
  [ctx : TcContext]
  [types : AstTypeList]
  [cursor : i64]) : i64
  (match types
    [(AstTypeNil) cursor]
    [(AstTypeCons ty rest)
      (let
        [ty : AstType (ty-node-get ty)]
        [rest : AstTypeList (box-get rest)]
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
    [(AstVariantDef _ fields _) (lower-variant-fields-storage-size ctx fields)]))

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
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef variant-name fields _)
            (let
              [next : CompilerIrGlobalList
                (match fields
                  [(AstTypeNil)
                    (let
                      [object-name : String
                        (lower-nullary-variant-object-name
                          enum-name
                          variant-name)]
                      (compiler-ir-global-cons
                        (IrGlobal object-name (AstTyI64) (IrValueI64 tag))
                        globals))]
                  [_ globals])]
              (lower-nullary-variant-globals enum-name rest (+ tag 1) next))]))]))

(define (lower-enum-variants-storage-size
  [ctx : TcContext]
  [variants : AstVariantDefList]
  [max-size : i64]) : i64
  (match variants
    [(AstVariantDefNil) max-size]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        [size : i64 (lower-variant-storage-size ctx variant)]
        (lower-enum-variants-storage-size
          ctx
          rest
          (if (> size max-size)
            size
            max-size)))]))

(define (lower-enum-storage-size [ctx : TcContext] [enum-name : String]) : i64
  (match (tc-context-enum-variants ctx enum-name)
    [(OkAstVariantDefList variants)
      (lower-enum-variants-storage-size ctx variants 8)]
    [(ErrAstVariantDefList _) 8]))

(define (lower-struct-fields [ctx : TcContext] [struct-name : String]) : ResultAstFieldDefList
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
                  [(AstDeclDefStruct _ _ _ fields) (OkAstFieldDefList fields)]
                  [(AstDeclDefStructLifetimes _ _ _ _ fields)
                    (OkAstFieldDefList fields)]
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
        [(TcStructDecl repr _ _) (ast-struct-repr-c? repr)])]
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
          (IrInstrCall var-id "tl_alloc" (IrCallArgsOne (IrValueI64 size)) ty))
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

(define (lower-inline-aggregate-copy-size [ctx : TcContext] [ty : AstType]) : ResultLowerSize
  (match (tc-inline-aggregate-type-layout ctx ty)
    [(OkTcLayoutInfo info)
      (match info
        [(TcLayoutInfo size _) (OkLowerSize size)])]
    [(ErrTcLayoutInfo message) (ErrLowerSize message)]))

(define (lower-copy-inline-aggregate-to-inline
  [ctx : TcContext]
  [state : LowerState]
  [value : CompilerIrValue]
  [ty : AstType]) : ResultLowerExpr
  (match (lower-inline-aggregate-copy-size ctx ty)
    [(OkLowerSize size)
      (match (lower-reserve-inline-storage state size ty)
        [(LowerExpr copy-state copy-value _)
          (OkLowerExpr
            (LowerExpr
              (lower-copy-bytes copy-state copy-value 0 value 0 size)
              copy-value
              ty))])]
    [(ErrLowerSize message) (ErrLowerExpr (lower-diagnostic message))]))

(define (lower-copy-inline-aggregate-to-heap
  [ctx : TcContext]
  [state : LowerState]
  [value : CompilerIrValue]
  [ty : AstType]) : ResultLowerExpr
  (match (lower-inline-aggregate-copy-size ctx ty)
    [(OkLowerSize size)
      (match (lower-reserve-heap-storage state size ty)
        [(LowerExpr copy-state copy-value _)
          (OkLowerExpr
            (LowerExpr
              (lower-copy-bytes copy-state copy-value 0 value 0 size)
              copy-value
              ty))])]
    [(ErrLowerSize message) (ErrLowerExpr (lower-diagnostic message))]))

(define (lower-inline-aggregate-abi-copy-needed?
  [ctx : TcContext]
  [state : LowerState]
  [ty : AstType]) : bool
  (and
    (lower-mode-inline-aggregates? (lower-state-mode state))
    (lower-type-contains-inline-aggregate? ctx ty)))

(define (lower-return-abi-value
  [ctx : TcContext]
  [state : LowerState]
  [value : CompilerIrValue]
  [ty : AstType]) : ResultLowerExpr
  (if (lower-inline-aggregate-abi-copy-needed? ctx state ty)
    (lower-copy-inline-aggregate-to-heap ctx state value ty)
    (OkLowerExpr (LowerExpr state value ty))))

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
        (IrInstrCall var-id "tl_oob_abort" (IrCallArgsNil) (AstTyUnit)))]))

(define (lower-string-fields [state : LowerState] [value : CompilerIrValue]) : LowerStringFields
  (match (lower-load-at-offset state value 0 (AstTyU64))
    [(LowerExpr ptr-state ptr _)
      (match (lower-load-at-offset ptr-state value 8 (AstTyI64))
        [(LowerExpr len-state len _) (LowerStringFields len-state ptr len)])]))

(define (lower-str-ref-type? [ctx : TcContext] [ty : AstType]) : bool
  (match (tc-type-strip-region (tc-resolve-type ctx ty))
    [(AstTyRef _ inner)
      (match (tc-type-strip-region (tc-resolve-type ctx (ty-node-get inner)))
        [(AstTyStr) true]
        [_ false])]
    [_ false]))

(define (lower-string-handle-type? [ctx : TcContext] [ty : AstType]) : bool
  (match (tc-type-strip-region (tc-resolve-type ctx ty))
    [(AstTyString) true]
    [_ (lower-str-ref-type? ctx ty)]))

(define (lower-string-concat-builtin-name? [name : String]) : bool
  (or (string-eq name "string-append") (string-eq name "string-concat")))

(define (lower-string-concat-call-parts
  [ctx : TcContext]
  [env : SymI64Env]
  [expr : AstExpr]) : LowerMaybeStringConcatCall
  (match (ast-expr-unspan expr)
    [(AstExprCall callee-box args)
      (match (ast-expr-unspan (ast-node-get callee-box))
        [(AstExprVar name)
          (if (and
            (lower-string-concat-builtin-name? (intern-str name))
            (lower-builtin-call-available? ctx env (intern-str name)))
            (match args
              [(AstExprCons left tail)
                (let
                  [left : AstExpr (ast-node-get left)]
                  [tail : AstExprList (box-get tail)]
                  (match tail
                    [(AstExprCons right rest)
                      (let
                        [right : AstExpr (ast-node-get right)]
                        [rest : AstExprList (box-get rest)]
                        (match rest
                          [(AstExprNil) (LowerSomeStringConcatCall left right)]
                          [_ (LowerNoStringConcatCall)]))]
                    [_ (LowerNoStringConcatCall)]))]
              [_ (LowerNoStringConcatCall)])
            (LowerNoStringConcatCall))]
        [_ (LowerNoStringConcatCall)])]
    [_ (LowerNoStringConcatCall)]))

(define (lower-string-concat-exprs-right
  [ctx : TcContext]
  [env : SymI64Env]
  [left : AstExpr]
  [right : AstExpr]
  [remaining : i64]) : AstExprList
  (if (<= remaining 2)
    (ast-expr-cons
      (ast-node-push left)
      (ast-expr-cons (ast-node-push right) AstExprNil))
    (match (lower-string-concat-call-parts ctx env right)
      [(LowerSomeStringConcatCall nested-left nested-right)
        (ast-expr-cons
          (ast-node-push left)
          (lower-string-concat-exprs-right
            ctx
            env
            nested-left
            nested-right
            (- remaining 1)))]
      [(LowerNoStringConcatCall)
        (ast-expr-cons
          (ast-node-push left)
          (ast-expr-cons (ast-node-push right) AstExprNil))])))

(define (lower-string-concat-runtime-name [count : i64]) : String
  (cond
    [(= count 3) "tl_string_concat3"]
    [(= count 4) "tl_string_concat4"]
    [(= count 5) "tl_string_concat5"]
    [else "tl_string_concat"]))

(define (lower-string-concat-values-rev
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [exprs : AstExprList]
  [acc : CompilerIrValueList]
  [count : i64]) : ResultLowerStringValues
  (match exprs
    [(AstExprNil) (OkLowerStringValues state acc count)]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (ast-node-get expr)]
        [rest : AstExprList (box-get rest)]
        (match (lower-expr ctx state env type-env expr)
          [(OkLowerExpr lowered)
            (match lowered
              [(LowerExpr expr-state value expr-ty)
                (if (lower-string-handle-type? ctx expr-ty)
                  (match (lower-string-fields expr-state value)
                    [(LowerStringFields field-state ptr len)
                      (lower-string-concat-values-rev
                        ctx
                        field-state
                        env
                        type-env
                        rest
                        (compiler-ir-value-cons
                          len
                          (compiler-ir-value-cons ptr acc))
                        (+ count 1))])
                  (ErrLowerStringValues
                    (lower-diagnostic-at-expr
                      expr
                      "lower: string-concat requires String")))])]
          [(ErrLowerExpr message) (ErrLowerStringValues message)]))]))

(define (lower-string-concat-exprs
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [exprs : AstExprList]) : ResultLowerExpr
  (match (lower-string-concat-values-rev
    ctx
    state
    env
    type-env
    exprs
    IrValueNil
    0)
    [(OkLowerStringValues values-state values-rev count)
      (match (lower-state-alloc-var values-state)
        [(LowerAlloc allocated var-id)
          (OkLowerExpr
            (LowerExpr
              (lower-state-emit
                allocated
                (IrInstrCall
                  var-id
                  (lower-string-concat-runtime-name count)
                  (compiler-ir-call-args-from-list
                    (compiler-ir-value-list-reverse-onto values-rev IrValueNil))
                  (AstTyString)))
              (IrValueVar var-id)
              (AstTyString)))])]
    [(ErrLowerStringValues message) (ErrLowerExpr message)]))

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
    [(AstTyArray elem-ty _)
      (not (tc-type-contains-reference? (ty-node-get elem-ty)))]
    [(AstTyDynArray elem-ty)
      (not (tc-type-contains-reference? (ty-node-get elem-ty)))]
    [_ false]))

(define (lower-borrow-place-value-reference? [ctx : TcContext] [ty : AstType]) : bool
  (match (tc-type-strip-region (tc-resolve-type ctx ty))
    [(AstTyArray _ _) true]
    [(AstTyDynArray _) true]
    [_ false]))

(define (lower-supported-reference-type-list-with-stack?
  [ctx : TcContext]
  [types : AstTypeList]
  [stack : LowerStringSet]) : bool
  (match types
    [(AstTypeNil) true]
    [(AstTypeCons head rest)
      (let
        [head : AstType (ty-node-get head)]
        [rest : AstTypeList (box-get rest)]
        (and
          (lower-supported-reference-type-with-stack? ctx head stack)
          (lower-supported-reference-type-list-with-stack? ctx rest stack)))]))

(define (lower-supported-reference-type-list-subst-with-stack?
  [ctx : TcContext]
  [subst : TcLifetimeSubst]
  [types : AstTypeList]
  [stack : LowerStringSet]) : bool
  (match types
    [(AstTypeNil) true]
    [(AstTypeCons head rest)
      (let
        [head : AstType (ty-node-get head)]
        [rest : AstTypeList (box-get rest)]
        (and
          (lower-supported-reference-type-with-stack?
            ctx
            (tc-lifetime-subst-type subst head)
            stack)
          (lower-supported-reference-type-list-subst-with-stack?
            ctx
            subst
            rest
            stack)))]))

(define (lower-supported-reference-field-list-with-stack?
  [ctx : TcContext]
  [subst : TcLifetimeSubst]
  [fields : AstFieldDefList]
  [stack : LowerStringSet]) : bool
  (match fields
    [(AstFieldDefNil) true]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef _ ty _)
            (and
              (lower-supported-reference-type-with-stack?
                ctx
                (tc-lifetime-subst-type subst ty)
                stack)
              (lower-supported-reference-field-list-with-stack?
                ctx
                subst
                rest
                stack))]))]))

(define (lower-supported-reference-variant-list-with-stack?
  [ctx : TcContext]
  [subst : TcLifetimeSubst]
  [variants : AstVariantDefList]
  [stack : LowerStringSet]) : bool
  (match variants
    [(AstVariantDefNil) true]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef _ fields _)
            (and
              (lower-supported-reference-type-list-subst-with-stack?
                ctx
                subst
                fields
                stack)
              (lower-supported-reference-variant-list-with-stack?
                ctx
                subst
                rest
                stack))]))]))

(define (lower-supported-reference-struct-args-with-stack?
  [ctx : TcContext]
  [name : String]
  [lifetimes : AstLifetimeList]
  [stack : LowerStringSet]) : bool
  (if (lower-string-set-contains? stack name)
    true
    (match (tc-lifetime-subst-from-nominal-args ctx name lifetimes)
      [(ErrTcLifetimeSubst _) false]
      [(OkTcLifetimeSubst subst)
        (match (tc-struct-decl ctx name)
          [(ErrTcStructDecl _) false]
          [(OkTcStructDecl decl)
            (match decl
              [(TcStructDecl _ _ fields)
                (lower-supported-reference-field-list-with-stack?
                  ctx
                  subst
                  fields
                  (lower-string-set-insert stack name))])])])))

(define (lower-supported-reference-enum-args-with-stack?
  [ctx : TcContext]
  [name : String]
  [lifetimes : AstLifetimeList]
  [stack : LowerStringSet]) : bool
  (if (lower-string-set-contains? stack name)
    true
    (match (tc-lifetime-subst-from-nominal-args ctx name lifetimes)
      [(ErrTcLifetimeSubst _) false]
      [(OkTcLifetimeSubst subst)
        (match (tc-context-enum-variants ctx name)
          [(ErrAstVariantDefList _) false]
          [(OkAstVariantDefList variants)
            (lower-supported-reference-variant-list-with-stack?
              ctx
              subst
              variants
              (lower-string-set-insert stack name))])])))

(define (lower-supported-reference-type-with-stack?
  [ctx : TcContext]
  [ty : AstType]
  [stack : LowerStringSet]) : bool
  (let
    [resolved : AstType (tc-type-strip-region (tc-resolve-type ctx ty))]
    (if (not (tc-type-contains-reference? resolved))
      true
      (match resolved
        [(AstTyRef _ inner)
          (lower-supported-reference-referent-type? ctx (ty-node-get inner))]
        [(AstTyMutRef _ inner)
          (lower-supported-reference-referent-type? ctx (ty-node-get inner))]
        [(AstTyTuple elems)
          (lower-supported-reference-type-list-with-stack? ctx elems stack)]
        [(AstTyArray elem _)
          (lower-supported-reference-type-with-stack?
            ctx
            (ty-node-get elem)
            stack)]
        [(AstTyBox elem)
          (lower-supported-reference-type-with-stack?
            ctx
            (ty-node-get elem)
            stack)]
        [(AstTyStructArgs name lifetimes)
          (lower-supported-reference-struct-args-with-stack?
            ctx
            name
            lifetimes
            stack)]
        [(AstTyEnumArgs name lifetimes)
          (lower-supported-reference-enum-args-with-stack?
            ctx
            name
            lifetimes
            stack)]
        [(AstTyRegion _ inner)
          (lower-supported-reference-type-with-stack?
            ctx
            (ty-node-get inner)
            stack)]
        [_ false]))))

(define (lower-supported-reference-type? [ctx : TcContext] [ty : AstType]) : bool
  (lower-supported-reference-type-with-stack? ctx ty LowerStringNil))

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
              (if (lower-borrow-place-value-reference? ctx referent-ty)
                (OkLowerExpr (LowerExpr state (IrValueVar id) result-ty))
                (OkLowerExpr
                  (lower-borrow-copy-to-storage
                    ctx
                    state
                    (IrValueVar id)
                    referent-ty
                    result-ty)))]
            [(NoneI64)
              (OkLowerExpr
                (LowerExpr
                  state
                  (IrValueGlobalAddr (lower-resolve-name state name))
                  result-ty))])))]
    [(ErrTcType message)
      (ErrLowerExpr (lower-diagnostic-at-expr origin message))]))

(define (lower-borrow-struct-field-address-named
  [ctx : TcContext]
  [state : LowerState]
  [receiver-value : CompilerIrValue]
  [struct-name : String]
  [field : String]
  [origin : AstExpr]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-struct-field-info ctx struct-name field)
    [(OkLowerFieldInfo info)
      (match info
        [(LowerFieldInfo offset _)
          (match (lower-gep-byte state receiver-value offset)
            [(LowerExpr ptr-state ptr _)
              (OkLowerExpr (LowerExpr ptr-state ptr result-ty))])])]
    [(ErrLowerFieldInfo message) (ErrLowerExpr message)]))

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
              (lower-borrow-struct-field-address-named
                ctx
                receiver-state
                receiver-value
                struct-name
                field
                origin
                result-ty)]
            [(AstTyStructArgs struct-name _)
              (lower-borrow-struct-field-address-named
                ctx
                receiver-state
                receiver-value
                struct-name
                field
                origin
                result-ty)]
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
  (match (lower-expr-result-type-or-check
    ctx
    env
    type-env
    (lower-state-type-cache state)
    arr)
    [(OkTcType arr-ty)
      (match (tc-type-strip-region arr-ty)
        [(AstTyDynArray elem-ty)
          (match (lower-expr ctx state env type-env arr)
            [(OkLowerExpr arr-lowered)
              (match arr-lowered
                [(LowerExpr arr-state arr-value _)
                  (match (lower-index-result-type-or-check
                    ctx
                    env
                    type-env
                    (lower-state-type-cache arr-state)
                    index)
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
                                (tc-type-without-regions (ty-node-get elem-ty)))
                                [(LowerExpr addr-state elem-ptr _)
                                  (OkLowerExpr
                                    (LowerExpr addr-state elem-ptr result-ty))])])]
                        [(ErrLowerExpr message) (ErrLowerExpr message)])]
                    [(ErrTcType message)
                      (ErrLowerExpr (lower-diagnostic-at-expr index message))])])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])]
        [(AstTyArray elem-ty elem-count)
          (let
            [fixed-elem-ty : AstType
              (tc-type-without-regions (ty-node-get elem-ty))]
            (match (lower-expr ctx state env type-env arr)
              [(OkLowerExpr arr-lowered)
                (match arr-lowered
                  [(LowerExpr arr-state arr-value _)
                    (match (lower-index-result-type-or-check
                      ctx
                      env
                      type-env
                      (lower-state-type-cache arr-state)
                      index)
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
      (lower-borrow-var-address
        ctx
        state
        env
        type-env
        (intern-str name)
        origin
        result-ty)]
    [(AstExprStructGet receiver-box field)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        (lower-borrow-struct-field-address
          ctx
          state
          env
          type-env
          receiver
          field
          origin
          result-ty))]
    [(AstExprTupleRef tuple-expr-box index)
      (let
        [tuple-expr : AstExpr (ast-node-get tuple-expr-box)]
        (lower-borrow-tuple-field-address
          ctx
          state
          env
          type-env
          tuple-expr
          index
          origin
          result-ty))]
    [(AstExprArrayRef arr-box index-box)
      (let
        [arr : AstExpr (ast-node-get arr-box)]
        [index : AstExpr (ast-node-get index-box)]
        (lower-borrow-array-element-address
          ctx
          state
          env
          type-env
          arr
          index
          origin
          result-ty))]
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
        (if (lower-supported-reference-referent-type?
          ctx
          (ty-node-get referent-ty))
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
      [(AstTyMutRef _ referent-ty)
        (if (lower-supported-reference-referent-type?
          ctx
          (ty-node-get referent-ty))
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
            [ty : AstType (ty-node-get ty)]
            [rest-types : AstTypeList (box-get rest-types)]
            [resolved : AstType (tc-resolve-type ctx ty)]
            [offset : i64
              (lower-align-up cursor (lower-type-align ctx resolved))]
            (lower-store-values
              ctx
              (lower-store-at-offset state base offset value resolved)
              base
              (box-get rest-values)
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
                  (box-get rest-values)
                  (box-get rest-fields)))])]
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
          (let
            [rest-fields : AstFieldDefList (box-get rest-fields)]
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
                            (box-get rest-values)
                            rest-fields
                            layout))]
                      [(ErrTcLayoutInfo message)
                        (ErrLowerState (lower-diagnostic message))])))]))]
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
            [ty : AstType (ty-node-get ty)]
            [rest-types : AstTypeList (box-get rest-types)]
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
                    (box-get rest-values)
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
    [(AstLitString _) true]
    [_ false]))

(define (lower-enum-type-name-or-empty [ty : AstType]) : String
  (match (tc-type-strip-region ty)
    [(AstTyEnum enum-name) enum-name]
    [(AstTyEnumArgs enum-name _) enum-name]
    [(AstTyVarArgs enum-name _) enum-name]
    [_ ""]))

(define (lower-variant-lookup-name-for-scrut
  [scrut-ty : AstType]
  [variant-name : String]) : String
  (match (tc-type-strip-region scrut-ty)
    [(AstTyEnum enum-name) (tc-variant-name-for-enum enum-name variant-name)]
    [(AstTyEnumArgs enum-name _)
      (tc-variant-name-for-enum enum-name variant-name)]
    [(AstTyVarArgs enum-name _)
      (tc-variant-name-for-enum enum-name variant-name)]
    [_ variant-name]))

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

(define (lower-string-payload-literal-eq
  [state : LowerState]
  [field-value : CompilerIrValue]
  [lit-value : CompilerIrValue]) : ResultLowerExpr
  (match (lower-string-fields state field-value)
    [(LowerStringFields field-state field-ptr field-len)
      (match (lower-string-fields field-state lit-value)
        [(LowerStringFields done-state lit-ptr lit-len)
          (match (lower-state-alloc-var done-state)
            [(LowerAlloc eq-alloc eq-var)
              (OkLowerExpr
                (LowerExpr
                  (lower-state-emit
                    eq-alloc
                    (IrInstrCall
                      eq-var
                      "tl_string_eq"
                      (compiler-ir-call-args-from-list
                        (compiler-ir-value-cons
                          field-ptr
                          (compiler-ir-value-cons
                            field-len
                            (compiler-ir-value-cons
                              lit-ptr
                              (compiler-ir-value-cons lit-len IrValueNil)))))
                      (AstTyBool)))
                  (IrValueVar eq-var)
                  (AstTyBool)))])])]))

(define (lower-literal-payload-eq
  [ctx : TcContext]
  [state : LowerState]
  [field-value : CompilerIrValue]
  [lit : AstLiteral]
  [resolved : AstType]) : ResultLowerExpr
  (match lit
    [(AstLitString _)
      (if (lower-string-handle-type? ctx resolved)
        (lower-string-payload-literal-eq
          state
          field-value
          (lower-literal-value lit))
        (ErrLowerExpr
          (lower-diagnostic
            "lower: unsupported enum payload literal pattern type")))]
    [_
      (match (lower-state-alloc-var state)
        [(LowerAlloc eq-alloc eq-var)
          (OkLowerExpr
            (LowerExpr
              (lower-state-emit
                eq-alloc
                (IrInstrBinOp
                  eq-var
                  IrBinEq
                  field-value
                  (lower-literal-value lit)
                  resolved))
              (IrValueVar eq-var)
              (AstTyBool)))])]))

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
      (let
        [pattern : AstPattern (box-get pattern)]
        [rest-patterns : AstPatternList (box-get rest-patterns)]
        (match types
          [(AstTypeCons ty rest-types)
            (let
              [ty : AstType (ty-node-get ty)]
              [rest-types : AstTypeList (box-get rest-types)]
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
                          (match (lower-literal-payload-eq
                            ctx
                            load-state
                            field-value
                            lit
                            resolved)
                            [(OkLowerExpr lowered-eq)
                              (match lowered-eq
                                [(LowerExpr eq-state eq-value _)
                                  (match (lower-state-fresh-label
                                    eq-state
                                    "payload_ok")
                                    [(LowerLabel ok-state ok-label)
                                      (lower-bind-variant-payloads
                                        ctx
                                        (lower-state-finish-block
                                          (lower-state-emit
                                            ok-state
                                            (IrInstrBranch
                                              eq-value
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
                                        fail-label)])])]
                            [(ErrLowerExpr message) (ErrLowerEnv message)])])
                      (ErrLowerEnv
                        (lower-diagnostic
                          "lower: unsupported enum payload literal pattern type")))]
                  [(AstPatVariant nested-name nested-args-box)
                    ;; Refutable nested variant payload (#651): load the payload
                    ;; field (an enum pointer), test its tag against the nested
                    ;; variant, and on mismatch branch to the enclosing arm's
                    ;; next-arm test (`fail-label`); on match recurse into the
                    ;; nested variant's own payload fields (tag at offset 0,
                    ;; payloads from offset 8), then continue the outer payloads.
                    (let
                      [nested-args : AstPatternList (box-get nested-args-box)]
                      (match ctx
                        [(TcContext _ symbols registries _)
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
                              (match (compiler-registries-variant-fields-indexed
                                symbols
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
                                          (match (lower-state-alloc-var
                                            tag-state)
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
                                                      (ErrLowerEnv message)])])])])])])])]))]
                  [_
                    (ErrLowerEnv
                      (lower-diagnostic
                        "lower: unsupported enum payload pattern"))])))]
          [(AstTypeNil)
            (ErrLowerEnv
              (lower-diagnostic "lower: enum payload pattern arity mismatch"))]))]))

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
      (let
        [pattern : AstPattern (box-get pattern)]
        [rest : AstPatternList (box-get rest)]
        (if (lower-pattern-refutable? pattern)
          true
          (lower-pattern-list-refutable? rest)))]))

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
      (let
        [rest : AstFieldDefList (box-get rest)]
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
                  (+ offset (lower-type-size ctx resolved)))))]))]))

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
            (lower-field-info-from-repr-c-list (box-get rest) field-name))])]))

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
      (OkLowerExpr
        (LowerExpr state (IrValueGlobal (lower-resolve-name state name)) ty))]))

(define (lower-var-id
  [state : LowerState]
  [env : SymI64Env]
  [name-id : i64]
  [ty : AstType]) : ResultLowerExpr
  (match (sym-i64-lookup-id env name-id)
    [(SomeI64 id) (OkLowerExpr (LowerExpr state (IrValueVar id) ty))]
    [(NoneI64)
      (OkLowerExpr
        (LowerExpr
          state
          (IrValueGlobal (lower-resolve-name state (intern-str name-id)))
          ty))]))

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
    (match (compiler-symbols-lookup-value
      symbols
      (lower-hygiene-source-name name))
      [(SomeI64 handle)
        (or
          (=
            (compiler-symbol-handle-kind handle)
            (compiler-symbol-kind-function-define))
          (or
            (=
              (compiler-symbol-handle-kind handle)
              (compiler-symbol-kind-extern))
            (=
              (compiler-symbol-handle-kind handle)
              (compiler-symbol-kind-defdispatch))))]
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
    [(SymI64Bind name-id _ rest)
      (if (tc-expr-uses-free-name? body (intern-str name-id) bound)
        true
        (lower-lambda-captures-env? (box-get rest) body bound))]))

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
            [(AstTyFunc _ ret) (OkTcType (ty-node-get ret))]
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
            (lower-capture-list-contains-name? (box-get rest) name))])]))

(define (lower-capture-list-count [captures : LowerCaptureList]) : i64
  (match captures
    [(LowerCaptureNil) 0]
    [(LowerCaptureCons _ rest) (+ 1 (lower-capture-list-count (box-get rest)))]))

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
    [(AstTyRef _ _) true]
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
        (tc-type-without-regions (ty-node-get elem-ty))
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
        (tc-type-without-regions (ty-node-get elem-ty))
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
                          (IrCallArgsOne byte-count)
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
        [ty : AstType (ty-node-get ty)]
        [rest : AstTypeList (box-get rest)]
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
      (let
        [rest : AstVariantDefList (box-get rest)]
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
                        [(AstVariantDef _ fields _)
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
                            [(ErrLowerState message) (ErrLowerState message)])]))])])]))]))

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
    [(SymI64Bind name-id var-id rest)
      (let
        [name : String (intern-str name-id)]
        (if (or
          (lower-capture-list-contains-name? captures name)
          (not (tc-expr-uses-free-name? body name bound)))
          (lower-capture-plan-scan
            ctx
            (box-get rest)
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
                      (box-get rest)
                      type-env
                      body
                      bound
                      (+ offset (lower-type-size ctx slot-ty))
                      (LowerCaptureCons
                        (LowerCapture name var-id capture-ty offset)
                        (box captures))
                      origin))
                  (ErrLowerCapturePlan
                    (lower-diagnostic-at-expr
                      origin
                      (lower-capture-support-message ctx capture-ty)))))])))]))

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
                    (box-get rest))])]
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
                    (box-get rest)
                    (sym-i64-bind env name loaded-var)
                    (tc-bind type-env name capture-ty))]
                [_
                  (ErrLowerEnv
                    (lower-diagnostic
                      "lower: capture load did not materialize a variable"))])])])]))

(define (lower-captured-param-list [ctx : TcContext] [params : AstParamList]) : CompilerIrParamList
  (compiler-ir-param-cons
    (IrParam "__tl_env" (AstTyU64) 0)
    (lower-param-list ctx params 1)))

(define (lower-function-with-captures
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
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
          type-cache
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
            [type-env : TcTypeEnv (tc-bind-params ctx captured-type-env params)]
            (match (lower-copy-inline-aggregate-params
              ctx
              captured-state
              env
              type-env
              params)
              [(OkLowerEnv abi-state abi-env abi-type-env)
                (match (lower-tail-expr
                  ctx
                  abi-state
                  abi-env
                  abi-type-env
                  body
                  ret-ty)
                  [(OkLowerState final-state)
                    (OkLowerFunction
                      (compiler-ir-function-cons
                        (IrFunction
                          logical-name
                          (lower-captured-param-list ctx params)
                          ret-ty
                          (lower-state-next-var final-state)
                          (lower-state-build-blocks final-state))
                        (lower-state-functions final-state))
                      (lower-state-spans final-state))]
                  [(ErrLowerState message) (ErrLowerFunction message)])]
              [(ErrLowerEnv message) (ErrLowerFunction message)]))]
        [(ErrLowerEnv message) (ErrLowerFunction message)]))))

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
            (lower-state-type-cache state)
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
                    (lower-state-type-cache named-state)
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

(define lower-cleanup-marker-id-cache : i64
  -1)

(define (lower-cleanup-marker-id) : i64
  lower-cleanup-marker-id-cache)

(define (lower-region-reset-marker-name) : String
  " __tl_active_region_reset")

(define lower-region-reset-marker-id-cache : i64
  -1)

(define (lower-region-reset-marker-id) : i64
  lower-region-reset-marker-id-cache)

(define (lower-spmd-reduce-acc-name) : String
  "0spmd-reduce-acc")

(define (lower-spmd-reduce-end-name) : String
  "0spmd-reduce-end")

(define (lower-spmd-reduce-val-name) : String
  "0spmd-reduce-val")

(define (lower-spmd-reduce-current-name) : String
  "0spmd-reduce-current")

(define lower-spmd-reduce-acc-id-cache : i64
  -1)

(define lower-spmd-reduce-end-id-cache : i64
  -1)

(define lower-spmd-reduce-val-id-cache : i64
  -1)

(define lower-spmd-reduce-current-id-cache : i64
  -1)

(define (lower-spmd-reduce-acc-id) : i64
  lower-spmd-reduce-acc-id-cache)

(define (lower-spmd-reduce-end-id) : i64
  lower-spmd-reduce-end-id-cache)

(define (lower-spmd-reduce-val-id) : i64
  lower-spmd-reduce-val-id-cache)

(define (lower-spmd-reduce-current-id) : i64
  lower-spmd-reduce-current-id-cache)

(define (lower-name-id [name : String]) : i64
  (cond
    [(string-eq name (lower-spmd-reduce-acc-name)) (lower-spmd-reduce-acc-id)]
    [(string-eq name (lower-spmd-reduce-end-name)) (lower-spmd-reduce-end-id)]
    [(string-eq name (lower-spmd-reduce-val-name)) (lower-spmd-reduce-val-id)]
    [(string-eq name (lower-spmd-reduce-current-name))
      (lower-spmd-reduce-current-id)]
    [else (intern name)]))

(define (lower-refresh-marker-ids!) : unit
  (begin
    (set! lower-cleanup-marker-id-cache (intern (lower-cleanup-marker-name)))
    (set!
      lower-region-reset-marker-id-cache
      (intern (lower-region-reset-marker-name)))
    (set! lower-spmd-reduce-acc-id-cache (intern (lower-spmd-reduce-acc-name)))
    (set! lower-spmd-reduce-end-id-cache (intern (lower-spmd-reduce-end-name)))
    (set! lower-spmd-reduce-val-id-cache (intern (lower-spmd-reduce-val-name)))
    (set!
      lower-spmd-reduce-current-id-cache
      (intern (lower-spmd-reduce-current-name)))))

(define (lower-cleanup-hidden-name [var-id : i64]) : String
  (string-append "__tl_cleanup_resource." (int->string var-id)))

(define (lower-region-hidden-name [var-id : i64]) : String
  (string-append "__tl_region_mark." (int->string var-id)))

(define (lower-cleanup-metadata-type
  [hidden-name : String]
  [cleanup-name : String]) : AstType
  (AstTyTuple
    (ast-type-cons
      (AstTyVar hidden-name)
      (ast-type-cons (AstTyVar cleanup-name) AstTypeNil))))

(define (lower-region-reset-metadata-type [hidden-name : String]) : AstType
  (AstTyVar hidden-name))

(define (lower-type-env-push-cleanup
  [type-env : TcTypeEnv]
  [hidden-name : String]
  [cleanup-name : String]) : TcTypeEnv
  (tc-bind-id
    type-env
    (lower-cleanup-marker-id)
    (lower-cleanup-metadata-type hidden-name cleanup-name)))

(define (lower-type-env-push-region-reset
  [type-env : TcTypeEnv]
  [hidden-name : String]) : TcTypeEnv
  (tc-bind-id
    type-env
    (lower-region-reset-marker-id)
    (lower-region-reset-metadata-type hidden-name)))

(define (lower-cleanup-name-from-expr [cleanup : AstExpr]) : ResultTcString
  (match (ast-expr-unspan cleanup)
    [(AstExprVar name) (OkTcString (intern-str name))]
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
                (IrCallArgsOne (IrValueVar resource-id))
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
                (IrCallArgsOne (IrValueVar mark-var))
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
              (lower-emit-cleanup-list next-state env (box-get rest))]
            [(ErrLowerState message) (ErrLowerState message)])])]))

(define (lower-cleanup-list-count [cleanups : LowerCleanupList]) : i64
  (match cleanups
    [(LowerCleanupNil) 0]
    [(LowerCleanupCons _ rest) (+ 1 (lower-cleanup-list-count (box-get rest)))]))

(define (lower-emit-active-exits-with
  [cleanup-marker-id : i64]
  [region-reset-marker-id : i64]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]) : ResultLowerState
  (match type-env
    [(TcTypeNil) (OkLowerState state)]
    [(TcTypeCache _ _ _ _ rest)
      (lower-emit-active-exits-with
        cleanup-marker-id
        region-reset-marker-id
        state
        env
        (box-get rest))]
    [(TcTypeBind key ty rest)
      (if (= key cleanup-marker-id)
        (match ty
          [(AstTyTuple types)
            (match types
              [(AstTypeCons hidden-ty type-rest)
                (let
                  [hidden-ty : AstType (ty-node-get hidden-ty)]
                  [type-rest : AstTypeList (box-get type-rest)]
                  (match hidden-ty
                    [(AstTyVar hidden-name)
                      (match type-rest
                        [(AstTypeCons cleanup-ty end)
                          (let
                            [cleanup-ty : AstType (ty-node-get cleanup-ty)]
                            [end : AstTypeList (box-get end)]
                            (match cleanup-ty
                              [(AstTyVar cleanup-name)
                                (match end
                                  [(AstTypeNil)
                                    (match (lower-emit-cleanup-call
                                      state
                                      env
                                      hidden-name
                                      cleanup-name)
                                      [(OkLowerState next-state)
                                        (lower-emit-active-exits-with
                                          cleanup-marker-id
                                          region-reset-marker-id
                                          next-state
                                          env
                                          (box-get rest))]
                                      [(ErrLowerState message)
                                        (ErrLowerState message)])]
                                  [_
                                    (lower-emit-active-exits-with
                                      cleanup-marker-id
                                      region-reset-marker-id
                                      state
                                      env
                                      (box-get rest))])]
                              [_
                                (lower-emit-active-exits-with
                                  cleanup-marker-id
                                  region-reset-marker-id
                                  state
                                  env
                                  (box-get rest))]))]
                        [_
                          (lower-emit-active-exits-with
                            cleanup-marker-id
                            region-reset-marker-id
                            state
                            env
                            (box-get rest))])]
                    [_
                      (lower-emit-active-exits-with
                        cleanup-marker-id
                        region-reset-marker-id
                        state
                        env
                        (box-get rest))]))]
              [_
                (lower-emit-active-exits-with
                  cleanup-marker-id
                  region-reset-marker-id
                  state
                  env
                  (box-get rest))])]
          [_
            (lower-emit-active-exits-with
              cleanup-marker-id
              region-reset-marker-id
              state
              env
              (box-get rest))])
        (if (= key region-reset-marker-id)
          (match ty
            [(AstTyVar hidden-name)
              (match (lower-emit-region-reset state env hidden-name)
                [(OkLowerState next-state)
                  (lower-emit-active-exits-with
                    cleanup-marker-id
                    region-reset-marker-id
                    next-state
                    env
                    (box-get rest))]
                [(ErrLowerState message) (ErrLowerState message)])]
            [_
              (lower-emit-active-exits-with
                cleanup-marker-id
                region-reset-marker-id
                state
                env
                (box-get rest))])
          (lower-emit-active-exits-with
            cleanup-marker-id
            region-reset-marker-id
            state
            env
            (box-get rest))))]))

(define (lower-emit-active-exits
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]) : ResultLowerState
  (lower-emit-active-exits-with
    (lower-cleanup-marker-id)
    (lower-region-reset-marker-id)
    state
    env
    type-env))

(define (lower-emit-active-cleanups-with
  [cleanup-marker-id : i64]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]) : ResultLowerState
  (match type-env
    [(TcTypeNil) (OkLowerState state)]
    [(TcTypeCache _ _ _ _ rest)
      (lower-emit-active-cleanups-with
        cleanup-marker-id
        state
        env
        (box-get rest))]
    [(TcTypeBind key ty rest)
      (if (= key cleanup-marker-id)
        (match ty
          [(AstTyTuple types)
            (match types
              [(AstTypeCons hidden-ty type-rest)
                (let
                  [hidden-ty : AstType (ty-node-get hidden-ty)]
                  [type-rest : AstTypeList (box-get type-rest)]
                  (match hidden-ty
                    [(AstTyVar hidden-name)
                      (match type-rest
                        [(AstTypeCons cleanup-ty end)
                          (let
                            [cleanup-ty : AstType (ty-node-get cleanup-ty)]
                            [end : AstTypeList (box-get end)]
                            (match cleanup-ty
                              [(AstTyVar cleanup-name)
                                (match end
                                  [(AstTypeNil)
                                    (match (lower-emit-cleanup-call
                                      state
                                      env
                                      hidden-name
                                      cleanup-name)
                                      [(OkLowerState next-state)
                                        (lower-emit-active-cleanups-with
                                          cleanup-marker-id
                                          next-state
                                          env
                                          (box-get rest))]
                                      [(ErrLowerState message)
                                        (ErrLowerState message)])]
                                  [_
                                    (lower-emit-active-cleanups-with
                                      cleanup-marker-id
                                      state
                                      env
                                      (box-get rest))])]
                              [_
                                (lower-emit-active-cleanups-with
                                  cleanup-marker-id
                                  state
                                  env
                                  (box-get rest))]))]
                        [_
                          (lower-emit-active-cleanups-with
                            cleanup-marker-id
                            state
                            env
                            (box-get rest))])]
                    [_
                      (lower-emit-active-cleanups-with
                        cleanup-marker-id
                        state
                        env
                        (box-get rest))]))]
              [_
                (lower-emit-active-cleanups-with
                  cleanup-marker-id
                  state
                  env
                  (box-get rest))])]
          [_
            (lower-emit-active-cleanups-with
              cleanup-marker-id
              state
              env
              (box-get rest))])
        (lower-emit-active-cleanups-with
          cleanup-marker-id
          state
          env
          (box-get rest)))]))

(define (lower-emit-active-cleanups
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]) : ResultLowerState
  (lower-emit-active-cleanups-with (lower-cleanup-marker-id) state env type-env))

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
              (match (lower-return-abi-value ctx value-state value-ir return-ty)
                [(OkLowerExpr return-copy)
                  (match return-copy
                    [(LowerExpr return-state return-value _)
                      (match (lower-emit-active-exits return-state env type-env)
                        [(OkLowerState cleanup-state)
                          (OkLowerExpr
                            (LowerExpr
                              (lower-state-emit-at-expr
                                cleanup-state
                                (IrInstrReturn
                                  (lower-return-maybe return-value return-ty))
                                origin)
                              IrValueUnit
                              (AstTyNever)))]
                        [(ErrLowerState message) (ErrLowerExpr message)])])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])])]
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
                      (match (tc-try-infos-compatible operand-info return-info)
                        [(OkTcUnit)
                          (lower-try-with-info
                            ctx
                            result-state
                            env
                            type-env
                            result-value
                            operand-info
                            return-info
                            origin)]
                        [(ErrTcUnit message)
                          (ErrLowerExpr
                            (lower-diagnostic-at-expr origin message))])]
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

(define (lower-string-runtime-builtin? [name : String]) : bool
  (let
    [_ : String name]
    false))

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
      [(AstExprCons arg tail)
        (let
          [arg : AstExpr (ast-node-get arg)]
          [tail : AstExprList (box-get tail)]
          (match tail
            [(AstExprNil)
              (match (lower-expr ctx state env type-env arg)
                [(OkLowerExpr lowered)
                  (match lowered
                    [(LowerExpr arg-state arg-value arg-ty)
                      (match (lower-cast-value
                        arg-state
                        arg-value
                        arg-ty
                        (AstTyI64))
                        [(LowerExpr cast-state cast-value _)
                          (lower-runtime-call-values
                            cast-state
                            (lower-arena-builtin-symbol name)
                            (compiler-ir-value-cons cast-value IrValueNil)
                            result-ty)])])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])]
            [_
              (ErrLowerExpr
                (lower-diagnostic "lower: arena builtin expects one argument"))]))]
      [_
        (ErrLowerExpr
          (lower-diagnostic "lower: arena builtin expects one argument"))])))

;; Lower `(clone x)` (#1633): the canonical deep-copy / arena-escape. A String
;; copies its buffer through `tl_substring`; tuple, fixed-array, and dynamic-
;; array values allocate fresh storage and recursively clone each element; Box
;; values allocate a fresh box for the cloned inner value; named aggregates
;; dispatch to synthesized `clone$<Name>` helpers (compiler_clone.tl) so
;; recursive enum/struct values recurse at runtime instead of lower time; and
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
              (IrCallArgsOne value)
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
        [ty : AstType (ty-node-get ty)]
        [rest : AstTypeList (box-get rest)]
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
                          (IrCallArgsOne byte-count)
                          (AstTyU64)))
                      env
                      type-env
                      old-buf
                      len
                      elem-ty
                      elem-size
                      buf-var
                      result-ty)])]))])]))

(define (lower-clone-box-value
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [value : CompilerIrValue]
  [inner-ty : AstType]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-load-at-offset state value 0 inner-ty)
    [(LowerExpr load-state inner-value _)
      (match (lower-clone-dispatch
        ctx
        load-state
        env
        type-env
        inner-value
        inner-ty)
        [(OkLowerExpr cloned)
          (match cloned
            [(LowerExpr clone-state clone-value _)
              (match (lower-reserve-heap-storage
                clone-state
                (lower-type-size ctx inner-ty)
                result-ty)
                [(LowerExpr box-state box-value _)
                  (OkLowerExpr
                    (LowerExpr
                      (lower-store-at-offset
                        box-state
                        box-value
                        0
                        clone-value
                        inner-ty)
                      box-value
                      result-ty))])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]))

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
          (tc-type-without-regions (ty-node-get elem-ty))
          count
          clone-ty)]
      [(AstTyDynArray elem-ty)
        (lower-clone-dynarray-value
          ctx
          state
          env
          type-env
          value
          (tc-type-without-regions (ty-node-get elem-ty))
          clone-ty)]
      [(AstTyBox elem-ty)
        (lower-clone-box-value
          ctx
          state
          env
          type-env
          value
          (tc-type-without-regions (ty-node-get elem-ty))
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
    [else (string-eq name "string->int")]))

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
      (let
        [arg : AstExpr (ast-node-get arg)]
        [rest-args : AstExprList (box-get rest-args)]
        (match types
          [(AstTypeCons expected rest-types)
            (let
              [expected : AstType (ty-node-get expected)]
              [rest-types : AstTypeList (box-get rest-types)]
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
                          (OkLowerArgs
                            rest-state
                            (compiler-ir-value-cons value rest-values))]
                        [(ErrLowerArgs message) (ErrLowerArgs message)])])]
                [(ErrLowerExpr message) (ErrLowerArgs message)]))]
          [(AstTypeNil)
            (ErrLowerArgs
              (lower-diagnostic "lower: constructor arity mismatch"))]))]))

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
  [enum-name : String]
  [enum-ty : AstType]) : ResultLowerExpr
  (match (tc-inline-aggregate-layout-for ctx enum-name)
    [(OkTcInlineAggregateLayout layout)
      (match layout
        [(TcInlineEnumLayout size _ _)
          (let
            [layout-variant-name : String (tc-qualified-name-base variant-name)]
            (match (lower-reserve-inline-storage state size enum-ty)
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
                      (OkLowerExpr (LowerExpr done-state base enum-ty))]
                    [(ErrLowerState message) (ErrLowerExpr message)]))]))]
        [(TcInlineStructLayout _ _ _)
          (ErrLowerExpr
            (lower-diagnostic
              (string-append
                "lower: inline layout for enum is struct "
                enum-name)))])]
    [(ErrTcInlineAggregateLayout message)
      (ErrLowerExpr (lower-diagnostic message))]))

(define (lower-enum-constructor-fields-for-result
  [ctx : TcContext]
  [enum-name : String]
  [enum-ty : AstType]
  [fields : AstTypeList]) : AstTypeList
  (match enum-ty
    [(AstTyEnumArgs _ lifetimes)
      (match (tc-lifetime-subst-from-nominal-args ctx enum-name lifetimes)
        [(OkTcLifetimeSubst subst) (tc-lifetime-subst-type-list subst fields)]
        [(ErrTcLifetimeSubst _) fields])]
    [(AstTyVarArgs _ lifetimes)
      (match (tc-lifetime-subst-from-nominal-args ctx enum-name lifetimes)
        [(OkTcLifetimeSubst subst) (tc-lifetime-subst-type-list subst fields)]
        [(ErrTcLifetimeSubst _) fields])]
    [_ fields]))

(define (lower-construct-enum-with-name
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [variant-name : String]
  [handle : i64]
  [args : AstExprList]
  [enum-name : String]
  [enum-ty : AstType]) : ResultLowerExpr
  (match ctx
    [(TcContext _ symbols _ _)
      (match (compiler-registries-variant-fields-indexed symbols handle)
        [(OkAstTypeList fields)
          (let
            [resolved-fields : AstTypeList
              (tc-resolve-type-list
                ctx
                (lower-enum-constructor-fields-for-result
                  ctx
                  enum-name
                  enum-ty
                  fields))]
            (match (lower-args-as ctx state env type-env args resolved-fields)
              [(OkLowerArgs args-state values)
                (if (lower-mode-inline-aggregates?
                  (lower-state-mode args-state))
                  (lower-construct-enum-inline-from-values
                    ctx
                    args-state
                    variant-name
                    handle
                    values
                    resolved-fields
                    enum-name
                    enum-ty)
                  (match resolved-fields
                    [(AstTypeNil)
                      (OkLowerExpr
                        (LowerExpr
                          args-state
                          (IrValueGlobalAddr
                            (lower-nullary-variant-object-name
                              enum-name
                              variant-name))
                          enum-ty))]
                    [_
                      (let
                        [size : i64
                          (lower-variant-fields-storage-size
                            ctx
                            resolved-fields)]
                        (match (lower-reserve-heap-storage
                          args-state
                          size
                          enum-ty)
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
                                resolved-fields
                                8)
                                [(OkLowerState done-state)
                                  (OkLowerExpr
                                    (LowerExpr done-state base enum-ty))]
                                [(ErrLowerState message) (ErrLowerExpr message)]))]))]))]
              [(ErrLowerArgs message) (ErrLowerExpr message)]))]
        [(ErrAstTypeList message) (ErrLowerExpr (lower-diagnostic message))])]))

(define (lower-construct-enum-with-handle
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [variant-name : String]
  [handle : i64]
  [args : AstExprList]
  [result-ty : AstType]) : ResultLowerExpr
  (let
    [enum-ty : AstType
      (tc-type-without-regions (tc-resolve-type ctx result-ty))]
    (match enum-ty
      [(AstTyEnum enum-name)
        (lower-construct-enum-with-name
          ctx
          state
          env
          type-env
          variant-name
          handle
          args
          enum-name
          enum-ty)]
      [(AstTyEnumArgs enum-name _)
        (lower-construct-enum-with-name
          ctx
          state
          env
          type-env
          variant-name
          handle
          args
          enum-name
          enum-ty)]
      [_
        (ErrLowerExpr
          (lower-diagnostic
            (string-append
              "lower: enum constructor result is not enum: "
              variant-name)))])))

(define (lower-struct-constructor-field-types-for-result
  [ctx : TcContext]
  [struct-name : String]
  [struct-ty : AstType]
  [fields : AstFieldDefList]) : AstTypeList
  (let
    [field-types : AstTypeList (tc-field-type-list ctx fields)]
    (match struct-ty
      [(AstTyStructArgs _ lifetimes)
        (match (tc-lifetime-subst-from-nominal-args ctx struct-name lifetimes)
          [(OkTcLifetimeSubst subst)
            (tc-lifetime-subst-type-list subst field-types)]
          [(ErrTcLifetimeSubst _) field-types])]
      [(AstTyVarArgs _ lifetimes)
        (match (tc-lifetime-subst-from-nominal-args ctx struct-name lifetimes)
          [(OkTcLifetimeSubst subst)
            (tc-lifetime-subst-type-list subst field-types)]
          [(ErrTcLifetimeSubst _) field-types])]
      [_ field-types])))

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
        [struct-ty : AstType
          (tc-type-without-regions (tc-resolve-type ctx result-ty))]
        [field-types : AstTypeList
          (lower-struct-constructor-field-types-for-result
            ctx
            struct-name
            struct-ty
            fields)]
        (match (lower-args-as ctx state env type-env args field-types)
          [(OkLowerArgs args-state values)
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
                            (OkLowerExpr (LowerExpr done-state base struct-ty))]
                          [(ErrLowerState message) (ErrLowerExpr message)])])]
                  [(ErrTcReprCLayout message)
                    (ErrLowerExpr (lower-diagnostic message))])
                (let
                  [size : i64 (lower-type-list-storage-size ctx field-types)]
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
                        [(ErrLowerState message) (ErrLowerExpr message)])]))))]
          [(ErrLowerArgs message) (ErrLowerExpr message)]))]
    [(ErrAstFieldDefList message) (ErrLowerExpr (lower-diagnostic message))]))

(define (lower-init-expr-list-from-types [types : AstTypeList]) : AstExprList
  (match types
    [(AstTypeNil) AstExprNil]
    [(AstTypeCons head rest)
      (let
        [head : AstType (ty-node-get head)]
        [rest : AstTypeList (box-get rest)]
        (ast-expr-cons
          (ast-expr-init head)
          (lower-init-expr-list-from-types rest)))]))

(define (lower-init-expr-list-repeat [ty : AstType] [count : i64]) : AstExprList
  (if (<= count 0)
    AstExprNil
    (ast-expr-cons
      (ast-expr-init ty)
      (lower-init-expr-list-repeat ty (- count 1)))))

(define (lower-init-scalar
  [state : LowerState]
  [value : CompilerIrValue]
  [ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (lower-materialize-at-expr state value ty origin))

(define (lower-init-struct
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [struct-name : String]
  [struct-ty : AstType]) : ResultLowerExpr
  (if (lower-struct-repr-c? ctx struct-name)
    (ErrLowerExpr
      (lower-diagnostic "lower: init supports only default-layout structs"))
    (match (lower-struct-fields ctx struct-name)
      [(OkAstFieldDefList fields)
        (let
          [field-types : AstTypeList
            (tc-resolve-type-list
              ctx
              (lower-struct-constructor-field-types-for-result
                ctx
                struct-name
                struct-ty
                fields))]
          (lower-construct-struct
            ctx
            state
            env
            type-env
            struct-name
            (lower-init-expr-list-from-types field-types)
            struct-ty))]
      [(ErrAstFieldDefList message) (ErrLowerExpr (lower-diagnostic message))])))

(define (lower-init-enum
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [enum-name : String]
  [enum-ty : AstType]) : ResultLowerExpr
  (match (tc-enum-decl ctx enum-name)
    [(OkTcEnumDecl decl)
      (match decl
        [(TcEnumDecl _ variants)
          (match variants
            [(AstVariantDefNil)
              (ErrLowerExpr
                (lower-diagnostic
                  "lower: init requires enum with at least one variant"))]
            [(AstVariantDefCons variant _)
              (match variant
                [(AstVariantDef variant-name fields _)
                  (let
                    [lookup-name : String
                      (tc-variant-name-for-enum enum-name variant-name)]
                    [payload-types : AstTypeList
                      (tc-resolve-type-list
                        ctx
                        (lower-enum-constructor-fields-for-result
                          ctx
                          enum-name
                          enum-ty
                          fields))]
                    (match (compiler-registries-lookup-variant
                      (tc-context-registries ctx)
                      lookup-name)
                      [(SomeI64 handle)
                        (lower-construct-enum-with-name
                          ctx
                          state
                          env
                          type-env
                          lookup-name
                          handle
                          (lower-init-expr-list-from-types payload-types)
                          enum-name
                          enum-ty)]
                      [(NoneI64)
                        (ErrLowerExpr
                          (lower-diagnostic
                            (string-append
                              "lower: unknown variant "
                              lookup-name)))]))])])])]
    [(ErrTcEnumDecl message) (ErrLowerExpr (lower-diagnostic message))]))

(define (lower-init-expr
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [ty : AstType]
  [origin : AstExpr]
  [expr-ty : AstType]) : ResultLowerExpr
  (let
    [resolved : AstType (tc-type-without-regions (tc-resolve-type ctx ty))]
    (if (tc-integer-type? resolved)
      (lower-init-scalar state (IrValueI64 0) expr-ty origin)
      (match resolved
        [(AstTyF64) (lower-init-scalar state (IrValueF64 "0.0") expr-ty origin)]
        [(AstTyF32) (lower-init-scalar state (IrValueF64 "0.0") expr-ty origin)]
        [(AstTyBool)
          (lower-init-scalar state (IrValueBool false) expr-ty origin)]
        [(AstTyChar)
          (lower-init-scalar state (IrValueChar #\nul') expr-ty origin)]
        [(AstTyUnit) (OkLowerExpr (LowerExpr state IrValueUnit expr-ty))]
        [(AstTyString)
          (lower-init-scalar state (IrValueString "") expr-ty origin)]
        [(AstTyPtr _)
          (match (lower-materialize state (IrValueI64 0) (AstTyU64))
            [(OkLowerExpr lowered)
              (match lowered
                [(LowerExpr null-state null-value _)
                  (OkLowerExpr (LowerExpr null-state null-value expr-ty))])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])]
        [(AstTyMutPtr _)
          (match (lower-materialize state (IrValueI64 0) (AstTyU64))
            [(OkLowerExpr lowered)
              (match lowered
                [(LowerExpr null-state null-value _)
                  (OkLowerExpr (LowerExpr null-state null-value expr-ty))])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])]
        [(AstTyDynArray elem)
          (lower-make-array-from-len
            ctx
            state
            env
            type-env
            (ty-node-get elem)
            (IrValueI64 0)
            (AstTyI64)
            (AstExprLiteral (AstLitInt 0))
            origin)]
        [(AstTyBox elem)
          (lower-box
            ctx
            state
            env
            type-env
            (AstExprInit (ty-node-get elem))
            expr-ty)]
        [(AstTyTuple elems)
          (lower-tuple
            ctx
            state
            env
            type-env
            (lower-init-expr-list-from-types elems)
            expr-ty
            origin)]
        [(AstTyArray elem count)
          (if (< count 0)
            (ErrLowerExpr
              (lower-diagnostic
                "lower: init fixed array length must be non-negative"))
            (lower-array-literal
              ctx
              state
              env
              type-env
              (lower-init-expr-list-repeat (ty-node-get elem) count)
              expr-ty
              origin))]
        [(AstTyStruct name)
          (lower-init-struct ctx state env type-env name resolved)]
        [(AstTyStructArgs name _)
          (lower-init-struct ctx state env type-env name resolved)]
        [(AstTyEnum name)
          (lower-init-enum ctx state env type-env name resolved)]
        [(AstTyEnumArgs name _)
          (lower-init-enum ctx state env type-env name resolved)]
        [_
          (ErrLowerExpr
            (lower-diagnostic-at-expr
              origin
              (string-append
                "lower: init unsupported type "
                (tc-type-render resolved))))]))))

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
      (match (tc-type-strip-region expr-ty)
        [(AstTyEnum _)
          (let
            [lookup-name : String
              (lower-variant-constructor-lookup-name ctx name expr-ty)]
            [symbols : CompilerSymbols (tc-context-symbols ctx)]
            [registries : CompilerRegistries (tc-context-registries ctx)]
            (match (compiler-registries-lookup-variant registries lookup-name)
              [(SomeI64 handle)
                (match (compiler-registries-variant-fields-indexed
                  symbols
                  handle)
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
                      [_
                        (lower-function-value-or-var ctx state env name expr-ty)])]
                  [(ErrAstTypeList _)
                    (lower-function-value-or-var ctx state env name expr-ty)])]
              [(NoneI64)
                (lower-function-value-or-var ctx state env name expr-ty)]))]
        [_ (lower-function-value-or-var ctx state env name expr-ty)])]))

(define (lower-var-or-nullary-variant-id
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name-id : i64]
  [expr-ty : AstType]) : ResultLowerExpr
  (match (sym-i64-lookup-id env name-id)
    [(SomeI64 _) (lower-var-id state env name-id expr-ty)]
    [(NoneI64)
      (let
        [name : String (intern-str name-id)]
        (match (tc-type-strip-region expr-ty)
          [(AstTyEnum _)
            (let
              [lookup-name : String
                (lower-variant-constructor-lookup-name ctx name expr-ty)]
              [symbols : CompilerSymbols (tc-context-symbols ctx)]
              [registries : CompilerRegistries (tc-context-registries ctx)]
              (match (compiler-registries-lookup-variant registries lookup-name)
                [(SomeI64 handle)
                  (match (compiler-registries-variant-fields-indexed
                    symbols
                    handle)
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
                        [_
                          (lower-function-value-or-var
                            ctx
                            state
                            env
                            name
                            expr-ty)])]
                    [(ErrAstTypeList _)
                      (lower-function-value-or-var ctx state env name expr-ty)])]
                [(NoneI64)
                  (lower-function-value-or-var ctx state env name expr-ty)]))]
          [_ (lower-function-value-or-var ctx state env name expr-ty)]))]))

(define (lower-call-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [func : AstExpr]
  [args : AstExprList]) : ResultTcType
  (match (ast-expr-unspan func)
    [(AstExprVar name)
      (match (lower-lookup-type type-cache env type-env (intern-str name))
        [(OkTcType fn-ty)
          (match (tc-type-strip-region (tc-resolve-type ctx fn-ty))
            [(AstTyFunc _ ret)
              (OkTcType
                (tc-type-without-regions
                  (tc-resolve-type ctx (ty-node-get ret))))]
            [(AstTyEnum _) (OkTcType (tc-type-without-regions fn-ty))]
            [_ (ErrTcType "lower: call result type is not fast-pathable")])]
        [(ErrTcType message)
          (if (lower-builtin-call-available? ctx env (intern-str name))
            (cond
              [(string-eq (intern-str name) "array-length")
                (OkTcType (AstTyI64))]
              [(or
                  (string-eq (intern-str name) "string-ref")
                  (string-eq (intern-str name) "char-at"))
                (OkTcType (AstTyChar))]
              [(string-eq (intern-str name) "clone")
                (match args
                  [(AstExprCons arg tail)
                    (let
                      [arg : AstExpr (ast-node-get arg)]
                      [tail : AstExprList (box-get tail)]
                      (match tail
                        [(AstExprNil)
                          (lower-expr-result-type-fast
                            ctx
                            env
                            type-env
                            type-cache
                            arg)]
                        [_
                          (ErrTcType
                            "lower: call result type is not fast-pathable")]))]
                  [_ (ErrTcType "lower: call result type is not fast-pathable")])]
              [else (ErrTcType message)])
            (ErrTcType message))])]
    [(AstExprLambda params maybe-ret body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (tc-lambda-expr-allow-ref-captures
          ctx
          type-env
          params
          maybe-ret
          body)
          [(OkTcType fn-ty)
            (match fn-ty
              [(AstTyFunc _ ret)
                (OkTcType
                  (tc-type-without-regions
                    (tc-resolve-type ctx (ty-node-get ret))))]
              [_ (ErrTcType "lower: call result type is not fast-pathable")])]
          [(ErrTcType message) (ErrTcType message)]))]
    [_ (ErrTcType "lower: call result type is not fast-pathable")]))

(define (lower-binary-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
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
      (match (lower-expr-result-type-fast ctx env type-env type-cache left)
        [(OkTcType left-ty) (OkTcType left-ty)]
        [(ErrTcType message) (ErrTcType message)])]))

(define (lower-if-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [then-branch : AstExpr]
  [else-branch : AstExpr]) : ResultTcType
  (match (lower-expr-result-type-fast ctx env type-env type-cache then-branch)
    [(OkTcType then-ty)
      (match (lower-expr-result-type-fast
        ctx
        env
        type-env
        type-cache
        else-branch)
        [(OkTcType else-ty) (tc-merge-branch-type then-ty else-ty)]
        [(ErrTcType message) (ErrTcType message)])]
    [(ErrTcType message) (ErrTcType message)]))

(define (lower-expr-list-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [exprs : AstExprList]) : ResultTcType
  (match exprs
    [(AstExprNil) (OkTcType (AstTyUnit))]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (ast-node-get expr)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil)
            (lower-expr-result-type-fast ctx env type-env type-cache expr)]
          [_
            (lower-expr-list-result-type-fast ctx env type-env type-cache rest)]))]))

(define (lower-pattern-list-bind-local-names
  [env : SymI64Env]
  [patterns : AstPatternList]) : SymI64Env
  (match patterns
    [(AstPatternNil) env]
    [(AstPatternCons pattern rest)
      (let
        [pattern : AstPattern (box-get pattern)]
        [rest : AstPatternList (box-get rest)]
        (lower-pattern-list-bind-local-names
          (lower-pattern-bind-local-names env pattern)
          rest))]))

(define (lower-pattern-bind-local-names
  [env : SymI64Env]
  [pattern : AstPattern]) : SymI64Env
  (match pattern
    [(AstPatVar name _) (sym-i64-bind env name 0)]
    [(AstPatTuple patterns-box)
      (let
        [patterns : AstPatternList (box-get patterns-box)]
        (lower-pattern-list-bind-local-names env patterns))]
    [(AstPatBinding name) (sym-i64-bind env name 0)]
    [(AstPatVariant _ args-box)
      (let
        [args : AstPatternList (box-get args-box)]
        (lower-pattern-list-bind-local-names env args))]
    [_ env]))

(define (lower-match-pattern-bind-local-names
  [ctx : TcContext]
  [env : SymI64Env]
  [scrut-ty : AstType]
  [pattern : AstPattern]) : SymI64Env
  (match (tc-type-strip-region (tc-resolve-type ctx scrut-ty))
    [(AstTyEnum _)
      (match pattern
        [(AstPatVariant _ args-box)
          (let
            [args : AstPatternList (box-get args-box)]
            (lower-pattern-list-bind-local-names env args))]
        [_ env])]
    [_ (lower-pattern-bind-local-names env pattern)]))

(define (lower-match-arm-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [scrut-ty : AstType]
  [arm : AstMatchArm]) : ResultTcType
  (match arm
    [(AstMatchArm pattern body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (tc-bind-match-pattern ctx type-env scrut-ty pattern)
          [(OkTcEnv arm-type-env)
            (lower-expr-result-type-fast
              ctx
              (lower-match-pattern-bind-local-names ctx env scrut-ty pattern)
              arm-type-env
              type-cache
              body)]
          [(ErrTcEnv message) (ErrTcType message)]))]))

(define (lower-match-rest-result-types-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [scrut-ty : AstType]
  [arms : AstMatchArmList]
  [want : AstType]) : ResultTcType
  (match arms
    [(AstMatchArmNil) (OkTcType want)]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match (lower-match-arm-result-type-fast
          ctx
          env
          type-env
          type-cache
          scrut-ty
          arm)
          [(OkTcType got)
            (match (tc-merge-branch-type want got)
              [(OkTcType merged)
                (lower-match-rest-result-types-fast
                  ctx
                  env
                  type-env
                  type-cache
                  scrut-ty
                  rest
                  merged)]
              [(ErrTcType message) (ErrTcType message)])]
          [(ErrTcType message) (ErrTcType message)]))]))

(define (lower-match-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [scrutinee : AstExpr]
  [arms : AstMatchArmList]) : ResultTcType
  (match (lower-expr-result-type-fast ctx env type-env type-cache scrutinee)
    [(OkTcType scrut-ty)
      (match arms
        [(AstMatchArmNil)
          (ErrTcType "lower: match result type is not fast-pathable")]
        [(AstMatchArmCons arm rest)
          (let
            [rest : AstMatchArmList (box-get rest)]
            (match (lower-match-arm-result-type-fast
              ctx
              env
              type-env
              type-cache
              scrut-ty
              arm)
              [(OkTcType first-ty)
                (lower-match-rest-result-types-fast
                  ctx
                  env
                  type-env
                  type-cache
                  scrut-ty
                  rest
                  first-ty)]
              [(ErrTcType message) (ErrTcType message)]))])]
    [(ErrTcType message) (ErrTcType message)]))

(define (lower-let-binding-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [maybe-ty : AstMaybeType]
  [init : AstExpr]) : ResultTcType
  (match maybe-ty
    [(AstSomeType ty)
      (OkTcType (tc-type-without-regions (tc-resolve-type ctx ty)))]
    [(AstNoType)
      (if (tc-ref-capturing-lambda-init? type-env init)
        (match (ast-expr-unspan init)
          [(AstExprLambda params maybe-ret body-box)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (tc-lambda-expr-allow-ref-captures
                ctx
                type-env
                params
                maybe-ret
                body))]
          [_ (lower-expr-result-type-fast ctx env type-env type-cache init)])
        (lower-expr-result-type-fast ctx env type-env type-cache init))]))

(define (lower-let-bindings-type-env-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [bindings : AstLetBindingList]) : ResultTcEnv
  (match bindings
    [(AstLetBindingNil) (OkTcEnv type-env)]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name maybe-ty init-box)
            (let
              [name-id : i64 (lower-name-id name)]
              [init : AstExpr (ast-node-get init-box)]
              (match (lower-let-binding-result-type-fast
                ctx
                env
                type-env
                type-cache
                maybe-ty
                init)
                [(OkTcType binding-ty)
                  (lower-let-bindings-type-env-fast
                    ctx
                    (sym-i64-bind-id env name-id 0)
                    (tc-bind-id type-env name-id binding-ty)
                    type-cache
                    rest)]
                [(ErrTcType message) (ErrTcEnv message)]))]))]))

(define (lower-let-bindings-local-env
  [env : SymI64Env]
  [bindings : AstLetBindingList]) : SymI64Env
  (match bindings
    [(AstLetBindingNil) env]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name _ _)
            (lower-let-bindings-local-env
              (sym-i64-bind-id env (lower-name-id name) 0)
              rest)]))]))

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
  [type-cache : LowerTypeCache]
  [index : AstExpr]) : ResultTcType
  (match (lower-expr-result-type-fast ctx env type-env type-cache index)
    [(OkTcType index-ty)
      (if (tc-integer-type? index-ty)
        (OkTcType index-ty)
        (ErrTcType "lower: index result type is not fast-pathable"))]
    [(ErrTcType message) (ErrTcType message)]))

(define (lower-unary-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [op : AstUnOp]
  [inner : AstExpr]) : ResultTcType
  (match (lower-expr-result-type-fast ctx env type-env type-cache inner)
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
  [type-cache : LowerTypeCache]
  [tuple-expr : AstExpr]
  [index : i64]) : ResultTcType
  (match (lower-expr-result-type-fast ctx env type-env type-cache tuple-expr)
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
  [type-cache : LowerTypeCache]
  [array-expr : AstExpr]
  [index : AstExpr]) : ResultTcType
  (match (lower-index-result-type-fast ctx env type-env type-cache index)
    [(OkTcType _)
      (match (lower-expr-result-type-fast
        ctx
        env
        type-env
        type-cache
        array-expr)
        [(OkTcType array-ty)
          (match (tc-type-strip-region (tc-resolve-type ctx array-ty))
            [(AstTyArray elem-ty _)
              (OkTcType
                (lower-projected-result-type-fast
                  ctx
                  array-ty
                  (ty-node-get elem-ty)))]
            [(AstTyDynArray elem-ty)
              (OkTcType
                (lower-projected-result-type-fast
                  ctx
                  array-ty
                  (ty-node-get elem-ty)))]
            [_ (ErrTcType "lower: array-ref result type is not fast-pathable")])]
        [(ErrTcType message) (ErrTcType message)])]
    [(ErrTcType message) (ErrTcType message)]))

(define (lower-string-ref-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [str : AstExpr]
  [index : AstExpr]) : ResultTcType
  (match (lower-index-result-type-fast ctx env type-env type-cache index)
    [(OkTcType _)
      (match (lower-expr-result-type-fast ctx env type-env type-cache str)
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
  [type-cache : LowerTypeCache]
  [receiver : AstExpr]
  [field : String]) : ResultTcType
  (match (lower-expr-result-type-fast ctx env type-env type-cache receiver)
    [(OkTcType receiver-ty)
      (match (tc-type-strip-region (tc-resolve-type ctx receiver-ty))
        [(AstTyStruct struct-name)
          (match (tc-struct-field-type ctx struct-name field)
            [(OkTcType field-ty)
              (OkTcType
                (lower-projected-result-type-fast ctx receiver-ty field-ty))]
            [(ErrTcType message) (ErrTcType message)])]
        [(AstTyStructArgs struct-name lifetimes)
          (match (tc-struct-field-type-with-args
            ctx
            struct-name
            lifetimes
            field)
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
  [type-cache : LowerTypeCache]
  [box-expr : AstExpr]) : ResultTcType
  (match (lower-expr-result-type-fast ctx env type-env type-cache box-expr)
    [(OkTcType box-ty)
      (match (tc-type-strip-region (tc-resolve-type ctx box-ty))
        [(AstTyBox inner-ty)
          (OkTcType
            (lower-projected-result-type-fast ctx box-ty (ty-node-get inner-ty)))]
        [_ (ErrTcType "lower: box-get result type is not fast-pathable")])]
    [(ErrTcType message) (ErrTcType message)]))

(define (lower-expr-result-type-fast
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [expr : AstExpr]) : ResultTcType
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-expr-result-type-fast ctx env type-env type-cache inner))]
    [(AstExprLiteral lit) (OkTcType (tc-literal-type lit))]
    [(AstExprVar name)
      (match (lower-lookup-type-id type-cache env type-env name)
        [(OkTcType expr-ty) (OkTcType (tc-type-without-regions expr-ty))]
        [(ErrTcType message) (ErrTcType message)])]
    [(AstExprInit ty)
      (OkTcType (tc-type-without-regions (tc-resolve-type ctx ty)))]
    [(AstExprAnn _ ty)
      (OkTcType (tc-type-without-regions (tc-resolve-type ctx ty)))]
    [(AstExprCast _ ty)
      (OkTcType (tc-type-without-regions (tc-resolve-type ctx ty)))]
    [(AstExprUnary op inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-unary-result-type-fast ctx env type-env type-cache op inner))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (lower-call-result-type-fast ctx env type-env type-cache func args))]
    [(AstExprBinary op left-box _)
      (let
        [left : AstExpr (ast-node-get left-box)]
        (lower-binary-result-type-fast ctx env type-env type-cache op left))]
    [(AstExprIf _ then-branch-box else-branch-box)
      (let
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (lower-if-result-type-fast
          ctx
          env
          type-env
          type-cache
          then-branch
          else-branch))]
    [(AstExprBegin exprs)
      (lower-expr-list-result-type-fast ctx env type-env type-cache exprs)]
    [(AstExprUnsafe exprs)
      (lower-expr-list-result-type-fast
        ctx
        env
        (tc-enter-unsafe type-env)
        type-cache
        exprs)]
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (ast-node-get scrutinee-box)]
        (lower-match-result-type-fast
          ctx
          env
          type-env
          type-cache
          scrutinee
          arms))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (lower-let-bindings-type-env-fast
          ctx
          env
          type-env
          type-cache
          bindings)
          [(OkTcEnv body-type-env)
            (lower-expr-result-type-fast
              ctx
              (lower-let-bindings-local-env env bindings)
              body-type-env
              type-cache
              body)]
          [(ErrTcEnv message) (ErrTcType message)]))]
    [(AstExprTupleRef tuple-expr-box index)
      (let
        [tuple-expr : AstExpr (ast-node-get tuple-expr-box)]
        (lower-tuple-ref-result-type-fast
          ctx
          env
          type-env
          type-cache
          tuple-expr
          index))]
    [(AstExprArrayRef array-expr-box index-box)
      (let
        [array-expr : AstExpr (ast-node-get array-expr-box)]
        [index : AstExpr (ast-node-get index-box)]
        (lower-array-ref-result-type-fast
          ctx
          env
          type-env
          type-cache
          array-expr
          index))]
    [(AstExprStringRef str-box index-box)
      (let
        [str : AstExpr (ast-node-get str-box)]
        [index : AstExpr (ast-node-get index-box)]
        (lower-string-ref-result-type-fast
          ctx
          env
          type-env
          type-cache
          str
          index))]
    [(AstExprStructGet receiver-box field)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        (lower-struct-get-result-type-fast
          ctx
          env
          type-env
          type-cache
          receiver
          field))]
    [(AstExprBoxGet box-expr-box)
      (let
        [box-expr : AstExpr (ast-node-get box-expr-box)]
        (lower-box-get-result-type-fast ctx env type-env type-cache box-expr))]
    [(AstExprSet _ _) (OkTcType (AstTyUnit))]
    [_ (ErrTcType "lower: expression result type is not fast-pathable")]))

(define (lower-expr-result-type-or-check
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [expr : AstExpr]) : ResultTcType
  (match (lower-expr-result-type-fast ctx env type-env type-cache expr)
    [(OkTcType expr-ty) (OkTcType expr-ty)]
    [(ErrTcType _) (tc-expr ctx type-env expr)]))

(define (lower-index-result-type-or-check
  [ctx : TcContext]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [index : AstExpr]) : ResultTcType
  (match (lower-index-result-type-fast ctx env type-env type-cache index)
    [(OkTcType index-ty) (OkTcType index-ty)]
    [(ErrTcType _) (tc-expr ctx type-env index)]))

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
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-expr-origin ctx state env type-env inner origin))]
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
      (match (lower-lookup-type-id
        (lower-state-type-cache state)
        env
        type-env
        name)
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
    [(AstExprBinary op left-box _)
      (let
        [left : AstExpr (ast-node-get left-box)]
        (match (lower-binary-result-type-fast
          ctx
          env
          type-env
          (lower-state-type-cache state)
          op
          left)
          [(OkTcType expr-ty)
            (lower-expr-with-type ctx state env type-env expr origin expr-ty)]
          [(ErrTcType _)
            (lower-expr-typechecked ctx state env type-env expr origin)]))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (match (lower-call-result-type-fast
          ctx
          env
          type-env
          (lower-state-type-cache state)
          func
          args)
          [(OkTcType expr-ty)
            (lower-expr-with-type ctx state env type-env expr origin expr-ty)]
          [(ErrTcType _)
            (lower-expr-typechecked ctx state env type-env expr origin)]))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (lower-let-bindings ctx state env type-env bindings)
          [(OkLowerEnv binding-state body-env body-type-env)
            (lower-expr ctx binding-state body-env body-type-env body)]
          [(ErrLowerEnv message) (ErrLowerExpr message)]))]
    [(AstExprBegin exprs) (lower-begin ctx state env type-env exprs)]
    [(AstExprUnsafe exprs)
      (lower-begin ctx state env (tc-enter-unsafe type-env) exprs)]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (match (lower-if-result-type-fast
          ctx
          env
          type-env
          (lower-state-type-cache state)
          then-branch
          else-branch)
          [(OkTcType expr-ty)
            (lower-if
              ctx
              state
              env
              type-env
              cond
              then-branch
              else-branch
              expr-ty)]
          [(ErrTcType _)
            (lower-expr-typechecked ctx state env type-env expr origin)]))]
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (ast-node-get scrutinee-box)]
        (match (lower-match-result-type-fast
          ctx
          env
          type-env
          (lower-state-type-cache state)
          scrutinee
          arms)
          [(OkTcType expr-ty)
            (lower-match ctx state env type-env scrutinee arms expr-ty)]
          [(ErrTcType _)
            (lower-expr-typechecked ctx state env type-env expr origin)]))]
    [_
      (match (lower-expr-result-type-fast
        ctx
        env
        type-env
        (lower-state-type-cache state)
        expr)
        [(OkTcType expr-ty)
          (lower-expr-with-type ctx state env type-env expr origin expr-ty)]
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
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-expr-with-type ctx state env type-env inner origin expr-ty))]
    [(AstExprLiteral lit)
      (lower-materialize-at-expr state (lower-literal-value lit) expr-ty origin)]
    [(AstExprInit ty)
      (lower-init-expr ctx state env type-env ty origin expr-ty)]
    [(AstExprVar name)
      (lower-var-or-nullary-variant-id ctx state env type-env name expr-ty)]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (lower-expr-expected ctx state env type-env inner expr-ty origin)
          [(OkLowerExpr lowered)
            (match lowered
              [(LowerExpr inner-state value _)
                (OkLowerExpr (LowerExpr inner-state value expr-ty))])]
          [(ErrLowerExpr message) (ErrLowerExpr message)]))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match (lower-expr ctx state env type-env inner)
          [(OkLowerExpr lowered)
            (match lowered
              [(LowerExpr inner-state value inner-ty)
                (OkLowerExpr
                  (lower-cast-value inner-state value inner-ty expr-ty))])]
          [(ErrLowerExpr message) (ErrLowerExpr message)]))]
    [(AstExprBorrow _ _ inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-borrow-expr ctx state env type-env inner origin expr-ty))]
    [(AstExprUnary op inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
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
          [(ErrLowerExpr message) (ErrLowerExpr message)]))]
    [(AstExprBinary op left-box right-box)
      ;; `and`/`or` short-circuit: desugar to a conditional branch so the right
      ;; operand is evaluated only when the left does not already decide the
      ;; result, matching the Rust lowerer in `src/lower.rs` (#1132 / #1165):
      ;; `(and a b)` -> `(if a b false)`, `(or a b)` -> `(if a true b)`. Every
      ;; other binop evaluates both operands eagerly into an `IrInstrBinOp`.
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
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
              [(ErrLowerExpr message) (ErrLowerExpr message)])]))]
    [(AstExprCall func-box args)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (lower-call ctx state env type-env func args expr-ty origin))]
    [(AstExprLambda params maybe-ret body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lower-lambda
          ctx
          state
          env
          type-env
          params
          maybe-ret
          body
          origin
          expr-ty))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (lower-let-bindings ctx state env type-env bindings)
          [(OkLowerEnv binding-state body-env body-type-env)
            (lower-expr ctx binding-state body-env body-type-env body)]
          [(ErrLowerEnv message) (ErrLowerExpr message)]))]
    [(AstExprBegin exprs) (lower-begin ctx state env type-env exprs)]
    [(AstExprUnsafe exprs)
      (lower-begin ctx state env (tc-enter-unsafe type-env) exprs)]
    [(AstExprSet name value-box)
      (let
        [name-id : i64 (lower-name-id name)]
        [value : AstExpr (ast-node-get value-box)]
        (match (lower-lookup-type-id
          (lower-state-type-cache state)
          env
          type-env
          name-id)
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
                      (match (sym-i64-lookup-id env name-id)
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
                (string-append "lower: assignment to unknown local " name)))]))]
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (lower-if ctx state env type-env cond then-branch else-branch expr-ty))]
    [(AstExprWhile cond-box body-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [body : AstExpr (ast-node-get body-box)]
        (lower-while ctx state env type-env cond body))]
    [(AstExprForeach index index-ty start-box end-box body-box)
      (let
        [start : AstExpr (ast-node-get start-box)]
        [end : AstExpr (ast-node-get end-box)]
        [body : AstExpr (ast-node-get body-box)]
        (lower-foreach ctx state env type-env index index-ty start end body))]
    [(AstExprSpmdReduce op index index-ty start-box end-box init-box value-box)
      (let
        [start : AstExpr (ast-node-get start-box)]
        [end : AstExpr (ast-node-get end-box)]
        [init : AstExpr (ast-node-get init-box)]
        [value : AstExpr (ast-node-get value-box)]
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
          value))]
    [(AstExprMatch scrutinee-box arms)
      (let
        [scrutinee : AstExpr (ast-node-get scrutinee-box)]
        (lower-match ctx state env type-env scrutinee arms expr-ty))]
    [(AstExprStringRef str-box index-box)
      (let
        [str : AstExpr (ast-node-get str-box)]
        [index : AstExpr (ast-node-get index-box)]
        (lower-string-ref ctx state env type-env str index))]
    [(AstExprStructGet receiver-box field)
      (let
        [receiver : AstExpr (ast-node-get receiver-box)]
        (lower-struct-get ctx state env type-env receiver field expr-ty))]
    [(AstExprMakeArray elem-ty len-box)
      (let
        [len : AstExpr (ast-node-get len-box)]
        (lower-make-array ctx state env type-env elem-ty len origin))]
    [(AstExprArray values)
      (lower-array-literal ctx state env type-env values expr-ty origin)]
    [(AstExprArrayRef arr-box index-box)
      (let
        [arr : AstExpr (ast-node-get arr-box)]
        [index : AstExpr (ast-node-get index-box)]
        (lower-array-ref ctx state env type-env arr index))]
    [(AstExprArraySet arr-box index-box value-box)
      (let
        [arr : AstExpr (ast-node-get arr-box)]
        [index : AstExpr (ast-node-get index-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lower-array-set ctx state env type-env arr index value))]
    [(AstExprArrayPush arr-box value-box)
      (let
        [arr : AstExpr (ast-node-get arr-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lower-array-push ctx state env type-env arr value))]
    [(AstExprTuple values)
      (lower-tuple ctx state env type-env values expr-ty origin)]
    [(AstExprTupleRef tuple-expr-box index)
      (let
        [tuple-expr : AstExpr (ast-node-get tuple-expr-box)]
        (lower-tuple-ref ctx state env type-env tuple-expr index expr-ty))]
    [(AstExprWithRegion _ body) (lower-with-arena ctx state env type-env body)]
    [(AstExprWithEscape scratch-box body)
      (let
        [scratch : AstExpr (ast-node-get scratch-box)]
        (lower-with-escape ctx state env type-env scratch body))]
    [(AstExprWithResource bindings body)
      (lower-with-resource ctx state env type-env bindings body)]
    [(AstExprBox inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-box ctx state env type-env inner expr-ty))]
    [(AstExprBoxGet inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-box-get ctx state env type-env inner expr-ty))]
    [(AstExprTry inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-try ctx state env type-env inner origin))]
    [(AstExprReturn value-box)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (lower-return-form ctx state env type-env value origin))]
    ;; `(comptime expr)` folds to a literal via the scalar CTFE evaluator (#719).
    ;; Successful folds reuse the ordinary literal path; CTFE rejections (free
    ;; runtime vars, unsupported forms, f64 -> #735) surface as lower errors.
    [(AstExprComptime inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
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
          [(ErrCtfe diag) (ErrLowerExpr diag)]))]
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
    [(AstExprPtrNullCheck inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
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
          [(ErrLowerExpr diag) (ErrLowerExpr diag)]))]
    [(AstExprPtrAddrOf name)
      (match (sym-i64-lookup env name)
        [(SomeI64 local-id)
          (match (lower-state-alloc-var state)
            [(LowerAlloc allocated var-id)
              (OkLowerExpr
                (LowerExpr
                  (lower-state-emit-at-expr
                    allocated
                    (IrInstrAddrOf var-id local-id)
                    origin)
                  (IrValueVar var-id)
                  expr-ty))])]
        [(NoneI64)
          (ErrLowerExpr
            (lower-diagnostic-at-expr
              origin
              "lower: ptr-addr-of requires local or parameter storage"))])]
    [(AstExprPtrRead ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
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
          [(ErrLowerExpr diag) (ErrLowerExpr diag)]))]
    [(AstExprPtrWrite ptr-box value-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [value : AstExpr (ast-node-get value-box)]
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
          [(ErrLowerExpr diag) (ErrLowerExpr diag)]))]
    [(AstExprPtrOffset ptr-box offset-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [offset : AstExpr (ast-node-get offset-box)]
        (match (lower-expr ctx state env type-env ptr)
          [(OkLowerExpr ptr-lowered)
            (match ptr-lowered
              [(LowerExpr ptr-state ptr-value ptr-ty)
                (match (lower-expr ctx ptr-state env type-env offset)
                  [(OkLowerExpr offset-lowered)
                    (match offset-lowered
                      [(LowerExpr offset-state offset-value _)
                        (match (tc-type-strip-region
                          (tc-resolve-type ctx ptr-ty))
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
                                        (ty-node-get elem-ty))
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
                                        (ty-node-get elem-ty))
                                      origin)
                                    (IrValueVar var-id)
                                    expr-ty))])]
                          [_
                            (ErrLowerExpr
                              (lower-diagnostic-at-expr
                                origin
                                "lower: ptr-offset requires raw pointer"))])])]
                  [(ErrLowerExpr diag) (ErrLowerExpr diag)])])]
          [(ErrLowerExpr diag) (ErrLowerExpr diag)]))]
    [(AstExprPtrCast ptr-box _)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (lower-expr ctx state env type-env ptr)
          [(OkLowerExpr lowered)
            (match lowered
              [(LowerExpr ptr-state ptr-value ptr-ty)
                (OkLowerExpr
                  (lower-cast-value ptr-state ptr-value ptr-ty expr-ty))])]
          [(ErrLowerExpr diag) (ErrLowerExpr diag)]))]
    [(AstExprPtrToInt ptr-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        (match (lower-expr ctx state env type-env ptr)
          [(OkLowerExpr lowered)
            (match lowered
              [(LowerExpr ptr-state ptr-value ptr-ty)
                (OkLowerExpr
                  (lower-cast-value ptr-state ptr-value ptr-ty expr-ty))])]
          [(ErrLowerExpr diag) (ErrLowerExpr diag)]))]
    [(AstExprIntToPtr value-box _)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match (lower-expr ctx state env type-env value)
          [(OkLowerExpr lowered)
            (match lowered
              [(LowerExpr value-state value-ir value-ty)
                (OkLowerExpr
                  (lower-cast-value value-state value-ir value-ty expr-ty))])]
          [(ErrLowerExpr diag) (ErrLowerExpr diag)]))]
    [(AstExprStringData str-box)
      (let
        [str : AstExpr (ast-node-get str-box)]
        (lower-string-data ctx state env type-env str expr-ty))]
    [(AstExprStringFromBytes ptr-box len-box)
      (let
        [ptr : AstExpr (ast-node-get ptr-box)]
        [len : AstExpr (ast-node-get len-box)]
        (lower-string-from-bytes ctx state env type-env ptr len))]
    [(AstExprArrayData array-box)
      (let
        [array : AstExpr (ast-node-get array-box)]
        (lower-array-data ctx state env type-env array expr-ty))]
    [(AstExprProgramArgc) (lower-entry-load state 0 expr-ty)]
    [(AstExprProgramArgv) (lower-entry-load state 1 expr-ty)]
    [(AstExprProgramEnvp) (lower-entry-load state 2 expr-ty)]
    [(AstExprCpuIdEax leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lower-cpuid-like ctx state env type-env leaf subleaf 0))]
    [(AstExprCpuIdEbx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lower-cpuid-like ctx state env type-env leaf subleaf 1))]
    [(AstExprCpuIdEcx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lower-cpuid-like ctx state env type-env leaf subleaf 2))]
    [(AstExprCpuIdEdx leaf-box subleaf-box)
      (let
        [leaf : AstExpr (ast-node-get leaf-box)]
        [subleaf : AstExpr (ast-node-get subleaf-box)]
        (lower-cpuid-like ctx state env type-env leaf subleaf 3))]
    [(AstExprXgetbv index-box)
      (let
        [index : AstExpr (ast-node-get index-box)]
        (lower-xgetbv ctx state env type-env index))]
    [(AstExprSyscall args) (lower-syscall ctx state env type-env args)]
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
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-expr-expected ctx state env type-env inner expected-ty origin))]
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
    [(AstExprIf cond-box then-branch-box else-branch-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (lower-if
          ctx
          state
          env
          type-env
          cond
          then-branch
          else-branch
          expected-ty))]
    [(AstExprCall func-box _)
      (let
        [func : AstExpr (ast-node-get func-box)]
        (match (ast-expr-unspan func)
          [(AstExprVar name)
            (match (lower-lookup-type
              (lower-state-type-cache state)
              env
              type-env
              (intern-str name))
              [(OkTcType fn-ty)
                (match (tc-type-strip-region (tc-resolve-type ctx fn-ty))
                  [(AstTyFunc _ ret-ty)
                    (let
                      [actual-ty : AstType
                        (tc-type-without-regions
                          (tc-resolve-type ctx (ty-node-get ret-ty)))]
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
                (lower-expr-and-coerce ctx state env type-env expr expected-ty)])]
          [_ (lower-expr-and-coerce ctx state env type-env expr expected-ty)]))]
    [_ (lower-expr-and-coerce ctx state env type-env expr expected-ty)]))

(define (lower-struct-get-named
  [ctx : TcContext]
  [state : LowerState]
  [receiver-value : CompilerIrValue]
  [struct-name : String]
  [field : String]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-struct-field-info-for-mode
    ctx
    (lower-state-mode state)
    struct-name
    field)
    [(OkLowerFieldInfo info)
      (match info
        [(LowerFieldInfo offset field-ty)
          (match (lower-gep-byte state receiver-value offset)
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
    [(ErrLowerFieldInfo message) (ErrLowerExpr message)]))

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
              (lower-struct-get-named
                ctx
                receiver-state
                receiver-value
                struct-name
                field
                result-ty)]
            [(AstTyStructArgs struct-name _)
              (lower-struct-get-named
                ctx
                receiver-state
                receiver-value
                struct-name
                field
                result-ty)]
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
        [ty : AstType (ty-node-get ty)]
        [rest : AstTypeList (box-get rest)]
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
      (let
        [value : AstExpr (ast-node-get value)]
        [rest-values : AstExprList (box-get rest-values)]
        (match types
          [(AstTypeNil)
            (ErrLowerState (lower-diagnostic "lower: tuple arity mismatch"))]
          [(AstTypeCons ty rest-types)
            (let
              [ty : AstType (ty-node-get ty)]
              [rest-types : AstTypeList (box-get rest-types)]
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
                [(ErrLowerExpr message) (ErrLowerState message)]))]))]))

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
      (let
        [value : AstExpr (ast-node-get value)]
        [rest-values : AstExprList (box-get rest-values)]
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
          [(ErrLowerExpr message) (ErrLowerState message)]))]))

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
        [resolved-elem : AstType (tc-resolve-type ctx (ty-node-get elem-ty))]
        [elem-size : i64 (lower-type-size ctx (ty-node-get elem-ty))]
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
              (compiler-ir-call-args-from-list
                (compiler-ir-value-cons
                  src-ptr
                  (compiler-ir-value-cons
                    start-value
                    (compiler-ir-value-cons len-value IrValueNil))))
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
  (lower-string-concat-exprs
    ctx
    state
    env
    type-env
    (lower-string-concat-exprs-right ctx env left right 5)))

(define (lower-c-abi-runtime-handle-extern? [name : String]) : bool
  (or
    (lower-string-prefix-at? name "tl_" 0)
    (lower-string-prefix-at? name ".L_tl_" 0)))

(define (lower-c-abi-extern-call?
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [name : String]) : bool
  (if (not (lower-mode-c-abi? (lower-state-mode state)))
    false
    (match (sym-i64-lookup env name)
      [(SomeI64 _) false]
      [(NoneI64)
        (if (lower-c-abi-runtime-handle-extern? name)
          false
          (match (compiler-symbols-lookup-value
            (tc-context-symbols ctx)
            (lower-hygiene-source-name name))
            [(SomeI64 handle)
              (=
                (compiler-symbol-handle-kind handle)
                (compiler-symbol-kind-extern))]
            [(NoneI64) false]))])))

(define (lower-c-abi-integer-field-type? [ctx : TcContext] [ty : AstType]) : bool
  (match (tc-type-strip-region (tc-resolve-type ctx ty))
    [(AstTyI64) true]
    [(AstTyU64) true]
    [(AstTyI32) true]
    [(AstTyU32) true]
    [(AstTyI16) true]
    [(AstTyU16) true]
    [(AstTyI8) true]
    [(AstTyU8) true]
    [(AstTyBool) true]
    [(AstTyChar) true]
    [(AstTyPtr _) true]
    [(AstTyMutPtr _) true]
    [_ false]))

(define (lower-c-abi-inline-fields-integer-only?
  [ctx : TcContext]
  [fields : TcInlineFieldLayoutList]) : bool
  (match fields
    [(TcInlineFieldLayoutNil) true]
    [(TcInlineFieldLayoutCons field rest)
      (and
        (lower-c-abi-integer-field-type?
          ctx
          (tc-inline-field-layout-type field))
        (lower-c-abi-inline-fields-integer-only? ctx (box-get rest)))]))

(define (lower-c-abi-integer-scalar-type [size : i64]) : AstType
  (cond
    [(<= size 1) (AstTyU8)]
    [(<= size 2) (AstTyU16)]
    [(<= size 4) (AstTyU32)]
    [else (AstTyU64)]))

(define (lower-c-abi-target-name [mode : CompilerLowerMode]) : String
  (if (lower-mode-windows-c-abi? mode)
    "windows-x86_64"
    "linux-x86_64"))

(define (lower-c-abi-register-aggregate-size?
  [mode : CompilerLowerMode]
  [size : i64]) : bool
  (if (lower-mode-windows-c-abi? mode)
    (or (= size 1) (or (= size 2) (or (= size 4) (= size 8))))
    (and (> size 0) (<= size 8))))

(define (lower-c-abi-aggregate-size-message [mode : CompilerLowerMode]) : String
  (if (lower-mode-windows-c-abi? mode)
    "integer-only structs of size 1, 2, 4, or 8 bytes"
    "integer-only structs up to 8 bytes"))

(define (lower-c-abi-unsupported-message
  [mode : CompilerLowerMode]
  [ty : AstType]) : String
  (string-append
    (string-append "lower: unsupported " (lower-c-abi-target-name mode))
    (string-append
      " C aggregate ABI for "
      (string-append
        (tc-type-render ty)
        (string-append
          "; this slice supports "
          (lower-c-abi-aggregate-size-message mode))))))

(define (lower-c-abi-aggregate-class
  [ctx : TcContext]
  [mode : CompilerLowerMode]
  [ty : AstType]) : LowerCAbiAggregate
  (let
    [resolved : AstType (tc-type-without-regions (tc-resolve-type ctx ty))]
    (match resolved
      [(AstTyStruct name)
        (match (tc-inline-aggregate-layout-for ctx name)
          [(OkTcInlineAggregateLayout layout)
            (match layout
              [(TcInlineStructLayout size _ fields)
                (if (and
                  (lower-c-abi-register-aggregate-size? mode size)
                  (lower-c-abi-inline-fields-integer-only? ctx fields))
                  (LowerCAbiIntegerAggregate
                    (lower-c-abi-integer-scalar-type size)
                    size)
                  (LowerCAbiUnsupportedAggregate
                    (lower-c-abi-unsupported-message mode resolved)))]
              [(TcInlineEnumLayout _ _ _)
                (LowerCAbiUnsupportedAggregate
                  (lower-c-abi-unsupported-message mode resolved))])]
          [(ErrTcInlineAggregateLayout message)
            (LowerCAbiUnsupportedAggregate message)])]
      [(AstTyEnum _)
        (LowerCAbiUnsupportedAggregate
          (lower-c-abi-unsupported-message mode resolved))]
      [_ (LowerCAbiNoAggregate)])))

(define (lower-c-abi-args-as
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
      (let
        [arg : AstExpr (ast-node-get arg)]
        [rest-args : AstExprList (box-get rest-args)]
        (match types
          [(AstTypeCons expected rest-types)
            (let
              [expected : AstType (ty-node-get expected)]
              [rest-types : AstTypeList (box-get rest-types)]
              [arg-ty : AstType
                (tc-type-without-regions (tc-resolve-type ctx expected))]
              (match (lower-expr-expected ctx state env type-env arg arg-ty arg)
                [(OkLowerExpr lowered)
                  (match lowered
                    [(LowerExpr arg-state value _)
                      (match (lower-c-abi-aggregate-class
                        ctx
                        (lower-state-mode arg-state)
                        arg-ty)
                        [(LowerCAbiNoAggregate)
                          (match (lower-c-abi-args-as
                            ctx
                            arg-state
                            env
                            type-env
                            rest-args
                            rest-types)
                            [(OkLowerArgs rest-state rest-values)
                              (OkLowerArgs
                                rest-state
                                (compiler-ir-value-cons value rest-values))]
                            [(ErrLowerArgs message) (ErrLowerArgs message)])]
                        [(LowerCAbiIntegerAggregate scalar-ty _)
                          (match (lower-load-at-offset
                            arg-state
                            value
                            0
                            scalar-ty)
                            [(LowerExpr scalar-state scalar-value _)
                              (match (lower-c-abi-args-as
                                ctx
                                scalar-state
                                env
                                type-env
                                rest-args
                                rest-types)
                                [(OkLowerArgs rest-state rest-values)
                                  (OkLowerArgs
                                    rest-state
                                    (compiler-ir-value-cons
                                      scalar-value
                                      rest-values))]
                                [(ErrLowerArgs message) (ErrLowerArgs message)])])]
                        [(LowerCAbiUnsupportedAggregate message)
                          (ErrLowerArgs (lower-diagnostic-at-expr arg message))])])]
                [(ErrLowerExpr message) (ErrLowerArgs message)]))]
          [(AstTypeNil)
            (ErrLowerArgs
              (lower-diagnostic "lower: constructor arity mismatch"))]))]))

(define (lower-c-abi-finish-call-result
  [state : LowerState]
  [call-value : CompilerIrValue]
  [result-ty : AstType]
  [abi : LowerCAbiAggregate]
  [origin : AstExpr]) : ResultLowerExpr
  (match abi
    [(LowerCAbiNoAggregate)
      (OkLowerExpr (LowerExpr state call-value result-ty))]
    [(LowerCAbiIntegerAggregate scalar-ty size)
      (match (lower-reserve-heap-storage state size result-ty)
        [(LowerExpr base-state base _)
          (OkLowerExpr
            (LowerExpr
              (lower-store-at-offset base-state base 0 call-value scalar-ty)
              base
              result-ty))])]
    [(LowerCAbiUnsupportedAggregate message)
      (ErrLowerExpr (lower-diagnostic-at-expr origin message))]))

(define (lower-direct-c-abi-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [param-types : AstTypeList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match (lower-c-abi-args-as ctx state env type-env args param-types)
    [(OkLowerArgs args-state values)
      (match (lower-c-abi-aggregate-class
        ctx
        (lower-state-mode args-state)
        result-ty)
        [(LowerCAbiUnsupportedAggregate message)
          (ErrLowerExpr (lower-diagnostic-at-expr origin message))]
        [(LowerCAbiNoAggregate)
          (match (lower-state-alloc-var args-state)
            [(LowerAlloc allocated var-id)
              (let
                [instr : CompilerIrInstr
                  (IrInstrCall
                    var-id
                    (lower-resolve-call-name allocated env name)
                    (compiler-ir-call-args-from-list values)
                    result-ty)]
                (lower-c-abi-finish-call-result
                  (lower-state-emit-at-expr allocated instr origin)
                  (IrValueVar var-id)
                  result-ty
                  (LowerCAbiNoAggregate)
                  origin))])]
        [(LowerCAbiIntegerAggregate scalar-ty size)
          (match (lower-state-alloc-var args-state)
            [(LowerAlloc allocated var-id)
              (let
                [instr : CompilerIrInstr
                  (IrInstrCall
                    var-id
                    (lower-resolve-call-name allocated env name)
                    (compiler-ir-call-args-from-list values)
                    scalar-ty)]
                (lower-c-abi-finish-call-result
                  (lower-state-emit-at-expr allocated instr origin)
                  (IrValueVar var-id)
                  result-ty
                  (LowerCAbiIntegerAggregate scalar-ty size)
                  origin))])])]
    [(ErrLowerArgs message) (ErrLowerExpr message)]))

(define (lower-direct-call-values
  [state : LowerState]
  [env : SymI64Env]
  [name : String]
  [values : CompilerIrValueList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc allocated var-id)
      (let
        [instr : CompilerIrInstr
          (IrInstrCall
            var-id
            (lower-resolve-call-name allocated env name)
            (compiler-ir-call-args-from-list values)
            result-ty)]
        (OkLowerExpr
          (LowerExpr
            (lower-state-emit-at-expr allocated instr origin)
            (IrValueVar var-id)
            result-ty)))]))

(define (lower-direct-call-from-args
  [args-result : ResultLowerArgs]
  [env : SymI64Env]
  [name : String]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args-result
    [(OkLowerArgs args-state values)
      (lower-direct-call-values args-state env name values result-ty origin)]
    [(ErrLowerArgs message) (ErrLowerExpr message)]))

(define (lower-direct-call-param-types
  [ctx : TcContext]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [params : AstTypeList]) : ResultTcTypeList
  (match (tc-call-extern-abi-for-name ctx name)
    [(TcSomeExternAbi abi)
      (if (tc-call-dynamic-c-varargs-abi? abi)
        (tc-call-extern-varargs-params ctx type-env args params abi)
        (OkTcTypeList params))]
    [(TcNoExternAbi) (OkTcTypeList params)]))

(define (lower-direct-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match (lower-lookup-type (lower-state-type-cache state) env type-env name)
    [(OkTcType fn-ty)
      (match (tc-type-strip-region (tc-resolve-type ctx fn-ty))
        [(AstTyFunc param-types _)
          (match (lower-direct-call-param-types
            ctx
            type-env
            name
            args
            (tc-resolve-type-list ctx param-types))
            [(OkTcTypeList call-param-types)
              (if (lower-c-abi-extern-call? ctx state env name)
                (lower-direct-c-abi-call
                  ctx
                  state
                  env
                  type-env
                  name
                  args
                  call-param-types
                  result-ty
                  origin)
                (lower-direct-call-from-args
                  (lower-args-as ctx state env type-env args call-param-types)
                  env
                  name
                  result-ty
                  origin))]
            [(ErrTcTypeList message)
              (ErrLowerExpr (lower-diagnostic-at-expr origin message))])]
        [_
          (lower-direct-call-from-args
            (lower-args ctx state env type-env args)
            env
            name
            result-ty
            origin)])]
    [(ErrTcType _)
      (lower-direct-call-from-args
        (lower-args ctx state env type-env args)
        env
        name
        result-ty
        origin)]))

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
          (IrInstrCallIndirect
            var-id
            func-value
            (compiler-ir-call-args-from-list values)
            result-ty)]
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
    [(AstExprCons str tail)
      (let
        [str : AstExpr (ast-node-get str)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons start rest1)
            (let
              [start : AstExpr (ast-node-get start)]
              [rest1 : AstExprList (box-get rest1)]
              (match rest1
                [(AstExprCons len rest2)
                  (let
                    [len : AstExpr (ast-node-get len)]
                    [rest2 : AstExprList (box-get rest2)]
                    (match rest2
                      [(AstExprNil)
                        (lower-substring ctx state env type-env str start len)]
                      [_
                        (lower-direct-call
                          ctx
                          state
                          env
                          type-env
                          name
                          args
                          result-ty
                          origin)]))]
                [_
                  (lower-direct-call
                    ctx
                    state
                    env
                    type-env
                    name
                    args
                    result-ty
                    origin)]))]
          [_
            (lower-direct-call
              ctx
              state
              env
              type-env
              name
              args
              result-ty
              origin)]))]
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
    [(AstExprCons left tail)
      (let
        [left : AstExpr (ast-node-get left)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons right rest)
            (let
              [right : AstExpr (ast-node-get right)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (lower-string-concat ctx state env type-env left right)]
                [_
                  (lower-direct-call
                    ctx
                    state
                    env
                    type-env
                    name
                    args
                    result-ty
                    origin)]))]
          [_
            (lower-direct-call
              ctx
              state
              env
              type-env
              name
              args
              result-ty
              origin)]))]
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
            (IrInstrCall
              var-id
              name
              (compiler-ir-call-args-from-list values)
              result-ty))
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
    [(AstExprCons arg tail)
      (let
        [arg : AstExpr (ast-node-get arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprNil)
            (match (lower-expr ctx state env type-env arg)
              [(OkLowerExpr lowered)
                (match lowered
                  [(LowerExpr arg-state arg-value arg-ty)
                    (match (lower-cast-value
                      arg-state
                      arg-value
                      arg-ty
                      expected-ty)
                      [(LowerExpr cast-state cast-value _)
                        (lower-runtime-call-values
                          cast-state
                          runtime-name
                          (compiler-ir-value-cons cast-value IrValueNil)
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
              origin)]))]
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
                  (compiler-ir-value-cons
                    ptr
                    (compiler-ir-value-cons len IrValueNil))
                  result-ty)])
            (ErrLowerExpr (lower-diagnostic-at-expr arg message)))])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-one-string-object-runtime-call
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
            (lower-runtime-call-values
              arg-state
              runtime-name
              (compiler-ir-value-cons arg-value IrValueNil)
              result-ty)
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
                                (compiler-ir-value-cons
                                  left-ptr
                                  (compiler-ir-value-cons
                                    left-len
                                    (compiler-ir-value-cons
                                      right-ptr
                                      (compiler-ir-value-cons
                                        right-len
                                        IrValueNil))))
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
    [(AstExprCons arg tail)
      (let
        [arg : AstExpr (ast-node-get arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprNil)
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
              origin)]))]
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
    [(AstExprCons arg tail)
      (let
        [arg : AstExpr (ast-node-get arg)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprNil)
            (match (lower-expr ctx state env type-env arg)
              [(OkLowerExpr lowered)
                (match lowered
                  [(LowerExpr arg-state arg-value arg-ty)
                    (match (lower-cast-value
                      arg-state
                      arg-value
                      arg-ty
                      (AstTyI64))
                      [(LowerExpr cast-state cast-value _)
                        (lower-runtime-call-values
                          cast-state
                          "tl_int_to_string"
                          (compiler-ir-value-cons cast-value IrValueNil)
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
              origin)]))]
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

(define (lower-string-eq-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons left tail)
      (let
        [left : AstExpr (ast-node-get left)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons right rest)
            (let
              [right : AstExpr (ast-node-get right)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (lower-expr ctx state env type-env left)
                    [(OkLowerExpr lowered-left)
                      (match lowered-left
                        [(LowerExpr left-state left-value _)
                          (match (lower-expr ctx left-state env type-env right)
                            [(OkLowerExpr lowered-right)
                              (match lowered-right
                                [(LowerExpr right-state right-value _)
                                  (match (lower-string-fields
                                    right-state
                                    left-value)
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
                                          (lower-runtime-call-values
                                            done-fields-state
                                            "tl_string_eq"
                                            (compiler-ir-value-cons
                                              left-ptr
                                              (compiler-ir-value-cons
                                                left-len
                                                (compiler-ir-value-cons
                                                  right-ptr
                                                  (compiler-ir-value-cons
                                                    right-len
                                                    IrValueNil))))
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
                    origin)]))]
          [_
            (lower-direct-call
              ctx
              state
              env
              type-env
              "string-eq"
              args
              result-ty
              origin)]))]
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
    [else (lower-direct-call ctx state env type-env name args result-ty origin)]))

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
    [(AstExprCons str tail)
      (let
        [str : AstExpr (ast-node-get str)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons index rest)
            (let
              [index : AstExpr (ast-node-get index)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (lower-string-ref ctx state env type-env str index)]
                [_
                  (lower-direct-call
                    ctx
                    state
                    env
                    type-env
                    name
                    args
                    result-ty
                    origin)]))]
          [_
            (lower-direct-call
              ctx
              state
              env
              type-env
              name
              args
              result-ty
              origin)]))]
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
        [source-name : String (lower-hygiene-source-name name)]
        [symbols : CompilerSymbols (tc-context-symbols ctx)]
        [registries : CompilerRegistries (tc-context-registries ctx)]
        [variant-name : String
          (lower-variant-constructor-lookup-name ctx source-name result-ty)]
        [struct-name : String
          (match (tc-type-strip-region result-ty)
            [(AstTyStruct resolved-struct)
              (if (lower-call-name-matches-nominal?
                ctx
                source-name
                resolved-struct)
                resolved-struct
                (lower-module-lookup-name ctx source-name))]
            [_ (lower-module-lookup-name ctx source-name)])]
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
    [(AstExprLambda params maybe-ret body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (tc-lambda-expr-allow-ref-captures
          ctx
          type-env
          params
          maybe-ret
          body)
          [(OkTcType fn-ty)
            (match (lower-lambda
              ctx
              state
              env
              type-env
              params
              maybe-ret
              body
              func
              fn-ty)
              [(OkLowerExpr lowered-func)
                (match lowered-func
                  [(LowerExpr func-state func-value _)
                    (lower-indirect-call
                      ctx
                      func-state
                      env
                      type-env
                      func-value
                      args
                      result-ty
                      origin)])]
              [(ErrLowerExpr message) (ErrLowerExpr message)])]
          [(ErrTcType message)
            (ErrLowerExpr (lower-diagnostic-at-expr func message))]))]
    [(AstExprVar raw-name)
      ;; Builtins reached from a macro expansion arrive hygiene-renamed
      ;; (`__tl_macro_global$string-length`); strip the prefix so the builtin
      ;; dispatch below (length/string-length inline loads, etc.) fires just as it
      ;; does for hand-written calls. `raw-name` still keys the local-variable
      ;; lookup, and the generic call path strips the prefix itself.
      (let
        [name : String (lower-hygiene-source-name (intern-str raw-name))]
        (match (sym-i64-lookup env (intern-str raw-name))
          [(SomeI64 local-id)
            (match (tc-lookup type-env (intern-str raw-name))
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
            (let
              [builtin-available : bool
                (not (lower-top-level-value-defined? ctx name))]
              (cond
                [(and builtin-available (tc-layout-query-name? name))
                  (ErrLowerExpr
                    (lower-diagnostic-at-expr
                      origin
                      (string-append
                        "lower: "
                        (string-append
                          name
                          " is compile-time only; wrap it in (comptime ...)"))))]
                [(and
                    builtin-available
                    (or
                      (string-eq name "string-ref")
                      (string-eq name "char-at")))
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
                    builtin-available
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
                [(and builtin-available (lower-string-runtime-builtin? name))
                  (lower-string-runtime-call
                    ctx
                    state
                    env
                    type-env
                    name
                    args
                    result-ty
                    origin)]
                [(and builtin-available (string-eq name "cpuid"))
                  (lower-cpuid-call
                    ctx
                    state
                    env
                    type-env
                    args
                    result-ty
                    origin)]
                [(and builtin-available (string-eq name "xgetbv"))
                  (lower-xgetbv-call ctx state env type-env args origin)]
                [(and builtin-available (string-eq name "clone"))
                  (match args
                    [(AstExprCons arg tail)
                      (let
                        [arg : AstExpr (ast-node-get arg)]
                        [tail : AstExprList (box-get tail)]
                        (match tail
                          [(AstExprNil)
                            (lower-clone-call ctx state env type-env arg)]
                          [_
                            (ErrLowerExpr
                              (lower-diagnostic
                                "lower: clone expects one argument"))]))]
                    [_
                      (ErrLowerExpr
                        (lower-diagnostic "lower: clone expects one argument"))])]
                [(and builtin-available (lower-arena-builtin? name))
                  (lower-arena-builtin-call
                    ctx
                    state
                    env
                    type-env
                    name
                    args
                    result-ty)]
                [(and builtin-available (lower-bootstrap-runtime-builtin? name))
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
                    origin)]))]))]
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
    [(AstExprCons arr tail)
      (let
        [arr : AstExpr (ast-node-get arr)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprNil)
            (match (lower-expr-result-type-fast
              ctx
              env
              type-env
              (lower-state-type-cache state)
              arr)
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
          [_
            (lower-direct-call
              ctx
              state
              env
              type-env
              name
              args
              result-ty
              origin)]))]
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
        (lower-direct-call ctx state env type-env name args result-ty origin))]))

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

(define (lower-string-data
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [str : AstExpr]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env str)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr str-state str-value _)
          (match (lower-load-at-offset str-state str-value 0 result-ty)
            [(LowerExpr data-state data-value _)
              (OkLowerExpr (LowerExpr data-state data-value result-ty))])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-array-data
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [array : AstExpr]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env array)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr array-state array-value array-ty)
          (match (tc-type-strip-region (tc-resolve-type ctx array-ty))
            [(AstTyDynArray _)
              (match (lower-load-at-offset array-state array-value 0 result-ty)
                [(LowerExpr data-state data-value _)
                  (OkLowerExpr (LowerExpr data-state data-value result-ty))])]
            [(AstTyArray _ _)
              (OkLowerExpr
                (lower-cast-value array-state array-value array-ty result-ty))]
            [_
              (ErrLowerExpr
                (lower-diagnostic "lower: array-data requires array"))])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-string-from-bytes
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [ptr : AstExpr]
  [len : AstExpr]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env ptr)
    [(OkLowerExpr ptr-lowered)
      (match ptr-lowered
        [(LowerExpr ptr-state ptr-value ptr-ty)
          (match (lower-expr ctx ptr-state env type-env len)
            [(OkLowerExpr len-lowered)
              (match len-lowered
                [(LowerExpr len-state len-value len-ty)
                  (match (lower-cast-value
                    len-state
                    len-value
                    len-ty
                    (AstTyI64))
                    [(LowerExpr len-i-state len-i-value _)
                      (match (lower-reserve-heap-storage
                        len-i-state
                        16
                        (AstTyString))
                        [(LowerExpr base-state base-value _)
                          (let
                            [with-ptr : LowerState
                              (lower-store-at-offset
                                base-state
                                base-value
                                0
                                ptr-value
                                (lower-raw-pointer-ir-type ptr-ty))]
                            [with-len : LowerState
                              (lower-store-at-offset
                                with-ptr
                                base-value
                                8
                                len-i-value
                                (AstTyI64))]
                            (OkLowerExpr
                              (LowerExpr with-len base-value (AstTyString))))])])])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-entry-load
  [state : LowerState]
  [kind : i64]
  [result-ty : AstType]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc allocated var-id)
      (let
        [instr : CompilerIrInstr
          (cond
            [(= kind 0) (IrInstrEntryArgc var-id)]
            [(= kind 1) (IrInstrEntryArgv var-id)]
            [else (IrInstrEntryEnvp var-id)])]
        (OkLowerExpr
          (LowerExpr
            (lower-state-emit allocated instr)
            (IrValueVar var-id)
            result-ty)))]))

(define (lower-cpuid-like
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [leaf : AstExpr]
  [subleaf : AstExpr]
  [reg-index : i64]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env leaf)
    [(OkLowerExpr leaf-lowered)
      (match leaf-lowered
        [(LowerExpr leaf-state leaf-value leaf-ty)
          (match (lower-cast-value leaf-state leaf-value leaf-ty (AstTyI64))
            [(LowerExpr leaf-i-state leaf-i-value _)
              (match (lower-expr ctx leaf-i-state env type-env subleaf)
                [(OkLowerExpr subleaf-lowered)
                  (match subleaf-lowered
                    [(LowerExpr subleaf-state subleaf-value subleaf-ty)
                      (match (lower-cast-value
                        subleaf-state
                        subleaf-value
                        subleaf-ty
                        (AstTyI64))
                        [(LowerExpr subleaf-i-state subleaf-i-value _)
                          (match (lower-state-alloc-var subleaf-i-state)
                            [(LowerAlloc allocated var-id)
                              (OkLowerExpr
                                (LowerExpr
                                  (lower-state-emit
                                    allocated
                                    (IrInstrCpuId
                                      var-id
                                      leaf-i-value
                                      subleaf-i-value
                                      reg-index))
                                  (IrValueVar var-id)
                                  (AstTyI64)))])])])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-xgetbv
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : AstExpr]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env index)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr index-state index-value index-ty)
          (match (lower-cast-value index-state index-value index-ty (AstTyI64))
            [(LowerExpr index-i-state index-i-value _)
              (match (lower-state-alloc-var index-i-state)
                [(LowerAlloc allocated var-id)
                  (OkLowerExpr
                    (LowerExpr
                      (lower-state-emit
                        allocated
                        (IrInstrXgetbv var-id index-i-value))
                      (IrValueVar var-id)
                      (AstTyI64)))])])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-cpuid-store-field
  [state : LowerState]
  [base : CompilerIrValue]
  [leaf : CompilerIrValue]
  [subleaf : CompilerIrValue]
  [reg-index : i64]
  [offset : i64]) : LowerState
  (match (lower-state-alloc-var state)
    [(LowerAlloc allocated var-id)
      (lower-store-at-offset
        (lower-state-emit
          allocated
          (IrInstrCpuId var-id leaf subleaf reg-index))
        base
        offset
        (IrValueVar var-id)
        (AstTyI32))]))

(define (lower-cpuid-tuple-values
  [ctx : TcContext]
  [state : LowerState]
  [leaf : CompilerIrValue]
  [subleaf : CompilerIrValue]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match (tc-resolve-type ctx result-ty)
    [(AstTyTuple elem-tys)
      (match (lower-reserve-heap-storage
        state
        (lower-type-list-storage-size ctx elem-tys)
        result-ty)
        [(LowerExpr base-state base _)
          (let
            [eax-state : LowerState
              (lower-cpuid-store-field base-state base leaf subleaf 0 0)]
            [ebx-state : LowerState
              (lower-cpuid-store-field eax-state base leaf subleaf 1 4)]
            [ecx-state : LowerState
              (lower-cpuid-store-field ebx-state base leaf subleaf 2 8)]
            [edx-state : LowerState
              (lower-cpuid-store-field ecx-state base leaf subleaf 3 12)]
            (OkLowerExpr (LowerExpr edx-state base result-ty)))])]
    [_
      (ErrLowerExpr
        (lower-diagnostic-at-expr origin "lower: cpuid requires tuple result"))]))

(define (lower-cpuid-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [result-ty : AstType]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons leaf tail)
      (let
        [leaf : AstExpr (ast-node-get leaf)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprCons subleaf rest)
            (let
              [subleaf : AstExpr (ast-node-get subleaf)]
              [rest : AstExprList (box-get rest)]
              (match rest
                [(AstExprNil)
                  (match (lower-expr ctx state env type-env leaf)
                    [(OkLowerExpr leaf-lowered)
                      (match leaf-lowered
                        [(LowerExpr leaf-state leaf-value leaf-ty)
                          (match (lower-cast-value
                            leaf-state
                            leaf-value
                            leaf-ty
                            (AstTyI64))
                            [(LowerExpr leaf-i-state leaf-i-value _)
                              (match (lower-expr
                                ctx
                                leaf-i-state
                                env
                                type-env
                                subleaf)
                                [(OkLowerExpr subleaf-lowered)
                                  (match subleaf-lowered
                                    [(LowerExpr
                                        subleaf-state
                                        subleaf-value
                                        subleaf-ty)
                                      (match (lower-cast-value
                                        subleaf-state
                                        subleaf-value
                                        subleaf-ty
                                        (AstTyI64))
                                        [(LowerExpr
                                            subleaf-i-state
                                            subleaf-i-value
                                            _)
                                          (lower-cpuid-tuple-values
                                            ctx
                                            subleaf-i-state
                                            leaf-i-value
                                            subleaf-i-value
                                            result-ty
                                            origin)])])]
                                [(ErrLowerExpr message) (ErrLowerExpr message)])])])]
                    [(ErrLowerExpr message) (ErrLowerExpr message)])]
                [_
                  (ErrLowerExpr
                    (lower-diagnostic "lower: cpuid expects two arguments"))]))]
          [_
            (ErrLowerExpr
              (lower-diagnostic "lower: cpuid expects two arguments"))]))]
    [_ (ErrLowerExpr (lower-diagnostic "lower: cpuid expects two arguments"))]))

(define (lower-xgetbv-call
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]
  [origin : AstExpr]) : ResultLowerExpr
  (match args
    [(AstExprCons index tail)
      (let
        [index : AstExpr (ast-node-get index)]
        [tail : AstExprList (box-get tail)]
        (match tail
          [(AstExprNil) (lower-xgetbv ctx state env type-env index)]
          [_
            (ErrLowerExpr
              (lower-diagnostic-at-expr
                origin
                "lower: xgetbv expects one argument"))]))]
    [_
      (ErrLowerExpr
        (lower-diagnostic-at-expr origin "lower: xgetbv expects one argument"))]))

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

(define (lower-init-default-share-safe-type-list?
  [ctx : TcContext]
  [types : AstTypeList]) : bool
  (match types
    [(AstTypeNil) true]
    [(AstTypeCons head rest)
      (let
        [head : AstType (ty-node-get head)]
        [rest : AstTypeList (box-get rest)]
        (if (lower-init-default-share-safe? ctx head)
          (lower-init-default-share-safe-type-list? ctx rest)
          false))]))

(define (lower-init-default-share-safe-struct?
  [ctx : TcContext]
  [struct-name : String]
  [struct-ty : AstType]) : bool
  (match (tc-struct-decl ctx struct-name)
    [(OkTcStructDecl decl)
      (match decl
        [(TcStructDecl repr cleanup fields)
          (if (ast-struct-repr-c? repr)
            false
            (if (ast-struct-cleanup? cleanup)
              false
              (let
                [field-types : AstTypeList
                  (tc-resolve-type-list
                    ctx
                    (lower-struct-constructor-field-types-for-result
                      ctx
                      struct-name
                      struct-ty
                      fields))]
                (lower-init-default-share-safe-type-list? ctx field-types))))])]
    [(ErrTcStructDecl _) false]))

(define (lower-init-default-share-safe-enum?
  [ctx : TcContext]
  [enum-name : String]
  [enum-ty : AstType]) : bool
  (match (tc-enum-decl ctx enum-name)
    [(OkTcEnumDecl decl)
      (match decl
        [(TcEnumDecl cleanup variants)
          (if (ast-enum-cleanup? cleanup)
            false
            (match variants
              [(AstVariantDefNil) false]
              [(AstVariantDefCons variant _)
                (match variant
                  [(AstVariantDef _ fields _)
                    (let
                      [field-types : AstTypeList
                        (tc-resolve-type-list
                          ctx
                          (lower-enum-constructor-fields-for-result
                            ctx
                            enum-name
                            enum-ty
                            fields))]
                      (lower-init-default-share-safe-type-list? ctx field-types))])]))])]
    [(ErrTcEnumDecl _) false]))

(define (lower-init-default-share-safe? [ctx : TcContext] [ty : AstType]) : bool
  (let
    [resolved : AstType (tc-type-without-regions (tc-resolve-type ctx ty))]
    (if (tc-integer-type? resolved)
      true
      (match resolved
        [(AstTyF64) true]
        [(AstTyF32) true]
        [(AstTyBool) true]
        [(AstTyChar) true]
        [(AstTyUnit) true]
        [(AstTyString) true]
        [(AstTyPtr _) true]
        [(AstTyMutPtr _) true]
        [(AstTyTuple elems)
          (lower-init-default-share-safe-type-list? ctx elems)]
        [(AstTyStruct name)
          (lower-init-default-share-safe-struct? ctx name resolved)]
        [(AstTyStructArgs name _)
          (lower-init-default-share-safe-struct? ctx name resolved)]
        [(AstTyEnum name)
          (lower-init-default-share-safe-enum? ctx name resolved)]
        [(AstTyEnumArgs name _)
          (lower-init-default-share-safe-enum? ctx name resolved)]
        [_ false]))))

(define (lower-make-array-init-advance
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

(define (lower-make-array-store-init-body
  [state : LowerState]
  [buf-value : CompilerIrValue]
  [index-var : i64]
  [header-label : String]
  [exit-label : String]
  [elem-ty : AstType]
  [init-value : CompilerIrValue]) : ResultLowerState
  (match (lower-emit-gep state buf-value (IrValueVar index-var) elem-ty)
    [(LowerExpr gep-state elem-ptr _)
      (lower-make-array-init-advance
        (lower-state-emit
          gep-state
          (IrInstrStorePtr elem-ptr init-value elem-ty))
        index-var
        header-label
        exit-label)]))

(define (lower-make-array-init-body
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [buf-value : CompilerIrValue]
  [index-var : i64]
  [header-label : String]
  [exit-label : String]
  [elem-ty : AstType]
  [origin : AstExpr]) : ResultLowerState
  (match (lower-init-expr ctx state env type-env elem-ty origin elem-ty)
    [(OkLowerExpr lowered-init)
      (match lowered-init
        [(LowerExpr init-state init-value _)
          (match (lower-emit-gep
            init-state
            buf-value
            (IrValueVar index-var)
            elem-ty)
            [(LowerExpr gep-state elem-ptr _)
              (lower-make-array-init-advance
                (lower-state-emit
                  gep-state
                  (IrInstrStorePtr elem-ptr init-value elem-ty))
                index-var
                header-label
                exit-label)])])]
    [(ErrLowerExpr message) (ErrLowerState message)]))

(define (lower-make-array-init-loop-with-labels
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [buf-value : CompilerIrValue]
  [len-i64 : CompilerIrValue]
  [elem-ty : AstType]
  [origin : AstExpr]
  [header-label : String]
  [body-label : String]
  [exit-label : String]) : ResultLowerState
  (match (lower-state-alloc-var state)
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
        (match (lower-emit-binop
          header-start
          IrBinLt
          (IrValueVar index-var)
          len-i64
          (AstTyBool))
          [(LowerExpr cond-state cond-value _)
            (let
              [body-start : LowerState
                (lower-state-finish-block
                  (lower-state-emit
                    cond-state
                    (IrInstrBranch cond-value body-label exit-label))
                  body-label)]
              (lower-make-array-init-body
                ctx
                body-start
                env
                type-env
                buf-value
                index-var
                header-label
                exit-label
                elem-ty
                origin))]))]))

(define (lower-make-array-store-init-loop-with-labels
  [state : LowerState]
  [buf-value : CompilerIrValue]
  [len-i64 : CompilerIrValue]
  [elem-ty : AstType]
  [init-value : CompilerIrValue]
  [header-label : String]
  [body-label : String]
  [exit-label : String]) : ResultLowerState
  (match (lower-state-alloc-var state)
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
        (match (lower-emit-binop
          header-start
          IrBinLt
          (IrValueVar index-var)
          len-i64
          (AstTyBool))
          [(LowerExpr cond-state cond-value _)
            (let
              [body-start : LowerState
                (lower-state-finish-block
                  (lower-state-emit
                    cond-state
                    (IrInstrBranch cond-value body-label exit-label))
                  body-label)]
              (lower-make-array-store-init-body
                body-start
                buf-value
                index-var
                header-label
                exit-label
                elem-ty
                init-value))]))]))

(define (lower-make-array-init-loop-runtime
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [buf-value : CompilerIrValue]
  [len-i64 : CompilerIrValue]
  [elem-ty : AstType]
  [elem-size : i64]
  [origin : AstExpr]) : ResultLowerState
  (if (= elem-size 0)
    (OkLowerState state)
    (match (lower-state-fresh-label state "make_array_init_header")
      [(LowerLabel header-label-state header-label)
        (match (lower-state-fresh-label
          header-label-state
          "make_array_init_body")
          [(LowerLabel body-label-state body-label)
            (match (lower-state-fresh-label
              body-label-state
              "make_array_init_exit")
              [(LowerLabel exit-label-state exit-label)
                (lower-make-array-init-loop-with-labels
                  ctx
                  exit-label-state
                  env
                  type-env
                  buf-value
                  len-i64
                  elem-ty
                  origin
                  header-label
                  body-label
                  exit-label)])])])))

(define (lower-make-array-store-init-loop-runtime
  [state : LowerState]
  [buf-value : CompilerIrValue]
  [len-i64 : CompilerIrValue]
  [elem-ty : AstType]
  [elem-size : i64]
  [init-value : CompilerIrValue]) : ResultLowerState
  (if (= elem-size 0)
    (OkLowerState state)
    (match (lower-state-fresh-label state "make_array_init_header")
      [(LowerLabel header-label-state header-label)
        (match (lower-state-fresh-label
          header-label-state
          "make_array_init_body")
          [(LowerLabel body-label-state body-label)
            (match (lower-state-fresh-label
              body-label-state
              "make_array_init_exit")
              [(LowerLabel exit-label-state exit-label)
                (lower-make-array-store-init-loop-with-labels
                  exit-label-state
                  buf-value
                  len-i64
                  elem-ty
                  init-value
                  header-label
                  body-label
                  exit-label)])])])))

(define (lower-make-array-fill8
  [state : LowerState]
  [buf-value : CompilerIrValue]
  [len-i64 : CompilerIrValue]
  [init-value : CompilerIrValue]) : ResultLowerState
  (match (lower-runtime-call-values
    state
    "tl_array_fill8"
    (compiler-ir-value-cons
      buf-value
      (compiler-ir-value-cons
        len-i64
        (compiler-ir-value-cons init-value IrValueNil)))
    (AstTyUnit))
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr done-state _ _) (OkLowerState done-state)])]
    [(ErrLowerExpr message) (ErrLowerState message)]))

(define (lower-make-array-fill8-supported? [ctx : TcContext] [ty : AstType]) : bool
  (let
    [resolved : AstType (tc-type-without-regions (tc-resolve-type ctx ty))]
    (and
      (= (lower-type-size ctx resolved) 8)
      (and
        (not (tc-type-eq resolved (AstTyF64)))
        (lower-init-default-share-safe? ctx resolved)))))

(define (lower-make-array-zero-fill-supported? [ctx : TcContext] [ty : AstType]) : bool
  (let
    [resolved : AstType (tc-type-without-regions (tc-resolve-type ctx ty))]
    (if (tc-integer-type? resolved)
      true
      (match resolved
        [(AstTyF64) true]
        [(AstTyF32) true]
        [(AstTyBool) true]
        [(AstTyChar) true]
        [(AstTyUnit) true]
        [(AstTyPtr _) true]
        [(AstTyMutPtr _) true]
        [_ false]))))

(define (lower-make-array-zero-fill
  [state : LowerState]
  [buf-value : CompilerIrValue]
  [byte-count : CompilerIrValue]) : ResultLowerState
  (match (lower-runtime-call-values
    state
    "tl_array_zero"
    (compiler-ir-value-cons
      buf-value
      (compiler-ir-value-cons byte-count IrValueNil))
    (AstTyUnit))
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr done-state _ _) (OkLowerState done-state)])]
    [(ErrLowerExpr message) (ErrLowerState message)]))

(define (lower-make-array-zero-literal-length? [len : AstExpr]) : bool
  (match (ast-expr-unspan len)
    [(AstExprLiteral (AstLitInt value)) (= value 0)]
    [_ false]))

(define (lower-make-array-init-loop-nonzero
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [buf-value : CompilerIrValue]
  [len-i64 : CompilerIrValue]
  [byte-count : CompilerIrValue]
  [elem-ty : AstType]
  [elem-size : i64]
  [origin : AstExpr]) : ResultLowerState
  (cond
    [(= elem-size 0) (OkLowerState state)]
    [(lower-make-array-zero-fill-supported? ctx elem-ty)
      (lower-make-array-zero-fill state buf-value byte-count)]
    [(lower-init-default-share-safe? ctx elem-ty)
      (match (lower-init-expr ctx state env type-env elem-ty origin elem-ty)
        [(OkLowerExpr lowered-init)
          (match lowered-init
            [(LowerExpr init-state init-value _)
              (if (lower-make-array-fill8-supported? ctx elem-ty)
                (lower-make-array-fill8 init-state buf-value len-i64 init-value)
                (lower-make-array-store-init-loop-runtime
                  init-state
                  buf-value
                  len-i64
                  elem-ty
                  elem-size
                  init-value))])]
        [(ErrLowerExpr message) (ErrLowerState message)])]
    [else
      (lower-make-array-init-loop-runtime
        ctx
        state
        env
        type-env
        buf-value
        len-i64
        elem-ty
        elem-size
        origin)]))

(define (lower-make-array-init-loop
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [buf-value : CompilerIrValue]
  [len-i64 : CompilerIrValue]
  [byte-count : CompilerIrValue]
  [elem-ty : AstType]
  [elem-size : i64]
  [zero-literal-length : bool]
  [origin : AstExpr]) : ResultLowerState
  (if zero-literal-length
    (OkLowerState state)
    (match len-i64
      [(IrValueI64 literal-len)
        (if (= literal-len 0)
          (OkLowerState state)
          (lower-make-array-init-loop-nonzero
            ctx
            state
            env
            type-env
            buf-value
            len-i64
            byte-count
            elem-ty
            elem-size
            origin))]
      [_
        (lower-make-array-init-loop-nonzero
          ctx
          state
          env
          type-env
          buf-value
          len-i64
          byte-count
          elem-ty
          elem-size
          origin)])))

(define (lower-make-array-alloc-buffer
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [arr-ty : AstType]
  [len-i64 : CompilerIrValue]
  [elem-ty : AstType]
  [elem-size : i64]
  [zero-literal-length : bool]
  [origin : AstExpr]) : ResultLowerExpr
  (match (lower-emit-binop
    state
    (IrBinMul)
    len-i64
    (IrValueI64 elem-size)
    (AstTyI64))
    [(LowerExpr byte-state byte-count _)
      (match (lower-state-alloc-var byte-state)
        [(LowerAlloc buf-alloc buf-var)
          (let
            [alloc-state : LowerState
              (lower-state-emit
                buf-alloc
                (IrInstrCall
                  buf-var
                  "tl_alloc"
                  (IrCallArgsOne byte-count)
                  (AstTyU64)))]
            (match (lower-make-array-init-loop
              ctx
              alloc-state
              env
              type-env
              (IrValueVar buf-var)
              len-i64
              byte-count
              elem-ty
              elem-size
              zero-literal-length
              origin)
              [(OkLowerState init-state)
                (lower-make-array-store-fat init-state arr-ty buf-var len-i64)]
              [(ErrLowerState message) (ErrLowerExpr message)]))])]))

(define (lower-make-array-after-max-check
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [fail-label : String]
  [alloc-label : String]
  [arr-ty : AstType]
  [len-i64 : CompilerIrValue]
  [elem-ty : AstType]
  [elem-size : i64]
  [zero-literal-length : bool]
  [origin : AstExpr]) : ResultLowerExpr
  (let
    [fail-start : LowerState (lower-state-finish-block state fail-label)]
    [alloc-start : LowerState
      (lower-state-finish-block
        (lower-state-emit
          (lower-oob-abort fail-start)
          (IrInstrJump alloc-label))
        alloc-label)]
    (lower-make-array-alloc-buffer
      ctx
      alloc-start
      env
      type-env
      arr-ty
      len-i64
      elem-ty
      elem-size
      zero-literal-length
      origin)))

(define (lower-make-array-from-len
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [elem-ty : AstType]
  [len-value : CompilerIrValue]
  [len-ty : AstType]
  [len-expr : AstExpr]
  [origin : AstExpr]) : ResultLowerExpr
  (let
    [resolved-elem : AstType (tc-resolve-type ctx elem-ty)]
    (match (lower-cast-value state len-value len-ty (AstTyI64))
      [(LowerExpr len-state len-i64 _)
        (let
          [elem-size : i64 (lower-type-size ctx resolved-elem)]
          [arr-ty : AstType (ast-ty-dyn-array resolved-elem)]
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
                                  ctx
                                  (lower-state-emit
                                    s5
                                    (IrInstrBranch
                                      within-max
                                      alloc-label
                                      fail-label))
                                  env
                                  type-env
                                  fail-label
                                  alloc-label
                                  arr-ty
                                  len-i64
                                  resolved-elem
                                  elem-size
                                  (lower-make-array-zero-literal-length?
                                    len-expr)
                                  origin)]))])])])]))])))

(define (lower-make-array
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [elem-ty : AstType]
  [len : AstExpr]
  [origin : AstExpr]) : ResultLowerExpr
  (match (lower-expr ctx state env type-env len)
    [(OkLowerExpr lowered)
      (match lowered
        [(LowerExpr len-state len-value len-ty)
          (lower-make-array-from-len
            ctx
            len-state
            env
            type-env
            elem-ty
            len-value
            len-ty
            len
            origin)])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

;; `(array-ref arr index)` -> bounds-checked typed element load.
(define (lower-array-ref
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [arr : AstExpr]
  [index : AstExpr]) : ResultLowerExpr
  (match (lower-expr-result-type-or-check
    ctx
    env
    type-env
    (lower-state-type-cache state)
    arr)
    [(OkTcType arr-ty)
      (match (tc-array-readable-receiver ctx arr-ty)
        [(OkTcArrayReceiver receiver)
          (match receiver
            [(TcArrayReceiver container-ty elem-ty)
              (let
                [elem-ir-ty : AstType (tc-type-without-regions elem-ty)]
                (match (lower-expr ctx state env type-env arr)
                  [(OkLowerExpr arr-lowered)
                    (match arr-lowered
                      [(LowerExpr arr-state arr-value _)
                        (match (lower-index-result-type-or-check
                          ctx
                          env
                          type-env
                          (lower-state-type-cache arr-state)
                          index)
                          [(OkTcType idx-ty)
                            (match (lower-expr ctx arr-state env type-env index)
                              [(OkLowerExpr idx-lowered)
                                (match idx-lowered
                                  [(LowerExpr idx-state idx-value _)
                                    (match (tc-type-strip-region
                                      (tc-resolve-type ctx container-ty))
                                      [(AstTyDynArray _)
                                        (match (lower-array-element-addr
                                          idx-state
                                          arr-value
                                          idx-value
                                          idx-ty
                                          elem-ir-ty)
                                          [(LowerExpr addr-state elem-ptr _)
                                            (match (lower-emit-load
                                              addr-state
                                              elem-ptr
                                              elem-ir-ty)
                                              [(LowerExpr
                                                  load-state
                                                  load-value
                                                  _)
                                                (OkLowerExpr
                                                  (LowerExpr
                                                    load-state
                                                    load-value
                                                    elem-ir-ty))])])]
                                      [(AstTyArray _ elem-count)
                                        (match (lower-fixed-array-element-addr
                                          idx-state
                                          arr-value
                                          idx-value
                                          idx-ty
                                          elem-ir-ty
                                          elem-count)
                                          [(LowerExpr addr-state elem-ptr _)
                                            (if (=
                                              (lower-type-size ctx elem-ir-ty)
                                              0)
                                              (OkLowerExpr
                                                (LowerExpr
                                                  addr-state
                                                  IrValueUnit
                                                  elem-ir-ty))
                                              (match (lower-emit-load
                                                addr-state
                                                elem-ptr
                                                elem-ir-ty)
                                                [(LowerExpr
                                                    load-state
                                                    load-value
                                                    _)
                                                  (OkLowerExpr
                                                    (LowerExpr
                                                      load-state
                                                      load-value
                                                      elem-ir-ty))]))])]
                                      [_
                                        (ErrLowerExpr
                                          (lower-diagnostic-at-expr
                                            arr
                                            "lower: array-ref requires array type"))])])]
                              [(ErrLowerExpr message) (ErrLowerExpr message)])]
                          [(ErrTcType message)
                            (ErrLowerExpr
                              (lower-diagnostic-at-expr index message))])])]
                  [(ErrLowerExpr message) (ErrLowerExpr message)]))])]
        [(ErrTcArrayReceiver message)
          (ErrLowerExpr (lower-diagnostic-at-expr arr message))])]
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
  (match (lower-expr-result-type-or-check
    ctx
    env
    type-env
    (lower-state-type-cache state)
    arr)
    [(OkTcType arr-ty)
      (match (tc-array-set-receiver ctx arr-ty)
        [(OkTcArrayReceiver receiver)
          (match receiver
            [(TcArrayReceiver container-ty elem-ty)
              (let
                [elem-ir-ty : AstType (tc-type-without-regions elem-ty)]
                (match (lower-expr ctx state env type-env arr)
                  [(OkLowerExpr arr-lowered)
                    (match arr-lowered
                      [(LowerExpr arr-state arr-value _)
                        (match (lower-index-result-type-or-check
                          ctx
                          env
                          type-env
                          (lower-state-type-cache arr-state)
                          index)
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
                                            (match (tc-type-strip-region
                                              (tc-resolve-type ctx container-ty))
                                              [(AstTyDynArray _)
                                                (match (lower-array-element-addr
                                                  value-state
                                                  arr-value
                                                  idx-value
                                                  idx-ty
                                                  elem-ir-ty)
                                                  [(LowerExpr
                                                      addr-state
                                                      elem-ptr
                                                      _)
                                                    (OkLowerExpr
                                                      (LowerExpr
                                                        (lower-state-emit
                                                          addr-state
                                                          (IrInstrStorePtr
                                                            elem-ptr
                                                            value-ir
                                                            elem-ir-ty))
                                                        IrValueUnit
                                                        (AstTyUnit)))])]
                                              [(AstTyArray _ elem-count)
                                                (match (lower-fixed-array-element-addr
                                                  value-state
                                                  arr-value
                                                  idx-value
                                                  idx-ty
                                                  elem-ir-ty
                                                  elem-count)
                                                  [(LowerExpr
                                                      addr-state
                                                      elem-ptr
                                                      _)
                                                    (if (=
                                                      (lower-type-size
                                                        ctx
                                                        elem-ir-ty)
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
                                                              elem-ir-ty))
                                                          IrValueUnit
                                                          (AstTyUnit))))])]
                                              [_
                                                (ErrLowerExpr
                                                  (lower-diagnostic-at-expr
                                                    arr
                                                    "lower: array-set! requires array type"))])])]
                                      [(ErrLowerExpr message)
                                        (ErrLowerExpr message)])])]
                              [(ErrLowerExpr message) (ErrLowerExpr message)])]
                          [(ErrTcType message)
                            (ErrLowerExpr
                              (lower-diagnostic-at-expr index message))])])]
                  [(ErrLowerExpr message) (ErrLowerExpr message)]))])]
        [(ErrTcArrayReceiver message)
          (ErrLowerExpr (lower-diagnostic-at-expr arr message))])]
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
                    (IrCallArgsOne byte-count)
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
  (match (lower-expr-result-type-or-check
    ctx
    env
    type-env
    (lower-state-type-cache state)
    arr)
    [(OkTcType arr-ty)
      (match (tc-array-push-receiver ctx arr-ty)
        [(OkTcArrayReceiver receiver)
          (match receiver
            [(TcArrayReceiver _ elem-ty)
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
                  [(ErrLowerExpr message) (ErrLowerExpr message)]))])]
        [(ErrTcArrayReceiver message)
          (ErrLowerExpr (lower-diagnostic-at-expr arr message))])]
    [(ErrTcType message) (ErrLowerExpr (lower-diagnostic-at-expr arr message))]))

;; Lower each syscall operand and widen it to i64 (the kernel reads the full
;; 64-bit registers). Mirrors `lower-args` but inserts the cast.
(define (lower-syscall-args
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]) : ResultLowerArgs
  (match args
    [(AstExprNil) (OkLowerArgs state IrValueNil)]
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ast-node-get arg)]
        [rest : AstExprList (box-get rest)]
        (match (lower-expr ctx state env type-env arg)
          [(OkLowerExpr lowered)
            (match lowered
              [(LowerExpr arg-state value value-ty)
                (match (lower-cast-value arg-state value value-ty (AstTyI64))
                  [(LowerExpr cast-state cast-value _)
                    (match (lower-syscall-args ctx cast-state env type-env rest)
                      [(OkLowerArgs rest-state rest-values)
                        (OkLowerArgs
                          rest-state
                          (compiler-ir-value-cons cast-value rest-values))]
                      [(ErrLowerArgs message) (ErrLowerArgs message)])])])]
          [(ErrLowerExpr message) (ErrLowerArgs message)]))]))

(define (lower-syscall
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]) : ResultLowerExpr
  (match (lower-syscall-args ctx state env type-env args)
    [(OkLowerArgs args-state values)
      (match (lower-state-alloc-var args-state)
        [(LowerAlloc allocated var-id)
          (OkLowerExpr
            (LowerExpr
              (lower-state-emit
                allocated
                (IrInstrSyscall var-id (compiler-ir-call-args-from-list values)))
              (IrValueVar var-id)
              (AstTyI64)))])]
    [(ErrLowerArgs message) (ErrLowerExpr message)]))

(define (lower-args
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [args : AstExprList]) : ResultLowerArgs
  (match args
    [(AstExprNil) (OkLowerArgs state IrValueNil)]
    [(AstExprCons arg rest)
      (let
        [arg : AstExpr (ast-node-get arg)]
        [rest : AstExprList (box-get rest)]
        (match (lower-expr ctx state env type-env arg)
          [(OkLowerExpr lowered)
            (match lowered
              [(LowerExpr arg-state value _)
                (match (lower-args ctx arg-state env type-env rest)
                  [(OkLowerArgs rest-state rest-values)
                    (OkLowerArgs
                      rest-state
                      (compiler-ir-value-cons value rest-values))]
                  [(ErrLowerArgs message) (ErrLowerArgs message)])])]
          [(ErrLowerExpr message) (ErrLowerArgs message)]))]))

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
      (if (tc-ref-capturing-lambda-init? type-env init)
        (match (ast-expr-unspan init)
          [(AstExprLambda params lambda-ret body-box)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [expected-ty : AstType
                (tc-type-without-regions (tc-resolve-type ctx ty))]
              (match (lower-lambda
                ctx
                state
                env
                type-env
                params
                lambda-ret
                body
                init
                expected-ty)
                [(OkLowerExpr lowered)
                  (match lowered
                    [(LowerExpr next-state value actual-ty)
                      (OkLowerExpr
                        (lower-coerce-value
                          next-state
                          value
                          actual-ty
                          expected-ty))])]
                [(ErrLowerExpr message) (ErrLowerExpr message)]))]
          [_
            (lower-expr-expected
              ctx
              state
              env
              type-env
              init
              (tc-type-without-regions (tc-resolve-type ctx ty))
              init)])
        (lower-expr-expected
          ctx
          state
          env
          type-env
          init
          (tc-type-without-regions (tc-resolve-type ctx ty))
          init))]
    [(AstNoType)
      (if (tc-ref-capturing-lambda-init? type-env init)
        (match (ast-expr-unspan init)
          [(AstExprLambda params lambda-ret body-box)
            (let
              [body : AstExpr (ast-node-get body-box)]
              (match (tc-lambda-expr-allow-ref-captures
                ctx
                type-env
                params
                lambda-ret
                body)
                [(OkTcType lambda-ty)
                  (lower-lambda
                    ctx
                    state
                    env
                    type-env
                    params
                    lambda-ret
                    body
                    init
                    lambda-ty)]
                [(ErrTcType message)
                  (ErrLowerExpr (lower-diagnostic-at-expr init message))]))]
          [_ (lower-expr ctx state env type-env init)])
        (lower-expr ctx state env type-env init))]))

(define (lower-let-bindings
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [bindings : AstLetBindingList]) : ResultLowerEnv
  (match bindings
    [(AstLetBindingNil) (OkLowerEnv state env type-env)]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name maybe-ty init-box)
            (let
              [name-id : i64 (lower-name-id name)]
              [init : AstExpr (ast-node-get init-box)]
              (match (lower-let-init ctx state env type-env maybe-ty init)
                [(OkLowerExpr lowered)
                  (match lowered
                    [(LowerExpr init-state init-value init-ty)
                      (let
                        [binding-ty : AstType
                          (lower-let-binding-type ctx maybe-ty init-ty)]
                        (match (lower-state-alloc-var init-state)
                          [(LowerAlloc allocated var-id)
                            (let
                              [next-type-env : TcTypeEnv
                                (tc-bind-id type-env name-id binding-ty)]
                              (lower-let-bindings
                                ctx
                                (lower-state-emit
                                  allocated
                                  (IrInstrMov var-id init-value binding-ty))
                                (sym-i64-bind-id env name-id var-id)
                                next-type-env
                                rest))]))])]
                [(ErrLowerExpr message) (ErrLowerEnv message)]))]))]))

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
      (let
        [rest : AstResourceBindingList (box-get rest)]
        (match binding
          [(AstResourceBinding name init-box cleanup-box)
            (let
              [init : AstExpr (ast-node-get init-box)]
              [cleanup : AstExpr (ast-node-get cleanup-box)]
              (match (lower-expr ctx state env type-env init)
                [(OkLowerExpr lowered)
                  (match lowered
                    [(LowerExpr init-state init-value init-ty)
                      (match (lower-cleanup-name-from-expr cleanup)
                        [(OkTcString cleanup-name)
                          (let
                            [binding-ty : AstType
                              (tc-type-without-regions init-ty)]
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
                                      (box cleanups))))]))]
                        [(ErrTcString message)
                          (ErrLowerResourceBindings
                            (lower-diagnostic-at-expr cleanup message))])])]
                [(ErrLowerExpr message) (ErrLowerResourceBindings message)]))]))]))

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
      (let
        [expr : AstExpr (ast-node-get expr)]
        [rest : AstExprList (box-get rest)]
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
              [(ErrLowerExpr message) (ErrLowerExpr message)])]))]))

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
            (IrInstrCall mark-var "tl_region_mark" (IrCallArgsNil) (AstTyU64)))]
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
                              (IrCallArgsOne (IrValueVar mark-var))
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
    (compiler-ir-value-cons mark-value IrValueNil)
    (AstTyUnit))
    [(OkLowerExpr rewind-lowered)
      (match rewind-lowered
        [(LowerExpr rewind-state _ _)
          (match (lower-runtime-call-values
            rewind-state
            "tl_arena_set"
            (compiler-ir-value-cons new-enclosing-value IrValueNil)
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
            (compiler-ir-value-cons scratch-head-value IrValueNil)
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
  [type-env : TcTypeEnv]
  [scratch-head-value : CompilerIrValue]
  [mark-value : CompilerIrValue]
  [body-value : CompilerIrValue]
  [body-ty : AstType]) : ResultLowerExpr
  (match (lower-clone-dispatch ctx state env type-env body-value body-ty)
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
                    (compiler-ir-value-cons enclosing-value IrValueNil)
                    (AstTyUnit))
                    [(OkLowerExpr restore-enclosing-lowered)
                      (match restore-enclosing-lowered
                        [(LowerExpr restore-state _ _)
                          (lower-with-escape-clone
                            ctx
                            restore-state
                            env
                            type-env
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
                    (compiler-ir-value-cons scratch-value IrValueNil)
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
                (compiler-ir-phi-input-cons
                  then-value
                  then-end-label
                  (compiler-ir-phi-input-cons
                    else-value
                    else-end-label
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
(define (spmd-reduce-acc-binop-update [op : AstBinOp] [value : i64]) : i64
  (ast-expr-set
    (lower-spmd-reduce-acc-name)
    (ast-expr-binary
      op
      (ast-node-push (AstExprVar (lower-spmd-reduce-acc-id)))
      value)))

;; Per-iteration accumulator update for a select fold (`min`/`max`): bind `value`
;; once into a temp, then keep it when `(<cmp> val acc)` holds, else keep `acc`.
;; The temp keeps `value` to a single evaluation even though the select names it
;; twice.
(define (spmd-reduce-acc-select-update [cmp : AstBinOp] [value : i64]) : i64
  (ast-expr-let
    (ast-let-binding-cons
      (ast-let-binding (lower-spmd-reduce-val-name) (AstNoType) value)
      (AstLetBindingNil))
    (ast-expr-set
      (lower-spmd-reduce-acc-name)
      (ast-expr-if
        (ast-expr-binary
          cmp
          (ast-node-push (AstExprVar (lower-spmd-reduce-val-id)))
          (ast-node-push (AstExprVar (lower-spmd-reduce-acc-id))))
        (ast-node-push (AstExprVar (lower-spmd-reduce-val-id)))
        (ast-node-push (AstExprVar (lower-spmd-reduce-acc-id)))))))

(define (spmd-reduce-acc-update-expr [op : AstReduceOp] [value : i64]) : i64
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
  [acc-update : i64]) : ResultLowerExpr
  (lower-expr
    ctx
    state
    env
    type-env
    (ast-node-get
      (ast-expr-let
        (ast-let-binding-cons
          (ast-let-binding
            (lower-spmd-reduce-acc-name)
            (AstNoType)
            (ast-node-push init))
          (ast-let-binding-cons
            (ast-let-binding
              (lower-spmd-reduce-end-name)
              (AstNoType)
              (ast-node-push end))
            (ast-let-binding-cons
              (ast-let-binding
                index
                (AstSomeType index-ty)
                (ast-node-push start))
              (AstLetBindingNil))))
        (ast-node-push
          (AstExprBegin
            (ast-expr-cons
              (ast-expr-while
                (ast-expr-binary
                  (AstBinLt)
                  (ast-node-push (AstExprVar (intern index)))
                  (ast-node-push (AstExprVar (lower-spmd-reduce-end-id))))
                (ast-node-push
                  (AstExprBegin
                    (ast-expr-cons
                      acc-update
                      (ast-expr-cons
                        (ast-expr-set
                          index
                          (ast-expr-binary
                            (AstBinAdd)
                            (ast-node-push (AstExprVar (intern index)))
                            (ast-node-push (AstExprLiteral (AstLitInt 1)))))
                        (AstExprNil))))))
              (ast-expr-cons
                (ast-node-push (AstExprVar (lower-spmd-reduce-acc-id)))
                (AstExprNil)))))))))

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
    [acc-update : i64 (spmd-reduce-acc-update-expr op (ast-node-push value))]
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
    [(CompilerLowerLinuxAvx2) true]
    [(CompilerLowerWindowsAvx2) true]
    [(CompilerLowerAvx512) true]
    [(CompilerLowerLinuxAvx512) true]
    [(CompilerLowerWindowsAvx512) true]
    [_ false]))

(define (lower-mode-avx512? [mode : CompilerLowerMode]) : bool
  (match mode
    [(CompilerLowerAvx512) true]
    [(CompilerLowerLinuxAvx512) true]
    [(CompilerLowerWindowsAvx512) true]
    [_ false]))

(define (lower-mode-inline-aggregates? [mode : CompilerLowerMode]) : bool
  (match mode
    [(CompilerLowerInlineAggregates) true]
    [_ false]))

(define (lower-mode-linux-c-abi? [mode : CompilerLowerMode]) : bool
  (match mode
    [(CompilerLowerLinuxScalar) true]
    [(CompilerLowerLinuxAvx2) true]
    [(CompilerLowerLinuxAvx512) true]
    [_ false]))

(define (lower-mode-windows-c-abi? [mode : CompilerLowerMode]) : bool
  (match mode
    [(CompilerLowerWindowsScalar) true]
    [(CompilerLowerWindowsAvx2) true]
    [(CompilerLowerWindowsAvx512) true]
    [_ false]))

(define (lower-mode-c-abi? [mode : CompilerLowerMode]) : bool
  (or (lower-mode-linux-c-abi? mode) (lower-mode-windows-c-abi? mode)))

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
        [(AstTyF32) 8]
        [(AstTyI32) 8]
        [(AstTyU32) 8]
        [_ 0])]
    [(CompilerLowerLinuxAvx2)
      (match (tc-type-without-regions ty)
        [(AstTyI64) 4]
        [(AstTyU64) 4]
        [(AstTyF64) 4]
        [(AstTyF32) 8]
        [(AstTyI32) 8]
        [(AstTyU32) 8]
        [_ 0])]
    [(CompilerLowerWindowsAvx2)
      (match (tc-type-without-regions ty)
        [(AstTyI64) 4]
        [(AstTyU64) 4]
        [(AstTyF64) 4]
        [(AstTyF32) 8]
        [(AstTyI32) 8]
        [(AstTyU32) 8]
        [_ 0])]
    [(CompilerLowerAvx512)
      (match (tc-type-without-regions ty)
        [(AstTyI64) 8]
        [(AstTyU64) 8]
        [(AstTyF64) 8]
        [(AstTyF32) 16]
        [(AstTyI32) 16]
        [(AstTyU32) 16]
        [_ 0])]
    [(CompilerLowerLinuxAvx512)
      (match (tc-type-without-regions ty)
        [(AstTyI64) 8]
        [(AstTyU64) 8]
        [(AstTyF64) 8]
        [(AstTyF32) 16]
        [(AstTyI32) 16]
        [(AstTyU32) 16]
        [_ 0])]
    [(CompilerLowerWindowsAvx512)
      (match (tc-type-without-regions ty)
        [(AstTyI64) 8]
        [(AstTyU64) 8]
        [(AstTyF64) 8]
        [(AstTyF32) 16]
        [(AstTyI32) 16]
        [(AstTyU32) 16]
        [_ 0])]
    [_ 0]))

(define (lower-expr-is-var? [expr : AstExpr] [name : String]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-expr-is-var? inner name))]
    [(AstExprVar found) (string-eq (intern-str found) name)]
    [_ false]))

(define (lower-dynamic-array-var
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [expr : AstExpr]) : LowerMaybeArrayVar
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-dynamic-array-var env type-env inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-dynamic-array-var env type-env inner))]
    [(AstExprVar name)
      (match (sym-i64-lookup-id env name)
        [(SomeI64 var-id)
          (match (tc-lookup type-env (intern-str name))
            [(OkTcType ty)
              (match (tc-type-strip-region ty)
                [(AstTyDynArray elem-ty)
                  (LowerSomeArrayVar
                    var-id
                    (tc-type-without-regions (ty-node-get elem-ty)))]
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
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-array-ref-var-for-index env type-env inner index))]
    [(AstExprArrayRef arr-box idx-box)
      (let
        [arr : AstExpr (ast-node-get arr-box)]
        [idx : AstExpr (ast-node-get idx-box)]
        (if (lower-expr-is-var? idx index)
          (lower-dynamic-array-var env type-env arr)
          LowerNoArrayVar))]
    [_ LowerNoArrayVar]))

(define (lower-array-var-list-add
  [vars : LowerArrayVarList]
  [var : i64]
  [offset : i64]) : LowerArrayVarList
  (match vars
    [(LowerArrayVarNil) (LowerArrayVarCons var offset (box LowerArrayVarNil))]
    [(LowerArrayVarCons found found-offset rest)
      (if (= found var)
        (LowerArrayVarCons
          found
          (if (> offset found-offset)
            offset
            found-offset)
          rest)
        (LowerArrayVarCons
          found
          found-offset
          (box (lower-array-var-list-add (box-get rest) var offset))))]))

(define (lower-array-var-list-merge
  [left : LowerArrayVarList]
  [right : LowerArrayVarList]) : LowerArrayVarList
  (match right
    [(LowerArrayVarNil) left]
    [(LowerArrayVarCons var offset rest)
      (lower-array-var-list-merge
        (lower-array-var-list-add left var offset)
        (box-get rest))]))

(define (lower-array-var-list-max-offset [vars : LowerArrayVarList]) : i64
  (match vars
    [(LowerArrayVarNil) 0]
    [(LowerArrayVarCons _ offset rest)
      (let
        [rest-offset : i64 (lower-array-var-list-max-offset (box-get rest))]
        (if (> offset rest-offset)
          offset
          rest-offset))]))

(define (lower-masked-vector-index-literal-offset [expr : AstExpr]) : i64
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-index-literal-offset inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-index-literal-offset inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-index-literal-offset inner))]
    [(AstExprLiteral (AstLitInt n))
      (if (>= n 0)
        n
        -1)]
    [_ -1]))

(define (lower-masked-vector-index-offset [index : String] [expr : AstExpr]) : i64
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-index-offset index inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-index-offset index inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-index-offset index inner))]
    [(AstExprVar name)
      (if (string-eq (intern-str name) index)
        0
        -1)]
    [(AstExprBinary op left-box right-box)
      (match op
        [(AstBinAdd)
          (let
            [left : AstExpr (ast-node-get left-box)]
            [right : AstExpr (ast-node-get right-box)]
            [left-offset : i64 (lower-masked-vector-index-offset index left)]
            [right-offset : i64 (lower-masked-vector-index-offset index right)]
            (cond
              [(= left-offset 0)
                (lower-masked-vector-index-literal-offset right)]
              [(= right-offset 0)
                (lower-masked-vector-index-literal-offset left)]
              [else -1]))]
        [_ -1])]
    [_ -1]))

(define (lower-masked-vector-lanes-merge [left : i64] [right : i64]) : i64
  (cond
    [(< left 0) -1]
    [(< right 0) -1]
    [(= left 0) right]
    [(= right 0) left]
    [(= left right) left]
    [else -1]))

(define (lower-masked-vector-binop-supported? [op : AstBinOp]) : bool
  (match op
    [(AstBinAdd) true]
    [(AstBinEq) true]
    [(AstBinNe) true]
    [(AstBinLt) true]
    [(AstBinLe) true]
    [(AstBinGt) true]
    [(AstBinGe) true]
    [(AstBinAnd) true]
    [(AstBinOr) true]
    [_ false]))

(define (lower-masked-vector-unop-supported? [op : AstUnOp]) : bool
  (match op
    [(AstUnNot) true]
    [_ false]))

(define (lower-masked-vector-expr-list-lanes
  [mode : CompilerLowerMode]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [exprs : AstExprList]) : i64
  (match exprs
    [(AstExprNil) 0]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (ast-node-get expr)]
        [rest : AstExprList (box-get rest)]
        (lower-masked-vector-lanes-merge
          (lower-masked-vector-expr-lanes mode env type-env index expr)
          (lower-masked-vector-expr-list-lanes mode env type-env index rest)))]))

(define (lower-masked-vector-let-bindings-lanes
  [mode : CompilerLowerMode]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [bindings : AstLetBindingList]) : i64
  (match bindings
    [(AstLetBindingNil) 0]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding _ _ init-box)
            (let
              [init : AstExpr (ast-node-get init-box)]
              (lower-masked-vector-lanes-merge
                (lower-masked-vector-expr-lanes mode env type-env index init)
                (lower-masked-vector-let-bindings-lanes
                  mode
                  env
                  type-env
                  index
                  rest)))]))]))

(define (lower-masked-vector-expr-lanes
  [mode : CompilerLowerMode]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [expr : AstExpr]) : i64
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-expr-lanes mode env type-env index inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-expr-lanes mode env type-env index inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-expr-lanes mode env type-env index inner))]
    [(AstExprLiteral _) 0]
    [(AstExprVar _) 0]
    [(AstExprUnary op inner-box)
      (if (lower-masked-vector-unop-supported? op)
        (let
          [inner : AstExpr (ast-node-get inner-box)]
          (lower-masked-vector-expr-lanes mode env type-env index inner))
        -1)]
    [(AstExprBinary op left-box right-box)
      (if (lower-masked-vector-binop-supported? op)
        (let
          [left : AstExpr (ast-node-get left-box)]
          [right : AstExpr (ast-node-get right-box)]
          (lower-masked-vector-lanes-merge
            (lower-masked-vector-expr-lanes mode env type-env index left)
            (lower-masked-vector-expr-lanes mode env type-env index right)))
        -1)]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lower-masked-vector-lanes-merge
          (lower-masked-vector-let-bindings-lanes
            mode
            env
            type-env
            index
            bindings)
          (lower-masked-vector-expr-lanes mode env type-env index body)))]
    [(AstExprIf cond-box then-box else-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-box)]
        [else-branch : AstExpr (ast-node-get else-box)]
        (lower-masked-vector-lanes-merge
          (lower-masked-vector-expr-lanes mode env type-env index cond)
          (lower-masked-vector-lanes-merge
            (lower-masked-vector-expr-lanes mode env type-env index then-branch)
            (lower-masked-vector-expr-lanes mode env type-env index else-branch))))]
    [(AstExprBegin exprs)
      (lower-masked-vector-expr-list-lanes mode env type-env index exprs)]
    [(AstExprArrayRef arr-box idx-box)
      (let
        [arr : AstExpr (ast-node-get arr-box)]
        [idx : AstExpr (ast-node-get idx-box)]
        (if (>= (lower-masked-vector-index-offset index idx) 0)
          (match (lower-dynamic-array-var env type-env arr)
            [(LowerSomeArrayVar _ elem-ty)
              (lower-simd-lanes-for-elem mode elem-ty)]
            [LowerNoArrayVar -1])
          -1))]
    [(AstExprArraySet arr-box idx-box value-box)
      (let
        [arr : AstExpr (ast-node-get arr-box)]
        [idx : AstExpr (ast-node-get idx-box)]
        [value : AstExpr (ast-node-get value-box)]
        (if (>= (lower-masked-vector-index-offset index idx) 0)
          (match (lower-dynamic-array-var env type-env arr)
            [(LowerSomeArrayVar _ elem-ty)
              (lower-masked-vector-lanes-merge
                (lower-simd-lanes-for-elem mode elem-ty)
                (lower-masked-vector-expr-lanes mode env type-env index value))]
            [LowerNoArrayVar -1])
          -1))]
    [_ -1]))

(define (lower-masked-vector-body-has-varying-if?
  [mode : CompilerLowerMode]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-body-has-varying-if? mode env type-env index inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-body-has-varying-if? mode env type-env index inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-body-has-varying-if? mode env type-env index inner))]
    [(AstExprIf cond-box then-box else-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-box)]
        [else-branch : AstExpr (ast-node-get else-box)]
        (if (> (lower-masked-vector-expr-lanes mode env type-env index cond) 0)
          true
          (or
            (lower-masked-vector-body-has-varying-if?
              mode
              env
              type-env
              index
              then-branch)
            (lower-masked-vector-body-has-varying-if?
              mode
              env
              type-env
              index
              else-branch))))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (or
          (lower-masked-vector-let-bindings-have-varying-if?
            mode
            env
            type-env
            index
            bindings)
          (lower-masked-vector-body-has-varying-if?
            mode
            env
            type-env
            index
            body)))]
    [(AstExprBegin exprs)
      (lower-masked-vector-expr-list-has-varying-if?
        mode
        env
        type-env
        index
        exprs)]
    [(AstExprUnary _ inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-body-has-varying-if? mode env type-env index inner))]
    [(AstExprBinary _ left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (or
          (lower-masked-vector-body-has-varying-if?
            mode
            env
            type-env
            index
            left)
          (lower-masked-vector-body-has-varying-if?
            mode
            env
            type-env
            index
            right)))]
    [(AstExprArrayRef arr-box idx-box)
      (let
        [arr : AstExpr (ast-node-get arr-box)]
        [idx : AstExpr (ast-node-get idx-box)]
        (or
          (lower-masked-vector-body-has-varying-if? mode env type-env index arr)
          (lower-masked-vector-body-has-varying-if? mode env type-env index idx)))]
    [(AstExprArraySet arr-box idx-box value-box)
      (let
        [arr : AstExpr (ast-node-get arr-box)]
        [idx : AstExpr (ast-node-get idx-box)]
        [value : AstExpr (ast-node-get value-box)]
        (or
          (lower-masked-vector-body-has-varying-if? mode env type-env index arr)
          (or
            (lower-masked-vector-body-has-varying-if?
              mode
              env
              type-env
              index
              idx)
            (lower-masked-vector-body-has-varying-if?
              mode
              env
              type-env
              index
              value))))]
    [_ false]))

(define (lower-masked-vector-expr-list-has-varying-if?
  [mode : CompilerLowerMode]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [exprs : AstExprList]) : bool
  (match exprs
    [(AstExprNil) false]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (ast-node-get expr)]
        [rest : AstExprList (box-get rest)]
        (or
          (lower-masked-vector-body-has-varying-if?
            mode
            env
            type-env
            index
            expr)
          (lower-masked-vector-expr-list-has-varying-if?
            mode
            env
            type-env
            index
            rest)))]))

(define (lower-masked-vector-let-bindings-have-varying-if?
  [mode : CompilerLowerMode]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [bindings : AstLetBindingList]) : bool
  (match bindings
    [(AstLetBindingNil) false]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding _ _ init-box)
            (let
              [init : AstExpr (ast-node-get init-box)]
              (or
                (lower-masked-vector-body-has-varying-if?
                  mode
                  env
                  type-env
                  index
                  init)
                (lower-masked-vector-let-bindings-have-varying-if?
                  mode
                  env
                  type-env
                  index
                  rest)))]))]))

(define (lower-masked-vector-map
  [mode : CompilerLowerMode]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [body : AstExpr]) : LowerMaybeMaskedVectorMap
  (if (and
    (lower-mode-avx512? mode)
    (lower-masked-vector-body-has-varying-if? mode env type-env index body))
    (let
      [lanes : i64
        (lower-masked-vector-expr-lanes mode env type-env index body)]
      (if (> lanes 0)
        (LowerSomeMaskedVectorMap lanes)
        LowerNoMaskedVectorMap))
    LowerNoMaskedVectorMap))

(define (lower-masked-vector-array-vars
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [expr : AstExpr]) : LowerArrayVarList
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-array-vars env type-env index inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-array-vars env type-env index inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-array-vars env type-env index inner))]
    [(AstExprUnary _ inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-masked-vector-array-vars env type-env index inner))]
    [(AstExprBinary _ left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (lower-array-var-list-merge
          (lower-masked-vector-array-vars env type-env index left)
          (lower-masked-vector-array-vars env type-env index right)))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lower-array-var-list-merge
          (lower-masked-vector-let-binding-array-vars
            env
            type-env
            index
            bindings)
          (lower-masked-vector-array-vars env type-env index body)))]
    [(AstExprIf cond-box then-box else-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-box)]
        [else-branch : AstExpr (ast-node-get else-box)]
        (lower-array-var-list-merge
          (lower-masked-vector-array-vars env type-env index cond)
          (lower-array-var-list-merge
            (lower-masked-vector-array-vars env type-env index then-branch)
            (lower-masked-vector-array-vars env type-env index else-branch))))]
    [(AstExprBegin exprs)
      (lower-masked-vector-expr-list-array-vars env type-env index exprs)]
    [(AstExprArrayRef arr-box idx-box)
      (let
        [arr : AstExpr (ast-node-get arr-box)]
        [idx : AstExpr (ast-node-get idx-box)]
        [idx-offset : i64 (lower-masked-vector-index-offset index idx)]
        (if (>= idx-offset 0)
          (match (lower-dynamic-array-var env type-env arr)
            [(LowerSomeArrayVar var _)
              (lower-array-var-list-add LowerArrayVarNil var idx-offset)]
            [LowerNoArrayVar LowerArrayVarNil])
          LowerArrayVarNil))]
    [(AstExprArraySet arr-box idx-box value-box)
      (let
        [arr : AstExpr (ast-node-get arr-box)]
        [idx : AstExpr (ast-node-get idx-box)]
        [value : AstExpr (ast-node-get value-box)]
        [idx-offset : i64 (lower-masked-vector-index-offset index idx)]
        (lower-array-var-list-merge
          (if (>= idx-offset 0)
            (match (lower-dynamic-array-var env type-env arr)
              [(LowerSomeArrayVar var _)
                (lower-array-var-list-add LowerArrayVarNil var idx-offset)]
              [LowerNoArrayVar LowerArrayVarNil])
            LowerArrayVarNil)
          (lower-masked-vector-array-vars env type-env index value)))]
    [_ LowerArrayVarNil]))

(define (lower-masked-vector-expr-list-array-vars
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [exprs : AstExprList]) : LowerArrayVarList
  (match exprs
    [(AstExprNil) LowerArrayVarNil]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (ast-node-get expr)]
        [rest : AstExprList (box-get rest)]
        (lower-array-var-list-merge
          (lower-masked-vector-array-vars env type-env index expr)
          (lower-masked-vector-expr-list-array-vars env type-env index rest)))]))

(define (lower-masked-vector-let-binding-array-vars
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [bindings : AstLetBindingList]) : LowerArrayVarList
  (match bindings
    [(AstLetBindingNil) LowerArrayVarNil]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding _ _ init-box)
            (let
              [init : AstExpr (ast-node-get init-box)]
              (lower-array-var-list-merge
                (lower-masked-vector-array-vars env type-env index init)
                (lower-masked-vector-let-binding-array-vars
                  env
                  type-env
                  index
                  rest)))]))]))

(define (lower-masked-vector-let-binding-names
  [bindings : AstLetBindingList]
  [lane-locals : LowerStringSet]) : LowerStringSet
  (match bindings
    [(AstLetBindingNil) lane-locals]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name _ _)
            (lower-masked-vector-let-binding-names
              rest
              (lower-string-set-insert lane-locals name))]))]))

(define (lower-simple-vector-map-value
  [mode : CompilerLowerMode]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [dst-var : i64]
  [dst-elem : AstType]
  [value : AstExpr]) : LowerMaybeVectorMap
  (match value
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-simple-vector-map-value
          mode
          env
          type-env
          index
          dst-var
          dst-elem
          inner))]
    [(AstExprBinary op lhs-box rhs-box)
      (let
        [lhs : AstExpr (ast-node-get lhs-box)]
        [rhs : AstExpr (ast-node-get rhs-box)]
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
          [_ LowerNoVectorMap]))]
    [_ LowerNoVectorMap]))

(define (lower-simple-vector-map
  [mode : CompilerLowerMode]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [body : AstExpr]) : LowerMaybeVectorMap
  (match body
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-simple-vector-map mode env type-env index inner))]
    [(AstExprArraySet arr-box set-index-box value-box)
      (let
        [arr : AstExpr (ast-node-get arr-box)]
        [set-index : AstExpr (ast-node-get set-index-box)]
        [value : AstExpr (ast-node-get value-box)]
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
          LowerNoVectorMap))]
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
      [(AstExprSpanned inner-box _)
        (let
          [inner : AstExpr (ast-node-get inner-box)]
          (lower-simple-vector-reduce mode env type-env op index inner))]
      [(AstExprAnn inner-box _)
        (let
          [inner : AstExpr (ast-node-get inner-box)]
          (lower-simple-vector-reduce mode env type-env op index inner))]
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
                    [(AstTyF64)
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
                    [(AstTyI64)
                      (if (lower-mode-avx512? mode)
                        (LowerSomeVectorReduce
                          array-var
                          (IrVectorReduceMin)
                          elem
                          lanes)
                        LowerNoVectorReduce)]
                    [_ LowerNoVectorReduce])]
                [(AstReduceMax)
                  (match elem
                    [(AstTyI32)
                      (LowerSomeVectorReduce
                        array-var
                        (IrVectorReduceMax)
                        elem
                        lanes)]
                    [(AstTyI64)
                      (if (lower-mode-avx512? mode)
                        (LowerSomeVectorReduce
                          array-var
                          (IrVectorReduceMax)
                          elem
                          lanes)
                        LowerNoVectorReduce)]
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

(define (lower-emit-splat
  [state : LowerState]
  [value : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]) : LowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc s v)
      (LowerExpr
        (lower-state-emit s (IrInstrSplat v value lanes elem-ty))
        (IrValueVar v)
        elem-ty)]))

(define (lower-emit-vector-compare
  [state : LowerState]
  [op : CompilerIrBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [lanes : i64]
  [elem-ty : AstType]) : LowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc s v)
      (LowerExpr
        (lower-state-emit s (IrInstrVectorCompare v op lhs rhs lanes elem-ty))
        (IrValueVar v)
        (AstTyBool))]))

(define (lower-emit-mask-binop
  [state : LowerState]
  [op : CompilerIrMaskBinOp]
  [lhs : CompilerIrValue]
  [rhs : CompilerIrValue]
  [lanes : i64]) : LowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc s v)
      (LowerExpr
        (lower-state-emit s (IrInstrMaskBinOp v op lhs rhs lanes))
        (IrValueVar v)
        (AstTyBool))]))

(define (lower-emit-mask-not
  [state : LowerState]
  [src : CompilerIrValue]
  [lanes : i64]) : LowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc s v)
      (LowerExpr
        (lower-state-emit s (IrInstrMaskNot v src lanes))
        (IrValueVar v)
        (AstTyBool))]))

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
  (let
    [acc-name-id : i64 (lower-spmd-reduce-acc-id)]
    [current-name-id : i64 (lower-spmd-reduce-current-id)]
    (lower-expr
      ctx
      state
      (sym-i64-bind-id
        (sym-i64-bind-id env acc-name-id acc-var)
        current-name-id
        value-var)
      (tc-bind-id
        (tc-bind-id type-env acc-name-id elem-ty)
        current-name-id
        elem-ty)
      (ast-node-get
        (spmd-reduce-acc-update-expr
          op
          (ast-node-push (AstExprVar current-name-id)))))))

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

(define (lower-avx512-index-plus-offset
  [state : LowerState]
  [base : CompilerIrValue]
  [offset : i64]) : LowerExpr
  (if (> offset 0)
    (lower-emit-binop state (IrBinAdd) base (IrValueI64 offset) (AstTyI64))
    (LowerExpr state base (AstTyI64))))

(define (lower-avx512-array-list-next-ok
  [state : LowerState]
  [ok : CompilerIrValue]
  [next-index : CompilerIrValue]
  [arrays : LowerArrayVarList]) : LowerExpr
  (match arrays
    [(LowerArrayVarNil) (LowerExpr state ok (AstTyBool))]
    [(LowerArrayVarCons array-var offset rest)
      (match (lower-avx512-index-plus-offset state next-index offset)
        [(LowerExpr index-state limit-index _)
          (match (lower-array-len-value index-state (IrValueVar array-var))
            [(LowerExpr len-state array-len _)
              (match (lower-emit-binop
                len-state
                (IrBinLe)
                limit-index
                array-len
                (AstTyBool))
                [(LowerExpr cmp-state within _)
                  (match (lower-emit-binop
                    cmp-state
                    (IrBinAnd)
                    ok
                    within
                    (AstTyBool))
                    [(LowerExpr next-state next-ok _)
                      (lower-avx512-array-list-next-ok
                        next-state
                        next-ok
                        next-index
                        (box-get rest))])])])])]))

(define (lower-avx512-array-list-end-ok
  [state : LowerState]
  [ok : CompilerIrValue]
  [end-value : CompilerIrValue]
  [arrays : LowerArrayVarList]) : LowerExpr
  (match arrays
    [(LowerArrayVarNil) (LowerExpr state ok (AstTyBool))]
    [(LowerArrayVarCons array-var offset rest)
      (match (lower-avx512-index-plus-offset state end-value offset)
        [(LowerExpr index-state limit-index _)
          (match (lower-array-len-value index-state (IrValueVar array-var))
            [(LowerExpr len-state array-len _)
              (match (lower-emit-binop
                len-state
                (IrBinLe)
                limit-index
                array-len
                (AstTyBool))
                [(LowerExpr cmp-state within _)
                  (match (lower-emit-binop
                    cmp-state
                    (IrBinAnd)
                    ok
                    within
                    (AstTyBool))
                    [(LowerExpr next-state next-ok _)
                      (lower-avx512-array-list-end-ok
                        next-state
                        next-ok
                        end-value
                        (box-get rest))])])])])]))

(define (lower-avx512-masked-index-limit [lanes : i64] [offset : i64]) : i64
  (let
    [base : i64 (- 9223372036854775807 lanes)]
    (if (> offset base)
      -1
      (- base offset))))

(define (lower-avx512-masked-tail-limit [offset : i64]) : i64
  (- 9223372036854775807 offset))

(define (lower-avx512-masked-vector-ok
  [state : LowerState]
  [index-var : i64]
  [next-index : CompilerIrValue]
  [end-value : CompilerIrValue]
  [arrays : LowerArrayVarList]
  [lanes : i64]) : LowerExpr
  (let
    [s : LowerState state]
    [max-offset : i64 (lower-array-var-list-max-offset arrays)]
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
        (IrValueI64 (lower-avx512-masked-index-limit lanes max-offset))
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
          (lower-avx512-array-list-next-ok next-s value next-index arrays)]))))

(define (lower-avx512-masked-tail-ok
  [state : LowerState]
  [index-var : i64]
  [end-value : CompilerIrValue]
  [arrays : LowerArrayVarList]) : LowerExpr
  (let
    [s : LowerState state]
    [max-offset : i64 (lower-array-var-list-max-offset arrays)]
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
        end-value
        (IrValueI64 (lower-avx512-masked-tail-limit max-offset))
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
          (lower-avx512-array-list-end-ok next-s value end-value arrays)]))))

(define (lower-avx512-masked-unsupported [expr : AstExpr] [detail : String]) : ResultLowerExpr
  (ErrLowerExpr
    (lower-diagnostic-at-expr
      expr
      (string-append "lower: SPMD masked if does not support " detail))))

(define (lower-avx512-masked-index-value
  [state : LowerState]
  [index : String]
  [index-var : i64]
  [expr : AstExpr]) : ResultLowerExpr
  (let
    [offset : i64 (lower-masked-vector-index-offset index expr)]
    (if (< offset 0)
      (lower-avx512-masked-unsupported
        expr
        "non-contiguous array indexes in this AVX-512 slice")
      (if (= offset 0)
        (OkLowerExpr (LowerExpr state (IrValueVar index-var) (AstTyI64)))
        (OkLowerExpr
          (lower-emit-binop
            state
            (IrBinAdd)
            (IrValueVar index-var)
            (IrValueI64 offset)
            (AstTyI64)))))))

(define (lower-avx512-masked-bool-literal
  [state : LowerState]
  [active-mask : CompilerIrValue]
  [lanes : i64]
  [value : bool]) : LowerExpr
  (if value
    (LowerExpr state active-mask (AstTyBool))
    (lower-emit-mask-not state active-mask lanes)))

(define (lower-avx512-masked-var
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [lane-locals : LowerStringSet]
  [index : String]
  [lanes : i64]
  [expr : AstExpr]
  [name : String]) : ResultLowerExpr
  (if (lower-string-set-contains? lane-locals name)
    (match (sym-i64-lookup env name)
      [(SomeI64 var-id)
        (match (tc-lookup type-env name)
          [(OkTcType ty)
            (OkLowerExpr
              (LowerExpr state (IrValueVar var-id) (tc-type-without-regions ty)))]
          [(ErrTcType message)
            (ErrLowerExpr (lower-diagnostic-at-expr expr message))])]
      [(NoneI64)
        (lower-avx512-masked-unsupported expr "unknown lane-local binding")])
    (if (string-eq name index)
      (lower-avx512-masked-unsupported
        expr
        "lane index values; direct array indexes are supported")
      (match (sym-i64-lookup env name)
        [(SomeI64 var-id)
          (match (tc-lookup type-env name)
            [(OkTcType ty)
              (let
                [lane-ty : AstType (tc-type-without-regions ty)]
                (if (>
                  (lower-simd-lanes-for-elem (lower-state-mode state) lane-ty)
                  0)
                  (OkLowerExpr
                    (lower-emit-splat state (IrValueVar var-id) lanes lane-ty))
                  (lower-avx512-masked-unsupported
                    expr
                    "uniform non-lane values inside masked vector expressions")))]
            [(ErrTcType message)
              (ErrLowerExpr (lower-diagnostic-at-expr expr message))])]
        [(NoneI64)
          (lower-avx512-masked-unsupported
            expr
            "unbound values inside masked vector expressions")]))))

(define (lower-avx512-masked-array-ref
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [index-var : i64]
  [active-mask : CompilerIrValue]
  [lanes : i64]
  [expr : AstExpr]
  [arr : AstExpr]
  [idx : AstExpr]) : ResultLowerExpr
  (match (lower-dynamic-array-var env type-env arr)
    [(LowerSomeArrayVar array-var elem-ty)
      (let
        [lane-ty : AstType (tc-type-without-regions elem-ty)]
        (if (=
          (lower-simd-lanes-for-elem (lower-state-mode state) lane-ty)
          lanes)
          (match (lower-avx512-masked-index-value state index index-var idx)
            [(OkLowerExpr idx-lowered)
              (match idx-lowered
                [(LowerExpr idx-state idx-value _)
                  (OkLowerExpr
                    (lower-emit-predicated-load
                      idx-state
                      (IrValueVar array-var)
                      idx-value
                      active-mask
                      lanes
                      lane-ty))])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])
          (lower-avx512-masked-unsupported
            expr
            "mixed lane widths inside one masked foreach")))]
    [LowerNoArrayVar
      (lower-avx512-masked-unsupported
        expr
        "non-dynamic-array reads inside masked branches")]))

(define (lower-avx512-masked-array-set
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [lane-locals : LowerStringSet]
  [index : String]
  [index-var : i64]
  [active-mask : CompilerIrValue]
  [lanes : i64]
  [expr : AstExpr]
  [arr : AstExpr]
  [idx : AstExpr]
  [value : AstExpr]) : ResultLowerExpr
  (match (lower-dynamic-array-var env type-env arr)
    [(LowerSomeArrayVar array-var elem-ty)
      (let
        [lane-ty : AstType (tc-type-without-regions elem-ty)]
        (if (=
          (lower-simd-lanes-for-elem (lower-state-mode state) lane-ty)
          lanes)
          (match (lower-avx512-masked-index-value state index index-var idx)
            [(OkLowerExpr idx-lowered)
              (match idx-lowered
                [(LowerExpr idx-state idx-value _)
                  (match (lower-avx512-masked-expr
                    ctx
                    idx-state
                    env
                    type-env
                    lane-locals
                    index
                    index-var
                    active-mask
                    lanes
                    value)
                    [(OkLowerExpr value-lowered)
                      (match value-lowered
                        [(LowerExpr value-state value-ir _)
                          (OkLowerExpr
                            (LowerExpr
                              (lower-emit-predicated-store
                                value-state
                                (IrValueVar array-var)
                                idx-value
                                value-ir
                                active-mask
                                lanes
                                lane-ty)
                              IrValueUnit
                              (AstTyUnit)))])]
                    [(ErrLowerExpr message) (ErrLowerExpr message)])])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])
          (lower-avx512-masked-unsupported
            expr
            "mixed lane widths inside one masked foreach")))]
    [LowerNoArrayVar
      (lower-avx512-masked-unsupported
        expr
        "non-dynamic-array writes inside masked branches")]))

(define (lower-avx512-masked-let-bindings
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [lane-locals : LowerStringSet]
  [index : String]
  [index-var : i64]
  [active-mask : CompilerIrValue]
  [lanes : i64]
  [bindings : AstLetBindingList]) : ResultLowerEnv
  (match bindings
    [(AstLetBindingNil) (OkLowerEnv state env type-env)]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name maybe-ty init-box)
            (let
              [init : AstExpr (ast-node-get init-box)]
              (match (lower-avx512-masked-expr
                ctx
                state
                env
                type-env
                lane-locals
                index
                index-var
                active-mask
                lanes
                init)
                [(OkLowerExpr lowered)
                  (match lowered
                    [(LowerExpr init-state init-value init-ty)
                      (let
                        [binding-ty : AstType
                          (lower-let-binding-type ctx maybe-ty init-ty)]
                        (match init-value
                          [(IrValueVar init-var)
                            (lower-avx512-masked-let-bindings
                              ctx
                              init-state
                              (sym-i64-bind env name init-var)
                              (tc-bind type-env name binding-ty)
                              (lower-string-set-insert lane-locals name)
                              index
                              index-var
                              active-mask
                              lanes
                              rest)]
                          [_
                            (ErrLowerEnv
                              (lower-diagnostic-at-expr
                                init
                                "lower: masked let init did not produce an IR variable"))]))])]
                [(ErrLowerExpr message) (ErrLowerEnv message)]))]))]))

(define (lower-avx512-masked-begin
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [lane-locals : LowerStringSet]
  [index : String]
  [index-var : i64]
  [active-mask : CompilerIrValue]
  [lanes : i64]
  [exprs : AstExprList]) : ResultLowerExpr
  (match exprs
    [(AstExprNil) (OkLowerExpr (LowerExpr state IrValueUnit (AstTyUnit)))]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (ast-node-get expr)]
        [rest : AstExprList (box-get rest)]
        (match (lower-avx512-masked-expr
          ctx
          state
          env
          type-env
          lane-locals
          index
          index-var
          active-mask
          lanes
          expr)
          [(OkLowerExpr lowered)
            (match lowered
              [(LowerExpr next-state value ty)
                (match rest
                  [(AstExprNil) (OkLowerExpr (LowerExpr next-state value ty))]
                  [_
                    (lower-avx512-masked-begin
                      ctx
                      next-state
                      env
                      type-env
                      lane-locals
                      index
                      index-var
                      active-mask
                      lanes
                      rest)])])]
          [(ErrLowerExpr message) (ErrLowerExpr message)]))]))

(define (lower-avx512-masked-if
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [lane-locals : LowerStringSet]
  [index : String]
  [index-var : i64]
  [active-mask : CompilerIrValue]
  [lanes : i64]
  [expr : AstExpr]
  [cond : AstExpr]
  [then-branch : AstExpr]
  [else-branch : AstExpr]) : ResultLowerExpr
  (match (lower-avx512-masked-expr
    ctx
    state
    env
    type-env
    lane-locals
    index
    index-var
    active-mask
    lanes
    cond)
    [(OkLowerExpr cond-lowered)
      (match cond-lowered
        [(LowerExpr cond-state cond-mask _)
          (match (lower-emit-mask-binop
            cond-state
            (IrMaskAnd)
            active-mask
            cond-mask
            lanes)
            [(LowerExpr then-mask-state then-mask _)
              (match (lower-emit-mask-not then-mask-state cond-mask lanes)
                [(LowerExpr not-state not-mask _)
                  (match (lower-emit-mask-binop
                    not-state
                    (IrMaskAnd)
                    active-mask
                    not-mask
                    lanes)
                    [(LowerExpr else-mask-state else-mask _)
                      (match (lower-avx512-masked-expr
                        ctx
                        else-mask-state
                        env
                        type-env
                        lane-locals
                        index
                        index-var
                        then-mask
                        lanes
                        then-branch)
                        [(OkLowerExpr then-lowered)
                          (match then-lowered
                            [(LowerExpr then-state then-value then-ty)
                              (match (lower-avx512-masked-expr
                                ctx
                                then-state
                                env
                                type-env
                                lane-locals
                                index
                                index-var
                                else-mask
                                lanes
                                else-branch)
                                [(OkLowerExpr else-lowered)
                                  (match else-lowered
                                    [(LowerExpr else-state else-value else-ty)
                                      (match then-ty
                                        [(AstTyUnit)
                                          (OkLowerExpr
                                            (LowerExpr
                                              else-state
                                              IrValueUnit
                                              (AstTyUnit)))]
                                        [_
                                          (lower-avx512-masked-unsupported
                                            expr
                                            "value-producing masked if results in this AVX-512 slice")])])]
                                [(ErrLowerExpr message) (ErrLowerExpr message)])])]
                        [(ErrLowerExpr message) (ErrLowerExpr message)])])])])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-avx512-masked-binary
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [lane-locals : LowerStringSet]
  [index : String]
  [index-var : i64]
  [active-mask : CompilerIrValue]
  [lanes : i64]
  [expr : AstExpr]
  [op : AstBinOp]
  [left : AstExpr]
  [right : AstExpr]) : ResultLowerExpr
  (match op
    [(AstBinAnd)
      (match (lower-avx512-masked-expr
        ctx
        state
        env
        type-env
        lane-locals
        index
        index-var
        active-mask
        lanes
        left)
        [(OkLowerExpr left-lowered)
          (match left-lowered
            [(LowerExpr left-state left-value _)
              (match (lower-avx512-masked-expr
                ctx
                left-state
                env
                type-env
                lane-locals
                index
                index-var
                active-mask
                lanes
                right)
                [(OkLowerExpr right-lowered)
                  (match right-lowered
                    [(LowerExpr right-state right-value _)
                      (OkLowerExpr
                        (lower-emit-mask-binop
                          right-state
                          (IrMaskAnd)
                          left-value
                          right-value
                          lanes))])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstBinOr)
      (match (lower-avx512-masked-expr
        ctx
        state
        env
        type-env
        lane-locals
        index
        index-var
        active-mask
        lanes
        left)
        [(OkLowerExpr left-lowered)
          (match left-lowered
            [(LowerExpr left-state left-value _)
              (match (lower-avx512-masked-expr
                ctx
                left-state
                env
                type-env
                lane-locals
                index
                index-var
                active-mask
                lanes
                right)
                [(OkLowerExpr right-lowered)
                  (match right-lowered
                    [(LowerExpr right-state right-value _)
                      (OkLowerExpr
                        (lower-emit-mask-binop
                          right-state
                          (IrMaskOr)
                          left-value
                          right-value
                          lanes))])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstBinAdd)
      (match (lower-avx512-masked-expr
        ctx
        state
        env
        type-env
        lane-locals
        index
        index-var
        active-mask
        lanes
        left)
        [(OkLowerExpr left-lowered)
          (match left-lowered
            [(LowerExpr left-state left-value left-ty)
              (match (lower-avx512-masked-expr
                ctx
                left-state
                env
                type-env
                lane-locals
                index
                index-var
                active-mask
                lanes
                right)
                [(OkLowerExpr right-lowered)
                  (match right-lowered
                    [(LowerExpr right-state right-value _)
                      (OkLowerExpr
                        (lower-emit-vector-binop
                          right-state
                          (IrBinAdd)
                          left-value
                          right-value
                          lanes
                          left-ty))])]
                [(ErrLowerExpr message) (ErrLowerExpr message)])])]
        [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstBinEq)
      (lower-avx512-masked-compare
        ctx
        state
        env
        type-env
        lane-locals
        index
        index-var
        active-mask
        lanes
        expr
        (IrBinEq)
        left
        right)]
    [(AstBinNe)
      (lower-avx512-masked-compare
        ctx
        state
        env
        type-env
        lane-locals
        index
        index-var
        active-mask
        lanes
        expr
        (IrBinNe)
        left
        right)]
    [(AstBinLt)
      (lower-avx512-masked-compare
        ctx
        state
        env
        type-env
        lane-locals
        index
        index-var
        active-mask
        lanes
        expr
        (IrBinLt)
        left
        right)]
    [(AstBinLe)
      (lower-avx512-masked-compare
        ctx
        state
        env
        type-env
        lane-locals
        index
        index-var
        active-mask
        lanes
        expr
        (IrBinLe)
        left
        right)]
    [(AstBinGt)
      (lower-avx512-masked-compare
        ctx
        state
        env
        type-env
        lane-locals
        index
        index-var
        active-mask
        lanes
        expr
        (IrBinGt)
        left
        right)]
    [(AstBinGe)
      (lower-avx512-masked-compare
        ctx
        state
        env
        type-env
        lane-locals
        index
        index-var
        active-mask
        lanes
        expr
        (IrBinGe)
        left
        right)]
    [_ (lower-avx512-masked-unsupported expr "this binary operator")]))

(define (lower-avx512-masked-compare
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [lane-locals : LowerStringSet]
  [index : String]
  [index-var : i64]
  [active-mask : CompilerIrValue]
  [lanes : i64]
  [expr : AstExpr]
  [op : CompilerIrBinOp]
  [left : AstExpr]
  [right : AstExpr]) : ResultLowerExpr
  (match (lower-avx512-masked-expr
    ctx
    state
    env
    type-env
    lane-locals
    index
    index-var
    active-mask
    lanes
    left)
    [(OkLowerExpr left-lowered)
      (match left-lowered
        [(LowerExpr left-state left-value left-ty)
          (match (lower-avx512-masked-expr
            ctx
            left-state
            env
            type-env
            lane-locals
            index
            index-var
            active-mask
            lanes
            right)
            [(OkLowerExpr right-lowered)
              (match right-lowered
                [(LowerExpr right-state right-value _)
                  (OkLowerExpr
                    (lower-emit-vector-compare
                      right-state
                      op
                      left-value
                      right-value
                      lanes
                      left-ty))])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])])]
    [(ErrLowerExpr message) (ErrLowerExpr message)]))

(define (lower-avx512-masked-expr
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [lane-locals : LowerStringSet]
  [index : String]
  [index-var : i64]
  [active-mask : CompilerIrValue]
  [lanes : i64]
  [expr : AstExpr]) : ResultLowerExpr
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-avx512-masked-expr
          ctx
          state
          env
          type-env
          lane-locals
          index
          index-var
          active-mask
          lanes
          inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-avx512-masked-expr
          ctx
          state
          env
          type-env
          lane-locals
          index
          index-var
          active-mask
          lanes
          inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-avx512-masked-expr
          ctx
          state
          env
          type-env
          lane-locals
          index
          index-var
          active-mask
          lanes
          inner))]
    [(AstExprLiteral lit)
      (match lit
        [(AstLitBool value)
          (OkLowerExpr
            (lower-avx512-masked-bool-literal state active-mask lanes value))]
        [_
          (OkLowerExpr
            (lower-emit-splat
              state
              (lower-literal-value lit)
              lanes
              (tc-literal-type lit)))])]
    [(AstExprVar name)
      (lower-avx512-masked-var
        ctx
        state
        env
        type-env
        lane-locals
        index
        lanes
        expr
        (intern-str name))]
    [(AstExprUnary op inner-box)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (match op
          [(AstUnNot)
            (match (lower-avx512-masked-expr
              ctx
              state
              env
              type-env
              lane-locals
              index
              index-var
              active-mask
              lanes
              inner)
              [(OkLowerExpr lowered)
                (match lowered
                  [(LowerExpr next-state value _)
                    (OkLowerExpr (lower-emit-mask-not next-state value lanes))])]
              [(ErrLowerExpr message) (ErrLowerExpr message)])]
          [_ (lower-avx512-masked-unsupported expr "this unary operator")]))]
    [(AstExprBinary op left-box right-box)
      (let
        [left : AstExpr (ast-node-get left-box)]
        [right : AstExpr (ast-node-get right-box)]
        (lower-avx512-masked-binary
          ctx
          state
          env
          type-env
          lane-locals
          index
          index-var
          active-mask
          lanes
          expr
          op
          left
          right))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (match (lower-avx512-masked-let-bindings
          ctx
          state
          env
          type-env
          lane-locals
          index
          index-var
          active-mask
          lanes
          bindings)
          [(OkLowerEnv bound-state bound-env bound-type-env)
            (lower-avx512-masked-expr
              ctx
              bound-state
              bound-env
              bound-type-env
              (lower-masked-vector-let-binding-names bindings lane-locals)
              index
              index-var
              active-mask
              lanes
              body)]
          [(ErrLowerEnv message) (ErrLowerExpr message)]))]
    [(AstExprIf cond-box then-box else-box)
      (let
        [cond : AstExpr (ast-node-get cond-box)]
        [then-branch : AstExpr (ast-node-get then-box)]
        [else-branch : AstExpr (ast-node-get else-box)]
        (lower-avx512-masked-if
          ctx
          state
          env
          type-env
          lane-locals
          index
          index-var
          active-mask
          lanes
          expr
          cond
          then-branch
          else-branch))]
    [(AstExprBegin exprs)
      (lower-avx512-masked-begin
        ctx
        state
        env
        type-env
        lane-locals
        index
        index-var
        active-mask
        lanes
        exprs)]
    [(AstExprArrayRef arr-box idx-box)
      (let
        [arr : AstExpr (ast-node-get arr-box)]
        [idx : AstExpr (ast-node-get idx-box)]
        (lower-avx512-masked-array-ref
          ctx
          state
          env
          type-env
          index
          index-var
          active-mask
          lanes
          expr
          arr
          idx))]
    [(AstExprArraySet arr-box idx-box value-box)
      (let
        [arr : AstExpr (ast-node-get arr-box)]
        [idx : AstExpr (ast-node-get idx-box)]
        [value : AstExpr (ast-node-get value-box)]
        (lower-avx512-masked-array-set
          ctx
          state
          env
          type-env
          lane-locals
          index
          index-var
          active-mask
          lanes
          expr
          arr
          idx
          value))]
    [_ (lower-avx512-masked-unsupported expr "this branch expression")]))

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

(define (lower-avx512-masked-map-body
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [index-ty : AstType]
  [index-var : i64]
  [active-mask : CompilerIrValue]
  [lanes : i64]
  [body : AstExpr]) : ResultLowerExpr
  (lower-avx512-masked-expr
    ctx
    state
    (sym-i64-bind env index index-var)
    (tc-bind type-env index index-ty)
    LowerStringNil
    index
    index-var
    active-mask
    lanes
    body))

(define (lower-avx512-masked-foreach-lowered
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [index : String]
  [index-ty : AstType]
  [start-value : CompilerIrValue]
  [end-value : CompilerIrValue]
  [body : AstExpr]
  [plan : LowerMaybeMaskedVectorMap]) : ResultLowerExpr
  (match plan
    [(LowerSomeMaskedVectorMap lanes)
      (match (lower-state-alloc-var state)
        [(LowerAlloc index-alloc index-var)
          (let
            [s : LowerState
              (lower-state-emit
                index-alloc
                (IrInstrMov index-var start-value index-ty))]
            [body-env : SymI64Env (sym-i64-bind env index index-var)]
            [body-type-env : TcTypeEnv (tc-bind type-env index index-ty)]
            [arrays : LowerArrayVarList
              (lower-masked-vector-array-vars body-env body-type-env index body)]
            [header-label : String ""]
            [body-label : String ""]
            [tail-header-label : String ""]
            [tail-check-label : String ""]
            [tail-mask-label : String ""]
            [tail-body-label : String ""]
            [exit-label : String ""]
            [next-index : CompilerIrValue IrValueUnit]
            [vector-ok : CompilerIrValue IrValueUnit]
            [tail-cond : CompilerIrValue IrValueUnit]
            [tail-safe : CompilerIrValue IrValueUnit]
            [active-mask : CompilerIrValue IrValueUnit]
            (begin
              (match (lower-state-fresh-label s "foreach_avx512_mask_header")
                [(LowerLabel next-s label)
                  (begin
                    (set! s next-s)
                    (set! header-label label))])
              (match (lower-state-fresh-label s "foreach_avx512_mask_body")
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
              (match (lower-avx512-masked-vector-ok
                s
                index-var
                next-index
                end-value
                arrays
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
              (match (lower-emit-tail-mask
                s
                (IrValueVar index-var)
                next-index
                lanes)
                [(LowerExpr next-s value _)
                  (begin
                    (set! s next-s)
                    (set! active-mask value))])
              (match (lower-avx512-masked-map-body
                ctx
                s
                env
                type-env
                index
                index-ty
                index-var
                active-mask
                lanes
                body)
                [(OkLowerExpr lowered-body)
                  (match lowered-body
                    [(LowerExpr body-state _ _)
                      (set!
                        s
                        (lower-state-emit
                          body-state
                          (IrInstrMov index-var next-index index-ty)))])]
                [(ErrLowerExpr message) (return (ErrLowerExpr message))])
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
                    (IrInstrBranch tail-cond tail-check-label exit-label))
                  tail-check-label))
              (match (lower-avx512-masked-tail-ok s index-var end-value arrays)
                [(LowerExpr next-s value _)
                  (begin
                    (set! s next-s)
                    (set! tail-safe value))])
              (set!
                s
                (lower-state-finish-block
                  (lower-state-emit
                    s
                    (IrInstrBranch tail-safe tail-mask-label tail-body-label))
                  tail-mask-label))
              (match (lower-emit-tail-mask
                s
                (IrValueVar index-var)
                end-value
                lanes)
                [(LowerExpr next-s value _)
                  (begin
                    (set! s next-s)
                    (set! active-mask value))])
              (match (lower-avx512-masked-map-body
                ctx
                s
                env
                type-env
                index
                index-ty
                index-var
                active-mask
                lanes
                body)
                [(OkLowerExpr lowered-tail)
                  (match lowered-tail
                    [(LowerExpr tail-state _ _)
                      (set!
                        s
                        (lower-state-finish-block
                          (lower-state-emit tail-state (IrInstrJump exit-label))
                          tail-body-label))])]
                [(ErrLowerExpr message) (return (ErrLowerExpr message))])
              (match (lower-expr ctx s body-env body-type-env body)
                [(OkLowerExpr scalar-tail-lowered)
                  (match scalar-tail-lowered
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
    [LowerNoMaskedVectorMap
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
        (match (lower-masked-vector-map
          (lower-state-mode state)
          env
          type-env
          index
          body)
          [(LowerSomeMaskedVectorMap _)
            (lower-avx512-masked-foreach-lowered
              ctx
              state
              env
              type-env
              index
              index-ty
              start-value
              end-value
              body
              (lower-masked-vector-map
                (lower-state-mode state)
                env
                type-env
                index
                body))]
          [LowerNoMaskedVectorMap
            (if (lower-masked-vector-body-has-varying-if?
              (lower-state-mode state)
              env
              type-env
              index
              body)
              (ErrLowerExpr
                (lower-diagnostic-at-expr
                  body
                  "lower: SPMD masked if AVX-512 lowering is not available for this backend mode or branch shape"))
              (lower-scalar-foreach-lowered
                ctx
                state
                env
                type-env
                index
                index-ty
                start-value
                end-value
                body))])])
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
                  (match (tc-type-strip-region (tc-resolve-type ctx scrut-ty))
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
                    [(AstTyEnumArgs _ _)
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
                    [(AstTyVarArgs _ _)
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
      (let
        [rest : AstMatchArmList (box-get rest)]
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
              [(AstMatchArm pat body-box)
                (let
                  [body : AstExpr (ast-node-get body-box)]
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
                        (lower-diagnostic "lower: unsupported match pattern"))]))])]))]))

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
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pat body-box)
            (let
              [body : AstExpr (ast-node-get body-box)]
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
                    [(AstPatVariant variant-name args-box)
                      (let
                        [args : AstPatternList (box-get args-box)]
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
                          phi-inputs))]
                    [_
                      (ErrLowerExpr
                        (lower-diagnostic
                          "lower: unsupported enum match pattern"))])]
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
                    [(AstPatVariant variant-name args-box)
                      (let
                        [args : AstPatternList (box-get args-box)]
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
                          phi-inputs))]
                    [_
                      (ErrLowerExpr
                        (lower-diagnostic
                          "lower: unsupported enum match pattern"))])]))]))]))

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
    [(TcContext _ symbols registries _)
      (let
        [resolved-scrut-ty : AstType
          (tc-type-strip-region (tc-resolve-type ctx scrut-ty))]
        [lookup-name : String
          (lower-variant-lookup-name-for-scrut resolved-scrut-ty variant-name)]
        (match (compiler-registries-lookup-variant registries lookup-name)
          [(SomeI64 handle)
            (match (compiler-registries-variant-fields-indexed symbols handle)
              [(OkAstTypeList fields)
                (let
                  [resolved-fields : AstTypeList
                    (tc-resolve-type-list
                      ctx
                      (lower-enum-constructor-fields-for-result
                        ctx
                        (lower-enum-type-name-or-empty resolved-scrut-ty)
                        resolved-scrut-ty
                        fields))]
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
                      resolved-fields
                      (lower-state-mode state)
                      (lower-enum-type-name-or-empty resolved-scrut-ty)
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
                                      (compiler-ir-phi-input-cons
                                        body-value
                                        body-end-label
                                        phi-inputs))))])]
                          [(ErrLowerExpr message) (ErrLowerExpr message)])]
                      [(ErrLowerEnv message) (ErrLowerExpr message)])))]
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
                    (compiler-ir-phi-input-cons
                      body-value
                      body-end-label
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
    [(TcContext _ symbols registries _)
      (let
        [resolved-scrut-ty : AstType
          (tc-type-strip-region (tc-resolve-type ctx scrut-ty))]
        [lookup-name : String
          (lower-variant-lookup-name-for-scrut resolved-scrut-ty variant-name)]
        (match (compiler-registries-lookup-variant registries lookup-name)
          [(SomeI64 handle)
            (match (compiler-registries-variant-fields-indexed symbols handle)
              [(OkAstTypeList fields)
                (let
                  [resolved-fields : AstTypeList
                    (tc-resolve-type-list
                      ctx
                      (lower-enum-constructor-fields-for-result
                        ctx
                        (lower-enum-type-name-or-empty resolved-scrut-ty)
                        resolved-scrut-ty
                        fields))]
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
                                    resolved-fields
                                    args
                                    body
                                    rest
                                    merge-label
                                    expr-ty
                                    phi-inputs))])]))]))]
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
                                (compiler-ir-phi-input-cons
                                  body-value
                                  body-end-label
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
    [(AstMatchArm pat body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
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
                      (compiler-ir-phi-input-cons
                        body-value
                        body-end-label
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

(define (lower-tail-call-var-unshadowed? [env : SymI64Env] [name : i64]) : bool
  (match (sym-i64-lookup-id env name)
    [(SomeI64 _) false]
    [(NoneI64) true]))

(define (lower-tail-call-target?
  [_state : LowerState]
  [env : SymI64Env]
  [callee : AstExpr]) : bool
  (match (ast-expr-unspan callee)
    [(AstExprVar name) (lower-tail-call-var-unshadowed? env name)]
    [_ false]))

(define (lower-tail-call-self-target? [state : LowerState] [name : i64]) : bool
  (string-eq
    (lower-resolve-name state (intern-str name))
    (lower-state-current-function state)))

(define (lower-symbol-function-define? [ctx : TcContext] [name : String]) : bool
  (let
    [symbols : CompilerSymbols (tc-context-symbols ctx)]
    (match (compiler-symbols-lookup-value
      symbols
      (lower-hygiene-source-name name))
      [(SomeI64 handle)
        (=
          (compiler-symbol-handle-kind handle)
          (compiler-symbol-kind-function-define))]
      [(NoneI64) false])))

(define (lower-tail-call-compatible-return?
  [ctx : TcContext]
  [callee-ret : AstType]
  [ret-ty : AstType]) : bool
  (tc-type-eq
    (tc-type-without-regions (tc-resolve-type ctx callee-ret))
    (tc-type-without-regions (tc-resolve-type ctx ret-ty))))

(define (lower-tail-call-direct-supported?
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : i64]
  [ret-ty : AstType]) : bool
  (if (lower-tail-call-self-target? state name)
    true
    (let
      [source-name : String (intern-str name)]
      (if (lower-symbol-function-define? ctx source-name)
        (match (lower-lookup-type-id
          (lower-state-type-cache state)
          env
          type-env
          name)
          [(OkTcType fn-ty)
            (match (tc-type-strip-region (tc-resolve-type ctx fn-ty))
              [(AstTyFunc param-types callee-ret)
                (and
                  (<=
                    (tc-type-list-len (tc-resolve-type-list ctx param-types))
                    4)
                  (lower-tail-call-compatible-return?
                    ctx
                    (ty-node-get callee-ret)
                    ret-ty))]
              [_ false])]
          [(ErrTcType _) false])
        false))))

(define (lower-tail-call-args-for-target
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : i64]
  [args : AstExprList]) : ResultLowerArgs
  (match (lower-lookup-type-id (lower-state-type-cache state) env type-env name)
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
    [(ErrTcType _) (lower-args ctx state env type-env args)]))

(define (lower-tail-let-bindings-candidate-env
  [env : SymI64Env]
  [bindings : AstLetBindingList]) : SymI64Env
  (match bindings
    [(AstLetBindingNil) env]
    [(AstLetBindingCons binding rest)
      (let
        [rest : AstLetBindingList (box-get rest)]
        (match binding
          [(AstLetBinding name _ _)
            (lower-tail-let-bindings-candidate-env
              (sym-i64-bind env name 0)
              rest)]))]))

(define (lower-tail-begin-candidate?
  [state : LowerState]
  [env : SymI64Env]
  [exprs : AstExprList]) : bool
  (match exprs
    [(AstExprNil) false]
    [(AstExprCons expr rest)
      (let
        [expr : AstExpr (ast-node-get expr)]
        [rest : AstExprList (box-get rest)]
        (match rest
          [(AstExprNil) (lower-tail-expr-candidate? state env expr)]
          [_ (lower-tail-begin-candidate? state env rest)]))]))

(define (lower-tail-match-arms-candidate?
  [state : LowerState]
  [env : SymI64Env]
  [arms : AstMatchArmList]) : bool
  (match arms
    [(AstMatchArmNil) false]
    [(AstMatchArmCons arm rest)
      (let
        [rest : AstMatchArmList (box-get rest)]
        (match arm
          [(AstMatchArm pat body-box)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [body-env : SymI64Env
                (match pat
                  [(AstPatBinding name) (sym-i64-bind env name 0)]
                  [_ env])]
              (if (lower-tail-expr-candidate? state body-env body)
                true
                (lower-tail-match-arms-candidate? state env rest)))]))]))

(define (lower-tail-expr-candidate?
  [state : LowerState]
  [env : SymI64Env]
  [expr : AstExpr]) : bool
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-tail-expr-candidate? state env inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-tail-expr-candidate? state env inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-tail-expr-candidate? state env inner))]
    [(AstExprCall callee-box _)
      (let
        [callee : AstExpr (ast-node-get callee-box)]
        (lower-tail-call-target? state env callee))]
    [(AstExprLet bindings body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lower-tail-expr-candidate?
          state
          (lower-tail-let-bindings-candidate-env env bindings)
          body))]
    [(AstExprBegin exprs) (lower-tail-begin-candidate? state env exprs)]
    [(AstExprUnsafe exprs) (lower-tail-begin-candidate? state env exprs)]
    [(AstExprIf _ then-branch-box else-branch-box)
      (let
        [then-branch : AstExpr (ast-node-get then-branch-box)]
        [else-branch : AstExpr (ast-node-get else-branch-box)]
        (if (lower-tail-expr-candidate? state env then-branch)
          true
          (lower-tail-expr-candidate? state env else-branch)))]
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
            (match (lower-return-abi-value ctx body-state value ret-ty)
              [(OkLowerExpr return-copy)
                (match return-copy
                  [(LowerExpr return-state return-value _)
                    (OkLowerState
                      (lower-state-emit
                        return-state
                        (IrInstrReturn (lower-return-maybe return-value ret-ty))))])]
              [(ErrLowerExpr message) (ErrLowerState message)]))])]
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
  (match (ast-expr-unspan callee)
    [(AstExprVar name)
      (if (and
        (and
          (lower-tail-call-var-unshadowed? env name)
          (not (lower-mode-inline-aggregates? (lower-state-mode state))))
        (lower-tail-call-direct-supported? ctx state env type-env name ret-ty))
        (match (lower-tail-call-args-for-target
          ctx
          state
          env
          type-env
          name
          args)
          [(OkLowerArgs args-state values)
            (OkLowerState
              (lower-state-emit-at-expr
                args-state
                (IrInstrTailCall
                  (lower-resolve-name args-state (intern-str name))
                  (compiler-ir-call-args-from-list values)
                  ret-ty)
                origin))]
          [(ErrLowerArgs message) (ErrLowerState message)])
        (lower-return-expr ctx state env type-env origin ret-ty))]
    [_ (lower-return-expr ctx state env type-env origin ret-ty)]))

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
      (let
        [expr : AstExpr (ast-node-get expr)]
        [rest : AstExprList (box-get rest)]
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
              [(ErrLowerExpr message) (ErrLowerState message)])]))]))

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
      (let
        [rest : AstMatchArmList (box-get rest)]
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
              [(AstMatchArm pat body-box)
                (let
                  [body : AstExpr (ast-node-get body-box)]
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
                        (lower-diagnostic "lower: unsupported match pattern"))]))])]))]))

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
    [(AstMatchArm pat body-box)
      (let
        [body : AstExpr (ast-node-get body-box)]
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
          (match (tc-type-strip-region (tc-resolve-type ctx scrut-ty))
            [(AstTyEnum _)
              (lower-return-expr ctx state env type-env origin ret-ty)]
            [(AstTyEnumArgs _ _)
              (lower-return-expr ctx state env type-env origin ret-ty)]
            [(AstTyVarArgs _ _)
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
      [(AstExprSpanned inner-box _)
        (let
          [inner : AstExpr (ast-node-get inner-box)]
          (lower-tail-expr ctx state env type-env inner ret-ty))]
      [(AstExprAnn inner-box _)
        (let
          [inner : AstExpr (ast-node-get inner-box)]
          (lower-tail-expr ctx state env type-env inner ret-ty))]
      [(AstExprCast inner-box _)
        (let
          [inner : AstExpr (ast-node-get inner-box)]
          (match (tc-expr ctx type-env inner)
            [(OkTcType inner-ty)
              (if (tc-type-eq (tc-type-without-regions inner-ty) ret-ty)
                (lower-tail-expr ctx state env type-env inner ret-ty)
                (lower-return-expr ctx state env type-env expr ret-ty))]
            [(ErrTcType message)
              (ErrLowerState (lower-diagnostic-at-expr inner message))]))]
      [(AstExprCall callee-box args)
        (let
          [callee : AstExpr (ast-node-get callee-box)]
          (lower-tail-call ctx state env type-env callee args ret-ty expr))]
      [(AstExprLet bindings body-box)
        (let
          [body : AstExpr (ast-node-get body-box)]
          (match (lower-let-bindings ctx state env type-env bindings)
            [(OkLowerEnv binding-state body-env body-type-env)
              (lower-tail-expr
                ctx
                binding-state
                body-env
                body-type-env
                body
                ret-ty)]
            [(ErrLowerEnv message) (ErrLowerState message)]))]
      [(AstExprBegin exprs)
        (lower-tail-begin ctx state env type-env exprs ret-ty)]
      [(AstExprUnsafe exprs)
        (lower-tail-begin ctx state env (tc-enter-unsafe type-env) exprs ret-ty)]
      [(AstExprIf cond-box then-branch-box else-branch-box)
        (let
          [cond : AstExpr (ast-node-get cond-box)]
          [then-branch : AstExpr (ast-node-get then-branch-box)]
          [else-branch : AstExpr (ast-node-get else-branch-box)]
          (lower-tail-if
            ctx
            state
            env
            type-env
            cond
            then-branch
            else-branch
            ret-ty))]
      [(AstExprMatch scrutinee-box arms)
        (let
          [scrutinee : AstExpr (ast-node-get scrutinee-box)]
          (lower-tail-match ctx state env type-env scrutinee arms ret-ty expr))]
      [_ (lower-return-expr ctx state env type-env expr ret-ty)])
    (lower-return-expr ctx state env type-env expr ret-ty)))

(define (lower-param-count [params : AstParamList]) : i64
  (match params
    [(AstParamNil) 0]
    [(AstParamCons _ rest)
      (let
        [rest : AstParamList (box-get rest)]
        (+ 1 (lower-param-count rest)))]))

(define (lower-bind-params
  [params : AstParamList]
  [idx : i64]
  [env : SymI64Env]) : SymI64Env
  (match params
    [(AstParamNil) env]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam name _ _)
            (lower-bind-params rest (+ idx 1) (sym-i64-bind env name idx))]))]))

(define (lower-param-list [ctx : TcContext] [params : AstParamList] [idx : i64]) : CompilerIrParamList
  (match params
    [(AstParamNil) IrParamNil]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam name ty _)
            (compiler-ir-param-cons
              (IrParam
                name
                (tc-type-without-regions (tc-resolve-type ctx ty))
                idx)
              (lower-param-list ctx rest (+ idx 1)))]))]))

(define (lower-copy-inline-aggregate-param
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [name : String]
  [ty : AstType]) : ResultLowerEnv
  (let
    [resolved : AstType (tc-type-without-regions (tc-resolve-type ctx ty))]
    (if (lower-inline-aggregate-abi-copy-needed? ctx state resolved)
      (match (sym-i64-lookup env name)
        [(SomeI64 var-id)
          (match (lower-copy-inline-aggregate-to-inline
            ctx
            state
            (IrValueVar var-id)
            resolved)
            [(OkLowerExpr copied)
              (match copied
                [(LowerExpr copy-state copy-value _)
                  (match copy-value
                    [(IrValueVar copy-var)
                      (OkLowerEnv
                        copy-state
                        (sym-i64-bind env name copy-var)
                        type-env)]
                    [_
                      (ErrLowerEnv
                        (lower-diagnostic
                          "lower: aggregate ABI param copy expected local value"))])])]
            [(ErrLowerExpr message) (ErrLowerEnv message)])]
        [(NoneI64)
          (ErrLowerEnv
            (lower-diagnostic
              (string-append "lower: missing aggregate ABI param " name)))])
      (OkLowerEnv state env type-env))))

(define (lower-copy-inline-aggregate-params
  [ctx : TcContext]
  [state : LowerState]
  [env : SymI64Env]
  [type-env : TcTypeEnv]
  [params : AstParamList]) : ResultLowerEnv
  (match params
    [(AstParamNil) (OkLowerEnv state env type-env)]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam name ty _)
            (match (lower-copy-inline-aggregate-param
              ctx
              state
              env
              type-env
              name
              ty)
              [(OkLowerEnv param-state param-env param-type-env)
                (lower-copy-inline-aggregate-params
                  ctx
                  param-state
                  param-env
                  param-type-env
                  rest)]
              [(ErrLowerEnv message) (ErrLowerEnv message)])]))]))

(define (lower-supported-function-param-type? [ctx : TcContext] [ty : AstType]) : bool
  (lower-supported-reference-type? ctx ty))

(define (lower-type-contains-inline-aggregate? [ctx : TcContext] [ty : AstType]) : bool
  (match (tc-type-strip-region (tc-resolve-type ctx ty))
    [(AstTyStruct _) true]
    [(AstTyEnum _) true]
    [(AstTyTuple elems) (lower-type-list-contains-inline-aggregate? ctx elems)]
    [(AstTyArray elem _)
      (lower-type-contains-inline-aggregate? ctx (ty-node-get elem))]
    [(AstTyRegion _ inner)
      (lower-type-contains-inline-aggregate? ctx (ty-node-get inner))]
    [_ false]))

(define (lower-type-list-contains-inline-aggregate?
  [ctx : TcContext]
  [types : AstTypeList]) : bool
  (match types
    [(AstTypeNil) false]
    [(AstTypeCons ty rest)
      (let
        [ty : AstType (ty-node-get ty)]
        [rest : AstTypeList (box-get rest)]
        (or
          (lower-type-contains-inline-aggregate? ctx ty)
          (lower-type-list-contains-inline-aggregate? ctx rest)))]))

(define (lower-param-list-contains-inline-aggregate?
  [ctx : TcContext]
  [params : AstParamList]) : bool
  (match params
    [(AstParamNil) false]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam _ ty _)
            (or
              (lower-type-contains-inline-aggregate? ctx ty)
              (lower-param-list-contains-inline-aggregate? ctx rest))]))]))

(define (lower-param-list-contains-unsupported-reference?
  [ctx : TcContext]
  [params : AstParamList]) : bool
  (match params
    [(AstParamNil) false]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam _ ty _)
            (or
              (not (lower-supported-function-param-type? ctx ty))
              (lower-param-list-contains-unsupported-reference? ctx rest))]))]))

(define (lower-supported-function-return-type? [ctx : TcContext] [ty : AstType]) : bool
  (match (tc-resolve-type ctx ty)
    [(AstTyRegion _ inner)
      (lower-supported-function-return-type? ctx (ty-node-get inner))]
    [_ true]))

(define (lower-logical-name-has-suffix?
  [logical-name : String]
  [suffix : String]) : bool
  (let
    [name-len : i64 (string-length logical-name)]
    [suffix-len : i64 (string-length suffix)]
    (and
      (>= name-len suffix-len)
      (string-eq
        (substring logical-name (- name-len suffix-len) suffix-len)
        suffix))))

(define (lower-stdlib-hash-string-param? [ctx : TcContext] [ty : AstType]) : bool
  (match (tc-type-strip-region (tc-resolve-type ctx ty))
    [(AstTyRef _ inner)
      (match (tc-type-strip-region (tc-resolve-type ctx (ty-node-get inner)))
        [(AstTyStr) true]
        [_ false])]
    [_ false]))

(define (lower-stdlib-hash-string-signature?
  [ctx : TcContext]
  [logical-name : String]
  [params : AstParamList]
  [ret-ty : AstType]) : bool
  (and
    (lower-logical-name-has-suffix? logical-name "stdlib/hash.tl::hash-string")
    (and
      (tc-type-eq ret-ty (AstTyI64))
      (match params
        [(AstParamCons param rest)
          (let
            [rest : AstParamList (box-get rest)]
            (match rest
              [(AstParamNil)
                (match param
                  [(AstParam _ ty _) (lower-stdlib-hash-string-param? ctx ty)])]
              [_ false]))]
        [_ false]))))

(define (lower-runtime-return-function
  [ctx : TcContext]
  [logical-name : String]
  [params : AstParamList]
  [ret-ty : AstType]
  [call-state : LowerState]
  [value : CompilerIrValue]) : ResultLowerFunction
  (let
    [return-state : LowerState
      (lower-state-emit call-state (IrInstrReturn (IrSomeValue value)))]
    (OkLowerFunction
      (compiler-ir-function-cons
        (IrFunction
          logical-name
          (lower-param-list ctx params 0)
          ret-ty
          (lower-state-next-var return-state)
          (lower-state-build-blocks return-state))
        (lower-state-functions return-state))
      (lower-state-spans return-state))))

(define (lower-stdlib-hash-string-function
  [ctx : TcContext]
  [logical-name : String]
  [params : AstParamList]
  [ret-ty : AstType]
  [state : LowerState]) : ResultLowerFunction
  (match (lower-string-fields state (IrValueVar 0))
    [(LowerStringFields fields-state ptr len)
      (match (lower-runtime-call-values
        fields-state
        "tl_hash_string"
        (compiler-ir-value-cons ptr (compiler-ir-value-cons len IrValueNil))
        ret-ty)
        [(OkLowerExpr lowered)
          (match lowered
            [(LowerExpr call-state value _)
              (lower-runtime-return-function
                ctx
                logical-name
                params
                ret-ty
                call-state
                value)])]
        [(ErrLowerExpr message) (ErrLowerFunction message)])]))

(define (lower-stdlib-string-eq-borrowed-signature?
  [ctx : TcContext]
  [logical-name : String]
  [params : AstParamList]
  [ret-ty : AstType]) : bool
  (and
    (lower-logical-name-has-suffix?
      logical-name
      "stdlib/string.tl::string-eq-borrowed")
    (and
      (tc-type-eq ret-ty (AstTyBool))
      (match params
        [(AstParamCons (AstParam _ left-ty _) left-rest)
          (match (box-get left-rest)
            [(AstParamCons (AstParam _ right-ty _) right-rest)
              (match (box-get right-rest)
                [(AstParamNil)
                  (and
                    (lower-stdlib-hash-string-param? ctx left-ty)
                    (lower-stdlib-hash-string-param? ctx right-ty))]
                [_ false])]
            [_ false])]
        [_ false]))))

(define (lower-stdlib-string-eq-borrowed-function
  [ctx : TcContext]
  [logical-name : String]
  [params : AstParamList]
  [ret-ty : AstType]
  [state : LowerState]) : ResultLowerFunction
  (match (lower-string-fields state (IrValueVar 0))
    [(LowerStringFields left-state left-ptr left-len)
      (match (lower-string-fields left-state (IrValueVar 1))
        [(LowerStringFields done-state right-ptr right-len)
          (match (lower-runtime-call-values
            done-state
            "tl_string_eq"
            (compiler-ir-value-cons
              left-ptr
              (compiler-ir-value-cons
                left-len
                (compiler-ir-value-cons
                  right-ptr
                  (compiler-ir-value-cons right-len IrValueNil))))
            ret-ty)
            [(OkLowerExpr lowered)
              (match lowered
                [(LowerExpr call-state value _)
                  (lower-runtime-return-function
                    ctx
                    logical-name
                    params
                    ret-ty
                    call-state
                    value)])]
            [(ErrLowerExpr message) (ErrLowerFunction message)])])]))

(define (lower-function
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
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
    (let
      [param-count : i64 (lower-param-count params)]
      [env : SymI64Env (lower-bind-params params 0 (sym-i64-empty))]
      [type-env : TcTypeEnv
        (tc-bind-return-type
          (tc-bind-params ctx (tc-hygiene-global-env top-env) params)
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
          type-cache
          mode)]
      [ret-ty : AstType (tc-type-without-regions (tc-resolve-type ctx ret))]
      (if (lower-supported-function-return-type? ctx ret-ty)
        (if (lower-stdlib-hash-string-signature? ctx logical-name params ret-ty)
          (lower-stdlib-hash-string-function
            ctx
            logical-name
            params
            ret-ty
            state)
          (if (lower-stdlib-string-eq-borrowed-signature?
            ctx
            logical-name
            params
            ret-ty)
            (lower-stdlib-string-eq-borrowed-function
              ctx
              logical-name
              params
              ret-ty
              state)
            (match (lower-copy-inline-aggregate-params
              ctx
              state
              env
              type-env
              params)
              [(OkLowerEnv abi-state abi-env abi-type-env)
                (match (lower-tail-expr
                  ctx
                  abi-state
                  abi-env
                  abi-type-env
                  body
                  ret-ty)
                  [(OkLowerState final-state)
                    (OkLowerFunction
                      (compiler-ir-function-cons
                        (IrFunction
                          logical-name
                          (lower-param-list ctx params 0)
                          ret-ty
                          (lower-state-next-var final-state)
                          (lower-state-build-blocks final-state))
                        (lower-state-functions final-state))
                      (lower-state-spans final-state))]
                  [(ErrLowerState message) (ErrLowerFunction message)])]
              [(ErrLowerEnv message) (ErrLowerFunction message)])))
        (ErrLowerFunction
          (lower-diagnostic-at-expr body "lower: unsupported expression"))))))

(define (lower-global-value [names : LowerNameCache] [expr : AstExpr]) : ResultLowerValue
  (match expr
    [(AstExprSpanned inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-global-value names inner))]
    [(AstExprAnn inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-global-value names inner))]
    [(AstExprCast inner-box _)
      (let
        [inner : AstExpr (ast-node-get inner-box)]
        (lower-global-value names inner))]
    [(AstExprLiteral lit) (OkLowerValue (lower-literal-value lit))]
    [(AstExprVar name)
      (OkLowerValue
        (IrValueGlobal (lower-name-cache-resolve names (intern-str name))))]
    [_
      (ErrLowerValue (lower-diagnostic "lower: unsupported global initializer"))]))

(define (lower-global-init-function-name [global-name : String]) : String
  (string-append "__global_init_" global-name))

(define (lower-top-decl-type-or-check
  [ctx : TcContext]
  [env : TcTypeEnv]
  [decl : AstDecl]) : ResultTcType
  (match decl
    [(AstDeclDef name _ _)
      (match (tc-lookup env name)
        [(OkTcType ty) (OkTcType ty)]
        [(ErrTcType _) (tc-top-decl-type-with-env ctx env decl)])]
    [_ (tc-top-decl-type-with-env ctx env decl)]))

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

;; Reusable per-function lowering scratch arena (#1917). Lowering one function
;; allocates a fresh `LowerState` plus the transient IR/AST-walk scratch the bump
;; allocator never frees; summed across cli.tl's ~5000 functions this transient
;; dominates the lower phase's peak live (the headline self-build memory number).
;; We lower each function inside one shared scratch arena and `arena-rewind` it
;; after deep-`clone`ing ONLY the produced IR function list back into the
;; enclosing (program) arena -- reclaiming the per-function transient before the
;; next function. The arena is created lazily once and reused (rewound, never
;; remapped) per function, mirroring the optimizer's per-function escape
;; (`optimize-function-escaping`). The spans side-table insertion is recomputed
;; in the enclosing arena (it never affects emitted assembly, only backend-error
;; source locations). `lower-function-escaping` is only ever called at decl
;; granularity (never re-entrant within `lower-function`'s body walk), so a
;; single shared mark/rewind region is sound. Output stays byte-identical: the
;; clone is a structural deep copy, so the escaped IR lowers to the same assembly
;; as the in-place IR did.
(define lower-scratch-arena : i64
  0)

(define (lower-scratch-arena-get) : i64
  (if (= lower-scratch-arena 0)
    (let
      [scratch : i64 (arena-make)]
      (begin
        (set! lower-scratch-arena scratch)
        scratch))
    lower-scratch-arena))

(define (lower-function-escaping
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [logical-name : String]
  [params : AstParamList]
  [ret : AstType]
  [body : AstExpr]
  [spans : CompilerSourceSpans]
  [names : LowerNameCache]
  [mode : CompilerLowerMode]) : ResultLowerFunction
  (let
    [enclosing : i64 (arena-current)]
    [scratch : i64 (lower-scratch-arena-get)]
    (begin
      (unsafe
        (arena-set! scratch))
      (let
        [mark : i64 (arena-mark)]
        (match (lower-function
          ctx
          top-env
          type-cache
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
                (unsafe
                  (arena-set! enclosing))
                (let
                  [escaped-fns : CompilerIrFunctionList
                    (compiler-ir-clone-function-list fns)]
                  [escaped-spans : CompilerSourceSpans
                    (lower-record-function-span spans logical-name body)]
                  [new-enclosing : i64 (arena-current)]
                  (begin
                    (unsafe
                      (arena-set! scratch-head)
                      (arena-rewind mark)
                      (arena-set! new-enclosing))
                    (OkLowerFunction escaped-fns escaped-spans)))))]
          [(ErrLowerFunction message)
            (let
              [scratch-head : i64 (arena-current)]
              (begin
                (unsafe
                  (arena-set! enclosing))
                (let
                  [escaped-message : CompilerDiagnostic (clone message)]
                  [new-enclosing : i64 (arena-current)]
                  (begin
                    (unsafe
                      (arena-set! scratch-head)
                      (arena-rewind mark)
                      (arena-set! new-enclosing))
                    (ErrLowerFunction escaped-message)))))])))))

(define (lower-struct-cleanup-param-name) : String
  "__tl_cleanup_value")

(define (lower-struct-cleanup-qualified-name
  [struct-name : String]
  [cleanup-name : String]) : String
  (if (tc-name-qualified? cleanup-name)
    cleanup-name
    (compiler-symbol-module-key
      (tc-qualified-name-module struct-name)
      cleanup-name)))

(define (lower-struct-cleanup-name-for-struct
  [ctx : TcContext]
  [struct-name : String]) : ResultTcString
  (match (tc-struct-decl ctx struct-name)
    [(OkTcStructDecl decl)
      (match decl
        [(TcStructDecl _ cleanup _)
          (match cleanup
            [(AstStructCleanupFn cleanup-name)
              (OkTcString
                (lower-struct-cleanup-qualified-name struct-name cleanup-name))]
            [(AstStructNoCleanup)
              (ErrTcString
                (string-append
                  "lower: owned cleanup field type has no cleanup function "
                  struct-name))])])]
    [(ErrTcStructDecl message) (ErrTcString message)]))

(define (lower-struct-cleanup-name-for-type [ctx : TcContext] [ty : AstType]) : ResultTcString
  (let
    [resolved : AstType (tc-type-strip-region (tc-resolve-type ctx ty))]
    (match resolved
      [(AstTyStruct name) (lower-struct-cleanup-name-for-struct ctx name)]
      [(AstTyStructArgs name _) (lower-struct-cleanup-name-for-struct ctx name)]
      [_
        (ErrTcString
          (string-append
            "lower: owned cleanup field type is not a cleanup-owning struct "
            (tc-type-render resolved)))])))

(define (lower-struct-cleanup-call-expr
  [cleanup-name : String]
  [value-name : String]
  [field-name : String]) : i64
  (ast-expr-call
    (ast-node-push (AstExprVar (intern cleanup-name)))
    (ast-expr-cons
      (ast-expr-struct-get
        (ast-node-push (AstExprVar (intern value-name)))
        field-name)
      AstExprNil)))

(define (lower-struct-cleanup-field-exprs
  [ctx : TcContext]
  [value-name : String]
  [field : AstFieldDef]
  [acc : AstExprList]) : ResultAstExprList
  (match field
    [(AstFieldDef field-name ty cleanup)
      (match cleanup
        [(AstFieldNoCleanup) (OkAstExprList acc)]
        [(AstFieldCleanupFn cleanup-name)
          (OkAstExprList
            (ast-expr-cons
              (lower-struct-cleanup-call-expr
                cleanup-name
                value-name
                field-name)
              acc))]
        [(AstFieldOwnedCleanup)
          (match (lower-struct-cleanup-name-for-type ctx ty)
            [(OkTcString cleanup-name)
              (OkAstExprList
                (ast-expr-cons
                  (lower-struct-cleanup-call-expr
                    cleanup-name
                    value-name
                    field-name)
                  acc))]
            [(ErrTcString message) (ErrAstExprList message)])])]))

(define (lower-struct-cleanup-body-fields
  [ctx : TcContext]
  [value-name : String]
  [fields : AstFieldDefList]
  [acc : AstExprList]) : ResultAstExprList
  (match fields
    [(AstFieldDefNil) (OkAstExprList acc)]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match (lower-struct-cleanup-field-exprs ctx value-name field acc)
          [(OkAstExprList next)
            (lower-struct-cleanup-body-fields ctx value-name rest next)]
          [(ErrAstExprList message) (ErrAstExprList message)]))]))

(define (lower-struct-cleanup-function
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [logical-name : String]
  [struct-ty : AstType]
  [fields : AstFieldDefList]
  [spans : CompilerSourceSpans]
  [names : LowerNameCache]
  [mode : CompilerLowerMode]) : ResultLowerFunction
  (let
    [value-name : String (lower-struct-cleanup-param-name)]
    (match (lower-struct-cleanup-body-fields ctx value-name fields AstExprNil)
      [(OkAstExprList exprs)
        (let
          [params : AstParamList
            (ast-param-cons (AstParam value-name struct-ty false) AstParamNil)]
          [body : AstExpr
            (match exprs
              [(AstExprNil) (AstExprLiteral AstLitUnit)]
              [_ (AstExprBegin exprs)])]
          (lower-function-escaping
            ctx
            top-env
            type-cache
            logical-name
            params
            (AstTyUnit)
            body
            spans
            names
            mode))]
      [(ErrAstExprList message) (ErrLowerFunction (lower-diagnostic message))])))

(define (lower-struct-cleanup-decl
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [logical-name : String]
  [cleanup : AstStructCleanup]
  [struct-ty : AstType]
  [fields : AstFieldDefList]
  [spans : CompilerSourceSpans]
  [names : LowerNameCache]
  [mode : CompilerLowerMode]) : ResultLowerFunction
  (match cleanup
    [(AstStructNoCleanup) (OkLowerFunction IrFunctionNil spans)]
    [(AstStructCleanupFn _)
      (lower-struct-cleanup-function
        ctx
        top-env
        type-cache
        logical-name
        struct-ty
        fields
        spans
        names
        mode)]))

(define (lower-dispatch-cache-name [logical-name : String]) : String
  (string-append "__tl_dispatch_cache_" logical-name))

(define (lower-dispatch-variant-prefix [isa : AstDispatchIsa]) : String
  (match isa
    [(AstDispatchScalar) "__tl_dispatch_variant_scalar_"]
    [(AstDispatchAvx2) "__tl_dispatch_variant_avx2_"]
    [(AstDispatchAvx512) "__tl_dispatch_variant_avx512_"]))

(define (lower-dispatch-variant-internal-name
  [dispatch-name : String]
  [isa : AstDispatchIsa]
  [variant-name : String]) : String
  (string-append
    (lower-dispatch-variant-prefix isa)
    (string-append dispatch-name (string-append "__" variant-name))))

(define (lower-dispatch-lower-mode
  [isa : AstDispatchIsa]
  [mode : CompilerLowerMode]) : CompilerLowerMode
  (match isa
    [(AstDispatchScalar)
      (if (lower-mode-windows-c-abi? mode)
        (CompilerLowerWindowsScalar)
        (if (lower-mode-linux-c-abi? mode)
          (CompilerLowerLinuxScalar)
          (CompilerLowerScalar)))]
    [(AstDispatchAvx2)
      (if (lower-mode-windows-c-abi? mode)
        (CompilerLowerWindowsAvx2)
        (if (lower-mode-linux-c-abi? mode)
          (CompilerLowerLinuxAvx2)
          (CompilerLowerAvx2)))]
    [(AstDispatchAvx512)
      (if (lower-mode-windows-c-abi? mode)
        (CompilerLowerWindowsAvx512)
        (if (lower-mode-linux-c-abi? mode)
          (CompilerLowerLinuxAvx512)
          (CompilerLowerAvx512)))]))

(define (lower-dispatch-type-list-without-regions [types : AstTypeList]) : AstTypeList
  (match types
    [(AstTypeNil) AstTypeNil]
    [(AstTypeCons ty rest)
      (let
        [ty : AstType (ty-node-get ty)]
        [rest : AstTypeList (box-get rest)]
        (ast-type-cons
          (tc-type-without-regions ty)
          (lower-dispatch-type-list-without-regions rest)))]))

(define (lower-dispatch-param-type-count [types : AstTypeList]) : i64
  (match types
    [(AstTypeNil) 0]
    [(AstTypeCons _ rest)
      (let
        [rest : AstTypeList (box-get rest)]
        (+ 1 (lower-dispatch-param-type-count rest)))]))

(define (lower-dispatch-param-list-from-types [types : AstTypeList] [idx : i64]) : CompilerIrParamList
  (match types
    [(AstTypeNil) IrParamNil]
    [(AstTypeCons ty rest)
      (let
        [ty : AstType (ty-node-get ty)]
        [rest : AstTypeList (box-get rest)]
        (compiler-ir-param-cons
          (IrParam
            (string-append "arg" (int->string idx))
            (tc-type-without-regions ty)
            idx)
          (lower-dispatch-param-list-from-types rest (+ idx 1))))]))

(define (lower-dispatch-param-values [types : AstTypeList] [idx : i64]) : CompilerIrValueList
  (match types
    [(AstTypeNil) IrValueNil]
    [(AstTypeCons _ rest)
      (let
        [rest : AstTypeList (box-get rest)]
        (compiler-ir-value-cons
          (IrValueVar idx)
          (lower-dispatch-param-values rest (+ idx 1))))]))

(define (lower-dispatch-find-internal-name
  [variants : AstDispatchVariantList]
  [module : String]
  [names : LowerNameCache]
  [dispatch-name : String]
  [wanted : AstDispatchIsa]) : TcMaybeString
  (match variants
    [(AstDispatchVariantNil) (TcNoString)]
    [(AstDispatchVariantCons variant rest)
      (let
        [rest : AstDispatchVariantList (box-get rest)]
        (match variant
          [(AstDispatchVariant isa variant-name)
            (if (tc-dispatch-isa-eq? isa wanted)
              (TcSomeString
                (lower-dispatch-variant-internal-name
                  dispatch-name
                  isa
                  (lower-dispatch-variant-logical-name
                    module
                    names
                    variant-name)))
              (lower-dispatch-find-internal-name
                rest
                module
                names
                dispatch-name
                wanted))]))]))

(define (lower-dispatch-call-return-instr [call-var : i64] [ret-ty : AstType]) : CompilerIrInstr
  (IrInstrReturn (lower-return-maybe (IrValueVar call-var) ret-ty)))

(define (lower-dispatch-cached-block
  [cache-name : String]
  [args : CompilerIrCallArgs]
  [ret-ty : AstType]
  [call-var : i64]) : CompilerIrBlock
  (compiler-ir-block
    "cached"
    (compiler-ir-instr-cons
      (IrInstrCallIndirect call-var (IrValueGlobal cache-name) args ret-ty)
      (compiler-ir-instr-cons
        (lower-dispatch-call-return-instr call-var ret-ty)
        IrInstrNil))))

(define (lower-dispatch-select-block
  [label : String]
  [cache-name : String]
  [fn-name : String]
  [fn-ty : AstType]
  [args : CompilerIrCallArgs]
  [ret-ty : AstType]
  [call-var : i64]) : CompilerIrBlock
  (compiler-ir-block
    label
    (compiler-ir-instr-cons
      (IrInstrStore cache-name (IrValueFunction fn-name) fn-ty)
      (compiler-ir-instr-cons
        (IrInstrCallIndirect call-var (IrValueFunction fn-name) args ret-ty)
        (compiler-ir-instr-cons
          (lower-dispatch-call-return-instr call-var ret-ty)
          IrInstrNil)))))

(define (lower-dispatch-entry-block
  [cache-name : String]
  [fn-ty : AstType]
  [cached-var : i64]
  [resolve-label : String]) : CompilerIrBlock
  (compiler-ir-block
    "entry"
    (compiler-ir-instr-cons
      (IrInstrBinOp
        cached-var
        IrBinNe
        (IrValueGlobal cache-name)
        (IrValueI64 0)
        (AstTyBool))
      (compiler-ir-instr-cons
        (IrInstrBranch (IrValueVar cached-var) "cached" resolve-label)
        IrInstrNil))))

(define (lower-dispatch-feature-blocks
  [prefix : String]
  [xcr0-mask : i64]
  [feature-mask : i64]
  [select-label : String]
  [fallback-label : String]
  [base : i64]
  [tail : CompilerIrBlockList]) : CompilerIrBlockList
  (let
    [check-label : String (clone prefix)]
    [osxsave-label : String (string-append (clone prefix) "_osxsave")]
    [xcr0-label : String (string-append (clone prefix) "_xcr0")]
    [leaf7-label : String (string-append prefix "_leaf7")]
    [max-leaf-var : i64 base]
    [max-ok-var : i64 (+ base 1)]
    [leaf1-ecx-var : i64 (+ base 2)]
    [osxsave-mask-var : i64 (+ base 3)]
    [osxsave-ok-var : i64 (+ base 4)]
    [xcr0-var : i64 (+ base 5)]
    [xcr0-mask-var : i64 (+ base 6)]
    [xcr0-ok-var : i64 (+ base 7)]
    [leaf7-ebx-var : i64 (+ base 8)]
    [feature-mask-var : i64 (+ base 9)]
    [feature-ok-var : i64 (+ base 10)]
    (compiler-ir-block-cons
      (compiler-ir-block
        check-label
        (compiler-ir-instr-cons
          (IrInstrCpuId max-leaf-var (IrValueI64 0) (IrValueI64 0) 0)
          (compiler-ir-instr-cons
            (IrInstrBinOp
              max-ok-var
              IrBinGe
              (IrValueVar max-leaf-var)
              (IrValueI64 7)
              (AstTyBool))
            (compiler-ir-instr-cons
              (IrInstrBranch
                (IrValueVar max-ok-var)
                osxsave-label
                fallback-label)
              IrInstrNil))))
      (compiler-ir-block-cons
        (compiler-ir-block
          osxsave-label
          (compiler-ir-instr-cons
            (IrInstrCpuId leaf1-ecx-var (IrValueI64 1) (IrValueI64 0) 2)
            (compiler-ir-instr-cons
              (IrInstrBinOp
                osxsave-mask-var
                IrBinBitAnd
                (IrValueVar leaf1-ecx-var)
                (IrValueI64 134217728)
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrBinOp
                  osxsave-ok-var
                  IrBinNe
                  (IrValueVar osxsave-mask-var)
                  (IrValueI64 0)
                  (AstTyBool))
                (compiler-ir-instr-cons
                  (IrInstrBranch
                    (IrValueVar osxsave-ok-var)
                    xcr0-label
                    fallback-label)
                  IrInstrNil)))))
        (compiler-ir-block-cons
          (compiler-ir-block
            xcr0-label
            (compiler-ir-instr-cons
              (IrInstrXgetbv xcr0-var (IrValueI64 0))
              (compiler-ir-instr-cons
                (IrInstrBinOp
                  xcr0-mask-var
                  IrBinBitAnd
                  (IrValueVar xcr0-var)
                  (IrValueI64 xcr0-mask)
                  (AstTyI64))
                (compiler-ir-instr-cons
                  (IrInstrBinOp
                    xcr0-ok-var
                    IrBinEq
                    (IrValueVar xcr0-mask-var)
                    (IrValueI64 xcr0-mask)
                    (AstTyBool))
                  (compiler-ir-instr-cons
                    (IrInstrBranch
                      (IrValueVar xcr0-ok-var)
                      leaf7-label
                      fallback-label)
                    IrInstrNil)))))
          (compiler-ir-block-cons
            (compiler-ir-block
              leaf7-label
              (compiler-ir-instr-cons
                (IrInstrCpuId leaf7-ebx-var (IrValueI64 7) (IrValueI64 0) 1)
                (compiler-ir-instr-cons
                  (IrInstrBinOp
                    feature-mask-var
                    IrBinBitAnd
                    (IrValueVar leaf7-ebx-var)
                    (IrValueI64 feature-mask)
                    (AstTyI64))
                  (compiler-ir-instr-cons
                    (IrInstrBinOp
                      feature-ok-var
                      IrBinNe
                      (IrValueVar feature-mask-var)
                      (IrValueI64 0)
                      (AstTyBool))
                    (compiler-ir-instr-cons
                      (IrInstrBranch
                        (IrValueVar feature-ok-var)
                        select-label
                        fallback-label)
                      IrInstrNil)))))
            tail))))))

(define (lower-dispatch-select-blocks
  [cache-name : String]
  [fn-ty : AstType]
  [args : CompilerIrCallArgs]
  [ret-ty : AstType]
  [scalar-name : String]
  [maybe-avx2 : TcMaybeString]
  [maybe-avx512 : TcMaybeString]
  [base : i64]) : CompilerIrBlockList
  (let
    [scalar-blocks : CompilerIrBlockList
      (compiler-ir-block-cons
        (lower-dispatch-select-block
          "select_scalar"
          cache-name
          scalar-name
          fn-ty
          args
          ret-ty
          (+ base 24))
        IrBlockNil)]
    [with-avx2 : CompilerIrBlockList
      (match maybe-avx2
        [(TcSomeString avx2-name)
          (compiler-ir-block-cons
            (lower-dispatch-select-block
              "select_avx2"
              cache-name
              avx2-name
              fn-ty
              args
              ret-ty
              (+ base 25))
            scalar-blocks)]
        [(TcNoString) scalar-blocks])]
    (match maybe-avx512
      [(TcSomeString avx512-name)
        (compiler-ir-block-cons
          (lower-dispatch-select-block
            "select_avx512"
            cache-name
            avx512-name
            fn-ty
            args
            ret-ty
            (+ base 26))
          with-avx2)]
      [(TcNoString) with-avx2])))

(define (lower-dispatch-resolve-label
  [maybe-avx2 : TcMaybeString]
  [maybe-avx512 : TcMaybeString]) : String
  (match maybe-avx512
    [(TcSomeString _) "check_avx512"]
    [(TcNoString)
      (match maybe-avx2
        [(TcSomeString _) "check_avx2"]
        [(TcNoString) "select_scalar"])]))

(define (lower-dispatch-resolve-blocks
  [maybe-avx2 : TcMaybeString]
  [maybe-avx512 : TcMaybeString]
  [base : i64]
  [tail : CompilerIrBlockList]) : CompilerIrBlockList
  (let
    [with-avx2 : CompilerIrBlockList
      (match maybe-avx2
        [(TcSomeString _)
          (lower-dispatch-feature-blocks
            "check_avx2"
            6
            32
            "select_avx2"
            "select_scalar"
            (+ base 12)
            tail)]
        [(TcNoString) tail])]
    (match maybe-avx512
      [(TcSomeString _)
        (lower-dispatch-feature-blocks
          "check_avx512"
          230
          65536
          "select_avx512"
          (match maybe-avx2
            [(TcSomeString _) "check_avx2"]
            [(TcNoString) "select_scalar"])
          (+ base 1)
          with-avx2)]
      [(TcNoString) with-avx2])))

(define (lower-dispatch-thunk-function
  [logical-name : String]
  [fn-ty : AstType]
  [variants : AstDispatchVariantList]
  [module : String]
  [names : LowerNameCache]
  [spans : CompilerSourceSpans]) : ResultLowerFunction
  (match fn-ty
    [(AstTyFunc param-types ret-box)
      (let
        [ret-ty : AstType (tc-type-without-regions (ty-node-get ret-box))]
        [clean-param-types : AstTypeList
          (lower-dispatch-type-list-without-regions param-types)]
        [param-count : i64 (lower-dispatch-param-type-count clean-param-types)]
        [cache-name : String (lower-dispatch-cache-name logical-name)]
        [args : CompilerIrCallArgs
          (compiler-ir-call-args-from-list
            (lower-dispatch-param-values clean-param-types 0))]
        [maybe-avx2 : TcMaybeString
          (lower-dispatch-find-internal-name
            variants
            module
            names
            logical-name
            (AstDispatchAvx2))]
        [maybe-avx512 : TcMaybeString
          (lower-dispatch-find-internal-name
            variants
            module
            names
            logical-name
            (AstDispatchAvx512))]
        (match (lower-dispatch-find-internal-name
          variants
          module
          names
          logical-name
          (AstDispatchScalar))
          [(TcSomeString scalar-name)
            (let
              [blocks : CompilerIrBlockList
                (compiler-ir-block-cons
                  (lower-dispatch-entry-block
                    cache-name
                    fn-ty
                    param-count
                    (lower-dispatch-resolve-label maybe-avx2 maybe-avx512))
                  (compiler-ir-block-cons
                    (lower-dispatch-cached-block
                      cache-name
                      args
                      ret-ty
                      (+ param-count 23))
                    (lower-dispatch-resolve-blocks
                      maybe-avx2
                      maybe-avx512
                      param-count
                      (lower-dispatch-select-blocks
                        cache-name
                        fn-ty
                        args
                        ret-ty
                        scalar-name
                        maybe-avx2
                        maybe-avx512
                        param-count))))]
              (OkLowerFunction
                (compiler-ir-function-cons
                  (IrFunction
                    logical-name
                    (lower-dispatch-param-list-from-types clean-param-types 0)
                    ret-ty
                    (+ param-count 27)
                    blocks)
                  IrFunctionNil)
                spans))]
          [(TcNoString)
            (ErrLowerFunction
              (lower-diagnostic "lower: defdispatch requires a scalar variant"))]))]
    [_
      (ErrLowerFunction
        (lower-diagnostic "lower: defdispatch did not typecheck as a function"))]))

(define (lower-dispatch-lower-variant-decl
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [internal-name : String]
  [isa : AstDispatchIsa]
  [decl : AstDecl]
  [spans : CompilerSourceSpans]
  [names : LowerNameCache]
  [mode : CompilerLowerMode]) : ResultLowerFunction
  (match decl
    [(AstDeclDefFn _ params ret body-box _)
      (let
        [body : AstExpr (ast-node-get body-box)]
        (lower-function-escaping
          ctx
          top-env
          type-cache
          internal-name
          params
          ret
          body
          spans
          names
          (lower-dispatch-lower-mode isa mode)))]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (lower-dispatch-lower-variant-decl
          ctx
          top-env
          type-cache
          internal-name
          isa
          inner
          spans
          names
          mode))]
    [_
      (ErrLowerFunction
        (lower-diagnostic "lower: defdispatch variants must be local functions"))]))

(define (lower-dispatch-lower-variant
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [dispatch-name : String]
  [variant : AstDispatchVariant]
  [module : String]
  [spans : CompilerSourceSpans]
  [names : LowerNameCache]
  [mode : CompilerLowerMode]) : ResultLowerFunction
  (match variant
    [(AstDispatchVariant isa variant-name)
      (let
        [lookup-name : String (lower-dispatch-source-name module variant-name)]
        [variant-logical : String (lower-name-cache-resolve names lookup-name)]
        [internal-name : String
          (lower-dispatch-variant-internal-name
            dispatch-name
            isa
            variant-logical)]
        (match (compiler-symbols-lookup-value
          (tc-context-symbols ctx)
          lookup-name)
          [(SomeI64 handle)
            (match (compiler-program-decl-at-index
              (tc-context-program ctx)
              (compiler-symbol-handle-index handle))
              [(OkAstDecl decl)
                (lower-dispatch-lower-variant-decl
                  ctx
                  top-env
                  type-cache
                  internal-name
                  isa
                  decl
                  spans
                  names
                  mode)]
              [(ErrAstDecl message)
                (ErrLowerFunction (lower-diagnostic message))])]
          [(NoneI64)
            (ErrLowerFunction
              (lower-diagnostic
                (string-append
                  "lower: unknown defdispatch variant "
                  variant-name)))]))]))

(define (lower-dispatch-lower-variants
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [dispatch-name : String]
  [variants : AstDispatchVariantList]
  [module : String]
  [spans : CompilerSourceSpans]
  [names : LowerNameCache]
  [mode : CompilerLowerMode]
  [functions : CompilerIrFunctionList]) : ResultLowerFunction
  (match variants
    [(AstDispatchVariantNil) (OkLowerFunction functions spans)]
    [(AstDispatchVariantCons variant rest)
      (let
        [rest : AstDispatchVariantList (box-get rest)]
        (match (lower-dispatch-lower-variant
          ctx
          top-env
          type-cache
          dispatch-name
          variant
          module
          spans
          names
          mode)
          [(OkLowerFunction lowered-functions function-spans)
            (lower-dispatch-lower-variants
              ctx
              top-env
              type-cache
              dispatch-name
              rest
              module
              function-spans
              names
              mode
              (lower-function-list-append lowered-functions functions))]
          [(ErrLowerFunction message) (ErrLowerFunction message)]))]))

(define (lower-dispatch-decl
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [local-top-env : TcTypeEnv]
  [type-cache : LowerTypeCache]
  [name : String]
  [variants : AstDispatchVariantList]
  [spans : CompilerSourceSpans]
  [name-cache : LowerNameCache]
  [mode : CompilerLowerMode]
  [module : String]) : ResultLowerDispatchDecl
  (let
    [decl-ctx : TcContext (tc-context-with-module ctx module)]
    [logical-name : String
      (lower-current-decl-logical-name-cache name-cache module name)]
    (match (tc-lookup local-top-env name)
      [(OkTcType dispatch-ty)
        (let
          [fn-ty : AstType
            (tc-type-without-regions (tc-resolve-type decl-ctx dispatch-ty))]
          (match (lower-dispatch-lower-variants
            decl-ctx
            local-top-env
            type-cache
            logical-name
            variants
            module
            spans
            name-cache
            mode
            IrFunctionNil)
            [(OkLowerFunction variant-functions variant-spans)
              (match (lower-dispatch-thunk-function
                logical-name
                fn-ty
                variants
                module
                name-cache
                variant-spans)
                [(OkLowerFunction thunk-functions thunk-spans)
                  (OkLowerDispatchDecl
                    (LowerDispatchDecl
                      (IrGlobal
                        (lower-dispatch-cache-name logical-name)
                        fn-ty
                        (IrValueI64 0))
                      (lower-function-list-append
                        thunk-functions
                        variant-functions)
                      thunk-spans))]
                [(ErrLowerFunction message) (ErrLowerDispatchDecl message)])]
            [(ErrLowerFunction message) (ErrLowerDispatchDecl message)]))]
      [(ErrTcType message) (ErrLowerDispatchDecl (lower-diagnostic message))])))

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
  (let
    [name-cache : LowerNameCache (lower-name-cache-from-env names)]
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
      name-cache
      (lower-type-cache-from-env top-env)
      (lower-dispatch-variant-set-from-decls
        decls
        AstDeclPathNil
        "<source>"
        name-cache)
      mode
      "")))

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
  [type-cache : LowerTypeCache]
  [dispatch-variants : StringI64Map]
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
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclUnsafe inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (lower-decls-in-module
                ctx
                top-env
                local-top-env
                (ast-decl-cons inner rest)
                globals
                functions
                externs
                spans
                names
                name-cache
                type-cache
                dispatch-variants
                mode
                module))]
          [(AstDeclDef name _ expr-box)
            (let
              [expr : AstExpr (ast-node-get expr-box)]
              [decl-ctx : TcContext (tc-context-with-module ctx module)]
              (match (lower-top-decl-type-or-check decl-ctx local-top-env decl)
                [(OkTcType ty)
                  (let
                    [global-ty : AstType (tc-type-without-regions ty)]
                    [global-name : String
                      (lower-current-decl-logical-name-cache
                        name-cache
                        module
                        name)]
                    (match (lower-global-value name-cache expr)
                      [(OkLowerValue value)
                        (lower-decls-in-module
                          ctx
                          top-env
                          local-top-env
                          rest
                          (compiler-ir-global-cons
                            (IrGlobal global-name global-ty value)
                            globals)
                          functions
                          externs
                          spans
                          names
                          name-cache
                          type-cache
                          dispatch-variants
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
                          type-cache
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
                              (compiler-ir-global-cons
                                (IrGlobal global-name global-ty IrValueUnit)
                                globals)
                              (lower-function-list-append init-funcs functions)
                              externs
                              init-spans
                              names
                              name-cache
                              type-cache
                              dispatch-variants
                              mode
                              module)]
                          [(ErrLowerFunction init-message)
                            (ErrLowerDecls init-message)])]))]
                [(ErrTcType message) (ErrLowerDecls (lower-diagnostic message))]))]
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
                  (compiler-ir-extern-cons
                    (IrExtern
                      name
                      (tc-type-without-regions (tc-resolve-type decl-ctx ty))
                      (ast-extern-metadata-abi metadata)
                      (ast-extern-metadata-symbol metadata)
                      (ast-extern-metadata-link-inputs metadata)
                      false)
                    externs)
                  spans
                  names
                  name-cache
                  type-cache
                  dispatch-variants
                  mode
                  module)))]
          [(AstDeclDefFn name params ret body-box export)
            (let
              [body : AstExpr (ast-node-get body-box)]
              [decl-ctx : TcContext (tc-context-with-module ctx module)]
              [logical-name : String
                (lower-current-decl-logical-name-cache name-cache module name)]
              (if (string-i64-map-contains? dispatch-variants logical-name)
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
                  type-cache
                  dispatch-variants
                  mode
                  module)
                (begin
                  (cfg compile-profile (compiler-lower-profile-detail-start))
                  (match (lower-function-escaping
                    decl-ctx
                    local-top-env
                    type-cache
                    logical-name
                    params
                    ret
                    body
                    spans
                    name-cache
                    mode)
                    [(OkLowerFunction lowered-functions function-spans)
                      (let
                        [next-externs : CompilerIrExternList
                          (match export
                            [(AstFnNoExport) externs]
                            [(AstFnExport symbol)
                              (compiler-ir-extern-cons
                                (IrExtern
                                  logical-name
                                  (ast-ty-func
                                    (tc-type-list-without-regions
                                      (tc-param-type-list decl-ctx params))
                                    (tc-type-without-regions
                                      (tc-resolve-type decl-ctx ret)))
                                  (AstExternAbiC)
                                  symbol
                                  AstExternLinkInputNil
                                  true)
                                externs)])]
                        (begin
                          (cfg
                            compile-profile
                            (compiler-lower-profile-detail-finish
                              "function"
                              logical-name))
                          (lower-decls-in-module
                            ctx
                            top-env
                            local-top-env
                            rest
                            globals
                            (lower-function-list-append
                              lowered-functions
                              functions)
                            next-externs
                            function-spans
                            names
                            name-cache
                            type-cache
                            dispatch-variants
                            mode
                            module)))]
                    [(ErrLowerFunction message)
                      (begin
                        (cfg
                          compile-profile
                          (compiler-lower-profile-detail-finish
                            "function"
                            logical-name))
                        (ErrLowerDecls message))]))))]
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
              type-cache
              dispatch-variants
              mode
              module)]
          [(AstDeclDefDispatch name variants)
            (match (lower-dispatch-decl
              ctx
              top-env
              local-top-env
              type-cache
              name
              variants
              spans
              name-cache
              mode
              module)
              [(OkLowerDispatchDecl lowered)
                (match lowered
                  [(LowerDispatchDecl
                      cache-global
                      lowered-functions
                      function-spans)
                    (lower-decls-in-module
                      ctx
                      top-env
                      local-top-env
                      rest
                      (compiler-ir-global-cons cache-global globals)
                      (lower-function-list-append lowered-functions functions)
                      externs
                      function-spans
                      names
                      name-cache
                      type-cache
                      dispatch-variants
                      mode
                      module)])]
              [(ErrLowerDispatchDecl message) (ErrLowerDecls message)])]
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
              type-cache
              dispatch-variants
              mode
              module)]
          [(AstDeclIncludeStr _ _)
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
              type-cache
              dispatch-variants
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
              type-cache
              dispatch-variants
              mode
              module)]
          [(AstDeclModule next-module)
            (match (lower-module-local-envs ctx top-env names next-module)
              [(OkLowerModuleLocalEnv next-local-top-env local-names)
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
                  (lower-type-cache-from-env next-local-top-env)
                  dispatch-variants
                  mode
                  next-module)]
              [(ErrLowerModuleLocalEnv message)
                (ErrLowerDecls (lower-diagnostic message))])]
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
              type-cache
              dispatch-variants
              mode
              module)]
          [(AstDeclDefEnum name _ variants)
            (lower-decls-in-module
              ctx
              top-env
              local-top-env
              rest
              (lower-nullary-variant-globals
                (lower-current-decl-logical-name-cache name-cache module name)
                variants
                0
                globals)
              functions
              externs
              spans
              names
              name-cache
              type-cache
              dispatch-variants
              mode
              module)]
          [(AstDeclDefEnumLifetimes name _ _ variants)
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
              type-cache
              dispatch-variants
              mode
              module)]
          [(AstDeclDefStruct name _ cleanup fields)
            (let
              [decl-ctx : TcContext (tc-context-with-module ctx module)]
              [logical-name : String
                (match cleanup
                  [(AstStructNoCleanup) ""]
                  [(AstStructCleanupFn cleanup-name)
                    (lower-current-decl-logical-name-cache
                      name-cache
                      module
                      cleanup-name)])]
              [struct-ty : AstType
                (AstTyStruct (compiler-symbol-module-key module name))]
              (match (lower-struct-cleanup-decl
                decl-ctx
                local-top-env
                type-cache
                logical-name
                cleanup
                struct-ty
                fields
                spans
                name-cache
                mode)
                [(OkLowerFunction cleanup-functions cleanup-spans)
                  (lower-decls-in-module
                    ctx
                    top-env
                    local-top-env
                    rest
                    globals
                    (lower-function-list-append cleanup-functions functions)
                    externs
                    cleanup-spans
                    names
                    name-cache
                    type-cache
                    dispatch-variants
                    mode
                    module)]
                [(ErrLowerFunction message) (ErrLowerDecls message)]))]
          [(AstDeclDefStructLifetimes name lifetimes _ cleanup fields)
            (let
              [decl-ctx : TcContext (tc-context-with-module ctx module)]
              [logical-name : String
                (match cleanup
                  [(AstStructNoCleanup) ""]
                  [(AstStructCleanupFn cleanup-name)
                    (lower-current-decl-logical-name-cache
                      name-cache
                      module
                      cleanup-name)])]
              [struct-ty : AstType
                (AstTyStructArgs
                  (compiler-symbol-module-key module name)
                  lifetimes)]
              (match (lower-struct-cleanup-decl
                decl-ctx
                local-top-env
                type-cache
                logical-name
                cleanup
                struct-ty
                fields
                spans
                name-cache
                mode)
                [(OkLowerFunction cleanup-functions cleanup-spans)
                  (lower-decls-in-module
                    ctx
                    top-env
                    local-top-env
                    rest
                    globals
                    (lower-function-list-append cleanup-functions functions)
                    externs
                    cleanup-spans
                    names
                    name-cache
                    type-cache
                    dispatch-variants
                    mode
                    module)]
                [(ErrLowerFunction message) (ErrLowerDecls message)]))]
          [(AstDeclComptimeDecl _ template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (lower-decls-in-module
                ctx
                top-env
                local-top-env
                (ast-decl-cons template rest)
                globals
                functions
                externs
                spans
                names
                name-cache
                type-cache
                dispatch-variants
                mode
                module))]))]))

(define (lower-compiler-program-checked-with-names-mode
  [ctx : TcContext]
  [top-env : TcTypeEnv]
  [program : AstProgram]
  [names : LowerNameEnv]
  [mode : CompilerLowerMode]) : ResultCompilerLower
  (begin
    (lower-refresh-marker-ids!)
    (match program
      [(AstProgram decls-box)
        (let
          [decls : AstDeclList (box-get decls-box)]
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
            [(ErrLowerDecls message) (ErrCompilerLower message)]))])))

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
      (match (typecheck-compiler-specialized-program-with-paths-checked
        specialized
        AstDeclPathNil)
        [(OkCompilerTypecheckChecked _ ctx top-env)
          (let
            [alias-names : LowerNameEnv
              (match specialized
                [(AstProgram decls-box)
                  (let
                    [decls : AstDeclList (box-get decls-box)]
                    (lower-name-env-with-import-aliases
                      decls
                      AstDeclPathNil
                      "<source>"
                      LowerNameNil
                      false))])]
            (lower-compiler-program-checked-with-names-mode
              ctx
              top-env
              specialized
              alias-names
              mode))]
        [(ErrCompilerTypecheckChecked diag) (ErrCompilerLower diag)])]
    [(ErrSpecProgram diag) (ErrCompilerLower diag)]))

(define (lower-compiler-program-unlocated-mode
  [program : AstProgram]
  [mode : CompilerLowerMode])
  :
  ResultCompilerLower
  ;; Generate declaration families before macro expansion (see
  ;; typecheck-compiler-program-with-paths for why).
  (match (gen-normalize-program program)
    [(OkGenProgram generated)
      (match (macro-expand-program generated)
        [(OkMacroExpand expanded)
          (lower-compiler-expanded-program-unlocated-mode expanded mode)]
        [(ErrMacroExpand diag) (ErrCompilerLower diag)])]
    [(ErrGenProgram diag) (ErrCompilerLower diag)]))

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
  (begin
    (cfg compile-profile (compiler-lower-profile-start))
    (let
      [needs-specialization : bool (compiler-specialize-needed? program)]
      [specialized-paths : AstDeclPathList
        (if needs-specialization
          AstDeclPathNil
          paths)]
      [names : LowerNameEnv
        (match program
          [(AstProgram decls-box)
            (let
              [decls : AstDeclList (box-get decls-box)]
              (lower-name-env-from-decls decls paths entry-path LowerNameNil))])]
      (match (compiler-specialize-program program)
        [(OkSpecProgram specialized)
          (begin
            (cfg compile-profile (compiler-lower-profile-finish "specialize"))
            (cfg compile-profile (compiler-lower-profile-start))
            (let
              [prune-names : LowerNameEnv
                (if needs-specialization
                  (match specialized
                    [(AstProgram decls-box)
                      (let
                        [decls : AstDeclList (box-get decls-box)]
                        (lower-name-env-from-decls
                          decls
                          specialized-paths
                          entry-path
                          LowerNameNil))])
                  names)]
              (match (lower-prune-unreachable-functions-with-clone-roots
                entry-path
                specialized
                specialized-paths
                prune-names
                (CloneNameNil))
                [(LowerPrunedProgram base-program base-paths)
                  (begin
                    (cfg
                      compile-profile
                      (compiler-lower-profile-finish "prune"))
                    (cfg compile-profile (compiler-lower-profile-start))
                    (match (lower-reachable-clone-roots
                      base-program
                      base-paths
                      prune-names)
                      [(OkLowerCloneRoots clone-roots)
                        (begin
                          (cfg
                            compile-profile
                            (compiler-lower-profile-finish "clone_roots"))
                          (cfg compile-profile (compiler-lower-profile-start))
                          (let
                            [checked-program : AstProgram
                              (clone-augment-program-with-roots
                                base-program
                                clone-roots)]
                            [checked-paths : AstDeclPathList base-paths]
                            [checked-names : LowerNameEnv
                              (match checked-program
                                [(AstProgram decls-box)
                                  (let
                                    [decls : AstDeclList (box-get decls-box)]
                                    (lower-name-env-from-decls
                                      decls
                                      checked-paths
                                      entry-path
                                      LowerNameNil))])]
                            [lower-names : LowerNameEnv
                              (if needs-specialization
                                (match checked-program
                                  [(AstProgram decls-box)
                                    (let
                                      [decls : AstDeclList (box-get decls-box)]
                                      (lower-name-env-add-clone-decls
                                        decls
                                        checked-paths
                                        entry-path
                                        names))])
                                checked-names)]
                            (begin
                              (cfg
                                compile-profile
                                (compiler-lower-profile-finish
                                  "clone_augment_names"))
                              (cfg
                                compile-profile
                                (compiler-lower-profile-start))
                              (match (typecheck-compiler-specialized-program-with-paths-checked
                                checked-program
                                checked-paths)
                                [(OkCompilerTypecheckChecked _ ctx top-env)
                                  (begin
                                    (cfg
                                      compile-profile
                                      (compiler-lower-profile-finish
                                        "typecheck"))
                                    (cfg
                                      compile-profile
                                      (compiler-lower-profile-start))
                                    (match (lower-compiler-program-checked-with-names-mode
                                      ctx
                                      top-env
                                      checked-program
                                      lower-names
                                      mode)
                                      [(OkCompilerLower ir spans)
                                        (begin
                                          (cfg
                                            compile-profile
                                            (compiler-lower-profile-finish
                                              "decls"))
                                          (OkCompilerLower ir spans))]
                                      [(ErrCompilerLower diag)
                                        (begin
                                          (cfg
                                            compile-profile
                                            (compiler-lower-profile-finish
                                              "decls"))
                                          (ErrCompilerLower
                                            (lower-diagnostic-with-path
                                              diag
                                              entry-path)))]))]
                                [(ErrCompilerTypecheckChecked diag)
                                  (begin
                                    (cfg
                                      compile-profile
                                      (compiler-lower-profile-finish
                                        "typecheck"))
                                    (ErrCompilerLower diag))]))))]
                      [(ErrLowerCloneRoots diag)
                        (begin
                          (cfg
                            compile-profile
                            (compiler-lower-profile-finish "clone_roots"))
                          (ErrCompilerLower diag))]))])))]
        [(ErrSpecProgram diag)
          (begin
            (cfg compile-profile (compiler-lower-profile-finish "specialize"))
            (ErrCompilerLower (lower-diagnostic-with-path diag entry-path)))]))))

(define (lower-compiler-program-with-decl-paths-mode
  [entry-path : String]
  [program : AstProgram]
  [paths : AstDeclPathList]
  [mode : CompilerLowerMode]) : ResultCompilerLower
  (begin
    (cfg compile-profile (compiler-lower-profile-start))
    ;; Generate declaration families before macro expansion (see
    ;; typecheck-compiler-program-with-paths for why).
    (match (gen-normalize-program-with-paths program paths entry-path)
      [(OkGenProgramWithPaths generated generated-paths)
        (match (macro-expand-program generated)
          [(OkMacroExpand expanded)
            (begin
              (cfg
                compile-profile
                (compiler-lower-profile-finish "macro_expand"))
              (lower-compiler-expanded-program-with-decl-paths-mode
                entry-path
                expanded
                generated-paths
                mode))]
          [(ErrMacroExpand diag)
            (begin
              (cfg
                compile-profile
                (compiler-lower-profile-finish "macro_expand"))
              (ErrCompilerLower (lower-diagnostic-with-path diag entry-path)))])]
      [(ErrGenProgramWithPaths diag)
        (begin
          (cfg compile-profile (compiler-lower-profile-finish "macro_expand"))
          (ErrCompilerLower (lower-diagnostic-with-path diag entry-path)))])))

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
  (begin
    ;; Each standalone single-source compile (smoke self-tests, emit-source,
    ;; check tools) runs in a fresh arena, so interned name strings from a
    ;; previous compile are freed. Reset the persistent intern table here so a
    ;; later compile never probes a dangling key. The multi-file driver compiles
    ;; through the loader, not this entry, so cli.tl's fixpoint is unaffected.
    (intern-reset!)
    (match (parse-ast-source src)
      [(OkAstProgram program)
        (lower-compiler-program-with-path-mode path program mode)]
      [(ErrAstProgram message)
        (ErrCompilerLower
          (lower-diagnostic-with-path (lower-diagnostic message) path))])))

(define (lower-compiler-source-with-path [path : String] [src : String]) : ResultCompilerLower
  (lower-compiler-source-with-path-mode path src (CompilerLowerScalar)))

(define (compiler-lower-smoke-source) : String
  "(extern (print-i64 [arg0 : i64]) : unit)
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

(define (compiler-lower-macro-hygiene-definition-source) : String
  "(define (macro-helper [x : bool]) : bool (not x))
(defmacro (unless2 [condition : bool] [body : unit]) : unit
  `(if (macro-helper ,condition)
     ,body
     unit))
(define (main) : unit
  (let ([macro-helper : bool true])
    (unless2 false unit)))")

;; A fixed-array literal `(array ...)`: it type-checks to `(Array i64 N)` and now
;; lowers to inline storage with each element stored at its offset, returning the
;; storage pointer (the same representation `array-ref`/`array-set!` index off).
(define (compiler-lower-array-literal-source) : String
  "(define (main) : i64
  (let [a : (Array i64 3) (array 1 2 3)]
    (array-ref a 2)))")

(define (compiler-lower-fixed-array-return-source) : String
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
(define (make-ref-tuple [n : i64]) : (Tuple (& n i64) i64)
  (tuple (& n) 7))
(define (make-ref-array [n : i64]) : (Array (& n i64) 1)
  (array (& n)))
(define (main [n : i64]) : i64
  (let
    [pair : (Tuple (& n i64) i64) (tuple (& n) 7)]
    [items : (Array (& n i64) 1) (array (& n))]
    (begin
      (ref-id (ref-return n))
      (make-ref-tuple n)
      (make-ref-array n)
      (tuple-ref pair 1)
      (array-ref items 0)
      42)))")

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

(define (compiler-lower-reference-struct-result-source) : String
  "(defstruct RefBox
  (:lifetimes text)
  (borrowed (& text str))
  (owned String)
  (is-owned bool))
(define (ref-box-borrowed [text : (& text str)] [owned : String]) : (RefBox text)
  (RefBox text owned false))
(define (ref-box-owned [text : (& text str)] [owned : String]) : (RefBox text)
  (RefBox text owned true))
(define (ref-box-length [item : (RefBox text)]) : i64
  (if (struct-get item is-owned)
    (string-length (struct-get item owned))
    (string-length (struct-get item borrowed))))
(define (main [text : String] [owned : String]) : i64
  (let
    [borrowed : (RefBox text) (ref-box-borrowed (& text) owned)]
    [owned-box : (RefBox text) (ref-box-owned (& text) owned)]
    (+ (ref-box-length borrowed) (ref-box-length owned-box))))")

(define (compiler-lower-reference-struct-multi-result-source) : String
  "(defstruct ReplaceResult
  (:lifetimes text old replacement)
  (borrowed (& text str))
  (old-text (& old str))
  (replacement-text (& replacement str))
  (owned String)
  (is-owned bool))
(define (replace-borrowed
  [text : (& text str)]
  [old : (& old str)]
  [replacement : (& replacement str)]
  [owned : String]) : (ReplaceResult text old replacement)
  (ReplaceResult text old replacement owned false))
(define (replace-owned
  [text : (& text str)]
  [old : (& old str)]
  [replacement : (& replacement str)]
  [owned : String]) : (ReplaceResult text old replacement)
  (ReplaceResult text old replacement owned true))
(define (replace-score [item : (ReplaceResult text old replacement)]) : i64
  (+
    (string-length (struct-get item old-text))
    (+
      (string-length (struct-get item replacement-text))
      (if (struct-get item is-owned)
        (string-length (struct-get item owned))
        (string-length (struct-get item borrowed))))))
(define (main [text : String] [old : String] [replacement : String] [owned : String]) : i64
  (let
    [borrowed : (ReplaceResult text old replacement)
      (replace-borrowed (& text) (& old) (& replacement) owned)]
    [owned-result : (ReplaceResult text old replacement)
      (replace-owned (& text) (& old) (& replacement) owned)]
    (+ (replace-score borrowed) (replace-score owned-result))))")

(define (compiler-lower-reference-enum-result-source) : String
  "(defenum RefChoice
  (:lifetimes text)
  (RefChoiceBorrowed (& text str))
  (RefChoiceOwned String))
(define (borrowed-choice [text : (& text str)]) : (RefChoice text)
  (RefChoiceBorrowed text))
(define (owned-choice [text : (& text str)] [owned : String]) : (RefChoice text)
  (RefChoiceOwned owned))
(define (choice-length [choice : (RefChoice text)]) : i64
  (match choice
    [(RefChoiceBorrowed value) (string-length value)]
    [(RefChoiceOwned value) (string-length value)]))
(define (choice-loop [choice : (RefChoice text)] [count : i64]) : i64
  (match choice
    [(RefChoiceBorrowed value)
      (if (> count 0)
        (choice-loop (RefChoiceBorrowed value) (- count 1))
        (string-length value))]
    [(RefChoiceOwned value) (string-length value)]))
(define (main [text : String] [owned : String]) : i64
  (+
    (choice-length (borrowed-choice (& text)))
    (choice-loop (owned-choice (& text) owned) 1)))")

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
  "(extern (print-i64 [arg0 : i64]) : unit)
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

(define (compiler-lower-capturing-lambda-reference-source) : String
  "(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let [f : (-> i64) (lambda () : i64 (let [copy : (& n i64) r] 42))]
      (f))))")

(define (compiler-lower-capturing-lambda-reference-immediate-source) : String
  "(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    ((lambda () : i64 (let [copy : (& n i64) r] 42)))))")

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

(define (compiler-lower-duplicate-function-source) : String
  "(define (dup) : i64 1)
(define (dup) : i64 2)
(define (main) : i64 (dup))")

(define (compiler-lower-defdispatch-source) : String
  "(define (dot-scalar [x : i64]) : i64 x)
(define (dot-avx2 [x : i64]) : i64 (+ x 2))
(define (dot-avx512 [x : i64]) : i64 (+ x 5))
(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2) (avx512 dot-avx512))
(define (main [x : i64]) : i64 (dot x))")

(define (compiler-lower-defdispatch-shared-helper-source) : String
  "(define (dispatch-helper [x : i64]) : i64 (+ x 1))
(define (dot-scalar [x : i64]) : i64 (dispatch-helper x))
(define (dot-avx2 [x : i64]) : i64 (+ (dispatch-helper x) 2))
(define (dot-avx512 [x : i64]) : i64 (+ (dispatch-helper x) 5))
(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2) (avx512 dot-avx512))
(define (main [x : i64]) : i64 (dot x))")

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

(define (compiler-lower-linux-error-ok? [src : String] [want : String]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerLinuxScalar))
    [(ErrCompilerLower diag)
      (string-eq (compiler-diagnostic-message diag) want)]
    [(OkCompilerLower _ _) false]))

(define (compiler-lower-windows-error-ok? [src : String] [want : String]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerWindowsScalar))
    [(ErrCompilerLower diag)
      (string-eq (compiler-diagnostic-message diag) want)]
    [(OkCompilerLower _ _) false]))

;; Scalar match lowering smoke (#568): an i64 literal match with a binding
;; catch-all (value-returning), an exhaustive bool match, and a unit-typed match.
(define (compiler-lower-match-source) : String
  "(extern (print-i64 [arg0 : i64]) : unit)
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

(define (compiler-lower-mut-ref-array-access-source) : String
  "(define (get [a : (& a (Array i64))] [i : i64]) : i64 (array-ref a i))
(define (put [a : (&mut a (Array i64))] [i : i64] [v : i64]) : unit
  (array-set! a i v))
(define (grow [a : (&mut a (Array i64))] [v : i64]) : unit
  (array-push! a v))
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
;; initialized elements, and a dynamic-array fat value. The fixture also
;; immediately uses `array-set!`, `array-ref`, and `array-length` so the
;; generated IR exercises the full dynamic-array primitive set.
(define (compiler-lower-make-array-source) : String
  "(define (main [n : i64]) : i64
  (let
    [a : (Array i64) (make-array i64 n)]
    (begin
      (array-set! a 0 40)
      (array-set! a 1 2)
      (+ (array-length a) (+ (array-ref a 0) (array-ref a 1))))))")

(define (compiler-lower-make-array-init-source) : String
  "(define (main [n : i64]) : i64
  (let
    [items : (Array String) (make-array String n)]
    (array-length items)))")

;; `string-length`/`length` on a String lower to the same fat `{ptr, len}`
;; length load as `array-length` (#527): both lay out the i64 length at offset 8.
(define (compiler-lower-string-length-source) : String
  "(define (str-len [s : String]) : i64 (string-length s))
(define (str-len-alias [s : String]) : i64 (length s))
(define (str-len-borrow [s : String]) : i64 (string-length (& s)))
(define (str-len-alias-borrow [s : String]) : i64 (length (& s)))
(define (main) : i64 0)")

(define (compiler-lower-string-runtime-source) : String
  "(define (print-string [text : String]) : unit
  unit)
(define (print-str [text : String]) : unit
  (print-string text))
(define (string-append [left : (& left str)] [right : (& right str)]) : String
  \"joined\")
(define (substring [text : (& text str)] [start : i64] [len : i64]) : String
  (let
    [probe : char (string-ref text start)]
    \"slice\"))
(define (string-concat [left : (& left str)] [right : (& right str)]) : String
  (string-append left right))
(define (main) : i64
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
      (print-string joined)
      (print-str extended)
      (+ (string-length (& joined))
        (+ (string-length (& extended))
          (+ (string->int (& digits))
            (+ (if (string-eq (& joined) (& extended)) 1 0)
              (cast (char-at (& spaced) 0) : i64))))))))")

(define (compiler-lower-string-concat-fusion-source) : String
  "(define (string-append [left : String] [right : String]) : String
  left)
(define (main) : i64
  (let
    [three : String (string-append \"a\" (string-append \"b\" \"c\"))]
    [four : String
      (string-append \"a\" (string-append \"b\" (string-append \"c\" \"d\")))]
    [five : String
      (string-append
        \"a\"
        (string-append \"b\" (string-append \"c\" (string-append \"d\" \"e\"))))]
    (+ (string-length three) (+ (string-length four) (string-length five)))))")

(define (compiler-lower-print-string-stdlib-source) : String
  "(define (print-string [text : String]) : unit
  unit)
(define (print-str [text : String]) : unit
  (print-string text))
(define (main [text : String]) : i64
  (begin
    (print-string text)
    (print-str text)
    0))")

(define (compiler-lower-borrowed-str-param-source) : String
  "(define (borrowed-score [path : (& path str)]) : i64
  (string-length path))
(define (main [path : String]) : i64
  (borrowed-score (& path)))")

(define (compiler-lower-stdlib-hash-string-source) : String
  "(define (hash-string [key : (& key str)]) : i64
  (let
    [n : i64 (string-length key)]
    [i : i64 0]
    [hash : i64 0]
    (begin
      (while (< i n)
        (let
          [next : i64
            (+ (+ (* hash 131) (cast (string-ref key i) : i64)) 1)]
          [reduced : i64
            (+ (bit-and next 0x7fffffff) (shr next 31))]
          (begin
            (set!
              hash
              (if (>= reduced 0x7fffffff)
                (- reduced 0x7fffffff)
                reduced))
            (set! i (+ i 1)))))
      hash)))
(define (main [key : String]) : i64
  (+ (hash-string (& key)) 0))")

(define (compiler-lower-stdlib-hash-string-paths) : AstDeclPathList
  (ast-decl-path-cons
    "stdlib/hash.tl"
    (ast-decl-path-cons "app.tl" AstDeclPathNil)))

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
  "(define stdin-eof-state : bool false)
(define (read-stdin-bytes [count : i64]) : String
  (let
    [buf : (Array u8) (make-array u8 count)]
    (unsafe (string-from-bytes (ptr-cast (array-data buf) : (Ptr u8)) count))))
(define (read-stdin-line) : String
  (let
    [buf : (Array u8) (make-array u8 0)]
    (unsafe (string-from-bytes (ptr-cast (array-data buf) : (Ptr u8)) 0))))
(define (stdin-eof?) : bool stdin-eof-state)
(define (flush-stdout) : unit unit)
(define (main) : i64
  (begin
    (flush-stdout)
    (if (stdin-eof?)
        (string-length (read-stdin-line))
        (string-length (read-stdin-bytes 3)))))")

(define (compiler-lower-stdio-builtin-source) : String
  "(define stdin-eof-state : bool false)
(define (read-stdin-bytes [count : i64]) : String
  (let
    [buf : (Array u8) (make-array u8 count)]
    (unsafe (string-from-bytes (ptr-cast (array-data buf) : (Ptr u8)) count))))
(define (read-stdin-line) : String
  (let
    [buf : (Array u8) (make-array u8 0)]
    (unsafe (string-from-bytes (ptr-cast (array-data buf) : (Ptr u8)) 0))))
(define (stdin-eof?) : bool stdin-eof-state)
(define (flush-stdout) : unit unit)
(define (main [count : i64]) : i64
  (begin
    (flush-stdout)
    (if (stdin-eof?)
        (string-length (read-stdin-line))
        (string-length (read-stdin-bytes count)))))")

(define (compiler-lower-env-builtin-source) : String
  "(define (env-var-exists? [name : String]) : bool true)
(define (env-var-value [name : String]) : String name)
(define (env-path-separator) : String \":\")
(define (main [name : String]) : i64
  (let
    [separator : String (env-path-separator)]
    [value : String (env-var-value name)]
    (if (env-var-exists? name)
      (+ (string-length value) (string-length separator))
      (string-length separator))))")

(define (compiler-lower-cpu-builtin-source) : String
  "(define (main) : i64
  (let
    [r : (Tuple i32 i32 i32 i32) (cpuid 0 0)]
    (+ (cast (tuple-ref r 0) : i64) (xgetbv 0))))")

(define (compiler-lower-file-handle-status-source) : String
  "(extern (os-open [arg0 : (Ptr u8)] [arg1 : i32] [arg2 : i32]) : i32 (:symbol \"open\"))
(extern (os-close [arg0 : i32]) : i32 (:symbol \"close\"))
(extern (os-read [arg0 : i32] [arg1 : (MutPtr u8)] [arg2 : i64]) : i64 (:symbol \"read\"))
(extern (os-write [arg0 : i32] [arg1 : (Ptr u8)] [arg2 : i64]) : i64 (:symbol \"write\"))
(extern (os-fflush [arg0 : (Ptr u8)]) : i32 (:symbol \"fflush\"))
(define (file-open-status [path : String] [mode : i64]) : i64
  (cast
    (os-open (unsafe (string-data path)) (cast mode : i32) (cast 384 : i32))
    : i64))
(define (file-close-status [handle : i64]) : i64
  (cast (os-close (cast handle : i32)) : i64))
(define (file-read-chunk-status [handle : i64] [count : i64]) : i64
  (let
    [buf : (Array u8) (make-array u8 count)]
    (os-read (cast handle : i32) (unsafe (array-data buf)) count)))
(define (file-write-status [handle : i64] [text : String]) : i64
  (os-write
    (cast handle : i32)
    (unsafe (string-data text))
    (string-length text)))
(define (file-flush-status [handle : i64]) : i64
  (cast (os-fflush (ptr-null : (Ptr u8))) : i64))
(define (file-read-chunk-bytes [handle : i64]) : String
  (let
    [buf : (Array u8) (make-array u8 0)]
    (unsafe (string-from-bytes (ptr-cast (array-data buf) : (Ptr u8)) 0))))
(define (file-read-chunk-eof? [handle : i64]) : bool false)
(define (append-file-status [path : String] [text : String]) : i64
  (let
    [handle : i64 (file-open-status path 2)]
    (+ (file-write-status handle text) (file-close-status handle))))
(define (main) : i64
  (let
    [path : String \"input.txt\"]
    [suffix : String \"x\"]
    [chunk : String \"chunk\"]
    [handle : i64 (file-open-status path 0)]
    (+ handle
      (+ (append-file-status path suffix)
        (+ (file-read-chunk-status handle 4)
          (+ (file-write-status handle chunk)
            (+ (file-flush-status handle)
              (+ (string-length (file-read-chunk-bytes handle))
                (+ (if (file-read-chunk-eof? handle) 1 0)
                   (file-close-status handle))))))))))")

(define (compiler-lower-fs-status-source) : String
  "(define (fs-current-dir-status) : i64 0)
(define (fs-current-dir) : String \".\")
(define (fs-process-id) : i64 1)
(define (fs-mkdir-status [path : String]) : i64 0)
(define (fs-remove-file-status [path : String]) : i64 0)
(define (fs-remove-dir-status [path : String]) : i64 0)
(define (fs-rename-status [source : String] [destination : String]) : i64 0)
(define (fs-read-dir-status [path : String]) : i64 0)
(define (fs-read-dir [path : String]) : String path)
(define (fs-file-kind-status [path : String]) : i64 0)
(define (fs-file-size-status [path : String]) : i64 0)
(define (fs-file-size [path : String]) : i64 (string-length path))
(define (main) : i64
  (+ (fs-current-dir-status)
    (+ (string-length (fs-current-dir))
      (+ (fs-process-id)
        (+ (fs-mkdir-status \"target/typelisp-fs\")
          (+ (fs-remove-file-status \"target/typelisp-fs/artifact.o\")
            (+ (fs-remove-dir-status \"target/typelisp-fs\")
              (+ (fs-rename-status
                  \"target/typelisp-fs/from name\"
                  \"target/typelisp-fs/to name\")
                (+ (fs-read-dir-status \"target/typelisp-fs\")
                  (+ (string-length (fs-read-dir \"target/typelisp-fs\"))
                    (+ (fs-file-kind-status \"target/typelisp-fs\")
                      (+ (fs-file-size-status \"target/typelisp-fs\")
                        (fs-file-size \"target/typelisp-fs\")))))))))))))")

(define (compiler-lower-raw-pointer-ops-source) : String
  "(extern (raw-make) : (MutPtr i64))
(define (main [n : u64]) : u64
  (let
    [cell : i64 0]
    [local : (MutPtr i64) (unsafe (ptr-addr-of cell))]
    [p : (MutPtr i64) (raw-make)]
    (unsafe
      (ptr-write! local 42)
      (ptr-read local)
      (ptr-write! p 41)
      (ptr-read p)
      (ptr->int (ptr-offset (ptr-cast (int->ptr n : (MutPtr i64)) : (Ptr i64)) 2)))))")

(define (compiler-lower-raw-pointer-direct-call-source) : String
  "(extern (raw-make) : (MutPtr i64))
(define (main) : unit
  (unsafe
    (ptr-write! (raw-make) 41)))")

(define (compiler-lower-raw-pointer-call-value-source) : String
  "(extern (raw-make) : (MutPtr i64))
(extern (raw-value) : i64)
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

(define (compiler-lower-init-source) : String
  "(defstruct Point (x i64) (flag bool))
(defenum Maybe (None) (Some i64))
(define (main) : i64
  (let
    [n : i64 (init : i64)]
    [flag : bool (init : bool)]
    [ch : char (init : char)]
    [text : String (init : String)]
    [ptr : (Ptr i64) (init : (Ptr i64))]
    [items : (Array i64) (init : (Array i64))]
    [tupled : (Tuple i64 bool) (init : (Tuple i64 bool))]
    [fixed : (Array i64 2) (init : (Array i64 2))]
    [point : Point (init : Point)]
    [maybe : Maybe (init : Maybe)]
    [boxed : (Box i64) (init : (Box i64))]
    (+ n (+ (struct-get point x) (+ (tuple-ref tupled 0) (+ (array-ref fixed 0) (box-get boxed)))))))")

;; Tuple construction + ref lowering (#1583): `(tuple true 42)` reserves
;; struct-shaped aggregate storage and stores each element at its field offset;
;; `(tuple-ref t 1)` gep+loads the indexed element. The whole computation lives
;; in `main` so it is not pruned as unreachable.
(define (compiler-lower-tuple-source) : String
  "(define (main) : i64
  (let
    [t : (Tuple bool i64) (tuple true 42)]
    (tuple-ref t 1)))")

(define (compiler-lower-tuple-return-source) : String
  "(define (make-pair [a : i64] [b : bool]) : (Tuple i64 bool)
  (tuple a b))")

(define (compiler-lower-clone-source) : String
  "(defstruct Holder
  (name String)
  (fixed (Array String 2))
  (items (Array String))
  (pair (Tuple String String)))
(defenum StringList
  (SNil)
  (SCons String (Box StringList)))
(define (clone-tuple [items : (Array String)]) : i64
  (let [pair : (Tuple String (Array String)) (clone (tuple \"tuple\" items))]
    (string-length (tuple-ref pair 0))))
(define (clone-fixed) : i64
  (let [fixed : (Array String 2) (clone (array \"left\" \"right\"))]
    (string-length (array-ref fixed 0))))
(define (clone-dyn [items : (Array String)]) : i64
  (let [copied : (Array String) (clone items)]
    (array-length copied)))
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

(define (compiler-lower-clone-reachable-source) : String
  "(defstruct UsedClone
  (name String))
(defstruct NestedClone
  (used UsedClone))
(defstruct UnusedClone
  (name String))
(define (make-nested [s : String]) : NestedClone
  (clone (NestedClone (UsedClone s))))
(define (main [s : String]) : i64
  (let
    [item : NestedClone (make-nested s)]
    (string-length (struct-get (struct-get item used) name))))")

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

(define (compiler-lower-clone-shape-ok?) : bool
  (match (parse-ast-source (compiler-lower-clone-source))
    [(OkAstProgram ast)
      (match (lower-compiler-program-with-decl-paths
        "<source>"
        ast
        AstDeclPathNil)
        [(OkCompilerLower program _)
          (match program
            [(IrProgram _ functions _)
              (let
                [ok : bool true]
                (begin
                  (if (>
                    (lower-test-function-call-count
                      functions
                      "<source>::clone-tuple"
                      "tl_substring")
                    0)
                    unit
                    (set! ok false))
                  (if (>
                    (lower-test-function-call-count
                      functions
                      "<source>::clone-tuple"
                      "tl_alloc")
                    0)
                    unit
                    (set! ok false))
                  (if (>
                    (lower-test-function-call-count
                      functions
                      "<source>::clone-fixed"
                      "tl_substring")
                    1)
                    unit
                    (set! ok false))
                  (if (>
                    (lower-test-function-call-count
                      functions
                      "<source>::clone-dyn"
                      "tl_alloc")
                    1)
                    unit
                    (set! ok false))
                  (if (>
                    (lower-test-function-branch-count
                      functions
                      "<source>::clone-dyn")
                    0)
                    unit
                    (set! ok false))
                  (if (=
                    (lower-test-function-call-count
                      functions
                      "<source>::clone-holder"
                      "<source>::clone$Holder")
                    1)
                    unit
                    (set! ok false))
                  (if (=
                    (lower-test-function-call-count
                      functions
                      "<source>::clone-list"
                      "<source>::clone$StringList")
                    1)
                    unit
                    (set! ok false))
                  (if (>
                    (lower-test-function-call-count
                      functions
                      "<source>::clone$Holder"
                      "tl_substring")
                    0)
                    unit
                    (set! ok false))
                  (if (>
                    (lower-test-function-call-count
                      functions
                      "<source>::clone$Holder"
                      "tl_alloc")
                    0)
                    unit
                    (set! ok false))
                  (if (>
                    (lower-test-function-call-count
                      functions
                      "<source>::clone$StringList$acc"
                      "tl_substring")
                    0)
                    unit
                    (set! ok false))
                  ok))])]
        [(ErrCompilerLower _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-lower-clone-reachable-helpers-ok?) : bool
  (match (parse-ast-source (compiler-lower-clone-reachable-source))
    [(OkAstProgram ast)
      (match (lower-compiler-program-with-decl-paths
        "<source>"
        ast
        AstDeclPathNil)
        [(OkCompilerLower program _)
          (match program
            [(IrProgram _ functions _)
              (and
                (lower-test-function-defined?
                  functions
                  "<source>::clone$NestedClone")
                (and
                  (lower-test-function-defined?
                    functions
                    "<source>::clone$UsedClone")
                  (and
                    (not
                      (lower-test-function-defined?
                        functions
                        "<source>::clone$UnusedClone"))
                    (=
                      (lower-test-function-call-count
                        functions
                        "<source>::clone$NestedClone"
                        "<source>::clone$UsedClone")
                      1))))])]
        [(ErrCompilerLower _) false])]
    [(ErrAstProgram _) false]))

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
  "(comptime-decl (:generated point-family Point \"i64-i64\")
  (defstruct Point (x i64) (y i64)))
(comptime-decl (:generated shape-family Shape \"point\")
  (defenum Shape (Nothing) (Circle i64) (Pair Point)))
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

(define (compiler-lower-option-try-source) : String
  "(defenum MaybeI64 (SomeI64 i64) (NoneI64))
(define (read [flag : bool] [n : i64]) : MaybeI64
  (if flag (SomeI64 n) NoneI64))
(define (main [a : bool] [b : bool]) : MaybeI64
  (let ([x : i64 (try (read a 40))])
    (SomeI64 (+ x (try (read b 2))))))")

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

(define (compiler-lower-cleanup-struct-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (close-fd [fd : i64]) : unit unit)
(define (use-fd [ok : bool] [fd : i64]) : ResultI64
  (if ok (OkI64 fd) (ErrI64 \"use fd\")))
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (main [use-ok : bool]) : ResultI64
  (with ([h (FileHandle 10) cleanup-file-handle])
    (OkI64 (try (use-fd use-ok (struct-get h fd))))))")

(define (compiler-lower-cleanup-struct-nested-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(define (close-buffer [buffer : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct BufferedFile
  (:cleanup cleanup-buffered-file)
  (handle FileHandle (:owned))
  (buffer i64 (:cleanup close-buffer)))
(define (main) : i64
  (with ([b (BufferedFile (FileHandle 10) 20) cleanup-buffered-file])
    42))")

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
          (if (= (compiler-ir-summary-instructions summary) 22)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-vars summary) 14)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-empty-blocks summary) 0)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-max-instructions-function summary) 19)
            unit
            (set! ok false))
          (if (= (compiler-ir-summary-max-instructions-block summary) 6)
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

(define (lower-test-instr-cpuid-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrCpuId _ _ _ _) 1]
    [_ 0]))

(define (lower-test-instr-xgetbv-count [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrXgetbv _ _) 1]
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
        (lower-test-value-list-function-count (box-get rest) name))]))

(define (lower-test-call-args-function-count
  [args : CompilerIrCallArgs]
  [name : String]) : i64
  (match args
    [(IrCallArgsNil) 0]
    [(IrCallArgsOne value) (lower-test-value-function-count value name)]
    [(IrCallArgsTwo a b)
      (+
        (lower-test-value-function-count a name)
        (lower-test-value-function-count b name))]
    [(IrCallArgsArray values)
      (lower-test-call-args-array-function-count values name 0)]))

(define (lower-test-call-args-array-function-count
  [values : (Array CompilerIrValue)]
  [name : String]
  [index : i64]) : i64
  (if (>= index (array-length values))
    0
    (+
      (lower-test-value-function-count (array-ref values index) name)
      (lower-test-call-args-array-function-count values name (+ index 1)))))

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
        (lower-test-call-args-function-count args function-name)
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
      (+
        (lower-test-instr-phi-count instr)
        (lower-test-instrs-phi-count (box-get rest)))]))

(define (lower-test-instrs-load-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-load-count instr)
        (lower-test-instrs-load-count (box-get rest)))]))

(define (lower-test-instrs-branch-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-branch-count instr)
        (lower-test-instrs-branch-count (box-get rest)))]))

(define (lower-test-instrs-bounds-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-bounds-count instr)
        (lower-test-instrs-bounds-count (box-get rest)))]))

(define (lower-test-instrs-return-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-return-count instr)
        (lower-test-instrs-return-count (box-get rest)))]))

(define (lower-test-instrs-call-count
  [instrs : CompilerIrInstrList]
  [name : String]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-call-count instr name)
        (lower-test-instrs-call-count (box-get rest) name))]))

(define (lower-test-instr-call-name? [instr : CompilerIrInstr] [name : String]) : bool
  (match instr
    [(IrInstrCall _ call-name _ _) (string-eq call-name name)]
    [(IrInstrTailCall call-name _ _) (string-eq call-name name)]
    [_ false]))

(define (lower-test-instrs-call-before?
  [instrs : CompilerIrInstrList]
  [first : String]
  [second : String]
  [seen-first : bool]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr rest)
      (if (lower-test-instr-call-name? instr second)
        seen-first
        (lower-test-instrs-call-before?
          (box-get rest)
          first
          second
          (if (lower-test-instr-call-name? instr first)
            true
            seen-first)))]))

(define (lower-test-instrs-cpuid-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-cpuid-count instr)
        (lower-test-instrs-cpuid-count (box-get rest)))]))

(define (lower-test-instrs-xgetbv-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-xgetbv-count instr)
        (lower-test-instrs-xgetbv-count (box-get rest)))]))

(define (lower-test-instrs-indirect-call-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-indirect-call-count instr)
        (lower-test-instrs-indirect-call-count (box-get rest)))]))

(define (lower-test-instrs-indirect-unit-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-indirect-unit-count instr)
        (lower-test-instrs-indirect-unit-count (box-get rest)))]))

(define (lower-test-instrs-return-function-count
  [instrs : CompilerIrInstrList]
  [function-name : String]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-return-function-count instr function-name)
        (lower-test-instrs-return-function-count (box-get rest) function-name))]))

(define (lower-test-instrs-indirect-callee-function-count
  [instrs : CompilerIrInstrList]
  [function-name : String]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-indirect-callee-function-count instr function-name)
        (lower-test-instrs-indirect-callee-function-count
          (box-get rest)
          function-name))]))

(define (lower-test-instrs-call-arg-function-count
  [instrs : CompilerIrInstrList]
  [call-name : String]
  [function-name : String]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-call-arg-function-count instr call-name function-name)
        (lower-test-instrs-call-arg-function-count
          (box-get rest)
          call-name
          function-name))]))

(define (lower-test-instrs-tail-call-count
  [instrs : CompilerIrInstrList]
  [name : String]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-tail-call-count instr name)
        (lower-test-instrs-tail-call-count (box-get rest) name))]))

(define (lower-test-instrs-store-ptr-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-store-ptr-count instr)
        (lower-test-instrs-store-ptr-count (box-get rest)))]))

(define (lower-test-instrs-alloc-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-alloc-count instr)
        (lower-test-instrs-alloc-count (box-get rest)))]))

(define (lower-test-instrs-addr-of-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-addr-of-count instr)
        (lower-test-instrs-addr-of-count (box-get rest)))]))

(define (lower-test-instrs-vector-load-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-vector-load-count instr)
        (lower-test-instrs-vector-load-count (box-get rest)))]))

(define (lower-test-instrs-vector-binop-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-vector-binop-count instr)
        (lower-test-instrs-vector-binop-count (box-get rest)))]))

(define (lower-test-instrs-vector-reduce-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-vector-reduce-count instr)
        (lower-test-instrs-vector-reduce-count (box-get rest)))]))

(define (lower-test-instrs-vector-store-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-vector-store-count instr)
        (lower-test-instrs-vector-store-count (box-get rest)))]))

(define (lower-test-instrs-predicated-load-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-predicated-load-count instr)
        (lower-test-instrs-predicated-load-count (box-get rest)))]))

(define (lower-test-instrs-predicated-store-count
  [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-predicated-store-count instr)
        (lower-test-instrs-predicated-store-count (box-get rest)))]))

(define (lower-test-instrs-tail-mask-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-tail-mask-count instr)
        (lower-test-instrs-tail-mask-count (box-get rest)))]))

(define (lower-test-instrs-vector-shape-count
  [instrs : CompilerIrInstrList]
  [lanes : i64]
  [elem-ty : AstType]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-vector-shape-count instr lanes elem-ty)
        (lower-test-instrs-vector-shape-count (box-get rest) lanes elem-ty))]))

(define (lower-test-instrs-u64-mov-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-u64-mov-count instr)
        (lower-test-instrs-u64-mov-count (box-get rest)))]))

(define (lower-test-instrs-binop-op-count
  [instrs : CompilerIrInstrList]
  [op : CompilerIrBinOp]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-binop-op-count instr op)
        (lower-test-instrs-binop-op-count (box-get rest) op))]))

(define (lower-test-instrs-cast-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-cast-count instr)
        (lower-test-instrs-cast-count (box-get rest)))]))

(define (lower-test-instrs-store-global-count
  [instrs : CompilerIrInstrList]
  [name : String]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-store-global-count instr name)
        (lower-test-instrs-store-global-count (box-get rest) name))]))

(define (lower-test-instr-seq-phi-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-phi-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-load-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-load-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-branch-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-branch-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-bounds-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-bounds-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-return-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-return-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-call-count
  [instrs : CompilerIrInstrSeq]
  [name : String]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-call-count (array-ref slots index) name)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-call-before?
  [instrs : CompilerIrInstrSeq]
  [first : String]
  [second : String]) : bool
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [seen-first : bool false]
    [done : bool false]
    [result : bool false]
    (begin
      (while (and (< index count) (not done))
        (let
          [instr : CompilerIrInstr (array-ref slots index)]
          (begin
            (if (lower-test-instr-call-name? instr second)
              (begin
                (set! result seen-first)
                (set! done true))
              (if (lower-test-instr-call-name? instr first)
                (set! seen-first true)
                unit))
            (set! index (+ index 1)))))
      result)))

(define (lower-test-instr-seq-cpuid-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-cpuid-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-xgetbv-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-xgetbv-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-indirect-call-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-indirect-call-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-indirect-unit-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-indirect-unit-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-return-function-count
  [instrs : CompilerIrInstrSeq]
  [function-name : String]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-return-function-count
                (array-ref slots index)
                function-name)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-indirect-callee-function-count
  [instrs : CompilerIrInstrSeq]
  [function-name : String]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-indirect-callee-function-count
                (array-ref slots index)
                function-name)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-call-arg-function-count
  [instrs : CompilerIrInstrSeq]
  [call-name : String]
  [function-name : String]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-call-arg-function-count
                (array-ref slots index)
                call-name
                function-name)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-tail-call-count
  [instrs : CompilerIrInstrSeq]
  [name : String]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-tail-call-count (array-ref slots index) name)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-store-ptr-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-store-ptr-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-alloc-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-alloc-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-addr-of-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-addr-of-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-load-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-vector-load-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-binop-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-vector-binop-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-reduce-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-vector-reduce-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-store-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-vector-store-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-predicated-load-count
  [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-predicated-load-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-predicated-store-count
  [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-predicated-store-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-tail-mask-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-tail-mask-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-vector-shape-count
  [instrs : CompilerIrInstrSeq]
  [lanes : i64]
  [elem-ty : AstType]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-vector-shape-count
                (array-ref slots index)
                lanes
                elem-ty)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-u64-mov-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-u64-mov-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-binop-op-count
  [instrs : CompilerIrInstrSeq]
  [op : CompilerIrBinOp]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-binop-op-count (array-ref slots index) op)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-cast-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-cast-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-store-global-count
  [instrs : CompilerIrInstrSeq]
  [name : String]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-store-global-count (array-ref slots index) name)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-blocks-phi-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-phi-count instrs)
            (lower-test-blocks-phi-count (box-get rest)))])]))

(define (lower-test-blocks-load-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-load-count instrs)
            (lower-test-blocks-load-count (box-get rest)))])]))

(define (lower-test-blocks-branch-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-branch-count instrs)
            (lower-test-blocks-branch-count (box-get rest)))])]))

(define (lower-test-blocks-bounds-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-bounds-count instrs)
            (lower-test-blocks-bounds-count (box-get rest)))])]))

(define (lower-test-blocks-return-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-return-count instrs)
            (lower-test-blocks-return-count (box-get rest)))])]))

(define (lower-test-blocks-call-count
  [blocks : CompilerIrBlockList]
  [name : String]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-call-count instrs name)
            (lower-test-blocks-call-count (box-get rest) name))])]))

(define (lower-test-blocks-call-before?
  [blocks : CompilerIrBlockList]
  [first : String]
  [second : String]) : bool
  (match blocks
    [(IrBlockNil) false]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (if (lower-test-instr-seq-call-before? instrs first second)
            true
            (lower-test-blocks-call-before? (box-get rest) first second))])]))

(define (lower-test-blocks-cpuid-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-cpuid-count instrs)
            (lower-test-blocks-cpuid-count (box-get rest)))])]))

(define (lower-test-blocks-xgetbv-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-xgetbv-count instrs)
            (lower-test-blocks-xgetbv-count (box-get rest)))])]))

(define (lower-test-blocks-indirect-call-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-indirect-call-count instrs)
            (lower-test-blocks-indirect-call-count (box-get rest)))])]))

(define (lower-test-blocks-indirect-unit-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-indirect-unit-count instrs)
            (lower-test-blocks-indirect-unit-count (box-get rest)))])]))

(define (lower-test-blocks-return-function-count
  [blocks : CompilerIrBlockList]
  [function-name : String]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-return-function-count instrs function-name)
            (lower-test-blocks-return-function-count
              (box-get rest)
              function-name))])]))

(define (lower-test-blocks-indirect-callee-function-count
  [blocks : CompilerIrBlockList]
  [function-name : String]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-indirect-callee-function-count
              instrs
              function-name)
            (lower-test-blocks-indirect-callee-function-count
              (box-get rest)
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
            (lower-test-instr-seq-call-arg-function-count
              instrs
              call-name
              function-name)
            (lower-test-blocks-call-arg-function-count
              (box-get rest)
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
            (lower-test-instr-seq-tail-call-count instrs name)
            (lower-test-blocks-tail-call-count (box-get rest) name))])]))

(define (lower-test-blocks-store-ptr-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-store-ptr-count instrs)
            (lower-test-blocks-store-ptr-count (box-get rest)))])]))

(define (lower-test-blocks-alloc-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-alloc-count instrs)
            (lower-test-blocks-alloc-count (box-get rest)))])]))

(define (lower-test-blocks-addr-of-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-addr-of-count instrs)
            (lower-test-blocks-addr-of-count (box-get rest)))])]))

(define (lower-test-blocks-vector-load-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-vector-load-count instrs)
            (lower-test-blocks-vector-load-count (box-get rest)))])]))

(define (lower-test-blocks-vector-binop-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-vector-binop-count instrs)
            (lower-test-blocks-vector-binop-count (box-get rest)))])]))

(define (lower-test-blocks-vector-reduce-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-vector-reduce-count instrs)
            (lower-test-blocks-vector-reduce-count (box-get rest)))])]))

(define (lower-test-blocks-vector-store-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-vector-store-count instrs)
            (lower-test-blocks-vector-store-count (box-get rest)))])]))

(define (lower-test-blocks-predicated-load-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-predicated-load-count instrs)
            (lower-test-blocks-predicated-load-count (box-get rest)))])]))

(define (lower-test-blocks-predicated-store-count
  [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-predicated-store-count instrs)
            (lower-test-blocks-predicated-store-count (box-get rest)))])]))

(define (lower-test-blocks-tail-mask-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-tail-mask-count instrs)
            (lower-test-blocks-tail-mask-count (box-get rest)))])]))

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
            (lower-test-instr-seq-vector-shape-count instrs lanes elem-ty)
            (lower-test-blocks-vector-shape-count (box-get rest) lanes elem-ty))])]))

(define (lower-test-blocks-u64-mov-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-u64-mov-count instrs)
            (lower-test-blocks-u64-mov-count (box-get rest)))])]))

(define (lower-test-blocks-binop-op-count
  [blocks : CompilerIrBlockList]
  [op : CompilerIrBinOp]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-binop-op-count instrs op)
            (lower-test-blocks-binop-op-count (box-get rest) op))])]))

(define (lower-test-blocks-cast-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-cast-count instrs)
            (lower-test-blocks-cast-count (box-get rest)))])]))

(define (lower-test-blocks-store-global-count
  [blocks : CompilerIrBlockList]
  [name : String]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-store-global-count instrs name)
            (lower-test-blocks-store-global-count (box-get rest) name))])]))

;; Phi count of the function named `name`, or -1 when no such function exists
;; (so a missing function fails both the `> 0` and `= 0` assertions below).
(define (lower-test-function-defined?
  [funcs : CompilerIrFunctionList]
  [name : String]) : bool
  (match funcs
    [(IrFunctionNil) false]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ _)
          (if (string-eq fname name)
            true
            (lower-test-function-defined? (box-get rest) name))])]))

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
            (lower-test-function-phi-count (box-get rest) name))])]))

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
            (lower-test-function-load-count (box-get rest) name))])]))

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
            (lower-test-function-branch-count (box-get rest) name))])]))

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
            (lower-test-function-bounds-count (box-get rest) name))])]))

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
            (lower-test-function-return-count (box-get rest) name))])]))

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
            (lower-test-functions-call-count (box-get rest) name))])]))

(define (lower-test-functions-tail-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (match funcs
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (+
            (lower-test-blocks-tail-call-count blocks name)
            (lower-test-functions-tail-call-count (box-get rest) name))])]))

(define (lower-test-functions-direct-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]) : i64
  (+
    (lower-test-functions-call-count funcs name)
    (lower-test-functions-tail-call-count funcs name)))

(define (lower-test-functions-cpuid-count [funcs : CompilerIrFunctionList]) : i64
  (match funcs
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (+
            (lower-test-blocks-cpuid-count blocks)
            (lower-test-functions-cpuid-count (box-get rest)))])]))

(define (lower-test-functions-xgetbv-count [funcs : CompilerIrFunctionList]) : i64
  (match funcs
    [(IrFunctionNil) 0]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (+
            (lower-test-blocks-xgetbv-count blocks)
            (lower-test-functions-xgetbv-count (box-get rest)))])]))

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
            (lower-test-function-call-count (box-get rest) name call-name))])]))

(define (lower-test-function-call-before?
  [funcs : CompilerIrFunctionList]
  [name : String]
  [first : String]
  [second : String]) : bool
  (match funcs
    [(IrFunctionNil) false]
    [(IrFunctionCons func rest)
      (match func
        [(IrFunction fname _ _ _ blocks)
          (if (string-eq fname name)
            (lower-test-blocks-call-before? blocks first second)
            (lower-test-function-call-before? (box-get rest) name first second))])]))

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
            (lower-test-function-indirect-call-count (box-get rest) name))])]))

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
            (lower-test-function-indirect-unit-count (box-get rest) name))])]))

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
            (lower-test-function-return-function-count
              (box-get rest)
              name
              function-name))])]))

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
              (box-get rest)
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
              (box-get rest)
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
            (lower-test-function-tail-call-count (box-get rest) name call-name))])]))

(define (lower-test-function-direct-call-count
  [funcs : CompilerIrFunctionList]
  [name : String]
  [call-name : String]) : i64
  (+
    (lower-test-function-call-count funcs name call-name)
    (lower-test-function-tail-call-count funcs name call-name)))

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
            (lower-test-function-store-ptr-count (box-get rest) name))])]))

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
            (lower-test-function-alloc-count (box-get rest) name))])]))

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
            (lower-test-function-addr-of-count (box-get rest) name))])]))

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
            (lower-test-function-vector-load-count (box-get rest) name))])]))

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
            (lower-test-function-vector-binop-count (box-get rest) name))])]))

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
            (lower-test-function-vector-reduce-count (box-get rest) name))])]))

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
            (lower-test-function-vector-store-count (box-get rest) name))])]))

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
            (lower-test-function-predicated-load-count (box-get rest) name))])]))

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
            (lower-test-function-predicated-store-count (box-get rest) name))])]))

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
            (lower-test-function-tail-mask-count (box-get rest) name))])]))

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
            (lower-test-function-vector-shape-count
              (box-get rest)
              name
              lanes
              elem-ty))])]))

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
            (lower-test-function-u64-mov-count (box-get rest) name))])]))

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
            (lower-test-function-binop-op-count (box-get rest) name op))])]))

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
            (lower-test-function-cast-count (box-get rest) name))])]))

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
            (lower-test-function-store-global-count
              (box-get rest)
              name
              global-name))])]))

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
            (lower-test-global-list-has-name? (box-get rest) name))])]))

(define (compiler-lower-defdispatch-thunk-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-defdispatch-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram globals functions _)
          (let
            [cache-name : String "__tl_dispatch_cache_dot"]
            [scalar-name : String
              "__tl_dispatch_variant_scalar_dot__dot-scalar"]
            [avx2-name : String "__tl_dispatch_variant_avx2_dot__dot-avx2"]
            [avx512-name : String
              "__tl_dispatch_variant_avx512_dot__dot-avx512"]
            [ok : bool true]
            (begin
              (if (lower-test-global-list-has-name? globals cache-name)
                unit
                (set! ok false))
              (if (lower-test-function-defined? functions "dot")
                unit
                (set! ok false))
              (if (lower-test-function-defined? functions scalar-name)
                unit
                (set! ok false))
              (if (lower-test-function-defined? functions avx2-name)
                unit
                (set! ok false))
              (if (lower-test-function-defined? functions avx512-name)
                unit
                (set! ok false))
              (when
                (lower-test-function-defined? functions "dot-scalar")
                (set! ok false))
              (when
                (lower-test-function-defined? functions "dot-avx2")
                (set! ok false))
              (when
                (lower-test-function-defined? functions "dot-avx512")
                (set! ok false))
              (if (= (lower-test-function-call-count functions "main" "dot") 1)
                unit
                (set! ok false))
              (if (>=
                (lower-test-function-indirect-call-count functions "dot")
                4)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-store-global-count
                  functions
                  "dot"
                  cache-name)
                3)
                unit
                (set! ok false))
              (if (>= (lower-test-functions-cpuid-count functions) 6)
                unit
                (set! ok false))
              (if (= (lower-test-functions-xgetbv-count functions) 2)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-callee-function-count
                  functions
                  "dot"
                  scalar-name)
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-callee-function-count
                  functions
                  "dot"
                  avx2-name)
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-indirect-callee-function-count
                  functions
                  "dot"
                  avx512-name)
                1)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-defdispatch-shared-helper-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-defdispatch-shared-helper-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [scalar-name : String
              "__tl_dispatch_variant_scalar_dot__dot-scalar"]
            [avx2-name : String "__tl_dispatch_variant_avx2_dot__dot-avx2"]
            [avx512-name : String
              "__tl_dispatch_variant_avx512_dot__dot-avx512"]
            [ok : bool true]
            (begin
              (if (lower-test-function-defined? functions "dispatch-helper")
                unit
                (set! ok false))
              (when
                (lower-test-function-defined? functions "dot-scalar")
                (set! ok false))
              (when
                (lower-test-function-defined? functions "dot-avx2")
                (set! ok false))
              (when
                (lower-test-function-defined? functions "dot-avx512")
                (set! ok false))
              (if (=
                (lower-test-function-direct-call-count
                  functions
                  scalar-name
                  "dispatch-helper")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-direct-call-count
                  functions
                  avx2-name
                  "dispatch-helper")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-function-direct-call-count
                  functions
                  avx512-name
                  "dispatch-helper")
                1)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-generated-path-source) : String
  "(comptime-decl (:generated point-family Point \"same\")
  (defstruct Point (x i64)))
(comptime-decl (:generated point-family Point \"same\")
  (defstruct Point (x i64)))
(define (after [x : i64]) : i64 (+ x 1))
(define (main) : i64 (after 41))")

(define (compiler-lower-generated-paths) : AstDeclPathList
  (ast-decl-path-cons
    "gen.tl"
    (ast-decl-path-cons
      "gen.tl"
      (ast-decl-path-cons "lib.tl" (ast-decl-path-cons "app.tl" AstDeclPathNil)))))

(define (compiler-lower-generated-paths-preserved-ok?) : bool
  (match (parse-ast-source (compiler-lower-generated-path-source))
    [(OkAstProgram program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-generated-paths))
        [(OkCompilerLower lowered _)
          (match lowered
            [(IrProgram _ functions _)
              (and
                (lower-test-function-defined? functions "lib.tl::after")
                (and
                  (lower-test-function-defined? functions "main")
                  (=
                    (lower-test-function-direct-call-count
                      functions
                      "main"
                      "lib.tl::after")
                    1)))])]
        [(ErrCompilerLower _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-lower-module-symbol-source) : String
  "(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x answer))
(define (main) : i64 (inc answer))")

(define (compiler-lower-module-symbol-paths) : AstDeclPathList
  (ast-decl-path-cons
    "lib.tl"
    (ast-decl-path-cons "lib.tl" (ast-decl-path-cons "app.tl" AstDeclPathNil))))

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
                    (lower-test-functions-direct-call-count
                      functions
                      "lib.tl::inc")
                    0)
                  (and
                    (>
                      (lower-test-function-binop-count functions "lib.tl::inc")
                      0)
                    (>= (lower-test-function-binop-count functions "main") 0))))])]
        [(ErrCompilerLower _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-lower-package-owned-symbol-source) : String
  "(define (runtime-helper) : i64 1)
(define (app-helper) : i64 41)
(define (main) : i64 (+ (runtime-helper) (app-helper)))")

(define (compiler-lower-package-owned-symbol-paths) : AstDeclPathList
  (ast-decl-path-cons
    "stdlib/runtime.tl"
    (ast-decl-path-cons
      "app/src/main.tl"
      (ast-decl-path-cons "" AstDeclPathNil))))

(define (compiler-lower-package-owned-symbols-ok?) : bool
  (match (parse-ast-source (compiler-lower-package-owned-symbol-source))
    [(OkAstProgram program)
      (match (lower-compiler-program-with-decl-paths
        ""
        program
        (compiler-lower-package-owned-symbol-paths))
        [(OkCompilerLower lowered _)
          (match lowered
            [(IrProgram _ functions _)
              (and
                (lower-test-function-defined?
                  functions
                  "stdlib/runtime.tl::runtime-helper")
                (and
                  (lower-test-function-defined? functions "main")
                  (=
                    (lower-test-function-call-count
                      functions
                      "main"
                      "app/src/main.tl::app-helper")
                    1)))])]
        [(ErrCompilerLower _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-lower-module-qualified-source) : String
  "(module left)
(define same : i64 20)
(define (get) : i64 same)
(export (value get))
(module right)
(define same : i64 22)
(define (get) : i64 same)
(export (value get))
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
(export
  (value get)
  (type Maybe)
  (variant None)
  (variant Some)
  (type Point)
  (constructor Point)
  (field Point x))
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
(defenum CandList (CandNil) (CandCons Candidate (Box CandList)))
(define (cand-nth [cands : CandList]) : Candidate
  (match cands
    [(CandNil) (Candidate 0)]
    [(CandCons head rest) head]))
(export
  (value cand-nth)
  (type Candidate)
  (constructor Candidate)
  (field Candidate number)
  (type CandList)
  (variant CandNil)
  (variant CandCons))
(module main)
(define (main) : i64
  (let [c : data/Candidate
    (data/cand-nth (data/CandCons (data/Candidate 7) (box (data/CandNil))))]
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
(export (type Maybe) (variant get))
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
  (ast-decl-path-cons "app.tl" (ast-decl-path-cons "app.tl" AstDeclPathNil)))

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
                (lower-test-functions-direct-call-count
                  functions
                  "__tl_specialized_alloc_type_i64_none")
                0)])]
        [(ErrCompilerLower _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-lower-extern-link-metadata-source) : String
  "(extern (ffi-add [arg0 : i64]) : i64 (:abi c) (:symbol \"ffi_add\") (:link-lib \"ffi\") (:link-search \"native\") (:link-arg \"-Wl,--as-needed\"))
(define (main) : i64 (ffi-add 35))")

(define (compiler-lower-c-abi-unsupported-aggregate-source) : String
  "(defstruct Big (lo i64) (hi i64))
(extern (big-use [arg0 : Big]) : i64 (:symbol \"tl_cabi_big_use\"))
(define (main) : i64
  (big-use (Big 1 2)))")

(define (compiler-lower-c-abi-windows-unsupported-aggregate-source) : String
  "(defstruct Rgb (r u8) (g u8) (b u8))
(extern (rgb-use [arg0 : Rgb]) : i64 (:symbol \"tl_cabi_rgb_use\"))
(define (main) : i64
  (rgb-use (Rgb (cast 1 : u8) (cast 2 : u8) (cast 3 : u8))))")

(define (compiler-lower-extern-link-inputs-ok?
  [inputs : AstExternLinkInputList]) : bool
  (match inputs
    [(AstExternLinkInputCons (AstExternLinkLib lib) rest0)
      (let
        [rest0 : AstExternLinkInputList (box-get rest0)]
        (match rest0
          [(AstExternLinkInputCons (AstExternLinkSearch dir) rest1)
            (let
              [rest1 : AstExternLinkInputList (box-get rest1)]
              (match rest1
                [(AstExternLinkInputCons (AstExternLinkArg arg-value) rest2)
                  (let
                    [rest2 : AstExternLinkInputList (box-get rest2)]
                    (match rest2
                      [(AstExternLinkInputNil)
                        (and
                          (string-eq lib "ffi")
                          (and
                            (string-eq dir "native")
                            (string-eq arg-value "-Wl,--as-needed")))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (compiler-lower-extern-link-metadata-ok?) : bool
  (match (lower-compiler-source (compiler-lower-extern-link-metadata-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ _ externs)
          (match externs
            [(IrExternCons
                (IrExtern name _ abi symbol link-inputs _)
                IrExternNil)
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
  "(extern (print-i64 [arg0 : i64]) : unit)
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

(define (compiler-lower-tail-direct-source) : String
  "(define (finish [x : i64] [y : i64]) : i64 (+ x y))
(define (step [x : i64]) : i64 (finish x 1))
(define (main) : i64 (step 41))")

(define (compiler-lower-tail-direct-stack-source) : String
  "(define (finish5
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]) : i64
  (+ a (+ b (+ c (+ d e)))))
(define (step5 [x : i64]) : i64 (finish5 x 1 2 3 4))
(define (main) : i64 (step5 32))")

(define (compiler-lower-tail-cleanup-source) : String
  "(define (finish [x : i64]) : i64 x)
(define (step [x : i64]) : i64
  (with-arena scratch
    (finish x)))
(define (main) : i64 (step 42))")

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

(define (compiler-lower-tail-direct-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tail-direct-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count functions "step" "finish")
              1)
            (= (lower-test-function-call-count functions "step" "finish") 0))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-tail-direct-stack-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tail-direct-stack-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count functions "step5" "finish5")
              0)
            (> (lower-test-function-call-count functions "step5" "finish5") 0))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-tail-cleanup-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-tail-cleanup-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (=
              (lower-test-function-tail-call-count functions "step" "finish")
              0)
            (> (lower-test-function-call-count functions "step" "finish") 0))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-tail-call-shape-ok?) : bool
  (and
    (compiler-lower-tail-simple-shape-ok?)
    (and
      (compiler-lower-tail-context-shape-ok?)
      (and
        (compiler-lower-tail-operand-shape-ok?)
        (and
          (compiler-lower-tail-direct-shape-ok?)
          (and
            (compiler-lower-tail-direct-stack-shape-ok?)
            (compiler-lower-tail-cleanup-shape-ok?)))))))

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
        (lower-test-instrs-i64-mov-count (box-get rest) want))]))

(define (lower-test-instrs-binop-count [instrs : CompilerIrInstrList]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-binop-count instr)
        (lower-test-instrs-binop-count (box-get rest)))]))

(define (lower-test-instrs-gep-offset-count
  [instrs : CompilerIrInstrList]
  [want : i64]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (lower-test-instr-gep-offset-count instr want)
        (lower-test-instrs-gep-offset-count (box-get rest) want))]))

(define (lower-test-instr-seq-i64-mov-count
  [instrs : CompilerIrInstrSeq]
  [want : i64]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-i64-mov-count (array-ref slots index) want)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-binop-count [instrs : CompilerIrInstrSeq]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+ acc (lower-test-instr-binop-count (array-ref slots index))))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-instr-seq-gep-offset-count
  [instrs : CompilerIrInstrSeq]
  [want : i64]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [acc : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            acc
            (+
              acc
              (lower-test-instr-gep-offset-count (array-ref slots index) want)))
          (set! index (+ index 1))))
      acc)))

(define (lower-test-blocks-i64-mov-count
  [blocks : CompilerIrBlockList]
  [want : i64]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-i64-mov-count instrs want)
            (lower-test-blocks-i64-mov-count (box-get rest) want))])]))

(define (lower-test-blocks-binop-count [blocks : CompilerIrBlockList]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-binop-count instrs)
            (lower-test-blocks-binop-count (box-get rest)))])]))

(define (lower-test-blocks-gep-offset-count
  [blocks : CompilerIrBlockList]
  [want : i64]) : i64
  (match blocks
    [(IrBlockNil) 0]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (+
            (lower-test-instr-seq-gep-offset-count instrs want)
            (lower-test-blocks-gep-offset-count (box-get rest) want))])]))

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
            (lower-test-function-i64-mov-count (box-get rest) name want))])]))

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
            (lower-test-function-binop-count (box-get rest) name))])]))

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
            (lower-test-function-gep-offset-count (box-get rest) name want))])]))

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

(define (compiler-lower-enum-string-literal-payload-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-enum-string-literal-payload-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (= (lower-test-functions-call-count functions "tl_string_eq") 1)
            (= (lower-test-functions-call-count functions "string-eq") 0))])]
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

(define (compiler-lower-option-try-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-option-try-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (> (lower-test-function-branch-count functions "main") 1)
            (> (lower-test-function-return-count functions "main") 2))])]
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

(define (compiler-lower-cleanup-struct-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-cleanup-struct-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (=
              (lower-test-function-direct-call-count
                functions
                "cleanup-file-handle"
                "close-fd")
              1)
            (and
              (>
                (lower-test-function-direct-call-count
                  functions
                  "main"
                  "cleanup-file-handle")
                1)
              (> (lower-test-function-return-count functions "main") 1)))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-cleanup-struct-nested-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-cleanup-struct-nested-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (=
              (lower-test-function-direct-call-count
                functions
                "cleanup-file-handle"
                "close-fd")
              1)
            (and
              (=
                (lower-test-function-call-count
                  functions
                  "cleanup-buffered-file"
                  "close-buffer")
                1)
              (and
                (=
                  (lower-test-function-direct-call-count
                    functions
                    "cleanup-buffered-file"
                    "cleanup-file-handle")
                  1)
                (lower-test-function-call-before?
                  functions
                  "cleanup-buffered-file"
                  "close-buffer"
                  "cleanup-file-handle"))))])]
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
            (and
              (> (lower-test-functions-call-count functions "tl_oob_abort") 0)
              (=
                (lower-test-function-call-count
                  functions
                  "main"
                  "tl_array_zero")
                1)))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-make-array-init-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (=
              (lower-test-function-call-count functions "main" "tl_array_fill8")
              1)
            (and
              (>= (lower-test-function-store-ptr-count functions "main") 2)
              (> (lower-test-functions-call-count functions "tl_alloc") 0)))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-string-runtime-shape-ok? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-functions-call-count functions "tl_substring")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_string_concat")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_oob_abort")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-direct-call-count functions "substring")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-direct-call-count
                  functions
                  "string-append")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-direct-call-count
                  functions
                  "string-concat")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_print_str")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  "__tl_rt_print_string")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-direct-call-count
                  functions
                  "print-string")
                2)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-direct-call-count functions "print-str")
                1)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-string-concat-fusion-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-string-concat-fusion-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-functions-call-count functions "tl_string_concat")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_string_concat3")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_string_concat4")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_string_concat5")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-direct-call-count
                  functions
                  "string-append")
                0)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-print-string-stdlib-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-print-string-stdlib-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (= (lower-test-functions-call-count functions "tl_print_str") 0)
            (and
              (=
                (lower-test-functions-direct-call-count
                  functions
                  "print-string")
                2)
              (=
                (lower-test-functions-direct-call-count functions "print-str")
                1)))])]
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
                (lower-test-function-direct-call-count
                  functions
                  "main"
                  "borrowed-score")
                0)
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

(define (compiler-lower-stdlib-hash-string-shape-ok?) : bool
  (match (parse-ast-source (compiler-lower-stdlib-hash-string-source))
    [(OkAstProgram program)
      (match (lower-compiler-program-with-decl-paths
        "app.tl"
        program
        (compiler-lower-stdlib-hash-string-paths))
        [(OkCompilerLower lowered _)
          (match lowered
            [(IrProgram _ functions _)
              (let
                [name : String "stdlib/hash.tl::hash-string"]
                [ok : bool true]
                (begin
                  (if (=
                    (lower-test-function-call-count
                      functions
                      name
                      "tl_hash_string")
                    1)
                    unit
                    (set! ok false))
                  (if (= (lower-test-function-bounds-count functions name) 0)
                    unit
                    (set! ok false))
                  (if (=
                    (lower-test-function-direct-call-count
                      functions
                      "main"
                      name)
                    1)
                    unit
                    (set! ok false))
                  ok))])]
        [(ErrCompilerLower _) false])]
    [(ErrAstProgram _) false]))

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
              (if (> (lower-test-function-store-ptr-count functions "main") 1)
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

(define (compiler-lower-reference-nominal-aggregate-ok?) : bool
  (and
    (compiler-lower-ok? (compiler-lower-reference-struct-result-source))
    (and
      (compiler-lower-ok? (compiler-lower-reference-struct-multi-result-source))
      (compiler-lower-ok? (compiler-lower-reference-enum-result-source)))))

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

(define (compiler-lower-capturing-lambda-reference-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-capturing-lambda-reference-source))
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
              (if (>= (lower-test-function-load-count functions lambda-name) 1)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-capturing-lambda-reference-immediate-shape-ok?) : bool
  (match (lower-compiler-source
    (compiler-lower-capturing-lambda-reference-immediate-source))
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
              (if (>= (lower-test-function-load-count functions lambda-name) 1)
                unit
                (set! ok false))
              ok))])]
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
          (and
            (compiler-lower-capturing-lambda-shadow-shape-ok?)
            (and
              (compiler-lower-capturing-lambda-reference-shape-ok?)
              (compiler-lower-capturing-lambda-reference-immediate-shape-ok?))))))))

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
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_file_close_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_append_file_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_file_read_chunk_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_file_write_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_file_flush_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_file_read_chunk_bytes")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_file_read_chunk_eof")
                0)
                unit
                (set! ok false))
              (if (> (lower-test-functions-call-count functions "os-open") 0)
                unit
                (set! ok false))
              (if (> (lower-test-functions-call-count functions "os-close") 0)
                unit
                (set! ok false))
              (if (> (lower-test-functions-call-count functions "os-read") 0)
                unit
                (set! ok false))
              (if (> (lower-test-functions-call-count functions "os-write") 0)
                unit
                (set! ok false))
              (if (> (lower-test-functions-call-count functions "os-fflush") 0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-call-count functions "file-open-status")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-call-count functions "file-close-status")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-call-count functions "append-file-status")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-call-count
                  functions
                  "file-read-chunk-status")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-call-count functions "file-write-status")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-call-count functions "file-flush-status")
                0)
                unit
                (set! ok false))
              (if (>
                (lower-test-functions-call-count
                  functions
                  "file-read-chunk-bytes")
                0)
                unit
                (set! ok false))
              (if (>
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
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_remove_file_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_remove_dir_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_rename_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_read_dir_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions ".L_tl_fs_read_dir")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_file_kind_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_file_size_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions ".L_tl_fs_file_size")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_fs_process_id")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  "tl_fs_current_dir_status")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_fs_current_dir")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "fs-mkdir-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  "fs-remove-file-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  "fs-remove-dir-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "fs-rename-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "fs-read-dir-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "fs-read-dir")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  "fs-file-kind-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  "fs-file-size-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "fs-file-size")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "fs-process-id")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  "fs-current-dir-status")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "fs-current-dir")
                1)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-region-source) : String
  "(define (int->string [value : i64]) : String
  \"41\")
(define (main) : i64
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

(define (compiler-lower-with-arena-source [src : String]) : String
  (string-append
    "(extern (tl_arena_make) : i64)
(extern (tl_arena_current) : i64)
(extern (tl_region_mark) : i64)
(unsafe (extern (tl_arena_set [arg0 : i64]) : unit))
(unsafe (extern (tl_region_reset [arg0 : i64]) : unit))
(define (arena-make) : i64 (tl_arena_make))
(define (arena-current) : i64 (tl_arena_current))
(define (arena-mark) : i64 (tl_region_mark))
(unsafe (define (arena-set! [arena : i64]) : unit (unsafe (tl_arena_set arena))))
(unsafe (define (arena-rewind [mark : i64]) : unit (unsafe (tl_region_reset mark))))
(define (int->string [value : i64]) : String \"42\")
"
    src))

(define (compiler-lower-with-escape-scalar-source) : String
  (compiler-lower-with-arena-source
    "(define (main) : i64
  (let
    [scratch : i64 (arena-make)]
    (with-escape scratch 40 42)))"))

(define (compiler-lower-with-escape-string-source) : String
  (compiler-lower-with-arena-source
    "(define (main) : String
  (let
    [scratch : i64 (arena-make)]
    (with-escape scratch (int->string 42))))"))

(define (compiler-lower-with-escape-array-source) : String
  (compiler-lower-with-arena-source
    "(define (main) : (Array String)
  (let
    [scratch : i64 (arena-make)]
    (with-escape scratch
      (let
        [items : (Array String) (make-array String 2)]
        (begin
          (array-set! items 0 (int->string 1))
          (array-set! items 1 (int->string 2))
          items)))))"))

(define (compiler-lower-with-escape-box-source) : String
  (compiler-lower-with-arena-source
    "(define (main) : (Box String)
  (let
    [scratch : i64 (arena-make)]
    (with-escape scratch (box (int->string 42)))))"))

(define (compiler-lower-with-escape-owning-source) : String
  (compiler-lower-with-arena-source
    "(defstruct EscapePayload
  (name String)
  (items (Array String))
  (cell (Box String)))
(defenum EscapeResult
  (EscapeOk EscapePayload)
  (EscapeNone))
(define (main) : EscapeResult
  (let
    [scratch : i64 (arena-make)]
    (with-escape scratch
      (let
        [items : (Array String) (make-array String 2)]
        (begin
          (array-set! items 0 (int->string 1))
          (array-set! items 1 (int->string 2))
          (EscapeOk
            (EscapePayload
              (int->string 3)
              items
              (box (int->string 4)))))))))"))

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

(define (compiler-lower-with-escape-array-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-with-escape-array-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (compiler-lower-with-escape-arena-shape-ok?
              (compiler-lower-with-escape-array-source))
            (and
              (> (lower-test-functions-call-count functions "tl_alloc") 1)
              (> (lower-test-function-branch-count functions "main") 0)))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-with-escape-box-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-with-escape-box-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (compiler-lower-with-escape-arena-shape-ok?
              (compiler-lower-with-escape-box-source))
            (and
              (> (lower-test-functions-call-count functions "tl_alloc") 0)
              (> (lower-test-functions-call-count functions "tl_substring") 0)))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-with-escape-owning-shape-ok?) : bool
  (match (parse-ast-source (compiler-lower-with-escape-owning-source))
    [(OkAstProgram ast)
      (match (lower-compiler-program-with-decl-paths
        "<source>"
        ast
        AstDeclPathNil)
        [(OkCompilerLower program _)
          (match program
            [(IrProgram _ functions _)
              (and
                (compiler-lower-with-escape-arena-shape-ok?
                  (compiler-lower-with-escape-owning-source))
                (and
                  (=
                    (lower-test-function-call-count
                      functions
                      "main"
                      "<source>::clone$EscapeResult")
                    1)
                  (and
                    (lower-test-function-defined?
                      functions
                      "<source>::clone$EscapeResult")
                    (> (lower-test-functions-call-count functions "tl_alloc") 0))))])]
        [(ErrCompilerLower _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-lower-with-escape-shape-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-lower-with-escape-arena-shape-ok?
        (compiler-lower-with-escape-scalar-source))
        unit
        (set! ok false))
      (if (match (lower-compiler-source
        (compiler-lower-with-escape-string-source))
        [(OkCompilerLower program _)
          (match program
            [(IrProgram _ functions _)
              (and
                (compiler-lower-with-escape-arena-shape-ok?
                  (compiler-lower-with-escape-string-source))
                (> (lower-test-functions-call-count functions "tl_substring") 0))])]
        [(ErrCompilerLower _) false])
        unit
        (set! ok false))
      (if (compiler-lower-with-escape-array-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-with-escape-box-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-with-escape-owning-shape-ok?)
        unit
        (set! ok false))
      ok)))

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

(define (compiler-lower-avx2-foreach-map-f32-source) : String
  "(define (fill [a : (Array f32)] [b : (Array f32)] [out : (Array f32)] [n : i64]) : unit
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
      (and
        (compiler-lower-avx2-foreach-map-source-shape-ok?
          (compiler-lower-avx2-foreach-map-f64-source)
          (AstTyF64)
          4)
        (compiler-lower-avx2-foreach-map-source-shape-ok?
          (compiler-lower-avx2-foreach-map-f32-source)
          (AstTyF32)
          8)))))

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
      (and
        (compiler-lower-avx512-foreach-map-source-shape-ok?
          (compiler-lower-avx2-foreach-map-f64-source)
          (AstTyF64)
          8)
        (compiler-lower-avx512-foreach-map-source-shape-ok?
          (compiler-lower-avx2-foreach-map-f32-source)
          (AstTyF32)
          16)))))

(define (compiler-lower-avx512-masked-if-source) : String
  "(define (fill [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< (array-ref xs i) 0)
      (array-set! out i 0)
      (array-set! out i (+ (array-ref xs i) 1)))))")

(define (compiler-lower-avx512-masked-if-offset-source) : String
  "(define (fill [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< (array-ref xs (+ i 1)) 0)
      (array-set! out (+ i 1) 0)
      (array-set! out (+ i 1) (+ (array-ref xs (+ i 1)) 1)))))")

(define (compiler-lower-avx512-masked-if-source-shape-ok? [src : String]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerAvx512))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [load-count : i64
              (lower-test-function-vector-load-count functions "fill")]
            [store-count : i64
              (lower-test-function-vector-store-count functions "fill")]
            [binop-count : i64
              (lower-test-function-vector-binop-count functions "fill")]
            [pred-load-count : i64
              (lower-test-function-predicated-load-count functions "fill")]
            [pred-store-count : i64
              (lower-test-function-predicated-store-count functions "fill")]
            [tail-mask-count : i64
              (lower-test-function-tail-mask-count functions "fill")]
            [tail-store-count : i64
              (lower-test-function-store-ptr-count functions "fill")]
            (compiler-lower-and8
              (= load-count 0)
              (= store-count 0)
              (>= binop-count 2)
              (>= pred-load-count 4)
              (>= pred-store-count 4)
              (= tail-mask-count 2)
              (> tail-store-count 0)
              true))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-avx512-masked-if-shape-ok?) : bool
  (compiler-lower-avx512-masked-if-source-shape-ok?
    (compiler-lower-avx512-masked-if-source)))

(define (compiler-lower-avx512-masked-if-offset-shape-ok?) : bool
  (compiler-lower-avx512-masked-if-source-shape-ok?
    (compiler-lower-avx512-masked-if-offset-source)))

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
    (and
      (compiler-lower-avx2-foreach-fallback-stays-scalar-ok?)
      (and
        (compiler-lower-avx512-masked-if-shape-ok?)
        (compiler-lower-avx512-masked-if-offset-shape-ok?)))))

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

(define (compiler-lower-avx512-spmd-reduce-shape-ok?
  [src : String]
  [elem-ty : AstType]
  [lanes : i64]) : bool
  (match (lower-compiler-source-with-mode src (CompilerLowerAvx512))
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
      (compiler-lower-avx2-spmd-reduce-shape-ok?
        "(define (f [xs : (Array f64)] [n : i64]) : f64 (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref xs i)))"
        (AstTyF64)
        4)
      (compiler-lower-avx2-spmd-reduce-stays-scalar-ok?
        "(define (f [xs : (Array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))")
      true
      true)
    true))

(define (compiler-lower-avx512-spmd-reduce-tests-ok?) : bool
  (compiler-lower-and8
    (compiler-lower-avx512-spmd-reduce-shape-ok?
      "(define (f [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))"
      (AstTyI64)
      8)
    (compiler-lower-avx512-spmd-reduce-shape-ok?
      "(define (f [xs : (Array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
      (AstTyI64)
      8)
    (compiler-lower-avx512-spmd-reduce-shape-ok?
      "(define (f [xs : (Array i64)] [n : i64] [seed : i64]) : i64 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
      (AstTyI64)
      8)
    (compiler-lower-avx512-spmd-reduce-shape-ok?
      "(define (f [xs : (Array f64)] [n : i64]) : f64 (spmd-reduce sum ([i : i64 0 n]) 0.0 (array-ref xs i)))"
      (AstTyF64)
      8)
    (compiler-lower-avx512-spmd-reduce-shape-ok?
      "(define (f [xs : (Array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))"
      (AstTyI32)
      16)
    (compiler-lower-avx512-spmd-reduce-shape-ok?
      "(define (f [xs : (Array i32)] [n : i64] [seed : i32]) : i32 (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))"
      (AstTyI32)
      16)
    true
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
                (and
                  (compiler-lower-avx2-spmd-reduce-tests-ok?)
                  (compiler-lower-avx512-spmd-reduce-tests-ok?))))))))))

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
;; folds to its byte size / alignment (equal for primitives) inside `(comptime â€¦)`.
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
    (compiler-lower-raw-pointer-addr-of-shape-ok?)
    (and
      (compiler-lower-ok? (compiler-lower-raw-pointer-direct-call-source))
      (compiler-lower-ok? (compiler-lower-raw-pointer-call-value-source)))))

(define (compiler-lower-raw-pointer-addr-of-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-raw-pointer-ops-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (and
            (= (lower-test-function-call-count functions "main" "tl_alloc") 0)
            (and
              (= (lower-test-function-addr-of-count functions "main") 1)
              (>= (lower-test-function-store-ptr-count functions "main") 2)))])]
    [(ErrCompilerLower _) false]))

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

(define (compiler-lower-stdio-builtin-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-stdio-builtin-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-functions-call-count functions ".L_tl_flush_stdout")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions ".L_tl_stdin_eof")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_read_stdin_line")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count
                  functions
                  ".L_tl_read_stdin_bytes")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "flush-stdout")
                1)
                unit
                (set! ok false))
              (if (= (lower-test-functions-call-count functions "stdin-eof?") 1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "read-stdin-line")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "read-stdin-bytes")
                1)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-env-builtin-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-env-builtin-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (=
                (lower-test-functions-call-count functions "tl_env_var_exists")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-call-count functions "tl_env_var_value")
                0)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-direct-call-count
                  functions
                  "env-var-exists?")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-direct-call-count
                  functions
                  "env-var-value")
                1)
                unit
                (set! ok false))
              (if (=
                (lower-test-functions-direct-call-count
                  functions
                  "env-path-separator")
                1)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-stdlib-helper-defaults-disabled-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (when (lower-bootstrap-runtime-builtin? "print") (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "print-string") (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "print-str") (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "print-newline") (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "print-bool") (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "print-char") (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "print-float") (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "print-error") (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "panic") (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "error") (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "arg-count") (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "arg") (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "read-file") (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "write-file") (set! ok false))
      (when
        (lower-bootstrap-runtime-builtin? "file-open-status")
        (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "fs-process-id") (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "fs-current-dir") (set! ok false))
      (when
        (lower-bootstrap-runtime-builtin? "read-stdin-line")
        (set! ok false))
      (when
        (lower-bootstrap-runtime-builtin? "read-stdin-bytes")
        (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "stdin-eof?") (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "flush-stdout") (set! ok false))
      (when
        (lower-bootstrap-runtime-builtin? "env-var-exists?")
        (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "env-var-value") (set! ok false))
      (when
        (lower-bootstrap-runtime-builtin? "env-path-separator")
        (set! ok false))
      (when (lower-bootstrap-runtime-builtin? "int->string") (set! ok false))
      (when (lower-string-runtime-builtin? "substring") (set! ok false))
      (when (lower-string-runtime-builtin? "string-slice") (set! ok false))
      (when (lower-string-runtime-builtin? "string-append") (set! ok false))
      (when (lower-string-runtime-builtin? "string-concat") (set! ok false))
      ok)))

(define (compiler-lower-cpu-builtin-shape-ok?) : bool
  (match (lower-compiler-source (compiler-lower-cpu-builtin-source))
    [(OkCompilerLower program _)
      (match program
        [(IrProgram _ functions _)
          (let
            [ok : bool true]
            (begin
              (if (>= (lower-test-functions-cpuid-count functions) 4)
                unit
                (set! ok false))
              (if (= (lower-test-functions-xgetbv-count functions) 1)
                unit
                (set! ok false))
              (if (= (lower-test-functions-call-count functions "cpuid") 0)
                unit
                (set! ok false))
              (if (= (lower-test-functions-call-count functions "xgetbv") 0)
                unit
                (set! ok false))
              (if (= (lower-test-functions-call-count functions "tl_cpuid") 0)
                unit
                (set! ok false))
              (if (= (lower-test-functions-call-count functions "tl_xgetbv") 0)
                unit
                (set! ok false))
              ok))])]
    [(ErrCompilerLower _) false]))

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
      (if (compiler-lower-string-concat-fusion-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-print-string-stdlib-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-borrowed-str-param-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-stdlib-hash-string-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-string-shadow-shape-ok?
        (compiler-lower-string-shadow-source))
        unit
        (set! ok false))
      (if (compiler-lower-stdio-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-stdio-builtin-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-stdlib-helper-defaults-disabled-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-env-builtin-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-cpu-builtin-shape-ok?)
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
      (if (compiler-lower-ok? (compiler-lower-macro-hygiene-definition-source))
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
      (if (compiler-lower-ok?
        (compiler-lower-enum-string-literal-payload-source))
        unit
        (set! ok false))
      (if (compiler-lower-enum-string-literal-payload-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-export-source))
        unit
        (set! ok false))
      (if (compiler-lower-defdispatch-thunk-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-defdispatch-shared-helper-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-result-try-source))
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-option-try-source))
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
      (if (compiler-lower-option-try-shape-ok?)
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
      (if (compiler-lower-cleanup-struct-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-cleanup-struct-nested-shape-ok?)
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
      (if (compiler-lower-array-access-shape-ok?
        (compiler-lower-mut-ref-array-access-source))
        unit
        (set! ok false))
      (if (compiler-lower-array-push-shape-ok?
        (compiler-lower-array-push-source))
        unit
        (set! ok false))
      (if (compiler-lower-array-push-shape-ok?
        (compiler-lower-mut-ref-array-access-source))
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
      (if (compiler-lower-make-array-init-shape-ok?
        (compiler-lower-make-array-init-source))
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
      (if (compiler-lower-ok? (compiler-lower-init-source))
        unit
        (set! ok false))
      (if (compiler-lower-tuple-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-tuple-return-source))
        unit
        (set! ok false))
      (if (compiler-lower-clone-shape-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-clone-reachable-helpers-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-error-ok?
        (compiler-lower-clone-unsupported-source)
        "typecheck: clone unsupported type (-> i64 i64)")
        unit
        (set! ok false))
      (if (compiler-lower-inline-aggregate-tests-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-ok? (compiler-lower-comptime-decl-source))
        unit
        (set! ok false))
      (if (compiler-lower-generated-paths-preserved-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-module-symbols-ok?)
        unit
        (set! ok false))
      (if (compiler-lower-package-owned-symbols-ok?)
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
      (if (compiler-lower-linux-error-ok?
        (compiler-lower-c-abi-unsupported-aggregate-source)
        "lower: unsupported linux-x86_64 C aggregate ABI for Big; this slice supports integer-only structs up to 8 bytes")
        unit
        (set! ok false))
      (if (compiler-lower-windows-error-ok?
        (compiler-lower-c-abi-unsupported-aggregate-source)
        "lower: unsupported windows-x86_64 C aggregate ABI for Big; this slice supports integer-only structs of size 1, 2, 4, or 8 bytes")
        unit
        (set! ok false))
      (if (compiler-lower-windows-error-ok?
        (compiler-lower-c-abi-windows-unsupported-aggregate-source)
        "lower: unsupported windows-x86_64 C aggregate ABI for Rgb; this slice supports integer-only structs of size 1, 2, 4, or 8 bytes")
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
    [(AstDeclCons _ rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (+ 1 (lower-test-decl-list-count rest)))]))

(define (lower-test-decl-list-defines? [decls : AstDeclList] [name : String]) : bool
  (match decls
    [(AstDeclNil) false]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclDefFn found _ _ _ _)
            (if (string-eq found name)
              true
              (lower-test-decl-list-defines? rest name))]
          [(AstDeclComptimeDecl _ inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (if (lower-test-decl-list-defines?
                (ast-decl-cons inner AstDeclNil)
                name)
                true
                (lower-test-decl-list-defines? rest name)))]
          [(AstDeclUnsafe inner-box)
            (let
              [inner : AstDecl (box-get inner-box)]
              (if (lower-test-decl-list-defines?
                (ast-decl-cons inner AstDeclNil)
                name)
                true
                (lower-test-decl-list-defines? rest name)))]
          [_ (lower-test-decl-list-defines? rest name)]))]))

(define (compiler-lower-ast-dce-program) : AstProgram
  (ast-program
    (ast-decl-cons
      (ast-decl-def
        "callback"
        AstNoType
        (ast-node-push (AstExprVar (intern "callback-target"))))
      (ast-decl-cons
        (ast-decl-def-fn
          "main"
          AstParamNil
          (AstTyI64)
          (ast-expr-call
            (ast-node-push (AstExprVar (intern "helper")))
            AstExprNil))
        (ast-decl-cons
          (ast-decl-def-fn
            "helper"
            AstParamNil
            (AstTyI64)
            (ast-node-push (AstExprLiteral (AstLitInt 7))))
          (ast-decl-cons
            (ast-decl-def-fn
              "callback-target"
              AstParamNil
              (AstTyI64)
              (ast-node-push (AstExprLiteral (AstLitInt 11))))
            (ast-decl-cons
              (ast-decl-def-fn
                "dead"
                AstParamNil
                (AstTyI64)
                (ast-node-push (AstExprLiteral (AstLitInt 9))))
              AstDeclNil)))))))

(define (compiler-lower-ast-dce-no-main-program) : AstProgram
  (ast-program
    (ast-decl-cons
      (ast-decl-def-fn
        "helper"
        AstParamNil
        (AstTyI64)
        (ast-node-push (AstExprLiteral (AstLitInt 7))))
      (ast-decl-cons
        (ast-decl-def-fn
          "dead"
          AstParamNil
          (AstTyI64)
          (ast-node-push (AstExprLiteral (AstLitInt 9))))
        AstDeclNil))))

(define (compiler-lower-unsafe-ast-dce-source) : String
  "(define (main) : i64 (unsafe (unsafe-entry)))
(define (unsafe-helper) : i64 41)
(unsafe (define (unsafe-entry) : i64 (unsafe-helper)))
(define (dead-helper) : i64 0)
(unsafe (define (dead-unsafe) : i64 (dead-helper)))")

(define (compiler-lower-ast-dce-ok?) : bool
  (let
    [program : AstProgram (compiler-lower-ast-dce-program)]
    [no-main-program : AstProgram (compiler-lower-ast-dce-no-main-program)]
    [names : LowerNameEnv
      (match program
        [(AstProgram decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            (lower-name-env-from-decls
              decls
              AstDeclPathNil
              "entry.tl"
              LowerNameNil))])]
    [no-main-names : LowerNameEnv
      (match no-main-program
        [(AstProgram decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            (lower-name-env-from-decls
              decls
              AstDeclPathNil
              "entry.tl"
              LowerNameNil))])]
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
              [(AstProgram kept-box)
                (let
                  [kept : AstDeclList (box-get kept-box)]
                  (match kept-no-main
                    [(AstProgram no-main-kept-box)
                      (let
                        [no-main-kept : AstDeclList (box-get no-main-kept-box)]
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
                                  (not
                                    (lower-test-decl-list-defines? kept "dead"))
                                  (=
                                    (lower-test-decl-list-count no-main-kept)
                                    2)))))))]))])])])))

(define (compiler-lower-unsafe-ast-dce-kept-ok? [kept : AstDeclList]) : bool
  (and
    (= (lower-test-decl-list-count kept) 3)
    (and
      (lower-test-decl-list-defines? kept "main")
      (and
        (lower-test-decl-list-defines? kept "unsafe-helper")
        (and
          (lower-test-decl-list-defines? kept "unsafe-entry")
          (and
            (not (lower-test-decl-list-defines? kept "dead-helper"))
            (not (lower-test-decl-list-defines? kept "dead-unsafe"))))))))

(define (compiler-lower-unsafe-ast-dce-ok?) : bool
  (match (parse-ast-source (compiler-lower-unsafe-ast-dce-source))
    [(OkAstProgram program)
      (match program
        [(AstProgram decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            [names : LowerNameEnv
              (lower-name-env-from-decls
                decls
                AstDeclPathNil
                "entry.tl"
                LowerNameNil)]
            [pruned : LowerPrunedProgram
              (lower-prune-unreachable-functions
                "entry.tl"
                program
                AstDeclPathNil
                names)]
            (match pruned
              [(LowerPrunedProgram kept-program _)
                (match kept-program
                  [(AstProgram kept-box)
                    (compiler-lower-unsafe-ast-dce-kept-ok? (box-get kept-box))])]))])]
    [(ErrAstProgram _) false]))

(define (compiler-lower-boxed-helper-lists-ok?) : bool
  (let
    [names : LowerNameEnv
      (LowerNameBind
        "source-a"
        "logical-a"
        (box (LowerNameBind "source-b" "logical-b" (box LowerNameNil))))]
    [strings : LowerStringSet
      (lower-string-set-insert
        (lower-string-set-insert LowerStringNil "helper-a")
        "helper-b")]
    [captures : LowerCaptureList
      (LowerCaptureCons
        (LowerCapture "cap-a" 1 (AstTyI64) 0)
        (box
          (LowerCaptureCons
            (LowerCapture "cap-b" 2 (AstTyBool) 8)
            (box LowerCaptureNil))))]
    [cleanups : LowerCleanupList
      (LowerCleanupCons
        (LowerCleanup "hidden-a" "cleanup-a")
        (box
          (LowerCleanupCons
            (LowerCleanup "hidden-b" "cleanup-b")
            (box LowerCleanupNil))))]
    (and
      (= (lower-name-env-count names) 2)
      (and
        (string-eq (lower-name-env-resolve names "source-b") "logical-b")
        (and
          (lower-string-set-contains? strings "helper-a")
          (and
            (lower-string-set-contains? strings "helper-b")
            (and
              (= (lower-capture-list-count captures) 2)
              (and
                (lower-capture-list-contains-name? captures "cap-b")
                (= (lower-cleanup-list-count cleanups) 2)))))))))

(define (compiler-lower-back-half-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-lower-boxed-helper-lists-ok?)
        unit
        (set! ok false))
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
      (if (compiler-lower-ok? (compiler-lower-fixed-array-return-source))
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
      (if (compiler-lower-reference-nominal-aggregate-ok?)
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
      (if (compiler-lower-error-ok?
        (compiler-lower-duplicate-function-source)
        "symbols: duplicate value declaration dup")
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
      (if (compiler-lower-unsafe-ast-dce-ok?)
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