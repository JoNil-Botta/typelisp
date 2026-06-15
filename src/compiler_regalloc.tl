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
  ;; #2386: a 2-word register-group value lives in two GP registers (word0,
  ;; word1). A group that cannot get two registers spills to a 16-byte slot,
  ;; represented as the ordinary CompilerRegSpill (the backend reads the second
  ;; word at offset-8 using the program word-count map).
  (CompilerRegRegisterPair String String)
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

(defstruct CompilerRegAssignmentIndex
  (present (Array i64))
  (items (Array CompilerRegLocation)))

(defstruct CompilerRegIntervalIndex
  (starts (Array i64))
  (ends (Array i64)))

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
;; would silently observe garbage. The five registers below are exactly those
;; the backend prologue/epilogue save and restore. Mirrors the former Rust
;; backend's `SYSV_ALLOCATABLE_INTEGER_REGS` (callee-saved only).
;;
;; %rbx is callee-saved under both SysV and Win64 and was historically reserved
;; as the backend's hard scratch register for the right-hand operand of integer
;; binops/compares/gep/div/shift. That scratch role moved to %r8 (caller-saved
;; under both ABIs, only ever live inside a single instruction's emission, never
;; across a call), freeing %rbx to join the allocatable pool. It is added LAST so
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
            (compiler-reg-instr-seq-moves instrs moves))])]
    [(IrBlockArray seq)
      (compiler-reg-block-list-moves (compiler-ir-block-seq-to-list seq) moves)]))

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

(define (compiler-reg-fill-location-array
  [items : (Array CompilerRegLocation)]
  [value : CompilerRegLocation]) : unit
  (let
    [index : i64 0]
    [count : i64 (array-length items)]
    (begin
      (while (< index count)
        (begin
          (array-set! items index value)
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
              (>= var (array-length present))
              (not (= (array-ref present var) 0)))
              unit
              (begin
                (array-set! present var 1)
                (array-set! items var location)))])
        (compiler-reg-assignment-index-fill! (box-get rest) present items))]))

(define (compiler-reg-assignment-index-build
  [assignments : CompilerRegAssignmentList]
  [vars : i64]) : CompilerRegAssignmentIndex
  (let
    [present : (Array i64) (make-array i64 vars)]
    [items : (Array CompilerRegLocation) (make-array CompilerRegLocation vars)]
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
    (if (or (< var 0) (>= var (array-length present)))
      CompilerRegNoLocation
      (if (= (array-ref present var) 0)
        CompilerRegNoLocation
        (CompilerRegSomeLocation (array-ref items var))))))

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
              (>= var (array-length starts))
              (>= (array-ref starts var) 0))
              unit
              (begin
                (array-set! starts var start)
                (array-set! ends var end)))])
        (compiler-reg-interval-index-fill! (box-get rest) starts ends))]))

(define (compiler-reg-interval-index-build
  [intervals : CompilerRegIntervalList]
  [vars : i64]) : CompilerRegIntervalIndex
  (let
    [starts : (Array i64) (make-array i64 vars)]
    [ends : (Array i64) (make-array i64 vars)]
    (begin
      (compiler-reg-fill-i64-array starts -1)
      (compiler-reg-fill-i64-array ends -1)
      (compiler-reg-interval-index-fill! intervals starts ends)
      (CompilerRegIntervalIndex starts ends))))

(define (compiler-reg-interval-index-lookup
  [index : CompilerRegIntervalIndex]
  [var : i64]) : CompilerRegMaybeInterval
  (let
    [starts : (Array i64) (struct-get index starts)]
    [ends : (Array i64) (struct-get index ends)]
    (if (or (< var 0) (>= var (array-length starts)))
      CompilerRegNoInterval
      (if (< (array-ref starts var) 0)
        CompilerRegNoInterval
        (CompilerRegSomeInterval
          (CompilerRegInterval var (array-ref starts var) (array-ref ends var)))))))

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

(define (compiler-reg-extend-set-words
  [starts : (Array i64)]
  [ends : (Array i64)]
  [set : CompilerLiveI64Set]
  [word-index : i64]
  [point : i64]) : unit
  (if (>= word-index (compiler-live-set-word-count set))
    unit
    (begin
      (compiler-reg-extend-set-word-bits
        starts
        ends
        (compiler-live-set-word-at set word-index)
        (* word-index (compiler-live-set-word-bits))
        point)
      (compiler-reg-extend-set-words starts ends set (+ word-index 1) point))))

