; refs #4286: generated hashmap globals must borrow the loaded aggregate value,
; not the global storage slot that holds the aggregate pointer.
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as string_i64_map)

(define generated-hashmap-global : string_i64_map.Map
  (string_i64_map.with-capacity 1))
(define generated-hashmap-sentinel : i64
  99)

(define (generated-hashmap-fill-global!) : unit
  (begin
    (string_i64_map.insert! generated-hashmap-global "k0" 0)
    (string_i64_map.insert! generated-hashmap-global "k1" 1)
    (string_i64_map.insert! generated-hashmap-global "k2" 2)
    (string_i64_map.insert! generated-hashmap-global "k3" 3)
    (string_i64_map.insert! generated-hashmap-global "k4" 4)
    (string_i64_map.insert! generated-hashmap-global "k5" 5)
    (string_i64_map.insert! generated-hashmap-global "k6" 6)
    (string_i64_map.insert! generated-hashmap-global "k7" 7)))

(define (generated-hashmap-value [key : String]) : i64
  (string_i64_map.lookup-value-or
    (string_i64_map.get (& generated-hashmap-global) key)
    -1000))

(define (generated-hashmap-score) : i64
  (+
    (+
      (+ (generated-hashmap-value "k0") (generated-hashmap-value "k1"))
      (+ (generated-hashmap-value "k2") (generated-hashmap-value "k3")))
    (+
      (+ (generated-hashmap-value "k4") (generated-hashmap-value "k5"))
      (+ (generated-hashmap-value "k6") (generated-hashmap-value "k7")))))

(define (main) : i64
  (begin
    (generated-hashmap-fill-global!)
    (if (and
      (= generated-hashmap-sentinel 99)
      (= (string_i64_map.len (& generated-hashmap-global)) 8)
      (= (generated-hashmap-score) 28))
      42
      1)))