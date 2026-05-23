(define (init-i64 [a : (Array i64)] [b : (Array i64)] [n : i64]) : unit
  (let ([i : i64 0])
    (while (< i n)
      (begin
        (array-set! a i (+ i 1))
        (array-set! b i (* i 2))
        (set! i (+ i 1))))))

(define (fill-i64-foreach [a : (Array i64)]
                          [b : (Array i64)]
                          [out : (Array i64)]
                          [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))

(define (fill-i64-scalar [a : (Array i64)]
                         [b : (Array i64)]
                         [out : (Array i64)]
                         [n : i64]) : unit
  (let ([i : i64 0])
    (while (< i n)
      (begin
        (array-set! out i (+ (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

(define (eq-i64 [a : (Array i64)] [b : (Array i64)] [n : i64]) : bool
  (let ([i : i64 0] [ok : bool true])
    (begin
      (while (< i n)
        (begin
          (if (!= (array-ref a i) (array-ref b i))
              (set! ok false)
              unit)
          (set! i (+ i 1))))
      ok)))

(define (case-i64 [n : i64]) : bool
  (let ([a : (Array i64) (make-array i64 n)]
        [b : (Array i64) (make-array i64 n)]
        [got : (Array i64) (make-array i64 n)]
        [want : (Array i64) (make-array i64 n)])
    (begin
      (init-i64 a b n)
      (fill-i64-foreach a b got n)
      (fill-i64-scalar a b want n)
      (eq-i64 got want n))))

(define (init-i32 [a : (Array i32)] [b : (Array i32)] [n : i64]) : unit
  (let ([i : i64 0])
    (while (< i n)
      (begin
        (array-set! a i (cast (+ i 1) : i32))
        (array-set! b i (cast (* i 2) : i32))
        (set! i (+ i 1))))))

(define (fill-i32-foreach [a : (Array i32)]
                          [b : (Array i32)]
                          [out : (Array i32)]
                          [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))

(define (fill-i32-scalar [a : (Array i32)]
                         [b : (Array i32)]
                         [out : (Array i32)]
                         [n : i64]) : unit
  (let ([i : i64 0])
    (while (< i n)
      (begin
        (array-set! out i (+ (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

(define (eq-i32 [a : (Array i32)] [b : (Array i32)] [n : i64]) : bool
  (let ([i : i64 0] [ok : bool true])
    (begin
      (while (< i n)
        (begin
          (if (!= (array-ref a i) (array-ref b i))
              (set! ok false)
              unit)
          (set! i (+ i 1))))
      ok)))

(define (case-i32 [n : i64]) : bool
  (let ([a : (Array i32) (make-array i32 n)]
        [b : (Array i32) (make-array i32 n)]
        [got : (Array i32) (make-array i32 n)]
        [want : (Array i32) (make-array i32 n)])
    (begin
      (init-i32 a b n)
      (fill-i32-foreach a b got n)
      (fill-i32-scalar a b want n)
      (eq-i32 got want n))))

(define (init-f64 [a : (Array f64)] [b : (Array f64)] [n : i64]) : unit
  (let ([i : i64 0])
    (while (< i n)
      (begin
        (array-set! a i 1.5)
        (array-set! b i 2.25)
        (set! i (+ i 1))))))

(define (fill-f64-foreach [a : (Array f64)]
                          [b : (Array f64)]
                          [out : (Array f64)]
                          [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))

(define (fill-f64-scalar [a : (Array f64)]
                         [b : (Array f64)]
                         [out : (Array f64)]
                         [n : i64]) : unit
  (let ([i : i64 0])
    (while (< i n)
      (begin
        (array-set! out i (+ (array-ref a i) (array-ref b i)))
        (set! i (+ i 1))))))

(define (eq-f64 [a : (Array f64)] [b : (Array f64)] [n : i64]) : bool
  (let ([i : i64 0] [ok : bool true])
    (begin
      (while (< i n)
        (begin
          (if (!= (array-ref a i) (array-ref b i))
              (set! ok false)
              unit)
          (set! i (+ i 1))))
      ok)))

(define (case-f64 [n : i64]) : bool
  (let ([a : (Array f64) (make-array f64 n)]
        [b : (Array f64) (make-array f64 n)]
        [got : (Array f64) (make-array f64 n)]
        [want : (Array f64) (make-array f64 n)])
    (begin
      (init-f64 a b n)
      (fill-f64-foreach a b got n)
      (fill-f64-scalar a b want n)
      (eq-f64 got want n))))

(define (case-end-bound-evaluated-once) : bool
  (let ([bounds : (Array i64) (make-array i64 1)]
        [out : (Array i64) (make-array i64 3)])
    (begin
      (array-set! bounds 0 3)
      (array-set! out 0 0)
      (array-set! out 1 0)
      (array-set! out 2 0)
      (foreach ([i : i64 0 (array-ref bounds 0)])
        (begin
          (array-set! bounds 0 0)
          (array-set! out i (+ i 1))))
      (= (array-ref out 2) 3))))

(define (case-index-binding-is-scoped) : bool
  (= (let ([i : i64 7])
       (begin
         (foreach ([i : i64 0 3]) unit)
         i))
     7))

(define (all-cases) : bool
  (let ([ok : bool true])
    (begin
      (if (case-i64 0) unit (set! ok false))
      (if (case-i64 3) unit (set! ok false))
      (if (case-i64 4) unit (set! ok false))
      (if (case-i64 9) unit (set! ok false))
      (if (case-i32 0) unit (set! ok false))
      (if (case-i32 3) unit (set! ok false))
      (if (case-i32 8) unit (set! ok false))
      (if (case-i32 9) unit (set! ok false))
      (if (case-f64 0) unit (set! ok false))
      (if (case-f64 3) unit (set! ok false))
      (if (case-f64 4) unit (set! ok false))
      (if (case-f64 9) unit (set! ok false))
      (if (case-end-bound-evaluated-once) unit (set! ok false))
      (if (case-index-binding-is-scoped) unit (set! ok false))
      ok)))

(define (main) : i64
  (if (all-cases) 42 1))
