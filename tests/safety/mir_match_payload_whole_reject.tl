;: After an arm moves a payload field out, the scrutinee is maybe-moved.
(defenum Slot
  (Full (__tl_dyn-array i64))
  (Empty))

(define (take [_items : (__tl_dyn-array i64)]) : i64
  1)

(define (keep [_s : Slot]) : i64
  1)

(define (run [s : Slot]) : i64
  (+
    (match s
      [(Slot.Full items) (take items)]
      [(Slot.Empty) 0])
    (keep s)))

(define (main) : i64
  0)