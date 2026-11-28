;; An allocation made inside an `in-arena` over an arena with no region lands
;; in that arena, not the caller's: storing it into a global is accepted.
(import stdlib.arena)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)

(define names : svec.Vec
  (svec.new))

(define (record [n : i64]) : unit
  (let
    [facts : i64
      (unsafe
        (arena.tl_arena_make_small))]
    (in-arena
      (unsafe
        (arena.from-raw-handle facts))
      (svec.push-ref! (&mut names) (string.int->string n)))))

(define (main) : i64
  (with-arena phase (record 1234567))
  (if (= (svec.len (& names)) 1)
    42
    1))