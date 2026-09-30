(import stdlib.arena)
(import stdlib.string)

(defstruct InvalidateCallerState
  (:lifetimes owner)
  (arena (arena.Arena owner))
  (answer i64))

(define (release-state [state : (InvalidateCallerState r) (:invalidate r)]) : unit
  (arena.destroy-safe! state.arena))

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (in-arena owner (string.append "owned" "-text"))]
    [state (InvalidateCallerState owner 42)]
    (begin
      (release-state state)
      (string.string-length text))))