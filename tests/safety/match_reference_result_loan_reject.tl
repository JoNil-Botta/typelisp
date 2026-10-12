(defenum Token
  (Text String)
  (Other String))

(define (main) : i64
  (let
    [tok : Token (Token.Text "before")]
    [saved : (& tok str)
      (match (& tok)
        [(Token.Text text) text]
        [(Token.Other text) text])]
    (begin
      (set! tok (Token.Other "after"))
      (__tl_string_length saved))))