;; compiler_regalloc.tl - Planning-only scalar register allocation (#554).
;;
;; This pass mirrors the legacy backend's planning shape without changing
;; assembly emission. It computes inspectable live intervals, ineligible vars,
;; and register/spill homes for scalar IR values. The selfhost pools keep
;; %rsp/%rbp reserved and admit caller-saved integer/XMM registers only for
;; values that cannot be clobbered by call emission.
(import stdlib.io)
(import stdlib.array)
(import stdlib.string)
(import stdlib.str_cat)
(import stdlib.hashmap)
(import "compiler_liveness.tl")
(cfg test (import stdlib.test))

(defenum CompilerRegStringList
  (CompilerRegStringNil)
  (CompilerRegStringCons String (Box CompilerRegStringList)))

(defenum CompilerRegLocation
  (CompilerRegRegister String)
  ;; #2386: a 2-word register-group value lives in two GP registers (word0,
  ;; word1). A group that cannot get two registers spills to a 16-byte slot,
  ;; represented as the ordinary CompilerRegSpill (the backend reads the second
  ;; word at offset-8 using the program word-count map).
  (CompilerRegRegisterPair String String)
  (CompilerRegSpill i64)
  ;; Rematerialization: a single-def value whose definition is a cheap static
  ;; recompute (a constant or an address materialization `leaq label(%rip)`) is
  ;; not spilled to a slot under pressure -- it is RECOMPUTED at each use and its
  ;; defining store is dropped. The carried IrValue is exactly what the def Mov
  ;; produced, so recomputing always yields the identical value.
  (CompilerRegRemat CompilerIrValue))

(defenum CompilerRegMaybeLocation
  (CompilerRegNoLocation)
  (CompilerRegSomeLocation CompilerRegLocation))

(defenum CompilerRegMaybeString
  (CompilerRegNoString)
  (CompilerRegSomeString String))

(defenum CompilerRegTargetAbi
  (CompilerRegAbiLinux)
  (CompilerRegAbiWindows))

(defenum CompilerRegAssignment
  (CompilerRegAssignment i64 CompilerRegLocation))

(defenum CompilerRegAssignmentList
  (CompilerRegAssignmentNil)
  (CompilerRegAssignmentCons
    CompilerRegAssignment
    (Box CompilerRegAssignmentList)))

(defenum CompilerRegInterval
  (CompilerRegInterval i64 i64 i64))

(defenum CompilerRegIntervalList
  (CompilerRegIntervalNil)
  (CompilerRegIntervalCons CompilerRegInterval (Box CompilerRegIntervalList)))

(defenum CompilerRegMaybeInterval
  (CompilerRegNoInterval)
  (CompilerRegSomeInterval CompilerRegInterval))

(defenum CompilerRegVarType
  (CompilerRegVarType i64 AstType))

(defenum CompilerRegVarTypeList
  (CompilerRegVarTypeNil)
  (CompilerRegVarTypeCons CompilerRegVarType (Box CompilerRegVarTypeList)))

(defenum CompilerRegMaybeType
  (CompilerRegNoType)
  (CompilerRegSomeType AstType))

(defstruct CompilerRegVarTypes
  (entries CompilerRegVarTypeList)
  (present (Array i64))
  (items (Array AstType)))

(defstruct CompilerRegAssignmentIndex
  (present (Array i64))
  (items (Array CompilerRegLocation)))

(defstruct CompilerRegAssignmentTable
  (present (Array i64))
  (items (Array CompilerRegLocation)))

(defstruct CompilerRegIntervalIndex
  (starts (Array i64))
  (ends (Array i64))
  (segments (Array CompilerRegIntervalList)))

(defenum CompilerRegIntervalSelection
  (CompilerRegIntervalSelection
    CompilerRegIntervalList
    CompilerRegIntervalIndex))

(defenum CompilerRegActive
  (CompilerRegActive i64 i64 String))

(defenum CompilerRegActiveList
  (CompilerRegActiveNil)
  (CompilerRegActiveCons CompilerRegActive (Box CompilerRegActiveList)))

(defenum CompilerRegMaybeActive
  (CompilerRegNoActive)
  (CompilerRegSomeActive CompilerRegActive))

(defenum CompilerRegPlan
  (CompilerRegPlan
    CompilerRegAssignmentList
    CompilerLiveI64Set
    CompilerRegIntervalList
    CompilerRegVarTypeList
    CompilerLiveI64Set))

(defenum CompilerRegAssignState
  (CompilerRegAssignState CompilerRegActiveList CompilerRegAssignmentTable))

(defenum CompilerRegCallSaveAssignState
  (CompilerRegCallSaveAssignState CompilerRegAssignmentTable CompilerLiveI64Set))

(defenum CompilerRegCallSaveRewrite
  (CompilerRegCallSaveRewrite
    CompilerIrBlockList
    i64
    i64
    CompilerRegAssignmentList
    CompilerRegVarTypeList))

(defenum CompilerRegCallSaveInstrRewrite
  (CompilerRegCallSaveInstrRewrite
    CompilerIrInstrList
    i64
    i64
    CompilerRegAssignmentList
    CompilerRegVarTypeList))

(defstruct CompilerRegRematTable
  (def-counts (Array i64))
  (candidates (Array i64))
  (kinds (Array i64))
  (values (Array CompilerIrValue))
  (offsets (Array CompilerIrValue))
  (op-types (Array AstType))
  (types (Array AstType)))

(define (compiler-reg-remat-kind-mov) : i64
  1)

(define (compiler-reg-remat-kind-load) : i64
  2)

(define (compiler-reg-remat-kind-gep) : i64
  3)

(defenum CompilerRegMaybeCallSaveActive
  (CompilerRegNoCallSaveActive)
  (CompilerRegSomeCallSaveActive i64 i64 AstType))

(defenum CompilerRegEdgeCopyDirection
  (CompilerRegEdgeCopyIntoRegion)
  (CompilerRegEdgeCopyOutOfRegion))

(defenum CompilerRegEdgeCopyPlacement
  (CompilerRegEdgeCopyPredEnd)
  (CompilerRegEdgeCopySuccEntry))

(defenum CompilerRegEdgeCopy
  (CompilerRegEdgeCopy
    String
    String
    i64
    i64
    AstType
    CompilerRegEdgeCopyDirection
    CompilerRegEdgeCopyPlacement))

(defenum CompilerRegEdgeCopyList
  (CompilerRegEdgeCopyNil)
  (CompilerRegEdgeCopyCons CompilerRegEdgeCopy (Box CompilerRegEdgeCopyList)))

(defenum CompilerRegEdgeCopyPlacementResult
  (CompilerRegEdgeCopyPlacementOk CompilerRegEdgeCopyPlacement)
  (CompilerRegEdgeCopyPlacementRefused String))

(defenum CompilerRegEdgeCopyPlan
  (CompilerRegEdgeCopyPlan CompilerRegEdgeCopyList)
  (CompilerRegEdgeCopyRefused String))

(defenum CompilerRegEdgeCopyRewrite
  (CompilerRegEdgeCopyRewrite CompilerIrBlockList)
  (CompilerRegEdgeCopyRewriteRefused String))

(defenum CompilerRegLoopSplitCandidate
  (CompilerRegLoopSplitNoCandidate)
  (CompilerRegLoopSplitCandidate
    i64
    String
    AstType
    String
    CompilerRegEdgeCopyList))

(defenum CompilerRegParamAssignPlan
  (CompilerRegParamAssignPlan
    CompilerRegAssignmentTable
    CompilerLiveI64Set
    CompilerLiveI64Set))

(cfg
  (any regalloc-census test)
  (defstruct CompilerRegCallSpanCensus
    (counts (Array i64))))

(defenum CompilerRegMove
  (CompilerRegMove i64 i64 bool))

(defenum CompilerRegMoveList
  (CompilerRegMoveNil)
  (CompilerRegMoveCons CompilerRegMove (Box CompilerRegMoveList)))

;; Deterministic move-copy classes used by scalar home coalescing. Roots are the
;; lowest var id in each class; allocation then reuses any assigned class home.
(defstruct CompilerRegCoalesceMap
  (parents (Array i64)))

(define (compiler-reg-string-cons
  [head : String]
  [rest : CompilerRegStringList]) : CompilerRegStringList
  (CompilerRegStringCons head (box rest)))

(define (compiler-reg-assignment-cons
  [head : CompilerRegAssignment]
  [rest : CompilerRegAssignmentList]) : CompilerRegAssignmentList
  (CompilerRegAssignmentCons head (box rest)))

(define (compiler-reg-interval-cons
  [head : CompilerRegInterval]
  [rest : CompilerRegIntervalList]) : CompilerRegIntervalList
  (CompilerRegIntervalCons head (box rest)))

(define (compiler-reg-var-type-cons
  [head : CompilerRegVarType]
  [rest : CompilerRegVarTypeList]) : CompilerRegVarTypeList
  (CompilerRegVarTypeCons head (box rest)))

(define (compiler-reg-edge-copy-cons
  [head : CompilerRegEdgeCopy]
  [rest : CompilerRegEdgeCopyList]) : CompilerRegEdgeCopyList
  (CompilerRegEdgeCopyCons head (box rest)))

(define (compiler-reg-active-cons
  [head : CompilerRegActive]
  [rest : CompilerRegActiveList]) : CompilerRegActiveList
  (CompilerRegActiveCons head (box rest)))

(define (compiler-reg-move-cons
  [head : CompilerRegMove]
  [rest : CompilerRegMoveList]) : CompilerRegMoveList
  (CompilerRegMoveCons head (box rest)))

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

;; Allocatable integer register pool. Only callee-saved registers are admitted
;; by the primary pass:
;; a value whose live interval spans a call keeps its home across that call
;; because the callee preserves these registers, so no spill/reload around the
;; call is needed. The former pool also offered %r8/%r9, which are caller-saved
;; under both SysV and Win64 and are clobbered by an intervening call — a value
;; homed there and read after the call (e.g. the first operand of `(+ a (f))`)
;; would silently observe garbage. The five registers below are exactly those
;; the backend prologue/epilogue save and restore. Mirrors the former Rust
;; backend's `SYSV_ALLOCATABLE_INTEGER_REGS` (callee-saved only).
;;
;; %rbx is callee-saved under both SysV and Win64 and was historically reserved
;; as the backend's hard scratch register for the right-hand operand of integer
;; binops/compares/gep/div/shift. That fixed scratch role moved under the
;; scavenger, freeing %rbx to join the callee-saved pool. It is added LAST so
;; functions needing four or fewer registers keep their previous r12-r15 homes;
;; %rbx only homes a value once the four call-safe registers are exhausted, and
;; when it does the backend prologue/epilogue saves/restores it into a frame slot
;; exactly like r12-r15.
(define (compiler-reg-sysv-integer-registers) : CompilerRegStringList
  (compiler-reg-string-cons
    "%r12"
    (compiler-reg-string-cons
      "%r13"
      (compiler-reg-string-cons
        "%r14"
        (compiler-reg-string-cons
          "%r15"
          (compiler-reg-string-cons "%rbx" CompilerRegStringNil))))))

(define (compiler-reg-sysv-integer-register-count) : i64
  (compiler-reg-string-list-count (compiler-reg-sysv-integer-registers)))

;; Conservative caller-saved extension for the scalar opt2 pass. These registers
;; are caller-saved on both SysV and Win64, are not callee-saved registers that
;; would need prologue/epilogue save/restore, and are used only for intervals
;; that do not span a modeled backend caller-clobber point. This legacy helper is
;; intentionally the three-register subset; the unified greedy pool owns
;; %r10/%r11/%r8 behind the same clobber filter.
(define (compiler-reg-zero-call-caller-saved-integer-registers) : CompilerRegStringList
  (compiler-reg-string-cons
    "%r9"
    (compiler-reg-string-cons
      "%rcx"
      (compiler-reg-string-cons "%rdx" CompilerRegStringNil))))

(define (compiler-reg-sysv-caller-saved-integer-registers) : CompilerRegStringList
  (compiler-reg-string-cons
    "%rax"
    (compiler-reg-string-cons
      "%rcx"
      (compiler-reg-string-cons
        "%rdx"
        (compiler-reg-string-cons
          "%rsi"
          (compiler-reg-string-cons
            "%rdi"
            (compiler-reg-string-cons
              "%r8"
              (compiler-reg-string-cons
                "%r9"
                (compiler-reg-string-cons
                  "%r10"
                  (compiler-reg-string-cons "%r11" CompilerRegStringNil))))))))))

(define (compiler-reg-sysv-callee-saved-integer-registers) : CompilerRegStringList
  (compiler-reg-string-cons
    "%rbx"
    (compiler-reg-string-cons
      "%r12"
      (compiler-reg-string-cons
        "%r13"
        (compiler-reg-string-cons
          "%r14"
          (compiler-reg-string-cons "%r15" CompilerRegStringNil))))))

(define (compiler-reg-win64-caller-saved-integer-registers) : CompilerRegStringList
  (compiler-reg-string-cons
    "%rax"
    (compiler-reg-string-cons
      "%rcx"
      (compiler-reg-string-cons
        "%rdx"
        (compiler-reg-string-cons
          "%r8"
          (compiler-reg-string-cons
            "%r9"
            (compiler-reg-string-cons
              "%r10"
              (compiler-reg-string-cons "%r11" CompilerRegStringNil))))))))

(define (compiler-reg-win64-callee-saved-integer-registers) : CompilerRegStringList
  (compiler-reg-string-cons
    "%rbx"
    (compiler-reg-string-cons
      "%rsi"
      (compiler-reg-string-cons
        "%rdi"
        (compiler-reg-string-cons
          "%r12"
          (compiler-reg-string-cons
            "%r13"
            (compiler-reg-string-cons
              "%r14"
              (compiler-reg-string-cons "%r15" CompilerRegStringNil))))))))

;; Persistent float homes use XMM registers that are caller-saved on both SysV
;; and Windows x64, avoid %xmm0/%xmm1 arithmetic scratch, avoid %xmm15 outgoing
;; stack-argument scratch, and avoid Windows callee-saved XMM6-XMM15 until the
;; backend has save/restore support for those registers.
(define (compiler-reg-xmm-registers) : CompilerRegStringList
  (compiler-reg-string-cons
    "%xmm2"
    (compiler-reg-string-cons
      "%xmm3"
      (compiler-reg-string-cons
        "%xmm4"
        (compiler-reg-string-cons "%xmm5" CompilerRegStringNil)))))

(define (compiler-reg-vector-registers) : CompilerRegStringList
  (compiler-reg-string-cons
    "%vec6"
    (compiler-reg-string-cons
      "%vec7"
      (compiler-reg-string-cons
        "%vec8"
        (compiler-reg-string-cons
          "%vec9"
          (compiler-reg-string-cons
            "%vec10"
            (compiler-reg-string-cons
              "%vec11"
              (compiler-reg-string-cons
                "%vec12"
                (compiler-reg-string-cons "%vec13" CompilerRegStringNil)))))))))

(define (compiler-reg-mask-registers) : CompilerRegStringList
  (compiler-reg-string-cons
    "%k1"
    (compiler-reg-string-cons
      "%k2"
      (compiler-reg-string-cons
        "%k3"
        (compiler-reg-string-cons
          "%k4"
          (compiler-reg-string-cons
            "%k5"
            (compiler-reg-string-cons "%k6" CompilerRegStringNil)))))))

(define (compiler-reg-sysv-caller-saved-xmm-registers) : CompilerRegStringList
  (compiler-reg-string-cons
    "%xmm0"
    (compiler-reg-string-cons
      "%xmm1"
      (compiler-reg-string-cons
        "%xmm2"
        (compiler-reg-string-cons
          "%xmm3"
          (compiler-reg-string-cons
            "%xmm4"
            (compiler-reg-string-cons
              "%xmm5"
              (compiler-reg-string-cons
                "%xmm6"
                (compiler-reg-string-cons
                  "%xmm7"
                  (compiler-reg-string-cons
                    "%xmm8"
                    (compiler-reg-string-cons
                      "%xmm9"
                      (compiler-reg-string-cons
                        "%xmm10"
                        (compiler-reg-string-cons
                          "%xmm11"
                          (compiler-reg-string-cons
                            "%xmm12"
                            (compiler-reg-string-cons
                              "%xmm13"
                              (compiler-reg-string-cons
                                "%xmm14"
                                (compiler-reg-string-cons
                                  "%xmm15"
                                  CompilerRegStringNil)))))))))))))))))

(define (compiler-reg-sysv-callee-saved-xmm-registers) : CompilerRegStringList
  CompilerRegStringNil)

(define (compiler-reg-win64-caller-saved-xmm-registers) : CompilerRegStringList
  (compiler-reg-string-cons
    "%xmm0"
    (compiler-reg-string-cons
      "%xmm1"
      (compiler-reg-string-cons
        "%xmm2"
        (compiler-reg-string-cons
          "%xmm3"
          (compiler-reg-string-cons
            "%xmm4"
            (compiler-reg-string-cons "%xmm5" CompilerRegStringNil)))))))

(define (compiler-reg-win64-callee-saved-xmm-registers) : CompilerRegStringList
  (compiler-reg-string-cons
    "%xmm6"
    (compiler-reg-string-cons
      "%xmm7"
      (compiler-reg-string-cons
        "%xmm8"
        (compiler-reg-string-cons
          "%xmm9"
          (compiler-reg-string-cons
            "%xmm10"
            (compiler-reg-string-cons
              "%xmm11"
              (compiler-reg-string-cons
                "%xmm12"
                (compiler-reg-string-cons
                  "%xmm13"
                  (compiler-reg-string-cons
                    "%xmm14"
                    (compiler-reg-string-cons "%xmm15" CompilerRegStringNil)))))))))))

(define (compiler-reg-string-list-count [regs : CompilerRegStringList]) : i64
  (match regs
    [(CompilerRegStringNil) 0]
    [(CompilerRegStringCons _ rest)
      (+ 1 (compiler-reg-string-list-count (box-get rest)))]))

(define (compiler-reg-string-list-contains?
  [regs : CompilerRegStringList]
  [want : String]) : bool
  (match regs
    [(CompilerRegStringNil) false]
    [(CompilerRegStringCons reg rest)
      (if (string.string-eq reg want)
        true
        (compiler-reg-string-list-contains? (box-get rest) want))]))

(define (compiler-reg-float-type? [ty : AstType]) : bool
  (match ty
    [(AstTyF64) true]
    [(AstTyF32) true]
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
    [(AstTyF32) true]
    [(AstTyBool) true]
    [(AstTyChar) true]
    [(AstTyFunc _ _) true]
    [(AstTyPtr _) true]
    [(AstTyMutPtr _) true]
    [(AstTyRef _ _) true]
    [(AstTyMutRef _ _) true]
    [_ false]))

;; Aggregate types represented as a single 8-byte handle (an arena/heap pointer
;; or a fat-string descriptor pointer). Their VALUES are register-sized, so a var
;; of one of these types can live in a callee-saved register exactly like a raw
;; pointer — the backend already moves them with a plain movq. Values whose
;; address is taken (AddrOf/Gep/Alloc) stay on the stack via the memory rule, so
;; register homing here is safe. Zero-sized AstTyExpr/AstTyExprList are excluded.
(define (compiler-reg-handle-type? [ty : AstType]) : bool
  (match ty
    [(AstTyString) true]
    [(AstTyStr) true]
    [(AstTyBox _) true]
    [(AstTyArray _ _) true]
    [(AstTyDynArray _) true]
    [(AstTyEnum _) true]
    [(AstTyEnumArgs _ _) true]
    [(AstTyStruct _) true]
    [(AstTyStructArgs _ _) true]
    [(AstTyVar _) true]
    [(AstTyVarArgs _ _) true]
    [_ false]))

(define (compiler-reg-register-eligible-type? [ty : AstType]) : bool
  (if (compiler-reg-scalar-type? ty)
    true
    (compiler-reg-handle-type? ty)))

(define (compiler-reg-var-type-insert
  [types : CompilerRegVarTypeList]
  [var : i64]
  [ty : AstType]) : CompilerRegVarTypeList
  (match types
    [(CompilerRegVarTypeNil)
      (compiler-reg-var-type-cons
        (CompilerRegVarType var ty)
        CompilerRegVarTypeNil)]
    [(CompilerRegVarTypeCons item rest)
      (match item
        [(CompilerRegVarType id _)
          (if (= id var)
            (compiler-reg-var-type-cons
              (CompilerRegVarType var ty)
              (box-get rest))
            (if (> id var)
              (compiler-reg-var-type-cons (CompilerRegVarType var ty) types)
              (compiler-reg-var-type-cons
                item
                (compiler-reg-var-type-insert (box-get rest) var ty))))])]))

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
              (compiler-reg-var-type-lookup (box-get rest) var)))])]))

(define (compiler-reg-var-types-list [types : CompilerRegVarTypes]) : CompilerRegVarTypeList
  (struct-get types entries))

(define (compiler-reg-var-types-lookup
  [types : CompilerRegVarTypes]
  [var : i64]) : CompilerRegMaybeType
  (let
    [present : (Array i64) (struct-get types present)]
    [items : (Array AstType) (struct-get types items)]
    (if (or (< var 0) (>= var (array.array-length present)))
      CompilerRegNoType
      (if (= (array.array-ref present var) 0)
        CompilerRegNoType
        (CompilerRegSomeType (array.array-ref items var))))))

(define (compiler-reg-param-types
  [params : CompilerIrParamList]
  [types : CompilerRegVarTypeList]) : CompilerRegVarTypeList
  (match params
    [(IrParamNil) types]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ ty id)
          (compiler-reg-param-types
            (box-get rest)
            (compiler-reg-var-type-insert types id ty))])]))

(define (compiler-reg-addr-of-result-type) : AstType
  (ast-ty-mut-ptr (AstTyU8)))

(define (compiler-reg-instr-def-type
  [types : CompilerRegVarTypeList]
  [instr : CompilerIrInstr]) : CompilerRegVarTypeList
  (match instr
    [(IrInstrMov dst _ ty) (compiler-reg-var-type-insert types dst ty)]
    [(IrInstrAddrOf dst _)
      (compiler-reg-var-type-insert
        types
        dst
        (compiler-reg-addr-of-result-type))]
    [(IrInstrLoad dst _ ty) (compiler-reg-var-type-insert types dst ty)]
    [(IrInstrCast dst _ _ to-ty) (compiler-reg-var-type-insert types dst to-ty)]
    [(IrInstrBitcast dst _ _ to-ty)
      (compiler-reg-var-type-insert types dst to-ty)]
    [(IrInstrBinOp dst _ _ _ ty) (compiler-reg-var-type-insert types dst ty)]
    [(IrInstrUnOp dst _ _ ty) (compiler-reg-var-type-insert types dst ty)]
    [(IrInstrVectorReduce dst _ _ _ elem-ty)
      (compiler-reg-var-type-insert types dst elem-ty)]
    [(IrInstrMaskReduce dst _ _ _)
      (compiler-reg-var-type-insert types dst (AstTyBool))]
    [(IrInstrEntryArgc dst) (compiler-reg-var-type-insert types dst (AstTyI64))]
    [(IrInstrEntryArgv dst)
      (compiler-reg-var-type-insert
        types
        dst
        (ast-ty-ptr (ast-ty-ptr (AstTyU8))))]
    [(IrInstrEntryEnvp dst)
      (compiler-reg-var-type-insert
        types
        dst
        (ast-ty-ptr (ast-ty-ptr (AstTyU8))))]
    [(IrInstrCpuId dst _ _ _)
      (compiler-reg-var-type-insert types dst (AstTyI64))]
    [(IrInstrXgetbv dst _) (compiler-reg-var-type-insert types dst (AstTyI64))]
    [(IrInstrSyscall dst _) (compiler-reg-var-type-insert types dst (AstTyI64))]
    [(IrInstrCall dst _ _ ty) (compiler-reg-var-type-insert types dst ty)]
    [(IrInstrPhi dst _ ty) (compiler-reg-var-type-insert types dst ty)]
    [(IrInstrPack dst _ ty) (compiler-reg-var-type-insert types dst ty)]
    [(IrInstrWord dst _ _ ty) (compiler-reg-var-type-insert types dst ty)]
    [_ types]))

(define (compiler-reg-var-type-array-set!
  [present : (Array i64)]
  [types : (Array AstType)]
  [var : i64]
  [ty : AstType]) : unit
  (if (or (< var 0) (>= var (array.array-length present)))
    unit
    (begin
      (array.array-set! present var 1)
      (array.array-set! types var ty))))

(define (compiler-reg-param-types-array!
  [params : CompilerIrParamList]
  [present : (Array i64)]
  [types : (Array AstType)]) : unit
  (match params
    [(IrParamNil) unit]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ ty id)
          (begin
            (compiler-reg-var-type-array-set! present types id ty)
            (compiler-reg-param-types-array! (box-get rest) present types))])]))

(define (compiler-reg-instr-def-type-array!
  [instr : CompilerIrInstr]
  [present : (Array i64)]
  [types : (Array AstType)]) : unit
  (match instr
    [(IrInstrMov dst _ ty)
      (compiler-reg-var-type-array-set! present types dst ty)]
    [(IrInstrAddrOf dst _)
      (compiler-reg-var-type-array-set!
        present
        types
        dst
        (compiler-reg-addr-of-result-type))]
    [(IrInstrLoad dst _ ty)
      (compiler-reg-var-type-array-set! present types dst ty)]
    [(IrInstrCast dst _ _ to-ty)
      (compiler-reg-var-type-array-set! present types dst to-ty)]
    [(IrInstrBitcast dst _ _ to-ty)
      (compiler-reg-var-type-array-set! present types dst to-ty)]
    [(IrInstrBinOp dst _ _ _ ty)
      (compiler-reg-var-type-array-set! present types dst ty)]
    [(IrInstrUnOp dst _ _ ty)
      (compiler-reg-var-type-array-set! present types dst ty)]
    [(IrInstrVectorReduce dst _ _ _ elem-ty)
      (compiler-reg-var-type-array-set! present types dst elem-ty)]
    [(IrInstrMaskReduce dst _ _ _)
      (compiler-reg-var-type-array-set! present types dst (AstTyBool))]
    [(IrInstrCall dst _ _ ty)
      (compiler-reg-var-type-array-set! present types dst ty)]
    [(IrInstrPhi dst _ ty)
      (compiler-reg-var-type-array-set! present types dst ty)]
    [(IrInstrPack dst _ ty)
      (compiler-reg-var-type-array-set! present types dst ty)]
    [(IrInstrWord dst _ _ ty)
      (compiler-reg-var-type-array-set! present types dst ty)]
    [_ unit]))

(define (compiler-reg-instr-seq-types-array!
  [instrs : CompilerIrInstrSeq]
  [present : (Array i64)]
  [types : (Array AstType)]) : unit
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-reg-instr-def-type-array!
            (array.array-ref slots index)
            present
            types)
          (set! index (+ index 1))))
      unit)))

(define (compiler-reg-block-list-types-array!
  [blocks : CompilerIrBlockList]
  [present : (Array i64)]
  [types : (Array AstType)]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (begin
            (compiler-reg-instr-seq-types-array! instrs present types)
            (compiler-reg-block-list-types-array! (box-get rest) present types))])]
    [(IrBlockArray seq)
      (compiler-reg-block-list-types-array!
        (compiler-ir-block-seq-to-list seq)
        present
        types)]))

(define (compiler-reg-var-type-arrays-to-list
  [present : (Array i64)]
  [types : (Array AstType)]
  [index : i64]
  [acc : CompilerRegVarTypeList]) : CompilerRegVarTypeList
  (if (< index 0)
    acc
    (compiler-reg-var-type-arrays-to-list
      present
      types
      (- index 1)
      (if (= (array.array-ref present index) 0)
        acc
        (compiler-reg-var-type-cons
          (CompilerRegVarType index (array.array-ref types index))
          acc)))))

(define (compiler-reg-function-var-types [func : CompilerIrFunction]) : CompilerRegVarTypes
  (match func
    [(IrFunction _ params _ vars blocks)
      (let
        [present : (Array i64) (array.make-array i64 vars)]
        [types : (Array AstType) (array.make-array AstType vars)]
        (begin
          (compiler-reg-fill-i64-array present 0)
          (compiler-reg-param-types-array! params present types)
          (compiler-reg-block-list-types-array! blocks present types)
          (CompilerRegVarTypes
            (compiler-reg-var-type-arrays-to-list
              present
              types
              (- vars 1)
              CompilerRegVarTypeNil)
            present
            types)))]))

(define (compiler-reg-move-list-contains?
  [moves : CompilerRegMoveList]
  [src : i64]
  [dst : i64]) : bool
  (match moves
    [(CompilerRegMoveNil) false]
    [(CompilerRegMoveCons move rest)
      (match move
        [(CompilerRegMove found-src found-dst _)
          (if (and (= found-src src) (= found-dst dst))
            true
            (compiler-reg-move-list-contains? (box-get rest) src dst))])]))

(define (compiler-reg-move-list-contains-undirected?
  [moves : CompilerRegMoveList]
  [src : i64]
  [dst : i64]) : bool
  (match moves
    [(CompilerRegMoveNil) false]
    [(CompilerRegMoveCons move rest)
      (match move
        [(CompilerRegMove found-src found-dst _)
          (if (or
            (and (= found-src src) (= found-dst dst))
            (and (= found-src dst) (= found-dst src)))
            true
            (compiler-reg-move-list-contains-undirected? (box-get rest) src dst))])]))

(define (compiler-reg-move-list-empty? [moves : CompilerRegMoveList]) : bool
  (match moves
    [(CompilerRegMoveNil) true]
    [_ false]))

(define (compiler-reg-move-list-mark-strict
  [moves : CompilerRegMoveList]
  [src : i64]
  [dst : i64]) : CompilerRegMoveList
  (match moves
    [(CompilerRegMoveNil) CompilerRegMoveNil]
    [(CompilerRegMoveCons move rest)
      (match move
        [(CompilerRegMove found-src found-dst strict)
          (if (or
            (and (= found-src src) (= found-dst dst))
            (and (= found-src dst) (= found-dst src)))
            (compiler-reg-move-cons
              (CompilerRegMove found-src found-dst true)
              (box-get rest))
            (compiler-reg-move-cons
              (CompilerRegMove found-src found-dst strict)
              (compiler-reg-move-list-mark-strict (box-get rest) src dst)))])]))

(define (compiler-reg-move-list-add
  [moves : CompilerRegMoveList]
  [src : i64]
  [dst : i64]
  [strict : bool]
  [undirected : bool]) : CompilerRegMoveList
  (if (= src dst)
    moves
    (if (if undirected
      (compiler-reg-move-list-contains-undirected? moves src dst)
      (compiler-reg-move-list-contains? moves src dst))
      (if strict
        (compiler-reg-move-list-mark-strict moves src dst)
        moves)
      (compiler-reg-move-cons (CompilerRegMove src dst strict) moves))))

(define (compiler-reg-phi-input-moves
  [dst : i64]
  [inputs : CompilerIrPhiInputList]
  [moves : CompilerRegMoveList]
  [strict-pairs : bool]) : CompilerRegMoveList
  (match inputs
    [(IrPhiInputNil) moves]
    [(IrPhiInputCons value _ rest)
      (let
        [tail : CompilerRegMoveList
          (compiler-reg-phi-input-moves dst (box-get rest) moves strict-pairs)]
        (match value
          [(IrValueVar src)
            (compiler-reg-move-list-add tail src dst strict-pairs strict-pairs)]
          [_ tail]))]))

(define (compiler-reg-instr-moves
  [instr : CompilerIrInstr]
  [moves : CompilerRegMoveList]
  [strict-pairs : bool]) : CompilerRegMoveList
  (match instr
    [(IrInstrMov dst src _)
      (match src
        [(IrValueVar var)
          (compiler-reg-move-list-add moves var dst false strict-pairs)]
        [_ moves])]
    [(IrInstrPhi dst inputs _)
      (compiler-reg-phi-input-moves dst inputs moves strict-pairs)]
    [_ moves]))

(define (compiler-reg-instr-seq-moves
  [instrs : CompilerIrInstrSeq]
  [moves : CompilerRegMoveList]
  [strict-pairs : bool]) : CompilerRegMoveList
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [index : i64 (- (struct-get instrs len) 1)]
    [out : CompilerRegMoveList moves]
    (begin
      (while (>= index 0)
        (begin
          (set!
            out
            (compiler-reg-instr-moves
              (array.array-ref slots index)
              out
              strict-pairs))
          (set! index (- index 1))))
      out)))

(define (compiler-reg-block-list-moves
  [blocks : CompilerIrBlockList]
  [moves : CompilerRegMoveList]
  [strict-pairs : bool]) : CompilerRegMoveList
  (match blocks
    [(IrBlockNil) moves]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-reg-block-list-moves
            (box-get rest)
            (compiler-reg-instr-seq-moves instrs moves strict-pairs)
            strict-pairs)])]
    [(IrBlockArray seq)
      (compiler-reg-block-list-moves
        (compiler-ir-block-seq-to-list seq)
        moves
        strict-pairs)]))

(define (compiler-reg-function-moves
  [func : CompilerIrFunction]
  [strict-pairs : bool]) : CompilerRegMoveList
  (match func
    [(IrFunction _ _ _ _ blocks)
      (compiler-reg-block-list-moves blocks CompilerRegMoveNil strict-pairs)]))

(define (compiler-reg-fill-i64-array [items : (Array i64)] [value : i64]) : unit
  (let
    [index : i64 0]
    [count : i64 (array.array-length items)]
    (begin
      (while (< index count)
        (begin
          (array.array-set! items index value)
          (set! index (+ index 1))))
      unit)))

(define (compiler-reg-select-false-preference-instr!
  [instr : CompilerIrInstr]
  [preferences : (Array i64)]) : unit
  (match instr
    [(IrInstrSelect payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload dst _ _ false-value _ _)
          (match false-value
            [(IrValueVar false-var)
              (if (and (>= dst 0) (< dst (array.array-length preferences)))
                (array.array-set! preferences dst false-var)
                unit)]
            [_ unit])])]
    [_ unit]))

(define (compiler-reg-select-false-preference-seq!
  [instrs : CompilerIrInstrSeq]
  [preferences : (Array i64)]) : unit
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-reg-select-false-preference-instr!
            (array.array-ref slots index)
            preferences)
          (set! index (+ index 1))))
      unit)))

(define (compiler-reg-select-false-preference-blocks!
  [blocks : CompilerIrBlockList]
  [preferences : (Array i64)]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (begin
        (match block
          [(IrBlock _ instrs)
            (compiler-reg-select-false-preference-seq! instrs preferences)])
        (compiler-reg-select-false-preference-blocks!
          (box-get rest)
          preferences))]
    [(IrBlockArray seq)
      (compiler-reg-select-false-preference-blocks!
        (compiler-ir-block-seq-to-list seq)
        preferences)]))

(define (compiler-reg-function-select-false-preferences
  [func : CompilerIrFunction]
  [vars : i64]) : (Array i64)
  (let
    [preferences : (Array i64) (array.make-array i64 vars)]
    (begin
      (compiler-reg-fill-i64-array preferences -1)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (compiler-reg-select-false-preference-blocks! blocks preferences)])
      preferences)))

(define (compiler-reg-fill-location-array
  [items : (Array CompilerRegLocation)]
  [value : CompilerRegLocation]) : unit
  (let
    [index : i64 0]
    [count : i64 (array.array-length items)]
    (begin
      (while (< index count)
        (begin
          (array.array-set! items index value)
          (set! index (+ index 1))))
      unit)))

(define (compiler-reg-assignment-index-fill!
  [assignments : CompilerRegAssignmentList]
  [present : (Array i64)]
  [items : (Array CompilerRegLocation)]) : unit
  (match assignments
    [(CompilerRegAssignmentNil) unit]
    [(CompilerRegAssignmentCons item rest)
      (begin
        (match item
          [(CompilerRegAssignment var location)
            (if (or
              (< var 0)
              (>= var (array.array-length present))
              (not (= (array.array-ref present var) 0)))
              unit
              (begin
                (array.array-set! present var 1)
                (array.array-set! items var location)))])
        (compiler-reg-assignment-index-fill! (box-get rest) present items))]))

(define (compiler-reg-assignment-index-build
  [assignments : CompilerRegAssignmentList]
  [vars : i64]) : CompilerRegAssignmentIndex
  (let
    [present : (Array i64) (array.make-array i64 vars)]
    [items : (Array CompilerRegLocation)
      (array.make-array CompilerRegLocation vars)]
    (begin
      (compiler-reg-fill-i64-array present 0)
      (compiler-reg-fill-location-array items (CompilerRegSpill 0))
      (compiler-reg-assignment-index-fill! assignments present items)
      (CompilerRegAssignmentIndex present items))))

(define (compiler-reg-assignment-index-lookup
  [index : CompilerRegAssignmentIndex]
  [var : i64]) : CompilerRegMaybeLocation
  (let
    [present : (Array i64) (struct-get index present)]
    [items : (Array CompilerRegLocation) (struct-get index items)]
    (if (or (< var 0) (>= var (array.array-length present)))
      CompilerRegNoLocation
      (if (= (array.array-ref present var) 0)
        CompilerRegNoLocation
        (CompilerRegSomeLocation (array.array-ref items var))))))

(define (compiler-reg-assignment-table-make [vars : i64]) : CompilerRegAssignmentTable
  (let
    [n : i64
      (if (< vars 1)
        1
        vars)]
    [present : (Array i64) (array.make-array i64 n)]
    [items : (Array CompilerRegLocation)
      (array.make-array CompilerRegLocation n)]
    (begin
      (compiler-reg-fill-i64-array present 0)
      (compiler-reg-fill-location-array items (CompilerRegSpill 0))
      (CompilerRegAssignmentTable present items))))

(define (compiler-reg-assignment-table-insert
  [assignments : CompilerRegAssignmentTable]
  [var : i64]
  [location : CompilerRegLocation]) : CompilerRegAssignmentTable
  (let
    [present : (Array i64) (struct-get assignments present)]
    [items : (Array CompilerRegLocation) (struct-get assignments items)]
    (begin
      (if (or (< var 0) (>= var (array.array-length present)))
        unit
        (begin
          (array.array-set! present var 1)
          (array.array-set! items var location)))
      assignments)))

(define (compiler-reg-assignment-table-lookup
  [assignments : CompilerRegAssignmentTable]
  [var : i64]) : CompilerRegMaybeLocation
  (let
    [present : (Array i64) (struct-get assignments present)]
    [items : (Array CompilerRegLocation) (struct-get assignments items)]
    (if (or (< var 0) (>= var (array.array-length present)))
      CompilerRegNoLocation
      (if (= (array.array-ref present var) 0)
        CompilerRegNoLocation
        (CompilerRegSomeLocation (array.array-ref items var))))))

(define (compiler-reg-assignment-table-has-spill-from?
  [assignments : CompilerRegAssignmentTable]
  [index : i64]) : bool
  (let
    [present : (Array i64) (struct-get assignments present)]
    [items : (Array CompilerRegLocation) (struct-get assignments items)]
    (cond
      [(>= index (array.array-length present)) false]
      [(= (array.array-ref present index) 0)
        (compiler-reg-assignment-table-has-spill-from? assignments (+ index 1))]
      [else
        (match (array.array-ref items index)
          [(CompilerRegSpill _) true]
          [_
            (compiler-reg-assignment-table-has-spill-from?
              assignments
              (+ index 1))])])))

(define (compiler-reg-assignment-table-has-spill?
  [assignments : CompilerRegAssignmentTable]) : bool
  (compiler-reg-assignment-table-has-spill-from? assignments 0))

(define (compiler-reg-assignment-table-to-list-from
  [assignments : CompilerRegAssignmentTable]
  [index : i64]
  [out : CompilerRegAssignmentList]) : CompilerRegAssignmentList
  (if (< index 0)
    out
    (let
      [present : (Array i64) (struct-get assignments present)]
      [items : (Array CompilerRegLocation) (struct-get assignments items)]
      (compiler-reg-assignment-table-to-list-from
        assignments
        (- index 1)
        (if (= (array.array-ref present index) 0)
          out
          (compiler-reg-assignment-cons
            (CompilerRegAssignment index (array.array-ref items index))
            out))))))

(define (compiler-reg-assignment-table-to-list
  [assignments : CompilerRegAssignmentTable]) : CompilerRegAssignmentList
  (compiler-reg-assignment-table-to-list-from
    assignments
    (- (array.array-length (struct-get assignments present)) 1)
    CompilerRegAssignmentNil))

(define (compiler-reg-interval-index-fill!
  [intervals : CompilerRegIntervalList]
  [starts : (Array i64)]
  [ends : (Array i64)]) : unit
  (match intervals
    [(CompilerRegIntervalNil) unit]
    [(CompilerRegIntervalCons interval rest)
      (begin
        (match interval
          [(CompilerRegInterval var start end)
            (if (or
              (< var 0)
              (>= var (array.array-length starts))
              (>= (array.array-ref starts var) 0))
              unit
              (begin
                (array.array-set! starts var start)
                (array.array-set! ends var end)))])
        (compiler-reg-interval-index-fill! (box-get rest) starts ends))]))

(define (compiler-reg-interval-index-build
  [intervals : CompilerRegIntervalList]
  [vars : i64]) : CompilerRegIntervalIndex
  (let
    [starts : (Array i64) (array.make-array i64 vars)]
    [ends : (Array i64) (array.make-array i64 vars)]
    [segments : (Array CompilerRegIntervalList)
      (array.make-array CompilerRegIntervalList 0)]
    (begin
      (compiler-reg-fill-i64-array starts -1)
      (compiler-reg-fill-i64-array ends -1)
      (compiler-reg-interval-index-fill! intervals starts ends)
      (CompilerRegIntervalIndex starts ends segments))))

(define (compiler-reg-interval-index-lookup
  [index : CompilerRegIntervalIndex]
  [var : i64]) : CompilerRegMaybeInterval
  (let
    [starts : (Array i64) (struct-get index starts)]
    [ends : (Array i64) (struct-get index ends)]
    (if (or (< var 0) (>= var (array.array-length starts)))
      CompilerRegNoInterval
      (if (< (array.array-ref starts var) 0)
        CompilerRegNoInterval
        (CompilerRegSomeInterval
          (CompilerRegInterval
            var
            (array.array-ref starts var)
            (array.array-ref ends var)))))))

(define (compiler-reg-interval-list-empty? [segments : CompilerRegIntervalList]) : bool
  (match segments
    [(CompilerRegIntervalNil) true]
    [_ false]))

(define (compiler-reg-extend-interval
  [starts : (Array i64)]
  [ends : (Array i64)]
  [var : i64]
  [point : i64]) : unit
  (if (< var 0)
    unit
    (if (>= var (array.array-length starts))
      unit
      (let
        [start : i64 (array.array-ref starts var)]
        [end : i64 (array.array-ref ends var)]
        (begin
          (if (< start 0)
            (begin
              (array.array-set! starts var point)
              (array.array-set! ends var point))
            (begin
              (if (< point start)
                (array.array-set! starts var point)
                unit)
              (if (> point end)
                (array.array-set! ends var point)
                unit)))
          unit)))))

(define (compiler-reg-low-bit-index [bits : i64]) : i64
  (let
    [value : i64 bits]
    [offset : i64 0]
    (begin
      (if (= (bit-and value 0xffffffff) 0)
        (begin
          (set! value (shr value 32))
          (set! offset (+ offset 32)))
        unit)
      (if (= (bit-and value 0xffff) 0)
        (begin
          (set! value (shr value 16))
          (set! offset (+ offset 16)))
        unit)
      (if (= (bit-and value 0xff) 0)
        (begin
          (set! value (shr value 8))
          (set! offset (+ offset 8)))
        unit)
      (if (= (bit-and value 0xf) 0)
        (begin
          (set! value (shr value 4))
          (set! offset (+ offset 4)))
        unit)
      (if (= (bit-and value 0x3) 0)
        (begin
          (set! value (shr value 2))
          (set! offset (+ offset 2)))
        unit)
      (if (= (bit-and value 0x1) 0)
        (+ offset 1)
        offset))))

(define (compiler-reg-segment-flush-var!
  [segments : (Array CompilerRegIntervalList)]
  [starts : (Array i64)]
  [ends : (Array i64)]
  [var : i64]) : unit
  (if (or
    (< var 0)
    (>= var (array.array-length starts))
    (< (array.array-ref starts var) 0))
    unit
    (begin
      (array.array-set!
        segments
        var
        (compiler-reg-interval-cons
          (CompilerRegInterval
            var
            (array.array-ref starts var)
            (array.array-ref ends var))
          (array.array-ref segments var)))
      (array.array-set! starts var -1)
      (array.array-set! ends var -1)
      unit)))

(define (compiler-reg-segment-note-point!
  [segments : (Array CompilerRegIntervalList)]
  [starts : (Array i64)]
  [ends : (Array i64)]
  [var : i64]
  [point : i64]) : unit
  (if (or (< var 0) (>= var (array.array-length starts)))
    unit
    (if (< (array.array-ref starts var) 0)
      (begin
        (array.array-set! starts var point)
        (array.array-set! ends var point))
      (let
        [end : i64 (array.array-ref ends var)]
        (if (<= point (+ end 1))
          (if (> point end)
            (array.array-set! ends var point)
            unit)
          (begin
            (compiler-reg-segment-flush-var! segments starts ends var)
            (array.array-set! starts var point)
            (array.array-set! ends var point)))))))

(define (compiler-reg-extend-segment-set-word-bits!
  [starts : (Array i64)]
  [ends : (Array i64)]
  [segments : (Array CompilerRegIntervalList)]
  [segment-starts : (Array i64)]
  [segment-ends : (Array i64)]
  [bits : i64]
  [var : i64]
  [point : i64]) : unit
  (if (= bits 0)
    unit
    (let
      [index : i64 (compiler-reg-low-bit-index bits)]
      [item-var : i64 (+ var index)]
      (begin
        (compiler-reg-extend-interval starts ends item-var point)
        (compiler-reg-segment-note-point!
          segments
          segment-starts
          segment-ends
          item-var
          point)
        (compiler-reg-extend-segment-set-word-bits!
          starts
          ends
          segments
          segment-starts
          segment-ends
          (bit-and bits (- bits 1))
          var
          point)))))

(define (compiler-reg-extend-segment-set-words!
  [starts : (Array i64)]
  [ends : (Array i64)]
  [segments : (Array CompilerRegIntervalList)]
  [segment-starts : (Array i64)]
  [segment-ends : (Array i64)]
  [set : CompilerLiveI64Set]
  [word-index : i64]
  [point : i64]) : unit
  (let
    [index : i64 word-index]
    [word-count : i64 (compiler-live-set-word-count set)]
    (while (< index word-count)
      (begin
        (compiler-reg-extend-segment-set-word-bits!
          starts
          ends
          segments
          segment-starts
          segment-ends
          (compiler-live-set-word-at set index)
          (* index (compiler-live-set-word-bits))
          point)
        (set! index (+ index 1))))))

;; #3489 (PR1): note a live point into the per-var SEGMENTS only, WITHOUT
;; touching the coarse [start,end] interval. Bridges pass-through liveness so a
;; value live ACROSS an instruction is one continuous segment. Coarse already
;; spans this interior point (min..max), so leaving it untouched keeps the
;; linear-scan placement byte-identical -- only segment-precise interference
;; (consumed by coalescing) is corrected.
(define (compiler-reg-segment-note-set-word-bits!
  [segments : (Array CompilerRegIntervalList)]
  [segment-starts : (Array i64)]
  [segment-ends : (Array i64)]
  [bits : i64]
  [var : i64]
  [point : i64]) : unit
  (if (= bits 0)
    unit
    (let
      [index : i64 (compiler-reg-low-bit-index bits)]
      [item-var : i64 (+ var index)]
      (begin
        (compiler-reg-segment-note-point!
          segments
          segment-starts
          segment-ends
          item-var
          point)
        (compiler-reg-segment-note-set-word-bits!
          segments
          segment-starts
          segment-ends
          (bit-and bits (- bits 1))
          var
          point)))))

(define (compiler-reg-segment-note-set-words!
  [segments : (Array CompilerRegIntervalList)]
  [segment-starts : (Array i64)]
  [segment-ends : (Array i64)]
  [set : CompilerLiveI64Set]
  [word-index : i64]
  [point : i64]) : unit
  (let
    [index : i64 word-index]
    [word-count : i64 (compiler-live-set-word-count set)]
    (while (< index word-count)
      (begin
        (compiler-reg-segment-note-set-word-bits!
          segments
          segment-starts
          segment-ends
          (compiler-live-set-word-at set index)
          (* index (compiler-live-set-word-bits))
          point)
        (set! index (+ index 1))))))

(define (compiler-reg-extend-segment-instr!
  [starts : (Array i64)]
  [ends : (Array i64)]
  [segments : (Array CompilerRegIntervalList)]
  [segment-starts : (Array i64)]
  [segment-ends : (Array i64)]
  [live-after : CompilerLiveI64Set]
  [point : i64]
  [instr : CompilerIrInstr]) : unit
  (begin
    (compiler-reg-extend-segment-set-words!
      starts
      ends
      segments
      segment-starts
      segment-ends
      (compiler-live-instr-defs instr)
      0
      point)
    (compiler-reg-extend-segment-set-words!
      starts
      ends
      segments
      segment-starts
      segment-ends
      (compiler-live-instr-uses instr)
      0
      point)
    ;; #3489 (PR1): bridge live-after values into the SEGMENT at `point` (LLVM
    ;; SlotIndex semantics: a value live-OUT of this instruction is live AT it),
    ;; making a pass-through value one continuous segment instead of degenerate
    ;; single-point segments that wrongly fail the half-open overlap test. A value
    ;; whose LAST use is here is NOT in live-after, so it still ends at `point`,
    ;; preserving the def/use touch that lets a copy/two-address result coalesce.
    ;; Defs are already marked at `point` above, so this never extends a def back.
    (compiler-reg-segment-note-set-words!
      segments
      segment-starts
      segment-ends
      live-after
      0
      point)
    (compiler-reg-extend-segment-set-words!
      starts
      ends
      segments
      segment-starts
      segment-ends
      live-after
      0
      (+ point 1))))

(define (compiler-reg-extend-set-words
  [starts : (Array i64)]
  [ends : (Array i64)]
  [set : CompilerLiveI64Set]
  [word-index : i64]
  [point : i64]) : unit
  (let
    [index : i64 word-index]
    [word-count : i64 (compiler-live-set-word-count set)]
    (while (< index word-count)
      (begin
        (compiler-reg-extend-set-word-bits
          starts
          ends
          (compiler-live-set-word-at set index)
          (* index (compiler-live-set-word-bits))
          point)
        (set! index (+ index 1))))))

(define (compiler-reg-extend-set-word-bits
  [starts : (Array i64)]
  [ends : (Array i64)]
  [bits : i64]
  [var : i64]
  [point : i64]) : unit
  (if (= bits 0)
    unit
    (let
      [index : i64 (compiler-reg-low-bit-index bits)]
      (begin
        (compiler-reg-extend-interval starts ends (+ var index) point)
        (compiler-reg-extend-set-word-bits
          starts
          ends
          (bit-and bits (- bits 1))
          var
          point)))))

(define (compiler-reg-extend-instr
  [starts : (Array i64)]
  [ends : (Array i64)]
  [live-after : CompilerLiveI64Set]
  [point : i64]
  [instr : CompilerIrInstr]) : unit
  (begin
    (compiler-reg-extend-set-words
      starts
      ends
      (compiler-live-instr-defs instr)
      0
      point)
    (compiler-reg-extend-set-words
      starts
      ends
      (compiler-live-instr-uses instr)
      0
      point)
    (compiler-reg-extend-set-words starts ends live-after 0 (+ point 1))))

(define (compiler-reg-live-intervals-instr-seq
  [instrs : CompilerIrInstrSeq]
  [live-afters : CompilerLiveInstrSetVec]
  [point : i64]
  [starts : (Array i64)]
  [ends : (Array i64)]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [after-items : (Array CompilerLiveI64Set) (struct-get live-afters items)]
    [index : i64 0]
    [out-point : i64 point]
    (begin
      (while (< index count)
        (let
          [live-after : CompilerLiveI64Set
            (if (< index (array.array-length after-items))
              (array.array-ref after-items index)
              (compiler-live-set-empty))]
          (begin
            (compiler-reg-extend-instr
              starts
              ends
              live-after
              out-point
              (array.array-ref slots index))
            (set! out-point (+ out-point 2))
            (set! index (+ index 1)))))
      out-point)))

(define (compiler-reg-live-intervals-find-afters
  [liveness : CompilerFunctionLiveness]
  [label : String]) : CompilerLiveInstrSetVec
  (match (compiler-live-function-find-block liveness label)
    [(CompilerLiveSomeBlock live-block)
      (compiler-live-block-instr-after live-block)]
    [(CompilerLiveNoBlock) (compiler-live-instr-set-vec-empty)]))

(define (compiler-reg-live-intervals-blocks-with-live
  [blocks : CompilerIrBlockList]
  [liveness : CompilerFunctionLiveness]
  [point : i64]
  [starts : (Array i64)]
  [ends : (Array i64)]) : i64
  (match blocks
    [(IrBlockNil) point]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (let
            [live-afters : CompilerLiveInstrSetVec
              (compiler-reg-live-intervals-find-afters liveness label)]
            (compiler-reg-live-intervals-blocks-with-live
              (box-get rest)
              liveness
              (compiler-reg-live-intervals-instr-seq
                instrs
                live-afters
                point
                starts
                ends)
              starts
              ends))])]
    [(IrBlockArray seq)
      (compiler-reg-live-intervals-blocks-with-live
        (compiler-ir-block-seq-to-list seq)
        liveness
        point
        starts
        ends)]))

(define (compiler-reg-interval-arrays-to-list
  [starts : (Array i64)]
  [ends : (Array i64)]
  [index : i64]
  [acc : CompilerRegIntervalList]) : CompilerRegIntervalList
  (if (< index 0)
    acc
    (let
      [start : i64 (array.array-ref starts index)]
      [end : i64 (array.array-ref ends index)]
      (if (< start 0)
        (compiler-reg-interval-arrays-to-list starts ends (- index 1) acc)
        (compiler-reg-interval-arrays-to-list
          starts
          ends
          (- index 1)
          (compiler-reg-interval-cons (CompilerRegInterval index start end) acc))))))

(define (compiler-reg-live-intervals
  [func : CompilerIrFunction]
  [liveness : CompilerFunctionLiveness]) : CompilerRegIntervalList
  (match func
    [(IrFunction _ _ _ vars blocks)
      (let
        [starts : (Array i64) (array.make-array i64 vars)]
        [ends : (Array i64) (array.make-array i64 vars)]
        (begin
          (compiler-reg-fill-i64-array starts -1)
          (compiler-reg-fill-i64-array ends -1)
          (compiler-reg-live-intervals-blocks-with-live
            blocks
            liveness
            0
            starts
            ends)
          (compiler-reg-interval-arrays-to-list
            starts
            ends
            (- vars 1)
            CompilerRegIntervalNil)))]))

(define (compiler-reg-live-interval-selection-instr-seq
  [instrs : CompilerIrInstrSeq]
  [live-afters : CompilerLiveInstrSetVec]
  [point : i64]
  [starts : (Array i64)]
  [ends : (Array i64)]
  [segments : (Array CompilerRegIntervalList)]
  [segment-starts : (Array i64)]
  [segment-ends : (Array i64)]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [after-items : (Array CompilerLiveI64Set) (struct-get live-afters items)]
    [index : i64 0]
    [out-point : i64 point]
    (begin
      (while (< index count)
        (let
          [live-after : CompilerLiveI64Set
            (if (< index (array.array-length after-items))
              (array.array-ref after-items index)
              (compiler-live-set-empty))]
          [instr : CompilerIrInstr (array.array-ref slots index)]
          (begin
            (compiler-reg-extend-segment-instr!
              starts
              ends
              segments
              segment-starts
              segment-ends
              live-after
              out-point
              instr)
            (set! out-point (+ out-point 2))
            (set! index (+ index 1)))))
      out-point)))

(define (compiler-reg-live-interval-selection-blocks
  [blocks : CompilerIrBlockList]
  [liveness : CompilerFunctionLiveness]
  [point : i64]
  [starts : (Array i64)]
  [ends : (Array i64)]
  [segments : (Array CompilerRegIntervalList)]
  [segment-starts : (Array i64)]
  [segment-ends : (Array i64)]) : i64
  (match blocks
    [(IrBlockNil) point]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (let
            [live-afters : CompilerLiveInstrSetVec
              (compiler-reg-live-intervals-find-afters liveness label)]
            (compiler-reg-live-interval-selection-blocks
              (box-get rest)
              liveness
              (compiler-reg-live-interval-selection-instr-seq
                instrs
                live-afters
                point
                starts
                ends
                segments
                segment-starts
                segment-ends)
              starts
              ends
              segments
              segment-starts
              segment-ends))])]
    [(IrBlockArray seq)
      (compiler-reg-live-interval-selection-blocks
        (compiler-ir-block-seq-to-list seq)
        liveness
        point
        starts
        ends
        segments
        segment-starts
        segment-ends)]))

(define (compiler-reg-live-interval-selection
  [func : CompilerIrFunction]
  [liveness : CompilerFunctionLiveness]) : CompilerRegIntervalSelection
  (match func
    [(IrFunction _ _ _ vars blocks)
      (let
        [starts : (Array i64) (array.make-array i64 vars)]
        [ends : (Array i64) (array.make-array i64 vars)]
        [segments : (Array CompilerRegIntervalList)
          (array.make-array CompilerRegIntervalList vars)]
        [segment-starts : (Array i64) (array.make-array i64 vars)]
        [segment-ends : (Array i64) (array.make-array i64 vars)]
        (begin
          (compiler-reg-fill-i64-array starts -1)
          (compiler-reg-fill-i64-array ends -1)
          (compiler-reg-fill-i64-array segment-starts -1)
          (compiler-reg-fill-i64-array segment-ends -1)
          (compiler-reg-live-interval-selection-blocks
            blocks
            liveness
            0
            starts
            ends
            segments
            segment-starts
            segment-ends)
          (let
            [index : i64 0]
            (while (< index vars)
              (begin
                (compiler-reg-segment-flush-var!
                  segments
                  segment-starts
                  segment-ends
                  index)
                (set! index (+ index 1)))))
          (CompilerRegIntervalSelection
            (compiler-reg-interval-arrays-to-list
              starts
              ends
              (- vars 1)
              CompilerRegIntervalNil)
            (CompilerRegIntervalIndex starts ends segments))))]))

;; ---------------------------------------------------------------------------
;; Cheap block-level liveness for register planning (#perf).
;;
;; The register allocator only needs, per variable, a single [first-live,
;; last-live] interval, which can be built from block-level live-in/live-out plus
;; per-instruction mentions. This pass reuses the tested use/def/successor
;; extraction from compiler-live-build-blocks, then runs the backward dataflow
;; fixpoint over MUTABLE i64-word bitsets (in place, no per-operation allocation),
;; instead of the shared liveness pass's immutable linked-list bitset unions and
;; per-instruction live-after materialization. Block-level live-in/out keeps the
;; intervals sound across control flow that pure mention ranges miss (a
;; loop-carried value is live-out of the body and live-in of the header, so its
;; interval covers the whole loop). 63 data bits per word avoid the i64 sign bit.
;; ---------------------------------------------------------------------------
(define (compiler-reg-bits-words [vars : i64]) : i64
  (/ (+ vars 62) 63))

(define (compiler-reg-bits-set! [row : (Array i64)] [base : i64] [var : i64]) : unit
  (let
    [w : i64 (+ base (/ var 63))]
    (array.array-set! row w (bit-or (array.array-ref row w) (shl 1 (% var 63))))))

(define (compiler-reg-chunk->row!
  [row : (Array i64)]
  [base : i64]
  [bits : i64]
  [var-base : i64]) : unit
  (if (= bits 0)
    unit
    (let
      [i : i64 (compiler-reg-low-bit-index bits)]
      (begin
        (compiler-reg-bits-set! row base (+ var-base i))
        (compiler-reg-chunk->row! row base (bit-and bits (- bits 1)) var-base)))))

(define (compiler-reg-set-words->row!
  [set : CompilerLiveI64Set]
  [row : (Array i64)]
  [base : i64]
  [word-index : i64]) : unit
  (if (>= word-index (compiler-live-set-word-count set))
    unit
    (begin
      (compiler-reg-chunk->row!
        row
        base
        (compiler-live-set-word-at set word-index)
        (* word-index (compiler-live-set-word-bits)))
      (compiler-reg-set-words->row! set row base (+ word-index 1)))))

(define (compiler-reg-set->row!
  [set : CompilerLiveI64Set]
  [row : (Array i64)]
  [base : i64]) : unit
  (compiler-reg-set-words->row! set row base 0))

(define (compiler-reg-live-block-succs [block : CompilerLiveBlock]) : CompilerLiveLabelSet
  (match block
    [(CompilerLiveBlock _ _ _ _ _ succs _) succs]))

(define (compiler-reg-live-block-list-count [blocks : CompilerLiveBlockList]) : i64
  (match blocks
    [(CompilerLiveBlockNil) 0]
    [(CompilerLiveBlockCons _ rest)
      (+ 1 (compiler-reg-live-block-list-count (box-get rest)))]))

(define (compiler-reg-bits-build-rows!
  [blocks : CompilerLiveBlockList]
  [arr : (Array CompilerLiveBlock)]
  [idmap : hashmap.StringI64Map]
  [use-rows : (Array i64)]
  [def-rows : (Array i64)]
  [words : i64]
  [index : i64]) : hashmap.StringI64Map
  (match blocks
    [(CompilerLiveBlockNil) idmap]
    [(CompilerLiveBlockCons block rest)
      (match block
        [(CompilerLiveBlock label uses defs _ _ _ _)
          (begin
            (array.array-set! arr index block)
            (compiler-reg-set->row! uses use-rows (* index words))
            (compiler-reg-set->row! defs def-rows (* index words))
            (compiler-reg-bits-build-rows!
              (box-get rest)
              arr
              (hashmap.string-i64-map-put idmap label index)
              use-rows
              def-rows
              words
              (+ index 1)))])]))

(define (compiler-reg-bits-clear-row!
  [row : (Array i64)]
  [base : i64]
  [words : i64]) : unit
  (let
    [w : i64 0]
    (begin
      (while (< w words)
        (begin
          (array.array-set! row (+ base w) 0)
          (set! w (+ w 1))))
      unit)))

(define (compiler-reg-bits-or-row!
  [dst : (Array i64)]
  [dbase : i64]
  [src : (Array i64)]
  [sbase : i64]
  [words : i64]) : unit
  (let
    [w : i64 0]
    (begin
      (while (< w words)
        (begin
          (array.array-set!
            dst
            (+ dbase w)
            (bit-or
              (array.array-ref dst (+ dbase w))
              (array.array-ref src (+ sbase w))))
          (set! w (+ w 1))))
      unit)))

(define (compiler-reg-bits-or-succs!
  [live-out : (Array i64)]
  [live-in : (Array i64)]
  [succs : CompilerLiveLabelSet]
  [idmap : hashmap.StringI64Map]
  [b : i64]
  [words : i64]) : unit
  (match succs
    [(CompilerLiveLabelNil) unit]
    [(CompilerLiveLabelCons label rest)
      (begin
        (match (hashmap.string-i64-map-get idmap label)
          [(hashmap.StringI64MapFound idx)
            (compiler-reg-bits-or-row!
              live-out
              (* b words)
              live-in
              (* idx words)
              words)]
          [(hashmap.StringI64MapMissing) unit])
        (compiler-reg-bits-or-succs!
          live-out
          live-in
          (box-get rest)
          idmap
          b
          words))]))

(define (compiler-reg-bits-update-live-in!
  [live-in : (Array i64)]
  [use-rows : (Array i64)]
  [live-out : (Array i64)]
  [def-rows : (Array i64)]
  [base : i64]
  [words : i64]) : bool
  (let
    [w : i64 0]
    [changed : bool false]
    (begin
      (while (< w words)
        (let
          [idx : i64 (+ base w)]
          [next : i64
            (bit-or
              (array.array-ref use-rows idx)
              (bit-and
                (array.array-ref live-out idx)
                (bit-xor (array.array-ref def-rows idx) -1)))]
          (begin
            (if (= next (array.array-ref live-in idx))
              unit
              (begin
                (array.array-set! live-in idx next)
                (set! changed true)))
            (set! w (+ w 1)))))
      changed)))

(define (compiler-reg-bits-iterate!
  [arr : (Array CompilerLiveBlock)]
  [idmap : hashmap.StringI64Map]
  [words : i64]
  [use-rows : (Array i64)]
  [live-in : (Array i64)]
  [live-out : (Array i64)]
  [def-rows : (Array i64)]
  [b : i64]
  [changed : bool]) : bool
  (if (< b 0)
    changed
    (begin
      (compiler-reg-bits-clear-row! live-out (* b words) words)
      (compiler-reg-bits-or-succs!
        live-out
        live-in
        (compiler-reg-live-block-succs (array.array-ref arr b))
        idmap
        b
        words)
      (let
        [next-changed : bool
          (if (compiler-reg-bits-update-live-in!
            live-in
            use-rows
            live-out
            def-rows
            (* b words)
            words)
            true
            changed)]
        (compiler-reg-bits-iterate!
          arr
          idmap
          words
          use-rows
          live-in
          live-out
          def-rows
          (- b 1)
          next-changed)))))

(define (compiler-reg-bits-fixpoint!
  [arr : (Array CompilerLiveBlock)]
  [idmap : hashmap.StringI64Map]
  [count : i64]
  [words : i64]
  [use-rows : (Array i64)]
  [live-in : (Array i64)]
  [live-out : (Array i64)]
  [def-rows : (Array i64)]) : unit
  (if (compiler-reg-bits-iterate!
    arr
    idmap
    words
    use-rows
    live-in
    live-out
    def-rows
    (- count 1)
    false)
    (compiler-reg-bits-fixpoint!
      arr
      idmap
      count
      words
      use-rows
      live-in
      live-out
      def-rows)
    unit))

(define (compiler-reg-bits-extend-word!
  [bits : i64]
  [var-base : i64]
  [starts : (Array i64)]
  [ends : (Array i64)]
  [point : i64]) : unit
  (if (= bits 0)
    unit
    (let
      [i : i64 (compiler-reg-low-bit-index bits)]
      (begin
        (compiler-reg-extend-interval starts ends (+ var-base i) point)
        (compiler-reg-bits-extend-word!
          (bit-and bits (- bits 1))
          var-base
          starts
          ends
          point)))))

(define (compiler-reg-bits-extend-row!
  [row : (Array i64)]
  [base : i64]
  [words : i64]
  [starts : (Array i64)]
  [ends : (Array i64)]
  [point : i64]) : unit
  (let
    [w : i64 0]
    (begin
      (while (< w words)
        (begin
          (compiler-reg-bits-extend-word!
            (array.array-ref row (+ base w))
            (* w 63)
            starts
            ends
            point)
          (set! w (+ w 1))))
      unit)))

(define (compiler-reg-bits-mentions-instr-seq
  [instrs : CompilerIrInstrSeq]
  [point : i64]
  [starts : (Array i64)]
  [ends : (Array i64)]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [out-point : i64 point]
    (begin
      (while (< index count)
        (begin
          (compiler-reg-extend-instr
            starts
            ends
            (compiler-live-set-empty)
            out-point
            (array.array-ref slots index))
          (set! out-point (+ out-point 2))
          (set! index (+ index 1))))
      out-point)))

(define (compiler-reg-bits-intervals-walk
  [ir-blocks : CompilerIrBlockList]
  [live-in : (Array i64)]
  [live-out : (Array i64)]
  [words : i64]
  [b : i64]
  [point : i64]
  [starts : (Array i64)]
  [ends : (Array i64)]) : i64
  (match ir-blocks
    [(IrBlockNil) point]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (begin
            (compiler-reg-bits-extend-row!
              live-in
              (* b words)
              words
              starts
              ends
              point)
            (let
              [end-point : i64
                (compiler-reg-bits-mentions-instr-seq instrs point starts ends)]
              (begin
                (compiler-reg-bits-extend-row!
                  live-out
                  (* b words)
                  words
                  starts
                  ends
                  end-point)
                (compiler-reg-bits-intervals-walk
                  (box-get rest)
                  live-in
                  live-out
                  words
                  (+ b 1)
                  end-point
                  starts
                  ends))))])]
    [(IrBlockArray seq)
      (compiler-reg-bits-intervals-walk
        (compiler-ir-block-seq-to-list seq)
        live-in
        live-out
        words
        b
        point
        starts
        ends)]))

(define (compiler-reg-bits-map-capacity [count : i64]) : i64
  (if (< count 4)
    8
    (* count 2)))

(define (compiler-reg-block-intervals [func : CompilerIrFunction]) : CompilerRegIntervalList
  (match func
    [(IrFunction _ _ _ vars blocks)
      (let
        [live-blocks : CompilerLiveBlockList
          (compiler-live-build-blocks blocks)]
        [count : i64 (compiler-reg-live-block-list-count live-blocks)]
        [words : i64 (compiler-reg-bits-words vars)]
        [cells : i64 (* count words)]
        [arr : (Array CompilerLiveBlock)
          (array.make-array CompilerLiveBlock count)]
        [use-rows : (Array i64) (array.make-array i64 cells)]
        [def-rows : (Array i64) (array.make-array i64 cells)]
        [live-in : (Array i64) (array.make-array i64 cells)]
        [live-out : (Array i64) (array.make-array i64 cells)]
        [starts : (Array i64) (array.make-array i64 vars)]
        [ends : (Array i64) (array.make-array i64 vars)]
        (begin
          (compiler-reg-fill-i64-array use-rows 0)
          (compiler-reg-fill-i64-array def-rows 0)
          (compiler-reg-fill-i64-array live-in 0)
          (compiler-reg-fill-i64-array live-out 0)
          (compiler-reg-fill-i64-array starts -1)
          (compiler-reg-fill-i64-array ends -1)
          (let
            [idmap : hashmap.StringI64Map
              (compiler-reg-bits-build-rows!
                live-blocks
                arr
                (hashmap.string-i64-map-with-capacity
                  (compiler-reg-bits-map-capacity count))
                use-rows
                def-rows
                words
                0)]
            (begin
              (compiler-reg-bits-fixpoint!
                arr
                idmap
                count
                words
                use-rows
                live-in
                live-out
                def-rows)
              (compiler-reg-bits-intervals-walk
                blocks
                live-in
                live-out
                words
                0
                0
                starts
                ends)
              (compiler-reg-interval-arrays-to-list
                starts
                ends
                (- vars 1)
                CompilerRegIntervalNil)))))]))

;; When handles-ok? is true (scalar path) 8-byte aggregate handles are register
;; eligible; when false (SIMD/AVX path, unchanged) only CPU scalars/pointers are.
(define (compiler-reg-ineligible-non-scalars
  [types : CompilerRegVarTypeList]
  [set : CompilerLiveI64Set]
  [handles-ok? : bool]) : CompilerLiveI64Set
  (match types
    [(CompilerRegVarTypeNil) set]
    [(CompilerRegVarTypeCons item rest)
      (match item
        [(CompilerRegVarType var ty)
          (compiler-reg-ineligible-non-scalars
            (box-get rest)
            (if (if handles-ok?
              (compiler-reg-register-eligible-type? ty)
              (compiler-reg-scalar-type? ty))
              set
              (compiler-live-set-insert set var))
            handles-ok?)])]))

(define (compiler-reg-ineligible-params
  [params : CompilerIrParamList]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match params
    [(IrParamNil) set]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ _ var)
          (compiler-reg-ineligible-params
            (box-get rest)
            (compiler-live-set-insert set var))])]))

(define (compiler-reg-integer-param-type? [ty : AstType]) : bool
  (and
    ;; Local handle values are register-eligible after lowering, but aggregate
    ;; ABI params can be incoming by-reference values used by backend copy/allocation
    ;; sequences. Only true scalar integer/pointer params can keep their incoming
    ;; ABI home.
    (compiler-reg-scalar-type? ty)
    (not (compiler-reg-float-type? ty))
    (not (compiler-reg-type-register-group? ty))))

(define (compiler-reg-param-int-reg
  [abi : CompilerRegTargetAbi]
  [int-idx : i64]
  [position : i64]) : CompilerRegMaybeString
  (let
    [idx : i64
      (match abi
        [(CompilerRegAbiLinux) int-idx]
        [(CompilerRegAbiWindows) position])]
    (match abi
      [(CompilerRegAbiLinux)
        (cond
          [(= idx 0) (CompilerRegSomeString "%rdi")]
          [(= idx 1) (CompilerRegSomeString "%rsi")]
          [(= idx 2) (CompilerRegSomeString "%rdx")]
          [(= idx 3) (CompilerRegSomeString "%rcx")]
          ;; Skip Linux arg4 (%r8) in this legacy zero-call pin set; the unified
          ;; greedy pool owns %r8 behind the clobber filter.
          [(= idx 5) (CompilerRegSomeString "%r9")]
          [else CompilerRegNoString])]
      [(CompilerRegAbiWindows)
        (cond
          [(= idx 0) (CompilerRegSomeString "%rcx")]
          [(= idx 1) (CompilerRegSomeString "%rdx")]
          ;; Skip Win64 arg2 (%r8) in this legacy zero-call pin set; the unified
          ;; greedy pool owns %r8 behind the clobber filter.
          [(= idx 3) (CompilerRegSomeString "%r9")]
          [else CompilerRegNoString])])))

(define (compiler-reg-param-pin-safe?
  [assignments : CompilerRegAssignmentTable]
  [interval-index : CompilerRegIntervalIndex]
  [base-ineligible : CompilerLiveI64Set]
  [var : i64]
  [reg : String]) : bool
  (and
    (not (compiler-live-set-contains? base-ineligible var))
    (match (compiler-reg-interval-index-lookup interval-index var)
      [(CompilerRegSomeInterval interval)
        (match interval
          [(CompilerRegInterval _ start end)
            (not
              (compiler-reg-assignment-table-location-conflicts?
                assignments
                interval-index
                var
                (- 0 1)
                (CompilerRegRegister reg)))])]
      [(CompilerRegNoInterval) false])))

(define (compiler-reg-param-assign-walk
  [abi : CompilerRegTargetAbi]
  [params : CompilerIrParamList]
  [interval-index : CompilerRegIntervalIndex]
  [assignments : CompilerRegAssignmentTable]
  [ineligible : CompilerLiveI64Set]
  [blocked : CompilerLiveI64Set]
  [int-idx : i64]
  [position : i64]
  [can-pin? : bool]) : CompilerRegParamAssignPlan
  (match params
    [(IrParamNil) (CompilerRegParamAssignPlan assignments ineligible blocked)]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ ty var-id)
          (let
            [is-float : bool (compiler-reg-float-type? ty)]
            [is-group : bool (compiler-reg-type-register-group? ty)]
            [next-int : i64
              (if is-float
                int-idx
                (+ int-idx 1))]
            [next-position : i64 (+ position 1)]
            [tail-can-pin? : bool (and can-pin? (not is-group))]
            [reg : CompilerRegMaybeString
              (if (and
                can-pin?
                (not is-group)
                (compiler-reg-integer-param-type? ty))
                (compiler-reg-param-int-reg abi int-idx position)
                CompilerRegNoString)]
            (match reg
              [(CompilerRegSomeString home)
                (if (compiler-reg-param-pin-safe?
                  assignments
                  interval-index
                  ineligible
                  var-id
                  home)
                  (compiler-reg-param-assign-walk
                    abi
                    (box-get rest)
                    interval-index
                    (compiler-reg-assignment-table-insert
                      assignments
                      var-id
                      (CompilerRegRegister home))
                    ineligible
                    (compiler-live-set-insert blocked var-id)
                    next-int
                    next-position
                    tail-can-pin?)
                  (compiler-reg-param-assign-walk
                    abi
                    (box-get rest)
                    interval-index
                    assignments
                    (compiler-live-set-insert ineligible var-id)
                    (compiler-live-set-insert blocked var-id)
                    next-int
                    next-position
                    tail-can-pin?))]
              [(CompilerRegNoString)
                (compiler-reg-param-assign-walk
                  abi
                  (box-get rest)
                  interval-index
                  assignments
                  (compiler-live-set-insert ineligible var-id)
                  (compiler-live-set-insert blocked var-id)
                  next-int
                  next-position
                  tail-can-pin?)]))])]))

(define (compiler-reg-param-assign-plan
  [abi : CompilerRegTargetAbi]
  [func : CompilerIrFunction]
  [interval-index : CompilerRegIntervalIndex]
  [base-ineligible : CompilerLiveI64Set]
  [vars : i64]) : CompilerRegParamAssignPlan
  (match func
    [(IrFunction _ params _ _ _)
      (match params
        [(IrParamNil)
          (CompilerRegParamAssignPlan
            (compiler-reg-assignment-table-make vars)
            base-ineligible
            base-ineligible)]
        [(IrParamCons _ _)
          (let
            [assignments : CompilerRegAssignmentTable
              (compiler-reg-assignment-table-make vars)]
            (if (compiler-reg-backend-caller-clobber? func)
              (let
                [fallback-ineligible : CompilerLiveI64Set
                  (compiler-reg-ineligible-params params base-ineligible)]
                (CompilerRegParamAssignPlan
                  assignments
                  fallback-ineligible
                  fallback-ineligible))
              (compiler-reg-param-assign-walk
                abi
                params
                interval-index
                assignments
                base-ineligible
                base-ineligible
                0
                0
                true)))])]))

(define (compiler-reg-ineligible-instr
  [instr : CompilerIrInstr]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match instr
    [(IrInstrAlloc dst _) (compiler-live-set-insert set dst)]
    [(IrInstrAddrOf _ src) (compiler-live-set-insert set src)]
    [(IrInstrGep dst _ _ _) (compiler-live-set-insert set dst)]
    [_ set]))

(define (compiler-reg-ineligible-instr-seq
  [instrs : CompilerIrInstrSeq]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [out : CompilerLiveI64Set set]
    (begin
      (while (< index count)
        (begin
          (set!
            out
            (compiler-reg-ineligible-instr (array.array-ref slots index) out))
          (set! index (+ index 1))))
      out)))

(define (compiler-reg-ineligible-memory
  [blocks : CompilerIrBlockList]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match blocks
    [(IrBlockNil) set]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-reg-ineligible-memory
            (box-get rest)
            (compiler-reg-ineligible-instr-seq instrs set))])]
    [(IrBlockArray seq)
      (compiler-reg-ineligible-memory (compiler-ir-block-seq-to-list seq) set)]))

(define (compiler-reg-call-live-instr-seq
  [instrs : CompilerIrInstrSeq]
  [liveness : CompilerFunctionLiveness]
  [label : String]
  [start-index : i64]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [instr-index : i64 start-index]
    [out : CompilerLiveI64Set set]
    (begin
      (while (< index count)
        (begin
          (set!
            out
            (match (array.array-ref slots index)
              [(IrInstrCall _ _ _ _)
                (compiler-live-set-union
                  out
                  (compiler-live-after liveness label instr-index))]
              [(IrInstrCallCAbiStoreResult payload-box)
                (match (box-get payload-box)
                  [(CompilerIrInstrCallCAbiStoreResultPayload _ _ _ _)
                    (compiler-live-set-union
                      out
                      (compiler-live-after liveness label instr-index))])]
              [(IrInstrCallIndirectCAbiStoreResult payload-box)
                (match (box-get payload-box)
                  [(CompilerIrInstrCallIndirectCAbiStoreResultPayload _ _ _ _)
                    (compiler-live-set-union
                      out
                      (compiler-live-after liveness label instr-index))])]
              [(IrInstrTailCall _ _ _)
                (compiler-live-set-union
                  out
                  (compiler-live-after liveness label instr-index))]
              [(IrInstrTailCallIndirect _ _ _)
                (compiler-live-set-union
                  out
                  (compiler-live-after liveness label instr-index))]
              [_ out]))
          (set! instr-index (+ instr-index 1))
          (set! index (+ index 1))))
      out)))

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
            (box-get rest)
            liveness
            (compiler-reg-call-live-instr-seq instrs liveness label 0 set))])]
    [(IrBlockArray seq)
      (compiler-reg-call-live-blocks
        (compiler-ir-block-seq-to-list seq)
        liveness
        set)]))

(define (compiler-reg-call-arg-vars-instr-seq
  [instrs : CompilerIrInstrSeq]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [out : CompilerLiveI64Set set]
    (begin
      (while (< index count)
        (begin
          (set!
            out
            (match (array.array-ref slots index)
              [(IrInstrCall _ _ args _)
                (compiler-live-set-union
                  out
                  (compiler-live-call-args-vars args))]
              [(IrInstrCallCAbiStoreResult payload-box)
                (match (box-get payload-box)
                  [(CompilerIrInstrCallCAbiStoreResultPayload base _ args _)
                    (compiler-live-set-union
                      out
                      (compiler-live-value-vars-into
                        (compiler-live-call-args-vars args)
                        base))])]
              [(IrInstrCallIndirectCAbiStoreResult payload-box)
                (match (box-get payload-box)
                  [(CompilerIrInstrCallIndirectCAbiStoreResultPayload
                      base
                      func
                      args
                      _)
                    (compiler-live-set-union
                      out
                      (compiler-live-value-vars-into
                        (compiler-live-value-vars-into
                          (compiler-live-call-args-vars args)
                          base)
                        func))])]
              [(IrInstrTailCall _ args _)
                (compiler-live-set-union
                  out
                  (compiler-live-call-args-vars args))]
              [(IrInstrTailCallIndirect func args _)
                (compiler-live-set-union
                  out
                  (compiler-live-value-vars-into
                    (compiler-live-call-args-vars args)
                    func))]
              [_ out]))
          (set! index (+ index 1))))
      out)))

(define (compiler-reg-call-arg-vars-blocks
  [blocks : CompilerIrBlockList]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match blocks
    [(IrBlockNil) set]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-reg-call-arg-vars-blocks
            (box-get rest)
            (compiler-reg-call-arg-vars-instr-seq instrs set))])]
    [(IrBlockArray seq)
      (compiler-reg-call-arg-vars-blocks
        (compiler-ir-block-seq-to-list seq)
        set)]))

;; --- Register-eligible direct-call args (option b) -------------------------
;; A direct IrInstrCall is "simple" for register-eligible args when it has at
;; most 4 integer-class scalar args. 4 is the Win64 GP arg-register count (the
;; safe minimum across both ABIs), so every arg of a simple call is GP-register
;; passed on BOTH SysV (%rdi..%rcx) and Win64 (%rcx..%r9); none land on the
;; stack and there are no float/group/aggregate args (which shift positions or
;; need two-register marshalling). Only such calls' arg vars are left eligible;
;; the backend resolves any register source/dest conflict among them with a
;; sound parallel move (compiler-backend-emit-arg-move-list). Every other call
;; shape keeps its arg vars ineligible (memory-sourced), so the backend's naive
;; ascending marshalling stays correct for them. The SIMD path keeps the old
;; block-everything behavior via compiler-reg-call-arg-vars-blocks (unchanged).
(define (compiler-reg-call-arg-int-class?
  [value : CompilerIrValue]
  [types : CompilerRegVarTypeList]) : bool
  (match value
    [(IrValueVar id)
      (match (compiler-reg-var-type-lookup types id)
        [(CompilerRegSomeType ty) (compiler-reg-integer-param-type? ty)]
        [(CompilerRegNoType) false])]
    [(IrValueF64 _) false]
    [(IrValueUnit) false]
    [_ true]))

(define (compiler-reg-call-args-array-int-class?
  [values : (Array CompilerIrValue)]
  [types : CompilerRegVarTypeList]
  [index : i64]
  [count : i64]) : bool
  (if (>= index count)
    true
    (and
      (compiler-reg-call-arg-int-class? (array.array-ref values index) types)
      (compiler-reg-call-args-array-int-class? values types (+ index 1) count))))

;; Per-ABI GP integer arg-register count: SysV has 6 (%rdi/%rsi/%rdx/%rcx/%r8/%r9),
;; Win64 has 4 (%rcx/%rdx/%r8/%r9). Direct-call args within this arity (and all
;; integer-class) are register-passed and left eligible; the backend parallel
;; move resolves any source/dest conflict (and uses the matching target-aware
;; threshold, so a 5..6-arg SysV conflict is never naive-marshalled). Mirrored in the
;; backend at compiler-backend-call-args-gp-parallel? -- keep the two in sync.
(define (compiler-reg-arg-reg-limit-for-abi [abi : CompilerRegTargetAbi]) : i64
  (match abi
    [(CompilerRegAbiLinux) 6]
    [(CompilerRegAbiWindows) 4]))

(define (compiler-reg-call-simple?
  [args : CompilerIrCallArgs]
  [types : CompilerRegVarTypeList]
  [limit : i64]) : bool
  (match args
    [(IrCallArgsNil) true]
    [(IrCallArgsOne v) (compiler-reg-call-arg-int-class? v types)]
    [(IrCallArgsTwo a b)
      (and
        (compiler-reg-call-arg-int-class? a types)
        (compiler-reg-call-arg-int-class? b types))]
    [(IrCallArgsArray values)
      (if (> (array.array-length values) limit)
        false
        (compiler-reg-call-args-array-int-class?
          values
          types
          0
          (array.array-length values)))]))

(define (compiler-reg-call-arg-vars-instr-seq-scalar
  [instrs : CompilerIrInstrSeq]
  [set : CompilerLiveI64Set]
  [types : CompilerRegVarTypeList]
  [limit : i64]) : CompilerLiveI64Set
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [out : CompilerLiveI64Set set]
    (begin
      (while (< index count)
        (begin
          (set!
            out
            (match (array.array-ref slots index)
              [(IrInstrCall _ _ args _)
                (if (compiler-reg-call-simple? args types limit)
                  out
                  (compiler-live-set-union
                    out
                    (compiler-live-call-args-vars args)))]
              [(IrInstrCallCAbiStoreResult payload-box)
                (match (box-get payload-box)
                  [(CompilerIrInstrCallCAbiStoreResultPayload base _ args _)
                    (compiler-live-set-union
                      out
                      (compiler-live-value-vars-into
                        (compiler-live-call-args-vars args)
                        base))])]
              [(IrInstrCallIndirectCAbiStoreResult payload-box)
                (match (box-get payload-box)
                  [(CompilerIrInstrCallIndirectCAbiStoreResultPayload
                      base
                      func
                      args
                      _)
                    (compiler-live-set-union
                      out
                      (compiler-live-value-vars-into
                        (compiler-live-value-vars-into
                          (compiler-live-call-args-vars args)
                          base)
                        func))])]
              [(IrInstrTailCall _ args _)
                (compiler-live-set-union
                  out
                  (compiler-live-call-args-vars args))]
              [(IrInstrTailCallIndirect func args _)
                (compiler-live-set-union
                  out
                  (compiler-live-value-vars-into
                    (compiler-live-call-args-vars args)
                    func))]
              ;; Closure/indirect calls reserve ABI arg-register 0 for the env and
              ;; marshal user args at base 1; the parallel-move solver builds at base
              ;; 0, so keep their arg vars memory-sourced (ineligible) -> the naive
              ;; (base-correct) marshalling handles them and no register cycle forms.
              ;; (Follow-up: a base-aware + cap-aware parallel move could re-enable
              ;; register-homed indirect-call args.)
              [(IrInstrCallIndirect _ func args _)
                (compiler-live-set-union
                  out
                  (compiler-live-value-vars-into
                    (compiler-live-call-args-vars args)
                    func))]
              [(IrInstrCallIndirectC _ func args _)
                (compiler-live-set-union
                  out
                  (compiler-live-value-vars-into
                    (compiler-live-call-args-vars args)
                    func))]
              [_ out]))
          (set! index (+ index 1))))
      out)))

(define (compiler-reg-call-arg-vars-blocks-scalar
  [blocks : CompilerIrBlockList]
  [set : CompilerLiveI64Set]
  [types : CompilerRegVarTypeList]
  [limit : i64]) : CompilerLiveI64Set
  (match blocks
    [(IrBlockNil) set]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-reg-call-arg-vars-blocks-scalar
            (box-get rest)
            (compiler-reg-call-arg-vars-instr-seq-scalar instrs set types limit)
            types
            limit)])]
    [(IrBlockArray seq)
      (compiler-reg-call-arg-vars-blocks-scalar
        (compiler-ir-block-seq-to-list seq)
        set
        types
        limit)]))

;; Ineligible variables are computed structurally (non-scalar/non-handle types,
;; call-argument vars, address-taken/memory targets). A value live across a call
;; is NOT structurally ineligible: the primary integer pool admits only
;; callee-saved registers (%r12-%r15/%rbx) which the callee (TypeLisp function
;; prologue/epilogue, or a runtime helper that push/pops them) preserves across
;; the call. The scalar zero-call extension is layered on later and separately
;; rejects any interval spanning a modeled caller-clobber point.
(define (compiler-reg-ineligible-vars-non-params
  [func : CompilerIrFunction]
  [types : CompilerRegVarTypeList]
  [limit : i64]) : CompilerLiveI64Set
  (match func
    [(IrFunction _ _ _ _ blocks)
      (compiler-reg-ineligible-memory
        blocks
        (compiler-reg-call-arg-vars-blocks-scalar
          blocks
          (compiler-reg-ineligible-non-scalars
            types
            (compiler-live-set-empty)
            true)
          types
          limit))]))

;; SIMD/AVX register planning keeps the original (pre-#perf) ineligibility: every
;; value live across a call is ineligible (the vector/mask/XMM pools are
;; caller-saved and the backend has no callee-saved save/restore for them), and
;; only CPU scalars/pointers — not aggregate handles — are register eligible.
;; This keeps the AVX backend golden output byte-identical.
(define (compiler-reg-ineligible-vars-simd
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
              (compiler-reg-ineligible-non-scalars
                types
                (compiler-live-set-empty)
                false)))))]))

(define (compiler-reg-interval-before?
  [left : CompilerRegInterval]
  [right : CompilerRegInterval]) : bool
  (match left
    [(CompilerRegInterval left-var left-start left-end)
      (match right
        [(CompilerRegInterval right-var right-start right-end)
          (cond
            [(< left-start right-start) true]
            [(> left-start right-start) false]
            [(< left-end right-end) true]
            [(> left-end right-end) false]
            [else (< left-var right-var)])])]))

(define (compiler-reg-candidate-insert
  [candidates : CompilerRegIntervalList]
  [interval : CompilerRegInterval]) : CompilerRegIntervalList
  (match candidates
    [(CompilerRegIntervalNil)
      (compiler-reg-interval-cons interval CompilerRegIntervalNil)]
    [(CompilerRegIntervalCons head rest)
      (if (compiler-reg-interval-before? interval head)
        (compiler-reg-interval-cons interval candidates)
        (compiler-reg-interval-cons
          head
          (compiler-reg-candidate-insert (box-get rest) interval)))]))

(define (compiler-reg-candidates
  [intervals : CompilerRegIntervalList]
  [types : CompilerRegVarTypes]
  [ineligible : CompilerLiveI64Set]
  [want-float : bool]) : CompilerRegIntervalList
  (match intervals
    [(CompilerRegIntervalNil) CompilerRegIntervalNil]
    [(CompilerRegIntervalCons interval rest)
      (match interval
        [(CompilerRegInterval var _ _)
          (let
            [tail : CompilerRegIntervalList
              (compiler-reg-candidates
                (box-get rest)
                types
                ineligible
                want-float)]
            (if (compiler-live-set-contains? ineligible var)
              tail
              (match (compiler-reg-var-types-lookup types var)
                [(CompilerRegSomeType ty)
                  (if (if want-float
                    (compiler-reg-float-type? ty)
                    (not (compiler-reg-float-type? ty)))
                    (compiler-reg-candidate-insert tail interval)
                    tail)]
                [(CompilerRegNoType) tail])))])]))

(define (compiler-reg-interval-list-more-than?
  [intervals : CompilerRegIntervalList]
  [limit : i64]) : bool
  (if (< limit 0)
    true
    (match intervals
      [(CompilerRegIntervalNil) false]
      [(CompilerRegIntervalCons _ rest)
        (compiler-reg-interval-list-more-than? (box-get rest) (- limit 1))])))

(define (compiler-reg-vector-defs-instr
  [instr : CompilerIrInstr]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match instr
    [(IrInstrLaneId dst _ _) (compiler-live-set-insert set dst)]
    [(IrInstrSplat dst _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrVectorBinOp payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorBinOpPayload dst _ _ _ _ _)
          (compiler-live-set-insert set dst)])]
    [(IrInstrSelect payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload dst _ _ _ _ _)
          (compiler-live-set-insert set dst)])]
    [(IrInstrVectorLoad dst _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrPredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload dst _ _ _ _ elem-ty)
          (match elem-ty
            [(AstTyBool) set]
            [_ (compiler-live-set-insert set dst)])])]
    [_ set]))

(define (compiler-reg-mask-defs-instr
  [instr : CompilerIrInstr]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match instr
    [(IrInstrVectorCompare payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorComparePayload dst _ _ _ _ _)
          (compiler-live-set-insert set dst)])]
    [(IrInstrMaskBinOp dst _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrMaskNot dst _ _) (compiler-live-set-insert set dst)]
    [(IrInstrPredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload dst _ _ _ _ elem-ty)
          (match elem-ty
            [(AstTyBool) (compiler-live-set-insert set dst)]
            [_ set])])]
    [(IrInstrTailMask dst _ _ _) (compiler-live-set-insert set dst)]
    [_ set]))

(define (compiler-reg-vector-mask-defs-instr-seq
  [instrs : CompilerIrInstrSeq]
  [vector-set : CompilerLiveI64Set]
  [mask-set : CompilerLiveI64Set]) : CompilerLiveUseDef
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [out-vector : CompilerLiveI64Set vector-set]
    [out-mask : CompilerLiveI64Set mask-set]
    (begin
      (while (< index count)
        (begin
          (set!
            out-vector
            (compiler-reg-vector-defs-instr
              (array.array-ref slots index)
              out-vector))
          (set!
            out-mask
            (compiler-reg-mask-defs-instr
              (array.array-ref slots index)
              out-mask))
          (set! index (+ index 1))))
      (CompilerLiveUseDef out-vector out-mask))))

(define (compiler-reg-vector-mask-defs-blocks
  [blocks : CompilerIrBlockList]
  [vector-set : CompilerLiveI64Set]
  [mask-set : CompilerLiveI64Set]) : CompilerLiveUseDef
  (match blocks
    [(IrBlockNil) (CompilerLiveUseDef vector-set mask-set)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (match (compiler-reg-vector-mask-defs-instr-seq
            instrs
            vector-set
            mask-set)
            [(CompilerLiveUseDef next-vector next-mask)
              (compiler-reg-vector-mask-defs-blocks
                (box-get rest)
                next-vector
                next-mask)])])]
    [(IrBlockArray seq)
      (compiler-reg-vector-mask-defs-blocks
        (compiler-ir-block-seq-to-list seq)
        vector-set
        mask-set)]))

(define (compiler-reg-function-vector-mask-defs [func : CompilerIrFunction]) : CompilerLiveUseDef
  (match func
    [(IrFunction _ _ _ _ blocks)
      (compiler-reg-vector-mask-defs-blocks
        blocks
        (compiler-live-set-empty)
        (compiler-live-set-empty))]))

(define (compiler-reg-special-candidates
  [intervals : CompilerRegIntervalList]
  [vars : CompilerLiveI64Set]
  [blocked : CompilerLiveI64Set]) : CompilerRegIntervalList
  (match intervals
    [(CompilerRegIntervalNil) CompilerRegIntervalNil]
    [(CompilerRegIntervalCons interval rest)
      (match interval
        [(CompilerRegInterval var _ _)
          (let
            [tail : CompilerRegIntervalList
              (compiler-reg-special-candidates (box-get rest) vars blocked)]
            (if (and
              (compiler-live-set-contains? vars var)
              (not (compiler-live-set-contains? blocked var)))
              (compiler-reg-candidate-insert tail interval)
              tail))])]))

(define (compiler-reg-active-count [active : CompilerRegActiveList]) : i64
  (match active
    [(CompilerRegActiveNil) 0]
    [(CompilerRegActiveCons _ rest)
      (+ 1 (compiler-reg-active-count (box-get rest)))]))

(define (compiler-reg-active-contains-register?
  [active : CompilerRegActiveList]
  [reg : String]) : bool
  (match active
    [(CompilerRegActiveNil) false]
    [(CompilerRegActiveCons item rest)
      (match item
        [(CompilerRegActive _ _ active-reg)
          (if (string.string-eq reg active-reg)
            true
            (compiler-reg-active-contains-register? (box-get rest) reg))])]))

(define (compiler-reg-active-register-conflicts-except?
  [active : CompilerRegActiveList]
  [reg : String]
  [except-var : i64]) : bool
  (match active
    [(CompilerRegActiveNil) false]
    [(CompilerRegActiveCons item rest)
      (match item
        [(CompilerRegActive active-var _ active-reg)
          (if (and
            (string.string-eq reg active-reg)
            (not (= active-var except-var)))
            true
            (compiler-reg-active-register-conflicts-except?
              (box-get rest)
              reg
              except-var))])]))

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
    [(CompilerRegActiveNil)
      (compiler-reg-active-cons item CompilerRegActiveNil)]
    [(CompilerRegActiveCons head rest)
      (if (compiler-reg-active-before? item head)
        (compiler-reg-active-cons item active)
        (compiler-reg-active-cons
          head
          (compiler-reg-active-insert (box-get rest) item)))]))

(define (compiler-reg-expire-active
  [active : CompilerRegActiveList]
  [start : i64]) : CompilerRegActiveList
  (match active
    [(CompilerRegActiveNil) CompilerRegActiveNil]
    [(CompilerRegActiveCons item rest)
      (match item
        [(CompilerRegActive _ end _)
          (if (<= end start)
            (compiler-reg-expire-active (box-get rest) start)
            (compiler-reg-active-insert
              (compiler-reg-expire-active (box-get rest) start)
              item))])]))

(define (compiler-reg-first-free-register
  [regs : CompilerRegStringList]
  [active : CompilerRegActiveList]) : String
  (match regs
    [(CompilerRegStringNil) "%r12"]
    [(CompilerRegStringCons reg rest)
      (if (compiler-reg-active-contains-register? active reg)
        (compiler-reg-first-free-register (box-get rest) active)
        reg)]))

;; #3489 (PR4) -> general hole-filling: is `reg` held by an active value that
;; conflicts with `var`? Two same-register values conflict iff their live
;; SEGMENTS overlap. This is sound for EVERY candidate because the allocator runs
;; on the merged-root index, where each candidate carries complete segments -- a
;; singleton its own live range, a class root the union of its members'. Every
;; segment hole is therefore genuine deadness, exactly the LLVM LiveInterval
;; property that makes segment-overlap an exact interference test. The earlier
;; rule trusted holes only for non-singleton roots, conservatively treating all
;; other values' segments as if incomplete; the merged-root index guarantees they
;; are not, so the restriction is dropped. (`hole-aware-vars` is retained on the
;; signature for the call sites but no longer gates the decision.)
(define (compiler-reg-active-register-conflicts?
  [active : CompilerRegActiveList]
  [reg : String]
  [index : CompilerRegIntervalIndex]
  [var : i64]
  [hole-aware-vars : CompilerLiveI64Set]) : bool
  (match active
    [(CompilerRegActiveNil) false]
    [(CompilerRegActiveCons item rest)
      (match item
        [(CompilerRegActive aid _ areg)
          (if (string.string-eq reg areg)
            (if (not
              (compiler-reg-vars-interfere-segmented-index? index var aid))
              (compiler-reg-active-register-conflicts?
                (box-get rest)
                reg
                index
                var
                hole-aware-vars)
              true)
            (compiler-reg-active-register-conflicts?
              (box-get rest)
              reg
              index
              var
              hole-aware-vars))])]))

;; #3489 (PR4): first register not in conflict with `var` over its live segments
;; (CompilerRegNoString if every register is occupied by an interfering value).
(define (compiler-reg-first-free-register-holes
  [regs : CompilerRegStringList]
  [active : CompilerRegActiveList]
  [index : CompilerRegIntervalIndex]
  [var : i64]
  [hole-aware-vars : CompilerLiveI64Set]) : CompilerRegMaybeString
  (match regs
    [(CompilerRegStringNil) (CompilerRegNoString)]
    [(CompilerRegStringCons reg rest)
      (if (compiler-reg-active-register-conflicts?
        active
        reg
        index
        var
        hole-aware-vars)
        (compiler-reg-first-free-register-holes
          (box-get rest)
          active
          index
          var
          hole-aware-vars)
        (CompilerRegSomeString reg))]))

(define (compiler-reg-active-max [active : CompilerRegActiveList]) : CompilerRegMaybeActive
  (match active
    [(CompilerRegActiveNil) CompilerRegNoActive]
    [(CompilerRegActiveCons item rest)
      (match (compiler-reg-active-max (box-get rest))
        [(CompilerRegNoActive) (CompilerRegSomeActive item)]
        [(CompilerRegSomeActive other)
          (if (compiler-reg-active-before? item other)
            (CompilerRegSomeActive other)
            (CompilerRegSomeActive item))])]))

;; #2386: furthest-ending active var that is NOT a 2-word register-group var.
;; Spilling is only ever applied to scalar (single-register) vars; a group var
;; occupies a register PAIR and cannot be evicted to a single 8-byte spill slot
;; without corrupting word1, so it must never be chosen as a spill victim. Group
;; vars that cannot get a pair are left unassigned (homed in their 16-byte stack
;; region) before reaching here.
(define (compiler-reg-active-max-non-group
  [active : CompilerRegActiveList]
  [group-vars : CompilerLiveI64Set]) : CompilerRegMaybeActive
  (match active
    [(CompilerRegActiveNil) CompilerRegNoActive]
    [(CompilerRegActiveCons item rest)
      (let
        [rest-max : CompilerRegMaybeActive
          (compiler-reg-active-max-non-group (box-get rest) group-vars)]
        (match item
          [(CompilerRegActive id _ _)
            (if (compiler-live-set-contains? group-vars id)
              rest-max
              (match rest-max
                [(CompilerRegNoActive) (CompilerRegSomeActive item)]
                [(CompilerRegSomeActive other)
                  (if (compiler-reg-active-before? item other)
                    (CompilerRegSomeActive other)
                    (CompilerRegSomeActive item))]))]))]))

(define (compiler-reg-active-remove-var
  [active : CompilerRegActiveList]
  [var : i64]) : CompilerRegActiveList
  (match active
    [(CompilerRegActiveNil) CompilerRegActiveNil]
    [(CompilerRegActiveCons item rest)
      (match item
        [(CompilerRegActive id _ _)
          (if (= id var)
            (compiler-reg-active-remove-var (box-get rest) var)
            (compiler-reg-active-cons
              item
              (compiler-reg-active-remove-var (box-get rest) var)))])]))

(define (compiler-reg-assignment-insert
  [assignments : CompilerRegAssignmentList]
  [var : i64]
  [location : CompilerRegLocation]) : CompilerRegAssignmentList
  (match assignments
    [(CompilerRegAssignmentNil)
      (compiler-reg-assignment-cons
        (CompilerRegAssignment var location)
        CompilerRegAssignmentNil)]
    [(CompilerRegAssignmentCons item rest)
      (match item
        [(CompilerRegAssignment id _)
          (if (= id var)
            (compiler-reg-assignment-cons
              (CompilerRegAssignment var location)
              (box-get rest))
            (if (> id var)
              (compiler-reg-assignment-cons
                (CompilerRegAssignment var location)
                assignments)
              (compiler-reg-assignment-cons
                item
                (compiler-reg-assignment-insert (box-get rest) var location))))])]))

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
              (compiler-reg-assignment-lookup (box-get rest) var)))])]))

(define (compiler-reg-location-eq?
  [left : CompilerRegLocation]
  [right : CompilerRegLocation]) : bool
  (match left
    [(CompilerRegRegister left-reg)
      (match right
        [(CompilerRegRegister right-reg) (string.string-eq left-reg right-reg)]
        [_ false])]
    [(CompilerRegRegisterPair left-a left-b)
      (match right
        [(CompilerRegRegisterPair right-a right-b)
          (and
            (string.string-eq left-a right-a)
            (string.string-eq left-b right-b))]
        [_ false])]
    [(CompilerRegSpill left-offset)
      (match right
        [(CompilerRegSpill right-offset) (= left-offset right-offset)]
        [_ false])]
    ;; Conservative: distinct rematerialised values never alias, and treating two
    ;; equal ones as different only forgoes a copy elision (never unsound).
    [(CompilerRegRemat _) false]))

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
              (compiler-reg-interval-lookup (box-get rest) var)))])]))

(define (compiler-reg-interval-overlap?
  [left : CompilerRegInterval]
  [right : CompilerRegInterval]) : bool
  (match left
    [(CompilerRegInterval _ left-start left-end)
      (match right
        [(CompilerRegInterval _ right-start right-end)
          (not (or (<= left-end right-start) (<= right-end left-start)))])]))

(define (compiler-reg-interval-list-overlaps-one?
  [segments : CompilerRegIntervalList]
  [interval : CompilerRegInterval]) : bool
  (match segments
    [(CompilerRegIntervalNil) false]
    [(CompilerRegIntervalCons head rest)
      (if (compiler-reg-interval-overlap? head interval)
        true
        (compiler-reg-interval-list-overlaps-one? (box-get rest) interval))]))

(define (compiler-reg-interval-list-overlaps?
  [left : CompilerRegIntervalList]
  [right : CompilerRegIntervalList]) : bool
  (match left
    [(CompilerRegIntervalNil) false]
    [(CompilerRegIntervalCons head rest)
      (if (compiler-reg-interval-list-overlaps-one? right head)
        true
        (compiler-reg-interval-list-overlaps? (box-get rest) right))]))

(define (compiler-reg-interval-range?
  [intervals : CompilerRegIntervalList]
  [var : i64]
  [start : i64]
  [end : i64]) : bool
  (match (compiler-reg-interval-lookup intervals var)
    [(CompilerRegSomeInterval interval)
      (match interval
        [(CompilerRegInterval _ got-start got-end)
          (and (= got-start start) (= got-end end))])]
    [(CompilerRegNoInterval) false]))

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

(define (compiler-reg-vars-interfere-index?
  [intervals : CompilerRegIntervalIndex]
  [left : i64]
  [right : i64]) : bool
  (if (= left right)
    true
    (match (compiler-reg-interval-index-lookup intervals left)
      [(CompilerRegSomeInterval left-interval)
        (match (compiler-reg-interval-index-lookup intervals right)
          [(CompilerRegSomeInterval right-interval)
            (compiler-reg-interval-overlap? left-interval right-interval)]
          [(CompilerRegNoInterval) true])]
      [(CompilerRegNoInterval) true])))

;; #3486 infrastructure: answer interference from per-var live segments when both
;; sides have segment data, with the old coarse interval as the conservative
;; fallback. Allocation still calls compiler-reg-vars-interfere-index? until the
;; policy changes that consume holes are proven independently.
(define (compiler-reg-vars-interfere-segmented-index?
  [intervals : CompilerRegIntervalIndex]
  [left : i64]
  [right : i64]) : bool
  (if (= left right)
    true
    (let
      [segments : (Array CompilerRegIntervalList)
        (struct-get intervals segments)]
      [left-segments : CompilerRegIntervalList
        (if (or (< left 0) (>= left (array.array-length segments)))
          CompilerRegIntervalNil
          (array.array-ref segments left))]
      [right-segments : CompilerRegIntervalList
        (if (or (< right 0) (>= right (array.array-length segments)))
          CompilerRegIntervalNil
          (array.array-ref segments right))]
      (if (and
        (not (compiler-reg-interval-list-empty? left-segments))
        (not (compiler-reg-interval-list-empty? right-segments)))
        (compiler-reg-interval-list-overlaps? left-segments right-segments)
        (compiler-reg-vars-interfere-index? intervals left right)))))

;; Two values may share a register iff they occupy the SAME register class. The
;; old rule demanded identical AstType tags AND scalar-ness, which refused to
;; coalesce a copy between e.g. an i64 and a Ptr, or -- far more commonly in this
;; compiler -- between any two 8-byte HANDLE values (Enum/Struct/String/Box/Array
;; descriptors), even though all of those live in one GP register and are moved
;; with a plain movq. Nominal type is irrelevant to register sharing: the only
;; constraint is GP-vs-SSE (you cannot put a GP value in an XMM register), and
;; width consistency is already guaranteed because coalescing is driven by pure
;; moves, whose two endpoints always have the same representation. So: both
;; register-eligible, and both the same register class.
(define (compiler-reg-compatible-types?
  [types : CompilerRegVarTypes]
  [left : i64]
  [right : i64]) : bool
  (match (compiler-reg-var-types-lookup types left)
    [(CompilerRegSomeType left-ty)
      (match (compiler-reg-var-types-lookup types right)
        [(CompilerRegSomeType right-ty)
          (and
            (compiler-reg-register-eligible-type? left-ty)
            (compiler-reg-register-eligible-type? right-ty)
            (if (compiler-reg-float-type? left-ty)
              (compiler-reg-float-type? right-ty)
              (not (compiler-reg-float-type? right-ty))))]
        [(CompilerRegNoType) false])]
    [(CompilerRegNoType) false]))

(define (compiler-reg-same-value-overlap-eligible?
  [types : CompilerRegVarTypes]
  [left : i64]
  [right : i64]) : bool
  (match (compiler-reg-var-types-lookup types left)
    [(CompilerRegSomeType left-ty)
      (match (compiler-reg-var-types-lookup types right)
        [(CompilerRegSomeType right-ty)
          (and
            (compiler-reg-scalar-type? left-ty)
            (compiler-reg-scalar-type? right-ty)
            (if (compiler-reg-float-type? left-ty)
              (compiler-reg-float-type? right-ty)
              (not (compiler-reg-float-type? right-ty))))]
        [(CompilerRegNoType) false])]
    [(CompilerRegNoType) false]))

(define (compiler-reg-location-conflicts?
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalIndex]
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
              (box-get rest)
              intervals
              var
              ignore-var
              location)
            (if (and
              (compiler-reg-location-eq? assigned-location location)
              (compiler-reg-vars-interfere-index? intervals var assigned-var))
              true
              (compiler-reg-location-conflicts?
                (box-get rest)
                intervals
                var
                ignore-var
                location)))])]))

(define (compiler-reg-assignment-table-location-conflicts-from?
  [assignments : CompilerRegAssignmentTable]
  [intervals : CompilerRegIntervalIndex]
  [var : i64]
  [ignore-var : i64]
  [location : CompilerRegLocation]
  [index : i64]) : bool
  (let
    [present : (Array i64) (struct-get assignments present)]
    [items : (Array CompilerRegLocation) (struct-get assignments items)]
    (cond
      [(>= index (array.array-length present)) false]
      [(= (array.array-ref present index) 0)
        (compiler-reg-assignment-table-location-conflicts-from?
          assignments
          intervals
          var
          ignore-var
          location
          (+ index 1))]
      [(or (= index var) (= index ignore-var))
        (compiler-reg-assignment-table-location-conflicts-from?
          assignments
          intervals
          var
          ignore-var
          location
          (+ index 1))]
      [(and
          (compiler-reg-location-eq? (array.array-ref items index) location)
          (compiler-reg-vars-interfere-index? intervals var index))
        true]
      [else
        (compiler-reg-assignment-table-location-conflicts-from?
          assignments
          intervals
          var
          ignore-var
          location
          (+ index 1))])))

(define (compiler-reg-assignment-table-location-conflicts?
  [assignments : CompilerRegAssignmentTable]
  [intervals : CompilerRegIntervalIndex]
  [var : i64]
  [ignore-var : i64]
  [location : CompilerRegLocation]) : bool
  (compiler-reg-assignment-table-location-conflicts-from?
    assignments
    intervals
    var
    ignore-var
    location
    0))

(define (compiler-reg-assignment-table-location-conflicts-segmented-from?
  [assignments : CompilerRegAssignmentTable]
  [intervals : CompilerRegIntervalIndex]
  [var : i64]
  [ignore-var : i64]
  [location : CompilerRegLocation]
  [index : i64]) : bool
  (let
    [present : (Array i64) (struct-get assignments present)]
    [items : (Array CompilerRegLocation) (struct-get assignments items)]
    (cond
      [(>= index (array.array-length present)) false]
      [(= (array.array-ref present index) 0)
        (compiler-reg-assignment-table-location-conflicts-segmented-from?
          assignments
          intervals
          var
          ignore-var
          location
          (+ index 1))]
      [(or (= index var) (= index ignore-var))
        (compiler-reg-assignment-table-location-conflicts-segmented-from?
          assignments
          intervals
          var
          ignore-var
          location
          (+ index 1))]
      [(and
          (compiler-reg-location-eq? (array.array-ref items index) location)
          (compiler-reg-vars-interfere-segmented-index? intervals var index))
        true]
      [else
        (compiler-reg-assignment-table-location-conflicts-segmented-from?
          assignments
          intervals
          var
          ignore-var
          location
          (+ index 1))])))

(define (compiler-reg-assignment-table-location-conflicts-segmented?
  [assignments : CompilerRegAssignmentTable]
  [intervals : CompilerRegIntervalIndex]
  [var : i64]
  [ignore-var : i64]
  [location : CompilerRegLocation]) : bool
  (compiler-reg-assignment-table-location-conflicts-segmented-from?
    assignments
    intervals
    var
    ignore-var
    location
    0))

(define (compiler-reg-coalesce-location-legacy-from-var
  [assignments : CompilerRegAssignmentTable]
  [intervals : CompilerRegIntervalIndex]
  [types : CompilerRegVarTypes]
  [var : i64]
  [other : i64]) : CompilerRegMaybeLocation
  (if (or
    (= var other)
    (not (compiler-reg-compatible-types? types var other))
    (compiler-reg-vars-interfere-index? intervals var other))
    CompilerRegNoLocation
    (match (compiler-reg-assignment-table-lookup assignments other)
      [(CompilerRegSomeLocation location)
        (if (compiler-reg-assignment-table-location-conflicts?
          assignments
          intervals
          var
          other
          location)
          CompilerRegNoLocation
          (CompilerRegSomeLocation location))]
      [(CompilerRegNoLocation) CompilerRegNoLocation])))

(define (compiler-reg-coalesce-location-legacy
  [moves : CompilerRegMoveList]
  [assignments : CompilerRegAssignmentTable]
  [intervals : CompilerRegIntervalIndex]
  [types : CompilerRegVarTypes]
  [var : i64]) : CompilerRegMaybeLocation
  (match moves
    [(CompilerRegMoveNil) CompilerRegNoLocation]
    [(CompilerRegMoveCons move rest)
      (match move
        [(CompilerRegMove src dst _)
          (if (= dst var)
            (match (compiler-reg-coalesce-location-legacy-from-var
              assignments
              intervals
              types
              var
              src)
              [(CompilerRegSomeLocation location)
                (CompilerRegSomeLocation location)]
              [(CompilerRegNoLocation)
                (compiler-reg-coalesce-location-legacy
                  (box-get rest)
                  assignments
                  intervals
                  types
                  var)])
            (if (= src var)
              (match (compiler-reg-coalesce-location-legacy-from-var
                assignments
                intervals
                types
                var
                dst)
                [(CompilerRegSomeLocation location)
                  (CompilerRegSomeLocation location)]
                [(CompilerRegNoLocation)
                  (compiler-reg-coalesce-location-legacy
                    (box-get rest)
                    assignments
                    intervals
                    types
                    var)])
              (compiler-reg-coalesce-location-legacy
                (box-get rest)
                assignments
                intervals
                types
                var)))])]))

;; ---------------------------------------------------------------------------
;; #2 value-number same-value coalescing (move-flood bucket b).
;;
;; Bucket b (un-coalesced SSA copies, the dominant move class) is src-live
;; fan-out: `dst := src` where src stays live past the copy, so src and dst
;; OVERLAP and the interference-gated coalescer rejects them. But a copy whose
;; dst and src are BOTH single-static-def holds one identical value over the
;; entire overlap (dst mirrors src, neither is ever redefined), so merging them
;; into one register is sound regardless of overlap -- LLVM's
;; valuesIdentical/CR_Erase case (RegisterCoalescer.cpp:2799/3008).
;;
;; SOUNDNESS: only DIRECT `IrInstrMov dst (IrValueVar src)` copies with
;; def-count[dst]==def-count[src]==1 enter the same-value relation. Phi inputs
;; (path-dependent) and multi-def vars -- the loop-carried set!/back-edge values
;; that are the #3489 fibonacci/four_acc/bce_sum miscompile class -- are EXCLUDED
;; because loop-carried values are lowered to phis or carry multiple defs and so
;; are never single-def direct copies. The relaxation only WAIVES interference
;; for proven same-value pairs; the geometry predicate is unchanged, and the
;; all-pairs class-compatibility check still rejects any class that would mix a
;; distinct-value var with an overlapping member.
;; The single var an instruction defines, or -1. Mirrors the def list of
;; compiler-reg-instr-def-type so the def census stays complete (a missed def
;; site would understate a multi-def var and is the one unsound failure mode).
(define (compiler-reg-instr-def-var [instr : CompilerIrInstr]) : i64
  (match instr
    [(IrInstrMov dst _ _) dst]
    [(IrInstrAlloc dst _) dst]
    [(IrInstrAddrOf dst _) dst]
    [(IrInstrGep dst _ _ _) dst]
    [(IrInstrLoad dst _ _) dst]
    [(IrInstrCast dst _ _ _) dst]
    [(IrInstrBitcast dst _ _ _) dst]
    [(IrInstrBinOp dst _ _ _ _) dst]
    [(IrInstrUnOp dst _ _ _) dst]
    [(IrInstrLaneId dst _ _) dst]
    [(IrInstrSplat dst _ _ _) dst]
    [(IrInstrVectorBinOp payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorBinOpPayload dst _ _ _ _ _) dst])]
    [(IrInstrVectorReduce dst _ _ _ _) dst]
    [(IrInstrVectorCompare payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorComparePayload dst _ _ _ _ _) dst])]
    [(IrInstrMaskBinOp dst _ _ _ _) dst]
    [(IrInstrMaskNot dst _ _) dst]
    [(IrInstrMaskReduce dst _ _ _) dst]
    [(IrInstrSelect payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload dst _ _ _ _ _) dst])]
    [(IrInstrVectorLoad dst _ _ _ _) dst]
    [(IrInstrPredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload dst _ _ _ _ _) dst])]
    [(IrInstrTailMask dst _ _ _) dst]
    [(IrInstrEntryArgc dst) dst]
    [(IrInstrEntryArgv dst) dst]
    [(IrInstrEntryEnvp dst) dst]
    [(IrInstrCpuId dst _ _ _) dst]
    [(IrInstrXgetbv dst _) dst]
    [(IrInstrSyscall dst _) dst]
    [(IrInstrCall dst _ _ _) dst]
    [(IrInstrCallIndirect dst _ _ _) dst]
    [(IrInstrCallIndirectC dst _ _ _) dst]
    [(IrInstrPhi dst _ _) dst]
    [(IrInstrPack dst _ _) dst]
    [(IrInstrWord dst _ _ _) dst]
    [_ (- 0 1)]))

(define (compiler-reg-count-def! [counts : (Array i64)] [var : i64]) : unit
  (if (and (>= var 0) (< var (array.array-length counts)))
    (array.array-set! counts var (+ (array.array-ref counts var) 1))
    unit))

(define (compiler-reg-count-seq-defs!
  [instrs : CompilerIrInstrSeq]
  [counts : (Array i64)]) : unit
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-reg-count-def!
            counts
            (compiler-reg-instr-def-var (array.array-ref slots index)))
          (set! index (+ index 1))))
      unit)))

(define (compiler-reg-count-block-defs!
  [blocks : CompilerIrBlockList]
  [counts : (Array i64)]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (begin
            (compiler-reg-count-seq-defs! instrs counts)
            (compiler-reg-count-block-defs! (box-get rest) counts))])]
    [(IrBlockArray seq)
      (compiler-reg-count-block-defs!
        (compiler-ir-block-seq-to-list seq)
        counts)]))

(define (compiler-reg-mark-phi-def! [phi-defs : (Array i64)] [var : i64]) : unit
  (if (and (>= var 0) (< var (array.array-length phi-defs)))
    (array.array-set! phi-defs var 1)
    unit))

(define (compiler-reg-mark-phi-defs-seq!
  [instrs : CompilerIrInstrSeq]
  [phi-defs : (Array i64)]) : unit
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (match (array.array-ref slots index)
            [(IrInstrPhi dst _ _) (compiler-reg-mark-phi-def! phi-defs dst)]
            [_ unit])
          (set! index (+ index 1))))
      unit)))

(define (compiler-reg-mark-phi-defs-blocks!
  [blocks : CompilerIrBlockList]
  [phi-defs : (Array i64)]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (begin
            (compiler-reg-mark-phi-defs-seq! instrs phi-defs)
            (compiler-reg-mark-phi-defs-blocks! (box-get rest) phi-defs))])]
    [(IrBlockArray seq)
      (compiler-reg-mark-phi-defs-blocks!
        (compiler-ir-block-seq-to-list seq)
        phi-defs)]))

(define (compiler-reg-param-count-defs!
  [params : CompilerIrParamList]
  [counts : (Array i64)]) : unit
  (match params
    [(IrParamNil) unit]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ _ id)
          (begin
            (compiler-reg-count-def! counts id)
            (compiler-reg-param-count-defs! (box-get rest) counts))])]))

(define (compiler-reg-function-def-counts [func : CompilerIrFunction]) : (Array
    i64)
  (match func
    [(IrFunction _ params _ vars blocks)
      (let
        [counts : (Array i64) (array.make-array i64 vars)]
        (begin
          (compiler-reg-fill-i64-array counts 0)
          (compiler-reg-param-count-defs! params counts)
          (compiler-reg-count-block-defs! blocks counts)
          counts))]))

;; Same-value union-find, path-compressed; the class root is its min member id.
(define (compiler-reg-sv-find [parents : (Array i64)] [x : i64]) : i64
  (if (or (< x 0) (>= x (array.array-length parents)))
    (- 0 1)
    (let
      [p : i64 (array.array-ref parents x)]
      (if (= p x)
        x
        (let
          [r : i64 (compiler-reg-sv-find parents p)]
          (begin
            (array.array-set! parents x r)
            r))))))

(define (compiler-reg-sv-union! [parents : (Array i64)] [a : i64] [b : i64]) : unit
  (let
    [ra : i64 (compiler-reg-sv-find parents a)]
    [rb : i64 (compiler-reg-sv-find parents b)]
    (if (or (< ra 0) (< rb 0) (= ra rb))
      unit
      (if (< ra rb)
        (array.array-set! parents rb ra)
        (array.array-set! parents ra rb)))))

(define (compiler-reg-sv-single-def? [counts : (Array i64)] [var : i64]) : bool
  (and
    (>= var 0)
    (< var (array.array-length counts))
    (= (array.array-ref counts var) 1)))

(define (compiler-reg-sv-single-def-non-phi?
  [counts : (Array i64)]
  [phi-defs : (Array i64)]
  [var : i64]) : bool
  (and
    (compiler-reg-sv-single-def? counts var)
    (or
      (>= var (array.array-length phi-defs))
      (= (array.array-ref phi-defs var) 0))))

(define (compiler-reg-sv-eligible? [eligible : (Array i64)] [var : i64]) : bool
  (if (= (array.array-length eligible) 0)
    true
    (and
      (>= var 0)
      (< var (array.array-length eligible))
      (= (array.array-ref eligible var) 1))))

(define (compiler-reg-sv-add-instr!
  [instr : CompilerIrInstr]
  [counts : (Array i64)]
  [phi-defs : (Array i64)]
  [eligible : (Array i64)]
  [parents : (Array i64)]) : unit
  (match instr
    [(IrInstrMov dst src _)
      (match src
        [(IrValueVar svar)
          (if (and
            (compiler-reg-sv-single-def-non-phi? counts phi-defs dst)
            (compiler-reg-sv-single-def-non-phi? counts phi-defs svar)
            (compiler-reg-sv-eligible? eligible dst)
            (compiler-reg-sv-eligible? eligible svar))
            (compiler-reg-sv-union! parents svar dst)
            unit)]
        [_ unit])]
    [_ unit]))

(define (compiler-reg-sv-seq!
  [instrs : CompilerIrInstrSeq]
  [counts : (Array i64)]
  [phi-defs : (Array i64)]
  [eligible : (Array i64)]
  [parents : (Array i64)]) : unit
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-reg-sv-add-instr!
            (array.array-ref slots index)
            counts
            phi-defs
            eligible
            parents)
          (set! index (+ index 1))))
      unit)))

(define (compiler-reg-sv-blocks!
  [blocks : CompilerIrBlockList]
  [counts : (Array i64)]
  [phi-defs : (Array i64)]
  [eligible : (Array i64)]
  [parents : (Array i64)]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (begin
            (compiler-reg-sv-seq! instrs counts phi-defs eligible parents)
            (compiler-reg-sv-blocks!
              (box-get rest)
              counts
              phi-defs
              eligible
              parents))])]
    [(IrBlockArray seq)
      (compiler-reg-sv-blocks!
        (compiler-ir-block-seq-to-list seq)
        counts
        phi-defs
        eligible
        parents)]))

(define (compiler-reg-function-same-value-parents-filtered
  [func : CompilerIrFunction]
  [eligible : (Array i64)]) : (Array i64)
  (match func
    [(IrFunction _ _ _ vars blocks)
      (let
        [counts : (Array i64) (compiler-reg-function-def-counts func)]
        [phi-defs : (Array i64) (array.make-array i64 vars)]
        [parents : (Array i64) (array.make-array i64 vars)]
        [index : i64 0]
        (begin
          (compiler-reg-fill-i64-array phi-defs 0)
          (compiler-reg-mark-phi-defs-blocks! blocks phi-defs)
          (while (< index vars)
            (begin
              (array.array-set! parents index index)
              (set! index (+ index 1))))
          (compiler-reg-sv-blocks! blocks counts phi-defs eligible parents)
          parents))]))

(define (compiler-reg-function-same-value-parents [func : CompilerIrFunction]) : (Array
    i64)
  (compiler-reg-function-same-value-parents-filtered
    func
    (array.make-array i64 0)))

(define (compiler-reg-same-value-eligible-vars
  [interval-index : CompilerRegIntervalIndex]
  [clobber-points : CompilerLiveI64Set]) : (Array i64)
  (let
    [starts : (Array i64) (struct-get interval-index starts)]
    [ends : (Array i64) (struct-get interval-index ends)]
    [eligible : (Array i64) (array.make-array i64 (array.array-length starts))]
    [var : i64 0]
    (begin
      (compiler-reg-fill-i64-array eligible 0)
      (while (< var (array.array-length starts))
        (begin
          (if (and
            (>= (array.array-ref starts var) 0)
            (not
              (compiler-reg-call-set-in-range?
                clobber-points
                (array.array-ref starts var)
                (array.array-ref ends var))))
            (array.array-set! eligible var 1)
            unit)
          (set! var (+ var 1))))
      eligible)))

(define (compiler-reg-same-value-class?
  [parents : (Array i64)]
  [left : i64]
  [right : i64]) : bool
  (if (= (array.array-length parents) 0)
    false
    (let
      [rl : i64 (compiler-reg-sv-find parents left)]
      [rr : i64 (compiler-reg-sv-find parents right)]
      (and (>= rl 0) (= rl rr)))))

(define (compiler-reg-coalesce-map-init!
  [parents : (Array i64)]
  [sizes : (Array i64)]
  [index : i64]) : unit
  (if (>= index (array.array-length parents))
    unit
    (begin
      (array.array-set! parents index index)
      (array.array-set! sizes index 1)
      (compiler-reg-coalesce-map-init! parents sizes (+ index 1)))))

(define (compiler-reg-coalesce-map-root-from-parents
  [parents : (Array i64)]
  [var : i64]) : i64
  (if (or (< var 0) (>= var (array.array-length parents)))
    (- 0 1)
    (array.array-ref parents var)))

(define (compiler-reg-coalesce-vars-compatible?
  [intervals : CompilerRegIntervalIndex]
  [types : CompilerRegVarTypes]
  [group-vars : CompilerLiveI64Set]
  [left : i64]
  [right : i64]
  [strict : bool]
  [sv-parents : (Array i64)]) : bool
  (and
    (not (= left right))
    (not (compiler-live-set-contains? group-vars left))
    (not (compiler-live-set-contains? group-vars right))
    (compiler-reg-compatible-types? types left right)
    ;; #2 same-value relaxation: a proven same-value pair (single-def direct copy)
    ;; may coalesce despite overlap -- one register holds the shared value. The
    ;; geometry test itself is unchanged; this only ADDS the same-value escape.
    (or
      (not
        (if strict
          (compiler-reg-vars-interfere-index? intervals left right)
          (compiler-reg-vars-interfere-segmented-index? intervals left right)))
      (and
        (compiler-reg-same-value-overlap-eligible? types left right)
        (compiler-reg-same-value-class? sv-parents left right)))))

(define (compiler-reg-coalesce-map-var-compatible-with-root?
  [parents : (Array i64)]
  [intervals : CompilerRegIntervalIndex]
  [types : CompilerRegVarTypes]
  [group-vars : CompilerLiveI64Set]
  [var : i64]
  [root : i64]
  [strict : bool]
  [index : i64]
  [sv-parents : (Array i64)]) : bool
  (cond
    [(>= index (array.array-length parents)) true]
    [(= (array.array-ref parents index) root)
      (if (compiler-reg-coalesce-vars-compatible?
        intervals
        types
        group-vars
        var
        index
        strict
        sv-parents)
        (compiler-reg-coalesce-map-var-compatible-with-root?
          parents
          intervals
          types
          group-vars
          var
          root
          strict
          (+ index 1)
          sv-parents)
        false)]
    [else
      (compiler-reg-coalesce-map-var-compatible-with-root?
        parents
        intervals
        types
        group-vars
        var
        root
        strict
        (+ index 1)
        sv-parents)]))

(define (compiler-reg-coalesce-map-classes-compatible-from?
  [parents : (Array i64)]
  [intervals : CompilerRegIntervalIndex]
  [types : CompilerRegVarTypes]
  [group-vars : CompilerLiveI64Set]
  [left-root : i64]
  [right-root : i64]
  [strict : bool]
  [index : i64]
  [sv-parents : (Array i64)]) : bool
  (cond
    [(>= index (array.array-length parents)) true]
    [(= (array.array-ref parents index) left-root)
      (if (compiler-reg-coalesce-map-var-compatible-with-root?
        parents
        intervals
        types
        group-vars
        index
        right-root
        strict
        0
        sv-parents)
        (compiler-reg-coalesce-map-classes-compatible-from?
          parents
          intervals
          types
          group-vars
          left-root
          right-root
          strict
          (+ index 1)
          sv-parents)
        false)]
    [else
      (compiler-reg-coalesce-map-classes-compatible-from?
        parents
        intervals
        types
        group-vars
        left-root
        right-root
        strict
        (+ index 1)
        sv-parents)]))

(define (compiler-reg-coalesce-map-classes-compatible?
  [parents : (Array i64)]
  [intervals : CompilerRegIntervalIndex]
  [types : CompilerRegVarTypes]
  [group-vars : CompilerLiveI64Set]
  [left-root : i64]
  [right-root : i64]
  [strict : bool]
  [sv-parents : (Array i64)]) : bool
  (compiler-reg-coalesce-map-classes-compatible-from?
    parents
    intervals
    types
    group-vars
    left-root
    right-root
    strict
    0
    sv-parents))

(define (compiler-reg-coalesce-map-merge-root-parents-into!
  [parents : (Array i64)]
  [winner : i64]
  [loser : i64]
  [index : i64]) : unit
  (if (>= index (array.array-length parents))
    unit
    (begin
      (if (= (array.array-ref parents index) loser)
        (array.array-set! parents index winner)
        unit)
      (compiler-reg-coalesce-map-merge-root-parents-into!
        parents
        winner
        loser
        (+ index 1)))))

;; Per-pair join (LLVM joinVirtRegs structure): maintain a per-root merged COARSE
;; interval [start,end] -- the union extent of the class members. Two roots with
;; DISJOINT coarse extents provably have no interfering member pair (each member's
;; segments lie within its coarse interval, which lies within the root extent), so
;; they join in O(1) without the O(n^2) all-pairs class scan. This is a sound
;; SUBSET of classes-compatible? (coarse-disjoint => segment-disjoint => every
;; cross pair non-interfering; the class is type-homogeneous and src/dst types are
;; already checked), so the coalescing RESULT is identical -- only the common
;; disjoint case takes the fast path. When extents overlap, the exact
;; classes-compatible? check still decides, preserving #3489 semantics precisely.
(define (compiler-reg-coalesce-init-coarse!
  [root-start : (Array i64)]
  [root-end : (Array i64)]
  [src-start : (Array i64)]
  [src-end : (Array i64)]
  [index : i64]) : unit
  (if (>= index (array.array-length root-start))
    unit
    (begin
      (array.array-set!
        root-start
        index
        (if (< index (array.array-length src-start))
          (array.array-ref src-start index)
          (- 0 1)))
      (array.array-set!
        root-end
        index
        (if (< index (array.array-length src-end))
          (array.array-ref src-end index)
          (- 0 1)))
      (compiler-reg-coalesce-init-coarse!
        root-start
        root-end
        src-start
        src-end
        (+ index 1)))))

(define (compiler-reg-coalesce-coarse-disjoint?
  [root-start : (Array i64)]
  [root-end : (Array i64)]
  [a : i64]
  [b : i64]) : bool
  (let
    [a-start : i64 (array.array-ref root-start a)]
    [a-end : i64 (array.array-ref root-end a)]
    [b-start : i64 (array.array-ref root-start b)]
    [b-end : i64 (array.array-ref root-end b)]
    (if (or (< a-start 0) (< a-end 0) (< b-start 0) (< b-end 0))
      false
      (or (<= a-end b-start) (<= b-end a-start)))))

(define (compiler-reg-coalesce-map-merge-root-into!
  [parents : (Array i64)]
  [sizes : (Array i64)]
  [root-start : (Array i64)]
  [root-end : (Array i64)]
  [winner : i64]
  [loser : i64]) : unit
  (begin
    (array.array-set!
      sizes
      winner
      (+ (array.array-ref sizes winner) (array.array-ref sizes loser)))
    (array.array-set! sizes loser 0)
    (let
      [loser-start : i64 (array.array-ref root-start loser)]
      [loser-end : i64 (array.array-ref root-end loser)]
      [winner-start : i64 (array.array-ref root-start winner)]
      [winner-end : i64 (array.array-ref root-end winner)]
      (begin
        (if (< winner-start 0)
          (array.array-set! root-start winner loser-start)
          (if (if (< loser-start 0)
            false
            (< loser-start winner-start))
            (array.array-set! root-start winner loser-start)
            unit))
        (if (> loser-end winner-end)
          (array.array-set! root-end winner loser-end)
          unit)))
    (compiler-reg-coalesce-map-merge-root-parents-into! parents winner loser 0)))

(define (compiler-reg-coalesce-map-try-merge!
  [parents : (Array i64)]
  [sizes : (Array i64)]
  [root-start : (Array i64)]
  [root-end : (Array i64)]
  [intervals : CompilerRegIntervalIndex]
  [types : CompilerRegVarTypes]
  [group-vars : CompilerLiveI64Set]
  [left : i64]
  [right : i64]
  [strict : bool]
  [sv-parents : (Array i64)]) : bool
  (let
    [left-root : i64 (compiler-reg-coalesce-map-root-from-parents parents left)]
    [right-root : i64
      (compiler-reg-coalesce-map-root-from-parents parents right)]
    (cond
      [(or (< left-root 0) (< right-root 0) (= left-root right-root)) false]
      [(not
          (compiler-reg-coalesce-vars-compatible?
            intervals
            types
            group-vars
            left
            right
            strict
            sv-parents))
        false]
      [(or
          (and
            (= (array.array-ref sizes left-root) 1)
            (= (array.array-ref sizes right-root) 1))
          ;; per-pair join fast path: disjoint merged extents => trivially legal.
          (compiler-reg-coalesce-coarse-disjoint?
            root-start
            root-end
            left-root
            right-root)
          (compiler-reg-coalesce-map-classes-compatible?
            parents
            intervals
            types
            group-vars
            left-root
            right-root
            strict
            sv-parents))
        (let
          [winner : i64
            (if (< left-root right-root)
              left-root
              right-root)]
          [loser : i64
            (if (< left-root right-root)
              right-root
              left-root)]
          (begin
            (compiler-reg-coalesce-map-merge-root-into!
              parents
              sizes
              root-start
              root-end
              winner
              loser)
            true))]
      [else false])))

(define (compiler-reg-coalesce-map-merge-moves!
  [parents : (Array i64)]
  [sizes : (Array i64)]
  [root-start : (Array i64)]
  [root-end : (Array i64)]
  [moves : CompilerRegMoveList]
  [intervals : CompilerRegIntervalIndex]
  [types : CompilerRegVarTypes]
  [group-vars : CompilerLiveI64Set]
  [changed : bool]
  [sv-parents : (Array i64)]) : bool
  (match moves
    [(CompilerRegMoveNil) changed]
    [(CompilerRegMoveCons move rest)
      (match move
        [(CompilerRegMove src dst strict)
          (let
            [did-merge : bool
              (compiler-reg-coalesce-map-try-merge!
                parents
                sizes
                root-start
                root-end
                intervals
                types
                group-vars
                src
                dst
                strict
                sv-parents)]
            (compiler-reg-coalesce-map-merge-moves!
              parents
              sizes
              root-start
              root-end
              (box-get rest)
              intervals
              types
              group-vars
              (or changed did-merge)
              sv-parents))])]))

(define (compiler-reg-coalesce-map-fixpoint!
  [parents : (Array i64)]
  [sizes : (Array i64)]
  [root-start : (Array i64)]
  [root-end : (Array i64)]
  [moves : CompilerRegMoveList]
  [intervals : CompilerRegIntervalIndex]
  [types : CompilerRegVarTypes]
  [group-vars : CompilerLiveI64Set]
  [sv-parents : (Array i64)]) : unit
  (begin
    (compiler-reg-coalesce-map-merge-moves!
      parents
      sizes
      root-start
      root-end
      moves
      intervals
      types
      group-vars
      false
      sv-parents)
    unit))

(define (compiler-reg-coalesce-map-build
  [moves : CompilerRegMoveList]
  [intervals : CompilerRegIntervalIndex]
  [types : CompilerRegVarTypes]
  [group-vars : CompilerLiveI64Set]
  [vars : i64]
  [sv-parents : (Array i64)]) : CompilerRegCoalesceMap
  (if (compiler-reg-move-list-empty? moves)
    (CompilerRegCoalesceMap (array.make-array i64 0))
    (let
      [n : i64
        (if (< vars 1)
          1
          vars)]
      [parents : (Array i64) (array.make-array i64 n)]
      [sizes : (Array i64) (array.make-array i64 n)]
      [root-start : (Array i64) (array.make-array i64 n)]
      [root-end : (Array i64) (array.make-array i64 n)]
      (begin
        (compiler-reg-coalesce-map-init! parents sizes 0)
        (compiler-reg-coalesce-init-coarse!
          root-start
          root-end
          (struct-get intervals starts)
          (struct-get intervals ends)
          0)
        (compiler-reg-coalesce-map-fixpoint!
          parents
          sizes
          root-start
          root-end
          moves
          intervals
          types
          group-vars
          sv-parents)
        (CompilerRegCoalesceMap parents)))))

(define (compiler-reg-coalesce-location-from-class-from
  [coalesce : CompilerRegCoalesceMap]
  [assignments : CompilerRegAssignmentTable]
  [intervals : CompilerRegIntervalIndex]
  [var : i64]
  [root : i64]
  [index : i64]) : CompilerRegMaybeLocation
  (let
    [parents : (Array i64) (struct-get coalesce parents)]
    (cond
      [(>= index (array.array-length parents)) CompilerRegNoLocation]
      [(or (= index var) (not (= (array.array-ref parents index) root)))
        (compiler-reg-coalesce-location-from-class-from
          coalesce
          assignments
          intervals
          var
          root
          (+ index 1))]
      [else
        (match (compiler-reg-assignment-table-lookup assignments index)
          [(CompilerRegSomeLocation location)
            (if (compiler-reg-assignment-table-location-conflicts-segmented?
              assignments
              intervals
              var
              index
              location)
              (compiler-reg-coalesce-location-from-class-from
                coalesce
                assignments
                intervals
                var
                root
                (+ index 1))
              (CompilerRegSomeLocation location))]
          [(CompilerRegNoLocation)
            (compiler-reg-coalesce-location-from-class-from
              coalesce
              assignments
              intervals
              var
              root
              (+ index 1))])])))

(define (compiler-reg-coalesce-location
  [coalesce : CompilerRegCoalesceMap]
  [assignments : CompilerRegAssignmentTable]
  [intervals : CompilerRegIntervalIndex]
  [var : i64]) : CompilerRegMaybeLocation
  (let
    [parents : (Array i64) (struct-get coalesce parents)]
    [root : i64 (compiler-reg-coalesce-map-root-from-parents parents var)]
    (if (< root 0)
      CompilerRegNoLocation
      (compiler-reg-coalesce-location-from-class-from
        coalesce
        assignments
        intervals
        var
        root
        0))))

(define (compiler-reg-assignment-count
  [assignments : CompilerRegAssignmentList]) : i64
  (match assignments
    [(CompilerRegAssignmentNil) 0]
    [(CompilerRegAssignmentCons _ rest)
      (+ 1 (compiler-reg-assignment-count (box-get rest)))]))

(define (compiler-reg-spill-count [assignments : CompilerRegAssignmentList]) : i64
  (match assignments
    [(CompilerRegAssignmentNil) 0]
    [(CompilerRegAssignmentCons item rest)
      (match item
        [(CompilerRegAssignment _ location)
          (match location
            [(CompilerRegSpill _)
              (+ 1 (compiler-reg-spill-count (box-get rest)))]
            [_ (compiler-reg-spill-count (box-get rest))])])]))

;; Spill weight for `var` (#3473/#3490). The scalar opt2 path passes
;; loop-depth-weighted counts; unweighted/empty arrays still keep the old
;; deterministic policy for other stages. Out-of-range vars score 0.
(define (compiler-reg-spill-weight [ref-counts : (Array i64)] [var : i64]) : i64
  (if (and (>= var 0) (< var (array.array-length ref-counts)))
    (array.array-ref ref-counts var)
    0))

;; Does `var` already hold a hard register (single or pair) in the table? Used to
;; let the primary callee-saved pass skip values a prior pass already homed.
(define (compiler-reg-assignment-table-register-assigned?
  [assignments : CompilerRegAssignmentTable]
  [var : i64]) : bool
  (match (compiler-reg-assignment-table-lookup assignments var)
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegRegister _) true]
        [(CompilerRegRegisterPair _ _) true]
        [_ false])]
    [(CompilerRegNoLocation) false]))

(define (compiler-reg-copy-hints-add-move!
  [hints : (Array i64)]
  [parents : (Array i64)]
  [src : i64]
  [dst : i64]) : unit
  (let
    [n : i64 (array.array-length hints)]
    [root-src : i64
      (if (if (>= src 0)
        (< src (array.array-length parents))
        false)
        (array.array-ref parents src)
        src)]
    [root-dst : i64
      (if (if (>= dst 0)
        (< dst (array.array-length parents))
        false)
        (array.array-ref parents dst)
        dst)]
    (if (or
      (= root-src root-dst)
      (< root-src 0)
      (>= root-src n)
      (< root-dst 0)
      (>= root-dst n))
      unit
      (begin
        (if (< (array.array-ref hints root-src) 0)
          (array.array-set! hints root-src root-dst)
          unit)
        (if (< (array.array-ref hints root-dst) 0)
          (array.array-set! hints root-dst root-src)
          unit)
        unit))))

(define (compiler-reg-copy-hints-from-moves!
  [hints : (Array i64)]
  [parents : (Array i64)]
  [moves : CompilerRegMoveList]) : unit
  (match moves
    [(CompilerRegMoveNil) unit]
    [(CompilerRegMoveCons move rest)
      (begin
        (match move
          [(CompilerRegMove src dst _)
            (compiler-reg-copy-hints-add-move! hints parents src dst)])
        (compiler-reg-copy-hints-from-moves! hints parents (box-get rest)))]))

;; Build per-root copy hints from the move list, mapping each move endpoint to its
;; coalesce root. The first move pairing a root with a distinct neighbour wins.
(define (compiler-reg-function-copy-hints
  [moves : CompilerRegMoveList]
  [coalesce : CompilerRegCoalesceMap]
  [n : i64]) : (Array i64)
  (let
    [hints : (Array i64) (array.make-array i64 n)]
    [parents : (Array i64) (struct-get coalesce parents)]
    (begin
      (compiler-reg-fill-i64-array hints -1)
      (compiler-reg-copy-hints-from-moves! hints parents moves)
      hints)))

(define (compiler-reg-fixed-preferred-register
  [assignments : CompilerRegAssignmentTable]
  [active : CompilerRegActiveList]
  [preferences : (Array i64)]
  [interval-index : CompilerRegIntervalIndex]
  [var : i64]
  [start : i64]) : CompilerRegMaybeString
  (if (or (< var 0) (>= var (array.array-length preferences)))
    (CompilerRegNoString)
    (let
      [preferred : i64 (array.array-ref preferences var)]
      [ends : (Array i64) (struct-get interval-index ends)]
      (if (or
        (< preferred 0)
        (>= preferred (array.array-length ends))
        (> (array.array-ref ends preferred) start))
        (CompilerRegNoString)
        (match (compiler-reg-assignment-table-lookup assignments preferred)
          [(CompilerRegSomeLocation location)
            (match location
              [(CompilerRegRegister reg)
                (if (compiler-reg-active-register-conflicts-except?
                  active
                  reg
                  preferred)
                  (CompilerRegNoString)
                  (CompilerRegSomeString reg))]
              [_ (CompilerRegNoString)])]
          [(CompilerRegNoLocation) (CompilerRegNoString)])))))

(define (compiler-reg-assign-fixed-candidates
  [candidates : CompilerRegIntervalList]
  [regs : CompilerRegStringList]
  [active : CompilerRegActiveList]
  [assignments : CompilerRegAssignmentTable]
  [preferences : (Array i64)]
  [interval-index : CompilerRegIntervalIndex]) : CompilerRegAssignState
  (match candidates
    [(CompilerRegIntervalNil) (CompilerRegAssignState active assignments)]
    [(CompilerRegIntervalCons interval rest)
      (match interval
        [(CompilerRegInterval var start end)
          (let
            [expired : CompilerRegActiveList
              (compiler-reg-expire-active active start)]
            [preferred : CompilerRegMaybeString
              (compiler-reg-fixed-preferred-register
                assignments
                expired
                preferences
                interval-index
                var
                start)]
            (match preferred
              [(CompilerRegSomeString reg)
                (compiler-reg-assign-fixed-candidates
                  (box-get rest)
                  regs
                  (compiler-reg-active-insert
                    expired
                    (CompilerRegActive var end reg))
                  (compiler-reg-assignment-table-insert
                    assignments
                    var
                    (CompilerRegRegister reg))
                  preferences
                  interval-index)]
              [(CompilerRegNoString)
                (if (=
                  (compiler-reg-active-count expired)
                  (compiler-reg-string-list-count regs))
                  (compiler-reg-assign-fixed-candidates
                    (box-get rest)
                    regs
                    expired
                    assignments
                    preferences
                    interval-index)
                  (let
                    [reg : String
                      (compiler-reg-first-free-register regs expired)]
                    (compiler-reg-assign-fixed-candidates
                      (box-get rest)
                      regs
                      (compiler-reg-active-insert
                        expired
                        (CompilerRegActive var end reg))
                      (compiler-reg-assignment-table-insert
                        assignments
                        var
                        (CompilerRegRegister reg))
                      preferences
                      interval-index)))]))])]))

;; Call points (#perf/correctness): the primary integer pool admits only
;; callee-saved registers, so a value live across a call keeps its home safely.
;; The scalar caller-saved extension consults a stricter backend clobber set.
;; The XMM/float
;; pool, however, uses CALLER-saved registers (the backend has no callee-saved
;; XMM save/restore), which a call clobbers — so a FLOAT value live across a call
;; must NOT be register-homed. We compute the set of instruction points that hold
;; a call (using the same 2-per-instruction numbering as the live intervals) and
;; mark any float-typed value whose interval strictly spans a call point
;; ineligible. Integers are unaffected here (their primary pool is call-safe).
(defenum CompilerRegCallScan
  (CompilerRegCallScan i64 CompilerLiveI64Set))

(define (compiler-reg-call-points-seq
  [instrs : CompilerIrInstrSeq]
  [point : i64]
  [set : CompilerLiveI64Set]) : CompilerRegCallScan
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [p : i64 point]
    [out : CompilerLiveI64Set set]
    (begin
      (while (< index count)
        (begin
          (set!
            out
            (match (array.array-ref slots index)
              [(IrInstrCall _ _ _ _) (compiler-live-set-insert out p)]
              [(IrInstrCallIndirect _ _ _ _) (compiler-live-set-insert out p)]
              [(IrInstrCallIndirectC _ _ _ _) (compiler-live-set-insert out p)]
              [(IrInstrCallCAbiStoreResult payload-box)
                (match (box-get payload-box)
                  [(CompilerIrInstrCallCAbiStoreResultPayload _ _ _ _)
                    (compiler-live-set-insert out p)])]
              [(IrInstrCallIndirectCAbiStoreResult payload-box)
                (match (box-get payload-box)
                  [(CompilerIrInstrCallIndirectCAbiStoreResultPayload _ _ _ _)
                    (compiler-live-set-insert out p)])]
              [(IrInstrTailCall _ _ _) (compiler-live-set-insert out p)]
              [(IrInstrTailCallIndirect _ _ _) (compiler-live-set-insert out p)]
              [_ out]))
          (set! p (+ p 2))
          (set! index (+ index 1))))
      (CompilerRegCallScan p out))))

(define (compiler-reg-call-points-blocks
  [blocks : CompilerIrBlockList]
  [point : i64]
  [set : CompilerLiveI64Set]) : CompilerRegCallScan
  (match blocks
    [(IrBlockNil) (CompilerRegCallScan point set)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (match (compiler-reg-call-points-seq instrs point set)
            [(CompilerRegCallScan p2 s2)
              (compiler-reg-call-points-blocks (box-get rest) p2 s2)])])]
    [(IrBlockArray seq)
      (compiler-reg-call-points-blocks
        (compiler-ir-block-seq-to-list seq)
        point
        set)]))

(define (compiler-reg-call-points [func : CompilerIrFunction]) : CompilerLiveI64Set
  (match func
    [(IrFunction _ _ _ _ blocks)
      (match (compiler-reg-call-points-blocks
        blocks
        0
        (compiler-live-set-empty))
        [(CompilerRegCallScan _ set) set])]))

(define (compiler-reg-backend-clobber-binop? [op : CompilerIrBinOp]) : bool
  (match op
    [(IrBinDiv) true]
    [(IrBinMod) true]
    [(IrBinSafeDiv) true]
    [(IrBinSafeMod) true]
    [(IrBinShl) true]
    [(IrBinShr) true]
    [_ false]))

(define (compiler-reg-backend-caller-clobber-instr? [instr : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrCall _ _ _ _) true]
    [(IrInstrCallIndirect _ _ _ _) true]
    [(IrInstrCallIndirectC _ _ _ _) true]
    [(IrInstrCallCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallCAbiStoreResultPayload _ _ _ _) true])]
    [(IrInstrCallIndirectCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallIndirectCAbiStoreResultPayload _ _ _ _) true])]
    [(IrInstrTailCall _ _ _) true]
    [(IrInstrTailCallIndirect _ _ _) true]
    [(IrInstrSyscall _ _) true]
    [(IrInstrBoundsCheck _ _ _) true]
    [(IrInstrCpuId _ _ _ _) true]
    [(IrInstrXgetbv _ _) true]
    [(IrInstrPack _ _ _) true]
    [(IrInstrBinOp _ op _ _ _) (compiler-reg-backend-clobber-binop? op)]
    [_ false]))

(define (compiler-reg-backend-caller-clobber-seq? [instrs : CompilerIrInstrSeq]) : bool
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (< index count) (not found))
        (begin
          (set!
            found
            (compiler-reg-backend-caller-clobber-instr?
              (array.array-ref slots index)))
          (set! index (+ index 1))))
      found)))

(define (compiler-reg-backend-caller-clobber-blocks?
  [blocks : CompilerIrBlockList]) : bool
  (match blocks
    [(IrBlockNil) false]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (if (compiler-reg-backend-caller-clobber-seq? instrs)
            true
            (compiler-reg-backend-caller-clobber-blocks? (box-get rest)))])]
    [(IrBlockArray seq)
      (compiler-reg-backend-caller-clobber-blocks?
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-reg-backend-caller-clobber? [func : CompilerIrFunction]) : bool
  (match func
    [(IrFunction _ _ _ _ blocks)
      (compiler-reg-backend-caller-clobber-blocks? blocks)]))

;; Backend caller-clobber points include ordinary calls plus non-call IR that
;; emits caller-clobbering machine instructions or helper calls. The zero-call
;; caller-saved pass rejects any interval spanning one of these points.
(define (compiler-reg-backend-caller-clobber-points-seq
  [instrs : CompilerIrInstrSeq]
  [point : i64]
  [set : CompilerLiveI64Set]) : CompilerRegCallScan
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [p : i64 point]
    [out : CompilerLiveI64Set set]
    (begin
      (while (< index count)
        (begin
          (if (compiler-reg-backend-caller-clobber-instr?
            (array.array-ref slots index))
            (set! out (compiler-live-set-insert out p))
            unit)
          (set! p (+ p 2))
          (set! index (+ index 1))))
      (CompilerRegCallScan p out))))

(define (compiler-reg-backend-caller-clobber-points-blocks
  [blocks : CompilerIrBlockList]
  [point : i64]
  [set : CompilerLiveI64Set]) : CompilerRegCallScan
  (match blocks
    [(IrBlockNil) (CompilerRegCallScan point set)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (match (compiler-reg-backend-caller-clobber-points-seq
            instrs
            point
            set)
            [(CompilerRegCallScan p2 s2)
              (compiler-reg-backend-caller-clobber-points-blocks
                (box-get rest)
                p2
                s2)])])]
    [(IrBlockArray seq)
      (compiler-reg-backend-caller-clobber-points-blocks
        (compiler-ir-block-seq-to-list seq)
        point
        set)]))

(define (compiler-reg-backend-caller-clobber-points [func : CompilerIrFunction]) : CompilerLiveI64Set
  (match func
    [(IrFunction _ _ _ _ blocks)
      (match (compiler-reg-backend-caller-clobber-points-blocks
        blocks
        0
        (compiler-live-set-empty))
        [(CompilerRegCallScan _ set) set])]))

;; Per-register clobber model (15c). The merged caller-clobber set above is too
;; coarse for the greedy: it treats a div/shift exactly like a call (all
;; caller-saved unavailable across it). But idiv clobbers only rax:rdx, and a variable shift only rcx, so a value CAN cross a
;; div in %r9/%rcx and a shift in %r9/%rdx. These per-kind point sets let the
;; greedy forbid only the registers an op actually clobbers.
;;   kind 0 = call-like (all caller-saved)   kind 1 = idiv   kind 2 = shift
(define (compiler-reg-clobber-binop-div? [op : CompilerIrBinOp]) : bool
  (match op
    [(IrBinDiv) true]
    [(IrBinMod) true]
    [(IrBinSafeDiv) true]
    [(IrBinSafeMod) true]
    [_ false]))

(define (compiler-reg-clobber-binop-shift? [op : CompilerIrBinOp]) : bool
  (match op
    [(IrBinShl) true]
    [(IrBinShr) true]
    [_ false]))

(define (compiler-reg-clobber-instr-kind?
  [instr : CompilerIrInstr]
  [kind : i64]) : bool
  (match instr
    [(IrInstrBinOp _ op _ _ _)
      (if (= kind 1)
        (compiler-reg-clobber-binop-div? op)
        (if (= kind 2)
          (compiler-reg-clobber-binop-shift? op)
          false))]
    [_
      (if (= kind 0)
        (compiler-reg-backend-caller-clobber-instr? instr)
        false)]))

(define (compiler-reg-clobber-kind-points-seq
  [instrs : CompilerIrInstrSeq]
  [point : i64]
  [set : CompilerLiveI64Set]
  [kind : i64]) : CompilerRegCallScan
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [p : i64 point]
    [out : CompilerLiveI64Set set]
    (begin
      (while (< index count)
        (begin
          (if (compiler-reg-clobber-instr-kind?
            (array.array-ref slots index)
            kind)
            (set! out (compiler-live-set-insert out p))
            unit)
          (set! p (+ p 2))
          (set! index (+ index 1))))
      (CompilerRegCallScan p out))))

(define (compiler-reg-clobber-kind-points-blocks
  [blocks : CompilerIrBlockList]
  [point : i64]
  [set : CompilerLiveI64Set]
  [kind : i64]) : CompilerRegCallScan
  (match blocks
    [(IrBlockNil) (CompilerRegCallScan point set)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (match (compiler-reg-clobber-kind-points-seq instrs point set kind)
            [(CompilerRegCallScan p2 s2)
              (compiler-reg-clobber-kind-points-blocks
                (box-get rest)
                p2
                s2
                kind)])])]
    [(IrBlockArray seq)
      (compiler-reg-clobber-kind-points-blocks
        (compiler-ir-block-seq-to-list seq)
        point
        set
        kind)]))

(define (compiler-reg-clobber-kind-points
  [func : CompilerIrFunction]
  [kind : i64]) : CompilerLiveI64Set
  (match func
    [(IrFunction _ _ _ _ blocks)
      (match (compiler-reg-clobber-kind-points-blocks
        blocks
        0
        (compiler-live-set-empty)
        kind)
        [(CompilerRegCallScan _ set) set])]))

(define (compiler-reg-call-word-in-range?
  [bits : i64]
  [var-base : i64]
  [start : i64]
  [end : i64]) : bool
  (if (= bits 0)
    false
    (let
      [i : i64 (compiler-reg-low-bit-index bits)]
      [c : i64 (+ var-base i)]
      (if (if (< start c)
        (< c end)
        false)
        true
        (compiler-reg-call-word-in-range?
          (bit-and bits (- bits 1))
          var-base
          start
          end)))))

(cfg
  (any regalloc-census test)
  (define (compiler-reg-call-word-count-in-range
    [bits : i64]
    [var-base : i64]
    [start : i64]
    [end : i64]) : i64
    (if (= bits 0)
      0
      (let
        [i : i64 (compiler-reg-low-bit-index bits)]
        [c : i64 (+ var-base i)]
        [rest : i64
          (compiler-reg-call-word-count-in-range
            (bit-and bits (- bits 1))
            var-base
            start
            end)]
        (if (if (< start c)
          (< c end)
          false)
          (+ 1 rest)
          rest)))))

(define (compiler-reg-call-set-in-range-words?
  [set : CompilerLiveI64Set]
  [start : i64]
  [end : i64]
  [word-index : i64]) : bool
  (if (>= word-index (compiler-live-set-word-count set))
    false
    (if (compiler-reg-call-word-in-range?
      (compiler-live-set-word-at set word-index)
      (* word-index (compiler-live-set-word-bits))
      start
      end)
      true
      (compiler-reg-call-set-in-range-words? set start end (+ word-index 1)))))

(define (compiler-reg-call-set-in-range?
  [set : CompilerLiveI64Set]
  [start : i64]
  [end : i64]) : bool
  (compiler-reg-call-set-in-range-words? set start end 0))

(define (compiler-reg-call-word-count-in-range-model
  [bits : i64]
  [var-base : i64]
  [start : i64]
  [end : i64]) : i64
  (if (= bits 0)
    0
    (let
      [i : i64 (compiler-reg-low-bit-index bits)]
      [c : i64 (+ var-base i)]
      [rest : i64
        (compiler-reg-call-word-count-in-range-model
          (bit-and bits (- bits 1))
          var-base
          start
          end)]
      (if (if (< start c)
        (< c end)
        false)
        (+ 1 rest)
        rest))))

(define (compiler-reg-call-set-count-in-range-model-words
  [set : CompilerLiveI64Set]
  [start : i64]
  [end : i64]
  [word-index : i64]) : i64
  (if (>= word-index (compiler-live-set-word-count set))
    0
    (+
      (compiler-reg-call-word-count-in-range-model
        (compiler-live-set-word-at set word-index)
        (* word-index (compiler-live-set-word-bits))
        start
        end)
      (compiler-reg-call-set-count-in-range-model-words
        set
        start
        end
        (+ word-index 1)))))

(define (compiler-reg-call-set-count-in-range-model
  [set : CompilerLiveI64Set]
  [start : i64]
  [end : i64]) : i64
  (compiler-reg-call-set-count-in-range-model-words set start end 0))

(define (compiler-reg-direct-call-points-seq
  [instrs : CompilerIrInstrSeq]
  [point : i64]
  [set : CompilerLiveI64Set]) : CompilerRegCallScan
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [p : i64 point]
    [out : CompilerLiveI64Set set]
    (begin
      (while (< index count)
        (begin
          (set!
            out
            (match (array.array-ref slots index)
              [(IrInstrCall _ _ _ _) (compiler-live-set-insert out p)]
              [_ out]))
          (set! p (+ p 2))
          (set! index (+ index 1))))
      (CompilerRegCallScan p out))))

(define (compiler-reg-direct-call-points-blocks
  [blocks : CompilerIrBlockList]
  [point : i64]
  [set : CompilerLiveI64Set]) : CompilerRegCallScan
  (match blocks
    [(IrBlockNil) (CompilerRegCallScan point set)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (match (compiler-reg-direct-call-points-seq instrs point set)
            [(CompilerRegCallScan p2 s2)
              (compiler-reg-direct-call-points-blocks (box-get rest) p2 s2)])])]
    [(IrBlockArray seq)
      (compiler-reg-direct-call-points-blocks
        (compiler-ir-block-seq-to-list seq)
        point
        set)]))

(define (compiler-reg-direct-call-points [func : CompilerIrFunction]) : CompilerLiveI64Set
  (match func
    [(IrFunction _ _ _ _ blocks)
      (match (compiler-reg-direct-call-points-blocks
        blocks
        0
        (compiler-live-set-empty))
        [(CompilerRegCallScan _ set) set])]))

(define (compiler-reg-clobber-instr-vars [instr : CompilerIrInstr]) : CompilerLiveI64Set
  (compiler-live-set-union
    (compiler-live-instr-uses instr)
    (compiler-live-instr-defs instr)))

(define (compiler-reg-backend-caller-clobber-vars-seq
  [instrs : CompilerIrInstrSeq]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [out : CompilerLiveI64Set set]
    (begin
      (while (< index count)
        (begin
          (if (compiler-reg-backend-caller-clobber-instr?
            (array.array-ref slots index))
            (set!
              out
              (compiler-live-set-union
                out
                (compiler-reg-clobber-instr-vars (array.array-ref slots index))))
            unit)
          (set! index (+ index 1))))
      out)))

(define (compiler-reg-backend-caller-clobber-vars-blocks
  [blocks : CompilerIrBlockList]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match blocks
    [(IrBlockNil) set]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-reg-backend-caller-clobber-vars-blocks
            (box-get rest)
            (compiler-reg-backend-caller-clobber-vars-seq instrs set))])]
    [(IrBlockArray seq)
      (compiler-reg-backend-caller-clobber-vars-blocks
        (compiler-ir-block-seq-to-list seq)
        set)]))

(define (compiler-reg-backend-caller-clobber-vars [func : CompilerIrFunction]) : CompilerLiveI64Set
  (match func
    [(IrFunction _ _ _ _ blocks)
      (compiler-reg-backend-caller-clobber-vars-blocks
        blocks
        (compiler-live-set-empty))]))

(define (compiler-reg-loop-depth-max) : i64
  8)

(define (compiler-reg-loop-depth-weight [depth : i64]) : i64
  (cond
    [(<= depth 0) 1]
    [(= depth 1) 2]
    [(= depth 2) 4]
    [(= depth 3) 8]
    [else 16]))

(define (compiler-reg-loop-depth-block-ids
  [blocks : CompilerIrBlockList]
  [ids : hashmap.StringI64Map]
  [index : i64]) : hashmap.StringI64Map
  (match blocks
    [(IrBlockNil) ids]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _)
          (compiler-reg-loop-depth-block-ids
            (box-get rest)
            (hashmap.string-i64-map-put ids label index)
            (+ index 1))])]
    [(IrBlockArray seq)
      (compiler-reg-loop-depth-block-ids
        (compiler-ir-block-seq-to-list seq)
        ids
        index)]))

(define (compiler-reg-loop-depth-record-succ!
  [loop-ends : (Array i64)]
  [ids : hashmap.StringI64Map]
  [source-id : i64]
  [label : String]) : unit
  (match (hashmap.string-i64-map-get ids label)
    [(hashmap.StringI64MapFound target-id)
      (if (and (>= target-id 0) (<= target-id source-id))
        (if (> source-id (array.array-ref loop-ends target-id))
          (array.array-set! loop-ends target-id source-id)
          unit)
        unit)]
    [(hashmap.StringI64MapMissing) unit]))

(define (compiler-reg-loop-depth-record-succs!
  [loop-ends : (Array i64)]
  [ids : hashmap.StringI64Map]
  [source-id : i64]
  [succs : CompilerLiveLabelSet]) : unit
  (match succs
    [(CompilerLiveLabelNil) unit]
    [(CompilerLiveLabelCons label rest)
      (begin
        (compiler-reg-loop-depth-record-succ! loop-ends ids source-id label)
        (compiler-reg-loop-depth-record-succs!
          loop-ends
          ids
          source-id
          (box-get rest)))]))

(define (compiler-reg-loop-depth-record-blocks!
  [blocks : CompilerIrBlockList]
  [ids : hashmap.StringI64Map]
  [loop-ends : (Array i64)]
  [index : i64]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (begin
        (compiler-reg-loop-depth-record-succs!
          loop-ends
          ids
          index
          (compiler-live-block-successors block))
        (compiler-reg-loop-depth-record-blocks!
          (box-get rest)
          ids
          loop-ends
          (+ index 1)))]
    [(IrBlockArray seq)
      (compiler-reg-loop-depth-record-blocks!
        (compiler-ir-block-seq-to-list seq)
        ids
        loop-ends
        index)]))

(define (compiler-reg-loop-depth-bump-range!
  [depths : (Array i64)]
  [index : i64]
  [end : i64]) : unit
  (if (or (>= index (array.array-length depths)) (> index end))
    unit
    (begin
      (if (< (array.array-ref depths index) (compiler-reg-loop-depth-max))
        (array.array-set! depths index (+ (array.array-ref depths index) 1))
        unit)
      (compiler-reg-loop-depth-bump-range! depths (+ index 1) end))))

(define (compiler-reg-loop-depths-from-ends!
  [loop-ends : (Array i64)]
  [depths : (Array i64)]
  [index : i64]) : unit
  (if (>= index (array.array-length loop-ends))
    unit
    (begin
      (if (>= (array.array-ref loop-ends index) index)
        (compiler-reg-loop-depth-bump-range!
          depths
          index
          (array.array-ref loop-ends index))
        unit)
      (compiler-reg-loop-depths-from-ends! loop-ends depths (+ index 1)))))

(define (compiler-reg-function-loop-depths [blocks : CompilerIrBlockList]) : (Array
    i64)
  (let
    [count : i64 (compiler-ir-block-list-count blocks)]
    [depths : (Array i64) (array.make-array i64 count)]
    [loop-ends : (Array i64) (array.make-array i64 count)]
    [ids : hashmap.StringI64Map
      (compiler-reg-loop-depth-block-ids
        blocks
        (hashmap.string-i64-map-with-capacity
          (compiler-reg-bits-map-capacity count))
        0)]
    (begin
      (compiler-reg-fill-i64-array depths 0)
      (compiler-reg-fill-i64-array loop-ends (- 0 1))
      (compiler-reg-loop-depth-record-blocks! blocks ids loop-ends 0)
      (compiler-reg-loop-depths-from-ends! loop-ends depths 0)
      depths)))

(define (compiler-reg-ref-counts-add-word-weighted!
  [counts : (Array i64)]
  [bits : i64]
  [var-base : i64]
  [weight : i64]) : unit
  (if (= bits 0)
    unit
    (let
      [i : i64 (compiler-reg-low-bit-index bits)]
      [var : i64 (+ var-base i)]
      (begin
        (if (and (>= var 0) (< var (array.array-length counts)))
          (array.array-set! counts var (+ (array.array-ref counts var) weight))
          unit)
        (compiler-reg-ref-counts-add-word-weighted!
          counts
          (bit-and bits (- bits 1))
          var-base
          weight)))))

(define (compiler-reg-ref-counts-add-word!
  [counts : (Array i64)]
  [bits : i64]
  [var-base : i64]) : unit
  (compiler-reg-ref-counts-add-word-weighted! counts bits var-base 1))

(define (compiler-reg-ref-counts-add-set-words!
  [counts : (Array i64)]
  [set : CompilerLiveI64Set]
  [word-index : i64]) : unit
  (if (>= word-index (compiler-live-set-word-count set))
    unit
    (begin
      (compiler-reg-ref-counts-add-word!
        counts
        (compiler-live-set-word-at set word-index)
        (* word-index (compiler-live-set-word-bits)))
      (compiler-reg-ref-counts-add-set-words! counts set (+ word-index 1)))))

(define (compiler-reg-ref-counts-add-set!
  [counts : (Array i64)]
  [set : CompilerLiveI64Set]) : unit
  (compiler-reg-ref-counts-add-set-words! counts set 0))

(define (compiler-reg-ref-counts-add-set-words-weighted!
  [counts : (Array i64)]
  [set : CompilerLiveI64Set]
  [word-index : i64]
  [weight : i64]) : unit
  (if (>= word-index (compiler-live-set-word-count set))
    unit
    (begin
      (compiler-reg-ref-counts-add-word-weighted!
        counts
        (compiler-live-set-word-at set word-index)
        (* word-index (compiler-live-set-word-bits))
        weight)
      (compiler-reg-ref-counts-add-set-words-weighted!
        counts
        set
        (+ word-index 1)
        weight))))

(define (compiler-reg-ref-counts-add-set-weighted!
  [counts : (Array i64)]
  [set : CompilerLiveI64Set]
  [weight : i64]) : unit
  (compiler-reg-ref-counts-add-set-words-weighted! counts set 0 weight))

(define (compiler-reg-ref-counts-add-instr!
  [counts : (Array i64)]
  [instr : CompilerIrInstr]) : unit
  (begin
    (compiler-reg-ref-counts-add-set! counts (compiler-live-instr-uses instr))
    (compiler-reg-ref-counts-add-set! counts (compiler-live-instr-defs instr))))

(define (compiler-reg-ref-counts-add-instr-weighted!
  [counts : (Array i64)]
  [instr : CompilerIrInstr]
  [weight : i64]) : unit
  (begin
    (compiler-reg-ref-counts-add-set-weighted!
      counts
      (compiler-live-instr-uses instr)
      weight)
    (compiler-reg-ref-counts-add-set-weighted!
      counts
      (compiler-live-instr-defs instr)
      weight)))

(define (compiler-reg-ref-counts-seq!
  [counts : (Array i64)]
  [instrs : CompilerIrInstrSeq]) : unit
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    (while (< index count)
      (begin
        (compiler-reg-ref-counts-add-instr!
          counts
          (array.array-ref slots index))
        (set! index (+ index 1))))))

(define (compiler-reg-ref-counts-seq-weighted!
  [counts : (Array i64)]
  [instrs : CompilerIrInstrSeq]
  [weight : i64]) : unit
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    (while (< index count)
      (begin
        (compiler-reg-ref-counts-add-instr-weighted!
          counts
          (array.array-ref slots index)
          weight)
        (set! index (+ index 1))))))

(define (compiler-reg-ref-counts-blocks!
  [counts : (Array i64)]
  [blocks : CompilerIrBlockList]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (begin
        (match block
          [(IrBlock _ instrs) (compiler-reg-ref-counts-seq! counts instrs)])
        (compiler-reg-ref-counts-blocks! counts (box-get rest)))]
    [(IrBlockArray seq)
      (compiler-reg-ref-counts-blocks!
        counts
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-reg-ref-counts-blocks-weighted!
  [counts : (Array i64)]
  [blocks : CompilerIrBlockList]
  [depths : (Array i64)]
  [block-index : i64]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (begin
        (match block
          [(IrBlock _ instrs)
            (compiler-reg-ref-counts-seq-weighted!
              counts
              instrs
              (compiler-reg-loop-depth-weight
                (array.array-ref depths block-index)))])
        (compiler-reg-ref-counts-blocks-weighted!
          counts
          (box-get rest)
          depths
          (+ block-index 1)))]
    [(IrBlockArray seq)
      (compiler-reg-ref-counts-blocks-weighted!
        counts
        (compiler-ir-block-seq-to-list seq)
        depths
        block-index)]))

(define (compiler-reg-remat-value? [value : CompilerIrValue]) : bool
  (match value
    [(IrValueI64 _) true]
    [(IrValueBool _) true]
    [(IrValueChar _) true]
    [(IrValueF64 _) true]
    [(IrValueGlobalAddr _) true]
    [_ false]))

(define (compiler-reg-remat-mov-value?
  [value : CompilerIrValue]
  [allow-invariant-loads : bool]) : bool
  (match value
    [(IrValueGlobal _) allow-invariant-loads]
    [_ (compiler-reg-remat-value? value)]))

(define (compiler-reg-remat-gep?
  [base : CompilerIrValue]
  [offset : CompilerIrValue]) : bool
  (match base
    [(IrValueGlobalAddr _)
      (match offset
        [(IrValueI64 _) true]
        [_ false])]
    [_ false]))

(define (compiler-reg-remat-load?
  [src : CompilerIrValue]
  [allow-invariant-loads : bool]) : bool
  (if allow-invariant-loads
    (match src
      [(IrValueGlobalAddr _) true]
      [_ false])
    false))

(define (compiler-reg-remat-defn-with-invariant-loads?
  [instr : CompilerIrInstr]
  [allow-invariant-loads : bool]) : bool
  (match instr
    [(IrInstrMov _ value _)
      (compiler-reg-remat-mov-value? value allow-invariant-loads)]
    [(IrInstrGep _ base offset _) (compiler-reg-remat-gep? base offset)]
    [(IrInstrLoad _ src _) (compiler-reg-remat-load? src allow-invariant-loads)]
    [_ false]))

(define (compiler-reg-remat-defn? [instr : CompilerIrInstr]) : bool
  (compiler-reg-remat-defn-with-invariant-loads? instr false))

(define (compiler-reg-remat-candidates-add-instr
  [candidates : CompilerLiveI64Set]
  [instr : CompilerIrInstr]) : CompilerLiveI64Set
  (let
    [defs : CompilerLiveI64Set (compiler-live-instr-defs instr)]
    (if (compiler-reg-remat-defn? instr)
      (compiler-live-set-union candidates defs)
      candidates)))

(define (compiler-reg-remat-discount-weight [weight : i64]) : i64
  (/ weight 2))

;; A value the backend can RECOMPUTE in one instruction at each use: a static
;; address materialisation (`leaq label(%rip)`). Plain integer/bool/char constants
;; are deliberately EXCLUDED: the optimiser's constant propagation already inlines
;; them directly into their uses (so an optimised function never carries a constant
;; in a spillable vreg), making constant remat moot on real code; addresses cannot
;; always be folded into an instruction's immediate, so they are the case that
;; genuinely benefits. IrValueGlobal (a LOAD of a mutable global) and IrValueF64
;; (no scalar backend support) must never be rematerialised.
(define (compiler-reg-remat-recompute-value? [value : CompilerIrValue]) : bool
  (match value
    [(IrValueGlobalAddr _) true]
    [(IrValueFunction _) true]
    [(IrValueString _) true]
    [(IrValueBytes _) true]
    [_ false]))

(define (compiler-reg-remat-init-vals!
  [vals : (Array CompilerIrValue)]
  [vars : i64]) : unit
  (let
    [i : i64 0]
    (while (< i vars)
      (begin
        (array.array-set! vals i (IrValueUnit))
        (set! i (+ i 1))))))

;; Record var -> rematerialisable value for every var whose SOLE definition is a
;; Mov of a recomputable value.
(define (compiler-reg-collect-remat-seq!
  [instrs : CompilerIrInstrSeq]
  [def-counts : (Array i64)]
  [flags : (Array i64)]
  [vals : (Array CompilerIrValue)]) : unit
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    (while (< index count)
      (begin
        (match (array.array-ref slots index)
          [(IrInstrMov dst value _)
            ;; flags[dst]: 0 = not remat, 1 = remat, 2 = poisoned (address-taken,
            ;; must keep a real slot). A poisoned var never becomes remat.
            (if (if (if (compiler-reg-remat-recompute-value? value)
              (compiler-reg-sv-single-def? def-counts dst)
              false)
              (if (>= dst 0)
                (if (< dst (array.array-length flags))
                  (not (= (array.array-ref flags dst) 2))
                  false)
                false)
              false)
              (begin
                (array.array-set! flags dst 1)
                (array.array-set! vals dst value)
                unit)
              unit)]
          ;; Taking a var's address needs its real storage; poison it so it is
          ;; never rematerialised (its slot must hold the value).
          [(IrInstrAddrOf _ src)
            (if (if (>= src 0)
              (< src (array.array-length flags))
              false)
              (begin
                (array.array-set! flags src 2)
                unit)
              unit)]
          [_ unit])
        (set! index (+ index 1))))))

(define (compiler-reg-collect-remat-blocks!
  [blocks : CompilerIrBlockList]
  [def-counts : (Array i64)]
  [flags : (Array i64)]
  [vals : (Array CompilerIrValue)]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (begin
        (match block
          [(IrBlock _ instrs)
            (compiler-reg-collect-remat-seq! instrs def-counts flags vals)])
        (compiler-reg-collect-remat-blocks!
          (box-get rest)
          def-counts
          flags
          vals))]
    [(IrBlockArray seq)
      (compiler-reg-collect-remat-blocks!
        (compiler-ir-block-seq-to-list seq)
        def-counts
        flags
        vals)]))

;; Post-allocation rewrite: a singleton (non-coalesced) rematerialisable var that
;; the allocator chose to SPILL is converted to CompilerRegRemat instead -- its
;; uses recompute the value and its def store is dropped (backend). Coalesced
;; members are excluded so a class never half-remats. The already-reserved spill
;; slot is simply left unused.
(define (compiler-reg-rewrite-remat-assignments
  [assignments : CompilerRegAssignmentTable]
  [func : CompilerIrFunction]
  [coalesce : CompilerRegCoalesceMap]
  [shadows : CompilerLiveI64Set]
  [vars : i64]) : CompilerRegAssignmentTable
  (let
    [def-counts : (Array i64) (compiler-reg-function-def-counts func)]
    [parents : (Array i64) (struct-get coalesce parents)]
    [merged-roots : CompilerLiveI64Set
      (compiler-reg-coalesce-merged-root-set coalesce)]
    [flags : (Array i64) (array.make-array i64 vars)]
    [vals : (Array CompilerIrValue) (array.make-array CompilerIrValue vars)]
    [v : i64 0]
    (begin
      (compiler-reg-fill-i64-array flags 0)
      (compiler-reg-remat-init-vals! vals vars)
      (match func
        [(IrFunction _ _ _ _ blocks)
          (compiler-reg-collect-remat-blocks!
            (compiler-ir-block-list-force-cons blocks)
            def-counts
            flags
            vals)])
      (while (< v vars)
        (begin
          ;; Skip vars the call-spanning saver shadows: those keep a real slot to
          ;; restore from around calls, so they must not lose it to remat.
          (if (if (< v (array.array-length flags))
            (if (= (array.array-ref flags v) 1)
              (if (compiler-live-set-contains? shadows v)
                false
                (not
                  (compiler-reg-coalesce-var-nonsingleton?
                    parents
                    merged-roots
                    v)))
              false)
            false)
            (match (compiler-reg-assignment-table-lookup assignments v)
              [(CompilerRegSomeLocation loc)
                (match loc
                  [(CompilerRegSpill _)
                    (begin
                      (compiler-reg-assignment-table-insert
                        assignments
                        v
                        (CompilerRegRemat (array.array-ref vals v)))
                      unit)]
                  [_ unit])]
              [(CompilerRegNoLocation) unit])
            unit)
          (set! v (+ v 1))))
      assignments)))

(define (compiler-reg-coalesce-var-nonsingleton?
  [parents : (Array i64)]
  [merged-roots : CompilerLiveI64Set]
  [var : i64]) : bool
  (if (or (< var 0) (>= var (array.array-length parents)))
    false
    (let
      [root : i64 (array.array-ref parents var)]
      [mapped : i64
        (if (and (>= root 0) (< root (array.array-length parents)))
          root
          var)]
      (compiler-live-set-contains? merged-roots mapped))))

(define (compiler-reg-remat-discount-single-def-spill-weights!
  [weights : (Array i64)]
  [def-status : (Array i64)]
  [coalesce : CompilerRegCoalesceMap]) : unit
  (let
    [parents : (Array i64) (struct-get coalesce parents)]
    [merged-roots : CompilerLiveI64Set
      (compiler-reg-coalesce-merged-root-set coalesce)]
    [var : i64 0]
    (while (< var (array.array-length weights))
      (begin
        (let
          [status : i64
            (if (< var (array.array-length def-status))
              (array.array-ref def-status var)
              0)]
          (if (and
            (= (bit-and status 1) 1)
            (= (/ status 2) 1)
            (not
              (compiler-reg-coalesce-var-nonsingleton? parents merged-roots var)))
            (array.array-set!
              weights
              var
              (compiler-reg-remat-discount-weight (array.array-ref weights var)))
            unit))
        (set! var (+ var 1))))))

(define (compiler-reg-remat-instr-mutates-memory? [instr : CompilerIrInstr]) : bool
  (match (compiler-ir-instr-effect instr)
    [(IrEffectMemoryWrite) true]
    [(IrEffectUnknown) true]
    [_ false]))

(define (compiler-reg-remat-instrs-mutates-memory?
  [instrs : CompilerIrInstrSeq]) : bool
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (< index count) (not found))
        (begin
          (set!
            found
            (compiler-reg-remat-instr-mutates-memory?
              (array.array-ref slots index)))
          (set! index (+ index 1))))
      found)))

(define (compiler-reg-remat-blocks-mutates-memory?
  [blocks : CompilerIrBlockList]) : bool
  (match blocks
    [(IrBlockNil) false]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (or
            (compiler-reg-remat-instrs-mutates-memory? instrs)
            (compiler-reg-remat-blocks-mutates-memory? (box-get rest)))])]
    [(IrBlockArray seq)
      (compiler-reg-remat-blocks-mutates-memory?
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-reg-remat-invariant-loads-ok? [func : CompilerIrFunction]) : bool
  (match func
    [(IrFunction _ _ _ _ blocks)
      (not (compiler-reg-remat-blocks-mutates-memory? blocks))]))

(define (compiler-reg-remat-status-candidate-add-instr!
  [def-status : (Array i64)]
  [instr : CompilerIrInstr]
  [allow-invariant-loads : bool]) : unit
  (match instr
    [(IrInstrMov dst value _)
      (if (and
        (compiler-reg-remat-mov-value? value allow-invariant-loads)
        (>= dst 0)
        (< dst (array.array-length def-status)))
        (array.array-set!
          def-status
          dst
          (bit-or (array.array-ref def-status dst) 1))
        unit)]
    [(IrInstrGep dst base offset _)
      (if (and
        (compiler-reg-remat-gep? base offset)
        (>= dst 0)
        (< dst (array.array-length def-status)))
        (array.array-set!
          def-status
          dst
          (bit-or (array.array-ref def-status dst) 1))
        unit)]
    [(IrInstrLoad dst src _)
      (if (and
        (compiler-reg-remat-load? src allow-invariant-loads)
        (>= dst 0)
        (< dst (array.array-length def-status)))
        (array.array-set!
          def-status
          dst
          (bit-or (array.array-ref def-status dst) 1))
        unit)]
    [_ unit]))

(define (compiler-reg-ref-counts-add-instr-weighted-remat!
  [counts : (Array i64)]
  [def-status : (Array i64)]
  [instr : CompilerIrInstr]
  [weight : i64]
  [allow-invariant-loads : bool]) : unit
  (let
    [uses : CompilerLiveI64Set (compiler-live-instr-uses instr)]
    [defs : CompilerLiveI64Set (compiler-live-instr-defs instr)]
    (begin
      (compiler-reg-ref-counts-add-set-weighted! counts uses weight)
      (compiler-reg-ref-counts-add-set-weighted! counts defs weight)
      (compiler-reg-ref-counts-add-set-weighted! def-status defs 2)
      (compiler-reg-remat-status-candidate-add-instr!
        def-status
        instr
        allow-invariant-loads))))

(define (compiler-reg-ref-counts-seq-weighted-remat!
  [counts : (Array i64)]
  [def-status : (Array i64)]
  [instrs : CompilerIrInstrSeq]
  [weight : i64]
  [allow-invariant-loads : bool]) : unit
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-reg-ref-counts-add-instr-weighted-remat!
            counts
            def-status
            (array.array-ref slots index)
            weight
            allow-invariant-loads)
          (set! index (+ index 1))))
      unit)))

(define (compiler-reg-ref-counts-blocks-weighted-remat!
  [counts : (Array i64)]
  [def-status : (Array i64)]
  [blocks : CompilerIrBlockList]
  [depths : (Array i64)]
  [block-index : i64]
  [allow-invariant-loads : bool]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (begin
        (match block
          [(IrBlock _ instrs)
            (compiler-reg-ref-counts-seq-weighted-remat!
              counts
              def-status
              instrs
              (compiler-reg-loop-depth-weight
                (array.array-ref depths block-index))
              allow-invariant-loads)])
        (compiler-reg-ref-counts-blocks-weighted-remat!
          counts
          def-status
          (box-get rest)
          depths
          (+ block-index 1)
          allow-invariant-loads))]
    [(IrBlockArray seq)
      (compiler-reg-ref-counts-blocks-weighted-remat!
        counts
        def-status
        (compiler-ir-block-seq-to-list seq)
        depths
        block-index
        allow-invariant-loads)]))

(define (compiler-reg-function-ref-counts [func : CompilerIrFunction]) : (Array
    i64)
  (match func
    [(IrFunction _ _ _ vars blocks)
      (let
        [counts : (Array i64) (array.make-array i64 vars)]
        (begin
          (compiler-reg-fill-i64-array counts 0)
          (compiler-reg-ref-counts-blocks! counts blocks)
          counts))]))

(define (compiler-reg-function-spill-weights [func : CompilerIrFunction]) : (Array
    i64)
  (match func
    [(IrFunction _ _ _ vars blocks)
      (let
        [counts : (Array i64) (array.make-array i64 vars)]
        [depths : (Array i64) (compiler-reg-function-loop-depths blocks)]
        (begin
          (compiler-reg-fill-i64-array counts 0)
          (compiler-reg-ref-counts-blocks-weighted! counts blocks depths 0)
          counts))]))

(define (compiler-reg-function-spill-weights-remat
  [func : CompilerIrFunction]
  [coalesce : CompilerRegCoalesceMap]) : (Array i64)
  (match func
    [(IrFunction _ _ _ vars blocks)
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

(define (compiler-reg-call-spanning-caller-saved-benefit?
  [ref-count : i64]
  [calls : i64]) : bool
  ;; Static gate for the first split caller-saved slice: register segments must
  ;; save more spilled-value memory traffic than the call-boundary materializing
  ;; moves add. Each normal call crossed costs one spill and one reload, plus a
  ;; small frame-overhead budget. This intentionally rejects marginal ranges.
  (> ref-count (+ (* 2 calls) 1)))

(define (compiler-reg-interval-index-has-segment-table?
  [index : CompilerRegIntervalIndex]) : bool
  (> (array.array-length (struct-get index segments)) 0))

(define (compiler-reg-interval-index-var-has-segments?
  [index : CompilerRegIntervalIndex]
  [var : i64]) : bool
  (let
    [segments : (Array CompilerRegIntervalList) (struct-get index segments)]
    (and
      (>= var 0)
      (< var (array.array-length segments))
      (not (compiler-reg-interval-list-empty? (array.array-ref segments var))))))

(define (compiler-reg-call-split-boundary-vars-blocks
  [blocks : CompilerLiveBlockList]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match blocks
    [(CompilerLiveBlockNil) set]
    [(CompilerLiveBlockCons block rest)
      (compiler-reg-call-split-boundary-vars-blocks
        (box-get rest)
        (compiler-live-set-union
          (compiler-live-set-union set (compiler-live-block-live-in block))
          (compiler-live-block-live-out block)))]))

(define (compiler-reg-call-split-boundary-vars [func : CompilerIrFunction]) : CompilerLiveI64Set
  (compiler-reg-call-split-boundary-vars-blocks
    (compiler-live-function-blocks (compiler-live-analyze-function func))
    (compiler-live-set-empty)))

(define (compiler-reg-edge-copy-list-reverse-onto
  [copies : CompilerRegEdgeCopyList]
  [acc : CompilerRegEdgeCopyList]) : CompilerRegEdgeCopyList
  (match copies
    [(CompilerRegEdgeCopyNil) acc]
    [(CompilerRegEdgeCopyCons copy rest)
      (compiler-reg-edge-copy-list-reverse-onto
        (box-get rest)
        (compiler-reg-edge-copy-cons copy acc))]))

(define (compiler-reg-edge-copy-list-count [copies : CompilerRegEdgeCopyList]) : i64
  (match copies
    [(CompilerRegEdgeCopyNil) 0]
    [(CompilerRegEdgeCopyCons _ rest)
      (+ 1 (compiler-reg-edge-copy-list-count (box-get rest)))]))

(define (compiler-reg-region-label-map-from
  [labels : CompilerRegStringList]
  [out : hashmap.StringI64Map]) : hashmap.StringI64Map
  (match labels
    [(CompilerRegStringNil) out]
    [(CompilerRegStringCons label rest)
      (compiler-reg-region-label-map-from
        (box-get rest)
        (hashmap.string-i64-map-put out label 1))]))

(define (compiler-reg-region-label-map [labels : CompilerRegStringList]) : hashmap.StringI64Map
  (compiler-reg-region-label-map-from
    labels
    (hashmap.string-i64-map-with-capacity
      (compiler-reg-bits-map-capacity (compiler-reg-string-list-count labels)))))

(define (compiler-reg-region-label?
  [region : hashmap.StringI64Map]
  [label : String]) : bool
  (match (hashmap.string-i64-map-get region label)
    [(hashmap.StringI64MapFound _) true]
    [(hashmap.StringI64MapMissing) false]))

(define (compiler-reg-edge-copy-live-block-label [block : CompilerLiveBlock]) : String
  (match block
    [(CompilerLiveBlock label _ _ _ _ _ _) label]))

(define (compiler-reg-edge-copy-increment-pred!
  [ids : hashmap.StringI64Map]
  [pred-counts : (Array i64)]
  [label : String]) : unit
  (match (hashmap.string-i64-map-get ids label)
    [(hashmap.StringI64MapFound index)
      (array.array-set!
        pred-counts
        index
        (+ (array.array-ref pred-counts index) 1))]
    [(hashmap.StringI64MapMissing) unit]))

(define (compiler-reg-edge-copy-count-preds-succs!
  [ids : hashmap.StringI64Map]
  [pred-counts : (Array i64)]
  [succs : CompilerLiveLabelSet]) : unit
  (match succs
    [(CompilerLiveLabelNil) unit]
    [(CompilerLiveLabelCons label rest)
      (begin
        (compiler-reg-edge-copy-increment-pred! ids pred-counts label)
        (compiler-reg-edge-copy-count-preds-succs!
          ids
          pred-counts
          (box-get rest)))]))

(define (compiler-reg-edge-copy-count-preds-blocks!
  [ids : hashmap.StringI64Map]
  [blocks : (Array CompilerLiveBlock)]
  [pred-counts : (Array i64)]
  [index : i64]) : unit
  (if (>= index (array.array-length blocks))
    unit
    (begin
      (compiler-reg-edge-copy-count-preds-succs!
        ids
        pred-counts
        (compiler-reg-live-block-succs (array.array-ref blocks index)))
      (compiler-reg-edge-copy-count-preds-blocks!
        ids
        blocks
        pred-counts
        (+ index 1)))))

(define (compiler-reg-edge-copy-pred-counts
  [ids : hashmap.StringI64Map]
  [blocks : (Array CompilerLiveBlock)]) : (Array i64)
  (let
    [pred-counts : (Array i64)
      (array.make-array i64 (array.array-length blocks))]
    (begin
      (compiler-reg-fill-i64-array pred-counts 0)
      (compiler-reg-edge-copy-count-preds-blocks! ids blocks pred-counts 0)
      pred-counts)))

(define (compiler-reg-edge-copy-refusal
  [from-label : String]
  [to-label : String]) : String
  (str_cat.str-cat
    "regalloc: edge copy from "
    from-label
    " to "
    to-label
    " needs critical-edge splitting"))

(define (compiler-reg-edge-copy-placement-for
  [from-label : String]
  [to-label : String]
  [from-succs : i64]
  [to-preds : i64]) : CompilerRegEdgeCopyPlacementResult
  (cond
    [(= from-succs 1)
      (CompilerRegEdgeCopyPlacementOk CompilerRegEdgeCopyPredEnd)]
    [(= to-preds 1)
      (CompilerRegEdgeCopyPlacementOk CompilerRegEdgeCopySuccEntry)]
    [else
      (CompilerRegEdgeCopyPlacementRefused
        (compiler-reg-edge-copy-refusal from-label to-label))]))

(define (compiler-reg-edge-copy-live-on-edge?
  [from-block : CompilerLiveBlock]
  [to-block : CompilerLiveBlock]
  [var : i64]) : bool
  (and
    (compiler-live-set-contains? (compiler-live-block-live-out from-block) var)
    (compiler-live-set-contains? (compiler-live-block-live-in to-block) var)))

(define (compiler-reg-edge-copy-boundary-one
  [ids : hashmap.StringI64Map]
  [blocks : (Array CompilerLiveBlock)]
  [pred-counts : (Array i64)]
  [region : hashmap.StringI64Map]
  [from-block : CompilerLiveBlock]
  [from-label : String]
  [from-inside : bool]
  [from-succs : i64]
  [stack-var : i64]
  [region-var : i64]
  [ty : AstType]
  [to-label : String]
  [acc : CompilerRegEdgeCopyList]) : CompilerRegEdgeCopyPlan
  (match (hashmap.string-i64-map-get ids to-label)
    [(hashmap.StringI64MapFound to-index)
      (let
        [to-block : CompilerLiveBlock (array.array-ref blocks to-index)]
        [to-inside : bool (compiler-reg-region-label? region to-label)]
        (if (or
          (= from-inside to-inside)
          (not
            (compiler-reg-edge-copy-live-on-edge? from-block to-block stack-var)))
          (CompilerRegEdgeCopyPlan acc)
          (match (compiler-reg-edge-copy-placement-for
            from-label
            to-label
            from-succs
            (array.array-ref pred-counts to-index))
            [(CompilerRegEdgeCopyPlacementOk placement)
              (if to-inside
                (CompilerRegEdgeCopyPlan
                  (compiler-reg-edge-copy-cons
                    (CompilerRegEdgeCopy
                      from-label
                      to-label
                      stack-var
                      region-var
                      ty
                      CompilerRegEdgeCopyIntoRegion
                      placement)
                    acc))
                (CompilerRegEdgeCopyPlan
                  (compiler-reg-edge-copy-cons
                    (CompilerRegEdgeCopy
                      from-label
                      to-label
                      region-var
                      stack-var
                      ty
                      CompilerRegEdgeCopyOutOfRegion
                      placement)
                    acc)))]
            [(CompilerRegEdgeCopyPlacementRefused message)
              (CompilerRegEdgeCopyRefused message)])))]
    [(hashmap.StringI64MapMissing)
      (CompilerRegEdgeCopyRefused
        (str_cat.str-cat
          "regalloc: edge copy target block not found: "
          to-label))]))

(define (compiler-reg-edge-copy-boundary-succs
  [ids : hashmap.StringI64Map]
  [blocks : (Array CompilerLiveBlock)]
  [pred-counts : (Array i64)]
  [region : hashmap.StringI64Map]
  [from-block : CompilerLiveBlock]
  [from-label : String]
  [from-inside : bool]
  [from-succs : i64]
  [stack-var : i64]
  [region-var : i64]
  [ty : AstType]
  [succs : CompilerLiveLabelSet]
  [acc : CompilerRegEdgeCopyList]) : CompilerRegEdgeCopyPlan
  (match succs
    [(CompilerLiveLabelNil) (CompilerRegEdgeCopyPlan acc)]
    [(CompilerLiveLabelCons to-label rest)
      (match (compiler-reg-edge-copy-boundary-one
        ids
        blocks
        pred-counts
        region
        from-block
        from-label
        from-inside
        from-succs
        stack-var
        region-var
        ty
        to-label
        acc)
        [(CompilerRegEdgeCopyPlan next)
          (compiler-reg-edge-copy-boundary-succs
            ids
            blocks
            pred-counts
            region
            from-block
            from-label
            from-inside
            from-succs
            stack-var
            region-var
            ty
            (box-get rest)
            next)]
        [(CompilerRegEdgeCopyRefused message)
          (CompilerRegEdgeCopyRefused message)])]))

(define (compiler-reg-edge-copy-boundary-blocks
  [ids : hashmap.StringI64Map]
  [blocks : (Array CompilerLiveBlock)]
  [pred-counts : (Array i64)]
  [region : hashmap.StringI64Map]
  [stack-var : i64]
  [region-var : i64]
  [ty : AstType]
  [index : i64]
  [acc : CompilerRegEdgeCopyList]) : CompilerRegEdgeCopyPlan
  (if (>= index (array.array-length blocks))
    (CompilerRegEdgeCopyPlan
      (compiler-reg-edge-copy-list-reverse-onto acc CompilerRegEdgeCopyNil))
    (let
      [block : CompilerLiveBlock (array.array-ref blocks index)]
      [label : String (compiler-reg-edge-copy-live-block-label block)]
      [succs : CompilerLiveLabelSet (compiler-reg-live-block-succs block)]
      (match (compiler-reg-edge-copy-boundary-succs
        ids
        blocks
        pred-counts
        region
        block
        label
        (compiler-reg-region-label? region label)
        (compiler-live-label-set-count succs)
        stack-var
        region-var
        ty
        succs
        acc)
        [(CompilerRegEdgeCopyPlan next)
          (compiler-reg-edge-copy-boundary-blocks
            ids
            blocks
            pred-counts
            region
            stack-var
            region-var
            ty
            (+ index 1)
            next)]
        [(CompilerRegEdgeCopyRefused message)
          (CompilerRegEdgeCopyRefused message)]))))

(define (compiler-reg-edge-copy-plan-for-region
  [func : CompilerIrFunction]
  [region-labels : CompilerRegStringList]
  [stack-var : i64]
  [region-var : i64]
  [ty : AstType]) : CompilerRegEdgeCopyPlan
  (match (compiler-live-analyze-function func)
    [(CompilerFunctionLiveness ids blocks)
      (let
        [pred-counts : (Array i64)
          (compiler-reg-edge-copy-pred-counts ids blocks)]
        (compiler-reg-edge-copy-boundary-blocks
          ids
          blocks
          pred-counts
          (compiler-reg-region-label-map region-labels)
          stack-var
          region-var
          ty
          0
          CompilerRegEdgeCopyNil))]))

(define (compiler-reg-edge-copy-instr [copy : CompilerRegEdgeCopy]) : CompilerIrInstr
  (match copy
    [(CompilerRegEdgeCopy _ _ src dst ty _ _)
      (IrInstrMov dst (IrValueVar src) ty)]))

(define (compiler-reg-edge-copy-target-label [copy : CompilerRegEdgeCopy]) : String
  (match copy
    [(CompilerRegEdgeCopy from-label to-label _ _ _ _ placement)
      (match placement
        [(CompilerRegEdgeCopyPredEnd) from-label]
        [(CompilerRegEdgeCopySuccEntry) to-label])]))

(define (compiler-reg-edge-copy-placement [copy : CompilerRegEdgeCopy]) : CompilerRegEdgeCopyPlacement
  (match copy
    [(CompilerRegEdgeCopy _ _ _ _ _ _ placement) placement]))

(define (compiler-reg-edge-copy-insert-before-last
  [instrs : CompilerIrInstrList]
  [copy-instr : CompilerIrInstr]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (compiler-ir-instr-cons copy-instr IrInstrNil)]
    [(IrInstrCons instr rest)
      (match (box-get rest)
        [(IrInstrNil)
          (compiler-ir-instr-cons
            copy-instr
            (compiler-ir-instr-cons instr IrInstrNil))]
        [_
          (compiler-ir-instr-cons
            instr
            (compiler-reg-edge-copy-insert-before-last
              (box-get rest)
              copy-instr))])]))

(define (compiler-reg-edge-copy-insert-after-phis
  [instrs : CompilerIrInstrList]
  [copy-instr : CompilerIrInstr]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) (compiler-ir-instr-cons copy-instr IrInstrNil)]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrPhi _ _ _)
          (compiler-ir-instr-cons
            instr
            (compiler-reg-edge-copy-insert-after-phis (box-get rest) copy-instr))]
        [_ (compiler-ir-instr-cons copy-instr instrs)])]))

(define (compiler-reg-edge-copy-insert-in-block
  [block : CompilerIrBlock]
  [copy : CompilerRegEdgeCopy]) : CompilerIrBlock
  (match block
    [(IrBlock label instrs)
      (let
        [copy-instr : CompilerIrInstr (compiler-reg-edge-copy-instr copy)]
        [items : CompilerIrInstrList (compiler-ir-instr-seq-to-list instrs)]
        [rewritten : CompilerIrInstrList
          (match (compiler-reg-edge-copy-placement copy)
            [(CompilerRegEdgeCopyPredEnd)
              (compiler-reg-edge-copy-insert-before-last items copy-instr)]
            [(CompilerRegEdgeCopySuccEntry)
              (compiler-reg-edge-copy-insert-after-phis items copy-instr)])]
        (IrBlock label (compiler-ir-instr-seq-from-list rewritten)))]))

(define (compiler-reg-edge-copy-insert-one
  [blocks : CompilerIrBlockList]
  [copy : CompilerRegEdgeCopy]) : CompilerRegEdgeCopyRewrite
  (match blocks
    [(IrBlockNil)
      (CompilerRegEdgeCopyRewriteRefused
        (str_cat.str-cat
          "regalloc: edge copy insertion block not found: "
          (compiler-reg-edge-copy-target-label copy)))]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label _)
          (if (string.string-eq
            label
            (compiler-reg-edge-copy-target-label copy))
            (CompilerRegEdgeCopyRewrite
              (compiler-ir-block-cons
                (compiler-reg-edge-copy-insert-in-block block copy)
                (box-get rest)))
            (match (compiler-reg-edge-copy-insert-one (box-get rest) copy)
              [(CompilerRegEdgeCopyRewrite tail)
                (CompilerRegEdgeCopyRewrite (compiler-ir-block-cons block tail))]
              [(CompilerRegEdgeCopyRewriteRefused message)
                (CompilerRegEdgeCopyRewriteRefused message)]))])]
    [(IrBlockArray seq)
      (compiler-reg-edge-copy-insert-one
        (compiler-ir-block-seq-to-list seq)
        copy)]))

(define (compiler-reg-edge-copy-apply
  [blocks : CompilerIrBlockList]
  [copies : CompilerRegEdgeCopyList]) : CompilerRegEdgeCopyRewrite
  (match copies
    [(CompilerRegEdgeCopyNil) (CompilerRegEdgeCopyRewrite blocks)]
    [(CompilerRegEdgeCopyCons copy rest)
      (match (compiler-reg-edge-copy-insert-one blocks copy)
        [(CompilerRegEdgeCopyRewrite rewritten)
          (compiler-reg-edge-copy-apply rewritten (box-get rest))]
        [(CompilerRegEdgeCopyRewriteRefused message)
          (CompilerRegEdgeCopyRewriteRefused message)])]))

(define (compiler-reg-loop-split-noop
  [blocks : CompilerIrBlockList]
  [vars : i64]) : CompilerRegCallSaveRewrite
  (CompilerRegCallSaveRewrite
    blocks
    vars
    vars
    CompilerRegAssignmentNil
    CompilerRegVarTypeNil))

(define (compiler-reg-loop-split-direction-present?
  [copies : CompilerRegEdgeCopyList]
  [want-into : bool]) : bool
  (match copies
    [(CompilerRegEdgeCopyNil) false]
    [(CompilerRegEdgeCopyCons copy rest)
      (match copy
        [(CompilerRegEdgeCopy _ _ _ _ _ direction _)
          (if (match direction
            [(CompilerRegEdgeCopyIntoRegion) want-into]
            [(CompilerRegEdgeCopyOutOfRegion) (not want-into)])
            true
            (compiler-reg-loop-split-direction-present?
              (box-get rest)
              want-into))])]))

(define (compiler-reg-loop-split-copies-bidirectional?
  [copies : CompilerRegEdgeCopyList]) : bool
  (and
    (compiler-reg-loop-split-direction-present? copies true)
    (compiler-reg-loop-split-direction-present? copies false)))

(define (compiler-reg-loop-split-instr-list-has-phi?
  [instrs : CompilerIrInstrList]) : bool
  (match instrs
    [(IrInstrNil) false]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrPhi _ _ _) true]
        [_ (compiler-reg-loop-split-instr-list-has-phi? (box-get rest))])]))

(define (compiler-reg-loop-split-instr-seq-has-phi?
  [instrs : CompilerIrInstrSeq]) : bool
  (compiler-reg-loop-split-instr-list-has-phi?
    (compiler-ir-instr-seq-to-list instrs)))

(define (compiler-reg-loop-split-instr-mentions-var?
  [instr : CompilerIrInstr]
  [var : i64]) : bool
  (or
    (compiler-live-set-contains? (compiler-live-instr-uses instr) var)
    (compiler-live-set-contains? (compiler-live-instr-defs instr) var)))

(define (compiler-reg-loop-split-mention-count-list
  [instrs : CompilerIrInstrList]
  [var : i64]) : i64
  (match instrs
    [(IrInstrNil) 0]
    [(IrInstrCons instr rest)
      (+
        (if (compiler-reg-loop-split-instr-mentions-var? instr var)
          1
          0)
        (compiler-reg-loop-split-mention-count-list (box-get rest) var))]))

(define (compiler-reg-loop-split-mention-count
  [instrs : CompilerIrInstrSeq]
  [var : i64]) : i64
  (compiler-reg-loop-split-mention-count-list
    (compiler-ir-instr-seq-to-list instrs)
    var))

(define (compiler-reg-loop-split-region-interval
  [region-var : i64]
  [start : i64]
  [end : i64]) : CompilerRegIntervalList
  (compiler-reg-interval-cons
    (CompilerRegInterval region-var start end)
    CompilerRegIntervalNil))

(define (compiler-reg-loop-split-var-overlaps-region?
  [intervals : CompilerRegIntervalIndex]
  [var : i64]
  [region-intervals : CompilerRegIntervalList]) : bool
  (let
    [segments : (Array CompilerRegIntervalList) (struct-get intervals segments)]
    [var-segments : CompilerRegIntervalList
      (if (or (< var 0) (>= var (array.array-length segments)))
        CompilerRegIntervalNil
        (array.array-ref segments var))]
    (if (not (compiler-reg-interval-list-empty? var-segments))
      (compiler-reg-interval-list-overlaps? var-segments region-intervals)
      (match (compiler-reg-interval-index-lookup intervals var)
        [(CompilerRegSomeInterval interval)
          (compiler-reg-interval-list-overlaps-one? region-intervals interval)]
        [(CompilerRegNoInterval) true]))))

(define (compiler-reg-loop-split-location-conflicts-region?
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalIndex]
  [region-intervals : CompilerRegIntervalList]
  [ignore-var : i64]
  [location : CompilerRegLocation]) : bool
  (match assignments
    [(CompilerRegAssignmentNil) false]
    [(CompilerRegAssignmentCons item rest)
      (match item
        [(CompilerRegAssignment assigned-var assigned-location)
          (if (or
            (= assigned-var ignore-var)
            (not (compiler-reg-location-eq? assigned-location location)))
            (compiler-reg-loop-split-location-conflicts-region?
              (box-get rest)
              intervals
              region-intervals
              ignore-var
              location)
            (if (compiler-reg-loop-split-var-overlaps-region?
              intervals
              assigned-var
              region-intervals)
              true
              (compiler-reg-loop-split-location-conflicts-region?
                (box-get rest)
                intervals
                region-intervals
                ignore-var
                location)))])]))

(define (compiler-reg-loop-split-first-register
  [regs : CompilerRegStringList]
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalIndex]
  [region-intervals : CompilerRegIntervalList]
  [ignore-var : i64]) : CompilerRegMaybeString
  (match regs
    [(CompilerRegStringNil) CompilerRegNoString]
    [(CompilerRegStringCons reg rest)
      (if (compiler-reg-loop-split-location-conflicts-region?
        assignments
        intervals
        region-intervals
        ignore-var
        (CompilerRegRegister reg))
        (compiler-reg-loop-split-first-register
          (box-get rest)
          assignments
          intervals
          region-intervals
          ignore-var)
        (CompilerRegSomeString reg))]))

(define (compiler-reg-loop-split-type-ok?
  [type-info : CompilerRegVarTypes]
  [group-vars : CompilerLiveI64Set]
  [var : i64]) : CompilerRegMaybeType
  (if (compiler-live-set-contains? group-vars var)
    CompilerRegNoType
    (match (compiler-reg-var-types-lookup type-info var)
      [(CompilerRegSomeType ty)
        (if (and
          (compiler-reg-register-eligible-type? ty)
          (not (compiler-reg-float-type? ty)))
          (CompilerRegSomeType ty)
          CompilerRegNoType)]
      [(CompilerRegNoType) CompilerRegNoType])))

(define (compiler-reg-loop-split-hot-benefit?
  [mentions : i64]
  [depth : i64]
  [copy-count : i64]) : bool
  (and
    (> depth 0)
    (> mentions 0)
    (> (* mentions (compiler-reg-loop-depth-weight depth)) copy-count)))

(define (compiler-reg-loop-split-succs-has-backedge?
  [ids : hashmap.StringI64Map]
  [source-index : i64]
  [succs : CompilerLiveLabelSet]) : bool
  (match succs
    [(CompilerLiveLabelNil) false]
    [(CompilerLiveLabelCons label rest)
      (match (hashmap.string-i64-map-get ids label)
        [(hashmap.StringI64MapFound target-index)
          (if (<= target-index source-index)
            true
            (compiler-reg-loop-split-succs-has-backedge?
              ids
              source-index
              (box-get rest)))]
        [(hashmap.StringI64MapMissing)
          (compiler-reg-loop-split-succs-has-backedge?
            ids
            source-index
            (box-get rest))])]))

(define (compiler-reg-loop-split-region-remap-blocks
  [blocks : CompilerIrBlockList]
  [region : hashmap.StringI64Map]
  [remap : (Array i64)]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) IrBlockNil]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (let
            [rewritten-block : CompilerIrBlock
              (if (compiler-reg-region-label? region label)
                (IrBlock
                  label
                  (compiler-ir-instr-seq-from-list
                    (compiler-reg-remap-instr-list
                      remap
                      (compiler-ir-instr-seq-to-list instrs))))
                block)]
            (compiler-ir-block-cons
              rewritten-block
              (compiler-reg-loop-split-region-remap-blocks
                (box-get rest)
                region
                remap)))])]
    [(IrBlockArray seq)
      (compiler-reg-loop-split-region-remap-blocks
        (compiler-ir-block-seq-to-list seq)
        region
        remap)]))

(define (compiler-reg-loop-split-try-var
  [func : CompilerIrFunction]
  [region-label : String]
  [block : CompilerLiveBlock]
  [instrs : CompilerIrInstrSeq]
  [region-start : i64]
  [region-end : i64]
  [depth : i64]
  [vars : i64]
  [var : i64]
  [type-info : CompilerRegVarTypes]
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalIndex]
  [group-vars : CompilerLiveI64Set]
  [parents : (Array i64)]
  [merged-roots : CompilerLiveI64Set]) : CompilerRegLoopSplitCandidate
  (if (and
    (compiler-live-set-contains? (compiler-live-block-live-in block) var)
    (compiler-live-set-contains? (compiler-live-block-live-out block) var)
    (not (compiler-live-set-contains? (compiler-live-block-defs block) var))
    (compiler-reg-interval-index-var-has-segments? intervals var)
    (not (compiler-reg-coalesce-var-nonsingleton? parents merged-roots var)))
    (match (compiler-reg-assignment-lookup assignments var)
      [(CompilerRegSomeLocation location)
        (match location
          [(CompilerRegSpill _)
            (match (compiler-reg-loop-split-type-ok? type-info group-vars var)
              [(CompilerRegSomeType ty)
                (let
                  [labels : CompilerRegStringList
                    (compiler-reg-string-cons region-label CompilerRegStringNil)]
                  [mentions : i64
                    (compiler-reg-loop-split-mention-count instrs var)]
                  [region-intervals : CompilerRegIntervalList
                    (compiler-reg-loop-split-region-interval
                      vars
                      region-start
                      region-end)]
                  (match (compiler-reg-edge-copy-plan-for-region
                    func
                    labels
                    var
                    vars
                    ty)
                    [(CompilerRegEdgeCopyPlan copies)
                      (let
                        [copy-count : i64
                          (compiler-reg-edge-copy-list-count copies)]
                        (if (and
                          (compiler-reg-loop-split-copies-bidirectional? copies)
                          (compiler-reg-loop-split-hot-benefit?
                            mentions
                            depth
                            copy-count))
                          (match (compiler-reg-loop-split-first-register
                            (compiler-reg-sysv-integer-registers)
                            assignments
                            intervals
                            region-intervals
                            var)
                            [(CompilerRegSomeString reg)
                              (CompilerRegLoopSplitCandidate
                                var
                                region-label
                                ty
                                reg
                                copies)]
                            [(CompilerRegNoString)
                              (CompilerRegLoopSplitNoCandidate)])
                          (CompilerRegLoopSplitNoCandidate)))]
                    [(CompilerRegEdgeCopyRefused _)
                      (CompilerRegLoopSplitNoCandidate)]))]
              [(CompilerRegNoType) (CompilerRegLoopSplitNoCandidate)])]
          [_ (CompilerRegLoopSplitNoCandidate)])]
      [(CompilerRegNoLocation) (CompilerRegLoopSplitNoCandidate)])
    (CompilerRegLoopSplitNoCandidate)))

(define (compiler-reg-loop-split-select-var
  [func : CompilerIrFunction]
  [region-label : String]
  [block : CompilerLiveBlock]
  [instrs : CompilerIrInstrSeq]
  [region-start : i64]
  [region-end : i64]
  [depth : i64]
  [vars : i64]
  [var : i64]
  [type-info : CompilerRegVarTypes]
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalIndex]
  [group-vars : CompilerLiveI64Set]
  [parents : (Array i64)]
  [merged-roots : CompilerLiveI64Set]) : CompilerRegLoopSplitCandidate
  (if (>= var vars)
    (CompilerRegLoopSplitNoCandidate)
    (match (compiler-reg-loop-split-try-var
      func
      region-label
      block
      instrs
      region-start
      region-end
      depth
      vars
      var
      type-info
      assignments
      intervals
      group-vars
      parents
      merged-roots)
      [(CompilerRegLoopSplitNoCandidate)
        (compiler-reg-loop-split-select-var
          func
          region-label
          block
          instrs
          region-start
          region-end
          depth
          vars
          (+ var 1)
          type-info
          assignments
          intervals
          group-vars
          parents
          merged-roots)]
      [(CompilerRegLoopSplitCandidate stack-var label ty reg copies)
        (CompilerRegLoopSplitCandidate stack-var label ty reg copies)])))

(define (compiler-reg-loop-split-select-blocks
  [func : CompilerIrFunction]
  [blocks : CompilerIrBlockList]
  [ids : hashmap.StringI64Map]
  [live-blocks : (Array CompilerLiveBlock)]
  [depths : (Array i64)]
  [point : i64]
  [block-index : i64]
  [vars : i64]
  [type-info : CompilerRegVarTypes]
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalIndex]
  [group-vars : CompilerLiveI64Set]
  [parents : (Array i64)]
  [merged-roots : CompilerLiveI64Set]) : CompilerRegLoopSplitCandidate
  (match blocks
    [(IrBlockNil) (CompilerRegLoopSplitNoCandidate)]
    [(IrBlockCons ir-block rest)
      (match ir-block
        [(IrBlock label instrs)
          (let
            [next-point : i64
              (+ point (* 2 (compiler-ir-instr-seq-count instrs)))]
            [depth : i64
              (if (< block-index (array.array-length depths))
                (array.array-ref depths block-index)
                0)]
            (if (and
              (< block-index (array.array-length live-blocks))
              (> depth 0)
              (not (compiler-reg-loop-split-instr-seq-has-phi? instrs))
              (compiler-reg-loop-split-succs-has-backedge?
                ids
                block-index
                (compiler-reg-live-block-succs
                  (array.array-ref live-blocks block-index))))
              (match (compiler-reg-loop-split-select-var
                func
                label
                (array.array-ref live-blocks block-index)
                instrs
                point
                next-point
                depth
                vars
                0
                type-info
                assignments
                intervals
                group-vars
                parents
                merged-roots)
                [(CompilerRegLoopSplitNoCandidate)
                  (compiler-reg-loop-split-select-blocks
                    func
                    (box-get rest)
                    ids
                    live-blocks
                    depths
                    next-point
                    (+ block-index 1)
                    vars
                    type-info
                    assignments
                    intervals
                    group-vars
                    parents
                    merged-roots)]
                [(CompilerRegLoopSplitCandidate stack-var region ty reg copies)
                  (CompilerRegLoopSplitCandidate stack-var region ty reg copies)])
              (compiler-reg-loop-split-select-blocks
                func
                (box-get rest)
                ids
                live-blocks
                depths
                next-point
                (+ block-index 1)
                vars
                type-info
                assignments
                intervals
                group-vars
                parents
                merged-roots)))])]
    [(IrBlockArray seq)
      (compiler-reg-loop-split-select-blocks
        func
        (compiler-ir-block-seq-to-list seq)
        ids
        live-blocks
        depths
        point
        block-index
        vars
        type-info
        assignments
        intervals
        group-vars
        parents
        merged-roots)]))

(define (compiler-reg-loop-split-apply-candidate
  [blocks : CompilerIrBlockList]
  [vars : i64]
  [stack-var : i64]
  [region-label : String]
  [ty : AstType]
  [reg : String]
  [copies : CompilerRegEdgeCopyList]) : CompilerRegCallSaveRewrite
  (let
    [remap : (Array i64) (compiler-reg-caller-save-remap vars)]
    [region-map : hashmap.StringI64Map
      (compiler-reg-region-label-map
        (compiler-reg-string-cons region-label CompilerRegStringNil))]
    (begin
      (array.array-set! remap stack-var vars)
      (match (compiler-reg-edge-copy-apply
        (compiler-reg-loop-split-region-remap-blocks blocks region-map remap)
        copies)
        [(CompilerRegEdgeCopyRewrite rewritten-blocks)
          (CompilerRegCallSaveRewrite
            rewritten-blocks
            vars
            (+ vars 1)
            (compiler-reg-assignment-cons
              (CompilerRegAssignment vars (CompilerRegRegister reg))
              CompilerRegAssignmentNil)
            (compiler-reg-var-type-cons
              (CompilerRegVarType vars ty)
              CompilerRegVarTypeNil))]
        [(CompilerRegEdgeCopyRewriteRefused _)
          (compiler-reg-loop-split-noop blocks vars)]))))

;; Multi-split: rescue EVERY profitable spilled loop-carried var, not just the
;; first. Each split rewrites the IR (region uses -> a new register-resident var
;; SV + edge copies at the region boundary) and merges SV's register assignment
;; into `plan`; the next pass recomputes liveness/intervals on the rewritten
;; blocks, so its conflict check (loop-split-first-register / location-conflicts-
;; region?) already sees every prior split's SV occupying its register across its
;; region and avoids it -- which is exactly what makes picking the FINAL (not
;; re-allocated) registers sound. The region remap also stops the same var being
;; re-selected for the same region, so it converges; fuel (the integer register
;; count) bounds it. With a single candidate this is bit-identical to the old
;; one-shot behaviour (merging additions with the empty tail is the identity).
(define (compiler-reg-loop-split-rewrite-one
  [func : CompilerIrFunction]
  [blocks : CompilerIrBlockList]
  [vars : i64]
  [type-info : CompilerRegVarTypes]
  [plan : CompilerRegPlan]) : CompilerRegCallSaveRewrite
  (if (not (compiler-reg-scalar-full-intervals? func))
    (compiler-reg-loop-split-noop blocks vars)
    (compiler-reg-loop-split-rewrite-fueled
      func
      blocks
      vars
      type-info
      plan
      (compiler-reg-sysv-integer-register-count))))

(define (compiler-reg-loop-split-rewrite-fueled
  [func : CompilerIrFunction]
  [blocks : CompilerIrBlockList]
  [vars : i64]
  [type-info : CompilerRegVarTypes]
  [plan : CompilerRegPlan]
  [fuel : i64]) : CompilerRegCallSaveRewrite
  (if (<= fuel 0)
    (compiler-reg-loop-split-noop blocks vars)
    (let
      [liveness : CompilerFunctionLiveness
        (compiler-live-analyze-function func)]
      [selection : CompilerRegIntervalSelection
        (compiler-reg-live-interval-selection func liveness)]
      [types : CompilerRegVarTypeList (compiler-reg-var-types-list type-info)]
      [assignments : CompilerRegAssignmentList
        (compiler-reg-plan-assignments plan)]
      [group-vars : CompilerLiveI64Set
        (compiler-reg-function-group-vars func types)]
      [depths : (Array i64) (compiler-reg-function-loop-depths blocks)]
      (match selection
        [(CompilerRegIntervalSelection _ intervals)
          (let
            [coalesce : CompilerRegCoalesceMap
              (compiler-reg-coalesce-map-build
                (compiler-reg-function-moves func false)
                intervals
                type-info
                group-vars
                vars
                (array.make-array i64 0))]
            [parents : (Array i64) (struct-get coalesce parents)]
            [merged-roots : CompilerLiveI64Set
              (compiler-reg-coalesce-merged-root-set coalesce)]
            (match liveness
              [(CompilerFunctionLiveness ids live-blocks)
                (match (compiler-reg-loop-split-select-blocks
                  func
                  blocks
                  ids
                  live-blocks
                  depths
                  0
                  0
                  vars
                  type-info
                  assignments
                  intervals
                  group-vars
                  parents
                  merged-roots)
                  [(CompilerRegLoopSplitNoCandidate)
                    (compiler-reg-loop-split-noop blocks vars)]
                  [(CompilerRegLoopSplitCandidate
                      stack-var
                      region-label
                      ty
                      reg
                      copies)
                    (let
                      [applied : CompilerRegCallSaveRewrite
                        (compiler-reg-loop-split-apply-candidate
                          blocks
                          vars
                          stack-var
                          region-label
                          ty
                          reg
                          copies)]
                      (match applied
                        [(CompilerRegCallSaveRewrite
                            new-blocks
                            _
                            new-vars
                            split-assignments
                            split-types)
                          (match func
                            [(IrFunction name params ret-ty _ _)
                              (let
                                [new-func : CompilerIrFunction
                                  (IrFunction
                                    name
                                    params
                                    ret-ty
                                    new-vars
                                    new-blocks)]
                                [new-plan : CompilerRegPlan
                                  (compiler-reg-plan-with-call-save-rewrite
                                    plan
                                    applied)]
                                [rest : CompilerRegCallSaveRewrite
                                  (compiler-reg-loop-split-rewrite-fueled
                                    new-func
                                    new-blocks
                                    new-vars
                                    type-info
                                    new-plan
                                    (- fuel 1))]
                                (match rest
                                  [(CompilerRegCallSaveRewrite
                                      final-blocks
                                      _
                                      final-vars
                                      rest-assignments
                                      rest-types)
                                    (CompilerRegCallSaveRewrite
                                      final-blocks
                                      vars
                                      final-vars
                                      (compiler-reg-assignment-list-merge
                                        split-assignments
                                        rest-assignments)
                                      (compiler-reg-var-type-list-merge
                                        split-types
                                        rest-types))]))])]))])]))]))))

(define (compiler-reg-loop-split-max-rounds) : i64
  (compiler-reg-sysv-integer-register-count))

(define (compiler-reg-loop-split-rewrite-rounds
  [func : CompilerIrFunction]
  [blocks : CompilerIrBlockList]
  [in-vars : i64]
  [current-vars : i64]
  [plan : CompilerRegPlan]
  [extra-assignments : CompilerRegAssignmentList]
  [extra-types : CompilerRegVarTypeList]
  [rounds-left : i64]) : CompilerRegCallSaveRewrite
  (if (<= rounds-left 0)
    (CompilerRegCallSaveRewrite
      blocks
      in-vars
      current-vars
      extra-assignments
      extra-types)
    (let
      [round-plan : CompilerRegPlan
        (compiler-reg-plan-with-call-save-rewrite
          plan
          (CompilerRegCallSaveRewrite
            blocks
            in-vars
            current-vars
            extra-assignments
            extra-types))]
      [round-type-info : CompilerRegVarTypes
        (compiler-reg-function-var-types func)]
      (match (compiler-reg-loop-split-rewrite-one
        func
        blocks
        current-vars
        round-type-info
        round-plan)
        [(CompilerRegCallSaveRewrite
            next-blocks
            _
            next-vars
            next-assignments
            next-types)
          (if (= next-vars current-vars)
            (CompilerRegCallSaveRewrite
              blocks
              in-vars
              current-vars
              extra-assignments
              extra-types)
            (match func
              [(IrFunction name params ret-ty _ _)
                (let
                  [merged-assignments : CompilerRegAssignmentList
                    (compiler-reg-assignment-list-merge
                      next-assignments
                      extra-assignments)]
                  [merged-types : CompilerRegVarTypeList
                    (compiler-reg-var-type-list-merge next-types extra-types)]
                  [next-func : CompilerIrFunction
                    (IrFunction name params ret-ty next-vars next-blocks)]
                  (compiler-reg-loop-split-rewrite-rounds
                    next-func
                    next-blocks
                    in-vars
                    next-vars
                    plan
                    merged-assignments
                    merged-types
                    (- rounds-left 1)))]))]))))

(define (compiler-reg-loop-split-rewrite-blocks
  [func : CompilerIrFunction]
  [blocks : CompilerIrBlockList]
  [vars : i64]
  [_type-info : CompilerRegVarTypes]
  [plan : CompilerRegPlan]) : CompilerRegCallSaveRewrite
  (compiler-reg-loop-split-rewrite-rounds
    func
    blocks
    vars
    vars
    plan
    CompilerRegAssignmentNil
    CompilerRegVarTypeNil
    (compiler-reg-loop-split-max-rounds)))

(define (compiler-reg-caller-saved-call-spanning-candidate?
  [assignments : CompilerRegAssignmentTable]
  [interval-index : CompilerRegIntervalIndex]
  [ref-counts : (Array i64)]
  [group-vars : CompilerLiveI64Set]
  [boundary-vars : CompilerLiveI64Set]
  [direct-call-points : CompilerLiveI64Set]
  [clobber-points : CompilerLiveI64Set]
  [clobber-vars : CompilerLiveI64Set]
  [require-segments : bool]
  [var : i64]
  [start : i64]
  [end : i64]) : bool
  (let
    [calls : i64
      (compiler-reg-call-set-count-in-range-model direct-call-points start end)]
    [clobbers : i64
      (compiler-reg-call-set-count-in-range-model clobber-points start end)]
    [ref-count : i64
      (if (and (>= var 0) (< var (array.array-length ref-counts)))
        (array.array-ref ref-counts var)
        0)]
    (and
      (> calls 0)
      (= calls clobbers)
      (compiler-reg-call-spanning-caller-saved-benefit? ref-count calls)
      (not (compiler-live-set-contains? group-vars var))
      (not (compiler-live-set-contains? boundary-vars var))
      (if require-segments
        (compiler-reg-interval-index-var-has-segments? interval-index var)
        true)
      (not (compiler-live-set-contains? clobber-vars var))
      (not
        (compiler-reg-assignment-table-location-conflicts?
          assignments
          interval-index
          var
          (- 0 1)
          (CompilerRegRegister "%r9")))
      (match (compiler-reg-assignment-table-lookup assignments var)
        [(CompilerRegSomeLocation location)
          (match location
            [(CompilerRegSpill _) true]
            [_ false])]
        [(CompilerRegNoLocation) false]))))

(define (compiler-reg-assign-caller-saved-call-spanning-candidates
  [candidates : CompilerRegIntervalList]
  [assignments : CompilerRegAssignmentTable]
  [interval-index : CompilerRegIntervalIndex]
  [ref-counts : (Array i64)]
  [group-vars : CompilerLiveI64Set]
  [boundary-vars : CompilerLiveI64Set]
  [direct-call-points : CompilerLiveI64Set]
  [clobber-points : CompilerLiveI64Set]
  [clobber-vars : CompilerLiveI64Set]
  [require-segments : bool]
  [shadows : CompilerLiveI64Set]) : CompilerRegCallSaveAssignState
  (match candidates
    [(CompilerRegIntervalNil)
      (CompilerRegCallSaveAssignState assignments shadows)]
    [(CompilerRegIntervalCons interval rest)
      (match interval
        [(CompilerRegInterval var start end)
          (if (compiler-reg-caller-saved-call-spanning-candidate?
            assignments
            interval-index
            ref-counts
            group-vars
            boundary-vars
            direct-call-points
            clobber-points
            clobber-vars
            require-segments
            var
            start
            end)
            (compiler-reg-assign-caller-saved-call-spanning-candidates
              (box-get rest)
              (compiler-reg-assignment-table-insert
                assignments
                var
                (CompilerRegRegister "%r9"))
              interval-index
              ref-counts
              group-vars
              boundary-vars
              direct-call-points
              clobber-points
              clobber-vars
              require-segments
              (compiler-live-set-insert shadows var))
            (compiler-reg-assign-caller-saved-call-spanning-candidates
              (box-get rest)
              assignments
              interval-index
              ref-counts
              group-vars
              boundary-vars
              direct-call-points
              clobber-points
              clobber-vars
              require-segments
              shadows))])]))

(define (compiler-reg-restore-call-split-spills-from
  [assignments : CompilerRegAssignmentTable]
  [splits : CompilerLiveI64Set]
  [index : i64]) : CompilerRegAssignmentTable
  (let
    [present : (Array i64) (struct-get assignments present)]
    (if (>= index (array.array-length present))
      assignments
      (begin
        (if (compiler-live-set-contains? splits index)
          (begin
            (compiler-reg-assignment-table-insert
              assignments
              index
              (CompilerRegSpill (compiler-reg-stack-slot-offset index)))
            unit)
          unit)
        (compiler-reg-restore-call-split-spills-from
          assignments
          splits
          (+ index 1))))))

(define (compiler-reg-restore-call-split-spills
  [assignments : CompilerRegAssignmentTable]
  [splits : CompilerLiveI64Set]) : CompilerRegAssignmentTable
  (compiler-reg-restore-call-split-spills-from assignments splits 0))

(define (compiler-reg-function-single-block? [func : CompilerIrFunction]) : bool
  (match func
    [(IrFunction _ _ _ _ blocks) (= (compiler-ir-block-list-count blocks) 1)]))

(define (compiler-reg-assign-caller-saved-call-spanning
  [func : CompilerIrFunction]
  [candidates : CompilerRegIntervalList]
  [assignments : CompilerRegAssignmentTable]
  [interval-index : CompilerRegIntervalIndex]
  [group-vars : CompilerLiveI64Set]) : CompilerRegCallSaveAssignState
  (let
    [single-block : bool (compiler-reg-function-single-block? func)]
    [has-segments : bool
      (compiler-reg-interval-index-has-segment-table? interval-index)]
    (if (or single-block has-segments)
      (match (compiler-reg-assign-caller-saved-call-spanning-candidates
        candidates
        assignments
        interval-index
        (compiler-reg-function-ref-counts func)
        group-vars
        (if single-block
          (compiler-live-set-empty)
          (compiler-reg-call-split-boundary-vars func))
        (compiler-reg-direct-call-points func)
        (compiler-reg-backend-caller-clobber-points func)
        (compiler-reg-backend-caller-clobber-vars func)
        (not single-block)
        (compiler-live-set-empty))
        [(CompilerRegCallSaveAssignState reserved split-vars)
          (CompilerRegCallSaveAssignState
            (compiler-reg-restore-call-split-spills reserved split-vars)
            split-vars)])
      (CompilerRegCallSaveAssignState assignments (compiler-live-set-empty)))))

(cfg
  (any regalloc-census test)
  (define (compiler-reg-call-set-count-in-range-words
    [set : CompilerLiveI64Set]
    [start : i64]
    [end : i64]
    [word-index : i64]) : i64
    (if (>= word-index (compiler-live-set-word-count set))
      0
      (+
        (compiler-reg-call-word-count-in-range
          (compiler-live-set-word-at set word-index)
          (* word-index (compiler-live-set-word-bits))
          start
          end)
        (compiler-reg-call-set-count-in-range-words
          set
          start
          end
          (+ word-index 1))))))

(cfg
  (any regalloc-census test)
  (define (compiler-reg-call-set-count-in-range
    [set : CompilerLiveI64Set]
    [start : i64]
    [end : i64]) : i64
    (compiler-reg-call-set-count-in-range-words set start end 0)))

(cfg
  (any regalloc-census test)
  (define (compiler-reg-call-span-census-empty) : CompilerRegCallSpanCensus
    (CompilerRegCallSpanCensus (array.make-array i64 12))))

(cfg
  (any regalloc-census test)
  (define (compiler-reg-call-span-outcome-register) : i64
    0))

(cfg
  (any regalloc-census test)
  (define (compiler-reg-call-span-outcome-spill) : i64
    1))

(cfg
  (any regalloc-census test)
  (define (compiler-reg-call-span-outcome-unassigned) : i64
    2))

(cfg
  (any regalloc-census test)
  (define (compiler-reg-call-span-bucket [calls : i64]) : i64
    (cond [(= calls 0) 0] [(= calls 1) 1] [(< calls 4) 2] [else 3])))

(cfg
  (any regalloc-census test)
  (define (compiler-reg-call-span-census-index [bucket : i64] [outcome : i64]) : i64
    (+ (* bucket 3) outcome)))

(cfg
  (any regalloc-census test)
  (define (compiler-reg-call-span-census-add!
    [census : CompilerRegCallSpanCensus]
    [calls : i64]
    [outcome : i64]) : unit
    (let
      [counts : (Array i64) (struct-get census counts)]
      [index : i64
        (compiler-reg-call-span-census-index
          (compiler-reg-call-span-bucket calls)
          outcome)]
      (array.array-set! counts index (+ (array.array-ref counts index) 1)))))

(cfg
  (any regalloc-census test)
  (define (compiler-reg-call-span-census-count
    [census : CompilerRegCallSpanCensus]
    [bucket : i64]
    [outcome : i64]) : i64
    (array.array-ref
      (struct-get census counts)
      (compiler-reg-call-span-census-index bucket outcome))))

(cfg
  (any regalloc-census test)
  (define (compiler-reg-call-span-assignment-outcome
    [assignments : CompilerRegAssignmentList]
    [split-vars : CompilerLiveI64Set]
    [var : i64]) : i64
    (if (compiler-live-set-contains? split-vars var)
      (compiler-reg-call-span-outcome-register)
      (match (compiler-reg-assignment-lookup assignments var)
        [(CompilerRegNoLocation) (compiler-reg-call-span-outcome-unassigned)]
        [(CompilerRegSomeLocation location)
          (match location
            [(CompilerRegSpill _) (compiler-reg-call-span-outcome-spill)]
            [_ (compiler-reg-call-span-outcome-register)])]))))

(cfg
  (any regalloc-census test)
  (define (compiler-reg-call-span-census-intervals!
    [census : CompilerRegCallSpanCensus]
    [intervals : CompilerRegIntervalList]
    [assignments : CompilerRegAssignmentList]
    [call-points : CompilerLiveI64Set]
    [split-vars : CompilerLiveI64Set]) : unit
    (match intervals
      [(CompilerRegIntervalNil) unit]
      [(CompilerRegIntervalCons interval rest)
        (match interval
          [(CompilerRegInterval var start end)
            (begin
              (compiler-reg-call-span-census-add!
                census
                (compiler-reg-call-set-count-in-range call-points start end)
                (compiler-reg-call-span-assignment-outcome
                  assignments
                  split-vars
                  var))
              (compiler-reg-call-span-census-intervals!
                census
                (box-get rest)
                assignments
                call-points
                split-vars))])])))

;; Caller-saved integer homes must clear this measured gate before they can be
;; enabled for call-spanning ranges: the register-home benefit must exceed
;; 2*calls_spanned memory ops (spill+reload per normal call) plus the spill-slot
;; and frame overhead. Split-selected originals count as register-covered even
;; though the canonical original var remains stack-homed across the call.
(cfg
  (any regalloc-census test)
  (define (compiler-reg-plan-call-span-census
    [func : CompilerIrFunction]
    [plan : CompilerRegPlan]) : CompilerRegCallSpanCensus
    (let
      [type-info : CompilerRegVarTypes (compiler-reg-function-var-types func)]
      [census : CompilerRegCallSpanCensus (compiler-reg-call-span-census-empty)]
      (begin
        (match plan
          [(CompilerRegPlan assignments ineligible intervals _ split-vars)
            (compiler-reg-call-span-census-intervals!
              census
              (compiler-reg-candidates intervals type-info ineligible false)
              assignments
              (compiler-reg-call-points func)
              split-vars)])
        census))))

(cfg
  (any regalloc-census test)
  (define (compiler-reg-call-span-census-merge-into!
    [dst : CompilerRegCallSpanCensus]
    [src : CompilerRegCallSpanCensus]) : unit
    (let
      [dst-counts : (Array i64) (struct-get dst counts)]
      [src-counts : (Array i64) (struct-get src counts)]
      [index : i64 0]
      (begin
        (while (< index (array.array-length dst-counts))
          (begin
            (array.array-set!
              dst-counts
              index
              (+
                (array.array-ref dst-counts index)
                (array.array-ref src-counts index)))
            (set! index (+ index 1))))
        unit))))

(cfg
  regalloc-census
  (define compiler-reg-call-span-census-total : CompilerRegCallSpanCensus
    (compiler-reg-call-span-census-empty)))

(cfg
  regalloc-census
  (define (compiler-reg-call-span-census-reset!) : unit
    (set!
      compiler-reg-call-span-census-total
      (compiler-reg-call-span-census-empty))))

(cfg
  regalloc-census
  (define (compiler-reg-call-span-census-record-plan!
    [func : CompilerIrFunction]
    [plan : CompilerRegPlan]) : unit
    (compiler-reg-call-span-census-merge-into!
      compiler-reg-call-span-census-total
      (compiler-reg-plan-call-span-census func plan))))

(cfg
  regalloc-census
  (define (compiler-reg-call-span-census-row [label : String] [bucket : i64]) : String
    (str_cat.str-cat
      "regalloc-call-span-census|"
      label
      "|"
      (string.int->string
        (compiler-reg-call-span-census-count
          compiler-reg-call-span-census-total
          bucket
          (compiler-reg-call-span-outcome-register)))
      "|"
      (string.int->string
        (compiler-reg-call-span-census-count
          compiler-reg-call-span-census-total
          bucket
          (compiler-reg-call-span-outcome-spill)))
      "|"
      (string.int->string
        (compiler-reg-call-span-census-count
          compiler-reg-call-span-census-total
          bucket
          (compiler-reg-call-span-outcome-unassigned)))
      "\n")))

(cfg
  regalloc-census
  (define (compiler-reg-call-span-census-print!) : unit
    (begin
      (io.print-error
        "regalloc-call-span-census|calls_spanned|register|spill|unassigned\n")
      (io.print-error (compiler-reg-call-span-census-row "0" 0))
      (io.print-error (compiler-reg-call-span-census-row "1" 1))
      (io.print-error (compiler-reg-call-span-census-row "2-3" 2))
      (io.print-error (compiler-reg-call-span-census-row "4+" 3)))))

;; ---- move census (cfg regalloc-census) ------------------------------------
;; Categorise every harvested IR move by why it survived as a reg-reg copy, to
;; see where the move flood actually comes from. Slots:
;;   0 harvested      total moves seen
;;   1 coalesced      src/dst share a coalesce root -> emitted as a self-move
;;   2 samevalue_unco un-coalesced but proven SAME VALUE (#2 should catch these;
;;                    leftovers are multi-def / class-check rejects)
;;   3 disjoint_unco  un-coalesced, DISTINCT value, but live SEGMENTS are
;;                    DISJOINT -> the two could share one register via sound
;;                    hole-filling, so copy-hint *should* fold the copy away
;;   4 interfere      un-coalesced, distinct value, segments overlap -> a real
;;                    simultaneous-liveness copy (needs a split, else irreducible)
(cfg
  regalloc-census
  (define compiler-reg-move-census-counts : (Array i64)
    (array.make-array i64 16)))

(cfg
  regalloc-census
  (define (compiler-reg-move-census-reset!) : unit
    (compiler-reg-fill-i64-array compiler-reg-move-census-counts 0)))

(cfg
  regalloc-census
  (define (compiler-reg-move-census-bump! [slot : i64]) : unit
    (if (if (< slot 0)
      true
      (>= slot (array.array-length compiler-reg-move-census-counts)))
      unit
      (array.array-set!
        compiler-reg-move-census-counts
        slot
        (+ (array.array-ref compiler-reg-move-census-counts slot) 1)))))

(cfg
  regalloc-census
  (define (compiler-reg-move-census-find [parents : (Array i64)] [v : i64]) : i64
    (if (if (< v 0)
      true
      (>= v (array.array-length parents)))
      v
      (let
        [p : i64 (array.array-ref parents v)]
        (if (= p v)
          v
          (compiler-reg-move-census-find parents p))))))

(cfg
  regalloc-census
  (define (compiler-reg-move-census-record!
    [moves : CompilerRegMoveList]
    [parents : (Array i64)]
    [interval-index : CompilerRegIntervalIndex]
    [eff-index : CompilerRegIntervalIndex]
    [types : CompilerRegVarTypes]
    [group-vars : CompilerLiveI64Set]
    [sv-parents : (Array i64)]) : unit
    (match moves
      [(CompilerRegMoveNil) unit]
      [(CompilerRegMoveCons move rest)
        (begin
          (match move
            [(CompilerRegMove src dst _)
              (begin
                (compiler-reg-move-census-bump! 0)
                (let
                  [rs : i64 (compiler-reg-move-census-find parents src)]
                  [rd : i64 (compiler-reg-move-census-find parents dst)]
                  (if (= rs rd)
                    (compiler-reg-move-census-bump! 1)
                    (if (compiler-reg-same-value-class? sv-parents src dst)
                      (compiler-reg-move-census-bump! 2)
                      (if (not
                        (compiler-reg-vars-interfere-segmented-index?
                          interval-index
                          src
                          dst))
                        ;; vars are segment-disjoint. Split by whether their
                        ;; coalesce ROOTS also stay disjoint (slot 5: a root-level
                        ;; copy-hint COULD place them in one register) or the merged
                        ;; classes now conflict (slot 6). Slot 7: of the rootfree
                        ;; ones, the PAIR is coalesce-vars-compatible? -> the merge
                        ;; was blocked by the all-pairs class check, not the pair.
                        (begin
                          (compiler-reg-move-census-bump! 3)
                          (if (compiler-reg-vars-interfere-segmented-index?
                            eff-index
                            rs
                            rd)
                            (compiler-reg-move-census-bump! 6)
                            (begin
                              (compiler-reg-move-census-bump! 5)
                              (if (compiler-reg-coalesce-vars-compatible?
                                interval-index
                                types
                                group-vars
                                src
                                dst
                                false
                                sv-parents)
                                (compiler-reg-move-census-bump! 7)
                                (if (if (compiler-live-set-contains?
                                  group-vars
                                  src)
                                  true
                                  (compiler-live-set-contains? group-vars dst))
                                  (compiler-reg-move-census-bump! 8)
                                  (if (not
                                    (compiler-reg-compatible-types?
                                      types
                                      src
                                      dst))
                                    (compiler-reg-move-census-bump! 9)
                                    (compiler-reg-move-census-bump! 10)))))))
                        (compiler-reg-move-census-bump! 4))))))])
          (compiler-reg-move-census-record!
            (box-get rest)
            parents
            interval-index
            eff-index
            types
            group-vars
            sv-parents))])))

(cfg
  regalloc-census
  (define (compiler-reg-move-census-print!) : unit
    (begin
      (io.print-error
        "regalloc-move-census|harvested|coalesced|samevalue_unco|disjoint_unco|interfere|disjoint_rootfree|disjoint_rootblocked|rootfree_paircompat|rootfree_group|rootfree_typemismatch|rootfree_other\n")
      (io.print-error
        (str_cat.str-cat
          "regalloc-move-census|"
          (string.int->string
            (array.array-ref compiler-reg-move-census-counts 0))
          "|"
          (string.int->string
            (array.array-ref compiler-reg-move-census-counts 1))
          "|"
          (string.int->string
            (array.array-ref compiler-reg-move-census-counts 2))
          "|"
          (string.int->string
            (array.array-ref compiler-reg-move-census-counts 3))
          "|"
          (string.int->string
            (array.array-ref compiler-reg-move-census-counts 4))
          "|"
          (string.int->string
            (array.array-ref compiler-reg-move-census-counts 5))
          "|"
          (string.int->string
            (array.array-ref compiler-reg-move-census-counts 6))
          "|"
          (string.int->string
            (array.array-ref compiler-reg-move-census-counts 7))
          "|"
          (string.int->string
            (array.array-ref compiler-reg-move-census-counts 8))
          "|"
          (string.int->string
            (array.array-ref compiler-reg-move-census-counts 9))
          "|"
          (string.int->string
            (array.array-ref compiler-reg-move-census-counts 10))
          "\n")))))

(define (compiler-reg-var-float? [type-info : CompilerRegVarTypes] [var : i64]) : bool
  (match (compiler-reg-var-types-lookup type-info var)
    [(CompilerRegSomeType ty) (compiler-reg-float-type? ty)]
    [(CompilerRegNoType) false]))

(define (compiler-reg-mark-float-spanning
  [intervals : CompilerRegIntervalList]
  [type-info : CompilerRegVarTypes]
  [call-points : CompilerLiveI64Set]
  [ineligible : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match intervals
    [(CompilerRegIntervalNil) ineligible]
    [(CompilerRegIntervalCons interval rest)
      (match interval
        [(CompilerRegInterval var start end)
          (compiler-reg-mark-float-spanning
            (box-get rest)
            type-info
            call-points
            (if (if (compiler-reg-var-float? type-info var)
              (compiler-reg-call-set-in-range? call-points start end)
              false)
              (compiler-live-set-insert ineligible var)
              ineligible))])]))

;; #2386: the set of 2-word register-group vars in a function -- those defined by
;; IrInstrPack and those read by IrInstrWord (the group value being extracted),
;; closed over Mov/Phi copies. These vars need TWO general-purpose registers.
(define (compiler-reg-group-vars-instr
  [set : CompilerLiveI64Set]
  [instr : CompilerIrInstr]) : CompilerLiveI64Set
  (match instr
    [(IrInstrPack dst _ _) (compiler-live-set-insert set dst)]
    [(IrInstrWord _ src _ _)
      (match src
        [(IrValueVar v) (compiler-live-set-insert set v)]
        [_ set])]
    [_ set]))

(define (compiler-reg-group-vars-instrs
  [set : CompilerLiveI64Set]
  [instrs : CompilerIrInstrList]) : CompilerLiveI64Set
  (match instrs
    [(IrInstrNil) set]
    [(IrInstrCons instr rest)
      (compiler-reg-group-vars-instrs
        (compiler-reg-group-vars-instr set instr)
        (box-get rest))]))

(define (compiler-reg-group-vars-blocks
  [set : CompilerLiveI64Set]
  [blocks : CompilerIrBlockList]) : CompilerLiveI64Set
  (match blocks
    [(IrBlockNil) set]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-reg-group-vars-blocks
            (compiler-reg-group-vars-instrs
              set
              (compiler-ir-instr-seq-to-list instrs))
            (box-get rest))])]
    [(IrBlockArray seq)
      (compiler-reg-group-vars-blocks set (compiler-ir-block-seq-to-list seq))]))

;; #2386: a Phi merging group values, or a Mov copying one, must mark its dst (and
;; the other endpoints) as a group var too -- otherwise the merged value gets a
;; single register and word1 is dropped. Group-ness flows both ways across these
;; copies, so we close the seed set over them to a fixpoint below.
(define (compiler-reg-phi-inputs-any-in-set?
  [set : CompilerLiveI64Set]
  [inputs : CompilerIrPhiInputList]) : bool
  (match inputs
    [(IrPhiInputNil) false]
    [(IrPhiInputCons value _ rest)
      (match value
        [(IrValueVar v)
          (if (compiler-live-set-contains? set v)
            true
            (compiler-reg-phi-inputs-any-in-set? set (box-get rest)))]
        [_ (compiler-reg-phi-inputs-any-in-set? set (box-get rest))])]))

(define (compiler-reg-phi-inputs-insert-all
  [set : CompilerLiveI64Set]
  [inputs : CompilerIrPhiInputList]) : CompilerLiveI64Set
  (match inputs
    [(IrPhiInputNil) set]
    [(IrPhiInputCons value _ rest)
      (let
        [next : CompilerLiveI64Set
          (match value
            [(IrValueVar v) (compiler-live-set-insert set v)]
            [_ set])]
        (compiler-reg-phi-inputs-insert-all next (box-get rest)))]))

(define (compiler-reg-group-vars-propagate-instr
  [set : CompilerLiveI64Set]
  [instr : CompilerIrInstr]) : CompilerLiveI64Set
  (match instr
    [(IrInstrMov dst src _)
      (match src
        [(IrValueVar v)
          (if (or
            (compiler-live-set-contains? set dst)
            (compiler-live-set-contains? set v))
            (compiler-live-set-insert (compiler-live-set-insert set dst) v)
            set)]
        [_ set])]
    [(IrInstrPhi dst inputs _)
      (if (or
        (compiler-live-set-contains? set dst)
        (compiler-reg-phi-inputs-any-in-set? set inputs))
        (compiler-reg-phi-inputs-insert-all
          (compiler-live-set-insert set dst)
          inputs)
        set)]
    [_ set]))

;; #2386: iterate the instruction SEQ in place by index. The fixpoint re-runs the
;; propagation pass once per round; materializing each block's instr-seq to a list
;; every round (compiler-ir-instr-seq-to-list) allocated O(rounds * instrs) of
;; transient list nodes per function, which on the largest functions overflowed
;; the per-function scratch arena into a second chunk -- enough to expose the
;; arena rewind's latent reuse hazard and corrupt later emission. Reading the seq
;; by index allocates nothing.
(define (compiler-reg-group-vars-propagate-seq
  [set : CompilerLiveI64Set]
  [instrs : CompilerIrInstrSeq]
  [index : i64]) : CompilerLiveI64Set
  (if (>= index (compiler-ir-instr-seq-count instrs))
    set
    (compiler-reg-group-vars-propagate-seq
      (compiler-reg-group-vars-propagate-instr
        set
        (compiler-ir-instr-seq-ref instrs index))
      instrs
      (+ index 1))))

(define (compiler-reg-group-vars-propagate-blocks
  [set : CompilerLiveI64Set]
  [blocks : CompilerIrBlockList]) : CompilerLiveI64Set
  (match blocks
    [(IrBlockNil) set]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-reg-group-vars-propagate-blocks
            (compiler-reg-group-vars-propagate-seq set instrs 0)
            (box-get rest))])]
    [(IrBlockArray seq)
      (compiler-reg-group-vars-propagate-blocks
        set
        (compiler-ir-block-seq-to-list seq))]))

(define (compiler-reg-group-vars-fixpoint
  [set : CompilerLiveI64Set]
  [blocks : CompilerIrBlockList]) : CompilerLiveI64Set
  (let
    [next : CompilerLiveI64Set
      (compiler-reg-group-vars-propagate-blocks set blocks)]
    (if (= (compiler-live-set-count next) (compiler-live-set-count set))
      next
      (compiler-reg-group-vars-fixpoint next blocks))))

;; #2386: program-wide aggregate-type-name -> machine-word count map, mirroring
;; CompilerBackendProgramIndex.group-word-counts. The backend sets this once
;; before per-function planning (compiler-reg-set-group-counts!). It lets the
;; register allocator recognise a 2-word register-group value by its TYPE even
;; when this function contains no IrInstrPack that produced it -- e.g. the result
;; of a call returning a group, a group-typed parameter, or a Mov of a group.
;; Without it such a var is mis-classified as an 8-byte handle (see
;; compiler-reg-handle-type?), gets a single GP register, and emit-group-store
;; writes both words into that one register -- silently dropping word1. (At -O2
;; these tiny callees are inlined so the standalone pattern rarely survives; at
;; -O1 it is pervasive.) Self-tests never set it, so the map stays empty and the
;; structural Pack/Word seeding below is unaffected.
(define compiler-reg-group-counts : hashmap.StringI64Map
  (hashmap.string-i64-map-with-capacity 8))
(define compiler-reg-group-class-masks : hashmap.StringI64Map
  (hashmap.string-i64-map-with-capacity 8))

(define (compiler-reg-set-group-counts! [counts : hashmap.StringI64Map]) : unit
  (set! compiler-reg-group-counts counts))

(define (compiler-reg-set-group-class-masks! [masks : hashmap.StringI64Map]) : unit
  (set! compiler-reg-group-class-masks masks))

;; The aggregate type name a value carries (mirror of
;; compiler-backend-aggregate-type-name); empty for non-aggregate types.
(define (compiler-reg-aggregate-type-name [ty : AstType]) : String
  (match ty
    [(AstTyStruct name) (intern-str name)]
    [(AstTyStructArgs name _) (intern-str name)]
    [(AstTyEnum name) (intern-str name)]
    [(AstTyEnumArgs name _) (intern-str name)]
    [(AstTyRegion _ inner)
      (compiler-reg-aggregate-type-name (ty-node-get inner))]
    [_ ""]))

;; True when a var's type is a >=2-word register-group per the program map.
(define (compiler-reg-type-register-group? [ty : AstType]) : bool
  (let
    [name : String (compiler-reg-aggregate-type-name ty)]
    (if (string.string-eq name "")
      false
      (match (hashmap.string-i64-map-get compiler-reg-group-counts name)
        [(hashmap.StringI64MapFound count) (> count 1)]
        [(hashmap.StringI64MapMissing) false]))))

(define (compiler-reg-type-register-group-has-sse? [ty : AstType]) : bool
  (let
    [name : String (compiler-reg-aggregate-type-name ty)]
    (if (string.string-eq name "")
      false
      (match (hashmap.string-i64-map-get compiler-reg-group-class-masks name)
        [(hashmap.StringI64MapFound mask) (> mask 0)]
        [(hashmap.StringI64MapMissing) false]))))

(define (compiler-reg-var-register-group-has-sse?
  [types : CompilerRegVarTypes]
  [var : i64]) : bool
  (match (compiler-reg-var-types-lookup types var)
    [(CompilerRegSomeType ty) (compiler-reg-type-register-group-has-sse? ty)]
    [(CompilerRegNoType) false]))

;; Seed every var whose TYPE is a 2-word register-group (the type-based group
;; vars the structural Pack/Word scan misses).
(define (compiler-reg-group-vars-from-types
  [types : CompilerRegVarTypeList]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match types
    [(CompilerRegVarTypeNil) set]
    [(CompilerRegVarTypeCons item rest)
      (match item
        [(CompilerRegVarType var ty)
          (compiler-reg-group-vars-from-types
            (box-get rest)
            (if (compiler-reg-type-register-group? ty)
              (compiler-live-set-insert set var)
              set))])]))

(define (compiler-reg-function-group-vars
  [func : CompilerIrFunction]
  [types : CompilerRegVarTypeList]) : CompilerLiveI64Set
  (match func
    [(IrFunction _ _ _ _ blocks)
      (compiler-reg-group-vars-fixpoint
        (compiler-reg-group-vars-from-types
          types
          (compiler-reg-group-vars-blocks (compiler-live-set-empty) blocks))
        blocks)]))

;; #2386: whether a function has ANY register-group var (structural OR type-based,
;; e.g. a group-typed call result/param). The backend uses this to reserve the
;; word1 stack region for stack-homed groups; a type-based group var the structural
;; scan misses would otherwise write word1 below the allocated frame (clobbered by
;; an intervening call's pushed return address / callee frame).
(define (compiler-reg-function-has-group-vars?
  [func : CompilerIrFunction]
  [types : CompilerRegVarTypeList]) : bool
  (> (compiler-live-set-count (compiler-reg-function-group-vars func types)) 0))

;; #3489 (PR2): LLVM-style coalescing-by-rename. LLVM removes a copy by renaming
;; the two virtual registers into ONE, so a coalesced class is a single value the
;; allocator places atomically. Here: collapse each coalesce class to its root
;; var. `compiler-reg-merged-root-index` returns an interval index in which ONLY
;; the root carries an interval -- the merged [min-start, max-end] over all class
;; members -- and every non-root member is dropped (start = -1, excluded from the
;; candidate list). The allocator then sees one indivisible candidate per class:
;; one placement, one eviction unit, one register, across every pass and pool.
;; Members inherit the root's location via compiler-reg-expand-class-assignments.
;; The merged coarse interval drives interference; a singleton var's coarse
;; interval already equals its live range, so non-coalesced values are unaffected.
(define (compiler-reg-prepend-segments
  [src : CompilerRegIntervalList]
  [dst : CompilerRegIntervalList]) : CompilerRegIntervalList
  (match src
    [(CompilerRegIntervalNil) dst]
    [(CompilerRegIntervalCons s rest)
      (compiler-reg-interval-cons
        s
        (compiler-reg-prepend-segments (box-get rest) dst))]))

(define (compiler-reg-interval-list-insert-merged
  [segments : CompilerRegIntervalList]
  [var : i64]
  [start : i64]
  [end : i64]) : CompilerRegIntervalList
  (match segments
    [(CompilerRegIntervalNil)
      (compiler-reg-interval-cons
        (CompilerRegInterval var start end)
        CompilerRegIntervalNil)]
    [(CompilerRegIntervalCons head rest)
      (match head
        [(CompilerRegInterval _ head-start head-end)
          (cond
            [(< end head-start)
              (compiler-reg-interval-cons
                (CompilerRegInterval var start end)
                segments)]
            [(< head-end start)
              (compiler-reg-interval-cons
                head
                (compiler-reg-interval-list-insert-merged
                  (box-get rest)
                  var
                  start
                  end))]
            [else
              (compiler-reg-interval-list-insert-merged
                (box-get rest)
                var
                (if (< start head-start)
                  start
                  head-start)
                (if (> end head-end)
                  end
                  head-end))])])]))

(define (compiler-reg-union-segments
  [src : CompilerRegIntervalList]
  [root : i64]
  [dst : CompilerRegIntervalList]) : CompilerRegIntervalList
  (match src
    [(CompilerRegIntervalNil) dst]
    [(CompilerRegIntervalCons s rest)
      (match s
        [(CompilerRegInterval _ start end)
          (compiler-reg-union-segments
            (box-get rest)
            root
            (compiler-reg-interval-list-insert-merged dst root start end))])]))

(define (compiler-reg-merged-root-index
  [coalesce : CompilerRegCoalesceMap]
  [interval-index : CompilerRegIntervalIndex]) : CompilerRegIntervalIndex
  (let
    [orig-starts : (Array i64) (struct-get interval-index starts)]
    [orig-ends : (Array i64) (struct-get interval-index ends)]
    [orig-segs : (Array CompilerRegIntervalList)
      (struct-get interval-index segments)]
    [parents : (Array i64) (struct-get coalesce parents)]
    [n : i64 (array.array-length orig-starts)]
    [root-starts : (Array i64) (array.make-array i64 n)]
    [root-ends : (Array i64) (array.make-array i64 n)]
    [root-segs : (Array CompilerRegIntervalList)
      (array.make-array CompilerRegIntervalList n)]
    [v : i64 0]
    (begin
      (compiler-reg-fill-i64-array root-starts -1)
      (compiler-reg-fill-i64-array root-ends -1)
      ;; #3489 (PR4): make-array does NOT zero object slots to Nil, so every
      ;; root-segs entry MUST be initialised before the prepend accumulation --
      ;; otherwise the union list's tail is a garbage pointer and iterating it
      ;; later (interference check / call-spanning shadow) dereferences it.
      (while (< v n)
        (begin
          (array.array-set! root-segs v CompilerRegIntervalNil)
          (set! v (+ v 1))))
      (set! v 0)
      (while (< v n)
        (begin
          (if (>= (array.array-ref orig-starts v) 0)
            (let
              [r : i64
                (if (< v (array.array-length parents))
                  (array.array-ref parents v)
                  v)]
              [rr : i64
                (if (and (>= r 0) (< r n))
                  r
                  v)]
              (begin
                (if (or
                  (< (array.array-ref root-starts rr) 0)
                  (<
                    (array.array-ref orig-starts v)
                    (array.array-ref root-starts rr)))
                  (array.array-set!
                    root-starts
                    rr
                    (array.array-ref orig-starts v))
                  unit)
                (if (>
                  (array.array-ref orig-ends v)
                  (array.array-ref root-ends rr))
                  (array.array-set! root-ends rr (array.array-ref orig-ends v))
                  unit)
                ;; #3489 (PR4) + #3788: the root carries the UNION of its
                ;; members' segments. Normal coalescing only merges
                ;; non-interfering members, but same-value coalescing deliberately
                ;; admits overlapping members, so keep the root segment list
                ;; sorted and non-overlapping while preserving genuine holes.
                (array.array-set!
                  root-segs
                  rr
                  (compiler-reg-union-segments
                    (if (< v (array.array-length orig-segs))
                      (array.array-ref orig-segs v)
                      CompilerRegIntervalNil)
                    rr
                    (array.array-ref root-segs rr)))))
            unit)
          (set! v (+ v 1))))
      (CompilerRegIntervalIndex root-starts root-ends root-segs))))

;; Non-singleton coalesce roots are the only values whose segment holes are
;; intentionally widened by class merging, so only they may drive hole-aware
;; register reuse.
(define (compiler-reg-coalesce-merged-root-set-from
  [parents : (Array i64)]
  [index : i64]
  [out : CompilerLiveI64Set]) : CompilerLiveI64Set
  (if (>= index (array.array-length parents))
    out
    (let
      [root : i64 (array.array-ref parents index)]
      (compiler-reg-coalesce-merged-root-set-from
        parents
        (+ index 1)
        (if (and
          (>= root 0)
          (< root (array.array-length parents))
          (not (= root index)))
          (compiler-live-set-insert out root)
          out)))))

(define (compiler-reg-coalesce-merged-root-set
  [coalesce : CompilerRegCoalesceMap]) : CompilerLiveI64Set
  (compiler-reg-coalesce-merged-root-set-from
    (struct-get coalesce parents)
    0
    (compiler-live-set-empty)))

(define (compiler-reg-coalesce-root-set-from-vars-from
  [parents : (Array i64)]
  [source : CompilerLiveI64Set]
  [index : i64]
  [out : CompilerLiveI64Set]) : CompilerLiveI64Set
  (if (>= index (array.array-length parents))
    out
    (let
      [root : i64 (array.array-ref parents index)]
      [mapped : i64
        (if (and (>= root 0) (< root (array.array-length parents)))
          root
          index)]
      (compiler-reg-coalesce-root-set-from-vars-from
        parents
        source
        (+ index 1)
        (if (compiler-live-set-contains? source index)
          (compiler-live-set-insert out mapped)
          out)))))

(define (compiler-reg-coalesce-root-set-from-vars
  [coalesce : CompilerRegCoalesceMap]
  [source : CompilerLiveI64Set]) : CompilerLiveI64Set
  (let
    [parents : (Array i64) (struct-get coalesce parents)]
    (if (= (array.array-length parents) 0)
      source
      (compiler-reg-coalesce-root-set-from-vars-from
        parents
        source
        0
        (compiler-live-set-empty)))))

;; #3489 (PR2): expand a per-root assignment table to all original vars -- every
;; member of a coalesce class inherits its root's location (register or spill
;; slot). This realises the coalesce: the copy `member <- root` becomes
;; src-reg == dst-reg and is dropped at emission. A var whose root got no
;; location stays absent (spills by default).
(define (compiler-reg-expand-class-assignments
  [assignments : CompilerRegAssignmentTable]
  [coalesce : CompilerRegCoalesceMap]
  [orig-starts : (Array i64)]
  [vars : i64]) : CompilerRegAssignmentTable
  (let
    [parents : (Array i64) (struct-get coalesce parents)]
    [out : CompilerRegAssignmentTable (compiler-reg-assignment-table-make vars)]
    [v : i64 0]
    (begin
      (while (< v vars)
        (begin
          (if (and
            (< v (array.array-length orig-starts))
            (>= (array.array-ref orig-starts v) 0))
            (let
              [r : i64
                (if (< v (array.array-length parents))
                  (array.array-ref parents v)
                  v)]
              [rr : i64
                (if (and (>= r 0) (< r vars))
                  r
                  v)]
              (match (compiler-reg-assignment-table-lookup assignments rr)
                [(CompilerRegSomeLocation loc)
                  (begin
                    (compiler-reg-assignment-table-insert out v loc)
                    unit)]
                [(CompilerRegNoLocation) unit]))
            unit)
          (set! v (+ v 1))))
      out)))

;; #3489 (PR2): the spill-weight eviction scores a candidate by its use count,
;; but a merged class root carries only its OWN var's weight -- which can be the
;; least-used member of the class (e.g. a phi result used once), so the eviction
;; underweights a hot coalesced loop value and spills it (crc32's accumulator).
;; Give the root the MAX weight over its members: that captures the class's
;; hottest reference rate (enough to keep a hot loop value resident) without
;; SUM's over-weighting, which would evict hot singletons that share the loop
;; (the reps var in spmd_reduce).
(define (compiler-reg-merge-ref-counts
  [coalesce : CompilerRegCoalesceMap]
  [ref-counts : (Array i64)]
  [vars : i64]) : (Array i64)
  (let
    [parents : (Array i64) (struct-get coalesce parents)]
    [out : (Array i64) (array.make-array i64 vars)]
    [v : i64 0]
    (begin
      (compiler-reg-fill-i64-array out 0)
      (while (< v vars)
        (begin
          (if (< v (array.array-length ref-counts))
            (let
              [r : i64
                (if (< v (array.array-length parents))
                  (array.array-ref parents v)
                  v)]
              [rr : i64
                (if (and (>= r 0) (< r vars))
                  r
                  v)]
              [w : i64 (array.array-ref ref-counts v)]
              (if (> w (array.array-ref out rr))
                (array.array-set! out rr w)
                unit))
            unit)
          (set! v (+ v 1))))
      out)))

;; ============================================================================
;; LLVM-style per-vreg Greedy register allocator (RAGreedy). The single allocation
;; algorithm across the whole compiler: integer (all 8 registers, caller/callee-
;; saved with call-clobber as interference), SIMD/AVX integer (the 5 callee-saved),
;; and float->XMM (all caller-saved). For each register class one selectOrSplit
;; pass over the coalesced ROOTS:
;;   * spill-weight PRIORITY ORDER (remat-discounted ref-counts desc, var asc) --
;;     the LLVM enqueue priority;
;;   * a GLOBAL per-physreg interference union (LiveIntervalUnion): a register is
;;     free for a root iff the SOUND segmented-index test clears against EVERY var
;;     holding it (prepass picks + already-assigned roots);
;;   * CALL-CLOBBER as interference: a caller-saved register is unavailable to a
;;     value whose live range crosses a call (the regmask clobbers it);
;;   * COPY-HINT biasing: try the copy-neighbour's register first;
;;   * remat-aware spill-weight EVICTION + the RS_* stage machine: clear a register
;;     all of whose interferers are strictly lower weight, else (split-eligible)
;;     mark RS_Split for the region-split post-pass, else spill. Strict weight order
;;     => terminating. Group/pair roots are left UNASSIGNED (backend stack-homes
;;     them); the call-spanning save/restore rescue then runs over the integer
;;     result.
(define (compiler-reg-greedy-string-list-to-array
  [regs : CompilerRegStringList]
  [out : (Array String)]
  [i : i64]) : unit
  (match regs
    [(CompilerRegStringNil) unit]
    [(CompilerRegStringCons reg rest)
      (begin
        (if (< i (array.array-length out))
          (array.array-set! out i reg)
          unit)
        (compiler-reg-greedy-string-list-to-array (box-get rest) out (+ i 1)))]))

(define (compiler-reg-greedy-holds-reg?
  [assignments : CompilerRegAssignmentTable]
  [w : i64]
  [reg : String]) : bool
  (match (compiler-reg-assignment-table-lookup assignments w)
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegRegister r) (string.string-eq r reg)]
        [(CompilerRegRegisterPair a b)
          (or (string.string-eq a reg) (string.string-eq b reg))]
        [(CompilerRegSpill _) false]
        [(CompilerRegRemat _) false])]
    [(CompilerRegNoLocation) false]))

;; Max ref-count among vars holding `reg` that interfere with `var`; -1 if none.
(define (compiler-reg-greedy-interferer-max
  [assignments : CompilerRegAssignmentTable]
  [interval-index : CompilerRegIntervalIndex]
  [ref-counts : (Array i64)]
  [var : i64]
  [reg : String]
  [idx : i64]
  [n : i64]
  [acc : i64]) : i64
  (if (>= idx n)
    acc
    (compiler-reg-greedy-interferer-max
      assignments
      interval-index
      ref-counts
      var
      reg
      (+ idx 1)
      n
      (if (and
        (not (= idx var))
        (compiler-reg-greedy-holds-reg? assignments idx reg)
        (compiler-reg-vars-interfere-segmented-index? interval-index var idx))
        (let
          [w : i64
            (if (< idx (array.array-length ref-counts))
              (array.array-ref ref-counts idx)
              0)]
          (if (> w acc)
            w
            acc))
        acc))))

(define (compiler-reg-greedy-reg-free?
  [assignments : CompilerRegAssignmentTable]
  [interval-index : CompilerRegIntervalIndex]
  [ref-counts : (Array i64)]
  [var : i64]
  [reg : String]
  [n : i64]) : bool
  (=
    (compiler-reg-greedy-interferer-max
      assignments
      interval-index
      ref-counts
      var
      reg
      0
      n
      (- 0 1))
    (- 0 1)))

;; {rax,rdx}: the registers an idiv hard-clobbers (rax:rdx outputs). The INT_MIN/-1
;; overflow guard temps are no longer hardcoded to %r10/%r11 -- the guard scavenges
;; free registers (compiler-backend-div-overflow-guard-asm), avoiding any
;; div-spanning value via the live query, so a div-spanning var may now use
;; %r10/%r11. rax stays reserved.
(define (compiler-reg-greedy-div-clobber-registers) : CompilerRegStringList
  (compiler-reg-string-cons
    "%rax"
    (compiler-reg-string-cons "%rdx" CompilerRegStringNil)))

;; Caller-saved registers a div/shift-spanning (but NOT call-spanning) var may not
;; use: div-span -> {rax,rdx}, shift-span -> {rcx}, unioned. The call-span case is
;; handled separately by the start-idx skip, so it is not represented here.
(define (compiler-reg-greedy-forbidden-regs
  [spans-div : bool]
  [spans-shift : bool]) : CompilerRegStringList
  (let
    [div-part : CompilerRegStringList
      (if spans-div
        (compiler-reg-greedy-div-clobber-registers)
        CompilerRegStringNil)]
    (if spans-shift
      (compiler-reg-string-cons "%rcx" div-part)
      div-part)))

(define (compiler-reg-greedy-first-free
  [assignments : CompilerRegAssignmentTable]
  [interval-index : CompilerRegIntervalIndex]
  [ref-counts : (Array i64)]
  [var : i64]
  [reg-arr : (Array String)]
  [ridx : i64]
  [rcount : i64]
  [n : i64]
  [forbidden : CompilerRegStringList]) : String
  (if (>= ridx rcount)
    ""
    (let
      [reg : String (array.array-ref reg-arr ridx)]
      (if (and
        (not (compiler-reg-string-list-contains? forbidden reg))
        (compiler-reg-greedy-reg-free?
          assignments
          interval-index
          ref-counts
          var
          reg
          n))
        reg
        (compiler-reg-greedy-first-free
          assignments
          interval-index
          ref-counts
          var
          reg-arr
          (+ ridx 1)
          rcount
          n
          forbidden)))))

;; Copy-hint register: the reg held by the copy-neighbour, if it is in the pool
;; and free for `var`. Biases `var` onto its move-partner's register.
(define (compiler-reg-greedy-hint-free-reg
  [assignments : CompilerRegAssignmentTable]
  [interval-index : CompilerRegIntervalIndex]
  [ref-counts : (Array i64)]
  [copy-hints : (Array i64)]
  [regs : CompilerRegStringList]
  [var : i64]
  [n : i64]
  [forbidden : CompilerRegStringList]) : String
  (if (or (< var 0) (>= var (array.array-length copy-hints)))
    ""
    (let
      [nb : i64 (array.array-ref copy-hints var)]
      (if (< nb 0)
        ""
        (match (compiler-reg-assignment-table-lookup assignments nb)
          [(CompilerRegSomeLocation loc)
            (match loc
              [(CompilerRegRegister r)
                (if (and
                  (not (compiler-reg-string-list-contains? forbidden r))
                  (compiler-reg-string-list-contains? regs r)
                  (compiler-reg-greedy-reg-free?
                    assignments
                    interval-index
                    ref-counts
                    var
                    r
                    n))
                  r
                  "")]
              [(CompilerRegRegisterPair _ _) ""]
              [(CompilerRegSpill _) ""]
              [(CompilerRegRemat _) ""])]
          [(CompilerRegNoLocation) ""])))))

;; First pool register all of whose interferers are STRICTLY lower weight than
;; `weight` (so clearing it costs less than spilling `var`); "" if none.
(define (compiler-reg-greedy-first-evictable
  [assignments : CompilerRegAssignmentTable]
  [interval-index : CompilerRegIntervalIndex]
  [ref-counts : (Array i64)]
  [var : i64]
  [weight : i64]
  [reg-arr : (Array String)]
  [ridx : i64]
  [rcount : i64]
  [n : i64]
  [forbidden : CompilerRegStringList]) : String
  (if (>= ridx rcount)
    ""
    (let
      [reg : String (array.array-ref reg-arr ridx)]
      [m : i64
        (compiler-reg-greedy-interferer-max
          assignments
          interval-index
          ref-counts
          var
          (array.array-ref reg-arr ridx)
          0
          n
          (- 0 1))]
      (if (and
        (not (compiler-reg-string-list-contains? forbidden reg))
        (>= m 0)
        (< m weight))
        reg
        (compiler-reg-greedy-first-evictable
          assignments
          interval-index
          ref-counts
          var
          weight
          reg-arr
          (+ ridx 1)
          rcount
          n
          forbidden)))))

(define (compiler-reg-greedy-evict-reg!
  [assignments : CompilerRegAssignmentTable]
  [interval-index : CompilerRegIntervalIndex]
  [var : i64]
  [reg : String]
  [idx : i64]
  [n : i64]) : unit
  (if (>= idx n)
    unit
    (begin
      (if (and
        (not (= idx var))
        (compiler-reg-greedy-holds-reg? assignments idx reg)
        (compiler-reg-vars-interfere-segmented-index? interval-index var idx))
        (begin
          (compiler-reg-assignment-table-insert
            assignments
            idx
            (CompilerRegSpill (compiler-reg-stack-slot-offset idx)))
          unit)
        unit)
      (compiler-reg-greedy-evict-reg!
        assignments
        interval-index
        var
        reg
        (+ idx 1)
        n))))

(define (compiler-reg-greedy-already-assigned?
  [assignments : CompilerRegAssignmentTable]
  [var : i64]) : bool
  (match (compiler-reg-assignment-table-lookup assignments var)
    [(CompilerRegSomeLocation _) true]
    [(CompilerRegNoLocation) false]))

;; RS_* stage machine (LLVM RAGreedy selectOrSplit, made explicit on the per-vreg
;; base). alloc-one! pops one root in priority order and returns its terminal
;; stage:
;;   RS_Assign (1) -- got a register (hint reg, free reg, or by evicting strictly
;;                    lower-weight interferers).
;;   RS_Split  (2) -- no register, but the spilled root has a split-eligible
;;                    (multi-segment / loop-carried) live range, so the function-
;;                    level region-splitter (compiler-reg-loop-split-*, run as the
;;                    backend post-pass on THIS plan) will rescue it: rewrite the
;;                    hot region to a fresh register-resident var + cold-edge
;;                    boundary copies, cost-gated by mentions x loop-depth. The
;;                    greedy returns a CompilerRegPlan (not a rewritten function),
;;                    so the IR-rewriting split necessarily lives in that post-pass;
;;                    this stage records the selectOrSplit decision.
;;   RS_Spill  (3) -- no register and not split-eligible: stack-home it.
;; The plan output is identical to the single-pass M1 (every non-assigned root is
;; spilled either way); the stage is the explicit decision the post-pass consumes.
(define (compiler-reg-greedy-stage-rs-new) : i64
  0)

(define (compiler-reg-greedy-stage-rs-assign) : i64
  1)

(define (compiler-reg-greedy-stage-rs-split) : i64
  2)

(define (compiler-reg-greedy-stage-rs-spill) : i64
  3)

;; Physical-register preference (arg-var -> ABI-arg-register coalescing). For an
;; OUTGOING call-argument var the plan records the greedy-integer-pool INDEX of the
;; SysV register it will be marshalled into (arg position i ->
;; compiler-backend-arg-reg i: 0=%rdi,1=%rsi,2=%rdx,3=%rcx,4=%r8,5=%r9). Homing the
;; arg value directly in that register turns the backend's `movq <home>, %rdi`
;; marshalling move into a `movq %rdi, %rdi` self-move that the peephole drops.
;; SOUND because an arg value is consumed AT the call (not live across it):
;;   * `spans-call` vars are gated out, so a genuinely call-spanning value is NEVER
;;     homed in a caller-saved arg register (it would be clobbered by the call it
;;     spans) -- those fall through to the callee-saved-only search below;
;;   * the preference is honoured ONLY when the register is in the active pool, not
;;     clobbered by a spanned div/shift (`forbidden`), and FREE over the var's whole
;;     interval (no interferer holds it). Any failure returns "" and the normal
;;     hint/free/evict pick runs, so a preference can never force a spill, evict a
;;     value, or create interference -- it only biases a free choice.
(define (compiler-reg-greedy-arg-pref-reg
  [assignments : CompilerRegAssignmentTable]
  [interval-index : CompilerRegIntervalIndex]
  [ref-counts : (Array i64)]
  [arg-prefs : (Array i64)]
  [reg-arr : (Array String)]
  [rcount : i64]
  [regs : CompilerRegStringList]
  [var : i64]
  [n : i64]
  [forbidden : CompilerRegStringList]
  [spans-call : bool]) : String
  (if (or spans-call (< var 0) (>= var (array.array-length arg-prefs)))
    ""
    (let
      [idx : i64 (array.array-ref arg-prefs var)]
      (if (or (< idx 0) (>= idx rcount))
        ""
        (let
          [reg : String (array.array-ref reg-arr idx)]
          (if (and
            (not (compiler-reg-string-list-contains? forbidden reg))
            (compiler-reg-string-list-contains? regs reg)
            (compiler-reg-greedy-reg-free?
              assignments
              interval-index
              ref-counts
              var
              reg
              n))
            reg
            ""))))))

(define (compiler-reg-greedy-alloc-one!
  [assignments : CompilerRegAssignmentTable]
  [interval-index : CompilerRegIntervalIndex]
  [ref-counts : (Array i64)]
  [copy-hints : (Array i64)]
  [arg-prefs : (Array i64)]
  [group-vars : CompilerLiveI64Set]
  [regs : CompilerRegStringList]
  [reg-arr : (Array String)]
  [rcount : i64]
  [var : i64]
  [n : i64]
  [call-points : CompilerLiveI64Set]
  [div-points : CompilerLiveI64Set]
  [shift-points : CompilerLiveI64Set]
  [callee-regs : CompilerRegStringList]
  [caller-saved-count : i64]) : i64
  (if (or
    (compiler-reg-greedy-already-assigned? assignments var)
    (compiler-live-set-contains? group-vars var))
    (compiler-reg-greedy-stage-rs-new)
    (let
      ;; Per-register clobber (15c). A call-spanning value may use NO caller-saved
      ;; reg (start past the caller-saved prefix, callee-saved copy-hints only) --
      ;; the original coarse rule. A value that spans only a div/shift may still use
      ;; the caller-saved regs that op does NOT clobber: it searches the whole pool
      ;; (start-idx 0) with `forbidden` excluding just {rax,rdx} (div) and/or
      ;; {rcx} (shift).
      [spans-call : bool
        (compiler-reg-greedy-var-spans-clobber? interval-index call-points var)]
      [spans-div : bool
        (compiler-reg-greedy-var-spans-clobber? interval-index div-points var)]
      [spans-shift : bool
        (compiler-reg-greedy-var-spans-clobber? interval-index shift-points var)]
      [start-idx : i64
        (if spans-call
          caller-saved-count
          0)]
      [hint-regs : CompilerRegStringList
        (if spans-call
          callee-regs
          regs)]
      [forbidden : CompilerRegStringList
        (if spans-call
          CompilerRegStringNil
          (compiler-reg-greedy-forbidden-regs spans-div spans-shift))]
      ;; Highest-priority bias: if this var is an outgoing call argument, try its
      ;; ABI arg register first (free-only, never evicting). Falls through to the
      ;; copy-hint / first-free / evict pick when the arg register is unavailable.
      [pref : String
        (compiler-reg-greedy-arg-pref-reg
          assignments
          interval-index
          ref-counts
          arg-prefs
          reg-arr
          rcount
          regs
          var
          n
          forbidden
          spans-call)]
      [hint : String
        (compiler-reg-greedy-hint-free-reg
          assignments
          interval-index
          ref-counts
          copy-hints
          hint-regs
          var
          n
          forbidden)]
      ;; The ABI arg-register preference takes priority over the copy hint; both
      ;; are free-only picks (no eviction), so a single non-empty test assigns
      ;; whichever applies and otherwise falls through to first-free/evict/spill.
      [chosen : String
        (if (not (string-eq pref ""))
          pref
          hint)]
      (if (not (string-eq chosen ""))
        (begin
          (compiler-reg-assignment-table-insert
            assignments
            var
            (CompilerRegRegister chosen))
          (compiler-reg-greedy-stage-rs-assign))
        (let
          [free : String
            (compiler-reg-greedy-first-free
              assignments
              interval-index
              ref-counts
              var
              reg-arr
              start-idx
              rcount
              n
              forbidden)]
          (if (not (string-eq free ""))
            (begin
              (compiler-reg-assignment-table-insert
                assignments
                var
                (CompilerRegRegister free))
              (compiler-reg-greedy-stage-rs-assign))
            (let
              [weight : i64
                (if (< var (array.array-length ref-counts))
                  (array.array-ref ref-counts var)
                  0)]
              [ev : String
                (compiler-reg-greedy-first-evictable
                  assignments
                  interval-index
                  ref-counts
                  var
                  weight
                  reg-arr
                  start-idx
                  rcount
                  n
                  forbidden)]
              (if (not (string-eq ev ""))
                (begin
                  (compiler-reg-greedy-evict-reg!
                    assignments
                    interval-index
                    var
                    ev
                    0
                    n)
                  (compiler-reg-assignment-table-insert
                    assignments
                    var
                    (CompilerRegRegister ev))
                  (compiler-reg-greedy-stage-rs-assign))
                (begin
                  (compiler-reg-assignment-table-insert
                    assignments
                    var
                    (CompilerRegSpill (compiler-reg-stack-slot-offset var)))
                  (if (compiler-reg-interval-index-var-has-segments?
                    interval-index
                    var)
                    (compiler-reg-greedy-stage-rs-split)
                    (compiler-reg-greedy-stage-rs-spill)))))))))))

(define (compiler-reg-greedy-collect-vars
  [candidates : CompilerRegIntervalList]
  [out : (Array i64)]
  [i : i64]) : i64
  (match candidates
    [(CompilerRegIntervalNil) i]
    [(CompilerRegIntervalCons interval rest)
      (match interval
        [(CompilerRegInterval var _ _)
          (begin
            (if (< i (array.array-length out))
              (array.array-set! out i var)
              unit)
            (compiler-reg-greedy-collect-vars (box-get rest) out (+ i 1)))])]))

(define (compiler-reg-greedy-weight-before?
  [ref-counts : (Array i64)]
  [a : i64]
  [b : i64]) : bool
  (let
    [wa : i64
      (if (< a (array.array-length ref-counts))
        (array.array-ref ref-counts a)
        0)]
    [wb : i64
      (if (< b (array.array-length ref-counts))
        (array.array-ref ref-counts b)
        0)]
    (if (> wa wb)
      true
      (if (< wa wb)
        false
        (< a b)))))

(define (compiler-reg-greedy-sort-insert!
  [arr : (Array i64)]
  [ref-counts : (Array i64)]
  [j : i64]) : unit
  (if (<= j 0)
    unit
    (let
      [cur : i64 (array.array-ref arr j)]
      [prev : i64 (array.array-ref arr (- j 1))]
      (if (compiler-reg-greedy-weight-before? ref-counts cur prev)
        (begin
          (array.array-set! arr j prev)
          (array.array-set! arr (- j 1) cur)
          (compiler-reg-greedy-sort-insert! arr ref-counts (- j 1)))
        unit))))

(define (compiler-reg-greedy-sort!
  [arr : (Array i64)]
  [ref-counts : (Array i64)]
  [i : i64]
  [count : i64]) : unit
  (if (>= i count)
    unit
    (begin
      (compiler-reg-greedy-sort-insert! arr ref-counts i)
      (compiler-reg-greedy-sort! arr ref-counts (+ i 1) count))))

;; Combine the remat-DISCOUNTED spill weight (primary eviction priority) with the
;; RAW (undiscounted) use-density (secondary tie-break) into a single key:
;;   combined = discounted * (maxRaw + 1) + raw
;; Sorting/eviction by `combined` therefore orders first by discounted weight
;; (remat values are cheaper to spill, so they rank lower and spill first) and,
;; among equal discounted weight, by raw use count (the genuinely coldest value
;; spills first). The /2 remat discount collapses distinct use counts to the same
;; small integer; without the raw secondary key the greedy would spill an
;; arbitrary tied value (e.g. a 2-use value over the 1-use coldest). maxRaw+1 as
;; the radix keeps `discounted` strictly dominant. A non-remat value (discounted
;; == raw) outranks a remat value of equal raw, so remat is still preferred for
;; spilling.
(define (compiler-reg-greedy-combine-spill-weights
  [discounted : (Array i64)]
  [raw : (Array i64)]) : (Array i64)
  (let
    [n : i64 (array.array-length discounted)]
    [out : (Array i64) (array.make-array i64 n)]
    [max-raw : i64 0]
    [v : i64 0]
    (begin
      (while (< v n)
        (begin
          (let
            [r : i64
              (if (< v (array.array-length raw))
                (array.array-ref raw v)
                0)]
            (if (> r max-raw)
              (set! max-raw r)
              unit))
          (set! v (+ v 1))))
      (set! v 0)
      (while (< v n)
        (begin
          (let
            [d : i64 (array.array-ref discounted v)]
            [r : i64
              (if (< v (array.array-length raw))
                (array.array-ref raw v)
                0)]
            (array.array-set! out v (+ (* d (+ max-raw 1)) r)))
          (set! v (+ v 1))))
      out)))

;; Staged worklist driver: pop each root in priority (spill-weight desc) order,
;; run selectOrSplit (alloc-one!), and record its terminal RS_* stage in `stages`.
;; The stage array is the explicit selectOrSplit state the post-pass region split
;; consumes (RS_Split roots are exactly the loop-split rescue candidates).
(define (compiler-reg-greedy-alloc-all!
  [arr : (Array i64)]
  [i : i64]
  [count : i64]
  [assignments : CompilerRegAssignmentTable]
  [interval-index : CompilerRegIntervalIndex]
  [ref-counts : (Array i64)]
  [copy-hints : (Array i64)]
  [arg-prefs : (Array i64)]
  [group-vars : CompilerLiveI64Set]
  [regs : CompilerRegStringList]
  [reg-arr : (Array String)]
  [rcount : i64]
  [stages : (Array i64)]
  [n : i64]
  [call-points : CompilerLiveI64Set]
  [div-points : CompilerLiveI64Set]
  [shift-points : CompilerLiveI64Set]
  [callee-regs : CompilerRegStringList]
  [caller-saved-count : i64]) : unit
  (if (>= i count)
    unit
    (let
      [v : i64 (array.array-ref arr i)]
      [stg : i64
        (compiler-reg-greedy-alloc-one!
          assignments
          interval-index
          ref-counts
          copy-hints
          arg-prefs
          group-vars
          regs
          reg-arr
          rcount
          v
          n
          call-points
          div-points
          shift-points
          callee-regs
          caller-saved-count)]
      (begin
        (if (and (>= v 0) (< v (array.array-length stages)))
          (array.array-set! stages v stg)
          unit)
        (compiler-reg-greedy-alloc-all!
          arr
          (+ i 1)
          count
          assignments
          interval-index
          ref-counts
          copy-hints
          arg-prefs
          group-vars
          regs
          reg-arr
          rcount
          stages
          n
          call-points
          div-points
          shift-points
          callee-regs
          caller-saved-count)))))

;; Unified Greedy integer register pool: caller-saved zero-call scratch
;; (%r9/%rcx/%rdx) FIRST so non-call-spanning values prefer them -- no
;; prologue/epilogue save/restore, the LLVM CSR-cost try-order -- then the other
;; caller-saved pool members (%r10/%r11/%r8), then the callee-saved pool. The
;; first `caller-saved-count` entries are caller-saved: a value whose live range
;; spans a backend clobber-point (call site / op that clobbers caller-saved regs)
;; may NOT use them (it would be clobbered across the clobber), exactly the
;; regmask-as-interference rule. Such values start their register search at the
;; callee-saved offset. This folds the old prepass-partition +
;; caller-saved-overflow into ONE allocation pass.
(define (compiler-reg-greedy-integer-pool) : CompilerRegStringList
  (compiler-reg-string-cons
    "%rax"
    (compiler-reg-string-cons
    "%rsi"
    (compiler-reg-string-cons
    "%rdi"
    (compiler-reg-string-cons
    "%r9"
    (compiler-reg-string-cons
      "%rcx"
      (compiler-reg-string-cons
        "%rdx"
        (compiler-reg-string-cons
          "%r10"
          (compiler-reg-string-cons
            "%r11"
            (compiler-reg-string-cons
              "%r8"
              (compiler-reg-sysv-integer-registers)))))))))))

(define (compiler-reg-greedy-caller-saved-count) : i64
  (-
    (compiler-reg-string-list-count (compiler-reg-greedy-integer-pool))
    (compiler-reg-string-list-count (compiler-reg-sysv-integer-registers))))

;; ABI-aware GP greedy pool. SysV is the byte-identical default pool above. Win64
;; differs ONLY in the caller/callee SPLIT: %rsi/%rdi are NONVOLATILE (callee-
;; saved) on Win64, so they must live in the callee-saved suffix (saved/restored
;; by the prologue, kept across calls) rather than the caller-saved prefix --
;; otherwise a Win64 function homes a value in %rsi/%rdi, treats it as clobbered
;; across calls, and clobbers the caller's nonvolatile register. All 14 registers
;; are in the pool for both ABIs; only the order (and thus caller-saved-count)
;; changes. The SysV self-host fixpoint cannot exercise this (SysV-only).
(define (compiler-reg-greedy-integer-pool-for-abi
  [abi : CompilerRegTargetAbi]) : CompilerRegStringList
  (match abi
    [(CompilerRegAbiLinux) (compiler-reg-greedy-integer-pool)]
    [(CompilerRegAbiWindows)
      ;; Win64: %rsi/%rdi are nonvolatile (callee-saved). The backend prologue/
      ;; epilogue (compiler-backend-emit-save-callee-regs) saves only the SysV
      ;; callee set (r12-r15,rbx), so -- to stay sound WITHOUT a Win64-specific
      ;; save-set -- EXCLUDE %rsi/%rdi from the Win64 allocatable pool (12 GP regs).
      ;; caller-saved (volatile) first: rax,rcx,rdx,r8,r9,r10,r11 (7), then the
      ;; backend-saved callee suffix r12-r15,rbx (5). Reclaiming %rsi/%rdi as Win64
      ;; homes requires a Win64 callee save-set -- a follow-up; this keeps Win64
      ;; CORRECT now (previously %rsi/%rdi sat in the caller-saved prefix and were
      ;; clobbered without save, corrupting the caller's nonvolatile registers).
      (compiler-reg-string-cons
        "%rax"
        (compiler-reg-string-cons
          "%rcx"
          (compiler-reg-string-cons
            "%rdx"
            (compiler-reg-string-cons
              "%r8"
              (compiler-reg-string-cons
                "%r9"
                (compiler-reg-string-cons
                  "%r10"
                  (compiler-reg-string-cons
                    "%r11"
                    (compiler-reg-sysv-integer-registers))))))))]))

(define (compiler-reg-greedy-caller-saved-count-for-abi
  [abi : CompilerRegTargetAbi]) : i64
  (match abi
    [(CompilerRegAbiLinux) (compiler-reg-greedy-caller-saved-count)]
    [(CompilerRegAbiWindows)
      ;; Win64 pool = 7 caller-saved + the 5 backend-saved callee regs (r12-r15,rbx);
      ;; %rsi/%rdi are excluded (see pool-for-abi). 12 - 5 = 7 caller-saved.
      (-
        (compiler-reg-string-list-count
          (compiler-reg-greedy-integer-pool-for-abi abi))
        (compiler-reg-string-list-count
          (compiler-reg-sysv-integer-registers)))]))

;; Coarse clobber-span test: does var's [start,end] cross any clobber-point?
;; (The clobber-span half of the old per-register zero-call gate, sans the
;; conflict check which the LiveIntervalUnion test already covers.)
;; Out-of-range -> conservative spanning (callee-saved only).
(define (compiler-reg-greedy-var-spans-clobber?
  [interval-index : CompilerRegIntervalIndex]
  [clobber-points : CompilerLiveI64Set]
  [var : i64]) : bool
  (let
    [starts : (Array i64) (struct-get interval-index starts)]
    [ends : (Array i64) (struct-get interval-index ends)]
    (if (and (>= var 0) (< var (array.array-length starts)))
      (compiler-reg-call-set-in-range?
        clobber-points
        (array.array-ref starts var)
        (array.array-ref ends var))
      true)))

;; SysV integer call-argument registers by position (mirrors
;; compiler-backend-arg-reg in compiler_backend.tl; duplicated here because
;; regalloc must not depend on the backend). "" past the 6 register args (the rest
;; are stack-passed and get no physical preference).
(define (compiler-reg-sysv-arg-reg [pos : i64]) : String
  (cond
    [(= pos 0) "%rdi"]
    [(= pos 1) "%rsi"]
    [(= pos 2) "%rdx"]
    [(= pos 3) "%rcx"]
    [(= pos 4) "%r8"]
    [(= pos 5) "%r9"]
    [else ""]))

(define (compiler-reg-string-list-index-of
  [regs : CompilerRegStringList]
  [want : String]
  [i : i64]) : i64
  (match regs
    [(CompilerRegStringNil) -1]
    [(CompilerRegStringCons reg rest)
      (if (string.string-eq reg want)
        i
        (compiler-reg-string-list-index-of (box-get rest) want (+ i 1)))]))

;; Greedy-integer-pool INDEX of the SysV register for integer arg position `pos`,
;; or -1 if `pos` is not a register-passed argument. Computed by searching the
;; live pool definition, so it stays correct if the pool order changes.
(define (compiler-reg-greedy-arg-pool-index [pos : i64]) : i64
  (let
    [reg : String (compiler-reg-sysv-arg-reg pos)]
    (if (string.string-eq reg "")
      -1
      (compiler-reg-string-list-index-of
        (compiler-reg-greedy-integer-pool)
        reg
        0))))

;; Record arg-var -> ABI-register preference (greedy-pool index) for one call
;; argument at integer position `pos`. Only IrValueVar args take a home; the
;; var is mapped to its coalesce root (parents) like the copy hints, and the first
;; preference for a root wins. Indices past arg 5 yield -1 and are skipped.
(define (compiler-reg-arg-pref-value!
  [value : CompilerIrValue]
  [pos : i64]
  [prefs : (Array i64)]
  [parents : (Array i64)]) : unit
  (match value
    [(IrValueVar v)
      (let
        [idx : i64 (compiler-reg-greedy-arg-pool-index pos)]
        (if (< idx 0)
          unit
          (let
            [root : i64
              (if (if (>= v 0)
                (< v (array.array-length parents))
                false)
                (array.array-ref parents v)
                v)]
            (if (if (>= root 0)
              (< root (array.array-length prefs))
              false)
              (if (< (array.array-ref prefs root) 0)
                (begin
                  (array.array-set! prefs root idx)
                  unit)
                unit)
              unit))))]
    [_ unit]))

(define (compiler-reg-arg-pref-array!
  [values : (Array CompilerIrValue)]
  [i : i64]
  [prefs : (Array i64)]
  [parents : (Array i64)]) : unit
  (if (>= i (array.array-length values))
    unit
    (begin
      (compiler-reg-arg-pref-value! (array.array-ref values i) i prefs parents)
      (compiler-reg-arg-pref-array! values (+ i 1) prefs parents))))

(define (compiler-reg-arg-pref-args!
  [args : CompilerIrCallArgs]
  [prefs : (Array i64)]
  [parents : (Array i64)]) : unit
  (match args
    [(IrCallArgsNil) unit]
    [(IrCallArgsOne a) (compiler-reg-arg-pref-value! a 0 prefs parents)]
    [(IrCallArgsTwo a b)
      (begin
        (compiler-reg-arg-pref-value! a 0 prefs parents)
        (compiler-reg-arg-pref-value! b 1 prefs parents))]
    [(IrCallArgsArray values)
      (compiler-reg-arg-pref-array! values 0 prefs parents)]))

;; Outgoing call instructions whose integer args are marshalled through the SysV
;; arg registers. The callee/function-pointer operand of the indirect forms is NOT
;; an argument and is left without a preference. (Syscalls use a different register
;; convention and are intentionally omitted.)
(define (compiler-reg-arg-pref-instr!
  [instr : CompilerIrInstr]
  [prefs : (Array i64)]
  [parents : (Array i64)]) : unit
  (match instr
    [(IrInstrCall _ _ args _)
      (compiler-reg-arg-pref-args! args prefs parents)]
    ;; Indirect/closure calls: arg vars are ineligible (see
    ;; compiler-reg-call-arg-vars-instr-seq-scalar) so no arg-reg preference
    ;; applies; the base-0 pref was also wrong for the closure base-1 marshalling.
    [(IrInstrCallCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallCAbiStoreResultPayload _ _ args _)
          (compiler-reg-arg-pref-args! args prefs parents)])]
    [(IrInstrCallIndirectCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallIndirectCAbiStoreResultPayload _ _ args _)
          (compiler-reg-arg-pref-args! args prefs parents)])]
    [(IrInstrTailCall _ args _)
      (compiler-reg-arg-pref-args! args prefs parents)]
    [(IrInstrTailCallIndirect _ args _)
      (compiler-reg-arg-pref-args! args prefs parents)]
    [_ unit]))

(define (compiler-reg-arg-pref-seq!
  [instrs : CompilerIrInstrSeq]
  [prefs : (Array i64)]
  [parents : (Array i64)]) : unit
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (compiler-reg-arg-pref-instr!
            (array.array-ref slots index)
            prefs
            parents)
          (set! index (+ index 1))))
      unit)))

(define (compiler-reg-arg-pref-blocks!
  [blocks : CompilerIrBlockList]
  [prefs : (Array i64)]
  [parents : (Array i64)]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (begin
        (match block
          [(IrBlock _ instrs)
            (compiler-reg-arg-pref-seq! instrs prefs parents)])
        (compiler-reg-arg-pref-blocks! (box-get rest) prefs parents))]
    [(IrBlockArray seq)
      (compiler-reg-arg-pref-blocks!
        (compiler-ir-block-seq-to-list seq)
        prefs
        parents)]))

;; Build the per-root physical-register preference array: each outgoing call-arg
;; var biased toward the SysV register it is marshalled into. Indexed by coalesce
;; root (like copy hints); -1 = no preference.
(define (compiler-reg-function-arg-prefs
  [abi : CompilerRegTargetAbi]
  [func : CompilerIrFunction]
  [coalesce : CompilerRegCoalesceMap]
  [n : i64]) : (Array i64)
  (let
    [prefs : (Array i64) (array.make-array i64 n)]
    [parents : (Array i64) (struct-get coalesce parents)]
    (begin
      (compiler-reg-fill-i64-array prefs -1)
      ;; The arg->ABI-register preference is keyed on the SysV arg-register map
      ;; (compiler-reg-greedy-arg-pool-index). On Win64 the arg registers differ
      ;; (rcx/rdx/r8/r9) AND %rsi/%rdi are callee-saved, so the SysV bias is both
      ;; wrong and counterproductive there; skip it (empty preference) on Win64
      ;; until a Win64 arg-coalescing pass lands. SysV is unchanged.
      (match abi
        [(CompilerRegAbiLinux)
          (match func
            [(IrFunction _ _ _ _ blocks)
              (compiler-reg-arg-pref-blocks! blocks prefs parents)])]
        [(CompilerRegAbiWindows) unit])
      prefs)))

(define (compiler-reg-greedy-state
  [candidates : CompilerRegIntervalList]
  [regs : CompilerRegStringList]
  [assignments : CompilerRegAssignmentTable]
  [interval-index : CompilerRegIntervalIndex]
  [group-vars : CompilerLiveI64Set]
  [ref-counts : (Array i64)]
  [copy-hints : (Array i64)]
  [arg-prefs : (Array i64)]
  [call-points : CompilerLiveI64Set]
  [div-points : CompilerLiveI64Set]
  [shift-points : CompilerLiveI64Set]
  [callee-regs : CompilerRegStringList]
  [caller-saved-count : i64]) : CompilerRegAssignState
  (let
    [n : i64 (array.array-length (struct-get assignments present))]
    [rcount : i64 (compiler-reg-string-list-count regs)]
    [reg-arr : (Array String)
      (array.make-array
        String
        (if (< (compiler-reg-string-list-count regs) 1)
          1
          (compiler-reg-string-list-count regs)))]
    [order : (Array i64)
      (array.make-array
        i64
        (if (< (array.array-length (struct-get assignments present)) 1)
          1
          (array.array-length (struct-get assignments present))))]
    ;; RS_* stage per root (RS_New until selectOrSplit runs); the post-pass region
    ;; split rescues the RS_Split entries.
    [stages : (Array i64)
      (array.make-array
        i64
        (if (< (array.array-length (struct-get assignments present)) 1)
          1
          (array.array-length (struct-get assignments present))))]
    (begin
      (compiler-reg-greedy-string-list-to-array regs reg-arr 0)
      (let
        [count : i64 (compiler-reg-greedy-collect-vars candidates order 0)]
        (begin
          (compiler-reg-greedy-sort! order ref-counts 0 count)
          (compiler-reg-greedy-alloc-all!
            order
            0
            count
            assignments
            interval-index
            ref-counts
            copy-hints
            arg-prefs
            group-vars
            regs
            reg-arr
            rcount
            stages
            n
            call-points
            div-points
            shift-points
            callee-regs
            caller-saved-count)
          (CompilerRegAssignState CompilerRegActiveNil assignments))))))

(define (compiler-reg-plan-from
  [func : CompilerIrFunction]
  [type-info : CompilerRegVarTypes]
  [types : CompilerRegVarTypeList]
  [intervals : CompilerRegIntervalList]
  [interval-index : CompilerRegIntervalIndex]
  [assignment-table : CompilerRegAssignmentTable]
  [ineligible : CompilerLiveI64Set]
  [blocked : CompilerLiveI64Set]
  [allow-caller-saved-zero-call : bool]
  [abi : CompilerRegTargetAbi]) : CompilerRegPlan
  (let
    [moves
      : CompilerRegMoveList
      ;; #3489 (PR3): phi back-edge moves NON-strict so loop-carried phi/copy
      ;; pairs coalesce (then merge into one root via PR2). SIMD already passed
      ;; false here; only the scalar-opt2 plan gains the loop coalescing.
      (compiler-reg-function-moves func false)]
    [group-vars : CompilerLiveI64Set
      (compiler-reg-function-group-vars func types)]
    ;; Backend caller-clobber points (call sites + ops that clobber caller-saved
    ;; registers). Hoisted so same-value filtering, integer greedy allocation, and
    ;; the existing caller-saved spill rescue share one computation.
    [clobber-points
      : CompilerLiveI64Set
      ;; Unconditional: the greedy now allocates the integer (both opt2 and SIMD)
      ;; AND float->XMM classes, all of which use clobber-points for call-clobber
      ;; interference. On the SIMD-integer path caller-saved-count=0 makes every
      ;; pool register callee-saved, so the clobber test never restricts there; on
      ;; the XMM path call-spanning floats are already excluded pre-allocation.
      (compiler-reg-backend-caller-clobber-points func)]
    ;; #2 same-value overlap coalescing: single-def direct copy pairs carry one
    ;; identical value and may coalesce even when their live segments overlap.
    ;; Vars spanning a modeled caller-clobber point stay out of the same-value
    ;; relation for now; their save/restore and regmask constraints are already
    ;; represented by normal interference and must not be bypassed by an overlap
    ;; waiver.
    [sv-parents : (Array i64)
      (compiler-reg-function-same-value-parents-filtered
        func
        (compiler-reg-same-value-eligible-vars interval-index clobber-points))]
    [coalesce : CompilerRegCoalesceMap
      (if allow-caller-saved-zero-call
        (compiler-reg-coalesce-map-build
          moves
          interval-index
          type-info
          group-vars
          (array.array-length (struct-get interval-index starts))
          sv-parents)
        (CompilerRegCoalesceMap (array.make-array i64 0)))]
    ;; #3489 (PR2): collapse coalesce classes to one root candidate each, and run
    ;; the allocation passes over those roots with an EMPTY coalesce map (the
    ;; merge already realised coalescing, so no per-member coalesce-location is
    ;; needed). SIMD/AVX (allow-caller-saved-zero-call = false) builds no coalesce
    ;; map, so eff-* fall back to the originals and that path is byte-identical.
    [eff-index : CompilerRegIntervalIndex
      (if allow-caller-saved-zero-call
        (compiler-reg-merged-root-index coalesce interval-index)
        interval-index)]
    ;; move census (cfg regalloc-census only; no-op otherwise): categorise the
    ;; harvested moves against the final coalesce result + per-var and per-root
    ;; segments.
    [_move-census : unit
      (cfg
        regalloc-census
        (if allow-caller-saved-zero-call
          (compiler-reg-move-census-record!
            moves
            (struct-get coalesce parents)
            interval-index
            eff-index
            type-info
            group-vars
            sv-parents)
          unit)
        unit)]
    [eff-intervals : CompilerRegIntervalList
      (if allow-caller-saved-zero-call
        (compiler-reg-interval-arrays-to-list
          (struct-get eff-index starts)
          (struct-get eff-index ends)
          (- (array.array-length (struct-get eff-index starts)) 1)
          CompilerRegIntervalNil)
        intervals)]
    ;; copy-hint biasing: per-root preferred move-neighbour for the integer passes.
    [copy-hints
      : (Array i64)
      ;; Built unconditionally now that the greedy allocates the SIMD-integer path
      ;; too: with the empty false-path coalesce, copy-hints-add-move! falls back to
      ;; identity roots, so this yields direct var->move-neighbour hints -- letting
      ;; the SIMD-integer greedy bias a copy's dst onto its src register (LLVM-style
      ;; copy hint for every class), which the old linear-scan did via `moves`. The
      ;; float->XMM call passes its own empty copy-hints, so floats are unaffected.
      (compiler-reg-function-copy-hints
        moves
        coalesce
        (array.array-length (struct-get interval-index starts)))]
    ;; arg-var -> ABI-arg-register physical preference: each outgoing call-argument
    ;; var biased toward the SysV register it will be marshalled into, so the
    ;; backend's `movq <home>, %rdi` becomes an elided self-move. Indexed by
    ;; coalesce root, like copy-hints. Only the scalar-opt2 integer greedy consumes
    ;; it; the SIMD-integer and float->XMM greedy calls pass an empty array (their
    ;; pools are not the SysV integer pool, so a pool-index preference is moot).
    [arg-prefs
      : (Array i64)
      (compiler-reg-function-arg-prefs
        abi
        func
        coalesce
        (array.array-length (struct-get interval-index starts)))]
    ;; #3489 follow-up: the effective scalar allocation pass sees only coalesced
    ;; roots, so original-var exclusions must block the root. Otherwise a root
    ;; may get a register even though one merged member is a call argument or
    ;; parameter that must stay stack/ABI-homed; on Windows that let a stack
    ;; CreateFileA argument inherit %r9 after the same call clobbered %r9 for the
    ;; fourth ABI argument.
    [eff-blocked : CompilerLiveI64Set
      (if allow-caller-saved-zero-call
        (compiler-reg-coalesce-root-set-from-vars coalesce blocked)
        blocked)]
    [integer-candidates : CompilerRegIntervalList
      (compiler-reg-candidates eff-intervals type-info eff-blocked false)]
    [integer-registers : CompilerRegStringList
      (compiler-reg-sysv-integer-registers)]
    [vector-mask-defs : CompilerLiveUseDef
      (compiler-reg-function-vector-mask-defs func)]
    ;; #3490: loop-depth-weighted use counts drive spill-weight eviction on the
    ;; integer scalar opt2 stage (allow-caller-saved-zero-call is the scalar-opt2
    ;; discriminator). An empty array selects the original furthest-end policy,
    ;; keeping the SIMD/AVX plan and the caller-saved XMM stage byte-identical.
    [eviction-ref-counts : (Array i64)
      (if allow-caller-saved-zero-call
        ;; The greedy ALWAYS uses remat-discounted spill weights for its priority
        ;; order (LLVM RAGreedy always computes spill weights). The old
        ;; remat-weight-needed gate compared total candidates to the full
        ;; (8-register) pool, so a call-spanning function -- whose values may only
        ;; use the 5 callee-saved registers and so oversubscribe even with < 8
        ;; total candidates -- got an empty weight array and fell back to var-id
        ;; order, keeping the rematerialisable constant in a register and spilling
        ;; a more expensive non-remat value. Always scoring fixes that (#3489 PR2:
        ;; each coalesced class scored by its hottest member). The discounted
        ;; weight is combined with the RAW use-density as a tie-break (combine-
        ;; spill-weights) so that among equal-discounted values the genuinely
        ;; coldest one spills, not an arbitrary tied one.
        (compiler-reg-greedy-combine-spill-weights
          (compiler-reg-merge-ref-counts
            coalesce
            (compiler-reg-function-spill-weights-remat func coalesce)
            (array.array-length (struct-get interval-index starts)))
          (compiler-reg-merge-ref-counts
            coalesce
            (compiler-reg-function-spill-weights func)
            (array.array-length (struct-get interval-index starts))))
        (array.make-array i64 0))]
    ;; Per-register clobber point sets (15c): kind 0 = call sites (all caller-saved),
    ;; kind 1 = idiv (rax:rdx), kind 2 = shift (rcx). Splitting the
    ;; old merged set lets the greedy forbid only the registers each op actually
    ;; clobbers, so a div/shift-spanning value keeps the caller-saved regs the op
    ;; leaves alone instead of being forced callee-saved. On the SIMD-integer path
    ;; caller-saved-count=0 makes every pool register callee-saved (no restriction);
    ;; on the XMM path call-spanning floats are already excluded pre-allocation.
    [call-points : CompilerLiveI64Set (compiler-reg-clobber-kind-points func 0)]
    [div-points : CompilerLiveI64Set (compiler-reg-clobber-kind-points func 1)]
    [shift-points : CompilerLiveI64Set
      (compiler-reg-clobber-kind-points func 2)]
    ;; Step B: the unified greedy is the scalar integer allocator and homes
    ;; non-call-spanning scratch in the caller-saved pool (%r9/%rcx/%rdx) itself,
    ;; so the old scalar prepass-partition + caller-saved-overflow passes are gone.
    ;; The incoming table flows straight in; integer-candidates is borrowed directly.
    [prepass-assignments : CompilerRegAssignmentTable assignment-table]
    [integer-state
      : CompilerRegAssignState
      ;; Integer allocation via the unified per-vreg Greedy allocator (priority-queue
      ;; selectOrSplit, per-physreg LiveIntervalUnion, call-clobber as interference).
      ;; Scalar-opt2 (true) uses all 14 integer registers + coalescing; the SIMD/AVX
      ;; branch below (false) uses the 5 callee-saved (the old SIMD pool) with no
      ;; coalescing -- the same algorithm, a conservative config.
      (if allow-caller-saved-zero-call
        (compiler-reg-greedy-state
          integer-candidates
          (compiler-reg-greedy-integer-pool-for-abi abi)
          prepass-assignments
          eff-index
          group-vars
          eviction-ref-counts
          copy-hints
          arg-prefs
          call-points
          div-points
          shift-points
          integer-registers
          (compiler-reg-greedy-caller-saved-count-for-abi abi))
        ;; SIMD/AVX integer allocation: same unified greedy, over the 5 callee-saved
        ;; integer registers (= the old SIMD pool) with caller-saved-count=0 so every
        ;; register is treated callee-saved (no caller-saved-first ordering; the SIMD
        ;; path never partitioned). ref-counts/copy-hints are empty here -> the
        ;; greedy's bounds-guarded spill-weight/hint accesses fall back to var-id
        ;; order / no-hint, matching the old linear-scan's defaults.
        (compiler-reg-greedy-state
          integer-candidates
          integer-registers
          prepass-assignments
          eff-index
          group-vars
          eviction-ref-counts
          copy-hints
          (array.make-array i64 0)
          call-points
          div-points
          shift-points
          integer-registers
          0))]
    [integer-assignments : CompilerRegAssignmentTable
      (match integer-state
        [(CompilerRegAssignState _ assignments) assignments])]
    ;; Step B: the caller-saved-overflow pass is gone -- the unified greedy already
    ;; allocates the caller-saved zero-call pool (%r9/%rcx/%rdx) itself, so retrying
    ;; the same registers here was redundant. The call-spanning save/restore rescue
    ;; (a real spill-avoidance, not a register-allocation pass) is kept and fed the
    ;; greedy's assignments directly.
    [integer-with-call-save-state : CompilerRegCallSaveAssignState
      (if (and
        allow-caller-saved-zero-call
        (compiler-reg-assignment-table-has-spill? integer-assignments))
        (compiler-reg-assign-caller-saved-call-spanning
          func
          integer-candidates
          integer-assignments
          eff-index
          group-vars)
        (CompilerRegCallSaveAssignState
          integer-assignments
          (compiler-live-set-empty)))]
    [integer-call-assignments : CompilerRegAssignmentTable
      (match integer-with-call-save-state
        [(CompilerRegCallSaveAssignState assignments _) assignments])]
    [call-save-shadows : CompilerLiveI64Set
      (match integer-with-call-save-state
        [(CompilerRegCallSaveAssignState _ shadows) shadows])]
    [scalar-state
      : CompilerRegAssignState
      ;; float -> XMM allocation: the unified greedy over the XMM registers. SysV has
      ;; NO callee-saved XMM, so callee-regs=nil and caller-saved-count=|xmm| -> every
      ;; xmm is caller-saved; a float crossing a call would get no register and spill.
      ;; But call-spanning floats are already excluded pre-allocation
      ;; (mark-float-spanning on the scalar path / ineligible-vars-simd on the SIMD
      ;; path), so only non-call-spanning floats reach here -- exactly the set the old
      ;; linear-scan allocated; only the register CHOICE differs. group-vars /
      ;; ref-counts / copy-hints empty -> bounds-guarded var-id order, no hint.
      (compiler-reg-greedy-state
        (compiler-reg-candidates eff-intervals type-info eff-blocked true)
        (compiler-reg-xmm-registers)
        integer-call-assignments
        eff-index
        (compiler-live-set-empty)
        (array.make-array i64 0)
        (array.make-array i64 0)
        (array.make-array i64 0)
        call-points
        div-points
        shift-points
        CompilerRegStringNil
        (compiler-reg-string-list-count (compiler-reg-xmm-registers)))]
    [scalar-assignments : CompilerRegAssignmentTable
      (match scalar-state
        [(CompilerRegAssignState _ assignments) assignments])]
    [vector-vars : CompilerLiveI64Set
      (match vector-mask-defs
        [(CompilerLiveUseDef vars _) vars])]
    [mask-vars : CompilerLiveI64Set
      (match vector-mask-defs
        [(CompilerLiveUseDef _ vars) vars])]
    [vector-preferences : (Array i64)
      (compiler-reg-function-select-false-preferences
        func
        (array.array-length (struct-get interval-index starts)))]
    [vector-state : CompilerRegAssignState
      (compiler-reg-assign-fixed-candidates
        (compiler-reg-special-candidates intervals vector-vars blocked)
        (compiler-reg-vector-registers)
        CompilerRegActiveNil
        scalar-assignments
        vector-preferences
        interval-index)]
    [vector-assignments : CompilerRegAssignmentTable
      (match vector-state
        [(CompilerRegAssignState _ assignments) assignments])]
    [mask-state : CompilerRegAssignState
      (compiler-reg-assign-fixed-candidates
        (compiler-reg-special-candidates intervals mask-vars blocked)
        (compiler-reg-mask-registers)
        CompilerRegActiveNil
        vector-assignments
        (array.make-array i64 0)
        interval-index)]
    [assignments : CompilerRegAssignmentTable
      (match mask-state
        [(CompilerRegAssignState _ found) found])]
    ;; #3489 (PR2): the passes above assigned class ROOTS; expand so every member
    ;; inherits its root's location (realising the coalesce). SIMD/AVX has no
    ;; coalesce map, so this is the identity there.
    [final-assignments : CompilerRegAssignmentTable
      (if allow-caller-saved-zero-call
        (compiler-reg-rewrite-remat-assignments
          (compiler-reg-expand-class-assignments
            assignments
            coalesce
            (struct-get interval-index starts)
            (array.array-length (struct-get interval-index starts)))
          func
          coalesce
          call-save-shadows
          (array.array-length (struct-get interval-index starts)))
        assignments)]
    (CompilerRegPlan
      (compiler-reg-assignment-table-to-list final-assignments)
      ineligible
      intervals
      types
      call-save-shadows)))

;; SIMD/AVX register plan (unchanged from before #perf): full dataflow-liveness
;; intervals + the call-live-conservative ineligibility, keeping AVX backend
;; golden output byte-identical.
(define (compiler-reg-plan-function [func : CompilerIrFunction]) : CompilerRegPlan
  (let
    [liveness : CompilerFunctionLiveness (compiler-live-analyze-function func)]
    [type-info : CompilerRegVarTypes (compiler-reg-function-var-types func)]
    [types : CompilerRegVarTypeList (compiler-reg-var-types-list type-info)]
    [intervals : CompilerRegIntervalList
      (compiler-reg-live-intervals func liveness)]
    [ineligible : CompilerLiveI64Set
      (compiler-reg-ineligible-vars-simd func liveness types)]
    [vars : i64
      (match func
        [(IrFunction _ _ _ function-vars _) function-vars])]
    (compiler-reg-plan-from
      func
      type-info
      types
      intervals
      (compiler-reg-interval-index-build intervals vars)
      (compiler-reg-assignment-table-make vars)
      ineligible
      ineligible
      false
      CompilerRegAbiLinux)))

;; Scalar register plan (#perf, opt level 2): full dataflow live intervals for
;; small multi-block functions, structural ineligibility that keeps
;; call-spanning integers/handles in callee-saved registers, and
;; float-call-spanning exclusion for the caller-saved XMM pool. Single-block
;; functions cannot have loop-carried values; very large functions stay on the
;; cheap block-level interval builder to cap opt2 compiler cost.
(define (compiler-reg-scalar-full-interval-block-limit) : i64
  10)

(define (compiler-reg-scalar-full-intervals? [func : CompilerIrFunction]) : bool
  (match func
    [(IrFunction _ _ _ _ blocks)
      (let
        [count : i64 (compiler-ir-block-list-count blocks)]
        (and
          (> count 1)
          (<= count (compiler-reg-scalar-full-interval-block-limit))))]))

(define (compiler-reg-plan-function-scalar-for-abi
  [abi : CompilerRegTargetAbi]
  [func : CompilerIrFunction]) : CompilerRegPlan
  (let
    [type-info : CompilerRegVarTypes (compiler-reg-function-var-types func)]
    [types : CompilerRegVarTypeList (compiler-reg-var-types-list type-info)]
    [vars : i64
      (match func
        [(IrFunction _ _ _ function-vars _) function-vars])]
    [interval-selection : CompilerRegIntervalSelection
      (if (compiler-reg-scalar-full-intervals? func)
        (compiler-reg-live-interval-selection
          func
          (compiler-live-analyze-function func))
        (let
          [block-intervals : CompilerRegIntervalList
            (compiler-reg-block-intervals func)]
          (CompilerRegIntervalSelection
            block-intervals
            (compiler-reg-interval-index-build block-intervals vars))))]
    (match interval-selection
      [(CompilerRegIntervalSelection intervals interval-index)
        (let
          [base-ineligible : CompilerLiveI64Set
            (compiler-reg-mark-float-spanning
              intervals
              type-info
              (compiler-reg-call-points func)
              (compiler-reg-ineligible-vars-non-params
                func
                types
                (compiler-reg-arg-reg-limit-for-abi abi)))]
          [param-plan : CompilerRegParamAssignPlan
            (compiler-reg-param-assign-plan
              abi
              func
              interval-index
              base-ineligible
              vars)]
          (match param-plan
            [(CompilerRegParamAssignPlan preassignments ineligible blocked)
              (compiler-reg-plan-from
                func
                type-info
                types
                intervals
                interval-index
                preassignments
                ineligible
                blocked
                true
                abi)]))])))

(define (compiler-reg-plan-function-scalar [func : CompilerIrFunction]) : CompilerRegPlan
  (compiler-reg-plan-function-scalar-for-abi CompilerRegAbiLinux func))

;; Fast scalar backend plan: keep type discovery for emission decisions, but
;; leave values in their stack slots instead of spending compile time on liveness
;; and register assignment. AVX/vector backend modes still use full regalloc.
(define (compiler-reg-plan-function-stack-only [func : CompilerIrFunction]) : CompilerRegPlan
  (let
    [type-info : CompilerRegVarTypes (compiler-reg-function-var-types func)]
    (CompilerRegPlan
      CompilerRegAssignmentNil
      (compiler-live-set-empty)
      CompilerRegIntervalNil
      (compiler-reg-var-types-list type-info)
      (compiler-live-set-empty))))

;; --- stack-slot compaction and storage coloring (#2598) ---------------------
;; One frame slot per raw IR variable wastes most of the frame once register
;; allocation has moved many values into registers. The scalar pass renumbers
;; stack-resident scalar variables into a dense frame-slot prefix after regalloc,
;; preserving parameter ids for the prologue spill contract. A second pass colors
;; contiguous inline-storage ranges, sharing those range slots when their
;; AddrOf/Gep-derived pointer lifetimes are disjoint. Variables that already
;; have a register home receive free non-slot ids, and stack-homed register
;; groups are remapped by their word0 id; the backend places word1 in the
;; matching second var-region. Plans with no intervals (the stack-only opt0/opt1
;; path skips liveness) pass through unchanged. The result's slot count replaces
;; the raw var count in the backend's frame layout.
(defenum CompilerRegColoring
  (CompilerRegColoringNone)
  (CompilerRegColoringRemap (Array i64) i64))

;; Per-var slot-colorability flags: only values the register allocator could
;; legally home in one 64-bit register (scalars and 8-byte handles) are known
;; to occupy exactly one frame slot. Anything else (vectors, masks, inline
;; groups, unknown) is skipped by the scalar interval walk and then receives a
;; private dense slot if it still needs stack storage.
(define (compiler-reg-color-flags
  [types : CompilerRegVarTypeList]
  [flags : (Array bool)]) : unit
  (match types
    [(CompilerRegVarTypeNil) unit]
    [(CompilerRegVarTypeCons item rest)
      (match item
        [(CompilerRegVarType var ty)
          (begin
            (if (< var (array.array-length flags))
              (array.array-set!
                flags
                var
                (or
                  (compiler-reg-scalar-type? ty)
                  (compiler-reg-handle-type? ty)))
              unit)
            (compiler-reg-color-flags (box-get rest) flags))])]))

;; Sorted insert by (start, var): deterministic processing order.
;; In-place heapsort of an interval array by (start, var) -- deterministic
;; total order, O(n log n), no allocation beyond the array itself (the
;; insertion-sort cons spine it replaces allocated O(n^2) cells, which blew
;; the scratch arena on ~7000-var functions).
(define (compiler-reg-color-interval-before?
  [a : CompilerRegInterval]
  [b : CompilerRegInterval]) : bool
  (match a
    [(CompilerRegInterval a-var a-start _)
      (match b
        [(CompilerRegInterval b-var b-start _)
          (or (< a-start b-start) (and (= a-start b-start) (< a-var b-var)))])]))

(define (compiler-reg-color-interval-copy [item : CompilerRegInterval]) : CompilerRegInterval
  (match item
    [(CompilerRegInterval var start end) (CompilerRegInterval var start end)]))

(define (compiler-reg-color-sift-down
  [items : (Array CompilerRegInterval)]
  [root : i64]
  [count : i64]) : unit
  (let
    [node : i64 root]
    [done : bool false]
    (while (not done)
      (let
        [left : i64 (+ (* node 2) 1)]
        [right : i64 (+ (* node 2) 2)]
        [largest : i64
          (let
            [pick : i64 node]
            (begin
              (if (and
                (< left count)
                (compiler-reg-color-interval-before?
                  (array.array-ref items pick)
                  (array.array-ref items left)))
                (set! pick left)
                unit)
              (if (and
                (< right count)
                (compiler-reg-color-interval-before?
                  (array.array-ref items pick)
                  (array.array-ref items right)))
                (set! pick right)
                unit)
              pick))]
        (if (= largest node)
          (set! done true)
          (let
            [node-item : CompilerRegInterval
              (compiler-reg-color-interval-copy (array.array-ref items node))]
            [largest-item : CompilerRegInterval
              (compiler-reg-color-interval-copy (array.array-ref items largest))]
            (begin
              (array.array-set! items node largest-item)
              (array.array-set! items largest node-item)
              (set! node largest))))))))

(define (compiler-reg-color-heapsort
  [items : (Array CompilerRegInterval)]
  [count : i64]) : unit
  (begin
    (let
      [i : i64 (- (/ count 2) 1)]
      (while (>= i 0)
        (begin
          (compiler-reg-color-sift-down items i count)
          (set! i (- i 1)))))
    (let
      [last : i64 (- count 1)]
      (while (> last 0)
        (let
          [root-item : CompilerRegInterval
            (compiler-reg-color-interval-copy (array.array-ref items 0))]
          [last-item : CompilerRegInterval
            (compiler-reg-color-interval-copy (array.array-ref items last))]
          (begin
            (array.array-set! items 0 last-item)
            (array.array-set! items last root-item)
            (compiler-reg-color-sift-down items 0 last)
            (set! last (- last 1))))))))

(define (compiler-reg-color-interval-count
  [intervals : CompilerRegIntervalList]) : i64
  (match intervals
    [(CompilerRegIntervalNil) 0]
    [(CompilerRegIntervalCons _ rest)
      (+ 1 (compiler-reg-color-interval-count (box-get rest)))]))

(define (compiler-reg-color-interval-fill
  [intervals : CompilerRegIntervalList]
  [items : (Array CompilerRegInterval)]
  [index : i64]) : unit
  (match intervals
    [(CompilerRegIntervalNil) unit]
    [(CompilerRegIntervalCons head rest)
      (begin
        (array.array-set! items index head)
        (compiler-reg-color-interval-fill (box-get rest) items (+ index 1)))]))

(define (compiler-reg-color-sorted-array [intervals : CompilerRegIntervalList]) : (Array
    CompilerRegInterval)
  (let
    [count : i64 (compiler-reg-color-interval-count intervals)]
    [items : (Array CompilerRegInterval)
      (array.make-array CompilerRegInterval count)]
    (begin
      (compiler-reg-color-interval-fill intervals items 0)
      (compiler-reg-color-heapsort items count)
      items)))

;; Per-variable full lifetime end over all split live intervals. The scalar
;; coloring walk assigns each variable one remapped frame slot, so a slot must
;; stay busy until that variable's last interval ends, even if the interval list
;; has a hole before a later use.
(define (compiler-reg-color-extent-ends
  [items : (Array CompilerRegInterval)]
  [vars : i64]) : (Array i64)
  (let
    [ends : (Array i64) (array.make-array i64 vars)]
    [i : i64 0]
    (begin
      (while (< i vars)
        (begin
          (array.array-set! ends i (- 0 1))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i (array.array-length items))
        (match (array.array-ref items i)
          [(CompilerRegInterval var _ end)
            (begin
              (if (and
                (>= var 0)
                (< var vars)
                (> end (array.array-ref ends var)))
                (array.array-set! ends var end)
                unit)
              (set! i (+ i 1)))]))
      ends)))

;; First slot id at or after `from` that is not identity-pinned to a
;; parameter (pins mark slot-ends with i64-max). Fresh slots fill the gaps a
;; sparse parameter id leaves behind, so slot ids never run past the pinned
;; band and the overall renumbering stays inside [0, vars).
(define (compiler-reg-color-next-free-slot
  [slot-ends : (Array i64)]
  [from : i64]) : i64
  (if (>= from (array.array-length slot-ends))
    from
    (if (= (array.array-ref slot-ends from) 9223372036854775807)
      (compiler-reg-color-next-free-slot slot-ends (+ from 1))
      from)))

;; Lowest used slot whose previous occupant ended strictly before `start`.
;; STRICT `<`: phi parallel copies at a block edge read inputs and write
;; destinations at the same interval position, so same-position reuse would let
;; one phi's destination clobber another phi's not-yet-read input through the
;; slot. Parameter pins use i64-max in slot-ends and therefore never match.
(define (compiler-reg-color-find-slot
  [slot-ends : (Array i64)]
  [used : i64]
  [start : i64]
  [index : i64]) : i64
  (if (>= index used)
    used
    (if (< (array.array-ref slot-ends index) start)
      index
      (compiler-reg-color-find-slot slot-ends used start (+ index 1)))))

(define (compiler-reg-color-walk
  [items : (Array CompilerRegInterval)]
  [count : i64]
  [index : i64]
  [assignment-index : CompilerRegAssignmentIndex]
  [pinned : CompilerLiveI64Set]
  [ineligible : CompilerLiveI64Set]
  [colorable : (Array bool)]
  [slot-ends : (Array i64)]
  [extent-ends : (Array i64)]
  [used : i64]
  [remap : (Array i64)]) : i64
  (if (>= index count)
    used
    (match (array.array-ref items index)
      [(CompilerRegInterval var start end)
        (if (or
          ;; Already renumbered: parameter identity pins (the prologue's
          ;; param spill targets the ORIGINAL id's formula slot, so a pinned
          ;; id must never be reassigned mid-walk) and split intervals (the
          ;; first interval wins; revisiting would leak the first slot).
          (>= (array.array-ref remap var) 0)
          (not (array.array-ref colorable var))
          (compiler-live-set-contains? pinned var)
          (compiler-live-set-contains? ineligible var)
          ;; Spilled scalars are re-homed by the id remap (the stale
          ;; assignment entry keyed by the old id is never queried);
          ;; register-homed values keep their ids and homes.
          (match (compiler-reg-assignment-index-lookup assignment-index var)
            [(CompilerRegSomeLocation location)
              (match location
                [(CompilerRegSpill _) false]
                [_ true])]
            [(CompilerRegNoLocation) false]))
          (compiler-reg-color-walk
            items
            count
            (+ index 1)
            assignment-index
            pinned
            ineligible
            colorable
            slot-ends
            extent-ends
            used
            remap)
          (let
            ;; Prefer the lowest same-size scalar slot whose prior owner ended
            ;; before this variable starts. Otherwise take a fresh slot,
            ;; skipping param-pinned ids so sparse parameter ids leave no hole.
            [found : i64 (compiler-reg-color-find-slot slot-ends used start 0)]
            [slot : i64
              (if (>= found used)
                (compiler-reg-color-next-free-slot slot-ends used)
                found)]
            [next-used : i64
              (if (>= found used)
                (+ slot 1)
                used)]
            [full-end : i64
              (compiler-reg-max end (array.array-ref extent-ends var))]
            (begin
              (array.array-set! slot-ends slot full-end)
              (array.array-set! remap var slot)
              (compiler-reg-color-walk
                items
                count
                (+ index 1)
                assignment-index
                pinned
                ineligible
                colorable
                slot-ends
                extent-ends
                next-used
                remap))))])))

(define (compiler-reg-color-fill-interval-bounds
  [intervals : CompilerRegIntervalList]
  [starts : (Array i64)]
  [ends : (Array i64)]) : unit
  (match intervals
    [(CompilerRegIntervalNil) unit]
    [(CompilerRegIntervalCons head rest)
      (begin
        (match head
          [(CompilerRegInterval var start end)
            (if (and (>= var 0) (< var (array.array-length starts)))
              (begin
                (array.array-set! starts var start)
                (array.array-set! ends var end))
              unit)])
        (compiler-reg-color-fill-interval-bounds (box-get rest) starts ends))]))

(define (compiler-reg-color-mark-storage-vars
  [range-of-var : (Array i64)]
  [first : i64]
  [count : i64]
  [range-id : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (if (and
          (>= (+ first i) 0)
          (< (+ first i) (array.array-length range-of-var)))
          (array.array-set! range-of-var (+ first i) range-id)
          unit)
        (set! i (+ i 1))))))

(define (compiler-reg-color-detect-storage-seq
  [instrs : CompilerIrInstrSeq]
  [range-of-var : (Array i64)]
  [range-base : (Array i64)]
  [range-size : (Array i64)]
  [range-count : i64]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [len : i64 (compiler-ir-instr-seq-count instrs)]
    [i : i64 0]
    [run-first : i64 (- 0 1)]
    [run-last : i64 (- 0 1)]
    [run-count : i64 0]
    [ranges : i64 range-count]
    (begin
      (while (< i len)
        (begin
          (match (array.array-ref slots i)
            [(IrInstrAlloc dst _)
              (if (or (= run-count 0) (= dst (+ run-last 1)))
                (begin
                  (if (= run-count 0)
                    (set! run-first dst)
                    unit)
                  (set! run-last dst)
                  (set! run-count (+ run-count 1)))
                (begin
                  (set! run-first dst)
                  (set! run-last dst)
                  (set! run-count 1)))]
            [(IrInstrAddrOf _ src)
              (begin
                (if (and
                  (> run-count 0)
                  (= src run-last)
                  (= run-first (+ (- src run-count) 1))
                  (< ranges (array.array-length range-base)))
                  (begin
                    (array.array-set! range-base ranges src)
                    (array.array-set! range-size ranges run-count)
                    (compiler-reg-color-mark-storage-vars
                      range-of-var
                      run-first
                      run-count
                      ranges)
                    (set! ranges (+ ranges 1)))
                  unit)
                (set! run-first (- 0 1))
                (set! run-last (- 0 1))
                (set! run-count 0))]
            [_
              (begin
                (set! run-first (- 0 1))
                (set! run-last (- 0 1))
                (set! run-count 0))])
          (set! i (+ i 1))))
      ranges)))

(define (compiler-reg-color-detect-storage-blocks
  [blocks : CompilerIrBlockList]
  [range-of-var : (Array i64)]
  [range-base : (Array i64)]
  [range-size : (Array i64)]
  [range-count : i64]) : i64
  (match blocks
    [(IrBlockNil) range-count]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-reg-color-detect-storage-blocks
            (box-get rest)
            range-of-var
            range-base
            range-size
            (compiler-reg-color-detect-storage-seq
              instrs
              range-of-var
              range-base
              range-size
              range-count))])]
    [(IrBlockArray seq)
      (let
        [i : i64 0]
        [count : i64 range-count]
        (begin
          (while (< i (compiler-ir-block-seq-count seq))
            (begin
              (match (compiler-ir-block-seq-ref seq i)
                [(IrBlock _ instrs)
                  (set!
                    count
                    (compiler-reg-color-detect-storage-seq
                      instrs
                      range-of-var
                      range-base
                      range-size
                      count))])
              (set! i (+ i 1))))
          count))]))

(define (compiler-reg-color-value-root
  [roots : (Array i64)]
  [value : CompilerIrValue]) : i64
  (match value
    [(IrValueVar var)
      (if (and (>= var 0) (< var (array.array-length roots)))
        (array.array-ref roots var)
        (- 0 1))]
    [_ (- 0 1)]))

(define (compiler-reg-color-merge-root [acc : i64] [root : i64]) : i64
  (cond
    [(< root 0) (- 0 1)]
    [(< acc 0) root]
    [(= acc root) root]
    [else (- 0 2)]))

(define (compiler-reg-color-value-list-root
  [roots : (Array i64)]
  [values : CompilerIrValueList]
  [acc : i64]) : i64
  (match values
    [(IrValueNil) acc]
    [(IrValueCons value rest)
      (let
        [next : i64
          (compiler-reg-color-merge-root
            acc
            (compiler-reg-color-value-root roots value))]
        (if (= next (- 0 1))
          (- 0 1)
          (if (= next (- 0 2))
            (- 0 2)
            (compiler-reg-color-value-list-root roots (box-get rest) next))))]))

(define (compiler-reg-color-phi-root
  [roots : (Array i64)]
  [inputs : CompilerIrPhiInputList]
  [acc : i64]) : i64
  (match inputs
    [(IrPhiInputNil) acc]
    [(IrPhiInputCons value _ rest)
      (let
        [next : i64
          (compiler-reg-color-merge-root
            acc
            (compiler-reg-color-value-root roots value))]
        (if (= next (- 0 1))
          (- 0 1)
          (if (= next (- 0 2))
            (- 0 2)
            (compiler-reg-color-phi-root roots (box-get rest) next))))]))

(define (compiler-reg-color-set-root!
  [roots : (Array i64)]
  [invalid : (Array bool)]
  [dst : i64]
  [root : i64]) : bool
  (if (or (< root 0) (< dst 0) (>= dst (array.array-length roots)))
    false
    (let
      [old : i64 (array.array-ref roots dst)]
      (if (= old root)
        false
        (if (< old 0)
          (begin
            (array.array-set! roots dst root)
            true)
          (begin
            (if (< old (array.array-length invalid))
              (array.array-set! invalid old true)
              unit)
            (if (< root (array.array-length invalid))
              (array.array-set! invalid root true)
              unit)
            (array.array-set! roots dst (- 0 2))
            true))))))

(define (compiler-reg-color-propagate-root-instr
  [instr : CompilerIrInstr]
  [range-of-var : (Array i64)]
  [roots : (Array i64)]
  [invalid : (Array bool)]) : bool
  (match instr
    [(IrInstrAddrOf dst src)
      (if (and (>= src 0) (< src (array.array-length range-of-var)))
        (compiler-reg-color-set-root!
          roots
          invalid
          dst
          (array.array-ref range-of-var src))
        false)]
    [(IrInstrGep dst base _ _)
      (compiler-reg-color-set-root!
        roots
        invalid
        dst
        (compiler-reg-color-value-root roots base))]
    [(IrInstrMov dst value _)
      (compiler-reg-color-set-root!
        roots
        invalid
        dst
        (compiler-reg-color-value-root roots value))]
    [(IrInstrPhi dst inputs _)
      (compiler-reg-color-set-root!
        roots
        invalid
        dst
        (compiler-reg-color-phi-root roots inputs (- 0 1)))]
    [(IrInstrSelect payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload dst _ true-value false-value _ _)
          (let
            [left : i64 (compiler-reg-color-value-root roots true-value)]
            [right : i64 (compiler-reg-color-value-root roots false-value)]
            (if (>= right 0)
              (compiler-reg-color-set-root! roots invalid dst right)
              (if (and (>= left 0) (= left right))
                (compiler-reg-color-set-root! roots invalid dst left)
                false)))])]
    [_ false]))

(define (compiler-reg-color-propagate-root-seq
  [instrs : CompilerIrInstrSeq]
  [range-of-var : (Array i64)]
  [roots : (Array i64)]
  [invalid : (Array bool)]) : bool
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [len : i64 (compiler-ir-instr-seq-count instrs)]
    [i : i64 0]
    [changed : bool false]
    (begin
      (while (< i len)
        (begin
          (if (compiler-reg-color-propagate-root-instr
            (array.array-ref slots i)
            range-of-var
            roots
            invalid)
            (set! changed true)
            unit)
          (set! i (+ i 1))))
      changed)))

(define (compiler-reg-color-propagate-root-blocks
  [blocks : CompilerIrBlockList]
  [range-of-var : (Array i64)]
  [roots : (Array i64)]
  [invalid : (Array bool)]) : bool
  (match blocks
    [(IrBlockNil) false]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (let
            [head : bool
              (compiler-reg-color-propagate-root-seq
                instrs
                range-of-var
                roots
                invalid)]
            [tail : bool
              (compiler-reg-color-propagate-root-blocks
                (box-get rest)
                range-of-var
                roots
                invalid)]
            (or head tail))])]
    [(IrBlockArray seq)
      (let
        [i : i64 0]
        [changed : bool false]
        (begin
          (while (< i (compiler-ir-block-seq-count seq))
            (begin
              (match (compiler-ir-block-seq-ref seq i)
                [(IrBlock _ instrs)
                  (if (compiler-reg-color-propagate-root-seq
                    instrs
                    range-of-var
                    roots
                    invalid)
                    (set! changed true)
                    unit)])
              (set! i (+ i 1))))
          changed))]))

(define (compiler-reg-color-propagate-roots
  [blocks : CompilerIrBlockList]
  [range-of-var : (Array i64)]
  [roots : (Array i64)]
  [invalid : (Array bool)]) : unit
  (let
    [changed : bool true]
    [rounds : i64 0]
    [limit : i64 (array.array-length roots)]
    (while (and changed (< rounds limit))
      (begin
        (set!
          changed
          (compiler-reg-color-propagate-root-blocks
            blocks
            range-of-var
            roots
            invalid))
        (set! rounds (+ rounds 1))))))

(define (compiler-reg-color-invalidate-root!
  [invalid : (Array bool)]
  [root : i64]) : unit
  (if (and (>= root 0) (< root (array.array-length invalid)))
    (array.array-set! invalid root true)
    unit))

(define (compiler-reg-color-invalidate-value!
  [roots : (Array i64)]
  [invalid : (Array bool)]
  [value : CompilerIrValue]) : unit
  (compiler-reg-color-invalidate-root!
    invalid
    (compiler-reg-color-value-root roots value)))

(define (compiler-reg-color-invalidate-maybe-value!
  [roots : (Array i64)]
  [invalid : (Array bool)]
  [value : CompilerIrMaybeValue]) : unit
  (match value
    [(IrNoValue) unit]
    [(IrSomeValue inner)
      (compiler-reg-color-invalidate-value! roots invalid inner)]))

(define (compiler-reg-color-invalidate-value-list!
  [roots : (Array i64)]
  [invalid : (Array bool)]
  [values : CompilerIrValueList]) : unit
  (match values
    [(IrValueNil) unit]
    [(IrValueCons value rest)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid value)
        (compiler-reg-color-invalidate-value-list! roots invalid (box-get rest)))]))

(define (compiler-reg-color-invalidate-call-args!
  [roots : (Array i64)]
  [invalid : (Array bool)]
  [args : CompilerIrCallArgs]) : unit
  (match args
    [(IrCallArgsNil) unit]
    [(IrCallArgsOne a) (compiler-reg-color-invalidate-value! roots invalid a)]
    [(IrCallArgsTwo a b)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid a)
        (compiler-reg-color-invalidate-value! roots invalid b))]
    [(IrCallArgsArray items)
      (let
        [i : i64 0]
        [len : i64 (array.array-length items)]
        (while (< i len)
          (begin
            (compiler-reg-color-invalidate-value!
              roots
              invalid
              (array.array-ref items i))
            (set! i (+ i 1)))))]))

(define (compiler-reg-color-invalidate-phi!
  [roots : (Array i64)]
  [invalid : (Array bool)]
  [dst-root : i64]
  [inputs : CompilerIrPhiInputList]) : unit
  (match inputs
    [(IrPhiInputNil) unit]
    [(IrPhiInputCons value _ rest)
      (let
        [root : i64 (compiler-reg-color-value-root roots value)]
        (begin
          (if (and (>= root 0) (not (= root dst-root)))
            (compiler-reg-color-invalidate-root! invalid root)
            unit)
          (compiler-reg-color-invalidate-phi!
            roots
            invalid
            dst-root
            (box-get rest))))]))

(define (compiler-reg-color-invalidate-instr!
  [instr : CompilerIrInstr]
  [roots : (Array i64)]
  [invalid : (Array bool)]) : unit
  (match instr
    [(IrInstrMov dst value _)
      (let
        [root : i64 (compiler-reg-color-value-root roots value)]
        (if (and
          (>= root 0)
          (or
            (>= dst (array.array-length roots))
            (not (= (array.array-ref roots dst) root))))
          (compiler-reg-color-invalidate-root! invalid root)
          unit))]
    [(IrInstrGep dst base _ _)
      (let
        [root : i64 (compiler-reg-color-value-root roots base)]
        (if (and
          (>= root 0)
          (or
            (>= dst (array.array-length roots))
            (not (= (array.array-ref roots dst) root))))
          (compiler-reg-color-invalidate-root! invalid root)
          unit))]
    [(IrInstrStorePtr dst src _)
      (compiler-reg-color-invalidate-value! roots invalid src)]
    [(IrInstrBoundsCheck index length _)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid index)
        (compiler-reg-color-invalidate-value! roots invalid length))]
    [(IrInstrCast _ src _ _)
      (compiler-reg-color-invalidate-value! roots invalid src)]
    [(IrInstrBitcast _ src _ _)
      (compiler-reg-color-invalidate-value! roots invalid src)]
    [(IrInstrBinOp _ _ lhs rhs _)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid lhs)
        (compiler-reg-color-invalidate-value! roots invalid rhs))]
    [(IrInstrUnOp _ _ value _)
      (compiler-reg-color-invalidate-value! roots invalid value)]
    [(IrInstrSplat _ value _ _)
      (compiler-reg-color-invalidate-value! roots invalid value)]
    [(IrInstrVectorBinOp payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorBinOpPayload _ _ lhs rhs _ _)
          (begin
            (compiler-reg-color-invalidate-value! roots invalid lhs)
            (compiler-reg-color-invalidate-value! roots invalid rhs))])]
    [(IrInstrVectorReduce _ _ src _ _)
      (compiler-reg-color-invalidate-value! roots invalid src)]
    [(IrInstrVectorCompare payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorComparePayload _ _ lhs rhs _ _)
          (begin
            (compiler-reg-color-invalidate-value! roots invalid lhs)
            (compiler-reg-color-invalidate-value! roots invalid rhs))])]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid lhs)
        (compiler-reg-color-invalidate-value! roots invalid rhs))]
    [(IrInstrMaskNot _ src _)
      (compiler-reg-color-invalidate-value! roots invalid src)]
    [(IrInstrMaskReduce _ _ src _)
      (compiler-reg-color-invalidate-value! roots invalid src)]
    [(IrInstrSelect payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload dst mask true-value false-value _ _)
          (let
            [left : i64 (compiler-reg-color-value-root roots true-value)]
            [right : i64 (compiler-reg-color-value-root roots false-value)]
            [dst-root : i64
              (if (and (>= dst 0) (< dst (array.array-length roots)))
                (array.array-ref roots dst)
                (- 0 1))]
            (begin
              (compiler-reg-color-invalidate-value! roots invalid mask)
              (if (and (>= left 0) (not (= left dst-root)))
                (compiler-reg-color-invalidate-root! invalid left)
                unit)
              (if (and (>= right 0) (not (= right dst-root)))
                (compiler-reg-color-invalidate-root! invalid right)
                unit)))])]
    [(IrInstrVectorLoad _ base index _ _)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid base)
        (compiler-reg-color-invalidate-value! roots invalid index))]
    [(IrInstrVectorStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorStorePayload base index value _ _)
          (begin
            (compiler-reg-color-invalidate-value! roots invalid base)
            (compiler-reg-color-invalidate-value! roots invalid index)
            (compiler-reg-color-invalidate-value! roots invalid value))])]
    [(IrInstrPredicatedStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedStorePayload base index value mask _ _)
          (begin
            (compiler-reg-color-invalidate-value! roots invalid base)
            (compiler-reg-color-invalidate-value! roots invalid index)
            (compiler-reg-color-invalidate-value! roots invalid value)
            (compiler-reg-color-invalidate-value! roots invalid mask))])]
    [(IrInstrPredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload _ base index mask _ _)
          (begin
            (compiler-reg-color-invalidate-value! roots invalid base)
            (compiler-reg-color-invalidate-value! roots invalid index)
            (compiler-reg-color-invalidate-value! roots invalid mask))])]
    [(IrInstrTailMask _ index length _)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid index)
        (compiler-reg-color-invalidate-value! roots invalid length))]
    [(IrInstrCpuId _ leaf subleaf _)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid leaf)
        (compiler-reg-color-invalidate-value! roots invalid subleaf))]
    [(IrInstrXgetbv _ index)
      (compiler-reg-color-invalidate-value! roots invalid index)]
    [(IrInstrSyscall _ args)
      (compiler-reg-color-invalidate-call-args! roots invalid args)]
    [(IrInstrCall _ name args _)
      (if (string.string-eq name "tl_memcpy")
        unit
        (compiler-reg-color-invalidate-call-args! roots invalid args))]
    [(IrInstrCallIndirect _ callee args _)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid callee)
        (compiler-reg-color-invalidate-call-args! roots invalid args))]
    [(IrInstrCallIndirectC _ callee args _)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid callee)
        (compiler-reg-color-invalidate-call-args! roots invalid args))]
    [(IrInstrCallCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallCAbiStoreResultPayload base _ args _)
          (begin
            (compiler-reg-color-invalidate-value! roots invalid base)
            (compiler-reg-color-invalidate-call-args! roots invalid args))])]
    [(IrInstrCallIndirectCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallIndirectCAbiStoreResultPayload base callee args _)
          (begin
            (compiler-reg-color-invalidate-value! roots invalid base)
            (compiler-reg-color-invalidate-value! roots invalid callee)
            (compiler-reg-color-invalidate-call-args! roots invalid args))])]
    [(IrInstrTailCall _ args _)
      (compiler-reg-color-invalidate-call-args! roots invalid args)]
    [(IrInstrStore _ value _)
      (compiler-reg-color-invalidate-value! roots invalid value)]
    [(IrInstrBranch value _ _)
      (compiler-reg-color-invalidate-value! roots invalid value)]
    [(IrInstrReturn value)
      (compiler-reg-color-invalidate-maybe-value! roots invalid value)]
    [(IrInstrPhi dst inputs _)
      (compiler-reg-color-invalidate-phi!
        roots
        invalid
        (if (and (>= dst 0) (< dst (array.array-length roots)))
          (array.array-ref roots dst)
          (- 0 1))
        inputs)]
    [_ unit]))

(define (compiler-reg-color-invalidate-seq!
  [instrs : CompilerIrInstrSeq]
  [roots : (Array i64)]
  [invalid : (Array bool)]) : unit
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [len : i64 (compiler-ir-instr-seq-count instrs)]
    [i : i64 0]
    (while (< i len)
      (begin
        (compiler-reg-color-invalidate-instr!
          (array.array-ref slots i)
          roots
          invalid)
        (set! i (+ i 1))))))

(define (compiler-reg-color-invalidate-blocks!
  [blocks : CompilerIrBlockList]
  [roots : (Array i64)]
  [invalid : (Array bool)]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (begin
        (match block
          [(IrBlock _ instrs)
            (compiler-reg-color-invalidate-seq! instrs roots invalid)])
        (compiler-reg-color-invalidate-blocks! (box-get rest) roots invalid))]
    [(IrBlockArray seq)
      (let
        [i : i64 0]
        (while (< i (compiler-ir-block-seq-count seq))
          (begin
            (match (compiler-ir-block-seq-ref seq i)
              [(IrBlock _ instrs)
                (compiler-reg-color-invalidate-seq! instrs roots invalid)])
            (set! i (+ i 1)))))]))

(define (compiler-reg-color-range-liveness!
  [roots : (Array i64)]
  [starts : (Array i64)]
  [ends : (Array i64)]
  [range-starts : (Array i64)]
  [range-ends : (Array i64)]) : unit
  (let
    [i : i64 0]
    [_max-start : i64 9223372036854775807]
    (while (< i (array.array-length roots))
      (let
        [root : i64 (array.array-ref roots i)]
        (begin
          (if (and (>= root 0) (< root (array.array-length range-starts)))
            (let
              [start : i64 (array.array-ref starts i)]
              [end : i64 (array.array-ref ends i)]
              (if (>= start 0)
                (begin
                  (if (< start (array.array-ref range-starts root))
                    (array.array-set! range-starts root start)
                    unit)
                  (if (> end (array.array-ref range-ends root))
                    (array.array-set! range-ends root end)
                    unit))
                unit))
            unit)
          (set! i (+ i 1)))))))

(define (compiler-reg-color-range-free?
  [slot-ends : (Array i64)]
  [slot : i64]
  [size : i64]
  [start : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (if (> (+ slot size) (array.array-length slot-ends))
        (set! ok false)
        unit)
      (while (and ok (< i size))
        (begin
          (if (< (array.array-ref slot-ends (+ slot i)) start)
            unit
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (compiler-reg-color-next-free-range
  [slot-ends : (Array i64)]
  [from : i64]
  [size : i64]
  [start : i64]) : i64
  (let
    [slot : i64 from]
    [done : bool false]
    (begin
      (while (not done)
        (if (compiler-reg-color-range-free? slot-ends slot size start)
          (set! done true)
          (set! slot (+ slot 1))))
      slot)))

(define (compiler-reg-color-set-range-ends!
  [slot-ends : (Array i64)]
  [slot : i64]
  [size : i64]
  [end : i64]) : unit
  (let
    [i : i64 0]
    (while (< i size)
      (begin
        (if (< (+ slot i) (array.array-length slot-ends))
          (array.array-set! slot-ends (+ slot i) end)
          unit)
        (set! i (+ i 1))))))

(define (compiler-reg-color-remap-storage-range!
  [remap : (Array i64)]
  [base : i64]
  [size : i64]
  [slot : i64]) : unit
  (let
    [first : i64 (+ (- base size) 1)]
    [i : i64 0]
    (while (< i size)
      (begin
        (if (and (>= (+ first i) 0) (< (+ first i) (array.array-length remap)))
          (array.array-set! remap (+ first i) (+ slot i))
          unit)
        (set! i (+ i 1))))))

(define (compiler-reg-color-range-clear?
  [remap : (Array i64)]
  [base : i64]
  [size : i64]) : bool
  (let
    [first : i64 (+ (- base size) 1)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< i size))
        (begin
          (if (and
            (>= (+ first i) 0)
            (< (+ first i) (array.array-length remap))
            (< (array.array-ref remap (+ first i)) 0))
            unit
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (compiler-reg-color-storage-ranges
  [slot-ends : (Array i64)]
  [remap : (Array i64)]
  [range-base : (Array i64)]
  [range-size : (Array i64)]
  [range-starts : (Array i64)]
  [range-ends : (Array i64)]
  [invalid : (Array bool)]
  [range-count : i64]
  [from : i64]) : i64
  (let
    [range : i64 0]
    [used : i64 from]
    [max-start : i64 9223372036854775807]
    (begin
      (while (< range range-count)
        (let
          [start : i64 (array.array-ref range-starts range)]
          [end : i64 (array.array-ref range-ends range)]
          [size : i64 (array.array-ref range-size range)]
          [base : i64 (array.array-ref range-base range)]
          (begin
            (if (and
              (not (array.array-ref invalid range))
              (< start max-start)
              (>= end start)
              (> size 0)
              (compiler-reg-color-range-clear? remap base size))
              (let
                [slot : i64
                  (compiler-reg-color-next-free-range slot-ends from size start)]
                (begin
                  (compiler-reg-color-set-range-ends! slot-ends slot size end)
                  (compiler-reg-color-remap-storage-range! remap base size slot)
                  (if (> (+ slot size) used)
                    (set! used (+ slot size))
                    unit)))
              unit)
            (set! range (+ range 1)))))
      used)))

;; Color only contiguous inline-storage ranges. These slots are addressed only
;; through AddrOf/Gep-derived pointers, so ranges may share ids with each other
;; when their pointer lifetimes are disjoint. They deliberately start after the
;; scalar stack prefix to avoid giving a real scalar value and an aggregate
;; storage word the same global type-table key.
(define (compiler-reg-color-inline-storage
  [blocks : CompilerIrBlockList]
  [intervals : CompilerRegIntervalList]
  [slot-ends : (Array i64)]
  [remap : (Array i64)]
  [vars : i64]
  [from : i64]) : i64
  (let
    [range-of-var : (Array i64) (array.make-array i64 vars)]
    [range-base : (Array i64) (array.make-array i64 vars)]
    [range-size : (Array i64) (array.make-array i64 vars)]
    [range-starts : (Array i64) (array.make-array i64 vars)]
    [range-ends : (Array i64) (array.make-array i64 vars)]
    [invalid : (Array bool) (array.make-array bool vars)]
    [roots : (Array i64) (array.make-array i64 vars)]
    [starts : (Array i64) (array.make-array i64 vars)]
    [ends : (Array i64) (array.make-array i64 vars)]
    [max-start : i64 9223372036854775807]
    [_cleared : unit
      (let
        [i : i64 0]
        (while (< i vars)
          (begin
            (array.array-set! range-of-var i (- 0 1))
            (array.array-set! range-base i (- 0 1))
            (array.array-set! range-size i 0)
            (array.array-set! range-starts i max-start)
            (array.array-set! range-ends i (- 0 1))
            (array.array-set! invalid i false)
            (array.array-set! roots i (- 0 1))
            (array.array-set! starts i (- 0 1))
            (array.array-set! ends i (- 0 1))
            (set! i (+ i 1)))))]
    [range-count : i64
      (compiler-reg-color-detect-storage-blocks
        blocks
        range-of-var
        range-base
        range-size
        0)]
    (if (= range-count 0)
      from
      (begin
        (compiler-reg-color-fill-interval-bounds intervals starts ends)
        (compiler-reg-color-propagate-roots blocks range-of-var roots invalid)
        (compiler-reg-color-invalidate-blocks! blocks roots invalid)
        (compiler-reg-color-range-liveness!
          roots
          starts
          ends
          range-starts
          range-ends)
        (compiler-reg-color-storage-ranges
          slot-ends
          remap
          range-base
          range-size
          range-starts
          range-ends
          invalid
          range-count
          from)))))

;; Rebuild the var-type table on remapped keys. Type and assignment lookups
;; early-exit on the ascending-id list invariant, so remapping keys in place
;; would silently break every lookup past the first out-of-order entry
;; (observed: register homes lost to formula-slot fallbacks and i64 compares
;; emitted as cmpb once the width lookup missed). Scatter the entries into
;; new-id-indexed arrays and rebuild the list in id order instead. Storage-range
;; coloring may alias multiple old inline-storage vars onto the same new id, but
;; those ids are never used as scalar value keys; later entries may overwrite the
;; unused storage type without affecting emission.
(define (compiler-reg-color-scatter-types
  [remap : (Array i64)]
  [present : (Array i64)]
  [items : (Array AstType)]
  [types : CompilerRegVarTypeList]) : unit
  (match types
    [(CompilerRegVarTypeNil) unit]
    [(CompilerRegVarTypeCons item rest)
      (begin
        (match item
          [(CompilerRegVarType var ty)
            (compiler-reg-var-type-array-set!
              present
              items
              (compiler-reg-remap-id remap var)
              ty)])
        (compiler-reg-color-scatter-types remap present items (box-get rest)))]))

(define (compiler-reg-color-rebuild-types
  [remap : (Array i64)]
  [vars : i64]
  [types : CompilerRegVarTypeList]) : CompilerRegVarTypeList
  (let
    [present : (Array i64) (array.make-array i64 vars)]
    [items : (Array AstType) (array.make-array AstType vars)]
    (begin
      (compiler-reg-fill-i64-array present 0)
      (compiler-reg-color-scatter-types remap present items types)
      (compiler-reg-var-type-arrays-to-list
        present
        items
        (- vars 1)
        CompilerRegVarTypeNil))))

;; Spilled scalars are dropped: the id remap re-homes them, so emission's
;; formula-slot fallback covers the new id and a stale Spill offset keyed by
;; the old id must never shadow it.
(define (compiler-reg-color-scatter-assignments
  [remap : (Array i64)]
  [present : (Array i64)]
  [items : (Array CompilerRegLocation)]
  [assignments : CompilerRegAssignmentList]) : unit
  (match assignments
    [(CompilerRegAssignmentNil) unit]
    [(CompilerRegAssignmentCons item rest)
      (begin
        (match item
          [(CompilerRegAssignment var location)
            (match location
              [(CompilerRegSpill _) unit]
              [_
                (let
                  [new-id : i64 (compiler-reg-remap-id remap var)]
                  (if (and
                    (>= new-id 0)
                    (< new-id (array.array-length present)))
                    (begin
                      (array.array-set! present new-id 1)
                      (array.array-set! items new-id location))
                    unit))])])
        (compiler-reg-color-scatter-assignments
          remap
          present
          items
          (box-get rest)))]))

(define (compiler-reg-assignment-arrays-to-list
  [present : (Array i64)]
  [items : (Array CompilerRegLocation)]
  [index : i64]
  [acc : CompilerRegAssignmentList]) : CompilerRegAssignmentList
  (if (< index 0)
    acc
    (compiler-reg-assignment-arrays-to-list
      present
      items
      (- index 1)
      (if (= (array.array-ref present index) 0)
        acc
        (compiler-reg-assignment-cons
          (CompilerRegAssignment index (array.array-ref items index))
          acc)))))

(define (compiler-reg-color-rebuild-assignments
  [remap : (Array i64)]
  [vars : i64]
  [assignments : CompilerRegAssignmentList]) : CompilerRegAssignmentList
  (let
    [present : (Array i64) (array.make-array i64 vars)]
    [items : (Array CompilerRegLocation)
      (array.make-array CompilerRegLocation vars)]
    (begin
      (compiler-reg-fill-i64-array present 0)
      (compiler-reg-fill-location-array items (CompilerRegSpill 0))
      (compiler-reg-color-scatter-assignments remap present items assignments)
      (compiler-reg-assignment-arrays-to-list
        present
        items
        (- vars 1)
        CompilerRegAssignmentNil))))

;; Identity-pin parameter variables: the prologue's param spill writes each
;; parameter to the formula slot of its ORIGINAL id (the ABI hand-off
;; contract), so params keep their ids and their slots are never shared.
(define (compiler-reg-color-param-pins
  [params : CompilerIrParamList]
  [remap : (Array i64)]
  [slot-ends : (Array i64)]
  [highest : i64]) : i64
  (match params
    [(IrParamNil) highest]
    [(IrParamCons param rest)
      (match param
        [(IrParam _ _ var-id)
          (begin
            (if (< var-id (array.array-length remap))
              (begin
                (array.array-set! remap var-id var-id)
                (array.array-set! slot-ends var-id 9223372036854775807))
              unit)
            (compiler-reg-color-param-pins
              (box-get rest)
              remap
              slot-ends
              (compiler-reg-max highest (+ var-id 1))))])]))

;; Total frame renumbering: colorable stack scalars share slots when their
;; intervals are disjoint, colorable inline-storage ranges are shared above
;; that scalar prefix, every remaining slot-resident variable gets a private
;; dense slot above them, and register-homed variables move to ids that are not
;; used by a stack slot. The assignment table is rebuilt on the new keys.
(define (compiler-reg-color-stack-slots
  [plan : CompilerRegPlan]
  [group-vars : CompilerLiveI64Set]
  [params : CompilerIrParamList]
  [blocks : CompilerIrBlockList]
  [vars : i64]) : CompilerRegColoring
  (let
    [intervals : CompilerRegIntervalList (compiler-reg-plan-intervals plan)]
    (match intervals
      [(CompilerRegIntervalNil) CompilerRegColoringNone]
      [(CompilerRegIntervalCons _ _)
        (let
          [slots : i64 (+ vars 4)]
          [slot-ends : (Array i64) (array.make-array i64 slots)]
          [assignments : CompilerRegAssignmentList
            (compiler-reg-plan-assignments plan)]
          [assignment-index : CompilerRegAssignmentIndex
            (compiler-reg-assignment-index-build assignments vars)]
          [ineligible : CompilerLiveI64Set (compiler-reg-plan-ineligible plan)]
          [colorable : (Array bool) (array.make-array bool vars)]
          [remap : (Array i64) (array.make-array i64 vars)]
          [_cleared : unit
            (let
              [i : i64 0]
              (begin
                (while (< i slots)
                  (begin
                    (array.array-set! slot-ends i (- 0 1))
                    (set! i (+ i 1))))
                (set! i 0)
                (while (< i vars)
                  (begin
                    (array.array-set! colorable i false)
                    (array.array-set! remap i (- 0 1))
                    (set! i (+ i 1))))))]
          [_flagged : unit
            (compiler-reg-color-flags (compiler-reg-plan-types plan) colorable)]
          [param-floor : i64
            (compiler-reg-color-param-pins params remap slot-ends 0)]
          [sorted : (Array CompilerRegInterval)
            (compiler-reg-color-sorted-array intervals)]
          [extent-ends : (Array i64)
            (compiler-reg-color-extent-ends sorted vars)]
          [stack-prefix : i64
            (compiler-reg-color-walk
              sorted
              (array.array-length sorted)
              0
              assignment-index
              group-vars
              ineligible
              colorable
              slot-ends
              extent-ends
              0
              remap)]
          [storage-prefix : i64
            (compiler-reg-color-inline-storage
              blocks
              intervals
              slot-ends
              remap
              vars
              stack-prefix)]
          [slot-count
            : i64
            ;; Private dense slots for everything slot-resident that the scalar
            ;; and inline-storage walks skipped, one slot each. Fresh ids skip
            ;; param pins, so the slot region is the dense prefix [0,
            ;; watermark) with params in place.
            (let
              [next : i64 storage-prefix]
              [i : i64 0]
              (begin
                (while (< i vars)
                  (begin
                    (if (>= (array.array-ref remap i) 0)
                      unit
                      (match (compiler-reg-assignment-index-lookup
                        assignment-index
                        i)
                        [(CompilerRegSomeLocation location)
                          (match location
                            [(CompilerRegSpill _)
                              (let
                                [slot : i64
                                  (compiler-reg-color-next-free-slot
                                    slot-ends
                                    next)]
                                (begin
                                  (array.array-set! remap i slot)
                                  (set! next (+ slot 1))))]
                            [_ unit])]
                        [(CompilerRegNoLocation)
                          (let
                            [slot : i64
                              (compiler-reg-color-next-free-slot slot-ends next)]
                            (begin
                              (array.array-set! remap i slot)
                              (set! next (+ slot 1))))]))
                    (set! i (+ i 1))))
                next))]
          [_renumbered
            : unit
            ;; Register-homed and unmentioned variables take the remaining FREE
            ;; ids of [0, vars), in var order (deterministic). Filling gaps
            ;; keeps the renumbering a bijection into [0, vars): an id at or
            ;; past vars would be silently dropped by the raw-var-sized rebuild
            ;; arrays and side tables. A register-homed variable never touches
            ;; its formula slot, so a free id below the watermark is safe.
            (let
              [taken : (Array bool) (array.make-array bool vars)]
              [i : i64 0]
              [free : i64 0]
              (begin
                (while (< i vars)
                  (begin
                    (array.array-set! taken i false)
                    (set! i (+ i 1))))
                (set! i 0)
                (while (< i vars)
                  (begin
                    (if (and
                      (>= (array.array-ref remap i) 0)
                      (< (array.array-ref remap i) vars))
                      (array.array-set! taken (array.array-ref remap i) true)
                      unit)
                    (set! i (+ i 1))))
                (set! i 0)
                (while (< i vars)
                  (begin
                    (if (< (array.array-ref remap i) 0)
                      (begin
                        (while (if (< free vars)
                          (array.array-ref taken free)
                          false)
                          (set! free (+ free 1)))
                        (array.array-set! remap i free)
                        (set! free (+ free 1)))
                      unit)
                    (set! i (+ i 1))))))]
          (CompilerRegColoringRemap
            remap
            (compiler-reg-max slot-count param-floor)))])))

;; --- var-id remap application (#2598) --------------------------------------
;; The backend computes stack slots from variable ids at many emission sites,
;; so compaction is applied by rewriting var ids in the IR: each stack-resident
;; variable id becomes its dense slot id and the formula slot follows. Pinned
;; params and register-homed variables keep or receive non-slot ids, so the
;; rebuilt assignment table and formula slots stay valid.
(define (compiler-reg-remap-id [remap : (Array i64)] [id : i64]) : i64
  (if (and (>= id 0) (< id (array.array-length remap)))
    (array.array-ref remap id)
    id))

(define (compiler-reg-remap-value
  [remap : (Array i64)]
  [value : CompilerIrValue]) : CompilerIrValue
  (match value
    [(IrValueVar id) (IrValueVar (compiler-reg-remap-id remap id))]
    [_ value]))

(define (compiler-reg-remap-value-list
  [remap : (Array i64)]
  [values : CompilerIrValueList]) : CompilerIrValueList
  (match values
    [(IrValueNil) IrValueNil]
    [(IrValueCons head rest)
      (IrValueCons
        (compiler-reg-remap-value remap head)
        (box (compiler-reg-remap-value-list remap (box-get rest))))]))

(define (compiler-reg-remap-call-args
  [remap : (Array i64)]
  [args : CompilerIrCallArgs]) : CompilerIrCallArgs
  (match args
    [(IrCallArgsNil) IrCallArgsNil]
    [(IrCallArgsOne a) (IrCallArgsOne (compiler-reg-remap-value remap a))]
    [(IrCallArgsTwo a b)
      (IrCallArgsTwo
        (compiler-reg-remap-value remap a)
        (compiler-reg-remap-value remap b))]
    [(IrCallArgsArray items)
      (let
        [count : i64 (array.array-length items)]
        [out : (Array CompilerIrValue) (array.make-array CompilerIrValue count)]
        [i : i64 0]
        (begin
          (while (< i count)
            (begin
              (array.array-set!
                out
                i
                (compiler-reg-remap-value remap (array.array-ref items i)))
              (set! i (+ i 1))))
          (IrCallArgsArray out)))]))

(define (compiler-reg-remap-phi-inputs
  [remap : (Array i64)]
  [inputs : CompilerIrPhiInputList]) : CompilerIrPhiInputList
  (match inputs
    [(IrPhiInputNil) IrPhiInputNil]
    [(IrPhiInputCons value label rest)
      (IrPhiInputCons
        (compiler-reg-remap-value remap value)
        label
        (box (compiler-reg-remap-phi-inputs remap (box-get rest))))]))

(define (compiler-reg-remap-maybe-value
  [remap : (Array i64)]
  [value : CompilerIrMaybeValue]) : CompilerIrMaybeValue
  (match value
    [(IrNoValue) IrNoValue]
    [(IrSomeValue inner) (IrSomeValue (compiler-reg-remap-value remap inner))]))

(define (compiler-reg-remap-instr
  [remap : (Array i64)]
  [instr : CompilerIrInstr]) : CompilerIrInstr
  (match instr
    [(IrInstrMov dst value ty)
      (IrInstrMov
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap value)
        ty)]
    [(IrInstrAlloc dst ty) (IrInstrAlloc (compiler-reg-remap-id remap dst) ty)]
    [(IrInstrAddrOf dst src)
      (IrInstrAddrOf
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-id remap src))]
    [(IrInstrGep dst base offset ty)
      (IrInstrGep
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap base)
        (compiler-reg-remap-value remap offset)
        ty)]
    [(IrInstrLoad dst src ty)
      (IrInstrLoad
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap src)
        ty)]
    [(IrInstrStorePtr ptr value ty)
      (IrInstrStorePtr
        (compiler-reg-remap-value remap ptr)
        (compiler-reg-remap-value remap value)
        ty)]
    [(IrInstrCopyBytes dst src size)
      (IrInstrCopyBytes
        (compiler-reg-remap-value remap dst)
        (compiler-reg-remap-value remap src)
        size)]
    [(IrInstrBoundsCheck index length ok-label)
      (IrInstrBoundsCheck
        (compiler-reg-remap-value remap index)
        (compiler-reg-remap-value remap length)
        ok-label)]
    [(IrInstrCast dst src from-ty to-ty)
      (IrInstrCast
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap src)
        from-ty
        to-ty)]
    [(IrInstrBitcast dst src from-ty to-ty)
      (IrInstrBitcast
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap src)
        from-ty
        to-ty)]
    [(IrInstrBinOp dst op lhs rhs ty)
      (IrInstrBinOp
        (compiler-reg-remap-id remap dst)
        op
        (compiler-reg-remap-value remap lhs)
        (compiler-reg-remap-value remap rhs)
        ty)]
    [(IrInstrUnOp dst op value ty)
      (IrInstrUnOp
        (compiler-reg-remap-id remap dst)
        op
        (compiler-reg-remap-value remap value)
        ty)]
    [(IrInstrLaneId dst lanes ty)
      (IrInstrLaneId (compiler-reg-remap-id remap dst) lanes ty)]
    [(IrInstrSplat dst value lanes ty)
      (IrInstrSplat
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap value)
        lanes
        ty)]
    [(IrInstrVectorBinOp payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorBinOpPayload dst op lhs rhs lanes ty)
          (ir-instr-vector-bin-op
            (compiler-reg-remap-id remap dst)
            op
            (compiler-reg-remap-value remap lhs)
            (compiler-reg-remap-value remap rhs)
            lanes
            ty)])]
    [(IrInstrVectorReduce dst op src lanes ty)
      (IrInstrVectorReduce
        (compiler-reg-remap-id remap dst)
        op
        (compiler-reg-remap-value remap src)
        lanes
        ty)]
    [(IrInstrVectorCompare payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorComparePayload dst op lhs rhs lanes ty)
          (ir-instr-vector-compare
            (compiler-reg-remap-id remap dst)
            op
            (compiler-reg-remap-value remap lhs)
            (compiler-reg-remap-value remap rhs)
            lanes
            ty)])]
    [(IrInstrMaskBinOp dst op lhs rhs lanes)
      (IrInstrMaskBinOp
        (compiler-reg-remap-id remap dst)
        op
        (compiler-reg-remap-value remap lhs)
        (compiler-reg-remap-value remap rhs)
        lanes)]
    [(IrInstrMaskNot dst src lanes)
      (IrInstrMaskNot
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap src)
        lanes)]
    [(IrInstrMaskReduce dst op src lanes)
      (IrInstrMaskReduce
        (compiler-reg-remap-id remap dst)
        op
        (compiler-reg-remap-value remap src)
        lanes)]
    [(IrInstrSelect payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrSelectPayload dst mask true-value false-value lanes ty)
          (ir-instr-select
            (compiler-reg-remap-id remap dst)
            (compiler-reg-remap-value remap mask)
            (compiler-reg-remap-value remap true-value)
            (compiler-reg-remap-value remap false-value)
            lanes
            ty)])]
    [(IrInstrVectorLoad dst base index lanes ty)
      (IrInstrVectorLoad
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap base)
        (compiler-reg-remap-value remap index)
        lanes
        ty)]
    [(IrInstrVectorStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrVectorStorePayload base index value lanes ty)
          (ir-instr-vector-store
            (compiler-reg-remap-value remap base)
            (compiler-reg-remap-value remap index)
            (compiler-reg-remap-value remap value)
            lanes
            ty)])]
    [(IrInstrPredicatedStore payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedStorePayload base index value mask lanes ty)
          (ir-instr-predicated-store
            (compiler-reg-remap-value remap base)
            (compiler-reg-remap-value remap index)
            (compiler-reg-remap-value remap value)
            (compiler-reg-remap-value remap mask)
            lanes
            ty)])]
    [(IrInstrPredicatedLoad payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrPredicatedLoadPayload dst base index mask lanes ty)
          (ir-instr-predicated-load
            (compiler-reg-remap-id remap dst)
            (compiler-reg-remap-value remap base)
            (compiler-reg-remap-value remap index)
            (compiler-reg-remap-value remap mask)
            lanes
            ty)])]
    [(IrInstrTailMask dst index length lanes)
      (IrInstrTailMask
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap index)
        (compiler-reg-remap-value remap length)
        lanes)]
    [(IrInstrEntryArgc dst)
      (IrInstrEntryArgc (compiler-reg-remap-id remap dst))]
    [(IrInstrEntryArgv dst)
      (IrInstrEntryArgv (compiler-reg-remap-id remap dst))]
    [(IrInstrEntryEnvp dst)
      (IrInstrEntryEnvp (compiler-reg-remap-id remap dst))]
    [(IrInstrCpuId dst leaf subleaf reg-index)
      (IrInstrCpuId
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap leaf)
        (compiler-reg-remap-value remap subleaf)
        reg-index)]
    [(IrInstrXgetbv dst index)
      (IrInstrXgetbv
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap index))]
    [(IrInstrSyscall dst args)
      (IrInstrSyscall
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-call-args remap args))]
    [(IrInstrCall dst name args ty)
      (IrInstrCall
        (compiler-reg-remap-id remap dst)
        name
        (compiler-reg-remap-call-args remap args)
        ty)]
    [(IrInstrCallIndirect dst callee args ty)
      (IrInstrCallIndirect
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap callee)
        (compiler-reg-remap-call-args remap args)
        ty)]
    [(IrInstrCallIndirectC dst callee args ty)
      (IrInstrCallIndirectC
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap callee)
        (compiler-reg-remap-call-args remap args)
        ty)]
    [(IrInstrCallCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallCAbiStoreResultPayload base name args slots)
          (ir-instr-call-cabi-store-result
            (compiler-reg-remap-value remap base)
            name
            (compiler-reg-remap-call-args remap args)
            slots)])]
    [(IrInstrCallIndirectCAbiStoreResult payload-box)
      (match (box-get payload-box)
        [(CompilerIrInstrCallIndirectCAbiStoreResultPayload
            base
            callee
            args
            slots)
          (ir-instr-call-indirect-cabi-store-result
            (compiler-reg-remap-value remap base)
            (compiler-reg-remap-value remap callee)
            (compiler-reg-remap-call-args remap args)
            slots)])]
    [(IrInstrTailCall name args ty)
      (IrInstrTailCall name (compiler-reg-remap-call-args remap args) ty)]
    [(IrInstrTailCallIndirect callee args ty)
      (IrInstrTailCallIndirect
        (compiler-reg-remap-value remap callee)
        (compiler-reg-remap-call-args remap args)
        ty)]
    [(IrInstrStore name value ty)
      (IrInstrStore name (compiler-reg-remap-value remap value) ty)]
    [(IrInstrJump _) instr]
    [(IrInstrBranch cond true-label false-label)
      (IrInstrBranch
        (compiler-reg-remap-value remap cond)
        true-label
        false-label)]
    [(IrInstrReturn value)
      (IrInstrReturn (compiler-reg-remap-maybe-value remap value))]
    [(IrInstrPhi dst inputs ty)
      (IrInstrPhi
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-phi-inputs remap inputs)
        ty)]
    [(IrInstrPack dst words ty)
      (IrInstrPack
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value-list remap words)
        ty)]
    [(IrInstrWord dst src index ty)
      (IrInstrWord
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap src)
        index
        ty)]
    [(IrInstrSwitch index base cases default-label)
      (IrInstrSwitch
        (compiler-reg-remap-value remap index)
        base
        cases
        default-label)]))

(define (compiler-reg-remap-instr-list
  [remap : (Array i64)]
  [instrs : CompilerIrInstrList]) : CompilerIrInstrList
  (match instrs
    [(IrInstrNil) IrInstrNil]
    [(IrInstrCons head rest)
      (IrInstrCons
        (compiler-reg-remap-instr remap head)
        (box (compiler-reg-remap-instr-list remap (box-get rest))))]))

(define (compiler-reg-remap-blocks
  [remap : (Array i64)]
  [blocks : CompilerIrBlockList]) : CompilerIrBlockList
  (match blocks
    [(IrBlockNil) IrBlockNil]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (IrBlockCons
            (IrBlock
              label
              (compiler-ir-instr-seq-from-list
                (compiler-reg-remap-instr-list
                  remap
                  (compiler-ir-instr-seq-to-list instrs))))
            (box (compiler-reg-remap-blocks remap (box-get rest))))])]
    [(IrBlockArray seq)
      (compiler-reg-remap-blocks remap (compiler-ir-block-seq-to-list seq))]))

(define (compiler-reg-plan-assignments [plan : CompilerRegPlan]) : CompilerRegAssignmentList
  (match plan
    [(CompilerRegPlan assignments _ _ _ _) assignments]))

(define (compiler-reg-plan-ineligible [plan : CompilerRegPlan]) : CompilerLiveI64Set
  (match plan
    [(CompilerRegPlan _ ineligible _ _ _) ineligible]))

(define (compiler-reg-plan-intervals [plan : CompilerRegPlan]) : CompilerRegIntervalList
  (match plan
    [(CompilerRegPlan _ _ intervals _ _) intervals]))

(define (compiler-reg-plan-types [plan : CompilerRegPlan]) : CompilerRegVarTypeList
  (match plan
    [(CompilerRegPlan _ _ _ types _) types]))

(define (compiler-reg-plan-caller-save-shadows [plan : CompilerRegPlan]) : CompilerLiveI64Set
  (match plan
    [(CompilerRegPlan _ _ _ _ shadows) shadows]))

(define (compiler-reg-assignment-list-merge
  [extra : CompilerRegAssignmentList]
  [base : CompilerRegAssignmentList]) : CompilerRegAssignmentList
  (match extra
    [(CompilerRegAssignmentNil) base]
    [(CompilerRegAssignmentCons item rest)
      (match item
        [(CompilerRegAssignment var location)
          (compiler-reg-assignment-list-merge
            (box-get rest)
            (compiler-reg-assignment-insert base var location))])]))

(define (compiler-reg-var-type-list-merge
  [extra : CompilerRegVarTypeList]
  [base : CompilerRegVarTypeList]) : CompilerRegVarTypeList
  (match extra
    [(CompilerRegVarTypeNil) base]
    [(CompilerRegVarTypeCons item rest)
      (match item
        [(CompilerRegVarType var ty)
          (compiler-reg-var-type-list-merge
            (box-get rest)
            (compiler-reg-var-type-insert base var ty))])]))

(define (compiler-reg-plan-with-call-save-rewrite
  [plan : CompilerRegPlan]
  [rewrite : CompilerRegCallSaveRewrite]) : CompilerRegPlan
  (match plan
    [(CompilerRegPlan assignments ineligible intervals types shadows)
      (match rewrite
        [(CompilerRegCallSaveRewrite _ _ _ extra-assignments extra-types)
          (CompilerRegPlan
            (compiler-reg-assignment-list-merge extra-assignments assignments)
            ineligible
            intervals
            (compiler-reg-var-type-list-merge extra-types types)
            shadows)])]))

(define (compiler-reg-caller-save-shadow-count-from
  [shadows : CompilerLiveI64Set]
  [vars : i64]
  [index : i64]
  [count : i64]) : i64
  (if (>= index vars)
    count
    (compiler-reg-caller-save-shadow-count-from
      shadows
      vars
      (+ index 1)
      (if (compiler-live-set-contains? shadows index)
        (+ count 1)
        count))))

(define (compiler-reg-caller-save-shadow-count
  [shadows : CompilerLiveI64Set]
  [vars : i64]) : i64
  (compiler-reg-caller-save-shadow-count-from shadows vars 0 0))

(define (compiler-reg-caller-save-remap-fill!
  [remap : (Array i64)]
  [index : i64]) : unit
  (if (>= index (array.array-length remap))
    unit
    (begin
      (array.array-set! remap index index)
      (compiler-reg-caller-save-remap-fill! remap (+ index 1)))))

(define (compiler-reg-caller-save-remap [vars : i64]) : (Array i64)
  (let
    [remap : (Array i64) (array.make-array i64 vars)]
    (begin
      (compiler-reg-caller-save-remap-fill! remap 0)
      remap)))

(define (compiler-reg-caller-save-selected-var-in-set-from
  [set : CompilerLiveI64Set]
  [splits : CompilerLiveI64Set]
  [index : i64]
  [vars : i64]) : i64
  (if (>= index vars)
    (- 0 1)
    (if (and
      (compiler-live-set-contains? set index)
      (compiler-live-set-contains? splits index))
      index
      (compiler-reg-caller-save-selected-var-in-set-from
        set
        splits
        (+ index 1)
        vars))))

(define (compiler-reg-caller-save-selected-var-in-set
  [set : CompilerLiveI64Set]
  [splits : CompilerLiveI64Set]
  [vars : i64]) : i64
  (compiler-reg-caller-save-selected-var-in-set-from set splits 0 vars))

(define (compiler-reg-caller-save-var-type
  [type-info : CompilerRegVarTypes]
  [var : i64]) : AstType
  (match (compiler-reg-var-types-lookup type-info var)
    [(CompilerRegSomeType ty) ty]
    [(CompilerRegNoType) (AstTyI64)]))

(define (compiler-reg-caller-save-segment-assignment
  [var : i64]
  [assignments : CompilerRegAssignmentList]) : CompilerRegAssignmentList
  (compiler-reg-assignment-cons
    (CompilerRegAssignment var (CompilerRegRegister "%r9"))
    assignments))

(define (compiler-reg-caller-save-active-at
  [intervals : CompilerRegIntervalList]
  [type-info : CompilerRegVarTypes]
  [splits : CompilerLiveI64Set]
  [current : (Array i64)]
  [point : i64]) : CompilerRegMaybeCallSaveActive
  (match intervals
    [(CompilerRegIntervalNil) (CompilerRegNoCallSaveActive)]
    [(CompilerRegIntervalCons interval rest)
      (match interval
        [(CompilerRegInterval var start end)
          (if (and
            (compiler-live-set-contains? splits var)
            (< start point)
            (< point end)
            (>= var 0)
            (< var (array.array-length current))
            (>= (array.array-ref current var) 0))
            (CompilerRegSomeCallSaveActive
              var
              (array.array-ref current var)
              (compiler-reg-caller-save-var-type type-info var))
            (compiler-reg-caller-save-active-at
              (box-get rest)
              type-info
              splits
              current
              point))])]))

(define (compiler-reg-caller-save-rewrite-instrs-rev
  [instrs : CompilerIrInstrList]
  [point : i64]
  [vars : i64]
  [next-var : i64]
  [type-info : CompilerRegVarTypes]
  [intervals : CompilerRegIntervalList]
  [splits : CompilerLiveI64Set]
  [current : (Array i64)]
  [remap : (Array i64)]
  [extra-assignments : CompilerRegAssignmentList]
  [extra-types : CompilerRegVarTypeList]
  [acc : CompilerIrInstrList]) : CompilerRegCallSaveInstrRewrite
  (match instrs
    [(IrInstrNil)
      (CompilerRegCallSaveInstrRewrite
        acc
        point
        next-var
        extra-assignments
        extra-types)]
    [(IrInstrCons instr rest)
      (match instr
        [(IrInstrCall _ _ _ _)
          (match (compiler-reg-caller-save-active-at
            intervals
            type-info
            splits
            current
            point)
            [(CompilerRegNoCallSaveActive)
              (compiler-reg-caller-save-rewrite-instrs-rev
                (box-get rest)
                (+ point 2)
                vars
                next-var
                type-info
                intervals
                splits
                current
                remap
                extra-assignments
                extra-types
                (compiler-ir-instr-cons instr acc))]
            [(CompilerRegSomeCallSaveActive var segment ty)
              (let
                [after-var : i64 next-var]
                [next-extra-assignments : CompilerRegAssignmentList
                  (compiler-reg-caller-save-segment-assignment
                    after-var
                    extra-assignments)]
                [next-extra-types : CompilerRegVarTypeList
                  (compiler-reg-var-type-insert extra-types after-var ty)]
                (begin
                  (array.array-set! current var after-var)
                  (array.array-set! remap var after-var)
                  (compiler-reg-caller-save-rewrite-instrs-rev
                    (box-get rest)
                    (+ point 2)
                    vars
                    (+ next-var 1)
                    type-info
                    intervals
                    splits
                    current
                    remap
                    next-extra-assignments
                    next-extra-types
                    (compiler-ir-instr-cons
                      (IrInstrMov after-var (IrValueVar var) ty)
                      (compiler-ir-instr-cons
                        instr
                        (compiler-ir-instr-cons
                          (IrInstrMov var (IrValueVar segment) ty)
                          acc))))))])]
        [_
          (let
            [split-def : i64
              (compiler-reg-caller-save-selected-var-in-set
                (compiler-live-instr-defs instr)
                splits
                vars)]
            [out-next-var : i64 next-var]
            [out-extra-assignments : CompilerRegAssignmentList
              extra-assignments]
            [out-extra-types : CompilerRegVarTypeList extra-types]
            (begin
              (if (>= split-def 0)
                (let
                  [ty : AstType
                    (compiler-reg-caller-save-var-type type-info split-def)]
                  (begin
                    (array.array-set! current split-def out-next-var)
                    (array.array-set! remap split-def out-next-var)
                    (set!
                      out-extra-assignments
                      (compiler-reg-caller-save-segment-assignment
                        out-next-var
                        out-extra-assignments))
                    (set!
                      out-extra-types
                      (compiler-reg-var-type-insert
                        out-extra-types
                        out-next-var
                        ty))
                    (set! out-next-var (+ out-next-var 1))))
                unit)
              (compiler-reg-caller-save-rewrite-instrs-rev
                (box-get rest)
                (+ point 2)
                vars
                out-next-var
                type-info
                intervals
                splits
                current
                remap
                out-extra-assignments
                out-extra-types
                (compiler-ir-instr-cons
                  (compiler-reg-remap-instr remap instr)
                  acc))))])]))

(define (compiler-reg-caller-save-rewrite-instrs
  [instrs : CompilerIrInstrSeq]
  [point : i64]
  [vars : i64]
  [next-var : i64]
  [type-info : CompilerRegVarTypes]
  [intervals : CompilerRegIntervalList]
  [splits : CompilerLiveI64Set]
  [current : (Array i64)]
  [remap : (Array i64)]
  [extra-assignments : CompilerRegAssignmentList]
  [extra-types : CompilerRegVarTypeList]) : CompilerRegCallSaveInstrRewrite
  (match (compiler-reg-caller-save-rewrite-instrs-rev
    (compiler-ir-instr-seq-to-list instrs)
    point
    vars
    next-var
    type-info
    intervals
    splits
    current
    remap
    extra-assignments
    extra-types
    IrInstrNil)
    [(CompilerRegCallSaveInstrRewrite
        rev
        next-point
        out-next-var
        out-extra-assignments
        out-extra-types)
      (CompilerRegCallSaveInstrRewrite
        (compiler-ir-instr-list-reverse-onto rev IrInstrNil)
        next-point
        out-next-var
        out-extra-assignments
        out-extra-types)]))

(define (compiler-reg-caller-save-reset-block-state!
  [current : (Array i64)]
  [remap : (Array i64)]) : unit
  (begin
    (compiler-reg-fill-i64-array current (- 0 1))
    (compiler-reg-caller-save-remap-fill! remap 0)))

(define (compiler-reg-caller-save-rewrite-blocks-rev
  [blocks : CompilerIrBlockList]
  [point : i64]
  [vars : i64]
  [next-var : i64]
  [type-info : CompilerRegVarTypes]
  [intervals : CompilerRegIntervalList]
  [splits : CompilerLiveI64Set]
  [current : (Array i64)]
  [remap : (Array i64)]
  [reset-each-block : bool]
  [extra-assignments : CompilerRegAssignmentList]
  [extra-types : CompilerRegVarTypeList]
  [acc : CompilerIrBlockList]) : CompilerRegCallSaveRewrite
  (match blocks
    [(IrBlockNil)
      (CompilerRegCallSaveRewrite
        acc
        point
        next-var
        extra-assignments
        extra-types)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (begin
            (if reset-each-block
              (compiler-reg-caller-save-reset-block-state! current remap)
              unit)
            (match (compiler-reg-caller-save-rewrite-instrs
              instrs
              point
              vars
              next-var
              type-info
              intervals
              splits
              current
              remap
              extra-assignments
              extra-types)
              [(CompilerRegCallSaveInstrRewrite
                  rewritten
                  next-point
                  next-var2
                  extra-assignments2
                  extra-types2)
                (compiler-reg-caller-save-rewrite-blocks-rev
                  (box-get rest)
                  next-point
                  vars
                  next-var2
                  type-info
                  intervals
                  splits
                  current
                  remap
                  reset-each-block
                  extra-assignments2
                  extra-types2
                  (compiler-ir-block-cons
                    (IrBlock label (compiler-ir-instr-seq-from-list rewritten))
                    acc))]))])]
    [(IrBlockArray seq)
      (compiler-reg-caller-save-rewrite-blocks-rev
        (compiler-ir-block-seq-to-list seq)
        point
        vars
        next-var
        type-info
        intervals
        splits
        current
        remap
        reset-each-block
        extra-assignments
        extra-types
        acc)]))

(define (compiler-reg-caller-save-rewrite-blocks
  [blocks : CompilerIrBlockList]
  [vars : i64]
  [type-info : CompilerRegVarTypes]
  [plan : CompilerRegPlan]) : CompilerRegCallSaveRewrite
  (let
    [splits : CompilerLiveI64Set (compiler-reg-plan-caller-save-shadows plan)]
    [split-count : i64 (compiler-reg-caller-save-shadow-count splits vars)]
    (if (= split-count 0)
      (CompilerRegCallSaveRewrite
        blocks
        vars
        vars
        CompilerRegAssignmentNil
        CompilerRegVarTypeNil)
      (let
        [current : (Array i64) (array.make-array i64 vars)]
        [remap : (Array i64) (compiler-reg-caller-save-remap vars)]
        [reset-each-block : bool (> (compiler-ir-block-list-count blocks) 1)]
        [_current-init : unit (compiler-reg-fill-i64-array current (- 0 1))]
        (match (compiler-reg-caller-save-rewrite-blocks-rev
          blocks
          0
          vars
          vars
          type-info
          (compiler-reg-plan-intervals plan)
          splits
          current
          remap
          reset-each-block
          CompilerRegAssignmentNil
          CompilerRegVarTypeNil
          IrBlockNil)
          [(CompilerRegCallSaveRewrite
              rev
              _
              out-vars
              extra-assignments
              extra-types)
            (CompilerRegCallSaveRewrite
              (compiler-ir-block-list-reverse-onto rev IrBlockNil)
              vars
              out-vars
              extra-assignments
              extra-types)])))))

(define (compiler-reg-remat-table-record-def!
  [table : CompilerRegRematTable]
  [instr : CompilerIrInstr]
  [allow-invariant-loads : bool]) : unit
  (let
    [def-counts : (Array i64) (struct-get table def-counts)]
    [candidates : (Array i64) (struct-get table candidates)]
    [kinds : (Array i64) (struct-get table kinds)]
    [values : (Array CompilerIrValue) (struct-get table values)]
    [offsets : (Array CompilerIrValue) (struct-get table offsets)]
    [op-types : (Array AstType) (struct-get table op-types)]
    [types : (Array AstType) (struct-get table types)]
    (begin
      (compiler-reg-ref-counts-add-set-weighted!
        def-counts
        (compiler-live-instr-defs instr)
        1)
      (match instr
        [(IrInstrMov dst value ty)
          (if (and
            (compiler-reg-remat-mov-value? value allow-invariant-loads)
            (>= dst 0)
            (< dst (array.array-length candidates)))
            (begin
              (array.array-set! candidates dst 1)
              (array.array-set! kinds dst (compiler-reg-remat-kind-mov))
              (array.array-set! values dst value)
              (array.array-set! op-types dst ty)
              (array.array-set! types dst ty))
            unit)]
        [(IrInstrGep dst base offset ty)
          (if (and
            (compiler-reg-remat-gep? base offset)
            (>= dst 0)
            (< dst (array.array-length candidates)))
            (begin
              (array.array-set! candidates dst 1)
              (array.array-set! kinds dst (compiler-reg-remat-kind-gep))
              (array.array-set! values dst base)
              (array.array-set! offsets dst offset)
              (array.array-set! op-types dst ty)
              (array.array-set! types dst (compiler-reg-addr-of-result-type)))
            unit)]
        [(IrInstrLoad dst src ty)
          (if (and
            (compiler-reg-remat-load? src allow-invariant-loads)
            (>= dst 0)
            (< dst (array.array-length candidates)))
            (begin
              (array.array-set! candidates dst 1)
              (array.array-set! kinds dst (compiler-reg-remat-kind-load))
              (array.array-set! values dst src)
              (array.array-set! op-types dst ty)
              (array.array-set! types dst ty))
            unit)]
        [_ unit]))))

(define (compiler-reg-remat-table-record-instrs!
  [table : CompilerRegRematTable]
  [instrs : CompilerIrInstrSeq]
  [allow-invariant-loads : bool]) : unit
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    (while (< index count)
      (begin
        (compiler-reg-remat-table-record-def!
          table
          (array.array-ref slots index)
          allow-invariant-loads)
        (set! index (+ index 1))))))

(define (compiler-reg-remat-table-record-blocks!
  [table : CompilerRegRematTable]
  [blocks : CompilerIrBlockList]
  [allow-invariant-loads : bool]) : unit
  (match blocks
    [(IrBlockNil) unit]
    [(IrBlockCons block rest)
      (begin
        (match block
          [(IrBlock _ instrs)
            (compiler-reg-remat-table-record-instrs!
              table
              instrs
              allow-invariant-loads)])
        (compiler-reg-remat-table-record-blocks!
          table
          (box-get rest)
          allow-invariant-loads))]
    [(IrBlockArray seq)
      (compiler-reg-remat-table-record-blocks!
        table
        (compiler-ir-block-seq-to-list seq)
        allow-invariant-loads)]))

(define (compiler-reg-remat-table-build [func : CompilerIrFunction]) : CompilerRegRematTable
  (match func
    [(IrFunction _ _ _ vars blocks)
      (let
        [def-counts : (Array i64) (array.make-array i64 vars)]
        [candidates : (Array i64) (array.make-array i64 vars)]
        [kinds : (Array i64) (array.make-array i64 vars)]
        [values : (Array CompilerIrValue)
          (array.make-array CompilerIrValue vars)]
        [offsets : (Array CompilerIrValue)
          (array.make-array CompilerIrValue vars)]
        [op-types : (Array AstType) (array.make-array AstType vars)]
        [types : (Array AstType) (array.make-array AstType vars)]
        [allow-invariant-loads : bool
          (compiler-reg-remat-invariant-loads-ok? func)]
        [table : CompilerRegRematTable
          (CompilerRegRematTable
            def-counts
            candidates
            kinds
            values
            offsets
            op-types
            types)]
        (begin
          (compiler-reg-fill-i64-array def-counts 0)
          (compiler-reg-fill-i64-array candidates 0)
          (compiler-reg-fill-i64-array kinds 0)
          (compiler-reg-remat-table-record-blocks!
            table
            blocks
            allow-invariant-loads)
          table))]))

(define (compiler-reg-remat-var-spilled?
  [assignments : CompilerRegAssignmentList]
  [var : i64]) : bool
  (match (compiler-reg-assignment-lookup assignments var)
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegSpill _) true]
        [_ false])]
    [(CompilerRegNoLocation) true]))

(define (compiler-reg-remat-table-eligible?
  [table : CompilerRegRematTable]
  [assignments : CompilerRegAssignmentList]
  [parents : (Array i64)]
  [merged-roots : CompilerLiveI64Set]
  [var : i64]) : bool
  (let
    [def-counts : (Array i64) (struct-get table def-counts)]
    [candidates : (Array i64) (struct-get table candidates)]
    (and
      (>= var 0)
      (< var (array.array-length def-counts))
      (= (array.array-ref def-counts var) 1)
      (= (array.array-ref candidates var) 1)
      (compiler-reg-remat-var-spilled? assignments var)
      (not (compiler-reg-coalesce-var-nonsingleton? parents merged-roots var)))))

(define (compiler-reg-remat-registers-for-type [ty : AstType]) : CompilerRegStringList
  (if (compiler-reg-float-type? ty)
    (compiler-reg-xmm-registers)
    (if (compiler-reg-register-eligible-type? ty)
      (compiler-reg-string-cons "%r9" CompilerRegStringNil)
      CompilerRegStringNil)))

(define (compiler-reg-remat-interval-active-at?
  [intervals : CompilerRegIntervalIndex]
  [var : i64]
  [point : i64]) : bool
  (match (compiler-reg-interval-index-lookup intervals var)
    [(CompilerRegSomeInterval interval)
      (match interval
        [(CompilerRegInterval _ start end)
          (and (<= start point) (<= point end))])]
    [(CompilerRegNoInterval) false]))

(define (compiler-reg-remat-location-conflicts-at?
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalIndex]
  [point : i64]
  [location : CompilerRegLocation]) : bool
  (match assignments
    [(CompilerRegAssignmentNil) false]
    [(CompilerRegAssignmentCons item rest)
      (match item
        [(CompilerRegAssignment var assigned-location)
          (if (and
            (compiler-reg-location-eq? assigned-location location)
            (compiler-reg-remat-interval-active-at? intervals var point))
            true
            (compiler-reg-remat-location-conflicts-at?
              (box-get rest)
              intervals
              point
              location))])]))

(define (compiler-reg-remat-first-free-register-at
  [regs : CompilerRegStringList]
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalIndex]
  [point : i64]
  [chosen : CompilerRegStringList]) : CompilerRegMaybeString
  (match regs
    [(CompilerRegStringNil) CompilerRegNoString]
    [(CompilerRegStringCons reg rest)
      (if (and
        (not (compiler-reg-string-list-contains? chosen reg))
        (not
          (compiler-reg-remat-location-conflicts-at?
            assignments
            intervals
            point
            (CompilerRegRegister reg))))
        (CompilerRegSomeString reg)
        (compiler-reg-remat-first-free-register-at
          (box-get rest)
          assignments
          intervals
          point
          chosen))]))

(define (compiler-reg-remat-selected-register
  [table : CompilerRegRematTable]
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalIndex]
  [point : i64]
  [chosen : CompilerRegStringList]
  [var : i64]) : CompilerRegMaybeString
  (let
    [types : (Array AstType) (struct-get table types)]
    (if (or (< var 0) (>= var (array.array-length types)))
      CompilerRegNoString
      (compiler-reg-remat-first-free-register-at
        (compiler-reg-remat-registers-for-type (array.array-ref types var))
        assignments
        intervals
        point
        chosen))))

(define (compiler-reg-remat-instr
  [table : CompilerRegRematTable]
  [temp : i64]
  [var : i64]) : CompilerIrInstr
  (let
    [kinds : (Array i64) (struct-get table kinds)]
    [values : (Array CompilerIrValue) (struct-get table values)]
    [offsets : (Array CompilerIrValue) (struct-get table offsets)]
    [op-types : (Array AstType) (struct-get table op-types)]
    [types : (Array AstType) (struct-get table types)]
    [ty : AstType (array.array-ref types var)]
    [value : CompilerIrValue (array.array-ref values var)]
    (cond
      [(= (array.array-ref kinds var) (compiler-reg-remat-kind-load))
        (IrInstrLoad temp value ty)]
      [(= (array.array-ref kinds var) (compiler-reg-remat-kind-gep))
        (IrInstrGep
          temp
          value
          (array.array-ref offsets var)
          (array.array-ref op-types var))]
      [else (IrInstrMov temp value ty)])))

(define (compiler-reg-remat-use-site-ok? [instr : CompilerIrInstr]) : bool
  (match instr
    [(IrInstrPhi _ _ _) false]
    ;; Remat temps are assigned to caller-clobbered homes for a single expanded
    ;; instruction. Avoid instructions whose backend expansion may clobber those
    ;; homes before every operand has been consumed.
    [_ (not (compiler-reg-backend-caller-clobber-instr? instr))]))

(define (compiler-reg-remat-instr-list-onto
  [items : CompilerIrInstrList]
  [acc : CompilerIrInstrList]) : CompilerIrInstrList
  (match items
    [(IrInstrNil) acc]
    [(IrInstrCons head rest)
      (compiler-ir-instr-cons
        head
        (compiler-reg-remat-instr-list-onto (box-get rest) acc))]))

;; Reset the entries of a shared, function-scoped identity remap array that a
;; single instruction touched. Only the vars in `uses` (the instruction's
;; operands) could have been overwritten, so restoring identity for those bits
;; returns the array to "no-remap" for the next instruction without an
;; O(vars) rescan/zero. Set bits at ids >= vars are skipped, matching the old
;; ascending `(while (< var vars) ...)` loop which never visited them.
(define (compiler-reg-remat-reset-remap-uses!
  [remap : (Array i64)]
  [uses : CompilerLiveI64Set]
  [vars : i64]) : unit
  (let
    [word-index : i64 0]
    [word-count : i64 (compiler-live-set-word-count uses)]
    (while (< word-index word-count)
      (let
        [bits : i64 (compiler-live-set-word-at uses word-index)]
        [base : i64 (* word-index (compiler-live-set-word-bits))]
        [bit : i64 0]
        (begin
          (while (not (= bits 0))
            (begin
              (if (not (= (bit-and bits 1) 0))
                (let
                  [var : i64 (+ base bit)]
                  (if (< var vars)
                    (array.array-set! remap var var)
                    unit))
                unit)
              (set! bits (shr bits 1))
              (set! bit (+ bit 1))))
          (set! word-index (+ word-index 1)))))))

(define (compiler-reg-remat-rewrite-one-instr
  [instr : CompilerIrInstr]
  [point : i64]
  [vars : i64]
  [next-var : i64]
  [table : CompilerRegRematTable]
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalIndex]
  [parents : (Array i64)]
  [merged-roots : CompilerLiveI64Set]
  [extra-assignments : CompilerRegAssignmentList]
  [extra-types : CompilerRegVarTypeList]
  [remap : (Array i64)]
  [acc : CompilerIrInstrList]) : CompilerRegCallSaveInstrRewrite
  (if (compiler-reg-remat-use-site-ok? instr)
    (let
      ;; `uses` is the (1-3 var) operand bitset for THIS instruction. Iterate
      ;; only its set bits in ascending order instead of scanning all `vars`,
      ;; which is byte-identical to the old loop (which also only ran the body
      ;; for set bits in ascending order) but avoids the per-instruction
      ;; O(vars) scan + array zero. `remap` is a function-scoped identity array
      ;; reused across instructions; we restore the bits we set afterwards.
      [uses : CompilerLiveI64Set (compiler-live-instr-uses instr)]
      [types : (Array AstType) (struct-get table types)]
      [prefix : CompilerIrInstrList IrInstrNil]
      [chosen : CompilerRegStringList CompilerRegStringNil]
      [out-next-var : i64 next-var]
      [out-extra-assignments : CompilerRegAssignmentList extra-assignments]
      [out-extra-types : CompilerRegVarTypeList extra-types]
      [word-index : i64 0]
      [word-count : i64 (compiler-live-set-word-count uses)]
      (begin
        (while (< word-index word-count)
          (let
            [bits : i64 (compiler-live-set-word-at uses word-index)]
            [base : i64 (* word-index (compiler-live-set-word-bits))]
            [bit : i64 0]
            (begin
              (while (not (= bits 0))
                (begin
                  (if (not (= (bit-and bits 1) 0))
                    (let
                      [var : i64 (+ base bit)]
                      (if (and
                        (< var vars)
                        (compiler-reg-remat-table-eligible?
                          table
                          assignments
                          parents
                          merged-roots
                          var))
                        (match (compiler-reg-remat-selected-register
                          table
                          assignments
                          intervals
                          point
                          chosen
                          var)
                          [(CompilerRegSomeString reg)
                            (let
                              [temp : i64 out-next-var]
                              [ty : AstType (array.array-ref types var)]
                              (begin
                                (array.array-set! remap var temp)
                                (set!
                                  prefix
                                  (compiler-ir-instr-cons
                                    (compiler-reg-remat-instr table temp var)
                                    prefix))
                                (set!
                                  chosen
                                  (compiler-reg-string-cons reg chosen))
                                (set!
                                  out-extra-assignments
                                  (compiler-reg-assignment-cons
                                    (CompilerRegAssignment
                                      temp
                                      (CompilerRegRegister reg))
                                    out-extra-assignments))
                                (set!
                                  out-extra-types
                                  (compiler-reg-var-type-insert
                                    out-extra-types
                                    temp
                                    ty))
                                (set! out-next-var (+ out-next-var 1))))]
                          [(CompilerRegNoString) unit])
                        unit))
                    unit)
                  (set! bits (shr bits 1))
                  (set! bit (+ bit 1))))
              (set! word-index (+ word-index 1)))))
        (if (= out-next-var next-var)
          (CompilerRegCallSaveInstrRewrite
            (compiler-ir-instr-cons instr acc)
            (+ point 2)
            out-next-var
            out-extra-assignments
            out-extra-types)
          (let
            [rewritten : CompilerIrInstr (compiler-reg-remap-instr remap instr)]
            (begin
              ;; Restore the shared remap array to identity for the next instr.
              (compiler-reg-remat-reset-remap-uses! remap uses vars)
              (CompilerRegCallSaveInstrRewrite
                (compiler-ir-instr-cons
                  rewritten
                  (compiler-reg-remat-instr-list-onto prefix acc))
                (+ point 2)
                out-next-var
                out-extra-assignments
                out-extra-types))))))
    (CompilerRegCallSaveInstrRewrite
      (compiler-ir-instr-cons instr acc)
      (+ point 2)
      next-var
      extra-assignments
      extra-types)))

(define (compiler-reg-remat-rewrite-instrs-rev
  [instrs : CompilerIrInstrList]
  [point : i64]
  [vars : i64]
  [next-var : i64]
  [table : CompilerRegRematTable]
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalIndex]
  [parents : (Array i64)]
  [merged-roots : CompilerLiveI64Set]
  [extra-assignments : CompilerRegAssignmentList]
  [extra-types : CompilerRegVarTypeList]
  [remap : (Array i64)]
  [acc : CompilerIrInstrList]) : CompilerRegCallSaveInstrRewrite
  (match instrs
    [(IrInstrNil)
      (CompilerRegCallSaveInstrRewrite
        acc
        point
        next-var
        extra-assignments
        extra-types)]
    [(IrInstrCons instr rest)
      (match (compiler-reg-remat-rewrite-one-instr
        instr
        point
        vars
        next-var
        table
        assignments
        intervals
        parents
        merged-roots
        extra-assignments
        extra-types
        remap
        acc)
        [(CompilerRegCallSaveInstrRewrite
            acc2
            point2
            next-var2
            extra-assignments2
            extra-types2)
          (compiler-reg-remat-rewrite-instrs-rev
            (box-get rest)
            point2
            vars
            next-var2
            table
            assignments
            intervals
            parents
            merged-roots
            extra-assignments2
            extra-types2
            remap
            acc2)])]))

(define (compiler-reg-remat-rewrite-instrs
  [instrs : CompilerIrInstrSeq]
  [point : i64]
  [vars : i64]
  [next-var : i64]
  [table : CompilerRegRematTable]
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalIndex]
  [parents : (Array i64)]
  [merged-roots : CompilerLiveI64Set]
  [extra-assignments : CompilerRegAssignmentList]
  [extra-types : CompilerRegVarTypeList]
  [remap : (Array i64)]) : CompilerRegCallSaveInstrRewrite
  (match (compiler-reg-remat-rewrite-instrs-rev
    (compiler-ir-instr-seq-to-list instrs)
    point
    vars
    next-var
    table
    assignments
    intervals
    parents
    merged-roots
    extra-assignments
    extra-types
    remap
    IrInstrNil)
    [(CompilerRegCallSaveInstrRewrite
        rev
        next-point
        out-next-var
        out-extra-assignments
        out-extra-types)
      (CompilerRegCallSaveInstrRewrite
        (compiler-ir-instr-list-reverse-onto rev IrInstrNil)
        next-point
        out-next-var
        out-extra-assignments
        out-extra-types)]))

(define (compiler-reg-remat-rewrite-blocks-rev
  [blocks : CompilerIrBlockList]
  [point : i64]
  [vars : i64]
  [next-var : i64]
  [table : CompilerRegRematTable]
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalIndex]
  [parents : (Array i64)]
  [merged-roots : CompilerLiveI64Set]
  [extra-assignments : CompilerRegAssignmentList]
  [extra-types : CompilerRegVarTypeList]
  [remap : (Array i64)]
  [acc : CompilerIrBlockList]) : CompilerRegCallSaveRewrite
  (match blocks
    [(IrBlockNil)
      (CompilerRegCallSaveRewrite
        acc
        point
        next-var
        extra-assignments
        extra-types)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (match (compiler-reg-remat-rewrite-instrs
            instrs
            point
            vars
            next-var
            table
            assignments
            intervals
            parents
            merged-roots
            extra-assignments
            extra-types
            remap)
            [(CompilerRegCallSaveInstrRewrite
                rewritten
                next-point
                next-var2
                extra-assignments2
                extra-types2)
              (compiler-reg-remat-rewrite-blocks-rev
                (box-get rest)
                next-point
                vars
                next-var2
                table
                assignments
                intervals
                parents
                merged-roots
                extra-assignments2
                extra-types2
                remap
                (compiler-ir-block-cons
                  (IrBlock label (compiler-ir-instr-seq-from-list rewritten))
                  acc))])])]
    [(IrBlockArray seq)
      (compiler-reg-remat-rewrite-blocks-rev
        (compiler-ir-block-seq-to-list seq)
        point
        vars
        next-var
        table
        assignments
        intervals
        parents
        merged-roots
        extra-assignments
        extra-types
        remap
        acc)]))

(define (compiler-reg-remat-rewrite-blocks
  [func : CompilerIrFunction]
  [blocks : CompilerIrBlockList]
  [vars : i64]
  [type-info : CompilerRegVarTypes]
  [plan : CompilerRegPlan]) : CompilerRegCallSaveRewrite
  (let
    [table : CompilerRegRematTable (compiler-reg-remat-table-build func)]
    [types : CompilerRegVarTypeList (compiler-reg-var-types-list type-info)]
    [group-vars : CompilerLiveI64Set
      (compiler-reg-function-group-vars func types)]
    [liveness : CompilerFunctionLiveness (compiler-live-analyze-function func)]
    (match (compiler-reg-live-interval-selection func liveness)
      [(CompilerRegIntervalSelection intervals interval-index)
        (let
          [coalesce : CompilerRegCoalesceMap
            (compiler-reg-coalesce-map-build
              (compiler-reg-function-moves func false)
              interval-index
              type-info
              group-vars
              vars
              (array.make-array i64 0))]
          [parents : (Array i64) (struct-get coalesce parents)]
          [merged-roots : CompilerLiveI64Set
            (compiler-reg-coalesce-merged-root-set coalesce)]
          ;; One function-scoped identity remap array, reused across every
          ;; instruction. Each rewritten instruction restores the few bits it
          ;; touches (see compiler-reg-remat-reset-remap-uses!), replacing the
          ;; old per-instruction O(vars) allocation + zero + identity fill.
          [remap : (Array i64) (compiler-reg-caller-save-remap vars)]
          (match (compiler-reg-remat-rewrite-blocks-rev
            blocks
            0
            vars
            vars
            table
            (compiler-reg-plan-assignments plan)
            interval-index
            parents
            merged-roots
            CompilerRegAssignmentNil
            CompilerRegVarTypeNil
            remap
            IrBlockNil)
            [(CompilerRegCallSaveRewrite
                rev
                _
                out-vars
                extra-assignments
                extra-types)
              (CompilerRegCallSaveRewrite
                (compiler-ir-block-list-reverse-onto rev IrBlockNil)
                vars
                out-vars
                extra-assignments
                extra-types)]))])))

(define (compiler-reg-location-register?
  [maybe-location : CompilerRegMaybeLocation]
  [reg : String]) : bool
  (match maybe-location
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegRegister found) (string.string-eq found reg)]
        [(CompilerRegRegisterPair a b)
          (or (string.string-eq a reg) (string.string-eq b reg))]
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

(define (compiler-reg-location-any-register?
  [maybe-location : CompilerRegMaybeLocation]) : bool
  (match maybe-location
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegRegister _) true]
        [(CompilerRegRegisterPair _ _) true]
        [_ false])]
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
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 1) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrStore "g0" (IrValueVar 0) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrMov 1 (IrValueI64 2) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 1)))
                IrInstrNil)))))
      IrBlockNil)))

(define (compiler-reg-f64-reuse-function) : CompilerIrFunction
  (IrFunction
    "f64_reuse"
    IrParamNil
    (compiler-reg-f64-ty)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueF64 0x3ff8000000000000) (compiler-reg-f64-ty))
          (compiler-ir-instr-cons
            (IrInstrStore "g0" (IrValueVar 0) (compiler-reg-f64-ty))
            (compiler-ir-instr-cons
              (IrInstrMov
                1
                (IrValueF64 0x4004000000000000)
                (compiler-reg-f64-ty))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 1)))
                IrInstrNil)))))
      IrBlockNil)))

(define (compiler-reg-overlap-function) : CompilerIrFunction
  (IrFunction
    "overlap"
    IrParamNil
    (AstTyUnit)
    8
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 0) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueI64 1) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrMov 2 (IrValueI64 2) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrMov 3 (IrValueI64 3) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (IrInstrMov 4 (IrValueI64 4) (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (IrInstrMov 5 (IrValueI64 5) (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (IrInstrMov 6 (IrValueI64 6) (compiler-reg-i64-ty))
                      (compiler-ir-instr-cons
                        (IrInstrStore "g0" (IrValueVar 0) (compiler-reg-i64-ty))
                        (compiler-ir-instr-cons
                          (IrInstrStore
                            "g1"
                            (IrValueVar 1)
                            (compiler-reg-i64-ty))
                          (compiler-ir-instr-cons
                            (IrInstrStore
                              "g2"
                              (IrValueVar 2)
                              (compiler-reg-i64-ty))
                            (compiler-ir-instr-cons
                              (IrInstrStore
                                "g3"
                                (IrValueVar 3)
                                (compiler-reg-i64-ty))
                              (compiler-ir-instr-cons
                                (IrInstrStore
                                  "g4"
                                  (IrValueVar 4)
                                  (compiler-reg-i64-ty))
                                (compiler-ir-instr-cons
                                  (IrInstrStore
                                    "g5"
                                    (IrValueVar 5)
                                    (compiler-reg-i64-ty))
                                  (compiler-ir-instr-cons
                                    (IrInstrStore
                                      "g6"
                                      (IrValueVar 6)
                                      (compiler-reg-i64-ty))
                                    (compiler-ir-instr-cons
                                      (IrInstrReturn IrNoValue)
                                      IrInstrNil))))))))))))))))
      IrBlockNil)))

(define (compiler-reg-f64-overlap-function) : CompilerIrFunction
  (IrFunction
    "f64_overlap"
    IrParamNil
    (AstTyUnit)
    5
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueF64 0x3fe0000000000000) (compiler-reg-f64-ty))
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueF64 0x3ff8000000000000) (compiler-reg-f64-ty))
            (compiler-ir-instr-cons
              (IrInstrMov
                2
                (IrValueF64 0x4004000000000000)
                (compiler-reg-f64-ty))
              (compiler-ir-instr-cons
                (IrInstrMov
                  3
                  (IrValueF64 0x400c000000000000)
                  (compiler-reg-f64-ty))
                (compiler-ir-instr-cons
                  (IrInstrMov
                    4
                    (IrValueF64 0x4012000000000000)
                    (compiler-reg-f64-ty))
                  (compiler-ir-instr-cons
                    (IrInstrStore "g0" (IrValueVar 0) (compiler-reg-f64-ty))
                    (compiler-ir-instr-cons
                      (IrInstrStore "g1" (IrValueVar 1) (compiler-reg-f64-ty))
                      (compiler-ir-instr-cons
                        (IrInstrStore "g2" (IrValueVar 2) (compiler-reg-f64-ty))
                        (compiler-ir-instr-cons
                          (IrInstrStore
                            "g3"
                            (IrValueVar 3)
                            (compiler-reg-f64-ty))
                          (compiler-ir-instr-cons
                            (IrInstrStore
                              "g4"
                              (IrValueVar 4)
                              (compiler-reg-f64-ty))
                            (compiler-ir-instr-cons
                              (IrInstrReturn IrNoValue)
                              IrInstrNil))))))))))))
      IrBlockNil)))

(define (compiler-reg-call-live-function) : CompilerIrFunction
  (IrFunction
    "call_live"
    IrParamNil
    (AstTyUnit)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 9) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrCall 1 "side_effect" (IrCallArgsNil) (AstTyUnit))
            (compiler-ir-instr-cons
              (IrInstrMov 2 (IrValueVar 0) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 2)))
                IrInstrNil)))))
      IrBlockNil)))

(define (compiler-reg-f64-call-live-function) : CompilerIrFunction
  (IrFunction
    "f64_call_live"
    IrParamNil
    (compiler-reg-f64-ty)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueF64 0x4023000000000000) (compiler-reg-f64-ty))
          (compiler-ir-instr-cons
            (IrInstrCall 1 "side_effect" (IrCallArgsNil) (AstTyUnit))
            (compiler-ir-instr-cons
              (IrInstrMov 2 (IrValueVar 0) (compiler-reg-f64-ty))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 2)))
                IrInstrNil)))))
      IrBlockNil)))

(define (compiler-reg-call-arg-function) : CompilerIrFunction
  (IrFunction
    "call_arg"
    IrParamNil
    (AstTyUnit)
    4
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 1) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueI64 2) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrCall
                2
                "use_args"
                (IrCallArgsTwo (IrValueVar 0) (IrValueVar 1))
                (AstTyUnit))
              (compiler-ir-instr-cons
                (IrInstrMov 3 (IrValueI64 3) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 3)))
                  IrInstrNil))))))
      IrBlockNil)))

(define (compiler-reg-f64-call-arg-function) : CompilerIrFunction
  (IrFunction
    "f64_call_arg"
    IrParamNil
    (compiler-reg-f64-ty)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueF64 0x3ff8000000000000) (compiler-reg-f64-ty))
          (compiler-ir-instr-cons
            (IrInstrCall
              1
              "takes_f64"
              (IrCallArgsOne (IrValueVar 0))
              (AstTyUnit))
            (compiler-ir-instr-cons
              (IrInstrMov
                2
                (IrValueF64 0x4004000000000000)
                (compiler-reg-f64-ty))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 2)))
                IrInstrNil)))))
      IrBlockNil)))

(define (compiler-reg-ineligible-function) : CompilerIrFunction
  (IrFunction
    "ineligible"
    (compiler-ir-param-cons (IrParam "arg" (compiler-reg-i64-ty) 0) IrParamNil)
    (AstTyUnit)
    7
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 1 (IrValueF64 0x3ff8000000000000) (AstTyF64))
          (compiler-ir-instr-cons
            (IrInstrMov 2 (IrValueString "heap") (AstTyString))
            (compiler-ir-instr-cons
              (IrInstrMov 3 (IrValueVar 0) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrMov 4 (IrValueUnit) (ast-ty-dyn-array (AstTyI64)))
                (compiler-ir-instr-cons
                  (IrInstrMov 5 (IrValueI64 5) (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (IrInstrAddrOf 6 3)
                    (compiler-ir-instr-cons
                      (IrInstrTailMask 7 (IrValueVar 5) (IrValueVar 5) 4)
                      (compiler-ir-instr-cons
                        (IrInstrReturn (IrSomeValue (IrValueVar 5)))
                        IrInstrNil)))))))))
      IrBlockNil)))

(define (compiler-reg-param-livein-gap-function) : CompilerIrFunction
  (IrFunction
    "param_livein_gap"
    (compiler-ir-param-cons (IrParam "arg" (compiler-reg-i64-ty) 0) IrParamNil)
    (AstTyI64)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons (IrInstrJump "body") IrInstrNil))
      (compiler-ir-block-cons
        (compiler-ir-block
          "body"
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueI64 7) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 0)))
              IrInstrNil)))
        IrBlockNil))))

(define (compiler-reg-single-block-livein-gap-function) : CompilerIrFunction
  (IrFunction
    "single_block_livein_gap"
    (compiler-ir-param-cons (IrParam "arg" (compiler-reg-i64-ty) 0) IrParamNil)
    (AstTyI64)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 1 (IrValueI64 7) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 0)))
            IrInstrNil)))
      IrBlockNil)))

(cfg
  test
  (define (compiler-reg-param-register-function) : CompilerIrFunction
    (IrFunction
      "param_registers"
      (compiler-ir-param-cons
        (IrParam "a" (compiler-reg-i64-ty) 0)
        (compiler-ir-param-cons
          (IrParam "b" (compiler-reg-i64-ty) 1)
          (compiler-ir-param-cons
            (IrParam "c" (compiler-reg-i64-ty) 2)
            IrParamNil)))
      (AstTyUnit)
      3
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrStore "pa" (IrValueVar 0) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrStore "pb" (IrValueVar 1) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrStore "pc" (IrValueVar 2) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons (IrInstrReturn IrNoValue) IrInstrNil)))))
        IrBlockNil))))

(cfg
  test
  (define (compiler-reg-zero-call-param-conflict-function) : CompilerIrFunction
    (let
      [instrs : CompilerIrInstrList IrInstrNil]
      (begin
        (set! instrs (compiler-ir-instr-cons (IrInstrReturn IrNoValue) instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "p5" (IrValueVar 5) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "g12" (IrValueVar 12) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "g11" (IrValueVar 11) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "g10" (IrValueVar 10) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "g9" (IrValueVar 9) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "g8" (IrValueVar 8) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "g7" (IrValueVar 7) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "g6" (IrValueVar 6) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 12 (IrValueI64 12) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 11 (IrValueI64 11) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 10 (IrValueI64 10) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 9 (IrValueI64 9) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 8 (IrValueI64 8) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 7 (IrValueI64 7) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 6 (IrValueI64 6) (compiler-reg-i64-ty))
            instrs))
        (IrFunction
          "zero_call_param_conflict"
          (compiler-ir-param-cons
            (IrParam "a" (compiler-reg-i64-ty) 0)
            (compiler-ir-param-cons
              (IrParam "b" (compiler-reg-i64-ty) 1)
              (compiler-ir-param-cons
                (IrParam "c" (compiler-reg-i64-ty) 2)
                (compiler-ir-param-cons
                  (IrParam "d" (compiler-reg-i64-ty) 3)
                  (compiler-ir-param-cons
                    (IrParam "e" (compiler-reg-i64-ty) 4)
                    (compiler-ir-param-cons
                      (IrParam "f" (compiler-reg-i64-ty) 5)
                      IrParamNil))))))
          (AstTyUnit)
          13
          (compiler-ir-block-cons (compiler-ir-block "entry" instrs) IrBlockNil))))))

(cfg
  test
  (define (compiler-reg-param-clobber-function) : CompilerIrFunction
    (IrFunction
      "param_clobber"
      (compiler-ir-param-cons
        (IrParam "arg" (compiler-reg-i64-ty) 0)
        IrParamNil)
      (AstTyI64)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrCall 1 "side_effect" (IrCallArgsNil) (AstTyUnit))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 0)))
              IrInstrNil)))
        IrBlockNil))))

(cfg
  test
  (define (compiler-reg-param-aggregate-function) : CompilerIrFunction
    (let
      [ty : AstType (AstTyStruct (intern "ParamAggregate"))]
      (IrFunction
        "param_aggregate"
        (compiler-ir-param-cons (IrParam "state" ty 0) IrParamNil)
        (AstTyUnit)
        2
        (compiler-ir-block-cons
          (compiler-ir-block
            "entry"
            (compiler-ir-instr-cons
              (IrInstrMov 1 (IrValueVar 0) ty)
              (compiler-ir-instr-cons (IrInstrReturn IrNoValue) IrInstrNil)))
          IrBlockNil)))))

(define (compiler-reg-move-chain-function) : CompilerIrFunction
  (IrFunction
    "move_chain"
    IrParamNil
    (AstTyI64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 41) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueVar 0) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrMov 2 (IrValueVar 1) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 2)))
                IrInstrNil)))))
      IrBlockNil)))

(define (compiler-reg-same-value-multi-def-census-function) : CompilerIrFunction
  (IrFunction
    "same_value_multi_def_census"
    IrParamNil
    (AstTyI64)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrAlloc 0 (compiler-reg-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 7) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrMov 1 (IrValueVar 0) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 1)))
                IrInstrNil)))))
      IrBlockNil)))

(define (compiler-reg-phi-join-function) : CompilerIrFunction
  (IrFunction
    "phi_join"
    IrParamNil
    (AstTyI64)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 7) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons (IrInstrJump "join") IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "join"
          (compiler-ir-instr-cons
            (IrInstrPhi
              1
              (compiler-ir-phi-input-cons (IrValueVar 0) "entry" IrPhiInputNil)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 1)))
              IrInstrNil)))
        IrBlockNil))))

(define (compiler-reg-loop-backedge-function) : CompilerIrFunction
  (IrFunction
    "loop_backedge"
    IrParamNil
    (AstTyI64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 0) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons (IrInstrJump "loop") IrInstrNil)))
      (compiler-ir-block-cons
        (compiler-ir-block
          "loop"
          (compiler-ir-instr-cons
            (IrInstrPhi
              1
              (compiler-ir-phi-input-cons
                (IrValueVar 0)
                "entry"
                (compiler-ir-phi-input-cons (IrValueVar 2) "body" IrPhiInputNil))
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrMov 2 (IrValueVar 1) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrBranch (IrValueBool false) "body" "exit")
                IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "body"
            (compiler-ir-instr-cons (IrInstrJump "loop") IrInstrNil))
          (compiler-ir-block-cons
            (compiler-ir-block
              "exit"
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 2)))
                IrInstrNil))
            IrBlockNil))))))

(define (compiler-reg-same-value-clobber-function) : CompilerIrFunction
  (IrFunction
    "same_value_clobber"
    IrParamNil
    (AstTyI64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 7) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrCall 1 "side_effect" IrCallArgsNil (AstTyUnit))
            (compiler-ir-instr-cons
              (IrInstrMov 2 (IrValueVar 0) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 2)))
                IrInstrNil)))))
      IrBlockNil)))

(define (compiler-reg-interference-blocks-coalesce-function) : CompilerIrFunction
  (IrFunction
    "interference_blocks_coalesce"
    IrParamNil
    (AstTyI64)
    2
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 9) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueVar 0) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrStore "keep" (IrValueVar 0) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 1)))
                IrInstrNil)))))
      IrBlockNil)))

(define (compiler-reg-spill-coalesce-function) : CompilerIrFunction
  (IrFunction
    "spill_coalesce"
    IrParamNil
    (AstTyI64)
    6
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 0) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueI64 1) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrMov 2 (IrValueI64 2) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrMov 3 (IrValueI64 3) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (IrInstrMov 4 (IrValueI64 4) (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (IrInstrStore "g0" (IrValueVar 0) (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (IrInstrStore "g1" (IrValueVar 1) (compiler-reg-i64-ty))
                      (compiler-ir-instr-cons
                        (IrInstrStore "g2" (IrValueVar 2) (compiler-reg-i64-ty))
                        (compiler-ir-instr-cons
                          (IrInstrStore
                            "g3"
                            (IrValueVar 3)
                            (compiler-reg-i64-ty))
                          (compiler-ir-instr-cons
                            (IrInstrMov 5 (IrValueVar 4) (compiler-reg-i64-ty))
                            (compiler-ir-instr-cons
                              (IrInstrReturn (IrSomeValue (IrValueVar 5)))
                              IrInstrNil))))))))))))
      IrBlockNil)))

(define (compiler-reg-vector-home-function) : CompilerIrFunction
  (IrFunction
    "vector_home"
    IrParamNil
    (AstTyUnit)
    4
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrVectorLoad 0 (IrValueI64 0) (IrValueI64 0) 4 (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrVectorLoad 1 (IrValueI64 0) (IrValueI64 4) 4 (AstTyI64))
            (compiler-ir-instr-cons
              (ir-instr-vector-bin-op
                2
                (IrBinAdd)
                (IrValueVar 0)
                (IrValueVar 1)
                4
                (AstTyI64))
              (compiler-ir-instr-cons
                (ir-instr-vector-bin-op
                  3
                  (IrBinAdd)
                  (IrValueVar 0)
                  (IrValueVar 2)
                  4
                  (AstTyI64))
                (compiler-ir-instr-cons
                  (ir-instr-vector-store
                    (IrValueI64 0)
                    (IrValueI64 8)
                    (IrValueVar 3)
                    4
                    (AstTyI64))
                  (compiler-ir-instr-cons (IrInstrReturn IrNoValue) IrInstrNil)))))))
      IrBlockNil)))

(define (compiler-reg-vector-select-false-home-function) : CompilerIrFunction
  (IrFunction
    "vector_select_false_home"
    IrParamNil
    (AstTyUnit)
    5
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrSplat 0 (IrValueI64 0) 8 (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrSplat 1 (IrValueI64 1) 8 (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrSplat 2 (IrValueI64 2) 8 (AstTyI64))
              (compiler-ir-instr-cons
                (ir-instr-vector-store
                  (IrValueI64 0)
                  (IrValueI64 0)
                  (IrValueVar 0)
                  8
                  (AstTyI64))
                (compiler-ir-instr-cons
                  (ir-instr-vector-compare
                    3
                    (IrBinLt)
                    (IrValueVar 2)
                    (IrValueVar 1)
                    8
                    (AstTyI64))
                  (compiler-ir-instr-cons
                    (ir-instr-select
                      4
                      (IrValueVar 3)
                      (IrValueVar 2)
                      (IrValueVar 1)
                      8
                      (AstTyI64))
                    (compiler-ir-instr-cons
                      (ir-instr-vector-store
                        (IrValueI64 0)
                        (IrValueI64 8)
                        (IrValueVar 4)
                        8
                        (AstTyI64))
                      (compiler-ir-instr-cons
                        (IrInstrReturn IrNoValue)
                        IrInstrNil)))))))))
      IrBlockNil)))

(define (compiler-reg-mask-home-function) : CompilerIrFunction
  (IrFunction
    "mask_home"
    IrParamNil
    (AstTyUnit)
    5
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrTailMask 0 (IrValueI64 0) (IrValueI64 8) 8)
          (compiler-ir-instr-cons
            (IrInstrTailMask 1 (IrValueI64 4) (IrValueI64 8) 8)
            (compiler-ir-instr-cons
              (IrInstrMaskBinOp 2 (IrMaskAnd) (IrValueVar 0) (IrValueVar 1) 8)
              (compiler-ir-instr-cons
                (IrInstrMaskNot 3 (IrValueVar 2) 8)
                (compiler-ir-instr-cons
                  (IrInstrMaskReduce 4 (IrMaskReduceAny) (IrValueVar 3) 8)
                  (compiler-ir-instr-cons
                    (IrInstrReturn (IrSomeValue (IrValueVar 4)))
                    IrInstrNil)))))))
      IrBlockNil)))

(define (compiler-reg-reuse-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-reuse-function))
    [(CompilerRegPlan assignments _ _ _ _)
      (and
        (= (compiler-reg-assignment-count assignments) 2)
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 0)
          "%r12")
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 1)
          "%r12"))]))

(define (compiler-reg-f64-reuse-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-f64-reuse-function))
    [(CompilerRegPlan assignments _ _ _ _)
      (and
        (= (compiler-reg-assignment-count assignments) 2)
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 0)
          "%xmm2")
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 1)
          "%xmm2"))]))

(define (compiler-reg-overlap-spill-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-overlap-function))
    [(CompilerRegPlan assignments _ _ _ _)
      ;; Seven simultaneously live values against a five-register callee-saved
      ;; pool: the first five take %r12..%r15 and %rbx, and the remaining two
      ;; spill. %rbx joined the pool once its fixed scratch role moved under the
      ;; scavenger.
      (and
        (= (compiler-reg-assignment-count assignments) 7)
        (= (compiler-reg-spill-count assignments) 2)
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 3)
          "%r15")
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 4)
          "%rbx")
        (compiler-reg-location-spill-offset?
          (compiler-reg-assignment-lookup assignments 6)
          (compiler-reg-stack-slot-offset 6)))]))

(define (compiler-reg-f64-overlap-spill-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-f64-overlap-function))
    [(CompilerRegPlan assignments _ _ _ _)
      (and
        (= (compiler-reg-assignment-count assignments) 5)
        (= (compiler-reg-spill-count assignments) 1)
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 0)
          "%xmm2")
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 1)
          "%xmm3")
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 2)
          "%xmm4")
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 3)
          "%xmm5")
        (compiler-reg-location-spill-offset?
          (compiler-reg-assignment-lookup assignments 4)
          (compiler-reg-stack-slot-offset 4)))]))

(define (compiler-reg-call-live-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-call-live-function))
    [(CompilerRegPlan assignments ineligible _ _ _)
      (and
        (compiler-live-set-contains? ineligible 0)
        (compiler-live-set-contains? ineligible 1)
        (compiler-reg-unassigned? assignments 0)
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 2)
          "%r12"))]))

;; Scalar plan (#perf): the same function, but an integer value live across a
;; call now keeps a callee-saved register home (the integer pool is call-safe),
;; while the unit call result stays ineligible.
(define (compiler-reg-scalar-call-live-ok?) : bool
  (match (compiler-reg-plan-function-scalar (compiler-reg-call-live-function))
    [(CompilerRegPlan assignments ineligible _ _ _)
      (and
        (not (compiler-live-set-contains? ineligible 0))
        (compiler-reg-location-any-register?
          (compiler-reg-assignment-lookup assignments 0))
        (compiler-reg-location-any-register?
          (compiler-reg-assignment-lookup assignments 2)))]))

;; Scalar plan correctness: a FLOAT value live across a call must NOT be homed in
;; the caller-saved XMM pool, so it stays ineligible even on the scalar path.
(define (compiler-reg-scalar-f64-call-live-ok?) : bool
  (match (compiler-reg-plan-function-scalar
    (compiler-reg-f64-call-live-function))
    [(CompilerRegPlan assignments ineligible _ _ _)
      (and
        (compiler-live-set-contains? ineligible 0)
        (compiler-reg-unassigned? assignments 0))]))

(define (compiler-reg-f64-call-live-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-f64-call-live-function))
    [(CompilerRegPlan assignments ineligible _ _ _)
      (and
        (compiler-live-set-contains? ineligible 0)
        (compiler-live-set-contains? ineligible 1)
        (compiler-reg-unassigned? assignments 0)
        (compiler-reg-unassigned? assignments 1)
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 2)
          "%xmm2"))]))

(define (compiler-reg-call-arg-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-call-arg-function))
    [(CompilerRegPlan assignments ineligible _ _ _)
      (and
        (compiler-live-set-contains? ineligible 0)
        (compiler-live-set-contains? ineligible 1)
        (compiler-reg-unassigned? assignments 0)
        (compiler-reg-unassigned? assignments 1)
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 3)
          "%r12"))]))

(define (compiler-reg-f64-call-arg-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-f64-call-arg-function))
    [(CompilerRegPlan assignments ineligible _ _ _)
      (and
        (compiler-live-set-contains? ineligible 0)
        (compiler-reg-unassigned? assignments 0)
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 2)
          "%xmm2"))]))

(define (compiler-reg-ineligible-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-ineligible-function))
    [(CompilerRegPlan assignments ineligible _ _ _)
      (let
        [marked : bool
          (and
            (compiler-live-set-contains? ineligible 0)
            (compiler-live-set-contains? ineligible 2)
            (compiler-live-set-contains? ineligible 3)
            (compiler-live-set-contains? ineligible 4)
            (not (compiler-live-set-contains? ineligible 6)))]
        [unassigned : bool
          (and
            (compiler-reg-unassigned? assignments 0)
            (compiler-reg-unassigned? assignments 2)
            (compiler-reg-unassigned? assignments 3)
            (compiler-reg-unassigned? assignments 4))]
        [homes : bool
          (and
            (compiler-reg-location-register?
              (compiler-reg-assignment-lookup assignments 1)
              "%xmm2")
            (compiler-reg-location-register?
              (compiler-reg-assignment-lookup assignments 5)
              "%r12")
            (compiler-reg-location-any-register?
              (compiler-reg-assignment-lookup assignments 6)))]
        (and marked unassigned homes))]))

;; Scalar plan (#perf): String/DynArray handles (vars 2/4), AddrOf results
;; (var 6), and clobber-free integer params (var 0) are register-eligible
;; 8-byte values; address-taken values (var 3 via the AddrOf) stay ineligible.
(define (compiler-reg-scalar-handle-eligible-ok?) : bool
  (match (compiler-reg-plan-function-scalar (compiler-reg-ineligible-function))
    [(CompilerRegPlan assignments ineligible _ _ _)
      (and
        (not (compiler-live-set-contains? ineligible 0))
        (compiler-live-set-contains? ineligible 3)
        (not (compiler-live-set-contains? ineligible 2))
        (not (compiler-live-set-contains? ineligible 4))
        (not (compiler-live-set-contains? ineligible 6))
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 0)
          "%rdi"))]))

(cfg
  test
  (define (compiler-reg-scalar-linux-param-registers-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegAbiLinux
      (compiler-reg-param-register-function))
      [(CompilerRegPlan assignments ineligible _ _ _)
        (and
          (not (compiler-live-set-contains? ineligible 0))
          (not (compiler-live-set-contains? ineligible 1))
          (not (compiler-live-set-contains? ineligible 2))
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 0)
            "%rdi")
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 1)
            "%rsi")
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 2)
            "%rdx"))])))

(cfg
  test
  (define (compiler-reg-scalar-windows-param-registers-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegAbiWindows
      (compiler-reg-param-register-function))
      [(CompilerRegPlan assignments ineligible _ _ _)
        (and
          (not (compiler-live-set-contains? ineligible 0))
          (not (compiler-live-set-contains? ineligible 1))
          (compiler-live-set-contains? ineligible 2)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 0)
            "%rcx")
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 1)
            "%rdx")
          (compiler-reg-unassigned? assignments 2))])))

(cfg
  test
  (define (compiler-reg-scalar-param-clobber-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegAbiLinux
      (compiler-reg-param-clobber-function))
      [(CompilerRegPlan assignments ineligible _ _ _)
        (and
          (compiler-live-set-contains? ineligible 0)
          (compiler-reg-unassigned? assignments 0))])))

(cfg
  test
  (define (compiler-reg-scalar-aggregate-param-not-pinned-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegAbiLinux
      (compiler-reg-param-aggregate-function))
      [(CompilerRegPlan assignments ineligible _ _ _)
        (and
          (compiler-live-set-contains? ineligible 0)
          (compiler-reg-unassigned? assignments 0))])))

(define (compiler-reg-scalar-function-intervals-ok?) : bool
  (match (compiler-reg-plan-function-scalar
    (compiler-reg-param-livein-gap-function))
    [(CompilerRegPlan _ _ intervals _ _)
      (compiler-reg-interval-range? intervals 0 1 4)]))

(define (compiler-reg-scalar-interval-guardrail-ok?) : bool
  (match (compiler-reg-plan-function-scalar
    (compiler-reg-single-block-livein-gap-function))
    [(CompilerRegPlan _ _ intervals _ _)
      (compiler-reg-interval-range? intervals 0 0 2)]))

(define (compiler-reg-scalar-loop-backedge-ok?) : bool
  (match (compiler-reg-plan-function-scalar
    (compiler-reg-loop-backedge-function))
    [(CompilerRegPlan assignments _ _ _ _)
      (and
        (compiler-reg-location-any-register?
          (compiler-reg-assignment-lookup assignments 1))
        (compiler-reg-location-any-register?
          (compiler-reg-assignment-lookup assignments 2))
        (compiler-reg-same-location? assignments 1 2))]))

(define (compiler-reg-syscall-clobber-overlap-function) : CompilerIrFunction
  (IrFunction
    "syscall_clobber_overlap"
    IrParamNil
    (AstTyUnit)
    7
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 0) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueI64 1) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrMov 2 (IrValueI64 2) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrMov 3 (IrValueI64 3) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (IrInstrMov 4 (IrValueI64 4) (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (IrInstrMov 5 (IrValueI64 5) (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (IrInstrSyscall 6 (IrCallArgsOne (IrValueI64 39)))
                      (compiler-ir-instr-cons
                        (IrInstrStore "g0" (IrValueVar 0) (compiler-reg-i64-ty))
                        (compiler-ir-instr-cons
                          (IrInstrStore
                            "g1"
                            (IrValueVar 1)
                            (compiler-reg-i64-ty))
                          (compiler-ir-instr-cons
                            (IrInstrStore
                              "g2"
                              (IrValueVar 2)
                              (compiler-reg-i64-ty))
                            (compiler-ir-instr-cons
                              (IrInstrStore
                                "g3"
                                (IrValueVar 3)
                                (compiler-reg-i64-ty))
                              (compiler-ir-instr-cons
                                (IrInstrStore
                                  "g4"
                                  (IrValueVar 4)
                                  (compiler-reg-i64-ty))
                                (compiler-ir-instr-cons
                                  (IrInstrStore
                                    "g5"
                                    (IrValueVar 5)
                                    (compiler-reg-i64-ty))
                                  (compiler-ir-instr-cons
                                    (IrInstrReturn IrNoValue)
                                    IrInstrNil)))))))))))))))
      IrBlockNil)))

(define (compiler-reg-call-spanning-caller-saved-function) : CompilerIrFunction
  (let
    [instrs : CompilerIrInstrList IrInstrNil]
    (begin
      (set! instrs (compiler-ir-instr-cons (IrInstrReturn IrNoValue) instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrStore "g5c" (IrValueVar 5) (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrStore "g5b" (IrValueVar 5) (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrStore "g6" (IrValueVar 6) (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrStore "g5" (IrValueVar 5) (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrStore "g4" (IrValueVar 4) (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrStore "g3" (IrValueVar 3) (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrStore "g2" (IrValueVar 2) (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrStore "g1" (IrValueVar 1) (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrStore "g0" (IrValueVar 0) (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrCall 7 "side_effect" (IrCallArgsNil) (AstTyUnit))
          instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrMov 6 (IrValueI64 6) (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrMov 5 (IrValueI64 5) (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrMov 4 (IrValueI64 4) (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrMov 3 (IrValueI64 3) (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrMov 2 (IrValueI64 2) (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrMov 1 (IrValueI64 1) (compiler-reg-i64-ty))
          instrs))
      (set!
        instrs
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 0) (compiler-reg-i64-ty))
          instrs))
      (IrFunction
        "call_spanning_caller_saved"
        IrParamNil
        (AstTyUnit)
        8
        (compiler-ir-block-cons (compiler-ir-block "entry" instrs) IrBlockNil)))))

(define (compiler-reg-scalar-zero-call-caller-saved-ok?) : bool
  (match (compiler-reg-plan-function-scalar (compiler-reg-overlap-function))
    [(CompilerRegPlan assignments _ _ _ _)
      (and
        (= (compiler-reg-assignment-count assignments) 7)
        (= (compiler-reg-spill-count assignments) 0)
        ;; #perf call-spanning-aware partitioning homes the non-call-spanning
        ;; values in the caller-saved pool in candidate order. With %rax/%rsi/%rdi
        ;; now pooled at the front, the leading vars land on %rax/%rsi/%rdi (was
        ;; %r9/%rcx/%rdx). Every value still gets a register (0 spills); sound here
        ;; because this is a zero-call function -- no clobber across a call.
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 0)
          "%rax")
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 1)
          "%rsi")
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 2)
          "%rdi"))]))

(cfg
  test
  (define (compiler-reg-scalar-zero-call-param-conflict-ok?) : bool
    (match (compiler-reg-plan-function-scalar-for-abi
      CompilerRegAbiLinux
      (compiler-reg-zero-call-param-conflict-function))
      [(CompilerRegPlan assignments _ _ _ _)
        (and
          (= (compiler-reg-spill-count assignments) 0)
          ;; #perf call-spanning-aware partitioning fills the caller-saved
          ;; zero-call pool (%r9/%rcx/%rdx) in candidate order, so the first three
          ;; zero-call values (5,6,7) take it and the rest fall to callee-saved;
          ;; every value still gets a register past the pinned-param conflicts.
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 5)
            "%r9")
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 6)
            "%rcx")
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 7)
            "%rdx"))])))

(define (compiler-reg-scalar-caller-saved-clobber-ok?) : bool
  (match (compiler-reg-plan-function-scalar
    (compiler-reg-syscall-clobber-overlap-function))
    [(CompilerRegPlan assignments _ _ _ _)
      (and
        (= (compiler-reg-spill-count assignments) 1)
        (compiler-reg-location-spill-offset?
          (compiler-reg-assignment-lookup assignments 5)
          (compiler-reg-stack-slot-offset 5)))]))

(cfg
  test
  (define (compiler-reg-remat-weight-function) : CompilerIrFunction
    (IrFunction
      "remat_weight"
      IrParamNil
      (AstTyUnit)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 7) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrBinOp
                1
                (IrBinAdd)
                (IrValueI64 1)
                (IrValueI64 2)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrStore "use1" (IrValueVar 1) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (IrInstrStore "use0a" (IrValueVar 0) (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (IrInstrStore "use0b" (IrValueVar 0) (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (IrInstrReturn IrNoValue)
                      IrInstrNil)))))))
        IrBlockNil))))

(cfg
  test
  (define (compiler-reg-remat-multi-def-function) : CompilerIrFunction
    (IrFunction
      "remat_multi_def"
      IrParamNil
      (AstTyUnit)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 7) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrBinOp
                0
                (IrBinAdd)
                (IrValueI64 1)
                (IrValueI64 2)
                (compiler-reg-i64-ty))
              (compiler-ir-instr-cons (IrInstrReturn IrNoValue) IrInstrNil))))
        IrBlockNil))))

(cfg
  test
  (define (compiler-reg-remat-classifier-ok?) : bool
    (and
      (compiler-reg-remat-defn?
        (IrInstrMov 10 (IrValueI64 1) (compiler-reg-i64-ty)))
      (compiler-reg-remat-defn? (IrInstrMov 11 (IrValueBool true) (AstTyBool)))
      (compiler-reg-remat-defn? (IrInstrMov 12 (IrValueChar 'x') (AstTyChar)))
      (compiler-reg-remat-defn?
        (IrInstrMov 13 (IrValueF64 0x3ff0000000000000) (compiler-reg-f64-ty)))
      (compiler-reg-remat-defn?
        (IrInstrMov 14 (IrValueGlobalAddr "global") (AstTyU64)))
      (not
        (compiler-reg-remat-defn?
          (IrInstrMov 15 (IrValueGlobal "global") (compiler-reg-i64-ty))))
      (compiler-reg-remat-defn-with-invariant-loads?
        (IrInstrMov 16 (IrValueGlobal "global") (compiler-reg-i64-ty))
        true)
      (compiler-reg-remat-defn?
        (IrInstrGep
          17
          (IrValueGlobalAddr "global")
          (IrValueI64 2)
          (compiler-reg-i64-ty)))
      (not
        (compiler-reg-remat-defn?
          (IrInstrGep
            18
            (IrValueGlobalAddr "global")
            (IrValueVar 0)
            (compiler-reg-i64-ty))))
      (not
        (compiler-reg-remat-defn?
          (IrInstrGep 19 (IrValueVar 0) (IrValueI64 2) (compiler-reg-i64-ty))))
      (not
        (compiler-reg-remat-defn?
          (IrInstrLoad 20 (IrValueGlobalAddr "global") (compiler-reg-i64-ty))))
      (compiler-reg-remat-defn-with-invariant-loads?
        (IrInstrLoad 21 (IrValueGlobalAddr "global") (compiler-reg-i64-ty))
        true)
      (not
        (compiler-reg-remat-defn-with-invariant-loads?
          (IrInstrLoad 22 (IrValueVar 0) (compiler-reg-i64-ty))
          true))
      (not
        (compiler-reg-remat-defn?
          (IrInstrMov 23 (IrValueVar 0) (compiler-reg-i64-ty))))
      (not
        (compiler-reg-remat-defn?
          (IrInstrMov 24 (IrValueString "heap") (AstTyString))))
      (not
        (compiler-reg-remat-defn?
          (IrInstrBinOp
            25
            (IrBinAdd)
            (IrValueI64 1)
            (IrValueI64 2)
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
        (array.array-set! parents 0 0)
        (array.array-set! parents 1 0)
        (let
          [coalesced : (Array i64)
            (compiler-reg-function-spill-weights-remat
              func
              (CompilerRegCoalesceMap parents))]
          (and
            (= (array.array-ref raw 0) 3)
            (= (array.array-ref raw 1) 2)
            (= (array.array-ref discounted 0) 1)
            (= (array.array-ref discounted 1) 2)
            (= (array.array-ref coalesced 0) 3)
            (= (array.array-ref coalesced 1) 2)
            (= (array.array-ref multi-raw 0) 2)
            (= (array.array-ref multi-discounted 0) 2)))))))

(cfg
  test
  (define (compiler-reg-remat-spill-weight-eviction-function) : CompilerIrFunction
    (let
      [instrs : CompilerIrInstrList IrInstrNil]
      (begin
        (set! instrs (compiler-ir-instr-cons (IrInstrReturn IrNoValue) instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "hot0b" (IrValueVar 0) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "hot0a" (IrValueVar 0) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "cold1" (IrValueVar 1) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "use5" (IrValueVar 5) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "use4" (IrValueVar 4) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "use3" (IrValueVar 3) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "use2" (IrValueVar 2) (compiler-reg-i64-ty))
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
            (IrInstrSyscall 6 (IrCallArgsOne (IrValueI64 39)))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 5 (IrValueI64 5) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 4 (IrValueI64 4) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 3 (IrValueI64 3) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 2 (IrValueI64 2) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrBinOp
              1
              (IrBinAdd)
              (IrValueI64 1)
              (IrValueI64 2)
              (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 0) (compiler-reg-i64-ty))
            instrs))
        (IrFunction
          "remat_spill_weight_eviction"
          IrParamNil
          (AstTyUnit)
          7
          (compiler-ir-block-cons (compiler-ir-block "entry" instrs) IrBlockNil))))))

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
        [(CompilerRegPlan assignments _ _ _ _)
          (and
            (> (array.array-ref raw 0) (array.array-ref raw 1))
            (< (array.array-ref discounted 0) (array.array-ref discounted 1))
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
      [instrs : CompilerIrInstrList IrInstrNil]
      (begin
        (set! instrs (compiler-ir-instr-cons (IrInstrReturn IrNoValue) instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "hot0c" (IrValueVar 0) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "hot0b" (IrValueVar 0) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "hot0a" (IrValueVar 0) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "cold1" (IrValueVar 1) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "use5b" (IrValueVar 5) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "use5a" (IrValueVar 5) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "use4b" (IrValueVar 4) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "use4a" (IrValueVar 4) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "use3b" (IrValueVar 3) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "use3a" (IrValueVar 3) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "use2b" (IrValueVar 2) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrStore "use2a" (IrValueVar 2) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrSyscall 6 (IrCallArgsOne (IrValueI64 39)))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 5 (IrValueI64 5) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 4 (IrValueI64 4) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 3 (IrValueI64 3) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 2 (IrValueI64 2) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueI64 1) (compiler-reg-i64-ty))
            instrs))
        (set!
          instrs
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 0) (compiler-reg-i64-ty))
            instrs))
        (IrFunction
          "spill_weight_eviction"
          IrParamNil
          (AstTyUnit)
          7
          (compiler-ir-block-cons (compiler-ir-block "entry" instrs) IrBlockNil))))))

(cfg
  test
  (define (compiler-reg-spill-weight-eviction-ok?) : bool
    (match (compiler-reg-plan-function-scalar
      (compiler-reg-spill-weight-eviction-function))
      [(CompilerRegPlan assignments _ _ _ _)
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
    (IrFunction
      "loop_spill_weight_eviction"
      IrParamNil
      (AstTyUnit)
      7
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 0) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrMov 1 (IrValueI64 1) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrMov 2 (IrValueI64 2) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (IrInstrMov 3 (IrValueI64 3) (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (IrInstrMov 4 (IrValueI64 4) (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (IrInstrMov 5 (IrValueI64 5) (compiler-reg-i64-ty))
                      (compiler-ir-instr-cons
                        (IrInstrSyscall 6 (IrCallArgsOne (IrValueI64 39)))
                        (compiler-ir-instr-cons (IrInstrJump "loop") IrInstrNil)))))))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "loop"
            (compiler-ir-instr-cons
              (IrInstrStore "hot0" (IrValueVar 0) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrStore "hot2" (IrValueVar 2) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (IrInstrStore "hot3" (IrValueVar 3) (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (IrInstrStore "hot4" (IrValueVar 4) (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (IrInstrStore "hot5" (IrValueVar 5) (compiler-reg-i64-ty))
                      (compiler-ir-instr-cons
                        (IrInstrBranch (IrValueBool false) "body" "exit")
                        IrInstrNil)))))))
          (compiler-ir-block-cons
            (compiler-ir-block
              "body"
              (compiler-ir-instr-cons (IrInstrJump "loop") IrInstrNil))
            (compiler-ir-block-cons
              (compiler-ir-block
                "exit"
                (compiler-ir-instr-cons
                  (IrInstrStore "cold1" (IrValueVar 1) (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons (IrInstrReturn IrNoValue) IrInstrNil)))
              IrBlockNil)))))))

(cfg
  test
  (define (compiler-reg-loop-spill-weight-eviction-ok?) : bool
    (let
      [func : CompilerIrFunction
        (compiler-reg-loop-spill-weight-eviction-function)]
      [static-counts : (Array i64) (compiler-reg-function-ref-counts func)]
      [weighted-counts : (Array i64) (compiler-reg-function-spill-weights func)]
      (match (compiler-reg-plan-function-scalar func)
        [(CompilerRegPlan assignments _ _ _ _)
          (and
            (=
              (array.array-ref static-counts 0)
              (array.array-ref static-counts 1))
            (>
              (array.array-ref weighted-counts 0)
              (array.array-ref weighted-counts 1))
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
      [(IrInstrNil) false]
      [(IrInstrCons instr rest)
        (match instr
          [(IrInstrMov found-dst found-value _)
            (match found-value
              [(IrValueI64 found)
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
      [(IrInstrNil) false]
      [(IrInstrCons instr rest)
        (match instr
          [(IrInstrMov found-dst found-value _)
            (match found-value
              [(IrValueVar found-src)
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
      [(IrInstrNil) false]
      [(IrInstrCons instr rest)
        (match instr
          [(IrInstrMov found-dst found-value _)
            (match found-value
              [(IrValueGlobal found-name)
                (if (and (= found-dst dst) (string.string-eq found-name name))
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
      [(IrInstrNil) false]
      [(IrInstrCons instr rest)
        (match instr
          [(IrInstrLoad found-dst found-src _)
            (match found-src
              [(IrValueGlobalAddr found-name)
                (if (and (= found-dst dst) (string.string-eq found-name name))
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
      [(IrInstrNil) false]
      [(IrInstrCons instr rest)
        (match instr
          [(IrInstrGep found-dst found-base found-offset found-ty)
            (match found-base
              [(IrValueGlobalAddr found-name)
                (match found-offset
                  [(IrValueI64 found-offset-value)
                    (if (and
                      (= found-dst dst)
                      (and
                        (string.string-eq found-name name)
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
      [(IrInstrNil) false]
      [(IrInstrCons instr rest)
        (match instr
          [(IrInstrStore found-name found-value _)
            (match found-value
              [(IrValueVar found-src)
                (if (and (string.string-eq found-name name) (= found-src src))
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
  (define (compiler-reg-instr-list-has-call-indirect-var?
    [instrs : CompilerIrInstrList]
    [callee : i64]) : bool
    (match instrs
      [(IrInstrNil) false]
      [(IrInstrCons instr rest)
        (match instr
          [(IrInstrCallIndirect _ found-callee _ _)
            (match found-callee
              [(IrValueVar found)
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
      [(IrInstrNil) false]
      [(IrInstrCons instr rest)
        (match instr
          [(IrInstrReturn maybe)
            (match maybe
              [(IrSomeValue value)
                (match value
                  [(IrValueVar found)
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
  (define (compiler-reg-first-block-instr-list [blocks : CompilerIrBlockList]) : CompilerIrInstrList
    (match blocks
      [(IrBlockCons block _)
        (match block
          [(IrBlock _ instrs) (compiler-ir-instr-seq-to-list instrs)])]
      [(IrBlockArray seq)
        (compiler-reg-first-block-instr-list
          (compiler-ir-block-seq-to-list seq))]
      [_ IrInstrNil])))

(cfg
  test
  (define (compiler-reg-block-instr-list
    [blocks : CompilerIrBlockList]
    [want-label : String]) : CompilerIrInstrList
    (match blocks
      [(IrBlockCons block rest)
        (match block
          [(IrBlock label instrs)
            (if (string.string-eq label want-label)
              (compiler-ir-instr-seq-to-list instrs)
              (compiler-reg-block-instr-list (box-get rest) want-label))])]
      [(IrBlockArray seq)
        (compiler-reg-block-instr-list
          (compiler-ir-block-seq-to-list seq)
          want-label)]
      [_ IrInstrNil])))

(cfg
  test
  (define (compiler-reg-remat-rewrite-function) : CompilerIrFunction
    (IrFunction
      "remat_rewrite"
      IrParamNil
      (AstTyUnit)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 7) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrStore "use0a" (IrValueVar 0) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrStore "use0b" (IrValueVar 0) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons (IrInstrReturn IrNoValue) IrInstrNil)))))
        IrBlockNil))))

(cfg
  test
  (define (compiler-reg-remat-conflict-function) : CompilerIrFunction
    (IrFunction
      "remat_conflict"
      IrParamNil
      (AstTyUnit)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 7) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrMov 1 (IrValueI64 9) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrStore "use0" (IrValueVar 0) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (IrInstrStore "keep1" (IrValueVar 1) (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons (IrInstrReturn IrNoValue) IrInstrNil))))))
        IrBlockNil))))

(cfg
  test
  (define (compiler-reg-remat-caller-clobber-function) : CompilerIrFunction
    (IrFunction
      "remat_caller_clobber"
      IrParamNil
      (AstTyUnit)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueGlobalAddr "callee") (AstTyU64))
            (compiler-ir-instr-cons
              (IrInstrCallIndirect 1 (IrValueVar 0) IrCallArgsNil (AstTyUnit))
              (compiler-ir-instr-cons (IrInstrReturn IrNoValue) IrInstrNil))))
        IrBlockNil))))

(cfg
  test
  (define (compiler-reg-remat-global-mov-function) : CompilerIrFunction
    (IrFunction
      "remat_global_mov"
      IrParamNil
      (compiler-reg-i64-ty)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueGlobal "global_value") (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 0)))
              IrInstrNil)))
        IrBlockNil))))

(cfg
  test
  (define (compiler-reg-remat-global-load-function) : CompilerIrFunction
    (IrFunction
      "remat_global_load"
      IrParamNil
      (compiler-reg-i64-ty)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrLoad
              0
              (IrValueGlobalAddr "global_value")
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 0)))
              IrInstrNil)))
        IrBlockNil))))

(cfg
  test
  (define (compiler-reg-remat-global-gep-function) : CompilerIrFunction
    (IrFunction
      "remat_global_gep"
      IrParamNil
      (compiler-reg-addr-of-result-type)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrGep
              0
              (IrValueGlobalAddr "global_value")
              (IrValueI64 3)
              (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 0)))
              IrInstrNil)))
        IrBlockNil))))

(cfg
  test
  (define (compiler-reg-remat-global-mutating-function) : CompilerIrFunction
    (IrFunction
      "remat_global_mutating"
      IrParamNil
      (compiler-reg-i64-ty)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueGlobal "global_value") (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrStore "global_value" (IrValueI64 1) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                IrInstrNil))))
        IrBlockNil))))

(cfg
  test
  (define (compiler-reg-remat-single-spill-plan [func : CompilerIrFunction]) : CompilerRegPlan
    (CompilerRegPlan
      (compiler-reg-assignment-cons
        (CompilerRegAssignment
          0
          (CompilerRegSpill (compiler-reg-stack-slot-offset 0)))
        CompilerRegAssignmentNil)
      (compiler-live-set-empty)
      CompilerRegIntervalNil
      (compiler-reg-var-types-list (compiler-reg-function-var-types func))
      (compiler-live-set-empty))))

(cfg
  test
  (define (compiler-reg-remat-conflict-plan [func : CompilerIrFunction]) : CompilerRegPlan
    (CompilerRegPlan
      (compiler-reg-assignment-cons
        (CompilerRegAssignment
          0
          (CompilerRegSpill (compiler-reg-stack-slot-offset 0)))
        (compiler-reg-assignment-cons
          (CompilerRegAssignment 1 (CompilerRegRegister "%r9"))
          CompilerRegAssignmentNil))
      (compiler-live-set-empty)
      CompilerRegIntervalNil
      (compiler-reg-var-types-list (compiler-reg-function-var-types func))
      (compiler-live-set-empty))))

(cfg
  test
  (define (compiler-reg-remat-rewrite-shape-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-remat-rewrite-function)]
      [plan : CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(IrFunction _ _ _ vars blocks)
          (match (compiler-reg-remat-rewrite-blocks
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite
                rewritten
                _
                out-vars
                extra-assignments
                extra-types)
              (let
                [items : CompilerIrInstrList
                  (compiler-reg-block-instr-list rewritten "entry")]
                [rewritten-plan : CompilerRegPlan
                  (compiler-reg-plan-with-call-save-rewrite
                    plan
                    (CompilerRegCallSaveRewrite
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
                    "%r9")
                  (compiler-reg-location-register?
                    (compiler-reg-assignment-lookup
                      rewritten-assignments
                      (+ vars 1))
                    "%r9")
                  (compiler-reg-instr-list-has-mov-i64? items vars 7)
                  (compiler-reg-instr-list-has-mov-i64? items (+ vars 1) 7)
                  (compiler-reg-instr-list-has-store-var? items "use0a" vars)
                  (compiler-reg-instr-list-has-store-var?
                    items
                    "use0b"
                    (+ vars 1))
                  (match (compiler-reg-var-type-lookup rewritten-types vars)
                    [(CompilerRegSomeType ty)
                      (match ty
                        [(AstTyI64) true]
                        [_ false])]
                    [(CompilerRegNoType) false])
                  (match (compiler-reg-var-type-lookup
                    rewritten-types
                    (+ vars 1))
                    [(CompilerRegSomeType ty)
                      (match ty
                        [(AstTyI64) true]
                        [_ false])]
                    [(CompilerRegNoType) false])
                  (not (compiler-reg-instr-list-has-store-var? items "use0a" 0))
                  (not (compiler-reg-instr-list-has-store-var? items "use0b" 0))))])]))))

(cfg
  test
  (define (compiler-reg-remat-register-conflict-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-remat-conflict-function)]
      [plan : CompilerRegPlan (compiler-reg-remat-conflict-plan func)]
      (match func
        [(IrFunction _ _ _ vars blocks)
          (match (compiler-reg-remat-rewrite-blocks
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : CompilerIrInstrList
                  (compiler-reg-block-instr-list rewritten "entry")]
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
        [(IrFunction _ _ _ vars blocks)
          (match (compiler-reg-remat-rewrite-blocks
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : CompilerIrInstrList
                  (compiler-reg-block-instr-list rewritten "entry")]
                (and
                  (= out-vars vars)
                  (= (compiler-reg-assignment-count extra-assignments) 0)
                  (compiler-reg-instr-list-has-call-indirect-var? items 0)))])]))))

(cfg
  test
  (define (compiler-reg-remat-global-mov-rewrite-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-remat-global-mov-function)]
      [plan : CompilerRegPlan (compiler-reg-remat-single-spill-plan func)]
      (match func
        [(IrFunction _ _ _ vars blocks)
          (match (compiler-reg-remat-rewrite-blocks
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : CompilerIrInstrList
                  (compiler-reg-block-instr-list rewritten "entry")]
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
        [(IrFunction _ _ _ vars blocks)
          (match (compiler-reg-remat-rewrite-blocks
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : CompilerIrInstrList
                  (compiler-reg-block-instr-list rewritten "entry")]
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
        [(IrFunction _ _ _ vars blocks)
          (match (compiler-reg-remat-rewrite-blocks
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : CompilerIrInstrList
                  (compiler-reg-block-instr-list rewritten "entry")]
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
        [(IrFunction _ _ _ vars blocks)
          (match (compiler-reg-remat-rewrite-blocks
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite
                rewritten
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : CompilerIrInstrList
                  (compiler-reg-block-instr-list rewritten "entry")]
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
  (define (compiler-reg-call-spanning-rewrite-shape-label-ok?
    [func : CompilerIrFunction]
    [plan : CompilerRegPlan]
    [label : String]) : bool
    (match func
      [(IrFunction _ _ _ vars blocks)
        (let
          [type-info : CompilerRegVarTypes
            (compiler-reg-function-var-types func)]
          [rewrite : CompilerRegCallSaveRewrite
            (compiler-reg-caller-save-rewrite-blocks blocks vars type-info plan)]
          (match rewrite
            [(CompilerRegCallSaveRewrite
                rewritten-blocks
                _
                out-vars
                extra-assignments
                _)
              (let
                [items : CompilerIrInstrList
                  (compiler-reg-block-instr-list rewritten-blocks label)]
                [rewritten-plan : CompilerRegPlan
                  (compiler-reg-plan-with-call-save-rewrite plan rewrite)]
                [rewritten-assignments : CompilerRegAssignmentList
                  (compiler-reg-plan-assignments rewritten-plan)]
                (and
                  (= out-vars (+ vars 2))
                  (= (compiler-reg-assignment-count extra-assignments) 2)
                  (compiler-reg-location-register?
                    (compiler-reg-assignment-lookup rewritten-assignments vars)
                    "%r9")
                  (compiler-reg-location-register?
                    (compiler-reg-assignment-lookup
                      rewritten-assignments
                      (+ vars 1))
                    "%r9")
                  (compiler-reg-instr-list-has-mov-i64? items vars 5)
                  (compiler-reg-instr-list-has-mov-var? items 5 vars)
                  (compiler-reg-instr-list-has-mov-var? items (+ vars 1) 5)
                  (compiler-reg-instr-list-has-store-var? items "g5" (+ vars 1))
                  (not (compiler-reg-instr-list-has-store-var? items "g5" 5))))]))])))

(define (compiler-reg-scalar-call-spanning-caller-saved-ok?) : bool
  (let
    [func : CompilerIrFunction
      (compiler-reg-call-spanning-caller-saved-function)]
    [plan : CompilerRegPlan (compiler-reg-plan-function-scalar func)]
    (match plan
      [(CompilerRegPlan assignments _ _ _ split-vars)
        (and
          ;; 7 call-spanning values vs 5 callee-saved registers -> 2 spill (call-
          ;; spanning values cannot use caller-saved across the call). The greedy's
          ;; spill-weight priority keeps the hottest value (var 5, stored 3x)
          ;; register-homed and spills the single-use overflow; var 6 overflows to
          ;; the stack and needs no save/restore rescue. (The old allocator spilled
          ;; var 5 then save/restored it; the unified greedy's weight ordering
          ;; avoids that round-trip -- a strict improvement.)
          (= (compiler-reg-spill-count assignments) 2)
          (compiler-reg-location-spill-offset?
            (compiler-reg-assignment-lookup assignments 6)
            (compiler-reg-stack-slot-offset 6))
          (not (compiler-live-set-contains? split-vars 5))
          (not (compiler-live-set-contains? split-vars 6)))])))

(cfg
  test
  (define (compiler-reg-call-spanning-post-call-stores
    [tail : CompilerIrInstrList]) : CompilerIrInstrList
    (compiler-ir-instr-cons
      (IrInstrStore "g0" (IrValueVar 0) (compiler-reg-i64-ty))
      (compiler-ir-instr-cons
        (IrInstrStore "g1" (IrValueVar 1) (compiler-reg-i64-ty))
        (compiler-ir-instr-cons
          (IrInstrStore "g2" (IrValueVar 2) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrStore "g3" (IrValueVar 3) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrStore "g4" (IrValueVar 4) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrStore "g5" (IrValueVar 5) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (IrInstrStore "g6" (IrValueVar 6) (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (IrInstrStore "g5b" (IrValueVar 5) (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (IrInstrStore "g5c" (IrValueVar 5) (compiler-reg-i64-ty))
                      tail)))))))))))

(cfg
  test
  (define (compiler-reg-call-spanning-defs-before [tail : CompilerIrInstrList]) : CompilerIrInstrList
    (compiler-ir-instr-cons
      (IrInstrMov 0 (IrValueI64 0) (compiler-reg-i64-ty))
      (compiler-ir-instr-cons
        (IrInstrMov 1 (IrValueI64 1) (compiler-reg-i64-ty))
        (compiler-ir-instr-cons
          (IrInstrMov 2 (IrValueI64 2) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons
            (IrInstrMov 3 (IrValueI64 3) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrMov 4 (IrValueI64 4) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons
                (IrInstrMov 5 (IrValueI64 5) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (IrInstrMov 6 (IrValueI64 6) (compiler-reg-i64-ty))
                  tail)))))))))

(cfg
  test
  (define (compiler-reg-call-spanning-call-before [tail : CompilerIrInstrList]) : CompilerIrInstrList
    (compiler-ir-instr-cons
      (IrInstrCall 7 "side_effect" (IrCallArgsNil) (AstTyUnit))
      tail)))

(cfg
  test
  (define (compiler-reg-call-spanning-multiblock-local-function) : CompilerIrFunction
    (let
      [body-tail : CompilerIrInstrList
        (compiler-ir-instr-cons (IrInstrJump "exit") IrInstrNil)]
      [body : CompilerIrInstrList
        (compiler-reg-call-spanning-defs-before
          (compiler-reg-call-spanning-call-before
            (compiler-reg-call-spanning-post-call-stores body-tail)))]
      (IrFunction
        "call_spanning_multiblock_local"
        IrParamNil
        (AstTyUnit)
        8
        (compiler-ir-block-cons
          (compiler-ir-block
            "entry"
            (compiler-ir-instr-cons (IrInstrJump "body") IrInstrNil))
          (compiler-ir-block-cons
            (compiler-ir-block "body" body)
            (compiler-ir-block-cons
              (compiler-ir-block
                "exit"
                (compiler-ir-instr-cons (IrInstrReturn IrNoValue) IrInstrNil))
              IrBlockNil)))))))

(cfg
  test
  (define (compiler-reg-call-spanning-multiblock-boundary-function) : CompilerIrFunction
    (let
      [entry : CompilerIrInstrList
        (compiler-reg-call-spanning-defs-before
          (compiler-ir-instr-cons (IrInstrJump "body") IrInstrNil))]
      [body-tail : CompilerIrInstrList
        (compiler-ir-instr-cons (IrInstrJump "exit") IrInstrNil)]
      [body : CompilerIrInstrList
        (compiler-reg-call-spanning-call-before
          (compiler-reg-call-spanning-post-call-stores body-tail))]
      (IrFunction
        "call_spanning_multiblock_boundary"
        IrParamNil
        (AstTyUnit)
        8
        (compiler-ir-block-cons
          (compiler-ir-block "entry" entry)
          (compiler-ir-block-cons
            (compiler-ir-block "body" body)
            (compiler-ir-block-cons
              (compiler-ir-block
                "exit"
                (compiler-ir-instr-cons (IrInstrReturn IrNoValue) IrInstrNil))
              IrBlockNil)))))))

(cfg
  test
  (define (compiler-reg-scalar-call-spanning-multiblock-local-ok?) : bool
    (let
      [func : CompilerIrFunction
        (compiler-reg-call-spanning-multiblock-local-function)]
      [plan : CompilerRegPlan (compiler-reg-plan-function-scalar func)]
      (match plan
        [(CompilerRegPlan assignments _ _ _ split-vars)
          (and
            ;; Same capacity story as the single-block fixture: the greedy
            ;; register-homes the hot call-spanning value (spill-weight priority)
            ;; and spills the single-use overflow (var 6) without a save/restore
            ;; rescue.
            (= (compiler-reg-spill-count assignments) 2)
            (compiler-reg-location-spill-offset?
              (compiler-reg-assignment-lookup assignments 6)
              (compiler-reg-stack-slot-offset 6))
            (not (compiler-live-set-contains? split-vars 5))
            (not (compiler-live-set-contains? split-vars 6)))]))))

(cfg
  test
  (define (compiler-reg-scalar-call-spanning-multiblock-boundary-ok?) : bool
    (let
      [plan : CompilerRegPlan
        (compiler-reg-plan-function-scalar
          (compiler-reg-call-spanning-multiblock-boundary-function))]
      (match plan
        [(CompilerRegPlan _ _ _ _ split-vars)
          (and
            (not (compiler-live-set-contains? split-vars 5))
            (not (compiler-live-set-contains? split-vars 6)))]))))

(cfg
  test
  (define (compiler-reg-edge-copy-list-has?
    [copies : CompilerRegEdgeCopyList]
    [from-label : String]
    [to-label : String]
    [src : i64]
    [dst : i64]
    [want-pred-end : bool]) : bool
    (match copies
      [(CompilerRegEdgeCopyNil) false]
      [(CompilerRegEdgeCopyCons copy rest)
        (match copy
          [(CompilerRegEdgeCopy
              found-from
              found-to
              found-src
              found-dst
              _
              _
              placement)
            (if (and
              (string.string-eq found-from from-label)
              (string.string-eq found-to to-label)
              (= found-src src)
              (= found-dst dst)
              (match placement
                [(CompilerRegEdgeCopyPredEnd) want-pred-end]
                [(CompilerRegEdgeCopySuccEntry) (not want-pred-end)]))
              true
              (compiler-reg-edge-copy-list-has?
                (box-get rest)
                from-label
                to-label
                src
                dst
                want-pred-end))])])))

(cfg
  test
  (define (compiler-reg-edge-copy-linear-function) : CompilerIrFunction
    (IrFunction
      "edge_copy_linear"
      IrParamNil
      (AstTyI64)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 7) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons (IrInstrJump "hot") IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "hot"
            (compiler-ir-instr-cons
              (IrInstrReturn (IrSomeValue (IrValueVar 0)))
              IrInstrNil))
          IrBlockNil)))))

(cfg
  test
  (define (compiler-reg-edge-copy-linear-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-edge-copy-linear-function)]
      [region : CompilerRegStringList
        (compiler-reg-string-cons "hot" CompilerRegStringNil)]
      (match (compiler-reg-edge-copy-plan-for-region
        func
        region
        0
        10
        (compiler-reg-i64-ty))
        [(CompilerRegEdgeCopyPlan copies)
          (and
            (= (compiler-reg-edge-copy-list-count copies) 1)
            (compiler-reg-edge-copy-list-has? copies "entry" "hot" 0 10 true)
            (match func
              [(IrFunction _ _ _ _ blocks)
                (match (compiler-reg-edge-copy-apply blocks copies)
                  [(CompilerRegEdgeCopyRewrite rewritten)
                    (compiler-reg-instr-list-has-mov-var?
                      (compiler-reg-block-instr-list rewritten "entry")
                      10
                      0)]
                  [(CompilerRegEdgeCopyRewriteRefused _) false])]))]
        [(CompilerRegEdgeCopyRefused _) false]))))

(cfg
  test
  (define (compiler-reg-edge-copy-backedge-function) : CompilerIrFunction
    (IrFunction
      "edge_copy_backedge"
      IrParamNil
      (AstTyI64)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 7) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons (IrInstrJump "loop") IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "loop"
            (compiler-ir-instr-cons
              (IrInstrBranch (IrValueBool false) "body" "exit")
              IrInstrNil))
          (compiler-ir-block-cons
            (compiler-ir-block
              "body"
              (compiler-ir-instr-cons
                (IrInstrStore "sink" (IrValueVar 0) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons (IrInstrJump "loop") IrInstrNil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                "exit"
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                  IrInstrNil))
              IrBlockNil)))))))

(cfg
  test
  (define (compiler-reg-edge-copy-backedge-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-edge-copy-backedge-function)]
      [region : CompilerRegStringList
        (compiler-reg-string-cons "body" CompilerRegStringNil)]
      (match (compiler-reg-edge-copy-plan-for-region
        func
        region
        0
        10
        (compiler-reg-i64-ty))
        [(CompilerRegEdgeCopyPlan copies)
          (and
            (= (compiler-reg-edge-copy-list-count copies) 2)
            (compiler-reg-edge-copy-list-has? copies "loop" "body" 0 10 false)
            (compiler-reg-edge-copy-list-has? copies "body" "loop" 10 0 true)
            (match func
              [(IrFunction _ _ _ _ blocks)
                (match (compiler-reg-edge-copy-apply blocks copies)
                  [(CompilerRegEdgeCopyRewrite rewritten)
                    (let
                      [body : CompilerIrInstrList
                        (compiler-reg-block-instr-list rewritten "body")]
                      (and
                        (compiler-reg-instr-list-has-mov-var? body 10 0)
                        (compiler-reg-instr-list-has-mov-var? body 0 10)))]
                  [(CompilerRegEdgeCopyRewriteRefused _) false])]))]
        [(CompilerRegEdgeCopyRefused _) false]))))

(cfg
  test
  (define (compiler-reg-edge-copy-critical-function) : CompilerIrFunction
    (IrFunction
      "edge_copy_critical"
      IrParamNil
      (AstTyI64)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 7) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrBranch (IrValueBool false) "hot" "cold")
              IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "other"
            (compiler-ir-instr-cons (IrInstrJump "hot") IrInstrNil))
          (compiler-ir-block-cons
            (compiler-ir-block
              "hot"
              (compiler-ir-instr-cons
                (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                IrInstrNil))
            (compiler-ir-block-cons
              (compiler-ir-block
                "cold"
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueI64 0)))
                  IrInstrNil))
              IrBlockNil)))))))

(cfg
  test
  (define (compiler-reg-edge-copy-critical-refusal-ok?) : bool
    (let
      [region : CompilerRegStringList
        (compiler-reg-string-cons "hot" CompilerRegStringNil)]
      (match (compiler-reg-edge-copy-plan-for-region
        (compiler-reg-edge-copy-critical-function)
        region
        0
        10
        (compiler-reg-i64-ty))
        [(CompilerRegEdgeCopyPlan _) false]
        [(CompilerRegEdgeCopyRefused _) true]))))

(cfg
  test
  (define (compiler-reg-loop-split-plan [func : CompilerIrFunction]) : CompilerRegPlan
    (let
      [type-info : CompilerRegVarTypes (compiler-reg-function-var-types func)]
      [liveness : CompilerFunctionLiveness
        (compiler-live-analyze-function func)]
      (match (compiler-reg-live-interval-selection func liveness)
        [(CompilerRegIntervalSelection intervals _)
          (CompilerRegPlan
            (compiler-reg-assignment-cons
              (CompilerRegAssignment
                0
                (CompilerRegSpill (compiler-reg-stack-slot-offset 0)))
              CompilerRegAssignmentNil)
            (compiler-live-set-empty)
            intervals
            (compiler-reg-var-types-list type-info)
            (compiler-live-set-empty))]))))

(cfg
  test
  (define (compiler-reg-loop-split-two-plan [func : CompilerIrFunction]) : CompilerRegPlan
    (let
      [type-info : CompilerRegVarTypes (compiler-reg-function-var-types func)]
      [liveness : CompilerFunctionLiveness
        (compiler-live-analyze-function func)]
      (match (compiler-reg-live-interval-selection func liveness)
        [(CompilerRegIntervalSelection intervals _)
          (CompilerRegPlan
            (compiler-reg-assignment-cons
              (CompilerRegAssignment
                0
                (CompilerRegSpill (compiler-reg-stack-slot-offset 0)))
              (compiler-reg-assignment-cons
                (CompilerRegAssignment
                  1
                  (CompilerRegSpill (compiler-reg-stack-slot-offset 1)))
                CompilerRegAssignmentNil))
            (compiler-live-set-empty)
            intervals
            (compiler-reg-var-types-list type-info)
            (compiler-live-set-empty))]))))

(cfg
  test
  (define (compiler-reg-loop-split-rewrite-function) : CompilerIrFunction
    (IrFunction
      "loop_split_rewrite"
      IrParamNil
      (AstTyI64)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 7) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons (IrInstrJump "loop") IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "loop"
            (compiler-ir-instr-cons
              (IrInstrBranch (IrValueBool false) "body" "exit")
              IrInstrNil))
          (compiler-ir-block-cons
            (compiler-ir-block
              "body"
              (compiler-ir-instr-cons
                (IrInstrStore "hot0" (IrValueVar 0) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (IrInstrStore "hot1" (IrValueVar 0) (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons (IrInstrJump "loop") IrInstrNil))))
            (compiler-ir-block-cons
              (compiler-ir-block
                "exit"
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                  IrInstrNil))
              IrBlockNil)))))))

(cfg
  test
  (define (compiler-reg-loop-split-two-rewrite-function) : CompilerIrFunction
    (IrFunction
      "loop_split_two_rewrite"
      IrParamNil
      (AstTyI64)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 7) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrMov 1 (IrValueI64 11) (compiler-reg-i64-ty))
              (compiler-ir-instr-cons (IrInstrJump "loop") IrInstrNil))))
        (compiler-ir-block-cons
          (compiler-ir-block
            "loop"
            (compiler-ir-instr-cons
              (IrInstrBranch (IrValueBool false) "body" "exit")
              IrInstrNil))
          (compiler-ir-block-cons
            (compiler-ir-block
              "body"
              (compiler-ir-instr-cons
                (IrInstrStore "hot0" (IrValueVar 0) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (IrInstrStore "hot1" (IrValueVar 1) (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (IrInstrStore "hot2" (IrValueVar 0) (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons
                      (IrInstrStore "hot3" (IrValueVar 1) (compiler-reg-i64-ty))
                      (compiler-ir-instr-cons (IrInstrJump "loop") IrInstrNil))))))
            (compiler-ir-block-cons
              (compiler-ir-block
                "exit"
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                  IrInstrNil))
              IrBlockNil)))))))

(cfg
  test
  (define (compiler-reg-loop-split-low-benefit-function) : CompilerIrFunction
    (IrFunction
      "loop_split_low_benefit"
      IrParamNil
      (AstTyI64)
      1
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 7) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons (IrInstrJump "loop") IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "loop"
            (compiler-ir-instr-cons
              (IrInstrBranch (IrValueBool false) "body" "exit")
              IrInstrNil))
          (compiler-ir-block-cons
            (compiler-ir-block
              "body"
              (compiler-ir-instr-cons
                (IrInstrStore "hot0" (IrValueVar 0) (compiler-reg-i64-ty))
                (compiler-ir-instr-cons (IrInstrJump "loop") IrInstrNil)))
            (compiler-ir-block-cons
              (compiler-ir-block
                "exit"
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                  IrInstrNil))
              IrBlockNil)))))))

(cfg
  test
  (define (compiler-reg-loop-split-phi-region-function) : CompilerIrFunction
    (IrFunction
      "loop_split_phi_region"
      IrParamNil
      (AstTyI64)
      2
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 7) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons (IrInstrJump "loop") IrInstrNil)))
        (compiler-ir-block-cons
          (compiler-ir-block
            "loop"
            (compiler-ir-instr-cons
              (IrInstrBranch (IrValueBool false) "body" "exit")
              IrInstrNil))
          (compiler-ir-block-cons
            (compiler-ir-block
              "body"
              (compiler-ir-instr-cons
                (IrInstrPhi
                  1
                  (compiler-ir-phi-input-cons
                    (IrValueVar 0)
                    "loop"
                    IrPhiInputNil)
                  (compiler-reg-i64-ty))
                (compiler-ir-instr-cons
                  (IrInstrStore "hot0" (IrValueVar 0) (compiler-reg-i64-ty))
                  (compiler-ir-instr-cons
                    (IrInstrStore "hot1" (IrValueVar 0) (compiler-reg-i64-ty))
                    (compiler-ir-instr-cons (IrInstrJump "loop") IrInstrNil)))))
            (compiler-ir-block-cons
              (compiler-ir-block
                "exit"
                (compiler-ir-instr-cons
                  (IrInstrReturn (IrSomeValue (IrValueVar 0)))
                  IrInstrNil))
              IrBlockNil)))))))

(cfg
  test
  (define (compiler-reg-loop-split-rewrite-ok?) : bool
    (let
      [func : CompilerIrFunction (compiler-reg-loop-split-rewrite-function)]
      [plan : CompilerRegPlan (compiler-reg-loop-split-plan func)]
      (match func
        [(IrFunction _ _ _ vars blocks)
          (let
            [rewrite : CompilerRegCallSaveRewrite
              (compiler-reg-loop-split-rewrite-blocks
                func
                blocks
                vars
                (compiler-reg-function-var-types func)
                plan)]
            (match rewrite
              [(CompilerRegCallSaveRewrite
                  rewritten
                  _
                  out-vars
                  extra-assignments
                  _)
                (let
                  [body : CompilerIrInstrList
                    (compiler-reg-block-instr-list rewritten "body")]
                  [rewritten-plan : CompilerRegPlan
                    (compiler-reg-plan-with-call-save-rewrite plan rewrite)]
                  [rewritten-assignments : CompilerRegAssignmentList
                    (compiler-reg-plan-assignments rewritten-plan)]
                  (and
                    (= out-vars (+ vars 1))
                    (= (compiler-reg-assignment-count extra-assignments) 1)
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup
                        rewritten-assignments
                        vars)
                      "%r12")
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
        [(IrFunction _ _ _ vars blocks)
          (let
            [rewrite : CompilerRegCallSaveRewrite
              (compiler-reg-loop-split-rewrite-blocks
                func
                blocks
                vars
                (compiler-reg-function-var-types func)
                plan)]
            (match rewrite
              [(CompilerRegCallSaveRewrite
                  rewritten
                  _
                  out-vars
                  extra-assignments
                  _)
                (let
                  [body : CompilerIrInstrList
                    (compiler-reg-block-instr-list rewritten "body")]
                  [rewritten-plan : CompilerRegPlan
                    (compiler-reg-plan-with-call-save-rewrite plan rewrite)]
                  [rewritten-assignments : CompilerRegAssignmentList
                    (compiler-reg-plan-assignments rewritten-plan)]
                  [split0 : i64 vars]
                  [split1 : i64 (+ vars 1)]
                  (and
                    (= out-vars (+ vars 2))
                    (= (compiler-reg-assignment-count extra-assignments) 2)
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup
                        rewritten-assignments
                        split0)
                      "%r12")
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup
                        rewritten-assignments
                        split1)
                      "%r13")
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
        [(IrFunction _ _ _ vars blocks)
          (match (compiler-reg-loop-split-rewrite-blocks
            func
            blocks
            vars
            (compiler-reg-function-var-types func)
            plan)
            [(CompilerRegCallSaveRewrite _ _ out-vars extra-assignments _)
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
  (define (compiler-reg-loop-split-phi-region-refusal-ok?) : bool
    (compiler-reg-loop-split-noop-for?
      (compiler-reg-loop-split-phi-region-function))))

(cfg
  test
  (define (compiler-reg-many-call-live-function) : CompilerIrFunction
    (IrFunction
      "many_call_live"
      IrParamNil
      (AstTyUnit)
      6
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrMov 0 (IrValueI64 9) (compiler-reg-i64-ty))
            (compiler-ir-instr-cons
              (IrInstrCall 1 "side_effect_a" (IrCallArgsNil) (AstTyUnit))
              (compiler-ir-instr-cons
                (IrInstrCall 2 "side_effect_b" (IrCallArgsNil) (AstTyUnit))
                (compiler-ir-instr-cons
                  (IrInstrCall 3 "side_effect_c" (IrCallArgsNil) (AstTyUnit))
                  (compiler-ir-instr-cons
                    (IrInstrCall 4 "side_effect_d" (IrCallArgsNil) (AstTyUnit))
                    (compiler-ir-instr-cons
                      (IrInstrMov 5 (IrValueVar 0) (compiler-reg-i64-ty))
                      (compiler-ir-instr-cons
                        (IrInstrReturn (IrSomeValue (IrValueVar 5)))
                        IrInstrNil))))))))
        IrBlockNil))))

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

(define (compiler-reg-indexed-lookups-ok?) : bool
  (let
    [assignments : CompilerRegAssignmentList
      (compiler-reg-assignment-insert
        (compiler-reg-assignment-insert
          CompilerRegAssignmentNil
          1
          (CompilerRegRegister "%r12"))
        3
        (CompilerRegSpill 24))]
    [intervals : CompilerRegIntervalList
      (compiler-reg-interval-cons
        (CompilerRegInterval 1 2 5)
        (compiler-reg-interval-cons
          (CompilerRegInterval 3 5 9)
          (compiler-reg-interval-cons
            (CompilerRegInterval 4 1 4)
            (compiler-reg-interval-cons
              (CompilerRegInterval 4 8 10)
              CompilerRegIntervalNil))))]
    [assignment-index : CompilerRegAssignmentIndex
      (compiler-reg-assignment-index-build assignments 5)]
    [assignment-table : CompilerRegAssignmentTable
      (compiler-reg-assignment-table-insert
        (compiler-reg-assignment-table-insert
          (compiler-reg-assignment-table-make 5)
          1
          (CompilerRegRegister "%r12"))
        3
        (CompilerRegSpill 24))]
    [assignment-table-list : CompilerRegAssignmentList
      (compiler-reg-assignment-table-to-list assignment-table)]
    [interval-index : CompilerRegIntervalIndex
      (compiler-reg-interval-index-build intervals 5)]
    [assignment-hit-ok : bool
      (match (compiler-reg-assignment-index-lookup assignment-index 1)
        [(CompilerRegSomeLocation location)
          (compiler-reg-location-eq? location (CompilerRegRegister "%r12"))]
        [(CompilerRegNoLocation) false])]
    [assignment-miss-ok : bool
      (match (compiler-reg-assignment-index-lookup assignment-index 2)
        [(CompilerRegSomeLocation _) false]
        [(CompilerRegNoLocation) true])]
    [assignment-oob-ok : bool
      (match (compiler-reg-assignment-index-lookup assignment-index -1)
        [(CompilerRegSomeLocation _) false]
        [(CompilerRegNoLocation) true])]
    [table-hit-ok : bool
      (match (compiler-reg-assignment-table-lookup assignment-table 1)
        [(CompilerRegSomeLocation location)
          (compiler-reg-location-eq? location (CompilerRegRegister "%r12"))]
        [(CompilerRegNoLocation) false])]
    [table-miss-ok : bool
      (match (compiler-reg-assignment-table-lookup assignment-table 2)
        [(CompilerRegSomeLocation _) false]
        [(CompilerRegNoLocation) true])]
    [table-oob-ok : bool
      (match (compiler-reg-assignment-table-lookup assignment-table -1)
        [(CompilerRegSomeLocation _) false]
        [(CompilerRegNoLocation) true])]
    [table-list-ok : bool
      (and
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignment-table-list 1)
          "%r12")
        (compiler-reg-location-eq?
          (match (compiler-reg-assignment-lookup assignment-table-list 3)
            [(CompilerRegSomeLocation location) location]
            [(CompilerRegNoLocation) (CompilerRegSpill -1)])
          (CompilerRegSpill 24)))]
    [interval-hit-ok : bool
      (match (compiler-reg-interval-index-lookup interval-index 3)
        [(CompilerRegSomeInterval interval)
          (match interval
            [(CompilerRegInterval var start end)
              (and (= var 3) (= start 5) (= end 9))])]
        [(CompilerRegNoInterval) false])]
    [interval-miss-ok : bool
      (match (compiler-reg-interval-index-lookup interval-index 2)
        [(CompilerRegSomeInterval _) false]
        [(CompilerRegNoInterval) true])]
    [interval-first-ok : bool
      (match (compiler-reg-interval-index-lookup interval-index 4)
        [(CompilerRegSomeInterval interval)
          (match interval
            [(CompilerRegInterval var start end)
              (and (= var 4) (= start 1) (= end 4))])]
        [(CompilerRegNoInterval) false])]
    [interference-ok : bool
      (and
        (not (compiler-reg-vars-interfere-index? interval-index 1 3))
        (compiler-reg-vars-interfere-index? interval-index 1 2))]
    [conflict-ok : bool
      (and
        (not
          (compiler-reg-location-conflicts?
            assignments
            interval-index
            3
            -1
            (CompilerRegRegister "%r12")))
        (compiler-reg-location-conflicts?
          assignments
          interval-index
          2
          -1
          (CompilerRegRegister "%r12")))]
    [table-conflict-ok : bool
      (and
        (not
          (compiler-reg-assignment-table-location-conflicts?
            assignment-table
            interval-index
            3
            -1
            (CompilerRegRegister "%r12")))
        (compiler-reg-assignment-table-location-conflicts?
          assignment-table
          interval-index
          2
          -1
          (CompilerRegRegister "%r12")))]
    (and
      assignment-hit-ok
      assignment-miss-ok
      assignment-oob-ok
      table-hit-ok
      table-miss-ok
      table-oob-ok
      table-list-ok
      interval-hit-ok
      interval-miss-ok
      interval-first-ok
      interference-ok
      conflict-ok
      table-conflict-ok)))

(define (compiler-reg-segmented-interference-ok?) : bool
  (let
    [starts : (Array i64) (array.make-array i64 5)]
    [ends : (Array i64) (array.make-array i64 5)]
    [segments : (Array CompilerRegIntervalList)
      (array.make-array CompilerRegIntervalList 5)]
    [segment-index : CompilerRegIntervalIndex
      (CompilerRegIntervalIndex starts ends segments)]
    (begin
      (compiler-reg-fill-i64-array starts -1)
      (compiler-reg-fill-i64-array ends -1)
      (array.array-set! starts 0 0)
      (array.array-set! ends 0 8)
      (array.array-set! starts 1 0)
      (array.array-set! ends 1 8)
      (array.array-set! starts 3 3)
      (array.array-set! ends 3 5)
      (array.array-set! starts 4 7)
      (array.array-set! ends 4 9)
      (array.array-set!
        segments
        1
        (compiler-reg-interval-cons
          (CompilerRegInterval 1 0 2)
          (compiler-reg-interval-cons
            (CompilerRegInterval 1 6 8)
            CompilerRegIntervalNil)))
      (array.array-set!
        segments
        3
        (compiler-reg-interval-cons
          (CompilerRegInterval 3 3 5)
          CompilerRegIntervalNil))
      (array.array-set!
        segments
        4
        (compiler-reg-interval-cons
          (CompilerRegInterval 4 7 9)
          CompilerRegIntervalNil))
      (and
        (not (compiler-reg-vars-interfere-segmented-index? segment-index 1 3))
        (compiler-reg-vars-interfere-segmented-index? segment-index 1 4)
        (compiler-reg-vars-interfere-segmented-index? segment-index 0 3)
        (compiler-reg-vars-interfere-segmented-index? segment-index 1 2)))))

(define (compiler-reg-hole-aware-register-reuse-ok?) : bool
  (let
    [starts : (Array i64) (array.make-array i64 5)]
    [ends : (Array i64) (array.make-array i64 5)]
    [segments : (Array CompilerRegIntervalList)
      (array.make-array CompilerRegIntervalList 5)]
    [segment-index : CompilerRegIntervalIndex
      (CompilerRegIntervalIndex starts ends segments)]
    [one-reg : CompilerRegStringList
      (compiler-reg-string-cons "%r12" CompilerRegStringNil)]
    [active-root : CompilerRegActiveList
      (compiler-reg-active-cons
        (CompilerRegActive 0 10 "%r12")
        CompilerRegActiveNil)]
    [active-ordinary : CompilerRegActiveList
      (compiler-reg-active-cons
        (CompilerRegActive 1 10 "%r12")
        CompilerRegActiveNil)]
    [hole-aware : CompilerLiveI64Set (compiler-live-set3 0 2 3)]
    [parents : (Array i64) (array.make-array i64 5)]
    (begin
      (compiler-reg-fill-i64-array starts -1)
      (compiler-reg-fill-i64-array ends -1)
      (array.array-set! starts 0 0)
      (array.array-set! ends 0 10)
      (array.array-set! starts 1 4)
      (array.array-set! ends 1 6)
      (array.array-set! starts 2 4)
      (array.array-set! ends 2 6)
      (array.array-set! starts 3 1)
      (array.array-set! ends 3 3)
      (array.array-set! starts 4 8)
      (array.array-set! ends 4 9)
      (array.array-set!
        segments
        0
        (compiler-reg-interval-cons
          (CompilerRegInterval 0 0 2)
          CompilerRegIntervalNil))
      (array.array-set!
        segments
        1
        (compiler-reg-interval-cons
          (CompilerRegInterval 1 4 6)
          CompilerRegIntervalNil))
      (array.array-set!
        segments
        2
        (compiler-reg-interval-cons
          (CompilerRegInterval 2 4 6)
          CompilerRegIntervalNil))
      (array.array-set!
        segments
        3
        (compiler-reg-interval-cons
          (CompilerRegInterval 3 1 3)
          CompilerRegIntervalNil))
      (array.array-set!
        segments
        4
        (compiler-reg-interval-cons
          (CompilerRegInterval 4 8 9)
          CompilerRegIntervalNil))
      (array.array-set! parents 0 0)
      (array.array-set! parents 1 0)
      (array.array-set! parents 2 2)
      (array.array-set! parents 3 2)
      (array.array-set! parents 4 4)
      (let
        ;; #3489 -> general hole-filling: the allocator runs on the merged-root
        ;; index, whose per-candidate segments are COMPLETE -- a singleton carries
        ;; its own live range, a class root the union of its members'. Every
        ;; segment hole is therefore genuine deadness, so ANY value may reuse an
        ;; active register in a hole whose segments are disjoint, regardless of
        ;; whether it is a coalesce root or a singleton. var 1's segment [4,6] is
        ;; disjoint from the active root var 0's [0,2], so it reuses %r12.
        [var1-disjoint-reuses : bool
          (match (compiler-reg-first-free-register-holes
            one-reg
            active-root
            segment-index
            1
            hole-aware)
            [(CompilerRegSomeString reg) (string.string-eq reg "%r12")]
            [(CompilerRegNoString) false])]
        [root-hole-reuses : bool
          (match (compiler-reg-first-free-register-holes
            one-reg
            active-root
            segment-index
            2
            hole-aware)
            [(CompilerRegSomeString reg) (string.string-eq reg "%r12")]
            [(CompilerRegNoString) false])]
        ;; overlap still conflicts: var 3's segment [1,3] overlaps var 0's [0,2].
        [root-overlap-conflicts : bool
          (match (compiler-reg-first-free-register-holes
            one-reg
            active-root
            segment-index
            3
            hole-aware)
            [(CompilerRegNoString) true]
            [(CompilerRegSomeString _) false])]
        ;; var 4's [8,9] is disjoint from the active ordinary var 1's [4,6].
        [var4-disjoint-reuses : bool
          (match (compiler-reg-first-free-register-holes
            one-reg
            active-ordinary
            segment-index
            4
            hole-aware)
            [(CompilerRegSomeString reg) (string.string-eq reg "%r12")]
            [(CompilerRegNoString) false])]
        [roots : CompilerLiveI64Set
          (compiler-reg-coalesce-merged-root-set
            (CompilerRegCoalesceMap parents))]
        [mapped-blocked : CompilerLiveI64Set
          (compiler-reg-coalesce-root-set-from-vars
            (CompilerRegCoalesceMap parents)
            (compiler-live-set2 1 4))]
        (and
          var1-disjoint-reuses
          root-hole-reuses
          root-overlap-conflicts
          var4-disjoint-reuses
          (compiler-live-set-contains? roots 0)
          (compiler-live-set-contains? roots 2)
          (not (compiler-live-set-contains? roots 1))
          (not (compiler-live-set-contains? roots 3))
          (not (compiler-live-set-contains? roots 4))
          (compiler-live-set-contains? mapped-blocked 0)
          (compiler-live-set-contains? mapped-blocked 4)
          (not (compiler-live-set-contains? mapped-blocked 1))
          (not (compiler-live-set-contains? mapped-blocked 2))
          (not (compiler-live-set-contains? mapped-blocked 3)))))))

(define (compiler-reg-coalesce-test-i64-types [vars : i64]) : CompilerRegVarTypes
  (let
    [present : (Array i64) (array.make-array i64 vars)]
    [types : (Array AstType) (array.make-array AstType vars)]
    [index : i64 0]
    (begin
      (compiler-reg-fill-i64-array present 0)
      (while (< index vars)
        (begin
          (array.array-set! present index 1)
          (array.array-set! types index (compiler-reg-i64-ty))
          (set! index (+ index 1))))
      (CompilerRegVarTypes
        (compiler-reg-var-type-arrays-to-list
          present
          types
          (- vars 1)
          CompilerRegVarTypeNil)
        present
        types))))

(define (compiler-reg-coalesce-test-flat-index) : CompilerRegIntervalIndex
  (compiler-reg-interval-index-build
    (compiler-reg-interval-cons
      (CompilerRegInterval 0 0 1)
      (compiler-reg-interval-cons
        (CompilerRegInterval 1 4 5)
        (compiler-reg-interval-cons
          (CompilerRegInterval 2 2 3)
          CompilerRegIntervalNil)))
    3))

(define (compiler-reg-coalesce-test-overlap-index) : CompilerRegIntervalIndex
  (compiler-reg-interval-index-build
    (compiler-reg-interval-cons
      (CompilerRegInterval 0 0 5)
      (compiler-reg-interval-cons
        (CompilerRegInterval 1 2 6)
        CompilerRegIntervalNil))
    2))

(define (compiler-reg-coalesce-test-segment-index) : CompilerRegIntervalIndex
  (let
    [starts : (Array i64) (array.make-array i64 2)]
    [ends : (Array i64) (array.make-array i64 2)]
    [segments : (Array CompilerRegIntervalList)
      (array.make-array CompilerRegIntervalList 2)]
    (begin
      (compiler-reg-fill-i64-array starts -1)
      (compiler-reg-fill-i64-array ends -1)
      (array.array-set! starts 0 0)
      (array.array-set! ends 0 10)
      (array.array-set! starts 1 0)
      (array.array-set! ends 1 10)
      (array.array-set!
        segments
        0
        (compiler-reg-interval-cons
          (CompilerRegInterval 0 0 2)
          CompilerRegIntervalNil))
      (array.array-set!
        segments
        1
        (compiler-reg-interval-cons
          (CompilerRegInterval 1 4 6)
          CompilerRegIntervalNil))
      (CompilerRegIntervalIndex starts ends segments))))

(define (compiler-reg-coalesce-fixpoint-map-ok?) : bool
  (let
    [types : CompilerRegVarTypes (compiler-reg-coalesce-test-i64-types 3)]
    [moves : CompilerRegMoveList
      (compiler-reg-move-list-add
        (compiler-reg-move-list-add CompilerRegMoveNil 0 2 false true)
        2
        1
        false
        true)]
    [index : CompilerRegIntervalIndex (compiler-reg-coalesce-test-flat-index)]
    [coalesce : CompilerRegCoalesceMap
      (compiler-reg-coalesce-map-build
        moves
        index
        types
        (compiler-live-set-empty)
        3
        (array.make-array i64 0))]
    [assignments : CompilerRegAssignmentTable
      (compiler-reg-assignment-table-insert
        (compiler-reg-assignment-table-make 3)
        0
        (CompilerRegRegister "%r12"))]
    [tie-assignments : CompilerRegAssignmentTable
      (compiler-reg-assignment-table-insert
        (compiler-reg-assignment-table-insert
          (compiler-reg-assignment-table-make 3)
          2
          (CompilerRegRegister "%r13"))
        0
        (CompilerRegRegister "%r12"))]
    (and
      (compiler-reg-location-register?
        (compiler-reg-coalesce-location coalesce assignments index 1)
        "%r12")
      (compiler-reg-location-register?
        (compiler-reg-coalesce-location coalesce tie-assignments index 1)
        "%r12"))))

(define (compiler-reg-coalesce-interference-reject-ok?) : bool
  (let
    [types : CompilerRegVarTypes (compiler-reg-coalesce-test-i64-types 2)]
    [moves : CompilerRegMoveList
      (compiler-reg-move-list-add CompilerRegMoveNil 0 1 false true)]
    [index : CompilerRegIntervalIndex
      (compiler-reg-coalesce-test-overlap-index)]
    [coalesce : CompilerRegCoalesceMap
      (compiler-reg-coalesce-map-build
        moves
        index
        types
        (compiler-live-set-empty)
        2
        (array.make-array i64 0))]
    [assignments : CompilerRegAssignmentTable
      (compiler-reg-assignment-table-insert
        (compiler-reg-assignment-table-make 2)
        0
        (CompilerRegRegister "%r12"))]
    (match (compiler-reg-coalesce-location coalesce assignments index 1)
      [(CompilerRegNoLocation) true]
      [(CompilerRegSomeLocation _) false])))

(define (compiler-reg-coalesce-segmented-map-ok?) : bool
  (let
    [types : CompilerRegVarTypes (compiler-reg-coalesce-test-i64-types 2)]
    [moves : CompilerRegMoveList
      (compiler-reg-move-list-add CompilerRegMoveNil 0 1 false true)]
    [index : CompilerRegIntervalIndex
      (compiler-reg-coalesce-test-segment-index)]
    [coalesce : CompilerRegCoalesceMap
      (compiler-reg-coalesce-map-build
        moves
        index
        types
        (compiler-live-set-empty)
        2
        (array.make-array i64 0))]
    [assignments : CompilerRegAssignmentTable
      (compiler-reg-assignment-table-insert
        (compiler-reg-assignment-table-make 2)
        0
        (CompilerRegRegister "%r12"))]
    (compiler-reg-location-register?
      (compiler-reg-coalesce-location coalesce assignments index 1)
      "%r12")))

(define (compiler-reg-coalesce-strict-segmented-reject-ok?) : bool
  (let
    [types : CompilerRegVarTypes (compiler-reg-coalesce-test-i64-types 2)]
    [moves : CompilerRegMoveList
      (compiler-reg-move-list-add CompilerRegMoveNil 0 1 true true)]
    [index : CompilerRegIntervalIndex
      (compiler-reg-coalesce-test-segment-index)]
    [coalesce : CompilerRegCoalesceMap
      (compiler-reg-coalesce-map-build
        moves
        index
        types
        (compiler-live-set-empty)
        2
        (array.make-array i64 0))]
    [assignments : CompilerRegAssignmentTable
      (compiler-reg-assignment-table-insert
        (compiler-reg-assignment-table-make 2)
        0
        (CompilerRegRegister "%r12"))]
    (match (compiler-reg-coalesce-location coalesce assignments index 1)
      [(CompilerRegNoLocation) true]
      [(CompilerRegSomeLocation _) false])))

(define (compiler-reg-single-segment-range?
  [segments : CompilerRegIntervalList]
  [var : i64]
  [start : i64]
  [end : i64]) : bool
  (match segments
    [(CompilerRegIntervalCons head rest)
      (match head
        [(CompilerRegInterval found-var found-start found-end)
          (and
            (= found-var var)
            (= found-start start)
            (= found-end end)
            (match (box-get rest)
              [(CompilerRegIntervalNil) true]
              [_ false]))])]
    [_ false]))

(define (compiler-reg-merged-root-overlap-segments-ok?) : bool
  (let
    [starts : (Array i64) (array.make-array i64 3)]
    [ends : (Array i64) (array.make-array i64 3)]
    [segments : (Array CompilerRegIntervalList)
      (array.make-array CompilerRegIntervalList 3)]
    [parents : (Array i64) (array.make-array i64 3)]
    (begin
      (compiler-reg-fill-i64-array starts -1)
      (compiler-reg-fill-i64-array ends -1)
      (array.array-set! segments 0 CompilerRegIntervalNil)
      (array.array-set! segments 1 CompilerRegIntervalNil)
      (array.array-set! segments 2 CompilerRegIntervalNil)
      (array.array-set! starts 0 0)
      (array.array-set! ends 0 6)
      (array.array-set! starts 1 2)
      (array.array-set! ends 1 8)
      (array.array-set!
        segments
        0
        (compiler-reg-interval-cons
          (CompilerRegInterval 0 0 4)
          (compiler-reg-interval-cons
            (CompilerRegInterval 0 5 6)
            CompilerRegIntervalNil)))
      (array.array-set!
        segments
        1
        (compiler-reg-interval-cons
          (CompilerRegInterval 1 2 8)
          CompilerRegIntervalNil))
      (array.array-set! parents 0 0)
      (array.array-set! parents 1 0)
      (array.array-set! parents 2 2)
      (let
        [merged : CompilerRegIntervalIndex
          (compiler-reg-merged-root-index
            (CompilerRegCoalesceMap parents)
            (CompilerRegIntervalIndex starts ends segments))]
        (and
          (= (array.array-ref (struct-get merged starts) 0) 0)
          (= (array.array-ref (struct-get merged ends) 0) 8)
          (< (array.array-ref (struct-get merged starts) 1) 0)
          (compiler-reg-single-segment-range?
            (array.array-ref (struct-get merged segments) 0)
            0
            0
            8))))))

(define (compiler-reg-same-value-multi-def-census-ok?) : bool
  (let
    [parents : (Array i64)
      (compiler-reg-function-same-value-parents
        (compiler-reg-same-value-multi-def-census-function))]
    (not (compiler-reg-same-value-class? parents 0 1))))

(define (compiler-reg-same-value-phi-census-ok?) : bool
  (let
    [parents : (Array i64)
      (compiler-reg-function-same-value-parents
        (compiler-reg-loop-backedge-function))]
    (not (compiler-reg-same-value-class? parents 1 2))))

(define (compiler-reg-same-value-clobber-census-ok?) : bool
  (let
    [func : CompilerIrFunction (compiler-reg-same-value-clobber-function)]
    [selection : CompilerRegIntervalSelection
      (compiler-reg-live-interval-selection
        func
        (compiler-live-analyze-function func))]
    (match selection
      [(CompilerRegIntervalSelection _ interval-index)
        (let
          [parents : (Array i64)
            (compiler-reg-function-same-value-parents-filtered
              func
              (compiler-reg-same-value-eligible-vars
                interval-index
                (compiler-reg-backend-caller-clobber-points func)))]
          (not (compiler-reg-same-value-class? parents 0 2)))])))

(define (compiler-reg-coalesce-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-move-chain-function))
    [(CompilerRegPlan chain-assignments _ _ _ _)
      (match (compiler-reg-plan-function (compiler-reg-phi-join-function))
        [(CompilerRegPlan phi-assignments _ _ _ _)
          (match (compiler-reg-plan-function
            (compiler-reg-loop-backedge-function))
            [(CompilerRegPlan loop-assignments _ _ _ _)
              (match (compiler-reg-plan-function
                (compiler-reg-interference-blocks-coalesce-function))
                [(CompilerRegPlan blocked-assignments _ _ _ _)
                  (match (compiler-reg-plan-function
                    (compiler-reg-spill-coalesce-function))
                    [(CompilerRegPlan spill-assignments _ _ _ _)
                      (and
                        (compiler-reg-same-location? chain-assignments 0 1)
                        (compiler-reg-same-location? chain-assignments 1 2)
                        (compiler-reg-same-location? phi-assignments 0 1)
                        (compiler-reg-different-location? loop-assignments 1 2)
                        (compiler-reg-different-location?
                          blocked-assignments
                          0
                          1)
                        (compiler-reg-same-location? spill-assignments 4 5)
                        (compiler-reg-coalesce-fixpoint-map-ok?)
                        (compiler-reg-coalesce-interference-reject-ok?)
                        (compiler-reg-coalesce-segmented-map-ok?)
                        (compiler-reg-coalesce-strict-segmented-reject-ok?)
                        (compiler-reg-merged-root-overlap-segments-ok?)
                        (compiler-reg-same-value-multi-def-census-ok?)
                        (compiler-reg-same-value-phi-census-ok?)
                        (compiler-reg-same-value-clobber-census-ok?))])])])])]))

(define (compiler-reg-vector-mask-homes-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-vector-home-function))
    [(CompilerRegPlan vector-assignments _ _ _ _)
      (match (compiler-reg-plan-function
        (compiler-reg-vector-select-false-home-function))
        [(CompilerRegPlan select-assignments _ _ _ _)
          (match (compiler-reg-plan-function (compiler-reg-mask-home-function))
            [(CompilerRegPlan mask-assignments _ _ _ _)
              (let
                [vector-ok : bool
                  (and
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup vector-assignments 0)
                      "%vec6")
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup vector-assignments 1)
                      "%vec7")
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup vector-assignments 2)
                      "%vec7")
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup vector-assignments 3)
                      "%vec6"))]
                [select-ok : bool
                  (and
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup select-assignments 1)
                      "%vec7")
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup select-assignments 2)
                      "%vec8")
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup select-assignments 4)
                      "%vec7"))]
                [mask-ok : bool
                  (and
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup mask-assignments 0)
                      "%k1")
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup mask-assignments 1)
                      "%k2")
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup mask-assignments 3)
                      "%k1"))]
                (and vector-ok select-ok mask-ok))])])]))

(define (compiler-reg-target-clobbers-ok?) : bool
  (let
    [zero-call-callers : CompilerRegStringList
      (compiler-reg-zero-call-caller-saved-integer-registers)]
    [greedy-pool : CompilerRegStringList (compiler-reg-greedy-integer-pool)]
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
      (not (compiler-reg-string-list-contains? sysv-callees "%rdi"))
      (compiler-reg-string-list-contains? win-callees "%rdi")
      (not (compiler-reg-string-list-contains? win-callers "%rdi"))
      (not
        (=
          (compiler-reg-string-list-count (compiler-reg-sysv-integer-registers))
          (compiler-reg-string-list-count win-callees)))
      ;; The callee-saved subpool admits only registers that survive an
      ;; intervening call.
      (compiler-reg-string-list-contains?
        (compiler-reg-sysv-integer-registers)
        "%r12")
      ;; The greedy pool owns the caller-saved backend temps behind the
      ;; clobber-point filter.
      (= (compiler-reg-greedy-caller-saved-count) 9)
      (compiler-reg-string-list-contains? greedy-pool "%r8")
      (compiler-reg-string-list-contains? greedy-pool "%r10")
      (compiler-reg-string-list-contains? greedy-pool "%r11")
      ;; ABI-aware split: SysV caller-saved-count=9; Win64=7 (%rsi/%rdi are
      ;; nonvolatile on Win64 -> in the callee-saved suffix, not the prefix).
      (= (compiler-reg-greedy-caller-saved-count-for-abi CompilerRegAbiLinux) 9)
      (= (compiler-reg-greedy-caller-saved-count-for-abi CompilerRegAbiWindows) 7)
      (=
        (compiler-reg-string-list-count
          (compiler-reg-greedy-integer-pool-for-abi CompilerRegAbiWindows))
        12)
      (not
        (compiler-reg-string-list-contains?
          (compiler-reg-greedy-integer-pool-for-abi CompilerRegAbiWindows)
          "%rsi"))
      (not
        (compiler-reg-string-list-contains?
          (compiler-reg-greedy-integer-pool-for-abi CompilerRegAbiWindows)
          "%rdi"))
      ;; The scalar zero-call extension is the older three-register subset.
      ;; Keep ABI/result registers and Win64 callee-saved %rsi/%rdi out of it.
      (= (compiler-reg-string-list-count zero-call-callers) 3)
      (compiler-reg-string-list-contains? zero-call-callers "%r9")
      (compiler-reg-string-list-contains? zero-call-callers "%rcx")
      (compiler-reg-string-list-contains? zero-call-callers "%rdx")
      (compiler-reg-string-list-contains? sysv-callers "%rcx")
      (compiler-reg-string-list-contains? sysv-callers "%rdx")
      (compiler-reg-string-list-contains? sysv-callers "%r9")
      (compiler-reg-string-list-contains? win-callers "%rcx")
      (compiler-reg-string-list-contains? win-callers "%rdx")
      (compiler-reg-string-list-contains? win-callers "%r9")
      (not (compiler-reg-string-list-contains? zero-call-callers "%rax"))
      (not (compiler-reg-string-list-contains? zero-call-callers "%r8"))
      (not (compiler-reg-string-list-contains? zero-call-callers "%r10"))
      (not (compiler-reg-string-list-contains? zero-call-callers "%r11"))
      (not (compiler-reg-string-list-contains? zero-call-callers "%rdi"))
      (not (compiler-reg-string-list-contains? zero-call-callers "%rsi"))
      (not
        (compiler-reg-string-list-contains?
          (compiler-reg-sysv-integer-registers)
          "%r8"))
      (not
        (compiler-reg-string-list-contains?
          (compiler-reg-sysv-integer-registers)
          "%r9")))))

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
        (compiler-reg-string-list-contains? pool "%xmm5")
        (not (compiler-reg-string-list-contains? pool "%xmm0"))
        (not (compiler-reg-string-list-contains? pool "%xmm1"))
        (not (compiler-reg-string-list-contains? pool "%xmm6"))
        (not (compiler-reg-string-list-contains? pool "%xmm15")))]
    [sysv-ok : bool
      (and
        (compiler-reg-string-list-contains? sysv-callers "%xmm14")
        (not (compiler-reg-string-list-contains? sysv-callees "%xmm14")))]
    [win-ok : bool
      (and
        (compiler-reg-string-list-contains? win-callers "%xmm5")
        (not (compiler-reg-string-list-contains? win-callers "%xmm6"))
        (compiler-reg-string-list-contains? win-callees "%xmm6"))]
    [counts-ok : bool
      (and
        (= (compiler-reg-string-list-count sysv-callers) 16)
        (= (compiler-reg-string-list-count sysv-callees) 0)
        (= (compiler-reg-string-list-count win-callers) 6)
        (= (compiler-reg-string-list-count win-callees) 10))]
    (and pool-ok sysv-ok win-ok counts-ok)))

(define (compiler-reg-color-register-assignments-to [last : i64]) : CompilerRegAssignmentList
  (if (< last 0)
    CompilerRegAssignmentNil
    (compiler-reg-assignment-insert
      (compiler-reg-color-register-assignments-to (- last 1))
      last
      (CompilerRegRegister "%r12"))))

(define (compiler-reg-color-storage-function) : CompilerIrFunction
  (let
    [big : AstType (AstTyStruct (intern "BigStorage"))]
    (IrFunction
      "storage_ranges"
      IrParamNil
      (AstTyUnit)
      6
      (compiler-ir-block-cons
        (compiler-ir-block
          "entry"
          (compiler-ir-instr-cons
            (IrInstrAlloc 0 big)
            (compiler-ir-instr-cons
              (IrInstrAlloc 1 big)
              (compiler-ir-instr-cons
                (IrInstrAddrOf 2 1)
                (compiler-ir-instr-cons
                  (IrInstrStorePtr (IrValueVar 2) (IrValueI64 11) (AstTyI64))
                  (compiler-ir-instr-cons
                    (IrInstrAlloc 3 big)
                    (compiler-ir-instr-cons
                      (IrInstrAlloc 4 big)
                      (compiler-ir-instr-cons
                        (IrInstrAddrOf 5 4)
                        (compiler-ir-instr-cons
                          (IrInstrStorePtr
                            (IrValueVar 5)
                            (IrValueI64 22)
                            (AstTyI64))
                          (compiler-ir-instr-cons
                            (IrInstrReturn IrNoValue)
                            IrInstrNil))))))))))
        IrBlockNil))))

(define (compiler-reg-color-pointer-assignments) : CompilerRegAssignmentList
  (compiler-reg-assignment-insert
    (compiler-reg-assignment-insert
      CompilerRegAssignmentNil
      2
      (CompilerRegRegister "%r12"))
    5
    (CompilerRegRegister "%r13")))

(define (compiler-reg-color-pointer-intervals) : CompilerRegIntervalList
  (compiler-reg-interval-cons
    (CompilerRegInterval 2 1 3)
    (compiler-reg-interval-cons
      (CompilerRegInterval 5 5 7)
      CompilerRegIntervalNil)))

(define (compiler-reg-color-pointer-types) : CompilerRegVarTypeList
  (compiler-reg-var-type-cons
    (CompilerRegVarType 2 (AstTyU64))
    (compiler-reg-var-type-cons
      (CompilerRegVarType 5 (AstTyU64))
      CompilerRegVarTypeNil)))

(define (compiler-reg-color-spill-sharing-assignments [vars : i64]) : CompilerRegAssignmentList
  (if (< vars 1)
    CompilerRegAssignmentNil
    (compiler-reg-assignment-insert
      (compiler-reg-color-spill-sharing-assignments (- vars 1))
      (- vars 1)
      (CompilerRegSpill (* (- vars 1) 8)))))

(define (compiler-reg-color-spill-sharing-types [vars : i64]) : CompilerRegVarTypeList
  (if (< vars 1)
    CompilerRegVarTypeNil
    (compiler-reg-var-type-cons
      (CompilerRegVarType (- vars 1) (AstTyI64))
      (compiler-reg-color-spill-sharing-types (- vars 1)))))

(define (compiler-reg-color-spill-sharing-intervals) : CompilerRegIntervalList
  (compiler-reg-interval-cons
    (CompilerRegInterval 0 0 2)
    (compiler-reg-interval-cons
      (CompilerRegInterval 2 1 5)
      (compiler-reg-interval-cons
        (CompilerRegInterval 1 3 4)
        CompilerRegIntervalNil))))

(define (compiler-reg-color-spill-split-intervals) : CompilerRegIntervalList
  (compiler-reg-interval-cons
    (CompilerRegInterval 0 0 1)
    (compiler-reg-interval-cons
      (CompilerRegInterval 1 2 3)
      (compiler-reg-interval-cons
        (CompilerRegInterval 0 5 7)
        CompilerRegIntervalNil))))

(define (compiler-reg-color-spill-param-intervals) : CompilerRegIntervalList
  (compiler-reg-interval-cons
    (CompilerRegInterval 0 0 1)
    (compiler-reg-interval-cons
      (CompilerRegInterval 1 1 2)
      (compiler-reg-interval-cons
        (CompilerRegInterval 2 3 4)
        CompilerRegIntervalNil))))

(define (compiler-reg-color-spill-slot-sharing-ok?) : bool
  (match (compiler-reg-color-stack-slots
    (CompilerRegPlan
      (compiler-reg-color-spill-sharing-assignments 3)
      (compiler-live-set-empty)
      (compiler-reg-color-spill-sharing-intervals)
      (compiler-reg-color-spill-sharing-types 3)
      (compiler-live-set-empty))
    (compiler-live-set-empty)
    IrParamNil
    IrBlockNil
    3)
    [(CompilerRegColoringRemap share-remap share-slots)
      (match (compiler-reg-color-stack-slots
        (CompilerRegPlan
          (compiler-reg-color-spill-sharing-assignments 2)
          (compiler-live-set-empty)
          (compiler-reg-color-spill-split-intervals)
          (compiler-reg-color-spill-sharing-types 2)
          (compiler-live-set-empty))
        (compiler-live-set-empty)
        IrParamNil
        IrBlockNil
        2)
        [(CompilerRegColoringRemap split-remap split-slots)
          (and
            (= share-slots 2)
            (= (array.array-ref share-remap 0) (array.array-ref share-remap 1))
            (not
              (=
                (array.array-ref share-remap 0)
                (array.array-ref share-remap 2)))
            (= split-slots 2)
            (not
              (=
                (array.array-ref split-remap 0)
                (array.array-ref split-remap 1))))]
        [(CompilerRegColoringNone) false])]
    [(CompilerRegColoringNone) false]))

(define (compiler-reg-color-spill-param-pins-ok?) : bool
  (match (compiler-reg-color-stack-slots
    (CompilerRegPlan
      (compiler-reg-color-spill-sharing-assignments 3)
      (compiler-live-set-empty)
      (compiler-reg-color-spill-param-intervals)
      (compiler-reg-color-spill-sharing-types 3)
      (compiler-live-set-empty))
    (compiler-live-set-empty)
    (compiler-ir-param-cons (IrParam "pinned" (AstTyI64) 1) IrParamNil)
    IrBlockNil
    3)
    [(CompilerRegColoringRemap remap slots)
      (and
        (= slots 2)
        (= (array.array-ref remap 1) 1)
        (= (array.array-ref remap 0) (array.array-ref remap 2))
        (not (= (array.array-ref remap 0) 1)))]
    [(CompilerRegColoringNone) false]))

(define (compiler-reg-color-storage-ranges-ok?) : bool
  (match (compiler-reg-color-storage-function)
    [(IrFunction _ params _ vars blocks)
      (match (compiler-reg-color-stack-slots
        (CompilerRegPlan
          (compiler-reg-color-pointer-assignments)
          (compiler-live-set-empty)
          (compiler-reg-color-pointer-intervals)
          (compiler-reg-color-pointer-types)
          (compiler-live-set-empty))
        (compiler-live-set-empty)
        params
        blocks
        vars)
        [(CompilerRegColoringRemap remap slots)
          (and
            (= slots 2)
            (= (array.array-ref remap 0) 0)
            (= (array.array-ref remap 1) 1)
            (= (array.array-ref remap 3) 0)
            (= (array.array-ref remap 4) 1))]
        [(CompilerRegColoringNone) false])]))

(define (compiler-reg-color-stack-group-ok?) : bool
  (let
    [group-var : i64 7]
    [coloring : CompilerRegColoring
      (compiler-reg-color-stack-slots
        (CompilerRegPlan
          (compiler-reg-color-register-assignments-to (- group-var 1))
          (compiler-live-set-empty)
          (CompilerRegIntervalCons
            (CompilerRegInterval group-var 0 2)
            (box CompilerRegIntervalNil))
          (compiler-reg-var-type-cons
            (CompilerRegVarType group-var (AstTyStruct (intern "RegGroup")))
            CompilerRegVarTypeNil)
          (compiler-live-set-empty))
        (compiler-live-set1 group-var)
        IrParamNil
        IrBlockNil
        (+ group-var 1))]
    (match coloring
      [(CompilerRegColoringRemap remap slots)
        (and
          (= slots 1)
          (= (array.array-ref remap group-var) 0)
          (<= (+ (array.array-ref remap group-var) 1) slots))]
      [(CompilerRegColoringNone) false])))

(define (compiler-regalloc-core-self-test?) : bool
  (and
    (compiler-reg-reuse-ok?)
    (compiler-reg-f64-reuse-ok?)
    (compiler-reg-overlap-spill-ok?)
    (compiler-reg-f64-overlap-spill-ok?)
    (compiler-reg-call-live-ok?)
    (compiler-reg-f64-call-live-ok?)
    (compiler-reg-call-arg-ok?)
    (compiler-reg-f64-call-arg-ok?)
    (compiler-reg-ineligible-ok?)
    (compiler-reg-target-clobbers-ok?)
    (compiler-reg-xmm-clobbers-ok?)
    (compiler-reg-coalesce-ok?)
    (compiler-reg-vector-mask-homes-ok?)
    (compiler-reg-segmented-interference-ok?)
    (compiler-reg-hole-aware-register-reuse-ok?)))

(define (compiler-regalloc-scalar-self-test?) : bool
  (and
    (compiler-reg-scalar-call-live-ok?)
    (compiler-reg-scalar-f64-call-live-ok?)
    (compiler-reg-scalar-handle-eligible-ok?)
    (cfg test (compiler-reg-scalar-linux-param-registers-ok?) true)
    (cfg test (compiler-reg-scalar-windows-param-registers-ok?) true)
    (cfg test (compiler-reg-scalar-param-clobber-ok?) true)
    (cfg test (compiler-reg-scalar-aggregate-param-not-pinned-ok?) true)
    (compiler-reg-scalar-function-intervals-ok?)
    (compiler-reg-scalar-interval-guardrail-ok?)
    (compiler-reg-scalar-loop-backedge-ok?)
    (compiler-reg-scalar-zero-call-caller-saved-ok?)
    (cfg test (compiler-reg-scalar-zero-call-param-conflict-ok?) true)
    (compiler-reg-scalar-caller-saved-clobber-ok?)
    (compiler-reg-scalar-call-spanning-caller-saved-ok?)
    (cfg test (compiler-reg-scalar-call-spanning-multiblock-local-ok?) true)
    (cfg test (compiler-reg-scalar-call-spanning-multiblock-boundary-ok?) true)
    (cfg test (compiler-reg-edge-copy-linear-ok?) true)
    (cfg test (compiler-reg-edge-copy-backedge-ok?) true)
    (cfg test (compiler-reg-edge-copy-critical-refusal-ok?) true)
    (cfg test (compiler-reg-loop-split-rewrite-ok?) true)
    (cfg test (compiler-reg-loop-split-multiple-rewrite-ok?) true)
    (cfg test (compiler-reg-loop-split-low-benefit-ok?) true)
    (cfg test (compiler-reg-loop-split-phi-region-refusal-ok?) true)))

(define (compiler-regalloc-storage-self-test?) : bool
  (and
    (cfg test (compiler-reg-remat-classifier-ok?) true)
    (cfg test (compiler-reg-remat-discount-weights-ok?) true)
    (cfg test (compiler-reg-remat-spill-weight-eviction-ok?) true)
    (cfg test (compiler-reg-remat-rewrite-shape-ok?) true)
    (cfg test (compiler-reg-remat-register-conflict-ok?) true)
    (cfg test (compiler-reg-remat-caller-clobber-refusal-ok?) true)
    (cfg test (compiler-reg-remat-global-mov-rewrite-ok?) true)
    (cfg test (compiler-reg-remat-global-load-rewrite-ok?) true)
    (cfg test (compiler-reg-remat-global-gep-rewrite-ok?) true)
    (cfg test (compiler-reg-remat-global-mutation-refusal-ok?) true)
    (cfg test (compiler-reg-spill-weight-eviction-ok?) true)
    (cfg test (compiler-reg-loop-spill-weight-eviction-ok?) true)
    (cfg test (compiler-reg-call-span-counts-ok?) true)
    (cfg test (compiler-reg-call-span-census-ok?) true)
    (compiler-reg-indexed-lookups-ok?)
    (compiler-reg-color-stack-group-ok?)
    (compiler-reg-color-spill-slot-sharing-ok?)
    (compiler-reg-color-spill-param-pins-ok?)
    (compiler-reg-color-storage-ranges-ok?)))

(define (compiler-regalloc-self-test) : i64
  (if (and
    (compiler-regalloc-core-self-test?)
    (compiler-regalloc-scalar-self-test?)
    (compiler-regalloc-storage-self-test?))
    42
    (io.panic "regalloc: smoke mismatch")))

(cfg
  test
  (test
    regalloc-call-span-census
    (test.assert-i64-eq
      (compiler-regalloc-self-test)
      42
      "regalloc call-span census fixture result")))