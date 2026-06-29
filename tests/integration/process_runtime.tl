(import "stdlib/io.tl")
(import "stdlib/env.tl")
(import "stdlib/process.tl")
(import "stdlib/process_borrowed.tl")
(import "stdlib/string.tl")
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
          (output-status output)
          expected-status
          "process output status")
        (assert-owned-string-eq
          (output-stdout output)
          expected-stdout
          "process output stdout")
        (assert-owned-string-eq
          (output-stderr output)
          expected-stderr
          "process output stderr"))]
    [(ErrProcessOutput error) (panic (error-message error))]))

(define (assert-process-spawn-failed [result : ResultProcessOutput]) : unit
  (match result
    [(ErrProcessOutput error)
      (begin
        (assert-true
          (error-spawn-failed? error)
          "process missing executable spawn failed")
        (assert-owned-string-eq
          (error-message error)
          "process: spawn failed"
          "process spawn failed message"))]
    [(OkProcessOutput _) (panic "process missing executable should fail")]))

(define (assert-process-child-result [result : ResultProcessChild]) : ProcessChild
  (match result
    [(OkProcessChild child) child]
    [(ErrProcessChild error) (panic (error-message error))]))

(define (assert-process-child-spawn-failed [result : ResultProcessChild]) : unit
  (match result
    [(ErrProcessChild error)
      (begin
        (assert-true
          (error-spawn-failed? error)
          "process async missing executable spawn failed")
        (assert-owned-string-eq
          (error-message error)
          "process: spawn failed"
          "process async spawn failed message"))]
    [(OkProcessChild _) (panic "process async missing executable should fail")]))

(define (assert-process-child-unsupported [result : ResultProcessChild]) : unit
  (match result
    [(ErrProcessChild error)
      (begin
        (assert-true (error-unsupported? error) "process async unsupported")
        (assert-owned-string-eq
          (error-message error)
          "process: async child handles are not supported by this runtime"
          "process async unsupported message"))]
    [(OkProcessChild _) (panic "process async should be unsupported")]))

(define (assert-process-output-unsupported [result : ResultProcessOutput]) : unit
  (match result
    [(ErrProcessOutput error)
      (begin
        (assert-true
          (error-unsupported? error)
          "process async wait unsupported")
        (assert-owned-string-eq
          (error-message error)
          "process: async child handles are not supported by this runtime"
          "process async wait unsupported message"))]
    [(OkProcessOutput _) (panic "process async wait should be unsupported")]))

(define (windows-process-command) : ProcessCommand
  (command
    "C:\\Windows\\System32\\cmd.exe"
    (args-cons
      "/C"
      (args-cons
        "echo stdout=ok&& 1>&2 echo stderr=err&& exit /b 7"
        (args-empty)))))

(define (windows-env-command) : ProcessCommand
  (command-with-env
    (command
      "C:\\Windows\\System32\\cmd.exe"
      (args-cons
        "/C"
        (args-cons "echo %TYPELISP_PROCESS_RUNTIME_ENV%" (args-empty))))
    "TYPELISP_PROCESS_RUNTIME_ENV"
    "process-env-value"))

(define (windows-env-vec-command) : ProcessCommand
  (command-with-env-vec
    (command
      "C:\\Windows\\System32\\cmd.exe"
      (args-cons
        "/C"
        (args-cons "echo %TYPELISP_PROCESS_RUNTIME_ENV_VEC%" (args-empty))))
    (env-vec-append
      (env-vec-new)
      "TYPELISP_PROCESS_RUNTIME_ENV_VEC"
      "process-env-vec-value")))

(define (windows-argv-vec-command) : ProcessCommand
  (command-from-argv-vec
    "C:\\Windows\\System32\\cmd.exe"
    (string-vec-push
      (string-vec-push (string-vec-with-capacity 2) "/C")
      "echo argv-vec=ok")))

(define (windows-borrowed-argv-output [exe : String] [argv : String]) : ResultProcessOutput
  (let
    [args : (ProcessBorrowedStringList argv)
      (args-append
        (args-single (substring-view (& argv) 0 2))
        (args-single (substring-view (& argv) 2 (- (string-length (& argv)) 2))))]
    (output (command (& exe) args))))

(define (windows-missing-command) : ProcessCommand
  (command
    "C:\\Windows\\System32\\definitely-missing-typelisp.exe"
    (args-empty)))

(define (linux-process-command) : ProcessCommand
  (command "/usr/bin/printf" (args-single "stdout=ok")))