(define (compiler-reg-extend-set
  [starts : (Array i64)]
  [ends : (Array i64)]
  [set : CompilerLiveI64Set]
  [point : i64]) : unit
  (compiler-reg-extend-set-words starts ends set 0 point))

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
            (if (< index (array-length after-items))
              (array-ref after-items index)
              (compiler-live-set-empty))]
          (begin
            (compiler-reg-extend-instr
              starts
              ends
              live-after
              out-point
              (array-ref slots index))
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

(define (compiler-reg-live-intervals-blocks
  [blocks : CompilerIrBlockList]
  [liveness : CompilerFunctionLiveness]
  [point : i64]
  [starts : (Array i64)]
  [ends : (Array i64)]) : i64
  (compiler-reg-live-intervals-blocks-with-live
    blocks
    liveness
    point
    starts
    ends))

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
            (match (array-ref slots index)
              [(IrInstrCall _ _ _ _)
                (compiler-live-set-union
                  out
                  (compiler-live-after liveness label instr-index))]
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
            (match (array-ref slots index)
              [(IrInstrCall _ _ args _)
                (compiler-live-set-union
                  out
                  (compiler-live-call-args-vars args))]
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

;; Ineligible variables are computed purely structurally (non-scalar/non-handle
;; types, params, call-argument vars, address-taken/memory targets). A value live
;; across a call is NOT ineligible: the integer pool admits only callee-saved
;; registers (%r12-%r15) which the callee (TypeLisp function prologue/epilogue, or
;; a runtime helper that push/pops them) preserves across the call, so a
;; call-spanning value keeps its home with no spill/reload. The scalar planner
;; can use either full per-instruction or cheap block-level register intervals;
;; this helper is only the structural eligibility policy layered on top.
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
    [(IrInstrLaneId dst _ _) (compiler-live-set-insert set dst)]
    [(IrInstrSplat dst _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrVectorBinOp dst _ _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrSelect dst _ _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrVectorLoad dst _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrPredicatedLoad dst _ _ _ _ elem-ty)
      (match elem-ty
        [(AstTyBool) set]
        [_ (compiler-live-set-insert set dst)])]
    [_ set]))

(define (compiler-reg-mask-defs-instr
  [instr : CompilerIrInstr]
  [set : CompilerLiveI64Set]) : CompilerLiveI64Set
  (match instr
    [(IrInstrVectorCompare dst _ _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrMaskBinOp dst _ _ _ _) (compiler-live-set-insert set dst)]
    [(IrInstrMaskNot dst _ _) (compiler-live-set-insert set dst)]
    [(IrInstrPredicatedLoad dst _ _ _ _ elem-ty)
      (match elem-ty
        [(AstTyBool) (compiler-live-set-insert set dst)]
        [_ set])]
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
        [(CompilerRegRegister right-reg) (string-eq left-reg right-reg)]
        [_ false])]
    [(CompilerRegRegisterPair left-a left-b)
      (match right
        [(CompilerRegRegisterPair right-a right-b)
          (and (string-eq left-a right-a) (string-eq left-b right-b))]
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
            (compiler-reg-scalar-type? right-ty)
            (= (ast-type-tag left-ty) (ast-type-tag right-ty)))]
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

(define (compiler-reg-coalesce-location-from-var
  [assignments : CompilerRegAssignmentList]
  [intervals : CompilerRegIntervalIndex]
  [types : CompilerRegVarTypes]
  [var : i64]
  [other : i64]) : CompilerRegMaybeLocation
  (if (or
    (= var other)
    (not (compiler-reg-compatible-types? types var other))
    (compiler-reg-vars-interfere-index? intervals var other))
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
  [intervals : CompilerRegIntervalIndex]
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
  [assignments : CompilerRegAssignmentList]
  [group-vars : CompilerLiveI64Set]) : CompilerRegAssignState
  (match interval
    [(CompilerRegInterval var _ end)
      (match (compiler-reg-active-max-non-group active group-vars)
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
  [interval-index : CompilerRegIntervalIndex]
  [types : CompilerRegVarTypes]
  [group-vars : CompilerLiveI64Set]) : CompilerRegAssignState
  (match candidates
    [(CompilerRegIntervalNil) (CompilerRegAssignState active assignments)]
    [(CompilerRegIntervalCons interval rest)
      (match interval
        [(CompilerRegInterval var start end)
          (let
            [expired : CompilerRegActiveList
              (compiler-reg-expire-active active start)]
            (match (if (compiler-live-set-contains? group-vars var)
              ;; #2386 (C5): a register-group (2-word) var must NEVER be coalesced
              ;; onto a single GP register. Coalescing runs before the group check
              ;; below, and the only thing that stopped a group var from coalescing
              ;; was an indirect scalar-type guard that holds only on -O2-normalized
              ;; IR; on lighter -O1 IR an un-normalized Pack dst could coalesce onto
              ;; one register and crash emit-pack. Forcing the NoLocation path makes
              ;; group membership authoritative (-> register PAIR or 16-byte spill)
              ;; independent of opt level. No-op at -O2 (the guard already excluded
              ;; aggregate-typed vars from coalescing there).
              (CompilerRegNoLocation)
              (compiler-reg-coalesce-location
                moves
                assignments
                interval-index
                types
                var))
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
                      interval-index
                      types
                      group-vars)]
                  [(CompilerRegRegisterPair reg-a reg-b)
                    ;; #2386: a coalesced register-pair occupies both registers for
                    ;; the var's lifetime -- two active entries that expire together.
                    (compiler-reg-assign-candidates
                      (box-get rest)
                      regs
                      (compiler-reg-active-insert
                        (compiler-reg-active-insert
                          expired
                          (CompilerRegActive var end reg-a))
                        (CompilerRegActive var end reg-b))
                      (compiler-reg-assignment-insert assignments var location)
                      moves
                      interval-index
                      types
                      group-vars)]
                  [(CompilerRegSpill _)
                    (compiler-reg-assign-candidates
                      (box-get rest)
                      regs
                      expired
                      (compiler-reg-assignment-insert assignments var location)
                      moves
                      interval-index
                      types
                      group-vars)])]
              [(CompilerRegNoLocation)
                (if (compiler-live-set-contains? group-vars var)
                  ;; #2386: a 2-word register-group var needs TWO free GP registers
                  ;; (a register pair). If two are not free it stays UNASSIGNED and
                  ;; the backend homes both words in the var's dedicated 16-byte
                  ;; stack region (group-word0-slot / group-word1-slot).
                  (if (compiler-reg-var-register-group-has-sse? types var)
                    ;; #2601: mixed/SSE register groups need per-word register
                    ;; banks. Until the allocator has a true mixed pair home,
                    ;; leave them in the existing two-slot stack fallback instead
                    ;; of assigning an SSE word to a GP register.
                    (compiler-reg-assign-candidates
                      (box-get rest)
                      regs
                      expired
                      assignments
                      moves
                      interval-index
                      types
                      group-vars)
                    (if (>=
                      (-
                        (compiler-reg-string-list-count regs)
                        (compiler-reg-active-count expired))
                      2)
                      (let
                        [reg-a : String
                          (compiler-reg-first-free-register regs expired)]
                        [active-a : CompilerRegActiveList
                          (compiler-reg-active-insert
                            expired
                            (CompilerRegActive var end reg-a))]
                        [reg-b : String
                          (compiler-reg-first-free-register regs active-a)]
                        (compiler-reg-assign-candidates
                          (box-get rest)
                          regs
                          (compiler-reg-active-insert
                            active-a
                            (CompilerRegActive var end reg-b))
                          (compiler-reg-assignment-insert
                            assignments
                            var
                            (CompilerRegRegisterPair reg-a reg-b))
                          moves
                          interval-index
                          types
                          group-vars))
                      ;; Fewer than two GP registers free: a group var cannot live in
                      ;; one register or an 8-byte spill slot, so leave it UNASSIGNED
                      ;; (NoLocation). The backend then homes both words in the var's
                      ;; reserved 16-byte stack region -- the same path stack-only mode
                      ;; uses. (compiler-reg-spill-at-interval would hand it a single
                      ;; register / 8-byte slot and crash emit-pack.)
                      (compiler-reg-assign-candidates
                        (box-get rest)
                        regs
                        expired
                        assignments
                        moves
                        interval-index
                        types
                        group-vars)))
                  (if (=
                    (compiler-reg-active-count expired)
                    (compiler-reg-string-list-count regs))
                    (match (compiler-reg-spill-at-interval
                      interval
                      expired
                      assignments
                      group-vars)
                      [(CompilerRegAssignState next-active next-assignments)
                        (compiler-reg-assign-candidates
                          (box-get rest)
                          regs
                          next-active
                          next-assignments
                          moves
                          interval-index
                          types
                          group-vars)])
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
                        interval-index
                        types
                        group-vars))))]))])]))

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
              [(IrInstrCallIndirectC _ _ _ _) (compiler-live-set-insert out p)]
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
(define compiler-reg-group-counts : StringI64Map
  (string-i64-map-with-capacity 8))

