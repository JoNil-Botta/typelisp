(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as map_string_i64)

; Must fail: put may overwrite, insert, resize, or move buckets while a mutable
; entry into the table is still live.
(define (main) : i64
  (let
    [alpha : String "alpha"]
    [m : map_string_i64.Map (map_string_i64.with-capacity 4)]
    (begin
      (map_string_i64.insert! m "alpha" 1)
      (let
        [entry : (map_string_i64.MutEntry m)
          (map_string_i64.get-mut-entry-borrowed (&mut m) (& alpha))]
        (begin
          (map_string_i64.insert-or-update! m "beta" 2)
          (+
            (map_string_i64.mut-entry-value-or entry 0)
            (map_string_i64.len (& m))))))))