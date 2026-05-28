;; compiler_regalloc.tl - Planning-only scalar register allocation (#554).
;;
;; This pass mirrors the Rust backend's planning shape without changing
;; assembly emission. It computes inspectable live intervals, ineligible vars,
;; and register/spill homes for scalar IR values. The selfhost pools keep
;; %rsp/%rbp and the emitter's hard scratch registers reserved, and only admit
;; caller-saved integer/XMM registers for values that cannot be clobbered by
;; call emission.
(import "compiler_liveness.tl")

(defenum CompilerRegStringList
  (CompilerRegStringNil)
  (CompilerRegStringCons String CompilerRegStringList))

(defenum CompilerRegLocation
  (CompilerRegRegister String)
  (CompilerRegSpill i64))

(defenum CompilerRegMaybeLocation
  (CompilerRegNoLocation)
  (CompilerRegSomeLocation CompilerRegLocation))

(defenum CompilerRegAssignment
  (CompilerRegAssignment i64 CompilerRegLocation))

(defenum CompilerRegAssignmentList
  (CompilerRegAssignmentNil)
  (CompilerRegAssignmentCons CompilerRegAssignment CompilerRegAssignmentList))

(defenum CompilerRegInterval
  (CompilerRegInterval i64 i64 i64))

(defenum CompilerRegIntervalList
  (CompilerRegIntervalNil)
  (CompilerRegIntervalCons CompilerRegInterval CompilerRegIntervalList))

(defenum CompilerRegMaybeInterval
  (CompilerRegNoInterval)
  (CompilerRegSomeInterval CompilerRegInterval))

(defenum CompilerRegVarType
  (CompilerRegVarType i64 AstType))

(defenum CompilerRegVarTypeList
  (CompilerRegVarTypeNil)
  (CompilerRegVarTypeCons CompilerRegVarType CompilerRegVarTypeList))

(defenum CompilerRegMaybeType
  (CompilerRegNoType)
  (CompilerRegSomeType AstType))

(defenum CompilerRegActive
  (CompilerRegActive i64 i64 String))

(defenum CompilerRegActiveList
  (CompilerRegActiveNil)
  (CompilerRegActiveCons CompilerRegActive CompilerRegActiveList))

(defenum CompilerRegMaybeActive
  (CompilerRegNoActive)
  (CompilerRegSomeActive CompilerRegActive))

(defenum CompilerRegPlan
  (CompilerRegPlan
    CompilerRegAssignmentList
    CompilerLiveI64Set
    CompilerRegIntervalList))

(defenum CompilerRegIntervalScan
  (CompilerRegIntervalScan CompilerRegIntervalList i64))

(defenum CompilerRegAssignState
  (CompilerRegAssignState CompilerRegActiveList CompilerRegAssignmentList))

(defenum CompilerRegMove
  (CompilerRegMove i64 i64))

(defenum CompilerRegMoveList
  (CompilerRegMoveNil)
  (CompilerRegMoveCons CompilerRegMove CompilerRegMoveList))

(define (compiler-reg-min [a : i64] [b : i64]) : i64
  (if (< a b)
    a
    b))

(define (compiler-reg-max [a : i64] [b : i64]) : i64
  (if (> a b)
    a
    b))

(define (compiler-reg-stack-slot-offset [var : i64]) : i64
  (- 0 (* 8 (+ var 1))))

(define (compiler-reg-sysv-integer-registers) : CompilerRegStringList
  (CompilerRegStringCons
    "%r12"
    (CompilerRegStringCons
      "%r13"
      (CompilerRegStringCons
        "%r14"
        (CompilerRegStringCons
          "%r15"
          (CompilerRegStringCons
            "%r8"
            (CompilerRegStringCons "%r9" CompilerRegStringNil)))))))

(define (compiler-reg-sysv-caller-saved-integer-registers) : CompilerRegStringList
  (CompilerRegStringCons
    "%rax"
    (CompilerRegStringCons
      "%rcx"
      (CompilerRegStringCons
        "%rdx"
        (CompilerRegStringCons
          "%rsi"
          (CompilerRegStringCons
            "%rdi"
            (CompilerRegStringCons
              "%r8"
              (CompilerRegStringCons
                "%r9"
                (CompilerRegStringCons
                  "%r10"
                  (CompilerRegStringCons "%r11" CompilerRegStringNil))))))))))

(define (compiler-reg-sysv-callee-saved-integer-registers) : CompilerRegStringList
  (CompilerRegStringCons
    "%rbx"
    (CompilerRegStringCons
      "%r12"
      (CompilerRegStringCons
        "%r13"
        (CompilerRegStringCons
          "%r14"
          (CompilerRegStringCons "%r15" CompilerRegStringNil))))))

(define (compiler-reg-win64-caller-saved-integer-registers) : CompilerRegStringList
  (CompilerRegStringCons
    "%rax"
    (CompilerRegStringCons
      "%rcx"
      (CompilerRegStringCons
        "%rdx"
        (CompilerRegStringCons
          "%r8"
          (CompilerRegStringCons
            "%r9"
            (CompilerRegStringCons
              "%r10"
              (CompilerRegStringCons "%r11" CompilerRegStringNil))))))))

(define (compiler-reg-win64-callee-saved-integer-registers) : CompilerRegStringList
  (CompilerRegStringCons
    "%rbx"
    (CompilerRegStringCons
      "%rsi"
      (CompilerRegStringCons
        "%rdi"
        (CompilerRegStringCons
          "%r12"
          (CompilerRegStringCons
            "%r13"
            (CompilerRegStringCons
              "%r14"
              (CompilerRegStringCons "%r15" CompilerRegStringNil))))))))

;; Persistent f64 homes use XMM registers that are caller-saved on both SysV
;; and Windows x64, avoid %xmm0/%xmm1 arithmetic scratch, avoid %xmm15 outgoing
;; stack-argument scratch, and avoid Windows callee-saved XMM6-XMM15 until the
;; backend has save/restore support for those registers.
(define (compiler-reg-xmm-registers) : CompilerRegStringList
  (CompilerRegStringCons
    "%xmm2"
    (CompilerRegStringCons
      "%xmm3"
      (CompilerRegStringCons
        "%xmm4"
        (CompilerRegStringCons "%xmm5" CompilerRegStringNil)))))

(define (compiler-reg-sysv-caller-saved-xmm-registers) : CompilerRegStringList
  (CompilerRegStringCons
    "%xmm0"
    (CompilerRegStringCons
      "%xmm1"
      (CompilerRegStringCons
        "%xmm2"
        (CompilerRegStringCons
          "%xmm3"
          (CompilerRegStringCons
            "%xmm4"
            (CompilerRegStringCons
              "%xmm5"
              (CompilerRegStringCons
                "%xmm6"
                (CompilerRegStringCons
                  "%xmm7"
                  (CompilerRegStringCons
                    "%xmm8"
                    (CompilerRegStringCons
                      "%xmm9"
                      (CompilerRegStringCons
                        "%xmm10"
                        (CompilerRegStringCons
                          "%xmm11"
                          (CompilerRegStringCons
                            "%xmm12"
                            (CompilerRegStringCons
                              "%xmm13"
                              (CompilerRegStringCons
                                "%xmm14"
                                (CompilerRegStringCons
                                  "%xmm15"
                                  CompilerRegStringNil)))))))))))))))))

(define (compiler-reg-sysv-callee-saved-xmm-registers) : CompilerRegStringList
  CompilerRegStringNil)

(define (compiler-reg-win64-caller-saved-xmm-registers) : CompilerRegStringList
  (CompilerRegStringCons
    "%xmm0"
    (CompilerRegStringCons
      "%xmm1"
      (CompilerRegStringCons
        "%xmm2"
        (CompilerRegStringCons
          "%xmm3"
          (CompilerRegStringCons
            "%xmm4"
            (CompilerRegStringCons "%xmm5" CompilerRegStringNil)))))))

(define (compiler-reg-win64-callee-saved-xmm-registers) : CompilerRegStringList
  (CompilerRegStringCons
    "%xmm6"
    (CompilerRegStringCons
      "%xmm7"
      (CompilerRegStringCons
        "%xmm8"
        (CompilerRegStringCons
          "%xmm9"
          (CompilerRegStringCons
            "%xmm10"
            (CompilerRegStringCons
              "%xmm11"
              (CompilerRegStringCons
                "%xmm12"
                (CompilerRegStringCons
                  "%xmm13"
                  (CompilerRegStringCons
                    "%xmm14"
                    (CompilerRegStringCons "%xmm15" CompilerRegStringNil)))))))))))

(define (compiler-reg-string-list-count [regs : CompilerRegStringList]) : i64
  (match regs
    [(CompilerRegStringNil) 0]
    [(CompilerRegStringCons _ rest) (+ 1 (compiler-reg-string-list-count rest))]))

(define (compiler-reg-string-list-contains?
  [regs : CompilerRegStringList]
  [want : String]) : bool
  (match regs
    [(CompilerRegStringNil) false]
    [(CompilerRegStringCons reg rest)
      (if (string-eq reg want)
        true
        (compiler-reg-string-list-contains? rest want))]))

(define (compiler-reg-f64-type? [ty : AstType]) : bool
  (match ty
    [(AstTyF64) true]
    [_ false]))

(define (compiler-reg-scalar-type? [ty : AstType]) : bool
  (match ty
    [(AstTyI64) true]
    [(AstTyI32) true]
    [(AstTyI16) true]
    [(AstTyI8) true]
    [(AstTyU64) true]
    [(AstTyU32) true]
    [(AstTyU16) true]
    [(AstTyU8) true]
    [(AstTyF64) true]
    [(AstTyBool) true]
    [(AstTyChar) true]
    [(AstTyFunc _ _) true]
    [(AstTyPtr _) true]
    [(AstTyMutPtr _) true]
    [(AstTyRef _ _) true]
    [(AstTyMutRef _ _) true]
    [_ false]))

(define (compiler-reg-var-type-insert
  [types : CompilerRegVarTypeList]
  [var : i64]
  [ty : AstType]) : CompilerRegVarTypeList
  (match types
    [(CompilerRegVarTypeNil)
      (CompilerRegVarTypeCons (CompilerRegVarType var ty) CompilerRegVarTypeNil)]
    [(CompilerRegVarTypeCons item rest)
      (match item
        [(CompilerRegVarType id _)
          (if (= id var)
            (CompilerRegVarTypeCons (CompilerRegVarType var ty) rest)
            (if (> id var)
              (CompilerRegVarTypeCons (CompilerRegVarType var ty) types)
              (CompilerRegVarTypeCons
                item
                (compiler-reg-var-type-insert rest var ty))))])]))

(define (compiler-reg-var-type-lookup
  [types : CompilerRegVarTypeList]
  [var : i64]) : CompilerRegMaybeType
  (match types
    [(CompilerRegVarTypeNil) CompilerRegNoType]
    [(CompilerRegVarTypeCons item rest)
      (match item
        [(CompilerRegVarType id ty)
          (if (= id var)
            (CompilerRegSomeType ty)
            (if (> id var)
              CompilerRegNoType
              (compiler-reg-var-type-lookup rest var)))])]))

(define (compiler-reg-param-types
  [params : CompilerIrParamList]
  [types : CompilerRegVarTypeList]) : CompilerRegVarTypeList
  (match params
    [(IrParamNil) types]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ ty id)
          (compiler-reg-param-types
            rest
            (compiler-reg-var-type-insert types id ty))])]))

