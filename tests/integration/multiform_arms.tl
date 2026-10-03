(import stdlib.comptime)

;; Match and cond arms take several body forms, evaluated in order like an
;; implicit begin; the last form gives the arm value.
(defenum Op
  (Add i64)
  (Scale i64)
  (Reset))

(defenum Opt
  (Some i64)
  (None))

(define (step [op : Op] [acc : i64]) : i64
  (let
    [total : i64 acc]
    [steps : i64 0]
    (match op
      [(Add n)
        (set! steps (+ steps 1))
        (set! total (+ total n))
        total]
      [(Scale n)
        (set! steps (+ steps 1))
        (set! total (* total n))
        (+ total steps)]
      [(Reset)
        (set! total 0)
        total])))

;; `break` and `return` end a multi-form arm early.
(define (first-square-at-least [limit : i64]) : i64
  (let
    [i : i64 0]
    [found : i64 -1]
    (while (< i 100)
      (match (>= (* i i) limit)
        [true
          (set! found i)
          (break)]
        [false
          (set! i (+ i 1))
          unit]))
    found))

(define (early [x : i64]) : i64
  (match x
    [0
      (set! x 7)
      (return x)]
    [_
      (set! x (* x 2))
      x]))

(define (classify [o : Opt]) : i64
  (let
    [score : i64 0]
    (match o
      [(Some v)
        (set! score 1)
        (match v
          [0
            (set! score (+ score 10))
            score]
          [_
            (set! score (+ score v))
            (* score 2)])]
      [(None)
        (set! score 5)
        score])))

(define (grade [x : i64]) : i64
  (let
    [bonus : i64 0]
    (cond
      [(< x 0)
        (set! bonus 1)
        (- 0 bonus)]
      [(= x 0)
        (set! bonus 2)
        (set! bonus (* bonus 3))
        bonus]
      [else
        (set! bonus x)
        (+ bonus 1)])))

;; Multi-form arms in a macro body run under CTFE, and a quasiquoted template
;; can splice operands into a generated arm.
(defmacro (doubled-literal [value : Expr]) : Expr
  (let
    [out : i64 0]
    (match value
      [(comptime.Expr.Int n)
        (set! out (* n 2))
        (comptime.expr-int out)]
      [_
        (set! out -1)
        (comptime.expr-int out)])))

(defmacro (when-zero [scrutinee : Expr] [first : Expr] [rest : Expr ...]) : Expr
  `(match ,scrutinee
    [0
      ,first
      ,@rest]
    [_ -1]))

(define (spliced [x : i64]) : i64
  (let
    [y : i64 0]
    (when-zero x (set! y 20) (set! y (+ y 1)) (* y 2))))

(define (main) : i64
  (let
    [checks : i64 0]
    (when (= (step (Add 5) 1) 6) (set! checks (+ checks 1)))
    (when (= (step (Scale 3) 2) 7) (set! checks (+ checks 1)))
    (when (= (step (Reset) 9) 0) (set! checks (+ checks 1)))
    (when (= (first-square-at-least 50) 8) (set! checks (+ checks 1)))
    (when (= (early 0) 7) (set! checks (+ checks 1)))
    (when (= (early 4) 8) (set! checks (+ checks 1)))
    (when (= (classify (Some 0)) 11) (set! checks (+ checks 1)))
    (when (= (classify (Some 4)) 10) (set! checks (+ checks 1)))
    (when (= (classify (None)) 5) (set! checks (+ checks 1)))
    (when (= (grade -3) -1) (set! checks (+ checks 1)))
    (when (= (grade 0) 6) (set! checks (+ checks 1)))
    (when (= (grade 4) 5) (set! checks (+ checks 1)))
    (when (= (doubled-literal 21) 42) (set! checks (+ checks 1)))
    (when
      (=
        (comptime
          (let
            [n : i64 3]
            (match n
              [3
                (set! n (+ n 1))
                (* n 2)]
              [_ 0])))
        8)
      (set! checks (+ checks 1)))
    (when (= (spliced 0) 42) (set! checks (+ checks 1)))
    (when (= (spliced 1) -1) (set! checks (+ checks 1)))
    (if (= checks 16)
      42
      checks)))