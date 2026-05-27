;; run.tl - Selfhost source-file run driver (#622, #1338).
;;
;; Linux/scalar source-file runs execute directly through stdlib process/fs. A
;; hidden `--emit-host-plan` mode preserves the private Rust host-action bridge
;; for staged fallback paths.
(import "host_plan.tl")

(import "native_source.tl")

(defenum RunPlanConfig
  (RunPlanConfig
    String
    String
    String
    String
    String
    String
    CompilerLoadRootList
    ProcessStringList
    i64
    bool))

(defenum ResultRunPlanConfig
  (OkRunPlanConfig RunPlanConfig)
  (ErrRunPlanConfig String))

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

(define (run-plan-root-list-append
  [roots : CompilerLoadRootList]
  [root : String]) : CompilerLoadRootList
  (native-source-root-list-append roots root))

(define (run-plan-runtime-lines
  [idx : i64]
  [count : i64]
  [runtime-lines : String]) : String
  (if (>= idx count)
    runtime-lines
    (run-plan-runtime-lines
      (+ idx 1)
      count
      (run-plan-append-runtime runtime-lines (arg idx)))))

(define (run-plan-runtime-arg-list
  [idx : i64]
  [count : i64]
  [runtime-args : ProcessStringList]) : ProcessStringList
  (if (>= idx count)
    runtime-args
    (run-plan-runtime-arg-list
      (+ idx 1)
      count
      (native-source-process-args-append runtime-args (arg idx)))))

(define (run-plan-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [target : String]
  [mode : String]
  [opt-level : String]
  [stdlib-lines : String]
  [runtime-lines : String]
  [stdlib-roots : CompilerLoadRootList]
  [runtime-args : ProcessStringList]
  [opt-level-value : i64]
  [emit-host-plan : bool]) : ResultRunPlanConfig
  (if (>= idx count)
    (OkRunPlanConfig
      (RunPlanConfig
        source
        target
        mode
        opt-level
        stdlib-lines
        runtime-lines
        stdlib-roots
        runtime-args
        opt-level-value
        emit-host-plan))
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
            (run-plan-runtime-lines (+ idx 1) count runtime-lines)
            stdlib-roots
            (run-plan-runtime-arg-list (+ idx 1) count runtime-args)
            opt-level-value
            emit-host-plan))
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
                  runtime-lines
                  stdlib-roots
                  runtime-args
                  opt-level-value
                  emit-host-plan)
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
                    runtime-lines
                    stdlib-roots
                    runtime-args
                    opt-level-value
                    emit-host-plan)
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
                      runtime-lines
                      stdlib-roots
                      runtime-args
                      (match (compiler-optimize-parse-level value)
                        [(OkCompilerOptimizeLevel parsed) parsed]
                        [(ErrCompilerOptimizeLevel) opt-level-value])
                      emit-host-plan)
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
                    runtime-lines
                    (run-plan-root-list-append stdlib-roots (arg (+ idx 1)))
                    runtime-args
                    opt-level-value
                    emit-host-plan))
                (if (string-eq current "--emit-host-plan")
                  (run-plan-parse-options
                    (+ idx 1)
                    count
                    source
                    target
                    mode
                    opt-level
                    stdlib-lines
                    runtime-lines
                    stdlib-roots
                    runtime-args
                    opt-level-value
                    true)
                  (OkRunPlanConfig
                    (RunPlanConfig
                      source
                      target
                      mode
                      opt-level
                      stdlib-lines
                      (run-plan-runtime-lines idx count runtime-lines)
                      stdlib-roots
                      (run-plan-runtime-arg-list idx count runtime-args)
                      opt-level-value
                      emit-host-plan)))))))))))

(define (run-plan-config [count : i64]) : ResultRunPlanConfig
  (if (< count 2)
    (ErrRunPlanConfig "run: expected source path")
    (let
      [source : String (arg 1)]
      (if (host-plan-flag? source)
        (ErrRunPlanConfig "run: expected source path before flags")
        (run-plan-parse-options
          2
          count
          source
          (host-plan-default-target)
          "scalar"
          ""
          ""
          ""
          CompilerLoadRootNil
          (ProcessStringNil)
          (compiler-optimize-default-level)
          false)))))

(define (run-plan-render [config : RunPlanConfig]) : String
  (match config
    [(RunPlanConfig
        source
        target
        mode
        opt-level
        stdlib-lines
        runtime-lines
        _
        _
        _
        _)
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

(define (main) : i64
  (match (run-plan-config (arg-count))
    [(OkRunPlanConfig config)
      (match config
        [(RunPlanConfig
            source
            target
            mode
            _
            _
            _
            stdlib-roots
            runtime-args
            opt-level-value
            emit-host-plan)
          (if emit-host-plan
            (begin
              (print-string (run-plan-render config))
              0)
            (native-source-run-command
              source
              target
              mode
              stdlib-roots
              runtime-args
              opt-level-value))])]
    [(ErrRunPlanConfig message)
      (begin
        (print-error message)
        1)]))