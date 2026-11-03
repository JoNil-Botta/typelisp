;; A scalar `for` item spelled like the arena does not let arena data reach
;; caller storage from the loop body (#9593).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      [xs : (Array i64 2) (array 40 2)]
      (for [r xs]
        ; Must fail: the arena `r` resets before the caller reads `b.value`.
        (set! b.value (& (deref x)))))))

(define (main) : i64
  0)