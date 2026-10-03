(import stdlib.hashmap)
(import (hashmap.hashmap String String) as map_string_string)

;; lint-allow: unused-import
(import stdlib.string)

(define (hashmap-borrowed-value-len
  [lookup : (map_string_string.BorrowedValueLookup map)]) : i64
  (match lookup
    [(BorrowedValueFound value) (string-length value)]
    [(BorrowedValueMissing) 0]))

; Must fail: put may overwrite, insert, resize, or move buckets while a value
; reference into the map is still live.
(define (main) : i64
  (let
    [key : String "alpha"]
    [m : map_string_string.Map (map_string_string.with-capacity 1)]
    (map_string_string.insert! m "alpha" "red")
    (let
      [borrowed : (map_string_string.BorrowedValueLookup m)
        (map_string_string.get-value-borrowed (& m) (& key))]
      (map_string_string.insert-or-update! m "beta" "amber")
      (+ (hashmap-borrowed-value-len borrowed) (map_string_string.len (& m))))))