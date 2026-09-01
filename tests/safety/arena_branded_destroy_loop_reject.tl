(import stdlib.arena)

(defstruct BrandedDestroyLoopOwner
  (:lifetimes owner)
  (arena (arena.Arena owner)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [state (BrandedDestroyLoopOwner owner)]
    [done : bool false]
    (begin
      (while (not done)
        (begin
          (arena.destroy-safe! state.arena)
          (set! done true)))
      42)))