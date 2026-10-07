(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(defstruct Point
  (x i64)
  (y i64))

(defenum Token
  (Num i64)
  (Plus))

(defenum Item
  (Word String)
  (Gap))

(defenum Node
  (:lifetimes source)
  (Leaf i64)
  (Items (& source (Slice i64))))

(defstruct Counter
  (name String)
  (count i64))

(define (sum [xs : (& (Slice i64))]) : i64
  (match xs
    [(slice) 0]
    [(slice x & rest) (+ x (sum rest))]))

(define (shape [xs : (& (Slice i64))]) : i64
  (match xs
    [(slice) 0]
    [(slice a) (* a 10)]
    [(slice a b) (+ (* a 100) b)]
    [(slice a _ & rest) (+ a (* 1000 (array-length rest)))]))

(define (literal-head [xs : (& (Slice i64))]) : i64
  (let
    [result : i64
      (match xs
        [(slice 1 b & _) b]
        [(slice 2 & rest) (sum rest)]
        [_ -1])]
    (+ result 0)))

;; Copy elements bind by value, so payload patterns test the loaded values.
(define (count-tokens [tokens : (& (Slice Token))]) : i64
  (match tokens
    [(slice) 0]
    [(slice (Num n) & rest) (+ n (count-tokens rest))]
    [(slice (Plus) & rest) (+ 100 (count-tokens rest))]
    ;; Coverage is by length; refutable element patterns need a fallback.
    [_ -1000]))

;; Non-Copy elements bind by reference; a String payload binds as `(& str)`.
(define (count-items [items : (& (Slice Item))]) : i64
  (match items
    [(slice) 0]
    [(slice (Word w) & rest)
      (+ (* 1000 (string.string-length w)) (count-items rest))]
    [(slice (Gap) & rest) (+ 1 (count-items rest))]
    [(slice _ & rest) (count-items rest)]))

(define (string-head [words : (& (Slice String))]) : i64
  (match words
    [(slice "skip" & rest) (string-head rest)]
    [(slice first & _) (string.string-length first)]
    [(slice) 0]))

(define (array-ref-score [items : (& (Array i64 3))]) : i64
  (match items
    [(slice a b c) (+ a (+ (* b 10) (* c 100)))]))

;; A borrowed fixed array has a static length, so its arms test only elements.
(define (array-literal-score [items : (& (Array i64 3))]) : i64
  (match items
    [(slice 1 b c) (+ b c)]
    [(slice a 5 _) (* a 100)]
    [(slice a b c) (- 0 (+ a (+ b c)))]))

;; Zero-sized elements share one address; the view still has their count.
(define (count-units [xs : (& (Slice unit))]) : i64
  (match xs
    [(slice) 0]
    [(slice _ & rest) (+ 1 (count-units rest))]))

(define (array-rest-score [items : (& (Array i64 4))]) : i64
  (match items
    [(slice first & rest) (+ first (sum rest))]))

(define (point-score [points : (& (Slice Point))]) : i64
  (match points
    [(slice (Point x y) & rest) (+ (* x y) (point-score rest))]
    [(slice) 0]))

(define (nested-score [rows : (& (Slice (& (Slice i64))))]) : i64
  (match rows
    [(slice) 0]
    [(slice (slice) & rest) (+ 1000 (nested-score rest))]
    [(slice (slice a & _) & rest) (+ a (nested-score rest))]
    ;; Arms with refutable element patterns do not combine for coverage.
    [(slice _ & rest) (nested-score rest)]))

(define (node-score [node : (Node source)]) : i64
  (match node
    [(Leaf n) n]
    [(Items (slice)) -1]
    [(Items (slice a b & _)) (+ a b)]
    [(Items (slice a)) (* a 2)]
    [(Items _) -2]))

(define (borrowed-node-score [node : (& (Node source))]) : i64
  (match node
    [(Items (slice a & rest)) (+ a (sum rest))]
    [_ 0]))

(define (bump-all! [xs : (&mut (Slice i64))]) : unit
  (match xs
    [(slice) unit]
    [(slice x & rest)
      (when
        (> (array-length rest) 0)
        (set! (array-ref rest 0) (+ (array-ref rest 0) x)))
      (bump-all! rest)]))

(define (count-all! [counters : (&mut (Slice Counter))]) : unit
  (match counters
    [(slice) unit]
    [(slice counter & rest)
      (set! counter.count (+ counter.count (string.string-length counter.name)))
      (count-all! rest)]))

;; A non-Copy element of a mutable view binds as `&mut`, so it can be replaced.
(define (replace-first! [words : (&mut (Slice String))]) : i64
  (match words
    [(slice first & rest)
      (set! (deref first) "replaced")
      (array-length rest)]
    [(slice) 0]))

(define (wide-slice-score) : i64
  (let
    [items : (Array i64 6) (array 1 2 3 4 5 6)]
    (+
      (shape (& items))
      (+ (shape (slice-view items 0 2)) (shape (slice-view items 4 1))))))

;; Comptime specialization substitutes `T`; the pattern binder `x` shadows the
;; comptime value `x` only inside its own arm.
(define (first-or [comptime T : type] [xs : (& (Slice T))] [fallback : T]) : T
  (match xs
    [(slice x & _) x]
    [(slice) fallback]))

(define (comptime-score) : i64
  (let
    [items : (Array i64 3) (array 7 8 9)]
    [found : i64 (first-or (type i64) (slice-view items 2 1) 0)]
    [fallback : i64 (first-or (type i64) (slice-view items 0 0) 6)]
    (+ found fallback)))

(define (shadow [comptime x : i64] [xs : (& (Slice i64))]) : i64
  (match xs
    [(slice x & _) x]
    [(slice) x]))

(defmacro (generated-slice-head [xs : Expr]) : Expr
  `(match ,xs
    [(slice first & _) first]
    [(slice) -1]))

(defmacro (define-slice-summer [name : Expr]) : Decls
  `(begin
    (define (,name [xs : (& (Slice i64))]) : i64
      (match xs
        [(slice) 0]
        [(slice x & rest) (+ x (,name rest))]))))

(define-slice-summer generated-sum)

;; The stdlib vector's `view` is a borrowed Slice of its live prefix.
(define (vector-score) : i64
  (let
    [values : i64vec.Vec (i64vec.new)]
    (i64vec.push! values 30)
    (i64vec.push! values 12)
    (match (i64vec.view (& values))
      [(slice a b) (+ a b)]
      [_ -1])))

(define (main) : i64
  (let
    [items : (Array i64 4) (array 1 2 3 4)]
    (unless (= (sum (& items)) 10) (return 1)))
  (let
    [empty : (Array i64 0) (init)]
    (unless (= (sum (& empty)) 0) (return 2)))
  (unless (= (wide-slice-score) 4153) (return 3))
  (let
    [one : (Array i64 3) (array 1 7 9)]
    [two : (Array i64 3) (array 2 7 9)]
    [three : (Array i64 2) (array 3 7)]
    (unless (= (literal-head (& one)) 7) (return 4))
    (unless (= (literal-head (& two)) 16) (return 5))
    (unless (= (literal-head (& three)) -1) (return 6)))
  (let
    [tokens : (Array Token 3) (array (Num 5) Plus (Num 7))]
    [items : (Array Item 3) (array (Word "abc") Gap (Word "z"))]
    (unless (= (count-tokens (& tokens)) 112) (return 7))
    (unless (= (count-items (& items)) 4001) (return 20)))
  (let
    [words : (Array String 3) (array "skip" "skip" "three")]
    (unless (= (string-head (& words)) 5) (return 8)))
  (let
    [items : (Array i64 3) (array 1 2 3)]
    (unless (= (array-ref-score (& items)) 321) (return 9)))
  (let
    [items : (Array i64 4) (array 10 1 2 3)]
    (unless (= (array-rest-score (& items)) 16) (return 10)))
  (let
    [points : (Array Point 2) (array (Point 2 3) (Point 4 5))]
    (unless (= (point-score (& points)) 26) (return 11)))
  (let
    [cells : (Array i64 3) (array 3 4 5)]
    [rows : (Array (& cells (Slice i64)) 3)
      (array
        (slice-view cells 0 2)
        (slice-view cells 0 0)
        (slice-view cells 2 1))]
    (unless (= (nested-score (& rows)) 1008) (return 12)))
  (let
    [values : (Array i64 3) (array 20 22 99)]
    (unless (= (node-score (Leaf 9)) 9) (return 13))
    (unless (= (node-score (Items (slice-view values 0 0))) -1) (return 14))
    (unless (= (node-score (Items (slice-view values 0 1))) 40) (return 15))
    (unless (= (node-score (Items (slice-view values 0 3))) 42) (return 16))
    (let
      [node : (Node values) (Items (slice-view values 0 3))]
      (unless (= (borrowed-node-score (& node)) 141) (return 17))))
  (let
    [items : (Array i64 4) (array 1 1 1 1)]
    (bump-all! (&mut items))
    (unless (= (array-ref items 3) 4) (return 18)))
  (let
    [counters : (Array Counter 2) (array (Counter "ab" 1) (Counter "xyz" 2))]
    (count-all! (&mut counters))
    (unless
      (= (+ (array-ref counters 0).count (array-ref counters 1).count) 8)
      (return 19)))
  (unless (= (vector-score) 42) (return 21))
  (let
    [words : (Array String 3) (array "a" "bb" "ccc")]
    (unless (= (replace-first! (&mut words)) 2) (return 33))
    (unless (= (string.string-length (array-ref words 0)) 8) (return 34)))
  (let
    [x : (Array i64 3) (array 1 2 3)]
    [y : (Array i64 3) (array 7 5 0)]
    [z : (Array i64 3) (array 2 2 2)]
    [units : (Array unit 4) (init)]
    (unless (= (array-literal-score (& x)) 5) (return 29))
    (unless (= (array-literal-score (& y)) 700) (return 30))
    (unless (= (array-literal-score (& z)) -6) (return 31))
    (unless (= (count-units (& units)) 4) (return 32)))
  (let
    [items : (Array i64 3) (array 7 8 9)]
    [empty : (Array i64 0) (init)]
    (unless (= (generated-slice-head (slice-view items 1 2)) 8) (return 22))
    (unless (= (generated-slice-head (slice-view empty 0 0)) -1) (return 23))
    (unless (= (generated-sum (& items)) 24) (return 24))
    (unless (= (comptime-score) 15) (return 25))
    (unless (= (shadow 5 (slice-view items 0 1)) 7) (return 27))
    (unless (= (shadow 5 (slice-view empty 0 0)) 5) (return 28)))
  42)