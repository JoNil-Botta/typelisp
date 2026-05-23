(defenum BinOp (OpAdd) (OpSub) (OpMul) (OpUnknown))

(define (parse-op [op : i64]) : BinOp
  (cond
    [(= op 43) (OpAdd)]
    [(= op 45) (OpSub)]
    [(= op 42) (OpMul)]
    [else (OpUnknown)]))

(define (score [op : BinOp]) : i64
  (match op
    [(OpAdd) 10]
    [(OpSub) 20]
    [(OpMul) 12]
    [(OpUnknown) 0]))

(define (main) : i64
  (+ (score (parse-op 43))
     (+ (score (parse-op 45))
        (+ (score (parse-op 42))
           (score (parse-op 47))))))
