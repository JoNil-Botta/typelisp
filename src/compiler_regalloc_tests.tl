;; compiler_regalloc_tests.tl - Selfhost register-allocator fixtures split
;; from production (#5169).
;;
;; Only blocks gated on exactly `test` moved. The regalloc-census blocks and
;; the `(any regalloc-census test)` ones stay in the production module: they
;; compile into instrumentation builds, so they are not self-test code.
(import "compiler_regalloc.tl")
(import "compiler_abi.tl")
(import "compiler_liveness.tl")
(import stdlib.array)
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as reg_string_i64_map)
(import (hashmap.hashmap i64 i64) as reg_i64_i64_map)
(cfg test (import stdlib.test))

(define (compiler-reg-liveness-census-reset!) : unit
  (cfg
    (any regalloc-liveness-census test)
    (begin
      (set! compiler-reg-liveness-census-baseline 0)
      (set! compiler-reg-liveness-census-edge-precise 0))
    unit))

(define (compiler-reg-liveness-census-baseline-count) : i64
  (cfg
    (any regalloc-liveness-census test)
    compiler-reg-liveness-census-baseline
    0))

(define (compiler-reg-liveness-census-edge-precise-count) : i64
  (cfg
    (any regalloc-liveness-census test)
    compiler-reg-liveness-census-edge-precise
    0))

(cfg
  test
  (define (compiler-reg-low-bit-index32-powers-ok? [bit : i64] [value : i64]) : bool
    (if (= bit 32)
      (and
        (= (compiler-reg-low-bit-index32 0) 31)
        (= (compiler-reg-low-bit-index32 0x100000000) 31))
      (and
        (= (compiler-reg-low-bit-index32 value) bit)
        (compiler-reg-low-bit-index32-powers-ok? (+ bit 1) (* value 2))))))

(cfg
  test
  (define (compiler-reg-call-word-range-case [index : i64]) : i64
    (if (= index 0)
      0
      (if (= index 1)
        1
        (if (= index 2)
          2
          (if (= index 3)
            0x80000000
            (if (= index 4)
              0xffffffff
              (if (= index 5)
                0x100000000
                (if (= index 6)
                  0x100000001
                  (if (= index 7)
                    0x300000000
                    0x80000001))))))))))

(cfg
  test
  (define (compiler-reg-call-word-range-base [index : i64]) : i64
    (if (= index 0)
      0
      (if (= index 1)
        1
        (if (= index 2)
          25
          31)))))

;; Differential oracle for the mask rewrite of `compiler-reg-call-word-in-range?`.
;; `compiler-reg-call-word-count-in-range` still has the original shape -- walk
;; the set bits through `compiler-reg-low-bit-index32` and range-test each one --
;; so "any bit in range" must equal "the walk counted more than zero" for every
;; input. A disagreement is a miscompile in interference testing, not a slow
;; compile.
;;
;; The bases reach 31 and the ranges pass 40 on purpose: that is the only way to
;; exercise the edge case the rewrite folds in, where a word carrying bits above
;; position 31 reports position 31 because `compiler-reg-low-bit-index32` masks
;; to `0xffffffff` and answers 31 for an empty low word.
(cfg
  test
  (define (compiler-reg-call-word-in-range-matches-walk?) : bool
    (let
      [ok : bool true]
      [case-index : i64 0]
      (begin
        (while (< case-index 9)
          (let
            [bits : i64 (compiler-reg-call-word-range-case case-index)]
            [base-index : i64 0]
            (begin
              (while (< base-index 4)
                (let
                  [base : i64 (compiler-reg-call-word-range-base base-index)]
                  [start : i64 -2]
                  (begin
                    (while (< start 34)
                      (let
                        [end : i64 start]
                        (begin
                          (while (< end 42)
                            (begin
                              (if (=
                                (compiler-reg-call-word-in-range?
                                  bits
                                  base
                                  start
                                  end)
                                (>
                                  (compiler-reg-call-word-count-in-range
                                    bits
                                    base
                                    start
                                    end)
                                  0))
                                unit
                                (set! ok false))
                              (set! end (+ end 1))))
                          (set! start (+ start 1)))))
                    (set! base-index (+ base-index 1)))))
              (set! case-index (+ case-index 1)))))
        ok))))

(define (compiler-reg-remat-defn-with-invariant-loads?
  [instr : CompilerIrInstr]
  [allow-invariant-loads : bool]) : bool
  (match instr
    [(CompilerIrInstr.Mov _ value _)
      (compiler-reg-remat-mov-value? value allow-invariant-loads)]
    [(CompilerIrInstr.Gep _ base offset _)
      (compiler-reg-remat-gep? base offset)]
    [(CompilerIrInstr.Load _ src _)
      (compiler-reg-remat-load? src allow-invariant-loads)]
    [_ false]))

(define (compiler-reg-remat-defn? [instr : CompilerIrInstr]) : bool
  (compiler-reg-remat-defn-with-invariant-loads? instr false))

(define (compiler-reg-function-ref-counts [func : CompilerIrFunction]) : (Array
    i64)
  (match func
    [(CompilerIrFunction.Function _ _ _ vars blocks)
      (let
        [counts : (Array i64) (array.make-array i64 vars)]
        (begin
          (compiler-reg-fill-i64-array counts 0)
          (compiler-reg-ref-counts-blocks! counts blocks)
          counts))]))

(define (compiler-reg-function-spill-weights-remat
  [func : CompilerIrFunction]
  [coalesce : CompilerRegCoalesceMap]) : (Array i64)
  (match func
    [(CompilerIrFunction.Function _ _ _ vars blocks)
      (let
        [counts : (Array i64) (array.make-array i64 vars)]
        [def-status : (Array i64) (array.make-array i64 vars)]
        [depths : (Array i64) (compiler-reg-function-loop-depths blocks)]
        [allow-invariant-loads : bool
          (compiler-reg-remat-invariant-loads-ok? func)]
        (begin
          (compiler-reg-fill-i64-array counts 0)
          (compiler-reg-fill-i64-array def-status 0)
          (compiler-reg-ref-counts-blocks-weighted-remat!
            counts
            def-status
            blocks
            depths
            0
            allow-invariant-loads)
          (compiler-reg-remat-discount-single-def-spill-weights!
            counts
            def-status
            coalesce)
          counts))]))

;; One-pass spill weights for the scalar-opt2 greedy: the remat walk accumulates
;; the exact raw use/def counts the plain spill-weights walk computes (same
;; adds, plus the def-status tracking), so the two per-function walks collapse
;; into one. Returns the same combined array as
;; (combine (merge (remat-discounted weights)) (merge (raw weights))).
(define (compiler-reg-edge-copy-plan-for-region
  [func : CompilerIrFunction]
  [region-labels : CompilerRegLabelList]
  [stack-var : i64]
  [region-var : i64]
  [ty : AstType]) : CompilerRegEdgeCopyPlan
  ;; Per-var (read-only / non-phi self-loop) planning: empty member set selects
  ;; the existing per-var liveness test in boundary-one (byte-identical).
  (compiler-reg-edge-copy-plan-for-region-members
    func
    region-labels
    stack-var
    region-var
    ty
    (compiler-live-set-empty)))

;; Group-aware planning for the SplitKit phi-carried homing: `members` is the
;; coalesce group's bitset; boundary edges are tested against any-member liveness.
(define (compiler-reg-plan-function-avx2 [func : CompilerIrFunction]) : CompilerRegPlan
  (compiler-reg-plan-function-avx2-for-abi CompilerRegTargetAbi.Linux func))

;; Scalar register plan (#perf, opt level 2): full dataflow live intervals for
;; ALL functions, structural ineligibility that keeps call-spanning
;; integers/handles in callee-saved registers and applies ABI XMM clobber
;; constraints to float candidates.
;;
;; The precise (segmented, hole-aware) interval builder feeds
;; compiler-reg-vars-interfere-segmented-index?, whose exact segment-overlap test
;; only fires when BOTH values carry segments; otherwise it falls back to the
;; coarse whole-[start,end] overlap, which manufactures phantom conflicts between
;; values whose live ranges are actually disjoint. The cheap block-level builder
;; (compiler-reg-block-intervals) leaves segments empty, so every function on it
;; is stuck with that conservative fallback.
;;
;; History (M-D): precise intervals were once limited to 2-10-block functions,
;; then extended to >= 100 blocks (#regalloc: -90 net static stack reloads in
;; the self-host's huge walkers, full-liveness compile cost negligible). The
;; 11-99-block band and single-block functions were deliberately kept coarse
;; because a measurement AT THAT TIME showed precise intervals in the medium
;; band perturbed the greedy spill-victim/eviction heuristics non-monotonically
;; and net-regressed reloads. That measurement predates params-as-greedy-
;; candidates (M-A) and dead result-store elision (M-B), which reshaped the
;; interference/pressure landscape; re-measured after M-B, precise intervals
;; everywhere are a net win, so every scalar-mode function now gets the precise
;; builder (single-block functions included: multi-def vars with disjoint
;; single-block ranges suffer the same phantom conflicts under the coarse
;; fallback, and the M-A param entry-extension below runs on the interval
;; index regardless of builder). This predicate also gates the loop-split
;; rescue passes, which require the precise index; they now run for every
;; function shape. The coarse compiler-reg-block-intervals branch in
;; compiler-reg-plan-function-scalar-for-abi is kept as the fallback: flipping
;; this predicate is the single switch back should a pathological shape appear.
;;
;; NOTE: enabling this detonated a LATENT BACKEND BUG, fixed together with it:
;; precise mid-band plans saturate the register pool, so the backend's
;; EMERGENCY scavenge (all pool regs occupied) started firing in fused
;; destructure emitters, where its candidate pick ignored the sibling load's
;; register home and the emergency-wrap restore overwrote the just-loaded
;; result (false OOB abort in lex-parse-based-int). See the M-D clobber fix in
;; compiler-backend-emit-load-from-gep-pair / compiler-backend-emit-load-load.
(cfg
  test
  (define (compiler-reg-early-exit-general-test-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "early_exit_general")
      (compiler-ir-param-cons
        (CompilerIrParam.Param "n" (AstType.I64) 0)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "limit" (AstType.I64) 1)
          CompilerIrParamList.Nil))
      (AstType.I64)
      5
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              2
              (CompilerIrBinOp.Le)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.I64 0)
              (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Var 2)
                (compiler-ir-label "zero")
                (compiler-ir-label "guard_limit"))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "zero")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
              CompilerIrInstrList.Nil))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "guard_limit")
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  3
                  (CompilerIrBinOp.Gt)
                  (CompilerIrValue.Var 0)
                  (CompilerIrValue.Var 1)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Branch
                    (CompilerIrValue.Var 3)
                    (compiler-ir-label "one")
                    (compiler-ir-label "body"))
                  CompilerIrInstrList.Nil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "one")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.I64 1)))
                  CompilerIrInstrList.Nil))
              (compiler-ir-block-cons
                (compiler-ir-block
                  (compiler-ir-label "body")
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Call
                      4
                      (compiler-ir-test-symbol "work")
                      CompilerIrCallArgs.Nil
                      (AstType.I64))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Jump (compiler-ir-label "entry"))
                      CompilerIrInstrList.Nil)))
                CompilerIrBlockList.Nil))))))))

(cfg
  test
  (define (compiler-reg-early-exit-general-ok?) : bool
    (match (compiler-reg-early-exit-shrinkwrap-function
      (compiler-reg-early-exit-general-test-function))
      [(CompilerIrFunction.Function _ params ret-ty _ blocks)
        (let
          [seq : CompilerIrBlockSeq (compiler-live-ir-block-list-to-seq blocks)]
          [body : CompilerIrInstrSeq
            (match (compiler-ir-block-seq-ref seq 5)
              [(CompilerIrBlock.Block _ instrs) instrs])]
          (and
            (= (compiler-ir-param-list-count params) 2)
            (match ret-ty
              [(AstType.I64) true]
              [_ false])
            (= (compiler-ir-block-seq-count seq) 10)
            (= compiler-reg-early-exit-prefix-count 4)
            (=
              compiler-reg-early-exit-saving-label
              (compiler-ir-label "entry__shrinkwrap_save"))
            (string.eq
              compiler-reg-early-exit-bare-label
              "entry__shrinkwrap_bare")
            (match (compiler-ir-block-seq-ref seq 0)
              [(CompilerIrBlock.Block label instrs)
                (and
                  (= label (compiler-ir-label "entry"))
                  (match (compiler-ir-instr-seq-ref instrs 1)
                    [(CompilerIrInstr.Branch _ yes no)
                      (and
                        (= yes (compiler-ir-label "entry__shrinkwrap_bare0"))
                        (= no (compiler-ir-label "guard_limit")))]
                    [_ false]))])
            (match (compiler-ir-block-seq-ref seq 1)
              [(CompilerIrBlock.Block label instrs)
                (and
                  (= label (compiler-ir-label "guard_limit"))
                  (match (compiler-ir-instr-seq-ref instrs 1)
                    [(CompilerIrInstr.Branch _ yes no)
                      (and
                        (= yes (compiler-ir-label "entry__shrinkwrap_bare1"))
                        (= no (compiler-ir-label "entry__shrinkwrap_save")))]
                    [_ false]))])
            (match (compiler-ir-instr-seq-ref body 1)
              [(CompilerIrInstr.Jump target)
                (= target (compiler-ir-label "entry__shrinkwrap_framed"))]
              [_ false])
            (match (compiler-ir-block-seq-ref seq 7)
              [(CompilerIrBlock.Block label _)
                (= label (compiler-ir-label "guard_limit__shrinkwrap_framed"))])))])))

(cfg
  test
  (define (compiler-reg-early-exit-float-guard-test-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "early_exit_float_guard")
      (compiler-ir-param-cons
        (CompilerIrParam.Param "actual" (AstType.F64) 0)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "expected" (AstType.F64) 1)
          CompilerIrParamList.Nil))
      (AstType.Unit)
      4
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              2
              (CompilerIrBinOp.Eq)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 1)
              (AstType.F64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Var 2)
                (compiler-ir-label "equal")
                (compiler-ir-label "failure"))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "equal")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return CompilerIrMaybeValue.No)
              CompilerIrInstrList.Nil))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "failure")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Call
                  3
                  (compiler-ir-test-symbol "report_float_failure")
                  CompilerIrCallArgs.Nil
                  (AstType.Unit))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                  CompilerIrInstrList.Nil)))
            CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-early-exit-float-guard-refused-ok?) : bool
    (match (compiler-reg-early-exit-shrinkwrap-function
      (compiler-reg-early-exit-float-guard-test-function))
      [(CompilerIrFunction.Function _ _ _ _ blocks)
        (and
          (=
            (compiler-ir-block-seq-count
              (compiler-live-ir-block-list-to-seq blocks))
            3)
          (= compiler-reg-early-exit-prefix-count 0)
          (not (compiler-ir-label-some? compiler-reg-early-exit-saving-label))
          (string.eq compiler-reg-early-exit-bare-label ""))])))

(cfg
  test
  (define (compiler-reg-cold-call-test-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "cold_call_split")
      (compiler-ir-param-cons
        (CompilerIrParam.Param "map" (compiler-reg-i64-ty) 0)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "key" (compiler-reg-i64-ty) 1)
          (compiler-ir-param-cons
            (CompilerIrParam.Param "value" (compiler-reg-i64-ty) 2)
            CompilerIrParamList.Nil)))
      (AstType.I64)
      6
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Branch
              (CompilerIrValue.Bool false)
              (compiler-ir-label "cold")
              (compiler-ir-label "bypass"))
            CompilerIrInstrList.Nil))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "cold")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Call
                3
                (compiler-ir-test-symbol "grow")
                (CompilerIrCallArgs.Nil)
                (AstType.Unit))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "join"))
                CompilerIrInstrList.Nil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "bypass")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "join"))
                CompilerIrInstrList.Nil))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "join")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    4
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 0)
                    (CompilerIrValue.Var 1)
                    (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.BinOp
                      5
                      (CompilerIrBinOp.Add)
                      (CompilerIrValue.Var 4)
                      (CompilerIrValue.Var 2)
                      (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                      CompilerIrInstrList.Nil))))
              (compiler-ir-block-cons
                (compiler-ir-block
                  (compiler-ir-label "loop")
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Branch
                      (CompilerIrValue.Bool false)
                      (compiler-ir-label "loop")
                      (compiler-ir-label "exit"))
                    CompilerIrInstrList.Nil))
                (compiler-ir-block-cons
                  (compiler-ir-block
                    (compiler-ir-label "exit")
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Return
                        (CompilerIrMaybeValue.Some (CompilerIrValue.Var 5)))
                      CompilerIrInstrList.Nil))
                  CompilerIrBlockList.Nil)))))))))

(cfg
  test
  (define (compiler-reg-cold-call-test-mov?
    [instr : CompilerIrInstr]
    [dst : i64]
    [src : i64]) : bool
    (match instr
      [(CompilerIrInstr.Mov found-dst (CompilerIrValue.Var found-src) _)
        (and (= found-dst dst) (= found-src src))]
      [_ false])))

(cfg
  test
  (define (compiler-reg-cold-call-split-ok?) : bool
    (let
      [rewrite : CompilerRegColdCallRewrite
        (compiler-reg-cold-call-rewrite-function
          (ast-node-pool-reader-type-segment-bases)
          (compiler-reg-cold-call-test-function))]
      [rewritten : CompilerIrFunction
        (compiler-reg-cold-call-rewrite-function-value rewrite)]
      [temp-start : i64 (compiler-reg-cold-call-rewrite-temp-start rewrite)]
      (match rewritten
        [(CompilerIrFunction.Function _ _ _ vars blocks)
          (let
            [seq : CompilerIrBlockSeq
              (compiler-live-ir-block-list-to-seq blocks)]
            [instrs : CompilerIrInstrSeq
              (match (compiler-ir-block-seq-ref seq 1)
                [(CompilerIrBlock.Block _ found) found])]
            [plan : CompilerRegPlan
              (compiler-reg-plan-function-scalar-cold-for-abi
                CompilerRegTargetAbi.Linux
                rewritten
                temp-start)]
            (and
              (= temp-start 6)
              (= vars 9)
              (= (compiler-ir-instr-seq-count instrs) 8)
              (compiler-reg-cold-call-test-mov?
                (compiler-ir-instr-seq-ref instrs 0)
                6
                0)
              (compiler-reg-cold-call-test-mov?
                (compiler-ir-instr-seq-ref instrs 1)
                7
                1)
              (compiler-reg-cold-call-test-mov?
                (compiler-ir-instr-seq-ref instrs 2)
                8
                2)
              (match (compiler-ir-instr-seq-ref instrs 3)
                [(CompilerIrInstr.Call _ _ _ _) true]
                [_ false])
              (compiler-reg-cold-call-test-mov?
                (compiler-ir-instr-seq-ref instrs 4)
                0
                6)
              (compiler-reg-cold-call-test-mov?
                (compiler-ir-instr-seq-ref instrs 5)
                1
                7)
              (compiler-reg-cold-call-test-mov?
                (compiler-ir-instr-seq-ref instrs 6)
                2
                8)
              (match (compiler-ir-instr-seq-ref instrs 7)
                [(CompilerIrInstr.Jump target)
                  (= target (compiler-ir-label "join"))]
                [_ false])
              (compiler-reg-location-register?
                (match plan
                  [(CompilerRegPlan.Plan assignments _ _ _ _ _)
                    (compiler-reg-assignment-lookup assignments 0)])
                compiler-reg-id-rdi)
              (compiler-reg-location-register?
                (match plan
                  [(CompilerRegPlan.Plan assignments _ _ _ _ _)
                    (compiler-reg-assignment-lookup assignments 1)])
                compiler-reg-id-rsi)
              (compiler-reg-location-register?
                (match plan
                  [(CompilerRegPlan.Plan assignments _ _ _ _ _)
                    (compiler-reg-assignment-lookup assignments 2)])
                compiler-reg-id-rdx)
              (compiler-reg-cold-call-carriers-stack? plan temp-start vars)))]))))

