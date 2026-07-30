(import stdlib.io)
(import stdlib.array)

;; ALIASING STRESS for M-E descriptor-load hoisting.
;;
;; Two hostile shapes:
;;
;; 1. `rotate-sum` stores INTO the same array it reads the length of on every
;;    iteration (read xs[i], write xs[n-1-i], length-dependent index math).
;;    Element stores cannot change the descriptor's len/data fields (arrays
;;    are fixed-size; any resize goes through a runtime call, which blocks
;;    hoisting), so LICM's element-only-store proof (#1801) legitimately
;;    hoists the len/data loads -- this fixture pins the semantics: the sum
;;    must still be computed from the freshly written values.
;;
;; 2. `nested-flip` alternates WHICH inner array handle sits in xss[0] each
;;    iteration and then reads that inner array's length. The inner descriptor
;;    load's base is loop-variant (reloaded from the outer element each
;;    iteration), so it must NOT be hoisted: a wrong hoist reads one inner
;;    array's length for all iterations and the checksum breaks.
;;
;; Both bounds/values feed from (io.arg-count) so nothing constant-folds.
(define (rotate-sum [xs : (__tl_dyn-array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          ;; read the value written on an EARLIER iteration when i > n-1-i.
          (set! acc (+ acc (array.ref xs i)))
          (array-set! xs (- (- n 1) i) (+ i 1))
          (set! i (+ i 1))))
      acc)))

(define (nested-flip
  [xss : (__tl_dyn-array (__tl_dyn-array i64))]
  [a : (__tl_dyn-array i64)]
  [b : (__tl_dyn-array i64)]
  [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (if (= (% i 2) 0)
            (array-set! xss 0 a)
            (array-set! xss 0 b))
          (set! acc (+ acc (array.length (array.ref xss 0))))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (+ (io.arg-count) 5)]
    [xs : (__tl_dyn-array i64) (array.make-array i64 n)]
    [a : (__tl_dyn-array i64) (array.make-array i64 2)]
    [b : (__tl_dyn-array i64) (array.make-array i64 3)]
    [xss : (__tl_dyn-array (__tl_dyn-array i64))
      (array.make-array (type (__tl_dyn-array i64)) 1)]
    (begin
      (array-set! xss 0 a)
      ;; n = 6 (no args). rotate-sum walk:
      ;;   i=0: acc += xs[0] (0), write xs[5]=1
      ;;   i=1: acc += xs[1] (0), write xs[4]=2
      ;;   i=2: acc += xs[2] (0), write xs[3]=3
      ;;   i=3: acc += xs[3] (3), write xs[2]=4
      ;;   i=4: acc += xs[4] (2), write xs[1]=5
      ;;   i=5: acc += xs[5] (1), write xs[0]=6
      ;; acc = 6. A stale (hoisted-value) read of xs[3]/xs[4]/xs[5] gives 0.
      (let
        [r1 : i64 (rotate-sum xs n)]
        ;; nested-flip over n=6: lengths 2,3,2,3,2,3 -> 15. A wrongly hoisted
        ;; inner-descriptor len gives 12 or 18.
        [r2 : i64 (nested-flip xss a b n)]
        (if (and (= r1 6) (= r2 15))
          42
          1)))))
