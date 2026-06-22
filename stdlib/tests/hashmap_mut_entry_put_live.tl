(import stdlib.hashmap)

; Must fail: put may overwrite, insert, resize, or move buckets while a mutable
; entry into the table is still live.
(define (main) : i64
  (let
    [alpha : String "alpha"]
    [m : hashmap.StringI64Map
      (hashmap.string-i64-map-put
        (hashmap.string-i64-map-with-capacity 4)
        "alpha"
        1)]
    [entry : (hashmap.StringI64MapMutEntry m)
      (hashmap.string-i64-map-get-mut-entry-borrowed m (& alpha))]
    [updated : hashmap.StringI64Map (hashmap.string-i64-map-put m "beta" 2)]
    (+
      (hashmap.string-i64-map-mut-entry-value-or entry 0)
      (hashmap.string-i64-map-len updated))))