;; Fast scalar backend plan: keep type discovery for emission decisions, but
;; leave values in their stack slots instead of spending compile time on liveness
;; and register assignment. AVX/vector backend modes still use full regalloc.
(cfg
  test
  (define (compiler-reg-param-register-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "param_registers")
      (compiler-ir-param-cons
        (CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "b" (compiler-reg-i64-ty) 1)
          (compiler-ir-param-cons
            (CompilerIrParam.Param "c" (compiler-reg-i64-ty) 2)
            CompilerIrParamList.Nil)))
      (AstType.Unit)
      3
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "pa")
              (CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Store
                (compiler-ir-test-symbol "pb")
                (CompilerIrValue.Var 1)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Store
                  (compiler-ir-test-symbol "pc")
                  (CompilerIrValue.Var 2)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                  CompilerIrInstrList.Nil)))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-float-param-register-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "float_param_registers")
      (compiler-ir-param-cons
        (CompilerIrParam.Param "a" (compiler-reg-f64-ty) 0)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "b" (compiler-reg-f64-ty) 1)
          (compiler-ir-param-cons
            (CompilerIrParam.Param "c" (compiler-reg-f64-ty) 2)
            CompilerIrParamList.Nil)))
      (AstType.Unit)
      3
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "fa")
              (CompilerIrValue.Var 0)
              (compiler-reg-f64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Store
                (compiler-ir-test-symbol "fb")
                (CompilerIrValue.Var 1)
                (compiler-reg-f64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Store
                  (compiler-ir-test-symbol "fc")
                  (CompilerIrValue.Var 2)
                  (compiler-reg-f64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                  CompilerIrInstrList.Nil)))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-low-xmm-splat-boundary-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "low_xmm_splat_boundary")
      (compiler-ir-param-cons
        (CompilerIrParam.Param "value" (compiler-reg-f64-ty) 0)
        CompilerIrParamList.Nil)
      (AstType.Unit)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Splat 1 (CompilerIrValue.I64 7) 4 (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Store
                (compiler-ir-test-symbol "low_xmm_splat_sink")
                (CompilerIrValue.Var 0)
                (compiler-reg-f64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                CompilerIrInstrList.Nil))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-low-xmm-vector-clobber-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "low_xmm_vector_clobber")
      (compiler-ir-param-cons
        (CompilerIrParam.Param "value" (compiler-reg-f64-ty) 0)
        CompilerIrParamList.Nil)
      (AstType.Unit)
      4
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Splat 1 (CompilerIrValue.I64 3) 4 (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Splat 2 (CompilerIrValue.I64 5) 4 (AstType.I64))
              (compiler-ir-instr-cons
                (ir-instr-vector-bin-op
                  3
                  (CompilerIrBinOp.Mul)
                  (CompilerIrValue.Var 1)
                  (CompilerIrValue.Var 2)
                  4
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Store
                    (compiler-ir-test-symbol "low_xmm_vector_sink")
                    (CompilerIrValue.Var 0)
                    (compiler-reg-f64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                    CompilerIrInstrList.Nil))))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-low-xmm-vector-boundaries-ok?) : bool
    (match (compiler-reg-plan-function-scalar
      (compiler-reg-low-xmm-splat-boundary-function))
      [(CompilerRegPlan.Plan splat-assignments _ _ _ _ _)
        (match (compiler-reg-plan-function-scalar
          (compiler-reg-low-xmm-vector-clobber-function))
          [(CompilerRegPlan.Plan clobber-assignments _ _ _ _ _)
            (and
              (cfg
                scratch-vreg
                (compiler-reg-location-register?
                  (compiler-reg-assignment-lookup splat-assignments 0)
                  (compiler-abi-xmm-register-id 0))
                (not
                  (compiler-reg-location-any-register?
                    (compiler-reg-assignment-lookup splat-assignments 0))))
              (not
                (compiler-reg-location-register?
                  (compiler-reg-assignment-lookup clobber-assignments 0)
                  (compiler-abi-xmm-register-id 0)))
              (not
                (compiler-reg-location-register?
                  (compiler-reg-assignment-lookup clobber-assignments 0)
                  (compiler-abi-xmm-register-id 1))))])])))

(cfg
  test
  (define (compiler-reg-mixed-float-call-arg-function) : CompilerIrFunction
    (let
      [args : (Array CompilerIrValue) (array.make-array CompilerIrValue 4)]
      (begin
        (array-set! args 0 (CompilerIrValue.Var 0))
        (array-set! args 1 (CompilerIrValue.Var 1))
        (array-set! args 2 (CompilerIrValue.Var 2))
        (array-set! args 3 (CompilerIrValue.Var 3))
        (CompilerIrFunction.Function
          (compiler-ir-test-symbol "mixed_float_call_args")
          (compiler-ir-param-cons
            (CompilerIrParam.Param "i" (compiler-reg-i64-ty) 0)
            (compiler-ir-param-cons
              (CompilerIrParam.Param "a" (compiler-reg-f64-ty) 1)
              (compiler-ir-param-cons
                (CompilerIrParam.Param "b" (compiler-reg-f64-ty) 2)
                (compiler-ir-param-cons
                  (CompilerIrParam.Param "c" (compiler-reg-f64-ty) 3)
                  CompilerIrParamList.Nil))))
          (AstType.Unit)
          5
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "entry")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Call
                  4
                  (compiler-ir-test-symbol "mixed_float_callee")
                  (CompilerIrCallArgs.Array args)
                  (AstType.Unit))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                  CompilerIrInstrList.Nil)))
            CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-win64-rsi-rdi-pressure-function) : CompilerIrFunction
    (let
      [instrs : CompilerIrInstrList CompilerIrInstrList.Nil]
      [params : CompilerIrParamList CompilerIrParamList.Nil]
      [i : i64 6]
      (begin
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return CompilerIrMaybeValue.No)
            instrs))
        (while (>= i 0)
          (begin
            (set!
              instrs
              (compiler-ir-instr-cons
                (CompilerIrInstr.Store
                  (compiler-ir-test-symbol "g")
                  (CompilerIrValue.Var i)
                  (compiler-reg-i64-ty))
                instrs))
            (set! i (- i 1))))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Call
              7
              (compiler-ir-test-symbol "side_effect")
              (CompilerIrCallArgs.Nil)
              (AstType.Unit))
            instrs))
        (set! i 6)
        (while (>= i 0)
          (begin
            (set!
              params
              (compiler-ir-param-cons
                (CompilerIrParam.Param
                  (string.append "p" (string.int->string i))
                  (compiler-reg-i64-ty)
                  i)
                params))
            (set! i (- i 1))))
        (CompilerIrFunction.Function
          (compiler-ir-test-symbol "win64_rsi_rdi_pressure")
          params
          (AstType.Unit)
          8
          (compiler-ir-block-cons
            (compiler-ir-block (compiler-ir-label "entry") instrs)
            CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-zero-call-param-conflict-function) : CompilerIrFunction
    (let
      [instrs : CompilerIrInstrList CompilerIrInstrList.Nil]
      (begin
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return CompilerIrMaybeValue.No)
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "p5")
              (CompilerIrValue.Var 5)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "g12")
              (CompilerIrValue.Var 12)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "g11")
              (CompilerIrValue.Var 11)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "g10")
              (CompilerIrValue.Var 10)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "g9")
              (CompilerIrValue.Var 9)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "g8")
              (CompilerIrValue.Var 8)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "g7")
              (CompilerIrValue.Var 7)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "g6")
              (CompilerIrValue.Var 6)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              12
              (CompilerIrValue.I64 12)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              11
              (CompilerIrValue.I64 11)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              10
              (CompilerIrValue.I64 10)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              9
              (CompilerIrValue.I64 9)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              8
              (CompilerIrValue.I64 8)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              7
              (CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              6
              (CompilerIrValue.I64 6)
              (compiler-reg-i64-ty))
            instrs))
        (CompilerIrFunction.Function
          (compiler-ir-test-symbol "zero_call_param_conflict")
          (compiler-ir-param-cons
            (CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
            (compiler-ir-param-cons
              (CompilerIrParam.Param "b" (compiler-reg-i64-ty) 1)
              (compiler-ir-param-cons
                (CompilerIrParam.Param "c" (compiler-reg-i64-ty) 2)
                (compiler-ir-param-cons
                  (CompilerIrParam.Param "d" (compiler-reg-i64-ty) 3)
                  (compiler-ir-param-cons
                    (CompilerIrParam.Param "e" (compiler-reg-i64-ty) 4)
                    (compiler-ir-param-cons
                      (CompilerIrParam.Param "f" (compiler-reg-i64-ty) 5)
                      CompilerIrParamList.Nil))))))
          (AstType.Unit)
          13
          (compiler-ir-block-cons
            (compiler-ir-block (compiler-ir-label "entry") instrs)
            CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-param-clobber-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "param_clobber")
      (compiler-ir-param-cons
        (CompilerIrParam.Param "arg" (compiler-reg-i64-ty) 0)
        CompilerIrParamList.Nil)
      (AstType.I64)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Call
              1
              (compiler-ir-test-symbol "side_effect")
              (CompilerIrCallArgs.Nil)
              (AstType.Unit))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
              CompilerIrInstrList.Nil)))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-param-aggregate-function) : CompilerIrFunction
    (let
      [ty : AstType (AstType.Struct (intern "ParamAggregate"))]
      (CompilerIrFunction.Function
        (compiler-ir-test-symbol "param_aggregate")
        (compiler-ir-param-cons
          (CompilerIrParam.Param "state" ty 0)
          CompilerIrParamList.Nil)
        (AstType.Unit)
        2
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "entry")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov 1 (CompilerIrValue.Var 0) ty)
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                CompilerIrInstrList.Nil)))
          CompilerIrBlockList.Nil)))))

(cfg
  test
  ;; GAP3a: zero-call function whose only would-be clobber is a shift by an
  ;; in-range CONSTANT (emitted as `shrq $3` -- no %rcx/%cl use). Params keep
  ;; their ABI pins.
  (define (compiler-reg-param-const-shift-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "param_const_shift")
      (compiler-ir-param-cons
        (CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "n" (compiler-reg-i64-ty) 1)
          CompilerIrParamList.Nil))
      (AstType.I64)
      3
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              2
              (CompilerIrBinOp.Shr)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.I64 3)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                2
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 2)
                (CompilerIrValue.Var 1)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
                CompilerIrInstrList.Nil))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  ;; GAP3a counterpart: a VARIABLE-count shift stays a clobber point (the
  ;; backend moves the count into %rcx and shifts by %cl). `a` (var 0) is live
  ;; across the shift: t = a >> n; return t + a.
  (define (compiler-reg-param-var-shift-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "param_var_shift")
      (compiler-ir-param-cons
        (CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "n" (compiler-reg-i64-ty) 1)
          CompilerIrParamList.Nil))
      (AstType.I64)
      3
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              2
              (CompilerIrBinOp.Shr)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 1)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                2
                (CompilerIrBinOp.Add)
                (CompilerIrValue.Var 2)
                (CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 2)))
                CompilerIrInstrList.Nil))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  ;; GAP3a: constant in-range shifts are not clobber points, so the pin gate
  ;; sees a clobber-free function and both params keep their incoming ABI
  ;; registers (%rdi/%rsi) -- the crc_update shape.
  (define (compiler-reg-scalar-param-const-shift-pin-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegTargetAbi.Linux
      (compiler-reg-param-const-shift-function))
      [(CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (compiler-live-set-contains? ineligible 0))
          (not (compiler-live-set-contains? ineligible 1))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 0)
            compiler-reg-id-rdi)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 1)
            compiler-reg-id-rsi))])))

(cfg
  test
  ;; GAP3c: a variable-count shift clobbers only %rcx, so per-register pin
  ;; gating keeps BOTH pins here: a (%rdi) spans the shift but %rdi is not
  ;; shift-clobbered, and n (%rsi, the count) is last-used AT the shift so it
  ;; does not span it. (Pre-GAP3c the function-global gate revoked both ->
  ;; greedy CSR homes; the %rcx narrowing is asserted by
  ;; compiler-reg-scalar-param-rcx-shift-span-ok? below.)
  (define (compiler-reg-scalar-param-var-shift-pin-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegTargetAbi.Linux
      (compiler-reg-param-var-shift-function))
      [(CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (compiler-live-set-contains? ineligible 0))
          (not (compiler-live-set-contains? ineligible 1))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 0)
            compiler-reg-id-rdi)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 1)
            compiler-reg-id-rsi))])))

(cfg
  test
  ;; GAP3c: params fully consumed BEFORE the first clobber point keep their
  ;; ABI pins even though the function has a call. t = a + a; call; return
  ;; t + t -- a (var 0) ends at point 0, the call is at point 2, so %rdi stays
  ;; pinned while the call-spanning t (var 1) takes a callee-saved home.
  (define (compiler-reg-param-dead-before-call-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "param_dead_before_call")
      (compiler-ir-param-cons
        (CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
        CompilerIrParamList.Nil)
      (AstType.I64)
      4
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              1
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Call
                2
                (compiler-ir-test-symbol "side_effect")
                (CompilerIrCallArgs.Nil)
                (AstType.Unit))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  3
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 1)
                  (CompilerIrValue.Var 1)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 3)))
                  CompilerIrInstrList.Nil)))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-scalar-param-dead-before-call-pin-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegTargetAbi.Linux
      (compiler-reg-param-dead-before-call-function))
      [(CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (compiler-live-set-contains? ineligible 0))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 0)
            compiler-reg-id-rdi)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 1)
            compiler-reg-id-r12))])))

(cfg
  test
  ;; GAP3c div spanning: v3 = v0 + v0; v4 = v3 / v1; v5 = v4 + v2; return v5.
  ;; A div bans EVERY pin it is spanned by (%rax:%rdx hardwiring + the canned
  ;; divmod expansion's scratch hunger), so the %rdx param v2 -- live across
  ;; it (last use point 4) -- must NOT keep its pin (greedy CSR home instead),
  ;; while v0 (%rdi, ends point 0) and v1 (%rsi, the divisor, last-used AT
  ;; the div = read before the clobber) keep theirs.
  (define (compiler-reg-param-rdx-div-span-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "param_rdx_div_span")
      (compiler-ir-param-cons
        (CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "b" (compiler-reg-i64-ty) 1)
          (compiler-ir-param-cons
            (CompilerIrParam.Param "c" (compiler-reg-i64-ty) 2)
            CompilerIrParamList.Nil)))
      (AstType.I64)
      6
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              3
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                4
                (CompilerIrBinOp.Div)
                (CompilerIrValue.Var 3)
                (CompilerIrValue.Var 1)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  5
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 4)
                  (CompilerIrValue.Var 2)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 5)))
                  CompilerIrInstrList.Nil)))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-scalar-param-rdx-div-span-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegTargetAbi.Linux
      (compiler-reg-param-rdx-div-span-function))
      [(CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (compiler-live-set-contains? ineligible 2))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 0)
            compiler-reg-id-rdi)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 1)
            compiler-reg-id-rsi)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 2)
            compiler-reg-id-r12))])))

(cfg
  test
  ;; GAP3c per-register narrowing, shift: v4 = v0 + v0; v5 = v4 << v1;
  ;; v6 = v5 + v2; v7 = v6 + v3; return v7. The variable shift (point 2)
  ;; hardwires only %rcx, so the %rcx param v3 -- live across it (last use
  ;; point 6) -- must NOT keep its pin, while v2 (%rdx) ALSO spans the shift
  ;; and keeps its pin (%rdx is not shift-clobbered), and v0/v1 end at/before
  ;; the shift and keep theirs.
  (define (compiler-reg-param-rcx-shift-span-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "param_rcx_shift_span")
      (compiler-ir-param-cons
        (CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "n" (compiler-reg-i64-ty) 1)
          (compiler-ir-param-cons
            (CompilerIrParam.Param "c" (compiler-reg-i64-ty) 2)
            (compiler-ir-param-cons
              (CompilerIrParam.Param "d" (compiler-reg-i64-ty) 3)
              CompilerIrParamList.Nil))))
      (AstType.I64)
      8
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              4
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                5
                (CompilerIrBinOp.Shl)
                (CompilerIrValue.Var 4)
                (CompilerIrValue.Var 1)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  6
                  (CompilerIrBinOp.Add)
                  (CompilerIrValue.Var 5)
                  (CompilerIrValue.Var 2)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    7
                    (CompilerIrBinOp.Add)
                    (CompilerIrValue.Var 6)
                    (CompilerIrValue.Var 3)
                    (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Return
                      (CompilerIrMaybeValue.Some (CompilerIrValue.Var 7)))
                    CompilerIrInstrList.Nil))))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-scalar-param-rcx-shift-span-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegTargetAbi.Linux
      (compiler-reg-param-rcx-shift-span-function))
      [(CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (compiler-live-set-contains? ineligible 3))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 0)
            compiler-reg-id-rdi)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 1)
            compiler-reg-id-rsi)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 2)
            compiler-reg-id-rdx)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 3)
            compiler-reg-id-r12))])))

(cfg
  test
  ;; GAP3c coalesce-hull demotion (the soundness net for per-interval pins):
  ;; v3 = v0 + v0; Mov v1 <- v0 (v0's last use, boundary touch -> v1
  ;; disjoint-coalesces with the param); call; store v1. The walk pins v0 on
  ;; its own clobber-free interval [0,2], but the class {v0,v1} hull [0,6]
  ;; spans the call -- a kept pin would make the post-call store read a
  ;; clobbered %rdi. compiler-reg-param-pins-demote! must revoke the pin and
  ;; the class must land on ONE callee-saved home instead.
  (define (compiler-reg-param-pin-coalesce-demote-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "param_pin_coalesce_demote")
      (compiler-ir-param-cons
        (CompilerIrParam.Param "a" (compiler-reg-i64-ty) 0)
        CompilerIrParamList.Nil)
      (AstType.Unit)
      4
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              3
              (CompilerIrBinOp.Add)
              (CompilerIrValue.Var 0)
              (CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov
                1
                (CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Call
                  2
                  (compiler-ir-test-symbol "side_effect")
                  (CompilerIrCallArgs.Nil)
                  (AstType.Unit))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Store
                    (compiler-ir-test-symbol "g")
                    (CompilerIrValue.Var 1)
                    (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                    CompilerIrInstrList.Nil))))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-scalar-param-pin-coalesce-demote-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegTargetAbi.Linux
      (compiler-reg-param-pin-coalesce-demote-function))
      [(CompilerRegPlan.Plan assignments _ _ _ _ _)
        (and
          (not
            (compiler-reg-location-register?
              (compiler-reg-assignment-lookup assignments 0)
              compiler-reg-id-rdi))
          (compiler-reg-location-any-register?
            (compiler-reg-assignment-lookup assignments 0))
          (compiler-reg-same-location? assignments 0 1))])))

