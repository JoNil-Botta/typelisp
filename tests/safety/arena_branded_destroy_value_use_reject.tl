(import stdlib.arena)
(import stdlib.string)

(defstruct BrandedDestroyOwner
  (:lifetimes owner)
  (arena (arena.Arena owner)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (in-arena owner (string.append "owned" "-text"))]
    [state (BrandedDestroyOwner owner)]
    (begin
      (arena.destroy-safe! state.arena)
      (string.string-length text))))