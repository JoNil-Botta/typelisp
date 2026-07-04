;; run_cli_core.tl - Selfhost run command logic.
;;
;; Source-file runs build and execute in-process through stdlib fs/process
;; helpers. `--direct` remains accepted as a compatibility no-op.
(import stdlib.io)
(import stdlib.process)
(import stdlib.vector as svec)
(import "build_run_core.tl")
(import "doc_test.tl")
(import "test_cli_core.tl")
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)

(defenum RunCliConfig
  (Config
    String
    CompilerBackendTarget
    CompilerBackendMode
    svec.StringVec
    SourceToolCfgNames
    process.ProcessStringList
    i64
    SourceToolLinkInputs))

(defenum ResultRunCliConfig
  (Ok RunCliConfig)
  (Err String))

(define (run-cli-unknown-target [value : String]) : String
  (str_cat.str-cat "run: unknown target " value ""))

(define (run-cli-unknown-opt-level [value : String]) : String
  (str_cat.str-cat "run: unknown opt level " value "; expected 0, 1, or 2"))

(define (run-cli-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [target : CompilerBackendTarget]
  [mode : CompilerBackendMode]
  [stdlib-roots : svec.StringVec]
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
      (cond
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
        [(string.eq current "--target")
          (if (>= (+ idx 1) count)
            (ResultRunCliConfig.Err "run: --target requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
              (match (source-tool-target value)
                [(ResultSourceToolTarget.Ok parsed-target)
                  (run-cli-parse-options
                    (+ idx 2)
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
                  (ResultRunCliConfig.Err (run-cli-unknown-target value))])))]
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
        [(string.eq current "--opt-level")
          (if (>= (+ idx 1) count)
            (ResultRunCliConfig.Err "run: --opt-level requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
              (if (source-tool-opt-level-valid? value)
                (run-cli-parse-options
                  (+ idx 2)
                  count
                  source
                  target
                  mode
                  stdlib-roots
                  cfgs
                  runtime-args
                  (string.>int value)
                  link-inputs)
                (ResultRunCliConfig.Err (run-cli-unknown-opt-level value)))))]
        [(string.eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ResultRunCliConfig.Err "run: --stdlib-root requires a value")
            (run-cli-parse-options
              (+ idx 2)
              count
              source
              target
              mode
              (let
                [next-roots : svec.StringVec stdlib-roots]
                (begin
                  (set!
                    next-roots
                    (svec.string-vec-push next-roots (io.arg (+ idx 1))))
                  next-roots))
              cfgs
              runtime-args
              opt-level
              link-inputs))]
        [(string.eq current "--cfg")
          (if (>= (+ idx 1) count)
            (ResultRunCliConfig.Err "run: --cfg requires a value")
            (run-cli-parse-options
              (+ idx 2)
              count
              source
              target
              mode
              stdlib-roots
              (source-tool-cfg-names-add cfgs (io.arg (+ idx 1)))
              runtime-args
              opt-level
              link-inputs))]
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
              (source-tool-link-inputs-add-lib link-inputs (io.arg (+ idx 1)))))]
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
              link-inputs))]))))

(define (run-cli-config-from [idx : i64] [count : i64]) : ResultRunCliConfig
  (if (<= count idx)
    (ResultRunCliConfig.Err "run: expected source path")
    (let
      [source : String (io.arg idx)]
      (if (source-tool-flag? source)
        (ResultRunCliConfig.Err "run: expected source path before flags")
        (run-cli-parse-options
          (+ idx 1)
          count
          source
          (source-tool-default-target)
          (CompilerBackendMode.Scalar)
          (svec.string-vec-new)
          (source-tool-cfg-names-empty)
          (process.args-empty)
          (compiler-optimize-default-level)
          (source-tool-link-inputs-empty))))))

(define (run-cli-typecheck-doctests
  [source : String]
  [stdlib-roots : svec.StringVec]) : i64
  (match (io.try-read-file (& source))
    [(io.ErrIoString _) 0]
    [(io.OkIoString text)
      (let
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
  [stdlib-roots : svec.StringVec]
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
              link-inputs))
          inline-test-status))
      doctest-status)))

(define (run-direct-from [idx : i64] [count : i64]) : i64
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
            link-inputs)])]
    [(ResultRunCliConfig.Err message)
      (begin
        (io.print-error message)
        1)]))

;; Run the `run` command over arguments starting at `start` (the index of the
;; first argument after any subcommand name). The bare form builds and executes
;; in-process.
(define (run-run-from [start : i64] [count : i64]) : i64
  (if (and (> count start) (string.eq (io.arg start) "--direct"))
    (run-direct-from (+ start 1) count)
    (run-direct-from start count)))