(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [frame : arena.Arena (arena.make)]
    [label : String (in-arena frame (string.append "captured" "-frame"))]
    [read : (-> i64)
      (lambda () : i64
        (string.string-length label))]
    (read)))