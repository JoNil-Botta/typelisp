(import stdlib.env)
(import stdlib.io)
(import stdlib.process)
(import stdlib.string)
(import stdlib.test)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

(define (assert-process-ok
  [result : process.ResultProcessOutput]
  [expected-status : i64]
  [expected-stdout : String]
  [expected-stderr : String]
  [message : String]) : unit
  (test.assert-true
    (process.result-output-eq?
      result
      expected-status
      expected-stdout
      expected-stderr)
    message))

(define (assert-process-spawn-failed
  [result : process.ResultProcessOutput]
  [message : String]) : unit
  (assert-owned-string-eq
    (process.result-error-message-or result "<process-ok>")
    "process: spawn failed"
    message))

(define (assert-process-child-ok
  [result : process.ResultProcessChild]
  [message : String]) : process.ProcessChild
  (let
    [info : process.ProcessChildInfo (process.child-result-info result)]
    (if (process.child-info-ok? info)
      (process.ProcessChild
        (process.child-info-pid info)
        (process.child-info-stdout-handle info)
        (process.child-info-stderr-handle info))
      (io.panic
        (string.string-append
          message
          (process.child-result-error-message-or result ""))))))

(define (assert-process-child-spawn-failed
  [result : process.ResultProcessChild]
  [message : String]) : unit
  (assert-owned-string-eq
    (process.child-result-error-message-or result "<process-ok>")
    "process: spawn failed"
    message))

(define (assert-process-unsupported
  [result : process.ResultProcessOutput]
  [message : String]) : unit
  (assert-owned-string-eq
    (process.result-error-message-or result "<process-ok>")
    message
    message))

(define (assert-process-child-unsupported
  [result : process.ResultProcessChild]
  [message : String]) : unit
  (assert-owned-string-eq
    (process.child-result-error-message-or result "<process-ok>")
    message
    message))

(define (process-runtime-simple-command) : process.ProcessCommand
  (process.command
    "/usr/bin/printf"
    (process.args-single "typelisp-process-runtime")))

(define (process-runtime-printf-command [text : String]) : process.ProcessCommand
  (process.command "/usr/bin/printf" (process.args-single text)))

(define (process-runtime-cwd-command) : process.ProcessCommand
  (process.command-with-cwd
    (process.command
      "/usr/bin/test"
      (process.args-cons "-f" (process.args-single "process.tl")))
    "stdlib"))

(define (process-runtime-env-command) : process.ProcessCommand
  (process.command-with-env
    (process.command
      "/usr/bin/printenv"
      (process.args-single "TYPELISP_PROCESS_RUNTIME_ENV"))
    "TYPELISP_PROCESS_RUNTIME_ENV"
    "process-env-value"))

(define (process-runtime-env-override-command) : process.ProcessCommand
  (process.command-with-env
    (process.command
      "/usr/bin/printenv"
      (process.args-single "TYPELISP_STDLIB_TEST_VALUE"))
    "TYPELISP_STDLIB_TEST_VALUE"
    "process-override"))

