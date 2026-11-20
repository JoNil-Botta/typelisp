;; A with cleanup `arena.rewind-safe!` ends the values allocated after its
;; phase at the scope exit: they cannot be its result.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [text
      (with
        ([p (arena.phase scratch) arena.rewind-safe!])
        (in-arena scratch (string.concat "ab" "cd")))]
    (string.string-length text)))