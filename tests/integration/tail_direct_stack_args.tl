; Direct non-self tail calls with stack-passed arguments must stage incoming
; stack homes before writing the callee-observed stack layout (#2362).
(define (even-stack
  [n : i64]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [acc : i64]) : i64
  (if (= n 0)
    (if (= f 17)
      acc
      1)
    (odd-stack (- n 1) a b c d e acc f)))

(define (odd-stack
  [n : i64]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [acc : i64]) : i64
  (if (= n 0)
    (if (= f 17)
      acc
      2)
    (even-stack (- n 1) a b c d e acc f)))

(define (main) : i64
  (even-stack 100000 1 2 3 4 5 17 42))