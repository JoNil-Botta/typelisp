(import "stdlib/hashmap.tl")

; Must fail: two mutable entry handles would alias the same backing table.
(define (main) : i64
  (let
    [alpha : String "alpha"]
    [beta : String "beta"]
    [m : StringI64Map
      (string-i64-map-put
        (string-i64-map-put (string-i64-map-with-capacity 4) "alpha" 1)
        "beta"
        2)]
    [entry1 : (StringI64MapMutEntry m)
      (string-i64-map-get-mut-entry-borrowed m (& alpha))]
    [entry2 : (StringI64MapMutEntry m)
      (string-i64-map-get-mut-entry-borrowed m (& beta))]
    (+
      (string-i64-map-mut-entry-value-or entry1 0)
      (string-i64-map-mut-entry-value-or entry2 0))))