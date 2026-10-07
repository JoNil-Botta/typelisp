;: A break or continue nested in an operand takes its loop edge (#8575). These
;: paths move nothing that a later iteration or the code after the loop reads.
(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (keep [n : i64]) : unit
  unit)

;; The break moves `t`, and nothing reads it after the loop.
(define (moved-then-left [t : Token]) : i64
  (let
    [acc : i64 0]
    (while true
      (keep
        (if true
          (begin
            (set! acc (consume t))
            (break))
          1))
      (break))
    acc))

;; The place moved on the break edge is reinitialized before its next use.
(define (reinitialized [t : Token]) : i64
  (let
    [acc : i64 0]
    [u : Token t]
    (while true
      (set!
        acc
        (+
          (if true
            (begin
              (set! acc (consume u))
              (break))
            1)
          acc))
      (break))
    (set! u (Token 2 "u"))
    (+ acc (consume u))))

;; Each owner lives in one outer iteration, and the operand's break leaves
;; only the inner loop.
(define (inner-loop-break) : i64
  (let
    [acc : i64 0]
    [n : i64 0]
    (while (< n 3)
      (let
        [t : Token (Token n "t")]
        (while true
          (keep
            (if true
              (begin
                (set! acc (+ acc (consume t)))
                (break))
              1))
          (break)))
      (set! n (+ n 1)))
    acc))

;; A continue in an operand repeats with nothing moved.
(define (continue-without-move) : i64
  (let
    [acc : i64 0]
    (while (< acc 5)
      (set! acc (+ acc 1))
      (keep
        (if (< acc 5)
          (continue)
          1)))
    acc))

(define (main) : i64
  ;; 12 + (20 + 2) + (0 + 1 + 2) + 5
  (+
    (moved-then-left (Token 12 "a"))
    (reinitialized (Token 20 "b"))
    (inner-loop-break)
    (continue-without-move)))