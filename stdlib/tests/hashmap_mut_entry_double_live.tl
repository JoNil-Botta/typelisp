(import stdlib.hashmap)
(import (hashmap String i64) as map_string_i64)

; Must fail: two mutable entry handles would alias the same backing table.
(define (main) : i64
  (let
    [alpha : String "alpha"]
    [beta : String "beta"]
    [m : map_string_i64.Map (map_string_i64.with-capacity 4)]
    (begin
      (map_string_i64.insert! m "alpha" 1)
      (map_string_i64.insert! m "beta" 2)
      (let
        [entry1 : (map_string_i64.MutEntry m)
          (map_string_i64.get-mut-entry-borrowed (&mut m) (& alpha))]
        [entry2 : (map_string_i64.MutEntry m)
          (map_string_i64.get-mut-entry-borrowed (&mut m) (& beta))]
        (+
          (map_string_i64.mut-entry-value-or entry1 0)
          (map_string_i64.mut-entry-value-or entry2 0))))))