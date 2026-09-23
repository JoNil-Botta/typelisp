;; Runtime bounds exercise every remainder around the sixteen-copy group.
(import stdlib.io)
(import stdlib.string)

(define (sum-forward [xs : (& xs (__tl_dyn-array i64))] [n : i64] [seed : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 seed]
    (begin
      (while (< i n)
        (begin
          (set! sum (+ sum (array-ref xs i)))
          (set! i (+ i 1))))
      sum)))

(define (sum-reverse [xs : (& xs (__tl_dyn-array i64))] [n : i64] [seed : i64]) : i64
  (let
    [i : i64 (- n 1)]
    [sum : i64 seed]
    (begin
      (while (>= i 0)
        (begin
          (set! sum (+ (array-ref xs i) sum))
          (set! i (- i 1))))
      sum)))

(define (sum-unsigned [xs : (& xs (__tl_dyn-array u64))] [n : i64] [seed : u64]) : u64
  (let
    [i : i64 0]
    [sum : u64 seed]
    (begin
      (while (< i n)
        (begin
          (set! sum (+ sum (array-ref xs i)))
          (set! i (+ i 1))))
      sum)))

(define (main) : i64
  (let
    [capacity : i64 129]
    [base : i64 9223372036854775776]
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 capacity)]
    [us : (__tl_dyn-array u64) (__tl_make-array u64 capacity)]
    [i : i64 0]
    [seed : i64 (+ 73 (io.arg-count))]
    [ok : bool true]
    (begin
      (while (< i capacity)
        (begin
          (set! (array-ref xs i) (+ base i))
          (set! (array-ref us i) (cast (+ base i) : u64))
          (set! i (+ i 1))))
      (if (> (io.arg-count) 1)
        (sum-forward (& xs) (string.>int (io.arg 1)) seed)
        (begin
          (set! i 0)
          (while (<= i capacity)
            (let
              [want : i64 (+ seed (* base i) (/ (* i (- i 1)) 2))]
              (begin
                (set!
                  ok
                  (and
                    ok
                    (= (sum-forward (& xs) i seed) want)
                    (= (sum-reverse (& xs) i seed) want)
                    (=
                      (sum-unsigned (& us) i (cast seed : u64))
                      (cast want : u64))))
                (set! i (+ i 1)))))
          (if ok
            42
            1))))))