;; Refs #9503: a reference shortened to a body-local lifetime keeps the brand it
;; stores (`tc-coercion-retain-invalidated-brands`), so it ends with the brand.
(import stdlib.arena)

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 5]
    (let
      [alias : (& k i64) x]
      (begin
        (arena.destroy-safe! owner)
        (deref alias)))))

(define (main) : i64
  0)
