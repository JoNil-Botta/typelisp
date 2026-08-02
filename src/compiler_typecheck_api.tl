;; compiler_typecheck_api.tl - Public typechecker API used by compiler tools.
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

(define (typecheck-compiler-program-with-paths-cache-and-load-state-and-prefix-cache-state-and-pools
  [load-state : load.CompilerLoadSessionState]
  [prefix-cache : tc_core.TcPrefixSnapshotCacheState]
  [job-state : tc_core.TcJobState]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [pools : ast.AstNodePoolContext]) : tc_core.ResultCompilerTypecheck
  ;; Generate declaration families (e.g. hashmap) before macro expansion. Macro
  ;; expansion type-directs some sub-expressions (let-init / match-scrutinee
  ;; typing), which must be able to see generated functions; the later template
  ;; specialization pass would otherwise produce them too late and any program
  ;; that both defines a macro and uses a generated function would fail to
  ;; typecheck. The downstream specialize call re-normalizes harmlessly.
  (begin
    (tc_core.tc-spmd-inline-helper-stack-reset!)
    (tc_core.tc-typecheck-result-with-pool-check
      (let
        [generated-result : spec.ResultGenProgramWithPaths
          (spec.gen-normalize-program-with-paths-and-pools
            program
            paths
            ""
            pools)]
        (begin
          (ast.ast-node-pool-context-install! pools)
          (match generated-result
            [(spec.ResultGenProgramWithPaths.Ok generated generated-paths)
              (match (tc_core.macro-expand-then-build-envs-with-load-state-and-job-state
                load-state
                job-state
                generated
                generated-paths
                pools
                stdlib-roots
                (typecheck-compiler-source-language-cfgs))
                [(tc_core.ResultMacroExpand.Ok expanded expanded-paths)
                  (begin
                    (ast.ast-node-pool-context-capture-active! pools)
                    (if (spec.compiler-specialize-needed? expanded)
                      (match (spec.gen-normalize-program-with-paths-and-pools
                        expanded
                        expanded-paths
                        (tc_core.tc-decl-path-list-last expanded-paths "")
                        pools)
                        [(spec.ResultGenProgramWithPaths.Ok
                            normalized
                            normalized-paths)
                          (begin
                            (ast.ast-node-pool-context-install! pools)
                            (if (spec.compiler-specialize-needed? normalized)
                              (match (csym.build-compiler-symbols-diagnostic-with-paths
                                normalized
                                normalized-paths)
                                [(csym.ResultCompilerSymbolsDiagnostic.Ok _)
                                  (begin
                                    (ast.ast-node-pool-context-capture-active!
                                      pools)
                                    (match (spec.compiler-specialize-program-with-paths-and-pools
                                      normalized
                                      normalized-paths
                                      (tc_core.tc-decl-path-list-last
                                        normalized-paths
                                        "")
                                      pools)
                                      [(spec.ResultSpecProgramWithPaths.Ok
                                          specialized
                                          specialized-paths)
                                        (tc_core.typecheck-compiler-specialized-program-with-paths-cache-with-pools-and-prefix-cache-state
                                          load-state
                                          prefix-cache
                                          job-state
                                          specialized
                                          specialized-paths
                                          stdlib-roots
                                          cache-scope
                                          pools)]
                                      [(spec.ResultSpecProgramWithPaths.Err
                                          diag)
                                        (tc_core.ResultCompilerTypecheck.Err
                                          (cdiag.compiler-diagnostic-list-box-single
                                            diag))]))]
                                [(csym.ResultCompilerSymbolsDiagnostic.Err diag)
                                  (tc_core.ResultCompilerTypecheck.Err
                                    (cdiag.compiler-diagnostic-list-box-single
                                      diag))])
                              (tc_core.typecheck-compiler-specialized-program-with-paths-cache-with-pools-and-prefix-cache-state
                                load-state
                                prefix-cache
                                job-state
                                normalized
                                normalized-paths
                                stdlib-roots
                                cache-scope
                                pools)))]
                        [(spec.ResultGenProgramWithPaths.Err diag)
                          (tc_core.ResultCompilerTypecheck.Err
                            (cdiag.compiler-diagnostic-list-box-single diag))])
                      (tc_core.typecheck-compiler-specialized-program-with-paths-cache-with-pools-and-prefix-cache-state
                        load-state
                        prefix-cache
                        job-state
                        expanded
                        expanded-paths
                        stdlib-roots
                        cache-scope
                        pools)))]
                [(tc_core.ResultMacroExpand.Err diag)
                  (tc_core.ResultCompilerTypecheck.Err
                    (cdiag.compiler-diagnostic-list-box-single diag))])]
            [(spec.ResultGenProgramWithPaths.Err diag)
              (tc_core.ResultCompilerTypecheck.Err
                (cdiag.compiler-diagnostic-list-box-single diag))]))))))

