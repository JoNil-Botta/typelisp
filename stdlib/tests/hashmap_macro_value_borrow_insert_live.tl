(import stdlib.hashmap)
(import (hashmap i64 String) as map_i64_string)

(define (borrowed-value-found?
  [lookup : (map_i64_string.BorrowedValueLookup map)]) : bool
  (match lookup
    [(map_i64_string.BorrowedValueFound _) true]
    [(map_i64_string.BorrowedValueMissing) false]))

(define (main) : i64
  (let
    [m : map_i64_string.Map (map_i64_string.with-capacity 2)]
    (begin
      (map_i64_string.insert! m 1 "one")
      (let
        [borrowed : (map_i64_string.BorrowedValueLookup m)
          (map_i64_string.get-value-borrowed (& m) 1)]
        (begin
          (map_i64_string.insert! m 2 "two")
          (if (borrowed-value-found? borrowed)
            1
            0))))))