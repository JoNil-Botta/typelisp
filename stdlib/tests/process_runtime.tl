(import "stdlib/env.tl")

(import "stdlib/process.tl")

(import "stdlib/test.tl")

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

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
        (assert-owned-string-eq
          (process-output-stdout output)
          expected-stdout
          message)
        (assert-owned-string-eq
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
        (assert-owned-string-eq (process-output-stdout output) "" message)
        (assert-false (string-eq (process-output-stderr output) "") message))]
    [(ErrProcessOutput _) (panic message)]))

(define (assert-process-spawn-failed
  [result : ResultProcessOutput]
  [message : String]) : unit
  (match result
    [(ErrProcessOutput error)
      (begin
        (assert-true (process-error-spawn-failed? error) message)
        (assert-owned-string-eq
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
        (assert-owned-string-eq (process-error-message error) message message))]
    [(OkProcessOutput _) (panic message)]))

(define (process-runtime-simple-command) : ProcessCommand
  (process-command
    "/usr/bin/printf"
    (process-args-single "typelisp-process-runtime")))

(define (process-runtime-cwd-command) : ProcessCommand
  (process-command-with-cwd
    (process-command
      "/usr/bin/test"
      (process-args-cons "-f" (process-args-single "process.tl")))
    "stdlib"))

(define (process-runtime-env-command) : ProcessCommand
  (process-command-with-env
    (process-command
      "/usr/bin/printenv"
      (process-args-single "TYPELISP_PROCESS_RUNTIME_ENV"))
    "TYPELISP_PROCESS_RUNTIME_ENV"
    "process-env-value"))

(define (process-runtime-env-override-command) : ProcessCommand
  (process-command-with-env
    (process-command
      "/usr/bin/printenv"
      (process-args-single "TYPELISP_STDLIB_TEST_VALUE"))
    "TYPELISP_STDLIB_TEST_VALUE"
    "process-override"))

(define (process-runtime-stdin-command) : ProcessCommand
  (process-command-with-stdin
    (process-command "/usr/bin/cat" (process-args-empty))
    "stdin-from-typelisp"))

(define (process-runtime-large-stdin) : String
  (let
    [text : String "a"]
    [i : i64 0]
    (begin
      (while (< i 17)
        (begin
          (set! text (string-append text text))
          (set! i (+ i 1))))
      text)))

(define (process-runtime-stdin-ignored-command) : ProcessCommand
  (process-command-with-stdin
    (process-command "/usr/bin/true" (process-args-empty))
    (process-runtime-large-stdin)))

(define (process-runtime-windows-command) : ProcessCommand
  (process-command
    "C:\\Windows\\System32\\cmd.exe"
    (process-args-cons
      "/C"
      (process-args-cons
        "echo stdout=ok&& 1>&2 echo stderr=err&& exit /b 7"
        (process-args-empty)))))

(define (process-runtime-windows-missing-command) : ProcessCommand
  (process-command
    "C:\\Windows\\System32\\definitely-missing-typelisp.exe"
    (process-args-empty)))

(define (main) : i64
  (if (string-eq (env-path-list-separator) ";")
    (begin
      (assert-process-ok
        (process-output (process-runtime-windows-command))
        7
        "stdout=ok\r\n"
        "stderr=err\r\n"
        "windows process output capture")
      (assert-process-spawn-failed
        (process-output (process-runtime-windows-missing-command))
        "windows process missing executable")
      42)
    (begin
      (assert-process-ok
        (process-output (process-runtime-simple-command))
        0
        "typelisp-process-runtime"
        ""
        "process stdout capture")
      (assert-process-ok
        (process-output (process-runtime-cwd-command))
        0
        ""
        ""
        "process cwd")
      (assert-process-ok
        (process-output (process-runtime-env-command))
        0
        "process-env-value\n"
        ""
        "process env override")
      (assert-process-ok
        (process-output (process-runtime-env-override-command))
        0
        "process-override\n"
        ""
        "process env override replaces inherited")
      (assert-process-ok
        (process-output (process-runtime-stdin-command))
        0
        "stdin-from-typelisp"
        ""
        "process stdin")
      (assert-process-ok
        (process-output (process-runtime-stdin-ignored-command))
        0
        ""
        ""
        "process stdin ignored")
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