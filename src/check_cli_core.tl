;; check_cli_core.tl - Self-hosted `check` (typecheck) command logic.
;;
;; Factored out of `check.tl` so the unified `cli.tl` dispatcher and the
;; retained check compatibility/coverage driver share the command without a
;; duplicate `main`.
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

(define (selfhost-check-flag? [value : String]) : bool
  (and (> (string.string-length value) 0) (= (string.string-ref value 0) '-')))

(define (selfhost-check-config-finish
  [input-path : String]
  [has-input : bool]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : cli_svec.Vec]
  [target : target_cfg.CompilerTargetCfg]
  [cfg-names : cli_svec.Vec]) : ResultSelfhostCheckConfig
  (if has-input
    (if has-manifest
      (ResultSelfhostCheckConfig.Err
        "selfhost-check: cannot combine input path with --manifest-path")
      (ResultSelfhostCheckConfig.Ok
        (SelfhostCheckConfig.File input-path stdlib-roots target cfg-names)))
    (ResultSelfhostCheckConfig.Ok
      (SelfhostCheckConfig.Package
        manifest-path
        has-manifest
        stdlib-roots
        target
        cfg-names))))

(define (selfhost-check-parse-args
  [idx : i64]
  [count : i64]
  [input-path : String]
  [has-input : bool]
  [manifest-path : String]
  [has-manifest : bool]
  [stdlib-roots : cli_svec.Vec (:consume)]
  [target : target_cfg.CompilerTargetCfg]
  [has-target : bool]
  [cfg-names : cli_svec.Vec (:consume)]) : ResultSelfhostCheckConfig
  (if (>= idx count)
    (selfhost-check-config-finish
      input-path
      has-input
      manifest-path
      has-manifest
      stdlib-roots
      target
      cfg-names)
    (let
      [current : String (io.arg idx)]
      (match (cli_option.cli-common-option-parse
        current
        idx
        count
        (bit-or
          cli_option.cli-common-option-stdlib-root
          (bit-or
            cli_option.cli-common-option-cfg
            cli_option.cli-common-option-target)))
        [(cli_option.CliCommonOption.Missing kind)
          (ResultSelfhostCheckConfig.Err
            (cli_option.cli-common-option-missing-message "selfhost-check" kind))]
        [(cli_option.CliCommonOption.Value kind value next-idx)
          (match kind
            [(cli_option.CliCommonOptionKind.StdlibRoot)
              (selfhost-check-parse-args
                next-idx
                count
                input-path
                has-input
                manifest-path
                has-manifest
                (let
                  [next-roots : cli_svec.Vec stdlib-roots]
                  (begin
                    (cli_svec.push-ref! (&mut next-roots) value)
                    next-roots))
                target
                has-target
                cfg-names)]
            [(cli_option.CliCommonOptionKind.Cfg)
              (selfhost-check-parse-args
                next-idx
                count
                input-path
                has-input
                manifest-path
                has-manifest
                stdlib-roots
                target
                has-target
                (let
                  [next-cfg-names : cli_svec.Vec cfg-names]
                  (begin
                    (cli_svec.push-ref! (&mut next-cfg-names) value)
                    next-cfg-names)))]
            [(cli_option.CliCommonOptionKind.Target)
              (if has-target
                (ResultSelfhostCheckConfig.Err
                  "selfhost-check: --target was provided more than once")
                (match (target_cfg.compiler-target-cfg-parse value)
                  [(target_cfg.ResultCompilerTargetCfg.Ok parsed-target)
                    (selfhost-check-parse-args
                      next-idx
                      count
                      input-path
                      has-input
                      manifest-path
                      has-manifest
                      stdlib-roots
                      parsed-target
                      true
                      cfg-names)]
                  [(target_cfg.ResultCompilerTargetCfg.Err message)
                    (ResultSelfhostCheckConfig.Err
                      (str_cat.str-cat "selfhost-check: " message))]))]
            [(cli_option.CliCommonOptionKind.OptLevel)
              (ResultSelfhostCheckConfig.Err
                "selfhost-check: internal unsupported common option")])]
        [(cli_option.CliCommonOption.NotCommon)
          (cond
            [(string.eq current "--manifest-path")
              (if (>= (+ idx 1) count)
                (ResultSelfhostCheckConfig.Err
                  "selfhost-check: --manifest-path requires a value")
                (if has-manifest
                  (ResultSelfhostCheckConfig.Err
                    "selfhost-check: duplicate --manifest-path")
                  (selfhost-check-parse-args
                    (+ idx 2)
                    count
                    input-path
                    has-input
                    (io.arg (+ idx 1))
                    true
                    stdlib-roots
                    target
                    has-target
                    cfg-names)))]
            [(selfhost-check-flag? current)
              (ResultSelfhostCheckConfig.Err
                (str_cat.str-cat "selfhost-check: unknown flag " current))]
            [has-input
              (ResultSelfhostCheckConfig.Err
                (str_cat.str-cat "selfhost-check: unexpected argument " current))]
            [else
              (selfhost-check-parse-args
                (+ idx 1)
                count
                current
                true
                manifest-path
                has-manifest
                stdlib-roots
                target
                has-target
                cfg-names)])]))))

