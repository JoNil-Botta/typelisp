;; compiler_regalloc_tests.tl - Selfhost register-allocator fixtures split
;; from production (#5169).
;;
;; Only blocks gated on exactly `test` moved. The regalloc-census blocks and
;; the `(any regalloc-census test)` ones stay in the production module: they
;; compile into instrumentation builds, so they are not self-test code.
(import compiler_regalloc as reg)
(import compiler_abi as cabi)
(import compiler_liveness as live)
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(cfg test (import compiler_intern as ci))
(import stdlib.io)
(import stdlib.array)
(import stdlib.string)
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as reg_string_i64_map)
(import (hashmap.hashmap i64 i64) as reg_i64_i64_map)
(cfg test (import stdlib.test))

(define (compiler-reg-liveness-census-reset!) : unit
  (reg.compiler-reg-liveness-census-reset!))

(define (compiler-reg-liveness-census-baseline-count) : i64
  (reg.compiler-reg-liveness-census-baseline-count))

(define (compiler-reg-liveness-census-edge-precise-count) : i64
  (reg.compiler-reg-liveness-census-edge-precise-count))

(cfg
  test
  (define (compiler-reg-low-bit-index32-powers-ok? [bit : i64] [value : i64]) : bool
    (if (= bit 32)
      (and
        (= (reg.compiler-reg-low-bit-index32 0) 31)
        (= (reg.compiler-reg-low-bit-index32 0x100000000) 31))
      (and
        (= (reg.compiler-reg-low-bit-index32 value) bit)
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
                                (reg.compiler-reg-call-word-in-range?
                                  bits
                                  base
                                  start
                                  end)
                                (>
                                  (reg.compiler-reg-call-word-count-in-range
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
  [instr : ir.CompilerIrInstr]
  [allow-invariant-loads : bool]) : bool
  (match instr
    [(ir.CompilerIrInstr.Mov _ value _)
      (reg.compiler-reg-remat-mov-value? value allow-invariant-loads)]
    [(ir.CompilerIrInstr.Gep _ base offset _)
      (reg.compiler-reg-remat-gep? base offset)]
    [(ir.CompilerIrInstr.Load _ src _)
      (reg.compiler-reg-remat-load? src allow-invariant-loads)]
    [_ false]))

(define (compiler-reg-remat-defn? [instr : ir.CompilerIrInstr]) : bool
  (compiler-reg-remat-defn-with-invariant-loads? instr false))

(define (compiler-reg-function-ref-counts [func : ir.CompilerIrFunction]) : (__tl_dyn-array
    i64)
  (match func
    [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
      (let
        [counts : (__tl_dyn-array i64) (array.make-array i64 vars)]
        (begin
          (reg.compiler-reg-fill-i64-array counts 0)
          (reg.compiler-reg-ref-counts-blocks! counts blocks)
          counts))]))

(define (compiler-reg-function-spill-weights-remat
  [func : ir.CompilerIrFunction]
  [coalesce : reg.CompilerRegCoalesceMap]) : (__tl_dyn-array i64)
  (match func
    [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
      (let
        [counts : (__tl_dyn-array i64) (array.make-array i64 vars)]
        [def-status : (__tl_dyn-array i64) (array.make-array i64 vars)]
        [depths : (__tl_dyn-array i64)
          (reg.compiler-reg-function-loop-depths blocks)]
        [allow-invariant-loads : bool
          (reg.compiler-reg-remat-invariant-loads-ok? func)]
        (begin
          (reg.compiler-reg-fill-i64-array counts 0)
          (reg.compiler-reg-fill-i64-array def-status 0)
          (reg.compiler-reg-ref-counts-blocks-weighted-remat!
            counts
            def-status
            blocks
            depths
            0
            allow-invariant-loads)
          (reg.compiler-reg-remat-discount-single-def-spill-weights!
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
  [func : ir.CompilerIrFunction]
  [region-labels : reg.CompilerRegLabelSeq]
  [stack-var : i64]
  [region-var : i64]
  [ty : ast.AstType]) : reg.CompilerRegEdgeCopyPlan
  ;; Per-var (read-only / non-phi self-loop) planning: empty member set selects
  ;; the existing per-var liveness test in boundary-one (byte-identical).
  (reg.compiler-reg-edge-copy-plan-for-region-members
    func
    region-labels
    stack-var
    region-var
    ty
    (live.compiler-live-set-empty)))

;; Group-aware planning for the SplitKit phi-carried homing: `members` is the
;; coalesce group's bitset; boundary edges are tested against any-member liveness.
(define (compiler-reg-plan-function-avx2 [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
  (reg.compiler-reg-plan-function-avx2-for-abi
    cabi.CompilerRegTargetAbi.Linux
    func))

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
  (define (compiler-reg-early-exit-general-test-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "early_exit_general")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "n" (ast.AstType.I64) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "limit" (ast.AstType.I64) 1)
          ir.CompilerIrParamList.Nil))
      (ast.AstType.I64)
      5
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.BinOp
              2
              (ir.CompilerIrBinOp.Le)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.I64 0)
              (ast.AstType.I64))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Var 2)
                (ir.compiler-ir-label "zero")
                (ir.compiler-ir-label "guard_limit"))
              ir.CompilerIrInstrList.Nil)))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "zero")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.I64 0)))
              ir.CompilerIrInstrList.Nil))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "guard_limit")
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.BinOp
                  3
                  (ir.CompilerIrBinOp.Gt)
                  (ir.CompilerIrValue.Var 0)
                  (ir.CompilerIrValue.Var 1)
                  (ast.AstType.I64))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Branch
                    (ir.CompilerIrValue.Var 3)
                    (ir.compiler-ir-label "one")
                    (ir.compiler-ir-label "body"))
                  ir.CompilerIrInstrList.Nil)))
            (ir.compiler-ir-block-cons
              (ir.compiler-ir-block
                (ir.compiler-ir-label "one")
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.I64 1)))
                  ir.CompilerIrInstrList.Nil))
              (ir.compiler-ir-block-cons
                (ir.compiler-ir-block
                  (ir.compiler-ir-label "body")
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Call
                      4
                      (ir.compiler-ir-test-symbol "work")
                      ir.CompilerIrCallArgs.Nil
                      (ast.AstType.I64))
                    (ir.compiler-ir-instr-cons
                      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "entry"))
                      ir.CompilerIrInstrList.Nil)))
                ir.CompilerIrBlockList.Nil))))))))

(cfg
  test
  (define (compiler-reg-early-exit-general-ok?) : bool
    (match (reg.compiler-reg-early-exit-shrinkwrap-function
      (compiler-reg-early-exit-general-test-function))
      [(ir.CompilerIrFunction.Function _ params ret-ty _ blocks)
        (let
          [seq : ir.CompilerIrBlockSeq
            (live.compiler-live-ir-block-list-to-seq blocks)]
          [body : ir.CompilerIrInstrSeq
            (match (ir.compiler-ir-block-seq-ref seq 5)
              [(ir.CompilerIrBlock.Block _ instrs) instrs])]
          (and
            (= (ir.compiler-ir-param-list-count params) 2)
            (match ret-ty
              [(ast.AstType.I64) true]
              [_ false])
            (= (ir.compiler-ir-block-seq-count seq) 10)
            (= reg.compiler-reg-early-exit-prefix-count 4)
            (=
              reg.compiler-reg-early-exit-saving-label
              (ir.compiler-ir-label "entry__shrinkwrap_save"))
            (string.eq
              (reg.compiler-reg-early-exit-bare-label-current)
              "entry__shrinkwrap_bare")
            (match (ir.compiler-ir-block-seq-ref seq 0)
              [(ir.CompilerIrBlock.Block label instrs)
                (and
                  (= label (ir.compiler-ir-label "entry"))
                  (match (ir.compiler-ir-instr-seq-ref instrs 1)
                    [(ir.CompilerIrInstr.Branch _ yes no)
                      (and
                        (= yes (ir.compiler-ir-label "entry__shrinkwrap_bare0"))
                        (= no (ir.compiler-ir-label "guard_limit")))]
                    [_ false]))])
            (match (ir.compiler-ir-block-seq-ref seq 1)
              [(ir.CompilerIrBlock.Block label instrs)
                (and
                  (= label (ir.compiler-ir-label "guard_limit"))
                  (match (ir.compiler-ir-instr-seq-ref instrs 1)
                    [(ir.CompilerIrInstr.Branch _ yes no)
                      (and
                        (= yes (ir.compiler-ir-label "entry__shrinkwrap_bare1"))
                        (= no (ir.compiler-ir-label "entry__shrinkwrap_save")))]
                    [_ false]))])
            (match (ir.compiler-ir-instr-seq-ref body 1)
              [(ir.CompilerIrInstr.Jump target)
                (= target (ir.compiler-ir-label "entry__shrinkwrap_framed"))]
              [_ false])
            (match (ir.compiler-ir-block-seq-ref seq 7)
              [(ir.CompilerIrBlock.Block label _)
                (=
                  label
                  (ir.compiler-ir-label "guard_limit__shrinkwrap_framed"))])))])))

(cfg
  test
  (define (compiler-reg-early-exit-float-guard-test-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "early_exit_float_guard")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "actual" (ast.AstType.F64) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "expected" (ast.AstType.F64) 1)
          ir.CompilerIrParamList.Nil))
      (ast.AstType.Unit)
      4
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.BinOp
              2
              (ir.CompilerIrBinOp.Eq)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.Var 1)
              (ast.AstType.F64))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Var 2)
                (ir.compiler-ir-label "equal")
                (ir.compiler-ir-label "failure"))
              ir.CompilerIrInstrList.Nil)))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "equal")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
              ir.CompilerIrInstrList.Nil))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "failure")
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Call
                  3
                  (ir.compiler-ir-test-symbol "report_float_failure")
                  ir.CompilerIrCallArgs.Nil
                  (ast.AstType.Unit))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  ir.CompilerIrInstrList.Nil)))
            ir.CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-early-exit-float-guard-refused-ok?) : bool
    (match (reg.compiler-reg-early-exit-shrinkwrap-function
      (compiler-reg-early-exit-float-guard-test-function))
      [(ir.CompilerIrFunction.Function _ _ _ _ blocks)
        (and
          (=
            (ir.compiler-ir-block-seq-count
              (live.compiler-live-ir-block-list-to-seq blocks))
            3)
          (= reg.compiler-reg-early-exit-prefix-count 0)
          (not
            (ir.compiler-ir-label-some?
              reg.compiler-reg-early-exit-saving-label))
          (string.eq (reg.compiler-reg-early-exit-bare-label-current) ""))])))

(cfg
  test
  (define (compiler-reg-cold-call-test-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "cold_call_split")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "map" (reg.compiler-reg-i64-ty) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "key" (reg.compiler-reg-i64-ty) 1)
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "value" (reg.compiler-reg-i64-ty) 2)
            ir.CompilerIrParamList.Nil)))
      (ast.AstType.I64)
      6
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Branch
              (ir.CompilerIrValue.Bool false)
              (ir.compiler-ir-label "cold")
              (ir.compiler-ir-label "bypass"))
            ir.CompilerIrInstrList.Nil))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "cold")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Call
                3
                (ir.compiler-ir-test-symbol "grow")
                (ir.CompilerIrCallArgs.Nil)
                (ast.AstType.Unit))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "join"))
                ir.CompilerIrInstrList.Nil)))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "bypass")
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "join"))
                ir.CompilerIrInstrList.Nil))
            (ir.compiler-ir-block-cons
              (ir.compiler-ir-block
                (ir.compiler-ir-label "join")
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.BinOp
                    4
                    (ir.CompilerIrBinOp.Add)
                    (ir.CompilerIrValue.Var 0)
                    (ir.CompilerIrValue.Var 1)
                    (reg.compiler-reg-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.BinOp
                      5
                      (ir.CompilerIrBinOp.Add)
                      (ir.CompilerIrValue.Var 4)
                      (ir.CompilerIrValue.Var 2)
                      (reg.compiler-reg-i64-ty))
                    (ir.compiler-ir-instr-cons
                      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                      ir.CompilerIrInstrList.Nil))))
              (ir.compiler-ir-block-cons
                (ir.compiler-ir-block
                  (ir.compiler-ir-label "loop")
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Branch
                      (ir.CompilerIrValue.Bool false)
                      (ir.compiler-ir-label "loop")
                      (ir.compiler-ir-label "exit"))
                    ir.CompilerIrInstrList.Nil))
                (ir.compiler-ir-block-cons
                  (ir.compiler-ir-block
                    (ir.compiler-ir-label "exit")
                    (ir.compiler-ir-instr-cons
                      (ir.CompilerIrInstr.Return
                        (ir.CompilerIrMaybeValue.Some
                          (ir.CompilerIrValue.Var 5)))
                      ir.CompilerIrInstrList.Nil))
                  ir.CompilerIrBlockList.Nil)))))))))

(cfg
  test
  (define (compiler-reg-cold-call-test-mov?
    [instr : ir.CompilerIrInstr]
    [dst : i64]
    [src : i64]) : bool
    (match instr
      [(ir.CompilerIrInstr.Mov found-dst (ir.CompilerIrValue.Var found-src) _)
        (and (= found-dst dst) (= found-src src))]
      [_ false])))

(cfg
  test
  (define (compiler-reg-cold-call-split-ok?) : bool
    (let
      [rewrite : reg.CompilerRegColdCallRewrite
        (reg.compiler-reg-cold-call-rewrite-function
          (ast.ast-node-pool-reader-type-segment-bases)
          (compiler-reg-cold-call-test-function))]
      [rewritten : ir.CompilerIrFunction
        (reg.compiler-reg-cold-call-rewrite-function-value rewrite)]
      [temp-start : i64 (reg.compiler-reg-cold-call-rewrite-temp-start rewrite)]
      (match rewritten
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (let
            [seq : ir.CompilerIrBlockSeq
              (live.compiler-live-ir-block-list-to-seq blocks)]
            [instrs : ir.CompilerIrInstrSeq
              (match (ir.compiler-ir-block-seq-ref seq 1)
                [(ir.CompilerIrBlock.Block _ found) found])]
            [plan : reg.CompilerRegPlan
              (reg.compiler-reg-plan-function-scalar-cold-for-abi
                cabi.CompilerRegTargetAbi.Linux
                rewritten
                temp-start)]
            (and
              (= temp-start 6)
              (= vars 9)
              (= (ir.compiler-ir-instr-seq-count instrs) 8)
              (compiler-reg-cold-call-test-mov?
                (ir.compiler-ir-instr-seq-ref instrs 0)
                6
                0)
              (compiler-reg-cold-call-test-mov?
                (ir.compiler-ir-instr-seq-ref instrs 1)
                7
                1)
              (compiler-reg-cold-call-test-mov?
                (ir.compiler-ir-instr-seq-ref instrs 2)
                8
                2)
              (match (ir.compiler-ir-instr-seq-ref instrs 3)
                [(ir.CompilerIrInstr.Call _ _ _ _) true]
                [_ false])
              (compiler-reg-cold-call-test-mov?
                (ir.compiler-ir-instr-seq-ref instrs 4)
                0
                6)
              (compiler-reg-cold-call-test-mov?
                (ir.compiler-ir-instr-seq-ref instrs 5)
                1
                7)
              (compiler-reg-cold-call-test-mov?
                (ir.compiler-ir-instr-seq-ref instrs 6)
                2
                8)
              (match (ir.compiler-ir-instr-seq-ref instrs 7)
                [(ir.CompilerIrInstr.Jump target)
                  (= target (ir.compiler-ir-label "join"))]
                [_ false])
              (reg.compiler-reg-location-register?
                (match plan
                  [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
                    (reg.compiler-reg-assignment-lookup assignments 0)])
                cabi.compiler-reg-id-rdi)
              (reg.compiler-reg-location-register?
                (match plan
                  [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
                    (reg.compiler-reg-assignment-lookup assignments 1)])
                cabi.compiler-reg-id-rsi)
              (reg.compiler-reg-location-register?
                (match plan
                  [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
                    (reg.compiler-reg-assignment-lookup assignments 2)])
                cabi.compiler-reg-id-rdx)
              (reg.compiler-reg-cold-call-carriers-stack? plan temp-start vars)))]))))

;; Fast scalar backend plan: keep type discovery for emission decisions, but
;; leave values in their stack slots instead of spending compile time on liveness
;; and register assignment. AVX/vector backend modes still use full regalloc.
(cfg
  test
  (define (compiler-reg-param-register-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "param_registers")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (reg.compiler-reg-i64-ty) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "b" (reg.compiler-reg-i64-ty) 1)
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "c" (reg.compiler-reg-i64-ty) 2)
            ir.CompilerIrParamList.Nil)))
      (ast.AstType.Unit)
      3
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "pa")
              (ir.CompilerIrValue.Var 0)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "pb")
                (ir.CompilerIrValue.Var 1)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "pc")
                  (ir.CompilerIrValue.Var 2)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  ir.CompilerIrInstrList.Nil)))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-float-param-register-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "float_param_registers")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (reg.compiler-reg-f64-ty) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "b" (reg.compiler-reg-f64-ty) 1)
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "c" (reg.compiler-reg-f64-ty) 2)
            ir.CompilerIrParamList.Nil)))
      (ast.AstType.Unit)
      3
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "fa")
              (ir.CompilerIrValue.Var 0)
              (reg.compiler-reg-f64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "fb")
                (ir.CompilerIrValue.Var 1)
                (reg.compiler-reg-f64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "fc")
                  (ir.CompilerIrValue.Var 2)
                  (reg.compiler-reg-f64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  ir.CompilerIrInstrList.Nil)))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-low-xmm-splat-boundary-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "low_xmm_splat_boundary")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "value" (reg.compiler-reg-f64-ty) 0)
        ir.CompilerIrParamList.Nil)
      (ast.AstType.Unit)
      2
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Splat
              1
              (ir.CompilerIrValue.I64 7)
              4
              (ast.AstType.I64))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "low_xmm_splat_sink")
                (ir.CompilerIrValue.Var 0)
                (reg.compiler-reg-f64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                ir.CompilerIrInstrList.Nil))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-low-xmm-vector-clobber-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "low_xmm_vector_clobber")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "value" (reg.compiler-reg-f64-ty) 0)
        ir.CompilerIrParamList.Nil)
      (ast.AstType.Unit)
      4
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Splat
              1
              (ir.CompilerIrValue.I64 3)
              4
              (ast.AstType.I64))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Splat
                2
                (ir.CompilerIrValue.I64 5)
                4
                (ast.AstType.I64))
              (ir.compiler-ir-instr-cons
                (ir.ir-instr-vector-bin-op
                  3
                  (ir.CompilerIrBinOp.Mul)
                  (ir.CompilerIrValue.Var 1)
                  (ir.CompilerIrValue.Var 2)
                  4
                  (ast.AstType.I64))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "low_xmm_vector_sink")
                    (ir.CompilerIrValue.Var 0)
                    (reg.compiler-reg-f64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                    ir.CompilerIrInstrList.Nil))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-low-xmm-vector-boundaries-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar
      (compiler-reg-low-xmm-splat-boundary-function))
      [(reg.CompilerRegPlan.Plan splat-assignments _ _ _ _ _)
        (match (reg.compiler-reg-plan-function-scalar
          (compiler-reg-low-xmm-vector-clobber-function))
          [(reg.CompilerRegPlan.Plan clobber-assignments _ _ _ _ _)
            (and
              (cfg
                scratch-vreg
                (reg.compiler-reg-location-register?
                  (reg.compiler-reg-assignment-lookup splat-assignments 0)
                  (cabi.compiler-abi-xmm-register-id 0))
                (not
                  (reg.compiler-reg-location-any-register?
                    (reg.compiler-reg-assignment-lookup splat-assignments 0))))
              (not
                (reg.compiler-reg-location-register?
                  (reg.compiler-reg-assignment-lookup clobber-assignments 0)
                  (cabi.compiler-abi-xmm-register-id 0)))
              (not
                (reg.compiler-reg-location-register?
                  (reg.compiler-reg-assignment-lookup clobber-assignments 0)
                  (cabi.compiler-abi-xmm-register-id 1))))])])))

