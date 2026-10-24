(import compiler_backend_home_origins as homes)
(import compiler_ir_types as ir)
(import compiler_ir_text as ir_text)
(import compiler_regalloc as regalloc)
(import compiler_liveness as live)
(import compiler_owned_view as owned_view)
(import compiler_abi as abi)
(import stdlib.test)
(import stdlib.io)
(import stdlib.iterator)

(define (home-bindings-ok [result : homes.CompilerBackendHomeBindingsResult]) : homes.CompilerBackendHomeBindingList
  (match result
    [(Ok bindings) bindings]
    [(Err message) (io.panic message)]))

(define (home-query-ok
  [bindings : (& homes.CompilerBackendHomeBindingList)]
  [emitted : i64]
  [query : homes.CompilerBackendHomeQuery]
  [expected : i64]) : unit
  (match (homes.compiler-backend-home-resolve bindings emitted query)
    [(Ok actual) (test.assert-i64-eq actual expected "original logical home")]
    [(Err message) (io.panic message)]))

(define (home-query-error
  [bindings : (& homes.CompilerBackendHomeBindingList)]
  [emitted : i64]
  [query : homes.CompilerBackendHomeQuery]) : unit
  (test.assert-true
    (match (homes.compiler-backend-home-resolve bindings emitted query)
      [(Err _) true]
      [_ false])
    "ambiguous or unbound original home rejects"))

