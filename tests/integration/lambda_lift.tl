(define (apply1 [f : (-> i64 i64)] [x : i64]) : i64
  (f x))

(define (case-immediate) : bool
  (= ((lambda ([x : i64]) : i64 (+ x 1)) 41) 42))

(define (case-let-bound) : bool
  (= (let ([f : (-> i64 i64) (lambda ([x : i64]) : i64 (* x 2))])
       (f 21))
     42))

(define (case-lambda-arg) : bool
  (= (apply1 (lambda ([x : i64]) : i64 (+ x 10)) 32) 42))

(define (case-unit-returning) : bool
  (begin
    ((lambda () : unit unit))
    true))

(define (all-cases) : bool
  (let ([ok : bool true])
    (begin
      (if (case-immediate) unit (set! ok false))
      (if (case-let-bound) unit (set! ok false))
      (if (case-lambda-arg) unit (set! ok false))
      (if (case-unit-returning) unit (set! ok false))
      ok)))

(define (main) : i64
  (if (all-cases) 42 1))
