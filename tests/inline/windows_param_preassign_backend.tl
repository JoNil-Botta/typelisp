;; windows_param_preassign_backend.tl - backend smoke for #3493's Win64
;; incoming scalar parameter homes.
(import stdlib.io)
(import "../../src/compiler_backend.tl")

(define (win-param-preassign-assert-true [condition : bool] [message : String]) : unit
  (if condition
    unit
    (io.panic message)))

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
  ;; The incoming Win64 home of param b (var 1) is %rdx (arg1), which the safe
  ;; div clobbers (idiv writes %rdx:%rax), so b cannot keep its arg-register
  ;; home across the div. Pre-campaign the allocator forced it to the stack
  ;; (ineligible + unassigned). The M-A campaign made params greedy candidates,
  ;; so b is now register-homed in a CALLEE-SAVED register that survives the
  ;; clobber instead of being stack-homed -- the same soundness property (b is
  ;; not left in a div-clobbered register) with a better home.
  (match (compiler-reg-plan-function-scalar-for-abi
    CompilerRegAbiWindows
    (win-param-preassign-safe-div-function))
    [(CompilerRegPlan assignments ineligible _ _ _ _)
      (and
        (not (compiler-live-set-contains? ineligible 1))
        (match (compiler-reg-assignment-lookup assignments 1)
          [(CompilerRegSomeLocation location)
            (match location
              [(CompilerRegRegister r)
                (compiler-reg-string-list-contains?
                  (compiler-reg-win64-callee-saved-integer-registers)
                  r)]
              [_ false])]
          [(CompilerRegNoLocation) false]))]))

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
              ;; Params a/b/d keep their incoming Win64 arg-register homes
              ;; (%rcx/%rdx/%r9) and are stored to their globals directly --
              ;; no stack spill.
              (compiler-backend-string-contains?
                asm
                "    movq %rcx, _tl_win_pa(%rip)\n")
              (compiler-backend-string-contains?
                asm
                "    movq %rdx, _tl_win_pb(%rip)\n")
              (compiler-backend-string-contains?
                asm
                "    movq %r9, _tl_win_pd(%rip)\n")
              ;; Param c arrives in %r8, which doubles as the backend's fixed
              ;; emit scratch register, so it cannot stay there: it is
              ;; relocated to a callee-saved register (%r12) and stored from
              ;; there -- NOT stacked, and never stored directly out of %r8.
              (compiler-backend-string-contains? asm "    movq %r8, %r12\n")
              (compiler-backend-string-contains?
                asm
                "    movq %r12, _tl_win_pc(%rip)\n")
              (not
                (compiler-backend-string-contains?
                  asm
                  "    movq %r8, _tl_win_pc(%rip)\n")))]
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
    "Windows scalar param preassignment should keep rcx/rdx/r9 homes and relocate r8 to a callee-saved register"))

(test
  windows-param-preassign-safe-div-regalloc
  (win-param-preassign-assert-true
    (win-param-preassign-safe-div-regalloc-ok?)
    "Windows rdx parameter home should be blocked across safe div/mod clobbers, relocating the param to a callee-saved register"))