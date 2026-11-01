;; Refs #9503: a reference parameter that names an `:invalidate` brand carries
;; that arena's region, so a binding shortened to a body-local lifetime still
;; ends with the brand: reading it after the destroy is rejected.
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