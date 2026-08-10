(import stdlib.arena)
(import stdlib.string)

(defstruct FrameCache
  (label String))

(define (main) : i64
  (let
    [frame : arena.Arena (arena.make)]
    [cache : FrameCache (FrameCache "empty")]
    (begin
      (set! cache.label (in-arena frame (string.append "stored" "-frame")))
      (string.string-length cache.label))))