;; A colliding `with-arena` inside an SPMD `foreach` still names the arena:
;; its data cannot reach the caller's struct (#9593).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (foreach
    ([i : i64 0 1])
    (with-arena
      r
      (let
        [x : (Box i64) (box 5)]
        ; Must fail: the arena `r` resets before the caller reads `b.value`.
        (set! b.value (& (deref x)))))))

(define (main) : i64
  0)