;; compiler_check_core.tl - Shared selfhost check/typecheck helpers.
(import compiler_owned_view as owned_view)
(cfg compile-profile (import stdlib.str_cat_runtime as str_cat))
(cfg compile-profile (import stdlib.io))
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(cfg compile-profile (import stdlib.profile))
(import compiler_load)
(import compiler_parse_core as parser)
(import compiler_ast_types as ast)
(import compiler_cfg_core as cfg_core)
(import compiler_diagnostic as cdiag)
(import compiler_typecheck_api)
(import compiler_typecheck_core as tc)
(import compiler_target_cfg_core as target_cfg)
(import sym_i64_env)

(defenum ResultCompilerCheck
  (Ok tc.CompilerTypecheckSummary cdiag.CompilerAdvisoryList)
  (Err (Box cdiag.CompilerDiagnosticList) cdiag.CompilerAdvisoryList))

(defenum ResultCompilerCheckWithPaths
  (Ok
    tc.CompilerTypecheckSummary
    ast.AstDeclPathList
    cdiag.CompilerAdvisoryList)
  (Err (Box cdiag.CompilerDiagnosticList) cdiag.CompilerAdvisoryList))

(define (compiler-check-advisories-for-job [job-state : tc.TcJobState]) : cdiag.CompilerAdvisoryList
  (cdiag.compiler-advisory-sink-snapshot
    (tc.tc-job-state-advisory-sink job-state)))

(define (compiler-check-serial-advisories) : cdiag.CompilerAdvisoryList
  (compiler-check-advisories-for-job (tc.tc-serial-job-state)))

(cfg
  compile-profile
  (define compiler-check-profile-start-ms : i64
    0))

(cfg
  compile-profile
  (define (compiler-check-profile-start) : unit
    (set! compiler-check-profile-start-ms (profile.now-ms))))

(cfg
  compile-profile
  (define (compiler-check-profile-finish [phase : String]) : unit
    (io.print-error
      (str_cat.str-cat
        "compile-profile|check."
        phase
        "|"
        (string.int->string
          (- (profile.now-ms) compiler-check-profile-start-ms))
        "|0|0|0\n"))))

(define (compiler-check-language-cfgs) : sym_i64_env.SymI64Env
  (target_cfg.compiler-target-cfgs
    target_cfg.CompilerTargetCfg.Linux
    (cfg_core.compiler-cfg-empty)))

(define (compiler-check-diagnostic-with-fallback-path
  [diag : cdiag.CompilerDiagnostic]
  [path : String]) : cdiag.CompilerDiagnostic
  (cdiag.compiler-diagnostic-with-fallback-path diag path))

(define (compiler-check-diagnostics-with-fallback-path
  [diagnostics : cdiag.CompilerDiagnosticList]
  [path : String]) : cdiag.CompilerDiagnosticList
  (let
    [count : i64
      (cdiag.compiler-diagnostic-list-count
        (owned_view.compiler-owned-shared-view diagnostics))]
    [index : i64 0]
    [out : cdiag.CompilerDiagnosticList
      (cdiag.compiler-diagnostic-list-with-capacity count)]
    (begin
      (while (< index count)
        (begin
          (cdiag.compiler-diagnostic-list-push!
            (&mut out)
            (compiler-check-diagnostic-with-fallback-path
              (cdiag.compiler-diagnostic-list-get
                (owned_view.compiler-owned-shared-view diagnostics)
                index)
              (owned_view.compiler-owned-shared-view path)))
          (set! index (+ index 1))))
      out)))

(define (compiler-check-diagnostic-before?
  [left : (& left cdiag.CompilerDiagnostic)]
  [right : (& right cdiag.CompilerDiagnostic)]) : bool
  (let
    [left-primary : (& left cdiag.CompilerDiagnosticSpan) (& left.primary)]
    [right-primary : (& right cdiag.CompilerDiagnosticSpan) (& right.primary)]
    (if (string.eq (& left-primary.path) (& right-primary.path))
      (let
        [left-line : i64 left-primary.start-line]
        [right-line : i64 right-primary.start-line]
        (or
          (< left-line right-line)
          (and
            (= left-line right-line)
            (< left-primary.start-col right-primary.start-col))))
      false)))

(define (compiler-check-diagnostic-list-insert-source-order
  [diag : cdiag.CompilerDiagnostic]
  [sorted : (&mut sorted cdiag.CompilerDiagnosticList)]) : unit
  (let
    [count : i64 sorted.len]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (if (compiler-check-diagnostic-before?
          (& diag)
          (cdiag.compiler-diagnostic-list-ref sorted index))
          (set! found true)
          (set! index (+ index 1))))
      (cdiag.compiler-diagnostic-list-insert! sorted index diag))))

