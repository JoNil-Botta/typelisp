;; run.tl - Selfhost source-file run tool (#1018).
;;
;; `--direct` runs source files with stdlib fs/process helpers. The default
;; host-plan mode preserves the private Rust/stage0 compatibility bridge.
(import "host_plan.tl")

(import "build_run_core.tl")

(defenum RunPlanConfig
  (RunPlanConfig String String String String String String))

(defenum ResultRunPlanConfig
  (OkRunPlanConfig RunPlanConfig)
  (ErrRunPlanConfig String))

(defenum RunCliConfig
  (RunCliConfig
    String
    CompilerBackendTarget
    CompilerLoadRootList
    ProcessStringList
    i64))

(defenum ResultRunCliConfig
  (OkRunCliConfig RunCliConfig)
  (ErrRunCliConfig String))

(define (run-plan-unknown-target [value : String]) : String
  (host-plan-cat3 "run: unknown target " value ""))

(define (run-plan-unknown-mode [value : String]) : String
  (host-plan-cat3 "run: unknown backend mode " value ""))

(define (run-plan-unknown-opt-level [value : String]) : String
  (host-plan-cat3 "run: unknown opt level " value ""))

(define (run-plan-append-stdlib [stdlib-lines : String] [root : String]) : String
  (string-append stdlib-lines (host-plan-netline "stdlib-root" root)))

(define (run-plan-append-runtime [runtime-lines : String] [value : String]) : String
  (string-append runtime-lines (host-plan-netline "runtime-arg" value)))

(define (run-plan-runtime-args
  [idx : i64]
  [count : i64]
  [runtime-lines : String]) : String
  (if (>= idx count)
    runtime-lines
    (run-plan-runtime-args
      (+ idx 1)
      count
      (run-plan-append-runtime runtime-lines (arg idx)))))

(define (run-plan-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [target : String]
  [mode : String]
  [opt-level : String]
  [stdlib-lines : String]
  [runtime-lines : String]) : ResultRunPlanConfig
  (if (>= idx count)
    (OkRunPlanConfig
      (RunPlanConfig source target mode opt-level stdlib-lines runtime-lines))
    (let
      [current : String (arg idx)]
      (if (string-eq current "--")
        (OkRunPlanConfig
          (RunPlanConfig
            source
            target
            mode
            opt-level
            stdlib-lines
            (run-plan-runtime-args (+ idx 1) count runtime-lines)))
        (if (string-eq current "--target")
          (if (>= (+ idx 1) count)
            (ErrRunPlanConfig "run: --target requires a value")
            (let
              [value : String (arg (+ idx 1))]
              (if (host-plan-target-valid? value)
                (run-plan-parse-options
                  (+ idx 2)
                  count
                  source
                  value
                  mode
                  opt-level
                  stdlib-lines
                  runtime-lines)
                (ErrRunPlanConfig (run-plan-unknown-target value)))))
          (if (string-eq current "--backend-mode")
            (if (>= (+ idx 1) count)
              (ErrRunPlanConfig "run: --backend-mode requires a value")
              (let
                [value : String (arg (+ idx 1))]
                (if (host-plan-backend-mode-valid? value)
                  (run-plan-parse-options
                    (+ idx 2)
                    count
                    source
                    target
                    value
                    opt-level
                    stdlib-lines
                    runtime-lines)
                  (ErrRunPlanConfig (run-plan-unknown-mode value)))))
            (if (string-eq current "--opt-level")
              (if (>= (+ idx 1) count)
                (ErrRunPlanConfig "run: --opt-level requires a value")
                (let
                  [value : String (arg (+ idx 1))]
                  (if (host-plan-opt-level-valid? value)
                    (run-plan-parse-options
                      (+ idx 2)
                      count
                      source
                      target
                      mode
                      value
                      stdlib-lines
                      runtime-lines)
                    (ErrRunPlanConfig (run-plan-unknown-opt-level value)))))
              (if (string-eq current "--stdlib-root")
                (if (>= (+ idx 1) count)
                  (ErrRunPlanConfig "run: --stdlib-root requires a value")
                  (run-plan-parse-options
                    (+ idx 2)
                    count
                    source
                    target
                    mode
                    opt-level
                    (run-plan-append-stdlib stdlib-lines (arg (+ idx 1)))
                    runtime-lines))
                (OkRunPlanConfig
                  (RunPlanConfig
                    source
                    target
                    mode
                    opt-level
                    stdlib-lines
                    (run-plan-runtime-args idx count runtime-lines)))))))))))

(define (run-plan-config [count : i64]) : ResultRunPlanConfig
  (run-plan-config-from 1 count))

(define (run-plan-config-from [idx : i64] [count : i64]) : ResultRunPlanConfig
  (if (<= count idx)
    (ErrRunPlanConfig "run: expected source path")
    (let
      [source : String (arg idx)]
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
          "")))))

(define (run-plan-render [config : RunPlanConfig]) : String
  (match config
    [(RunPlanConfig source target mode opt-level stdlib-lines runtime-lines)
      (string-append
        (host-plan-header)
        (string-append
          (host-plan-word-line "action" "run-source")
          (string-append
            (host-plan-netline "source" source)
            (string-append
              (host-plan-word-line "target" target)
              (string-append
                (host-plan-word-line "backend-mode" mode)
                (string-append
                  (if (string-eq opt-level "")
                    ""
                    (host-plan-word-line "opt-level" opt-level))
                  (string-append
                    stdlib-lines
                    (string-append runtime-lines "end\n"))))))))]))

