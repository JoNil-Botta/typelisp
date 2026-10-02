;: Generated hashmap bang mutators follow the ordinary rule: a temporary
;: receiver is a borrowed call-argument temporary (SPEC section 3.10).
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as map_i64_i64)

(define (main) : unit
  (map_i64_i64.insert! (map_i64_i64.new) 1 1))