(define (compiler-reg-instr-def-type
  [types : CompilerRegVarTypeList]
  [instr : CompilerIrInstr]) : CompilerRegVarTypeList
  (match instr
    [(IrInstrMov dst _ ty) (compiler-reg-var-type-insert types dst ty)]
    [(IrInstrLoad dst _ ty) (compiler-reg-var-type-insert types dst ty)]
    [(IrInstrCast dst _ _ to-ty) (compiler-reg-var-type-insert types dst to-ty)]
    [(IrInstrBinOp dst _ _ _ ty) (compiler-reg-var-type-insert types dst ty)]
    [(IrInstrUnOp dst _ _ ty) (compiler-reg-var-type-insert types dst ty)]
    [(IrInstrVectorReduce dst _ _ _ elem-ty)
      (compiler-reg-var-type-insert types dst elem-ty)]
    [(IrInstrMaskReduce dst _ _ _)
      (compiler-reg-var-type-insert types dst (AstTyBool))]
    [(IrInstrCall dst _ _ ty) (compiler-reg-var-type-insert types dst ty)]
    [(IrInstrPhi dst _ ty) (compiler-reg-var-type-insert types dst ty)]
    [_ types]))

(define (compiler-reg-instr-list-types
  [instrs : CompilerIrInstrList]
  [types : CompilerRegVarTypeList]) : CompilerRegVarTypeList
  (match instrs
    [(IrInstrNil) types]
    [(IrInstrCons instr rest)
      (compiler-reg-instr-list-types
        rest
        (compiler-reg-instr-def-type types instr))]))

(define (compiler-reg-block-list-types
  [blocks : CompilerIrBlockList]
  [types : CompilerRegVarTypeList]) : CompilerRegVarTypeList
  (match blocks
    [(IrBlockNil) types]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-reg-block-list-types
            rest
            (compiler-reg-instr-list-types instrs types))])]))

(define (compiler-reg-function-var-types [func : CompilerIrFunction]) : CompilerRegVarTypeList
  (match func
    [(IrFunction _ params _ _ blocks)
      (compiler-reg-block-list-types
        blocks
        (compiler-reg-param-types params CompilerRegVarTypeNil))]))

(define (compiler-reg-move-list-contains?
  [moves : CompilerRegMoveList]
  [src : i64]
  [dst : i64]) : bool
  (match moves
    [(CompilerRegMoveNil) false]
    [(CompilerRegMoveCons move rest)
      (match move
        [(CompilerRegMove found-src found-dst)
          (if (and (= found-src src) (= found-dst dst))
            true
            (compiler-reg-move-list-contains? rest src dst))])]))

(define (compiler-reg-move-list-add
  [moves : CompilerRegMoveList]
  [src : i64]
  [dst : i64]) : CompilerRegMoveList
  (if (= src dst)
    moves
    (if (compiler-reg-move-list-contains? moves src dst)
      moves
      (CompilerRegMoveCons (CompilerRegMove src dst) moves))))

(define (compiler-reg-phi-input-moves
  [dst : i64]
  [inputs : CompilerIrPhiInputList]
  [moves : CompilerRegMoveList]) : CompilerRegMoveList
  (match inputs
    [(IrPhiInputNil) moves]
    [(IrPhiInputCons input rest)
      (match input
        [(IrPhiInput value _)
          (let
            [tail : CompilerRegMoveList
              (compiler-reg-phi-input-moves dst rest moves)]
            (match value
              [(IrValueVar src) (compiler-reg-move-list-add tail src dst)]
              [_ tail]))])]))

(define (compiler-reg-instr-moves
  [instr : CompilerIrInstr]
  [moves : CompilerRegMoveList]) : CompilerRegMoveList
  (match instr
    [(IrInstrMov dst src _)
      (match src
        [(IrValueVar var) (compiler-reg-move-list-add moves var dst)]
        [_ moves])]
    [(IrInstrPhi dst inputs _) (compiler-reg-phi-input-moves dst inputs moves)]
    [_ moves]))

(define (compiler-reg-instr-list-moves
  [instrs : CompilerIrInstrList]
  [moves : CompilerRegMoveList]) : CompilerRegMoveList
  (match instrs
    [(IrInstrNil) moves]
    [(IrInstrCons instr rest)
      (compiler-reg-instr-moves
        instr
        (compiler-reg-instr-list-moves rest moves))]))

(define (compiler-reg-block-list-moves
  [blocks : CompilerIrBlockList]
  [moves : CompilerRegMoveList]) : CompilerRegMoveList
  (match blocks
    [(IrBlockNil) moves]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-reg-block-list-moves
            rest
            (compiler-reg-instr-list-moves instrs moves))])]))

(define (compiler-reg-function-moves [func : CompilerIrFunction]) : CompilerRegMoveList
  (match func
    [(IrFunction _ _ _ _ blocks)
      (compiler-reg-block-list-moves blocks CompilerRegMoveNil)]))

(define (compiler-reg-extend-interval
  [intervals : CompilerRegIntervalList]
  [var : i64]
  [point : i64]) : CompilerRegIntervalList
  (match intervals
    [(CompilerRegIntervalNil)
      (CompilerRegIntervalCons
        (CompilerRegInterval var point point)
        CompilerRegIntervalNil)]
    [(CompilerRegIntervalCons interval rest)
      (match interval
        [(CompilerRegInterval id start end)
          (if (= id var)
            (CompilerRegIntervalCons
              (CompilerRegInterval
                id
                (compiler-reg-min start point)
                (compiler-reg-max end point))
              rest)
            (if (> id var)
              (CompilerRegIntervalCons
                (CompilerRegInterval var point point)
                intervals)
              (CompilerRegIntervalCons
                interval
                (compiler-reg-extend-interval rest var point))))])]))

