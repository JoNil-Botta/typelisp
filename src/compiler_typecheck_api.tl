;; compiler_typecheck_api.tl - Public typechecker API used by compiler tools.
(import compiler_owned_view as owned_view)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_typecheck_core as tc_core)
(import compiler_load as load)
(import compiler_specialize as spec)
(import compiler_ast_types as ast)
(import compiler_symbols as csym)
(import compiler_cfg_core as cfg_core)
(import compiler_parse_core as parser)
(import compiler_diagnostic as cdiag)
(import sym_i64_env)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)

(define (compiler-typecheck-context-program [ctx : tc_core.TcContext]) : ast.AstProgram
  (tc_core.tc-context-program ctx))

(define (compiler-typecheck-prefix-cache-scope
  [kind : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : String
  (load.compiler-load-prelude-cache-key kind stdlib-roots cfgs))

(define (compiler-typecheck-reset-load-session!) : unit
  (begin
    (load.compiler-load-session-reset-pools!)
    (load.compiler-load-session-reset-interns!)
    (cbi.compiler-builtin-initialize-for-parse!)
    (tc_core.compiler-typecheck-reset-intern-owned-state!)))

(define (typecheck-compiler-program-with-paths-cache-and-load-state-and-prefix-cache-state-and-pools-and-intern-state
  [load-state : load.CompilerLoadSessionState]
  [prefix-cache : tc_core.TcPrefixSnapshotCacheState]
  [job-state : tc_core.TcJobState]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [pools : ast.AstNodePoolContext]
  [intern-state : ci.InternCompatState]) : tc_core.ResultCompilerTypecheck
  ;; Generate declaration families (e.g. hashmap) before macro expansion. Macro
  ;; expansion type-directs some sub-expressions (let-init / match-scrutinee
  ;; typing), which must be able to see generated functions; the later template
  ;; specialization pass would otherwise produce them too late and any program
  ;; that both defines a macro and uses a generated function would fail to
  ;; typecheck. The downstream specialize call re-normalizes harmlessly.
  (let
    [intern-state : ci.InternCompatState
      (owned_view.compiler-owned-shared-view intern-state)]
    (begin
      (tc_core.tc-spmd-inline-helper-stack-reset!)
      (tc_core.tc-macro-call-site-state-reset!
        (tc_core.tc-job-state-macro-call-sites job-state))
      (tc_core.tc-typecheck-result-with-pool-check
        job-state
        (let
          [owner-context : spec.SpecOwnerContext
            (spec.spec-owner-context-new
              (owned_view.compiler-owned-shared-view pools)
              (owned_view.compiler-owned-shared-view intern-state))]
          [generated-result : spec.ResultGenProgramWithPaths
            (spec.gen-normalize-program-with-paths-and-pools-and-intern-state
              program
              paths
              ""
              owner-context)]
          (begin
            (ast.ast-node-pool-context-install!
              (owned_view.compiler-owned-shared-view pools))
            ;; Publish generated IDs before legacy macro/symbol consumers run.
            (ci.intern-compat-state-install!
              (owned_view.compiler-owned-shared-view intern-state))
            (match generated-result
              [(spec.ResultGenProgramWithPaths.Ok generated generated-paths)
                (let
                  [macro-result : tc_core.ResultMacroExpand
                    (tc_core.macro-expand-then-build-envs-with-load-state-and-job-state-and-intern-state
                      (owned_view.compiler-owned-shared-view load-state)
                      job-state
                      generated
                      generated-paths
                      (owned_view.compiler-owned-shared-view pools)
                      (owned_view.compiler-owned-shared-view stdlib-roots)
                      (typecheck-compiler-source-language-cfgs)
                      (owned_view.compiler-owned-shared-view intern-state))]
                  (begin
                    (ast.ast-node-pool-context-capture-active!
                      (owned_view.compiler-owned-shared-view pools))
                    (ci.intern-compat-state-capture-from-globals!
                      (&mut intern-state))
                    (match macro-result
                      [(tc_core.ResultMacroExpand.Ok expanded expanded-paths)
                        (if (spec.compiler-specialize-needed-with-pools
                          (owned_view.compiler-owned-shared-view expanded)
                          (owned_view.compiler-owned-shared-view pools))
                          (let
                            [owner-context : spec.SpecOwnerContext
                              (spec.spec-owner-context-new
                                (owned_view.compiler-owned-shared-view pools)
                                (owned_view.compiler-owned-shared-view
                                  intern-state))]
                            [normalized-result : spec.ResultGenProgramWithPaths
                              (spec.gen-normalize-program-with-paths-and-pools-and-intern-state
                                expanded
                                (owned_view.compiler-owned-shared-view
                                  expanded-paths)
                                (tc_core.tc-decl-path-list-last
                                  expanded-paths
                                  "")
                                owner-context)]
                            (begin
                              ;; Publish explicit normalization mutations before
                              ;; matching either result or entering legacy phases.
                              (ast.ast-node-pool-context-install!
                                (owned_view.compiler-owned-shared-view pools))
                              (ci.intern-compat-state-install!
                                (owned_view.compiler-owned-shared-view
                                  intern-state))
                              (match normalized-result
                                [(spec.ResultGenProgramWithPaths.Ok
                                    normalized
                                    normalized-paths)
                                  (if (spec.compiler-specialize-needed-with-pools
                                    (owned_view.compiler-owned-shared-view
                                      normalized)
                                    (owned_view.compiler-owned-shared-view
                                      pools))
                                    (let
                                      [symbol-result : csym.ResultCompilerSymbolsDiagnostic
                                        (csym.build-compiler-symbols-diagnostic-with-paths
                                          (owned_view.compiler-owned-shared-view
                                            normalized)
                                          (owned_view.compiler-owned-shared-view
                                            normalized-paths))]
                                      (begin
                                        (ast.ast-node-pool-context-capture-active!
                                          (owned_view.compiler-owned-shared-view
                                            pools))
                                        (ci.intern-compat-state-capture-from-globals!
                                          (&mut intern-state))
                                        (match symbol-result
                                          [(csym.ResultCompilerSymbolsDiagnostic.Ok
                                              _)
                                            (let
                                              [specialized-result : spec.ResultSpecProgramWithPaths
                                                (spec.compiler-specialize-program-with-paths-and-pools-and-intern-state
                                                  (owned_view.compiler-owned-shared-view
                                                    normalized)
                                                  (owned_view.compiler-owned-shared-view
                                                    normalized-paths)
                                                  (tc_core.tc-decl-path-list-last
                                                    (owned_view.compiler-owned-shared-view
                                                      normalized-paths)
                                                    "")
                                                  (owned_view.compiler-owned-shared-view
                                                    pools)
                                                  (owned_view.compiler-owned-shared-view
                                                    intern-state))]
                                              (begin
                                                (ast.ast-node-pool-context-install!
                                                  (owned_view.compiler-owned-shared-view
                                                    pools))
                                                (ci.intern-compat-state-install!
                                                  (owned_view.compiler-owned-shared-view
                                                    intern-state))
                                                (match specialized-result
                                                  [(spec.ResultSpecProgramWithPaths.Ok
                                                      specialized
                                                      specialized-paths)
                                                    (tc_core.typecheck-compiler-specialized-program-with-paths-cache-with-pools-and-prefix-cache-state-and-intern-state
                                                      load-state
                                                      prefix-cache
                                                      job-state
                                                      specialized
                                                      specialized-paths
                                                      stdlib-roots
                                                      cache-scope
                                                      pools
                                                      (ci.intern-source-name-session-handle
                                                        (ci.intern-source-name-session-from-state
                                                          intern-state))
                                                      intern-state)]
                                                  [(spec.ResultSpecProgramWithPaths.Err
                                                      diag)
                                                    (tc_core.ResultCompilerTypecheck.Err
                                                      (cdiag.compiler-diagnostic-list-box-single
                                                        diag))])))]
                                          [(csym.ResultCompilerSymbolsDiagnostic.Err
                                              diag)
                                            (tc_core.ResultCompilerTypecheck.Err
                                              (cdiag.compiler-diagnostic-list-box-single
                                                diag))])))
                                    (tc_core.typecheck-compiler-specialized-program-with-paths-cache-with-pools-and-prefix-cache-state-and-intern-state
                                      load-state
                                      prefix-cache
                                      job-state
                                      normalized
                                      normalized-paths
                                      stdlib-roots
                                      cache-scope
                                      pools
                                      (ci.intern-source-name-session-handle
                                        (ci.intern-source-name-session-from-state
                                          intern-state))
                                      intern-state))]
                                [(spec.ResultGenProgramWithPaths.Err diag)
                                  (tc_core.ResultCompilerTypecheck.Err
                                    (cdiag.compiler-diagnostic-list-box-single
                                      diag))])))
                          (tc_core.typecheck-compiler-specialized-program-with-paths-cache-with-pools-and-prefix-cache-state-and-intern-state
                            load-state
                            prefix-cache
                            job-state
                            expanded
                            expanded-paths
                            stdlib-roots
                            cache-scope
                            pools
                            (ci.intern-source-name-session-handle
                              (ci.intern-source-name-session-from-state
                                intern-state))
                            intern-state))]
                      [(tc_core.ResultMacroExpand.Err diag)
                        (tc_core.ResultCompilerTypecheck.Err
                          (cdiag.compiler-diagnostic-list-box-single diag))])))]
              [(spec.ResultGenProgramWithPaths.Err diag)
                (tc_core.ResultCompilerTypecheck.Err
                  (cdiag.compiler-diagnostic-list-box-single diag))])))))))

;; Serial/test compatibility implementation retains the historical ambient
;; owner behavior. Production callers use the explicit intern-state entry.
;; Serial/test adapter for callers migrated to explicit loader state before the
;; prefix-cache and typecheck-job state seams existed.
(define (typecheck-compiler-program-with-paths-cache-and-load-state-and-prefix-cache-state-and-pools
  [load-state : load.CompilerLoadSessionState]
  [prefix-cache : tc_core.TcPrefixSnapshotCacheState]
  [job-state : tc_core.TcJobState]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [pools : ast.AstNodePoolContext]) : tc_core.ResultCompilerTypecheck
  (typecheck-compiler-program-with-paths-cache-and-load-state-and-prefix-cache-state-and-pools-and-intern-state
    load-state
    prefix-cache
    job-state
    program
    paths
    stdlib-roots
    cache-scope
    pools
    (ci.intern-compat-state-capture-active)))

(define (typecheck-compiler-program-with-paths-cache-and-load-state-and-pools
  [load-state : load.CompilerLoadSessionState]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [pools : ast.AstNodePoolContext]) : tc_core.ResultCompilerTypecheck
  (typecheck-compiler-program-with-paths-cache-and-load-state-and-prefix-cache-state-and-pools
    load-state
    (tc_core.tc-prefix-snapshot-serial-test-cache-state-shared-view)
    (tc_core.tc-serial-job-state)
    program
    paths
    stdlib-roots
    cache-scope
    pools))

;; Serial/test compatibility adapter. Production callers with a job context use
;; the explicit load-state, prefix-cache-state, and job-state entry above.
(define (typecheck-compiler-program-with-paths-cache-and-pools
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [pools : ast.AstNodePoolContext]) : tc_core.ResultCompilerTypecheck
  (typecheck-compiler-program-with-paths-cache-and-load-state-and-pools
    (load.compiler-load-serial-test-session-state)
    program
    paths
    stdlib-roots
    cache-scope
    pools))

(define (typecheck-compiler-program-with-paths-cache
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]) : tc_core.ResultCompilerTypecheck
  (typecheck-compiler-program-with-paths-cache-and-pools
    program
    paths
    stdlib-roots
    cache-scope
    (ast.ast-node-pool-context-capture-active)))

(define (typecheck-compiler-program-with-paths
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]) : tc_core.ResultCompilerTypecheck
  (typecheck-compiler-program-with-paths-cache
    program
    paths
    (svec.new)
    (tc_core.tc-prefix-default-cache-scope)))

