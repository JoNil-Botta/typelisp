;; An enclosing `in-arena` that selects the caller's branded arena does not
;; stop a same-spelled `with-arena` from shadowing the caller lifetime: the
;; inner arena still resets before the caller reads `b.value` (#9593).
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [home : (arena.Arena r)] [b : (&mut r (RefBox r))]) : unit
  (in-arena
    home
    (with-arena
      r
      (let
        [x : (Box i64) (box 5)]
        ; Must fail: `x` lives in the inner arena, not in `home`.
        (set! b.value (& (deref x)))))))

(define (main) : i64
  0)