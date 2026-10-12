(defenum Token
  (Num i64)
  (Nil))

(define (main) : i64
  (let
    [tok : Token (Token.Num 1)]
    [saved : (& tok Token) (& tok)]
    [index : i64 0]
    (begin
      (while (< index 1)
        (begin
          (match (& tok)
            [(Token.Num value)
              (begin
                (set! tok (Token.Num (+ value 1)))
                unit)]
            [_ unit])
          (set! index (+ index 1))))
      (match saved
        [(Token.Num value) value]
        [_ 0]))))