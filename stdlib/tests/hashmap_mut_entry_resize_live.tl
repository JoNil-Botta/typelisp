(import stdlib.hashmap)

; Must fail: resizing/rehashing moves bucket storage while a mutable entry into
; the old storage is still live.
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
    [resized : hashmap.StringI64Map (hashmap.string-i64-map-resized m 16)]
    (+
      (hashmap.string-i64-map-mut-entry-value-or entry 0)
      (hashmap.string-i64-map-capacity resized))))