(import stdlib.arena)
(import stdlib.string)

(define (release-with
  [owner : (arena.Arena r) (:invalidate r)]
  [text : (& s str)]) : (& s str)
  (begin
    (arena.destroy-safe! owner)
    text))

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (in-arena owner (string.append "owned" "-text"))]
    [view (release-with owner (& text))]
    (string.string-length view)))