;; Serial/test adapter for callers migrated to explicit loader state before the
;; prefix-cache and typecheck-job state seams existed.
(define (typecheck-compiler-program-with-paths-cache-and-load-state-and-pools
  [load-state : load.CompilerLoadSessionState]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [pools : ast.AstNodePoolContext]) : tc_core.ResultCompilerTypecheck
  (typecheck-compiler-program-with-paths-cache-and-load-state-and-prefix-cache-state-and-pools
    load-state
    tc_core.tc-prefix-snapshot-serial-test-cache-state
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
    (let
      [generated-result : spec.ResultGenProgramWithPaths
        (spec.gen-normalize-program-with-paths-and-pools program paths "" pools)]
      (begin
        (ast.ast-node-pool-context-install! pools)
        (match generated-result
          [(spec.ResultGenProgramWithPaths.Ok generated generated-paths)
            (match (tc_core.macro-expand-then-build-envs-with-load-state-and-job-state
              load-state
              job-state
              generated
              generated-paths
              pools
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

(define (typecheck-compiler-program-with-paths-checked-cache-and-load-state-and-prefix-cache-state-and-pools
  [load-state : load.CompilerLoadSessionState]
  [prefix-cache : tc_core.TcPrefixSnapshotCacheState]
  [job-state : tc_core.TcJobState]
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [pools : ast.AstNodePoolContext]) : tc_core.ResultCompilerTypecheckChecked
  (begin
    (tc_core.tc-spmd-inline-helper-stack-reset!)
    (tc_core.tc-typecheck-checked-result-with-pool-check
      (let
        [generated-result : spec.ResultGenProgramWithPaths
          (spec.gen-normalize-program-with-paths-and-pools
            program
            paths
            ""
            pools)]
        (begin
          (ast.ast-node-pool-context-install! pools)
          (match generated-result
            [(spec.ResultGenProgramWithPaths.Ok generated generated-paths)
              (match (tc_core.macro-expand-then-build-envs-with-load-state-and-job-state
                load-state
                job-state
                generated
                generated-paths
                pools
                stdlib-roots
                (typecheck-compiler-source-language-cfgs))
                [(tc_core.ResultMacroExpand.Ok expanded expanded-paths)
                  (begin
                    (ast.ast-node-pool-context-capture-active! pools)
                    (if (spec.compiler-specialize-needed? expanded)
                      (match (spec.gen-normalize-program-with-paths-and-pools
                        expanded
                        expanded-paths
                        (tc_core.tc-decl-path-list-last expanded-paths "")
                        pools)
                        [(spec.ResultGenProgramWithPaths.Ok
                            normalized
                            normalized-paths)
                          (begin
                            (ast.ast-node-pool-context-install! pools)
                            (if (spec.compiler-specialize-needed? normalized)
                              (match (csym.build-compiler-symbols-diagnostic-with-paths
                                normalized
                                normalized-paths)
                                [(csym.ResultCompilerSymbolsDiagnostic.Ok _)
                                  (begin
                                    (ast.ast-node-pool-context-capture-active!
                                      pools)
                                    (match (spec.compiler-specialize-program-with-paths-and-pools
                                      normalized
                                      normalized-paths
                                      (tc_core.tc-decl-path-list-last
                                        normalized-paths
                                        "")
                                      pools)
                                      [(spec.ResultSpecProgramWithPaths.Ok
                                          specialized
                                          specialized-paths)
                                        (tc_core.typecheck-compiler-specialized-program-with-paths-checked-cache-with-pools-and-prefix-cache-state
                                          load-state
                                          prefix-cache
                                          job-state
                                          specialized
                                          specialized-paths
                                          stdlib-roots
                                          cache-scope
                                          pools)]
                                      [(spec.ResultSpecProgramWithPaths.Err
                                          diag)
                                        (tc_core.ResultCompilerTypecheckChecked.Err
                                          (cdiag.compiler-diagnostic-list-box-single
                                            diag))]))]
                                [(csym.ResultCompilerSymbolsDiagnostic.Err diag)
                                  (tc_core.ResultCompilerTypecheckChecked.Err
                                    (cdiag.compiler-diagnostic-list-box-single
                                      diag))])
                              (tc_core.typecheck-compiler-specialized-program-with-paths-checked-cache-with-pools-and-prefix-cache-state
                                load-state
                                prefix-cache
                                job-state
                                normalized
                                normalized-paths
                                stdlib-roots
                                cache-scope
                                pools)))]
                        [(spec.ResultGenProgramWithPaths.Err diag)
                          (tc_core.ResultCompilerTypecheckChecked.Err
                            (cdiag.compiler-diagnostic-list-box-single diag))])
                      (tc_core.typecheck-compiler-specialized-program-with-paths-checked-cache-with-pools-and-prefix-cache-state
                        load-state
                        prefix-cache
                        job-state
                        expanded
                        expanded-paths
                        stdlib-roots
                        cache-scope
                        pools)))]
                [(tc_core.ResultMacroExpand.Err diag)
                  (tc_core.ResultCompilerTypecheckChecked.Err
                    (cdiag.compiler-diagnostic-list-box-single diag))])]
            [(spec.ResultGenProgramWithPaths.Err diag)
              (tc_core.ResultCompilerTypecheckChecked.Err
                (cdiag.compiler-diagnostic-list-box-single diag))]))))))

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
    tc_core.tc-prefix-snapshot-serial-test-cache-state
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
      stdlib-roots
      cfgs)
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
      (typecheck-compiler-source-decl-has-stdlib-import? (box-get inner-box))]
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
      (typecheck-compiler-source-decls-have-stdlib-import? (box-get decls-box))]))

(define (typecheck-compiler-repl-expr
  [decls : ast.AstDeclList]
  [expr : ast.AstExpr]) : tc_core.ResultTcType
  (let
    [program : ast.AstProgram (ast.ast-program decls)]
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
                    program
                    symbols
                    registries
                    ""
                    cbi.compiler-builtin-id-fix-empty
                    (ast.ast-node-pool-context-capture-active))]
                (match (tc_core.tc-program-source-types-policy-ok
                  ctx
                  program
                  (ast.ast-decl-path-list-new))
                  [(tc_core.ResultTcSourcePolicyDiagnostic.Ok)
                    (match (tc_core.tc-source-expr-policy-ok
                      ctx
                      (tc_core.tc-context-expr-bases ctx)
                      expr)
                      [(tc_core.ResultTcUnit.Ok)
                        (match (tc_core.tc-build-top-env ctx program)
                          [(tc_core.ResultTcEnv.Ok top-env)
                            (match (tc_core.tc-check-decls
                              ctx
                              top-env
                              decls
                              (tc_core.CompilerTypecheckSummary 0 0 0))
                              [(tc_core.ResultCompilerTypecheck.Ok _)
                                (tc_core.tc-expr ctx top-env expr)]
                              [(tc_core.ResultCompilerTypecheck.Err diag)
                                (tc_core.ResultTcType.Err
                                  (cdiag.compiler-diagnostic-message
                                    (cdiag.compiler-diagnostic-list-first
                                      (box-get diag))))])]
                          [(tc_core.ResultTcEnv.Err message)
                            (tc_core.ResultTcType.Err message)])]
                      [(tc_core.ResultTcUnit.Err message)
                        (tc_core.ResultTcType.Err message)])]
                  [(tc_core.ResultTcSourcePolicyDiagnostic.Err diag)
                    (tc_core.ResultTcType.Err
                      (cdiag.compiler-diagnostic-message (box-get diag)))]))]
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
      (match (parser.parse-ast-source-diagnostic "" src)
        [(parser.ResultAstProgramDiagnostic.Ok program)
          ;; Keep synthetic in-memory fixtures on the historical direct path,
          ;; but route real stdlib imports through the loader so macro imports
          ;; see loaded stdlib macro definitions and alias markers.
          (if (typecheck-compiler-source-program-has-stdlib-import? program)
            (match (typecheck-compiler-source-load src)
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