(define (compiler-reg-extend-set
  [intervals : CompilerRegIntervalList]
  [set : CompilerLiveI64Set]
  [point : i64]) : CompilerRegIntervalList
  (match set
    [(CompilerLiveI64Nil) intervals]
    [(CompilerLiveI64Cons var rest)
      (compiler-reg-extend-set
        (compiler-reg-extend-interval intervals var point)
        rest
        point)]))

(define (compiler-reg-extend-instr
  [intervals : CompilerRegIntervalList]
  [liveness : CompilerFunctionLiveness]
  [label : String]
  [index : i64]
  [point : i64]
  [instr : CompilerIrInstr]) : CompilerRegIntervalList
  (let
    [with-defs : CompilerRegIntervalList
      (compiler-reg-extend-set intervals (compiler-live-instr-defs instr) point)]
    (let
      [with-uses : CompilerRegIntervalList
        (compiler-reg-extend-set
          with-defs
          (compiler-live-instr-uses instr)
          point)]
      (compiler-reg-extend-set
        with-uses
        (compiler-live-after liveness label index)
        (+ point 1)))))

(define (compiler-reg-live-intervals-instrs
  [instrs : CompilerIrInstrList]
  [liveness : CompilerFunctionLiveness]
  [label : String]
  [index : i64]
  [point : i64]
  [intervals : CompilerRegIntervalList]) : CompilerRegIntervalScan
  (match instrs
    [(IrInstrNil) (CompilerRegIntervalScan intervals point)]
    [(IrInstrCons instr rest)
      (compiler-reg-live-intervals-instrs
        rest
        liveness
        label
        (+ index 1)
        (+ point 2)
        (compiler-reg-extend-instr intervals liveness label index point instr))]))

(define (compiler-reg-live-intervals-blocks
  [blocks : CompilerIrBlockList]
  [liveness : CompilerFunctionLiveness]
  [point : i64]
  [intervals : CompilerRegIntervalList]) : CompilerRegIntervalScan
  (match blocks
    [(IrBlockNil) (CompilerRegIntervalScan intervals point)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (match (compiler-reg-live-intervals-instrs
            instrs
            liveness
            label
            0
            point
            intervals)
            [(CompilerRegIntervalScan block-intervals next-point)
              (compiler-reg-live-intervals-blocks
                rest
                liveness
                next-point
                block-intervals)])])]))

(define (compiler-reg-live-intervals
  [func : CompilerIrFunction]
  [liveness : CompilerFunctionLiveness]) : CompilerRegIntervalList
  (match func
    [(IrFunction _ _ _ _ blocks)
      (match (compiler-reg-live-intervals-blocks
        blocks
        liveness
        0
        CompilerRegIntervalNil)
        [(CompilerRegIntervalScan intervals _) intervals])]))

(define (compiler-reg-ineligible-non-scalars
  [types : CompilerRegVarTypeList]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match types
    [(CompilerRegVarTypeNil) set]
    [(CompilerRegVarTypeCons item rest)
      (match item
        [(CompilerRegVarType var ty)
          (compiler-reg-ineligible-non-scalars
            rest
            (if (compiler-reg-scalar-type? ty)
              set
              (compiler-live-set-insert set var)))])]))

(define (compiler-reg-ineligible-params
  [params : CompilerIrParamList]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match params
    [(IrParamNil) set]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ _ var)
          (compiler-reg-ineligible-params
            rest
            (compiler-live-set-insert set var))])]))

(define (compiler-reg-ineligible-instr
  [instr : CompilerIrInstr]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match instr
    [(IrInstrAlloc dst _) (compiler-live-set-insert set dst)]
    [(IrInstrAddrOf dst src)
      (compiler-live-set-insert (compiler-live-set-insert set dst) src)]
    [(IrInstrGep dst _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrLaneId dst _ _) (compiler-live-set-insert set dst)]
    [(IrInstrSplat dst _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrVectorBinOp dst _ _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrVectorCompare dst _ _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrMaskBinOp dst _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrMaskNot dst _ _) (compiler-live-set-insert set dst)]
    [(IrInstrSelect dst _ _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrVectorLoad dst _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrPredicatedLoad dst _ _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrTailMask dst _ _ _) (compiler-live-set-insert set dst)]
    [_ set]))

(define (compiler-reg-ineligible-instrs
  [instrs : CompilerIrInstrList]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match instrs
    [(IrInstrNil) set]
    [(IrInstrCons instr rest)
      (compiler-reg-ineligible-instrs
        rest
        (compiler-reg-ineligible-instr instr set))]))

(define (compiler-reg-ineligible-memory
  [blocks : CompilerIrBlockList]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match blocks
    [(IrBlockNil) set]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-reg-ineligible-memory
            rest
            (compiler-reg-ineligible-instrs instrs set))])]))

(define (compiler-reg-call-live-instrs
  [instrs : CompilerIrInstrList]
  [liveness : CompilerFunctionLiveness]
  [label : String]
  [index : i64]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match instrs
    [(IrInstrNil) set]
    [(IrInstrCons instr rest)
      (let
        [next-set : CompilerLiveI64Set
          (match instr
            [(IrInstrCall _ _ _ _)
              (compiler-live-set-union
                set
                (compiler-live-after liveness label index))]
            [(IrInstrTailCall _ _ _)
              (compiler-live-set-union
                set
                (compiler-live-after liveness label index))]
            [_ set])]
        (compiler-reg-call-live-instrs rest liveness label (+ index 1) next-set))]))

(define (compiler-reg-call-live-blocks
  [blocks : CompilerIrBlockList]
  [liveness : CompilerFunctionLiveness]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match blocks
    [(IrBlockNil) set]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (compiler-reg-call-live-blocks
            rest
            liveness
            (compiler-reg-call-live-instrs instrs liveness label 0 set))])]))

(define (compiler-reg-call-arg-vars-instrs
  [instrs : CompilerIrInstrList]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match instrs
    [(IrInstrNil) set]
    [(IrInstrCons instr rest)
      (compiler-reg-call-arg-vars-instrs
        rest
        (match instr
          [(IrInstrCall _ _ args _)
            (compiler-live-set-union set (compiler-live-value-list-vars args))]
          [(IrInstrTailCall _ args _)
            (compiler-live-set-union set (compiler-live-value-list-vars args))]
          [_ set]))]))

(define (compiler-reg-call-arg-vars-blocks
  [blocks : CompilerIrBlockList]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match blocks
    [(IrBlockNil) set]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-reg-call-arg-vars-blocks
            rest
            (compiler-reg-call-arg-vars-instrs instrs set))])]))

(define (compiler-reg-ineligible-vars
  [func : CompilerIrFunction]
  [liveness : CompilerFunctionLiveness]
  [types : CompilerRegVarTypeList]) : CompilerLiveI64Set
  (match func
    [(IrFunction _ params _ _ blocks)
      (compiler-reg-call-live-blocks
        blocks
        liveness
        (compiler-reg-ineligible-memory
          blocks
          (compiler-reg-ineligible-params
            params
            (compiler-reg-call-arg-vars-blocks
              blocks
              (compiler-reg-ineligible-non-scalars types CompilerLiveI64Nil)))))]))

(define (compiler-reg-interval-before?
  [left : CompilerRegInterval]
  [right : CompilerRegInterval]) : bool
  (match left
    [(CompilerRegInterval left-var left-start left-end)
      (match right
        [(CompilerRegInterval right-var right-start right-end)
          (if (< left-start right-start)
            true
            (if (> left-start right-start)
              false
              (if (< left-end right-end)
                true
                (if (> left-end right-end)
                  false
                  (< left-var right-var)))))])]))

(define (compiler-reg-candidate-insert
  [candidates : CompilerRegIntervalList]
  [interval : CompilerRegInterval]) : CompilerRegIntervalList
  (match candidates
    [(CompilerRegIntervalNil)
      (CompilerRegIntervalCons interval CompilerRegIntervalNil)]
    [(CompilerRegIntervalCons head rest)
      (if (compiler-reg-interval-before? interval head)
        (CompilerRegIntervalCons interval candidates)
        (CompilerRegIntervalCons
          head
          (compiler-reg-candidate-insert rest interval)))]))

(define (compiler-reg-candidates
  [intervals : CompilerRegIntervalList]
  [types : CompilerRegVarTypeList]
  [ineligible : CompilerLiveI64Set]
  [want-f64 : bool]) : CompilerRegIntervalList
  (match intervals
    [(CompilerRegIntervalNil) CompilerRegIntervalNil]
    [(CompilerRegIntervalCons interval rest)
      (match interval
        [(CompilerRegInterval var _ _)
          (let
            [tail : CompilerRegIntervalList
              (compiler-reg-candidates rest types ineligible want-f64)]
            (if (compiler-live-set-contains? ineligible var)
              tail
              (match (compiler-reg-var-type-lookup types var)
                [(CompilerRegSomeType ty)
                  (if (if want-f64
                    (compiler-reg-f64-type? ty)
                    (not (compiler-reg-f64-type? ty)))
                    (compiler-reg-candidate-insert tail interval)
                    tail)]
                [(CompilerRegNoType) tail])))])]))

