;; run_cli_core.tl - Selfhost run command logic.
;;
;; Source-file runs build and execute in-process through stdlib fs/process
;; helpers. `--direct` remains accepted as a compatibility no-op.
(import stdlib.io)
(import stdlib.process)
(import stdlib.vector)
(import "host_plan.tl")
(import "build_run_core.tl")
(import "doc_test.tl")
(import "test_cli_core.tl")
(import stdlib.string)
(import stdlib.str_cat)

(defenum RunPlanConfig
  (RunPlanConfig String String String String String String String))

(defenum ResultRunPlanConfig
  (OkRunPlanConfig RunPlanConfig)
  (ErrRunPlanConfig String))

(defenum RunCliConfig
  (RunCliConfig
    String
    CompilerBackendTarget
    CompilerBackendMode
    vector.StringVec
    vector.StringVec
    process.ProcessStringList
    i64
    SourceToolLinkInputs))

(defenum ResultRunCliConfig
  (OkRunCliConfig RunCliConfig)
  (ErrRunCliConfig String))

(define (run-plan-unknown-target [value : String]) : String
  (str_cat.str-cat "run: unknown target " value ""))

(define (run-plan-unknown-mode [value : String]) : String
  (str_cat.str-cat "run: unknown backend mode " value ""))

(define (run-plan-unknown-opt-level [value : String]) : String
  (str_cat.str-cat "run: unknown opt level " value "; expected 0, 1, or 2"))

(define (run-plan-append-stdlib [stdlib-lines : String] [root : String]) : String
  (string.string-append stdlib-lines (host-plan-netline "stdlib-root" root)))

(define (run-plan-append-cfg [cfg-lines : String] [name : String]) : String
  (string.string-append cfg-lines (host-plan-netline "cfg" name)))

(define (run-plan-append-runtime [runtime-lines : String] [value : String]) : String
  (string.string-append runtime-lines (host-plan-netline "runtime-arg" value)))

(define (run-plan-runtime-args
  [idx : i64]
  [count : i64]
  [runtime-lines : String]) : String
  (if (>= idx count)
    runtime-lines
    (run-plan-runtime-args
      (+ idx 1)
      count
      (run-plan-append-runtime runtime-lines (io.arg idx)))))

(define (run-plan-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [target : String]
  [mode : String]
  [opt-level : String]
  [stdlib-lines : String]
  [cfg-lines : String]
  [runtime-lines : String]) : ResultRunPlanConfig
  (if (>= idx count)
    (OkRunPlanConfig
      (RunPlanConfig
        source
        target
        mode
        opt-level
        stdlib-lines
        cfg-lines
        runtime-lines))
    (let
      [current : String (io.arg idx)]
      (cond
        [(string.string-eq current "--")
          (OkRunPlanConfig
            (RunPlanConfig
              source
              target
              mode
              opt-level
              stdlib-lines
              cfg-lines
              (run-plan-runtime-args (+ idx 1) count runtime-lines)))]
        [(string.string-eq current "--target")
          (if (>= (+ idx 1) count)
            (ErrRunPlanConfig "run: --target requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
              (if (host-plan-target-valid? value)
                (run-plan-parse-options
                  (+ idx 2)
                  count
                  source
                  value
                  mode
                  opt-level
                  stdlib-lines
                  cfg-lines
                  runtime-lines)
                (ErrRunPlanConfig (run-plan-unknown-target value)))))]
        [(string.string-eq current "--backend-mode")
          (if (>= (+ idx 1) count)
            (ErrRunPlanConfig "run: --backend-mode requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
              (if (host-plan-backend-mode-valid? value)
                (run-plan-parse-options
                  (+ idx 2)
                  count
                  source
                  target
                  value
                  opt-level
                  stdlib-lines
                  cfg-lines
                  runtime-lines)
                (ErrRunPlanConfig (run-plan-unknown-mode value)))))]
        [(string.string-eq current "--opt-level")
          (if (>= (+ idx 1) count)
            (ErrRunPlanConfig "run: --opt-level requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
              (if (host-plan-opt-level-valid? value)
                (run-plan-parse-options
                  (+ idx 2)
                  count
                  source
                  target
                  mode
                  value
                  stdlib-lines
                  cfg-lines
                  runtime-lines)
                (ErrRunPlanConfig (run-plan-unknown-opt-level value)))))]
        [(string.string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrRunPlanConfig "run: --stdlib-root requires a value")
            (run-plan-parse-options
              (+ idx 2)
              count
              source
              target
              mode
              opt-level
              (run-plan-append-stdlib stdlib-lines (io.arg (+ idx 1)))
              cfg-lines
              runtime-lines))]
        [(string.string-eq current "--cfg")
          (if (>= (+ idx 1) count)
            (ErrRunPlanConfig "run: --cfg requires a value")
            (run-plan-parse-options
              (+ idx 2)
              count
              source
              target
              mode
              opt-level
              stdlib-lines
              (run-plan-append-cfg cfg-lines (io.arg (+ idx 1)))
              runtime-lines))]
        [else
          (OkRunPlanConfig
            (RunPlanConfig
              source
              target
              mode
              opt-level
              stdlib-lines
              cfg-lines
              (run-plan-runtime-args idx count runtime-lines)))]))))

