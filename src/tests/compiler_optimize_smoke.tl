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
;; reduces simple induction-derived loop offsets/addresses, eliminates local
;; redundant loads when alias facts prove no barrier intervened, reports
;; implicit scratch-region candidates/blockers, and validates
;; unused call-graph/SCC infrastructure for the next inliner phases; returns 42
;; only when every self-test passes.
(import "../compiler_optimize.tl")

(define (smoke-mov-dst-var-type?
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [src : i64]
  [ty : AstType]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrMov d (IrValueVar s) mov-ty)
          (if (= d dst)
            (and (= s src) (opt-type-eq mov-ty ty))
            (smoke-mov-dst-var-type? (box-get rest) dst src ty))]
        [_ (smoke-mov-dst-var-type? (box-get rest) dst src ty)])]))

(define (smoke-cast-dst-var-types?
  [instrs : CompilerIrInstrList]
  [dst : i64]
  [src : i64]
  [from-ty : AstType]
  [to-ty : AstType]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrCast d (IrValueVar s) cast-from cast-to)
          (if (= d dst)
            (and
              (= s src)
              (opt-type-eq cast-from from-ty)
              (opt-type-eq cast-to to-ty))
            (smoke-cast-dst-var-types? (box-get rest) dst src from-ty to-ty))]
        [_ (smoke-cast-dst-var-types? (box-get rest) dst src from-ty to-ty)])]))

(define (smoke-noop-int-cast-mov-instrs) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrCast 50 (IrValueVar 10) (AstTyU8) (AstTyChar))
    (compiler-ir-instr-cons
      (IrInstrCast 51 (IrValueVar 11) (AstTyU16) (AstTyU8))
      (compiler-ir-instr-cons
        (IrInstrCast 52 (IrValueVar 12) (AstTyU16) (AstTyChar))
        (compiler-ir-instr-cons
          (IrInstrCast 53 (IrValueVar 13) (AstTyU8) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrCast 54 (IrValueVar 14) (AstTyI16) (AstTyU32))
            (compiler-ir-instr-cons
              (IrInstrCast 55 (IrValueVar 15) (AstTyI64) (AstTyU64))
              (IrInstrNil))))))))

(define (smoke-noop-int-cast-mov-self-test) : i64
  (let
    [rewritten : CompilerIrInstrList
      (opt-fold-instrs (OptConstNil) (smoke-noop-int-cast-mov-instrs))]
    (begin
      (unless (= (opt-count-cast-instrs rewritten) 3) (return 1))
      (unless (smoke-mov-dst-var-type? rewritten 50 10 (AstTyChar)) (return 2))
      (unless (smoke-mov-dst-var-type? rewritten 51 11 (AstTyU8)) (return 3))
      (unless (smoke-mov-dst-var-type? rewritten 52 12 (AstTyChar)) (return 4))
      (unless
        (smoke-cast-dst-var-types? rewritten 55 15 (AstTyI64) (AstTyU64))
        (return 5))
      42)))

(define (smoke-bounds-object-length-check-fragment
  [ptr-var : i64]
  [length-var : i64]
  [cast-var : i64]
  [object : CompilerIrValue]
  [offset : CompilerIrValue]
  [slot-ty : AstType]
  [index : CompilerIrValue]
  [label : String]
  [tail : CompilerIrInstrList]) : CompilerIrInstrList
  (compiler-ir-instr-cons
    (IrInstrGep ptr-var object offset slot-ty)
    (compiler-ir-instr-cons
      (IrInstrLoad length-var (IrValueVar ptr-var) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrCast cast-var (IrValueVar length-var) (AstTyI64) (AstTyU64))
        (compiler-ir-instr-cons
          (IrInstrBoundsCheck index (IrValueVar cast-var) label)
          tail)))))

(define (smoke-bounds-object-pair
  [second-object : CompilerIrValue]
  [offset : CompilerIrValue]
  [slot-ty : AstType]) : CompilerIrInstrList
  (smoke-bounds-object-length-check-fragment
    10
    11
    12
    (IrValueVar 1)
    offset
    slot-ty
    (IrValueVar 0)
    "bounds_ok.0"
    (smoke-bounds-object-length-check-fragment
      20
      21
      22
      second-object
      offset
      slot-ty
      (IrValueVar 0)
      "bounds_ok.1"
      (IrInstrNil))))

