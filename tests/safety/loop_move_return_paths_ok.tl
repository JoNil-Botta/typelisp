;: A move from before a loop is sound when its only executed path returns from
;: the function. The zero-trip path retains the pre-loop owner state.
(define (move-whole-return [run : bool] [text : String]) : String
  (begin
    (while run
      (return text))
    text))

(define (move-path-return [run : bool] [pair : (Tuple String i64)]) : String
  (begin
    (while run
      (return (tuple-ref pair 0)))
    (tuple-ref pair 0)))

;: A sibling continue path does not make the move on the returning arm
;: loop-carried.
(define (move-return-or-continue [run : bool] [take : bool] [text : String]) : String
  (begin
    (while run
      (if take
        (return text)
        (continue)))
    text))

(define (main) : i64
  0)