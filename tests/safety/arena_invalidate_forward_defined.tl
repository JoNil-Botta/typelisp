(import stdlib.arena)
(import stdlib.string)

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

(define (forward [owner : (arena.Arena s) (:invalidate s)]) : unit
  (release owner))

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (in-arena owner (string.append "owned" "-text"))]
    [length : i64 (string.string-length text)]
    (begin
      (forward owner)
      (+ length 32))))