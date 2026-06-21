(import "stdlib/hashmap.tl")
(import "stdlib/string.tl")

(define (hashmap-borrowed-value-len
  [lookup : (StringStringMapBorrowedValueLookup map)]) : i64
  (match lookup
    [(StringStringMapBorrowedValueFound value) (string-length value)]
    [(StringStringMapBorrowedValueMissing) 0]))

; Must fail: put may overwrite, insert, resize, or move buckets while a value
; reference into the map is still live.
(define (main) : i64
  (let
    [key : String "alpha"]
    [m : StringStringMap
      (string-string-map-put (string-string-map-with-capacity 1) "alpha" "red")]
    [borrowed : (StringStringMapBorrowedValueLookup m)
      (string-string-map-get-value-borrowed (& m) (& key))]
    [updated : StringStringMap (string-string-map-put m "beta" "amber")]
    (+ (hashmap-borrowed-value-len borrowed) (string-string-map-len updated))))
