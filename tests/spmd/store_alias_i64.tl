;; The single mutable reference deliberately reads and writes the same array.
;; Sequential gang copies must load both inputs before their corresponding
;; output store, preserving scalar alias semantics without manufacturing
;; overlapping safe references.
(define (alias-map [values : (&mut values (__tl_dyn-array i64))] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set!
      (array-ref values i)
      (+ (+ (array-ref values i) (array-ref values i)) 3))))

(define (main) : i64
  (let
    [n : i64 257]
    [values : (__tl_dyn-array i64) (__tl_make-array i64 260)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i 260)
        (begin
          (set! (array-ref values i) (+ i 1))
          (set! i (+ i 1))))
      (alias-map (&mut values) n)
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