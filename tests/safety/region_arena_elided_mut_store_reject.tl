;; Elision cannot let a reference into the scoped arena escape into caller
;; storage through the same shape as the valid caller-reference store.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [p : (& r i64)] [b : (&mut (RefBox r))]) : i64
  (with-arena
    q
    (let
      [x : (Box i64) (box 30)]
      (set! b.value (& q (deref x)))
      (deref p))))

(define (main) : i64
  0)