(cfg
  test
  (define (compiler-reg-mixed-float-call-arg-function) : ir.CompilerIrFunction
    (let
      [args : (__tl_dyn-array ir.CompilerIrValue)
        (array.make-array ir.CompilerIrValue 4)]
      (begin
        (array-set! args 0 (ir.CompilerIrValue.Var 0))
        (array-set! args 1 (ir.CompilerIrValue.Var 1))
        (array-set! args 2 (ir.CompilerIrValue.Var 2))
        (array-set! args 3 (ir.CompilerIrValue.Var 3))
        (ir.CompilerIrFunction.Function
          (ir.compiler-ir-test-symbol "mixed_float_call_args")
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "i" (reg.compiler-reg-i64-ty) 0)
            (ir.compiler-ir-param-cons
              (ir.CompilerIrParam.Param "a" (reg.compiler-reg-f64-ty) 1)
              (ir.compiler-ir-param-cons
                (ir.CompilerIrParam.Param "b" (reg.compiler-reg-f64-ty) 2)
                (ir.compiler-ir-param-cons
                  (ir.CompilerIrParam.Param "c" (reg.compiler-reg-f64-ty) 3)
                  ir.CompilerIrParamList.Nil))))
          (ast.AstType.Unit)
          5
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "entry")
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Call
                  4
                  (ir.compiler-ir-test-symbol "mixed_float_callee")
                  (ir.CompilerIrCallArgs.Array args)
                  (ast.AstType.Unit))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  ir.CompilerIrInstrList.Nil)))
            ir.CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-win64-rsi-rdi-pressure-function) : ir.CompilerIrFunction
    (let
      [instrs : ir.CompilerIrInstrList ir.CompilerIrInstrList.Nil]
      [params : ir.CompilerIrParamList ir.CompilerIrParamList.Nil]
      [i : i64 6]
      (begin
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
            instrs))
        (while (>= i 0)
          (begin
            (set!
              instrs
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "g")
                  (ir.CompilerIrValue.Var i)
                  (reg.compiler-reg-i64-ty))
                instrs))
            (set! i (- i 1))))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Call
              7
              (ir.compiler-ir-test-symbol "side_effect")
              (ir.CompilerIrCallArgs.Nil)
              (ast.AstType.Unit))
            instrs))
        (set! i 6)
        (while (>= i 0)
          (begin
            (set!
              params
              (ir.compiler-ir-param-cons
                (ir.CompilerIrParam.Param
                  (string.append "p" (string.int->string i))
                  (reg.compiler-reg-i64-ty)
                  i)
                params))
            (set! i (- i 1))))
        (ir.CompilerIrFunction.Function
          (ir.compiler-ir-test-symbol "win64_rsi_rdi_pressure")
          params
          (ast.AstType.Unit)
          8
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block (ir.compiler-ir-label "entry") instrs)
            ir.CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-zero-call-param-conflict-function) : ir.CompilerIrFunction
    (let
      [instrs : ir.CompilerIrInstrList ir.CompilerIrInstrList.Nil]
      (begin
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "p5")
              (ir.CompilerIrValue.Var 5)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g12")
              (ir.CompilerIrValue.Var 12)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g11")
              (ir.CompilerIrValue.Var 11)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g10")
              (ir.CompilerIrValue.Var 10)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g9")
              (ir.CompilerIrValue.Var 9)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g8")
              (ir.CompilerIrValue.Var 8)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g7")
              (ir.CompilerIrValue.Var 7)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g6")
              (ir.CompilerIrValue.Var 6)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              12
              (ir.CompilerIrValue.I64 12)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              11
              (ir.CompilerIrValue.I64 11)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              10
              (ir.CompilerIrValue.I64 10)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              9
              (ir.CompilerIrValue.I64 9)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              8
              (ir.CompilerIrValue.I64 8)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              7
              (ir.CompilerIrValue.I64 7)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              6
              (ir.CompilerIrValue.I64 6)
              (reg.compiler-reg-i64-ty))
            instrs))
        (ir.CompilerIrFunction.Function
          (ir.compiler-ir-test-symbol "zero_call_param_conflict")
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "a" (reg.compiler-reg-i64-ty) 0)
            (ir.compiler-ir-param-cons
              (ir.CompilerIrParam.Param "b" (reg.compiler-reg-i64-ty) 1)
              (ir.compiler-ir-param-cons
                (ir.CompilerIrParam.Param "c" (reg.compiler-reg-i64-ty) 2)
                (ir.compiler-ir-param-cons
                  (ir.CompilerIrParam.Param "d" (reg.compiler-reg-i64-ty) 3)
                  (ir.compiler-ir-param-cons
                    (ir.CompilerIrParam.Param "e" (reg.compiler-reg-i64-ty) 4)
                    (ir.compiler-ir-param-cons
                      (ir.CompilerIrParam.Param "f" (reg.compiler-reg-i64-ty) 5)
                      ir.CompilerIrParamList.Nil))))))
          (ast.AstType.Unit)
          13
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block (ir.compiler-ir-label "entry") instrs)
            ir.CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-param-clobber-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "param_clobber")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "arg" (reg.compiler-reg-i64-ty) 0)
        ir.CompilerIrParamList.Nil)
      (ast.AstType.I64)
      2
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Call
              1
              (ir.compiler-ir-test-symbol "side_effect")
              (ir.CompilerIrCallArgs.Nil)
              (ast.AstType.Unit))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
              ir.CompilerIrInstrList.Nil)))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-param-aggregate-function) : ir.CompilerIrFunction
    (let
      [ty : ast.AstType (ast.AstType.Struct (ci.intern "ParamAggregate"))]
      (ir.CompilerIrFunction.Function
        (ir.compiler-ir-test-symbol "param_aggregate")
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "state" ty 0)
          ir.CompilerIrParamList.Nil)
        (ast.AstType.Unit)
        2
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "entry")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Mov 1 (ir.CompilerIrValue.Var 0) ty)
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                ir.CompilerIrInstrList.Nil)))
          ir.CompilerIrBlockList.Nil)))))

(cfg
  test
  ;; GAP3a: zero-call function whose only would-be clobber is a shift by an
  ;; in-range CONSTANT (emitted as `shrq $3` -- no %rcx/%cl use). Params keep
  ;; their ABI pins.
  (define (compiler-reg-param-const-shift-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "param_const_shift")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (reg.compiler-reg-i64-ty) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "n" (reg.compiler-reg-i64-ty) 1)
          ir.CompilerIrParamList.Nil))
      (ast.AstType.I64)
      3
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.BinOp
              2
              (ir.CompilerIrBinOp.Shr (ast.AstType.I64))
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.I64 3)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.BinOp
                2
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.Var 2)
                (ir.CompilerIrValue.Var 1)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))
                ir.CompilerIrInstrList.Nil))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  ;; GAP3a counterpart: a VARIABLE-count shift stays a clobber point (the
  ;; backend moves the count into %rcx and shifts by %cl). `a` (var 0) is live
  ;; across the shift: t = a >> n; return t + a.
  (define (compiler-reg-param-var-shift-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "param_var_shift")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (reg.compiler-reg-i64-ty) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "n" (reg.compiler-reg-i64-ty) 1)
          ir.CompilerIrParamList.Nil))
      (ast.AstType.I64)
      3
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.BinOp
              2
              (ir.CompilerIrBinOp.Shr (ast.AstType.I64))
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.Var 1)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.BinOp
                2
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.Var 2)
                (ir.CompilerIrValue.Var 0)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 2)))
                ir.CompilerIrInstrList.Nil))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  ;; GAP3a: constant in-range shifts are not clobber points, so the pin gate
  ;; sees a clobber-free function and both params keep their incoming ABI
  ;; registers (%rdi/%rsi) -- the crc_update shape.
  (define (compiler-reg-scalar-param-const-shift-pin-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-const-shift-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (not (live.compiler-live-set-contains? ineligible 1))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rdi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            cabi.compiler-reg-id-rsi))])))

(cfg
  test
  ;; GAP3c: a variable-count shift clobbers only %rcx, so per-register pin
  ;; gating keeps BOTH pins here: a (%rdi) spans the shift but %rdi is not
  ;; shift-clobbered, and n (%rsi, the count) is last-used AT the shift so it
  ;; does not span it. (Pre-GAP3c the function-global gate revoked both ->
  ;; greedy CSR homes; the %rcx narrowing is asserted by
  ;; compiler-reg-scalar-param-rcx-shift-span-ok? below.)
  (define (compiler-reg-scalar-param-var-shift-pin-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-var-shift-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (not (live.compiler-live-set-contains? ineligible 1))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rdi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            cabi.compiler-reg-id-rsi))])))

(cfg
  test
  ;; GAP3c: params fully consumed BEFORE the first clobber point keep their
  ;; ABI pins even though the function has a call. t = a + a; call; return
  ;; t + t -- a (var 0) ends at point 0, the call is at point 2, so %rdi stays
  ;; pinned while the call-spanning t (var 1) takes a callee-saved home.
  (define (compiler-reg-param-dead-before-call-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "param_dead_before_call")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (reg.compiler-reg-i64-ty) 0)
        ir.CompilerIrParamList.Nil)
      (ast.AstType.I64)
      4
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.BinOp
              1
              (ir.CompilerIrBinOp.Add)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.Var 0)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Call
                2
                (ir.compiler-ir-test-symbol "side_effect")
                (ir.CompilerIrCallArgs.Nil)
                (ast.AstType.Unit))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.BinOp
                  3
                  (ir.CompilerIrBinOp.Add)
                  (ir.CompilerIrValue.Var 1)
                  (ir.CompilerIrValue.Var 1)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 3)))
                  ir.CompilerIrInstrList.Nil)))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-scalar-param-dead-before-call-pin-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-dead-before-call-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rdi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            cabi.compiler-reg-id-r12))])))

(cfg
  test
  ;; GAP3c div spanning: v3 = v0 + v0; v4 = v3 / v1; v5 = v4 + v2; return v5.
  ;; A div bans EVERY pin it is spanned by (%rax:%rdx hardwiring + the canned
  ;; divmod expansion's scratch hunger), so the %rdx param v2 -- live across
  ;; it (last use point 4) -- must NOT keep its pin (greedy CSR home instead),
  ;; while v0 (%rdi, ends point 0) and v1 (%rsi, the divisor, last-used AT
  ;; the div = read before the clobber) keep theirs.
  (define (compiler-reg-param-rdx-div-span-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "param_rdx_div_span")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (reg.compiler-reg-i64-ty) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "b" (reg.compiler-reg-i64-ty) 1)
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "c" (reg.compiler-reg-i64-ty) 2)
            ir.CompilerIrParamList.Nil)))
      (ast.AstType.I64)
      6
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.BinOp
              3
              (ir.CompilerIrBinOp.Add)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.Var 0)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.BinOp
                4
                (ir.CompilerIrBinOp.Div)
                (ir.CompilerIrValue.Var 3)
                (ir.CompilerIrValue.Var 1)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.BinOp
                  5
                  (ir.CompilerIrBinOp.Add)
                  (ir.CompilerIrValue.Var 4)
                  (ir.CompilerIrValue.Var 2)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 5)))
                  ir.CompilerIrInstrList.Nil)))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-scalar-param-rdx-div-span-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-rdx-div-span-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 2))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rdi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            cabi.compiler-reg-id-rsi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 2)
            cabi.compiler-reg-id-r12))])))

(cfg
  test
  ;; GAP3c per-register narrowing, shift: v4 = v0 + v0; v5 = v4 << v1;
  ;; v6 = v5 + v2; v7 = v6 + v3; return v7. The variable shift (point 2)
  ;; hardwires only %rcx, so the %rcx param v3 -- live across it (last use
  ;; point 6) -- must NOT keep its pin, while v2 (%rdx) ALSO spans the shift
  ;; and keeps its pin (%rdx is not shift-clobbered), and v0/v1 end at/before
  ;; the shift and keep theirs.
  (define (compiler-reg-param-rcx-shift-span-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "param_rcx_shift_span")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (reg.compiler-reg-i64-ty) 0)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "n" (reg.compiler-reg-i64-ty) 1)
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "c" (reg.compiler-reg-i64-ty) 2)
            (ir.compiler-ir-param-cons
              (ir.CompilerIrParam.Param "d" (reg.compiler-reg-i64-ty) 3)
              ir.CompilerIrParamList.Nil))))
      (ast.AstType.I64)
      8
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.BinOp
              4
              (ir.CompilerIrBinOp.Add)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.Var 0)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.BinOp
                5
                (ir.CompilerIrBinOp.Shl (ast.AstType.I64))
                (ir.CompilerIrValue.Var 4)
                (ir.CompilerIrValue.Var 1)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.BinOp
                  6
                  (ir.CompilerIrBinOp.Add)
                  (ir.CompilerIrValue.Var 5)
                  (ir.CompilerIrValue.Var 2)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.BinOp
                    7
                    (ir.CompilerIrBinOp.Add)
                    (ir.CompilerIrValue.Var 6)
                    (ir.CompilerIrValue.Var 3)
                    (reg.compiler-reg-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Return
                      (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 7)))
                    ir.CompilerIrInstrList.Nil))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-scalar-param-rcx-shift-span-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-rcx-shift-span-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 3))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rdi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            cabi.compiler-reg-id-rsi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 2)
            cabi.compiler-reg-id-rdx)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 3)
            cabi.compiler-reg-id-r12))])))

(cfg
  test
  ;; GAP3c coalesce-hull demotion (the soundness net for per-interval pins):
  ;; v3 = v0 + v0; Mov v1 <- v0 (v0's last use, boundary touch -> v1
  ;; disjoint-coalesces with the param); call; store v1. The walk pins v0 on
  ;; its own clobber-free interval [0,2], but the class {v0,v1} hull [0,6]
  ;; spans the call -- a kept pin would make the post-call store read a
  ;; clobbered %rdi. compiler-reg-param-pins-demote! must revoke the pin and
  ;; the class must land on ONE callee-saved home instead.
  (define (compiler-reg-param-pin-coalesce-demote-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "param_pin_coalesce_demote")
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "a" (reg.compiler-reg-i64-ty) 0)
        ir.CompilerIrParamList.Nil)
      (ast.AstType.Unit)
      4
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.BinOp
              3
              (ir.CompilerIrBinOp.Add)
              (ir.CompilerIrValue.Var 0)
              (ir.CompilerIrValue.Var 0)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.Var 0)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Call
                  2
                  (ir.compiler-ir-test-symbol "side_effect")
                  (ir.CompilerIrCallArgs.Nil)
                  (ast.AstType.Unit))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "g")
                    (ir.CompilerIrValue.Var 1)
                    (reg.compiler-reg-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                    ir.CompilerIrInstrList.Nil))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-scalar-param-pin-coalesce-demote-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-pin-coalesce-demote-function))
      [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
        (and
          (not
            (reg.compiler-reg-location-register?
              (reg.compiler-reg-assignment-lookup assignments 0)
              cabi.compiler-reg-id-rdi))
          (reg.compiler-reg-location-any-register?
            (reg.compiler-reg-assignment-lookup assignments 0))
          (reg.compiler-reg-same-location? assignments 0 1))])))

(define (compiler-reg-self-loop-exit-live-phi-mask-ok?) : bool
  (let
    [loop-first : ir.CompilerIrFunction
      (reg.compiler-reg-self-loop-exit-live-phi-function true)]
    [exit-first : ir.CompilerIrFunction
      (reg.compiler-reg-self-loop-exit-live-phi-function false)]
    [loop-first-mask : (__tl_dyn-array i64)
      (reg.compiler-reg-function-phi-touched-safe
        loop-first
        (live.compiler-live-analyze-function-edge-precise loop-first))]
    [exit-first-mask : (__tl_dyn-array i64)
      (reg.compiler-reg-function-phi-touched-safe
        exit-first
        (live.compiler-live-analyze-function-edge-precise exit-first))]
    [fixed-register-mask : (__tl_dyn-array i64)
      (reg.compiler-reg-function-phi-touched-safe-mode
        loop-first
        (live.compiler-live-analyze-function-edge-precise loop-first)
        false)]
    (and
      (reg.compiler-reg-self-loop-exit-live-phi-mask-shape-ok? loop-first-mask)
      (reg.compiler-reg-self-loop-exit-live-phi-mask-shape-ok? exit-first-mask)
      (= (array-ref fixed-register-mask 0) 0)
      (= (array-ref fixed-register-mask 3) 0))))

(cfg
  test
  (define (compiler-reg-indirect-call-arg-prefs-ok?) : bool
    (let
      [pool : reg.CompilerRegIdSeq
        (reg.compiler-reg-greedy-integer-pool-for-abi
          cabi.CompilerRegTargetAbi.Linux)]
      [prefs : (__tl_dyn-array i64)
        (reg.compiler-reg-function-arg-prefs
          cabi.CompilerRegTargetAbi.Linux
          (reg.compiler-reg-indirect-call-arg-function)
          (compiler-reg-test-identity-coalesce 4)
          4)]
      (and
        (= (array-ref prefs 0) -1)
        (=
          (array-ref prefs 1)
          (reg.compiler-reg-id-seq-index-of pool cabi.compiler-reg-id-rsi 0))
        (=
          (array-ref prefs 2)
          (reg.compiler-reg-id-seq-index-of pool cabi.compiler-reg-id-rdx 0))))))

(cfg
  test
  (define (compiler-reg-scalar-linux-param-registers-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-register-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (not (live.compiler-live-set-contains? ineligible 1))
          (not (live.compiler-live-set-contains? ineligible 2))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rdi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            cabi.compiler-reg-id-rsi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 2)
            cabi.compiler-reg-id-rdx))])))

(cfg
  test
  ;; Win64 zero-clobber pins: params 0/1 keep %rcx/%rdx. Param 2's incoming
  ;; register (%r8) is excluded from the legacy pin set, but M-A (RC1) makes it
  ;; a greedy candidate: it takes the first callee-saved home instead of being
  ;; stack-homed.
  (define (compiler-reg-scalar-windows-param-registers-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Windows
      (compiler-reg-param-register-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (not (live.compiler-live-set-contains? ineligible 1))
          (not (live.compiler-live-set-contains? ineligible 2))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rcx)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            cabi.compiler-reg-id-rdx)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 2)
            cabi.compiler-reg-id-r12))])))

(cfg
  test
  (define (compiler-reg-scalar-float-param-registers-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-float-param-register-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (not (live.compiler-live-set-contains? ineligible 1))
          (not (live.compiler-live-set-contains? ineligible 2))
          (cfg
            scratch-vreg
            (and
              (reg.compiler-reg-location-register?
                (reg.compiler-reg-assignment-lookup assignments 0)
                (cabi.compiler-abi-xmm-register-id 0))
              (reg.compiler-reg-location-register?
                (reg.compiler-reg-assignment-lookup assignments 1)
                (cabi.compiler-abi-xmm-register-id 1)))
            (and
              (not
                (reg.compiler-reg-location-any-register?
                  (reg.compiler-reg-assignment-lookup assignments 0)))
              (not
                (reg.compiler-reg-location-any-register?
                  (reg.compiler-reg-assignment-lookup assignments 1)))))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 2)
            (cabi.compiler-abi-xmm-register-id 2)))])))

(cfg
  test
  (define (compiler-reg-scalar-win64-float-param-registers-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Windows
      (compiler-reg-float-param-register-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (not (live.compiler-live-set-contains? ineligible 1))
          (not (live.compiler-live-set-contains? ineligible 2))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            (cfg
              scratch-vreg
              (cabi.compiler-abi-xmm-register-id 0)
              (cabi.compiler-abi-xmm-register-id 6)))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 1)
            (cfg
              scratch-vreg
              (cabi.compiler-abi-xmm-register-id 1)
              (cabi.compiler-abi-xmm-register-id 7)))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 2)
            (cabi.compiler-abi-xmm-register-id 2)))])))

(cfg
  test
  (define (compiler-reg-scalar-mixed-float-call-args-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-mixed-float-call-arg-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (live.compiler-live-set-contains? ineligible 0)
          (not (live.compiler-live-set-contains? ineligible 1))
          (not (live.compiler-live-set-contains? ineligible 2))
          (not (live.compiler-live-set-contains? ineligible 3))
          (reg.compiler-reg-unassigned? assignments 0)
          (cfg
            scratch-vreg
            (and
              (reg.compiler-reg-location-register?
                (reg.compiler-reg-assignment-lookup assignments 1)
                (cabi.compiler-abi-xmm-register-id 0))
              (reg.compiler-reg-location-register?
                (reg.compiler-reg-assignment-lookup assignments 2)
                (cabi.compiler-abi-xmm-register-id 1)))
            (and
              (reg.compiler-reg-unassigned? assignments 1)
              (reg.compiler-reg-unassigned? assignments 2)))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 3)
            (cabi.compiler-abi-xmm-register-id 2)))])))

(cfg
  test
  (define (compiler-reg-scalar-win64-mixed-float-call-args-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Windows
      (compiler-reg-mixed-float-call-arg-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (live.compiler-live-set-contains? ineligible 0)
          (not (live.compiler-live-set-contains? ineligible 1))
          (not (live.compiler-live-set-contains? ineligible 2))
          (not (live.compiler-live-set-contains? ineligible 3))
          (reg.compiler-reg-unassigned? assignments 0)
          (cfg
            scratch-vreg
            (reg.compiler-reg-location-register?
              (reg.compiler-reg-assignment-lookup assignments 1)
              (cabi.compiler-abi-xmm-register-id 1))
            (reg.compiler-reg-unassigned? assignments 1))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 2)
            (cabi.compiler-abi-xmm-register-id 2))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 3)
            (cabi.compiler-abi-xmm-register-id 3)))])))

(cfg
  test
  (define (compiler-reg-scalar-windows-rsi-rdi-pool-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Windows
      (compiler-reg-win64-rsi-rdi-pressure-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (not (live.compiler-live-set-contains? ineligible 6))
          (reg.compiler-reg-assignments-use-register?
            assignments
            cabi.compiler-reg-id-rsi)
          (reg.compiler-reg-assignments-use-register?
            assignments
            cabi.compiler-reg-id-rdi))])))

(cfg
  test
  (define (compiler-reg-test-identity-coalesce [n : i64]) : reg.CompilerRegCoalesceMap
    (let
      [parents : (__tl_dyn-array i64) (array.make-array i64 n)]
      [sizes : (__tl_dyn-array i64) (array.make-array i64 n)]
      (begin
        (reg.compiler-reg-coalesce-map-init! parents sizes 0)
        (reg.CompilerRegCoalesceMap parents)))))

(cfg
  test
  (define (compiler-reg-win64-arg-result-pref-function) : ir.CompilerIrFunction
    (let
      [args : (__tl_dyn-array ir.CompilerIrValue)
        (array.make-array ir.CompilerIrValue 5)]
      (begin
        (array-set! args 0 (ir.CompilerIrValue.Var 0))
        (array-set! args 1 (ir.CompilerIrValue.Var 1))
        (array-set! args 2 (ir.CompilerIrValue.Var 2))
        (array-set! args 3 (ir.CompilerIrValue.Var 3))
        (array-set! args 4 (ir.CompilerIrValue.Var 4))
        (ir.CompilerIrFunction.Function
          (ir.compiler-ir-test-symbol "win64_arg_result_pref")
          ir.CompilerIrParamList.Nil
          (ast.AstType.I64)
          6
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "entry")
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Call
                  5
                  (ir.compiler-ir-test-symbol "callee")
                  (ir.CompilerIrCallArgs.Array args)
                  (ast.AstType.I64))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 5)))
                  ir.CompilerIrInstrList.Nil)))
            ir.CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-win64-arg-result-prefs-ok?) : bool
    (let
      [pool : reg.CompilerRegIdSeq
        (reg.compiler-reg-greedy-integer-pool-for-abi
          cabi.CompilerRegTargetAbi.Windows)]
      [prefs : (__tl_dyn-array i64)
        (reg.compiler-reg-function-arg-prefs
          cabi.CompilerRegTargetAbi.Windows
          (compiler-reg-win64-arg-result-pref-function)
          (compiler-reg-test-identity-coalesce 6)
          6)]
      (and
        (=
          (array-ref prefs 0)
          (reg.compiler-reg-id-seq-index-of pool cabi.compiler-reg-id-rcx 0))
        (=
          (array-ref prefs 1)
          (reg.compiler-reg-id-seq-index-of pool cabi.compiler-reg-id-rdx 0))
        (=
          (array-ref prefs 2)
          (reg.compiler-reg-id-seq-index-of pool cabi.compiler-reg-id-r8 0))
        (=
          (array-ref prefs 3)
          (reg.compiler-reg-id-seq-index-of pool cabi.compiler-reg-id-r9 0))
        (= (array-ref prefs 4) -1)
        (=
          (array-ref prefs 5)
          (reg.compiler-reg-id-seq-index-of pool cabi.compiler-reg-id-rax 0))))))

(cfg
  test
  ;; M-A (RC1): a clobber-point function no longer stack-homes its params. The
  ;; scalar param cannot keep its ABI pin (the call clobbers %rdi) but becomes
  ;; an ordinary greedy candidate restricted to callee-saved homes: it wins the
  ;; first callee-saved register and is copied there once at entry instead of
  ;; being reloaded from the stack at every use.
  (define (compiler-reg-scalar-param-clobber-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-clobber-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-r12))])))

