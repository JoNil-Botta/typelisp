(import stdlib.comptime)

(defmacro (loop-body [condition : Expr] [body : Expr]) : Expr
  (comptime.expr-while condition body))

(defmacro (loop-forms [condition : Expr] [body : Expr ...]) : Expr
  `(while ,condition
    ,@body))

(defmacro (emit-loop) : Decls
  '(define (generated-loop) : i64
    (let
      [i : i64 0]
      (while (< i 3)
        (begin
          i
          unit)
        (set! i (+ i 1)))
      i)))

(emit-loop)

(define (main) : i64
  (let
    [running : bool true]
    [total : i64 0]
    (while running
      (begin
        (+ total 1)
        unit)
      (set! total (+ total 10))
      (set! running false))
    (set! running true)
    (loop-body
      running
      (begin
        (+ total 1)
        (set! total (+ total 20))
        (set! running false)))
    (set! running true)
    (loop-forms
      running
      (begin
        (begin
          99
          unit)
        unit)
      (set! total (+ total 6))
      (set! running false))
    (+
      total
      (generated-loop)
      (comptime
        (let
          [i : i64 0]
          (while (< i 3)
            (set! i (+ i 1))
            unit)
          i)))))