(define (home-origin-coloring-test) : unit
  (let
    [map : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [instr : ir.CompilerIrInstr (Mov 2 (Var 1) (I64))]
    (set! (array-ref map 0) 2)
    (set! (array-ref map 1) 0)
    (set! (array-ref map 2) 0)
    (set! (array-ref map 3) 1)
    (let
      [coloring : regalloc.CompilerRegColoring
        (Remap (owned_view.compiler-owned-shared-view map) 3)]
      [actual : ir.CompilerIrInstr
        (regalloc.compiler-reg-remap-instr (& map) (& instr))]
      [bindings : homes.CompilerBackendHomeBindingList
        (home-bindings-ok
          (homes.compiler-backend-home-bindings (& instr) (& coloring) 4))]
      (test.assert-true
        (match actual
          [(Mov dst (Var src) _) (and (= dst 0) (= src 0))]
          [_ false])
        "real coloring aliases the emitted IDs")
      (test.assert-true
        (match (& instr)
          [(Mov dst (Var src) _) (and (= dst 2) (= src 1))]
          [_ false])
        "real remapper leaves original instruction intact")
      (home-query-ok (& bindings) 0 (AnyUse) 1)
      (home-query-ok (& bindings) 0 (Definition) 2)
      (home-query-ok (& bindings) 0 (Use 0) 1)
      (home-query-error (& bindings) 0 (Use 1))
      (home-query-error (& bindings) 3 (AnyUse))
      (home-query-error (& bindings) -1 (AnyUse))
      (home-query-error (& bindings) 0 (Use -1))
      (let
        [exact : (__tl_dyn-array homes.CompilerBackendHomeBinding)
          (__tl_make-array homes.CompilerBackendHomeBinding bindings.len)]
        [spare : (__tl_dyn-array homes.CompilerBackendHomeBinding)
          (__tl_make-array homes.CompilerBackendHomeBinding (+ bindings.len 3))]
        (for [index (iterator.range 0 bindings.len)]
          (set!
            (array-ref exact index)
            (clone (array-ref bindings.slots index)))
          (set!
            (array-ref spare index)
            (clone (array-ref bindings.slots index))))
        (let
          [exact-view : homes.CompilerBackendHomeBindingList
            (homes.CompilerBackendHomeBindingList exact bindings.len)]
          [spare-view : homes.CompilerBackendHomeBindingList
            (homes.CompilerBackendHomeBindingList spare bindings.len)]
          (home-query-ok (& exact-view) 0 (AnyUse) 1)
          (home-query-ok (& spare-view) 0 (Definition) 2)))
      (set! (array-ref map 1) 3)
      (home-query-ok (& bindings) 0 (AnyUse) 1)
      (let
        [other : homes.CompilerBackendHomeBindingList
          (home-bindings-ok
            (homes.compiler-backend-home-bindings (& instr) (& coloring) 4))]
        (home-query-ok (& other) 3 (AnyUse) 1)
        (home-query-ok (& bindings) 0 (AnyUse) 1)))
    (let
      [identity : regalloc.CompilerRegColoring (None)]
      [bindings : homes.CompilerBackendHomeBindingList
        (home-bindings-ok
          (homes.compiler-backend-home-bindings (& instr) (& identity) 4))]
      (home-query-ok (& bindings) 1 (AnyUse) 1)
      (home-query-ok (& bindings) 2 (Definition) 2))))

(define (home-origin-ambiguous-use-test) : unit
  (let
    [map : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [instr : ir.CompilerIrInstr (BinOp 3 (Add) (Var 1) (Var 2) (I64))]
    (set! (array-ref map 0) 2)
    (set! (array-ref map 1) 0)
    (set! (array-ref map 2) 0)
    (set! (array-ref map 3) 1)
    (let
      [coloring : regalloc.CompilerRegColoring
        (Remap (owned_view.compiler-owned-shared-view map) 3)]
      [bindings : homes.CompilerBackendHomeBindingList
        (home-bindings-ok
          (homes.compiler-backend-home-bindings (& instr) (& coloring) 4))]
      (home-query-error (& bindings) 0 (AnyUse))
      (home-query-ok (& bindings) 0 (Use 0) 1)
      (home-query-ok (& bindings) 0 (Use 1) 2)
      (home-query-ok (& bindings) 1 (Definition) 3)
      (let
        [repeated : ir.CompilerIrInstr (BinOp 3 (Add) (Var 1) (Var 1) (I64))]
        [repeated-bindings : homes.CompilerBackendHomeBindingList
          (home-bindings-ok
            (homes.compiler-backend-home-bindings (& repeated) (& coloring) 4))]
        (home-query-ok (& repeated-bindings) 0 (AnyUse) 1))
      (let
        [literal : ir.CompilerIrInstr (BinOp 3 (Add) (I64 5) (Var 2) (I64))]
        [literal-bindings : homes.CompilerBackendHomeBindingList
          (home-bindings-ok
            (homes.compiler-backend-home-bindings (& literal) (& coloring) 4))]
        (home-query-error (& literal-bindings) 0 (Use 0))
        (home-query-ok (& literal-bindings) 0 (Use 1) 2))
      (test.assert-true
        (match (homes.compiler-backend-home-bindings (& instr) (& coloring) 2)
          [(Err _) true]
          [_ false])
        "original IDs cannot exceed logical extent")
      (set! (array-ref map 1) -1)
      (test.assert-true
        (match (homes.compiler-backend-home-bindings (& instr) (& coloring) 4)
          [(Err _) true]
          [_ false])
        "unmapped live use rejects"))))

(define (home-origin-address-test) : unit
  (let
    [map : (__tl_dyn-array i64) (__tl_make-array i64 10)]
    [original : ir.CompilerIrInstr (AddrOf 3 7)]
    (for [index (iterator.range 0 10)]
      (set! (array-ref map index) index))
    (set! (array-ref map 7) 1)
    (let
      [emitted : ir.CompilerIrInstr
        (regalloc.compiler-reg-remap-instr (& map) (& original))]
      [coloring : regalloc.CompilerRegColoring (Remap map 10)]
      [bindings : homes.CompilerBackendHomeBindingList
        (home-bindings-ok
          (homes.compiler-backend-home-bindings-checked
            (& original)
            (& emitted)
            (& coloring)
            10
            10))]
      (home-query-ok (& bindings) 1 (Address) 7)
      (home-query-error (& bindings) 1 (AnyUse))
      (let
        [wrong : ir.CompilerIrInstr (AddrOf 3 2)]
        (test.assert-true
          (match (homes.compiler-backend-home-bindings-checked
            (& original)
            (& wrong)
            (& coloring)
            10
            10)
            [(Err _) true]
            [_ false])
          "changed storage identity rejects"))
      (let
        [wrong : ir.CompilerIrInstr (AddrOf 3 10)]
        (test.assert-true
          (match (homes.compiler-backend-home-bindings
            (& wrong)
            (& coloring)
            10)
            [(Err _) true]
            [_ false])
          "raw storage home bounds are checked")))))

(define (home-origin-parameter-test) : unit
  (let
    [map : (__tl_dyn-array i64) (__tl_make-array i64 10)]
    [params : (__tl_dyn-array ir.CompilerIrParam)
      (__tl_make-array ir.CompilerIrParam 3)]
    [blocks : (__tl_dyn-array ir.CompilerIrBlock)
      (__tl_make-array ir.CompilerIrBlock 3)]
    (for [index (iterator.range 0 10)]
      (set! (array-ref map index) index))
    (set! (array-ref map 7) 1)
    (set! (array-ref map 8) 1)
    (set! (array-ref params 0) (Param "arg" (I64) 7))
    (set!
      (array-ref blocks 0)
      (Block 10 (ir.compiler-ir-instr-seq1 (Mov 8 (Var 7) (I64)))))
    (let
      [original : ir.CompilerIrBlockList
        (Array (ir.CompilerIrBlockSeq blocks 1))]
      [placed : ir.CompilerIrBlockList
        (regalloc.compiler-reg-remap-blocks (& map) (& original))]
      [input : homes.CompilerBackendHomePlanInput
        (homes.CompilerBackendHomePlanInput
          44
          10
          10
          (ir.CompilerIrParamSeq params 1)
          original
          placed
          (Remap map 10)
          (live.compiler-live-set-empty))]
      [plan : homes.CompilerBackendHomePlan
        (match (homes.compiler-backend-home-plan-build (& input))
          [(Ok result) result]
          [(Err message) (io.panic message)])]
      (for [kind (iterator.range 0 3)]
        (match (homes.compiler-backend-home-plan-resolve
          (& plan)
          44
          10
          (if (= kind 0)
            -1
            0)
          1
          (if (= kind 0)
            (Parameter)
            (if (= kind 1)
              (Definition)
              (AnyUse))))
          [(Err message) (io.panic message)]
          [(Ok home)
            (test.assert-i64-eq
              home.id
              (if (= kind 1)
                8
                7)
              "entry versus body identity")
            (test.assert-i64-eq home.bytes 8 "scalar parameter capacity")]))
      (test.assert-true
        (match (homes.compiler-backend-home-plan-resolve
          (& plan)
          44
          20
          0
          1
          (Parameter))
          [(Err _) true]
          [_ false])
        "parameter authority requires its entry block")
      (test.assert-true
        (match (homes.compiler-backend-home-plan-resolve
          (& plan)
          44
          10
          -1
          1
          (Definition))
          [(Err _) true]
          [_ false])
        "body definition cannot substitute for parameter authority")
      (home-query-error (& plan.parameters) 1 (AnyUse))
      (for [invalid (iterator.range 0 4)]
        (let
          [bad : homes.CompilerBackendHomePlanInput (clone input)]
          [bad-params : (__tl_dyn-array ir.CompilerIrParam)
            (__tl_make-array ir.CompilerIrParam 2)]
          (set!
            (array-ref bad-params 0)
            (Param
              "arg"
              (I64)
              (if (= invalid 2)
                10
                7)))
          (set! (array-ref bad-params 1) (Param "duplicate" (I64) 7))
          (set!
            bad.params
            (ir.CompilerIrParamSeq
              bad-params
              (if (= invalid 0)
                -1
                (if (= invalid 1)
                  3
                  (if (= invalid 3)
                    2
                    1)))))
          (test.assert-true
            (match (homes.compiler-backend-home-plan-build (& bad))
              [(Err _) true]
              [_ false])
            "invalid parameter extent, ID or duplicate rejects"))))))

(define (home-origin-tests) : unit
  (home-origin-coloring-test)
  (home-origin-ambiguous-use-test)
  (home-origin-plan-test)
  (home-origin-address-test)
  (home-origin-parameter-test)
  (home-origin-phi-test)
  (home-origin-group-fragment-test)
  (home-origin-emergency-test)
  (home-origin-callee-test))

(test home-origins-survive-noninjective-coloring (home-origin-tests))

(define (home-origin-plan-query
  [plan : (& homes.CompilerBackendHomePlan)]
  [block : i64]
  [site : i64]
  [emitted : i64]
  [query : homes.CompilerBackendHomeQuery]
  [logical : i64]) : unit
  (match (homes.compiler-backend-home-plan-resolve
    plan
    44
    block
    site
    emitted
    query)
    [(Err message) (io.panic message)]
    [(Ok home)
      (test.assert-i64-eq
        home.id
        logical
        "instruction-scoped pre-color identity")
      (test.assert-i64-eq
        home.bytes
        32
        "capacity comes from original vector layout")]))

(define (home-origin-plan-test) : unit
  (let
    [instructions : (__tl_dyn-array ir.CompilerIrInstr)
      (__tl_make-array ir.CompilerIrInstr 7)]
    [blocks : (__tl_dyn-array ir.CompilerIrBlock)
      (__tl_make-array ir.CompilerIrBlock 5)]
    [remap : (__tl_dyn-array i64) (__tl_make-array i64 10)]
    (set! (array-ref instructions 0) (Splat 7 (I64 1) 4 (I64)))
    (set! (array-ref instructions 1) (Splat 9 (I64 2) 4 (I64)))
    (set!
      (array-ref instructions 2)
      (VectorBinOp
        (box
          (ir.CompilerIrInstrVectorBinOpPayload 8 (Add) (Var 7) (Var 9) 4 (I64)))))
    (set! (array-ref instructions 3) (TailMask 4 (I64 0) (I64 64) 4))
    (set! (array-ref instructions 4) (Branch (Bool true) 20 30))
    (set!
      (array-ref blocks 0)
      (Block 10 (ir.CompilerIrInstrSeq instructions 5)))
    (set!
      (array-ref blocks 1)
      (Block 20 (ir.compiler-ir-instr-seq1 (Return (Some (Var 8))))))
    (set!
      (array-ref blocks 2)
      (Block 30 (ir.compiler-ir-instr-seq1 (Return (Some (Var 8))))))
    (for [index (iterator.range 0 10)]
      (set! (array-ref remap index) index))
    (set! (array-ref remap 7) 1)
    (set! (array-ref remap 8) 1)
    (set! (array-ref remap 9) 2)
    (let
      [original : ir.CompilerIrBlockList
        (Array (ir.CompilerIrBlockSeq blocks 3))]
      [colored : ir.CompilerIrBlockList
        (regalloc.compiler-reg-remap-blocks (& remap) (& original))]
      [view : (& colored (Slice ir.CompilerIrBlock))
        (ir.compiler-ir-block-list-view (& colored))]
      [placed-blocks : (__tl_dyn-array ir.CompilerIrBlock)
        (__tl_make-array ir.CompilerIrBlock 3)]
      (set! (array-ref placed-blocks 0) (clone (array-ref view 0)))
      (set! (array-ref placed-blocks 1) (clone (array-ref view 2)))
      (set! (array-ref placed-blocks 2) (clone (array-ref view 1)))
      (let
        [input : homes.CompilerBackendHomePlanInput
          (homes.CompilerBackendHomePlanInput
            44
            10
            10
            (ir.compiler-ir-param-seq-empty)
            original
            (Array (ir.CompilerIrBlockSeq placed-blocks 3))
            (Remap remap 10)
            (live.compiler-live-set1 0))]
        [plan : homes.CompilerBackendHomePlan
          (match (homes.compiler-backend-home-plan-build (& input))
            [(Ok result) result]
            [(Err message) (io.panic message)])]
        (test.assert-i64-eq
          (array-length plan.sites)
          7
          "only live placed instruction prefixes")
        (test.assert-i64-eq
          (array-ref plan.bytes 0)
          16
          "original register-group capacity")
        (test.assert-i64-eq
          (array-ref plan.bytes 3)
          8
          "ordinary scalar home capacity")
        (test.assert-i64-eq
          (array-ref plan.bytes 4)
          32
          "planned mask reservation exceeds compact access")
        (home-origin-plan-query (& plan) 10 2 1 (AnyUse) 7)
        (home-origin-plan-query (& plan) 10 2 1 (Definition) 8)
        (home-origin-plan-query (& plan) 20 6 1 (AnyUse) 8)
        (test.assert-true
          (match (homes.compiler-backend-home-plan-resolve
            (& plan)
            45
            10
            2
            1
            (AnyUse))
            [(Err _) true]
            [_ false])
          "wrong function cannot reuse a plan")
        (test.assert-true
          (match (homes.compiler-backend-home-plan-resolve
            (& plan)
            44
            20
            2
            1
            (AnyUse))
            [(Err _) true]
            [_ false])
          "wrong block cannot reuse a site")
        (test.assert-true
          (match (homes.compiler-backend-home-plan-resolve
            (& plan)
            44
            10
            7
            1
            (AnyUse))
            [(Err _) true]
            [_ false])
          "out-of-range site rejects")
        (for [invalid (iterator.range 0 6)]
          (let
            [bad : homes.CompilerBackendHomePlanInput (clone input)]
            (cond
              [(= invalid 0) (set! bad.function -1)]
              [(= invalid 1) (set! bad.emitted-count 1)]
              [(= invalid 2) (set! bad.logical-count 7)]
              [else
                (let
                  [bad-blocks : (__tl_dyn-array ir.CompilerIrBlock)
                    (__tl_make-array ir.CompilerIrBlock 2)]
                  (set!
                    (array-ref bad-blocks 0)
                    (Block
                      (if (= invalid 3)
                        99
                        10)
                      (ir.compiler-ir-instr-seq-empty)))
                  (when
                    (= invalid 5)
                    (let
                      [placed : (& input (Slice ir.CompilerIrBlock))
                        (ir.compiler-ir-block-list-view (& input.placed))]
                      (set!
                        (array-ref bad-blocks 0)
                        (clone (array-ref placed 0)))))
                  (set!
                    (array-ref bad-blocks 1)
                    (clone (array-ref bad-blocks 0)))
                  (set!
                    bad.placed
                    (Array
                      (ir.CompilerIrBlockSeq
                        bad-blocks
                        (if (= invalid 5)
                          2
                          1)))))])
            (test.assert-true
              (match (homes.compiler-backend-home-plan-build (& bad))
                [(Err _) true]
                [_ false])
              "invalid paired placement rejects")))
        ;; The actual remapped input is immutable to the plan. A changed
        ;; producer operand must fail a fresh paired check, never match by slot.
        (let
          [wrong : ir.CompilerIrInstr (Mov 1 (Var 2) (I64))]
          [right : ir.CompilerIrInstr (Mov 8 (Var 7) (I64))]
          (test.assert-true
            (match (homes.compiler-backend-home-bindings-checked
              (& right)
              (& wrong)
              (& input.coloring)
              10
              10)
              [(Err _) true]
              [_ false])
            "changed mapped operand rejects"))))))

(define (home-origin-phi-test) : unit
  (let
    [original : ir.CompilerIrBlockList
      (ir_text.blocks
        "entry:
  jump join
other:
  jump join
join:
  %7 = phi [%1, entry], [%2, other] : f64
  %8 = phi [%2, entry], [%1, other] : f64
  return %7
")]
    [map : (__tl_dyn-array i64) (__tl_make-array i64 10)]
    (for [index (iterator.range 0 10)]
      (set! (array-ref map index) index))
    (set! (array-ref map 1) 3)
    (set! (array-ref map 2) 4)
    (set! (array-ref map 7) 3)
    (set! (array-ref map 8) 4)
    (let
      [input : homes.CompilerBackendHomePlanInput
        (homes.CompilerBackendHomePlanInput
          44
          10
          10
          (ir.compiler-ir-param-seq-empty)
          (owned_view.compiler-owned-shared-view original)
          (regalloc.compiler-reg-remap-blocks (& map) (& original))
          (Remap map 10)
          (live.compiler-live-set-empty))]
      [plan : homes.CompilerBackendHomePlan
        (match (homes.compiler-backend-home-plan-build (& input))
          [(Ok result) result]
          [(Err message) (io.panic message)])]
      [target : i64 (array-ref plan.sites 2).block]
      (for [edge (iterator.range 0 2)]
        (let
          [from : i64 (array-ref plan.sites edge).block]
          (match (homes.compiler-backend-home-phi-site (& plan) 2 from 3)
            [(Err message) (io.panic message)]
            [(Ok site use)
              (test.assert-i64-eq site 2 "exact target Phi")
              (test.assert-i64-eq use edge "exact predecessor operand")
              (home-query-ok
                (& (array-ref plan.sites site).bindings)
                3
                (Definition)
                7)
              (home-query-ok
                (& (array-ref plan.sites site).bindings)
                (+ 3 edge)
                (Use use)
                (+ 1 edge))
              (test.assert-true
                (match (homes.compiler-backend-home-plan-resolve
                  (& plan)
                  44
                  target
                  site
                  (- 4 edge)
                  (Use use))
                  [(Err _) true]
                  [_ false])
                "another predecessor cannot authorize the same emitted color")])))
      (for [bad (iterator.range 0 5)]
        (test.assert-true
          (match (homes.compiler-backend-home-phi-site
            (& plan)
            (cond [(= bad 0) -1] [(= bad 1) 0] [(= bad 2) 3] [else 2])
            (if (= bad 3)
              999999
              (array-ref plan.sites 0).block)
            (if (= bad 4)
              9
              3))
            [(Err _) true]
            [_ false])
          "unknown edge/destination or non-entry instruction rejects"))
      (let
        [before : ir.CompilerIrInstr
          (ir_text.instr "%7 = phi [%1, entry], [%2, other] : f64")]
        [changed : ir.CompilerIrInstr
          (ir_text.instr "%7 = phi [%1, other], [%2, entry] : f64")]
        [identity : regalloc.CompilerRegColoring (None)]
        (test.assert-true
          (match (homes.compiler-backend-home-bindings-checked
            (& before)
            (& changed)
            (& identity)
            10
            10)
            [(Err _) true]
            [_ false])
          "equal operand colors do not authorize changed predecessor labels")))))

(define (home-origin-group-fragment-test) : unit
  (for [spare (iterator.range 0 2)]
    (let
      [map : (__tl_dyn-array i64) (__tl_make-array i64 10)]
      [instructions : (__tl_dyn-array ir.CompilerIrInstr)
        (__tl_make-array ir.CompilerIrInstr (+ 1 (* 3 spare)))]
      [blocks : (__tl_dyn-array ir.CompilerIrBlock)
        (__tl_make-array ir.CompilerIrBlock (+ 1 (* 2 spare)))]
      (for [var (iterator.range 0 10)]
        (set! (array-ref map var) var))
      (set! (array-ref map 7) 1)
      (set! (array-ref map 8) 1)
      (set! (array-ref instructions 0) (Mov 8 (Var 7) (I64)))
      (set!
        (array-ref blocks 0)
        (Block 10 (ir.CompilerIrInstrSeq instructions 1)))
      (let
        [original : ir.CompilerIrBlockList
          (Array (ir.CompilerIrBlockSeq blocks 1))]
        [input : homes.CompilerBackendHomePlanInput
          (homes.CompilerBackendHomePlanInput
            44
            10
            10
            (ir.compiler-ir-param-seq-empty)
            (owned_view.compiler-owned-shared-view original)
            (regalloc.compiler-reg-remap-blocks (& map) (& original))
            (Remap map 10)
            (live.compiler-live-set-insert (live.compiler-live-set1 7) 8))]
        [plan : homes.CompilerBackendHomePlan
          (match (homes.compiler-backend-home-plan-build (& input))
            [(Ok result) result]
            [(Err message) (io.panic message)])]
        (for [kind (iterator.range 0 2)]
          (let
            [home : homes.CompilerBackendLogicalHome
              (match (homes.compiler-backend-home-plan-resolve
                (& plan)
                44
                10
                0
                1
                (if (= kind 0)
                  (AnyUse)
                  (Definition)))
                [(Ok result) result]
                [(Err message) (io.panic message)])]
            (for [word (iterator.range 0 2)]
              (match (homes.compiler-backend-home-group-fragment
                (& plan)
                home
                word)
                [(Err message) (io.panic message)]
                [(Ok fragment)
                  (test.assert-i64-eq
                    fragment.id
                    (+ 24 (+ (* 2 kind) word))
                    "group fragments retain original color and word")
                  (test.assert-i64-eq
                    fragment.bytes
                    8
                    "one fragment is one word")]))))
        (for [invalid (iterator.range 0 6)]
          (let
            [id : i64
              (if (= invalid 0)
                -1
                (if (= invalid 1)
                  10
                  (if (= invalid 2)
                    0
                    7)))]
            [bytes : i64
              (if (= invalid 3)
                8
                16)]
            [word : i64
              (if (= invalid 4)
                -1
                (if (= invalid 5)
                  2
                  0))]
            (test.assert-true
              (match (homes.compiler-backend-home-group-fragment
                (& plan)
                (homes.CompilerBackendLogicalHome id bytes)
                word)
                [(Err _) true]
                [_ false])
              "only an exact original group authorizes a word")))
        (let
          [malformed : homes.CompilerBackendHomePlan (clone plan)]
          (set! malformed.groups (__tl_make-array bool 0))
          (test.assert-true
            (match (homes.compiler-backend-home-group-fragment
              (& malformed)
              (homes.CompilerBackendLogicalHome 7 16)
              0)
              [(Err _) true]
              [_ false])
            "group extent mismatch rejects"))))))

(define (home-emergency-query!
  [plan : (&mut homes.CompilerBackendHomePlan)]
  [function : i64]
  [block : i64]
  [site : i64]
  [reg : i64]) : homes.CompilerBackendPlannedHomeResult
  (homes.compiler-backend-home-preservation!
    plan
    function
    block
    site
    (EmergencyRegister reg)))

(define (home-origin-emergency-test) : unit
  (for [spare (iterator.range 0 2)]
    (let
      [instructions : (__tl_dyn-array ir.CompilerIrInstr)
        (__tl_make-array ir.CompilerIrInstr (+ 2 (* 3 spare)))]
      [blocks : (__tl_dyn-array ir.CompilerIrBlock)
        (__tl_make-array ir.CompilerIrBlock (+ 1 spare))]
      (set! (array-ref instructions 0) (Mov 8 (Var 7) (I64)))
      (set! (array-ref instructions 1) (Mov 9 (Var 8) (I64)))
      (set!
        (array-ref blocks 0)
        (Block 10 (ir.CompilerIrInstrSeq instructions 2)))
      (let
        [original : ir.CompilerIrBlockList
          (Array (ir.CompilerIrBlockSeq blocks 1))]
        [input : homes.CompilerBackendHomePlanInput
          (homes.CompilerBackendHomePlanInput
            44
            10
            10
            (ir.compiler-ir-param-seq-empty)
            (owned_view.compiler-owned-shared-view original)
            original
            (None)
            (live.compiler-live-set-empty))]
        [plan : homes.CompilerBackendHomePlan
          (match (homes.compiler-backend-home-plan-build (& input))
            [(Ok result) result]
            [(Err message) (io.panic message)])]
        (for [request (iterator.range 0 5)]
          (let
            [reg : i64
              (cond
                [(< request 2) abi.compiler-reg-id-r9]
                [(= request 2) abi.compiler-reg-id-r10]
                [(= request 3) (abi.compiler-abi-xmm-register-id 2)]
                [else (abi.compiler-abi-vector-register-id 2)])]
            (match (home-emergency-query!
              (&mut plan)
              44
              10
              (if (= request 1)
                1
                0)
              reg)
              [(Err message) (io.panic message)]
              [(Ok home)
                (test.assert-i64-eq
                  home.id
                  (+
                    30
                    (if (= request 4)
                      3
                      request))
                  "emergency resources follow scalar and group namespaces")
                (test.assert-i64-eq home.bytes 64 "reserved emergency capacity")])))
        (test.assert-i64-eq
          plan.preservations.len
          4
          "vector aliases share the site's preservation resource")
        (let
          [slots : (__tl_dyn-array homes.CompilerBackendPreservationHome)
            (__tl_make-array
              homes.CompilerBackendPreservationHome
              (+ 4 (* 3 spare)))]
          (for [index (iterator.range 0 4)]
            (set!
              (array-ref slots index)
              (clone (array-ref plan.preservations.slots index))))
          (set!
            plan.preservations
            (homes.CompilerBackendPreservationHomeList slots 4)))
        (match (home-emergency-query!
          (&mut plan)
          44
          10
          0
          abi.compiler-reg-id-r9)
          [(Err message) (io.panic message)]
          [(Ok home)
            (test.assert-i64-eq home.id 30 "exact/spare lookup parity")])
        (for [invalid (iterator.range 0 10)]
          (let
            [bad : homes.CompilerBackendHomePlan (clone plan)]
            (when (= invalid 8) (set! bad.preservations.len 100))
            (when
              (= invalid 9)
              (set!
                (array-ref bad.preservations.slots 1)
                (clone (array-ref bad.preservations.slots 0))))
            (test.assert-true
              (match (home-emergency-query!
                (&mut bad)
                (if (= invalid 0)
                  45
                  44)
                (if (= invalid 1)
                  11
                  10)
                (cond [(= invalid 2) -1] [(= invalid 3) 2] [else 0])
                (cond
                  [(= invalid 4) -1]
                  [(= invalid 5) abi.compiler-reg-id-rsp]
                  [(= invalid 6) abi.compiler-reg-id-rbp]
                  [(= invalid 7) (abi.compiler-abi-mask-register-id 1)]
                  [else abi.compiler-reg-id-r9]))
                [(Err _) true]
                [_ false])
              "unbound, malformed or unsupported emergency authority rejects")))
        (test.assert-i64-eq
          plan.preservations.len
          4
          "failed clones cannot edit original")
        (match (home-emergency-query!
          (&mut plan)
          44
          10
          0
          abi.compiler-reg-id-r9)
          [(Err message) (io.panic message)]
          [(Ok home)
            (test.assert-i64-eq home.id 30 "original resource remains bound")])
        (for [request (iterator.range 0 3)]
          (match (homes.compiler-backend-home-preservation!
            (&mut plan)
            44
            10
            0
            (ParallelCopySlot
              (if (= request 1)
                0
                abi.compiler-reg-id-r9)))
            [(Err message) (io.panic message)]
            [(Ok home)
              (test.assert-i64-eq
                home.id
                (if (= request 1)
                  35
                  34)
                "planned slots cannot alias equal-numbered emergency registers")
              (test.assert-i64-eq home.bytes 8 "parallel-copy word capacity")]))
        (test.assert-true
          (match (homes.compiler-backend-home-preservation!
            (&mut plan)
            44
            10
            0
            (ParallelCopySlot -1))
            [(Err _) true]
            [_ false])
          "negative planned slot rejects")
        (test.assert-i64-eq
          plan.preservations.len
          6
          "failed slot query publishes no resource")
        (match (homes.compiler-backend-home-preservation!
          (&mut plan)
          44
          10
          0
          (ParallelCopyRegister abi.compiler-reg-id-r9))
          [(Err message) (io.panic message)]
          [(Ok home)
            (test.assert-i64-eq
              home.id
              36
              "implicit planned save has a distinct typed key")
            (test.assert-i64-eq home.bytes 8 "push/pop preserves one GP word")])
        (test.assert-true
          (match (homes.compiler-backend-home-preservation!
            (&mut plan)
            44
            10
            0
            (ParallelCopyRegister (abi.compiler-abi-xmm-register-id 2)))
            [(Err _) true]
            [_ false])
          "GP push/pop authority rejects vector registers")))))

(define (home-origin-fixed-staging-test) : unit
  (for [spare (iterator.range 0 2)]
    (let
      [instructions : (__tl_dyn-array ir.CompilerIrInstr)
        (__tl_make-array ir.CompilerIrInstr (+ 2 spare))]
      [blocks : (__tl_dyn-array ir.CompilerIrBlock)
        (__tl_make-array ir.CompilerIrBlock (+ 1 spare))]
      (set! (array-ref instructions 0) (Mov 8 (Var 7) (I64)))
      (set! (array-ref instructions 1) (Mov 9 (Var 8) (I64)))
      (set!
        (array-ref blocks 0)
        (Block 10 (ir.CompilerIrInstrSeq instructions 2)))
      (let
        [original : ir.CompilerIrBlockList
          (Array (ir.CompilerIrBlockSeq blocks 1))]
        [input : homes.CompilerBackendHomePlanInput
          (homes.CompilerBackendHomePlanInput
            44
            10
            10
            (ir.compiler-ir-param-seq-empty)
            (owned_view.compiler-owned-shared-view original)
            original
            (None)
            (live.compiler-live-set-empty))]
        [plan : homes.CompilerBackendHomePlan
          (match (homes.compiler-backend-home-plan-build (& input))
            [(Ok result) result]
            [(Err message) (io.panic message)])]
        (for [request (iterator.range 0 4)]
          (match (homes.compiler-backend-home-preservation!
            (&mut plan)
            44
            10
            (if (= request 2)
              1
              0)
            (if (= request 3)
              (ParallelCopySlot 0)
              (FixedStaging (LaneBuffer) 32)))
            [(Err message) (io.panic message)]
            [(Ok home)
              (test.assert-i64-eq
                home.id
                (+ 30 (cond [(< request 2) 0] [(= request 2) 1] [else 2]))
                "fixed buffer identity follows its site and typed authority")
              (test.assert-i64-eq
                home.bytes
                (if (= request 3)
                  8
                  32)
                "fixed buffer capacity is independent of each access width")]))
        (for [request (iterator.range 0 7)]
          (match (homes.compiler-backend-home-preservation!
            (&mut plan)
            44
            10
            (if (= request 6)
              1
              0)
            (FixedStaging
              (cond
                [(= request 6) (Operand 0)]
                [(< request 3)
                  (Operand
                    (if (= request 2)
                      1
                      0))]
                [(< request 5)
                  (Result
                    (if (= request 3)
                      0
                      3))]
                [else (Permutation)])
              (if (= request 6)
                64
                32)))
            [(Err message) (io.panic message)]
            [(Ok home)
              (test.assert-i64-eq
                home.id
                (+
                  33
                  (if (= request 0)
                    0
                    (- request 1)))
                "shift resource identity is semantic, typed and site-local")
              (test.assert-i64-eq
                home.bytes
                (if (= request 6)
                  64
                  32)
                "shift resource retains the planned vector capacity")]))
        (let
          [count : i64 plan.preservations.len]
          [slots : (__tl_dyn-array homes.CompilerBackendPreservationHome)
            (__tl_make-array
              homes.CompilerBackendPreservationHome
              (+ count (* spare 3)))]
          (for [index (iterator.range 0 count)]
            (set!
              (array-ref slots index)
              (clone (array-ref plan.preservations.slots index))))
          (set!
            plan.preservations
            (homes.CompilerBackendPreservationHomeList slots count)))
        (match (homes.compiler-backend-home-preservation!
          (&mut plan)
          44
          10
          0
          (FixedStaging (Permutation) 32))
          [(Err message) (io.panic message)]
          [(Ok home)
            (test.assert-i64-eq home.id 37 "exact/spare fixed resource lookup")])
        (for [invalid (iterator.range 0 7)]
          (test.assert-true
            (match (homes.compiler-backend-home-preservation!
              (&mut plan)
              44
              10
              0
              (FixedStaging
                (cond
                  [(< invalid 2)
                    (Operand
                      (if (= invalid 0)
                        -1
                        2))]
                  [(< invalid 4)
                    (Result
                      (if (= invalid 2)
                        -1
                        4))]
                  [else (Permutation)])
                (cond
                  [(= invalid 4) 16]
                  [(= invalid 5) 0]
                  [(= invalid 6) 64]
                  [else 32])))
              [(Err _) true]
              [_ false])
            "malformed shift key or changed capacity rejects"))
        (test.assert-i64-eq
          plan.preservations.len
          9
          "failed query publishes no resource")
        (for [kind (iterator.range 0 8)]
          (match (homes.compiler-backend-home-preservation!
            (&mut plan)
            44
            10
            0
            (FixedStaging
              (cond
                [(= kind 0) (GatherMask)]
                [(= kind 1) (GatherIndex)]
                [(= kind 2) (GatherResult)]
                [(= kind 3) (ShuffleSelector 0)]
                [(= kind 4) (ShuffleSelector 1)]
                [(= kind 5) (ShuffleIndex)]
                [(= kind 6) (ShuffleSource)]
                [else (LaneBuffer)])
              (if (= kind 1)
                64
                32)))
            [(Err message) (io.panic message)]
            [(Ok home)
              (test.assert-i64-eq
                home.id
                (if (= kind 7)
                  30
                  (+ 39 kind))
                "every fixed staging role has a distinct semantic key")]))
        (for [invalid (iterator.range 0 5)]
          (test.assert-true
            (match (homes.compiler-backend-home-preservation!
              (&mut plan)
              44
              10
              0
              (FixedStaging
                (cond
                  [(< invalid 2)
                    (ShuffleSelector
                      (if (= invalid 0)
                        -1
                        2))]
                  [(= invalid 2) (GatherMask)]
                  [(= invalid 3) (LaneBuffer)]
                  [else (GatherIndex)])
                (if (= invalid 4)
                  32
                  64)))
              [(Err _) true]
              [_ false])
            "unsupported selector, fixed capacity or later capacity drift rejects"))
        (test.assert-i64-eq
          plan.preservations.len
          16
          "no malformed fixed resource is published")))))

(test backend-home-fixed-lane-resource (home-origin-fixed-staging-test))

(define (home-origin-callee-test) : unit
  (for [spare (iterator.range 0 2)]
    (let
      [original : ir.CompilerIrBlockList
        (ir_text.blocks "entry:
  %1 = mov %0 : i64
  return %1
")]
      [input : homes.CompilerBackendHomePlanInput
        (homes.CompilerBackendHomePlanInput
          44
          2
          2
          (ir.compiler-ir-param-seq-empty)
          (owned_view.compiler-owned-shared-view original)
          original
          (None)
          (live.compiler-live-set-empty))]
      [plan : homes.CompilerBackendHomePlan
        (match (homes.compiler-backend-home-plan-build (& input))
          [(Ok result) result]
          [(Err message) (io.panic message)])]
      (for [index (iterator.range 0 3)]
        (let
          [reg : i64
            (if (= index 1)
              (abi.compiler-abi-xmm-register-id 6)
              abi.compiler-reg-id-r12)]
          (match (homes.compiler-backend-home-preservation!
            (&mut plan)
            44
            plan.entry-block
            -1
            (CalleeSaveRegister reg))
            [(Err message) (io.panic message)]
            [(Ok home)
              (test.assert-i64-eq
                home.id
                (if (= index 1)
                  7
                  6)
                "function resource survives saves and returns at different sites")
              (test.assert-i64-eq
                home.bytes
                (if (= index 1)
                  16
                  8)
                "callee capacity is its actual ABI preservation width")])))
      (let
        [slots : (__tl_dyn-array homes.CompilerBackendPreservationHome)
          (__tl_make-array
            homes.CompilerBackendPreservationHome
            (+ 2 (* spare 3)))]
        (for [index (iterator.range 0 2)]
          (set!
            (array-ref slots index)
            (clone (array-ref plan.preservations.slots index))))
        (set!
          plan.preservations
          (homes.CompilerBackendPreservationHomeList slots 2)))
      (match (homes.compiler-backend-home-preservation!
        (&mut plan)
        44
        plan.entry-block
        -1
        (CalleeSaveRegister abi.compiler-reg-id-r12))
        [(Err message) (io.panic message)]
        [(Ok home)
          (test.assert-i64-eq home.id 6 "exact/spare function scope parity")])
      (for [invalid (iterator.range 0 11)]
        (let
          [bad : homes.CompilerBackendHomePlan (clone plan)]
          (when (= invalid 9) (set! bad.preservations.len 100))
          (when
            (= invalid 10)
            (set!
              (array-ref bad.preservations.slots 1)
              (clone (array-ref bad.preservations.slots 0))))
          (test.assert-true
            (match (homes.compiler-backend-home-preservation!
              (&mut bad)
              (if (= invalid 0)
                45
                44)
              (if (= invalid 1)
                (+ plan.entry-block 1)
                plan.entry-block)
              (cond [(= invalid 2) 0] [(= invalid 3) -2] [else -1])
              (CalleeSaveRegister
                (cond
                  [(= invalid 4) abi.compiler-reg-id-rax]
                  [(= invalid 5) abi.compiler-reg-id-rsp]
                  [(= invalid 6) (abi.compiler-abi-xmm-register-id 0)]
                  [(= invalid 7) (abi.compiler-abi-vector-register-id 6)]
                  [(= invalid 8) (abi.compiler-abi-mask-register-id 1)]
                  [else abi.compiler-reg-id-r12])))
              [(Err _) true]
              [_ false])
            "function saves reject instruction authority, wrong function and invalid registers")))
      (for [kind (iterator.range 0 3)]
        (match (homes.compiler-backend-home-preservation!
          (&mut plan)
          44
          plan.entry-block
          -1
          (if (= kind 1)
            (CalleeSaveRegister abi.compiler-reg-id-rbp)
            (FramePointer)))
          [(Err message) (io.panic message)]
          [(Ok home)
            (test.assert-i64-eq
              home.id
              (if (= kind 1)
                9
                8)
              "ordinary frame pointer is distinct from an FPO allocated rbp save")
            (test.assert-i64-eq home.bytes 8 "full saved frame pointer")]))
      (test.assert-true
        (match (homes.compiler-backend-home-preservation!
          (&mut plan)
          44
          plan.entry-block
          0
          (FramePointer))
          [(Err _) true]
          [_ false])
        "frame pointers cannot borrow an instruction scope"))))