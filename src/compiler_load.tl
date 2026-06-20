;; compiler_load.tl - Shared selfhost compiler source/import loader.
(import "../stdlib/io.tl")
(import "compiler_parse_core.tl")
(import "compiler_diagnostic.tl")
(import "sym_i64_env.tl")
(import "../stdlib/env.tl")
(import "../stdlib/fs.tl")
(import "../stdlib/hashmap.tl")
(import "../stdlib/vector.tl")
(import "compiler_embedded_stdlib.tl")
(import "../stdlib/string.tl")
(import "../stdlib/str_cat.tl")

(defenum ResultCompilerLoad
  (OkCompilerLoad AstDeclList SymI64Env)
  (ErrCompilerLoad CompilerDiagnostic))

(defenum ResultCompilerLoadWithPaths
  (OkCompilerLoadWithPaths
    AstDeclList
    AstDeclPathList
    AstDeclModuleList
    SymI64Env)
  (ErrCompilerLoadWithPaths CompilerDiagnostic))

(defenum CompilerLoadMaybePath
  (CompilerLoadNoPath)
  (CompilerLoadSomePath String))

(defenum CompilerLoadMaybeString
  (CompilerLoadNoString)
  (CompilerLoadSomeString String))

(defenum ResultPkgResolve
  (OkPkgResolve String)
  (ErrPkgResolve String))

(defstruct CompilerLoadPackageEntry
  (entry-path String)
  (manifest-dir String)
  (owner String))

(defenum ResultCompilerLoadPackageEntry
  (OkCompilerLoadPackageEntry CompilerLoadPackageEntry)
  (ErrCompilerLoadPackageEntry String))

(defenum CompilerLoadMaybeModuleId
  (CompilerLoadNoModuleId)
  (CompilerLoadSomeModuleId String))

(defenum CompilerLoadMaybeDecl
  (CompilerLoadNoDecl)
  (CompilerLoadSomeDecl AstDecl))

(defenum ResultCompilerLoadInclude
  (OkCompilerLoadInclude AstDecl)
  (ErrCompilerLoadInclude CompilerDiagnostic))

(defenum ResultCompilerLoadModuleId
  (OkCompilerLoadModuleId String)
  (ErrCompilerLoadModuleId CompilerDiagnostic))

(defenum ResultCompilerLoadAliasCheck
  (OkCompilerLoadAliasCheck)
  (ErrCompilerLoadAliasCheck CompilerDiagnostic))

(defenum CompilerLoadPreludeCacheLookup
  (CompilerLoadPreludeCacheMiss)
  (CompilerLoadPreludeCacheHit
    AstDeclList
    AstDeclPathList
    AstDeclModuleList
    SymI64Env))

(defenum CompilerLoadPreludeCacheSlot
  (CompilerLoadPreludeCacheEmpty)
  (CompilerLoadPreludeCacheFull
    String
    AstDeclList
    AstDeclPathList
    AstDeclModuleList
    SymI64Env))

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
  (runtime-prelude-cache-ready (Array bool)))

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
    (compiler-load-session-state-bool-cell false)))

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
        (if (string-eq slot-key key)
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
        (if (string-eq slot-key key)
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
        (if (string-eq slot-key key)
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
        (if (string-eq slot-key key)
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
        (if (string-eq slot-key key)
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
      [prev-arena : i64 (arena-current)]
      [recorded : bool
        (begin
          (unsafe
            (arena-set! node-pool-base-arena))
          (let
            [persistent-key : String (string-copy-borrowed (& key))]
            (begin
              (unsafe
                (arena-set! prev-arena))
              (compiler-load-program-admission-record persistent-key))))]
      recorded)))

(define (compiler-load-session-note-persistent!) : unit
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
    (if (> (intern-pool-len) (compiler-load-session-intern-floor-value))
      (array-set!
        (struct-get compiler-load-active-session-state intern-floor)
        0
        (intern-pool-len))
      unit)))

(define (compiler-load-session-note-persistent-with-pools!
  [pools : AstNodePoolContext]) : unit
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
    (if (> (intern-pool-len) (compiler-load-session-intern-floor-value))
      (array-set!
        (struct-get compiler-load-active-session-state intern-floor)
        0
        (intern-pool-len))
      unit)))

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
    (if (compiler-load-session-cache-enabled?)
      (intern-persistent-storage-enable!)
      (intern-persistent-storage-disable!))))

(define (compiler-load-session-cache-enable!) : unit
  (begin
    (array-set!
      (struct-get compiler-load-active-session-state cache-enabled)
      0
      true)
    (intern-persistent-storage-enable!)))

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
    (array-set! (struct-get state program-cache-store-count) 0 0)))

(define (compiler-load-session-program-cache-disable!) : unit
  (begin
    (array-set!
      (struct-get compiler-load-active-session-state program-cache-enabled)
      0
      false)
    (compiler-load-program-cache-clear!)))

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
  (if (compiler-load-session-cache-enabled?)
    (begin
      (ast-node-pool-reset-to! (compiler-load-session-ast-floor-value))
      (ty-node-pool-reset-to! (compiler-load-session-ty-floor-value)))
    (begin
      (ast-node-pool-reset!)
      (ty-node-pool-reset!))))

(define (compiler-load-session-reset-pools-with-pools!
  [pools : AstNodePoolContext]) : unit
  (if (compiler-load-session-cache-enabled?)
    (ast-node-pool-context-reset-to!
      pools
      (compiler-load-session-ast-floor-value)
      (compiler-load-session-ty-floor-value))
    (ast-node-pool-context-reset-to! pools 0 0)))

(define (compiler-load-session-reset-interns!) : unit
  (if (compiler-load-session-cache-enabled?)
    (intern-reset-to! (compiler-load-session-intern-floor-value))
    (intern-reset!)))

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
        (if (string-eq slot-key key)
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
  [seen : SymI64Env]
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
        (if (string-eq slot-key key)
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
  [seen : SymI64Env]) : unit
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
  [seen : SymI64Env]
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
  [roots : StringVec]
  [index : i64]
  [count : i64]
  [out : String]) : String
  (if (>= index count)
    out
    (let
      [root : String (string-vec-get roots index "")]
      (compiler-load-roots-cache-key-from
        roots
        (+ index 1)
        count
        (str-cat out (int->string (string-length root)) ":" root ";")))))

(define (compiler-load-roots-cache-key [roots : StringVec]) : String
  (compiler-load-roots-cache-key-from roots 0 (string-vec-len roots) ""))

(define (compiler-load-cfg-cache-key-from [cfgs : SymI64Env] [out : String]) : String
  (match cfgs
    [(SymI64Nil) out]
    [(SymI64Bind key value rest)
      (compiler-load-cfg-cache-key-from
        (box-get rest)
        (str-cat out (intern-str key) "=" (int->string value) ";"))]))

(define (compiler-load-cfg-cache-key [cfgs : SymI64Env]) : String
  (compiler-load-cfg-cache-key-from cfgs ""))

(define (compiler-load-prelude-cache-key
  [kind : String]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : String
  (let
    [effective-roots : StringVec (compiler-load-roots-with-env stdlib-roots)]
    (str-cat
      kind
      "|roots:"
      (compiler-load-roots-cache-key effective-roots)
      "|cfg:"
      (compiler-load-cfg-cache-key cfgs))))

(define (compiler-load-program-cache-key
  [kind : String]
  [path : String]
  [cfgs : SymI64Env]) : String
  (let
    [normalized : String (compiler-load-normalize-path path)]
    (str-cat
      "program|"
      kind
      ":"
      (int->string (string-length normalized))
      ":"
      normalized
      "|cfg:"
      (compiler-load-cfg-cache-key cfgs))))

(define (compiler-load-char-code-at [text : String] [idx : i64]) : i64
  (cast (string-ref text idx) : i64))

(define (compiler-load-path-separator? [c : char]) : bool
  (fs-path-separator? c))

(define (compiler-load-absolute-path? [path : String]) : bool
  (fs-path-absolute? (& path)))

(define (compiler-load-dirname [path : String]) : String
  (let
    [n : i64 (string-length path)]
    [i : i64 0]
    [last : i64 -1]
    (begin
      (while (< i n)
        (begin
          (if (compiler-load-path-separator? (string-ref path i))
            (set! last i)
            (set! last last))
          (set! i (+ i 1))))
      (if (< last 0)
        ""
        (substring path 0 (+ last 1))))))

(define (compiler-load-join-import-path
  [importer-path : String]
  [import-path : String]) : String
  (if (compiler-load-absolute-path? import-path)
    import-path
    (string-append (compiler-load-dirname importer-path) import-path)))

(define (compiler-load-normalize-path [path : String]) : String
  (fs-path-normalize (& path)))

(define (compiler-load-safe-relative? [path : String]) : bool
  (fs-path-safe-relative? (& path)))

(define (compiler-load-string-prefix-at?
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
                  (compiler-load-char-code-at text (+ start i))
                  (compiler-load-char-code-at prefix i))
                  (set! i (+ i 1))
                  (set! ok false))
                (set! ok false)))
            (= i prefix-len)))))))

(define (compiler-load-stdlib-import? [path : String]) : bool
  (compiler-load-string-prefix-at? path "stdlib/" 0))

(define (compiler-load-stdlib-suffix [path : String]) : String
  (substring path 7 (- (string-length path) 7)))

(define (compiler-load-join-root-path [root : String] [suffix : String]) : String
  (let
    [n : i64 (string-length root)]
    (if (= n 0)
      suffix
      (let
        [last : char (string-ref root (- n 1))]
        (if (compiler-load-path-separator? last)
          (string-append root suffix)
          (string-append root (string-append "/" suffix)))))))

(define (compiler-load-roots-with-env [roots : StringVec]) : StringVec
  (let
    [name : String "TYPELISP_STDLIB_ROOT"]
    (match (env-get (& name))
      [(EnvNoString) roots]
      [(EnvSomeString root)
        (if (= (string-length root) 0)
          roots
          (string-vec-push roots root))])))

(define (compiler-load-cache-root-prefix [root : String]) : String
  (compiler-load-join-root-path (compiler-load-normalize-path root) ""))

(define (compiler-load-cache-path-under-root?
  [normalized-path : String]
  [root : String]) : bool
  (if (= (string-length root) 0)
    false
    (compiler-load-string-prefix-at?
      normalized-path
      (compiler-load-cache-root-prefix root)
      0)))

(define (compiler-load-path-under-roots-from?
  [normalized-path : String]
  [roots : StringVec]
  [index : i64]
  [count : i64]) : bool
  (if (>= index count)
    false
    (if (compiler-load-cache-path-under-root?
      normalized-path
      (string-vec-get roots index ""))
      true
      (compiler-load-path-under-roots-from?
        normalized-path
        roots
        (+ index 1)
        count))))

(define (compiler-load-session-file-cacheable?
  [path : String]
  [_stdlib-roots : StringVec]) : bool
  ;; Entry files opt out before this helper. Resolved import files are safe to
  ;; cache by path + cfg, including local and package-owned modules.
  (> (string-length (compiler-load-normalize-path path)) 0))

(define (compiler-load-session-file-cache-immediate?
  [path : String]
  [stdlib-roots : StringVec]) : bool
  (let
    [normalized : String (compiler-load-normalize-path path)]
    (if (compiler-load-stdlib-import? normalized)
      true
      (let
        [effective-roots : StringVec
          (compiler-load-roots-with-env stdlib-roots)]
        (compiler-load-path-under-roots-from?
          normalized
          effective-roots
          0
          (string-vec-len effective-roots))))))

(define (compiler-load-resolve-stdlib-root-raw
  [suffix : String]
  [roots : StringVec]) : CompilerLoadMaybePath
  (if (compiler-load-safe-relative? suffix)
    (let
      [i : i64 0]
      [n : i64 (string-vec-len roots)]
      [found : bool false]
      [found-path : String ""]
      (begin
        (while (and (not found) (< i n))
          (let
            [root : String (string-vec-get roots i "")]
            [candidate : String (compiler-load-join-root-path root suffix)]
            (if (file-exists? candidate)
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
  [roots : StringVec]) : CompilerLoadMaybePath
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
      (CompilerLoadSomePath (string-append "stdlib/" suffix))]
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
    (string-vec-new)))

(define (compiler-load-resolve-import-with-roots
  [importer-path : String]
  [import-path : String]
  [stdlib-roots : StringVec]) : String
  (match (compiler-load-resolve-import-result-with-roots
    importer-path
    import-path
    stdlib-roots)
    [(OkPkgResolve resolved) resolved]
    [(ErrPkgResolve _) import-path]))

(define (compiler-load-resolve-import-result-with-roots
  [importer-path : String]
  [import-path : String]
  [stdlib-roots : StringVec]) : ResultPkgResolve
  (if (compiler-load-pkg-import? import-path)
    (compiler-load-resolve-pkg-import-from-disk importer-path import-path)
    (let
      [primary : String
        (compiler-load-join-import-path importer-path import-path)]
      [resolved : String
        (if (file-exists? primary)
          primary
          (if (compiler-load-stdlib-import? import-path)
            (let
              [suffix : String (compiler-load-stdlib-suffix import-path)]
              (match (compiler-load-resolve-stdlib-root suffix stdlib-roots)
                [(CompilerLoadSomePath root-path) root-path]
                [(CompilerLoadNoPath)
                  (if (file-exists? import-path)
                    import-path
                    (match (compiler-load-embedded-stdlib-path suffix)
                      [(CompilerLoadSomePath embedded-path) embedded-path]
                      [(CompilerLoadNoPath) primary]))]))
            primary))]
      (OkPkgResolve resolved))))

(define (compiler-load-dotted-module-path [module-name : String]) : String
  (let
    [n : i64 (string-length module-name)]
    [i : i64 0]
    [out : String ""]
    (begin
      (while (< i n)
        (begin
          (if (char-eq (string-ref module-name i) '.')
            (set! out (string-append out "/"))
            (set! out (string-append out (substring module-name i 1))))
          (set! i (+ i 1))))
      (string-append out ".tl"))))

(define (compiler-load-dotted-module-first-len [module-name : String]) : i64
  (let
    [n : i64 (string-length module-name)]
    [i : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (< i n))
        (if (char-eq (string-ref module-name i) '.')
          (set! done true)
          (set! i (+ i 1))))
      i)))

(define (compiler-load-dotted-module-first [module-name : String]) : String
  (substring module-name 0 (compiler-load-dotted-module-first-len module-name)))

(define (compiler-load-dotted-module-rest
  [module-name : String]
  [first-len : i64]) : String
  (let
    [n : i64 (string-length module-name)]
    [rest-start : i64 (+ first-len 1)]
    (if (>= rest-start n)
      ""
      (substring module-name rest-start (- n rest-start)))))

(define (compiler-load-resolve-stdlib-module-path
  [module-path : String]
  [stdlib-roots : StringVec]) : String
  (let
    [suffix : String (compiler-load-stdlib-suffix module-path)]
    (match (compiler-load-resolve-stdlib-root suffix stdlib-roots)
      [(CompilerLoadSomePath root-path) root-path]
      [(CompilerLoadNoPath)
        (if (file-exists? module-path)
          module-path
          (match (compiler-load-embedded-stdlib-path suffix)
            [(CompilerLoadSomePath embedded-path) embedded-path]
            [(CompilerLoadNoPath) module-path]))])))

(define (compiler-load-resolve-module-import-with-roots
  [import-root : String]
  [module-name : String]
  [stdlib-roots : StringVec]) : ResultPkgResolve
  (let
    [module-path : String (compiler-load-dotted-module-path module-name)]
    (if (compiler-load-stdlib-import? module-path)
      (OkPkgResolve
        (compiler-load-resolve-stdlib-module-path module-path stdlib-roots))
      (OkPkgResolve
        (compiler-load-normalize-path
          (compiler-load-join-root-path import-root module-path))))))

(define (compiler-load-resolve-import-spec-with-roots
  [importer-path : String]
  [import-root : String]
  [kind : AstImportKind]
  [import-path : String]
  [stdlib-roots : StringVec]) : ResultPkgResolve
  (match kind
    [(AstImportPath)
      (compiler-load-resolve-import-result-with-roots
        importer-path
        import-path
        stdlib-roots)]
    [(AstImportModule)
      (compiler-load-resolve-module-import-with-roots
        import-root
        import-path
        stdlib-roots)]
    [(AstImportMacro _)
      (ErrPkgResolve
        "compiler-load: module macro imports must be expanded before import resolution")]
    [(AstImportMacroDecls _)
      (ErrPkgResolve
        "compiler-load: module macro imports must be expanded before import resolution")]))

(define (compiler-load-resolve-package-module-import
  [module-name : String]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [stdlib-roots : StringVec]) : ResultPkgResolve
  (let
    [first-len : i64 (compiler-load-dotted-module-first-len module-name)]
    [first : String (substring module-name 0 first-len)]
    [module-path : String (compiler-load-dotted-module-path module-name)]
    (if (compiler-load-stdlib-import? module-path)
      (OkPkgResolve
        (compiler-load-resolve-stdlib-module-path module-path stdlib-roots))
      (match (compiler-load-pkg-dep-lookup deps first)
        [(CompilerLoadNoPath)
          (OkPkgResolve
            (compiler-load-normalize-path
              (compiler-load-join-root-path manifest-dir module-path)))]
        [(CompilerLoadSomePath dep-path)
          (let
            [rest : String
              (compiler-load-dotted-module-rest module-name first-len)]
            (if (= (string-length rest) 0)
              (ErrPkgResolve
                (string-append
                  "compiler-load: dotted import missing module segment after package alias: "
                  module-name))
              (if (compiler-load-github-dependency-path? dep-path)
                (ErrPkgResolve
                  (string-append
                    "compiler-load: GitHub dependency '"
                    (string-append
                      first
                      (string-append
                        "' requires fetch support (#1157): "
                        module-name))))
                (OkPkgResolve
                  (compiler-load-normalize-path
                    (compiler-load-join-root-path
                      (compiler-load-join-root-path manifest-dir dep-path)
                      (compiler-load-dotted-module-path rest)))))))]))))

(define (compiler-load-resolve-package-import-spec
  [importer-path : String]
  [kind : AstImportKind]
  [import-path : String]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultPkgResolve
  (match kind
    [(AstImportPath)
      (if (compiler-load-pkg-import? import-path)
        (compiler-load-resolve-pkg-import import-path manifest-dir deps)
        (compiler-load-resolve-import-result-with-roots
          importer-path
          import-path
          stdlib-roots))]
    [(AstImportModule)
      (compiler-load-resolve-package-module-import
        import-path
        manifest-dir
        deps
        stdlib-roots)]
    [(AstImportMacro _)
      (ErrPkgResolve
        "compiler-load: module macro imports must be expanded before import resolution")]
    [(AstImportMacroDecls _)
      (ErrPkgResolve
        "compiler-load: module macro imports must be expanded before import resolution")]))

(define (compiler-load-package-import-externs?
  [kind : AstImportKind]
  [import-path : String]
  [deps : CompilerPkgDeps]) : bool
  (match kind
    [(AstImportPath) (compiler-load-pkg-import? import-path)]
    [(AstImportModule)
      (let
        [module-path : String (compiler-load-dotted-module-path import-path)]
        [first : String (compiler-load-dotted-module-first import-path)]
        (if (compiler-load-stdlib-import? module-path)
          false
          (match (compiler-load-pkg-dep-lookup deps first)
            [(CompilerLoadSomePath _) true]
            [(CompilerLoadNoPath) false])))]
    [(AstImportMacro _) false]
    [(AstImportMacroDecls _) false]))

(define (compiler-load-macro-import-kind? [kind : AstImportKind]) : bool
  (match kind
    [(AstImportMacro _) true]
    [(AstImportMacroDecls _) true]
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
    (AstSomeType (AstTyString))
    (ast-node-pool-context-expr-push
      pools
      (AstExprLiteral (AstLitString contents)))))

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
    (AstSomeType (ast-ty-dyn-array-with-pools pools (AstTyU8)))
    (ast-node-pool-context-expr-push pools (AstExprBinaryData contents))))

(define (compiler-load-include-str-read-error
  [importer-path : String]
  [include-path : String]
  [resolved : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start
    importer-path
    (string-append
      "compiler-load: cannot read include-str "
      (string-append
        include-path
        (string-append
          " from "
          (string-append
            importer-path
            (string-append " (resolved " (string-append resolved ")"))))))))

(define (compiler-load-include-str-from-resolved
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : String]) : ResultCompilerLoadInclude
  (if (file-exists? resolved)
    (OkCompilerLoadInclude
      (compiler-load-include-str-def name (read-file resolved)))
    (match (compiler-load-embedded-stdlib-source-for-path resolved)
      [(CompilerEmbeddedStdlibSomeSource source)
        (OkCompilerLoadInclude (compiler-load-include-str-def name source))]
      [(CompilerEmbeddedStdlibNoSource)
        (ErrCompilerLoadInclude
          (compiler-load-include-str-read-error
            importer-path
            include-path
            resolved))])))

(define (compiler-load-include-str-from-resolved-with-pools
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : String]
  [pools : AstNodePoolContext]) : ResultCompilerLoadInclude
  (if (file-exists? resolved)
    (OkCompilerLoadInclude
      (compiler-load-include-str-def-with-pools pools name (read-file resolved)))
    (match (compiler-load-embedded-stdlib-source-for-path resolved)
      [(CompilerEmbeddedStdlibSomeSource source)
        (OkCompilerLoadInclude
          (compiler-load-include-str-def-with-pools pools name source))]
      [(CompilerEmbeddedStdlibNoSource)
        (ErrCompilerLoadInclude
          (compiler-load-include-str-read-error
            importer-path
            include-path
            resolved))])))