(cfg
  test
  ;; GAP3b: an aggregate-HANDLE param (8-byte struct descriptor) is
  ;; pin-eligible exactly like a scalar (integer-param-type? widened to
  ;; register-eligible), so in this zero-clobber function it keeps its
  ;; incoming %rdi instead of the M-A-era greedy callee-saved home.
  (define (compiler-reg-scalar-aggregate-param-pinned-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-param-aggregate-function))
      [(reg.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
        (and
          (not (live.compiler-live-set-contains? ineligible 0))
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 0)
            cabi.compiler-reg-id-rdi))])))

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
    (match (reg.compiler-reg-plan-function-scalar-for-abi
      cabi.CompilerRegTargetAbi.Linux
      (compiler-reg-zero-call-param-conflict-function))
      [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
        (and
          (= (reg.compiler-reg-spill-count assignments) 0)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 5)
            cabi.compiler-reg-id-r9)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 6)
            cabi.compiler-reg-id-rax)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 7)
            cabi.compiler-reg-id-rsi)
          (reg.compiler-reg-location-register?
            (reg.compiler-reg-assignment-lookup assignments 8)
            cabi.compiler-reg-id-rdi))])))

(cfg
  test
  (define (compiler-reg-remat-weight-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_weight")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      2
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.BinOp
                1
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.I64 1)
                (ir.CompilerIrValue.I64 2)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "use1")
                  (ir.CompilerIrValue.Var 1)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "use0a")
                    (ir.CompilerIrValue.Var 0)
                    (reg.compiler-reg-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Store
                      (ir.compiler-ir-test-symbol "use0b")
                      (ir.CompilerIrValue.Var 0)
                      (reg.compiler-reg-i64-ty))
                    (ir.compiler-ir-instr-cons
                      (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                      ir.CompilerIrInstrList.Nil)))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-multi-def-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_multi_def")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      1
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.BinOp
                0
                (ir.CompilerIrBinOp.Add)
                (ir.CompilerIrValue.I64 1)
                (ir.CompilerIrValue.I64 2)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                ir.CompilerIrInstrList.Nil))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-classifier-ok?) : bool
    (and
      (compiler-reg-remat-defn?
        (ir.CompilerIrInstr.Mov
          10
          (ir.CompilerIrValue.I64 1)
          (reg.compiler-reg-i64-ty)))
      (compiler-reg-remat-defn?
        (ir.CompilerIrInstr.Mov
          11
          (ir.CompilerIrValue.Bool true)
          (ast.AstType.Bool)))
      (compiler-reg-remat-defn?
        (ir.CompilerIrInstr.Mov
          12
          (ir.CompilerIrValue.Char 'x')
          (ast.AstType.Char)))
      (compiler-reg-remat-defn?
        (ir.CompilerIrInstr.Mov
          13
          (ir.CompilerIrValue.F64 0x3ff0000000000000)
          (reg.compiler-reg-f64-ty)))
      (compiler-reg-remat-defn?
        (ir.CompilerIrInstr.Mov
          14
          (ir.CompilerIrValue.GlobalAddr (ir.compiler-ir-test-symbol "global"))
          (ast.AstType.U64)))
      (not
        (compiler-reg-remat-defn?
          (ir.CompilerIrInstr.Mov
            15
            (ir.CompilerIrValue.Global (ir.compiler-ir-test-symbol "global"))
            (reg.compiler-reg-i64-ty))))
      (compiler-reg-remat-defn-with-invariant-loads?
        (ir.CompilerIrInstr.Mov
          16
          (ir.CompilerIrValue.Global (ir.compiler-ir-test-symbol "global"))
          (reg.compiler-reg-i64-ty))
        true)
      (compiler-reg-remat-defn?
        (ir.CompilerIrInstr.Gep
          17
          (ir.CompilerIrValue.GlobalAddr (ir.compiler-ir-test-symbol "global"))
          (ir.CompilerIrValue.I64 2)
          (reg.compiler-reg-i64-ty)))
      (not
        (compiler-reg-remat-defn?
          (ir.CompilerIrInstr.Gep
            18
            (ir.CompilerIrValue.GlobalAddr
              (ir.compiler-ir-test-symbol "global"))
            (ir.CompilerIrValue.Var 0)
            (reg.compiler-reg-i64-ty))))
      (not
        (compiler-reg-remat-defn?
          (ir.CompilerIrInstr.Gep
            19
            (ir.CompilerIrValue.Var 0)
            (ir.CompilerIrValue.I64 2)
            (reg.compiler-reg-i64-ty))))
      (not
        (compiler-reg-remat-defn?
          (ir.CompilerIrInstr.Load
            20
            (ir.CompilerIrValue.GlobalAddr
              (ir.compiler-ir-test-symbol "global"))
            (reg.compiler-reg-i64-ty))))
      (compiler-reg-remat-defn-with-invariant-loads?
        (ir.CompilerIrInstr.Load
          21
          (ir.CompilerIrValue.GlobalAddr (ir.compiler-ir-test-symbol "global"))
          (reg.compiler-reg-i64-ty))
        true)
      (not
        (compiler-reg-remat-defn-with-invariant-loads?
          (ir.CompilerIrInstr.Load
            22
            (ir.CompilerIrValue.Var 0)
            (reg.compiler-reg-i64-ty))
          true))
      (not
        (compiler-reg-remat-defn?
          (ir.CompilerIrInstr.Mov
            23
            (ir.CompilerIrValue.Var 0)
            (reg.compiler-reg-i64-ty))))
      (not
        (compiler-reg-remat-defn?
          (ir.CompilerIrInstr.Mov
            24
            (ir.CompilerIrValue.String "heap")
            (ast.AstType.String))))
      (not
        (compiler-reg-remat-defn?
          (ir.CompilerIrInstr.BinOp
            25
            (ir.CompilerIrBinOp.Add)
            (ir.CompilerIrValue.I64 1)
            (ir.CompilerIrValue.I64 2)
            (reg.compiler-reg-i64-ty)))))))

(cfg
  test
  (define (compiler-reg-remat-discount-weights-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-remat-weight-function)]
      [empty-coalesce : reg.CompilerRegCoalesceMap
        (reg.CompilerRegCoalesceMap (array.make-array i64 0))]
      [raw : (__tl_dyn-array i64)
        (reg.compiler-reg-function-spill-weights func)]
      [discounted : (__tl_dyn-array i64)
        (compiler-reg-function-spill-weights-remat func empty-coalesce)]
      [multi-raw : (__tl_dyn-array i64)
        (reg.compiler-reg-function-spill-weights
          (compiler-reg-remat-multi-def-function))]
      [multi-discounted : (__tl_dyn-array i64)
        (compiler-reg-function-spill-weights-remat
          (compiler-reg-remat-multi-def-function)
          empty-coalesce)]
      [parents : (__tl_dyn-array i64) (array.make-array i64 2)]
      (begin
        (array-set! parents 0 0)
        (array-set! parents 1 0)
        (let
          [coalesced : (__tl_dyn-array i64)
            (compiler-reg-function-spill-weights-remat
              func
              (reg.CompilerRegCoalesceMap parents))]
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
  (define (compiler-reg-remat-spill-weight-eviction-function) : ir.CompilerIrFunction
    (let
      [instrs : ir.CompilerIrInstrList ir.CompilerIrInstrList.Nil]
      (begin
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "hot0b")
              (ir.CompilerIrValue.Var 0)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "hot0a")
              (ir.CompilerIrValue.Var 0)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "cold1")
              (ir.CompilerIrValue.Var 1)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use5")
              (ir.CompilerIrValue.Var 5)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use4")
              (ir.CompilerIrValue.Var 4)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use3")
              (ir.CompilerIrValue.Var 3)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use2")
              (ir.CompilerIrValue.Var 2)
              (reg.compiler-reg-i64-ty))
            instrs))
        ;; #perf: syscall after the uses so every value crosses it (call-spanning)
        ;; -- the partition gates off and the 6 candidates oversubscribe the 5
        ;; callee-saved registers. var1 is the only non-remat value, so the remat
        ;; discount keeps it in a register and a rematerialisable value is the
        ;; victim; among the remat values the cheapest (1-use var5, one recompute)
        ;; is spilled rather than the 2-use var0 (two recomputes).
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Syscall
              6
              (ir.CompilerIrCallArgs.One (ir.CompilerIrValue.I64 39)))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              5
              (ir.CompilerIrValue.I64 5)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              4
              (ir.CompilerIrValue.I64 4)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              3
              (ir.CompilerIrValue.I64 3)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              2
              (ir.CompilerIrValue.I64 2)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.BinOp
              1
              (ir.CompilerIrBinOp.Add)
              (ir.CompilerIrValue.I64 1)
              (ir.CompilerIrValue.I64 2)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 0)
              (reg.compiler-reg-i64-ty))
            instrs))
        (ir.CompilerIrFunction.Function
          (ir.compiler-ir-test-symbol "remat_spill_weight_eviction")
          ir.CompilerIrParamList.Nil
          (ast.AstType.Unit)
          7
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block (ir.compiler-ir-label "entry") instrs)
            ir.CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-remat-spill-weight-eviction-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-remat-spill-weight-eviction-function)]
      [empty-coalesce : reg.CompilerRegCoalesceMap
        (reg.CompilerRegCoalesceMap (array.make-array i64 0))]
      [raw : (__tl_dyn-array i64)
        (reg.compiler-reg-function-spill-weights func)]
      [discounted : (__tl_dyn-array i64)
        (compiler-reg-function-spill-weights-remat func empty-coalesce)]
      (match (reg.compiler-reg-plan-function-scalar func)
        [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
          (and
            (> (array-ref raw 0) (array-ref raw 1))
            (< (array-ref discounted 0) (array-ref discounted 1))
            ;; The non-remat var1 is KEPT in a register: the remat discount ranks
            ;; the rematerialisable values (var0, var2-5) below it, so a remat
            ;; value -- never the costly-to-spill non-remat one -- is the victim.
            (reg.compiler-reg-location-any-register?
              (reg.compiler-reg-assignment-lookup assignments 1))
            ;; Among the remat values the GREEDY spills the genuinely cheapest:
            ;; var0 has 2 uses (spilling it costs 2 recomputes) while var5 has 1
            ;; use (1 recompute), so var0 is KEPT and the 1-use var5 is the victim.
            ;; The combined discounted+raw priority key breaks the discount's
            ;; use-count collapse by raw use density, spilling the least-used
            ;; rematerialisable value rather than the most-used one.
            (reg.compiler-reg-location-any-register?
              (reg.compiler-reg-assignment-lookup assignments 0))
            (reg.compiler-reg-location-spill-offset?
              (reg.compiler-reg-assignment-lookup assignments 5)
              (reg.compiler-reg-stack-slot-offset 5)))]))))

(cfg
  test
  (define (compiler-reg-spill-weight-eviction-function) : ir.CompilerIrFunction
    ;; #perf: every value crosses the syscall (call-spanning), so the call-
    ;; spanning-aware partition is gated off and the 6 candidates genuinely
    ;; oversubscribe the 5 callee-saved registers. var0 is hot (3 uses), vars 2-5
    ;; are medium (2 uses), var1 is the unique coldest (1 use) and is the
    ;; spill-weight eviction victim.
    (let
      [instrs : ir.CompilerIrInstrList ir.CompilerIrInstrList.Nil]
      (begin
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "hot0c")
              (ir.CompilerIrValue.Var 0)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "hot0b")
              (ir.CompilerIrValue.Var 0)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "hot0a")
              (ir.CompilerIrValue.Var 0)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "cold1")
              (ir.CompilerIrValue.Var 1)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use5b")
              (ir.CompilerIrValue.Var 5)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use5a")
              (ir.CompilerIrValue.Var 5)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use4b")
              (ir.CompilerIrValue.Var 4)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use4a")
              (ir.CompilerIrValue.Var 4)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use3b")
              (ir.CompilerIrValue.Var 3)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use3a")
              (ir.CompilerIrValue.Var 3)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use2b")
              (ir.CompilerIrValue.Var 2)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "use2a")
              (ir.CompilerIrValue.Var 2)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Syscall
              6
              (ir.CompilerIrCallArgs.One (ir.CompilerIrValue.I64 39)))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              5
              (ir.CompilerIrValue.I64 5)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              4
              (ir.CompilerIrValue.I64 4)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              3
              (ir.CompilerIrValue.I64 3)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              2
              (ir.CompilerIrValue.I64 2)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              1
              (ir.CompilerIrValue.I64 1)
              (reg.compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 0)
              (reg.compiler-reg-i64-ty))
            instrs))
        (ir.CompilerIrFunction.Function
          (ir.compiler-ir-test-symbol "spill_weight_eviction")
          ir.CompilerIrParamList.Nil
          (ast.AstType.Unit)
          7
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block (ir.compiler-ir-label "entry") instrs)
            ir.CompilerIrBlockList.Nil))))))

(cfg
  test
  (define (compiler-reg-spill-weight-eviction-ok?) : bool
    (match (reg.compiler-reg-plan-function-scalar
      (compiler-reg-spill-weight-eviction-function))
      [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
        (and
          (reg.compiler-reg-location-any-register?
            (reg.compiler-reg-assignment-lookup assignments 0))
          (reg.compiler-reg-location-spill-offset?
            (reg.compiler-reg-assignment-lookup assignments 1)
            (reg.compiler-reg-stack-slot-offset 1))
          (reg.compiler-reg-location-any-register?
            (reg.compiler-reg-assignment-lookup assignments 5)))])))

(cfg
  test
  (define (compiler-reg-loop-spill-weight-eviction-function) : ir.CompilerIrFunction
    ;; #perf: all six values cross the entry syscall (call-spanning) so the
    ;; partition gates off. var0 and vars 2-5 are used inside the loop (loop-depth
    ;; weighted) while var1 is the single cold exit value -- the unique
    ;; spill-weight eviction victim despite var0/var1 sharing one static use each.
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "loop_spill_weight_eviction")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      7
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 0)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.I64 1)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Mov
                  2
                  (ir.CompilerIrValue.I64 2)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Mov
                    3
                    (ir.CompilerIrValue.I64 3)
                    (reg.compiler-reg-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Mov
                      4
                      (ir.CompilerIrValue.I64 4)
                      (reg.compiler-reg-i64-ty))
                    (ir.compiler-ir-instr-cons
                      (ir.CompilerIrInstr.Mov
                        5
                        (ir.CompilerIrValue.I64 5)
                        (reg.compiler-reg-i64-ty))
                      (ir.compiler-ir-instr-cons
                        (ir.CompilerIrInstr.Syscall
                          6
                          (ir.CompilerIrCallArgs.One
                            (ir.CompilerIrValue.I64 39)))
                        (ir.compiler-ir-instr-cons
                          (ir.CompilerIrInstr.Jump
                            (ir.compiler-ir-label "loop"))
                          ir.CompilerIrInstrList.Nil)))))))))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "loop")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "hot0")
                (ir.CompilerIrValue.Var 0)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "hot2")
                  (ir.CompilerIrValue.Var 2)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "hot3")
                    (ir.CompilerIrValue.Var 3)
                    (reg.compiler-reg-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Store
                      (ir.compiler-ir-test-symbol "hot4")
                      (ir.CompilerIrValue.Var 4)
                      (reg.compiler-reg-i64-ty))
                    (ir.compiler-ir-instr-cons
                      (ir.CompilerIrInstr.Store
                        (ir.compiler-ir-test-symbol "hot5")
                        (ir.CompilerIrValue.Var 5)
                        (reg.compiler-reg-i64-ty))
                      (ir.compiler-ir-instr-cons
                        (ir.CompilerIrInstr.Branch
                          (ir.CompilerIrValue.Bool false)
                          (ir.compiler-ir-label "body")
                          (ir.compiler-ir-label "exit"))
                        ir.CompilerIrInstrList.Nil)))))))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "body")
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                ir.CompilerIrInstrList.Nil))
            (ir.compiler-ir-block-cons
              (ir.compiler-ir-block
                (ir.compiler-ir-label "exit")
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "cold1")
                    (ir.CompilerIrValue.Var 1)
                    (reg.compiler-reg-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                    ir.CompilerIrInstrList.Nil)))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-loop-spill-weight-eviction-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-loop-spill-weight-eviction-function)]
      [static-counts : (__tl_dyn-array i64)
        (compiler-reg-function-ref-counts func)]
      [weighted-counts : (__tl_dyn-array i64)
        (reg.compiler-reg-function-spill-weights func)]
      (match (reg.compiler-reg-plan-function-scalar func)
        [(reg.CompilerRegPlan.Plan assignments _ _ _ _ _)
          (and
            (= (array-ref static-counts 0) (array-ref static-counts 1))
            (> (array-ref weighted-counts 0) (array-ref weighted-counts 1))
            (reg.compiler-reg-location-any-register?
              (reg.compiler-reg-assignment-lookup assignments 0))
            (reg.compiler-reg-location-spill-offset?
              (reg.compiler-reg-assignment-lookup assignments 1)
              (reg.compiler-reg-stack-slot-offset 1))
            (reg.compiler-reg-location-any-register?
              (reg.compiler-reg-assignment-lookup assignments 5)))]))))

