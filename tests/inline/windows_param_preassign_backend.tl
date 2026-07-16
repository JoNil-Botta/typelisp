;; windows_param_preassign_backend.tl - backend smoke for #3493's Win64
;; incoming scalar parameter homes.
(import stdlib.io)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)

;; Retained for #2454 path-import compatibility: compiler_backend.tl is raw
;; source without a resolvable top-level module name.
(import "../../src/compiler_backend.tl")

(define (win-param-preassign-assert-true [condition : bool] [message : String]) : unit
  (if condition
    unit
    (io.panic message)))

(define (win-param-preassign-logical-name [name : String]) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (ci.intern-generated-name name)))

(define (win-param-preassign-globals
  [pa : i64]
  [pb : i64]
  [pc : i64]
  [pd : i64]) : CompilerIrGlobalList
  (compiler-ir-global-cons
    (CompilerIrGlobal.Global pa (AstType.I64) (CompilerIrValue.I64 0))
    (compiler-ir-global-cons
      (CompilerIrGlobal.Global pb (AstType.I64) (CompilerIrValue.I64 0))
      (compiler-ir-global-cons
        (CompilerIrGlobal.Global pc (AstType.I64) (CompilerIrValue.I64 0))
        (compiler-ir-global-cons
          (CompilerIrGlobal.Global pd (AstType.I64) (CompilerIrValue.I64 0))
          CompilerIrGlobalList.Nil)))))

(define (win-param-preassign-function
  [function-name : i64]
  [pa : i64]
  [pb : i64]
  [pc : i64]
  [pd : i64]) : CompilerIrFunction
  (CompilerIrFunction.Function
    function-name
    (compiler-ir-param-cons
      (CompilerIrParam.Param "a" (AstType.I64) 0)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "b" (AstType.I64) 1)
        (compiler-ir-param-cons
          (CompilerIrParam.Param "c" (AstType.I64) 2)
          (compiler-ir-param-cons
            (CompilerIrParam.Param "d" (AstType.I64) 3)
            CompilerIrParamList.Nil))))
    (AstType.Unit)
    4
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (CompilerIrInstr.Store pa (CompilerIrValue.Var 0) (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Store pb (CompilerIrValue.Var 1) (AstType.I64))
            (compiler-ir-instr-cons
              (CompilerIrInstr.Store pc (CompilerIrValue.Var 2) (AstType.I64))
              (compiler-ir-instr-cons
                (CompilerIrInstr.Store pd (CompilerIrValue.Var 3) (AstType.I64))
                (compiler-ir-instr-cons
                  (CompilerIrInstr.Return CompilerIrMaybeValue.No)
                  CompilerIrInstrList.Nil))))))
      CompilerIrBlockList.Nil)))

(define (win-param-preassign-program) : CompilerIrProgram
  (let
    [function-name : i64
      (win-param-preassign-logical-name "win_param_preassign")]
    [pa : i64 (win-param-preassign-logical-name "win_pa")]
    [pb : i64 (win-param-preassign-logical-name "win_pb")]
    [pc : i64 (win-param-preassign-logical-name "win_pc")]
    [pd : i64 (win-param-preassign-logical-name "win_pd")]
    (CompilerIrProgram.Program
      (win-param-preassign-globals pa pb pc pd)
      (compiler-ir-function-cons
        (win-param-preassign-function function-name pa pb pc pd)
        CompilerIrFunctionList.Nil)
      CompilerIrExternList.Nil)))

(define (win-param-preassign-safe-div-function) : CompilerIrFunction
  (CompilerIrFunction.Function
    (win-param-preassign-logical-name "win_param_safe_div")
    (compiler-ir-param-cons
      (CompilerIrParam.Param "a" (AstType.I64) 0)
      (compiler-ir-param-cons
        (CompilerIrParam.Param "b" (AstType.I64) 1)
        CompilerIrParamList.Nil))
    (AstType.I64)
    3
    (compiler-ir-block-cons
      (compiler-ir-block
        "entry"
        (compiler-ir-instr-cons
          (CompilerIrInstr.BinOp
            2
            CompilerIrBinOp.SafeDiv
            (CompilerIrValue.I64 8)
            (CompilerIrValue.I64 2)
            (AstType.I64))
          (compiler-ir-instr-cons
            (CompilerIrInstr.Return
              (CompilerIrMaybeValue.Some (CompilerIrValue.Var 1)))
            CompilerIrInstrList.Nil)))
      CompilerIrBlockList.Nil)))

(define (win-param-preassign-safe-div-regalloc-ok?) : bool
  ;; The incoming Win64 home of param b (var 1) is %rdx (arg1), which the safe
  ;; div clobbers (idiv writes %rdx:%rax), so b cannot keep its arg-register
  ;; home across the div. Pre-campaign the allocator forced it to the stack
  ;; (ineligible + unassigned). The M-A campaign made params greedy candidates,
  ;; so b is now register-homed in a CALLEE-SAVED register that survives the
  ;; clobber instead of being stack-homed -- the same soundness property (b is
  ;; not left in a div-clobbered register) with a better home.
  (match (compiler-reg-plan-function-scalar-for-abi
    CompilerRegTargetAbi.Windows
    (win-param-preassign-safe-div-function))
    [(CompilerRegPlan.Plan assignments ineligible _ _ _ _)
      (and
        (not (compiler-live-set-contains? ineligible 1))
        (match (compiler-reg-assignment-lookup assignments 1)
          [(CompilerRegMaybeLocation.Some location)
            (match location
              [(CompilerRegLocation.Register r)
                (compiler-reg-string-list-contains?
                  (compiler-reg-win64-callee-saved-integer-registers)
                  r)]
              [_ false])]
          [(CompilerRegMaybeLocation.No) false]))]))

(define (win-param-preassign-backend-ok?) : bool
  (begin
    (compiler-backend-set-scalar-registers! true)
    (match (compiler-backend-emit-program-target-with-mode
      (win-param-preassign-program)
      (CompilerBackendTarget.Windows)
      (CompilerBackendMode.Scalar)
      (compiler-source-spans-empty)
      false)
      [(ResultCompilerBackend.Ok asm)
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
      [(ResultCompilerBackend.Err _)
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