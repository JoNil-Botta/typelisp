(defenum Token
  (TIdent String)
  (TEnd))

(define (op-score [op : String]) : i64
  (match op
    ["+" 10]
    ["*" 15]
    [_ 0]))

(define (token-score [token : Token]) : i64
  (match token
    [(TIdent "if") 12]
    [(TIdent "else") 20]
    [(TIdent _) 5]
    [(TEnd) 0]))

(define (main) : i64
  (+
    (op-score "+")
    (+
      (op-score "/")
      (+
        (token-score (TIdent "if"))
        (+
          (token-score (TIdent "while"))
          (+ (token-score (TEnd)) (op-score "*")))))))