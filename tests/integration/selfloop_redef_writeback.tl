(import stdlib.io)

;; FORCING TEST for SplitKit step 1 -- redefined write-back for single-block
;; self-loops (the un-deaded bidirectional OUT-copy path in the loop-split).
;;
;; Shape (each piece is load-bearing for reaching the redefined write-back gate in
;; compiler-reg-loop-split-try-var):
;;   * `acc-loop` is self-tail-recursive (the k>0 arm). The tail-rec->loop pass
;;     (compiler_optimize.tl #19812) rewrites that call into a back-edge to the
;;     ENTRY block, and SSA construction then SKIPS the whole function because its
;;     entry has a CFG predecessor (compiler_optimize.tl:9563). So the loop's
;;     `set!` accumulators stay MUTABLE, NON-phi variables -- exactly the values the
;;     step-1 path homes (phi-carried values are step 2). The recursion is never
;;     taken at runtime (called with k=0) but its presence is what defeats SSA and
;;     blocks inlining.
;;   * the `(while (< i 1000) ...)` body is a single straight-line block with a
;;     side-effect-free header, so loop rotation (compiler_optimize.tl #2458) turns
;;     it into a single-block SELF-LOOP (the body branches back to itself). The
;;     constant bound lets SCCP fold the zero-trip guard away, so the loop
;;     preheader and exit are single-predecessor -- the edge-copy planner can place
;;     the INTO copy (load at entry) and the OUT copy (write-back at exit) without
;;     refusing on a critical edge.
;;   * sixteen accumulators create register pressure so several spill; a spilled,
;;     redefined, non-phi, carried (live-in & live-out) accumulator is precisely the
;;     value the redefined write-back gate accepts (its coalesced move-group is
;;     remapped to the homed register, with the OUT copy storing it back at exit).
;;
;; This shape drives a spilled, redefined, non-phi, carried accumulator THROUGH the
;; redefined write-back gate (compiler-reg-loop-split-try-var): the gate now admits
;; it, the edge-copy planner produces a bidirectional INTO+OUT plan, and
;; compiler-reg-loop-split-copies-bidirectional? (formerly dead) gates the rescue on
;; the write-back being present. The actual register homing only completes when a
;; clobber-free candidate register is free over the loop region; under the current
;; greedy allocator a redefined self-loop value spans the whole region and spills
;; only at MAX region pressure, when every candidate is occupied, so the OUT-copy
;; APPLY is register-availability-gated (the SplitKit/step-2 lever). Either way:
;;
;; CORRECTNESS GUARD: every accumulator is read AND written every iteration through
;; the self-loop. If the redefined-path gate relaxation, the coalesced-group remap,
;; or (when a register frees up) the OUT store-back mis-reconstructs ANY accumulator
;; the sum is wrong -> exit 1. The seed comes from (io.arg-count) so the optimizer
;; cannot constant-fold the loop, and `expected` is a closed form (no loop) -- a
;; reconstruction guard the pointer-heavy self-host fixpoint cannot provide, and a
;; regression anchor for step 2 when the homing completes.
(define (acc-loop [n : i64] [k : i64] [s : i64]) : i64
  (if (> k 0)
    (acc-loop n (- k 1) s)
    (let
      [a0 : i64 (+ s 1)]
      [a1 : i64 (+ s 2)]
      [a2 : i64 (+ s 3)]
      [a3 : i64 (+ s 4)]
      [a4 : i64 (+ s 5)]
      [a5 : i64 (+ s 6)]
      [a6 : i64 (+ s 7)]
      [a7 : i64 (+ s 8)]
      [a8 : i64 (+ s 9)]
      [a9 : i64 (+ s 10)]
      [a10 : i64 (+ s 11)]
      [a11 : i64 (+ s 12)]
      [a12 : i64 (+ s 13)]
      [a13 : i64 (+ s 14)]
      [a14 : i64 (+ s 15)]
      [a15 : i64 (+ s 16)]
      [i : i64 0]
      (begin
        (while (< i 1000)
          (begin
            (set! a0 (+ a0 i))
            (set! a1 (+ a1 i))
            (set! a2 (+ a2 i))
            (set! a3 (+ a3 i))
            (set! a4 (+ a4 i))
            (set! a5 (+ a5 i))
            (set! a6 (+ a6 i))
            (set! a7 (+ a7 i))
            (set! a8 (+ a8 i))
            (set! a9 (+ a9 i))
            (set! a10 (+ a10 i))
            (set! a11 (+ a11 i))
            (set! a12 (+ a12 i))
            (set! a13 (+ a13 i))
            (set! a14 (+ a14 i))
            (set! a15 (+ a15 i))
            (set! i (+ i 1))))
        (+
          a0
          (+
            a1
            (+
              a2
              (+
                a3
                (+
                  a4
                  (+
                    a5
                    (+
                      a6
                      (+
                        a7
                        (+
                          a8
                          (+ a9 (+ a10 (+ a11 (+ a12 (+ a13 (+ a14 a15)))))))))))))))))))

(define (main) : i64
  (let
    [s : i64 (io.arg-count)]
    [r : i64 (acc-loop 0 0 s)]
    ;; closed form: sum_J (s + J + 1) + 16 * sum_{i=0}^{999} i
    ;;            = 16*s + (1+2+...+16) + 16 * (999*1000/2)
    ;;            = 16*s + 136 + 7992000 = 16*s + 7992136
    [expected : i64 (+ (* 16 s) 7992136)]
    (if (= r expected)
      42
      1)))
