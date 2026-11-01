;; A reference-bearing aggregate built from a local cannot be stored under a
;; caller lifetime with the same name.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut a (RefBox a))]) : unit
  (let
    [a : i64 1]
    ; Must fail: `rb` holds a borrow of the local `a`.
    [rb (RefBox (& a))]
    (set! (deref b) rb)))

(define (main) : i64
  0)