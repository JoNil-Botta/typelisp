;; Full SIMD gangs use an all-active parent state while tails and divergent
;; children retain real masks. Exercise zero, short, exact-width, and partial
;; ranges, including a child branch whose active mask is always empty.
(import stdlib.array)

(define capacity : i64
  16)

(define (classify [value : i64]) : i64
  (if (< value -1000)
    -99
    (if (< value 0)
      -1
      (if (= (bit-and value 1) 0)
        2
        3))))

(define (fill
  [xs : (Array i64)]
  [copy : (Array i64)]
  [out : (Array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [value : i64 (array-ref xs i)]
      (begin
        ;; Parent-only accesses should be ordinary vector operations in full
        ;; gangs and predicated operations in the final partial gang.
        (array-set! copy i value)
        (if (< value -1000)
          (array-set! out i -99)
          (if (< value 0)
            (array-set! out i -1)
            (if (= (bit-and value 1) 0)
              (array-set! out i 2)
              (array-set! out i 3))))))))

(define (run-case [n : i64]) : bool
  (let
    [xs : (Array i64) (array.make-array i64 capacity)]
    [copy : (Array i64) (array.make-array i64 capacity)]
    [out : (Array i64) (array.make-array i64 capacity)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i capacity)
        (begin
          (array-set! xs i (- i 5))
          (array-set! copy i 777)
          (array-set! out i 888)
          (set! i (+ i 1))))
      (fill xs copy out n)
      (set! i 0)
      (while (< i capacity)
        (let
          [value : i64 (array-ref xs i)]
          [expected-copy : i64
            (if (< i n)
              value
              777)]
          [expected-out : i64
            (if (< i n)
              (classify value)
              888)]
          (begin
            (if (or
              (!= (array-ref copy i) expected-copy)
              (!= (array-ref out i) expected-out))
              (set! ok false)
              unit)
            (set! i (+ i 1)))))
      ok)))

(define (main) : i64
  (if (and
    (run-case 0)
    (run-case 2)
    (run-case 4)
    (run-case 8)
    (run-case 13)
    (run-case 16))
    42
    1))