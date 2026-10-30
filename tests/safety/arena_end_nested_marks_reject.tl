;; Refs #9502 Refs #9493. An enclosing activation stays live below marks/other activations.
(import stdlib.arena)
(import stdlib.string)

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

(define (exercise [owner : (arena.Arena r) (:invalidate r)]) : i64
  (in-arena
    owner
    (with-arena
      s
      (with-arena
        t
        (begin
          (arena.destroy-safe! owner)
          42)))))

(define (main) : i64
  (let
    [owner (arena.make)]
    (exercise owner)))