;; Implicit-cleanup arena escape: `with` cleanup inside `in-arena` with an
;; active phase stores an allocation into a global before `arena.rewind-safe!`.
(import stdlib.arena)
(import stdlib.string)

(define g : String
  "init")

(define (leak [_x : i64]) : unit
  (set! g (string.append "hello" "world")))

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    (in-arena owner (with ([x 1 leak]) 0))
    (arena.rewind-safe! p)
    (if (string.eq (& g) "helloworld")
      42
      7)))