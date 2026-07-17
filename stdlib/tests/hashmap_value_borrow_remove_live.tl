(import stdlib.hashmap)
(import (hashmap String String) as map_string_string)

;; lint-allow: unused-import
(import stdlib.string)

(define (hashmap-borrowed-value-len
  [lookup : (map_string_string.BorrowedValueLookup map)]) : i64
  (match lookup
    [(map_string_string.BorrowedValueFound value) (string-length value)]
    [(map_string_string.BorrowedValueMissing) 0]))

; Must fail: removing a slot would invalidate the returned value reference.
(define (main) : i64
  (let
    [key : String "alpha"]
    [m : map_string_string.Map (map_string_string.with-capacity 4)]
    (begin
      (map_string_string.insert! m "alpha" "red")
      (let
        [borrowed : (map_string_string.BorrowedValueLookup m)
          (map_string_string.get-value-borrowed (& m) (& key))]
        (begin
          (map_string_string.remove-borrowed! m (& key))
          (hashmap-borrowed-value-len borrowed))))))