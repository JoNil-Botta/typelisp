;; Inside a typed scalar `for` carrier of a colliding with-arena region, a
;; fresh borrow of arena data still cannot reach caller storage (#9593).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      [saved : (& r i64) (& r (deref x))]
      [items : (Array (& r i64) 1) (array saved)]
      (for [r : (& r i64) items]
        ; Must fail: the arena `r` resets before the caller reads `b.value`.
        (set! b.value (& (deref x)))))))

(define (main) : i64
  0)