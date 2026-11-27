(import field_opacity_model as model)

(define (change [v : (&mut model.Reading)]) : unit
  (unsafe
    (set! v.scale 2)))

(define (main) : i64
  0)