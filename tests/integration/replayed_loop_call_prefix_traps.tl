;; Trapping prefixes retain one source-span identity before the cached call.
(import stdlib.io)
(import stdlib.string)

(define (probe [values : (& values (__tl_dyn-array i64))]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i (array-length values))
        (begin
          (set! total (+ total (array-ref values i)))
          (set! i (+ i 1))))
      total)))

(define (divide [values : (& values (__tl_dyn-array i64))] [j : i64]) : i64
  (let
    [total : i64 0]
    (begin
      (while (> j -2)
        (begin
          (set! total (+ (/ 60 j) (probe values)))
          (set! j (- j 1))))
      total)))

(define (remainder [values : (& values (__tl_dyn-array i64))] [j : i64]) : i64
  (let
    [total : i64 0]
    (begin
      (while (> j -2)
        (begin
          (set! total (+ (% 60 j) (probe values)))
          (set! j (- j 1))))
      total)))

(define (left [values : (& values (__tl_dyn-array i64))] [j : i64]) : i64
  (let
    [total : i64 0]
    (begin
      (while (> j -2)
        (begin
          (set! total (+ (shl 1 j) (probe values)))
          (set! j (- j 1))))
      total)))

(define (right [values : (& values (__tl_dyn-array i64))] [j : i64]) : i64
  (let
    [total : i64 0]
    (begin
      (while (> j -2)
        (begin
          (set! total (+ (shr 64 j) (probe values)))
          (set! j (- j 1))))
      total)))

(define (main) : i64
  (let
    [values : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [mode : i64 (string.>int (io.arg 1))]
    [start : i64 (string.>int (io.arg 2))]
    (begin
      (io.println
        "{}"
        (cond
          [(= mode 0) (divide (& values) start)]
          [(= mode 1) (remainder (& values) start)]
          [(= mode 2) (left (& values) start)]
          [else (right (& values) start)]))
      0)))