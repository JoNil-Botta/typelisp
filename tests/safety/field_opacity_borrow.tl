(import field_opacity_model as model)

(define (take [v : (& model.Reading)]) : (& i64)
  (& v.scale))

(define (main) : i64
  0)