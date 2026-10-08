;; The prelude `for` range expansion advances its counter BEFORE the body, so
;; `continue` moves to the next item. At -O2 the optimizer's latch sink moves
;; that increment into the loop's latch, which gives a `for` loop with an `if`
;; body the same closing `cmp; jl` as its `while` twin
;; (tests/codegen/asm-shape.cases pins that shape). `main` checks the loops
;; whose shape the move must not change: `break`, `continue`, inclusive ranges
;; at both i64 extremes, nested loops, and a body that reads the next index
;; itself. Each answer is compared with a `while` loop or a closed form.
(import stdlib.iterator)

(define (count-if-for [xs : (& xs (__tl_dyn-array i64))] [n : i64])
  (:export-symbol "latch_sink_count_if_for") : i64
  (let
    [c : i64 0]
    (for [i (iterator.range 0 n)]
      (when (> (array-ref xs i) 50) (+= c 1)))
    c))

(define (count-if-while [xs : (& xs (__tl_dyn-array i64))] [n : i64])
  (:export-symbol "latch_sink_count_if_while") : i64
  (let
    [c : i64 0]
    [i : i64 0]
    (while (< i n)
      (when (> (array-ref xs i) 50) (+= c 1))
      (+= i 1))
    c))

;; Stops at the first element above `limit`.
(define (sum-until [xs : (& xs (__tl_dyn-array i64))] [n : i64] [limit : i64]) : i64
  (let
    [s : i64 0]
    (for [i (iterator.range 0 n)]
      (when (> (array-ref xs i) limit) (break))
      (+= s (array-ref xs i)))
    s))

;; Skips every third index.
(define (sum-skipping [xs : (& xs (__tl_dyn-array i64))] [n : i64]) : i64
  (let
    [s : i64 0]
    (for [i (iterator.range 0 n)]
      (when (= (% i 3) 0) (continue))
      (+= s (array-ref xs i)))
    s))

;; Counts the items of an inclusive range, ending at `hi`.
(define (count-inclusive [lo : i64] [hi : i64]) : i64
  (let
    [c : i64 0]
    (for [i (iterator.range-inclusive lo hi)]
      (when (>= i lo) (+= c 1)))
    c))

;; Sums j over 0 <= j < i < n with an odd j.
(define (nested-odd [n : i64]) : i64
  (let
    [s : i64 0]
    (for [i (iterator.range 0 n)]
      (for [j (iterator.range 0 i)]
        (when (= (% j 2) 1) (+= s j))))
    s))

;; The body reads `i + 1`, which value numbering shares with the advance.
(define (shift-next [xs : (&mut xs (__tl_dyn-array i64))] [n : i64]) : unit
  (for [i (iterator.range 0 n)]
    (when
      (> (array-ref xs (+ i 1)) 0)
      (set! (array-ref xs i) (array-ref xs (+ i 1))))))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 101)]
    [k : i64 0]
    [bad : i64 0]
    (while (< k 101)
      (set! (array-ref xs k) (% (* k 37) 101))
      (+= k 1))
    (for [n (iterator.range 0 101)]
      (unless (= (count-if-for (& xs) n) (count-if-while (& xs) n)) (+= bad 1)))
    ;; xs[0..4] = 0 37 74 10 47, and 74 > 60 stops the sum after two items.
    (unless (= (sum-until (& xs) 100 60) 37) (+= bad 100))
    (unless (= (sum-until (& xs) 0 60) 0) (+= bad 100))
    ;; indices 1 2 4 5 -> 37 + 74 + 47 + 84
    (unless (= (sum-skipping (& xs) 6) 242) (+= bad 1000))
    (unless (= (count-inclusive 1 4) 4) (+= bad 10000))
    (unless (= (count-inclusive 5 4) 0) (+= bad 10000))
    (unless
      (= (count-inclusive 9223372036854775805 9223372036854775807) 3)
      (+= bad 10000))
    (unless
      (= (count-inclusive -9223372036854775808 -9223372036854775806) 3)
      (+= bad 10000))
    ;; sum over i < 6 of the odd j < i: i=2:1, i=3:1, i=4:1+3, i=5:1+3 -> 10
    (unless (= (nested-odd 6) 10) (+= bad 100000))
    (shift-next (&mut xs) 5)
    ;; xs[0..5] were 0 37 74 10 47 84; every next element is positive.
    (unless (= (array-ref xs 0) 37) (+= bad 1000000))
    (unless (= (array-ref xs 4) 84) (+= bad 1000000))
    (if (= bad 0)
      42
      1)))