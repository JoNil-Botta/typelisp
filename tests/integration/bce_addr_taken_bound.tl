(import stdlib.io)

(define (sum-to [items : (& source (Slice i64))] [k : i64]) : i64
  (let
    [n : i64 k]
    [pn : (MutPtr i64)
      (unsafe
        (ptr-addr-of n))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i n)
      (set! acc (+ acc (array-ref items i)))
      (unsafe
        (ptr-write! pn (+ i 3)))
      (set! i (+ i 1)))
    acc))

(define (main) : i64
  (let
    [arr : (Array i64 8) (array 1 1 1 1 1 1 1 1)]
    (sum-to (slice-view (& arr) 0 (+ 7 (io.arg-count))) (io.arg-count))))