;; Captured owned-loop annotations use type bindings before the item binds.
(define (typed-sum [comptime T : type]) : i64
  (let
    [items : (Array i64 2) (array 10 20)]
    [total : i64 0]
    (for [item : T items]
      (set! total (+ total (cast item : i64))))
    total))

(define (typed-shadow [comptime element-type : type]) : i64
  (let
    [items : (Array i64 2) (array 10 20)]
    [total : i64 0]
    (for [element-type : element-type items]
      (set! total (+ total element-type)))
    (+ total (cast 1 : element-type))))

(define (typed-array [comptime T : type]) : i64
  (let
    [items : (Array (Array i64 3) 2) (array (array 1 2 3) (array 4 5 6))]
    [total : i64 0]
    (for [row : (Array T 3) items]
      (for [item : T row]
        (set! total (+ total (cast item : i64)))))
    total))

(define (typed-reference [comptime T : type]) : i64
  (let
    [left : i64 10]
    [items (array (& left) (& left))]
    [total : i64 0]
    (for [item : (& left T) items]
      (set! total (+ total (cast (deref item) : i64))))
    total))

(define (typed-reference-array [comptime T : type]) : i64
  (let
    [row : (Array i64 3) (array 7 8 9)]
    [items (array (& row))]
    [total : i64 0]
    (for [item : (& row (Array T 3)) items]
      (set!
        total
        (+
          (cast (array-ref (deref item) 0) : i64)
          (cast (array-ref (deref item) 2) : i64))))
    total))

(define (typed-mutable-reference [comptime T : type] [place : (&mut place i64)]) : unit
  (let
    [items (array place)]
    (for [item : (&mut place T) items]
      (set! (deref item) (cast 30 : T)))))

(define (typed-empty [comptime T : type]) : i64
  (let
    [items : (Array i64 0) (make-array i64 0)]
    [count : i64 0]
    (for [_item : T items]
      (set! count (+ count 1)))
    count))

(define (typed-unit [comptime T : type]) : i64
  (let
    [items : (Array unit 2) (array unit unit)]
    [count : i64 0]
    (for [_item : T items]
      (set! count (+ count 1)))
    count))

(define (typed-value-name [comptime i64 : i64]) : i64
  (let
    [items : (Array i64 2) (array 10 20)]
    [total : i64 0]
    (for [item : i64 items]
      (set! total (+ total item)))
    (+ total i64)))

(define (main) : i64
  (let
    [value : i64 10]
    (typed-mutable-reference (type i64) (&mut value))
    (if (and
      (= (typed-sum (type i64)) 30)
      (= (typed-shadow (type i64)) 31)
      (= (typed-array (type i64)) 21)
      (= (typed-reference (type i64)) 20)
      (= (typed-reference-array (type i64)) 16)
      (= value 30)
      (= (typed-empty (type i64)) 0)
      (= (typed-unit (type unit)) 2)
      (= (typed-value-name 3) 33))
      42
      1)))