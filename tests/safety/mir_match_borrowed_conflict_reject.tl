;: Binders of a borrowed match are references into the scrutinee's referent:
;: its owner cannot be replaced while a binder is still used.
(defenum Slot
  (Full (__tl_dyn-array i64))
  (Empty))

(define (peek [_items : (& items (__tl_dyn-array i64))]) : i64
  1)

(define (run [s : Slot] [other : Slot]) : i64
  (match (& s)
    [(Slot.Full items)
      (begin
        (set! s other)
        (peek items))]
    [(Slot.Empty) 0]))

(define (main) : i64
  0)