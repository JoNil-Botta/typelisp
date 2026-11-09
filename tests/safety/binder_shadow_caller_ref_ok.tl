;; Genuine caller data keeps its lifetime under a binder of the same name
;; (#9609).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))] [p : (& r i64)]) : unit
  (let
    [r : i64 1]
    (set! b.value p)))

(define (main) : i64
  0)