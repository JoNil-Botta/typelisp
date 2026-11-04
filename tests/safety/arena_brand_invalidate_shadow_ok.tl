;; #9612: a local or lambda parameter named like an invalidated brand shadows
;; it, so a borrow of that storage is not brand data and may be held under
;; another local's lifetime.
(import stdlib.arena)

(define (own-local [owner : (arena.Arena r) (:invalidate r)]) : i64
  (let
    [r : i64 20]
    [k : i64 0]
    [alias : (& k i64) (& r)]
    [n : i64 (deref alias)]
    (arena.destroy-safe! owner)
    n))

(define (lambda-param [owner : (arena.Arena r) (:invalidate r)]) : i64
  (let
    [n : i64
      ((lambda ([r : i64] [y : i64]) : i64
          (let
            [alias : (& y i64) (& r)]
            (deref alias)))
        22
        0)]
    (arena.destroy-safe! owner)
    n))

(define (main) : i64
  (+ (own-local (arena.make)) (lambda-param (arena.make))))