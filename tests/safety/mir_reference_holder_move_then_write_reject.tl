;: Moving an aggregate that holds a reference moves the loan with it: the new
;: owner's later use keeps the loan live across a write of the referent.
(defstruct Holder
  (:lifetimes a)
  (r (& a i64))
  (tag String))

(define (main) : i64
  (let
    [a : i64 1]
    (let
      [first : (Holder a) (Holder (& a) "first")]
      [second : (Holder a) first]
      (set! a 2)
      (deref second.r))))