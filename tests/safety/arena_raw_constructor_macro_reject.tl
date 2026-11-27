(import stdlib.arena)

(defmacro (forge [handle : Expr]) : Expr
  `(arena.Arena ,handle))

(define (main) : i64
  (arena.raw-handle (forge 0)))