(define (compiler-reg-active-count [active : CompilerRegActiveList]) : i64
  (match active
    [(CompilerRegActiveNil) 0]
    [(CompilerRegActiveCons _ rest) (+ 1 (compiler-reg-active-count rest))]))

(define (compiler-reg-active-contains-register?
  [active : CompilerRegActiveList]
  [reg : String]) : bool
  (match active
    [(CompilerRegActiveNil) false]
    [(CompilerRegActiveCons item rest)
      (match item
        [(CompilerRegActive _ _ active-reg)
          (if (string-eq reg active-reg)
            true
            (compiler-reg-active-contains-register? rest reg))])]))

(define (compiler-reg-active-before?
  [left : CompilerRegActive]
  [right : CompilerRegActive]) : bool
  (match left
    [(CompilerRegActive left-var left-end _)
      (match right
        [(CompilerRegActive right-var right-end _)
          (if (< left-end right-end)
            true
            (if (> left-end right-end)
              false
              (< left-var right-var)))])]))

(define (compiler-reg-active-insert
  [active : CompilerRegActiveList]
  [item : CompilerRegActive]) : CompilerRegActiveList
  (match active
    [(CompilerRegActiveNil) (CompilerRegActiveCons item CompilerRegActiveNil)]
    [(CompilerRegActiveCons head rest)
      (if (compiler-reg-active-before? item head)
        (CompilerRegActiveCons item active)
        (CompilerRegActiveCons head (compiler-reg-active-insert rest item)))]))

(define (compiler-reg-expire-active
  [active : CompilerRegActiveList]
  [start : i64]) : CompilerRegActiveList
  (match active
    [(CompilerRegActiveNil) CompilerRegActiveNil]
    [(CompilerRegActiveCons item rest)
      (match item
        [(CompilerRegActive _ end _)
          (if (<= end start)
            (compiler-reg-expire-active rest start)
            (compiler-reg-active-insert
              (compiler-reg-expire-active rest start)
              item))])]))

(define (compiler-reg-first-free-register
  [regs : CompilerRegStringList]
  [active : CompilerRegActiveList]) : String
  (match regs
    [(CompilerRegStringNil) "%r12"]
    [(CompilerRegStringCons reg rest)
      (if (compiler-reg-active-contains-register? active reg)
        (compiler-reg-first-free-register rest active)
        reg)]))

(define (compiler-reg-active-max [active : CompilerRegActiveList]) : CompilerRegMaybeActive
  (match active
    [(CompilerRegActiveNil) CompilerRegNoActive]
    [(CompilerRegActiveCons item rest)
      (match (compiler-reg-active-max rest)
        [(CompilerRegNoActive) (CompilerRegSomeActive item)]
        [(CompilerRegSomeActive other)
          (if (compiler-reg-active-before? item other)
            (CompilerRegSomeActive other)
            (CompilerRegSomeActive item))])]))

(define (compiler-reg-active-remove-var
  [active : CompilerRegActiveList]
  [var : i64]) : CompilerRegActiveList
  (match active
    [(CompilerRegActiveNil) CompilerRegActiveNil]
    [(CompilerRegActiveCons item rest)
      (match item
        [(CompilerRegActive id _ _)
          (if (= id var)
            (compiler-reg-active-remove-var rest var)
            (CompilerRegActiveCons
              item
              (compiler-reg-active-remove-var rest var)))])]))

(define (compiler-reg-assignment-insert
  [assignments : CompilerRegAssignmentList]
  [var : i64]
  [location : CompilerRegLocation]) : CompilerRegAssignmentList
  (match assignments
    [(CompilerRegAssignmentNil)
      (CompilerRegAssignmentCons
        (CompilerRegAssignment var location)
        CompilerRegAssignmentNil)]
    [(CompilerRegAssignmentCons item rest)
      (match item
        [(CompilerRegAssignment id _)
          (if (= id var)
            (CompilerRegAssignmentCons
              (CompilerRegAssignment var location)
              rest)
            (if (> id var)
              (CompilerRegAssignmentCons
                (CompilerRegAssignment var location)
                assignments)
              (CompilerRegAssignmentCons
                item
                (compiler-reg-assignment-insert rest var location))))])]))

(define (compiler-reg-assignment-lookup
  [assignments : CompilerRegAssignmentList]
  [var : i64]) : CompilerRegMaybeLocation
  (match assignments
    [(CompilerRegAssignmentNil) CompilerRegNoLocation]
    [(CompilerRegAssignmentCons item rest)
      (match item
        [(CompilerRegAssignment id location)
          (if (= id var)
            (CompilerRegSomeLocation location)
            (if (> id var)
              CompilerRegNoLocation
              (compiler-reg-assignment-lookup rest var)))])]))

(define (compiler-reg-location-eq?
  [left : CompilerRegLocation]
  [right : CompilerRegLocation]) : bool
  (match left
    [(CompilerRegRegister left-reg)
      (match right
        [(CompilerRegRegister right-reg) (string-eq left-reg right-reg)]
        [_ false])]
    [(CompilerRegSpill left-offset)
      (match right
        [(CompilerRegSpill right-offset) (= left-offset right-offset)]
        [_ false])]))

(define (compiler-reg-interval-lookup
  [intervals : CompilerRegIntervalList]
  [var : i64]) : CompilerRegMaybeInterval
  (match intervals
    [(CompilerRegIntervalNil) CompilerRegNoInterval]
    [(CompilerRegIntervalCons interval rest)
      (match interval
        [(CompilerRegInterval id _ _)
          (if (= id var)
            (CompilerRegSomeInterval interval)
            (if (> id var)
              CompilerRegNoInterval
              (compiler-reg-interval-lookup rest var)))])]))

(define (compiler-reg-interval-overlap?
  [left : CompilerRegInterval]
  [right : CompilerRegInterval]) : bool
  (match left
    [(CompilerRegInterval _ left-start left-end)
      (match right
        [(CompilerRegInterval _ right-start right-end)
          (not (or (<= left-end right-start) (<= right-end left-start)))])]))

(define (compiler-reg-vars-interfere?
  [intervals : CompilerRegIntervalList]
  [left : i64]
  [right : i64]) : bool
  (if (= left right)
    true
    (match (compiler-reg-interval-lookup intervals left)
      [(CompilerRegSomeInterval left-interval)
        (match (compiler-reg-interval-lookup intervals right)
          [(CompilerRegSomeInterval right-interval)
            (compiler-reg-interval-overlap? left-interval right-interval)]
          [(CompilerRegNoInterval) true])]
      [(CompilerRegNoInterval) true])))

(define (compiler-reg-compatible-types?
  [types : CompilerRegVarTypeList]
  [left : i64]
  [right : i64]) : bool
  (match (compiler-reg-var-type-lookup types left)
    [(CompilerRegSomeType left-ty)
      (match (compiler-reg-var-type-lookup types right)
        [(CompilerRegSomeType right-ty)
          (and
            (compiler-reg-scalar-type? left-ty)
            (and
              (compiler-reg-scalar-type? right-ty)
              (= (ast-type-tag left-ty) (ast-type-tag right-ty))))]
        [(CompilerRegNoType) false])]
    [(CompilerRegNoType) false]))

(define (compiler-reg-location-conflicts?
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalList]
  [var : i64]
  [ignore-var : i64]
  [location : CompilerRegLocation]) : bool
  (match assignments
    [(CompilerRegAssignmentNil) false]
    [(CompilerRegAssignmentCons item rest)
      (match item
        [(CompilerRegAssignment assigned-var assigned-location)
          (if (or (= assigned-var var) (= assigned-var ignore-var))
            (compiler-reg-location-conflicts?
              rest
              intervals
              var
              ignore-var
              location)
            (if (and
              (compiler-reg-location-eq? assigned-location location)
              (compiler-reg-vars-interfere? intervals var assigned-var))
              true
              (compiler-reg-location-conflicts?
                rest
                intervals
                var
                ignore-var
                location)))])]))

