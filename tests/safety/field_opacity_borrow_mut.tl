(import field_opacity_model as model)

(define (take [v : (&mut model.Reading)]) : (&mut i64)
  (unsafe
    (&mut v.scale)))

(define (main) : i64
  0)