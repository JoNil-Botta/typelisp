(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (main) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i 50)
        (let
          [t : Token (Token i "t")]
          (begin
            (set! i (+ i 1))
            (if (= (% i 2) 0)
              (begin
                (consume t)
                (continue))
              unit)
            (if (> i 12)
              (begin
                (set! sum (+ sum (consume t)))
                (break))
              unit)
            (set! sum (+ sum (consume t))))))
      sum)))