(import stdlib.hashmap)
(import (hashmap String i64) as map_string_i64)

(define (use-map-borrow [_borrowed : (&mut map map_string_i64.Map)]) : unit
  unit)

; Must fail: insert-or-update may overwrite, insert, resize, or move buckets
; while a mutable borrow of the map is still live.
(define (main) : i64
  (let
    [m : map_string_i64.Map (map_string_i64.with-capacity 4)]
    (begin
      (let
        [borrowed : (&mut m map_string_i64.Map) (&mut m)]
        (begin
          (map_string_i64.insert-or-update! m "k" 1)
          (use-map-borrow borrowed)))
      (map_string_i64.len (& m)))))