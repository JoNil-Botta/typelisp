(import stdlib.arena)
(import stdlib.string)

(defstruct PlainTextState
  (:lifetimes owner)
  (arena (arena.Arena owner))
  (text String))

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (in-arena owner (string.append "region" "-owned"))]
    [_state (PlainTextState owner text)]
    0))