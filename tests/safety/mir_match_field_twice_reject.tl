;: Matching a field by value moves its payload out; a second match cannot
;: move it again (legacy accepted this double move).
(defenum Slot
  (Full (__tl_dyn-array i64))
  (Empty))

(defstruct Holder
  (slot Slot))

(define (take [_items : (__tl_dyn-array i64)]) : i64
  1)

(define (twice [h : Holder]) : i64
  (+
    (match h.slot
      [(Slot.Full items) (take items)]
      [(Slot.Empty) 0])
    (match h.slot
      [(Slot.Full items) (take items)]
      [(Slot.Empty) 0])))

(define (main) : i64
  0)