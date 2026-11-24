(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [p : (Tuple arena.Arena String)
      (with-scratch
        (tuple
          (let
            [a : arena.Arena (arena.current)]
            a)
          (string.int->string 42)))]
    (match p
      [(tuple dead _)
        (in-arena dead (string.string-length (string.int->string 99)))])))