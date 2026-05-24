;; build.tl - Selfhost source-file build host-action planner (#622).
;;
;; Emits a private `typelisp-host-plan v1` build-source plan for Rust's
;; `typelisp debug host-action` / future top-level build routing. Package build
;; remains Rust-owned in this slice.
(import "host_plan.tl")

(defenum BuildPlanConfig
  (BuildPlanConfig String bool String bool String String String))

(defenum ResultBuildPlanConfig
  (OkBuildPlanConfig BuildPlanConfig)
  (ErrBuildPlanConfig String))

(define (build-plan-unknown-target [value : String]) : String
  (host-plan-cat3 "build: unknown target " value ""))

(define (build-plan-unknown-mode [value : String]) : String
  (host-plan-cat3 "build: unknown backend mode " value ""))

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
          stdlib-lines))
      (if has-output
        (ErrBuildPlanConfig "build: -o requires a source file argument")
        (ErrBuildPlanConfig "build: expected source path")))
    (let ([current : String (arg idx)])
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
              (build-plan-append-stdlib stdlib-lines (arg (+ idx 1)))))
          (if (string-eq current "--target")
            (if (>= (+ idx 1) count)
              (ErrBuildPlanConfig "build: --target requires a value")
              (let ([value : String (arg (+ idx 1))])
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
                    stdlib-lines)
                  (ErrBuildPlanConfig (build-plan-unknown-target value)))))
            (if (string-eq current "--backend-mode")
              (if (>= (+ idx 1) count)
                (ErrBuildPlanConfig "build: --backend-mode requires a value")
                (let ([value : String (arg (+ idx 1))])
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
                      stdlib-lines)
                    (ErrBuildPlanConfig (build-plan-unknown-mode value)))))
              (if (string-eq current "--manifest-path")
                (if (>= (+ idx 1) count)
                  (ErrBuildPlanConfig "build: --manifest-path requires a value")
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
                      stdlib-lines)))))))))))

(define (build-plan-config [count : i64]) : ResultBuildPlanConfig
  (build-plan-parse-options
    1
    count
    ""
    false
    ""
    false
    "linux-x86_64"
    "scalar"
    ""))

(define (build-plan-render [config : BuildPlanConfig]) : String
  (match config
    [(BuildPlanConfig source _ output has-output target mode stdlib-lines)
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
                  (string-append stdlib-lines "end\n")))))))]))

(define (main) : i64
  (match (build-plan-config (arg-count))
    [(OkBuildPlanConfig config)
      (begin
        (print-string (build-plan-render config))
        0)]
    [(ErrBuildPlanConfig message)
      (begin
        (print-error message)
        1)]))