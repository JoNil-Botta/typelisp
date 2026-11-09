;; An equal spelling still reaches the ownership graph, which rejects the
;; local borrow (#8890, #9609).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut a (RefBox a))]) : unit
  (let
    [a : i64 5]
    [la : (& a i64) (& a)]
    (set! b.value la)))

(define (main) : i64
  0)