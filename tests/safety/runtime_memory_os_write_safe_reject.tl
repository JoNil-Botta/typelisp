;; A raw OS write requires a live initialized source range for the full call.
(import stdlib.runtime)

(define (main) : i64
  (runtime.os-write 2 (ptr-null : (Ptr u8)) 1))