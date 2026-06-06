;; compiler_regalloc.tl - Planning-only scalar register allocation (#554).
;;
;; This pass mirrors the legacy backend's planning shape without changing
;; assembly emission. It computes inspectable live intervals, ineligible vars,
;; and register/spill homes for scalar IR values. The selfhost pools keep
;; %rsp/%rbp and the emitter's hard scratch registers reserved, and only admit
;; caller-saved integer/XMM registers for values that cannot be clobbered by
;; call emission.
(import "../stdlib/io.tl")

(import "compiler_liveness.tl")

(defenum CompilerRegStringList
  (CompilerRegStringNil)
  (CompilerRegStringCons String (Box CompilerRegStringList)))

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
    CompilerRegVarTypeList))

(defenum CompilerRegAssignState
  (CompilerRegAssignState CompilerRegActiveList CompilerRegAssignmentList))

(defenum CompilerRegMove
  (CompilerRegMove i64 i64))

(defenum CompilerRegMoveList
  (CompilerRegMoveNil)
  (CompilerRegMoveCons CompilerRegMove (Box CompilerRegMoveList)))

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

;; Allocatable integer register pool. Only callee-saved registers are admitted:
;; a value whose live interval spans a call keeps its home across that call
;; because the callee preserves these registers, so no spill/reload around the
;; call is needed. The former pool also offered %r8/%r9, which are caller-saved
;; under both SysV and Win64 and are clobbered by an intervening call — a value
;; homed there and read after the call (e.g. the first operand of `(+ a (f))`)
;; would silently observe garbage. The four registers below are exactly those
;; the backend prologue/epilogue save and restore. Mirrors the former Rust
;; backend's `SYSV_ALLOCATABLE_INTEGER_REGS` (callee-saved only).
(define (compiler-reg-sysv-integer-registers) : CompilerRegStringList
  (compiler-reg-string-cons
    "%r12"
    (compiler-reg-string-cons
      "%r13"
      (compiler-reg-string-cons
        "%r14"
        (compiler-reg-string-cons "%r15" CompilerRegStringNil)))))

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
      (if (string-eq reg want)
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
    (if (or (< var 0) (>= var (array-length present)))
      CompilerRegNoType
      (if (= (array-ref present var) 0)
        CompilerRegNoType
        (CompilerRegSomeType (array-ref items var))))))

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
    [_ types]))

(define (compiler-reg-var-type-array-set!
  [present : (Array i64)]
  [types : (Array AstType)]
  [var : i64]
  [ty : AstType]) : unit
  (if (or (< var 0) (>= var (array-length present)))
    unit
    (begin
      (array-set! present var 1)
      (array-set! types var ty))))

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
    [(IrInstrLoad dst _ ty)
      (compiler-reg-var-type-array-set! present types dst ty)]
    [(IrInstrCast dst _ _ to-ty)
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
            (array-ref slots index)
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
            (compiler-reg-block-list-types-array! (box-get rest) present types))])]))

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
      (if (= (array-ref present index) 0)
        acc
        (compiler-reg-var-type-cons
          (CompilerRegVarType index (array-ref types index))
          acc)))))

(define (compiler-reg-function-var-types [func : CompilerIrFunction]) : CompilerRegVarTypes
  (match func
    [(IrFunction _ params _ vars blocks)
      (let
        [present : (Array i64) (make-array i64 vars)]
        [types : (Array AstType) (make-array AstType vars)]
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
        [(CompilerRegMove found-src found-dst)
          (if (and (= found-src src) (= found-dst dst))
            true
            (compiler-reg-move-list-contains? (box-get rest) src dst))])]))

(define (compiler-reg-move-list-add
  [moves : CompilerRegMoveList]
  [src : i64]
  [dst : i64]) : CompilerRegMoveList
  (if (= src dst)
    moves
    (if (compiler-reg-move-list-contains? moves src dst)
      moves
      (compiler-reg-move-cons (CompilerRegMove src dst) moves))))

(define (compiler-reg-phi-input-moves
  [dst : i64]
  [inputs : CompilerIrPhiInputList]
  [moves : CompilerRegMoveList]) : CompilerRegMoveList
  (match inputs
    [(IrPhiInputNil) moves]
    [(IrPhiInputCons value _ rest)
      (let
        [tail : CompilerRegMoveList
          (compiler-reg-phi-input-moves dst (box-get rest) moves)]
        (match value
          [(IrValueVar src) (compiler-reg-move-list-add tail src dst)]
          [_ tail]))]))

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

(define (compiler-reg-instr-seq-moves
  [instrs : CompilerIrInstrSeq]
  [moves : CompilerRegMoveList]) : CompilerRegMoveList
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [index : i64 (- (struct-get instrs len) 1)]
    [out : CompilerRegMoveList moves]
    (begin
      (while (>= index 0)
        (begin
          (set! out (compiler-reg-instr-moves (array-ref slots index) out))
          (set! index (- index 1))))
      out)))

