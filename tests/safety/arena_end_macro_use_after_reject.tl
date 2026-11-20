;; #9041: a macro expanding to `arena.destroy-safe!` is that call, decided from
;; the definition its head resolves to: the destroy invalidates `text`.
(import stdlib.arena)
(import stdlib.string)

(defmacro (kill [a : Expr]) : Expr
  `(arena.destroy-safe! ,a))

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [text (in-arena scratch (string.concat "ab" "cd"))]
    (begin
      (kill scratch)
      (string.string-length text))))