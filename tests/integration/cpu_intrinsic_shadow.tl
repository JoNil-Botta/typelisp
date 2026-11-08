;; Both prebound CPU names must use the entry module's visible definitions.
(define (xgetbv [_index : i64]) : i64
  9)

(define (cpuid [_leaf : i64] [_subleaf : i64]) : (Tuple i32 i32 i32 i32)
  (tuple 7 7 7 7))

(define (renamed-xgetbv [_index : i64]) : i64
  9)

(define (apply-cpu [read : (-> i64 i64)]) : i64
  (read 0))

(defmacro (read-xcr [index : Expr]) : Expr
  `(xgetbv ,index))

(define (main) : i64
  (if (and
    (= (xgetbv 0) 9)
    (= (renamed-xgetbv 0) 9)
    (= (read-xcr 0) 9)
    (= (apply-cpu xgetbv) 9)
    (= (tuple-ref (cpuid 0 0) 0) 7))
    42
    1))