(define (compiler-reg-block-list-moves
  [blocks : CompilerIrBlockList]
  [moves : CompilerRegMoveList]) : CompilerRegMoveList
  (match blocks
    [(IrBlockNil) moves]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (compiler-reg-block-list-moves
            (box-get rest)
            (compiler-reg-instr-seq-moves instrs moves))])]))

(define (compiler-reg-function-moves [func : CompilerIrFunction]) : CompilerRegMoveList
  (match func
    [(IrFunction _ _ _ _ blocks)
      (compiler-reg-block-list-moves blocks CompilerRegMoveNil)]))

(define (compiler-reg-fill-i64-array [items : (Array i64)] [value : i64]) : unit
  (let
    [index : i64 0]
    [count : i64 (array-length items)]
    (begin
      (while (< index count)
        (begin
          (array-set! items index value)
          (set! index (+ index 1))))
      unit)))

(define (compiler-reg-extend-interval
  [starts : (Array i64)]
  [ends : (Array i64)]
  [var : i64]
  [point : i64]) : unit
  (if (< var 0)
    unit
    (if (>= var (array-length starts))
      unit
      (let
        [start : i64 (array-ref starts var)]
        [end : i64 (array-ref ends var)]
        (begin
          (if (< start 0)
            (begin
              (array-set! starts var point)
              (array-set! ends var point))
            (begin
              (if (< point start)
                (array-set! starts var point)
                unit)
              (if (> point end)
                (array-set! ends var point)
                unit)))
          unit)))))

(define (compiler-reg-low-bit-index [bits : i64]) : i64
  (let
    [value : i64 bits]
    [offset : i64 0]
    (begin
      (if (= (bit-and value 65535) 0)
        (begin
          (set! value (shr value 16))
          (set! offset (+ offset 16)))
        unit)
      (if (= (bit-and value 255) 0)
        (begin
          (set! value (shr value 8))
          (set! offset (+ offset 8)))
        unit)
      (if (= (bit-and value 15) 0)
        (begin
          (set! value (shr value 4))
          (set! offset (+ offset 4)))
        unit)
      (if (= (bit-and value 3) 0)
        (begin
          (set! value (shr value 2))
          (set! offset (+ offset 2)))
        unit)
      (if (= (bit-and value 1) 0)
        (+ offset 1)
        offset))))

(define (compiler-reg-extend-set
  [starts : (Array i64)]
  [ends : (Array i64)]
  [set : CompilerLiveI64Set]
  [point : i64]) : unit
  (match set
    [(CompilerLiveI64Nil) unit]
    [(CompilerLiveI64Cons chunk rest)
      (begin
        (compiler-reg-extend-set-word-bits
          starts
          ends
          (compiler-live-set-chunk-bits chunk)
          (*
            (compiler-live-set-chunk-word-index chunk)
            (compiler-live-set-word-bits))
          point)
        (compiler-reg-extend-set starts ends (box-get rest) point))]))

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
    (compiler-reg-extend-set starts ends (compiler-live-instr-defs instr) point)
    (compiler-reg-extend-set starts ends (compiler-live-instr-uses instr) point)
    (compiler-reg-extend-set starts ends live-after (+ point 1))))

(define (compiler-reg-live-intervals-instr-seq
  [instrs : CompilerIrInstrSeq]
  [live-afters : CompilerLiveInstrSetList]
  [point : i64]
  [starts : (Array i64)]
  [ends : (Array i64)]) : i64
  (let
    [slots : (Array CompilerIrInstr) (struct-get instrs slots)]
    [count : i64 (struct-get instrs len)]
    [index : i64 0]
    [out-point : i64 point]
    [afters : CompilerLiveInstrSetList live-afters]
    (begin
      (while (< index count)
        (begin
          (match afters
            [(CompilerLiveInstrSetCons live-after rest-after)
              (begin
                (compiler-reg-extend-instr
                  starts
                  ends
                  live-after
                  out-point
                  (array-ref slots index))
                (set! afters (box-get rest-after)))]
            [(CompilerLiveInstrSetNil)
              (compiler-reg-extend-instr
                starts
                ends
                (compiler-live-set-empty)
                out-point
                (array-ref slots index))])
          (set! out-point (+ out-point 2))
          (set! index (+ index 1))))
      out-point)))

(define (compiler-reg-live-intervals-find-afters
  [live-blocks : CompilerLiveBlockList]
  [label : String]) : CompilerLiveInstrSetList
  (match (compiler-live-find-block live-blocks label)
    [(CompilerLiveSomeBlock live-block)
      (compiler-live-block-instr-after live-block)]
    [(CompilerLiveNoBlock) CompilerLiveInstrSetNil]))