(defenum ResultCompilerDocExpand
  (Ok ast.AstProgram ast.AstDeclPathList)
  (Err (Box cdiag.CompilerDiagnostic)))

(define (typecheck-compiler-doc-expand-program-with-paths-and-load-state-and-job-state-and-pools
  [load-state : load.CompilerLoadSessionState]
  [job-state : tc_core.TcJobState]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [pools : ast.AstNodePoolContext]) : ResultCompilerDocExpand
  (begin
    (tc_core.tc-spmd-inline-helper-stack-reset!)
    (tc_core.tc-macro-call-site-state-reset!
      (tc_core.tc-job-state-macro-call-sites job-state))
    (let
      [generated-result : spec.ResultGenProgramWithPaths
        (spec.gen-normalize-program-with-paths-and-pools
          program
          paths
          ""
          (owned_view.compiler-owned-shared-view pools))]
      (begin
        (ast.ast-node-pool-context-install!
          (owned_view.compiler-owned-shared-view pools))
        (match generated-result
          [(spec.ResultGenProgramWithPaths.Ok generated generated-paths)
            (match (tc_core.macro-expand-then-build-envs-with-load-state-and-job-state
              load-state
              job-state
              generated
              generated-paths
              (owned_view.compiler-owned-shared-view pools)
              stdlib-roots
              (typecheck-compiler-source-language-cfgs))
              [(tc_core.ResultMacroExpand.Ok expanded expanded-paths)
                (begin
                  (ast.ast-node-pool-context-capture-active! pools)
                  (ResultCompilerDocExpand.Ok expanded expanded-paths))]
              [(tc_core.ResultMacroExpand.Err diag)
                (ResultCompilerDocExpand.Err diag)])]
          [(spec.ResultGenProgramWithPaths.Err diag)
            (ResultCompilerDocExpand.Err diag)])))))

