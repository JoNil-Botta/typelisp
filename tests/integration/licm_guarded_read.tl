;; #7997: an invariant element read in an arm of a counting loop moves to the
;; preheader behind the same bound its check tests. The moved read must give
;; the arm exactly the element it would have read, must not happen when the
;; bound fails, and must leave the loop's own check to report an index out of
;; range. The pair loop below has the shape the versioner does not clone (an
;; inner scan in its arm), which is where only this guard can move the read.
;; The index, the arm's trip count and the array length all come from the
;; arguments, so no fold decides the bound.
;;
;; `wild` indexes far past the array (argv 1 times 2^40): its arm never runs,
;; so the source reads nothing and neither may the guard. The abort twin passes
;; an index past the array with the arm taken, and must stop at the bounds
;; diagnostic of the source's check.
(import stdlib.io)
(import stdlib.string)

;; How many of `lo..hi` exceed `bound`: the inner scan the arm runs.
(define (glr-above
  [vals : (& vals (__tl_dyn-array i64))]
  [lo : i64]
  [hi : i64]
  [bound : i64]) : i64
  (let
    [j : i64 lo]
    [count : i64 0]
    (begin
      (while (< j hi)
        (begin
          (when (> (array-ref vals j) bound) (set! count (+ count 1)))
          (set! j (+ j 1))))
      count)))

;; For each of the first `take` trips, `vals[k]` plus how many of `vals[0..i]`
;; exceed it.
(define (glr-sum
  [vals : (& vals (__tl_dyn-array i64))]
  [k : i64]
  [take : i64]
  [n : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i n)
        (begin
          (when
            (< i take)
            (let
              [pivot : i64 (array-ref vals k)]
              (set! sum (+ sum pivot (glr-above vals 0 i pivot)))))
          (set! i (+ i 1))))
      sum)))

(define (main) : i64
  (let
    [k : i64 (string.>int (io.arg 1))]
    [take : i64 (string.>int (io.arg 2))]
    [n : i64 (string.>int (io.arg 3))]
    [vals : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref vals i) (* 10 (% (* (+ i 3) 7) n)))
          (set! i (+ i 1))))
      (io.print-format "{}\n" (glr-sum (& vals) 2 n n))
      (io.print-format "{}\n" (glr-sum (& vals) 1 take n))
      (io.print-format "{}\n" (glr-sum (& vals) (* k 1099511627776) 0 n))
      (io.print-format "{}\n" (glr-sum (& vals) k take n))
      42)))