(import stdlib.comptime)

(defmacro (answer [input : Expr]) : i64
  (let
    [total : i64 0]
    (when
      (or true (comptime.comptime-error "or evaluated its right operand"))
      (set! total (+ total 10))
      (set! total (+ total 20)))
    (unless
      (and false (comptime.comptime-error "and evaluated its right operand"))
      (set! total (+ total 10)))
    (cond
      [(= total 40)
        (let
          [total : i64 (+ total 2)]
          (match input
            [(comptime.Expr.Int 1) (comptime.expr-int total)]
            [_ (comptime.expr-int 1)]))]
      [else (comptime.expr-int 2)])))

(define (main) : i64
  (answer 1))