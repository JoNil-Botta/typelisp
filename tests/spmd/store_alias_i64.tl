(import stdlib.array)

;; The three parameters are distinct IR bases but deliberately receive the same
;; array at runtime. Sequential gang copies must load both inputs before their
;; corresponding output store, preserving scalar alias semantics.
(define (alias-map
  [left : (Array i64)]
  [right : (Array i64)]
  [out : (Array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (+ (+ (array-ref left i) (array-ref right i)) 3))))

(define (main) : i64
  (let
    [n : i64 257]
    [values : (Array i64) (array.make-array i64 260)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i 260)
        (begin
          (array-set! values i (+ i 1))
          (set! i (+ i 1))))
      (alias-map values values values n)
      (set! i 0)
      (while (and ok (< i n))
        (begin
          (if (= (array-ref values i) (+ (* (+ i 1) 2) 3))
            unit
            (set! ok false))
          (set! i (+ i 1))))
      (if (and ok (= (array-ref values n) (+ n 1)))
        42
        1))))