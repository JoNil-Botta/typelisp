(import stdlib.io)

;; The loop bound n is stored to through its address on every trip, so the
;; loop runs four times (exit 4, four dots). BCE's clone-free bound tightening
;; must not capture the initial bound 8 for the continuing compare.
(define (main) : i64
  (let
    [items : (Array i64 8) (array 1 1 1 1 1 1 1 1)]
    [n : i64 (+ (io.arg-count) 7)]
    [pn : (MutPtr i64)
      (unsafe
        (ptr-addr-of n))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i n)
      (set! acc (+ acc (array-ref items i)))
      (unsafe
        (ptr-write! pn 4))
      (io.print-error ".")
      (let
        [j : i64 0]
        (while (< j (io.arg-count))
          (set! acc (+ acc j))
          (set! j (+ j 1))))
      (set! i (+ i 1)))
    acc))