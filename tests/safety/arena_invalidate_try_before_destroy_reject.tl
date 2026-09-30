(import stdlib.arena)
(import stdlib.string)

(defenum InvalidateStep
  (Ok i64)
  (Err i64))

(define (step [ok : bool]) : InvalidateStep
  (if ok
    (InvalidateStep.Ok 1)
    (InvalidateStep.Err 7)))

(define (release [owner : (arena.Arena r) (:invalidate r)] [ok : bool]) : InvalidateStep
  (let
    [value : i64 (try (step ok))]
    (begin
      (arena.destroy-safe! owner)
      (InvalidateStep.Ok (+ value 41)))))

(define (main) : i64
  42)