;; Raw target helpers carry pointer/descriptor preconditions and cannot be used
;; as a safe bypass around the validated process wrapper.
(import stdlib.process_runtime)

(define (main) : i64
  (begin
    (process_runtime.linux-build-argv 0 (process_runtime.args-empty))
    0))