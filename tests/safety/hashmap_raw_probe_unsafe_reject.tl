(import stdlib.hashmap)

(define (main) : i64
  (let
    [slots : (Array stdlib.hashmap.HashmapI64I64BackingSlot)
      (make-array stdlib.hashmap.HashmapI64I64BackingSlot 1)]
    (begin
      (stdlib.hashmap.hashmap-i64-i64-backing-probe slots 2 0 0)
      42)))