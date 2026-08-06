;: A by-value binding cannot manufacture a second owner from a global place.
(define global-text : String
  "owned")

(define (main) : i64
  (let
    [_moved : String global-text]
    42))
