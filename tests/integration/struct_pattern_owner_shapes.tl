;; struct_pattern_owner_shapes.tl - Declarations for struct_pattern_owner_module.tl.
(defenum Kind
  (Solid)
  (Dashed i64))

(defstruct Point
  (x i64))

(defstruct Line
  (start Point)
  (kind Kind)
  (len i64))

(defenum Shape
  (Seg (Box Line))
  (Dot Point))