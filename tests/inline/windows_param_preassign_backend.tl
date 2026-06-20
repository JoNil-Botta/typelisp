;; windows_param_preassign_backend.tl - backend smoke for #3493's Win64
;; incoming scalar parameter homes.
(import "../../src/compiler_backend.tl")

(define (win-param-preassign-assert-true [condition : bool] [message : String]) : unit
  (if condition
    unit
    (panic message)))

(define (win-param-preassign-globals) : CompilerIrGlobalList
  (compiler-ir-global-cons
    (IrGlobal "win_pa" (AstTyI64) (IrValueI64 0))
    (compiler-ir-global-cons
      (IrGlobal "win_pb" (AstTyI64) (IrValueI64 0))
      (compiler-ir-global-cons
        (IrGlobal "win_pc" (AstTyI64) (IrValueI64 0))
        (compiler-ir-global-cons
          (IrGlobal "win_pd" (AstTyI64) (IrValueI64 0))
          IrGlobalNil)))))

(define (win-param-preassign-function) : CompilerIrFunction
  (IrFunction
    "win_param_preassign"
    (compiler-ir-param-cons
      (IrParam "a" (AstTyI64) 0)
      (compiler-ir-param-cons
        (IrParam "b" (AstTyI64) 1)
        (compiler-ir-param-cons
          (IrParam "c" (AstTyI64) 2)
          (compiler-ir-param-cons (IrParam "d" (AstTyI64) 3) IrParamNil))))
    (AstTyUnit)
    4
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrStore "win_pa" (IrValueVar 0) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrStore "win_pb" (IrValueVar 1) (AstTyI64))
            (compiler-ir-instr-cons
              (IrInstrStore "win_pc" (IrValueVar 2) (AstTyI64))
              (compiler-ir-instr-cons
                (IrInstrStore "win_pd" (IrValueVar 3) (AstTyI64))
                (compiler-ir-instr-cons (IrInstrReturn IrNoValue) IrInstrNil))))))
      IrBlockNil)))

(define (win-param-preassign-program) : CompilerIrProgram
  (IrProgram
    (win-param-preassign-globals)
    (compiler-ir-function-cons (win-param-preassign-function) IrFunctionNil)
    IrExternNil))

(define (win-param-preassign-safe-div-function) : CompilerIrFunction
  (IrFunction
    "win_param_safe_div"
    (compiler-ir-param-cons
      (IrParam "a" (AstTyI64) 0)
      (compiler-ir-param-cons (IrParam "b" (AstTyI64) 1) IrParamNil))
    (AstTyI64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (IrInstrBinOp 2 IrBinSafeDiv (IrValueI64 8) (IrValueI64 2) (AstTyI64))
          (compiler-ir-instr-cons
            (IrInstrReturn (IrSomeValue (IrValueVar 1)))
            IrInstrNil)))
      IrBlockNil)))

(define (win-param-preassign-safe-div-regalloc-ok?) : bool
  (match (compiler-reg-plan-function-scalar-for-abi
    CompilerRegAbiWindows
    (win-param-preassign-safe-div-function))
    [(CompilerRegPlan assignments ineligible _ _ _)
      (and
        (compiler-live-set-contains? ineligible 1)
        (compiler-reg-unassigned? assignments 1))]))

(define (win-param-preassign-backend-ok?) : bool
  (begin
    (compiler-backend-set-scalar-registers! true)
    (match (compiler-backend-emit-program-target-with-mode
      (win-param-preassign-program)
      (BackendTargetWindows)
      (BackendModeScalar)
      (compiler-source-spans-empty)
      false)
      [(OkCompilerBackend asm)
        (let
          [ok : bool
            (and
              (compiler-backend-string-contains?
                asm
                "#t _tl_f0 _tl_win_param_preassign\n")
              (compiler-backend-string-contains? asm "_tl_f0:\n")
              (not
                (compiler-backend-string-contains?
                  asm
                  "    movq %rcx, -8(%rbp)\n"))
              (not
                (compiler-backend-string-contains?
                  asm
                  "    movq %rdx, -16(%rbp)\n"))
              (compiler-backend-string-contains?
                asm
                "    movq %r8, -24(%rbp)\n")
              (not
                (compiler-backend-string-contains?
                  asm
                  "    movq %r9, -32(%rbp)\n")))]
          (begin
            (compiler-backend-set-scalar-registers! false)
            ok))]
      [(ErrCompilerBackend _)
        (begin
          (compiler-backend-set-scalar-registers! false)
          false)])))

(test
  windows-param-preassign-backend
  (win-param-preassign-assert-true
    (win-param-preassign-backend-ok?)
    "Windows scalar param preassignment should keep rcx/rdx/r9 homes and spill r8"))

(test
  windows-param-preassign-safe-div-regalloc
  (win-param-preassign-assert-true
    (win-param-preassign-safe-div-regalloc-ok?)
    "Windows rdx parameter home should be blocked across safe div/mod clobbers"))