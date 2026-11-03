;; After a self-named carrier of a colliding with-arena region (#9593, #8998
;; L2), a direct borrow of arena data still cannot reach caller storage.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      [r : (& r i64) (& r (deref x))]
      ; Must fail: the arena `r` resets before the caller reads `b.value`.
      (set! b.value (& (deref x))))))

(define (main) : i64
  0)