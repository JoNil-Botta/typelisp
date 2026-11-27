(import field_opacity_model as model)

(define (main) : i64
  (match (model.reading 1)
    [(model.Reading value _) value]))