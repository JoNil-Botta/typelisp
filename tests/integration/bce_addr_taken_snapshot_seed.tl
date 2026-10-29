(import stdlib.io)

;; The counter starts at a snapshot of n (-1); a store through pn then sets n
;; to 0. i=-1: index=-1 length=8 checked abort.
(define (sum-at [items : (& source (Slice i64))] [trips : i64] [start : i64]) : i64
  (let
    [n : i64 start]
    [pn : (MutPtr i64)
      (unsafe
        (ptr-addr-of n))]
    [i : i64 n]
    [acc : i64 0]
    (unsafe
      (ptr-write! pn 0))
    (while (< i trips)
      (set! acc (+ acc (array-ref items i)))
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
      (+ 7 (io.arg-count))
      (- (io.arg-count) 2))))