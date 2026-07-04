(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [frame-a : arena.Arena (arena.make)]
    [frame-b : arena.Arena (arena.make)]
    [phase-a : arena.ArenaPhase (arena.phase frame-a)]
    [previous : String (in-arena frame-a (string.append "frame" "-old"))]
    [current : String (in-arena frame-b (string.append "frame" "-current"))]
    [current-len : i64 (string.string-length current)]
    (begin
      (arena.rewind-safe! phase-a)
      (+ current-len (string.string-length previous)))))