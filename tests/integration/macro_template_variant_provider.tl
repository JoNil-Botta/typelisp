;; The `MacroTemplateShape.X` constructors in this macro's template name this
;; module's enum wherever the macro is used, including from a module that sees
;; the enum only through an import alias (macro_template_variant.tl).
(defenum MacroTemplateShape
  (Dot i64)
  (Pair i64 i64))

(defmacro (macro-template-shape-map [shape : Expr] [hook : Expr]) : Expr
  `(match ,shape
    [(MacroTemplateShape.Dot a) (MacroTemplateShape.Dot (,hook a))]
    [(MacroTemplateShape.Pair a b)
      (MacroTemplateShape.Pair (,hook a) (,hook b))]))

(define (macro-template-shape-sum [shape : MacroTemplateShape]) : i64
  (match shape
    [(Dot a) a]
    [(Pair a b) (+ a b)]))

(define (macro-template-shape-double [x : i64]) : i64
  (* x 2))

(define (main) : i64
  (macro-template-shape-sum
    (macro-template-shape-map
      (MacroTemplateShape.Pair 10 11)
      macro-template-shape-double)))