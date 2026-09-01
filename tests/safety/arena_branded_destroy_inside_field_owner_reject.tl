(import stdlib.arena)

(defstruct BrandedDestroyInsideOwner
  (:lifetimes owner)
  (arena (arena.Arena owner)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [state (BrandedDestroyInsideOwner owner)]
    (in-arena state.arena (arena.destroy-safe! state.arena))))