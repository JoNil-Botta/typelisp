;: Reading a Copy field or tuple element through `(deref box)` reads the boxed
;: storage in place and leaves the box usable.
(defstruct Leaf
  (w i64)
  (s String))

(defstruct Node
  (v i64)
  (leaf Leaf)
  (pair (Tuple i64 i64)))

(define (leaf-w [l : (& Leaf)]) : i64
  l.w)

(define (node-v [n : (& Node)]) : i64
  (+ (deref n).v (deref n).v))

(define (take [b : (Box Node)]) : i64
  (deref b).v)

(define (main) : i64
  (let
    [b : (Box Node) (box (Node 1 (Leaf 2 "s") (tuple 3 4)))]
    [cell : (Box (Tuple i64 String)) (box (tuple 5 "t"))]
    (if (and
      (=
        (+
          (deref b).v
          (deref b).v
          (deref b).leaf.w
          (leaf-w (deref b).leaf)
          (tuple-ref (deref b).pair 1))
        10)
      (= (+ (tuple-ref (deref cell) 0) (tuple-ref (deref cell) 0)) 10)
      (= (node-v (& (deref b))) 2)
      (= (take b) 1))
      42
      1)))