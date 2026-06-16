;# benchmarks/hashmap_grow/bench.tl - hashmap grow/rehash benchmark (#2168).
;#
;# Equivalent to benchmarks/hashmap_grow/baseline.c. Both insert deterministic
;# i64 keys into an initially small open-addressed map, forcing repeated grows
;# and rehashes, then sample lookups to make the final contents observable.
;# TypeLisp `+`/`*` wrap modulo 2^64 (SPEC), matching C `uint64_t`, so both
;# programs produce the identical exit code on a given host.
;#
;# The entry count is `base-entries + (arg-count)` (`arg-count` is 1 with no
;# extra arguments, matching C `argc`), keeping the result deterministic while
;# preventing whole-loop constant folding.
(import "stdlib/io.tl")
(import "stdlib/hashmap.tl")

(define base-entries : i64
  24000)

(define (hashmap-grow-key [i : i64]) : i64
  (+ (* i 131) 17))

(define (hashmap-grow-value [key : i64]) : i64
  (+ (* key 33) 7))

(define (hashmap-grow-lookup-value-or
  [result : I64I64MapLookup]
  [fallback : i64]) : i64
  (match result
    [(I64I64MapFound value) value]
    [(I64I64MapMissing) fallback]))

(define (main) : i64
  (let
    [n : i64 (+ base-entries (arg-count))]
    [m : I64I64Map (i64-i64-map-with-capacity 4)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (let
            [key : i64 (hashmap-grow-key i)]
            (set! m (i64-i64-map-put m key (hashmap-grow-value key))))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i n)
        (begin
          (let
            [key : i64 (hashmap-grow-key i)]
            (set!
              acc
              (+ acc (hashmap-grow-lookup-value-or (i64-i64-map-get m key) -1))))
          (set! i (+ i 257))))
      (bit-and (+ (+ acc (i64-i64-map-len m)) (i64-i64-map-capacity m)) 255))))