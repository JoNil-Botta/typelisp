;; A delayed invariant call must run only when its source site is reached.
;; The denominator also exercises first-call traps without speculative calls.
(import stdlib.io)
(import stdlib.string)

(define (expensive-read [values : (& values (__tl_dyn-array i64))] [den : i64]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i (array-length values))
        (begin
          (set! total (+ total (array-ref values i)))
          (set! i (+ i 1))))
      (/ total den))))

(define (delayed
  [values : (& values (__tl_dyn-array i64))]
  [rounds : i64]
  [start : i64]
  [den : i64]
  [shift : i64]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (begin
      (while (< i rounds)
        (begin
          (set! total (+ total (shl 1 shift)))
          (when (>= i start) (set! total (+ total (expensive-read values den))))
          (set! i (+ i 1))))
      total)))

(define (mutating [values : (&mut values (__tl_dyn-array i64))] [rounds : i64]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    [one : i64 1]
    (begin
      (while (< i rounds)
        (begin
          (set! total (+ total (expensive-read values one)))
          (set! (array-ref values 0) (+ (array-ref values 0) 1))
          (set! i (+ i 1))))
      total)))

(define (nested [values : (&mut values (__tl_dyn-array i64))]) : i64
  (let
    [outer : i64 0]
    [inner : i64 0]
    [total : i64 0]
    [one : i64 1]
    (begin
      (while (< outer 4)
        (begin
          (set! (array-ref values 0) outer)
          (set! inner 0)
          (while (< inner 5)
            (begin
              (when
                (> inner 1)
                (set! total (+ total (expensive-read values one))))
              (set! inner (+ inner 1))))
          (set! outer (+ outer 1))))
      total)))

(define (varying [values : (& values (__tl_dyn-array i64))]) : i64
  (let
    [i : i64 1]
    [total : i64 0]
    (begin
      (while (< i 5)
        (begin
          (set! total (+ total (expensive-read values i)))
          (set! i (+ i 1))))
      total)))

(define (main) : i64
  (let
    [mode : i64 (string.>int (io.arg 1))]
    [values : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [i : i64 0]
    (begin
      (while (< i 8)
        (begin
          (set! (array-ref values i) (+ i 1))
          (set! i (+ i 1))))
      (cond
        [(= mode 1) (io.println "{}" (delayed (& values) 0 0 0 -1))]
        [(= mode 2) (io.println "{}" (delayed (& values) 5 5 0 0))]
        [(= mode 3) (io.println "{}" (delayed (& values) 5 2 2 0))]
        [(= mode 4) (io.println "{}" (delayed (& values) 5 2 0 0))]
        [(= mode 5) (io.println "{}" (delayed (& values) 5 0 0 -1))]
        [(= mode 6) (io.println "{}" (mutating (&mut values) 5))]
        [(= mode 7) (io.println "{}" (nested (&mut values)))]
        [(= mode 8) (io.println "{}" (varying (& values)))]
        [else (io.println "{}" (delayed (& values) -2 0 0 -1))])
      0)))