(cfg
  test
  (define (compiler-reg-instr-list-has-mov-i64?
    [instrs : ir.CompilerIrInstrList]
    [dst : i64]
    [value : i64]) : bool
    (match instrs
      [(ir.CompilerIrInstrList.Nil) false]
      [(ir.CompilerIrInstrList.Cons instr rest)
        (match instr
          [(ir.CompilerIrInstr.Mov found-dst found-value _)
            (match found-value
              [(ir.CompilerIrValue.I64 found)
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
    [instrs : ir.CompilerIrInstrList]
    [dst : i64]
    [src : i64]) : bool
    (match instrs
      [(ir.CompilerIrInstrList.Nil) false]
      [(ir.CompilerIrInstrList.Cons instr rest)
        (match instr
          [(ir.CompilerIrInstr.Mov found-dst found-value _)
            (match found-value
              [(ir.CompilerIrValue.Var found-src)
                (if (and (= found-dst dst) (= found-src src))
                  true
                  (compiler-reg-instr-list-has-mov-var? (box-get rest) dst src))]
              [_ (compiler-reg-instr-list-has-mov-var? (box-get rest) dst src)])]
          [_ (compiler-reg-instr-list-has-mov-var? (box-get rest) dst src)])])))

(cfg
  test
  (define (compiler-reg-instr-list-has-mov-global?
    [instrs : ir.CompilerIrInstrList]
    [dst : i64]
    [name : String]) : bool
    (match instrs
      [(ir.CompilerIrInstrList.Nil) false]
      [(ir.CompilerIrInstrList.Cons instr rest)
        (match instr
          [(ir.CompilerIrInstr.Mov found-dst found-value _)
            (match found-value
              [(ir.CompilerIrValue.Global found-name)
                (if (and
                  (= found-dst dst)
                  (string.eq (ir.compiler-ir-symbol-text found-name) name))
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
    [instrs : ir.CompilerIrInstrList]
    [dst : i64]
    [name : String]) : bool
    (match instrs
      [(ir.CompilerIrInstrList.Nil) false]
      [(ir.CompilerIrInstrList.Cons instr rest)
        (match instr
          [(ir.CompilerIrInstr.Load found-dst found-src _)
            (match found-src
              [(ir.CompilerIrValue.GlobalAddr found-name)
                (if (and
                  (= found-dst dst)
                  (string.eq (ir.compiler-ir-symbol-text found-name) name))
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
    [instrs : ir.CompilerIrInstrList]
    [dst : i64]
    [name : String]
    [offset : i64]
    [ty : ast.AstType]) : bool
    (match instrs
      [(ir.CompilerIrInstrList.Nil) false]
      [(ir.CompilerIrInstrList.Cons instr rest)
        (match instr
          [(ir.CompilerIrInstr.Gep found-dst found-base found-offset found-ty)
            (match found-base
              [(ir.CompilerIrValue.GlobalAddr found-name)
                (match found-offset
                  [(ir.CompilerIrValue.I64 found-offset-value)
                    (if (and
                      (= found-dst dst)
                      (and
                        (string.eq (ir.compiler-ir-symbol-text found-name) name)
                        (and
                          (= found-offset-value offset)
                          (ast.ast-type-eq? found-ty ty))))
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
    [instrs : ir.CompilerIrInstrList]
    [name : String]
    [src : i64]) : bool
    (match instrs
      [(ir.CompilerIrInstrList.Nil) false]
      [(ir.CompilerIrInstrList.Cons instr rest)
        (match instr
          [(ir.CompilerIrInstr.Store found-name found-value _)
            (match found-value
              [(ir.CompilerIrValue.Var found-src)
                (if (and
                  (string.eq (ir.compiler-ir-symbol-text found-name) name)
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
    [instrs : ir.CompilerIrInstrList]
    [dst : i64]
    [src : i64]) : bool
    (match instrs
      [(ir.CompilerIrInstrList.Nil) false]
      [(ir.CompilerIrInstrList.Cons instr rest)
        (match instr
          [(ir.CompilerIrInstr.AddrOf found-dst found-src)
            (if (and (= found-dst dst) (= found-src src))
              true
              (compiler-reg-instr-list-has-addr-of? (box-get rest) dst src))]
          [_ (compiler-reg-instr-list-has-addr-of? (box-get rest) dst src)])])))

(cfg
  test
  (define (compiler-reg-instr-list-has-call-indirect-var?
    [instrs : ir.CompilerIrInstrList]
    [callee : i64]) : bool
    (match instrs
      [(ir.CompilerIrInstrList.Nil) false]
      [(ir.CompilerIrInstrList.Cons instr rest)
        (match instr
          [(ir.CompilerIrInstr.CallIndirect _ found-callee _ _)
            (match found-callee
              [(ir.CompilerIrValue.Var found)
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
    [instrs : ir.CompilerIrInstrList]
    [src : i64]) : bool
    (match instrs
      [(ir.CompilerIrInstrList.Nil) false]
      [(ir.CompilerIrInstrList.Cons instr rest)
        (match instr
          [(ir.CompilerIrInstr.Return maybe)
            (match maybe
              [(ir.CompilerIrMaybeValue.Some value)
                (match value
                  [(ir.CompilerIrValue.Var found)
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
    [blocks : ir.CompilerIrBlockList]
    [want-label : i64]) : ir.CompilerIrInstrList
    (match blocks
      [(ir.CompilerIrBlockList.Cons block rest)
        (match block
          [(ir.CompilerIrBlock.Block label instrs)
            (if (= label want-label)
              (ir.compiler-ir-instr-seq-to-list instrs)
              (compiler-reg-block-instr-list (box-get rest) want-label))])]
      [(ir.CompilerIrBlockList.Array seq)
        (let
          [i : i64 0]
          [count : i64 (ir.compiler-ir-block-seq-count seq)]
          [out : ir.CompilerIrInstrList ir.CompilerIrInstrList.Nil]
          [found : bool false]
          (begin
            (while (and (< i count) (not found))
              (begin
                (match (ir.compiler-ir-block-seq-ref seq i)
                  [(ir.CompilerIrBlock.Block label instrs)
                    (if (= label want-label)
                      (begin
                        (set! out (ir.compiler-ir-instr-seq-to-list instrs))
                        (set! found true))
                      unit)])
                (set! i (+ i 1))))
            out))]
      [_ ir.CompilerIrInstrList.Nil])))

(cfg
  test
  (define (compiler-reg-remat-rewrite-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_rewrite")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      1
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "use0a")
                (ir.CompilerIrValue.Var 0)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "use0b")
                  (ir.CompilerIrValue.Var 0)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  ir.CompilerIrInstrList.Nil)))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-conflict-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_conflict")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      2
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.I64 9)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "use0")
                  (ir.CompilerIrValue.Var 0)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "keep1")
                    (ir.CompilerIrValue.Var 1)
                    (reg.compiler-reg-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                    ir.CompilerIrInstrList.Nil))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-caller-clobber-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_caller_clobber")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      2
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.GlobalAddr
                (ir.compiler-ir-test-symbol "callee"))
              (ast.AstType.U64))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.CallIndirect
                1
                (ir.CompilerIrValue.Var 0)
                ir.CompilerIrCallArgs.Nil
                (ast.AstType.Unit))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                ir.CompilerIrInstrList.Nil))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-addr-of-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_addr_of")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      2
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.AddrOf 1 0)
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "addr")
                  (ir.CompilerIrValue.Var 1)
                  (reg.compiler-reg-addr-of-result-type))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  ir.CompilerIrInstrList.Nil)))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-global-mov-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_global_mov")
      ir.CompilerIrParamList.Nil
      (reg.compiler-reg-i64-ty)
      1
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.Global
                (ir.compiler-ir-test-symbol "global_value"))
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
              ir.CompilerIrInstrList.Nil)))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-global-load-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_global_load")
      ir.CompilerIrParamList.Nil
      (reg.compiler-reg-i64-ty)
      1
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Load
              0
              (ir.CompilerIrValue.GlobalAddr
                (ir.compiler-ir-test-symbol "global_value"))
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
              ir.CompilerIrInstrList.Nil)))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-global-gep-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_global_gep")
      ir.CompilerIrParamList.Nil
      (reg.compiler-reg-addr-of-result-type)
      1
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Gep
              0
              (ir.CompilerIrValue.GlobalAddr
                (ir.compiler-ir-test-symbol "global_value"))
              (ir.CompilerIrValue.I64 3)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
              ir.CompilerIrInstrList.Nil)))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-global-mutating-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "remat_global_mutating")
      ir.CompilerIrParamList.Nil
      (reg.compiler-reg-i64-ty)
      1
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.Global
                (ir.compiler-ir-test-symbol "global_value"))
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "global_value")
                (ir.CompilerIrValue.I64 1)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                ir.CompilerIrInstrList.Nil))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-remat-single-spill-plan [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
    (reg.CompilerRegPlan.Plan
      (reg.compiler-reg-assignment-cons
        (reg.CompilerRegAssignment
          0
          (reg.CompilerRegLocation.Spill (reg.compiler-reg-stack-slot-offset 0)))
        reg.CompilerRegAssignmentList.Nil)
      (live.compiler-live-set-empty)
      (reg.compiler-reg-interval-seq-empty)
      (reg.compiler-reg-function-var-types func)
      (reg.compiler-reg-call-split-empty)
      (reg.compiler-reg-split-plan-empty))))

(cfg
  test
  (define (compiler-reg-remat-conflict-plan [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
    (reg.CompilerRegPlan.Plan
      (reg.compiler-reg-assignment-cons
        (reg.CompilerRegAssignment
          0
          (reg.CompilerRegLocation.Spill (reg.compiler-reg-stack-slot-offset 0)))
        (reg.compiler-reg-assignment-cons
          (reg.CompilerRegAssignment
            1
            (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r9))
          reg.CompilerRegAssignmentList.Nil))
      (live.compiler-live-set-empty)
      (reg.compiler-reg-interval-seq-empty)
      (reg.compiler-reg-function-var-types func)
      (reg.compiler-reg-call-split-empty)
      (reg.compiler-reg-split-plan-empty))))

(cfg
  test
  (define (compiler-reg-remat-rewrite-shape-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-remat-rewrite-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-remat-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                extra-types)
              (let
                [items : ir.CompilerIrInstrList
                  (compiler-reg-block-instr-list
                    rewritten
                    (ir.compiler-ir-label "entry"))]
                [rewritten-plan : reg.CompilerRegPlan
                  (reg.compiler-reg-plan-with-call-save-rewrite
                    plan
                    (reg.CompilerRegCallSaveRewrite.Rewrite
                      rewritten
                      vars
                      out-vars
                      extra-assignments
                      extra-types))]
                [rewritten-assignments : reg.CompilerRegAssignmentList
                  (reg.compiler-reg-plan-assignments rewritten-plan)]
                [rewritten-types : reg.CompilerRegVarTypes
                  (reg.compiler-reg-plan-types rewritten-plan)]
                (and
                  (= out-vars (+ vars 2))
                  (= (reg.compiler-reg-assignment-count extra-assignments) 2)
                  (reg.compiler-reg-location-register?
                    (reg.compiler-reg-assignment-lookup
                      rewritten-assignments
                      vars)
                    cabi.compiler-reg-id-r9)
                  (reg.compiler-reg-location-register?
                    (reg.compiler-reg-assignment-lookup
                      rewritten-assignments
                      (+ vars 1))
                    cabi.compiler-reg-id-r9)
                  (compiler-reg-instr-list-has-mov-i64? items vars 7)
                  (compiler-reg-instr-list-has-mov-i64? items (+ vars 1) 7)
                  (compiler-reg-instr-list-has-store-var? items "use0a" vars)
                  (compiler-reg-instr-list-has-store-var?
                    items
                    "use0b"
                    (+ vars 1))
                  (match (reg.compiler-reg-var-types-lookup
                    rewritten-types
                    vars)
                    [(reg.CompilerRegMaybeType.Some ty)
                      (match ty
                        [(ast.AstType.I64) true]
                        [_ false])]
                    [(reg.CompilerRegMaybeType.No) false])
                  (match (reg.compiler-reg-var-types-lookup
                    rewritten-types
                    (+ vars 1))
                    [(reg.CompilerRegMaybeType.Some ty)
                      (match ty
                        [(ast.AstType.I64) true]
                        [_ false])]
                    [(reg.CompilerRegMaybeType.No) false])
                  (not (compiler-reg-instr-list-has-store-var? items "use0a" 0))
                  (not (compiler-reg-instr-list-has-store-var? items "use0b" 0))))])]))))

(cfg
  test
  (define (compiler-reg-remat-register-conflict-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-remat-conflict-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-remat-conflict-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-remat-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : ir.CompilerIrInstrList
                  (compiler-reg-block-instr-list
                    rewritten
                    (ir.compiler-ir-label "entry"))]
                (and
                  (= out-vars vars)
                  (= (reg.compiler-reg-assignment-count extra-assignments) 0)
                  (compiler-reg-instr-list-has-store-var? items "use0" 0)))])]))))

(cfg
  test
  (define (compiler-reg-remat-caller-clobber-refusal-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-remat-caller-clobber-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-remat-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : ir.CompilerIrInstrList
                  (compiler-reg-block-instr-list
                    rewritten
                    (ir.compiler-ir-label "entry"))]
                (and
                  (= out-vars vars)
                  (= (reg.compiler-reg-assignment-count extra-assignments) 0)
                  (compiler-reg-instr-list-has-call-indirect-var? items 0)))])]))))

(cfg
  test
  (define (compiler-reg-remat-addr-of-source-refusal-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-remat-addr-of-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-remat-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : ir.CompilerIrInstrList
                  (compiler-reg-block-instr-list
                    rewritten
                    (ir.compiler-ir-label "entry"))]
                (and
                  (= out-vars vars)
                  (= (reg.compiler-reg-assignment-count extra-assignments) 0)
                  (compiler-reg-instr-list-has-addr-of? items 1 0)
                  (not (compiler-reg-instr-list-has-addr-of? items 1 vars))))])]))))

(cfg
  test
  (define (compiler-reg-remat-global-mov-rewrite-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-remat-global-mov-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-remat-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : ir.CompilerIrInstrList
                  (compiler-reg-block-instr-list
                    rewritten
                    (ir.compiler-ir-label "entry"))]
                (and
                  (= out-vars (+ vars 1))
                  (= (reg.compiler-reg-assignment-count extra-assignments) 1)
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
      [func : ir.CompilerIrFunction (compiler-reg-remat-global-load-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-remat-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : ir.CompilerIrInstrList
                  (compiler-reg-block-instr-list
                    rewritten
                    (ir.compiler-ir-label "entry"))]
                (and
                  (= out-vars (+ vars 1))
                  (= (reg.compiler-reg-assignment-count extra-assignments) 1)
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
      [func : ir.CompilerIrFunction (compiler-reg-remat-global-gep-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-remat-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : ir.CompilerIrInstrList
                  (compiler-reg-block-instr-list
                    rewritten
                    (ir.compiler-ir-label "entry"))]
                (and
                  (= out-vars (+ vars 1))
                  (= (reg.compiler-reg-assignment-count extra-assignments) 1)
                  (compiler-reg-instr-list-has-gep-global-i64?
                    items
                    vars
                    "global_value"
                    3
                    (reg.compiler-reg-i64-ty))
                  (compiler-reg-instr-list-has-return-var? items vars)
                  (not (compiler-reg-instr-list-has-return-var? items 0))))])]))))

(cfg
  test
  (define (compiler-reg-remat-global-mutation-refusal-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-remat-global-mutating-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-remat-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : ir.CompilerIrInstrList
                  (compiler-reg-block-instr-list
                    rewritten
                    (ir.compiler-ir-label "entry"))]
                (and
                  (= out-vars vars)
                  (= (reg.compiler-reg-assignment-count extra-assignments) 0)
                  (compiler-reg-instr-list-has-return-var? items 0)
                  (not
                    (compiler-reg-instr-list-has-mov-global?
                      items
                      vars
                      "global_value"))))])]))))

(cfg
  test
  (define (compiler-reg-call-spanning-post-call-stores
    [tail : ir.CompilerIrInstrList]) : ir.CompilerIrInstrList
    (ir.compiler-ir-instr-cons
      (ir.CompilerIrInstr.Store
        (ir.compiler-ir-test-symbol "g0")
        (ir.CompilerIrValue.Var 0)
        (reg.compiler-reg-i64-ty))
      (ir.compiler-ir-instr-cons
        (ir.CompilerIrInstr.Store
          (ir.compiler-ir-test-symbol "g1")
          (ir.CompilerIrValue.Var 1)
          (reg.compiler-reg-i64-ty))
        (ir.compiler-ir-instr-cons
          (ir.CompilerIrInstr.Store
            (ir.compiler-ir-test-symbol "g2")
            (ir.CompilerIrValue.Var 2)
            (reg.compiler-reg-i64-ty))
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Store
              (ir.compiler-ir-test-symbol "g3")
              (ir.CompilerIrValue.Var 3)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Store
                (ir.compiler-ir-test-symbol "g4")
                (ir.CompilerIrValue.Var 4)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "g5")
                  (ir.CompilerIrValue.Var 5)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "g6")
                    (ir.CompilerIrValue.Var 6)
                    (reg.compiler-reg-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Store
                      (ir.compiler-ir-test-symbol "g5b")
                      (ir.CompilerIrValue.Var 5)
                      (reg.compiler-reg-i64-ty))
                    (ir.compiler-ir-instr-cons
                      (ir.CompilerIrInstr.Store
                        (ir.compiler-ir-test-symbol "g5c")
                        (ir.CompilerIrValue.Var 5)
                        (reg.compiler-reg-i64-ty))
                      tail)))))))))))

(cfg
  test
  (define (compiler-reg-call-spanning-defs-before
    [tail : ir.CompilerIrInstrList]) : ir.CompilerIrInstrList
    (ir.compiler-ir-instr-cons
      (ir.CompilerIrInstr.Mov
        0
        (ir.CompilerIrValue.I64 0)
        (reg.compiler-reg-i64-ty))
      (ir.compiler-ir-instr-cons
        (ir.CompilerIrInstr.Mov
          1
          (ir.CompilerIrValue.I64 1)
          (reg.compiler-reg-i64-ty))
        (ir.compiler-ir-instr-cons
          (ir.CompilerIrInstr.Mov
            2
            (ir.CompilerIrValue.I64 2)
            (reg.compiler-reg-i64-ty))
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              3
              (ir.CompilerIrValue.I64 3)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Mov
                4
                (ir.CompilerIrValue.I64 4)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Mov
                  5
                  (ir.CompilerIrValue.I64 5)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Mov
                    6
                    (ir.CompilerIrValue.I64 6)
                    (reg.compiler-reg-i64-ty))
                  tail)))))))))

(cfg
  test
  (define (compiler-reg-call-spanning-call-before
    [tail : ir.CompilerIrInstrList]) : ir.CompilerIrInstrList
    (ir.compiler-ir-instr-cons
      (ir.CompilerIrInstr.Call
        7
        (ir.compiler-ir-test-symbol "side_effect")
        (ir.CompilerIrCallArgs.Nil)
        (ast.AstType.Unit))
      tail)))

(cfg
  test
  (define (compiler-reg-call-spanning-multiblock-local-function) : ir.CompilerIrFunction
    (let
      [body-tail : ir.CompilerIrInstrList
        (ir.compiler-ir-instr-cons
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "exit"))
          ir.CompilerIrInstrList.Nil)]
      [body : ir.CompilerIrInstrList
        (compiler-reg-call-spanning-defs-before
          (compiler-reg-call-spanning-call-before
            (compiler-reg-call-spanning-post-call-stores body-tail)))]
      (ir.CompilerIrFunction.Function
        (ir.compiler-ir-test-symbol "call_spanning_multiblock_local")
        ir.CompilerIrParamList.Nil
        (ast.AstType.Unit)
        8
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "entry")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "body"))
              ir.CompilerIrInstrList.Nil))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block (ir.compiler-ir-label "body") body)
            (ir.compiler-ir-block-cons
              (ir.compiler-ir-block
                (ir.compiler-ir-label "exit")
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  ir.CompilerIrInstrList.Nil))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-call-spanning-multiblock-boundary-function) : ir.CompilerIrFunction
    (let
      [entry : ir.CompilerIrInstrList
        (compiler-reg-call-spanning-defs-before
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "body"))
            ir.CompilerIrInstrList.Nil))]
      [body-tail : ir.CompilerIrInstrList
        (ir.compiler-ir-instr-cons
          (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "exit"))
          ir.CompilerIrInstrList.Nil)]
      [body : ir.CompilerIrInstrList
        (compiler-reg-call-spanning-call-before
          (compiler-reg-call-spanning-post-call-stores body-tail))]
      (ir.CompilerIrFunction.Function
        (ir.compiler-ir-test-symbol "call_spanning_multiblock_boundary")
        ir.CompilerIrParamList.Nil
        (ast.AstType.Unit)
        8
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block (ir.compiler-ir-label "entry") entry)
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block (ir.compiler-ir-label "body") body)
            (ir.compiler-ir-block-cons
              (ir.compiler-ir-block
                (ir.compiler-ir-label "exit")
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)
                  ir.CompilerIrInstrList.Nil))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-scalar-call-spanning-multiblock-local-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-call-spanning-multiblock-local-function)]
      [plan : reg.CompilerRegPlan (reg.compiler-reg-plan-function-scalar func)]
      (match plan
        [(reg.CompilerRegPlan.Plan assignments _ _ _ split-vars _)
          (and
            ;; Same capacity story as the single-block fixture: the greedy
            ;; register-homes the hot call-spanning value (spill-weight priority)
            ;; and spills the single-use overflow (var 6) without a save/restore
            ;; rescue.
            (= (reg.compiler-reg-spill-count assignments) 2)
            (reg.compiler-reg-location-spill-offset?
              (reg.compiler-reg-assignment-lookup assignments 6)
              (reg.compiler-reg-stack-slot-offset 6))
            (not
              (live.compiler-live-set-contains?
                (reg.compiler-reg-call-split-shadows split-vars)
                5))
            (not
              (live.compiler-live-set-contains?
                (reg.compiler-reg-call-split-shadows split-vars)
                6)))]))))

(cfg
  test
  (define (compiler-reg-scalar-call-spanning-multiblock-boundary-ok?) : bool
    (let
      [plan : reg.CompilerRegPlan
        (reg.compiler-reg-plan-function-scalar
          (compiler-reg-call-spanning-multiblock-boundary-function))]
      (match plan
        [(reg.CompilerRegPlan.Plan _ _ _ _ split-vars _)
          (and
            (not
              (live.compiler-live-set-contains?
                (reg.compiler-reg-call-split-shadows split-vars)
                5))
            (not
              (live.compiler-live-set-contains?
                (reg.compiler-reg-call-split-shadows split-vars)
                6)))]))))

(cfg
  test
  (define (compiler-reg-edge-copy-list-has?
    [copies : reg.CompilerRegEdgeCopySeq]
    [from-label : i64]
    [to-label : i64]
    [src : i64]
    [dst : i64]
    [want-pred-end : bool]) : bool
    (let
      [slots : (__tl_dyn-array reg.CompilerRegEdgeCopy)
        (struct-get copies slots)]
      [count : i64 (struct-get copies len)]
      [index : i64 0]
      [found : bool false]
      (begin
        (while (and (< index count) (not found))
          (begin
            (match (array-ref slots index)
              [(reg.CompilerRegEdgeCopy.Copy
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
                    [(reg.CompilerRegEdgeCopyPlacement.PredEnd) want-pred-end]
                    [(reg.CompilerRegEdgeCopyPlacement.SuccEntry)
                      (not want-pred-end)]))
                  (set! found true)
                  unit)])
            (set! index (+ index 1))))
        found))))

(cfg
  test
  (define (compiler-reg-edge-copy-linear-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "edge_copy_linear")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      1
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "hot"))
              ir.CompilerIrInstrList.Nil)))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "hot")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
              ir.CompilerIrInstrList.Nil))
          ir.CompilerIrBlockList.Nil)))))

(cfg
  test
  (define (compiler-reg-edge-copy-linear-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-edge-copy-linear-function)]
      [region : reg.CompilerRegLabelSeq
        (reg.compiler-reg-label-seq-prepend
          (ir.compiler-ir-label "hot")
          (reg.compiler-reg-label-seq-empty))]
      (match (compiler-reg-edge-copy-plan-for-region
        func
        region
        0
        10
        (reg.compiler-reg-i64-ty))
        [(reg.CompilerRegEdgeCopyPlan.Plan copies)
          (and
            (= (reg.compiler-reg-edge-copy-list-count copies) 1)
            (compiler-reg-edge-copy-list-has?
              copies
              (ir.compiler-ir-label "entry")
              (ir.compiler-ir-label "hot")
              0
              10
              true)
            (match func
              [(ir.CompilerIrFunction.Function _ _ _ _ blocks)
                (match (reg.compiler-reg-edge-copy-apply blocks copies)
                  [(reg.CompilerRegEdgeCopyRewrite.Rewrite rewritten)
                    (compiler-reg-instr-list-has-mov-var?
                      (compiler-reg-block-instr-list
                        rewritten
                        (ir.compiler-ir-label "entry"))
                      10
                      0)]
                  [(reg.CompilerRegEdgeCopyRewrite.Refused _) false])]))]
        [(reg.CompilerRegEdgeCopyPlan.Refused _) false]))))

(cfg
  test
  (define (compiler-reg-edge-copy-backedge-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "edge_copy_backedge")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      1
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
              ir.CompilerIrInstrList.Nil)))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "loop")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool false)
                (ir.compiler-ir-label "body")
                (ir.compiler-ir-label "exit"))
              ir.CompilerIrInstrList.Nil))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "body")
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "sink")
                  (ir.CompilerIrValue.Var 0)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                  ir.CompilerIrInstrList.Nil)))
            (ir.compiler-ir-block-cons
              (ir.compiler-ir-block
                (ir.compiler-ir-label "exit")
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                  ir.CompilerIrInstrList.Nil))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-edge-copy-backedge-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-edge-copy-backedge-function)]
      [region : reg.CompilerRegLabelSeq
        (reg.compiler-reg-label-seq-prepend
          (ir.compiler-ir-label "body")
          (reg.compiler-reg-label-seq-empty))]
      (match (compiler-reg-edge-copy-plan-for-region
        func
        region
        0
        10
        (reg.compiler-reg-i64-ty))
        [(reg.CompilerRegEdgeCopyPlan.Plan copies)
          (and
            (= (reg.compiler-reg-edge-copy-list-count copies) 2)
            (compiler-reg-edge-copy-list-has?
              copies
              (ir.compiler-ir-label "loop")
              (ir.compiler-ir-label "body")
              0
              10
              false)
            (compiler-reg-edge-copy-list-has?
              copies
              (ir.compiler-ir-label "body")
              (ir.compiler-ir-label "loop")
              10
              0
              true)
            (match func
              [(ir.CompilerIrFunction.Function _ _ _ _ blocks)
                (match (reg.compiler-reg-edge-copy-apply blocks copies)
                  [(reg.CompilerRegEdgeCopyRewrite.Rewrite rewritten)
                    (let
                      [body : ir.CompilerIrInstrList
                        (compiler-reg-block-instr-list
                          rewritten
                          (ir.compiler-ir-label "body"))]
                      (and
                        (compiler-reg-instr-list-has-mov-var? body 10 0)
                        (compiler-reg-instr-list-has-mov-var? body 0 10)))]
                  [(reg.CompilerRegEdgeCopyRewrite.Refused _) false])]))]
        [(reg.CompilerRegEdgeCopyPlan.Refused _) false]))))

(cfg
  test
  (define (compiler-reg-edge-copy-critical-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "edge_copy_critical")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      1
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool false)
                (ir.compiler-ir-label "hot")
                (ir.compiler-ir-label "cold"))
              ir.CompilerIrInstrList.Nil)))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "other")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "hot"))
              ir.CompilerIrInstrList.Nil))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "hot")
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                ir.CompilerIrInstrList.Nil))
            (ir.compiler-ir-block-cons
              (ir.compiler-ir-block
                (ir.compiler-ir-label "cold")
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.I64 0)))
                  ir.CompilerIrInstrList.Nil))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-edge-copy-critical-refusal-ok?) : bool
    (let
      [region : reg.CompilerRegLabelSeq
        (reg.compiler-reg-label-seq-prepend
          (ir.compiler-ir-label "hot")
          (reg.compiler-reg-label-seq-empty))]
      (match (compiler-reg-edge-copy-plan-for-region
        (compiler-reg-edge-copy-critical-function)
        region
        0
        10
        (reg.compiler-reg-i64-ty))
        [(reg.CompilerRegEdgeCopyPlan.Plan _) false]
        [(reg.CompilerRegEdgeCopyPlan.Refused _) true]))))

