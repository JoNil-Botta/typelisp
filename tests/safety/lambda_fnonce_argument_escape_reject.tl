(define (call-now [callback : (-> String)]) : String
  (callback))

(define (main) : i64
  (let
    [owned : String "once"]
    [take : (-> String)
      (lambda () : String
        owned)]
    [result : String (call-now take)]
    0))