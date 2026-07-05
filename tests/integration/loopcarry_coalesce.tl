(import stdlib.array)
(import stdlib.io)

;; FORCING / CORRECTNESS test for LLVM-style loop-carry phi coalescing -- mirrors
;; quicksort's `qs_partition` shape: a value (`store`) carried across a loop whose
;; body contains a real (non-inlinable) call AND bounds-checked array accesses,
;; updated CONDITIONALLY (so SSA construction builds a loop-header phi AND an
;; if-merge phi for it -- the exact merge-phi chain the baseline coalescer refused
;; to join). Because the loop body contains a call, a register-homed carry must
;; live in a CALLEE-SAVED register (preserved across the call). The function has
;; only a handful of live values, so callee-saved registers are FREE -- so a
;; coalesced carry should win one and stay register-resident, exactly as clang
;; does (and exactly where HEAD spills `store` to the stack despite free
;; callee-saved registers).
;;
;; CORRECTNESS GUARD: `count-below` compacts the elements < pivot to the front
;; (store-side of a partition) and returns their count. With xs[i] = i + s the
;; qualifying prefix is a self-copy (xs unchanged), so the count is deterministic
;; and the array survives repeated calls. If the phi-input remap / coalesced-group
;; homing mis-reconstructs `store` (reads a clobbered caller-saved reg across the
;; call, or the wrong sub-range), the count is wrong -> exit 1. The expected value
;; is a closed form (count of scan < threshold), a reconstruction guard the
;; pointer-heavy self-host fixpoint cannot provide. Seeded from (io.arg-count) so the
;; optimizer cannot constant-fold the loop away.
;; Recursive on purpose: the opt-2 leaf-inliner would inline a trivial leaf and
;; delete the call, defeating the call-spanning shape. A self-recursive function
;; is not inlined, so the `call` survives the loop body. sink(k) = k (>= 0).
(define (sink [x : i64]) : i64
  (if (<= x 0)
    0
    (+ 1 (sink (- x 1)))))

(define (count-below [xs : (Array i64)] [n : i64] [pivot : i64]) : i64
  (let
    [store : i64 0]
    [scan : i64 0]
    (begin
      (while (< scan n)
        (begin
          (if (< (array.ref xs scan) pivot)
            (begin
              ;; real call in the loop body -> `store` (live across it) must be
              ;; callee-saved or spill; plus a bounds-checked store (array-set!).
              (sink (bit-and scan 3))
              (array-set! xs store (array.ref xs scan))
              (set! store (+ store 1)))
            unit)
          (set! scan (+ scan 1))))
      store)))

(define (main) : i64
  (let
    [s : i64 (io.arg-count)]
    [n : i64 1000]
    [xs : (Array i64) (array.make-array i64 1000)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! xs i (+ i s))
          (set! i (+ i 1))))
      ;; xs[scan] < pivot  <=>  scan + s < threshold + s  <=>  scan < threshold,
      ;; so count = threshold (clamped to n). Both calls leave xs unchanged.
      (let
        [r1 : i64 (count-below xs n (+ 500 s))]
        [r2 : i64 (count-below xs n (+ 300 s))]
        (if (and (= r1 500) (= r2 300))
          42
          1)))))
