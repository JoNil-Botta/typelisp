(import "stdlib/io.tl")

;; FORCING TEST for SplitKit Phase B (#154): caller-saved call-run sub-range
;; homing of a spilled call-spanning pointer.
;;
;; `p` and the six scalars b..g are ALL live across a REAL call (`clobber`, a
;; self-recursive function the opt-2 inliner cannot delete, so the call survives
;; and clobbers every caller-saved register). Seven values overlap the call but
;; only five callee-saved registers exist, so under the whole-interval rule
;; (compiler-reg-greedy-alloc-one! start-idx = caller-saved-count) the excess --
;; including the pointer `p` -- whole-interval-spills and is reloaded per use.
;;
;; AFTER the call, `p` is dereferenced three times per iteration inside a
;; CALL-FREE loop body (the array bounds check lowers to a noreturn abort, which
;; is NOT a caller-clobber -- exactly the clobber-free region the pass homes in).
;; Phase B loads `p` ONCE at the loop-body entry into a free caller-saved register
;; (%r8/%r9/%rsi/%rdi -- unclobbered because the run is call-free) and rewrites the
;; three reads to that register, collapsing three per-iteration reloads to one
;; load. The reload-elision peephole cannot do this: it can only ELIDE a reload
;; whose value is still resident, but the intervening index arithmetic evicts the
;; reload register, so without a RESERVED register the value is re-loaded.
;;
;; SOUNDNESS GUARD: if Phase B homes `p` in a register that a call clobbers, or
;; reconstructs the wrong sub-range, the sum is wrong -> exit 1. Inputs derive
;; from (arg-count) so the optimizer cannot constant-fold the calls/derefs away,
;; and `expected` is a straight-line closed form -- a reconstruction guard the
;; pointer-heavy self-host fixpoint cannot provide.
(define (clobber [x : i64]) : i64
  (if (<= x 0)
    1
    (+ 1 (clobber (- x 1)))))

(define (run
  [p : (Array i64)]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]) : i64
  (let
    ;; REAL call: keeps p and b..g live across it -> 7 call-spanning values > 5
    ;; callee-saved -> p whole-interval-spills.
    [k : i64 (clobber (+ b (+ c (+ d (+ e (+ f g))))))]
    [acc : i64 0]
    [i : i64 0]
    (begin
      ;; CALL-FREE loop body: p dereferenced three times per iteration. With p
      ;; spilled, each deref reloads it today; Phase B homes it in a caller-saved
      ;; register for the run.
      (while (< i 3)
        (begin
          (set! acc (+ acc (array-ref p 0)))
          (set! acc (+ acc (array-ref p 1)))
          (set! acc (+ acc (array-ref p 2)))
          (set! i (+ i 1))))
      ;; use b..g after the loop so they stay live across the call (pressure).
      (+ acc (+ k (+ b (+ c (+ d (+ e (+ f g))))))))))

(define (main) : i64
  (let
    [ac : i64 (arg-count)]
    [p : (Array i64) (make-array i64 3)]
    (begin
      (array-set! p 0 (+ ac 10))
      (array-set! p 1 (+ ac 12))
      (array-set! p 2 (+ ac 20))
      (let
        [b : i64 (+ ac 1)]
        [c : i64 (+ ac 2)]
        [d : i64 (+ ac 3)]
        [e : i64 (+ ac 4)]
        [f : i64 (+ ac 5)]
        [g : i64 (+ ac 6)]
        [r : i64 (run p b c d e f g)]
        ;; per iteration the loop adds p[0]+p[1]+p[2] = 3*ac + 42; 3 iterations.
        [psum : i64 (+ (+ ac 10) (+ (+ ac 12) (+ ac 20)))]
        ;; b..g sum = 6*ac + 21; clobber(x) = x+1 for x>=0.
        [bg : i64
          (+
            (+ ac 1)
            (+ (+ ac 2) (+ (+ ac 3) (+ (+ ac 4) (+ (+ ac 5) (+ ac 6))))))]
        [expected : i64 (+ (* 3 psum) (+ (+ bg 1) bg))]
        (if (= r expected)
          42
          1)))))