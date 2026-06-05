(import "stdlib/io.tl")

;; print_float.tl - write an f64 through the stdlib platform FFI binding.
(define (main) : i64
  (begin
    (print-float 1.5)
    0))