(import stdlib.io)

;; FORCING / SOUNDNESS test for the callee-saved OCCUPANT split (LLVM
;; tryRegionSplit): free a callee-saved register (CSR) for a call-spanning value
;; by exploiting a HOLE in a CSR-occupant's live range.
;;
;; `occ` has three phases separated by real (non-inlinable) calls to `clobber`,
;; which clobbers every caller-saved register, so a value live across a phase
;; boundary must live in a CSR (or spill).
;;
;;   a,b,c,d : used AFTER every call  -> call-spanning for the WHOLE function ->
;;             they want 4 of the 5 CSRs across all three phases.
;;   e       : used across call1 (phase1) and, after REASSIGNMENT, across call3
;;             (phase3). It is NOT used in phase2 and is redefined only in phase3,
;;             so its live range has a genuine HOLE spanning phase2. e is the
;;             CSR-OCCUPANT with a hole.
;;   v       : born in phase2, used across call2, dead afterwards. It lives ONLY
;;             inside e's hole. Across call2 the live call-spanning set is
;;             {a,b,c,d,v} (e is dead), so the 5th CSR that e vacates in its hole
;;             is exactly what v needs across its call.
;;
;; With hole-aware (segmented) interference (compiler-reg-vars-interfere-
;; segmented-index?, active for the precise-interval block tiers), e and v have
;; DISJOINT live ranges, so they may share one CSR across their disjoint call
;; instants -- the "5 CSRs shared across disjoint call-crossing instants" that
;; LLVM's SplitKit achieves. If the allocator mis-models the hole (treats e as
;; live-through phase2, or gives v a caller-saved reg clobbered by call2, or
;; reconstructs the wrong sub-range), the accumulated sum is wrong -> exit 1.
;;
;; CORRECTNESS GUARD: `occ(n) = 18*n + 338` in closed form (each phase's
;; contribution summed by hand), a reconstruction guard the pointer-heavy
;; self-host fixpoint cannot provide. Seeded from (io.arg-count) so the optimizer
;; cannot constant-fold the calls/holes away.
;; Recursive on purpose: the opt-2 leaf-inliner would inline a trivial leaf and
;; delete the call, defeating the call-spanning shape. A self-recursive function
;; is not inlined, so the `call` survives. clobber(k) = k+1 for k >= 0.
(define (clobber [x : i64]) : i64
  (if (<= x 0)
    1
    (+ 1 (clobber (- x 1)))))

(define (occ [n : i64]) : i64
  (let
    [a : i64 (+ n 1)]
    [b : i64 (+ n 2)]
    [c : i64 (+ n 3)]
    [d : i64 (+ n 4)]
    [e : i64 (+ n 5)]
    [v : i64 0]
    [acc : i64 0]
    (begin
      ;; phase 1: call1, then a,b,c,d,e used after it (all 5 call-spanning here)
      (set! acc (+ acc (clobber n)))
      (set! acc (+ acc (+ a (+ b (+ c (+ d e))))))
      ;; phase 2: e is DEAD (its hole); v born and used across call2 with a,b,c,d
      (set! v (+ n 100))
      (set! acc (+ acc (clobber n)))
      (set! acc (+ acc (+ a (+ b (+ c (+ d v))))))
      ;; phase 3: reassign e (new value), used across call3
      (set! e (+ n 200))
      (set! acc (+ acc (clobber n)))
      (set! acc (+ acc (+ a (+ b (+ c (+ d e))))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (io.arg-count)]
    [r : i64 (occ n)]
    [expected : i64 (+ (* 18 n) 338)]
    (if (= r expected)
      42
      1)))