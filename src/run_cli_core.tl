;; run_cli_core.tl - Selfhost run command logic.
;;
;; Source-file runs build and execute in-process through stdlib fs/process
;; helpers. Package runs reuse the package build path, then execute the emitted
;; binary artifact. `--direct` remains accepted as a compatibility no-op.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.process)
(import stdlib.vector)
(import (vector.vector String) as cli_svec)
(import cli_option_core as cli_option)
(import "build_run_core.tl")
(import "build_cli_core.tl")
(import "doc_test.tl")
(import "test_cli_core.tl")
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)

(defenum RunCliConfig
  (Config
    String
    CompilerBackendTarget
    CompilerBackendMode
    cli_svec.Vec
    SourceToolCfgNames
    process.ProcessStringList
    i64
    SourceToolLinkInputs)
  (Package BuildConfig process.ProcessStringList))

(defenum ResultRunCliConfig
  (Ok RunCliConfig)
  (Err String))

(define (run-cli-unknown-target [value : String]) : String
  (str_cat.str-cat "run: unknown target " value ""))

(define (run-cli-unknown-opt-level [value : String]) : String
  (str_cat.str-cat "run: unknown opt level " value "; expected 0, 1, or 2"))

(define (run-cli-string-prefix? [text : String] [prefix : String]) : bool
  (let
    [prefix-len : i64 (string.string-length prefix)]
    (and
      (>= (string.string-length text) prefix-len)
      (string.eq (string.substring text 0 prefix-len) prefix))))

(define (run-cli-rewrite-build-error [message : String]) : String
  (let
    [prefix : String "build: "]
    [prefix-len : i64 (string.string-length prefix)]
    (if (run-cli-string-prefix? message prefix)
      (str_cat.str-cat
        "run: "
        (string.substring
          message
          prefix-len
          (- (string.string-length message) prefix-len)))
      message)))

(define (run-cli-runtime-separator-index [idx : i64] [count : i64]) : i64
  (if (>= idx count)
    count
    (if (string.eq (io.arg idx) "--")
      idx
      (run-cli-runtime-separator-index (+ idx 1) count))))

(define (run-cli-package-config-from [idx : i64] [count : i64]) : ResultRunCliConfig
  (let
    [separator : i64 (run-cli-runtime-separator-index idx count)]
    [runtime-args : process.ProcessStringList
      (if (< separator count)
        (source-tool-args-from-argv (+ separator 1) count (process.args-empty))
        (process.args-empty))]
    (match (build-config-from idx separator)
      [(ResultBuildConfig.Err message)
        (ResultRunCliConfig.Err (run-cli-rewrite-build-error message))]
      [(ResultBuildConfig.Ok config)
        (match config
          [(BuildConfig.Package _ _ _ _ _ _ _ _ _ _)
            (ResultRunCliConfig.Ok (RunCliConfig.Package config runtime-args))]
          [(BuildConfig.Source _ _ _ _ _ _ _ _)
            (ResultRunCliConfig.Err
              "run: source file arguments must appear before run options; use -- before package runtime args")])])))

