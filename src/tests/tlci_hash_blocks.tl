;; The digest polynomial is format-stable. Check every short subrange against
;; bytewise modular arithmetic, including maximal bytes and incoming hashes.
(import stdlib.iterator)
(import tlci_core as tlci)
(import tlci_core_tests)
(import stdlib.test)
(import stdlib.arena)

(define (reference
  [bytes : (& bytes (__tl_dyn-array u8))]
  [hash : i64]
  [start : i64]
  [end : i64]) : i64
  (let
    [h : i64 hash]
    (for [i (iterator.range start end)]
      (set! h (% (+ (* h 131) (cast (array-ref bytes i) : i64)) 2147483647)))
    h))

(define (check-length [n : i64] [pattern : i64]) : unit
  (let
    [bytes : (__tl_dyn-array u8)
      (if (= pattern 0)
        (__tl_make-array u8 n)
        (tlci_core_tests.tlci-test-hash-bytes
          n
          (if (= pattern 1)
            -1
            (+ n 13))))]
    (test.assert-i64-eq
      (tlci.tlci-content-hash (& bytes))
      (tlci.tlci-content-hash-bytewise (& bytes))
      "content digest keeps its zeroed digest field")
    (for [start (iterator.range 0 (+ n 1))]
      (for [end (iterator.range start (+ n 1))]
        (test.assert-i64-eq
          (tlci.tlci-hash-extend (& bytes) 0 start end)
          (reference (& bytes) 0 start end)
          "zero incoming digest")
        (test.assert-i64-eq
          (tlci.tlci-range-hash (& bytes) start (- end start))
          (reference (& bytes) 1 start end)
          "range digest with ordinary incoming value")
        (test.assert-i64-eq
          (tlci.tlci-hash-extend (& bytes) 2147483646 start end)
          (reference (& bytes) 2147483646 start end)
          "largest normalized incoming digest")))))

(test
  balanced_tlci_hash_blocks
  (for [n (iterator.range 0 (+ 80 1))]
    (for [pattern (iterator.range 0 3)]
      (let
        [scope (arena.make)]
        (in-arena scope (check-length n pattern))
        (arena.destroy-safe! scope)))))

(define (check-stream-boundaries [n : i64] [pattern : i64]) : unit
  (let
    [bytes : (__tl_dyn-array u8)
      (if (= pattern 0)
        (__tl_make-array u8 (+ n 32))
        (tlci_core_tests.tlci-test-hash-bytes
          (+ n 32)
          (if (= pattern 1)
            -1
            (+ n 13))))]
    (for [start (iterator.range 0 32)]
      (test.assert-i64-eq
        (tlci.tlci-hash-extend (& bytes) 0 start (+ start n))
        (reference (& bytes) 0 start (+ start n))
        "parallel streams at each alignment with zero seed")
      (test.assert-i64-eq
        (tlci.tlci-hash-extend (& bytes) 2147483646 start (+ start n))
        (reference (& bytes) 2147483646 start (+ start n))
        "parallel streams at each alignment with maximal seed"))))

(test
  parallel_tlci_hash_boundaries
  (let
    [centers : (Array i64 8) (array 32 64 96 128 256 1024 4096 8192)]
    (for [c (iterator.range 0 (array-length centers))]
      (for [delta (iterator.range -1 (+ 1 1))]
        (for [pattern (iterator.range 0 3)]
          (let
            [scope (arena.make)]
            (in-arena
              scope
              (check-stream-boundaries (+ (array-ref centers c) delta) pattern))
            (arena.destroy-safe! scope)))))))