;; #9537: an argument tied to the arena an `:invalidate` call ends cannot pass
;; under a formal lifetime of its own, which outlives the call.
(import stdlib.arena)

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& a i64)]) : i64
  (begin
    (arena.destroy-safe! owner)
    (deref x)))

(define (main) : i64
  (let
    [seed : i64 7]
    [o (arena.make)]
    [b (in-arena o (box seed))]
    (exercise o (& (deref b)))))