;; Compiler-emitted abort descriptors cannot be forwarded by safe source.
(import stdlib.runtime)

(define (main) : i64
  (runtime.oob-abort-at (ptr-null : (Ptr i64)) 0 0))