(define (run-host-plan-main [idx : i64]) : i64
  (match (run-plan-config-from idx (arg-count))
    [(OkRunPlanConfig config)
      (begin
        (print-string (run-plan-render config))
        0)]
    [(ErrRunPlanConfig message)
      (begin
        (print-error message)
        1)]))

(define (run-cli-unknown-target [value : String]) : String
  (source-tool-cat3 "run: unknown target " value ""))

(define (run-cli-unknown-mode [value : String]) : String
  (source-tool-cat3 "run: unknown backend mode " value ""))

(define (run-cli-unknown-opt-level [value : String]) : String
  (source-tool-cat3 "run: unknown opt level " value ""))

(define (run-cli-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [runtime-args : ProcessStringList]
  [opt-level : i64]) : ResultRunCliConfig
  (if (>= idx count)
    (OkRunCliConfig
      (RunCliConfig source target stdlib-roots runtime-args opt-level))
    (let
      [current : String (arg idx)]
      (if (string-eq current "--")
        (OkRunCliConfig
          (RunCliConfig
            source
            target
            stdlib-roots
            (source-tool-args-from-argv (+ idx 1) count runtime-args)
            opt-level))
        (if (string-eq current "--target")
          (if (>= (+ idx 1) count)
            (ErrRunCliConfig "run: --target requires a value")
            (let
              [value : String (arg (+ idx 1))]
              (match (source-tool-target value)
                [(OkSourceToolTarget parsed-target)
                  (run-cli-parse-options
                    (+ idx 2)
                    count
                    source
                    parsed-target
                    stdlib-roots
                    runtime-args
                    opt-level)]
                [(ErrSourceToolTarget _)
                  (ErrRunCliConfig (run-cli-unknown-target value))])))
          (if (string-eq current "--backend-mode")
            (if (>= (+ idx 1) count)
              (ErrRunCliConfig "run: --backend-mode requires a value")
              (let
                [value : String (arg (+ idx 1))]
                (if (source-tool-backend-mode-valid? value)
                  (run-cli-parse-options
                    (+ idx 2)
                    count
                    source
                    target
                    stdlib-roots
                    runtime-args
                    opt-level)
                  (ErrRunCliConfig (run-cli-unknown-mode value)))))
            (if (string-eq current "--opt-level")
              (if (>= (+ idx 1) count)
                (ErrRunCliConfig "run: --opt-level requires a value")
                (let
                  [value : String (arg (+ idx 1))]
                  (if (source-tool-opt-level-valid? value)
                    (run-cli-parse-options
                      (+ idx 2)
                      count
                      source
                      target
                      stdlib-roots
                      runtime-args
                      (string->int value))
                    (ErrRunCliConfig (run-cli-unknown-opt-level value)))))
              (if (string-eq current "--stdlib-root")
                (if (>= (+ idx 1) count)
                  (ErrRunCliConfig "run: --stdlib-root requires a value")
                  (run-cli-parse-options
                    (+ idx 2)
                    count
                    source
                    target
                    (source-tool-root-list-append stdlib-roots (arg (+ idx 1)))
                    runtime-args
                    opt-level))
                (OkRunCliConfig
                  (RunCliConfig
                    source
                    target
                    stdlib-roots
                    (source-tool-args-from-argv idx count runtime-args)
                    opt-level))))))))))

(define (run-cli-config [count : i64]) : ResultRunCliConfig
  (run-cli-config-from 1 count))

(define (run-cli-config-from [idx : i64] [count : i64]) : ResultRunCliConfig
  (if (<= count idx)
    (ErrRunCliConfig "run: expected source path")
    (let
      [source : String (arg idx)]
      (if (source-tool-flag? source)
        (ErrRunCliConfig "run: expected source path before flags")
        (run-cli-parse-options
          (+ idx 1)
          count
          source
          (source-tool-default-target)
          CompilerLoadRootNil
          (process-args-empty)
          (compiler-optimize-default-level))))))

(define (run-cli-main) : i64
  (match (run-cli-config (arg-count))
    [(OkRunCliConfig config)
      (match config
        [(RunCliConfig source target stdlib-roots runtime-args opt-level)
          (source-tool-run-source
            source
            target
            stdlib-roots
            runtime-args
            opt-level)])]
    [(ErrRunCliConfig message)
      (begin
        (print-error message)
        1)]))

(define (main) : i64
  (if (and (> (arg-count) 1) (string-eq (arg 1) "--direct"))
    (match (run-cli-config-from 2 (arg-count))
      [(OkRunCliConfig config)
        (match config
          [(RunCliConfig source target stdlib-roots runtime-args opt-level)
            (source-tool-run-source
              source
              target
              stdlib-roots
              runtime-args
              opt-level)])]
      [(ErrRunCliConfig message)
        (begin
          (print-error message)
          1)])
    (if (and (> (arg-count) 1) (string-eq (arg 1) "--host-plan"))
      (run-host-plan-main 2)
      (run-host-plan-main 1))))