(define (compiler-reg-self-loop-exit-live-phi-mask-ok?) : bool
  (let
    [loop-first : CompilerIrFunction
      (compiler-reg-self-loop-exit-live-phi-function true)]
    [exit-first : CompilerIrFunction
      (compiler-reg-self-loop-exit-live-phi-function false)]
    [loop-first-mask : (Array i64)
      (compiler-reg-function-phi-touched-safe
        loop-first
        (compiler-live-analyze-function-edge-precise loop-first))]
    [exit-first-mask : (Array i64)
      (compiler-reg-function-phi-touched-safe
        exit-first
        (compiler-live-analyze-function-edge-precise exit-first))]
    [fixed-register-mask : (Array i64)
      (compiler-reg-function-phi-touched-safe-mode
        loop-first
        (compiler-live-analyze-function-edge-precise loop-first)
        false)]
    (and
      (compiler-reg-self-loop-exit-live-phi-mask-shape-ok? loop-first-mask)
      (compiler-reg-self-loop-exit-live-phi-mask-shape-ok? exit-first-mask)
      (= (array-ref fixed-register-mask 0) 0)
      (= (array-ref fixed-register-mask 3) 0))))

(cfg
  test
  (define (compiler-reg-indirect-call-arg-prefs-ok?) : bool
    (let
      [pool : CompilerRegIdList
        (compiler-reg-greedy-integer-pool-for-abi CompilerRegTargetAbi.Linux)]
      [prefs : (Array i64)
        (compiler-reg-function-arg-prefs
          CompilerRegTargetAbi.Linux
          (compiler-reg-indirect-call-arg-function)
          (compiler-reg-test-identity-coalesce 4)
          4)]
      (and
        (= (array-ref prefs 0) -1)
        (=
          (array-ref prefs 1)
          (compiler-reg-id-list-index-of pool compiler-reg-id-rsi 0))
        (=
          (array-ref prefs 2)
          (compiler-reg-id-list-index-of pool compiler-reg-id-rdx 0))))))

(cfg
  test
  (define (compiler-reg-scalar-linux-param-registers-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegTargetAbi.Linux
      (compiler-reg-param-register-function))
      [(CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (compiler-live-set-contains? ineligible 0))
          (not (compiler-live-set-contains? ineligible 1))
          (not (compiler-live-set-contains? ineligible 2))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 0)
            compiler-reg-id-rdi)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 1)
            compiler-reg-id-rsi)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 2)
            compiler-reg-id-rdx))])))

(cfg
  test
  ;; Win64 zero-clobber pins: params 0/1 keep %rcx/%rdx. Param 2's incoming
  ;; register (%r8) is excluded from the legacy pin set, but M-A (RC1) makes it
  ;; a greedy candidate: it takes the first callee-saved home instead of being
  ;; stack-homed.
  (define (compiler-reg-scalar-windows-param-registers-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegTargetAbi.Windows
      (compiler-reg-param-register-function))
      [(CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (compiler-live-set-contains? ineligible 0))
          (not (compiler-live-set-contains? ineligible 1))
          (not (compiler-live-set-contains? ineligible 2))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 0)
            compiler-reg-id-rcx)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 1)
            compiler-reg-id-rdx)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 2)
            compiler-reg-id-r12))])))

(cfg
  test
  (define (compiler-reg-scalar-float-param-registers-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegTargetAbi.Linux
      (compiler-reg-float-param-register-function))
      [(CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (compiler-live-set-contains? ineligible 0))
          (not (compiler-live-set-contains? ineligible 1))
          (not (compiler-live-set-contains? ineligible 2))
          (cfg
            scratch-vreg
            (and
              (compiler-reg-location-register?
                (compiler-reg-assignment-lookup assignments 0)
                (compiler-abi-xmm-register-id 0))
              (compiler-reg-location-register?
                (compiler-reg-assignment-lookup assignments 1)
                (compiler-abi-xmm-register-id 1)))
            (and
              (not
                (compiler-reg-location-any-register?
                  (compiler-reg-assignment-lookup assignments 0)))
              (not
                (compiler-reg-location-any-register?
                  (compiler-reg-assignment-lookup assignments 1)))))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 2)
            (compiler-abi-xmm-register-id 2)))])))

(cfg
  test
  (define (compiler-reg-scalar-win64-float-param-registers-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegTargetAbi.Windows
      (compiler-reg-float-param-register-function))
      [(CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (compiler-live-set-contains? ineligible 0))
          (not (compiler-live-set-contains? ineligible 1))
          (not (compiler-live-set-contains? ineligible 2))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 0)
            (cfg
              scratch-vreg
              (compiler-abi-xmm-register-id 0)
              (compiler-abi-xmm-register-id 6)))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 1)
            (cfg
              scratch-vreg
              (compiler-abi-xmm-register-id 1)
              (compiler-abi-xmm-register-id 7)))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 2)
            (compiler-abi-xmm-register-id 2)))])))

(cfg
  test
  (define (compiler-reg-scalar-mixed-float-call-args-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegTargetAbi.Linux
      (compiler-reg-mixed-float-call-arg-function))
      [(CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (compiler-live-set-contains? ineligible 0)
          (not (compiler-live-set-contains? ineligible 1))
          (not (compiler-live-set-contains? ineligible 2))
          (not (compiler-live-set-contains? ineligible 3))
          (compiler-reg-unassigned? assignments 0)
          (cfg
            scratch-vreg
            (and
              (compiler-reg-location-register?
                (compiler-reg-assignment-lookup assignments 1)
                (compiler-abi-xmm-register-id 0))
              (compiler-reg-location-register?
                (compiler-reg-assignment-lookup assignments 2)
                (compiler-abi-xmm-register-id 1)))
            (and
              (compiler-reg-unassigned? assignments 1)
              (compiler-reg-unassigned? assignments 2)))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 3)
            (compiler-abi-xmm-register-id 2)))])))

(cfg
  test
  (define (compiler-reg-scalar-win64-mixed-float-call-args-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegTargetAbi.Windows
      (compiler-reg-mixed-float-call-arg-function))
      [(CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (compiler-live-set-contains? ineligible 0)
          (not (compiler-live-set-contains? ineligible 1))
          (not (compiler-live-set-contains? ineligible 2))
          (not (compiler-live-set-contains? ineligible 3))
          (compiler-reg-unassigned? assignments 0)
          (cfg
            scratch-vreg
            (compiler-reg-location-register?
              (compiler-reg-assignment-lookup assignments 1)
              (compiler-abi-xmm-register-id 1))
            (compiler-reg-unassigned? assignments 1))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 2)
            (compiler-abi-xmm-register-id 2))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 3)
            (compiler-abi-xmm-register-id 3)))])))

(cfg
  test
  (define (compiler-reg-scalar-windows-rsi-rdi-pool-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegTargetAbi.Windows
      (compiler-reg-win64-rsi-rdi-pressure-function))
      [(CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (compiler-live-set-contains? ineligible 0))
          (not (compiler-live-set-contains? ineligible 6))
          (compiler-reg-assignments-use-register?
            assignments
            compiler-reg-id-rsi)
          (compiler-reg-assignments-use-register?
            assignments
            compiler-reg-id-rdi))])))

(cfg
  test
  (define (compiler-reg-test-identity-coalesce [n : i64]) : CompilerRegCoalesceMap
    (let
      [parents : (Array i64) (array.make-array i64 n)]
      [sizes : (Array i64) (array.make-array i64 n)]
      (begin
        (compiler-reg-coalesce-map-init! parents sizes 0)
        (CompilerRegCoalesceMap parents)))))

(cfg
  test
  (define (compiler-reg-win64-arg-result-pref-function) : CompilerIrFunction
    (let
      [args : (Array CompilerIrValue) (array.make-array CompilerIrValue 5)]
      (begin
        (array-set! args 0 (CompilerIrValue.Var 0))
        (array-set! args 1 (CompilerIrValue.Var 1))
        (array-set! args 2 (CompilerIrValue.Var 2))
        (array-set! args 3 (CompilerIrValue.Var 3))
        (array-set! args 4 (CompilerIrValue.Var 4))
        (CompilerIrFunction.Function
          (compiler-ir-test-symbol "win64_arg_result_pref")
          CompilerIrParamList.Nil
          (AstType.I64)
          6
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "entry")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Call
                  5
                  (compiler-ir-test-symbol "callee")
                  (CompilerIrCallArgs.Array args)
                  (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 5)))
                  CompilerIrInstrList.Nil)))
            CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-win64-arg-result-prefs-ok?) : bool
    (let
      [pool : CompilerRegIdList
        (compiler-reg-greedy-integer-pool-for-abi CompilerRegTargetAbi.Windows)]
      [prefs : (Array i64)
        (compiler-reg-function-arg-prefs
          CompilerRegTargetAbi.Windows
          (compiler-reg-win64-arg-result-pref-function)
          (compiler-reg-test-identity-coalesce 6)
          6)]
      (and
        (=
          (array-ref prefs 0)
          (compiler-reg-id-list-index-of pool compiler-reg-id-rcx 0))
        (=
          (array-ref prefs 1)
          (compiler-reg-id-list-index-of pool compiler-reg-id-rdx 0))
        (=
          (array-ref prefs 2)
          (compiler-reg-id-list-index-of pool compiler-reg-id-r8 0))
        (=
          (array-ref prefs 3)
          (compiler-reg-id-list-index-of pool compiler-reg-id-r9 0))
        (= (array-ref prefs 4) -1)
        (=
          (array-ref prefs 5)
          (compiler-reg-id-list-index-of pool compiler-reg-id-rax 0))))))

(cfg
  test
  ;; M-A (RC1): a clobber-point function no longer stack-homes its params. The
  ;; scalar param cannot keep its ABI pin (the call clobbers %rdi) but becomes
  ;; an ordinary greedy candidate restricted to callee-saved homes: it wins the
  ;; first callee-saved register and is copied there once at entry instead of
  ;; being reloaded from the stack at every use.
  (define (compiler-reg-scalar-param-clobber-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegTargetAbi.Linux
      (compiler-reg-param-clobber-function))
      [(CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (compiler-live-set-contains? ineligible 0))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 0)
            compiler-reg-id-r12))])))

(cfg
  test
  ;; GAP3b: an aggregate-HANDLE param (8-byte struct descriptor) is
  ;; pin-eligible exactly like a scalar (integer-param-type? widened to
  ;; register-eligible), so in this zero-clobber function it keeps its
  ;; incoming %rdi instead of the M-A-era greedy callee-saved home.
  (define (compiler-reg-scalar-aggregate-param-pinned-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegTargetAbi.Linux
      (compiler-reg-param-aggregate-function))
      [(CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (compiler-live-set-contains? ineligible 0))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 0)
            compiler-reg-id-rdi))])))

;; M-A (RC1): a used param's interval is force-extended to the function's first
;; point (the entry copy writes its home register in the prologue), so the
;; live-in gap param now spans [0,4] instead of the precise builder's [1,4].
(cfg
  test
  ;; Zero-call function with six scalar params, only `f` (var 5) used. The
  ;; unused params 0-4 have no interval, so they can be neither pinned nor
  ;; greedy-allocated (before AND after M-A); var 5 keeps its %r9 ABI pin. The
  ;; zero-call locals 6..12 then fill the caller-saved pool head in candidate
  ;; order -- %rax/%rsi/%rdi with the current pool ordering -- skipping the
  ;; pinned %r9; nothing spills.
  (define (compiler-reg-scalar-zero-call-param-conflict-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegTargetAbi.Linux
      (compiler-reg-zero-call-param-conflict-function))
      [(CompilerRegPlan.Plan assignments _ _ _ _ _)
        (and
          (= (compiler-reg-spill-count assignments) 0)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 5)
            compiler-reg-id-r9)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 6)
            compiler-reg-id-rax)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 7)
            compiler-reg-id-rsi)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 8)
            compiler-reg-id-rdi))])))

(cfg
  test
  (define (compiler-reg-remat-weight-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "remat_weight")
      CompilerIrParamList.Nil
      (AstType.Unit)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                1
                (CompilerIrBinOp.Add)
                (CompilerIrValue.I64 1)
                (CompilerIrValue.I64 2)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Store
                  (compiler-ir-test-symbol "use1")
                  (CompilerIrValue.Var 1)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Store
                    (compiler-ir-test-symbol "use0a")
                    (CompilerIrValue.Var 0)
                    (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Store
                      (compiler-ir-test-symbol "use0b")
                      (CompilerIrValue.Var 0)
                      (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                      CompilerIrInstrList.Nil)))))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-multi-def-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "remat_multi_def")
      CompilerIrParamList.Nil
      (AstType.Unit)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                0
                (CompilerIrBinOp.Add)
                (CompilerIrValue.I64 1)
                (CompilerIrValue.I64 2)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                CompilerIrInstrList.Nil))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-classifier-ok?) : bool
    (and
      (compiler-reg-remat-defn?
        (CompilerIrInstr.Mov 10 (CompilerIrValue.I64 1) (compiler-reg-i64-ty)))
      (compiler-reg-remat-defn?
        (CompilerIrInstr.Mov 11 (CompilerIrValue.Bool true) (AstType.Bool)))
      (compiler-reg-remat-defn?
        (CompilerIrInstr.Mov 12 (CompilerIrValue.Char 'x') (AstType.Char)))
      (compiler-reg-remat-defn?
        (CompilerIrInstr.Mov
          13
          (CompilerIrValue.F64 0x3ff0000000000000)
          (compiler-reg-f64-ty)))
      (compiler-reg-remat-defn?
        (CompilerIrInstr.Mov
          14
          (CompilerIrValue.GlobalAddr (compiler-ir-test-symbol "global"))
          (AstType.U64)))
      (not
        (compiler-reg-remat-defn?
          (CompilerIrInstr.Mov
            15
            (CompilerIrValue.Global (compiler-ir-test-symbol "global"))
            (compiler-reg-i64-ty))))
      (compiler-reg-remat-defn-with-invariant-loads?
        (CompilerIrInstr.Mov
          16
          (CompilerIrValue.Global (compiler-ir-test-symbol "global"))
          (compiler-reg-i64-ty))
        true)
      (compiler-reg-remat-defn?
        (CompilerIrInstr.Gep
          17
          (CompilerIrValue.GlobalAddr (compiler-ir-test-symbol "global"))
          (CompilerIrValue.I64 2)
          (compiler-reg-i64-ty)))
      (not
        (compiler-reg-remat-defn?
          (CompilerIrInstr.Gep
            18
            (CompilerIrValue.GlobalAddr (compiler-ir-test-symbol "global"))
            (CompilerIrValue.Var 0)
            (compiler-reg-i64-ty))))
      (not
        (compiler-reg-remat-defn?
          (CompilerIrInstr.Gep
            19
            (CompilerIrValue.Var 0)
            (CompilerIrValue.I64 2)
            (compiler-reg-i64-ty))))
      (not
        (compiler-reg-remat-defn?
          (CompilerIrInstr.Load
            20
            (CompilerIrValue.GlobalAddr (compiler-ir-test-symbol "global"))
            (compiler-reg-i64-ty))))
      (compiler-reg-remat-defn-with-invariant-loads?
        (CompilerIrInstr.Load
          21
          (CompilerIrValue.GlobalAddr (compiler-ir-test-symbol "global"))
          (compiler-reg-i64-ty))
        true)
      (not
        (compiler-reg-remat-defn-with-invariant-loads?
          (CompilerIrInstr.Load
            22
            (CompilerIrValue.Var 0)
            (compiler-reg-i64-ty))
          true))
      (not
        (compiler-reg-remat-defn?
          (CompilerIrInstr.Mov 23 (CompilerIrValue.Var 0) (compiler-reg-i64-ty))))
      (not
        (compiler-reg-remat-defn?
          (CompilerIrInstr.Mov
            24
            (CompilerIrValue.String "heap")
            (AstType.String))))
      (not
        (compiler-reg-remat-defn?
          (CompilerIrInstr.BinOp
            25
            (CompilerIrBinOp.Add)
            (CompilerIrValue.I64 1)
            (CompilerIrValue.I64 2)
            (compiler-reg-i64-ty)))))))

(cfg
  test
  (define (compiler-reg-remat-discount-weights-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-remat-weight-function)]
      [empty-coalesce : CompilerRegCoalesceMap
        (CompilerRegCoalesceMap (array.make-array i64 0))]
      [raw : (Array i64) (compiler-reg-function-spill-weights func)]
      [discounted : (Array i64)
        (compiler-reg-function-spill-weights-remat func empty-coalesce)]
      [multi-raw : (Array i64)
        (compiler-reg-function-spill-weights
          (compiler-reg-remat-multi-def-function))]
      [multi-discounted : (Array i64)
        (compiler-reg-function-spill-weights-remat
          (compiler-reg-remat-multi-def-function)
          empty-coalesce)]
      [parents : (Array i64) (array.make-array i64 2)]
      (begin
        (array-set! parents 0 0)
        (array-set! parents 1 0)
        (let
          [coalesced : (Array i64)
            (compiler-reg-function-spill-weights-remat
              func
              (CompilerRegCoalesceMap parents))]
          (and
            (= (array-ref raw 0) 3)
            (= (array-ref raw 1) 2)
            (= (array-ref discounted 0) 1)
            (= (array-ref discounted 1) 2)
            (= (array-ref coalesced 0) 3)
            (= (array-ref coalesced 1) 2)
            (= (array-ref multi-raw 0) 2)
            (= (array-ref multi-discounted 0) 2)))))))

(cfg
  test
  (define (compiler-reg-remat-spill-weight-eviction-function) : CompilerIrFunction
    (let
      [instrs : CompilerIrInstrList CompilerIrInstrList.Nil]
      (begin
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return CompilerIrMaybeValue.No)
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "hot0b")
              (CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "hot0a")
              (CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "cold1")
              (CompilerIrValue.Var 1)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "use5")
              (CompilerIrValue.Var 5)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "use4")
              (CompilerIrValue.Var 4)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "use3")
              (CompilerIrValue.Var 3)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "use2")
              (CompilerIrValue.Var 2)
              (compiler-reg-i64-ty))
            instrs))
        ;; #perf: syscall after the uses so every value crosses it (call-spanning)
        ;; -- the partition gates off and the 6 candidates oversubscribe the 5
        ;; callee-saved registers. var1 is the only non-remat value, so the remat
        ;; discount keeps it in a register and a rematerialisable value is the
        ;; victim; among the remat values the cheapest (1-use var5, one recompute)
        ;; is spilled rather than the 2-use var0 (two recomputes).
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Syscall
              6
              (CompilerIrCallArgs.One (CompilerIrValue.I64 39)))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              5
              (CompilerIrValue.I64 5)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              4
              (CompilerIrValue.I64 4)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              3
              (CompilerIrValue.I64 3)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              2
              (CompilerIrValue.I64 2)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.BinOp
              1
              (CompilerIrBinOp.Add)
              (CompilerIrValue.I64 1)
              (CompilerIrValue.I64 2)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 0)
              (compiler-reg-i64-ty))
            instrs))
        (CompilerIrFunction.Function
          (compiler-ir-test-symbol "remat_spill_weight_eviction")
          CompilerIrParamList.Nil
          (AstType.Unit)
          7
          (compiler-ir-block-cons
            (compiler-ir-block (compiler-ir-label "entry") instrs)
            CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-remat-spill-weight-eviction-ok?) : bool
    (let
      [func : CompilerIrFunction
        (compiler-reg-remat-spill-weight-eviction-function)]
      [empty-coalesce : CompilerRegCoalesceMap
        (CompilerRegCoalesceMap (array.make-array i64 0))]
      [raw : (Array i64) (compiler-reg-function-spill-weights func)]
      [discounted : (Array i64)
        (compiler-reg-function-spill-weights-remat func empty-coalesce)]
      (match (compiler-reg-plan-function-scalar func)
        [(CompilerRegPlan.Plan assignments _ _ _ _ _)
          (and
            (> (array-ref raw 0) (array-ref raw 1))
            (< (array-ref discounted 0) (array-ref discounted 1))
            ;; The non-remat var1 is KEPT in a register: the remat discount ranks
            ;; the rematerialisable values (var0, var2-5) below it, so a remat
            ;; value -- never the costly-to-spill non-remat one -- is the victim.
            (compiler-reg-location-any-register?
              (compiler-reg-assignment-lookup assignments 1))
            ;; Among the remat values the GREEDY spills the genuinely cheapest:
            ;; var0 has 2 uses (spilling it costs 2 recomputes) while var5 has 1
            ;; use (1 recompute), so var0 is KEPT and the 1-use var5 is the victim.
            ;; The combined discounted+raw priority key breaks the discount's
            ;; use-count collapse by raw use density, spilling the least-used
            ;; rematerialisable value rather than the most-used one.
            (compiler-reg-location-any-register?
              (compiler-reg-assignment-lookup assignments 0))
            (compiler-reg-location-spill-offset?
              (compiler-reg-assignment-lookup assignments 5)
              (compiler-reg-stack-slot-offset 5)))]))))

