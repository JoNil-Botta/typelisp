;: A move followed by an escaping break cannot reach another iteration. The
;: moved value is deliberately not used on the break successor.
(define (move-whole-break [run : bool] [text : String]) : unit
  (begin
    (while run
      (let
        [taken : String text]
        (break)))
    unit))

(define (move-path-break [run : bool] [pair : (Tuple String i64)]) : unit
  (begin
    (while run
      (let
        [taken : String (tuple-ref pair 0)]
        (break)))
    unit))

(define (main) : i64
  0)