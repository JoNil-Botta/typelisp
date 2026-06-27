(import stdlib.array)

(define (put-mut!
  [items : (&mut items (Array i64))]
  [index : i64]
  [value : i64]) : unit
  (array.array-set! items index value))

(define (push-mut! [items : (&mut items (Array i64))] [value : i64]) : unit
  (array.array-push! items value))

(define (dynamic-score) : i64
  (let
    [items : (Array i64) (array.make-array i64 2)]
    (begin
      (array.array-set! items 0 10)
      (array.array-set! items 1 20)
      (array.array-push! items 5)
      (put-mut! (&mut items) 2 12)
      (push-mut! (&mut items) 0)
      (if (= (array.array-length items) 4)
        (+
          (array.array-ref items 0)
          (+
            (array.array-ref items 1)
            (+ (array.array-ref items 2) (array.array-ref items 3))))
        0))))

(define (fixed-score) : i64
  (let
    [items : (Array i64 3) (array 1 2 3)]
    (begin
      (array.array-set! items 1 20)
      (+
        (array.array-ref items 0)
        (+ (array.array-ref items 1) (array.array-ref items 2))))))

(define (main) : i64
  (if (and (= (dynamic-score) 42) (= (fixed-score) 24))
    42
    1))