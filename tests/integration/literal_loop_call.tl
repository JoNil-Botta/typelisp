(import stdlib.io)

(define global-count : i64
  0)

(define (read-sum [values : (& values (__tl_dyn-array i64))] [divisor : i64]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i (array-length values))
        (begin
          (set! total (+ total (array-ref values i)))
          (set! i (+ i 1))))
      (/ total divisor))))

(define (bump-array [values : (&mut values (__tl_dyn-array i64))]) : unit
  (set! (array-ref values 0) (+ (array-ref values 0) 1)))

(define (bump-global) : unit
  (set! global-count (+ global-count 1)))

(define (read-global [values : (& values (__tl_dyn-array i64))] [divisor : i64]) : i64
  (+ (read-sum values divisor) global-count))

(define (delayed
  [values : (& values (__tl_dyn-array i64))]
  [rounds : i64]
  [start : i64]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i rounds)
        (begin
          (when (>= i start) (set! total (+ total (read-sum values 2))))
          (set! i (+ i 1))))
      total)))

(define (never-reached
  [values : (& values (__tl_dyn-array i64))]
  [rounds : i64]
  [start : i64]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i rounds)
        (begin
          (when (>= i start) (set! total (+ total (read-sum values 0))))
          (set! i (+ i 1))))
      total)))

(define (mutating [values : (&mut values (__tl_dyn-array i64))]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i 5)
        (begin
          (set! total (+ total (read-sum values 1)))
          (bump-array values)
          (set! i (+ i 1))))
      total)))

(define (global-mutating [values : (& values (__tl_dyn-array i64))]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i 5)
        (begin
          (set! total (+ total (read-global values 1)))
          (bump-global)
          (set! i (+ i 1))))
      total)))

(define (main) : i64
  (let
    [values : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [i : i64 0]
    (begin
      (while (< i 8)
        (begin
          (set! (array-ref values i) (+ i 1))
          (set! i (+ i 1))))
      (io.println
        "{} {} {} {} {} {} {}"
        (delayed (& values) 0 0)
        (delayed (& values) 5 5)
        (delayed (& values) 5 2)
        (mutating (&mut values))
        (global-mutating (& values))
        (never-reached (& values) (- (io.arg-count) 1) 0)
        (never-reached (& values) 5 5))
      0)))