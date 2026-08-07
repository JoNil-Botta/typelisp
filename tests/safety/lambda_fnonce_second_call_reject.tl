(define (main) : String
  (let
    [owned : String "once"]
    [take : (-> String)
      (lambda () : String
        owned)]
    [first : String (take)]
    (take)))