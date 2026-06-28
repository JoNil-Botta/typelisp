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
    [(Token.Ident "if") 12]
    [(Token.Ident "else") 20]
    [(Token.Ident _) 5]
    [(Token.End) 0]))

(define (main) : i64
  (+
    (op-score "+")
    (+
      (op-score "/")
      (+
        (token-score (Token.Ident "if"))
        (+
          (token-score (Token.Ident "while"))
          (+ (token-score (Token.End)) (op-score "*")))))))