(define (compiler-reg-live-intervals-head-afters
  [live-blocks : CompilerLiveBlockList]
  [all-live-blocks : CompilerLiveBlockList]
  [label : String]) : CompilerLiveInstrSetList
  (match live-blocks
    [(CompilerLiveBlockNil)
      (compiler-reg-live-intervals-find-afters all-live-blocks label)]
    [(CompilerLiveBlockCons live-block _)
      (if (string-eq (compiler-live-block-label live-block) label)
        (compiler-live-block-instr-after live-block)
        (compiler-reg-live-intervals-find-afters all-live-blocks label))]))

(define (compiler-reg-live-intervals-next-live-blocks
  [live-blocks : CompilerLiveBlockList]
  [label : String]) : CompilerLiveBlockList
  (match live-blocks
    [(CompilerLiveBlockNil) CompilerLiveBlockNil]
    [(CompilerLiveBlockCons live-block rest)
      (if (string-eq (compiler-live-block-label live-block) label)
        (box-get rest)
        live-blocks)]))

(define (compiler-reg-live-intervals-blocks-with-live
  [blocks : CompilerIrBlockList]
  [live-blocks : CompilerLiveBlockList]
  [all-live-blocks : CompilerLiveBlockList]
  [point : i64]
  [starts : (Array i64)]
  [ends : (Array i64)]) : i64
  (match blocks
    [(IrBlockNil) point]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock label instrs)
          (let
            [live-afters : CompilerLiveInstrSetList
              (compiler-reg-live-intervals-head-afters
                live-blocks
                all-live-blocks
                label)]
            (compiler-reg-live-intervals-blocks-with-live
              (box-get rest)
              (compiler-reg-live-intervals-next-live-blocks live-blocks label)
              all-live-blocks
              (compiler-reg-live-intervals-instr-seq
                instrs
                live-afters
                point
                starts
                ends)
              starts
              ends))])]))

(define (compiler-reg-live-intervals-blocks
  [blocks : CompilerIrBlockList]
  [liveness : CompilerFunctionLiveness]
  [point : i64]
  [starts : (Array i64)]
  [ends : (Array i64)]) : i64
  (let
    [live-blocks : CompilerLiveBlockList
      (compiler-live-function-blocks liveness)]
    (compiler-reg-live-intervals-blocks-with-live
      blocks
      live-blocks
      live-blocks
      point
      starts
      ends)))

(define (compiler-reg-interval-arrays-to-list
  [starts : (Array i64)]
  [ends : (Array i64)]
  [index : i64]
  [acc : CompilerRegIntervalList]) : CompilerRegIntervalList
  (if (< index 0)
    acc
    (let
      [start : i64 (array-ref starts index)]
      [end : i64 (array-ref ends index)]
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
        [starts : (Array i64) (make-array i64 vars)]
        [ends : (Array i64) (make-array i64 vars)]
        (begin
          (compiler-reg-fill-i64-array starts -1)
          (compiler-reg-fill-i64-array ends -1)
          (compiler-reg-live-intervals-blocks blocks liveness 0 starts ends)
          (compiler-reg-interval-arrays-to-list
            starts
            ends
            (- vars 1)
            CompilerRegIntervalNil)))]))

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
    (array-set! row w (bit-or (array-ref row w) (shl 1 (% var 63))))))

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

(define (compiler-reg-set->row!
  [set : CompilerLiveI64Set]
  [row : (Array i64)]
  [base : i64]) : unit
  (match set
    [(CompilerLiveI64Nil) unit]
    [(CompilerLiveI64Cons chunk rest)
      (begin
        (compiler-reg-chunk->row!
          row
          base
          (compiler-live-set-chunk-bits chunk)
          (*
            (compiler-live-set-chunk-word-index chunk)
            (compiler-live-set-word-bits)))
        (compiler-reg-set->row! (box-get rest) row base))]))

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
  [idmap : StringI64Map]
  [use-rows : (Array i64)]
  [def-rows : (Array i64)]
  [words : i64]
  [index : i64]) : StringI64Map
  (match blocks
    [(CompilerLiveBlockNil) idmap]
    [(CompilerLiveBlockCons block rest)
      (match block
        [(CompilerLiveBlock label uses defs _ _ _ _)
          (begin
            (array-set! arr index block)
            (compiler-reg-set->row! uses use-rows (* index words))
            (compiler-reg-set->row! defs def-rows (* index words))
            (compiler-reg-bits-build-rows!
              (box-get rest)
              arr
              (string-i64-map-put idmap label index)
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
          (array-set! row (+ base w) 0)
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
          (array-set!
            dst
            (+ dbase w)
            (bit-or (array-ref dst (+ dbase w)) (array-ref src (+ sbase w))))
          (set! w (+ w 1))))
      unit)))

(define (compiler-reg-bits-or-succs!
  [live-out : (Array i64)]
  [live-in : (Array i64)]
  [succs : CompilerLiveLabelSet]
  [idmap : StringI64Map]
  [b : i64]
  [words : i64]) : unit
  (match succs
    [(CompilerLiveLabelNil) unit]
    [(CompilerLiveLabelCons label rest)
      (begin
        (match (string-i64-map-get idmap label)
          [(StringI64MapFound idx)
            (compiler-reg-bits-or-row!
              live-out
              (* b words)
              live-in
              (* idx words)
              words)]
          [(StringI64MapMissing) unit])
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
              (array-ref use-rows idx)
              (bit-and
                (array-ref live-out idx)
                (bit-xor (array-ref def-rows idx) -1)))]
          (begin
            (if (= next (array-ref live-in idx))
              unit
              (begin
                (array-set! live-in idx next)
                (set! changed true)))
            (set! w (+ w 1)))))
      changed)))

