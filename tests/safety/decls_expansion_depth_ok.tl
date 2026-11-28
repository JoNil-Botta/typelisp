(import stdlib.comptime)

(defmacro (emit [depth : comptime.Expr] [name : comptime.Expr]) : Decls
  (match depth
    [(comptime.Expr.Int 0)
      `(define (,name) : i64
        21)]
    [(comptime.Expr.Int n)
      (let
        [next : comptime.Expr (comptime.expr-int (- n 1))]
        `(emit ,next ,name))]
    [_ (comptime.comptime-error "expected an integer depth")]))

;; Each sibling reaches the permitted depth of 512, including this splice.
(defmacro (branch) : Decls
  `(begin
    (emit 511 left)
    (emit 511 right)))

(branch)

;; A later invocation deduplicates the finished splice.
(branch)

(define (main) : i64
  (+ (left) (right)))