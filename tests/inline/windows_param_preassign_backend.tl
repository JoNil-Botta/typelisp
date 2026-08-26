;; windows_param_preassign_backend.tl - backend smoke for #3493's Win64
;; incoming scalar parameter homes.
(import stdlib.io)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_backend)
(import compiler_profile_state as profile_state)
(import compiler_abi as abi)
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import compiler_regalloc as regalloc)
(import compiler_liveness as liveness)

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
  [pd : i64]) : ir.CompilerIrGlobalSeq
  (let
    [builder : ir.CompilerIrGlobalBuilder
      (ir.compiler-ir-global-builder-with-capacity 4)]
    (begin
      (ir.compiler-ir-global-builder-push!
        (&mut builder)
        (ir.CompilerIrGlobal.Global
          pa
          (ast.AstType.I64)
          (ir.CompilerIrValue.I64 0)))
      (ir.compiler-ir-global-builder-push!
        (&mut builder)
        (ir.CompilerIrGlobal.Global
          pb
          (ast.AstType.I64)
          (ir.CompilerIrValue.I64 0)))
      (ir.compiler-ir-global-builder-push!
        (&mut builder)
        (ir.CompilerIrGlobal.Global
          pc
          (ast.AstType.I64)
          (ir.CompilerIrValue.I64 0)))
      (ir.compiler-ir-global-builder-push!
        (&mut builder)
        (ir.CompilerIrGlobal.Global
          pd
          (ast.AstType.I64)
          (ir.CompilerIrValue.I64 0)))
      (ir.compiler-ir-global-builder-to-seq builder))))

(define (win-param-preassign-function
  [function-name : i64]
  [pa : i64]
  [pb : i64]
  [pc : i64]
  [pd : i64]) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    function-name
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "a" (ast.AstType.I64) 0)
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "b" (ast.AstType.I64) 1)
        (ir.compiler-ir-param-cons
          (ir.CompilerIrParam.Param "c" (ast.AstType.I64) 2)
          (ir.compiler-ir-param-cons
            (ir.CompilerIrParam.Param "d" (ast.AstType.I64) 3)
            ir.CompilerIrParamList.Nil))))
    (ast.AstType.Unit)
    4
    (ir.compiler-ir-block-cons
      (ir.compiler-ir-block
        (ir.compiler-ir-label "entry")
        (ir.compiler-ir-instr-seq5
          (ir.CompilerIrInstr.Store
            pa
            (ir.CompilerIrValue.Var 0)
            (ast.AstType.I64))
          (ir.CompilerIrInstr.Store
            pb
            (ir.CompilerIrValue.Var 1)
            (ast.AstType.I64))
          (ir.CompilerIrInstr.Store
            pc
            (ir.CompilerIrValue.Var 2)
            (ast.AstType.I64))
          (ir.CompilerIrInstr.Store
            pd
            (ir.CompilerIrValue.Var 3)
            (ast.AstType.I64))
          (ir.CompilerIrInstr.Return ir.CompilerIrMaybeValue.No)))
      ir.CompilerIrBlockList.Nil)))

(define (win-param-preassign-program) : ir.CompilerIrProgram
  (let
    [function-name : i64
      (win-param-preassign-logical-name "win_param_preassign")]
    [pa : i64 (win-param-preassign-logical-name "win_pa")]
    [pb : i64 (win-param-preassign-logical-name "win_pb")]
    [pc : i64 (win-param-preassign-logical-name "win_pc")]
    [pd : i64 (win-param-preassign-logical-name "win_pd")]
    (ir.CompilerIrProgram.Program
      (win-param-preassign-globals pa pb pc pd)
      (ir.compiler-ir-function-seq-prepend
        (win-param-preassign-function function-name pa pb pc pd)
        (ir.compiler-ir-function-seq-empty))
      (ir.compiler-ir-extern-seq-empty))))