(define compiler-reg-group-class-masks : StringI64Map
  (string-i64-map-with-capacity 8))

(define (compiler-reg-set-group-counts! [counts : StringI64Map]) : unit
  (set! compiler-reg-group-counts counts))

(define (compiler-reg-set-group-class-masks! [masks : StringI64Map]) : unit
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
    (if (string-eq name "")
      false
      (match (string-i64-map-get compiler-reg-group-counts name)
        [(StringI64MapFound count) (> count 1)]
        [(StringI64MapMissing) false]))))

(define (compiler-reg-type-register-group-has-sse? [ty : AstType]) : bool
  (let
    [name : String (compiler-reg-aggregate-type-name ty)]
    (if (string-eq name "")
      false
      (match (string-i64-map-get compiler-reg-group-class-masks name)
        [(StringI64MapFound mask) (> mask 0)]
        [(StringI64MapMissing) false]))))

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
    [group-vars : CompilerLiveI64Set
      (compiler-reg-function-group-vars func types)]
    [vector-mask-defs : CompilerLiveUseDef
      (compiler-reg-function-vector-mask-defs func)]
    [interval-index : CompilerRegIntervalIndex
      (match func
        [(IrFunction _ _ _ vars _)
          (compiler-reg-interval-index-build intervals vars)])]
    (match (compiler-reg-assign-candidates
      (compiler-reg-candidates intervals type-info ineligible false)
      (compiler-reg-sysv-integer-registers)
      CompilerRegActiveNil
      CompilerRegAssignmentNil
      moves
      interval-index
      type-info
      group-vars)
      [(CompilerRegAssignState _ integer-assignments)
        (match (compiler-reg-assign-candidates
          (compiler-reg-candidates intervals type-info ineligible true)
          (compiler-reg-xmm-registers)
          CompilerRegActiveNil
          integer-assignments
          moves
          interval-index
          type-info
          (compiler-live-set-empty))
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

;; Scalar register plan (#perf, opt level 2): full dataflow live intervals for
;; small multi-block functions, structural ineligibility that keeps
;; call-spanning integers/handles in callee-saved registers, and
;; float-call-spanning exclusion for the caller-saved XMM pool. Single-block
;; functions cannot have loop-carried values; very large functions stay on the
;; cheap block-level interval builder to cap opt2 compiler cost.
(define (compiler-reg-scalar-full-interval-block-limit) : i64
  8)

(define (compiler-reg-scalar-full-intervals? [func : CompilerIrFunction]) : bool
  (match func
    [(IrFunction _ _ _ _ blocks)
      (let
        [count : i64 (compiler-ir-block-list-count blocks)]
        (and
          (> count 1)
          (<= count (compiler-reg-scalar-full-interval-block-limit))))]))

(define (compiler-reg-plan-function-scalar [func : CompilerIrFunction]) : CompilerRegPlan
  (let
    [type-info : CompilerRegVarTypes (compiler-reg-function-var-types func)]
    [types : CompilerRegVarTypeList (compiler-reg-var-types-list type-info)]
    [intervals : CompilerRegIntervalList
      (if (compiler-reg-scalar-full-intervals? func)
        (compiler-reg-live-intervals func (compiler-live-analyze-function func))
        (compiler-reg-block-intervals func))]
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
            (if (< var (array-length flags))
              (array-set!
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
                  (array-ref items pick)
                  (array-ref items left)))
                (set! pick left)
                unit)
              (if (and
                (< right count)
                (compiler-reg-color-interval-before?
                  (array-ref items pick)
                  (array-ref items right)))
                (set! pick right)
                unit)
              pick))]
        (if (= largest node)
          (set! done true)
          (let
            [tmp : CompilerRegInterval (array-ref items node)]
            (begin
              (array-set! items node (array-ref items largest))
              (array-set! items largest tmp)
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
          [tmp : CompilerRegInterval (array-ref items 0)]
          (begin
            (array-set! items 0 (array-ref items last))
            (array-set! items last tmp)
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
        (array-set! items index head)
        (compiler-reg-color-interval-fill (box-get rest) items (+ index 1)))]))

(define (compiler-reg-color-sorted-array [intervals : CompilerRegIntervalList]) : (Array
    CompilerRegInterval)
  (let
    [count : i64 (compiler-reg-color-interval-count intervals)]
    [items : (Array CompilerRegInterval) (make-array CompilerRegInterval count)]
    (begin
      (compiler-reg-color-interval-fill intervals items 0)
      (compiler-reg-color-heapsort items count)
      items)))

;; Lowest free slot whose previous occupant's interval ended strictly before
;; `start`. slot-ends[i] holds the end position of slot i's current occupant;
;; reserved slots carry a sentinel end that never expires. STRICT `<`: phi
;; parallel copies at a block edge read inputs and write destinations at the
;; same interval position, so same-position reuse would let one phi's
;; destination clobber another phi's not-yet-read input through the slot.
;; First slot id at or after `from` that is not identity-pinned to a
;; parameter (pins mark slot-ends with i64-max). Fresh slots fill the gaps a
;; sparse parameter id leaves behind, so slot ids never run past the pinned
;; band and the overall renumbering stays inside [0, vars).
(define (compiler-reg-color-next-free-slot
  [slot-ends : (Array i64)]
  [from : i64]) : i64
  (if (>= from (array-length slot-ends))
    from
    (if (= (array-ref slot-ends from) 9223372036854775807)
      (compiler-reg-color-next-free-slot slot-ends (+ from 1))
      from)))

(define (compiler-reg-color-walk
  [items : (Array CompilerRegInterval)]
  [count : i64]
  [index : i64]
  [assignment-index : CompilerRegAssignmentIndex]
  [pinned : CompilerLiveI64Set]
  [ineligible : CompilerLiveI64Set]
  [colorable : (Array bool)]
  [slot-ends : (Array i64)]
  [used : i64]
  [remap : (Array i64)]) : i64
  (if (>= index count)
    used
    (match (array-ref items index)
      [(CompilerRegInterval var start end)
        (if (or
          ;; Already renumbered: parameter identity pins (the prologue's
          ;; param spill targets the ORIGINAL id's formula slot, so a pinned
          ;; id must never be reassigned mid-walk) and split intervals (the
          ;; first interval wins; revisiting would leak the first slot).
          (>= (array-ref remap var) 0)
          (not (array-ref colorable var))
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
            used
            remap)
          (let
            ;; Slice 1 ships compaction only: every variable gets a fresh
            ;; dense slot. Fresh slots skip param-pinned ids so sparse
            ;; parameter ids leave no hole.
            [slot : i64 (compiler-reg-color-next-free-slot slot-ends used)]
            [next-used : i64 (+ slot 1)]
            (begin
              (array-set! slot-ends slot end)
              (array-set! remap var slot)
              (compiler-reg-color-walk
                items
                count
                (+ index 1)
                assignment-index
                pinned
                ineligible
                colorable
                slot-ends
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
            (if (and (>= var 0) (< var (array-length starts)))
              (begin
                (array-set! starts var start)
                (array-set! ends var end))
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
        (if (and (>= (+ first i) 0) (< (+ first i) (array-length range-of-var)))
          (array-set! range-of-var (+ first i) range-id)
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
          (match (array-ref slots i)
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
                  (< ranges (array-length range-base)))
                  (begin
                    (array-set! range-base ranges src)
                    (array-set! range-size ranges run-count)
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
      (if (and (>= var 0) (< var (array-length roots)))
        (array-ref roots var)
        (- 0 1))]
    [_ (- 0 1)]))

(define (compiler-reg-color-merge-root [acc : i64] [root : i64]) : i64
  (if (< root 0)
    (- 0 1)
    (if (< acc 0)
      root
      (if (= acc root)
        root
        (- 0 2)))))

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
  (if (or (< root 0) (< dst 0) (>= dst (array-length roots)))
    false
    (let
      [old : i64 (array-ref roots dst)]
      (if (= old root)
        false
        (if (< old 0)
          (begin
            (array-set! roots dst root)
            true)
          (begin
            (if (< old (array-length invalid))
              (array-set! invalid old true)
              unit)
            (if (< root (array-length invalid))
              (array-set! invalid root true)
              unit)
            (array-set! roots dst (- 0 2))
            true))))))

(define (compiler-reg-color-propagate-root-instr
  [instr : CompilerIrInstr]
  [range-of-var : (Array i64)]
  [roots : (Array i64)]
  [invalid : (Array bool)]) : bool
  (match instr
    [(IrInstrAddrOf dst src)
      (if (and (>= src 0) (< src (array-length range-of-var)))
        (compiler-reg-color-set-root!
          roots
          invalid
          dst
          (array-ref range-of-var src))
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
    [(IrInstrSelect dst _ true-value false-value _ _)
      (let
        [left : i64 (compiler-reg-color-value-root roots true-value)]
        [right : i64 (compiler-reg-color-value-root roots false-value)]
        (if (and (>= left 0) (= left right))
          (compiler-reg-color-set-root! roots invalid dst left)
          false))]
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
            (array-ref slots i)
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
    [limit : i64 (array-length roots)]
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
  (if (and (>= root 0) (< root (array-length invalid)))
    (array-set! invalid root true)
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
        [len : i64 (array-length items)]
        (while (< i len)
          (begin
            (compiler-reg-color-invalidate-value!
              roots
              invalid
              (array-ref items i))
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
            (>= dst (array-length roots))
            (not (= (array-ref roots dst) root))))
          (compiler-reg-color-invalidate-root! invalid root)
          unit))]
    [(IrInstrGep dst base _ _)
      (let
        [root : i64 (compiler-reg-color-value-root roots base)]
        (if (and
          (>= root 0)
          (or
            (>= dst (array-length roots))
            (not (= (array-ref roots dst) root))))
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
    [(IrInstrVectorBinOp _ _ lhs rhs _ _)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid lhs)
        (compiler-reg-color-invalidate-value! roots invalid rhs))]
    [(IrInstrVectorReduce _ _ src _ _)
      (compiler-reg-color-invalidate-value! roots invalid src)]
    [(IrInstrVectorCompare _ _ lhs rhs _ _)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid lhs)
        (compiler-reg-color-invalidate-value! roots invalid rhs))]
    [(IrInstrMaskBinOp _ _ lhs rhs _)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid lhs)
        (compiler-reg-color-invalidate-value! roots invalid rhs))]
    [(IrInstrMaskNot _ src _)
      (compiler-reg-color-invalidate-value! roots invalid src)]
    [(IrInstrMaskReduce _ _ src _)
      (compiler-reg-color-invalidate-value! roots invalid src)]
    [(IrInstrSelect dst mask true-value false-value _ _)
      (let
        [left : i64 (compiler-reg-color-value-root roots true-value)]
        [right : i64 (compiler-reg-color-value-root roots false-value)]
        [dst-root : i64
          (if (and (>= dst 0) (< dst (array-length roots)))
            (array-ref roots dst)
            (- 0 1))]
        (begin
          (compiler-reg-color-invalidate-value! roots invalid mask)
          (if (and (>= left 0) (not (= left dst-root)))
            (compiler-reg-color-invalidate-root! invalid left)
            unit)
          (if (and (>= right 0) (not (= right dst-root)))
            (compiler-reg-color-invalidate-root! invalid right)
            unit)))]
    [(IrInstrVectorLoad _ base index _ _)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid base)
        (compiler-reg-color-invalidate-value! roots invalid index))]
    [(IrInstrVectorStore base index value _ _)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid base)
        (compiler-reg-color-invalidate-value! roots invalid index)
        (compiler-reg-color-invalidate-value! roots invalid value))]
    [(IrInstrPredicatedStore base index value mask _ _)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid base)
        (compiler-reg-color-invalidate-value! roots invalid index)
        (compiler-reg-color-invalidate-value! roots invalid value)
        (compiler-reg-color-invalidate-value! roots invalid mask))]
    [(IrInstrPredicatedLoad _ base index mask _ _)
      (begin
        (compiler-reg-color-invalidate-value! roots invalid base)
        (compiler-reg-color-invalidate-value! roots invalid index)
        (compiler-reg-color-invalidate-value! roots invalid mask))]
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
      (if (string-eq name "tl_memcpy")
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
        (if (and (>= dst 0) (< dst (array-length roots)))
          (array-ref roots dst)
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
        (compiler-reg-color-invalidate-instr! (array-ref slots i) roots invalid)
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
    [max-start : i64 9223372036854775807]
    (while (< i (array-length roots))
      (let
        [root : i64 (array-ref roots i)]
        (begin
          (if (and (>= root 0) (< root (array-length range-starts)))
            (let
              [start : i64 (array-ref starts i)]
              [end : i64 (array-ref ends i)]
              (if (>= start 0)
                (begin
                  (if (< start (array-ref range-starts root))
                    (array-set! range-starts root start)
                    unit)
                  (if (> end (array-ref range-ends root))
                    (array-set! range-ends root end)
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
      (if (> (+ slot size) (array-length slot-ends))
        (set! ok false)
        unit)
      (while (and ok (< i size))
        (begin
          (if (< (array-ref slot-ends (+ slot i)) start)
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
        (if (< (+ slot i) (array-length slot-ends))
          (array-set! slot-ends (+ slot i) end)
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
        (if (and (>= (+ first i) 0) (< (+ first i) (array-length remap)))
          (array-set! remap (+ first i) (+ slot i))
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
            (< (+ first i) (array-length remap))
            (< (array-ref remap (+ first i)) 0))
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
          [start : i64 (array-ref range-starts range)]
          [end : i64 (array-ref range-ends range)]
          [size : i64 (array-ref range-size range)]
          [base : i64 (array-ref range-base range)]
          (begin
            (if (and
              (not (array-ref invalid range))
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
    [range-of-var : (Array i64) (make-array i64 vars)]
    [range-base : (Array i64) (make-array i64 vars)]
    [range-size : (Array i64) (make-array i64 vars)]
    [range-starts : (Array i64) (make-array i64 vars)]
    [range-ends : (Array i64) (make-array i64 vars)]
    [invalid : (Array bool) (make-array bool vars)]
    [roots : (Array i64) (make-array i64 vars)]
    [starts : (Array i64) (make-array i64 vars)]
    [ends : (Array i64) (make-array i64 vars)]
    [max-start : i64 9223372036854775807]
    [cleared : unit
      (let
        [i : i64 0]
        (while (< i vars)
          (begin
            (array-set! range-of-var i (- 0 1))
            (array-set! range-base i (- 0 1))
            (array-set! range-size i 0)
            (array-set! range-starts i max-start)
            (array-set! range-ends i (- 0 1))
            (array-set! invalid i false)
            (array-set! roots i (- 0 1))
            (array-set! starts i (- 0 1))
            (array-set! ends i (- 0 1))
            (set! i (+ i 1)))))]
    [range-count : i64
      (compiler-reg-color-detect-storage-blocks
        blocks
        range-of-var
        range-base
        range-size
        0)]
    (begin
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
            from))))))

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
    [present : (Array i64) (make-array i64 vars)]
    [items : (Array AstType) (make-array AstType vars)]
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
                  (if (and (>= new-id 0) (< new-id (array-length present)))
                    (begin
                      (array-set! present new-id 1)
                      (array-set! items new-id location))
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
      (if (= (array-ref present index) 0)
        acc
        (compiler-reg-assignment-cons
          (CompilerRegAssignment index (array-ref items index))
          acc)))))

(define (compiler-reg-color-rebuild-assignments
  [remap : (Array i64)]
  [vars : i64]
  [assignments : CompilerRegAssignmentList]) : CompilerRegAssignmentList
  (let
    [present : (Array i64) (make-array i64 vars)]
    [items : (Array CompilerRegLocation) (make-array CompilerRegLocation vars)]
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
            (if (< var-id (array-length remap))
              (begin
                (array-set! remap var-id var-id)
                (array-set! slot-ends var-id 9223372036854775807))
              unit)
            (compiler-reg-color-param-pins
              (box-get rest)
              remap
              slot-ends
              (compiler-reg-max highest (+ var-id 1))))])]))

;; Total frame renumbering: colorable stack scalars are assigned fresh dense
;; slots first, colorable inline-storage ranges are shared above that scalar
;; prefix, every remaining slot-resident variable gets a private dense slot
;; above them, and register-homed variables move to ids that are not used by a
;; stack slot. The assignment table is rebuilt on the new keys.
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
          [slot-ends : (Array i64) (make-array i64 slots)]
          [assignments : CompilerRegAssignmentList
            (compiler-reg-plan-assignments plan)]
          [assignment-index : CompilerRegAssignmentIndex
            (compiler-reg-assignment-index-build assignments vars)]
          [ineligible : CompilerLiveI64Set (compiler-reg-plan-ineligible plan)]
          [colorable : (Array bool) (make-array bool vars)]
          [remap : (Array i64) (make-array i64 vars)]
          [cleared : unit
            (let
              [i : i64 0]
              (begin
                (while (< i slots)
                  (begin
                    (array-set! slot-ends i (- 0 1))
                    (set! i (+ i 1))))
                (set! i 0)
                (while (< i vars)
                  (begin
                    (array-set! colorable i false)
                    (array-set! remap i (- 0 1))
                    (set! i (+ i 1))))))]
          [flagged : unit
            (compiler-reg-color-flags (compiler-reg-plan-types plan) colorable)]
          [param-floor : i64
            (compiler-reg-color-param-pins params remap slot-ends 0)]
          [sorted : (Array CompilerRegInterval)
            (compiler-reg-color-sorted-array intervals)]
          [stack-prefix : i64
            (compiler-reg-color-walk
              sorted
              (array-length sorted)
              0
              assignment-index
              group-vars
              ineligible
              colorable
              slot-ends
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
                    (if (>= (array-ref remap i) 0)
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
                                  (array-set! remap i slot)
                                  (set! next (+ slot 1))))]
                            [_ unit])]
                        [(CompilerRegNoLocation)
                          (let
                            [slot : i64
                              (compiler-reg-color-next-free-slot slot-ends next)]
                            (begin
                              (array-set! remap i slot)
                              (set! next (+ slot 1))))]))
                    (set! i (+ i 1))))
                next))]
          [renumbered
            : unit
            ;; Register-homed and unmentioned variables take the remaining FREE
            ;; ids of [0, vars), in var order (deterministic). Filling gaps
            ;; keeps the renumbering a bijection into [0, vars): an id at or
            ;; past vars would be silently dropped by the raw-var-sized rebuild
            ;; arrays and side tables. A register-homed variable never touches
            ;; its formula slot, so a free id below the watermark is safe.
            (let
              [taken : (Array bool) (make-array bool vars)]
              [i : i64 0]
              [free : i64 0]
              (begin
                (while (< i vars)
                  (begin
                    (array-set! taken i false)
                    (set! i (+ i 1))))
                (set! i 0)
                (while (< i vars)
                  (begin
                    (if (and
                      (>= (array-ref remap i) 0)
                      (< (array-ref remap i) vars))
                      (array-set! taken (array-ref remap i) true)
                      unit)
                    (set! i (+ i 1))))
                (set! i 0)
                (while (< i vars)
                  (begin
                    (if (< (array-ref remap i) 0)
                      (begin
                        (while (if (< free vars)
                          (array-ref taken free)
                          false)
                          (set! free (+ free 1)))
                        (array-set! remap i free)
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
  (if (and (>= id 0) (< id (array-length remap)))
    (array-ref remap id)
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
        [count : i64 (array-length items)]
        [out : (Array CompilerIrValue) (make-array CompilerIrValue count)]
        [i : i64 0]
        (begin
          (while (< i count)
            (begin
              (array-set!
                out
                i
                (compiler-reg-remap-value remap (array-ref items i)))
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
    [(IrInstrVectorBinOp dst op lhs rhs lanes ty)
      (IrInstrVectorBinOp
        (compiler-reg-remap-id remap dst)
        op
        (compiler-reg-remap-value remap lhs)
        (compiler-reg-remap-value remap rhs)
        lanes
        ty)]
    [(IrInstrVectorReduce dst op src lanes ty)
      (IrInstrVectorReduce
        (compiler-reg-remap-id remap dst)
        op
        (compiler-reg-remap-value remap src)
        lanes
        ty)]
    [(IrInstrVectorCompare dst op lhs rhs lanes ty)
      (IrInstrVectorCompare
        (compiler-reg-remap-id remap dst)
        op
        (compiler-reg-remap-value remap lhs)
        (compiler-reg-remap-value remap rhs)
        lanes
        ty)]
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
    [(IrInstrSelect dst mask true-value false-value lanes ty)
      (IrInstrSelect
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap mask)
        (compiler-reg-remap-value remap true-value)
        (compiler-reg-remap-value remap false-value)
        lanes
        ty)]
    [(IrInstrVectorLoad dst base index lanes ty)
      (IrInstrVectorLoad
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap base)
        (compiler-reg-remap-value remap index)
        lanes
        ty)]
    [(IrInstrVectorStore base index value lanes ty)
      (IrInstrVectorStore
        (compiler-reg-remap-value remap base)
        (compiler-reg-remap-value remap index)
        (compiler-reg-remap-value remap value)
        lanes
        ty)]
    [(IrInstrPredicatedStore base index value mask lanes ty)
      (IrInstrPredicatedStore
        (compiler-reg-remap-value remap base)
        (compiler-reg-remap-value remap index)
        (compiler-reg-remap-value remap value)
        (compiler-reg-remap-value remap mask)
        lanes
        ty)]
    [(IrInstrPredicatedLoad dst base index mask lanes ty)
      (IrInstrPredicatedLoad
        (compiler-reg-remap-id remap dst)
        (compiler-reg-remap-value remap base)
        (compiler-reg-remap-value remap index)
        (compiler-reg-remap-value remap mask)
        lanes
        ty)]
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
        ty)]))

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
        [(CompilerRegRegisterPair a b) (or (string-eq a reg) (string-eq b reg))]
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
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 0)
          "%r12")
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 1)
          "%r12"))]))

