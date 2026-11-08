(define (read-xcr [xgetbv : (-> bool i32)]) : i32
  (xgetbv true))

(define (read-cpu [cpuid : (-> i64 i64)]) : i64
  (cpuid 4))

(define (main) : i64
  (let
    [xgetbv : (-> bool i32)
      (lambda ([enabled : bool]) : i32
        (if enabled
          9
          8))]
    [cpuid : (-> i64 i64)
      (lambda ([value : i64]) : i64
        (+ value 13))]
    (if (and
      (= (xgetbv true) 9)
      (= (read-xcr xgetbv) 9)
      (= (cpuid 4) 17)
      (= (read-cpu cpuid) 17))
      42
      1)))