(import stdlib.io)

;; FORCING / CORRECTNESS test for SplitKit step 2 -- phi-aware register homing of
;; loop-carried values (the dominant 607-spill population).
;;
;; Unlike the step-1 exhibit (selfloop_redef_writeback.tl), which used the
;; self-tail-rec trick to keep the accumulator a MUTABLE non-phi variable, these
;; loops are ordinary `while` loops, so SSA construction inserts a real loop-header
;; PHI for every loop-carried value: `acc_phi = phi [init, preheader], [acc_next,
;; back-edge]`. That phi is exactly what step 2 must home: coalesce the phi result
;; with its back-edge input into one register so the carry stays in-register across
;; the loop, copy the preheader input INTO that register at loop entry, and write
;; the register back OUT to the slot at the loop exit (only when live-out).
;;
;; The accumulators are seeded from a runtime VARIABLE (`s`, from arg-count), not a
;; constant, so (a) the optimizer cannot fold the loop and (b) the phi's preheader
;; input is a real in-coalesce-group variable -- the shape the step-2 phi-correctness
;; gate accepts (a constant preheader input is conservatively refused, since the
;; INTO copy loads the group slot rather than materialising a literal). Each
;; function is called twice so it is not inlined away.
;;
;; CORRECTNESS GUARD: every accumulator is read AND written every iteration through
;; its header phi. If the phi-input remap, the coalesced-group homing, or (once a
;; register frees over the loop) the INTO/OUT boundary copies mis-reconstruct ANY
;; accumulator, the sum is wrong -> exit 1. `expected` is a straight-line closed
;; form (no loop), a reconstruction guard the pointer-heavy self-host fixpoint
;; cannot provide, and the regression anchor for when the homing fires.
;; Single loop-carried phi accumulator, variable seed, used after the loop.
(define (acc-sum [n : i64] [seed : i64]) : i64
  (let
    [acc : i64 seed]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc i))
          (set! i (+ i 1))))
      acc)))

;; A real call inside the loop body -> the loop region is NOT clobber-free, so a
;; homed carry must use a CALLEE-SAVED register (preserved across the call).
(define (bump [x : i64]) : i64
  (+ x 1))

;; Two loop-carried phi accumulators across an inner call (callee-saved carry).
;;   a_{k+1} = a_k + bump(k) = a_k + (k+1)
;;   b_{k+1} = b_k + 2
(define (acc-two [n : i64] [seed : i64]) : i64
  (let
    [a : i64 seed]
    [b : i64 seed]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! a (+ a (bump i)))
          (set! b (+ b 2))
          (set! i (+ i 1))))
      (+ a b))))

(define (main) : i64
  (let
    [s : i64 (io.arg-count)]
    ;; acc-sum n times: acc = seed + sum_{i=0}^{n-1} i = seed + n*(n-1)/2
    [r1a : i64 (acc-sum 1000 s)]
    [r1b : i64 (acc-sum 500 (+ s 7))]
    [e1a : i64 (+ s (/ (* 1000 999) 2))]
    [e1b : i64 (+ (+ s 7) (/ (* 500 499) 2))]
    ;; acc-two: a = seed + n*(n+1)/2 ; b = seed + 2n ; result = a + b
    [r2a : i64 (acc-two 1000 s)]
    [r2b : i64 (acc-two 400 (+ s 3))]
    [e2a : i64 (+ (+ s (/ (* 1000 1001) 2)) (+ s (* 2 1000)))]
    [e2b : i64 (+ (+ (+ s 3) (/ (* 400 401) 2)) (+ (+ s 3) (* 2 400)))]
    (if (and (= r1a e1a) (= r1b e1b) (= r2a e2a) (= r2b e2b))
      42
      1)))
