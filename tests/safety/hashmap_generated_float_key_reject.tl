(import stdlib.hashmap)
(import (hashmap.hashmap f64 i64) as float_key_map)

(define (main) : i64
  (let
    [m : float_key_map.Map (float_key_map.new)]
    (begin
      (float_key_map.insert! m 1.0 1)
      (float_key_map.len (& m)))))