(define (compiler-reg-bits-iterate!
  [arr : (Array CompilerLiveBlock)]
  [idmap : StringI64Map]
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
        (compiler-reg-live-block-succs (array-ref arr b))
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
  [idmap : StringI64Map]
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
            (array-ref row (+ base w))
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
            (array-ref slots index))
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
                  ends))))])]))

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
        [arr : (Array CompilerLiveBlock) (make-array CompilerLiveBlock count)]
        [use-rows : (Array i64) (make-array i64 cells)]
        [def-rows : (Array i64) (make-array i64 cells)]
        [live-in : (Array i64) (make-array i64 cells)]
        [live-out : (Array i64) (make-array i64 cells)]
        [starts : (Array i64) (make-array i64 vars)]
        [ends : (Array i64) (make-array i64 vars)]
        (begin
          (compiler-reg-fill-i64-array use-rows 0)
          (compiler-reg-fill-i64-array def-rows 0)
          (compiler-reg-fill-i64-array live-in 0)
          (compiler-reg-fill-i64-array live-out 0)
          (compiler-reg-fill-i64-array starts -1)
          (compiler-reg-fill-i64-array ends -1)
          (let
            [idmap : StringI64Map
              (compiler-reg-bits-build-rows!
                live-blocks
                arr
                (string-i64-map-with-capacity
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
    [(IrInstrSelect dst _ _ _ _ _) (compiler-live-set-insert set dst)]
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
          (set! out (compiler-reg-ineligible-instr (array-ref slots index) out))
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
            (compiler-reg-ineligible-instr-seq instrs set))])]))

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
            (match (array-ref slots index)
              [(IrInstrCall _ _ _ _)
                (compiler-live-set-union
                  out
                  (compiler-live-after liveness label instr-index))]
              [(IrInstrTailCall _ _ _)
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
            (compiler-reg-call-live-instr-seq instrs liveness label 0 set))])]))

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
            (match (array-ref slots index)
              [(IrInstrCall _ _ args _)
                (compiler-live-set-union
                  out
                  (compiler-live-call-args-vars args))]
              [(IrInstrTailCall _ args _)
                (compiler-live-set-union
                  out
                  (compiler-live-call-args-vars args))]
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
            (compiler-reg-call-arg-vars-instr-seq instrs set))])]))

;; Ineligible variables are computed purely structurally (non-scalar/non-handle
;; types, params, call-argument vars, address-taken/memory targets). A value live
;; across a call is NOT ineligible: the integer pool admits only callee-saved
;; registers (%r12-%r15) which the callee (TypeLisp function prologue/epilogue, or
;; a runtime helper that push/pops them) preserves across the call, so a
;; call-spanning value keeps its home with no spill/reload. Dropping the old
;; call-live rule both removes the spill churn around calls and removes the only
;; consumer of full per-instruction liveness, so register planning needs only the
;; cheap block-level liveness used by compiler-reg-block-intervals.
(define (compiler-reg-ineligible-vars
  [func : CompilerIrFunction]
  [types : CompilerRegVarTypeList]) : CompilerLiveI64Set
  (match func
    [(IrFunction _ params _ _ blocks)
      (compiler-reg-ineligible-memory
        blocks
        (compiler-reg-ineligible-params
          params
          (compiler-reg-call-arg-vars-blocks
            blocks
            (compiler-reg-ineligible-non-scalars
              types
              (compiler-live-set-empty)
              true))))]))

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

(define (compiler-reg-vector-defs-instr
  [instr : CompilerIrInstr]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match instr
    [(IrInstrVectorBinOp dst _ _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrVectorLoad dst _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrPredicatedLoad dst _ _ _ _ _) (compiler-live-set-insert set dst)]
    [_ set]))

