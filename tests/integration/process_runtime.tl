(import "stdlib/process.tl")

(import "stdlib/test.tl")

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
        (assert-string-eq
          (process-output-stdout output)
          expected-stdout
          "process output stdout")
        (assert-string-eq
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
        (assert-string-eq
          (process-error-message error)
          "process: spawn failed"
          "process spawn failed message"))]
    [(OkProcessOutput _) (panic "process missing executable should fail")]))

(define (windows-process-command) : ProcessCommand
  (process-command
    "C:\\Windows\\System32\\cmd.exe"
    (process-args-cons
      "/C"
      (process-args-cons
        "echo stdout=ok&& 1>&2 echo stderr=err&& exit /b 7"
        (process-args-empty)))))

(define (windows-missing-command) : ProcessCommand
  (process-command
    "C:\\Windows\\System32\\definitely-missing-typelisp.exe"
    (process-args-empty)))

(define (linux-process-command) : ProcessCommand
  (process-command "/usr/bin/printf" (process-args-single "stdout=ok")))

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
      (assert-process-spawn-failed (process-output (windows-missing-command)))
      42)
    (begin
      (assert-process-output-result
        (process-output (linux-process-command))
        0
        "stdout=ok"
        "")
      (assert-process-spawn-failed (process-output (linux-missing-command)))
      42)))