(import stdlib.arena)
(import stdlib.string)
(import stdlib.test)
(import stdlib.comptime)

(defmacro (phase-param-keys-code [f : type]) : i64
  (let
    [first : String (type-key (function-param-type f 0))]
    [second : String (type-key (function-param-type f 1))]
    (comptime.expr-int
      (if (string.eq first second)
        1
        42))))

(defstruct ArenaView
  (handle i64))

(define (read-context [state : (MutPtr ArenaView)]) : i64
  (unsafe
    (in-arena (arena.Arena (deref state).handle) 42)))

(define (release-other
  [other : (arena.Arena other) (:invalidate other)]
  [_phase : (& phase (arena.ArenaPhase owner generation))]
  [text : (in generation String)]) : i64
  (arena.destroy-safe! other)
  (string.string-length text))

(defstruct PhaseInput
  (:lifetimes owner generation)
  (owner (arena.Arena owner))
  (phase (arena.ArenaPhase owner generation))
  (text (in generation String)))

(define (allocate [owner : (arena.Arena r)] [phase : (arena.ArenaPhase r g)]) : (PhaseInput
    r
    g)
  (let
    [text (in-arena phase (string.append "routed" "-helper"))]
    (PhaseInput owner phase text)))

(define (main) : i64
  (let
    [view (ArenaView (arena.raw-handle (arena.current)))]
    [context : i64
      (unsafe
        (read-context (ptr-addr-of view)))]
    [owner (arena.make)]
    [other (arena.make)]
    [base (in-arena owner (string.append "base" "-value"))]
    [phase (arena.phase owner)]
    [text (in-arena phase (string.append "phase" "-value"))]
    [routed (allocate owner phase)]
    [restored-owner routed.owner]
    [restored-phase routed.phase]
    [length : i64 (release-other other (& restored-phase) text)]
    (test.assert-true
      (=
        (phase-param-keys-code
          (type (-> (arena.ArenaPhase r g) (arena.ArenaPhase r h) unit)))
        42)
      "reflection retains distinct generation arguments")
    (test.assert-true
      (= context 42)
      "unsafe target retains its checked type fact")
    (test.assert-true (= length 11) "unrelated owner does not end this phase")
    (test.assert-true
      (= (string.string-length routed.text) 13)
      "phase-aware helper allocates through the generation")
    (arena.rewind-safe! restored-phase)
    (test.assert-true
      (= (string.string-length base) 10)
      "base allocation survives the phase")
    (arena.destroy-safe! restored-owner)
    42))