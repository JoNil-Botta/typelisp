;# benchmarks/hashmap_insert/bench.tl - generated I64I64Map insert benchmark (#2165).
;#
;# Equivalent to benchmarks/hashmap_insert/baseline.c. The benchmark repeatedly
;# builds a fresh power-of-two map and populates it with deterministic i64 keys,
;# then samples a lookup so the inserted contents stay observable.
(import "stdlib/io.tl")
(import "stdlib/hashmap.tl")

(define hashmap-insert-base-rounds : i64
  640)
(define hashmap-insert-size : i64
  1024)

(define (hashmap-insert-key [round : i64] [i : i64]) : i64
  (+ (+ (* round 1000003) (* i 17)) 5))

(define (hashmap-insert-value [key : i64]) : i64
  (+ (* key 33) 7))

(define (hashmap-insert-lookup-value-or
  [result : I64I64MapLookup]
  [fallback : i64]) : i64
  (match result
    [(I64I64MapFound value) value]
    [(I64I64MapMissing) fallback]))

(define (main) : i64
  (let
    [rounds : i64 (+ hashmap-insert-base-rounds (arg-count))]
    [round : i64 0]
    [acc : i64 0]
    (begin
      (while (< round rounds)
        (begin
          (let
            [m : I64I64Map (i64-i64-map-with-capacity 2048)]
            [i : i64 0]
            (begin
              (while (< i hashmap-insert-size)
                (begin
                  (let
                    [key : i64 (hashmap-insert-key round i)]
                    (set! m (i64-i64-map-put m key (hashmap-insert-value key))))
                  (set! i (+ i 1))))
              (let
                [sample : i64 (% round hashmap-insert-size)]
                [sample-key : i64 (hashmap-insert-key round sample)]
                (set!
                  acc
                  (+
                    acc
                    (+
                      (i64-i64-map-len m)
                      (hashmap-insert-lookup-value-or
                        (i64-i64-map-get m sample-key)
                        -1)))))))
          (set! round (+ round 1))))
      (bit-and acc 255))))