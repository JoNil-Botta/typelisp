(defstruct Pair
  (left i64)
  (right i64))

(defenum Op
  (Add)
  (Mul)
  (Sub))

(define (apply-op [op : Op] [pair : Pair]) : i64
  (match op
    [(Add) (+ (struct-get pair left) (struct-get pair right))]
    [(Mul) (% (* (struct-get pair left) (struct-get pair right)) 1000000007)]
    [(Sub) (- (struct-get pair left) (struct-get pair right))]))

(define (choose [i : i64]) : Op
  (if (= (% i 3) 0)
    Add
    (if (= (% i 3) 1)
      Mul
      Sub)))

(define (bench [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set!
            acc
            (% (+ acc (apply-op (choose i) (Pair i (+ i 1)))) 1000000007))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string->int (arg 1))]
    (begin
      (print (bench n))
      0)))