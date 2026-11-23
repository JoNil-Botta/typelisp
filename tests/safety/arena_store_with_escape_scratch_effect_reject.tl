;; Implicit-cleanup arena escape: `with-escape`'s scratch operand evaluates
;; in the enclosing arena, so effect scanning must visit it rather than treat
;; its expression ID as a bound name.
(import stdlib.arena)
(import stdlib.string)

(define g : String
  "init")

(define (pick-scratch [s : arena.Arena]) : arena.Arena
  (set! g (string.append "hello" "world"))
  s)

(define (run [s : arena.Arena]) : i64
  (with-escape (pick-scratch s) 1))

(define (main) : i64
  (let
    [s (arena.make)]
    (with-arena r (run s))
    (arena.destroy-safe! s)
    (if (string.eq (& g) "helloworld")
      42
      7)))