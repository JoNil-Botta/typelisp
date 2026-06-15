(import stdlib.random)

(import stdlib.vector)

(import stdlib.test)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

(define (assert-system-seed-ok [result : random.ResultSystemSeed]) : unit
  (match result
    [(random.OkSystemSeed seed)
      (begin
        (test.assert-true (> seed 0) "system seed positive")
        (test.assert-true (< seed (random.random-modulus)) "system seed normalized"))]
    [(random.ErrSystemSeed _) (panic "system seed should succeed on Linux")]))

(define (assert-system-seed-error [result : random.ResultSystemSeed]) : unit
  (match result
    [(random.OkSystemSeed _) (panic "expected system seed error")]
    [(random.ErrSystemSeed err)
      (match err
        [(random.RandomSystemSeedUnavailable message)
          (test.assert-true (> (string-length message) 0) "error message non-empty")])]))

(define (assert-random-bounded-ok
  [result : random.RandomBoundedResult]
  [want-state : i64]
  [want-value : i64]
  [message : String]) : unit
  (match result
    [(random.OkRandomBounded state value)
      (begin
        (test.assert-i64-eq (random.random-state-seed state) want-state message)
        (test.assert-i64-eq value want-value message))]
    [(random.ErrRandomBounded err) (panic err)]))

(define (assert-random-bounded-error
  [result : random.RandomBoundedResult]
  [want-message : String]) : unit
  (match result
    [(random.OkRandomBounded _ _) (panic "expected bounded random error")]
    [(random.ErrRandomBounded err)
      (assert-owned-string-eq err want-message want-message)]))

(define (assert-weighted-ok
  [result : random.RandomWeightedIndexResult]
  [want-state : i64]
  [want-index : i64]
  [message : String]) : unit
  (match result
    [(random.OkRandomWeightedIndex state index)
      (begin
        (test.assert-i64-eq (random.random-state-seed state) want-state message)
        (test.assert-i64-eq index want-index message))]
    [(random.ErrRandomWeightedIndex err) (panic err)]))

(define (assert-weighted-error
  [result : random.RandomWeightedIndexResult]
  [want-message : String]) : unit
  (match result
    [(random.OkRandomWeightedIndex _ _) (panic "expected weighted random error")]
    [(random.ErrRandomWeightedIndex err)
      (assert-owned-string-eq err want-message want-message)]))

(define (assert-sequence-from-one) : unit
  (let
    [draw1 : random.RandomDraw (random.random-next (random.random-seed 1))]
    [draw2 : random.RandomDraw (random.random-next (random.random-draw-state draw1))]
    [draw3 : random.RandomDraw (random.random-next (random.random-draw-state draw2))]
    (begin
      (test.assert-i64-eq (random.random-draw-value draw1) 16807 "first MINSTD draw")
      (test.assert-i64-eq
        (random.random-state-seed (random.random-draw-state draw1))
        16807
        "first MINSTD state")
      (test.assert-i64-eq (random.random-draw-value draw2) 282475249 "second MINSTD draw")
      (test.assert-i64-eq (random.random-draw-value draw3) 1622650073 "third MINSTD draw"))))

(define (assert-bounded-range [state : random.RandomState] [upper : i64] [count : i64]) : unit
  (let
    [i : i64 0]
    [current : random.RandomState state]
    (while (< i count)
      (match (random.random-bounded current upper)
        [(random.OkRandomBounded next value)
          (begin
            (test.assert-true (>= value 0) "bounded draw non-negative")
            (test.assert-true (< value upper) "bounded draw below upper")
            (set! current next)
            (set! i (+ i 1)))]
        [(random.ErrRandomBounded err) (panic err)]))))

(define (weighted-fixture) : random.RandomWeightList
  (random.random-weight-list-cons
    0
    (random.random-weight-list-cons
      10
      (random.random-weight-list-cons
        0
        (random.random-weight-list-cons 5 (random.random-weight-list-empty))))))

(define (weighted-array-fixture) : (Array i64)
  (let
    [weights : (Array i64) (make-array i64 4)]
    (begin
      (array-set! weights 0 0)
      (array-set! weights 1 10)
      (array-set! weights 2 0)
      (array-set! weights 3 5)
      weights)))

(define (weighted-zero-array) : (Array i64)
  (make-array i64 2))

(define (weighted-negative-array) : (Array i64)
  (let
    [weights : (Array i64) (make-array i64 2)]
    (begin
      (array-set! weights 0 1)
      (array-set! weights 1 -1)
      weights)))

