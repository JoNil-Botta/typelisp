(import stdlib.string)

(defstruct Point
  (x i64)
  (y i64))

(defstruct Holder
  (items (Array i64 2)))

(defenum Wrapped
  (Wrapped (Array i64 2)))

(defmacro (generated-array-score [items : (Array i64 3)]) : i64
  `(match ,items
    [(array first second third) (+ first (+ second third))]))

(define (owned-string-score [items : (Array String 3)]) : i64
  (match items
    [(array first second third)
      (+
        (string.string-length first)
        (+ (string.string-length second) (string.string-length third)))]))

(define (borrowed-string-score [items : (Array String 3)]) : i64
  (let
    [matched : i64
      (match (& items)
        [(array first second _)
          (+ (string.string-length first) (string.string-length second))])]
    ;; The array owner remains initialized after the shared element references'
    ;; final use.
    (+ matched (string.string-length (array-ref items 2)))))

(define (copy-array-score [items : (Array i64 3)]) : i64
  (let
    [matched : i64
      (match items
        [(array first second third) (+ first (+ second third))])]
    ;; Structural Copy keeps the source available after a by-value match.
    (+ matched (array-ref items 0))))

(define (empty-array-score) : i64
  (let
    [items : (Array i64 0) (init)]
    (match items
      [(array) 42])))

(define (nested-score) : i64
  (let
    [items : (Array (Tuple i64 i64) 2) (array (tuple 1 2) (tuple 3 4))]
    (match items
      [(array (tuple a b) (tuple c d)) (+ a (+ b (+ c d)))])))

(define (nested-array-score) : i64
  (let
    [items : (Array (Array i64 2) 2) (array (array 1 2) (array 3 4))]
    (match items
      [(array (array a b) (array c d)) (+ a (+ b (+ c d)))])))

(define (borrowed-nested-array-score [items : (Array (Array i64 2) 2)]) : i64
  (match (& items)
    [(array (array a b) (array c d))
      (+ (deref a) (+ (deref b) (+ (deref c) (deref d))))]))

(define (owned-box-score [items : (Array (Box i64) 2)]) : i64
  (match items
    [(array first second) (+ (deref first) (deref second))]))

(define (struct-element-score) : i64
  (let
    [items : (Array Point 2) (array (Point 1 2) (Point 3 4))]
    (match items
      [(array (Point a b) (Point c d)) (+ a (+ b (+ c d)))])))

(define (aggregate-nesting-score) : i64
  (let
    [holder : Holder (Holder (array 5 6))]
    [wrapped : Wrapped (Wrapped (array 7 8))]
    [boxed : (Box (Array i64 2)) (box (array 9 10))]
    [tupled : (Tuple (Array i64 2) i64) (tuple (array 11 12) 0)]
    (+
      (match holder
        [(Holder (array a b)) (+ a b)])
      (+
        (match wrapped
          [(Wrapped (array a b)) (+ a b)])
        (+
          (match boxed
            [(box (array a b)) (+ a b)])
          (match tupled
            [(tuple (array a b) _) (+ a b)]))))))

(define (main) : i64
  (begin
    (unless (= (owned-string-score (array "owned" "xx" "yyyy")) 11) (return 1))
    (unless
      (= (borrowed-string-score (array "borrow" "xx" "owner")) 13)
      (return 2))
    (unless (= (copy-array-score (array 7 8 9)) 31) (return 3))
    (unless (= (empty-array-score) 42) (return 4))
    (unless (= (nested-score) 10) (return 5))
    (unless (= (nested-array-score) 10) (return 6))
    (unless
      (= (borrowed-nested-array-score (array (array 9 10) (array 11 12))) 42)
      (return 7))
    (unless (= (owned-box-score (array (box 20) (box 22))) 42) (return 8))
    (unless (= (struct-element-score) 10) (return 9))
    (unless (= (aggregate-nesting-score) 68) (return 10))
    (unless (= (generated-array-score (array 13 14 15)) 42) (return 11))
    42))