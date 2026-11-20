;; #8173: a closure returned through a bare `arena.Arena` parameter keeps the
;; owner's brand, so the end of the owner reaches the closure.
(import stdlib.arena)
(import stdlib.string)

(define (later [a : arena.Arena]) : (-> i64)
  (lambda () : i64
    (string.string-length (in-arena a (string.concat "a" "b")))))

(define (main) : i64
  (let
    [s (arena.make)]
    [f (later s)]
    (begin
      (arena.destroy-safe! s)
      (f))))