(cfg
  test
  (define (compiler-reg-spill-weight-eviction-function) : CompilerIrFunction
    ;; #perf: every value crosses the syscall (call-spanning), so the call-
    ;; spanning-aware partition is gated off and the 6 candidates genuinely
    ;; oversubscribe the 5 callee-saved registers. var0 is hot (3 uses), vars 2-5
    ;; are medium (2 uses), var1 is the unique coldest (1 use) and is the
    ;; spill-weight eviction victim.
    (let
      [instrs : CompilerIrInstrList CompilerIrInstrList.Nil]
      (begin
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return CompilerIrMaybeValue.No)
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "hot0c")
              (CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "hot0b")
              (CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "hot0a")
              (CompilerIrValue.Var 0)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "cold1")
              (CompilerIrValue.Var 1)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "use5b")
              (CompilerIrValue.Var 5)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "use5a")
              (CompilerIrValue.Var 5)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "use4b")
              (CompilerIrValue.Var 4)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "use4a")
              (CompilerIrValue.Var 4)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "use3b")
              (CompilerIrValue.Var 3)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "use3a")
              (CompilerIrValue.Var 3)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "use2b")
              (CompilerIrValue.Var 2)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "use2a")
              (CompilerIrValue.Var 2)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Syscall
              6
              (CompilerIrCallArgs.One (CompilerIrValue.I64 39)))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              5
              (CompilerIrValue.I64 5)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              4
              (CompilerIrValue.I64 4)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              3
              (CompilerIrValue.I64 3)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              2
              (CompilerIrValue.I64 2)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              1
              (CompilerIrValue.I64 1)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 0)
              (compiler-reg-i64-ty))
            instrs))
        (CompilerIrFunction.Function
          (compiler-ir-test-symbol "spill_weight_eviction")
          CompilerIrParamList.Nil
          (AstType.Unit)
          7
          (compiler-ir-block-cons
            (compiler-ir-block (compiler-ir-label "entry") instrs)
            CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-spill-weight-eviction-ok?) : bool
    (match (compiler-reg-plan-function-scalar
      (compiler-reg-spill-weight-eviction-function))
      [(CompilerRegPlan.Plan assignments _ _ _ _ _)
        (and
          (compiler-reg-location-any-register?
            (compiler-reg-assignment-lookup assignments 0))
          (compiler-reg-location-spill-offset?
            (compiler-reg-assignment-lookup assignments 1)
            (compiler-reg-stack-slot-offset 1))
          (compiler-reg-location-any-register?
            (compiler-reg-assignment-lookup assignments 5)))])))

(cfg
  test
  (define (compiler-reg-loop-spill-weight-eviction-function) : CompilerIrFunction
    ;; #perf: all six values cross the entry syscall (call-spanning) so the
    ;; partition gates off. var0 and vars 2-5 are used inside the loop (loop-depth
    ;; weighted) while var1 is the single cold exit value -- the unique
    ;; spill-weight eviction victim despite var0/var1 sharing one static use each.
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "loop_spill_weight_eviction")
      CompilerIrParamList.Nil
      (AstType.Unit)
      7
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 0)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov
                1
                (CompilerIrValue.I64 1)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Mov
                  2
                  (CompilerIrValue.I64 2)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Mov
                    3
                    (CompilerIrValue.I64 3)
                    (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Mov
                      4
                      (CompilerIrValue.I64 4)
                      (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Mov
                        5
                        (CompilerIrValue.I64 5)
                        (compiler-reg-i64-ty))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Syscall
                          6
                          (CompilerIrCallArgs.One (CompilerIrValue.I64 39)))
                        (compiler-ir-instr-cons
                          (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                          CompilerIrInstrList.Nil)))))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "loop")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Store
                (compiler-ir-test-symbol "hot0")
                (CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Store
                  (compiler-ir-test-symbol "hot2")
                  (CompilerIrValue.Var 2)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Store
                    (compiler-ir-test-symbol "hot3")
                    (CompilerIrValue.Var 3)
                    (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Store
                      (compiler-ir-test-symbol "hot4")
                      (CompilerIrValue.Var 4)
                      (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Store
                        (compiler-ir-test-symbol "hot5")
                        (CompilerIrValue.Var 5)
                        (compiler-reg-i64-ty))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Branch
                          (CompilerIrValue.Bool false)
                          (compiler-ir-label "body")
                          (compiler-ir-label "exit"))
                        CompilerIrInstrList.Nil)))))))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "body")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                CompilerIrInstrList.Nil))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "exit")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Store
                    (compiler-ir-test-symbol "cold1")
                    (CompilerIrValue.Var 1)
                    (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                    CompilerIrInstrList.Nil)))
              CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-loop-spill-weight-eviction-ok?) : bool
    (let
      [func : CompilerIrFunction
        (compiler-reg-loop-spill-weight-eviction-function)]
      [static-counts : (Array i64) (compiler-reg-function-ref-counts func)]
      [weighted-counts : (Array i64) (compiler-reg-function-spill-weights func)]
      (match (compiler-reg-plan-function-scalar func)
        [(CompilerRegPlan.Plan assignments _ _ _ _ _)
          (and
            (= (array-ref static-counts 0) (array-ref static-counts 1))
            (> (array-ref weighted-counts 0) (array-ref weighted-counts 1))
            (compiler-reg-location-any-register?
              (compiler-reg-assignment-lookup assignments 0))
            (compiler-reg-location-spill-offset?
              (compiler-reg-assignment-lookup assignments 1)
              (compiler-reg-stack-slot-offset 1))
            (compiler-reg-location-any-register?
              (compiler-reg-assignment-lookup assignments 5)))]))))

(cfg
  test
  (define (compiler-reg-instr-list-has-mov-i64?
    [instrs : CompilerIrInstrList]
    [dst : i64]
    [value : i64]) : bool
    (match instrs
      [(CompilerIrInstrList.Nil) false]
      [(CompilerIrInstrList.Cons instr rest)
        (match instr
          [(CompilerIrInstr.Mov found-dst found-value _)
            (match found-value
              [(CompilerIrValue.I64 found)
                (if (and (= found-dst dst) (= found value))
                  true
                  (compiler-reg-instr-list-has-mov-i64?
                    (box-get rest)
                    dst
                    value))]
              [_
                (compiler-reg-instr-list-has-mov-i64? (box-get rest) dst value)])]
          [_ (compiler-reg-instr-list-has-mov-i64? (box-get rest) dst value)])])))

(cfg
  test
  (define (compiler-reg-instr-list-has-mov-var?
    [instrs : CompilerIrInstrList]
    [dst : i64]
    [src : i64]) : bool
    (match instrs
      [(CompilerIrInstrList.Nil) false]
      [(CompilerIrInstrList.Cons instr rest)
        (match instr
          [(CompilerIrInstr.Mov found-dst found-value _)
            (match found-value
              [(CompilerIrValue.Var found-src)
                (if (and (= found-dst dst) (= found-src src))
                  true
                  (compiler-reg-instr-list-has-mov-var? (box-get rest) dst src))]
              [_ (compiler-reg-instr-list-has-mov-var? (box-get rest) dst src)])]
          [_ (compiler-reg-instr-list-has-mov-var? (box-get rest) dst src)])])))

(cfg
  test
  (define (compiler-reg-instr-list-has-mov-global?
    [instrs : CompilerIrInstrList]
    [dst : i64]
    [name : String]) : bool
    (match instrs
      [(CompilerIrInstrList.Nil) false]
      [(CompilerIrInstrList.Cons instr rest)
        (match instr
          [(CompilerIrInstr.Mov found-dst found-value _)
            (match found-value
              [(CompilerIrValue.Global found-name)
                (if (and
                  (= found-dst dst)
                  (string.eq (compiler-ir-symbol-text found-name) name))
                  true
                  (compiler-reg-instr-list-has-mov-global?
                    (box-get rest)
                    dst
                    name))]
              [_
                (compiler-reg-instr-list-has-mov-global?
                  (box-get rest)
                  dst
                  name)])]
          [_ (compiler-reg-instr-list-has-mov-global? (box-get rest) dst name)])])))

(cfg
  test
  (define (compiler-reg-instr-list-has-load-global-addr?
    [instrs : CompilerIrInstrList]
    [dst : i64]
    [name : String]) : bool
    (match instrs
      [(CompilerIrInstrList.Nil) false]
      [(CompilerIrInstrList.Cons instr rest)
        (match instr
          [(CompilerIrInstr.Load found-dst found-src _)
            (match found-src
              [(CompilerIrValue.GlobalAddr found-name)
                (if (and
                  (= found-dst dst)
                  (string.eq (compiler-ir-symbol-text found-name) name))
                  true
                  (compiler-reg-instr-list-has-load-global-addr?
                    (box-get rest)
                    dst
                    name))]
              [_
                (compiler-reg-instr-list-has-load-global-addr?
                  (box-get rest)
                  dst
                  name)])]
          [_
            (compiler-reg-instr-list-has-load-global-addr?
              (box-get rest)
              dst
              name)])])))

(cfg
  test
  (define (compiler-reg-instr-list-has-gep-global-i64?
    [instrs : CompilerIrInstrList]
    [dst : i64]
    [name : String]
    [offset : i64]
    [ty : AstType]) : bool
    (match instrs
      [(CompilerIrInstrList.Nil) false]
      [(CompilerIrInstrList.Cons instr rest)
        (match instr
          [(CompilerIrInstr.Gep found-dst found-base found-offset found-ty)
            (match found-base
              [(CompilerIrValue.GlobalAddr found-name)
                (match found-offset
                  [(CompilerIrValue.I64 found-offset-value)
                    (if (and
                      (= found-dst dst)
                      (and
                        (string.eq (compiler-ir-symbol-text found-name) name)
                        (and
                          (= found-offset-value offset)
                          (ast-type-eq? found-ty ty))))
                      true
                      (compiler-reg-instr-list-has-gep-global-i64?
                        (box-get rest)
                        dst
                        name
                        offset
                        ty))]
                  [_
                    (compiler-reg-instr-list-has-gep-global-i64?
                      (box-get rest)
                      dst
                      name
                      offset
                      ty)])]
              [_
                (compiler-reg-instr-list-has-gep-global-i64?
                  (box-get rest)
                  dst
                  name
                  offset
                  ty)])]
          [_
            (compiler-reg-instr-list-has-gep-global-i64?
              (box-get rest)
              dst
              name
              offset
              ty)])])))

(cfg
  test
  (define (compiler-reg-instr-list-has-store-var?
    [instrs : CompilerIrInstrList]
    [name : String]
    [src : i64]) : bool
    (match instrs
      [(CompilerIrInstrList.Nil) false]
      [(CompilerIrInstrList.Cons instr rest)
        (match instr
          [(CompilerIrInstr.Store found-name found-value _)
            (match found-value
              [(CompilerIrValue.Var found-src)
                (if (and
                  (string.eq (compiler-ir-symbol-text found-name) name)
                  (= found-src src))
                  true
                  (compiler-reg-instr-list-has-store-var?
                    (box-get rest)
                    name
                    src))]
              [_
                (compiler-reg-instr-list-has-store-var? (box-get rest) name src)])]
          [_ (compiler-reg-instr-list-has-store-var? (box-get rest) name src)])])))

(cfg
  test
  (define (compiler-reg-instr-list-has-addr-of?
    [instrs : CompilerIrInstrList]
    [dst : i64]
    [src : i64]) : bool
    (match instrs
      [(CompilerIrInstrList.Nil) false]
      [(CompilerIrInstrList.Cons instr rest)
        (match instr
          [(CompilerIrInstr.AddrOf found-dst found-src)
            (if (and (= found-dst dst) (= found-src src))
              true
              (compiler-reg-instr-list-has-addr-of? (box-get rest) dst src))]
          [_ (compiler-reg-instr-list-has-addr-of? (box-get rest) dst src)])])))

(cfg
  test
  (define (compiler-reg-instr-list-has-call-indirect-var?
    [instrs : CompilerIrInstrList]
    [callee : i64]) : bool
    (match instrs
      [(CompilerIrInstrList.Nil) false]
      [(CompilerIrInstrList.Cons instr rest)
        (match instr
          [(CompilerIrInstr.CallIndirect _ found-callee _ _)
            (match found-callee
              [(CompilerIrValue.Var found)
                (if (= found callee)
                  true
                  (compiler-reg-instr-list-has-call-indirect-var?
                    (box-get rest)
                    callee))]
              [_
                (compiler-reg-instr-list-has-call-indirect-var?
                  (box-get rest)
                  callee)])]
          [_
            (compiler-reg-instr-list-has-call-indirect-var?
              (box-get rest)
              callee)])])))

(cfg
  test
  (define (compiler-reg-instr-list-has-return-var?
    [instrs : CompilerIrInstrList]
    [src : i64]) : bool
    (match instrs
      [(CompilerIrInstrList.Nil) false]
      [(CompilerIrInstrList.Cons instr rest)
        (match instr
          [(CompilerIrInstr.Return maybe)
            (match maybe
              [(CompilerIrMaybeValue.Some value)
                (match value
                  [(CompilerIrValue.Var found)
                    (if (= found src)
                      true
                      (compiler-reg-instr-list-has-return-var?
                        (box-get rest)
                        src))]
                  [_
                    (compiler-reg-instr-list-has-return-var? (box-get rest) src)])]
              [_ (compiler-reg-instr-list-has-return-var? (box-get rest) src)])]
          [_ (compiler-reg-instr-list-has-return-var? (box-get rest) src)])])))

(cfg
  test
  (define (compiler-reg-block-instr-list
    [blocks : CompilerIrBlockList]
    [want-label : i64]) : CompilerIrInstrList
    (match blocks
      [(CompilerIrBlockList.Cons block rest)
        (match block
          [(CompilerIrBlock.Block label instrs)
            (if (= label want-label)
              (compiler-ir-instr-seq-to-list instrs)
              (compiler-reg-block-instr-list (box-get rest) want-label))])]
      [(CompilerIrBlockList.Array seq)
        (let
          [i : i64 0]
          [count : i64 (compiler-ir-block-seq-count seq)]
          [out : CompilerIrInstrList CompilerIrInstrList.Nil]
          [found : bool false]
          (begin
            (while (and (< i count) (not found))
              (begin
                (match (compiler-ir-block-seq-ref seq i)
                  [(CompilerIrBlock.Block label instrs)
                    (if (= label want-label)
                      (begin
                        (set! out (compiler-ir-instr-seq-to-list instrs))
                        (set! found true))
                      unit)])
                (set! i (+ i 1))))
            out))]
      [_ CompilerIrInstrList.Nil])))

(cfg
  test
  (define (compiler-reg-remat-rewrite-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "remat_rewrite")
      CompilerIrParamList.Nil
      (AstType.Unit)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Store
                (compiler-ir-test-symbol "use0a")
                (CompilerIrValue.Var 0)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Store
                  (compiler-ir-test-symbol "use0b")
                  (CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                  CompilerIrInstrList.Nil)))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-conflict-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "remat_conflict")
      CompilerIrParamList.Nil
      (AstType.Unit)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov
                1
                (CompilerIrValue.I64 9)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Store
                  (compiler-ir-test-symbol "use0")
                  (CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Store
                    (compiler-ir-test-symbol "keep1")
                    (CompilerIrValue.Var 1)
                    (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                    CompilerIrInstrList.Nil))))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-caller-clobber-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "remat_caller_clobber")
      CompilerIrParamList.Nil
      (AstType.Unit)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.GlobalAddr (compiler-ir-test-symbol "callee"))
              (AstType.U64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.CallIndirect
                1
                (CompilerIrValue.Var 0)
                CompilerIrCallArgs.Nil
                (AstType.Unit))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                CompilerIrInstrList.Nil))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-addr-of-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "remat_addr_of")
      CompilerIrParamList.Nil
      (AstType.Unit)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.AddrOf 1 0)
              (compiler-ir-instr-cons
                (CompilerIrInstr.Store
                  (compiler-ir-test-symbol "addr")
                  (CompilerIrValue.Var 1)
                  (compiler-reg-addr-of-result-type))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                  CompilerIrInstrList.Nil)))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-global-mov-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "remat_global_mov")
      CompilerIrParamList.Nil
      (compiler-reg-i64-ty)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.Global (compiler-ir-test-symbol "global_value"))
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
              CompilerIrInstrList.Nil)))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-global-load-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "remat_global_load")
      CompilerIrParamList.Nil
      (compiler-reg-i64-ty)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Load
              0
              (CompilerIrValue.GlobalAddr
                (compiler-ir-test-symbol "global_value"))
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
              CompilerIrInstrList.Nil)))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-global-gep-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "remat_global_gep")
      CompilerIrParamList.Nil
      (compiler-reg-addr-of-result-type)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Gep
              0
              (CompilerIrValue.GlobalAddr
                (compiler-ir-test-symbol "global_value"))
              (CompilerIrValue.I64 3)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
              CompilerIrInstrList.Nil)))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-global-mutating-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "remat_global_mutating")
      CompilerIrParamList.Nil
      (compiler-reg-i64-ty)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.Global (compiler-ir-test-symbol "global_value"))
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Store
                (compiler-ir-test-symbol "global_value")
                (CompilerIrValue.I64 1)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
                CompilerIrInstrList.Nil))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-single-spill-plan [func : CompilerIrFunction]) : CompilerRegPlan
    (CompilerRegPlan.Plan
      (compiler-reg-assignment-cons
        (CompilerRegAssignment.Assignment
          0
          (CompilerRegLocation.Spill (compiler-reg-stack-slot-offset 0)))
        CompilerRegAssignmentList.Nil)
      (compiler-live-set-empty)
      (compiler-reg-interval-seq-empty)
      (compiler-reg-var-types-list (compiler-reg-function-var-types func))
      (compiler-reg-call-split-empty)
      (compiler-reg-split-plan-empty))))

(cfg
  test
  (define (compiler-reg-remat-conflict-plan [func : CompilerIrFunction]) : CompilerRegPlan
    (CompilerRegPlan.Plan
      (compiler-reg-assignment-cons
        (CompilerRegAssignment.Assignment
          0
          (CompilerRegLocation.Spill (compiler-reg-stack-slot-offset 0)))
        (compiler-reg-assignment-cons
          (CompilerRegAssignment.Assignment
            1
            (CompilerRegLocation.Register compiler-reg-id-r9))
          CompilerRegAssignmentList.Nil))
      (compiler-live-set-empty)
      (compiler-reg-interval-seq-empty)
      (compiler-reg-var-types-list (compiler-reg-function-var-types func))
      (compiler-reg-call-split-empty)
      (compiler-reg-split-plan-empty))))

