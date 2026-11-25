;; Cold loop-exit edge blocks (COLD-EDGE).
;;
;; `same-prefix?` compares two arrays element by element and leaves the loop
;; through its mismatch arm, which carries a phi copy (`ok` becomes false) to a
;; block outside every loop. The emitter names that edge block cold and COLD-1
;; moves it to the end of the function, so the equal case falls through to the
;; loop's increment instead of jumping over the copy on every trip.
;;
;; tests/codegen/asm-shape.d/c40-cold-edge.cases pins that layout. The result
;; is 42 only if both the match and the mismatch still return the right value.
(import stdlib.iterator)

(define (build [n : i64] [bump : i64]) : (__tl_dyn-array i64)
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    (for [i (iterator.range 0 n)]
      (set! (array-ref xs i) (* i 3)))
    (set! (array-ref xs (- n 1)) (+ (array-ref xs (- n 1)) bump))
    xs))

(define (same-prefix?
  [a : (& (__tl_dyn-array i64))]
  [b : (& (__tl_dyn-array i64))]
  [len : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (while (and (< i len) ok)
      (if (= (array-ref a i) (array-ref b i))
        unit
        (set! ok false))
      (set! i (+ i 1)))
    ok))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array i64) (build 9 0)]
    [ys : (__tl_dyn-array i64) (build 9 0)]
    [zs : (__tl_dyn-array i64) (build 9 1)]
    ;; 40 for the full match, 2 for the match that stops before the bumped
    ;; last element, 0 for the mismatch.
    (+
      (if (same-prefix? (& xs) (& ys) 9)
        40
        0)
      (if (same-prefix? (& xs) (& zs) 8)
        2
        0)
      (if (same-prefix? (& xs) (& zs) 9)
        100
        0))))