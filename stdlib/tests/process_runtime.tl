(import "stdlib/env.tl")

(import "stdlib/process.tl")

(import "stdlib/test.tl")

(define (assert-process-ok
  [result : ResultProcessOutput]
  [expected-status : i64]
  [expected-stdout : String]
  [expected-stderr : String]
  [message : String]) : unit
  (match result
    [(OkProcessOutput output)
      (begin
        (assert-i64-eq (process-output-status output) expected-status message)
        (assert-string-eq
          (process-output-stdout output)
          expected-stdout
          message)
        (assert-string-eq
          (process-output-stderr output)
          expected-stderr
          message))]
    [(ErrProcessOutput _) (panic message)]))

(define (assert-process-stderr-nonempty
  [result : ResultProcessOutput]
  [expected-status : i64]
  [message : String]) : unit
  (match result
    [(OkProcessOutput output)
      (begin
        (assert-i64-eq (process-output-status output) expected-status message)
        (assert-string-eq (process-output-stdout output) "" message)
        (assert-false (string-eq (process-output-stderr output) "") message))]
    [(ErrProcessOutput _) (panic message)]))

(define (assert-process-spawn-failed
  [result : ResultProcessOutput]
  [message : String]) : unit
  (match result
    [(ErrProcessOutput error)
      (begin
        (assert-true (process-error-spawn-failed? error) message)
        (assert-string-eq
          (process-error-message error)
          "process: spawn failed"
          message))]
    [(OkProcessOutput _) (panic message)]))

(define (assert-process-unsupported
  [result : ResultProcessOutput]
  [message : String]) : unit
  (match result
    [(ErrProcessOutput error)
      (begin
        (assert-true (process-error-unsupported? error) message)
        (assert-string-eq (process-error-message error) message message))]
    [(OkProcessOutput _) (panic message)]))

(define (process-runtime-simple-command) : ProcessCommand
  (process-command
    "/usr/bin/printf"
    (process-args-single "typelisp-process-runtime")))

(define (main) : i64
  (if (string-eq (env-path-list-separator) ";")
    (begin
      (assert-process-unsupported
        (process-output (process-runtime-simple-command))
        "process: runtime execution is not supported on this target")
      42)
    (begin
      (assert-process-ok
        (process-output (process-runtime-simple-command))
        0
        "typelisp-process-runtime"
        ""
        "process stdout capture")
      (assert-process-ok
        (process-output (process-command "/usr/bin/false" (process-args-empty)))
        1
        ""
        ""
        "process nonzero status")
      (assert-process-stderr-nonempty
        (process-output
          (process-command
            "/usr/bin/ls"
            (process-args-single "/definitely_missing_typelisp_process_840")))
        2
        "process stderr capture")
      (assert-process-spawn-failed
        (process-output
          (process-command
            "/definitely_missing_typelisp_process_840"
            (process-args-empty)))
        "process missing executable")
      42)))