;# benchmarks/hashmap_get/bench.tl - generated i64/i64 hashmap lookup benchmark (#2166).
;#
;# Equivalent to benchmarks/hashmap_get/baseline.c. The benchmark pre-populates
;# a fixed-capacity map, then alternates deterministic hit and miss lookups so
;# the generated read probe path dominates the runtime.
(import stdlib.io)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as map_i64_i64)

(define hashmap-get-base-rounds : i64
  1200)
(define hashmap-get-size : i64
  2048)

(define (hashmap-get-key [i : i64]) : i64
  (+ (* i 17) 5))

(define (hashmap-get-value [key : i64]) : i64
  (+ (* key 33) 7))

(define (main) : i64
  (let
    [rounds : i64 (+ hashmap-get-base-rounds (io.arg-count))]
    [m : map_i64_i64.Map (map_i64_i64.with-capacity 4096)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i hashmap-get-size)
        (begin
          (let
            [key : i64 (hashmap-get-key i)]
            (map_i64_i64.insert! m key (hashmap-get-value key)))
          (set! i (+ i 1))))
      (let
        [round : i64 0]
        (while (< round rounds)
          (begin
            (let
              [hit : i64 0]
              (while (< hit hashmap-get-size)
                (begin
                  (let
                    [key : i64 (hashmap-get-key hit)]
                    (set! acc (+ acc (map_i64_i64.get-value-or (& m) key -1))))
                  (set! hit (+ hit 1)))))
            (let
              [miss : i64 0]
              (while (< miss hashmap-get-size)
                (begin
                  (let
                    [key : i64 (+ (hashmap-get-key miss) 1)]
                    (set! acc (+ acc (map_i64_i64.get-value-or (& m) key 3))))
                  (set! miss (+ miss 1)))))
            (set! round (+ round 1)))))
      (bit-and (+ acc (map_i64_i64.len (& m))) 255))))