(define (typecheck-compiler-doc-expand-program-with-paths-and-load-state-and-pools
  [load-state : load.CompilerLoadSessionState]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [pools : ast.AstNodePoolContext]) : ResultCompilerDocExpand
  (typecheck-compiler-doc-expand-program-with-paths-and-load-state-and-job-state-and-pools
    load-state
    (tc_core.tc-serial-job-state)
    program
    paths
    stdlib-roots
    pools))

;; Serial/test compatibility adapter.
(define (typecheck-compiler-doc-expand-program-with-paths-and-pools
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [pools : ast.AstNodePoolContext]) : ResultCompilerDocExpand
  (typecheck-compiler-doc-expand-program-with-paths-and-load-state-and-pools
    (load.compiler-load-serial-test-session-state)
    program
    paths
    stdlib-roots
    pools))

(define (typecheck-compiler-program-with-paths-checked-cache-and-load-state-and-prefix-cache-state-and-pools-and-intern-state
  [load-state : load.CompilerLoadSessionState]
  [prefix-cache : tc_core.TcPrefixSnapshotCacheState]
  [job-state : tc_core.TcJobState]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [pools : ast.AstNodePoolContext]
  [intern-state : ci.InternCompatState]) : tc_core.ResultCompilerTypecheckChecked
  (let
    [intern-state : ci.InternCompatState
      (owned_view.compiler-owned-shared-view intern-state)]
    (begin
      (tc_core.tc-spmd-inline-helper-stack-reset!)
      (tc_core.tc-macro-call-site-state-reset!
        (tc_core.tc-job-state-macro-call-sites job-state))
      (tc_core.tc-typecheck-checked-result-with-pool-check
        job-state
        (let
          [owner-context : spec.SpecOwnerContext
            (spec.spec-owner-context-new
              (owned_view.compiler-owned-shared-view pools)
              (owned_view.compiler-owned-shared-view intern-state))]
          [generated-result : spec.ResultGenProgramWithPaths
            (spec.gen-normalize-program-with-paths-and-pools-and-intern-state
              program
              paths
              ""
              owner-context)]
          (begin
            (ast.ast-node-pool-context-install!
              (owned_view.compiler-owned-shared-view pools))
            ;; Publish generated IDs before legacy macro/symbol consumers run.
            (ci.intern-compat-state-install!
              (owned_view.compiler-owned-shared-view intern-state))
            (match generated-result
              [(spec.ResultGenProgramWithPaths.Ok generated generated-paths)
                (let
                  [macro-result : tc_core.ResultMacroExpand
                    (tc_core.macro-expand-then-build-envs-with-load-state-and-job-state-and-intern-state
                      (owned_view.compiler-owned-shared-view load-state)
                      job-state
                      generated
                      generated-paths
                      (owned_view.compiler-owned-shared-view pools)
                      (owned_view.compiler-owned-shared-view stdlib-roots)
                      (typecheck-compiler-source-language-cfgs)
                      (owned_view.compiler-owned-shared-view intern-state))]
                  (begin
                    (ast.ast-node-pool-context-capture-active!
                      (owned_view.compiler-owned-shared-view pools))
                    (ci.intern-compat-state-capture-from-globals!
                      (&mut intern-state))
                    (match macro-result
                      [(tc_core.ResultMacroExpand.Ok expanded expanded-paths)
                        (if (spec.compiler-specialize-needed-with-pools
                          (owned_view.compiler-owned-shared-view expanded)
                          (owned_view.compiler-owned-shared-view pools))
                          (let
                            [owner-context : spec.SpecOwnerContext
                              (spec.spec-owner-context-new
                                (owned_view.compiler-owned-shared-view pools)
                                (owned_view.compiler-owned-shared-view
                                  intern-state))]
                            [normalized-result : spec.ResultGenProgramWithPaths
                              (spec.gen-normalize-program-with-paths-and-pools-and-intern-state
                                expanded
                                (owned_view.compiler-owned-shared-view
                                  expanded-paths)
                                (tc_core.tc-decl-path-list-last
                                  expanded-paths
                                  "")
                                owner-context)]
                            (begin
                              ;; Publish explicit normalization mutations before
                              ;; matching either result or entering legacy phases.
                              (ast.ast-node-pool-context-install!
                                (owned_view.compiler-owned-shared-view pools))
                              (ci.intern-compat-state-install!
                                (owned_view.compiler-owned-shared-view
                                  intern-state))
                              (match normalized-result
                                [(spec.ResultGenProgramWithPaths.Ok
                                    normalized
                                    normalized-paths)
                                  (if (spec.compiler-specialize-needed-with-pools
                                    (owned_view.compiler-owned-shared-view
                                      normalized)
                                    (owned_view.compiler-owned-shared-view
                                      pools))
                                    (let
                                      [symbol-result : csym.ResultCompilerSymbolsDiagnostic
                                        (csym.build-compiler-symbols-diagnostic-with-paths
                                          (owned_view.compiler-owned-shared-view
                                            normalized)
                                          (owned_view.compiler-owned-shared-view
                                            normalized-paths))]
                                      (begin
                                        (ast.ast-node-pool-context-capture-active!
                                          (owned_view.compiler-owned-shared-view
                                            pools))
                                        (ci.intern-compat-state-capture-from-globals!
                                          (&mut intern-state))
                                        (match symbol-result
                                          [(csym.ResultCompilerSymbolsDiagnostic.Ok
                                              _)
                                            (let
                                              [specialized-result : spec.ResultSpecProgramWithPaths
                                                (spec.compiler-specialize-program-with-paths-and-pools-and-intern-state
                                                  (owned_view.compiler-owned-shared-view
                                                    normalized)
                                                  (owned_view.compiler-owned-shared-view
                                                    normalized-paths)
                                                  (tc_core.tc-decl-path-list-last
                                                    (owned_view.compiler-owned-shared-view
                                                      normalized-paths)
                                                    "")
                                                  (owned_view.compiler-owned-shared-view
                                                    pools)
                                                  (owned_view.compiler-owned-shared-view
                                                    intern-state))]
                                              (begin
                                                (ast.ast-node-pool-context-install!
                                                  (owned_view.compiler-owned-shared-view
                                                    pools))
                                                (ci.intern-compat-state-install!
                                                  (owned_view.compiler-owned-shared-view
                                                    intern-state))
                                                (match specialized-result
                                                  [(spec.ResultSpecProgramWithPaths.Ok
                                                      specialized
                                                      specialized-paths)
                                                    (tc_core.typecheck-compiler-specialized-program-with-paths-checked-cache-with-pools-and-source-names-and-prefix-cache-state-and-intern-state
                                                      load-state
                                                      prefix-cache
                                                      job-state
                                                      specialized
                                                      specialized-paths
                                                      stdlib-roots
                                                      cache-scope
                                                      pools
                                                      (ci.intern-source-name-session-handle
                                                        (ci.intern-source-name-session-from-state
                                                          intern-state))
                                                      intern-state)]
                                                  [(spec.ResultSpecProgramWithPaths.Err
                                                      diag)
                                                    (tc_core.ResultCompilerTypecheckChecked.Err
                                                      (cdiag.compiler-diagnostic-list-box-single
                                                        diag))])))]
                                          [(csym.ResultCompilerSymbolsDiagnostic.Err
                                              diag)
                                            (tc_core.ResultCompilerTypecheckChecked.Err
                                              (cdiag.compiler-diagnostic-list-box-single
                                                diag))])))
                                    (tc_core.typecheck-compiler-specialized-program-with-paths-checked-cache-with-pools-and-source-names-and-prefix-cache-state-and-intern-state
                                      load-state
                                      prefix-cache
                                      job-state
                                      normalized
                                      normalized-paths
                                      stdlib-roots
                                      cache-scope
                                      pools
                                      (ci.intern-source-name-session-handle
                                        (ci.intern-source-name-session-from-state
                                          intern-state))
                                      intern-state))]
                                [(spec.ResultGenProgramWithPaths.Err diag)
                                  (tc_core.ResultCompilerTypecheckChecked.Err
                                    (cdiag.compiler-diagnostic-list-box-single
                                      diag))])))
                          (tc_core.typecheck-compiler-specialized-program-with-paths-checked-cache-with-pools-and-source-names-and-prefix-cache-state-and-intern-state
                            load-state
                            prefix-cache
                            job-state
                            expanded
                            expanded-paths
                            stdlib-roots
                            cache-scope
                            pools
                            (ci.intern-source-name-session-handle
                              (ci.intern-source-name-session-from-state
                                intern-state))
                            intern-state))]
                      [(tc_core.ResultMacroExpand.Err diag)
                        (tc_core.ResultCompilerTypecheckChecked.Err
                          (cdiag.compiler-diagnostic-list-box-single diag))])))]
              [(spec.ResultGenProgramWithPaths.Err diag)
                (tc_core.ResultCompilerTypecheckChecked.Err
                  (cdiag.compiler-diagnostic-list-box-single diag))])))))))

