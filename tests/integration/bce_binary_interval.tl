(import stdlib.io)
(import stdlib.string)

(define (search-div
  [items : (& items (__tl_dyn-array i64))]
  [start : i64]
  [end : i64]
  [value : i64]) : i64
  (let
    [lo : i64 start]
    [hi : i64 end]
    [best : i64 -1]
    (while (<= lo hi)
      (let
        [mid : i64 (/ (+ lo hi) 2)]
        (if (<= (array-ref items mid) value)
          (begin
            (set! best mid)
            (set! lo (+ mid 1)))
          (set! hi (- mid 1)))))
    best))

(define (search-shift
  [items : (& items (__tl_dyn-array i64))]
  [base : i64]
  [start : i64]
  [end : i64]
  [value : i64]) : i64
  (let
    [lo : i64 start]
    [hi : i64 end]
    [best : i64 -1]
    (while (<= lo hi)
      (let
        [mid : i64 (shr (+ hi lo) 1)]
        (if (<= (array-ref items (+ base mid)) value)
          (begin
            (set! best mid)
            (set! lo (+ mid 1)))
          (set! hi (- mid 1)))))
    best))

(define (check-searches [items : (& items (__tl_dyn-array i64))]) : i64
  (let
    [start : i64 0]
    (while (< start 32)
      (let
        [end : i64 (- start 1)]
        (while (< end 32)
          (let
            [value : i64 -1]
            (while (< value 100)
              (let
                [expected : i64 -1]
                [i : i64 start]
                (while (<= i end)
                  (when (<= (array-ref items i) value) (set! expected i))
                  (set! i (+ i 1)))
                (unless
                  (= (search-div items start end value) expected)
                  (return 1))
                (let
                  [relative : i64
                    (search-shift items start 0 (- end start) value)]
                  (unless
                    (=
                      (if (< relative 0)
                        -1
                        (+ relative start))
                      expected)
                    (return 2))))
              (set! value (+ value 1))))
          (set! end (+ end 1))))
      (set! start (+ start 1))))
  42)

(define (main) : i64
  (let
    [mode : i64 (string.>int (io.arg 1))]
    [items : (__tl_dyn-array i64) (__tl_make-array i64 32)]
    [i : i64 0]
    (while (< i 32)
      (set! (array-ref items i) (* 3 (/ i 2)))
      (set! i (+ i 1)))
    (cond
      [(= mode 1) (search-div (& items) 0 64 100)]
      [(= mode 2) (search-shift (& items) 0 -8 -2 100)]
      [(= mode 3)
        (search-div (& items) 9223372036854775806 9223372036854775807 100)]
      [(= mode 4) (search-shift (& items) 30 0 4 100)]
      [else (check-searches (& items))])))