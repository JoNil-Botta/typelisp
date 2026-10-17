(import stdlib.arena)
(import stdlib.string)
(import stdlib.test)

(defstruct PhaseFloor
  (:lifetimes owner generation)
  (owner (arena.Arena owner))
  (phase (arena.ArenaPhase owner generation))
  (kept (in owner String))
  (text (in generation String)))

(define (refresh [floor : (PhaseFloor owner generation)]) : (PhaseFloor
    owner
    generation)
  (let
    [expected : i64 (arena.raw-handle floor.owner)]
    [actual : i64
      (in-arena
        floor.phase
        (let
          [current (arena.current)]
          current.handle))]
    (test.assert-true (= expected actual) "phase uses its embedded arena")
    (set! floor.text (in-arena floor.phase (string.append "field" "-routed")))
    floor))

(define (main) : i64
  (let
    [home : i64 (arena.raw-handle (arena.current))]
    [owner (arena.make)]
    [kept (in-arena owner (string.append "before" "-phase"))]
    [phase (arena.phase owner)]
    [text (in-arena phase (string.append "local" "-routed"))]
    [floor (refresh (PhaseFloor owner phase kept text))]
    [first-length : i64 (string.string-length floor.text)]
    [restored-owner floor.owner]
    [restored-kept floor.kept]
    (arena.rewind-safe! floor.phase)
    (let
      [base (in-arena restored-owner (string.append "base" "-again"))]
      [next-phase (arena.phase restored-owner)]
      [next-text (in-arena next-phase (string.append "next" "-generation"))]
      [next (PhaseFloor restored-owner next-phase restored-kept next-text)]
      [next-length : i64 (string.string-length next.text)]
      [final-owner next.owner]
      [final-kept next.kept]
      (arena.rewind-safe! next.phase)
      (test.assert-true (= first-length 12) "parameter field allocation")
      (test.assert-true (= next-length 15) "new stored generation")
      (test.assert-true
        (= (string.string-length final-kept) 12)
        "pre-phase value survives both rewinds")
      (test.assert-true
        (= (string.string-length base) 10)
        "base value survives next rewind")
      (test.assert-true
        (= home (arena.raw-handle (arena.current)))
        "allocation target restored")
      (arena.destroy-safe! final-owner)
      42)))