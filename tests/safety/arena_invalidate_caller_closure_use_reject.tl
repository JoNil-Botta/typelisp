(import stdlib.arena)
(import stdlib.string)

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

(define (main) : i64
  (let
    [owner (arena.make-atomic)]
    [text (in-arena owner (string.append "owned" "-text"))]
    [read-text : (-> i64)
      (lambda () : i64
        (string.string-length text))]
    (begin
      (release owner)
      (read-text))))