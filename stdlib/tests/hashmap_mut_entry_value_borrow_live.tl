(import stdlib.hashmap)

(define (borrowed-value-found? [lookup : (hashmap.StringI64MapBorrowedValueLookup map)]) : bool
  (match lookup
    [(hashmap.StringI64MapBorrowedValueFound _) true]
    [(hashmap.StringI64MapBorrowedValueMissing) false]))

; Must fail: a mutable entry would permit overwriting a map value while an
; immutable value reference into that map is still live.
(define (main) : i64
  (let
    [alpha : String "alpha"]
    [m : hashmap.StringI64Map
      (hashmap.string-i64-map-put (hashmap.string-i64-map-with-capacity 4) "alpha" 1)]
    [borrowed : (hashmap.StringI64MapBorrowedValueLookup m)
      (hashmap.string-i64-map-get-value-borrowed (& m) (& alpha))]
    [entry : (hashmap.StringI64MapMutEntry m)
      (hashmap.string-i64-map-get-mut-entry-borrowed m (& alpha))]
    (if (borrowed-value-found? borrowed)
      (hashmap.string-i64-map-mut-entry-value-or entry 0)
      0)))