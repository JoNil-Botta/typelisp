(import "stdlib/io.tl")
(import "stdlib/env.tl")
(import stdlib.process)
(import stdlib.process_borrowed)
(import "stdlib/string.tl")
(import "stdlib/test.tl")
(import stdlib.vector)
(import (vector.vector String) as svec)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

(define (assert-process-output-result
  [result : process.ResultProcessOutput]
  [expected-status : i64]
  [expected-stdout : String]
  [expected-stderr : String]) : unit
  (match result
    [(process.OkProcessOutput output)
      (begin
        (assert-i64-eq
          (process.output-status output)
          expected-status
          "process output status")
        (assert-owned-string-eq
          (process.output-stdout output)
          expected-stdout
          "process output stdout")
        (assert-owned-string-eq
          (process.output-stderr output)
          expected-stderr
          "process output stderr"))]
    [(process.ErrProcessOutput error) (panic (process.error-message error))]))

(define (assert-process-spawn-failed [result : process.ResultProcessOutput]) : unit
  (match result
    [(process.ErrProcessOutput error)
      (begin
        (assert-true
          (process.error-spawn-failed? error)
          "process missing executable spawn failed")
        (assert-owned-string-eq
          (process.error-message error)
          "process: spawn failed"
          "process spawn failed message"))]
    [(process.OkProcessOutput _)
      (panic "process missing executable should fail")]))

(define (assert-process-child-result [result : process.ResultProcessChild]) : process.ProcessChild
  (match result
    [(process.OkProcessChild child) child]
    [(process.ErrProcessChild error) (panic (process.error-message error))]))

(define (assert-process-child-spawn-failed
  [result : process.ResultProcessChild]) : unit
  (match result
    [(process.ErrProcessChild error)
      (begin
        (assert-true
          (process.error-spawn-failed? error)
          "process async missing executable spawn failed")
        (assert-owned-string-eq
          (process.error-message error)
          "process: spawn failed"
          "process async spawn failed message"))]
    [(process.OkProcessChild _)
      (panic "process async missing executable should fail")]))

(define (assert-process-child-unsupported [result : process.ResultProcessChild]) : unit
  (match result
    [(process.ErrProcessChild error)
      (begin
        (assert-true
          (process.error-unsupported? error)
          "process async unsupported")
        (assert-owned-string-eq
          (process.error-message error)
          "process: async child handles are not supported by this runtime"
          "process async unsupported message"))]
    [(process.OkProcessChild _) (panic "process async should be unsupported")]))

(define (assert-process-output-unsupported
  [result : process.ResultProcessOutput]) : unit
  (match result
    [(process.ErrProcessOutput error)
      (begin
        (assert-true
          (process.error-unsupported? error)
          "process async wait unsupported")
        (assert-owned-string-eq
          (process.error-message error)
          "process: async child handles are not supported by this runtime"
          "process async wait unsupported message"))]
    [(process.OkProcessOutput _)
      (panic "process async wait should be unsupported")]))

(define (windows-process-command) : process.ProcessCommand
  (process.command
    "C:\\Windows\\System32\\cmd.exe"
    (process.args-cons
      "/C"
      (process.args-cons
        "echo stdout=ok&& 1>&2 echo stderr=err&& exit /b 7"
        (process.args-empty)))))

(define (windows-env-command) : process.ProcessCommand
  (process.command-with-env
    (process.command
      "C:\\Windows\\System32\\cmd.exe"
      (process.args-cons
        "/C"
        (process.args-cons
          "echo %TYPELISP_PROCESS_RUNTIME_ENV%"
          (process.args-empty))))
    "TYPELISP_PROCESS_RUNTIME_ENV"
    "process-env-value"))

(define (windows-env-vec-command) : process.ProcessCommand
  (let
    [env : process.ProcessEnvVec (process.env-vec-new)]
    (begin
      (process.env-vec-append
        (&mut env)
        "TYPELISP_PROCESS_RUNTIME_ENV_VEC"
        "process-env-vec-value")
      (process.command-with-env-vec
        (process.command
          "C:\\Windows\\System32\\cmd.exe"
          (process.args-cons
            "/C"
            (process.args-cons
              "echo %TYPELISP_PROCESS_RUNTIME_ENV_VEC%"
              (process.args-empty))))
        (& env)))))

(define (windows-argv-vec-command) : process.ProcessCommand
  (let
    [argv : svec.Vec (svec.with-capacity 2)]
    (begin
      (svec.push (&mut argv) "/C")
      (svec.push (&mut argv) "echo argv-vec=ok")
      (process.command-from-argv-vec "C:\\Windows\\System32\\cmd.exe" (& argv)))))

(define (windows-borrowed-argv-output [exe : String] [argv : String]) : process.ResultProcessOutput
  (let
    [args : (process_borrowed.ProcessBorrowedStringList argv)
      (process_borrowed.args-append
        (process_borrowed.args-single (substring-view (& argv) 0 2))
        (process_borrowed.args-single
          (substring-view (& argv) 2 (- (string-length (& argv)) 2))))]
    (process_borrowed.output (process_borrowed.command (& exe) args))))

