;; print_float.tl - write an f64 through the native tl_print_f64 runtime helper.
(define (main) : i64
  (begin
    (print-float 1.5)
    0))