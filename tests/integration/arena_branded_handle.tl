(import stdlib.arena as memory)

(defstruct BrandedArenaState
  (:lifetimes owner)
  (arena (memory.Arena owner))
  (answer i64))

(define (state-answer [state : (BrandedArenaState owner)]) : i64
  state.answer)

(define (branded-arena-observable? [owner : (memory.Arena owner)]) : bool
  (> (memory.raw-handle owner) 0))

(define (shadowed-make-copy-ok) : bool
  (let
    [make : (-> memory.Arena)
      (lambda () : memory.Arena
        (memory.current))]
    [legacy (make)]
    [_copy legacy]
    (= (memory.raw-handle legacy) (memory.raw-handle legacy))))

(define (main) : i64
  (let
    [helper-owner (memory.make)]
    [phase (memory.phase helper-owner)]
    [_raw (memory.raw-handle helper-owner)]
    [observable-owner (memory.make)]
    [observable : bool (branded-arena-observable? observable-owner)]
    [state-owner (memory.make)]
    [state (BrandedArenaState state-owner 42)]
    [answer : i64 (state-answer state)]
    (begin
      (memory.rewind-safe! phase)
      (memory.destroy-safe! helper-owner)
      (if (and observable (shadowed-make-copy-ok))
        answer
        1))))