(define (windows-missing-command) : process.ProcessCommand
  (process.command
    "C:\\Windows\\System32\\definitely-missing-typelisp.exe"
    (process.args-empty)))

(define (linux-process-command) : process.ProcessCommand
  (process.command "/usr/bin/printf" (process.args-single "stdout=ok")))

(define (linux-env-command) : process.ProcessCommand
  (process.command-with-env
    (process.command
      "/usr/bin/printenv"
      (process.args-single "TYPELISP_PROCESS_RUNTIME_ENV"))
    "TYPELISP_PROCESS_RUNTIME_ENV"
    "process-env-value"))

(define (linux-env-vec-command) : process.ProcessCommand
  (let
    [env : process.ProcessEnvVec (process.env-vec-new)]
    (begin
      (process.env-vec-append
        (&mut env)
        "TYPELISP_PROCESS_RUNTIME_ENV_VEC"
        "process-env-vec-value")
      (process.command-with-env-vec
        (process.command
          "/usr/bin/printenv"
          (process.args-single "TYPELISP_PROCESS_RUNTIME_ENV_VEC"))
        (& env)))))

(define (linux-argv-vec-command) : process.ProcessCommand
  (let
    [argv : svec.Vec (svec.with-capacity 3)]
    (begin
      (svec.push (&mut argv) "%s:%s")
      (svec.push (&mut argv) "argv")
      (svec.push (&mut argv) "vec")
      (process.command-from-argv-vec "/usr/bin/printf" (& argv)))))

(define (linux-borrowed-argv-output [exe : String] [argv : String]) : process.ResultProcessOutput
  (let
    [args : (process_borrowed.ProcessBorrowedStringList argv)
      (process_borrowed.args-append
        (process_borrowed.args-single (substring-view (& argv) 0 5))
        (process_borrowed.args-append
          (process_borrowed.args-single (substring-view (& argv) 5 8))
          (process_borrowed.args-single (substring-view (& argv) 13 4))))]
    (process_borrowed.output (process_borrowed.command (& exe) args))))

(define (linux-async-process-command [text : String]) : process.ProcessCommand
  (process.command "/usr/bin/printf" (process.args-single text)))

(define (linux-borrowed-process-output [exe : String] [text : String]) : process.ResultProcessOutput
  (process_borrowed.output
    (process_borrowed.command (& exe) (process_borrowed.args-single (& text)))))

(define (linux-borrowed-process-start [exe : String] [text : String]) : process.ResultProcessChild
  (process_borrowed.start
    (process_borrowed.command (& exe) (process_borrowed.args-single (& text)))))

(define (linux-missing-command) : process.ProcessCommand
  (process.command "/definitely-missing-typelisp" (process.args-empty)))

(define (main) : i64
  (if (string-eq (env-path-separator) ";")
    (begin
      (assert-process-output-result
        (process.output (windows-process-command))
        7
        "stdout=ok\r\n"
        "stderr=err\r\n")
      (assert-process-output-result
        (process.output (windows-env-command))
        0
        "process-env-value\r\n"
        "")
      (assert-process-output-result
        (process.output (windows-env-vec-command))
        0
        "process-env-vec-value\r\n"
        "")
      (assert-process-output-result
        (process.output (windows-argv-vec-command))
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
      (assert-process-spawn-failed (process.output (windows-missing-command)))
      (assert-process-child-unsupported
        (process.start (windows-process-command)))
      (assert-process-output-unsupported
        (process.wait (process.ProcessChild 1 2 3)))
      42)
    (begin
      (assert-process-output-result
        (process.output (linux-process-command))
        0
        "stdout=ok"
        "")
      (assert-process-output-result
        (process.output (linux-env-command))
        0
        "process-env-value\n"
        "")
      (assert-process-output-result
        (process.output (linux-env-vec-command))
        0
        "process-env-vec-value\n"
        "")
      (assert-process-output-result
        (process.output (linux-argv-vec-command))
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
      (assert-process-spawn-failed (process.output (linux-missing-command)))
      (let
        [first : process.ProcessChild
          (assert-process-child-result
            (process.start (linux-async-process-command "async-one")))]
        [second : process.ProcessChild
          (assert-process-child-result
            (process.start (linux-async-process-command "async-two")))]
        [third : process.ProcessChild
          (assert-process-child-result
            (linux-borrowed-process-start "/usr/bin/printf" "borrowed-async"))]
        (begin
          (assert-process-output-result
            (process.wait third)
            0
            "borrowed-async"
            "")
          (assert-process-output-result (process.wait second) 0 "async-two" "")
          (assert-process-output-result (process.wait first) 0 "async-one" "")))
      (assert-process-child-spawn-failed
        (process.start
          (process.command
            "/definitely-missing-typelisp-async"
            (process.args-empty))))
      42)))
