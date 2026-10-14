(import stdlib.arena)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    (begin
      (set! owner.handle 12345)
      owner.handle)))