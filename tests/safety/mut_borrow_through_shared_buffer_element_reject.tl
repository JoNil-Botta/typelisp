;: A private buffer's elements are owned through the buffer, so a `&mut` borrow
;: of one through a shared reference to the buffer's owner is rejected (#8743).
(defstruct Owner
  (items (__tl_dyn-array i64)))

(define (bump [q : (&mut i64)]) : unit
  (set! (deref q) (+ (deref q) 1)))

(define (f [owner : (& Owner)]) : i64
  (bump (&mut (array-ref owner.items 0)))
  (array-ref owner.items 0))

(define (main) : i64
  (let
    [owner (Owner (__tl_make-array i64 1))]
    (f (& owner))))