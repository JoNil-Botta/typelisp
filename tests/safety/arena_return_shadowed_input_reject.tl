(import stdlib.arena)
(import stdlib.string)

(define (leak [owner : (arena.Arena source)]) : (in source String)
  (with-arena source (return (string.append "inner" ""))))

(define (main) : i64
  (let
    [owner (arena.make)]
    (string.string-length (leak owner))))
