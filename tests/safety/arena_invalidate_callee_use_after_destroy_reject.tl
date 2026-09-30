(import stdlib.arena)
(import stdlib.string)

(define (release
  [owner : (arena.Arena r) (:invalidate r)]
  [text : (in r String)]) : i64
  (begin
    (arena.destroy-safe! owner)
    (string.string-length text)))

(define (main) : i64
  42)