(import stdlib.arena)

(defstruct BrandedDestroyBranchOwner
  (:lifetimes owner)
  (arena (arena.Arena owner)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [state (BrandedDestroyBranchOwner owner)]
    (begin
      (if true
        (arena.destroy-safe! state.arena)
        unit)
      (arena.destroy-safe! state.arena)
      42)))