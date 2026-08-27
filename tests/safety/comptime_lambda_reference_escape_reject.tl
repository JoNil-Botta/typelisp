(import stdlib.comptime)
(import stdlib.string)

(defmacro (make-scoped-reader [value : Expr]) : Expr
  (let
    [name : String (comptime.syntax-name-fresh "scoped-value")]
    [captured : Expr (comptime.expr-var name)]
    [body : Expr
      `(lambda () : i64
        (string-length ,captured))]
    (comptime.expr-shared-let-scope name value body)))

;; The closure cannot outlive the macro-generated shared binding.
(define (bad [owner : String]) : (-> i64)
  (make-scoped-reader owner))

(define (main) : i64
  0)