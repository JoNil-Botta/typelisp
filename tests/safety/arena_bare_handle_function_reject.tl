;; #8173: a closure returned through a bare `arena.Arena` parameter could keep
;; a branded owner's handle, and a function result cannot carry the owner's
;; brand, so the call is rejected.
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