(define (wrong-item-type [comptime T : type]) : unit
  (let
    [items : (Array i64 1) (array 1)]
    (for [_item : T items]
      unit)))

(define (main) : i64
  (wrong-item-type (type bool))
  0)