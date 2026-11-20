;; A with exit destroying an `(:invalidate r)` parameter discharges it.
(import stdlib.arena)

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (with ([a owner arena.destroy-safe!]) unit))

(define (main) : i64
  (let
    [o (arena.make)]
    (begin
      (release o)
      42)))