(define (run-plan-config [count : i64]) : ResultRunPlanConfig
  (run-plan-config-from 1 count))

(define (run-plan-config-from [idx : i64] [count : i64]) : ResultRunPlanConfig
  (if (<= count idx)
    (ErrRunPlanConfig "run: expected source path")
    (let
      [source : String (io.arg idx)]
      (if (host-plan-flag? source)
        (ErrRunPlanConfig "run: expected source path before flags")
        (run-plan-parse-options
          (+ idx 1)
          count
          source
          (source-tool-default-target-name)
          "scalar"
          ""
          ""
          ""
          "")))))

(define (run-plan-render [config : RunPlanConfig]) : String
  (match config
    [(RunPlanConfig
        source
        target
        mode
        opt-level
        stdlib-lines
        cfg-lines
        runtime-lines)
      (str_cat.str-cat
        (host-plan-header)
        (host-plan-word-line "action" "run-source")
        (host-plan-netline "source" source)
        (host-plan-word-line "target" target)
        (host-plan-word-line "backend-mode" mode)
        (if (string.string-eq opt-level "")
          ""
          (host-plan-word-line "opt-level" opt-level))
        stdlib-lines
        cfg-lines
        runtime-lines
        "end\n")]))

(define (run-host-plan-main [idx : i64]) : i64
  (match (run-plan-config-from idx (arg-count))
    [(OkRunPlanConfig config)
      (begin
        (io.print-string (run-plan-render config))
        0)]
    [(ErrRunPlanConfig message)
      (begin
        (io.print-error message)
        1)]))

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
  [stdlib-roots : vector.StringVec]
  [cfg-names : vector.StringVec]
  [runtime-args : process.ProcessStringList]
  [opt-level : i64]
  [link-inputs : SourceToolLinkInputs]) : ResultRunCliConfig
  (if (>= idx count)
    (OkRunCliConfig
      (RunCliConfig
        source
        target
        mode
        stdlib-roots
        cfg-names
        runtime-args
        opt-level
        link-inputs))
    (let
      [current : String (io.arg idx)]
      (cond
        [(string.string-eq current "--")
          (OkRunCliConfig
            (RunCliConfig
              source
              target
              mode
              stdlib-roots
              cfg-names
              (source-tool-args-from-argv (+ idx 1) count runtime-args)
              opt-level
              link-inputs))]
        [(string.string-eq current "--target")
          (if (>= (+ idx 1) count)
            (ErrRunCliConfig "run: --target requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
              (match (source-tool-target value)
                [(OkSourceToolTarget parsed-target)
                  (run-cli-parse-options
                    (+ idx 2)
                    count
                    source
                    parsed-target
                    mode
                    stdlib-roots
                    cfg-names
                    runtime-args
                    opt-level
                    link-inputs)]
                [(ErrSourceToolTarget _)
                  (ErrRunCliConfig (run-cli-unknown-target value))])))]
        [(string.string-eq current "--backend-mode")
          (if (>= (+ idx 1) count)
            (ErrRunCliConfig "run: --backend-mode requires a value")
            (let
              [value : String (io.arg (+ idx 1))]
              (match (source-tool-backend-mode "run" value)
                [(OkSourceToolBackendMode parsed-mode)
                  (run-cli-parse-options
                    (+ idx 2)
                    count
                    source
                    target
                    parsed-mode
                    stdlib-roots
                    cfg-names
                    runtime-args
                    opt-level
                    link-inputs)]
                [(ErrSourceToolBackendMode message) (ErrRunCliConfig message)])))]
        [(string.string-eq current "--opt-level")
          (if (>= (+ idx 1) count)
            (ErrRunCliConfig "run: --opt-level requires a value")
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
                  cfg-names
                  runtime-args
                  (string.string->int value)
                  link-inputs)
                (ErrRunCliConfig (run-cli-unknown-opt-level value)))))]
        [(string.string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrRunCliConfig "run: --stdlib-root requires a value")
            (run-cli-parse-options
              (+ idx 2)
              count
              source
              target
              mode
              (vector.string-vec-push stdlib-roots (io.arg (+ idx 1)))
              cfg-names
              runtime-args
              opt-level
              link-inputs))]
        [(string.string-eq current "--cfg")
          (if (>= (+ idx 1) count)
            (ErrRunCliConfig "run: --cfg requires a value")
            (run-cli-parse-options
              (+ idx 2)
              count
              source
              target
              mode
              stdlib-roots
              (vector.string-vec-push cfg-names (io.arg (+ idx 1)))
              runtime-args
              opt-level
              link-inputs))]
        [(string.string-eq current "--link-lib")
          (if (>= (+ idx 1) count)
            (ErrRunCliConfig "run: --link-lib requires a value")
            (run-cli-parse-options
              (+ idx 2)
              count
              source
              target
              mode
              stdlib-roots
              cfg-names
              runtime-args
              opt-level
              (source-tool-link-inputs-add-lib link-inputs (io.arg (+ idx 1)))))]
        [(string.string-eq current "--link-search")
          (if (>= (+ idx 1) count)
            (ErrRunCliConfig "run: --link-search requires a value")
            (run-cli-parse-options
              (+ idx 2)
              count
              source
              target
              mode
              stdlib-roots
              cfg-names
              runtime-args
              opt-level
              (source-tool-link-inputs-add-search-dir
                link-inputs
                (io.arg (+ idx 1)))))]
        [(string.string-eq current "--link-arg")
          (if (>= (+ idx 1) count)
            (ErrRunCliConfig "run: --link-arg requires a value")
            (run-cli-parse-options
              (+ idx 2)
              count
              source
              target
              mode
              stdlib-roots
              cfg-names
              runtime-args
              opt-level
              (source-tool-link-inputs-add-raw-arg
                link-inputs
                (io.arg (+ idx 1)))))]
        [else
          (OkRunCliConfig
            (RunCliConfig
              source
              target
              mode
              stdlib-roots
              cfg-names
              (source-tool-args-from-argv idx count runtime-args)
              opt-level
              link-inputs))]))))

