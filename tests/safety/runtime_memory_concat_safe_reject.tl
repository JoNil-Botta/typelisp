;; Raw concatenation source ranges cannot be supplied by safe source.
(import stdlib.runtime)

(define (main) : i64
  (begin
    (runtime.string-concat (ptr-null : (Ptr u8)) 0 (ptr-null : (Ptr u8)) 0)
    0))