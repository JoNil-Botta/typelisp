(defstruct Point
  (x i64)
  (y i64))

(defstruct Segment
  (from Point)
  (to Point))

(defstruct CPoint
  (:repr c)
  (tag u8)
  (y i64))

(defenum Shape
  (Dot)
  (Box Point))