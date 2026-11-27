(import field_opacity_model as model)

(defstruct Sample
  (v model.Reading))

(define (main) : i64
  (let
    [_items (__tl_make-array (Tuple Sample i64) 2)]
    0))