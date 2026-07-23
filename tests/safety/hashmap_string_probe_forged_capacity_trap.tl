;: A generated string-key probe remains safe when a caller forges capacity:
;: its checked slot reads trap before metadata can address outside the array.
(import stdlib.array)
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as map)

(define (main) : i64
  (let
    [slots : (Array map.GeneratedHashmapSlot)
      (array.make-array map.GeneratedHashmapSlot 1)]
    [key : String "missing"]
    (begin
      (array-set! slots 0 (map.GeneratedHashmapSlot.Tombstone))
      (map.probe (& slots) 2 (& key) (map.hash-key (& key)))
      42)))