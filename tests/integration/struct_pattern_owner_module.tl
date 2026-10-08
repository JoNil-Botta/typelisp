;; struct_pattern_owner_module.tl - Regression for #8727.
(import struct_pattern_owner_shapes as shapes)
(import struct_pattern_owner_user as user)

(define (main) : i64
  (let
    [line : shapes.Line
      (shapes.Line (shapes.Point 30) (shapes.Kind.Dashed 2) 10)]
    [seg : shapes.Shape
      (shapes.Shape.Seg
        (box (shapes.Line (shapes.Point 4) shapes.Kind.Solid 0)))]
    (+
      (user.line-score line)
      (- (user.line-start-x line) 30)
      (- (user.shape-score seg) 4)
      (- 9 (user.shape-score (shapes.Shape.Dot (shapes.Point 9)))))))