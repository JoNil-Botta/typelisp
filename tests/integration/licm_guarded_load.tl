(import stdlib.io)
(import stdlib.string)

(define (selected-sum
  [items : (__tl_dyn-array i64)]
  [index : i64]
  [trips : i64]
  [first : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i trips)
        (begin
          (when (>= i first) (set! sum (+ sum (array-ref items index))))
          (set! i (+ i 1))))
      sum)))

(define (selected-float-sum
  [items : (__tl_dyn-array f64)]
  [index : i64]
  [trips : i64]
  [first : i64]) : f64
  (let
    [i : i64 0]
    [sum : f64 0.0]
    (begin
      (while (< i trips)
        (begin
          (when (>= i first) (set! sum (+ sum (array-ref items index))))
          (set! i (+ i 1))))
      sum)))

(define (selected-nested-sum
  [items : (__tl_dyn-array i64)]
  [index : i64]
  [trips : i64]
  [first : i64]
  [outer : i64]) : i64
  (let
    [round : i64 0]
    [sum : i64 0]
    (begin
      (while (< round outer)
        (let
          [i : i64 0]
          (begin
            (while (< i trips)
              (begin
                (when (>= i first) (set! sum (+ sum (array-ref items index))))
                (set! i (+ i 1))))
            (set! round (+ round 1)))))
      sum)))

(define (selected-handle-length
  [items : (__tl_dyn-array String)]
  [index : i64]
  [trips : i64]
  [first : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i trips)
        (begin
          (when
            (>= i first)
            (set!
              sum
              (+ sum (string.string-length (& (array-ref items index))))))
          (set! i (+ i 1))))
      sum)))

(define (main) : i64
  (let
    [index : i64 (string.>int (io.arg 1))]
    [length : i64 (string.>int (io.arg 2))]
    [trips : i64 (string.>int (io.arg 3))]
    [first : i64 (string.>int (io.arg 4))]
    [selected : i64 (string.>int (io.arg 5))]
    [items : (__tl_dyn-array i64) (__tl_make-array i64 length)]
    [floats : (__tl_dyn-array f64) (__tl_make-array f64 length)]
    [nested-items : (__tl_dyn-array i64) (__tl_make-array i64 length)]
    [texts : (__tl_dyn-array String) (__tl_make-array String length)]
    [i : i64 0]
    (begin
      (while (< i length)
        (begin
          (set! (array-ref items i) 42)
          (set! (array-ref floats i) 1.5)
          (set! (array-ref nested-items i) 42)
          (set! (array-ref texts i) "1234567")
          (set! i (+ i 1))))
      (cond
        [(= selected -1)
          (begin
            (selected-float-sum floats index trips first)
            1)]
        [(= selected -2)
          (if (= (selected-nested-sum nested-items index trips first 0) 0)
            42
            1)]
        [(= selected -3)
          (begin
            (selected-handle-length texts index trips first)
            1)]
        [(and
            (= (selected-sum items index trips first) (* selected 42))
            (=
              (selected-float-sum floats index trips first)
              (* (cast selected : f64) 1.5))
            (=
              (selected-nested-sum nested-items index trips first 3)
              (* selected 126))
            (= (selected-handle-length texts index trips first) (* selected 7)))
          42]
        [else 1]))))