(define (run-cli-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : SourceToolCfgNames]
  [runtime-args : process.ProcessStringList]
  [opt-level : i64]
  [link-inputs : SourceToolLinkInputs]) : ResultRunCliConfig
  (if (>= idx count)
    (ResultRunCliConfig.Ok
      (RunCliConfig.Config
        source
        target
        mode
        stdlib-roots
        cfgs
        runtime-args
        opt-level
        link-inputs))
    (let
      [current : String (io.arg idx)]
      (match (cli_option.cli-common-option-parse
        current
        idx
        count
        cli_option.cli-common-option-all)
        [(cli_option.CliCommonOption.Missing kind)
          (ResultRunCliConfig.Err
            (cli_option.cli-common-option-missing-message "run" kind))]
        [(cli_option.CliCommonOption.Value kind value next-idx)
          (match kind
            [(cli_option.CliCommonOptionKind.StdlibRoot)
              (run-cli-parse-options
                next-idx
                count
                source
                target
                mode
                (let
                  [next-roots : cli_svec.Vec stdlib-roots]
                  (begin
                    (cli_svec.push (&mut next-roots) value)
                    next-roots))
                cfgs
                runtime-args
                opt-level
                link-inputs)]
            [(cli_option.CliCommonOptionKind.Cfg)
              (run-cli-parse-options
                next-idx
                count
                source
                target
                mode
                stdlib-roots
                (source-tool-cfg-names-add cfgs value)
                runtime-args
                opt-level
                link-inputs)]
            [(cli_option.CliCommonOptionKind.Target)
              (match (source-tool-target value)
                [(ResultSourceToolTarget.Ok parsed-target)
                  (run-cli-parse-options
                    next-idx
                    count
                    source
                    parsed-target
                    mode
                    stdlib-roots
                    cfgs
                    runtime-args
                    opt-level
                    link-inputs)]
                [(ResultSourceToolTarget.Err _)
                  (ResultRunCliConfig.Err (run-cli-unknown-target value))])]
            [(cli_option.CliCommonOptionKind.OptLevel)
              (if (source-tool-opt-level-valid? value)
                (run-cli-parse-options
                  next-idx
                  count
                  source
                  target
                  mode
                  stdlib-roots
                  cfgs
                  runtime-args
                  (string.>int value)
                  link-inputs)
                (ResultRunCliConfig.Err (run-cli-unknown-opt-level value)))])]
        [(cli_option.CliCommonOption.NotCommon)
          (cond
            [(or (string.eq current "--debug") (string.eq current "-g"))
              (begin
                (compiler-debug-info-set-enabled! true)
                (run-cli-parse-options
                  (+ idx 1)
                  count
                  source
                  target
                  mode
                  stdlib-roots
                  cfgs
                  runtime-args
                  opt-level
                  link-inputs))]
            [(string.eq current "--")
              (ResultRunCliConfig.Ok
                (RunCliConfig.Config
                  source
                  target
                  mode
                  stdlib-roots
                  cfgs
                  (source-tool-args-from-argv (+ idx 1) count runtime-args)
                  opt-level
                  link-inputs))]
            [(string.eq current "--backend-mode")
              (if (>= (+ idx 1) count)
                (ResultRunCliConfig.Err "run: --backend-mode requires a value")
                (let
                  [value : String (io.arg (+ idx 1))]
                  (match (source-tool-backend-mode "run" value)
                    [(ResultSourceToolBackendMode.Ok parsed-mode)
                      (run-cli-parse-options
                        (+ idx 2)
                        count
                        source
                        target
                        parsed-mode
                        stdlib-roots
                        cfgs
                        runtime-args
                        opt-level
                        link-inputs)]
                    [(ResultSourceToolBackendMode.Err message)
                      (ResultRunCliConfig.Err message)])))]
            [(string.eq current "--link-lib")
              (if (>= (+ idx 1) count)
                (ResultRunCliConfig.Err "run: --link-lib requires a value")
                (run-cli-parse-options
                  (+ idx 2)
                  count
                  source
                  target
                  mode
                  stdlib-roots
                  cfgs
                  runtime-args
                  opt-level
                  (source-tool-link-inputs-add-lib
                    link-inputs
                    (io.arg (+ idx 1)))))]
            [(string.eq current "--link-search")
              (if (>= (+ idx 1) count)
                (ResultRunCliConfig.Err "run: --link-search requires a value")
                (run-cli-parse-options
                  (+ idx 2)
                  count
                  source
                  target
                  mode
                  stdlib-roots
                  cfgs
                  runtime-args
                  opt-level
                  (source-tool-link-inputs-add-search-dir
                    link-inputs
                    (io.arg (+ idx 1)))))]
            [(string.eq current "--link-arg")
              (if (>= (+ idx 1) count)
                (ResultRunCliConfig.Err "run: --link-arg requires a value")
                (run-cli-parse-options
                  (+ idx 2)
                  count
                  source
                  target
                  mode
                  stdlib-roots
                  cfgs
                  runtime-args
                  opt-level
                  (source-tool-link-inputs-add-raw-arg
                    link-inputs
                    (io.arg (+ idx 1)))))]
            [else
              (ResultRunCliConfig.Ok
                (RunCliConfig.Config
                  source
                  target
                  mode
                  stdlib-roots
                  cfgs
                  (source-tool-args-from-argv idx count runtime-args)
                  opt-level
                  link-inputs))])]))))

(define (run-cli-config-from [idx : i64] [count : i64]) : ResultRunCliConfig
  (if (or (<= count idx) (source-tool-flag? (io.arg idx)))
    (run-cli-package-config-from idx count)
    (let
      [source : String (io.arg idx)]
      (run-cli-parse-options
        (+ idx 1)
        count
        source
        (source-tool-default-target)
        (CompilerBackendMode.Scalar)
        (cli_svec.new)
        (source-tool-cfg-names-empty)
        (process.args-empty)
        (compiler-optimize-default-level)
        (source-tool-link-inputs-empty)))))

(define (run-cli-typecheck-doctests
  [source : String]
  [stdlib-roots : cli_svec.Vec]) : i64
  (match (io.try-read-file (& source))
    [(io.ErrIoBytes _) 0]
    [(io.OkIoBytes contents)
      (let
        [text : String (byte_buf.to-string contents)]
        [report : DocTestRunReport
          (doc-test-typecheck-source-with-roots source text stdlib-roots)]
        (if (doc-test-run-report-ok? report)
          0
          (begin
            (io.print-error (doc-test-run-report-render report))
            1)))]))

(define (run-cli-run-source-with-doctests
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : cli_svec.Vec]
  [cfgs : SourceToolCfgNames]
  [runtime-args : process.ProcessStringList]
  [opt-level : i64]
  [mode : CompilerBackendMode]
  [link-inputs : SourceToolLinkInputs]) : i64
  (let
    [doctest-status : i64 (run-cli-typecheck-doctests source stdlib-roots)]
    (if (= doctest-status 0)
      (let
        [inline-test-status : i64
          (tltest-inline-typecheck-file-with-cfg
            source
            stdlib-roots
            (compiler-driver-target-cfgs
              target
              (source-tool-cfg-names-to-env cfgs))
            "typecheck-prefix-inline-run")]
        (if (= inline-test-status 0)
          (begin
            (compiler-driver-reset-file-state!)
            (source-tool-run-source
              source
              target
              stdlib-roots
              cfgs
              runtime-args
              opt-level
              mode
              link-inputs
              true))
          inline-test-status))
      doctest-status)))

