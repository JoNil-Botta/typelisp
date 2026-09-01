(import stdlib.arena)

(defstruct BrandedDestroyParameterState
  (:lifetimes owner)
  (arena (arena.Arena owner)))

(define (destroy-input [state : (BrandedDestroyParameterState owner)]) : unit
  (arena.destroy-safe! state.arena))

(define (main) : i64
  42)