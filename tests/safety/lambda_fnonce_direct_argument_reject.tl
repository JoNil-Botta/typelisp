(define (call-now [callback : (-> String)]) : String
  (callback))

(define (main) : i64
  (let
    [owned : String "once"]
    (begin
      (call-now
        (lambda () : String
          owned))
      0)))