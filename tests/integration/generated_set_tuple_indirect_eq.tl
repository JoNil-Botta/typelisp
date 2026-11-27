;; The generated Set imports eq and hash, and hash also imports eq.
(import stdlib.set)
(import (set.set (Tuple i64 i64)) as tuple_set)

(define (main) : i64
  (let
    [keys : tuple_set.Set (tuple_set.new)]
    (tuple_set.insert! keys (tuple 3 4))
    (tuple_set.insert! keys (tuple 3 4))
    (if (and
      (= (tuple_set.len (& keys)) 1)
      (tuple_set.contains? (& keys) (tuple 3 4))
      (not (tuple_set.contains? (& keys) (tuple 4 3))))
      42
      1)))