(import field_opacity_model as model)

(define (visible [v : (& model.Reading)]) : i64
  (unsafe
    (match v
      [(fields value) value])))

(define (main) : i64
  0)