;: The scalar `for` macro lowers through the same loop join analysis.
(define (generated-for-return [items : (Array i64 1)] [text : String]) : String
  (begin
    (for [item items] (return text))
    text))

(define (main) : i64
  0)