(define (smoke-bounds-object-call-barrier) : CompilerIrInstrList
  (smoke-bounds-object-length-check-fragment
    10
    11
    12
    (IrValueVar 1)
    (IrValueI64 1)
    (AstTyI64)
    (IrValueVar 0)
    "bounds_ok.0"
    (compiler-ir-instr-cons
      (IrInstrCall 30 "touch" (IrCallArgsNil) (AstTyUnit))
      (smoke-bounds-object-length-check-fragment
        20
        21
        22
        (IrValueVar 1)
        (IrValueI64 1)
        (AstTyI64)
        (IrValueVar 0)
        "bounds_ok.1"
        (IrInstrNil)))))

(define (smoke-bounds-object-store-barrier) : CompilerIrInstrList
  (smoke-bounds-object-length-check-fragment
    10
    11
    12
    (IrValueVar 1)
    (IrValueI64 1)
    (AstTyI64)
    (IrValueVar 0)
    "bounds_ok.0"
    (compiler-ir-instr-cons
      (IrInstrStorePtr (IrValueVar 99) (IrValueI64 7) (AstTyI64))
      (smoke-bounds-object-length-check-fragment
        20
        21
        22
        (IrValueVar 1)
        (IrValueI64 1)
        (AstTyI64)
        (IrValueVar 0)
        "bounds_ok.1"
        (IrInstrNil)))))

(define (smoke-object-bounds-self-test) : i64
  (let
    [object-array : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsNil)
        (smoke-bounds-object-pair (IrValueVar 1) (IrValueI64 1) (AstTyI64)))]
    [object-string : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsNil)
        (smoke-bounds-object-pair (IrValueVar 1) (IrValueI64 8) (AstTyU8)))]
    [object-mismatch : CompilerIrInstrList
      (opt-bounds-instrs
        (OptBoundsNil)
        (smoke-bounds-object-pair (IrValueVar 2) (IrValueI64 1) (AstTyI64)))]
    [object-call : CompilerIrInstrList
      (opt-bounds-instrs (OptBoundsNil) (smoke-bounds-object-call-barrier))]
    [object-store : CompilerIrInstrList
      (opt-bounds-instrs (OptBoundsNil) (smoke-bounds-object-store-barrier))]
    (cond
      [(not (= (opt-count-bounds-instrs object-array) 1)) 1]
      [(not (= (opt-count-bounds-instrs object-string) 1)) 2]
      [(not (= (opt-count-bounds-instrs object-mismatch) 2)) 3]
      [(not (= (opt-count-bounds-instrs object-call) 2)) 4]
      [(not (= (opt-count-bounds-instrs object-store) 2)) 5]
      [else 42])))

(define (smoke-range-bce-entry [with-nonnegative : bool]) : CompilerIrBlock
  (compiler-ir-block
    "entry"
    (compiler-ir-instr-cons
      (IrInstrGep 3 (IrValueVar 2) (IrValueI64 1) (AstTyI64))
      (compiler-ir-instr-cons
        (IrInstrLoad 1 (IrValueVar 3) (AstTyI64))
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 0) (AstTyI64))
          (if with-nonnegative
            (compiler-ir-instr-cons
              (IrInstrBinOp
                14
                (IrBinGe)
                (IrValueVar 0)
                (IrValueI64 0)
                (AstTyBool))
              (compiler-ir-instr-cons
                (IrInstrBranch (IrValueVar 14) "lt" "exit")
                (IrInstrNil)))
            (compiler-ir-instr-cons (IrInstrJump "lt") (IrInstrNil))))))))

(define (smoke-range-bce-lt [op : CompilerIrBinOp] [length-var : i64]) : CompilerIrBlock
  (compiler-ir-block
    "lt"
    (compiler-ir-instr-cons
      (IrInstrBinOp 15 op (IrValueVar 0) (IrValueVar length-var) (AstTyBool))
      (compiler-ir-instr-cons
        (IrInstrBranch (IrValueVar 15) "body" "exit")
        (IrInstrNil)))))

(define (smoke-range-bce-body) : CompilerIrBlock
  (compiler-ir-block
    "body"
    (opt-loop-bce-string-test-ref-instrs
      2
      30
      (compiler-ir-instr-cons
        (IrInstrReturn (IrSomeValue (IrValueVar 37)))
        (IrInstrNil)))))

(define (smoke-range-bce-redefined-body) : CompilerIrBlock
  (compiler-ir-block
    "body"
    (compiler-ir-instr-cons
      (IrInstrMov 0 (IrValueI64 (- 0 1)) (AstTyI64))
      (opt-loop-bce-string-test-ref-instrs
        2
        30
        (compiler-ir-instr-cons
          (IrInstrReturn (IrSomeValue (IrValueVar 37)))
          (IrInstrNil))))))

