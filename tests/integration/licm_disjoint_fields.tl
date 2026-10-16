(import stdlib.io)
(import stdlib.string)

(defstruct Fields
  (x i64)
  (y i64))

(define (sum-disjoint [p : (&mut r Fields)] [count : i64]) : i64
  (let
    [total : i64 0]
    [index : i64 0]
    (while (< index count)
      (set! p.y index)
      (set! total (+ total p.x))
      (+= index 1))
    total))

(define (sum-same [p : (&mut r Fields)] [count : i64]) : i64
  (let
    [total : i64 0]
    [index : i64 0]
    (while (< index count)
      (set! p.x index)
      (set! total (+ total p.x))
      (+= index 1))
    total))

(define (main) : i64
  (let
    [limit : i64 (string.>int (io.arg 1))]
    [seed : i64 (string.>int (io.arg 2))]
    [count : i64 0]
    [ok? : bool true]
    (while (and ok? (<= count limit))
      (let
        [disjoint : Fields (Fields seed 123)]
        [same : Fields (Fields seed 123)]
        [disjoint-total : i64 (sum-disjoint (&mut disjoint) count)]
        [same-total : i64 (sum-same (&mut same) count)]
        (set!
          ok?
          (and
            (= disjoint-total (* seed count))
            (= disjoint.x seed)
            (=
              disjoint.y
              (if (= count 0)
                123
                (- count 1)))
            (= same-total (/ (* count (- count 1)) 2))
            (=
              same.x
              (if (= count 0)
                seed
                (- count 1)))
            (= same.y 123))))
      (+= count 1))
    (if ok?
      42
      1)))