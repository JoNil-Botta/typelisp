;; A macro type operand may not hide a bare Slice in its element type.
(defmacro (slice-nested [S : type]) : Module
  `(begin
    (module generated.slice_nested)
    (define (sentinel) : i64
      0)))

(import (slice-nested (Slice (Slice i64))) as bad)

(define (main) : i64
  (bad.sentinel))