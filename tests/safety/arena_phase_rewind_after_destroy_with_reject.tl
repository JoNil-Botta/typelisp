;; #9788: a `with` phase token ended by its owner's destroy cannot be rewound
;; by the scope's cleanup.
(import stdlib.arena)

(define (main) : i64
  (let
    [s (arena.make)]
    (with
      ([p (arena.phase s) arena.rewind-safe!])
      (begin
        (arena.destroy-safe! s)
        42))))