(import "stdlib/hashmap.tl")

; Must fail: put may overwrite, insert, resize, or move buckets while a mutable
; entry into the table is still live.
(define (main) : i64
  (let
    [alpha : String "alpha"]
    [m : StringI64Map
      (string-i64-map-put (string-i64-map-with-capacity 4) "alpha" 1)]
    [entry : (StringI64MapMutEntry m)
      (string-i64-map-get-mut-entry-borrowed m (& alpha))]
    [updated : StringI64Map (string-i64-map-put m "beta" 2)]
    (+ (string-i64-map-mut-entry-value-or entry 0) (string-i64-map-len updated))))