;; Serial/test compatibility adapter for the checked API.
(define (typecheck-compiler-program-with-paths-checked-cache-and-load-state-and-prefix-cache-state-and-pools
  [load-state : load.CompilerLoadSessionState]
  [prefix-cache : tc_core.TcPrefixSnapshotCacheState]
  [job-state : tc_core.TcJobState]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [pools : ast.AstNodePoolContext]) : tc_core.ResultCompilerTypecheckChecked
  (typecheck-compiler-program-with-paths-checked-cache-and-load-state-and-prefix-cache-state-and-pools-and-intern-state
    load-state
    prefix-cache
    job-state
    program
    paths
    stdlib-roots
    cache-scope
    pools
    (ci.intern-compat-state-capture-active)))

;; Serial/test adapter for the load-state-only surface.
(define (typecheck-compiler-program-with-paths-checked-cache-and-load-state-and-pools
  [load-state : load.CompilerLoadSessionState]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [pools : ast.AstNodePoolContext]) : tc_core.ResultCompilerTypecheckChecked
  (typecheck-compiler-program-with-paths-checked-cache-and-load-state-and-prefix-cache-state-and-pools
    load-state
    (tc_core.tc-prefix-snapshot-serial-test-cache-state-shared-view)
    (tc_core.tc-serial-job-state)
    program
    paths
    stdlib-roots
    cache-scope
    pools))

