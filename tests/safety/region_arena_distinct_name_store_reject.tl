;; Control for the fresh `with-arena` binder (#9593): an arena whose name does
;; not collide with the caller lifetime keeps its own region and its ordinary
;; field type mismatch.
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