(define (run-cli-config [count : i64]) : ResultRunCliConfig
  (run-cli-config-from 1 count))

(define (run-cli-config-from [idx : i64] [count : i64]) : ResultRunCliConfig
  (if (<= count idx)
    (ErrRunCliConfig "run: expected source path")
    (let
      [source : String (io.arg idx)]
      (if (source-tool-flag? source)
        (ErrRunCliConfig "run: expected source path before flags")
        (run-cli-parse-options
          (+ idx 1)
          count
          source
          (source-tool-default-target)
          (BackendModeScalar)
          (vector.string-vec-new)
          (vector.string-vec-new)
          (process.process-args-empty)
          (compiler-optimize-default-level)
          (source-tool-link-inputs-empty))))))

(define (run-cli-typecheck-doctests
  [source : String]
  [stdlib-roots : vector.StringVec]) : i64
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
  [stdlib-roots : vector.StringVec]
  [cfg-names : vector.StringVec]
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
              (source-tool-cfg-names-to-env cfg-names))
            "typecheck-prefix-inline-run")]
        (if (= inline-test-status 0)
          (begin
            (compiler-driver-reset-file-state!)
            (source-tool-run-source
              source
              target
              stdlib-roots
              cfg-names
              runtime-args
              opt-level
              mode
              link-inputs))
          inline-test-status))
      doctest-status)))

(define (run-cli-main) : i64
  (match (run-cli-config (arg-count))
    [(OkRunCliConfig config)
      (match config
        [(RunCliConfig
            source
            target
            mode
            stdlib-roots
            cfg-names
            runtime-args
            opt-level
            link-inputs)
          (run-cli-run-source-with-doctests
            source
            target
            stdlib-roots
            cfg-names
            runtime-args
            opt-level
            mode
            link-inputs)])]
    [(ErrRunCliConfig message)
      (begin
        (io.print-error message)
        1)]))

(define (run-direct-from [idx : i64] [count : i64]) : i64
  (match (run-cli-config-from idx count)
    [(OkRunCliConfig config)
      (match config
        [(RunCliConfig
            source
            target
            mode
            stdlib-roots
            cfg-names
            runtime-args
            opt-level
            link-inputs)
          (run-cli-run-source-with-doctests
            source
            target
            stdlib-roots
            cfg-names
            runtime-args
            opt-level
            mode
            link-inputs)])]
    [(ErrRunCliConfig message)
      (begin
        (io.print-error message)
        1)]))

;; Run the `run` command over arguments starting at `start` (the index of the
;; first argument after any subcommand name). The bare form builds and executes
;; in-process.
(define (run-run-from [start : i64] [count : i64]) : i64
  (if (and (> count start) (string.string-eq (io.arg start) "--direct"))
    (run-direct-from (+ start 1) count)
    (run-direct-from start count)))