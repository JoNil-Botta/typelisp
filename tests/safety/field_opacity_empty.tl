(import field_opacity_model as model)

(defenum History
  (Empty)
  (Previous model.Reading))

(define (main) : i64
  (let
    [fixed (make-array model.Reading 0)]
    [nested (make-array (Array model.Reading 0) 2)]
    [dynamic (__tl_make-array model.Reading 0)]
    [history (make-array History 1)]
    (+ (length fixed) (length nested) (length dynamic) (length history))))