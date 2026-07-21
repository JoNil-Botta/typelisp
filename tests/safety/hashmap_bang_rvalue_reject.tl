;: Generated hashmap bang mutators preserve the normal mutable-place diagnostic.
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as map_i64_i64)

(define (main) : unit
  (map_i64_i64.insert! (map_i64_i64.new) 1 1))