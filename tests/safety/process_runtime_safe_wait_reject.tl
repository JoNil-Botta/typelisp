;; Runtime wait is part of the unsafe OS seam even though its boxed capability
;; is validated before native authority can be acquired.
(import stdlib.process_runtime)

(define (main) : i64
  (begin
    (process_runtime.tl_process_wait (box 0))
    0))