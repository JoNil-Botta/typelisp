(import stdlib.arena)
(import stdlib.string)

(defstruct PhaseBox
  (:lifetimes owner generation)
  (token (arena.ArenaPhase owner generation)))

(defenum PhaseChoice
  (:lifetimes owner generation)
  (Empty)
  (Live (Box (PhaseBox owner generation))))

(define (destroy-and-read
  [owner : (arena.Arena r) (:invalidate r)]
  [_stored : (PhaseChoice r g)]
  [text : (in g String)]) : i64
  (arena.destroy-safe! owner)
  (string.string-length text))

(define (main) : i64
  42)