;; Serial/test compatibility adapter.
(define (typecheck-compiler-program-with-paths-checked-cache-and-pools
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [pools : ast.AstNodePoolContext]) : tc_core.ResultCompilerTypecheckChecked
  (typecheck-compiler-program-with-paths-checked-cache-and-load-state-and-pools
    (load.compiler-load-serial-test-session-state)
    program
    paths
    stdlib-roots
    cache-scope
    pools))

(define (typecheck-compiler-program-with-paths-checked-cache
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]) : tc_core.ResultCompilerTypecheckChecked
  (typecheck-compiler-program-with-paths-checked-cache-and-pools
    program
    paths
    stdlib-roots
    cache-scope
    (ast.ast-node-pool-context-capture-active)))

(define (typecheck-compiler-program-with-paths-checked
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]) : tc_core.ResultCompilerTypecheckChecked
  (typecheck-compiler-program-with-paths-checked-cache
    program
    paths
    (svec.new)
    (tc_core.tc-prefix-default-cache-scope)))

(define (typecheck-compiler-program [program : ast.AstProgram]) : tc_core.ResultCompilerTypecheck
  (typecheck-compiler-program-with-paths program (ast.ast-decl-path-list-new)))

(define (typecheck-compiler-source-language-cfgs) : sym_i64_env.SymI64Env
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (cfg_core.compiler-cfg-empty)))