(define (compiler-check-diagnostic-list-insert-all-source-order
  [incoming : cdiag.CompilerDiagnosticList]
  [sorted : (&mut sorted cdiag.CompilerDiagnosticList)]) : unit
  (let
    [count : i64
      (cdiag.compiler-diagnostic-list-count
        (owned_view.compiler-owned-shared-view incoming))]
    [index : i64 0]
    (while (< index count)
      (begin
        (compiler-check-diagnostic-list-insert-source-order
          (cdiag.compiler-diagnostic-list-get
            (owned_view.compiler-owned-shared-view incoming)
            index)
          sorted)
        (set! index (+ index 1))))))

(define (compiler-check-result-with-parse-diagnostics
  [parse-diagnostics : cdiag.CompilerDiagnosticList]
  [result : ResultCompilerCheck]) : ResultCompilerCheck
  (if (=
    (cdiag.compiler-diagnostic-list-count
      (owned_view.compiler-owned-shared-view parse-diagnostics))
    0)
    result
    (let
      [count : i64
        (cdiag.compiler-diagnostic-list-count
          (owned_view.compiler-owned-shared-view parse-diagnostics))]
      [index : i64 0]
      [owned-parse : cdiag.CompilerDiagnosticList
        (cdiag.compiler-diagnostic-list-with-capacity count)]
      (begin
        (while (< index count)
          (begin
            (cdiag.compiler-diagnostic-list-push!
              (&mut owned-parse)
              (cdiag.compiler-diagnostic-list-get
                (owned_view.compiler-owned-shared-view parse-diagnostics)
                index))
            (set! index (+ index 1))))
        (match result
          [(ResultCompilerCheck.Ok _ advisories)
            (ResultCompilerCheck.Err (box owned-parse) advisories)]
          [(ResultCompilerCheck.Err semantic-diagnostics advisories)
            (begin
              (compiler-check-diagnostic-list-insert-all-source-order
                (deref semantic-diagnostics)
                (&mut owned-parse))
              (ResultCompilerCheck.Err (box owned-parse) advisories))])))))

(define (compiler-check-reset-pools!) : unit
  (compiler_load.compiler-load-session-reset-pools!))

(define (compiler-check-reset-interns!) : unit
  (begin
    (compiler_load.compiler-load-session-reset-interns!)
    (tc.compiler-typecheck-reset-intern-owned-state!)))

(define (compiler-check-program-with-paths-cache-and-job-state
  [path : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope : String]
  [job-state : tc.TcJobState]) : ResultCompilerCheck
  (begin
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler_typecheck_api.typecheck-compiler-program-with-paths-cache-and-load-state-and-prefix-cache-state-and-pools
      (compiler_load.compiler-load-serial-test-session-state)
      (tc.tc-prefix-snapshot-serial-test-cache-state-shared-view)
      job-state
      (ast.ast-program decls)
      paths
      stdlib-roots
      cfgs
      cache-scope
      (ast.ast-node-pool-context-capture-active))
      [(tc.ResultCompilerTypecheck.Ok summary)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "typecheck"))
          (ResultCompilerCheck.Ok
            summary
            (compiler-check-advisories-for-job job-state)))]
      [(tc.ResultCompilerTypecheck.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "typecheck"))
          (ResultCompilerCheck.Err
            (box
              (compiler-check-diagnostics-with-fallback-path (deref diag) path))
            (compiler-check-advisories-for-job job-state)))])))

(define (compiler-check-program-with-paths-cache
  [path : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope : String]) : ResultCompilerCheck
  (compiler-check-program-with-paths-cache-and-job-state
    path
    decls
    paths
    stdlib-roots
    cfgs
    cache-scope
    (tc.tc-serial-job-state)))

(define (compiler-check-loaded-with-prelude-cache-and-job-state
  [path : String]
  [prelude-decls : ast.AstDeclList]
  [prelude-paths : ast.AstDeclPathList]
  [loaded : compiler_load.ResultCompilerLoadWithPaths]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope : String]
  [job-state : tc.TcJobState]) : ResultCompilerCheck
  (match loaded
    [(compiler_load.ResultCompilerLoadWithPaths.Ok
        entry-decls
        entry-paths
        entry-modules
        _)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (compiler-check-program-with-paths-cache-and-job-state
          path
          (compiler_load.compiler-load-decl-list-append
            prelude-decls
            entry-decls)
          (compiler_load.compiler-load-decl-path-list-append
            prelude-paths
            (ast.ast-decl-path-list-with-modules entry-paths entry-modules))
          stdlib-roots
          cfgs
          cache-scope
          job-state))]
    [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheck.Err
          (cdiag.compiler-diagnostic-list-box-single diag)
          (compiler-check-advisories-for-job job-state)))]))

