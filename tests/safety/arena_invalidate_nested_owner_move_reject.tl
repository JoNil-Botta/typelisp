(import stdlib.arena)
(import stdlib.string)

(defstruct InvalidateNestedState
  (:lifetimes owner)
  (arena (arena.Arena owner))
  (count i64))

(define (release [state : (InvalidateNestedState r) (:invalidate r)]) : unit
  (let
    [arena : (arena.Arena r) state.arena]
    unit))

(define (main) : i64
  42)