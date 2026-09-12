;; A raw substring caller must prove source range validity and lifetime.
(import stdlib.runtime)

(define (main) : i64
  (begin
    (runtime.substring (ptr-null : (Ptr u8)) 0 1)
    0))