(define (compiler-reg-f64-reuse-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-f64-reuse-function))
    [(CompilerRegPlan assignments _ _ _)
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
    [(CompilerRegPlan assignments _ _ _)
      ;; Seven simultaneously live values against a five-register callee-saved
      ;; pool: the first five take %r12..%r15 and %rbx, and the remaining two
      ;; spill. %rbx joined the pool once its hard-scratch role moved to %r8.
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
    [(CompilerRegPlan assignments _ _ _)
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
    [(CompilerRegPlan assignments ineligible _ _)
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
    [(CompilerRegPlan assignments ineligible _ _)
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
    [(CompilerRegPlan assignments ineligible _ _)
      (and
        (compiler-live-set-contains? ineligible 0)
        (compiler-reg-unassigned? assignments 0))]))

(define (compiler-reg-f64-call-live-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-f64-call-live-function))
    [(CompilerRegPlan assignments ineligible _ _)
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
    [(CompilerRegPlan assignments ineligible _ _)
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
    [(CompilerRegPlan assignments ineligible _ _)
      (and
        (compiler-live-set-contains? ineligible 0)
        (compiler-reg-unassigned? assignments 0)
        (compiler-reg-location-register?
          (compiler-reg-assignment-lookup assignments 2)
          "%xmm2"))]))

(define (compiler-reg-ineligible-ok?) : bool
  (match (compiler-reg-plan-function (compiler-reg-ineligible-function))
    [(CompilerRegPlan assignments ineligible _ _)
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

;; Scalar plan (#perf): String/DynArray handles (vars 2/4) and AddrOf results
;; (var 6) are register-eligible 8-byte values; params (var 0) and
;; address-taken values (var 3 via the AddrOf) stay ineligible.
(define (compiler-reg-scalar-handle-eligible-ok?) : bool
  (match (compiler-reg-plan-function-scalar (compiler-reg-ineligible-function))
    [(CompilerRegPlan _ ineligible _ _)
      (and
        (compiler-live-set-contains? ineligible 0)
        (compiler-live-set-contains? ineligible 3)
        (not (compiler-live-set-contains? ineligible 2))
        (not (compiler-live-set-contains? ineligible 4))
        (not (compiler-live-set-contains? ineligible 6)))]))

(define (compiler-reg-scalar-function-intervals-ok?) : bool
  (match (compiler-reg-plan-function-scalar
    (compiler-reg-param-livein-gap-function))
    [(CompilerRegPlan _ _ intervals _)
      (compiler-reg-interval-range? intervals 0 1 4)]))

(define (compiler-reg-scalar-interval-guardrail-ok?) : bool
  (match (compiler-reg-plan-function-scalar
    (compiler-reg-single-block-livein-gap-function))
    [(CompilerRegPlan _ _ intervals _)
      (compiler-reg-interval-range? intervals 0 0 2)]))

(define (compiler-reg-scalar-loop-backedge-ok?) : bool
  (match (compiler-reg-plan-function-scalar
    (compiler-reg-loop-backedge-function))
    [(CompilerRegPlan assignments _ _ _)
      (and
        (compiler-reg-location-any-register?
          (compiler-reg-assignment-lookup assignments 1))
        (compiler-reg-location-any-register?
          (compiler-reg-assignment-lookup assignments 2))
        (compiler-reg-different-location? assignments 1 2))]))

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
    (and
      assignment-hit-ok
      assignment-miss-ok
      assignment-oob-ok
      interval-hit-ok
      interval-miss-ok
      interval-first-ok
      interference-ok
      conflict-ok)))

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
                        (compiler-reg-same-location? chain-assignments 1 2)
                        (compiler-reg-same-location? phi-assignments 0 1)
                        (compiler-reg-different-location? loop-assignments 1 2)
                        (compiler-reg-different-location?
                          blocked-assignments
                          0
                          1)
                        (compiler-reg-same-location? spill-assignments 4 5))])])])])]))

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
                (compiler-reg-location-register?
                  (compiler-reg-assignment-lookup vector-assignments 1)
                  "%vec7")
                (compiler-reg-location-register?
                  (compiler-reg-assignment-lookup vector-assignments 2)
                  "%vec7")
                (compiler-reg-location-register?
                  (compiler-reg-assignment-lookup vector-assignments 3)
                  "%vec6"))]
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
      (not (compiler-reg-string-list-contains? sysv-callees "%rdi"))
      (compiler-reg-string-list-contains? win-callees "%rdi")
      (not (compiler-reg-string-list-contains? win-callers "%rdi"))
      (not
        (=
          (compiler-reg-string-list-count (compiler-reg-sysv-integer-registers))
          (compiler-reg-string-list-count win-callees)))
      ;; The allocatable pool admits only callee-saved registers, so a
      ;; value homed there survives an intervening call. It must never
      ;; offer a caller-saved register such as %r8/%r9.
      (compiler-reg-string-list-contains?
        (compiler-reg-sysv-integer-registers)
        "%r12")
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

