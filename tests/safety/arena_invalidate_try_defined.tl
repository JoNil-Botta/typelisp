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
  (begin
    (arena.destroy-safe! owner)
    (let
      [value : i64 (try (step ok))]
      (InvalidateStep.Ok (+ value 41)))))

(define (main) : i64
  (let
    [owner (arena.make)]
    (match (release owner true)
      [(InvalidateStep.Ok value) value]
      [(InvalidateStep.Err code) code])))