;; An annotation written before a local shadows a caller lifetime names the
;; caller's lifetime, and keeps naming it inside the shadowing scope.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (keep [p : (& a i64)] [b : (&mut a (RefBox a))]) : unit
  (let
    [q : (& a i64) p]
    (let
      [a : i64 3]
      (set! b.value q))))

(define (main) : i64
  0)