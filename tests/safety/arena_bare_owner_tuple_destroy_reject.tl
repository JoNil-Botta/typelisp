;; Storing a bare-annotated owner in a tuple moves the owner (#8172).
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [pair : (Tuple arena.Arena i64) (tuple owner 1)]
    (begin
      (arena.destroy-safe! owner)
      (string.string-length
        (in-arena (tuple-ref pair 0) (string.concat "a" "b"))))))