(defstruct Pair
  (x i64)
  (y i64))

(define (box-set-score) : i64
  (let
    [cell : (Box i64) (box 5)]
    (begin
      (set! (deref cell) 11)
      (__tl-box-place cell))))

(define (boxed-field-set-score) : i64
  (let
    [cell : (Box Pair) (box (Pair 1 2))]
    (begin
      (__tl-project-set-field (__tl-box-place cell) x 19)
      (+
        (__tl-project-field (__tl-box-place cell) x)
        (__tl-project-field (__tl-box-place cell) y)))))

(define (set-pair-x! [pair : (&mut pair Pair)] [value : i64]) : unit
  (set! pair.x value))

(define (boxed-mut-borrow-score) : i64
  (let
    [cell : (Box Pair) (box (Pair 4 5))]
    (begin
      (set-pair-x! (&mut (__tl-box-place cell)) 37)
      (+
        (__tl-project-field (__tl-box-place cell) x)
        (__tl-project-field (__tl-box-place cell) y)))))

(define (box-take-score) : i64
  (let
    [cell : (Box i64) (box 10)]
    [value : i64 (deref cell)]
    value))

(define (main) : i64
  (if (and
    (= (box-set-score) 11)
    (= (boxed-field-set-score) 21)
    (= (boxed-mut-borrow-score) 42)
    (= (box-take-score) 10))
    42
    1))