(cfg
  test
  (define (compiler-reg-loop-split-plan [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
    (let
      [type-info : reg.CompilerRegVarTypes
        (reg.compiler-reg-function-var-types func)]
      [liveness : live.CompilerFunctionLiveness
        (live.compiler-live-analyze-function func)]
      (match (reg.compiler-reg-live-interval-selection func liveness)
        [(reg.CompilerRegIntervalSelection.Selection intervals _)
          (reg.CompilerRegPlan.Plan
            (reg.compiler-reg-assignment-cons
              (reg.CompilerRegAssignment
                0
                (reg.CompilerRegLocation.Spill
                  (reg.compiler-reg-stack-slot-offset 0)))
              reg.CompilerRegAssignmentList.Nil)
            (live.compiler-live-set-empty)
            intervals
            type-info
            (reg.compiler-reg-call-split-empty)
            (reg.compiler-reg-split-plan-empty))]))))

(cfg
  test
  (define (compiler-reg-loop-split-two-plan [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
    (let
      [type-info : reg.CompilerRegVarTypes
        (reg.compiler-reg-function-var-types func)]
      [liveness : live.CompilerFunctionLiveness
        (live.compiler-live-analyze-function func)]
      (match (reg.compiler-reg-live-interval-selection func liveness)
        [(reg.CompilerRegIntervalSelection.Selection intervals _)
          (reg.CompilerRegPlan.Plan
            (reg.compiler-reg-assignment-cons
              (reg.CompilerRegAssignment
                0
                (reg.CompilerRegLocation.Spill
                  (reg.compiler-reg-stack-slot-offset 0)))
              (reg.compiler-reg-assignment-cons
                (reg.CompilerRegAssignment
                  1
                  (reg.CompilerRegLocation.Spill
                    (reg.compiler-reg-stack-slot-offset 1)))
                reg.CompilerRegAssignmentList.Nil))
            (live.compiler-live-set-empty)
            intervals
            type-info
            (reg.compiler-reg-call-split-empty)
            (reg.compiler-reg-split-plan-empty))]))))

(cfg
  test
  (define (compiler-reg-leaf-csr-split-plan [func : ir.CompilerIrFunction]) : reg.CompilerRegPlan
    (let
      [type-info : reg.CompilerRegVarTypes
        (reg.compiler-reg-function-var-types func)]
      [liveness : live.CompilerFunctionLiveness
        (live.compiler-live-analyze-function func)]
      (match (reg.compiler-reg-live-interval-selection func liveness)
        [(reg.CompilerRegIntervalSelection.Selection intervals _)
          (reg.CompilerRegPlan.Plan
            (reg.compiler-reg-assignment-cons
              (reg.CompilerRegAssignment
                0
                (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))
              (reg.compiler-reg-assignment-cons
                (reg.CompilerRegAssignment
                  1
                  (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r8))
                reg.CompilerRegAssignmentList.Nil))
            (live.compiler-live-set-empty)
            intervals
            type-info
            (reg.compiler-reg-call-split-empty)
            (reg.compiler-reg-split-plan-empty))]))))

(cfg
  test
  (define (compiler-reg-leaf-csr-split-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "leaf_csr_split")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      2
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
              ir.CompilerIrInstrList.Nil)))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "loop")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.BinOp
                1
                (ir.CompilerIrBinOp.Eq)
                (ir.CompilerIrValue.Var 0)
                (ir.CompilerIrValue.I64 7)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Branch
                  (ir.CompilerIrValue.Var 1)
                  (ir.compiler-ir-label "body")
                  (ir.compiler-ir-label "exit"))
                ir.CompilerIrInstrList.Nil)))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "body")
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "hot0")
                  (ir.CompilerIrValue.Var 0)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "hot1")
                    (ir.CompilerIrValue.Var 0)
                    (reg.compiler-reg-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                    ir.CompilerIrInstrList.Nil))))
            (ir.compiler-ir-block-cons
              (ir.compiler-ir-block
                (ir.compiler-ir-label "exit")
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.I64 0)))
                  ir.CompilerIrInstrList.Nil))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-leaf-csr-split-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-leaf-csr-split-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-leaf-csr-split-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (let
            [rewrite : reg.CompilerRegCallSaveRewrite
              (reg.compiler-reg-leaf-csr-split-rewrite-one
                (ast.ast-node-pool-reader-type-segment-bases)
                cabi.CompilerRegTargetAbi.Linux
                func
                blocks
                vars
                (reg.compiler-reg-function-var-types func)
                plan)]
            (match rewrite
              [(reg.CompilerRegCallSaveRewrite.Rewrite
                  rewritten
                  _
                  out-vars
                  extra-assignments
                  _)
                (let
                  [rewritten-func : ir.CompilerIrFunction
                    (ir.CompilerIrFunction.Function
                      (ir.compiler-ir-test-symbol "leaf_csr_split")
                      ir.CompilerIrParamList.Nil
                      (ast.AstType.I64)
                      out-vars
                      rewritten)]
                  [rewritten-types : reg.CompilerRegVarTypes
                    (reg.compiler-reg-function-var-types rewritten-func)]
                  [raw-plan : reg.CompilerRegPlan
                    (reg.compiler-reg-plan-function-scalar-cold-with-type-segment-bases-for-abi-with-types-and-preassignments
                      (ast.ast-node-pool-reader-type-segment-bases)
                      cabi.CompilerRegTargetAbi.Linux
                      rewritten-func
                      (- 0 1)
                      rewritten-types
                      extra-assignments)]
                  [rewritten-plan : reg.CompilerRegPlan
                    (reg.compiler-reg-plan-hide-leaf-csr-phantoms
                      raw-plan
                      extra-assignments
                      vars)]
                  [assignments : reg.CompilerRegAssignmentList
                    (reg.compiler-reg-plan-assignments rewritten-plan)]
                  [body : ir.CompilerIrInstrList
                    (compiler-reg-block-instr-list
                      rewritten
                      (ir.compiler-ir-label "body"))]
                  (and
                    (= out-vars (+ vars 2))
                    (= (reg.compiler-reg-assignment-count extra-assignments) 2)
                    (reg.compiler-reg-leaf-csr-fuse-safe? func 1)
                    (not
                      (reg.compiler-reg-assignments-use-register?
                        assignments
                        cabi.compiler-reg-id-r12))
                    (not
                      (reg.compiler-reg-location-any-register?
                        (reg.compiler-reg-assignment-lookup assignments 0)))
                    (reg.compiler-reg-location-any-register?
                      (reg.compiler-reg-assignment-lookup assignments vars))
                    (reg.compiler-reg-location-any-register?
                      (reg.compiler-reg-assignment-lookup
                        assignments
                        (+ vars 1)))
                    (not
                      (reg.compiler-reg-same-location?
                        assignments
                        vars
                        (+ vars 1)))
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
  (define (compiler-reg-loop-split-rewrite-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "loop_split_rewrite")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      1
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
              ir.CompilerIrInstrList.Nil)))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "loop")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool false)
                (ir.compiler-ir-label "body")
                (ir.compiler-ir-label "exit"))
              ir.CompilerIrInstrList.Nil))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "body")
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "hot0")
                  (ir.CompilerIrValue.Var 0)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "hot1")
                    (ir.CompilerIrValue.Var 0)
                    (reg.compiler-reg-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                    ir.CompilerIrInstrList.Nil))))
            (ir.compiler-ir-block-cons
              (ir.compiler-ir-block
                (ir.compiler-ir-label "exit")
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                  ir.CompilerIrInstrList.Nil))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-loop-split-two-rewrite-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "loop_split_two_rewrite")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      2
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.I64 11)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                ir.CompilerIrInstrList.Nil))))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "loop")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool false)
                (ir.compiler-ir-label "body")
                (ir.compiler-ir-label "exit"))
              ir.CompilerIrInstrList.Nil))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "body")
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "hot0")
                  (ir.CompilerIrValue.Var 0)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "hot1")
                    (ir.CompilerIrValue.Var 1)
                    (reg.compiler-reg-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Store
                      (ir.compiler-ir-test-symbol "hot2")
                      (ir.CompilerIrValue.Var 0)
                      (reg.compiler-reg-i64-ty))
                    (ir.compiler-ir-instr-cons
                      (ir.CompilerIrInstr.Store
                        (ir.compiler-ir-test-symbol "hot3")
                        (ir.CompilerIrValue.Var 1)
                        (reg.compiler-reg-i64-ty))
                      (ir.compiler-ir-instr-cons
                        (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                        ir.CompilerIrInstrList.Nil))))))
            (ir.compiler-ir-block-cons
              (ir.compiler-ir-block
                (ir.compiler-ir-label "exit")
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                  ir.CompilerIrInstrList.Nil))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-loop-split-low-benefit-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "loop_split_low_benefit")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      1
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
              ir.CompilerIrInstrList.Nil)))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "loop")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool false)
                (ir.compiler-ir-label "body")
                (ir.compiler-ir-label "exit"))
              ir.CompilerIrInstrList.Nil))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "body")
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Store
                  (ir.compiler-ir-test-symbol "hot0")
                  (ir.CompilerIrValue.Var 0)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                  ir.CompilerIrInstrList.Nil)))
            (ir.compiler-ir-block-cons
              (ir.compiler-ir-block
                (ir.compiler-ir-label "exit")
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                  ir.CompilerIrInstrList.Nil))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-loop-split-phi-region-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "loop_split_phi_region")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      2
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
              ir.CompilerIrInstrList.Nil)))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "loop")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Bool false)
                (ir.compiler-ir-label "body")
                (ir.compiler-ir-label "exit"))
              ir.CompilerIrInstrList.Nil))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "body")
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Phi
                  1
                  (ir.compiler-ir-phi-input-cons
                    (ir.CompilerIrValue.Var 0)
                    (ir.compiler-ir-label "loop")
                    ir.CompilerIrPhiInputList.Nil)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Store
                    (ir.compiler-ir-test-symbol "hot0")
                    (ir.CompilerIrValue.Var 0)
                    (reg.compiler-reg-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Store
                      (ir.compiler-ir-test-symbol "hot1")
                      (ir.CompilerIrValue.Var 0)
                      (reg.compiler-reg-i64-ty))
                    (ir.compiler-ir-instr-cons
                      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                      ir.CompilerIrInstrList.Nil)))))
            (ir.compiler-ir-block-cons
              (ir.compiler-ir-block
                (ir.compiler-ir-label "exit")
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Return
                    (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 0)))
                  ir.CompilerIrInstrList.Nil))
              ir.CompilerIrBlockList.Nil)))))))

(cfg
  test
  (define (compiler-reg-loop-split-rewrite-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-loop-split-rewrite-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-loop-split-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (let
            [rewrite : reg.CompilerRegCallSaveRewrite
              (reg.compiler-reg-loop-split-rewrite-blocks
                (ast.ast-node-pool-reader-type-segment-bases)
                func
                blocks
                vars
                (reg.compiler-reg-function-var-types func)
                plan)]
            (match rewrite
              [(reg.CompilerRegCallSaveRewrite.Rewrite
                  rewritten
                  _
                  out-vars
                  extra-assignments
                  _)
                (let
                  [body : ir.CompilerIrInstrList
                    (compiler-reg-block-instr-list
                      rewritten
                      (ir.compiler-ir-label "body"))]
                  [rewritten-plan : reg.CompilerRegPlan
                    (reg.compiler-reg-plan-with-call-save-rewrite plan rewrite)]
                  [rewritten-assignments : reg.CompilerRegAssignmentList
                    (reg.compiler-reg-plan-assignments rewritten-plan)]
                  (and
                    (= out-vars (+ vars 1))
                    (= (reg.compiler-reg-assignment-count extra-assignments) 1)
                    ;; The region is clobber-free (no call/syscall), so the
                    ;; candidate list offers the caller-saved %r8/%r9/%rsi/%rdi
                    ;; before the callee-saved set and the split var takes %r8.
                    ;; (Stale %r12 expectation predated the clobber-free
                    ;; caller-saved widening; only --cfg test builds run this.)
                    (reg.compiler-reg-location-register?
                      (reg.compiler-reg-assignment-lookup
                        rewritten-assignments
                        vars)
                      cabi.compiler-reg-id-r8)
                    (compiler-reg-instr-list-has-mov-var? body vars 0)
                    (compiler-reg-instr-list-has-mov-var? body 0 vars)
                    (compiler-reg-instr-list-has-store-var? body "hot0" vars)
                    (compiler-reg-instr-list-has-store-var? body "hot1" vars)
                    (not (compiler-reg-instr-list-has-store-var? body "hot0" 0))))]))]))))

(cfg
  test
  (define (compiler-reg-loop-split-multiple-rewrite-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-loop-split-two-rewrite-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-loop-split-two-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (let
            [rewrite : reg.CompilerRegCallSaveRewrite
              (reg.compiler-reg-loop-split-rewrite-blocks
                (ast.ast-node-pool-reader-type-segment-bases)
                func
                blocks
                vars
                (reg.compiler-reg-function-var-types func)
                plan)]
            (match rewrite
              [(reg.CompilerRegCallSaveRewrite.Rewrite
                  rewritten
                  _
                  out-vars
                  extra-assignments
                  _)
                (let
                  [body : ir.CompilerIrInstrList
                    (compiler-reg-block-instr-list
                      rewritten
                      (ir.compiler-ir-label "body"))]
                  [rewritten-plan : reg.CompilerRegPlan
                    (reg.compiler-reg-plan-with-call-save-rewrite plan rewrite)]
                  [rewritten-assignments : reg.CompilerRegAssignmentList
                    (reg.compiler-reg-plan-assignments rewritten-plan)]
                  [split0 : i64 vars]
                  [split1 : i64 (+ vars 1)]
                  (and
                    (= out-vars (+ vars 2))
                    (= (reg.compiler-reg-assignment-count extra-assignments) 2)
                    ;; Clobber-free region -> caller-saved candidates first:
                    ;; the two split vars take %r8 and %r9 (see
                    ;; compiler-reg-loop-split-candidate-regs).
                    (reg.compiler-reg-location-register?
                      (reg.compiler-reg-assignment-lookup
                        rewritten-assignments
                        split0)
                      cabi.compiler-reg-id-r8)
                    (reg.compiler-reg-location-register?
                      (reg.compiler-reg-assignment-lookup
                        rewritten-assignments
                        split1)
                      cabi.compiler-reg-id-r9)
                    (compiler-reg-instr-list-has-store-var? body "hot0" split0)
                    (compiler-reg-instr-list-has-store-var? body "hot1" split1)
                    (compiler-reg-instr-list-has-store-var? body "hot2" split0)
                    (compiler-reg-instr-list-has-store-var? body "hot3" split1)
                    (not (compiler-reg-instr-list-has-store-var? body "hot0" 0))
                    (not (compiler-reg-instr-list-has-store-var? body "hot1" 1))))]))]))))

(cfg
  test
  (define (compiler-reg-loop-split-noop-for? [func : ir.CompilerIrFunction]) : bool
    (let
      [plan : reg.CompilerRegPlan (compiler-reg-loop-split-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-loop-split-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                _
                _
                out-vars
                extra-assignments
                _)
              (and
                (= out-vars vars)
                (= (reg.compiler-reg-assignment-count extra-assignments) 0))])]))))

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
      [func : ir.CompilerIrFunction
        (compiler-reg-loop-split-phi-region-function)]
      [plan : reg.CompilerRegPlan (compiler-reg-loop-split-plan func)]
      (match func
        [(ir.CompilerIrFunction.Function _ _ _ vars blocks)
          (match (reg.compiler-reg-loop-split-rewrite-blocks
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            blocks
            vars
            (reg.compiler-reg-function-var-types func)
            plan)
            [(reg.CompilerRegCallSaveRewrite.Rewrite
                _
                _
                out-vars
                extra-assignments
                _)
              (and
                (= out-vars (+ vars 1))
                (= (reg.compiler-reg-assignment-count extra-assignments) 1))])]))))

(cfg
  test
  (define (compiler-reg-loop-split-clobber-scan-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "loop_split_clobber_scan")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      5
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "loop")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.I64 3)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.BinOp
                  2
                  (ir.CompilerIrBinOp.Shl (ast.AstType.I64))
                  (ir.CompilerIrValue.Var 0)
                  (ir.CompilerIrValue.Var 1)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.BinOp
                    3
                    (ir.CompilerIrBinOp.Div)
                    (ir.CompilerIrValue.Var 0)
                    (ir.CompilerIrValue.Var 1)
                    (reg.compiler-reg-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.BinOp
                      4
                      (ir.CompilerIrBinOp.Mul)
                      (ir.CompilerIrValue.Var 0)
                      (ir.CompilerIrValue.Var 1)
                      (reg.compiler-reg-i64-ty))
                    (ir.compiler-ir-instr-cons
                      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
                      ir.CompilerIrInstrList.Nil)))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-loop-split-rcx-rdx-candidates-ok?) : bool
    (let
      [safe : reg.CompilerRegIdSeq
        (reg.compiler-reg-loop-split-candidate-regs true true true)]
      [unsafe : reg.CompilerRegIdSeq
        (reg.compiler-reg-loop-split-candidate-regs true false false)]
      [call-region : reg.CompilerRegIdSeq
        (reg.compiler-reg-loop-split-candidate-regs false true true)]
      (and
        (reg.compiler-reg-id-seq-contains? safe cabi.compiler-reg-id-rcx)
        (reg.compiler-reg-id-seq-contains? safe cabi.compiler-reg-id-rdx)
        (not
          (reg.compiler-reg-id-seq-contains? unsafe cabi.compiler-reg-id-rcx))
        (not
          (reg.compiler-reg-id-seq-contains? unsafe cabi.compiler-reg-id-rdx))
        (reg.compiler-reg-id-seq-contains? unsafe cabi.compiler-reg-id-r8)
        (reg.compiler-reg-id-seq-contains? unsafe cabi.compiler-reg-id-rdi)
        (not
          (reg.compiler-reg-id-seq-contains?
            call-region
            cabi.compiler-reg-id-r8))
        (not
          (reg.compiler-reg-id-seq-contains?
            call-region
            cabi.compiler-reg-id-rcx))
        (not
          (reg.compiler-reg-id-seq-contains?
            call-region
            cabi.compiler-reg-id-rdx))))))

(cfg
  test
  (define (compiler-reg-loop-split-fixed-clobber-scan-ok?) : bool
    (let
      [func : ir.CompilerIrFunction
        (compiler-reg-loop-split-clobber-scan-function)]
      [full-window : reg.CompilerRegIdSeq
        (reg.compiler-reg-loop-split-candidate-regs
          true
          (reg.compiler-reg-loop-split-region-rcx-safe?
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            0
            12)
          (reg.compiler-reg-loop-split-region-rdx-safe?
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            0
            12))]
      (and
        ;; Point 4 is the variable shift; inclusive-start makes [4,6) unsafe.
        (reg.compiler-reg-loop-split-region-crosses-kind?
          (ast.ast-node-pool-reader-type-segment-bases)
          func
          2
          4
          6)
        ;; Points 6 and 8 are the div and mul %rdx fixed-use sites.
        (reg.compiler-reg-loop-split-region-crosses-kind?
          (ast.ast-node-pool-reader-type-segment-bases)
          func
          4
          6
          8)
        (reg.compiler-reg-loop-split-region-crosses-kind?
          (ast.ast-node-pool-reader-type-segment-bases)
          func
          4
          8
          10)
        ;; The half-open end still excludes a clobber exactly at end.
        (not
          (reg.compiler-reg-loop-split-region-crosses-kind?
            (ast.ast-node-pool-reader-type-segment-bases)
            func
            2
            0
            4))
        (not
          (reg.compiler-reg-id-seq-contains?
            full-window
            cabi.compiler-reg-id-rcx))
        (not
          (reg.compiler-reg-id-seq-contains?
            full-window
            cabi.compiler-reg-id-rdx))
        (reg.compiler-reg-id-seq-contains? full-window cabi.compiler-reg-id-r8)
        (reg.compiler-reg-id-seq-contains? full-window cabi.compiler-reg-id-rdi)))))

(cfg
  test
  (define (compiler-reg-many-call-live-function) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "many_call_live")
      ir.CompilerIrParamList.Nil
      (ast.AstType.Unit)
      6
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 9)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Call
                1
                (ir.compiler-ir-test-symbol "side_effect_a")
                (ir.CompilerIrCallArgs.Nil)
                (ast.AstType.Unit))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Call
                  2
                  (ir.compiler-ir-test-symbol "side_effect_b")
                  (ir.CompilerIrCallArgs.Nil)
                  (ast.AstType.Unit))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Call
                    3
                    (ir.compiler-ir-test-symbol "side_effect_c")
                    (ir.CompilerIrCallArgs.Nil)
                    (ast.AstType.Unit))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Call
                      4
                      (ir.compiler-ir-test-symbol "side_effect_d")
                      (ir.CompilerIrCallArgs.Nil)
                      (ast.AstType.Unit))
                    (ir.compiler-ir-instr-cons
                      (ir.CompilerIrInstr.Mov
                        5
                        (ir.CompilerIrValue.Var 0)
                        (reg.compiler-reg-i64-ty))
                      (ir.compiler-ir-instr-cons
                        (ir.CompilerIrInstr.Return
                          (ir.CompilerIrMaybeValue.Some
                            (ir.CompilerIrValue.Var 5)))
                        ir.CompilerIrInstrList.Nil))))))))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-call-span-counts-ok?) : bool
    (let
      [points : live.CompilerLiveI64Set (live.compiler-live-set4 2 4 6 8)]
      (and
        (= (reg.compiler-reg-call-set-count-in-range points 0 2) 0)
        (= (reg.compiler-reg-call-set-count-in-range points 0 3) 1)
        (= (reg.compiler-reg-call-set-count-in-range points 0 7) 3)
        (= (reg.compiler-reg-call-set-count-in-range points 0 9) 4)
        (= (reg.compiler-reg-call-set-count-in-range points 2 8) 2)))))

(cfg
  test
  (define (compiler-reg-call-span-census-count?
    [census : reg.CompilerRegCallSpanCensus]
    [bucket : i64]
    [outcome : i64]
    [want : i64]) : bool
    (= (reg.compiler-reg-call-span-census-count census bucket outcome) want)))

