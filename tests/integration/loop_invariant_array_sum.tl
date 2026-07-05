(import stdlib.io)

;; Reconstruction-correctness guard for a bounds-checked array summed through a
;; loop-INVARIANT base pointer (`items`) under register pressure, plus the forcing
;; exhibit for the still-open loop-invariant-reload gap (#81 / #64).
;;
;; A single-block `while` loop reads `items` and five loop-invariant scalars
;; (a..e) every iteration. clang/LLVM keep the loop-invariant base in ONE register
;; across the whole loop; WE currently reload it every iteration
;; (`movq -8(%rbp),%r10` for both the bounds check and the data load -- the
;; array_sum smoking gun from the #85 LLVM-gap comparison), and reload a/b too.
;; Closing that is the #81 SplitKit core (the cheap-slice attempt in #86 -- accept
;; read-only "into-only" rescues + treat the noreturn `tl_oob_abort` guard call as
;; clobber-free -- was proven INERT: byte-identical codegen, because the rescue
;; never forms a register home for these read-only values; see
;; target/86-into-only-and-lever2.patch). When #81 lands, add a loop-body reload
;; assertion here.
;;
;; For now this guards CORRECTNESS: if anything mis-reconstructs the sum, exit 1.
;; The loop bound and seed come from (io.arg-count) so the optimizer cannot
;; constant-fold the loop, and `expected` is recomputed from a straight-line closed
;; form (no loop) -- a reconstruction guard the pointer-heavy self-host fixpoint
;; cannot provide.
(define (sum-array [items : (Array i64)] [n : i64] [seed : i64]) : i64
  (let
    [a : i64 (+ seed 1)]
    [b : i64 (+ seed 2)]
    [c : i64 (+ seed 3)]
    [d : i64 (+ seed 4)]
    [e : i64 (+ seed 5)]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          ;; array-ref through the loop-invariant base `items` every iteration,
          ;; plus the invariants a..e: the base must stay in a register across the
          ;; loop or it is reloaded every iteration.
          (set! acc (+ acc (array-ref items i)))
          (set! acc (+ acc (+ a (+ b (+ c (+ d e))))))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [ac : i64 (io.arg-count)]
    [n : i64 (+ ac 4)]
    [seed : i64 ac]
    [items : (Array i64) (make-array i64 n)]
    [i : i64 0]
    (begin
      ;; items[k] = k*10
      (while (< i n)
        (begin
          (array-set! items i (* i 10))
          (set! i (+ i 1))))
      (let
        [r : i64 (sum-array items n seed)]
        ;; closed form: sum_{k=0}^{n-1}(k*10) + n*(a+b+c+d+e)
        ;;            = 5*n*(n-1)            + n*(5*seed + 15)
        [expected : i64 (+ (* 5 (* n (- n 1))) (* n (+ (* 5 seed) 15)))]
        (if (= r expected)
          42
          1)))))