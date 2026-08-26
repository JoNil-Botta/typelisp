(import stdlib.hashmap)
(import (hashmap.hashmap i64 (Tuple i64 i64)) as invalid_map)

(define (main) : i64
  (let
    [map : invalid_map.Map (invalid_map.new)]
    (invalid_map.len (& map))))