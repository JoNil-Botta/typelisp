(import stdlib.arena)
(import stdlib.string)

(define (make-reader [owner : (arena.Arena owner)]) : (-> i64)
  (let
    [text (in-arena owner (string.append "captured" "-owner"))]
    (lambda () : i64
      (string.string-length text))))

(define (main) : i64
  ((make-reader (arena.make))))