(define (run-cli-run-package-artifact
  [bin-path : String]
  [target : CompilerBackendTarget]
  [runtime-args : process.ProcessStringList]) : i64
  (match (source-tool-run-executable-inherit bin-path target runtime-args)
    [(process.OkProcessOutput output)
      (let
        [status : i64 (process.output-status output)]
        status)]
    [(process.ErrProcessOutput error)
      (begin
        (io.print-error
          (str_cat.str-cat
            "Error: failed to run executable '"
            bin-path
            "' for target "
            (source-tool-target-name target)
            ": "
            (process.error-message error)))
        1)]))

(define (run-cli-package-artifact-path
  [manifest-path : String]
  [manifest : CompilerPkgManifest]
  [profile : BuildProfile]
  [target : CompilerBackendTarget]) : String
  (let
    [normalized-path : String
      (build-package-normalize-manifest-path manifest-path)]
    [manifest-dir : String (compiler-load-dirname normalized-path)]
    [artifacts : BuildPackageArtifactPaths
      (build-package-artifact-paths
        manifest-dir
        (struct-get manifest name)
        (struct-get manifest kind)
        profile
        target)]
    (build-package-runtime-artifact-path artifacts)))

(define (run-cli-run-package-from-path
  [manifest-path : String]
  [target-text : String]
  [has-target : bool]
  [mode : String]
  [profile : BuildProfile]
  [opt-level : i64]
  [lock-policy : BuildPackageLockPolicy]
  [stdlib-roots : cli_svec.Vec]
  [producer-identity : String]
  [runtime-args : process.ProcessStringList]) : i64
  (match (build-parse-target target-text)
    [(ResultBuildTarget.Err message)
      (begin
        (io.print-error (run-cli-rewrite-build-error message))
        1)]
    [(ResultBuildTarget.Ok target)
      (match (build-load-manifest manifest-path)
        [(ResultBuildManifest.Err message)
          (begin
            (io.print-error (str_cat.str-cat "Error: " message))
            1)]
        [(ResultBuildManifest.Ok manifest)
          (if (not (build-package-kind-entry? (struct-get manifest kind)))
            (begin
              (io.print-error
                "run: package manifest kind must be bin to execute")
              1)
            (let
              [build-status : i64
                (build-package-from-path-announce
                  manifest-path
                  target-text
                  has-target
                  mode
                  opt-level
                  profile
                  lock-policy
                  stdlib-roots
                  producer-identity
                  false)]
              (if (= build-status 0)
                (run-cli-run-package-artifact
                  (run-cli-package-artifact-path
                    manifest-path
                    manifest
                    profile
                    target)
                  target
                  runtime-args)
                build-status)))])]))

(define (run-cli-run-package
  [config : BuildConfig]
  [producer-identity : String]
  [runtime-args : process.ProcessStringList]) : i64
  (match config
    [(BuildConfig.Package
        manifest-path
        has-manifest
        target-text
        has-target
        mode
        profile
        _
        opt-level
        lock-policy
        stdlib-roots)
      (let
        [resolved-manifest : CompilerLoadMaybePath
          (if has-manifest
            (CompilerLoadSomePath manifest-path)
            (build-discover-manifest-up "" 256))]
        (match resolved-manifest
          [(CompilerLoadNoPath)
            (begin
              (io.print-error
                "could not find typelisp.pkg from '.' or any parent directory")
              1)]
          [(CompilerLoadSomePath path)
            (run-cli-run-package-from-path
              path
              target-text
              has-target
              mode
              profile
              opt-level
              lock-policy
              stdlib-roots
              producer-identity
              runtime-args)]))]
    [_ 1]))

(define (run-direct-from [idx : i64] [count : i64] [producer-identity : String]) : i64
  (match (run-cli-config-from idx count)
    [(ResultRunCliConfig.Ok config)
      (match config
        [(RunCliConfig.Config
            source
            target
            mode
            stdlib-roots
            cfgs
            runtime-args
            opt-level
            link-inputs)
          (run-cli-run-source-with-doctests
            source
            target
            stdlib-roots
            cfgs
            runtime-args
            opt-level
            mode
            link-inputs)]
        [(RunCliConfig.Package package-config runtime-args)
          (run-cli-run-package package-config producer-identity runtime-args)])]
    [(ResultRunCliConfig.Err message)
      (begin
        (io.print-error message)
        1)]))

;; Run the `run` command over arguments starting at `start` (the index of the
;; first argument after any subcommand name). The bare form builds and executes
;; in-process.
(define (run-run-from [start : i64] [count : i64] [producer-identity : String]) : i64
  (begin
    (compiler-debug-info-set-enabled! false)
    (if (and (> count start) (string.eq (io.arg start) "--direct"))
      (run-direct-from (+ start 1) count producer-identity)
      (run-direct-from start count producer-identity))))