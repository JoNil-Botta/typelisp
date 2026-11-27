(import field_opacity_model as model)

(defenum History
  (Current model.Reading)
  (Empty))

(define (main) : i64
  (let
    [_history (make-array History 1)]
    0))