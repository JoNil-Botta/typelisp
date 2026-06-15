(import stdlib.hashmap)

(define (hashmap-borrowed-value-len
  [lookup : (hashmap.StringStringMapBorrowedValueLookup map)]) : i64
  (match lookup
    [(hashmap.StringStringMapBorrowedValueFound value) (string-length value)]
    [(hashmap.StringStringMapBorrowedValueMissing) 0]))

; Must fail: put may overwrite, insert, resize, or move buckets while a value
; reference into the map is still live.
(define (main) : i64
  (let
    [key : String "alpha"]
    [m : hashmap.StringStringMap
      (hashmap.string-string-map-put (hashmap.string-string-map-with-capacity 1) "alpha" "red")]
    [borrowed : (hashmap.StringStringMapBorrowedValueLookup m)
      (hashmap.string-string-map-get-value-borrowed (& m) (& key))]
    [updated : hashmap.StringStringMap (hashmap.string-string-map-put m "beta" "amber")]
    (+ (hashmap-borrowed-value-len borrowed) (hashmap.string-string-map-len updated))))