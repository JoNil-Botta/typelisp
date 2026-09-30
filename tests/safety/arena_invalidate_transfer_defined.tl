(import stdlib.arena)
(import stdlib.string)

(define (pass [owner : (arena.Arena r)]) : (arena.Arena r)
  owner)

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (in-arena owner (string.append "owned" "-text"))]
    [moved (pass owner)]
    [length : i64 (string.string-length text)]
    (begin
      (arena.destroy-safe! moved)
      (+ length 32))))