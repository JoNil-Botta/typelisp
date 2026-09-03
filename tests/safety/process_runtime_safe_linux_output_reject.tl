;; The target-specific runtime path is not a public bypass around the validated
;; cross-target process entry.
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
      (process_runtime.linux-output command)
      0)))