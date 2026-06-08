(import "stdlib/hashmap.tl")

(define (hashmap-borrowed-value-len
  [lookup : (StringStringMapBorrowedValueLookup map)]) : i64
  (match lookup
    [(StringStringMapBorrowedValueFound value) (string-length value)]
    [(StringStringMapBorrowedValueMissing) 0]))

; Must fail: resizing/rehashing moves bucket storage while a value reference
; into the old storage is still live.
(define (main) : i64
  (let
    [key : String "alpha"]
    [m : StringStringMap
      (string-string-map-put (string-string-map-with-capacity 4) "alpha" "red")]
    [borrowed : (StringStringMapBorrowedValueLookup m)
      (string-string-map-get-value-borrowed (& m) (& key))]
    [resized : StringStringMap (string-string-map-resized m 16)]
    (+
      (hashmap-borrowed-value-len borrowed)
      (string-string-map-capacity resized))))