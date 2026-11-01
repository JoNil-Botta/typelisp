(import stdlib.io)

;; Each trip reads `items[index]`, then writes `index` through its address.
(define (sum-at [items : (& source (Slice i64))] [trips : i64]) : i64
  (let
    [index : i64 0]
    [pindex : (MutPtr i64)
      (unsafe
        (ptr-addr-of index))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i trips)
      (set! acc (+ acc (array-ref items index)))
      (unsafe
        (ptr-write! pindex 8))
      (set! i (+ i 1)))
    acc))

(define (main) : i64
  (let
    [arr : (Array i64 8) (array 1 1 1 1 1 1 1 1)]
    (sum-at (slice-view (& arr) 0 (+ 7 (io.arg-count))) (+ 3 (io.arg-count)))))