(define (typecheck-compiler-source-load [src : String]) : load.ResultCompilerLoadWithPaths
  (let
    [stdlib-roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (typecheck-compiler-source-language-cfgs)]
    (match (load.compiler-load-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      (owned_view.compiler-owned-shared-view stdlib-roots)
      (owned_view.compiler-owned-shared-view cfgs))
      [(load.ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (match (load.compiler-load-source-with-paths-and-roots-cfg
          ""
          src
          prelude-seen
          stdlib-roots
          cfgs)
          [(load.ResultCompilerLoadWithPaths.Ok
              entry-decls
              entry-paths
              entry-modules
              seen)
            (load.ResultCompilerLoadWithPaths.Ok
              (load.compiler-load-decl-list-append prelude-decls entry-decls)
              (load.compiler-load-decl-path-list-append
                prelude-paths
                entry-paths)
              (load.compiler-load-decl-module-list-append
                prelude-modules
                entry-modules)
              seen)]
          [(load.ResultCompilerLoadWithPaths.Err diag)
            (load.ResultCompilerLoadWithPaths.Err diag)])]
      [(load.ResultCompilerLoadWithPaths.Err diag)
        (load.ResultCompilerLoadWithPaths.Err diag)])))

(define (typecheck-compiler-source-stdlib-import-kind?
  [kind : ast.AstImportKind]
  [path : String]) : bool
  (match kind
    [(ast.AstImportKind.Module)
      (load.compiler-load-stdlib-import?
        (load.compiler-load-dotted-module-path path))]
    [_ false]))

(define (typecheck-compiler-source-decl-has-stdlib-import? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Import decl-meta (ast.AstImportSpec.Spec kind path _ _ _))
      (typecheck-compiler-source-stdlib-import-kind? kind path)]
    [(ast.AstDecl.Unsafe inner-box)
      (typecheck-compiler-source-decl-has-stdlib-import?
        (owned_view.compiler-owned-box-shared-view inner-box))]
    [_ false]))

