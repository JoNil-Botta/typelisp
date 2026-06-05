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
        (box-get rest)
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
            (box-get rest)
            (compiler-reg-instr-list-types instrs types))])]))

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

(define (compiler-reg-instr-list-types-array!
  [instrs : CompilerIrInstrList]
  [present : (Array i64)]
  [types : (Array AstType)]) : unit
  (match instrs
    [(IrInstrNil) unit]
    [(IrInstrCons instr rest)
      (begin
        (compiler-reg-instr-def-type-array! instr present types)
        (compiler-reg-instr-list-types-array! (box-get rest) present types))]))

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
            (compiler-reg-instr-list-types-array! instrs present types)
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

(define (compiler-reg-instr-list-moves
  [instrs : CompilerIrInstrList]
  [moves : CompilerRegMoveList]) : CompilerRegMoveList
  (match instrs
    [(IrInstrNil) moves]
    [(IrInstrCons instr rest)
      (compiler-reg-instr-moves
        instr
        (compiler-reg-instr-list-moves (box-get rest) moves))]))

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
            (compiler-reg-instr-list-moves instrs moves))])]))

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
        (compiler-reg-extend-set starts ends rest point))]))

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

(define (compiler-reg-live-intervals-instrs
  [instrs : CompilerIrInstrList]
  [live-afters : CompilerLiveInstrSetList]
  [point : i64]
  [starts : (Array i64)]
  [ends : (Array i64)]) : i64
  (match instrs
    [(IrInstrNil) point]
    [(IrInstrCons instr rest)
      (match live-afters
        [(CompilerLiveInstrSetCons live-after rest-after)
          (begin
            (compiler-reg-extend-instr starts ends live-after point instr)
            (compiler-reg-live-intervals-instrs
              (box-get rest)
              (box-get rest-after)
              (+ point 2)
              starts
              ends))]
        [(CompilerLiveInstrSetNil)
          (begin
            (compiler-reg-extend-instr
              starts
              ends
              (compiler-live-set-empty)
              point
              instr)
            (compiler-reg-live-intervals-instrs
              (box-get rest)
              CompilerLiveInstrSetNil
              (+ point 2)
              starts
              ends))])]))

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
              (compiler-reg-live-intervals-instrs
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

(define (compiler-reg-ineligible-non-scalars
  [types : CompilerRegVarTypeList]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match types
    [(CompilerRegVarTypeNil) set]
    [(CompilerRegVarTypeCons item rest)
      (match item
        [(CompilerRegVarType var ty)
          (compiler-reg-ineligible-non-scalars
            (box-get rest)
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

(define (compiler-reg-ineligible-instrs
  [instrs : CompilerIrInstrList]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match instrs
    [(IrInstrNil) set]
    [(IrInstrCons instr rest)
      (compiler-reg-ineligible-instrs
        (box-get rest)
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
            (box-get rest)
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
        (compiler-reg-call-live-instrs
          (box-get rest)
          liveness
          label
          (+ index 1)
          next-set))]))

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
            (compiler-reg-call-live-instrs instrs liveness label 0 set))])]))

(define (compiler-reg-call-arg-vars-instrs
  [instrs : CompilerIrInstrList]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match instrs
    [(IrInstrNil) set]
    [(IrInstrCons instr rest)
      (compiler-reg-call-arg-vars-instrs
        (box-get rest)
        (match instr
          [(IrInstrCall _ _ args _)
            (compiler-live-set-union set (compiler-live-call-args-vars args))]
          [(IrInstrTailCall _ args _)
            (compiler-live-set-union set (compiler-live-call-args-vars args))]
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
            (box-get rest)
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
              (compiler-reg-ineligible-non-scalars
                types
                (compiler-live-set-empty))))))]))

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

(define (compiler-reg-vector-mask-defs-instrs
  [instrs : CompilerIrInstrList]
  [vector-set : CompilerLiveI64Set]
  [mask-set : CompilerLiveI64Set]) : CompilerLiveUseDef
  (match instrs
    [(IrInstrNil) (CompilerLiveUseDef vector-set mask-set)]
    [(IrInstrCons instr rest)
      (compiler-reg-vector-mask-defs-instrs
        (box-get rest)
        (compiler-reg-vector-defs-instr instr vector-set)
        (compiler-reg-mask-defs-instr instr mask-set))]))

(define (compiler-reg-vector-mask-defs-blocks
  [blocks : CompilerIrBlockList]
  [vector-set : CompilerLiveI64Set]
  [mask-set : CompilerLiveI64Set]) : CompilerLiveUseDef
  (match blocks
    [(IrBlockNil) (CompilerLiveUseDef vector-set mask-set)]
    [(IrBlockCons block rest)
      (match block
        [(IrBlock _ instrs)
          (match (compiler-reg-vector-mask-defs-instrs
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

(define (compiler-reg-plan-function [func : CompilerIrFunction]) : CompilerRegPlan
  (let
    [liveness : CompilerFunctionLiveness (compiler-live-analyze-function func)]
    [type-info : CompilerRegVarTypes (compiler-reg-function-var-types func)]
    [types : CompilerRegVarTypeList (compiler-reg-var-types-list type-info)]
    [intervals : CompilerRegIntervalList
      (compiler-reg-live-intervals func liveness)]
    [ineligible : CompilerLiveI64Set
      (compiler-reg-ineligible-vars func liveness types)]
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
      (IrBlock
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
      (IrBlock
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
      (IrBlock
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
      (IrBlock
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
      (IrBlock
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
      (IrBlock
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
      (IrBlock
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
      (IrBlock
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
      (IrBlock
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
      (IrBlock
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
      (IrBlock
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 7) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons (IrInstrJump "join") IrInstrNil)))
      (compiler-ir-block-cons
        (IrBlock
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
      (IrBlock
        "entry"
        (compiler-ir-instr-cons
          (IrInstrMov 0 (IrValueI64 0) (compiler-reg-i64-ty))
          (compiler-ir-instr-cons (IrInstrJump "loop") IrInstrNil)))
      (compiler-ir-block-cons
        (IrBlock
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
          (IrBlock
            "body"
            (compiler-ir-instr-cons (IrInstrJump "loop") IrInstrNil))
          (compiler-ir-block-cons
            (IrBlock
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
      (IrBlock
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
      (IrBlock
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
      (IrBlock
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
      (IrBlock
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
                          (compiler-reg-vector-mask-homes-ok?)))))))))))))
    42
    (begin
      (panic "regalloc: smoke mismatch")
      0)))