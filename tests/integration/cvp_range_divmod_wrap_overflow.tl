(import stdlib.io)

;; Exercises the bounded modular linear recurrence across:
;;   1. Small n (fast unrolled u64 RoundUp magic path);
;;   2. Wrapping overflow past INT64_MAX (n > 542551294462045624 boundary and
;;      a scaled-stride loop that actually crosses INT64_MAX into negative
;;      wrapping i64 remainder via the scalar tail);
;;   3. Direct step starting at i = 542551294462045620..542551294462045630
;;      crossing the exact 542551294462045624 overflow threshold.
(define (recurrence-small [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 1]
    (while (< i n)
      (set! acc (% (+ (* acc 31) (+ (* i 17) 7)) 1000000007))
      (set! i (+ i 1)))
    acc))

(define (recurrence-wrap-stride [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 1]
    (while (< i n)
      (set! acc (% (+ (* acc 31) (+ (* i 100000000000000000) 7)) 1000000007))
      (set! i (+ i 1)))
    acc))

(define (recurrence-threshold [start : i64] [stop : i64]) : i64
  (let
    [i : i64 start]
    [acc : i64 1000000006]
    (while (< i stop)
      (set! acc (% (+ (* acc 31) (+ (* i 17) 7)) 1000000007))
      (set! i (+ i 1)))
    acc))

(define (main) : i64
  (let
    [a : i64 (recurrence-small 1000)]
    [b : i64 (recurrence-wrap-stride 100)]
    [c : i64 (recurrence-threshold 542551294462045620 542551294462045630)]
    [d : i64 (recurrence-threshold 542551294462045625 542551294462045626)]
    (io.println "{} {} {} {}" a b c d)
    (if (and (= a 330637357) (= b -821813502) (= c 673175210) (< d 0))
      42
      1)))