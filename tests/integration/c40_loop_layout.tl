;; Block layout of exits (#block-placement exit and return-arm sinking).
;;
;; `first-one-from` is a search loop whose two exits -- the bound test's and
;; the hit's -- both return. The front end lays each out right after its test,
;; inside the loop, which leaves the in-loop arm on the taken side of both
;; tests. Exit sinking moves both returns past the loop, so each test falls
;; into the loop and the only branch taken per trip is the back edge.
;;
;; `weighted-sum` opens with a guard whose return arm is laid out as the
;; fall-through; `x < 0` is predicted false, so return-arm sinking may move the
;; arm out of line wherever the guard ends up (it is small enough to inline).
;;
;; tests/codegen/asm-shape.d/c40-loop-layout.cases pins the loop's layout. The
;; result is 42 only if every exit still returns the right value.
(import stdlib.iterator)

(define (build) : (__tl_dyn-array i64)
  (__tl_make-array 0 0 2 0 3 1 0 4))

(define (first-one-from [xs : (& (__tl_dyn-array i64))] [i : i64]) : i64
  (if (>= i (array-length xs))
    -1
    (if (= (array-ref xs i) 1)
      i
      (first-one-from xs (+ i 1)))))

(define (weighted-sum [xs : (& (__tl_dyn-array i64))] [w : i64]) : i64
  (if (< w 0)
    0
    (let
      [acc : i64 0]
      (for [i (iterator.range 0 (array-length xs))]
        (set! acc (+ acc (* w (array-ref xs i)))))
      acc)))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array i64) (build)]
    ;; 5 + -1 + 0 + 3 * 10 + 8 = 42: the hit, the miss past the bound, the
    ;; guarded return, and the weighted sum.
    (+
      (first-one-from (& xs) 0)
      (first-one-from (& xs) 6)
      (weighted-sum (& xs) -1)
      (* 3 (weighted-sum (& xs) 1))
      8)))