;; Cross-target IR equality uses scalar returns; native controls separately
;; cover cpuid tuples and their target-specific aggregate return conventions.
(define (xgetbv [_index : i64]) : i64
  9)

(define (apply-cpu [read : (-> i64 i64)]) : i64
  (read 0))

(defmacro (read-xcr [index : Expr]) : Expr
  `(xgetbv ,index))

(define (main) : i64
  (if (and (= (xgetbv 0) 9) (= (read-xcr 0) 9) (= (apply-cpu xgetbv) 9))
    42
    1))