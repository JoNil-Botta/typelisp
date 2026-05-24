;; run.tl - Selfhost source-file run host-action planner (#622).

;;

;; Emits a private `typelisp-host-plan v1` run-source plan for Rust's

;; `typelisp debug host-action` / future top-level run routing. Rust remains the

;; process boundary; this driver only parses argv and emits the plan.

(import "host_plan.tl")

(defenum RunPlanConfig
  (RunPlanConfig String String String String String))

(defenum ResultRunPlanConfig
  (OkRunPlanConfig RunPlanConfig)
  (ErrRunPlanConfig String))

(define (run-plan-unknown-target [value : String]) : String
  (host-plan-cat3 "run: unknown target " value ""))

(define (run-plan-unknown-mode [value : String]) : String
  (host-plan-cat3 "run: unknown backend mode " value ""))

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
  [stdlib-lines : String]
  [runtime-lines : String]) : ResultRunPlanConfig
  (if (>= idx count)
    (OkRunPlanConfig
      (RunPlanConfig source target mode stdlib-lines runtime-lines))
    (let
      [current : String (arg idx)]
      (if (string-eq current "--")
        (OkRunPlanConfig
          (RunPlanConfig
            source
            target
            mode
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
                    stdlib-lines
                    runtime-lines)
                  (ErrRunPlanConfig (run-plan-unknown-mode value)))))
            (if (string-eq current "--stdlib-root")
              (if (>= (+ idx 1) count)
                (ErrRunPlanConfig "run: --stdlib-root requires a value")
                (run-plan-parse-options
                  (+ idx 2)
                  count
                  source
                  target
                  mode
                  (run-plan-append-stdlib stdlib-lines (arg (+ idx 1)))
                  runtime-lines))
              (OkRunPlanConfig
                (RunPlanConfig
                  source
                  target
                  mode
                  stdlib-lines
                  (run-plan-runtime-args idx count runtime-lines))))))))))

(define (run-plan-config [count : i64]) : ResultRunPlanConfig
  (if (< count 2)
    (ErrRunPlanConfig "run: expected source path")
    (let
      [source : String (arg 1)]
      (if (host-plan-flag? source)
        (ErrRunPlanConfig "run: expected source path before flags")
        (run-plan-parse-options 2 count source "linux-x86_64" "scalar" "" "")))))

(define (run-plan-render [config : RunPlanConfig]) : String
  (match config
    [(RunPlanConfig source target mode stdlib-lines runtime-lines)
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
                  stdlib-lines
                  (string-append runtime-lines "end\n")))))))]))

(define (main) : i64
  (match (run-plan-config (arg-count))
    [(OkRunPlanConfig config)
      (begin
        (print-string (run-plan-render config))
        0)]
    [(ErrRunPlanConfig message)
      (begin
        (print-error message)
        1)]))