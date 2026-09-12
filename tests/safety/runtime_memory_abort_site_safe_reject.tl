;; Compiler-emitted abort descriptors cannot be forged and read by safe source.
(import stdlib.runtime)

(define (main) : i64
  (runtime.abort-site-word (ptr-null : (Ptr i64)) 0))