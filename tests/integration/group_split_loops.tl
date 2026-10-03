;; Register-group values (two-word enums and structs) reassigned in loops and
;; carried through tail recursion keep every word through the optimizer's
;; per-word split and SSA (#7913).
(defenum MaybeIndex
  (None)
  (Some i64))

(defstruct Acc
  (n i64)
  (x f64))

(defstruct Pair
  (a i64)
  (b i64))

;; The last index holding zero: a two-word enum reassigned in a loop.
(define (last-zero [xs : (& xs (__tl_dyn-array i64))]) : MaybeIndex
  (let
    [found : MaybeIndex None]
    [i : i64 0]
    (begin
      (while (< i (array-length xs))
        (begin
          (if (= (array-ref xs i) 0)
            (set! found (Some i))
            unit)
          (set! i (+ i 1))))
      found)))

;; A group with an integer word and a float word.
(define (positive-sum [xs : (& xs (__tl_dyn-array f64))]) : Acc
  (let
    [acc : Acc (Acc 0 0.0)]
    [i : i64 0]
    (begin
      (while (< i (array-length xs))
        (begin
          (if (> (array-ref xs i) 0.0)
            (set! acc (Acc (+ acc.n 1) (+ acc.x (array-ref xs i))))
            unit)
          (set! i (+ i 1))))
      acc)))

;; Two groups swapped on every iteration: a parallel-copy cycle.
(define (swap-rounds [n : i64]) : i64
  (let
    [p : Pair (Pair 1 2)]
    [q : Pair (Pair 3 4)]
    [i : i64 0]
    (begin
      (while (< i n)
        (let
          [t : Pair p]
          (begin
            (set! p q)
            (set! q t)
            (set! i (+ i 1)))))
      (+ (* p.a 100) (+ (* p.b 10) q.a)))))

;; A group parameter the tail call rewrites.
(define (first-over
  [found : MaybeIndex]
  [i : i64]
  [limit : i64]
  [xs : (& xs (__tl_dyn-array i64))]) : MaybeIndex
  (if (>= i (array-length xs))
    found
    (first-over
      (match found
        [(None)
          (if (> (array-ref xs i) limit)
            (Some i)
            found)]
        [(Some _) found])
      (+ i 1)
      limit
      xs)))

(define (index-or [m : MaybeIndex] [fallback : i64]) : i64
  (match m
    [(Some k) k]
    [(None) fallback]))

(define (main) : i64
  (let
    [ints : (__tl_dyn-array i64) (__tl_make-array i64 5)]
    [floats : (__tl_dyn-array f64) (__tl_make-array f64 4)]
    (begin
      (set! (array-ref ints 0) 0)
      (set! (array-ref ints 1) 9)
      (set! (array-ref ints 2) 0)
      (set! (array-ref ints 3) 4)
      (set! (array-ref ints 4) 7)
      (set! (array-ref floats 0) 1.5)
      (set! (array-ref floats 1) -2.0)
      (set! (array-ref floats 2) 2.25)
      (set! (array-ref floats 3) 0.25)
      (let
        [acc : Acc (positive-sum (& floats))]
        (if (and
          (= (index-or (last-zero (& ints)) -1) 2)
          (= (index-or (first-over None 0 5 (& ints)) -1) 1)
          (= (index-or (first-over None 0 20 (& ints)) -1) -1)
          (= acc.n 3)
          (= acc.x 4.0)
          (= (swap-rounds 5) 341)
          (= (swap-rounds 4) 123))
          42
          1)))))