;; Refs #9503: a parameter that names two invalidated brands keeps a region
;; after a whole-value shortening that drops one of them, so a read after
;; either end is rejected.
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