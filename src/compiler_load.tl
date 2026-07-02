;; compiler_load.tl - Shared selfhost compiler source/import loader.
(import stdlib.arena)
(import stdlib.io)
(import "compiler_parse_core.tl")
(import "compiler_diagnostic.tl")
(import sym_i64_env)
(import stdlib.env)
(import stdlib.fs)
(import stdlib.hashmap)
(import stdlib.vector)
(import "compiler_embedded_stdlib.tl")
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import token)

(defenum ResultCompilerLoad
  (Ok AstDeclList sym_i64_env.SymI64Env)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCompilerLoadWithPaths
  (Ok AstDeclList AstDeclPathList AstDeclModuleList sym_i64_env.SymI64Env)
  (Err (Box CompilerDiagnostic)))

(defenum CompilerLoadMaybePath
  (CompilerLoadNoPath)
  (CompilerLoadSomePath String))

(defenum CompilerLoadMaybeString
  (CompilerLoadNoString)
  (CompilerLoadSomeString String))

(defenum ResultPkgResolve
  (Ok String)
  (Err String))

(defstruct CompilerLoadPackageEntry
  (entry-path String)
  (manifest-dir String)
  (owner String))

(defenum ResultCompilerLoadPackageEntry
  (Ok CompilerLoadPackageEntry)
  (Err String))

(defenum CompilerLoadMaybeModuleId
  (CompilerLoadNoModuleId)
  (CompilerLoadSomeModuleId String))

(defenum CompilerLoadMaybeDecl
  (CompilerLoadNoDecl)
  (CompilerLoadSomeDecl AstDecl))

(defenum ResultCompilerLoadInclude
  (Ok AstDecl)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCompilerLoadModuleId
  (Ok String)
  (Err (Box CompilerDiagnostic)))

(defenum ResultCompilerLoadAliasCheck
  (Ok)
  (Err (Box CompilerDiagnostic)))

(defenum CompilerLoadSurfaceMaybeString
  (CompilerLoadSurfaceNoString)
  (CompilerLoadSurfaceSomeString String))

(defenum CompilerLoadSurfaceImportKind
  (CompilerLoadSurfaceImportPath)
  (CompilerLoadSurfaceImportModule)
  (CompilerLoadSurfaceImportMacro)
  (CompilerLoadSurfaceImportMacroDecls))

(defstruct CompilerLoadSurfaceImport
  (kind CompilerLoadSurfaceImportKind)
  (source-path String)
  (import-path String)
  (module-name CompilerLoadSurfaceMaybeString)
  (alias CompilerLoadSurfaceMaybeString)
  (default-alias CompilerLoadSurfaceMaybeString)
  (span AstSourceSpan))

(defenum CompilerLoadSurfaceImportList
  (CompilerLoadSurfaceImportNil)
  (CompilerLoadSurfaceImportCons
    CompilerLoadSurfaceImport
    (Box CompilerLoadSurfaceImportList)))

(defenum CompilerLoadSurfaceMacroResultKind
  (CompilerLoadSurfaceMacroExpr)
  (CompilerLoadSurfaceMacroModule)
  (CompilerLoadSurfaceMacroDecls)
  (CompilerLoadSurfaceMacroOther))

(defenum CompilerLoadSurfaceDeclKind
  (CompilerLoadSurfaceValue)
  (CompilerLoadSurfaceFunction)
  (CompilerLoadSurfaceExtern)
  (CompilerLoadSurfaceStruct)
  (CompilerLoadSurfaceEnum)
  (CompilerLoadSurfaceMacro)
  (CompilerLoadSurfaceDispatch)
  (CompilerLoadSurfaceTest)
  (CompilerLoadSurfaceIncludeStr)
  (CompilerLoadSurfaceIncludeBin))

(defenum CompilerLoadSurfaceSignature
  (CompilerLoadSurfaceNoSignature)
  (CompilerLoadSurfaceValueSignature AstMaybeType)
  (CompilerLoadSurfaceFunctionSignature AstParamList AstType)
  (CompilerLoadSurfaceExternSignature AstExternKind AstExternMetadata AstType)
  (CompilerLoadSurfaceStructSignature
    AstLifetimeList
    AstStructRepr
    AstStructCleanup
    AstFieldDefList)
  (CompilerLoadSurfaceEnumSignature
    AstLifetimeList
    AstEnumCleanup
    AstVariantDefList)
  (CompilerLoadSurfaceMacroSignature AstMacroParamList AstType i64)
  (CompilerLoadSurfaceDispatchSignature AstDispatchVariantList))

(defstruct CompilerLoadSurfaceDecl
  (kind CompilerLoadSurfaceDeclKind)
  (name String)
  (module String)
  (signature CompilerLoadSurfaceSignature)
  (macro-result CompilerLoadSurfaceMacroResultKind)
  (has-cleanup bool)
  (has-export bool)
  (has-generated-meta bool)
  (was-unsafe bool)
  (span AstSourceSpan))

(defenum CompilerLoadSurfaceDeclList
  (CompilerLoadSurfaceDeclNil)
  (CompilerLoadSurfaceDeclCons
    CompilerLoadSurfaceDecl
    (Box CompilerLoadSurfaceDeclList)))

(defstruct CompilerLoadSurfaceBuild
  (imports CompilerLoadSurfaceImportList)
  (decls CompilerLoadSurfaceDeclList)
  (has-tests bool)
  (has-export-metadata bool)
  (has-generated-decls bool)
  (has-decl-emitting-macro bool))

(defstruct CompilerLoadSurfaceSummary
  (module-id String)
  (source-path String)
  (root-id String)
  (cfg-key String)
  (imports CompilerLoadSurfaceImportList)
  (decls CompilerLoadSurfaceDeclList)
  (has-tests bool)
  (has-export-metadata bool)
  (has-generated-decls bool)
  (has-decl-emitting-macro bool))

(defenum CompilerLoadSurfaceSummaryList
  (CompilerLoadSurfaceSummaryNil)
  (CompilerLoadSurfaceSummaryCons
    CompilerLoadSurfaceSummary
    (Box CompilerLoadSurfaceSummaryList)))

(defenum ResultCompilerLoadSurfaceSummary
  (Ok CompilerLoadSurfaceSummary)
  (Err (Box CompilerDiagnostic)))

(defenum CompilerLoadMaybeSurfaceSummary
  (CompilerLoadNoSurfaceSummary)
  (CompilerLoadSomeSurfaceSummary CompilerLoadSurfaceSummary))

(define compiler-load-active-surface-summaries : CompilerLoadSurfaceSummaryList
  (CompilerLoadSurfaceSummaryNil))
(define compiler-load-stdlib-array-surface-summary : CompilerLoadMaybeSurfaceSummary
  (CompilerLoadNoSurfaceSummary))
(define compiler-load-surface-summary-load-depth : i64
  0)
(define compiler-load-lazy-import-skip-record-count : i64
  0)

(defenum CompilerLoadPreludeCacheLookup
  (CompilerLoadPreludeCacheMiss)
  (CompilerLoadPreludeCacheHit
    AstDeclList
    AstDeclPathList
    AstDeclModuleList
    sym_i64_env.SymI64Env))

(defenum CompilerLoadPreludeCacheSlot
  (CompilerLoadPreludeCacheEmpty)
  (CompilerLoadPreludeCacheFull
    String
    AstDeclList
    AstDeclPathList
    AstDeclModuleList
    sym_i64_env.SymI64Env))

(defenum CompilerLoadProgramCacheLookup
  (CompilerLoadProgramCacheMiss)
  (CompilerLoadProgramCacheHit AstProgram))

(defenum CompilerLoadProgramCacheSlot
  (CompilerLoadProgramCacheEmpty)
  (CompilerLoadProgramCacheFull String AstProgram))

(defenum CompilerLoadProgramAdmissionSlot
  (CompilerLoadProgramAdmissionEmpty)
  (CompilerLoadProgramAdmissionFull String))

(define compiler-load-program-cache-capacity : i64
  256)
(define compiler-load-local-program-cache-node-limit : i64
  2048)
(define compiler-load-runtime-prelude-cache-capacity : i64
  16)
(define compiler-load-dotted-path-cache-capacity : i64
  256)

;; Loader cache data is owned by an explicit session state. The no-arg
;; compatibility helpers below operate on the active state pointer only.
(defstruct CompilerLoadSessionState
  (cache-enabled (Array bool))
  (program-cache-enabled (Array bool))
  (ast-floor (Array i64))
  (ty-floor (Array i64))
  (intern-floor (Array i64))
  (program-cache (Array CompilerLoadProgramCacheSlot))
  (program-admission (Array CompilerLoadProgramAdmissionSlot))
  (program-cache-ready (Array bool))
  (program-admission-ready (Array bool))
  (program-cache-hit-count (Array i64))
  (program-cache-miss-count (Array i64))
  (program-cache-store-count (Array i64))
  (runtime-prelude-cache (Array CompilerLoadPreludeCacheSlot))
  (runtime-prelude-cache-ready (Array bool))
  (dotted-path-cache-ready (Array bool))
  (dotted-path-cache-keys (Array i64))
  (dotted-path-cache-values (Array String))
  (dotted-path-cache-generation (Array i64)))

(define (compiler-load-session-state-bool-cell [value : bool]) : (Array bool)
  (let
    [cell : (Array bool) (make-array bool 1)]
    (begin
      (array-set! cell 0 value)
      cell)))

(define (compiler-load-session-state-i64-cell [value : i64]) : (Array i64)
  (let
    [cell : (Array i64) (make-array i64 1)]
    (begin
      (array-set! cell 0 value)
      cell)))

(define (compiler-load-session-state-bool-cell-get [cell : (Array bool)]) : bool
  (array-ref cell 0))

(define (compiler-load-session-state-bool-cell-set!
  [cell : (Array bool)]
  [value : bool]) : unit
  (array-set! cell 0 value))

(define (compiler-load-session-state-i64-cell-get [cell : (Array i64)]) : i64
  (array-ref cell 0))

(define (compiler-load-session-state-i64-cell-set!
  [cell : (Array i64)]
  [value : i64]) : unit
  (array-set! cell 0 value))

(define (compiler-load-session-state-new) : CompilerLoadSessionState
  (CompilerLoadSessionState
    (compiler-load-session-state-bool-cell false)
    (compiler-load-session-state-bool-cell true)
    (compiler-load-session-state-i64-cell 0)
    (compiler-load-session-state-i64-cell 0)
    (compiler-load-session-state-i64-cell 0)
    (make-array CompilerLoadProgramCacheSlot 256)
    (make-array CompilerLoadProgramAdmissionSlot 256)
    (compiler-load-session-state-bool-cell false)
    (compiler-load-session-state-bool-cell false)
    (compiler-load-session-state-i64-cell 0)
    (compiler-load-session-state-i64-cell 0)
    (compiler-load-session-state-i64-cell 0)
    (make-array CompilerLoadPreludeCacheSlot 16)
    (compiler-load-session-state-bool-cell false)
    (make-array bool compiler-load-dotted-path-cache-capacity)
    (make-array i64 compiler-load-dotted-path-cache-capacity)
    (make-array String compiler-load-dotted-path-cache-capacity)
    (compiler-load-session-state-i64-cell 0)))

(define compiler-load-active-session-state : CompilerLoadSessionState
  (compiler-load-session-state-new))

(define (compiler-load-session-state-cache-enabled?
  [state : CompilerLoadSessionState]) : bool
  (compiler-load-session-state-bool-cell-get (struct-get state cache-enabled)))

(define (compiler-load-session-state-cache-set-enabled!
  [state : CompilerLoadSessionState]
  [enabled : bool]) : unit
  (compiler-load-session-state-bool-cell-set!
    (struct-get state cache-enabled)
    enabled))

(define (compiler-load-session-state-cache-enable!
  [state : CompilerLoadSessionState]) : unit
  (compiler-load-session-state-cache-set-enabled! state true))

(define (compiler-load-session-state-program-cache-enabled?
  [state : CompilerLoadSessionState]) : bool
  (compiler-load-session-state-bool-cell-get
    (struct-get state program-cache-enabled)))

(define (compiler-load-session-state-program-cache-set-enabled-cell!
  [state : CompilerLoadSessionState]
  [enabled : bool]) : unit
  (compiler-load-session-state-bool-cell-set!
    (struct-get state program-cache-enabled)
    enabled))

(define (compiler-load-program-cache-fill! [index : i64]) : unit
  (if (>= index compiler-load-program-cache-capacity)
    unit
    (begin
      (array-set!
        (struct-get compiler-load-active-session-state program-cache)
        index
        (CompilerLoadProgramCacheEmpty))
      (compiler-load-program-cache-fill! (+ index 1)))))

(define (compiler-load-program-cache-stats-reset!) : unit
  (begin
    (array-set!
      (struct-get compiler-load-active-session-state program-cache-hit-count)
      0
      0)
    (array-set!
      (struct-get compiler-load-active-session-state program-cache-miss-count)
      0
      0)
    (array-set!
      (struct-get compiler-load-active-session-state program-cache-store-count)
      0
      0)))

(define (compiler-load-program-cache-clear!) : unit
  (begin
    (compiler-load-program-cache-fill! 0)
    (array-set!
      (struct-get compiler-load-active-session-state program-cache-ready)
      0
      true)
    (compiler-load-program-admission-clear!)
    (compiler-load-program-cache-stats-reset!)))

(define (compiler-load-program-cache-ensure!) : unit
  (if (array-ref
    (struct-get compiler-load-active-session-state program-cache-ready)
    0)
    unit
    (compiler-load-program-cache-clear!)))

(define (compiler-load-program-cache-note-hit!) : unit
  (array-set!
    (struct-get compiler-load-active-session-state program-cache-hit-count)
    0
    (+ (compiler-load-program-cache-hit-count-value) 1)))

(define (compiler-load-program-cache-note-miss!) : unit
  (array-set!
    (struct-get compiler-load-active-session-state program-cache-miss-count)
    0
    (+ (compiler-load-program-cache-miss-count-value) 1)))

(define (compiler-load-program-cache-note-store!) : unit
  (array-set!
    (struct-get compiler-load-active-session-state program-cache-store-count)
    0
    (+ (compiler-load-program-cache-store-count-value) 1)))

(define (compiler-load-program-cache-hit-count-value) : i64
  (array-ref
    (struct-get compiler-load-active-session-state program-cache-hit-count)
    0))

(define (compiler-load-program-cache-miss-count-value) : i64
  (array-ref
    (struct-get compiler-load-active-session-state program-cache-miss-count)
    0))

(define (compiler-load-program-cache-store-count-value) : i64
  (array-ref
    (struct-get compiler-load-active-session-state program-cache-store-count)
    0))

(define (compiler-load-program-cache-lookup-from [key : String] [index : i64]) : CompilerLoadProgramCacheLookup
  (if (>= index compiler-load-program-cache-capacity)
    (CompilerLoadProgramCacheMiss)
    (match (array-ref
      (struct-get compiler-load-active-session-state program-cache)
      index)
      [(CompilerLoadProgramCacheEmpty) (CompilerLoadProgramCacheMiss)]
      [(CompilerLoadProgramCacheFull slot-key program)
        (if (string.eq slot-key key)
          (CompilerLoadProgramCacheHit program)
          (compiler-load-program-cache-lookup-from key (+ index 1)))])))

(define (compiler-load-program-cache-lookup [key : String]) : CompilerLoadProgramCacheLookup
  (begin
    (compiler-load-program-cache-ensure!)
    (compiler-load-program-cache-lookup-from key 0)))

(define (compiler-load-program-cache-store-at
  [key : String]
  [program : AstProgram]
  [index : i64]) : bool
  (if (>= index compiler-load-program-cache-capacity)
    false
    (match (array-ref
      (struct-get compiler-load-active-session-state program-cache)
      index)
      [(CompilerLoadProgramCacheEmpty)
        (begin
          (array-set!
            (struct-get compiler-load-active-session-state program-cache)
            index
            (CompilerLoadProgramCacheFull key program))
          (compiler-load-program-cache-note-store!)
          true)]
      [(CompilerLoadProgramCacheFull slot-key _)
        (if (string.eq slot-key key)
          (begin
            (array-set!
              (struct-get compiler-load-active-session-state program-cache)
              index
              (CompilerLoadProgramCacheFull key program))
            (compiler-load-program-cache-note-store!)
            true)
          (compiler-load-program-cache-store-at key program (+ index 1)))])))

(define (compiler-load-program-cache-store
  [key : String]
  [program : AstProgram]) : bool
  (begin
    (compiler-load-program-cache-ensure!)
    (compiler-load-program-cache-store-at key program 0)))

(define (compiler-load-program-cache-can-store-at [key : String] [index : i64]) : bool
  (if (>= index compiler-load-program-cache-capacity)
    false
    (match (array-ref
      (struct-get compiler-load-active-session-state program-cache)
      index)
      [(CompilerLoadProgramCacheEmpty) true]
      [(CompilerLoadProgramCacheFull slot-key _)
        (if (string.eq slot-key key)
          true
          (compiler-load-program-cache-can-store-at key (+ index 1)))])))

(define (compiler-load-program-cache-can-store [key : String]) : bool
  (begin
    (compiler-load-program-cache-ensure!)
    (compiler-load-program-cache-can-store-at key 0)))

(define (compiler-load-program-admission-fill! [index : i64]) : unit
  (if (>= index compiler-load-program-cache-capacity)
    unit
    (begin
      (array-set!
        (struct-get compiler-load-active-session-state program-admission)
        index
        (CompilerLoadProgramAdmissionEmpty))
      (compiler-load-program-admission-fill! (+ index 1)))))

(define (compiler-load-program-admission-clear!) : unit
  (begin
    (compiler-load-program-admission-fill! 0)
    (array-set!
      (struct-get compiler-load-active-session-state program-admission-ready)
      0
      true)))

(define (compiler-load-program-admission-ensure!) : unit
  (if (array-ref
    (struct-get compiler-load-active-session-state program-admission-ready)
    0)
    unit
    (compiler-load-program-admission-clear!)))

(define (compiler-load-program-admission-contains-from?
  [key : String]
  [index : i64]) : bool
  (if (>= index compiler-load-program-cache-capacity)
    false
    (match (array-ref
      (struct-get compiler-load-active-session-state program-admission)
      index)
      [(CompilerLoadProgramAdmissionEmpty) false]
      [(CompilerLoadProgramAdmissionFull slot-key)
        (if (string.eq slot-key key)
          true
          (compiler-load-program-admission-contains-from? key (+ index 1)))])))

(define (compiler-load-program-admission-contains? [key : String]) : bool
  (begin
    (compiler-load-program-admission-ensure!)
    (compiler-load-program-admission-contains-from? key 0)))

(define (compiler-load-program-admission-record-at [key : String] [index : i64]) : bool
  (if (>= index compiler-load-program-cache-capacity)
    false
    (match (array-ref
      (struct-get compiler-load-active-session-state program-admission)
      index)
      [(CompilerLoadProgramAdmissionEmpty)
        (begin
          (array-set!
            (struct-get compiler-load-active-session-state program-admission)
            index
            (CompilerLoadProgramAdmissionFull key))
          true)]
      [(CompilerLoadProgramAdmissionFull slot-key)
        (if (string.eq slot-key key)
          true
          (compiler-load-program-admission-record-at key (+ index 1)))])))

(define (compiler-load-program-admission-record [key : String]) : bool
  (begin
    (compiler-load-program-admission-ensure!)
    (compiler-load-program-admission-record-at key 0)))

(define (compiler-load-program-admission-record-persistent [key : String]) : bool
  (if (compiler-load-program-admission-contains? key)
    true
    (let
      [prev-arena : i64 (arena.tl_arena_current)]
      [recorded : bool
        (begin
          (unsafe
            (arena.tl_arena_set node-pool-base-arena))
          (let
            [persistent-key : String (string.copy (& key))]
            (begin
              (unsafe
                (arena.tl_arena_set prev-arena))
              (compiler-load-program-admission-record persistent-key))))]
      recorded)))

(define (compiler-load-session-note-persistent!) : unit
  (let
    [old-intern-floor : i64 (compiler-load-session-intern-floor-value)]
    [new-intern-floor : i64 (intern-pool-len)]
    (begin
      (if (> (ast-node-pool-len) (compiler-load-session-ast-floor-value))
        (array-set!
          (struct-get compiler-load-active-session-state ast-floor)
          0
          (ast-node-pool-len))
        unit)
      (if (> (ty-node-pool-len) (compiler-load-session-ty-floor-value))
        (array-set!
          (struct-get compiler-load-active-session-state ty-floor)
          0
          (ty-node-pool-len))
        unit)
      (if (> new-intern-floor old-intern-floor)
        (begin
          (intern-persist-range! old-intern-floor new-intern-floor)
          (intern-persistent-arena-floor-refresh!)
          (array-set!
            (struct-get compiler-load-active-session-state intern-floor)
            0
            new-intern-floor))
        unit))))

(define (compiler-load-session-note-persistent-with-pools!
  [pools : AstNodePoolContext]) : unit
  (let
    [old-intern-floor : i64 (compiler-load-session-intern-floor-value)]
    [new-intern-floor : i64 (intern-pool-len)]
    (begin
      (if (>
        (ast-node-pool-context-expr-len pools)
        (compiler-load-session-ast-floor-value))
        (array-set!
          (struct-get compiler-load-active-session-state ast-floor)
          0
          (ast-node-pool-context-expr-len pools))
        unit)
      (if (>
        (ast-node-pool-context-type-len pools)
        (compiler-load-session-ty-floor-value))
        (array-set!
          (struct-get compiler-load-active-session-state ty-floor)
          0
          (ast-node-pool-context-type-len pools))
        unit)
      (if (> new-intern-floor old-intern-floor)
        (begin
          (intern-persist-range! old-intern-floor new-intern-floor)
          (intern-persistent-arena-floor-refresh!)
          (array-set!
            (struct-get compiler-load-active-session-state intern-floor)
            0
            new-intern-floor))
        unit))))

(define (compiler-load-session-ast-floor-value) : i64
  (array-ref (struct-get compiler-load-active-session-state ast-floor) 0))

(define (compiler-load-session-ty-floor-value) : i64
  (array-ref (struct-get compiler-load-active-session-state ty-floor) 0))

(define (compiler-load-session-intern-floor-value) : i64
  (array-ref (struct-get compiler-load-active-session-state intern-floor) 0))

(define (compiler-load-session-floors-set!
  [ast-floor : i64]
  [ty-floor : i64]
  [intern-floor : i64]) : unit
  (begin
    (array-set!
      (struct-get compiler-load-active-session-state ast-floor)
      0
      ast-floor)
    (array-set!
      (struct-get compiler-load-active-session-state ty-floor)
      0
      ty-floor)
    (array-set!
      (struct-get compiler-load-active-session-state intern-floor)
      0
      intern-floor)))

(define (compiler-load-session-state-use! [state : CompilerLoadSessionState]) : unit
  (begin
    (set! compiler-load-active-session-state state)
    (intern-persistent-storage-disable!)))

(define (compiler-load-session-cache-enable!) : unit
  (begin
    (array-set!
      (struct-get compiler-load-active-session-state cache-enabled)
      0
      true)
    (intern-persistent-storage-disable!)))

(define (compiler-load-session-cache-set-enabled! [enabled : bool]) : unit
  (if enabled
    (compiler-load-session-cache-enable!)
    (begin
      (array-set!
        (struct-get compiler-load-active-session-state cache-enabled)
        0
        false)
      (intern-persistent-storage-disable!))))

(define (compiler-load-session-program-cache-enable!) : unit
  (array-set!
    (struct-get compiler-load-active-session-state program-cache-enabled)
    0
    true))

(define (compiler-load-session-state-program-cache-disable!
  [state : CompilerLoadSessionState]) : unit
  (begin
    (compiler-load-session-state-program-cache-set-enabled-cell! state false)
    (array-set! (struct-get state program-cache-ready) 0 false)
    (array-set! (struct-get state program-admission-ready) 0 false)
    (array-set! (struct-get state program-cache-hit-count) 0 0)
    (array-set! (struct-get state program-cache-miss-count) 0 0)
    (array-set! (struct-get state program-cache-store-count) 0 0)
    (intern-persistent-storage-disable!)))

(define (compiler-load-session-program-cache-disable!) : unit
  (begin
    (array-set!
      (struct-get compiler-load-active-session-state program-cache-enabled)
      0
      false)
    (compiler-load-program-cache-clear!)
    (intern-persistent-storage-disable!)))

(define (compiler-load-session-state-program-cache-set-enabled!
  [state : CompilerLoadSessionState]
  [enabled : bool]) : unit
  (if enabled
    (compiler-load-session-state-program-cache-set-enabled-cell! state true)
    (compiler-load-session-state-program-cache-disable! state)))

(define (compiler-load-session-program-cache-set-enabled! [enabled : bool]) : unit
  (if enabled
    (compiler-load-session-program-cache-enable!)
    (compiler-load-session-program-cache-disable!)))

(define (compiler-load-session-program-cache-enabled?) : bool
  (array-ref
    (struct-get compiler-load-active-session-state program-cache-enabled)
    0))

(define (compiler-load-session-cache-disable-for-test!) : unit
  (begin
    (set! compiler-load-active-session-state (compiler-load-session-state-new))
    (array-set!
      (struct-get compiler-load-active-session-state cache-enabled)
      0
      false)
    (array-set!
      (struct-get compiler-load-active-session-state program-cache-enabled)
      0
      true)
    (compiler-load-session-floors-set! 0 0 0)
    (compiler-load-program-cache-clear!)
    (compiler-load-runtime-prelude-cache-clear!)
    (intern-persistent-storage-disable!)))

(define (compiler-load-session-cache-enabled?) : bool
  (array-ref (struct-get compiler-load-active-session-state cache-enabled) 0))

(define (compiler-load-session-reset-pools!) : unit
  (begin
    (compiler-load-surface-summaries-reset!)
    (set! compiler-load-surface-summary-load-depth 0)
    (if (compiler-load-session-cache-enabled?)
      (begin
        (ast-node-pool-reset-to! (compiler-load-session-ast-floor-value))
        (ty-node-pool-reset-to! (compiler-load-session-ty-floor-value)))
      (begin
        (ast-node-pool-reset!)
        (ty-node-pool-reset!)))))

(define (compiler-load-session-reset-pools-with-pools!
  [pools : AstNodePoolContext]) : unit
  (begin
    (compiler-load-surface-summaries-reset!)
    (set! compiler-load-surface-summary-load-depth 0)
    (if (compiler-load-session-cache-enabled?)
      (ast-node-pool-context-reset-to!
        pools
        (compiler-load-session-ast-floor-value)
        (compiler-load-session-ty-floor-value))
      (ast-node-pool-context-reset-to! pools 0 0))))

(define (compiler-load-session-reset-interns!) : unit
  (begin
    (compiler-load-surface-summaries-reset!)
    (set! compiler-load-surface-summary-load-depth 0)
    (if (compiler-load-session-cache-enabled?)
      (begin
        (intern-reset-to! (compiler-load-session-intern-floor-value))
        (intern-persistent-arena-reset-to-floor!))
      (intern-reset!))))

(define (compiler-load-runtime-prelude-cache-fill! [index : i64]) : unit
  (if (>= index compiler-load-runtime-prelude-cache-capacity)
    unit
    (begin
      (array-set!
        (struct-get compiler-load-active-session-state runtime-prelude-cache)
        index
        (CompilerLoadPreludeCacheEmpty))
      (compiler-load-runtime-prelude-cache-fill! (+ index 1)))))

(define (compiler-load-runtime-prelude-cache-clear!) : unit
  (begin
    (compiler-load-runtime-prelude-cache-fill! 0)
    (array-set!
      (struct-get
        compiler-load-active-session-state
        runtime-prelude-cache-ready)
      0
      true)))

(define (compiler-load-runtime-prelude-cache-ensure!) : unit
  (if (array-ref
    (struct-get compiler-load-active-session-state runtime-prelude-cache-ready)
    0)
    unit
    (compiler-load-runtime-prelude-cache-clear!)))

(define (compiler-load-runtime-prelude-cache-lookup-from
  [key : String]
  [index : i64]) : CompilerLoadPreludeCacheLookup
  (if (>= index compiler-load-runtime-prelude-cache-capacity)
    (CompilerLoadPreludeCacheMiss)
    (match (array-ref
      (struct-get compiler-load-active-session-state runtime-prelude-cache)
      index)
      [(CompilerLoadPreludeCacheEmpty) (CompilerLoadPreludeCacheMiss)]
      [(CompilerLoadPreludeCacheFull slot-key decls paths modules seen)
        (if (string.eq slot-key key)
          (CompilerLoadPreludeCacheHit decls paths modules seen)
          (compiler-load-runtime-prelude-cache-lookup-from key (+ index 1)))])))

(define (compiler-load-runtime-prelude-cache-lookup [key : String]) : CompilerLoadPreludeCacheLookup
  (begin
    (compiler-load-runtime-prelude-cache-ensure!)
    (compiler-load-runtime-prelude-cache-lookup-from key 0)))

(define (compiler-load-runtime-prelude-cache-store-at
  [key : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [modules : AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]
  [index : i64]) : unit
  (if (>= index compiler-load-runtime-prelude-cache-capacity)
    unit
    (match (array-ref
      (struct-get compiler-load-active-session-state runtime-prelude-cache)
      index)
      [(CompilerLoadPreludeCacheEmpty)
        (array-set!
          (struct-get compiler-load-active-session-state runtime-prelude-cache)
          index
          (CompilerLoadPreludeCacheFull key decls paths modules seen))]
      [(CompilerLoadPreludeCacheFull slot-key _ _ _ _)
        (if (string.eq slot-key key)
          (array-set!
            (struct-get
              compiler-load-active-session-state
              runtime-prelude-cache)
            index
            (CompilerLoadPreludeCacheFull key decls paths modules seen))
          (compiler-load-runtime-prelude-cache-store-at
            key
            decls
            paths
            modules
            seen
            (+ index 1)))])))

(define (compiler-load-runtime-prelude-cache-store
  [key : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [modules : AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]) : unit
  (begin
    (compiler-load-runtime-prelude-cache-ensure!)
    (compiler-load-runtime-prelude-cache-store-at
      key
      decls
      paths
      modules
      seen
      0)
    (compiler-load-session-note-persistent!)))

(define (compiler-load-runtime-prelude-cache-store-with-pools
  [key : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [modules : AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : unit
  (begin
    (compiler-load-runtime-prelude-cache-ensure!)
    (compiler-load-runtime-prelude-cache-store-at
      key
      decls
      paths
      modules
      seen
      0)
    (compiler-load-session-note-persistent-with-pools! pools)))

(define (compiler-load-roots-cache-key-from
  [roots : vector.StringVec]
  [index : i64]
  [count : i64]
  [out : String]) : String
  (if (>= index count)
    out
    (let
      [root : String (vector.string-vec-get roots index "")]
      (compiler-load-roots-cache-key-from
        roots
        (+ index 1)
        count
        (str_cat.str-cat
          out
          (string.int->string (string.string-length root))
          ":"
          root
          ";")))))

(define (compiler-load-roots-cache-key [roots : vector.StringVec]) : String
  (compiler-load-roots-cache-key-from roots 0 (vector.string-vec-len roots) ""))

(define (compiler-load-cfg-cache-key-from
  [cfgs : sym_i64_env.SymI64Env]
  [out : String]) : String
  (match cfgs
    [(sym_i64_env.SymI64Nil) out]
    [(sym_i64_env.SymI64Bind key value rest)
      (compiler-load-cfg-cache-key-from
        (box-get rest)
        (str_cat.str-cat
          out
          (intern-str key)
          "="
          (string.int->string value)
          ";"))]))

(define (compiler-load-cfg-cache-key [cfgs : sym_i64_env.SymI64Env]) : String
  (compiler-load-cfg-cache-key-from cfgs ""))

(define (compiler-load-prelude-cache-key
  [kind : String]
  [stdlib-roots : vector.StringVec]
  [cfgs : sym_i64_env.SymI64Env]) : String
  (let
    [effective-roots : vector.StringVec
      (compiler-load-roots-with-env stdlib-roots)]
    (str_cat.str-cat
      kind
      "|roots:"
      (compiler-load-roots-cache-key effective-roots)
      "|cfg:"
      (compiler-load-cfg-cache-key cfgs))))

(define (compiler-load-program-cache-key
  [kind : String]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]) : String
  (let
    [normalized : String (compiler-load-normalize-path path)]
    (str_cat.str-cat
      "program|"
      kind
      ":"
      (string.int->string (string.string-length normalized))
      ":"
      normalized
      "|cfg:"
      (compiler-load-cfg-cache-key cfgs))))

(define (compiler-load-char-code-at [text : String] [idx : i64]) : i64
  (cast (string.string-ref text idx) : i64))

(define (compiler-load-path-separator? [c : char]) : bool
  (fs.path-separator? c))

(define (compiler-load-absolute-path? [path : String]) : bool
  (fs.path-absolute? (& path)))

(define (compiler-load-dirname [path : String]) : String
  (let
    [n : i64 (string.string-length path)]
    [i : i64 0]
    [last : i64 -1]
    (begin
      (while (< i n)
        (begin
          (if (compiler-load-path-separator? (string.string-ref path i))
            (set! last i)
            (set! last last))
          (set! i (+ i 1))))
      (if (< last 0)
        ""
        (string.substring path 0 (+ last 1))))))

(define (compiler-load-join-import-path
  [importer-path : String]
  [import-path : String]) : String
  (if (compiler-load-absolute-path? import-path)
    import-path
    (string.append (compiler-load-dirname importer-path) import-path)))

(define (compiler-load-normalize-path [path : String]) : String
  (fs.path-normalize (& path)))

(define (compiler-load-safe-relative? [path : String]) : bool
  (fs.path-safe-relative? (& path)))

(define (compiler-load-string-prefix-at?
  [text : String]
  [prefix : String]
  [start : i64]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [prefix-len : i64 (string.string-length prefix)]
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
                  (compiler-load-char-code-at text (+ start i))
                  (compiler-load-char-code-at prefix i))
                  (set! i (+ i 1))
                  (set! ok false))
                (set! ok false)))
            (= i prefix-len)))))))

(define (compiler-load-string-eq? [left : String] [right : String]) : bool
  (and
    (= (string.string-length left) (string.string-length right))
    (compiler-load-string-prefix-at? left right 0)))

(define (compiler-load-string-contains-from?
  [text : String]
  [needle : String]
  [start : i64]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [needle-len : i64 (string.string-length needle)]
    [i : i64 start]
    [found : bool false]
    (begin
      (while (and (not found) (<= (+ i needle-len) text-len))
        (if (compiler-load-string-prefix-at? text needle i)
          (set! found true)
          (set! i (+ i 1))))
      found)))

(define (compiler-load-string-contains? [text : String] [needle : String]) : bool
  (compiler-load-string-contains-from? text needle 0))

(define (compiler-load-symbol-char? [c : char]) : bool
  (let
    [code : i64 (cast c : i64)]
    (cond
      [(and (>= code 97) (<= code 122)) true]
      [(and (>= code 65) (<= code 90)) true]
      [(and (>= code 48) (<= code 57)) true]
      [(= code 45) true]
      [(= code 95) true]
      [(= code 33) true]
      [(and (>= code 37) (<= code 38)) true]
      [(= code 42) true]
      [(= code 43) true]
      [(= code 46) true]
      [(= code 47) true]
      [(= code 58) true]
      [(and (>= code 60) (<= code 63)) true]
      [else false])))

(define (compiler-load-source-index-at-line-col
  [source : String]
  [line : i64]
  [col : i64]) : i64
  (let
    [n : i64 (string.string-length source)]
    [idx : i64 0]
    [cur-line : i64 1]
    [cur-col : i64 1]
    (begin
      (while (and
        (< idx n)
        (or (< cur-line line) (and (= cur-line line) (< cur-col col))))
        (let
          [c : char (string.string-ref source idx)]
          (begin
            (if (= c '\n')
              (begin
                (set! cur-line (+ cur-line 1))
                (set! cur-col 1))
              (set! cur-col (+ cur-col 1)))
            (set! idx (+ idx 1)))))
      idx)))

(define (compiler-load-source-scan-start
  [span : AstSourceSpan]
  [source : String]) : i64
  (compiler-load-source-index-at-line-col
    source
    (struct-get span end-line)
    (struct-get span end-col)))

(define (compiler-load-source-name-before-ok? [source : String] [idx : i64]) : bool
  (or
    (<= idx 0)
    (not (compiler-load-symbol-char? (string.string-ref source (- idx 1))))))

(define (compiler-load-source-name-after-ok? [source : String] [end : i64]) : bool
  (or
    (>= end (string.string-length source))
    (not (compiler-load-symbol-char? (string.string-ref source end)))))

(define (compiler-load-source-name-token-at?
  [source : String]
  [name : String]
  [idx : i64]) : bool
  (let
    [end : i64 (+ idx (string.string-length name))]
    (and
      (compiler-load-source-name-before-ok? source idx)
      (compiler-load-string-prefix-at? source name idx)
      (compiler-load-source-name-after-ok? source end))))

(define (compiler-load-source-has-name-token-from?
  [source : String]
  [name : String]
  [start : i64]) : bool
  (let
    [n : i64 (string.string-length source)]
    [name-len : i64 (string.string-length name)]
    (if (= name-len 0)
      false
      (let
        [name-first : char (string.string-ref name 0)]
        [idx : i64 start]
        [found : bool false]
        (begin
          (while (and (not found) (<= (+ idx name-len) n))
            (if (and
              (= (string.string-ref source idx) name-first)
              (compiler-load-source-name-token-at? source name idx))
              (set! found true)
              (set! idx (+ idx 1))))
          found)))))

(define (compiler-load-source-alias-after-ok? [source : String] [end : i64]) : bool
  (if (>= end (string.string-length source))
    true
    (let
      [c : char (string.string-ref source end)]
      (or (= c '.') (= c '/') (not (compiler-load-symbol-char? c))))))

(define (compiler-load-source-alias-token-at?
  [source : String]
  [alias : String]
  [idx : i64]) : bool
  (let
    [end : i64 (+ idx (string.string-length alias))]
    (and
      (compiler-load-source-name-before-ok? source idx)
      (compiler-load-string-prefix-at? source alias idx)
      (compiler-load-source-alias-after-ok? source end))))

(define (compiler-load-source-bare-alias-before-ok?
  [source : String]
  [idx : i64]) : bool
  (if (<= idx 0)
    true
    (let
      [prev : char (string.string-ref source (- idx 1))]
      (and
        (not (= prev '.'))
        (not (= prev '/'))
        (not (compiler-load-symbol-char? prev))))))

(define (compiler-load-source-bare-alias-token-at?
  [source : String]
  [alias : String]
  [idx : i64]) : bool
  (let
    [end : i64 (+ idx (string.string-length alias))]
    (and
      (compiler-load-source-bare-alias-before-ok? source idx)
      (compiler-load-string-prefix-at? source alias idx)
      (compiler-load-source-alias-after-ok? source end))))

(define (compiler-load-source-has-alias-token-from?
  [source : String]
  [alias : String]
  [start : i64]) : bool
  (let
    [n : i64 (string.string-length source)]
    [alias-len : i64 (string.string-length alias)]
    (if (= alias-len 0)
      false
      (let
        [alias-first : char (string.string-ref alias 0)]
        [idx : i64 start]
        [found : bool false]
        (begin
          (while (and (not found) (<= (+ idx alias-len) n))
            (if (and
              (= (string.string-ref source idx) alias-first)
              (compiler-load-source-alias-token-at? source alias idx))
              (set! found true)
              (set! idx (+ idx 1))))
          found)))))

(define (compiler-load-source-has-bare-alias-token-from?
  [source : String]
  [alias : String]
  [start : i64]) : bool
  (let
    [n : i64 (string.string-length source)]
    [alias-len : i64 (string.string-length alias)]
    (if (= alias-len 0)
      false
      (let
        [alias-first : char (string.string-ref alias 0)]
        [idx : i64 start]
        [found : bool false]
        (begin
          (while (and (not found) (<= (+ idx alias-len) n))
            (if (and
              (= (string.string-ref source idx) alias-first)
              (compiler-load-source-bare-alias-token-at? source alias idx))
              (set! found true)
              (set! idx (+ idx 1))))
          found)))))

(define (compiler-load-source-for-lazy-scan [path : String]) : CompilerLoadMaybeString
  (if (io.file-exists? path)
    (CompilerLoadSomeString (io.read-file path))
    (match (compiler-load-embedded-stdlib-source-for-path path)
      [(CompilerEmbeddedStdlibSomeSource source)
        (CompilerLoadSomeString source)]
      [(CompilerEmbeddedStdlibNoSource) (CompilerLoadNoString)])))

(define (compiler-load-lazy-env-disabled? [name : String]) : bool
  (match (env.get (& name))
    [(env.EnvSomeString value)
      (or
        (string.eq value "0")
        (string.eq value "false")
        (string.eq value "off"))]
    [(env.EnvNoString) false]))

(define (compiler-load-lazy-imports-enabled?) : bool
  (not
    (or
      (compiler-load-lazy-env-disabled? "TYPELISP_LAZY_IMPORTS")
      (compiler-load-lazy-env-disabled? "TYPELISP_LAZY_DOTTED_IMPORTS"))))

(define (compiler-load-prelude-importer? [path : String]) : bool
  (let
    [normalized : String (compiler-load-normalize-path path)]
    (or
      (string.eq normalized (compiler-load-normalize-path "stdlib/runtime.tl"))
      (string.eq
        normalized
        (compiler-load-normalize-path compiler-load-core-macro-prelude-path)))))

(define (compiler-load-stdlib-import? [path : String]) : bool
  (compiler-load-string-prefix-at? path "stdlib/" 0))

(define (compiler-load-stdlib-suffix [path : String]) : String
  (string.substring path 7 (- (string.string-length path) 7)))

(define (compiler-load-join-root-path [root : String] [suffix : String]) : String
  (let
    [n : i64 (string.string-length root)]
    (if (= n 0)
      suffix
      (let
        [last : char (string.string-ref root (- n 1))]
        (if (compiler-load-path-separator? last)
          (string.append root suffix)
          (string.append root (string.append "/" suffix)))))))

(define (compiler-load-roots-with-env [roots : vector.StringVec]) : vector.StringVec
  (let
    [name : String "TYPELISP_STDLIB_ROOT"]
    (match (env.get (& name))
      [(env.EnvNoString) roots]
      [(env.EnvSomeString root)
        (if (= (string.string-length root) 0)
          roots
          (vector.string-vec-push roots root))])))

(define (compiler-load-cache-root-prefix [root : String]) : String
  (compiler-load-join-root-path (compiler-load-normalize-path root) ""))

(define (compiler-load-cache-path-under-root?
  [normalized-path : String]
  [root : String]) : bool
  (if (= (string.string-length root) 0)
    false
    (compiler-load-string-prefix-at?
      normalized-path
      (compiler-load-cache-root-prefix root)
      0)))

(define (compiler-load-path-under-roots-from?
  [normalized-path : String]
  [roots : vector.StringVec]
  [index : i64]
  [count : i64]) : bool
  (if (>= index count)
    false
    (if (compiler-load-cache-path-under-root?
      normalized-path
      (vector.string-vec-get roots index ""))
      true
      (compiler-load-path-under-roots-from?
        normalized-path
        roots
        (+ index 1)
        count))))

(define (compiler-load-session-file-cacheable?
  [path : String]
  [_stdlib-roots : vector.StringVec]) : bool
  ;; Entry files opt out before this helper. Resolved import files are safe to
  ;; cache by path + cfg, including local and package-owned modules.
  (> (string.string-length (compiler-load-normalize-path path)) 0))

(define (compiler-load-session-file-cache-immediate?
  [path : String]
  [stdlib-roots : vector.StringVec]) : bool
  (let
    [normalized : String (compiler-load-normalize-path path)]
    (if (compiler-load-stdlib-import? normalized)
      true
      (let
        [effective-roots : vector.StringVec
          (compiler-load-roots-with-env stdlib-roots)]
        (compiler-load-path-under-roots-from?
          normalized
          effective-roots
          0
          (vector.string-vec-len effective-roots))))))

(define (compiler-load-stdlib-private-path?
  [path : String]
  [stdlib-roots : vector.StringVec]) : bool
  (if (compiler-load-string-contains? path "vector")
    (let
      [normalized : String (compiler-load-normalize-path path)]
      [stdlib-path : String
        (if (compiler-load-stdlib-import? normalized)
          normalized
          (compiler-load-stdlib-owned-path-from-roots normalized stdlib-roots))]
      (string.eq stdlib-path "stdlib/vector.tl"))
    false))

(define (compiler-load-stdlib-private-module? [module : String]) : bool
  (string.eq module "stdlib.vector"))

(define (compiler-load-stdlib-comptime-path?
  [path : String]
  [stdlib-roots : vector.StringVec]) : bool
  (if (compiler-load-string-contains? path "comptime")
    (let
      [normalized : String (compiler-load-normalize-path path)]
      [stdlib-path : String
        (if (compiler-load-stdlib-import? normalized)
          normalized
          (compiler-load-stdlib-owned-path-from-roots normalized stdlib-roots))]
      (string.eq stdlib-path "stdlib/comptime.tl"))
    false))

(define (compiler-load-stdlib-comptime-module? [module : String]) : bool
  (string.eq module "stdlib.comptime"))

(define (compiler-load-stdlib-private-cfgs
  [path : String]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [private-cfgs : sym_i64_env.SymI64Env
      (if (compiler-cfg-private-dynamic-buffer-enabled? cfgs)
        cfgs
        (match expected-module
          [(AstMaybeModuleName.Some module)
            (if (compiler-load-stdlib-private-module? module)
              (compiler-cfg-enable-private-dynamic-buffer cfgs)
              cfgs)]
          [(AstMaybeModuleName.No)
            (if (compiler-load-stdlib-private-path? path stdlib-roots)
              (compiler-cfg-enable-private-dynamic-buffer cfgs)
              cfgs)]))]
    (match expected-module
      [(AstMaybeModuleName.Some module)
        (if (compiler-load-stdlib-comptime-module? module)
          (compiler-cfg-enable private-cfgs "feature-plain-comptime-well-known")
          private-cfgs)]
      [(AstMaybeModuleName.No)
        (if (compiler-load-stdlib-comptime-path? path stdlib-roots)
          (compiler-cfg-enable private-cfgs "feature-plain-comptime-well-known")
          private-cfgs)])))

(define (compiler-load-resolve-stdlib-root-raw
  [suffix : String]
  [roots : vector.StringVec]) : CompilerLoadMaybePath
  (if (compiler-load-safe-relative? suffix)
    (let
      [i : i64 0]
      [n : i64 (vector.string-vec-len roots)]
      [found : bool false]
      [found-path : String ""]
      (begin
        (while (and (not found) (< i n))
          (let
            [root : String (vector.string-vec-get roots i "")]
            [candidate : String (compiler-load-join-root-path root suffix)]
            (if (io.file-exists? candidate)
              (begin
                (set! found true)
                (set! found-path candidate))
              (set! i (+ i 1)))))
        (if found
          (CompilerLoadSomePath found-path)
          (CompilerLoadNoPath))))
    (CompilerLoadNoPath)))

(define (compiler-load-resolve-stdlib-root
  [suffix : String]
  [roots : vector.StringVec]) : CompilerLoadMaybePath
  (compiler-load-resolve-stdlib-root-raw
    suffix
    (compiler-load-roots-with-env roots)))

(define (compiler-load-embedded-stdlib-source [suffix : String]) : CompilerEmbeddedStdlibSource
  (if (compiler-load-safe-relative? suffix)
    (compiler-embedded-stdlib-lookup suffix)
    (CompilerEmbeddedStdlibNoSource)))

(define (compiler-load-embedded-stdlib-path [suffix : String]) : CompilerLoadMaybePath
  (match (compiler-load-embedded-stdlib-source suffix)
    [(CompilerEmbeddedStdlibSomeSource _)
      (CompilerLoadSomePath (string.append "stdlib/" suffix))]
    [(CompilerEmbeddedStdlibNoSource) (CompilerLoadNoPath)]))

(define (compiler-load-embedded-stdlib-source-for-path [path : String]) : CompilerEmbeddedStdlibSource
  (if (compiler-load-stdlib-import? path)
    (compiler-load-embedded-stdlib-source (compiler-load-stdlib-suffix path))
    (CompilerEmbeddedStdlibNoSource)))

(define (compiler-load-resolve-import
  [importer-path : String]
  [import-path : String]) : String
  (compiler-load-resolve-import-with-roots
    importer-path
    import-path
    (vector.string-vec-new)))

(define (compiler-load-resolve-import-with-roots
  [importer-path : String]
  [import-path : String]
  [stdlib-roots : vector.StringVec]) : String
  (match (compiler-load-resolve-import-result-with-roots
    importer-path
    import-path
    stdlib-roots)
    [(ResultPkgResolve.Ok resolved) resolved]
    [(ResultPkgResolve.Err _) import-path]))

(define (compiler-load-resolve-import-result-with-roots
  [importer-path : String]
  [import-path : String]
  [stdlib-roots : vector.StringVec]) : ResultPkgResolve
  (if (compiler-load-pkg-import? import-path)
    (compiler-load-resolve-pkg-import-from-disk importer-path import-path)
    (let
      [primary : String
        (compiler-load-join-import-path importer-path import-path)]
      [resolved : String
        (if (io.file-exists? primary)
          primary
          (if (compiler-load-stdlib-import? import-path)
            (let
              [suffix : String (compiler-load-stdlib-suffix import-path)]
              (match (compiler-load-resolve-stdlib-root suffix stdlib-roots)
                [(CompilerLoadSomePath root-path) root-path]
                [(CompilerLoadNoPath)
                  (if (io.file-exists? import-path)
                    import-path
                    (match (compiler-load-embedded-stdlib-path suffix)
                      [(CompilerLoadSomePath embedded-path) embedded-path]
                      [(CompilerLoadNoPath) primary]))]))
            primary))]
      (ResultPkgResolve.Ok resolved))))

(define (compiler-load-dotted-path-cache-clear-ready! [index : i64]) : unit
  (if (>= index compiler-load-dotted-path-cache-capacity)
    unit
    (begin
      (array-set!
        (struct-get compiler-load-active-session-state dotted-path-cache-ready)
        index
        false)
      (compiler-load-dotted-path-cache-clear-ready! (+ index 1)))))

(define (compiler-load-dotted-path-cache-reset!) : unit
  (begin
    (compiler-load-dotted-path-cache-clear-ready! 0)
    (array-set!
      (struct-get
        compiler-load-active-session-state
        dotted-path-cache-generation)
      0
      (intern-generation))))

(define (compiler-load-dotted-path-cache-ensure!) : unit
  (if (=
    (array-ref
      (struct-get
        compiler-load-active-session-state
        dotted-path-cache-generation)
      0)
    (intern-generation))
    unit
    (compiler-load-dotted-path-cache-reset!)))

(define (compiler-load-dotted-path-cache-bucket [module-id : i64]) : i64
  (bit-and module-id (- compiler-load-dotted-path-cache-capacity 1)))

(define (compiler-load-dotted-path-cache-lookup [module-id : i64]) : CompilerLoadMaybeString
  (let
    [bucket : i64 (compiler-load-dotted-path-cache-bucket module-id)]
    (if (if (array-ref
      (struct-get compiler-load-active-session-state dotted-path-cache-ready)
      bucket)
      (=
        (array-ref
          (struct-get compiler-load-active-session-state dotted-path-cache-keys)
          bucket)
        module-id)
      false)
      (CompilerLoadSomeString
        (array-ref
          (struct-get
            compiler-load-active-session-state
            dotted-path-cache-values)
          bucket))
      (CompilerLoadNoString))))

(define (compiler-load-dotted-path-cache-store!
  [module-id : i64]
  [path : String]) : unit
  (let
    [bucket : i64 (compiler-load-dotted-path-cache-bucket module-id)]
    (begin
      (array-set!
        (struct-get compiler-load-active-session-state dotted-path-cache-ready)
        bucket
        true)
      (array-set!
        (struct-get compiler-load-active-session-state dotted-path-cache-keys)
        bucket
        module-id)
      (array-set!
        (struct-get compiler-load-active-session-state dotted-path-cache-values)
        bucket
        path))))

(define (compiler-load-dotted-module-path-uncached [module-name : String]) : String
  (let
    [n : i64 (string.string-length module-name)]
    [i : i64 0]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (if (string.char-eq (string.string-ref module-name i) '.')
            (set! out (string.concat3 out "/" ""))
            (set!
              out
              (string.concat3 out (string.substring module-name i 1) "")))
          (set! i (+ i 1))))
      (string.concat3 out ".tl" ""))))

(define (compiler-load-dotted-module-path [module-name : String]) : String
  (begin
    (compiler-load-dotted-path-cache-ensure!)
    (let
      [module-id : i64 (intern module-name)]
      (match (compiler-load-dotted-path-cache-lookup module-id)
        [(CompilerLoadSomeString path) path]
        [(CompilerLoadNoString)
          (let
            [prev-arena : i64 (arena.tl_arena_current)]
            (begin
              (unsafe
                (arena.tl_arena_set node-pool-base-arena))
              (let
                [path : String
                  (compiler-load-dotted-module-path-uncached module-name)]
                (begin
                  (compiler-load-dotted-path-cache-store! module-id path)
                  (unsafe
                    (arena.tl_arena_set prev-arena))
                  path))))]))))

(define (compiler-load-dotted-module-first-len [module-name : String]) : i64
  (let
    [n : i64 (string.string-length module-name)]
    [i : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (if (string.char-eq (string.string-ref module-name i) '.')
          (set! done true)
          (set! i (+ i 1))))
      i)))

(define (compiler-load-dotted-module-first [module-name : String]) : String
  (string.substring
    module-name
    0
    (compiler-load-dotted-module-first-len module-name)))

(define (compiler-load-dotted-module-rest
  [module-name : String]
  [first-len : i64]) : String
  (let
    [n : i64 (string.string-length module-name)]
    [rest-start : i64 (+ first-len 1)]
    (if (>= rest-start n)
      ""
      (string.substring module-name rest-start (- n rest-start)))))

(define (compiler-load-resolve-stdlib-module-path
  [module-path : String]
  [stdlib-roots : vector.StringVec]) : String
  (let
    [suffix : String (compiler-load-stdlib-suffix module-path)]
    (match (compiler-load-resolve-stdlib-root suffix stdlib-roots)
      [(CompilerLoadSomePath root-path) root-path]
      [(CompilerLoadNoPath)
        (if (io.file-exists? module-path)
          module-path
          (match (compiler-load-embedded-stdlib-path suffix)
            [(CompilerLoadSomePath embedded-path) embedded-path]
            [(CompilerLoadNoPath) module-path]))])))

(define (compiler-load-resolve-root-module-path
  [module-path : String]
  [stdlib-roots : vector.StringVec]) : CompilerLoadMaybePath
  (compiler-load-resolve-stdlib-root-raw module-path stdlib-roots))

(define (compiler-load-nested-import-root? [root : String]) : bool
  (or
    (compiler-load-string-contains? root "/")
    (compiler-load-string-contains? root "\\")))

(define (compiler-load-resolve-module-import-with-roots
  [importer-path : String]
  [import-root : String]
  [module-name : String]
  [stdlib-roots : vector.StringVec]) : ResultPkgResolve
  (let
    [module-path : String (compiler-load-dotted-module-path module-name)]
    (if (compiler-load-stdlib-import? module-path)
      (ResultPkgResolve.Ok
        (compiler-load-resolve-stdlib-module-path module-path stdlib-roots))
      (let
        [root-primary : String
          (compiler-load-normalize-path
            (compiler-load-join-root-path import-root module-path))]
        (if (compiler-load-nested-import-root? import-root)
          (if (io.file-exists? root-primary)
            (ResultPkgResolve.Ok root-primary)
            (let
              [importer-dir : String (compiler-load-dirname importer-path)]
              [importer-primary : String
                (compiler-load-normalize-path
                  (compiler-load-join-root-path importer-dir module-path))]
              (if (and
                (not (string.eq importer-dir import-root))
                (compiler-load-nested-import-root? importer-dir)
                (io.file-exists? importer-primary))
                (ResultPkgResolve.Ok importer-primary)
                (match (compiler-load-resolve-root-module-path
                  module-path
                  stdlib-roots)
                  [(CompilerLoadSomePath root-path)
                    (ResultPkgResolve.Ok root-path)]
                  [(CompilerLoadNoPath) (ResultPkgResolve.Ok root-primary)]))))
          (match (compiler-load-resolve-root-module-path
            module-path
            stdlib-roots)
            [(CompilerLoadSomePath root-path) (ResultPkgResolve.Ok root-path)]
            [(CompilerLoadNoPath) (ResultPkgResolve.Ok root-primary)]))))))

(define (compiler-load-resolve-import-spec-with-roots
  [importer-path : String]
  [import-root : String]
  [kind : AstImportKind]
  [import-path : String]
  [stdlib-roots : vector.StringVec]) : ResultPkgResolve
  (match kind
    [(AstImportKind.Path)
      (compiler-load-resolve-import-result-with-roots
        importer-path
        import-path
        stdlib-roots)]
    [(AstImportKind.Module)
      (compiler-load-resolve-module-import-with-roots
        importer-path
        import-root
        import-path
        stdlib-roots)]
    [(AstImportKind.Macro _ _)
      (ResultPkgResolve.Err
        "compiler-load: module macro imports must be expanded before import resolution")]
    [(AstImportKind.MacroDecls _ _)
      (ResultPkgResolve.Err
        "compiler-load: module macro imports must be expanded before import resolution")]))

(define (compiler-load-resolve-package-module-import
  [module-name : String]
  [importer-path : String]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [stdlib-roots : vector.StringVec]) : ResultPkgResolve
  (let
    [first-len : i64 (compiler-load-dotted-module-first-len module-name)]
    [first : String (string.substring module-name 0 first-len)]
    [module-path : String (compiler-load-dotted-module-path module-name)]
    (if (compiler-load-stdlib-import? module-path)
      (ResultPkgResolve.Ok
        (compiler-load-resolve-stdlib-module-path module-path stdlib-roots))
      (match (compiler-load-pkg-dep-lookup deps first)
        [(CompilerLoadNoPath)
          (let
            [importer-dir : String (compiler-load-dirname importer-path)]
            [primary : String
              (compiler-load-normalize-path
                (compiler-load-join-root-path importer-dir module-path))]
            [fallback : String
              (compiler-load-normalize-path
                (compiler-load-join-root-path manifest-dir module-path))]
            (if (and
              (compiler-load-nested-import-root? importer-dir)
              (io.file-exists? primary))
              (ResultPkgResolve.Ok primary)
              (ResultPkgResolve.Ok fallback)))]
        [(CompilerLoadSomePath dep-path)
          (let
            [rest : String
              (compiler-load-dotted-module-rest module-name first-len)]
            (if (= (string.string-length rest) 0)
              (ResultPkgResolve.Err
                (string.append
                  "compiler-load: dotted import missing module segment after package alias: "
                  module-name))
              (if (compiler-load-github-dependency-path? dep-path)
                (ResultPkgResolve.Err
                  (string.append
                    "compiler-load: GitHub dependency '"
                    (string.append
                      first
                      (string.append
                        "' requires fetch support (#1157): "
                        module-name))))
                (ResultPkgResolve.Ok
                  (compiler-load-normalize-path
                    (compiler-load-join-root-path
                      (compiler-load-join-root-path manifest-dir dep-path)
                      (compiler-load-dotted-module-path rest)))))))]))))

(define (compiler-load-resolve-package-import-spec
  [importer-path : String]
  [kind : AstImportKind]
  [import-path : String]
  [stdlib-roots : vector.StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultPkgResolve
  (match kind
    [(AstImportKind.Path)
      (if (compiler-load-pkg-import? import-path)
        (compiler-load-resolve-pkg-import import-path manifest-dir deps)
        (compiler-load-resolve-import-result-with-roots
          importer-path
          import-path
          stdlib-roots))]
    [(AstImportKind.Module)
      (compiler-load-resolve-package-module-import
        import-path
        importer-path
        manifest-dir
        deps
        stdlib-roots)]
    [(AstImportKind.Macro _ _)
      (ResultPkgResolve.Err
        "compiler-load: module macro imports must be expanded before import resolution")]
    [(AstImportKind.MacroDecls _ _)
      (ResultPkgResolve.Err
        "compiler-load: module macro imports must be expanded before import resolution")]))

(define (compiler-load-package-import-externs?
  [kind : AstImportKind]
  [import-path : String]
  [deps : CompilerPkgDeps]) : bool
  (match kind
    [(AstImportKind.Path) (compiler-load-pkg-import? import-path)]
    [(AstImportKind.Module)
      (let
        [module-path : String (compiler-load-dotted-module-path import-path)]
        [first : String (compiler-load-dotted-module-first import-path)]
        (if (compiler-load-stdlib-import? module-path)
          false
          (match (compiler-load-pkg-dep-lookup deps first)
            [(CompilerLoadSomePath _) true]
            [(CompilerLoadNoPath) false])))]
    [(AstImportKind.Macro _ _) false]
    [(AstImportKind.MacroDecls _ _) false]))

(define (compiler-load-macro-import-kind? [kind : AstImportKind]) : bool
  (match kind
    [(AstImportKind.Macro _ _) true]
    [(AstImportKind.MacroDecls _ _) true]
    [_ false]))

(define (compiler-load-include-str-def [name : String] [contents : String]) : AstDecl
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [decl : AstDecl
      (compiler-load-include-str-def-with-pools pools name contents)]
    (begin
      (ast-node-pool-context-install! pools)
      decl)))

(define (compiler-load-include-str-def-with-pools
  [pools : AstNodePoolContext]
  [name : String]
  [contents : String]) : AstDecl
  (ast-decl-def
    name
    (AstMaybeType.Some (AstType.String))
    (ast-node-pool-context-expr-push
      pools
      (AstExpr.Literal (AstLiteral.String contents)))))

(define (compiler-load-include-bin-def [name : String] [contents : String]) : AstDecl
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [decl : AstDecl
      (compiler-load-include-bin-def-with-pools pools name contents)]
    (begin
      (ast-node-pool-context-install! pools)
      decl)))

(define (compiler-load-include-bin-def-with-pools
  [pools : AstNodePoolContext]
  [name : String]
  [contents : String]) : AstDecl
  (ast-decl-def
    name
    (AstMaybeType.Some (ast-ty-dyn-array-with-pools pools (AstType.U8)))
    (ast-node-pool-context-expr-push pools (AstExpr.BinaryData contents))))

(define (compiler-load-include-str-read-error
  [importer-path : String]
  [include-path : String]
  [resolved : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start
    importer-path
    (string.append
      "compiler-load: cannot read include-str "
      (string.append
        include-path
        (string.append
          " from "
          (string.append
            importer-path
            (string.append " (resolved " (string.append resolved ")"))))))))

(define (compiler-load-include-str-from-resolved
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : String]) : ResultCompilerLoadInclude
  (if (io.file-exists? resolved)
    (ResultCompilerLoadInclude.Ok
      (compiler-load-include-str-def name (io.read-file resolved)))
    (match (compiler-load-embedded-stdlib-source-for-path resolved)
      [(CompilerEmbeddedStdlibSomeSource source)
        (ResultCompilerLoadInclude.Ok
          (compiler-load-include-str-def name source))]
      [(CompilerEmbeddedStdlibNoSource)
        (ResultCompilerLoadInclude.Err
          (box
            (compiler-load-include-str-read-error
              importer-path
              include-path
              resolved)))])))

(define (compiler-load-include-str-from-resolved-with-pools
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : String]
  [pools : AstNodePoolContext]) : ResultCompilerLoadInclude
  (if (io.file-exists? resolved)
    (ResultCompilerLoadInclude.Ok
      (compiler-load-include-str-def-with-pools
        pools
        name
        (io.read-file resolved)))
    (match (compiler-load-embedded-stdlib-source-for-path resolved)
      [(CompilerEmbeddedStdlibSomeSource source)
        (ResultCompilerLoadInclude.Ok
          (compiler-load-include-str-def-with-pools pools name source))]
      [(CompilerEmbeddedStdlibNoSource)
        (ResultCompilerLoadInclude.Err
          (box
            (compiler-load-include-str-read-error
              importer-path
              include-path
              resolved)))])))

(define (compiler-load-include-bin-read-error
  [importer-path : String]
  [include-path : String]
  [resolved : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start
    importer-path
    (str_cat.str-cat
      "compiler-load: cannot read include-bin "
      include-path
      " from "
      importer-path
      " (resolved "
      resolved
      ")")))

(define (compiler-load-include-bin-from-resolved
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : String]) : ResultCompilerLoadInclude
  (if (io.file-exists? resolved)
    (ResultCompilerLoadInclude.Ok
      (compiler-load-include-bin-def name (io.read-file resolved)))
    (match (compiler-load-embedded-stdlib-source-for-path resolved)
      [(CompilerEmbeddedStdlibSomeSource source)
        (ResultCompilerLoadInclude.Ok
          (compiler-load-include-bin-def name source))]
      [(CompilerEmbeddedStdlibNoSource)
        (ResultCompilerLoadInclude.Err
          (box
            (compiler-load-include-bin-read-error
              importer-path
              include-path
              resolved)))])))

(define (compiler-load-include-bin-from-resolved-with-pools
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : String]
  [pools : AstNodePoolContext]) : ResultCompilerLoadInclude
  (if (io.file-exists? resolved)
    (ResultCompilerLoadInclude.Ok
      (compiler-load-include-bin-def-with-pools
        pools
        name
        (io.read-file resolved)))
    (match (compiler-load-embedded-stdlib-source-for-path resolved)
      [(CompilerEmbeddedStdlibSomeSource source)
        (ResultCompilerLoadInclude.Ok
          (compiler-load-include-bin-def-with-pools pools name source))]
      [(CompilerEmbeddedStdlibNoSource)
        (ResultCompilerLoadInclude.Err
          (box
            (compiler-load-include-bin-read-error
              importer-path
              include-path
              resolved)))])))

(define (compiler-load-expand-include-str
  [importer-path : String]
  [include-path : String]
  [name : String]
  [stdlib-roots : vector.StringVec]) : ResultCompilerLoadInclude
  (match (compiler-load-resolve-import-result-with-roots
    importer-path
    include-path
    stdlib-roots)
    [(ResultPkgResolve.Ok resolved)
      (compiler-load-include-str-from-resolved
        importer-path
        include-path
        resolved
        name)]
    [(ResultPkgResolve.Err message)
      (ResultCompilerLoadInclude.Err
        (box (compiler-diagnostic-at-start importer-path message)))]))

(define (compiler-load-expand-include-str-with-pools
  [importer-path : String]
  [include-path : String]
  [name : String]
  [stdlib-roots : vector.StringVec]
  [pools : AstNodePoolContext]) : ResultCompilerLoadInclude
  (match (compiler-load-resolve-import-result-with-roots
    importer-path
    include-path
    stdlib-roots)
    [(ResultPkgResolve.Ok resolved)
      (compiler-load-include-str-from-resolved-with-pools
        importer-path
        include-path
        resolved
        name
        pools)]
    [(ResultPkgResolve.Err message)
      (ResultCompilerLoadInclude.Err
        (box (compiler-diagnostic-at-start importer-path message)))]))

(define (compiler-load-expand-include-bin
  [importer-path : String]
  [include-path : String]
  [name : String]
  [stdlib-roots : vector.StringVec]) : ResultCompilerLoadInclude
  (match (compiler-load-resolve-import-result-with-roots
    importer-path
    include-path
    stdlib-roots)
    [(ResultPkgResolve.Ok resolved)
      (compiler-load-include-bin-from-resolved
        importer-path
        include-path
        resolved
        name)]
    [(ResultPkgResolve.Err message)
      (ResultCompilerLoadInclude.Err
        (box (compiler-diagnostic-at-start importer-path message)))]))

(define (compiler-load-expand-include-bin-with-pools
  [importer-path : String]
  [include-path : String]
  [name : String]
  [stdlib-roots : vector.StringVec]
  [pools : AstNodePoolContext]) : ResultCompilerLoadInclude
  (match (compiler-load-resolve-import-result-with-roots
    importer-path
    include-path
    stdlib-roots)
    [(ResultPkgResolve.Ok resolved)
      (compiler-load-include-bin-from-resolved-with-pools
        importer-path
        include-path
        resolved
        name
        pools)]
    [(ResultPkgResolve.Err message)
      (ResultCompilerLoadInclude.Err
        (box (compiler-diagnostic-at-start importer-path message)))]))

(define (compiler-load-decl-list-append
  [left : AstDeclList]
  [right : AstDeclList]) : AstDeclList
  (let
    [out : AstDeclList
      (ast-decl-list-with-capacity
        (+ (ast-decl-list-len (& left)) (ast-decl-list-len (& right))))]
    (begin
      (ast-decl-list-append-from (&mut out) (& left) 0)
      (ast-decl-list-append-from (&mut out) (& right) 0)
      out)))

(define (compiler-load-decl-list-append-onto
  [left : AstDeclList]
  [right : AstDeclList]) : AstDeclList
  (let
    [out : AstDeclList
      (ast-decl-list-with-capacity
        (+ (ast-decl-list-len (& left)) (ast-decl-list-len (& right))))]
    (begin
      (ast-decl-list-append-from (&mut out) (& left) 0)
      (ast-decl-list-append-from (&mut out) (& right) 0)
      out)))

(define (compiler-load-decl-path-list-append
  [left : AstDeclPathList]
  [right : AstDeclPathList]) : AstDeclPathList
  (let
    [out : AstDeclPathList
      (ast-decl-path-list-with-capacity
        (+ (ast-decl-path-list-len (& left)) (ast-decl-path-list-len (& right))))]
    (begin
      (ast-decl-path-list-append-from (&mut out) (& left) 0)
      (ast-decl-path-list-append-from (&mut out) (& right) 0)
      out)))

(define (compiler-load-decl-path-list-append-onto
  [left : AstDeclPathList]
  [right : AstDeclPathList]) : AstDeclPathList
  (let
    [out : AstDeclPathList
      (ast-decl-path-list-with-capacity
        (+ (ast-decl-path-list-len (& left)) (ast-decl-path-list-len (& right))))]
    (begin
      (ast-decl-path-list-append-from (&mut out) (& left) 0)
      (ast-decl-path-list-append-from (&mut out) (& right) 0)
      out)))

(define (compiler-load-decl-module-list-append
  [left : AstDeclModuleList]
  [right : AstDeclModuleList]) : AstDeclModuleList
  (let
    [out : AstDeclModuleList
      (ast-decl-module-list-with-capacity
        (+
          (ast-decl-module-list-len (& left))
          (ast-decl-module-list-len (& right))))]
    (begin
      (ast-decl-module-list-append-from (&mut out) (& left) 0)
      (ast-decl-module-list-append-from (&mut out) (& right) 0)
      out)))

(define (compiler-load-decl-module-list-append-onto
  [left : AstDeclModuleList]
  [right : AstDeclModuleList]) : AstDeclModuleList
  (let
    [out : AstDeclModuleList
      (ast-decl-module-list-with-capacity
        (+
          (ast-decl-module-list-len (& left))
          (ast-decl-module-list-len (& right))))]
    (begin
      (ast-decl-module-list-append-from (&mut out) (& left) 0)
      (ast-decl-module-list-append-from (&mut out) (& right) 0)
      out)))

(define compiler-load-core-macro-prelude-path : String
  "stdlib/core_macros.tl")

;; `core_macros.tl` declares `(module stdlib.core_macros)`. Add a root module
;; marker after loading it so the following entry resumes in the root module,
;; matching import restoration and keeping module-less `main` discoverable.
(define (compiler-load-append-root-module-marker
  [loaded : ResultCompilerLoadWithPaths]) : ResultCompilerLoadWithPaths
  (match loaded
    [(ResultCompilerLoadWithPaths.Ok decls paths modules seen)
      (ResultCompilerLoadWithPaths.Ok
        (compiler-load-decl-list-append
          decls
          (ast-decl-cons (ast-decl-module "") (ast-decl-list-new)))
        (compiler-load-decl-path-list-append
          paths
          (ast-decl-path-cons
            compiler-load-core-macro-prelude-path
            (ast-decl-path-list-new)))
        (compiler-load-decl-module-list-append
          modules
          (ast-decl-module-cons "" (ast-decl-module-list-new)))
        seen)]
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-load-core-macro-prelude-with-roots-cfg
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-append-root-module-marker
    (compiler-load-file-with-paths-and-roots-cfg
      compiler-load-core-macro-prelude-path
      seen
      stdlib-roots
      cfgs)))

(define (compiler-load-core-macro-prelude-with-roots-cfg-with-pools
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-append-root-module-marker
    (compiler-load-file-with-paths-and-roots-cfg-with-pools
      compiler-load-core-macro-prelude-path
      seen
      stdlib-roots
      cfgs
      pools)))

(define (compiler-load-core-macro-prelude-with-roots
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]) : ResultCompilerLoadWithPaths
  (compiler-load-core-macro-prelude-with-roots-cfg
    seen
    stdlib-roots
    (compiler-cfg-empty)))

(define (compiler-load-drop-paths [result : ResultCompilerLoadWithPaths]) : ResultCompilerLoad
  (match result
    [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
      (ResultCompilerLoad.Ok decls seen)]
    [(ResultCompilerLoadWithPaths.Err diag) (ResultCompilerLoad.Err diag)]))

(define (compiler-load-decls-module-id-loop
  [path : String]
  [decls : AstDeclList]
  [fallback : String]
  [found : CompilerLoadMaybeModuleId]) : ResultCompilerLoadModuleId
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil)
      (match found
        [(CompilerLoadNoModuleId) (ResultCompilerLoadModuleId.Ok fallback)]
        [(CompilerLoadSomeModuleId name) (ResultCompilerLoadModuleId.Ok name)])]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.Module name)
            (match found
              [(CompilerLoadNoModuleId)
                (compiler-load-decls-module-id-loop
                  path
                  rest
                  fallback
                  (CompilerLoadSomeModuleId (intern-str name)))]
              [(CompilerLoadSomeModuleId _)
                (ResultCompilerLoadModuleId.Err
                  (box
                    (compiler-diagnostic-at-start
                      path
                      "compiler-load: duplicate module declaration")))])]
          [_ (compiler-load-decls-module-id-loop path rest fallback found)]))]))

(define (compiler-load-decls-module-id [path : String] [decls : AstDeclList]) : ResultCompilerLoadModuleId
  (compiler-load-decls-module-id-loop
    path
    decls
    (compiler-load-canonical-module-id-from-path path)
    CompilerLoadNoModuleId))

(define (compiler-load-decls-module-id-with-fallback
  [path : String]
  [decls : AstDeclList]
  [fallback : String]) : ResultCompilerLoadModuleId
  (compiler-load-decls-module-id-loop
    path
    decls
    fallback
    CompilerLoadNoModuleId))

(define (compiler-load-check-expected-module
  [path : String]
  [expected : AstMaybeModuleName]
  [actual : String]) : ResultCompilerLoadModuleId
  (match expected
    [(AstMaybeModuleName.No) (ResultCompilerLoadModuleId.Ok actual)]
    [(AstMaybeModuleName.Some want)
      (if (string.eq want actual)
        (ResultCompilerLoadModuleId.Ok actual)
        (ResultCompilerLoadModuleId.Err
          (box
            (compiler-diagnostic-at-start
              path
              (string.append
                "compiler-load: import expected module "
                (string.append want (string.append " but loaded " actual)))))))]))

(define (compiler-load-no-expected-module? [expected : AstMaybeModuleName]) : bool
  (match expected
    [(AstMaybeModuleName.No) true]
    [(AstMaybeModuleName.Some _) false]))

(define (compiler-load-seen-path-key [path : String]) : String
  (string.append "path:" (compiler-load-normalize-path path)))

(define (compiler-load-strip-tl-extension [path : String]) : String
  (let
    [n : i64 (string.string-length path)]
    (if (and (>= n 3) (string.eq (string.substring path (- n 3) 3) ".tl"))
      (string.substring path 0 (- n 3))
      path)))

(define (compiler-load-module-id-from-path-text [path : String]) : String
  (let
    [normalized : String
      (compiler-load-strip-tl-extension (compiler-load-normalize-path path))]
    [n : i64 (string.string-length normalized)]
    [i : i64 0]
    [out : String ""]
    (begin
      (while (< i n)
        (let
          [c : char (string.string-ref normalized i)]
          (begin
            (if (compiler-load-path-separator? c)
              (set! out (string.concat3 out "." ""))
              (set!
                out
                (string.concat3 out (string.substring normalized i 1) "")))
            (set! i (+ i 1)))))
      out)))

(define (compiler-load-canonical-module-id-from-path [path : String]) : String
  (compiler-load-module-id-from-path-text path))

(define (compiler-load-canonical-module-id-from-pkg-import
  [import-path : String]) : String
  (if (compiler-load-pkg-import? import-path)
    (compiler-load-module-id-from-path-text
      (string.substring import-path 4 (- (string.string-length import-path) 4)))
    (compiler-load-module-id-from-path-text import-path)))

(define (compiler-load-canonical-module-id-from-import
  [kind : AstImportKind]
  [import-path : String]
  [resolved-path : String]) : String
  (match kind
    [(AstImportKind.Module) import-path]
    [(AstImportKind.Path)
      (let
        [normalized-import : String (compiler-load-normalize-path import-path)]
        (if (compiler-load-pkg-import? import-path)
          (compiler-load-canonical-module-id-from-pkg-import import-path)
          (if (compiler-load-stdlib-import? normalized-import)
            (compiler-load-canonical-module-id-from-path normalized-import)
            (compiler-load-canonical-module-id-from-path resolved-path))))]
    [_ (compiler-load-canonical-module-id-from-path resolved-path)]))

(define (compiler-load-canonical-source-module-from-import
  [kind : AstImportKind]
  [import-path : String]
  [resolved-path : String]
  [expected-module : AstMaybeModuleName]
  [context-module : String]) : String
  (let
    [fallback : String
      (compiler-load-canonical-module-id-from-import
        kind
        import-path
        resolved-path)]
    (match kind
      [(AstImportKind.Path)
        (if (compiler-load-pkg-import? import-path)
          fallback
          (if (compiler-load-no-expected-module? expected-module)
            context-module
            fallback))]
      [_ fallback])))

(define (compiler-load-moduleless-context-id [path : String] [module : String]) : String
  (if (> (string.string-length module) 0)
    (str_cat.str-cat
      "moduleless:"
      module
      ":"
      (compiler-load-normalize-path path))
    (compiler-load-normalize-path path)))

(define (compiler-load-seen-path-key-in-module
  [path : String]
  [module : String]) : String
  (string.append "path:" (compiler-load-moduleless-context-id path module)))

(define (compiler-load-decls-source-module [decls : AstDeclList]) : String
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) ""]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.Module name) (intern-str name)]
          [_ (compiler-load-decls-source-module rest)]))]))

(define (compiler-load-decls-source-module-or
  [decls : AstDeclList]
  [fallback : String]) : String
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) fallback]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.Module name) (intern-str name)]
          [_ (compiler-load-decls-source-module-or rest fallback)]))]))

(define (compiler-load-decl-list-has-module? [decls : AstDeclList]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) false]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.Module _) true]
          [_ (compiler-load-decl-list-has-module? rest)]))]))

(define (compiler-load-decl-list-has-module-name?
  [decls : AstDeclList]
  [want : String]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) false]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.Module name)
            (if (string.eq (intern-str name) want)
              true
              (compiler-load-decl-list-has-module-name? rest want))]
          [(AstDecl.ModuleBody name body-box)
            (if (string.eq (intern-str name) want)
              true
              (or
                (compiler-load-decl-list-has-module-name?
                  (box-get body-box)
                  want)
                (compiler-load-decl-list-has-module-name? rest want)))]
          [_ (compiler-load-decl-list-has-module-name? rest want)]))]))

(define (compiler-load-decl-list-has-extern-symbol?
  [decls : AstDeclList]
  [want : String]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) false]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.Extern _ _ metadata _)
            (if (string.eq (ast-extern-metadata-symbol metadata) want)
              true
              (compiler-load-decl-list-has-extern-symbol? rest want))]
          [_ (compiler-load-decl-list-has-extern-symbol? rest want)]))]))

(define (compiler-load-contextual-moduleless-decls
  [decls : AstDeclList]
  [source-module : String]) : AstDeclList
  (if (and
    (> (string.string-length source-module) 0)
    (not (compiler-load-decl-list-has-module? decls)))
    (ast-decl-cons (ast-decl-module source-module) decls)
    decls))

(define (compiler-load-seen-module-with-paths
  [path : String]
  [module-id : String]
  [decls : AstDeclList]
  [seen : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (if (compiler-load-decl-list-has-module? decls)
    (ResultCompilerLoadWithPaths.Ok
      (ast-decl-cons (ast-decl-module module-id) (ast-decl-list-new))
      (ast-decl-path-cons path (ast-decl-path-list-new))
      (ast-decl-module-cons module-id (ast-decl-module-list-new))
      seen)
    (ResultCompilerLoadWithPaths.Ok
      (ast-decl-list-new)
      (ast-decl-path-list-new)
      (ast-decl-module-list-new)
      seen)))

(define (compiler-load-legacy-path-flat-module-import?
  [kind : AstImportKind]
  [expected : AstMaybeModuleName]
  [alias : AstMaybeImportAlias]
  [imported-decls : AstDeclList]) : bool
  (match kind
    [(AstImportKind.Path)
      (match expected
        [(AstMaybeModuleName.No)
          (match alias
            [(AstMaybeImportAlias.No)
              (compiler-load-decl-list-has-module? imported-decls)]
            [(AstMaybeImportAlias.Some _) false])]
        [(AstMaybeModuleName.Some _) false])]
    [_ false]))

(define (compiler-load-after-import-expected-module
  [kind : AstImportKind]
  [expected : AstMaybeModuleName]
  [alias : AstMaybeImportAlias]
  [imported-decls : AstDeclList]) : AstMaybeModuleName
  (if (compiler-load-legacy-path-flat-module-import?
    kind
    expected
    alias
    imported-decls)
    (AstMaybeModuleName.Some (compiler-load-decls-source-module imported-decls))
    expected))

(define (compiler-load-after-import-alias
  [kind : AstImportKind]
  [expected : AstMaybeModuleName]
  [alias : AstMaybeImportAlias]
  [imported-decls : AstDeclList]) : AstMaybeImportAlias
  (if (compiler-load-legacy-path-flat-module-import?
    kind
    expected
    alias
    imported-decls)
    (AstMaybeImportAlias.Some "")
    alias))

(define (compiler-load-dotted-import-alias-key
  [module : String]
  [alias : String]) : String
  (string.append module (string.append "/" alias)))

(define (compiler-load-duplicate-dotted-import-alias-loop
  [decls : AstDeclList]
  [current-module : String]
  [seen : sym_i64_env.SymI64Env]) : CompilerLoadMaybeString
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) (CompilerLoadNoString)]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.Module name)
            (compiler-load-duplicate-dotted-import-alias-loop
              rest
              (intern-str name)
              seen)]
          [(AstDecl.Import
              (AstImportSpec.Spec
                (AstImportKind.Module)
                _
                _
                (AstMaybeImportAlias.Some alias)
                _))
            (let
              [key : String
                (compiler-load-dotted-import-alias-key current-module alias)]
              (if (sym_i64_env.sym-i64-contains seen key)
                (CompilerLoadSomeString alias)
                (compiler-load-duplicate-dotted-import-alias-loop
                  rest
                  current-module
                  (sym_i64_env.sym-i64-bind seen key 1))))]
          [_
            (compiler-load-duplicate-dotted-import-alias-loop
              rest
              current-module
              seen)]))]))

(define (compiler-load-check-dotted-import-aliases
  [path : String]
  [decls : AstDeclList]
  [source-module : String]) : ResultCompilerLoadAliasCheck
  (match (compiler-load-duplicate-dotted-import-alias-loop
    decls
    source-module
    (sym_i64_env.sym-i64-empty))
    [(CompilerLoadNoString) (ResultCompilerLoadAliasCheck.Ok)]
    [(CompilerLoadSomeString alias)
      (ResultCompilerLoadAliasCheck.Err
        (box
          (compiler-diagnostic-at-start
            path
            (string.append
              "compiler-load: duplicate module import alias "
              alias))))]))

(define (compiler-load-surface-summaries-reset!) : unit
  (begin
    (set!
      compiler-load-active-surface-summaries
      (CompilerLoadSurfaceSummaryNil))
    (set!
      compiler-load-stdlib-array-surface-summary
      (CompilerLoadNoSurfaceSummary))
    (set! compiler-load-lazy-import-skip-record-count 0)))

(define (compiler-load-surface-summary-load-enter!) : unit
  (begin
    (if (= compiler-load-surface-summary-load-depth 0)
      (compiler-load-surface-summaries-reset!)
      unit)
    (set!
      compiler-load-surface-summary-load-depth
      (+ compiler-load-surface-summary-load-depth 1))))

(define (compiler-load-surface-summary-load-exit!) : unit
  (set!
    compiler-load-surface-summary-load-depth
    (- compiler-load-surface-summary-load-depth 1)))

(define (compiler-load-surface-summaries) : CompilerLoadSurfaceSummaryList
  compiler-load-active-surface-summaries)

(define (compiler-load-lazy-import-skip-count) : i64
  compiler-load-lazy-import-skip-record-count)

(define (compiler-load-lazy-import-record-skip!) : unit
  (set!
    compiler-load-lazy-import-skip-record-count
    (+ compiler-load-lazy-import-skip-record-count 1)))

(define (compiler-load-stdlib-array-module-id? [module-id : String]) : bool
  (or
    (compiler-load-string-eq? module-id "stdlib.array")
    (compiler-load-string-eq? module-id "stdlib/array")
    (compiler-load-string-eq? module-id "stdlib/array.tl")))

(define (compiler-load-record-surface-summary!
  [summary : CompilerLoadSurfaceSummary]) : unit
  (begin
    (if (compiler-load-stdlib-array-module-id? (struct-get summary module-id))
      (set!
        compiler-load-stdlib-array-surface-summary
        (CompilerLoadSomeSurfaceSummary summary))
      unit)
    (set!
      compiler-load-active-surface-summaries
      (CompilerLoadSurfaceSummaryCons
        summary
        (box compiler-load-active-surface-summaries)))))

(define (compiler-load-surface-summary-find-source-in
  [summaries : CompilerLoadSurfaceSummaryList]
  [source-path : String]) : CompilerLoadMaybeSurfaceSummary
  (match summaries
    [(CompilerLoadSurfaceSummaryNil) (CompilerLoadNoSurfaceSummary)]
    [(CompilerLoadSurfaceSummaryCons summary rest)
      (if (string.eq (struct-get summary source-path) source-path)
        (CompilerLoadSomeSurfaceSummary summary)
        (compiler-load-surface-summary-find-source-in
          (box-get rest)
          source-path))]))

(define (compiler-load-surface-summary-find-source [source-path : String]) : CompilerLoadMaybeSurfaceSummary
  (let
    [normalized : String (compiler-load-normalize-path source-path)]
    (if (compiler-load-string-eq? normalized "stdlib/array.tl")
      (match compiler-load-stdlib-array-surface-summary
        [(CompilerLoadSomeSurfaceSummary summary)
          (CompilerLoadSomeSurfaceSummary summary)]
        [(CompilerLoadNoSurfaceSummary)
          (compiler-load-surface-summary-find-source-in
            compiler-load-active-surface-summaries
            normalized)])
      (compiler-load-surface-summary-find-source-in
        compiler-load-active-surface-summaries
        normalized))))

(define (compiler-load-stdlib-array-surface-summary-ensure-with-pools
  [path : String]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : unit
  (match compiler-load-stdlib-array-surface-summary
    [(CompilerLoadSomeSurfaceSummary _) unit]
    [(CompilerLoadNoSurfaceSummary)
      (let
        [parse-cfgs : sym_i64_env.SymI64Env
          (compiler-load-stdlib-private-cfgs
            path
            stdlib-roots
            expected-module
            cfgs)]
        (match (if (io.file-exists? path)
          (compiler-load-parse-file-diagnostic-session-with-pools
            path
            stdlib-roots
            parse-cfgs
            pools)
          (match (compiler-load-embedded-stdlib-source-for-path path)
            [(CompilerEmbeddedStdlibSomeSource source)
              (compiler-load-parse-embedded-source-diagnostic-session-with-pools
                path
                source
                parse-cfgs
                pools)]
            [(CompilerEmbeddedStdlibNoSource)
              (compiler-load-parse-file-diagnostic-escaping-with-pools
                path
                parse-cfgs
                pools)]))
          [(ResultAstProgramDiagnostic.Ok program)
            (match (compiler-load-surface-summary-build
              path
              import-root
              parse-cfgs
              program)
              [(ResultCompilerLoadSurfaceSummary.Ok summary)
                (compiler-load-record-surface-summary! summary)]
              [(ResultCompilerLoadSurfaceSummary.Err _) unit])]
          [(ResultAstProgramDiagnostic.Err _) unit]))]))

(define (compiler-load-surface-summary-decl-requires-eager?
  [decl : CompilerLoadSurfaceDecl]) : bool
  (or
    (match (struct-get decl kind)
      [(CompilerLoadSurfaceExtern) true]
      [_ false])
    (struct-get decl has-cleanup)
    (struct-get decl has-export)
    (struct-get decl has-generated-meta)))

(define (compiler-load-surface-summary-decls-require-eager?
  [decls : CompilerLoadSurfaceDeclList]) : bool
  (match decls
    [(CompilerLoadSurfaceDeclNil) false]
    [(CompilerLoadSurfaceDeclCons decl rest)
      (or
        (compiler-load-surface-summary-decl-requires-eager? decl)
        (compiler-load-surface-summary-decls-require-eager? (box-get rest)))]))

(define (compiler-load-surface-summary-requires-eager?
  [summary : CompilerLoadSurfaceSummary]) : bool
  (or
    (struct-get summary has-tests)
    (struct-get summary has-export-metadata)
    (struct-get summary has-generated-decls)
    (struct-get summary has-decl-emitting-macro)
    (compiler-load-surface-summary-decls-require-eager?
      (struct-get summary decls))))

(define (compiler-load-lazy-variant-name-used?
  [variant : AstVariantDef]
  [source : String]
  [start : i64]) : bool
  (match variant
    [(AstVariantDef.Def name _ _)
      (compiler-load-source-has-name-token-from? source (intern-str name) start)]))

(define (compiler-load-lazy-variant-list-name-used?
  [variants : AstVariantDefList]
  [source : String]
  [start : i64]) : bool
  (match variants
    [(AstVariantDefList.Nil) false]
    [(AstVariantDefList.Cons variant rest)
      (or
        (compiler-load-lazy-variant-name-used? variant source start)
        (compiler-load-lazy-variant-list-name-used? (box-get rest) source start))]))

(define (compiler-load-lazy-surface-signature-name-used?
  [signature : CompilerLoadSurfaceSignature]
  [source : String]
  [start : i64]) : bool
  (match signature
    [(CompilerLoadSurfaceEnumSignature _ _ variants)
      (compiler-load-lazy-variant-list-name-used? variants source start)]
    [_ false]))

(define (compiler-load-lazy-surface-decl-name-used?
  [decl : CompilerLoadSurfaceDecl]
  [source : String]
  [start : i64]) : bool
  (or
    (compiler-load-source-has-name-token-from?
      source
      (struct-get decl name)
      start)
    (compiler-load-lazy-surface-signature-name-used?
      (struct-get decl signature)
      source
      start)))

(define (compiler-load-lazy-surface-decls-name-used?
  [decls : CompilerLoadSurfaceDeclList]
  [source : String]
  [start : i64]) : bool
  (match decls
    [(CompilerLoadSurfaceDeclNil) false]
    [(CompilerLoadSurfaceDeclCons decl rest)
      (or
        (compiler-load-lazy-surface-decl-name-used? decl source start)
        (compiler-load-lazy-surface-decls-name-used?
          (box-get rest)
          source
          start))]))

(define (compiler-load-lazy-module-used-after?
  [importer-path : String]
  [summary : CompilerLoadSurfaceSummary]
  [alias : String]
  [span : AstSourceSpan]
  [include-direct-names : bool]) : bool
  (match (compiler-load-source-for-lazy-scan importer-path)
    [(CompilerLoadNoString) true]
    [(CompilerLoadSomeString source)
      (let
        [start : i64 (compiler-load-source-scan-start span source)]
        (if (compiler-load-source-has-alias-token-from? source alias start)
          true
          (if include-direct-names
            (compiler-load-lazy-surface-decls-name-used?
              (struct-get summary decls)
              source
              start)
            false)))]))

(define (compiler-load-stdlib-array-canonical-importer?
  [importer-path : String]) : bool
  (let
    [normalized : String (compiler-load-normalize-path importer-path)]
    (or
      (compiler-load-string-eq? normalized "stdlib/vector.tl")
      (compiler-load-string-eq? normalized "stdlib/hashmap.tl")
      (compiler-load-string-eq? normalized "stdlib/str_cat.tl"))))

(define (compiler-load-stdlib-array-alias-used-after?
  [importer-path : String]
  [alias : String]
  [span : AstSourceSpan]) : bool
  (match (compiler-load-source-for-lazy-scan importer-path)
    [(CompilerLoadNoString) true]
    [(CompilerLoadSomeString source)
      (compiler-load-source-has-bare-alias-token-from?
        source
        alias
        (compiler-load-source-scan-start span source))]))

(define (compiler-load-lazy-import-preload-candidate?
  [importer-path : String]
  [kind : AstImportKind]
  [import-path : String]
  [resolved : String]
  [alias : AstMaybeImportAlias]) : bool
  (and
    (compiler-load-lazy-imports-enabled?)
    (not (compiler-load-prelude-importer? importer-path))
    (match kind
      [(AstImportKind.Module) true]
      [_ false])
    (match alias
      [(AstMaybeImportAlias.Some _) true]
      [(AstMaybeImportAlias.No) false])
    (or
      (compiler-load-string-eq? import-path "stdlib.array")
      (compiler-load-stdlib-array-module-id? resolved))))

(define (compiler-load-lazy-import-skip?
  [importer-path : String]
  [kind : AstImportKind]
  [resolved : String]
  [alias : AstMaybeImportAlias]
  [span : AstSourceSpan]) : bool
  (if (or
    (not (compiler-load-lazy-imports-enabled?))
    (compiler-load-prelude-importer? importer-path))
    false
    (match (compiler-load-surface-summary-find-source resolved)
      [(CompilerLoadNoSurfaceSummary) false]
      [(CompilerLoadSomeSurfaceSummary summary)
        (if (compiler-load-surface-summary-requires-eager? summary)
          false
          (match kind
            [(AstImportKind.Module)
              (match alias
                [(AstMaybeImportAlias.Some alias-name)
                  (if (compiler-load-stdlib-array-module-id?
                    (struct-get summary module-id))
                    (and
                      (not
                        (compiler-load-stdlib-array-canonical-importer?
                          importer-path))
                      (not
                        (compiler-load-stdlib-array-alias-used-after?
                          importer-path
                          alias-name
                          span)))
                    (not
                      (compiler-load-lazy-module-used-after?
                        importer-path
                        summary
                        alias-name
                        span
                        (not (compiler-load-stdlib-import? resolved)))))]
                [(AstMaybeImportAlias.No) false])]
            [(AstImportKind.Path) false]
            [_ false]))])))

(define (compiler-load-surface-zero-span) : AstSourceSpan
  (AstSourceSpan 0 0 0 0))

(define (compiler-load-surface-module-maybe [module-name : AstMaybeModuleName]) : CompilerLoadSurfaceMaybeString
  (match module-name
    [(AstMaybeModuleName.No) (CompilerLoadSurfaceNoString)]
    [(AstMaybeModuleName.Some name) (CompilerLoadSurfaceSomeString name)]))

(define (compiler-load-surface-alias-maybe [alias : AstMaybeImportAlias]) : CompilerLoadSurfaceMaybeString
  (match alias
    [(AstMaybeImportAlias.No) (CompilerLoadSurfaceNoString)]
    [(AstMaybeImportAlias.Some name) (CompilerLoadSurfaceSomeString name)]))

(define (compiler-load-surface-import-kind [kind : AstImportKind]) : CompilerLoadSurfaceImportKind
  (match kind
    [(AstImportKind.Path) (CompilerLoadSurfaceImportPath)]
    [(AstImportKind.Module) (CompilerLoadSurfaceImportModule)]
    [(AstImportKind.Macro _ _) (CompilerLoadSurfaceImportMacro)]
    [(AstImportKind.MacroDecls _ _) (CompilerLoadSurfaceImportMacroDecls)]))

(define (compiler-load-surface-import-decl-emitting? [kind : AstImportKind]) : bool
  (match kind
    [(AstImportKind.MacroDecls _ _) true]
    [_ false]))

(define (compiler-load-surface-import-default-alias
  [kind : AstImportKind]
  [import-path : String]) : CompilerLoadSurfaceMaybeString
  (match kind
    [(AstImportKind.Module)
      (CompilerLoadSurfaceSomeString
        (parse-ast-dotted-import-default-alias import-path))]
    [_ (CompilerLoadSurfaceNoString)]))

(define (compiler-load-surface-macro-result-kind [ret : AstType]) : CompilerLoadSurfaceMacroResultKind
  (match ret
    [(AstType.Expr) (CompilerLoadSurfaceMacroExpr)]
    [(AstType.Var name)
      (cond
        [(or (= name (intern "Expr")) (= name (intern "expr")))
          (CompilerLoadSurfaceMacroExpr)]
        [(or (= name (intern "Module")) (= name (intern "module")))
          (CompilerLoadSurfaceMacroModule)]
        [(or (= name (intern "Decls")) (= name (intern "decls")))
          (CompilerLoadSurfaceMacroDecls)]
        [else (CompilerLoadSurfaceMacroOther)])]
    [_ (CompilerLoadSurfaceMacroOther)]))

(define (compiler-load-surface-macro-result-decl-emitting? [ret : AstType]) : bool
  (match (compiler-load-surface-macro-result-kind ret)
    [(CompilerLoadSurfaceMacroModule) true]
    [(CompilerLoadSurfaceMacroDecls) true]
    [_ false]))

(define (compiler-load-surface-fn-export? [export : AstFnExport]) : bool
  (match export
    [(AstFnExport.No) false]
    [(AstFnExport.Export _) true]))

(define (compiler-load-surface-generated-meta? [meta : AstGeneratedDeclMeta]) : bool
  (match meta
    [(AstGeneratedDeclMeta.No) false]
    [(AstGeneratedDeclMeta.Some _ _ _ _) true]))

(define (compiler-load-surface-field-list-cleanup? [fields : AstFieldDefList]) : bool
  (compiler-load-surface-field-list-cleanup-at? (& fields) 0))

(define (compiler-load-surface-field-list-cleanup-at?
  [fields : (& fields AstFieldDefList)]
  [index : i64]) : bool
  (if (>= index (ast-field-def-list-len fields))
    false
    (match (ast-field-def-list-get fields index (ast-field-def-fallback))
      [(AstFieldDef.Def _ _ cleanup)
        (or
          (ast-field-cleanup? cleanup)
          (compiler-load-surface-field-list-cleanup-at? fields (+ index 1)))])))

(define (compiler-load-surface-variant-payload-cleanup?
  [cleanups : AstVariantPayloadCleanupList]) : bool
  (match cleanups
    [(AstVariantPayloadCleanupList.Nil) false]
    [(AstVariantPayloadCleanupList.Cons cleanup rest)
      (or
        (ast-variant-payload-cleanup? cleanup)
        (compiler-load-surface-variant-payload-cleanup? (box-get rest)))]))

(define (compiler-load-surface-variant-list-cleanup?
  [variants : AstVariantDefList]) : bool
  (match variants
    [(AstVariantDefList.Nil) false]
    [(AstVariantDefList.Cons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef.Def _ _ cleanups)
            (or
              (compiler-load-surface-variant-payload-cleanup? cleanups)
              (compiler-load-surface-variant-list-cleanup? rest))]))]))

(define (compiler-load-surface-build-empty) : CompilerLoadSurfaceBuild
  (CompilerLoadSurfaceBuild
    CompilerLoadSurfaceImportNil
    CompilerLoadSurfaceDeclNil
    false
    false
    false
    false))

(define (compiler-load-surface-build-add-import
  [build : CompilerLoadSurfaceBuild]
  [import-edge : CompilerLoadSurfaceImport]
  [decl-emitting : bool]) : CompilerLoadSurfaceBuild
  (CompilerLoadSurfaceBuild
    (CompilerLoadSurfaceImportCons import-edge (box (struct-get build imports)))
    (struct-get build decls)
    (struct-get build has-tests)
    (struct-get build has-export-metadata)
    (struct-get build has-generated-decls)
    (or (struct-get build has-decl-emitting-macro) decl-emitting)))

(define (compiler-load-surface-build-add-decl
  [build : CompilerLoadSurfaceBuild]
  [decl : CompilerLoadSurfaceDecl]
  [has-test : bool]
  [has-export : bool]
  [has-generated : bool]
  [decl-emitting : bool]) : CompilerLoadSurfaceBuild
  (CompilerLoadSurfaceBuild
    (struct-get build imports)
    (CompilerLoadSurfaceDeclCons decl (box (struct-get build decls)))
    (or (struct-get build has-tests) has-test)
    (or (struct-get build has-export-metadata) has-export)
    (or (struct-get build has-generated-decls) has-generated)
    (or (struct-get build has-decl-emitting-macro) decl-emitting)))

(define (compiler-load-surface-build-decl
  [source-path : String]
  [module-id : String]
  [decl : AstDecl]
  [generated : bool]
  [was-unsafe : bool]
  [build : CompilerLoadSurfaceBuild]) : CompilerLoadSurfaceBuild
  (match decl
    [(AstDecl.Import
        (AstImportSpec.Spec kind import-path module-name alias span))
      (compiler-load-surface-build-add-import
        build
        (CompilerLoadSurfaceImport
          (compiler-load-surface-import-kind kind)
          source-path
          import-path
          (compiler-load-surface-module-maybe module-name)
          (compiler-load-surface-alias-maybe alias)
          (compiler-load-surface-import-default-alias kind import-path)
          span)
        (compiler-load-surface-import-decl-emitting? kind))]
    [(AstDecl.Def name maybe-ty _)
      (compiler-load-surface-build-add-decl
        build
        (CompilerLoadSurfaceDecl
          (CompilerLoadSurfaceValue)
          (intern-str name)
          module-id
          (CompilerLoadSurfaceValueSignature maybe-ty)
          (CompilerLoadSurfaceMacroOther)
          false
          false
          generated
          was-unsafe
          (compiler-load-surface-zero-span))
        false
        false
        generated
        false)]
    [(AstDecl.DefFn name params ret _ export)
      (let
        [has-export : bool (compiler-load-surface-fn-export? export)]
        (compiler-load-surface-build-add-decl
          build
          (CompilerLoadSurfaceDecl
            (CompilerLoadSurfaceFunction)
            (intern-str name)
            module-id
            (CompilerLoadSurfaceFunctionSignature params ret)
            (CompilerLoadSurfaceMacroOther)
            false
            has-export
            generated
            was-unsafe
            (compiler-load-surface-zero-span))
          false
          has-export
          generated
          false))]
    [(AstDecl.Extern name kind meta ty)
      (compiler-load-surface-build-add-decl
        build
        (CompilerLoadSurfaceDecl
          (CompilerLoadSurfaceExtern)
          (intern-str name)
          module-id
          (CompilerLoadSurfaceExternSignature kind meta ty)
          (CompilerLoadSurfaceMacroOther)
          false
          false
          generated
          was-unsafe
          (compiler-load-surface-zero-span))
        false
        false
        generated
        false)]
    [(AstDecl.DefStruct name repr cleanup fields)
      (let
        [has-cleanup : bool
          (or
            (ast-struct-cleanup? cleanup)
            (compiler-load-surface-field-list-cleanup? fields))]
        (compiler-load-surface-build-add-decl
          build
          (CompilerLoadSurfaceDecl
            (CompilerLoadSurfaceStruct)
            (intern-str name)
            module-id
            (CompilerLoadSurfaceStructSignature
              AstLifetimeList.Nil
              repr
              cleanup
              fields)
            (CompilerLoadSurfaceMacroOther)
            has-cleanup
            false
            generated
            was-unsafe
            (compiler-load-surface-zero-span))
          false
          false
          generated
          false))]
    [(AstDecl.DefStructLifetimes name lifetimes repr cleanup fields)
      (let
        [has-cleanup : bool
          (or
            (ast-struct-cleanup? cleanup)
            (compiler-load-surface-field-list-cleanup? fields))]
        (compiler-load-surface-build-add-decl
          build
          (CompilerLoadSurfaceDecl
            (CompilerLoadSurfaceStruct)
            (intern-str name)
            module-id
            (CompilerLoadSurfaceStructSignature lifetimes repr cleanup fields)
            (CompilerLoadSurfaceMacroOther)
            has-cleanup
            false
            generated
            was-unsafe
            (compiler-load-surface-zero-span))
          false
          false
          generated
          false))]
    [(AstDecl.DefEnum name cleanup variants)
      (let
        [has-cleanup : bool
          (or
            (ast-enum-cleanup? cleanup)
            (compiler-load-surface-variant-list-cleanup? variants))]
        (compiler-load-surface-build-add-decl
          build
          (CompilerLoadSurfaceDecl
            (CompilerLoadSurfaceEnum)
            (intern-str name)
            module-id
            (CompilerLoadSurfaceEnumSignature
              AstLifetimeList.Nil
              cleanup
              variants)
            (CompilerLoadSurfaceMacroOther)
            has-cleanup
            false
            generated
            was-unsafe
            (compiler-load-surface-zero-span))
          false
          false
          generated
          false))]
    [(AstDecl.DefEnumLifetimes name lifetimes cleanup variants)
      (let
        [has-cleanup : bool
          (or
            (ast-enum-cleanup? cleanup)
            (compiler-load-surface-variant-list-cleanup? variants))]
        (compiler-load-surface-build-add-decl
          build
          (CompilerLoadSurfaceDecl
            (CompilerLoadSurfaceEnum)
            (intern-str name)
            module-id
            (CompilerLoadSurfaceEnumSignature lifetimes cleanup variants)
            (CompilerLoadSurfaceMacroOther)
            has-cleanup
            false
            generated
            was-unsafe
            (compiler-load-surface-zero-span))
          false
          false
          generated
          false))]
    [(AstDecl.DefMacro name params ret body-box)
      (let
        [result-kind : CompilerLoadSurfaceMacroResultKind
          (compiler-load-surface-macro-result-kind ret)]
        [decl-emitting : bool
          (compiler-load-surface-macro-result-decl-emitting? ret)]
        (compiler-load-surface-build-add-decl
          build
          (CompilerLoadSurfaceDecl
            (CompilerLoadSurfaceMacro)
            (intern-str name)
            module-id
            (CompilerLoadSurfaceMacroSignature params ret body-box)
            result-kind
            false
            false
            generated
            was-unsafe
            (compiler-load-surface-zero-span))
          false
          false
          generated
          decl-emitting))]
    [(AstDecl.DefDispatch name variants)
      (compiler-load-surface-build-add-decl
        build
        (CompilerLoadSurfaceDecl
          (CompilerLoadSurfaceDispatch)
          (intern-str name)
          module-id
          (CompilerLoadSurfaceDispatchSignature variants)
          (CompilerLoadSurfaceMacroOther)
          false
          false
          generated
          was-unsafe
          (compiler-load-surface-zero-span))
        false
        false
        generated
        false)]
    [(AstDecl.Test name _ span)
      (compiler-load-surface-build-add-decl
        build
        (CompilerLoadSurfaceDecl
          (CompilerLoadSurfaceTest)
          (intern-str name)
          module-id
          (CompilerLoadSurfaceNoSignature)
          (CompilerLoadSurfaceMacroOther)
          false
          false
          generated
          was-unsafe
          span)
        true
        false
        generated
        false)]
    [(AstDecl.IncludeStr name _)
      (compiler-load-surface-build-add-decl
        build
        (CompilerLoadSurfaceDecl
          (CompilerLoadSurfaceIncludeStr)
          name
          module-id
          (CompilerLoadSurfaceNoSignature)
          (CompilerLoadSurfaceMacroOther)
          false
          false
          generated
          was-unsafe
          (compiler-load-surface-zero-span))
        false
        false
        generated
        false)]
    [(AstDecl.IncludeBin name _)
      (compiler-load-surface-build-add-decl
        build
        (CompilerLoadSurfaceDecl
          (CompilerLoadSurfaceIncludeBin)
          name
          module-id
          (CompilerLoadSurfaceNoSignature)
          (CompilerLoadSurfaceMacroOther)
          false
          false
          generated
          was-unsafe
          (compiler-load-surface-zero-span))
        false
        false
        generated
        false)]
    [(AstDecl.Unsafe inner-box)
      (compiler-load-surface-build-decl
        source-path
        module-id
        (box-get inner-box)
        generated
        true
        build)]
    [(AstDecl.ComptimeDecl meta inner-box)
      (compiler-load-surface-build-decl
        source-path
        module-id
        (box-get inner-box)
        (or generated (compiler-load-surface-generated-meta? meta))
        was-unsafe
        build)]
    [(AstDecl.ModuleBody nested-module body-box)
      (compiler-load-surface-build-decls-into
        source-path
        (intern-str nested-module)
        (box-get body-box)
        build)]
    [(AstDecl.Module _) build]))

(define (compiler-load-surface-build-decls-into
  [source-path : String]
  [module-id : String]
  [decls : AstDeclList]
  [build : CompilerLoadSurfaceBuild]) : CompilerLoadSurfaceBuild
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) build]
    [(AstDeclListStep.Cons decl rest-box)
      (let
        [rest : AstDeclList rest-box]
        (match decl
          [(AstDecl.Module next-module)
            (compiler-load-surface-build-decls-into
              source-path
              (intern-str next-module)
              rest
              build)]
          [(AstDecl.ModuleBody nested-module body-box)
            (compiler-load-surface-build-decls-into
              source-path
              (intern-str nested-module)
              (box-get body-box)
              (compiler-load-surface-build-decls-into
                source-path
                module-id
                rest
                build))]
          [_
            (compiler-load-surface-build-decl
              source-path
              module-id
              decl
              false
              false
              (compiler-load-surface-build-decls-into
                source-path
                module-id
                rest
                build))]))]))

(define (compiler-load-surface-build-decls
  [source-path : String]
  [module-id : String]
  [decls : AstDeclList]) : CompilerLoadSurfaceBuild
  (compiler-load-surface-build-decls-into
    source-path
    module-id
    decls
    (compiler-load-surface-build-empty)))

(define (compiler-load-surface-summary-from-decls
  [path : String]
  [root-id : String]
  [cfgs : sym_i64_env.SymI64Env]
  [module-id : String]
  [decls : AstDeclList]) : CompilerLoadSurfaceSummary
  (let
    [source-path : String (compiler-load-normalize-path path)]
    [build : CompilerLoadSurfaceBuild
      (compiler-load-surface-build-decls source-path module-id decls)]
    (CompilerLoadSurfaceSummary
      module-id
      source-path
      (compiler-load-normalize-path root-id)
      (compiler-load-cfg-cache-key cfgs)
      (struct-get build imports)
      (struct-get build decls)
      (struct-get build has-tests)
      (struct-get build has-export-metadata)
      (struct-get build has-generated-decls)
      (struct-get build has-decl-emitting-macro))))

(define (compiler-load-surface-summary-build
  [path : String]
  [root-id : String]
  [cfgs : sym_i64_env.SymI64Env]
  [program : AstProgram]) : ResultCompilerLoadSurfaceSummary
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        [source-module : String (compiler-load-decls-source-module decls)]
        (match (compiler-load-decls-module-id path decls)
          [(ResultCompilerLoadModuleId.Ok module-id)
            (match (compiler-load-check-dotted-import-aliases
              path
              decls
              source-module)
              [(ResultCompilerLoadAliasCheck.Ok)
                (ResultCompilerLoadSurfaceSummary.Ok
                  (compiler-load-surface-summary-from-decls
                    path
                    root-id
                    cfgs
                    module-id
                    decls))]
              [(ResultCompilerLoadAliasCheck.Err diag)
                (ResultCompilerLoadSurfaceSummary.Err diag)])]
          [(ResultCompilerLoadModuleId.Err diag)
            (ResultCompilerLoadSurfaceSummary.Err diag)]))]))

(define (compiler-load-decls-with-paths
  [decls : AstDeclList]
  [importer-path : String]
  [seen : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-decls-with-paths-and-roots
    decls
    importer-path
    seen
    (vector.string-vec-new)))

(define (compiler-load-alias-decl-list
  [kind : AstImportKind]
  [import-path : String]
  [expected-module : AstMaybeModuleName]
  [alias : AstMaybeImportAlias]
  [rest : AstDeclList]) : AstDeclList
  (match alias
    [(AstMaybeImportAlias.Some _)
      (ast-decl-list-prepend-builder
        (AstDecl.Import
          (AstImportSpec.Spec
            kind
            import-path
            expected-module
            alias
            (AstSourceSpan 0 0 0 0)))
        rest)]
    [(AstMaybeImportAlias.No) rest]))

(define (compiler-load-alias-path-list
  [importer-path : String]
  [alias : AstMaybeImportAlias]
  [rest : AstDeclPathList]) : AstDeclPathList
  (match alias
    [(AstMaybeImportAlias.Some _)
      (ast-decl-path-list-prepend-builder importer-path rest)]
    [(AstMaybeImportAlias.No) rest]))

(define (compiler-load-alias-module-list
  [importer-module : String]
  [alias : AstMaybeImportAlias]
  [rest : AstDeclModuleList]) : AstDeclModuleList
  (match alias
    [(AstMaybeImportAlias.Some _)
      (ast-decl-module-list-prepend-builder importer-module rest)]
    [(AstMaybeImportAlias.No) rest]))

;; Imported module declarations switch the flattened declaration context; restore
;; the importer's source module before the alias marker and remaining decls.
(define (compiler-load-decls-after-import
  [kind : AstImportKind]
  [import-path : String]
  [expected-module : AstMaybeModuleName]
  [alias : AstMaybeImportAlias]
  [importer-source-module : String]
  [imported-decls : AstDeclList]
  [rest : AstDeclList]) : AstDeclList
  (let
    [after-alias : AstDeclList
      (compiler-load-alias-decl-list
        kind
        import-path
        expected-module
        alias
        rest)]
    (if (compiler-load-decl-list-has-module? imported-decls)
      (ast-decl-list-prepend-builder
        (ast-decl-module importer-source-module)
        after-alias)
      after-alias)))

(define (compiler-load-paths-after-import
  [importer-path : String]
  [alias : AstMaybeImportAlias]
  [imported-decls : AstDeclList]
  [rest : AstDeclPathList]) : AstDeclPathList
  (let
    [after-alias : AstDeclPathList
      (compiler-load-alias-path-list importer-path alias rest)]
    (if (compiler-load-decl-list-has-module? imported-decls)
      (ast-decl-path-list-prepend-builder importer-path after-alias)
      after-alias)))

(define (compiler-load-modules-after-import
  [importer-module : String]
  [alias : AstMaybeImportAlias]
  [imported-decls : AstDeclList]
  [rest : AstDeclModuleList]) : AstDeclModuleList
  (let
    [after-alias : AstDeclModuleList
      (compiler-load-alias-module-list importer-module alias rest)]
    (if (compiler-load-decl-list-has-module? imported-decls)
      (ast-decl-module-list-prepend-builder importer-module after-alias)
      after-alias)))

(define (compiler-load-decls-with-module-and-roots
  [decls : AstDeclList]
  [importer-path : String]
  [importer-module : String]
  [importer-source-module : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]) : ResultCompilerLoadWithPaths
  (compiler-load-decls-with-module-and-roots-cfg
    decls
    importer-path
    importer-module
    importer-source-module
    seen
    stdlib-roots
    (compiler-cfg-empty)))

(define (compiler-load-decls-with-module-and-roots-cfg
  [decls : AstDeclList]
  [importer-path : String]
  [importer-module : String]
  [importer-source-module : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-decls-with-module-and-roots-cfg-root
    decls
    importer-path
    importer-module
    importer-source-module
    seen
    stdlib-roots
    (compiler-load-dirname importer-path)
    cfgs))

(define (compiler-load-decls-with-module-and-roots-cfg-with-pools
  [decls : AstDeclList]
  [importer-path : String]
  [importer-module : String]
  [importer-source-module : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
    decls
    importer-path
    importer-module
    importer-source-module
    seen
    stdlib-roots
    (compiler-load-dirname importer-path)
    cfgs
    pools))

(define (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
  [decls : AstDeclList]
  [importer-path : String]
  [importer-module : String]
  [importer-source-module : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil)
      (ResultCompilerLoadWithPaths.Ok
        (ast-decl-list-new)
        (ast-decl-path-list-new)
        (ast-decl-module-list-new)
        seen)]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.ModuleBody target-module-id body-box)
            (let
              [target-module : String (intern-str target-module-id)]
              [body : AstDeclList (box-get body-box)]
              (if (or
                (compiler-load-decl-list-has-module-name? body target-module)
                (compiler-load-decl-list-has-module-name? rest target-module))
                (ResultCompilerLoadWithPaths.Err
                  (box
                    (compiler-diagnostic-at-start
                      importer-path
                      "compiler-load: duplicate module declaration")))
                (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                  body
                  importer-path
                  target-module
                  target-module
                  seen
                  stdlib-roots
                  import-root
                  cfgs
                  pools)
                  [(ResultCompilerLoadWithPaths.Ok
                      body-decls
                      body-paths
                      body-modules
                      body-seen)
                    (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                      rest
                      importer-path
                      importer-module
                      importer-source-module
                      body-seen
                      stdlib-roots
                      import-root
                      cfgs
                      pools)
                      [(ResultCompilerLoadWithPaths.Ok
                          rest-decls
                          rest-paths
                          rest-modules
                          rest-seen)
                        (ResultCompilerLoadWithPaths.Ok
                          (ast-decl-list-prepend-builder
                            (ast-decl-module target-module)
                            (compiler-load-decl-list-append-onto
                              body-decls
                              (ast-decl-list-prepend-builder
                                (ast-decl-module importer-source-module)
                                rest-decls)))
                          (ast-decl-path-list-prepend-builder
                            importer-path
                            (compiler-load-decl-path-list-append-onto
                              body-paths
                              (ast-decl-path-list-prepend-builder
                                importer-path
                                rest-paths)))
                          (ast-decl-module-list-prepend-builder
                            target-module
                            (compiler-load-decl-module-list-append-onto
                              body-modules
                              (ast-decl-module-list-prepend-builder
                                importer-module
                                rest-modules)))
                          rest-seen)]
                      [(ResultCompilerLoadWithPaths.Err diag)
                        (ResultCompilerLoadWithPaths.Err diag)])]
                  [(ResultCompilerLoadWithPaths.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])))]
          [(AstDecl.Import
              (AstImportSpec.Spec kind import-path expected-module alias span))
            (if (compiler-load-macro-import-kind? kind)
              (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                rest
                importer-path
                importer-module
                importer-source-module
                seen
                stdlib-roots
                import-root
                cfgs
                pools)
                [(ResultCompilerLoadWithPaths.Ok
                    rest-decls
                    rest-paths
                    rest-modules
                    rest-seen)
                  (ResultCompilerLoadWithPaths.Ok
                    (ast-decl-list-prepend-builder decl rest-decls)
                    (ast-decl-path-list-prepend-builder
                      importer-path
                      rest-paths)
                    (ast-decl-module-list-prepend-builder
                      importer-module
                      rest-modules)
                    rest-seen)]
                [(ResultCompilerLoadWithPaths.Err diag)
                  (ResultCompilerLoadWithPaths.Err diag)])
              (match (compiler-load-resolve-import-spec-with-roots
                importer-path
                import-root
                kind
                import-path
                stdlib-roots)
                [(ResultPkgResolve.Ok resolved)
                  (let
                    [preload-candidate : bool
                      (compiler-load-lazy-import-preload-candidate?
                        importer-path
                        kind
                        import-path
                        resolved
                        alias)]
                    [_preload-summary : unit
                      (if preload-candidate
                        (compiler-load-stdlib-array-surface-summary-ensure-with-pools
                          resolved
                          stdlib-roots
                          expected-module
                          import-root
                          cfgs
                          pools)
                        unit)]
                    [preload-skip : bool
                      (if preload-candidate
                        (compiler-load-lazy-import-skip?
                          importer-path
                          kind
                          resolved
                          alias
                          span)
                        false)]
                    (match (if preload-skip
                      (ResultCompilerLoadWithPaths.Ok
                        (ast-decl-list-new)
                        (ast-decl-path-list-new)
                        (ast-decl-module-list-new)
                        seen)
                      (compiler-load-file-with-paths-and-roots-expect-cfg-root-import-with-pools
                        resolved
                        seen
                        stdlib-roots
                        kind
                        import-path
                        expected-module
                        import-root
                        cfgs
                        pools
                        importer-source-module))
                      [(ResultCompilerLoadWithPaths.Ok
                          imported-decls
                          imported-paths
                          imported-modules
                          import-seen)
                        (let
                          [lazy-skip : bool
                            (if preload-skip
                              true
                              (compiler-load-lazy-import-skip?
                                importer-path
                                kind
                                resolved
                                alias
                                span))]
                          [after-import-seen : sym_i64_env.SymI64Env
                            (if lazy-skip
                              seen
                              import-seen)]
                          (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                            rest
                            importer-path
                            importer-module
                            importer-source-module
                            after-import-seen
                            stdlib-roots
                            import-root
                            cfgs
                            pools)
                            [(ResultCompilerLoadWithPaths.Ok
                                rest-decls
                                rest-paths
                                rest-modules
                                rest-seen)
                              (let
                                [after-import-expected : AstMaybeModuleName
                                  (compiler-load-after-import-expected-module
                                    kind
                                    expected-module
                                    alias
                                    imported-decls)]
                                [after-import-alias : AstMaybeImportAlias
                                  (compiler-load-after-import-alias
                                    kind
                                    expected-module
                                    alias
                                    imported-decls)]
                                (if lazy-skip
                                  (begin
                                    (compiler-load-lazy-import-record-skip!)
                                    (ResultCompilerLoadWithPaths.Ok
                                      (compiler-load-decls-after-import
                                        kind
                                        resolved
                                        after-import-expected
                                        after-import-alias
                                        importer-source-module
                                        (ast-decl-list-new)
                                        rest-decls)
                                      (compiler-load-paths-after-import
                                        importer-path
                                        after-import-alias
                                        (ast-decl-list-new)
                                        rest-paths)
                                      (compiler-load-modules-after-import
                                        importer-module
                                        after-import-alias
                                        (ast-decl-list-new)
                                        rest-modules)
                                      rest-seen))
                                  (ResultCompilerLoadWithPaths.Ok
                                    (compiler-load-decl-list-append-onto
                                      imported-decls
                                      (compiler-load-decls-after-import
                                        kind
                                        resolved
                                        after-import-expected
                                        after-import-alias
                                        importer-source-module
                                        imported-decls
                                        rest-decls))
                                    (compiler-load-decl-path-list-append-onto
                                      imported-paths
                                      (compiler-load-paths-after-import
                                        importer-path
                                        after-import-alias
                                        imported-decls
                                        rest-paths))
                                    (compiler-load-decl-module-list-append-onto
                                      imported-modules
                                      (compiler-load-modules-after-import
                                        importer-module
                                        after-import-alias
                                        imported-decls
                                        rest-modules))
                                    rest-seen)))]
                            [(ResultCompilerLoadWithPaths.Err diag)
                              (ResultCompilerLoadWithPaths.Err diag)]))]
                      [(ResultCompilerLoadWithPaths.Err diag)
                        (ResultCompilerLoadWithPaths.Err diag)]))]
                [(ResultPkgResolve.Err message)
                  (ResultCompilerLoadWithPaths.Err
                    (box (compiler-diagnostic-at-start importer-path message)))]))]
          [(AstDecl.IncludeStr name include-path)
            (match (compiler-load-expand-include-str-with-pools
              importer-path
              include-path
              name
              stdlib-roots
              pools)
              [(ResultCompilerLoadInclude.Ok expanded)
                (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                  rest
                  importer-path
                  importer-module
                  importer-source-module
                  seen
                  stdlib-roots
                  import-root
                  cfgs
                  pools)
                  [(ResultCompilerLoadWithPaths.Ok
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (ResultCompilerLoadWithPaths.Ok
                      (ast-decl-list-prepend-builder expanded rest-decls)
                      (ast-decl-path-list-prepend-builder
                        importer-path
                        rest-paths)
                      (ast-decl-module-list-prepend-builder
                        importer-module
                        rest-modules)
                      rest-seen)]
                  [(ResultCompilerLoadWithPaths.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ResultCompilerLoadInclude.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]
          [(AstDecl.IncludeBin name include-path)
            (match (compiler-load-expand-include-bin-with-pools
              importer-path
              include-path
              name
              stdlib-roots
              pools)
              [(ResultCompilerLoadInclude.Ok expanded)
                (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                  rest
                  importer-path
                  importer-module
                  importer-source-module
                  seen
                  stdlib-roots
                  import-root
                  cfgs
                  pools)
                  [(ResultCompilerLoadWithPaths.Ok
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (ResultCompilerLoadWithPaths.Ok
                      (ast-decl-list-prepend-builder expanded rest-decls)
                      (ast-decl-path-list-prepend-builder
                        importer-path
                        rest-paths)
                      (ast-decl-module-list-prepend-builder
                        importer-module
                        rest-modules)
                      rest-seen)]
                  [(ResultCompilerLoadWithPaths.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ResultCompilerLoadInclude.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]
          [_
            (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
              rest
              importer-path
              importer-module
              importer-source-module
              seen
              stdlib-roots
              import-root
              cfgs
              pools)
              [(ResultCompilerLoadWithPaths.Ok
                  rest-decls
                  rest-paths
                  rest-modules
                  rest-seen)
                (ResultCompilerLoadWithPaths.Ok
                  (ast-decl-list-prepend-builder decl rest-decls)
                  (ast-decl-path-list-prepend-builder importer-path rest-paths)
                  (ast-decl-module-list-prepend-builder
                    importer-module
                    rest-modules)
                  rest-seen)]
              [(ResultCompilerLoadWithPaths.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]))]))

(define (compiler-load-decls-with-module-and-roots-cfg-root
  [decls : AstDeclList]
  [importer-path : String]
  [importer-module : String]
  [importer-source-module : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultCompilerLoadWithPaths
      (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
        decls
        importer-path
        importer-module
        importer-source-module
        seen
        stdlib-roots
        import-root
        cfgs
        pools)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (compiler-load-decls-with-paths-and-roots
  [decls : AstDeclList]
  [importer-path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]) : ResultCompilerLoadWithPaths
  (compiler-load-decls-with-paths-and-roots-cfg
    decls
    importer-path
    seen
    stdlib-roots
    (compiler-cfg-empty)))

(define (compiler-load-decls-with-paths-and-roots-cfg
  [decls : AstDeclList]
  [importer-path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-load-decls-module-id importer-path decls)
    [(ResultCompilerLoadModuleId.Ok module-id)
      (if (sym_i64_env.sym-i64-contains seen module-id)
        (ResultCompilerLoadWithPaths.Ok
          (ast-decl-list-new)
          (ast-decl-path-list-new)
          (ast-decl-module-list-new)
          seen)
        (compiler-load-decls-with-module-and-roots-cfg
          decls
          importer-path
          module-id
          (compiler-load-decls-source-module decls)
          (sym_i64_env.sym-i64-bind seen module-id 1)
          stdlib-roots
          cfgs))]
    [(ResultCompilerLoadModuleId.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-load-decls-with-paths-and-roots-cfg-with-pools
  [decls : AstDeclList]
  [importer-path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (compiler-load-decls-module-id importer-path decls)
    [(ResultCompilerLoadModuleId.Ok module-id)
      (if (sym_i64_env.sym-i64-contains seen module-id)
        (ResultCompilerLoadWithPaths.Ok
          (ast-decl-list-new)
          (ast-decl-path-list-new)
          (ast-decl-module-list-new)
          seen)
        (compiler-load-decls-with-module-and-roots-cfg-with-pools
          decls
          importer-path
          module-id
          (compiler-load-decls-source-module decls)
          (sym_i64_env.sym-i64-bind seen module-id 1)
          stdlib-roots
          cfgs
          pools))]
    [(ResultCompilerLoadModuleId.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-load-decls
  [decls : AstDeclList]
  [importer-path : String]
  [seen : sym_i64_env.SymI64Env]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-decls-with-paths decls importer-path seen)))

(define (compiler-load-decls-with-roots
  [decls : AstDeclList]
  [importer-path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-decls-with-paths-and-roots
      decls
      importer-path
      seen
      stdlib-roots)))

(define (compiler-load-program-with-paths
  [path : String]
  [program : AstProgram]
  [seen : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-program-with-paths-and-roots
    path
    program
    seen
    (vector.string-vec-new)))

(define (compiler-load-program-with-paths-and-roots
  [path : String]
  [program : AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]) : ResultCompilerLoadWithPaths
  (compiler-load-program-with-paths-and-roots-expect
    path
    program
    seen
    stdlib-roots
    AstMaybeModuleName.No))

(define (compiler-load-program-with-paths-and-roots-expect
  [path : String]
  [program : AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]) : ResultCompilerLoadWithPaths
  (compiler-load-program-with-paths-and-roots-expect-cfg
    path
    program
    seen
    stdlib-roots
    expected-module
    (compiler-cfg-empty)))

(define (compiler-load-program-with-paths-and-roots-expect-cfg
  [path : String]
  [program : AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-program-with-paths-and-roots-expect-cfg-root
    path
    program
    seen
    stdlib-roots
    expected-module
    (compiler-load-dirname path)
    cfgs))

(define (compiler-load-program-with-paths-and-roots-expect-cfg-with-pools
  [path : String]
  [program : AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-program-with-paths-and-roots-expect-cfg-root-with-pools
    path
    program
    seen
    stdlib-roots
    expected-module
    (compiler-load-dirname path)
    cfgs
    pools))

(define (compiler-load-program-with-paths-and-roots-expect-cfg-root-with-pools
  [path : String]
  [program : AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-program-with-paths-and-roots-expect-cfg-root-fallback-with-pools
    path
    program
    seen
    stdlib-roots
    expected-module
    import-root
    cfgs
    pools
    (compiler-load-canonical-module-id-from-path path)
    ""))

(define (compiler-load-program-with-paths-and-roots-expect-cfg-root-fallback-with-pools
  [path : String]
  [program : AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [module-id-fallback : String]
  [source-module-fallback : String]) : ResultCompilerLoadWithPaths
  (let
    [_ : unit (compiler-load-surface-summary-load-enter!)]
    [loaded : ResultCompilerLoadWithPaths
      (match program
        [(AstProgram.Program decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            [source-module : String
              (compiler-load-decls-source-module-or
                decls
                source-module-fallback)]
            [load-decls : AstDeclList
              (compiler-load-contextual-moduleless-decls decls source-module)]
            (match (compiler-load-decls-module-id-with-fallback
              path
              decls
              module-id-fallback)
              [(ResultCompilerLoadModuleId.Ok module-id)
                (match (compiler-load-check-expected-module
                  path
                  expected-module
                  module-id)
                  [(ResultCompilerLoadModuleId.Ok _)
                    (if (sym_i64_env.sym-i64-contains seen module-id)
                      (compiler-load-seen-module-with-paths
                        path
                        module-id
                        load-decls
                        seen)
                      (match (compiler-load-check-dotted-import-aliases
                        path
                        load-decls
                        source-module)
                        [(ResultCompilerLoadAliasCheck.Ok)
                          (begin
                            (compiler-load-record-surface-summary!
                              (compiler-load-surface-summary-from-decls
                                path
                                import-root
                                cfgs
                                module-id
                                load-decls))
                            (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                              load-decls
                              path
                              module-id
                              source-module
                              (sym_i64_env.sym-i64-bind seen module-id 1)
                              stdlib-roots
                              import-root
                              cfgs
                              pools))]
                        [(ResultCompilerLoadAliasCheck.Err diag)
                          (ResultCompilerLoadWithPaths.Err diag)]))]
                  [(ResultCompilerLoadModuleId.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ResultCompilerLoadModuleId.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)]))])]
    (begin
      (compiler-load-surface-summary-load-exit!)
      loaded)))

(define (compiler-load-program-with-paths-and-roots-expect-cfg-root
  [path : String]
  [program : AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultCompilerLoadWithPaths
      (compiler-load-program-with-paths-and-roots-expect-cfg-root-with-pools
        path
        program
        seen
        stdlib-roots
        expected-module
        import-root
        cfgs
        pools)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (compiler-load-program
  [path : String]
  [program : AstProgram]
  [seen : sym_i64_env.SymI64Env]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-program-with-paths path program seen)))

(define (compiler-load-program-with-roots
  [path : String]
  [program : AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-program-with-paths-and-roots path program seen stdlib-roots)))

(define (compiler-load-source-with-paths
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots
    path
    source
    seen
    (vector.string-vec-new)))

(define (compiler-load-source-with-paths-and-roots
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots-expect
    path
    source
    seen
    stdlib-roots
    AstMaybeModuleName.No))

(define (compiler-load-source-with-paths-and-roots-cfg
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots-expect-cfg
    path
    source
    seen
    stdlib-roots
    AstMaybeModuleName.No
    cfgs))

(define (compiler-load-source-with-paths-and-roots-expect
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots-expect-cfg
    path
    source
    seen
    stdlib-roots
    expected-module
    (compiler-cfg-empty)))

;; Parse a module source directly in the active (program-lifetime) arena.
;;
;; A scratch-arena variant used to parse large files into a throwaway arena and
;; `clone` the result back out to cap cold self-build peak memory. That cannot
;; work with the flat-node AST: `AstExpr`/`AstType`/`SpannedSexpr` nodes live in
;; persistent GLOBAL pools, not the active arena, so destroying the scratch arena
;; left the cloned program pointing at pool slots whose backing list/string data
;; had been freed -- a segfault on the next self-build. The scratch path was
;; already disabled (its size threshold was raised past any real input); it has
;; now been removed. Recovering its memory benefit needs pool-aware reclamation
;; (e.g. truncating the node pools after escaping), not arena destruction.
(define (compiler-load-parse-source-diagnostic-escaping
  [path : String]
  [source : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgramDiagnostic
  (parse-ast-source-diagnostic-with-cfg path source cfgs))

(define (compiler-load-parse-source-diagnostic-escaping-with-pools
  [path : String]
  [source : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (parse-ast-source-diagnostic-with-cfg-and-pools path source cfgs pools))

(define (compiler-load-parse-file-diagnostic-escaping
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgramDiagnostic
  (let
    [source : String (io.read-file path)]
    (compiler-load-parse-source-diagnostic-escaping path source cfgs)))

(define (compiler-load-parse-file-diagnostic-escaping-with-pools
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (let
    [source : String (io.read-file path)]
    (compiler-load-parse-source-diagnostic-escaping-with-pools
      path
      source
      cfgs
      pools)))

(define (compiler-load-cache-program-result
  [key : String]
  [result : ResultAstProgramDiagnostic]) : ResultAstProgramDiagnostic
  (match result
    [(ResultAstProgramDiagnostic.Ok program)
      (begin
        (if (compiler-load-program-cache-store key program)
          (compiler-load-session-note-persistent!)
          unit)
        (ResultAstProgramDiagnostic.Ok program))]
    [(ResultAstProgramDiagnostic.Err diag)
      (ResultAstProgramDiagnostic.Err diag)]))

(define (compiler-load-cache-program-result-with-pools
  [key : String]
  [result : ResultAstProgramDiagnostic]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (match result
    [(ResultAstProgramDiagnostic.Ok program)
      (begin
        (if (compiler-load-program-cache-store key program)
          (compiler-load-session-note-persistent-with-pools! pools)
          unit)
        (ResultAstProgramDiagnostic.Ok program))]
    [(ResultAstProgramDiagnostic.Err diag)
      (ResultAstProgramDiagnostic.Err diag)]))

(define (compiler-load-parse-file-diagnostic-cache-miss
  [key : String]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgramDiagnostic
  (if (compiler-load-program-cache-can-store key)
    (let
      [prev-arena : i64 (arena.tl_arena_current)]
      [loaded : ResultAstProgramDiagnostic
        (begin
          (unsafe
            (arena.tl_arena_set node-pool-base-arena))
          (let
            [persistent-key : String (string.copy (& key))]
            [parsed : ResultAstProgramDiagnostic
              (compiler-load-parse-file-diagnostic-escaping path cfgs)]
            (begin
              (unsafe
                (arena.tl_arena_set prev-arena))
              (compiler-load-cache-program-result persistent-key parsed))))]
      loaded)
    (compiler-load-parse-file-diagnostic-escaping path cfgs)))

(define (compiler-load-parse-file-diagnostic-cache-miss-with-pools
  [key : String]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (if (compiler-load-program-cache-can-store key)
    (let
      [prev-arena : i64 (arena.tl_arena_current)]
      [loaded : ResultAstProgramDiagnostic
        (begin
          (unsafe
            (arena.tl_arena_set (ast-node-pool-context-base-arena pools)))
          (let
            [persistent-key : String (string.copy (& key))]
            [parsed : ResultAstProgramDiagnostic
              (compiler-load-parse-file-diagnostic-escaping-with-pools
                path
                cfgs
                pools)]
            (begin
              (unsafe
                (arena.tl_arena_set prev-arena))
              (compiler-load-cache-program-result-with-pools
                persistent-key
                parsed
                pools))))]
      loaded)
    (compiler-load-parse-file-diagnostic-escaping-with-pools path cfgs pools)))

(define (compiler-load-ast-program-result-ok?
  [result : ResultAstProgramDiagnostic]) : bool
  (match result
    [(ResultAstProgramDiagnostic.Ok _) true]
    [(ResultAstProgramDiagnostic.Err _) false]))

(define (compiler-load-parse-file-diagnostic-cache-miss-local
  [key : String]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgramDiagnostic
  (if (compiler-load-program-cache-can-store key)
    (let
      [start-nodes : i64 (ast-node-pool-len)]
      [cold : ResultAstProgramDiagnostic
        (compiler-load-parse-file-diagnostic-escaping path cfgs)]
      [node-delta : i64 (- (ast-node-pool-len) start-nodes)]
      (if (and
        (compiler-load-ast-program-result-ok? cold)
        (<= node-delta compiler-load-local-program-cache-node-limit))
        (compiler-load-parse-file-diagnostic-cache-miss key path cfgs)
        cold))
    (compiler-load-parse-file-diagnostic-escaping path cfgs)))

(define (compiler-load-parse-file-diagnostic-cache-miss-local-with-pools
  [key : String]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (if (compiler-load-program-cache-can-store key)
    (let
      [start-nodes : i64 (ast-node-pool-context-expr-len pools)]
      [cold : ResultAstProgramDiagnostic
        (compiler-load-parse-file-diagnostic-escaping-with-pools
          path
          cfgs
          pools)]
      [node-delta : i64 (- (ast-node-pool-context-expr-len pools) start-nodes)]
      (if (and
        (compiler-load-ast-program-result-ok? cold)
        (<= node-delta compiler-load-local-program-cache-node-limit))
        (compiler-load-parse-file-diagnostic-cache-miss-with-pools
          key
          path
          cfgs
          pools)
        cold))
    (compiler-load-parse-file-diagnostic-escaping-with-pools path cfgs pools)))

(define (compiler-load-parse-file-diagnostic-admit-only
  [key : String]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgramDiagnostic
  (let
    [parsed : ResultAstProgramDiagnostic
      (compiler-load-parse-file-diagnostic-escaping path cfgs)]
    (begin
      (match parsed
        [(ResultAstProgramDiagnostic.Ok _)
          (if (compiler-load-program-admission-record-persistent key)
            unit
            unit)]
        [(ResultAstProgramDiagnostic.Err _) unit])
      parsed)))

(define (compiler-load-parse-file-diagnostic-admit-only-with-pools
  [key : String]
  [path : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (let
    [parsed : ResultAstProgramDiagnostic
      (compiler-load-parse-file-diagnostic-escaping-with-pools path cfgs pools)]
    (begin
      (match parsed
        [(ResultAstProgramDiagnostic.Ok _)
          (if (compiler-load-program-admission-record-persistent key)
            unit
            unit)]
        [(ResultAstProgramDiagnostic.Err _) unit])
      parsed)))

(define (compiler-load-parse-file-diagnostic-session
  [path : String]
  [stdlib-roots : vector.StringVec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgramDiagnostic
  (if (and
    (compiler-load-session-cache-enabled?)
    (compiler-load-session-program-cache-enabled?)
    (compiler-load-session-file-cacheable? path stdlib-roots))
    (let
      [key : String (compiler-load-program-cache-key "file" path cfgs)]
      (match (compiler-load-program-cache-lookup key)
        [(CompilerLoadProgramCacheHit program)
          (begin
            (compiler-load-program-cache-note-hit!)
            (ResultAstProgramDiagnostic.Ok program))]
        [(CompilerLoadProgramCacheMiss)
          (begin
            (compiler-load-program-cache-note-miss!)
            (if (or
              (compiler-load-session-file-cache-immediate? path stdlib-roots)
              (compiler-load-program-admission-contains? key))
              (if (compiler-load-session-file-cache-immediate?
                path
                stdlib-roots)
                (compiler-load-parse-file-diagnostic-cache-miss key path cfgs)
                (compiler-load-parse-file-diagnostic-cache-miss-local
                  key
                  path
                  cfgs))
              (compiler-load-parse-file-diagnostic-admit-only key path cfgs)))]))
    (compiler-load-parse-file-diagnostic-escaping path cfgs)))

(define (compiler-load-parse-file-diagnostic-session-with-pools
  [path : String]
  [stdlib-roots : vector.StringVec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (if (and
    (compiler-load-session-cache-enabled?)
    (compiler-load-session-program-cache-enabled?)
    (compiler-load-session-file-cacheable? path stdlib-roots))
    (let
      [key : String (compiler-load-program-cache-key "file" path cfgs)]
      (match (compiler-load-program-cache-lookup key)
        [(CompilerLoadProgramCacheHit program)
          (begin
            (compiler-load-program-cache-note-hit!)
            (ResultAstProgramDiagnostic.Ok program))]
        [(CompilerLoadProgramCacheMiss)
          (begin
            (compiler-load-program-cache-note-miss!)
            (if (or
              (compiler-load-session-file-cache-immediate? path stdlib-roots)
              (compiler-load-program-admission-contains? key))
              (if (compiler-load-session-file-cache-immediate?
                path
                stdlib-roots)
                (compiler-load-parse-file-diagnostic-cache-miss-with-pools
                  key
                  path
                  cfgs
                  pools)
                (compiler-load-parse-file-diagnostic-cache-miss-local-with-pools
                  key
                  path
                  cfgs
                  pools))
              (compiler-load-parse-file-diagnostic-admit-only-with-pools
                key
                path
                cfgs
                pools)))]))
    (compiler-load-parse-file-diagnostic-escaping-with-pools path cfgs pools)))

(define (compiler-load-parse-embedded-source-diagnostic-cache-miss
  [key : String]
  [path : String]
  [source : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgramDiagnostic
  (if (compiler-load-program-cache-can-store key)
    (let
      [prev-arena : i64 (arena.tl_arena_current)]
      [loaded : ResultAstProgramDiagnostic
        (begin
          (unsafe
            (arena.tl_arena_set node-pool-base-arena))
          (let
            [persistent-key : String (string.copy (& key))]
            [parsed : ResultAstProgramDiagnostic
              (compiler-load-parse-source-diagnostic-escaping path source cfgs)]
            (begin
              (unsafe
                (arena.tl_arena_set prev-arena))
              (compiler-load-cache-program-result persistent-key parsed))))]
      loaded)
    (compiler-load-parse-source-diagnostic-escaping path source cfgs)))

(define (compiler-load-parse-embedded-source-diagnostic-cache-miss-with-pools
  [key : String]
  [path : String]
  [source : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (if (compiler-load-program-cache-can-store key)
    (let
      [prev-arena : i64 (arena.tl_arena_current)]
      [loaded : ResultAstProgramDiagnostic
        (begin
          (unsafe
            (arena.tl_arena_set (ast-node-pool-context-base-arena pools)))
          (let
            [persistent-key : String (string.copy (& key))]
            [parsed : ResultAstProgramDiagnostic
              (compiler-load-parse-source-diagnostic-escaping-with-pools
                path
                source
                cfgs
                pools)]
            (begin
              (unsafe
                (arena.tl_arena_set prev-arena))
              (compiler-load-cache-program-result-with-pools
                persistent-key
                parsed
                pools))))]
      loaded)
    (compiler-load-parse-source-diagnostic-escaping-with-pools
      path
      source
      cfgs
      pools)))

(define (compiler-load-parse-embedded-source-diagnostic-session
  [path : String]
  [source : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgramDiagnostic
  (if (and
    (compiler-load-session-cache-enabled?)
    (compiler-load-session-program-cache-enabled?))
    (let
      [key : String (compiler-load-program-cache-key "embedded" path cfgs)]
      (match (compiler-load-program-cache-lookup key)
        [(CompilerLoadProgramCacheHit program)
          (begin
            (compiler-load-program-cache-note-hit!)
            (ResultAstProgramDiagnostic.Ok program))]
        [(CompilerLoadProgramCacheMiss)
          (begin
            (compiler-load-program-cache-note-miss!)
            (compiler-load-parse-embedded-source-diagnostic-cache-miss
              key
              path
              source
              cfgs))]))
    (compiler-load-parse-source-diagnostic-escaping path source cfgs)))

(define (compiler-load-parse-embedded-source-diagnostic-session-with-pools
  [path : String]
  [source : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (if (and
    (compiler-load-session-cache-enabled?)
    (compiler-load-session-program-cache-enabled?))
    (let
      [key : String (compiler-load-program-cache-key "embedded" path cfgs)]
      (match (compiler-load-program-cache-lookup key)
        [(CompilerLoadProgramCacheHit program)
          (begin
            (compiler-load-program-cache-note-hit!)
            (ResultAstProgramDiagnostic.Ok program))]
        [(CompilerLoadProgramCacheMiss)
          (begin
            (compiler-load-program-cache-note-miss!)
            (compiler-load-parse-embedded-source-diagnostic-cache-miss-with-pools
              key
              path
              source
              cfgs
              pools))]))
    (compiler-load-parse-source-diagnostic-escaping-with-pools
      path
      source
      cfgs
      pools)))

(define (compiler-load-source-with-paths-and-roots-expect-cfg
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-load-parse-source-diagnostic-escaping path source cfgs)
    [(ResultAstProgramDiagnostic.Ok program)
      (compiler-load-program-with-paths-and-roots-expect-cfg
        path
        program
        seen
        stdlib-roots
        expected-module
        cfgs)]
    [(ResultAstProgramDiagnostic.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-load-source-with-paths-and-roots-expect-cfg-with-pools
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (compiler-load-parse-source-diagnostic-escaping-with-pools
    path
    source
    cfgs
    pools)
    [(ResultAstProgramDiagnostic.Ok program)
      (compiler-load-program-with-paths-and-roots-expect-cfg-with-pools
        path
        program
        seen
        stdlib-roots
        expected-module
        cfgs
        pools)]
    [(ResultAstProgramDiagnostic.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-load-source
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]) : ResultCompilerLoad
  (compiler-load-drop-paths (compiler-load-source-with-paths path source seen)))

(define (compiler-load-source-with-roots
  [path : String]
  [source : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-source-with-paths-and-roots path source seen stdlib-roots)))

(define (compiler-load-file-with-paths
  [path : String]
  [seen : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots path seen (vector.string-vec-new)))

(define (compiler-load-file-with-paths-and-roots
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect
    path
    seen
    stdlib-roots
    AstMaybeModuleName.No))

(define (compiler-load-file-with-paths-and-roots-cfg
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg
    path
    seen
    stdlib-roots
    AstMaybeModuleName.No
    cfgs))

(define (compiler-load-file-with-paths-and-roots-cfg-with-pools
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-with-pools
    path
    seen
    stdlib-roots
    AstMaybeModuleName.No
    cfgs
    pools))

(define (compiler-load-file-with-paths-and-roots-expect
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg
    path
    seen
    stdlib-roots
    expected-module
    (compiler-cfg-empty)))

(define (compiler-load-bind-path-dedup
  [loaded : ResultCompilerLoadWithPaths]
  [path-dedup : bool]
  [path-key : String]) : ResultCompilerLoadWithPaths
  (match loaded
    [(ResultCompilerLoadWithPaths.Ok decls paths modules loaded-seen)
      (ResultCompilerLoadWithPaths.Ok
        decls
        paths
        modules
        (if path-dedup
          (sym_i64_env.sym-i64-bind loaded-seen path-key 1)
          loaded-seen))]
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (compiler-load-file-with-paths-and-roots-expect-cfg
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root
    path
    seen
    stdlib-roots
    expected-module
    (compiler-load-dirname path)
    cfgs))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-with-pools
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root-with-pools
    path
    seen
    stdlib-roots
    expected-module
    (compiler-load-dirname path)
    cfgs
    pools))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-root
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current
    path
    seen
    stdlib-roots
    expected-module
    import-root
    cfgs
    true))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-root-with-pools
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-with-pools
    path
    seen
    stdlib-roots
    expected-module
    import-root
    cfgs
    true
    pools))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-root-import-with-pools
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [kind : AstImportKind]
  [import-path : String]
  [expected-module : AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [context-module : String]) : ResultCompilerLoadWithPaths
  (let
    [fallback : String
      (compiler-load-canonical-module-id-from-import kind import-path path)]
    [source-module : String
      (compiler-load-canonical-source-module-from-import
        kind
        import-path
        path
        expected-module
        context-module)]
    (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-fallback-with-pools
      path
      seen
      stdlib-roots
      expected-module
      import-root
      cfgs
      true
      pools
      (compiler-load-seen-path-key-in-module path context-module)
      fallback
      source-module)))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-current : bool]) : ResultCompilerLoadWithPaths
  (let
    [path-key : String (compiler-load-seen-path-key path)]
    [path-dedup : bool (compiler-load-no-expected-module? expected-module)]
    (if (and path-dedup (sym_i64_env.sym-i64-contains seen path-key))
      (ResultCompilerLoadWithPaths.Ok
        (ast-decl-list-new)
        (ast-decl-path-list-new)
        (ast-decl-module-list-new)
        seen)
      (let
        [parse-cfgs : sym_i64_env.SymI64Env
          (compiler-load-stdlib-private-cfgs
            path
            stdlib-roots
            expected-module
            cfgs)]
        (if (io.file-exists? path)
          (match (if cache-current
            (compiler-load-parse-file-diagnostic-session
              path
              stdlib-roots
              parse-cfgs)
            (compiler-load-parse-file-diagnostic-escaping path parse-cfgs))
            [(ResultAstProgramDiagnostic.Ok program)
              (compiler-load-bind-path-dedup
                (compiler-load-program-with-paths-and-roots-expect-cfg-root
                  path
                  program
                  seen
                  stdlib-roots
                  expected-module
                  import-root
                  parse-cfgs)
                path-dedup
                path-key)]
            [(ResultAstProgramDiagnostic.Err diag)
              (ResultCompilerLoadWithPaths.Err diag)])
          (match (compiler-load-embedded-stdlib-source-for-path path)
            [(CompilerEmbeddedStdlibSomeSource source)
              (match (if cache-current
                (compiler-load-parse-embedded-source-diagnostic-session
                  path
                  source
                  parse-cfgs)
                (compiler-load-parse-source-diagnostic-escaping
                  path
                  source
                  parse-cfgs))
                [(ResultAstProgramDiagnostic.Ok program)
                  (compiler-load-bind-path-dedup
                    (compiler-load-program-with-paths-and-roots-expect-cfg-root
                      path
                      program
                      seen
                      stdlib-roots
                      expected-module
                      import-root
                      parse-cfgs)
                    path-dedup
                    path-key)]
                [(ResultAstProgramDiagnostic.Err diag)
                  (ResultCompilerLoadWithPaths.Err diag)])]
            [(CompilerEmbeddedStdlibNoSource)
              (ResultCompilerLoadWithPaths.Err
                (box
                  (compiler-diagnostic-at-start
                    path
                    (string.append "compiler-load: cannot read import " path))))]))))))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-with-pools
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-current : bool]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-fallback-with-pools
    path
    seen
    stdlib-roots
    expected-module
    import-root
    cfgs
    cache-current
    pools
    (compiler-load-seen-path-key path)
    (compiler-load-canonical-module-id-from-path path)
    ""))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-fallback-with-pools
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [import-root : String]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-current : bool]
  [pools : AstNodePoolContext]
  [path-key : String]
  [module-id-fallback : String]
  [source-module-fallback : String]) : ResultCompilerLoadWithPaths
  (let
    [path-dedup : bool (compiler-load-no-expected-module? expected-module)]
    (if (and path-dedup (sym_i64_env.sym-i64-contains seen path-key))
      (ResultCompilerLoadWithPaths.Ok
        (ast-decl-list-new)
        (ast-decl-path-list-new)
        (ast-decl-module-list-new)
        seen)
      (let
        [parse-cfgs : sym_i64_env.SymI64Env
          (compiler-load-stdlib-private-cfgs
            path
            stdlib-roots
            expected-module
            cfgs)]
        (if (io.file-exists? path)
          (match (if cache-current
            (compiler-load-parse-file-diagnostic-session-with-pools
              path
              stdlib-roots
              parse-cfgs
              pools)
            (compiler-load-parse-file-diagnostic-escaping-with-pools
              path
              parse-cfgs
              pools))
            [(ResultAstProgramDiagnostic.Ok program)
              (compiler-load-bind-path-dedup
                (compiler-load-program-with-paths-and-roots-expect-cfg-root-fallback-with-pools
                  path
                  program
                  seen
                  stdlib-roots
                  expected-module
                  import-root
                  parse-cfgs
                  pools
                  module-id-fallback
                  source-module-fallback)
                path-dedup
                path-key)]
            [(ResultAstProgramDiagnostic.Err diag)
              (ResultCompilerLoadWithPaths.Err diag)])
          (match (compiler-load-embedded-stdlib-source-for-path path)
            [(CompilerEmbeddedStdlibSomeSource source)
              (match (if cache-current
                (compiler-load-parse-embedded-source-diagnostic-session-with-pools
                  path
                  source
                  parse-cfgs
                  pools)
                (compiler-load-parse-source-diagnostic-escaping-with-pools
                  path
                  source
                  parse-cfgs
                  pools))
                [(ResultAstProgramDiagnostic.Ok program)
                  (compiler-load-bind-path-dedup
                    (compiler-load-program-with-paths-and-roots-expect-cfg-root-fallback-with-pools
                      path
                      program
                      seen
                      stdlib-roots
                      expected-module
                      import-root
                      parse-cfgs
                      pools
                      module-id-fallback
                      source-module-fallback)
                    path-dedup
                    path-key)]
                [(ResultAstProgramDiagnostic.Err diag)
                  (ResultCompilerLoadWithPaths.Err diag)])]
            [(CompilerEmbeddedStdlibNoSource)
              (ResultCompilerLoadWithPaths.Err
                (box
                  (compiler-diagnostic-at-start
                    path
                    (string.append "compiler-load: cannot read import " path))))]))))))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-fallback
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]
  [module-id-fallback : String]
  [source-module-fallback : String]) : ResultCompilerLoadWithPaths
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [result : ResultCompilerLoadWithPaths
      (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-fallback-with-pools
        path
        seen
        stdlib-roots
        expected-module
        (compiler-load-dirname path)
        cfgs
        true
        pools
        (compiler-load-seen-path-key path)
        module-id-fallback
        source-module-fallback)]
    (begin
      (ast-node-pool-context-install! pools)
      result)))

(define (compiler-load-entry-file-with-paths-and-roots-cfg
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current
    path
    seen
    stdlib-roots
    AstMaybeModuleName.No
    (compiler-load-dirname path)
    cfgs
    false))

(define (compiler-load-entry-file-with-paths-and-roots-cfg-with-pools
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-with-pools
    path
    seen
    stdlib-roots
    AstMaybeModuleName.No
    (compiler-load-dirname path)
    cfgs
    false
    pools))

(define (compiler-load-file [path : String] [seen : sym_i64_env.SymI64Env]) : ResultCompilerLoad
  (compiler-load-drop-paths (compiler-load-file-with-paths path seen)))

(define (compiler-load-file-with-roots
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-file-with-paths-and-roots path seen stdlib-roots)))

(define (compiler-load-package-hex-digit [n : i64]) : String
  (cond
    [(= n 0) "0"]
    [(= n 1) "1"]
    [(= n 2) "2"]
    [(= n 3) "3"]
    [(= n 4) "4"]
    [(= n 5) "5"]
    [(= n 6) "6"]
    [(= n 7) "7"]
    [(= n 8) "8"]
    [(= n 9) "9"]
    [(= n 10) "a"]
    [(= n 11) "b"]
    [(= n 12) "c"]
    [(= n 13) "d"]
    [(= n 14) "e"]
    [else "f"]))

(define (compiler-load-package-hex-byte [n : i64]) : String
  (string.append
    (compiler-load-package-hex-digit (/ n 16))
    (compiler-load-package-hex-digit (% n 16))))

(define (compiler-load-package-symbol-char
  [text : String]
  [idx : i64]
  [c : char]) : String
  (cond
    [(or
        (and (>= c 'A') (<= c 'Z'))
        (and (>= c 'a') (<= c 'z'))
        (and (>= c '0') (<= c '9'))
        (= c '_'))
      (string.substring text idx 1)]
    [(= c '-') "_"]
    [(= c '?') "_question"]
    [(= c '!') "_bang"]
    [(= c '+') "_plus"]
    [(= c '*') "_star"]
    [(= c '/') "_slash"]
    [(= c '=') "_eq"]
    [(= c '<') "_lt"]
    [(= c '>') "_gt"]
    [(= c ':') "_colon"]
    [else
      (string.append
        "_u"
        (compiler-load-package-hex-byte (compiler-load-char-code-at text idx)))]))

(define (compiler-load-package-asm-safe-symbol [name : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string.string-length name)]
    [out : String ""]
    [emitted : bool false]
    [pending-separator : bool false]
    (begin
      (while (< i n)
        (if (compiler-load-package-tl-extension-at? name i)
          (set! i (+ i 3))
          (let
            [c : char (string.string-ref name i)]
            (if (compiler-load-package-symbol-separator? c)
              (begin
                (if emitted
                  (set! pending-separator true)
                  unit)
                (set! i (+ i 1)))
              (begin
                (if pending-separator
                  (begin
                    (set! out (string.concat3 out "_" ""))
                    (set! pending-separator false))
                  unit)
                (set!
                  out
                  (string.concat3
                    out
                    (compiler-load-package-symbol-char name i c)
                    ""))
                (set! emitted true)
                (set! i (+ i 1)))))))
      out)))

(define (compiler-load-package-symbol-separator? [c : char]) : bool
  (or (= c '/') (= c '\\') (= c ':') (= c '.')))

(define (compiler-load-package-tl-extension-at? [name : String] [idx : i64]) : bool
  (let
    [n : i64 (string.string-length name)]
    [after : i64 (+ idx 3)]
    (and
      (<= after n)
      (= (string.string-ref name idx) '.')
      (= (string.string-ref name (+ idx 1)) 't')
      (= (string.string-ref name (+ idx 2)) 'l')
      (or
        (= after n)
        (compiler-load-package-symbol-separator? (string.string-ref name after))))))

(define (compiler-load-package-user-symbol [name : String]) : String
  (if (string.eq name "main")
    "main"
    (string.append "_tl_" (compiler-load-package-asm-safe-symbol name))))

(define (compiler-load-package-module-key [module : String] [name : String]) : String
  (if (= (string.string-length module) 0)
    name
    (string.append module (string.append "/" name))))

(define (compiler-load-package-module-id
  [entry-path : String]
  [decl-path : String]) : String
  (let
    [entry-path : String (compiler-load-normalize-path entry-path)]
    [decl-path : String (compiler-load-normalize-path decl-path)]
    [base : String (compiler-load-dirname entry-path)]
    [base-len : i64 (string.string-length base)]
    [decl-len : i64 (string.string-length decl-path)]
    (if (and (> base-len 0) (compiler-load-string-prefix-at? decl-path base 0))
      (string.substring decl-path base-len (- decl-len base-len))
      decl-path)))

(define (compiler-load-package-module-logical-name
  [entry-path : String]
  [decl-path : String]
  [source-name : String]) : String
  (if (and
    (string.eq
      (compiler-load-normalize-path decl-path)
      (compiler-load-normalize-path entry-path))
    (string.eq source-name "main"))
    "main"
    (string.append
      (string.append
        (compiler-load-package-module-id entry-path decl-path)
        "::")
      source-name)))

(define (compiler-load-package-entry-main?
  [entry-path : String]
  [decl-path : String]
  [_module : String]
  [source-name : String]) : bool
  (and
    (string.eq
      (compiler-load-normalize-path decl-path)
      (compiler-load-normalize-path entry-path))
    (string.eq source-name "main")))

(define (compiler-load-root-prefix [root : String]) : String
  (compiler-load-join-root-path root ""))

(define (compiler-load-path-under-root? [path : String] [root : String]) : bool
  (let
    [prefix : String (compiler-load-root-prefix root)]
    [prefix-len : i64 (string.string-length prefix)]
    (and (> prefix-len 0) (compiler-load-string-prefix-at? path prefix 0))))

(define (compiler-load-owned-path-from-root
  [owner : String]
  [root : String]
  [path : String]) : String
  (let
    [prefix : String (compiler-load-root-prefix root)]
    [prefix-len : i64 (string.string-length prefix)]
    [path-len : i64 (string.string-length path)]
    (if (= prefix-len 0)
      (if (compiler-load-absolute-path? path)
        path
        (string.append
          owner
          (string.append "/" (compiler-load-normalize-path path))))
      (if (compiler-load-path-under-root? path root)
        (string.append
          owner
          (string.append
            "/"
            (string.substring path prefix-len (- path-len prefix-len))))
        path))))

(define (compiler-load-stdlib-owner-root? [root : String]) : bool
  (let
    [normalized : String (compiler-load-normalize-path root)]
    [base : String (fs.basename (& normalized))]
    (string.eq base "stdlib")))

(define (compiler-load-stdlib-owned-path-from-roots
  [path : String]
  [stdlib-roots : vector.StringVec]) : String
  (let
    [roots : vector.StringVec (compiler-load-roots-with-env stdlib-roots)]
    [i : i64 0]
    [n : i64 (vector.string-vec-len roots)]
    [found : bool false]
    [out : String ""]
    (begin
      (while (and (not found) (< i n))
        (let
          [root : String (vector.string-vec-get roots i "")]
          [prefix : String (compiler-load-root-prefix root)]
          [prefix-len : i64 (string.string-length prefix)]
          [path-len : i64 (string.string-length path)]
          (if (and
            (compiler-load-stdlib-owner-root? root)
            (> prefix-len 0)
            (compiler-load-string-prefix-at? path prefix 0))
            (begin
              (set! found true)
              (set!
                out
                (string.append
                  "stdlib/"
                  (string.substring path prefix-len (- path-len prefix-len)))))
            (set! i (+ i 1)))))
      (if found
        out
        path))))

(define (compiler-load-package-owned-path
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : vector.StringVec]
  [path : String]) : String
  (let
    [stdlib-path : String
      (if (compiler-load-stdlib-import? path)
        (compiler-load-normalize-path path)
        (compiler-load-stdlib-owned-path-from-roots path stdlib-roots))]
    (if (compiler-load-stdlib-import? stdlib-path)
      stdlib-path
      (if (= (string.string-length package-owner) 0)
        path
        (compiler-load-owned-path-from-root package-owner package-root path)))))

(defenum CompilerLoadOwnedPathCacheResult
  (CompilerLoadOwnedPathCacheResult hashmap.StringStringMap String))

(define (compiler-load-package-owned-path-cached
  [cache : hashmap.StringStringMap]
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : vector.StringVec]
  [path : String]) : CompilerLoadOwnedPathCacheResult
  (match (hashmap.string-string-map-get cache path)
    [(hashmap.StringStringMapFound owned)
      (CompilerLoadOwnedPathCacheResult cache owned)]
    [(hashmap.StringStringMapMissing)
      (let
        [owned : String
          (compiler-load-package-owned-path
            package-owner
            package-root
            stdlib-roots
            path)]
        (CompilerLoadOwnedPathCacheResult
          (hashmap.string-string-map-put cache path owned)
          owned))]))

(define (compiler-load-package-decl-logical-name
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [source-name : String]) : String
  (if (compiler-load-package-entry-main?
    entry-path
    decl-path
    module
    source-name)
    "main"
    (if (string.eq module "")
      (compiler-load-package-module-logical-name
        entry-path
        decl-path
        source-name)
      (compiler-load-package-module-logical-name
        entry-path
        decl-path
        (compiler-load-package-module-key module source-name)))))

(define (compiler-load-param-type-list [params : AstParamList]) : AstTypeList
  (match params
    [(AstParamList.Nil) AstTypeList.Nil]
    [(AstParamList.Cons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam.Param _ ty _)
            (ast-type-cons ty (compiler-load-param-type-list rest))]))]))

(define (compiler-load-package-def-fn-extern
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : vector.StringVec]
  [decl-path : String]
  [module : String]
  [name : i64]
  [params : AstParamList]
  [ret : AstType]) : AstDecl
  (let
    [name-str : String (intern-str name)]
    [logical-path : String
      (compiler-load-package-owned-path
        package-owner
        package-root
        stdlib-roots
        decl-path)]
    [logical : String
      (compiler-load-package-decl-logical-name "" logical-path module name-str)]
    (AstDecl.Extern
      name
      (AstExternKind.Function)
      (AstExternMetadata.Metadata
        (AstExternAbi.C)
        (compiler-load-package-user-symbol logical)
        AstExternLinkInputList.Nil
        false)
      (ast-ty-func (compiler-load-param-type-list params) ret))))

(define (compiler-load-package-transform-decl
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : vector.StringVec]
  [decl-path : String]
  [module : String]
  [decl : AstDecl]) : CompilerLoadMaybeDecl
  (match decl
    [(AstDecl.DefFn name params ret _ _)
      (CompilerLoadSomeDecl
        (compiler-load-package-def-fn-extern
          package-owner
          package-root
          stdlib-roots
          decl-path
          module
          name
          params
          ret))]
    [(AstDecl.DefStruct _ _ _ _) (CompilerLoadSomeDecl decl)]
    [(AstDecl.Module _) (CompilerLoadSomeDecl decl)]
    [(AstDecl.Unsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (match (compiler-load-package-transform-decl
          package-owner
          package-root
          stdlib-roots
          decl-path
          module
          inner)
          [(CompilerLoadSomeDecl transformed)
            (CompilerLoadSomeDecl (ast-decl-unsafe transformed))]
          [(CompilerLoadNoDecl) (CompilerLoadNoDecl)]))]
    [(AstDecl.ComptimeDecl meta template-box)
      (let
        [template : AstDecl (box-get template-box)]
        (match (compiler-load-package-transform-decl
          package-owner
          package-root
          stdlib-roots
          decl-path
          module
          template)
          [(CompilerLoadSomeDecl transformed)
            (CompilerLoadSomeDecl
              (ast-decl-comptime-decl-with-meta meta transformed))]
          [(CompilerLoadNoDecl) (CompilerLoadNoDecl)]))]
    [_ (CompilerLoadNoDecl)]))

(define (compiler-load-path-list-head-or
  [paths : AstDeclPathList]
  [fallback : String]) : String
  (match (ast-decl-path-list-step paths)
    [(AstDeclPathListStep.Cons path _) path]
    [(AstDeclPathListStep.Nil) fallback]))

(define (compiler-load-path-list-tail [paths : AstDeclPathList]) : AstDeclPathList
  (match (ast-decl-path-list-step paths)
    [(AstDeclPathListStep.Cons _ rest)
      (let
        [rest : AstDeclPathList rest]
        rest)]
    [(AstDeclPathListStep.Nil) (ast-decl-path-list-new)]))

(define (compiler-load-package-owned-decl-entry-main?
  [entry-path : String]
  [module : String]
  [decl-path : String]
  [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.DefFn name _ _ _ _)
      (compiler-load-package-entry-main?
        entry-path
        decl-path
        module
        (intern-str name))]
    [(AstDecl.Unsafe inner-box)
      (compiler-load-package-owned-decl-entry-main?
        entry-path
        module
        decl-path
        (box-get inner-box))]
    [_ false]))

(define (compiler-load-package-owned-paths-for-decls-in-module
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : vector.StringVec]
  [entry-path : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [module : String]) : AstDeclPathList
  (let
    [count : i64 (ast-decl-list-len (& decls))]
    [decl-cursor : AstDeclList decls]
    [path-cursor : AstDeclPathList paths]
    [current-module : String module]
    [out : AstDeclPathList (ast-decl-path-list-with-capacity count)]
    [owned-cache : hashmap.StringStringMap
      (hashmap.string-string-map-with-capacity (+ (* count 2) 16))]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast-decl-list-step decl-cursor)
          [(AstDeclListStep.Nil) (set! done true)]
          [(AstDeclListStep.Cons decl rest)
            (let
              [decl-path : String
                (compiler-load-path-list-head-or path-cursor entry-path)]
              [owned-path : String
                (if (compiler-load-package-owned-decl-entry-main?
                  entry-path
                  current-module
                  decl-path
                  decl)
                  ""
                  (match (compiler-load-package-owned-path-cached
                    owned-cache
                    package-owner
                    package-root
                    stdlib-roots
                    decl-path)
                    [(CompilerLoadOwnedPathCacheResult next-cache cached-path)
                      (begin
                        (set! owned-cache next-cache)
                        cached-path)]))]
              (begin
                (ast-decl-path-list-push (&mut out) owned-path)
                (match decl
                  [(AstDecl.Module name)
                    (set! current-module (intern-str name))]
                  [_ unit])
                (set! decl-cursor rest)
                (set! path-cursor (compiler-load-path-list-tail path-cursor))))]))
      out)))

(define (compiler-load-package-owned-paths-for-decls
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : vector.StringVec]
  [entry-path : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]) : AstDeclPathList
  (compiler-load-package-owned-paths-for-decls-in-module
    package-owner
    package-root
    stdlib-roots
    entry-path
    decls
    paths
    ""))

(define (compiler-load-package-extern-decls
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : vector.StringVec]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [seen : sym_i64_env.SymI64Env]
  [module : String]) : ResultCompilerLoadWithPaths
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil)
      (ResultCompilerLoadWithPaths.Ok
        (ast-decl-list-new)
        (ast-decl-path-list-new)
        (ast-decl-module-list-new)
        seen)]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        [decl-path : String
          (compiler-load-path-list-head-or paths package-root)]
        [owned-decl-path : String
          (compiler-load-package-owned-path
            package-owner
            package-root
            stdlib-roots
            decl-path)]
        [rest-paths : AstDeclPathList (compiler-load-path-list-tail paths)]
        [next-module : String
          (match decl
            [(AstDecl.Module name) (intern-str name)]
            [_ module])]
        (match (compiler-load-package-extern-decls
          package-owner
          package-root
          stdlib-roots
          rest
          rest-paths
          seen
          next-module)
          [(ResultCompilerLoadWithPaths.Ok
              rest-decls
              rest-decl-paths
              rest-modules
              rest-seen)
            (match (compiler-load-package-transform-decl
              package-owner
              package-root
              stdlib-roots
              decl-path
              module
              decl)
              [(CompilerLoadSomeDecl transformed)
                (ResultCompilerLoadWithPaths.Ok
                  (ast-decl-list-prepend-builder transformed rest-decls)
                  (ast-decl-path-list-prepend-builder
                    owned-decl-path
                    rest-decl-paths)
                  (ast-decl-module-list-prepend-builder module rest-modules)
                  rest-seen)]
              [(CompilerLoadNoDecl)
                (ResultCompilerLoadWithPaths.Ok
                  rest-decls
                  rest-decl-paths
                  rest-modules
                  rest-seen)])]
          [(ResultCompilerLoadWithPaths.Err diag)
            (ResultCompilerLoadWithPaths.Err diag)]))]))

(define (compiler-load-package-entry-for-source [source-path : String]) : ResultCompilerLoadPackageEntry
  (match (compiler-load-discover-manifest source-path)
    [(CompilerLoadNoPath)
      (ResultCompilerLoadPackageEntry.Err
        (string.append
          "compiler-load: dependency package manifest not found for "
          source-path))]
    [(CompilerLoadSomePath manifest-path)
      (match (compiler-load-parse-manifest-diagnostic-infer-kind
        manifest-path
        (io.read-file manifest-path))
        [(ResultCompilerPkgManifestDiagnostic.Err diag)
          (ResultCompilerLoadPackageEntry.Err
            (string.append
              "compiler-load: invalid dependency package manifest '"
              (string.append
                manifest-path
                (string.append
                  "': "
                  (compiler-diagnostic-message (box-get diag))))))]
        [(ResultCompilerPkgManifestDiagnostic.Ok manifest)
          (let
            [manifest-dir : String (compiler-load-dirname manifest-path)]
            (ResultCompilerLoadPackageEntry.Ok
              (CompilerLoadPackageEntry
                (compiler-load-normalize-path
                  (compiler-load-join-root-path
                    manifest-dir
                    (struct-get manifest entry)))
                manifest-dir
                (struct-get manifest name))))])]))

(define (compiler-load-package-externs-from-import
  [resolved : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [cfgs : sym_i64_env.SymI64Env]
  [module-id-fallback : String]
  [source-module-fallback : String]) : ResultCompilerLoadWithPaths
  (match (compiler-load-package-entry-for-source resolved)
    [(ResultCompilerLoadPackageEntry.Err message)
      (ResultCompilerLoadWithPaths.Err
        (box (compiler-diagnostic-at-start resolved message)))]
    [(ResultCompilerLoadPackageEntry.Ok entry)
      (match (compiler-load-file-with-paths-and-roots-expect-cfg-fallback
        resolved
        seen
        stdlib-roots
        expected-module
        cfgs
        module-id-fallback
        source-module-fallback)
        [(ResultCompilerLoadWithPaths.Ok
            imported-decls
            imported-paths
            _
            import-seen)
          (compiler-load-package-extern-decls
            (struct-get entry owner)
            (struct-get entry manifest-dir)
            stdlib-roots
            imported-decls
            imported-paths
            import-seen
            "")]
        [(ResultCompilerLoadWithPaths.Err diag)
          (ResultCompilerLoadWithPaths.Err diag)])]))

(define (compiler-load-package-expand-include-str
  [importer-path : String]
  [include-path : String]
  [name : String]
  [stdlib-roots : vector.StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerLoadInclude
  (match (if (compiler-load-pkg-import? include-path)
    (compiler-load-resolve-pkg-import include-path manifest-dir deps)
    (compiler-load-resolve-import-result-with-roots
      importer-path
      include-path
      stdlib-roots))
    [(ResultPkgResolve.Ok resolved)
      (compiler-load-include-str-from-resolved
        importer-path
        include-path
        resolved
        name)]
    [(ResultPkgResolve.Err message)
      (ResultCompilerLoadInclude.Err
        (box (compiler-diagnostic-at-start importer-path message)))]))

(define (compiler-load-package-expand-include-bin
  [importer-path : String]
  [include-path : String]
  [name : String]
  [stdlib-roots : vector.StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerLoadInclude
  (match (if (compiler-load-pkg-import? include-path)
    (compiler-load-resolve-pkg-import include-path manifest-dir deps)
    (compiler-load-resolve-import-result-with-roots
      importer-path
      include-path
      stdlib-roots))
    [(ResultPkgResolve.Ok resolved)
      (compiler-load-include-bin-from-resolved
        importer-path
        include-path
        resolved
        name)]
    [(ResultPkgResolve.Err message)
      (ResultCompilerLoadInclude.Err
        (box (compiler-diagnostic-at-start importer-path message)))]))

(define (compiler-load-package-decls-with-module-and-roots
  [decls : AstDeclList]
  [importer-path : String]
  [importer-module : String]
  [importer-source-module : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil)
      (ResultCompilerLoadWithPaths.Ok
        (ast-decl-list-new)
        (ast-decl-path-list-new)
        (ast-decl-module-list-new)
        seen)]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.Import
              (AstImportSpec.Spec kind import-path expected-module alias span))
            (if (compiler-load-macro-import-kind? kind)
              (match (compiler-load-package-decls-with-module-and-roots
                rest
                importer-path
                importer-module
                importer-source-module
                seen
                stdlib-roots
                manifest-dir
                deps
                cfgs)
                [(ResultCompilerLoadWithPaths.Ok
                    rest-decls
                    rest-paths
                    rest-modules
                    rest-seen)
                  (ResultCompilerLoadWithPaths.Ok
                    (ast-decl-list-prepend-builder decl rest-decls)
                    (ast-decl-path-list-prepend-builder
                      importer-path
                      rest-paths)
                    (ast-decl-module-list-prepend-builder
                      importer-module
                      rest-modules)
                    rest-seen)]
                [(ResultCompilerLoadWithPaths.Err diag)
                  (ResultCompilerLoadWithPaths.Err diag)])
              (match (compiler-load-resolve-package-import-spec
                importer-path
                kind
                import-path
                stdlib-roots
                manifest-dir
                deps)
                [(ResultPkgResolve.Ok resolved)
                  (let
                    [package-externs : bool
                      (compiler-load-package-import-externs?
                        kind
                        import-path
                        deps)]
                    [fallback : String
                      (compiler-load-canonical-module-id-from-import
                        kind
                        import-path
                        resolved)]
                    [source-fallback : String
                      (compiler-load-canonical-source-module-from-import
                        kind
                        import-path
                        resolved
                        expected-module
                        importer-source-module)]
                    [preload-skip : bool
                      (if package-externs
                        false
                        (let
                          [preload-candidate : bool
                            (compiler-load-lazy-import-preload-candidate?
                              importer-path
                              kind
                              import-path
                              resolved
                              alias)]
                          (if preload-candidate
                            (compiler-load-lazy-import-skip?
                              importer-path
                              kind
                              resolved
                              alias
                              span)
                            false)))]
                    (match (if preload-skip
                      (ResultCompilerLoadWithPaths.Ok
                        (ast-decl-list-new)
                        (ast-decl-path-list-new)
                        (ast-decl-module-list-new)
                        seen)
                      (if package-externs
                        (compiler-load-package-externs-from-import
                          resolved
                          seen
                          stdlib-roots
                          expected-module
                          cfgs
                          fallback
                          "")
                        (compiler-load-package-file-with-paths-and-roots-expect-cache-current-fallback
                          resolved
                          seen
                          stdlib-roots
                          expected-module
                          manifest-dir
                          deps
                          cfgs
                          true
                          fallback
                          source-fallback)))
                      [(ResultCompilerLoadWithPaths.Ok
                          imported-decls
                          imported-paths
                          imported-modules
                          import-seen)
                        (let
                          [lazy-skip : bool
                            (if preload-skip
                              true
                              (compiler-load-lazy-import-skip?
                                importer-path
                                kind
                                resolved
                                alias
                                span))]
                          [after-import-seen : sym_i64_env.SymI64Env
                            (if lazy-skip
                              seen
                              import-seen)]
                          (match (compiler-load-package-decls-with-module-and-roots
                            rest
                            importer-path
                            importer-module
                            importer-source-module
                            after-import-seen
                            stdlib-roots
                            manifest-dir
                            deps
                            cfgs)
                            [(ResultCompilerLoadWithPaths.Ok
                                rest-decls
                                rest-paths
                                rest-modules
                                rest-seen)
                              (let
                                [after-import-expected : AstMaybeModuleName
                                  (compiler-load-after-import-expected-module
                                    kind
                                    expected-module
                                    alias
                                    imported-decls)]
                                [after-import-alias : AstMaybeImportAlias
                                  (compiler-load-after-import-alias
                                    kind
                                    expected-module
                                    alias
                                    imported-decls)]
                                (if lazy-skip
                                  (begin
                                    (compiler-load-lazy-import-record-skip!)
                                    (ResultCompilerLoadWithPaths.Ok
                                      (compiler-load-decls-after-import
                                        kind
                                        resolved
                                        after-import-expected
                                        after-import-alias
                                        importer-source-module
                                        (ast-decl-list-new)
                                        rest-decls)
                                      (compiler-load-paths-after-import
                                        importer-path
                                        after-import-alias
                                        (ast-decl-list-new)
                                        rest-paths)
                                      (compiler-load-modules-after-import
                                        importer-module
                                        after-import-alias
                                        (ast-decl-list-new)
                                        rest-modules)
                                      rest-seen))
                                  (ResultCompilerLoadWithPaths.Ok
                                    (compiler-load-decl-list-append-onto
                                      imported-decls
                                      (compiler-load-decls-after-import
                                        kind
                                        resolved
                                        after-import-expected
                                        after-import-alias
                                        importer-source-module
                                        imported-decls
                                        rest-decls))
                                    (compiler-load-decl-path-list-append-onto
                                      imported-paths
                                      (compiler-load-paths-after-import
                                        importer-path
                                        after-import-alias
                                        imported-decls
                                        rest-paths))
                                    (compiler-load-decl-module-list-append-onto
                                      imported-modules
                                      (compiler-load-modules-after-import
                                        importer-module
                                        after-import-alias
                                        imported-decls
                                        rest-modules))
                                    rest-seen)))]
                            [(ResultCompilerLoadWithPaths.Err diag)
                              (ResultCompilerLoadWithPaths.Err diag)]))]
                      [(ResultCompilerLoadWithPaths.Err diag)
                        (ResultCompilerLoadWithPaths.Err diag)]))]
                [(ResultPkgResolve.Err message)
                  (ResultCompilerLoadWithPaths.Err
                    (box (compiler-diagnostic-at-start importer-path message)))]))]
          [(AstDecl.IncludeStr name include-path)
            (match (compiler-load-package-expand-include-str
              importer-path
              include-path
              name
              stdlib-roots
              manifest-dir
              deps)
              [(ResultCompilerLoadInclude.Ok expanded)
                (match (compiler-load-package-decls-with-module-and-roots
                  rest
                  importer-path
                  importer-module
                  importer-source-module
                  seen
                  stdlib-roots
                  manifest-dir
                  deps
                  cfgs)
                  [(ResultCompilerLoadWithPaths.Ok
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (ResultCompilerLoadWithPaths.Ok
                      (ast-decl-list-prepend-builder expanded rest-decls)
                      (ast-decl-path-list-prepend-builder
                        importer-path
                        rest-paths)
                      (ast-decl-module-list-prepend-builder
                        importer-module
                        rest-modules)
                      rest-seen)]
                  [(ResultCompilerLoadWithPaths.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ResultCompilerLoadInclude.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]
          [(AstDecl.IncludeBin name include-path)
            (match (compiler-load-package-expand-include-bin
              importer-path
              include-path
              name
              stdlib-roots
              manifest-dir
              deps)
              [(ResultCompilerLoadInclude.Ok expanded)
                (match (compiler-load-package-decls-with-module-and-roots
                  rest
                  importer-path
                  importer-module
                  importer-source-module
                  seen
                  stdlib-roots
                  manifest-dir
                  deps
                  cfgs)
                  [(ResultCompilerLoadWithPaths.Ok
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (ResultCompilerLoadWithPaths.Ok
                      (ast-decl-list-prepend-builder expanded rest-decls)
                      (ast-decl-path-list-prepend-builder
                        importer-path
                        rest-paths)
                      (ast-decl-module-list-prepend-builder
                        importer-module
                        rest-modules)
                      rest-seen)]
                  [(ResultCompilerLoadWithPaths.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ResultCompilerLoadInclude.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]
          [_
            (match (compiler-load-package-decls-with-module-and-roots
              rest
              importer-path
              importer-module
              importer-source-module
              seen
              stdlib-roots
              manifest-dir
              deps
              cfgs)
              [(ResultCompilerLoadWithPaths.Ok
                  rest-decls
                  rest-paths
                  rest-modules
                  rest-seen)
                (ResultCompilerLoadWithPaths.Ok
                  (ast-decl-list-prepend-builder decl rest-decls)
                  (ast-decl-path-list-prepend-builder importer-path rest-paths)
                  (ast-decl-module-list-prepend-builder
                    importer-module
                    rest-modules)
                  rest-seen)]
              [(ResultCompilerLoadWithPaths.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]))]))

(define (compiler-load-package-program-with-paths-and-roots-expect-fallback
  [path : String]
  [program : AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]
  [module-id-fallback : String]
  [source-module-fallback : String]) : ResultCompilerLoadWithPaths
  (let
    [_ : unit (compiler-load-surface-summary-load-enter!)]
    [loaded : ResultCompilerLoadWithPaths
      (match program
        [(AstProgram.Program decls-box)
          (let
            [decls : AstDeclList (box-get decls-box)]
            [source-module : String
              (compiler-load-decls-source-module-or
                decls
                source-module-fallback)]
            [load-decls : AstDeclList
              (compiler-load-contextual-moduleless-decls decls source-module)]
            (match (compiler-load-decls-module-id-with-fallback
              path
              decls
              module-id-fallback)
              [(ResultCompilerLoadModuleId.Ok module-id)
                (match (compiler-load-check-expected-module
                  path
                  expected-module
                  module-id)
                  [(ResultCompilerLoadModuleId.Ok _)
                    (if (sym_i64_env.sym-i64-contains seen module-id)
                      (compiler-load-seen-module-with-paths
                        path
                        module-id
                        load-decls
                        seen)
                      (match (compiler-load-check-dotted-import-aliases
                        path
                        load-decls
                        source-module)
                        [(ResultCompilerLoadAliasCheck.Ok)
                          (begin
                            (compiler-load-record-surface-summary!
                              (compiler-load-surface-summary-from-decls
                                path
                                manifest-dir
                                cfgs
                                module-id
                                load-decls))
                            (compiler-load-package-decls-with-module-and-roots
                              load-decls
                              path
                              module-id
                              source-module
                              (sym_i64_env.sym-i64-bind seen module-id 1)
                              stdlib-roots
                              manifest-dir
                              deps
                              cfgs))]
                        [(ResultCompilerLoadAliasCheck.Err diag)
                          (ResultCompilerLoadWithPaths.Err diag)]))]
                  [(ResultCompilerLoadModuleId.Err diag)
                    (ResultCompilerLoadWithPaths.Err diag)])]
              [(ResultCompilerLoadModuleId.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)]))])]
    (begin
      (compiler-load-surface-summary-load-exit!)
      loaded)))

(define (compiler-load-package-program-with-paths-and-roots-expect
  [path : String]
  [program : AstProgram]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-package-program-with-paths-and-roots-expect-fallback
    path
    program
    seen
    stdlib-roots
    expected-module
    manifest-dir
    deps
    cfgs
    (compiler-load-canonical-module-id-from-path path)
    ""))

(define (compiler-load-package-file-with-paths-and-roots-expect-cache-current-fallback
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-current : bool]
  [module-id-fallback : String]
  [source-module-fallback : String]) : ResultCompilerLoadWithPaths
  (let
    [parse-cfgs : sym_i64_env.SymI64Env
      (compiler-load-stdlib-private-cfgs path stdlib-roots expected-module cfgs)]
    (if (io.file-exists? path)
      (match (if cache-current
        (compiler-load-parse-file-diagnostic-session
          path
          stdlib-roots
          parse-cfgs)
        (compiler-load-parse-file-diagnostic-escaping path parse-cfgs))
        [(ResultAstProgramDiagnostic.Ok program)
          (compiler-load-package-program-with-paths-and-roots-expect-fallback
            path
            program
            seen
            stdlib-roots
            expected-module
            manifest-dir
            deps
            parse-cfgs
            module-id-fallback
            source-module-fallback)]
        [(ResultAstProgramDiagnostic.Err diag)
          (ResultCompilerLoadWithPaths.Err diag)])
      (match (compiler-load-embedded-stdlib-source-for-path path)
        [(CompilerEmbeddedStdlibSomeSource source)
          (match (if cache-current
            (compiler-load-parse-embedded-source-diagnostic-session
              path
              source
              parse-cfgs)
            (compiler-load-parse-source-diagnostic-escaping
              path
              source
              parse-cfgs))
            [(ResultAstProgramDiagnostic.Ok program)
              (compiler-load-package-program-with-paths-and-roots-expect-fallback
                path
                program
                seen
                stdlib-roots
                expected-module
                manifest-dir
                deps
                parse-cfgs
                module-id-fallback
                source-module-fallback)]
            [(ResultAstProgramDiagnostic.Err diag)
              (ResultCompilerLoadWithPaths.Err diag)])]
        [(CompilerEmbeddedStdlibNoSource)
          (ResultCompilerLoadWithPaths.Err
            (box
              (compiler-diagnostic-at-start
                path
                (string.append "compiler-load: cannot read import " path))))]))))

(define (compiler-load-package-file-with-paths-and-roots-expect-cache-current
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-current : bool]) : ResultCompilerLoadWithPaths
  (compiler-load-package-file-with-paths-and-roots-expect-cache-current-fallback
    path
    seen
    stdlib-roots
    expected-module
    manifest-dir
    deps
    cfgs
    cache-current
    (compiler-load-canonical-module-id-from-path path)
    ""))

(define (compiler-load-package-file-with-paths-and-roots-expect
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [expected-module : AstMaybeModuleName]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-package-file-with-paths-and-roots-expect-cache-current
    path
    seen
    stdlib-roots
    expected-module
    manifest-dir
    deps
    cfgs
    true))

(define (compiler-load-package-file-with-paths-and-roots
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerLoadWithPaths
  (compiler-load-package-file-with-paths-and-roots-expect
    path
    seen
    stdlib-roots
    AstMaybeModuleName.No
    manifest-dir
    deps
    (compiler-cfg-empty)))

(define (compiler-load-package-file-with-paths-and-roots-cfg
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-package-file-with-paths-and-roots-expect
    path
    seen
    stdlib-roots
    AstMaybeModuleName.No
    manifest-dir
    deps
    cfgs))

(define (compiler-load-package-entry-file-with-paths-and-roots-cfg
  [path : String]
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-package-file-with-paths-and-roots-expect-cache-current
    path
    seen
    stdlib-roots
    AstMaybeModuleName.No
    manifest-dir
    deps
    cfgs
    false))

(define (compiler-load-package-core-macro-prelude-with-roots-cfg
  [seen : sym_i64_env.SymI64Env]
  [stdlib-roots : vector.StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-append-root-module-marker
    (compiler-load-package-file-with-paths-and-roots-cfg
      compiler-load-core-macro-prelude-path
      seen
      stdlib-roots
      manifest-dir
      deps
      cfgs)))

(define (compiler-load-package-file-with-runtime-cfg
  [input-path : String]
  [stdlib-roots : vector.StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerLoadWithPaths
  (if emit-entry
    (match (compiler-load-package-file-with-paths-and-roots-cfg
      "stdlib/runtime.tl"
      (sym_i64_env.sym-i64-empty)
      stdlib-roots
      manifest-dir
      deps
      cfgs)
      [(ResultCompilerLoadWithPaths.Ok
          runtime-decls
          runtime-paths
          runtime-modules
          runtime-seen)
        (match (compiler-load-package-core-macro-prelude-with-roots-cfg
          runtime-seen
          stdlib-roots
          manifest-dir
          deps
          cfgs)
          [(ResultCompilerLoadWithPaths.Ok
              macro-decls
              macro-paths
              macro-modules
              prelude-seen)
            (match (compiler-load-package-entry-file-with-paths-and-roots-cfg
              input-path
              prelude-seen
              stdlib-roots
              manifest-dir
              deps
              cfgs)
              [(ResultCompilerLoadWithPaths.Ok
                  entry-decls
                  entry-paths
                  entry-modules
                  seen)
                (ResultCompilerLoadWithPaths.Ok
                  (compiler-load-decl-list-append
                    (compiler-load-decl-list-append runtime-decls macro-decls)
                    entry-decls)
                  (compiler-load-decl-path-list-append
                    (compiler-load-decl-path-list-append
                      runtime-paths
                      macro-paths)
                    entry-paths)
                  (compiler-load-decl-module-list-append
                    (compiler-load-decl-module-list-append
                      runtime-modules
                      macro-modules)
                    entry-modules)
                  seen)]
              [(ResultCompilerLoadWithPaths.Err diag)
                (ResultCompilerLoadWithPaths.Err diag)])]
          [(ResultCompilerLoadWithPaths.Err diag)
            (ResultCompilerLoadWithPaths.Err diag)])]
      [(ResultCompilerLoadWithPaths.Err diag)
        (ResultCompilerLoadWithPaths.Err diag)])
    (match (compiler-load-package-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      stdlib-roots
      manifest-dir
      deps
      cfgs)
      [(ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (match (compiler-load-package-entry-file-with-paths-and-roots-cfg
          input-path
          prelude-seen
          stdlib-roots
          manifest-dir
          deps
          cfgs)
          [(ResultCompilerLoadWithPaths.Ok
              entry-decls
              entry-paths
              entry-modules
              seen)
            (ResultCompilerLoadWithPaths.Ok
              (compiler-load-decl-list-append prelude-decls entry-decls)
              (compiler-load-decl-path-list-append prelude-paths entry-paths)
              (compiler-load-decl-module-list-append
                prelude-modules
                entry-modules)
              seen)]
          [(ResultCompilerLoadWithPaths.Err diag)
            (ResultCompilerLoadWithPaths.Err diag)])]
      [(ResultCompilerLoadWithPaths.Err diag)
        (ResultCompilerLoadWithPaths.Err diag)])))

(define (compiler-load-decl-list-count [decls : AstDeclList]) : i64
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) 0]
    [(AstDeclListStep.Cons _ rest)
      (let
        [rest : AstDeclList rest]
        (+ 1 (compiler-load-decl-list-count rest)))]))

(define (compiler-load-first-string-def?
  [decls : AstDeclList]
  [name : String]
  [want : String]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Cons
        (AstDecl.Def got (AstMaybeType.Some (AstType.String)) value-box)
        _)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match value
          [(AstExpr.Literal (AstLiteral.String text))
            (and (string.eq (intern-str got) name) (string.eq text want))]
          [_ false]))]
    [_ false]))

(define (compiler-load-binary-payload-ok? [text : String]) : bool
  (and
    (= (string.string-length text) 6)
    (= (compiler-load-char-code-at text 0) 0)
    (= (compiler-load-char-code-at text 1) 65)
    (= (compiler-load-char-code-at text 2) 127)
    (= (compiler-load-char-code-at text 3) 128)
    (= (compiler-load-char-code-at text 4) 255)
    (= (compiler-load-char-code-at text 5) 10)))

(define (compiler-load-first-bin-def? [decls : AstDeclList] [name : String]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Cons
        (AstDecl.Def
          got
          (AstMaybeType.Some (AstType.DynArray elem-id))
          value-box)
        _)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [elem : AstType (ty-node-get elem-id)]
        (match value
          [(AstExpr.BinaryData text)
            (and
              (string.eq (intern-str got) name)
              (match elem
                [(AstType.U8) true]
                [_ false])
              (compiler-load-binary-payload-ok? text))]
          [_ false]))]
    [_ false]))

(define (compiler-load-binary-fixture) : String
  (let
    [bytes : (Array u8) (make-array u8 6)]
    (begin
      (array-set! bytes 0 (cast 0 : u8))
      (array-set! bytes 1 (cast 65 : u8))
      (array-set! bytes 2 (cast 127 : u8))
      (array-set! bytes 3 (cast 128 : u8))
      (array-set! bytes 4 (cast 255 : u8))
      (array-set! bytes 5 (cast 10 : u8))
      (unsafe
        (string-from-bytes (ptr-cast (array-data bytes) : (Ptr u8)) 6)))))

(define (compiler-load-decl-list-has-import-alias?
  [decls : AstDeclList]
  [target-module : String]
  [target-alias : String]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) false]
    [(AstDeclListStep.Cons decl rest)
      (let
        [rest : AstDeclList rest]
        (match decl
          [(AstDecl.Import
              (AstImportSpec.Spec
                _
                _
                (AstMaybeModuleName.Some module-name)
                (AstMaybeImportAlias.Some alias)
                _))
            (if (and
              (string.eq module-name target-module)
              (string.eq alias target-alias))
              true
              (compiler-load-decl-list-has-import-alias?
                rest
                target-module
                target-alias))]
          [_
            (compiler-load-decl-list-has-import-alias?
              rest
              target-module
              target-alias)]))]))

(define (compiler-load-unmoduled-import-restored-decls? [decls : AstDeclList]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Cons (AstDecl.Module imported-module) rest1)
      (let
        [rest1 : AstDeclList rest1]
        (match (ast-decl-list-step rest1)
          [(AstDeclListStep.Cons (AstDecl.Def imported-name _ _) rest2)
            (let
              [rest2 : AstDeclList rest2]
              (match (ast-decl-list-step rest2)
                [(AstDeclListStep.Cons (AstDecl.Module restored-module) rest3)
                  (let
                    [rest3 : AstDeclList rest3]
                    (match (ast-decl-list-step rest3)
                      [(AstDeclListStep.Cons
                          (AstDecl.Import
                            (AstImportSpec.Spec
                              _
                              _
                              (AstMaybeModuleName.Some alias-module)
                              (AstMaybeImportAlias.Some alias-name)
                              _))
                          rest4)
                        (let
                          [rest4 : AstDeclList rest4]
                          (match (ast-decl-list-step rest4)
                            [(AstDeclListStep.Cons
                                (AstDecl.DefFn main-name _ _ _ _)
                                done-box)
                              (let
                                [done : AstDeclList done-box]
                                (and
                                  (ast-decl-list-empty? (& done))
                                  (string.eq
                                    (intern-str imported-module)
                                    "restore.dep")
                                  (string.eq
                                    (intern-str imported-name)
                                    "dep-value")
                                  (string.eq (intern-str restored-module) "")
                                  (string.eq alias-module "restore.dep")
                                  (string.eq alias-name "dep")
                                  (string.eq (intern-str main-name) "main")))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (compiler-load-two-modules?
  [modules : AstDeclModuleList]
  [want : String]) : bool
  (and
    (= (ast-decl-module-list-len (& modules)) 2)
    (string.eq (ast-decl-module-list-get (& modules) 0 "") want)
    (string.eq (ast-decl-module-list-get (& modules) 1 "") want)))

(define (compiler-load-entry-cycle-module-name? [name : String]) : bool
  (or (string.eq name "smoke.entry") (string.eq name "smoke.dep")))

(define (compiler-load-entry-cycle-modules-loop
  [modules : AstDeclModuleList]
  [count : i64]) : bool
  (if (>= count (ast-decl-module-list-len (& modules)))
    (= count 11)
    (and
      (compiler-load-entry-cycle-module-name?
        (ast-decl-module-list-get (& modules) count ""))
      (compiler-load-entry-cycle-modules-loop modules (+ count 1)))))

(define (compiler-load-entry-cycle-modules? [modules : AstDeclModuleList]) : bool
  (compiler-load-entry-cycle-modules-loop modules 0))

(define (compiler-load-surface-maybe-string-eq?
  [maybe : CompilerLoadSurfaceMaybeString]
  [want : String]) : bool
  (match maybe
    [(CompilerLoadSurfaceSomeString got) (string.eq got want)]
    [(CompilerLoadSurfaceNoString) (string.eq want "")]))

(define (compiler-load-surface-import-kind-code
  [kind : CompilerLoadSurfaceImportKind]) : i64
  (match kind
    [(CompilerLoadSurfaceImportPath) 1]
    [(CompilerLoadSurfaceImportModule) 2]
    [(CompilerLoadSurfaceImportMacro) 3]
    [(CompilerLoadSurfaceImportMacroDecls) 4]))

(define (compiler-load-surface-decl-kind-code
  [kind : CompilerLoadSurfaceDeclKind]) : i64
  (match kind
    [(CompilerLoadSurfaceValue) 1]
    [(CompilerLoadSurfaceFunction) 2]
    [(CompilerLoadSurfaceExtern) 3]
    [(CompilerLoadSurfaceStruct) 4]
    [(CompilerLoadSurfaceEnum) 5]
    [(CompilerLoadSurfaceMacro) 6]
    [(CompilerLoadSurfaceDispatch) 7]
    [(CompilerLoadSurfaceTest) 8]
    [(CompilerLoadSurfaceIncludeStr) 9]
    [(CompilerLoadSurfaceIncludeBin) 10]))

(define (compiler-load-surface-macro-result-kind-code
  [kind : CompilerLoadSurfaceMacroResultKind]) : i64
  (match kind
    [(CompilerLoadSurfaceMacroExpr) 1]
    [(CompilerLoadSurfaceMacroModule) 2]
    [(CompilerLoadSurfaceMacroDecls) 3]
    [(CompilerLoadSurfaceMacroOther) 4]))

(define (compiler-load-surface-import-list-count
  [imports : CompilerLoadSurfaceImportList]) : i64
  (match imports
    [(CompilerLoadSurfaceImportNil) 0]
    [(CompilerLoadSurfaceImportCons _ rest)
      (+ 1 (compiler-load-surface-import-list-count (box-get rest)))]))

(define (compiler-load-surface-decl-list-count
  [decls : CompilerLoadSurfaceDeclList]) : i64
  (match decls
    [(CompilerLoadSurfaceDeclNil) 0]
    [(CompilerLoadSurfaceDeclCons _ rest)
      (+ 1 (compiler-load-surface-decl-list-count (box-get rest)))]))

(define (compiler-load-surface-import-kind-count
  [imports : CompilerLoadSurfaceImportList]
  [kind-code : i64]) : i64
  (match imports
    [(CompilerLoadSurfaceImportNil) 0]
    [(CompilerLoadSurfaceImportCons import-edge rest)
      (let
        [rest : CompilerLoadSurfaceImportList (box-get rest)]
        (+
          (if (=
            (compiler-load-surface-import-kind-code
              (struct-get import-edge kind))
            kind-code)
            1
            0)
          (compiler-load-surface-import-kind-count rest kind-code)))]))

(define (compiler-load-surface-import-has?
  [imports : CompilerLoadSurfaceImportList]
  [kind-code : i64]
  [import-path : String]
  [alias : String]
  [default-alias : String]) : bool
  (match imports
    [(CompilerLoadSurfaceImportNil) false]
    [(CompilerLoadSurfaceImportCons import-edge rest)
      (if (and
        (=
          (compiler-load-surface-import-kind-code (struct-get import-edge kind))
          kind-code)
        (string.eq (struct-get import-edge import-path) import-path)
        (compiler-load-surface-maybe-string-eq?
          (struct-get import-edge alias)
          alias)
        (compiler-load-surface-maybe-string-eq?
          (struct-get import-edge default-alias)
          default-alias))
        true
        (compiler-load-surface-import-has?
          (box-get rest)
          kind-code
          import-path
          alias
          default-alias))]))

(define (compiler-load-surface-decl-kind-count
  [decls : CompilerLoadSurfaceDeclList]
  [kind-code : i64]) : i64
  (match decls
    [(CompilerLoadSurfaceDeclNil) 0]
    [(CompilerLoadSurfaceDeclCons decl rest)
      (let
        [rest : CompilerLoadSurfaceDeclList (box-get rest)]
        (+
          (if (=
            (compiler-load-surface-decl-kind-code (struct-get decl kind))
            kind-code)
            1
            0)
          (compiler-load-surface-decl-kind-count rest kind-code)))]))

(define (compiler-load-surface-decl-has?
  [decls : CompilerLoadSurfaceDeclList]
  [kind-code : i64]
  [name : String]) : bool
  (match decls
    [(CompilerLoadSurfaceDeclNil) false]
    [(CompilerLoadSurfaceDeclCons decl rest)
      (if (and
        (=
          (compiler-load-surface-decl-kind-code (struct-get decl kind))
          kind-code)
        (string.eq (struct-get decl name) name))
        true
        (compiler-load-surface-decl-has? (box-get rest) kind-code name))]))

(define (compiler-load-surface-decl-generated?
  [decls : CompilerLoadSurfaceDeclList]
  [name : String]) : bool
  (match decls
    [(CompilerLoadSurfaceDeclNil) false]
    [(CompilerLoadSurfaceDeclCons decl rest)
      (if (and
        (string.eq (struct-get decl name) name)
        (struct-get decl has-generated-meta))
        true
        (compiler-load-surface-decl-generated? (box-get rest) name))]))

(define (compiler-load-surface-decl-unsafe?
  [decls : CompilerLoadSurfaceDeclList]
  [name : String]) : bool
  (match decls
    [(CompilerLoadSurfaceDeclNil) false]
    [(CompilerLoadSurfaceDeclCons decl rest)
      (if (and
        (string.eq (struct-get decl name) name)
        (struct-get decl was-unsafe))
        true
        (compiler-load-surface-decl-unsafe? (box-get rest) name))]))

(define (compiler-load-surface-decl-cleanup?
  [decls : CompilerLoadSurfaceDeclList]
  [name : String]) : bool
  (match decls
    [(CompilerLoadSurfaceDeclNil) false]
    [(CompilerLoadSurfaceDeclCons decl rest)
      (if (and
        (string.eq (struct-get decl name) name)
        (struct-get decl has-cleanup))
        true
        (compiler-load-surface-decl-cleanup? (box-get rest) name))]))

(define (compiler-load-surface-macro-result-count
  [decls : CompilerLoadSurfaceDeclList]
  [result-code : i64]) : i64
  (match decls
    [(CompilerLoadSurfaceDeclNil) 0]
    [(CompilerLoadSurfaceDeclCons decl rest)
      (let
        [rest : CompilerLoadSurfaceDeclList (box-get rest)]
        (+
          (if (and
            (= (compiler-load-surface-decl-kind-code (struct-get decl kind)) 6)
            (=
              (compiler-load-surface-macro-result-kind-code
                (struct-get decl macro-result))
              result-code))
            1
            0)
          (compiler-load-surface-macro-result-count rest result-code)))]))

(define (compiler-load-surface-summary-smoke-source) : String
  (str_cat.str-cat
    "(module summary.mod)
(import \"dep.tl\" module dep.mod as dep)
(import stdlib.vector as vec)
(import (vector i64) as vi64)
(cfg feature (import \"feature.tl\" module feature.mod as feat))
(emit-generated VecI64)
(define value : i64 1)
(define (pub [x : i64]) (:export-symbol \"pub\") : i64 x)
(extern (foreign [x : i64]) : i64)
(unsafe (extern (danger [x : i64]) : i64))
(defstruct Resource (:cleanup close-resource) (fd i64 (:cleanup close-fd)))
(defenum Maybe (:cleanup close-maybe) (None) (Some i64 (:cleanup close-i64)))
(defmacro (expr-m [x : Expr]) : Expr x)
(defmacro (module-m [T : type]) : Module (expr-unit))
(defmacro (decls-m [T : type]) : Decls (expr-unit))
(comptime-decl (:generated gen-family generated-value \"i64\")
  (define generated-value : i64 3))
("
    "test loader-summary value)
(include-str text \"data.txt\")
(include-bin blob \"data.bin\")"))

(define (compiler-load-surface-summary-shape-ok?
  [summary : CompilerLoadSurfaceSummary]) : bool
  (let
    [imports : CompilerLoadSurfaceImportList (struct-get summary imports)]
    [decls : CompilerLoadSurfaceDeclList (struct-get summary decls)]
    (and
      (string.eq (struct-get summary module-id) "summary.mod")
      (string.eq (struct-get summary source-path) "src/summary.tl")
      (string.eq (struct-get summary root-id) "src")
      (= (compiler-load-surface-import-list-count imports) 5)
      (= (compiler-load-surface-import-kind-count imports 1) 2)
      (= (compiler-load-surface-import-kind-count imports 2) 1)
      (= (compiler-load-surface-import-kind-count imports 3) 1)
      (= (compiler-load-surface-import-kind-count imports 4) 1)
      (compiler-load-surface-import-has?
        imports
        2
        "stdlib.vector"
        "vec"
        "vector")
      (compiler-load-surface-import-has? imports 1 "feature.tl" "feat" "")
      (= (compiler-load-surface-decl-list-count decls) 13)
      (= (compiler-load-surface-decl-kind-count decls 6) 3)
      (compiler-load-surface-decl-has? decls 1 "value")
      (compiler-load-surface-decl-has? decls 2 "pub")
      (compiler-load-surface-decl-has? decls 3 "foreign")
      (compiler-load-surface-decl-unsafe? decls "danger")
      (compiler-load-surface-decl-cleanup? decls "Resource")
      (compiler-load-surface-decl-cleanup? decls "Maybe")
      (compiler-load-surface-decl-generated? decls "generated-value")
      (= (compiler-load-surface-macro-result-count decls 1) 1)
      (= (compiler-load-surface-macro-result-count decls 2) 1)
      (= (compiler-load-surface-macro-result-count decls 3) 1)
      (struct-get summary has-tests)
      (struct-get summary has-export-metadata)
      (struct-get summary has-generated-decls)
      (struct-get summary has-decl-emitting-macro)
      (compiler-load-surface-summary-requires-eager? summary))))

(define (compiler-load-surface-summary-smoke-ok?) : bool
  (let
    [cfgs : sym_i64_env.SymI64Env
      (compiler-cfg-enable (compiler-cfg-empty) "feature")]
    (match (compiler-load-parse-source-diagnostic-escaping
      "src\\summary.tl"
      (compiler-load-surface-summary-smoke-source)
      cfgs)
      [(ResultAstProgramDiagnostic.Ok program)
        (match (compiler-load-surface-summary-build
          "src\\summary.tl"
          "src\\..\\src"
          cfgs
          program)
          [(ResultCompilerLoadSurfaceSummary.Ok summary)
            (compiler-load-surface-summary-shape-ok? summary)]
          [(ResultCompilerLoadSurfaceSummary.Err _) false])]
      [(ResultAstProgramDiagnostic.Err _) false])))

(define (compiler-load-normalize-ok?) : bool
  (and
    (string.eq
      (compiler-load-normalize-path "selfhost/./x/../compiler_load.tl")
      "selfhost/compiler_load.tl")
    (string.eq
      (compiler-load-normalize-path "target\\loader\\..\\dep.tl")
      "target/dep.tl")))

(define (compiler-load-canonical-module-id-ok?) : bool
  (and
    (string.eq
      (compiler-load-canonical-module-id-from-path "stdlib/array.tl")
      "stdlib.array")
    (string.eq
      (compiler-load-canonical-module-id-from-path "src\\compiler_intern.tl")
      "src.compiler_intern")
    (string.eq
      (compiler-load-canonical-module-id-from-pkg-import "pkg:math/src/add.tl")
      "math.src.add")
    (string.eq
      (compiler-load-canonical-module-id-from-import
        (AstImportKind.Module)
        "stdlib.some_name"
        "target/ignored/some_name.tl")
      "stdlib.some_name")))

(define (compiler-load-source-provenance-ok?) : bool
  (match (compiler-load-source-with-paths
    "src/./main.tl"
    "(module app.main)
(define answer : i64 42)"
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoadWithPaths.Ok decls _ modules seen)
      (and
        (= (compiler-load-decl-list-count decls) 2)
        (compiler-load-two-modules? modules "app.main")
        (sym_i64_env.sym-i64-contains seen "app.main"))]
    [(ResultCompilerLoadWithPaths.Err _) false]))

(define (compiler-load-entry-moduled-main-ok?) : bool
  (and
    (compiler-load-package-entry-main?
      "src/app.tl"
      "src/app.tl"
      "app.main"
      "main")
    (compiler-load-package-entry-main?
      "src\\app.tl"
      "src/app.tl"
      "app.main"
      "main")
    (not
      (compiler-load-package-entry-main?
        "src/app.tl"
        "src/lib.tl"
        "app.main"
        "main"))
    (not
      (compiler-load-package-entry-main?
        "src/app.tl"
        "src/app.tl"
        "app.main"
        "helper"))))

(define (compiler-load-expected-module-conflict-ok?) : bool
  (match (compiler-load-source-with-paths-and-roots-expect
    "src/lib.tl"
    "(module lib.actual)
(define value : i64 1)"
    (sym_i64_env.sym-i64-empty)
    (vector.string-vec-new)
    (AstMaybeModuleName.Some "lib.want"))
    [(ResultCompilerLoadWithPaths.Err diag)
      (string.eq
        (compiler-diagnostic-message (box-get diag))
        "compiler-load: import expected module lib.want but loaded lib.actual")]
    [(ResultCompilerLoadWithPaths.Ok _ _ _ _) false]))

(define (compiler-load-duplicate-module-ok?) : bool
  (match (compiler-load-source
    "src/dup.tl"
    "(module dup.one)
(module dup.two)
(define value : i64 1)"
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoad.Err diag)
      (string.eq
        (compiler-diagnostic-message (box-get diag))
        "compiler-load: duplicate module declaration")]
    [(ResultCompilerLoad.Ok _ _) false]))

(define (compiler-load-nested-module-body-ok?) : bool
  (match (compiler-load-source
    "src/nested_module.tl"
    "(module local.helper (define value : i64 1))
(define root-value : i64 2)"
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoad.Ok decls _)
      (match (ast-decl-list-step decls)
        [(AstDeclListStep.Cons (AstDecl.Module nested-module) rest1)
          (let
            [rest1 : AstDeclList rest1]
            (match (ast-decl-list-step rest1)
              [(AstDeclListStep.Cons (AstDecl.Def value-name _ _) rest2)
                (let
                  [rest2 : AstDeclList rest2]
                  (match (ast-decl-list-step rest2)
                    [(AstDeclListStep.Cons
                        (AstDecl.Module restored-module)
                        rest3)
                      (let
                        [rest3 : AstDeclList rest3]
                        (match (ast-decl-list-step rest3)
                          [(AstDeclListStep.Cons
                              (AstDecl.Def root-name _ _)
                              done-box)
                            (let
                              [done : AstDeclList done-box]
                              (and
                                (ast-decl-list-empty? (& done))
                                (string.eq
                                  (intern-str nested-module)
                                  "local.helper")
                                (string.eq (intern-str value-name) "value")
                                (string.eq (intern-str restored-module) "")
                                (string.eq (intern-str root-name) "root-value")))]
                          [_ false]))]
                    [_ false]))]
              [_ false]))]
        [_ false])]
    [(ResultCompilerLoad.Err _) false]))

(define (compiler-load-nested-module-duplicate-ok?) : bool
  (match (compiler-load-source
    "src/nested_dup.tl"
    "(module local.helper (define a : i64 1))
(module local.helper (define b : i64 2))"
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoad.Err diag)
      (string.eq
        (compiler-diagnostic-message (box-get diag))
        "compiler-load: duplicate module declaration")]
    [(ResultCompilerLoad.Ok _ _) false]))

(define (compiler-load-seen-module-ok?) : bool
  (match (compiler-load-source
    "src/other.tl"
    "(module seen.module)
(define value : i64 1)"
    (sym_i64_env.sym-i64-bind (sym_i64_env.sym-i64-empty) "seen.module" 1))
    [(ResultCompilerLoad.Ok decls _)
      (compiler-load-decl-list-has-module? decls)]
    [(ResultCompilerLoad.Err _) false]))

(define (compiler-load-cfg-import-ok?) : bool
  (let
    [source : String
      "(module cfg.entry)
(cfg missing (import \"definitely_missing.tl\"))
(define value : i64 1)"]
    [enabled-source : String
      "(module cfg.entry.active)
(cfg feature (import \"definitely_missing.tl\"))
(define value : i64 1)"]
    [feature-cfg : sym_i64_env.SymI64Env
      (compiler-cfg-enable (compiler-cfg-empty) "feature")]
    (and
      (match (compiler-load-source-with-paths-and-roots-cfg
        "src/main.tl"
        source
        (sym_i64_env.sym-i64-empty)
        (vector.string-vec-new)
        (compiler-cfg-empty))
        [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
          (= (compiler-load-decl-list-count decls) 2)]
        [(ResultCompilerLoadWithPaths.Err _) false])
      (match (compiler-load-source-with-paths-and-roots-cfg
        "src/main.tl"
        enabled-source
        (sym_i64_env.sym-i64-empty)
        (vector.string-vec-new)
        feature-cfg)
        [(ResultCompilerLoadWithPaths.Err _) true]
        [(ResultCompilerLoadWithPaths.Ok _ _ _ _) false]))))

(define (compiler-load-file-import-dedup-cycle-ok?) : bool
  (begin
    (io.write-file
      "target/compiler_load_dep.tl"
      "(module smoke.dep)
(import \"compiler_load_entry.tl\" module smoke.entry as entry)
(define dep : i64 1)")
    (io.write-file
      "target/compiler_load_entry.tl"
      "(module smoke.entry)
(import \"compiler_load_dep.tl\" module smoke.dep as dep)
(import \"./compiler_load_dep.tl\" module smoke.dep)
(define (main) : i64 dep)")
    (match (compiler-load-file-with-paths
      "target/compiler_load_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ modules seen)
        (and
          (= (compiler-load-decl-list-count decls) 11)
          (compiler-load-entry-cycle-modules? modules)
          (sym_i64_env.sym-i64-contains seen "smoke.entry")
          (sym_i64_env.sym-i64-contains seen "smoke.dep"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-import-module-restore-ok?) : bool
  (begin
    (io.write-file
      "target/cl_restore_dep.tl"
      "(module restore.dep)
(define dep-value : i64 1)")
    (io.write-file
      "target/cl_restore_entry.tl"
      "(import \"cl_restore_dep.tl\" module restore.dep as dep)
(define (main) : i64 42)")
    (match (compiler-load-file-with-paths
      "target/cl_restore_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
        (compiler-load-unmoduled-import-restored-decls? decls)]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-file-fallback-path-dedup-ok?) : bool
  (begin
    (io.write-file
      "target/compiler_load_legacy_dep.tl"
      "(define legacy-dep : i64 1)")
    (io.write-file
      "target/compiler_load_legacy_entry.tl"
      "(import \"compiler_load_legacy_dep.tl\")
(import \"./compiler_load_legacy_dep.tl\")
(define (main) : i64 legacy-dep)")
    (match (compiler-load-file-with-paths
      "target/compiler_load_legacy_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ modules seen)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (sym_i64_env.sym-i64-contains seen "target.compiler_load_legacy_dep")
          (not
            (sym_i64_env.sym-i64-contains
              seen
              "target/compiler_load_legacy_dep.tl")))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-import-alias-preserved-ok?) : bool
  (begin
    (io.write-file
      "target/cl_alias_dep.tl"
      "(module alias.dep)
(define (get) : i64 7)")
    (io.write-file
      "target/cl_alias_entry.tl"
      "(import \"cl_alias_dep.tl\" module alias.dep :as dep)
(module alias.entry)
(define (main) : i64 (dep.get))")
    (match (compiler-load-file-with-paths
      "target/cl_alias_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
        (compiler-load-decl-list-has-import-alias? decls "alias.dep" "dep")]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-legacy-path-module-flat-alias-ok?) : bool
  (begin
    (io.write-file
      "target/cl_legacy_module_dep.tl"
      "(module legacy.dep)
(define (get) : i64 7)")
    (io.write-file
      "target/cl_legacy_module_entry.tl"
      "(import \"cl_legacy_module_dep.tl\")
(define (main) : i64 (get))")
    (match (compiler-load-file-with-paths
      "target/cl_legacy_module_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
        (compiler-load-decl-list-has-import-alias? decls "legacy.dep" "")]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-seen-legacy-path-module-flat-alias-ok?) : bool
  (begin
    (io.write-file
      "target/cl_seen_legacy_module_dep.tl"
      "(module seen.legacy.dep)
(define (get) : i64 7)")
    (io.write-file
      "target/cl_seen_legacy_module_pre.tl"
      "(import \"cl_seen_legacy_module_dep.tl\" module seen.legacy.dep :as dep)
(define (pre) : i64 (dep.get))")
    (io.write-file
      "target/cl_seen_legacy_module_entry.tl"
      "(import \"cl_seen_legacy_module_pre.tl\")
(import \"cl_seen_legacy_module_dep.tl\")
(define (main) : i64 (get))")
    (match (compiler-load-file-with-paths
      "target/cl_seen_legacy_module_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
        (compiler-load-decl-list-has-import-alias? decls "seen.legacy.dep" "")]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-package-legacy-path-module-flat-alias-ok?) : bool
  (begin
    (io.write-file
      "target/cl_pkg_legacy_module_dep.tl"
      "(module legacy.pkg.dep)
(define (get) : i64 7)")
    (io.write-file
      "target/cl_pkg_legacy_module_entry.tl"
      "(import \"cl_pkg_legacy_module_dep.tl\")
(define (main) : i64 (get))")
    (match (compiler-load-package-file-with-paths-and-roots
      "target/cl_pkg_legacy_module_entry.tl"
      (sym_i64_env.sym-i64-empty)
      (vector.string-vec-new)
      "target"
      (compiler-pkg-deps-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
        (compiler-load-decl-list-has-import-alias? decls "legacy.pkg.dep" "")]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-package-seen-legacy-path-module-flat-alias-ok?) : bool
  (begin
    (io.write-file
      "target/cl_pkg_seen_legacy_module_dep.tl"
      "(module seen.legacy.pkg.dep)
(define (get) : i64 7)")
    (io.write-file
      "target/cl_pkg_seen_legacy_module_pre.tl"
      "(import \"cl_pkg_seen_legacy_module_dep.tl\" module seen.legacy.pkg.dep :as dep)
(define (pre) : i64 (dep.get))")
    (io.write-file
      "target/cl_pkg_seen_legacy_module_entry.tl"
      "(import \"cl_pkg_seen_legacy_module_pre.tl\")
(import \"cl_pkg_seen_legacy_module_dep.tl\")
(define (main) : i64 (get))")
    (match (compiler-load-package-file-with-paths-and-roots
      "target/cl_pkg_seen_legacy_module_entry.tl"
      (sym_i64_env.sym-i64-empty)
      (vector.string-vec-new)
      "target"
      (compiler-pkg-deps-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
        (compiler-load-decl-list-has-import-alias?
          decls
          "seen.legacy.pkg.dep"
          "")]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-dotted-import-duplicate-alias-ok?) : bool
  (match (compiler-load-source
    "src/dup_alias.tl"
    "(module alias.entry)
(import pkg.one)
(import other.one)
(define (main) : i64 0)"
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoad.Err diag)
      (string.eq
        (compiler-diagnostic-message (box-get diag))
        "compiler-load: duplicate module import alias one")]
    [(ResultCompilerLoad.Ok _ _) false]))

(define (compiler-load-dotted-import-resolution-ok?) : bool
  (and
    (string.eq
      (compiler-load-dotted-module-path "stdlib.core_macros")
      "stdlib/core_macros.tl")
    (match (compiler-load-resolve-module-import-with-roots
      "src/main.tl"
      "src/"
      "app.lib"
      (vector.string-vec-new))
      [(ResultPkgResolve.Ok path) (string.eq path "src/app/lib.tl")]
      [(ResultPkgResolve.Err _) false])
    (match (compiler-load-resolve-module-import-with-roots
      "src/main.tl"
      "src/"
      "stdlib.core_macros"
      (vector.string-vec-new))
      [(ResultPkgResolve.Ok path) (string.eq path "stdlib/core_macros.tl")]
      [(ResultPkgResolve.Err _) false])))

(define (compiler-load-test-mkdir-direct [path : String]) : bool
  (match (fs.try-mkdir-if-missing (& path))
    [(io.OkIoUnit) true]
    [(io.ErrIoUnit _) false]))

(define (compiler-load-test-mkdir [path : String]) : bool
  (if (compiler-load-string-prefix-at? path "target/" 0)
    (and
      (compiler-load-test-mkdir-direct "target")
      (compiler-load-test-mkdir-direct path))
    (compiler-load-test-mkdir-direct path)))

(define (compiler-load-session-cache-common-dep-ok?) : bool
  (let
    [root : String "target/cl_cache_common_root"]
    [dep-suffix : String "cache_dep.tl"]
    [dep-file : String (compiler-load-join-root-path root dep-suffix)]
    [roots : vector.StringVec
      (vector.string-vec-push (vector.string-vec-new) root)]
    (begin
      (compiler-load-test-mkdir root)
      (io.write-file dep-file "(module cache.dep)
(define dep-value : i64 1)")
      (io.write-file
        "target/cl_cache_entry_a.tl"
        "(module cache.entry.a)
(import \"stdlib/cache_dep.tl\" module cache.dep as dep)
(define entry-a : i64 1)")
      (io.write-file
        "target/cl_cache_entry_b.tl"
        "(module cache.entry.b)
(import \"stdlib/cache_dep.tl\" module cache.dep as dep)
(define entry-b : i64 2)")
      (compiler-load-session-cache-enable!)
      (compiler-load-program-cache-clear!)
      (let
        [ok : bool false]
        (begin
          (if (match (compiler-load-file-with-paths-and-roots
            "target/cl_cache_entry_a.tl"
            (sym_i64_env.sym-i64-empty)
            roots)
            [(ResultCompilerLoadWithPaths.Ok _ _ _ _) true]
            [(ResultCompilerLoadWithPaths.Err _) false])
            (begin
              (compiler-load-session-reset-pools!)
              (compiler-load-session-reset-interns!)
              (match (compiler-load-file-with-paths-and-roots
                "target/cl_cache_entry_b.tl"
                (sym_i64_env.sym-i64-empty)
                roots)
                [(ResultCompilerLoadWithPaths.Ok _ _ _ _)
                  (set!
                    ok
                    (and
                      (> (compiler-load-program-cache-hit-count-value) 0)
                      (>= (compiler-load-program-cache-store-count-value) 1)))]
                [(ResultCompilerLoadWithPaths.Err _) (set! ok false)]))
            (set! ok false))
          (compiler-load-session-cache-disable-for-test!)
          ok)))))

(define (compiler-load-session-cache-root-isolation-ok?) : bool
  (let
    [root-a : String "target/cl_cache_root_a"]
    [root-b : String "target/cl_cache_root_b"]
    [dep-suffix : String "cache_root_dep.tl"]
    [root-a-file : String (compiler-load-join-root-path root-a dep-suffix)]
    [root-b-file : String (compiler-load-join-root-path root-b dep-suffix)]
    [roots-a : vector.StringVec
      (vector.string-vec-push (vector.string-vec-new) root-a)]
    [roots-b : vector.StringVec
      (vector.string-vec-push (vector.string-vec-new) root-b)]
    (begin
      (compiler-load-test-mkdir root-a)
      (compiler-load-test-mkdir root-b)
      (io.write-file
        root-a-file
        "(module cache.root.a)
(define root-value : i64 1)")
      (io.write-file
        root-b-file
        "(module cache.root.b)
(define root-value : i64 2)")
      (io.write-file
        "target/cl_cache_root_entry_a.tl"
        "(module cache.root.entry.a)
(import \"stdlib/cache_root_dep.tl\" module cache.root.a as dep)
(define entry-a : i64 1)")
      (io.write-file
        "target/cl_cache_root_entry_b.tl"
        "(module cache.root.entry.b)
(import \"stdlib/cache_root_dep.tl\" module cache.root.b as dep)
(define entry-b : i64 2)")
      (compiler-load-session-cache-enable!)
      (compiler-load-program-cache-clear!)
      (let
        [ok : bool false]
        (begin
          (if (match (compiler-load-file-with-paths-and-roots
            "target/cl_cache_root_entry_a.tl"
            (sym_i64_env.sym-i64-empty)
            roots-a)
            [(ResultCompilerLoadWithPaths.Ok _ _ _ _) true]
            [(ResultCompilerLoadWithPaths.Err _) false])
            (begin
              (compiler-load-session-reset-pools!)
              (compiler-load-session-reset-interns!)
              (match (compiler-load-file-with-paths-and-roots
                "target/cl_cache_root_entry_b.tl"
                (sym_i64_env.sym-i64-empty)
                roots-b)
                [(ResultCompilerLoadWithPaths.Ok _ _ _ _) (set! ok true)]
                [(ResultCompilerLoadWithPaths.Err _) (set! ok false)]))
            (set! ok false))
          (compiler-load-session-cache-disable-for-test!)
          ok)))))

(define (compiler-load-session-cache-entry-cold-ok?) : bool
  (begin
    (io.write-file
      "target/cl_cache_cold_entry.tl"
      "(module cache.cold.entry)
(define entry-value : i64 1)")
    (compiler-load-session-cache-enable!)
    (compiler-load-program-cache-clear!)
    (let
      [ok : bool false]
      (begin
        (if (match (compiler-load-entry-file-with-paths-and-roots-cfg
          "target/cl_cache_cold_entry.tl"
          (sym_i64_env.sym-i64-empty)
          (vector.string-vec-new)
          (compiler-cfg-empty))
          [(ResultCompilerLoadWithPaths.Ok _ _ _ _) true]
          [(ResultCompilerLoadWithPaths.Err _) false])
          (begin
            (compiler-load-session-reset-pools!)
            (compiler-load-session-reset-interns!)
            (match (compiler-load-entry-file-with-paths-and-roots-cfg
              "target/cl_cache_cold_entry.tl"
              (sym_i64_env.sym-i64-empty)
              (vector.string-vec-new)
              (compiler-cfg-empty))
              [(ResultCompilerLoadWithPaths.Ok _ _ _ _)
                (set!
                  ok
                  (and
                    (= (compiler-load-program-cache-hit-count-value) 0)
                    (= (compiler-load-program-cache-store-count-value) 0)))]
              [(ResultCompilerLoadWithPaths.Err _) (set! ok false)]))
          (set! ok false))
        (compiler-load-session-cache-disable-for-test!)
        ok))))

(define (compiler-load-session-program-cache-disable-persistent-off-ok?) : bool
  (begin
    (compiler-load-session-cache-enable!)
    (compiler-load-session-program-cache-disable!)
    (let
      [ok : bool (not (intern-persistent-storage-on?))]
      (begin
        (compiler-load-session-cache-disable-for-test!)
        ok))))

(define (compiler-load-session-cache-enable-persistent-off-ok?) : bool
  (begin
    (compiler-load-session-cache-enable!)
    (let
      [ok : bool (not (intern-persistent-storage-on?))]
      (begin
        (compiler-load-session-cache-disable-for-test!)
        ok))))

(define (compiler-load-session-persistent-floor-interns-ok?) : bool
  (begin
    (compiler-load-session-cache-enable!)
    (compiler-load-session-program-cache-disable!)
    (let
      [id : i64
        (with-scratch
          (let
            [name : String (string.append "cache.floor." "transient")]
            [interned : i64 (intern name)]
            (begin
              (compiler-load-session-note-persistent!)
              interned)))]
      (begin
        (compiler-load-session-reset-interns!)
        (let
          [again : i64 (intern "cache.floor.transient")]
          [ok : bool (= id again)]
          (begin
            (compiler-load-session-cache-disable-for-test!)
            ok))))))

(define (compiler-load-session-cache-local-common-dep-ok?) : bool
  (let
    [dir : String "target/cl_cache_local"]
    [dep : String (compiler-load-join-root-path dir "dep.tl")]
    [entry-a : String (compiler-load-join-root-path dir "entry_a.tl")]
    [entry-b : String (compiler-load-join-root-path dir "entry_b.tl")]
    [entry-c : String (compiler-load-join-root-path dir "entry_c.tl")]
    (begin
      (compiler-load-test-mkdir dir)
      (io.write-file dep "(module cache.local.dep)
(define dep-value : i64 1)")
      (io.write-file
        entry-a
        "(module cache.local.entry.a)
(import \"dep.tl\" module cache.local.dep as dep)
(define entry-a : i64 1)")
      (io.write-file
        entry-b
        "(module cache.local.entry.b)
(import \"dep.tl\" module cache.local.dep as dep)
(define entry-b : i64 2)")
      (io.write-file
        entry-c
        "(module cache.local.entry.c)
(import \"dep.tl\" module cache.local.dep as dep)
(define entry-c : i64 3)")
      (compiler-load-session-cache-enable!)
      (compiler-load-program-cache-clear!)
      (let
        [ok : bool false]
        (begin
          (if (match (compiler-load-entry-file-with-paths-and-roots-cfg
            entry-a
            (sym_i64_env.sym-i64-empty)
            (vector.string-vec-new)
            (compiler-cfg-empty))
            [(ResultCompilerLoadWithPaths.Ok _ _ _ _) true]
            [(ResultCompilerLoadWithPaths.Err _) false])
            (begin
              (compiler-load-session-reset-pools!)
              (compiler-load-session-reset-interns!)
              (match (compiler-load-entry-file-with-paths-and-roots-cfg
                entry-b
                (sym_i64_env.sym-i64-empty)
                (vector.string-vec-new)
                (compiler-cfg-empty))
                [(ResultCompilerLoadWithPaths.Ok _ _ _ _)
                  (begin
                    (compiler-load-session-reset-pools!)
                    (compiler-load-session-reset-interns!)
                    (match (compiler-load-entry-file-with-paths-and-roots-cfg
                      entry-c
                      (sym_i64_env.sym-i64-empty)
                      (vector.string-vec-new)
                      (compiler-cfg-empty))
                      [(ResultCompilerLoadWithPaths.Ok _ _ _ _)
                        (set!
                          ok
                          (and
                            (> (compiler-load-program-cache-hit-count-value) 0)
                            (>=
                              (compiler-load-program-cache-store-count-value)
                              1)))]
                      [(ResultCompilerLoadWithPaths.Err _) (set! ok false)]))]
                [(ResultCompilerLoadWithPaths.Err _) (set! ok false)]))
            (set! ok false))
          (compiler-load-session-cache-disable-for-test!)
          ok)))))

(define (compiler-load-session-cache-package-common-dep-ok?) : bool
  (let
    [root : String "target/cl_cache_pkg"]
    [src : String (compiler-load-join-root-path root "src")]
    [dep : String (compiler-load-join-root-path src "common.tl")]
    [entry-a : String (compiler-load-join-root-path src "entry_a.tl")]
    [entry-b : String (compiler-load-join-root-path src "entry_b.tl")]
    [entry-c : String (compiler-load-join-root-path src "entry_c.tl")]
    [deps : CompilerPkgDeps (compiler-pkg-deps-empty)]
    (begin
      (compiler-load-test-mkdir root)
      (compiler-load-test-mkdir src)
      (io.write-file
        dep
        "(module cache.pkg.common)
(define common-value : i64 1)")
      (io.write-file
        entry-a
        "(module cache.pkg.entry.a)
(import \"common.tl\" module cache.pkg.common as common)
(define entry-a : i64 1)")
      (io.write-file
        entry-b
        "(module cache.pkg.entry.b)
(import \"common.tl\" module cache.pkg.common as common)
(define entry-b : i64 2)")
      (io.write-file
        entry-c
        "(module cache.pkg.entry.c)
(import \"common.tl\" module cache.pkg.common as common)
(define entry-c : i64 3)")
      (compiler-load-session-cache-enable!)
      (compiler-load-program-cache-clear!)
      (let
        [ok : bool false]
        (begin
          (if (match (compiler-load-package-entry-file-with-paths-and-roots-cfg
            entry-a
            (sym_i64_env.sym-i64-empty)
            (vector.string-vec-new)
            root
            deps
            (compiler-cfg-empty))
            [(ResultCompilerLoadWithPaths.Ok _ _ _ _) true]
            [(ResultCompilerLoadWithPaths.Err _) false])
            (begin
              (compiler-load-session-reset-pools!)
              (compiler-load-session-reset-interns!)
              (match (compiler-load-package-entry-file-with-paths-and-roots-cfg
                entry-b
                (sym_i64_env.sym-i64-empty)
                (vector.string-vec-new)
                root
                deps
                (compiler-cfg-empty))
                [(ResultCompilerLoadWithPaths.Ok _ _ _ _)
                  (begin
                    (compiler-load-session-reset-pools!)
                    (compiler-load-session-reset-interns!)
                    (match (compiler-load-package-entry-file-with-paths-and-roots-cfg
                      entry-c
                      (sym_i64_env.sym-i64-empty)
                      (vector.string-vec-new)
                      root
                      deps
                      (compiler-cfg-empty))
                      [(ResultCompilerLoadWithPaths.Ok _ _ _ _)
                        (set!
                          ok
                          (and
                            (> (compiler-load-program-cache-hit-count-value) 0)
                            (>=
                              (compiler-load-program-cache-store-count-value)
                              1)))]
                      [(ResultCompilerLoadWithPaths.Err _) (set! ok false)]))]
                [(ResultCompilerLoadWithPaths.Err _) (set! ok false)]))
            (set! ok false))
          (compiler-load-session-cache-disable-for-test!)
          ok)))))

(define (compiler-load-dotted-source-root-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_dotted_src")
    (compiler-load-test-mkdir "target/cl_dotted_src/nested")
    (io.write-file
      "target/cl_dotted_src/root_leaf.tl"
      "(module root_leaf)
(define leaf-val : i64 1)")
    (io.write-file
      "target/cl_dotted_src/nested/dep.tl"
      "(module nested.dep)
(import root_leaf as leaf)
(define dep-val : i64 leaf-val)")
    (io.write-file
      "target/cl_dotted_src/entry.tl"
      "(module dotted.entry)
(import nested.dep)
(define (main) : i64 dep-val)")
    (match (compiler-load-file-with-paths
      "target/cl_dotted_src/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (and
          (sym_i64_env.sym-i64-contains seen "dotted.entry")
          (sym_i64_env.sym-i64-contains seen "nested.dep")
          (sym_i64_env.sym-i64-contains seen "root_leaf"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-moduleless-dotted-source-root-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_moduleless_dotted_src")
    (compiler-load-test-mkdir "target/cl_moduleless_dotted_src/nested")
    (io.write-file
      "target/cl_moduleless_dotted_src/root_leaf.tl"
      "(define leaf-val : i64 1)")
    (io.write-file
      "target/cl_moduleless_dotted_src/nested/dep.tl"
      "(import root_leaf as leaf)
(define dep-val : i64 leaf.leaf-val)")
    (io.write-file
      "target/cl_moduleless_dotted_src/entry.tl"
      "(module moduleless.dotted.entry)
(import nested.dep)
(define (main) : i64 dep.dep-val)")
    (match (compiler-load-file-with-paths
      "target/cl_moduleless_dotted_src/entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (compiler-load-decl-list-has-module-name? decls "root_leaf")
          (compiler-load-decl-list-has-module-name? decls "nested.dep")
          (compiler-load-decl-list-has-import-alias? decls "nested.dep" "dep")
          (sym_i64_env.sym-i64-contains seen "root_leaf")
          (sym_i64_env.sym-i64-contains seen "nested.dep"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-dotted-source-root-fallback-ok?) : bool
  (let
    [root : String "target/cl_dotted_src_fallback/src"]
    [tests : String (compiler-load-join-root-path root "tests")]
    [leaf : String (compiler-load-join-root-path root "leaf.tl")]
    [mid : String (compiler-load-join-root-path root "mid.tl")]
    [entry : String (compiler-load-join-root-path tests "entry.tl")]
    [roots : vector.StringVec
      (vector.string-vec-push (vector.string-vec-new) root)]
    (begin
      (compiler-load-test-mkdir "target/cl_dotted_src_fallback")
      (compiler-load-test-mkdir root)
      (compiler-load-test-mkdir tests)
      (io.write-file leaf "(module leaf)
(define leaf-val : i64 1)")
      (io.write-file
        mid
        "(module mid)
(import leaf)
(define mid-val : i64 leaf.leaf-val)")
      (io.write-file
        entry
        "(module fallback.entry)
(import \"../mid.tl\")
(define (main) : i64 mid-val)")
      (match (compiler-load-file-with-paths-and-roots
        entry
        (sym_i64_env.sym-i64-empty)
        roots)
        [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
          (and
            (sym_i64_env.sym-i64-contains seen "fallback.entry")
            (sym_i64_env.sym-i64-contains seen "mid")
            (sym_i64_env.sym-i64-contains seen "leaf"))]
        [(ResultCompilerLoadWithPaths.Err _) false]))))

(define (compiler-load-dotted-after-path-import-ok?) : bool
  (let
    [root : String "target/cl_dotted_after_path/src"]
    [tests : String (compiler-load-join-root-path root "tests")]
    [helper : String (compiler-load-join-root-path root "helper.tl")]
    [provider : String (compiler-load-join-root-path root "provider.tl")]
    [entry : String (compiler-load-join-root-path tests "entry.tl")]
    (begin
      (compiler-load-test-mkdir "target/cl_dotted_after_path")
      (compiler-load-test-mkdir root)
      (compiler-load-test-mkdir tests)
      (io.write-file helper "(module helper)
(define answer : i64 42)")
      (io.write-file
        provider
        "(module provider)
(import helper as helper)
(define value : i64 helper.answer)")
      (io.write-file
        entry
        "(import \"../provider.tl\")
(define (main) : i64 value)")
      (match (compiler-load-file-with-paths entry (sym_i64_env.sym-i64-empty))
        [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
          (and
            (sym_i64_env.sym-i64-contains seen "provider")
            (sym_i64_env.sym-i64-contains seen "helper"))]
        [(ResultCompilerLoadWithPaths.Err _) false]))))

(define (compiler-load-package-dotted-import-resolution-ok?) : bool
  (let
    [deps : CompilerPkgDeps (compiler-load-pkg-resolve-deps)]
    (and
      (match (compiler-load-resolve-package-import-spec
        "proj/src/main.tl"
        (AstImportKind.Module)
        "app.lib"
        (vector.string-vec-new)
        "proj"
        deps)
        [(ResultPkgResolve.Ok path) (string.eq path "proj/app/lib.tl")]
        [(ResultPkgResolve.Err _) false])
      (match (compiler-load-resolve-package-import-spec
        "proj/src/main.tl"
        (AstImportKind.Module)
        "math.src.add"
        (vector.string-vec-new)
        "proj"
        deps)
        [(ResultPkgResolve.Ok path) (string.eq path "math/src/add.tl")]
        [(ResultPkgResolve.Err _) false])
      (compiler-load-package-import-externs?
        (AstImportKind.Module)
        "math.src.add"
        deps)
      (not
        (compiler-load-package-import-externs?
          (AstImportKind.Module)
          "stdlib.core_macros"
          deps)))))

(define (compiler-load-package-dotted-sibling-source-ok?) : bool
  (let
    [root : String "target/cl_pkg_dotted_src"]
    [src : String (compiler-load-join-root-path root "src")]
    [entry : String (compiler-load-join-root-path src "main.tl")]
    [dep : String (compiler-load-join-root-path src "dep.tl")]
    [deps : CompilerPkgDeps (compiler-load-pkg-resolve-deps)]
    (begin
      (compiler-load-test-mkdir root)
      (compiler-load-test-mkdir src)
      (io.write-file dep "(module dep)
(define dep-val : i64 1)")
      (match (compiler-load-resolve-package-import-spec
        entry
        (AstImportKind.Module)
        "dep"
        (vector.string-vec-new)
        root
        deps)
        [(ResultPkgResolve.Ok path)
          (string.eq path (compiler-load-normalize-path dep))]
        [(ResultPkgResolve.Err _) false]))))

(define (compiler-load-package-moduleless-pkg-import-id-ok?) : bool
  (let
    [base : String "target/cl_pkg_moduleless_id"]
    [app-root : String (compiler-load-join-root-path base "app")]
    [app-src : String (compiler-load-join-root-path app-root "src")]
    [math-root : String (compiler-load-join-root-path base "math")]
    [math-src : String (compiler-load-join-root-path math-root "src")]
    [entry : String (compiler-load-join-root-path app-src "main.tl")]
    [dep : String (compiler-load-join-root-path math-src "add.tl")]
    [deps : CompilerPkgDeps
      (compiler-pkg-deps-from-list
        (CompilerPkgDepCons
          (CompilerPkgDep "math" "../math")
          (box CompilerPkgDepNil)))]
    (begin
      (compiler-load-test-mkdir base)
      (compiler-load-test-mkdir app-root)
      (compiler-load-test-mkdir app-src)
      (compiler-load-test-mkdir math-root)
      (compiler-load-test-mkdir math-src)
      (io.write-file
        (compiler-load-join-root-path math-root "typelisp.pkg")
        "(package (name \"math\") (version \"1\") (kind staticlib) (entry \"src/add.tl\"))")
      (io.write-file dep "(define (add [x : i64]) : i64 (+ x 1))")
      (io.write-file
        entry
        "(module pkg.moduleless.entry)
(import \"pkg:math/src/add.tl\")
(define (main) : i64 0)")
      (match (compiler-load-package-file-with-paths-and-roots
        entry
        (sym_i64_env.sym-i64-empty)
        (vector.string-vec-new)
        app-root
        deps)
        [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
          (and
            (compiler-load-decl-list-has-extern-symbol?
              decls
              "_tl_math_src_add_add")
            (sym_i64_env.sym-i64-contains seen "math.src.add")
            (not (sym_i64_env.sym-i64-contains seen dep)))]
        [(ResultCompilerLoadWithPaths.Err _) false]))))

(define (compiler-load-generated-meta-preserved-ok?) : bool
  (let
    [meta : AstGeneratedDeclMeta
      (AstGeneratedDeclMeta.Some "gen" "generated-fn" AstExprList.Nil "")]
    [inner : AstDecl
      (ast-decl-def-fn
        "generated-fn"
        AstParamList.Nil
        (AstType.I64)
        (ast-node-push (AstExpr.Literal (ast-lit-int 1))))]
    [decl : AstDecl (ast-decl-comptime-decl-with-meta meta inner)]
    (match (compiler-load-package-transform-decl
      "demo"
      ""
      (vector.string-vec-new)
      "src/main.tl"
      "main"
      decl)
      [(CompilerLoadSomeDecl transformed)
        (match transformed
          [(AstDecl.ComptimeDecl found-meta template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (and
                (match found-meta
                  [(AstGeneratedDeclMeta.Some generator item arg-keys _)
                    (and
                      (string.eq generator "gen")
                      (string.eq item "generated-fn")
                      (match arg-keys
                        [(AstExprList.Nil) true]
                        [_ false]))]
                  [_ false])
                (match template
                  [(AstDecl.Extern name _ _ _)
                    (string.eq (intern-str name) "generated-fn")]
                  [_ false])))]
          [_ false])]
      [(CompilerLoadNoDecl) false])))

;; Diamond import dedup (#1074 / #1041): entry imports A and B, both of which
;; import C; C must load exactly once. Writes fixture modules under target/ and
;; loads through the file loader, mirroring the existing dedup/cycle self-test.
(define (compiler-load-diamond-import-ok?) : bool
  (begin
    (io.write-file
      "target/cl_diamond_c.tl"
      "(module diamond.c)
(define c-val : i64 1)")
    (io.write-file
      "target/cl_diamond_a.tl"
      "(module diamond.a)
(import \"cl_diamond_c.tl\" module diamond.c as c)
(define a-val : i64 1)")
    (io.write-file
      "target/cl_diamond_b.tl"
      "(module diamond.b)
(import \"cl_diamond_c.tl\" module diamond.c as c)
(define b-val : i64 1)")
    (io.write-file
      "target/cl_diamond_entry.tl"
      "(module diamond.entry)
(import \"cl_diamond_a.tl\" module diamond.a as a)
(import \"cl_diamond_b.tl\" module diamond.b as b)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_diamond_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler-load-decl-list-count decls) 17)
          (sym_i64_env.sym-i64-contains seen "diamond.c")
          (sym_i64_env.sym-i64-contains seen "diamond.a")
          (sym_i64_env.sym-i64-contains seen "diamond.b")
          (sym_i64_env.sym-i64-contains seen "diamond.entry"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

;; Transitive import dedup (#1074 / #1041): entry imports A, A imports B, B
;; imports C; the whole chain loads with the deterministic loaded decl count and
;; every module recorded in the seen set.
(define (compiler-load-transitive-import-ok?) : bool
  (begin
    (io.write-file "target/cl_tr_c.tl" "(module tr.c)
(define c-val : i64 1)")
    (io.write-file
      "target/cl_tr_b.tl"
      "(module tr.b)
(import \"cl_tr_c.tl\" module tr.c as c)
(define b-val : i64 1)")
    (io.write-file
      "target/cl_tr_a.tl"
      "(module tr.a)
(import \"cl_tr_b.tl\" module tr.b as b)
(define a-val : i64 1)")
    (io.write-file
      "target/cl_tr_entry.tl"
      "(module tr.entry)
(import \"cl_tr_a.tl\" module tr.a as a)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_tr_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ seen)
        (and
          (= (compiler-load-decl-list-count decls) 14)
          (sym_i64_env.sym-i64-contains seen "tr.c")
          (sym_i64_env.sym-i64-contains seen "tr.b")
          (sym_i64_env.sym-i64-contains seen "tr.a")
          (sym_i64_env.sym-i64-contains seen "tr.entry"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

;; An `(import ...)` of a path that does not resolve to a readable file reports
;; a `cannot read import <path>` diagnostic (the imported-file diagnostic; #1074).
(define (compiler-load-missing-import-ok?) : bool
  (match (compiler-load-source
    "src/app.tl"
    "(import \"no_such_module_xyz.tl\")
(define value : i64 1)"
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoad.Err diag)
      (string.eq
        (compiler-diagnostic-message (box-get diag))
        "compiler-load: cannot read import src/no_such_module_xyz.tl")]
    [(ResultCompilerLoad.Ok _ _) false]))

(define (compiler-load-include-str-relative-ok?) : bool
  (begin
    (io.write-file "target/cl_include_payload.txt" "hello from include")
    (io.write-file
      "target/cl_include_entry.tl"
      "(include-str payload \"cl_include_payload.txt\")
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_include_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (compiler-load-first-string-def? decls "payload" "hello from include"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-include-str-stdlib-root-ok?) : bool
  (begin
    (io.write-file "target/cl_include_root_payload.txt" "hello from root")
    (match (compiler-load-source-with-paths-and-roots
      "src/include_entry.tl"
      "(include-str embedded \"stdlib/cl_include_root_payload.txt\")
(define (main) : i64 0)"
      (sym_i64_env.sym-i64-empty)
      (vector.string-vec-push (vector.string-vec-new) "target"))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (compiler-load-first-string-def? decls "embedded" "hello from root"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-missing-include-str-ok?) : bool
  (match (compiler-load-source
    "src/app.tl"
    "(include-str missing \"no_such_resource_xyz.txt\")
(define value : i64 1)"
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoad.Err diag)
      (string.eq
        (compiler-diagnostic-message (box-get diag))
        "compiler-load: cannot read include-str no_such_resource_xyz.txt from src/app.tl (resolved src/no_such_resource_xyz.txt)")]
    [(ResultCompilerLoad.Ok _ _) false]))

(define (compiler-load-include-str-raw-text-ok?) : bool
  (let
    [payload : String
      "(import \"definitely_missing.tl\")
(define injected : i64 7)"]
    (begin
      (io.write-file "target/cl_include_raw_payload.txt" payload)
      (io.write-file
        "target/cl_include_raw_entry.tl"
        "(include-str payload \"cl_include_raw_payload.txt\")
(define (main) : i64 0)")
      (match (compiler-load-file-with-paths
        "target/cl_include_raw_entry.tl"
        (sym_i64_env.sym-i64-empty))
        [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
          (and
            (= (compiler-load-decl-list-count decls) 2)
            (compiler-load-first-string-def? decls "payload" payload))]
        [(ResultCompilerLoadWithPaths.Err _) false]))))

(define (compiler-load-include-bin-relative-ok?) : bool
  (begin
    (io.write-file
      "target/cl_include_bin_payload.bin"
      (compiler-load-binary-fixture))
    (io.write-file
      "target/cl_include_bin_entry.tl"
      "(include-bin payload \"cl_include_bin_payload.bin\")
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_include_bin_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (compiler-load-first-bin-def? decls "payload"))]
      [(ResultCompilerLoadWithPaths.Err _) false])))

(define (compiler-load-missing-include-bin-ok?) : bool
  (match (compiler-load-source
    "src/app.tl"
    "(include-bin missing \"no_such_resource_xyz.bin\")
(define value : i64 1)"
    (sym_i64_env.sym-i64-empty))
    [(ResultCompilerLoad.Err diag)
      (string.eq
        (compiler-diagnostic-message (box-get diag))
        "compiler-load: cannot read include-bin no_such_resource_xyz.bin from src/app.tl (resolved src/no_such_resource_xyz.bin)")]
    [(ResultCompilerLoad.Ok _ _) false]))

(define (compiler-load-embedded-stdlib-lookup-ok?) : bool
  (match (compiler-load-embedded-stdlib-source "string.tl")
    [(CompilerEmbeddedStdlibSomeSource source)
      (match (compiler-load-source-with-paths-and-roots
        "stdlib/string.tl"
        source
        (sym_i64_env.sym-i64-empty)
        (vector.string-vec-new))
        [(ResultCompilerLoadWithPaths.Ok decls _ _ _)
          (> (compiler-load-decl-list-count decls) 0)]
        [(ResultCompilerLoadWithPaths.Err _) false])]
    [(CompilerEmbeddedStdlibNoSource) false]))

(define (compiler-load-embedded-stdlib-missing-ok?) : bool
  (match (compiler-load-embedded-stdlib-source "definitely_missing_xyz.tl")
    [(CompilerEmbeddedStdlibNoSource) true]
    [(CompilerEmbeddedStdlibSomeSource _) false]))

(define (compiler-load-embedded-stdlib-escape-rejected-ok?) : bool
  (match (compiler-load-embedded-stdlib-source "../string.tl")
    [(CompilerEmbeddedStdlibNoSource) true]
    [(CompilerEmbeddedStdlibSomeSource _) false]))

;; A parse error inside an imported file surfaces a diagnostic whose path is the
;; imported file (not the importer), preserving imported-file provenance (#1074).
(define (compiler-load-imported-parse-error-path-ok?) : bool
  (begin
    (io.write-file
      "target/cl_ipe_dep.tl"
      "(module ipe.dep)
(define broken : i64 )")
    (io.write-file
      "target/cl_ipe_entry.tl"
      "(module ipe.entry)
(import \"cl_ipe_dep.tl\" module ipe.dep as dep)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_ipe_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Err diag)
        (and
          (string.eq
            (compiler-diagnostic-path (box-get diag))
            "target/cl_ipe_dep.tl")
          (string.eq
            (compiler-diagnostic-message (box-get diag))
            "parse: malformed value definition"))]
      [(ResultCompilerLoadWithPaths.Ok _ _ _ _) false])))

;; A duplicate `(module ...)` declaration inside an imported file surfaces a
;; diagnostic whose path is the imported file, not the importer (#1074).
(define (compiler-load-imported-duplicate-module-path-ok?) : bool
  (begin
    (io.write-file
      "target/cl_idm_dep.tl"
      "(module idm.depa)
(module idm.depb)
(define v : i64 1)")
    (io.write-file
      "target/cl_idm_entry.tl"
      "(module idm.entry)
(import \"cl_idm_dep.tl\" module idm.depa as dep)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_idm_entry.tl"
      (sym_i64_env.sym-i64-empty))
      [(ResultCompilerLoadWithPaths.Err diag)
        (and
          (string.eq
            (compiler-diagnostic-path (box-get diag))
            "target/cl_idm_dep.tl")
          (string.eq
            (compiler-diagnostic-message (box-get diag))
            "compiler-load: duplicate module declaration"))]
      [(ResultCompilerLoadWithPaths.Ok _ _ _ _) false])))

;; A `stdlib/<x>` import whose importer-relative path is absent resolves through
;; a configured `--stdlib-root` (root fallback) (#1074).
(define (compiler-load-stdlib-root-fallback-ok?) : bool
  (begin
    (io.write-file "target/cl_srf_mod.tl" "(module srf.mod)
(define v : i64 1)")
    (io.write-file
      "target/cl_srf_entry.tl"
      "(module srf.entry)
(import \"stdlib/cl_srf_mod.tl\" module srf.mod as m)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths-and-roots
      "target/cl_srf_entry.tl"
      (sym_i64_env.sym-i64-empty)
      (vector.string-vec-push (vector.string-vec-new) "target"))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (sym_i64_env.sym-i64-contains seen "srf.mod")]
      [(ResultCompilerLoadWithPaths.Err _) false])))

;; `--stdlib-root` resolution searches roots in order; the first existing
;; candidate wins, so a missing leading root is skipped (#1074).
(define (compiler-load-stdlib-searched-root-ok?) : bool
  (begin
    (io.write-file "target/cl_ssr_mod.tl" "(module ssr.mod)
(define v : i64 1)")
    (io.write-file
      "target/cl_ssr_entry.tl"
      "(module ssr.entry)
(import \"stdlib/cl_ssr_mod.tl\" module ssr.mod as m)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths-and-roots
      "target/cl_ssr_entry.tl"
      (sym_i64_env.sym-i64-empty)
      (vector.string-vec-push
        (vector.string-vec-push
          (vector.string-vec-new)
          "target/cl_ssr_absent_root")
        "target"))
      [(ResultCompilerLoadWithPaths.Ok _ _ _ seen)
        (sym_i64_env.sym-i64-contains seen "ssr.mod")]
      [(ResultCompilerLoadWithPaths.Err _) false])))

;; A `stdlib/<x>` import found in no configured root reports a cannot-read
;; diagnostic naming the importer-relative candidate path (#1074).
(define (compiler-load-stdlib-unresolved-ok?) : bool
  (begin
    (io.write-file
      "target/cl_sur_entry.tl"
      "(module sur.entry)
(import \"stdlib/cl_sur_missing.tl\" module sur.mod as m)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths-and-roots
      "target/cl_sur_entry.tl"
      (sym_i64_env.sym-i64-empty)
      (vector.string-vec-push (vector.string-vec-new) "target"))
      [(ResultCompilerLoadWithPaths.Err diag)
        (string.eq
          (compiler-diagnostic-message (box-get diag))
          "compiler-load: cannot read import target/stdlib/cl_sur_missing.tl")]
      [(ResultCompilerLoadWithPaths.Ok _ _ _ _) false])))

;; A configured stdlib root must not serve a suffix that lexically escapes the
;; root with `..` (#1681).
(define (compiler-load-stdlib-root-escape-rejected-ok?) : bool
  (let
    [root-dir : String "target/cl_sre_root"]
    [entry-dir : String "target/cl_sre_entry_dir"]
    (begin
      (fs.mkdir-status-owned root-dir)
      (fs.mkdir-status-owned entry-dir)
      (io.write-file
        "target/cl_sre_out.tl"
        "(module sre.out)
(define v : i64 1)")
      (io.write-file
        "target/cl_sre_entry_dir/entry.tl"
        "(module sre.entry)
(import \"stdlib/../cl_sre_out.tl\" module sre.out as out)
(define (main) : i64 0)")
      (match (compiler-load-file-with-paths-and-roots
        "target/cl_sre_entry_dir/entry.tl"
        (sym_i64_env.sym-i64-empty)
        (vector.string-vec-push (vector.string-vec-new) "target/cl_sre_root"))
        [(ResultCompilerLoadWithPaths.Err _) true]
        [(ResultCompilerLoadWithPaths.Ok _ _ _ _) false]))))

;: --- typelisp.pkg manifest parser (#834, slice 1) ---------------------------
;: Parse a `typelisp.pkg` manifest, an S-expression of the form
;:   (package (name "...") (version "...") (kind "bin") (entry "...")
;:            (dependencies (alias "path") ...))
;: into a structured value. Reuses the selfhost reader (`lex` + `read-result`,
;: both already reachable here via compiler_parse_core -> read.tl) instead of a
;: bespoke manifest tokenizer.
;: A parsed dependency: an import alias and its package-root path.
(defstruct CompilerPkgDep
  (alias String)
  (path String))

;: Alias->path dependency list from a parsed manifest.
(defenum CompilerPkgDepList
  (CompilerPkgDepNil)
  (CompilerPkgDepCons CompilerPkgDep (Box CompilerPkgDepList)))

;: Package dependencies preserve manifest order for deterministic builds while
;: indexing aliases for duplicate detection and `pkg:<alias>/...` resolution.
(defstruct CompilerPkgDeps
  (ordered CompilerPkgDepList)
  (aliases hashmap.StringStringMap))

;: Package artifact kind: binary executable or static library.
(defenum CompilerPkgKind
  (CompilerPkgKindBin)
  (CompilerPkgKindLib))

;: A parsed `typelisp.pkg` manifest.
;: One link scope's native inputs: ordered libraries, search paths, and raw
;: linker arguments. Order within each list is preserved from the manifest.
(defstruct CompilerPkgLinkSet
  (libraries fs.FsStringVector)
  (search-paths fs.FsStringVector)
  (args fs.FsStringVector))

;: Parsed `(link ...)` manifest section. `all` applies to every target; `linux`
;: and `windows` add per-target inputs. Empty lists mean the field was omitted.
(defstruct CompilerPkgLink
  (all CompilerPkgLinkSet)
  (linux CompilerPkgLinkSet)
  (windows CompilerPkgLinkSet))

(defenum ResultCompilerPkgLink
  (Ok CompilerPkgLink)
  (Err String))

;: Internal: a parsed list of `link` field string values, or a diagnostic.
(defenum ResultPkgStrVec
  (Ok fs.FsStringVector)
  (Err String))

(defstruct CompilerPkgManifest
  (name String)
  (version String)
  (kind CompilerPkgKind)
  (entry String)
  (deps CompilerPkgDeps)
  (link CompilerPkgLink))

;: Parse result: the manifest or a legacy string diagnostic.
(defenum ResultCompilerPkgManifest
  (Ok CompilerPkgManifest)
  (Err String))

;: Source-facing parse result: the manifest or a path/span-bearing diagnostic.
(defenum ResultCompilerPkgManifestDiagnostic
  (Ok CompilerPkgManifest)
  (Err (Box CompilerDiagnostic)))

;: Internal: a single extracted string field value, or a diagnostic.
(defenum ResultPkgString
  (Ok String)
  (Err String))

;: Internal: a parsed package kind, or a diagnostic.
(defenum ResultCompilerPkgKind
  (Ok CompilerPkgKind)
  (Err String))

;: Internal: parsed dependencies, or a diagnostic.
(defenum ResultCompilerPkgDeps
  (Ok CompilerPkgDeps)
  (Err String))

;: Count the dependencies in a parsed list.
(define (compiler-pkg-dep-list-count [deps : CompilerPkgDepList]) : i64
  (match deps
    [(CompilerPkgDepNil) 0]
    [(CompilerPkgDepCons _ rest)
      (+ 1 (compiler-pkg-dep-list-count (box-get rest)))]))

(define (compiler-pkg-deps-empty) : CompilerPkgDeps
  (CompilerPkgDeps
    CompilerPkgDepNil
    (hashmap.string-string-map-with-capacity 8)))

(define (compiler-pkg-deps-list [deps : CompilerPkgDeps]) : CompilerPkgDepList
  (struct-get deps ordered))

(define (compiler-pkg-deps-count [deps : CompilerPkgDeps]) : i64
  (compiler-pkg-dep-list-count (compiler-pkg-deps-list deps)))

(define (compiler-pkg-deps-alias-seen?
  [deps : CompilerPkgDeps]
  [target-alias : String]) : bool
  (hashmap.string-string-map-contains? (struct-get deps aliases) target-alias))

(define (compiler-pkg-deps-cons
  [alias : String]
  [path : String]
  [tail : CompilerPkgDeps]) : CompilerPkgDeps
  (CompilerPkgDeps
    (CompilerPkgDepCons
      (CompilerPkgDep alias path)
      (box (compiler-pkg-deps-list tail)))
    (hashmap.string-string-map-put (struct-get tail aliases) alias path)))

(define (compiler-pkg-deps-from-list [deps : CompilerPkgDepList]) : CompilerPkgDeps
  (match deps
    [(CompilerPkgDepNil) (compiler-pkg-deps-empty)]
    [(CompilerPkgDepCons dep rest)
      (compiler-pkg-deps-cons
        (struct-get dep alias)
        (struct-get dep path)
        (compiler-pkg-deps-from-list (box-get rest)))]))

(define (compiler-load-package-name-char? [c : char]) : bool
  (let
    [code : i64 (cast c : i64)]
    (or
      (and (>= code 48) (<= code 57))
      (and (>= code 65) (<= code 90))
      (and (>= code 97) (<= code 122))
      (= code 45)
      (= code 95))))

(define (compiler-load-package-token-valid? [value : String]) : bool
  (let
    [n : i64 (string.string-length value)]
    [i : i64 0]
    [ok : bool (> n 0)]
    (begin
      (while ok
        (if (< i n)
          (if (compiler-load-package-name-char? (string.string-ref value i))
            (set! i (+ i 1))
            (set! ok false))
          (set! ok false)))
      (= i n))))

(define (compiler-load-github-component-char? [c : char]) : bool
  (or (compiler-load-package-name-char? c) (= c '.')))

(define (compiler-load-github-component-valid? [value : String]) : bool
  (let
    [n : i64 (string.string-length value)]
    [i : i64 0]
    [ok : bool (> n 0)]
    (begin
      (while ok
        (if (< i n)
          (if (compiler-load-github-component-char? (string.string-ref value i))
            (set! i (+ i 1))
            (set! ok false))
          (set! ok false)))
      (= i n))))

(define (compiler-load-github-dependency-path? [path : String]) : bool
  (compiler-load-string-prefix-at? path "https://github.com/" 0))

(define (compiler-load-github-pin-kind-valid? [kind : String]) : bool
  (or (string.eq kind "rev") (string.eq kind "tag") (string.eq kind "branch")))

(define (compiler-load-github-address-body [address : String]) : String
  (if (compiler-load-string-prefix-at? address "github.com/" 0)
    (string.substring address 11 (- (string.string-length address) 11))
    address))

(define (compiler-load-github-address-error [alias : String]) : ResultPkgString
  (ResultPkgString.Err
    (string.append
      "manifest dependency `"
      (string.append
        alias
        "` github address must be `owner/repo` or `github.com/owner/repo`"))))

(define (compiler-load-normalize-github-address
  [alias : String]
  [address : String]
  [pin-kind : String]
  [pin-value : String]) : ResultPkgString
  (let
    [body : String (compiler-load-github-address-body address)]
    [body-len : i64 (string.string-length body)]
    [slash : i64 (compiler-load-slash-index-from body 0 body-len)]
    (if (or (< slash 1) (>= slash (- body-len 1)))
      (compiler-load-github-address-error alias)
      (let
        [owner : String (string.substring body 0 slash)]
        [repo : String
          (string.substring body (+ slash 1) (- body-len (+ slash 1)))]
        (cond
          [(>=
              (compiler-load-slash-index-from
                repo
                0
                (string.string-length repo))
              0)
            (compiler-load-github-address-error alias)]
          [(not (compiler-load-github-component-valid? owner))
            (compiler-load-github-address-error alias)]
          [(not (compiler-load-github-component-valid? repo))
            (compiler-load-github-address-error alias)]
          [else
            (ResultPkgString.Ok
              (string.append
                "https://github.com/"
                (string.append
                  owner
                  (string.append
                    "/"
                    (string.append
                      repo
                      (string.append
                        ".git#"
                        (string.append pin-kind (string.append "=" pin-value))))))))])))))

(define (compiler-load-normal-relative-entry? [path : String]) : bool
  (compiler-load-safe-relative? path))

;: Extract a single `"value"` from a field tail `("value")`.
(define (compiler-load-manifest-string-value [ftail : Sexpr] [fname : String]) : ResultPkgString
  (match ftail
    [(Sexpr.Cons vhead vrest)
      (match (box-get vhead)
        [(Sexpr.Str val)
          (match (box-get vrest)
            [(Sexpr.Nil) (ResultPkgString.Ok val)]
            [_
              (ResultPkgString.Err
                (string.append
                  "manifest field `"
                  (string.append fname "` takes a single string value")))])]
        [_
          (ResultPkgString.Err
            (string.append
              "manifest field `"
              (string.append fname "` must have a string value")))])]
    [_
      (ResultPkgString.Err
        (string.append
          "manifest field `"
          (string.append fname "` must have a string value")))]))

(define (compiler-load-manifest-github-pin
  [alias : String]
  [address : String]
  [pin-form : Sexpr]) : ResultPkgString
  (match pin-form
    [(Sexpr.Cons pin-kind-node pin-tail)
      (match (box-get pin-kind-node)
        [(Sexpr.Sym pin-kind)
          (if (compiler-load-github-pin-kind-valid? pin-kind)
            (match (box-get pin-tail)
              [(Sexpr.Cons pin-value-node end)
                (match (box-get end)
                  [(Sexpr.Nil)
                    (match (box-get pin-value-node)
                      [(Sexpr.Str pin-value)
                        (if (string.eq pin-value "")
                          (ResultPkgString.Err
                            (string.append
                              "manifest dependency `"
                              (string.append
                                alias
                                "` github pin must not be empty")))
                          (compiler-load-normalize-github-address
                            alias
                            address
                            pin-kind
                            pin-value))]
                      [_
                        (ResultPkgString.Err
                          (string.append
                            "manifest dependency `"
                            (string.append
                              alias
                              "` github pin must be a single string value")))])]
                  [_
                    (ResultPkgString.Err
                      (string.append
                        "manifest dependency `"
                        (string.append
                          alias
                          "` github pin must be a single string value")))])]
              [_
                (ResultPkgString.Err
                  (string.append
                    "manifest dependency `"
                    (string.append
                      alias
                      "` github pin must be a single string value")))])
            (ResultPkgString.Err
              (string.append
                "manifest dependency `"
                (string.append alias "` github pin must be rev, tag, or branch"))))]
        [_
          (ResultPkgString.Err
            (string.append
              "manifest dependency `"
              (string.append
                alias
                "` github source requires exactly one rev, tag, or branch pin")))])]
    [_
      (ResultPkgString.Err
        (string.append
          "manifest dependency `"
          (string.append
            alias
            "` github source requires exactly one rev, tag, or branch pin")))]))

(define (compiler-load-manifest-github-value
  [alias : String]
  [source-tail : Sexpr]) : ResultPkgString
  (match source-tail
    [(Sexpr.Cons address-node after-address)
      (match (box-get address-node)
        [(Sexpr.Str address)
          (match (box-get after-address)
            [(Sexpr.Cons pin-form end)
              (match (box-get end)
                [(Sexpr.Nil)
                  (compiler-load-manifest-github-pin
                    alias
                    address
                    (box-get pin-form))]
                [_
                  (ResultPkgString.Err
                    (string.append
                      "manifest dependency `"
                      (string.append
                        alias
                        "` github source requires exactly one rev, tag, or branch pin")))])]
            [_
              (ResultPkgString.Err
                (string.append
                  "manifest dependency `"
                  (string.append
                    alias
                    "` github source requires exactly one rev, tag, or branch pin")))])]
        [_
          (ResultPkgString.Err
            (string.append
              "manifest dependency `"
              (string.append
                alias
                "` github source must be `(github \"owner/repo\" (rev|tag|branch \"pin\"))`")))])]
    [_
      (ResultPkgString.Err
        (string.append
          "manifest dependency `"
          (string.append
            alias
            "` github source must be `(github \"owner/repo\" (rev|tag|branch \"pin\"))`")))]))

(define (compiler-load-manifest-dependency-value
  [etail : Sexpr]
  [alias : String]) : ResultPkgString
  (match etail
    [(Sexpr.Cons vhead vrest)
      (match (box-get vrest)
        [(Sexpr.Nil)
          (match (box-get vhead)
            [(Sexpr.Str path) (ResultPkgString.Ok path)]
            [(Sexpr.Cons source-kind-node source-tail)
              (match (box-get source-kind-node)
                [(Sexpr.Sym source-kind)
                  (if (string.eq source-kind "github")
                    (compiler-load-manifest-github-value
                      alias
                      (box-get source-tail))
                    (ResultPkgString.Err
                      (string.append
                        "manifest dependency `"
                        (string.append
                          alias
                          "` must be a path string or github source"))))]
                [_
                  (ResultPkgString.Err
                    (string.append
                      "manifest dependency `"
                      (string.append
                        alias
                        "` must be a path string or github source")))])]
            [_
              (ResultPkgString.Err
                (string.append
                  "manifest dependency `"
                  (string.append
                    alias
                    "` must be a path string or github source")))])]
        [_
          (ResultPkgString.Err
            (string.append
              "manifest dependency `"
              (string.append
                alias
                "` takes a single path string or github source")))])]
    [_
      (ResultPkgString.Err
        (string.append
          "manifest dependency `"
          (string.append alias "` must be a path string or github source")))]))

(define (compiler-load-manifest-kind-token [val : String]) : ResultCompilerPkgKind
  (if (string.eq val "bin")
    (ResultCompilerPkgKind.Ok (CompilerPkgKindBin))
    (if (or (string.eq val "staticlib") (string.eq val "lib"))
      (ResultCompilerPkgKind.Ok (CompilerPkgKindLib))
      (ResultCompilerPkgKind.Err
        "manifest field `kind` must be `bin`, `staticlib`, or `lib`"))))

(define (compiler-load-manifest-kind-value [ftail : Sexpr]) : ResultCompilerPkgKind
  (match ftail
    [(Sexpr.Cons vhead vrest)
      (match (box-get vrest)
        [(Sexpr.Nil)
          (match (box-get vhead)
            [(Sexpr.Str val) (compiler-load-manifest-kind-token val)]
            [(Sexpr.Sym val) (compiler-load-manifest-kind-token val)]
            [_
              (ResultCompilerPkgKind.Err
                "manifest field `kind` must have a string or symbol value")])]
        [_
          (ResultCompilerPkgKind.Err
            "manifest field `kind` takes a single value")])]
    [_
      (ResultCompilerPkgKind.Err
        "manifest field `kind` must have a string or symbol value")]))

(define (compiler-load-manifest-cons-dep
  [alias : String]
  [path : String]
  [rest : Sexpr]) : ResultCompilerPkgDeps
  (cond
    [(string.eq alias "")
      (ResultCompilerPkgDeps.Err "dependency alias must not be empty")]
    [(not (compiler-load-package-token-valid? alias))
      (ResultCompilerPkgDeps.Err
        "dependency alias may only contain ASCII letters, digits, '-' and '_'")]
    [(string.eq path "")
      (ResultCompilerPkgDeps.Err
        (string.append
          "manifest dependency `"
          (string.append alias "` path must not be empty")))]
    [else
      (match (compiler-load-manifest-parse-deps rest)
        [(ResultCompilerPkgDeps.Err m) (ResultCompilerPkgDeps.Err m)]
        [(ResultCompilerPkgDeps.Ok tail-deps)
          (if (compiler-pkg-deps-alias-seen? tail-deps alias)
            (ResultCompilerPkgDeps.Err
              (string.append
                "duplicate dependency alias `"
                (string.append alias "`")))
            (ResultCompilerPkgDeps.Ok
              (compiler-pkg-deps-cons alias path tail-deps)))])]))

;: Parse the `(alias "path") ...` entries of a `(dependencies ...)` field.
(define (compiler-load-manifest-parse-deps [entries : Sexpr]) : ResultCompilerPkgDeps
  (match entries
    [(Sexpr.Nil) (ResultCompilerPkgDeps.Ok (compiler-pkg-deps-empty))]
    [(Sexpr.Cons entry rest)
      (match (box-get entry)
        [(Sexpr.Cons ehead etail)
          (match (box-get ehead)
            [(Sexpr.Sym alias)
              (match (compiler-load-manifest-dependency-value
                (box-get etail)
                alias)
                [(ResultPkgString.Err m) (ResultCompilerPkgDeps.Err m)]
                [(ResultPkgString.Ok path)
                  (compiler-load-manifest-cons-dep alias path (box-get rest))])]
            [_
              (ResultCompilerPkgDeps.Err
                "dependency entries must start with an alias name")])]
        [_
          (ResultCompilerPkgDeps.Err
            "dependency entries must be lists like `(alias \"path\")`")])]
    [_
      (ResultCompilerPkgDeps.Err
        "`dependencies` must be a list of `(alias \"path\")` or `(alias (github ...))` entries")]))

;: An empty link scope (no libraries, search paths, or args).
(define (compiler-pkg-link-set-empty) : CompilerPkgLinkSet
  (CompilerPkgLinkSet
    (fs.fs-string-vector-new)
    (fs.fs-string-vector-new)
    (fs.fs-string-vector-new)))

;: An empty `(link ...)` section (every scope empty).
(define (compiler-pkg-link-empty) : CompilerPkgLink
  (CompilerPkgLink
    (compiler-pkg-link-set-empty)
    (compiler-pkg-link-set-empty)
    (compiler-pkg-link-set-empty)))

;: Map a `link` sub-field name to its scope index, or -1 when unknown.
;: scope: 0 all-target, 1 linux, 2 windows.
(define (compiler-load-link-field-scope [fname : String]) : i64
  (cond
    [(string.eq fname "libraries") 0]
    [(string.eq fname "search-paths") 0]
    [(string.eq fname "args") 0]
    [(string.eq fname "linux-libraries") 1]
    [(string.eq fname "linux-search-paths") 1]
    [(string.eq fname "linux-args") 1]
    [(string.eq fname "windows-libraries") 2]
    [(string.eq fname "windows-search-paths") 2]
    [(string.eq fname "windows-args") 2]
    [else -1]))

;: Map a `link` sub-field name to its category index, or -1 when unknown.
;: category: 0 libraries, 1 search-paths, 2 args.
(define (compiler-load-link-field-category [fname : String]) : i64
  (cond
    [(string.eq fname "libraries") 0]
    [(string.eq fname "search-paths") 1]
    [(string.eq fname "args") 2]
    [(string.eq fname "linux-libraries") 0]
    [(string.eq fname "linux-search-paths") 1]
    [(string.eq fname "linux-args") 2]
    [(string.eq fname "windows-libraries") 0]
    [(string.eq fname "windows-search-paths") 1]
    [(string.eq fname "windows-args") 2]
    [else -1]))

;: The link scope's set for a scope index.
(define (compiler-pkg-link-scope-set [link : CompilerPkgLink] [scope : i64]) : CompilerPkgLinkSet
  (if (= scope 0)
    (struct-get link all)
    (if (= scope 1)
      (struct-get link linux)
      (struct-get link windows))))

;: Return `link` with the given scope's set replaced.
(define (compiler-pkg-link-replace-scope
  [link : CompilerPkgLink]
  [scope : i64]
  [set : CompilerPkgLinkSet]) : CompilerPkgLink
  (if (= scope 0)
    (CompilerPkgLink set (struct-get link linux) (struct-get link windows))
    (if (= scope 1)
      (CompilerPkgLink (struct-get link all) set (struct-get link windows))
      (CompilerPkgLink (struct-get link all) (struct-get link linux) set))))

;: The category's value list within a link scope set.
(define (compiler-pkg-link-set-category [set : CompilerPkgLinkSet] [cat : i64]) : fs.FsStringVector
  (if (= cat 0)
    (struct-get set libraries)
    (if (= cat 1)
      (struct-get set search-paths)
      (struct-get set args))))

;: Return `set` with the given category's value list replaced.
(define (compiler-pkg-link-set-replace-category
  [set : CompilerPkgLinkSet]
  [cat : i64]
  [vec : fs.FsStringVector]) : CompilerPkgLinkSet
  (if (= cat 0)
    (CompilerPkgLinkSet vec (struct-get set search-paths) (struct-get set args))
    (if (= cat 1)
      (CompilerPkgLinkSet (struct-get set libraries) vec (struct-get set args))
      (CompilerPkgLinkSet
        (struct-get set libraries)
        (struct-get set search-paths)
        vec))))

;: The value list for a (scope, category) pair.
(define (compiler-pkg-link-get-vec
  [link : CompilerPkgLink]
  [scope : i64]
  [cat : i64]) : fs.FsStringVector
  (compiler-pkg-link-set-category (compiler-pkg-link-scope-set link scope) cat))

;: Return `link` with the (scope, category) value list replaced.
(define (compiler-pkg-link-set-vec
  [link : CompilerPkgLink]
  [scope : i64]
  [cat : i64]
  [vec : fs.FsStringVector]) : CompilerPkgLink
  (compiler-pkg-link-replace-scope
    link
    scope
    (compiler-pkg-link-set-replace-category
      (compiler-pkg-link-scope-set link scope)
      cat
      vec)))

;: Parse the one-or-more non-empty string values of one `link` sub-field.
(define (compiler-load-manifest-link-values
  [values : Sexpr]
  [fname : String]
  [acc : fs.FsStringVector]) : ResultPkgStrVec
  (match values
    [(Sexpr.Nil)
      (if (= (fs.fs-string-vector-len (& acc)) 0)
        (ResultPkgStrVec.Err
          (string.append
            "`link` field `"
            (string.append fname "` requires at least one value")))
        (ResultPkgStrVec.Ok acc))]
    [(Sexpr.Cons vhead vrest)
      (match (box-get vhead)
        [(Sexpr.Str val)
          (if (string.eq val "")
            (ResultPkgStrVec.Err
              (string.append
                "`link` field `"
                (string.append fname "` values must not be empty")))
            (let
              [out : fs.FsStringVector acc]
              (begin
                (fs.fs-string-vector-push! (&mut out) val)
                (compiler-load-manifest-link-values (box-get vrest) fname out))))]
        [_
          (ResultPkgStrVec.Err
            (string.append
              "`link` field `"
              (string.append fname "` values must be strings")))])]
    [_
      (ResultPkgStrVec.Err
        (string.append
          "`link` field `"
          (string.append fname "` must be a list of string values")))]))

;: Store one parsed sub-field into the accumulating link section, rejecting
;: unknown field names and a field that was already provided.
(define (compiler-load-manifest-link-store
  [acc : CompilerPkgLink]
  [fname : String]
  [values : fs.FsStringVector]) : ResultCompilerPkgLink
  (let
    [scope : i64 (compiler-load-link-field-scope fname)]
    [cat : i64 (compiler-load-link-field-category fname)]
    (if (or (< scope 0) (< cat 0))
      (ResultCompilerPkgLink.Err
        (string.append "unknown `link` field `" (string.append fname "`")))
      (let
        [existing : fs.FsStringVector (compiler-pkg-link-get-vec acc scope cat)]
        (if (> (fs.fs-string-vector-len (& existing)) 0)
          (ResultCompilerPkgLink.Err
            (string.append "duplicate `link` field `" (string.append fname "`")))
          (ResultCompilerPkgLink.Ok
            (compiler-pkg-link-set-vec acc scope cat values)))))))

;: Walk the `(field "...")` entries of a `(link ...)` section.
(define (compiler-load-manifest-parse-link-into
  [entries : Sexpr]
  [acc : CompilerPkgLink]) : ResultCompilerPkgLink
  (match entries
    [(Sexpr.Nil) (ResultCompilerPkgLink.Ok acc)]
    [(Sexpr.Cons entry rest)
      (match (box-get entry)
        [(Sexpr.Cons ehead etail)
          (match (box-get ehead)
            [(Sexpr.Sym fname)
              (match (compiler-load-manifest-link-values
                (box-get etail)
                fname
                (fs.fs-string-vector-new))
                [(ResultPkgStrVec.Err m) (ResultCompilerPkgLink.Err m)]
                [(ResultPkgStrVec.Ok values)
                  (match (compiler-load-manifest-link-store acc fname values)
                    [(ResultCompilerPkgLink.Err m)
                      (ResultCompilerPkgLink.Err m)]
                    [(ResultCompilerPkgLink.Ok acc2)
                      (compiler-load-manifest-parse-link-into
                        (box-get rest)
                        acc2)])])]
            [_
              (ResultCompilerPkgLink.Err
                "`link` entries must start with a field name")])]
        [_
          (ResultCompilerPkgLink.Err
            "`link` entries must be lists like `(libraries \"...\")`")])]
    [_
      (ResultCompilerPkgLink.Err
        "`link` must be a list of `(field \"...\")` entries")]))

;: Parse a `(link ...)` manifest section into a CompilerPkgLink.
(define (compiler-load-manifest-parse-link [entries : Sexpr]) : ResultCompilerPkgLink
  (compiler-load-manifest-parse-link-into entries (compiler-pkg-link-empty)))

(define (compiler-load-manifest-default-entry [kind : CompilerPkgKind]) : String
  (match kind
    [(CompilerPkgKindBin) "src/main.tl"]
    [(CompilerPkgKindLib) "src/lib.tl"]))

(define (compiler-load-manifest-with-kind
  [manifest : CompilerPkgManifest]
  [kind : CompilerPkgKind]) : CompilerPkgManifest
  (CompilerPkgManifest
    (struct-get manifest name)
    (struct-get manifest version)
    kind
    (compiler-load-manifest-default-entry kind)
    (struct-get manifest deps)
    (struct-get manifest link)))

;: Walk the package fields, accumulating name/version/kind/entry/deps, then
;: check required fields and synthesize convention defaults for omitted kind
;: and entry.
(define (compiler-load-manifest-fields
  [fields : Sexpr]
  [name : String]
  [has-name : bool]
  [version : String]
  [has-version : bool]
  [kind : CompilerPkgKind]
  [has-kind : bool]
  [entry : String]
  [has-entry : bool]
  [has-deps : bool]
  [deps : CompilerPkgDeps]
  [has-link : bool]
  [link : CompilerPkgLink]) : ResultCompilerPkgManifest
  (match fields
    [(Sexpr.Nil)
      (let
        [final-entry : String
          (if has-entry
            entry
            (compiler-load-manifest-default-entry kind))]
        (cond
          [(not has-name)
            (ResultCompilerPkgManifest.Err
              "manifest missing required field `name`")]
          [(string.eq name "")
            (ResultCompilerPkgManifest.Err
              "manifest field `name` must not be empty")]
          [(not (compiler-load-package-token-valid? name))
            (ResultCompilerPkgManifest.Err
              "manifest field `name` may only contain ASCII letters, digits, '-' and '_'")]
          [(not has-version)
            (ResultCompilerPkgManifest.Err
              "manifest missing required field `version`")]
          [(string.eq version "")
            (ResultCompilerPkgManifest.Err
              "manifest field `version` must not be empty")]
          [(string.eq final-entry "")
            (ResultCompilerPkgManifest.Err
              "manifest field `entry` must not be empty")]
          [(not (compiler-load-normal-relative-entry? final-entry))
            (ResultCompilerPkgManifest.Err
              "manifest field `entry` must be a normal relative path below the manifest directory")]
          [else
            (ResultCompilerPkgManifest.Ok
              (CompilerPkgManifest name version kind final-entry deps link))]))]
    [(Sexpr.Cons field rest)
      (match (box-get field)
        [(Sexpr.Cons fhead ftail)
          (match (box-get fhead)
            [(Sexpr.Sym fname)
              (cond
                [(string.eq fname "dependencies")
                  (if has-deps
                    (ResultCompilerPkgManifest.Err
                      "duplicate manifest field `dependencies`")
                    (match (compiler-load-manifest-parse-deps (box-get ftail))
                      [(ResultCompilerPkgDeps.Err m)
                        (ResultCompilerPkgManifest.Err m)]
                      [(ResultCompilerPkgDeps.Ok parsed-deps)
                        (compiler-load-manifest-fields
                          (box-get rest)
                          name
                          has-name
                          version
                          has-version
                          kind
                          has-kind
                          entry
                          has-entry
                          true
                          parsed-deps
                          has-link
                          link)]))]
                [(string.eq fname "link")
                  (if has-link
                    (ResultCompilerPkgManifest.Err
                      "duplicate manifest field `link`")
                    (match (compiler-load-manifest-parse-link (box-get ftail))
                      [(ResultCompilerPkgLink.Err m)
                        (ResultCompilerPkgManifest.Err m)]
                      [(ResultCompilerPkgLink.Ok parsed-link)
                        (compiler-load-manifest-fields
                          (box-get rest)
                          name
                          has-name
                          version
                          has-version
                          kind
                          has-kind
                          entry
                          has-entry
                          has-deps
                          deps
                          true
                          parsed-link)]))]
                [(string.eq fname "name")
                  (if has-name
                    (ResultCompilerPkgManifest.Err
                      "duplicate manifest field `name`")
                    (match (compiler-load-manifest-string-value
                      (box-get ftail)
                      fname)
                      [(ResultPkgString.Err m)
                        (ResultCompilerPkgManifest.Err m)]
                      [(ResultPkgString.Ok val)
                        (compiler-load-manifest-fields
                          (box-get rest)
                          val
                          true
                          version
                          has-version
                          kind
                          has-kind
                          entry
                          has-entry
                          has-deps
                          deps
                          has-link
                          link)]))]
                [(string.eq fname "version")
                  (if has-version
                    (ResultCompilerPkgManifest.Err
                      "duplicate manifest field `version`")
                    (match (compiler-load-manifest-string-value
                      (box-get ftail)
                      fname)
                      [(ResultPkgString.Err m)
                        (ResultCompilerPkgManifest.Err m)]
                      [(ResultPkgString.Ok val)
                        (compiler-load-manifest-fields
                          (box-get rest)
                          name
                          has-name
                          val
                          true
                          kind
                          has-kind
                          entry
                          has-entry
                          has-deps
                          deps
                          has-link
                          link)]))]
                [(string.eq fname "kind")
                  (if has-kind
                    (ResultCompilerPkgManifest.Err
                      "duplicate manifest field `kind`")
                    (match (compiler-load-manifest-kind-value (box-get ftail))
                      [(ResultCompilerPkgKind.Err m)
                        (ResultCompilerPkgManifest.Err m)]
                      [(ResultCompilerPkgKind.Ok val)
                        (compiler-load-manifest-fields
                          (box-get rest)
                          name
                          has-name
                          version
                          has-version
                          val
                          true
                          entry
                          has-entry
                          has-deps
                          deps
                          has-link
                          link)]))]
                [(string.eq fname "entry")
                  (if has-entry
                    (ResultCompilerPkgManifest.Err
                      "duplicate manifest field `entry`")
                    (match (compiler-load-manifest-string-value
                      (box-get ftail)
                      fname)
                      [(ResultPkgString.Err m)
                        (ResultCompilerPkgManifest.Err m)]
                      [(ResultPkgString.Ok val)
                        (compiler-load-manifest-fields
                          (box-get rest)
                          name
                          has-name
                          version
                          has-version
                          kind
                          has-kind
                          val
                          true
                          has-deps
                          deps
                          has-link
                          link)]))]
                [else
                  (ResultCompilerPkgManifest.Err
                    (string.append
                      "unknown manifest field `"
                      (string.append fname "`")))])]
            [_
              (ResultCompilerPkgManifest.Err
                "package fields must start with a field name")])]
        [_
          (ResultCompilerPkgManifest.Err
            "package fields must be lists like `(name \"...\")`")])]
    [_
      (ResultCompilerPkgManifest.Err
        "package fields must be lists like `(name \"...\")`")]))

;: Parse the top-level `(package ...)` form.
(define (compiler-load-manifest-from-form [form : Sexpr]) : ResultCompilerPkgManifest
  (match form
    [(Sexpr.Cons head rest)
      (match (box-get head)
        [(Sexpr.Sym s)
          (if (string.eq s "package")
            (compiler-load-manifest-fields
              (box-get rest)
              ""
              false
              ""
              false
              (CompilerPkgKindBin)
              false
              ""
              false
              false
              (compiler-pkg-deps-empty)
              false
              (compiler-pkg-link-empty))
            (ResultCompilerPkgManifest.Err
              (string.append
                "expected `package` form, got `"
                (string.append s "`"))))]
        [_ (ResultCompilerPkgManifest.Err "manifest must start with `package`")])]
    [_
      (ResultCompilerPkgManifest.Err "manifest must be a `(package ...)` form")]))

(define (compiler-load-manifest-fields-have? [fields : Sexpr] [target : String]) : bool
  (match fields
    [(Sexpr.Nil) false]
    [(Sexpr.Cons field rest)
      (let
        [tail-has : bool
          (compiler-load-manifest-fields-have? (box-get rest) target)]
        (match (box-get field)
          [(Sexpr.Cons fhead _)
            (match (box-get fhead)
              [(Sexpr.Sym name) (or (string.eq name target) tail-has)]
              [_ tail-has])]
          [_ tail-has]))]
    [_ false]))

(define (compiler-load-manifest-form-has-field?
  [form : Sexpr]
  [target : String]) : bool
  (match form
    [(Sexpr.Cons head rest)
      (match (box-get head)
        [(Sexpr.Sym s)
          (if (string.eq s "package")
            (compiler-load-manifest-fields-have? (box-get rest) target)
            false)]
        [_ false])]
    [_ false]))

(define (compiler-load-manifest-needs-kind-inference? [form : Sexpr]) : bool
  (and
    (not (compiler-load-manifest-form-has-field? form "kind"))
    (not (compiler-load-manifest-form-has-field? form "entry"))))

(define (compiler-load-manifest-convention-path
  [manifest-path : String]
  [relative : String]) : String
  (compiler-load-join-root-path (compiler-load-dirname manifest-path) relative))

(define (compiler-load-manifest-infer-kind-from-files [manifest-path : String]) : ResultCompilerPkgKind
  (let
    [has-main : bool
      (io.file-exists?
        (compiler-load-manifest-convention-path manifest-path "src/main.tl"))]
    [has-lib : bool
      (io.file-exists?
        (compiler-load-manifest-convention-path manifest-path "src/lib.tl"))]
    (cond
      [(and has-main (not has-lib))
        (ResultCompilerPkgKind.Ok (CompilerPkgKindBin))]
      [(and has-lib (not has-main))
        (ResultCompilerPkgKind.Ok (CompilerPkgKindLib))]
      [(and has-main has-lib)
        (ResultCompilerPkgKind.Err
          "manifest omits `kind` and `entry`, but both `src/main.tl` and `src/lib.tl` exist; add explicit `kind` or `entry`")]
      [else
        (ResultCompilerPkgKind.Err
          "manifest omits `kind` and `entry`, but neither `src/main.tl` nor `src/lib.tl` exists; add `kind` and `entry` or create a conventional entry file")])))

;: Preserve the legacy `manifest: ...` syntax-error message while attaching the
;: reader span to the source-facing diagnostic result.
(define (compiler-load-manifest-source-error-diagnostic
  [path : String]
  [err : token.SourceError]) : CompilerDiagnostic
  (compiler-diagnostic-from-span
    path
    (token.source-error-span err)
    (string.append "manifest: " (token.source-error-message err))))

(define (compiler-load-manifest-validation-diagnostic
  [path : String]
  [form : SpannedSexpr]
  [message : String]) : CompilerDiagnostic
  (compiler-diagnostic-from-span path (spanned-sexpr-span form) message))

(define (compiler-load-manifest-apply-kind-inference
  [path : String]
  [form : SpannedSexpr]
  [manifest : CompilerPkgManifest]) : ResultCompilerPkgManifestDiagnostic
  (let
    [raw-form : Sexpr (spanned-sexpr-form form)]
    (if (compiler-load-manifest-needs-kind-inference? raw-form)
      (match (compiler-load-manifest-infer-kind-from-files path)
        [(ResultCompilerPkgKind.Ok kind)
          (ResultCompilerPkgManifestDiagnostic.Ok
            (compiler-load-manifest-with-kind manifest kind))]
        [(ResultCompilerPkgKind.Err message)
          (ResultCompilerPkgManifestDiagnostic.Err
            (box
              (compiler-load-manifest-validation-diagnostic path form message)))])
      (ResultCompilerPkgManifestDiagnostic.Ok manifest))))

(define (compiler-load-parse-manifest-form-diagnostic
  [path : String]
  [form : SpannedSexpr]) : ResultCompilerPkgManifestDiagnostic
  (match (compiler-load-manifest-from-form (spanned-sexpr-form form))
    [(ResultCompilerPkgManifest.Ok manifest)
      (ResultCompilerPkgManifestDiagnostic.Ok manifest)]
    [(ResultCompilerPkgManifest.Err message)
      (ResultCompilerPkgManifestDiagnostic.Err
        (box (compiler-load-manifest-validation-diagnostic path form message)))]))

(define (compiler-load-parse-manifest-form-diagnostic-infer-kind
  [path : String]
  [form : SpannedSexpr]) : ResultCompilerPkgManifestDiagnostic
  (match (compiler-load-manifest-from-form (spanned-sexpr-form form))
    [(ResultCompilerPkgManifest.Ok manifest)
      (compiler-load-manifest-apply-kind-inference path form manifest)]
    [(ResultCompilerPkgManifest.Err message)
      (ResultCompilerPkgManifestDiagnostic.Err
        (box (compiler-load-manifest-validation-diagnostic path form message)))]))

;: Parse a `typelisp.pkg` manifest source string into a structured manifest,
;: preserving manifest path/span identity for source-facing errors.
(define (compiler-load-parse-manifest-diagnostic
  [path : String]
  [source : String]) : ResultCompilerPkgManifestDiagnostic
  (begin
    (sp-node-pool-reset!)
    (match (lex-spanned-result source)
      [(ResultSpannedTokens.Err err)
        (ResultCompilerPkgManifestDiagnostic.Err
          (box (compiler-load-manifest-source-error-diagnostic path err)))]
      [(ResultSpannedTokens.Ok toks)
        (match (read-spanned-result toks)
          [(ResultSpannedSexpr.Err err)
            (ResultCompilerPkgManifestDiagnostic.Err
              (box (compiler-load-manifest-source-error-diagnostic path err)))]
          [(ResultSpannedSexpr.Ok form)
            (compiler-load-parse-manifest-form-diagnostic path form)])])))

(define (compiler-load-parse-manifest-diagnostic-infer-kind
  [path : String]
  [source : String]) : ResultCompilerPkgManifestDiagnostic
  (begin
    (sp-node-pool-reset!)
    (match (lex-spanned-result source)
      [(ResultSpannedTokens.Err err)
        (ResultCompilerPkgManifestDiagnostic.Err
          (box (compiler-load-manifest-source-error-diagnostic path err)))]
      [(ResultSpannedTokens.Ok toks)
        (match (read-spanned-result toks)
          [(ResultSpannedSexpr.Err err)
            (ResultCompilerPkgManifestDiagnostic.Err
              (box (compiler-load-manifest-source-error-diagnostic path err)))]
          [(ResultSpannedSexpr.Ok form)
            (compiler-load-parse-manifest-form-diagnostic-infer-kind path form)])])))

;: Parse a manifest source string into a structured manifest. This compatibility
;: wrapper keeps existing in-memory parser callers and message-only tests stable.
(define (compiler-load-parse-manifest [source : String]) : ResultCompilerPkgManifest
  (match (compiler-load-parse-manifest-diagnostic "" source)
    [(ResultCompilerPkgManifestDiagnostic.Ok manifest)
      (ResultCompilerPkgManifest.Ok manifest)]
    [(ResultCompilerPkgManifestDiagnostic.Err diag)
      (ResultCompilerPkgManifest.Err
        (compiler-diagnostic-message (box-get diag)))]))

;: Self-test: a full manifest parses with the expected fields + dependency
;: count.
(define (compiler-load-manifest-valid-full-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"demo\") (version \"0.1.0\") (kind \"bin\") (entry \"src/main.tl\") (dependencies (math \"../math\") (util \"../util\")))")
    [(ResultCompilerPkgManifest.Ok m)
      (and
        (string.eq (struct-get m name) "demo")
        (string.eq (struct-get m version) "0.1.0")
        (match (struct-get m kind)
          [(CompilerPkgKindBin)
            (and
              (string.eq (struct-get m entry) "src/main.tl")
              (= (compiler-pkg-deps-count (struct-get m deps)) 2))]
          [(CompilerPkgKindLib) false]))]
    [(ResultCompilerPkgManifest.Err _) false]))

;: Self-test: a manifest without a `dependencies` field parses with no deps.
(define (compiler-load-manifest-valid-nodeps-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"x\") (version \"1\") (kind staticlib))")
    [(ResultCompilerPkgManifest.Ok m)
      (match (struct-get m kind)
        [(CompilerPkgKindLib)
          (and
            (string.eq (struct-get m entry) "src/lib.tl")
            (= (compiler-pkg-deps-count (struct-get m deps)) 0))]
        [(CompilerPkgKindBin) false])]
    [(ResultCompilerPkgManifest.Err _) false]))

(define (compiler-load-manifest-default-bin-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"default_bin\") (version \"1\"))")
    [(ResultCompilerPkgManifest.Ok m)
      (match (struct-get m kind)
        [(CompilerPkgKindBin) (string.eq (struct-get m entry) "src/main.tl")]
        [(CompilerPkgKindLib) false])]
    [(ResultCompilerPkgManifest.Err _) false]))

(define (compiler-load-manifest-entry-override-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"override\") (version \"1\") (kind \"staticlib\") (entry \"custom/lib.tl\"))")
    [(ResultCompilerPkgManifest.Ok m)
      (match (struct-get m kind)
        [(CompilerPkgKindLib) (string.eq (struct-get m entry) "custom/lib.tl")]
        [(CompilerPkgKindBin) false])]
    [(ResultCompilerPkgManifest.Err _) false]))

(define (compiler-load-manifest-dep-path-is?
  [deps : CompilerPkgDeps]
  [alias : String]
  [expected : String]) : bool
  (match (compiler-load-pkg-dep-lookup deps alias)
    [(CompilerLoadSomePath path) (string.eq path expected)]
    [(CompilerLoadNoPath) false]))

(define (compiler-load-pkg-deps-three-alias-order?
  [deps : CompilerPkgDeps]
  [first-alias : String]
  [second-alias : String]
  [third-alias : String]) : bool
  (match (compiler-pkg-deps-list deps)
    [(CompilerPkgDepCons first rest1)
      (and
        (string.eq (struct-get first alias) first-alias)
        (match (box-get rest1)
          [(CompilerPkgDepCons second rest2)
            (and
              (string.eq (struct-get second alias) second-alias)
              (match (box-get rest2)
                [(CompilerPkgDepCons third rest3)
                  (and
                    (string.eq (struct-get third alias) third-alias)
                    (match (box-get rest3)
                      [(CompilerPkgDepNil) true]
                      [(CompilerPkgDepCons _ _) false]))]
                [(CompilerPkgDepNil) false]))]
          [(CompilerPkgDepNil) false]))]
    [(CompilerPkgDepNil) false]))

(define (compiler-load-manifest-github-deps-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"github_demo\") (version \"1\") (kind \"bin\") (entry \"src/main.tl\") (dependencies (math (github \"JoNil-Botta/math\" (rev \"abc123\"))) (util (github \"github.com/JoNil-Botta/util.repo\" (tag \"v1.0.0\"))) (core \"../core\")))")
    [(ResultCompilerPkgManifest.Ok m)
      (let
        [deps : CompilerPkgDeps (struct-get m deps)]
        (and
          (= (compiler-pkg-deps-count deps) 3)
          (compiler-load-pkg-deps-three-alias-order? deps "math" "util" "core")
          (compiler-load-manifest-dep-path-is?
            deps
            "math"
            "https://github.com/JoNil-Botta/math.git#rev=abc123")
          (compiler-load-manifest-dep-path-is?
            deps
            "util"
            "https://github.com/JoNil-Botta/util.repo.git#tag=v1.0.0")
          (compiler-load-manifest-dep-path-is? deps "core" "../core")))]
    [(ResultCompilerPkgManifest.Err _) false]))

;: True when parsing `source` fails with exactly the `expected` diagnostic.
(define (compiler-load-manifest-rejects? [source : String] [expected : String]) : bool
  (match (compiler-load-parse-manifest source)
    [(ResultCompilerPkgManifest.Err m) (string.eq m expected)]
    [(ResultCompilerPkgManifest.Ok _) false]))

(define (compiler-load-manifest-diagnostic-span-forward?
  [diag : CompilerDiagnostic]) : bool
  (or
    (> (compiler-diagnostic-end-line diag) (compiler-diagnostic-line diag))
    (and
      (= (compiler-diagnostic-end-line diag) (compiler-diagnostic-line diag))
      (>= (compiler-diagnostic-end-col diag) (compiler-diagnostic-col diag)))))

(define (compiler-load-manifest-diagnostic-rejects?
  [path : String]
  [source : String]
  [expected : String]
  [line : i64]
  [col : i64]) : bool
  (match (compiler-load-parse-manifest-diagnostic path source)
    [(ResultCompilerPkgManifestDiagnostic.Err diag)
      (and
        (string.eq (compiler-diagnostic-path (box-get diag)) path)
        (= (compiler-diagnostic-line (box-get diag)) line)
        (= (compiler-diagnostic-col (box-get diag)) col)
        (compiler-load-manifest-diagnostic-span-forward? (box-get diag))
        (string.eq (compiler-diagnostic-message (box-get diag)) expected))]
    [(ResultCompilerPkgManifestDiagnostic.Ok _) false]))

(define (compiler-load-pkg-manifest-diagnostic-ok?) : bool
  (and
    (compiler-load-manifest-diagnostic-rejects?
      "pkg/typelisp.pkg"
      "("
      "manifest: reader: unterminated list: reached end of input before ')'"
      1
      1)
    (compiler-load-manifest-diagnostic-rejects?
      "pkg/typelisp.pkg"
      "(module foo)"
      "expected `package` form, got `module`"
      1
      1)))

(define (compiler-load-manifest-test-mkdir [path : String]) : bool
  (match (fs.try-mkdir-if-missing (& path))
    [(io.OkIoUnit) true]
    [(io.ErrIoUnit _) false]))

(define (compiler-load-manifest-test-write [path : String] [contents : String]) : bool
  (match (io.try-write-file (& path) (& contents))
    [(io.OkIoUnit) true]
    [(io.ErrIoUnit _) false]))

(define (compiler-load-manifest-test-root [name : String]) : String
  (compiler-load-join-root-path "target" name))

(define (compiler-load-manifest-test-src [root : String]) : String
  (compiler-load-join-root-path root "src"))

(define (compiler-load-manifest-test-path [root : String] [relative : String]) : String
  (compiler-load-join-root-path root relative))

(define (compiler-load-manifest-write-convention-fixture
  [root : String]
  [manifest : String]
  [has-main : bool]
  [has-lib : bool]) : bool
  (let
    [src : String (compiler-load-manifest-test-src root)]
    [ok-target : bool (compiler-load-manifest-test-mkdir "target")]
    [ok-root : bool (compiler-load-manifest-test-mkdir root)]
    [ok-src : bool (compiler-load-manifest-test-mkdir src)]
    [ok-manifest : bool
      (compiler-load-manifest-test-write
        (compiler-load-manifest-test-path root "typelisp.pkg")
        manifest)]
    [ok-main : bool
      (if has-main
        (compiler-load-manifest-test-write
          (compiler-load-manifest-test-path root "src/main.tl")
          "(define (main) : i64 42)")
        true)]
    [ok-lib : bool
      (if has-lib
        (compiler-load-manifest-test-write
          (compiler-load-manifest-test-path root "src/lib.tl")
          "(define lib-value : i64 42)")
        true)]
    (and ok-target ok-root ok-src ok-manifest ok-main ok-lib)))

(define (compiler-load-manifest-path-kind-entry-is?
  [path : String]
  [expected-kind : CompilerPkgKind]
  [expected-entry : String]) : bool
  (match (compiler-load-parse-manifest-diagnostic-infer-kind
    path
    (io.read-file path))
    [(ResultCompilerPkgManifestDiagnostic.Ok manifest)
      (and
        (string.eq (struct-get manifest entry) expected-entry)
        (match (struct-get manifest kind)
          [(CompilerPkgKindBin)
            (match expected-kind
              [(CompilerPkgKindBin) true]
              [(CompilerPkgKindLib) false])]
          [(CompilerPkgKindLib)
            (match expected-kind
              [(CompilerPkgKindLib) true]
              [(CompilerPkgKindBin) false])]))]
    [(ResultCompilerPkgManifestDiagnostic.Err _) false]))

(define (compiler-load-manifest-path-rejects?
  [path : String]
  [expected : String]) : bool
  (match (compiler-load-parse-manifest-diagnostic-infer-kind
    path
    (io.read-file path))
    [(ResultCompilerPkgManifestDiagnostic.Err diag)
      (string.eq (compiler-diagnostic-message (box-get diag)) expected)]
    [(ResultCompilerPkgManifestDiagnostic.Ok _) false]))

(define (compiler-load-manifest-infer-bin-only-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_bin_only")]
    [manifest-path : String
      (compiler-load-manifest-test-path root "typelisp.pkg")]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"bin_only\") (version \"1\"))"
        true
        false)
      (compiler-load-manifest-path-kind-entry-is?
        manifest-path
        (CompilerPkgKindBin)
        "src/main.tl"))))

(define (compiler-load-manifest-infer-lib-only-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_lib_only")]
    [manifest-path : String
      (compiler-load-manifest-test-path root "typelisp.pkg")]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"lib_only\") (version \"1\"))"
        false
        true)
      (compiler-load-manifest-path-kind-entry-is?
        manifest-path
        (CompilerPkgKindLib)
        "src/lib.tl"))))

(define (compiler-load-manifest-infer-ambiguous-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_ambiguous")]
    [manifest-path : String
      (compiler-load-manifest-test-path root "typelisp.pkg")]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"ambiguous\") (version \"1\"))"
        true
        true)
      (compiler-load-manifest-path-rejects?
        manifest-path
        "manifest omits `kind` and `entry`, but both `src/main.tl` and `src/lib.tl` exist; add explicit `kind` or `entry`"))))

(define (compiler-load-manifest-infer-missing-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_missing")]
    [manifest-path : String
      (compiler-load-manifest-test-path root "typelisp.pkg")]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"missing\") (version \"1\"))"
        false
        false)
      (compiler-load-manifest-path-rejects?
        manifest-path
        "manifest omits `kind` and `entry`, but neither `src/main.tl` nor `src/lib.tl` exists; add `kind` and `entry` or create a conventional entry file"))))

(define (compiler-load-manifest-infer-explicit-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_explicit")]
    [manifest-path : String
      (compiler-load-manifest-test-path root "typelisp.pkg")]
    [explicit-entry-root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_explicit_entry")]
    [explicit-entry-path : String
      (compiler-load-manifest-test-path explicit-entry-root "typelisp.pkg")]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"explicit\") (version \"1\") (kind staticlib))"
        true
        true)
      (compiler-load-manifest-path-kind-entry-is?
        manifest-path
        (CompilerPkgKindLib)
        "src/lib.tl")
      (compiler-load-manifest-write-convention-fixture
        explicit-entry-root
        "(package (name \"explicit_entry\") (version \"1\") (entry \"custom.tl\"))"
        false
        true)
      (compiler-load-manifest-path-kind-entry-is?
        explicit-entry-path
        (CompilerPkgKindBin)
        "custom.tl"))))

(define (compiler-load-manifest-infer-package-entry-ok?) : bool
  (let
    [root : String
      (compiler-load-manifest-test-root "compiler_load_pkg_entry_lib_only")]
    [source-path : String (compiler-load-manifest-test-path root "src/lib.tl")]
    [expected-entry : String (compiler-load-normalize-path source-path)]
    (and
      (compiler-load-manifest-write-convention-fixture
        root
        "(package (name \"entry_dep\") (version \"1\"))"
        false
        true)
      (match (compiler-load-package-entry-for-source source-path)
        [(ResultCompilerLoadPackageEntry.Ok entry)
          (and
            (string.eq (struct-get entry owner) "entry_dep")
            (string.eq (struct-get entry entry-path) expected-entry))]
        [(ResultCompilerLoadPackageEntry.Err _) false]))))

(define (compiler-load-manifest-path-inference-ok?) : bool
  (and
    (compiler-load-manifest-infer-bin-only-ok?)
    (compiler-load-manifest-infer-lib-only-ok?)
    (compiler-load-manifest-infer-ambiguous-ok?)
    (compiler-load-manifest-infer-missing-ok?)
    (compiler-load-manifest-infer-explicit-ok?)
    (compiler-load-manifest-infer-package-entry-ok?)))

(define (compiler-load-pkg-manifest-github-validation-ok?) : bool
  (and
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math (github \"owner/repo\"))))"
      "manifest dependency `math` github source requires exactly one rev, tag, or branch pin")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math (github \"owner/repo/extra\" (rev \"abc\")))))"
      "manifest dependency `math` github address must be `owner/repo` or `github.com/owner/repo`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math (github \"owner/repo\" (sha \"abc\")))))"
      "manifest dependency `math` github pin must be rev, tag, or branch")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math (github \"owner/repo\" (rev \"\")))))"
      "manifest dependency `math` github pin must not be empty")))

(define (compiler-load-pkg-manifest-validation-ok?) : bool
  (and
    (compiler-load-manifest-rejects?
      "(package (name \"demo\") (name \"again\") (version \"1\") (kind \"bin\") (entry \"e.tl\"))"
      "duplicate manifest field `name`")
    (compiler-load-manifest-rejects?
      "(package (name \"\") (version \"1\") (kind \"bin\") (entry \"e.tl\"))"
      "manifest field `name` must not be empty")
    (compiler-load-manifest-rejects?
      "(package (name \"bad.name\") (version \"1\") (kind \"bin\") (entry \"e.tl\"))"
      "manifest field `name` may only contain ASCII letters, digits, '-' and '_'")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"\") (kind \"bin\") (entry \"e.tl\"))"
      "manifest field `version` must not be empty")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bad\") (entry \"e.tl\"))"
      "manifest field `kind` must be `bin`, `staticlib`, or `lib`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (kind \"lib\") (entry \"e.tl\"))"
      "duplicate manifest field `kind`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"\"))"
      "manifest field `entry` must not be empty")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"../main.tl\"))"
      "manifest field `entry` must be a normal relative path below the manifest directory")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math \"a\")) (dependencies (util \"b\")))"
      "duplicate manifest field `dependencies`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math \"a\") (math \"b\")))"
      "duplicate dependency alias `math`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (bad.alias \"a\")))"
      "dependency alias may only contain ASCII letters, digits, '-' and '_'")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (dependencies (math \"\")))"
      "manifest dependency `math` path must not be empty")))

;: True when a package link string vector is empty.
(define (compiler-load-link-vec-empty? [vec : (& vec fs.FsStringVector)]) : bool
  (= (fs.fs-string-vector-len vec) 0))

;: True when a package link string vector holds exactly one value equal to `a`.
(define (compiler-load-link-vec-single?
  [vec : (& vec fs.FsStringVector)]
  [a : String]) : bool
  (and
    (= (fs.fs-string-vector-len vec) 1)
    (string.eq (fs.fs-string-vector-get vec 0 "") a)))

;: True when a package link string vector holds exactly `a` then `b`, in order.
(define (compiler-load-link-vec-pair?
  [vec : (& vec fs.FsStringVector)]
  [a : String]
  [b : String]) : bool
  (and
    (= (fs.fs-string-vector-len vec) 2)
    (string.eq (fs.fs-string-vector-get vec 0 "") a)
    (string.eq (fs.fs-string-vector-get vec 1 "") b)))

;: Self-test: a `(link ...)` section parses into all-target and per-target sets
;: with manifest order preserved.
(define (compiler-load-manifest-link-valid-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"p\") (version \"1\") (kind \"bin\") (entry \"src/main.tl\") (link (libraries \"raylib\") (search-paths \"vendor/lib\") (linux-libraries \"GL\" \"m\") (linux-args \"-Wl,--as-needed\") (windows-libraries \"opengl32\")))")
    [(ResultCompilerPkgManifest.Ok m)
      (let
        [link : CompilerPkgLink (struct-get m link)]
        [all : CompilerPkgLinkSet (struct-get link all)]
        [lin : CompilerPkgLinkSet (struct-get link linux)]
        [win : CompilerPkgLinkSet (struct-get link windows)]
        (and
          (compiler-load-link-vec-single?
            (& (struct-get all libraries))
            "raylib")
          (compiler-load-link-vec-single?
            (& (struct-get all search-paths))
            "vendor/lib")
          (compiler-load-link-vec-empty? (& (struct-get all args)))
          (compiler-load-link-vec-pair? (& (struct-get lin libraries)) "GL" "m")
          (compiler-load-link-vec-single?
            (& (struct-get lin args))
            "-Wl,--as-needed")
          (compiler-load-link-vec-single?
            (& (struct-get win libraries))
            "opengl32")))]
    [(ResultCompilerPkgManifest.Err _) false]))

;: Self-test: a manifest with no `link` section parses with empty link sets.
(define (compiler-load-manifest-link-default-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"p\") (version \"1\") (kind \"bin\") (entry \"src/main.tl\"))")
    [(ResultCompilerPkgManifest.Ok m)
      (let
        [link : CompilerPkgLink (struct-get m link)]
        (and
          (compiler-load-link-vec-empty?
            (& (struct-get (struct-get link all) libraries)))
          (compiler-load-link-vec-empty?
            (& (struct-get (struct-get link linux) libraries)))
          (compiler-load-link-vec-empty?
            (& (struct-get (struct-get link windows) libraries)))))]
    [(ResultCompilerPkgManifest.Err _) false]))

;: Self-test: invalid `(link ...)` sections produce the expected diagnostics.
(define (compiler-load-manifest-link-rejections-ok?) : bool
  (and
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (libraries \"a\")) (link (args \"b\")))"
      "duplicate manifest field `link`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (libraries \"a\") (libraries \"b\")))"
      "duplicate `link` field `libraries`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (frobs \"a\")))"
      "unknown `link` field `frobs`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (libraries \"\")))"
      "`link` field `libraries` values must not be empty")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (libraries)))"
      "`link` field `libraries` requires at least one value")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (version \"1\") (kind \"bin\") (entry \"e.tl\") (link (libraries 5)))"
      "`link` field `libraries` values must be strings")))

;: Aggregate link-section self-test.
(define (compiler-load-manifest-link-ok?) : bool
  (and
    (compiler-load-manifest-link-valid-ok?)
    (compiler-load-manifest-link-default-ok?)
    (compiler-load-manifest-link-rejections-ok?)))

;: Aggregate manifest-parser self-test (#834).
(define (compiler-load-pkg-manifest-ok?) : bool
  (and
    (compiler-load-manifest-valid-full-ok?)
    (compiler-load-manifest-link-ok?)
    (compiler-load-manifest-valid-nodeps-ok?)
    (compiler-load-manifest-default-bin-ok?)
    (compiler-load-manifest-entry-override-ok?)
    (compiler-load-manifest-rejects?
      "(package (version \"1\") (kind \"bin\") (entry \"e.tl\"))"
      "manifest missing required field `name`")
    (compiler-load-manifest-rejects?
      "(package (name \"x\") (kind \"bin\") (entry \"e.tl\"))"
      "manifest missing required field `version`")
    (compiler-load-manifest-rejects?
      "(module foo)"
      "expected `package` form, got `module`")
    (compiler-load-pkg-manifest-validation-ok?)
    (compiler-load-manifest-github-deps-ok?)
    (compiler-load-pkg-manifest-github-validation-ok?)
    (compiler-load-pkg-manifest-diagnostic-ok?)))

;: --- pkg:<alias>/... import resolution (#834, slice 2) ----------------------
;: Resolve a `pkg:<alias>/<rest>` import against a parsed manifest's dependency
;: list, relative to the manifest directory: `<manifest-dir>/<dep-path>/<rest>`,
;: normalized. Rejects a missing alias, an empty/`/`-less spec, and a `rest`
;: that escapes the dependency root via `..`, preserving those diagnostics when
;: the import resolver runs inside the selfhost driver.
;: True when an import path is a package import (`pkg:<alias>/...`).
(define (compiler-load-pkg-import? [path : String]) : bool
  (compiler-load-string-prefix-at? path "pkg:" 0))

;: Index of the first '/' in `s` at or after `i`, or -1 if none.
(define (compiler-load-slash-index-from [s : String] [i : i64] [n : i64]) : i64
  (if (>= i n)
    -1
    (if (= (string.string-ref s i) '/')
      i
      (compiler-load-slash-index-from s (+ i 1) n))))

;: True when a path is not a safe relative suffix below its package root.
(define (compiler-load-path-escapes? [path : String]) : bool
  (not (compiler-load-safe-relative? path)))

;: Look up a dependency's root path by import alias.
(define (compiler-load-pkg-dep-lookup
  [deps : CompilerPkgDeps]
  [target-alias : String]) : CompilerLoadMaybePath
  (match (hashmap.string-string-map-get (struct-get deps aliases) target-alias)
    [(hashmap.StringStringMapFound path) (CompilerLoadSomePath path)]
    [(hashmap.StringStringMapMissing) (CompilerLoadNoPath)]))

;: Resolve `pkg:<alias>/<rest>` against `deps`, relative to `manifest-dir`.
(define (compiler-load-resolve-pkg-import
  [import-path : String]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultPkgResolve
  (let
    [body : String
      (string.substring import-path 4 (- (string.string-length import-path) 4))]
    [slash : i64
      (compiler-load-slash-index-from body 0 (string.string-length body))]
    (if (< slash 0)
      (ResultPkgResolve.Err
        (string.append
          "compiler-load: pkg import missing '/' after alias: "
          import-path))
      (let
        [alias : String (string.substring body 0 slash)]
        [rest : String
          (string.substring
            body
            (+ slash 1)
            (- (string.string-length body) (+ slash 1)))]
        (if (= (string.string-length alias) 0)
          (ResultPkgResolve.Err
            (string.append
              "compiler-load: pkg import has empty alias: "
              import-path))
          (match (compiler-load-pkg-dep-lookup deps alias)
            [(CompilerLoadNoPath)
              (ResultPkgResolve.Err
                (string.append
                  "compiler-load: unknown package alias '"
                  (string.append alias (string.append "': " import-path))))]
            [(CompilerLoadSomePath dep-path)
              (if (compiler-load-github-dependency-path? dep-path)
                (ResultPkgResolve.Err
                  (string.append
                    "compiler-load: GitHub dependency '"
                    (string.append
                      alias
                      (string.append
                        "' requires fetch support (#1157): "
                        import-path))))
                (let
                  [norm-rest : String (compiler-load-normalize-path rest)]
                  (if (compiler-load-path-escapes? norm-rest)
                    (ResultPkgResolve.Err
                      (string.append
                        "compiler-load: pkg import escapes package root: "
                        import-path))
                    (ResultPkgResolve.Ok
                      (compiler-load-normalize-path
                        (compiler-load-join-root-path
                          (compiler-load-join-root-path manifest-dir dep-path)
                          norm-rest))))))]))))))

;: Parent directory of a directory path, or no-path at the top. `dirname`
;: returns a path *including* its trailing separator, so a trailing separator
;: is stripped first to make the walk-up progress (e.g. `src/` -> ``, the cwd).
(define (compiler-load-parent-dir [dir : String]) : CompilerLoadMaybePath
  (let
    [n : i64 (string.string-length dir)]
    (if (= n 0)
      (CompilerLoadNoPath)
      (let
        [trimmed : String
          (if (compiler-load-path-separator? (string.string-ref dir (- n 1)))
            (string.substring dir 0 (- n 1))
            dir)]
        [parent : String (compiler-load-dirname trimmed)]
        (if (string.eq parent dir)
          (CompilerLoadNoPath)
          (CompilerLoadSomePath parent))))))

;: Walk up from `dir` looking for a `typelisp.pkg` manifest, mirroring the Rust
;: `discover_manifest` (src/package.rs). `fuel` bounds the climb.
(define (compiler-load-discover-manifest-up [dir : String] [fuel : i64]) : CompilerLoadMaybePath
  (if (<= fuel 0)
    (CompilerLoadNoPath)
    (let
      [candidate : String (string.append dir "typelisp.pkg")]
      (if (io.file-exists? candidate)
        (CompilerLoadSomePath candidate)
        (match (compiler-load-parent-dir dir)
          [(CompilerLoadNoPath) (CompilerLoadNoPath)]
          [(CompilerLoadSomePath parent)
            (compiler-load-discover-manifest-up parent (- fuel 1))])))))

;: Discover the nearest `typelisp.pkg` at or above the importer's directory.
(define (compiler-load-discover-manifest [start-path : String]) : CompilerLoadMaybePath
  (compiler-load-discover-manifest-up (compiler-load-dirname start-path) 256))

;: Resolve a `pkg:<alias>/...` import by discovering and parsing the nearest
;: `typelisp.pkg` relative to the importer, then resolving against its deps.
;: Missing manifests and parse errors fall back to the raw import path so the
;: loader reports a normal "cannot read import" error. Syntactically valid
;: manifests preserve pkg-resolution diagnostics into the caller.
(define (compiler-load-resolve-pkg-import-from-disk
  [importer-path : String]
  [import-path : String]) : ResultPkgResolve
  (match (compiler-load-discover-manifest importer-path)
    [(CompilerLoadNoPath) (ResultPkgResolve.Ok import-path)]
    [(CompilerLoadSomePath manifest-path)
      (match (compiler-load-parse-manifest-diagnostic
        manifest-path
        (io.read-file manifest-path))
        [(ResultCompilerPkgManifestDiagnostic.Err _)
          (ResultPkgResolve.Ok import-path)]
        [(ResultCompilerPkgManifestDiagnostic.Ok manifest)
          (compiler-load-resolve-pkg-import
            import-path
            (compiler-load-dirname manifest-path)
            (struct-get manifest deps))])]))

;: Self-test fixture: local deps plus one GitHub dep that needs fetch support.
(define (compiler-load-pkg-resolve-deps) : CompilerPkgDeps
  (compiler-pkg-deps-from-list
    (CompilerPkgDepCons
      (CompilerPkgDep "math" "../math")
      (box
        (CompilerPkgDepCons
          (CompilerPkgDep "util" "vendor/util")
          (box
            (CompilerPkgDepCons
              (CompilerPkgDep
                "remote"
                "https://github.com/owner/repo.git#rev=abc")
              (box CompilerPkgDepNil))))))))

;: True when resolving `import-path` yields exactly `expected`.
(define (compiler-load-pkg-resolves? [import-path : String] [expected : String]) : bool
  (match (compiler-load-resolve-pkg-import
    import-path
    "proj"
    (compiler-load-pkg-resolve-deps))
    [(ResultPkgResolve.Ok p) (string.eq p expected)]
    [(ResultPkgResolve.Err _) false]))

;: True when resolving `import-path` fails with exactly `expected`.
(define (compiler-load-pkg-resolve-rejects?
  [import-path : String]
  [expected : String]) : bool
  (match (compiler-load-resolve-pkg-import
    import-path
    "proj"
    (compiler-load-pkg-resolve-deps))
    [(ResultPkgResolve.Err m) (string.eq m expected)]
    [(ResultPkgResolve.Ok _) false]))

;: Aggregate pkg-import resolution self-test (#834).
(define (compiler-load-pkg-resolve-ok?) : bool
  (and
    (compiler-load-pkg-resolves? "pkg:math/src/add.tl" "math/src/add.tl")
    (compiler-load-pkg-resolves? "pkg:util/lib.tl" "proj/vendor/util/lib.tl")
    (compiler-load-pkg-resolve-rejects?
      "pkg:nope/x.tl"
      "compiler-load: unknown package alias 'nope': pkg:nope/x.tl")
    (compiler-load-pkg-resolve-rejects?
      "pkg:math"
      "compiler-load: pkg import missing '/' after alias: pkg:math")
    (compiler-load-pkg-resolve-rejects?
      "pkg:math/../../etc.tl"
      "compiler-load: pkg import escapes package root: pkg:math/../../etc.tl")
    (compiler-load-pkg-resolve-rejects?
      "pkg:remote/src/lib.tl"
      "compiler-load: GitHub dependency 'remote' requires fetch support (#1157): pkg:remote/src/lib.tl")))

;: True when `parent-dir dir` yields exactly `expected`.
(define (compiler-load-pkg-parent-dir-is? [dir : String] [expected : String]) : bool
  (match (compiler-load-parent-dir dir)
    [(CompilerLoadSomePath p) (string.eq p expected)]
    [(CompilerLoadNoPath) false]))

;: True when `parent-dir dir` reports no parent (top of the climb).
(define (compiler-load-pkg-parent-dir-none? [dir : String]) : bool
  (match (compiler-load-parent-dir dir)
    [(CompilerLoadNoPath) true]
    [(CompilerLoadSomePath _) false]))

;: The manifest-discovery walk-up steps one directory at a time, descending to
;: the cwd (``) before stopping (#834).
(define (compiler-load-pkg-parent-dir-ok?) : bool
  (and
    (compiler-load-pkg-parent-dir-is? "a/b/" "a/")
    (compiler-load-pkg-parent-dir-is? "a/b/c/" "a/b/")
    (compiler-load-pkg-parent-dir-is? "a/" "")
    (compiler-load-pkg-parent-dir-none? "")))

(define (compiler-load-string-vec-roots-ok?) : bool
  (begin
    (io.write-file "target/cl_vec_root_payload.tl" "(define v : i64 1)")
    (let
      [roots : vector.StringVec
        (vector.string-vec-push
          (vector.string-vec-push
            (vector.string-vec-new)
            "target/cl_vec_missing_root")
          "target")]
      (and
        (= (vector.string-vec-len roots) 2)
        (string.eq
          (vector.string-vec-get roots 0 "")
          "target/cl_vec_missing_root")
        (string.eq (vector.string-vec-get roots 1 "") "target")
        (match (compiler-load-resolve-stdlib-root-raw
          "cl_vec_root_payload.tl"
          roots)
          [(CompilerLoadSomePath path)
            (string.eq path "target/cl_vec_root_payload.tl")]
          [(CompilerLoadNoPath) false])))))

(define (compiler-load-boxed-pkg-dep-list-ok?) : bool
  (let
    [deps : CompilerPkgDeps
      (compiler-pkg-deps-from-list
        (CompilerPkgDepCons
          (CompilerPkgDep "alpha" "dep-alpha")
          (box
            (CompilerPkgDepCons
              (CompilerPkgDep "beta" "dep-beta")
              (box CompilerPkgDepNil)))))]
    (and
      (= (compiler-pkg-deps-count deps) 2)
      (compiler-pkg-deps-alias-seen? deps "beta")
      (compiler-load-manifest-dep-path-is? deps "beta" "dep-beta"))))

;; relative-resolution variants (#1074): importer-relative join, parent-directory
;; (`..`) resolution end-to-end (join then normalize), and absolute-path
;; preservation (Unix-rooted and Windows-drive imports ignore the importer dir).
;; Pure path-string logic; complements `compiler-load-normalize-ok?` which covers
;; bare `.`/`..`/separator normalization without the importer-relative join.
(define (compiler-load-relative-resolution-ok?) : bool
  (and
    ;; importer-relative: import resolves against the importer's directory
    (string.eq
      (compiler-load-join-import-path "src/app/main.tl" "util.tl")
      "src/app/util.tl")
    ;; parent-directory (`..`) resolution end-to-end (join then normalize)
    (string.eq
      (compiler-load-normalize-path
        (compiler-load-join-import-path "src/app/main.tl" "../lib/helper.tl"))
      "src/lib/helper.tl")
    ;; absolute Unix-rooted import is preserved as-is (importer dir ignored)
    (string.eq
      (compiler-load-join-import-path "src/app/main.tl" "/opt/dep.tl")
      "/opt/dep.tl")
    ;; absolute Windows-drive import is preserved as-is
    (string.eq
      (compiler-load-join-import-path "src/app/main.tl" "C:/dep.tl")
      "C:/dep.tl")))

(define (compiler-load-dotted-module-path-cache-ok?) : bool
  (begin
    (compiler-load-dotted-path-cache-reset!)
    (let
      [stdlib-name : String "stdlib.core_macros"]
      [pkg-name : String "pkg.local.mod"]
      [stdlib-id : i64 (intern stdlib-name)]
      [pkg-id : i64 (intern pkg-name)]
      [first : String (compiler-load-dotted-module-path "stdlib.core_macros")]
      [second : String (compiler-load-dotted-module-path "stdlib.core_macros")]
      [third : String (compiler-load-dotted-module-path "pkg.local.mod")]
      (and
        (string.eq first "stdlib/core_macros.tl")
        (string.eq second "stdlib/core_macros.tl")
        (string.eq third "pkg/local/mod.tl")
        (match (compiler-load-dotted-path-cache-lookup stdlib-id)
          [(CompilerLoadSomeString cached)
            (string.eq cached "stdlib/core_macros.tl")]
          [(CompilerLoadNoString) false])
        (match (compiler-load-dotted-path-cache-lookup pkg-id)
          [(CompilerLoadSomeString cached)
            (string.eq cached "pkg/local/mod.tl")]
          [(CompilerLoadNoString) false])))))

(define (compiler-load-test-path-at [paths : AstDeclPathList] [index : i64]) : String
  (match (ast-decl-path-list-step paths)
    [(AstDeclPathListStep.Nil) ""]
    [(AstDeclPathListStep.Cons path rest)
      (if (= index 0)
        path
        (let
          [rest : AstDeclPathList rest]
          (compiler-load-test-path-at rest (- index 1))))]))

(define (compiler-load-package-owner-paths-ok?) : bool
  (let
    [roots : vector.StringVec
      (vector.string-vec-push (vector.string-vec-new) "C:/repo/stdlib")]
    [mixed-roots : vector.StringVec
      (vector.string-vec-push
        (vector.string-vec-push (vector.string-vec-new) "C:/repo/stdlib")
        "C:/repo/selfhost")]
    [runtime-decl : AstDecl
      (ast-decl-def-fn
        "runtime-helper"
        AstParamList.Nil
        (AstType.I64)
        (ast-node-push (AstExpr.Literal (ast-lit-int 1))))]
    [helper-decl : AstDecl
      (ast-decl-def-fn
        "helper"
        AstParamList.Nil
        (AstType.I64)
        (ast-node-push (AstExpr.Literal (ast-lit-int 2))))]
    [main-decl : AstDecl
      (ast-decl-def-fn
        "main"
        AstParamList.Nil
        (AstType.I64)
        (ast-node-push (AstExpr.Literal (ast-lit-int 0))))]
    [decls : AstDeclList
      (ast-decl-cons
        runtime-decl
        (ast-decl-cons
          helper-decl
          (ast-decl-cons main-decl (ast-decl-list-new))))]
    [paths : AstDeclPathList
      (ast-decl-path-cons
        "C:/repo/stdlib/runtime.tl"
        (ast-decl-path-cons
          "C:/pkg/src/main.tl"
          (ast-decl-path-cons "C:/pkg/src/main.tl" (ast-decl-path-list-new))))]
    [owned : AstDeclPathList
      (compiler-load-package-owned-paths-for-decls
        "app"
        "C:/pkg/"
        roots
        "C:/pkg/src/main.tl"
        decls
        paths)]
    [runtime-owned-ok : bool
      (string.eq (compiler-load-test-path-at owned 0) "stdlib/runtime.tl")]
    [helper-owned-ok : bool
      (string.eq (compiler-load-test-path-at owned 1) "app/src/main.tl")]
    [entry-main-ok : bool (string.eq (compiler-load-test-path-at owned 2) "")]
    [stdlib-normalized-ok : bool
      (string.eq
        (compiler-load-package-owned-path
          "app"
          "C:/pkg/"
          roots
          "stdlib/../stdlib/runtime.tl")
        "stdlib/runtime.tl")]
    [empty-root-owned-ok : bool
      (string.eq
        (compiler-load-package-owned-path "app" "" roots "src/main.tl")
        "app/src/main.tl")]
    [selfhost-root-owned-ok : bool
      (string.eq
        (compiler-load-package-owned-path
          "app"
          "C:/repo/"
          mixed-roots
          "C:/repo/selfhost/compiler_driver_core.tl")
        "app/selfhost/compiler_driver_core.tl")]
    (and
      runtime-owned-ok
      helper-owned-ok
      entry-main-ok
      stdlib-normalized-ok
      empty-root-owned-ok
      selfhost-root-owned-ok)))

(define (compiler-load-package-owner-extern-symbol-ok?) : bool
  (let
    [decl : AstDecl
      (compiler-load-package-def-fn-extern
        "dep"
        "C:/dep/"
        (vector.string-vec-new)
        "C:/dep/src/lib.tl"
        ""
        (intern "helper")
        AstParamList.Nil
        (AstType.I64))]
    (match decl
      [(AstDecl.Extern _ _ metadata _)
        (string.eq
          (ast-extern-metadata-symbol metadata)
          "_tl_dep_src_lib_helper")]
      [_ false])))

(define (compiler-load-self-test) : i64
  (begin
    (unless
      (compiler-load-normalize-ok?)
      (return (io.panic "compiler-load: normalize smoke mismatch")))
    (unless
      (compiler-load-canonical-module-id-ok?)
      (return (io.panic "compiler-load: canonical module id smoke mismatch")))
    (unless
      (compiler-load-relative-resolution-ok?)
      (return (io.panic "compiler-load: relative resolution smoke mismatch")))
    (unless
      (compiler-load-dotted-module-path-cache-ok?)
      (return (io.panic "compiler-load: dotted path cache smoke mismatch")))
    (unless
      (compiler-load-package-owner-paths-ok?)
      (return (io.panic "compiler-load: package owner path smoke mismatch")))
    (unless
      (compiler-load-package-owner-extern-symbol-ok?)
      (return
        (io.panic "compiler-load: package owner extern symbol smoke mismatch")))
    (unless
      (compiler-load-source-provenance-ok?)
      (return (io.panic "compiler-load: source provenance smoke mismatch")))
    (unless
      (compiler-load-entry-moduled-main-ok?)
      (return (io.panic "compiler-load: entry moduled main smoke mismatch")))
    (unless
      (compiler-load-expected-module-conflict-ok?)
      (return (io.panic "compiler-load: expected module smoke mismatch")))
    (unless
      (compiler-load-duplicate-module-ok?)
      (return (io.panic "compiler-load: duplicate module smoke mismatch")))
    (unless
      (compiler-load-nested-module-body-ok?)
      (return (io.panic "compiler-load: nested module body smoke mismatch")))
    (unless
      (compiler-load-nested-module-duplicate-ok?)
      (return
        (io.panic "compiler-load: nested module duplicate smoke mismatch")))
    (unless
      (compiler-load-seen-module-ok?)
      (return (io.panic "compiler-load: seen module smoke mismatch")))
    (unless
      (compiler-load-cfg-import-ok?)
      (return (io.panic "compiler-load: cfg import smoke mismatch")))
    (unless
      (compiler-load-surface-summary-smoke-ok?)
      (return (io.panic "compiler-load: surface summary smoke mismatch")))
    (unless
      (compiler-load-session-cache-common-dep-ok?)
      (return
        (io.panic "compiler-load: session cache common dep smoke mismatch")))
    (unless
      (compiler-load-session-cache-root-isolation-ok?)
      (return
        (io.panic "compiler-load: session cache root isolation smoke mismatch")))
    (unless
      (compiler-load-session-cache-entry-cold-ok?)
      (return
        (io.panic "compiler-load: session cache entry cold smoke mismatch")))
    (unless
      (compiler-load-session-program-cache-disable-persistent-off-ok?)
      (return
        (io.panic
          "compiler-load: disabled program cache left persistent intern storage on")))
    (unless
      (compiler-load-session-cache-enable-persistent-off-ok?)
      (return
        (io.panic
          "compiler-load: session cache enable left persistent intern storage on")))
    (unless
      (compiler-load-session-persistent-floor-interns-ok?)
      (return
        (io.panic
          "compiler-load: session cache intern floor kept scratch storage")))
    (unless
      (compiler-load-session-cache-local-common-dep-ok?)
      (return
        (io.panic
          "compiler-load: session cache local common dep smoke mismatch")))
    (unless
      (compiler-load-session-cache-package-common-dep-ok?)
      (return
        (io.panic
          "compiler-load: session cache package common dep smoke mismatch")))
    (unless
      (compiler-load-file-import-dedup-cycle-ok?)
      (return (io.panic "compiler-load: import dedup/cycle smoke mismatch")))
    (unless
      (compiler-load-file-fallback-path-dedup-ok?)
      (return (io.panic "compiler-load: fallback path dedup smoke mismatch")))
    (unless
      (compiler-load-import-module-restore-ok?)
      (return (io.panic "compiler-load: import module restore smoke mismatch")))
    (unless
      (compiler-load-import-alias-preserved-ok?)
      (return
        (io.panic "compiler-load: import alias preservation smoke mismatch")))
    (unless
      (compiler-load-legacy-path-module-flat-alias-ok?)
      (return
        (io.panic "compiler-load: legacy path module flat alias smoke mismatch")))
    (unless
      (compiler-load-seen-legacy-path-module-flat-alias-ok?)
      (return
        (io.panic
          "compiler-load: seen legacy path module flat alias smoke mismatch")))
    (unless
      (compiler-load-package-legacy-path-module-flat-alias-ok?)
      (return
        (io.panic
          "compiler-load: package legacy path module flat alias smoke mismatch")))
    (unless
      (compiler-load-package-seen-legacy-path-module-flat-alias-ok?)
      (return
        (io.panic
          "compiler-load: package seen legacy path module flat alias smoke mismatch")))
    (unless
      (compiler-load-dotted-import-duplicate-alias-ok?)
      (return
        (io.panic "compiler-load: dotted import duplicate alias smoke mismatch")))
    (unless
      (compiler-load-dotted-import-resolution-ok?)
      (return
        (io.panic "compiler-load: dotted import resolution smoke mismatch")))
    (unless
      (compiler-load-dotted-source-root-ok?)
      (return (io.panic "compiler-load: dotted source root smoke mismatch")))
    (unless
      (compiler-load-moduleless-dotted-source-root-ok?)
      (return
        (io.panic "compiler-load: moduleless dotted source root smoke mismatch")))
    (unless
      (compiler-load-dotted-source-root-fallback-ok?)
      (return
        (io.panic "compiler-load: dotted source root fallback smoke mismatch")))
    (unless
      (compiler-load-dotted-after-path-import-ok?)
      (return
        (io.panic "compiler-load: dotted after path import smoke mismatch")))
    (unless
      (compiler-load-package-dotted-import-resolution-ok?)
      (return
        (io.panic
          "compiler-load: package dotted import resolution smoke mismatch")))
    (unless
      (compiler-load-package-dotted-sibling-source-ok?)
      (return
        (io.panic "compiler-load: package dotted sibling source smoke mismatch")))
    (unless
      (compiler-load-package-moduleless-pkg-import-id-ok?)
      (return
        (io.panic "compiler-load: package moduleless pkg import smoke mismatch")))
    (unless
      (compiler-load-generated-meta-preserved-ok?)
      (return
        (io.panic
          "compiler-load: generated metadata preservation smoke mismatch")))
    (unless
      (compiler-load-diamond-import-ok?)
      (return (io.panic "compiler-load: diamond import smoke mismatch")))
    (unless
      (compiler-load-transitive-import-ok?)
      (return (io.panic "compiler-load: transitive import smoke mismatch")))
    (unless
      (compiler-load-missing-import-ok?)
      (return (io.panic "compiler-load: missing import smoke mismatch")))
    (unless
      (compiler-load-include-str-relative-ok?)
      (return (io.panic "compiler-load: include-str relative smoke mismatch")))
    (unless
      (compiler-load-include-str-stdlib-root-ok?)
      (return
        (io.panic "compiler-load: include-str stdlib root smoke mismatch")))
    (unless
      (compiler-load-missing-include-str-ok?)
      (return (io.panic "compiler-load: missing include-str smoke mismatch")))
    (unless
      (compiler-load-include-str-raw-text-ok?)
      (return (io.panic "compiler-load: include-str raw text smoke mismatch")))
    (unless
      (compiler-load-include-bin-relative-ok?)
      (return (io.panic "compiler-load: include-bin relative smoke mismatch")))
    (unless
      (compiler-load-missing-include-bin-ok?)
      (return (io.panic "compiler-load: missing include-bin smoke mismatch")))
    (unless
      (compiler-load-embedded-stdlib-lookup-ok?)
      (return (io.panic "compiler-load: embedded stdlib lookup smoke mismatch")))
    (unless
      (compiler-load-embedded-stdlib-missing-ok?)
      (return
        (io.panic "compiler-load: embedded stdlib missing smoke mismatch")))
    (unless
      (compiler-load-embedded-stdlib-escape-rejected-ok?)
      (return (io.panic "compiler-load: embedded stdlib escape smoke mismatch")))
    (unless
      (compiler-load-imported-parse-error-path-ok?)
      (return
        (io.panic "compiler-load: imported parse error path smoke mismatch")))
    (unless
      (compiler-load-imported-duplicate-module-path-ok?)
      (return
        (io.panic
          "compiler-load: imported duplicate module path smoke mismatch")))
    (unless
      (compiler-load-stdlib-root-fallback-ok?)
      (return (io.panic "compiler-load: stdlib root fallback smoke mismatch")))
    (unless
      (compiler-load-stdlib-searched-root-ok?)
      (return (io.panic "compiler-load: stdlib searched root smoke mismatch")))
    (unless
      (compiler-load-stdlib-unresolved-ok?)
      (return (io.panic "compiler-load: stdlib unresolved smoke mismatch")))
    (unless
      (compiler-load-stdlib-root-escape-rejected-ok?)
      (return (io.panic "compiler-load: stdlib root escape smoke mismatch")))
    (unless
      (compiler-load-pkg-manifest-ok?)
      (return (io.panic "compiler-load: pkg manifest smoke mismatch")))
    (unless
      (compiler-load-manifest-path-inference-ok?)
      (return
        (io.panic "compiler-load: manifest path inference smoke mismatch")))
    (unless
      (compiler-load-pkg-resolve-ok?)
      (return (io.panic "compiler-load: pkg resolve smoke mismatch")))
    (unless
      (compiler-load-pkg-parent-dir-ok?)
      (return (io.panic "compiler-load: pkg parent-dir smoke mismatch")))
    (unless
      (compiler-load-string-vec-roots-ok?)
      (return (io.panic "compiler-load: string vec roots smoke mismatch")))
    (unless
      (compiler-load-boxed-pkg-dep-list-ok?)
      (return (io.panic "compiler-load: boxed pkg-dep-list smoke mismatch")))
    42))