(define (compiler-reg-coalesce-location-from-var
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalList]
  [types : CompilerRegVarTypeList]
  [var : i64]
  [other : i64]) : CompilerRegMaybeLocation
  (if (or
    (= var other)
    (or
      (not (compiler-reg-compatible-types? types var other))
      (compiler-reg-vars-interfere? intervals var other)))
    CompilerRegNoLocation
    (match (compiler-reg-assignment-lookup assignments other)
      [(CompilerRegSomeLocation location)
        (if (compiler-reg-location-conflicts?
          assignments
          intervals
          var
          other
          location)
          CompilerRegNoLocation
          (CompilerRegSomeLocation location))]
      [(CompilerRegNoLocation) CompilerRegNoLocation])))

(define (compiler-reg-coalesce-location
  [moves : CompilerRegMoveList]
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalList]
  [types : CompilerRegVarTypeList]
  [var : i64]) : CompilerRegMaybeLocation
  (match moves
    [(CompilerRegMoveNil) CompilerRegNoLocation]
    [(CompilerRegMoveCons move rest)
      (match move
        [(CompilerRegMove src dst)
          (if (= dst var)
            (match (compiler-reg-coalesce-location-from-var
              assignments
              intervals
              types
              var
              src)
              [(CompilerRegSomeLocation location)
                (CompilerRegSomeLocation location)]
              [(CompilerRegNoLocation)
                (compiler-reg-coalesce-location
                  rest
                  assignments
                  intervals
                  types
                  var)])
            (if (= src var)
              (match (compiler-reg-coalesce-location-from-var
                assignments
                intervals
                types
                var
                dst)
                [(CompilerRegSomeLocation location)
                  (CompilerRegSomeLocation location)]
                [(CompilerRegNoLocation)
                  (compiler-reg-coalesce-location
                    rest
                    assignments
                    intervals
                    types
                    var)])
              (compiler-reg-coalesce-location
                rest
                assignments
                intervals
                types
                var)))])]))

(define (compiler-reg-assignment-count
  [assignments : CompilerRegAssignmentList]) : i64
  (match assignments
    [(CompilerRegAssignmentNil) 0]
    [(CompilerRegAssignmentCons _ rest)
      (+ 1 (compiler-reg-assignment-count rest))]))

(define (compiler-reg-spill-count [assignments : CompilerRegAssignmentList]) : i64
  (match assignments
    [(CompilerRegAssignmentNil) 0]
    [(CompilerRegAssignmentCons item rest)
      (match item
        [(CompilerRegAssignment _ location)
          (match location
            [(CompilerRegSpill _) (+ 1 (compiler-reg-spill-count rest))]
            [_ (compiler-reg-spill-count rest)])])]))

(define (compiler-reg-spill-at-interval
  [interval : CompilerRegInterval]
  [active : CompilerRegActiveList]
  [assignments : CompilerRegAssignmentList]) : CompilerRegAssignState
  (match interval
    [(CompilerRegInterval var _ end)
      (match (compiler-reg-active-max active)
        [(CompilerRegNoActive)
          (CompilerRegAssignState
            active
            (compiler-reg-assignment-insert
              assignments
              var
              (CompilerRegSpill (compiler-reg-stack-slot-offset var))))]
        [(CompilerRegSomeActive spill)
          (match spill
            [(CompilerRegActive spill-var spill-end spill-reg)
              (if (> spill-end end)
                (CompilerRegAssignState
                  (compiler-reg-active-insert
                    (compiler-reg-active-remove-var active spill-var)
                    (CompilerRegActive var end spill-reg))
                  (compiler-reg-assignment-insert
                    (compiler-reg-assignment-insert
                      assignments
                      spill-var
                      (CompilerRegSpill
                        (compiler-reg-stack-slot-offset spill-var)))
                    var
                    (CompilerRegRegister spill-reg)))
                (CompilerRegAssignState
                  active
                  (compiler-reg-assignment-insert
                    assignments
                    var
                    (CompilerRegSpill (compiler-reg-stack-slot-offset var)))))])])]))

(define (compiler-reg-assign-candidates
  [candidates : CompilerRegIntervalList]
  [regs : CompilerRegStringList]
  [active : CompilerRegActiveList]
  [assignments : CompilerRegAssignmentList]
  [moves : CompilerRegMoveList]
  [intervals : CompilerRegIntervalList]
  [types : CompilerRegVarTypeList]) : CompilerRegAssignState
  (match candidates
    [(CompilerRegIntervalNil) (CompilerRegAssignState active assignments)]
    [(CompilerRegIntervalCons interval rest)
      (match interval
        [(CompilerRegInterval var start end)
          (let
            [expired : CompilerRegActiveList
              (compiler-reg-expire-active active start)]
            (match (compiler-reg-coalesce-location
              moves
              assignments
              intervals
              types
              var)
              [(CompilerRegSomeLocation location)
                (match location
                  [(CompilerRegRegister reg)
                    (compiler-reg-assign-candidates
                      rest
                      regs
                      (compiler-reg-active-insert
                        expired
                        (CompilerRegActive var end reg))
                      (compiler-reg-assignment-insert assignments var location)
                      moves
                      intervals
                      types)]
                  [(CompilerRegSpill _)
                    (compiler-reg-assign-candidates
                      rest
                      regs
                      expired
                      (compiler-reg-assignment-insert assignments var location)
                      moves
                      intervals
                      types)])]
              [(CompilerRegNoLocation)
                (if (=
                  (compiler-reg-active-count expired)
                  (compiler-reg-string-list-count regs))
                  (match (compiler-reg-spill-at-interval
                    interval
                    expired
                    assignments)
                    [(CompilerRegAssignState next-active next-assignments)
                      (compiler-reg-assign-candidates
                        rest
                        regs
                        next-active
                        next-assignments
                        moves
                        intervals
                        types)])
                  (let
                    [reg : String
                      (compiler-reg-first-free-register regs expired)]
                    (compiler-reg-assign-candidates
                      rest
                      regs
                      (compiler-reg-active-insert
                        expired
                        (CompilerRegActive var end reg))
                      (compiler-reg-assignment-insert
                        assignments
                        var
                        (CompilerRegRegister reg))
                      moves
                      intervals
                      types)))]))])]))

(define (compiler-reg-plan-function [func : CompilerIrFunction]) : CompilerRegPlan
  (let
    [liveness : CompilerFunctionLiveness (compiler-live-analyze-function func)]
    (let
      [types : CompilerRegVarTypeList (compiler-reg-function-var-types func)]
      (let
        [intervals : CompilerRegIntervalList
          (compiler-reg-live-intervals func liveness)]
        (let
          [ineligible : CompilerLiveI64Set
            (compiler-reg-ineligible-vars func liveness types)]
          (match (compiler-reg-assign-candidates
            (compiler-reg-candidates intervals types ineligible false)
            (compiler-reg-sysv-integer-registers)
            CompilerRegActiveNil
            CompilerRegAssignmentNil
            (compiler-reg-function-moves func)
            intervals
            types)
            [(CompilerRegAssignState _ integer-assignments)
              (match (compiler-reg-assign-candidates
                (compiler-reg-candidates intervals types ineligible true)
                (compiler-reg-xmm-registers)
                CompilerRegActiveNil
                integer-assignments
                (compiler-reg-function-moves func)
                intervals
                types)
                [(CompilerRegAssignState _ assignments)
                  (CompilerRegPlan assignments ineligible intervals)])]))))))

(define (compiler-reg-plan-assignments [plan : CompilerRegPlan]) : CompilerRegAssignmentList
  (match plan
    [(CompilerRegPlan assignments _ _) assignments]))

(define (compiler-reg-plan-ineligible [plan : CompilerRegPlan]) : CompilerLiveI64Set
  (match plan
    [(CompilerRegPlan _ ineligible _) ineligible]))

(define (compiler-reg-plan-intervals [plan : CompilerRegPlan]) : CompilerRegIntervalList
  (match plan
    [(CompilerRegPlan _ _ intervals) intervals]))

(define (compiler-reg-location-register?
  [maybe-location : CompilerRegMaybeLocation]
  [reg : String]) : bool
  (match maybe-location
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegRegister found) (string-eq found reg)]
        [_ false])]
    [_ false]))

(define (compiler-reg-location-spill?
  [maybe-location : CompilerRegMaybeLocation]) : bool
  (match maybe-location
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegSpill offset) (< offset 0)]
        [_ false])]
    [_ false]))

(define (compiler-reg-location-spill-offset?
  [maybe-location : CompilerRegMaybeLocation]
  [offset : i64]) : bool
  (match maybe-location
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegSpill found) (= found offset)]
        [_ false])]
    [_ false]))

(define (compiler-reg-unassigned?
  [assignments : CompilerRegAssignmentList]
  [var : i64]) : bool
  (match (compiler-reg-assignment-lookup assignments var)
    [(CompilerRegNoLocation) true]
    [_ false]))

