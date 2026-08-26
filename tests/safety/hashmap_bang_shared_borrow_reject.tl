;: A live generated hashmap value borrow blocks a bang mutation of the map.
(import stdlib.hashmap)

(defstruct BorrowedNominalValue
  (text String))

(import (hashmap.hashmap i64 BorrowedNominalValue) as nominal_map)

(define (main) : unit
  (let
    [m : nominal_map.Map (nominal_map.new)]
    (begin
      (nominal_map.insert! m 1 (BorrowedNominalValue "first"))
      (let
        [borrowed : (nominal_map.BorrowedValueLookup m)
          (nominal_map.get-value-borrowed (& m) 1)]
        (begin
          (nominal_map.insert! m 2 (BorrowedNominalValue "second"))
          (if (nominal_map.borrowed-value-found? borrowed)
            unit
            unit))))))