(cfg
  test
  (define (compiler-reg-call-span-census-ok?) : bool
    (let
      [zero-census : reg.CompilerRegCallSpanCensus
        (reg.compiler-reg-plan-call-span-census
          (reg.compiler-reg-overlap-function)
          (reg.compiler-reg-plan-function-scalar
            (reg.compiler-reg-overlap-function)))]
      [one-census : reg.CompilerRegCallSpanCensus
        (reg.compiler-reg-plan-call-span-census
          (reg.compiler-reg-call-live-function)
          (reg.compiler-reg-plan-function-scalar
            (reg.compiler-reg-call-live-function)))]
      [many-census : reg.CompilerRegCallSpanCensus
        (reg.compiler-reg-plan-call-span-census
          (compiler-reg-many-call-live-function)
          (reg.compiler-reg-plan-function-scalar
            (compiler-reg-many-call-live-function)))]
      (and
        (compiler-reg-call-span-census-count?
          zero-census
          0
          (reg.compiler-reg-call-span-outcome-register)
          7)
        (compiler-reg-call-span-census-count?
          zero-census
          0
          (reg.compiler-reg-call-span-outcome-spill)
          0)
        (compiler-reg-call-span-census-count?
          one-census
          1
          (reg.compiler-reg-call-span-outcome-register)
          1)
        (compiler-reg-call-span-census-count?
          one-census
          0
          (reg.compiler-reg-call-span-outcome-register)
          1)
        (compiler-reg-call-span-census-count?
          many-census
          3
          (reg.compiler-reg-call-span-outcome-register)
          1)
        (compiler-reg-call-span-census-count?
          many-census
          0
          (reg.compiler-reg-call-span-outcome-register)
          1)))))

(cfg
  test
  (define (compiler-reg-xmm-ownership-fixed-home
    [preassigned-reg : i64]
    [intervals : reg.CompilerRegIntervalSeq]
    [candidate-start : i64]
    [candidate-end : i64]
    [regs : reg.CompilerRegIdSeq]) : i64
    (let
      [index : reg.CompilerRegIntervalIndex
        (reg.compiler-reg-interval-index-build intervals 2)]
      [assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignment-table-insert
          (reg.compiler-reg-assignment-table-make 2)
          0
          (reg.CompilerRegLocation.Register preassigned-reg))]
      [candidates : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 1 candidate-start candidate-end)
          (reg.compiler-reg-interval-seq-empty))]
      (match (reg.compiler-reg-assign-fixed-candidates
        candidates
        regs
        (reg.compiler-reg-active-seq-empty)
        assignments
        (array.make-array i64 0)
        index)
        [(reg.CompilerRegAssignState.State _ out)
          (match (reg.compiler-reg-assignment-table-lookup out 1)
            [(reg.CompilerRegMaybeLocation.Some location)
              (reg.compiler-reg-location-primary-register location)]
            [(reg.CompilerRegMaybeLocation.No) cabi.compiler-reg-id-invalid])]))))

(cfg
  test
  (define (compiler-reg-register-id-range-roundtrips?
    [reg-id : i64]
    [end : i64]) : bool
    (if (>= reg-id end)
      true
      (and
        (=
          (cabi.compiler-abi-register-id-from-spelling
            (cabi.compiler-abi-register-spelling reg-id))
          reg-id)
        (compiler-reg-register-id-range-roundtrips? (+ reg-id 1) end)))))

(cfg
  test
  (define (compiler-reg-canonical-register-ids-ok?) : bool
    (and
      ;; Every canonical ID round-trips through the cold spelling boundary.
      (compiler-reg-register-id-range-roundtrips?
        cabi.compiler-reg-id-rax
        (+ cabi.compiler-reg-id-r15 1))
      (compiler-reg-register-id-range-roundtrips?
        cabi.compiler-reg-id-xmm-base
        (+ cabi.compiler-reg-id-xmm-base cabi.compiler-reg-id-family-count))
      (compiler-reg-register-id-range-roundtrips?
        cabi.compiler-reg-id-vec-base
        (+ cabi.compiler-reg-id-vec-base cabi.compiler-reg-id-family-count))
      (compiler-reg-register-id-range-roundtrips?
        cabi.compiler-reg-id-mask-base
        (+ cabi.compiler-reg-id-mask-base cabi.compiler-reg-id-mask-count))
      ;; Constructors reject values outside their compact domains.
      (= (cabi.compiler-abi-xmm-register-id -1) cabi.compiler-reg-id-invalid)
      (= (cabi.compiler-abi-xmm-register-id 32) cabi.compiler-reg-id-invalid)
      (= (cabi.compiler-abi-vector-register-id -1) cabi.compiler-reg-id-invalid)
      (= (cabi.compiler-abi-vector-register-id 32) cabi.compiler-reg-id-invalid)
      (= (cabi.compiler-abi-mask-register-id -1) cabi.compiler-reg-id-invalid)
      (= (cabi.compiler-abi-mask-register-id 8) cabi.compiler-reg-id-invalid)
      ;; Width-specific vector spellings share ownership without losing class.
      (=
        (cabi.compiler-abi-register-id-from-spelling "%ymm31")
        (cabi.compiler-abi-vector-register-id 31))
      (=
        (cabi.compiler-abi-register-id-from-spelling "%zmm31")
        (cabi.compiler-abi-vector-register-id 31))
      (cabi.compiler-abi-registers-overlap?
        (cabi.compiler-abi-xmm-register-id 31)
        (cabi.compiler-abi-vector-register-id 31))
      (=
        (cabi.compiler-abi-register-with-vector-class
          (cabi.compiler-abi-xmm-register-id 31)
          true)
        (cabi.compiler-abi-vector-register-id 31))
      ;; ABI tables return canonical IDs, including their invalid boundaries.
      (=
        (cabi.compiler-abi-gp-arg-register-id
          (cabi.CompilerRegTargetAbi.Linux)
          0)
        cabi.compiler-reg-id-rdi)
      (=
        (cabi.compiler-abi-gp-arg-register-id
          (cabi.CompilerRegTargetAbi.Windows)
          3)
        cabi.compiler-reg-id-r9)
      (=
        (cabi.compiler-abi-float-arg-register-id
          (cabi.CompilerRegTargetAbi.Linux)
          7)
        (cabi.compiler-abi-xmm-register-id 7))
      (=
        (cabi.compiler-abi-callee-saved-xmm-register-id
          (cabi.CompilerRegTargetAbi.Windows)
          9)
        (cabi.compiler-abi-xmm-register-id 15))
      (=
        (cabi.compiler-abi-gp-arg-register-id
          (cabi.CompilerRegTargetAbi.Windows)
          4)
        cabi.compiler-reg-id-invalid)
      (=
        (cabi.compiler-abi-caller-saved-xmm-register-id
          (cabi.CompilerRegTargetAbi.Windows)
          6)
        cabi.compiler-reg-id-invalid))))

(cfg
  test
  (define (compiler-reg-xmm-ownership-intervals
    [pre-start : i64]
    [pre-end : i64]
    [candidate-start : i64]
    [candidate-end : i64]) : reg.CompilerRegIntervalSeq
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 0 pre-start pre-end)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 1 candidate-start candidate-end)
        (reg.compiler-reg-interval-seq-empty)))))

(cfg
  test
  (define (compiler-reg-xmm-ownership-segment-hole-intervals) : reg.CompilerRegIntervalSeq
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 0 0 2)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 1 3 5)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 0 6 8)
          (reg.compiler-reg-interval-seq-empty))))))

(cfg
  test
  (define (compiler-reg-xmm-physical-ownership-ok?) : bool
    (let
      [vector-pool : reg.CompilerRegIdSeq
        (reg.compiler-reg-id-seq-prepend
          (cabi.compiler-abi-vector-register-id 6)
          (reg.compiler-reg-id-seq-prepend
            (cabi.compiler-abi-vector-register-id 7)
            (reg.compiler-reg-id-seq-empty)))]
      [scalar-spelled-pool : reg.CompilerRegIdSeq
        (reg.compiler-reg-id-seq-prepend
          (cabi.compiler-abi-xmm-register-id 6)
          (reg.compiler-reg-id-seq-prepend
            (cabi.compiler-abi-xmm-register-id 7)
            (reg.compiler-reg-id-seq-empty)))]
      [overlap : reg.CompilerRegIntervalSeq
        (compiler-reg-xmm-ownership-intervals 0 8 2 6)]
      [boundary-reuse : reg.CompilerRegIntervalSeq
        (compiler-reg-xmm-ownership-intervals 0 2 2 6)]
      (and
        ;; AVX2/AVX-512 spellings and the width-neutral allocator home all own
        ;; the same physical register as an f32/f64 scalar XMM spelling.
        (reg.compiler-reg-registers-overlap?
          (cabi.compiler-abi-xmm-register-id 6)
          (cabi.compiler-abi-vector-register-id 6))
        (reg.compiler-reg-registers-overlap?
          (cabi.compiler-abi-xmm-register-id 6)
          (cabi.compiler-abi-register-id-from-spelling "%ymm6"))
        (reg.compiler-reg-registers-overlap?
          (cabi.compiler-abi-xmm-register-id 6)
          (cabi.compiler-abi-register-id-from-spelling "%zmm6"))
        (not
          (reg.compiler-reg-registers-overlap?
            (cabi.compiler-abi-xmm-register-id 6)
            (cabi.compiler-abi-vector-register-id 7)))
        (not
          (reg.compiler-reg-registers-overlap?
            (cabi.compiler-abi-xmm-register-id 6)
            (cabi.compiler-abi-mask-register-id 6)))
        (=
          (reg.compiler-reg-xmm-family-index
            (cabi.compiler-abi-xmm-register-id 13))
          13)
        (=
          (reg.compiler-reg-xmm-family-index
            (cabi.compiler-abi-register-id-from-spelling "%ymm13"))
          13)
        (=
          (reg.compiler-reg-xmm-family-index
            (cabi.compiler-abi-register-id-from-spelling "%zmm13"))
          13)
        (=
          (reg.compiler-reg-xmm-family-index
            (cabi.compiler-abi-vector-register-id 13))
          13)
        (=
          (reg.compiler-reg-xmm-family-index
            (cabi.compiler-abi-register-id-from-spelling "%xmm06"))
          -1)
        ;; Deliberate f32/f64-vs-vector collisions reject physical index 6 at
        ;; every emitted width and select the next vector home.
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (cabi.compiler-abi-xmm-register-id 6)
            overlap
            2
            6
            vector-pool)
          (cabi.compiler-abi-vector-register-id 7))
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (cabi.compiler-abi-vector-register-id 6)
            overlap
            2
            6
            vector-pool)
          (cabi.compiler-abi-vector-register-id 7))
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (cabi.compiler-abi-vector-register-id 6)
            overlap
            2
            6
            vector-pool)
          (cabi.compiler-abi-vector-register-id 7))
        ;; Mask-on-vector allocation uses the same ownership query even when
        ;; the preassignment and candidate pools use opposite class spellings.
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (cabi.compiler-abi-vector-register-id 6)
            overlap
            2
            6
            scalar-spelled-pool)
          (cabi.compiler-abi-xmm-register-id 7))
        ;; Touching ranges and a segmented phi/liveness hole may safely reuse
        ;; the physical register; real segment overlap still rejects it.
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (cabi.compiler-abi-xmm-register-id 6)
            boundary-reuse
            2
            6
            vector-pool)
          (cabi.compiler-abi-vector-register-id 6))
        (=
          (compiler-reg-xmm-ownership-fixed-home
            (cabi.compiler-abi-xmm-register-id 6)
            (compiler-reg-xmm-ownership-segment-hole-intervals)
            3
            5
            vector-pool)
          (cabi.compiler-abi-vector-register-id 6))))))

(cfg
  test
  (define (compiler-reg-dense-mask-on-vector-homes-ok?) : bool
    (let
      [list-func : ir.CompilerIrFunction (reg.compiler-reg-mask-home-function)]
      [dense-func : ir.CompilerIrFunction
        (ir.compiler-ir-function-compact-blocks list-func)]
      [list-assignments : reg.CompilerRegAssignmentList
        (reg.compiler-reg-plan-assignments
          (compiler-reg-plan-function-avx2 list-func))]
      [dense-assignments : reg.CompilerRegAssignmentList
        (reg.compiler-reg-plan-assignments
          (compiler-reg-plan-function-avx2 dense-func))]
      (and
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup list-assignments 0)
          (cabi.compiler-abi-vector-register-id 6))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup list-assignments 1)
          (cabi.compiler-abi-vector-register-id 7))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup dense-assignments 0)
          (cabi.compiler-abi-vector-register-id 6))
        (reg.compiler-reg-location-register?
          (reg.compiler-reg-assignment-lookup dense-assignments 1)
          (cabi.compiler-abi-vector-register-id 7))))))

(cfg
  test
  (define (compiler-reg-liveness-handle-ok?) : bool
    (let
      [func : ir.CompilerIrFunction (compiler-reg-edge-copy-linear-function)]
      [region : reg.CompilerRegLabelSeq
        (reg.compiler-reg-label-seq-prepend
          (ir.compiler-ir-label "hot")
          (reg.compiler-reg-label-seq-empty))]
      (begin
        (reg.compiler-reg-liveness-census-reset!)
        (let
          [handle : reg.CompilerRegLivenessHandle
            (reg.compiler-reg-liveness-handle-make func true)]
          [liveness : live.CompilerFunctionLiveness
            (struct-get handle baseline)]
          (and
            (match (reg.compiler-reg-edge-copy-plan-for-region-with-liveness
              liveness
              region
              0
              10
              (reg.compiler-reg-i64-ty))
              [(reg.CompilerRegEdgeCopyPlan.Plan _) true]
              [(reg.CompilerRegEdgeCopyPlan.Refused _) false])
            (match (reg.compiler-reg-edge-copy-plan-for-region-with-liveness
              liveness
              region
              0
              11
              (reg.compiler-reg-i64-ty))
              [(reg.CompilerRegEdgeCopyPlan.Plan _) true]
              [(reg.CompilerRegEdgeCopyPlan.Refused _) false])
            (= (reg.compiler-reg-liveness-census-baseline-count) 1)
            ;; The linear fixture is phi-free, so the edge-precise analysis is
            ;; the baseline itself and no second fixpoint is computed.
            (= (reg.compiler-reg-liveness-census-edge-precise-count) 0)))))))

(cfg
  test
  (define (compiler-reg-liveness-handle-phi-fixture) : ir.CompilerIrFunction
    (ir.CompilerIrFunction.Function
      (ir.compiler-ir-test-symbol "liveness_handle_phi")
      ir.CompilerIrParamList.Nil
      (ast.AstType.I64)
      2
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "entry")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Mov
              0
              (ir.CompilerIrValue.I64 7)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "loop"))
              ir.CompilerIrInstrList.Nil)))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "loop")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Phi
                1
                (ir.CompilerIrPhiInputList.Cons
                  (ir.CompilerIrValue.Var 0)
                  (ir.compiler-ir-label "entry")
                  (box
                    (ir.CompilerIrPhiInputList.Cons
                      (ir.CompilerIrValue.Var 1)
                      (ir.compiler-ir-label "loop")
                      (box ir.CompilerIrPhiInputList.Nil))))
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Return
                  (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 1)))
                ir.CompilerIrInstrList.Nil)))
          ir.CompilerIrBlockList.Nil)))))

(cfg
  test
  (define (compiler-reg-liveness-handle-phi-ok?) : bool
    (begin
      (reg.compiler-reg-liveness-census-reset!)
      (let
        [_handle : reg.CompilerRegLivenessHandle
          (reg.compiler-reg-liveness-handle-make
            (compiler-reg-liveness-handle-phi-fixture)
            true)]
        (and
          (= (reg.compiler-reg-liveness-census-baseline-count) 1)
          ;; Phi present: the second, edge-precise fixpoint is computed.
          (= (reg.compiler-reg-liveness-census-edge-precise-count) 1))))))

(cfg
  test
  (define (compiler-reg-group-pair-test-fill-homes!
    [assignments : reg.CompilerRegAssignmentTable]
    [var : i64]
    [vars : i64]) : unit
    (if (or (>= var vars) (>= var 6))
      unit
      (let
        [_inserted : reg.CompilerRegAssignmentTable
          (reg.compiler-reg-assignment-table-insert
            assignments
            var
            (reg.CompilerRegLocation.Register
              (reg.compiler-reg-group-pair-csr (- var 1))))]
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
      [interval-index : reg.CompilerRegIntervalIndex
        (reg.compiler-reg-interval-index-build
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval 0 0 10)
            (reg.compiler-reg-interval-seq-prepend
              (reg.CompilerRegInterval 1 0 10)
              (reg.compiler-reg-interval-seq-prepend
                (reg.CompilerRegInterval 2 0 10)
                (reg.compiler-reg-interval-seq-prepend
                  (reg.CompilerRegInterval 3 0 10)
                  (reg.compiler-reg-interval-seq-prepend
                    (reg.CompilerRegInterval 4 0 10)
                    (reg.compiler-reg-interval-seq-prepend
                      (reg.CompilerRegInterval 5 0 10)
                      (reg.compiler-reg-interval-seq-prepend
                        (reg.CompilerRegInterval 6 0 10)
                        (reg.compiler-reg-interval-seq-prepend
                          (reg.CompilerRegInterval 7 0 10)
                          (reg.compiler-reg-interval-seq-prepend
                            (reg.CompilerRegInterval 8 0 10)
                            (reg.compiler-reg-interval-seq-prepend
                              (reg.CompilerRegInterval 9 0 10)
                              (reg.compiler-reg-interval-seq-empty)))))))))))
          vars)]
      [members : (__tl_dyn-array i64) (array.make-array i64 vars)]
      [parents : (__tl_dyn-array i64) (array.make-array i64 vars)]
      [poisoned : (__tl_dyn-array bool) (array.make-array bool vars)]
      [weights : (__tl_dyn-array i64) (array.make-array i64 vars)]
      [assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignment-table-make vars)]
      [csr-assignments : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignment-table-make vars)]
      [caller-occupied : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignment-table-make vars)]
      [nonoccupying : reg.CompilerRegAssignmentTable
        (reg.compiler-reg-assignment-table-make vars)]
      [shadow-regs : (__tl_dyn-array i64) (array.make-array i64 2)]
      (begin
        (reg.compiler-reg-fill-i64-array
          shadow-regs
          cabi.compiler-reg-id-invalid)
        (array-set! members 0 0)
        (reg.compiler-reg-fill-i64-array weights 1)
        (array-set! weights 0 10)
        (let
          [v : i64 0]
          (while (< v vars)
            (begin
              (array-set! parents v v)
              (array-set! poisoned v false)
              (set! v (+ v 1)))))
        (array-set! shadow-regs 1 cabi.compiler-reg-id-r8)
        (compiler-reg-group-pair-test-fill-homes! assignments 1 vars)
        (compiler-reg-group-pair-test-fill-homes! csr-assignments 1 vars)
        (compiler-reg-group-pair-test-fill-homes! caller-occupied 1 vars)
        (let
          [_nonoccupying-spill : reg.CompilerRegAssignmentTable
            (reg.compiler-reg-assignment-table-insert
              nonoccupying
              1
              (reg.CompilerRegLocation.Spill
                (reg.compiler-reg-stack-slot-offset 1)))]
          [_nonoccupying-pair : reg.CompilerRegAssignmentTable
            (reg.compiler-reg-assignment-table-insert
              nonoccupying
              2
              (reg.CompilerRegLocation.RegisterPair
                cabi.compiler-reg-id-r12
                cabi.compiler-reg-id-r13))]
          [_caller-occupied-r8 : reg.CompilerRegAssignmentTable
            (reg.compiler-reg-assignment-table-insert
              caller-occupied
              1
              (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r8))]
          [_caller-occupied-r12 : reg.CompilerRegAssignmentTable
            (reg.compiler-reg-assignment-table-insert
              caller-occupied
              6
              (reg.CompilerRegLocation.Register cabi.compiler-reg-id-r12))]
          [empty-split : reg.CompilerRegCallSplit
            (reg.compiler-reg-call-split-empty)]
          [shadow-split : reg.CompilerRegCallSplit
            (reg.CompilerRegCallSplit
              (live.compiler-live-set-empty)
              shadow-regs
              (reg.compiler-reg-call-region-seq-push
                (reg.compiler-reg-call-region-seq-empty)
                (reg.CompilerRegCallRegion 1 0 10 0 0)))]
          [phi-excluded : live.CompilerLiveI64Set
            (reg.compiler-reg-group-pair-excluded-instr
              (live.compiler-live-set-empty)
              (ir.CompilerIrInstr.Phi
                0
                ir.CompilerIrPhiInputList.Nil
                (ast.AstType.Struct (ci.intern "Pair")))
              (live.compiler-live-set1 0))]
          [call-caller-unsafe : live.CompilerLiveI64Set
            (reg.compiler-reg-group-pair-caller-unsafe-instr
              (live.compiler-live-set-empty)
              (ir.CompilerIrInstr.Call
                1
                (ir.compiler-ir-test-symbol "callee")
                (ir.CompilerIrCallArgs.One (ir.CompilerIrValue.Var 0))
                (ast.AstType.I64)))]
          [indirect-call-caller-unsafe : live.CompilerLiveI64Set
            (reg.compiler-reg-group-pair-caller-unsafe-instr
              (live.compiler-live-set-empty)
              (ir.CompilerIrInstr.CallIndirect
                1
                (ir.CompilerIrValue.Var 2)
                (ir.CompilerIrCallArgs.One (ir.CompilerIrValue.Var 0))
                (ast.AstType.I64)))]
          [indirect-c-call-caller-unsafe : live.CompilerLiveI64Set
            (reg.compiler-reg-group-pair-caller-unsafe-instr
              (live.compiler-live-set-empty)
              (ir.CompilerIrInstr.CallIndirectC
                1
                (ir.CompilerIrValue.Var 2)
                (ir.CompilerIrCallArgs.One (ir.CompilerIrValue.Var 0))
                (ast.AstType.I64)))]
          [pair-conflicts : (__tl_dyn-array i64) (array.make-array i64 vars)]
          [pair-conflict-count : i64
            (reg.compiler-reg-group-pair-conflict-vars!
              interval-index
              members
              1
              vars
              pair-conflicts)]
          [shadow-cost : i64
            (reg.compiler-reg-group-pair-component-register-cost
              assignments
              interval-index
              members
              1
              pair-conflicts
              pair-conflict-count
              weights
              10
              true
              shadow-split
              cabi.compiler-reg-id-r8)]
          [free-r8-cost : i64
            (reg.compiler-reg-group-pair-component-register-cost
              nonoccupying
              interval-index
              members
              1
              pair-conflicts
              pair-conflict-count
              weights
              10
              true
              empty-split
              cabi.compiler-reg-id-r8)]
          [occupied-r8-cost : i64
            (reg.compiler-reg-group-pair-component-register-cost
              caller-occupied
              interval-index
              members
              1
              pair-conflicts
              pair-conflict-count
              weights
              10
              true
              empty-split
              cabi.compiler-reg-id-r8)]
          [csr-evict-cost : i64
            (reg.compiler-reg-group-pair-component-register-cost
              assignments
              interval-index
              members
              1
              pair-conflicts
              pair-conflict-count
              weights
              10
              false
              empty-split
              cabi.compiler-reg-id-r12)]
          [blocked-r12-cost : i64
            (reg.compiler-reg-group-pair-component-register-cost
              nonoccupying
              interval-index
              members
              1
              pair-conflicts
              pair-conflict-count
              weights
              10
              false
              empty-split
              cabi.compiler-reg-id-r12)]
          (let
            [_caller-placed : unit
              (reg.compiler-reg-assign-group-pair-component
                (ast.ast-node-pool-reader-type-segment-bases)
                0
                vars
                (reg.compiler-reg-coalesce-test-i64-types vars)
                (live.compiler-live-set1 0)
                (live.compiler-live-set-empty)
                (live.compiler-live-set-empty)
                (struct-get interval-index starts)
                (struct-get interval-index ends)
                poisoned
                parents
                members
                interval-index
                caller-occupied
                weights
                (live.compiler-live-set-empty)
                empty-split)]
            [_csr-placed : unit
              (reg.compiler-reg-assign-group-pair-component
                (ast.ast-node-pool-reader-type-segment-bases)
                0
                vars
                (reg.compiler-reg-coalesce-test-i64-types vars)
                (live.compiler-live-set1 0)
                (live.compiler-live-set-empty)
                (live.compiler-live-set1 0)
                (struct-get interval-index starts)
                (struct-get interval-index ends)
                poisoned
                parents
                members
                interval-index
                csr-assignments
                weights
                (live.compiler-live-set-empty)
                empty-split)]
            [_placed : unit
              (reg.compiler-reg-assign-group-pair-component
                (ast.ast-node-pool-reader-type-segment-bases)
                0
                vars
                (reg.compiler-reg-coalesce-test-i64-types vars)
                (live.compiler-live-set1 0)
                (live.compiler-live-set-empty)
                (live.compiler-live-set-empty)
                (struct-get interval-index starts)
                (struct-get interval-index ends)
                poisoned
                parents
                members
                interval-index
                assignments
                weights
                (live.compiler-live-set-empty)
                empty-split)]
            (and
              (= (reg.compiler-reg-group-pair-candidate-count true) 7)
              (=
                (reg.compiler-reg-group-pair-candidate true 0)
                cabi.compiler-reg-id-r8)
              (=
                (reg.compiler-reg-group-pair-candidate true 1)
                cabi.compiler-reg-id-r9)
              (=
                (reg.compiler-reg-group-pair-candidate true 2)
                cabi.compiler-reg-id-r12)
              (= (reg.compiler-reg-group-pair-candidate-count false) 5)
              (=
                (reg.compiler-reg-group-pair-candidate false 0)
                cabi.compiler-reg-id-r12)
              (reg.compiler-reg-group-pair-component-clobber-free?
                interval-index
                (live.compiler-live-set-empty)
                members
                1)
              (not
                (reg.compiler-reg-group-pair-component-clobber-free?
                  interval-index
                  (live.compiler-live-set1 5)
                  members
                  1))
              (not (live.compiler-live-set-contains? phi-excluded 0))
              (live.compiler-live-set-contains? call-caller-unsafe 0)
              (live.compiler-live-set-contains? indirect-call-caller-unsafe 0)
              (live.compiler-live-set-contains? indirect-c-call-caller-unsafe 0)
              (reg.compiler-reg-group-pair-component-contains?
                call-caller-unsafe
                members
                1)
              (= shadow-cost (- 0 1))
              (= free-r8-cost 0)
              (> occupied-r8-cost 0)
              (> csr-evict-cost 0)
              (= blocked-r12-cost (- 0 1))
              (match (reg.compiler-reg-assignment-table-lookup assignments 0)
                [(reg.CompilerRegMaybeLocation.Some location)
                  (match location
                    [(reg.CompilerRegLocation.RegisterPair first second)
                      (and
                        (= first cabi.compiler-reg-id-r8)
                        (= second cabi.compiler-reg-id-r9))]
                    [_ false])]
                [(reg.CompilerRegMaybeLocation.No) false])
              (match (reg.compiler-reg-assignment-table-lookup assignments 1)
                [(reg.CompilerRegMaybeLocation.Some location)
                  (match location
                    [(reg.CompilerRegLocation.Register reg)
                      (= reg cabi.compiler-reg-id-r12)]
                    [_ false])]
                [(reg.CompilerRegMaybeLocation.No) false])
              (match (reg.compiler-reg-assignment-table-lookup
                caller-occupied
                0)
                [(reg.CompilerRegMaybeLocation.Some location)
                  (match location
                    [(reg.CompilerRegLocation.RegisterPair first second)
                      (and
                        (= first cabi.compiler-reg-id-r8)
                        (= second cabi.compiler-reg-id-r9))]
                    [_ false])]
                [(reg.CompilerRegMaybeLocation.No) false])
              (match (reg.compiler-reg-assignment-table-lookup
                caller-occupied
                1)
                [(reg.CompilerRegMaybeLocation.Some location)
                  (match location
                    [(reg.CompilerRegLocation.Spill _) true]
                    [_ false])]
                [(reg.CompilerRegMaybeLocation.No) false])
              (match (reg.compiler-reg-assignment-table-lookup
                csr-assignments
                0)
                [(reg.CompilerRegMaybeLocation.Some location)
                  (match location
                    [(reg.CompilerRegLocation.RegisterPair first second)
                      (and
                        (= first cabi.compiler-reg-id-r12)
                        (= second cabi.compiler-reg-id-r13))]
                    [_ false])]
                [(reg.CompilerRegMaybeLocation.No) false])
              (match (reg.compiler-reg-assignment-table-lookup
                csr-assignments
                1)
                [(reg.CompilerRegMaybeLocation.Some location)
                  (match location
                    [(reg.CompilerRegLocation.Spill _) true]
                    [_ false])]
                [(reg.CompilerRegMaybeLocation.No) false])
              (match (reg.compiler-reg-assignment-table-lookup
                csr-assignments
                2)
                [(reg.CompilerRegMaybeLocation.Some location)
                  (match location
                    [(reg.CompilerRegLocation.Spill _) true]
                    [_ false])]
                [(reg.CompilerRegMaybeLocation.No) false]))))))))

