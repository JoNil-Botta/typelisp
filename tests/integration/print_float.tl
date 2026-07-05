(import stdlib.io)

;; print_float.tl - write an f64 through the stdlib platform FFI binding.
(define (main) : i64
  (begin
    (io.print-float 1.5)
    0))
