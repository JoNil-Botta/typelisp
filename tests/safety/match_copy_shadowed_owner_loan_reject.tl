;; Removing the pattern-local `tok` must not remove the outer owner's loan.
(defenum Token
  (Num i64))

(define (main) : i64
  (let
    [tok : Token (Token.Num 1)]
    [other : Token (Token.Num 2)]
    [saved : (& tok Token) (& tok)]
    (begin
      (match (& other)
        [(Token.Num tok) tok])
      (set! tok (Token.Num 100))
      (match saved
        [(Token.Num value) value]))))