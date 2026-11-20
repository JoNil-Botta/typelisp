;; A with cleanup may end an owner moved into it; a scalar read from its
;; values inside the scope is valid.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [o (arena.make)]
    [n : i64
      (with
        ([a o arena.destroy-safe!])
        (string.string-length (in-arena a (string.concat "ab" "cd"))))]
    (+ 38 n)))