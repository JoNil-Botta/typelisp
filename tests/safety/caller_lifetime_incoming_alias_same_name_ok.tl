;; Caller-owned references remain valid when a scalar storage owner has the same name.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [a : i64] [p : (& a i64)] [b : (&mut a (RefBox a))]) : unit
  (let
    [r p]
    (set! b.value r)))

(define (main) : i64
  0)