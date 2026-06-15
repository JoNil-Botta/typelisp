(import stdlib.io)

(define (borrowed-str-len [text : (& input str)]) : i64
  (string-length text))

(define (main [input : String]) : unit
  (let
    [view : (& input str) (& input)]
    (if (= (borrowed-str-len view) (string-length input))
      unit
      unit)))