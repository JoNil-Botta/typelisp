;; A lambda parameter spelled like the arena shadows only the lambda body;
;; the store before it still escapes the arena (#9593).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      (set! b.value (& (deref x)))
      (let
        [f
          (lambda ([r : i64]) : i64
            r)]
        unit))))

(define (main) : i64
  0)