(cfg
  test
  (define (compiler-reg-remat-rewrite-shape-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-remat-rewrite-function)]
      [plan : CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(CompilerIrFunction.Function _ _ _ vars blocks)
          (match (compiler-reg-remat-rewrite-blocks
            (ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                extra-types)
              (let
                [items : CompilerIrInstrList
                  (compiler-reg-block-instr-list
                    rewritten
                    (compiler-ir-label "entry"))]
                [rewritten-plan : CompilerRegPlan
                  (compiler-reg-plan-with-call-save-rewrite
                    plan
                    (CompilerRegCallSaveRewrite.Rewrite
                      rewritten
                      vars
                      out-vars
                      extra-assignments
                      extra-types))]
                [rewritten-assignments : CompilerRegAssignmentList
                  (compiler-reg-plan-assignments rewritten-plan)]
                [rewritten-types : CompilerRegVarTypeList
                  (compiler-reg-plan-types rewritten-plan)]
                (and
                  (= out-vars (+ vars 2))
                  (= (compiler-reg-assignment-count extra-assignments) 2)
                  (compiler-reg-location-register?
                    (compiler-reg-assignment-lookup rewritten-assignments vars)
                    compiler-reg-id-r9)
                  (compiler-reg-location-register?
                    (compiler-reg-assignment-lookup
                      rewritten-assignments
                      (+ vars 1))
                    compiler-reg-id-r9)
                  (compiler-reg-instr-list-has-mov-i64? items vars 7)
                  (compiler-reg-instr-list-has-mov-i64? items (+ vars 1) 7)
                  (compiler-reg-instr-list-has-store-var? items "use0a" vars)
                  (compiler-reg-instr-list-has-store-var?
                    items
                    "use0b"
                    (+ vars 1))
                  (match (compiler-reg-var-type-lookup rewritten-types vars)
                    [(CompilerRegMaybeType.Some ty)
                      (match ty
                        [(AstType.I64) true]
                        [_ false])]
                    [(CompilerRegMaybeType.No) false])
                  (match (compiler-reg-var-type-lookup
                    rewritten-types
                    (+ vars 1))
                    [(CompilerRegMaybeType.Some ty)
                      (match ty
                        [(AstType.I64) true]
                        [_ false])]
                    [(CompilerRegMaybeType.No) false])
                  (not (compiler-reg-instr-list-has-store-var? items "use0a" 0))
                  (not (compiler-reg-instr-list-has-store-var? items "use0b" 0))))])]))))

(cfg
  test
  (define (compiler-reg-remat-register-conflict-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-remat-conflict-function)]
      [plan : CompilerRegPlan (compiler-reg-remat-conflict-plan func)]
      (match func
        [(CompilerIrFunction.Function _ _ _ vars blocks)
          (match (compiler-reg-remat-rewrite-blocks
            (ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : CompilerIrInstrList
                  (compiler-reg-block-instr-list
                    rewritten
                    (compiler-ir-label "entry"))]
                (and
                  (= out-vars vars)
                  (= (compiler-reg-assignment-count extra-assignments) 0)
                  (compiler-reg-instr-list-has-store-var? items "use0" 0)))])]))))

(cfg
  test
  (define (compiler-reg-remat-caller-clobber-refusal-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-remat-caller-clobber-function)]
      [plan : CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(CompilerIrFunction.Function _ _ _ vars blocks)
          (match (compiler-reg-remat-rewrite-blocks
            (ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : CompilerIrInstrList
                  (compiler-reg-block-instr-list
                    rewritten
                    (compiler-ir-label "entry"))]
                (and
                  (= out-vars vars)
                  (= (compiler-reg-assignment-count extra-assignments) 0)
                  (compiler-reg-instr-list-has-call-indirect-var? items 0)))])]))))

(cfg
  test
  (define (compiler-reg-remat-addr-of-source-refusal-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-remat-addr-of-function)]
      [plan : CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(CompilerIrFunction.Function _ _ _ vars blocks)
          (match (compiler-reg-remat-rewrite-blocks
            (ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : CompilerIrInstrList
                  (compiler-reg-block-instr-list
                    rewritten
                    (compiler-ir-label "entry"))]
                (and
                  (= out-vars vars)
                  (= (compiler-reg-assignment-count extra-assignments) 0)
                  (compiler-reg-instr-list-has-addr-of? items 1 0)
                  (not (compiler-reg-instr-list-has-addr-of? items 1 vars))))])]))))

(cfg
  test
  (define (compiler-reg-remat-global-mov-rewrite-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-remat-global-mov-function)]
      [plan : CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(CompilerIrFunction.Function _ _ _ vars blocks)
          (match (compiler-reg-remat-rewrite-blocks
            (ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : CompilerIrInstrList
                  (compiler-reg-block-instr-list
                    rewritten
                    (compiler-ir-label "entry"))]
                (and
                  (= out-vars (+ vars 1))
                  (= (compiler-reg-assignment-count extra-assignments) 1)
                  (compiler-reg-instr-list-has-mov-global?
                    items
                    vars
                    "global_value")
                  (compiler-reg-instr-list-has-return-var? items vars)
                  (not (compiler-reg-instr-list-has-return-var? items 0))))])]))))

(cfg
  test
  (define (compiler-reg-remat-global-load-rewrite-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-remat-global-load-function)]
      [plan : CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(CompilerIrFunction.Function _ _ _ vars blocks)
          (match (compiler-reg-remat-rewrite-blocks
            (ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : CompilerIrInstrList
                  (compiler-reg-block-instr-list
                    rewritten
                    (compiler-ir-label "entry"))]
                (and
                  (= out-vars (+ vars 1))
                  (= (compiler-reg-assignment-count extra-assignments) 1)
                  (compiler-reg-instr-list-has-load-global-addr?
                    items
                    vars
                    "global_value")
                  (compiler-reg-instr-list-has-return-var? items vars)
                  (not (compiler-reg-instr-list-has-return-var? items 0))))])]))))

(cfg
  test
  (define (compiler-reg-remat-global-gep-rewrite-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-remat-global-gep-function)]
      [plan : CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(CompilerIrFunction.Function _ _ _ vars blocks)
          (match (compiler-reg-remat-rewrite-blocks
            (ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : CompilerIrInstrList
                  (compiler-reg-block-instr-list
                    rewritten
                    (compiler-ir-label "entry"))]
                (and
                  (= out-vars (+ vars 1))
                  (= (compiler-reg-assignment-count extra-assignments) 1)
                  (compiler-reg-instr-list-has-gep-global-i64?
                    items
                    vars
                    "global_value"
                    3
                    (compiler-reg-i64-ty))
                  (compiler-reg-instr-list-has-return-var? items vars)
                  (not (compiler-reg-instr-list-has-return-var? items 0))))])]))))

(cfg
  test
  (define (compiler-reg-remat-global-mutation-refusal-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-remat-global-mutating-function)]
      [plan : CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(CompilerIrFunction.Function _ _ _ vars blocks)
          (match (compiler-reg-remat-rewrite-blocks
            (ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : CompilerIrInstrList
                  (compiler-reg-block-instr-list
                    rewritten
                    (compiler-ir-label "entry"))]
                (and
                  (= out-vars vars)
                  (= (compiler-reg-assignment-count extra-assignments) 0)
                  (compiler-reg-instr-list-has-return-var? items 0)
                  (not
                    (compiler-reg-instr-list-has-mov-global?
                      items
                      vars
                      "global_value"))))])]))))

(cfg
  test
  (define (compiler-reg-call-spanning-post-call-stores
    [tail : CompilerIrInstrList]) : CompilerIrInstrList
    (compiler-ir-instr-cons
      (CompilerIrInstr.Store
        (compiler-ir-test-symbol "g0")
        (CompilerIrValue.Var 0)
        (compiler-reg-i64-ty))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Store
          (compiler-ir-test-symbol "g1")
          (CompilerIrValue.Var 1)
          (compiler-reg-i64-ty))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Store
            (compiler-ir-test-symbol "g2")
            (CompilerIrValue.Var 2)
            (compiler-reg-i64-ty))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store
              (compiler-ir-test-symbol "g3")
              (CompilerIrValue.Var 3)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Store
                (compiler-ir-test-symbol "g4")
                (CompilerIrValue.Var 4)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Store
                  (compiler-ir-test-symbol "g5")
                  (CompilerIrValue.Var 5)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Store
                    (compiler-ir-test-symbol "g6")
                    (CompilerIrValue.Var 6)
                    (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Store
                      (compiler-ir-test-symbol "g5b")
                      (CompilerIrValue.Var 5)
                      (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Store
                        (compiler-ir-test-symbol "g5c")
                        (CompilerIrValue.Var 5)
                        (compiler-reg-i64-ty))
                      tail)))))))))))

(cfg
  test
  (define (compiler-reg-call-spanning-defs-before [tail : CompilerIrInstrList]) : CompilerIrInstrList
    (compiler-ir-instr-cons
      (CompilerIrInstr.Mov 0 (CompilerIrValue.I64 0) (compiler-reg-i64-ty))
      (compiler-ir-instr-cons
        (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 1) (compiler-reg-i64-ty))
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 2 (CompilerIrValue.I64 2) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              3
              (CompilerIrValue.I64 3)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov
                4
                (CompilerIrValue.I64 4)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Mov
                  5
                  (CompilerIrValue.I64 5)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Mov
                    6
                    (CompilerIrValue.I64 6)
                    (compiler-reg-i64-ty))
                  tail)))))))))

(cfg
  test
  (define (compiler-reg-call-spanning-call-before [tail : CompilerIrInstrList]) : CompilerIrInstrList
    (compiler-ir-instr-cons
      (CompilerIrInstr.Call
        7
        (compiler-ir-test-symbol "side_effect")
        (CompilerIrCallArgs.Nil)
        (AstType.Unit))
      tail)))

(cfg
  test
  (define (compiler-reg-call-spanning-multiblock-local-function) : CompilerIrFunction
    (let
      [body-tail : CompilerIrInstrList
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "exit"))
          CompilerIrInstrList.Nil)]
      [body : CompilerIrInstrList
        (compiler-reg-call-spanning-defs-before
          (compiler-reg-call-spanning-call-before
            (compiler-reg-call-spanning-post-call-stores body-tail)))]
      (CompilerIrFunction.Function
        (compiler-ir-test-symbol "call_spanning_multiblock_local")
        CompilerIrParamList.Nil
        (AstType.Unit)
        8
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "entry")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "body"))
              CompilerIrInstrList.Nil))
          (compiler-ir-block-cons
            (compiler-ir-block (compiler-ir-label "body") body)
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "exit")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                  CompilerIrInstrList.Nil))
              CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-call-spanning-multiblock-boundary-function) : CompilerIrFunction
    (let
      [entry : CompilerIrInstrList
        (compiler-reg-call-spanning-defs-before
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "body"))
            CompilerIrInstrList.Nil))]
      [body-tail : CompilerIrInstrList
        (compiler-ir-instr-cons
          (CompilerIrInstr.Jump (compiler-ir-label "exit"))
          CompilerIrInstrList.Nil)]
      [body : CompilerIrInstrList
        (compiler-reg-call-spanning-call-before
          (compiler-reg-call-spanning-post-call-stores body-tail))]
      (CompilerIrFunction.Function
        (compiler-ir-test-symbol "call_spanning_multiblock_boundary")
        CompilerIrParamList.Nil
        (AstType.Unit)
        8
        (compiler-ir-block-cons
          (compiler-ir-block (compiler-ir-label "entry") entry)
          (compiler-ir-block-cons
            (compiler-ir-block (compiler-ir-label "body") body)
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "exit")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                  CompilerIrInstrList.Nil))
              CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-scalar-call-spanning-multiblock-local-ok?) : bool
    (let
      [func : CompilerIrFunction
        (compiler-reg-call-spanning-multiblock-local-function)]
      [plan : CompilerRegPlan (compiler-reg-plan-function-scalar func)]
      (match plan
        [(CompilerRegPlan.Plan assignments _ _ _ split-vars _)
          (and
            ;; Same capacity story as the single-block fixture: the greedy
            ;; register-homes the hot call-spanning value (spill-weight priority)
            ;; and spills the single-use overflow (var 6) without a save/restore
            ;; rescue.
            (= (compiler-reg-spill-count assignments) 2)
            (compiler-reg-location-spill-offset?
              (compiler-reg-assignment-lookup assignments 6)
              (compiler-reg-stack-slot-offset 6))
            (not
              (compiler-live-set-contains?
                (compiler-reg-call-split-shadows split-vars)
                5))
            (not
              (compiler-live-set-contains?
                (compiler-reg-call-split-shadows split-vars)
                6)))]))))

(cfg
  test
  (define (compiler-reg-scalar-call-spanning-multiblock-boundary-ok?) : bool
    (let
      [plan : CompilerRegPlan
        (compiler-reg-plan-function-scalar
          (compiler-reg-call-spanning-multiblock-boundary-function))]
      (match plan
        [(CompilerRegPlan.Plan _ _ _ _ split-vars _)
          (and
            (not
              (compiler-live-set-contains?
                (compiler-reg-call-split-shadows split-vars)
                5))
            (not
              (compiler-live-set-contains?
                (compiler-reg-call-split-shadows split-vars)
                6)))]))))

(cfg
  test
  (define (compiler-reg-edge-copy-list-has?
    [copies : CompilerRegEdgeCopySeq]
    [from-label : i64]
    [to-label : i64]
    [src : i64]
    [dst : i64]
    [want-pred-end : bool]) : bool
    (let
      [slots : (Array CompilerRegEdgeCopy) (struct-get copies slots)]
      [count : i64 (struct-get copies len)]
      [index : i64 0]
      [found : bool false]
      (begin
        (while (and (< index count) (not found))
          (begin
            (match (array-ref slots index)
              [(CompilerRegEdgeCopy.Copy
                  found-from
                  found-to
                  found-src
                  found-dst
                  _
                  _
                  placement)
                (if (and
                  (= found-from from-label)
                  (= found-to to-label)
                  (= found-src src)
                  (= found-dst dst)
                  (match placement
                    [(CompilerRegEdgeCopyPlacement.PredEnd) want-pred-end]
                    [(CompilerRegEdgeCopyPlacement.SuccEntry)
                      (not want-pred-end)]))
                  (set! found true)
                  unit)])
            (set! index (+ index 1))))
        found))))

(cfg
  test
  (define (compiler-reg-edge-copy-linear-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "edge_copy_linear")
      CompilerIrParamList.Nil
      (AstType.I64)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "hot"))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "hot")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
              CompilerIrInstrList.Nil))
          CompilerIrBlockList.Nil)))))

(cfg
  test
  (define (compiler-reg-edge-copy-linear-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-edge-copy-linear-function)]
      [region : CompilerRegLabelList
        (CompilerRegLabelList.Cons
          (compiler-ir-label "hot")
          (box CompilerRegLabelList.Nil))]
      (match (compiler-reg-edge-copy-plan-for-region
        func
        region
        0
        10
        (compiler-reg-i64-ty))
        [(CompilerRegEdgeCopyPlan.Plan copies)
          (and
            (= (compiler-reg-edge-copy-list-count copies) 1)
            (compiler-reg-edge-copy-list-has?
              copies
              (compiler-ir-label "entry")
              (compiler-ir-label "hot")
              0
              10
              true)
            (match func
              [(CompilerIrFunction.Function _ _ _ _ blocks)
                (match (compiler-reg-edge-copy-apply blocks copies)
                  [(CompilerRegEdgeCopyRewrite.Rewrite rewritten)
                    (compiler-reg-instr-list-has-mov-var?
                      (compiler-reg-block-instr-list
                        rewritten
                        (compiler-ir-label "entry"))
                      10
                      0)]
                  [(CompilerRegEdgeCopyRewrite.Refused _) false])]))]
        [(CompilerRegEdgeCopyPlan.Refused _) false]))))

(cfg
  test
  (define (compiler-reg-edge-copy-backedge-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "edge_copy_backedge")
      CompilerIrParamList.Nil
      (AstType.I64)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "loop")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Bool false)
                (compiler-ir-label "body")
                (compiler-ir-label "exit"))
              CompilerIrInstrList.Nil))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "body")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Store
                  (compiler-ir-test-symbol "sink")
                  (CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                  CompilerIrInstrList.Nil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "exit")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
                  CompilerIrInstrList.Nil))
              CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-edge-copy-backedge-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-edge-copy-backedge-function)]
      [region : CompilerRegLabelList
        (CompilerRegLabelList.Cons
          (compiler-ir-label "body")
          (box CompilerRegLabelList.Nil))]
      (match (compiler-reg-edge-copy-plan-for-region
        func
        region
        0
        10
        (compiler-reg-i64-ty))
        [(CompilerRegEdgeCopyPlan.Plan copies)
          (and
            (= (compiler-reg-edge-copy-list-count copies) 2)
            (compiler-reg-edge-copy-list-has?
              copies
              (compiler-ir-label "loop")
              (compiler-ir-label "body")
              0
              10
              false)
            (compiler-reg-edge-copy-list-has?
              copies
              (compiler-ir-label "body")
              (compiler-ir-label "loop")
              10
              0
              true)
            (match func
              [(CompilerIrFunction.Function _ _ _ _ blocks)
                (match (compiler-reg-edge-copy-apply blocks copies)
                  [(CompilerRegEdgeCopyRewrite.Rewrite rewritten)
                    (let
                      [body : CompilerIrInstrList
                        (compiler-reg-block-instr-list
                          rewritten
                          (compiler-ir-label "body"))]
                      (and
                        (compiler-reg-instr-list-has-mov-var? body 10 0)
                        (compiler-reg-instr-list-has-mov-var? body 0 10)))]
                  [(CompilerRegEdgeCopyRewrite.Refused _) false])]))]
        [(CompilerRegEdgeCopyPlan.Refused _) false]))))

(cfg
  test
  (define (compiler-reg-edge-copy-critical-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "edge_copy_critical")
      CompilerIrParamList.Nil
      (AstType.I64)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Bool false)
                (compiler-ir-label "hot")
                (compiler-ir-label "cold"))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "other")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "hot"))
              CompilerIrInstrList.Nil))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "hot")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
                CompilerIrInstrList.Nil))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "cold")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
                  CompilerIrInstrList.Nil))
              CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-edge-copy-critical-refusal-ok?) : bool
    (let
      [region : CompilerRegLabelList
        (CompilerRegLabelList.Cons
          (compiler-ir-label "hot")
          (box CompilerRegLabelList.Nil))]
      (match (compiler-reg-edge-copy-plan-for-region
        (compiler-reg-edge-copy-critical-function)
        region
        0
        10
        (compiler-reg-i64-ty))
        [(CompilerRegEdgeCopyPlan.Plan _) false]
        [(CompilerRegEdgeCopyPlan.Refused _) true]))))

(cfg
  test
  (define (compiler-reg-loop-split-plan [func : CompilerIrFunction]) : CompilerRegPlan
    (let
      [type-info : CompilerRegVarTypes (compiler-reg-function-var-types func)]
      [liveness : CompilerFunctionLiveness
        (compiler-live-analyze-function func)]
      (match (compiler-reg-live-interval-selection func liveness)
        [(CompilerRegIntervalSelection.Selection intervals _)
          (CompilerRegPlan.Plan
            (compiler-reg-assignment-cons
              (CompilerRegAssignment.Assignment
                0
                (CompilerRegLocation.Spill (compiler-reg-stack-slot-offset 0)))
              CompilerRegAssignmentList.Nil)
            (compiler-live-set-empty)
            intervals
            (compiler-reg-var-types-list type-info)
            (compiler-reg-call-split-empty)
            (compiler-reg-split-plan-empty))]))))

