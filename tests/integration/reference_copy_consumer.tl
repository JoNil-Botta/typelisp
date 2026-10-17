(import stdlib.test)

(defstruct Wide
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(defenum Row
  (Fields i64 i64 i64)
  (Empty))

(defenum Wrapped
  (Item Wide)
  (Absent))

(define (select-field [p : (& p Row)] [first : bool]) : i64
  (match (deref p)
    [(Fields a b _)
      (if first
        a
        b)]
    [(Empty) 0]))

(define (scalar-value [p : (& p Row)]) : i64
  (+
    1
    (match (deref p)
      [(Fields a _ _) a]
      [(Empty) 0])))

(define (mutate-scalar [p : (&mut p Row)]) : i64
  (match (deref p)
    [(Fields a b _)
      (set! (deref p) (Fields 90 91 92))
      (+ a b)]
    [(Empty) 0]))

(define (mutate-aggregate [p : (&mut p Wrapped)]) : i64
  (match (deref p)
    [(Item value)
      (set! (deref p) (Item (Wide 90 91 92 93)))
      (+ value.a value.d)]
    [(Absent) 0]))

(define (escape [p : (& p Wrapped)]) : Wide
  (match (deref p)
    [(Item value) value]
    [(Absent) (Wide 0 0 0 0)]))

(define (exit-escape [p : (& p Wrapped)]) : Wide
  (match (deref p)
    [(Item value) (return value)]
    [(Absent) 0])
  (Wide 0 0 0 0))

(define (explicit-return [p : (& p Wide)]) : Wide
  (return (deref p)))

(define (main) : i64
  (let
    [row : Row (Fields 20 22 7)]
    (test.assert-i64-eq (select-field (& row) true) 20 "first pure arm read")
    (test.assert-i64-eq (select-field (& row) false) 22 "second pure arm read")
    (test.assert-i64-eq (scalar-value (& row)) 21 "non-tail pure match")
    (test.assert-i64-eq (mutate-scalar (&mut row)) 42 "scalar payload snapshot")
    (test.assert-i64-eq (select-field (& row) true) 90 "scalar mutation ran")
    (set! row (Empty))
    (test.assert-i64-eq (select-field (& row) false) 0 "empty variant"))
  (let
    [wrapped : Wrapped (Item (Wide 20 2 3 22))]
    [copy (escape (& wrapped))]
    [early (exit-escape (& wrapped))]
    (test.assert-i64-eq
      (mutate-aggregate (&mut wrapped))
      42
      "aggregate payload snapshot before mutation")
    (test.assert-i64-eq (+ copy.a copy.d) 42 "aggregate match result escapes")
    (test.assert-i64-eq
      (+ early.a early.d)
      42
      "early return escapes scalar match")
    (set! wrapped (Absent))
    (test.assert-i64-eq (escape (& wrapped)).a 0 "aggregate fallback")
    (test.assert-i64-eq (exit-escape (& wrapped)).a 0 "early-return fallback"))
  (let
    [source : Wide (Wide 20 2 3 22)]
    [cloned (clone (deref (& source)))]
    [returned (explicit-return (& source))]
    (set! source.a 90)
    (test.assert-i64-eq (+ cloned.a cloned.d) 42 "clone owns independent bytes")
    (test.assert-i64-eq
      (+ returned.a returned.d)
      42
      "explicit return owns bytes"))
  42)