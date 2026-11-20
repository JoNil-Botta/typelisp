;; A with cleanup `arena.rewind-safe!` rewinds to its phase at the scope exit.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [n : i64
      (with
        ([p (arena.phase scratch) arena.rewind-safe!])
        (string.string-length (in-arena scratch (string.concat "ab" "cd"))))]
    (+ 38 n)))