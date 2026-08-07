(define (make) : (-> String)
  (let
    [owned : String "once"]
    [take : (-> String)
      (lambda () : String
        owned)]
    take))

(define (main) : i64
  0)