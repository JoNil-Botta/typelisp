;; Refs #9503: a closure capturing the shortened binding ends with the brand.
(import stdlib.arena)

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 5]
    (let
      [alias : (& k i64) x]
      [f
        (lambda () : i64
          (deref alias))]
      (begin
        (arena.destroy-safe! owner)
        (f)))))

(define (main) : i64
  0)