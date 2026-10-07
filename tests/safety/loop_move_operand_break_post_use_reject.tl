;: A break nested in a call argument leaves the loop with the moves made up to
;: it, so the moved place cannot be used after the loop (#8575).
(define (take [text : String]) : i64
  0)

(define (keep [n : i64]) : unit
  unit)

(define (bad [run : bool] [text : String]) : String
  (begin
    (while run
      (keep
        (if run
          (begin
            (take text)
            (break))
          1))
      (break))
    text))

(define (main) : i64
  0)