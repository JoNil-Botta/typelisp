(import stdlib.array)
(import stdlib.comptime)

(defmacro (integration-all [items : bool ...]) : bool
  (comptime.expr-list-fold-if
    items
    (comptime.expr-bool true)
    (comptime.expr-bool false)
    true))

(define (put-mut!
  [items : (&mut items (Array i64))]
  [index : i64]
  [value : i64]) : unit
  (array-set! items index value))

(define (push-mut! [items : (&mut items (Array i64))] [value : i64]) : unit
  (array-push! items value))

(define (dynamic-score) : i64
  (let
    [items : (Array i64) (array.make-array i64 2)]
    (begin
      (array-set! items 0 10)
      (array-set! items 1 20)
      (array-push! items 5)
      (put-mut! (&mut items) 2 12)
      (push-mut! (&mut items) 0)
      (if (= (array-length items) 4)
        (+
          (array-ref items 0)
          (+ (array-ref items 1) (+ (array-ref items 2) (array-ref items 3))))
        0))))

(define (fixed-score) : i64
  (let
    [items : (Array i64 3) (array 1 2 3)]
    (begin
      (array-set! items 1 20)
      (+ (array-ref items 0) (+ (array-ref items 1) (array-ref items 2))))))

(define (main) : i64
  (let
    [flag : bool true]
    (if (and
      (integration-all flag true)
      flag
      (= (dynamic-score) 42)
      (= (fixed-score) 24))
      42
      1)))