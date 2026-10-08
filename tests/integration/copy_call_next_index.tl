;; copy_call over a loop that bumps its counter BEFORE the body, so both of the
;; copy's geps are indexed by the counter's `next`: `i = i + 1`, then
;; `b[i] = a[i]`. The prelude `for` range expansion has the same shape once
;; GVN merges the body's `i + 1` with the advance.
;;
;; The rewrite redefines `next` as its exit value, `bound`. Geps that kept reading
;; it sent the call `bound` elements past the first one the loop wrote, off the
;; end of both arrays. `main` checks every element the loop writes and the ones
;; on either side that it must leave alone. tests/codegen/asm-shape.cases checks
;; that the loop still becomes ONE call.
(define (grow [a : (& a (__tl_dyn-array i64))] [n : i64]) : (__tl_dyn-array i64)
  (let
    [b : (__tl_dyn-array i64) (__tl_make-array i64 (+ n 4))]
    [i : i64 0]
    (while (< i n)
      (set! i (+ i 1))
      (set! (array-ref b i) (array-ref a i)))
    b))

;; The number of wrong elements after copying `n`: `dst[1..n]` must hold the
;; source values, and `dst[0]` and `dst[n+1..n+3]` must still be zero.
(define (wrong [n : i64]) : i64
  (let
    [src : (__tl_dyn-array i64) (__tl_make-array i64 (+ n 4))]
    [k : i64 0]
    [bad : i64 0]
    (while (< k (+ n 4))
      (set! (array-ref src k) (* (+ k 1) 10))
      (set! k (+ k 1)))
    (let
      [dst : (__tl_dyn-array i64) (grow (& src) n)]
      (set! k 0)
      (while (< k (+ n 4))
        (unless
          (=
            (array-ref dst k)
            (if (and (> k 0) (<= k n))
              (* (+ k 1) 10)
              0))
          (set! bad (+ bad 1)))
        (set! k (+ k 1)))
      bad)))

(define (main) : i64
  (let
    [bad : i64
      (+
        (wrong 0)
        (wrong 1)
        (wrong 3)
        (wrong 4)
        (wrong 7)
        (wrong 16)
        (wrong 33)
        (wrong 100))]
    (if (= bad 0)
      42
      bad)))