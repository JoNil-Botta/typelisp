;; A later local spelled like the arena does not let a fresh borrow of arena
;; data, taken inside that local's scope, reach caller storage (#9593). This
;; rejects only because the stored value is the fresh `(& (deref x))`: arena
;; data bound before the shadowing local and stored after it is still accepted,
;; a pre-existing binder-identity hole tracked by #9609.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      [r : i64 1]
      (set! b.value (& (deref x))))))

(define (main) : i64
  0)