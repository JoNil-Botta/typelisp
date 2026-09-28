;; check_cli_core.tl - Self-hosted `check` (typecheck) command logic.
;;
;; Main-free, so the unified `main.tl` dispatcher runs the command without a
;; duplicate `main`.
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector String) as cli_svec)
(import cli_option_core as cli_option)
(import compiler_target_cfg_core as target_cfg)
(import compiler_check_core)
(import compiler_driver_core)
(import doc_test)
(import compiler_load)
(import compiler_ast_types as ast)
(import compiler_diagnostic as cdiag)
(import compiler_intern as ci)
(import package_source_core)
(import test_cli_core)
(import compiler_builtin_ids as cbi)
(import stdlib.string)
(import sym_i64_env)

(defenum SelfhostCheckConfig
  (File String cli_svec.Vec target_cfg.CompilerTargetCfg cli_svec.Vec)
  (Package String bool cli_svec.Vec target_cfg.CompilerTargetCfg cli_svec.Vec))

(defenum ResultSelfhostCheckConfig
  (Ok SelfhostCheckConfig)
  (Err String))

;; Parse the `check` config from arguments starting at `start`. `count` is
;; `(arg-count)`.
(define (selfhost-check-config-from [start : i64] [count : i64]) : ResultSelfhostCheckConfig
  (let
    [args : cli_option.CliArgs
      (cli_option.cli-args
        "selfhost-check"
        "--stdlib-root <dir> --cfg <name> --target <target> --manifest-path <file>"
        start
        count)]
    [input-path : String ""]
    [has-input : bool false]
    [manifest-path : String ""]
    [has-manifest : bool false]
    [stdlib-roots : cli_svec.Vec (cli_svec.new)]
    [target : target_cfg.CompilerTargetCfg
      (target_cfg.compiler-target-cfg-default)]
    [has-target : bool false]
    [cfg-names : cli_svec.Vec (cli_svec.new)]
    (begin
      (while (cli_option.cli-args-next! (&mut args))
        (cond
          [(string.eq args.name "--stdlib-root")
            (cli_svec.push-ref!
              (&mut stdlib-roots)
              (cli_option.cli-args-value (& args)))]
          [(string.eq args.name "--cfg")
            (cli_svec.push-ref!
              (&mut cfg-names)
              (cli_option.cli-args-value (& args)))]
          [(string.eq args.name "--target")
            (if has-target
              (cli_option.cli-args-fail!
                (&mut args)
                "selfhost-check: --target was provided more than once")
              (match (target_cfg.compiler-target-cfg-parse
                (cli_option.cli-args-value (& args)))
                [(target_cfg.ResultCompilerTargetCfg.Ok parsed-target)
                  (begin
                    (set! target parsed-target)
                    (set! has-target true))]
                [(target_cfg.ResultCompilerTargetCfg.Err message)
                  (cli_option.cli-args-fail!
                    (&mut args)
                    (str_cat.str-cat "selfhost-check: " message))]))]
          [(string.eq args.name "--manifest-path")
            (if has-manifest
              (cli_option.cli-args-fail!
                (&mut args)
                "selfhost-check: duplicate --manifest-path")
              (begin
                (set! manifest-path (cli_option.cli-args-value (& args)))
                (set! has-manifest true)))]
          [(cli_option.cli-flag? args.arg)
            (cli_option.cli-args-fail-arg!
              (&mut args)
              "selfhost-check: unknown flag ")]
          [has-input
            (cli_option.cli-args-fail-arg!
              (&mut args)
              "selfhost-check: unexpected argument ")]
          [else
            (begin
              (set! input-path (string.copy (& args.arg)))
              (set! has-input true))]))
      (cond
        [args.failed (ResultSelfhostCheckConfig.Err args.error)]
        [(and has-input has-manifest)
          (ResultSelfhostCheckConfig.Err
            "selfhost-check: cannot combine input path with --manifest-path")]
        [has-input
          (ResultSelfhostCheckConfig.Ok
            (SelfhostCheckConfig.File input-path stdlib-roots target cfg-names))]
        [else
          (ResultSelfhostCheckConfig.Ok
            (SelfhostCheckConfig.Package
              manifest-path
              has-manifest
              stdlib-roots
              target
              cfg-names))]))))

(define (selfhost-check-print-passed) : i64
  (begin
    (io.print-format "{}" "Type checking passed!\n")
    0))

