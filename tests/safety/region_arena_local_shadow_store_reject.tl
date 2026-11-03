;; A later local spelled like the arena does not let earlier arena data reach
;; caller storage (#9593).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      [r : i64 1]
      (set! b.value (& (deref x))))))

(define (main) : i64
  0)