(cfg
  test
  (define (compiler-reg-loop-split-two-plan [func : CompilerIrFunction]) : CompilerRegPlan
    (let
      [type-info : CompilerRegVarTypes (compiler-reg-function-var-types func)]
      [liveness : CompilerFunctionLiveness
        (compiler-live-analyze-function func)]
      (match (compiler-reg-live-interval-selection func liveness)
        [(CompilerRegIntervalSelection.Selection intervals _)
          (CompilerRegPlan.Plan
            (compiler-reg-assignment-cons
              (CompilerRegAssignment.Assignment
                0
                (CompilerRegLocation.Spill (compiler-reg-stack-slot-offset 0)))
              (compiler-reg-assignment-cons
                (CompilerRegAssignment.Assignment
                  1
                  (CompilerRegLocation.Spill (compiler-reg-stack-slot-offset 1)))
                CompilerRegAssignmentList.Nil))
            (compiler-live-set-empty)
            intervals
            (compiler-reg-var-types-list type-info)
            (compiler-reg-call-split-empty)
            (compiler-reg-split-plan-empty))]))))

(cfg
  test
  (define (compiler-reg-leaf-csr-split-plan [func : CompilerIrFunction]) : CompilerRegPlan
    (let
      [type-info : CompilerRegVarTypes (compiler-reg-function-var-types func)]
      [liveness : CompilerFunctionLiveness
        (compiler-live-analyze-function func)]
      (match (compiler-reg-live-interval-selection func liveness)
        [(CompilerRegIntervalSelection.Selection intervals _)
          (CompilerRegPlan.Plan
            (compiler-reg-assignment-cons
              (CompilerRegAssignment.Assignment
                0
                (CompilerRegLocation.Register compiler-reg-id-r12))
              (compiler-reg-assignment-cons
                (CompilerRegAssignment.Assignment
                  1
                  (CompilerRegLocation.Register compiler-reg-id-r8))
                CompilerRegAssignmentList.Nil))
            (compiler-live-set-empty)
            intervals
            (compiler-reg-var-types-list type-info)
            (compiler-reg-call-split-empty)
            (compiler-reg-split-plan-empty))]))))

(cfg
  test
  (define (compiler-reg-leaf-csr-split-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "leaf_csr_split")
      CompilerIrParamList.Nil
      (AstType.I64)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "loop")
            (compiler-ir-instr-cons
              (CompilerIrInstr.BinOp
                1
                (CompilerIrBinOp.Eq)
                (CompilerIrValue.Var 0)
                (CompilerIrValue.I64 7)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Branch
                  (CompilerIrValue.Var 1)
                  (compiler-ir-label "body")
                  (compiler-ir-label "exit"))
                CompilerIrInstrList.Nil)))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "body")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Store
                  (compiler-ir-test-symbol "hot0")
                  (CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Store
                    (compiler-ir-test-symbol "hot1")
                    (CompilerIrValue.Var 0)
                    (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                    CompilerIrInstrList.Nil))))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "exit")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.I64 0)))
                  CompilerIrInstrList.Nil))
              CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-leaf-csr-split-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-leaf-csr-split-function)]
      [plan : CompilerRegPlan (compiler-reg-leaf-csr-split-plan func)]
      (match func
        [(CompilerIrFunction.Function _ _ _ vars blocks)
          (let
            [rewrite : CompilerRegCallSaveRewrite
              (compiler-reg-leaf-csr-split-rewrite-one
                (ast-node-pool-reader-type-segment-bases)
                CompilerRegTargetAbi.Linux
                func
                blocks
                vars
                (compiler-reg-function-var-types func)
                plan)]
            (match rewrite
              [(CompilerRegCallSaveRewrite.Rewrite
                  rewritten
                  _
                  out-vars
                  extra-assignments
                  _)
                (let
                  [rewritten-func : CompilerIrFunction
                    (CompilerIrFunction.Function
                      (compiler-ir-test-symbol "leaf_csr_split")
                      CompilerIrParamList.Nil
                      (AstType.I64)
                      out-vars
                      rewritten)]
                  [rewritten-types : CompilerRegVarTypes
                    (compiler-reg-function-var-types rewritten-func)]
                  [raw-plan : CompilerRegPlan
                    (compiler-reg-plan-function-scalar-cold-with-type-segment-bases-for-abi-with-types-and-preassignments
                      (ast-node-pool-reader-type-segment-bases)
                      CompilerRegTargetAbi.Linux
                      rewritten-func
                      (- 0 1)
                      rewritten-types
                      extra-assignments)]
                  [rewritten-plan : CompilerRegPlan
                    (compiler-reg-plan-hide-leaf-csr-phantoms
                      raw-plan
                      extra-assignments
                      vars)]
                  [assignments : CompilerRegAssignmentList
                    (compiler-reg-plan-assignments rewritten-plan)]
                  [body : CompilerIrInstrList
                    (compiler-reg-block-instr-list
                      rewritten
                      (compiler-ir-label "body"))]
                  (and
                    (= out-vars (+ vars 2))
                    (= (compiler-reg-assignment-count extra-assignments) 2)
                    (compiler-reg-leaf-csr-fuse-safe? func 1)
                    (not
                      (compiler-reg-assignments-use-register?
                        assignments
                        compiler-reg-id-r12))
                    (not
                      (compiler-reg-location-any-register?
                        (compiler-reg-assignment-lookup assignments 0)))
                    (compiler-reg-location-any-register?
                      (compiler-reg-assignment-lookup assignments vars))
                    (compiler-reg-location-any-register?
                      (compiler-reg-assignment-lookup assignments (+ vars 1)))
                    (not
                      (compiler-reg-same-location? assignments vars (+ vars 1)))
                    (compiler-reg-instr-list-has-store-var?
                      body
                      "hot0"
                      (+ vars 1))
                    (compiler-reg-instr-list-has-store-var?
                      body
                      "hot1"
                      (+ vars 1))
                    (not (compiler-reg-instr-list-has-store-var? body "hot0" 0))))]))]))))

(cfg
  test
  (define (compiler-reg-loop-split-rewrite-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "loop_split_rewrite")
      CompilerIrParamList.Nil
      (AstType.I64)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "loop")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Bool false)
                (compiler-ir-label "body")
                (compiler-ir-label "exit"))
              CompilerIrInstrList.Nil))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "body")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Store
                  (compiler-ir-test-symbol "hot0")
                  (CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Store
                    (compiler-ir-test-symbol "hot1")
                    (CompilerIrValue.Var 0)
                    (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                    CompilerIrInstrList.Nil))))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "exit")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
                  CompilerIrInstrList.Nil))
              CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-loop-split-two-rewrite-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "loop_split_two_rewrite")
      CompilerIrParamList.Nil
      (AstType.I64)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov
                1
                (CompilerIrValue.I64 11)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                CompilerIrInstrList.Nil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "loop")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Bool false)
                (compiler-ir-label "body")
                (compiler-ir-label "exit"))
              CompilerIrInstrList.Nil))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "body")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Store
                  (compiler-ir-test-symbol "hot0")
                  (CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Store
                    (compiler-ir-test-symbol "hot1")
                    (CompilerIrValue.Var 1)
                    (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Store
                      (compiler-ir-test-symbol "hot2")
                      (CompilerIrValue.Var 0)
                      (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Store
                        (compiler-ir-test-symbol "hot3")
                        (CompilerIrValue.Var 1)
                        (compiler-reg-i64-ty))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                        CompilerIrInstrList.Nil))))))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "exit")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
                  CompilerIrInstrList.Nil))
              CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-loop-split-low-benefit-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "loop_split_low_benefit")
      CompilerIrParamList.Nil
      (AstType.I64)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "loop")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Bool false)
                (compiler-ir-label "body")
                (compiler-ir-label "exit"))
              CompilerIrInstrList.Nil))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "body")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Store
                  (compiler-ir-test-symbol "hot0")
                  (CompilerIrValue.Var 0)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                  CompilerIrInstrList.Nil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "exit")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
                  CompilerIrInstrList.Nil))
              CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-loop-split-phi-region-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "loop_split_phi_region")
      CompilerIrParamList.Nil
      (AstType.I64)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "loop")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Branch
                (CompilerIrValue.Bool false)
                (compiler-ir-label "body")
                (compiler-ir-label "exit"))
              CompilerIrInstrList.Nil))
          (compiler-ir-block-cons
            (compiler-ir-block
              (compiler-ir-label "body")
              (compiler-ir-instr-cons
                (CompilerIrInstr.Phi
                  1
                  (compiler-ir-phi-input-cons
                    (CompilerIrValue.Var 0)
                    (compiler-ir-label "loop")
                    CompilerIrPhiInputList.Nil)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Store
                    (compiler-ir-test-symbol "hot0")
                    (CompilerIrValue.Var 0)
                    (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Store
                      (compiler-ir-test-symbol "hot1")
                      (CompilerIrValue.Var 0)
                      (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                      CompilerIrInstrList.Nil)))))
            (compiler-ir-block-cons
              (compiler-ir-block
                (compiler-ir-label "exit")
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return
                    (CompilerIrMaybeValue.Some (CompilerIrValue.Var 0)))
                  CompilerIrInstrList.Nil))
              CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-loop-split-rewrite-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-loop-split-rewrite-function)]
      [plan : CompilerRegPlan (compiler-reg-loop-split-plan func)]
      (match func
        [(CompilerIrFunction.Function _ _ _ vars blocks)
          (let
            [rewrite : CompilerRegCallSaveRewrite
              (compiler-reg-loop-split-rewrite-blocks
                (ast-node-pool-reader-type-segment-bases)
                func
                blocks
                vars
                (compiler-reg-function-var-types func)
                plan)]
            (match rewrite
              [(CompilerRegCallSaveRewrite.Rewrite
                  rewritten
                  _
                  out-vars
                  extra-assignments
                  _)
                (let
                  [body : CompilerIrInstrList
                    (compiler-reg-block-instr-list
                      rewritten
                      (compiler-ir-label "body"))]
                  [rewritten-plan : CompilerRegPlan
                    (compiler-reg-plan-with-call-save-rewrite plan rewrite)]
                  [rewritten-assignments : CompilerRegAssignmentList
                    (compiler-reg-plan-assignments rewritten-plan)]
                  (and
                    (= out-vars (+ vars 1))
                    (= (compiler-reg-assignment-count extra-assignments) 1)
                    ;; The region is clobber-free (no call/syscall), so the
                    ;; candidate list offers the caller-saved %r8/%r9/%rsi/%rdi
                    ;; before the callee-saved set and the split var takes %r8.
                    ;; (Stale %r12 expectation predated the clobber-free
                    ;; caller-saved widening; only --cfg test builds run this.)
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup
                        rewritten-assignments
                        vars)
                      compiler-reg-id-r8)
                    (compiler-reg-instr-list-has-mov-var? body vars 0)
                    (compiler-reg-instr-list-has-mov-var? body 0 vars)
                    (compiler-reg-instr-list-has-store-var? body "hot0" vars)
                    (compiler-reg-instr-list-has-store-var? body "hot1" vars)
                    (not (compiler-reg-instr-list-has-store-var? body "hot0" 0))))]))]))))

(cfg
  test
  (define (compiler-reg-loop-split-multiple-rewrite-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-loop-split-two-rewrite-function)]
      [plan : CompilerRegPlan (compiler-reg-loop-split-two-plan func)]
      (match func
        [(CompilerIrFunction.Function _ _ _ vars blocks)
          (let
            [rewrite : CompilerRegCallSaveRewrite
              (compiler-reg-loop-split-rewrite-blocks
                (ast-node-pool-reader-type-segment-bases)
                func
                blocks
                vars
                (compiler-reg-function-var-types func)
                plan)]
            (match rewrite
              [(CompilerRegCallSaveRewrite.Rewrite
                  rewritten
                  _
                  out-vars
                  extra-assignments
                  _)
                (let
                  [body : CompilerIrInstrList
                    (compiler-reg-block-instr-list
                      rewritten
                      (compiler-ir-label "body"))]
                  [rewritten-plan : CompilerRegPlan
                    (compiler-reg-plan-with-call-save-rewrite plan rewrite)]
                  [rewritten-assignments : CompilerRegAssignmentList
                    (compiler-reg-plan-assignments rewritten-plan)]
                  [split0 : i64 vars]
                  [split1 : i64 (+ vars 1)]
                  (and
                    (= out-vars (+ vars 2))
                    (= (compiler-reg-assignment-count extra-assignments) 2)
                    ;; Clobber-free region -> caller-saved candidates first:
                    ;; the two split vars take %r8 and %r9 (see
                    ;; compiler-reg-loop-split-candidate-regs).
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup
                        rewritten-assignments
                        split0)
                      compiler-reg-id-r8)
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup
                        rewritten-assignments
                        split1)
                      compiler-reg-id-r9)
                    (compiler-reg-instr-list-has-store-var? body "hot0" split0)
                    (compiler-reg-instr-list-has-store-var? body "hot1" split1)
                    (compiler-reg-instr-list-has-store-var? body "hot2" split0)
                    (compiler-reg-instr-list-has-store-var? body "hot3" split1)
                    (not (compiler-reg-instr-list-has-store-var? body "hot0" 0))
                    (not (compiler-reg-instr-list-has-store-var? body "hot1" 1))))]))]))))

(cfg
  test
  (define (compiler-reg-loop-split-noop-for? [func : CompilerIrFunction]) : bool
    (let
      [plan : CompilerRegPlan (compiler-reg-loop-split-plan func)]
      (match func
        [(CompilerIrFunction.Function _ _ _ vars blocks)
          (match (compiler-reg-loop-split-rewrite-blocks
            (ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite.Rewrite
                _
                _
                out-vars
                extra-assignments
                _)
              (and
                (= out-vars vars)
                (= (compiler-reg-assignment-count extra-assignments) 0))])]))))

(cfg
  test
  (define (compiler-reg-loop-split-low-benefit-ok?) : bool
    (compiler-reg-loop-split-noop-for?
      (compiler-reg-loop-split-low-benefit-function))))

(cfg
  test
  ;; Historical name: this fixture's phi-header region used to be REFUSED
  ;; (critical entry edge). The on-demand per-header preheader split
  ;; (compiler-reg-preheader-*) now inserts a dedicated preheader for exactly
  ;; this shape, so the hot spilled var IS homed: one split var, one extra
  ;; assignment. (Stale noop expectation predated the preheader machinery;
  ;; only --cfg test builds run this.)
  (define (compiler-reg-loop-split-phi-region-refusal-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-loop-split-phi-region-function)]
      [plan : CompilerRegPlan (compiler-reg-loop-split-plan func)]
      (match func
        [(CompilerIrFunction.Function _ _ _ vars blocks)
          (match (compiler-reg-loop-split-rewrite-blocks
            (ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite.Rewrite
                _
                _
                out-vars
                extra-assignments
                _)
              (and
                (= out-vars (+ vars 1))
                (= (compiler-reg-assignment-count extra-assignments) 1))])]))))

(cfg
  test
  (define (compiler-reg-loop-split-clobber-scan-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "loop_split_clobber_scan")
      CompilerIrParamList.Nil
      (AstType.I64)
      5
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "loop")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Mov
                1
                (CompilerIrValue.I64 3)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.BinOp
                  2
                  (CompilerIrBinOp.Shl)
                  (CompilerIrValue.Var 0)
                  (CompilerIrValue.Var 1)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.BinOp
                    3
                    (CompilerIrBinOp.Div)
                    (CompilerIrValue.Var 0)
                    (CompilerIrValue.Var 1)
                    (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.BinOp
                      4
                      (CompilerIrBinOp.Mul)
                      (CompilerIrValue.Var 0)
                      (CompilerIrValue.Var 1)
                      (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Jump (compiler-ir-label "loop"))
                      CompilerIrInstrList.Nil)))))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-loop-split-rcx-rdx-candidates-ok?) : bool
    (let
      [safe : CompilerRegIdList
        (compiler-reg-loop-split-candidate-regs true true true)]
      [unsafe : CompilerRegIdList
        (compiler-reg-loop-split-candidate-regs true false false)]
      [call-region : CompilerRegIdList
        (compiler-reg-loop-split-candidate-regs false true true)]
      (and
        (compiler-reg-id-list-contains? safe compiler-reg-id-rcx)
        (compiler-reg-id-list-contains? safe compiler-reg-id-rdx)
        (not (compiler-reg-id-list-contains? unsafe compiler-reg-id-rcx))
        (not (compiler-reg-id-list-contains? unsafe compiler-reg-id-rdx))
        (compiler-reg-id-list-contains? unsafe compiler-reg-id-r8)
        (compiler-reg-id-list-contains? unsafe compiler-reg-id-rdi)
        (not (compiler-reg-id-list-contains? call-region compiler-reg-id-r8))
        (not (compiler-reg-id-list-contains? call-region compiler-reg-id-rcx))
        (not (compiler-reg-id-list-contains? call-region compiler-reg-id-rdx))))))

(cfg
  test
  (define (compiler-reg-loop-split-fixed-clobber-scan-ok?) : bool
    (let
      [func : CompilerIrFunction
        (compiler-reg-loop-split-clobber-scan-function)]
      [full-window : CompilerRegIdList
        (compiler-reg-loop-split-candidate-regs
          true
          (compiler-reg-loop-split-region-rcx-safe?
            (ast-node-pool-reader-type-segment-bases)
            func
            0
            12)
          (compiler-reg-loop-split-region-rdx-safe?
            (ast-node-pool-reader-type-segment-bases)
            func
            0
            12))]
      (and
        ;; Point 4 is the variable shift; inclusive-start makes [4,6) unsafe.
        (compiler-reg-loop-split-region-crosses-kind?
          (ast-node-pool-reader-type-segment-bases)
          func
          2
          4
          6)
        ;; Points 6 and 8 are the div and mul %rdx fixed-use sites.
        (compiler-reg-loop-split-region-crosses-kind?
          (ast-node-pool-reader-type-segment-bases)
          func
          4
          6
          8)
        (compiler-reg-loop-split-region-crosses-kind?
          (ast-node-pool-reader-type-segment-bases)
          func
          4
          8
          10)
        ;; The half-open end still excludes a clobber exactly at end.
        (not
          (compiler-reg-loop-split-region-crosses-kind?
            (ast-node-pool-reader-type-segment-bases)
            func
            2
            0
            4))
        (not (compiler-reg-id-list-contains? full-window compiler-reg-id-rcx))
        (not (compiler-reg-id-list-contains? full-window compiler-reg-id-rdx))
        (compiler-reg-id-list-contains? full-window compiler-reg-id-r8)
        (compiler-reg-id-list-contains? full-window compiler-reg-id-rdi)))))

(cfg
  test
  (define (compiler-reg-many-call-live-function) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "many_call_live")
      CompilerIrParamList.Nil
      (AstType.Unit)
      6
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 9)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Call
                1
                (compiler-ir-test-symbol "side_effect_a")
                (CompilerIrCallArgs.Nil)
                (AstType.Unit))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Call
                  2
                  (compiler-ir-test-symbol "side_effect_b")
                  (CompilerIrCallArgs.Nil)
                  (AstType.Unit))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Call
                    3
                    (compiler-ir-test-symbol "side_effect_c")
                    (CompilerIrCallArgs.Nil)
                    (AstType.Unit))
                  (compiler-ir-instr-cons
                    (CompilerIrInstr.Call
                      4
                      (compiler-ir-test-symbol "side_effect_d")
                      (CompilerIrCallArgs.Nil)
                      (AstType.Unit))
                    (compiler-ir-instr-cons
                      (CompilerIrInstr.Mov
                        5
                        (CompilerIrValue.Var 0)
                        (compiler-reg-i64-ty))
                      (compiler-ir-instr-cons
                        (CompilerIrInstr.Return
                          (CompilerIrMaybeValue.Some (CompilerIrValue.Var 5)))
                        CompilerIrInstrList.Nil))))))))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-call-span-counts-ok?) : bool
    (let
      [points : CompilerLiveI64Set (compiler-live-set4 2 4 6 8)]
      (and
        (= (compiler-reg-call-set-count-in-range points 0 2) 0)
        (= (compiler-reg-call-set-count-in-range points 0 3) 1)
        (= (compiler-reg-call-set-count-in-range points 0 7) 3)
        (= (compiler-reg-call-set-count-in-range points 0 9) 4)
        (= (compiler-reg-call-set-count-in-range points 2 8) 2)))))

