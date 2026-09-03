;; Inherited-output process execution has the same validated unsafe boundary.
(import stdlib.process_runtime)

(define (main) : i64
  (let
    [command : process_runtime.ProcessRuntimeCommand
      (process_runtime.command-full
        "echo"
        (process_runtime.args-empty)
        (process_runtime.no-string)
        (process_runtime.env-empty)
        (process_runtime.no-string))]
    (begin
      (process_runtime.tl_process_inherit command)
      0)))