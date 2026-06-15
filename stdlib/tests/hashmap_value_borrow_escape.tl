(import stdlib.hashmap)

; Must fail: the returned lookup is tied to the inner map, not `outer`.
(define (main [outer : hashmap.StringStringMap] [key : String]) : (hashmap.StringStringMapBorrowedValueLookup
    outer)
  (let
    [inner : hashmap.StringStringMap
      (hashmap.string-string-map-put (hashmap.string-string-map-with-capacity 4) "alpha" "red")]
    (hashmap.string-string-map-get-value-borrowed (& inner) (& key))))