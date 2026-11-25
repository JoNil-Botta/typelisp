(import stdlib.io)

;; FORCING TEST for the S3 loop-region split. The inner loop's body computes a
;; loop-local value (`d2`) that lives across an inlined Newton square root and
;; is read again after it, while the loop bound `n` and the outer index `i` are
;; live over the whole function but read only once per inner iteration. With
;; every register busy, the whole-interval greedy keeps the sprawling bound in
;; a register and stores `d2` to the stack on every inner iteration; splitting
;; the bound around the inner loop hands its register to `d2` instead.
(define (isqrt [n : i64]) : i64
  (if (<= n 0)
    0
    (let
      [guess : i64 n]
      [settled : bool false]
      [iteration : i64 0]
      (while (and (< iteration 40) (not settled))
        (let
          [next : i64 (/ (+ guess (/ n guess)) 2)]
          (if (>= next guess)
            (set! settled true)
            (set! guess next))
          (set! iteration (+ iteration 1))))
      guess)))

(define (forces
  [px : (&mut px (__tl_dyn-array i64))]
  [py : (&mut py (__tl_dyn-array i64))]
  [mass : (&mut mass (__tl_dyn-array i64))]
  [ax : (&mut ax (__tl_dyn-array i64))]
  [ay : (&mut ay (__tl_dyn-array i64))]
  [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (let
        [sum-x : i64 0]
        [sum-y : i64 0]
        [j : i64 0]
        (while (< j n)
          (when
            (!= j i)
            (let
              [dx : i64 (- (array-ref px j) (array-ref px i))]
              [dy : i64 (- (array-ref py j) (array-ref py i))]
              [d2 : i64 (+ (* dx dx) (* dy dy) 64)]
              [dist : i64 (isqrt (shl d2 4))]
              [pull : i64 (/ (* (array-ref mass j) 1073741824) d2)]
              (set! sum-x (+ sum-x (/ (* pull dx) (+ dist 1))))
              (set! sum-y (+ sum-y (/ (* pull dy) (+ dist 1))))))
          (set! j (+ j 1)))
        (set! (array-ref ax i) sum-x)
        (set! (array-ref ay i) sum-y)
        (set! i (+ i 1))))
    unit))

(define (main) : i64
  (let
    [n : i64 24]
    [px : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [py : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [mass : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [ax : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [ay : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [k : i64 0]
    (while (< k n)
      (set! (array-ref px k) (% (* k 7919) 1000))
      (set! (array-ref py k) (% (* k 104729) 1000))
      (set! (array-ref mass k) (+ 1 (% (* k 31) 17)))
      (set! k (+ k 1)))
    (forces (&mut px) (&mut py) (&mut mass) (&mut ax) (&mut ay) n)
    (let
      [total : i64 0]
      [m : i64 0]
      (while (< m n)
        (set! total (+ total (array-ref ax m) (* 3 (array-ref ay m))))
        (set! m (+ m 1)))
      (io.println "{}" total)
      42)))