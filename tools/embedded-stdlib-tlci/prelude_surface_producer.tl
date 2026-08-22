;; prelude_surface_producer.tl - standalone stdlib prelude frontend-surface
;; builder used by the embedded-stdlib TLCI tool.
(import compiler_load as load)
(import compiler_ast_types as ast)
(import compiler_clone as clone)
(import compiler_diagnostic as cdiag)
(import compiler_prelude_surface_producer as prelude_shared)
(import compiler_specialize as spec)
(import compiler_surface_ast as surface_ast)
(import compiler_typecheck_core as tc)
(import tlci_core as tlci)
(import compiler_cfg_core as cfg_core)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_surface_facts as surface_facts)
(import compiler_surface_identity as surface_identity)
(import stdlib.arena)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.vector)
(import sym_i64_env as cfg_env)
(import (vector.vector String) as surface_svec)

(defenum ResultPreludeSurface
  (Ok (__tl_dyn-array u8))
  (Err String))

(defenum ResultPreludeSurfaceFacts
  (Ok
    surface_facts.SurfaceTypecheckFacts
    ast.AstProgram
    ast.AstDeclPathList
    ci.InternSourceNameSessionHandle)
  (Err String))

(define (prelude-surface-target-cfgs [windows-target : bool]) : cfg_env.SymI64Env
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (let
      [cfgs : cfg_env.SymI64Env (cfg_core.compiler-cfg-empty)]
      (if windows-target
        (cfg_core.compiler-cfg-enable
          (cfg_core.compiler-cfg-enable
            (cfg_core.compiler-cfg-enable cfgs "windows")
            "target-windows")
          "os-windows")
        (cfg_core.compiler-cfg-enable
          (cfg_core.compiler-cfg-enable
            (cfg_core.compiler-cfg-enable
              (cfg_core.compiler-cfg-enable cfgs "linux")
              "unix")
            "target-linux")
          "os-linux")))))

