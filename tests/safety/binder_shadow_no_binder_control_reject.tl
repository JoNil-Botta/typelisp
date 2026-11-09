;; Control: the same store with no binder keeps its ordinary mismatch (#9609).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    s
    (let
      [x : (Box i64) (box 5)]
      [local : (& s i64) (& s (deref x))]
      (set! b.value local))))

(define (main) : i64
  0)