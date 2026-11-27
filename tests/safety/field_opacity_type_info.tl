(import field_opacity_model as model)
(import stdlib.comptime)

(defmacro (inspect [T : type]) : i64
  (match (type-info T)
    [(comptime.TypeInfo.Struct _ fields)
      (let
        [_field (array-ref fields.items 1)]
        (comptime.expr-int 1))]
    [_ (comptime.expr-int 0)]))

(define (main) : i64
  (inspect model.Reading))