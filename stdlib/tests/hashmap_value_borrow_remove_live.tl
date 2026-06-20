(import stdlib.hashmap)

(define (hashmap-borrowed-value-len
  [lookup : (hashmap.StringStringMapBorrowedValueLookup map)]) : i64
  (match lookup
    [(hashmap.StringStringMapBorrowedValueFound value) (string-length value)]
    [(hashmap.StringStringMapBorrowedValueMissing) 0]))

; Must fail: removing a slot would invalidate the returned value reference.
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
    [removed : hashmap.StringStringMapRemoveResult
      (hashmap.string-string-map-remove-borrowed m (& key))]
    (+
      (hashmap-borrowed-value-len borrowed)
      (match removed
        [(hashmap.StringStringMapRemoveOk _) 1]
        [(hashmap.StringStringMapRemoveMissing _) 0]))))