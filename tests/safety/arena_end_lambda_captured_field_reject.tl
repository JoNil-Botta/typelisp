;; #9482: a closure cannot end an arena it reaches through a captured place
;; (`state.inner.arena`) any more than a captured owner local.
(import stdlib.arena)
(import stdlib.string)

(defstruct Inner
  (:lifetimes owner)
  (arena (arena.Arena owner)))

(defstruct State
  (:lifetimes owner)
  (inner (Inner owner)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (in-arena owner (string.append "owned" "-text"))]
    [state (State (Inner owner))]
    (let
      [f
        (lambda () : i64
          (arena.destroy-safe! state.inner.arena)
          0)]
      (begin
        (f)
        (string.string-length (& text))))))