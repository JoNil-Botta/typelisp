;; The digest polynomial is format-stable. Check every short subrange against
;; bytewise modular arithmetic, including maximal bytes and incoming hashes.
(import tlci_core as tlci)
(import stdlib.test)
(import stdlib.arena)

(define (reference
  [bytes : (& bytes (__tl_dyn-array u8))]
  [hash : i64]
  [start : i64]
  [end : i64]) : i64
  (let
    [h : i64 hash]
    [i : i64 start]
    (begin
      (while (< i end)
        (begin
          (set! h (% (+ (* h 131) (cast (array-ref bytes i) : i64)) 2147483647))
          (set! i (+ i 1))))
      h)))

(define (check-length [n : i64] [pattern : i64]) : unit
  (let
    [bytes : (__tl_dyn-array u8)
      (if (= pattern 0)
        (__tl_make-array u8 n)
        (tlci.tlci-test-hash-bytes
          n
          (if (= pattern 1)
            -1
            (+ n 13))))]
    [start : i64 0]
    (begin
      (test.assert-i64-eq
        (tlci.tlci-content-hash (& bytes))
        (tlci.tlci-content-hash-bytewise (& bytes))
        "content digest keeps its zeroed digest field")
      (while (<= start n)
        (begin
          (let
            [end : i64 start]
            (while (<= end n)
              (begin
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
                  "largest normalized incoming digest")
                (set! end (+ end 1)))))
          (set! start (+ start 1)))))))

(test
  balanced_tlci_hash_blocks
  (let
    [n : i64 0]
    (while (<= n 80)
      (begin
        (let
          [pattern : i64 0]
          (while (< pattern 3)
            (begin
              (let
                [scope (arena.make)]
                (begin
                  (in-arena scope (check-length n pattern))
                  (arena.destroy-safe! scope)))
              (set! pattern (+ pattern 1)))))
        (set! n (+ n 1))))))

(define (check-stream-boundaries [n : i64] [pattern : i64]) : unit
  (let
    [bytes : (__tl_dyn-array u8)
      (if (= pattern 0)
        (__tl_make-array u8 (+ n 32))
        (tlci.tlci-test-hash-bytes
          (+ n 32)
          (if (= pattern 1)
            -1
            (+ n 13))))]
    [start : i64 0]
    (while (< start 32)
      (begin
        (test.assert-i64-eq
          (tlci.tlci-hash-extend (& bytes) 0 start (+ start n))
          (reference (& bytes) 0 start (+ start n))
          "parallel streams at each alignment with zero seed")
        (test.assert-i64-eq
          (tlci.tlci-hash-extend (& bytes) 2147483646 start (+ start n))
          (reference (& bytes) 2147483646 start (+ start n))
          "parallel streams at each alignment with maximal seed")
        (set! start (+ start 1))))))

(test
  parallel_tlci_hash_boundaries
  (let
    [centers : (Array i64 8) (array 32 64 96 128 256 1024 4096 8192)]
    [c : i64 0]
    (while (< c (array-length centers))
      (let
        [delta : i64 -1]
        (begin
          (while (<= delta 1)
            (let
              [pattern : i64 0]
              (begin
                (while (< pattern 3)
                  (let
                    [scope (arena.make)]
                    (begin
                      (in-arena
                        scope
                        (check-stream-boundaries
                          (+ (array-ref centers c) delta)
                          pattern))
                      (arena.destroy-safe! scope)
                      (set! pattern (+ pattern 1)))))
                (set! delta (+ delta 1)))))
          (set! c (+ c 1)))))))