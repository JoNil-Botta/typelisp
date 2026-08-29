(import stdlib.arena)
(import stdlib.string)

(defstruct BrandedTextSlot
  (:lifetimes owner)
  (text (in owner String)))

(define (main) : i64
  (let
    [left-owner (arena.make)]
    [left-text (in-arena left-owner (string.append "left" "-owned"))]
    [right-owner (arena.make)]
    [right-text (in-arena right-owner (string.append "right" "-owned"))]
    [slot (BrandedTextSlot right-text)]
    (begin
      (set! slot.text left-text)
      0)))