;: A by-value holder's `&mut` regions are its own: storing a reborrow of one
;: field's referent into another field does not change where the first field
;: points, so a later reborrow through it is still exact (#8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Mix
  (:lifetimes i a)
  (m (&mut i (RefBox a)))
  (xs (&mut a (__tl_dyn-array i64))))

(define (f [k : (Mix i a)]) : i64
  (let
    [acc : i64 0]
    [r1 (& (array-ref (deref k.xs) 0))]
    (set! (deref k.m).value r1)
    (set! acc (+ acc (deref r1)))
    (set! acc (+ acc (deref (& (array-ref (deref k.xs) 0)))))
    acc))

(define (main) : i64
  42)