; refs #331: aggregate globals are initialized through hidden runtime
; initializer functions, whose returned pointers are stored before main.
(defenum MaybeI64
  (Some i64)
  (None))

(defstruct Pair
  (x i64)
  (y i64))

(defstruct Nested
  (label String)
  (choice MaybeI64))

(define greeting
  "hello")

(define choice : MaybeI64
  (Some 8))

(define pair
  (Pair 10 11))

(define cells
  (make-array i64 3))

(define nested : Nested
  (Nested "ok" (Some 3)))

(define (main) : i64
  (+
    (+
      (+ (string-length greeting) (length cells))
      (+ (struct-get pair x) (struct-get pair y)))
    (+
      (match choice
        [(Some n) n]
        [None 0])
      (+
        (string-length (struct-get nested label))
        (match (struct-get nested choice)
          [(Some n) n]
          [None 0])))))