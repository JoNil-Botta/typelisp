;; Uniform receiver/index/value writes keep their scalar result for empty,
;; full-gang and tail domains; neighboring elements remain untouched. Ordered
;; scans store varying prefixes through uniform destinations, including from a
;; helper and into an array element's field.
(defstruct Total
  (sum i64)
  (count i64))

(define (store-first [out : (&mut out (Array i64 2))] [value : i64]) : unit
  (set! (array-ref out 0) value))

(define (main) : i32
  (let
    [out : (Array i64 2) (array -1 0)]
    [scan-out : (Array i64 2) (array -1 0)]
    [helper-out : (Array i64 2) (array 0 -1)]
    [totals : (Array Total 2) (array (Total 0 0) (Total 0 0))]
    [summary : Total (Total 0 0)]
    [slot : i64 1]
    [answer : i64 42]
    (begin
      (foreach ([_i : i64 3 3]) (set! (array-ref out 0) 99))
      (foreach ([_i : i64 5 2]) (set! (array-ref out 0) 99))
      (foreach ([_i : i64 0 9]) (set! (array-ref out slot) answer))
      (foreach ([_i : i64 0 9]) (set! summary.count answer))
      (spmd-scan
        sum
        ([i : i64 0 3] [prefix : i64 0])
        (+ i 1)
        (set! (array-ref scan-out 1) prefix))
      (spmd-scan
        sum
        ([_i : i64 0 0] [prefix : i64 99])
        (array-ref scan-out 99)
        (set! (array-ref scan-out 99) prefix))
      (spmd-scan
        sum
        ([i : i64 0 9] [prefix : i64 0])
        (+ i 1)
        (store-first (&mut helper-out) prefix))
      (spmd-scan
        sum
        ([i : i64 0 9] [prefix : i64 0])
        (+ i 1)
        (set! (array-ref totals 1).sum prefix))
      (if (and
        (= (array-ref out 0) -1)
        (= (array-ref out 1) 42)
        (= (array-ref scan-out 0) -1)
        (= (array-ref scan-out 1) 6)
        (= (array-ref helper-out 0) 45)
        (= (array-ref helper-out 1) -1)
        (= (array-ref totals 0).sum 0)
        (= (array-ref totals 1).sum 45)
        (= summary.sum 0)
        (= summary.count 42))
        42
        1))))