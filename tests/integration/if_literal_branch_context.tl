;; An `if` with no expected type whose branches are an integer literal and an
;; i64 value: the literal adopts i64, as it would under an annotation (#8590).
;; Comparison operands, an unannotated `let`, and `cond` inside `when` all
;; type their `if` this way. `main` returns 42 only when every value is exact.
(define (two) : i64
  2)

(define (main) : i64
  (let
    [score : i64 0]
    [plain
      (if false
        0
        (two))]
    [negative
      (if true
        -1
        (two))]
    [wide
      (if true
        4000000000
        (two))]
    (begin
      (when
        (<
          (if false
            0
            (two))
          3)
        (set! score (+ score 10)))
      (when
        (=
          (if true
            (two)
            0)
          2)
        (set! score (+ score 10)))
      (when
        (<
          1
          (if false
            0
            (two)))
        (set! score (+ score 10)))
      (when (= (cond [false 0] [else (two)]) 2) (set! score (+ score 5)))
      (when (< negative 0) (set! score (+ score 3)))
      (when (= wide 4000000000) (set! score (+ score 2)))
      ;; 10 + 10 + 10 + 5 + 3 + 2 + 2
      (+ score plain))))