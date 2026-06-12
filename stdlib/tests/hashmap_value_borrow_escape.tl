(import "stdlib/hashmap.tl")

; Must fail: the returned lookup is tied to the inner map, not `outer`.
(define (main [outer : StringStringMap] [key : String]) : (StringStringMapBorrowedValueLookup
    outer)
  (let
    [inner : StringStringMap
      (string-string-map-put (string-string-map-with-capacity 4) "alpha" "red")]
    (string-string-map-get-value-borrowed (& inner) (& key))))