(define (compiler-check-loaded-with-prelude-cache
  [path : String]
  [prelude-decls : ast.AstDeclList]
  [prelude-paths : ast.AstDeclPathList]
  [loaded : compiler_load.ResultCompilerLoadWithPaths]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope : String]) : ResultCompilerCheck
  (compiler-check-loaded-with-prelude-cache-and-job-state
    path
    prelude-decls
    prelude-paths
    loaded
    stdlib-roots
    cfgs
    cache-scope
    (tc.tc-serial-job-state)))

(define (compiler-check-source-with-prelude-recovery
  [path : String]
  [source : String]
  [prelude-decls : ast.AstDeclList]
  [prelude-paths : ast.AstDeclPathList]
  [prelude-seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope : String]
  [job-state : tc.TcJobState]) : ResultCompilerCheck
  (match (parser.parse-ast-source-recovery-diagnostic-with-cfg
    (owned_view.compiler-owned-shared-view path)
    source
    cfgs)
    [(parser.ResultAstProgramRecovery.Fatal diagnostics)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheck.Err
          diagnostics
          (compiler-check-advisories-for-job job-state)))]
    [(parser.ResultAstProgramRecovery.Parsed program diagnostics)
      (let
        [parse-identity : compiler_load.CompilerLoadParseIdentity
          (compiler_load.compiler-load-parse-identity
            (owned_view.compiler-owned-shared-view path)
            (compiler_load.compiler-load-canonical-module-id-from-path path)
            ast.AstMaybeModuleName.No)]
        [loaded : compiler_load.ResultCompilerLoadWithPaths
          (compiler_load.compiler-load-program-with-paths-and-roots-expect-cfg
            (owned_view.compiler-owned-shared-view path)
            program
            prelude-seen
            (owned_view.compiler-owned-shared-view stdlib-roots)
            ast.AstMaybeModuleName.No
            cfgs
            parse-identity)]
        (compiler-check-result-with-parse-diagnostics
          (deref diagnostics)
          (compiler-check-loaded-with-prelude-cache-and-job-state
            path
            prelude-decls
            prelude-paths
            loaded
            stdlib-roots
            cfgs
            cache-scope
            job-state)))]))

(define (compiler-check-loaded-cache-with-paths
  [path : String]
  [loaded : compiler_load.ResultCompilerLoadWithPaths]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [cache-scope : String]) : ResultCompilerCheckWithPaths
  (match loaded
    [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths modules _)
      (let
        [owned-paths : ast.AstDeclPathList
          (ast.ast-decl-path-list-with-modules paths modules)]
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (match (compiler-check-program-with-paths-cache
            path
            decls
            (owned_view.compiler-owned-shared-view owned-paths)
            stdlib-roots
            cfgs
            cache-scope)
            [(ResultCompilerCheck.Ok summary advisories)
              (ResultCompilerCheckWithPaths.Ok summary owned-paths advisories)]
            [(ResultCompilerCheck.Err diag advisories)
              (ResultCompilerCheckWithPaths.Err diag advisories)])))]
    [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheckWithPaths.Err
          (cdiag.compiler-diagnostic-list-box-single diag)
          (compiler-check-serial-advisories)))]))

(define (compiler-check-file-with-roots
  [path : String]
  [stdlib-roots : svec.Vec]) : ResultCompilerCheck
  (compiler-check-file-with-roots-and-cfg
    path
    stdlib-roots
    (compiler-check-language-cfgs)))