(define (win-param-preassign-safe-div-function) : ir.CompilerIrFunction
  (ir.CompilerIrFunction.Function
    (win-param-preassign-logical-name "win_param_safe_div")
    (ir.compiler-ir-param-cons
      (ir.CompilerIrParam.Param "a" (ast.AstType.I64) 0)
      (ir.compiler-ir-param-cons
        (ir.CompilerIrParam.Param "b" (ast.AstType.I64) 1)
        ir.CompilerIrParamList.Nil))
    (ast.AstType.I64)
    3
    (ir.compiler-ir-block-cons
      (ir.compiler-ir-block
        (ir.compiler-ir-label "entry")
        (ir.compiler-ir-instr-seq2
          (ir.CompilerIrInstr.BinOp
            2
            ir.CompilerIrBinOp.SafeDiv
            (ir.CompilerIrValue.I64 8)
            (ir.CompilerIrValue.I64 2)
            (ast.AstType.I64))
          (ir.CompilerIrInstr.Return
            (ir.CompilerIrMaybeValue.Some (ir.CompilerIrValue.Var 1)))))
      ir.CompilerIrBlockList.Nil)))

(define (win-param-preassign-safe-div-regalloc-ok?) : bool
  ;; The incoming Win64 home of param b (var 1) is %rdx (arg1), which the safe
  ;; div clobbers (idiv writes %rdx:%rax), so b cannot keep its arg-register
  ;; home across the div. Pre-campaign the allocator forced it to the stack
  ;; (ineligible + unassigned). The M-A campaign made params greedy candidates,
  ;; so b is now register-homed in a CALLEE-SAVED register that survives the
  ;; clobber instead of being stack-homed -- the same soundness property (b is
  ;; not left in a div-clobbered register) with a better home.
  (match (regalloc.compiler-reg-plan-function-scalar-for-abi
    abi.CompilerRegTargetAbi.Windows
    (win-param-preassign-safe-div-function))
    [(regalloc.CompilerRegPlan.Plan assignments ineligible _ _ _ _)
      (and
        (not (liveness.compiler-live-set-contains? ineligible 1))
        (match (regalloc.compiler-reg-assignment-lookup assignments 1)
          [(regalloc.CompilerRegMaybeLocation.Some location)
            (match location
              [(regalloc.CompilerRegLocation.Register r)
                (regalloc.compiler-reg-id-seq-contains?
                  (regalloc.compiler-reg-win64-callee-saved-integer-registers)
                  r)]
              [_ false])]
          [(regalloc.CompilerRegMaybeLocation.No) false]))]))

(define (win-param-preassign-backend-ok?) : bool
  (let
    [program : ir.CompilerIrProgram (win-param-preassign-program)]
    [backend-state : compiler_backend.CompilerBackendState
      (compiler_backend.compiler-backend-state-new
        (ci.intern-compat-state-capture-active))]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [profile-state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    [_scalar : unit
      (compiler_backend.compiler-backend-state-set-scalar-registers-enabled!
        backend-state
        true)]
    (match (compiler_backend.compiler-backend-emit-program-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
      backend-state
      pools
      program
      (compiler_backend.CompilerBackendTarget.Windows)
      (compiler_backend.CompilerBackendMode.Scalar)
      (ir.compiler-source-spans-empty)
      false
      false
      profile-state)
      [(compiler_backend.ResultCompilerBackend.Ok asm)
        (and
          (compiler_backend.compiler-backend-string-contains?
            asm
            "#t _tl_f0 _tl_win_param_preassign\n")
          (compiler_backend.compiler-backend-string-contains? asm "_tl_f0:\n")
          ;; Params a/b/d keep their incoming Win64 arg-register homes
          ;; (%rcx/%rdx/%r9) and are stored to their globals directly --
          ;; no stack spill.
          (compiler_backend.compiler-backend-string-contains?
            asm
            "    movq %rcx, _tl_win_pa(%rip)\n")
          (compiler_backend.compiler-backend-string-contains?
            asm
            "    movq %rdx, _tl_win_pb(%rip)\n")
          (compiler_backend.compiler-backend-string-contains?
            asm
            "    movq %r9, _tl_win_pd(%rip)\n")
          ;; Param c arrives in %r8, which doubles as the backend's fixed
          ;; emit scratch register, so it cannot stay there: it is
          ;; relocated to a callee-saved register (%r12) and stored from
          ;; there -- NOT stacked, and never stored directly out of %r8.
          (compiler_backend.compiler-backend-string-contains?
            asm
            "    movq %r8, %r12\n")
          (compiler_backend.compiler-backend-string-contains?
            asm
            "    movq %r12, _tl_win_pc(%rip)\n")
          (not
            (compiler_backend.compiler-backend-string-contains?
              asm
              "    movq %r8, _tl_win_pc(%rip)\n")))]
      [(compiler_backend.ResultCompilerBackend.Err _) false])))

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