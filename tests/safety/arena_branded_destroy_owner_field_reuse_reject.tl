(import stdlib.arena)

(defstruct BrandedDestroyOwnerState
  (:lifetimes owner)
  (arena (arena.Arena owner))
  (answer i64))

(define (main) : i64
  (let
    [owner (arena.make)]
    [state (BrandedDestroyOwnerState owner 42)]
    (begin
      (arena.destroy-safe! state.arena)
      (arena.raw-handle state.arena))))