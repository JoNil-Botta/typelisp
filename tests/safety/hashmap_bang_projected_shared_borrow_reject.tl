;: A generated bang macro must preserve borrow conflicts for projected places.
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as map_i64_i64)

(defstruct Holder
  (map map_i64_i64.Map))

(define (main) : unit
  (let
    [holder : Holder (Holder (map_i64_i64.new))]
    (begin
      (map_i64_i64.insert! holder.map 1 10)
      (let
        [borrowed
          (map_i64_i64.get-value-borrowed (& holder.map) 1)]
        (begin
          (map_i64_i64.insert! holder.map 2 20)
          (if (map_i64_i64.borrowed-value-found? borrowed)
            unit
            unit))))))
