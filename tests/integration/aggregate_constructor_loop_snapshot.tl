;; A completed constructor may not adopt storage still visible through the
;; previous iteration's destination while evaluating the next constructor.
(defstruct Inner
  (a i64)
  (b i64)
  (c i64))

(defstruct Outer
  (left Inner)
  (right Inner))

(define (main) : i64
  (let
    [o : Outer (Outer (Inner 1 2 3) (Inner 4 5 6))]
    [i : i64 0]
    (begin
      (while (< i 2)
        (begin
          (set! o (Outer o.right o.left))
          (set! i (+ i 1))))
      (if (and
        (= o.left.a 1)
        (= o.left.b 2)
        (= o.left.c 3)
        (= o.right.a 4)
        (= o.right.b 5)
        (= o.right.c 6))
        42
        1))))