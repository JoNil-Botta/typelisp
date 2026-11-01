(import stdlib.io)

;; Not tail-recursive, so the call stays a call.
(define (depth [d : i64]) : i64
  (if (<= d 0)
    0
    (+ 1 (depth (- d 1)))))

;; The outer loop's limit `n` is raised through its address each trip; the
;; checked `items[i]` aborts at index 8 at opt0.
(define (walk [items : (& source (Slice i64))] [k : i64]) : i64
  (let
    [n : i64 k]
    [pn : (MutPtr i64)
      (unsafe
        (ptr-addr-of n))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i n)
      (set! acc (+ acc (array-ref items i)))
      (let
        [j : i64 0]
        (while (< j k)
          (set! acc (+ acc j))
          (set! j (+ j 1))))
      (set! acc (+ acc (depth k)))
      (unsafe
        (ptr-write! pn (+ i 3)))
      (set! i (+ i 1)))
    acc))

(define (main) : i64
  (let
    [arr : (Array i64 8) (array 1 1 1 1 1 1 1 1)]
    (walk (slice-view (& arr) 0 (+ 7 (io.arg-count))) (io.arg-count))))