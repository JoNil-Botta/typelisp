(import "stdlib/io.tl")

;; SINGLE-BLOCK call-spanning rescue PROBE (#79 Stage B finding).
;; `spanning` is one straight-line block (no control flow): 8 values a..h are
;; defined, then a single recursive (non-inlinable) call clobbers every
;; caller-saved register, then a..h are each read 4x AFTER the call. So all 8
;; are live across the call (overflow: 8 > 5 callee-saved -> the greedy spills
;; several), each is hot (ref-count 4 > 2*calls+1 -> passes the benefit gate
;; with exactly ONE call in range), and none cross a block boundary (single
;; block -> not a boundary-var). This is the ideal shape the current within-block
;; rescue should be able to handle.
;;
;; EMPIRICAL FINDING (Stage B): the call-spanning rescue is DEAD -- it does NOT
;; fire even on this ideal case. Evidence: (1) swapping the rescue reg %r9->%rcx
;; produced ZERO register-allocation changes across 1.13M lines of self-host
;; codegen; (2) here the spilled overflow values reload from their slots (no %r9
;; sub-range rescue), and removing the %r9-conflict gate did not change that; (3)
;; the textual reload-elision peephole already CSEs the repeated post-call reads
;; down to a single reload, so the rescue's nominal benefit is largely already
;; captured. Re-enabling for real requires per-var SCAVENGED free caller-saved
;; registers (the Stage-A CompilerRegCallSplit var->reg map exists for this; the
;; single hardcoded %r9 is structurally busy) for single-block, plus #81
;; (per-block spill-code insertion) for the multi-block / loop boundary-var case
;; that holds the bulk of the self-host's call-spanning spill traffic.
;;
;; This test is kept as a correctness guard (=42) and a FUTURE firing guard:
;; once the rescue is properly re-enabled it should keep a spilled-but-hot
;; call-spanning value in a register across its post-call sub-range here.
;; Contrast call_spanning_split.tl (multi-block/loop): there a..h are
;; boundary-vars, excluded for soundness (#81).
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
    [k : i64 (clobber n)]
    ;; one call (clobber); each of a..h read 4x after it, straight-line:
    (+
      k
      (+
        (+ a (+ b (+ c (+ d (+ e (+ f (+ g h)))))))
        (+
          (+ a (+ b (+ c (+ d (+ e (+ f (+ g h)))))))
          (+
            (+ a (+ b (+ c (+ d (+ e (+ f (+ g h)))))))
            (+ a (+ b (+ c (+ d (+ e (+ f (+ g h)))))))))))))

(define (main) : i64
  (let
    [n : i64 (arg-count)]
    [r : i64 (spanning n)]
    ;; n=1: a..h = 2..9, each sum = 44; k = clobber(1) = 2; r = 2 + 4*44 = 178
    (if (= r 178)
      42
      1)))