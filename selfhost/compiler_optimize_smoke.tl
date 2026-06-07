;; compiler_optimize_smoke.tl - Runnable smoke for compiler_optimize.tl
;; (#543 constant folding, #544 dead-code elimination, #546 common
;; subexpression elimination, #545 copy propagation, #924 strength reduction,
;; #925 typed constant/cast folding, #926 CFG simplification, #930 bounds-check
;; elimination, #1347 CFG/dominance/SSA verification, opt-level policy, #923
;; fixed-point iteration, self-tail-recursion lowering, #1348 sparse conditional
;; constant propagation, #1489 aggregate stack promotion, #1349 global value
;; numbering/cross-block copy propagation, and #1801 conservative loop-invariant
;; code motion).
;;
;; Folds constant arithmetic and typed scalar operations into `Mov` literals,
;; reduces safe algebraic identities, eliminates an unused pure temporary,
;; eliminates a repeated pure expression, propagates block-local copies, removes
;; duplicate proven bounds checks, simplifies constant control flow, validates
;; CFG/dominance/SSA/natural-loop utility invariants, stack-promotes safe local
;; aggregate storage, selects optimization policies by level, reruns the pass
;; pipeline to a fixed point, and removes dominated repeated scalar expressions
;; across blocks, hoists safe scalar loop invariants into preheaders, and
;; reduces simple induction-derived loop offsets/addresses, and validates unused
;; call-graph/SCC infrastructure for the next inliner phases; returns 42 only
;; when every self-test passes.
(import "compiler_optimize.tl")

(define (main) : i64
  (begin
    (unless (= (compiler-optimize-self-test) 42) (return 1))
    (unless (= (compiler-optimize-typed-fold-self-test) 42) (return 1))
    (unless (= (compiler-optimize-strength-self-test) 42) (return 1))
    (unless (= (compiler-optimize-dce-self-test) 42) (return 1))
    (unless (= (compiler-optimize-dce-mem-self-test) 42) (return 1))
    (unless (= (compiler-optimize-cse-self-test) 42) (return 1))
    (unless (= (compiler-optimize-copy-self-test) 42) (return 1))
    (unless (= (compiler-optimize-bounds-self-test) 42) (return 1))
    (unless (= (compiler-optimize-sccp-self-test) 42) (return 1))
    (unless (= (compiler-optimize-global-value-number-self-test) 42) (return 1))
    (unless (= (compiler-optimize-cfg-self-test) 42) (return 1))
    (unless (= (compiler-optimize-natural-loop-self-test) 42) (return 1))
    (unless (= (compiler-optimize-licm-self-test) 42) (return 1))
    (unless (= (compiler-optimize-induction-self-test) 42) (return 1))
    (unless (= (compiler-optimize-ssa-self-test) 42) (return 1))
    (unless (= (compiler-optimize-level-self-test) 42) (return 1))
    (unless (= (compiler-optimize-callgraph-self-test) 42) (return 1))
    (unless (= (compiler-optimize-scc-self-test) 42) (return 1))
    (unless (= (compiler-optimize-inline-self-test) 42) (return 1))
    (unless (= (compiler-optimize-fixed-point-self-test) 42) (return 1))
    (unless (= (compiler-optimize-tailrec-self-test) 42) (return 1))
    (unless (= (compiler-optimize-global-dce-self-test) 42) (return 1))
    (unless (= (compiler-optimize-aggregate-promote-self-test) 42) (return 1))
    (unless (= (compiler-optimize-aggregate-sroa-self-test) 42) (return 1))
    (unless (= (compiler-optimize-spans-self-test) 42) (return 1))
    (unless (= (compiler-optimize-gvn-self-test) 42) (return 1))
    (compiler-optimize-alias-self-test)))