(define (typecheck-compiler-source-decls-have-stdlib-import?
  [decls : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) false]
    [(ast.AstDeclListStep.Cons decl rest)
      (or
        (typecheck-compiler-source-decl-has-stdlib-import? decl)
        (typecheck-compiler-source-decls-have-stdlib-import? rest))]))

(define (typecheck-compiler-source-program-has-stdlib-import?
  [program : ast.AstProgram]) : bool
  (match program
    [(ast.AstProgram.Program decls-box)
      (typecheck-compiler-source-decls-have-stdlib-import?
        (owned_view.compiler-owned-box-shared-view decls-box))]))

(define (typecheck-compiler-repl-expr
  [decls : ast.AstDeclList]
  [expr : ast.AstExpr]) : tc_core.ResultTcType
  (let
    [program : ast.AstProgram
      (ast.ast-program (owned_view.compiler-owned-shared-view decls))]
    (begin
      (tc_core.tc-clone-able-cache-reset!)
      (tc_core.macro-alias-cache-reset!)
      (match (csym.build-compiler-symbols program)
        [(csym.ResultCompilerSymbols.Ok symbols)
          (match (csym.build-compiler-registries program)
            [(csym.ResultCompilerRegistries.Ok registries)
              (let
                [ctx : tc_core.TcContext
                  (tc_core.tc-context-new
                    (owned_view.compiler-owned-shared-view program)
                    symbols
                    registries
                    ""
                    cbi.compiler-builtin-id-fix-empty
                    (ast.ast-node-pool-context-capture-active))]
                (match (tc_core.tc-program-source-types-policy-ok
                  (owned_view.compiler-owned-shared-view ctx)
                  (owned_view.compiler-owned-shared-view program)
                  (ast.ast-decl-path-list-new))
                  [(tc_core.ResultTcSourcePolicyDiagnostic.Ok)
                    (match (tc_core.tc-source-expr-policy-ok
                      (owned_view.compiler-owned-shared-view ctx)
                      (tc_core.tc-context-expr-bases
                        (owned_view.compiler-owned-shared-view ctx))
                      (owned_view.compiler-owned-shared-view expr))
                      [(tc_core.ResultTcUnit.Ok)
                        (match (tc_core.tc-build-top-env
                          (owned_view.compiler-owned-shared-view ctx)
                          program)
                          [(tc_core.ResultTcEnv.Ok top-env)
                            (match (tc_core.tc-check-decls
                              (owned_view.compiler-owned-shared-view ctx)
                              top-env
                              decls
                              (tc_core.CompilerTypecheckSummary 0 0 0))
                              [(tc_core.ResultCompilerTypecheck.Ok _)
                                (tc_core.tc-expr ctx top-env expr)]
                              [(tc_core.ResultCompilerTypecheck.Err diag)
                                (let
                                  [diagnostics : cdiag.CompilerDiagnosticList
                                    (cdiag.compiler-diagnostic-list-box-shared-view
                                      diag)]
                                  [first : cdiag.CompilerDiagnostic
                                    (cdiag.compiler-diagnostic-list-first
                                      diagnostics)]
                                  (tc_core.ResultTcType.Err
                                    (cdiag.compiler-diagnostic-message first)))])]
                          [(tc_core.ResultTcEnv.Err message)
                            (tc_core.ResultTcType.Err message)])]
                      [(tc_core.ResultTcUnit.Err message)
                        (tc_core.ResultTcType.Err message)])]
                  [(tc_core.ResultTcSourcePolicyDiagnostic.Err diag)
                    (tc_core.ResultTcType.Err
                      (cdiag.compiler-diagnostic-message (__tl-box-place diag)))]))]
            [(csym.ResultCompilerRegistries.Err message)
              (tc_core.ResultTcType.Err message)])]
        [(csym.ResultCompilerSymbols.Err message)
          (tc_core.ResultTcType.Err message)]))))

