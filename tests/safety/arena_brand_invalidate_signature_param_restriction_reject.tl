;; #9612: a temporary restriction (D-C124), restored by #9256 G2. A parameter
;; of the invalidating signature does not shadow the brand, which is bound
;; after the parameters, so a borrow of it carries the brand's lifetime and
;; cannot be held under a local's. The program is sound: it reads the alias
;; before the destroy.
(import stdlib.arena)

(define (f [owner : (arena.Arena r) (:invalidate r)] [r : i64]) : i64
  (let
    [k : i64 0]
    [alias : (& k i64) (& r)]
    [n : i64 (deref alias)]
    (arena.destroy-safe! owner)
    n))

(define (main) : i64
  (f (arena.make) 42))