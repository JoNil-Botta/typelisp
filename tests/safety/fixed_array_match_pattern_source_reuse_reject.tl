(import stdlib.string)

(define (main [items : (Array String 2)]) : i64
  (let
    [score : i64
      (match items
        [(array first second)
          (+ (string.string-length first) (string.string-length second))])]
    (+ score (string.string-length (array-ref items 0)))))