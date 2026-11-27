(import field_opacity_model as model)

(define (main) : i64
  (length (make-array i64 (comptime (offset-of (type model.Aligned) scale)))))