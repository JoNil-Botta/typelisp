(import stdlib.io)

;; a snapshots n (6), then a store through pn sets n to 0. The loop reads
;; items[a + i] and items[a + i + 1]: i=0 idx 6,7; i=1 index=8 length=8 abort.
(define (sum-at [items : (& source (Slice i64))] [trips : i64] [start : i64]) : i64
  (let
    [n : i64 start]
    [pn : (MutPtr i64)
      (unsafe
        (ptr-addr-of n))]
    [a : i64 n]
    [acc : i64 0]
    [i : i64 0]
    (unsafe
      (ptr-write! pn 0))
    (while (< i trips)
      (set! acc (+ acc (array-ref items (+ a i))))
      (set! acc (+ acc (array-ref items (+ (+ a i) 1))))
      (set! i (+ i 1)))
    (+
      acc
      (unsafe
        (ptr-read pn)))))

(define (main) : i64
  (let
    [arr : (Array i64 8) (array 1 1 1 1 1 1 1 1)]
    (sum-at
      (slice-view (& arr) 0 (+ 7 (io.arg-count)))
      (+ 3 (io.arg-count))
      (+ 5 (io.arg-count)))))