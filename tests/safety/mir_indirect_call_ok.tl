;: Calls through function values (parameters and locals) are checked like
;: direct calls: operands are consumed, and the callee is a Copy value.
(define (add-one [n : i64]) : i64
  (+ n 1))

(define (apply-twice [f : (-> i64 i64)] [n : i64]) : i64
  (f (f n)))

(define (main) : i64
  (let
    [g : (-> i64 i64) add-one]
    (+ (apply-twice g 38) (g 1))))