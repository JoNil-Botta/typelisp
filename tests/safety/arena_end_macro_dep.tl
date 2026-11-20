;; The imported macro of `arena_end_macro_imported_use_after_reject`.
(import stdlib.arena)

(defmacro (kill [a : Expr]) : Expr
  `(arena.destroy-safe! ,a))