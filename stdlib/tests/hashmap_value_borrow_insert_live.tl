(import "stdlib/hashmap.tl")

(define (hashmap-borrowed-value-len
  [lookup : (StringStringMapBorrowedValueLookup map)]) : i64
  (match lookup
    [(StringStringMapBorrowedValueFound value) (string-length value)]
    [(StringStringMapBorrowedValueMissing) 0]))

; Must fail: direct insertion mutates the bucket array while a value reference
; into the map is still live.
(define (main) : i64
  (let
    [key : String "alpha"]
    [m : StringStringMap
      (string-string-map-put (string-string-map-with-capacity 4) "alpha" "red")]
    [borrowed : (StringStringMapBorrowedValueLookup m)
      (string-string-map-get-value-borrowed (& m) (& key))]
    [inserted : StringStringMapInsertResult
      (string-string-map-insert m "beta" "amber")]
    (+
      (hashmap-borrowed-value-len borrowed)
      (match inserted
        [(StringStringMapInsertOk _) 1]
        [(StringStringMapInsertFull _) 0]))))