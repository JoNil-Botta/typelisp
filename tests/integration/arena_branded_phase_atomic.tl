(import stdlib.arena)
(import stdlib.string)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)

(define (main) : i64
  (let
    [owner (arena.make-atomic)]
    [kept (in-arena owner (string.append "pre" "-phase"))]
    [phase (arena.phase owner)]
    [text (in-arena phase (string.append "atomic" "-phase"))]
    (match (thread_i64.spawn
      (lambda () : i64
        (string.string-length text)))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk worker)
        (match (thread_i64.join worker)
          [(thread_i64.I64JoinErr _) 2]
          [(thread_i64.I64JoinOk length)
            (arena.rewind-safe! phase)
            (let
              [post (in-arena owner (string.append "base" "-after-join"))]
              [answer : i64
                (+
                  length
                  (+ (string.string-length kept) (string.string-length post)))]
              (arena.destroy-safe! owner)
              (+ answer 6))])])))