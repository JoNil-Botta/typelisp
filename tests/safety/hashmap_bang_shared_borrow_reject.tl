;: A live generated hashmap value borrow blocks a bang mutation of the map.
(import stdlib.hashmap)
(import (hashmap i64 i64) as map_i64_i64)

(define (main) : unit
  (let
    [m : map_i64_i64.Map (map_i64_i64.new)]
    (begin
      (map_i64_i64.insert! m 1 10)
      (let
        [borrowed : (map_i64_i64.BorrowedValueLookup m)
          (map_i64_i64.get-value-borrowed (& m) 1)]
        (begin
          (map_i64_i64.insert! m 2 20)
          (if (map_i64_i64.borrowed-value-found? borrowed)
            unit
            unit))))))