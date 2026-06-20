(module struct.match.geom)

(defstruct QPoint
  (x i64)
  (y i64))

(export (type QPoint) (constructor QPoint) (field QPoint x) (field QPoint y))