(cfg
  test
  (define (compiler-reg-call-span-census-count?
    [census : CompilerRegCallSpanCensus]
    [bucket : i64]
    [outcome : i64]
    [want : i64]) : bool
    (= (compiler-reg-call-span-census-count census bucket outcome) want)))

(cfg
  test
  (define (compiler-reg-call-span-census-ok?) : bool
    (let
      [zero-census : CompilerRegCallSpanCensus
        (compiler-reg-plan-call-span-census
          (compiler-reg-overlap-function)
          (compiler-reg-plan-function-scalar (compiler-reg-overlap-function)))]
      [one-census : CompilerRegCallSpanCensus
        (compiler-reg-plan-call-span-census
          (compiler-reg-call-live-function)
          (compiler-reg-plan-function-scalar (compiler-reg-call-live-function)))]
      [many-census : CompilerRegCallSpanCensus
        (compiler-reg-plan-call-span-census
          (compiler-reg-many-call-live-function)
          (compiler-reg-plan-function-scalar
            (compiler-reg-many-call-live-function)))]
      (and
        (compiler-reg-call-span-census-count?
          zero-census
          0
          (compiler-reg-call-span-outcome-register)
          7)
        (compiler-reg-call-span-census-count?
          zero-census
          0
          (compiler-reg-call-span-outcome-spill)
          0)
        (compiler-reg-call-span-census-count?
          one-census
          1
          (compiler-reg-call-span-outcome-register)
          1)
        (compiler-reg-call-span-census-count?
          one-census
          0
          (compiler-reg-call-span-outcome-register)
          1)
        (compiler-reg-call-span-census-count?
          many-census
          3
          (compiler-reg-call-span-outcome-register)
          1)
        (compiler-reg-call-span-census-count?
          many-census
          0
          (compiler-reg-call-span-outcome-register)
          1)))))

(cfg
  test
  (define (compiler-reg-xmm-ownership-fixed-home
    [preassigned-reg : i64]
    [intervals : CompilerRegIntervalSeq]
    [candidate-start : i64]
    [candidate-end : i64]
    [regs : CompilerRegIdList]) : i64
    (let
      [index : CompilerRegIntervalIndex
        (compiler-reg-interval-index-build intervals 2)]
      [assignments : CompilerRegAssignmentTable
        (compiler-reg-assignment-table-insert
          (compiler-reg-assignment-table-make 2)
          0
          (CompilerRegLocation.Register preassigned-reg))]
      [candidates : CompilerRegIntervalSeq
        (compiler-reg-interval-seq-prepend
          (CompilerRegInterval.Interval 1 candidate-start candidate-end)
          (compiler-reg-interval-seq-empty))]
      (match (compiler-reg-assign-fixed-candidates
        candidates
        regs
        (compiler-reg-active-seq-empty)
        assignments
        (array.make-array i64 0)
        index)
        [(CompilerRegAssignState.State _ out)
          (match (compiler-reg-assignment-table-lookup out 1)
            [(CompilerRegMaybeLocation.Some location)
              (compiler-reg-location-primary-register location)]
            [(CompilerRegMaybeLocation.No) compiler-reg-id-invalid])]))))

(cfg
  test
  (define (compiler-reg-register-id-range-roundtrips?
    [reg-id : i64]
    [end : i64]) : bool
    (if (>= reg-id end)
      true
      (and
        (=
          (compiler-abi-register-id-from-spelling
            (compiler-abi-register-spelling reg-id))
          reg-id)
        (compiler-reg-register-id-range-roundtrips? (+ reg-id 1) end)))))

(cfg
  test
  (define (compiler-reg-canonical-register-ids-ok?) : bool
    (and
      ;; Every canonical ID round-trips through the cold spelling boundary.
      (compiler-reg-register-id-range-roundtrips?
        compiler-reg-id-rax
        (+ compiler-reg-id-r15 1))
      (compiler-reg-register-id-range-roundtrips?
        compiler-reg-id-xmm-base
        (+ compiler-reg-id-xmm-base compiler-reg-id-family-count))
      (compiler-reg-register-id-range-roundtrips?
        compiler-reg-id-vec-base
        (+ compiler-reg-id-vec-base compiler-reg-id-family-count))
      (compiler-reg-register-id-range-roundtrips?
        compiler-reg-id-mask-base
        (+ compiler-reg-id-mask-base compiler-reg-id-mask-count))
      ;; Constructors reject values outside their compact domains.
      (= (compiler-abi-xmm-register-id -1) compiler-reg-id-invalid)
      (= (compiler-abi-xmm-register-id 32) compiler-reg-id-invalid)
      (= (compiler-abi-vector-register-id -1) compiler-reg-id-invalid)
      (= (compiler-abi-vector-register-id 32) compiler-reg-id-invalid)
      (= (compiler-abi-mask-register-id -1) compiler-reg-id-invalid)
      (= (compiler-abi-mask-register-id 8) compiler-reg-id-invalid)
      ;; Width-specific vector spellings share ownership without losing class.
      (=
        (compiler-abi-register-id-from-spelling "%ymm31")
        (compiler-abi-vector-register-id 31))
      (=
        (compiler-abi-register-id-from-spelling "%zmm31")
        (compiler-abi-vector-register-id 31))
      (compiler-abi-registers-overlap?
        (compiler-abi-xmm-register-id 31)
        (compiler-abi-vector-register-id 31))
      (=
        (compiler-abi-register-with-vector-class
          (compiler-abi-xmm-register-id 31)
          true)
        (compiler-abi-vector-register-id 31))
      ;; ABI tables return canonical IDs, including their invalid boundaries.
      (=
        (compiler-abi-gp-arg-register-id (CompilerRegTargetAbi.Linux) 0)
        compiler-reg-id-rdi)
      (=
        (compiler-abi-gp-arg-register-id (CompilerRegTargetAbi.Windows) 3)
        compiler-reg-id-r9)
      (=
        (compiler-abi-float-arg-register-id (CompilerRegTargetAbi.Linux) 7)
        (compiler-abi-xmm-register-id 7))
      (=
        (compiler-abi-callee-saved-xmm-register-id
          (CompilerRegTargetAbi.Windows)
          9)
        (compiler-abi-xmm-register-id 15))
      (=
        (compiler-abi-gp-arg-register-id (CompilerRegTargetAbi.Windows) 4)
        compiler-reg-id-invalid)
      (=
        (compiler-abi-caller-saved-xmm-register-id
          (CompilerRegTargetAbi.Windows)
          6)
        compiler-reg-id-invalid))))

(cfg
  test
  (define (compiler-reg-xmm-ownership-intervals
    [pre-start : i64]
    [pre-end : i64]
    [candidate-start : i64]
    [candidate-end : i64]) : CompilerRegIntervalSeq
    (compiler-reg-interval-seq-prepend
      (CompilerRegInterval.Interval 0 pre-start pre-end)
      (compiler-reg-interval-seq-prepend
        (CompilerRegInterval.Interval 1 candidate-start candidate-end)
        (compiler-reg-interval-seq-empty)))))

(cfg
  test
  (define (compiler-reg-xmm-ownership-segment-hole-intervals) : CompilerRegIntervalSeq
    (compiler-reg-interval-seq-prepend
      (CompilerRegInterval.Interval 0 0 2)
      (compiler-reg-interval-seq-prepend
        (CompilerRegInterval.Interval 1 3 5)
        (compiler-reg-interval-seq-prepend
          (CompilerRegInterval.Interval 0 6 8)
          (compiler-reg-interval-seq-empty))))))

(cfg
  test
  (define (compiler-reg-xmm-physical-ownership-ok?) : bool
    (let
      [vector-pool : CompilerRegIdList
        (compiler-reg-id-cons
          (compiler-abi-vector-register-id 6)
          (compiler-reg-id-cons
            (compiler-abi-vector-register-id 7)
            CompilerRegIdList.Nil))]
      [scalar-spelled-pool : CompilerRegIdList
        (compiler-reg-id-cons
          (compiler-abi-xmm-register-id 6)
          (compiler-reg-id-cons
            (compiler-abi-xmm-register-id 7)
            CompilerRegIdList.Nil))]
      [overlap : CompilerRegIntervalSeq
        (compiler-reg-xmm-ownership-intervals 0 8 2 6)]
      [boundary-reuse : CompilerRegIntervalSeq
        (compiler-reg-xmm-ownership-intervals 0 2 2 6)]
      (and
        ;; AVX2/AVX-512 spellings and the width-neutral allocator home all own
        ;; the same physical register as an f32/f64 scalar XMM spelling.
        (compiler-reg-registers-overlap?
          (compiler-abi-xmm-register-id 6)
          (compiler-abi-vector-register-id 6))
        (compiler-reg-registers-overlap?
          (compiler-abi-xmm-register-id 6)
          (compiler-abi-register-id-from-spelling "%ymm6"))
        (compiler-reg-registers-overlap?
          (compiler-abi-xmm-register-id 6)
          (compiler-abi-register-id-from-spelling "%zmm6"))
        (not
          (compiler-reg-registers-overlap?
            (compiler-abi-xmm-register-id 6)
            (compiler-abi-vector-register-id 7)))
        (not
          (compiler-reg-registers-overlap?
            (compiler-abi-xmm-register-id 6)
            (compiler-abi-mask-register-id 6)))
        (= (compiler-reg-xmm-family-index (compiler-abi-xmm-register-id 13)) 13)
        (=
          (compiler-reg-xmm-family-index
            (compiler-abi-register-id-from-spelling "%ymm13"))
          13)
        (=
          (compiler-reg-xmm-family-index
            (compiler-abi-register-id-from-spelling "%zmm13"))
          13)
        (=
          (compiler-reg-xmm-family-index (compiler-abi-vector-register-id 13))
          13)
        (=
          (compiler-reg-xmm-family-index
            (compiler-abi-register-id-from-spelling "%xmm06"))
          -1)
        ;; Deliberate f32/f64-vs-vector collisions reject physical index 6 at
        ;; every emitted width and select the next vector home.
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (compiler-abi-xmm-register-id 6)
            overlap
            2
            6
            vector-pool)
          (compiler-abi-vector-register-id 7))
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (compiler-abi-vector-register-id 6)
            overlap
            2
            6
            vector-pool)
          (compiler-abi-vector-register-id 7))
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (compiler-abi-vector-register-id 6)
            overlap
            2
            6
            vector-pool)
          (compiler-abi-vector-register-id 7))
        ;; Mask-on-vector allocation uses the same ownership query even when
        ;; the preassignment and candidate pools use opposite class spellings.
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (compiler-abi-vector-register-id 6)
            overlap
            2
            6
            scalar-spelled-pool)
          (compiler-abi-xmm-register-id 7))
        ;; Touching ranges and a segmented phi/liveness hole may safely reuse
        ;; the physical register; real segment overlap still rejects it.
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (compiler-abi-xmm-register-id 6)
            boundary-reuse
            2
            6
            vector-pool)
          (compiler-abi-vector-register-id 6))
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (compiler-abi-xmm-register-id 6)
            (compiler-reg-xmm-ownership-segment-hole-intervals)
            3
            5
            vector-pool)
          (compiler-abi-vector-register-id 6))))))

(cfg
  test
  (define (compiler-reg-dense-mask-on-vector-homes-ok?) : bool
    (let
      [list-func : CompilerIrFunction (compiler-reg-mask-home-function)]
      [dense-func : CompilerIrFunction
        (compiler-ir-function-compact-blocks list-func)]
      [list-assignments : CompilerRegAssignmentList
        (compiler-reg-plan-assignments
          (compiler-reg-plan-function-avx2 list-func))]
      [dense-assignments : CompilerRegAssignmentList
        (compiler-reg-plan-assignments
          (compiler-reg-plan-function-avx2 dense-func))]
      (and
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup list-assignments 0)
          (compiler-abi-vector-register-id 6))
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup list-assignments 1)
          (compiler-abi-vector-register-id 7))
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup dense-assignments 0)
          (compiler-abi-vector-register-id 6))
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup dense-assignments 1)
          (compiler-abi-vector-register-id 7))))))

(cfg
  test
  (define (compiler-reg-liveness-handle-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-edge-copy-linear-function)]
      [region : CompilerRegLabelList
        (CompilerRegLabelList.Cons
          (compiler-ir-label "hot")
          (box CompilerRegLabelList.Nil))]
      (begin
        (compiler-reg-liveness-census-reset!)
        (let
          [handle : CompilerRegLivenessHandle
            (compiler-reg-liveness-handle-make func true)]
          [liveness : CompilerFunctionLiveness (struct-get handle baseline)]
          (and
            (match (compiler-reg-edge-copy-plan-for-region-with-liveness
              liveness
              region
              0
              10
              (compiler-reg-i64-ty))
              [(CompilerRegEdgeCopyPlan.Plan _) true]
              [(CompilerRegEdgeCopyPlan.Refused _) false])
            (match (compiler-reg-edge-copy-plan-for-region-with-liveness
              liveness
              region
              0
              11
              (compiler-reg-i64-ty))
              [(CompilerRegEdgeCopyPlan.Plan _) true]
              [(CompilerRegEdgeCopyPlan.Refused _) false])
            (= (compiler-reg-liveness-census-baseline-count) 1)
            ;; The linear fixture is phi-free, so the edge-precise analysis is
            ;; the baseline itself and no second fixpoint is computed.
            (= (compiler-reg-liveness-census-edge-precise-count) 0)))))))

(cfg
  test
  (define (compiler-reg-liveness-handle-phi-fixture) : CompilerIrFunction
    (CompilerIrFunction.Function
      (compiler-ir-test-symbol "liveness_handle_phi")
      CompilerIrParamList.Nil
      (AstType.I64)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "entry")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Mov
              0
              (CompilerIrValue.I64 7)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Jump (compiler-ir-label "loop"))
              CompilerIrInstrList.Nil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            (compiler-ir-label "loop")
            (compiler-ir-instr-cons
              (CompilerIrInstr.Phi
                1
                (CompilerIrPhiInputList.Cons
                  (CompilerIrValue.Var 0)
                  (compiler-ir-label "entry")
                  (box
                    (CompilerIrPhiInputList.Cons
                      (CompilerIrValue.Var 1)
                      (compiler-ir-label "loop")
                      (box CompilerIrPhiInputList.Nil))))
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Return
                  (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
                CompilerIrInstrList.Nil)))
          CompilerIrBlockList.Nil)))))

(cfg
  test
  (define (compiler-reg-liveness-handle-phi-ok?) : bool
    (begin
      (compiler-reg-liveness-census-reset!)
      (let
        [_handle : CompilerRegLivenessHandle
          (compiler-reg-liveness-handle-make
            (compiler-reg-liveness-handle-phi-fixture)
            true)]
        (and
          (= (compiler-reg-liveness-census-baseline-count) 1)
          ;; Phi present: the second, edge-precise fixpoint is computed.
          (= (compiler-reg-liveness-census-edge-precise-count) 1))))))

(cfg
  test
  (define (compiler-reg-group-pair-test-fill-homes!
    [assignments : CompilerRegAssignmentTable]
    [var : i64]
    [vars : i64]) : unit
    (if (or (>= var vars) (>= var 6))
      unit
      (let
        [_inserted : CompilerRegAssignmentTable
          (compiler-reg-assignment-table-insert
            assignments
            var
            (CompilerRegLocation.Register
              (compiler-reg-group-pair-csr (- var 1))))]
        (compiler-reg-group-pair-test-fill-homes! assignments (+ var 1) vars)))))