;; Parse the `check` config from arguments starting at `start`. `count` is
;; `(arg-count)`.
(define (selfhost-check-config-from [start : i64] [count : i64]) : ResultSelfhostCheckConfig
  (selfhost-check-parse-args
    start
    count
    ""
    false
    ""
    false
    (cli_svec.new)
    (target_cfg.compiler-target-cfg-default)
    false
    (cli_svec.new)))

(define (selfhost-check-doctest-report [report : doc_test.DocTestRunReport]) : i64
  (if (doc_test.doc-test-run-report-ok? report)
    0
    (begin
      (io.print-error (doc_test.doc-test-run-report-render report))
      1)))

(define (selfhost-check-print-passed) : i64
  (begin
    (io.print-format "{}" "Type checking passed!\n")
    0))

(define (selfhost-check-file-doctests
  [input-path : String]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : i64
  (selfhost-check-doctest-report
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
  (selfhost-check-doctest-report
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
  (match (compiler_check_core.compiler-check-file-with-roots-and-cfg
    input-path
    stdlib-roots
    (target_cfg.compiler-target-cfgs-with-names target cfg-names))
    [(compiler_check_core.ResultCompilerCheck.Ok _)
      (let
        [inline-test-status : i64
          (test_cli_core.tltest-inline-typecheck-file-with-cfg
            input-path
            stdlib-roots
            (target_cfg.compiler-target-cfgs-with-names target cfg-names)
            "typecheck-prefix-inline-check")]
        (if (= inline-test-status 0)
          (let
            [doctest-status : i64
              (selfhost-check-file-doctests
                input-path
                stdlib-roots
                (target_cfg.compiler-target-cfgs-with-names target cfg-names))]
            (if (= doctest-status 0)
              (selfhost-check-print-passed)
              doctest-status))
          inline-test-status))]
    [(compiler_check_core.ResultCompilerCheck.Err diag)
      (begin
        (selfhost-check-report-diagnostics (__tl-box-place diag))
        1)]))

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
        [name : String manifest.name]
        [entry-path : String
          (selfhost-check-package-entry-path manifest-dir manifest)]
        [emit-entry : bool (selfhost-check-package-kind-entry? manifest.kind)]
        [_reset-file-state : unit
          (compiler_driver_core.compiler-driver-reset-file-state!)]
        (match (compiler_check_core.compiler-check-package-entry-file-with-roots-and-cfg
          entry-path
          stdlib-roots
          manifest-dir
          manifest.deps
          emit-entry
          (target_cfg.compiler-target-cfgs-with-names target cfg-names))
          [(compiler_check_core.ResultCompilerCheckWithPaths.Ok _ paths)
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
                  stdlib-roots
                  manifest-dir
                  name
                  manifest.deps
                  (target_cfg.compiler-target-cfgs-with-names target cfg-names)
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
                inline-test-status))]
          [(compiler_check_core.ResultCompilerCheckWithPaths.Err diag)
            (begin
              (selfhost-check-report-diagnostics (__tl-box-place diag))
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