(import "stdlib/random.tl")

(import "stdlib/test.tl")

(define (assert-system-seed-ok [result : ResultSystemSeed]) : unit
  (match result
    [(OkSystemSeed seed)
      (begin
        (assert-true (> seed 0) "system seed positive")
        (assert-true (< seed (random-modulus)) "system seed normalized"))]
    [(ErrSystemSeed _) (panic "system seed should succeed on Linux")]))

(define (assert-system-seed-error [result : ResultSystemSeed]) : unit
  (match result
    [(OkSystemSeed _) (panic "expected system seed error")]
    [(ErrSystemSeed err)
      (match err
        [(RandomSystemSeedUnavailable message)
          (assert-true (> (string-length message) 0) "error message non-empty")])]))

(define (assert-random-bounded-ok
  [result : RandomBoundedResult]
  [want-state : i64]
  [want-value : i64]
  [message : String]) : unit
  (match result
    [(OkRandomBounded state value)
      (begin
        (assert-i64-eq (random-state-seed state) want-state message)
        (assert-i64-eq value want-value message))]
    [(ErrRandomBounded err) (panic err)]))

(define (assert-random-bounded-error
  [result : RandomBoundedResult]
  [want-message : String]) : unit
  (match result
    [(OkRandomBounded _ _) (panic "expected bounded random error")]
    [(ErrRandomBounded err) (assert-string-eq err want-message want-message)]))

(define (assert-weighted-ok
  [result : RandomWeightedIndexResult]
  [want-state : i64]
  [want-index : i64]
  [message : String]) : unit
  (match result
    [(OkRandomWeightedIndex state index)
      (begin
        (assert-i64-eq (random-state-seed state) want-state message)
        (assert-i64-eq index want-index message))]
    [(ErrRandomWeightedIndex err) (panic err)]))

(define (assert-weighted-error
  [result : RandomWeightedIndexResult]
  [want-message : String]) : unit
  (match result
    [(OkRandomWeightedIndex _ _) (panic "expected weighted random error")]
    [(ErrRandomWeightedIndex err)
      (assert-string-eq err want-message want-message)]))

(define (assert-sequence-from-one) : unit
  (let
    [draw1 : RandomDraw (random-next (random-seed 1))]
    [draw2 : RandomDraw (random-next (random-draw-state draw1))]
    [draw3 : RandomDraw (random-next (random-draw-state draw2))]
    (begin
      (assert-i64-eq (random-draw-value draw1) 16807 "first MINSTD draw")
      (assert-i64-eq
        (random-state-seed (random-draw-state draw1))
        16807
        "first MINSTD state")
      (assert-i64-eq (random-draw-value draw2) 282475249 "second MINSTD draw")
      (assert-i64-eq (random-draw-value draw3) 1622650073 "third MINSTD draw"))))

(define (assert-bounded-range [state : RandomState] [upper : i64] [count : i64]) : unit
  (let
    [i : i64 0]
    [current : RandomState state]
    (while (< i count)
      (match (random-bounded current upper)
        [(OkRandomBounded next value)
          (begin
            (assert-true (>= value 0) "bounded draw non-negative")
            (assert-true (< value upper) "bounded draw below upper")
            (set! current next)
            (set! i (+ i 1)))]
        [(ErrRandomBounded err) (panic err)]))))

(define (weighted-fixture) : RandomWeightList
  (random-weight-list-cons
    0
    (random-weight-list-cons
      10
      (random-weight-list-cons
        0
        (random-weight-list-cons 5 (random-weight-list-empty))))))

(define (main) : i64
  (begin
    (assert-i64-eq (random-state-seed (random-seed 0)) 1 "zero seed normalizes")
    (assert-i64-eq (random-state-seed (random-seed 1)) 1 "one seed stays one")
    (assert-i64-eq
      (random-state-seed (random-seed -1))
      2147483646
      "negative seed normalizes")
    (assert-i64-eq
      (random-state-seed (random-seed 2147483647))
      1
      "modulus seed normalizes")
    (assert-sequence-from-one)
    (assert-random-bounded-ok
      (random-bounded (random-seed 1) 10)
      16807
      7
      "bounded draw stable")
    (assert-random-bounded-error
      (random-bounded (random-seed 1) 0)
      "random: upper bound must be positive")
    (assert-bounded-range (random-seed 99) 3 12)
    (assert-weighted-error
      (random-weighted-index (random-seed 1) (random-weight-list-empty))
      "random: weight list must not be empty")
    (assert-weighted-error
      (random-weighted-index
        (random-seed 1)
        (random-weight-list-cons
          0
          (random-weight-list-cons 0 (random-weight-list-empty))))
      "random: weight total must be positive")
    (assert-weighted-error
      (random-weighted-index
        (random-seed 1)
        (random-weight-list-cons
          1
          (random-weight-list-cons -1 (random-weight-list-empty))))
      "random: weight must not be negative")
    (assert-weighted-ok
      (random-weighted-index (random-seed 1) (weighted-fixture))
      16807
      1
      "weighted index skips leading zero and picks first positive bucket")
    (assert-weighted-ok
      (random-weighted-index (random-seed 2) (weighted-fixture))
      33614
      3
      "weighted index reaches later positive bucket")
    (assert-system-seed-ok (random-system-seed))
    (assert-system-seed-ok (random-system-seed))
    (assert-system-seed-error
      (ErrSystemSeed (RandomSystemSeedUnavailable "entropy unavailable")))
    (let
      [state1 : RandomState (random-from-system)]
      (begin
        (assert-true
          (> (random-state-seed state1) 0)
          "random-from-system seed positive")
        (assert-true
          (< (random-state-seed state1) (random-modulus))
          "random-from-system seed normalized")))
    42))