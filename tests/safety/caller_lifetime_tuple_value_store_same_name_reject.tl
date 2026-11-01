;; A tuple holding a borrow of the parameter `a` cannot be stored under the
;; caller's `a`.
(defstruct PairBox
  (:lifetimes a)
  (pair (Tuple (& a i64) i64)))

(define (store [a : i64] [b : (&mut a (PairBox a))]) : unit
  (let
    [t (tuple (& a) (+ a 0))]
    ; Must fail: `t` holds a borrow of the parameter.
    (set! b.pair t)))

(define (main) : i64
  0)