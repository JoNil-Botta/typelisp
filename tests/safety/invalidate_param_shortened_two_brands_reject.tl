;; Refs #9503: shortening one of two stored brands keeps the dropped one, so
;; its end invalidates the binding even though the other brand is still live.
(import stdlib.arena)

(defstruct Pair2
  (:lifetimes a b)
  (p (& a i64))
  (q (& b i64)))

(define (exercise
  [o1 : (arena.Arena r) (:invalidate r)]
  [o2 : (arena.Arena s) (:invalidate s)]
  [x : (Pair2 r s)]) : i64
  (let
    [k : i64 5]
    (let
      [w : (Pair2 r k) x]
      (begin
        (arena.destroy-safe! o2)
        (let
          [v : i64 (deref w.q)]
          (begin
            (arena.destroy-safe! o1)
            v))))))

(define (main) : i64
  0)