(cfg
  test
  (define (compiler-reg-test-interval-shape?
    [items : reg.CompilerRegIntervalSeq]
    [index : i64]
    [var : i64]
    [start : i64]
    [end : i64]) : bool
    (let
      [got : reg.CompilerRegInterval
        (reg.compiler-reg-interval-seq-ref items index)]
      (and
        (= (struct-get got var) var)
        (= (struct-get got start) start)
        (= (struct-get got end) end)))))

(cfg
  test
  (define (compiler-reg-dense-interval-seq-ok?) : bool
    (let
      [appended : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-empty)]
      [prepended : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-empty)]
      [inserted : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-empty)]
      [separated-left : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-empty)]
      [separated-right : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-empty)]
      [late-overlap-right : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-empty)]
      [zero-left : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-empty)]
      [zero-right : reg.CompilerRegIntervalSeq
        (reg.compiler-reg-interval-seq-empty)]
      [i : i64 0]
      (begin
        ;; Cross several capacity boundaries in both construction directions.
        (while (< i 10)
          (begin
            (set!
              appended
              (reg.compiler-reg-interval-seq-append
                appended
                (reg.CompilerRegInterval i (* i 2) (+ (* i 2) 1))))
            (set!
              prepended
              (reg.compiler-reg-interval-seq-prepend
                (reg.CompilerRegInterval i (* i 2) (+ (* i 2) 1))
                prepended))
            (set! i (+ i 1))))
        (set!
          inserted
          (reg.compiler-reg-interval-seq-append
            inserted
            (reg.CompilerRegInterval 0 0 1)))
        (set!
          inserted
          (reg.compiler-reg-interval-seq-append
            inserted
            (reg.CompilerRegInterval 2 4 5)))
        (set!
          inserted
          (reg.compiler-reg-interval-seq-append
            inserted
            (reg.CompilerRegInterval 1 2 3)))
        (set! inserted (reg.compiler-reg-candidate-sort inserted))
        (set!
          separated-left
          (reg.compiler-reg-interval-seq-append
            separated-left
            (reg.CompilerRegInterval 0 1 2)))
        (set!
          separated-left
          (reg.compiler-reg-interval-seq-append
            separated-left
            (reg.CompilerRegInterval 0 6 8)))
        (set!
          separated-left
          (reg.compiler-reg-interval-seq-append
            separated-left
            (reg.CompilerRegInterval 0 12 15)))
        (set!
          separated-right
          (reg.compiler-reg-interval-seq-append
            separated-right
            (reg.CompilerRegInterval 1 2 4)))
        (set!
          separated-right
          (reg.compiler-reg-interval-seq-append
            separated-right
            (reg.CompilerRegInterval 1 8 10)))
        (set!
          separated-right
          (reg.compiler-reg-interval-seq-append
            separated-right
            (reg.CompilerRegInterval 1 15 18)))
        (set!
          late-overlap-right
          (reg.compiler-reg-interval-seq-append
            late-overlap-right
            (reg.CompilerRegInterval 1 2 4)))
        (set!
          late-overlap-right
          (reg.compiler-reg-interval-seq-append
            late-overlap-right
            (reg.CompilerRegInterval 1 8 10)))
        (set!
          late-overlap-right
          (reg.compiler-reg-interval-seq-append
            late-overlap-right
            (reg.CompilerRegInterval 1 14 18)))
        (set!
          zero-left
          (reg.compiler-reg-interval-seq-append
            zero-left
            (reg.CompilerRegInterval 0 0 0)))
        (set!
          zero-right
          (reg.compiler-reg-interval-seq-append
            zero-right
            (reg.CompilerRegInterval 1 0 2)))
        (and
          (= (reg.compiler-reg-interval-seq-count appended) 10)
          (compiler-reg-test-interval-shape? appended 0 0 0 1)
          (compiler-reg-test-interval-shape? appended 9 9 18 19)
          (= (reg.compiler-reg-interval-seq-count prepended) 10)
          (compiler-reg-test-interval-shape? prepended 0 9 18 19)
          (compiler-reg-test-interval-shape? prepended 9 0 0 1)
          (= (reg.compiler-reg-interval-seq-count inserted) 3)
          (compiler-reg-test-interval-shape? inserted 0 0 0 1)
          (compiler-reg-test-interval-shape? inserted 1 1 2 3)
          (compiler-reg-test-interval-shape? inserted 2 2 4 5)
          ;; Touching boundaries after point zero remain non-overlapping.
          (not
            (reg.compiler-reg-interval-seq-overlaps?
              separated-left
              separated-right))
          ;; The ordered scan must continue far enough to find a late overlap.
          (reg.compiler-reg-interval-seq-overlaps?
            separated-left
            late-overlap-right)
          (not
            (reg.compiler-reg-interval-seq-overlaps-one?
              separated-left
              (reg.CompilerRegInterval 2 4 6)))
          ;; Entry-point touches preserve the prologue-home exception.
          (reg.compiler-reg-interval-seq-overlaps? zero-left zero-right))))))

(cfg
  test
  (test
    regalloc-dense-interval-sequence
    (test.assert-true
      (compiler-reg-dense-interval-seq-ok?)
      "dense interval growth preserves order and merge overlap boundaries")))

(cfg
  test
  (define (compiler-reg-dense-id-label-seqs-ok?) : bool
    (let
      [ids : reg.CompilerRegIdSeq (reg.compiler-reg-id-seq-with-capacity 4)]
      [id-snapshot : reg.CompilerRegIdSeq (reg.compiler-reg-id-seq-empty)]
      [id-prepended : reg.CompilerRegIdSeq (reg.compiler-reg-id-seq-empty)]
      [labels : reg.CompilerRegLabelSeq
        (reg.compiler-reg-label-seq-with-capacity 4)]
      [label-snapshot : reg.CompilerRegLabelSeq
        (reg.compiler-reg-label-seq-empty)]
      [entry-label : i64 (ir.compiler-ir-label "dense_seq_entry")]
      [body-label : i64 (ir.compiler-ir-label "dense_seq_body")]
      (begin
        (set! ids (reg.compiler-reg-id-seq-push ids cabi.compiler-reg-id-r12))
        (set! ids (reg.compiler-reg-id-seq-push ids cabi.compiler-reg-id-r13))
        ;; A retained snapshot has an exact logical length and prefix even while
        ;; the continuing builder fills its spare suffix.
        (set! id-snapshot (clone ids))
        (set! ids (reg.compiler-reg-id-seq-push ids cabi.compiler-reg-id-r12))
        (set!
          id-prepended
          (reg.compiler-reg-id-seq-prepend cabi.compiler-reg-id-rbx id-snapshot))
        (set! labels (reg.compiler-reg-label-seq-push labels entry-label))
        (set! labels (reg.compiler-reg-label-seq-push labels body-label))
        (set! label-snapshot (clone labels))
        (set! labels (reg.compiler-reg-label-seq-push labels entry-label))
        (and
          (= (reg.compiler-reg-id-seq-count id-snapshot) 2)
          (=
            (reg.compiler-reg-id-seq-ref id-snapshot 0)
            cabi.compiler-reg-id-r12)
          (=
            (reg.compiler-reg-id-seq-ref id-snapshot 1)
            cabi.compiler-reg-id-r13)
          (= (reg.compiler-reg-id-seq-count ids) 3)
          ;; Duplicate register IDs remain ordered rather than being setified.
          (= (reg.compiler-reg-id-seq-ref ids 2) cabi.compiler-reg-id-r12)
          (reg.compiler-reg-id-seq-contains? ids cabi.compiler-reg-id-r13)
          (= (reg.compiler-reg-id-seq-count id-prepended) 3)
          (=
            (reg.compiler-reg-id-seq-ref id-prepended 0)
            cabi.compiler-reg-id-rbx)
          (=
            (reg.compiler-reg-id-seq-ref id-prepended 1)
            cabi.compiler-reg-id-r12)
          (=
            (reg.compiler-reg-id-seq-ref id-prepended 2)
            cabi.compiler-reg-id-r13)
          (= (reg.compiler-reg-label-seq-count label-snapshot) 2)
          (= (reg.compiler-reg-label-seq-ref label-snapshot 0) entry-label)
          (= (reg.compiler-reg-label-seq-ref label-snapshot 1) body-label)
          (= (reg.compiler-reg-label-seq-count labels) 3)
          (= (reg.compiler-reg-label-seq-ref labels 2) entry-label)
          (reg.compiler-reg-label-seq-contains? labels body-label))))))

(cfg
  test
  (test
    regalloc-dense-register-and-label-sequences
    (test.assert-true
      (compiler-reg-dense-id-label-seqs-ok?)
      "dense register and label sequences preserve snapshots, order, and duplicates")))

(cfg
  test
  (define (compiler-reg-dense-var-types-ok?) : bool
    (let
      [base : reg.CompilerRegVarTypes
        (reg.compiler-reg-var-types-insert
          (reg.compiler-reg-var-types-insert
            (reg.compiler-reg-var-types-empty)
            2
            (ast.AstType.I64))
          5
          (ast.AstType.U64))]
      [extra : reg.CompilerRegVarTypes
        (reg.compiler-reg-var-types-insert
          (reg.compiler-reg-var-types-empty)
          5
          (ast.AstType.Bool))]
      [merged : reg.CompilerRegVarTypes
        (reg.compiler-reg-var-types-merge extra base)]
      (and
        (= (array-ref (struct-get base present) 2) 1)
        (= (array-ref (struct-get base present) 3) 0)
        (match (reg.compiler-reg-var-types-lookup base 2)
          [(reg.CompilerRegMaybeType.Some (ast.AstType.I64)) true]
          [_ false])
        (match (reg.compiler-reg-var-types-lookup base 3)
          [(reg.CompilerRegMaybeType.No) true]
          [_ false])
        ;; Merge overrides a present extra entry without mutating the published
        ;; base view retained by retry paths.
        (match (reg.compiler-reg-var-types-lookup base 5)
          [(reg.CompilerRegMaybeType.Some (ast.AstType.U64)) true]
          [_ false])
        (match (reg.compiler-reg-var-types-lookup merged 5)
          [(reg.CompilerRegMaybeType.Some (ast.AstType.Bool)) true]
          [_ false])))))

(cfg
  test
  (test
    regalloc-dense-var-types
    (test.assert-true
      (compiler-reg-dense-var-types-ok?)
      "dense var types preserve holes, exact types, growth, and merge isolation")))

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
        (reg.compiler-reg-xmm-clobbers-ok?)
        (compiler-reg-low-xmm-vector-boundaries-ok?))
      "ABI pools admit scalar XMM0/XMM1 while vector scratch boundaries stay explicit")))

(cfg
  test
  (test
    regalloc-xmm-abi-call-constraints
    (test.assert-true
      (and
        (reg.compiler-reg-xmm-abi-call-constraints-ok?)
        (reg.compiler-reg-xmm-shared-greedy-bank-ok?)
        (reg.compiler-reg-xmm-vector-class-reset-ok?))
      "ABI XMM pools enforce SysV volatile and Win64 nonvolatile call homes")))

(cfg
  test
  (test
    regalloc-vector-mask-homes
    (test.assert-true
      (and
        (reg.compiler-reg-vector-mask-homes-ok?)
        (reg.compiler-reg-mask-pressure-spill-home-ok?))
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
      (reg.compiler-reg-destructive-chain-ok?)
      "bounded destructive ties coalesce lhs/rhs chains and refuse clobber/noncomm-rhs/div")))

(cfg
  test
  (test
    regalloc-scalar-web-merge
    (test.assert-true
      (compiler-reg-color-web-merge-ok?)
      "order-independent webs merge a disjoint carry chain into one slot and still refuse an overlap")))

(cfg
  test
  (test
    regalloc-scalar-web-carry-priority
    (test.assert-true
      (compiler-reg-color-carry-priority-ok?)
      "a phi dst joins the loop carry's web rather than an interfering computed source")))

;; M-B2 scalar phi-web slot sharing. Both cases hand the colorer the SAME plan
;; intervals -- deliberately overlapping, which is what the conservative model
;; produces for a phi and its input, because it counts the input as live AT the
;; phi block -- so only the block shape decides. `entry` defines the input and
;; `merge`'s phi consumes it: with the input dead after the phi the two
;; edge-precise hulls are strictly ordered and one slot serves both; with the
;; input still live past the phi they genuinely interfere and keep two slots.
(cfg
  test
  (define (compiler-reg-color-phi-web-blocks [live-after-phi : bool]) : ir.CompilerIrBlockList
    (ir.compiler-ir-block-cons
      (ir.compiler-ir-block
        (ir.compiler-ir-label "entry")
        (ir.compiler-ir-instr-cons
          (ir.CompilerIrInstr.Mov
            1
            (ir.CompilerIrValue.I64 7)
            (reg.compiler-reg-i64-ty))
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "merge"))
            ir.CompilerIrInstrList.Nil)))
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "merge")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Phi
              0
              (ir.compiler-ir-phi-input-cons
                (ir.CompilerIrValue.Var 1)
                (ir.compiler-ir-label "entry")
                ir.CompilerIrPhiInputList.Nil)
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Return
                (ir.CompilerIrMaybeValue.Some
                  (ir.CompilerIrValue.Var
                    (if live-after-phi
                      1
                      0))))
              ir.CompilerIrInstrList.Nil)))
        ir.CompilerIrBlockList.Nil))))

(cfg
  test
  (define (compiler-reg-color-phi-web-intervals) : reg.CompilerRegIntervalSeq
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 1 0 6)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 0 4 6)
        (reg.compiler-reg-interval-seq-empty)))))

(cfg
  test
  (define (compiler-reg-color-phi-web-coloring [live-after-phi : bool]) : reg.CompilerRegColoring
    (reg.compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (reg.CompilerRegPlan.Plan
        (reg.compiler-reg-color-spill-sharing-assignments 2)
        (live.compiler-live-set-empty)
        (compiler-reg-color-phi-web-intervals)
        (reg.compiler-reg-color-spill-sharing-types 2)
        (reg.compiler-reg-call-split-empty)
        (reg.compiler-reg-split-plan-empty))
      (live.compiler-live-set-empty)
      ir.CompilerIrParamList.Nil
      (compiler-reg-color-phi-web-blocks live-after-phi)
      2
      2
      (live.compiler-live-set-empty))))

(cfg
  test
  (define (compiler-reg-color-phi-web-slot-sharing-ok?) : bool
    (match (compiler-reg-color-phi-web-coloring false)
      [(reg.CompilerRegColoring.Remap share-remap share-slots)
        (match (compiler-reg-color-phi-web-coloring true)
          [(reg.CompilerRegColoring.Remap live-remap live-slots)
            (and
              (= share-slots 1)
              (= (array-ref share-remap 0) (array-ref share-remap 1))
              (= live-slots 2)
              (not (= (array-ref live-remap 0) (array-ref live-remap 1))))]
          [(reg.CompilerRegColoring.None) false])]
      [(reg.CompilerRegColoring.None) false])))

