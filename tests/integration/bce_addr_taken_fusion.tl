(import stdlib.io)

;; Each trip checks `a[index]`, writes `index` through its address, then
;; checks `b[index]`: the two checks read different values, so one cannot
;; stand for the other. i=0 writes 8, so b[8] aborts (length 8).
(define (sum-at
  [a : (& first (Slice i64))]
  [b : (& second (Slice i64))]
  [trips : i64]) : i64
  (let
    [index : i64 0]
    [pindex : (MutPtr i64)
      (unsafe
        (ptr-addr-of index))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i trips)
      (set! acc (+ acc (array-ref a i)))
      (set! acc (+ acc (array-ref a index)))
      (if (< i 2)
        (unsafe
          (ptr-write! pindex 8))
        (unsafe
          (ptr-write! pindex 9)))
      (set! acc (+ acc (array-ref b index)))
      (unsafe
        (ptr-write! pindex 0))
      (set! i (+ i 1)))
    acc))

(define (main) : i64
  (let
    [arr : (Array i64 8) (array 1 1 1 1 1 1 1 1)]
    (sum-at
      (slice-view (& arr) 0 (+ 7 (io.arg-count)))
      (slice-view (& arr) 0 (+ 7 (io.arg-count)))
      (+ 2 (io.arg-count)))))