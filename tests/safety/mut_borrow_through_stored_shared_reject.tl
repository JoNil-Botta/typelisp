;: A shared reference stored in a field stays shared when the owner is reached
;: through `&mut` (#8694).
(defstruct Held
  (:lifetimes a)
  (p (& a i64)))

(define (bump [q : (&mut i64)]) : unit
  (set! (deref q) (+ (deref q) 1)))

(define (f [h : (&mut (Held a))]) : i64
  (bump (&mut h.p))
  0)

(define (main) : i64
  (let
    [n : i64 40]
    [held (Held (& n))]
    (f (&mut held))))