(define (compiler-load-include-bin-read-error
  [importer-path : String]
  [include-path : String]
  [resolved : String]) : CompilerDiagnostic
  (compiler-diagnostic-at-start
    importer-path
    (str-cat
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
  (if (file-exists? resolved)
    (OkCompilerLoadInclude
      (compiler-load-include-bin-def name (read-file resolved)))
    (match (compiler-load-embedded-stdlib-source-for-path resolved)
      [(CompilerEmbeddedStdlibSomeSource source)
        (OkCompilerLoadInclude (compiler-load-include-bin-def name source))]
      [(CompilerEmbeddedStdlibNoSource)
        (ErrCompilerLoadInclude
          (compiler-load-include-bin-read-error
            importer-path
            include-path
            resolved))])))

(define (compiler-load-include-bin-from-resolved-with-pools
  [importer-path : String]
  [include-path : String]
  [resolved : String]
  [name : String]
  [pools : AstNodePoolContext]) : ResultCompilerLoadInclude
  (if (file-exists? resolved)
    (OkCompilerLoadInclude
      (compiler-load-include-bin-def-with-pools pools name (read-file resolved)))
    (match (compiler-load-embedded-stdlib-source-for-path resolved)
      [(CompilerEmbeddedStdlibSomeSource source)
        (OkCompilerLoadInclude
          (compiler-load-include-bin-def-with-pools pools name source))]
      [(CompilerEmbeddedStdlibNoSource)
        (ErrCompilerLoadInclude
          (compiler-load-include-bin-read-error
            importer-path
            include-path
            resolved))])))

(define (compiler-load-expand-include-str
  [importer-path : String]
  [include-path : String]
  [name : String]
  [stdlib-roots : StringVec]) : ResultCompilerLoadInclude
  (match (compiler-load-resolve-import-result-with-roots
    importer-path
    include-path
    stdlib-roots)
    [(OkPkgResolve resolved)
      (compiler-load-include-str-from-resolved
        importer-path
        include-path
        resolved
        name)]
    [(ErrPkgResolve message)
      (ErrCompilerLoadInclude
        (compiler-diagnostic-at-start importer-path message))]))

(define (compiler-load-expand-include-str-with-pools
  [importer-path : String]
  [include-path : String]
  [name : String]
  [stdlib-roots : StringVec]
  [pools : AstNodePoolContext]) : ResultCompilerLoadInclude
  (match (compiler-load-resolve-import-result-with-roots
    importer-path
    include-path
    stdlib-roots)
    [(OkPkgResolve resolved)
      (compiler-load-include-str-from-resolved-with-pools
        importer-path
        include-path
        resolved
        name
        pools)]
    [(ErrPkgResolve message)
      (ErrCompilerLoadInclude
        (compiler-diagnostic-at-start importer-path message))]))

(define (compiler-load-expand-include-bin
  [importer-path : String]
  [include-path : String]
  [name : String]
  [stdlib-roots : StringVec]) : ResultCompilerLoadInclude
  (match (compiler-load-resolve-import-result-with-roots
    importer-path
    include-path
    stdlib-roots)
    [(OkPkgResolve resolved)
      (compiler-load-include-bin-from-resolved
        importer-path
        include-path
        resolved
        name)]
    [(ErrPkgResolve message)
      (ErrCompilerLoadInclude
        (compiler-diagnostic-at-start importer-path message))]))

(define (compiler-load-expand-include-bin-with-pools
  [importer-path : String]
  [include-path : String]
  [name : String]
  [stdlib-roots : StringVec]
  [pools : AstNodePoolContext]) : ResultCompilerLoadInclude
  (match (compiler-load-resolve-import-result-with-roots
    importer-path
    include-path
    stdlib-roots)
    [(OkPkgResolve resolved)
      (compiler-load-include-bin-from-resolved-with-pools
        importer-path
        include-path
        resolved
        name
        pools)]
    [(ErrPkgResolve message)
      (ErrCompilerLoadInclude
        (compiler-diagnostic-at-start importer-path message))]))

(define (compiler-load-decl-list-append
  [left : AstDeclList]
  [right : AstDeclList]) : AstDeclList
  (match left
    [(AstDeclNil) right]
    [(AstDeclCons head rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (ast-decl-cons head (compiler-load-decl-list-append rest right)))]))

(define (compiler-load-decl-path-list-append
  [left : AstDeclPathList]
  [right : AstDeclPathList]) : AstDeclPathList
  (match left
    [(AstDeclPathNil) right]
    [(AstDeclPathCons head rest)
      (let
        [rest : AstDeclPathList (box-get rest)]
        (ast-decl-path-cons
          head
          (compiler-load-decl-path-list-append rest right)))]))

(define (compiler-load-decl-module-list-append
  [left : AstDeclModuleList]
  [right : AstDeclModuleList]) : AstDeclModuleList
  (match left
    [(AstDeclModuleNil) right]
    [(AstDeclModuleCons head rest)
      (let
        [rest : AstDeclModuleList (box-get rest)]
        (ast-decl-module-cons
          head
          (compiler-load-decl-module-list-append rest right)))]))

(define compiler-load-core-macro-prelude-path : String
  "stdlib/core_macros.tl")

;; `core_macros.tl` declares `(module stdlib.core_macros)`. Add a root module
;; marker after loading it so the following entry resumes in the root module,
;; matching import restoration and keeping module-less `main` discoverable.
(define (compiler-load-append-root-module-marker
  [loaded : ResultCompilerLoadWithPaths]) : ResultCompilerLoadWithPaths
  (match loaded
    [(OkCompilerLoadWithPaths decls paths modules seen)
      (OkCompilerLoadWithPaths
        (compiler-load-decl-list-append
          decls
          (ast-decl-cons (ast-decl-module "") AstDeclNil))
        (compiler-load-decl-path-list-append
          paths
          (ast-decl-path-cons
            compiler-load-core-macro-prelude-path
            AstDeclPathNil))
        (compiler-load-decl-module-list-append
          modules
          (ast-decl-module-cons "" AstDeclModuleNil))
        seen)]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-load-core-macro-prelude-with-roots-cfg
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-append-root-module-marker
    (compiler-load-file-with-paths-and-roots-cfg
      compiler-load-core-macro-prelude-path
      seen
      stdlib-roots
      cfgs)))

(define (compiler-load-core-macro-prelude-with-roots-cfg-with-pools
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-append-root-module-marker
    (compiler-load-file-with-paths-and-roots-cfg-with-pools
      compiler-load-core-macro-prelude-path
      seen
      stdlib-roots
      cfgs
      pools)))

(define (compiler-load-core-macro-prelude-with-roots
  [seen : SymI64Env]
  [stdlib-roots : StringVec]) : ResultCompilerLoadWithPaths
  (compiler-load-core-macro-prelude-with-roots-cfg
    seen
    stdlib-roots
    (compiler-cfg-empty)))

(define (compiler-load-drop-paths [result : ResultCompilerLoadWithPaths]) : ResultCompilerLoad
  (match result
    [(OkCompilerLoadWithPaths decls _ _ seen) (OkCompilerLoad decls seen)]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoad diag)]))

(define (compiler-load-decls-module-id-loop
  [path : String]
  [decls : AstDeclList]
  [fallback : String]
  [found : CompilerLoadMaybeModuleId]) : ResultCompilerLoadModuleId
  (match decls
    [(AstDeclNil)
      (match found
        [(CompilerLoadNoModuleId) (OkCompilerLoadModuleId fallback)]
        [(CompilerLoadSomeModuleId name) (OkCompilerLoadModuleId name)])]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule name)
            (match found
              [(CompilerLoadNoModuleId)
                (compiler-load-decls-module-id-loop
                  path
                  rest
                  fallback
                  (CompilerLoadSomeModuleId (intern-str name)))]
              [(CompilerLoadSomeModuleId _)
                (ErrCompilerLoadModuleId
                  (compiler-diagnostic-at-start
                    path
                    "compiler-load: duplicate module declaration"))])]
          [_ (compiler-load-decls-module-id-loop path rest fallback found)]))]))

(define (compiler-load-decls-module-id [path : String] [decls : AstDeclList]) : ResultCompilerLoadModuleId
  (compiler-load-decls-module-id-loop
    path
    decls
    (compiler-load-normalize-path path)
    CompilerLoadNoModuleId))

(define (compiler-load-check-expected-module
  [path : String]
  [expected : AstMaybeModuleName]
  [actual : String]) : ResultCompilerLoadModuleId
  (match expected
    [(AstNoModuleName) (OkCompilerLoadModuleId actual)]
    [(AstSomeModuleName want)
      (if (string-eq want actual)
        (OkCompilerLoadModuleId actual)
        (ErrCompilerLoadModuleId
          (compiler-diagnostic-at-start
            path
            (string-append
              "compiler-load: import expected module "
              (string-append want (string-append " but loaded " actual))))))]))

(define (compiler-load-no-expected-module? [expected : AstMaybeModuleName]) : bool
  (match expected
    [(AstNoModuleName) true]
    [(AstSomeModuleName _) false]))

(define (compiler-load-seen-path-key [path : String]) : String
  (string-append "path:" (compiler-load-normalize-path path)))

(define (compiler-load-decls-source-module [decls : AstDeclList]) : String
  (match decls
    [(AstDeclNil) ""]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule name) (intern-str name)]
          [_ (compiler-load-decls-source-module rest)]))]))

(define (compiler-load-decl-list-has-module? [decls : AstDeclList]) : bool
  (match decls
    [(AstDeclNil) false]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule _) true]
          [_ (compiler-load-decl-list-has-module? rest)]))]))

(define (compiler-load-seen-module-with-paths
  [path : String]
  [module-id : String]
  [decls : AstDeclList]
  [seen : SymI64Env]) : ResultCompilerLoadWithPaths
  (if (compiler-load-decl-list-has-module? decls)
    (OkCompilerLoadWithPaths
      (ast-decl-cons (ast-decl-module module-id) AstDeclNil)
      (ast-decl-path-cons path AstDeclPathNil)
      (ast-decl-module-cons module-id AstDeclModuleNil)
      seen)
    (OkCompilerLoadWithPaths AstDeclNil AstDeclPathNil AstDeclModuleNil seen)))

(define (compiler-load-legacy-path-flat-module-import?
  [kind : AstImportKind]
  [expected : AstMaybeModuleName]
  [alias : AstMaybeImportAlias]
  [imported-decls : AstDeclList]) : bool
  (match kind
    [(AstImportPath)
      (match expected
        [(AstNoModuleName)
          (match alias
            [(AstNoImportAlias)
              (compiler-load-decl-list-has-module? imported-decls)]
            [(AstSomeImportAlias _) false])]
        [(AstSomeModuleName _) false])]
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
    (AstSomeModuleName (compiler-load-decls-source-module imported-decls))
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
    (AstSomeImportAlias "")
    alias))

(define (compiler-load-dotted-import-alias-key
  [module : String]
  [alias : String]) : String
  (string-append module (string-append "/" alias)))

(define (compiler-load-duplicate-dotted-import-alias-loop
  [decls : AstDeclList]
  [current-module : String]
  [seen : SymI64Env]) : CompilerLoadMaybeString
  (match decls
    [(AstDeclNil) (CompilerLoadNoString)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclModule name)
            (compiler-load-duplicate-dotted-import-alias-loop
              rest
              (intern-str name)
              seen)]
          [(AstDeclImport
              (AstImportSpec (AstImportModule) _ _ (AstSomeImportAlias alias) _))
            (let
              [key : String
                (compiler-load-dotted-import-alias-key current-module alias)]
              (if (sym-i64-contains seen key)
                (CompilerLoadSomeString alias)
                (compiler-load-duplicate-dotted-import-alias-loop
                  rest
                  current-module
                  (sym-i64-bind seen key 1))))]
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
    (sym-i64-empty))
    [(CompilerLoadNoString) (OkCompilerLoadAliasCheck)]
    [(CompilerLoadSomeString alias)
      (ErrCompilerLoadAliasCheck
        (compiler-diagnostic-at-start
          path
          (string-append "compiler-load: duplicate module import alias " alias)))]))

(define (compiler-load-decls-with-paths
  [decls : AstDeclList]
  [importer-path : String]
  [seen : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-decls-with-paths-and-roots
    decls
    importer-path
    seen
    (string-vec-new)))

(define (compiler-load-alias-decl-list
  [kind : AstImportKind]
  [import-path : String]
  [expected-module : AstMaybeModuleName]
  [alias : AstMaybeImportAlias]
  [rest : AstDeclList]) : AstDeclList
  (match alias
    [(AstSomeImportAlias _)
      (ast-decl-cons
        (AstDeclImport
          (AstImportSpec
            kind
            import-path
            expected-module
            alias
            (AstSourceSpan 0 0 0 0)))
        rest)]
    [(AstNoImportAlias) rest]))

(define (compiler-load-alias-path-list
  [importer-path : String]
  [alias : AstMaybeImportAlias]
  [rest : AstDeclPathList]) : AstDeclPathList
  (match alias
    [(AstSomeImportAlias _) (ast-decl-path-cons importer-path rest)]
    [(AstNoImportAlias) rest]))

(define (compiler-load-alias-module-list
  [importer-module : String]
  [alias : AstMaybeImportAlias]
  [rest : AstDeclModuleList]) : AstDeclModuleList
  (match alias
    [(AstSomeImportAlias _) (ast-decl-module-cons importer-module rest)]
    [(AstNoImportAlias) rest]))

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
      (ast-decl-cons (ast-decl-module importer-source-module) after-alias)
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
      (ast-decl-path-cons importer-path after-alias)
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
      (ast-decl-module-cons importer-module after-alias)
      after-alias)))

(define (compiler-load-decls-with-module-and-roots
  [decls : AstDeclList]
  [importer-path : String]
  [importer-module : String]
  [importer-source-module : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]) : ResultCompilerLoadWithPaths
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
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
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
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]
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
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [import-root : String]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match decls
    [(AstDeclNil)
      (OkCompilerLoadWithPaths AstDeclNil AstDeclPathNil AstDeclModuleNil seen)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport
              (AstImportSpec kind import-path expected-module alias _))
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
                [(OkCompilerLoadWithPaths
                    rest-decls
                    rest-paths
                    rest-modules
                    rest-seen)
                  (OkCompilerLoadWithPaths
                    (ast-decl-cons decl rest-decls)
                    (ast-decl-path-cons importer-path rest-paths)
                    (ast-decl-module-cons importer-module rest-modules)
                    rest-seen)]
                [(ErrCompilerLoadWithPaths diag)
                  (ErrCompilerLoadWithPaths diag)])
              (match (compiler-load-resolve-import-spec-with-roots
                importer-path
                import-root
                kind
                import-path
                stdlib-roots)
                [(OkPkgResolve resolved)
                  (match (compiler-load-file-with-paths-and-roots-expect-cfg-root-with-pools
                    resolved
                    seen
                    stdlib-roots
                    expected-module
                    import-root
                    cfgs
                    pools)
                    [(OkCompilerLoadWithPaths
                        imported-decls
                        imported-paths
                        imported-modules
                        import-seen)
                      (match (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                        rest
                        importer-path
                        importer-module
                        importer-source-module
                        import-seen
                        stdlib-roots
                        import-root
                        cfgs
                        pools)
                        [(OkCompilerLoadWithPaths
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
                            (OkCompilerLoadWithPaths
                              (compiler-load-decl-list-append
                                imported-decls
                                (compiler-load-decls-after-import
                                  kind
                                  resolved
                                  after-import-expected
                                  after-import-alias
                                  importer-source-module
                                  imported-decls
                                  rest-decls))
                              (compiler-load-decl-path-list-append
                                imported-paths
                                (compiler-load-paths-after-import
                                  importer-path
                                  after-import-alias
                                  imported-decls
                                  rest-paths))
                              (compiler-load-decl-module-list-append
                                imported-modules
                                (compiler-load-modules-after-import
                                  importer-module
                                  after-import-alias
                                  imported-decls
                                  rest-modules))
                              rest-seen))]
                        [(ErrCompilerLoadWithPaths diag)
                          (ErrCompilerLoadWithPaths diag)])]
                    [(ErrCompilerLoadWithPaths diag)
                      (ErrCompilerLoadWithPaths diag)])]
                [(ErrPkgResolve message)
                  (ErrCompilerLoadWithPaths
                    (compiler-diagnostic-at-start importer-path message))]))]
          [(AstDeclIncludeStr name include-path)
            (match (compiler-load-expand-include-str-with-pools
              importer-path
              include-path
              name
              stdlib-roots
              pools)
              [(OkCompilerLoadInclude expanded)
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
                  [(OkCompilerLoadWithPaths
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (OkCompilerLoadWithPaths
                      (ast-decl-cons expanded rest-decls)
                      (ast-decl-path-cons importer-path rest-paths)
                      (ast-decl-module-cons importer-module rest-modules)
                      rest-seen)]
                  [(ErrCompilerLoadWithPaths diag)
                    (ErrCompilerLoadWithPaths diag)])]
              [(ErrCompilerLoadInclude diag) (ErrCompilerLoadWithPaths diag)])]
          [(AstDeclIncludeBin name include-path)
            (match (compiler-load-expand-include-bin-with-pools
              importer-path
              include-path
              name
              stdlib-roots
              pools)
              [(OkCompilerLoadInclude expanded)
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
                  [(OkCompilerLoadWithPaths
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (OkCompilerLoadWithPaths
                      (ast-decl-cons expanded rest-decls)
                      (ast-decl-path-cons importer-path rest-paths)
                      (ast-decl-module-cons importer-module rest-modules)
                      rest-seen)]
                  [(ErrCompilerLoadWithPaths diag)
                    (ErrCompilerLoadWithPaths diag)])]
              [(ErrCompilerLoadInclude diag) (ErrCompilerLoadWithPaths diag)])]
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
              [(OkCompilerLoadWithPaths
                  rest-decls
                  rest-paths
                  rest-modules
                  rest-seen)
                (OkCompilerLoadWithPaths
                  (ast-decl-cons decl rest-decls)
                  (ast-decl-path-cons importer-path rest-paths)
                  (ast-decl-module-cons importer-module rest-modules)
                  rest-seen)]
              [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]))]))

