(import stdlib.io)

;; FORCING TEST for #79 (per-var call-spanning live-range split). Eight values
;; a..h are computed before the loop and used INSIDE it, AFTER a call (clobber)
;; that clobbers every caller-saved register. All eight are therefore live
;; ACROSS the call and OVERLAP in the call-spanning region. With only 5
;; callee-saved GP registers, several of the eight cannot stay in a callee-saved
;; reg across the call, so the per-var call-spanning rescue must keep each in its
;; OWN caller-saved register for the non-crossing sub-ranges (spilling across the
;; call). If the split mis-reconstructs ANY of the eight (reads a clobbered reg,
;; or the wrong sub-range), the sum is wrong -> exit 1. This is the correctness
;; guard the pointer-heavy self-host fixpoint cannot provide. Values come from
;; (io.arg-count) so the optimizer cannot constant-fold the calls away. Correct
;; both before (overlapping values spill) and after (each gets its own
;; caller-saved register) the generalization -- a reconstruction regression guard.
;; Recursive on purpose: the opt-2 leaf-inliner inlines a trivial (+ x 1) leaf,
;; which would delete the call entirely and leave nothing live across a call --
;; defeating the whole test. A self-recursive function is not inlined, so the
;; `call` survives. clobber(x) = x+1 for x>=0 (values unchanged, r still 186).
(define (clobber [x : i64]) : i64
  (if (<= x 0)
    1
    (+ 1 (clobber (- x 1)))))

(define (spanning [n : i64]) : i64
  (let
    [a : i64 (+ n 1)]
    [b : i64 (+ n 2)]
    [c : i64 (+ n 3)]
    [d : i64 (+ n 4)]
    [e : i64 (+ n 5)]
    [f : i64 (+ n 6)]
    [g : i64 (+ n 7)]
    [h : i64 (+ n 8)]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i 4)
        (begin
          ;; Use a..h BEFORE the call: this gives each a non-crossing sub-range
          ;; (a register-resident segment) in addition to crossing the call,
          ;; which is exactly what the call-spanning rescue splits -- keep the
          ;; value in a caller-saved reg for the pre-call segment, spill across.
          (set! acc (+ acc (+ a (+ b (+ c (+ d (+ e (+ f (+ g h)))))))))
          (set! acc (+ acc (clobber i)))
          ;; Use a..h AFTER the call: forces the live range to cross the call.
          (set! acc (+ acc (+ a (+ b (+ c (+ d (+ e (+ f (+ g h)))))))))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (io.arg-count)]
    [r : i64 (spanning n)]
    ;; n=1: a..h = 2..9, sum = 44; loop i=0..3 adds 44 (pre-call) + (i+1)
    ;; (clobber) + 44 (post-call) = 89 + i per iteration.
    ;; total = sum_{i=0..3}(89 + i) = (89+90+91+92) = 362
    (if (= r 362)
      42
      1)))