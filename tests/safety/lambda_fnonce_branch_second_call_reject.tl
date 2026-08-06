(define (main [take-left : bool]) : String
  (let
    [owned : String "once"]
    [take : (-> String)
      (lambda () : String
        owned)]
    [first : String
      (if take-left
        (take)
        "other")]
    (take)))