(import stdlib.hashmap)

(defstruct UnsupportedHashmapKey
  (value i64)
  (indirect (Box i64)))

(import (hashmap.hashmap UnsupportedHashmapKey i64) as unsupported_key_map)

(define (main) : i64
  (let
    [m : unsupported_key_map.Map (unsupported_key_map.new)]
    (begin
      (unsupported_key_map.insert! m (UnsupportedHashmapKey 1 (box 2)) 1)
      (unsupported_key_map.len (& m)))))