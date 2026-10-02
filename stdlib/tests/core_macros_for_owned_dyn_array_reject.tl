(define (main) : i64
  (let
    [values : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [total : i64 0]
    (begin
      (for [value values]
        (set! total (+ total value)))
      total)))