(define (compiler-reg-mask-defs-instr
  [instr : CompilerIrInstr]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match instr
    [(IrInstrVectorCompare dst _ _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrMaskBinOp dst _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrMaskNot dst _ _) (compiler-live-set-insert set dst)]
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
            (compiler-reg-vector-defs-instr (array-ref slots index) out-vector))
          (set!
            out-mask
            (compiler-reg-mask-defs-instr (array-ref slots index) out-mask))
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
                next-mask)])])]))

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
          (if (string-eq reg active-reg)
            true
            (compiler-reg-active-contains-register? (box-get rest) reg))])]))

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
              (compiler-reg-interval-lookup (box-get rest) var)))])]))

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
  [types : CompilerRegVarTypes]
  [left : i64]
  [right : i64]) : bool
  (match (compiler-reg-var-types-lookup types left)
    [(CompilerRegSomeType left-ty)
      (match (compiler-reg-var-types-lookup types right)
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
              (box-get rest)
              intervals
              var
              ignore-var
              location)
            (if (and
              (compiler-reg-location-eq? assigned-location location)
              (compiler-reg-vars-interfere? intervals var assigned-var))
              true
              (compiler-reg-location-conflicts?
                (box-get rest)
                intervals
                var
                ignore-var
                location)))])]))

(define (compiler-reg-coalesce-location-from-var
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalList]
  [types : CompilerRegVarTypes]
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
  [types : CompilerRegVarTypes]
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
                  (box-get rest)
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
                    (box-get rest)
                    assignments
                    intervals
                    types
                    var)])
              (compiler-reg-coalesce-location
                (box-get rest)
                assignments
                intervals
                types
                var)))])]))

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
  [types : CompilerRegVarTypes]) : CompilerRegAssignState
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
                      (box-get rest)
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
                      (box-get rest)
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
                        (box-get rest)
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
                      (box-get rest)
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

(define (compiler-reg-assign-fixed-candidates
  [candidates : CompilerRegIntervalList]
  [regs : CompilerRegStringList]
  [active : CompilerRegActiveList]
  [assignments : CompilerRegAssignmentList]) : CompilerRegAssignState
  (match candidates
    [(CompilerRegIntervalNil) (CompilerRegAssignState active assignments)]
    [(CompilerRegIntervalCons interval rest)
      (match interval
        [(CompilerRegInterval var start end)
          (let
            [expired : CompilerRegActiveList
              (compiler-reg-expire-active active start)]
            (if (=
              (compiler-reg-active-count expired)
              (compiler-reg-string-list-count regs))
              (compiler-reg-assign-fixed-candidates
                (box-get rest)
                regs
                expired
                assignments)
              (let
                [reg : String (compiler-reg-first-free-register regs expired)]
                (compiler-reg-assign-fixed-candidates
                  (box-get rest)
                  regs
                  (compiler-reg-active-insert
                    expired
                    (CompilerRegActive var end reg))
                  (compiler-reg-assignment-insert
                    assignments
                    var
                    (CompilerRegRegister reg))))))])]))

;; Call points (#perf/correctness): the integer pool admits only callee-saved
;; registers, so a value live across a call keeps its home safely. The XMM/float
;; pool, however, uses CALLER-saved registers (the backend has no callee-saved
;; XMM save/restore), which a call clobbers — so a FLOAT value live across a call
;; must NOT be register-homed. We compute the set of instruction points that hold
;; a call (using the same 2-per-instruction numbering as the live intervals) and
;; mark any float-typed value whose interval strictly spans a call point
;; ineligible. Integers are unaffected (their pool is call-safe).
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
            (match (array-ref slots index)
              [(IrInstrCall _ _ _ _) (compiler-live-set-insert out p)]
              [(IrInstrCallIndirect _ _ _ _) (compiler-live-set-insert out p)]
              [(IrInstrTailCall _ _ _) (compiler-live-set-insert out p)]
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
              (compiler-reg-call-points-blocks (box-get rest) p2 s2)])])]))

