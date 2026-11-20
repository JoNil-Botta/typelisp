;; #9490: passed as an argument, `arena.destroy-safe!` is a value too.
(import stdlib.arena)
(import stdlib.string)

(define (apply1 [f : (-> arena.Arena unit)] [a : arena.Arena]) : unit
  (f a))

(define (main) : i64
  (let
    [o (arena.make)]
    [text (in-arena o (string.concat "ab" "cd"))]
    (begin
      (apply1 arena.destroy-safe! o)
      (string.string-length text))))