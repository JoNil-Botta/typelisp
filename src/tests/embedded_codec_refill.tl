;; A one-bit literal alphabet visits every reader occupancy and padding tail.
;; Vary exact payload lengths across the fast loop's sixteen-byte boundary.
(import stdlib.iterator)
(import compiler_embedded_stdlib_tlci_codec as codec)
(import compiler_embedded_stdlib_tlci_codec_tests as fixture)
(import stdlib.arena)
(import stdlib.test)

(define (check [n : i64]) : unit
  (let
    [payload : (__tl_dyn-array u8) (fixture.tlci-codec-test-base-payload n n)]
    [main-start : i64 (fixture.tlci-codec-test-main-start)]
    [bit-start : i64 (+ (fixture.tlci-codec-test-length-start) 16)]
    [i : i64 1]
    (when
      (> n 0)
      (set! (array-ref payload (+ main-start 65)) (cast 1 : u8))
      (set! (array-ref payload (+ main-start 66)) (cast 1 : u8)))
    (while (< i n)
      (let
        [at : i64 (+ bit-start (/ i 8))]
        (set!
          (array-ref payload at)
          (cast
            (bit-or (cast (array-ref payload at) : i64) (shl 1 (- 7 (% i 8))))
            : u8))
        (+= i 2)))
    (match (codec.compiler-embedded-stdlib-tlci-codec-decode (& payload) n)
      [(Err _) (test.assert-true false "valid exact-length literal frame")]
      [(Ok bytes)
        (test.assert-i64-eq (array-length bytes) n "decoded frame length")
        (set! i 0)
        (while (< i n)
          (test.assert-i64-eq
            (cast (array-ref bytes i) : i64)
            (+ 65 (% i 2))
            "literal bytes across refill boundaries")
          (+= i 1))])
    unit))

(test
  bounded_embedded_codec_refill
  (for [n (iterator.range 0 (+ 260 1))]
    (let
      [scope (arena.make)]
      (in-arena
        scope
        (check
          (if (<= n 257)
            n
            (+ 2047 (- n 258)))))
      (arena.destroy-safe! scope))))