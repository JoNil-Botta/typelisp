;; compiler_prelude_surface_producer.tl - build the stdlib prelude deployment
;; of the generic package frontend-surface schemas.
(import "compiler_load.tl")
(import "compiler_surface_ast.tl")
(import "compiler_typecheck_api.tl")
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_surface_facts as surface_facts)
(import compiler_surface_identity as surface_identity)
(import stdlib.arena)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as surface_svec)

(defenum ResultPreludeSurface
  (Ok (Array u8))
  (Err String))

(defenum ResultPreludeSurfaceFacts
  (Ok surface_facts.SurfaceTypecheckFacts AstProgram AstDeclPathList)
  (Err String))

(define (prelude-surface-path-present?
  [items : (& items surface_svec.Vec)]
  [path : String]) : bool
  (let
    [index : i64 0]
    [present : bool false]
    (begin
      (while (and (not present) (< index (surface_svec.len items)))
        (if (string.eq (surface_svec.get items index "") path)
          (set! present true)
          (set! index (+ index 1))))
      present)))

(define (prelude-surface-module-set [paths : AstDeclPathList]) : (Array String)
  (let
    [items : surface_svec.Vec (surface_svec.new)]
    [index : i64 0]
    [count : i64 (ast-decl-path-list-len (& paths))]
    (begin
      (while (< index count)
        (let
          [path : String
            (array-ref
              (struct-get paths slots)
              (+ (struct-get paths offset) index))]
          (begin
            (if (prelude-surface-path-present? (& items) path)
              unit
              (surface_svec.push (&mut items) path))
            (set! index (+ index 1)))))
      (let
        [out : (Array String) (surface_svec.to-array (& items))]
        [sort-index : i64 1]
        (begin
          (while (< sort-index (array-length out))
            (let
              [value : String (array-ref out sort-index)]
              [scan : i64 sort-index]
              (begin
                (while (and
                  (> scan 0)
                  (surface_identity.surface-identity-string-less?
                    value
                    (array-ref out (- scan 1))))
                  (begin
                    (array-set! out scan (array-ref out (- scan 1)))
                    (set! scan (- scan 1))))
                (array-set! out scan value)
                (set! sort-index (+ sort-index 1)))))
          out)))))

(define (prelude-surface-target-cfgs [windows-target : bool]) : sym_i64_env.SymI64Env
  (let
    [cfgs : sym_i64_env.SymI64Env (compiler-cfg-empty)]
    (if windows-target
      (compiler-cfg-enable
        (compiler-cfg-enable
          (compiler-cfg-enable cfgs "windows")
          "target-windows")
        "os-windows")
      (compiler-cfg-enable
        (compiler-cfg-enable
          (compiler-cfg-enable (compiler-cfg-enable cfgs "linux") "unix")
          "target-linux")
        "os-linux"))))