(define (compiler-check-file-with-roots-and-cfg
  [path : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerCheck
  (compiler-check-source-with-roots-and-cfg
    (owned_view.compiler-owned-shared-view path)
    (compiler_load.compiler-load-read-file-text path)
    stdlib-roots
    cfgs))

(define (compiler-check-package-source-with-prelude-recovery
  [path : String]
  [source : String]
  [prelude-decls : ast.AstDeclList]
  [prelude-paths : ast.AstDeclPathList]
  [prelude-seen : sym_i64_env.SymI64Env]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerCheck
  (match (parser.parse-ast-source-recovery-diagnostic-with-cfg
    (owned_view.compiler-owned-shared-view path)
    source
    cfgs)
    [(parser.ResultAstProgramRecovery.Fatal diagnostics)
      (begin
        (cfg compile-profile (compiler-check-profile-finish "load"))
        (ResultCompilerCheck.Err diagnostics (compiler-check-serial-advisories)))]
    [(parser.ResultAstProgramRecovery.Parsed program diagnostics)
      (let
        [parse-identity : compiler_load.CompilerLoadParseIdentity
          (compiler_load.compiler-load-parse-identity
            (owned_view.compiler-owned-shared-view path)
            (compiler_load.compiler-load-canonical-module-id-from-path path)
            ast.AstMaybeModuleName.No)]
        [loaded : compiler_load.ResultCompilerLoadWithPaths
          (compiler_load.compiler-load-package-program-with-paths-and-roots-expect
            (owned_view.compiler-owned-shared-view path)
            program
            prelude-seen
            (owned_view.compiler-owned-shared-view stdlib-roots)
            ast.AstMaybeModuleName.No
            manifest-dir
            deps
            cfgs
            parse-identity)]
        (compiler-check-result-with-parse-diagnostics
          (deref diagnostics)
          (compiler-check-loaded-with-prelude-cache
            path
            prelude-decls
            prelude-paths
            loaded
            (owned_view.compiler-owned-shared-view stdlib-roots)
            cfgs
            (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
              "typecheck-prefix-check"
              stdlib-roots
              cfgs))))]))

(define (compiler-check-package-source-with-roots-and-cfg
  [path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (tc.tc-job-state-reset-advisories! (tc.tc-serial-job-state))
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler_load.compiler-load-package-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      (owned_view.compiler-owned-shared-view stdlib-roots)
      (owned_view.compiler-owned-shared-view manifest-dir)
      (owned_view.compiler-owned-shared-view deps)
      cfgs)
      [(compiler_load.ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (compiler-check-package-source-with-prelude-recovery
          path
          source
          prelude-decls
          (ast.ast-decl-path-list-with-modules prelude-paths prelude-modules)
          prelude-seen
          stdlib-roots
          manifest-dir
          deps
          cfgs)]
      [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ResultCompilerCheck.Err
            (cdiag.compiler-diagnostic-list-box-single diag)
            (compiler-check-serial-advisories)))])))

(define (compiler-check-package-entry-file-with-roots-and-cfg
  [path : String]
  [stdlib-roots : svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [emit-entry : bool]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerCheckWithPaths
  (begin
    (compiler-check-reset-pools!)
    (tc.tc-job-state-reset-advisories! (tc.tc-serial-job-state))
    (cfg compile-profile (compiler-check-profile-start))
    (compiler-check-loaded-cache-with-paths
      (owned_view.compiler-owned-shared-view path)
      (compiler_load.compiler-load-package-file-with-runtime-cfg
        path
        (owned_view.compiler-owned-shared-view stdlib-roots)
        manifest-dir
        deps
        emit-entry
        cfgs)
      (owned_view.compiler-owned-shared-view stdlib-roots)
      cfgs
      (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
        "typecheck-prefix-check"
        stdlib-roots
        cfgs))))

(define (compiler-check-source [path : String] [source : String]) : ResultCompilerCheck
  (compiler-check-source-with-roots-and-cfg
    path
    source
    (svec.new)
    (compiler-check-language-cfgs)))

(define (compiler-check-source-with-roots-and-cfg-and-job-state
  [path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]
  [job-state : tc.TcJobState]) : ResultCompilerCheck
  (begin
    (compiler-check-reset-pools!)
    (tc.tc-job-state-reset-advisories! job-state)
    (cfg compile-profile (compiler-check-profile-start))
    (match (compiler_load.compiler-load-core-macro-prelude-with-roots-cfg
      (sym_i64_env.sym-i64-empty)
      (owned_view.compiler-owned-shared-view stdlib-roots)
      cfgs)
      [(compiler_load.ResultCompilerLoadWithPaths.Ok
          prelude-decls
          prelude-paths
          prelude-modules
          prelude-seen)
        (compiler-check-source-with-prelude-recovery
          path
          source
          prelude-decls
          (ast.ast-decl-path-list-with-modules prelude-paths prelude-modules)
          prelude-seen
          (owned_view.compiler-owned-shared-view stdlib-roots)
          cfgs
          (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
            "typecheck-prefix-check"
            stdlib-roots
            cfgs)
          job-state)]
      [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
        (begin
          (cfg compile-profile (compiler-check-profile-finish "load"))
          (ResultCompilerCheck.Err
            (cdiag.compiler-diagnostic-list-box-single diag)
            (compiler-check-advisories-for-job job-state)))])))

(define (compiler-check-source-with-roots-and-cfg
  [path : String]
  [source : String]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : ResultCompilerCheck
  (compiler-check-source-with-roots-and-cfg-and-job-state
    path
    source
    stdlib-roots
    cfgs
    (tc.tc-serial-job-state)))