;; A borrow of the binder annotated with its name is rejected by the
;; ownership graph (#8890, #9609).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defenum Opt
  (:lifetimes a)
  (None)
  (Some (& a i64)))

(define (f [b : (&mut r (RefBox r))]) : unit
  (let
    [r : i64 1]
    [z : (& r i64) (& r)]
    (set! b.value z)))

(define (main) : i64
  0)