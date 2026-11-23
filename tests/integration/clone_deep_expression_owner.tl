(import stdlib.clone)

(defstruct HTTPItem
  (label String)
  (count i64))

(clone.gen-clone HTTPItem)