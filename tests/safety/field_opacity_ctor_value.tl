(import field_opacity_model as model)

(define (main) : i64
  (let
    [make : (-> i64 i64 model.Reading) model.Reading]
    (make 1 2).value))