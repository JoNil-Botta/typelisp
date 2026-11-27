(import stdlib.eq)
(import stdlib.set)
(import (eq.eq (Tuple i64 i64)) as tuple_eq)
(import (set.set (Tuple i64 i64)) as tuple_set)

(define (main) : i64
  (let
    [keys : tuple_set.Set (tuple_set.new)]
    [key : (Tuple i64 i64) (tuple 3 4)]
    [same : (Tuple i64 i64) (tuple 3 4)]
    (tuple_set.insert! keys key)
    (if (and (tuple_eq.eq (& key) (& same)) (tuple_set.contains? (& keys) same))
      42
      1)))