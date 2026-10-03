(defenum Token
  (Ident String)
  (End))

(define (op-score [op : String]) : i64
  (match op
    ["+" 10]
    ["*" 15]
    [_ 0]))

(define (token-score [token : Token]) : i64
  (match token
    [(Ident "if") 12]
    [(Ident "else") 20]
    [(Ident _) 5]
    [(End) 0]))

(define (main) : i64
  (+
    (op-score "+")
    (+
      (op-score "/")
      (+
        (token-score (Ident "if"))
        (+ (token-score (Ident "while")) (+ (token-score (End)) (op-score "*")))))))