(define (selfhost-check-file-doctests
  [input-path : String]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : i64
  (doc_test.doc-test-report-status
    (doc_test.doc-test-typecheck-file-with-roots-and-cfg
      input-path
      stdlib-roots
      cfgs)))

(define (selfhost-check-package-doctests
  [paths : ast.AstDeclPathList]
  [stdlib-roots : cli_svec.Vec]
  [manifest-dir : String]
  [deps : compiler_load.CompilerPkgDeps]
  [cfgs : sym_i64_env.SymI64Env]) : i64
  (doc_test.doc-test-report-status
    (doc_test.doc-test-typecheck-package-paths-with-roots-and-cfg
      paths
      stdlib-roots
      manifest-dir
      deps
      cfgs)))

(define (selfhost-check-report-diagnostics
  [diagnostics : cdiag.CompilerDiagnosticList]) : unit
  (let
    [count : i64 (cdiag.compiler-diagnostic-list-count diagnostics)]
    [index : i64 0]
    (while (< index count)
      (begin
        (io.print-error
          (compiler_driver_core.compiler-driver-render-source-diagnostic
            (cdiag.compiler-diagnostic-list-get diagnostics index)))
        (set! index (+ index 1))))))

(define (selfhost-check-file
  [input-path : String]
  [stdlib-roots : cli_svec.Vec]
  [target : target_cfg.CompilerTargetCfg]
  [cfg-names : cli_svec.Vec]) : i64
  (let
    [check-cfgs : sym_i64_env.SymI64Env
      (target_cfg.compiler-target-cfgs-with-names
        target
        (owned_view.compiler-owned-shared-view cfg-names))]
    (match (compiler_check_core.compiler-check-file-with-roots-and-cfg
      (owned_view.compiler-owned-shared-view input-path)
      (owned_view.compiler-owned-shared-view stdlib-roots)
      check-cfgs)
      [(compiler_check_core.ResultCompilerCheck.Ok _ advisories)
        (begin
          (compiler_driver_core.compiler-driver-print-advisories (& advisories))
          (let
            [inline-test-status : i64
              (test_cli_core.tltest-inline-typecheck-file-with-cfg
                (owned_view.compiler-owned-shared-view input-path)
                (owned_view.compiler-owned-shared-view stdlib-roots)
                (target_cfg.compiler-target-cfgs-with-names
                  target
                  (owned_view.compiler-owned-shared-view cfg-names))
                "typecheck-prefix-inline-check")]
            (if (= inline-test-status 0)
              (let
                [doctest-status : i64
                  (selfhost-check-file-doctests
                    input-path
                    stdlib-roots
                    (target_cfg.compiler-target-cfgs-with-names
                      target
                      cfg-names))]
                (if (= doctest-status 0)
                  (selfhost-check-print-passed)
                  doctest-status))
              inline-test-status)))]
      [(compiler_check_core.ResultCompilerCheck.Err diag advisories)
        (begin
          (compiler_driver_core.compiler-driver-print-advisories (& advisories))
          (selfhost-check-report-diagnostics (deref diag))
          1)])))

(define (selfhost-check-package-kind-entry?
  [kind : compiler_load.CompilerPkgKind]) : bool
  (match kind
    [(CompilerPkgKindBin) true]
    [(CompilerPkgKindLib) false]))

(define (selfhost-check-package-entry-path
  [manifest-dir : String]
  [manifest : compiler_load.CompilerPkgManifest]) : String
  (compiler_load.compiler-load-normalize-path
    (compiler_load.compiler-load-join-root-path manifest-dir manifest.entry)))

(define (selfhost-check-package-doctest-paths-snapshot
  [paths : ast.AstDeclPathList]) : ast.AstDeclPathList
  (let
    [count : i64 (ast.ast-decl-path-list-len (& paths))]
    [out : ast.AstDeclPathList (ast.ast-decl-path-list-with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [path : String (ast.ast-decl-path-list-get (& paths) index "")]
          [owned-path : String
            (string.substring path 0 (string.string-length path))]
          (begin
            (ast.ast-decl-path-list-push-with-owner-and-provenance-id
              (&mut out)
              owned-path
              cbi.compiler-builtin-id-fix-empty
              (ast.ast-decl-path-list-provenance-id
                (& paths)
                index
                cbi.compiler-builtin-id-fix-empty))
            (set! index (+ index 1)))))
      out)))

