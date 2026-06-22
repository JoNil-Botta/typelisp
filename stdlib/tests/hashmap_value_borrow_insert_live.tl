(import stdlib.hashmap)

(define (hashmap-borrowed-value-len
  [lookup : (hashmap.StringStringMapBorrowedValueLookup map)]) : i64
  (match lookup
    [(hashmap.StringStringMapBorrowedValueFound value) (string-length value)]
    [(hashmap.StringStringMapBorrowedValueMissing) 0]))

; Must fail: direct insertion mutates the bucket array while a value reference
; into the map is still live.
(define (main) : i64
  (let
    [key : String "alpha"]
    [m : hashmap.StringStringMap
      (hashmap.string-string-map-put
        (hashmap.string-string-map-with-capacity 4)
        "alpha"
        "red")]
    [borrowed : (hashmap.StringStringMapBorrowedValueLookup m)
      (hashmap.string-string-map-get-value-borrowed (& m) (& key))]
    [inserted : hashmap.StringStringMapInsertResult
      (hashmap.string-string-map-insert m "beta" "amber")]
    (+
      (hashmap-borrowed-value-len borrowed)
      (match inserted
        [(hashmap.StringStringMapInsertOk _) 1]
        [(hashmap.StringStringMapInsertFull _) 0]))))