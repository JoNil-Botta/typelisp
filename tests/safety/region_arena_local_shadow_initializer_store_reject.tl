;; A shadowing local's initializer still names the arena: storing arena data
;; there is an escape (#9593).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      [r : i64
        (begin
          (set! b.value (& r (deref x)))
          1)]
      unit)))

(define (main) : i64
  0)