(defenum Token
  (Num i64)
  (Nil))

(defstruct Pair
  (left Token)
  (right Token))

(define (main) : i64
  (let
    [pair : Pair (Pair (Token.Num 1) (Token.Num 2))]
    [saved : (& pair Token) (& pair.left)]
    (begin
      (match (begin
        (set! saved (& pair.right))
        (& pair.right))
        [(Token.Num value)
          (begin
            (set! pair.right (Token.Nil))
            value)]
        [_ 0])
      (match saved
        [(Token.Num value) value]
        [_ 0]))))