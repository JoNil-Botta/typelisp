(import stdlib.arena)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)
(import "stdlib/string.tl")

(define (atomic-arena-join-code [worker : thread_i64.Handle]) : i64
  (match (thread_i64.join worker)
    [(thread_i64.I64JoinOk value) value]
    [(thread_i64.I64JoinErr _) -1]))

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [kept : String (in-arena owner (append "kept" "-value"))]
    [phase : arena.ArenaPhase (arena.phase owner)]
    [temp : String (in-arena owner (append "temp" "-value"))]
    [temp-len : i64 (string-length temp)]
    (match (thread_i64.spawn
      (lambda () : i64
        (+ temp-len (string-length kept))))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk worker)
        (let
          [joined : i64 (atomic-arena-join-code worker)]
          (begin
            (arena.rewind-safe! phase)
            (arena.destroy-safe! owner)
            (if (= joined 20)
              42
              2)))])))