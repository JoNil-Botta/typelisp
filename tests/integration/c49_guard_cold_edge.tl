;; Guard-block COLD-EDGE out-of-line stubs (Shape 1 & Shape 2) and redundant
;; movzbl elimination on Bool returns.
;;
;; `copy-into` triggers an unroll guard whose false arm falls back to the scalar
;; loop while the true arm falls straight into the unrolled loop.
;; `all-equal?` returns a Bool produced by comparisons/constants without
;; redundant self-register `movzbl`.
;;
;; tests/codegen/asm-shape.d/c49-guard-cold-edge.cases pins the -O2 shapes and
;; verifies -Os/-O1/-O0 emit no guard `_branch_cold_` edges.
(import stdlib.iterator)

(define (copy-into
  [dst : (&mut (__tl_dyn-array i64))]
  [src : (& (__tl_dyn-array i64))]
  [n : i64]) : i64
  (let
    [i : i64 0]
    (while (< i n)
      (set! (array-ref dst i) (array-ref src i))
      (+= i 1))
    i))

(define (sum-offset
  [a : (& (__tl_dyn-array i64))]
  [b : (& (__tl_dyn-array i64))]
  [start : i64]
  [n : i64]) : i64
  (let
    [i : i64 start]
    [acc : i64 0]
    (while (< i n)
      (+= acc (+ (array-ref a i) (array-ref b i)))
      (+= i 1))
    acc))

(define (all-positive? [xs : (& (__tl_dyn-array i64))] [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (while (and (< i n) ok)
      (when (<= (array-ref xs i) 0) (set! ok false))
      (+= i 1))
    ok))

(define (main) : i64
  (let
    [src : (__tl_dyn-array i64) (__tl_make-array i64 12)]
    [dst : (__tl_dyn-array i64) (__tl_make-array i64 12)]
    (for [i (iterator.range 0 12)]
      (set! (array-ref src i) (+ i 1)))
    (let
      [c1 : i64 (copy-into (&mut dst) (& src) 12)]
      [c2 : i64 (copy-into (&mut dst) (& src) 2)]
      [s1 : i64 (sum-offset (& src) (& dst) 0 12)]
      [s2 : i64 (sum-offset (& src) (& dst) 10 12)]
      [p1 : bool (all-positive? (& dst) 12)]
      (set! (array-ref dst 5) 0)
      (let
        [p2 : bool (all-positive? (& dst) 12)]
        ;; c1=12, c2=2, s1=156, s2=46, p1=true, p2=false -> 42
        (if (and (= c1 12) (= c2 2) (= s1 156) (= s2 46) p1 (not p2))
          42
          1)))))