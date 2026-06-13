(import "stdlib/core_macros.tl" module stdlib.core_macros as core)

(defenum BinOp
  (OpAdd)
  (OpSub)
  (OpMul)
  (OpUnknown))

(define (parse-op [op : char]) : BinOp
  (core/cond
    (= op #+')
    (OpAdd)
    (= op #-')
    (OpSub)
    (= op #*')
    (OpMul)
    (OpUnknown)))

(define (score [op : BinOp]) : i64
  (match op
    [(OpAdd) 10]
    [(OpSub) 20]
    [(OpMul) 12]
    [(OpUnknown) 0]))

(define (main) : i64
  (+
    (score (parse-op #+'))
    (+ (score (parse-op #-')) (+ (score (parse-op #*')) (score (parse-op #/'))))))