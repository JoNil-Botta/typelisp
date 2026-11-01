;; These names collide with smaller structs in both importing fixtures.
(defstruct Pair
  (marker bool)
  (left i64)
  (right i64))

(defstruct Small
  (before i64)
  (value i64)
  (after i64))

(defstruct Label
  (before i64)
  (text String)
  (extra i64))

(defstruct Holder
  (before i64)
  (pair Pair)
  (after i64))

(defenum Item
  (PairItem Pair)
  (LabelItem Label))

(defenum Scalar
  (SmallItem Small)
  (Empty))