(module field_opacity_model.detail)

(import field_opacity_model as model)

(define (main) : i64
  (let
    [v : model.Reading (model.Reading 24 1)]
    (set! v.scale 2)
    (match v
      [(model.Reading value scale)
        (+ value scale (comptime (offset-of (type model.Aligned) scale)) 8)])))