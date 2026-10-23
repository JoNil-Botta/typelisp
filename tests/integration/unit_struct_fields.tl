(defstruct Empty
  (value unit))

(defstruct One
  (head unit)
  (number i64)
  (tail unit))

(defstruct Two
  (a i64)
  (middle unit)
  (b i64)
  (tail unit))

(defstruct Wide
  (a i64)
  (b i64)
  (c i64)
  (tail unit))

(defstruct Nested
  (empty Empty)
  (number i64))

(define effects : i64
  0)

(define (tick) : unit
  (+= effects 1))

(define (make-empty) : Empty
  (tick)
  (Empty (tick)))

(define (read-reference [value : (& value Two)]) : unit
  value.tail)

(define (read-empty-reference [value : (& value Empty)]) : unit
  value.value)

(define (read-pointer [value : (MutPtr Wide)]) : unit
  (unsafe
    (__tl-project-field (deref value) tail)))

(define (exit-receiver) : i64
  (__tl-project-field (ann (return 42) : Empty) value)
  1)

(define (exit-left) : i64
  (= (ann (return 42) : unit) (tick))
  1)

(define (exit-right) : i64
  (= (tick) (ann (return 42) : unit))
  1)

(define (main) : i64
  (let
    [one : One (One unit 7 unit)]
    [two : Two (Two 11 unit 13 unit)]
    [wide : Wide (Wide 17 19 23 unit)]
    [nested : Nested (Nested (Empty unit) 29)]
    [empty : Empty (Empty unit)]
    [returned? : bool (= (__tl-project-field (make-empty) value) unit)]
    (if (and
      returned?
      (= effects 2)
      (= empty.value unit)
      (= one.head unit)
      (= one.tail unit)
      (= one.number 7)
      (= two.middle unit)
      (= two.tail unit)
      (= two.a 11)
      (= two.b 13)
      (= wide.tail unit)
      (= wide.c 23)
      (= nested.empty.value unit)
      (= nested.number 29)
      (= (read-reference (& two)) unit)
      (= (read-empty-reference (& empty)) unit)
      (=
        (read-pointer
          (unsafe
            (ptr-addr-of wide)))
        unit)
      (match empty
        [(Empty bound) (= bound unit)])
      (match one
        [(One head number tail) (and (= head unit) (= number 7) (= tail unit))])
      (match nested
        [(Nested bound number) (and (= bound.value unit) (= number 29))])
      (= (exit-receiver) 42)
      (= (tick) (tick))
      (= effects 4)
      (not (!= (tick) (tick)))
      (= effects 6)
      (= (exit-left) 42)
      (= effects 6)
      (= (exit-right) 42)
      (= effects 7))
      42
      1)))