(define (prelude-surface-load-cold
  [load-state : CompilerLoadSessionState]
  [roots : surface_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultCompilerLoadWithPaths
  (match (compiler-load-stdlib-prelude-file-with-roots-cfg-with-pools
    load-state
    compiler-load-runtime-prelude-path
    (sym_i64_env.sym-i64-empty)
    roots
    cfgs
    pools)
    [(ResultCompilerLoadWithPaths.Ok
        runtime-decls
        runtime-paths
        runtime-modules
        runtime-seen)
      (match (compiler-load-core-macro-prelude-with-roots-cfg-with-pools
        load-state
        runtime-seen
        roots
        cfgs
        pools)
        [(ResultCompilerLoadWithPaths.Ok
            macro-decls
            macro-paths
            macro-modules
            macro-seen)
          (ResultCompilerLoadWithPaths.Ok
            (compiler-load-decl-list-append runtime-decls macro-decls)
            (compiler-load-decl-path-list-append runtime-paths macro-paths)
            (compiler-load-decl-module-list-append
              runtime-modules
              macro-modules)
            macro-seen)]
        [(ResultCompilerLoadWithPaths.Err diag)
          (ResultCompilerLoadWithPaths.Err diag)])]
    [(ResultCompilerLoadWithPaths.Err diag)
      (ResultCompilerLoadWithPaths.Err diag)]))

(define (prelude-surface-facts-error
  [prefix : String]
  [diag : (Box CompilerDiagnostic)]) : ResultPreludeSurfaceFacts
  (ResultPreludeSurfaceFacts.Err
    (str-cat prefix (compiler-diagnostic-render (box-get diag)))))

(define (prelude-surface-typecheck-facts-specialized
  [program : AstProgram]
  [paths : AstDeclPathList]
  [surface-program : AstProgram]
  [surface-paths : AstDeclPathList]
  [macro-decl-count : i64]
  [roots : surface_svec.Vec]
  [pools : AstNodePoolContext]) : ResultPreludeSurfaceFacts
  (let
    [decl-count : i64
      (match program
        [(AstProgram.Program decls-box)
          (ast-decl-list-len (& (box-get decls-box)))])]
    [_select-all-clone-roots : unit (tc-clone-root-collection-use! program)]
    [_start-fact-recording : unit
      (surface_facts.surface-typecheck-facts-recording-start!
        (arena.tl_arena_current))]
    [_start-early-exit-facts : unit (tc-body-early-exit-facts-start! pools)]
    [checked : ResultCompilerTypecheckChecked
      (typecheck-compiler-specialized-program-with-paths-checked-cache-with-pools-and-source-names
        program
        paths
        roots
        (tc-prefix-default-cache-scope)
        pools
        (ci.intern-source-name-session-capture-active-handle))]
    (match checked
      [(ResultCompilerTypecheckChecked.Err diag)
        (begin
          (tc-body-early-exit-facts-abort!)
          (tc-clone-root-collection-abort!)
          (surface_facts.surface-typecheck-facts-recording-abort!)
          (prelude-surface-facts-error
            "prelude surface typecheck failed: "
            diag))]
      [(ResultCompilerTypecheckChecked.Ok summary ctx _ _)
        (let
          [_finish-early-exit-facts : unit (tc-body-early-exit-facts-finish!)]
          [_finish-clone-roots : CloneNameList
            (tc-clone-root-collection-finish! ctx)]
          (match summary
            [(CompilerTypecheckSummary values functions externs)
              (ResultPreludeSurfaceFacts.Ok
                (surface_facts.surface-typecheck-facts-recording-finish
                  macro-decl-count
                  decl-count
                  values
                  functions
                  externs)
                surface-program
                surface-paths)]))])))

(define (prelude-surface-typecheck-facts-expanded
  [expanded : AstProgram]
  [expanded-paths : AstDeclPathList]
  [roots : surface_svec.Vec]
  [pools : AstNodePoolContext]) : ResultPreludeSurfaceFacts
  (let
    [macro-decl-count : i64
      (match expanded
        [(AstProgram.Program decls-box)
          (ast-decl-list-len (& (box-get decls-box)))])]
    (if (compiler-specialize-needed-with-pools expanded pools)
      (match (compiler-specialize-program-with-paths-and-pools
        expanded
        expanded-paths
        ""
        pools)
        [(ResultSpecProgramWithPaths.Err diag)
          (prelude-surface-facts-error
            "prelude surface specialization failed: "
            diag)]
        [(ResultSpecProgramWithPaths.Ok specialized specialized-paths)
          (prelude-surface-typecheck-facts-specialized
            specialized
            specialized-paths
            expanded
            expanded-paths
            macro-decl-count
            roots
            pools)])
      (prelude-surface-typecheck-facts-specialized
        expanded
        expanded-paths
        expanded
        expanded-paths
        macro-decl-count
        roots
        pools))))

(define (prelude-surface-typecheck-facts
  [load-state : CompilerLoadSessionState]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [roots : surface_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]) : ResultPreludeSurfaceFacts
  (match (gen-normalize-program-with-paths-and-pools
    (ast-program decls)
    paths
    ""
    pools)
    [(ResultGenProgramWithPaths.Err diag)
      (prelude-surface-facts-error
        "prelude surface normalization failed: "
        diag)]
    [(ResultGenProgramWithPaths.Ok generated generated-paths)
      (match (macro-expand-program-with-paths-and-pools-roots-cfg-and-source-names
        load-state
        generated
        generated-paths
        pools
        (ci.intern-source-name-session-capture-active-handle)
        roots
        cfgs)
        [(ResultMacroExpand.Err diag)
          (prelude-surface-facts-error
            "prelude surface expansion failed: "
            diag)]
        [(ResultMacroExpand.Ok expanded expanded-paths)
          (prelude-surface-typecheck-facts-expanded
            expanded
            expanded-paths
            roots
            pools)])]))

(define (prelude-surface-pack
  [identity-bytes : (Array u8)]
  [ast-bytes : (Array u8)]
  [fact-bytes : (Array u8)]) : ResultPreludeSurface
  (let
    [sections : (Array TlciAuxSection) (make-array TlciAuxSection 3)]
    (begin
      (array-set!
        sections
        0
        (TlciAuxSection tlci-aux-kind-package-identity 1 identity-bytes))
      (array-set!
        sections
        1
        (TlciAuxSection tlci-aux-kind-frontend-ast 1 ast-bytes))
      (array-set!
        sections
        2
        (TlciAuxSection
          tlci-aux-kind-frontend-facts
          surface_facts.surface-typecheck-facts-schema-version
          fact-bytes))
      (match (tlci-aux-pack-rodata (tlci-empty-bytes) sections)
        [(ResultTlciAuxBytes.Err message) (ResultPreludeSurface.Err message)]
        [(ResultTlciAuxBytes.Ok rodata) (ResultPreludeSurface.Ok rodata)]))))

(define (prelude-surface-encode-payloads
  [identity-payload : surface_identity.SurfaceIdentityPayload]
  [facts : surface_facts.SurfaceTypecheckFacts]
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [modules : AstDeclModuleList]
  [seen : sym_i64_env.SymI64Env]
  [pools : AstNodePoolContext]
  [source-count : i64]
  [identity-count : i64]) : ResultPreludeSurface
  (match (surface_identity.surface-identity-encode identity-payload)
    [(surface_identity.ResultSurfaceIdentityBytes.Err message)
      (ResultPreludeSurface.Err message)]
    [(surface_identity.ResultSurfaceIdentityBytes.Ok identity-bytes)
      (match (surface-ast-encode
        decls
        paths
        modules
        seen
        pools
        source-count
        identity-count)
        [(ResultSurfaceAstBytes.Err message) (ResultPreludeSurface.Err message)]
        [(ResultSurfaceAstBytes.Ok ast-bytes)
          (match (surface_facts.surface-typecheck-facts-encode
            facts
            source-count
            identity-count)
            [(surface_facts.ResultSurfaceTypecheckFactBytes.Err message)
              (ResultPreludeSurface.Err message)]
            [(surface_facts.ResultSurfaceTypecheckFactBytes.Ok fact-bytes)
              (prelude-surface-pack identity-bytes ast-bytes fact-bytes)])])]))

(define (prelude-surface-build
  [root : String]
  [source-hash : String]
  [build-hash : String]
  [windows-target : bool]) : ResultPreludeSurface
  (let
    [previous-arena : i64 (arena.tl_arena_current)]
    [surface-arena : i64 (arena.tl_arena_make)]
    [_set-surface-arena : unit
      (unsafe
        (arena.tl_arena_set surface-arena))]
    [_reset-interns : unit (ci.intern-reset!)]
    [_reset-builtins : unit (cbi.compiler-builtin-reset!)]
    [roots : surface_svec.Vec (surface_svec.new)]
    [pools : AstNodePoolContext
      (ast-node-pool-context-new-with-capacities-in-arena
        131072
        8192
        surface-arena)]
    [load-state : CompilerLoadSessionState (compiler-load-session-state-new)]
    (begin
      (surface_svec.push (&mut roots) root)
      (match (prelude-surface-load-cold
        load-state
        roots
        (prelude-surface-target-cfgs windows-target)
        pools)
        [(ResultCompilerLoadWithPaths.Err diag)
          (begin
            (unsafe
              (arena.tl_arena_set previous-arena))
            (ResultPreludeSurface.Err
              (str-cat
                "prelude surface load failed: "
                (compiler-diagnostic-render (box-get diag)))))]
        [(ResultCompilerLoadWithPaths.Ok decls paths modules seen)
          (match (prelude-surface-typecheck-facts
            load-state
            decls
            paths
            roots
            (prelude-surface-target-cfgs windows-target)
            pools)
            [(ResultPreludeSurfaceFacts.Err message)
              (begin
                (unsafe
                  (arena.tl_arena_set previous-arena))
                (ResultPreludeSurface.Err message))]
            [(ResultPreludeSurfaceFacts.Ok facts surface-program surface-paths)
              (let
                [module-set : (Array String) (prelude-surface-module-set paths)]
                [surface-decls : AstDeclList
                  (match surface-program
                    [(AstProgram.Program decls-box) (box-get decls-box)])]
                [key : surface_identity.SurfaceIdentityKey
                  (surface_identity.SurfaceIdentityKey
                    "stdlib.prelude"
                    module-set
                    source-hash
                    build-hash
                    (if windows-target
                      "windows-default"
                      "linux-default"))]
                [identity-payload : surface_identity.SurfaceIdentityPayload
                  (surface_identity.surface-identity-capture key)]
                [source-count : i64
                  (array-length (struct-get identity-payload source-names))]
                [identity-count : i64
                  (+
                    source-count
                    (array-length (struct-get identity-payload generated)))]
                (begin
                  (unsafe
                    (arena.tl_arena_set previous-arena))
                  (prelude-surface-encode-payloads
                    identity-payload
                    facts
                    surface-decls
                    surface-paths
                    modules
                    seen
                    pools
                    source-count
                    identity-count)))])]))))