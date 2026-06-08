(import "stdlib/hashmap.tl")

(define (hashmap-borrowed-value-len
  [lookup : (StringStringMapBorrowedValueLookup map)]) : i64
  (match lookup
    [(StringStringMapBorrowedValueFound value) (string-length value)]
    [(StringStringMapBorrowedValueMissing) 0]))

; Must fail: removing a slot would invalidate the returned value reference.
(define (main) : i64
  (let
    [key : String "alpha"]
    [m : StringStringMap
      (string-string-map-put (string-string-map-with-capacity 4) "alpha" "red")]
    [borrowed : (StringStringMapBorrowedValueLookup m)
      (string-string-map-get-value-borrowed (& m) (& key))]
    [removed : StringStringMapRemoveResult
      (string-string-map-remove-borrowed m (& key))]
    (+
      (hashmap-borrowed-value-len borrowed)
      (match removed
        [(StringStringMapRemoveOk _) 1]
        [(StringStringMapRemoveMissing _) 0]))))