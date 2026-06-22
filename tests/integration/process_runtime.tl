(import "stdlib/io.tl")
(import "stdlib/env.tl")
(import "stdlib/process_borrowed.tl")
(import "stdlib/test.tl")
(import "stdlib/vector.tl")
(import "stdlib/string.tl")

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

(define (assert-process-output-result
  [result : ResultProcessOutput]
  [expected-status : i64]
  [expected-stdout : String]
  [expected-stderr : String]) : unit
  (match result
    [(OkProcessOutput output)
      (begin
        (assert-i64-eq
          (process-output-status output)
          expected-status
          "process output status")
        (assert-owned-string-eq
          (process-output-stdout output)
          expected-stdout
          "process output stdout")
        (assert-owned-string-eq
          (process-output-stderr output)
          expected-stderr
          "process output stderr"))]
    [(ErrProcessOutput error) (panic (process-error-message error))]))

(define (assert-process-spawn-failed [result : ResultProcessOutput]) : unit
  (match result
    [(ErrProcessOutput error)
      (begin
        (assert-true
          (process-error-spawn-failed? error)
          "process missing executable spawn failed")
        (assert-owned-string-eq
          (process-error-message error)
          "process: spawn failed"
          "process spawn failed message"))]
    [(OkProcessOutput _) (panic "process missing executable should fail")]))

(define (assert-process-child-result [result : ResultProcessChild]) : ProcessChild
  (match result
    [(OkProcessChild child) child]
    [(ErrProcessChild error) (panic (process-error-message error))]))

(define (assert-process-child-spawn-failed [result : ResultProcessChild]) : unit
  (match result
    [(ErrProcessChild error)
      (begin
        (assert-true
          (process-error-spawn-failed? error)
          "process async missing executable spawn failed")
        (assert-owned-string-eq
          (process-error-message error)
          "process: spawn failed"
          "process async spawn failed message"))]
    [(OkProcessChild _) (panic "process async missing executable should fail")]))

(define (assert-process-child-unsupported [result : ResultProcessChild]) : unit
  (match result
    [(ErrProcessChild error)
      (begin
        (assert-true
          (process-error-unsupported? error)
          "process async unsupported")
        (assert-owned-string-eq
          (process-error-message error)
          "process: async child handles are not supported by this runtime"
          "process async unsupported message"))]
    [(OkProcessChild _) (panic "process async should be unsupported")]))

(define (assert-process-output-unsupported [result : ResultProcessOutput]) : unit
  (match result
    [(ErrProcessOutput error)
      (begin
        (assert-true
          (process-error-unsupported? error)
          "process async wait unsupported")
        (assert-owned-string-eq
          (process-error-message error)
          "process: async child handles are not supported by this runtime"
          "process async wait unsupported message"))]
    [(OkProcessOutput _) (panic "process async wait should be unsupported")]))

(define (windows-process-command) : ProcessCommand
  (process-command
    "C:\\Windows\\System32\\cmd.exe"
    (process-args-cons
      "/C"
      (process-args-cons
        "echo stdout=ok&& 1>&2 echo stderr=err&& exit /b 7"
        (process-args-empty)))))

(define (windows-env-command) : ProcessCommand
  (process-command-with-env
    (process-command
      "C:\\Windows\\System32\\cmd.exe"
      (process-args-cons
        "/C"
        (process-args-cons
          "echo %TYPELISP_PROCESS_RUNTIME_ENV%"
          (process-args-empty))))
    "TYPELISP_PROCESS_RUNTIME_ENV"
    "process-env-value"))

(define (windows-env-vec-command) : ProcessCommand
  (process-command-with-env-vec
    (process-command
      "C:\\Windows\\System32\\cmd.exe"
      (process-args-cons
        "/C"
        (process-args-cons
          "echo %TYPELISP_PROCESS_RUNTIME_ENV_VEC%"
          (process-args-empty))))
    (process-env-vec-append
      (process-env-vec-new)
      "TYPELISP_PROCESS_RUNTIME_ENV_VEC"
      "process-env-vec-value")))

(define (windows-argv-vec-command) : ProcessCommand
  (process-command-from-argv-vec
    "C:\\Windows\\System32\\cmd.exe"
    (string-vec-push
      (string-vec-push (string-vec-with-capacity 2) "/C")
      "echo argv-vec=ok")))

