(import field_opacity_model as model)
(import stdlib.comptime)

(defmacro (scale-align [T : type]) : i64
  (comptime.expr-int (struct-field-declared-align (reference-element-type T) 1)))

(define (main) : i64
  (scale-align (& a model.Aligned)))