(define (runtime-type [comptime T : type]) : i64
  (let
    [items : (Array i64 1) (array 1)]
    (for [_item : T items]
      unit)
    T))

(define (main) : i64
  (runtime-type (type i64)))