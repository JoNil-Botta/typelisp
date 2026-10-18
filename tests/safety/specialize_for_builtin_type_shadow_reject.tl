(define (count [comptime i64 : type]) : i64
  (let
    [items : (Array bool 2) (array true false)]
    [total : i64 0]
    (for [item : i64 items]
      (when item (set! total (+ total 1))))
    total))

(define (main) : i64
  (count (type bool)))