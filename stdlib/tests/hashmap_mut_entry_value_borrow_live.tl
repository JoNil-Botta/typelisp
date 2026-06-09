(import "stdlib/hashmap.tl")

(define (borrowed-value-found? [lookup : (StringI64MapBorrowedValueLookup map)]) : bool
  (match lookup
    [(StringI64MapBorrowedValueFound _) true]
    [(StringI64MapBorrowedValueMissing) false]))

; Must fail: a mutable entry would permit overwriting a map value while an
; immutable value reference into that map is still live.
(define (main) : i64
  (let
    [alpha : String "alpha"]
    [m : StringI64Map
      (string-i64-map-put (string-i64-map-with-capacity 4) "alpha" 1)]
    [borrowed : (StringI64MapBorrowedValueLookup m)
      (string-i64-map-get-value-borrowed (& m) (& alpha))]
    [entry : (StringI64MapMutEntry m)
      (string-i64-map-get-mut-entry-borrowed m (& alpha))]
    (if (borrowed-value-found? borrowed)
      (string-i64-map-mut-entry-value-or entry 0)
      0)))