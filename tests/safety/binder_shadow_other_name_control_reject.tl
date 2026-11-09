;; Control: a binder of another name keeps the ordinary mismatch (#9609).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    s
    (let
      [x : (Box i64) (box 5)]
      [local : (& s i64) (& s (deref x))]
      [other : i64 1]
      (set! b.value local))))

(define (main) : i64
  0)