(import field_opacity_model as model)

(define (main) : i64
  (+
    (comptime (struct-field-count (type model.Aligned)))
    (comptime (struct-field-declared-align (type model.Aligned) 0))
    (comptime (offset-of (type model.Aligned) value))
    (comptime (size-of (type model.Aligned)))))