(define (smoke-range-bce-blocks
  [with-nonnegative : bool]
  [op : CompilerIrBinOp]
  [length-var : i64]) : CompilerIrBlockList
  (compiler-ir-block-cons
    (smoke-range-bce-entry with-nonnegative)
    (compiler-ir-block-cons
      (smoke-range-bce-lt op length-var)
      (compiler-ir-block-cons
        (smoke-range-bce-body)
        (compiler-ir-block-cons (opt-loop-bce-test-exit) (IrBlockNil))))))

(define (smoke-range-bce-redefined-blocks) : CompilerIrBlockList
  (compiler-ir-block-cons
    (smoke-range-bce-entry true)
    (compiler-ir-block-cons
      (smoke-range-bce-lt (IrBinLt) 1)
      (compiler-ir-block-cons
        (smoke-range-bce-redefined-body)
        (compiler-ir-block-cons (opt-loop-bce-test-exit) (IrBlockNil))))))

(define (smoke-range-bce-count
  [with-nonnegative : bool]
  [op : CompilerIrBinOp]
  [length-var : i64]) : i64
  (opt-count-bounds-blocks
    (opt-loop-bce-blocks
      (opt-loop-bce-test-summaries false false)
      (opt-loop-bce-string-test-params)
      (smoke-range-bce-blocks with-nonnegative op length-var))))

(define (smoke-range-bce-redefined-count) : i64
  (opt-count-bounds-blocks
    (opt-loop-bce-blocks
      (opt-loop-bce-test-summaries false false)
      (opt-loop-bce-string-test-params)
      (smoke-range-bce-redefined-blocks))))

(define (smoke-range-bce-self-test) : i64
  (let
    [positive : i64 (smoke-range-bce-count true (IrBinLt) 1)]
    [missing-nonnegative : i64 (smoke-range-bce-count false (IrBinLt) 1)]
    [off-by-one : i64 (smoke-range-bce-count true (IrBinLe) 1)]
    [mismatched-length : i64 (smoke-range-bce-count true (IrBinLt) 20)]
    [redefined-index : i64 (smoke-range-bce-redefined-count)]
    (cond
      [(not (= positive 0)) 1]
      [(not (= missing-nonnegative 1)) 2]
      [(not (= off-by-one 1)) 3]
      [(not (= mismatched-length 1)) 4]
      [(not (= redefined-index 1)) 5]
      [else 42])))

(define (main) : i64
  (begin
    (unless (= (compiler-optimize-self-test) 42) (return 1))
    (unless (= (compiler-optimize-typed-fold-self-test) 42) (return 1))
    (unless (= (smoke-noop-int-cast-mov-self-test) 42) (return 1))
    (unless (= (compiler-optimize-strength-self-test) 42) (return 1))
    (unless (= (compiler-optimize-dce-self-test) 42) (return 1))
    (unless (= (compiler-optimize-dce-mem-self-test) 42) (return 1))
    (unless (= (compiler-optimize-divrem-safety-self-test) 42) (return 1))
    (unless (= (compiler-optimize-cse-self-test) 42) (return 1))
    (unless (= (compiler-optimize-copy-self-test) 42) (return 1))
    (unless (= (compiler-optimize-bounds-self-test) 42) (return 1))
    (unless (= (smoke-object-bounds-self-test) 42) (return 1))
    (unless (= (smoke-range-bce-self-test) 42) (return 1))
    (unless (= (compiler-optimize-sccp-self-test) 42) (return 1))
    (unless (= (compiler-optimize-global-value-number-self-test) 42) (return 1))
    (unless (= (compiler-optimize-cfg-self-test) 42) (return 1))
    (unless (= (compiler-optimize-natural-loop-self-test) 42) (return 1))
    (unless (= (compiler-optimize-loop-rotation-self-test) 42) (return 1))
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
    (unless (= (compiler-optimize-aggregate-candidate-self-test) 42) (return 1))
    (unless (= (compiler-optimize-aggregate-promote-self-test) 42) (return 1))
    (unless (= (compiler-optimize-aggregate-sroa-self-test) 42) (return 1))
    (unless (= (compiler-optimize-spans-self-test) 42) (return 1))
    (unless (= (compiler-optimize-gvn-self-test) 42) (return 1))
    (unless (= (compiler-optimize-load-cse-self-test) 42) (return 1))
    (unless (= (compiler-optimize-scratch-region-self-test) 42) (return 1))
    (compiler-optimize-alias-self-test)))