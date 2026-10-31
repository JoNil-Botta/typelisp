;; Refs #9503: a binding shortened twice still ends with the brand.
(import stdlib.arena)

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 5]
    (let
      [alias : (& k i64) x]
      (let
        [m : i64 6]
        (let
          [alias2 : (& m i64) alias]
          (begin
            (arena.destroy-safe! owner)
            (deref alias2)))))))

(define (main) : i64
  0)