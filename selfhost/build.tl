;; build.tl - Selfhost source-file build tool (#1018).
;;
;; `--direct` builds source files with stdlib fs/process helpers. The default
;; host-plan mode preserves the private Rust/stage0 compatibility bridge.
(import "host_plan.tl")

(import "build_run_core.tl")

(defenum BuildPlanConfig
  (BuildPlanConfig String bool String bool String String String String))

(defenum ResultBuildPlanConfig
  (OkBuildPlanConfig BuildPlanConfig)
  (ErrBuildPlanConfig String))

(defenum BuildCliConfig
  (BuildCliConfig
    String
    bool
    String
    bool
    CompilerBackendTarget
    CompilerLoadRootList
    i64))

(defenum ResultBuildCliConfig
  (OkBuildCliConfig BuildCliConfig)
  (ErrBuildCliConfig String))

(define (build-plan-unknown-target [value : String]) : String
  (host-plan-cat3 "build: unknown target " value ""))

(define (build-plan-unknown-mode [value : String]) : String
  (host-plan-cat3 "build: unknown backend mode " value ""))

(define (build-plan-unknown-opt-level [value : String]) : String
  (host-plan-cat3 "build: unknown opt level " value ""))

(define (build-plan-append-stdlib [stdlib-lines : String] [root : String]) : String
  (string-append stdlib-lines (host-plan-netline "stdlib-root" root)))

(define (build-plan-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [has-source : bool]
  [output : String]
  [has-output : bool]
  [target : String]
  [mode : String]
  [opt-level : String]
  [stdlib-lines : String]) : ResultBuildPlanConfig
  (if (>= idx count)
    (if has-source
      (OkBuildPlanConfig
        (BuildPlanConfig
          source
          has-source
          output
          has-output
          target
          mode
          opt-level
          stdlib-lines))
      (if has-output
        (ErrBuildPlanConfig "build: -o requires a source file argument")
        (ErrBuildPlanConfig "build: expected source path")))
    (let
      [current : String (arg idx)]
      (if (string-eq current "-o")
        (if (>= (+ idx 1) count)
          (ErrBuildPlanConfig "build: -o requires a value")
          (if has-output
            (ErrBuildPlanConfig "build: -o was provided more than once")
            (build-plan-parse-options
              (+ idx 2)
              count
              source
              has-source
              (arg (+ idx 1))
              true
              target
              mode
              opt-level
              stdlib-lines)))
        (if (string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrBuildPlanConfig "build: --stdlib-root requires a value")
            (build-plan-parse-options
              (+ idx 2)
              count
              source
              has-source
              output
              has-output
              target
              mode
              opt-level
              (build-plan-append-stdlib stdlib-lines (arg (+ idx 1)))))
          (if (string-eq current "--target")
            (if (>= (+ idx 1) count)
              (ErrBuildPlanConfig "build: --target requires a value")
              (let
                [value : String (arg (+ idx 1))]
                (if (host-plan-target-valid? value)
                  (build-plan-parse-options
                    (+ idx 2)
                    count
                    source
                    has-source
                    output
                    has-output
                    value
                    mode
                    opt-level
                    stdlib-lines)
                  (ErrBuildPlanConfig (build-plan-unknown-target value)))))
            (if (string-eq current "--backend-mode")
              (if (>= (+ idx 1) count)
                (ErrBuildPlanConfig "build: --backend-mode requires a value")
                (let
                  [value : String (arg (+ idx 1))]
                  (if (host-plan-backend-mode-valid? value)
                    (build-plan-parse-options
                      (+ idx 2)
                      count
                      source
                      has-source
                      output
                      has-output
                      target
                      value
                      opt-level
                      stdlib-lines)
                    (ErrBuildPlanConfig (build-plan-unknown-mode value)))))
              (if (string-eq current "--opt-level")
                (if (>= (+ idx 1) count)
                  (ErrBuildPlanConfig "build: --opt-level requires a value")
                  (let
                    [value : String (arg (+ idx 1))]
                    (if (host-plan-opt-level-valid? value)
                      (build-plan-parse-options
                        (+ idx 2)
                        count
                        source
                        has-source
                        output
                        has-output
                        target
                        mode
                        value
                        stdlib-lines)
                      (ErrBuildPlanConfig (build-plan-unknown-opt-level value)))))
                (if (string-eq current "--manifest-path")
                  (if (>= (+ idx 1) count)
                    (ErrBuildPlanConfig
                      "build: --manifest-path requires a value")
                    (ErrBuildPlanConfig
                      "build: --manifest-path is handled by Rust typelisp build; selfhost build planner expects a source file"))
                  (if (host-plan-flag? current)
                    (ErrBuildPlanConfig
                      (string-append "build: unknown flag " current))
                    (if has-source
                      (ErrBuildPlanConfig "build: accepts only one source file")
                      (build-plan-parse-options
                        (+ idx 1)
                        count
                        current
                        true
                        output
                        has-output
                        target
                        mode
                        opt-level
                        stdlib-lines))))))))))))

