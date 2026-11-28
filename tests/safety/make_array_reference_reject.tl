(define (count [value : (& source i64)]) : i64
  (let
    [items (__tl_make-array (& source i64) (deref value))]
    (length items)))

(define (main) : i64
  (let
    [zero : i64 0]
    (count (& zero))))