(import stdlib.arena)
(import stdlib.string)

(defstruct BrandedTextState
  (:lifetimes owner)
  (arena (arena.Arena owner))
  (text (in owner String)))

(define (main) : i64
  (let
    [left-owner (arena.make)]
    [left-text (in-arena left-owner (string.append "left" "-owned"))]
    [right-owner (arena.make)]
    [_state (BrandedTextState right-owner left-text)]
    0))