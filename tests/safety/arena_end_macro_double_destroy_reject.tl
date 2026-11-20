;; #9041: a macro-expanded destroy consumes its owner like a direct one.
(import stdlib.arena)

(defmacro (kill [a : Expr]) : Expr
  `(arena.destroy-safe! ,a))

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    (begin
      (kill scratch)
      (kill scratch)
      42)))