(define (compiler-load-decls-with-module-and-roots-cfg-root
  [decls : AstDeclList]
  [importer-path : String]
  [importer-module : String]
  [importer-source-module : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [import-root : String]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
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
  [seen : SymI64Env]
  [stdlib-roots : StringVec]) : ResultCompilerLoadWithPaths
  (compiler-load-decls-with-paths-and-roots-cfg
    decls
    importer-path
    seen
    stdlib-roots
    (compiler-cfg-empty)))

(define (compiler-load-decls-with-paths-and-roots-cfg
  [decls : AstDeclList]
  [importer-path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-load-decls-module-id importer-path decls)
    [(OkCompilerLoadModuleId module-id)
      (if (sym-i64-contains seen module-id)
        (OkCompilerLoadWithPaths
          AstDeclNil
          AstDeclPathNil
          AstDeclModuleNil
          seen)
        (compiler-load-decls-with-module-and-roots-cfg
          decls
          importer-path
          module-id
          (compiler-load-decls-source-module decls)
          (sym-i64-bind seen module-id 1)
          stdlib-roots
          cfgs))]
    [(ErrCompilerLoadModuleId diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-load-decls-with-paths-and-roots-cfg-with-pools
  [decls : AstDeclList]
  [importer-path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (compiler-load-decls-module-id importer-path decls)
    [(OkCompilerLoadModuleId module-id)
      (if (sym-i64-contains seen module-id)
        (OkCompilerLoadWithPaths
          AstDeclNil
          AstDeclPathNil
          AstDeclModuleNil
          seen)
        (compiler-load-decls-with-module-and-roots-cfg-with-pools
          decls
          importer-path
          module-id
          (compiler-load-decls-source-module decls)
          (sym-i64-bind seen module-id 1)
          stdlib-roots
          cfgs
          pools))]
    [(ErrCompilerLoadModuleId diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-load-decls
  [decls : AstDeclList]
  [importer-path : String]
  [seen : SymI64Env]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-decls-with-paths decls importer-path seen)))

(define (compiler-load-decls-with-roots
  [decls : AstDeclList]
  [importer-path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-decls-with-paths-and-roots
      decls
      importer-path
      seen
      stdlib-roots)))

(define (compiler-load-program-with-paths
  [path : String]
  [program : AstProgram]
  [seen : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-program-with-paths-and-roots
    path
    program
    seen
    (string-vec-new)))

(define (compiler-load-program-with-paths-and-roots
  [path : String]
  [program : AstProgram]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]) : ResultCompilerLoadWithPaths
  (compiler-load-program-with-paths-and-roots-expect
    path
    program
    seen
    stdlib-roots
    AstNoModuleName))

(define (compiler-load-program-with-paths-and-roots-expect
  [path : String]
  [program : AstProgram]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
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
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [expected-module : AstMaybeModuleName]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
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
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [expected-module : AstMaybeModuleName]
  [cfgs : SymI64Env]
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
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [expected-module : AstMaybeModuleName]
  [import-root : String]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        [source-module : String (compiler-load-decls-source-module decls)]
        (match (compiler-load-decls-module-id path decls)
          [(OkCompilerLoadModuleId module-id)
            (match (compiler-load-check-expected-module
              path
              expected-module
              module-id)
              [(OkCompilerLoadModuleId _)
                (if (sym-i64-contains seen module-id)
                  (compiler-load-seen-module-with-paths
                    path
                    module-id
                    decls
                    seen)
                  (match (compiler-load-check-dotted-import-aliases
                    path
                    decls
                    source-module)
                    [(OkCompilerLoadAliasCheck)
                      (compiler-load-decls-with-module-and-roots-cfg-root-with-pools
                        decls
                        path
                        module-id
                        source-module
                        (sym-i64-bind seen module-id 1)
                        stdlib-roots
                        import-root
                        cfgs
                        pools)]
                    [(ErrCompilerLoadAliasCheck diag)
                      (ErrCompilerLoadWithPaths diag)]))]
              [(ErrCompilerLoadModuleId diag) (ErrCompilerLoadWithPaths diag)])]
          [(ErrCompilerLoadModuleId diag) (ErrCompilerLoadWithPaths diag)]))]))

(define (compiler-load-program-with-paths-and-roots-expect-cfg-root
  [path : String]
  [program : AstProgram]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [expected-module : AstMaybeModuleName]
  [import-root : String]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
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
  [seen : SymI64Env]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-program-with-paths path program seen)))

(define (compiler-load-program-with-roots
  [path : String]
  [program : AstProgram]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-program-with-paths-and-roots path program seen stdlib-roots)))

(define (compiler-load-source-with-paths
  [path : String]
  [source : String]
  [seen : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots path source seen (string-vec-new)))

(define (compiler-load-source-with-paths-and-roots
  [path : String]
  [source : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots-expect
    path
    source
    seen
    stdlib-roots
    AstNoModuleName))

(define (compiler-load-source-with-paths-and-roots-cfg
  [path : String]
  [source : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-source-with-paths-and-roots-expect-cfg
    path
    source
    seen
    stdlib-roots
    AstNoModuleName
    cfgs))

(define (compiler-load-source-with-paths-and-roots-expect
  [path : String]
  [source : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
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
  [cfgs : SymI64Env]) : ResultAstProgramDiagnostic
  (parse-ast-source-diagnostic-with-cfg path source cfgs))

(define (compiler-load-parse-source-diagnostic-escaping-with-pools
  [path : String]
  [source : String]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (parse-ast-source-diagnostic-with-cfg-and-pools path source cfgs pools))

(define (compiler-load-parse-file-diagnostic-escaping
  [path : String]
  [cfgs : SymI64Env]) : ResultAstProgramDiagnostic
  (let
    [source : String (read-file path)]
    (compiler-load-parse-source-diagnostic-escaping path source cfgs)))

(define (compiler-load-parse-file-diagnostic-escaping-with-pools
  [path : String]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (let
    [source : String (read-file path)]
    (compiler-load-parse-source-diagnostic-escaping-with-pools
      path
      source
      cfgs
      pools)))

(define (compiler-load-cache-program-result
  [key : String]
  [result : ResultAstProgramDiagnostic]) : ResultAstProgramDiagnostic
  (match result
    [(OkAstProgramDiagnostic program)
      (begin
        (if (compiler-load-program-cache-store key program)
          (compiler-load-session-note-persistent!)
          unit)
        (OkAstProgramDiagnostic program))]
    [(ErrAstProgramDiagnostic diag) (ErrAstProgramDiagnostic diag)]))

(define (compiler-load-cache-program-result-with-pools
  [key : String]
  [result : ResultAstProgramDiagnostic]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (match result
    [(OkAstProgramDiagnostic program)
      (begin
        (if (compiler-load-program-cache-store key program)
          (compiler-load-session-note-persistent-with-pools! pools)
          unit)
        (OkAstProgramDiagnostic program))]
    [(ErrAstProgramDiagnostic diag) (ErrAstProgramDiagnostic diag)]))

(define (compiler-load-parse-file-diagnostic-cache-miss
  [key : String]
  [path : String]
  [cfgs : SymI64Env]) : ResultAstProgramDiagnostic
  (if (compiler-load-program-cache-can-store key)
    (let
      [prev-arena : i64 (arena-current)]
      [loaded : ResultAstProgramDiagnostic
        (begin
          (unsafe
            (arena-set! node-pool-base-arena))
          (let
            [persistent-key : String (string-copy-borrowed (& key))]
            [parsed : ResultAstProgramDiagnostic
              (compiler-load-parse-file-diagnostic-escaping path cfgs)]
            (begin
              (unsafe
                (arena-set! prev-arena))
              (compiler-load-cache-program-result persistent-key parsed))))]
      loaded)
    (compiler-load-parse-file-diagnostic-escaping path cfgs)))

(define (compiler-load-parse-file-diagnostic-cache-miss-with-pools
  [key : String]
  [path : String]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (if (compiler-load-program-cache-can-store key)
    (let
      [prev-arena : i64 (arena-current)]
      [loaded : ResultAstProgramDiagnostic
        (begin
          (unsafe
            (arena-set! (ast-node-pool-context-base-arena pools)))
          (let
            [persistent-key : String (string-copy-borrowed (& key))]
            [parsed : ResultAstProgramDiagnostic
              (compiler-load-parse-file-diagnostic-escaping-with-pools
                path
                cfgs
                pools)]
            (begin
              (unsafe
                (arena-set! prev-arena))
              (compiler-load-cache-program-result-with-pools
                persistent-key
                parsed
                pools))))]
      loaded)
    (compiler-load-parse-file-diagnostic-escaping-with-pools path cfgs pools)))

(define (compiler-load-ast-program-result-ok?
  [result : ResultAstProgramDiagnostic]) : bool
  (match result
    [(OkAstProgramDiagnostic _) true]
    [(ErrAstProgramDiagnostic _) false]))

(define (compiler-load-parse-file-diagnostic-cache-miss-local
  [key : String]
  [path : String]
  [cfgs : SymI64Env]) : ResultAstProgramDiagnostic
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
  [cfgs : SymI64Env]
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
  [cfgs : SymI64Env]) : ResultAstProgramDiagnostic
  (let
    [parsed : ResultAstProgramDiagnostic
      (compiler-load-parse-file-diagnostic-escaping path cfgs)]
    (begin
      (match parsed
        [(OkAstProgramDiagnostic _)
          (if (compiler-load-program-admission-record-persistent key)
            unit
            unit)]
        [(ErrAstProgramDiagnostic _) unit])
      parsed)))

(define (compiler-load-parse-file-diagnostic-admit-only-with-pools
  [key : String]
  [path : String]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (let
    [parsed : ResultAstProgramDiagnostic
      (compiler-load-parse-file-diagnostic-escaping-with-pools path cfgs pools)]
    (begin
      (match parsed
        [(OkAstProgramDiagnostic _)
          (if (compiler-load-program-admission-record-persistent key)
            unit
            unit)]
        [(ErrAstProgramDiagnostic _) unit])
      parsed)))

(define (compiler-load-parse-file-diagnostic-session
  [path : String]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : ResultAstProgramDiagnostic
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
            (OkAstProgramDiagnostic program))]
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
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]
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
            (OkAstProgramDiagnostic program))]
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
  [cfgs : SymI64Env]) : ResultAstProgramDiagnostic
  (if (compiler-load-program-cache-can-store key)
    (let
      [prev-arena : i64 (arena-current)]
      [loaded : ResultAstProgramDiagnostic
        (begin
          (unsafe
            (arena-set! node-pool-base-arena))
          (let
            [persistent-key : String (string-copy-borrowed (& key))]
            [parsed : ResultAstProgramDiagnostic
              (compiler-load-parse-source-diagnostic-escaping path source cfgs)]
            (begin
              (unsafe
                (arena-set! prev-arena))
              (compiler-load-cache-program-result persistent-key parsed))))]
      loaded)
    (compiler-load-parse-source-diagnostic-escaping path source cfgs)))

(define (compiler-load-parse-embedded-source-diagnostic-cache-miss-with-pools
  [key : String]
  [path : String]
  [source : String]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultAstProgramDiagnostic
  (if (compiler-load-program-cache-can-store key)
    (let
      [prev-arena : i64 (arena-current)]
      [loaded : ResultAstProgramDiagnostic
        (begin
          (unsafe
            (arena-set! (ast-node-pool-context-base-arena pools)))
          (let
            [persistent-key : String (string-copy-borrowed (& key))]
            [parsed : ResultAstProgramDiagnostic
              (compiler-load-parse-source-diagnostic-escaping-with-pools
                path
                source
                cfgs
                pools)]
            (begin
              (unsafe
                (arena-set! prev-arena))
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
  [cfgs : SymI64Env]) : ResultAstProgramDiagnostic
  (if (and
    (compiler-load-session-cache-enabled?)
    (compiler-load-session-program-cache-enabled?))
    (let
      [key : String (compiler-load-program-cache-key "embedded" path cfgs)]
      (match (compiler-load-program-cache-lookup key)
        [(CompilerLoadProgramCacheHit program)
          (begin
            (compiler-load-program-cache-note-hit!)
            (OkAstProgramDiagnostic program))]
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
  [cfgs : SymI64Env]
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
            (OkAstProgramDiagnostic program))]
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
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [expected-module : AstMaybeModuleName]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-load-parse-source-diagnostic-escaping path source cfgs)
    [(OkAstProgramDiagnostic program)
      (compiler-load-program-with-paths-and-roots-expect-cfg
        path
        program
        seen
        stdlib-roots
        expected-module
        cfgs)]
    [(ErrAstProgramDiagnostic diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-load-source-with-paths-and-roots-expect-cfg-with-pools
  [path : String]
  [source : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [expected-module : AstMaybeModuleName]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (compiler-load-parse-source-diagnostic-escaping-with-pools
    path
    source
    cfgs
    pools)
    [(OkAstProgramDiagnostic program)
      (compiler-load-program-with-paths-and-roots-expect-cfg-with-pools
        path
        program
        seen
        stdlib-roots
        expected-module
        cfgs
        pools)]
    [(ErrAstProgramDiagnostic diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-load-source
  [path : String]
  [source : String]
  [seen : SymI64Env]) : ResultCompilerLoad
  (compiler-load-drop-paths (compiler-load-source-with-paths path source seen)))

(define (compiler-load-source-with-roots
  [path : String]
  [source : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]) : ResultCompilerLoad
  (compiler-load-drop-paths
    (compiler-load-source-with-paths-and-roots path source seen stdlib-roots)))

(define (compiler-load-file-with-paths [path : String] [seen : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots path seen (string-vec-new)))

(define (compiler-load-file-with-paths-and-roots
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect
    path
    seen
    stdlib-roots
    AstNoModuleName))

(define (compiler-load-file-with-paths-and-roots-cfg
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg
    path
    seen
    stdlib-roots
    AstNoModuleName
    cfgs))

(define (compiler-load-file-with-paths-and-roots-cfg-with-pools
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-with-pools
    path
    seen
    stdlib-roots
    AstNoModuleName
    cfgs
    pools))

(define (compiler-load-file-with-paths-and-roots-expect
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
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
    [(OkCompilerLoadWithPaths decls paths modules loaded-seen)
      (OkCompilerLoadWithPaths
        decls
        paths
        modules
        (if path-dedup
          (sym-i64-bind loaded-seen path-key 1)
          loaded-seen))]
    [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)]))

(define (compiler-load-file-with-paths-and-roots-expect-cfg
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [expected-module : AstMaybeModuleName]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root
    path
    seen
    stdlib-roots
    expected-module
    (compiler-load-dirname path)
    cfgs))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-with-pools
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [expected-module : AstMaybeModuleName]
  [cfgs : SymI64Env]
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
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [expected-module : AstMaybeModuleName]
  [import-root : String]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
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
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [expected-module : AstMaybeModuleName]
  [import-root : String]
  [cfgs : SymI64Env]
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

(define (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [expected-module : AstMaybeModuleName]
  [import-root : String]
  [cfgs : SymI64Env]
  [cache-current : bool]) : ResultCompilerLoadWithPaths
  (let
    [path-key : String (compiler-load-seen-path-key path)]
    [path-dedup : bool (compiler-load-no-expected-module? expected-module)]
    (if (and path-dedup (sym-i64-contains seen path-key))
      (OkCompilerLoadWithPaths AstDeclNil AstDeclPathNil AstDeclModuleNil seen)
      (if (file-exists? path)
        (match (if cache-current
          (compiler-load-parse-file-diagnostic-session path stdlib-roots cfgs)
          (compiler-load-parse-file-diagnostic-escaping path cfgs))
          [(OkAstProgramDiagnostic program)
            (compiler-load-bind-path-dedup
              (compiler-load-program-with-paths-and-roots-expect-cfg-root
                path
                program
                seen
                stdlib-roots
                expected-module
                import-root
                cfgs)
              path-dedup
              path-key)]
          [(ErrAstProgramDiagnostic diag) (ErrCompilerLoadWithPaths diag)])
        (match (compiler-load-embedded-stdlib-source-for-path path)
          [(CompilerEmbeddedStdlibSomeSource source)
            (match (if cache-current
              (compiler-load-parse-embedded-source-diagnostic-session
                path
                source
                cfgs)
              (compiler-load-parse-source-diagnostic-escaping path source cfgs))
              [(OkAstProgramDiagnostic program)
                (compiler-load-bind-path-dedup
                  (compiler-load-program-with-paths-and-roots-expect-cfg-root
                    path
                    program
                    seen
                    stdlib-roots
                    expected-module
                    import-root
                    cfgs)
                  path-dedup
                  path-key)]
              [(ErrAstProgramDiagnostic diag) (ErrCompilerLoadWithPaths diag)])]
          [(CompilerEmbeddedStdlibNoSource)
            (ErrCompilerLoadWithPaths
              (compiler-diagnostic-at-start
                path
                (string-append "compiler-load: cannot read import " path)))])))))

(define (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-with-pools
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [expected-module : AstMaybeModuleName]
  [import-root : String]
  [cfgs : SymI64Env]
  [cache-current : bool]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (let
    [path-key : String (compiler-load-seen-path-key path)]
    [path-dedup : bool (compiler-load-no-expected-module? expected-module)]
    (if (and path-dedup (sym-i64-contains seen path-key))
      (OkCompilerLoadWithPaths AstDeclNil AstDeclPathNil AstDeclModuleNil seen)
      (if (file-exists? path)
        (match (if cache-current
          (compiler-load-parse-file-diagnostic-session-with-pools
            path
            stdlib-roots
            cfgs
            pools)
          (compiler-load-parse-file-diagnostic-escaping-with-pools
            path
            cfgs
            pools))
          [(OkAstProgramDiagnostic program)
            (compiler-load-bind-path-dedup
              (compiler-load-program-with-paths-and-roots-expect-cfg-root-with-pools
                path
                program
                seen
                stdlib-roots
                expected-module
                import-root
                cfgs
                pools)
              path-dedup
              path-key)]
          [(ErrAstProgramDiagnostic diag) (ErrCompilerLoadWithPaths diag)])
        (match (compiler-load-embedded-stdlib-source-for-path path)
          [(CompilerEmbeddedStdlibSomeSource source)
            (match (if cache-current
              (compiler-load-parse-embedded-source-diagnostic-session-with-pools
                path
                source
                cfgs
                pools)
              (compiler-load-parse-source-diagnostic-escaping-with-pools
                path
                source
                cfgs
                pools))
              [(OkAstProgramDiagnostic program)
                (compiler-load-bind-path-dedup
                  (compiler-load-program-with-paths-and-roots-expect-cfg-root-with-pools
                    path
                    program
                    seen
                    stdlib-roots
                    expected-module
                    import-root
                    cfgs
                    pools)
                  path-dedup
                  path-key)]
              [(ErrAstProgramDiagnostic diag) (ErrCompilerLoadWithPaths diag)])]
          [(CompilerEmbeddedStdlibNoSource)
            (ErrCompilerLoadWithPaths
              (compiler-diagnostic-at-start
                path
                (string-append "compiler-load: cannot read import " path)))])))))

(define (compiler-load-entry-file-with-paths-and-roots-cfg
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current
    path
    seen
    stdlib-roots
    AstNoModuleName
    (compiler-load-dirname path)
    cfgs
    false))

(define (compiler-load-entry-file-with-paths-and-roots-cfg-with-pools
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (compiler-load-file-with-paths-and-roots-expect-cfg-root-cache-current-with-pools
    path
    seen
    stdlib-roots
    AstNoModuleName
    (compiler-load-dirname path)
    cfgs
    false
    pools))

(define (compiler-load-file [path : String] [seen : SymI64Env]) : ResultCompilerLoad
  (compiler-load-drop-paths (compiler-load-file-with-paths path seen)))

(define (compiler-load-file-with-roots
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]) : ResultCompilerLoad
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
  (string-append
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
      (substring text idx 1)]
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
      (string-append
        "_u"
        (compiler-load-package-hex-byte (compiler-load-char-code-at text idx)))]))

(define (compiler-load-package-asm-safe-symbol [name : String]) : String
  (let
    [i : i64 0]
    [n : i64 (string-length name)]
    [out : String ""]
    [emitted : bool false]
    [pending-separator : bool false]
    (begin
      (while (< i n)
        (if (compiler-load-package-tl-extension-at? name i)
          (set! i (+ i 3))
          (let
            [c : char (string-ref name i)]
            (if (compiler-load-package-symbol-separator? c)
              (begin
                (if emitted
                  (set! pending-separator true)
                  unit)
                (set! i (+ i 1)))
              (begin
                (if pending-separator
                  (begin
                    (set! out (string-append out "_"))
                    (set! pending-separator false))
                  unit)
                (set!
                  out
                  (string-append
                    out
                    (compiler-load-package-symbol-char name i c)))
                (set! emitted true)
                (set! i (+ i 1)))))))
      out)))

(define (compiler-load-package-symbol-separator? [c : char]) : bool
  (or (= c '/') (= c '\\') (= c ':') (= c '.')))

(define (compiler-load-package-tl-extension-at? [name : String] [idx : i64]) : bool
  (let
    [n : i64 (string-length name)]
    [after : i64 (+ idx 3)]
    (and
      (<= after n)
      (= (string-ref name idx) '.')
      (= (string-ref name (+ idx 1)) 't')
      (= (string-ref name (+ idx 2)) 'l')
      (or
        (= after n)
        (compiler-load-package-symbol-separator? (string-ref name after))))))

(define (compiler-load-package-user-symbol [name : String]) : String
  (if (string-eq name "main")
    "main"
    (string-append "_tl_" (compiler-load-package-asm-safe-symbol name))))

(define (compiler-load-package-module-key [module : String] [name : String]) : String
  (if (= (string-length module) 0)
    name
    (string-append module (string-append "/" name))))

(define (compiler-load-package-module-id
  [entry-path : String]
  [decl-path : String]) : String
  (let
    [base : String (compiler-load-dirname entry-path)]
    [base-len : i64 (string-length base)]
    [decl-len : i64 (string-length decl-path)]
    (if (and (> base-len 0) (compiler-load-string-prefix-at? decl-path base 0))
      (substring decl-path base-len (- decl-len base-len))
      decl-path)))

(define (compiler-load-package-module-logical-name
  [entry-path : String]
  [decl-path : String]
  [source-name : String]) : String
  (if (and (string-eq decl-path entry-path) (string-eq source-name "main"))
    "main"
    (string-append
      (string-append
        (compiler-load-package-module-id entry-path decl-path)
        "::")
      source-name)))

(define (compiler-load-package-entry-main?
  [entry-path : String]
  [decl-path : String]
  [module : String]
  [source-name : String]) : bool
  (and
    (string-eq decl-path entry-path)
    (string-eq source-name "main")
    (or (string-eq module "") (string-eq module "main"))))

(define (compiler-load-root-prefix [root : String]) : String
  (compiler-load-join-root-path root ""))

(define (compiler-load-path-under-root? [path : String] [root : String]) : bool
  (let
    [prefix : String (compiler-load-root-prefix root)]
    [prefix-len : i64 (string-length prefix)]
    (and (> prefix-len 0) (compiler-load-string-prefix-at? path prefix 0))))

(define (compiler-load-owned-path-from-root
  [owner : String]
  [root : String]
  [path : String]) : String
  (let
    [prefix : String (compiler-load-root-prefix root)]
    [prefix-len : i64 (string-length prefix)]
    [path-len : i64 (string-length path)]
    (if (= prefix-len 0)
      (if (compiler-load-absolute-path? path)
        path
        (string-append
          owner
          (string-append "/" (compiler-load-normalize-path path))))
      (if (compiler-load-path-under-root? path root)
        (string-append
          owner
          (string-append
            "/"
            (substring path prefix-len (- path-len prefix-len))))
        path))))

(define (compiler-load-stdlib-owner-root? [root : String]) : bool
  (let
    [normalized : String (compiler-load-normalize-path root)]
    [base : String (fs-basename (& normalized))]
    (string-eq base "stdlib")))

(define (compiler-load-stdlib-owned-path-from-roots
  [path : String]
  [stdlib-roots : StringVec]) : String
  (let
    [roots : StringVec (compiler-load-roots-with-env stdlib-roots)]
    [i : i64 0]
    [n : i64 (string-vec-len roots)]
    [found : bool false]
    [out : String ""]
    (begin
      (while (and (not found) (< i n))
        (let
          [root : String (string-vec-get roots i "")]
          [prefix : String (compiler-load-root-prefix root)]
          [prefix-len : i64 (string-length prefix)]
          [path-len : i64 (string-length path)]
          (if (and
            (compiler-load-stdlib-owner-root? root)
            (> prefix-len 0)
            (compiler-load-string-prefix-at? path prefix 0))
            (begin
              (set! found true)
              (set!
                out
                (string-append
                  "stdlib/"
                  (substring path prefix-len (- path-len prefix-len)))))
            (set! i (+ i 1)))))
      (if found
        out
        path))))

(define (compiler-load-package-owned-path
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : StringVec]
  [path : String]) : String
  (let
    [stdlib-path : String
      (if (compiler-load-stdlib-import? path)
        (compiler-load-normalize-path path)
        (compiler-load-stdlib-owned-path-from-roots path stdlib-roots))]
    (if (compiler-load-stdlib-import? stdlib-path)
      stdlib-path
      (if (= (string-length package-owner) 0)
        path
        (compiler-load-owned-path-from-root package-owner package-root path)))))

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
    (if (string-eq module "")
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
    [(AstParamNil) AstTypeNil]
    [(AstParamCons param rest)
      (let
        [rest : AstParamList (box-get rest)]
        (match param
          [(AstParam _ ty _)
            (ast-type-cons ty (compiler-load-param-type-list rest))]))]))

(define (compiler-load-package-def-fn-extern
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : StringVec]
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
    (AstDeclExtern
      name
      (AstExternFunction)
      (AstExternMetadata
        (AstExternAbiC)
        (compiler-load-package-user-symbol logical)
        AstExternLinkInputNil
        false)
      (ast-ty-func (compiler-load-param-type-list params) ret))))

(define (compiler-load-package-transform-decl
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : StringVec]
  [decl-path : String]
  [module : String]
  [decl : AstDecl]) : CompilerLoadMaybeDecl
  (match decl
    [(AstDeclDefFn name params ret _ _)
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
    [(AstDeclDefStruct _ _ _ _) (CompilerLoadSomeDecl decl)]
    [(AstDeclModule _) (CompilerLoadSomeDecl decl)]
    [(AstDeclUnsafe inner-box)
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
    [(AstDeclComptimeDecl meta template-box)
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
  (match paths
    [(AstDeclPathCons path _) path]
    [(AstDeclPathNil) fallback]))

(define (compiler-load-path-list-tail [paths : AstDeclPathList]) : AstDeclPathList
  (match paths
    [(AstDeclPathCons _ rest)
      (let
        [rest : AstDeclPathList (box-get rest)]
        rest)]
    [(AstDeclPathNil) AstDeclPathNil]))

(define (compiler-load-package-owned-decl-path
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : StringVec]
  [entry-path : String]
  [module : String]
  [decl-path : String]
  [decl : AstDecl]) : String
  (match decl
    [(AstDeclDefFn name _ _ _ _)
      (if (compiler-load-package-entry-main?
        entry-path
        decl-path
        module
        (intern-str name))
        ""
        (compiler-load-package-owned-path
          package-owner
          package-root
          stdlib-roots
          decl-path))]
    [(AstDeclUnsafe inner-box)
      (let
        [inner : AstDecl (box-get inner-box)]
        (compiler-load-package-owned-decl-path
          package-owner
          package-root
          stdlib-roots
          entry-path
          module
          decl-path
          inner))]
    [_
      (compiler-load-package-owned-path
        package-owner
        package-root
        stdlib-roots
        decl-path)]))

(define (compiler-load-package-owned-paths-for-decls-in-module
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : StringVec]
  [entry-path : String]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [module : String]) : AstDeclPathList
  (match decls
    [(AstDeclNil) AstDeclPathNil]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        [decl-path : String (compiler-load-path-list-head-or paths entry-path)]
        [rest-paths : AstDeclPathList (compiler-load-path-list-tail paths)]
        [next-module : String
          (match decl
            [(AstDeclModule name) (intern-str name)]
            [_ module])]
        (ast-decl-path-cons
          (compiler-load-package-owned-decl-path
            package-owner
            package-root
            stdlib-roots
            entry-path
            module
            decl-path
            decl)
          (compiler-load-package-owned-paths-for-decls-in-module
            package-owner
            package-root
            stdlib-roots
            entry-path
            rest
            rest-paths
            next-module)))]))

(define (compiler-load-package-owned-paths-for-decls
  [package-owner : String]
  [package-root : String]
  [stdlib-roots : StringVec]
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
  [stdlib-roots : StringVec]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [seen : SymI64Env]
  [module : String]) : ResultCompilerLoadWithPaths
  (match decls
    [(AstDeclNil)
      (OkCompilerLoadWithPaths AstDeclNil AstDeclPathNil AstDeclModuleNil seen)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
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
            [(AstDeclModule name) (intern-str name)]
            [_ module])]
        (match (compiler-load-package-extern-decls
          package-owner
          package-root
          stdlib-roots
          rest
          rest-paths
          seen
          next-module)
          [(OkCompilerLoadWithPaths
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
                (OkCompilerLoadWithPaths
                  (ast-decl-cons transformed rest-decls)
                  (ast-decl-path-cons owned-decl-path rest-decl-paths)
                  (ast-decl-module-cons module rest-modules)
                  rest-seen)]
              [(CompilerLoadNoDecl)
                (OkCompilerLoadWithPaths
                  rest-decls
                  rest-decl-paths
                  rest-modules
                  rest-seen)])]
          [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)]))]))

(define (compiler-load-package-entry-for-source [source-path : String]) : ResultCompilerLoadPackageEntry
  (match (compiler-load-discover-manifest source-path)
    [(CompilerLoadNoPath)
      (ErrCompilerLoadPackageEntry
        (string-append
          "compiler-load: dependency package manifest not found for "
          source-path))]
    [(CompilerLoadSomePath manifest-path)
      (match (compiler-load-parse-manifest-diagnostic-infer-kind
        manifest-path
        (read-file manifest-path))
        [(ErrCompilerPkgManifestDiagnostic diag)
          (ErrCompilerLoadPackageEntry
            (string-append
              "compiler-load: invalid dependency package manifest '"
              (string-append
                manifest-path
                (string-append "': " (compiler-diagnostic-message diag)))))]
        [(OkCompilerPkgManifestDiagnostic manifest)
          (let
            [manifest-dir : String (compiler-load-dirname manifest-path)]
            (OkCompilerLoadPackageEntry
              (CompilerLoadPackageEntry
                (compiler-load-normalize-path
                  (compiler-load-join-root-path
                    manifest-dir
                    (struct-get manifest entry)))
                manifest-dir
                (struct-get manifest name))))])]))

(define (compiler-load-package-externs-from-import
  [resolved : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [expected-module : AstMaybeModuleName]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (match (compiler-load-package-entry-for-source resolved)
    [(ErrCompilerLoadPackageEntry message)
      (ErrCompilerLoadWithPaths (compiler-diagnostic-at-start resolved message))]
    [(OkCompilerLoadPackageEntry entry)
      (match (compiler-load-file-with-paths-and-roots-expect-cfg
        resolved
        seen
        stdlib-roots
        expected-module
        cfgs)
        [(OkCompilerLoadWithPaths imported-decls imported-paths _ import-seen)
          (compiler-load-package-extern-decls
            (struct-get entry owner)
            (struct-get entry manifest-dir)
            stdlib-roots
            imported-decls
            imported-paths
            import-seen
            "")]
        [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]))

(define (compiler-load-package-expand-include-str
  [importer-path : String]
  [include-path : String]
  [name : String]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerLoadInclude
  (match (if (compiler-load-pkg-import? include-path)
    (compiler-load-resolve-pkg-import include-path manifest-dir deps)
    (compiler-load-resolve-import-result-with-roots
      importer-path
      include-path
      stdlib-roots))
    [(OkPkgResolve resolved)
      (compiler-load-include-str-from-resolved
        importer-path
        include-path
        resolved
        name)]
    [(ErrPkgResolve message)
      (ErrCompilerLoadInclude
        (compiler-diagnostic-at-start importer-path message))]))

(define (compiler-load-package-expand-include-bin
  [importer-path : String]
  [include-path : String]
  [name : String]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerLoadInclude
  (match (if (compiler-load-pkg-import? include-path)
    (compiler-load-resolve-pkg-import include-path manifest-dir deps)
    (compiler-load-resolve-import-result-with-roots
      importer-path
      include-path
      stdlib-roots))
    [(OkPkgResolve resolved)
      (compiler-load-include-bin-from-resolved
        importer-path
        include-path
        resolved
        name)]
    [(ErrPkgResolve message)
      (ErrCompilerLoadInclude
        (compiler-diagnostic-at-start importer-path message))]))

(define (compiler-load-package-decls-with-module-and-roots
  [decls : AstDeclList]
  [importer-path : String]
  [importer-module : String]
  [importer-source-module : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (match decls
    [(AstDeclNil)
      (OkCompilerLoadWithPaths AstDeclNil AstDeclPathNil AstDeclModuleNil seen)]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport
              (AstImportSpec kind import-path expected-module alias _))
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
                [(OkCompilerLoadWithPaths
                    rest-decls
                    rest-paths
                    rest-modules
                    rest-seen)
                  (OkCompilerLoadWithPaths
                    (ast-decl-cons decl rest-decls)
                    (ast-decl-path-cons importer-path rest-paths)
                    (ast-decl-module-cons importer-module rest-modules)
                    rest-seen)]
                [(ErrCompilerLoadWithPaths diag)
                  (ErrCompilerLoadWithPaths diag)])
              (match (compiler-load-resolve-package-import-spec
                importer-path
                kind
                import-path
                stdlib-roots
                manifest-dir
                deps)
                [(OkPkgResolve resolved)
                  (match (if (compiler-load-package-import-externs?
                    kind
                    import-path
                    deps)
                    (compiler-load-package-externs-from-import
                      resolved
                      seen
                      stdlib-roots
                      expected-module
                      cfgs)
                    (compiler-load-package-file-with-paths-and-roots-expect
                      resolved
                      seen
                      stdlib-roots
                      expected-module
                      manifest-dir
                      deps
                      cfgs))
                    [(OkCompilerLoadWithPaths
                        imported-decls
                        imported-paths
                        imported-modules
                        import-seen)
                      (match (compiler-load-package-decls-with-module-and-roots
                        rest
                        importer-path
                        importer-module
                        importer-source-module
                        import-seen
                        stdlib-roots
                        manifest-dir
                        deps
                        cfgs)
                        [(OkCompilerLoadWithPaths
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
                            (OkCompilerLoadWithPaths
                              (compiler-load-decl-list-append
                                imported-decls
                                (compiler-load-decls-after-import
                                  kind
                                  resolved
                                  after-import-expected
                                  after-import-alias
                                  importer-source-module
                                  imported-decls
                                  rest-decls))
                              (compiler-load-decl-path-list-append
                                imported-paths
                                (compiler-load-paths-after-import
                                  importer-path
                                  after-import-alias
                                  imported-decls
                                  rest-paths))
                              (compiler-load-decl-module-list-append
                                imported-modules
                                (compiler-load-modules-after-import
                                  importer-module
                                  after-import-alias
                                  imported-decls
                                  rest-modules))
                              rest-seen))]
                        [(ErrCompilerLoadWithPaths diag)
                          (ErrCompilerLoadWithPaths diag)])]
                    [(ErrCompilerLoadWithPaths diag)
                      (ErrCompilerLoadWithPaths diag)])]
                [(ErrPkgResolve message)
                  (ErrCompilerLoadWithPaths
                    (compiler-diagnostic-at-start importer-path message))]))]
          [(AstDeclIncludeStr name include-path)
            (match (compiler-load-package-expand-include-str
              importer-path
              include-path
              name
              stdlib-roots
              manifest-dir
              deps)
              [(OkCompilerLoadInclude expanded)
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
                  [(OkCompilerLoadWithPaths
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (OkCompilerLoadWithPaths
                      (ast-decl-cons expanded rest-decls)
                      (ast-decl-path-cons importer-path rest-paths)
                      (ast-decl-module-cons importer-module rest-modules)
                      rest-seen)]
                  [(ErrCompilerLoadWithPaths diag)
                    (ErrCompilerLoadWithPaths diag)])]
              [(ErrCompilerLoadInclude diag) (ErrCompilerLoadWithPaths diag)])]
          [(AstDeclIncludeBin name include-path)
            (match (compiler-load-package-expand-include-bin
              importer-path
              include-path
              name
              stdlib-roots
              manifest-dir
              deps)
              [(OkCompilerLoadInclude expanded)
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
                  [(OkCompilerLoadWithPaths
                      rest-decls
                      rest-paths
                      rest-modules
                      rest-seen)
                    (OkCompilerLoadWithPaths
                      (ast-decl-cons expanded rest-decls)
                      (ast-decl-path-cons importer-path rest-paths)
                      (ast-decl-module-cons importer-module rest-modules)
                      rest-seen)]
                  [(ErrCompilerLoadWithPaths diag)
                    (ErrCompilerLoadWithPaths diag)])]
              [(ErrCompilerLoadInclude diag) (ErrCompilerLoadWithPaths diag)])]
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
              [(OkCompilerLoadWithPaths
                  rest-decls
                  rest-paths
                  rest-modules
                  rest-seen)
                (OkCompilerLoadWithPaths
                  (ast-decl-cons decl rest-decls)
                  (ast-decl-path-cons importer-path rest-paths)
                  (ast-decl-module-cons importer-module rest-modules)
                  rest-seen)]
              [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]))]))

(define (compiler-load-package-program-with-paths-and-roots-expect
  [path : String]
  [program : AstProgram]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [expected-module : AstMaybeModuleName]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (match program
    [(AstProgram decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        [source-module : String (compiler-load-decls-source-module decls)]
        (match (compiler-load-decls-module-id path decls)
          [(OkCompilerLoadModuleId module-id)
            (match (compiler-load-check-expected-module
              path
              expected-module
              module-id)
              [(OkCompilerLoadModuleId _)
                (if (sym-i64-contains seen module-id)
                  (compiler-load-seen-module-with-paths
                    path
                    module-id
                    decls
                    seen)
                  (match (compiler-load-check-dotted-import-aliases
                    path
                    decls
                    source-module)
                    [(OkCompilerLoadAliasCheck)
                      (compiler-load-package-decls-with-module-and-roots
                        decls
                        path
                        module-id
                        source-module
                        (sym-i64-bind seen module-id 1)
                        stdlib-roots
                        manifest-dir
                        deps
                        cfgs)]
                    [(ErrCompilerLoadAliasCheck diag)
                      (ErrCompilerLoadWithPaths diag)]))]
              [(ErrCompilerLoadModuleId diag) (ErrCompilerLoadWithPaths diag)])]
          [(ErrCompilerLoadModuleId diag) (ErrCompilerLoadWithPaths diag)]))]))

(define (compiler-load-package-file-with-paths-and-roots-expect-cache-current
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [expected-module : AstMaybeModuleName]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : SymI64Env]
  [cache-current : bool]) : ResultCompilerLoadWithPaths
  (if (file-exists? path)
    (match (if cache-current
      (compiler-load-parse-file-diagnostic-session path stdlib-roots cfgs)
      (compiler-load-parse-file-diagnostic-escaping path cfgs))
      [(OkAstProgramDiagnostic program)
        (compiler-load-package-program-with-paths-and-roots-expect
          path
          program
          seen
          stdlib-roots
          expected-module
          manifest-dir
          deps
          cfgs)]
      [(ErrAstProgramDiagnostic diag) (ErrCompilerLoadWithPaths diag)])
    (match (compiler-load-embedded-stdlib-source-for-path path)
      [(CompilerEmbeddedStdlibSomeSource source)
        (match (if cache-current
          (compiler-load-parse-embedded-source-diagnostic-session
            path
            source
            cfgs)
          (compiler-load-parse-source-diagnostic-escaping path source cfgs))
          [(OkAstProgramDiagnostic program)
            (compiler-load-package-program-with-paths-and-roots-expect
              path
              program
              seen
              stdlib-roots
              expected-module
              manifest-dir
              deps
              cfgs)]
          [(ErrAstProgramDiagnostic diag) (ErrCompilerLoadWithPaths diag)])]
      [(CompilerEmbeddedStdlibNoSource)
        (ErrCompilerLoadWithPaths
          (compiler-diagnostic-at-start
            path
            (string-append "compiler-load: cannot read import " path)))])))

(define (compiler-load-package-file-with-paths-and-roots-expect
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [expected-module : AstMaybeModuleName]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
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
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultCompilerLoadWithPaths
  (compiler-load-package-file-with-paths-and-roots-expect
    path
    seen
    stdlib-roots
    AstNoModuleName
    manifest-dir
    deps
    (compiler-cfg-empty)))

(define (compiler-load-package-file-with-paths-and-roots-cfg
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-package-file-with-paths-and-roots-expect
    path
    seen
    stdlib-roots
    AstNoModuleName
    manifest-dir
    deps
    cfgs))

(define (compiler-load-package-entry-file-with-paths-and-roots-cfg
  [path : String]
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (compiler-load-package-file-with-paths-and-roots-expect-cache-current
    path
    seen
    stdlib-roots
    AstNoModuleName
    manifest-dir
    deps
    cfgs
    false))

(define (compiler-load-package-core-macro-prelude-with-roots-cfg
  [seen : SymI64Env]
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
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
  [stdlib-roots : StringVec]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]
  [emit-entry : bool]
  [cfgs : SymI64Env]) : ResultCompilerLoadWithPaths
  (if emit-entry
    (match (compiler-load-package-file-with-paths-and-roots-cfg
      "stdlib/runtime.tl"
      (sym-i64-empty)
      stdlib-roots
      manifest-dir
      deps
      cfgs)
      [(OkCompilerLoadWithPaths
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
          [(OkCompilerLoadWithPaths
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
              [(OkCompilerLoadWithPaths
                  entry-decls
                  entry-paths
                  entry-modules
                  seen)
                (OkCompilerLoadWithPaths
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
              [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]
          [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]
      [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])
    (match (compiler-load-package-core-macro-prelude-with-roots-cfg
      (sym-i64-empty)
      stdlib-roots
      manifest-dir
      deps
      cfgs)
      [(OkCompilerLoadWithPaths
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
          [(OkCompilerLoadWithPaths entry-decls entry-paths entry-modules seen)
            (OkCompilerLoadWithPaths
              (compiler-load-decl-list-append prelude-decls entry-decls)
              (compiler-load-decl-path-list-append prelude-paths entry-paths)
              (compiler-load-decl-module-list-append
                prelude-modules
                entry-modules)
              seen)]
          [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])]
      [(ErrCompilerLoadWithPaths diag) (ErrCompilerLoadWithPaths diag)])))

(define (compiler-load-decl-list-count [decls : AstDeclList]) : i64
  (match decls
    [(AstDeclNil) 0]
    [(AstDeclCons _ rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (+ 1 (compiler-load-decl-list-count rest)))]))

(define (compiler-load-first-string-def?
  [decls : AstDeclList]
  [name : String]
  [want : String]) : bool
  (match decls
    [(AstDeclCons (AstDeclDef got (AstSomeType (AstTyString)) value-box) _)
      (let
        [value : AstExpr (ast-node-get value-box)]
        (match value
          [(AstExprLiteral (AstLitString text))
            (and (string-eq (intern-str got) name) (string-eq text want))]
          [_ false]))]
    [_ false]))

(define (compiler-load-binary-payload-ok? [text : String]) : bool
  (and
    (= (string-length text) 6)
    (= (compiler-load-char-code-at text 0) 0)
    (= (compiler-load-char-code-at text 1) 65)
    (= (compiler-load-char-code-at text 2) 127)
    (= (compiler-load-char-code-at text 3) 128)
    (= (compiler-load-char-code-at text 4) 255)
    (= (compiler-load-char-code-at text 5) 10)))

(define (compiler-load-first-bin-def? [decls : AstDeclList] [name : String]) : bool
  (match decls
    [(AstDeclCons
        (AstDeclDef got (AstSomeType (AstTyDynArray elem-id)) value-box)
        _)
      (let
        [value : AstExpr (ast-node-get value-box)]
        [elem : AstType (ty-node-get elem-id)]
        (match value
          [(AstExprBinaryData text)
            (and
              (string-eq (intern-str got) name)
              (match elem
                [(AstTyU8) true]
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
  (match decls
    [(AstDeclNil) false]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclImport
              (AstImportSpec
                _
                _
                (AstSomeModuleName module-name)
                (AstSomeImportAlias alias)
                _))
            (if (and
              (string-eq module-name target-module)
              (string-eq alias target-alias))
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
  (match decls
    [(AstDeclCons (AstDeclModule imported-module) rest1)
      (let
        [rest1 : AstDeclList (box-get rest1)]
        (match rest1
          [(AstDeclCons (AstDeclDef imported-name _ _) rest2)
            (let
              [rest2 : AstDeclList (box-get rest2)]
              (match rest2
                [(AstDeclCons (AstDeclModule restored-module) rest3)
                  (let
                    [rest3 : AstDeclList (box-get rest3)]
                    (match rest3
                      [(AstDeclCons
                          (AstDeclImport
                            (AstImportSpec
                              _
                              _
                              (AstSomeModuleName alias-module)
                              (AstSomeImportAlias alias-name)
                              _))
                          rest4)
                        (let
                          [rest4 : AstDeclList (box-get rest4)]
                          (match rest4
                            [(AstDeclCons
                                (AstDeclDefFn main-name _ _ _ _)
                                AstDeclNil)
                              (and
                                (string-eq
                                  (intern-str imported-module)
                                  "restore.dep")
                                (string-eq
                                  (intern-str imported-name)
                                  "dep-value")
                                (string-eq (intern-str restored-module) "")
                                (string-eq alias-module "restore.dep")
                                (string-eq alias-name "dep")
                                (string-eq (intern-str main-name) "main"))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (compiler-load-two-modules?
  [modules : AstDeclModuleList]
  [want : String]) : bool
  (match modules
    [(AstDeclModuleCons first tail)
      (let
        [tail : AstDeclModuleList (box-get tail)]
        (match tail
          [(AstDeclModuleCons second rest)
            (let
              [rest : AstDeclModuleList (box-get rest)]
              (match rest
                [(AstDeclModuleNil)
                  (and (string-eq first want) (string-eq second want))]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (compiler-load-entry-cycle-module-name? [name : String]) : bool
  (or (string-eq name "smoke.entry") (string-eq name "smoke.dep")))

(define (compiler-load-entry-cycle-modules-loop
  [modules : AstDeclModuleList]
  [count : i64]) : bool
  (match modules
    [(AstDeclModuleNil) (= count 11)]
    [(AstDeclModuleCons first tail)
      (and
        (compiler-load-entry-cycle-module-name? first)
        (compiler-load-entry-cycle-modules-loop (box-get tail) (+ count 1)))]))

(define (compiler-load-entry-cycle-modules? [modules : AstDeclModuleList]) : bool
  (compiler-load-entry-cycle-modules-loop modules 0))

(define (compiler-load-normalize-ok?) : bool
  (and
    (string-eq
      (compiler-load-normalize-path "selfhost/./x/../compiler_load.tl")
      "selfhost/compiler_load.tl")
    (string-eq
      (compiler-load-normalize-path "target\\loader\\..\\dep.tl")
      "target/dep.tl")))

(define (compiler-load-source-provenance-ok?) : bool
  (match (compiler-load-source-with-paths
    "src/./main.tl"
    "(module app.main)
(define answer : i64 42)"
    (sym-i64-empty))
    [(OkCompilerLoadWithPaths decls _ modules seen)
      (and
        (= (compiler-load-decl-list-count decls) 2)
        (compiler-load-two-modules? modules "app.main")
        (sym-i64-contains seen "app.main"))]
    [(ErrCompilerLoadWithPaths _) false]))

(define (compiler-load-expected-module-conflict-ok?) : bool
  (match (compiler-load-source-with-paths-and-roots-expect
    "src/lib.tl"
    "(module lib.actual)
(define value : i64 1)"
    (sym-i64-empty)
    (string-vec-new)
    (AstSomeModuleName "lib.want"))
    [(ErrCompilerLoadWithPaths diag)
      (string-eq
        (compiler-diagnostic-message diag)
        "compiler-load: import expected module lib.want but loaded lib.actual")]
    [(OkCompilerLoadWithPaths _ _ _ _) false]))

(define (compiler-load-duplicate-module-ok?) : bool
  (match (compiler-load-source
    "src/dup.tl"
    "(module dup.one)
(module dup.two)
(define value : i64 1)"
    (sym-i64-empty))
    [(ErrCompilerLoad diag)
      (string-eq
        (compiler-diagnostic-message diag)
        "compiler-load: duplicate module declaration")]
    [(OkCompilerLoad _ _) false]))

(define (compiler-load-seen-module-ok?) : bool
  (match (compiler-load-source
    "src/other.tl"
    "(module seen.module)
(define value : i64 1)"
    (sym-i64-bind (sym-i64-empty) "seen.module" 1))
    [(OkCompilerLoad decls _) (compiler-load-decl-list-has-module? decls)]
    [(ErrCompilerLoad _) false]))

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
    [feature-cfg : SymI64Env
      (compiler-cfg-enable (compiler-cfg-empty) "feature")]
    (and
      (match (compiler-load-source-with-paths-and-roots-cfg
        "src/main.tl"
        source
        (sym-i64-empty)
        (string-vec-new)
        (compiler-cfg-empty))
        [(OkCompilerLoadWithPaths decls _ _ _)
          (= (compiler-load-decl-list-count decls) 2)]
        [(ErrCompilerLoadWithPaths _) false])
      (match (compiler-load-source-with-paths-and-roots-cfg
        "src/main.tl"
        enabled-source
        (sym-i64-empty)
        (string-vec-new)
        feature-cfg)
        [(ErrCompilerLoadWithPaths _) true]
        [(OkCompilerLoadWithPaths _ _ _ _) false]))))

(define (compiler-load-file-import-dedup-cycle-ok?) : bool
  (begin
    (write-file
      "target/compiler_load_dep.tl"
      "(module smoke.dep)
(import \"compiler_load_entry.tl\" module smoke.entry as entry)
(define dep : i64 1)")
    (write-file
      "target/compiler_load_entry.tl"
      "(module smoke.entry)
(import \"compiler_load_dep.tl\" module smoke.dep as dep)
(import \"./compiler_load_dep.tl\" module smoke.dep)
(define (main) : i64 dep)")
    (match (compiler-load-file-with-paths
      "target/compiler_load_entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ modules seen)
        (and
          (= (compiler-load-decl-list-count decls) 11)
          (compiler-load-entry-cycle-modules? modules)
          (sym-i64-contains seen "smoke.entry")
          (sym-i64-contains seen "smoke.dep"))]
      [(ErrCompilerLoadWithPaths _) false])))

(define (compiler-load-import-module-restore-ok?) : bool
  (begin
    (write-file
      "target/cl_restore_dep.tl"
      "(module restore.dep)
(define dep-value : i64 1)")
    (write-file
      "target/cl_restore_entry.tl"
      "(import \"cl_restore_dep.tl\" module restore.dep as dep)
(define (main) : i64 42)")
    (match (compiler-load-file-with-paths
      "target/cl_restore_entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ _ _)
        (compiler-load-unmoduled-import-restored-decls? decls)]
      [(ErrCompilerLoadWithPaths _) false])))

(define (compiler-load-file-fallback-path-dedup-ok?) : bool
  (begin
    (write-file
      "target/compiler_load_legacy_dep.tl"
      "(define legacy-dep : i64 1)")
    (write-file
      "target/compiler_load_legacy_entry.tl"
      "(import \"compiler_load_legacy_dep.tl\")
(import \"./compiler_load_legacy_dep.tl\")
(define (main) : i64 legacy-dep)")
    (match (compiler-load-file-with-paths
      "target/compiler_load_legacy_entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ modules seen)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (match modules
            [(AstDeclModuleCons first tail-box)
              (let
                [tail : AstDeclModuleList (box-get tail-box)]
                (match tail
                  [(AstDeclModuleCons second rest-box)
                    (let
                      [rest : AstDeclModuleList (box-get rest-box)]
                      (match rest
                        [(AstDeclModuleNil)
                          (and
                            (string-eq
                              first
                              "target/compiler_load_legacy_dep.tl")
                            (string-eq
                              second
                              "target/compiler_load_legacy_entry.tl"))]
                        [_ false]))]
                  [_ false]))]
            [_ false])
          (sym-i64-contains seen "target/compiler_load_legacy_dep.tl"))]
      [(ErrCompilerLoadWithPaths _) false])))

(define (compiler-load-import-alias-preserved-ok?) : bool
  (begin
    (write-file
      "target/cl_alias_dep.tl"
      "(module alias.dep)
(define (get) : i64 7)")
    (write-file
      "target/cl_alias_entry.tl"
      "(import \"cl_alias_dep.tl\" module alias.dep :as dep)
(module alias.entry)
(define (main) : i64 (dep.get))")
    (match (compiler-load-file-with-paths
      "target/cl_alias_entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ _ _)
        (compiler-load-decl-list-has-import-alias? decls "alias.dep" "dep")]
      [(ErrCompilerLoadWithPaths _) false])))

(define (compiler-load-legacy-path-module-flat-alias-ok?) : bool
  (begin
    (write-file
      "target/cl_legacy_module_dep.tl"
      "(module legacy.dep)
(define (get) : i64 7)")
    (write-file
      "target/cl_legacy_module_entry.tl"
      "(import \"cl_legacy_module_dep.tl\")
(define (main) : i64 (get))")
    (match (compiler-load-file-with-paths
      "target/cl_legacy_module_entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ _ _)
        (compiler-load-decl-list-has-import-alias? decls "legacy.dep" "")]
      [(ErrCompilerLoadWithPaths _) false])))

(define (compiler-load-seen-legacy-path-module-flat-alias-ok?) : bool
  (begin
    (write-file
      "target/cl_seen_legacy_module_dep.tl"
      "(module seen.legacy.dep)
(define (get) : i64 7)")
    (write-file
      "target/cl_seen_legacy_module_pre.tl"
      "(import \"cl_seen_legacy_module_dep.tl\" module seen.legacy.dep :as dep)
(define (pre) : i64 (dep.get))")
    (write-file
      "target/cl_seen_legacy_module_entry.tl"
      "(import \"cl_seen_legacy_module_pre.tl\")
(import \"cl_seen_legacy_module_dep.tl\")
(define (main) : i64 (get))")
    (match (compiler-load-file-with-paths
      "target/cl_seen_legacy_module_entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ _ _)
        (compiler-load-decl-list-has-import-alias? decls "seen.legacy.dep" "")]
      [(ErrCompilerLoadWithPaths _) false])))

(define (compiler-load-package-legacy-path-module-flat-alias-ok?) : bool
  (begin
    (write-file
      "target/cl_pkg_legacy_module_dep.tl"
      "(module legacy.pkg.dep)
(define (get) : i64 7)")
    (write-file
      "target/cl_pkg_legacy_module_entry.tl"
      "(import \"cl_pkg_legacy_module_dep.tl\")
(define (main) : i64 (get))")
    (match (compiler-load-package-file-with-paths-and-roots
      "target/cl_pkg_legacy_module_entry.tl"
      (sym-i64-empty)
      (string-vec-new)
      "target"
      (compiler-pkg-deps-empty))
      [(OkCompilerLoadWithPaths decls _ _ _)
        (compiler-load-decl-list-has-import-alias? decls "legacy.pkg.dep" "")]
      [(ErrCompilerLoadWithPaths _) false])))

(define (compiler-load-package-seen-legacy-path-module-flat-alias-ok?) : bool
  (begin
    (write-file
      "target/cl_pkg_seen_legacy_module_dep.tl"
      "(module seen.legacy.pkg.dep)
(define (get) : i64 7)")
    (write-file
      "target/cl_pkg_seen_legacy_module_pre.tl"
      "(import \"cl_pkg_seen_legacy_module_dep.tl\" module seen.legacy.pkg.dep :as dep)
(define (pre) : i64 (dep.get))")
    (write-file
      "target/cl_pkg_seen_legacy_module_entry.tl"
      "(import \"cl_pkg_seen_legacy_module_pre.tl\")
(import \"cl_pkg_seen_legacy_module_dep.tl\")
(define (main) : i64 (get))")
    (match (compiler-load-package-file-with-paths-and-roots
      "target/cl_pkg_seen_legacy_module_entry.tl"
      (sym-i64-empty)
      (string-vec-new)
      "target"
      (compiler-pkg-deps-empty))
      [(OkCompilerLoadWithPaths decls _ _ _)
        (compiler-load-decl-list-has-import-alias?
          decls
          "seen.legacy.pkg.dep"
          "")]
      [(ErrCompilerLoadWithPaths _) false])))

(define (compiler-load-dotted-import-duplicate-alias-ok?) : bool
  (match (compiler-load-source
    "src/dup_alias.tl"
    "(module alias.entry)
(import pkg.one)
(import other.one)
(define (main) : i64 0)"
    (sym-i64-empty))
    [(ErrCompilerLoad diag)
      (string-eq
        (compiler-diagnostic-message diag)
        "compiler-load: duplicate module import alias one")]
    [(OkCompilerLoad _ _) false]))

(define (compiler-load-dotted-import-resolution-ok?) : bool
  (and
    (string-eq
      (compiler-load-dotted-module-path "stdlib.core_macros")
      "stdlib/core_macros.tl")
    (match (compiler-load-resolve-module-import-with-roots
      "src/"
      "app.lib"
      (string-vec-new))
      [(OkPkgResolve path) (string-eq path "src/app/lib.tl")]
      [(ErrPkgResolve _) false])
    (match (compiler-load-resolve-module-import-with-roots
      "src/"
      "stdlib.core_macros"
      (string-vec-new))
      [(OkPkgResolve path) (string-eq path "stdlib/core_macros.tl")]
      [(ErrPkgResolve _) false])))

(define (compiler-load-test-mkdir-direct [path : String]) : bool
  (match (try-mkdir-if-missing (& path))
    [(OkIoUnit) true]
    [(ErrIoUnit _) false]))

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
    [roots : StringVec (string-vec-push (string-vec-new) root)]
    (begin
      (compiler-load-test-mkdir root)
      (write-file dep-file "(module cache.dep)
(define dep-value : i64 1)")
      (write-file
        "target/cl_cache_entry_a.tl"
        "(module cache.entry.a)
(import \"stdlib/cache_dep.tl\" module cache.dep as dep)
(define entry-a : i64 1)")
      (write-file
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
            (sym-i64-empty)
            roots)
            [(OkCompilerLoadWithPaths _ _ _ _) true]
            [(ErrCompilerLoadWithPaths _) false])
            (begin
              (compiler-load-session-reset-pools!)
              (compiler-load-session-reset-interns!)
              (match (compiler-load-file-with-paths-and-roots
                "target/cl_cache_entry_b.tl"
                (sym-i64-empty)
                roots)
                [(OkCompilerLoadWithPaths _ _ _ _)
                  (begin
                    (set!
                      ok
                      (and
                        (> (compiler-load-program-cache-hit-count-value) 0)
                        (>= (compiler-load-program-cache-store-count-value) 1))))]
                [(ErrCompilerLoadWithPaths _) (set! ok false)]))
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
    [roots-a : StringVec (string-vec-push (string-vec-new) root-a)]
    [roots-b : StringVec (string-vec-push (string-vec-new) root-b)]
    (begin
      (compiler-load-test-mkdir root-a)
      (compiler-load-test-mkdir root-b)
      (write-file
        root-a-file
        "(module cache.root.a)
(define root-value : i64 1)")
      (write-file
        root-b-file
        "(module cache.root.b)
(define root-value : i64 2)")
      (write-file
        "target/cl_cache_root_entry_a.tl"
        "(module cache.root.entry.a)
(import \"stdlib/cache_root_dep.tl\" module cache.root.a as dep)
(define entry-a : i64 1)")
      (write-file
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
            (sym-i64-empty)
            roots-a)
            [(OkCompilerLoadWithPaths _ _ _ _) true]
            [(ErrCompilerLoadWithPaths _) false])
            (begin
              (compiler-load-session-reset-pools!)
              (compiler-load-session-reset-interns!)
              (match (compiler-load-file-with-paths-and-roots
                "target/cl_cache_root_entry_b.tl"
                (sym-i64-empty)
                roots-b)
                [(OkCompilerLoadWithPaths _ _ _ _) (set! ok true)]
                [(ErrCompilerLoadWithPaths _) (set! ok false)]))
            (set! ok false))
          (compiler-load-session-cache-disable-for-test!)
          ok)))))

(define (compiler-load-session-cache-entry-cold-ok?) : bool
  (begin
    (write-file
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
          (sym-i64-empty)
          (string-vec-new)
          (compiler-cfg-empty))
          [(OkCompilerLoadWithPaths _ _ _ _) true]
          [(ErrCompilerLoadWithPaths _) false])
          (begin
            (compiler-load-session-reset-pools!)
            (compiler-load-session-reset-interns!)
            (match (compiler-load-entry-file-with-paths-and-roots-cfg
              "target/cl_cache_cold_entry.tl"
              (sym-i64-empty)
              (string-vec-new)
              (compiler-cfg-empty))
              [(OkCompilerLoadWithPaths _ _ _ _)
                (set!
                  ok
                  (and
                    (= (compiler-load-program-cache-hit-count-value) 0)
                    (= (compiler-load-program-cache-store-count-value) 0)))]
              [(ErrCompilerLoadWithPaths _) (set! ok false)]))
          (set! ok false))
        (compiler-load-session-cache-disable-for-test!)
        ok))))

(define (compiler-load-session-cache-local-common-dep-ok?) : bool
  (let
    [dir : String "target/cl_cache_local"]
    [dep : String (compiler-load-join-root-path dir "dep.tl")]
    [entry-a : String (compiler-load-join-root-path dir "entry_a.tl")]
    [entry-b : String (compiler-load-join-root-path dir "entry_b.tl")]
    [entry-c : String (compiler-load-join-root-path dir "entry_c.tl")]
    (begin
      (compiler-load-test-mkdir dir)
      (write-file dep "(module cache.local.dep)
(define dep-value : i64 1)")
      (write-file
        entry-a
        "(module cache.local.entry.a)
(import \"dep.tl\" module cache.local.dep as dep)
(define entry-a : i64 1)")
      (write-file
        entry-b
        "(module cache.local.entry.b)
(import \"dep.tl\" module cache.local.dep as dep)
(define entry-b : i64 2)")
      (write-file
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
            (sym-i64-empty)
            (string-vec-new)
            (compiler-cfg-empty))
            [(OkCompilerLoadWithPaths _ _ _ _) true]
            [(ErrCompilerLoadWithPaths _) false])
            (begin
              (compiler-load-session-reset-pools!)
              (compiler-load-session-reset-interns!)
              (match (compiler-load-entry-file-with-paths-and-roots-cfg
                entry-b
                (sym-i64-empty)
                (string-vec-new)
                (compiler-cfg-empty))
                [(OkCompilerLoadWithPaths _ _ _ _)
                  (begin
                    (compiler-load-session-reset-pools!)
                    (compiler-load-session-reset-interns!)
                    (match (compiler-load-entry-file-with-paths-and-roots-cfg
                      entry-c
                      (sym-i64-empty)
                      (string-vec-new)
                      (compiler-cfg-empty))
                      [(OkCompilerLoadWithPaths _ _ _ _)
                        (set!
                          ok
                          (and
                            (> (compiler-load-program-cache-hit-count-value) 0)
                            (>=
                              (compiler-load-program-cache-store-count-value)
                              1)))]
                      [(ErrCompilerLoadWithPaths _) (set! ok false)]))]
                [(ErrCompilerLoadWithPaths _) (set! ok false)]))
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
      (write-file dep "(module cache.pkg.common)
(define common-value : i64 1)")
      (write-file
        entry-a
        "(module cache.pkg.entry.a)
(import \"common.tl\" module cache.pkg.common as common)
(define entry-a : i64 1)")
      (write-file
        entry-b
        "(module cache.pkg.entry.b)
(import \"common.tl\" module cache.pkg.common as common)
(define entry-b : i64 2)")
      (write-file
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
            (sym-i64-empty)
            (string-vec-new)
            root
            deps
            (compiler-cfg-empty))
            [(OkCompilerLoadWithPaths _ _ _ _) true]
            [(ErrCompilerLoadWithPaths _) false])
            (begin
              (compiler-load-session-reset-pools!)
              (compiler-load-session-reset-interns!)
              (match (compiler-load-package-entry-file-with-paths-and-roots-cfg
                entry-b
                (sym-i64-empty)
                (string-vec-new)
                root
                deps
                (compiler-cfg-empty))
                [(OkCompilerLoadWithPaths _ _ _ _)
                  (begin
                    (compiler-load-session-reset-pools!)
                    (compiler-load-session-reset-interns!)
                    (match (compiler-load-package-entry-file-with-paths-and-roots-cfg
                      entry-c
                      (sym-i64-empty)
                      (string-vec-new)
                      root
                      deps
                      (compiler-cfg-empty))
                      [(OkCompilerLoadWithPaths _ _ _ _)
                        (set!
                          ok
                          (and
                            (> (compiler-load-program-cache-hit-count-value) 0)
                            (>=
                              (compiler-load-program-cache-store-count-value)
                              1)))]
                      [(ErrCompilerLoadWithPaths _) (set! ok false)]))]
                [(ErrCompilerLoadWithPaths _) (set! ok false)]))
            (set! ok false))
          (compiler-load-session-cache-disable-for-test!)
          ok)))))

(define (compiler-load-dotted-source-root-ok?) : bool
  (begin
    (compiler-load-test-mkdir "target/cl_dotted_src")
    (compiler-load-test-mkdir "target/cl_dotted_src/nested")
    (write-file
      "target/cl_dotted_src/root_leaf.tl"
      "(module root_leaf)
(define leaf-val : i64 1)")
    (write-file
      "target/cl_dotted_src/nested/dep.tl"
      "(module nested.dep)
(import root_leaf as leaf)
(define dep-val : i64 leaf-val)")
    (write-file
      "target/cl_dotted_src/entry.tl"
      "(module dotted.entry)
(import nested.dep as dep)
(define (main) : i64 dep-val)")
    (match (compiler-load-file-with-paths
      "target/cl_dotted_src/entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths _ _ _ seen)
        (and
          (sym-i64-contains seen "dotted.entry")
          (sym-i64-contains seen "nested.dep")
          (sym-i64-contains seen "root_leaf"))]
      [(ErrCompilerLoadWithPaths _) false])))

(define (compiler-load-package-dotted-import-resolution-ok?) : bool
  (let
    [deps : CompilerPkgDeps (compiler-load-pkg-resolve-deps)]
    (and
      (match (compiler-load-resolve-package-import-spec
        "proj/src/main.tl"
        (AstImportModule)
        "app.lib"
        (string-vec-new)
        "proj"
        deps)
        [(OkPkgResolve path) (string-eq path "proj/app/lib.tl")]
        [(ErrPkgResolve _) false])
      (match (compiler-load-resolve-package-import-spec
        "proj/src/main.tl"
        (AstImportModule)
        "math.src.add"
        (string-vec-new)
        "proj"
        deps)
        [(OkPkgResolve path) (string-eq path "math/src/add.tl")]
        [(ErrPkgResolve _) false])
      (compiler-load-package-import-externs?
        (AstImportModule)
        "math.src.add"
        deps)
      (not
        (compiler-load-package-import-externs?
          (AstImportModule)
          "stdlib.core_macros"
          deps)))))

(define (compiler-load-generated-meta-preserved-ok?) : bool
  (let
    [meta : AstGeneratedDeclMeta
      (AstSomeGeneratedDeclMeta "gen" "generated-fn" AstExprNil "")]
    [inner : AstDecl
      (ast-decl-def-fn
        "generated-fn"
        AstParamNil
        (AstTyI64)
        (ast-node-push (AstExprLiteral (ast-lit-int 1))))]
    [decl : AstDecl (ast-decl-comptime-decl-with-meta meta inner)]
    (match (compiler-load-package-transform-decl
      "demo"
      ""
      (string-vec-new)
      "src/main.tl"
      "main"
      decl)
      [(CompilerLoadSomeDecl transformed)
        (match transformed
          [(AstDeclComptimeDecl found-meta template-box)
            (let
              [template : AstDecl (box-get template-box)]
              (and
                (match found-meta
                  [(AstSomeGeneratedDeclMeta generator item arg-keys _)
                    (and
                      (string-eq generator "gen")
                      (string-eq item "generated-fn")
                      (match arg-keys
                        [(AstExprNil) true]
                        [_ false]))]
                  [_ false])
                (match template
                  [(AstDeclExtern name _ _ _)
                    (string-eq (intern-str name) "generated-fn")]
                  [_ false])))]
          [_ false])]
      [(CompilerLoadNoDecl) false])))

;; Diamond import dedup (#1074 / #1041): entry imports A and B, both of which
;; import C; C must load exactly once. Writes fixture modules under target/ and
;; loads through the file loader, mirroring the existing dedup/cycle self-test.
(define (compiler-load-diamond-import-ok?) : bool
  (begin
    (write-file
      "target/cl_diamond_c.tl"
      "(module diamond.c)
(define c-val : i64 1)")
    (write-file
      "target/cl_diamond_a.tl"
      "(module diamond.a)
(import \"cl_diamond_c.tl\" module diamond.c as c)
(define a-val : i64 1)")
    (write-file
      "target/cl_diamond_b.tl"
      "(module diamond.b)
(import \"cl_diamond_c.tl\" module diamond.c as c)
(define b-val : i64 1)")
    (write-file
      "target/cl_diamond_entry.tl"
      "(module diamond.entry)
(import \"cl_diamond_a.tl\" module diamond.a as a)
(import \"cl_diamond_b.tl\" module diamond.b as b)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_diamond_entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ _ seen)
        (and
          (= (compiler-load-decl-list-count decls) 17)
          (sym-i64-contains seen "diamond.c")
          (sym-i64-contains seen "diamond.a")
          (sym-i64-contains seen "diamond.b")
          (sym-i64-contains seen "diamond.entry"))]
      [(ErrCompilerLoadWithPaths _) false])))

;; Transitive import dedup (#1074 / #1041): entry imports A, A imports B, B
;; imports C; the whole chain loads with the deterministic loaded decl count and
;; every module recorded in the seen set.
(define (compiler-load-transitive-import-ok?) : bool
  (begin
    (write-file "target/cl_tr_c.tl" "(module tr.c)
(define c-val : i64 1)")
    (write-file
      "target/cl_tr_b.tl"
      "(module tr.b)
(import \"cl_tr_c.tl\" module tr.c as c)
(define b-val : i64 1)")
    (write-file
      "target/cl_tr_a.tl"
      "(module tr.a)
(import \"cl_tr_b.tl\" module tr.b as b)
(define a-val : i64 1)")
    (write-file
      "target/cl_tr_entry.tl"
      "(module tr.entry)
(import \"cl_tr_a.tl\" module tr.a as a)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_tr_entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ _ seen)
        (and
          (= (compiler-load-decl-list-count decls) 14)
          (sym-i64-contains seen "tr.c")
          (sym-i64-contains seen "tr.b")
          (sym-i64-contains seen "tr.a")
          (sym-i64-contains seen "tr.entry"))]
      [(ErrCompilerLoadWithPaths _) false])))

;; An `(import ...)` of a path that does not resolve to a readable file reports
;; a `cannot read import <path>` diagnostic (the imported-file diagnostic; #1074).
(define (compiler-load-missing-import-ok?) : bool
  (match (compiler-load-source
    "src/app.tl"
    "(import \"no_such_module_xyz.tl\")
(define value : i64 1)"
    (sym-i64-empty))
    [(ErrCompilerLoad diag)
      (string-eq
        (compiler-diagnostic-message diag)
        "compiler-load: cannot read import src/no_such_module_xyz.tl")]
    [(OkCompilerLoad _ _) false]))

(define (compiler-load-include-str-relative-ok?) : bool
  (begin
    (write-file "target/cl_include_payload.txt" "hello from include")
    (write-file
      "target/cl_include_entry.tl"
      "(include-str payload \"cl_include_payload.txt\")
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_include_entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ _ _)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (compiler-load-first-string-def? decls "payload" "hello from include"))]
      [(ErrCompilerLoadWithPaths _) false])))

(define (compiler-load-include-str-stdlib-root-ok?) : bool
  (begin
    (write-file "target/cl_include_root_payload.txt" "hello from root")
    (match (compiler-load-source-with-paths-and-roots
      "src/include_entry.tl"
      "(include-str embedded \"stdlib/cl_include_root_payload.txt\")
(define (main) : i64 0)"
      (sym-i64-empty)
      (string-vec-push (string-vec-new) "target"))
      [(OkCompilerLoadWithPaths decls _ _ _)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (compiler-load-first-string-def? decls "embedded" "hello from root"))]
      [(ErrCompilerLoadWithPaths _) false])))

(define (compiler-load-missing-include-str-ok?) : bool
  (match (compiler-load-source
    "src/app.tl"
    "(include-str missing \"no_such_resource_xyz.txt\")
(define value : i64 1)"
    (sym-i64-empty))
    [(ErrCompilerLoad diag)
      (string-eq
        (compiler-diagnostic-message diag)
        "compiler-load: cannot read include-str no_such_resource_xyz.txt from src/app.tl (resolved src/no_such_resource_xyz.txt)")]
    [(OkCompilerLoad _ _) false]))

(define (compiler-load-include-str-raw-text-ok?) : bool
  (let
    [payload : String
      "(import \"definitely_missing.tl\")
(define injected : i64 7)"]
    (begin
      (write-file "target/cl_include_raw_payload.txt" payload)
      (write-file
        "target/cl_include_raw_entry.tl"
        "(include-str payload \"cl_include_raw_payload.txt\")
(define (main) : i64 0)")
      (match (compiler-load-file-with-paths
        "target/cl_include_raw_entry.tl"
        (sym-i64-empty))
        [(OkCompilerLoadWithPaths decls _ _ _)
          (and
            (= (compiler-load-decl-list-count decls) 2)
            (compiler-load-first-string-def? decls "payload" payload))]
        [(ErrCompilerLoadWithPaths _) false]))))

(define (compiler-load-include-bin-relative-ok?) : bool
  (begin
    (write-file
      "target/cl_include_bin_payload.bin"
      (compiler-load-binary-fixture))
    (write-file
      "target/cl_include_bin_entry.tl"
      "(include-bin payload \"cl_include_bin_payload.bin\")
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_include_bin_entry.tl"
      (sym-i64-empty))
      [(OkCompilerLoadWithPaths decls _ _ _)
        (and
          (= (compiler-load-decl-list-count decls) 2)
          (compiler-load-first-bin-def? decls "payload"))]
      [(ErrCompilerLoadWithPaths _) false])))

(define (compiler-load-missing-include-bin-ok?) : bool
  (match (compiler-load-source
    "src/app.tl"
    "(include-bin missing \"no_such_resource_xyz.bin\")
(define value : i64 1)"
    (sym-i64-empty))
    [(ErrCompilerLoad diag)
      (string-eq
        (compiler-diagnostic-message diag)
        "compiler-load: cannot read include-bin no_such_resource_xyz.bin from src/app.tl (resolved src/no_such_resource_xyz.bin)")]
    [(OkCompilerLoad _ _) false]))

(define (compiler-load-embedded-stdlib-lookup-ok?) : bool
  (match (compiler-load-embedded-stdlib-source "string.tl")
    [(CompilerEmbeddedStdlibSomeSource source)
      (match (compiler-load-source-with-paths-and-roots
        "stdlib/string.tl"
        source
        (sym-i64-empty)
        (string-vec-new))
        [(OkCompilerLoadWithPaths decls _ _ _)
          (> (compiler-load-decl-list-count decls) 0)]
        [(ErrCompilerLoadWithPaths _) false])]
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
    (write-file
      "target/cl_ipe_dep.tl"
      "(module ipe.dep)
(define broken : i64 )")
    (write-file
      "target/cl_ipe_entry.tl"
      "(module ipe.entry)
(import \"cl_ipe_dep.tl\" module ipe.dep as dep)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_ipe_entry.tl"
      (sym-i64-empty))
      [(ErrCompilerLoadWithPaths diag)
        (and
          (string-eq (compiler-diagnostic-path diag) "target/cl_ipe_dep.tl")
          (string-eq
            (compiler-diagnostic-message diag)
            "parse: malformed value definition"))]
      [(OkCompilerLoadWithPaths _ _ _ _) false])))

;; A duplicate `(module ...)` declaration inside an imported file surfaces a
;; diagnostic whose path is the imported file, not the importer (#1074).
(define (compiler-load-imported-duplicate-module-path-ok?) : bool
  (begin
    (write-file
      "target/cl_idm_dep.tl"
      "(module idm.depa)
(module idm.depb)
(define v : i64 1)")
    (write-file
      "target/cl_idm_entry.tl"
      "(module idm.entry)
(import \"cl_idm_dep.tl\" module idm.depa as dep)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths
      "target/cl_idm_entry.tl"
      (sym-i64-empty))
      [(ErrCompilerLoadWithPaths diag)
        (and
          (string-eq (compiler-diagnostic-path diag) "target/cl_idm_dep.tl")
          (string-eq
            (compiler-diagnostic-message diag)
            "compiler-load: duplicate module declaration"))]
      [(OkCompilerLoadWithPaths _ _ _ _) false])))

;; A `stdlib/<x>` import whose importer-relative path is absent resolves through
;; a configured `--stdlib-root` (root fallback) (#1074).
(define (compiler-load-stdlib-root-fallback-ok?) : bool
  (begin
    (write-file "target/cl_srf_mod.tl" "(module srf.mod)
(define v : i64 1)")
    (write-file
      "target/cl_srf_entry.tl"
      "(module srf.entry)
(import \"stdlib/cl_srf_mod.tl\" module srf.mod as m)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths-and-roots
      "target/cl_srf_entry.tl"
      (sym-i64-empty)
      (string-vec-push (string-vec-new) "target"))
      [(OkCompilerLoadWithPaths _ _ _ seen) (sym-i64-contains seen "srf.mod")]
      [(ErrCompilerLoadWithPaths _) false])))

;; `--stdlib-root` resolution searches roots in order; the first existing
;; candidate wins, so a missing leading root is skipped (#1074).
(define (compiler-load-stdlib-searched-root-ok?) : bool
  (begin
    (write-file "target/cl_ssr_mod.tl" "(module ssr.mod)
(define v : i64 1)")
    (write-file
      "target/cl_ssr_entry.tl"
      "(module ssr.entry)
(import \"stdlib/cl_ssr_mod.tl\" module ssr.mod as m)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths-and-roots
      "target/cl_ssr_entry.tl"
      (sym-i64-empty)
      (string-vec-push
        (string-vec-push (string-vec-new) "target/cl_ssr_absent_root")
        "target"))
      [(OkCompilerLoadWithPaths _ _ _ seen) (sym-i64-contains seen "ssr.mod")]
      [(ErrCompilerLoadWithPaths _) false])))

;; A `stdlib/<x>` import found in no configured root reports a cannot-read
;; diagnostic naming the importer-relative candidate path (#1074).
(define (compiler-load-stdlib-unresolved-ok?) : bool
  (begin
    (write-file
      "target/cl_sur_entry.tl"
      "(module sur.entry)
(import \"stdlib/cl_sur_missing.tl\" module sur.mod as m)
(define (main) : i64 0)")
    (match (compiler-load-file-with-paths-and-roots
      "target/cl_sur_entry.tl"
      (sym-i64-empty)
      (string-vec-push (string-vec-new) "target"))
      [(ErrCompilerLoadWithPaths diag)
        (string-eq
          (compiler-diagnostic-message diag)
          "compiler-load: cannot read import target/stdlib/cl_sur_missing.tl")]
      [(OkCompilerLoadWithPaths _ _ _ _) false])))

;; A configured stdlib root must not serve a suffix that lexically escapes the
;; root with `..` (#1681).
(define (compiler-load-stdlib-root-escape-rejected-ok?) : bool
  (let
    [root-dir : String "target/cl_sre_root"]
    [entry-dir : String "target/cl_sre_entry_dir"]
    (begin
      (fs-mkdir-status-owned root-dir)
      (fs-mkdir-status-owned entry-dir)
      (write-file "target/cl_sre_out.tl" "(module sre.out)
(define v : i64 1)")
      (write-file
        "target/cl_sre_entry_dir/entry.tl"
        "(module sre.entry)
(import \"stdlib/../cl_sre_out.tl\" module sre.out as out)
(define (main) : i64 0)")
      (match (compiler-load-file-with-paths-and-roots
        "target/cl_sre_entry_dir/entry.tl"
        (sym-i64-empty)
        (string-vec-push (string-vec-new) "target/cl_sre_root"))
        [(ErrCompilerLoadWithPaths _) true]
        [(OkCompilerLoadWithPaths _ _ _ _) false]))))

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
  (aliases StringStringMap))

;: Package artifact kind: binary executable or static library.
(defenum CompilerPkgKind
  (CompilerPkgKindBin)
  (CompilerPkgKindLib))

;: A parsed `typelisp.pkg` manifest.
;: One link scope's native inputs: ordered libraries, search paths, and raw
;: linker arguments. Order within each list is preserved from the manifest.
(defstruct CompilerPkgLinkSet
  (libraries StringVec)
  (search-paths StringVec)
  (args StringVec))

;: Parsed `(link ...)` manifest section. `all` applies to every target; `linux`
;: and `windows` add per-target inputs. Empty lists mean the field was omitted.
(defstruct CompilerPkgLink
  (all CompilerPkgLinkSet)
  (linux CompilerPkgLinkSet)
  (windows CompilerPkgLinkSet))

(defenum ResultCompilerPkgLink
  (OkCompilerPkgLink CompilerPkgLink)
  (ErrCompilerPkgLink String))

;: Internal: a parsed list of `link` field string values, or a diagnostic.
(defenum ResultPkgStrVec
  (OkPkgStrVec StringVec)
  (ErrPkgStrVec String))

(defstruct CompilerPkgManifest
  (name String)
  (version String)
  (kind CompilerPkgKind)
  (entry String)
  (deps CompilerPkgDeps)
  (link CompilerPkgLink))

;: Parse result: the manifest or a legacy string diagnostic.
(defenum ResultCompilerPkgManifest
  (OkCompilerPkgManifest CompilerPkgManifest)
  (ErrCompilerPkgManifest String))

;: Source-facing parse result: the manifest or a path/span-bearing diagnostic.
(defenum ResultCompilerPkgManifestDiagnostic
  (OkCompilerPkgManifestDiagnostic CompilerPkgManifest)
  (ErrCompilerPkgManifestDiagnostic CompilerDiagnostic))

;: Internal: a single extracted string field value, or a diagnostic.
(defenum ResultPkgString
  (OkPkgString String)
  (ErrPkgString String))

;: Internal: a parsed package kind, or a diagnostic.
(defenum ResultCompilerPkgKind
  (OkCompilerPkgKind CompilerPkgKind)
  (ErrCompilerPkgKind String))

;: Internal: parsed dependencies, or a diagnostic.
(defenum ResultCompilerPkgDeps
  (OkCompilerPkgDeps CompilerPkgDeps)
  (ErrCompilerPkgDeps String))

;: Count the dependencies in a parsed list.
(define (compiler-pkg-dep-list-count [deps : CompilerPkgDepList]) : i64
  (match deps
    [(CompilerPkgDepNil) 0]
    [(CompilerPkgDepCons _ rest)
      (+ 1 (compiler-pkg-dep-list-count (box-get rest)))]))

(define (compiler-pkg-deps-empty) : CompilerPkgDeps
  (CompilerPkgDeps CompilerPkgDepNil (string-string-map-with-capacity 8)))

(define (compiler-pkg-deps-list [deps : CompilerPkgDeps]) : CompilerPkgDepList
  (struct-get deps ordered))

(define (compiler-pkg-deps-count [deps : CompilerPkgDeps]) : i64
  (compiler-pkg-dep-list-count (compiler-pkg-deps-list deps)))

(define (compiler-pkg-deps-alias-seen?
  [deps : CompilerPkgDeps]
  [target-alias : String]) : bool
  (string-string-map-contains? (struct-get deps aliases) target-alias))

(define (compiler-pkg-deps-cons
  [alias : String]
  [path : String]
  [tail : CompilerPkgDeps]) : CompilerPkgDeps
  (CompilerPkgDeps
    (CompilerPkgDepCons
      (CompilerPkgDep alias path)
      (box (compiler-pkg-deps-list tail)))
    (string-string-map-put (struct-get tail aliases) alias path)))

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
    [n : i64 (string-length value)]
    [i : i64 0]
    [ok : bool (> n 0)]
    (begin
      (while ok
        (if (< i n)
          (if (compiler-load-package-name-char? (string-ref value i))
            (set! i (+ i 1))
            (set! ok false))
          (set! ok false)))
      (= i n))))

(define (compiler-load-github-component-char? [c : char]) : bool
  (or (compiler-load-package-name-char? c) (= c '.')))

(define (compiler-load-github-component-valid? [value : String]) : bool
  (let
    [n : i64 (string-length value)]
    [i : i64 0]
    [ok : bool (> n 0)]
    (begin
      (while ok
        (if (< i n)
          (if (compiler-load-github-component-char? (string-ref value i))
            (set! i (+ i 1))
            (set! ok false))
          (set! ok false)))
      (= i n))))

(define (compiler-load-github-dependency-path? [path : String]) : bool
  (compiler-load-string-prefix-at? path "https://github.com/" 0))

(define (compiler-load-github-pin-kind-valid? [kind : String]) : bool
  (or (string-eq kind "rev") (string-eq kind "tag") (string-eq kind "branch")))

(define (compiler-load-github-address-body [address : String]) : String
  (if (compiler-load-string-prefix-at? address "github.com/" 0)
    (substring address 11 (- (string-length address) 11))
    address))

(define (compiler-load-github-address-error [alias : String]) : ResultPkgString
  (ErrPkgString
    (string-append
      "manifest dependency `"
      (string-append
        alias
        "` github address must be `owner/repo` or `github.com/owner/repo`"))))

(define (compiler-load-normalize-github-address
  [alias : String]
  [address : String]
  [pin-kind : String]
  [pin-value : String]) : ResultPkgString
  (let
    [body : String (compiler-load-github-address-body address)]
    [body-len : i64 (string-length body)]
    [slash : i64 (compiler-load-slash-index-from body 0 body-len)]
    (if (or (< slash 1) (>= slash (- body-len 1)))
      (compiler-load-github-address-error alias)
      (let
        [owner : String (substring body 0 slash)]
        [repo : String (substring body (+ slash 1) (- body-len (+ slash 1)))]
        (cond
          [(>= (compiler-load-slash-index-from repo 0 (string-length repo)) 0)
            (compiler-load-github-address-error alias)]
          [(not (compiler-load-github-component-valid? owner))
            (compiler-load-github-address-error alias)]
          [(not (compiler-load-github-component-valid? repo))
            (compiler-load-github-address-error alias)]
          [else
            (OkPkgString
              (string-append
                "https://github.com/"
                (string-append
                  owner
                  (string-append
                    "/"
                    (string-append
                      repo
                      (string-append
                        ".git#"
                        (string-append pin-kind (string-append "=" pin-value))))))))])))))

(define (compiler-load-normal-relative-entry? [path : String]) : bool
  (compiler-load-safe-relative? path))

;: Extract a single `"value"` from a field tail `("value")`.
(define (compiler-load-manifest-string-value [ftail : Sexpr] [fname : String]) : ResultPkgString
  (match ftail
    [(SCons vhead vrest)
      (match (box-get vhead)
        [(SStr val)
          (match (box-get vrest)
            [(SNil) (OkPkgString val)]
            [_
              (ErrPkgString
                (string-append
                  "manifest field `"
                  (string-append fname "` takes a single string value")))])]
        [_
          (ErrPkgString
            (string-append
              "manifest field `"
              (string-append fname "` must have a string value")))])]
    [_
      (ErrPkgString
        (string-append
          "manifest field `"
          (string-append fname "` must have a string value")))]))

(define (compiler-load-manifest-github-pin
  [alias : String]
  [address : String]
  [pin-form : Sexpr]) : ResultPkgString
  (match pin-form
    [(SCons pin-kind-node pin-tail)
      (match (box-get pin-kind-node)
        [(SSym pin-kind)
          (if (compiler-load-github-pin-kind-valid? pin-kind)
            (match (box-get pin-tail)
              [(SCons pin-value-node end)
                (match (box-get end)
                  [(SNil)
                    (match (box-get pin-value-node)
                      [(SStr pin-value)
                        (if (string-eq pin-value "")
                          (ErrPkgString
                            (string-append
                              "manifest dependency `"
                              (string-append
                                alias
                                "` github pin must not be empty")))
                          (compiler-load-normalize-github-address
                            alias
                            address
                            pin-kind
                            pin-value))]
                      [_
                        (ErrPkgString
                          (string-append
                            "manifest dependency `"
                            (string-append
                              alias
                              "` github pin must be a single string value")))])]
                  [_
                    (ErrPkgString
                      (string-append
                        "manifest dependency `"
                        (string-append
                          alias
                          "` github pin must be a single string value")))])]
              [_
                (ErrPkgString
                  (string-append
                    "manifest dependency `"
                    (string-append
                      alias
                      "` github pin must be a single string value")))])
            (ErrPkgString
              (string-append
                "manifest dependency `"
                (string-append alias "` github pin must be rev, tag, or branch"))))]
        [_
          (ErrPkgString
            (string-append
              "manifest dependency `"
              (string-append
                alias
                "` github source requires exactly one rev, tag, or branch pin")))])]
    [_
      (ErrPkgString
        (string-append
          "manifest dependency `"
          (string-append
            alias
            "` github source requires exactly one rev, tag, or branch pin")))]))

(define (compiler-load-manifest-github-value
  [alias : String]
  [source-tail : Sexpr]) : ResultPkgString
  (match source-tail
    [(SCons address-node after-address)
      (match (box-get address-node)
        [(SStr address)
          (match (box-get after-address)
            [(SCons pin-form end)
              (match (box-get end)
                [(SNil)
                  (compiler-load-manifest-github-pin
                    alias
                    address
                    (box-get pin-form))]
                [_
                  (ErrPkgString
                    (string-append
                      "manifest dependency `"
                      (string-append
                        alias
                        "` github source requires exactly one rev, tag, or branch pin")))])]
            [_
              (ErrPkgString
                (string-append
                  "manifest dependency `"
                  (string-append
                    alias
                    "` github source requires exactly one rev, tag, or branch pin")))])]
        [_
          (ErrPkgString
            (string-append
              "manifest dependency `"
              (string-append
                alias
                "` github source must be `(github \"owner/repo\" (rev|tag|branch \"pin\"))`")))])]
    [_
      (ErrPkgString
        (string-append
          "manifest dependency `"
          (string-append
            alias
            "` github source must be `(github \"owner/repo\" (rev|tag|branch \"pin\"))`")))]))

(define (compiler-load-manifest-dependency-value
  [etail : Sexpr]
  [alias : String]) : ResultPkgString
  (match etail
    [(SCons vhead vrest)
      (match (box-get vrest)
        [(SNil)
          (match (box-get vhead)
            [(SStr path) (OkPkgString path)]
            [(SCons source-kind-node source-tail)
              (match (box-get source-kind-node)
                [(SSym source-kind)
                  (if (string-eq source-kind "github")
                    (compiler-load-manifest-github-value
                      alias
                      (box-get source-tail))
                    (ErrPkgString
                      (string-append
                        "manifest dependency `"
                        (string-append
                          alias
                          "` must be a path string or github source"))))]
                [_
                  (ErrPkgString
                    (string-append
                      "manifest dependency `"
                      (string-append
                        alias
                        "` must be a path string or github source")))])]
            [_
              (ErrPkgString
                (string-append
                  "manifest dependency `"
                  (string-append
                    alias
                    "` must be a path string or github source")))])]
        [_
          (ErrPkgString
            (string-append
              "manifest dependency `"
              (string-append
                alias
                "` takes a single path string or github source")))])]
    [_
      (ErrPkgString
        (string-append
          "manifest dependency `"
          (string-append alias "` must be a path string or github source")))]))

(define (compiler-load-manifest-kind-token [val : String]) : ResultCompilerPkgKind
  (if (string-eq val "bin")
    (OkCompilerPkgKind (CompilerPkgKindBin))
    (if (or (string-eq val "staticlib") (string-eq val "lib"))
      (OkCompilerPkgKind (CompilerPkgKindLib))
      (ErrCompilerPkgKind
        "manifest field `kind` must be `bin`, `staticlib`, or `lib`"))))

(define (compiler-load-manifest-kind-value [ftail : Sexpr]) : ResultCompilerPkgKind
  (match ftail
    [(SCons vhead vrest)
      (match (box-get vrest)
        [(SNil)
          (match (box-get vhead)
            [(SStr val) (compiler-load-manifest-kind-token val)]
            [(SSym val) (compiler-load-manifest-kind-token val)]
            [_
              (ErrCompilerPkgKind
                "manifest field `kind` must have a string or symbol value")])]
        [_ (ErrCompilerPkgKind "manifest field `kind` takes a single value")])]
    [_
      (ErrCompilerPkgKind
        "manifest field `kind` must have a string or symbol value")]))

(define (compiler-load-manifest-cons-dep
  [alias : String]
  [path : String]
  [rest : Sexpr]) : ResultCompilerPkgDeps
  (cond
    [(string-eq alias "")
      (ErrCompilerPkgDeps "dependency alias must not be empty")]
    [(not (compiler-load-package-token-valid? alias))
      (ErrCompilerPkgDeps
        "dependency alias may only contain ASCII letters, digits, '-' and '_'")]
    [(string-eq path "")
      (ErrCompilerPkgDeps
        (string-append
          "manifest dependency `"
          (string-append alias "` path must not be empty")))]
    [else
      (match (compiler-load-manifest-parse-deps rest)
        [(ErrCompilerPkgDeps m) (ErrCompilerPkgDeps m)]
        [(OkCompilerPkgDeps tail-deps)
          (if (compiler-pkg-deps-alias-seen? tail-deps alias)
            (ErrCompilerPkgDeps
              (string-append
                "duplicate dependency alias `"
                (string-append alias "`")))
            (OkCompilerPkgDeps (compiler-pkg-deps-cons alias path tail-deps)))])]))

;: Parse the `(alias "path") ...` entries of a `(dependencies ...)` field.
(define (compiler-load-manifest-parse-deps [entries : Sexpr]) : ResultCompilerPkgDeps
  (match entries
    [(SNil) (OkCompilerPkgDeps (compiler-pkg-deps-empty))]
    [(SCons entry rest)
      (match (box-get entry)
        [(SCons ehead etail)
          (match (box-get ehead)
            [(SSym alias)
              (match (compiler-load-manifest-dependency-value
                (box-get etail)
                alias)
                [(ErrPkgString m) (ErrCompilerPkgDeps m)]
                [(OkPkgString path)
                  (compiler-load-manifest-cons-dep alias path (box-get rest))])]
            [_
              (ErrCompilerPkgDeps
                "dependency entries must start with an alias name")])]
        [_
          (ErrCompilerPkgDeps
            "dependency entries must be lists like `(alias \"path\")`")])]
    [_
      (ErrCompilerPkgDeps
        "`dependencies` must be a list of `(alias \"path\")` or `(alias (github ...))` entries")]))

;: An empty link scope (no libraries, search paths, or args).
(define (compiler-pkg-link-set-empty) : CompilerPkgLinkSet
  (CompilerPkgLinkSet (string-vec-new) (string-vec-new) (string-vec-new)))

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
    [(string-eq fname "libraries") 0]
    [(string-eq fname "search-paths") 0]
    [(string-eq fname "args") 0]
    [(string-eq fname "linux-libraries") 1]
    [(string-eq fname "linux-search-paths") 1]
    [(string-eq fname "linux-args") 1]
    [(string-eq fname "windows-libraries") 2]
    [(string-eq fname "windows-search-paths") 2]
    [(string-eq fname "windows-args") 2]
    [else -1]))

;: Map a `link` sub-field name to its category index, or -1 when unknown.
;: category: 0 libraries, 1 search-paths, 2 args.
(define (compiler-load-link-field-category [fname : String]) : i64
  (cond
    [(string-eq fname "libraries") 0]
    [(string-eq fname "search-paths") 1]
    [(string-eq fname "args") 2]
    [(string-eq fname "linux-libraries") 0]
    [(string-eq fname "linux-search-paths") 1]
    [(string-eq fname "linux-args") 2]
    [(string-eq fname "windows-libraries") 0]
    [(string-eq fname "windows-search-paths") 1]
    [(string-eq fname "windows-args") 2]
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
(define (compiler-pkg-link-set-category [set : CompilerPkgLinkSet] [cat : i64]) : StringVec
  (if (= cat 0)
    (struct-get set libraries)
    (if (= cat 1)
      (struct-get set search-paths)
      (struct-get set args))))

;: Return `set` with the given category's value list replaced.
(define (compiler-pkg-link-set-replace-category
  [set : CompilerPkgLinkSet]
  [cat : i64]
  [vec : StringVec]) : CompilerPkgLinkSet
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
  [cat : i64]) : StringVec
  (compiler-pkg-link-set-category (compiler-pkg-link-scope-set link scope) cat))

;: Return `link` with the (scope, category) value list replaced.
(define (compiler-pkg-link-set-vec
  [link : CompilerPkgLink]
  [scope : i64]
  [cat : i64]
  [vec : StringVec]) : CompilerPkgLink
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
  [acc : StringVec]) : ResultPkgStrVec
  (match values
    [(SNil)
      (if (= (string-vec-len acc) 0)
        (ErrPkgStrVec
          (string-append
            "`link` field `"
            (string-append fname "` requires at least one value")))
        (OkPkgStrVec acc))]
    [(SCons vhead vrest)
      (match (box-get vhead)
        [(SStr val)
          (if (string-eq val "")
            (ErrPkgStrVec
              (string-append
                "`link` field `"
                (string-append fname "` values must not be empty")))
            (compiler-load-manifest-link-values
              (box-get vrest)
              fname
              (string-vec-push acc val)))]
        [_
          (ErrPkgStrVec
            (string-append
              "`link` field `"
              (string-append fname "` values must be strings")))])]
    [_
      (ErrPkgStrVec
        (string-append
          "`link` field `"
          (string-append fname "` must be a list of string values")))]))

;: Store one parsed sub-field into the accumulating link section, rejecting
;: unknown field names and a field that was already provided.
(define (compiler-load-manifest-link-store
  [acc : CompilerPkgLink]
  [fname : String]
  [values : StringVec]) : ResultCompilerPkgLink
  (let
    [scope : i64 (compiler-load-link-field-scope fname)]
    [cat : i64 (compiler-load-link-field-category fname)]
    (if (or (< scope 0) (< cat 0))
      (ErrCompilerPkgLink
        (string-append "unknown `link` field `" (string-append fname "`")))
      (if (> (string-vec-len (compiler-pkg-link-get-vec acc scope cat)) 0)
        (ErrCompilerPkgLink
          (string-append "duplicate `link` field `" (string-append fname "`")))
        (OkCompilerPkgLink (compiler-pkg-link-set-vec acc scope cat values))))))

;: Walk the `(field "...")` entries of a `(link ...)` section.
(define (compiler-load-manifest-parse-link-into
  [entries : Sexpr]
  [acc : CompilerPkgLink]) : ResultCompilerPkgLink
  (match entries
    [(SNil) (OkCompilerPkgLink acc)]
    [(SCons entry rest)
      (match (box-get entry)
        [(SCons ehead etail)
          (match (box-get ehead)
            [(SSym fname)
              (match (compiler-load-manifest-link-values
                (box-get etail)
                fname
                (string-vec-new))
                [(ErrPkgStrVec m) (ErrCompilerPkgLink m)]
                [(OkPkgStrVec values)
                  (match (compiler-load-manifest-link-store acc fname values)
                    [(ErrCompilerPkgLink m) (ErrCompilerPkgLink m)]
                    [(OkCompilerPkgLink acc2)
                      (compiler-load-manifest-parse-link-into
                        (box-get rest)
                        acc2)])])]
            [_
              (ErrCompilerPkgLink "`link` entries must start with a field name")])]
        [_
          (ErrCompilerPkgLink
            "`link` entries must be lists like `(libraries \"...\")`")])]
    [_
      (ErrCompilerPkgLink "`link` must be a list of `(field \"...\")` entries")]))

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
    [(SNil)
      (let
        [final-entry : String
          (if has-entry
            entry
            (compiler-load-manifest-default-entry kind))]
        (cond
          [(not has-name)
            (ErrCompilerPkgManifest "manifest missing required field `name`")]
          [(string-eq name "")
            (ErrCompilerPkgManifest "manifest field `name` must not be empty")]
          [(not (compiler-load-package-token-valid? name))
            (ErrCompilerPkgManifest
              "manifest field `name` may only contain ASCII letters, digits, '-' and '_'")]
          [(not has-version)
            (ErrCompilerPkgManifest "manifest missing required field `version`")]
          [(string-eq version "")
            (ErrCompilerPkgManifest
              "manifest field `version` must not be empty")]
          [(string-eq final-entry "")
            (ErrCompilerPkgManifest "manifest field `entry` must not be empty")]
          [(not (compiler-load-normal-relative-entry? final-entry))
            (ErrCompilerPkgManifest
              "manifest field `entry` must be a normal relative path below the manifest directory")]
          [else
            (OkCompilerPkgManifest
              (CompilerPkgManifest name version kind final-entry deps link))]))]
    [(SCons field rest)
      (match (box-get field)
        [(SCons fhead ftail)
          (match (box-get fhead)
            [(SSym fname)
              (cond
                [(string-eq fname "dependencies")
                  (if has-deps
                    (ErrCompilerPkgManifest
                      "duplicate manifest field `dependencies`")
                    (match (compiler-load-manifest-parse-deps (box-get ftail))
                      [(ErrCompilerPkgDeps m) (ErrCompilerPkgManifest m)]
                      [(OkCompilerPkgDeps parsed-deps)
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
                [(string-eq fname "link")
                  (if has-link
                    (ErrCompilerPkgManifest "duplicate manifest field `link`")
                    (match (compiler-load-manifest-parse-link (box-get ftail))
                      [(ErrCompilerPkgLink m) (ErrCompilerPkgManifest m)]
                      [(OkCompilerPkgLink parsed-link)
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
                [(string-eq fname "name")
                  (if has-name
                    (ErrCompilerPkgManifest "duplicate manifest field `name`")
                    (match (compiler-load-manifest-string-value
                      (box-get ftail)
                      fname)
                      [(ErrPkgString m) (ErrCompilerPkgManifest m)]
                      [(OkPkgString val)
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
                [(string-eq fname "version")
                  (if has-version
                    (ErrCompilerPkgManifest
                      "duplicate manifest field `version`")
                    (match (compiler-load-manifest-string-value
                      (box-get ftail)
                      fname)
                      [(ErrPkgString m) (ErrCompilerPkgManifest m)]
                      [(OkPkgString val)
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
                [(string-eq fname "kind")
                  (if has-kind
                    (ErrCompilerPkgManifest "duplicate manifest field `kind`")
                    (match (compiler-load-manifest-kind-value (box-get ftail))
                      [(ErrCompilerPkgKind m) (ErrCompilerPkgManifest m)]
                      [(OkCompilerPkgKind val)
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
                [(string-eq fname "entry")
                  (if has-entry
                    (ErrCompilerPkgManifest "duplicate manifest field `entry`")
                    (match (compiler-load-manifest-string-value
                      (box-get ftail)
                      fname)
                      [(ErrPkgString m) (ErrCompilerPkgManifest m)]
                      [(OkPkgString val)
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
                  (ErrCompilerPkgManifest
                    (string-append
                      "unknown manifest field `"
                      (string-append fname "`")))])]
            [_
              (ErrCompilerPkgManifest
                "package fields must start with a field name")])]
        [_
          (ErrCompilerPkgManifest
            "package fields must be lists like `(name \"...\")`")])]
    [_
      (ErrCompilerPkgManifest
        "package fields must be lists like `(name \"...\")`")]))

;: Parse the top-level `(package ...)` form.
(define (compiler-load-manifest-from-form [form : Sexpr]) : ResultCompilerPkgManifest
  (match form
    [(SCons head rest)
      (match (box-get head)
        [(SSym s)
          (if (string-eq s "package")
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
            (ErrCompilerPkgManifest
              (string-append
                "expected `package` form, got `"
                (string-append s "`"))))]
        [_ (ErrCompilerPkgManifest "manifest must start with `package`")])]
    [_ (ErrCompilerPkgManifest "manifest must be a `(package ...)` form")]))

(define (compiler-load-manifest-fields-have? [fields : Sexpr] [target : String]) : bool
  (match fields
    [(SNil) false]
    [(SCons field rest)
      (let
        [tail-has : bool
          (compiler-load-manifest-fields-have? (box-get rest) target)]
        (match (box-get field)
          [(SCons fhead _)
            (match (box-get fhead)
              [(SSym name) (or (string-eq name target) tail-has)]
              [_ tail-has])]
          [_ tail-has]))]
    [_ false]))

(define (compiler-load-manifest-form-has-field?
  [form : Sexpr]
  [target : String]) : bool
  (match form
    [(SCons head rest)
      (match (box-get head)
        [(SSym s)
          (if (string-eq s "package")
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
      (file-exists?
        (compiler-load-manifest-convention-path manifest-path "src/main.tl"))]
    [has-lib : bool
      (file-exists?
        (compiler-load-manifest-convention-path manifest-path "src/lib.tl"))]
    (cond
      [(and has-main (not has-lib)) (OkCompilerPkgKind (CompilerPkgKindBin))]
      [(and has-lib (not has-main)) (OkCompilerPkgKind (CompilerPkgKindLib))]
      [(and has-main has-lib)
        (ErrCompilerPkgKind
          "manifest omits `kind` and `entry`, but both `src/main.tl` and `src/lib.tl` exist; add explicit `kind` or `entry`")]
      [else
        (ErrCompilerPkgKind
          "manifest omits `kind` and `entry`, but neither `src/main.tl` nor `src/lib.tl` exists; add `kind` and `entry` or create a conventional entry file")])))

;: Preserve the legacy `manifest: ...` syntax-error message while attaching the
;: reader span to the source-facing diagnostic result.
(define (compiler-load-manifest-source-error-diagnostic
  [path : String]
  [err : SourceError]) : CompilerDiagnostic
  (compiler-diagnostic-from-span
    path
    (source-error-span err)
    (string-append "manifest: " (source-error-message err))))

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
        [(OkCompilerPkgKind kind)
          (OkCompilerPkgManifestDiagnostic
            (compiler-load-manifest-with-kind manifest kind))]
        [(ErrCompilerPkgKind message)
          (ErrCompilerPkgManifestDiagnostic
            (compiler-load-manifest-validation-diagnostic path form message))])
      (OkCompilerPkgManifestDiagnostic manifest))))

(define (compiler-load-parse-manifest-form-diagnostic
  [path : String]
  [form : SpannedSexpr]) : ResultCompilerPkgManifestDiagnostic
  (match (compiler-load-manifest-from-form (spanned-sexpr-form form))
    [(OkCompilerPkgManifest manifest)
      (OkCompilerPkgManifestDiagnostic manifest)]
    [(ErrCompilerPkgManifest message)
      (ErrCompilerPkgManifestDiagnostic
        (compiler-load-manifest-validation-diagnostic path form message))]))

(define (compiler-load-parse-manifest-form-diagnostic-infer-kind
  [path : String]
  [form : SpannedSexpr]) : ResultCompilerPkgManifestDiagnostic
  (match (compiler-load-manifest-from-form (spanned-sexpr-form form))
    [(OkCompilerPkgManifest manifest)
      (compiler-load-manifest-apply-kind-inference path form manifest)]
    [(ErrCompilerPkgManifest message)
      (ErrCompilerPkgManifestDiagnostic
        (compiler-load-manifest-validation-diagnostic path form message))]))

;: Parse a `typelisp.pkg` manifest source string into a structured manifest,
;: preserving manifest path/span identity for source-facing errors.
(define (compiler-load-parse-manifest-diagnostic
  [path : String]
  [source : String]) : ResultCompilerPkgManifestDiagnostic
  (begin
    (sp-node-pool-reset!)
    (match (lex-spanned-result source)
      [(ErrSpannedTokens err)
        (ErrCompilerPkgManifestDiagnostic
          (compiler-load-manifest-source-error-diagnostic path err))]
      [(OkSpannedTokens toks)
        (match (read-spanned-result toks)
          [(ErrSpannedSexpr err)
            (ErrCompilerPkgManifestDiagnostic
              (compiler-load-manifest-source-error-diagnostic path err))]
          [(OkSpannedSexpr form)
            (compiler-load-parse-manifest-form-diagnostic path form)])])))

(define (compiler-load-parse-manifest-diagnostic-infer-kind
  [path : String]
  [source : String]) : ResultCompilerPkgManifestDiagnostic
  (begin
    (sp-node-pool-reset!)
    (match (lex-spanned-result source)
      [(ErrSpannedTokens err)
        (ErrCompilerPkgManifestDiagnostic
          (compiler-load-manifest-source-error-diagnostic path err))]
      [(OkSpannedTokens toks)
        (match (read-spanned-result toks)
          [(ErrSpannedSexpr err)
            (ErrCompilerPkgManifestDiagnostic
              (compiler-load-manifest-source-error-diagnostic path err))]
          [(OkSpannedSexpr form)
            (compiler-load-parse-manifest-form-diagnostic-infer-kind path form)])])))

;: Parse a manifest source string into a structured manifest. This compatibility
;: wrapper keeps existing in-memory parser callers and message-only tests stable.
(define (compiler-load-parse-manifest [source : String]) : ResultCompilerPkgManifest
  (match (compiler-load-parse-manifest-diagnostic "" source)
    [(OkCompilerPkgManifestDiagnostic manifest)
      (OkCompilerPkgManifest manifest)]
    [(ErrCompilerPkgManifestDiagnostic diag)
      (ErrCompilerPkgManifest (compiler-diagnostic-message diag))]))

;: Self-test: a full manifest parses with the expected fields + dependency
;: count.
(define (compiler-load-manifest-valid-full-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"demo\") (version \"0.1.0\") (kind \"bin\") (entry \"src/main.tl\") (dependencies (math \"../math\") (util \"../util\")))")
    [(OkCompilerPkgManifest m)
      (and
        (string-eq (struct-get m name) "demo")
        (string-eq (struct-get m version) "0.1.0")
        (match (struct-get m kind)
          [(CompilerPkgKindBin)
            (and
              (string-eq (struct-get m entry) "src/main.tl")
              (= (compiler-pkg-deps-count (struct-get m deps)) 2))]
          [(CompilerPkgKindLib) false]))]
    [(ErrCompilerPkgManifest _) false]))

;: Self-test: a manifest without a `dependencies` field parses with no deps.
(define (compiler-load-manifest-valid-nodeps-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"x\") (version \"1\") (kind staticlib))")
    [(OkCompilerPkgManifest m)
      (match (struct-get m kind)
        [(CompilerPkgKindLib)
          (and
            (string-eq (struct-get m entry) "src/lib.tl")
            (= (compiler-pkg-deps-count (struct-get m deps)) 0))]
        [(CompilerPkgKindBin) false])]
    [(ErrCompilerPkgManifest _) false]))

(define (compiler-load-manifest-default-bin-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"default_bin\") (version \"1\"))")
    [(OkCompilerPkgManifest m)
      (match (struct-get m kind)
        [(CompilerPkgKindBin) (string-eq (struct-get m entry) "src/main.tl")]
        [(CompilerPkgKindLib) false])]
    [(ErrCompilerPkgManifest _) false]))

(define (compiler-load-manifest-entry-override-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"override\") (version \"1\") (kind \"staticlib\") (entry \"custom/lib.tl\"))")
    [(OkCompilerPkgManifest m)
      (match (struct-get m kind)
        [(CompilerPkgKindLib) (string-eq (struct-get m entry) "custom/lib.tl")]
        [(CompilerPkgKindBin) false])]
    [(ErrCompilerPkgManifest _) false]))

(define (compiler-load-manifest-dep-path-is?
  [deps : CompilerPkgDeps]
  [alias : String]
  [expected : String]) : bool
  (match (compiler-load-pkg-dep-lookup deps alias)
    [(CompilerLoadSomePath path) (string-eq path expected)]
    [(CompilerLoadNoPath) false]))

(define (compiler-load-pkg-deps-three-alias-order?
  [deps : CompilerPkgDeps]
  [first-alias : String]
  [second-alias : String]
  [third-alias : String]) : bool
  (match (compiler-pkg-deps-list deps)
    [(CompilerPkgDepCons first rest1)
      (and
        (string-eq (struct-get first alias) first-alias)
        (match (box-get rest1)
          [(CompilerPkgDepCons second rest2)
            (and
              (string-eq (struct-get second alias) second-alias)
              (match (box-get rest2)
                [(CompilerPkgDepCons third rest3)
                  (and
                    (string-eq (struct-get third alias) third-alias)
                    (match (box-get rest3)
                      [(CompilerPkgDepNil) true]
                      [(CompilerPkgDepCons _ _) false]))]
                [(CompilerPkgDepNil) false]))]
          [(CompilerPkgDepNil) false]))]
    [(CompilerPkgDepNil) false]))

(define (compiler-load-manifest-github-deps-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"github_demo\") (version \"1\") (kind \"bin\") (entry \"src/main.tl\") (dependencies (math (github \"JoNil-Botta/math\" (rev \"abc123\"))) (util (github \"github.com/JoNil-Botta/util.repo\" (tag \"v1.0.0\"))) (core \"../core\")))")
    [(OkCompilerPkgManifest m)
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
    [(ErrCompilerPkgManifest _) false]))

;: True when parsing `source` fails with exactly the `expected` diagnostic.
(define (compiler-load-manifest-rejects? [source : String] [expected : String]) : bool
  (match (compiler-load-parse-manifest source)
    [(ErrCompilerPkgManifest m) (string-eq m expected)]
    [(OkCompilerPkgManifest _) false]))

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
    [(ErrCompilerPkgManifestDiagnostic diag)
      (and
        (string-eq (compiler-diagnostic-path diag) path)
        (= (compiler-diagnostic-line diag) line)
        (= (compiler-diagnostic-col diag) col)
        (compiler-load-manifest-diagnostic-span-forward? diag)
        (string-eq (compiler-diagnostic-message diag) expected))]
    [(OkCompilerPkgManifestDiagnostic _) false]))

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
  (match (try-mkdir-if-missing (& path))
    [(OkIoUnit) true]
    [(ErrIoUnit _) false]))

(define (compiler-load-manifest-test-write [path : String] [contents : String]) : bool
  (match (try-write-file (& path) (& contents))
    [(OkIoUnit) true]
    [(ErrIoUnit _) false]))

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
    (read-file path))
    [(OkCompilerPkgManifestDiagnostic manifest)
      (and
        (string-eq (struct-get manifest entry) expected-entry)
        (match (struct-get manifest kind)
          [(CompilerPkgKindBin)
            (match expected-kind
              [(CompilerPkgKindBin) true]
              [(CompilerPkgKindLib) false])]
          [(CompilerPkgKindLib)
            (match expected-kind
              [(CompilerPkgKindLib) true]
              [(CompilerPkgKindBin) false])]))]
    [(ErrCompilerPkgManifestDiagnostic _) false]))

(define (compiler-load-manifest-path-rejects?
  [path : String]
  [expected : String]) : bool
  (match (compiler-load-parse-manifest-diagnostic-infer-kind
    path
    (read-file path))
    [(ErrCompilerPkgManifestDiagnostic diag)
      (string-eq (compiler-diagnostic-message diag) expected)]
    [(OkCompilerPkgManifestDiagnostic _) false]))

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
        [(OkCompilerLoadPackageEntry entry)
          (and
            (string-eq (struct-get entry owner) "entry_dep")
            (string-eq (struct-get entry entry-path) expected-entry))]
        [(ErrCompilerLoadPackageEntry _) false]))))

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

;: True when a StringVec is empty.
(define (compiler-load-link-vec-empty? [vec : StringVec]) : bool
  (= (string-vec-len vec) 0))

;: True when a StringVec holds exactly one value equal to `a`.
(define (compiler-load-link-vec-single? [vec : StringVec] [a : String]) : bool
  (and (= (string-vec-len vec) 1) (string-eq (string-vec-get vec 0 "") a)))

;: True when a StringVec holds exactly `a` then `b`, in order.
(define (compiler-load-link-vec-pair?
  [vec : StringVec]
  [a : String]
  [b : String]) : bool
  (and
    (= (string-vec-len vec) 2)
    (string-eq (string-vec-get vec 0 "") a)
    (string-eq (string-vec-get vec 1 "") b)))

;: Self-test: a `(link ...)` section parses into all-target and per-target sets
;: with manifest order preserved.
(define (compiler-load-manifest-link-valid-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"p\") (version \"1\") (kind \"bin\") (entry \"src/main.tl\") (link (libraries \"raylib\") (search-paths \"vendor/lib\") (linux-libraries \"GL\" \"m\") (linux-args \"-Wl,--as-needed\") (windows-libraries \"opengl32\")))")
    [(OkCompilerPkgManifest m)
      (let
        [link : CompilerPkgLink (struct-get m link)]
        [all : CompilerPkgLinkSet (struct-get link all)]
        [lin : CompilerPkgLinkSet (struct-get link linux)]
        [win : CompilerPkgLinkSet (struct-get link windows)]
        (and
          (compiler-load-link-vec-single? (struct-get all libraries) "raylib")
          (compiler-load-link-vec-single?
            (struct-get all search-paths)
            "vendor/lib")
          (compiler-load-link-vec-empty? (struct-get all args))
          (compiler-load-link-vec-pair? (struct-get lin libraries) "GL" "m")
          (compiler-load-link-vec-single?
            (struct-get lin args)
            "-Wl,--as-needed")
          (compiler-load-link-vec-single? (struct-get win libraries) "opengl32")))]
    [(ErrCompilerPkgManifest _) false]))

;: Self-test: a manifest with no `link` section parses with empty link sets.
(define (compiler-load-manifest-link-default-ok?) : bool
  (match (compiler-load-parse-manifest
    "(package (name \"p\") (version \"1\") (kind \"bin\") (entry \"src/main.tl\"))")
    [(OkCompilerPkgManifest m)
      (let
        [link : CompilerPkgLink (struct-get m link)]
        (and
          (compiler-load-link-vec-empty?
            (struct-get (struct-get link all) libraries))
          (compiler-load-link-vec-empty?
            (struct-get (struct-get link linux) libraries))
          (compiler-load-link-vec-empty?
            (struct-get (struct-get link windows) libraries))))]
    [(ErrCompilerPkgManifest _) false]))

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
    (if (= (string-ref s i) '/')
      i
      (compiler-load-slash-index-from s (+ i 1) n))))

;: True when a path is not a safe relative suffix below its package root.
(define (compiler-load-path-escapes? [path : String]) : bool
  (not (compiler-load-safe-relative? path)))

;: Look up a dependency's root path by import alias.
(define (compiler-load-pkg-dep-lookup
  [deps : CompilerPkgDeps]
  [target-alias : String]) : CompilerLoadMaybePath
  (match (string-string-map-get (struct-get deps aliases) target-alias)
    [(StringStringMapFound path) (CompilerLoadSomePath path)]
    [(StringStringMapMissing) (CompilerLoadNoPath)]))

;: Resolve `pkg:<alias>/<rest>` against `deps`, relative to `manifest-dir`.
(define (compiler-load-resolve-pkg-import
  [import-path : String]
  [manifest-dir : String]
  [deps : CompilerPkgDeps]) : ResultPkgResolve
  (let
    [body : String (substring import-path 4 (- (string-length import-path) 4))]
    [slash : i64 (compiler-load-slash-index-from body 0 (string-length body))]
    (if (< slash 0)
      (ErrPkgResolve
        (string-append
          "compiler-load: pkg import missing '/' after alias: "
          import-path))
      (let
        [alias : String (substring body 0 slash)]
        [rest : String
          (substring body (+ slash 1) (- (string-length body) (+ slash 1)))]
        (if (= (string-length alias) 0)
          (ErrPkgResolve
            (string-append
              "compiler-load: pkg import has empty alias: "
              import-path))
          (match (compiler-load-pkg-dep-lookup deps alias)
            [(CompilerLoadNoPath)
              (ErrPkgResolve
                (string-append
                  "compiler-load: unknown package alias '"
                  (string-append alias (string-append "': " import-path))))]
            [(CompilerLoadSomePath dep-path)
              (if (compiler-load-github-dependency-path? dep-path)
                (ErrPkgResolve
                  (string-append
                    "compiler-load: GitHub dependency '"
                    (string-append
                      alias
                      (string-append
                        "' requires fetch support (#1157): "
                        import-path))))
                (let
                  [norm-rest : String (compiler-load-normalize-path rest)]
                  (if (compiler-load-path-escapes? norm-rest)
                    (ErrPkgResolve
                      (string-append
                        "compiler-load: pkg import escapes package root: "
                        import-path))
                    (OkPkgResolve
                      (compiler-load-normalize-path
                        (compiler-load-join-root-path
                          (compiler-load-join-root-path manifest-dir dep-path)
                          norm-rest))))))]))))))

;: Parent directory of a directory path, or no-path at the top. `dirname`
;: returns a path *including* its trailing separator, so a trailing separator
;: is stripped first to make the walk-up progress (e.g. `src/` -> ``, the cwd).
(define (compiler-load-parent-dir [dir : String]) : CompilerLoadMaybePath
  (let
    [n : i64 (string-length dir)]
    (if (= n 0)
      (CompilerLoadNoPath)
      (let
        [trimmed : String
          (if (compiler-load-path-separator? (string-ref dir (- n 1)))
            (substring dir 0 (- n 1))
            dir)]
        [parent : String (compiler-load-dirname trimmed)]
        (if (string-eq parent dir)
          (CompilerLoadNoPath)
          (CompilerLoadSomePath parent))))))

;: Walk up from `dir` looking for a `typelisp.pkg` manifest, mirroring the Rust
;: `discover_manifest` (src/package.rs). `fuel` bounds the climb.
(define (compiler-load-discover-manifest-up [dir : String] [fuel : i64]) : CompilerLoadMaybePath
  (if (<= fuel 0)
    (CompilerLoadNoPath)
    (let
      [candidate : String (string-append dir "typelisp.pkg")]
      (if (file-exists? candidate)
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
    [(CompilerLoadNoPath) (OkPkgResolve import-path)]
    [(CompilerLoadSomePath manifest-path)
      (match (compiler-load-parse-manifest-diagnostic
        manifest-path
        (read-file manifest-path))
        [(ErrCompilerPkgManifestDiagnostic _) (OkPkgResolve import-path)]
        [(OkCompilerPkgManifestDiagnostic manifest)
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
    [(OkPkgResolve p) (string-eq p expected)]
    [(ErrPkgResolve _) false]))

;: True when resolving `import-path` fails with exactly `expected`.
(define (compiler-load-pkg-resolve-rejects?
  [import-path : String]
  [expected : String]) : bool
  (match (compiler-load-resolve-pkg-import
    import-path
    "proj"
    (compiler-load-pkg-resolve-deps))
    [(ErrPkgResolve m) (string-eq m expected)]
    [(OkPkgResolve _) false]))

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
    [(CompilerLoadSomePath p) (string-eq p expected)]
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
    (write-file "target/cl_vec_root_payload.tl" "(define v : i64 1)")
    (let
      [roots : StringVec
        (string-vec-push
          (string-vec-push (string-vec-new) "target/cl_vec_missing_root")
          "target")]
      (and
        (= (string-vec-len roots) 2)
        (string-eq (string-vec-get roots 0 "") "target/cl_vec_missing_root")
        (string-eq (string-vec-get roots 1 "") "target")
        (match (compiler-load-resolve-stdlib-root-raw
          "cl_vec_root_payload.tl"
          roots)
          [(CompilerLoadSomePath path)
            (string-eq path "target/cl_vec_root_payload.tl")]
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
    (string-eq
      (compiler-load-join-import-path "src/app/main.tl" "util.tl")
      "src/app/util.tl")
    ;; parent-directory (`..`) resolution end-to-end (join then normalize)
    (string-eq
      (compiler-load-normalize-path
        (compiler-load-join-import-path "src/app/main.tl" "../lib/helper.tl"))
      "src/lib/helper.tl")
    ;; absolute Unix-rooted import is preserved as-is (importer dir ignored)
    (string-eq
      (compiler-load-join-import-path "src/app/main.tl" "/opt/dep.tl")
      "/opt/dep.tl")
    ;; absolute Windows-drive import is preserved as-is
    (string-eq
      (compiler-load-join-import-path "src/app/main.tl" "C:/dep.tl")
      "C:/dep.tl")))

(define (compiler-load-test-path-at [paths : AstDeclPathList] [index : i64]) : String
  (match paths
    [(AstDeclPathNil) ""]
    [(AstDeclPathCons path rest)
      (if (= index 0)
        path
        (let
          [rest : AstDeclPathList (box-get rest)]
          (compiler-load-test-path-at rest (- index 1))))]))

(define (compiler-load-package-owner-paths-ok?) : bool
  (let
    [roots : StringVec (string-vec-push (string-vec-new) "C:/repo/stdlib")]
    [mixed-roots : StringVec
      (string-vec-push
        (string-vec-push (string-vec-new) "C:/repo/stdlib")
        "C:/repo/selfhost")]
    [runtime-decl : AstDecl
      (ast-decl-def-fn
        "runtime-helper"
        AstParamNil
        (AstTyI64)
        (ast-node-push (AstExprLiteral (ast-lit-int 1))))]
    [helper-decl : AstDecl
      (ast-decl-def-fn
        "helper"
        AstParamNil
        (AstTyI64)
        (ast-node-push (AstExprLiteral (ast-lit-int 2))))]
    [main-decl : AstDecl
      (ast-decl-def-fn
        "main"
        AstParamNil
        (AstTyI64)
        (ast-node-push (AstExprLiteral (ast-lit-int 0))))]
    [decls : AstDeclList
      (ast-decl-cons
        runtime-decl
        (ast-decl-cons helper-decl (ast-decl-cons main-decl AstDeclNil)))]
    [paths : AstDeclPathList
      (ast-decl-path-cons
        "C:/repo/stdlib/runtime.tl"
        (ast-decl-path-cons
          "C:/pkg/src/main.tl"
          (ast-decl-path-cons "C:/pkg/src/main.tl" AstDeclPathNil)))]
    [owned : AstDeclPathList
      (compiler-load-package-owned-paths-for-decls
        "app"
        "C:/pkg/"
        roots
        "C:/pkg/src/main.tl"
        decls
        paths)]
    [runtime-owned-ok : bool
      (string-eq (compiler-load-test-path-at owned 0) "stdlib/runtime.tl")]
    [helper-owned-ok : bool
      (string-eq (compiler-load-test-path-at owned 1) "app/src/main.tl")]
    [entry-main-ok : bool (string-eq (compiler-load-test-path-at owned 2) "")]
    [stdlib-normalized-ok : bool
      (string-eq
        (compiler-load-package-owned-path
          "app"
          "C:/pkg/"
          roots
          "stdlib/../stdlib/runtime.tl")
        "stdlib/runtime.tl")]
    [empty-root-owned-ok : bool
      (string-eq
        (compiler-load-package-owned-path "app" "" roots "src/main.tl")
        "app/src/main.tl")]
    [selfhost-root-owned-ok : bool
      (string-eq
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
        (string-vec-new)
        "C:/dep/src/lib.tl"
        ""
        (intern "helper")
        AstParamNil
        (AstTyI64))]
    (match decl
      [(AstDeclExtern _ _ metadata _)
        (string-eq
          (ast-extern-metadata-symbol metadata)
          "_tl_dep_src_lib_helper")]
      [_ false])))

(define (compiler-load-self-test) : i64
  (begin
    (unless
      (compiler-load-normalize-ok?)
      (return
        (begin
          (panic "compiler-load: normalize smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-relative-resolution-ok?)
      (return
        (begin
          (panic "compiler-load: relative resolution smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-package-owner-paths-ok?)
      (return
        (begin
          (panic "compiler-load: package owner path smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-package-owner-extern-symbol-ok?)
      (return
        (begin
          (panic "compiler-load: package owner extern symbol smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-source-provenance-ok?)
      (return
        (begin
          (panic "compiler-load: source provenance smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-expected-module-conflict-ok?)
      (return
        (begin
          (panic "compiler-load: expected module smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-duplicate-module-ok?)
      (return
        (begin
          (panic "compiler-load: duplicate module smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-seen-module-ok?)
      (return
        (begin
          (panic "compiler-load: seen module smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-cfg-import-ok?)
      (return
        (begin
          (panic "compiler-load: cfg import smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-session-cache-common-dep-ok?)
      (return
        (begin
          (panic "compiler-load: session cache common dep smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-session-cache-root-isolation-ok?)
      (return
        (begin
          (panic "compiler-load: session cache root isolation smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-session-cache-entry-cold-ok?)
      (return
        (begin
          (panic "compiler-load: session cache entry cold smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-session-cache-local-common-dep-ok?)
      (return
        (begin
          (panic "compiler-load: session cache local common dep smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-session-cache-package-common-dep-ok?)
      (return
        (begin
          (panic
            "compiler-load: session cache package common dep smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-file-import-dedup-cycle-ok?)
      (return
        (begin
          (panic "compiler-load: import dedup/cycle smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-file-fallback-path-dedup-ok?)
      (return
        (begin
          (panic "compiler-load: fallback path dedup smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-import-module-restore-ok?)
      (return
        (begin
          (panic "compiler-load: import module restore smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-import-alias-preserved-ok?)
      (return
        (begin
          (panic "compiler-load: import alias preservation smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-legacy-path-module-flat-alias-ok?)
      (return
        (begin
          (panic "compiler-load: legacy path module flat alias smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-seen-legacy-path-module-flat-alias-ok?)
      (return
        (begin
          (panic
            "compiler-load: seen legacy path module flat alias smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-package-legacy-path-module-flat-alias-ok?)
      (return
        (begin
          (panic
            "compiler-load: package legacy path module flat alias smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-package-seen-legacy-path-module-flat-alias-ok?)
      (return
        (begin
          (panic
            "compiler-load: package seen legacy path module flat alias smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-dotted-import-duplicate-alias-ok?)
      (return
        (begin
          (panic "compiler-load: dotted import duplicate alias smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-dotted-import-resolution-ok?)
      (return
        (begin
          (panic "compiler-load: dotted import resolution smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-dotted-source-root-ok?)
      (return
        (begin
          (panic "compiler-load: dotted source root smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-package-dotted-import-resolution-ok?)
      (return
        (begin
          (panic
            "compiler-load: package dotted import resolution smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-generated-meta-preserved-ok?)
      (return
        (begin
          (panic
            "compiler-load: generated metadata preservation smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-diamond-import-ok?)
      (return
        (begin
          (panic "compiler-load: diamond import smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-transitive-import-ok?)
      (return
        (begin
          (panic "compiler-load: transitive import smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-missing-import-ok?)
      (return
        (begin
          (panic "compiler-load: missing import smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-include-str-relative-ok?)
      (return
        (begin
          (panic "compiler-load: include-str relative smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-include-str-stdlib-root-ok?)
      (return
        (begin
          (panic "compiler-load: include-str stdlib root smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-missing-include-str-ok?)
      (return
        (begin
          (panic "compiler-load: missing include-str smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-include-str-raw-text-ok?)
      (return
        (begin
          (panic "compiler-load: include-str raw text smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-include-bin-relative-ok?)
      (return
        (begin
          (panic "compiler-load: include-bin relative smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-missing-include-bin-ok?)
      (return
        (begin
          (panic "compiler-load: missing include-bin smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-embedded-stdlib-lookup-ok?)
      (return
        (begin
          (panic "compiler-load: embedded stdlib lookup smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-embedded-stdlib-missing-ok?)
      (return
        (begin
          (panic "compiler-load: embedded stdlib missing smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-embedded-stdlib-escape-rejected-ok?)
      (return
        (begin
          (panic "compiler-load: embedded stdlib escape smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-imported-parse-error-path-ok?)
      (return
        (begin
          (panic "compiler-load: imported parse error path smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-imported-duplicate-module-path-ok?)
      (return
        (begin
          (panic "compiler-load: imported duplicate module path smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-stdlib-root-fallback-ok?)
      (return
        (begin
          (panic "compiler-load: stdlib root fallback smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-stdlib-searched-root-ok?)
      (return
        (begin
          (panic "compiler-load: stdlib searched root smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-stdlib-unresolved-ok?)
      (return
        (begin
          (panic "compiler-load: stdlib unresolved smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-stdlib-root-escape-rejected-ok?)
      (return
        (begin
          (panic "compiler-load: stdlib root escape smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-pkg-manifest-ok?)
      (return
        (begin
          (panic "compiler-load: pkg manifest smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-manifest-path-inference-ok?)
      (return
        (begin
          (panic "compiler-load: manifest path inference smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-pkg-resolve-ok?)
      (return
        (begin
          (panic "compiler-load: pkg resolve smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-pkg-parent-dir-ok?)
      (return
        (begin
          (panic "compiler-load: pkg parent-dir smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-string-vec-roots-ok?)
      (return
        (begin
          (panic "compiler-load: string vec roots smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    (unless
      (compiler-load-boxed-pkg-dep-list-ok?)
      (return
        (begin
          (panic "compiler-load: boxed pkg-dep-list smoke mismatch")
          ;; lint-allow: unreachable-code
          0)))
    42))