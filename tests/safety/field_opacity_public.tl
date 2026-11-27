(import field_opacity_model as model)

(define (pass [v : model.Reading]) : model.Reading
  v)

(define (read-value [v : model.Reading]) : i64
  v.value)

(define (main) : i64
  (let
    [items (array (pass (model.reading 24)))]
    [v (array-ref items 0)]
    (set! v.value (+ v.value 2))
    (+ (read-value v) (comptime (size-of (type model.Reading))))))