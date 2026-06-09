; Indirect tail calls through a local function value reuse the current frame
; instead of growing the stack (#2363).
(define (loop [n : i64] [acc : i64]) : i64
  (let
    [again : (-> i64 i64 i64) loop]
    (if (= n 0)
      acc
      (again (- n 1) (+ acc 1)))))

(define (main) : i64
  (if (= (loop 100000 0) 100000)
    42
    1))