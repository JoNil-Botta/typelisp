(defstruct Pair
  (x i64)
  (y i64))

(define (box-set-score) : i64
  (let
    [cell : (Box i64) (box 5)]
    (begin
      (set! (box-get cell) 11)
      (box-get cell))))

(define (boxed-field-set-score) : i64
  (let
    [cell : (Box Pair) (box (Pair 1 2))]
    (begin
      (set! (struct-get (box-get cell) x) 19)
      (+ (struct-get (box-get cell) x) (struct-get (box-get cell) y)))))

(define (set-pair-x! [pair : (&mut pair Pair)] [value : i64]) : unit
  (set! (struct-get pair x) value))

(define (boxed-mut-borrow-score) : i64
  (let
    [cell : (Box Pair) (box (Pair 4 5))]
    (begin
      (set-pair-x! (&mut (box-get cell)) 37)
      (+ (struct-get (box-get cell) x) (struct-get (box-get cell) y)))))

(define (box-take-score) : i64
  (let
    [cell : (Box i64) (box 10)]
    [value : i64 (box-take cell)]
    value))

(define (main) : i64
  (if (and
    (= (box-set-score) 11)
    (= (boxed-field-set-score) 21)
    (= (boxed-mut-borrow-score) 42)
    (= (box-take-score) 10))
    42
    1))