;; Keep the late pair pass honest without depending on an incidental whole
;; program's pressure shape. Cold scalars occupy every CSR so a call-spanning
;; component must evict two of them, while a clobber-free component keeps the
;; r8:r9 pair. A cold scalar in r8 proves caller-pair eviction, while a
;; synthetic call-save shadow reserves r8 over the same range. A normal-call
;; group argument stays eligible for a CSR pair, but not the caller pair,
;; until the multiword ABI marshaller can use the pair parallel-move solver.
(cfg
  test
  (define (compiler-reg-group-pair-widening-ok?) : bool
    (let
      [vars : i64 10]
      [interval-index : CompilerRegIntervalIndex
        (compiler-reg-interval-index-build
          (compiler-reg-interval-seq-prepend
            (CompilerRegInterval.Interval 0 0 10)
            (compiler-reg-interval-seq-prepend
              (CompilerRegInterval.Interval 1 0 10)
              (compiler-reg-interval-seq-prepend
                (CompilerRegInterval.Interval 2 0 10)
                (compiler-reg-interval-seq-prepend
                  (CompilerRegInterval.Interval 3 0 10)
                  (compiler-reg-interval-seq-prepend
                    (CompilerRegInterval.Interval 4 0 10)
                    (compiler-reg-interval-seq-prepend
                      (CompilerRegInterval.Interval 5 0 10)
                      (compiler-reg-interval-seq-prepend
                        (CompilerRegInterval.Interval 6 0 10)
                        (compiler-reg-interval-seq-prepend
                          (CompilerRegInterval.Interval 7 0 10)
                          (compiler-reg-interval-seq-prepend
                            (CompilerRegInterval.Interval 8 0 10)
                            (compiler-reg-interval-seq-prepend
                              (CompilerRegInterval.Interval 9 0 10)
                              (compiler-reg-interval-seq-empty)))))))))))
          vars)]
      [members : (Array i64) (array.make-array i64 vars)]
      [parents : (Array i64) (array.make-array i64 vars)]
      [poisoned : (Array bool) (array.make-array bool vars)]
      [weights : (Array i64) (array.make-array i64 vars)]
      [assignments : CompilerRegAssignmentTable
        (compiler-reg-assignment-table-make vars)]
      [csr-assignments : CompilerRegAssignmentTable
        (compiler-reg-assignment-table-make vars)]
      [caller-occupied : CompilerRegAssignmentTable
        (compiler-reg-assignment-table-make vars)]
      [nonoccupying : CompilerRegAssignmentTable
        (compiler-reg-assignment-table-make vars)]
      [shadow-regs : (Array i64) (array.make-array i64 2)]
      (begin
        (compiler-reg-fill-i64-array shadow-regs compiler-reg-id-invalid)
        (array-set! members 0 0)
        (compiler-reg-fill-i64-array weights 1)
        (array-set! weights 0 10)
        (let
          [v : i64 0]
          (while (< v vars)
            (begin
              (array-set! parents v v)
              (array-set! poisoned v false)
              (set! v (+ v 1)))))
        (array-set! shadow-regs 1 compiler-reg-id-r8)
        (compiler-reg-group-pair-test-fill-homes! assignments 1 vars)
        (compiler-reg-group-pair-test-fill-homes! csr-assignments 1 vars)
        (compiler-reg-group-pair-test-fill-homes! caller-occupied 1 vars)
        (let
          [_nonoccupying-spill : CompilerRegAssignmentTable
            (compiler-reg-assignment-table-insert
              nonoccupying
              1
              (CompilerRegLocation.Spill (compiler-reg-stack-slot-offset 1)))]
          [_nonoccupying-pair : CompilerRegAssignmentTable
            (compiler-reg-assignment-table-insert
              nonoccupying
              2
              (CompilerRegLocation.RegisterPair
                compiler-reg-id-r12
                compiler-reg-id-r13))]
          [_caller-occupied-r8 : CompilerRegAssignmentTable
            (compiler-reg-assignment-table-insert
              caller-occupied
              1
              (CompilerRegLocation.Register compiler-reg-id-r8))]
          [_caller-occupied-r12 : CompilerRegAssignmentTable
            (compiler-reg-assignment-table-insert
              caller-occupied
              6
              (CompilerRegLocation.Register compiler-reg-id-r12))]
          [empty-split : CompilerRegCallSplit (compiler-reg-call-split-empty)]
          [shadow-split : CompilerRegCallSplit
            (CompilerRegCallSplit
              (compiler-live-set-empty)
              shadow-regs
              (compiler-reg-call-region-seq-push
                (compiler-reg-call-region-seq-empty)
                (CompilerRegCallRegion 1 0 10 0 0)))]
          [phi-excluded : CompilerLiveI64Set
            (compiler-reg-group-pair-excluded-instr
              (compiler-live-set-empty)
              (CompilerIrInstr.Phi
                0
                CompilerIrPhiInputList.Nil
                (AstType.Struct (intern "Pair")))
              (compiler-live-set1 0))]
          [call-caller-unsafe : CompilerLiveI64Set
            (compiler-reg-group-pair-caller-unsafe-instr
              (compiler-live-set-empty)
              (CompilerIrInstr.Call
                1
                (compiler-ir-test-symbol "callee")
                (CompilerIrCallArgs.One (CompilerIrValue.Var 0))
                (AstType.I64)))]
          [indirect-call-caller-unsafe : CompilerLiveI64Set
            (compiler-reg-group-pair-caller-unsafe-instr
              (compiler-live-set-empty)
              (CompilerIrInstr.CallIndirect
                1
                (CompilerIrValue.Var 2)
                (CompilerIrCallArgs.One (CompilerIrValue.Var 0))
                (AstType.I64)))]
          [indirect-c-call-caller-unsafe : CompilerLiveI64Set
            (compiler-reg-group-pair-caller-unsafe-instr
              (compiler-live-set-empty)
              (CompilerIrInstr.CallIndirectC
                1
                (CompilerIrValue.Var 2)
                (CompilerIrCallArgs.One (CompilerIrValue.Var 0))
                (AstType.I64)))]
          [shadow-cost : i64
            (compiler-reg-group-pair-component-register-cost
              assignments
              interval-index
              members
              1
              weights
              10
              true
              shadow-split
              compiler-reg-id-r8
              vars)]
          [free-r8-cost : i64
            (compiler-reg-group-pair-component-register-cost
              nonoccupying
              interval-index
              members
              1
              weights
              10
              true
              empty-split
              compiler-reg-id-r8
              vars)]
          [occupied-r8-cost : i64
            (compiler-reg-group-pair-component-register-cost
              caller-occupied
              interval-index
              members
              1
              weights
              10
              true
              empty-split
              compiler-reg-id-r8
              vars)]
          [csr-evict-cost : i64
            (compiler-reg-group-pair-component-register-cost
              assignments
              interval-index
              members
              1
              weights
              10
              false
              empty-split
              compiler-reg-id-r12
              vars)]
          [blocked-r12-cost : i64
            (compiler-reg-group-pair-component-register-cost
              nonoccupying
              interval-index
              members
              1
              weights
              10
              false
              empty-split
              compiler-reg-id-r12
              vars)]
          (let
            [_caller-placed : unit
              (compiler-reg-assign-group-pair-component
                (ast-node-pool-reader-type-segment-bases)
                0
                vars
                (compiler-reg-coalesce-test-i64-types vars)
                (compiler-live-set1 0)
                (compiler-live-set-empty)
                (compiler-live-set-empty)
                (struct-get interval-index starts)
                (struct-get interval-index ends)
                poisoned
                parents
                members
                interval-index
                caller-occupied
                weights
                (compiler-live-set-empty)
                empty-split)]
            [_csr-placed : unit
              (compiler-reg-assign-group-pair-component
                (ast-node-pool-reader-type-segment-bases)
                0
                vars
                (compiler-reg-coalesce-test-i64-types vars)
                (compiler-live-set1 0)
                (compiler-live-set-empty)
                (compiler-live-set1 0)
                (struct-get interval-index starts)
                (struct-get interval-index ends)
                poisoned
                parents
                members
                interval-index
                csr-assignments
                weights
                (compiler-live-set-empty)
                empty-split)]
            [_placed : unit
              (compiler-reg-assign-group-pair-component
                (ast-node-pool-reader-type-segment-bases)
                0
                vars
                (compiler-reg-coalesce-test-i64-types vars)
                (compiler-live-set1 0)
                (compiler-live-set-empty)
                (compiler-live-set-empty)
                (struct-get interval-index starts)
                (struct-get interval-index ends)
                poisoned
                parents
                members
                interval-index
                assignments
                weights
                (compiler-live-set-empty)
                empty-split)]
            (and
              (= (compiler-reg-group-pair-candidate-count true) 7)
              (= (compiler-reg-group-pair-candidate true 0) compiler-reg-id-r8)
              (= (compiler-reg-group-pair-candidate true 1) compiler-reg-id-r9)
              (= (compiler-reg-group-pair-candidate true 2) compiler-reg-id-r12)
              (= (compiler-reg-group-pair-candidate-count false) 5)
              (=
                (compiler-reg-group-pair-candidate false 0)
                compiler-reg-id-r12)
              (compiler-reg-group-pair-component-clobber-free?
                interval-index
                (compiler-live-set-empty)
                members
                1)
              (not
                (compiler-reg-group-pair-component-clobber-free?
                  interval-index
                  (compiler-live-set1 5)
                  members
                  1))
              (not (compiler-live-set-contains? phi-excluded 0))
              (compiler-live-set-contains? call-caller-unsafe 0)
              (compiler-live-set-contains? indirect-call-caller-unsafe 0)
              (compiler-live-set-contains? indirect-c-call-caller-unsafe 0)
              (compiler-reg-group-pair-component-contains?
                call-caller-unsafe
                members
                1)
              (= shadow-cost (- 0 1))
              (= free-r8-cost 0)
              (> occupied-r8-cost 0)
              (> csr-evict-cost 0)
              (= blocked-r12-cost (- 0 1))
              (match (compiler-reg-assignment-table-lookup assignments 0)
                [(CompilerRegMaybeLocation.Some location)
                  (match location
                    [(CompilerRegLocation.RegisterPair first second)
                      (and
                        (= first compiler-reg-id-r8)
                        (= second compiler-reg-id-r9))]
                    [_ false])]
                [(CompilerRegMaybeLocation.No) false])
              (match (compiler-reg-assignment-table-lookup assignments 1)
                [(CompilerRegMaybeLocation.Some location)
                  (match location
                    [(CompilerRegLocation.Register reg)
                      (= reg compiler-reg-id-r12)]
                    [_ false])]
                [(CompilerRegMaybeLocation.No) false])
              (match (compiler-reg-assignment-table-lookup caller-occupied 0)
                [(CompilerRegMaybeLocation.Some location)
                  (match location
                    [(CompilerRegLocation.RegisterPair first second)
                      (and
                        (= first compiler-reg-id-r8)
                        (= second compiler-reg-id-r9))]
                    [_ false])]
                [(CompilerRegMaybeLocation.No) false])
              (match (compiler-reg-assignment-table-lookup caller-occupied 1)
                [(CompilerRegMaybeLocation.Some location)
                  (match location
                    [(CompilerRegLocation.Spill _) true]
                    [_ false])]
                [(CompilerRegMaybeLocation.No) false])
              (match (compiler-reg-assignment-table-lookup csr-assignments 0)
                [(CompilerRegMaybeLocation.Some location)
                  (match location
                    [(CompilerRegLocation.RegisterPair first second)
                      (and
                        (= first compiler-reg-id-r12)
                        (= second compiler-reg-id-r13))]
                    [_ false])]
                [(CompilerRegMaybeLocation.No) false])
              (match (compiler-reg-assignment-table-lookup csr-assignments 1)
                [(CompilerRegMaybeLocation.Some location)
                  (match location
                    [(CompilerRegLocation.Spill _) true]
                    [_ false])]
                [(CompilerRegMaybeLocation.No) false])
              (match (compiler-reg-assignment-table-lookup csr-assignments 2)
                [(CompilerRegMaybeLocation.Some location)
                  (match location
                    [(CompilerRegLocation.Spill _) true]
                    [_ false])]
                [(CompilerRegMaybeLocation.No) false]))))))))

(cfg
  test
  (define (compiler-reg-test-interval-shape?
    [items : CompilerRegIntervalSeq]
    [index : i64]
    [var : i64]
    [start : i64]
    [end : i64]) : bool
    (match (compiler-reg-interval-seq-ref items index)
      [(CompilerRegInterval.Interval got-var got-start got-end)
        (and (= got-var var) (= got-start start) (= got-end end))])))

(cfg
  test
  (define (compiler-reg-dense-interval-seq-ok?) : bool
    (let
      [appended : CompilerRegIntervalSeq (compiler-reg-interval-seq-empty)]
      [prepended : CompilerRegIntervalSeq (compiler-reg-interval-seq-empty)]
      [inserted : CompilerRegIntervalSeq (compiler-reg-interval-seq-empty)]
      [separated-left : CompilerRegIntervalSeq
        (compiler-reg-interval-seq-empty)]
      [separated-right : CompilerRegIntervalSeq
        (compiler-reg-interval-seq-empty)]
      [late-overlap-right : CompilerRegIntervalSeq
        (compiler-reg-interval-seq-empty)]
      [zero-left : CompilerRegIntervalSeq (compiler-reg-interval-seq-empty)]
      [zero-right : CompilerRegIntervalSeq (compiler-reg-interval-seq-empty)]
      [i : i64 0]
      (begin
        ;; Cross several capacity boundaries in both construction directions.
        (while (< i 10)
          (begin
            (set!
              appended
              (compiler-reg-interval-seq-append
                appended
                (CompilerRegInterval.Interval i (* i 2) (+ (* i 2) 1))))
            (set!
              prepended
              (compiler-reg-interval-seq-prepend
                (CompilerRegInterval.Interval i (* i 2) (+ (* i 2) 1))
                prepended))
            (set! i (+ i 1))))
        (set!
          inserted
          (compiler-reg-interval-seq-append
            inserted
            (CompilerRegInterval.Interval 0 0 1)))
        (set!
          inserted
          (compiler-reg-interval-seq-append
            inserted
            (CompilerRegInterval.Interval 2 4 5)))
        (set!
          inserted
          (compiler-reg-interval-seq-append
            inserted
            (CompilerRegInterval.Interval 1 2 3)))
        (set! inserted (compiler-reg-candidate-sort inserted))
        (set!
          separated-left
          (compiler-reg-interval-seq-append
            separated-left
            (CompilerRegInterval.Interval 0 1 2)))
        (set!
          separated-left
          (compiler-reg-interval-seq-append
            separated-left
            (CompilerRegInterval.Interval 0 6 8)))
        (set!
          separated-left
          (compiler-reg-interval-seq-append
            separated-left
            (CompilerRegInterval.Interval 0 12 15)))
        (set!
          separated-right
          (compiler-reg-interval-seq-append
            separated-right
            (CompilerRegInterval.Interval 1 2 4)))
        (set!
          separated-right
          (compiler-reg-interval-seq-append
            separated-right
            (CompilerRegInterval.Interval 1 8 10)))
        (set!
          separated-right
          (compiler-reg-interval-seq-append
            separated-right
            (CompilerRegInterval.Interval 1 15 18)))
        (set!
          late-overlap-right
          (compiler-reg-interval-seq-append
            late-overlap-right
            (CompilerRegInterval.Interval 1 2 4)))
        (set!
          late-overlap-right
          (compiler-reg-interval-seq-append
            late-overlap-right
            (CompilerRegInterval.Interval 1 8 10)))
        (set!
          late-overlap-right
          (compiler-reg-interval-seq-append
            late-overlap-right
            (CompilerRegInterval.Interval 1 14 18)))
        (set!
          zero-left
          (compiler-reg-interval-seq-append
            zero-left
            (CompilerRegInterval.Interval 0 0 0)))
        (set!
          zero-right
          (compiler-reg-interval-seq-append
            zero-right
            (CompilerRegInterval.Interval 1 0 2)))
        (and
          (= (compiler-reg-interval-seq-count appended) 10)
          (compiler-reg-test-interval-shape? appended 0 0 0 1)
          (compiler-reg-test-interval-shape? appended 9 9 18 19)
          (= (compiler-reg-interval-seq-count prepended) 10)
          (compiler-reg-test-interval-shape? prepended 0 9 18 19)
          (compiler-reg-test-interval-shape? prepended 9 0 0 1)
          (= (compiler-reg-interval-seq-count inserted) 3)
          (compiler-reg-test-interval-shape? inserted 0 0 0 1)
          (compiler-reg-test-interval-shape? inserted 1 1 2 3)
          (compiler-reg-test-interval-shape? inserted 2 2 4 5)
          ;; Touching boundaries after point zero remain non-overlapping.
          (not
            (compiler-reg-interval-seq-overlaps? separated-left separated-right))
          ;; The ordered scan must continue far enough to find a late overlap.
          (compiler-reg-interval-seq-overlaps?
            separated-left
            late-overlap-right)
          (not
            (compiler-reg-interval-seq-overlaps-one?
              separated-left
              (CompilerRegInterval.Interval 2 4 6)))
          ;; Entry-point touches preserve the prologue-home exception.
          (compiler-reg-interval-seq-overlaps? zero-left zero-right))))))

(cfg
  test
  (test
    regalloc-dense-interval-sequence
    (test.assert-true
      (compiler-reg-dense-interval-seq-ok?)
      "dense interval growth preserves order and merge overlap boundaries")))

(cfg
  test
  (test
    regalloc-call-word-in-range-matches-walk
    (test.assert-true
      (compiler-reg-call-word-in-range-matches-walk?)
      "mask range test agrees with the bit walk it replaced, high bits included")))

(cfg
  test
  (test
    regalloc-canonical-register-ids
    (test.assert-true
      (compiler-reg-canonical-register-ids-ok?)
      "canonical GP/vector/mask IDs round-trip, alias, and follow both ABIs")))

(cfg
  test
  (test
    regalloc-xmm-physical-ownership
    (test.assert-true
      (compiler-reg-xmm-physical-ownership-ok?)
      "XMM-family physical ownership rejects overlap and permits liveness holes")))

(cfg
  test
  (test
    regalloc-xmm-dense-mask-on-vector
    (test.assert-true
      (compiler-reg-dense-mask-on-vector-homes-ok?)
      "dense/list mask-on-vector allocation keeps canonical XMM ownership")))

(cfg
  test
  (test
    regalloc-xmm-abi-pools
    (test.assert-true
      (and
        (compiler-reg-xmm-clobbers-ok?)
        (compiler-reg-low-xmm-vector-boundaries-ok?))
      "ABI pools admit scalar XMM0/XMM1 while vector scratch boundaries stay explicit")))

(cfg
  test
  (test
    regalloc-xmm-abi-call-constraints
    (test.assert-true
      (and
        (compiler-reg-xmm-abi-call-constraints-ok?)
        (compiler-reg-xmm-shared-greedy-bank-ok?)
        (compiler-reg-xmm-vector-class-reset-ok?))
      "ABI XMM pools enforce SysV volatile and Win64 nonvolatile call homes")))

(cfg
  test
  (test
    regalloc-vector-mask-homes
    (test.assert-true
      (and
        (compiler-reg-vector-mask-homes-ok?)
        (compiler-reg-mask-pressure-spill-home-ok?))
      "expanded vector/mask pools preserve homes and spill excess k-mask pressure")))

(cfg
  test
  (test
    regalloc-self-loop-exit-live-phi
    (test.assert-true
      (compiler-reg-self-loop-exit-live-phi-mask-ok?)
      "self-loop safety admits accumulator, excludes live counter, and ignores successor order")))

(cfg
  test
  (test
    regalloc-destructive-chain
    (test.assert-true
      (compiler-reg-destructive-chain-ok?)
      "bounded destructive ties coalesce lhs/rhs chains and refuse clobber/noncomm-rhs/div")))

;; M-B2 scalar phi-web slot sharing. Both cases hand the colorer the SAME plan
;; intervals -- deliberately overlapping, which is what the conservative model
;; produces for a phi and its input, because it counts the input as live AT the
;; phi block -- so only the block shape decides. `entry` defines the input and
;; `merge`'s phi consumes it: with the input dead after the phi the two
;; edge-precise hulls are strictly ordered and one slot serves both; with the
;; input still live past the phi they genuinely interfere and keep two slots.
(cfg
  test
  (define (compiler-reg-color-phi-web-blocks [live-after-phi : bool]) : CompilerIrBlockList
    (compiler-ir-block-cons
      (compiler-ir-block
        (compiler-ir-label "entry")
        (compiler-ir-instr-cons
          (CompilerIrInstr.Mov 1 (CompilerIrValue.I64 7) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Jump (compiler-ir-label "merge"))
            CompilerIrInstrList.Nil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          (compiler-ir-label "merge")
          (compiler-ir-instr-cons
            (CompilerIrInstr.Phi
              0
              (compiler-ir-phi-input-cons
                (CompilerIrValue.Var 1)
                (compiler-ir-label "entry")
                CompilerIrPhiInputList.Nil)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Return
                (CompilerIrMaybeValue.Some
                  (CompilerIrValue.Var
                    (if live-after-phi
                      1
                      0))))
              CompilerIrInstrList.Nil)))
        CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-color-phi-web-intervals) : CompilerRegIntervalSeq
    (compiler-reg-interval-seq-prepend
      (CompilerRegInterval.Interval 1 0 6)
      (compiler-reg-interval-seq-prepend
        (CompilerRegInterval.Interval 0 4 6)
        (compiler-reg-interval-seq-empty)))))

(cfg
  test
  (define (compiler-reg-color-phi-web-coloring [live-after-phi : bool]) : CompilerRegColoring
    (compiler-reg-color-stack-slots
      (ast-node-pool-reader-type-segment-bases)
      (CompilerRegPlan.Plan
        (compiler-reg-color-spill-sharing-assignments 2)
        (compiler-live-set-empty)
        (compiler-reg-color-phi-web-intervals)
        (compiler-reg-color-spill-sharing-types 2)
        (compiler-reg-call-split-empty)
        (compiler-reg-split-plan-empty))
      (compiler-live-set-empty)
      CompilerIrParamList.Nil
      (compiler-reg-color-phi-web-blocks live-after-phi)
      2
      2)))

(cfg
  test
  (define (compiler-reg-color-phi-web-slot-sharing-ok?) : bool
    (match (compiler-reg-color-phi-web-coloring false)
      [(CompilerRegColoring.Remap share-remap share-slots)
        (match (compiler-reg-color-phi-web-coloring true)
          [(CompilerRegColoring.Remap live-remap live-slots)
            (and
              (= share-slots 1)
              (= (array-ref share-remap 0) (array-ref share-remap 1))
              (= live-slots 2)
              (not (= (array-ref live-remap 0) (array-ref live-remap 1))))]
          [(CompilerRegColoring.None) false])]
      [(CompilerRegColoring.None) false])))

(cfg
  test
  (test
    regalloc-call-span-census
    (test.assert-i64-eq
      (compiler-regalloc-self-test)
      42
      "regalloc call-span census fixture result")))