(define seen : i64
  0)

(define (inc [x : i64]) : i64
  (+ x 1))

(define (dec [x : i64]) : i64
  (- x 1))

(define (mark) : unit
  (set! seen 42))

(define (apply1 [f : (-> i64 i64)] [x : i64]) : i64
  (f x))

(define (apply0u [f : (-> unit)]) : unit
  (f))

(define (shadow-inc [inc : (-> i64 i64)] [x : i64]) : i64
  (inc x))

(define (main) : i64
  (begin
    (apply0u mark)
    (if (= (apply1 inc 41) 42)
      (if (= (shadow-inc dec 43) 42)
        (if (= seen 42)
          42
          3)
        2)
      1)))