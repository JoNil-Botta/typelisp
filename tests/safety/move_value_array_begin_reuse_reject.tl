(define (sum [items : (__tl_dyn-array i64)]) : i64
  (array-ref items 0))

(define (pick [items : (__tl_dyn-array i64)]) : i64
  (+
    (sum
      (begin
        (array-length items)
        items))
    (array-length items)))

(define (main) : i64
  42)