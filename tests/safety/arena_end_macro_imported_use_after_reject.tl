;; #9041: an imported macro's `arena.destroy-safe!` is the same callee.
(import stdlib.arena)
(import stdlib.string)
(import arena_end_macro_dep as dep)

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [text (in-arena scratch (string.concat "ab" "cd"))]
    (begin
      (dep.kill scratch)
      (string.string-length text))))