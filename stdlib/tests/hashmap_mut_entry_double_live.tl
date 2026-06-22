(import stdlib.hashmap)

; Must fail: two mutable entry handles would alias the same backing table.
(define (main) : i64
  (let
    [alpha : String "alpha"]
    [beta : String "beta"]
    [m : hashmap.StringI64Map
      (hashmap.string-i64-map-put
        (hashmap.string-i64-map-put
          (hashmap.string-i64-map-with-capacity 4)
          "alpha"
          1)
        "beta"
        2)]
    [entry1 : (hashmap.StringI64MapMutEntry m)
      (hashmap.string-i64-map-get-mut-entry-borrowed m (& alpha))]
    [entry2 : (hashmap.StringI64MapMutEntry m)
      (hashmap.string-i64-map-get-mut-entry-borrowed m (& beta))]
    (+
      (hashmap.string-i64-map-mut-entry-value-or entry1 0)
      (hashmap.string-i64-map-mut-entry-value-or entry2 0))))