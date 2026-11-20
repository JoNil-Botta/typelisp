;; The with exit ends its binder's arena: a destroy inside the scope would
;; destroy it twice.
(import stdlib.arena)

(define (main) : i64
  (with
    ([a (arena.make) arena.destroy-safe!])
    (begin
      (arena.destroy-safe! a)
      42)))