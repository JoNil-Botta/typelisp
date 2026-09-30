(import stdlib.arena)
(import stdlib.string)

(defenum InvalidateChoice
  (Now)
  (Later))

(define (release
  [owner : (arena.Arena r) (:invalidate r)]
  [choice : InvalidateChoice]) : unit
  (match choice
    [(InvalidateChoice.Now) (arena.destroy-safe! owner)]
    [(InvalidateChoice.Later) unit]))

(define (main) : i64
  42)