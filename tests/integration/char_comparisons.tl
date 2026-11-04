;; Byte-order oracle for value, branching and select-on-flags comparisons.
;; Recursion prevents inlining the predicate dispatchers into the oracle.
(import stdlib.test)

(define (assert [condition : bool]) : unit
  (test.assert-true condition "unsigned char comparison"))

(define branch-witness : i64
  0)

(define (value-char [a : char] [b : char] [op : i64]) : bool
  (cond
    [(= op 0) (= a b)]
    [(= op 1) (!= a b)]
    [(= op 2) (< a b)]
    [(= op 3) (<= a b)]
    [(= op 4) (> a b)]
    [(= op 5) (>= a b)]
    [else (value-char a b (- op 6))]))

(define (branch-char [a : char] [b : char] [op : i64]) : unit
  (cond
    [(= op 0)
      (if (= a b)
        (set! branch-witness (+ branch-witness 1))
        (set! branch-witness (- branch-witness 1)))]
    [(= op 1)
      (if (!= a b)
        (set! branch-witness (+ branch-witness 1))
        (set! branch-witness (- branch-witness 1)))]
    [(= op 2)
      (if (< a b)
        (set! branch-witness (+ branch-witness 1))
        (set! branch-witness (- branch-witness 1)))]
    [(= op 3)
      (if (<= a b)
        (set! branch-witness (+ branch-witness 1))
        (set! branch-witness (- branch-witness 1)))]
    [(= op 4)
      (if (> a b)
        (set! branch-witness (+ branch-witness 1))
        (set! branch-witness (- branch-witness 1)))]
    [(= op 5)
      (if (>= a b)
        (set! branch-witness (+ branch-witness 1))
        (set! branch-witness (- branch-witness 1)))]
    [else (branch-char a b (- op 6))]))

(define (select-eq [a : char] [b : char] [count : i64]) : i64
  (let
    [left : i64 (cast a : i64)]
    [right : i64 (cast b : i64)]
    [sum : i64 0]
    [i : i64 0]
    (while (< i count)
      (let
        [selected : i64
          (if (= a b)
            left
            right)]
        (set! sum (+ sum selected))
        (set! i (+ i 1))))
    (+ sum 5)))

(define (select-ne [a : char] [b : char] [count : i64]) : i64
  (let
    [left : i64 (cast a : i64)]
    [right : i64 (cast b : i64)]
    [sum : i64 0]
    [i : i64 0]
    (while (< i count)
      (let
        [selected : i64
          (if (!= a b)
            left
            right)]
        (set! sum (+ sum selected))
        (set! i (+ i 1))))
    (+ sum 5)))

(define (select-lt [a : char] [b : char] [count : i64]) : i64
  (let
    [left : i64 (cast a : i64)]
    [right : i64 (cast b : i64)]
    [sum : i64 0]
    [i : i64 0]
    (while (< i count)
      (let
        [selected : i64
          (if (< a b)
            left
            right)]
        (set! sum (+ sum selected))
        (set! i (+ i 1))))
    (+ sum 5)))

(define (select-le [a : char] [b : char] [count : i64]) : i64
  (let
    [left : i64 (cast a : i64)]
    [right : i64 (cast b : i64)]
    [sum : i64 0]
    [i : i64 0]
    (while (< i count)
      (let
        [selected : i64
          (if (<= a b)
            left
            right)]
        (set! sum (+ sum selected))
        (set! i (+ i 1))))
    (+ sum 5)))

(define (select-gt [a : char] [b : char] [count : i64]) : i64
  (let
    [left : i64 (cast a : i64)]
    [right : i64 (cast b : i64)]
    [sum : i64 0]
    [i : i64 0]
    (while (< i count)
      (let
        [selected : i64
          (if (> a b)
            left
            right)]
        (set! sum (+ sum selected))
        (set! i (+ i 1))))
    (+ sum 5)))

(define (select-ge [a : char] [b : char] [count : i64]) : i64
  (let
    [left : i64 (cast a : i64)]
    [right : i64 (cast b : i64)]
    [sum : i64 0]
    [i : i64 0]
    (while (< i count)
      (let
        [selected : i64
          (if (>= a b)
            left
            right)]
        (set! sum (+ sum selected))
        (set! i (+ i 1))))
    (+ sum 5)))

(define (select-char [a : char] [b : char] [op : i64]) : i64
  (cond
    [(= op 0) (select-eq a b 1)]
    [(= op 1) (select-ne a b 1)]
    [(= op 2) (select-lt a b 1)]
    [(= op 3) (select-le a b 1)]
    [(= op 4) (select-gt a b 1)]
    [(= op 5) (select-ge a b 1)]
    [else (select-char a b (- op 6))]))

