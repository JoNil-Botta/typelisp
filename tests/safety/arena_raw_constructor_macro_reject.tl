(import stdlib.arena)

(defmacro (forge [handle : Expr]) : Expr
  `(arena.Arena ,handle))

(define (main) : i64
  (forge 12345).handle)