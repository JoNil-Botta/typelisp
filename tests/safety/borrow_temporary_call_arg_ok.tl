;: Borrowed call-argument temporaries (SPEC section 3.10): `(& value)` and
;: `(&mut value)` borrow hidden storage that lives until the call returns.
(import stdlib.string)

(defstruct Point
  (x i64)
  (y i64))

(defstruct Named
  (name String)
  (n i64))

(defenum Shape
  (Circle i64)
  (Empty))

(define counter : i64
  0)

(define (next!) : i64
  (begin
    (set! counter (+ counter 1))
    counter))

(define (sum [p : (& Point)]) : i64
  (+ p.x p.y))

(define (shift! [p : (&mut Point)] [d : i64]) : i64
  (begin
    (set! p.x (+ p.x d))
    (sum p)))

(define (named-score [n : (& Named)]) : i64
  (+ (string.string-length n.name) n.n))

(define (text-len [s : (& str)]) : i64
  (string.string-length s))

(define (twice [n : (& i64)]) : i64
  (* 2 (deref n)))

(define (widen [b : (& u8)]) : i64
  (cast (deref b) : i64))

(define (empty? [s : (& Shape)]) : bool
  (match s
    [(Shape.Empty) true]
    [_ false]))

(define (same-sum? [a : (& k Point)] [b : (& k Point)]) : bool
  (= (sum a) (sum b)))

(define (first [xs : (& (Slice i64))]) : i64
  (array-ref xs 0))

(define (slice-size [xs : (& (Slice i64))]) : i64
  (array-length xs))

(define (replace-first! [xs : (&mut (Slice i64))]) : i64
  (set! (array-ref xs 0) 11)
  (array-ref xs 0))

(define (produce-array) : (Array i64 3)
  (array 8 9 10))

(define (ordered [a : i64] [b : (& i64)] [c : i64]) : i64
  (+ (* 100 a) (* 10 (deref b)) c))

(define (make-named [n : i64]) : Named
  (Named (string.concat "ab" "c") n))

(define (via [f : (-> (& Point) i64)]) : i64
  (f (& (Point 2 3))))

(define (tail-sum [n : i64]) : i64
  (if (> n 0)
    (tail-sum (- n 1))
    (sum (& (Point 4 4)))))

(define (moved-in) : i64
  (let
    [name : String (string.concat "xy" "z")]
    (named-score (& (Named name 1)))))

(define (main) : i64
  (let
    [p : Point (Point 1 1)]
    (if (and
      (= (sum (& (Point 3 4))) 7)
      (= (shift! (&mut (Point 1 2)) 5) 8)
      (= (named-score (& (make-named 4))) 7)
      (= (text-len (& (string.concat "x" "yz"))) 3)
      (= (twice (& (+ 20 1))) 42)
      (= (widen (& 9)) 9)
      (empty? (& (Shape.Empty)))
      (not (empty? (& (Shape.Circle 1))))
      (same-sum? (& p) (& (Point 2 0)))
      (= (first (& (array 5 6 7))) 5)
      (= (first (& (array 4))) 4)
      (= (first (& (array 3 2))) 3)
      (= (first (& (produce-array))) 8)
      (= (slice-size (& (array))) 0)
      (= (replace-first! (&mut (array 1 2 3))) 11)
      (= (ordered (next!) (& (next!)) (next!)) 123)
      (= (via sum) 5)
      (= (sum (& (Point (twice (& 1)) 3))) 5)
      (= (tail-sum 3) 8)
      (= (moved-in) 4)
      (= (sum (& p)) 2))
      42
      1)))