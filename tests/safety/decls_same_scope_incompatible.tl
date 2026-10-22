(import stdlib.comptime)

(defmacro (emit [value : comptime.Expr]) : Decls
  (match value
    [(comptime.Expr.Int _)
      `(define answer : i64
        1)]
    [_
      `(define answer : i64
        2)]))

(emit 3)

(emit (+ 1 2))

(define (main) : i64
  answer)