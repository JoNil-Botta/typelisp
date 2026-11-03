;; Behind a lambda whose same-named parameters mix a non-carrier and a carrier,
;; arena data passed through the carrier and returned still cannot reach
;; caller storage (#9593).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      [f
        (lambda ([r : i64] [r : (& r i64)]) : (& r i64)
          r)]
      ; Must fail: the arena `r` resets before the caller reads `b.value`.
      (set! b.value (f 1 (& r (deref x)))))))

(define (main) : i64
  0)