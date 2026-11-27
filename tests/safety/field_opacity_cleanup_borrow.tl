(import field_opacity_model as model)

(define (take [v : (&mut model.SavedReading)]) : (&mut i64)
  (&mut v.value))

(define (main) : i64
  0)