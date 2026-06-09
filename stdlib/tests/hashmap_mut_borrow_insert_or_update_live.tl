(import "stdlib/hashmap.tl")

(define (use-map-borrow [borrowed : (&mut map StringI64Map)]) : unit
  unit)

; Must fail: insert-or-update may overwrite, insert, resize, or move buckets
; while a mutable borrow of the map is still live.
(define (main) : StringI64Map
  (let
    [m : StringI64Map (string-i64-map-with-capacity 4)]
    [borrowed : (&mut m StringI64Map) (&mut m)]
    [updated : StringI64Map (string-i64-map-insert-or-update m "k" 1)]
    (begin
      (use-map-borrow borrowed)
      updated)))