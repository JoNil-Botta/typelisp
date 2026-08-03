;; A type macro constrained to the stable `slice` kind rejects ordinary types.
(defmacro (slice-only [S : type (:kind slice)]) : Module
  `(begin
    (module generated.slice_only)
    (define (sentinel) : i64
      0)))

(import (slice-only i64) as bad)

(define (main) : i64
  (bad.sentinel))