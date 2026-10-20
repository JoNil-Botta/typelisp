;; if_literal_tail_branch_join.tl - a branch whose every value position is a
;; numeric literal joins with the other branch's type, as a bare literal does
;; (#8590): the last form of a `cond` arm of several forms, a `let` body, and
;; a nested `if` (the rest of a `cond`) whose arms are all such literals.
(define (wide [x : i64]) : i64
  (* x 1000000000))

(define (touch [_x : i64]) : unit
  unit)

;; A `cond` in statement position: the arms of several forms end in literals,
;; one arm is an `i64` call, and the arms after it are literals again.
(define (statement [mode : i64]) : i64
  (begin
    (cond
      [(= mode 0)
        (touch mode)
        0]
      [(= mode 1) (wide 3)]
      [(= mode 2)
        (touch mode)
        1]
      [else
        (touch mode)
        2])
    mode))

;; The joined value keeps the call's width.
(define (value [mode : i64]) : i64
  (cond
    [(= mode 0)
      (touch mode)
      4000000000]
    [(= mode 1) (wide 5)]
    [else
      (let
        [_ignored : i64 mode]
        -7)]))

(define (main) : i64
  (if (and
    (= (statement 0) 0)
    (= (statement 1) 1)
    (= (statement 5) 5)
    (= (value 0) 4000000000)
    (= (value 1) 5000000000)
    (= (value 2) -7))
    42
    1))