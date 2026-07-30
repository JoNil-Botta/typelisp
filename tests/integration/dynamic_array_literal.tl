(define dynamic-array-literal-trace : i64
  0)

(define (dynamic-array-literal-mark [value : i64]) : i64
  (begin
    (set!
      dynamic-array-literal-trace
      (+ (* dynamic-array-literal-trace 10) value))
    (* value 2)))

(define (dynamic-array-literal-score) : i64
  (let
    [items : (__tl_dyn-array i64)
      (make-array
        (dynamic-array-literal-mark 1)
        (dynamic-array-literal-mark 2)
        (dynamic-array-literal-mark 3))]
    (if (= dynamic-array-literal-trace 123)
      (+
        (array-length items)
        (+ (array-ref items 0) (+ (array-ref items 1) (array-ref items 2))))
      0)))

(define (dynamic-array-literal-init-score) : i64
  (let
    [items : (__tl_dyn-array i64) (make-array (init) 5)]
    (+ (array-length items) (+ (array-ref items 0) (array-ref items 1)))))

(define (dynamic-array-literal-empty-score) : i64
  (let
    [items : (__tl_dyn-array i64) (make-array)]
    (array-length items)))

(define (main) : i64
  (if (and
    (= (dynamic-array-literal-score) 15)
    (= (dynamic-array-literal-init-score) 7)
    (= (dynamic-array-literal-empty-score) 0))
    42
    1))