(define (build-plan-config [count : i64]) : ResultBuildPlanConfig
  (build-plan-config-from 1 count))

(define (build-plan-config-from [idx : i64] [count : i64]) : ResultBuildPlanConfig
  (build-plan-parse-options
    idx
    count
    ""
    false
    ""
    false
    (source-tool-default-target-name)
    "scalar"
    ""
    ""))

(define (build-plan-render [config : BuildPlanConfig]) : String
  (match config
    [(BuildPlanConfig
        source
        _
        output
        has-output
        target
        mode
        opt-level
        stdlib-lines)
      (string-append
        (host-plan-header)
        (string-append
          (host-plan-word-line "action" "build-source")
          (string-append
            (host-plan-netline "source" source)
            (string-append
              (if has-output
                (host-plan-netline "output" output)
                "")
              (string-append
                (host-plan-word-line "target" target)
                (string-append
                  (host-plan-word-line "backend-mode" mode)
                  (string-append
                    (if (string-eq opt-level "")
                      ""
                      (host-plan-word-line "opt-level" opt-level))
                    (string-append stdlib-lines "end\n"))))))))]))

(define (build-host-plan-main [idx : i64]) : i64
  (match (build-plan-config-from idx (arg-count))
    [(OkBuildPlanConfig config)
      (begin
        (print-string (build-plan-render config))
        0)]
    [(ErrBuildPlanConfig message)
      (begin
        (print-error message)
        1)]))

(define (build-cli-unknown-target [value : String]) : String
  (source-tool-cat3 "build: unknown target " value ""))

(define (build-cli-unknown-mode [value : String]) : String
  (source-tool-cat3 "build: unknown backend mode " value ""))

(define (build-cli-unknown-opt-level [value : String]) : String
  (source-tool-cat3 "build: unknown opt level " value ""))

