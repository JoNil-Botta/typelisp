(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as map_string_i64)

(define (borrowed-value-found?
  [lookup : (map_string_i64.BorrowedValueLookup map)]) : bool
  (match lookup
    [(map_string_i64.BorrowedValueFound _) true]
    [(map_string_i64.BorrowedValueMissing) false]))

; Must fail: a mutable entry would permit overwriting a map value while an
; immutable value reference into that map is still live.
(define (main) : i64
  (let
    [alpha : String "alpha"]
    [m : map_string_i64.Map (map_string_i64.with-capacity 4)]
    (begin
      (map_string_i64.insert! m "alpha" 1)
      (let
        [borrowed : (map_string_i64.BorrowedValueLookup m)
          (map_string_i64.get-value-borrowed (& m) (& alpha))]
        [entry : (map_string_i64.MutEntry m)
          (map_string_i64.get-mut-entry-borrowed (&mut m) (& alpha))]
        (if (borrowed-value-found? borrowed)
          (map_string_i64.mut-entry-value-or entry 0)
          0)))))