(define (typecheck-compiler-source [src : String]) : tc_core.ResultCompilerTypecheck
  (let
    [_cache-reset : unit (tc_core.tc-prefix-snapshot-cache-clear!)]
    [_dedup-reset : unit (ast.ty-node-dedup-clear!)]
    [_reset-before : unit (tc_core.compiler-typecheck-reset-file-state!)]
    [result : tc_core.ResultCompilerTypecheck
      (match (parser.parse-ast-source-diagnostic
        ""
        (owned_view.compiler-owned-shared-view src))
        [(parser.ResultAstProgramDiagnostic.Ok program)
          ;; Keep synthetic in-memory fixtures on the historical direct path,
          ;; but route real stdlib imports through the loader so macro imports
          ;; see loaded stdlib macro definitions and alias markers.
          (if (typecheck-compiler-source-program-has-stdlib-import?
            (owned_view.compiler-owned-shared-view program))
            (match (typecheck-compiler-source-load
              (owned_view.compiler-owned-shared-view src))
              [(load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
                (typecheck-compiler-program-with-paths
                  (ast.ast-program decls)
                  paths)]
              [(load.ResultCompilerLoadWithPaths.Err diag)
                (tc_core.ResultCompilerTypecheck.Err
                  (cdiag.compiler-diagnostic-list-box-single diag))])
            (typecheck-compiler-program program))]
        [(parser.ResultAstProgramDiagnostic.Err diag)
          (tc_core.ResultCompilerTypecheck.Err
            (cdiag.compiler-diagnostic-list-box-single diag))])]
    (begin
      (tc_core.compiler-typecheck-reset-file-state!)
      result)))

(define (compiler-typecheck-summary-score
  [summary : tc_core.CompilerTypecheckSummary]) : i64
  (match summary
    [(tc_core.CompilerTypecheckSummary values functions externs)
      (+ values (+ (* functions 10) (* externs 100)))]))