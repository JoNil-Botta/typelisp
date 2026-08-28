(import stdlib.arena)
(import stdlib.string)

(define (allocate-from-wrong-owner
  [source : (arena.Arena source)]
  [_target : (arena.Arena target)]) : (in target String)
  (in-arena source (string.append "wrong" "-owner")))

(define (main) : i64
  (allocate-from-wrong-owner (arena.make) (arena.make)))