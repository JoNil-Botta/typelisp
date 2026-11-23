(import stdlib.io)

(defenum Choice
  (First)
  (Second)
  (Fail))

(define (choose [choice : Choice] [stop : (-> never)]) : i64
  (+
    (if (= choice First)
      10
      (io.panic "expected first"))
    (match choice
      [(First) 1]
      [(Second) 2]
      [(Fail) (+ (stop) 3)])))

(define (main) : i64
  (choose
    First
    (lambda () : never
      (io.panic "indirect"))))