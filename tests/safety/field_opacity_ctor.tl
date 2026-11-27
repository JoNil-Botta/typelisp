(import field_opacity_model as model)

(define (main) : i64
  (let
    [v
      (unsafe
        (model.Reading 1 2))]
    v.value))