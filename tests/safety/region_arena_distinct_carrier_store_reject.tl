;; A local carrier of the colliding with-arena region named unlike it cannot
;; carry arena data out to caller storage (#9593).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      [local : (& r i64) (& r (deref x))]
      ; Must fail: `local` borrows the arena, which resets before the caller
      ; reads `b.value`.
      (set! b.value local))))

(define (main) : i64
  0)