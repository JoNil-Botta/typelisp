;; Inside an `in-arena` over an arena with no region, a value allocated before
;; it is still the caller's allocation: storing it into a global is rejected.
(import stdlib.arena)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define facts-arena : i64
  0)
(define names : svec.Vec
  (svec.new))

(define (add-fact) : unit
  (let
    [name : String (string.int->string 1234567)]
    (in-arena
      (unsafe
        (arena.from-raw-handle facts-arena))
      (svec.push-ref! (&mut names) name))))

(define (main) : i64
  (with-arena phase (add-fact))
  (svec.len (& names)))