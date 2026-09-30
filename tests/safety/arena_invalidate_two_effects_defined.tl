(import stdlib.arena)
(import stdlib.string)

(define (release-both
  [a : (arena.Arena r) (:invalidate r)]
  [b : (arena.Arena s) (:invalidate s)]) : unit
  (begin
    (arena.destroy-safe! b)
    (arena.destroy-safe! a)))

(define (main) : i64
  (let
    [first (arena.make)]
    [second (arena.make)]
    [kept (arena.make)]
    [text (in-arena kept (string.append "kept" "-text"))]
    (begin
      (release-both first second)
      (let
        [length : i64 (string.string-length text)]
        (begin
          (arena.destroy-safe! kept)
          (+ length 33))))))