(define (compiler-reg-i64-ty) : AstType
  (AstTyI64))

(define (compiler-reg-f64-ty) : AstType
  (AstTyF64))

(define (compiler-reg-reuse-function) : CompilerIrFunction
  (IrFunction
    "reuse"
    IrParamNil
    (AstTyUnit)
    2
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons
          (IrInstrMov 0 (IrValueI64 1) (compiler-reg-i64-ty))
          (IrInstrCons
            (IrInstrStore "g0" (IrValueVar 0) (compiler-reg-i64-ty))
            (IrInstrCons
              (IrInstrMov 1 (IrValueI64 2) (compiler-reg-i64-ty))
              (IrInstrCons
                (IrInstrReturn (IrSomeValue (IrValueVar 1)))
                IrInstrNil)))))
      IrBlockNil)))

(define (compiler-reg-f64-reuse-function) : CompilerIrFunction
  (IrFunction
    "f64_reuse"
    IrParamNil
    (compiler-reg-f64-ty)
    2
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons
          (IrInstrMov 0 (IrValueF64 "1.5") (compiler-reg-f64-ty))
          (IrInstrCons
            (IrInstrStore "g0" (IrValueVar 0) (compiler-reg-f64-ty))
            (IrInstrCons
              (IrInstrMov 1 (IrValueF64 "2.5") (compiler-reg-f64-ty))
              (IrInstrCons
                (IrInstrReturn (IrSomeValue (IrValueVar 1)))
                IrInstrNil)))))
      IrBlockNil)))

(define (compiler-reg-overlap-function) : CompilerIrFunction
  (IrFunction
    "overlap"
    IrParamNil
    (AstTyUnit)
    8
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons
          (IrInstrMov 0 (IrValueI64 0) (compiler-reg-i64-ty))
          (IrInstrCons
            (IrInstrMov 1 (IrValueI64 1) (compiler-reg-i64-ty))
            (IrInstrCons
              (IrInstrMov 2 (IrValueI64 2) (compiler-reg-i64-ty))
              (IrInstrCons
                (IrInstrMov 3 (IrValueI64 3) (compiler-reg-i64-ty))
                (IrInstrCons
                  (IrInstrMov 4 (IrValueI64 4) (compiler-reg-i64-ty))
                  (IrInstrCons
                    (IrInstrMov 5 (IrValueI64 5) (compiler-reg-i64-ty))
                    (IrInstrCons
                      (IrInstrMov 6 (IrValueI64 6) (compiler-reg-i64-ty))
                      (IrInstrCons
                        (IrInstrStore "g0" (IrValueVar 0) (compiler-reg-i64-ty))
                        (IrInstrCons
                          (IrInstrStore
                            "g1"
                            (IrValueVar 1)
                            (compiler-reg-i64-ty))
                          (IrInstrCons
                            (IrInstrStore
                              "g2"
                              (IrValueVar 2)
                              (compiler-reg-i64-ty))
                            (IrInstrCons
                              (IrInstrStore
                                "g3"
                                (IrValueVar 3)
                                (compiler-reg-i64-ty))
                              (IrInstrCons
                                (IrInstrStore
                                  "g4"
                                  (IrValueVar 4)
                                  (compiler-reg-i64-ty))
                                (IrInstrCons
                                  (IrInstrStore
                                    "g5"
                                    (IrValueVar 5)
                                    (compiler-reg-i64-ty))
                                  (IrInstrCons
                                    (IrInstrStore
                                      "g6"
                                      (IrValueVar 6)
                                      (compiler-reg-i64-ty))
                                    (IrInstrCons
                                      (IrInstrReturn IrNoValue)
                                      IrInstrNil))))))))))))))))
      IrBlockNil)))

(define (compiler-reg-f64-overlap-function) : CompilerIrFunction
  (IrFunction
    "f64_overlap"
    IrParamNil
    (AstTyUnit)
    5
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons
          (IrInstrMov 0 (IrValueF64 "0.5") (compiler-reg-f64-ty))
          (IrInstrCons
            (IrInstrMov 1 (IrValueF64 "1.5") (compiler-reg-f64-ty))
            (IrInstrCons
              (IrInstrMov 2 (IrValueF64 "2.5") (compiler-reg-f64-ty))
              (IrInstrCons
                (IrInstrMov 3 (IrValueF64 "3.5") (compiler-reg-f64-ty))
                (IrInstrCons
                  (IrInstrMov 4 (IrValueF64 "4.5") (compiler-reg-f64-ty))
                  (IrInstrCons
                    (IrInstrStore "g0" (IrValueVar 0) (compiler-reg-f64-ty))
                    (IrInstrCons
                      (IrInstrStore "g1" (IrValueVar 1) (compiler-reg-f64-ty))
                      (IrInstrCons
                        (IrInstrStore "g2" (IrValueVar 2) (compiler-reg-f64-ty))
                        (IrInstrCons
                          (IrInstrStore
                            "g3"
                            (IrValueVar 3)
                            (compiler-reg-f64-ty))
                          (IrInstrCons
                            (IrInstrStore
                              "g4"
                              (IrValueVar 4)
                              (compiler-reg-f64-ty))
                            (IrInstrCons (IrInstrReturn IrNoValue) IrInstrNil))))))))))))
      IrBlockNil)))

(define (compiler-reg-call-live-function) : CompilerIrFunction
  (IrFunction
    "call_live"
    IrParamNil
    (AstTyUnit)
    3
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons
          (IrInstrMov 0 (IrValueI64 9) (compiler-reg-i64-ty))
          (IrInstrCons
            (IrInstrCall 1 "side_effect" IrValueNil (AstTyUnit))
            (IrInstrCons
              (IrInstrMov 2 (IrValueVar 0) (compiler-reg-i64-ty))
              (IrInstrCons
                (IrInstrReturn (IrSomeValue (IrValueVar 2)))
                IrInstrNil)))))
      IrBlockNil)))

(define (compiler-reg-f64-call-live-function) : CompilerIrFunction
  (IrFunction
    "f64_call_live"
    IrParamNil
    (compiler-reg-f64-ty)
    3
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons
          (IrInstrMov 0 (IrValueF64 "9.5") (compiler-reg-f64-ty))
          (IrInstrCons
            (IrInstrCall 1 "side_effect" IrValueNil (AstTyUnit))
            (IrInstrCons
              (IrInstrMov 2 (IrValueVar 0) (compiler-reg-f64-ty))
              (IrInstrCons
                (IrInstrReturn (IrSomeValue (IrValueVar 2)))
                IrInstrNil)))))
      IrBlockNil)))

(define (compiler-reg-call-arg-function) : CompilerIrFunction
  (IrFunction
    "call_arg"
    IrParamNil
    (AstTyUnit)
    4
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons
          (IrInstrMov 0 (IrValueI64 1) (compiler-reg-i64-ty))
          (IrInstrCons
            (IrInstrMov 1 (IrValueI64 2) (compiler-reg-i64-ty))
            (IrInstrCons
              (IrInstrCall
                2
                "use_args"
                (IrValueCons
                  (IrValueVar 0)
                  (IrValueCons (IrValueVar 1) IrValueNil))
                (AstTyUnit))
              (IrInstrCons
                (IrInstrMov 3 (IrValueI64 3) (compiler-reg-i64-ty))
                (IrInstrCons
                  (IrInstrReturn (IrSomeValue (IrValueVar 3)))
                  IrInstrNil))))))
      IrBlockNil)))

(define (compiler-reg-f64-call-arg-function) : CompilerIrFunction
  (IrFunction
    "f64_call_arg"
    IrParamNil
    (compiler-reg-f64-ty)
    3
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons
          (IrInstrMov 0 (IrValueF64 "1.5") (compiler-reg-f64-ty))
          (IrInstrCons
            (IrInstrCall
              1
              "takes_f64"
              (IrValueCons (IrValueVar 0) IrValueNil)
              (AstTyUnit))
            (IrInstrCons
              (IrInstrMov 2 (IrValueF64 "2.5") (compiler-reg-f64-ty))
              (IrInstrCons
                (IrInstrReturn (IrSomeValue (IrValueVar 2)))
                IrInstrNil)))))
      IrBlockNil)))

