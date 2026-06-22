(import stdlib.hashmap)

(define (hashmap-borrowed-value-len
  [lookup : (hashmap.StringStringMapBorrowedValueLookup map)]) : i64
  (match lookup
    [(hashmap.StringStringMapBorrowedValueFound value) (string-length value)]
    [(hashmap.StringStringMapBorrowedValueMissing) 0]))

; Must fail: resizing/rehashing moves bucket storage while a value reference
; into the old storage is still live.
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
    [resized : hashmap.StringStringMap (hashmap.string-string-map-resized m 16)]
    (+
      (hashmap-borrowed-value-len borrowed)
      (hashmap.string-string-map-capacity resized))))