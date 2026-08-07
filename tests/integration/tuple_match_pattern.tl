(import stdlib.string)

(defstruct Point
  (x i64)
  (y i64))

(defstruct Holder
  (pair (Tuple i64 i64)))

(defenum Wrapped
  (Wrapped (Tuple i64 i64)))

(define (owned-string-score [pair : (Tuple String i64)]) : i64
  (match pair
    [(tuple text number) (+ (string.string-length text) number)]))

(define (borrowed-string-score [pair : (Tuple String i64)]) : i64
  (let
    [borrowed-score : i64
      (match (& pair)
        [(tuple text number) (+ (string.string-length text) (deref number))])]
    ;; The tuple owner remains initialized after the pattern bindings' final use.
    (+ borrowed-score (tuple-ref pair 1))))

(define (copy-tuple-score [pair : (Tuple i64 i64)]) : i64
  (let
    [matched : i64
      (match pair
        [(tuple left right) (+ left right)])]
    ;; Structural Copy keeps the source available after a by-value match.
    (+ matched (tuple-ref pair 0))))

(define (nested-score) : i64
  (let
    [value : (Tuple (Tuple i64 i64) Point (Box i64))
      (tuple (tuple 1 2) (Point 3 4) (box 5))]
    (match value
      [(tuple (tuple a b) (Point x y) (box z)) (+ a (+ b (+ x (+ y z))))])))

(define (aggregate-nesting-score) : i64
  (let
    [holder : Holder (Holder (tuple 6 7))]
    [wrapped : Wrapped (Wrapped (tuple 8 9))]
    [boxed : (Box (Tuple i64 i64)) (box (tuple 10 11))]
    (+
      (match holder
        [(Holder (tuple a b)) (+ a b)])
      (+
        (match wrapped
          [(Wrapped (tuple a b)) (+ a b)])
        (match boxed
          [(box (tuple a b)) (+ a b)])))))

(define (partial-move-score) : i64
  (let
    [pair : (Tuple (Box i64) i64) (tuple (box 1) 41)]
    [moved : (Box i64) (tuple-ref pair 0)]
    ;; A literal-index move leaves the sibling slot available.
    (+ (deref moved) (tuple-ref pair 1))))

(define (main) : i64
  (begin
    (unless (= (owned-string-score (tuple "owned" 37)) 42) (return 1))
    (unless (= (borrowed-string-score (tuple "borrow" 18)) 42) (return 2))
    (unless (= (copy-tuple-score (tuple 14 14)) 42) (return 3))
    (unless (= (nested-score) 15) (return 4))
    (unless (= (aggregate-nesting-score) 51) (return 5))
    (unless (= (partial-move-score) 42) (return 6))
    42))