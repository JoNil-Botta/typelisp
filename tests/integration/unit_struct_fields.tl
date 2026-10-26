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
(define borrowed-effects : i64
  0)

(define (borrow-empty [value : (& value Empty)]) : (& value Empty)
  (+= borrowed-effects 1)
  value)

(define (tick) : unit
  (+= effects 1))

(define (make-empty) : Empty
  (tick)
  (Empty (tick)))

(define (make) : Empty
  (Empty unit))

(define (read-returned) : i64
  (let
    [e : Empty (make)]
    (if (= e.value unit)
      42
      1)))

(define (read-local) : i64
  (let
    [e : Empty (Empty unit)]
    (if (= e.value unit)
      42
      1)))

(define (take-empty [value : Empty]) : unit
  value.value)

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
      (= (read-returned) 42)
      (= (read-local) 42)
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
      (= (take-empty nested.empty) unit)
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
      (match (borrow-empty (& empty))
        [(Empty value) (= value unit)])
      (= borrowed-effects 1)
      (match (& one)
        [(One head number tail) (and (= head unit) (= number 7) (= tail unit))])
      (match (& two)
        [(Two a middle b tail)
          (and (= a 11) (= middle unit) (= b 13) (= tail unit))])
      (match (& wide)
        [(Wide a b c tail) (and (= a 17) (= b 19) (= c 23) (= tail unit))])
      (match (& nested)
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