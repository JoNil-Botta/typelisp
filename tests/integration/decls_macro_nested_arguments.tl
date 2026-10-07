;; decls_macro_nested_arguments.tl - declaration macros with deeply nested
;; argument syntax (#8675).
;;
;; A declaration macro's call is keyed by its argument syntax. That key used to
;; grow about four times per nesting level, so an argument nested eight calls
;; deep overflowed the compiler's stack after several GB. The arguments below
;; nest well past that; the generated functions must return 12 and 30.
(import stdlib.comptime)

(define (inc [x : i64]) : i64
  (+ x 1))

;; An `Expr` operand twelve calls deep, spliced into the generated body.
(defmacro (gen-from-expr [name : Expr] [body : Expr]) : Decls
  `(begin
    (define (,name) : i64
      ,body)))

(gen-from-expr
  twelve
  (inc (inc (inc (inc (inc (inc (inc (inc (inc (inc (inc (inc 0)))))))))))))

;; Binding clauses whose initializers nest six calls deep, the shape of a
;; field-schema declaration macro.
(defmacro (gen-sum [name : Expr] [parts : ExprBindingClause ...]) : Decls
  (let
    [count : i64 (comptime.expr-binding-clause-list-length parts)]
    [index : i64 0]
    [sum : Expr `0]
    (while (< index count)
      (set!
        sum
        `(+
          ,sum
          ,(comptime.expr-binding-clause-init
            (comptime.expr-binding-clause-list-nth parts index))))
      (set! index (+ index 1)))
    `(begin
      (define (,name) : i64
        ,sum))))

(gen-sum
  thirty
  [a : i64 (inc (inc (inc (inc (inc (inc 0))))))]
  [b : i64 (inc (inc (inc (inc (inc (inc 0))))))]
  [c : i64 (inc (inc (inc (inc (inc (inc 0))))))]
  [d : i64 (inc (inc (inc (inc (inc (inc 0))))))]
  [e : i64 (inc (inc (inc (inc (inc (inc 0))))))])

(define (main) : i64
  (+ (twelve) (thirty)))