(define (compiler-reg-call-points [func : CompilerIrFunction]) : CompilerLiveI64Set
  (match func
    [(IrFunction _ _ _ _ blocks)
      (match (compiler-reg-call-points-blocks
        blocks
        0
        (compiler-live-set-empty))
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

(define (compiler-reg-call-set-in-range?
  [set : CompilerLiveI64Set]
  [start : i64]
  [end : i64]) : bool
  (match set
    [(CompilerLiveI64Nil) false]
    [(CompilerLiveI64Cons chunk rest)
      (if (compiler-reg-call-word-in-range?
        (compiler-live-set-chunk-bits chunk)
        (*
          (compiler-live-set-chunk-word-index chunk)
          (compiler-live-set-word-bits))
        start
        end)
        true
        (compiler-reg-call-set-in-range? (box-get rest) start end))]))

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

;; Shared linear-scan body: assign the integer pool, then XMM, then vector, then
;; mask registers over the given intervals/ineligible set.
(define (compiler-reg-plan-from
  [func : CompilerIrFunction]
  [type-info : CompilerRegVarTypes]
  [types : CompilerRegVarTypeList]
  [intervals : CompilerRegIntervalList]
  [ineligible : CompilerLiveI64Set]) : CompilerRegPlan
  (let
    [moves : CompilerRegMoveList (compiler-reg-function-moves func)]
    [vector-mask-defs : CompilerLiveUseDef
      (compiler-reg-function-vector-mask-defs func)]
    (match (compiler-reg-assign-candidates
      (compiler-reg-candidates intervals type-info ineligible false)
      (compiler-reg-sysv-integer-registers)
      CompilerRegActiveNil
      CompilerRegAssignmentNil
      moves
      intervals
      type-info)
      [(CompilerRegAssignState _ integer-assignments)
        (match (compiler-reg-assign-candidates
          (compiler-reg-candidates intervals type-info ineligible true)
          (compiler-reg-xmm-registers)
          CompilerRegActiveNil
          integer-assignments
          moves
          intervals
          type-info)
          [(CompilerRegAssignState _ scalar-assignments)
            (match vector-mask-defs
              [(CompilerLiveUseDef vector-vars mask-vars)
                (match (compiler-reg-assign-fixed-candidates
                  (compiler-reg-special-candidates
                    intervals
                    vector-vars
                    ineligible)
                  (compiler-reg-vector-registers)
                  CompilerRegActiveNil
                  scalar-assignments)
                  [(CompilerRegAssignState _ vector-assignments)
                    (match (compiler-reg-assign-fixed-candidates
                      (compiler-reg-special-candidates
                        intervals
                        mask-vars
                        ineligible)
                      (compiler-reg-mask-registers)
                      CompilerRegActiveNil
                      vector-assignments)
                      [(CompilerRegAssignState _ assignments)
                        (CompilerRegPlan assignments ineligible intervals types)])])])])])))

;; SIMD/AVX register plan (unchanged from before #perf): full dataflow-liveness
;; intervals + the call-live-conservative ineligibility, keeping AVX backend
;; golden output byte-identical.
(define (compiler-reg-plan-function [func : CompilerIrFunction]) : CompilerRegPlan
  (let
    [liveness : CompilerFunctionLiveness (compiler-live-analyze-function func)]
    [type-info : CompilerRegVarTypes (compiler-reg-function-var-types func)]
    [types : CompilerRegVarTypeList (compiler-reg-var-types-list type-info)]
    (compiler-reg-plan-from
      func
      type-info
      types
      (compiler-reg-live-intervals func liveness)
      (compiler-reg-ineligible-vars-simd func liveness types))))

;; Scalar register plan (#perf, opt level 2): cheap block-level live intervals,
;; structural ineligibility that keeps call-spanning integers/handles in
;; callee-saved registers, and float-call-spanning exclusion for the caller-saved
;; XMM pool.
(define (compiler-reg-plan-function-scalar [func : CompilerIrFunction]) : CompilerRegPlan
  (let
    [type-info : CompilerRegVarTypes (compiler-reg-function-var-types func)]
    [types : CompilerRegVarTypeList (compiler-reg-var-types-list type-info)]
    [intervals : CompilerRegIntervalList (compiler-reg-block-intervals func)]
    (compiler-reg-plan-from
      func
      type-info
      types
      intervals
      (compiler-reg-mark-float-spanning
        intervals
        type-info
        (compiler-reg-call-points func)
        (compiler-reg-ineligible-vars func types)))))

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
      (compiler-reg-var-types-list type-info))))

(define (compiler-reg-plan-assignments [plan : CompilerRegPlan]) : CompilerRegAssignmentList
  (match plan
    [(CompilerRegPlan assignments _ _ _) assignments]))

(define (compiler-reg-plan-ineligible [plan : CompilerRegPlan]) : CompilerLiveI64Set
  (match plan
    [(CompilerRegPlan _ ineligible _ _) ineligible]))

(define (compiler-reg-plan-intervals [plan : CompilerRegPlan]) : CompilerRegIntervalList
  (match plan
    [(CompilerRegPlan _ _ intervals _) intervals]))

(define (compiler-reg-plan-types [plan : CompilerRegPlan]) : CompilerRegVarTypeList
  (match plan
    [(CompilerRegPlan _ _ _ types) types]))

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

(define (compiler-reg-location-any-register?
  [maybe-location : CompilerRegMaybeLocation]) : bool
  (match maybe-location
    [(CompilerRegSomeLocation location)
      (match location
        [(CompilerRegRegister _) true]
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
          (IrInstrMov 0 (IrValueF64 "1.5") (compiler-reg-f64-ty))
          (compiler-ir-instr-cons
            (IrInstrStore "g0" (IrValueVar 0) (compiler-reg-f64-ty))
            (compiler-ir-instr-cons
              (IrInstrMov 1 (IrValueF64 "2.5") (compiler-reg-f64-ty))
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
          (IrInstrMov 0 (IrValueF64 "0.5") (compiler-reg-f64-ty))
          (compiler-ir-instr-cons
            (IrInstrMov 1 (IrValueF64 "1.5") (compiler-reg-f64-ty))
            (compiler-ir-instr-cons
              (IrInstrMov 2 (IrValueF64 "2.5") (compiler-reg-f64-ty))
              (compiler-ir-instr-cons
                (IrInstrMov 3 (IrValueF64 "3.5") (compiler-reg-f64-ty))
                (compiler-ir-instr-cons
                  (IrInstrMov 4 (IrValueF64 "4.5") (compiler-reg-f64-ty))
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
          (IrInstrMov 0 (IrValueF64 "9.5") (compiler-reg-f64-ty))
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
          (IrInstrMov 0 (IrValueF64 "1.5") (compiler-reg-f64-ty))
          (compiler-ir-instr-cons
            (IrInstrCall
              1
              "takes_f64"
              (IrCallArgsOne (IrValueVar 0))
              (AstTyUnit))
            (compiler-ir-instr-cons
              (IrInstrMov 2 (IrValueF64 "2.5") (compiler-reg-f64-ty))
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
          (IrInstrMov 1 (IrValueF64 "1.5") (AstTyF64))
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
              (IrInstrVectorBinOp
                2
                (IrBinAdd)
                (IrValueVar 0)
                (IrValueVar 1)
                4
                (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrVectorBinOp
                  3
                  (IrBinAdd)
                  (IrValueVar 0)
                  (IrValueVar 2)
                  4
                  (AstTyI64))
                (compiler-ir-instr-cons
                  (IrInstrVectorStore
                    (IrValueI64 0)
                    (IrValueI64 8)
                    (IrValueVar 3)
                    4
                    (AstTyI64))
                  (compiler-ir-instr-cons (IrInstrReturn IrNoValue) IrInstrNil)))))))
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
    [(CompilerRegPlan assignments _ _ _)
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
    [(CompilerRegPlan assignments _ _ _)
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
    [(CompilerRegPlan assignments _ _ _)
      ;; Seven simultaneously live values against a four-register callee-saved
      ;; pool: the first four take %r12..%r15 and the remaining three spill.
      (and
        (= (compiler-reg-assignment-count assignments) 7)
        (and
          (= (compiler-reg-spill-count assignments) 3)
          (and
            (compiler-reg-location-register?
              (compiler-reg-assignment-lookup assignments 3)
              "%r15")
            (and
              (compiler-reg-location-spill-offset?
                (compiler-reg-assignment-lookup assignments 4)
                (compiler-reg-stack-slot-offset 4))
              (compiler-reg-location-spill-offset?
                (compiler-reg-assignment-lookup assignments 6)
                (compiler-reg-stack-slot-offset 6))))))]))

(define (compiler-reg-f64-overlap-spill-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-f64-overlap-function))
    [(CompilerRegPlan assignments _ _ _)
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
    [(CompilerRegPlan assignments ineligible _ _)
      (and
        (compiler-live-set-contains? ineligible 0)
        (and
          (compiler-live-set-contains? ineligible 1)
          (and
            (compiler-reg-unassigned? assignments 0)
            (compiler-reg-location-register?
              (compiler-reg-assignment-lookup assignments 2)
              "%r12"))))]))

;; Scalar plan (#perf): the same function, but an integer value live across a
;; call now keeps a callee-saved register home (the integer pool is call-safe),
;; while the unit call result stays ineligible.
(define (compiler-reg-scalar-call-live-ok?) : bool
  (match (compiler-reg-plan-function-scalar (compiler-reg-call-live-function))
    [(CompilerRegPlan assignments ineligible _ _)
      (and
        (not (compiler-live-set-contains? ineligible 0))
        (and
          (compiler-reg-location-any-register?
            (compiler-reg-assignment-lookup assignments 0))
          (compiler-reg-location-any-register?
            (compiler-reg-assignment-lookup assignments 2))))]))

;; Scalar plan correctness: a FLOAT value live across a call must NOT be homed in
;; the caller-saved XMM pool, so it stays ineligible even on the scalar path.
(define (compiler-reg-scalar-f64-call-live-ok?) : bool
  (match (compiler-reg-plan-function-scalar
    (compiler-reg-f64-call-live-function))
    [(CompilerRegPlan assignments ineligible _ _)
      (and
        (compiler-live-set-contains? ineligible 0)
        (compiler-reg-unassigned? assignments 0))]))

(define (compiler-reg-f64-call-live-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-f64-call-live-function))
    [(CompilerRegPlan assignments ineligible _ _)
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
    [(CompilerRegPlan assignments ineligible _ _)
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
    [(CompilerRegPlan assignments ineligible _ _)
      (and
        (compiler-live-set-contains? ineligible 0)
        (and
          (compiler-reg-unassigned? assignments 0)
          (compiler-reg-location-register?
            (compiler-reg-assignment-lookup assignments 2)
            "%xmm2")))]))

(define (compiler-reg-ineligible-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-ineligible-function))
    [(CompilerRegPlan assignments ineligible _ _)
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
                  (compiler-live-set-contains? ineligible 6)))))]
        [unassigned : bool
          (and
            (compiler-reg-unassigned? assignments 0)
            (and
              (compiler-reg-unassigned? assignments 2)
              (and
                (compiler-reg-unassigned? assignments 3)
                (and
                  (compiler-reg-unassigned? assignments 4)
                  (compiler-reg-unassigned? assignments 6)))))]
        [homes : bool
          (and
            (compiler-reg-location-register?
              (compiler-reg-assignment-lookup assignments 1)
              "%xmm2")
            (compiler-reg-location-register?
              (compiler-reg-assignment-lookup assignments 5)
              "%r12"))]
        (and marked (and unassigned homes)))]))

;; Scalar plan (#perf): String/DynArray handles (vars 2/4) are register-eligible
;; 8-byte values; params (var 0) and address-taken values (var 3 via the AddrOf
;; into var 6) stay ineligible.
(define (compiler-reg-scalar-handle-eligible-ok?) : bool
  (match (compiler-reg-plan-function-scalar (compiler-reg-ineligible-function))
    [(CompilerRegPlan _ ineligible _ _)
      (and
        (and
          (compiler-live-set-contains? ineligible 0)
          (and
            (compiler-live-set-contains? ineligible 3)
            (compiler-live-set-contains? ineligible 6)))
        (and
          (not (compiler-live-set-contains? ineligible 2))
          (not (compiler-live-set-contains? ineligible 4))))]))

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
    [(CompilerRegPlan chain-assignments _ _ _)
      (match (compiler-reg-plan-function (compiler-reg-phi-join-function))
        [(CompilerRegPlan phi-assignments _ _ _)
          (match (compiler-reg-plan-function
            (compiler-reg-loop-backedge-function))
            [(CompilerRegPlan loop-assignments _ _ _)
              (match (compiler-reg-plan-function
                (compiler-reg-interference-blocks-coalesce-function))
                [(CompilerRegPlan blocked-assignments _ _ _)
                  (match (compiler-reg-plan-function
                    (compiler-reg-spill-coalesce-function))
                    [(CompilerRegPlan spill-assignments _ _ _)
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

(define (compiler-reg-vector-mask-homes-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-vector-home-function))
    [(CompilerRegPlan vector-assignments _ _ _)
      (match (compiler-reg-plan-function (compiler-reg-mask-home-function))
        [(CompilerRegPlan mask-assignments _ _ _)
          (let
            [vector-ok : bool
              (and
                (compiler-reg-location-register?
                  (compiler-reg-assignment-lookup vector-assignments 0)
                  "%vec6")
                (and
                  (compiler-reg-location-register?
                    (compiler-reg-assignment-lookup vector-assignments 1)
                    "%vec7")
                  (and
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup vector-assignments 2)
                      "%vec7")
                    (compiler-reg-location-register?
                      (compiler-reg-assignment-lookup vector-assignments 3)
                      "%vec6"))))]
            [mask-ok : bool
              (and
                (compiler-reg-location-register?
                  (compiler-reg-assignment-lookup mask-assignments 0)
                  "%k1")
                (and
                  (compiler-reg-location-register?
                    (compiler-reg-assignment-lookup mask-assignments 1)
                    "%k2")
                  (compiler-reg-location-register?
                    (compiler-reg-assignment-lookup mask-assignments 3)
                    "%k1")))]
            (and vector-ok mask-ok))])]))

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
              ;; The allocatable pool admits only callee-saved registers, so a
              ;; value homed there survives an intervening call. It must never
              ;; offer a caller-saved register such as %r8/%r9.
              (and
                (compiler-reg-string-list-contains?
                  (compiler-reg-sysv-integer-registers)
                  "%r12")
                (and
                  (not
                    (compiler-reg-string-list-contains?
                      (compiler-reg-sysv-integer-registers)
                      "%r8"))
                  (not
                    (compiler-reg-string-list-contains?
                      (compiler-reg-sysv-integer-registers)
                      "%r9")))))))))))

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
                        (and
                          (compiler-reg-coalesce-ok?)
                          (and
                            (compiler-reg-vector-mask-homes-ok?)
                            (and
                              (compiler-reg-scalar-call-live-ok?)
                              (and
                                (compiler-reg-scalar-f64-call-live-ok?)
                                (compiler-reg-scalar-handle-eligible-ok?))))))))))))))))
    42
    (begin
      (panic "regalloc: smoke mismatch")
      0)))