(define (build-cli-parse-options
  [idx : i64]
  [count : i64]
  [source : String]
  [has-source : bool]
  [output : String]
  [has-output : bool]
  [target : CompilerBackendTarget]
  [stdlib-roots : CompilerLoadRootList]
  [opt-level : i64]) : ResultBuildCliConfig
  (if (>= idx count)
    (if has-source
      (OkBuildCliConfig
        (BuildCliConfig
          source
          has-source
          output
          has-output
          target
          stdlib-roots
          opt-level))
      (if has-output
        (ErrBuildCliConfig "build: -o requires a source file argument")
        (ErrBuildCliConfig "build: expected source path")))
    (let
      [current : String (arg idx)]
      (if (string-eq current "-o")
        (if (>= (+ idx 1) count)
          (ErrBuildCliConfig "build: -o requires a value")
          (if has-output
            (ErrBuildCliConfig "build: -o was provided more than once")
            (build-cli-parse-options
              (+ idx 2)
              count
              source
              has-source
              (arg (+ idx 1))
              true
              target
              stdlib-roots
              opt-level)))
        (if (string-eq current "--stdlib-root")
          (if (>= (+ idx 1) count)
            (ErrBuildCliConfig "build: --stdlib-root requires a value")
            (build-cli-parse-options
              (+ idx 2)
              count
              source
              has-source
              output
              has-output
              target
              (source-tool-root-list-append stdlib-roots (arg (+ idx 1)))
              opt-level))
          (if (string-eq current "--target")
            (if (>= (+ idx 1) count)
              (ErrBuildCliConfig "build: --target requires a value")
              (let
                [value : String (arg (+ idx 1))]
                (match (source-tool-target value)
                  [(OkSourceToolTarget parsed-target)
                    (build-cli-parse-options
                      (+ idx 2)
                      count
                      source
                      has-source
                      output
                      has-output
                      parsed-target
                      stdlib-roots
                      opt-level)]
                  [(ErrSourceToolTarget _)
                    (ErrBuildCliConfig (build-cli-unknown-target value))])))
            (if (string-eq current "--backend-mode")
              (if (>= (+ idx 1) count)
                (ErrBuildCliConfig "build: --backend-mode requires a value")
                (let
                  [value : String (arg (+ idx 1))]
                  (if (source-tool-backend-mode-valid? value)
                    (build-cli-parse-options
                      (+ idx 2)
                      count
                      source
                      has-source
                      output
                      has-output
                      target
                      stdlib-roots
                      opt-level)
                    (ErrBuildCliConfig (build-cli-unknown-mode value)))))
              (if (string-eq current "--opt-level")
                (if (>= (+ idx 1) count)
                  (ErrBuildCliConfig "build: --opt-level requires a value")
                  (let
                    [value : String (arg (+ idx 1))]
                    (if (source-tool-opt-level-valid? value)
                      (build-cli-parse-options
                        (+ idx 2)
                        count
                        source
                        has-source
                        output
                        has-output
                        target
                        stdlib-roots
                        (string->int value))
                      (ErrBuildCliConfig (build-cli-unknown-opt-level value)))))
                (if (string-eq current "--manifest-path")
                  (if (>= (+ idx 1) count)
                    (ErrBuildCliConfig
                      "build: --manifest-path requires a value")
                    (ErrBuildCliConfig
                      "build: --manifest-path is handled by Rust typelisp build; selfhost build tool expects a source file"))
                  (if (source-tool-flag? current)
                    (ErrBuildCliConfig
                      (string-append "build: unknown flag " current))
                    (if has-source
                      (ErrBuildCliConfig "build: accepts only one source file")
                      (build-cli-parse-options
                        (+ idx 1)
                        count
                        current
                        true
                        output
                        has-output
                        target
                        stdlib-roots
                        opt-level))))))))))))

(define (build-cli-config [count : i64]) : ResultBuildCliConfig
  (build-cli-config-from 1 count))

(define (build-cli-config-from [idx : i64] [count : i64]) : ResultBuildCliConfig
  (build-cli-parse-options
    idx
    count
    ""
    false
    ""
    false
    (source-tool-default-target)
    CompilerLoadRootNil
    (compiler-optimize-default-level)))

(define (build-cli-main) : i64
  (match (build-cli-config (arg-count))
    [(OkBuildCliConfig config)
      (match config
        [(BuildCliConfig
            source
            _
            output
            has-output
            target
            stdlib-roots
            opt-level)
          (source-tool-build-source
            source
            output
            has-output
            target
            stdlib-roots
            opt-level)])]
    [(ErrBuildCliConfig message)
      (begin
        (print-error message)
        1)]))

(define (main) : i64
  (if (and (> (arg-count) 1) (string-eq (arg 1) "--direct"))
    (match (build-cli-config-from 2 (arg-count))
      [(OkBuildCliConfig config)
        (match config
          [(BuildCliConfig
              source
              _
              output
              has-output
              target
              stdlib-roots
              opt-level)
            (source-tool-build-source
              source
              output
              has-output
              target
              stdlib-roots
              opt-level)])]
      [(ErrBuildCliConfig message)
        (begin
          (print-error message)
          1)])
    (if (and (> (arg-count) 1) (string-eq (arg 1) "--host-plan"))
      (build-host-plan-main 2)
      (build-host-plan-main 1))))