;; M-B3 order-independent web construction. The loop below is the shape every
;; spilled loop carry in intern_table's it-intern-slice has: a header phi (%0)
;; fed by an entry constant (%3) and by a latch phi (%2), with a third phi (%1)
;; on the path between them. All four EP hulls are pairwise disjoint --
;; %3 dies in `entry`, %0 in `body`, %1 in `merge`, %2 in `latch` -- so ONE slot
;; serves the whole chain.
;;
;; The pre-M-B3 monotone rule could not see that. Visiting `header` first it
;; joined %2 to %0 (the only pair whose hulls are ordered the way the rule
;; wanted), which pushed the web's running end out to %2's; %3 and %1 both start
;; before that end and were refused even though neither overlaps anything in the
;; web, and %1's own web could never be joined to a second web anyway. Result: 3
;; slots and two surviving slot-to-slot phi copies per iteration. With all-pairs
;; disjointness plus web-to-web merging the chain collapses to 1 slot.
;;
;; `overlap` injects a genuine interference to prove the test still refuses: the
;; exit returns %1, so %1 stays live from `merge` past `latch` and really does
;; overlap %2. %1 must then keep its own slot.
(cfg
  test
  (define (compiler-reg-color-web-merge-blocks [overlap : bool]) : ir.CompilerIrBlockList
    (ir.compiler-ir-block-cons
      (ir.compiler-ir-block
        (ir.compiler-ir-label "entry")
        (ir.compiler-ir-instr-cons
          (ir.CompilerIrInstr.Mov
            3
            (ir.CompilerIrValue.I64 7)
            (reg.compiler-reg-i64-ty))
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
            ir.CompilerIrInstrList.Nil)))
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "header")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Phi
              0
              (ir.compiler-ir-phi-input-cons
                (ir.CompilerIrValue.Var 2)
                (ir.compiler-ir-label "latch")
                (ir.compiler-ir-phi-input-cons
                  (ir.CompilerIrValue.Var 3)
                  (ir.compiler-ir-label "entry")
                  ir.CompilerIrPhiInputList.Nil))
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Var 0)
                (ir.compiler-ir-label "body")
                (ir.compiler-ir-label "exit"))
              ir.CompilerIrInstrList.Nil)))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "body")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "merge"))
              ir.CompilerIrInstrList.Nil))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "merge")
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Phi
                  1
                  (ir.compiler-ir-phi-input-cons
                    (ir.CompilerIrValue.Var 0)
                    (ir.compiler-ir-label "body")
                    ir.CompilerIrPhiInputList.Nil)
                  (reg.compiler-reg-i64-ty))
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "latch"))
                  ir.CompilerIrInstrList.Nil)))
            (ir.compiler-ir-block-cons
              (ir.compiler-ir-block
                (ir.compiler-ir-label "latch")
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Phi
                    2
                    (ir.compiler-ir-phi-input-cons
                      (ir.CompilerIrValue.Var 1)
                      (ir.compiler-ir-label "merge")
                      ir.CompilerIrPhiInputList.Nil)
                    (reg.compiler-reg-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
                    ir.CompilerIrInstrList.Nil)))
              (ir.compiler-ir-block-cons
                (ir.compiler-ir-block
                  (ir.compiler-ir-label "exit")
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Return
                      (ir.CompilerIrMaybeValue.Some
                        (if overlap
                          (ir.CompilerIrValue.Var 1)
                          (ir.CompilerIrValue.I64 0))))
                    ir.CompilerIrInstrList.Nil))
                ir.CompilerIrBlockList.Nil))))))))

;; Deliberately overlapping conservative intervals, as in the M-B2 fixture above:
;; the ordinary disjoint-interval walk can share nothing, so every merge in the
;; result is the web logic's doing.
(cfg
  test
  (define (compiler-reg-color-web-merge-intervals) : reg.CompilerRegIntervalSeq
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 0 0 9)
      (reg.compiler-reg-interval-seq-prepend
        (reg.CompilerRegInterval 1 1 9)
        (reg.compiler-reg-interval-seq-prepend
          (reg.CompilerRegInterval 2 2 9)
          (reg.compiler-reg-interval-seq-prepend
            (reg.CompilerRegInterval 3 3 9)
            (reg.compiler-reg-interval-seq-empty)))))))

(cfg
  test
  (define (compiler-reg-color-web-merge-coloring [overlap : bool]) : reg.CompilerRegColoring
    (reg.compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (reg.CompilerRegPlan.Plan
        (reg.compiler-reg-color-spill-sharing-assignments 4)
        (live.compiler-live-set-empty)
        (compiler-reg-color-web-merge-intervals)
        (reg.compiler-reg-color-spill-sharing-types 4)
        (reg.compiler-reg-call-split-empty)
        (reg.compiler-reg-split-plan-empty))
      (live.compiler-live-set-empty)
      ir.CompilerIrParamList.Nil
      (compiler-reg-color-web-merge-blocks overlap)
      4
      4
      (live.compiler-live-set-empty))))

(cfg
  test
  (define (compiler-reg-color-web-merge-ok?) : bool
    (match (compiler-reg-color-web-merge-coloring false)
      [(reg.CompilerRegColoring.Remap merged-remap merged-slots)
        (match (compiler-reg-color-web-merge-coloring true)
          [(reg.CompilerRegColoring.Remap overlap-remap overlap-slots)
            (and
              ;; Disjoint chain: entry constant, header phi, mid phi and latch
              ;; phi all share ONE slot.
              (= merged-slots 1)
              (= (array-ref merged-remap 0) (array-ref merged-remap 1))
              (= (array-ref merged-remap 0) (array-ref merged-remap 2))
              (= (array-ref merged-remap 0) (array-ref merged-remap 3))
              ;; Genuine interference still refuses: %1 outlives %2's definition.
              (> overlap-slots 1)
              (not (= (array-ref overlap-remap 1) (array-ref overlap-remap 2))))]
          [(reg.CompilerRegColoring.None) false])]
      [(reg.CompilerRegColoring.None) false])))

;; M-B3 loop-carry priority. `merge`'s phi (%2) sits in the MIDDLE of the carry
;; chain -- `header`'s phi (%0) is fed by the latch phi (%3), not by %2 -- so when
;; `merge` is visited %2 is still a fresh singleton and both of its sources are
;; live candidates. It can join the web of either, but not both: the carry %0 is
;; live through `right` to feed %2 while the computed %1 is defined in `left`, so
;; %0 and %1 overlap. The input list names the COMPUTED source first, so a single
;; in-order pass takes %1 -- and the carry then pays a slot-to-slot copy on the
;; `right` edge, on the latch edge and on the back edge. Offering phi-defined
;; sources first puts %2 in the CARRY's web instead, collapsing the whole chain.
;; Exactly the `%208 = phi [%187, if_else.36], [%210, if_then.35]` decision in
;; it-intern-slice, where %187 is an `add` that overlaps the carry %210.
(cfg
  test
  (define (compiler-reg-color-carry-priority-blocks) : ir.CompilerIrBlockList
    (ir.compiler-ir-block-cons
      (ir.compiler-ir-block
        (ir.compiler-ir-label "entry")
        (ir.compiler-ir-instr-cons
          (ir.CompilerIrInstr.Mov
            4
            (ir.CompilerIrValue.I64 7)
            (reg.compiler-reg-i64-ty))
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
            ir.CompilerIrInstrList.Nil)))
      (ir.compiler-ir-block-cons
        (ir.compiler-ir-block
          (ir.compiler-ir-label "header")
          (ir.compiler-ir-instr-cons
            (ir.CompilerIrInstr.Phi
              0
              (ir.compiler-ir-phi-input-cons
                (ir.CompilerIrValue.Var 3)
                (ir.compiler-ir-label "latch")
                (ir.compiler-ir-phi-input-cons
                  (ir.CompilerIrValue.Var 4)
                  (ir.compiler-ir-label "entry")
                  ir.CompilerIrPhiInputList.Nil))
              (reg.compiler-reg-i64-ty))
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Branch
                (ir.CompilerIrValue.Var 0)
                (ir.compiler-ir-label "left")
                (ir.compiler-ir-label "right"))
              ir.CompilerIrInstrList.Nil)))
        (ir.compiler-ir-block-cons
          (ir.compiler-ir-block
            (ir.compiler-ir-label "left")
            (ir.compiler-ir-instr-cons
              (ir.CompilerIrInstr.Mov
                1
                (ir.CompilerIrValue.I64 9)
                (reg.compiler-reg-i64-ty))
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "merge"))
                ir.CompilerIrInstrList.Nil)))
          (ir.compiler-ir-block-cons
            (ir.compiler-ir-block
              (ir.compiler-ir-label "right")
              (ir.compiler-ir-instr-cons
                (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "merge"))
                ir.CompilerIrInstrList.Nil))
            (ir.compiler-ir-block-cons
              (ir.compiler-ir-block
                (ir.compiler-ir-label "merge")
                (ir.compiler-ir-instr-cons
                  (ir.CompilerIrInstr.Phi
                    2
                    (ir.compiler-ir-phi-input-cons
                      (ir.CompilerIrValue.Var 1)
                      (ir.compiler-ir-label "left")
                      (ir.compiler-ir-phi-input-cons
                        (ir.CompilerIrValue.Var 0)
                        (ir.compiler-ir-label "right")
                        ir.CompilerIrPhiInputList.Nil))
                    (reg.compiler-reg-i64-ty))
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "latch"))
                    ir.CompilerIrInstrList.Nil)))
              (ir.compiler-ir-block-cons
                (ir.compiler-ir-block
                  (ir.compiler-ir-label "latch")
                  (ir.compiler-ir-instr-cons
                    (ir.CompilerIrInstr.Phi
                      3
                      (ir.compiler-ir-phi-input-cons
                        (ir.CompilerIrValue.Var 2)
                        (ir.compiler-ir-label "merge")
                        ir.CompilerIrPhiInputList.Nil)
                      (reg.compiler-reg-i64-ty))
                    (ir.compiler-ir-instr-cons
                      (ir.CompilerIrInstr.Jump (ir.compiler-ir-label "header"))
                      ir.CompilerIrInstrList.Nil)))
                ir.CompilerIrBlockList.Nil))))))))

(cfg
  test
  (define (compiler-reg-color-carry-priority-intervals) : reg.CompilerRegIntervalSeq
    (reg.compiler-reg-interval-seq-prepend
      (reg.CompilerRegInterval 4 4 11)
      (compiler-reg-color-web-merge-intervals))))

(cfg
  test
  (define (compiler-reg-color-carry-priority-coloring) : reg.CompilerRegColoring
    (reg.compiler-reg-color-stack-slots
      (ast.ast-node-pool-reader-type-segment-bases)
      (reg.CompilerRegPlan.Plan
        (reg.compiler-reg-color-spill-sharing-assignments 5)
        (live.compiler-live-set-empty)
        (compiler-reg-color-carry-priority-intervals)
        (reg.compiler-reg-color-spill-sharing-types 5)
        (reg.compiler-reg-call-split-empty)
        (reg.compiler-reg-split-plan-empty))
      (live.compiler-live-set-empty)
      ir.CompilerIrParamList.Nil
      (compiler-reg-color-carry-priority-blocks)
      5
      5
      (live.compiler-live-set-empty))))

(cfg
  test
  (define (compiler-reg-color-carry-priority-ok?) : bool
    (match (compiler-reg-color-carry-priority-coloring)
      [(reg.CompilerRegColoring.Remap remap _)
        (and
          ;; The merge phi lands in the loop carry's web ...
          (= (array-ref remap 2) (array-ref remap 0))
          ;; ... and NOT in the computed value's, which interferes with it.
          (not (= (array-ref remap 2) (array-ref remap 1))))]
      [(reg.CompilerRegColoring.None) false])))

(define (compiler-regalloc-self-test-failure-message [name : String]) : String
  (string.append "regalloc self-test failed: " name))

(define (compiler-regalloc-self-test-require! [name : String] [ok : bool]) : unit
  (if ok
    unit
    (io.panic (compiler-regalloc-self-test-failure-message name))))

(define (compiler-regalloc-core-self-test?) : bool
  (begin
    (compiler-regalloc-self-test-require!
      "compiler-reg-low-bit-index32-powers-ok?"
      (cfg test (compiler-reg-low-bit-index32-powers-ok? 0 1) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-reuse-ok?"
      (reg.compiler-reg-reuse-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-f64-reuse-ok?"
      (reg.compiler-reg-f64-reuse-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-overlap-spill-ok?"
      (reg.compiler-reg-overlap-spill-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-f64-overlap-spill-ok?"
      (reg.compiler-reg-f64-overlap-spill-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-live-ok?"
      (reg.compiler-reg-call-live-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-f64-call-live-ok?"
      (reg.compiler-reg-f64-call-live-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-arg-ok?"
      (reg.compiler-reg-call-arg-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-f64-call-arg-ok?"
      (reg.compiler-reg-f64-call-arg-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-ineligible-ok?"
      (reg.compiler-reg-ineligible-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-target-clobbers-ok?"
      (reg.compiler-reg-target-clobbers-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-xmm-clobbers-ok?"
      (reg.compiler-reg-xmm-clobbers-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-xmm-abi-call-constraints-ok?"
      (reg.compiler-reg-xmm-abi-call-constraints-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-xmm-shared-greedy-bank-ok?"
      (reg.compiler-reg-xmm-shared-greedy-bank-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-xmm-vector-class-reset-ok?"
      (reg.compiler-reg-xmm-vector-class-reset-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-coalesce-ok?"
      (reg.compiler-reg-coalesce-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-liveness-handle-ok?"
      (cfg test (compiler-reg-liveness-handle-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-liveness-handle-phi-ok?"
      (cfg test (compiler-reg-liveness-handle-phi-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-xmm-physical-ownership-ok?"
      (cfg test (compiler-reg-xmm-physical-ownership-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-dense-mask-on-vector-homes-ok?"
      (cfg test (compiler-reg-dense-mask-on-vector-homes-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-vector-mask-homes-ok?"
      (reg.compiler-reg-vector-mask-homes-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-mask-pressure-spill-home-ok?"
      (reg.compiler-reg-mask-pressure-spill-home-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-segmented-interference-ok?"
      (reg.compiler-reg-segmented-interference-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-hole-aware-register-reuse-ok?"
      (reg.compiler-reg-hole-aware-register-reuse-ok?))
    true))

(define (compiler-regalloc-scalar-self-test?) : bool
  (begin
    (compiler-regalloc-self-test-require!
      "compiler-reg-early-exit-general-ok?"
      (cfg test (compiler-reg-early-exit-general-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-early-exit-float-guard-refused-ok?"
      (cfg test (compiler-reg-early-exit-float-guard-refused-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-cold-call-split-ok?"
      (cfg test (compiler-reg-cold-call-split-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-call-live-ok?"
      (reg.compiler-reg-scalar-call-live-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-f64-call-live-ok?"
      (reg.compiler-reg-scalar-f64-call-live-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-win64-f64-call-live-ok?"
      (reg.compiler-reg-scalar-win64-f64-call-live-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-handle-eligible-ok?"
      (reg.compiler-reg-scalar-handle-eligible-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-handle-call-arg-ok?"
      (reg.compiler-reg-scalar-handle-call-arg-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-indirect-call-arg-ok?"
      (reg.compiler-reg-scalar-indirect-call-arg-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-c-abi-store-result-call-arg-ok?"
      (reg.compiler-reg-scalar-c-abi-store-result-call-arg-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-win64-indirect-call-arg-cap-ok?"
      (reg.compiler-reg-scalar-win64-indirect-call-arg-cap-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-linux-param-registers-ok?"
      (cfg test (compiler-reg-scalar-linux-param-registers-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-windows-param-registers-ok?"
      (cfg test (compiler-reg-scalar-windows-param-registers-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-float-param-registers-ok?"
      (cfg test (compiler-reg-scalar-float-param-registers-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-win64-float-param-registers-ok?"
      (cfg test (compiler-reg-scalar-win64-float-param-registers-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-mixed-float-call-args-ok?"
      (cfg test (compiler-reg-scalar-mixed-float-call-args-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-win64-mixed-float-call-args-ok?"
      (cfg test (compiler-reg-scalar-win64-mixed-float-call-args-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-windows-rsi-rdi-pool-ok?"
      (cfg test (compiler-reg-scalar-windows-rsi-rdi-pool-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-win64-arg-result-prefs-ok?"
      (cfg test (compiler-reg-win64-arg-result-prefs-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-indirect-call-arg-prefs-ok?"
      (cfg test (compiler-reg-indirect-call-arg-prefs-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-param-clobber-ok?"
      (cfg test (compiler-reg-scalar-param-clobber-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-param-const-shift-pin-ok?"
      (cfg test (compiler-reg-scalar-param-const-shift-pin-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-param-var-shift-pin-ok?"
      (cfg test (compiler-reg-scalar-param-var-shift-pin-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-param-dead-before-call-pin-ok?"
      (cfg test (compiler-reg-scalar-param-dead-before-call-pin-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-param-rdx-div-span-ok?"
      (cfg test (compiler-reg-scalar-param-rdx-div-span-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-param-rcx-shift-span-ok?"
      (cfg test (compiler-reg-scalar-param-rcx-shift-span-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-param-pin-coalesce-demote-ok?"
      (cfg test (compiler-reg-scalar-param-pin-coalesce-demote-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-aggregate-param-pinned-ok?"
      (cfg test (compiler-reg-scalar-aggregate-param-pinned-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-function-intervals-ok?"
      (reg.compiler-reg-scalar-function-intervals-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-interval-guardrail-ok?"
      (reg.compiler-reg-scalar-interval-guardrail-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-loop-backedge-ok?"
      (reg.compiler-reg-scalar-loop-backedge-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-zero-call-caller-saved-ok?"
      (reg.compiler-reg-scalar-zero-call-caller-saved-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-zero-call-param-conflict-ok?"
      (cfg test (compiler-reg-scalar-zero-call-param-conflict-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-caller-saved-clobber-ok?"
      (reg.compiler-reg-scalar-caller-saved-clobber-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-call-spanning-caller-saved-ok?"
      (reg.compiler-reg-scalar-call-spanning-caller-saved-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-call-spanning-multiblock-local-ok?"
      (cfg test (compiler-reg-scalar-call-spanning-multiblock-local-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scalar-call-spanning-multiblock-boundary-ok?"
      (cfg
        test
        (compiler-reg-scalar-call-spanning-multiblock-boundary-ok?)
        true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-edge-copy-linear-ok?"
      (cfg test (compiler-reg-edge-copy-linear-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-edge-copy-backedge-ok?"
      (cfg test (compiler-reg-edge-copy-backedge-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-edge-copy-critical-refusal-ok?"
      (cfg test (compiler-reg-edge-copy-critical-refusal-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-split-rewrite-ok?"
      (cfg test (compiler-reg-loop-split-rewrite-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-split-multiple-rewrite-ok?"
      (cfg test (compiler-reg-loop-split-multiple-rewrite-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-leaf-csr-split-ok?"
      (cfg test (compiler-reg-leaf-csr-split-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-split-low-benefit-ok?"
      (cfg test (compiler-reg-loop-split-low-benefit-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-split-phi-region-refusal-ok?"
      (cfg test (compiler-reg-loop-split-phi-region-refusal-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-split-rcx-rdx-candidates-ok?"
      (cfg test (compiler-reg-loop-split-rcx-rdx-candidates-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-split-fixed-clobber-scan-ok?"
      (cfg test (compiler-reg-loop-split-fixed-clobber-scan-ok?) true))
    true))

(define (compiler-regalloc-storage-self-test?) : bool
  (begin
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-classifier-ok?"
      (cfg test (compiler-reg-remat-classifier-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-discount-weights-ok?"
      (cfg test (compiler-reg-remat-discount-weights-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-spill-weight-eviction-ok?"
      (cfg test (compiler-reg-remat-spill-weight-eviction-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-rewrite-shape-ok?"
      (cfg test (compiler-reg-remat-rewrite-shape-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-register-conflict-ok?"
      (cfg test (compiler-reg-remat-register-conflict-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-caller-clobber-refusal-ok?"
      (cfg test (compiler-reg-remat-caller-clobber-refusal-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-addr-of-source-refusal-ok?"
      (cfg test (compiler-reg-remat-addr-of-source-refusal-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-global-mov-rewrite-ok?"
      (cfg test (compiler-reg-remat-global-mov-rewrite-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-global-load-rewrite-ok?"
      (cfg test (compiler-reg-remat-global-load-rewrite-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-global-gep-rewrite-ok?"
      (cfg test (compiler-reg-remat-global-gep-rewrite-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-remat-global-mutation-refusal-ok?"
      (cfg test (compiler-reg-remat-global-mutation-refusal-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-spill-weight-eviction-ok?"
      (cfg test (compiler-reg-spill-weight-eviction-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-loop-spill-weight-eviction-ok?"
      (cfg test (compiler-reg-loop-spill-weight-eviction-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-span-counts-ok?"
      (cfg test (compiler-reg-call-span-counts-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-call-span-census-ok?"
      (cfg test (compiler-reg-call-span-census-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-group-pair-widening-ok?"
      (cfg test (compiler-reg-group-pair-widening-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-switch-scratch-vregs-ok?"
      (reg.compiler-reg-switch-scratch-vregs-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-bounds-scratch-vregs-ok?"
      (reg.compiler-reg-bounds-scratch-vregs-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-memory-scratch-vregs-ok?"
      (reg.compiler-reg-memory-scratch-vregs-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-early-scratch-model-ok?"
      (reg.compiler-reg-early-scratch-model-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-greedy-live-union-invariant-ok?"
      (reg.compiler-reg-greedy-live-union-invariant-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scratch-default-pool-target-invariant-ok?"
      (reg.compiler-reg-scratch-default-pool-target-invariant-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-scratch-callee-saved-registers-ok?"
      (reg.compiler-reg-scratch-callee-saved-registers-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-early-scratch-never-spills-ok?"
      (reg.compiler-reg-early-scratch-never-spills-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-early-scratch-exclusion-rehomes-ok?"
      (reg.compiler-reg-early-scratch-exclusion-rehomes-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-indexed-lookups-ok?"
      (reg.compiler-reg-indexed-lookups-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-stack-group-ok?"
      (reg.compiler-reg-color-stack-group-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-spill-slot-sharing-ok?"
      (reg.compiler-reg-color-spill-slot-sharing-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-fusion-pin-slots-ok?"
      (reg.compiler-reg-color-fusion-pin-slots-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-phi-web-slot-sharing-ok?"
      (cfg test (compiler-reg-color-phi-web-slot-sharing-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-web-merge-ok?"
      (cfg test (compiler-reg-color-web-merge-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-carry-priority-ok?"
      (cfg test (compiler-reg-color-carry-priority-ok?) true))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-spill-param-pins-ok?"
      (reg.compiler-reg-color-spill-param-pins-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-spill-hole-demand-ok?"
      (reg.compiler-reg-color-spill-hole-demand-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-spill-scratch-demand-ok?"
      (reg.compiler-reg-color-spill-scratch-demand-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-vector-stack-slots-ok?"
      (reg.compiler-reg-color-vector-stack-slots-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-vector-stack-mask-words-ok?"
      (reg.compiler-reg-vector-stack-mask-words-ok?))
    (compiler-regalloc-self-test-require!
      "compiler-reg-color-storage-ranges-ok?"
      (reg.compiler-reg-color-storage-ranges-ok?))
    true))

(define (compiler-regalloc-self-test) : i64
  (begin
    (compiler-regalloc-core-self-test?)
    (compiler-regalloc-scalar-self-test?)
    (compiler-regalloc-storage-self-test?)
    42))

(cfg
  test
  (test
    regalloc-call-span-census
    (test.assert-i64-eq
      (compiler-regalloc-self-test)
      42
      "regalloc call-span census fixture result")))