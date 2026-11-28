(import stdlib.profile)

(defstruct Small
  (value i64))

(defenum Choice
  (Empty)
  (Number i64))

(define stored : Small
  (Small 0))

(define (make-small [value : i64]) : Small
  (Small value))

(define (early [value : i64]) : Small
  (with-scratch (return (Small value)))
  (Small 0))

(define (main) : i64
  (let
    [local : Small (Small 0)]
    [choice : Choice Choice.Empty]
    [values : (Array i64 2) (array 0 0)]
    [pair : (Tuple i64 i64) (tuple 0 0)]
    [before : i64 (profile.alloc-total)]
    (with-scratch (set! stored (Small 42)))
    (with-scratch (set! local (Small 13)))
    (when (!= local.value 13) (return 4))
    (with-scratch (set! local (make-small 11)))
    (with-scratch (set! choice (Choice.Number 17)))
    (with-scratch (set! choice (Choice.Empty)))
    (match choice
      [Choice.Empty unit]
      [(Choice.Number _) (return 3)])
    (with-scratch (set! choice (Choice.Number 17)))
    (when (!= (profile.alloc-total) before) (return 1))
    (let
      [returned : Small (early 23)]
      [scoped : Small (with-arena phase (Small 31))]
      (with-scratch (set! values (array 3 5)))
      (with-scratch (set! pair (tuple 7 9)))
      (if (and
        (= local.value 11)
        (= returned.value 23)
        (= scoped.value 31)
        (= (array-ref values 1) 5)
        (= (tuple-ref pair 0) 7)
        (match choice
          [(Choice.Number n) (= n 17)]
          [Choice.Empty false]))
        stored.value
        2))))