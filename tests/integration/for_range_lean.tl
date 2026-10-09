;; `(for [i (iterator.range s e)] ...)` and `range-inclusive` over a direct call
;; count from the call's arguments: no range value, no protocol call. The
;; exported functions pair `for` loops with their `while` twins for the
;; optimizer's counter sink, which gives them the same code. `main` checks
;; the semantics the lean expansion must keep: single evaluation and order of
;; the bounds, empty and negative ranges, `break`, `continue`, nesting, a
;; reassigned item, inclusive ranges at both i64 extremes, a literal end, and a
;; local `range` that is not `stdlib.iterator.range`. Each answer is compared
;; with a `while` loop or a closed form.
(import stdlib.iterator)

(define (sum-for [xs : (& xs (__tl_dyn-array i64))] [n : i64])
  (:export-symbol "for_range_sum_for") : i64
  (let
    [s : i64 0]
    (for [i (iterator.range 0 n)]
      (+= s (array-ref xs i)))
    s))

(define (sum-while [xs : (& xs (__tl_dyn-array i64))] [n : i64])
  (:export-symbol "for_range_sum_while") : i64
  (let
    [s : i64 0]
    [i : i64 0]
    (while (< i n)
      (+= s (array-ref xs i))
      (+= i 1))
    s))

(define (copy-for
  [dst : (&mut dst (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [n : i64])
  (:export-symbol "for_range_copy_for") : unit
  (for [i (iterator.range 0 n)]
    (set! (array-ref dst i) (array-ref src i))))

(define (count-above [xs : (& xs (__tl_dyn-array i64))] [n : i64] [limit : i64])
  (:export-symbol "for_range_count_above") : i64
  (let
    [c : i64 0]
    (for [i (iterator.range 0 n)]
      (when (> (array-ref xs i) limit) (+= c 1)))
    c))

(define (count-above-while
  [xs : (& xs (__tl_dyn-array i64))]
  [n : i64]
  [limit : i64])
  (:export-symbol "for_range_count_above_while") : i64
  (let
    [c : i64 0]
    [i : i64 0]
    (while (< i n)
      (when (> (array-ref xs i) limit) (+= c 1))
      (+= i 1))
    c))

;; The bounds are evaluated once each, start first.
(define (next! [counter : (&mut counter (__tl_dyn-array i64))] [step : i64]) : i64
  (set! (array-ref counter 0) (+ (* (array-ref counter 0) 10) step))
  step)

(define (bounds-once) : i64
  (let
    [counter : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [items : i64 0]
    (for [i (iterator.range (next! (&mut counter) 1) (next! (&mut counter) 4))]
      (+= items i))
    ;; counter 12... is 14 (start then end); items 1 + 2 + 3
    (+ (* (array-ref counter 0) 100) items)))

(define (sum-skipping [xs : (& xs (__tl_dyn-array i64))] [n : i64]) : i64
  (let
    [s : i64 0]
    (for [i (iterator.range 0 n)]
      (when (= (% i 3) 0) (continue))
      (when (> (array-ref xs i) 80) (break))
      (+= s (array-ref xs i)))
    s))

(define (nested-odd [n : i64]) : i64
  (let
    [s : i64 0]
    (for [i (iterator.range 0 n)]
      (for [j (iterator.range 0 i)]
        (when (= (% j 2) 1) (+= s j))))
    s))

;; Reassigning the item does not move the loop.
(define (doubled [n : i64]) : i64
  (let
    [s : i64 0]
    (for [i (iterator.range 0 n)]
      (set! i (* i 2))
      (+= s i))
    s))

(define (count-range [lo : i64] [hi : i64]) : i64
  (let
    [c : i64 0]
    (for [i (iterator.range lo hi)]
      (when (>= i lo) (+= c 1)))
    c))

(define (count-inclusive [lo : i64] [hi : i64]) : i64
  (let
    [c : i64 0]
    (for [i (iterator.range-inclusive lo hi)]
      (when (>= i lo) (+= c 1)))
    c))

(define (sum-to-ten) : i64
  (let
    [s : i64 0]
    (for [i (iterator.range 0 10)]
      (+= s i))
    s))

;; A local function named `range` is not `stdlib.iterator.range`.
(define (local-range) : i64
  (let
    [range
      (lambda ([a : i64] [b : i64]) : iterator.I64Range
        (iterator.range (+ a 1) (+ b 1)))]
    [s : i64 0]
    (for [i (range 0 3)]
      (+= s i))
    s))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 101)]
    [ys : (__tl_dyn-array i64) (__tl_make-array i64 101)]
    [k : i64 0]
    [bad : i64 0]
    (while (< k 101)
      (set! (array-ref xs k) (% (* k 37) 101))
      (+= k 1))
    (set! k 0)
    (while (< k 101)
      (unless (= (sum-for (& xs) k) (sum-while (& xs) k)) (+= bad 1))
      (unless
        (= (count-above (& xs) k 50) (count-above-while (& xs) k 50))
        (+= bad 1))
      (+= k 1))
    (copy-for (&mut ys) (& xs) 100)
    (unless (= (array-ref ys 99) (array-ref xs 99)) (+= bad 10))
    (unless (= (array-ref ys 100) 0) (+= bad 10))
    (unless (= (bounds-once) 1406) (+= bad 100))
    ;; xs[0..6] = 0 37 74 10 47 84: indices 1 2 4 sum 37 + 74 + 47, and 84
    ;; at index 5 breaks
    (unless (= (sum-skipping (& xs) 6) 158) (+= bad 1000))
    (unless (= (nested-odd 6) 10) (+= bad 10000))
    (unless (= (doubled 5) 20) (+= bad 100000))
    (unless (= (count-range 3 7) 4) (+= bad 1000000))
    (unless (= (count-range 7 3) 0) (+= bad 1000000))
    (unless (= (count-range -5 -2) 3) (+= bad 1000000))
    (unless (= (count-inclusive 1 4) 4) (+= bad 10000000))
    (unless (= (count-inclusive 5 4) 0) (+= bad 10000000))
    (unless
      (= (count-inclusive 9223372036854775805 9223372036854775807) 3)
      (+= bad 10000000))
    (unless
      (= (count-inclusive -9223372036854775808 -9223372036854775806) 3)
      (+= bad 10000000))
    (unless (= (sum-to-ten) 45) (+= bad 100000000))
    ;; 1 + 2 + 3
    (unless (= (local-range) 6) (+= bad 1000000000))
    (if (= bad 0)
      42
      1)))