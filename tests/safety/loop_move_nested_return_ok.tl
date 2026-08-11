;: Return escapes both loop depths, so neither iteration edge is reachable
;: after the move.
(define (nested-return [outer : bool] [inner : bool] [text : String]) : String
  (begin
    (while outer
      (while inner
        (return text)))
    text))

(define (main) : i64
  0)