(define (linux-env-command) : ProcessCommand
  (command-with-env
    (command "/usr/bin/printenv" (args-single "TYPELISP_PROCESS_RUNTIME_ENV"))
    "TYPELISP_PROCESS_RUNTIME_ENV"
    "process-env-value"))

(define (linux-env-vec-command) : ProcessCommand
  (command-with-env-vec
    (command
      "/usr/bin/printenv"
      (args-single "TYPELISP_PROCESS_RUNTIME_ENV_VEC"))
    (env-vec-append
      (env-vec-new)
      "TYPELISP_PROCESS_RUNTIME_ENV_VEC"
      "process-env-vec-value")))

(define (linux-argv-vec-command) : ProcessCommand
  (command-from-argv-vec
    "/usr/bin/printf"
    (string-vec-push
      (string-vec-push
        (string-vec-push (string-vec-with-capacity 3) "%s:%s")
        "argv")
      "vec")))

(define (linux-borrowed-argv-output [exe : String] [argv : String]) : ResultProcessOutput
  (let
    [args : (ProcessBorrowedStringList argv)
      (args-append
        (args-single (substring-view (& argv) 0 5))
        (args-append
          (args-single (substring-view (& argv) 5 8))
          (args-single (substring-view (& argv) 13 4))))]
    (output (command (& exe) args))))

(define (linux-async-process-command [text : String]) : ProcessCommand
  (command "/usr/bin/printf" (args-single text)))

(define (linux-borrowed-process-output [exe : String] [text : String]) : ResultProcessOutput
  (output (command (& exe) (args-single (& text)))))

(define (linux-borrowed-process-start [exe : String] [text : String]) : ResultProcessChild
  (start (command (& exe) (args-single (& text)))))

(define (linux-missing-command) : ProcessCommand
  (command "/definitely-missing-typelisp" (args-empty)))

(define (main) : i64
  (if (string-eq (env-path-separator) ";")
    (begin
      (assert-process-output-result
        (output (windows-process-command))
        7
        "stdout=ok\r\n"
        "stderr=err\r\n")
      (assert-process-output-result
        (output (windows-env-command))
        0
        "process-env-value\r\n"
        "")
      (assert-process-output-result
        (output (windows-env-vec-command))
        0
        "process-env-vec-value\r\n"
        "")
      (assert-process-output-result
        (output (windows-argv-vec-command))
        0
        "argv-vec=ok\r\n"
        "")
      (assert-process-output-result
        (windows-borrowed-argv-output
          "C:\\Windows\\System32\\cmd.exe"
          "/Cecho borrowed-argv=ok")
        0
        "borrowed-argv=ok\r\n"
        "")
      (assert-process-spawn-failed (output (windows-missing-command)))
      (assert-process-child-unsupported (start (windows-process-command)))
      (assert-process-output-unsupported (wait (ProcessChild 1 2 3)))
      42)
    (begin
      (assert-process-output-result
        (output (linux-process-command))
        0
        "stdout=ok"
        "")
      (assert-process-output-result
        (output (linux-env-command))
        0
        "process-env-value\n"
        "")
      (assert-process-output-result
        (output (linux-env-vec-command))
        0
        "process-env-vec-value\n"
        "")
      (assert-process-output-result
        (output (linux-argv-vec-command))
        0
        "argv:vec"
        "")
      (assert-process-output-result
        (linux-borrowed-argv-output "/usr/bin/printf" "%s:%sborrowedargv")
        0
        "borrowed:argv"
        "")
      (assert-process-output-result
        (linux-borrowed-process-output "/usr/bin/printf" "borrowed-stdout=ok")
        0
        "borrowed-stdout=ok"
        "")
      (assert-process-spawn-failed (output (linux-missing-command)))
      (let
        [first : ProcessChild
          (assert-process-child-result
            (start (linux-async-process-command "async-one")))]
        [second : ProcessChild
          (assert-process-child-result
            (start (linux-async-process-command "async-two")))]
        [third : ProcessChild
          (assert-process-child-result
            (linux-borrowed-process-start "/usr/bin/printf" "borrowed-async"))]
        (begin
          (assert-process-output-result (wait third) 0 "borrowed-async" "")
          (assert-process-output-result (wait second) 0 "async-two" "")
          (assert-process-output-result (wait first) 0 "async-one" "")))
      (assert-process-child-spawn-failed
        (start (command "/definitely-missing-typelisp-async" (args-empty))))
      42)))