(defenum Token
  (Num i64)
  (Nil))

(define (read [tok : (& tok Token)] [extra : i64]) : i64
  (match tok
    [(Token.Num value) (+ value extra)]
    [_ extra]))

(define (main) : i64
  (let
    [tok : Token (Token.Num 1)]
    (read
      (& tok)
      (match (& tok)
        [(Token.Num value)
          (begin
            (set! tok (Token.Nil))
            value)]
        [_ 0]))))