(define (compiler-reg-ineligible-function) : CompilerIrFunction
  (IrFunction
    "ineligible"
    (IrParamCons (IrParam "arg" (compiler-reg-i64-ty) 0) IrParamNil)
    (AstTyUnit)
    7
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons
          (IrInstrMov 1 (IrValueF64 "1.5") (AstTyF64))
          (IrInstrCons
            (IrInstrMov 2 (IrValueString "heap") (AstTyString))
            (IrInstrCons
              (IrInstrMov 3 (IrValueVar 0) (compiler-reg-i64-ty))
              (IrInstrCons
                (IrInstrMov 4 (IrValueUnit) (AstTyDynArray (AstTyI64)))
                (IrInstrCons
                  (IrInstrMov 5 (IrValueI64 5) (compiler-reg-i64-ty))
                  (IrInstrCons
                    (IrInstrAddrOf 6 3)
                    (IrInstrCons
                      (IrInstrTailMask 7 (IrValueVar 5) (IrValueVar 5) 4)
                      (IrInstrCons
                        (IrInstrReturn (IrSomeValue (IrValueVar 5)))
                        IrInstrNil)))))))))
      IrBlockNil)))

(define (compiler-reg-move-chain-function) : CompilerIrFunction
  (IrFunction
    "move_chain"
    IrParamNil
    (AstTyI64)
    3
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons
          (IrInstrMov 0 (IrValueI64 41) (compiler-reg-i64-ty))
          (IrInstrCons
            (IrInstrMov 1 (IrValueVar 0) (compiler-reg-i64-ty))
            (IrInstrCons
              (IrInstrMov 2 (IrValueVar 1) (compiler-reg-i64-ty))
              (IrInstrCons
                (IrInstrReturn (IrSomeValue (IrValueVar 2)))
                IrInstrNil)))))
      IrBlockNil)))

(define (compiler-reg-phi-join-function) : CompilerIrFunction
  (IrFunction
    "phi_join"
    IrParamNil
    (AstTyI64)
    2
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons
          (IrInstrMov 0 (IrValueI64 7) (compiler-reg-i64-ty))
          (IrInstrCons (IrInstrJump "join") IrInstrNil)))
      (IrBlockCons
        (IrBlock
          "join"
          (IrInstrCons
            (IrInstrPhi
              1
              (IrPhiInputCons (IrPhiInput (IrValueVar 0) "entry") IrPhiInputNil)
              (compiler-reg-i64-ty))
            (IrInstrCons
              (IrInstrReturn (IrSomeValue (IrValueVar 1)))
              IrInstrNil)))
        IrBlockNil))))

(define (compiler-reg-loop-backedge-function) : CompilerIrFunction
  (IrFunction
    "loop_backedge"
    IrParamNil
    (AstTyI64)
    3
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons
          (IrInstrMov 0 (IrValueI64 0) (compiler-reg-i64-ty))
          (IrInstrCons (IrInstrJump "loop") IrInstrNil)))
      (IrBlockCons
        (IrBlock
          "loop"
          (IrInstrCons
            (IrInstrPhi
              1
              (IrPhiInputCons
                (IrPhiInput (IrValueVar 0) "entry")
                (IrPhiInputCons
                  (IrPhiInput (IrValueVar 2) "body")
                  IrPhiInputNil))
              (compiler-reg-i64-ty))
            (IrInstrCons
              (IrInstrMov 2 (IrValueVar 1) (compiler-reg-i64-ty))
              (IrInstrCons
                (IrInstrBranch (IrValueBool false) "body" "exit")
                IrInstrNil))))
        (IrBlockCons
          (IrBlock "body" (IrInstrCons (IrInstrJump "loop") IrInstrNil))
          (IrBlockCons
            (IrBlock
              "exit"
              (IrInstrCons
                (IrInstrReturn (IrSomeValue (IrValueVar 2)))
                IrInstrNil))
            IrBlockNil))))))

(define (compiler-reg-interference-blocks-coalesce-function) : CompilerIrFunction
  (IrFunction
    "interference_blocks_coalesce"
    IrParamNil
    (AstTyI64)
    2
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons
          (IrInstrMov 0 (IrValueI64 9) (compiler-reg-i64-ty))
          (IrInstrCons
            (IrInstrMov 1 (IrValueVar 0) (compiler-reg-i64-ty))
            (IrInstrCons
              (IrInstrStore "keep" (IrValueVar 0) (compiler-reg-i64-ty))
              (IrInstrCons
                (IrInstrReturn (IrSomeValue (IrValueVar 1)))
                IrInstrNil)))))
      IrBlockNil)))

(define (compiler-reg-spill-coalesce-function) : CompilerIrFunction
  (IrFunction
    "spill_coalesce"
    IrParamNil
    (AstTyI64)
    6
    (IrBlockCons
      (IrBlock
        "entry"
        (IrInstrCons
          (IrInstrMov 0 (IrValueI64 0) (compiler-reg-i64-ty))
          (IrInstrCons
            (IrInstrMov 1 (IrValueI64 1) (compiler-reg-i64-ty))
            (IrInstrCons
              (IrInstrMov 2 (IrValueI64 2) (compiler-reg-i64-ty))
              (IrInstrCons
                (IrInstrMov 3 (IrValueI64 3) (compiler-reg-i64-ty))
                (IrInstrCons
                  (IrInstrMov 4 (IrValueI64 4) (compiler-reg-i64-ty))
                  (IrInstrCons
                    (IrInstrStore "g0" (IrValueVar 0) (compiler-reg-i64-ty))
                    (IrInstrCons
                      (IrInstrStore "g1" (IrValueVar 1) (compiler-reg-i64-ty))
                      (IrInstrCons
                        (IrInstrStore "g2" (IrValueVar 2) (compiler-reg-i64-ty))
                        (IrInstrCons
                          (IrInstrStore
                            "g3"
                            (IrValueVar 3)
                            (compiler-reg-i64-ty))
                          (IrInstrCons
                            (IrInstrMov 5 (IrValueVar 4) (compiler-reg-i64-ty))
                            (IrInstrCons
                              (IrInstrReturn (IrSomeValue (IrValueVar 5)))
                              IrInstrNil))))))))))))
      IrBlockNil)))

(define (compiler-reg-reuse-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-reuse-function))
    [(CompilerRegPlan assignments _ _)
      (and
        (= (compiler-reg-assignment-count assignments) 2)
        (and
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 0)
            "%r12")
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 1)
            "%r12")))]))

(define (compiler-reg-f64-reuse-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-f64-reuse-function))
    [(CompilerRegPlan assignments _ _)
      (and
        (= (compiler-reg-assignment-count assignments) 2)
        (and
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 0)
            "%xmm2")
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 1)
            "%xmm2")))]))

(define (compiler-reg-overlap-spill-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-overlap-function))
    [(CompilerRegPlan assignments _ _)
      (and
        (= (compiler-reg-assignment-count assignments) 7)
        (and
          (= (compiler-reg-spill-count assignments) 1)
          (and
            (compiler-reg-location-register?
              (compiler-reg-assignment-lookup assignments 4)
              "%r8")
            (and
              (compiler-reg-location-register?
                (compiler-reg-assignment-lookup assignments 5)
                "%r9")
              (compiler-reg-location-spill-offset?
                (compiler-reg-assignment-lookup assignments 6)
                (compiler-reg-stack-slot-offset 6))))))]))

(define (compiler-reg-f64-overlap-spill-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-f64-overlap-function))
    [(CompilerRegPlan assignments _ _)
      (and
        (= (compiler-reg-assignment-count assignments) 5)
        (and
          (= (compiler-reg-spill-count assignments) 1)
          (and
            (compiler-reg-location-register?
              (compiler-reg-assignment-lookup assignments 0)
              "%xmm2")
            (and
              (compiler-reg-location-register?
                (compiler-reg-assignment-lookup assignments 1)
                "%xmm3")
              (and
                (compiler-reg-location-register?
                  (compiler-reg-assignment-lookup assignments 2)
                  "%xmm4")
                (and
                  (compiler-reg-location-register?
                    (compiler-reg-assignment-lookup assignments 3)
                    "%xmm5")
                  (compiler-reg-location-spill-offset?
                    (compiler-reg-assignment-lookup assignments 4)
                    (compiler-reg-stack-slot-offset 4))))))))]))

(define (compiler-reg-call-live-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-call-live-function))
    [(CompilerRegPlan assignments ineligible _)
      (and
        (compiler-live-set-contains? ineligible 0)
        (and
          (compiler-live-set-contains? ineligible 1)
          (and
            (compiler-reg-unassigned? assignments 0)
            (compiler-reg-location-register?
              (compiler-reg-assignment-lookup assignments 2)
              "%r12"))))]))

(define (compiler-reg-f64-call-live-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-f64-call-live-function))
    [(CompilerRegPlan assignments ineligible _)
      (and
        (compiler-live-set-contains? ineligible 0)
        (and
          (compiler-live-set-contains? ineligible 1)
          (and
            (compiler-reg-unassigned? assignments 0)
            (and
              (compiler-reg-unassigned? assignments 1)
              (compiler-reg-location-register?
                (compiler-reg-assignment-lookup assignments 2)
                "%xmm2")))))]))

