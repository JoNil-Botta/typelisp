(import stdlib.hashmap)

(define (use-map-borrow [borrowed : (&mut map hashmap.StringI64Map)]) : unit
  unit)

; Must fail: insert-or-update may overwrite, insert, resize, or move buckets
; while a mutable borrow of the map is still live.
(define (main) : hashmap.StringI64Map
  (let
    [m : hashmap.StringI64Map (hashmap.string-i64-map-with-capacity 4)]
    [borrowed : (&mut m hashmap.StringI64Map) (&mut m)]
    [updated : hashmap.StringI64Map (hashmap.string-i64-map-insert-or-update m "k" 1)]
    (begin
      (use-map-borrow borrowed)
      updated)))