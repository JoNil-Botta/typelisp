;; compiler_typecheck_api.tl - Public typechecker API used by compiler tools.
(import stdlib.vector)
(import (vector String) as svec)
(import "compiler_typecheck_core.tl")
(import "compiler_load.tl")
(import "compiler_specialize.tl")
(import sym_i64_env)

(define (compiler-typecheck-prefix-cache-scope
  [kind : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : String
  (compiler-load-prelude-cache-key kind stdlib-roots cfgs))

(define (compiler-typecheck-reset-load-session!) : unit
  (begin
    (compiler-load-session-reset-pools!)
    (compiler-load-session-reset-interns!)
    (compiler-typecheck-reset-intern-owned-state!)))

(define (typecheck-compiler-specialized-program-with-paths-cache-and-pools
  [program : AstProgram]
  [paths : AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [pools : AstNodePoolContext]) : ResultCompilerTypecheck
  (typecheck-compiler-specialized-program-with-paths-cache-with-pools
    program
    paths
    stdlib-roots
    cache-scope
    pools))

(define (typecheck-compiler-specialized-program-with-paths-checked-cache-and-pools
  [program : AstProgram]
  [paths : AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [pools : AstNodePoolContext]) : ResultCompilerTypecheckChecked
  (typecheck-compiler-specialized-program-with-paths-checked-cache-with-pools
    program
    paths
    stdlib-roots
    cache-scope
    pools))

(define (typecheck-compiler-program-with-paths-cache-and-pools
  [program : AstProgram]
  [paths : AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [pools : AstNodePoolContext]) : ResultCompilerTypecheck
  ;; Generate declaration families (e.g. hashmap) before macro expansion. Macro
  ;; expansion type-directs some sub-expressions (let-init / match-scrutinee
  ;; typing), which must be able to see generated functions; the later template
  ;; specialization pass would otherwise produce them too late and any program
  ;; that both defines a macro and uses a generated function would fail to
  ;; typecheck. The downstream specialize call re-normalizes harmlessly.
  (begin
    (tc-spmd-inline-helper-stack-reset!)
    (tc-typecheck-result-with-pool-check
      (let
        [generated-result : ResultGenProgramWithPaths
          (gen-normalize-program-with-paths-and-pools program paths "" pools)]
        (begin
          (ast-node-pool-context-install! pools)
          (match generated-result
            [(ResultGenProgramWithPaths.Ok generated generated-paths)
              (match (macro-expand-then-build-envs
                generated
                generated-paths
                pools
                stdlib-roots
                (typecheck-compiler-source-language-cfgs))
                [(ResultMacroExpand.Ok expanded expanded-paths)
                  (begin
                    (ast-node-pool-context-capture-active! pools)
                    (if (compiler-specialize-needed? expanded)
                      (match (gen-normalize-program-with-paths-and-pools
                        expanded
                        expanded-paths
                        (tc-decl-path-list-last expanded-paths "")
                        pools)
                        [(ResultGenProgramWithPaths.Ok
                            normalized
                            normalized-paths)
                          (begin
                            (ast-node-pool-context-install! pools)
                            (if (compiler-specialize-needed? normalized)
                              (match (build-compiler-symbols-diagnostic-with-paths
                                normalized
                                normalized-paths)
                                [(ResultCompilerSymbolsDiagnostic.Ok _)
                                  (begin
                                    (ast-node-pool-context-capture-active!
                                      pools)
                                    (match (compiler-specialize-program-with-paths-and-pools
                                      normalized
                                      normalized-paths
                                      (tc-decl-path-list-last
                                        normalized-paths
                                        "")
                                      pools)
                                      [(ResultSpecProgramWithPaths.Ok
                                          specialized
                                          specialized-paths)
                                        (typecheck-compiler-specialized-program-with-paths-cache-and-pools
                                          specialized
                                          specialized-paths
                                          stdlib-roots
                                          cache-scope
                                          pools)]
                                      [(ResultSpecProgramWithPaths.Err diag)
                                        (ResultCompilerTypecheck.Err diag)]))]
                                [(ResultCompilerSymbolsDiagnostic.Err diag)
                                  (ResultCompilerTypecheck.Err diag)])
                              (typecheck-compiler-specialized-program-with-paths-cache-and-pools
                                normalized
                                normalized-paths
                                stdlib-roots
                                cache-scope
                                pools)))]
                        [(ResultGenProgramWithPaths.Err diag)
                          (ResultCompilerTypecheck.Err diag)])
                      (typecheck-compiler-specialized-program-with-paths-cache-and-pools
                        expanded
                        expanded-paths
                        stdlib-roots
                        cache-scope
                        pools)))]
                [(ResultMacroExpand.Err diag)
                  (ResultCompilerTypecheck.Err diag)])]
            [(ResultGenProgramWithPaths.Err diag)
              (ResultCompilerTypecheck.Err diag)]))))))

(define (typecheck-compiler-program-with-paths-cache
  [program : AstProgram]
  [paths : AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]) : ResultCompilerTypecheck
  (typecheck-compiler-program-with-paths-cache-and-pools
    program
    paths
    stdlib-roots
    cache-scope
    (ast-node-pool-context-capture-active)))

(define (typecheck-compiler-program-with-paths
  [program : AstProgram]
  [paths : AstDeclPathList]) : ResultCompilerTypecheck
  (typecheck-compiler-program-with-paths-cache
    program
    paths
    (svec.new)
    (tc-prefix-default-cache-scope)))

(defenum ResultCompilerDocExpand
  (Ok AstProgram AstDeclPathList)
  (Err (Box CompilerDiagnostic)))

(define (typecheck-compiler-doc-expand-program-with-paths-and-pools
  [program : AstProgram]
  [paths : AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [pools : AstNodePoolContext]) : ResultCompilerDocExpand
  (begin
    (tc-spmd-inline-helper-stack-reset!)
    (let
      [generated-result : ResultGenProgramWithPaths
        (gen-normalize-program-with-paths-and-pools program paths "" pools)]
      (begin
        (ast-node-pool-context-install! pools)
        (match generated-result
          [(ResultGenProgramWithPaths.Ok generated generated-paths)
            (match (macro-expand-then-build-envs
              generated
              generated-paths
              pools
              stdlib-roots
              (typecheck-compiler-source-language-cfgs))
              [(ResultMacroExpand.Ok expanded expanded-paths)
                (begin
                  (ast-node-pool-context-capture-active! pools)
                  (ResultCompilerDocExpand.Ok expanded expanded-paths))]
              [(ResultMacroExpand.Err diag) (ResultCompilerDocExpand.Err diag)])]
          [(ResultGenProgramWithPaths.Err diag)
            (ResultCompilerDocExpand.Err diag)])))))

(define (typecheck-compiler-doc-expand-program-with-paths
  [program : AstProgram]
  [paths : AstDeclPathList]
  [stdlib-roots : svec.Vec]) : ResultCompilerDocExpand
  (typecheck-compiler-doc-expand-program-with-paths-and-pools
    program
    paths
    stdlib-roots
    (ast-node-pool-context-capture-active)))

(define (typecheck-compiler-program-with-paths-checked-cache-and-pools
  [program : AstProgram]
  [paths : AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]
  [pools : AstNodePoolContext]) : ResultCompilerTypecheckChecked
  (begin
    (tc-spmd-inline-helper-stack-reset!)
    (tc-typecheck-checked-result-with-pool-check
      (let
        [generated-result : ResultGenProgramWithPaths
          (gen-normalize-program-with-paths-and-pools program paths "" pools)]
        (begin
          (ast-node-pool-context-install! pools)
          (match generated-result
            [(ResultGenProgramWithPaths.Ok generated generated-paths)
              (match (macro-expand-then-build-envs
                generated
                generated-paths
                pools
                stdlib-roots
                (typecheck-compiler-source-language-cfgs))
                [(ResultMacroExpand.Ok expanded expanded-paths)
                  (begin
                    (ast-node-pool-context-capture-active! pools)
                    (if (compiler-specialize-needed? expanded)
                      (match (gen-normalize-program-with-paths-and-pools
                        expanded
                        expanded-paths
                        (tc-decl-path-list-last expanded-paths "")
                        pools)
                        [(ResultGenProgramWithPaths.Ok
                            normalized
                            normalized-paths)
                          (begin
                            (ast-node-pool-context-install! pools)
                            (if (compiler-specialize-needed? normalized)
                              (match (build-compiler-symbols-diagnostic-with-paths
                                normalized
                                normalized-paths)
                                [(ResultCompilerSymbolsDiagnostic.Ok _)
                                  (begin
                                    (ast-node-pool-context-capture-active!
                                      pools)
                                    (match (compiler-specialize-program-with-paths-and-pools
                                      normalized
                                      normalized-paths
                                      (tc-decl-path-list-last
                                        normalized-paths
                                        "")
                                      pools)
                                      [(ResultSpecProgramWithPaths.Ok
                                          specialized
                                          specialized-paths)
                                        (typecheck-compiler-specialized-program-with-paths-checked-cache-and-pools
                                          specialized
                                          specialized-paths
                                          stdlib-roots
                                          cache-scope
                                          pools)]
                                      [(ResultSpecProgramWithPaths.Err diag)
                                        (ResultCompilerTypecheckChecked.Err
                                          diag)]))]
                                [(ResultCompilerSymbolsDiagnostic.Err diag)
                                  (ResultCompilerTypecheckChecked.Err diag)])
                              (typecheck-compiler-specialized-program-with-paths-checked-cache-and-pools
                                normalized
                                normalized-paths
                                stdlib-roots
                                cache-scope
                                pools)))]
                        [(ResultGenProgramWithPaths.Err diag)
                          (ResultCompilerTypecheckChecked.Err diag)])
                      (typecheck-compiler-specialized-program-with-paths-checked-cache-and-pools
                        expanded
                        expanded-paths
                        stdlib-roots
                        cache-scope
                        pools)))]
                [(ResultMacroExpand.Err diag)
                  (ResultCompilerTypecheckChecked.Err diag)])]
            [(ResultGenProgramWithPaths.Err diag)
              (ResultCompilerTypecheckChecked.Err diag)]))))))

(define (typecheck-compiler-program-with-paths-checked-cache
  [program : AstProgram]
  [paths : AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cache-scope : String]) : ResultCompilerTypecheckChecked
  (typecheck-compiler-program-with-paths-checked-cache-and-pools
    program
    paths
    stdlib-roots
    cache-scope
    (ast-node-pool-context-capture-active)))

(define (typecheck-compiler-program-with-paths-checked
  [program : AstProgram]
  [paths : AstDeclPathList]) : ResultCompilerTypecheckChecked
  (typecheck-compiler-program-with-paths-checked-cache
    program
    paths
    (svec.new)
    (tc-prefix-default-cache-scope)))

(define (typecheck-compiler-program [program : AstProgram]) : ResultCompilerTypecheck
  (typecheck-compiler-program-with-paths program (ast-decl-path-list-new)))

(define (typecheck-compiler-source-language-cfgs) : sym_i64_env.SymI64Env
  (compiler-cfg-enable
    (compiler-cfg-enable
      (compiler-cfg-enable
        (compiler-cfg-enable
          (compiler-cfg-enable
            (compiler-cfg-enable
              (compiler-cfg-enable
                (compiler-cfg-enable
                  (compiler-cfg-enable
                    (compiler-cfg-empty)
                    "feature-ptr-addr-of")
                  "feature-str-view")
                "feature-runtime-str-view-extern")
              "feature-private-string-intrinsics")
            "feature-compiler-private-string-intrinsics")
          "array-helper-intrinsics")
        "feature-tl-memchr")
      "feature-plain-comptime-well-known")
    "feature-comptime-public-fields"))

(define (typecheck-compiler-source-load [src : String]) : ResultCompilerLoadWithPaths
  (let
    [stdlib-roots : svec.Vec (svec.new)]
    [cfgs : sym_i64_env.SymI64Env (typecheck-compiler-source-language-cfgs)]
    (match (compiler-load-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      stdlib-roots
      cfgs)
      [(ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (match (compiler-load-source-with-paths-and-roots-cfg
          ""
          src
          prelude-seen
          stdlib-roots
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

(define (typecheck-compiler-source-stdlib-import-kind?
  [kind : AstImportKind]
  [path : String]) : bool
  (match kind
    [(AstImportKind.Path) (compiler-load-stdlib-import? path)]
    [(AstImportKind.Module)
      (compiler-load-stdlib-import? (compiler-load-dotted-module-path path))]
    [_ false]))

(define (typecheck-compiler-source-decl-has-stdlib-import? [decl : AstDecl]) : bool
  (match decl
    [(AstDecl.Import (AstImportSpec.Spec kind path _ _ _))
      (typecheck-compiler-source-stdlib-import-kind? kind path)]
    [(AstDecl.Unsafe inner-box)
      (typecheck-compiler-source-decl-has-stdlib-import? (box-get inner-box))]
    [(AstDecl.ComptimeDecl _ template-box)
      (typecheck-compiler-source-decl-has-stdlib-import? (box-get template-box))]
    [_ false]))

(define (typecheck-compiler-source-decls-have-stdlib-import?
  [decls : AstDeclList]) : bool
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) false]
    [(AstDeclListStep.Cons decl rest)
      (or
        (typecheck-compiler-source-decl-has-stdlib-import? decl)
        (typecheck-compiler-source-decls-have-stdlib-import? rest))]))

(define (typecheck-compiler-source-program-has-stdlib-import?
  [program : AstProgram]) : bool
  (match program
    [(AstProgram.Program decls-box)
      (typecheck-compiler-source-decls-have-stdlib-import? (box-get decls-box))]))

(define (typecheck-compiler-repl-expr [decls : AstDeclList] [expr : AstExpr]) : ResultTcType
  (let
    [program : AstProgram (ast-program decls)]
    (begin
      (tc-clone-able-cache-reset!)
      (macro-alias-cache-reset!)
      (match (build-compiler-symbols program)
        [(ResultCompilerSymbols.Ok symbols)
          (match (build-compiler-registries program)
            [(ResultCompilerRegistries.Ok registries)
              (let
                [ctx : TcContext
                  (TcContext
                    program
                    symbols
                    registries
                    ""
                    (ast-node-pool-context-capture-active))]
                (match (tc-program-source-types-policy-ok ctx program)
                  [(ResultTcUnit.Ok)
                    (match (tc-source-expr-policy-ok ctx expr)
                      [(ResultTcUnit.Ok)
                        (match (tc-build-top-env ctx program)
                          [(ResultTcEnv.Ok top-env)
                            (match (tc-check-decls
                              ctx
                              top-env
                              decls
                              (CompilerTypecheckSummary 0 0 0))
                              [(ResultCompilerTypecheck.Ok _)
                                (tc-expr ctx top-env expr)]
                              [(ResultCompilerTypecheck.Err diag)
                                (ResultTcType.Err
                                  (compiler-diagnostic-message (box-get diag)))])]
                          [(ResultTcEnv.Err message) (ResultTcType.Err message)])]
                      [(ResultTcUnit.Err message) (ResultTcType.Err message)])]
                  [(ResultTcUnit.Err message) (ResultTcType.Err message)]))]
            [(ResultCompilerRegistries.Err message) (ResultTcType.Err message)])]
        [(ResultCompilerSymbols.Err message) (ResultTcType.Err message)]))))

(define (typecheck-compiler-source [src : String]) : ResultCompilerTypecheck
  (let
    [_cache-reset : unit (tc-prefix-snapshot-cache-clear!)]
    [_dedup-reset : unit (ty-node-dedup-clear!)]
    [_reset-before : unit (compiler-typecheck-reset-file-state!)]
    [result : ResultCompilerTypecheck
      (match (parse-ast-source-diagnostic "" src)
        [(ResultAstProgramDiagnostic.Ok program)
          ;; Keep synthetic in-memory fixtures on the historical direct path,
          ;; but route real stdlib imports through the loader so macro imports
          ;; see loaded stdlib macro definitions and alias markers.
          (if (typecheck-compiler-source-program-has-stdlib-import? program)
            (match (typecheck-compiler-source-load src)
              [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
                (typecheck-compiler-program-with-paths
                  (ast-program decls)
                  paths)]
              [(ResultCompilerLoadWithPaths.Err diag)
                (ResultCompilerTypecheck.Err diag)])
            (typecheck-compiler-program program))]
        [(ResultAstProgramDiagnostic.Err diag)
          (ResultCompilerTypecheck.Err diag)])]
    (begin
      (compiler-typecheck-reset-file-state!)
      result)))

(define (typecheck-compiler-source-with-cfg
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerTypecheck
  (let
    [_cache-reset : unit (tc-prefix-snapshot-cache-clear!)]
    [_dedup-reset : unit (ty-node-dedup-clear!)]
    [_reset-before : unit (compiler-typecheck-reset-file-state!)]
    [result : ResultCompilerTypecheck
      (match (parse-ast-source-diagnostic-with-cfg "" src cfgs)
        [(ResultAstProgramDiagnostic.Ok program)
          (typecheck-compiler-program program)]
        [(ResultAstProgramDiagnostic.Err diag)
          (ResultCompilerTypecheck.Err diag)])]
    (begin
      (compiler-typecheck-reset-file-state!)
      result)))

(define (compiler-typecheck-summary-score [summary : CompilerTypecheckSummary]) : i64
  (match summary
    [(CompilerTypecheckSummary values functions externs)
      (+ values (+ (* functions 10) (* externs 100)))]))