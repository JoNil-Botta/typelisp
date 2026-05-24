(define (apply1 [f : (-> i64 i64)] [x : i64]) : i64
  (f x))

(define (case-immediate) : bool
  (let ([n : i64 10])
    (= ((lambda ([x : i64]) : i64 (+ x n)) 32) 42)))

(define (case-passed-as-arg) : bool
  (let ([n : i64 10])
    (= (apply1 (lambda ([x : i64]) : i64 (+ x n)) 32) 42)))

(define (case-mixed-scalars) : bool
  (let ([n : i64 32] [ok : bool true] [ch : char #A'] [scale : f64 2.5])
    (=
      ((lambda
          ([x : i64])
          :
          i64
          (if ok
            (if (= ch #A')
              (if (= scale 2.5)
                (+ x n)
                0)
              0)
            0))
        10)
      42)))

(define (case-function-capture) : bool
  (let ([inc : (-> i64 i64) (lambda ([x : i64]) : i64 (+ x 1))] [n : i64 9])
    (= ((lambda ([x : i64]) : i64 (inc (+ x n))) 32) 42)))

(define (case-snapshot) : bool
  (let ([n : i64 10] [f : (-> i64 i64) (lambda ([x : i64]) : i64 (+ x n))])
    (begin
      (set! n 100)
      (= (f 32) 42))))

(define (case-nested) : bool
  (let ([outer : i64 7])
    (let ([make
        :
        (-> i64 (-> i64 i64))
        (lambda
          ([add : i64])
          :
          (-> i64 i64)
          (lambda ([x : i64]) : i64 (+ x (+ outer add))))])
      (= ((make 3) 32) 42))))

(define (case-shadowed-capture) : bool
  (let ([n : i64 10])
    (=
      ((lambda
          ([x : i64])
          :
          i64
          (+
            n
            (let ([n : i64 100])
              (+ x n))))
        32)
      142)))

(define (main) : i64
  (if (case-immediate)
    (if (case-passed-as-arg)
      (if (case-mixed-scalars)
        (if (case-function-capture)
          (if (case-snapshot)
            (if (case-nested)
              (if (case-shadowed-capture)
                42
                7)
              6)
            5)
          4)
        3)
      2)
    1))