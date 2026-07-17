(import stdlib.hashmap)
(import (hashmap String String) as map_string_string)

; Must fail: the returned lookup is tied to the inner map, not `outer`.
(define (main [outer : map_string_string.Map] [key : String]) : (map_string_string.BorrowedValueLookup
    outer)
  (let
    [inner : map_string_string.Map (map_string_string.with-capacity 4)]
    (begin
      (map_string_string.insert! inner "alpha" "red")
      (map_string_string.get-value-borrowed (& inner) (& key)))))