(define (process-runtime-env-vec-command) : process.ProcessCommand
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

(define (process-runtime-argv-vec-command) : process.ProcessCommand
  (let
    [argv : svec.Vec (svec.with-capacity 3)]
    (begin
      (svec.push (&mut argv) "%s:%s")
      (svec.push (&mut argv) "argv")
      (svec.push (&mut argv) "vec")
      (process.command-from-argv-vec "/usr/bin/printf" (& argv)))))

(define (process-runtime-stdin-command) : process.ProcessCommand
  (process.command-with-stdin
    (process.command "/usr/bin/cat" (process.args-empty))
    "stdin-from-typelisp"))

(define (process-runtime-large-stdin-from [text : String] [i : i64]) : String
  (if (>= i 17)
    text
    (process-runtime-large-stdin-from
      (string.string-append (& text) (& text))
      (+ i 1))))

(define (process-runtime-large-stdin) : String
  (process-runtime-large-stdin-from "a" 0))

(define (process-runtime-stdin-ignored-command) : process.ProcessCommand
  (process.command-with-stdin
    (process.command "/usr/bin/true" (process.args-empty))
    (process-runtime-large-stdin)))

(define (process-runtime-windows-command) : process.ProcessCommand
  (process.command
    "C:\\Windows\\System32\\cmd.exe"
    (process.args-cons
      "/C"
      (process.args-cons
        "echo stdout=ok&& 1>&2 echo stderr=err&& exit /b 7"
        (process.args-empty)))))

(define (process-runtime-windows-env-command) : process.ProcessCommand
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

(define (process-runtime-windows-env-vec-command) : process.ProcessCommand
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

(define (process-runtime-windows-argv-vec-command) : process.ProcessCommand
  (let
    [argv : svec.Vec (svec.with-capacity 2)]
    (begin
      (svec.push (&mut argv) "/C")
      (svec.push (&mut argv) "echo argv-vec=ok")
      (process.command-from-argv-vec "C:\\Windows\\System32\\cmd.exe" (& argv)))))

(define (process-runtime-windows-missing-command) : process.ProcessCommand
  (process.command
    "C:\\Windows\\System32\\definitely-missing-typelisp.exe"
    (process.args-empty)))

(define (main) : i64
  (if (string.string-eq (env.path-list-separator) ";")
    (begin
      (assert-process-ok
        (process.output (process-runtime-windows-command))
        7
        "stdout=ok\r\n"
        "stderr=err\r\n"
        "windows process output capture")
      (assert-process-ok
        (process.output (process-runtime-windows-env-command))
        0
        "process-env-value\r\n"
        ""
        "windows process env list override")
      (assert-process-ok
        (process.output (process-runtime-windows-env-vec-command))
        0
        "process-env-vec-value\r\n"
        ""
        "windows process env vec override")
      (assert-process-ok
        (process.output (process-runtime-windows-argv-vec-command))
        0
        "argv-vec=ok\r\n"
        ""
        "windows process argv vec")
      (assert-process-spawn-failed
        (process.output (process-runtime-windows-missing-command))
        "windows process missing executable")
      (assert-process-child-unsupported
        (process.start (process-runtime-windows-command))
        "process: async child handles are not supported by this runtime")
      (assert-process-unsupported
        (process.wait (process.ProcessChild 1 2 3))
        "process: async child handles are not supported by this runtime")
      42)
    (begin
      (assert-process-ok
        (process.output (process-runtime-simple-command))
        0
        "typelisp-process-runtime"
        ""
        "process stdout capture")
      (assert-process-ok
        (process.output (process-runtime-cwd-command))
        0
        ""
        ""
        "process cwd")
      (assert-process-ok
        (process.output (process-runtime-env-command))
        0
        "process-env-value\n"
        ""
        "process env override")
      (assert-process-ok
        (process.output (process-runtime-env-override-command))
        0
        "process-override\n"
        ""
        "process env override replaces inherited")
      (assert-process-ok
        (process.output (process-runtime-env-vec-command))
        0
        "process-env-vec-value\n"
        ""
        "process env vec override")
      (assert-process-ok
        (process.output (process-runtime-argv-vec-command))
        0
        "argv:vec"
        ""
        "process argv vec")
      (assert-process-ok
        (process.output (process-runtime-stdin-command))
        0
        "stdin-from-typelisp"
        ""
        "process stdin")
      (assert-process-ok
        (process.output (process-runtime-stdin-ignored-command))
        0
        ""
        ""
        "process stdin ignored")
      (assert-process-ok
        (process.output (process.command "/usr/bin/false" (process.args-empty)))
        1
        ""
        ""
        "process nonzero status")
      (assert-process-spawn-failed
        (process.output
          (process.command
            "/definitely_missing_typelisp_process_840"
            (process.args-empty)))
        "process missing executable")
      (let
        [child-a : process.ProcessChild
          (assert-process-child-ok
            (process.start (process-runtime-printf-command "async-a"))
            "process async start a: ")]
        [child-b : process.ProcessChild
          (assert-process-child-ok
            (process.start (process-runtime-printf-command "async-b"))
            "process async start b: ")]
        (begin
          (assert-process-ok
            (process.wait child-b)
            0
            "async-b"
            ""
            "process async wait b")
          (assert-process-ok
            (process.wait child-a)
            0
            "async-a"
            ""
            "process async wait a")))
      (assert-process-child-spawn-failed
        (process.start
          (process.command
            "/definitely_missing_typelisp_process_async_1847"
            (process.args-empty)))
        "process async missing executable")
      42)))