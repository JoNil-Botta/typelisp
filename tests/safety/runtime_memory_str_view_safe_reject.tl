;; The unchecked borrowed-view ABI carrier cannot be called from safe source.
(import stdlib.runtime)

(define (main) : i64
  (begin
    (runtime.str-view "x" 0 1)
    0))