(define (compiler-reg-color-storage-ranges-ok?) : bool
  (match (compiler-reg-color-storage-function)
    [(IrFunction _ params _ vars blocks)
      (match (compiler-reg-color-stack-slots
        (CompilerRegPlan
          (compiler-reg-color-pointer-assignments)
          (compiler-live-set-empty)
          (compiler-reg-color-pointer-intervals)
          (compiler-reg-color-pointer-types))
        (compiler-live-set-empty)
        params
        blocks
        vars)
        [(CompilerRegColoringRemap remap slots)
          (and
            (= slots 2)
            (= (array-ref remap 0) 0)
            (= (array-ref remap 1) 1)
            (= (array-ref remap 3) 0)
            (= (array-ref remap 4) 1))]
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
            CompilerRegVarTypeNil))
        (compiler-live-set1 group-var)
        IrParamNil
        IrBlockNil
        (+ group-var 1))]
    (match coloring
      [(CompilerRegColoringRemap remap slots)
        (and
          (= slots 1)
          (= (array-ref remap group-var) 0)
          (<= (+ (array-ref remap group-var) 1) slots))]
      [(CompilerRegColoringNone) false])))

(define (compiler-regalloc-self-test) : i64
  (if (and
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
    (compiler-reg-scalar-call-live-ok?)
    (compiler-reg-scalar-f64-call-live-ok?)
    (compiler-reg-scalar-handle-eligible-ok?)
    (compiler-reg-scalar-function-intervals-ok?)
    (compiler-reg-scalar-interval-guardrail-ok?)
    (compiler-reg-scalar-loop-backedge-ok?)
    (compiler-reg-indexed-lookups-ok?)
    (compiler-reg-color-stack-group-ok?)
    (compiler-reg-color-storage-ranges-ok?))
    42
    (begin
      (panic "regalloc: smoke mismatch")
      0)))