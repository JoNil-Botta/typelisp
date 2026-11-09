;; A stack reference under a binder named like the caller lifetime is
;; rejected at the conversion (#9609).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (let
    [y : i64 5]
    [local : (& y i64) (& y)]
    [r : i64 1]
    (set! b.value local)))

(define (main) : i64
  0)