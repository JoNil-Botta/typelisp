(import stdlib.env)
(import stdlib.process)
(import stdlib.string)
(import stdlib.test)

(define (assert-process-output-eq
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

(define (process-runtime-stderr-linux-command) : process.ProcessCommand
  (process.command
    "/bin/sh"
    (process.args-cons
      "-c"
      (process.args-single "printf typelisp-process-stderr 1>&2; exit 7"))))

(define (process-runtime-stderr-windows-command) : process.ProcessCommand
  (process.command
    "C:\\Windows\\System32\\cmd.exe"
    (process.args-cons
      "/C"
      (process.args-cons
        "1>&2 echo typelisp-process-stderr&& exit /b 7"
        (process.args-empty)))))

(define (main) : i64
  (if (string.eq (env.path-list-separator) ";")
    (begin
      (assert-process-output-eq
        (process.output (process-runtime-stderr-windows-command))
        7
        ""
        "typelisp-process-stderr\r\n"
        "windows process stable stderr capture")
      42)
    (begin
      (assert-process-output-eq
        (process.output (process-runtime-stderr-linux-command))
        7
        ""
        "typelisp-process-stderr"
        "linux process stable stderr capture")
      42)))