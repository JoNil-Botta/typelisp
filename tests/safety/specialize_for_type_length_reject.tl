(define (type-as-length [comptime T : type]) : unit
  (let
    [items : (Array (Array i64 1) 1) (array (array 1))]
    (for [_item : (Array i64 T) items]
      unit)))

(define (main) : i64
  (type-as-length (type i64))
  0)