(import stdlib.arena)
(import stdlib.string)
(import stdlib.test)

(define (release-other
  [other : (arena.Arena other) (:invalidate other)]
  [_phase : (& phase (arena.ArenaPhase owner generation))]
  [text : (in generation String)]) : i64
  (arena.destroy-safe! other)
  (string.string-length text))

(define (main) : i64
  (let
    [owner (arena.make)]
    [other (arena.make)]
    [base (in-arena owner (string.append "base" "-value"))]
    [phase (arena.phase owner)]
    [text (in-arena phase (string.append "phase" "-value"))]
    [length : i64 (release-other other (& phase) text)]
    (test.assert-true (= length 11) "unrelated owner does not end this phase")
    (arena.rewind-safe! phase)
    (test.assert-true
      (= (string.string-length base) 10)
      "base allocation survives the phase")
    (arena.destroy-safe! owner)
    42))