(define (oracle [a : i64] [b : i64] [op : i64]) : bool
  (cond
    [(= op 0) (= a b)]
    [(= op 1) (!= a b)]
    [(= op 2) (< a b)]
    [(= op 3) (<= a b)]
    [(= op 4) (> a b)]
    [(= op 5) (>= a b)]
    [else (oracle a b (- op 6))]))

(define (check-pair [left : i64] [right : i64]) : i64
  (let
    [a : char (cast left : char)]
    [b : char (cast right : char)]
    [op : i64 0]
    [mismatches : i64 0]
    (while (< op 6)
      (let
        [expected : bool (oracle (cast a : i64) (cast b : i64) op)]
        (when
          (!= (value-char a b op) expected)
          (set! mismatches (+ mismatches 1)))
        (set! branch-witness 0)
        (branch-char a b op)
        (when
          (!=
            branch-witness
            (if expected
              1
              -1))
          (set! mismatches (+ mismatches 1)))
        (when
          (!=
            (select-char a b op)
            (+
              (if expected
                left
                right)
              5))
          (set! mismatches (+ mismatches 1))))
      (set! op (+ op 1)))
    mismatches))

;; Literal operands exercise folding independently of the runtime oracle.
(define (folded-boundaries) : unit
  (assert (= (= (cast 0 : char) (cast 0 : char)) true))
  (assert (= (!= (cast 0 : char) (cast 0 : char)) false))
  (assert (= (< (cast 0 : char) (cast 0 : char)) false))
  (assert (= (<= (cast 0 : char) (cast 0 : char)) true))
  (assert (= (> (cast 0 : char) (cast 0 : char)) false))
  (assert (= (>= (cast 0 : char) (cast 0 : char)) true))
  (assert (= (= (cast 0 : char) (cast 127 : char)) false))
  (assert (= (!= (cast 0 : char) (cast 127 : char)) true))
  (assert (= (< (cast 0 : char) (cast 127 : char)) true))
  (assert (= (<= (cast 0 : char) (cast 127 : char)) true))
  (assert (= (> (cast 0 : char) (cast 127 : char)) false))
  (assert (= (>= (cast 0 : char) (cast 127 : char)) false))
  (assert (= (= (cast 0 : char) (cast 128 : char)) false))
  (assert (= (!= (cast 0 : char) (cast 128 : char)) true))
  (assert (= (< (cast 0 : char) (cast 128 : char)) true))
  (assert (= (<= (cast 0 : char) (cast 128 : char)) true))
  (assert (= (> (cast 0 : char) (cast 128 : char)) false))
  (assert (= (>= (cast 0 : char) (cast 128 : char)) false))
  (assert (= (= (cast 0 : char) (cast 255 : char)) false))
  (assert (= (!= (cast 0 : char) (cast 255 : char)) true))
  (assert (= (< (cast 0 : char) (cast 255 : char)) true))
  (assert (= (<= (cast 0 : char) (cast 255 : char)) true))
  (assert (= (> (cast 0 : char) (cast 255 : char)) false))
  (assert (= (>= (cast 0 : char) (cast 255 : char)) false))
  (assert (= (= (cast 127 : char) (cast 0 : char)) false))
  (assert (= (!= (cast 127 : char) (cast 0 : char)) true))
  (assert (= (< (cast 127 : char) (cast 0 : char)) false))
  (assert (= (<= (cast 127 : char) (cast 0 : char)) false))
  (assert (= (> (cast 127 : char) (cast 0 : char)) true))
  (assert (= (>= (cast 127 : char) (cast 0 : char)) true))
  (assert (= (= (cast 127 : char) (cast 127 : char)) true))
  (assert (= (!= (cast 127 : char) (cast 127 : char)) false))
  (assert (= (< (cast 127 : char) (cast 127 : char)) false))
  (assert (= (<= (cast 127 : char) (cast 127 : char)) true))
  (assert (= (> (cast 127 : char) (cast 127 : char)) false))
  (assert (= (>= (cast 127 : char) (cast 127 : char)) true))
  (assert (= (= (cast 127 : char) (cast 128 : char)) false))
  (assert (= (!= (cast 127 : char) (cast 128 : char)) true))
  (assert (= (< (cast 127 : char) (cast 128 : char)) true))
  (assert (= (<= (cast 127 : char) (cast 128 : char)) true))
  (assert (= (> (cast 127 : char) (cast 128 : char)) false))
  (assert (= (>= (cast 127 : char) (cast 128 : char)) false))
  (assert (= (= (cast 127 : char) (cast 255 : char)) false))
  (assert (= (!= (cast 127 : char) (cast 255 : char)) true))
  (assert (= (< (cast 127 : char) (cast 255 : char)) true))
  (assert (= (<= (cast 127 : char) (cast 255 : char)) true))
  (assert (= (> (cast 127 : char) (cast 255 : char)) false))
  (assert (= (>= (cast 127 : char) (cast 255 : char)) false))
  (assert (= (= (cast 128 : char) (cast 0 : char)) false))
  (assert (= (!= (cast 128 : char) (cast 0 : char)) true))
  (assert (= (< (cast 128 : char) (cast 0 : char)) false))
  (assert (= (<= (cast 128 : char) (cast 0 : char)) false))
  (assert (= (> (cast 128 : char) (cast 0 : char)) true))
  (assert (= (>= (cast 128 : char) (cast 0 : char)) true))
  (assert (= (= (cast 128 : char) (cast 127 : char)) false))
  (assert (= (!= (cast 128 : char) (cast 127 : char)) true))
  (assert (= (< (cast 128 : char) (cast 127 : char)) false))
  (assert (= (<= (cast 128 : char) (cast 127 : char)) false))
  (assert (= (> (cast 128 : char) (cast 127 : char)) true))
  (assert (= (>= (cast 128 : char) (cast 127 : char)) true))
  (assert (= (= (cast 128 : char) (cast 128 : char)) true))
  (assert (= (!= (cast 128 : char) (cast 128 : char)) false))
  (assert (= (< (cast 128 : char) (cast 128 : char)) false))
  (assert (= (<= (cast 128 : char) (cast 128 : char)) true))
  (assert (= (> (cast 128 : char) (cast 128 : char)) false))
  (assert (= (>= (cast 128 : char) (cast 128 : char)) true))
  (assert (= (= (cast 128 : char) (cast 255 : char)) false))
  (assert (= (!= (cast 128 : char) (cast 255 : char)) true))
  (assert (= (< (cast 128 : char) (cast 255 : char)) true))
  (assert (= (<= (cast 128 : char) (cast 255 : char)) true))
  (assert (= (> (cast 128 : char) (cast 255 : char)) false))
  (assert (= (>= (cast 128 : char) (cast 255 : char)) false))
  (assert (= (= (cast 255 : char) (cast 0 : char)) false))
  (assert (= (!= (cast 255 : char) (cast 0 : char)) true))
  (assert (= (< (cast 255 : char) (cast 0 : char)) false))
  (assert (= (<= (cast 255 : char) (cast 0 : char)) false))
  (assert (= (> (cast 255 : char) (cast 0 : char)) true))
  (assert (= (>= (cast 255 : char) (cast 0 : char)) true))
  (assert (= (= (cast 255 : char) (cast 127 : char)) false))
  (assert (= (!= (cast 255 : char) (cast 127 : char)) true))
  (assert (= (< (cast 255 : char) (cast 127 : char)) false))
  (assert (= (<= (cast 255 : char) (cast 127 : char)) false))
  (assert (= (> (cast 255 : char) (cast 127 : char)) true))
  (assert (= (>= (cast 255 : char) (cast 127 : char)) true))
  (assert (= (= (cast 255 : char) (cast 128 : char)) false))
  (assert (= (!= (cast 255 : char) (cast 128 : char)) true))
  (assert (= (< (cast 255 : char) (cast 128 : char)) false))
  (assert (= (<= (cast 255 : char) (cast 128 : char)) false))
  (assert (= (> (cast 255 : char) (cast 128 : char)) true))
  (assert (= (>= (cast 255 : char) (cast 128 : char)) true))
  (assert (= (= (cast 255 : char) (cast 255 : char)) true))
  (assert (= (!= (cast 255 : char) (cast 255 : char)) false))
  (assert (= (< (cast 255 : char) (cast 255 : char)) false))
  (assert (= (<= (cast 255 : char) (cast 255 : char)) true))
  (assert (= (> (cast 255 : char) (cast 255 : char)) false))
  (assert (= (>= (cast 255 : char) (cast 255 : char)) true)))

(define (main) : i64
  (folded-boundaries)
  (let
    [boundaries : (Array i64 4) (array 0 127 128 255)]
    [i : i64 0]
    [mismatches : i64 0]
    (while (< i 4)
      (let
        [j : i64 0]
        (while (< j 4)
          (assert
            (= (check-pair (array-ref boundaries i) (array-ref boundaries j)) 0))
          (set! j (+ j 1))))
      (set! i (+ i 1)))
    (set! i 0)
    (while (< i 256)
      (let
        [j : i64 0]
        (while (< j 256)
          (set! mismatches (+ mismatches (check-pair i j)))
          (set! j (+ j 1))))
      (set! i (+ i 1)))
    (assert (= mismatches 0))
    42))