(define (weighted-vector-fixture) : vector.I64Vec
  (vector.i64-vec-push
    (vector.i64-vec-push (vector.i64-vec-push (vector.i64-vec-push (vector.i64-vec-new) 0) 10) 0)
    5))

(define (weighted-zero-vector) : vector.I64Vec
  (vector.i64-vec-push (vector.i64-vec-push (vector.i64-vec-new) 0) 0))

(define (weighted-negative-vector) : vector.I64Vec
  (vector.i64-vec-push (vector.i64-vec-push (vector.i64-vec-new) 1) -1))

(define (main) : i64
  (begin
    (test.assert-i64-eq (random.random-state-seed (random.random-seed 0)) 1 "zero seed normalizes")
    (test.assert-i64-eq (random.random-state-seed (random.random-seed 1)) 1 "one seed stays one")
    (test.assert-i64-eq
      (random.random-state-seed (random.random-seed -1))
      2147483646
      "negative seed normalizes")
    (test.assert-i64-eq
      (random.random-state-seed (random.random-seed 2147483647))
      1
      "modulus seed normalizes")
    (assert-sequence-from-one)
    (assert-random-bounded-ok
      (random.random-bounded (random.random-seed 1) 10)
      16807
      7
      "bounded draw stable")
    (assert-random-bounded-error
      (random.random-bounded (random.random-seed 1) 0)
      "random: upper bound must be positive")
    (assert-bounded-range (random.random-seed 99) 3 12)
    (assert-weighted-error
      (random.random-weighted-index (random.random-seed 1) (random.random-weight-list-empty))
      "random: weight list must not be empty")
    (assert-weighted-error
      (random.random-weighted-index
        (random.random-seed 1)
        (random.random-weight-list-cons
          0
          (random.random-weight-list-cons 0 (random.random-weight-list-empty))))
      "random: weight total must be positive")
    (assert-weighted-error
      (random.random-weighted-index
        (random.random-seed 1)
        (random.random-weight-list-cons
          1
          (random.random-weight-list-cons -1 (random.random-weight-list-empty))))
      "random: weight must not be negative")
    (assert-weighted-error
      (random.random-weighted-index-array (random.random-seed 1) (make-array i64 0))
      "random: weight array must not be empty")
    (assert-weighted-error
      (random.random-weighted-index-array (random.random-seed 1) (weighted-zero-array))
      "random: weight total must be positive")
    (assert-weighted-error
      (random.random-weighted-index-array (random.random-seed 1) (weighted-negative-array))
      "random: weight must not be negative")
    (assert-weighted-error
      (random.random-weighted-index-vec (random.random-seed 1) (vector.i64-vec-new))
      "random: weight vector must not be empty")
    (assert-weighted-error
      (random.random-weighted-index-vec (random.random-seed 1) (weighted-zero-vector))
      "random: weight total must be positive")
    (assert-weighted-error
      (random.random-weighted-index-vec (random.random-seed 1) (weighted-negative-vector))
      "random: weight must not be negative")
    (assert-weighted-ok
      (random.random-weighted-index (random.random-seed 1) (weighted-fixture))
      16807
      1
      "weighted index skips leading zero and picks first positive bucket")
    (assert-weighted-ok
      (random.random-weighted-index-array (random.random-seed 1) (weighted-array-fixture))
      16807
      1
      "array weighted index matches list first positive bucket")
    (assert-weighted-ok
      (random.random-weighted-index-vec (random.random-seed 1) (weighted-vector-fixture))
      16807
      1
      "vector weighted index matches list first positive bucket")
    (assert-weighted-ok
      (random.random-weighted-index (random.random-seed 2) (weighted-fixture))
      33614
      3
      "weighted index reaches later positive bucket")
    (assert-weighted-ok
      (random.random-weighted-index-array (random.random-seed 2) (weighted-array-fixture))
      33614
      3
      "array weighted index reaches later positive bucket")
    (assert-weighted-ok
      (random.random-weighted-index-vec (random.random-seed 2) (weighted-vector-fixture))
      33614
      3
      "vector weighted index reaches later positive bucket")
    (assert-system-seed-ok (random.random-system-seed))
    (assert-system-seed-ok (random.random-system-seed))
    (assert-system-seed-error
      (random.ErrSystemSeed (random.RandomSystemSeedUnavailable "entropy unavailable")))
    (let
      [state1 : random.RandomState (random.random-from-system)]
      (begin
        (test.assert-true
          (> (random.random-state-seed state1) 0)
          "random-from-system seed positive")
        (test.assert-true
          (< (random.random-state-seed state1) (random.random-modulus))
          "random-from-system seed normalized")))
    42))