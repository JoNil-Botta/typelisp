;; A non-colliding arena keeps its own region and its ordinary field type
;; mismatch (#9593).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    q
    (let
      [x : (Box i64) (box 5)]
      ; Must fail: `(& q i64)` is not `(& r i64)`.
      (set! b.value (& (deref x))))))

(define (main) : i64
  0)