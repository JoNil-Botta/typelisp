(import stdlib.comptime)

(defmacro (comptime-require-string-literal [value : comptime.Expr]) : String
  (comptime.expr-string (comptime.expr-string-value value)))

(define (main) : i64
  (let
    [value : String "not a literal expression"]
    (begin
      (comptime-require-string-literal value)
      42)))