(define (windows-missing-command) : ProcessCommand
  (process-command
    "C:\\Windows\\System32\\definitely-missing-typelisp.exe"
    (process-args-empty)))

(define (linux-process-command) : ProcessCommand
  (process-command "/usr/bin/printf" (process-args-single "stdout=ok")))

(define (linux-env-command) : ProcessCommand
  (process-command-with-env
    (process-command
      "/usr/bin/printenv"
      (process-args-single "TYPELISP_PROCESS_RUNTIME_ENV"))
    "TYPELISP_PROCESS_RUNTIME_ENV"
    "process-env-value"))

(define (linux-env-vec-command) : ProcessCommand
  (process-command-with-env-vec
    (process-command
      "/usr/bin/printenv"
      (process-args-single "TYPELISP_PROCESS_RUNTIME_ENV_VEC"))
    (process-env-vec-append
      (process-env-vec-new)
      "TYPELISP_PROCESS_RUNTIME_ENV_VEC"
      "process-env-vec-value")))

(define (linux-argv-vec-command) : ProcessCommand
  (process-command-from-argv-vec
    "/usr/bin/printf"
    (string-vec-push
      (string-vec-push
        (string-vec-push (string-vec-with-capacity 3) "%s:%s")
        "argv")
      "vec")))

(define (linux-async-process-command [text : String]) : ProcessCommand
  (process-command "/usr/bin/printf" (process-args-single text)))

(define (linux-borrowed-process-output [exe : String] [text : String]) : ResultProcessOutput
  (process-borrowed-output
    (process-borrowed-command (& exe) (process-borrowed-args-single (& text)))))

(define (linux-borrowed-process-start [exe : String] [text : String]) : ResultProcessChild
  (process-borrowed-start
    (process-borrowed-command (& exe) (process-borrowed-args-single (& text)))))

(define (linux-missing-command) : ProcessCommand
  (process-command "/definitely-missing-typelisp" (process-args-empty)))

(define (main) : i64
  (if (string-eq (env-path-separator) ";")
    (begin
      (assert-process-output-result
        (process-output (windows-process-command))
        7
        "stdout=ok\r\n"
        "stderr=err\r\n")
      (assert-process-output-result
        (process-output (windows-env-command))
        0
        "process-env-value\r\n"
        "")
      (assert-process-output-result
        (process-output (windows-env-vec-command))
        0
        "process-env-vec-value\r\n"
        "")
      (assert-process-output-result
        (process-output (windows-argv-vec-command))
        0
        "argv-vec=ok\r\n"
        "")
      (assert-process-spawn-failed (process-output (windows-missing-command)))
      (assert-process-child-unsupported
        (process-start (windows-process-command)))
      (assert-process-output-unsupported (process-wait (ProcessChild 1 2 3)))
      42)
    (begin
      (assert-process-output-result
        (process-output (linux-process-command))
        0
        "stdout=ok"
        "")
      (assert-process-output-result
        (process-output (linux-env-command))
        0
        "process-env-value\n"
        "")
      (assert-process-output-result
        (process-output (linux-env-vec-command))
        0
        "process-env-vec-value\n"
        "")
      (assert-process-output-result
        (process-output (linux-argv-vec-command))
        0
        "argv:vec"
        "")
      (assert-process-output-result
        (linux-borrowed-process-output "/usr/bin/printf" "borrowed-stdout=ok")
        0
        "borrowed-stdout=ok"
        "")
      (assert-process-spawn-failed (process-output (linux-missing-command)))
      (let
        [first : ProcessChild
          (assert-process-child-result
            (process-start (linux-async-process-command "async-one")))]
        [second : ProcessChild
          (assert-process-child-result
            (process-start (linux-async-process-command "async-two")))]
        [third : ProcessChild
          (assert-process-child-result
            (linux-borrowed-process-start "/usr/bin/printf" "borrowed-async"))]
        (begin
          (assert-process-output-result
            (process-wait third)
            0
            "borrowed-async"
            "")
          (assert-process-output-result (process-wait second) 0 "async-two" "")
          (assert-process-output-result (process-wait first) 0 "async-one" "")))
      (assert-process-child-spawn-failed
        (process-start
          (process-command
            "/definitely-missing-typelisp-async"
            (process-args-empty))))
      42)))