(define (prelude-surface-load-cold
  [load-state : load.CompilerLoadSessionState]
  [roots : surface_svec.Vec]
  [cfgs : cfg_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : load.ResultCompilerLoadWithPaths
  (match (load.compiler-load-stdlib-prelude-file-with-roots-cfg-with-pools
    (load.compiler-load-session-state-shared-view (& load-state))
    (load.compiler-load-runtime-prelude-path-shared-view)
    (cfg_env.sym-i64-empty)
    (owned_view.compiler-owned-shared-view roots)
    (cfg_env.sym-i64-shared-view (& cfgs))
    (ast.ast-place-shared-view pools))
    [(load.ResultCompilerLoadWithPaths.Ok
        runtime-decls
        runtime-paths
        runtime-modules
        runtime-seen)
      (match (load.compiler-load-core-macro-prelude-with-roots-cfg-with-pools
        (load.compiler-load-session-state-shared-view (& load-state))
        runtime-seen
        (owned_view.compiler-owned-shared-view roots)
        (cfg_env.sym-i64-shared-view (& cfgs))
        (ast.ast-place-shared-view pools))
        [(load.ResultCompilerLoadWithPaths.Ok
            macro-decls
            macro-paths
            macro-modules
            macro-seen)
          (load.ResultCompilerLoadWithPaths.Ok
            (load.compiler-load-decl-list-append runtime-decls macro-decls)
            (load.compiler-load-decl-path-list-append runtime-paths macro-paths)
            (load.compiler-load-decl-module-list-append
              runtime-modules
              macro-modules)
            macro-seen)]
        [(load.ResultCompilerLoadWithPaths.Err diag)
          (load.ResultCompilerLoadWithPaths.Err diag)])]
    [(load.ResultCompilerLoadWithPaths.Err diag)
      (load.ResultCompilerLoadWithPaths.Err diag)]))

(define (prelude-surface-facts-error
  [prefix : String]
  [diag : (Box cdiag.CompilerDiagnostic)]) : ResultPreludeSurfaceFacts
  (ResultPreludeSurfaceFacts.Err
    (str_cat.str-cat
      prefix
      (cdiag.compiler-diagnostic-render
        (cdiag.compiler-diagnostic-box-shared-view diag)))))

(define (prelude-surface-typecheck-facts-specialized
  [load-state : load.CompilerLoadSessionState]
  [prefix-cache : tc.TcPrefixSnapshotCacheState]
  [job-state : tc.TcJobState]
  [source-names : ci.InternSourceNameSessionHandle]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [surface-program : ast.AstProgram]
  [surface-paths : ast.AstDeclPathList]
  [macro-decl-count : i64]
  [roots : surface_svec.Vec]
  [pools : ast.AstNodePoolContext]) : ResultPreludeSurfaceFacts
  (let
    [decl-count : i64
      (match (ast.ast-place-shared-view program)
        [(ast.AstProgram.Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            (ast.ast-decl-list-len (& decls)))])]
    [_select-all-clone-roots : unit
      (tc.tc-clone-root-collection-use! (ast.ast-place-shared-view program))]
    [_start-fact-recording : unit
      (surface_facts.surface-typecheck-facts-recording-start!
        (arena.tl_arena_current))]
    [checked : tc.ResultCompilerTypecheckChecked
      (tc.typecheck-compiler-specialized-program-with-paths-checked-cache-with-pools-and-source-names-and-prefix-cache-state-and-intern-state
        load-state
        prefix-cache
        job-state
        program
        paths
        roots
        (tc.tc-prefix-default-cache-scope)
        pools
        source-names
        (ci.intern-compat-state-capture-active))]
    (match checked
      [(tc.ResultCompilerTypecheckChecked.Partial diag _ _ _)
        (begin
          (tc.tc-clone-root-collection-abort!)
          (surface_facts.surface-typecheck-facts-recording-abort!)
          (prelude-surface-facts-error
            "prelude surface typecheck failed: "
            (box (cdiag.compiler-diagnostic-list-first (deref diag)))))]
      [(tc.ResultCompilerTypecheckChecked.Err diag)
        (begin
          (tc.tc-clone-root-collection-abort!)
          (surface_facts.surface-typecheck-facts-recording-abort!)
          (prelude-surface-facts-error
            "prelude surface typecheck failed: "
            (box
              (cdiag.compiler-diagnostic-list-first
                (cdiag.compiler-diagnostic-list-box-shared-view diag)))))]
      [(tc.ResultCompilerTypecheckChecked.Ok summary ctx _ _)
        (let
          [_finish-clone-roots : clone.CloneRootEntries
            (tc.tc-clone-root-collection-finish! ctx)]
          (match summary
            [(tc.CompilerTypecheckSummary values functions externs)
              (ResultPreludeSurfaceFacts.Ok
                (surface_facts.surface-typecheck-facts-recording-finish
                  macro-decl-count
                  decl-count
                  values
                  functions
                  externs)
                surface-program
                surface-paths
                source-names)]))])))

(define (prelude-surface-typecheck-facts-expanded
  [load-state : load.CompilerLoadSessionState]
  [prefix-cache : tc.TcPrefixSnapshotCacheState]
  [job-state : tc.TcJobState]
  [source-names : ci.InternSourceNameSessionHandle]
  [expanded : ast.AstProgram]
  [expanded-paths : ast.AstDeclPathList]
  [roots : surface_svec.Vec]
  [pools : ast.AstNodePoolContext]) : ResultPreludeSurfaceFacts
  (let
    [macro-decl-count : i64
      (match (ast.ast-place-shared-view expanded)
        [(ast.AstProgram.Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            (ast.ast-decl-list-len (& decls)))])]
    (if (spec.compiler-specialize-needed-with-pools
      (ast.ast-place-shared-view expanded)
      (ast.ast-place-shared-view pools))
      (match (spec.compiler-specialize-program-with-paths-and-pools
        (ast.ast-place-shared-view expanded)
        (ast.ast-place-shared-view expanded-paths)
        ""
        (ast.ast-place-shared-view pools))
        [(spec.ResultSpecProgramWithPaths.Err diag)
          (prelude-surface-facts-error
            "prelude surface specialization failed: "
            diag)]
        [(spec.ResultSpecProgramWithPaths.Ok specialized specialized-paths)
          (prelude-surface-typecheck-facts-specialized
            load-state
            prefix-cache
            job-state
            source-names
            specialized
            specialized-paths
            (ast.ast-place-shared-view expanded)
            (ast.ast-place-shared-view expanded-paths)
            macro-decl-count
            roots
            pools)])
      (prelude-surface-typecheck-facts-specialized
        load-state
        prefix-cache
        job-state
        source-names
        (ast.ast-place-shared-view expanded)
        (ast.ast-place-shared-view expanded-paths)
        expanded
        expanded-paths
        macro-decl-count
        roots
        pools))))

(define (prelude-surface-typecheck-facts
  [load-state : load.CompilerLoadSessionState]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [roots : surface_svec.Vec]
  [cfgs : cfg_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultPreludeSurfaceFacts
  (let
    [prefix-cache : tc.TcPrefixSnapshotCacheState
      (tc.tc-prefix-snapshot-cache-state-new)]
    [job-state : tc.TcJobState (tc.tc-job-state-new)]
    [source-names : ci.InternSourceNameSessionHandle
      (ci.intern-source-name-session-capture-active-handle)]
    (match (spec.gen-normalize-program-with-paths-and-pools
      (ast.ast-program decls)
      paths
      ""
      (ast.ast-place-shared-view pools))
      [(spec.ResultGenProgramWithPaths.Err diag)
        (prelude-surface-facts-error
          "prelude surface normalization failed: "
          diag)]
      [(spec.ResultGenProgramWithPaths.Ok generated generated-paths)
        (match (tc.macro-expand-program-with-paths-and-pools-roots-cfg-and-source-names-and-job-state
          (load.compiler-load-session-state-shared-view (& load-state))
          generated
          generated-paths
          (ast.ast-place-shared-view pools)
          (owned_view.compiler-owned-shared-view source-names)
          (owned_view.compiler-owned-shared-view job-state)
          (owned_view.compiler-owned-shared-view roots)
          (cfg_env.sym-i64-shared-view (& cfgs)))
          [(tc.ResultMacroExpand.Err diag)
            (prelude-surface-facts-error
              "prelude surface expansion failed: "
              diag)]
          [(tc.ResultMacroExpand.Ok expanded expanded-paths)
            (prelude-surface-typecheck-facts-expanded
              load-state
              prefix-cache
              job-state
              source-names
              expanded
              expanded-paths
              roots
              pools)])])))

(define (prelude-surface-pack
  [identity-bytes : (__tl_dyn-array u8)]
  [ast-bytes : (__tl_dyn-array u8)]
  [fact-bytes : (__tl_dyn-array u8)]) : ResultPreludeSurface
  (let
    [sections : (__tl_dyn-array tlci.TlciAuxSection)
      (__tl_make-array tlci.TlciAuxSection 3)]
    (begin
      (set!
        (array-ref sections 0)
        (tlci.TlciAuxSection
          tlci.tlci-aux-kind-package-identity
          surface_identity.surface-identity-schema-version
          identity-bytes))
      (set!
        (array-ref sections 1)
        ;; The aux section's schema-version is what
        ;; `compiler_surface_hydrate.tl` compares against
        ;; `surface-ast-schema-version`; it must BE that constant, not a
        ;; literal that happens to equal it. The facts section below
        ;; already does this correctly.
        (tlci.TlciAuxSection
          tlci.tlci-aux-kind-frontend-ast
          surface_ast.surface-ast-schema-version
          ast-bytes))
      (set!
        (array-ref sections 2)
        (tlci.TlciAuxSection
          tlci.tlci-aux-kind-frontend-facts
          surface_facts.surface-typecheck-facts-schema-version
          fact-bytes))
      (match (tlci.tlci-aux-pack-rodata (tlci.tlci-empty-bytes) sections)
        [(tlci.ResultTlciAuxBytes.Err message)
          (ResultPreludeSurface.Err message)]
        [(tlci.ResultTlciAuxBytes.Ok rodata) (ResultPreludeSurface.Ok rodata)]))))

(define (prelude-surface-encode-payloads
  [structural-session : cis.InternStructuralSessionHandle]
  [identity-payload : surface_identity.SurfaceIdentityPayload]
  [facts : surface_facts.SurfaceTypecheckFacts]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [modules : ast.AstDeclModuleList]
  [seen : cfg_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [source-count : i64]
  [identity-count : i64]) : ResultPreludeSurface
  (match (surface_identity.surface-identity-encode identity-payload)
    [(surface_identity.ResultSurfaceIdentityBytes.Err message)
      (ResultPreludeSurface.Err message)]
    [(surface_identity.ResultSurfaceIdentityBytes.Ok identity-bytes)
      (match (surface_ast.surface-ast-encode
        structural-session
        decls
        paths
        modules
        seen
        pools
        source-count
        identity-count)
        [(surface_ast.ResultSurfaceAstBytes.Err message)
          (ResultPreludeSurface.Err message)]
        [(surface_ast.ResultSurfaceAstBytes.Ok ast-bytes)
          (match (surface_facts.surface-typecheck-facts-encode
            facts
            structural-session
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
    [_guard-live-session : unit
      (when
        (load.compiler-load-active-session-live?)
        (return
          (ResultPreludeSurface.Err
            "prelude-surface-build: standalone resetting compiler entry cannot run inside an active compiler load session")))]
    [previous-arena : i64 (arena.tl_arena_current)]
    [surface-arena : i64 (arena.tl_arena_make)]
    [_set-surface-arena : unit
      (unsafe
        (arena.tl_arena_set surface-arena))]
    [_reset-interns : unit (ci.intern-reset!)]
    [_reset-builtins : unit (cbi.compiler-builtin-reset!)]
    [roots : surface_svec.Vec (surface_svec.new)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities-in-arena
        131072
        8192
        surface-arena)]
    [load-state : load.CompilerLoadSessionState
      (load.compiler-load-session-state-new)]
    (begin
      (surface_svec.push-ref! (&mut roots) root)
      (match (prelude-surface-load-cold
        (load.compiler-load-session-state-shared-view (& load-state))
        (owned_view.compiler-owned-shared-view roots)
        (prelude-surface-target-cfgs windows-target)
        (ast.ast-place-shared-view pools))
        [(load.ResultCompilerLoadWithPaths.Err diag)
          (begin
            (unsafe
              (arena.tl_arena_set previous-arena))
            (ResultPreludeSurface.Err
              (str_cat.str-cat
                "prelude surface load failed: "
                (cdiag.compiler-diagnostic-render
                  (cdiag.compiler-diagnostic-box-shared-view diag)))))]
        [(load.ResultCompilerLoadWithPaths.Ok decls paths modules seen)
          (match (prelude-surface-typecheck-facts
            load-state
            decls
            (ast.ast-place-shared-view paths)
            roots
            (prelude-surface-target-cfgs windows-target)
            (ast.ast-place-shared-view pools))
            [(ResultPreludeSurfaceFacts.Err message)
              (begin
                (unsafe
                  (arena.tl_arena_set previous-arena))
                (ResultPreludeSurface.Err message))]
            [(ResultPreludeSurfaceFacts.Ok
                facts
                surface-program
                surface-paths
                source-names)
              (let
                [module-set : (__tl_dyn-array String)
                  (prelude_shared.prelude-surface-module-set paths)]
                [surface-decls : ast.AstDeclList
                  (match surface-program
                    [(ast.AstProgram.Program decls-box)
                      (ast.ast-decl-list-box-shared-view decls-box)])]
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
                  (array-length identity-payload.source-names)]
                [identity-count : i64
                  (+ source-count (array-length identity-payload.generated))]
                (begin
                  (unsafe
                    (arena.tl_arena_set previous-arena))
                  (prelude-surface-encode-payloads
                    (cis.intern-structural-session-handle-from-source-names
                      source-names)
                    identity-payload
                    facts
                    surface-decls
                    surface-paths
                    modules
                    seen
                    pools
                    source-count
                    identity-count)))])]))))