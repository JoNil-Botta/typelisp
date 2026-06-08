(import "stdlib/hashmap.tl")

; Must fail: resizing/rehashing moves bucket storage while a mutable entry into
; the old storage is still live.
(define (main) : i64
  (let
    [alpha : String "alpha"]
    [m : StringI64Map
      (string-i64-map-put (string-i64-map-with-capacity 4) "alpha" 1)]
    [entry : (StringI64MapMutEntry m)
      (string-i64-map-get-mut-entry-borrowed m (& alpha))]
    [resized : StringI64Map (string-i64-map-resized m 16)]
    (+
      (string-i64-map-mut-entry-value-or entry 0)
      (string-i64-map-capacity resized))))