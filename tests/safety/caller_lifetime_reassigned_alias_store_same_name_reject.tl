;; An alias typed with a caller lifetime cannot be reassigned a borrow of a
;; parameter with the same name, which would then reach caller storage.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

; Must fail: `(& a)` borrows the parameter, not the caller's `a`.
(define (store [a : i64] [p : (& a i64)] [b : (&mut a (RefBox a))]) : unit
  (let
    [r p]
    (set! r (& a))
    (set! b.value r)))

(define (main) : i64
  0)