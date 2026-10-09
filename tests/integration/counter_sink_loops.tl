;; Loops that advance their counter BEFORE the body, as the prelude `for`
;; expansions do so that `continue` still moves to the next item. The
;; optimizer's counter sink moves that step into the loop's latches and lets
;; the body read the counter in place of the item copy, at levels 1 and 2, so
;; `counter_sink_sum_bump` compiles like its `while` twin
;; (tests/codegen/asm-shape.cases pins both). `main` checks the shapes the
;; rewrite must handle or leave alone: `break`, `continue`, nested loops, array
;; items, an item read on the way out of the loop, a mutated item, and a
;; counter read after the loop. Each answer is compared with a `while` loop or a
;; closed form.
;; The range expansion, written out: the step comes first.
(define (sum-bump [xs : (& xs (__tl_dyn-array i64))] [n : i64])
  (:export-symbol "counter_sink_sum_bump") : i64
  (let
    [s : i64 0]
    (let
      [idx : i64 0]
      [end : i64 n]
      (while (< idx end)
        (let
          [i idx]
          (set! idx (+ idx 1))
          (+= s (array-ref xs i)))))
    s))

(define (sum-while [xs : (& xs (__tl_dyn-array i64))] [n : i64])
  (:export-symbol "counter_sink_sum_while") : i64
  (let
    [s : i64 0]
    [i : i64 0]
    (while (< i n)
      (+= s (array-ref xs i))
      (+= i 1))
    s))

;; The copy idiom: at level 2 both become one block copy.
(define (copy-bump
  [dst : (&mut dst (__tl_dyn-array i64))]
  [src : (& src (__tl_dyn-array i64))]
  [n : i64])
  (:export-symbol "counter_sink_copy_bump") : unit
  (let
    [idx : i64 0]
    [end : i64 n]
    (while (< idx end)
      (let
        [i idx]
        (set! idx (+ idx 1))
        (set! (array-ref dst i) (array-ref src i))))))

;; `continue` is a second latch: both get the step.
(define (sum-skipping [xs : (& xs (__tl_dyn-array i64))] [n : i64]) : i64
  (let
    [s : i64 0]
    (let
      [idx : i64 0]
      [end : i64 n]
      (while (< idx end)
        (let
          [i idx]
          (set! idx (+ idx 1))
          (when (= (% i 3) 0) (continue))
          (+= s (array-ref xs i)))))
    s))

;; The item is read on the `break` path out of the loop.
(define (first-above [xs : (& xs (__tl_dyn-array i64))] [n : i64] [limit : i64]) : i64
  (let
    [found : i64 -1]
    (let
      [idx : i64 0]
      [end : i64 n]
      (while (< idx end)
        (let
          [i idx]
          (set! idx (+ idx 1))
          (when (> (array-ref xs i) limit) (set! found i) (break)))))
    found))

;; Sums j over 0 <= j < i < n with an odd j.
(define (nested-odd [n : i64]) : i64
  (let
    [s : i64 0]
    (let
      [a : i64 0]
      [a-end : i64 n]
      (while (< a a-end)
        (let
          [i a]
          (set! a (+ a 1))
          (let
            [b : i64 0]
            [b-end : i64 i]
            (while (< b b-end)
              (let
                [j b]
                (set! b (+ b 1))
                (when (= (% j 2) 1) (+= s j))))))))
    s))

;; The item is reassigned in the body, so the copy stays; the step still moves.
(define (sum-doubled [n : i64]) : i64
  (let
    [s : i64 0]
    (let
      [idx : i64 0]
      [end : i64 n]
      (while (< idx end)
        (let
          [i idx]
          (set! idx (+ idx 1))
          (set! i (* i 2))
          (+= s i))))
    s))

;; The counter is read after the loop, so nothing moves.
(define (count-until [xs : (& xs (__tl_dyn-array i64))] [n : i64] [limit : i64]) : i64
  (let
    [idx : i64 0]
    (while (< idx n)
      (let
        [i idx]
        (set! idx (+ idx 1))
        (when (> (array-ref xs i) limit) (break))))
    idx))

;; An array `for` computes its item from the counter before the step.
(define (sum-items [xs : (& xs (__tl_dyn-array i64))]) : i64
  (let
    [s : i64 0]
    (for [x xs]
      (when (= (% (deref x) 2) 0) (continue))
      (+= s (deref x)))
    s))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 101)]
    [ys : (__tl_dyn-array i64) (__tl_make-array i64 101)]
    [k : i64 0]
    [bad : i64 0]
    [odd-sum : i64 0]
    (while (< k 101)
      (set! (array-ref xs k) (% (* k 37) 101))
      (+= k 1))
    (set! k 0)
    (while (< k 101)
      (unless (= (sum-bump (& xs) k) (sum-while (& xs) k)) (+= bad 1))
      (+= k 1))
    (copy-bump (&mut ys) (& xs) 100)
    (unless (= (array-ref ys 99) (array-ref xs 99)) (+= bad 10))
    (unless (= (array-ref ys 100) 0) (+= bad 10))
    ;; xs[0..5] = 0 37 74 10 47 84; indices 1 2 4 5 -> 37 + 74 + 47 + 84
    (unless (= (sum-skipping (& xs) 6) 242) (+= bad 100))
    (unless (= (sum-skipping (& xs) 0) 0) (+= bad 100))
    (unless (= (first-above (& xs) 101 60) 2) (+= bad 1000))
    (unless (= (first-above (& xs) 2 60) -1) (+= bad 1000))
    ;; sum over i < 6 of the odd j < i: i=2:1, i=3:1, i=4:1+3, i=5:1+3 -> 10
    (unless (= (nested-odd 6) 10) (+= bad 10000))
    (unless (= (sum-doubled 5) 20) (+= bad 100000))
    ;; stops at index 2 (74 > 60), whose step has already run
    (unless (= (count-until (& xs) 101 60) 3) (+= bad 1000000))
    (unless (= (count-until (& xs) 2 60) 2) (+= bad 1000000))
    (set! k 0)
    (while (< k 101)
      (when (= (% (array-ref xs k) 2) 1) (+= odd-sum (array-ref xs k)))
      (+= k 1))
    (unless (= (sum-items (& xs)) odd-sum) (+= bad 10000000))
    (if (= bad 0)
      42
      1)))