(define (selfhost-check-package
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : cli_svec.Vec]
  [target : target_cfg.CompilerTargetCfg]
  [cfg-names : cli_svec.Vec]) : i64
  (match (package_source_core.package-source-discover-for
    "check"
    manifest-path
    has-manifest)
    [(package_source_core.ResultPackageSourceSet.Err message)
      (begin
        (io.print-error message)
        1)]
    [(package_source_core.ResultPackageSourceSet.Ok source-set)
      (let
        [manifest : compiler_load.CompilerPkgManifest source-set.manifest]
        [manifest-dir : String source-set.manifest-dir]
        [name : String (owned_view.compiler-owned-shared-view manifest.name)]
        [entry-path : String
          (selfhost-check-package-entry-path
            (owned_view.compiler-owned-shared-view manifest-dir)
            (owned_view.compiler-owned-shared-view manifest))]
        [emit-entry : bool (selfhost-check-package-kind-entry? manifest.kind)]
        [_reset-file-state : unit
          (compiler_driver_core.compiler-driver-reset-file-state!)]
        (match (compiler_check_core.compiler-check-package-entry-file-with-roots-and-cfg
          entry-path
          (owned_view.compiler-owned-shared-view stdlib-roots)
          (owned_view.compiler-owned-shared-view manifest-dir)
          (owned_view.compiler-owned-shared-view manifest.deps)
          emit-entry
          (target_cfg.compiler-target-cfgs-with-names
            target
            (owned_view.compiler-owned-shared-view cfg-names)))
          [(compiler_check_core.ResultCompilerCheckWithPaths.Ok
              _
              paths
              advisories)
            (begin
              (compiler_driver_core.compiler-driver-print-advisories
                (& advisories))
              (let
                ;; Doctests run after the compiler and intern arenas are reset.
                ;; Filesystem paths are values here, so retain owned copies rather
                ;; than carrying parser identity across that lifetime boundary.
                [doctest-paths : ast.AstDeclPathList
                  (selfhost-check-package-doctest-paths-snapshot paths)]
                ;; Match standalone package inline-test runs: entry checking can
                ;; leave enough compiler state live to exhaust long package checks.
                [_reset-after-entry : unit
                  (begin
                    (compiler_driver_core.compiler-driver-reset-file-state!)
                    (ci.intern-persistent-arena-reset!))]
                [inline-test-status : i64
                  (test_cli_core.tltest-inline-typecheck-package-sources-with-cfg
                    source-set.sources
                    (owned_view.compiler-owned-shared-view stdlib-roots)
                    (owned_view.compiler-owned-shared-view manifest-dir)
                    name
                    (owned_view.compiler-owned-shared-view manifest.deps)
                    (target_cfg.compiler-target-cfgs-with-names
                      target
                      (owned_view.compiler-owned-shared-view cfg-names))
                    "typecheck-prefix-inline-check-package")]
                (if (= inline-test-status 0)
                  (let
                    [doctest-status : i64
                      (selfhost-check-package-doctests
                        doctest-paths
                        stdlib-roots
                        manifest-dir
                        manifest.deps
                        (target_cfg.compiler-target-cfgs-with-names
                          target
                          cfg-names))]
                    (if (= doctest-status 0)
                      (selfhost-check-print-passed)
                      doctest-status))
                  inline-test-status)))]
          [(compiler_check_core.ResultCompilerCheckWithPaths.Err
              diag
              advisories)
            (begin
              (compiler_driver_core.compiler-driver-print-advisories
                (& advisories))
              (selfhost-check-report-diagnostics
                (cdiag.compiler-diagnostic-list-box-shared-view diag))
              1)]))]))

;; Run the `check` command over arguments starting at `start`.
(define (selfhost-check-run-from [start : i64] [count : i64]) : i64
  (match (selfhost-check-config-from start count)
    [(ResultSelfhostCheckConfig.Ok config)
      (match config
        [(SelfhostCheckConfig.File input-path stdlib-roots target cfg-names)
          (selfhost-check-file input-path stdlib-roots target cfg-names)]
        [(SelfhostCheckConfig.Package
            manifest-path
            has-manifest
            stdlib-roots
            target
            cfg-names)
          (selfhost-check-package
            manifest-path
            has-manifest
            stdlib-roots
            target
            cfg-names)])]
    [(ResultSelfhostCheckConfig.Err message)
      (begin
        (io.print-error message)
        1)]))