(define (compiler-reg-call-arg-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-call-arg-function))
    [(CompilerRegPlan assignments ineligible _)
      (and
        (compiler-live-set-contains? ineligible 0)
        (and
          (compiler-live-set-contains? ineligible 1)
          (and
            (compiler-reg-unassigned? assignments 0)
            (and
              (compiler-reg-unassigned? assignments 1)
              (compiler-reg-location-register?
                (compiler-reg-assignment-lookup assignments 3)
                "%r12")))))]))

(define (compiler-reg-f64-call-arg-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-f64-call-arg-function))
    [(CompilerRegPlan assignments ineligible _)
      (and
        (compiler-live-set-contains? ineligible 0)
        (and
          (compiler-reg-unassigned? assignments 0)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 2)
            "%xmm2")))]))

(define (compiler-reg-ineligible-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-ineligible-function))
    [(CompilerRegPlan assignments ineligible _)
      (let
        [marked : bool
          (and
            (compiler-live-set-contains? ineligible 0)
            (and
              (compiler-live-set-contains? ineligible 2)
              (and
                (compiler-live-set-contains? ineligible 3)
                (and
                  (compiler-live-set-contains? ineligible 4)
                  (and
                    (compiler-live-set-contains? ineligible 6)
                    (compiler-live-set-contains? ineligible 7))))))]
        [unassigned : bool
          (and
            (compiler-reg-unassigned? assignments 0)
            (and
              (compiler-reg-unassigned? assignments 2)
              (and
                (compiler-reg-unassigned? assignments 3)
                (and
                  (compiler-reg-unassigned? assignments 4)
                  (and
                    (compiler-reg-unassigned? assignments 6)
                    (compiler-reg-unassigned? assignments 7))))))]
        [homes : bool
          (and
            (compiler-reg-location-register?
              (compiler-reg-assignment-lookup assignments 1)
              "%xmm2")
            (compiler-reg-location-register?
              (compiler-reg-assignment-lookup assignments 5)
              "%r12"))]
        (and marked (and unassigned homes)))]))

(define (compiler-reg-same-location?
  [assignments : CompilerRegAssignmentList]
  [left : i64]
  [right : i64]) : bool
  (match (compiler-reg-assignment-lookup assignments left)
    [(CompilerRegSomeLocation left-location)
      (match (compiler-reg-assignment-lookup assignments right)
        [(CompilerRegSomeLocation right-location)
          (compiler-reg-location-eq? left-location right-location)]
        [(CompilerRegNoLocation) false])]
    [(CompilerRegNoLocation) false]))

(define (compiler-reg-different-location?
  [assignments : CompilerRegAssignmentList]
  [left : i64]
  [right : i64]) : bool
  (match (compiler-reg-assignment-lookup assignments left)
    [(CompilerRegSomeLocation left-location)
      (match (compiler-reg-assignment-lookup assignments right)
        [(CompilerRegSomeLocation right-location)
          (not (compiler-reg-location-eq? left-location right-location))]
        [(CompilerRegNoLocation) false])]
    [(CompilerRegNoLocation) false]))

(define (compiler-reg-coalesce-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-move-chain-function))
    [(CompilerRegPlan chain-assignments _ _)
      (match (compiler-reg-plan-function (compiler-reg-phi-join-function))
        [(CompilerRegPlan phi-assignments _ _)
          (match (compiler-reg-plan-function
            (compiler-reg-loop-backedge-function))
            [(CompilerRegPlan loop-assignments _ _)
              (match (compiler-reg-plan-function
                (compiler-reg-interference-blocks-coalesce-function))
                [(CompilerRegPlan blocked-assignments _ _)
                  (match (compiler-reg-plan-function
                    (compiler-reg-spill-coalesce-function))
                    [(CompilerRegPlan spill-assignments _ _)
                      (and
                        (compiler-reg-same-location? chain-assignments 0 1)
                        (and
                          (compiler-reg-same-location? chain-assignments 1 2)
                          (and
                            (compiler-reg-same-location? phi-assignments 0 1)
                            (and
                              (compiler-reg-different-location?
                                loop-assignments
                                1
                                2)
                              (and
                                (compiler-reg-different-location?
                                  blocked-assignments
                                  0
                                  1)
                                (compiler-reg-same-location?
                                  spill-assignments
                                  4
                                  5))))))])])])])]))

(define (compiler-reg-target-clobbers-ok?) : bool
  (let
    [sysv-callers : CompilerRegStringList
      (compiler-reg-sysv-caller-saved-integer-registers)]
    [sysv-callees : CompilerRegStringList
      (compiler-reg-sysv-callee-saved-integer-registers)]
    [win-callers : CompilerRegStringList
      (compiler-reg-win64-caller-saved-integer-registers)]
    [win-callees : CompilerRegStringList
      (compiler-reg-win64-callee-saved-integer-registers)]
    (and
      (compiler-reg-string-list-contains? sysv-callers "%rdi")
      (and
        (not (compiler-reg-string-list-contains? sysv-callees "%rdi"))
        (and
          (compiler-reg-string-list-contains? win-callees "%rdi")
          (and
            (not (compiler-reg-string-list-contains? win-callers "%rdi"))
            (and
              (not
                (=
                  (compiler-reg-string-list-count
                    (compiler-reg-sysv-integer-registers))
                  (compiler-reg-string-list-count win-callees)))
              (and
                (compiler-reg-string-list-contains?
                  (compiler-reg-sysv-integer-registers)
                  "%r8")
                (compiler-reg-string-list-contains?
                  (compiler-reg-sysv-integer-registers)
                  "%r9")))))))))

(define (compiler-reg-xmm-clobbers-ok?) : bool
  (let
    [pool : CompilerRegStringList (compiler-reg-xmm-registers)]
    [sysv-callers : CompilerRegStringList
      (compiler-reg-sysv-caller-saved-xmm-registers)]
    [sysv-callees : CompilerRegStringList
      (compiler-reg-sysv-callee-saved-xmm-registers)]
    [win-callers : CompilerRegStringList
      (compiler-reg-win64-caller-saved-xmm-registers)]
    [win-callees : CompilerRegStringList
      (compiler-reg-win64-callee-saved-xmm-registers)]
    [pool-ok : bool
      (and
        (compiler-reg-string-list-contains? pool "%xmm2")
        (and
          (compiler-reg-string-list-contains? pool "%xmm5")
          (and
            (not (compiler-reg-string-list-contains? pool "%xmm0"))
            (and
              (not (compiler-reg-string-list-contains? pool "%xmm1"))
              (and
                (not (compiler-reg-string-list-contains? pool "%xmm6"))
                (not (compiler-reg-string-list-contains? pool "%xmm15")))))))]
    [sysv-ok : bool
      (and
        (compiler-reg-string-list-contains? sysv-callers "%xmm14")
        (not (compiler-reg-string-list-contains? sysv-callees "%xmm14")))]
    [win-ok : bool
      (and
        (compiler-reg-string-list-contains? win-callers "%xmm5")
        (and
          (not (compiler-reg-string-list-contains? win-callers "%xmm6"))
          (compiler-reg-string-list-contains? win-callees "%xmm6")))]
    [counts-ok : bool
      (and
        (= (compiler-reg-string-list-count sysv-callers) 16)
        (and
          (= (compiler-reg-string-list-count sysv-callees) 0)
          (and
            (= (compiler-reg-string-list-count win-callers) 6)
            (= (compiler-reg-string-list-count win-callees) 10))))]
    (and pool-ok (and sysv-ok (and win-ok counts-ok)))))

(define (compiler-regalloc-self-test) : i64
  (if (and
    (compiler-reg-reuse-ok?)
    (and
      (compiler-reg-f64-reuse-ok?)
      (and
        (compiler-reg-overlap-spill-ok?)
        (and
          (compiler-reg-f64-overlap-spill-ok?)
          (and
            (compiler-reg-call-live-ok?)
            (and
              (compiler-reg-f64-call-live-ok?)
              (and
                (compiler-reg-call-arg-ok?)
                (and
                  (compiler-reg-f64-call-arg-ok?)
                  (and
                    (compiler-reg-ineligible-ok?)
                    (and
                      (compiler-reg-target-clobbers-ok?)
                      (and
                        (compiler-reg-xmm-clobbers-ok?)
                        (compiler-reg-coalesce-ok?))))))))))))
    42
    (begin
      (panic "regalloc: smoke mismatch")
      0)))