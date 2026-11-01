;; A live thread handle holding the atomic arena's region must be joined
;; before the arena is destroyed.
(import stdlib.arena)
(import stdlib.string)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [text : String (in-arena owner (string.append "owned" "-text"))]
    [spawned : thread_i64.SpawnResult
      (thread_i64.spawn
        (lambda () : i64
          (string-length text)))]
    (begin
      (arena.destroy-safe! owner)
      0)))