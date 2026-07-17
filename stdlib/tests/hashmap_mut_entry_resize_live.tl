(import stdlib.hashmap)
(import (hashmap String i64) as map_string_i64)

; Must fail: resizing/rehashing moves bucket storage while a mutable entry into
; the old storage is still live.
(define (main) : i64
  (let
    [alpha : String "alpha"]
    [m : map_string_i64.Map (map_string_i64.with-capacity 4)]
    (begin
      (map_string_i64.insert! m "alpha" 1)
      (map_string_i64.insert! m "beta" 2)
      (let
        [entry : (map_string_i64.MutEntry m)
          (map_string_i64.get-mut-entry-borrowed (&mut m) (& alpha))]
        (begin
          ;; The third insertion crosses the four-slot table's load threshold.
          (map_string_i64.insert! m "gamma" 3)
          (+
            (map_string_i64.mut-entry-value-or entry 0)
            (map_string_i64.capacity (& m))))))))