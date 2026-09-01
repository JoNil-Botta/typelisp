(import stdlib.arena)
(import stdlib.string)

(defstruct BrandedDestroyBorrowOwner
  (:lifetimes owner)
  (arena (arena.Arena owner)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (in-arena owner (string.append "owned" "-text"))]
    [view (& text)]
    [state (BrandedDestroyBorrowOwner owner)]
    (begin
      (arena.destroy-safe! state.arena)
      (string.string-length view))))