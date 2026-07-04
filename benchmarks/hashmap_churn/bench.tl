;# benchmarks/hashmap_churn/bench.tl - hashmap insert/remove churn benchmark (#2167).
;#
;# Equivalent to benchmarks/hashmap_churn/baseline.c. Both insert deterministic
;# i64 keys, remove every third key from each batch, and sample lookups so the
;# final map contents stay observable. The workload keeps tombstones on the
;# insert/put path and makes grow-vs-rehash policy visible.
(import stdlib.io)
(import stdlib.hashmap)

(define churn-base-rounds : i64
  320)
(define churn-batch-size : i64
  96)

(define (hashmap-churn-key [round : i64] [i : i64]) : i64
  (+ (+ (* round 1000003) (* i 131)) 17))

(define (hashmap-churn-value [key : i64]) : i64
  (+ (* key 33) 7))

(define (hashmap-churn-lookup-value-or
  [result : hashmap.I64I64MapLookup]
  [fallback : i64]) : i64
  (match result
    [(hashmap.I64I64MapFound value) value]
    [(hashmap.I64I64MapMissing) fallback]))

(define (hashmap-churn-remove-map [result : hashmap.I64I64MapRemoveResult]) : hashmap.I64I64Map
  (match result
    [(hashmap.I64I64MapRemoveOk map) map]
    [(hashmap.I64I64MapRemoveMissing map) map]))

(define (main) : i64
  (let
    [rounds : i64 (+ churn-base-rounds (io.arg-count))]
    [m : hashmap.I64I64Map (hashmap.i64-i64-map-with-capacity 8)]
    [round : i64 0]
    [acc : i64 0]
    (begin
      (while (< round rounds)
        (begin
          (let
            [i : i64 0]
            (while (< i churn-batch-size)
              (begin
                (let
                  [key : i64 (hashmap-churn-key round i)]
                  (set!
                    m
                    (hashmap.i64-i64-map-put m key (hashmap-churn-value key))))
                (set! i (+ i 1)))))
          (let
            [i : i64 0]
            (while (< i churn-batch-size)
              (begin
                (if (= (% i 11) 0)
                  (let
                    [key : i64 (hashmap-churn-key round i)]
                    (set!
                      acc
                      (+
                        acc
                        (hashmap-churn-lookup-value-or
                          (hashmap.i64-i64-map-get m key)
                          -1))))
                  unit)
                (set! i (+ i 1)))))
          (let
            [i : i64 0]
            (while (< i churn-batch-size)
              (begin
                (if (= (% i 3) 0)
                  (let
                    [key : i64 (hashmap-churn-key round i)]
                    (set!
                      m
                      (hashmap-churn-remove-map
                        (hashmap.i64-i64-map-remove m key))))
                  unit)
                (set! i (+ i 1)))))
          (set! round (+ round 1))))
      (bit-and (+ acc (hashmap.i64-i64-map-len m)) 255))))