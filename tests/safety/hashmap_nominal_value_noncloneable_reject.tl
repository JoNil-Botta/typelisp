(import stdlib.hashmap)

(defstruct HashmapRawLeaf
  (raw (Ptr i64)))

(defenum HashmapNestedChoice
  (Empty)
  (Raw HashmapRawLeaf))

(defstruct HashmapNoncloneableValue
  (choice HashmapNestedChoice))

(import (hashmap.hashmap i64 HashmapNoncloneableValue) as invalid_map)

(define (main) : i64
  (let
    [map : invalid_map.Map (invalid_map.new)]
    (invalid_map.len (& map))))