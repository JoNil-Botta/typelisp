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
    (ir.compiler-ir-param-seq-prepend
      (ir.CompilerIrParam.Param "a" (ast.AstType.I64) 0)
      (ir.compiler-ir-param-seq-prepend
        (ir.CompilerIrParam.Param "b" (ast.AstType.I64) 1)
        (ir.compiler-ir-param-seq-prepend
          (ir.CompilerIrParam.Param "c" (ast.AstType.I64) 2)
          (ir.compiler-ir-param-seq-prepend
            (ir.CompilerIrParam.Param "d" (ast.AstType.I64) 3)
            (ir.compiler-ir-param-seq-empty)))))
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
    (ir.compiler-ir-param-seq-prepend
      (ir.CompilerIrParam.Param "a" (ast.AstType.I64) 0)
      (ir.compiler-ir-param-seq-prepend
        (ir.CompilerIrParam.Param "b" (ast.AstType.I64) 1)
        (ir.compiler-ir-param-seq-empty)))
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
  ;; so b is register-homed instead of stack-homed.
  ;; R3S-1: the home is no longer forced CALLEE-SAVED. b is the LAST parameter,
  ;; so no entry copy is emitted after its own and its home carries no schedule
  ;; constraint; it spans no call; and the div narrowing forbids exactly the
  ;; idiv pair {%rax,%rdx}. The soundness property asserted here is that pair --
  ;; b must not be left in a div-clobbered register -- and the concrete pick is
  ;; pinned as %rcx, in a function that now pushes no callee-saved register at
  ;; all. %rcx is param a's INCOMING argument register, and taking it is sound
  ;; for exactly the reason the schedule constraint encodes: a sits at an
  ;; EARLIER position, so its entry copy has already been emitted by the time
  ;; b's runs and there is nothing left in %rcx to destroy. The old
  ;; `is-param -> csr-only` rule could not express that and paid a
  ;; callee-saved push/pop for it.
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
                (and
                  (not (= r abi.compiler-reg-id-rax))
                  (not (= r abi.compiler-reg-id-rdx))
                  (= r abi.compiler-reg-id-rcx))]
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
            (compiler_backend.compiler-backend-global-shared-view asm)
            "#t _tl_f0 _tl_win_param_preassign\n")
          (compiler_backend.compiler-backend-string-contains?
            (compiler_backend.compiler-backend-global-shared-view asm)
            "_tl_f0:\n")
          ;; Params a/b/d keep their incoming Win64 arg-register homes
          ;; (%rcx/%rdx/%r9) and are stored to their globals directly --
          ;; no stack spill.
          (compiler_backend.compiler-backend-string-contains?
            (compiler_backend.compiler-backend-global-shared-view asm)
            "    movq %rcx, _tl_win_pa(%rip)\n")
          (compiler_backend.compiler-backend-string-contains?
            (compiler_backend.compiler-backend-global-shared-view asm)
            "    movq %rdx, _tl_win_pb(%rip)\n")
          (compiler_backend.compiler-backend-string-contains?
            (compiler_backend.compiler-backend-global-shared-view asm)
            "    movq %r9, _tl_win_pd(%rip)\n")
          ;; Param c arrives in %r8, which doubles as the backend's fixed
          ;; emit scratch register, so it cannot stay there: it is
          ;; relocated and stored from the new home -- NOT stacked, and
          ;; never stored directly out of %r8.
          ;; R3S-1: the new home is the caller-saved %rax, not a callee-saved
          ;; register. c's entry copy is emitted before d's, so the ONE home
          ;; the schedule forbids it is d's incoming %r9; every other free
          ;; pool register is legal and %rax is the first. The function
          ;; contains no call, so it now pushes no callee-saved register.
          (compiler_backend.compiler-backend-string-contains?
            (compiler_backend.compiler-backend-global-shared-view asm)
            "    movq %r8, %rax\n")
          (compiler_backend.compiler-backend-string-contains?
            (compiler_backend.compiler-backend-global-shared-view asm)
            "    movq %rax, _tl_win_pc(%rip)\n")
          (not
            (compiler_backend.compiler-backend-string-contains?
              (compiler_backend.compiler-backend-global-shared-view asm)
              "    movq %r8, _tl_win_pc(%rip)\n"))
          ;; The entry-copy schedule constraint, directly: c's home may never
          ;; be the incoming argument register of a LATER parameter, because
          ;; d's entry copy has not run yet when c's is emitted.
          (not
            (compiler_backend.compiler-backend-string-contains?
              (compiler_backend.compiler-backend-global-shared-view asm)
              "    movq %r8, %r9\n"))
          (not
            (compiler_backend.compiler-backend-string-contains?
              (compiler_backend.compiler-backend-global-shared-view asm)
              "    pushq %r12\n")))]
      [(compiler_backend.ResultCompilerBackend.Err _) false])))

(test
  windows-param-preassign-backend
  (win-param-preassign-assert-true
    (win-param-preassign-backend-ok?)
    "Windows scalar param preassignment should keep rcx/rdx/r9 homes and relocate r8 to a caller-saved home that is not a later param's incoming register"))

(test
  windows-param-preassign-safe-div-regalloc
  (win-param-preassign-assert-true
    (win-param-preassign-safe-div-regalloc-ok?)
    "Windows rdx parameter home should be blocked across safe div/mod clobbers, relocating the param off the idiv pair"))