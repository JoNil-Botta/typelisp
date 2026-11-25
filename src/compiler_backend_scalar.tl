;; compiler_backend_scalar.tl - Scalar operand, frame-slot, copy and cast emission.
(import compiler_backend_div_magic as be_div)
(import compiler_backend_operands as be_operand)
(import compiler_backend_program_facts as be_facts)
(import compiler_backend_state as be_state)
(import stdlib.iterator)
(import stdlib.io)
(import compiler_ir_types)
(import compiler_ast_types)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic)
(import compiler_optimize)
(import compiler_abi)
(import compiler_regalloc)
(import compiler_liveness)
(import stdlib.text_buf)
(import compiler_machine_x64 as mx)
(import compiler_intern as ci)
(import stdlib.hashmap)
(import (hashmap.hashmap String i64) as backend_string_i64_map)

;; Block labels are interned ids, so their maps are integer-keyed.
(import (hashmap.hashmap i64 i64) as backend_label_i64_map)
(import stdlib.string)
(import compiler_str_cat as str_cat)
(import stdlib.option)
(import (option.option i64) as option_i64)
(import compiler_owned_view as owned_view)

(define (compiler-backend-plan-location-reg-mask
  [location : compiler_regalloc.CompilerRegLocation]) : i64
  (match location
    [(Register reg) (be_operand.compiler-backend-plan-reg-id-bit reg)]
    [(RegisterPair a b)
      (bit-or
        (be_operand.compiler-backend-plan-reg-id-bit a)
        (be_operand.compiler-backend-plan-reg-id-bit b))]
    [_ 0]))

(define (compiler-backend-plan-reg-mask-of
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [mask : i64]) : i64
  (let
    [present : (__tl_dyn-array i64)
      (compiler_regalloc.compiler-reg-assignment-table-present assignments)]
    [items : (__tl_dyn-array compiler_regalloc.CompilerRegLocation)
      (compiler_regalloc.compiler-reg-assignment-table-items assignments)]
    [index : i64 0]
    [out : i64 mask]
    (while (< index (array-length present))
      (if (= (array-ref present index) 0)
        unit
        (set!
          out
          (bit-or
            out
            (compiler-backend-plan-location-reg-mask
              (be_state.compiler-backend-global-array-element-shared-view
                items
                index)))))
      (set! index (+ index 1)))
    out))

;; `active` gates the fast path exactly as the dense operand view does, and it
;; has the same lifetime: installed from the final table alongside that view and
;; cleared with it in compiler-backend-clear-function-emit-state!. Clearing is
;; REQUIRED, not tidiness -- the backend self-test calls the callee-save helpers
;; directly with their own tables, and a mask left active from the previously
;; emitted function would answer for that function instead.
(define (compiler-backend-set-emit-plan-reg-mask!
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]) : unit
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    (be_state.compiler-backend-function-state-set-i64!
      function-state
      be_state.compiler-backend-function-i64-emit-plan-reg-mask
      (compiler-backend-plan-reg-mask-of assignments 0))
    (be_state.compiler-backend-function-state-set-bool!
      function-state
      be_state.compiler-backend-function-bool-emit-plan-reg-mask-active
      true)))

(define (compiler-backend-trace-csr-set-text
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [body-mask : i64]
  [saved? : bool]) : String
  (let
    [out : String ""]
    (for [idx (iterator.range 0 compiler-backend-callee-save-order-count)]
      (let
        [reg-id : i64
          (be_operand.compiler-backend-trace-csr-name-at backend-state idx)]
        (if (and
          (not (= reg-id compiler_abi.compiler-reg-id-invalid))
          (if saved?
            (be_operand.compiler-backend-callee-needs-save?
              backend-state
              assignments
              reg-id)
            (not
              (=
                (bit-and
                  body-mask
                  (be_operand.compiler-backend-plan-reg-id-bit reg-id))
                0))))
          (set!
            out
            (str_cat.str-cat
              out
              (if (string.eq out "")
                ""
                ",")
              (compiler_abi.compiler-abi-register-spelling reg-id)))
          unit)))
    out))

(define (compiler-backend-trace-csr-line!
  [backend-state : be_state.CompilerBackendState]
  [name : String]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [body-mask : i64]
  [pushes : i64]) : unit
  (io.print-error
    (str_cat.str-cat
      "regalloc-csr|"
      name
      "|saved="
      (compiler-backend-trace-csr-set-text
        backend-state
        assignments
        body-mask
        true)
      "|used="
      (compiler-backend-trace-csr-set-text
        backend-state
        assignments
        body-mask
        false)
      "|pushes="
      (string.int->string pushes)
      "\n")))

(define (compiler-backend-plan-body-reg-mask-var
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var : i64]
  [mask : i64]) : i64
  (if (< var 0)
    mask
    (match (compiler_regalloc.compiler-reg-assignment-table-lookup
      assignments
      var)
      [(Some location)
        (bit-or mask (compiler-backend-plan-location-reg-mask location))]
      [(No) mask])))

(define (compiler-backend-plan-body-reg-mask-set
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [set : compiler_liveness.CompilerLiveI64Set]
  [mask : i64]) : i64
  (let
    [words : i64 (compiler_liveness.compiler-live-set-word-count set)]
    [out : i64 mask]
    (for [word-index (iterator.range 0 words)]
      (let
        [bits : i64
          (compiler_liveness.compiler-live-set-word-at-bounded set word-index)]
        [base : i64
          (* word-index (compiler_liveness.compiler-live-set-word-bits))]
        (while (not (= bits 0))
          (set!
            out
            (compiler-backend-plan-body-reg-mask-var
              assignments
              (+ base (compiler_regalloc.compiler-reg-low-bit-index32 bits))
              out))
          (set! bits (bit-and bits (- bits 1))))))
    out))

(define (compiler-backend-plan-body-reg-mask-instr
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [instr : compiler_ir_types.CompilerIrInstr]
  [mask : i64]) : i64
  (let
    [ids : (__tl_dyn-array i64) (compiler_liveness.compiler-live-instr-ids)]
    [id-count : i64 (compiler_liveness.compiler-live-instr-use-ids! (& instr))]
    [out : i64 mask]
    (if (< id-count 0)
      (compiler-backend-plan-body-reg-mask-set
        assignments
        (compiler_liveness.compiler-live-instr-defs (& instr))
        (compiler-backend-plan-body-reg-mask-set
          assignments
          (compiler_liveness.compiler-live-instr-uses instr)
          out))
      (begin
        (for [index (iterator.range 0 id-count)]
          (set!
            out
            (compiler-backend-plan-body-reg-mask-var
              assignments
              (array-ref ids index)
              out)))
        (compiler-backend-plan-body-reg-mask-var
          assignments
          (compiler_ir_types.compiler-ir-instr-dst instr)
          out)))))

(define (compiler-backend-plan-body-reg-mask
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [params : compiler_ir_types.CompilerIrParamSeq]) : i64
  (let
    [seq : compiler_ir_types.CompilerIrBlockSeq
      (compiler_liveness.compiler-live-ir-block-list-to-seq (& blocks))]
    [count : i64 (compiler_ir_types.compiler-ir-block-seq-count seq)]
    [out : i64 0]
    (for [position (iterator.range 0 params.len)]
      (match (compiler_ir_types.compiler-ir-param-seq-borrow params position)
        [(Param _ _ var-id)
          (set!
            out
            (compiler-backend-plan-body-reg-mask-var assignments var-id out))]))
    (for [b (iterator.range 0 count)]
      (match (compiler_ir_types.compiler-ir-block-seq-borrow seq b)
        [(Block _ instrs)
          (let
            [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr)
              instrs.slots]
            [n : i64 instrs.len]
            (for [i (iterator.range 0 n)]
              (set!
                out
                (compiler-backend-plan-body-reg-mask-instr
                  assignments
                  (be_state.compiler-backend-global-array-element-shared-view
                    slots
                    i)
                  out))))]))
    out))

(define (compiler-backend-rbp-callee-save-slot-index
  [_backend-state : be_state.CompilerBackendState]) : i64
  5)

;; Reserve enough space for either group-home mode. Functions with exposed
;; group addresses need the canonical pair region, with word0 at base and
;; word1 at base+8; without exposed groups only word1 leaves the var region, in
;; the compact map. Both regions are dense: one word per group var in the
;; compact map, two per group var in the canonical pair region, indexed by the
;; dense per-function group rank rather than by the raw var id.
(define (compiler-backend-frame-slots-with-groups
  [vars : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [backend-state : be_state.CompilerBackendState]) : i64
  (+
    (be_operand.compiler-backend-frame-slots vars assignments backend-state)
    (compiler-backend-group-pair-reserve backend-state)))

;; Frame slots reserving the LARGEST possible callee-save area (all callee
;; regs). The emergency spill slot is placed pre-body from frame-slots, but
;; on-demand scavenge callee-save can grow the real (post-body) callee-save area
;; -- so the emergency slot must sit below the maximum area or it overlaps an
;; on-demand-saved register's slot. Used for the emergency slot offset, and for
;; the frame size when an emergency actually fires (so the slot is in-bounds).
(define (compiler-backend-frame-slots-emergency-max
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : i64
  (let
    [win64 : bool (be_state.compiler-backend-current-fn-win64? backend-state)]
    [base : i64
      (if win64
        (+ (be_operand.compiler-backend-round-up-even-slots (+ vars 6)) 20)
        (+ vars 6))]
    (+ base (compiler-backend-group-pair-reserve backend-state))))

(define (compiler-backend-callee-save-slot-offset [vars : i64] [idx : i64]) : i64
  (- 0 (* 8 (+ vars (+ idx 1)))))

(define (compiler-backend-callee-save-slot
  [vars : i64]
  [idx : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (compiler-backend-callee-save-frame-offset
    backend-state
    (compiler-backend-callee-save-slot-offset vars idx)))

(define (compiler-backend-win64-xmm-callee-slot-offset
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [idx : i64]) : i64
  (-
    0
    (*
      8
      (+
        (be_operand.compiler-backend-round-up-even-slots
          (+
            vars
            (be_operand.compiler-backend-win64-gp-callee-save-prefix
              backend-state
              assignments)))
        (* 2 (+ idx 1))))))

(define (compiler-backend-win64-xmm-callee-slot
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [idx : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (be_operand.compiler-backend-frame-offset-with-backend-state
    backend-state
    (compiler-backend-win64-xmm-callee-slot-offset
      backend-state
      assignments
      vars
      idx)))

;; Known entry producers mark large subtractions without another allocation.
;; The late record sink consumes the fact after ordinary subtraction analyses.
;; Unmarked/unknown decrements retain the conservative 4096-byte threshold.
(define (compiler-backend-emit-stack-sub
  [target-policy : be_state.CompilerBackendTargetPolicy]
  [frame : i64]) : String
  (if (= frame 0)
    ""
    (if target-policy.stack-probe
      (if (>= frame 4096)
        (str_cat.str-cat
          "    movl $"
          (string.int->string frame)
          ", %eax\n    callq __chkstk\n    subq %rax, %rsp\n"
          ""
          "")
        (str_cat.str-cat "    subq $" (string.int->string frame) ", %rsp\n" ""))
      (str_cat.str-cat
        (if (> frame 4096)
          "# tl-stack-entry\n    subq $"
          "    subq $")
        (string.int->string frame)
        ", %rsp\n"))))

(define (compiler-backend-emit-windows-seh-proc
  [target : be_state.CompilerBackendTarget]
  [symbol : (& symbol str)]) : String
  (if (be_state.compiler-backend-target-seh-unwind? target)
    (str_cat.str-cat ".seh_proc " symbol "\n" "")
    ""))

(define (compiler-backend-emit-windows-seh-push-rbp
  [target : be_state.CompilerBackendTarget]) : String
  (if (be_state.compiler-backend-target-seh-unwind? target)
    "    .seh_pushreg %rbp\n"
    ""))

(define (compiler-backend-emit-windows-seh-set-rbp
  [target : be_state.CompilerBackendTarget]) : String
  (if (be_state.compiler-backend-target-seh-unwind? target)
    "    .seh_setframe %rbp, 0\n"
    ""))

(define (compiler-backend-emit-win64-xmm-callee-regs-at
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [frame : i64]
  [idx : i64]
  [step : i64]
  [saving : bool]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (or
    (< idx 0)
    (>=
      idx
      (compiler_abi.compiler-abi-callee-saved-xmm-register-count
        (Windows)
        (Internal))))
    ""
    (let
      [reg-id : i64
        (compiler_abi.compiler-abi-callee-saved-xmm-register-id
          (Windows)
          (Internal)
          idx)]
      [reg : String (compiler_abi.compiler-abi-register-spelling reg-id)]
      [tail : String
        (compiler-backend-emit-win64-xmm-callee-regs-at
          assignments
          vars
          frame
          (+ idx step)
          step
          saving
          backend-state)]
      (if (be_operand.compiler-backend-callee-needs-save?
        backend-state
        assignments
        reg-id)
        (if saving
          (let
            [slot-offset : i64
              (compiler-backend-win64-xmm-callee-slot-offset
                backend-state
                assignments
                vars
                idx)]
            [unwind-offset : i64 (+ frame slot-offset)]
            [save-line : String
              (str_cat.str-cat
                "    movdqu "
                reg
                ", "
                (be_operand.compiler-backend-frame-offset-with-backend-state
                  backend-state
                  slot-offset)
                "\n")]
            [unwind-line : String
              (str_cat.str-cat
                "    .seh_savexmm "
                reg
                ", "
                (string.int->string unwind-offset)
                "\n")]
            (str_cat.str-cat save-line unwind-line tail))
          (str_cat.str-cat
            "    movdqu "
            (compiler-backend-win64-xmm-callee-slot
              assignments
              vars
              idx
              backend-state)
            ", "
            reg
            (str_cat.str-cat "\n" tail)))
        tail))))

(define (compiler-backend-emit-save-win64-xmm-callee-regs
  [target : be_state.CompilerBackendTarget]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [frame : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (>
    (compiler_abi.compiler-abi-callee-saved-xmm-register-count
      (be_state.compiler-backend-target-abi target)
      (Internal))
    0)
    (compiler-backend-emit-win64-xmm-callee-regs-at
      assignments
      vars
      frame
      0
      1
      true
      backend-state)
    ""))

(define (compiler-backend-emit-save-win64-xmm-callee-regs-fpo-at
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [rsp-bias : i64]
  [idx : i64]) : String
  (if (>=
    idx
    (compiler_abi.compiler-abi-callee-saved-xmm-register-count
      (Windows)
      (Internal)))
    ""
    (let
      [reg-id : i64
        (compiler_abi.compiler-abi-callee-saved-xmm-register-id
          (Windows)
          (Internal)
          idx)]
      [reg : String (compiler_abi.compiler-abi-register-spelling reg-id)]
      [tail : String
        (compiler-backend-emit-save-win64-xmm-callee-regs-fpo-at
          backend-state
          assignments
          vars
          rsp-bias
          (+ idx 1))]
      (if (be_operand.compiler-backend-callee-needs-save?
        backend-state
        assignments
        reg-id)
        (let
          [slot-offset : i64
            (compiler-backend-win64-xmm-callee-slot-offset
              backend-state
              assignments
              vars
              idx)]
          [rsp-offset : i64 (+ rsp-bias slot-offset)]
          (str_cat.str-cat
            "    movdqu "
            reg
            ", "
            (str_cat.str-cat
              (string.int->string rsp-offset)
              "(%rsp)\n    .seh_savexmm "
              reg
              ", ")
            (str_cat.str-cat (string.int->string rsp-offset) "\n" tail)))
        tail))))

(define (compiler-backend-emit-windows-seh-prologue-tail
  [target : be_state.CompilerBackendTarget]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [frame : i64]
  [end-prologue : bool]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (be_state.compiler-backend-target-seh-unwind? target)
    (str_cat.str-cat
      (if (> frame 0)
        (str_cat.str-cat
          "    .seh_stackalloc "
          (string.int->string frame)
          "\n"
          "")
        "")
      (compiler-backend-emit-win64-xmm-callee-regs-at
        assignments
        vars
        frame
        0
        1
        true
        backend-state)
      (if end-prologue
        "    .seh_endprologue\n"
        "")
      "")
    ""))

(define (compiler-backend-emit-c-entry-shared) : String
  ;; A raw leaf tail-enters with its body in volatile R11. At most four
  ;; physical words need no argument moves; the common frame preserves the
  ;; Platform saves, aligns the stack for the Internal body (which reserves no
  ;; shadow space), and owns the unwind record for the call.
  (str_cat.str-cat
    ".seh_proc __tl$c_entry\n__tl$c_entry:\n    pushq %rsi\n    .seh_pushreg %rsi\n    pushq %rdi\n    .seh_pushreg %rdi\n    subq $8, %rsp\n    .seh_stackalloc 8\n    .seh_endprologue\n    call *%r11\n    addq $8, %rsp\n    popq %rdi\n    popq %rsi\n    ret\n    .seh_endproc\n"
    (if (compiler_ir_types.compiler-debug-info-enabled?)
      (compiler-backend-backtrace-c-entry-range
        "__tl$c_entry"
        ".L_tl_c_entry_shared_end")
      "")))

(define (compiler-backend-emit-c-export-entry
  [type-segment-bases : i64]
  [target-policy : be_state.CompilerBackendTargetPolicy]
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]
  [params : (& params compiler_ir_types.CompilerIrParamSeq)]) : String
  (if (or
    (not (compiler_abi.compiler-abi-platform-entry-bridge? target-policy.abi))
    (not (be_operand.compiler-backend-index-c-export? index name)))
    ""
    (let
      [entry : String
        (be_operand.compiler-backend-index-extern-link-symbol index name)]
      [body : String
        (be_operand.compiler-backend-function-symbol-index index name)]
      [plan : be_facts.CompilerBackendCEntryPlan
        (be_facts.compiler-backend-c-entry-plan type-segment-bases index params)]
      [out : text_buf.TextBuf (text_buf.empty)]
      (when
        (<= plan.len 4)
        (return
          (str_cat.str-cat
            ".globl "
            entry
            "\n"
            entry
            ":\n    leaq "
            body
            "(%rip), %r11\n    jmp __tl$c_entry\n")))
      (text_buf.append!
        out
        (str_cat.str-cat
          ".globl "
          entry
          "\n.seh_proc "
          entry
          "\n"
          entry
          ":\n    pushq %rsi\n    .seh_pushreg %rsi\n    pushq %rdi\n    .seh_pushreg %rdi\n"
          (compiler-backend-emit-stack-sub target-policy plan.frame)
          "    .seh_stackalloc "
          (string.int->string plan.frame)
          "\n    .seh_endprologue\n"))
      (for [position (iterator.range 4 plan.len)]
        (text_buf.append!
          out
          (str_cat.str-cat
            "    movq "
            (string.int->string
              (be_facts.compiler-backend-c-entry-incoming-offset
                (& plan)
                position))
            "(%rsp), %rax\n"))
        (text_buf.append!
          out
          (if (< position 6)
            (str_cat.str-cat
              "    movq %rax, "
              (compiler_abi.compiler-abi-register-spelling
                (if (array-ref plan.float-words position)
                  (compiler_abi.compiler-abi-float-arg-register-id
                    target-policy.abi
                    (Internal)
                    position)
                  (compiler_abi.compiler-abi-gp-arg-register-id
                    target-policy.abi
                    (Internal)
                    position)))
              "\n")
            (str_cat.str-cat
              "    movq %rax, "
              (string.int->string
                (be_facts.compiler-backend-outgoing-stack-arg-offset
                  target-policy.target
                  (Internal)
                  (- position 6)))
              "(%rsp)\n"))))
      (text_buf.append!
        out
        (str_cat.str-cat
          "    call "
          body
          "\n    addq $"
          (string.int->string plan.frame)
          ", %rsp\n    popq %rdi\n    popq %rsi\n    ret\n    .seh_endproc\n"))
      (when
        (compiler_ir_types.compiler-debug-info-enabled?)
        (text_buf.append!
          out
          (compiler-backend-backtrace-c-entry-range
            entry
            (str_cat.str-cat ".L_tl_c_entry_end_" entry))))
      (text_buf.render out))))

(define (compiler-backend-emit-function-entry
  [target-policy : be_state.CompilerBackendTargetPolicy]
  [symbol : String]
  [frame : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [describe-saves : bool]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [target : be_state.CompilerBackendTarget target-policy.target]
    (str_cat.str-cat
      (compiler-backend-emit-windows-seh-proc target symbol)
      symbol
      (if (and
        (compiler_ir_types.compiler-debug-info-enabled?)
        target-policy.linux)
        ":\n    .cfi_startproc\n    pushq %rbp\n    .cfi_def_cfa_offset 16\n    .cfi_offset %rbp, -16\n"
        ":\n    pushq %rbp\n")
      (compiler-backend-emit-windows-seh-push-rbp target)
      "    movq %rsp, %rbp\n"
      (if (and
        (compiler_ir_types.compiler-debug-info-enabled?)
        target-policy.linux)
        "    .cfi_def_cfa_register %rbp\n"
        "")
      ;; A described prologue names no frame register (see
      ;; compiler-backend-windows-framed-describe-saves?) and leaves its end
      ;; marker to compiler-backend-windows-framed-save-splice.
      (if describe-saves
        ""
        (compiler-backend-emit-windows-seh-set-rbp target))
      (compiler-backend-emit-stack-sub target-policy frame)
      (compiler-backend-emit-windows-seh-prologue-tail
        target
        assignments
        vars
        frame
        (not describe-saves)
        backend-state))))

;; ============================================================================
;; Windows framed prologue: describing the callee-register saves.
;;
;; The framed entry is `pushq %rbp; movq %rsp, %rbp; subq $F, %rsp`, and every
;; callee-register save goes to a slot below %rbp. Under `.seh_setframe %rbp, 0`
;; the unwinder measures save offsets from the frame register, i.e. from %rsp
;; before the allocation, where those slots sit at negative offsets that
;; UWOP_SAVE_NONVOL and UWOP_SAVE_XMM128 cannot encode. A framed function that
;; saves callee registers therefore names no frame register. Its establisher
;; frame is the post-allocation %rsp, each save is recorded at FRAME + SLOT, and
;; the unwind program is PUSH_NONVOL %rbp, the allocation, the XMM saves and the
;; GP saves. The GP saves keep their machine-code position at the head of the
;; body and gain `.seh_savereg` rows before `.seh_endprologue`.
;;
;; Without a frame register the description holds wherever %rsp is at its
;; post-allocation value, as on the Win64 FPO path. This scan admits a function
;; only when every call and every instruction that can fault runs there. A
;; transient %rsp window (a phi push bracket, a CSR pop-run restore, the
;; terminal `leave` / `movq %rbp, %rsp` epilogue) may hold only moves, pushes,
;; pops, `leaq`, `ret` and a terminal `jmp`, with memory operands based on %rsp,
;; %rbp or %rip. A call or any other instruction inside a window, a `subq` /
;; `addq` of %rsp, any other write of %rsp, or a push window still open at a
;; label keeps the frame-register description.
(define (compiler-backend-windows-framed-frame-operand-ok?
  [data : (Ptr u8)]
  [start : i64]
  [end : i64]) : bool
  (let
    [p : i64
      (be_operand.compiler-backend-peephole-scan-byte-range data start end 40)]
    [ok : bool true]
    (while (and ok (< p end))
      (if (or
        (> (+ p 5) end)
        (not
          (or
            (be_operand.compiler-backend-peephole-range-eq?
              data
              (+ p 1)
              (+ p 5)
              "%rsp")
            (be_operand.compiler-backend-peephole-range-eq?
              data
              (+ p 1)
              (+ p 5)
              "%rbp")
            (be_operand.compiler-backend-peephole-range-eq?
              data
              (+ p 1)
              (+ p 5)
              "%rip"))))
        (set! ok false)
        unit)
      (set!
        p
        (be_operand.compiler-backend-peephole-scan-byte-range
          data
          (+ p 1)
          end
          40)))
    ok))

(define (compiler-backend-windows-framed-rsp-exact? [text : (& text str)]) : bool
  (let
    [n : i64 (string.string-length text)]
    [data : (Ptr u8)
      (unsafe
        (string-data text))]
    [i : i64 0]
    [delta : i64 0]
    [tail : bool false]
    [ok : bool true]
    (while (and ok (< i n))
      (let
        [end : i64
          (be_operand.compiler-backend-peephole-scan-byte-range data i n 10)]
        [m : i64 i]
        (while (and
          (< m end)
          (= (be_state.compiler-backend-peephole-byte-at data m) 32))
          (+= m 1))
        (cond
          [(>= m end) unit]
          [(= (be_state.compiler-backend-peephole-byte-at data (- end 1)) 58)
            (if (and (not tail) (not (= delta 0)))
              (set! ok false)
              unit)
            (set! delta 0)
            (set! tail false)]
          [(or
              (= (be_state.compiler-backend-peephole-byte-at data m) 46)
              (= (be_state.compiler-backend-peephole-byte-at data m) 35))
            unit]
          [else
            (let
              [te : i64
                (be_operand.compiler-backend-peephole-scan-byte-range
                  data
                  m
                  end
                  32)]
              [kind : i64
                (be_operand.compiler-backend-control-mnemonic-kind
                  data
                  m
                  (- te m))]
              [window? : bool (or tail (not (= delta 0)))]
              [rsp-dst? : bool
                (and
                  (>= (- end te) 6)
                  (be_operand.compiler-backend-peephole-range-eq?
                    data
                    (- end 6)
                    end
                    ", %rsp"))]
              (cond
                [(= kind be_operand.compiler-backend-control-mnemonic-push)
                  (if (and
                    window?
                    (not
                      (compiler-backend-windows-framed-frame-operand-ok?
                        data
                        te
                        end)))
                    (set! ok false)
                    unit)
                  (+= delta 8)]
                [(= kind be_operand.compiler-backend-control-mnemonic-pop)
                  (if (<
                    (be_operand.compiler-backend-peephole-scan-byte-range
                      data
                      te
                      end
                      40)
                    end)
                    (set! ok false)
                    unit)
                  (-= delta 8)]
                [(= kind be_operand.compiler-backend-control-mnemonic-leave)
                  (set! tail true)]
                [rsp-dst?
                  (if (or
                    (= kind be_operand.compiler-backend-control-mnemonic-leaq)
                    (be_operand.compiler-backend-peephole-range-eq?
                      data
                      m
                      end
                      "movq %rbp, %rsp"))
                    (set! tail true)
                    (set! ok false))]
                [(not window?) unit]
                [(or
                    (= kind be_operand.compiler-backend-control-mnemonic-ret)
                    (= kind be_operand.compiler-backend-control-mnemonic-leaq)
                    (and
                      tail
                      (= kind be_operand.compiler-backend-control-mnemonic-jmp)))
                  unit]
                [(or
                    (be_operand.compiler-backend-peephole-range-eq?
                      data
                      m
                      (+ m 3)
                      "mov")
                    (be_operand.compiler-backend-peephole-range-eq?
                      data
                      m
                      (+ m 4)
                      "vmov"))
                  (if (compiler-backend-windows-framed-frame-operand-ok?
                    data
                    te
                    end)
                    unit
                    (set! ok false))]
                [else (set! ok false)]))])
        (set! i (+ end 1))))
    ok))

(define (compiler-backend-windows-framed-describe-saves?
  [target-policy : be_state.CompilerBackendTargetPolicy]
  [fpo-ok : bool]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [body : (& body str)]
  [backend-state : be_state.CompilerBackendState]) : bool
  (and
    target-policy.seh-unwind
    (not fpo-ok)
    (be_operand.compiler-backend-plan-uses-callee-regs?
      assignments
      backend-state)
    (compiler-backend-windows-framed-rsp-exact? body)))

;; The x64 unwind format records a prologue of at most 255 bytes. Upper bounds
;; per instruction: pushq %rbp 1, movq %rsp, %rbp 3, the allocation 13 (the
;; `__chkstk` probe sequence), each XMM `movdqu` save 10, the mode prologue 4,
;; each GP `movq` save 8.
(define compiler-backend-windows-prologue-limit : i64
  255)

(define (compiler-backend-windows-framed-prologue-bound
  [xmm-count : i64]
  [mode-prologue? : bool]
  [gp-count : i64]) : i64
  (+
    17
    (* 10 xmm-count)
    (if mode-prologue?
      4
      0)
    (* 8 gp-count)))

(define (compiler-backend-windows-framed-save-error
  [symbol : (& symbol str)]
  [reg : (& reg str)]
  [slot : i64]
  [frame : i64]
  [what : (& what str)]) : String
  (str_cat.str-cat
    "backend: Windows unwind cannot describe the "
    reg
    " save of "
    symbol
    " (slot "
    (string.int->string slot)
    "(%rbp), frame "
    (string.int->string frame)
    "): "
    what))

;; Rewrites BODY, the framed function text, so the GP saves that follow its
;; prologue at byte BASE are described (see above); BASE is 0 when BODY starts
;; after the prologue, or the end of the prologue spliced at a shrink-wrap
;; saving label. Each save must be the first remaining line, in the saving
;; prologue's order, and store that register to its slot:
;; `movq REG, SLOT(%rbp)`, or `movq REG, FRAME+SLOT(%rsp)` once rebased, the
;; same address because %rbp = %rsp + FRAME after the allocation. Its row
;; `.seh_savereg REG, FRAME+SLOT` follows it; the assembler picks the near or
;; far encoding from that offset. Every recorded offset, GP and XMM, must lie in
;; the allocation and be aligned for its encoding.
(define (compiler-backend-windows-framed-save-splice
  [body : (& body str)]
  [base : i64]
  [mode-prologue : (& mode-prologue str)]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [frame : i64]
  [symbol : (& symbol str)]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [error : String ""]
    [xmm-count : i64 0]
    [gp-count : i64 0]
    [idx : i64 0]
    [k : i64 0]
    (while (and
      (string.eq error "")
      (<
        idx
        (compiler_abi.compiler-abi-callee-saved-xmm-register-count
          (Windows)
          (Internal))))
      (let
        [reg-id : i64
          (compiler_abi.compiler-abi-callee-saved-xmm-register-id
            (Windows)
            (Internal)
            idx)]
        (if (be_operand.compiler-backend-callee-needs-save?
          backend-state
          assignments
          reg-id)
          (let
            [slot : i64
              (compiler-backend-win64-xmm-callee-slot-offset
                backend-state
                assignments
                vars
                idx)]
            [offset : i64 (+ frame slot)]
            (+= xmm-count 1)
            (if (or
              (< offset 0)
              (not (= (% offset 16) 0))
              (> (+ offset 16) frame))
              (set!
                error
                (compiler-backend-windows-framed-save-error
                  symbol
                  (compiler_abi.compiler-abi-register-spelling reg-id)
                  slot
                  frame
                  "the offset is outside the allocation or not 16-byte aligned"))
              unit))
          unit)
        (+= idx 1)))
    (while (< k compiler-backend-callee-save-order-count)
      (if (compiler-backend-callee-save-order-saved?
        assignments
        k
        backend-state)
        (+= gp-count 1)
        unit)
      (+= k 1))
    (if (and (string.eq error "") (< base 0))
      (set!
        error
        (str_cat.str-cat
          "backend: Windows prologue of "
          symbol
          " is missing from its shrink-wrapped body"))
      unit)
    (let
      [start : i64
        (if (and
          (> gp-count 0)
          (> (string.string-length mode-prologue) 0)
          (string.is-string-prefix-at body mode-prologue base))
          (+ base (string.string-length mode-prologue))
          base)]
      [pos : i64 start]
      [rows : String ""]
      [bound : i64
        (compiler-backend-windows-framed-prologue-bound
          xmm-count
          (> start 0)
          gp-count)]
      (if (and
        (string.eq error "")
        (> bound compiler-backend-windows-prologue-limit))
        (set!
          error
          (str_cat.str-cat
            "backend: Windows prologue of "
            symbol
            " may need "
            (string.int->string bound)
            " bytes (frame "
            (string.int->string frame)
            ", "
            (string.int->string gp-count)
            " GP and "
            (string.int->string xmm-count)
            " XMM saves); x64 unwind info describes at most 255"))
        unit)
      (set! k 0)
      (while (and
        (string.eq error "")
        (< k compiler-backend-callee-save-order-count))
        (if (compiler-backend-callee-save-order-saved?
          assignments
          k
          backend-state)
          (let
            [reg : String
              (compiler_abi.compiler-abi-register-spelling
                (be_operand.compiler-backend-callee-save-order-reg-id k))]
            [slot : i64
              (compiler-backend-callee-save-slot-offset
                vars
                (compiler-backend-callee-save-order-slot-index k backend-state))]
            [offset : i64 (+ frame slot)]
            [rbp-line : String
              (str_cat.str-cat
                "    movq "
                reg
                ", "
                (string.int->string slot)
                "(%rbp)\n")]
            [rsp-line : String
              (str_cat.str-cat
                "    movq "
                reg
                ", "
                (string.int->string offset)
                "(%rsp)\n")]
            (cond
              [(or (< offset 0) (not (= (% offset 8) 0)) (> (+ offset 8) frame))
                (set!
                  error
                  (compiler-backend-windows-framed-save-error
                    symbol
                    reg
                    slot
                    frame
                    "the offset is outside the allocation or not 8-byte aligned"))]
              [(or
                  (string.is-string-prefix-at body rbp-line pos)
                  (string.is-string-prefix-at body rsp-line pos))
                (let
                  [line : String
                    (if (string.is-string-prefix-at body rbp-line pos)
                      rbp-line
                      rsp-line)]
                  (+= pos (string.string-length line))
                  (set!
                    rows
                    (str_cat.str-cat
                      rows
                      line
                      "    .seh_savereg "
                      reg
                      ", "
                      (string.int->string offset)
                      "\n")))]
              [else
                (set!
                  error
                  (compiler-backend-windows-framed-save-error
                    symbol
                    reg
                    slot
                    frame
                    "the next prologue line is not that save"))]))
          unit)
        (+= k 1))
      (if (string.eq error "")
        (Ok
          (str_cat.str-cat
            (string.substring body 0 start)
            rows
            "    .seh_endprologue\n"
            (string.substring body pos (- (string.string-length body) pos))))
        (be_state.compiler-backend-instr-error instr-diag error)))))

;; M-G3 stage 2: frame-pointer-omission prologue (Linux text path only; the
;; body was proven rsp-constant and fully rebased by compiler-backend-rsp-
;; rebase). The +8 replaces the omitted `pushq %rbp`: it keeps %rsp 16-aligned
;; at every call exactly as before AND leaves every frame slot at the same
;; ABSOLUTE address as the rbp world, so the rebase bias is unchanged. The
;; matching epilogue (`addq $(frame+8), %rsp`) is produced by the rebase
;; pass's `leave` rewrite.
;; The `+8` in the no-CSR FPO prologue exists only to keep call alignment (the
;; total displacement D % 16 == 8). A function that makes no call has nothing to
;; align for, and one that never names a frame slot has nothing for the rebase
;; pass to bias, so its stack adjustment is dead weight and both the prologue
;; sub and the epilogue fold disappear. Set per function, just before the rebase.
(define (compiler-backend-fpo-no-push-sub
  [backend-state : be_state.CompilerBackendState]
  [frame : i64]) : i64
  (be_operand.compiler-backend-rsp-rebase-push-sub backend-state frame 0))

(define (compiler-backend-emit-function-entry-fpo
  [backend-state : be_state.CompilerBackendState]
  [symbol : String]
  [frame : i64]) : String
  (let
    [sub : i64 (compiler-backend-fpo-no-push-sub backend-state frame)]
    (if (= sub 0)
      (str_cat.str-cat symbol ":\n" "")
      (str_cat.str-cat
        symbol
        (if (> sub 4096)
          ":\n# tl-stack-entry\n    subq $"
          ":\n    subq $")
        (string.int->string sub)
        ", %rsp\n"))))

;; GAP1: push-style FPO prologue -- the plan-saved CSRs are pushed (slot-idx
;; order r12..rbp; the pop-run epilogue pops the reverse) and the subq shrinks
;; to S = frame + pad, keeping the total displacement (8n + S) % 16 == 8 like
;; the no-push `subq $(frame+8)`. The rebase pass ran in push mode with the
;; SAME regs/count, so the body's frame refs, deleted mov saves/restores, and
;; rewritten epilogues all agree with this layout.
(define (compiler-backend-emit-function-entry-fpo-push
  [backend-state : be_state.CompilerBackendState]
  [symbol : String]
  [frame : i64]
  [push-regs : (__tl_dyn-array String)]
  [push-count : i64]) : String
  (let
    [sub-s : i64
      (be_operand.compiler-backend-rsp-rebase-push-sub
        backend-state
        frame
        push-count)]
    [acc : String (str_cat.str-cat symbol ":\n" "")]
    (for [idx (iterator.range 0 (array-length push-regs))]
      (if (string.eq
        (be_state.compiler-backend-global-array-element-shared-view
          push-regs
          idx)
        "")
        unit
        (set!
          acc
          (str_cat.str-cat
            acc
            "    pushq "
            (be_state.compiler-backend-global-array-element-shared-view
              push-regs
              idx)
            "\n"
            ""))))
    (if (= sub-s 0)
      acc
      (str_cat.str-cat
        acc
        (if (> sub-s 4096)
          "# tl-stack-entry\n    subq $"
          "    subq $")
        (string.int->string sub-s)
        ", %rsp\n"
        ""))))

(define (compiler-backend-emit-function-entry-fpo-windows
  [target-policy : be_state.CompilerBackendTargetPolicy]
  [backend-state : be_state.CompilerBackendState]
  [symbol : String]
  [frame : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [push-regs : (__tl_dyn-array String)]
  [push-count : i64]) : String
  (let
    [sub-s : i64
      (be_operand.compiler-backend-rsp-rebase-push-sub
        backend-state
        frame
        push-count)]
    [rsp-bias : i64
      (if (> push-count 0)
        sub-s
        frame)]
    [acc : String (str_cat.str-cat ".seh_proc " symbol "\n" symbol ":\n")]
    (for [idx (iterator.range 0 (array-length push-regs))]
      (if (string.eq
        (be_state.compiler-backend-global-array-element-shared-view
          push-regs
          idx)
        "")
        unit
        (set!
          acc
          (str_cat.str-cat
            acc
            "    pushq "
            (be_state.compiler-backend-global-array-element-shared-view
              push-regs
              idx)
            (str_cat.str-cat
              "\n    .seh_pushreg "
              (be_state.compiler-backend-global-array-element-shared-view
                push-regs
                idx)
              "\n")))))
    (set!
      acc
      (str_cat.str-cat
        acc
        (compiler-backend-emit-stack-sub target-policy sub-s)))
    (set!
      acc
      (str_cat.str-cat
        acc
        (if (> sub-s 0)
          (str_cat.str-cat
            "    .seh_stackalloc "
            (string.int->string sub-s)
            "\n"
            "")
          "")
        (compiler-backend-emit-save-win64-xmm-callee-regs-fpo-at
          backend-state
          assignments
          vars
          rsp-bias
          0)
        "    .seh_endprologue\n"))
    acc))

;; Build the incoming-ABI homes used only while re-emitting the frame-free
;; prefix. Register parameters are recorded directly; stack parameters are left
;; absent, so a prefix that actually references one fails closed during
;; emission. Aggregate register groups are likewise left to the ordinary framed
;; path until their full ABI classifier can be represented here.
(define (compiler-backend-shrinkwrap-incoming-fill!
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [params : compiler_ir_types.CompilerIrParamSeq]
  [int-index : i64]
  [float-index : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [table : compiler_regalloc.CompilerRegAssignmentTable]) : bool
  (for [position (iterator.range 0 params.len)]
    (match (compiler_ir_types.compiler-ir-param-seq-ref params position)
      [(Param _ ty var)
        ;; Register groups and memory-class aggregates do not take one integer
        ;; register each: a SysV memory-class parameter is passed on the stack
        ;; and shifts every later scalar down a register. The guard cannot model
        ;; either, so decline rather than test the wrong register.
        (if (or
          (be_facts.compiler-backend-group-type?
            type-segment-bases
            program-index
            ty)
          (>
            (be_facts.compiler-backend-abi-memory-size
              type-segment-bases
              (be_state.compiler-backend-global-shared-view ty))
            0))
          (return false)
          (let
            [is-float : bool (be_operand.compiler-backend-float-type? ty)]
            [on-stack : bool
              (compiler-backend-stack-call-arg-for-banks?
                target
                (Internal)
                is-float
                int-index
                float-index
                position)]
            [next-int : i64
              (if is-float
                int-index
                (+ int-index 1))]
            [next-float : i64
              (if is-float
                (+ float-index 1)
                float-index)]
            (if on-stack
              (begin
                (set! int-index next-int)
                (set! float-index next-float))
              (match (if is-float
                (be_facts.compiler-backend-target-float-arg-reg-for-banks
                  target
                  (Internal)
                  float-index
                  position)
                (be_facts.compiler-backend-target-arg-reg-for-banks
                  target
                  (Internal)
                  int-index
                  position))
                [(Ok reg)
                  (compiler_regalloc.compiler-reg-assignment-table-insert
                    table
                    var
                    (Register
                      (compiler_abi.compiler-abi-register-id-from-spelling reg)))
                  (set! int-index next-int)
                  (set! float-index next-float)]
                [(Err _) (return false)]))))]))
  true)

(define (compiler-backend-shrinkwrap-incoming-assignments
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [params : compiler_ir_types.CompilerIrParamSeq]
  [vars : i64]
  [program-index : be_state.CompilerBackendProgramIndex]) : compiler_regalloc.CompilerRegAssignmentTable
  (let
    [table : compiler_regalloc.CompilerRegAssignmentTable
      (compiler_regalloc.compiler-reg-assignment-table-make vars)]
    (if (compiler-backend-shrinkwrap-incoming-fill!
      type-segment-bases
      target
      params
      0
      0
      program-index
      table)
      table
      (compiler_regalloc.compiler-reg-assignment-table-empty))))

(define (compiler-backend-shrinkwrap-incoming-value-ready?
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]) : bool
  (match value
    [(Var var)
      (match (compiler_regalloc.compiler-reg-assignment-lookup assignments var)
        [(Some location)
          (match location
            [(or (Register _) (RegisterPair _ _)) true]
            [_ false])]
        [(No) false])]
    [_ true]))

;; Prefix guards are dry-emitted before the current function's scavenge
;; intervals are installed.  Admit only operands the compare emitter can use
;; directly: a register home or an encodable immediate.  Falling through to a
;; scratch here is not merely an admission-time state hazard; on Win64 it can
;; overwrite a different incoming argument that a later bare return still
;; needs (for example, a large literal staged into %r8 before returning the
;; third argument from %r8).
(define (compiler-backend-shrinkwrap-compare-value-ready?
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [backend-state : be_state.CompilerBackendState]) : bool
  (match (be_operand.compiler-backend-immediate-operand backend-state value)
    [(Some _) true]
    [(No)
      (match value
        [(Var var)
          (match (compiler_regalloc.compiler-reg-assignment-lookup
            assignments
            var)
            [(Some location)
              (match location
                [(Register _) true]
                [_ false])]
            [(No) false])]
        [_ false])]))

(define (compiler-backend-shrinkwrap-incoming-return-ready?
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrMaybeValue]) : bool
  (match value
    [(No) true]
    [(Some some)
      (compiler-backend-shrinkwrap-incoming-value-ready? assignments some)]))

(define (compiler-backend-shrinkwrap-fallthrough
  [seq : (& seq compiler_ir_types.CompilerIrBlockSeq)]
  [index : i64]) : be_state.CompilerBackendMaybeLabel
  (if (< (+ index 1) (compiler_ir_types.compiler-ir-block-seq-count seq))
    (match (compiler_ir_types.compiler-ir-block-seq-borrow seq (+ index 1))
      [(Block next-label _) (Some next-label)])
    (No)))

;; Emit exactly the rewritten prefix with either the allocator's planned homes
;; (the textual splice needle) or incoming ABI homes (the replacement). The
;; prefix count is supplied by the property rewrite and every block is proven to
;; be compare+branch or a bare return. Any drift returns "" and triggers the
;; existing unwrapped full-pipeline retry.
(define (compiler-backend-shrinkwrap-prefix-asm
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [params : compiler_ir_types.CompilerIrParamSeq]
  [vars : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [function : String]
  [source-function : i64]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [bare-prefix : String]
  [prefix-count : i64]
  [ret-ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [incoming? : bool]) : String
  (let
    [seq : compiler_ir_types.CompilerIrBlockSeq
      (compiler_liveness.compiler-live-ir-block-list-to-seq (& blocks))]
    [selected : compiler_regalloc.CompilerRegAssignmentTable
      (if incoming?
        (compiler-backend-shrinkwrap-incoming-assignments
          type-segment-bases
          target
          (be_state.compiler-backend-global-shared-view params)
          vars
          program-index)
        assignments)]
    [ready : bool
      (and
        (> prefix-count 0)
        (<= prefix-count (compiler_ir_types.compiler-ir-block-seq-count seq))
        (or
          (not incoming?)
          (if (compiler_regalloc.compiler-reg-assignment-table-empty? selected)
            (= (compiler_ir_types.compiler-ir-param-seq-count params) 0)
            true)))]
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state
        program-index.backend-state)]
    [old-bare : String
      (be_state.compiler-backend-function-state-string
        function-state
        be_state.compiler-backend-function-string-shrinkwrap-bare-label)]
    [old-current-block : i64
      (be_state.compiler-backend-function-state-i64
        function-state
        be_state.compiler-backend-function-i64-current-block-label)]
    ;; The ordinary function emitter has a dense index for the allocator's
    ;; post-prologue homes.  It deliberately ignores the list argument passed
    ;; to emit-assignment-lookup.  That is correct for normal emission, but an
    ;; incoming prefix must use the temporary ABI-home list above.  Isolate the
    ;; prefix while it is rendered so a param allocated to (say) %r12 cannot be
    ;; read before the saving edge.
    [old-assignment-index-active : bool
      (be_state.compiler-backend-function-state-bool?
        function-state
        be_state.compiler-backend-function-bool-emit-assignment-index-active)]
    [acc : String ""]
    [index : i64 0]
    (be_state.compiler-backend-function-state-set-string!
      function-state
      be_state.compiler-backend-function-string-shrinkwrap-bare-label
      bare-prefix)
    (if incoming?
      (be_state.compiler-backend-function-state-set-bool!
        function-state
        be_state.compiler-backend-function-bool-emit-assignment-index-active
        false)
      unit)
    (while (and ready (< index prefix-count))
      (match (compiler_ir_types.compiler-ir-block-seq-borrow seq index)
        [(Block label instrs)
          (let
            [count : i64 (compiler_ir_types.compiler-ir-instr-seq-count instrs)]
            [_current-block : unit
              (be_state.compiler-backend-function-state-set-i64!
                function-state
                be_state.compiler-backend-function-i64-current-block-label
                label)]
            [piece : be_state.ResultCompilerBackend
              (if (= count 2)
                (match (compiler_ir_types.compiler-ir-instr-seq-ref instrs 0)
                  [(BinOp dst op lhs rhs ty)
                    (match (compiler_ir_types.compiler-ir-instr-scalar-fact
                      (compiler_ir_types.compiler-ir-instr-seq-ref instrs 1))
                      [(Branch cond on-true on-false)
                        (match cond
                          [(Var cond-var)
                            (if (and
                              (= cond-var dst)
                              (compiler-backend-shrinkwrap-compare-value-ready?
                                selected
                                (be_state.compiler-backend-global-shared-view
                                  lhs)
                                program-index.backend-state)
                              (compiler-backend-shrinkwrap-compare-value-ready?
                                selected
                                (be_state.compiler-backend-global-shared-view
                                  rhs)
                                program-index.backend-state))
                              (compiler-backend-emit-compare-branch
                                type-segment-bases
                                selected
                                (be_state.compiler-backend-global-shared-view
                                  function)
                                op
                                lhs
                                rhs
                                ty
                                on-true
                                on-false
                                (compiler-backend-shrinkwrap-fallthrough
                                  seq
                                  index)
                                program-index.backend-state)
                              (Err
                                (box
                                  (compiler_diagnostic.compiler-diagnostic-at-start
                                    ""
                                    "shrinkwrap guard drift"))))]
                          [_
                            (Err
                              (box
                                (compiler_diagnostic.compiler-diagnostic-at-start
                                  ""
                                  "shrinkwrap guard drift")))])]
                      [_
                        (Err
                          (box
                            (compiler_diagnostic.compiler-diagnostic-at-start
                              ""
                              "shrinkwrap guard drift")))])]
                  [_
                    (Err
                      (box
                        (compiler_diagnostic.compiler-diagnostic-at-start
                          ""
                          "shrinkwrap guard drift")))])
                (if (= count 1)
                  (match (compiler_ir_types.compiler-ir-instr-seq-ref instrs 0)
                    [(Return maybe)
                      (if (or
                        (not incoming?)
                        (compiler-backend-shrinkwrap-incoming-return-ready?
                          selected
                          (be_state.compiler-backend-global-shared-view maybe)))
                        (compiler-backend-emit-return
                          type-segment-bases
                          source-function
                          (be_state.compiler-backend-global-shared-view blocks)
                          maybe
                          selected
                          vars
                          (be_state.compiler-backend-global-shared-view ret-ty)
                          program-index)
                        (Err
                          (box
                            (compiler_diagnostic.compiler-diagnostic-at-start
                              ""
                              "shrinkwrap incoming return unavailable"))))]
                    [_
                      (Err
                        (box
                          (compiler_diagnostic.compiler-diagnostic-at-start
                            ""
                            "shrinkwrap return drift")))])
                  (Err
                    (box
                      (compiler_diagnostic.compiler-diagnostic-at-start
                        ""
                        "shrinkwrap prefix drift")))))]
            (match piece
              [(Ok asm)
                (set!
                  acc
                  (str_cat.str-cat
                    acc
                    (be_operand.compiler-backend-asm-label
                      (be_state.compiler-backend-global-shared-view function)
                      label)
                    ":\n"
                    asm))]
              [(Err _) (set! ready false)]))])
      (+= index 1))
    (be_state.compiler-backend-function-state-set-string!
      function-state
      be_state.compiler-backend-function-string-shrinkwrap-bare-label
      old-bare)
    (be_state.compiler-backend-function-state-set-i64!
      function-state
      be_state.compiler-backend-function-i64-current-block-label
      old-current-block)
    (be_state.compiler-backend-function-state-set-bool!
      function-state
      be_state.compiler-backend-function-bool-emit-assignment-index-active
      old-assignment-index-active)
    (if ready
      acc
      "")))

;; True once a branch terminator has already emitted its emergency restore INLINE
;; (right after the flag-setting compare/test, before the conditional jumps) -- so
;; the per-instruction emergency-wrap must NOT append a trailing restore after the
;; branch. A trailing restore would land after the jumps (dead code when both edges
;; jump away, e.g. critical-edge phi blocks), leaving the scavenged register's
;; live-out value never restored. Owned by the active function and consumed by
;; emergency-wrap.
;; The clang-shaped signed-divmod SRC keeps %r10 as its normal free fallback,
;; but a saturated site must not emergency-borrow it.  %r10 is also the generic
;; staging fallback immediately after divmod; restoring an emergency-owned %r10
;; there gives the reload-elision owner map a target-dependent frame owner
;; (Win64 and SysV have different occupied pools) and leaves a redundant reload
;; on Win64.  This flag affects only the emergency tier -- a genuinely free
;; %r10 remains the preferred choice.
;; One emergency slot must preserve the widest physical register bank the
;; current backend can expose. GP saves use the first 8 bytes; XMM-family saves
;; use 16/32/64 bytes in scalar/AVX2/AVX-512 mode respectively.
(define (compiler-backend-emergency-slot-size) : i64
  64)

(define (compiler-backend-emergency-frame-extra [count : i64]) : i64
  (be_operand.compiler-backend-round-up-16
    (* count (compiler-backend-emergency-slot-size))))

(define (compiler-backend-cycle-temp-max-slots) : i64
  2)

(define (compiler-backend-cycle-temp-frame-extra [count : i64]) : i64
  (if (> count 0)
    (be_operand.compiler-backend-round-up-16 (* count 8))
    0))

(define (compiler-backend-cycle-temp-frame-extra-needed
  [count : i64]
  [emergency-used : bool]) : i64
  (if (or (> count 0) emergency-used)
    (compiler-backend-cycle-temp-frame-extra
      (compiler-backend-cycle-temp-max-slots))
    0))

(define (compiler-backend-cycle-temp-use-slots!
  [function-state : be_state.CompilerBackendFunctionState]
  [count : i64]) : unit
  (if (>
    count
    (be_state.compiler-backend-function-scratch-i64
      function-state
      be_state.compiler-backend-scratch-i64-cycle-temp-used-count))
    (be_state.compiler-backend-function-scratch-set-i64!
      function-state
      be_state.compiler-backend-scratch-i64-cycle-temp-used-count
      count)
    unit))

(define (compiler-backend-cycle-temp-slot-offset
  [function-state : be_state.CompilerBackendFunctionState]
  [index : i64]) : i64
  (compiler-backend-cycle-temp-use-slots! function-state (+ index 1))
  (-
    (be_state.compiler-backend-function-scratch-i64
      function-state
      be_state.compiler-backend-scratch-i64-cycle-temp-base-offset)
    (* 8 index)))

(define (compiler-backend-cycle-temp-slot-with-backend-state
  [backend-state : be_state.CompilerBackendState]
  [index : i64]) : String
  (be_operand.compiler-backend-frame-offset-with-backend-state
    backend-state
    (compiler-backend-cycle-temp-slot-offset
      (be_state.compiler-backend-state-function-state backend-state)
      index)))

(define (compiler-backend-emergency-reg-offset
  [function-state : be_state.CompilerBackendFunctionState]
  [index : i64]) : i64
  (-
    (be_state.compiler-backend-function-scratch-i64
      function-state
      be_state.compiler-backend-scratch-i64-emergency-slot-offset)
    (* (compiler-backend-emergency-slot-size) index)))

;; The AVX2 predicated fallback: a shape AVX2 accepts whose element has no
;; vpmaskmov/vmaskmov form stages its lanes. A bool store tests mask bits in
;; GPRs instead.
(define (compiler-backend-avx2-predicated-staged?
  [elem-ty : (& elem-ty compiler_ast_types.AstType)]
  [lanes : i64]
  [store : bool]) : bool
  (match elem-ty
    [(Bool)
      (and (not store) (be_operand.compiler-backend-avx2-mask-shape-ok? lanes))]
    [_
      (and
        (be_operand.compiler-backend-avx2-shape-ok? elem-ty lanes)
        (string.eq
          (be_operand.compiler-backend-avx2-masked-move-mnemonic elem-ty)
          ""))]))

;; The bytes INSTR's emitted sequence will stage, following the dispatch in
;; `compiler-backend-emit-instr-with-bound`: a vector binop picks its ISA from
;; its own shape, the predicated, gather and tail-mask ops from the function's
;; mode, and a shuffle from its own shape. 0 for every other instruction.
(define (compiler-backend-simd-scratch-request
  [instr : compiler_ir_types.CompilerIrInstr]
  [avx2-function : bool]) : i64
  (match instr
    [(VectorBinOp payload-box)
      (let
        [op (be_state.compiler-backend-box-field-shared-view payload-box op)]
        [lanes (deref payload-box).lanes]
        [elem-ty
          (be_state.compiler-backend-box-field-shared-view payload-box ty)]
        [mode : be_state.CompilerBackendMode
          (be_operand.compiler-backend-vector-mode elem-ty lanes)]
        (cond
          [(not (be_operand.compiler-backend-mode-shape-ok? mode elem-ty lanes))
            0]
          [(and
              (be_state.compiler-backend-mode-avx2? mode)
              (be_operand.compiler-backend-word-vector-shift? op elem-ty))
            be_operand.compiler-backend-simd-scratch-word-shift-bytes]
          [(be_operand.compiler-backend-byte-vector-shift? op elem-ty)
            (be_operand.compiler-backend-simd-scratch-byte-shift-bytes
              (match mode
                [(Avx512) 64]
                [_ 32]))]
          [else 0]))]
    [(PredicatedLoad payload-box)
      (let
        [lanes (deref payload-box).lanes]
        [elem-ty
          (be_state.compiler-backend-box-field-shared-view payload-box ty)]
        (if (and
          avx2-function
          (compiler-backend-avx2-predicated-staged? elem-ty lanes false))
          be_operand.compiler-backend-simd-scratch-lane-staging-bytes
          0))]
    [(PredicatedStore payload-box)
      (let
        [lanes (deref payload-box).lanes]
        [elem-ty
          (be_state.compiler-backend-box-field-shared-view payload-box ty)]
        (if (and
          avx2-function
          (compiler-backend-avx2-predicated-staged? elem-ty lanes true))
          be_operand.compiler-backend-simd-scratch-lane-staging-bytes
          0))]
    [(GatherLoad payload-box)
      (let
        [lanes (deref payload-box).lanes]
        [elem-ty
          (be_state.compiler-backend-box-field-shared-view payload-box ty)]
        [dword : bool
          (be_operand.compiler-backend-gather-dword-element?
            (be_state.compiler-backend-global-shared-view elem-ty))]
        [mnemonic : String
          (if avx2-function
            (be_operand.compiler-backend-avx2-gather-mnemonic elem-ty)
            (be_operand.compiler-backend-avx512-gather-mnemonic elem-ty))]
        (if (and
          (not (string.eq mnemonic ""))
          (=
            lanes
            (*
              (if avx2-function
                4
                8)
              (if dword
                2
                1))))
          (be_operand.compiler-backend-simd-scratch-gather-bytes
            avx2-function
            dword)
          0))]
    [(VectorShuffle payload-box)
      (let
        [lanes (deref payload-box).lanes]
        [elem-ty
          (be_state.compiler-backend-box-field-shared-view payload-box ty)]
        [avx512 : bool
          (be_operand.compiler-backend-avx512-shape-ok? elem-ty lanes)]
        (if (or
          avx512
          (be_operand.compiler-backend-avx2-shape-ok? elem-ty lanes))
          (be_operand.compiler-backend-simd-scratch-shuffle-bytes
            (if avx512
              64
              32)
            (if (>
              lanes
              (if avx512
                8
                4))
              2
              1))
          0))]
    [(TailMask _ _ _ lanes)
      (if (and
        avx2-function
        (be_operand.compiler-backend-avx2-mask-shape-ok? lanes)
        (not (= lanes 4)))
        be_operand.compiler-backend-simd-scratch-lane-staging-bytes
        0)]
    [_ 0]))

(define (compiler-backend-simd-scratch-census-instrs
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [avx2-function : bool]
  [widest : i64]) : i64
  (let
    [acc : i64 widest]
    (for [index (iterator.range 0 instrs.len)]
      (let
        [request : i64
          (compiler-backend-simd-scratch-request
            (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)
            avx2-function)]
        (if (> request acc)
          (set! acc request)
          unit)))
    acc))

(define (compiler-backend-simd-scratch-census-seq
  [blocks : (& blocks compiler_ir_types.CompilerIrBlockSeq)]
  [avx2-function : bool]
  [widest : i64]) : i64
  (let
    [acc : i64 widest]
    (for [index
      (iterator.range 0 (compiler_ir_types.compiler-ir-block-seq-count blocks))]
      (match (compiler_ir_types.compiler-ir-block-seq-ref blocks index)
        [(Block _ instrs)
          (set!
            acc
            (compiler-backend-simd-scratch-census-instrs
              instrs
              avx2-function
              acc))]))
    acc))

(define (compiler-backend-simd-scratch-census-list
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [avx2-function : bool]
  [widest : i64]) : i64
  (match blocks
    [(Array seq)
      (compiler-backend-simd-scratch-census-seq seq avx2-function widest)]))

;; The function's staging region size: the largest request over every block
;; the body will emit, rounded to the frame's 16-byte granule. 0 when no
;; instruction stages, so such a function's frame is unchanged. A scalar-mode
;; function lowers no vector instruction and is not walked; a staged claim in
;; one would still fail against its empty plan.
(define (compiler-backend-simd-scratch-census
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [mode : be_state.CompilerBackendMode]) : i64
  (if (be_state.compiler-backend-mode-scalar? mode)
    0
    (be_operand.compiler-backend-round-up-16
      (compiler-backend-simd-scratch-census-list
        blocks
        (be_state.compiler-backend-mode-avx2? mode)
        0))))

;; Plan a region of BYTES directly below FRAME-BASE, the frame offset the
;; function's dynamic slots count down from, and clear the body's claims.
(define (compiler-backend-simd-scratch-plan!
  [function-state : be_state.CompilerBackendFunctionState]
  [bytes : i64]
  [frame-base : i64]) : unit
  (be_state.compiler-backend-function-scratch-set-i64!
    function-state
    be_state.compiler-backend-scratch-i64-simd-scratch-bytes
    bytes)
  (be_state.compiler-backend-function-scratch-set-i64!
    function-state
    be_state.compiler-backend-scratch-i64-simd-scratch-base-offset
    (- 0 (+ frame-base bytes)))
  (be_state.compiler-backend-function-scratch-set-i64!
    function-state
    be_state.compiler-backend-scratch-i64-simd-scratch-used-bytes
    0))

;; After the body: the region the body used must equal the plan. A claim
;; beyond it has already failed at its instruction; a reference beyond it is a
;; sequence that staged without a claim the census counted; a smaller use means
;; the census reserved a region no emitted sequence needed.
(define (compiler-backend-simd-scratch-drift?
  [function-state : be_state.CompilerBackendFunctionState]) : bool
  (not
    (=
      (be_operand.compiler-backend-round-up-16
        (be_state.compiler-backend-function-scratch-i64
          function-state
          be_state.compiler-backend-scratch-i64-simd-scratch-used-bytes))
      (be_state.compiler-backend-function-scratch-i64
        function-state
        be_state.compiler-backend-scratch-i64-simd-scratch-bytes))))

;; ============================================================================
;; T1-6 (b): frame-free emergency scratch saves.
;;
;; The address/global-materialisation sites hand the scavenger a fixed
;; preferred scratch (`%r10` for a base, `%r9` for a length, ...). When the
;; occupancy at that point leaves NO free, non-excluded, caller-saved register,
;; the scavenger borrows an occupied one and `compiler-backend-emergency-wrap`
;; brackets the instruction with a save/restore. Saving to a 64-byte FRAME slot
;; names a frame slot, and naming a frame slot is exactly what forces a
;; function to have a frame at all: a call-free leaf would pay a `subq`/`addq`
;; of %rsp on every call for one `movq %r9,(%rsp)` pair.
;;
;; Park the value in a free XMM register instead. `movq %rGP, %xmmN` /
;; `movq %xmmN, %rGP` is the same two instructions, touches no memory, needs no
;; slot -- so the function keeps a dead slot region and (with T1-6 (a) or the
;; existing bare-frame rule) no stack adjustment at all.
;;
;; The park register must be provably untouched between the save and the
;; restore, which bracket ONE instruction's emission. Four conditions give that:
;;   * the pool is {%xmm4, %xmm5}. Those two spellings appear nowhere in the
;;     emitters except in the scavenge candidate pool, so the only ways they can
;;     reach the text are the register allocator's plan and the XMM scavenger;
;;   * the PLAN never homes a value in that family anywhere in this function
;;     (`scavenge-plan-reg-mask`, which folds vec ids onto their xmm sibling, so
;;     a ymm/zmm home is caught too) -- this rules out the allocator;
;;   * the bit is added to the instruction's RESERVED mask the moment it is
;;     picked, so a later XMM scavenge inside the same instruction cannot pick
;;     it -- this rules out the scavenger;
;;   * it is free in the occupancy mask at this point.
;; Scalar mode only: in AVX2/AVX-512 bodies a legacy-SSE `movq` next to VEX code
;; would pay an AVX/SSE transition, and those bodies have live wide registers
;; anyway. Win64 keeps the frame slot (its own callee-save discipline for
;; %xmm6.. is unrelated, but the parking pool is not worth two ABIs of proof).
(define compiler-backend-emergency-park-candidate-count : i64
  2)

(define (compiler-backend-emergency-park-candidate [index : i64]) : i64
  (if (= index 0)
    (compiler_abi.compiler-abi-xmm-register-id 4)
    (compiler_abi.compiler-abi-xmm-register-id 5)))

;; A borrowed register the bracketed text provably leaves alone.
;;
;; The scavenger enqueues the emergency save when it hands the register out,
;; before the instruction is emitted -- and the instruction often turns out not
;; to use the scratch at all (a fused address whose base already had a register
;; home, say), leaving a save/restore pair around text that never writes the
;; register. Two facts make dropping such a pair provable from the text alone:
;;
;;   * the register is %r8..%r15. Those eight are the only general-purpose
;;     registers no x86-64 instruction touches IMPLICITLY (%rax/%rdx feed
;;     mul/div/cqto, %rcx/%rsi/%rdi feed the string and shift forms, %rsp/%rbp
;;     feed push/pop/leave), so "not named in the text" means "not written";
;;   * the text contains no `call` (the substring also covers `syscall`): a
;;     callee may clobber any caller-saved register without naming it.
;;
;; Then no spelling of the register appears in the bracketed text, so the value
;; the wrap would have preserved is still there when the wrap ends. Dropping
;; the pair is strictly better than emitting it: two fewer instructions, and no
;; frame slot named for a save that was never needed.
(define (compiler-backend-emergency-reg-untouched-by-text?
  [text : (& text str)]
  [reg : i64]) : bool
  (and
    (compiler-backend-emergency-text-park-allowed? text)
    (>= reg compiler_abi.compiler-reg-id-r8)
    (<= reg compiler_abi.compiler-reg-id-r15)
    (let
      [name : String (compiler_abi.compiler-abi-register-spelling reg)]
      (and
        (not (be_operand.compiler-backend-string-contains? text name))
        (not
          (be_operand.compiler-backend-string-contains?
            text
            (be_operand.compiler-backend-reg-part
              (be_state.compiler-backend-global-shared-view name)
              4)))
        (not
          (be_operand.compiler-backend-string-contains?
            text
            (be_operand.compiler-backend-reg-part
              (be_state.compiler-backend-global-shared-view name)
              2)))
        (not
          (be_operand.compiler-backend-string-contains?
            text
            (be_operand.compiler-backend-reg-part name 1)))))))

;; Is `xmm` already parking another pending save in this wrap?
(define (compiler-backend-emergency-park-taken?
  [function-state : be_state.CompilerBackendFunctionState]
  [count : i64]
  [xmm : i64]) : bool
  (let
    [i : i64 0]
    [found : bool false]
    (while (and (< i count) (not found))
      (if (=
        (be_operand.compiler-backend-emergency-save-loc function-state i)
        xmm)
        (set! found true)
        unit)
      (set! i (+ i 1)))
    found))

;; Number of pending saves already charged a FRAME slot (their dense index).
(define (compiler-backend-emergency-slot-form-count
  [function-state : be_state.CompilerBackendFunctionState]
  [count : i64]) : i64
  (let
    [i : i64 0]
    [n : i64 0]
    (while (< i count)
      (if (be_operand.compiler-backend-emergency-loc-slot-form?
        (be_operand.compiler-backend-emergency-save-loc function-state i))
        (set! n (+ n 1))
        unit)
      (set! i (+ i 1)))
    n))

;; Does the bracketed text leave `xmm` alone? The three vector spellings of the
;; family are the ONLY ways a line can name it, so a text that mentions none of
;; them neither reads nor writes the register.
(define (compiler-backend-emergency-park-untouched-by-text?
  [text : (& text str)]
  [xmm : i64]) : bool
  (let
    [family : i64 (compiler_regalloc.compiler-reg-xmm-family-index xmm)]
    [digits : String (string.int->string family)]
    (and
      (not
        (be_operand.compiler-backend-string-contains?
          text
          (str_cat.str-cat "%xmm" digits)))
      (not
        (be_operand.compiler-backend-string-contains?
          text
          (str_cat.str-cat "%ymm" digits)))
      (not
        (be_operand.compiler-backend-string-contains?
          text
          (str_cat.str-cat "%zmm" digits))))))

;; The XMM register pending save `index` may park in, or -1 for a frame slot.
;; See the T1-6 (b) note above for the four conditions.
(define (compiler-backend-emergency-park-reg
  [function-state : be_state.CompilerBackendFunctionState]
  [reg : i64]
  [count : i64]
  [text : (& text str)]
  [park-allowed : bool]) : i64
  (if (or
    (not park-allowed)
    (be_state.compiler-backend-function-state-bool?
      function-state
      be_state.compiler-backend-function-bool-current-fn-win64)
    (>= (compiler_regalloc.compiler-reg-xmm-family-index reg) 0)
    (not
      (match (be_state.compiler-backend-function-state-current-mode
        function-state)
        [(Scalar) true]
        [_ false])))
    -1
    (let
      [plan-mask : i64
        (be_state.compiler-backend-function-scratch-i64
          function-state
          be_state.compiler-backend-scratch-i64-scavenge-plan-reg-mask)]
      [i : i64 0]
      [found : i64 -1]
      (while (and
        (< i compiler-backend-emergency-park-candidate-count)
        (< found 0))
        (let
          [xmm : i64 (compiler-backend-emergency-park-candidate i)]
          [bit : i64 (be_operand.compiler-backend-scavenge-reg-id-bit xmm)]
          (if (and
            (not (= bit 0))
            (= (bit-and plan-mask bit) 0)
            (not
              (be_operand.compiler-backend-const-hoist-uses-reg?
                function-state
                xmm))
            (not
              (compiler-backend-emergency-park-taken? function-state count xmm))
            (compiler-backend-emergency-park-untouched-by-text? text xmm))
            (set! found xmm)
            unit)
          (set! i (+ i 1))))
      found)))

;; Give every still-undecided pending save a park location. `text` is the
;; bracketed instruction text and `park-allowed` says whether an XMM park may be
;; considered at all -- false for the INLINE restore paths (a branch's
;; restore-before-jumps, the divmod address restore, the buffer-splice wrap),
;; which emit their restore before the bracketed text exists.
;; Charging a frame slot here rather than at scavenge time is what lets an
;; XMM-parked function keep a dead slot region: `emergency-used` and the slot
;; count are the frame's inputs and are read only after the whole body is
;; emitted.
(define (compiler-backend-emergency-commit-locs!
  [function-state : be_state.CompilerBackendFunctionState]
  [text : (& text str)]
  [have-text : bool]
  [park-allowed : bool]) : unit
  (let
    [count : i64
      (be_state.compiler-backend-function-scratch-i64
        function-state
        be_state.compiler-backend-scratch-i64-emergency-pending-count)]
    [i : i64 0]
    (while (< i count)
      (if (=
        (be_operand.compiler-backend-emergency-save-loc function-state i)
        be_operand.compiler-backend-emergency-loc-undecided)
        (let
          [reg : i64
            (array-ref
              (be_state.compiler-backend-function-scratch-i64-array
                function-state
                be_state.compiler-backend-scratch-i64-array-emergency-regs)
              i)]
          [untouched : bool
            (and
              have-text
              (compiler-backend-emergency-reg-untouched-by-text? text reg))]
          [park : i64
            (if untouched
              -1
              (compiler-backend-emergency-park-reg
                function-state
                reg
                count
                text
                park-allowed))]
          [slot-index : i64
            (compiler-backend-emergency-slot-form-count function-state count)]
          [loc : i64
            (if untouched
              be_operand.compiler-backend-emergency-loc-elided
              (if (>= park 0)
                park
                (- 0 (+ slot-index 1))))]
          [locs : (__tl_dyn-array i64)
            (be_state.compiler-backend-function-scratch-i64-array
              function-state
              be_state.compiler-backend-scratch-i64-array-emergency-save-locs)]
          (set! (array-ref locs i) loc)
          (be_state.compiler-backend-function-scratch-set-i64-array!
            function-state
            be_state.compiler-backend-scratch-i64-array-emergency-save-locs
            locs)
          (unless
            (or untouched (>= park 0))
            (be_state.compiler-backend-function-scratch-set-bool!
              function-state
              be_state.compiler-backend-scratch-bool-emergency-used
              true)
            (if (>
              (+ slot-index 1)
              (be_state.compiler-backend-function-scratch-i64
                function-state
                be_state.compiler-backend-scratch-i64-emergency-used-count))
              (be_state.compiler-backend-function-scratch-set-i64!
                function-state
                be_state.compiler-backend-scratch-i64-emergency-used-count
                (+ slot-index 1))
              unit)))
        unit)
      (set! i (+ i 1)))))

;; Park nothing: force every pending save onto a frame slot.
(define (compiler-backend-emergency-commit-slot-form!
  [function-state : be_state.CompilerBackendFunctionState]) : unit
  (compiler-backend-emergency-commit-locs! function-state "" false false))

;; True when the bracketed text may leave the park register intact: a `call`
;; (the substring also covers `syscall`) hands control to code that is free to
;; clobber every caller-saved XMM register, so such a bracket keeps the frame
;; slot. Deliberately a plain substring test: a label that merely spells "call"
;; costs one frame slot, never correctness.
(define (compiler-backend-emergency-text-park-allowed? [text : (& text str)]) : bool
  (not (be_operand.compiler-backend-string-contains? text "call")))

(define (compiler-backend-emergency-reg-save-asm
  [reg : i64]
  [offset : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [slot : String
      (be_operand.compiler-backend-frame-offset-with-backend-state
        backend-state
        offset)]
    [reg-name : String (compiler_abi.compiler-abi-register-spelling reg)]
    (if (>= (compiler_regalloc.compiler-reg-xmm-family-index reg) 0)
      (match (be_state.compiler-backend-function-state-current-mode
        (be_state.compiler-backend-state-function-state backend-state))
        [(Scalar) (str_cat.str-cat "    movdqu " reg-name ", " slot "\n")]
        [(Avx2)
          (str_cat.str-cat
            "    vmovdqu "
            (be_operand.compiler-backend-vector-home-to-reg reg "ymm")
            ", "
            slot
            "\n")]
        [(Avx512)
          (str_cat.str-cat
            "    vmovdqu64 "
            (be_operand.compiler-backend-vector-home-to-reg reg "zmm")
            ", "
            slot
            "\n")])
      (str_cat.str-cat "    movq " reg-name ", " slot "\n"))))

(define (compiler-backend-emergency-reg-restore-asm
  [reg : i64]
  [offset : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [slot : String
      (be_operand.compiler-backend-frame-offset-with-backend-state
        backend-state
        offset)]
    [reg-name : String (compiler_abi.compiler-abi-register-spelling reg)]
    (if (>= (compiler_regalloc.compiler-reg-xmm-family-index reg) 0)
      (match (be_state.compiler-backend-function-state-current-mode
        (be_state.compiler-backend-state-function-state backend-state))
        [(Scalar) (str_cat.str-cat "    movdqu " slot ", " reg-name "\n")]
        [(Avx2)
          (str_cat.str-cat
            "    vmovdqu "
            slot
            ", "
            (be_operand.compiler-backend-vector-home-to-reg reg "ymm")
            "\n")]
        [(Avx512)
          (str_cat.str-cat
            "    vmovdqu64 "
            slot
            ", "
            (be_operand.compiler-backend-vector-home-to-reg reg "zmm")
            "\n")])
      (str_cat.str-cat "    movq " slot ", " reg-name "\n"))))

;; T1-6 (b): one pending save, at its recorded park location -- an XMM register
;; (frame-free) or the classic 64-byte frame slot.
(define (compiler-backend-emergency-entry-reg
  [function-state : be_state.CompilerBackendFunctionState]
  [index : i64]) : i64
  (array-ref
    (be_state.compiler-backend-function-scratch-i64-array
      function-state
      be_state.compiler-backend-scratch-i64-array-emergency-regs)
    index))

(define (compiler-backend-emergency-entry-save-asm
  [function-state : be_state.CompilerBackendFunctionState]
  [index : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [reg : i64 (compiler-backend-emergency-entry-reg function-state index)]
    [loc : i64
      (be_operand.compiler-backend-emergency-save-loc function-state index)]
    (cond
      [(= loc be_operand.compiler-backend-emergency-loc-elided) ""]
      [(>= loc 0)
        (str_cat.str-cat
          "    movq "
          (compiler_abi.compiler-abi-register-spelling reg)
          ", "
          (compiler_abi.compiler-abi-register-spelling loc)
          "\n")]
      [else
        (compiler-backend-emergency-reg-save-asm
          reg
          (compiler-backend-emergency-reg-offset function-state (- (- 0 loc) 1))
          backend-state)])))

(define (compiler-backend-emergency-entry-restore-asm
  [function-state : be_state.CompilerBackendFunctionState]
  [index : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [reg : i64 (compiler-backend-emergency-entry-reg function-state index)]
    [loc : i64
      (be_operand.compiler-backend-emergency-save-loc function-state index)]
    (cond
      [(= loc be_operand.compiler-backend-emergency-loc-elided) ""]
      [(>= loc 0)
        (str_cat.str-cat
          "    movq "
          (compiler_abi.compiler-abi-register-spelling loc)
          ", "
          (compiler_abi.compiler-abi-register-spelling reg)
          "\n")]
      [else
        (compiler-backend-emergency-reg-restore-asm
          reg
          (compiler-backend-emergency-reg-offset function-state (- (- 0 loc) 1))
          backend-state)])))

(define (compiler-backend-emergency-save-asm
  [function-state : be_state.CompilerBackendFunctionState]
  [index : i64]
  [count : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      (compiler-backend-emergency-entry-save-asm
        function-state
        index
        backend-state)
      (compiler-backend-emergency-save-asm
        function-state
        (+ index 1)
        count
        backend-state))))

(define (compiler-backend-emergency-restore-asm
  [function-state : be_state.CompilerBackendFunctionState]
  [index : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (< index 0)
    ""
    (str_cat.str-cat
      (compiler-backend-emergency-entry-restore-asm
        function-state
        index
        backend-state)
      (compiler-backend-emergency-restore-asm
        function-state
        (- index 1)
        backend-state))))

;; Emit the emergency restore INLINE, right after a branch's flag-setting
;; compare/test and before its conditional jumps. The scavenged scratch is dead
;; after the compare (the jumps read EFLAGS, not the register), and `movq` does
;; not touch EFLAGS, so restoring the saved value into its home here is correct and
;; flag-safe. This places the restore on a reachable path for BOTH out-edges,
;; instead of after the jumps where it is dead code on a no-fall-through branch.
;; Sets `restore-suppressed` so the enclosing emergency-wrap omits its trailing
;; restore (the save is still emitted by the wrap). Returns "" when no emergency
;; spill is pending for this branch (the common case) or when already emitted.
(define (compiler-backend-emergency-restore-before-jumps
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    (if (and
      (be_state.compiler-backend-function-scratch-bool?
        function-state
        be_state.compiler-backend-scratch-bool-emergency-pending)
      (not
        (be_state.compiler-backend-function-scratch-bool?
          function-state
          be_state.compiler-backend-scratch-bool-emergency-restore-suppressed)))
      (let
        ;; The restore is emitted BEFORE the bracketed text exists, so the park
        ;; decision cannot see it: charge frame slots.
        [_slot-form : unit
          (compiler-backend-emergency-commit-slot-form! function-state)]
        [count : i64
          (be_state.compiler-backend-function-scratch-i64
            function-state
            be_state.compiler-backend-scratch-i64-emergency-pending-count)]
        [restore-asm : String
          (compiler-backend-emergency-restore-asm
            function-state
            (- count 1)
            backend-state)]
        (be_state.compiler-backend-function-scratch-set-bool!
          function-state
          be_state.compiler-backend-scratch-bool-emergency-restore-suppressed
          true)
        restore-asm)
      "")))

(define (compiler-backend-emergency-wrap
  [head : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    (if (be_state.compiler-backend-function-scratch-bool?
      function-state
      be_state.compiler-backend-scratch-bool-emergency-pending)
      (let
        [_commit : unit
          (compiler-backend-emergency-commit-locs!
            function-state
            head
            true
            (compiler-backend-emergency-text-park-allowed? head))]
        [count : i64
          (be_state.compiler-backend-function-scratch-i64
            function-state
            be_state.compiler-backend-scratch-i64-emergency-pending-count)]
        [save-asm : String
          (compiler-backend-emergency-save-asm
            function-state
            0
            count
            backend-state)]
        [restore-asm : String
          (if (be_state.compiler-backend-function-scratch-bool?
            function-state
            be_state.compiler-backend-scratch-bool-emergency-restore-suppressed)
            ""
            (compiler-backend-emergency-restore-asm
              function-state
              (- count 1)
              backend-state))]
        (be_state.compiler-backend-function-scratch-set-bool!
          function-state
          be_state.compiler-backend-scratch-bool-emergency-pending
          false)
        (be_state.compiler-backend-function-scratch-set-i64!
          function-state
          be_state.compiler-backend-scratch-i64-emergency-pending-count
          0)
        (be_state.compiler-backend-function-scratch-set-bool!
          function-state
          be_state.compiler-backend-scratch-bool-emergency-restore-suppressed
          false)
        (str_cat.str-cat save-asm (str_cat.str-cat head restore-asm)))
      (begin
        (be_state.compiler-backend-function-scratch-set-bool!
          function-state
          be_state.compiler-backend-scratch-bool-emergency-restore-suppressed
          false)
        head))))

(define (compiler-backend-emergency-append
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [head : String]
  [backend-state : be_state.CompilerBackendState]) : unit
  (be_state.compiler-backend-asm-append
    out
    (compiler-backend-emergency-wrap head backend-state)))

;; Same wrap as `compiler-backend-emergency-wrap`, for text that is ALREADY in
;; the body buffer at [mark, len): the save is spliced in front of it and the
;; restore appended after it, producing exactly the bytes the String wrap did.
(define (compiler-backend-emergency-wrap-appended
  [out : (&mut out be_state.CompilerBackendAsmBuf)]
  [mark : i64]
  [backend-state : be_state.CompilerBackendState]) : unit
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    (if (be_state.compiler-backend-function-scratch-bool?
      function-state
      be_state.compiler-backend-scratch-bool-emergency-pending)
      (let
        ;; The bracketed bytes are already in the buffer and are not scanned
        ;; here, so this splice keeps the frame slot.
        [_slot-form : unit
          (compiler-backend-emergency-commit-slot-form! function-state)]
        [count : i64
          (be_state.compiler-backend-function-scratch-i64
            function-state
            be_state.compiler-backend-scratch-i64-emergency-pending-count)]
        [save-asm : String
          (compiler-backend-emergency-save-asm
            function-state
            0
            count
            backend-state)]
        [restore-asm : String
          (if (be_state.compiler-backend-function-scratch-bool?
            function-state
            be_state.compiler-backend-scratch-bool-emergency-restore-suppressed)
            ""
            (compiler-backend-emergency-restore-asm
              function-state
              (- count 1)
              backend-state))]
        (be_state.compiler-backend-function-scratch-set-bool!
          function-state
          be_state.compiler-backend-scratch-bool-emergency-pending
          false)
        (be_state.compiler-backend-function-scratch-set-i64!
          function-state
          be_state.compiler-backend-scratch-i64-emergency-pending-count
          0)
        (be_state.compiler-backend-function-scratch-set-bool!
          function-state
          be_state.compiler-backend-scratch-bool-emergency-restore-suppressed
          false)
        (be_state.compiler-backend-asm-buf-insert-at! out mark save-asm)
        (be_state.compiler-backend-asm-append out restore-asm))
      (begin
        (be_state.compiler-backend-function-scratch-set-bool!
          function-state
          be_state.compiler-backend-scratch-bool-emergency-restore-suppressed
          false)
        unit))))

(define (compiler-backend-emit-save-callee-reg
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [reg-id : i64]
  [idx : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (be_operand.compiler-backend-callee-needs-save?
    backend-state
    assignments
    reg-id)
    (let
      [reg : String (compiler_abi.compiler-abi-register-spelling reg-id)]
      (str_cat.str-cat
        "    movq "
        reg
        ", "
        (compiler-backend-callee-save-slot vars idx backend-state)
        "\n"))
    ""))

(define (compiler-backend-emit-restore-callee-reg
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [reg-id : i64]
  [idx : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (be_operand.compiler-backend-callee-needs-save?
    backend-state
    assignments
    reg-id)
    (let
      [reg : String (compiler_abi.compiler-abi-register-spelling reg-id)]
      (str_cat.str-cat
        "    movq "
        (compiler-backend-callee-save-slot vars idx backend-state)
        ", "
        reg
        "\n"))
    ""))

;; Pop restores are correct only when the used callee-save homes are adjacent in
;; stack order. The allocator hands out r12, r13, r14, r15, then rbx; for two or
;; more such homes, `leaq slot, %rsp` plus pops is no larger than the movq loads.
(define (compiler-backend-callee-save-pop-eligible?
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [backend-state : be_state.CompilerBackendState]) : bool
  (let
    [r12 : bool
      (be_operand.compiler-backend-callee-needs-save?
        backend-state
        assignments
        compiler_abi.compiler-reg-id-r12)]
    [r13 : bool
      (be_operand.compiler-backend-callee-needs-save?
        backend-state
        assignments
        compiler_abi.compiler-reg-id-r13)]
    [r14 : bool
      (be_operand.compiler-backend-callee-needs-save?
        backend-state
        assignments
        compiler_abi.compiler-reg-id-r14)]
    [r15 : bool
      (be_operand.compiler-backend-callee-needs-save?
        backend-state
        assignments
        compiler_abi.compiler-reg-id-r15)]
    [rbx : bool
      (be_operand.compiler-backend-callee-needs-save?
        backend-state
        assignments
        compiler_abi.compiler-reg-id-rbx)]
    ;; RBP is admitted only after FPO has removed every frame-base use.
    [rbp : bool
      (be_operand.compiler-backend-callee-needs-save?
        backend-state
        assignments
        compiler_abi.compiler-reg-id-rbp)]
    (or
      (and r12 r13 (not r14) (not r15) (not rbx) (not rbp))
      (and r12 r13 r14 (not r15) (not rbx) (not rbp))
      (and r12 r13 r14 r15 (not rbx) (not rbp))
      (and r12 r13 r14 r15 rbx (not rbp))
      (and r12 r13 r14 r15 rbx rbp))))

(define (compiler-backend-callee-save-pop-start-idx
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]) : i64
  (cond
    [(be_operand.compiler-backend-callee-needs-save?
        backend-state
        assignments
        compiler_abi.compiler-reg-id-rbp)
      5]
    [(be_operand.compiler-backend-callee-needs-save?
        backend-state
        assignments
        compiler_abi.compiler-reg-id-rbx)
      4]
    [(be_operand.compiler-backend-callee-needs-save?
        backend-state
        assignments
        compiler_abi.compiler-reg-id-r15)
      3]
    [(be_operand.compiler-backend-callee-needs-save?
        backend-state
        assignments
        compiler_abi.compiler-reg-id-r14)
      2]
    [else 1]))

(define (compiler-backend-emit-pop-callee-reg
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [reg-id : i64]) : String
  (if (be_operand.compiler-backend-callee-needs-save?
    backend-state
    assignments
    reg-id)
    (str_cat.str-cat
      "    popq "
      (compiler_abi.compiler-abi-register-spelling reg-id)
      "\n"
      "")
    ""))

(define (compiler-backend-emit-restore-callee-regs-pop
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (str_cat.str-cat
    (str_cat.str-cat
      "    leaq "
      (compiler-backend-callee-save-slot
        vars
        (compiler-backend-callee-save-pop-start-idx backend-state assignments)
        backend-state)
      ", %rsp\n")
    ;; %rbp's slot (idx 5) is the lowest address, so it pops FIRST.
    (compiler-backend-emit-pop-callee-reg
      backend-state
      assignments
      compiler_abi.compiler-reg-id-rbp)
    (compiler-backend-emit-pop-callee-reg
      backend-state
      assignments
      compiler_abi.compiler-reg-id-rbx)
    (compiler-backend-emit-pop-callee-reg
      backend-state
      assignments
      compiler_abi.compiler-reg-id-r15)
    (compiler-backend-emit-pop-callee-reg
      backend-state
      assignments
      compiler_abi.compiler-reg-id-r14)
    (compiler-backend-emit-pop-callee-reg
      backend-state
      assignments
      compiler_abi.compiler-reg-id-r13)
    (compiler-backend-emit-pop-callee-reg
      backend-state
      assignments
      compiler_abi.compiler-reg-id-r12)))

; The shared Internal GP save order includes optional FPO-only RBP last.
(define compiler-backend-callee-save-order-count : i64
  6)

(define (compiler-backend-callee-save-order-slot-index
  [k : i64]
  [_backend-state : be_state.CompilerBackendState]) : i64
  k)

(define (compiler-backend-callee-save-order-saved?
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [k : i64]
  [backend-state : be_state.CompilerBackendState]) : bool
  (and
    (>= k 0)
    (< k compiler-backend-callee-save-order-count)
    (be_operand.compiler-backend-callee-needs-save?
      backend-state
      assignments
      (be_operand.compiler-backend-callee-save-order-reg-id k))))

(define (compiler-backend-emit-save-callee-regs
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [text : String ""]
    (for [k (iterator.range 0 compiler-backend-callee-save-order-count)]
      (if (compiler-backend-callee-save-order-saved?
        assignments
        k
        backend-state)
        (set!
          text
          (str_cat.str-cat
            text
            (compiler-backend-emit-save-callee-reg
              assignments
              vars
              (be_operand.compiler-backend-callee-save-order-reg-id k)
              (compiler-backend-callee-save-order-slot-index k backend-state)
              backend-state)))
        unit))
    text))

(define (compiler-backend-emit-restore-callee-regs
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [gp : String
      (if (compiler-backend-callee-save-pop-eligible? assignments backend-state)
        (compiler-backend-emit-restore-callee-regs-pop
          assignments
          vars
          backend-state)
        (str_cat.str-cat
          (compiler-backend-emit-restore-callee-reg
            assignments
            vars
            compiler_abi.compiler-reg-id-rbp
            (compiler-backend-rbp-callee-save-slot-index backend-state)
            backend-state)
          (compiler-backend-emit-restore-callee-reg
            assignments
            vars
            compiler_abi.compiler-reg-id-rbx
            4
            backend-state)
          (compiler-backend-emit-restore-callee-reg
            assignments
            vars
            compiler_abi.compiler-reg-id-r15
            3
            backend-state)
          (compiler-backend-emit-restore-callee-reg
            assignments
            vars
            compiler_abi.compiler-reg-id-r14
            2
            backend-state)
          (compiler-backend-emit-restore-callee-reg
            assignments
            vars
            compiler_abi.compiler-reg-id-r13
            1
            backend-state)
          (compiler-backend-emit-restore-callee-reg
            assignments
            vars
            compiler_abi.compiler-reg-id-r12
            0
            backend-state)))]
    (if (be_state.compiler-backend-current-fn-win64? backend-state)
      (let
        [xmm : String
          (compiler-backend-emit-win64-xmm-callee-regs-at
            assignments
            vars
            0
            (-
              (compiler_abi.compiler-abi-callee-saved-xmm-register-count
                (Windows)
                (Internal))
              1)
            -1
            false
            backend-state)]
        (str_cat.str-cat xmm gp))
      gp)))

(define (compiler-backend-return-label
  [backend-state : be_state.CompilerBackendState]
  [source-function : i64]) : String
  (be_operand.compiler-backend-asm-label
    (be_state.compiler-backend-state-user-symbol-id
      backend-state
      source-function)
    (compiler_ir_types.compiler-ir-label "return")))

(define (compiler-backend-inline-return-tail
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (str_cat.str-cat
    (compiler-backend-emit-restore-callee-regs assignments vars backend-state)
    "    leave\n    ret\n"))

(define (compiler-backend-tail-jump-tail
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [target : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (str_cat.str-cat
    (compiler-backend-emit-restore-callee-regs assignments vars backend-state)
    (str_cat.str-cat "    leave\n    jmp " target "\n" "")))

;; Integer register moves and imm32 moves are typed machine records (#7055):
;; both routes build `compiler_machine_x64` records, which spell and encode
;; them, and no other code path writes these forms. A `movq` that names an XMM
;; register is another instruction (MOVQ xmm), whose family has not migrated.
(define (compiler-backend-machine-line [instr : mx.MachineInstr]) : String
  (mx.compiler-machine-x64-asm-line (mx.compiler-machine-x64-checked instr)))

;; `mov{l,q} %src, %dst` as a machine record when both are general-purpose
;; registers; otherwise the text of the other register class's move.
(define (compiler-backend-machine-move-line
  [width : mx.MachineWidth]
  [src : String]
  [dst : String]) : String
  (let
    [src-id : i64
      (be_operand.compiler-backend-machine-register
        (be_state.compiler-backend-global-shared-view src))]
    [dst-id : i64
      (be_operand.compiler-backend-machine-register
        (be_state.compiler-backend-global-shared-view dst))]
    (if (and
      (mx.compiler-machine-x64-gpr? src-id)
      (mx.compiler-machine-x64-gpr? dst-id))
      (compiler-backend-machine-line
        (mx.MachineInstr.MovRR width dst-id src-id))
      (match width
        [(W64) (str_cat.str-cat "    movq " src ", " dst "\n")]
        [(W32)
          (str_cat.str-cat
            "    movl "
            (be_operand.compiler-backend-reg-part src 4)
            ", "
            (be_operand.compiler-backend-reg-part dst 4)
            "\n")]))))

;; A reference to the CALLEE-SAVE slot region. The FPO push prologue absorbs
;; every such line (the rebase deletes the mov save/restore pairs and rewrites
;; the pop-run leaq), so it does not by itself keep the slot region alive; it
;; still counts as a frame reference for every reader of bit 9.
(define (compiler-backend-callee-save-frame-offset
  [state : be_state.CompilerBackendState]
  [offset : i64]) : String
  (be_state.compiler-backend-function-state-set-bool!
    (be_state.compiler-backend-state-function-state state)
    be_state.compiler-backend-function-bool-frame-slot-referenced
    true)
  (be_operand.compiler-backend-frame-offset-render state offset))

;; An allocator-rematerialised scalar still appears as a Var in the instruction
;; stream, but its defining move is intentionally suppressed. Consumers that can
;; encode an immediate directly should see through that home instead of first
;; demanding a register in which to recompute the value.
(define (compiler-backend-immediate-operand-with-assignments
  [state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]) : be_state.CompilerBackendMaybeImmediate
  (match (be_operand.compiler-backend-immediate-operand state value)
    [(Some imm) (Some imm)]
    [(No)
      (match value
        [(Var id)
          (match (be_operand.compiler-backend-emit-assignment-lookup
            state
            assignments
            id)
            [(Some location)
              (match location
                [(Remat remat)
                  (be_operand.compiler-backend-immediate-operand state remat)]
                [_ (No)])]
            [(No) (No)])]
        [_ (No)])]))

(define (compiler-backend-value-integer-zero?
  [value : compiler_ir_types.CompilerIrValue]) : bool
  ;; Compare lowering decisions stay on the IR value.  Assembly spelling is an
  ;; output of this decision and must never be consulted to make it.
  (match (be_operand.compiler-backend-value-as-i64 value)
    [(Some value) (= value 0)]
    [(None) false]))

(define (compiler-backend-value-integer-zero-with-assignments?
  [state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]) : bool
  (match (be_operand.compiler-backend-value-as-i64 value)
    [(Some found) (= found 0)]
    [(None)
      (match value
        [(Var id)
          (match (be_operand.compiler-backend-emit-assignment-lookup
            state
            assignments
            id)
            [(Some location)
              (match location
                [(Remat remat) (compiler-backend-value-integer-zero? remat)]
                [_ false])]
            [(No) false])]
        [_ false])]))

(define (compiler-backend-function-symbol-map-comment
  [index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : String
  (let
    [name-text : String
      (be_state.compiler-backend-symbol-text-index index name)]
    (if (and
      (not
        (be_state.compiler-backend-state-library-object? index.backend-state))
      (be_operand.compiler-backend-compact-function-symbol? name-text)
      (not (be_operand.compiler-backend-index-extern-provided? index name)))
      (str_cat.str-cat
        "#t "
        (be_operand.compiler-backend-function-symbol-index index name)
        " "
        (be_state.compiler-backend-user-symbol-uncached
          (be_operand.compiler-backend-symbol-leaf name-text))
        "\n")
      "")))

(define (compiler-backend-debug-file-directives
  [target : be_state.CompilerBackendTarget]
  [index : be_state.CompilerBackendSourceSpanIndex]) : String
  (if (not (compiler_ir_types.compiler-debug-info-enabled?))
    ""
    (match index.debug-files
      [(No) ""]
      [(Files _ paths count)
        (let
          [buf : text_buf.TextBuf (text_buf.empty)]
          (for [path-index (iterator.range 0 count)]
            (let
              [path-id : i64 (array-ref paths path-index)]
              [path : String
                (be_facts.compiler-backend-escape-string
                  (if (be_state.compiler-backend-target-elf? target)
                    (string.replace
                      (compiler_ir_types.compiler-debug-path-remap
                        (ci.intern-compat-state-str
                          (be_state.compiler-backend-state-intern
                            index.backend-state)
                          path-id))
                      "\\"
                      "/")
                    (compiler_ir_types.compiler-debug-path-remap
                      (ci.intern-compat-state-str
                        (be_state.compiler-backend-state-intern
                          index.backend-state)
                        path-id))))]
              [file-number : String (string.int->string (+ path-index 1))]
              (set!
                buf
                (text_buf.append
                  buf
                  (if (be_state.compiler-backend-target-coff? target)
                    (str_cat.str-cat
                      "    .cv_file "
                      file-number
                      " \""
                      path
                      "\"\n")
                    (str_cat.str-cat "    .file " file-number " \"" path "\"\n"))))))
          (text_buf.render buf))])))

(define (compiler-backend-debug-cv-function-seq-from
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [line-tables : bool]
  [index : i64]) : String
  (if (>= index functions.len)
    ""
    (match (owned_view.compiler-owned-element-view functions.slots index)
      [(Function name _ _ _ _ _)
        (match (be_operand.compiler-backend-index-function-slot
          program-index
          name)
          [(LookupFound function-id)
            (str_cat.str-cat
              (if line-tables
                (str_cat.str-cat
                  "    .cv_linetable "
                  (string.int->string function-id)
                  ", "
                  (be_operand.compiler-backend-function-symbol-index
                    program-index
                    name)
                  ", .Lcv_func_end_"
                  (string.int->string function-id))
                (str_cat.str-cat
                  "    .cv_func_id "
                  (string.int->string function-id)))
              "\n"
              (compiler-backend-debug-cv-function-seq-from
                functions
                program-index
                line-tables
                (+ index 1)))]
          [(LookupMissing)
            (compiler-backend-debug-cv-function-seq-from
              functions
              program-index
              line-tables
              (+ index 1))])])))

(define (compiler-backend-debug-cv-functions
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [line-tables : bool]) : String
  (compiler-backend-debug-cv-function-seq-from
    functions
    program-index
    line-tables
    0))

(define (compiler-backend-debug-prefix
  [target : be_state.CompilerBackendTarget]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [program-index : be_state.CompilerBackendProgramIndex]
  [span-index : be_state.CompilerBackendSourceSpanIndex]) : String
  (if (not (compiler_ir_types.compiler-debug-info-enabled?))
    ""
    (if (be_state.compiler-backend-target-coff? target)
      (str_cat.str-cat
        "    .section .debug$S,\"dr\"\n"
        "    .long 4\n"
        "    .cv_stringtable\n"
        (compiler-backend-debug-file-directives target span-index)
        (compiler-backend-debug-cv-functions functions program-index false)
        "    .text\n")
      (compiler-backend-debug-file-directives target span-index))))

(define (compiler-backend-debug-location-directive
  [target : be_state.CompilerBackendTarget]
  [program-index : be_state.CompilerBackendProgramIndex]
  [span-index : be_state.CompilerBackendSourceSpanIndex]
  [function : i64]
  [location : compiler_ir_types.CompilerMaybeSourceLocation]) : String
  (if (not (compiler_ir_types.compiler-debug-info-enabled?))
    ""
    (match location
      [(No) ""]
      [(Some (compiler_ir_types.CompilerSourceLocation path-id span))
        (let
          [file-number : i64
            (be_state.compiler-backend-debug-file-number span-index path-id)]
          [line : i64 (compiler_ast_types.ast-source-span-start-line span)]
          [column : i64 (compiler_ast_types.ast-source-span-start-col span)]
          (if (or (<= file-number 0) (<= line 0))
            ""
            (if (be_state.compiler-backend-target-coff? target)
              (match (be_operand.compiler-backend-index-function-slot
                program-index
                function)
                [(LookupFound function-id)
                  (str_cat.str-cat
                    "    .cv_loc "
                    (string.int->string function-id)
                    " "
                    (string.int->string file-number)
                    " "
                    (string.int->string line)
                    " "
                    (string.int->string column)
                    "\n")]
                [(LookupMissing) ""])
              (str_cat.str-cat
                "    .loc "
                (string.int->string file-number)
                " "
                (string.int->string line)
                " "
                (string.int->string column)
                "\n"))))]
      [_ ""])))

(define (compiler-backend-debug-function-location
  [target : be_state.CompilerBackendTarget]
  [program-index : be_state.CompilerBackendProgramIndex]
  [span-index : be_state.CompilerBackendSourceSpanIndex]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [function : i64]) : String
  (if (not (compiler_ir_types.compiler-debug-info-enabled?))
    ""
    (compiler-backend-debug-location-directive
      target
      program-index
      span-index
      function
      (compiler_ir_types.compiler-source-spans-lookup-location
        (& spans)
        (compiler_ir_types.compiler-ir-symbol-typed-id function)))))

(define (compiler-backend-debug-instr-location
  [ctx : be_state.CompilerBackendEmissionContext]
  [instr : compiler_ir_types.CompilerIrInstr]) : String
  (if (not (compiler_ir_types.compiler-debug-info-enabled?))
    ""
    (match (compiler_ir_types.compiler-source-spans-lookup-instr-location
      (& ctx.spans)
      (compiler_ir_types.compiler-ir-symbol-typed-id ctx.source-function)
      (& instr))
      [(Some location)
        (compiler-backend-debug-location-directive
          ctx.target-policy.target
          ctx.program-index
          ctx.span-index
          ctx.source-function
          (Some location))]
      [(No)
        (compiler-backend-debug-function-location
          ctx.target-policy.target
          ctx.program-index
          ctx.span-index
          ctx.spans
          ctx.source-function)])))

(define (compiler-backend-debug-trailer
  [target : be_state.CompilerBackendTarget]
  [functions : compiler_ir_types.CompilerIrFunctionSeq]
  [program-index : be_state.CompilerBackendProgramIndex]) : String
  (if (and
    (compiler_ir_types.compiler-debug-info-enabled?)
    (be_state.compiler-backend-target-coff? target))
    (str_cat.str-cat
      "    .section .debug$S,\"dr\"\n"
      "    .cv_filechecksums\n"
      (compiler-backend-debug-cv-functions functions program-index true)
      "    .text\n")
    (if (and
      (compiler_ir_types.compiler-debug-info-enabled?)
      (be_state.compiler-backend-target-elf? target))
      "    .section .text.typelisp_runtime,\"ax\"\n"
      "")))

;; Allocation-free fatal backtraces use a deliberately small, target-neutral
;; map instead of teaching the runtime to parse DWARF, CodeView, or PDB files.
;; One fixed eight-word row names a final text range and its source function.
;; The source strings live in a separate read-only section, so the row section
;; remains densely indexable and corruption checks can reject a non-multiple of
;; 64 bytes before reading it. Non-debug builds emit neither rows nor accessors:
;; compiler-driver installs `compiler-backtrace` together with debug-info, and
;; direct-object release builds therefore keep their existing section model.
(define (compiler-backend-backtrace-map-section
  [target : be_state.CompilerBackendTarget]) : String
  (if (be_state.compiler-backend-target-coff? target)
    "    .section .rdata$TLBT,\"dr\"\n"
    "    .section .typelisp_backtrace,\"a\",@progbits\n"))

;; The row travels with its call through speculative function emission and
;; cold-stub placement. Only an assembled row opens the table and marks its
;; kind as used. The two displacements are relative to their own fields.
(define (compiler-backend-abort-table-prefix
  [target : be_state.CompilerBackendTarget]) : String
  (str_cat.str-cat
    "    .macro .tl_abort_row pc, path, line, column, kind\n"
    (if (be_state.compiler-backend-target-coff? target)
      "    .pushsection .rdata$TLAS,\"dr\"\n"
      "    .pushsection .rodata.tl_abort_sites,\"a\",@progbits\n")
    "    .ifndef .L_tl_abort_table\n    .balign 4\n.L_tl_abort_table:\n    .endif\n"
    "    .long \\pc - ., \\path - ., \\line, \\column\n"
    "    .popsection\n    .set .L_tl_abort_used_\\kind, 1\n    .endm\n"))

;; Only volatile scratch registers are touched before the call. The frame
;; pointer describes both incoming stack alignments (a SysV abort-only leaf
;; can call from its red zone), and Win64 gets its own outgoing shadow space.
;; The existing runtime readers see the same four-word descriptor.
(define (compiler-backend-abort-table-trailer
  [target : be_state.CompilerBackendTarget]
  [site-count : i64]) : String
  (when (= site-count 0) (return ""))
  (let
    [windows? : bool (be_state.compiler-backend-target-coff? target)]
    [debug? : bool (compiler_ir_types.compiler-debug-info-enabled?)]
    ;; Speculative emission can leave fewer rows than sites. The assembler
    ;; guard below still requires a surviving row, so one allocated site
    ;; guarantees exactly one possible caller of the thunk.
    [scan? : bool (> site-count 1)]
    [site-reg : String
      (if windows?
        "%rcx"
        "%rdi")]
    [site-offset : i64
      (if windows?
        32
        0)]
    (str_cat.str-cat
      "    .section .text\n    .ifdef .L_tl_abort_table\n"
      (if scan?
        (str_cat.str-cat
          (if windows?
            "    .pushsection .rdata$TLAS,\"dr\"\n"
            "    .pushsection .rodata.tl_abort_sites,\"a\",@progbits\n")
          ".L_tl_abort_table_end:\n    .popsection\n")
        "")
      "    .irp kind, tl_oob_abort_at, tl_div_abort_at, tl_shift_abort_at, tl_panic_at\n"
      "    .ifdef .L_tl_abort_used_\\kind\n.L_tl_abort_\\kind:\n"
      "    leaq 1f(%rip), %r11\n    jmp .L_tl_abort_lookup\n1:\n    jmp \\kind\n"
      "    .endif\n    .endr\n"
      (if windows?
        "    .seh_proc .L_tl_abort_lookup\n.L_tl_abort_lookup:\n    pushq %rbp\n    .seh_pushreg %rbp\n    subq $64, %rsp\n    .seh_stackalloc 64\n    leaq 64(%rsp), %rbp\n    .seh_setframe %rbp, 64\n    .seh_endprologue\n    andq $-16, %rsp\n"
        (if debug?
          ".L_tl_abort_lookup:\n    .cfi_startproc\n    pushq %rbp\n    .cfi_def_cfa_offset 16\n    .cfi_offset %rbp, -16\n    movq %rsp, %rbp\n    .cfi_def_cfa_register %rbp\n    andq $-16, %rsp\n    subq $32, %rsp\n"
          ".L_tl_abort_lookup:\n    pushq %rbp\n    movq %rsp, %rbp\n    andq $-16, %rsp\n    subq $32, %rsp\n"))
      "    leaq .L_tl_abort_table(%rip), %r10\n"
      (if scan?
        (str_cat.str-cat
          "    movq 8(%rbp), %rax\n"
          "2:\n    leaq .L_tl_abort_table_end(%rip), "
          site-reg
          "\n    cmpq "
          site-reg
          ", %r10\n    jae 3f\n    movslq (%r10), "
          site-reg
          "\n    addq %r10, "
          site-reg
          "\n    cmpq %rax, "
          site-reg
          "\n    je 4f\n    addq $16, %r10\n    jmp 2b\n3:\n    ud2\n4:\n")
        "")
      "    leaq "
      (string.int->string site-offset)
      "(%rsp), "
      site-reg
      "\n    movslq 8(%r10), %rax\n    movq %rax, 16("
      site-reg
      ")\n    movslq 12(%r10), %rax\n    movq %rax, 24("
      site-reg
      ")\n    movslq 4(%r10), %rax\n"
      "    movdqu 4(%r10,%rax), %xmm0\n    movdqu %xmm0, ("
      site-reg
      ")\n    call *%r11\n    ud2\n"
      (if debug?
        ".L_tl_abort_lookup_end:\n"
        "")
      (cond
        [windows? "    .seh_endproc\n"]
        [debug? "    .cfi_endproc\n"]
        [else ""])
      (if debug?
        (str_cat.str-cat
          (compiler-backend-backtrace-map-section target)
          "    .balign 8\n    .quad .L_tl_abort_lookup\n    .quad .L_tl_abort_lookup_end\n"
          "    .quad tl_backtrace_string_data_begin\n    .quad 0\n"
          "    .quad tl_backtrace_string_data_begin\n    .quad 0\n"
          ;; An empty name and line -1 mark the abort lookup frame, which
          ;; must not consume a slot in the runtime's backtrace frame budget.
          "    .quad -1\n    .quad 0\n    .text\n")
        "")
      "    .endif\n")))

(define (compiler-backend-backtrace-string-section
  [target : be_state.CompilerBackendTarget]) : String
  (if (be_state.compiler-backend-target-coff? target)
    "    .section .rdata$TLBS,\"dr\"\n"
    "    .section .rodata.typelisp_backtrace,\"a\",@progbits\n"))

(define (compiler-backend-backtrace-map-prefix
  [target : be_state.CompilerBackendTarget]) : String
  (if (not (compiler_ir_types.compiler-debug-info-enabled?))
    ""
    (str_cat.str-cat
      (compiler-backend-backtrace-string-section target)
      "    .globl tl_backtrace_string_data_begin\ntl_backtrace_string_data_begin:\n"
      (compiler-backend-backtrace-map-section target)
      "    .balign 8\n    .globl tl_backtrace_map_data_begin\ntl_backtrace_map_data_begin:\n    .text\n")))

(define (compiler-backend-backtrace-map-trailer
  [target : be_state.CompilerBackendTarget]) : String
  (if (not (compiler_ir_types.compiler-debug-info-enabled?))
    ""
    (str_cat.str-cat
      (compiler-backend-backtrace-map-section target)
      "    .globl tl_backtrace_map_data_end\ntl_backtrace_map_data_end:\n"
      (compiler-backend-backtrace-string-section target)
      "    .globl tl_backtrace_string_data_end\ntl_backtrace_string_data_end:\n    .text\n")))

;; ABI bridges own unwind frames but no source frame. A validated map row with
;; an empty name marks that distinction without inventing a source location.
;; Both zero-length strings still point inside the bounded string section.
(define (compiler-backend-backtrace-c-entry-range
  [begin : String]
  [end : String]) : String
  (str_cat.str-cat
    end
    ":\n    .section .rdata$TLBT,\"dr\"\n    .balign 8\n    .quad "
    begin
    "\n    .quad "
    end
    "\n    .quad tl_backtrace_string_data_begin\n    .quad 0\n    .quad tl_backtrace_string_data_begin\n    .quad 0\n    .quad 0\n    .quad 0\n    .text\n"))

(define (compiler-backend-backtrace-function-id
  [program-index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : i64
  (match (be_operand.compiler-backend-index-function-slot program-index name)
    [(LookupFound function-id) function-id]
    [(LookupMissing) -1]))

(define (compiler-backend-backtrace-function-end-label
  [program-index : be_state.CompilerBackendProgramIndex]
  [name : i64]) : String
  (if (not (compiler_ir_types.compiler-debug-info-enabled?))
    ""
    (let
      [function-id : i64
        (compiler-backend-backtrace-function-id program-index name)]
      (if (< function-id 0)
        ""
        (str_cat.str-cat
          ".L_tl_backtrace_function_end_"
          (string.int->string function-id)
          ":\n")))))

(define (compiler-backend-backtrace-function-entry
  [target : be_state.CompilerBackendTarget]
  [program-index : be_state.CompilerBackendProgramIndex]
  [spans : compiler_ir_types.CompilerSourceSpans]
  [name : i64]
  [symbol : String]) : String
  (if (not (compiler_ir_types.compiler-debug-info-enabled?))
    ""
    (let
      [function-id : i64
        (compiler-backend-backtrace-function-id program-index name)]
      (if (< function-id 0)
        ""
        (let
          [name-text : String
            (be_state.compiler-backend-symbol-text-index program-index name)]
          [path : String ""]
          [line : i64 0]
          [column : i64 0]
          [_location : unit
            (match (compiler_ir_types.compiler-source-spans-lookup-location
              (& spans)
              (compiler_ir_types.compiler-ir-symbol-typed-id name))
              [(No) unit]
              [(Some location)
                (set!
                  path
                  (compiler_ir_types.compiler-debug-path-remap
                    (ci.intern-compat-state-str
                      (be_state.compiler-backend-state-intern
                        program-index.backend-state)
                      location.path-id)))
                (set!
                  line
                  (compiler_ast_types.ast-source-span-start-line location.span))
                (set!
                  column
                  (compiler_ast_types.ast-source-span-start-col location.span))])]
          [id-text : String (string.int->string function-id)]
          [name-label : String
            (str_cat.str-cat ".L_tl_backtrace_name_" id-text)]
          [path-label : String
            (str_cat.str-cat ".L_tl_backtrace_path_" id-text)]
          [end-label : String
            (str_cat.str-cat ".L_tl_backtrace_function_end_" id-text)]
          (str_cat.str-cat
            (compiler-backend-backtrace-string-section target)
            name-label
            ":\n    .ascii \""
            (be_facts.compiler-backend-escape-string
              (be_state.compiler-backend-global-shared-view name-text))
            "\"\n"
            path-label
            ":\n    .ascii \""
            (be_facts.compiler-backend-escape-string
              (be_state.compiler-backend-global-shared-view path))
            "\"\n"
            (compiler-backend-backtrace-map-section target)
            "    .balign 8\n    .quad "
            symbol
            "\n    .quad "
            end-label
            "\n    .quad "
            name-label
            "\n    .quad "
            (string.int->string (string.string-length name-text))
            "\n    .quad "
            path-label
            "\n    .quad "
            (string.int->string (string.string-length path))
            "\n    .quad "
            (string.int->string line)
            "\n    .quad "
            (string.int->string column)
            "\n    .text\n"))))))

;; Cold runtime-abort provenance for the instruction currently being emitted.
;; The descriptor itself is placed inline after the non-returning call; the
;; normal path branches over all argument setup and descriptor bytes.
(define (compiler-backend-stdlib-io-panic-name?
  [backend-state : be_state.CompilerBackendState]
  [name : i64]) : bool
  (let
    [text : String
      (be_state.compiler-backend-symbol-text-state backend-state name)]
    (or
      (string.eq text "_tl_stdlib_io_stdlib_io_panic")
      (and
        (string.eq (be_operand.compiler-backend-symbol-leaf text) "panic")
        (or
          (be_operand.compiler-backend-string-contains? text "stdlib/io.tl::")
          (be_operand.compiler-backend-string-contains? text "stdlib\\io.tl::")
          (be_operand.compiler-backend-string-contains? text "stdlib.io/"))))))

(define (compiler-backend-runtime-abort-site-instr?
  [backend-state : be_state.CompilerBackendState]
  [instr : compiler_ir_types.CompilerIrInstr]) : bool
  (match instr
    [(BoundsCheck _ _ _) true]
    [(BinOp _ op _ _ _) (compiler_ir_types.compiler-ir-binop-may-fault? (& op))]
    [(Call _ name _ _)
      (compiler-backend-stdlib-io-panic-name? backend-state name)]
    [_ false]))

(define (compiler-backend-optional-runtime-function?
  [backend-state : be_state.CompilerBackendState]
  [name : i64]) : bool
  (or
    (be_operand.compiler-backend-stdlib-runtime-function-name?
      (& (be_state.compiler-backend-symbol-text-state backend-state name)))
    (compiler-backend-stdlib-io-panic-name? backend-state name)))

(define (compiler-backend-abort-site-active?
  [backend-state : be_state.CompilerBackendState]) : bool
  (be_state.compiler-backend-function-state-bool?
    (be_state.compiler-backend-state-function-state backend-state)
    be_state.compiler-backend-function-bool-abort-site-active))

(define (compiler-backend-runtime-abort-site-install!
  [ctx : be_state.CompilerBackendEmissionContext]
  [instr : compiler_ir_types.CompilerIrInstr]) : unit
  (be_state.compiler-backend-function-state-set-bool!
    ctx.function-state
    be_state.compiler-backend-function-bool-abort-site-active
    false)
  ;; Every emitted instruction passes here, and few are abort sites. The
  ;; located setup lives in its own function so this common path keeps a
  ;; small frame.
  (when
    (compiler-backend-runtime-abort-site-instr?
      ctx.backend-state
      (be_state.compiler-backend-global-shared-view instr))
    (compiler-backend-runtime-abort-site-locate! ctx instr)))

(define (compiler-backend-runtime-abort-site-locate!
  [ctx : be_state.CompilerBackendEmissionContext]
  [instr : compiler_ir_types.CompilerIrInstr]) : unit
  (let
    [function-state : be_state.CompilerBackendFunctionState ctx.function-state]
    (match (compiler_ir_types.compiler-source-spans-lookup-instr-location
      (& ctx.spans)
      (compiler_ir_types.compiler-ir-symbol-typed-id ctx.source-function)
      (& instr))
      [(No) unit]
      [(Some location)
        (let
          [path-id : i64 location.path-id]
          [span : compiler_ast_types.AstSourceSpan location.span]
          (when
            (> path-id 0)
            (be_state.compiler-backend-function-state-set-bool!
              function-state
              be_state.compiler-backend-function-bool-abort-site-active
              true)
            (be_state.compiler-backend-function-state-set-string!
              function-state
              be_state.compiler-backend-function-string-abort-site-path
              (compiler_ir_types.compiler-debug-path-remap
                (ci.intern-compat-state-str
                  (be_state.compiler-backend-state-intern ctx.backend-state)
                  path-id)))
            (be_state.compiler-backend-function-state-set-i64!
              function-state
              be_state.compiler-backend-function-i64-abort-site-line
              (compiler_ast_types.ast-source-span-start-line span))
            (be_state.compiler-backend-function-state-set-i64!
              function-state
              be_state.compiler-backend-function-i64-abort-site-column
              (compiler_ast_types.ast-source-span-start-col span))
            (be_state.compiler-backend-function-state-set-abort-target!
              function-state
              ctx.target-policy.target)))])))

(define (compiler-backend-abort-arg-reg
  [backend-state : be_state.CompilerBackendState]
  [index : i64]) : String
  (compiler_abi.compiler-abi-gp-arg-register
    (be_state.compiler-backend-target-abi
      (be_state.compiler-backend-function-state-abort-target
        (be_state.compiler-backend-state-function-state backend-state)))
    (Platform)
    (if (> index 3)
      3
      index)))

(define (compiler-backend-abort-site-next-label
  [backend-state : be_state.CompilerBackendState]
  [suffix : String]) : String
  (let
    [counter : i64
      (be_state.compiler-backend-state-next-abort-site-counter! backend-state)]
    (str_cat.str-cat
      ".L_tl_abort_site_"
      (string.int->string counter)
      "_"
      suffix)))

(define (compiler-backend-abort-site-return-label
  [backend-state : be_state.CompilerBackendState]
  [label : String]
  [symbol : String]) : String
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [path : String
      (be_state.compiler-backend-function-state-string
        function-state
        be_state.compiler-backend-function-string-abort-site-path)]
    (str_cat.str-cat
      label
      ":\n    .tl_abort_row "
      label
      ", "
      (be_operand.compiler-backend-string-fat-label path)
      ", "
      (string.int->string
        (be_state.compiler-backend-function-state-i64
          function-state
          be_state.compiler-backend-function-i64-abort-site-line))
      ", "
      (string.int->string
        (be_state.compiler-backend-function-state-i64
          function-state
          be_state.compiler-backend-function-i64-abort-site-column))
      ", "
      symbol
      "\n")))

;; SAVE-SECOND runs before SAVE-FIRST. The top of stack is therefore the first
;; reported value and can be popped straight into ABI argument 1.
(define (compiler-backend-abort-call-three-asm
  [symbol : String]
  [suffix : String]
  [save-second : String]
  [save-first : String]
  [call-space : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [label : String
      (compiler-backend-abort-site-next-label backend-state suffix)]
    (str_cat.str-cat
      save-second
      save-first
      "    # tl_abort_operand_stage\n"
      "    popq "
      (compiler-backend-abort-arg-reg backend-state 1)
      "\n    popq "
      (compiler-backend-abort-arg-reg backend-state 2)
      "\n"
      (be_operand.compiler-backend-emit-call-space-sub call-space)
      "    call .L_tl_abort_"
      symbol
      "\n"
      (compiler-backend-abort-site-return-label backend-state label symbol)
      (be_operand.compiler-backend-emit-call-space-add call-space))))

;; Shift source-located aborts carry a fourth boolean argument indicating
;; whether the count is unsigned.  Keep this setup separate from the legacy
;; three-argument helper so all existing bounds/division/panic ABIs remain
;; byte-for-byte stable.
(define (compiler-backend-abort-call-shift-asm
  [symbol : String]
  [suffix : String]
  [save-count : String]
  [save-width : String]
  [unsigned-count? : bool]
  [call-space : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [label : String
      (compiler-backend-abort-site-next-label backend-state suffix)]
    (str_cat.str-cat
      save-width
      save-count
      "    # tl_abort_operand_stage\n"
      "    popq "
      (compiler-backend-abort-arg-reg backend-state 1)
      "\n    popq "
      (compiler-backend-abort-arg-reg backend-state 2)
      "\n    movq $"
      (if unsigned-count?
        "1"
        "0")
      ", "
      (compiler-backend-abort-arg-reg backend-state 3)
      "\n"
      (be_operand.compiler-backend-emit-call-space-sub call-space)
      "    call .L_tl_abort_"
      symbol
      "\n"
      (compiler-backend-abort-site-return-label backend-state label symbol)
      (be_operand.compiler-backend-emit-call-space-add call-space))))

(define (compiler-backend-abort-normalized-push-asm
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]
  [reg : String]) : String
  (let
    [size : i64 (be_operand.compiler-backend-type-size type-segment-bases ty)]
    [src : String
      (be_operand.compiler-backend-sized-reg
        type-segment-bases
        (be_state.compiler-backend-global-shared-view reg)
        (be_state.compiler-backend-global-shared-view ty))]
    (if (= size 8)
      (str_cat.str-cat "    pushq " reg "\n")
      (str_cat.str-cat
        "    "
        (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
          (cond [(= size 1) "movsbq"] [(= size 2) "movswq"] [else "movslq"])
          (cond [(= size 1) "movzbl"] [(= size 2) "movzwl"] [else "movl"]))
        " "
        src
        ", "
        (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
          "%r11"
          "%r11d")
        "\n    pushq %r11\n"))))

(define (compiler-backend-rewrite-panic-call
  [asm : String]
  [call-target : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (not
    (be_state.compiler-backend-function-state-bool?
      (be_state.compiler-backend-state-function-state backend-state)
      be_state.compiler-backend-function-bool-abort-site-active))
    asm
    (let
      [arg0 : String (compiler-backend-abort-arg-reg backend-state 0)]
      [arg1 : String (compiler-backend-abort-arg-reg backend-state 1)]
      [label : String
        (compiler-backend-abort-site-next-label backend-state "panic")]
      [needle : String (str_cat.str-cat "    call " call-target "\n")]
      [replacement : String
        (str_cat.str-cat
          "    movq "
          arg0
          ", "
          arg1
          "\n"
          "    call .L_tl_abort_tl_panic_at\n"
          (compiler-backend-abort-site-return-label
            backend-state
            label
            "tl_panic_at"))]
      (string.replace asm needle replacement))))

(define (compiler-backend-float-value-register
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : (& value compiler_ir_types.CompilerIrValue)]) : String
  (match value
    [(Var id)
      (match (be_operand.compiler-backend-emit-assignment-lookup
        backend-state
        assignments
        id)
        [(Some location)
          (match location
            [(Register home)
              (if (compiler_abi.compiler-abi-xmm-register-id? home)
                (compiler_abi.compiler-abi-register-spelling home)
                "")]
            [_ ""])]
        [(No) ""])]
    [_ ""]))

(define (compiler-backend-float-value-stack-address
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [backend-state : be_state.CompilerBackendState]) : String
  (match value
    [(Var id)
      (match (be_operand.compiler-backend-emit-assignment-lookup
        backend-state
        assignments
        id)
        [(Some location)
          (match location
            [(Spill offset)
              (be_operand.compiler-backend-frame-offset-with-backend-state
                backend-state
                offset)]
            [_ ""])]
        [(No)
          (be_operand.compiler-backend-slot-with-backend-state backend-state id)])]
    [_ ""]))

(define (compiler-backend-float-value-memory-operand
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [ty : (& ty compiler_ast_types.AstType)]
  [backend-state : be_state.CompilerBackendState]) : String
  (match (& value)
    [(Var _)
      (compiler-backend-float-value-stack-address
        assignments
        value
        backend-state)]
    [(Global name)
      (str_cat.str-cat
        (be_operand.compiler-backend-state-global-symbol-id backend-state name)
        "(%rip)")]
    [(F64 bits)
      (str_cat.str-cat
        (be_operand.compiler-backend-float-label ty bits)
        "(%rip)")]
    [_ ""]))

(define (compiler-backend-float-bits-gp-reg
  [type-segment-bases : i64]
  [reg : String]
  [ty : compiler_ast_types.AstType]) : String
  (if (= (be_operand.compiler-backend-type-size type-segment-bases ty) 8)
    reg
    (be_operand.compiler-backend-reg-part reg 4)))

(define (compiler-backend-float-bits-load-mnemonic
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]) : String
  (if (= (be_operand.compiler-backend-type-size type-segment-bases ty) 8)
    "movq"
    "movl"))

(define (compiler-backend-float-bits-xmm-mnemonic
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]) : String
  (if (= (be_operand.compiler-backend-type-size type-segment-bases ty) 8)
    "movq"
    "movd"))

(define (compiler-backend-emit-load-float-bits-to-gp
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [gp-reg : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [xmm-reg : String
      (compiler-backend-float-value-register backend-state assignments value)]
    [gp-part : String
      (compiler-backend-float-bits-gp-reg
        type-segment-bases
        gp-reg
        (be_state.compiler-backend-global-shared-view ty))]
    (if (not (string.eq xmm-reg ""))
      (Ok
        (str_cat.str-cat
          "    "
          (compiler-backend-float-bits-xmm-mnemonic type-segment-bases ty)
          " "
          xmm-reg
          ", "
          gp-part
          "\n"))
      (let
        [mem : String
          (compiler-backend-float-value-memory-operand
            assignments
            value
            ty
            backend-state)]
        (if (not (string.eq mem ""))
          (Ok
            (str_cat.str-cat
              "    "
              (compiler-backend-float-bits-load-mnemonic type-segment-bases ty)
              " "
              mem
              ", "
              gp-part
              "\n"))
          (Err
            (box
              (compiler_diagnostic.compiler-diagnostic-at-start
                ""
                "backend: unsupported float stack argument value"))))))))

(define (compiler-backend-float-direct-rhs-operand
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : (& ty compiler_ast_types.AstType)]
  [dst-home : (& dst-home str)]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [rhs-reg : String
      (compiler-backend-float-value-register backend-state assignments rhs)]
    (if (and (not (string.eq rhs-reg "")) (not (string.eq rhs-reg dst-home)))
      rhs-reg
      (compiler-backend-float-value-memory-operand
        assignments
        rhs
        ty
        backend-state))))

(define (compiler-backend-emit-load-i64-immediate [n : i64] [reg : String]) : String
  (let
    [line : be_state.CompilerBackendAsmBuf
      (be_state.compiler-backend-asm-buf-with-capacity
        be_state.compiler-backend-asm-line-capacity)]
    (be_operand.compiler-backend-emit-load-i64-immediate-into (&mut line) n reg)
    (be_state.compiler-backend-asm-buf-finish (& line))))

(define (compiler-backend-emit-load-typed-var-to-reg
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [id : i64]
  [ty : (& compiler_ast_types.AstType)]
  [reg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [forward-src : i64
      (be_operand.compiler-backend-forwarded-addr-of-src backend-state id)]
    ;; AddrOf forwarding suppresses the defining instruction and leaves its
    ;; allocator home uninitialized. Typed copies must therefore rematerialize
    ;; the source slot address just like the ordinary scalar loader does.
    (if (>= forward-src 0)
      (str_cat.str-cat
        "    leaq "
        (be_operand.compiler-backend-addr-of-source-slot
          assignments
          forward-src
          backend-state)
        ", "
        reg
        "\n")
      (match (be_operand.compiler-backend-emit-assignment-lookup
        backend-state
        assignments
        id)
        [(Some location)
          (match location
            ;; A whole register-group is loaded word-wise by the group
            ;; ABI paths; reaching the generic scalar load means word0's home.
            [(or (Register home) (RegisterPair home _))
              (compiler-backend-emit-load-register-to-reg
                type-segment-bases
                (compiler_abi.compiler-abi-register-spelling home)
                ty
                reg)]
            [(Spill offset)
              (compiler-backend-emit-load-memory-to-reg
                type-segment-bases
                (be_operand.compiler-backend-frame-offset-with-backend-state
                  backend-state
                  offset)
                ty
                reg)]
            ;; Rematerialise the value into `reg` (constants/addresses are i64-class,
            ;; so the immediate/leaq materialisation is width-correct for any use).
            [(Remat value)
              (be_operand.compiler-backend-load-value-asm
                (compiler_regalloc.compiler-reg-assignment-table-empty)
                value
                reg
                backend-state)])]
        [(No)
          (compiler-backend-emit-load-memory-to-reg
            type-segment-bases
            (be_operand.compiler-backend-slot-with-backend-state
              backend-state
              id)
            ty
            reg)]))))

(define (compiler-backend-address-base-register-ok?
  [home : (& home str)]
  [avoid : String]
  [allow-rbp : bool]) : bool
  ;; %rax was excluded here as a pre-pooling artifact (when %rax was the hardcoded
  ;; scratch/result reg). Now %rax is in the allocator pool, so a var homed in %rax
  ;; is a valid address base -- using it directly elides the `movq %rax,<scav>` reload
  ;; (the value-home conflict is still handled by `avoid`).
  ;;
  ;; M-G3 stage 2 (#rbp-base): a %rbp home spelled as a plain `off(%rbp)` base
  ;; would be rewritten as a frame slot by the FPO rsp-rebase pass (and mis-slot
  ;; by the peephole). GAP7: when `allow-rbp` is set, the CONST-offset caller
  ;; spells the %rbp base as the spaced form `off( %rbp)` (textually
  ;; distinct from a frame ref), so %rbp is admitted here. When it is not set
  ;; (the variable-index store caller, where the base occupies the SIB base slot
  ;; alongside the gep index), %rbp stays excluded -> staged. SIB INDEX position
  ;; (",%rbp,") is always fine -- the recognizers only match the base spelling.
  (and
    (not (string.eq home ""))
    (or allow-rbp (not (string.eq home "%rbp")))
    (if (string.eq avoid "")
      true
      (not (string.eq home avoid)))))

;; #rbp-base: filter for direct address-base candidates read straight off
;; value-scalar-register (the fused gep load/store paths) -- "" forces the
;; staged/scavenged path, exactly like a non-register home.
(define (compiler-backend-address-base-filter [home : String]) : String
  (if (string.eq home "%rbp")
    ""
    home))

(define (compiler-backend-address-base-home
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [avoid : String]
  [allow-rbp : bool]) : String
  (match value
    [(Var id)
      (if (>=
        (be_operand.compiler-backend-forwarded-addr-of-src backend-state id)
        0)
        ""
        (match (be_operand.compiler-backend-emit-assignment-lookup
          backend-state
          assignments
          id)
          [(Some location)
            (match location
              [(Register home)
                (let
                  [home-name : String
                    (compiler_abi.compiler-abi-register-spelling home)]
                  (if (compiler-backend-address-base-register-ok?
                    home-name
                    avoid
                    allow-rbp)
                    home-name
                    ""))]
              [_ ""])]
          [(No) ""]))]
    [_ ""]))

(define (compiler-backend-emit-address-base-with-avoid
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [fallback-reg : String]
  [avoid : String]
  [allow-rbp : bool]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackendAddressBase
  (let
    [home : String
      (compiler-backend-address-base-home
        backend-state
        assignments
        (be_state.compiler-backend-global-shared-view value)
        avoid
        allow-rbp)]
    (if (string.eq home "")
      (let
        [asm
          (try
            (be_operand.compiler-backend-emit-load-value
              assignments
              value
              (be_state.compiler-backend-global-shared-view fallback-reg)
              backend-state))]
        (Ok
          (be_state.CompilerBackendAddressBase
            asm
            (compiler_abi.compiler-abi-register-id-from-spelling fallback-reg))))
      (Ok
        (be_state.CompilerBackendAddressBase
          ""
          (compiler_abi.compiler-abi-register-id-from-spelling home))))))

;; The plain (avoid-free) address base is only ever consumed by CONST-offset
;; callers (store-ptr, store-to-gep const, store-ptr-pair, load-deref -- each
;; formats the returned base with copy-address / base-deref), so GAP7 admits a
;; %rbp base here (allow-rbp = true; spelled `off( %rbp)`). The variable-index
;; store caller uses emit-address-base-with-avoid with allow-rbp = false.
(define (compiler-backend-emit-address-base
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [fallback-reg : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackendAddressBase
  (compiler-backend-emit-address-base-with-avoid
    assignments
    value
    fallback-reg
    ""
    true
    backend-state))

(define (compiler-backend-emit-load-memory
  [type-segment-bases : i64]
  [addr : String]
  [ty : compiler_ast_types.AstType]) : String
  (let
    [size : i64 (be_operand.compiler-backend-type-size type-segment-bases ty)]
    (cond
      [(= size 8) (str_cat.str-cat "    movq " addr ", %rax\n")]
      [(= size 4)
        (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
          (str_cat.str-cat "    movslq " addr ", %rax\n")
          (str_cat.str-cat "    movl " addr ", %eax\n"))]
      [(= size 2)
        (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
          (str_cat.str-cat "    movswq " addr ", %rax\n")
          (str_cat.str-cat "    movzwl " addr ", %eax\n"))]
      [(= size 1)
        (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
          (str_cat.str-cat "    movsbq " addr ", %rax\n")
          (str_cat.str-cat "    movzbl " addr ", %eax\n"))]
      [else ""])))

(define (compiler-backend-emit-load-float-memory
  [addr : (& addr str)]
  [reg : (& reg str)]
  [ty : (& ty compiler_ast_types.AstType)]) : String
  (str_cat.str-cat
    "    "
    (be_operand.compiler-backend-float-move ty)
    " "
    addr
    ", "
    reg
    "\n"))

(define (compiler-backend-emit-load-memory-to-reg
  [type-segment-bases : i64]
  [addr : String]
  [ty : (& compiler_ast_types.AstType)]
  [reg : String]) : String
  (let
    [size : i64 (be_operand.compiler-backend-type-size type-segment-bases ty)]
    (cond
      [(= size 8) (str_cat.str-cat "    movq " addr ", " reg "\n")]
      [(= size 4)
        (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
          (str_cat.str-cat "    movslq " addr ", " reg "\n")
          (str_cat.str-cat
            "    movl "
            addr
            ", "
            (be_operand.compiler-backend-reg-part reg 4)
            "\n"))]
      [(= size 2)
        (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
          (str_cat.str-cat "    movswq " addr ", " reg "\n")
          (str_cat.str-cat
            "    movzwl "
            addr
            ", "
            (be_operand.compiler-backend-reg-part reg 4)
            "\n"))]
      [(= size 1)
        (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
          (str_cat.str-cat "    movsbq " addr ", " reg "\n")
          (str_cat.str-cat
            "    movzbl "
            addr
            ", "
            (be_operand.compiler-backend-reg-part reg 4)
            "\n"))]
      [else ""])))

(define (compiler-backend-emit-load-register-to-reg
  [type-segment-bases : i64]
  [src-reg : String]
  [ty : (& compiler_ast_types.AstType)]
  [dst-reg : String]) : String
  (let
    [size : i64 (be_operand.compiler-backend-type-size type-segment-bases ty)]
    (cond
      [(= size 8)
        (if (string.eq src-reg dst-reg)
          ""
          (compiler-backend-machine-move-line (W64) src-reg dst-reg))]
      [(= size 4)
        (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
          (str_cat.str-cat
            "    movslq "
            (be_operand.compiler-backend-reg-part src-reg size)
            ", "
            dst-reg
            "\n")
          (compiler-backend-machine-move-line (W32) src-reg dst-reg))]
      [(= size 2)
        (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
          (str_cat.str-cat
            "    movswq "
            (be_operand.compiler-backend-reg-part src-reg size)
            ", "
            dst-reg
            "\n")
          (str_cat.str-cat
            "    movzwl "
            (be_operand.compiler-backend-reg-part src-reg size)
            ", "
            (be_operand.compiler-backend-reg-part dst-reg 4)
            "\n"))]
      [(= size 1)
        (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
          (str_cat.str-cat
            "    movsbq "
            (be_operand.compiler-backend-reg-part src-reg size)
            ", "
            dst-reg
            "\n")
          (str_cat.str-cat
            "    movzbl "
            (be_operand.compiler-backend-reg-part src-reg size)
            ", "
            (be_operand.compiler-backend-reg-part dst-reg 4)
            "\n"))]
      [else ""])))

(define (compiler-backend-emit-store-reg-to-memory
  [type-segment-bases : i64]
  [addr : String]
  [reg : String]
  [ty : (& compiler_ast_types.AstType)]) : String
  (let
    [size : i64 (be_operand.compiler-backend-type-size type-segment-bases ty)]
    (cond
      [(= size 8) (str_cat.str-cat "    movq " reg ", " addr "\n")]
      [(= size 4)
        (str_cat.str-cat
          "    movl "
          (be_operand.compiler-backend-reg-part reg 4)
          ", "
          addr
          "\n")]
      [(= size 2)
        (str_cat.str-cat
          "    movw "
          (be_operand.compiler-backend-reg-part reg 2)
          ", "
          addr
          "\n")]
      [(= size 1)
        (str_cat.str-cat
          "    movb "
          (be_operand.compiler-backend-reg-part reg 1)
          ", "
          addr
          "\n")]
      [else ""])))

(define (compiler-backend-emit-store-xmm-to-memory
  [addr : String]
  [reg : String]
  [ty : (& compiler_ast_types.AstType)]) : String
  (str_cat.str-cat
    "    "
    (be_operand.compiler-backend-float-move ty)
    " "
    reg
    ", "
    addr
    "\n"))

(define (compiler-backend-store-immediate-mnemonic
  [type-segment-bases : i64]
  [ty : (& compiler_ast_types.AstType)]) : String
  (let
    [size : i64 (be_operand.compiler-backend-type-size type-segment-bases ty)]
    (cond
      [(= size 8) "movq"]
      [(= size 4) "movl"]
      [(= size 2) "movw"]
      [(= size 1) "movb"]
      [else ""])))

(define (compiler-backend-emit-store-immediate-to-memory
  [type-segment-bases : i64]
  [value : (& compiler_ir_types.CompilerIrValue)]
  [addr : (& addr str)]
  [ty : (& compiler_ast_types.AstType)]
  [backend-state : be_state.CompilerBackendState]) : be_state.CompilerBackendMaybeAsm
  (if (be_operand.compiler-backend-float-type? ty)
    (No)
    (match (be_operand.compiler-backend-immediate-operand backend-state value)
      [(Some imm)
        (let
          [mnemonic : String
            (compiler-backend-store-immediate-mnemonic type-segment-bases ty)]
          (if (string.eq mnemonic "")
            (No)
            (Some (str_cat.str-cat "    " mnemonic " " imm ", " addr "\n"))))]
      [(No) (No)])))

(define (compiler-backend-emit-load-immediate-to-reg
  [value : (& compiler_ir_types.CompilerIrValue)]
  [reg : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.CompilerBackendMaybeAsm
  (match (be_operand.compiler-backend-value-as-i64 value)
    [(Some n) (Some (compiler-backend-emit-load-i64-immediate n reg))]
    [(None)
      (match (be_operand.compiler-backend-immediate-operand backend-state value)
        [(Some imm) (Some (str_cat.str-cat "    movq " imm ", " reg "\n"))]
        [(No) (No)])]))

(define (compiler-backend-emit-store-immediate-to-var-home
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var-id : i64]
  [value : compiler_ir_types.CompilerIrValue]
  [backend-state : be_state.CompilerBackendState]) : be_state.CompilerBackendMaybeAsm
  (match (be_operand.compiler-backend-immediate-operand backend-state value)
    [(Some imm)
      (match (be_operand.compiler-backend-emit-assignment-lookup
        backend-state
        assignments
        var-id)
        [(Some location)
          (match location
            ;; An immediate never targets a whole register-group; unreached.
            [(or (Register home) (RegisterPair home _))
              (compiler-backend-emit-load-immediate-to-reg
                value
                (compiler_abi.compiler-abi-register-spelling home)
                backend-state)]
            [(Spill offset)
              (Some
                (str_cat.str-cat
                  "    movq "
                  imm
                  ", "
                  (be_operand.compiler-backend-frame-offset-with-backend-state
                    backend-state
                    offset)
                  "\n"))]
            ;; Rematerialised dst: this immediate store IS its (single) def, and the
            ;; value is recomputed at every use, so the store is dead -> emit nothing.
            [(Remat _) (Some "")])]
        [(No)
          (Some
            (str_cat.str-cat
              "    movq "
              imm
              ", "
              (be_operand.compiler-backend-slot-with-backend-state
                backend-state
                var-id)
              "\n"))])]
    [(No) (No)]))

;; Backend emission for multi-word register-resident aggregate groups.
;; CompilerIrInstr.Pack/CompilerIrInstr.Word are only produced once the size-16 register-resident
;; gate is enabled (the enable step adds the register-allocator group location and
;; the word-marshalling here). Until then they are never emitted, so reaching this
;; path means a lowering/backend representation mismatch -- surface it loudly
;; rather than emit silently wrong code.
;; Build the two words into the destination group's homes. Non-immediate
;; words are loaded into scavenged scratch registers first and only then moved
;; into the group's homes; immediate words are stored directly after those loads.
;; That keeps reads from the source homes ahead of any destination overwrite.
(define (compiler-backend-emit-group-word-move
  [src : (& src str)]
  [dst : (& dst str)]
  [sse? : bool]) : String
  (if (string.eq src dst)
    ""
    (let
      [cross-gp? : bool
        (and
          sse?
          (or
            (and
              (be_operand.compiler-backend-peephole-register-operand? src)
              (not (string.is-string-prefix-at src "%xmm" 0)))
            (and
              (be_operand.compiler-backend-peephole-register-operand? dst)
              (not (string.is-string-prefix-at dst "%xmm" 0)))))]
      (str_cat.str-cat
        "    "
        (if (and sse? (not cross-gp?))
          "movsd"
          "movq")
        " "
        src
        ", "
        dst
        "\n"))))

(define (compiler-backend-emit-group-word-copy
  [entry : (&mut entry be_state.CompilerBackendAsmBuf)]
  [target : be_state.CompilerBackendTarget]
  [src : String]
  [dst : String]
  [sse? : bool]
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (cond
    [(or
        (be_operand.compiler-backend-peephole-register-operand? src)
        (be_operand.compiler-backend-peephole-register-operand? dst))
      (Ok (compiler-backend-emit-group-word-move src dst sse?))]
    ;; An SSE word bound for a frame slot is an entry copy
    ;; (compiler-backend-param-entry-memory-copy): the XMM pool below would
    ;; fall back to a pinned parameter home.
    [sse?
      (be_state.compiler-backend-asm-append
        entry
        (compiler-backend-param-entry-memory-copy target src dst (& (F64))))
      (Ok "")]
    [else
      (let
        ;; Incoming parameter materialization runs before the emitted body.
        ;; The body's cursor is nevertheless left at its final instruction by
        ;; the time this text is assembled, so an ordinary `*-here` query
        ;; observes unrelated end-of-body pressure. Parameter homes are already
        ;; excluded by the caller; choose the remaining staging register
        ;; against the true pre-body occupancy (zero), as scalar stack
        ;; parameters do.
        [scratch : String
          (be_operand.compiler-backend-scavenge-pick-with-mask
            (be_state.compiler-backend-state-function-state backend-state)
            true
            0
            0
            exclude
            exclude-n
            "%r8")]
        (Ok
          (str_cat.str-cat
            (compiler-backend-emit-group-word-move src scratch false)
            (compiler-backend-emit-group-word-move scratch dst false))))]))

(define (compiler-backend-emit-load-pack-word
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [word : (& compiler_ir_types.CompilerIrValue)]
  [sse? : bool]
  [reg : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if sse?
    (let
      [ty (compiler_ast_types.AstType.F64)]
      (be_operand.compiler-backend-emit-load-float-value
        assignments
        word
        ty
        reg
        backend-state))
    (be_operand.compiler-backend-emit-load-value
      assignments
      word
      reg
      backend-state)))

(define (compiler-backend-pack-word-dst-register? [dst : (& dst str)]) : bool
  (and (> (string.string-length dst) 0) (= (string.string-ref dst 0) '%')))

(define (compiler-backend-emit-pack-word-immediate-store
  [type-segment-bases : i64]
  [word : (& compiler_ir_types.CompilerIrValue)]
  [dst : String]
  [sse? : bool]
  [backend-state : be_state.CompilerBackendState]) : be_state.CompilerBackendMaybeAsm
  (if sse?
    (No)
    (if (compiler-backend-pack-word-dst-register? dst)
      (compiler-backend-emit-load-immediate-to-reg word dst backend-state)
      (compiler-backend-emit-store-immediate-to-memory
        type-segment-bases
        word
        dst
        (& (I64))
        backend-state))))

(define (compiler-backend-emit-load-pack-word-unless-immediate
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [word : (& compiler_ir_types.CompilerIrValue)]
  [sse? : bool]
  [reg : String]
  [immediate-store : (& immediate-store be_state.CompilerBackendMaybeAsm)]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match immediate-store
    [(Some _) (Ok "")]
    [(No)
      (compiler-backend-emit-load-pack-word
        assignments
        word
        sse?
        reg
        backend-state)]))

(define (compiler-backend-emit-pack-word-store
  [scratch : String]
  [dst : String]
  [sse? : bool]
  [immediate-store : be_state.CompilerBackendMaybeAsm]) : String
  (match immediate-store
    [(Some asm) asm]
    [(No) (compiler-backend-emit-group-word-move scratch dst sse?)]))

(define (compiler-backend-emit-pack-words-direct-registers
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [w0 : (& compiler_ir_types.CompilerIrValue)]
  [w1 : (& compiler_ir_types.CompilerIrValue)]
  [dst0 : (& dst0 str)]
  [dst1 : (& dst1 str)]
  [sse0? : bool]
  [sse1? : bool]) : be_state.CompilerBackendMaybeAsm
  (let
    [src0 : String
      (be_facts.compiler-backend-value-register-home
        backend-state
        assignments
        w0)]
    [src1 : String
      (be_facts.compiler-backend-value-register-home
        backend-state
        assignments
        w1)]
    (if (and
      (compiler-backend-pack-word-dst-register? dst0)
      (compiler-backend-pack-word-dst-register? dst1)
      (not (string.eq src0 ""))
      (not (string.eq src1 ""))
      (not (string.eq src0 dst1))
      (not (string.eq src1 dst0)))
      (Some
        (str_cat.str-cat
          (compiler-backend-emit-group-word-move src0 dst0 sse0?)
          (compiler-backend-emit-group-word-move src1 dst1 sse1?)))
      (No))))

(define (compiler-backend-pack-word-source-home
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [word : (& compiler_ir_types.CompilerIrValue)]
  [sse? : bool]) : String
  (if sse?
    (compiler-backend-float-value-register backend-state assignments word)
    (be_operand.compiler-backend-value-scalar-register
      backend-state
      assignments
      word)))

(define (compiler-backend-emit-pack-words
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [w0 : (& compiler_ir_types.CompilerIrValue)]
  [w1 : (& compiler_ir_types.CompilerIrValue)]
  [dst0 : String]
  [dst1 : String]
  [sse0? : bool]
  [sse1? : bool]
  [_instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match (compiler-backend-emit-pack-words-direct-registers
    backend-state
    assignments
    w0
    w1
    dst0
    dst1
    sse0?
    sse1?)
    [(Some asm) (Ok asm)]
    [(No)
      (let
        [src1-home : String
          (compiler-backend-pack-word-source-home
            backend-state
            assignments
            w1
            sse1?)]
        ;; GAP2b: REGISTER-form dsts (a pair-homed group) must be excluded from
        ;; the scratch scavenges -- under full occupancy an EMERGENCY pick of a
        ;; dst register would wrap it in save/restore and the restore would
        ;; clobber the just-packed word. Memory-form dsts contribute "" (no-op),
        ;; leaving the stack-dst exclusions unchanged.
        [dst0-reg : String
          (if (compiler-backend-pack-word-dst-register? dst0)
            (owned_view.compiler-owned-shared-view dst0)
            "")]
        [dst1-reg : String
          (if (compiler-backend-pack-word-dst-register? dst1)
            (owned_view.compiler-owned-shared-view dst1)
            "")]
        [scratch0-exclude : (__tl_dyn-array String)
          (be_operand.compiler-backend-three-exclude
            src1-home
            (be_state.compiler-backend-global-shared-view dst0-reg)
            (be_state.compiler-backend-global-shared-view dst1-reg))]
        [scratch0 : String
          (if sse0?
            (be_operand.compiler-backend-scavenge-xmm-reg
              -1
              scratch0-exclude
              3
              "%xmm2"
              backend-state)
            (be_operand.compiler-backend-scavenge-reg-here
              scratch0-exclude
              3
              "%r8"
              backend-state))]
        [scratch1-exclude : (__tl_dyn-array String)
          (be_operand.compiler-backend-three-exclude
            (be_state.compiler-backend-global-shared-view scratch0)
            dst0-reg
            dst1-reg)]
        [scratch1 : String
          (if sse1?
            (be_operand.compiler-backend-scavenge-xmm-reg
              -1
              scratch1-exclude
              3
              "%xmm3"
              backend-state)
            (be_operand.compiler-backend-scavenge-reg-here
              scratch1-exclude
              3
              "%r9"
              backend-state))]
        [store0 : be_state.CompilerBackendMaybeAsm
          (compiler-backend-emit-pack-word-immediate-store
            type-segment-bases
            w0
            (be_state.compiler-backend-global-shared-view dst0)
            sse0?
            backend-state)]
        [store1 : be_state.CompilerBackendMaybeAsm
          (compiler-backend-emit-pack-word-immediate-store
            type-segment-bases
            w1
            (be_state.compiler-backend-global-shared-view dst1)
            sse1?
            backend-state)]
        [a0
          (try
            (compiler-backend-emit-load-pack-word-unless-immediate
              assignments
              w0
              sse0?
              (be_state.compiler-backend-global-shared-view scratch0)
              store0
              backend-state))]
        [a1
          (try
            (compiler-backend-emit-load-pack-word-unless-immediate
              assignments
              w1
              sse1?
              (be_state.compiler-backend-global-shared-view scratch1)
              store1
              backend-state))]
        (Ok
          (str_cat.str-cat
            a0
            a1
            (compiler-backend-emit-pack-word-store scratch0 dst0 sse0? store0)
            (compiler-backend-emit-pack-word-store scratch1 dst1 sse1? store1))))]))

;; An ordinary group keeps word0 in its scalar var slot. Functions without
;; address-exposed groups can retain the compact second-word region. Once any
;; group exposes its address, every word1 must instead use the canonical pair
;; region: mixing the one-word and two-word strides aliases distinct values.
(define (compiler-backend-group-legacy-word0-slot [var : i64]) : i64
  (- 0 (* 8 (+ var 1))))

;; Precondition: the function's addressable-group bitmap has no storage. A
;; retained nonempty bitmap can conservatively select canonical pair slots;
;; only zero words prove that no exposed pair can overlap this compact map.
;; Both regions are dense (compiler-backend-group-rank), so the compact map
;; needs one word per group var, not one per var.
(define (compiler-backend-group-legacy-word1-slot
  [var : i64]
  [vars : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [backend-state : be_state.CompilerBackendState]) : i64
  (-
    0
    (*
      8
      (+
        (be_operand.compiler-backend-frame-slots vars assignments backend-state)
        (+ (be_operand.compiler-backend-group-rank backend-state var) 1)))))

(define (compiler-backend-group-word1-slot
  [var : i64]
  [vars : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [backend-state : be_state.CompilerBackendState]) : i64
  (+
    (be_operand.compiler-backend-group-word0-slot
      var
      vars
      assignments
      backend-state)
    8))

(define (compiler-backend-emit-pack
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [words : compiler_ir_types.CompilerIrValueSeq]
  [ty : compiler_ast_types.AstType]
  [vars : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (= words.len 2)
    (let
      [w0 (compiler_ir_types.compiler-ir-value-seq-borrow words 0)]
      [w1 (compiler_ir_types.compiler-ir-value-seq-borrow words 1)]
      [w0-sse : bool
        (be_facts.compiler-backend-group-word-sse?
          type-segment-bases
          program-index
          ty
          0)]
      [w1-sse : bool
        (be_facts.compiler-backend-group-word-sse?
          type-segment-bases
          program-index
          ty
          1)]
      (match (be_operand.compiler-backend-emit-assignment-lookup
        backend-state
        assignments
        dst)
        [(Some location)
          (match location
            [(RegisterPair reg-a reg-b)
              (compiler-backend-emit-pack-words
                type-segment-bases
                assignments
                w0
                w1
                (compiler_abi.compiler-abi-register-spelling reg-a)
                (compiler_abi.compiler-abi-register-spelling reg-b)
                w0-sse
                w1-sse
                instr-diag
                backend-state)]
            [(Spill offset)
              ;; spilled group: words at [offset] and [offset-8].
              (compiler-backend-emit-pack-words
                type-segment-bases
                assignments
                w0
                w1
                (be_operand.compiler-backend-frame-offset-with-backend-state
                  backend-state
                  offset)
                (be_operand.compiler-backend-frame-offset-with-backend-state
                  backend-state
                  (- offset 8))
                w0-sse
                w1-sse
                instr-diag
                backend-state)]
            [_
              (be_state.compiler-backend-instr-error
                instr-diag
                "backend: CompilerIrInstr.Pack dst is not a register-group location")])]
        [(No)
          ;; stack-only: the group var lives in two stack slots.
          (let
            [dst0
              (try
                (compiler-backend-group-word-operand-with-backend-state
                  assignments
                  dst
                  0
                  vars
                  backend-state))]
            [dst1
              (try
                (compiler-backend-group-word-operand-with-backend-state
                  assignments
                  dst
                  1
                  vars
                  backend-state))]
            (compiler-backend-emit-pack-words
              type-segment-bases
              assignments
              w0
              w1
              dst0
              dst1
              w0-sse
              w1-sse
              instr-diag
              backend-state))]))
    (be_state.compiler-backend-instr-error
      instr-diag
      "backend: CompilerIrInstr.Pack requires exactly two words")))

;; Extract word `index` of a register-group value into `dst`'s home.
(define (compiler-backend-emit-word
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [index : i64]
  [ty : compiler_ast_types.AstType]
  [vars : i64]
  [instr-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match src
    [(Var src-var)
      (let
        [is-float : bool (be_operand.compiler-backend-float-type? ty)]
        (match (compiler-backend-group-word-operand-with-backend-state
          assignments
          src-var
          index
          vars
          backend-state)
          [(Ok operand)
            (Ok
              (if (be_operand.compiler-backend-peephole-register-operand?
                operand)
                (be_operand.compiler-backend-emit-store-typed-var
                  assignments
                  dst
                  operand
                  ty
                  backend-state)
                (let
                  [dst-home : String
                    (compiler-backend-var-register-home
                      backend-state
                      assignments
                      dst)]
                  ;; vreg-model: a register-homed 8-byte dst takes the spilled word
                  ;; straight into its home (movq operand, dst-home), skipping the
                  ;; temp stage + store -- this is the struct-word/param move flood
                  ;; (e.g. pair.left of a spilled register-group arg).
                  ;; An 8-byte scalar word fills the whole register; float words can
                  ;; also load directly to an XMM home. Spilled / narrow scalar dsts
                  ;; use a scavenged temp before the normal typed store.
                  (if (if (string.eq dst-home "")
                    false
                    (if is-float
                      true
                      (=
                        (be_operand.compiler-backend-type-size
                          type-segment-bases
                          ty)
                        8)))
                    (compiler-backend-emit-group-word-move
                      operand
                      dst-home
                      is-float)
                    (let
                      [no-exclude : (__tl_dyn-array String)
                        (__tl_make-array String 0)]
                      [scratch : String
                        (if is-float
                          (be_operand.compiler-backend-scavenge-xmm-reg
                            dst
                            no-exclude
                            0
                            "%xmm2"
                            backend-state)
                          (be_operand.compiler-backend-scavenge-reg
                            dst
                            no-exclude
                            0
                            "%r8"
                            backend-state))]
                      (str_cat.str-cat
                        (compiler-backend-emit-group-word-move
                          operand
                          scratch
                          is-float)
                        (be_operand.compiler-backend-emit-store-typed-var
                          assignments
                          dst
                          scratch
                          ty
                          backend-state)))))))]
          [(Err message)
            (let
              [message-view : compiler_diagnostic.CompilerDiagnostic
                (deref message)]
              (be_state.compiler-backend-instr-error
                instr-diag
                (compiler_diagnostic.compiler-diagnostic-message
                  (& message-view))))]))]
    [_
      (be_state.compiler-backend-instr-error
        instr-diag
        "backend: CompilerIrInstr.Word src must be a register-group var")]))

;; The assembly operand (register name or memory slot) holding word `index`
;; of a register-group var, regardless of how the allocator homed it. Used by the
;; call/return/param ABI to move group words to/from the ABI registers.
(define (compiler-backend-group-word-operand-with-backend-state
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var : i64]
  [index : i64]
  [vars : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (not (or (= index 0) (= index 1)))
    (Err
      (box
        (compiler_diagnostic.compiler-diagnostic-at-start
          ""
          "backend: register-group word index must be 0 or 1")))
    (match (be_operand.compiler-backend-emit-assignment-lookup
      backend-state
      assignments
      var)
      [(Some location)
        (match location
          [(RegisterPair reg-a reg-b)
            (Ok
              (compiler_abi.compiler-abi-register-spelling
                (if (= index 0)
                  reg-a
                  reg-b)))]
          [(Spill offset)
            (if (be_facts.compiler-backend-group-var? backend-state var)
              (Ok
                (be_operand.compiler-backend-frame-offset-with-backend-state
                  backend-state
                  (if (= index 0)
                    offset
                    (- offset 8))))
              (Err
                (box
                  (compiler_diagnostic.compiler-diagnostic-at-start
                    ""
                    "backend: register-group var assigned spill slot"))))]
          [(Register _)
            (Err
              (box
                (compiler_diagnostic.compiler-diagnostic-at-start
                  ""
                  "backend: register-group var assigned scalar register home")))]
          [(Remat _)
            (Err
              (box
                (compiler_diagnostic.compiler-diagnostic-at-start
                  ""
                  "backend: register-group var rematerialised")))])]
      [(No)
        (Ok
          (if (be_facts.compiler-backend-group-var? backend-state var)
            (be_operand.compiler-backend-frame-offset-with-backend-state
              backend-state
              (if (= index 0)
                (if (be_operand.compiler-backend-addressable-group-var?
                  backend-state
                  var)
                  (be_operand.compiler-backend-group-word0-slot
                    var
                    vars
                    assignments
                    backend-state)
                  (compiler-backend-group-legacy-word0-slot var))
                (if (=
                  (let
                    [function-state-live-set
                      (be_state.compiler-backend-function-state-live-set
                        (be_state.compiler-backend-state-function-state
                          backend-state)
                        be_state.compiler-backend-function-live-set-addressable-group-vars)]
                    (compiler_liveness.compiler-live-set-word-count
                      function-state-live-set))
                  0)
                  (compiler-backend-group-legacy-word1-slot
                    var
                    vars
                    assignments
                    backend-state)
                  (compiler-backend-group-word1-slot
                    var
                    vars
                    assignments
                    backend-state))))
            (be_operand.compiler-backend-slot-with-backend-state
              backend-state
              (+ var index))))])))

;; Load a group value's two words into `reg0`/`reg1` (for return -> rax:rdx
;; or an argument register pair). The value must be a group var.
(define (compiler-backend-emit-group-load
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [reg0 : (& reg0 str)]
  [reg1 : (& reg1 str)]
  [vars : i64]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match value
    [(Var v)
      (let
        [word0
          (try
            (compiler-backend-group-word-operand-with-backend-state
              assignments
              v
              0
              vars
              backend-state))]
        [word1
          (try
            (compiler-backend-group-word-operand-with-backend-state
              assignments
              v
              1
              vars
              backend-state))]
        (Ok
          (str_cat.str-cat
            (compiler-backend-emit-group-word-move
              word0
              reg0
              (be_facts.compiler-backend-group-word-sse?
                type-segment-bases
                program-index
                ty
                0))
            (compiler-backend-emit-group-word-move
              word1
              reg1
              (be_facts.compiler-backend-group-word-sse?
                type-segment-bases
                program-index
                ty
                1)))))]
    [_
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            "backend: register-group load requires var operand")))]))

;; Store a group's two words FROM `reg0`/`reg1` into the group var's home
;; (for a call result captured in rax:rdx, or an incoming group parameter).
(define (compiler-backend-emit-group-store
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var : i64]
  [reg0 : String]
  [reg1 : String]
  [vars : i64]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [word0
      (try
        (compiler-backend-group-word-operand-with-backend-state
          assignments
          var
          0
          vars
          backend-state))]
    [word1
      (try
        (compiler-backend-group-word-operand-with-backend-state
          assignments
          var
          1
          vars
          backend-state))]
    (Ok
      (str_cat.str-cat
        (compiler-backend-emit-group-word-move
          reg0
          word0
          (be_facts.compiler-backend-group-word-sse?
            type-segment-bases
            program-index
            ty
            0))
        (compiler-backend-emit-group-word-move
          reg1
          word1
          (be_facts.compiler-backend-group-word-sse?
            type-segment-bases
            program-index
            ty
            1))))))

(define (compiler-backend-group-return-reg
  [type-segment-bases : i64]
  [program-index : be_state.CompilerBackendProgramIndex]
  [ty : compiler_ast_types.AstType]
  [word-index : i64]) : String
  (if (be_facts.compiler-backend-group-word-sse?
    type-segment-bases
    program-index
    ty
    word-index)
    (if (and
      (= word-index 1)
      (be_facts.compiler-backend-group-word-sse?
        type-segment-bases
        program-index
        ty
        0))
      "%xmm1"
      "%xmm0")
    (if (and
      (= word-index 1)
      (not
        (be_facts.compiler-backend-group-word-sse?
          type-segment-bases
          program-index
          ty
          0)))
      "%rdx"
      "%rax")))

(define (compiler-backend-group-copy-xmm-scratch
  [dst : i64]
  [src0 : String]
  [src1 : String]
  [dst0 : String]
  [dst1 : String]
  [sibling : String]
  [fallback : String]
  [backend-state : be_state.CompilerBackendState]) : String
  ;; Aggregate word copies are internal compiler sequences, not ABI returns.
  ;; Select their SSE staging registers through the interval-aware scavenger so
  ;; allocator-owned XMM0/XMM1 homes cannot be silently clobbered.
  (be_operand.compiler-backend-scavenge-xmm-reg
    dst
    (__tl_make-array src0 src1 dst0 dst1 sibling)
    5
    fallback
    backend-state))

(define (compiler-backend-group-copy-gp-scratch
  [src0 : String]
  [src1 : String]
  [dst0 : String]
  [dst1 : String]
  [sibling : String]
  [fallback : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (be_operand.compiler-backend-scavenge-reg-here
    (__tl_make-array src0 src1 dst0 dst1 sibling)
    5
    fallback
    backend-state))

;; Copy an internal two-word aggregate without treating it as an ABI return.
;; Use the split-register sequence when its second register is free. A true
;; cross-word alias loads both words before either store; the
;; sequential case remains correct when scavenging must choose another register.
(define (compiler-backend-emit-group-copy
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : (& dst compiler_ir_types.CompilerIrValue)]
  [src : compiler_ir_types.CompilerIrValue]
  [vars : i64]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match src
    [(Var src-var)
      (let
        [src0
          (try
            (compiler-backend-group-word-operand-with-backend-state
              assignments
              src-var
              0
              vars
              backend-state))]
        [src1
          (try
            (compiler-backend-group-word-operand-with-backend-state
              assignments
              src-var
              1
              vars
              backend-state))]
        [dst-var : i64
          (match dst
            [(Var var) var]
            [_ -1])]
        [symbol : String
          (match dst
            [(Global name)
              (be_operand.compiler-backend-global-symbol-index
                program-index
                name)]
            [(Var _) ""]
            [_
              (return
                (Err
                  (box
                    (compiler_diagnostic.compiler-diagnostic-at-start
                      ""
                      "backend: register-group copy requires variable or global destination"))))])]
        [dst0
          (if (>= dst-var 0)
            (try
              (compiler-backend-group-word-operand-with-backend-state
                assignments
                dst-var
                0
                vars
                backend-state))
            (str_cat.str-cat symbol "(%rip)"))]
        [dst1
          (if (>= dst-var 0)
            (try
              (compiler-backend-group-word-operand-with-backend-state
                assignments
                dst-var
                1
                vars
                backend-state))
            (str_cat.str-cat symbol "+8(%rip)"))]
        [sse0? : bool
          (be_facts.compiler-backend-group-word-sse?
            type-segment-bases
            program-index
            ty
            0)]
        [sse1? : bool
          (be_facts.compiler-backend-group-word-sse?
            type-segment-bases
            program-index
            ty
            1)]
        [reg0 : String
          (if sse0?
            (compiler-backend-group-copy-xmm-scratch
              dst-var
              (be_state.compiler-backend-global-shared-view src0)
              (be_state.compiler-backend-global-shared-view src1)
              (be_state.compiler-backend-global-shared-view dst0)
              (be_state.compiler-backend-global-shared-view dst1)
              ""
              "%xmm0"
              backend-state)
            (compiler-backend-group-copy-gp-scratch
              (be_state.compiler-backend-global-shared-view src0)
              (be_state.compiler-backend-global-shared-view src1)
              (be_state.compiler-backend-global-shared-view dst0)
              (be_state.compiler-backend-global-shared-view dst1)
              ""
              "%rax"
              backend-state))]
        [reg1 : String
          (if sse1?
            (compiler-backend-group-copy-xmm-scratch
              dst-var
              (be_state.compiler-backend-global-shared-view src0)
              (be_state.compiler-backend-global-shared-view src1)
              (be_state.compiler-backend-global-shared-view dst0)
              (be_state.compiler-backend-global-shared-view dst1)
              (be_state.compiler-backend-global-shared-view reg0)
              (if sse0?
                "%xmm1"
                "%xmm0")
              backend-state)
            (compiler-backend-group-copy-gp-scratch
              (be_state.compiler-backend-global-shared-view src0)
              (be_state.compiler-backend-global-shared-view src1)
              (be_state.compiler-backend-global-shared-view dst0)
              (be_state.compiler-backend-global-shared-view dst1)
              (be_state.compiler-backend-global-shared-view reg0)
              (compiler-backend-group-return-reg
                type-segment-bases
                program-index
                ty
                1)
              backend-state))]
        (Ok
          (if (string.eq dst0 src1)
            (str_cat.str-cat
              (compiler-backend-emit-group-word-move src0 reg0 sse0?)
              (compiler-backend-emit-group-word-move src1 reg1 sse1?)
              (compiler-backend-emit-group-word-move reg0 dst0 sse0?)
              (compiler-backend-emit-group-word-move reg1 dst1 sse1?))
            (str_cat.str-cat
              (compiler-backend-emit-group-word-move src0 reg0 sse0?)
              (compiler-backend-emit-group-word-move reg0 dst0 sse0?)
              (compiler-backend-emit-group-word-move src1 reg1 sse1?)
              (compiler-backend-emit-group-word-move reg1 dst1 sse1?)))))]
    [_
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            "backend: register-group load requires var operand")))]))

(define (compiler-backend-group-stack-exclude [operand : String]) : (__tl_dyn-array
    String)
  (let
    [base : (__tl_dyn-array String)
      (compiler-backend-c-abi-stage-exclude-with "%r11")]
    (if (be_operand.compiler-backend-peephole-register-operand? operand)
      (be_operand.compiler-backend-scavenge-exclude-append
        base
        compiler-backend-c-abi-stage-exclude-count
        operand)
      base)))

(define (compiler-backend-group-stack-exclude-count [operand : (& operand str)]) : i64
  (if (be_operand.compiler-backend-peephole-register-operand? operand)
    (+ compiler-backend-c-abi-stage-exclude-count 1)
    compiler-backend-c-abi-stage-exclude-count))

(define (compiler-backend-outgoing-stack-arg-slot
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [stack-idx : i64]) : String
  (str_cat.str-cat
    (string.int->string
      (be_facts.compiler-backend-outgoing-stack-arg-offset
        target
        convention
        stack-idx))
    "(%rsp)"
    ""))

(define (compiler-backend-emit-group-stack-word-copy
  [operand : String]
  [scratch : (& scratch str)]
  [slot : String]) : String
  (str_cat.str-cat
    (compiler-backend-emit-group-word-move operand scratch false)
    (compiler-backend-emit-group-word-move scratch slot false)))

;; Push a group call-arg's two words to the outgoing stack frame at
;; consecutive slots (word0 -> stack-idx, word1 -> stack-idx+1), bit-copying
;; each eightbyte through a scavenged GP register so no in-flight arg is clobbered.
(define (compiler-backend-emit-group-stack-arg
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [stack-idx : i64]
  [vars : i64]
  [_ty : compiler_ast_types.AstType]
  [_program-index : be_state.CompilerBackendProgramIndex]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match value
    [(Var v)
      (let
        [word0
          (try
            (compiler-backend-group-word-operand-with-backend-state
              assignments
              v
              0
              vars
              backend-state))]
        [word1
          (try
            (compiler-backend-group-word-operand-with-backend-state
              assignments
              v
              1
              vars
              backend-state))]
        [scratch : String
          (be_operand.compiler-backend-scavenge-reg-here
            (compiler-backend-group-stack-exclude
              (be_state.compiler-backend-global-shared-view word1))
            (compiler-backend-group-stack-exclude-count word1)
            "%r10"
            backend-state)]
        (Ok
          (str_cat.str-cat
            (compiler-backend-emit-group-stack-word-copy
              word0
              scratch
              (compiler-backend-outgoing-stack-arg-slot
                target
                convention
                stack-idx))
            (compiler-backend-emit-group-stack-word-copy
              word1
              scratch
              (compiler-backend-outgoing-stack-arg-slot
                target
                convention
                (+ stack-idx 1))))))]
    [_
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            "backend: register-group stack argument requires var operand")))]))

(define (compiler-backend-group-word-arg-reg
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [sse? : bool]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]) : be_state.ResultBackendReg
  (if sse?
    (be_facts.compiler-backend-target-float-arg-reg-for-banks
      target
      convention
      float-idx
      position)
    (be_facts.compiler-backend-target-arg-reg-for-banks
      target
      convention
      int-idx
      position)))

;; The staging register for one value written into an outgoing (or tail) stack
;; argument slot, and for an indirect call's final target load. Both follow
;; argument marshalling, so the pick must not clobber any placed argument: the
;; pooled caller-arg candidates stay unavailable and %r11 is kept for ABI and
;; runtime clobber semantics.
(define (compiler-backend-stack-call-arg-stage
  [backend-state : be_state.CompilerBackendState]) : String
  (be_operand.compiler-backend-scavenge-reg-here
    (compiler-backend-c-abi-stage-exclude-with "%r11")
    compiler-backend-c-abi-stage-exclude-count
    "%r10"
    backend-state))

(define (compiler-backend-emit-group-word-stack-arg
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [word-index : i64]
  [stack-idx : i64]
  [vars : i64]
  [_ty : compiler_ast_types.AstType]
  [_program-index : be_state.CompilerBackendProgramIndex]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match value
    [(Var v)
      (let
        [scratch : String (compiler-backend-stack-call-arg-stage backend-state)]
        [operand
          (try
            (compiler-backend-group-word-operand-with-backend-state
              assignments
              v
              word-index
              vars
              backend-state))]
        (Ok
          (compiler-backend-emit-group-stack-word-copy
            operand
            scratch
            (compiler-backend-outgoing-stack-arg-slot
              target
              convention
              stack-idx))))]
    [_
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            "backend: register-group call argument requires var operand")))]))

(define (compiler-backend-emit-group-word-call-arg
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [word-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]
  [vars : i64]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [func-diag : compiler_diagnostic.CompilerDiagnostic]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [sse? : bool
      (be_facts.compiler-backend-group-word-sse?
        type-segment-bases
        program-index
        ty
        word-index)]
    (if (compiler-backend-stack-call-arg-for-banks?
      target
      convention
      sse?
      int-idx
      float-idx
      position)
      (compiler-backend-emit-group-word-stack-arg
        target
        convention
        assignments
        value
        word-index
        stack-idx
        vars
        ty
        program-index
        backend-state)
      (match (compiler-backend-group-word-arg-reg
        target
        convention
        sse?
        int-idx
        float-idx
        position)
        [(Ok reg)
          (match value
            [(Var v)
              (let
                [operand
                  (try
                    (compiler-backend-group-word-operand-with-backend-state
                      assignments
                      v
                      word-index
                      vars
                      backend-state))]
                (Ok (compiler-backend-emit-group-word-move operand reg sse?)))]
            [_
              (be_state.compiler-backend-instr-error
                func-diag
                "backend: register-group call argument requires var operand")])]
        [(Err message)
          (be_state.compiler-backend-instr-error func-diag message)]))))

(define (compiler-backend-emit-group-word-store
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var : i64]
  [word-index : i64]
  [reg : String]
  [vars : i64]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [operand
      (try
        (compiler-backend-group-word-operand-with-backend-state
          assignments
          var
          word-index
          vars
          backend-state))]
    (Ok
      (compiler-backend-emit-group-word-move
        reg
        operand
        (be_facts.compiler-backend-group-word-sse?
          type-segment-bases
          program-index
          ty
          word-index)))))

(define (compiler-backend-emit-group-word-stack-param
  [entry : (&mut entry be_state.CompilerBackendAsmBuf)]
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var : i64]
  [word-index : i64]
  [stack-idx : i64]
  [vars : i64]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [dst
      (try
        (compiler-backend-group-word-operand-with-backend-state
          assignments
          var
          word-index
          vars
          backend-state))]
    (compiler-backend-emit-group-word-copy
      entry
      target
      (be_operand.compiler-backend-frame-offset-with-backend-state
        backend-state
        (be_facts.compiler-backend-incoming-stack-arg-offset target stack-idx))
      dst
      (be_facts.compiler-backend-group-word-sse?
        type-segment-bases
        program-index
        ty
        word-index)
      exclude
      exclude-n
      backend-state)))

(define (compiler-backend-emit-group-word-param
  [entry : (&mut entry be_state.CompilerBackendAsmBuf)]
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var : i64]
  [word-index : i64]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]
  [stack-idx : i64]
  [vars : i64]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [sse? : bool
      (be_facts.compiler-backend-group-word-sse?
        type-segment-bases
        program-index
        ty
        word-index)]
    (if (compiler-backend-stack-call-arg-for-banks?
      target
      (Internal)
      sse?
      int-idx
      float-idx
      position)
      (compiler-backend-emit-group-word-stack-param
        entry
        type-segment-bases
        target
        assignments
        var
        word-index
        stack-idx
        vars
        ty
        program-index
        exclude
        exclude-n
        backend-state)
      (match (compiler-backend-group-word-arg-reg
        target
        (Internal)
        sse?
        int-idx
        float-idx
        position)
        [(Ok reg)
          (compiler-backend-emit-group-word-store
            type-segment-bases
            assignments
            var
            word-index
            reg
            vars
            ty
            program-index
            backend-state)]
        [(Err _)
          (Err
            (box
              (compiler_diagnostic.compiler-diagnostic-at-start
                ""
                "backend: too many params")))]))))

(define (compiler-backend-emit-load-typed-value
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (be_operand.compiler-backend-float-type? ty)
    (match (& value)
      [(Global name)
        (Ok
          (str_cat.str-cat
            "    "
            (be_operand.compiler-backend-float-move ty)
            " "
            (be_operand.compiler-backend-global-symbol-index program-index name)
            "(%rip), "
            "%xmm0"
            "\n"))]
      [_
        (be_operand.compiler-backend-emit-load-float-value
          assignments
          value
          ty
          "%xmm0"
          backend-state)])
    (match (& value)
      [(Var id)
        (Ok
          (compiler-backend-emit-load-typed-var-to-reg
            type-segment-bases
            assignments
            id
            ty
            "%rax"
            backend-state))]
      [(Global name)
        (if (be_state.compiler-backend-inline-aggregate-global?
          program-index.backend-state
          name)
          (Ok
            (str_cat.str-cat
              "    leaq "
              (be_operand.compiler-backend-global-symbol-index
                program-index
                name)
              "(%rip), %rax\n"
              ""))
          (Ok
            (compiler-backend-emit-load-memory
              type-segment-bases
              (str_cat.str-cat
                (be_operand.compiler-backend-global-symbol-index
                  program-index
                  name)
                "(%rip)"
                "")
              ty)))]
      [(GlobalAddr name)
        (Ok
          (str_cat.str-cat
            "    leaq "
            (be_facts.compiler-backend-function-or-global-addr-symbol
              program-index
              name)
            "(%rip), %rax\n"
            ""
            ""))]
      [_
        (be_operand.compiler-backend-emit-load-value
          assignments
          value
          "%rax"
          backend-state)])))

(define (compiler-backend-emit-load-typed-value-to-reg
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : (& compiler_ir_types.CompilerIrValue)]
  [ty : (& compiler_ast_types.AstType)]
  [reg : String]
  [program-index : be_state.CompilerBackendProgramIndex]) : be_state.ResultCompilerBackend
  (if (be_operand.compiler-backend-float-type? ty)
    (match value
      [(Global name)
        (Ok
          (str_cat.str-cat
            "    "
            (be_operand.compiler-backend-float-move ty)
            " "
            (be_operand.compiler-backend-global-symbol-index program-index name)
            "(%rip), "
            reg
            "\n"))]
      [_
        (be_operand.compiler-backend-emit-load-float-value
          assignments
          value
          ty
          reg
          program-index.backend-state)])
    (match value
      [(Var id)
        (Ok
          (compiler-backend-emit-load-typed-var-to-reg
            type-segment-bases
            assignments
            id
            ty
            reg
            program-index.backend-state))]
      [(Global name)
        (if (be_state.compiler-backend-inline-aggregate-global?
          program-index.backend-state
          name)
          (Ok
            (str_cat.str-cat
              "    leaq "
              (be_operand.compiler-backend-global-symbol-index
                program-index
                name)
              "(%rip), "
              reg
              "\n"))
          (Ok
            (compiler-backend-emit-load-memory-to-reg
              type-segment-bases
              (str_cat.str-cat
                (be_operand.compiler-backend-global-symbol-index
                  program-index
                  name)
                "(%rip)"
                "")
              ty
              reg)))]
      [(GlobalAddr name)
        (Ok
          (str_cat.str-cat
            "    leaq "
            (be_facts.compiler-backend-function-or-global-addr-symbol
              program-index
              name)
            "(%rip), "
            reg
            "\n"))]
      [_
        (be_operand.compiler-backend-emit-load-value
          assignments
          value
          reg
          program-index.backend-state)])))

(define (compiler-backend-binop-bit-or-shift?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]) : bool
  (match op
    [(or (BitAnd) (BitOr) (BitXor) (Shl _) (Shr _)) true]
    [_ false]))

(define (compiler-backend-missing-compare-operand-ty
  [result-ty : compiler_ast_types.AstType]) : compiler_ast_types.AstType
  (match (& result-ty)
    [(Bool) (I64)]
    [_ result-ty]))

(define (compiler-backend-binop-operand-ty
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [result-ty : compiler_ast_types.AstType]) : compiler_ast_types.AstType
  (if (compiler_ir_types.compiler-ir-binop-compare? (& op))
    ;; New comparison IR records the operand type directly. Keep the old Bool
    ;; inference fallback for hand-authored optimizer/backend fixtures while
    ;; they migrate; production lowering must never depend on it.
    (if (match (& result-ty)
      [(Bool) true]
      [_ false])
      (match (be_facts.compiler-backend-value-type
        types
        (be_state.compiler-backend-global-shared-view global-types)
        lhs)
        [(Some ty) ty]
        [(No)
          (match (be_facts.compiler-backend-value-type types global-types rhs)
            [(Some ty) ty]
            [(No) (compiler-backend-missing-compare-operand-ty result-ty)])])
      result-ty)
    (if (compiler-backend-binop-bit-or-shift? op)
      ;; Shifts carry their lhs/result type in the BinOp field.  In
      ;; particular, a literal lhs is represented as I64 regardless of its
      ;; source cast, so recovering the type from the value would turn a U64
      ;; shift into a signed/arithmetic operation after propagation.
      (match op
        [(or (Shl _) (Shr _)) result-ty]
        [_
          (match (be_facts.compiler-backend-value-type types global-types lhs)
            [(Some ty) ty]
            [(No) result-ty])])
      result-ty)))

(define (compiler-backend-value-float?
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [value : (& compiler_ir_types.CompilerIrValue)]) : bool
  (match value
    [(F64 _) true]
    [(Var id)
      (match (compiler_regalloc.compiler-reg-var-types-lookup types id)
        [(Some ty) (be_operand.compiler-backend-float-type? ty)]
        [(No) false])]
    [(Global name)
      (match (be_facts.compiler-backend-global-type-lookup global-types name)
        [(Some ty) (be_operand.compiler-backend-float-type? ty)]
        [(No) false])]
    [_ false]))

;; True when a binary op operates on floating-point values (f32 OR f64), so it
;; must use the scalar-SSE path (xmm registers, addss/addsd, ucomiss/ucomisd)
;; instead of the integer path. The operand precision is recovered separately
;; via compiler-backend-binop-operand-ty.
(define (compiler-backend-binop-f64?
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [lhs : (& compiler_ir_types.CompilerIrValue)]
  [rhs : (& compiler_ir_types.CompilerIrValue)]
  [ty : (& ty compiler_ast_types.AstType)]) : bool
  (if (be_operand.compiler-backend-float-type? ty)
    true
    (if (compiler-backend-value-float?
      types
      (be_state.compiler-backend-global-shared-view global-types)
      lhs)
      true
      (compiler-backend-value-float? types global-types rhs))))

;; A small nonnegative mask makes both the full result and the flags agree
;; at the narrower width. Keep TEST below bit 7 when using its byte form.
(define (compiler-backend-nonnegative-mask [imm : (& imm str)]) : i64
  (let
    [len : i64 (string.string-length imm)]
    [value : i64 0]
    (when
      (or (< len 2) (> len 11) (!= (string.string-ref imm 0) '$'))
      (return (- 0 1)))
    (for [index (iterator.range 1 len)]
      (let
        [digit : i64 (- (cast (string.string-ref imm index) : i64) 48)]
        (when (or (< digit 0) (> digit 9)) (return (- 0 1)))
        (set! value (+ (* value 10) digit))))
    (if (<= value 2147483647)
      value
      (- 0 1))))

(define (compiler-backend-binop-reg-asm
  [type-segment-bases : i64]
  [mnemonic : String]
  [ty : compiler_ast_types.AstType]
  [rhs : (& rhs str)]
  [lhs : String]) : String
  (let
    [suffix : String
      (be_operand.compiler-backend-int-instruction-suffix type-segment-bases ty)]
    [test? : bool (string.eq mnemonic "test")]
    [mask : i64
      (if (and
        (string.eq suffix "q")
        (or test? (string.eq mnemonic "and"))
        (>= (string.string-length lhs) 3)
        (<= (string.string-length lhs) 4)
        (= (string.string-ref lhs 0) '%')
        (= (string.string-ref lhs 1) 'r')
        (not (string.eq lhs "%rsp")))
        (compiler-backend-nonnegative-mask rhs)
        (- 0 1))]
    [byte? : bool (and test? (<= 0 mask) (<= mask 127))]
    [operand : String
      (if (>= mask 0)
        (be_operand.compiler-backend-reg-part
          lhs
          (if byte?
            1
            4))
        lhs)]
    (str_cat.str-cat
      (str_cat.str-cat
        "    "
        mnemonic
        (cond [byte? "b"] [(>= mask 0) "l"] [else suffix])
        " "
        rhs)
      (str_cat.str-cat ", " operand "\n"))))

(define (compiler-backend-binop-cmp-set-asm
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]
  [rhs : String]
  [lhs : String]
  [setcc : String]
  [result-reg : String]) : String
  (let
    [flags : String
      (str_cat.str-cat
        "    cmp"
        (be_operand.compiler-backend-int-instruction-suffix
          type-segment-bases
          ty)
        " "
        rhs
        ", "
        lhs
        "\n")]
    (str_cat.str-cat
      flags
      (str_cat.str-cat
        "    "
        setcc
        " "
        (be_operand.compiler-backend-reg-part (string.copy result-reg) 1)
        "\n    movzbl "
        (be_operand.compiler-backend-reg-part (string.copy result-reg) 1)
        ", "
        (be_operand.compiler-backend-reg-part (string.copy result-reg) 4)
        "\n"))))

(define (compiler-backend-binop-cmp-set-reg-asm
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]
  [rhs : String]
  [lhs : String]
  [setcc : String]
  [dst-reg : String]) : String
  (str_cat.str-cat
    (be_operand.compiler-backend-binop-cmp-reg-asm
      type-segment-bases
      ty
      rhs
      lhs)
    (str_cat.str-cat
      "    "
      setcc
      " "
      (be_operand.compiler-backend-reg-part (string.copy dst-reg) 1)
      "\n    movzbl "
      (be_operand.compiler-backend-reg-part (string.copy dst-reg) 1)
      ", "
      (be_operand.compiler-backend-reg-part (string.copy dst-reg) 4)
      "\n")))

(define (compiler-backend-binop-compare-flags-reg-asm
  [type-segment-bases : i64]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [ty : compiler_ast_types.AstType]
  [rhs : String]
  [lhs : String]) : String
  (if (be_facts.compiler-backend-bit-test-op? op)
    (compiler-backend-binop-reg-asm type-segment-bases "test" ty rhs lhs)
    (be_operand.compiler-backend-binop-cmp-reg-asm
      type-segment-bases
      ty
      rhs
      lhs)))

(define (compiler-backend-binop-compare-set-reg-asm
  [type-segment-bases : i64]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [ty : compiler_ast_types.AstType]
  [rhs : String]
  [lhs : String]
  [dst-reg : (& dst-reg str)]) : String
  (str_cat.str-cat
    (compiler-backend-binop-compare-flags-reg-asm
      type-segment-bases
      op
      (be_state.compiler-backend-global-shared-view ty)
      rhs
      lhs)
    (str_cat.str-cat
      "    "
      (compiler-backend-compare-setcc type-segment-bases op ty)
      " "
      (be_operand.compiler-backend-reg-part (string.copy dst-reg) 1)
      "\n    movzbl "
      (be_operand.compiler-backend-reg-part (string.copy dst-reg) 1)
      ", "
      (be_operand.compiler-backend-reg-part (string.copy dst-reg) 4)
      "\n")))

(define (compiler-backend-binop-test-zero-reg-asm
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]
  [reg : String]
  [setcc : String]) : String
  (let
    [lhs : String
      (be_operand.compiler-backend-sized-reg
        type-segment-bases
        (be_state.compiler-backend-global-shared-view reg)
        (be_state.compiler-backend-global-shared-view ty))]
    (str_cat.str-cat
      (compiler-backend-binop-reg-asm
        type-segment-bases
        "test"
        ty
        (be_state.compiler-backend-global-shared-view lhs)
        lhs)
      (str_cat.str-cat
        "    "
        setcc
        " "
        (be_operand.compiler-backend-reg-part (string.copy reg) 1)
        "\n    movzbl "
        (be_operand.compiler-backend-reg-part (string.copy reg) 1)
        ", "
        (be_operand.compiler-backend-reg-part (string.copy reg) 4)
        "\n"))))

(define (compiler-backend-compare-setcc
  [type-segment-bases : i64]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [ty : compiler_ast_types.AstType]) : String
  (match op
    [(or (Eq) (BitTestEq)) "sete"]
    [(or (Ne) (BitTestNe)) "setne"]
    [(Lt)
      (if (be_operand.compiler-backend-unsigned-rel-ty? type-segment-bases ty)
        "setb"
        "setl")]
    [(Le)
      (if (be_operand.compiler-backend-unsigned-rel-ty? type-segment-bases ty)
        "setbe"
        "setle")]
    [(Gt)
      (if (be_operand.compiler-backend-unsigned-rel-ty? type-segment-bases ty)
        "seta"
        "setg")]
    [(Ge)
      (if (be_operand.compiler-backend-unsigned-rel-ty? type-segment-bases ty)
        "setae"
        "setge")]
    [_ ""]))

;; M-F: absolute loads take the compact spelling when the value fits a signed
;; 32-bit immediate (movl/movq via emit-load-i64-immediate; the xorl-for-zero
;; case never reaches here -- every divmod caller filters zero first, and flags
;; are never live across an emitted op). `movabsq` in the output is therefore
;; textually reserved for genuine 64-bit constants.
(define (compiler-backend-emit-load-i64-absolute [n : i64] [reg : String]) : String
  (if (and (>= n (- 0 2147483648)) (<= n 4294967295))
    (compiler-backend-emit-load-i64-immediate n reg)
    (str_cat.str-cat "    movabsq $" (string.int->string n) ", " reg "\n")))

(define (compiler-backend-div-zero-guard-asm
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]
  [divisor-reg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [rhs : String
      (be_operand.compiler-backend-sized-reg
        type-segment-bases
        (be_state.compiler-backend-global-shared-view divisor-reg)
        (be_state.compiler-backend-global-shared-view ty))]
    (str_cat.str-cat
      (compiler-backend-binop-reg-asm
        type-segment-bases
        "test"
        (be_state.compiler-backend-global-shared-view ty)
        (be_state.compiler-backend-global-shared-view rhs)
        rhs)
      (if (compiler-backend-abort-site-active? backend-state)
        (str_cat.str-cat
          "    jne 1f\n"
          (compiler-backend-abort-call-three-asm
            "tl_div_abort_at"
            "div_zero"
            (compiler-backend-abort-normalized-push-asm
              type-segment-bases
              (be_state.compiler-backend-global-shared-view ty)
              divisor-reg)
            (compiler-backend-abort-normalized-push-asm
              type-segment-bases
              ty
              "%rax")
            0
            backend-state)
          "1:\n")
        "    jne 1f\n    call tl_div_abort\n1:\n"))))

(define (compiler-backend-div-overflow-guard-asm
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]
  [divisor-reg : String]
  [_planned-min : String]
  [_planned-neg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
    (let
      [suffix : String
        (be_operand.compiler-backend-int-instruction-suffix
          type-segment-bases
          (be_state.compiler-backend-global-shared-view ty))]
      [lhs : String
        (be_operand.compiler-backend-sized-reg
          type-segment-bases
          "%rax"
          (be_state.compiler-backend-global-shared-view ty))]
      [rhs : String
        (be_operand.compiler-backend-sized-reg
          type-segment-bases
          (be_state.compiler-backend-global-shared-view divisor-reg)
          (be_state.compiler-backend-global-shared-view ty))]
      ;; CMP computes lhs - 1 without changing lhs. At the operand's signed
      ;; width this sets OF exactly when lhs is INT_MIN. The only overflowing
      ;; signed quotient is INT_MIN / -1, so two immediate compares prove the
      ;; same condition without materializing either constant in a scratch
      ;; register. The zero guard still runs first, and both operands survive
      ;; for the original source-located overflow diagnostic.
      (str_cat.str-cat
        "    cmp"
        suffix
        " $1, "
        lhs
        "\n    jno 1f\n    cmp"
        suffix
        " $-1, "
        rhs
        (if (compiler-backend-abort-site-active? backend-state)
          (str_cat.str-cat
            "\n    jne 1f\n"
            (compiler-backend-abort-call-three-asm
              "tl_div_abort_at"
              "div_overflow"
              (compiler-backend-abort-normalized-push-asm
                type-segment-bases
                (be_state.compiler-backend-global-shared-view ty)
                divisor-reg)
              (compiler-backend-abort-normalized-push-asm
                type-segment-bases
                ty
                "%rax")
              0
              backend-state)
            "1:\n")
          "\n    jne 1f\n    call tl_div_abort\n1:\n")))
    ""))

(define (compiler-backend-divmod-guard-asm
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]
  [divisor-reg : String]
  [planned-min : String]
  [planned-neg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (str_cat.str-cat
    (compiler-backend-div-zero-guard-asm
      type-segment-bases
      (be_state.compiler-backend-global-shared-view ty)
      (be_state.compiler-backend-global-shared-view divisor-reg)
      backend-state)
    (compiler-backend-div-overflow-guard-asm
      type-segment-bases
      ty
      divisor-reg
      planned-min
      planned-neg
      backend-state)))

(define (compiler-backend-binop-divmod-core-asm
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]
  [want-remainder : bool]
  [divisor-reg : String]) : String
  (let
    [size : i64 (be_operand.compiler-backend-type-size type-segment-bases ty)]
    [signed : bool
      (be_facts.compiler-backend-type-signed? type-segment-bases ty)]
    [divisor : String
      (be_operand.compiler-backend-sized-reg type-segment-bases divisor-reg ty)]
    (cond
      [(= size 1)
        (str_cat.str-cat
          (if signed
            (str_cat.str-cat "    cbw\n    idivb " divisor "\n")
            (str_cat.str-cat "    andw $0x00ff, %ax\n    divb " divisor "\n"))
          (if want-remainder
            "    movb %ah, %al\n"
            ""))]
      [(= size 2)
        (str_cat.str-cat
          (if signed
            (str_cat.str-cat "    cwd\n    idivw " divisor "\n")
            (str_cat.str-cat "    xorw %dx, %dx\n    divw " divisor "\n"))
          (if want-remainder
            "    movw %dx, %ax\n"
            ""))]
      [(= size 4)
        (str_cat.str-cat
          (if signed
            (str_cat.str-cat "    cdq\n    idivl " divisor "\n")
            (str_cat.str-cat "    xorl %edx, %edx\n    divl " divisor "\n"))
          (if want-remainder
            "    movl %edx, %eax\n"
            ""))]
      [else
        (str_cat.str-cat
          (if signed
            (str_cat.str-cat "    cqto\n    idivq " divisor "\n")
            (str_cat.str-cat "    xorq %rdx, %rdx\n    divq " divisor "\n"))
          (if want-remainder
            "    movq %rdx, %rax\n"
            ""))])))

(define (compiler-backend-binop-divmod-asm
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]
  [want-remainder : bool]
  [divisor-reg : String]
  [planned-min : String]
  [planned-neg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (str_cat.str-cat
    (compiler-backend-divmod-guard-asm
      type-segment-bases
      (be_state.compiler-backend-global-shared-view ty)
      (be_state.compiler-backend-global-shared-view divisor-reg)
      planned-min
      planned-neg
      backend-state)
    (compiler-backend-binop-divmod-core-asm
      type-segment-bases
      ty
      want-remainder
      divisor-reg)))

(define (compiler-backend-emit-load-u64-absolute [n : u64] [reg : String]) : String
  (compiler-backend-emit-load-i64-absolute (cast n : i64) reg))

;; Test bit 63 directly instead of `(>= n 2^63)`. The unsigned compare against a
;; constant whose own bit 63 is set is miscompiled by the opt2 pipeline when this
;; helper is inlined into the magic-division codegen below: the opt2-built
;; compiler then treated `0x6666666666666667` (signed-/10 magic, bit 63 clear) as
;; high-bit-set and emitted a spurious "add dividend back" correction, corrupting
;; every constant `/`,`%` in the release self-build (garbled int formatting).
;; A bit-test (`!= 0`) is sign-agnostic and lowers identically at every
;; opt level, so it dodges the bad rewrite while staying provably equivalent.
(define (compiler-backend-u64-high-bit? [n : u64]) : bool
  (not (= (bit-and n (shl (cast 1 : u64) 63)) (cast 0 : u64))))

(define (compiler-backend-u64-power-of-two? [n : u64]) : bool
  (and (> n (cast 0 : u64)) (= (bit-and n (- n (cast 1 : u64))) (cast 0 : u64))))

(define (compiler-backend-u64-log2 [n : u64]) : i64
  (let
    [out : i64 0]
    [cursor : u64 n]
    (while (> cursor (cast 1 : u64))
      (set! cursor (shr cursor 1))
      (+= out 1))
    out))

(define (compiler-backend-i64-min-value) : i64
  (- (- 0 9223372036854775807) 1))

(define (compiler-backend-normalized-signed-immediate
  [type-segment-bases : i64]
  [n : i64]
  [ty : (& ty compiler_ast_types.AstType)]) : i64
  (match ty
    [(I8) (cast (cast n : i8) : i64)]
    [(I16) (cast (cast n : i16) : i64)]
    [(I32) (cast (cast n : i32) : i64)]
    [(or (Region _ inner) (Invalidate _ inner))
      (compiler-backend-normalized-signed-immediate
        type-segment-bases
        n
        (&
          (compiler_ast_types.ast-type-segment-bases-get
            type-segment-bases
            inner)))]
    [_ n]))

(define (compiler-backend-normalized-unsigned-immediate
  [type-segment-bases : i64]
  [n : i64]
  [ty : (& ty compiler_ast_types.AstType)]) : u64
  (match ty
    [(U8) (cast (cast n : u8) : u64)]
    [(U16) (cast (cast n : u16) : u64)]
    [(U32) (cast (cast n : u32) : u64)]
    [(or (Region _ inner) (Invalidate _ inner))
      (compiler-backend-normalized-unsigned-immediate
        type-segment-bases
        n
        (&
          (compiler_ast_types.ast-type-segment-bases-get
            type-segment-bases
            inner)))]
    [_ (cast n : u64)]))

(define (compiler-backend-divmod-safe-literal-i64?
  [type-segment-bases : i64]
  [n : i64]
  [ty : (& ty compiler_ast_types.AstType)]) : bool
  (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
    (let
      [d : i64
        (compiler-backend-normalized-signed-immediate type-segment-bases n ty)]
      (and (not (= d 0)) (not (= d (- 0 1)))))
    (not
      (=
        (compiler-backend-normalized-unsigned-immediate type-segment-bases n ty)
        (cast 0 : u64)))))

(define (compiler-backend-divmod-safe-literal?
  [type-segment-bases : i64]
  [value : compiler_ir_types.CompilerIrValue]
  [ty : (& ty compiler_ast_types.AstType)]) : bool
  (match (be_operand.compiler-backend-value-as-i64 value)
    [(Some n)
      (compiler-backend-divmod-safe-literal-i64? type-segment-bases n ty)]
    [(None) false]))

;; ===========================================================================
;; M-F: loop-hoisted backend constants.
;;
;; The strength-reduced constant divmod expansion materialises its 64-bit magic
;; reciprocal (`movabsq $magic, scratch`) at EVERY site, so a `% C` inside a hot
;; loop pays one movabsq per iteration (clang keeps the magic in a register
;; across the loop). The magic constant is emission-internal -- it never exists
;; in the IR -- so neither the optimiser's LICM nor the allocator can hoist it.
;; Ordinary wide BinOp RHS literals use the same per-site materialisation path.
;; This pass gives both kinds a loop-scoped register at the EMISSION-PLAN level:
;;
;;   * candidate loops: the natural loops of the FINAL emitted IR's CFG loop
;;     nest (compiler-reg-loop-nest-build), taken as MEMBER SETS: a loop is a
;;     header plus every block that reaches one of its latches without passing
;;     the header again. A member set is side-entry-free by construction, so
;;     admission asks only that the loop be LEAF (no call/syscall/tail-call in
;;     any MEMBER), that the header have exactly one predecessor from outside
;;     the set -- a P that ends in an unconditional Jump to the header (the M-E
;;     preheader shape) -- and that the function's ENTRY block be in the set
;;     only when it IS the header, since block 0 is reached through no
;;     predecessor and an edge count cannot see that way in. The layout enters
;;     only where an instruction-point hull has to be named: the span
;;     [lowest member .. highest member].
;;   * sites: constant divmods in the region whose expansion takes the signed or
;;     unsigned MAGIC path, plus supported size-8 BinOps with an I64 RHS outside
;;     signed imm32; deduplicated by site kind + VALUE;
;;   * register: first target-safe member of the M-G2b shadow set (rax/rdx/rcx
;;     are div/shift-fixed, r10/r11 stay the scavenger's) whose segment-precise
;;     occupancy is FREE over the whole hull [P-start .. region-end] -- checked
;;     against the same fresh final-IR intervals the scavenge occupancy is built
;;     from, so the hoist never displaces or fights an allocated value. No free
;;     register -> no hoist -> byte-identical output;
;;   * realisation: `movabsq $magic, R` is injected as raw text right after P's
;;     label (once per loop entry); each site's emission point is recorded and
;;     the divmod emitters read R instead of materialising (the recorded magic
;;     value is re-checked at the site -- a mismatch falls back to the load);
;;   * protection: a synthetic (register-homed, region-spanning) interval is
;;     appended to the scavenge-occupancy inputs, so every scavenged scratch in
;;     the region avoids R; the site's own dividend/mask/magic scratch picks
;;     additionally exclude R so even an emergency pick cannot alias it.
;;
;; Scalar-opt2 text path. Both Internal conventions admit rsi/rdi/r8/r9 as
;; caller-saved carriers; rbx uses a callee-saved frame home for divmod.
;; ===========================================================================
(defenum CompilerBackendConstHoistHome
  (CompilerBackendNoConstHoistHome)
  ;; Register, expected bits, ordinary-wide-binop site?
  (CompilerBackendConstHoistHomeReg i64 i64 bool)
  ;; Frame operand, expected bits. Frame homes are only selected for divmod
  ;; magic; ordinary wide-binop hoists retain their register-only contract.
  (CompilerBackendConstHoistHomeFrame String i64))

;; Synthetic occupancy entries for the scavenge context: count + per-entry
;; register / start point / end point.
(defenum CompilerBackendConstHoistSynth
  (CompilerBackendConstHoistSynth
    i64
    (__tl_dyn-array i64)
    (__tl_dyn-array i64)
    (__tl_dyn-array i64)))

;; true = inject BEFORE the label (the header-is-entry-block case: the load
;; goes at prologue end, so back edges re-enter after it); false = after the
;; label (a dedicated preheader block).
;; A frame-home magic is initialized through %rbx. The same stable, per-function
;; plan flag also makes %rbx a prologue-saved scavenge candidate at the sites:
;; after the one-time store, the register is free to be the sole dividend copy.
(define (compiler-backend-const-hoist-disable!
  [function-state : be_state.CompilerBackendFunctionState]) : CompilerBackendConstHoistSynth
  (let
    [scratch : be_state.CompilerBackendScratchState
      (be_state.compiler-backend-function-scratch-state function-state)]
    [empty-i64 : (__tl_dyn-array i64) scratch.empty-i64-array]
    [empty-bool : (__tl_dyn-array bool) scratch.empty-bool-array]
    [empty-string : (__tl_dyn-array String) scratch.empty-string-array]
    (be_state.compiler-backend-function-scratch-set-i64!
      function-state
      be_state.compiler-backend-scratch-i64-const-hoist-site-count
      0)
    (be_state.compiler-backend-function-scratch-set-i64!
      function-state
      be_state.compiler-backend-scratch-i64-const-hoist-inject-count
      0)
    (be_state.compiler-backend-function-scratch-set-bool!
      function-state
      be_state.compiler-backend-scratch-bool-const-hoist-frame-rbx
      false)
    (be_state.compiler-backend-function-scratch-set-i64!
      function-state
      be_state.compiler-backend-scratch-i64-const-hoist-frame-count
      0)
    (be_state.compiler-backend-function-scratch-set-i64-array!
      function-state
      be_state.compiler-backend-scratch-i64-array-const-hoist-site-points
      (be_state.compiler-backend-global-shared-view empty-i64))
    (be_state.compiler-backend-function-scratch-set-i64-array!
      function-state
      be_state.compiler-backend-scratch-i64-array-const-hoist-site-regs
      (be_state.compiler-backend-global-shared-view empty-i64))
    (be_state.compiler-backend-function-scratch-set-string-array!
      function-state
      be_state.compiler-backend-scratch-string-array-const-hoist-site-frame-operands
      (be_state.compiler-backend-global-shared-view empty-string))
    (be_state.compiler-backend-function-scratch-set-i64-array!
      function-state
      be_state.compiler-backend-scratch-i64-array-const-hoist-site-values
      (be_state.compiler-backend-global-shared-view empty-i64))
    (be_state.compiler-backend-function-scratch-set-bool-array!
      function-state
      be_state.compiler-backend-scratch-bool-array-const-hoist-site-wide
      (be_state.compiler-backend-global-shared-view empty-bool))
    (be_state.compiler-backend-function-scratch-set-bool-array!
      function-state
      be_state.compiler-backend-scratch-bool-array-const-hoist-site-frame
      (be_state.compiler-backend-global-shared-view empty-bool))
    (be_state.compiler-backend-function-scratch-set-i64-array!
      function-state
      be_state.compiler-backend-scratch-i64-array-const-hoist-inject-labels
      (be_state.compiler-backend-global-shared-view empty-i64))
    (be_state.compiler-backend-function-scratch-set-string-array!
      function-state
      be_state.compiler-backend-scratch-string-array-const-hoist-inject-texts
      empty-string)
    (be_state.compiler-backend-function-scratch-set-bool-array!
      function-state
      be_state.compiler-backend-scratch-bool-array-const-hoist-inject-pres
      empty-bool)
    (CompilerBackendConstHoistSynth
      0
      (be_state.compiler-backend-global-shared-view empty-i64)
      (be_state.compiler-backend-global-shared-view empty-i64)
      empty-i64)))

;; The shrink-wrap prefix is dry-emitted before this function's const-hoist
;; plan is built.  A preceding scratch-arena function may have left nonzero
;; site counts whose arrays were retired with that arena; consulting those
;; sites while rendering a bare return would dereference stale storage.
;; Admission therefore starts from a proven empty per-function hoist state.
(define (compiler-backend-shrinkwrap-admission-state-clean?
  [function-state : be_state.CompilerBackendFunctionState]) : bool
  (and
    (=
      (be_state.compiler-backend-function-scratch-i64
        function-state
        be_state.compiler-backend-scratch-i64-const-hoist-site-count)
      0)
    (=
      (be_state.compiler-backend-function-scratch-i64
        function-state
        be_state.compiler-backend-scratch-i64-const-hoist-inject-count)
      0)
    (not
      (be_state.compiler-backend-function-scratch-bool?
        function-state
        be_state.compiler-backend-scratch-bool-const-hoist-frame-rbx))
    (=
      (be_state.compiler-backend-function-scratch-i64
        function-state
        be_state.compiler-backend-scratch-i64-const-hoist-frame-count)
      0)))

(define (compiler-backend-prepare-shrinkwrap-admission!
  [function-state : be_state.CompilerBackendFunctionState]) : bool
  (compiler-backend-const-hoist-disable! function-state)
  (compiler-backend-shrinkwrap-admission-state-clean? function-state))

;; Registers eligible to carry a hoisted magic across a leaf loop region.
;; Both Internal conventions make RSI/RDI/R8/R9 volatile. RBX is callee-saved
;; under both and uses the frame-home path for divmod.
;;
;; %rbx is the revertible M-F extension for register-saturated leaf loops. The
;; ordinary caller-saved candidates are all loop-carried in vm-run, while %rbx
;; is free. For divmod magic, selecting %rbx becomes a frame-home hoist initialized
;; through %rbx; the register is then free for the one dividend copy at each site.
(define (compiler-backend-const-hoist-candidate-regs
  [target : be_state.CompilerBackendTarget]) : compiler_regalloc.CompilerRegIdSeq
  (compiler_regalloc.compiler-reg-id-seq-prepend
    compiler_abi.compiler-reg-id-r8
    (compiler_regalloc.compiler-reg-id-seq-prepend
      compiler_abi.compiler-reg-id-r9
      (let
        [rbx : compiler_regalloc.CompilerRegIdSeq
          (compiler_regalloc.compiler-reg-id-seq-prepend
            compiler_abi.compiler-reg-id-rbx
            (compiler_regalloc.compiler-reg-id-seq-empty))]
        ;; rsi and rdi join where the ABI makes them caller-saved.
        (if (compiler_abi.compiler-abi-caller-saved-gp-register?
          (be_state.compiler-backend-target-abi target)
          (Internal)
          compiler_abi.compiler-reg-id-rsi)
          (compiler_regalloc.compiler-reg-id-seq-prepend
            compiler_abi.compiler-reg-id-rsi
            (compiler_regalloc.compiler-reg-id-seq-prepend
              compiler_abi.compiler-reg-id-rdi
              rbx))
          rbx)))))

;; The register carrying this site's hoisted magic, or "" when the site has no
;; hoist or the recorded value does not match the magic this expansion computed
;; (defensive: a mismatch means the plan and the emitter disagree -- fall back
;; to the in-place load rather than read a wrong constant).
;; The validated magic operand may be a register or a frame home. A mismatch is
;; deliberately empty so the site falls back to ordinary materialization.
(define (compiler-backend-magic-home-operand
  [hoist : CompilerBackendConstHoistHome]
  [magic : u64]) : String
  (match hoist
    [(CompilerBackendNoConstHoistHome) ""]
    [(CompilerBackendConstHoistHomeReg reg expect wide?)
      (if (and (not wide?) (= expect (cast magic : i64)))
        (compiler_abi.compiler-abi-register-spelling reg)
        "")]
    [(CompilerBackendConstHoistHomeFrame operand expect)
      (if (= expect (cast magic : i64))
        operand
        "")]))

(define (compiler-backend-magic-home-reg-name
  [hoist : CompilerBackendConstHoistHome]) : String
  (match hoist
    [(CompilerBackendConstHoistHomeReg reg _ wide?)
      (if wide?
        ""
        (compiler_abi.compiler-abi-register-spelling reg))]
    [(or (CompilerBackendNoConstHoistHome)
         (CompilerBackendConstHoistHomeFrame _ _))
      ""]))

;; The current site's planned home when `value` is the exact wide literal the
;; planner recorded. Other value kinds and defensive value mismatches fall
;; back to ordinary materialisation.
(define (compiler-backend-const-hoist-value-home-reg
  [function-state : be_state.CompilerBackendFunctionState]
  [value : compiler_ir_types.CompilerIrValue]) : String
  (match value
    [(I64 n)
      (match (compiler-backend-const-hoist-here function-state)
        [(CompilerBackendConstHoistHomeReg reg expect wide?)
          (if (and wide? (= expect n))
            (compiler_abi.compiler-abi-register-spelling reg)
            "")]
        [(or (CompilerBackendConstHoistHomeFrame _ _)
             (CompilerBackendNoConstHoistHome))
          ""])]
    [_ ""]))

;; Site lookup keyed by the current emission point (the same drift-proof
;; coordinate the scavenger queries occupancy with).
(define (compiler-backend-const-hoist-here
  [function-state : be_state.CompilerBackendFunctionState]) : CompilerBackendConstHoistHome
  (if (=
    (be_state.compiler-backend-function-scratch-i64
      function-state
      be_state.compiler-backend-scratch-i64-const-hoist-site-count)
    0)
    (CompilerBackendNoConstHoistHome)
    (let
      [site-count : i64
        (be_state.compiler-backend-function-scratch-i64
          function-state
          be_state.compiler-backend-scratch-i64-const-hoist-site-count)]
      [site-points : (__tl_dyn-array i64)
        (be_state.compiler-backend-function-scratch-i64-array
          function-state
          be_state.compiler-backend-scratch-i64-array-const-hoist-site-points)]
      [site-regs : (__tl_dyn-array i64)
        (be_state.compiler-backend-function-scratch-i64-array
          function-state
          be_state.compiler-backend-scratch-i64-array-const-hoist-site-regs)]
      [site-values : (__tl_dyn-array i64)
        (be_state.compiler-backend-function-scratch-i64-array
          function-state
          be_state.compiler-backend-scratch-i64-array-const-hoist-site-values)]
      [site-wide : (__tl_dyn-array bool)
        (be_state.compiler-backend-function-scratch-bool-array
          function-state
          be_state.compiler-backend-scratch-bool-array-const-hoist-site-wide)]
      [site-frame : (__tl_dyn-array bool)
        (be_state.compiler-backend-function-scratch-bool-array
          function-state
          be_state.compiler-backend-scratch-bool-array-const-hoist-site-frame)]
      [site-frame-operands : (__tl_dyn-array String)
        (be_state.compiler-backend-function-scratch-string-array
          function-state
          be_state.compiler-backend-scratch-string-array-const-hoist-site-frame-operands)]
      [point : i64
        (be_state.compiler-backend-function-state-emission-point function-state)]
      [found : i64 (- 0 1)]
      (for [i (iterator.range 0 site-count)]
        (if (= (array-ref site-points i) point)
          (set! found i)
          unit))
      (if (< found 0)
        (CompilerBackendNoConstHoistHome)
        (if (array-ref site-frame found)
          (CompilerBackendConstHoistHomeFrame
            (be_state.compiler-backend-global-array-element-shared-view
              site-frame-operands
              found)
            (array-ref site-values found))
          (CompilerBackendConstHoistHomeReg
            (array-ref site-regs found)
            (array-ref site-values found)
            (array-ref site-wide found)))))))

;; All injection text registered for this block label (the preheader constant
;; loads): `pre` = true selects the before-label entries (header-is-entry-block
;; loops; the load lands at prologue end so back edges re-enter after it),
;; false the after-label entries (dedicated preheader blocks).
(define (compiler-backend-const-hoist-injection-from
  [function-state : be_state.CompilerBackendFunctionState]
  [label : i64]
  [pre : bool]
  [i : i64]) : String
  (if (>=
    i
    (be_state.compiler-backend-function-scratch-i64
      function-state
      be_state.compiler-backend-scratch-i64-const-hoist-inject-count))
    ""
    (if (and
      (=
        (array-ref
          (be_state.compiler-backend-function-scratch-i64-array
            function-state
            be_state.compiler-backend-scratch-i64-array-const-hoist-inject-labels)
          i)
        label)
      (if pre
        (array-ref
          (be_state.compiler-backend-function-scratch-bool-array
            function-state
            be_state.compiler-backend-scratch-bool-array-const-hoist-inject-pres)
          i)
        (not
          (array-ref
            (be_state.compiler-backend-function-scratch-bool-array
              function-state
              be_state.compiler-backend-scratch-bool-array-const-hoist-inject-pres)
            i))))
      (str_cat.str-cat
        (be_state.compiler-backend-global-array-element-shared-view
          (be_state.compiler-backend-function-scratch-string-array
            function-state
            be_state.compiler-backend-scratch-string-array-const-hoist-inject-texts)
          i)
        (compiler-backend-const-hoist-injection-from
          function-state
          label
          pre
          (+ i 1)))
      (compiler-backend-const-hoist-injection-from
        function-state
        label
        pre
        (+ i 1)))))

(define (compiler-backend-const-hoist-injection-for
  [function-state : be_state.CompilerBackendFunctionState]
  [label : i64]
  [pre : bool]) : String
  (if (=
    (be_state.compiler-backend-function-scratch-i64
      function-state
      be_state.compiler-backend-scratch-i64-const-hoist-inject-count)
    0)
    ""
    (compiler-backend-const-hoist-injection-from function-state label pre 0)))

;; The magic constant (as i64 bits) the constant-divmod expansion will
;; materialise for a signed 64-bit divisor, or 0 when that divisor does not
;; take the magic path (0 is never a valid magic).
(define (compiler-backend-const-hoist-signed-magic [d : i64]) : i64
  (if (or (= d 1) (= d (- 0 1)) (= d (compiler-backend-i64-min-value)))
    0
    (let
      [abs-d : i64
        (if (< d 0)
          (- 0 d)
          d)]
      (if (compiler-backend-u64-power-of-two? (cast abs-d : u64))
        0
        (cast
          (__tl-project-field
            (be_div.compiler-backend-signed-divisor-magic abs-d)
            magic)
          : i64)))))

(define (compiler-backend-const-hoist-unsigned-magic [d : u64]) : i64
  (if (or
    (compiler-backend-u64-power-of-two? d)
    (compiler-backend-u64-high-bit? d))
    0
    (match (be_div.compiler-backend-unsigned-divisor-magic d)
      [(or (RoundUp magic _) (RoundDown magic _)) (cast magic : i64)]
      [(No) 0])))

(define (compiler-backend-const-hoist-divmod-op?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]) : bool
  (match op
    [(or (Div) (Mod) (SafeDiv) (SafeMod)) true]
    [_ false]))

;; Ordinary integer binops whose wide RHS literal is materialised in a
;; register before the two-address operation. Comparisons and shifts retain
;; their existing emission rules.
(define (compiler-backend-const-hoist-wide-binop-op?
  [op : compiler_ir_types.CompilerIrBinOp]) : bool
  (match op
    [(or (Add) (Sub) (Mul) (And) (Or) (BitAnd) (BitOr) (BitXor)) true]
    [_ false]))

(define (compiler-backend-const-hoist-instr-wide?
  [type-segment-bases : i64]
  [instr : compiler_ir_types.CompilerIrInstr]) : bool
  (match instr
    [(BinOp _ op _ rhs ty)
      (and
        (compiler-backend-const-hoist-wide-binop-op? op)
        (= (be_operand.compiler-backend-type-size type-segment-bases ty) 8)
        (match rhs
          [(I64 n) (not (be_operand.compiler-backend-imm32? n))]
          [_ false]))]
    [_ false]))

;; The constant this instruction's emission will need resident in a register,
;; or 0 when it is not a hoist site. Div/mod returns its expansion's magic
;; value; ordinary 64-bit binops return a RHS literal that cannot use imm32.
;; Zero is never a candidate in either path.
(define (compiler-backend-const-hoist-instr-constant
  [type-segment-bases : i64]
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(BinOp _ op _ rhs ty)
      (if (compiler-backend-const-hoist-divmod-op? op)
        (match (be_operand.compiler-backend-value-as-i64 rhs)
          [(Some n)
            (if (and
              (=
                (be_operand.compiler-backend-type-size type-segment-bases ty)
                8)
              (compiler-backend-divmod-safe-literal-i64?
                type-segment-bases
                n
                ty))
              (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
                (compiler-backend-const-hoist-signed-magic n)
                (compiler-backend-const-hoist-unsigned-magic (cast n : u64)))
              0)]
          [(None) 0])
        (if (and
          (compiler-backend-const-hoist-wide-binop-op? op)
          (= (be_operand.compiler-backend-type-size type-segment-bases ty) 8))
          (match rhs
            [(I64 n)
              (if (be_operand.compiler-backend-imm32? n)
                0
                n)]
            [_ 0])
          0))]
    [_ 0]))

;; Any block outside [h..le] branching to a block strictly inside (h..le]?
(define (compiler-backend-const-hoist-succs-inside?
  [ids : (& ids backend_label_i64_map.Map)]
  [succs : compiler_liveness.CompilerLiveLabelSet]
  [h : i64]
  [le : i64]) : bool
  (match (& succs)
    [(Nil) false]
    [(Dense _ _)
      (match (backend_label_i64_map.get
        (& ids)
        (compiler_liveness.compiler-live-label-set-ref (& succs) 0))
        [(LookupFound q)
          (if (and (> q h) (<= q le))
            true
            (compiler-backend-const-hoist-succs-inside?
              ids
              (compiler_liveness.compiler-live-label-set-tail succs)
              h
              le))]
        [(LookupMissing)
          (compiler-backend-const-hoist-succs-inside?
            ids
            (compiler_liveness.compiler-live-label-set-tail succs)
            h
            le)])]))

(define (compiler-backend-const-hoist-side-entry?
  [orig : (__tl_dyn-array compiler_ir_types.CompilerIrBlock)]
  [ids : (& ids backend_label_i64_map.Map)]
  [h : i64]
  [le : i64]) : bool
  (let
    [n : i64 (array-length orig)]
    [p : i64 0]
    [found : bool false]
    (while (and (< p n) (not found))
      (if (or (< p h) (> p le))
        (set!
          found
          (compiler-backend-const-hoist-succs-inside?
            ids
            (compiler_liveness.compiler-live-block-successors
              (& (array-ref orig p)))
            h
            le))
        unit)
      (+= p 1))
    found))

;; Any successor of `succs` inside the inclusive index range [lo..le]?
(define (compiler-backend-const-hoist-succs-within?
  [ids : (& ids backend_label_i64_map.Map)]
  [succs : compiler_liveness.CompilerLiveLabelSet]
  [lo : i64]
  [le : i64]) : bool
  (match (& succs)
    [(Nil) false]
    [(Dense _ _)
      (match (backend_label_i64_map.get
        (& ids)
        (compiler_liveness.compiler-live-label-set-ref (& succs) 0))
        [(LookupFound q)
          (if (and (>= q lo) (<= q le))
            true
            (compiler-backend-const-hoist-succs-within?
              ids
              (compiler_liveness.compiler-live-label-set-tail succs)
              lo
              le))]
        [(LookupMissing)
          (compiler-backend-const-hoist-succs-within?
            ids
            (compiler_liveness.compiler-live-label-set-tail succs)
            lo
            le)])]))

;; A block may sit on a guard chain only when nothing it holds is a call.
(define (compiler-backend-const-hoist-block-call-free?
  [block : compiler_ir_types.CompilerIrBlock]) : bool
  (match block
    [(Block _ instrs)
      (not
        (compiler_regalloc.compiler-reg-loop-split-seq-has-call-or-syscall?
          instrs))]))

;; Collect indices of blocks outside [lo..le] whose successors reach it. Returns
;; the count; the indices themselves land in `out`, and `lo` drops to the
;; smallest index seen (progress for the chain walk below).
(define (compiler-backend-const-hoist-collect-outside-preds
  [orig : (__tl_dyn-array compiler_ir_types.CompilerIrBlock)]
  [ids : (& ids backend_label_i64_map.Map)]
  [lo : i64]
  [le : i64]
  [out : (&mut out (__tl_dyn-array i64))]) : i64
  (let
    [n : i64 (array-length orig)]
    [found : i64 0]
    [best : i64 lo]
    (for [p (iterator.range 0 n)]
      (if (or (< p lo) (> p le))
        (when
          (compiler-backend-const-hoist-succs-within?
            ids
            (compiler_liveness.compiler-live-block-successors
              (& (array-ref orig p)))
            lo
            le)
          (set! (array-ref out found) p)
          (+= found 1)
          (if (< p best)
            (set! best p)
            unit))
        unit))
    (set! (array-ref out found) best)
    found))

;; True when every collected pred block is call-free.
(define (compiler-backend-const-hoist-all-call-free?
  [orig : (__tl_dyn-array compiler_ir_types.CompilerIrBlock)]
  [preds : (__tl_dyn-array i64)]
  [count : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (while (and ok (< i count))
      (if (compiler-backend-const-hoist-block-call-free?
        (be_state.compiler-backend-global-array-element-shared-view
          orig
          (array-ref preds i)))
        unit
        (set! ok false))
      (+= i 1))
    ok))

;; Widened admission (Cycle 28): the strict M-E preheader shape rejects loops
;; whose entry runs through an unroll guard, because the guard block's
;; terminator is a conditional branch and the remainder loop gains a second
;; guard entry. The divmod magic load still dominates every site when it is
;; placed at the head of the guard chain. Walk outside-preds level by level:
;; every chain node must be call-free and strictly decrease the region's
;; lowest index (so the walk terminates), and the chain ends at a single
;; CALL-FREE predecessor whose terminator is an unconditional Jump. The final
;; predecessor matters too: injection happens immediately after its label, so
;; a later call in that same block would clobber a caller-saved constant home
;; before the loop reads it. Returns that predecessor's block index to inject
;; after, or -1 when no such dominator exists. Side-entry freedom over the
;; resolved span is re-checked by the caller with h := the resolved index.
(define (compiler-backend-const-hoist-resolve-inject
  [orig : (__tl_dyn-array compiler_ir_types.CompilerIrBlock)]
  [ids : (& ids backend_label_i64_map.Map)]
  [h : i64]
  [le : i64]) : i64
  (let
    [preds : (__tl_dyn-array i64) (__tl_make-array i64 17)]
    [lo : i64 h]
    [depth : i64 0]
    [found : i64 (- 0 1)]
    [done : bool false]
    (while (and (not done) (< depth 8))
      (let
        [count : i64
          (compiler-backend-const-hoist-collect-outside-preds
            (be_state.compiler-backend-global-shared-view orig)
            ids
            lo
            le
            (&mut preds))]
        [best : i64 (array-ref preds count)]
        (cond
          [(= count 0) (set! done true)]
          [(= count 1)
            (let
              [p : i64 (array-ref preds 0)]
              (if (and
                (compiler-backend-const-hoist-block-call-free?
                  (be_state.compiler-backend-global-array-element-shared-view
                    orig
                    p))
                (=
                  (compiler-backend-const-hoist-jump-target
                    (be_state.compiler-backend-global-array-element-shared-view
                      orig
                      p))
                  (compiler-backend-const-hoist-block-label
                    (&
                      (be_state.compiler-backend-global-array-element-shared-view
                        orig
                        lo)))))
                (begin
                  (set! found p)
                  (set! done true))
                (if (and
                  (compiler-backend-const-hoist-block-call-free?
                    (be_state.compiler-backend-global-array-element-shared-view
                      orig
                      p))
                  (< best lo))
                  (begin
                    (set! lo best)
                    (+= depth 1))
                  (set! done true))))]
          [else
            (if (and
              (compiler-backend-const-hoist-all-call-free?
                (be_state.compiler-backend-global-shared-view orig)
                (be_state.compiler-backend-global-shared-view preds)
                count)
              (< best lo))
              (begin
                (set! lo best)
                (+= depth 1))
              (set! done true))])))
    found))

;; Call-free over the loop's MEMBERS, walked in emitted order across the span
;; they occupy. A block inside that span but outside the set is skipped, and
;; skipping it is sound rather than merely cheap: a non-member does not reach a
;; latch, so control that enters one has left the loop for good and no later
;; site can read the register its call clobbered. The range reading charged
;; those blocks anyway, and refused whole loops over a call on a break arm.
(define (compiler-backend-const-hoist-region-leaf?
  [orig : (__tl_dyn-array compiler_ir_types.CompilerIrBlock)]
  [rlo : i64]
  [le : i64]) : bool
  (let
    [i : i64 rlo]
    [clean : bool true]
    (while (and (<= i le) clean)
      (match (owned_view.compiler-owned-element-view orig i)
        [(Block _ instrs)
          (if (compiler_regalloc.compiler-reg-loop-split-seq-has-call-or-syscall?
            instrs)
            (set! clean false)
            unit)])
      (+= i 1))
    clean))

;; "" unless the block's terminator is an unconditional Jump; else its target.
(define (compiler-backend-const-hoist-jump-target
  [block : compiler_ir_types.CompilerIrBlock]) : i64
  (match block
    [(Block _ instrs)
      (let
        [c : i64 (compiler_ir_types.compiler-ir-instr-seq-count instrs)]
        (if (<= c 0)
          (compiler_ir_types.compiler-ir-label-none)
          (match (compiler_ir_types.compiler-ir-instr-seq-borrow instrs (- c 1))
            [(Jump label) label]
            [_ (compiler_ir_types.compiler-ir-label-none)])))]))

(define (compiler-backend-const-hoist-block-label
  [block : (& compiler_ir_types.CompilerIrBlock)]) : i64
  (match block
    [(Block label _) label]))

;; Is `point` already recorded as a hoisted site?
(define (compiler-backend-const-hoist-point-recorded?
  [points : (& points (__tl_dyn-array i64))]
  [count : i64]
  [point : i64]) : bool
  (let
    [i : i64 0]
    [found : bool false]
    (while (and (< i count) (not found))
      (if (= (array-ref points i) point)
        (set! found true)
        unit)
      (+= i 1))
    found))

;; Is entry `i` the FIRST entry carrying its (value, wide?) key? Distinct keys
;; are identified by their first occurrence, which is also the tie-break rank
;; below, so this is the one place the dedup key is spelled out.
(define (compiler-backend-const-hoist-key-first?
  [values : (& values (__tl_dyn-array i64))]
  [wide : (& wide (__tl_dyn-array bool))]
  [i : i64]) : bool
  (let
    [j : i64 0]
    [seen : bool false]
    (while (and (< j i) (not seen))
      (if (= (array-ref values j) (array-ref values i))
        (if (= (array-ref wide j) (array-ref wide i))
          (set! seen true)
          unit)
        unit)
      (+= j 1))
    (not seen)))

;; How many entries in [0, count) share entry `i`'s (value, wide?) key -- the
;; STATIC site count of that constant inside this region.
(define (compiler-backend-const-hoist-key-sites
  [values : (& values (__tl_dyn-array i64))]
  [wide : (& wide (__tl_dyn-array bool))]
  [count : i64]
  [i : i64]) : i64
  (let
    [n : i64 0]
    (for [j (iterator.range 0 count)]
      (if (= (array-ref values j) (array-ref values i))
        (if (= (array-ref wide j) (array-ref wide i))
          (+= n 1)
          unit)
        unit))
    n))

;; The order in which this region's distinct constants claim its free
;; candidates. Writes one entry per distinct key into `order` (the key's first
;; occurrence index) and `tally` (its static site count), sorted by DESCENDING
;; site count; returns the distinct-key count.
;;
;; Program order is the wrong award order when candidates are scarce. In a
;; register-saturated region the FIRST constant took the only free register
;; regardless of how much work it saved, so a single-site wide literal could
;; outbid a divmod magic with five sites -- the magic then re-materialised a
;; `movabsq` at every site on every iteration while the wide literal, which
;; costs one materialisation per entry, sat in the register. Site count is the
;; sound static proxy for that saving: each hoisted site drops exactly one
;; in-region constant load. Execution frequency would be a better weight but is
;; not available here (the region is a block range, not a profile).
;;
;; Ties keep program order: the collection pass below emits distinct keys in
;; first-occurrence order and the sort is a STABLE insertion sort, so equal
;; site counts award in the order the constants appear. The result is a total
;; order over the region's keys with no map iteration anywhere, which keeps the
;; emitted plan reproducible.
(define (compiler-backend-const-hoist-award-order!
  [values : (& values (__tl_dyn-array i64))]
  [wide : (& wide (__tl_dyn-array bool))]
  [count : i64]
  [order : (&mut order (__tl_dyn-array i64))]
  [tally : (&mut tally (__tl_dyn-array i64))]) : i64
  (let
    [distinct : i64 0]
    (for [i (iterator.range 0 count)]
      (when
        (compiler-backend-const-hoist-key-first? values wide i)
        (set! (array-ref order distinct) i)
        (set!
          (array-ref tally distinct)
          (compiler-backend-const-hoist-key-sites values wide count i))
        (+= distinct 1)))
    (for [a (iterator.range 1 distinct)]
      (let
        [key-index : i64 (array-ref order a)]
        [key-tally : i64 (array-ref tally a)]
        [b : i64 a]
        (while (and (> b 0) (< (array-ref tally (- b 1)) key-tally))
          (set! (array-ref order b) (array-ref order (- b 1)))
          (set! (array-ref tally b) (array-ref tally (- b 1)))
          (-= b 1))
        (set! (array-ref order b) key-index)
        (set! (array-ref tally b) key-tally)))
    distinct))

;; Filter the candidate list: drop registers already reserved by an earlier
;; hoist whose synthetic span overlaps [lo, hi].
(define (compiler-backend-const-hoist-free-candidates
  [cands : compiler_regalloc.CompilerRegIdSeq]
  [synth-regs : (& synth-regs (__tl_dyn-array i64))]
  [synth-lo : (& synth-lo (__tl_dyn-array i64))]
  [synth-hi : (& synth-hi (__tl_dyn-array i64))]
  [synth-count : i64]
  [lo : i64]
  [hi : i64]) : compiler_regalloc.CompilerRegIdSeq
  (let
    [out : compiler_regalloc.CompilerRegIdSeq
      (compiler_regalloc.compiler-reg-id-seq-with-capacity
        (compiler_regalloc.compiler-reg-id-seq-count cands))]
    (for [candidate-index
      (iterator.range 0 (compiler_regalloc.compiler-reg-id-seq-count cands))]
      (let
        [reg : i64
          (compiler_regalloc.compiler-reg-id-seq-ref cands candidate-index)]
        [synth-index : i64 0]
        [taken : bool false]
        (while (and (< synth-index synth-count) (not taken))
          (if (and
            (= (array-ref synth-regs synth-index) reg)
            (<= (array-ref synth-lo synth-index) hi)
            (>= (array-ref synth-hi synth-index) lo))
            (set! taken true)
            unit)
          (+= synth-index 1))
        (if taken
          unit
          (set! out (compiler_regalloc.compiler-reg-id-seq-push out reg)))))
    out))

;; Cheap prescan: any constant-home candidate anywhere in the function?
(define (compiler-backend-const-hoist-any-constant?
  [type-segment-bases : i64]
  [orig : (__tl_dyn-array compiler_ir_types.CompilerIrBlock)]) : bool
  (let
    [n : i64 (array-length orig)]
    [b : i64 0]
    [found : bool false]
    (while (and (< b n) (not found))
      (match (be_state.compiler-backend-global-array-element-shared-view orig b)
        [(Block _ instrs)
          (let
            [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr)
              instrs.slots]
            [count : i64 instrs.len]
            [k : i64 0]
            (while (and (< k count) (not found))
              (if (=
                (compiler-backend-const-hoist-instr-constant
                  type-segment-bases
                  (be_state.compiler-backend-global-array-element-shared-view
                    slots
                    k))
                0)
                unit
                (set! found true))
              (+= k 1)))])
      (+= b 1))
    found))

;; Build the per-function hoist plan over the FINAL emitted IR (the exact
;; blocks, assignments and fresh intervals the scavenge occupancy uses).
;; Installs the owner-scoped site/injection plan and returns the synthetic
;; occupancy entries for the same function's scavenge context.
(define (compiler-backend-const-hoist-build!
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [intervals : compiler_regalloc.CompilerRegIntervalSeq]
  [vars : i64]
  [frame-base-slots : i64]
  [function-state : be_state.CompilerBackendFunctionState]
  [backend-state : be_state.CompilerBackendState]) : CompilerBackendConstHoistSynth
  (let
    [empty : CompilerBackendConstHoistSynth
      (compiler-backend-const-hoist-disable! function-state)]
    [dense-blocks : compiler_ir_types.CompilerIrBlockList blocks]
    [count : i64 (compiler_ir_types.compiler-ir-block-list-count dense-blocks)]
    (if (<= count 1)
      empty
      (let
        [orig : (__tl_dyn-array compiler_ir_types.CompilerIrBlock)
          (match (be_state.compiler-backend-global-shared-view dense-blocks)
            [(Array seq) seq.slots])]
        (if (not
          (compiler-backend-const-hoist-any-constant?
            type-segment-bases
            (be_state.compiler-backend-global-shared-view orig)))
          empty
          (let
            [ids : backend_label_i64_map.Map
              (compiler_regalloc.compiler-reg-loop-depth-block-ids
                (& dense-blocks)
                (&
                  (backend_label_i64_map.with-capacity
                    (compiler_regalloc.compiler-reg-bits-map-capacity count)))
                0)]
            [nest : compiler_regalloc.CompilerRegLoopNest
              (compiler_regalloc.compiler-reg-loop-nest-build (& dense-blocks))]
            [points : (__tl_dyn-array i64)
              (compiler_regalloc.compiler-reg-loop-phi-mb-block-points orig)]
            [interval-index : compiler_regalloc.CompilerRegIntervalIndex
              (compiler_regalloc.compiler-reg-interval-index-build
                (& intervals)
                vars)]
            ;; At most one site can be published for each final IR
            ;; instruction. Use that function-derived bound for both site and
            ;; synthetic/injection storage rather than fixed caps.
            [point-limit : i64 (array-ref points count)]
            [site-cap : i64
              (if (> point-limit 0)
                (/ point-limit 2)
                1)]
            [synth-cap : i64 site-cap]
            [site-points : (__tl_dyn-array i64) (__tl_make-array i64 site-cap)]
            [site-regs : (__tl_dyn-array i64) (__tl_make-array i64 site-cap)]
            [site-frame-operands : (__tl_dyn-array String)
              (__tl_make-array String site-cap)]
            [site-values : (__tl_dyn-array i64) (__tl_make-array i64 site-cap)]
            [site-wide : (__tl_dyn-array bool) (__tl_make-array bool site-cap)]
            [site-frame : (__tl_dyn-array bool) (__tl_make-array bool site-cap)]
            [site-count : i64 0]
            [inject-labels : (__tl_dyn-array i64)
              (__tl_make-array i64 synth-cap)]
            [inject-texts : (__tl_dyn-array String)
              (__tl_make-array String synth-cap)]
            [inject-pres : (__tl_dyn-array bool)
              (__tl_make-array bool synth-cap)]
            [inject-count : i64 0]
            [synth-regs : (__tl_dyn-array i64) (__tl_make-array i64 synth-cap)]
            [synth-lo : (__tl_dyn-array i64) (__tl_make-array i64 synth-cap)]
            [synth-hi : (__tl_dyn-array i64) (__tl_make-array i64 synth-cap)]
            [synth-count : i64 0]
            [frame-count : i64 0]
            ;; per-loop scratch: candidate site points/magics (before register
            ;; assignment), sized by the function instruction bound
            [loop-points : (__tl_dyn-array i64) (__tl_make-array i64 site-cap)]
            [loop-values : (__tl_dyn-array i64) (__tl_make-array i64 site-cap)]
            [loop-wide : (__tl_dyn-array bool) (__tl_make-array bool site-cap)]
            ;; per-loop scratch: the award sequence over the region's DISTINCT
            ;; keys (first-occurrence index + static site count), rebuilt for
            ;; every region by const-hoist-award-order!.
            [loop-order : (__tl_dyn-array i64) (__tl_make-array i64 site-cap)]
            [loop-tally : (__tl_dyn-array i64) (__tl_make-array i64 site-cap)]
            [hx : i64 0]
            [generation : i64 0]
            (while (<
              hx
              (compiler_regalloc.compiler-reg-loop-nest-header-count nest))
              (let
                [h : i64
                  (compiler_regalloc.compiler-reg-loop-nest-header (& nest) hx)]
                [total : i64 0]
                [rlo : i64 0]
                [le : i64 0]
                ;; The loop this header owns arrives as a MEMBER SET, not as
                ;; a block range. `rlo`/`le` are only the span that set
                ;; occupies in the emitted order, which is the language an
                ;; instruction-point hull has to be written in.
                (+= generation 1)
                (set!
                  total
                  (compiler_regalloc.compiler-reg-loop-nest-header-members!
                    nest
                    h
                    generation))
                (set!
                  rlo
                  (compiler_regalloc.compiler-reg-loop-nest-member-lo
                    nest
                    h
                    total))
                (set!
                  le
                  (compiler_regalloc.compiler-reg-loop-nest-member-hi
                    nest
                    h
                    total))
                (if (and
                  (< synth-count synth-cap)
                  (compiler-backend-const-hoist-region-leaf?
                    (be_state.compiler-backend-global-shared-view orig)
                    rlo
                    le))
                  ;; lint-allow: nested-let
                  (let
                    [h-label : i64
                      (compiler-backend-const-hoist-block-label
                        (&
                          (be_state.compiler-backend-global-array-element-shared-view
                            orig
                            h)))]
                    [p : i64
                      (compiler_regalloc.compiler-reg-loop-nest-outside-pred
                        nest
                        h
                        generation)]
                    ;; Two qualifying shapes:
                    ;;  * h > 0 with a single call-free out-of-loop
                    ;;    predecessor P (P < h, ends in Jump h): inject
                    ;;    AFTER P's label;
                    ;;  * h = 0 (opt-tailrec loops: the header IS the entry
                    ;;    block) with NO out-of-loop predecessor at all:
                    ;;    inject BEFORE block 0's label = at prologue end,
                    ;;    executed once per call; back edges re-enter after
                    ;;    it.
                    ;; A natural loop cannot HAVE a side entry: a block
                    ;; outside it with an edge to a member other than the
                    ;; header reaches the latch through that member, and
                    ;; reaching the latch is what puts a block in the set to
                    ;; begin with. So the strict shape is admitted on the
                    ;; predecessor COUNT alone -- one predecessor from
                    ;; outside the members, and every path into every member
                    ;; runs through it.
                    ;; Cycle 28: when the strict shape rejects a loop that
                    ;; enters through an unroll guard, resolve the call-free
                    ;; guard chain to its dominator (an unconditional Jump)
                    ;; and inject there, so one register/frame home carries
                    ;; each magic across the whole unrolled complex. THAT
                    ;; region is a layout span rather than a loop, so it
                    ;; still has to be proved side-entry-free -- and the
                    ;; member set has to lie inside the span being proved.
                    [strict-shape? : bool
                      (if (= h 0)
                        (= p (- 0 1))
                        (and
                          (>= p 0)
                          (< p h)
                          (compiler-backend-const-hoist-block-call-free?
                            (be_state.compiler-backend-global-array-element-shared-view
                              orig
                              p))
                          (=
                            (compiler-backend-const-hoist-jump-target
                              (be_state.compiler-backend-global-array-element-shared-view
                                orig
                                p))
                            h-label)))]
                    [site : i64
                      (if strict-shape?
                        p
                        (compiler-backend-const-hoist-resolve-inject
                          (be_state.compiler-backend-global-shared-view orig)
                          ids
                          h
                          le))]
                    (if (and
                      (if (= h 0)
                        (= site (- 0 1))
                        (>= site 0))
                      ;; The function's ENTRY block may be in the set
                      ;; only when it is the header. Control arrives at
                      ;; block 0 from the caller and not through any
                      ;; predecessor at all, so a member set that
                      ;; contains it under some later header has a way
                      ;; in that no injection can dominate -- and the
                      ;; natural-loop walk does produce such a set,
                      ;; because an irreducible entry makes it run back
                      ;; past the loop until it runs out of graph.
                      (or (= h 0) (> rlo 0))
                      (if strict-shape?
                        true
                        (and
                          (<= site rlo)
                          (not
                            (compiler-backend-const-hoist-side-entry?
                              (be_state.compiler-backend-global-shared-view
                                orig)
                              ids
                              site
                              le)))))
                      ;; qualifying loop: collect its unclaimed magic sites
                      (let
                        [loop-count : i64 0]
                        [lo : i64
                          (if (and (>= site 0) (< site rlo))
                            (array-ref points site)
                            (array-ref points rlo))]
                        [hi : i64 (array-ref points (+ le 1))]
                        [inject-label : i64
                          (if (= h 0)
                            h-label
                            (compiler-backend-const-hoist-block-label
                              (&
                                (be_state.compiler-backend-global-array-element-shared-view
                                  orig
                                  site))))]
                        [inject-pre : bool (= h 0)]
                        (for [b (iterator.range rlo (+ le 1))]
                          (if (compiler_regalloc.compiler-reg-loop-nest-member?
                            nest
                            b
                            generation)
                            (match (be_state.compiler-backend-global-array-element-shared-view
                              orig
                              b)
                              [(Block _ instrs)
                                (let
                                  [slots : (__tl_dyn-array
                                    compiler_ir_types.CompilerIrInstr)
                                    instrs.slots]
                                  [icount : i64 instrs.len]
                                  (for [k (iterator.range 0 icount)]
                                    (let
                                      [instr : compiler_ir_types.CompilerIrInstr
                                        (be_state.compiler-backend-global-array-element-shared-view
                                          slots
                                          k)]
                                      [magic : i64
                                        (compiler-backend-const-hoist-instr-constant
                                          type-segment-bases
                                          (be_state.compiler-backend-global-shared-view
                                            instr))]
                                      [wide? : bool
                                        (compiler-backend-const-hoist-instr-wide?
                                          type-segment-bases
                                          instr)]
                                      [point : i64
                                        (+ (array-ref points b) (* 2 k))]
                                      (when
                                        (and
                                          (not (= magic 0))
                                          (< loop-count site-cap)
                                          (not
                                            (compiler-backend-const-hoist-point-recorded?
                                              site-points
                                              site-count
                                              point)))
                                        (set!
                                          (array-ref loop-points loop-count)
                                          point)
                                        (set!
                                          (array-ref loop-values loop-count)
                                          magic)
                                        (set!
                                          (array-ref loop-wide loop-count)
                                          wide?)
                                        (+= loop-count 1)))))])
                            unit))
                        ;; assign registers per distinct magic value,
                        ;; heaviest claim (most static sites) first
                        (let
                          [awards : i64
                            (compiler-backend-const-hoist-award-order!
                              loop-values
                              loop-wide
                              loop-count
                              (&mut loop-order)
                              (&mut loop-tally))]
                          (for [o (iterator.range 0 awards)]
                            (let
                              [g : i64 (array-ref loop-order o)]
                              [magic : i64 (array-ref loop-values g)]
                              [wide? : bool (array-ref loop-wide g)]
                              (if (and
                                (< synth-count synth-cap)
                                (< inject-count synth-cap))
                                (match (let
                                  [regs
                                    (compiler-backend-const-hoist-free-candidates
                                      (compiler-backend-const-hoist-candidate-regs
                                        target)
                                      synth-regs
                                      synth-lo
                                      synth-hi
                                      synth-count
                                      lo
                                      hi)]
                                  [region-intervals
                                    (compiler_regalloc.compiler-reg-loop-split-region-interval
                                      (- 0 1)
                                      lo
                                      hi)]
                                  (compiler_regalloc.compiler-reg-loop-split-first-register
                                    regs
                                    assignments
                                    interval-index
                                    region-intervals
                                    (- 0 1)))
                                  [(No) unit]
                                  [(Some reg)
                                    (let
                                      [frame? : bool
                                        (and
                                          (not wide?)
                                          (=
                                            reg
                                            compiler_abi.compiler-reg-id-rbx))]
                                      [reg-name : String
                                        (compiler_abi.compiler-abi-register-spelling
                                          reg)]
                                      [home : String
                                        (if frame?
                                          (be_operand.compiler-backend-frame-offset-with-backend-state
                                            backend-state
                                            (-
                                              0
                                              (*
                                                8
                                                (+
                                                  frame-base-slots
                                                  frame-count
                                                  1))))
                                          (owned_view.compiler-owned-shared-view
                                            reg-name))]
                                      ;; synthetic occupancy entry
                                      (set!
                                        (array-ref synth-regs synth-count)
                                        (if frame?
                                          compiler_abi.compiler-reg-id-invalid
                                          reg))
                                      (set! (array-ref synth-lo synth-count) lo)
                                      (set! (array-ref synth-hi synth-count) hi)
                                      (+= synth-count 1)
                                      ;; preheader injection
                                      (set!
                                        (array-ref inject-labels inject-count)
                                        inject-label)
                                      (set!
                                        (array-ref inject-texts inject-count)
                                        (if frame?
                                          (str_cat.str-cat
                                            (compiler-backend-emit-load-i64-absolute
                                              magic
                                              "%rbx")
                                            (str_cat.str-cat
                                              "    movq %rbx, "
                                              home
                                              "\n"))
                                          (compiler-backend-emit-load-i64-absolute
                                            magic
                                            reg-name)))
                                      (set!
                                        (array-ref inject-pres inject-count)
                                        inject-pre)
                                      (+= inject-count 1)
                                      ;; every site of this magic in the loop
                                      (for [j (iterator.range g loop-count)]
                                        (when
                                          (and
                                            (= (array-ref loop-values j) magic)
                                            (= (array-ref loop-wide j) wide?)
                                            (< site-count site-cap))
                                          (set!
                                            (array-ref site-points site-count)
                                            (array-ref loop-points j))
                                          (set!
                                            (array-ref site-regs site-count)
                                            (if frame?
                                              compiler_abi.compiler-reg-id-invalid
                                              reg))
                                          (set!
                                            (array-ref
                                              site-frame-operands
                                              site-count)
                                            (if frame?
                                              (be_state.compiler-backend-global-shared-view
                                                home)
                                              ""))
                                          (set!
                                            (array-ref site-values site-count)
                                            magic)
                                          (set!
                                            (array-ref site-wide site-count)
                                            wide?)
                                          (set!
                                            (array-ref site-frame site-count)
                                            frame?)
                                          (+= site-count 1)))
                                      (when
                                        frame?
                                        (be_state.compiler-backend-function-scratch-set-bool!
                                          function-state
                                          be_state.compiler-backend-scratch-bool-const-hoist-frame-rbx
                                          true)
                                        (+= frame-count 1)))])
                                unit)))))
                      unit))
                  unit)
                (+= hx 1)))
            ;; commit
            (be_state.compiler-backend-function-scratch-set-i64!
              function-state
              be_state.compiler-backend-scratch-i64-const-hoist-site-count
              site-count)
            (be_state.compiler-backend-function-scratch-set-i64-array!
              function-state
              be_state.compiler-backend-scratch-i64-array-const-hoist-site-points
              site-points)
            (be_state.compiler-backend-function-scratch-set-i64-array!
              function-state
              be_state.compiler-backend-scratch-i64-array-const-hoist-site-regs
              site-regs)
            (be_state.compiler-backend-function-scratch-set-string-array!
              function-state
              be_state.compiler-backend-scratch-string-array-const-hoist-site-frame-operands
              site-frame-operands)
            (be_state.compiler-backend-function-scratch-set-i64-array!
              function-state
              be_state.compiler-backend-scratch-i64-array-const-hoist-site-values
              site-values)
            (be_state.compiler-backend-function-scratch-set-bool-array!
              function-state
              be_state.compiler-backend-scratch-bool-array-const-hoist-site-wide
              site-wide)
            (be_state.compiler-backend-function-scratch-set-bool-array!
              function-state
              be_state.compiler-backend-scratch-bool-array-const-hoist-site-frame
              site-frame)
            (be_state.compiler-backend-function-scratch-set-i64!
              function-state
              be_state.compiler-backend-scratch-i64-const-hoist-inject-count
              inject-count)
            (be_state.compiler-backend-function-scratch-set-i64-array!
              function-state
              be_state.compiler-backend-scratch-i64-array-const-hoist-inject-labels
              inject-labels)
            (be_state.compiler-backend-function-scratch-set-string-array!
              function-state
              be_state.compiler-backend-scratch-string-array-const-hoist-inject-texts
              inject-texts)
            (be_state.compiler-backend-function-scratch-set-bool-array!
              function-state
              be_state.compiler-backend-scratch-bool-array-const-hoist-inject-pres
              inject-pres)
            (be_state.compiler-backend-function-scratch-set-i64!
              function-state
              be_state.compiler-backend-scratch-i64-const-hoist-frame-count
              frame-count)
            (CompilerBackendConstHoistSynth
              synth-count
              synth-regs
              synth-lo
              synth-hi)))))))

(define (compiler-backend-const-hoist-extend-vars
  [synth : CompilerBackendConstHoistSynth]
  [vars : i64]) : i64
  (match synth
    [(CompilerBackendConstHoistSynth n _ _ _) (+ vars n)]))

(define (compiler-backend-const-hoist-extend-assignments
  [synth : CompilerBackendConstHoistSynth]
  [vars : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]) : compiler_regalloc.CompilerRegAssignmentTable
  (match synth
    [(CompilerBackendConstHoistSynth n regs _ _)
      (if (= n 0)
        assignments
        (let
          [out : compiler_regalloc.CompilerRegAssignmentTable
            (compiler_regalloc.compiler-reg-assignment-table-copy-with-capacity
              assignments
              (+ vars n))]
          (for [i (iterator.range 0 n)]
            (compiler_regalloc.compiler-reg-assignment-table-insert
              out
              (+ vars i)
              (if (= (array-ref regs i) compiler_abi.compiler-reg-id-invalid)
                (Spill
                  (compiler_regalloc.compiler-reg-stack-slot-offset (+ vars i)))
                (Register (array-ref regs i))))
            unit)
          out))]))

(define (compiler-backend-const-hoist-extend-intervals-from
  [lo : (__tl_dyn-array i64)]
  [hi : (__tl_dyn-array i64)]
  [n : i64]
  [i : i64]
  [vars : i64]
  [intervals : compiler_regalloc.CompilerRegIntervalSeq]) : compiler_regalloc.CompilerRegIntervalSeq
  (let
    [out : compiler_regalloc.CompilerRegIntervalSeq
      (compiler_regalloc.compiler-reg-interval-seq-empty)]
    (for [index (iterator.range i n)]
      (set!
        out
        (compiler_regalloc.compiler-reg-interval-seq-append
          (& out)
          (compiler_regalloc.CompilerRegInterval
            (+ vars index)
            (array-ref lo index)
            (array-ref hi index)))))
    (compiler_regalloc.compiler-reg-interval-seq-append-all out intervals)))

(define (compiler-backend-const-hoist-extend-intervals
  [synth : CompilerBackendConstHoistSynth]
  [vars : i64]
  [intervals : compiler_regalloc.CompilerRegIntervalSeq]) : compiler_regalloc.CompilerRegIntervalSeq
  (match synth
    [(CompilerBackendConstHoistSynth n _ lo hi)
      (compiler-backend-const-hoist-extend-intervals-from
        lo
        hi
        n
        0
        vars
        intervals)]))

;; Preserve an XMM-family staging register over one local phi copy. The
;; emergency slot is distinct from the phi cycle-temp slots and saves the whole
;; physical family (16/32/64 bytes in scalar/AVX2/AVX-512 mode), so a scalar
;; movss/movsd stage cannot corrupt live vector lanes aliased by ymm/zmm.
(define (compiler-backend-phi-xmm-local-preserve-asm
  [reg : String]
  [asm : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (be_operand.compiler-backend-emergency-add-id!
    (be_state.compiler-backend-state-function-state backend-state)
    (compiler_abi.compiler-abi-register-id-from-spelling reg))
  (compiler-backend-emergency-wrap asm backend-state))

(define (compiler-backend-scavenge-divmod-src-reg
  [dst : i64]
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    (be_state.compiler-backend-function-scratch-set-bool!
      function-state
      be_state.compiler-backend-scratch-bool-divmod-src-emergency-avoid-r10
      true)
    (let
      [reg : String
        (be_operand.compiler-backend-scavenge-reg
          dst
          exclude
          exclude-n
          "%r10"
          backend-state)]
      (be_state.compiler-backend-function-scratch-set-bool!
        function-state
        be_state.compiler-backend-scratch-bool-divmod-src-emergency-avoid-r10
        false)
      reg)))

(define (compiler-backend-scavenge-divmod-src-reg-here
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    (be_state.compiler-backend-function-scratch-set-bool!
      function-state
      be_state.compiler-backend-scratch-bool-divmod-src-emergency-avoid-r10
      true)
    (let
      [reg : String
        (be_operand.compiler-backend-scavenge-reg-here
          exclude
          exclude-n
          "%r10"
          backend-state)]
      (be_state.compiler-backend-function-scratch-set-bool!
        function-state
        be_state.compiler-backend-scratch-bool-divmod-src-emergency-avoid-r10
        false)
      reg)))

(define (compiler-backend-divmod-shift-rax [mnemonic : String] [shift : i64]) : String
  (if (= shift 0)
    ""
    (str_cat.str-cat
      "    "
      mnemonic
      "q $"
      (string.int->string shift)
      ", %rax\n")))

(define (compiler-backend-divmod-shift-reg
  [mnemonic : String]
  [shift : i64]
  [reg : String]) : String
  (if (= shift 0)
    ""
    (str_cat.str-cat
      "    "
      mnemonic
      "q $"
      (string.int->string shift)
      ", "
      reg
      "\n")))

;; `dividend - quotient*divisor`, landing in the fixed %rax result register.
;;
;; M-N: the product is negated at compile time (`q * -d`) and accumulated with
;; `addq dividend, %rax` instead of being subtracted from a restored dividend.
;; `q * -d` is the two's-complement negation of `q * d` in the same 64 bits the
;; old shape already relied on, so `dividend + (q * -d)` is bit-identical to
;; `dividend - (q * d)` -- but it materialises the product straight into %rax
;; (dead since the multiply) and the dividend feeds the final add from its own
;; register. That retires the `movq dividend, %rax` restore this sequence used
;; to pay at every constant-remainder site, matching clang's
;; `imul $-d, q, %rax; add D, %rax` count.
;;
;; An imm32 divisor keeps folding into the 3-operand imul (negating an imm32
;; magnitude stays imm32 because the divisor here is always positive). Wider
;; divisors materialise `-d` once; when the quotient already occupies %rax the
;; materialisation borrows `scratch-reg` and multiplies into %rax in place.
(define (compiler-backend-divmod-remainder-from-quotient-reg
  [divisor : u64]
  [quotient-reg : String]
  [scratch-reg : String]
  [dividend-reg : String]) : String
  (let
    [neg-divisor : i64 (- 0 (cast divisor : i64))]
    ;; Bound to a local (behavior-neutral) so the seed typechecker resolves the
    ;; enclosing append operands without a spurious mismatch.
    [mul-asm : String
      (if (be_operand.compiler-backend-imm32? (cast divisor : i64))
        (str_cat.str-cat
          "    imulq $"
          (string.int->string neg-divisor)
          ", "
          quotient-reg
          ", %rax\n")
        (if (string.eq quotient-reg "%rax")
          (str_cat.str-cat
            (compiler-backend-emit-load-i64-absolute
              neg-divisor
              (be_state.compiler-backend-global-shared-view scratch-reg))
            (str_cat.str-cat "    imulq " scratch-reg ", %rax\n"))
          (str_cat.str-cat
            (compiler-backend-emit-load-i64-absolute neg-divisor "%rax")
            (str_cat.str-cat "    imulq " quotient-reg ", %rax\n"))))]
    (str_cat.str-cat
      mul-asm
      (str_cat.str-cat "    addq " dividend-reg ", %rax\n"))))

(define (compiler-backend-divmod-remainder-from-quotient
  [divisor : u64]
  [scratch-reg : String]
  [dividend-reg : String]) : String
  (compiler-backend-divmod-remainder-from-quotient-reg
    divisor
    "%rax"
    scratch-reg
    dividend-reg))

(define (compiler-backend-unsigned-power-divmod-asm
  [divisor : u64]
  [want-remainder : bool]
  [scratch-reg : String]) : String
  (let
    [shift : i64 (compiler-backend-u64-log2 divisor)]
    [mask : u64 (- divisor (cast 1 : u64))]
    (if want-remainder
      (if (= mask (cast 0 : u64))
        "    xorq %rax, %rax\n"
        ;; M-F: imm32 masks use the immediate form (no constant mov).
        (if (be_operand.compiler-backend-imm32? (cast mask : i64))
          (str_cat.str-cat
            "    andl $"
            (string.int->string (cast mask : i64))
            ", %eax\n")
          (str_cat.str-cat
            (compiler-backend-emit-load-u64-absolute
              mask
              (be_state.compiler-backend-global-shared-view scratch-reg))
            (str_cat.str-cat "    andq " scratch-reg ", %rax\n"))))
      (compiler-backend-divmod-shift-rax "shr" shift))))

(define (compiler-backend-unsigned-high-bit-divmod-asm
  [divisor : u64]
  [want-remainder : bool]
  [scratch-reg : String]
  [dividend-reg : String]) : String
  (if want-remainder
    (str_cat.str-cat
      (str_cat.str-cat "    movq %rax, " dividend-reg "\n")
      (compiler-backend-emit-load-u64-absolute
        divisor
        (be_state.compiler-backend-global-shared-view scratch-reg))
      (str_cat.str-cat
        "    cmpq "
        scratch-reg
        ", %rax\n    jb 1f\n    subq "
        scratch-reg
        ", "
        dividend-reg
        "\n1:\n    movq "
        dividend-reg
        ", %rax\n"))
    (str_cat.str-cat
      (compiler-backend-emit-load-u64-absolute
        divisor
        (be_state.compiler-backend-global-shared-view scratch-reg))
      (str_cat.str-cat
        "    cmpq "
        scratch-reg
        ", %rax\n    setae %al\n    movzbl %al, %eax\n"))))

(define (compiler-backend-unsigned-magic-divmod-asm
  [divisor : u64]
  [want-remainder : bool]
  [scratch-reg : String]
  [dividend-reg : String]
  [hoist : CompilerBackendConstHoistHome]) : be_state.CompilerBackendMaybeAsm
  (match (be_div.compiler-backend-unsigned-divisor-magic divisor)
    [(RoundUp magic shift)
      (let
        ;; M-F: a loop-hoisted magic is already resident in `home` -- skip the
        ;; materialisation and read it in place (mulq/addq only READ it).
        [home : String (compiler-backend-magic-home-operand hoist magic)]
        [magic-load : String
          (if (string.eq home "")
            (compiler-backend-emit-load-u64-absolute
              magic
              (be_state.compiler-backend-global-shared-view scratch-reg))
            "")]
        [magic-src : String
          (if (string.eq home "")
            (owned_view.compiler-owned-shared-view scratch-reg)
            home)]
        [quotient-asm : String
          (if want-remainder
            (str_cat.str-cat
              (str_cat.str-cat "    movq %rax, " dividend-reg "\n")
              magic-load
              (str_cat.str-cat "    mulq " magic-src "\n")
              (compiler-backend-divmod-shift-reg "shr" shift "%rdx"))
            (str_cat.str-cat
              magic-load
              (str_cat.str-cat "    mulq " magic-src "\n    movq %rdx, %rax\n")
              (compiler-backend-divmod-shift-rax "shr" shift)))]
        (Some
          (if want-remainder
            (str_cat.str-cat
              quotient-asm
              (compiler-backend-divmod-remainder-from-quotient-reg
                divisor
                "%rdx"
                scratch-reg
                dividend-reg))
            quotient-asm)))]
    [(RoundDown magic shift)
      (let
        [home : String (compiler-backend-magic-home-operand hoist magic)]
        [magic-load : String
          (if (string.eq home "")
            (compiler-backend-emit-load-u64-absolute
              magic
              (be_state.compiler-backend-global-shared-view scratch-reg))
            "")]
        [magic-src : String
          (if (string.eq home "")
            (owned_view.compiler-owned-shared-view scratch-reg)
            home)]
        [quotient-asm : String
          (if want-remainder
            (str_cat.str-cat
              (str_cat.str-cat "    movq %rax, " dividend-reg "\n")
              magic-load
              (str_cat.str-cat
                "    mulq "
                magic-src
                "\n    addq "
                magic-src
                ", %rax\n    adcq $0, %rdx\n")
              (compiler-backend-divmod-shift-reg "shr" shift "%rdx"))
            (str_cat.str-cat
              magic-load
              (str_cat.str-cat
                "    mulq "
                magic-src
                "\n    addq "
                magic-src
                ", %rax\n    adcq $0, %rdx\n    movq %rdx, %rax\n")
              (compiler-backend-divmod-shift-rax "shr" shift)))]
        (Some
          (if want-remainder
            (str_cat.str-cat
              quotient-asm
              (compiler-backend-divmod-remainder-from-quotient-reg
                divisor
                "%rdx"
                scratch-reg
                dividend-reg))
            quotient-asm)))]
    [(No) (No)]))

(define (compiler-backend-signed-power-divmod-asm
  [divisor : u64]
  [negative-divisor : bool]
  [want-remainder : bool]
  [scratch-reg : String]
  [dividend-reg : String]
  [mask-reg : String]) : String
  (let
    [shift : i64 (compiler-backend-u64-log2 divisor)]
    [mask : u64 (- divisor (cast 1 : u64))]
    [mask-i64 : i64 (cast mask : i64)]
    ;; M-F: imm32 masks use the immediate form (no constant mov). Bound to a
    ;; local (behavior-neutral) so the seed typechecker resolves the enclosing
    ;; append operands without a spurious mismatch.
    [mask-op-asm : String
      (if (be_operand.compiler-backend-imm32? mask-i64)
        (str_cat.str-cat
          "    andl $"
          (string.int->string mask-i64)
          ", "
          (be_operand.compiler-backend-reg-part (string.copy mask-reg) 4)
          "\n")
        (str_cat.str-cat
          (compiler-backend-emit-load-u64-absolute
            mask
            (be_state.compiler-backend-global-shared-view scratch-reg))
          (str_cat.str-cat "    andq " scratch-reg ", " mask-reg "\n")))]
    [quotient-asm : String
      (str_cat.str-cat
        ;; The dividend save feeds only the remainder expansion below; a
        ;; quotient-only site never reads dividend-reg, so the copy is dead.
        (str_cat.str-cat
          (if want-remainder
            (str_cat.str-cat "    movq %rax, " dividend-reg "\n")
            "")
          "    movq %rax, "
          mask-reg
          "\n    sarq $63, "
          mask-reg
          "\n")
        mask-op-asm
        (str_cat.str-cat "    addq " mask-reg ", %rax\n")
        (compiler-backend-divmod-shift-rax "sar" shift))]
    (if want-remainder
      (str_cat.str-cat
        quotient-asm
        (compiler-backend-divmod-remainder-from-quotient
          divisor
          scratch-reg
          dividend-reg))
      (if negative-divisor
        (str_cat.str-cat quotient-asm "    negq %rax\n")
        quotient-asm))))

(define (compiler-backend-signed-magic-divmod-asm
  [divisor : i64]
  [negative-divisor : bool]
  [want-remainder : bool]
  [scratch-reg : String]
  [dividend-reg : String]
  [mask-reg : String]
  [hoist : CompilerBackendConstHoistHome]) : String
  (let
    [plan : be_div.CompilerBackendSignedDivMagic
      (be_div.compiler-backend-signed-divisor-magic divisor)]
    [magic : u64 plan.magic]
    [shift : i64 plan.shift]
    ;; M-F: a loop-hoisted magic is already resident in `home` -- skip the
    ;; materialisation and read it in place (imulq only READS it).
    [home : String (compiler-backend-magic-home-operand hoist magic)]
    [magic-load : String
      (if (string.eq home "")
        (compiler-backend-emit-load-u64-absolute
          magic
          (be_state.compiler-backend-global-shared-view scratch-reg))
        "")]
    [magic-src : String
      (if (string.eq home "")
        (owned_view.compiler-owned-shared-view scratch-reg)
        home)]
    [quotient-asm : String
      (if want-remainder
        (str_cat.str-cat
          "    movq %rax, "
          dividend-reg
          "\n"
          magic-load
          "    imulq "
          magic-src
          "\n"
          (if (compiler-backend-u64-high-bit? magic)
            (str_cat.str-cat "    addq " dividend-reg ", %rdx\n")
            "")
          (compiler-backend-divmod-shift-reg "sar" shift "%rdx")
          "    movq "
          dividend-reg
          ", "
          mask-reg
          "\n    sarq $63, "
          mask-reg
          "\n    subq "
          mask-reg
          ", %rdx\n")
        (str_cat.str-cat
          "    movq %rax, "
          dividend-reg
          "\n"
          magic-load
          "    imulq "
          magic-src
          "\n    movq %rdx, %rax\n"
          (if (compiler-backend-u64-high-bit? magic)
            (str_cat.str-cat "    addq " dividend-reg ", %rax\n")
            "")
          (compiler-backend-divmod-shift-rax "sar" shift)
          "    movq "
          dividend-reg
          ", "
          mask-reg
          "\n    sarq $63, "
          mask-reg
          "\n    subq "
          mask-reg
          ", %rax\n"))]
    (if want-remainder
      (str_cat.str-cat
        quotient-asm
        (compiler-backend-divmod-remainder-from-quotient-reg
          (cast divisor : u64)
          "%rdx"
          scratch-reg
          dividend-reg))
      (if negative-divisor
        (str_cat.str-cat quotient-asm "    negq %rax\n")
        quotient-asm))))

;; Clang-shaped signed constant division. Normally `src-reg` owns the dividend
;; for the duration of the expansion and is never %rax/%rdx. A low-magic or
;; power-of-two quotient that only seeds %rax may instead pass `%rax` itself;
;; remainder and high-magic shapes still need a surviving non-fixed SRC. The
;; truncation correction is the sign bit of the pre-shift quotient word, staged
;; through %rax after the multiply, rather than a second scratch holding the
;; dividend's sign mask.
(define (compiler-backend-divmod-result-move
  [src-reg : (& src-reg str)]
  [result-reg : (& result-reg str)]) : String
  (if (string.eq src-reg result-reg)
    ""
    (str_cat.str-cat "    movq " src-reg ", " result-reg "\n")))

(define (compiler-backend-signed-remainder-from-src
  [divisor : u64]
  [quotient-reg : String]
  [product-reg : String]
  [scratch-reg : String]
  [src-reg : (& src-reg str)]) : String
  (if (be_operand.compiler-backend-imm32? (cast divisor : i64))
    (str_cat.str-cat
      "    imulq $"
      (string.int->string (cast divisor : i64))
      ", "
      quotient-reg
      ", "
      product-reg
      "\n    subq "
      product-reg
      ", "
      src-reg
      "\n")
    (str_cat.str-cat
      (compiler-backend-emit-load-u64-absolute
        divisor
        (be_state.compiler-backend-global-shared-view scratch-reg))
      "    imulq "
      quotient-reg
      ", "
      scratch-reg
      "\n    subq "
      scratch-reg
      ", "
      src-reg
      "\n")))

(define (compiler-backend-signed-power-divmod-src-asm
  [divisor : u64]
  [negative-divisor : bool]
  [want-remainder : bool]
  [scratch-reg : String]
  [src-reg : String]
  [result-reg : String]) : String
  (let
    [shift : i64 (compiler-backend-u64-log2 divisor)]
    [mask : u64 (- divisor (cast 1 : u64))]
    [mask-asm : String
      (if (be_operand.compiler-backend-imm32? (cast mask : i64))
        (str_cat.str-cat
          "    andl $"
          (string.int->string (cast mask : i64))
          ", %edx\n")
        (str_cat.str-cat
          (compiler-backend-emit-load-u64-absolute
            mask
            (be_state.compiler-backend-global-shared-view scratch-reg))
          (str_cat.str-cat "    andq " scratch-reg ", %rdx\n")))]
    [quotient-asm : String
      (str_cat.str-cat
        (compiler-backend-divmod-result-move src-reg "%rax")
        "    movq %rax, %rdx\n    sarq $63, %rdx\n"
        mask-asm
        "    addq %rdx, %rax\n"
        (compiler-backend-divmod-shift-rax "sar" shift))]
    (if want-remainder
      (str_cat.str-cat
        quotient-asm
        (compiler-backend-signed-remainder-from-src
          divisor
          "%rax"
          "%rdx"
          scratch-reg
          src-reg)
        (compiler-backend-divmod-result-move src-reg result-reg))
      (str_cat.str-cat
        quotient-asm
        (if negative-divisor
          "    negq %rax\n"
          "")
        (compiler-backend-divmod-result-move "%rax" result-reg)))))

(define (compiler-backend-signed-magic-divmod-src-asm
  [divisor : i64]
  [negative-divisor : bool]
  [want-remainder : bool]
  [scratch-reg : String]
  [src-reg : String]
  [result-reg : String]
  [hoist : CompilerBackendConstHoistHome]) : String
  (let
    [plan : be_div.CompilerBackendSignedDivMagic
      (be_div.compiler-backend-signed-divisor-magic divisor)]
    [magic : u64 plan.magic]
    [shift : i64 plan.shift]
    ;; A wide remainder divisor needs the materialisation register again after
    ;; the quotient multiply.  Do not pin that rare site to a loop-hoisted home;
    ;; inline the magic and reuse its one register for q*d instead.
    [wide-remainder? : bool
      (and want-remainder (not (be_operand.compiler-backend-imm32? divisor)))]
    [candidate-home : String (compiler-backend-magic-home-operand hoist magic)]
    [home : String
      (if wide-remainder?
        ""
        candidate-home)]
    [magic-load : String
      (if (string.eq home "")
        (compiler-backend-emit-load-u64-absolute
          magic
          (be_state.compiler-backend-global-shared-view scratch-reg))
        "")]
    [magic-src : String
      (if (string.eq home "")
        (owned_view.compiler-owned-shared-view scratch-reg)
        home)]
    [quotient-prefix : String
      (str_cat.str-cat
        (compiler-backend-divmod-result-move src-reg "%rax")
        magic-load
        "    imulq "
        magic-src
        "\n"
        (if (compiler-backend-u64-high-bit? magic)
          (str_cat.str-cat "    addq " src-reg ", %rdx\n")
          "")
        "    movq %rdx, %rax\n    shrq $63, %rax\n"
        (compiler-backend-divmod-shift-reg "sar" shift "%rdx"))]
    (if want-remainder
      (str_cat.str-cat
        quotient-prefix
        "    addq %rax, %rdx\n"
        (compiler-backend-signed-remainder-from-src
          (cast divisor : u64)
          "%rdx"
          "%rax"
          scratch-reg
          src-reg)
        (compiler-backend-divmod-result-move src-reg result-reg))
      ;; %rax holds the sign correction and %rdx the shifted high word. The
      ;; final add is commutative, so accumulate into a requested %rax result
      ;; directly instead of producing %rdx and immediately copying it.
      (if (string.eq result-reg "%rax")
        (str_cat.str-cat
          quotient-prefix
          "    addq %rdx, %rax\n"
          (if negative-divisor
            "    negq %rax\n"
            ""))
        (str_cat.str-cat
          quotient-prefix
          "    addq %rax, %rdx\n"
          (if negative-divisor
            "    negq %rdx\n"
            "")
          (compiler-backend-divmod-result-move "%rdx" result-reg))))))

(define (compiler-backend-signed-constant-divmod-src-asm
  [divisor : i64]
  [want-remainder : bool]
  [scratch-reg : String]
  [src-reg : String]
  [result-reg : String]
  [hoist : CompilerBackendConstHoistHome]) : be_state.CompilerBackendMaybeAsm
  (if (= divisor 1)
    (Some
      (if want-remainder
        (str_cat.str-cat "    xorq " result-reg ", " result-reg "\n")
        (compiler-backend-divmod-result-move src-reg result-reg)))
    (if (= divisor (compiler-backend-i64-min-value))
      (No)
      (let
        [negative-divisor : bool (< divisor 0)]
        [abs-divisor : i64
          (if negative-divisor
            (- 0 divisor)
            divisor)]
        [abs-u64 : u64 (cast abs-divisor : u64)]
        (Some
          (if (compiler-backend-u64-power-of-two? abs-u64)
            (compiler-backend-signed-power-divmod-src-asm
              abs-u64
              negative-divisor
              want-remainder
              scratch-reg
              src-reg
              result-reg)
            (compiler-backend-signed-magic-divmod-src-asm
              abs-divisor
              negative-divisor
              want-remainder
              scratch-reg
              src-reg
              result-reg
              hoist)))))))

(define (compiler-backend-signed-constant-divmod-strength-asm
  [divisor : i64]
  [want-remainder : bool]
  [scratch-reg : String]
  [dividend-reg : String]
  [mask-reg : String]
  [hoist : CompilerBackendConstHoistHome]) : be_state.CompilerBackendMaybeAsm
  (if (= divisor 1)
    (Some
      (if want-remainder
        "    xorq %rax, %rax\n"
        ""))
    (if (= divisor (compiler-backend-i64-min-value))
      (No)
      (let
        [negative-divisor : bool (< divisor 0)]
        [abs-divisor : i64
          (if (< divisor 0)
            (- 0 divisor)
            divisor)]
        [abs-u64 : u64 (cast abs-divisor : u64)]
        (Some
          (if (compiler-backend-u64-power-of-two? abs-u64)
            (compiler-backend-signed-power-divmod-asm
              abs-u64
              negative-divisor
              want-remainder
              scratch-reg
              dividend-reg
              mask-reg)
            (compiler-backend-signed-magic-divmod-asm
              abs-divisor
              negative-divisor
              want-remainder
              scratch-reg
              dividend-reg
              mask-reg
              hoist)))))))

(define (compiler-backend-unsigned-constant-divmod-strength-asm
  [divisor : u64]
  [want-remainder : bool]
  [scratch-reg : String]
  [dividend-reg : String]
  [hoist : CompilerBackendConstHoistHome]) : be_state.CompilerBackendMaybeAsm
  (if (compiler-backend-u64-power-of-two? divisor)
    (Some
      (compiler-backend-unsigned-power-divmod-asm
        divisor
        want-remainder
        scratch-reg))
    (compiler-backend-unsigned-magic-divmod-asm
      divisor
      want-remainder
      scratch-reg
      dividend-reg
      hoist)))

(define (compiler-backend-constant-divmod-unguarded-asm
  [type-segment-bases : i64]
  [n : i64]
  [ty : compiler_ast_types.AstType]
  [want-remainder : bool]
  [scratch-reg : String]) : String
  (str_cat.str-cat
    (compiler-backend-emit-load-i64-absolute
      (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
        (compiler-backend-normalized-signed-immediate type-segment-bases n ty)
        (cast
          (compiler-backend-normalized-unsigned-immediate
            type-segment-bases
            n
            ty)
          : i64))
      (be_state.compiler-backend-global-shared-view scratch-reg))
    (compiler-backend-binop-divmod-core-asm
      type-segment-bases
      ty
      want-remainder
      scratch-reg)))

(define (compiler-backend-constant-divmod-asm
  [type-segment-bases : i64]
  [n : i64]
  [ty : compiler_ast_types.AstType]
  [want-remainder : bool]
  [scratch-reg : String]
  [dividend-reg : String]
  [mask-reg : String]
  [hoist : CompilerBackendConstHoistHome]) : be_state.CompilerBackendMaybeAsm
  (cond
    [(not (compiler-backend-divmod-safe-literal-i64? type-segment-bases n ty))
      (No)]
    [(not (= (be_operand.compiler-backend-type-size type-segment-bases ty) 8))
      (Some
        (compiler-backend-constant-divmod-unguarded-asm
          type-segment-bases
          n
          ty
          want-remainder
          scratch-reg))]
    [(be_facts.compiler-backend-type-signed? type-segment-bases ty)
      (let
        [divisor : i64
          (compiler-backend-normalized-signed-immediate type-segment-bases n ty)]
        (match (compiler-backend-signed-constant-divmod-strength-asm
          divisor
          want-remainder
          (be_state.compiler-backend-global-shared-view scratch-reg)
          dividend-reg
          mask-reg
          hoist)
          [(Some asm) (Some asm)]
          [(No)
            (Some
              (compiler-backend-constant-divmod-unguarded-asm
                type-segment-bases
                n
                ty
                want-remainder
                scratch-reg))]))]
    [else
      (let
        [divisor : u64
          (compiler-backend-normalized-unsigned-immediate
            type-segment-bases
            n
            ty)]
        ;; The 64-bit magic search below assumes divisor < 2^63 so rem*2 cannot
        ;; overflow while generating constants. Wider unsigned literals reduce to
        ;; a compare because the quotient can only be 0 or 1.
        (if (compiler-backend-u64-high-bit? divisor)
          (Some
            (compiler-backend-unsigned-high-bit-divmod-asm
              divisor
              want-remainder
              scratch-reg
              dividend-reg))
          (match (compiler-backend-unsigned-constant-divmod-strength-asm
            divisor
            want-remainder
            (be_state.compiler-backend-global-shared-view scratch-reg)
            dividend-reg
            hoist)
            [(Some asm) (Some asm)]
            [(No)
              (Some
                (compiler-backend-constant-divmod-unguarded-asm
                  type-segment-bases
                  n
                  ty
                  want-remainder
                  scratch-reg))])))]))

(define (compiler-backend-constant-safe-divmod-asm
  [type-segment-bases : i64]
  [n : i64]
  [ty : compiler_ast_types.AstType]
  [want-remainder : bool]
  [scratch-reg : String]
  [dividend-reg : String]
  [mask-reg : String]
  [hoist : CompilerBackendConstHoistHome]) : be_state.CompilerBackendMaybeAsm
  (match (compiler-backend-constant-divmod-asm
    type-segment-bases
    n
    (be_state.compiler-backend-global-shared-view ty)
    want-remainder
    (be_state.compiler-backend-global-shared-view scratch-reg)
    dividend-reg
    mask-reg
    hoist)
    [(Some asm) (Some asm)]
    [(No)
      (if (and
        (be_facts.compiler-backend-type-signed? type-segment-bases ty)
        (=
          (compiler-backend-normalized-signed-immediate type-segment-bases n ty)
          (- 0 1)))
        (Some
          (compiler-backend-constant-divmod-unguarded-asm
            type-segment-bases
            n
            ty
            want-remainder
            scratch-reg))
        (No))]))

(define (compiler-backend-binop-literal-divmod-asm
  [type-segment-bases : i64]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [scratch-reg : String]
  [dividend-reg : String]
  [mask-reg : String]
  [hoist : CompilerBackendConstHoistHome]) : be_state.CompilerBackendMaybeAsm
  (match op
    [(Div)
      (match (be_operand.compiler-backend-value-as-i64 rhs)
        [(Some n)
          (compiler-backend-constant-divmod-asm
            type-segment-bases
            n
            ty
            false
            scratch-reg
            dividend-reg
            mask-reg
            hoist)]
        [(None) (No)])]
    [(Mod)
      (match (be_operand.compiler-backend-value-as-i64 rhs)
        [(Some n)
          (compiler-backend-constant-divmod-asm
            type-segment-bases
            n
            ty
            true
            scratch-reg
            dividend-reg
            mask-reg
            hoist)]
        [(None) (No)])]
    [(SafeDiv)
      (match (be_operand.compiler-backend-value-as-i64 rhs)
        [(Some n)
          (compiler-backend-constant-safe-divmod-asm
            type-segment-bases
            n
            ty
            false
            scratch-reg
            dividend-reg
            mask-reg
            hoist)]
        [(None) (No)])]
    [(SafeMod)
      (match (be_operand.compiler-backend-value-as-i64 rhs)
        [(Some n)
          (compiler-backend-constant-safe-divmod-asm
            type-segment-bases
            n
            ty
            true
            scratch-reg
            dividend-reg
            mask-reg
            hoist)]
        [(None) (No)])]
    [_ (No)]))

(define (compiler-backend-binop-wants-remainder?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]) : bool
  (match op
    [(or (Mod) (SafeMod)) true]
    [_ false]))

(define (compiler-backend-literal-divmod-shape?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [rhs : compiler_ir_types.CompilerIrValue]) : bool
  (and
    (match op
      [(or (Div) (Mod) (SafeDiv) (SafeMod)) true]
      [_ false])
    (match (be_operand.compiler-backend-value-as-i64 rhs)
      [(Some _) true]
      [(None) false])))

(define (compiler-backend-signed-literal-divmod-src-shape?
  [type-segment-bases : i64]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]) : bool
  (and
    (compiler-backend-const-hoist-divmod-op? op)
    (be_facts.compiler-backend-type-signed? type-segment-bases ty)
    (= (be_operand.compiler-backend-type-size type-segment-bases ty) 8)
    (match (be_operand.compiler-backend-value-as-i64 rhs)
      [(Some n)
        (and
          (compiler-backend-divmod-safe-literal-i64? type-segment-bases n ty)
          (not
            (=
              (compiler-backend-normalized-signed-immediate
                type-segment-bases
                n
                ty)
              (compiler-backend-i64-min-value))))]
      [(None) false])))

;; Does the clang-shaped expansion need a materialisation register at this
;; site?  A resident loop-hoisted magic satisfies the common magic case.  A
;; wide power-of-two mask, or a wide remainder divisor that must reuse the
;; magic register after the quotient multiply, still needs one.
(define (compiler-backend-signed-literal-divmod-needs-material-reg?
  [type-segment-bases : i64]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : (& ty compiler_ast_types.AstType)]
  [want-remainder : bool]
  [hoist : CompilerBackendConstHoistHome]) : bool
  (match (be_operand.compiler-backend-value-as-i64 rhs)
    [(Some n)
      (let
        [divisor : i64
          (compiler-backend-normalized-signed-immediate type-segment-bases n ty)]
        [abs-divisor : i64
          (if (< divisor 0)
            (- 0 divisor)
            divisor)]
        [abs-u64 : u64 (cast abs-divisor : u64)]
        (if (= abs-divisor 1)
          false
          (if (compiler-backend-u64-power-of-two? abs-u64)
            (not
              (and
                (be_operand.compiler-backend-imm32?
                  (cast (- abs-u64 (cast 1 : u64)) : i64))
                (or
                  (not want-remainder)
                  (be_operand.compiler-backend-imm32? abs-divisor))))
            (or
              (and
                want-remainder
                (not (be_operand.compiler-backend-imm32? abs-divisor)))
              (let
                [plan : be_div.CompilerBackendSignedDivMagic
                  (be_div.compiler-backend-signed-divisor-magic abs-divisor)]
                (string.eq
                  (compiler-backend-magic-home-operand hoist plan.magic)
                  ""))))))]
    [(None) true]))

;; May a quotient load its dividend straight into fixed %rax? One-operand imul
;; destroys %rax, so this is legal only when the expansion never reads SRC
;; again: power-of-two quotients and low-bit magic quotients. Remainders need
;; SRC for `dividend - quotient*divisor`; high-bit magic needs it for
;; `addq SRC, %rdx`; divisor 1 is already a direct result move and gains nothing.
(define (compiler-backend-signed-literal-divmod-direct-rax-src?
  [type-segment-bases : i64]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : (& ty compiler_ast_types.AstType)]) : bool
  (and
    (not (compiler-backend-binop-wants-remainder? op))
    (match (be_operand.compiler-backend-value-as-i64 rhs)
      [(Some n)
        (let
          [divisor : i64
            (compiler-backend-normalized-signed-immediate
              type-segment-bases
              n
              ty)]
          (if (or
            (not
              (compiler-backend-divmod-safe-literal-i64?
                type-segment-bases
                n
                ty))
            (= divisor (compiler-backend-i64-min-value)))
            false
            (let
              [abs-divisor : i64
                (if (< divisor 0)
                  (- 0 divisor)
                  divisor)]
              [abs-u64 : u64 (cast abs-divisor : u64)]
              (and
                (not (= abs-divisor 1))
                (or
                  (compiler-backend-u64-power-of-two? abs-u64)
                  (not
                    (compiler-backend-u64-high-bit?
                      (__tl-project-field
                        (be_div.compiler-backend-signed-divisor-magic
                          abs-divisor)
                        magic))))))))]
      [(None) false])))

(define (compiler-backend-signed-literal-divmod-src-asm
  [type-segment-bases : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [scratch-reg : String]
  [src-reg : String]
  [result-reg : String]
  [hoist : CompilerBackendConstHoistHome]) : be_state.CompilerBackendMaybeAsm
  (match (be_operand.compiler-backend-value-as-i64 rhs)
    [(Some n)
      (compiler-backend-signed-constant-divmod-src-asm
        (compiler-backend-normalized-signed-immediate type-segment-bases n ty)
        (compiler-backend-binop-wants-remainder? op)
        scratch-reg
        src-reg
        result-reg
        hoist)]
    [(None) (No)]))

;; Signed i64 literal divmod uses the clang shape: one materialisation register
;; (unless M-F supplies the magic) plus one SRC copy because the legacy entry to
;; this wrapper has the dividend in fixed %rax.  There is no saved-dividend +
;; sign-mask pair.  Unsigned and narrow paths retain their existing lowering.
(define (compiler-backend-binop-literal-divmod-asm-dst
  [type-segment-bases : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [dst : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.CompilerBackendMaybeAsm
  ;; Generic scalar binop emission probes this helper before its immediate and
  ;; source-operand fallbacks. Keep the probe side-effect-free unless the IR is
  ;; actually a literal div/mod; otherwise ordinals 2-4 do not exist.
  (if (compiler-backend-literal-divmod-shape?
    op
    (be_state.compiler-backend-global-shared-view rhs))
    (let
      [hoist : CompilerBackendConstHoistHome
        (compiler-backend-const-hoist-here
          (be_state.compiler-backend-state-function-state backend-state))]
      [hoist-reg : String
        (compiler-backend-magic-home-reg-name
          (be_state.compiler-backend-global-shared-view hoist))]
      (if (compiler-backend-signed-literal-divmod-src-shape?
        type-segment-bases
        op
        (be_state.compiler-backend-global-shared-view rhs)
        (be_state.compiler-backend-global-shared-view ty))
        (let
          [needs-material : bool
            (compiler-backend-signed-literal-divmod-needs-material-reg?
              type-segment-bases
              (be_state.compiler-backend-global-shared-view rhs)
              ty
              (compiler-backend-binop-wants-remainder? op)
              (be_state.compiler-backend-global-shared-view hoist))]
          [magic : String
            (if needs-material
              (be_operand.compiler-backend-scavenge-reg
                dst
                (if (string.eq hoist-reg "")
                  (compiler-backend-binop-scavenge-exclude-for-op op)
                  (be_operand.compiler-backend-scavenge-exclude-append
                    (compiler-backend-binop-scavenge-exclude-for-op op)
                    5
                    (be_state.compiler-backend-global-shared-view hoist-reg)))
                (if (string.eq hoist-reg "")
                  5
                  6)
                "%r8"
                backend-state)
              "")]
          [src-excl : (__tl_dyn-array String)
            (compiler-backend-divmod-dividend-exclude
              (be_state.compiler-backend-global-shared-view magic))]
          [src : String
            (compiler-backend-scavenge-divmod-src-reg
              dst
              (if (string.eq hoist-reg "")
                src-excl
                (be_operand.compiler-backend-scavenge-exclude-append
                  src-excl
                  5
                  (be_state.compiler-backend-global-shared-view hoist-reg)))
              (if (string.eq hoist-reg "")
                5
                6)
              backend-state)]
          (match (compiler-backend-signed-literal-divmod-src-asm
            type-segment-bases
            op
            rhs
            ty
            magic
            (be_state.compiler-backend-global-shared-view src)
            "%rax"
            hoist)
            [(Some asm) (Some (str_cat.str-cat "    movq %rax, " src "\n" asm))]
            [(No) (No)]))
        (let
          [op-excl : (__tl_dyn-array String)
            (compiler-backend-binop-scavenge-exclude-for-op op)]
          [magic : String
            (be_operand.compiler-backend-scavenge-reg
              dst
              (if (string.eq hoist-reg "")
                op-excl
                (be_operand.compiler-backend-scavenge-exclude-append
                  op-excl
                  5
                  (be_state.compiler-backend-global-shared-view hoist-reg)))
              (if (string.eq hoist-reg "")
                5
                6)
              "%r8"
              backend-state)]
          [dividend-excl : (__tl_dyn-array String)
            (compiler-backend-divmod-dividend-exclude
              (be_state.compiler-backend-global-shared-view magic))]
          [dividend : String
            (be_operand.compiler-backend-scavenge-reg
              dst
              (if (string.eq hoist-reg "")
                dividend-excl
                (be_operand.compiler-backend-scavenge-exclude-append
                  dividend-excl
                  5
                  (be_state.compiler-backend-global-shared-view hoist-reg)))
              (if (string.eq hoist-reg "")
                5
                6)
              "%r10"
              backend-state)]
          [mask-excl : (__tl_dyn-array String)
            (compiler-backend-divmod-mask-exclude
              (be_state.compiler-backend-global-shared-view magic)
              (be_state.compiler-backend-global-shared-view dividend))]
          [mask : String
            (be_operand.compiler-backend-scavenge-reg
              dst
              (if (string.eq hoist-reg "")
                mask-excl
                (be_operand.compiler-backend-scavenge-exclude-append
                  mask-excl
                  6
                  (be_state.compiler-backend-global-shared-view hoist-reg)))
              (if (string.eq hoist-reg "")
                6
                7)
              "%r9"
              backend-state)]
          (compiler-backend-binop-literal-divmod-asm
            type-segment-bases
            op
            rhs
            ty
            magic
            dividend
            mask
            hoist))))
    (No)))

;; Same, but at the current emit point (no dst -- tail-return position). The magic
;; register is scavenged at the return point, so a pooled %r8 live across the fused
;; return is not clobbered by the constant-divmod sequence.
(define (compiler-backend-binop-literal-divmod-asm-here
  [type-segment-bases : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.CompilerBackendMaybeAsm
  ;; This helper is probed by generic return-binop emission. Reject a
  ;; non-literal/non-divmod shape before scavenging any registers.
  (if (compiler-backend-literal-divmod-shape?
    op
    (be_state.compiler-backend-global-shared-view rhs))
    (let
      ;; Tail-return position: never inside a hoisted loop region (a loop body
      ;; has no Ret), so no site lookup here.
      [hoist : CompilerBackendConstHoistHome (CompilerBackendNoConstHoistHome)]
      (if (compiler-backend-signed-literal-divmod-src-shape?
        type-segment-bases
        op
        (be_state.compiler-backend-global-shared-view rhs)
        (be_state.compiler-backend-global-shared-view ty))
        (let
          [magic : String
            (if (compiler-backend-signed-literal-divmod-needs-material-reg?
              type-segment-bases
              (be_state.compiler-backend-global-shared-view rhs)
              ty
              (compiler-backend-binop-wants-remainder? op)
              (be_state.compiler-backend-global-shared-view hoist))
              (be_operand.compiler-backend-scavenge-reg-here
                (compiler-backend-binop-scavenge-exclude-for-op op)
                5
                "%r8"
                backend-state)
              "")]
          [src : String
            (compiler-backend-scavenge-divmod-src-reg-here
              (compiler-backend-divmod-dividend-exclude
                (be_state.compiler-backend-global-shared-view magic))
              5
              backend-state)]
          (match (compiler-backend-signed-literal-divmod-src-asm
            type-segment-bases
            op
            rhs
            ty
            magic
            (be_state.compiler-backend-global-shared-view src)
            "%rax"
            hoist)
            [(Some asm) (Some (str_cat.str-cat "    movq %rax, " src "\n" asm))]
            [(No) (No)]))
        (let
          [magic : String
            (be_operand.compiler-backend-scavenge-reg-here
              (compiler-backend-binop-scavenge-exclude-for-op op)
              5
              "%r8"
              backend-state)]
          [dividend : String
            (be_operand.compiler-backend-scavenge-reg-here
              (compiler-backend-divmod-dividend-exclude
                (be_state.compiler-backend-global-shared-view magic))
              5
              "%r10"
              backend-state)]
          [mask : String
            (be_operand.compiler-backend-scavenge-reg-here
              (compiler-backend-divmod-mask-exclude
                (be_state.compiler-backend-global-shared-view magic)
                (be_state.compiler-backend-global-shared-view dividend))
              6
              "%r9"
              backend-state)]
          (compiler-backend-binop-literal-divmod-asm
            type-segment-bases
            op
            rhs
            ty
            magic
            dividend
            mask
            hoist))))
    (No)))

(define (compiler-backend-shift-count-width
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]) : i64
  (* (be_operand.compiler-backend-type-size type-segment-bases ty) 8))

(define (compiler-backend-shift-count-valid-typed?
  [type-segment-bases : i64]
  [count : i64]
  [count-ty : compiler_ast_types.AstType]
  [lhs-ty : compiler_ast_types.AstType]) : bool
  (if (be_facts.compiler-backend-type-signed? type-segment-bases count-ty)
    (and
      (>= count 0)
      (< count (compiler-backend-shift-count-width type-segment-bases lhs-ty)))
    (match count-ty
      [(U64)
        (<
          (cast count : u64)
          (cast
            (compiler-backend-shift-count-width type-segment-bases lhs-ty)
            : u64))]
      [_
        (and
          (>= count 0)
          (<
            count
            (compiler-backend-shift-count-width type-segment-bases lhs-ty)))])))

;; Shift counts proven in range. `(shr x (bit-and n 63))` is the idiom for a
;; bit position, and its count can only be 0..63: a `bit_and` with a literal
;; `c >= 0` keeps no bit `c` lacks, so the result lies in [0, c]. A shift whose
;; count var is that bounded, below the shifted width, can neither abort, so its
;; guard is unreachable.
;;
;; The table is read off the blocks being EMITTED (after coloring, where one var
;; id may name several values), per var id: the largest `c` over its
;; definitions, plus one, when EVERY definition is such a `bit_and`; -1 when any
;; is not, when a parameter binds it, or when an `addr_of` takes its address (a
;; store through the address redefines it with no instruction naming it); 0 when
;; nothing defines it.
(define (compiler-backend-bit-and-literal-bound
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]) : i64
  (match rhs
    [(I64 c) c]
    [_
      (match lhs
        [(I64 c) c]
        [_ -1])]))

(define (compiler-backend-shift-count-bounds-note!
  [bounds : (&mut bounds (__tl_dyn-array i64))]
  [var : i64]
  [bound : i64]) : unit
  (if (or (< var 0) (>= var (array-length bounds)))
    unit
    (let
      [current : i64 (array-ref bounds var)]
      (cond
        [(< current 0) unit]
        [(or (< bound 0) (>= bound 2147483647))
          (set! (array-ref bounds var) -1)]
        [(> (+ bound 1) current) (set! (array-ref bounds var) (+ bound 1))]
        [else unit]))))

(define (compiler-backend-shift-count-bounds-instr-seq!
  [bounds : (&mut bounds (__tl_dyn-array i64))]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : unit
  (let
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [count : i64 instrs.len]
    (for [index (iterator.range 0 count)]
      (match (be_state.compiler-backend-global-array-element-shared-view
        slots
        index)
        [(BinOp dst (BitAnd) lhs rhs _)
          (compiler-backend-shift-count-bounds-note!
            bounds
            dst
            (compiler-backend-bit-and-literal-bound lhs rhs))]
        [(AddrOf dst src _storage-words)
          (compiler-backend-shift-count-bounds-note! bounds dst -1)
          (compiler-backend-shift-count-bounds-note! bounds src -1)]
        [_
          (compiler-backend-shift-count-bounds-note!
            bounds
            (let
              [instr
                (be_state.compiler-backend-global-array-element-shared-view
                  slots
                  index)]
              (compiler_ir_types.compiler-ir-instr-dst instr))
            -1)]))))

(define (compiler-backend-shift-count-bounds
  [vars : i64]
  [params : compiler_ir_types.CompilerIrParamSeq]
  [blocks : compiler_ir_types.CompilerIrBlockList]) : (__tl_dyn-array i64)
  (let
    [bounds : (__tl_dyn-array i64)
      (__tl_make-array
        i64
        (if (< vars 0)
          0
          vars))]
    [seq : compiler_ir_types.CompilerIrBlockSeq
      (compiler_liveness.compiler-live-ir-block-list-to-seq (& blocks))]
    [block-count : i64 (compiler_ir_types.compiler-ir-block-seq-count seq)]
    (for [position (iterator.range 0 params.len)]
      (match (compiler_ir_types.compiler-ir-param-seq-borrow params position)
        [(Param _ _ id)
          (compiler-backend-shift-count-bounds-note! (&mut bounds) id -1)]))
    (for [b (iterator.range 0 block-count)]
      (match (compiler_ir_types.compiler-ir-block-seq-ref seq b)
        [(Block _ instrs)
          (compiler-backend-shift-count-bounds-instr-seq! (&mut bounds) instrs)]))
    bounds))

;; The bound (plus one) of `instr`'s shift count, or 0: only a scalar shift whose
;; count is a var the table bounds has one.
(define (compiler-backend-instr-shift-count-bound
  [function-state : be_state.CompilerBackendFunctionState]
  [instr : (& compiler_ir_types.CompilerIrInstr)]) : i64
  (match instr
    [(BinOp _ op _ (Var count) _)
      (if (compiler-backend-binop-shift-op? op)
        (let
          [bounds : (__tl_dyn-array i64)
            (be_state.compiler-backend-function-state-i64-array
              function-state
              be_state.compiler-backend-function-i64-array-shift-count-bounds)]
          (if (or (< count 0) (>= count (array-length bounds)))
            0
            (let
              [bound : i64 (array-ref bounds count)]
              (if (> bound 0)
                bound
                0))))
        0)]
    [_ 0]))

(define (compiler-backend-shift-guard-asm
  [type-segment-bases : i64]
  [lhs-ty : compiler_ast_types.AstType]
  [count-ty : compiler_ast_types.AstType]
  [count-reg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [bound : i64
      (be_state.compiler-backend-function-state-i64
        (be_state.compiler-backend-state-function-state backend-state)
        be_state.compiler-backend-function-i64-shift-count-bound)]
    (if (and
      (> bound 0)
      (<
        (- bound 1)
        (compiler-backend-shift-count-width
          type-segment-bases
          (be_state.compiler-backend-global-shared-view lhs-ty))))
      ;; The count is proven in [0, width): neither abort is reachable.
      ""
      (compiler-backend-shift-guard-asm-checked
        type-segment-bases
        lhs-ty
        count-ty
        count-reg
        backend-state))))

(define (compiler-backend-shift-guard-asm-checked
  [type-segment-bases : i64]
  [lhs-ty : compiler_ast_types.AstType]
  [count-ty : compiler_ast_types.AstType]
  [count-reg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [width : i64 (compiler-backend-shift-count-width type-segment-bases lhs-ty)]
    [count-sized : String
      (be_operand.compiler-backend-sized-reg
        type-segment-bases
        (be_state.compiler-backend-global-shared-view count-reg)
        (be_state.compiler-backend-global-shared-view count-ty))]
    [count-signed? : bool
      (be_facts.compiler-backend-type-signed? type-segment-bases count-ty)]
    [negative-abort : String
      (if (compiler-backend-abort-site-active? backend-state)
        (compiler-backend-abort-call-shift-asm
          "tl_shift_abort_at"
          "shift_negative"
          (compiler-backend-abort-normalized-push-asm
            type-segment-bases
            (be_state.compiler-backend-global-shared-view count-ty)
            (be_state.compiler-backend-global-shared-view count-reg))
          (str_cat.str-cat "    pushq $" (string.int->string width) "\n")
          false
          0
          backend-state)
        "    call tl_shift_abort\n")]
    [large-abort : String
      (if (compiler-backend-abort-site-active? backend-state)
        (compiler-backend-abort-call-shift-asm
          "tl_shift_abort_at"
          "shift_large"
          (compiler-backend-abort-normalized-push-asm
            type-segment-bases
            (be_state.compiler-backend-global-shared-view count-ty)
            count-reg)
          (str_cat.str-cat "    pushq $" (string.int->string width) "\n")
          (not count-signed?)
          0
          backend-state)
        "    call tl_shift_abort\n")]
    [negative-check : String
      (if count-signed?
        (str_cat.str-cat
          "    test"
          (be_operand.compiler-backend-int-instruction-suffix
            type-segment-bases
            (be_state.compiler-backend-global-shared-view count-ty))
          " "
          count-sized
          ", "
          count-sized
          "\n    jge 1f\n"
          negative-abort
          "1:\n")
        "")]
    (str_cat.str-cat
      negative-check
      (str_cat.str-cat
        "    cmp"
        (be_operand.compiler-backend-int-instruction-suffix
          type-segment-bases
          count-ty)
        " $"
        (string.int->string width)
        ", "
        count-sized
        "\n    jb 1f\n"
        large-abort
        "1:\n"))))

(define (compiler-backend-binop-shift-asm
  [type-segment-bases : i64]
  [mnemonic : String]
  [lhs-ty : compiler_ast_types.AstType]
  [count-ty : compiler_ast_types.AstType]
  [lhs : String]
  [count-reg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    ;; Bound to a local (behavior-neutral) to avoid a seed-typechecker
    ;; spurious mismatch on the enclosing append operands.
    [count-move : String
      (if (string.eq count-reg "%rcx")
        ""
        (str_cat.str-cat "    movq " count-reg ", %rcx\n"))]
    (str_cat.str-cat
      (compiler-backend-shift-guard-asm
        type-segment-bases
        (be_state.compiler-backend-global-shared-view lhs-ty)
        count-ty
        count-reg
        backend-state)
      count-move
      (str_cat.str-cat
        "    "
        mnemonic
        (be_operand.compiler-backend-int-instruction-suffix
          type-segment-bases
          lhs-ty)
        " %cl, "
        lhs
        "\n"))))

(define (compiler-backend-binop-asm
  [type-segment-bases : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [ty : compiler_ast_types.AstType]
  [rhs-reg : String]
  [staging-reg : String]
  [planned-min : String]
  [planned-neg : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [lhs : String
      (be_operand.compiler-backend-sized-reg
        type-segment-bases
        (be_state.compiler-backend-global-shared-view staging-reg)
        (be_state.compiler-backend-global-shared-view ty))]
    [rhs : String
      (be_operand.compiler-backend-sized-reg
        type-segment-bases
        (be_state.compiler-backend-global-shared-view rhs-reg)
        (be_state.compiler-backend-global-shared-view ty))]
    [_suffix : String
      (be_operand.compiler-backend-int-instruction-suffix
        type-segment-bases
        (be_state.compiler-backend-global-shared-view ty))]
    (match (be_state.compiler-backend-global-shared-view op)
      [(Add)
        (compiler-backend-binop-reg-asm type-segment-bases "add" ty rhs lhs)]
      [(Sub)
        (compiler-backend-binop-reg-asm type-segment-bases "sub" ty rhs lhs)]
      [(Mul)
        (if (= (be_operand.compiler-backend-type-size type-segment-bases ty) 1)
          (str_cat.str-cat "    imulq " rhs-reg ", " staging-reg "\n")
          (compiler-backend-binop-reg-asm type-segment-bases "imul" ty rhs lhs))]
      [(Div)
        (compiler-backend-binop-divmod-asm
          type-segment-bases
          ty
          false
          rhs-reg
          planned-min
          planned-neg
          backend-state)]
      [(Mod)
        (compiler-backend-binop-divmod-asm
          type-segment-bases
          ty
          true
          rhs-reg
          planned-min
          planned-neg
          backend-state)]
      [(SafeDiv)
        (compiler-backend-binop-divmod-core-asm
          type-segment-bases
          ty
          false
          rhs-reg)]
      [(SafeMod)
        (compiler-backend-binop-divmod-core-asm
          type-segment-bases
          ty
          true
          rhs-reg)]
      [(Eq)
        (compiler-backend-binop-cmp-set-asm
          type-segment-bases
          ty
          rhs
          lhs
          "sete"
          staging-reg)]
      [(Ne)
        (compiler-backend-binop-cmp-set-asm
          type-segment-bases
          ty
          rhs
          lhs
          "setne"
          staging-reg)]
      [(or (Lt) (Le) (Gt) (Ge))
        (compiler-backend-binop-cmp-set-asm
          type-segment-bases
          (be_state.compiler-backend-global-shared-view ty)
          rhs
          lhs
          (compiler-backend-compare-setcc
            type-segment-bases
            op
            (be_state.compiler-backend-global-shared-view ty))
          staging-reg)]
      [(or (BitTestEq) (BitTestNe))
        (compiler-backend-binop-compare-set-reg-asm
          type-segment-bases
          op
          ty
          rhs
          lhs
          staging-reg)]
      [(or (And) (BitAnd))
        (compiler-backend-binop-reg-asm type-segment-bases "and" ty rhs lhs)]
      [(or (Or) (BitOr))
        (compiler-backend-binop-reg-asm type-segment-bases "or" ty rhs lhs)]
      [(BitXor)
        (compiler-backend-binop-reg-asm type-segment-bases "xor" ty rhs lhs)]
      [(Shl count-ty)
        (compiler-backend-binop-shift-asm
          type-segment-bases
          "shl"
          ty
          count-ty
          lhs
          rhs-reg
          backend-state)]
      [(Shr count-ty)
        (compiler-backend-binop-shift-asm
          type-segment-bases
          (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
            "sar"
            "shr")
          ty
          count-ty
          lhs
          rhs-reg
          backend-state)]
      ;; The optimizer forms `rotr` only with an in-range immediate count, so
      ;; a register count needs no guard.
      [(Rotr)
        (str_cat.str-cat
          (if (string.eq rhs-reg "%rcx")
            ""
            (str_cat.str-cat "    movq " rhs-reg ", %rcx\n"))
          "    ror"
          (be_operand.compiler-backend-int-instruction-suffix
            type-segment-bases
            ty)
          " %cl, "
          lhs
          "\n")])))

(define (compiler-backend-binop-test-zero-asm
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]
  [setcc : String]
  [staging-reg : String]
  [result-reg : String]) : String
  (let
    [lhs : String
      (be_operand.compiler-backend-sized-reg
        type-segment-bases
        staging-reg
        (be_state.compiler-backend-global-shared-view ty))]
    (str_cat.str-cat
      (compiler-backend-binop-reg-asm
        type-segment-bases
        "test"
        ty
        (be_state.compiler-backend-global-shared-view lhs)
        lhs)
      (str_cat.str-cat
        "    "
        setcc
        " "
        (be_operand.compiler-backend-reg-part (string.copy result-reg) 1)
        "\n    movzbl "
        (be_operand.compiler-backend-reg-part (string.copy result-reg) 1)
        ", "
        (be_operand.compiler-backend-reg-part (string.copy result-reg) 4)
        "\n"))))

(define (compiler-backend-binop-immediate-cmp-asm
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]
  [imm : String]
  [setcc : String]
  [staging-reg : String]
  [result-reg : String]
  [rhs-zero? : bool]) : String
  (if rhs-zero?
    (compiler-backend-binop-test-zero-asm
      type-segment-bases
      ty
      setcc
      staging-reg
      result-reg)
    (compiler-backend-binop-cmp-set-asm
      type-segment-bases
      (be_state.compiler-backend-global-shared-view ty)
      imm
      (be_operand.compiler-backend-sized-reg type-segment-bases staging-reg ty)
      setcc
      result-reg)))

(define (compiler-backend-binop-immediate-cmp-reg-asm
  [type-segment-bases : i64]
  [ty : compiler_ast_types.AstType]
  [imm : String]
  [setcc : String]
  [dst-reg : String]
  [rhs-zero? : bool]) : String
  (if rhs-zero?
    (compiler-backend-binop-test-zero-reg-asm
      type-segment-bases
      ty
      dst-reg
      setcc)
    (compiler-backend-binop-cmp-set-reg-asm
      type-segment-bases
      (be_state.compiler-backend-global-shared-view ty)
      imm
      (be_operand.compiler-backend-sized-reg
        type-segment-bases
        (be_state.compiler-backend-global-shared-view dst-reg)
        ty)
      setcc
      dst-reg)))

(define (compiler-backend-binop-immediate-shift-asm
  [type-segment-bases : i64]
  [mnemonic : String]
  [lhs-ty : compiler_ast_types.AstType]
  [count-ty : compiler_ast_types.AstType]
  [imm : String]
  [staging-reg : String]) : be_state.CompilerBackendMaybeAsm
  (let
    [count : i64
      (string.>int (string.substring imm 1 (- (string.string-length imm) 1)))]
    (if (compiler-backend-shift-count-valid-typed?
      type-segment-bases
      count
      count-ty
      (be_state.compiler-backend-global-shared-view lhs-ty))
      (Some
        (str_cat.str-cat
          (str_cat.str-cat
            "    "
            mnemonic
            (be_operand.compiler-backend-int-instruction-suffix
              type-segment-bases
              (be_state.compiler-backend-global-shared-view lhs-ty))
            " "
            imm)
          (str_cat.str-cat
            ", "
            (be_operand.compiler-backend-sized-reg
              type-segment-bases
              staging-reg
              lhs-ty)
            "\n")))
      (No))))

(define (compiler-backend-binop-immediate-shift-reg-asm
  [type-segment-bases : i64]
  [mnemonic : String]
  [lhs-ty : compiler_ast_types.AstType]
  [count-ty : compiler_ast_types.AstType]
  [imm : String]
  [dst-reg : String]) : be_state.CompilerBackendMaybeAsm
  (let
    [count : i64
      (string.>int (string.substring imm 1 (- (string.string-length imm) 1)))]
    (if (compiler-backend-shift-count-valid-typed?
      type-segment-bases
      count
      count-ty
      (be_state.compiler-backend-global-shared-view lhs-ty))
      (Some
        (str_cat.str-cat
          (str_cat.str-cat
            "    "
            mnemonic
            (be_operand.compiler-backend-int-instruction-suffix
              type-segment-bases
              (be_state.compiler-backend-global-shared-view lhs-ty))
            " "
            imm)
          (str_cat.str-cat
            ", "
            (be_operand.compiler-backend-sized-reg
              type-segment-bases
              dst-reg
              lhs-ty)
            "\n")))
      (No))))

(define (compiler-backend-binop-immediate-direct-reg-asm
  [type-segment-bases : i64]
  [mnem : String]
  [op : compiler_ir_types.CompilerIrBinOp]
  [ty : compiler_ast_types.AstType]
  [imm : String]
  [dst-reg : String]
  [rhs-zero? : bool]) : be_state.CompilerBackendMaybeAsm
  (match (be_state.compiler-backend-global-shared-view op)
    [(Eq)
      (Some
        (compiler-backend-binop-immediate-cmp-reg-asm
          type-segment-bases
          ty
          imm
          "sete"
          dst-reg
          rhs-zero?))]
    [(Ne)
      (Some
        (compiler-backend-binop-immediate-cmp-reg-asm
          type-segment-bases
          ty
          imm
          "setne"
          dst-reg
          rhs-zero?))]
    [(or (Lt) (Le) (Gt) (Ge))
      (Some
        (compiler-backend-binop-immediate-cmp-reg-asm
          type-segment-bases
          (be_state.compiler-backend-global-shared-view ty)
          imm
          (compiler-backend-compare-setcc type-segment-bases op ty)
          dst-reg
          rhs-zero?))]
    [(or (BitTestEq) (BitTestNe))
      (Some
        (compiler-backend-binop-compare-set-reg-asm
          type-segment-bases
          op
          (be_state.compiler-backend-global-shared-view ty)
          imm
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            (be_state.compiler-backend-global-shared-view dst-reg)
            ty)
          dst-reg))]
    [(Shl count-ty)
      (compiler-backend-binop-immediate-shift-reg-asm
        type-segment-bases
        "shl"
        ty
        count-ty
        imm
        dst-reg)]
    [(Shr count-ty)
      (compiler-backend-binop-immediate-shift-reg-asm
        type-segment-bases
        (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
          "sar"
          "shr")
        ty
        count-ty
        imm
        dst-reg)]
    [(Rotr)
      (compiler-backend-binop-immediate-shift-reg-asm
        type-segment-bases
        "ror"
        ty
        ;; The immediate is in `(0, width)` by construction.
        (I64)
        imm
        dst-reg)]
    [(BitAnd)
      (Some
        (if (string.eq imm "$255")
          (str_cat.str-cat
            "    movzbl "
            (be_operand.compiler-backend-reg-part (string.copy dst-reg) 1)
            ", "
            (be_operand.compiler-backend-reg-part (string.copy dst-reg) 4)
            "\n")
          (if (string.eq imm "$65535")
            (str_cat.str-cat
              "    movzwl "
              (be_operand.compiler-backend-reg-part (string.copy dst-reg) 2)
              ", "
              (be_operand.compiler-backend-reg-part (string.copy dst-reg) 4)
              "\n")
            (compiler-backend-binop-reg-asm
              type-segment-bases
              mnem
              (be_state.compiler-backend-global-shared-view ty)
              imm
              (be_operand.compiler-backend-sized-reg
                type-segment-bases
                dst-reg
                ty)))))]
    [_
      (Some
        (compiler-backend-binop-reg-asm
          type-segment-bases
          mnem
          (be_state.compiler-backend-global-shared-view ty)
          imm
          (be_operand.compiler-backend-sized-reg type-segment-bases dst-reg ty)))]))

(define (compiler-backend-emit-binop-direct-compare
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [dst-home : String]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [rhs-reg : String
      (be_operand.compiler-backend-value-scalar-register
        backend-state
        assignments
        rhs)]
    [rhs-address : String
      (compiler-backend-compare-memory-operand
        type-segment-bases
        assignments
        (be_state.compiler-backend-global-shared-view rhs)
        (be_state.compiler-backend-global-shared-view ty)
        backend-state)]
    [lhs-reg : String
      (be_operand.compiler-backend-value-scalar-register
        backend-state
        assignments
        lhs)]
    [rhs-load-needed : bool
      (if (not (string.eq rhs-reg ""))
        (string.eq rhs-reg dst-home)
        (string.eq rhs-address ""))]
    [scav-rhs : String
      (if rhs-load-needed
        (be_operand.compiler-backend-scavenge-reg
          dst
          (compiler-backend-scavenge-exclude-regs2
            (be_state.compiler-backend-global-shared-view dst-home)
            lhs-reg)
          7
          "%r8"
          backend-state)
        "")]
    [rhs-operand : String
      (if (not (string.eq rhs-reg ""))
        (if (string.eq rhs-reg dst-home)
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            (be_state.compiler-backend-global-shared-view scav-rhs)
            (be_state.compiler-backend-global-shared-view ty))
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            rhs-reg
            (be_state.compiler-backend-global-shared-view ty)))
        (if (string.eq rhs-address "")
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            (be_state.compiler-backend-global-shared-view scav-rhs)
            (be_state.compiler-backend-global-shared-view ty))
          rhs-address))]
    [rhs-asm
      (try
        (if rhs-load-needed
          (be_operand.compiler-backend-emit-load-value
            assignments
            rhs
            scav-rhs
            backend-state)
          (be_state.ResultCompilerBackend.Ok "")))]
    [lhs-asm
      (try
        (be_operand.compiler-backend-emit-load-value
          assignments
          lhs
          (be_state.compiler-backend-global-shared-view dst-home)
          backend-state))]
    (Ok
      (str_cat.str-cat
        rhs-asm
        (str_cat.str-cat
          lhs-asm
          (compiler-backend-binop-compare-set-reg-asm
            type-segment-bases
            op
            (be_state.compiler-backend-global-shared-view ty)
            rhs-operand
            (be_operand.compiler-backend-sized-reg
              type-segment-bases
              (be_state.compiler-backend-global-shared-view dst-home)
              ty)
            dst-home))))))

(define (compiler-backend-emit-binop-direct-rcx-shift
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst-home : String]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [count-ty : compiler_ast_types.AstType
      (compiler_ir_types.compiler-ir-binop-rhs-type
        (be_state.compiler-backend-global-shared-view op)
        (be_state.compiler-backend-global-shared-view ty))]
    [mnemonic : String
      (match op
        [(Shl _) "shl"]
        [(Shr _)
          (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
            "sar"
            "shr")]
        [(Rotr) "ror"]
        [_ ""])]
    [lhs-asm
      (try
        (be_operand.compiler-backend-emit-load-value
          assignments
          lhs
          (be_state.compiler-backend-global-shared-view dst-home)
          backend-state))]
    (Ok
      (str_cat.str-cat
        lhs-asm
        (compiler-backend-shift-guard-asm
          type-segment-bases
          (be_state.compiler-backend-global-shared-view ty)
          count-ty
          "%rcx"
          backend-state)
        "    "
        mnemonic
        (be_operand.compiler-backend-int-instruction-suffix
          type-segment-bases
          (be_state.compiler-backend-global-shared-view ty))
        " %cl, "
        (be_operand.compiler-backend-sized-reg type-segment-bases dst-home ty)
        "\n"))))

(define (compiler-backend-binop-shift-mnemonic
  [type-segment-bases : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [ty : (& ty compiler_ast_types.AstType)]) : String
  (match op
    [(Shl _) "shl"]
    [(Shr _)
      (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
        "sar"
        "shr")]
    [(Rotr) "ror"]
    [_ ""]))

(define (compiler-backend-emit-binop-spill-direct-shift
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [operand-ty : compiler_ast_types.AstType]
  [result-ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [count-ty : compiler_ast_types.AstType
      (compiler_ir_types.compiler-ir-binop-rhs-type
        (be_state.compiler-backend-global-shared-view op)
        (be_state.compiler-backend-global-shared-view operand-ty))]
    [lhs-home : String
      (be_operand.compiler-backend-value-scalar-register
        backend-state
        assignments
        lhs)]
    [rhs-home : String
      (be_operand.compiler-backend-value-scalar-register
        backend-state
        assignments
        rhs)]
    [rhs-in-rcx? : bool (string.eq rhs-home "%rcx")]
    [count-reg : String
      (if rhs-in-rcx?
        "%rcx"
        (be_operand.compiler-backend-scavenge-reg
          dst
          (be_operand.compiler-backend-two-exclude "%rcx" lhs-home)
          2
          "%r8"
          backend-state))]
    [result-reg : String
      (be_operand.compiler-backend-scavenge-reg
        dst
        (be_operand.compiler-backend-two-exclude
          "%rcx"
          (be_state.compiler-backend-global-shared-view count-reg))
        2
        "%r8"
        backend-state)]
    [rhs-asm
      (try
        (if rhs-in-rcx?
          (be_state.ResultCompilerBackend.Ok "")
          (be_operand.compiler-backend-emit-load-value
            assignments
            rhs
            (be_state.compiler-backend-global-shared-view count-reg)
            backend-state)))]
    [lhs-asm
      (try
        (be_operand.compiler-backend-emit-load-value
          assignments
          lhs
          (be_state.compiler-backend-global-shared-view result-reg)
          backend-state))]
    (Ok
      (str_cat.str-cat
        rhs-asm
        (str_cat.str-cat
          lhs-asm
          (str_cat.str-cat
            (compiler-backend-binop-shift-asm
              type-segment-bases
              (compiler-backend-binop-shift-mnemonic
                type-segment-bases
                op
                operand-ty)
              (be_state.compiler-backend-global-shared-view operand-ty)
              count-ty
              (be_operand.compiler-backend-sized-reg
                type-segment-bases
                (be_state.compiler-backend-global-shared-view result-reg)
                operand-ty)
              count-reg
              backend-state)
            (be_operand.compiler-backend-emit-store-typed-var
              assignments
              dst
              result-reg
              result-ty
              backend-state)))))))

(define (compiler-backend-binop-immediate-reg-asm
  [type-segment-bases : i64]
  [mnemonic : String]
  [ty : compiler_ast_types.AstType]
  [imm : String]
  [staging-reg : String]) : String
  (compiler-backend-binop-reg-asm
    type-segment-bases
    mnemonic
    (be_state.compiler-backend-global-shared-view ty)
    imm
    (be_operand.compiler-backend-sized-reg type-segment-bases staging-reg ty)))

(define (compiler-backend-binop-immediate-asm
  [type-segment-bases : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [imm : String]
  [ty : compiler_ast_types.AstType]
  [staging-reg : String]
  [result-reg : String]
  [rhs-zero? : bool]) : be_state.CompilerBackendMaybeAsm
  (match op
    [(Add)
      (Some
        (compiler-backend-binop-immediate-reg-asm
          type-segment-bases
          "add"
          ty
          imm
          staging-reg))]
    [(Sub)
      (Some
        (compiler-backend-binop-immediate-reg-asm
          type-segment-bases
          "sub"
          ty
          imm
          staging-reg))]
    [(Mul)
      (Some
        (if (= (be_operand.compiler-backend-type-size type-segment-bases ty) 1)
          (str_cat.str-cat "    imulq " imm ", " staging-reg "\n")
          (compiler-backend-binop-immediate-reg-asm
            type-segment-bases
            "imul"
            ty
            imm
            staging-reg)))]
    [(Eq)
      (Some
        (compiler-backend-binop-immediate-cmp-asm
          type-segment-bases
          ty
          imm
          "sete"
          staging-reg
          result-reg
          rhs-zero?))]
    [(Ne)
      (Some
        (compiler-backend-binop-immediate-cmp-asm
          type-segment-bases
          ty
          imm
          "setne"
          "%rax"
          "%rax"
          rhs-zero?))]
    [(or (Lt) (Le) (Gt) (Ge))
      (Some
        (compiler-backend-binop-immediate-cmp-asm
          type-segment-bases
          (be_state.compiler-backend-global-shared-view ty)
          imm
          (compiler-backend-compare-setcc
            type-segment-bases
            op
            (be_state.compiler-backend-global-shared-view ty))
          staging-reg
          result-reg
          rhs-zero?))]
    [(And)
      (Some
        (compiler-backend-binop-immediate-reg-asm
          type-segment-bases
          "and"
          ty
          imm
          staging-reg))]
    [(or (Or) (BitOr))
      (Some
        (compiler-backend-binop-immediate-reg-asm
          type-segment-bases
          "or"
          ty
          imm
          staging-reg))]
    [(BitAnd)
      (let
        [size : i64
          (be_operand.compiler-backend-type-size type-segment-bases ty)]
        (Some
          (if (string.eq imm "$255")
            (str_cat.str-cat
              "    movzbl "
              (be_operand.compiler-backend-reg-part staging-reg 1)
              ", "
              (be_operand.compiler-backend-reg-part result-reg 4)
              "\n")
            (if (and (>= size 2) (string.eq imm "$65535"))
              (str_cat.str-cat
                "    movzwl "
                (be_operand.compiler-backend-reg-part staging-reg 2)
                ", "
                (be_operand.compiler-backend-reg-part result-reg 4)
                "\n")
              (compiler-backend-binop-immediate-reg-asm
                type-segment-bases
                "and"
                ty
                imm
                staging-reg)))))]
    [(BitXor)
      (Some
        (compiler-backend-binop-immediate-reg-asm
          type-segment-bases
          "xor"
          ty
          imm
          staging-reg))]
    [(Shl count-ty)
      (compiler-backend-binop-immediate-shift-asm
        type-segment-bases
        "shl"
        ty
        count-ty
        imm
        staging-reg)]
    [(Shr count-ty)
      (compiler-backend-binop-immediate-shift-asm
        type-segment-bases
        (if (be_facts.compiler-backend-type-signed? type-segment-bases ty)
          "sar"
          "shr")
        ty
        count-ty
        imm
        staging-reg)]
    [(Rotr)
      (compiler-backend-binop-immediate-shift-asm
        type-segment-bases
        "ror"
        ty
        ;; The immediate is in `(0, width)` by construction.
        (I64)
        imm
        staging-reg)]
    [_ (No)]))

(define (compiler-backend-unop-reg-asm
  [op : compiler_ir_types.CompilerIrUnOp]
  [reg : String]) : String
  (match op
    [(Neg) (str_cat.str-cat "    negq " reg "\n")]
    [(Not) (str_cat.str-cat "    xorq $1, " reg "\n")]
    [(BitNot) (str_cat.str-cat "    notq " reg "\n")]
    ;; Sqrt is admitted only for f32/f64 and takes the float path below.
    ;; BitLength needs the operand's signedness; see
    ;; compiler-backend-unop-typed-reg-asm.
    [(or (Sqrt) (BitLength)) ""]))

;; BITLEN: the significant-bit count of a 64-bit register, in place and without
;; a scratch register. A value with no significant bits (<= 0 signed, 0
;; unsigned) yields 0; otherwise `bsr` gives the index of the highest set bit.
(define (compiler-backend-bit-length-reg-asm [signed? : bool] [reg : String]) : String
  (str_cat.str-cat
    "    testq "
    reg
    ", "
    reg
    (if signed?
      "\n    jle 1f\n    bsrq "
      "\n    je 1f\n    bsrq ")
    reg
    ", "
    reg
    "\n    addq $1, "
    reg
    "\n    jmp 2f\n1:\n    xorq "
    reg
    ", "
    reg
    "\n2:\n"))

;; Integer unary ops whose lowering depends on the operand type.
(define (compiler-backend-unop-typed-reg-asm
  [type-segment-bases : i64]
  [op : compiler_ir_types.CompilerIrUnOp]
  [ty : compiler_ast_types.AstType]
  [reg : String]) : String
  (match op
    [(BitLength)
      (compiler-backend-bit-length-reg-asm
        (be_facts.compiler-backend-type-signed? type-segment-bases ty)
        reg)]
    [_ (compiler-backend-unop-reg-asm op reg)]))

(define (compiler-backend-float-suffix [fty : compiler_ast_types.AstType]) : String
  (if (be_state.compiler-backend-f64-type? fty)
    "sd"
    "ss"))

(define (compiler-backend-float-arith-op?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]) : bool
  (match op
    [(or (Add) (Sub) (Mul) (Div) (SafeDiv)) true]
    [_ false]))

(define (compiler-backend-float-arith-mnemonic
  [op : compiler_ir_types.CompilerIrBinOp]) : String
  (match op
    [(Add) "add"]
    [(Sub) "sub"]
    [(Mul) "mul"]
    [(or (Div) (SafeDiv)) "div"]
    [_ ""]))

(define (compiler-backend-float-compare-setcc
  [op : compiler_ir_types.CompilerIrBinOp]) : String
  (match op
    [(Eq) "sete"]
    [(Ne) "setne"]
    [(Lt) "setb"]
    [(Le) "setbe"]
    [(Gt) "seta"]
    [(Ge) "setae"]
    [_ "sete"]))

(define (compiler-backend-float-compare-flags
  [fty : compiler_ast_types.AstType]
  [lhs-reg : String]
  [rhs-operand : String]) : String
  (str_cat.str-cat
    "    ucomi"
    (compiler-backend-float-suffix fty)
    " "
    rhs-operand
    ", "
    lhs-reg
    "\n"))

(define (compiler-backend-float-compare-reg-asm
  [op : compiler_ir_types.CompilerIrBinOp]
  [fty : compiler_ast_types.AstType]
  [lhs-reg : String]
  [rhs-operand : String]
  [dst-home : String]) : String
  (str_cat.str-cat
    (compiler-backend-float-compare-flags fty lhs-reg rhs-operand)
    ;; UCOMIS sets ZF/PF/CF for unordered operands. Above/above-equal
    ;; already reject that case; the other predicates must inspect PF.
    ;; MOV preserves those flags and its 32-bit destination clears the
    ;; upper half. Only the result register is written: no hidden
    ;; byte scratch, operand reload, or second operand evaluation is needed.
    (if (match (& op)
      [(or (Gt) (Ge)) true]
      [_ false])
      (str_cat.str-cat
        "    "
        (compiler-backend-float-compare-setcc op)
        " "
        (be_operand.compiler-backend-reg-part (string.copy dst-home) 1)
        "\n    movzbl "
        (be_operand.compiler-backend-reg-part (string.copy dst-home) 1)
        ", "
        (be_operand.compiler-backend-reg-part (string.copy dst-home) 4)
        "\n")
      (str_cat.str-cat
        (compiler-backend-machine-line
          (mx.MachineInstr.MovRI
            (W32)
            (be_operand.compiler-backend-machine-register
              (string.copy dst-home))
            (match (& op)
              [(Ne) 1]
              [_ 0])))
        "    jp 1f\n    "
        (compiler-backend-float-compare-setcc op)
        " "
        (be_operand.compiler-backend-reg-part dst-home 1)
        "\n1:\n"))))

;; A scalar home owns the whole register. Copy all lanes to avoid
;; MOVSS/MOVSD's dependency on the destination's previous upper lanes.
(define (compiler-backend-emit-float-register-copy
  [src : String]
  [dst : String]
  [ty : (& ty compiler_ast_types.AstType)]) : String
  (if (string.eq src dst)
    ""
    (str_cat.str-cat
      (if (be_state.compiler-backend-f64-type? ty)
        "    movapd "
        "    movaps ")
      src
      ", "
      dst
      "\n")))

(define (compiler-backend-emit-float-binop-direct
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst-home : String]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs-operand : String]
  [fty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [lhs-home : String
      (compiler-backend-float-value-register backend-state assignments lhs)]
    [lhs-asm
      (if (string.eq lhs-home "")
        (try
          (be_operand.compiler-backend-emit-load-float-value
            assignments
            lhs
            fty
            (be_state.compiler-backend-global-shared-view dst-home)
            backend-state))
        (compiler-backend-emit-float-register-copy
          lhs-home
          (be_state.compiler-backend-global-shared-view dst-home)
          fty))]
    (Ok
      (str_cat.str-cat
        lhs-asm
        "    "
        (compiler-backend-float-arith-mnemonic op)
        (compiler-backend-float-suffix fty)
        " "
        rhs-operand
        ", "
        dst-home
        "\n"))))

(define (compiler-backend-emit-float-binop-spill-direct
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [fty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [rhs-reg : String
      (compiler-backend-float-value-register backend-state assignments rhs)]
    [exclude : (__tl_dyn-array String)
      (if (string.eq rhs-reg "")
        (__tl_make-array String 0)
        (be_operand.compiler-backend-one-exclude
          (be_state.compiler-backend-global-shared-view rhs-reg)))]
    [exclude-n : i64
      (if (string.eq rhs-reg "")
        0
        1)]
    [result-reg : String
      (be_operand.compiler-backend-scavenge-xmm-reg-for-staging
        dst
        exclude
        exclude-n
        "%xmm2"
        true
        backend-state)]
    [rhs-operand : String
      (compiler-backend-float-direct-rhs-operand
        assignments
        rhs
        fty
        result-reg
        backend-state)]
    (if (string.eq rhs-operand "")
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            "backend: cannot direct spilled float binop")))
      (let
        [asm
          (try
            (compiler-backend-emit-float-binop-direct
              assignments
              (be_state.compiler-backend-global-shared-view result-reg)
              op
              lhs
              rhs-operand
              (be_state.compiler-backend-global-shared-view fty)
              backend-state))]
        (Ok
          (str_cat.str-cat
            asm
            (be_operand.compiler-backend-emit-store-float-var
              assignments
              dst
              result-reg
              fty
              backend-state)))))))

(define (compiler-backend-emit-float-compare-direct
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst-home : String]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [fty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [lhs-reg : String
      (compiler-backend-float-value-register backend-state assignments lhs)]
    [rhs-operand : String
      (compiler-backend-float-direct-rhs-operand
        assignments
        rhs
        fty
        dst-home
        backend-state)]
    (if (or (string.eq lhs-reg "") (string.eq rhs-operand ""))
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            "backend: cannot direct float compare")))
      (Ok
        (compiler-backend-float-compare-reg-asm
          op
          fty
          lhs-reg
          rhs-operand
          dst-home)))))

(define (compiler-backend-emit-float-compare-spill-direct
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [fty : compiler_ast_types.AstType]
  [result-ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [result-reg : String
      (be_operand.compiler-backend-scavenge-reg
        dst
        (compiler-backend-binop-scavenge-exclude-build)
        5
        "%r8"
        backend-state)]
    [asm
      (try
        (compiler-backend-emit-float-compare-direct
          assignments
          (be_state.compiler-backend-global-shared-view result-reg)
          op
          lhs
          rhs
          fty
          backend-state))]
    (Ok
      (str_cat.str-cat
        asm
        (be_operand.compiler-backend-emit-store-typed-var
          assignments
          dst
          result-reg
          result-ty
          backend-state)))))

(define (compiler-backend-emit-staged-float-result
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [reg : String]
  [ty : (& ty compiler_ast_types.AstType)]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [home : String
      (compiler-backend-float-value-register
        backend-state
        assignments
        (& (compiler_ir_types.CompilerIrValue.Var dst)))]
    (if (string.eq home "")
      (be_operand.compiler-backend-emit-store-float-var
        assignments
        dst
        reg
        ty
        backend-state)
      (compiler-backend-emit-float-register-copy reg home ty))))

(define (compiler-backend-emit-float-binop-fallback
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [fty : compiler_ast_types.AstType]
  [result-ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (be_facts.compiler-backend-compare-op? op)
    (let
      [rhs-reg : String
        (compiler-backend-float-value-register backend-state assignments rhs)]
      [xmm-exclude : (__tl_dyn-array String)
        (if (string.eq rhs-reg "")
          (__tl_make-array String 0)
          (be_operand.compiler-backend-one-exclude
            (be_state.compiler-backend-global-shared-view rhs-reg)))]
      [xmm-exclude-n : i64
        (if (string.eq rhs-reg "")
          0
          1)]
      [lhs-reg : String
        (be_operand.compiler-backend-scavenge-xmm-reg-for-staging
          dst
          xmm-exclude
          xmm-exclude-n
          "%xmm2"
          true
          backend-state)]
      [rhs-operand : String
        (compiler-backend-float-direct-rhs-operand
          assignments
          (be_state.compiler-backend-global-shared-view rhs)
          fty
          lhs-reg
          backend-state)]
      [dst-home : String
        (compiler-backend-var-register-home backend-state assignments dst)]
      [result-reg : String
        (if (string.eq dst-home "")
          (be_operand.compiler-backend-scavenge-reg
            dst
            (compiler-backend-binop-scavenge-exclude-build)
            5
            "%r8"
            backend-state)
          (owned_view.compiler-owned-shared-view dst-home))]
      [store-result : String
        (if (string.eq dst-home "")
          (be_operand.compiler-backend-emit-store-typed-var
            assignments
            dst
            (be_state.compiler-backend-global-shared-view result-reg)
            result-ty
            backend-state)
          "")]
      (if (string.eq rhs-operand "")
        (let
          [rhs-temp-exclude : (__tl_dyn-array String)
            (be_operand.compiler-backend-one-exclude
              (be_state.compiler-backend-global-shared-view lhs-reg))]
          [rhs-temp : String
            (be_operand.compiler-backend-scavenge-xmm-reg-for-staging
              dst
              rhs-temp-exclude
              1
              "%xmm3"
              true
              backend-state)]
          [rhs-asm
            (try
              (be_operand.compiler-backend-emit-load-float-value
                assignments
                rhs
                fty
                (be_state.compiler-backend-global-shared-view rhs-temp)
                backend-state))]
          [lhs-asm
            (try
              (be_operand.compiler-backend-emit-load-float-value
                assignments
                lhs
                fty
                (be_state.compiler-backend-global-shared-view lhs-reg)
                backend-state))]
          (Ok
            (str_cat.str-cat
              rhs-asm
              lhs-asm
              (compiler-backend-float-compare-reg-asm
                op
                fty
                lhs-reg
                rhs-temp
                result-reg)
              store-result)))
        (let
          [lhs-asm
            (try
              (be_operand.compiler-backend-emit-load-float-value
                assignments
                lhs
                fty
                (be_state.compiler-backend-global-shared-view lhs-reg)
                backend-state))]
          (Ok
            (str_cat.str-cat
              lhs-asm
              (compiler-backend-float-compare-reg-asm
                op
                fty
                lhs-reg
                rhs-operand
                result-reg)
              store-result)))))
    (if (compiler-backend-float-arith-op? op)
      (let
        [rhs-reg : String
          (compiler-backend-float-value-register backend-state assignments rhs)]
        [exclude : (__tl_dyn-array String)
          (if (string.eq rhs-reg "")
            (__tl_make-array String 0)
            (be_operand.compiler-backend-one-exclude
              (be_state.compiler-backend-global-shared-view rhs-reg)))]
        [exclude-n : i64
          (if (string.eq rhs-reg "")
            0
            1)]
        [result-reg : String
          (be_operand.compiler-backend-scavenge-xmm-reg-for-staging
            dst
            exclude
            exclude-n
            "%xmm2"
            true
            backend-state)]
        [rhs-operand : String
          (compiler-backend-float-direct-rhs-operand
            assignments
            (be_state.compiler-backend-global-shared-view rhs)
            fty
            result-reg
            backend-state)]
        (if (string.eq rhs-operand "")
          (let
            [rhs-temp-exclude : (__tl_dyn-array String)
              (be_operand.compiler-backend-one-exclude
                (be_state.compiler-backend-global-shared-view result-reg))]
            [rhs-temp : String
              (be_operand.compiler-backend-scavenge-xmm-reg-for-staging
                dst
                rhs-temp-exclude
                1
                "%xmm3"
                true
                backend-state)]
            [rhs-asm
              (try
                (be_operand.compiler-backend-emit-load-float-value
                  assignments
                  rhs
                  fty
                  (be_state.compiler-backend-global-shared-view rhs-temp)
                  backend-state))]
            [asm
              (try
                (compiler-backend-emit-float-binop-direct
                  assignments
                  (be_state.compiler-backend-global-shared-view result-reg)
                  op
                  lhs
                  rhs-temp
                  fty
                  backend-state))]
            (Ok
              (str_cat.str-cat
                rhs-asm
                asm
                (compiler-backend-emit-staged-float-result
                  assignments
                  dst
                  result-reg
                  result-ty
                  backend-state))))
          (let
            [asm
              (try
                (compiler-backend-emit-float-binop-direct
                  assignments
                  (be_state.compiler-backend-global-shared-view result-reg)
                  op
                  lhs
                  rhs-operand
                  fty
                  backend-state))]
            (Ok
              (str_cat.str-cat
                asm
                (compiler-backend-emit-staged-float-result
                  assignments
                  dst
                  result-reg
                  result-ty
                  backend-state))))))
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            "backend: unsupported float binary op"))))))

(define (compiler-backend-float-unop-reg-asm
  [op : compiler_ir_types.CompilerIrUnOp]
  [ty : compiler_ast_types.AstType]
  [reg : (& reg str)]) : be_state.ResultCompilerBackend
  (match op
    [(Neg)
      (Ok
        (str_cat.str-cat
          "    xorpd "
          (if (be_state.compiler-backend-f64-type? ty)
            (be_facts.compiler-backend-f64-sign-bit-label)
            (be_facts.compiler-backend-f32-sign-bit-label))
          "(%rip), "
          reg
          "\n"))]
    [(Sqrt)
      (Ok
        (str_cat.str-cat
          "    sqrt"
          (compiler-backend-float-suffix ty)
          " "
          reg
          ", "
          reg
          "\n"))]
    [_
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            (if (be_state.compiler-backend-f64-type? ty)
              "backend: unsupported f64 unary op"
              "backend: unsupported float unary op"))))]))

(define (compiler-backend-direct-float-unop?
  [op : compiler_ir_types.CompilerIrUnOp]
  [ty : (& ty compiler_ast_types.AstType)]) : bool
  (or
    (be_state.compiler-backend-f64-type? ty)
    (and
      (be_operand.compiler-backend-float-type? ty)
      (match op
        [(or (Neg) (Sqrt)) true]
        [_ false]))))

;; 64-bit accumulate-in-place mnemonic for the arithmetic/bitwise binops whose
;; result can be computed directly in the destination register (dst = lhs <op>
;; rhs via "<op>q src, dst"). Comparisons, div/mod and variable shifts are
;; excluded (they need %rax/%rdx/%rcx or setcc) and return "".
(define (compiler-backend-binop-direct-mnemonic
  [op : (& op compiler_ir_types.CompilerIrBinOp)]) : String
  (match op
    [(Add) "add"]
    [(Sub) "sub"]
    [(Mul) "imul"]
    [(or (And) (BitAnd)) "and"]
    [(or (Or) (BitOr)) "or"]
    [(BitXor) "xor"]
    [_ ""]))

(define (compiler-backend-binop-direct-width-ok?
  [type-segment-bases : i64]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [ty : compiler_ast_types.AstType]) : bool
  (not
    (and
      (= (be_operand.compiler-backend-type-size type-segment-bases ty) 1)
      (match op
        [(Mul) true]
        [_ false]))))

(define (compiler-backend-binop-shift-op?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]) : bool
  (match op
    [(or (Shl _) (Shr _) (Rotr)) true]
    [_ false]))

(define (compiler-backend-binop-valid-immediate-shift?
  [type-segment-bases : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : bool
  (if (compiler-backend-binop-shift-op? op)
    (match (be_operand.compiler-backend-immediate-operand backend-state rhs)
      [(Some imm)
        (compiler-backend-shift-count-valid-typed?
          type-segment-bases
          (string.>int
            (string.substring imm 1 (- (string.string-length imm) 1)))
          (compiler_ir_types.compiler-ir-binop-rhs-type
            op
            (be_state.compiler-backend-global-shared-view ty))
          ty)]
      [(No) false])
    false))

(define (compiler-backend-binop-rcx-shift?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [rhs : compiler_ir_types.CompilerIrValue]
  [dst-home : (& dst-home str)]) : bool
  (and
    (compiler-backend-binop-shift-op? op)
    (not (string.eq dst-home "%rcx"))
    (string.eq
      (be_operand.compiler-backend-value-scalar-register
        backend-state
        assignments
        rhs)
      "%rcx")))

;; A scalar x86 source operand may be either a local stack home or a global
;; RIP-relative memory location. Keep the global case separate from the stack
;; helper so callers that specifically require a frame slot do not broaden
;; their accepted shapes accidentally.
(define (compiler-backend-value-scalar-memory-operand
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [backend-state : be_state.CompilerBackendState]) : String
  (match (& value)
    [(Var id)
      (match (be_operand.compiler-backend-emit-assignment-lookup
        backend-state
        assignments
        id)
        [(Some location)
          (match location
            [(Remat remat)
              (match remat
                ;; IAG-1: an inline aggregate global's cell no longer holds the
                ;; value a read produces, so `sym(%rip)` is not that read's
                ;; memory operand.
                [(Global name)
                  (if (be_state.compiler-backend-inline-aggregate-global?
                    backend-state
                    name)
                    ""
                    (str_cat.str-cat
                      (be_operand.compiler-backend-state-global-symbol-id
                        backend-state
                        name)
                      "(%rip)"))]
                [_ ""])]
            [_
              (be_operand.compiler-backend-value-stack-address
                assignments
                value
                backend-state)])]
        [(No)
          (be_operand.compiler-backend-value-stack-address
            assignments
            value
            backend-state)])]
    [(Global name)
      (if (be_state.compiler-backend-inline-aggregate-global?
        backend-state
        name)
        ""
        (str_cat.str-cat
          (be_operand.compiler-backend-state-global-symbol-id
            backend-state
            name)
          "(%rip)"))]
    [_
      (be_operand.compiler-backend-value-stack-address
        assignments
        value
        backend-state)]))

;; M6-I: the rip-relative memory operand of a scalar GLOBAL read.
;;
;; A global read is `movq g(%rip), %r` on both targets, and x86 lets a compare
;; read that cell through its own memory operand instead -- `cmpq g(%rip), %r`
;; is the whole of `movq g(%rip), %r8 ; cmpq %r8, %r`. The cell is read at the
;; same point in the program either way, because the materialising `movq` the
;; fold removes was emitted immediately in front of the compare it fed and
;; nothing between them writes memory.
;;
;; "" declines. Only a full-word integer global takes the operand: a narrow
;; global read carries the load's own extension into the register (the M6-C
;; width table's business, and not proved here), and a float compare moves
;; through the SSE path, which spells its operands differently.
(define (compiler-backend-value-global-memory-operand
  [backend-state : be_state.CompilerBackendState]
  [type-segment-bases : i64]
  [value : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]) : String
  (match value
    [(Global name)
      (if (or
        (be_operand.compiler-backend-float-type? ty)
        (not
          (= (be_operand.compiler-backend-type-size type-segment-bases ty) 8))
        ;; IAG-1: the cell of an inline aggregate global holds the aggregate,
        ;; not a word-sized value a compare may read.
        (be_state.compiler-backend-inline-aggregate-global? backend-state name))
        ""
        (let
          [symbol : String
            (be_operand.compiler-backend-state-global-symbol-id
              backend-state
              name)]
          (if (string.eq symbol "")
            ""
            (str_cat.str-cat symbol "(%rip)"))))]
    [_ ""]))

(define (compiler-backend-compare-memory-operand
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [stack : String
      (be_operand.compiler-backend-value-read-memory-operand
        assignments
        (be_state.compiler-backend-global-shared-view value)
        backend-state)]
    (if (string.eq stack "")
      (compiler-backend-value-global-memory-operand
        backend-state
        type-segment-bases
        value
        ty)
      stack)))

(define (compiler-backend-immediate-displacement [imm : (& imm str)]) : String
  (string.substring imm 1 (- (string.string-length imm) 1)))

(define (compiler-backend-binop-source-asm
  [type-segment-bases : i64]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [ty : compiler_ast_types.AstType]
  [rhs : String]
  [staging-reg : String]) : be_state.CompilerBackendMaybeAsm
  (match op
    [(Add)
      (Some
        (compiler-backend-binop-reg-asm
          type-segment-bases
          "add"
          (be_state.compiler-backend-global-shared-view ty)
          rhs
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            staging-reg
            ty)))]
    [(Sub)
      (Some
        (compiler-backend-binop-reg-asm
          type-segment-bases
          "sub"
          (be_state.compiler-backend-global-shared-view ty)
          rhs
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            staging-reg
            ty)))]
    [(Mul)
      (if (= (be_operand.compiler-backend-type-size type-segment-bases ty) 1)
        (No)
        (Some
          (compiler-backend-binop-reg-asm
            type-segment-bases
            "imul"
            (be_state.compiler-backend-global-shared-view ty)
            rhs
            (be_operand.compiler-backend-sized-reg
              type-segment-bases
              staging-reg
              ty))))]
    [(Eq)
      (Some
        (compiler-backend-binop-cmp-set-asm
          type-segment-bases
          (be_state.compiler-backend-global-shared-view ty)
          rhs
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            (be_state.compiler-backend-global-shared-view staging-reg)
            ty)
          "sete"
          staging-reg))]
    [(Ne)
      (Some
        (compiler-backend-binop-cmp-set-asm
          type-segment-bases
          (be_state.compiler-backend-global-shared-view ty)
          rhs
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            (be_state.compiler-backend-global-shared-view staging-reg)
            ty)
          "setne"
          staging-reg))]
    [(or (Lt) (Le) (Gt) (Ge))
      (Some
        (compiler-backend-binop-cmp-set-asm
          type-segment-bases
          (be_state.compiler-backend-global-shared-view ty)
          rhs
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            (be_state.compiler-backend-global-shared-view staging-reg)
            (be_state.compiler-backend-global-shared-view ty))
          (compiler-backend-compare-setcc
            type-segment-bases
            op
            (be_state.compiler-backend-global-shared-view ty))
          staging-reg))]
    [(or (BitTestEq) (BitTestNe))
      (Some
        (compiler-backend-binop-compare-set-reg-asm
          type-segment-bases
          op
          (be_state.compiler-backend-global-shared-view ty)
          rhs
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            (be_state.compiler-backend-global-shared-view staging-reg)
            ty)
          staging-reg))]
    [(or (And) (BitAnd))
      (Some
        (compiler-backend-binop-reg-asm
          type-segment-bases
          "and"
          (be_state.compiler-backend-global-shared-view ty)
          rhs
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            staging-reg
            ty)))]
    [(or (Or) (BitOr))
      (Some
        (compiler-backend-binop-reg-asm
          type-segment-bases
          "or"
          (be_state.compiler-backend-global-shared-view ty)
          rhs
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            staging-reg
            ty)))]
    [(BitXor)
      (Some
        (compiler-backend-binop-reg-asm
          type-segment-bases
          "xor"
          (be_state.compiler-backend-global-shared-view ty)
          rhs
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            staging-reg
            ty)))]
    [_ (No)]))

;; Find a live-free scratch register at the current emit point without ever
;; booking an emergency save/restore. Returns "" when occupancy tracking is
;; absent or every candidate is live/excluded.
(define (compiler-backend-free-scratch-reg-here
  [backend-state : be_state.CompilerBackendState]
  [exclude1 : (& exclude1 str)]
  [exclude2 : (& exclude2 str)]) : String
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [point : i64
      (be_state.compiler-backend-function-state-emission-point function-state)]
    [occupied-masks : (__tl_dyn-array i64)
      (be_state.compiler-backend-function-scratch-i64-array
        function-state
        be_state.compiler-backend-scratch-i64-array-scavenge-occupied-masks)]
    (if (or (< point 0) (= (array-length occupied-masks) 0))
      ""
      (let
        [occupied-mask : i64
          (be_operand.compiler-backend-scavenge-occupied-mask-over-range
            function-state
            point
            (+ point 2))]
        [exclude-mask : i64
          (bit-or
            (be_operand.compiler-backend-scavenge-reg-bit exclude1)
            (be_operand.compiler-backend-scavenge-reg-bit exclude2))]
        [plan-mask : i64
          (be_state.compiler-backend-function-scratch-i64
            function-state
            be_state.compiler-backend-scratch-i64-scavenge-plan-reg-mask)]
        [idx : i64
          (be_operand.compiler-backend-scavenge-first-ok-index
            function-state
            occupied-mask
            exclude-mask
            plan-mask
            (& be_operand.compiler-backend-scavenge-candidate-pool)
            (array-length be_operand.compiler-backend-scavenge-candidate-pool))]
        (if (< idx 0)
          ""
          (compiler_abi.compiler-abi-register-spelling
            (array-ref be_operand.compiler-backend-scavenge-candidate-pool idx)))))))

;; When `n = 2^k - 1` with `k >= 3` (e.g. 7, 15, 31, 63, ...), return `(Some k)`
;; so constant multiplication can lower to `shlq $k; subq` (2c latency vs 3c
;; `imulq`). Factors 1 and 3 are handled earlier (identity / 1-cycle `leaq`).
(define (compiler-backend-mul-pow2-minus1-shift [n : i64]) : option_i64.Option
  (if (or (< n 7) (> n 2147483647))
    (None)
    (compiler-backend-power-of-two-shift (+ n 1))))

;; Split a slow 3-component `leaq disp(dep, inv), dep` (3c latency on `dep`)
;; into `leaq disp(inv), tmp; addq tmp, dep` (1c on `dep`, with `leaq disp(inv)`
;; executing off the critical path). Returns `(No)` if no free scratch exists.
(define (compiler-backend-split-3op-lea-asm
  [backend-state : be_state.CompilerBackendState]
  [disp : i64]
  [inv-reg : (& inv-reg str)]
  [dep-reg : (& dep-reg str)]
  [preferred-tmp : (& preferred-tmp str)]) : be_state.CompilerBackendMaybeAsm
  (let
    [tmp : String
      (if (and
        (not (string.eq preferred-tmp ""))
        (not (string.eq preferred-tmp inv-reg))
        (not (string.eq preferred-tmp dep-reg)))
        (string.copy preferred-tmp)
        (compiler-backend-free-scratch-reg-here backend-state inv-reg dep-reg))]
    (if (string.eq tmp "")
      (No)
      (Some
        (str_cat.str-cat
          "    leaq "
          (string.int->string disp)
          "("
          inv-reg
          "), "
          (string.copy (& tmp))
          "\n    addq "
          tmp
          ", "
          dep-reg
          "\n")))))

;; Strength-reduce a three-operand constant multiply: a SIB-scale power of two
;; (2/4/8) becomes a flags-free `leaq (,%lhs,scale), %dst` and a larger power
;; of two whose source already sits in the destination register becomes a bare
;; `shlq` -- both the same instruction count as the imulq they replace and
;; cheaper to execute. Factors 3/5/9 use base + scaled index in one LEA.
;; Mersenne factors `2^k - 1` (`k >= 3`, e.g. 7/15/31/63) lower to
;; `movq; shlq $k; subq` (2c latency vs 3c `imulq`) when a distinct register is
;; available without spilling.
;; `leaq (,%rbp,scale)` is safe under the FPO rsp-rebase pass: the rebased
;; frame shape is `disp(%rbp)`, while this form names only an index.
(define (compiler-backend-mul-immediate-direct-asm-core
  [lhs-reg : (& lhs-reg str)]
  [dst-home : (& dst-home str)]
  [imm : (& imm str)]
  [rhs : (& compiler_ir_types.CompilerIrValue)]
  [scratch-reg : (& scratch-reg str)]
  [in-loop? : bool]) : String
  (match rhs
    [(I64 n)
      (let
        [sib : String (compiler-backend-mul-sib-operand lhs-reg n true)]
        (cond
          [(not (string.eq sib ""))
            (str_cat.str-cat "    leaq " sib ", " dst-home "\n")]
          [(and (>= n 7) (string.eq lhs-reg dst-home))
            (match (compiler-backend-power-of-two-shift n)
              [(Some count)
                (str_cat.str-cat
                  "    shlq $"
                  (string.int->string count)
                  ", "
                  dst-home
                  "\n")]
              [(None)
                (match (compiler-backend-mul-pow2-minus1-shift n)
                  [(Some count)
                    (if (not (string.eq scratch-reg ""))
                      (str_cat.str-cat
                        "    movq "
                        dst-home
                        ", "
                        scratch-reg
                        "\n    shlq $"
                        (string.int->string count)
                        ", "
                        dst-home
                        "\n    subq "
                        scratch-reg
                        ", "
                        dst-home
                        "\n")
                      (str_cat.str-cat
                        "    imulq "
                        imm
                        ", "
                        lhs-reg
                        ", "
                        dst-home
                        "\n"))]
                  [(None)
                    (str_cat.str-cat
                      "    imulq "
                      imm
                      ", "
                      lhs-reg
                      ", "
                      dst-home
                      "\n")])])]
          ;; Three instructions instead of one imulq: worth it for latency
          ;; only inside loops, so straight-line code does not grow.
          [(and in-loop? (not (string.eq lhs-reg dst-home)))
            (match (compiler-backend-mul-pow2-minus1-shift n)
              [(Some count)
                (str_cat.str-cat
                  "    movq "
                  lhs-reg
                  ", "
                  dst-home
                  "\n    shlq $"
                  (string.int->string count)
                  ", "
                  dst-home
                  "\n    subq "
                  lhs-reg
                  ", "
                  dst-home
                  "\n")]
              [(None)
                (str_cat.str-cat
                  "    imulq "
                  imm
                  ", "
                  lhs-reg
                  ", "
                  dst-home
                  "\n")])]
          [else
            (str_cat.str-cat "    imulq " imm ", " lhs-reg ", " dst-home "\n")]))]
    [_ (str_cat.str-cat "    imulq " imm ", " lhs-reg ", " dst-home "\n")]))

(define (compiler-backend-mul-immediate-direct-asm
  [lhs-reg : String]
  [dst-home : String]
  [imm : String]
  [rhs : compiler_ir_types.CompilerIrValue]
  [in-loop? : bool]) : String
  (compiler-backend-mul-immediate-direct-asm-core
    (& lhs-reg)
    (& dst-home)
    (& imm)
    (& rhs)
    ""
    in-loop?))

(define (compiler-backend-mul-immediate-direct-asm-with-state
  [lhs-reg : (& lhs-reg str)]
  [dst-home : (& dst-home str)]
  [imm : (& imm str)]
  [rhs : (& compiler_ir_types.CompilerIrValue)]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [fn-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [cur-label : i64
      (be_state.compiler-backend-function-state-i64
        fn-state
        be_state.compiler-backend-function-i64-current-block-label)]
    [in-loop? : bool
      (be_state.compiler-backend-function-loop-block? fn-state cur-label)]
    [scratch-reg : String
      (if (and
        (string.eq lhs-reg dst-home)
        in-loop?
        (match rhs
          [(I64 n)
            (match (compiler-backend-mul-pow2-minus1-shift n)
              [(Some _) true]
              [(None) false])]
          [_ false]))
        (compiler-backend-free-scratch-reg-here backend-state dst-home "")
        "")]
    (compiler-backend-mul-immediate-direct-asm-core
      lhs-reg
      dst-home
      imm
      rhs
      (& scratch-reg)
      in-loop?)))

;; Doubling can use base + index to avoid the displacement required by a
;; baseless SIB. A fused addition of another register needs the base slot,
;; so that caller keeps the index-only encoding for factors 2/4/8.
(define (compiler-backend-mul-sib-operand
  [reg : (& reg str)]
  [n : i64]
  [double-base? : bool]) : String
  (cond
    [(and (= n 2) double-base?)
      (if (string.eq reg "%rbp")
        "( %rbp,%rbp)"
        (str_cat.str-cat "(" reg "," reg ")"))]
    [(or (= n 2) (= n 4) (= n 8))
      (str_cat.str-cat "(," reg "," (string.int->string n) ")")]
    [(and (or (= n 3) (= n 5) (= n 9)) (not (string.eq reg "%rbp")))
      (str_cat.str-cat "(" reg "," reg "," (string.int->string (- n 1)) ")")]
    [else ""]))

;; The three-operand form for `dst = lhs OP imm` when the destination is not the
;; source's home: `add` is `leaq K(src), dst` and `sub` is the same instruction
;; with the displacement negated, which replaces a `mov` + arithmetic pair. Only
;; a displacement that still encodes as imm32 qualifies (i64 MIN has no
;; negation, so it falls out here).
;;
;; The FPO `%rbp` value-home invariant is centralized here rather than in
;; selected callers. `K(%rbp)` is textually indistinguishable from a frame
;; address to the final rsp rebase. The spaced base spelling preserves that
;; distinction. Any current or
;; retried register plan that reaches this formatter is therefore safe by
;; construction.
(define (compiler-backend-binop-immediate-lea-asm
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [lhs-reg : String]
  [dst-home : (& dst-home str)]
  [imm : (& imm str)]
  [rhs : compiler_ir_types.CompilerIrValue]) : be_state.CompilerBackendMaybeAsm
  (match op
    [(Add)
      (Some
        (str_cat.str-cat
          "    leaq "
          (compiler-backend-immediate-displacement imm)
          (be_operand.compiler-backend-value-base-prefix lhs-reg)
          lhs-reg
          "), "
          dst-home
          "\n"))]
    [(Sub)
      (match (be_operand.compiler-backend-value-as-i64 rhs)
        [(Some value)
          (if (be_operand.compiler-backend-imm32? (- 0 value))
            (Some
              (str_cat.str-cat
                "    leaq "
                (string.int->string (- 0 value))
                (be_operand.compiler-backend-value-base-prefix lhs-reg)
                lhs-reg
                "), "
                dst-home
                "\n"))
            (No))]
        [(None) (No)])]
    [_ (No)]))

(define (compiler-backend-emit-binop-direct-immediate
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst-home : String]
  [mnem : String]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [imm : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [lhs-reg : String
      (be_operand.compiler-backend-value-scalar-register
        backend-state
        assignments
        lhs)]
    (if (and
      (not (string.eq lhs-reg ""))
      (= (be_operand.compiler-backend-type-size type-segment-bases ty) 8)
      (match (& op)
        [(Mul) true]
        [_ false]))
      (Ok
        (compiler-backend-mul-immediate-direct-asm-with-state
          (& lhs-reg)
          (& dst-home)
          (& imm)
          (& rhs)
          backend-state))
      (match (if (and
        (not (string.eq lhs-reg ""))
        (not (string.eq lhs-reg dst-home))
        (not (string.eq imm "$0"))
        (= (be_operand.compiler-backend-type-size type-segment-bases ty) 8))
        (compiler-backend-binop-immediate-lea-asm
          op
          lhs-reg
          dst-home
          imm
          (be_state.compiler-backend-global-shared-view rhs))
        (be_state.CompilerBackendMaybeAsm.No))
        [(Some lea-asm) (Ok lea-asm)]
        [(No)
          (let
            [lhs-asm
              (try
                (be_operand.compiler-backend-emit-load-value
                  assignments
                  lhs
                  (be_state.compiler-backend-global-shared-view dst-home)
                  backend-state))]
            ;; op-asm bound to a local (behavior-neutral) so the seed
            ;; typechecker resolves the append operand without a
            ;; spurious match-arm mismatch.
            ;; `x + 0` / `x - 0` are x at every width (wrapping
            ;; included): the staged lhs move is the whole result.
            [op-asm : String
              (if (and
                (string.eq imm "$0")
                (match (& op)
                  [(or (Add) (Sub)) true]
                  [_ false]))
                ""
                (match (compiler-backend-binop-immediate-direct-reg-asm
                  type-segment-bases
                  mnem
                  op
                  ty
                  imm
                  dst-home
                  (compiler-backend-value-integer-zero? rhs))
                  [(Some asm) asm]
                  [(No) ""]))]
            (Ok (str_cat.str-cat lhs-asm op-asm)))]))))

(define (compiler-backend-binop-direct-immediate-ok?
  [type-segment-bases : i64]
  [mnem : (& mnem str)]
  [op : compiler_ir_types.CompilerIrBinOp]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : bool
  (or
    (be_facts.compiler-backend-compare-op? op)
    (not (string.eq mnem ""))
    (compiler-backend-binop-valid-immediate-shift?
      type-segment-bases
      op
      rhs
      ty
      backend-state)))

(define (compiler-backend-emit-binop-spill-direct-immediate
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [mnem : String]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [operand-ty : compiler_ast_types.AstType]
  [result-ty : compiler_ast_types.AstType]
  [imm : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [result-reg : String
      (be_operand.compiler-backend-scavenge-reg
        dst
        (compiler-backend-binop-scavenge-exclude-for-op op)
        5
        "%r8"
        backend-state)]
    [lhs-reg : String
      (be_operand.compiler-backend-value-scalar-register
        backend-state
        assignments
        lhs)]
    ;; `x + 0` / `x - 0` are x at every width (wrapping included): the
    ;; staged lhs move is the whole result, so no arithmetic follows.
    [zero-addsub? : bool
      (and
        (string.eq imm "$0")
        (match (& op)
          [(or (Add) (Sub)) true]
          [_ false]))]
    (match (if (and
      (not zero-addsub?)
      (not (string.eq lhs-reg ""))
      (=
        (be_operand.compiler-backend-type-size type-segment-bases operand-ty)
        8))
      ;; A register-homed lhs makes the three-operand lea form a strict
      ;; win over load+op: one instruction fewer before the home store.
      (compiler-backend-binop-immediate-lea-asm
        op
        lhs-reg
        result-reg
        imm
        (be_state.compiler-backend-global-shared-view rhs))
      (be_state.CompilerBackendMaybeAsm.No))
      [(Some lea-asm)
        (Ok
          (str_cat.str-cat
            lea-asm
            (be_operand.compiler-backend-emit-store-typed-var
              assignments
              dst
              result-reg
              result-ty
              backend-state)))]
      [(No)
        (let
          [lhs-asm
            (try
              (be_operand.compiler-backend-emit-load-value
                assignments
                lhs
                (be_state.compiler-backend-global-shared-view result-reg)
                backend-state))]
          (match (if zero-addsub?
            (be_state.CompilerBackendMaybeAsm.Some "")
            (compiler-backend-binop-immediate-direct-reg-asm
              type-segment-bases
              mnem
              op
              operand-ty
              imm
              (be_state.compiler-backend-global-shared-view result-reg)
              (compiler-backend-value-integer-zero? rhs)))
            [(Some op-asm)
              (Ok
                (str_cat.str-cat
                  lhs-asm
                  op-asm
                  (be_operand.compiler-backend-emit-store-typed-var
                    assignments
                    dst
                    result-reg
                    result-ty
                    backend-state)))]
            [(No)
              (Err
                (box
                  (compiler_diagnostic.compiler-diagnostic-at-start
                    ""
                    "backend: unsupported immediate spill binop")))]))])))

;; BE-6: the memory operand a binop's RIGHT operand may spell -- the frame slot
;; of a spilled var, the cell a rematerialised frozen read recomputes from
;; (W3(c)), or the cell of a direct full-word scalar-global read. The last is
;; M6-I's compare fold applied to arithmetic: `addq g(%rip), %r` is the whole
;; of `movq g(%rip), %scratch ; addq %scratch, %r`, the cell is read at the
;; same point either way, and nothing sits between the two. CANON-G puts a
;; commutative op's cell operand on the right precisely so this form applies.
(define (compiler-backend-binop-rhs-memory-operand
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [known : String
      (be_operand.compiler-backend-value-read-memory-operand
        assignments
        (be_state.compiler-backend-global-shared-view rhs)
        backend-state)]
    (if (string.eq known "")
      (compiler-backend-value-global-memory-operand
        backend-state
        type-segment-bases
        rhs
        ty)
      known)))

(define (compiler-backend-binop-spill-source-operand
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [rhs-reg : String
      (be_operand.compiler-backend-value-scalar-register
        backend-state
        assignments
        rhs)]
    (if (not (string.eq rhs-reg ""))
      (be_operand.compiler-backend-sized-reg type-segment-bases rhs-reg ty)
      (compiler-backend-binop-rhs-memory-operand
        type-segment-bases
        assignments
        rhs
        ty
        backend-state))))

(define (compiler-backend-emit-binop-spill-direct-source
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [mnem : String]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [operand-ty : compiler_ast_types.AstType]
  [result-ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [rhs-reg : String
      (be_operand.compiler-backend-value-scalar-register
        backend-state
        assignments
        rhs)]
    [rhs-operand : String
      (compiler-backend-binop-spill-source-operand
        type-segment-bases
        assignments
        rhs
        (be_state.compiler-backend-global-shared-view operand-ty)
        backend-state)]
    [exclude : (__tl_dyn-array String)
      (if (string.eq rhs-reg "")
        (compiler-backend-binop-scavenge-exclude-for-op op)
        (compiler-backend-scavenge-exclude-with
          (be_state.compiler-backend-global-shared-view rhs-reg)))]
    [exclude-n : i64
      (if (string.eq rhs-reg "")
        5
        6)]
    [result-reg : String
      (be_operand.compiler-backend-scavenge-reg
        dst
        exclude
        exclude-n
        "%r8"
        backend-state)]
    [lhs-asm
      (try
        (be_operand.compiler-backend-emit-load-value
          assignments
          lhs
          (be_state.compiler-backend-global-shared-view result-reg)
          backend-state))]
    [op-asm : String
      (if (be_facts.compiler-backend-compare-op? op)
        (compiler-backend-binop-compare-set-reg-asm
          type-segment-bases
          op
          (be_state.compiler-backend-global-shared-view operand-ty)
          rhs-operand
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            (be_state.compiler-backend-global-shared-view result-reg)
            operand-ty)
          result-reg)
        (compiler-backend-binop-reg-asm
          type-segment-bases
          mnem
          (be_state.compiler-backend-global-shared-view operand-ty)
          rhs-operand
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            (be_state.compiler-backend-global-shared-view result-reg)
            operand-ty)))]
    (Ok
      (str_cat.str-cat
        lhs-asm
        op-asm
        (be_operand.compiler-backend-emit-store-typed-var
          assignments
          dst
          result-reg
          result-ty
          backend-state)))))

(define (compiler-backend-value-live-after-here?
  [backend-state : be_state.CompilerBackendState]
  [value : compiler_ir_types.CompilerIrValue]) : bool
  (match value
    [(Var var)
      (let
        [point : i64
          (be_state.compiler-backend-function-state-emission-point
            (be_state.compiler-backend-state-function-state backend-state))]
        [ends : (__tl_dyn-array i64)
          (be_state.compiler-backend-function-scratch-i64-array
            (be_state.compiler-backend-state-function-state backend-state)
            be_state.compiler-backend-scratch-i64-array-scavenge-ends)]
        (and
          (>= var 0)
          (< var (array-length ends))
          (>= (array-ref ends var) (+ point 1))))]
    [_ false]))

(define (compiler-backend-divmod-src-register? [reg : (& reg str)]) : bool
  (and
    (not (string.eq reg ""))
    (not (string.eq reg "%rax"))
    (not (string.eq reg "%rdx"))))

;; May the SRC-shaped expansion DESTROY `home` from this instruction onward?
;;
;; Only the REMAINDER shape writes SRC: it ends `subq product, SRC`
;; (compiler-backend-signed-remainder-from-src, and the power-of-two twin), so
;; SRC is written, not merely read. Every quotient shape reads SRC and leaves the
;; result in %rax/%rdx, so a quotient may keep electing the dividend's own home
;; on the value fact alone -- `want-remainder?` false short-circuits to true and
;; that codegen is untouched.
;;
;; For a remainder, electing the dividend's own home as SRC needs a stronger
;; fact than "this VALUE is dead after here": it needs "this REGISTER carries
;; nothing after here".
;;
;; Those two facts come apart for a loop-carried value. It and the header phi
;; that reads it back are separate vars sharing one coalesced home: the body's
;; definition has its own interval, which ends at its last use INSIDE the body,
;; while the phi's interval spans the loop. When that last use is the `%`
;; itself, value-live-after-here? correctly reports the definition dead -- and
;; an expansion that subtracted into that register would silently corrupt the
;; induction state the next iteration still reads.
;;
;; The register-level fact is the one the scavenger already keys on, so ask the
;; same interval/assignment index it does rather than introduce a new analysis.
;; `dst-home` is exempt: when the destination lives in this register the
;; expansion writes exactly where the result belongs, and dst's own interval
;; opening here must not veto its own home.
;; Does `home` still CARRY a value one step past this instruction -- one this
;; instruction is not itself producing?
;;
;; Interval points advance by 2 per instruction and a definition lands on the
;; odd half-step, so `starts[v] == point + 1` identifies exactly the vars THIS
;; instruction defines. Those are what the expansion is producing (including a
;; coalesced alias of the result that is not `dst` itself), so they are not
;; obstacles. Anything else still live at `point + 1` is a value the register is
;; required to be holding, and the register-level index is the allocator's own
;; word on that -- the same interval/assignment data the scavenger consults, so
;; own-SRC selection agrees with what a scavenge at this point would allow.
(define (compiler-backend-divmod-home-carried-after?
  [function-state : be_state.CompilerBackendFunctionState]
  [home : String]
  [point : i64]) : bool
  (let
    [vars : i64
      (be_state.compiler-backend-function-scratch-i64
        function-state
        be_state.compiler-backend-scratch-i64-scavenge-vars)]
    [starts : (__tl_dyn-array i64)
      (be_state.compiler-backend-function-scratch-i64-array
        function-state
        be_state.compiler-backend-scratch-i64-array-scavenge-starts)]
    [ends : (__tl_dyn-array i64)
      (be_state.compiler-backend-function-scratch-i64-array
        function-state
        be_state.compiler-backend-scratch-i64-array-scavenge-ends)]
    [assignment-index : compiler_regalloc.CompilerRegAssignmentTable
      (be_state.compiler-backend-function-scratch-assignment-index
        function-state)]
    [after : i64 (+ point 1)]
    [v : i64 0]
    [carried : bool false]
    (while (and (< v vars) (not carried))
      (if (and
        ;; live-at-point? bounds-checks `v`, so the starts read below is in
        ;; range only because `and` short-circuits on its result.
        (compiler_regalloc.compiler-reg-var-live-at-point? starts ends v after)
        (not (= (array-ref starts v) after))
        (compiler_regalloc.compiler-reg-assignment-table-var-uses-register?
          assignment-index
          v
          (compiler_abi.compiler-abi-register-id-from-spelling
            (be_state.compiler-backend-global-shared-view home))))
        (set! carried true)
        unit)
      (+= v 1))
    carried))

(define (compiler-backend-divmod-src-home-safe?
  [backend-state : be_state.CompilerBackendState]
  [want-remainder? : bool]
  [home : String]
  [dst-home : (& dst-home str)]) : bool
  (or
    (not want-remainder?)
    (string.eq home dst-home)
    (not
      (compiler-backend-divmod-home-carried-after?
        (be_state.compiler-backend-state-function-state backend-state)
        home
        (be_state.compiler-backend-function-state-emission-point
          (be_state.compiler-backend-state-function-state backend-state))))))

;; Register-aware entry for ordinary BinOp emission. A dead non-fixed LHS home
;; is SRC directly. A live dividend whose quotient expansion only seeds %rax
;; loads there directly and keeps its ordinary home intact. Otherwise the
;; destination home, when available, is the natural one-copy SRC; only a
;; fixed/memory/live dividend needs a scavenged source register.
(define (compiler-backend-emit-signed-literal-divmod-dst
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [operand-ty : compiler_ast_types.AstType]
  [result-ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [hoist : CompilerBackendConstHoistHome
      (compiler-backend-const-hoist-here
        (be_state.compiler-backend-state-function-state backend-state))]
    [hoist-reg : String
      (compiler-backend-magic-home-reg-name
        (be_state.compiler-backend-global-shared-view hoist))]
    [needs-material : bool
      (compiler-backend-signed-literal-divmod-needs-material-reg?
        type-segment-bases
        (be_state.compiler-backend-global-shared-view rhs)
        operand-ty
        (compiler-backend-binop-wants-remainder? op)
        (be_state.compiler-backend-global-shared-view hoist))]
    [magic : String
      (if needs-material
        (be_operand.compiler-backend-scavenge-reg
          dst
          (if (string.eq hoist-reg "")
            (compiler-backend-binop-scavenge-exclude-for-op op)
            (be_operand.compiler-backend-scavenge-exclude-append
              (compiler-backend-binop-scavenge-exclude-for-op op)
              5
              (be_state.compiler-backend-global-shared-view hoist-reg)))
          (if (string.eq hoist-reg "")
            5
            6)
          "%r8"
          backend-state)
        "")]
    [lhs-home : String
      (be_operand.compiler-backend-value-scalar-register
        backend-state
        assignments
        lhs)]
    [lhs-live-after : bool
      (compiler-backend-value-live-after-here?
        backend-state
        (be_state.compiler-backend-global-shared-view lhs))]
    [dst-home : String
      (compiler-backend-var-register-home backend-state assignments dst)]
    [direct-rax-src? : bool
      (and
        lhs-live-after
        (not (string.eq lhs-home "%rax"))
        (not (string.eq lhs-home "%rdx"))
        (compiler-backend-signed-literal-divmod-direct-rax-src?
          type-segment-bases
          op
          (be_state.compiler-backend-global-shared-view rhs)
          operand-ty))]
    [own-src? : bool
      (and
        (not direct-rax-src?)
        (compiler-backend-divmod-src-register? lhs-home)
        (not (string.eq lhs-home magic))
        (not (string.eq lhs-home hoist-reg))
        (not lhs-live-after)
        (compiler-backend-divmod-src-home-safe?
          backend-state
          (compiler-backend-binop-wants-remainder? op)
          (be_state.compiler-backend-global-shared-view lhs-home)
          dst-home))]
    [dst-src? : bool
      (and
        (not own-src?)
        (compiler-backend-divmod-src-register? dst-home)
        (not (string.eq dst-home magic))
        (not (string.eq dst-home hoist-reg))
        (not (and lhs-live-after (string.eq dst-home lhs-home))))]
    [src-excl : (__tl_dyn-array String)
      (compiler-backend-divmod-dividend-exclude
        (be_state.compiler-backend-global-shared-view magic))]
    [src : String
      (cond
        [direct-rax-src? "%rax"]
        [own-src? lhs-home]
        [dst-src? (owned_view.compiler-owned-shared-view dst-home)]
        [else
          (compiler-backend-scavenge-divmod-src-reg
            dst
            (if (string.eq hoist-reg "")
              src-excl
              (be_operand.compiler-backend-scavenge-exclude-append
                src-excl
                5
                (be_state.compiler-backend-global-shared-view hoist-reg)))
            (if (string.eq hoist-reg "")
              5
              6)
            backend-state)])]
    [result-reg : String
      (if (string.eq dst-home "")
        (if (compiler-backend-binop-wants-remainder? op)
          (owned_view.compiler-owned-shared-view src)
          ;; Quotient-only strength reductions honor a requested %rax result;
          ;; staging a spilled store there avoids a fixed-register hop.
          "%rax")
        (owned_view.compiler-owned-shared-view dst-home))]
    [load-asm
      (try
        (be_operand.compiler-backend-emit-load-value
          assignments
          lhs
          (be_state.compiler-backend-global-shared-view src)
          backend-state))]
    (match (compiler-backend-signed-literal-divmod-src-asm
      type-segment-bases
      op
      rhs
      operand-ty
      magic
      src
      (be_state.compiler-backend-global-shared-view result-reg)
      hoist)
      [(Some op-asm)
        (Ok
          (str_cat.str-cat
            load-asm
            op-asm
            (if (string.eq dst-home "")
              (be_operand.compiler-backend-emit-store-typed-var
                assignments
                dst
                result-reg
                result-ty
                backend-state)
              "")))]
      [(No)
        (Err
          (box
            (compiler_diagnostic.compiler-diagnostic-at-start
              ""
              "backend: signed literal divmod shape unavailable")))])))

(define (compiler-backend-emit-signed-literal-divmod-here
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [operand-ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [hoist : CompilerBackendConstHoistHome (CompilerBackendNoConstHoistHome)]
    [needs-material : bool
      (compiler-backend-signed-literal-divmod-needs-material-reg?
        type-segment-bases
        (be_state.compiler-backend-global-shared-view rhs)
        operand-ty
        (compiler-backend-binop-wants-remainder? op)
        (be_state.compiler-backend-global-shared-view hoist))]
    [magic : String
      (if needs-material
        (be_operand.compiler-backend-scavenge-reg-here
          (compiler-backend-binop-scavenge-exclude-for-op op)
          5
          "%r8"
          backend-state)
        "")]
    [lhs-home : String
      (be_operand.compiler-backend-value-scalar-register
        backend-state
        assignments
        lhs)]
    [own-src? : bool
      (and
        (compiler-backend-divmod-src-register? lhs-home)
        (not
          (compiler-backend-value-live-after-here?
            backend-state
            (be_state.compiler-backend-global-shared-view lhs)))
        ;; No destination register on this path (the result stays in %rax), so
        ;; nothing is exempt from the register-level check.
        (compiler-backend-divmod-src-home-safe?
          backend-state
          (compiler-backend-binop-wants-remainder? op)
          (be_state.compiler-backend-global-shared-view lhs-home)
          ""))]
    [src : String
      (if own-src?
        lhs-home
        (compiler-backend-scavenge-divmod-src-reg-here
          (compiler-backend-divmod-dividend-exclude
            (be_state.compiler-backend-global-shared-view magic))
          5
          backend-state))]
    [load-asm
      (try
        (be_operand.compiler-backend-emit-load-value
          assignments
          lhs
          (be_state.compiler-backend-global-shared-view src)
          backend-state))]
    (match (compiler-backend-signed-literal-divmod-src-asm
      type-segment-bases
      op
      rhs
      operand-ty
      magic
      src
      "%rax"
      hoist)
      [(Some op-asm) (Ok (str_cat.str-cat load-asm op-asm))]
      [(No)
        (Err
          (box
            (compiler_diagnostic.compiler-diagnostic-at-start
              ""
              "backend: signed literal divmod shape unavailable")))])))

(define (compiler-backend-emit-binop
  [type-segment-bases : i64]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (compiler-backend-binop-f64?
    types
    (be_state.compiler-backend-global-shared-view global-types)
    lhs
    rhs
    ty)
    (let
      [fty : compiler_ast_types.AstType
        (compiler-backend-binop-operand-ty
          types
          global-types
          (be_state.compiler-backend-global-shared-view op)
          (be_state.compiler-backend-global-shared-view lhs)
          (be_state.compiler-backend-global-shared-view rhs)
          (be_state.compiler-backend-global-shared-view ty))]
      [result-ty : compiler_ast_types.AstType
        (compiler_ir_types.compiler-ir-binop-result-type
          (& op)
          (be_state.compiler-backend-global-shared-view ty))]
      [dst-home : String
        (compiler-backend-var-register-home backend-state assignments dst)]
      [rhs-operand : String
        (compiler-backend-float-direct-rhs-operand
          assignments
          (be_state.compiler-backend-global-shared-view rhs)
          fty
          dst-home
          backend-state)]
      [spill-rhs-operand : String
        (compiler-backend-float-direct-rhs-operand
          assignments
          (be_state.compiler-backend-global-shared-view rhs)
          fty
          ""
          backend-state)]
      [lhs-float-reg : String
        (compiler-backend-float-value-register backend-state assignments lhs)]
      (if (and
        (be_facts.compiler-backend-compare-op? op)
        (not (string.eq lhs-float-reg ""))
        (or
          (and
            (not (string.eq dst-home ""))
            (not
              (be_operand.compiler-backend-string-prefix-at? dst-home "%xmm" 0))
            (not (string.eq rhs-operand "")))
          (and (string.eq dst-home "") (not (string.eq spill-rhs-operand "")))))
        (if (string.eq dst-home "")
          (compiler-backend-emit-float-compare-spill-direct
            assignments
            dst
            op
            lhs
            rhs
            fty
            result-ty
            backend-state)
          (compiler-backend-emit-float-compare-direct
            assignments
            dst-home
            op
            lhs
            rhs
            fty
            backend-state))
        (if (and
          (be_operand.compiler-backend-float-type? ty)
          (compiler-backend-float-arith-op? op)
          (or
            (and
              (be_operand.compiler-backend-string-prefix-at? dst-home "%xmm" 0)
              (not (string.eq rhs-operand "")))
            (and (string.eq dst-home "") (not (string.eq spill-rhs-operand "")))))
          (if (string.eq dst-home "")
            (compiler-backend-emit-float-binop-spill-direct
              assignments
              dst
              op
              lhs
              rhs
              fty
              backend-state)
            (compiler-backend-emit-float-binop-direct
              assignments
              dst-home
              op
              lhs
              rhs-operand
              fty
              backend-state))
          (compiler-backend-emit-float-binop-fallback
            assignments
            dst
            op
            lhs
            rhs
            fty
            result-ty
            backend-state))))
    (let
      [operand-ty : compiler_ast_types.AstType
        (compiler-backend-binop-operand-ty
          types
          global-types
          (be_state.compiler-backend-global-shared-view op)
          (be_state.compiler-backend-global-shared-view lhs)
          (be_state.compiler-backend-global-shared-view rhs)
          (be_state.compiler-backend-global-shared-view ty))]
      [result-ty : compiler_ast_types.AstType
        (compiler_ir_types.compiler-ir-binop-result-type (& op) ty)]
      [dst-home : String
        (compiler-backend-var-register-home backend-state assignments dst)]
      [mnem : String (compiler-backend-binop-direct-mnemonic op)]
      ;; lint-allow: nested-if-ladder
      (if (and
        (compiler_regalloc.compiler-reg-clobber-binop-shift?
          (& op)
          (& rhs)
          (& operand-ty))
        (not
          (compiler-backend-binop-rcx-shift?
            backend-state
            assignments
            op
            (be_state.compiler-backend-global-shared-view rhs)
            dst-home)))
        (compiler-backend-emit-binop-spill-direct-shift
          type-segment-bases
          assignments
          dst
          (be_state.compiler-backend-global-shared-view op)
          lhs
          rhs
          operand-ty
          result-ty
          backend-state)
        (if (if (string.eq dst-home "")
          (match (be_operand.compiler-backend-immediate-operand
            backend-state
            rhs)
            [(Some _)
              (and
                (compiler-backend-binop-direct-width-ok?
                  type-segment-bases
                  op
                  (be_state.compiler-backend-global-shared-view operand-ty))
                (compiler-backend-binop-direct-immediate-ok?
                  type-segment-bases
                  mnem
                  (be_state.compiler-backend-global-shared-view op)
                  (be_state.compiler-backend-global-shared-view rhs)
                  (be_state.compiler-backend-global-shared-view operand-ty)
                  backend-state))]
            [(No)
              (and
                (compiler-backend-binop-direct-width-ok?
                  type-segment-bases
                  op
                  (be_state.compiler-backend-global-shared-view operand-ty))
                (or
                  (be_facts.compiler-backend-compare-op? op)
                  (not (string.eq mnem ""))
                  (compiler-backend-binop-shift-op? op))
                (not
                  (string.eq
                    (compiler-backend-binop-spill-source-operand
                      type-segment-bases
                      assignments
                      (be_state.compiler-backend-global-shared-view rhs)
                      (be_state.compiler-backend-global-shared-view operand-ty)
                      backend-state)
                    "")))])
          (or
            (be_facts.compiler-backend-compare-op? op)
            (and
              (compiler-backend-binop-direct-width-ok?
                type-segment-bases
                op
                (be_state.compiler-backend-global-shared-view operand-ty))
              (or
                (not (string.eq mnem ""))
                (compiler-backend-binop-valid-immediate-shift?
                  type-segment-bases
                  (be_state.compiler-backend-global-shared-view op)
                  (be_state.compiler-backend-global-shared-view rhs)
                  (be_state.compiler-backend-global-shared-view operand-ty)
                  backend-state)
                (compiler-backend-binop-rcx-shift?
                  backend-state
                  assignments
                  op
                  (be_state.compiler-backend-global-shared-view rhs)
                  dst-home)))))
          ;; Accumulate directly in the destination register: dst = lhs <op> rhs.
          ;; If rhs already lives in a register distinct from
          ;; dst-home, source the op straight from that home -- load lhs into
          ;; dst-home, then "<op> rhs-home, dst-home" -- skipping the "movq
          ;; rhs-home,%r8" stage entirely (rhs-home != dst-home guarantees the lhs
          ;; load cannot clobber it). Otherwise stage rhs through %r8 FIRST: lhs
          ;; goes into dst's home register, which may itself be rhs's home, and
          ;; loading lhs first would clobber rhs.
          (match (be_operand.compiler-backend-immediate-operand
            backend-state
            rhs)
            [(Some imm)
              (if (string.eq dst-home "")
                (compiler-backend-emit-binop-spill-direct-immediate
                  type-segment-bases
                  assignments
                  dst
                  mnem
                  (be_state.compiler-backend-global-shared-view op)
                  lhs
                  (be_state.compiler-backend-global-shared-view rhs)
                  operand-ty
                  result-ty
                  imm
                  backend-state)
                (compiler-backend-emit-binop-direct-immediate
                  type-segment-bases
                  assignments
                  dst-home
                  mnem
                  (be_state.compiler-backend-global-shared-view op)
                  lhs
                  (be_state.compiler-backend-global-shared-view rhs)
                  operand-ty
                  imm
                  backend-state))]
            [(No)
              (cond
                [(and
                    (string.eq dst-home "")
                    (compiler-backend-binop-shift-op? op))
                  (compiler-backend-emit-binop-spill-direct-shift
                    type-segment-bases
                    assignments
                    dst
                    (be_state.compiler-backend-global-shared-view op)
                    lhs
                    rhs
                    operand-ty
                    result-ty
                    backend-state)]
                [(string.eq dst-home "")
                  (compiler-backend-emit-binop-spill-direct-source
                    type-segment-bases
                    assignments
                    dst
                    mnem
                    (be_state.compiler-backend-global-shared-view op)
                    lhs
                    rhs
                    operand-ty
                    result-ty
                    backend-state)]
                [(be_facts.compiler-backend-compare-op? op)
                  (compiler-backend-emit-binop-direct-compare
                    type-segment-bases
                    assignments
                    dst
                    dst-home
                    op
                    lhs
                    rhs
                    operand-ty
                    backend-state)]
                [(compiler-backend-binop-shift-op? op)
                  (compiler-backend-emit-binop-direct-rcx-shift
                    type-segment-bases
                    assignments
                    dst-home
                    op
                    lhs
                    operand-ty
                    backend-state)]
                [else
                  (let
                    [rhs-hoist : String
                      (compiler-backend-const-hoist-value-home-reg
                        (be_state.compiler-backend-state-function-state
                          backend-state)
                        (be_state.compiler-backend-global-shared-view rhs))]
                    [rhs-reg : String
                      (if (string.eq rhs-hoist "")
                        (be_operand.compiler-backend-value-scalar-register
                          backend-state
                          assignments
                          rhs)
                        (owned_view.compiler-owned-shared-view rhs-hoist))]
                    [lhs-reg : String
                      (be_operand.compiler-backend-value-scalar-register
                        backend-state
                        assignments
                        lhs)]
                    [rhs-operand : String
                      (if (string.eq rhs-hoist "")
                        (compiler-backend-binop-spill-source-operand
                          type-segment-bases
                          assignments
                          (be_state.compiler-backend-global-shared-view rhs)
                          (be_state.compiler-backend-global-shared-view
                            operand-ty)
                          backend-state)
                        (be_operand.compiler-backend-sized-reg
                          type-segment-bases
                          rhs-hoist
                          (be_state.compiler-backend-global-shared-view
                            operand-ty)))]
                    ;; lint-allow: nested-if-ladder
                    (if (and
                      (or
                        (string.eq mnem "and")
                        (string.eq mnem "or")
                        (string.eq mnem "xor"))
                      (not (string.eq lhs-reg ""))
                      (string.eq rhs-reg dst-home))
                      ;; commutative shortcut: rhs-home == dst-home, so dst-home already
                      ;; holds rhs; for and/or/xor emit "<op> lhs, dst" directly -- no
                      ;; scav-rhs copy and no lhs->dst copy (dst = rhs <op> lhs = lhs <op>
                      ;; rhs, commutative). Saves two movs + a scratch register vs the
                      ;; scav path below.
                      (Ok
                        (compiler-backend-binop-reg-asm
                          type-segment-bases
                          mnem
                          (be_state.compiler-backend-global-shared-view
                            operand-ty)
                          (be_operand.compiler-backend-sized-reg
                            type-segment-bases
                            lhs-reg
                            (be_state.compiler-backend-global-shared-view
                              operand-ty))
                          (be_operand.compiler-backend-sized-reg
                            type-segment-bases
                            dst-home
                            (be_state.compiler-backend-global-shared-view
                              operand-ty))))
                      (if (and
                        (string.eq mnem "add")
                        (not (string.eq lhs-reg ""))
                        (not (string.eq rhs-reg ""))
                        ;; #rbp-base: %rbp must not land in the SIB BASE slot
                        ;; ("(%rbp," fails the FPO audit). Addition commutes, so
                        ;; an rbp-homed lhs swaps into the INDEX slot; only the
                        ;; both-rbp case (lhs == rhs == %rbp) falls through.
                        (not
                          (and
                            (string.eq lhs-reg "%rbp")
                            (string.eq rhs-reg "%rbp"))))
                        ;; bucket a (two-address tie): when both operands already live in
                        ;; registers and the op is add, emit a 3-address LEA so the
                        ;; "movq lhs,dst-home" tie copy is never produced -- dst-home =
                        ;; lhs-reg + rhs-reg. LEA does not set flags, but this SSA backend
                        ;; never consumes a binop's flags (comparisons emit their own cmp).
                        (Ok
                          (str_cat.str-cat
                            "    leaq ("
                            (if (string.eq lhs-reg "%rbp")
                              (owned_view.compiler-owned-shared-view rhs-reg)
                              (owned_view.compiler-owned-shared-view lhs-reg))
                            ","
                            (if (string.eq lhs-reg "%rbp")
                              lhs-reg
                              rhs-reg)
                            "), "
                            dst-home
                            "\n"))
                        (if (and
                          (not (string.eq rhs-reg dst-home))
                          (not (string.eq rhs-operand "")))
                          ;; Scalar load-fold: rhs-operand is the rhs's sized register
                          ;; (rhs already in a distinct reg) OR, when rhs is a spilled var,
                          ;; its DISP(%rbp) slot. Either way: load lhs into dst-home, then
                          ;; "<op> rhs-operand, dst-home" directly -- for a spilled rhs this
                          ;; folds the memory operand and skips the "movq rhs-slot,%scav"
                          ;; reload (rhs lives in memory, so loading lhs into dst-home cannot
                          ;; clobber it). rhs-reg==dst-home still falls through to the reload
                          ;; (rhs must be saved before lhs overwrites dst-home).
                          (let
                            [lhs-asm
                              (try
                                (be_operand.compiler-backend-emit-load-value
                                  assignments
                                  lhs
                                  (be_state.compiler-backend-global-shared-view
                                    dst-home)
                                  backend-state))]
                            (Ok
                              (str_cat.str-cat
                                lhs-asm
                                (compiler-backend-binop-reg-asm
                                  type-segment-bases
                                  mnem
                                  (be_state.compiler-backend-global-shared-view
                                    operand-ty)
                                  rhs-operand
                                  (be_operand.compiler-backend-sized-reg
                                    type-segment-bases
                                    dst-home
                                    (be_state.compiler-backend-global-shared-view
                                      operand-ty))))))
                          ;; Only the staged fallback needs a scratch. Selecting
                          ;; it before the commutative, LEA, and source-fold
                          ;; branches can enqueue an emergency save for a
                          ;; register absent from the chosen instruction.
                          (let
                            [scav-rhs : String
                              (be_operand.compiler-backend-scavenge-reg-here
                                (compiler-backend-scavenge-exclude-regs2
                                  (be_state.compiler-backend-global-shared-view
                                    dst-home)
                                  lhs-reg)
                                7
                                "%r8"
                                backend-state)]
                            [rhs-asm
                              (try
                                (be_operand.compiler-backend-emit-load-value
                                  assignments
                                  rhs
                                  (be_state.compiler-backend-global-shared-view
                                    scav-rhs)
                                  backend-state))]
                            [lhs-asm
                              (try
                                (be_operand.compiler-backend-emit-load-value
                                  assignments
                                  lhs
                                  (be_state.compiler-backend-global-shared-view
                                    dst-home)
                                  backend-state))]
                            (Ok
                              (str_cat.str-cat
                                rhs-asm
                                lhs-asm
                                (compiler-backend-binop-reg-asm
                                  type-segment-bases
                                  mnem
                                  (be_state.compiler-backend-global-shared-view
                                    operand-ty)
                                  (be_operand.compiler-backend-sized-reg
                                    type-segment-bases
                                    scav-rhs
                                    (be_state.compiler-backend-global-shared-view
                                      operand-ty))
                                  (be_operand.compiler-backend-sized-reg
                                    type-segment-bases
                                    dst-home
                                    (be_state.compiler-backend-global-shared-view
                                      operand-ty))))))))))])])
          (if (compiler-backend-signed-literal-divmod-src-shape?
            type-segment-bases
            op
            (be_state.compiler-backend-global-shared-view rhs)
            (be_state.compiler-backend-global-shared-view operand-ty))
            (compiler-backend-emit-signed-literal-divmod-dst
              type-segment-bases
              assignments
              dst
              op
              lhs
              rhs
              (be_state.compiler-backend-global-shared-view operand-ty)
              result-ty
              backend-state)
            (let
              [staging : String
                (match (& op)
                  [(or (Div) (Mod) (SafeDiv) (SafeMod)) "%rax"]
                  [_
                    (be_operand.compiler-backend-scavenge-reg
                      dst
                      (compiler-backend-scavenge-exclude-regs2
                        (be_operand.compiler-backend-value-scalar-register
                          backend-state
                          assignments
                          rhs)
                        "")
                      7
                      "%rax"
                      backend-state)])]
              [lhs-asm
                (try
                  (be_operand.compiler-backend-emit-load-value
                    assignments
                    lhs
                    (be_state.compiler-backend-global-shared-view staging)
                    backend-state))]
              (match (compiler-backend-binop-literal-divmod-asm-dst
                type-segment-bases
                (be_state.compiler-backend-global-shared-view op)
                (be_state.compiler-backend-global-shared-view rhs)
                (be_state.compiler-backend-global-shared-view operand-ty)
                dst
                backend-state)
                [(Some op-asm)
                  (Ok
                    (str_cat.str-cat
                      lhs-asm
                      op-asm
                      (be_operand.compiler-backend-emit-store-typed-var
                        assignments
                        dst
                        staging
                        result-ty
                        backend-state)))]
                [(No)
                  (match (be_operand.compiler-backend-immediate-operand
                    backend-state
                    rhs)
                    [(Some imm)
                      (match (compiler-backend-binop-immediate-asm
                        type-segment-bases
                        (be_state.compiler-backend-global-shared-view op)
                        imm
                        (be_state.compiler-backend-global-shared-view
                          operand-ty)
                        (be_state.compiler-backend-global-shared-view staging)
                        (be_state.compiler-backend-global-shared-view staging)
                        (compiler-backend-value-integer-zero?
                          (be_state.compiler-backend-global-shared-view rhs)))
                        [(Some op-asm)
                          (Ok
                            (str_cat.str-cat
                              lhs-asm
                              op-asm
                              (be_operand.compiler-backend-emit-store-typed-var
                                assignments
                                dst
                                (be_state.compiler-backend-global-shared-view
                                  staging)
                                result-ty
                                backend-state)))]
                        [(No)
                          (let
                            [scav-rhs : String
                              (be_operand.compiler-backend-scavenge-reg-here
                                (compiler-backend-scavenge-exclude-regs2
                                  (be_state.compiler-backend-global-shared-view
                                    staging)
                                  "")
                                7
                                "%r8"
                                backend-state)]
                            [rhs-asm
                              (try
                                (be_operand.compiler-backend-emit-load-value
                                  assignments
                                  rhs
                                  (be_state.compiler-backend-global-shared-view
                                    scav-rhs)
                                  backend-state))]
                            (Ok
                              (str_cat.str-cat
                                lhs-asm
                                rhs-asm
                                (compiler-backend-binop-asm
                                  type-segment-bases
                                  (be_state.compiler-backend-global-shared-view
                                    op)
                                  operand-ty
                                  scav-rhs
                                  (be_state.compiler-backend-global-shared-view
                                    staging)
                                  ""
                                  ""
                                  backend-state)
                                (be_operand.compiler-backend-emit-store-typed-var
                                  assignments
                                  dst
                                  (be_state.compiler-backend-global-shared-view
                                    staging)
                                  result-ty
                                  backend-state))))])]
                    [(No)
                      (let
                        ;; BE-6: a direct scalar-global cell is a legal
                        ;; memory source too (`addq g(%rip), %r`), exactly
                        ;; as M6-I lets a compare read one.
                        [rhs-address : String
                          (compiler-backend-binop-rhs-memory-operand
                            type-segment-bases
                            assignments
                            (be_state.compiler-backend-global-shared-view rhs)
                            (be_state.compiler-backend-global-shared-view
                              operand-ty)
                            backend-state)]
                        (if (not (string.eq rhs-address ""))
                          (match (compiler-backend-binop-source-asm
                            type-segment-bases
                            op
                            (be_state.compiler-backend-global-shared-view
                              operand-ty)
                            rhs-address
                            (be_state.compiler-backend-global-shared-view
                              staging))
                            [(Some op-asm)
                              (Ok
                                (str_cat.str-cat
                                  lhs-asm
                                  op-asm
                                  (be_operand.compiler-backend-emit-store-typed-var
                                    assignments
                                    dst
                                    (be_state.compiler-backend-global-shared-view
                                      staging)
                                    result-ty
                                    backend-state)))]
                            [(No)
                              (let
                                [scav-rhs : String
                                  (be_operand.compiler-backend-scavenge-reg-here
                                    (compiler-backend-scavenge-exclude-regs2
                                      (be_state.compiler-backend-global-shared-view
                                        staging)
                                      "")
                                    7
                                    "%r8"
                                    backend-state)]
                                [rhs-asm
                                  (try
                                    (be_operand.compiler-backend-emit-load-value
                                      assignments
                                      rhs
                                      (be_state.compiler-backend-global-shared-view
                                        scav-rhs)
                                      backend-state))]
                                (Ok
                                  (str_cat.str-cat
                                    lhs-asm
                                    rhs-asm
                                    (compiler-backend-binop-asm
                                      type-segment-bases
                                      (be_state.compiler-backend-global-shared-view
                                        op)
                                      (be_state.compiler-backend-global-shared-view
                                        operand-ty)
                                      (be_state.compiler-backend-global-shared-view
                                        scav-rhs)
                                      (be_state.compiler-backend-global-shared-view
                                        staging)
                                      ""
                                      ""
                                      backend-state)
                                    (be_operand.compiler-backend-emit-store-typed-var
                                      assignments
                                      dst
                                      (be_state.compiler-backend-global-shared-view
                                        staging)
                                      result-ty
                                      backend-state))))])
                          ;; #perf: rhs has no stack address, so it is register-
                          ;; homed (or a non-addressable value). When it lives in a
                          ;; register distinct from %rax (the temp holding lhs),
                          ;; source the op straight from that register instead of
                          ;; staging it through %r8 -- `movq %r15,%r8 ; addq
                          ;; %r8,%rax` collapses to `addq %r15,%rax`. This mirrors
                          ;; the stack-address fast path above and the register-dst
                          ;; direct path; it is purely an emission change,
                          ;; so register allocation is unaffected. Ops that have no
                          ;; binop-source-asm form fall back to %r8 staging.
                          (let
                            [rhs-hoist : String
                              (compiler-backend-const-hoist-value-home-reg
                                (be_state.compiler-backend-state-function-state
                                  backend-state)
                                (be_state.compiler-backend-global-shared-view
                                  rhs))]
                            [rhs-reg : String
                              (if (string.eq rhs-hoist "")
                                (be_operand.compiler-backend-value-scalar-register
                                  backend-state
                                  assignments
                                  rhs)
                                rhs-hoist)]
                            [lhs-reg : String
                              (be_operand.compiler-backend-value-scalar-register
                                backend-state
                                assignments
                                lhs)]
                            ;; Div/mod materialise the dividend in %rax; if the
                            ;; divisor also lives there, save it before lhs
                            ;; overwrites %rax.
                            [preserve-rhs-before-lhs? : bool
                              (and
                                (compiler-backend-divmod-op? op)
                                (string.eq rhs-reg staging))]
                            (match (if (if (string.eq rhs-reg "")
                              false
                              (not (string.eq rhs-reg staging)))
                              (compiler-backend-binop-source-asm
                                type-segment-bases
                                op
                                (be_state.compiler-backend-global-shared-view
                                  operand-ty)
                                (be_operand.compiler-backend-sized-reg
                                  type-segment-bases
                                  rhs-reg
                                  (be_state.compiler-backend-global-shared-view
                                    operand-ty))
                                (be_state.compiler-backend-global-shared-view
                                  staging))
                              (be_state.CompilerBackendMaybeAsm.No))
                              [(Some op-asm)
                                (Ok
                                  (str_cat.str-cat
                                    lhs-asm
                                    op-asm
                                    (be_operand.compiler-backend-emit-store-typed-var
                                      assignments
                                      dst
                                      (be_state.compiler-backend-global-shared-view
                                        staging)
                                      result-ty
                                      backend-state)))]
                              [(No)
                                ;; A directly encodable register source has
                                ;; already been selected above. Defer the
                                ;; side-effecting scratch request until this
                                ;; staged fallback is certain to consume it.
                                (let
                                  [scav-rhs : String
                                    (be_operand.compiler-backend-scavenge-reg-here
                                      (if preserve-rhs-before-lhs?
                                        (compiler-backend-scavenge-exclude-regs2
                                          (be_state.compiler-backend-global-shared-view
                                            staging)
                                          lhs-reg)
                                        (compiler-backend-scavenge-exclude-regs2
                                          (be_state.compiler-backend-global-shared-view
                                            staging)
                                          ""))
                                      7
                                      "%r8"
                                      backend-state)]
                                  [rhs-asm
                                    (try
                                      (be_operand.compiler-backend-emit-load-value
                                        assignments
                                        rhs
                                        (be_state.compiler-backend-global-shared-view
                                          scav-rhs)
                                        backend-state))]
                                  (Ok
                                    (if preserve-rhs-before-lhs?
                                      (str_cat.str-cat
                                        rhs-asm
                                        lhs-asm
                                        (compiler-backend-binop-asm
                                          type-segment-bases
                                          op
                                          operand-ty
                                          scav-rhs
                                          (be_state.compiler-backend-global-shared-view
                                            staging)
                                          ""
                                          ""
                                          backend-state)
                                        (be_operand.compiler-backend-emit-store-typed-var
                                          assignments
                                          dst
                                          (be_state.compiler-backend-global-shared-view
                                            staging)
                                          result-ty
                                          backend-state))
                                      (str_cat.str-cat
                                        lhs-asm
                                        rhs-asm
                                        (compiler-backend-binop-asm
                                          type-segment-bases
                                          op
                                          operand-ty
                                          scav-rhs
                                          (be_state.compiler-backend-global-shared-view
                                            staging)
                                          ""
                                          ""
                                          backend-state)
                                        (be_operand.compiler-backend-emit-store-typed-var
                                          assignments
                                          dst
                                          staging
                                          result-ty
                                          backend-state)))))]))))])]))))))))

(define (compiler-backend-rax-forwardable-binop?
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [lhs : (& compiler_ir_types.CompilerIrValue)]
  [rhs : (& compiler_ir_types.CompilerIrValue)]
  [ty : (& ty compiler_ast_types.AstType)]) : bool
  (and
    (compiler_regalloc.compiler-reg-assignment-table-empty? assignments)
    (not (be_facts.compiler-backend-compare-op? op))
    (not (compiler-backend-binop-f64? types global-types lhs rhs ty))))

(define (compiler-backend-binop-result-store
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [ty : compiler_ast_types.AstType]
  [store-result : bool]
  [backend-state : be_state.CompilerBackendState]) : String
  (if store-result
    (be_operand.compiler-backend-emit-store-typed-var
      assignments
      dst
      "%rax"
      ty
      backend-state)
    ""))

(define (compiler-backend-emit-binop-rax-rhs-staged
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [rhs : compiler_ir_types.CompilerIrValue]
  [operand-ty : compiler_ast_types.AstType]
  [store : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [scratch : String
      (be_operand.compiler-backend-scavenge-reg
        dst
        (compiler-backend-binop-scavenge-exclude-for-op op)
        5
        "%r8"
        backend-state)]
    [rhs-asm
      (try
        (be_operand.compiler-backend-emit-load-value
          assignments
          rhs
          (be_state.compiler-backend-global-shared-view scratch)
          backend-state))]
    (Ok
      (str_cat.str-cat
        rhs-asm
        (compiler-backend-binop-asm
          type-segment-bases
          op
          operand-ty
          scratch
          "%rax"
          ""
          ""
          backend-state)
        store))))

(define (compiler-backend-emit-binop-rax-rhs
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [rhs : compiler_ir_types.CompilerIrValue]
  [operand-ty : compiler_ast_types.AstType]
  [result-ty : compiler_ast_types.AstType]
  [store-result : bool]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (compiler-backend-signed-literal-divmod-src-shape?
    type-segment-bases
    op
    (be_state.compiler-backend-global-shared-view rhs)
    (be_state.compiler-backend-global-shared-view operand-ty))
    (let
      [store : String
        (compiler-backend-binop-result-store
          assignments
          dst
          result-ty
          store-result
          backend-state)]
      (match (compiler-backend-binop-literal-divmod-asm-dst
        type-segment-bases
        op
        rhs
        operand-ty
        dst
        backend-state)
        [(Some op-asm) (Ok (str_cat.str-cat op-asm store))]
        [(No)
          (Err
            (box
              (compiler_diagnostic.compiler-diagnostic-at-start
                ""
                "backend: signed literal divmod shape unavailable")))]))
    (let
      [store : String
        (compiler-backend-binop-result-store
          assignments
          dst
          result-ty
          store-result
          backend-state)]
      (if (compiler-backend-divmod-op? op)
        (let
          [scav-rhs : String
            (be_operand.compiler-backend-scavenge-reg
              dst
              (compiler-backend-binop-scavenge-exclude-for-op op)
              5
              "%r8"
              backend-state)]
          [scav-dividend : String
            (be_operand.compiler-backend-scavenge-reg
              dst
              (compiler-backend-divmod-dividend-exclude
                (be_state.compiler-backend-global-shared-view scav-rhs))
              5
              "%r10"
              backend-state)]
          [scav-mask : String
            (be_operand.compiler-backend-scavenge-reg
              dst
              (compiler-backend-divmod-mask-exclude
                (be_state.compiler-backend-global-shared-view scav-rhs)
                (be_state.compiler-backend-global-shared-view scav-dividend))
              6
              "%r9"
              backend-state)]
          ;; Stack-only path (empty-assignments gate) -- const-hoist never
          ;; plans sites here, so no magic home lookup.
          (match (compiler-backend-binop-literal-divmod-asm
            type-segment-bases
            op
            (be_state.compiler-backend-global-shared-view rhs)
            (be_state.compiler-backend-global-shared-view operand-ty)
            (be_state.compiler-backend-global-shared-view scav-rhs)
            (be_state.compiler-backend-global-shared-view scav-dividend)
            (be_state.compiler-backend-global-shared-view scav-mask)
            (CompilerBackendNoConstHoistHome))
            [(Some op-asm) (Ok (str_cat.str-cat op-asm store))]
            [(No)
              ;; A variable or non-strength-reducible divisor uses the ordinary
              ;; idiv/div lowering. The RAX-forwarded path already has the
              ;; dividend in %rax, so stage only the divisor and reuse the two
              ;; remaining modeled homes for signed overflow guards.
              (let
                [rhs-asm
                  (try
                    (be_operand.compiler-backend-emit-load-value
                      assignments
                      rhs
                      (be_state.compiler-backend-global-shared-view scav-rhs)
                      backend-state))]
                (Ok
                  (str_cat.str-cat
                    rhs-asm
                    (str_cat.str-cat
                      (compiler-backend-binop-asm
                        type-segment-bases
                        op
                        operand-ty
                        scav-rhs
                        "%rax"
                        scav-dividend
                        scav-mask
                        backend-state)
                      store))))]))
        (match (be_operand.compiler-backend-immediate-operand backend-state rhs)
          [(Some imm)
            (match (compiler-backend-binop-immediate-asm
              type-segment-bases
              (be_state.compiler-backend-global-shared-view op)
              imm
              (be_state.compiler-backend-global-shared-view operand-ty)
              "%rax"
              "%rax"
              (compiler-backend-value-integer-zero?
                (be_state.compiler-backend-global-shared-view rhs)))
              [(Some op-asm) (Ok (str_cat.str-cat op-asm store))]
              [(No)
                (compiler-backend-emit-binop-rax-rhs-staged
                  type-segment-bases
                  assignments
                  dst
                  op
                  rhs
                  operand-ty
                  store
                  backend-state)])]
          [(No)
            (compiler-backend-emit-binop-rax-rhs-staged
              type-segment-bases
              assignments
              dst
              op
              rhs
              operand-ty
              store
              backend-state)])))))

(define (compiler-backend-emit-binop-to-rax
  [type-segment-bases : i64]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [store-result : bool]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (compiler-backend-rax-forwardable-binop?
    types
    (be_state.compiler-backend-global-shared-view global-types)
    assignments
    op
    lhs
    rhs
    ty)
    (let
      [operand-ty : compiler_ast_types.AstType
        (compiler-backend-binop-operand-ty
          types
          global-types
          (be_state.compiler-backend-global-shared-view op)
          (be_state.compiler-backend-global-shared-view lhs)
          (be_state.compiler-backend-global-shared-view rhs)
          (be_state.compiler-backend-global-shared-view ty))]
      [lhs-asm
        (try
          (be_operand.compiler-backend-emit-load-value
            assignments
            lhs
            "%rax"
            backend-state))]
      [op-asm
        (try
          (compiler-backend-emit-binop-rax-rhs
            type-segment-bases
            assignments
            dst
            (be_state.compiler-backend-global-shared-view op)
            (be_state.compiler-backend-global-shared-view rhs)
            (be_state.compiler-backend-global-shared-view operand-ty)
            ty
            store-result
            backend-state))]
      (Ok (str_cat.str-cat lhs-asm op-asm)))
    (compiler-backend-emit-binop
      type-segment-bases
      types
      global-types
      assignments
      dst
      op
      lhs
      rhs
      ty
      backend-state)))

(define (compiler-backend-emit-binop-with-rax-value
  [type-segment-bases : i64]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [rax-var : i64]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [store-result : bool]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (compiler-backend-rax-forwardable-binop?
    types
    (be_state.compiler-backend-global-shared-view global-types)
    assignments
    op
    lhs
    rhs
    ty)
    (let
      [operand-ty : compiler_ast_types.AstType
        (compiler-backend-binop-operand-ty
          types
          (be_state.compiler-backend-global-shared-view global-types)
          (be_state.compiler-backend-global-shared-view op)
          (be_state.compiler-backend-global-shared-view lhs)
          (be_state.compiler-backend-global-shared-view rhs)
          (be_state.compiler-backend-global-shared-view ty))]
      (if (be_operand.compiler-backend-branch-uses-var? lhs rax-var)
        (compiler-backend-emit-binop-rax-rhs
          type-segment-bases
          assignments
          dst
          (be_state.compiler-backend-global-shared-view op)
          (be_state.compiler-backend-global-shared-view rhs)
          (be_state.compiler-backend-global-shared-view operand-ty)
          ty
          store-result
          backend-state)
        (if (and
          (be_operand.compiler-backend-branch-uses-var? rhs rax-var)
          (be_operand.compiler-backend-commutative-binop? op))
          (compiler-backend-emit-binop-rax-rhs
            type-segment-bases
            assignments
            dst
            (be_state.compiler-backend-global-shared-view op)
            (be_state.compiler-backend-global-shared-view lhs)
            (be_state.compiler-backend-global-shared-view operand-ty)
            ty
            store-result
            backend-state)
          (compiler-backend-emit-binop
            type-segment-bases
            types
            global-types
            assignments
            dst
            op
            lhs
            rhs
            ty
            backend-state))))
    (compiler-backend-emit-binop
      type-segment-bases
      types
      global-types
      assignments
      dst
      op
      lhs
      rhs
      ty
      backend-state)))

(define (compiler-backend-emit-float-arith-return
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [fty : compiler_ast_types.AstType]
  [return-tail : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [rhs-operand : String
      (compiler-backend-float-direct-rhs-operand
        assignments
        (be_state.compiler-backend-global-shared-view rhs)
        fty
        "%xmm0"
        backend-state)]
    (if (not (string.eq rhs-operand ""))
      (let
        [lhs-asm
          (try
            (be_operand.compiler-backend-emit-load-float-value
              assignments
              lhs
              fty
              "%xmm0"
              backend-state))]
        (Ok
          (str_cat.str-cat
            lhs-asm
            "    "
            (compiler-backend-float-arith-mnemonic op)
            (compiler-backend-float-suffix fty)
            " "
            rhs-operand
            ", %xmm0\n"
            return-tail)))
      (let
        [lhs-reg : String
          (compiler-backend-float-value-register backend-state assignments lhs)]
        [exclude : (__tl_dyn-array String)
          (if (string.eq lhs-reg "")
            (__tl_make-array String 0)
            (be_operand.compiler-backend-one-exclude
              (be_state.compiler-backend-global-shared-view lhs-reg)))]
        [exclude-n : i64
          (if (string.eq lhs-reg "")
            0
            1)]
        [rhs-temp : String
          (be_operand.compiler-backend-scavenge-xmm-reg
            -1
            exclude
            exclude-n
            "%xmm2"
            backend-state)]
        [rhs-asm
          (try
            (be_operand.compiler-backend-emit-load-float-value
              assignments
              rhs
              fty
              (be_state.compiler-backend-global-shared-view rhs-temp)
              backend-state))]
        [lhs-asm
          (try
            (be_operand.compiler-backend-emit-load-float-value
              assignments
              lhs
              fty
              "%xmm0"
              backend-state))]
        (Ok
          (str_cat.str-cat
            rhs-asm
            lhs-asm
            "    "
            (compiler-backend-float-arith-mnemonic op)
            (compiler-backend-float-suffix fty)
            " "
            rhs-temp
            ", %xmm0\n"
            return-tail))))))

(define (compiler-backend-emit-float-compare-return
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [fty : compiler_ast_types.AstType]
  [return-tail : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (be_facts.compiler-backend-compare-op? op)
    (let
      [lhs-home : String
        (compiler-backend-float-value-register backend-state assignments lhs)]
      [rhs-direct : String
        (compiler-backend-float-direct-rhs-operand
          assignments
          (be_state.compiler-backend-global-shared-view rhs)
          fty
          lhs-home
          backend-state)]
      (if (and (not (string.eq lhs-home "")) (not (string.eq rhs-direct "")))
        (Ok
          (str_cat.str-cat
            (compiler-backend-float-compare-reg-asm
              op
              fty
              lhs-home
              rhs-direct
              "%rax")
            return-tail))
        (let
          [rhs-reg : String
            (compiler-backend-float-value-register
              backend-state
              assignments
              rhs)]
          [xmm-exclude : (__tl_dyn-array String)
            (if (string.eq rhs-reg "")
              (__tl_make-array String 0)
              (be_operand.compiler-backend-one-exclude
                (be_state.compiler-backend-global-shared-view rhs-reg)))]
          [xmm-exclude-n : i64
            (if (string.eq rhs-reg "")
              0
              1)]
          [lhs-temp : String
            (be_operand.compiler-backend-scavenge-xmm-reg
              -1
              xmm-exclude
              xmm-exclude-n
              "%xmm2"
              backend-state)]
          [rhs-operand : String
            (compiler-backend-float-direct-rhs-operand
              assignments
              (be_state.compiler-backend-global-shared-view rhs)
              fty
              lhs-temp
              backend-state)]
          (if (string.eq rhs-operand "")
            (let
              [rhs-temp-exclude0 : (__tl_dyn-array String)
                (be_operand.compiler-backend-one-exclude
                  (be_state.compiler-backend-global-shared-view lhs-temp))]
              [rhs-temp-exclude : (__tl_dyn-array String)
                (if (string.eq lhs-home "")
                  rhs-temp-exclude0
                  (be_operand.compiler-backend-scavenge-exclude-append
                    rhs-temp-exclude0
                    1
                    (be_state.compiler-backend-global-shared-view lhs-home)))]
              [rhs-temp-exclude-n : i64
                (if (string.eq lhs-home "")
                  1
                  2)]
              [rhs-temp : String
                (be_operand.compiler-backend-scavenge-xmm-reg
                  -1
                  rhs-temp-exclude
                  rhs-temp-exclude-n
                  "%xmm3"
                  backend-state)]
              [rhs-asm
                (try
                  (be_operand.compiler-backend-emit-load-float-value
                    assignments
                    rhs
                    fty
                    (be_state.compiler-backend-global-shared-view rhs-temp)
                    backend-state))]
              [lhs-asm
                (try
                  (be_operand.compiler-backend-emit-load-float-value
                    assignments
                    lhs
                    fty
                    (be_state.compiler-backend-global-shared-view lhs-temp)
                    backend-state))]
              (Ok
                (str_cat.str-cat
                  rhs-asm
                  lhs-asm
                  (compiler-backend-float-compare-reg-asm
                    op
                    fty
                    lhs-temp
                    rhs-temp
                    "%rax")
                  return-tail)))
            (let
              [lhs-asm
                (try
                  (be_operand.compiler-backend-emit-load-float-value
                    assignments
                    lhs
                    fty
                    (be_state.compiler-backend-global-shared-view lhs-temp)
                    backend-state))]
              (Ok
                (str_cat.str-cat
                  lhs-asm
                  (compiler-backend-float-compare-reg-asm
                    op
                    fty
                    lhs-temp
                    rhs-operand
                    "%rax")
                  return-tail)))))))
    (Err
      (box
        (compiler_diagnostic.compiler-diagnostic-at-start
          ""
          "backend: unsupported float return compare")))))

(define (compiler-backend-scavenge-binop-return-rhs-reg
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]) : String
  (let
    [rhs-home : String
      (be_facts.compiler-backend-value-register-home
        backend-state
        assignments
        rhs)]
    [lhs-home : String
      (be_facts.compiler-backend-value-register-home
        backend-state
        assignments
        lhs)]
    ;; A scalar compare only reads its RHS. If that value already has a
    ;; non-%rax register home, loading the LHS into the return accumulator
    ;; cannot destroy it and no staging scratch is needed. Besides avoiding a
    ;; redundant move, this keeps return fusion from demanding an unmodeled
    ;; scratch when two preceding casts were coalesced into %rax and RHS-home.
    [direct-compare-home? : bool
      (and
        (be_facts.compiler-backend-compare-op? op)
        (not (string.eq rhs-home ""))
        (not (string.eq rhs-home "%rax")))]
    [exclude : (__tl_dyn-array String)
      (be_operand.compiler-backend-scavenge-exclude-append
        (be_operand.compiler-backend-scavenge-exclude-append
          (compiler-backend-binop-scavenge-exclude-for-op op)
          5
          "%rax")
        6
        (be_state.compiler-backend-global-shared-view rhs-home))]
    (cond
      [direct-compare-home? rhs-home]
      [else
        (cond
          [(and
              (be_facts.compiler-backend-compare-op? op)
              (not (string.eq rhs-home "%rax"))
              (not (string.eq lhs-home ""))
              (not (string.eq lhs-home "%rax")))
            ;; Once the LHS is copied into the fixed return accumulator, its old
            ;; home is dead and can materialize a non-encodable RHS.
            lhs-home]
          [else
            (be_operand.compiler-backend-scavenge-reg-here
              exclude
              7
              "%r8"
              backend-state)])])))

(define (compiler-backend-emit-return-compare-frame-fallback
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [op : compiler_ir_types.CompilerIrBinOp]
  [rhs : compiler_ir_types.CompilerIrValue]
  [operand-ty : compiler_ast_types.AstType]
  [lhs-asm : String]
  [return-tail : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [rhs-home : String
      (be_facts.compiler-backend-value-register-home
        backend-state
        assignments
        rhs)]
    [frame : String
      (compiler-backend-cycle-temp-slot-with-backend-state backend-state 0)]
    (if (string.eq rhs-home "%rax")
      ;; Capture the RHS before lhs-asm overwrites the fixed accumulator.
      (Ok
        (str_cat.str-cat
          "    movq %rax, "
          frame
          "\n"
          lhs-asm
          (compiler-backend-binop-compare-set-reg-asm
            type-segment-bases
            op
            (be_state.compiler-backend-global-shared-view operand-ty)
            frame
            (be_operand.compiler-backend-sized-reg
              type-segment-bases
              "%rax"
              operand-ty)
            "%rax")
          return-tail))
      ;; Otherwise the RHS remains loadable after staging the LHS. Preserve the
      ;; LHS in memory, load RHS into %rax, and reverse the comparison.
      (let
        [rhs-asm
          (try
            (be_operand.compiler-backend-emit-load-value
              assignments
              rhs
              "%rax"
              backend-state))]
        (Ok
          (str_cat.str-cat
            lhs-asm
            "    movq %rax, "
            frame
            "\n"
            rhs-asm
            (let
              [op-2 (be_operand.compiler-backend-compare-swapped-op op)]
              (compiler-backend-binop-compare-set-reg-asm
                type-segment-bases
                op-2
                (be_state.compiler-backend-global-shared-view operand-ty)
                frame
                (be_operand.compiler-backend-sized-reg
                  type-segment-bases
                  "%rax"
                  operand-ty)
                "%rax"))
            return-tail))))))

(define (compiler-backend-emit-binop-return
  [type-segment-bases : i64]
  [backend-state : be_state.CompilerBackendState]
  [source-function : i64]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [types : compiler_regalloc.CompilerRegVarTypes]
  [global-types : be_state.CompilerBackendGlobalTypeTable]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]) : be_state.ResultCompilerBackend
  (let
    [return-tail : String
      (compiler-backend-return-tail
        backend-state
        source-function
        assignments
        vars
        blocks)]
    (if (compiler-backend-binop-f64?
      types
      (be_state.compiler-backend-global-shared-view global-types)
      lhs
      rhs
      ty)
      (let
        [fty : compiler_ast_types.AstType
          (compiler-backend-binop-operand-ty
            types
            global-types
            (be_state.compiler-backend-global-shared-view op)
            (be_state.compiler-backend-global-shared-view lhs)
            (be_state.compiler-backend-global-shared-view rhs)
            ty)]
        (if (compiler-backend-float-arith-op? op)
          (compiler-backend-emit-float-arith-return
            assignments
            op
            lhs
            rhs
            fty
            return-tail
            backend-state)
          (compiler-backend-emit-float-compare-return
            assignments
            op
            lhs
            rhs
            fty
            return-tail
            backend-state)))
      (let
        [operand-ty : compiler_ast_types.AstType
          (compiler-backend-binop-operand-ty
            types
            global-types
            (be_state.compiler-backend-global-shared-view op)
            (be_state.compiler-backend-global-shared-view lhs)
            (be_state.compiler-backend-global-shared-view rhs)
            ty)]
        (if (compiler-backend-signed-literal-divmod-src-shape?
          type-segment-bases
          op
          (be_state.compiler-backend-global-shared-view rhs)
          (be_state.compiler-backend-global-shared-view operand-ty))
          (let
            [asm
              (try
                (compiler-backend-emit-signed-literal-divmod-here
                  type-segment-bases
                  assignments
                  op
                  (be_state.compiler-backend-global-shared-view lhs)
                  rhs
                  operand-ty
                  backend-state))]
            (Ok (str_cat.str-cat asm return-tail)))
          (let
            [lhs-address : String
              (compiler-backend-value-scalar-memory-operand
                assignments
                (be_state.compiler-backend-global-shared-view lhs)
                backend-state)]
            [rhs-home : String
              (be_facts.compiler-backend-value-register-home
                backend-state
                assignments
                rhs)]
            [rhs-address : String
              (compiler-backend-value-scalar-memory-operand
                assignments
                (be_state.compiler-backend-global-shared-view rhs)
                backend-state)]
            [swap-return-compare? : bool
              (and
                (be_facts.compiler-backend-compare-op? op)
                (not (string.eq lhs-address ""))
                (string.eq rhs-home "")
                (string.eq rhs-address ""))]
            (if swap-return-compare?
              ;; When the LHS is already memory-addressable and a rematerialized
              ;; RHS has no home, stage the RHS in the fixed accumulator and
              ;; reverse the predicate.  This keeps the comparison within x86's
              ;; one-memory-operand constraint without another scratch.
              (let
                [rhs-asm
                  (try
                    (be_operand.compiler-backend-emit-load-value
                      assignments
                      rhs
                      "%rax"
                      backend-state))]
                (Ok
                  (str_cat.str-cat
                    rhs-asm
                    (let
                      [op-2 (be_operand.compiler-backend-compare-swapped-op op)]
                      (compiler-backend-binop-compare-set-reg-asm
                        type-segment-bases
                        op-2
                        (be_state.compiler-backend-global-shared-view
                          operand-ty)
                        lhs-address
                        (be_operand.compiler-backend-sized-reg
                          type-segment-bases
                          "%rax"
                          operand-ty)
                        "%rax"))
                    return-tail)))
              (let
                [lhs-asm
                  (try
                    (be_operand.compiler-backend-emit-load-value
                      assignments
                      lhs
                      "%rax"
                      backend-state))]
                (match (compiler-backend-binop-literal-divmod-asm-here
                  type-segment-bases
                  (be_state.compiler-backend-global-shared-view op)
                  (be_state.compiler-backend-global-shared-view rhs)
                  (be_state.compiler-backend-global-shared-view operand-ty)
                  backend-state)
                  [(Some op-asm)
                    (Ok (str_cat.str-cat lhs-asm op-asm return-tail))]
                  [(No)
                    (match (compiler-backend-immediate-operand-with-assignments
                      backend-state
                      assignments
                      (be_state.compiler-backend-global-shared-view rhs))
                      [(Some imm)
                        (match (compiler-backend-binop-immediate-asm
                          type-segment-bases
                          (be_state.compiler-backend-global-shared-view op)
                          imm
                          (be_state.compiler-backend-global-shared-view
                            operand-ty)
                          "%rax"
                          "%rax"
                          (compiler-backend-value-integer-zero-with-assignments?
                            backend-state
                            assignments
                            (be_state.compiler-backend-global-shared-view rhs)))
                          [(Some op-asm)
                            (Ok (str_cat.str-cat lhs-asm op-asm return-tail))]
                          [(No)
                            (let
                              [rhs-reg : String
                                (compiler-backend-scavenge-binop-return-rhs-reg
                                  backend-state
                                  assignments
                                  (be_state.compiler-backend-global-shared-view
                                    op)
                                  (be_state.compiler-backend-global-shared-view
                                    lhs)
                                  (be_state.compiler-backend-global-shared-view
                                    rhs))]
                              [rhs-frame? : bool
                                (string.eq rhs-reg "@return-rhs-frame")]
                              [rhs-operand : String
                                (if rhs-frame?
                                  (compiler-backend-cycle-temp-slot-with-backend-state
                                    backend-state
                                    0)
                                  (owned_view.compiler-owned-shared-view
                                    rhs-reg))]
                              (if rhs-frame?
                                (compiler-backend-emit-return-compare-frame-fallback
                                  type-segment-bases
                                  assignments
                                  (be_state.compiler-backend-global-shared-view
                                    op)
                                  (be_state.compiler-backend-global-shared-view
                                    rhs)
                                  operand-ty
                                  lhs-asm
                                  return-tail
                                  backend-state)
                                (let
                                  [rhs-asm
                                    (try
                                      (be_operand.compiler-backend-emit-load-value
                                        assignments
                                        rhs
                                        (be_state.compiler-backend-global-shared-view
                                          rhs-reg)
                                        backend-state))]
                                  ;; %rax-pool: load rhs (into rhs-reg, which the
                                  ;; reserved-set scavenge keeps != lhs-home and !=
                                  ;; %rax) BEFORE lhs->%rax, so an rhs homed in %rax
                                  ;; is captured before the lhs staging overwrites it.
                                  (Ok
                                    (str_cat.str-cat
                                      (if (and
                                        (not
                                          (string.eq
                                            (be_facts.compiler-backend-value-register-home
                                              backend-state
                                              assignments
                                              lhs)
                                            ""))
                                        (string.eq
                                          (be_facts.compiler-backend-value-register-home
                                            backend-state
                                            assignments
                                            lhs)
                                          rhs-reg))
                                        (owned_view.compiler-owned-shared-view
                                          lhs-asm)
                                        (owned_view.compiler-owned-shared-view
                                          rhs-asm))
                                      (if (and
                                        (not
                                          (string.eq
                                            (be_facts.compiler-backend-value-register-home
                                              backend-state
                                              assignments
                                              lhs)
                                            ""))
                                        (string.eq
                                          (be_facts.compiler-backend-value-register-home
                                            backend-state
                                            assignments
                                            lhs)
                                          rhs-reg))
                                        rhs-asm
                                        lhs-asm)
                                      (compiler-backend-binop-asm
                                        type-segment-bases
                                        (be_state.compiler-backend-global-shared-view
                                          op)
                                        operand-ty
                                        rhs-operand
                                        "%rax"
                                        ""
                                        ""
                                        backend-state)
                                      return-tail)))))])]
                      [(No)
                        (let
                          [rhs-address : String
                            (compiler-backend-value-scalar-memory-operand
                              assignments
                              (be_state.compiler-backend-global-shared-view rhs)
                              backend-state)]
                          (if (and
                            (be_facts.compiler-backend-compare-op? op)
                            (not (string.eq rhs-address "")))
                            ;; x86 comparisons accept a memory source. The LHS
                            ;; is already in %rax, so staging a spilled RHS would
                            ;; add a move and consume a scratch slot for no reason.
                            (Ok
                              (str_cat.str-cat
                                lhs-asm
                                (compiler-backend-binop-compare-set-reg-asm
                                  type-segment-bases
                                  op
                                  (be_state.compiler-backend-global-shared-view
                                    operand-ty)
                                  rhs-address
                                  (be_operand.compiler-backend-sized-reg
                                    type-segment-bases
                                    "%rax"
                                    operand-ty)
                                  "%rax")
                                return-tail))
                            (let
                              [rhs-reg : String
                                (compiler-backend-scavenge-binop-return-rhs-reg
                                  backend-state
                                  assignments
                                  (be_state.compiler-backend-global-shared-view
                                    op)
                                  (be_state.compiler-backend-global-shared-view
                                    lhs)
                                  (be_state.compiler-backend-global-shared-view
                                    rhs))]
                              [rhs-frame? : bool
                                (string.eq rhs-reg "@return-rhs-frame")]
                              [rhs-operand : String
                                (if rhs-frame?
                                  (compiler-backend-cycle-temp-slot-with-backend-state
                                    backend-state
                                    0)
                                  (owned_view.compiler-owned-shared-view
                                    rhs-reg))]
                              (if rhs-frame?
                                (compiler-backend-emit-return-compare-frame-fallback
                                  type-segment-bases
                                  assignments
                                  op
                                  rhs
                                  operand-ty
                                  lhs-asm
                                  return-tail
                                  backend-state)
                                (let
                                  [rhs-asm
                                    (try
                                      (be_operand.compiler-backend-emit-load-value
                                        assignments
                                        rhs
                                        (be_state.compiler-backend-global-shared-view
                                          rhs-reg)
                                        backend-state))]
                                  ;; %rax-pool: load rhs before lhs->%rax (see above).
                                  (Ok
                                    (str_cat.str-cat
                                      (if (and
                                        (not
                                          (string.eq
                                            (be_facts.compiler-backend-value-register-home
                                              backend-state
                                              assignments
                                              lhs)
                                            ""))
                                        (string.eq
                                          (be_facts.compiler-backend-value-register-home
                                            backend-state
                                            assignments
                                            lhs)
                                          rhs-reg))
                                        (owned_view.compiler-owned-shared-view
                                          lhs-asm)
                                        (owned_view.compiler-owned-shared-view
                                          rhs-asm))
                                      (if (and
                                        (not
                                          (string.eq
                                            (be_facts.compiler-backend-value-register-home
                                              backend-state
                                              assignments
                                              lhs)
                                            ""))
                                        (string.eq
                                          (be_facts.compiler-backend-value-register-home
                                            backend-state
                                            assignments
                                            lhs)
                                          rhs-reg))
                                        rhs-asm
                                        lhs-asm)
                                      (compiler-backend-binop-asm
                                        type-segment-bases
                                        op
                                        operand-ty
                                        rhs-operand
                                        "%rax"
                                        ""
                                        ""
                                        backend-state)
                                      return-tail)))))))])])))))))))

(define (compiler-backend-jump-label [function : String] [label : i64]) : String
  (str_cat.str-cat
    "    jmp "
    (be_operand.compiler-backend-asm-label function label)
    "\n"
    ""))

(define (compiler-backend-jump-target-is-fallthrough?
  [target : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]) : bool
  (match fallthrough
    [(Some label) (= target label)]
    [(No) false]))

;; #jump-forward: the label a jump-only block hands its incoming jumps on to,
;; or `label` itself when the block is not jump-only. `pairs` is the flat
;; (from, to) table built once per function; `count` is its pair count.
(define (compiler-backend-jump-forward-pair-lookup
  [pairs : (& pairs (__tl_dyn-array i64))]
  [count : i64]
  [label : i64]) : i64
  (let
    [i : i64 0]
    [out : i64 label]
    (while (< i count)
      (if (= (array-ref pairs (* 2 i)) label)
        (begin
          (set! out (array-ref pairs (+ (* 2 i) 1)))
          (set! i count))
        (+= i 1)))
    out))

(define (compiler-backend-jump-forward-lookup
  [backend-state : be_state.CompilerBackendState]
  [label : i64]) : i64
  (let
    [pairs : (__tl_dyn-array i64)
      (be_state.compiler-backend-function-state-i64-array
        (be_state.compiler-backend-state-function-state backend-state)
        be_state.compiler-backend-function-i64-array-jump-forward)]
    (compiler-backend-jump-forward-pair-lookup
      pairs
      (/ (array-length pairs) 2)
      label)))

;; #jump-forward: the label a jump at this site should name. A target that is
;; already the fallthrough is left alone -- eliding the jump and letting the
;; block's own (equally forwarded) terminator run is never worse, and is
;; strictly better when that terminator is itself elided.
(define (compiler-backend-jump-resolve-target
  [backend-state : be_state.CompilerBackendState]
  [target : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]) : i64
  (if (compiler-backend-jump-target-is-fallthrough? target fallthrough)
    target
    (compiler-backend-jump-forward-lookup backend-state target)))

;; #jump-forward drift rail: a block admitted to the forwarding table must emit
;; nothing but its jump. If its own phi-edge copies turn out non-empty after
;; all, jumps that skipped past it would skip those copies, so fail the compile
;; loudly instead of emitting wrong code.
(define (compiler-backend-jump-forward-drift?
  [backend-state : be_state.CompilerBackendState]
  [label : i64]
  [copies : (& copies str)]) : bool
  (if (string.eq copies "")
    false
    (not (= (compiler-backend-jump-forward-lookup backend-state label) label))))

(define (compiler-backend-emit-branch-jumps
  [function : String]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [backend-state : be_state.CompilerBackendState]) : String
  ;; Flush any pending emergency restore inline (after the test, before the jumps)
  ;; -- flag-safe and on a reachable path for both edges.
  ;; jumps-asm bound to a local (behavior-neutral) to avoid a seed-typechecker
  ;; spurious mismatch on the enclosing append operand.
  (let
    [true-target : i64
      (compiler-backend-jump-resolve-target
        backend-state
        true-label
        fallthrough)]
    [false-target : i64
      (compiler-backend-jump-resolve-target
        backend-state
        false-label
        fallthrough)]
    [jumps-asm : String
      (if (compiler-backend-jump-target-is-fallthrough?
        false-target
        fallthrough)
        (str_cat.str-cat
          "    jne "
          (be_operand.compiler-backend-asm-label function true-target)
          "\n"
          "")
        (if (compiler-backend-jump-target-is-fallthrough?
          true-target
          fallthrough)
          (str_cat.str-cat
            "    je "
            (be_operand.compiler-backend-asm-label function false-target)
            "\n"
            "")
          (str_cat.str-cat
            "    jne "
            (be_operand.compiler-backend-asm-label
              (be_state.compiler-backend-global-shared-view function)
              true-label)
            "\n    jmp "
            (be_operand.compiler-backend-asm-label function false-target)
            "\n")))]
    (str_cat.str-cat
      (compiler-backend-emergency-restore-before-jumps backend-state)
      jumps-asm)))

(define (compiler-backend-emit-load-test-branch
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [function : String]
  [cond : compiler_ir_types.CompilerIrValue]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [test-reg : String
      (be_operand.compiler-backend-scavenge-reg-here
        (compiler-backend-binop-scavenge-exclude-build)
        5
        "%rax"
        backend-state)]
    [load
      (try
        (be_operand.compiler-backend-emit-load-value
          assignments
          cond
          (be_state.compiler-backend-global-shared-view test-reg)
          backend-state))]
    (Ok
      (str_cat.str-cat
        load
        (str_cat.str-cat "    testq " test-reg ", " test-reg "\n")
        (compiler-backend-emit-branch-jumps
          function
          true-label
          false-label
          fallthrough
          backend-state)))))

(define (compiler-backend-emit-branch
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [function : String]
  [cond : compiler_ir_types.CompilerIrValue]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match (& cond)
    [(Bool b)
      (let
        [taken : i64
          (compiler-backend-jump-resolve-target
            backend-state
            (if b
              true-label
              false-label)
            fallthrough)]
        (Ok
          (if (compiler-backend-jump-target-is-fallthrough? taken fallthrough)
            ""
            (compiler-backend-jump-label function taken))))]
    [(Var id)
      (let
        [test-asm : String
          (be_operand.compiler-backend-branch-test-var-asm
            assignments
            id
            backend-state)]
        (if (string.eq test-asm "")
          (compiler-backend-emit-load-test-branch
            assignments
            function
            cond
            true-label
            false-label
            fallthrough
            backend-state)
          (Ok
            (str_cat.str-cat
              test-asm
              (compiler-backend-emit-branch-jumps
                function
                true-label
                false-label
                fallthrough
                backend-state)))))]
    [_
      (match (be_operand.compiler-backend-value-as-i64 cond)
        [(Some value)
          (compiler-backend-emit-branch
            assignments
            function
            (Bool (not (= value 0)))
            true-label
            false-label
            fallthrough
            backend-state)]
        [(None)
          (let
            [test-reg : String
              (be_operand.compiler-backend-scavenge-reg-here
                (compiler-backend-binop-scavenge-exclude-build)
                5
                "%rax"
                backend-state)]
            [load
              (try
                (be_operand.compiler-backend-emit-load-value
                  assignments
                  cond
                  (be_state.compiler-backend-global-shared-view test-reg)
                  backend-state))]
            (Ok
              (str_cat.str-cat
                load
                (str_cat.str-cat "    testq " test-reg ", " test-reg "\n")
                ;; Non-scalar conditions can emergency-borrow an occupied
                ;; register while materializing the value. Flush that
                ;; restore after `testq` and before either edge, just like
                ;; the Var/fallback paths above; appending it after the
                ;; conditional jump restores only the fallthrough edge.
                (compiler-backend-emit-branch-jumps
                  function
                  true-label
                  false-label
                  fallthrough
                  backend-state))))])]))

(define (compiler-backend-divmod-op?
  [op : (& op compiler_ir_types.CompilerIrBinOp)]) : bool
  (match op
    [(or (Div) (Mod) (SafeDiv) (SafeMod)) true]
    [_ false]))

(define (compiler-backend-compare-true-jcc
  [type-segment-bases : i64]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [ty : (& compiler_ast_types.AstType)]) : String
  (match op
    [(or (Eq) (BitTestEq)) "je"]
    [(or (Ne) (BitTestNe)) "jne"]
    [(Lt)
      (if (be_operand.compiler-backend-unsigned-rel-ty? type-segment-bases ty)
        "jb"
        "jl")]
    [(Le)
      (if (be_operand.compiler-backend-unsigned-rel-ty? type-segment-bases ty)
        "jbe"
        "jle")]
    [(Gt)
      (if (be_operand.compiler-backend-unsigned-rel-ty? type-segment-bases ty)
        "ja"
        "jg")]
    [(Ge)
      (if (be_operand.compiler-backend-unsigned-rel-ty? type-segment-bases ty)
        "jae"
        "jge")]
    [_ ""]))

(define (compiler-backend-compare-false-jcc
  [type-segment-bases : i64]
  [op : (& op compiler_ir_types.CompilerIrBinOp)]
  [ty : (& compiler_ast_types.AstType)]) : String
  (match op
    [(or (Eq) (BitTestEq)) "jne"]
    [(or (Ne) (BitTestNe)) "je"]
    [(Lt)
      (if (be_operand.compiler-backend-unsigned-rel-ty? type-segment-bases ty)
        "jae"
        "jge")]
    [(Le)
      (if (be_operand.compiler-backend-unsigned-rel-ty? type-segment-bases ty)
        "ja"
        "jg")]
    [(Gt)
      (if (be_operand.compiler-backend-unsigned-rel-ty? type-segment-bases ty)
        "jbe"
        "jle")]
    [(Ge)
      (if (be_operand.compiler-backend-unsigned-rel-ty? type-segment-bases ty)
        "jb"
        "jl")]
    [_ ""]))

(define (compiler-backend-emit-jcc-label
  [jcc : String]
  [function : String]
  [label : i64]) : String
  (str_cat.str-cat
    "    "
    jcc
    " "
    (be_operand.compiler-backend-asm-label function label)
    "\n"))

(define (compiler-backend-emit-compare-branch-jumps
  [function : String]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [true-jcc : String]
  [false-jcc : String]
  [backend-state : be_state.CompilerBackendState]) : String
  ;; Flush any pending emergency restore inline (after the compare, before the
  ;; jumps) -- flag-safe and on a reachable path for both edges.
  ;; jumps-asm bound to a local (behavior-neutral) to avoid a seed-typechecker
  ;; spurious mismatch on the enclosing append operand.
  (let
    [true-target : i64
      (compiler-backend-jump-resolve-target
        backend-state
        true-label
        fallthrough)]
    [false-target : i64
      (compiler-backend-jump-resolve-target
        backend-state
        false-label
        fallthrough)]
    [jumps-asm : String
      (if (compiler-backend-jump-target-is-fallthrough?
        false-target
        fallthrough)
        (compiler-backend-emit-jcc-label true-jcc function true-target)
        (if (compiler-backend-jump-target-is-fallthrough?
          true-target
          fallthrough)
          (compiler-backend-emit-jcc-label false-jcc function false-target)
          (str_cat.str-cat
            (compiler-backend-emit-jcc-label
              true-jcc
              (be_state.compiler-backend-global-shared-view function)
              true-label)
            (compiler-backend-jump-label function false-label))))]
    (str_cat.str-cat
      (compiler-backend-emergency-restore-before-jumps backend-state)
      jumps-asm)))

(define (compiler-backend-emit-compare-operand-flags
  [type-segment-bases : i64]
  [op : compiler_ir_types.CompilerIrBinOp]
  [rhs : String]
  [lhs : String]
  [ty : compiler_ast_types.AstType]
  [rhs-zero? : bool]
  [lhs-register? : bool]) : String
  (if (be_facts.compiler-backend-bit-test-op? op)
    (compiler-backend-binop-reg-asm type-segment-bases "test" ty rhs lhs)
    (if (and rhs-zero? (be_facts.compiler-backend-compare-uses-zero-test? op))
      (if lhs-register?
        (compiler-backend-binop-reg-asm
          type-segment-bases
          "test"
          ty
          (be_state.compiler-backend-global-shared-view lhs)
          lhs)
        (str_cat.str-cat
          "    cmp"
          (be_operand.compiler-backend-int-instruction-suffix
            type-segment-bases
            ty)
          " $0, "
          lhs
          "\n"))
      (str_cat.str-cat
        (str_cat.str-cat
          "    cmp"
          (be_operand.compiler-backend-int-instruction-suffix
            type-segment-bases
            ty)
          " "
          rhs
          ", ")
        (str_cat.str-cat lhs "\n" "")))))

(define (compiler-backend-compare-rhs-scavenge-exclude [lhs-reg : String]) : (__tl_dyn-array
    String)
  (if (string.eq lhs-reg "")
    (compiler-backend-binop-scavenge-exclude-build)
    (be_operand.compiler-backend-scavenge-exclude-append
      (compiler-backend-binop-scavenge-exclude-build)
      5
      lhs-reg)))

(define (compiler-backend-compare-rhs-scavenge-exclude-n [lhs-reg : String]) : i64
  (if (string.eq lhs-reg "")
    5
    6))

(define (compiler-backend-emit-compare-branch-with-lhs-operand
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [function : String]
  [op : compiler_ir_types.CompilerIrBinOp]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [true-jcc : String]
  [false-jcc : String]
  [lhs-asm : String]
  [lhs-operand : String]
  [lhs-register? : bool]
  [lhs-reg : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match (be_operand.compiler-backend-immediate-operand backend-state rhs)
    [(Some imm)
      (Ok
        (str_cat.str-cat
          lhs-asm
          (compiler-backend-emit-compare-operand-flags
            type-segment-bases
            op
            imm
            lhs-operand
            ty
            (compiler-backend-value-integer-zero? rhs)
            lhs-register?)
          (compiler-backend-emit-compare-branch-jumps
            function
            true-label
            false-label
            fallthrough
            true-jcc
            false-jcc
            backend-state)))]
    [(No)
      (let
        [rhs-home : String
          (be_operand.compiler-backend-value-scalar-register-home
            backend-state
            assignments
            rhs)]
        (if (not (string.eq rhs-home ""))
          (Ok
            (str_cat.str-cat
              lhs-asm
              (compiler-backend-emit-compare-operand-flags
                type-segment-bases
                op
                (be_operand.compiler-backend-sized-reg
                  type-segment-bases
                  rhs-home
                  (be_state.compiler-backend-global-shared-view ty))
                lhs-operand
                ty
                false
                lhs-register?)
              (compiler-backend-emit-compare-branch-jumps
                function
                true-label
                false-label
                fallthrough
                true-jcc
                false-jcc
                backend-state)))
          ;; M6-F: a scalar-memory rhs is already a legal `cmp` SOURCE operand
          ;; whenever the lhs occupies the destination slot as a register --
          ;; `cmpq SLOT, %r` -- so the reload the scavenge path emits below is
          ;; pure overhead. This is the mirror of the lhs-address arm in
          ;; compiler-backend-emit-compare-branch, which has spelled a
          ;; spilled LHS straight into the destination slot all along; between
          ;; them exactly one operand is ever memory, which is all x86 allows.
          ;;
          ;; Restricted to a register lhs-operand for that reason, and to
          ;; non-bit-test ops because `test` renders its operands through
          ;; compiler-backend-binop-reg-asm, which sizes REGISTER spellings.
          ;; Narrow widths are fine: `cmp<w> SLOT, %r<w>` reads the low w bytes
          ;; of the slot, exactly what reloading the slot and comparing the
          ;; sized register did. Nothing between lhs-asm and the compare moves
          ;; %rsp -- emergency saves write fixed slots, never push -- which is
          ;; the same assumption the lhs-address arm already runs on.
          (let
            ;; M6-I extends this arm from a frame slot to a scalar GLOBAL read:
            ;; `cmpq g(%rip), %r` replaces `movq g(%rip), %scratch ; cmpq
            ;; %scratch, %r`, on the same terms -- the lhs holds the
            ;; destination slot as a register, so the compare still names
            ;; exactly one memory operand.
            [rhs-address : String
              (compiler-backend-compare-memory-operand
                type-segment-bases
                assignments
                (be_state.compiler-backend-global-shared-view rhs)
                (be_state.compiler-backend-global-shared-view ty)
                backend-state)]
            (if (and
              lhs-register?
              (not (string.eq rhs-address ""))
              (not (be_facts.compiler-backend-bit-test-op? op)))
              (Ok
                (str_cat.str-cat
                  lhs-asm
                  (compiler-backend-emit-compare-operand-flags
                    type-segment-bases
                    op
                    rhs-address
                    lhs-operand
                    ty
                    false
                    lhs-register?)
                  (compiler-backend-emit-compare-branch-jumps
                    function
                    true-label
                    false-label
                    fallthrough
                    true-jcc
                    false-jcc
                    backend-state)))
              (compiler-backend-emit-compare-branch-staged-rhs
                type-segment-bases
                assignments
                function
                rhs
                ty
                true-label
                false-label
                fallthrough
                true-jcc
                false-jcc
                lhs-asm
                lhs-operand
                lhs-register?
                lhs-reg
                op
                backend-state)))))]))

(define (compiler-backend-emit-compare-branch-staged-rhs
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [function : String]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [true-jcc : String]
  [false-jcc : String]
  [lhs-asm : String]
  [lhs-operand : String]
  [lhs-register? : bool]
  [lhs-reg : String]
  [op : compiler_ir_types.CompilerIrBinOp]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [rhs-reg : String
      (be_operand.compiler-backend-scavenge-reg-here
        (compiler-backend-compare-rhs-scavenge-exclude
          (be_state.compiler-backend-global-shared-view lhs-reg))
        (compiler-backend-compare-rhs-scavenge-exclude-n lhs-reg)
        "%r8"
        backend-state)]
    [rhs-asm
      (try
        (be_operand.compiler-backend-emit-load-value
          assignments
          rhs
          (be_state.compiler-backend-global-shared-view rhs-reg)
          backend-state))]
    (Ok
      (str_cat.str-cat
        lhs-asm
        rhs-asm
        (compiler-backend-emit-compare-operand-flags
          type-segment-bases
          op
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            rhs-reg
            (be_state.compiler-backend-global-shared-view ty))
          lhs-operand
          ty
          false
          lhs-register?)
        (compiler-backend-emit-compare-branch-jumps
          function
          true-label
          false-label
          fallthrough
          true-jcc
          false-jcc
          backend-state)))))

(define (compiler-backend-emit-float-compare-branch-jumps
  [function : String]
  [op : compiler_ir_types.CompilerIrBinOp]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [equal? : bool
      (match (& op)
        [(Eq) true]
        [_ false])]
    [check-parity? : bool
      (match (& op)
        [(or (Eq) (Ne)) true]
        [_ false])]
    [unordered-target : i64
      (if equal?
        false-label
        true-label)]
    [unordered-falls? : bool
      (and
        check-parity?
        (compiler-backend-jump-target-is-fallthrough?
          unordered-target
          fallthrough))]
    ;; Unordered sets CF, ZF and PF. JA/JAE therefore already reject it
    ;; and their complements accept it. JE/JNE need the parity check first.
    [true-jcc : String
      (match (& op)
        [(Eq) "je"]
        [(Ne) "jne"]
        [(Ge) "jae"]
        [_ "ja"])]
    [false-jcc : String
      (match (& op)
        [(Eq) "jne"]
        [(Ne) "je"]
        [(Ge) "jb"]
        [_ "jbe"])]
    [restore : String
      (compiler-backend-emergency-restore-before-jumps backend-state)]
    [parity : String
      (cond
        [unordered-falls? "    jp 1f\n"]
        [check-parity?
          (compiler-backend-emit-jcc-label
            "jp"
            (be_state.compiler-backend-global-shared-view function)
            (compiler-backend-jump-resolve-target
              backend-state
              unordered-target
              fallthrough))]
        [else ""])]
    (str_cat.str-cat
      restore
      parity
      (compiler-backend-emit-compare-branch-jumps
        function
        true-label
        false-label
        fallthrough
        true-jcc
        false-jcc
        backend-state)
      (if unordered-falls?
        "1:\n"
        ""))))

(define (compiler-backend-emit-float-compare-branch
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [function : String]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [swap? : bool
      (match (& op)
        [(or (Lt) (Le)) true]
        [_ false])]
    [predicate : compiler_ir_types.CompilerIrBinOp
      (if swap?
        (be_operand.compiler-backend-compare-swapped-op op)
        op)]
    (match (if swap?
      (tuple rhs lhs)
      (tuple lhs rhs))
      [(tuple left right)
        (let
          [right-operand : String
            (compiler-backend-float-direct-rhs-operand
              assignments
              right
              ty
              ""
              backend-state)]
          [left-home : String
            (compiler-backend-float-value-register
              backend-state
              assignments
              left)]
          [left-reg : String
            (if (string.eq left-home "")
              (be_operand.compiler-backend-scavenge-xmm-reg-for-staging
                -1
                (be_operand.compiler-backend-one-exclude
                  (string.copy (& right-operand)))
                1
                "%xmm2"
                true
                backend-state)
              left-home)]
          [load : String
            (try
              (be_operand.compiler-backend-emit-load-float-value
                assignments
                left
                ty
                (be_state.compiler-backend-global-shared-view left-reg)
                backend-state))]
          (Ok
            (str_cat.str-cat
              load
              (compiler-backend-float-compare-flags ty left-reg right-operand)
              (compiler-backend-emit-float-compare-branch-jumps
                function
                predicate
                true-label
                false-label
                fallthrough
                backend-state))))])))

(define (compiler-backend-emit-compare-branch
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [function : String]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (be_operand.compiler-backend-float-type? ty)
    (compiler-backend-emit-float-compare-branch
      assignments
      function
      op
      lhs
      rhs
      ty
      true-label
      false-label
      fallthrough
      backend-state)
    (compiler-backend-emit-int-compare-branch
      type-segment-bases
      assignments
      function
      op
      lhs
      rhs
      ty
      true-label
      false-label
      fallthrough
      backend-state)))

(define (compiler-backend-emit-int-compare-branch
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [function : String]
  [op : compiler_ir_types.CompilerIrBinOp]
  [lhs : compiler_ir_types.CompilerIrValue]
  [rhs : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [true-jcc : String
      (compiler-backend-compare-true-jcc type-segment-bases op ty)]
    [false-jcc : String
      (compiler-backend-compare-false-jcc type-segment-bases op ty)]
    ;; An immediate LHS can compare directly against a scalar RHS home below.
    ;; Preserve that home so no scratch can overwrite it before the compare.
    [rhs-home : String
      (be_operand.compiler-backend-value-scalar-register-home
        backend-state
        assignments
        rhs)]
    [swapped-op : compiler_ir_types.CompilerIrBinOp
      (be_operand.compiler-backend-compare-swapped-op
        (be_state.compiler-backend-global-shared-view op))]
    [swapped-true-jcc : String
      (compiler-backend-compare-true-jcc type-segment-bases swapped-op ty)]
    [swapped-false-jcc : String
      (compiler-backend-compare-false-jcc type-segment-bases swapped-op ty)]
    ;; Compare/branch fusion does not materialize the comparison result. When
    ;; the ordinary plan has no dedicated RHS slot, its result staging home is
    ;; therefore free and can stage a non-encodable RHS instead.
    (if (string.eq true-jcc "")
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            "backend: unsupported compare branch")))
      (let
        [lhs-home : String
          (be_operand.compiler-backend-value-scalar-register-home
            backend-state
            assignments
            lhs)]
        ;; M6-I: a scalar GLOBAL read is a legal compare DESTINATION operand
        ;; too, exactly as a spilled lhs already was -- but only when the OTHER
        ;; operand needs no staging register of its own.
        ;;
        ;; A spilled rhs reaches the compare as its memory operand once the
        ;; lhs is staged. Spelling the global into the destination slot instead
        ;; would leave that spilled rhs needing a stage of its own. So the arm
        ;; is admitted only for an immediate or register-homed rhs -- exactly
        ;; the cases that consume no scratch at all. Every other rhs keeps the
        ;; pre-M6-I shape.
        [rhs-needs-no-stage? : bool
          (or
            (not (string.eq rhs-home ""))
            (match (be_operand.compiler-backend-immediate-operand
              backend-state
              rhs)
              [(Some _) true]
              [(No) false]))]
        [lhs-address : String
          (let
            [stack : String
              (be_operand.compiler-backend-value-stack-address
                assignments
                (be_state.compiler-backend-global-shared-view lhs)
                backend-state)]
            (if (string.eq stack "")
              (if rhs-needs-no-stage?
                (compiler-backend-value-global-memory-operand
                  backend-state
                  type-segment-bases
                  (be_state.compiler-backend-global-shared-view lhs)
                  (be_state.compiler-backend-global-shared-view ty))
                "")
              stack))]
        [lhs-immediate? : bool
          (match (be_operand.compiler-backend-immediate-operand
            backend-state
            lhs)
            [(Some _) true]
            [(No) false])]
        (cond
          [(and lhs-immediate? (not (string.eq rhs-home "")))
            ;; `imm op rhs-reg` becomes `rhs-reg swapped-op imm`, avoiding a
            ;; scratch entirely. This is both smaller and protects the RHS home
            ;; through the branch compare.
            (compiler-backend-emit-compare-branch-with-lhs-operand
              type-segment-bases
              assignments
              function
              swapped-op
              lhs
              (be_state.compiler-backend-global-shared-view ty)
              true-label
              false-label
              fallthrough
              swapped-true-jcc
              swapped-false-jcc
              ""
              (be_operand.compiler-backend-sized-reg
                type-segment-bases
                (be_state.compiler-backend-global-shared-view rhs-home)
                ty)
              true
              rhs-home
              backend-state)]
          [(not (string.eq lhs-home ""))
            (compiler-backend-emit-compare-branch-with-lhs-operand
              type-segment-bases
              assignments
              function
              op
              rhs
              (be_state.compiler-backend-global-shared-view ty)
              true-label
              false-label
              fallthrough
              true-jcc
              false-jcc
              ""
              (be_operand.compiler-backend-sized-reg
                type-segment-bases
                (be_state.compiler-backend-global-shared-view lhs-home)
                ty)
              true
              lhs-home
              backend-state)]
          [(not (string.eq lhs-address ""))
            (compiler-backend-emit-compare-branch-with-lhs-operand
              type-segment-bases
              assignments
              function
              op
              rhs
              ty
              true-label
              false-label
              fallthrough
              true-jcc
              false-jcc
              ""
              lhs-address
              false
              ""
              backend-state)]
          [else
            (let
              [lhs-stage : String
                (be_operand.compiler-backend-scavenge-reg-here
                  (compiler-backend-binop-scavenge-exclude-build)
                  5
                  "%rax"
                  backend-state)]
              [lhs-asm
                (try
                  (be_operand.compiler-backend-emit-load-value
                    assignments
                    lhs
                    (be_state.compiler-backend-global-shared-view lhs-stage)
                    backend-state))]
              (compiler-backend-emit-compare-branch-with-lhs-operand
                type-segment-bases
                assignments
                function
                op
                rhs
                (be_state.compiler-backend-global-shared-view ty)
                true-label
                false-label
                fallthrough
                true-jcc
                false-jcc
                lhs-asm
                (be_operand.compiler-backend-sized-reg
                  type-segment-bases
                  (be_state.compiler-backend-global-shared-view lhs-stage)
                  ty)
                true
                lhs-stage
                backend-state))])))))

(define (compiler-backend-emit-compare-memory-address-flags
  [op : (& compiler_ir_types.CompilerIrBinOp)]
  [rhs : String]
  [addr : String]) : String
  ;; Bit-test operators need TEST semantics ((x & rhs) ==/!= 0); CMP would be
  ;; an equality test (x == rhs). The register compare path already selects
  ;; `test` for these (compiler-backend-binop-compare-flags-reg-asm); the
  ;; memory-operand fusions select it here. The jcc tables need no change:
  ;; test sets ZF from the AND result exactly where cmp sets it from the
  ;; subtraction result, and je/jne keep their meaning.
  (str_cat.str-cat
    "    "
    (if (be_facts.compiler-backend-bit-test-op? op)
      "testq "
      "cmpq ")
    rhs
    ", "
    addr
    "\n"))

(define (compiler-backend-emit-compare-memory-flags
  [op : (& compiler_ir_types.CompilerIrBinOp)]
  [rhs : String]
  [base : String]) : String
  (compiler-backend-emit-compare-memory-address-flags
    op
    rhs
    (be_facts.compiler-backend-copy-address 0 base)))

(define (compiler-backend-emit-load-compare-branch
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [function : String]
  [ptr : compiler_ir_types.CompilerIrValue]
  [op : (& compiler_ir_types.CompilerIrBinOp)]
  [rhs : (& compiler_ir_types.CompilerIrValue)]
  [ty : compiler_ast_types.AstType]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [true-jcc : String
      (compiler-backend-compare-true-jcc type-segment-bases op ty)]
    [false-jcc : String
      (compiler-backend-compare-false-jcc type-segment-bases op ty)]
    (if (string.eq true-jcc "")
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            "backend: unsupported load compare branch")))
      (let
        [base-home : String
          (be_facts.compiler-backend-address-base-filter-direct
            (be_operand.compiler-backend-value-scalar-register
              backend-state
              assignments
              ptr))]
        [scav-base : String
          (if (string.eq base-home "")
            (be_operand.compiler-backend-scavenge-reg-here
              (compiler-backend-binop-scavenge-exclude-build)
              5
              "%r10"
              backend-state)
            base-home)]
        [ptr-asm
          (try
            (be_operand.compiler-backend-emit-load-value
              assignments
              ptr
              (be_state.compiler-backend-global-shared-view scav-base)
              backend-state))]
        (match (be_operand.compiler-backend-immediate-operand backend-state rhs)
          [(Some imm)
            (Ok
              (str_cat.str-cat
                ptr-asm
                (compiler-backend-emit-compare-memory-flags op imm scav-base)
                (compiler-backend-emit-compare-branch-jumps
                  function
                  true-label
                  false-label
                  fallthrough
                  true-jcc
                  false-jcc
                  backend-state)))]
          [(No)
            ;; GAP6a: register-homed rhs is the compare operand directly.
            ;; ptr-asm loads the pointer into scav-base first; rhs is live
            ;; across it, so scav-base already avoids rhs-home. A spilled rhs
            ;; still stages (cmp mem,mem illegal -- scav-base is the memory
            ;; operand here).
            (let
              [rhs-home : String
                (be_operand.compiler-backend-value-scalar-register
                  backend-state
                  assignments
                  rhs)]
              (if (not (string.eq rhs-home ""))
                (Ok
                  (str_cat.str-cat
                    ptr-asm
                    (compiler-backend-emit-compare-memory-flags
                      op
                      rhs-home
                      scav-base)
                    (compiler-backend-emit-compare-branch-jumps
                      function
                      true-label
                      false-label
                      fallthrough
                      true-jcc
                      false-jcc
                      backend-state)))
                (let
                  [scav-rhs : String
                    (be_operand.compiler-backend-scavenge-reg-here
                      (compiler-backend-scavenge-exclude-with
                        (be_state.compiler-backend-global-shared-view scav-base))
                      6
                      "%r8"
                      backend-state)]
                  [rhs-asm
                    (try
                      (be_operand.compiler-backend-emit-load-value
                        assignments
                        rhs
                        (be_state.compiler-backend-global-shared-view scav-rhs)
                        backend-state))]
                  (Ok
                    (str_cat.str-cat
                      ptr-asm
                      rhs-asm
                      (compiler-backend-emit-compare-memory-flags
                        op
                        scav-rhs
                        scav-base)
                      (compiler-backend-emit-compare-branch-jumps
                        function
                        true-label
                        false-label
                        fallthrough
                        true-jcc
                        false-jcc
                        backend-state))))))])))))

(define (compiler-backend-emit-gep-load-compare-branch
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [function : String]
  [base : compiler_ir_types.CompilerIrValue]
  [offset : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [op : (& compiler_ir_types.CompilerIrBinOp)]
  [rhs : (& compiler_ir_types.CompilerIrValue)]
  [ty : (& compiler_ast_types.AstType)]
  [true-label : i64]
  [false-label : i64]
  [fallthrough : be_state.CompilerBackendMaybeLabel]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [true-jcc : String
      (compiler-backend-compare-true-jcc type-segment-bases op ty)]
    [false-jcc : String
      (compiler-backend-compare-false-jcc type-segment-bases op ty)]
    (if (string.eq true-jcc "")
      (Err
        (box
          (compiler_diagnostic.compiler-diagnostic-at-start
            ""
            "backend: unsupported gep load compare branch")))
      (match (be_operand.compiler-backend-value-as-i64 offset)
        [(Some n)
          (let
            [disp : i64
              (*
                n
                (be_operand.compiler-backend-type-size
                  type-segment-bases
                  elem-ty))]
            ;; Address-base scratch: base is loaded here and
            ;; immediately dereferenced by the compare (dead after), so a single
            ;; scavenged base suffices. In the MaybeImmediate.No arm scav-rhs must
            ;; exclude this base (both live across the cmp) -- see below.
            ;; #9976: a register-homed rhs is read in place AFTER the base is
            ;; staged, so the base scavenge excludes rhs-home explicitly: under
            ;; full occupancy the emergency pick borrows any NON-EXCLUDED
            ;; register, and occupancy alone does not keep it off rhs-home.
            ;; M-C2: a register-homed base needs neither the scavenge nor the
            ;; staging copy -- the compare only READS the addressing base, so the
            ;; home register is used directly (the load below self-elides).
            ;; IAG-1: an inline aggregate global's field is a complete
            ;; rip-relative compare operand; no base is materialised.
            [rip : String
              (compiler-backend-inline-aggregate-gep-operand
                backend-state
                type-segment-bases
                (be_state.compiler-backend-global-shared-view base)
                offset
                elem-ty
                0)]
            [base-home : String
              (if (string.eq rip "")
                (be_facts.compiler-backend-address-base-filter-direct
                  (be_operand.compiler-backend-value-scalar-register
                    backend-state
                    assignments
                    base))
                "")]
            [rhs-home : String
              (be_operand.compiler-backend-value-scalar-register
                backend-state
                assignments
                rhs)]
            [scav-base : String
              (if (not (string.eq rip ""))
                ""
                (if (string.eq base-home "")
                  (be_operand.compiler-backend-scavenge-reg-here
                    (be_operand.compiler-backend-one-exclude
                      (string.copy (& rhs-home)))
                    1
                    "%r10"
                    backend-state)
                  base-home))]
            [addr : String
              (if (not (string.eq rip ""))
                (owned_view.compiler-owned-shared-view rip)
                (compiler-backend-base-address
                  disp
                  (be_state.compiler-backend-global-shared-view scav-base)))]
            [base-asm
              (try
                (if (string.eq rip "")
                  (be_operand.compiler-backend-emit-load-value
                    assignments
                    base
                    (be_state.compiler-backend-global-shared-view scav-base)
                    backend-state)
                  (be_state.ResultCompilerBackend.Ok "")))]
            (match (be_operand.compiler-backend-immediate-operand
              backend-state
              rhs)
              [(Some imm)
                (Ok
                  (str_cat.str-cat
                    base-asm
                    (compiler-backend-emit-compare-memory-address-flags
                      op
                      imm
                      addr)
                    (compiler-backend-emit-compare-branch-jumps
                      function
                      true-label
                      false-label
                      fallthrough
                      true-jcc
                      false-jcc
                      backend-state)))]
              [(No)
                ;; GAP6a: a register-homed rhs is the compare's register
                ;; operand directly -- no `movq %rhs-home, %scratch` staging.
                ;; The compare only READS rhs, and base-asm loads base into
                ;; scav-base FIRST; the base scavenge excludes rhs-home (see
                ;; above), so scav-base != rhs-home. A SPILLED rhs must still
                ;; stage into a scratch -- `cmp mem, mem` is illegal (addr is
                ;; already the memory operand).
                (if (not (string.eq rhs-home ""))
                  (Ok
                    (str_cat.str-cat
                      base-asm
                      (compiler-backend-emit-compare-memory-address-flags
                        op
                        rhs-home
                        addr)
                      (compiler-backend-emit-compare-branch-jumps
                        function
                        true-label
                        false-label
                        fallthrough
                        true-jcc
                        false-jcc
                        backend-state)))
                  (let
                    [scav-rhs : String
                      (be_operand.compiler-backend-scavenge-reg-here
                        (compiler-backend-scavenge-exclude-with scav-base)
                        6
                        "%r8"
                        backend-state)]
                    [rhs-asm
                      (try
                        (be_operand.compiler-backend-emit-load-value
                          assignments
                          rhs
                          (be_state.compiler-backend-global-shared-view
                            scav-rhs)
                          backend-state))]
                    (Ok
                      (str_cat.str-cat
                        base-asm
                        rhs-asm
                        (compiler-backend-emit-compare-memory-address-flags
                          op
                          scav-rhs
                          addr)
                        (compiler-backend-emit-compare-branch-jumps
                          function
                          true-label
                          false-label
                          fallthrough
                          true-jcc
                          false-jcc
                          backend-state)))))]))]
        [(None)
          (Err
            (box
              (compiler_diagnostic.compiler-diagnostic-at-start
                ""
                "backend: non-immediate fused gep load compare branch")))]))))

(define (compiler-backend-bounds-length-operand
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [length : compiler_ir_types.CompilerIrValue]
  [backend-state : be_state.CompilerBackendState]) : String
  (match (be_operand.compiler-backend-immediate-operand backend-state length)
    [(Some imm) imm]
    [(No)
      (let
        [length-reg : String
          (be_operand.compiler-backend-value-scalar-register-home
            backend-state
            assignments
            length)]
        (if (not (string.eq length-reg ""))
          length-reg
          (be_operand.compiler-backend-value-read-memory-operand
            assignments
            length
            backend-state)))]))

(define (compiler-backend-bounds-check-tail
  [call-space : i64]
  [ok-symbol : String]
  [index-operand : String]
  [length-operand : String]
  [plan : be_state.CompilerBackendRuntimePlan]
  [program-index : be_state.CompilerBackendProgramIndex]) : String
  (if (compiler-backend-abort-site-active? program-index.backend-state)
    (str_cat.str-cat
      (compiler-backend-abort-call-three-asm
        "tl_oob_abort_at"
        "bounds"
        (str_cat.str-cat "    pushq " length-operand "\n")
        (str_cat.str-cat "    pushq " index-operand "\n")
        call-space
        program-index.backend-state)
      (str_cat.str-cat ok-symbol ":\n"))
    (str_cat.str-cat
      (be_operand.compiler-backend-emit-call-space-sub call-space)
      (str_cat.str-cat
        "    call "
        (be_operand.compiler-backend-call-symbol-index
          cbi.compiler-builtin-id-tl-oob-abort
          plan
          program-index)
        "\n"
        (str_cat.str-cat
          (be_operand.compiler-backend-emit-call-space-add call-space)
          (str_cat.str-cat ok-symbol ":\n" "" ""))
        ""))))

(define (compiler-backend-bounds-check-asm
  [index-asm : String]
  [length-asm : String]
  [length-operand : String]
  [index-operand : String]
  [call-space : i64]
  [ok-symbol : String]
  [plan : be_state.CompilerBackendRuntimePlan]
  [program-index : be_state.CompilerBackendProgramIndex]) : String
  (str_cat.str-cat
    index-asm
    length-asm
    (str_cat.str-cat
      "    cmpq "
      length-operand
      ", "
      index-operand
      "\n    jb "
      ok-symbol
      "\n")
    (compiler-backend-bounds-check-tail
      call-space
      ok-symbol
      index-operand
      length-operand
      plan
      program-index)))

;; GAP6d: constant-index bounds check. The normal path materialises the index
;; (`movl $K, %r`) then `cmpq len, %r; jb ok`. When the index is an imm32
;; constant K and the length is a register/memory operand, the compare folds to
;; `cmpq $K, len; ja ok`: the check `K < len` <=> `len > K` (both non-negative;
;; and a negative K sign-extends to a huge unsigned value so `len > K` is false
;; -> abort, exactly as materialising K and taking `jb` did). This drops the
;; index materialisation mov. length-operand MUST be a register or memory (never
;; an immediate) -- `cmpq $K, $L` is illegal; the caller guarantees it.
(define (compiler-backend-bounds-check-const-index-asm
  [length-asm : String]
  [length-operand : String]
  [index-imm : String]
  [call-space : i64]
  [ok-symbol : String]
  [plan : be_state.CompilerBackendRuntimePlan]
  [program-index : be_state.CompilerBackendProgramIndex]) : String
  (str_cat.str-cat
    length-asm
    (if (and
      (string.eq index-imm "$0")
      (be_operand.compiler-backend-string-prefix-at? length-operand "%" 0))
      (str_cat.str-cat
        "    testq "
        length-operand
        ", "
        length-operand
        "\n    ja "
        ok-symbol
        "\n")
      (str_cat.str-cat
        "    cmpq "
        index-imm
        ", "
        length-operand
        "\n    ja "
        ok-symbol
        "\n"))
    (compiler-backend-bounds-check-tail
      call-space
      ok-symbol
      index-imm
      length-operand
      plan
      program-index)))

;; "$K" when the index is an imm32-fitting constant, else "". imm32 is required
;; so `cmpq $K, len` is encodable.
(define (compiler-backend-bounds-const-index-imm
  [index : compiler_ir_types.CompilerIrValue]) : String
  (match (be_operand.compiler-backend-value-as-i64 index)
    [(Some k)
      (if (be_operand.compiler-backend-imm32? k)
        (str_cat.str-cat "$" (string.int->string k))
        "")]
    [(None) ""]))

(define (compiler-backend-emit-bounds-check
  [target : be_state.CompilerBackendTarget]
  [function : String]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [index : compiler_ir_types.CompilerIrValue]
  [length : compiler_ir_types.CompilerIrValue]
  [ok-label : i64]
  [plan : be_state.CompilerBackendRuntimePlan]
  [_functions : compiler_ir_types.CompilerIrFunctionSeq]
  [_externs : compiler_ir_types.CompilerIrExternSeq]
  [program-index : be_state.CompilerBackendProgramIndex]) : be_state.ResultCompilerBackend
  (let
    [call-space : i64
      (let
        [args (compiler_ir_types.CompilerIrCallArgs.Nil)]
        [types (compiler_ast_types.ast-type-list-new)]
        (be_operand.compiler-backend-call-arg-space
          target
          args
          types
          false
          program-index))]
    [ok-symbol : String
      (be_operand.compiler-backend-asm-label function ok-label)]
    [index-reg : String
      (be_operand.compiler-backend-value-scalar-register-home
        program-index.backend-state
        assignments
        index)]
    [direct-length-operand : String
      (compiler-backend-bounds-length-operand
        assignments
        (be_state.compiler-backend-global-shared-view length)
        program-index.backend-state)]
    ;; Length-load scratch: exclude the index home because the cmp reads index
    ;; vs length. The cfg-gated path supplies a short-lived allocator-owned
    ;; pseudo-var when length staging is required; otherwise retain the proven
    ;; emission-time scavenger fallback.
    [scav-len : String
      (if (string.eq direct-length-operand "")
        (be_operand.compiler-backend-scavenge-reg-here
          (compiler-backend-scavenge-exclude-with
            (be_state.compiler-backend-global-shared-view index-reg))
          6
          "%r9"
          program-index.backend-state)
        "")]
    ;; A constant index materializes into a reserved-set-aware scavenged register
    ;; distinct from the length scratch -- NOT a hardcoded %rax, which (now that
    ;; %rax is pooled) collided with a length loaded into %rax: `movq 8(%r10),%rax`
    ;; then `xorl %eax,%eax` clobbered the length, so `cmpq %rax,%rax` always
    ;; tripped the bounds check (false OOB abort).
    [index-operand : String
      (if (string.eq index-reg "")
        (be_operand.compiler-backend-scavenge-reg-here
          (compiler-backend-scavenge-exclude-with
            (be_state.compiler-backend-global-shared-view scav-len))
          6
          "%r10"
          program-index.backend-state)
        (owned_view.compiler-owned-shared-view index-reg))]
    (if (string.eq index-reg "")
      (let
        [const-imm : String
          (compiler-backend-bounds-const-index-imm
            (be_state.compiler-backend-global-shared-view index))]
        [fold-length-operand : String
          (compiler-backend-bounds-length-operand
            assignments
            (be_state.compiler-backend-global-shared-view length)
            program-index.backend-state)]
        (if (and
          (not (string.eq const-imm ""))
          ;; length must be a register/memory operand (never immediate:
          ;; `cmpq $K, $L` is illegal). A "" operand is loaded into scav-len.
          (not
            (be_operand.compiler-backend-string-prefix-at?
              fold-length-operand
              "$"
              0)))
          ;; GAP6d: constant index -- `cmpq $K, len; ja ok`, no index mov.
          (if (not (string.eq fold-length-operand ""))
            (Ok
              (compiler-backend-bounds-check-const-index-asm
                ""
                fold-length-operand
                const-imm
                call-space
                ok-symbol
                plan
                program-index))
            (let
              [length-asm
                (try
                  (be_operand.compiler-backend-emit-load-value
                    assignments
                    length
                    (be_state.compiler-backend-global-shared-view scav-len)
                    program-index.backend-state))]
              (Ok
                (compiler-backend-bounds-check-const-index-asm
                  length-asm
                  scav-len
                  const-imm
                  call-space
                  ok-symbol
                  plan
                  program-index))))
          (let
            [index-asm
              (try
                (be_operand.compiler-backend-emit-load-value
                  assignments
                  index
                  (be_state.compiler-backend-global-shared-view index-operand)
                  program-index.backend-state))]
            [length-operand : String
              (compiler-backend-bounds-length-operand
                assignments
                (be_state.compiler-backend-global-shared-view length)
                program-index.backend-state)]
            (if (not (string.eq length-operand ""))
              (Ok
                (compiler-backend-bounds-check-asm
                  index-asm
                  ""
                  length-operand
                  index-operand
                  call-space
                  ok-symbol
                  plan
                  program-index))
              (let
                [length-asm
                  (try
                    (be_operand.compiler-backend-emit-load-value
                      assignments
                      length
                      (be_state.compiler-backend-global-shared-view scav-len)
                      program-index.backend-state))]
                (Ok
                  (compiler-backend-bounds-check-asm
                    index-asm
                    length-asm
                    scav-len
                    index-operand
                    call-space
                    ok-symbol
                    plan
                    program-index)))))))
      (let
        [length-operand : String
          (compiler-backend-bounds-length-operand
            assignments
            (be_state.compiler-backend-global-shared-view length)
            program-index.backend-state)]
        (if (not (string.eq length-operand ""))
          (Ok
            (compiler-backend-bounds-check-asm
              ""
              ""
              length-operand
              index-operand
              call-space
              ok-symbol
              plan
              program-index))
          (let
            [length-asm
              (try
                (be_operand.compiler-backend-emit-load-value
                  assignments
                  length
                  (be_state.compiler-backend-global-shared-view scav-len)
                  program-index.backend-state))]
            (Ok
              (compiler-backend-bounds-check-asm
                ""
                length-asm
                scav-len
                index-operand
                call-space
                ok-symbol
                plan
                program-index))))))))

(define (compiler-backend-emit-unop
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [op : compiler_ir_types.CompilerIrUnOp]
  [src : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (compiler-backend-direct-float-unop? op ty)
    (let
      [dst-home : String
        (compiler-backend-var-register-home backend-state assignments dst)]
      (if (be_operand.compiler-backend-string-prefix-at? dst-home "%xmm" 0)
        (let
          [src-asm
            (try
              (be_operand.compiler-backend-emit-load-float-value
                assignments
                src
                ty
                (be_state.compiler-backend-global-shared-view dst-home)
                backend-state))]
          [op-asm (try (compiler-backend-float-unop-reg-asm op ty dst-home))]
          (Ok (str_cat.str-cat src-asm op-asm)))
        (let
          [result-reg : String
            (be_operand.compiler-backend-scavenge-xmm-reg
              dst
              (__tl_make-array String 0)
              0
              "%xmm2"
              backend-state)]
          [src-asm
            (try
              (be_operand.compiler-backend-emit-load-float-value
                assignments
                src
                ty
                (be_state.compiler-backend-global-shared-view result-reg)
                backend-state))]
          [op-asm
            (try
              (compiler-backend-float-unop-reg-asm
                op
                (be_state.compiler-backend-global-shared-view ty)
                result-reg))]
          (Ok
            (str_cat.str-cat
              src-asm
              op-asm
              (be_operand.compiler-backend-emit-store-float-var
                assignments
                dst
                result-reg
                ty
                backend-state))))))
    (let
      [dst-home : String
        (compiler-backend-var-register-home backend-state assignments dst)]
      (if (string.eq dst-home "")
        (let
          [result-reg : String
            (be_operand.compiler-backend-scavenge-reg
              dst
              (compiler-backend-binop-scavenge-exclude-build)
              5
              "%r8"
              backend-state)]
          [src-asm
            (try
              (be_operand.compiler-backend-emit-load-value
                assignments
                src
                (be_state.compiler-backend-global-shared-view result-reg)
                backend-state))]
          (Ok
            (str_cat.str-cat
              src-asm
              (compiler-backend-unop-typed-reg-asm
                type-segment-bases
                op
                ty
                (be_state.compiler-backend-global-shared-view result-reg))
              (be_operand.compiler-backend-emit-store-var
                assignments
                dst
                result-reg
                backend-state))))
        (let
          [src-asm
            (try
              (be_operand.compiler-backend-emit-load-value
                assignments
                src
                (be_state.compiler-backend-global-shared-view dst-home)
                backend-state))]
          (Ok
            (str_cat.str-cat
              src-asm
              (compiler-backend-unop-typed-reg-asm
                type-segment-bases
                op
                ty
                dst-home))))))))

;; The shift count for a power-of-two scale > 1, or None. Scales are small
;; positive type sizes, so the scan is bounded.
(define (compiler-backend-power-of-two-shift [scale : i64]) : option_i64.Option
  (let
    [count : i64 0]
    [value : i64 scale]
    (while (and (> value 1) (= (% value 2) 0))
      (set! value (/ value 2))
      (+= count 1))
    (if (and (= value 1) (> count 0))
      (Some count)
      (None))))

;; Fold the scaled index into base-reg in place for non-SIB scales (1 or odd).
(define (compiler-backend-gep-index-base-asm
  [base-reg : (& base-reg str)]
  [scale : i64]
  [index-reg : (& index-reg str)]) : String
  (if (= scale 1)
    (str_cat.str-cat "    addq " index-reg ", " base-reg "\n")
    (if (or (= scale 2) (= scale 4) (= scale 8))
      (str_cat.str-cat
        "    leaq ("
        base-reg
        ","
        index-reg
        ","
        (string.int->string scale)
        "), "
        base-reg
        "\n"
        "")
      ;; Power-of-two stride (16-byte inline enums/structs are the common
      ;; case): shift the index in place instead of a multiply. Same operand
      ;; shape as the imulq it replaces, strictly cheaper to execute.
      (let
        [scale-asm : String
          (match (compiler-backend-power-of-two-shift scale)
            [(Some count)
              (str_cat.str-cat
                "    shlq $"
                (string.int->string count)
                ", "
                index-reg
                "\n"
                "")]
            [(None)
              (str_cat.str-cat
                "    imulq $"
                (string.int->string scale)
                ", "
                index-reg
                "\n"
                "")])]
        (str_cat.str-cat
          scale-asm
          (str_cat.str-cat "    addq " index-reg ", " base-reg "\n"))))))

(define (compiler-backend-gep-sib-scale? [scale : i64]) : bool
  (or (= scale 1) (= scale 2) (= scale 4) (= scale 8)))

;; Reuse the emitter's parsed offset and scale. A non-disp32 constant takes
;; the existing register-index path, just like a dynamic offset.
(defmacro (compiler-backend-disp32-displacement
  [offset : Expr]
  [scale : Expr]
  [fold-disp : Expr]) : Expr
  `(match (be_operand.compiler-backend-value-as-i64 ,offset)
    [(option_i64.Option.Some n)
      (let
        [disp : i64 (+ (* n ,scale) ,fold-disp)]
        (if (be_operand.compiler-backend-imm32? disp)
          (option_i64.Option.Some disp)
          (option_i64.Option.None)))]
    [(option_i64.Option.None) (option_i64.Option.None)]))

;; GAP9 disp-aware SIB operand: `D(base,index,scale)`. The displacement is a
;; folded gep constant (compiler-backend-gep-fold-next!); 0 keeps the plain
;; spelling, and the non-SIB "" contract is unchanged.
(define (compiler-backend-gep-index-address-disp
  [disp : i64]
  [base-reg : (& base-reg str)]
  [scale : i64]
  [index-reg : (& index-reg str)]) : String
  (let
    [sib : String (compiler-backend-gep-index-address base-reg scale index-reg)]
    (if (or (= disp 0) (string.eq sib ""))
      sib
      (str_cat.str-cat (string.int->string disp) sib))))

;; GAP9 disp-aware staged address: compose base+index*scale as before, then
;; add the folded displacement into the base register.
;;
;; SS-P5(a): when the scale is one the SIB byte can spell, the displacement is
;; the SIB form's OWN field -- `leaq D(base,index,s), base` is the whole of
;; `leaq (base,index,s), base ; addq $D, base`, and for scale 1 the whole of
;; `addq index, base ; addq $D, base`. The fold needs D to fit the signed
;; 32-bit displacement field; anything wider keeps the two-instruction form,
;; where the `addq $D` at least reaches the imm32-or-wider encodings the
;; assembler picks.
(define (compiler-backend-gep-index-base-asm-disp
  [disp : i64]
  [base-reg : (& base-reg str)]
  [scale : i64]
  [index-reg : (& index-reg str)]) : String
  (if (and
    (not (= disp 0))
    (compiler-backend-gep-sib-scale? scale)
    (be_operand.compiler-backend-imm32? disp))
    (str_cat.str-cat
      "    leaq "
      (compiler-backend-gep-index-address-disp disp base-reg scale index-reg)
      ", "
      base-reg
      "\n")
    (let
      [tail : String
        (if (= disp 0)
          ""
          (str_cat.str-cat
            "    addq $"
            (string.int->string disp)
            ", "
            base-reg
            "\n"))]
      (str_cat.str-cat
        (compiler-backend-gep-index-base-asm base-reg scale index-reg)
        tail))))

;; BE-2: a %rbp base at scale 1 is spelled with the two SIB slots SWAPPED,
;; `(index,%rbp,1)`: base+index*1 is symmetric, and the index slot is the one
;; place the frame register may stand -- no recognizer reads it there. The
;; rsp-rebase pass finds frame references by the five bytes `(%rbp`, the
;; peephole's slot recognizers by the trailing `(%rbp)` and the base classifier
;; by the operand's last six bytes, and `(%r12,%rbp,1)` shows none of them
;; what they look for, exactly as BE-1's `leaq (base,%rbp,s)` does not. At any
;; other scale a %rbp base cannot be spelled and the caller's staged path
;; copies it, as before.
(define (compiler-backend-gep-index-address
  [base-reg : (& base-reg str)]
  [scale : i64]
  [index-reg : (& index-reg str)]) : String
  (cond
    [(not (compiler-backend-gep-sib-scale? scale)) ""]
    [(not (string.eq base-reg "%rbp"))
      (str_cat.str-cat
        "("
        base-reg
        ","
        index-reg
        ","
        (string.int->string scale)
        ")")]
    [(and
        (= scale 1)
        (not (string.eq index-reg ""))
        (not (string.eq index-reg "%rbp")))
      (str_cat.str-cat "(" index-reg ",%rbp,1)")]
    ;; BE-4: at every other scale the base slot is the only place the base can
    ;; stand, and it is spelled outright: `(%rbp,idx,s)`. A %rbp base reaching
    ;; this formatter is always a pool value of an rbp-planned function, where
    ;; the rsp-rebase audit steps over the indexed form, and no other reader
    ;; sees a frame reference in it -- the peephole's slot recognizers key the
    ;; trailing `(%rbp)`, the base classifier the operand's last six bytes.
    [(and (not (string.eq index-reg "")) (not (string.eq index-reg "%rbp")))
      (str_cat.str-cat
        "(%rbp,"
        index-reg
        ","
        (str_cat.str-cat (string.int->string scale) ")" "" ""))]
    [else ""]))

;; BE-2: the dynamic-index base filter for a site that spells its address
;; through compiler-backend-gep-index-address: a %rbp home is admitted at
;; scale 1, where that formatter can spell it, and filtered as before at every
;; other scale.
(define (compiler-backend-address-base-filter-sib [home : String] [scale : i64]) : String
  (if (and (string.eq home "%rbp") (compiler-backend-gep-sib-scale? scale))
    home
    (compiler-backend-address-base-filter home)))

;; Fold a constant displacement into base-reg in place.
(define (compiler-backend-gep-immediate-base-asm
  [base-reg : (& base-reg str)]
  [disp : i64]) : be_state.CompilerBackendMaybeAsm
  (if (= disp 0)
    (Some "")
    (if (be_operand.compiler-backend-imm32? disp)
      (Some
        (str_cat.str-cat
          "    addq $"
          (string.int->string disp)
          ", "
          base-reg
          "\n"
          ""))
      (No))))

(define (compiler-backend-emit-gep
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [base : compiler_ir_types.CompilerIrValue]
  [offset : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [gep-disp : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  ;; vreg-model: when the GEP result has a register home and the base is already
  ;; in a register, compute the address straight into that home with a single
  ;; leaq (constant offset). Variable-index GEPs and spilled/stack operands fall
  ;; through to the staged/scavenged path.
  (let
    [dst-home : String
      (compiler-backend-var-register-home backend-state assignments dst)]
    ;; IAG-1: `gep @g, k` on an inline aggregate global is a link-time constant
    ;; address; a register-homed result takes it in one `leaq`.
    [rip : String
      (compiler-backend-inline-aggregate-gep-operand
        backend-state
        type-segment-bases
        (be_state.compiler-backend-global-shared-view base)
        offset
        (be_state.compiler-backend-global-shared-view elem-ty)
        gep-disp)]
    ;; GAP7: a %rbp base is admitted for the CONST-offset leaq (spelled as the
    ;; SIB scale-1 form via compiler-backend-copy-address); the variable-index
    ;; branch below re-excludes it (the SIB index slot is taken by the gep index).
    [base-reg : String
      (be_facts.compiler-backend-address-base-filter-direct
        (be_operand.compiler-backend-value-scalar-register
          backend-state
          assignments
          base))]
    (if (and (not (string.eq rip "")) (not (string.eq dst-home "")))
      (Ok (str_cat.str-cat "    leaq " rip ", " dst-home "\n"))
      (if (if (string.eq dst-home "")
        false
        (not (string.eq base-reg "")))
        (match (be_operand.compiler-backend-value-as-i64 offset)
          [(Some n)
            (let
              [disp : i64
                (*
                  n
                  (be_operand.compiler-backend-type-size
                    type-segment-bases
                    elem-ty))]
              (if (be_operand.compiler-backend-imm32? disp)
                (if (if (= disp 0)
                  (string.eq base-reg dst-home)
                  false)
                  (Ok "")
                  (Ok
                    (str_cat.str-cat
                      "    leaq "
                      (be_facts.compiler-backend-copy-address disp base-reg)
                      ", "
                      dst-home
                      "\n")))
                (compiler-backend-emit-gep-staged
                  type-segment-bases
                  assignments
                  dst
                  base
                  offset
                  elem-ty
                  gep-disp
                  backend-state)))]
          [(None)
            ;; GAP6b: variable index, both base and index register-homed with a
            ;; valid SIB scale -> compute the address in ONE leaq off the homes,
            ;; no `movq base,%r; movq idx,%r2; leaq (%r,%r2,s)` staging copies.
            ;; leaq only READS its operands, so dst-home may alias base-reg or the
            ;; index. #rbp-base: base-reg is already filtered (never %rbp); a
            ;; %rbp-homed INDEX in the SIB index slot is legal.
            (let
              [offset-home : String
                (be_operand.compiler-backend-value-scalar-register
                  backend-state
                  assignments
                  offset)]
              [scale : i64
                (be_operand.compiler-backend-type-size
                  type-segment-bases
                  elem-ty)]
              (if (and
                (not (string.eq offset-home ""))
                ;; BE-2/BE-4: a %rbp base is spelled at every SIB scale
                ;; (swapped into the index slot at scale 1, outright above
                ;; it), so the one-leaq form is the whole gep where the staged
                ;; path copied %rbp first.
                (compiler-backend-gep-sib-scale? scale))
                (Ok
                  (str_cat.str-cat
                    "    leaq "
                    (compiler-backend-gep-index-address-disp
                      gep-disp
                      base-reg
                      scale
                      offset-home)
                    ", "
                    dst-home
                    "\n"))
                (compiler-backend-emit-gep-staged
                  type-segment-bases
                  assignments
                  dst
                  base
                  offset
                  elem-ty
                  gep-disp
                  backend-state)))])
        (compiler-backend-emit-gep-staged
          type-segment-bases
          assignments
          dst
          base
          offset
          elem-ty
          gep-disp
          backend-state)))))

(define (compiler-backend-emit-gep-staged-avoid
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [base : compiler_ir_types.CompilerIrValue]
  [offset : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [gep-disp : i64]
  [avoid1 : String]
  [avoid2 : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [scale : i64
      (be_operand.compiler-backend-type-size type-segment-bases elem-ty)]
    [dst-home : String
      (compiler-backend-var-register-home backend-state assignments dst)]
    (match (be_operand.compiler-backend-value-as-i64 offset)
      [(Some n)
        (let
          [use-dst-home? : bool
            (and
              (not (string.eq dst-home ""))
              (not (string.eq dst-home avoid1))
              (not (string.eq dst-home avoid2)))]
          [result-reg : String
            (if use-dst-home?
              dst-home
              (be_operand.compiler-backend-scavenge-reg
                dst
                (be_operand.compiler-backend-two-exclude
                  (be_state.compiler-backend-global-shared-view avoid1)
                  (be_state.compiler-backend-global-shared-view avoid2))
                2
                "%r10"
                backend-state))]
          [base-asm
            (try
              (be_operand.compiler-backend-emit-load-value
                assignments
                base
                (be_state.compiler-backend-global-shared-view result-reg)
                backend-state))]
          (match (compiler-backend-gep-immediate-base-asm
            result-reg
            (* n scale))
            [(Some offset-asm)
              (Ok
                (str_cat.str-cat
                  base-asm
                  (str_cat.str-cat
                    offset-asm
                    (if use-dst-home?
                      ""
                      (be_operand.compiler-backend-emit-store-var
                        assignments
                        dst
                        result-reg
                        backend-state)))))]
            [(No)
              (let
                [scav-idx : String
                  (be_operand.compiler-backend-scavenge-reg
                    dst
                    (be_operand.compiler-backend-three-exclude
                      (be_state.compiler-backend-global-shared-view result-reg)
                      avoid1
                      avoid2)
                    3
                    "%r8"
                    backend-state)]
                [offset-asm
                  (try
                    (be_operand.compiler-backend-emit-load-value
                      assignments
                      offset
                      (be_state.compiler-backend-global-shared-view scav-idx)
                      backend-state))]
                (Ok
                  (str_cat.str-cat
                    base-asm
                    (str_cat.str-cat
                      offset-asm
                      (str_cat.str-cat
                        (compiler-backend-gep-index-base-asm-disp
                          gep-disp
                          result-reg
                          scale
                          scav-idx)
                        (if use-dst-home?
                          ""
                          (be_operand.compiler-backend-emit-store-var
                            assignments
                            dst
                            result-reg
                            backend-state)))))))]))]
      [(None)
        (let
          [offset-home : String
            (be_operand.compiler-backend-value-scalar-register
              backend-state
              assignments
              offset)]
          ;; SS-P5(a): the index only ever needs a staging register when the
          ;; index-composing form WRITES it. `addq idx, base` (scale 1) and
          ;; `leaq disp(base,idx,s), base` (scale 2/4/8) both READ the index and
          ;; write only the base, so a register-homed index goes straight into
          ;; the SIB/add slot and the `movq %rX, %r8` staging copy disappears.
          ;; The non-SIB scales are excluded because their composition
          ;; (`shlq $c, idx` / `imulq $c, idx`) scales the index IN PLACE and
          ;; would destroy the live home, and a spilled index has no home to
          ;; use. `avoid1` and `avoid2` need no test: they name registers this
          ;; emitter must not WRITE, and the index is only ever read.
          ;;
          ;; BE-1: a %rbp-homed index is read directly too. It was refused here
          ;; "for the same reason GAP7 refuses it as a base", and that reason
          ;; is the BASE spelling alone: `off(%rbp)` and `(%rbp,idx,s)` are what
          ;; the FPO rsp-rebase pass and the peephole read as frame references,
          ;; and the index slot `(base,%rbp,s)` / `addq %rbp, base` is neither
          ;; -- the one-`leaq` path above (GAP6b) already composes off a %rbp
          ;; index. The refusal only showed once the allocator's block weights
          ;; (FREQ-1) homed a scan's index in %rbp: `sfl-scales` inlined into
          ;; `main` staged all three of its SIB indexes through %r8, which is
          ;; exactly the copy the select-flags-gep gate exists to refuse.
          [direct-index? : bool
            (and
              (not (string.eq offset-home ""))
              (compiler-backend-gep-sib-scale? scale))]
          [use-dst-home? : bool
            (and
              (not (string.eq dst-home ""))
              (not (string.eq dst-home offset-home))
              (not (string.eq dst-home avoid1))
              (not (string.eq dst-home avoid2)))]
          [result-reg : String
            (if use-dst-home?
              dst-home
              (be_operand.compiler-backend-scavenge-reg
                dst
                (be_operand.compiler-backend-three-exclude
                  (be_state.compiler-backend-global-shared-view offset-home)
                  (be_state.compiler-backend-global-shared-view avoid1)
                  (be_state.compiler-backend-global-shared-view avoid2))
                3
                "%r10"
                backend-state))]
          ;; result-reg is never offset-home (use-dst-home? refuses it, and the
          ;; scavenge excludes it), so loading the base cannot disturb the index
          ;; this path is about to read.
          [scav-idx : String
            (if direct-index?
              offset-home
              (be_operand.compiler-backend-scavenge-reg
                dst
                (be_operand.compiler-backend-three-exclude
                  (be_state.compiler-backend-global-shared-view result-reg)
                  avoid1
                  avoid2)
                3
                "%r8"
                backend-state))]
          [base-asm
            (try
              (be_operand.compiler-backend-emit-load-value
                assignments
                base
                (be_state.compiler-backend-global-shared-view result-reg)
                backend-state))]
          [offset-asm
            (try
              (if direct-index?
                (be_state.ResultCompilerBackend.Ok "")
                (be_operand.compiler-backend-emit-load-value
                  assignments
                  offset
                  (be_state.compiler-backend-global-shared-view scav-idx)
                  backend-state)))]
          (Ok
            (str_cat.str-cat
              base-asm
              (str_cat.str-cat
                offset-asm
                (str_cat.str-cat
                  (compiler-backend-gep-index-base-asm-disp
                    gep-disp
                    result-reg
                    scale
                    scav-idx)
                  (if use-dst-home?
                    ""
                    (be_operand.compiler-backend-emit-store-var
                      assignments
                      dst
                      result-reg
                      backend-state)))))))])))

(define (compiler-backend-emit-gep-staged
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [base : compiler_ir_types.CompilerIrValue]
  [offset : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [gep-disp : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (compiler-backend-emit-gep-staged-avoid
    type-segment-bases
    assignments
    dst
    base
    offset
    elem-ty
    gep-disp
    ""
    ""
    backend-state))

(define (compiler-backend-emit-load-instr
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  ;; vreg-model: when the source pointer (e.g. a register-homed GEP result) is
  ;; already in a register, dereference it straight from that home rather than
  ;; staging it through a scratch register.
  ;; compiler-backend-emit-address-base returns the register home directly when
  ;; available, falling back to loading the pointer into the scavenged base. This
  ;; mirrors the store path (compiler-backend-emit-store-ptr).
  (if (compiler-backend-var-remat-home? backend-state assignments dst)
    ;; R5: same argument as the `mov` arm -- a `load @g` whose destination
    ;; recomputes at every use has a dead definition.
    (Ok "")
    (let
      [src-home : String
        (be_facts.compiler-backend-value-register-home
          backend-state
          assignments
          src)]
      [scav-base : String
        (be_operand.compiler-backend-scavenge-reg-here
          (be_operand.compiler-backend-one-exclude src-home)
          1
          "%r10"
          backend-state)]
      [base-plan
        (try
          (compiler-backend-emit-address-base
            assignments
            src
            scav-base
            backend-state))]
      [ptr-asm : String base-plan.asm]
      [base : String
        (compiler_abi.compiler-abi-register-spelling base-plan.reg)]
      [base-mem : String
        (compiler-backend-base-deref
          (be_state.compiler-backend-global-shared-view base))]
      (Ok
        (if (be_operand.compiler-backend-float-type? ty)
          (let
            [dst-home : String
              (compiler-backend-var-register-home backend-state assignments dst)]
            [load-reg : String
              (if (string.eq dst-home "")
                (let
                  [no-exclude : (__tl_dyn-array String)
                    (__tl_make-array String 0)]
                  (be_operand.compiler-backend-scavenge-xmm-reg
                    dst
                    no-exclude
                    0
                    "%xmm2"
                    backend-state))
                (owned_view.compiler-owned-shared-view dst-home))]
            [store-asm : String
              (if (string.eq dst-home "")
                (be_operand.compiler-backend-emit-store-float-var
                  assignments
                  dst
                  (be_state.compiler-backend-global-shared-view load-reg)
                  ty
                  backend-state)
                "")]
            (str_cat.str-cat
              ptr-asm
              (compiler-backend-emit-load-float-memory base-mem load-reg ty)
              store-asm))
          (str_cat.str-cat
            ptr-asm
            (compiler-backend-emit-load-scalar-address-to-var
              type-segment-bases
              assignments
              dst
              base-mem
              ty
              (be_operand.compiler-backend-one-exclude base)
              1
              ""
              backend-state)))))))

(define (compiler-backend-emit-load-float-address-to-var
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [addr : String]
  [ty : (& compiler_ast_types.AstType)]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [dst-home : String
      (compiler-backend-var-register-home backend-state assignments dst)]
    [no-exclude : (__tl_dyn-array String) (__tl_make-array String 0)]
    [load-reg : String
      (if (string.eq dst-home "")
        (be_operand.compiler-backend-scavenge-xmm-reg
          dst
          no-exclude
          0
          "%xmm2"
          backend-state)
        (owned_view.compiler-owned-shared-view dst-home))]
    (str_cat.str-cat
      (compiler-backend-emit-load-float-memory addr load-reg ty)
      (if (string.eq dst-home "")
        (be_operand.compiler-backend-emit-store-float-var
          assignments
          dst
          load-reg
          ty
          backend-state)
        ""))))

;; IAG-1: the rip-relative memory operand `gep @g, k` denotes for an inline
;; aggregate global at a CONSTANT offset. It is the whole of the base
;; materialisation plus the addressing displacement in one operand, which is
;; what turns the two-instruction `movq g(%rip), %r ; movq (%r), %x` chain link
;; into a single `movq g+k(%rip), %x`. "" declines: a non-inline base, a
;; non-constant offset, or a displacement outside the cell (defensive -- an
;; in-bounds field access is all lowering produces for these).
(define (compiler-backend-inline-aggregate-gep-operand
  [backend-state : be_state.CompilerBackendState]
  [type-segment-bases : i64]
  [base : compiler_ir_types.CompilerIrValue]
  [offset : (& compiler_ir_types.CompilerIrValue)]
  [elem-ty : compiler_ast_types.AstType]
  [gep-disp : i64]) : String
  (match base
    [(Global name)
      (let
        [size : i64
          (be_state.compiler-backend-inline-aggregate-global-size
            backend-state
            name)]
        (if (= size 0)
          ""
          (match (be_operand.compiler-backend-value-as-i64 offset)
            [(Some n)
              (let
                [disp : i64
                  (+
                    (*
                      n
                      (be_operand.compiler-backend-type-size
                        type-segment-bases
                        elem-ty))
                    gep-disp)]
                (if (and (>= disp 0) (< disp size))
                  (be_state.compiler-backend-inline-aggregate-symbol-operand
                    (be_operand.compiler-backend-state-global-symbol-id
                      backend-state
                      name)
                    disp)
                  ""))]
            [(None) ""])))]
    [_ ""]))

(define (compiler-backend-emit-load-scalar-address-to-var
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [addr : String]
  [ty : (& compiler_ast_types.AstType)]
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [planned-value : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [dst-home : String
      (compiler-backend-var-register-home backend-state assignments dst)]
    (if (if (string.eq dst-home "")
      false
      (<= (be_operand.compiler-backend-type-size type-segment-bases ty) 8))
      (compiler-backend-emit-load-memory-to-reg
        type-segment-bases
        addr
        ty
        dst-home)
      (let
        [load-reg : String
          (if (string.eq planned-value "")
            ;; Callers that did not pick the load register scavenge one.
            (be_operand.compiler-backend-scavenge-reg
              dst
              exclude
              exclude-n
              "%r8"
              backend-state)
            planned-value)]
        [seq : be_state.CompilerBackendAsmBuf
          (be_state.compiler-backend-asm-buf-with-capacity
            be_state.compiler-backend-asm-seq-capacity)]
        (be_state.compiler-backend-asm-append
          (&mut seq)
          (compiler-backend-emit-load-memory-to-reg
            type-segment-bases
            addr
            ty
            (be_state.compiler-backend-global-shared-view load-reg)))
        (be_operand.compiler-backend-emit-store-var-into
          (&mut seq)
          assignments
          dst
          load-reg
          backend-state)
        (be_state.compiler-backend-asm-buf-finish (& seq))))))

(define (compiler-backend-base-address [disp : i64] [base : String]) : String
  (be_operand.compiler-backend-mem-base-address disp base))

;; "(base)" memory operand for a scavenged base register.
(define (compiler-backend-base-deref [base : String]) : String
  (be_operand.compiler-backend-mem-base-address 0 base))

(define (compiler-backend-param-register-exclude-location-count
  [location : compiler_regalloc.CompilerRegLocation]) : i64
  (match location
    [(Register _) 1]
    [(RegisterPair _ _) 2]
    [_ 0]))

(define (compiler-backend-param-register-exclude-count-from
  [backend-state : be_state.CompilerBackendState]
  [params : compiler_ir_types.CompilerIrParamSeq]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [position : i64]) : i64
  (if (>= position params.len)
    0
    (match (compiler_ir_types.compiler-ir-param-seq-borrow params position)
      [(Param _ _ var-id)
        (+
          (match (be_operand.compiler-backend-emit-assignment-lookup
            backend-state
            assignments
            var-id)
            [(Some location)
              (compiler-backend-param-register-exclude-location-count location)]
            [(No) 0])
          (compiler-backend-param-register-exclude-count-from
            backend-state
            params
            assignments
            (+ position 1)))])))

(define (compiler-backend-param-register-exclude-count
  [backend-state : be_state.CompilerBackendState]
  [params : compiler_ir_types.CompilerIrParamSeq]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]) : i64
  (compiler-backend-param-register-exclude-count-from
    backend-state
    params
    assignments
    0))

(define (compiler-backend-param-register-exclude-fill-location
  [location : compiler_regalloc.CompilerRegLocation]
  [out : (__tl_dyn-array String)]
  [index : i64]) : i64
  (match location
    [(Register reg)
      (set!
        (array-ref out index)
        (compiler_abi.compiler-abi-register-spelling reg))
      (+ index 1)]
    [(RegisterPair first second)
      (set!
        (array-ref out index)
        (compiler_abi.compiler-abi-register-spelling first))
      (set!
        (array-ref out (+ index 1))
        (compiler_abi.compiler-abi-register-spelling second))
      (+ index 2)]
    [_ index]))

(define (compiler-backend-param-register-exclude-fill-from
  [backend-state : be_state.CompilerBackendState]
  [params : compiler_ir_types.CompilerIrParamSeq]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [out : (__tl_dyn-array String)]
  [index : i64]
  [position : i64]) : i64
  (if (>= position params.len)
    index
    (match (compiler_ir_types.compiler-ir-param-seq-borrow params position)
      [(Param _ _ var-id)
        (compiler-backend-param-register-exclude-fill-from
          backend-state
          params
          assignments
          (be_state.compiler-backend-global-shared-view out)
          (match (be_operand.compiler-backend-emit-assignment-lookup
            backend-state
            assignments
            var-id)
            [(Some location)
              (compiler-backend-param-register-exclude-fill-location
                location
                out
                index)]
            [(No) index])
          (+ position 1))])))

(define (compiler-backend-param-register-exclude-fill
  [backend-state : be_state.CompilerBackendState]
  [params : compiler_ir_types.CompilerIrParamSeq]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [out : (__tl_dyn-array String)]
  [index : i64]) : i64
  (compiler-backend-param-register-exclude-fill-from
    backend-state
    params
    assignments
    out
    index
    0))

(define (compiler-backend-param-register-exclude
  [backend-state : be_state.CompilerBackendState]
  [params : compiler_ir_types.CompilerIrParamSeq]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]) : (__tl_dyn-array
    String)
  (let
    [n : i64
      (compiler-backend-param-register-exclude-count
        backend-state
        (be_state.compiler-backend-global-shared-view params)
        assignments)]
    [out : (__tl_dyn-array String) (__tl_make-array String n)]
    (compiler-backend-param-register-exclude-fill
      backend-state
      params
      assignments
      (be_state.compiler-backend-global-shared-view out)
      0)
    out))

;; The fixed-register exclude superset [rax,rdx,rcx] PLUS one more already-chosen
;; register (so a second scavenge at the same point avoids it). Pooled scratch
;; registers such as r10/r11 stay available unless the caller passes one as
;; `extra`.
(define (compiler-backend-scavenge-exclude-with [extra : String]) : (__tl_dyn-array
    String)
  (__tl_make-array "%rax" "%rdx" "%rcx" "" "" extra))

(define compiler-backend-c-abi-stage-exclude-count : i64
  8)

;; c-abi-stage-exclude plus one already-chosen scratch (so a 2nd scavenge differs).
(define (compiler-backend-c-abi-stage-exclude-with [extra : String]) : (__tl_dyn-array
    String)
  (let
    [a : (__tl_dyn-array String)
      (__tl_make-array String compiler-backend-c-abi-stage-exclude-count)]
    (set! (array-ref a 0) "%rax")
    (set! (array-ref a 1) "%rcx")
    (set! (array-ref a 2) "%rdx")
    (set! (array-ref a 3) "%r8")
    (set! (array-ref a 4) "%r9")
    (set! (array-ref a 5) "%rdi")
    (set! (array-ref a 6) "%rsi")
    (set! (array-ref a 7) extra)
    a))

(define (compiler-backend-copy-chunk-size [remaining : i64]) : i64
  (cond [(>= remaining 8) 8] [(>= remaining 4) 4] [(>= remaining 2) 2] [else 1]))

(define (compiler-backend-copy-chunk-type [chunk : i64]) : compiler_ast_types.AstType
  (cond [(= chunk 8) (U64)] [(= chunk 4) (U32)] [(= chunk 2) (U16)] [else (U8)]))

;; ===========================================================================
;; Shared copy thunks
;;
;; A 16-byte chunk pair costs 8-12 bytes inline and the same few shapes
;; (`(reg),%xmm2` then `%xmm2,(reg)`, `16(reg)` and `16(reg)`, ...) repeat all
;; over a program. A chunk run at or above
;; `compiler-backend-copy-thunk-min-bytes` therefore emits ONE 5-byte `call`
;; to a thunk emitted once per emission, and the thunk holds exactly the
;; inline `movups` sequence it replaces, tail included. The thunk is a leaf:
;; it reads only its base registers, writes only the scratch xmm and GPR the
;; inline sequence already wrote, touches no flags and no stack, and ends in
;; `ret`. A call site therefore has the inline sequence's exact clobber set.
;;
;; A thunk is keyed by the byte count, the src/dst/gp base SPELLINGS, both
;; displacements, the type-segment basis and the scratch xmm -- i.e. by the
;; emitted text itself, so two sites share a thunk only where their inline
;; bytes would be identical. The displacements ride the key instead of being
;; adjusted at the call site: a site cannot adjust them without paying an
;; instruction of its own.
;;
;; Where the call may go is a property of the CALLER's frame, not of the
;; copy. `compiler-backend-copy-thunk-applies?` requires the function's IR to
;; contain a returning call (see that flag's comment), so the final text keeps
;; a returning call (the census behind `call-align-needed`), which is exactly
;; what denies a red-zone frame and what makes `fpo-bare-frame` false -- so
;; the hosting frame keeps `%rsp % 16 == 0` at this call the same way it
;; already does at its own calls. Frame-base operands (`%rsp`/`%rbp`
;; spellings) are refused: chunk addresses are emitted before the rsp-rebase
;; pass rewrites the function's frame references, so those displacements are
;; not final here and a thunk could not carry them.
;;
;; The threshold trades text bytes against two instructions of run-time
;; overhead per executed site (`call` plus the thunk's `ret`): a longer run
;; saves more inline bytes per call and is executed no more often, so the
;; chosen value is the smallest run whose byte saving still pays for those two
;; instructions across a whole program.
;; Canonical per-size copy thunks. Each thunk copies `remaining` bytes (with
;; `remaining % 4 == 0`) from 0(c_src) to 0(c_dst) using `movups` (16 B),
;; `movsd` (8 B), and `movss` (4 B) through a single volatile XMM scratch, then
;; returns. The thunk never writes `c_src`, `c_dst`, flags, stack, or any GP
;; scratch register, so keys depend only on `(bytes, c_src, c_dst, c_xmm)`.
;;
;; Call sites materialize `(src + src-disp, dst + dst-disp)` into a free
;; volatile pair before `rsp-rebase`, so `%rbp` value homes, frame slots,
;; constant displacements, and SIB spellings all share the same canonical thunk.
;;
;; Thresholds:
;; - `-O2` in loop blocks: `>= 64 B` (with `<= 104 B` 2-setup-move copies kept
;;   inline to avoid per-iteration setup+call+ret overhead).
;; - `-O2` outside loops: `>= 56 B` always, and `48..52 B` when setup-cost == 0.
;; - `-Os` everywhere: `>= 32 B` (subject to per-site byte profitability and
;;   program-wide multiplicity >= 3 so small binaries never inflate).
(define compiler-backend-copy-thunk-loop-min-bytes : i64
  64)
(define compiler-backend-copy-thunk-min-bytes : i64
  48)
(define compiler-backend-copy-thunk-size-opt-min-bytes : i64
  32)

;; Buckets `0..127` count `CopyBytes` sizes `4*i` (`0..508 B`); bucket `128`
;; counts `>= 512 B`. Allocated inside `copy-thunk-arena` per program emission.
(define compiler-backend-copy-thunk-size-bucket-max : i64
  128)

;; Provisioned thunk table size. Past it, copies stay inline: the cap keeps
;; the per-emission table a fixed allocation and the decision local.
(define compiler-backend-copy-thunk-capacity : i64
  8192)

(define (compiler-backend-state-copy-thunks
  [state : be_state.CompilerBackendState]) : backend_string_i64_map.Map
  (let
    [data : be_state.CompilerBackendStateData
      (be_state.compiler-backend-state-data state)]
    data.copy-thunks))

(define (compiler-backend-state-set-copy-thunks!
  [state : be_state.CompilerBackendState]
  [thunks : backend_string_i64_map.Map]) : unit
  (unsafe
    (set!
      (deref (be_state.compiler-backend-state-ptr state)).copy-thunks
      thunks)))

(define (compiler-backend-state-copy-thunk-bodies
  [state : be_state.CompilerBackendState]) : (__tl_dyn-array String)
  (let
    [data : be_state.CompilerBackendStateData
      (be_state.compiler-backend-state-data state)]
    data.copy-thunk-bodies))

(define (compiler-backend-state-copy-thunk-count
  [state : be_state.CompilerBackendState]) : i64
  (let
    [data : be_state.CompilerBackendStateData
      (be_state.compiler-backend-state-data state)]
    data.copy-thunk-count))

(define (compiler-backend-state-set-copy-thunk-count!
  [state : be_state.CompilerBackendState]
  [count : i64]) : unit
  (unsafe
    (set!
      (deref (be_state.compiler-backend-state-ptr state)).copy-thunk-count
      count)))

(define (compiler-backend-copy-thunk-size-bucket [bytes : i64]) : i64
  (let
    [idx : i64 (/ bytes 4)]
    (if (> idx compiler-backend-copy-thunk-size-bucket-max)
      compiler-backend-copy-thunk-size-bucket-max
      idx)))

(define (compiler-backend-copy-thunk-size-count
  [state : be_state.CompilerBackendState]
  [bytes : i64]) : i64
  (let
    [data : be_state.CompilerBackendStateData
      (be_state.compiler-backend-state-data state)]
    [counts : (__tl_dyn-array i64) data.copy-thunk-size-counts]
    [len : i64 (array-length counts)]
    (if (= len 0)
      2
      (let
        [bucket : i64 (compiler-backend-copy-thunk-size-bucket bytes)]
        (if (and (>= bucket 0) (< bucket len))
          (array-ref counts bucket)
          0)))))

(define (compiler-backend-copy-thunk-registered?
  [key : (& str)]
  [backend-state : be_state.CompilerBackendState]) : bool
  (let
    [seen : backend_string_i64_map.Map
      (compiler-backend-state-copy-thunks backend-state)]
    (match (backend_string_i64_map.get-borrowed (& seen) key)
      [(LookupFound _) true]
      [(LookupMissing) false])))

(define (compiler-backend-copy-thunk-min-threshold
  [backend-state : be_state.CompilerBackendState]) : i64
  (if (be_state.compiler-backend-state-optimize-for-size? backend-state)
    compiler-backend-copy-thunk-size-opt-min-bytes
    (let
      [fn-state : be_state.CompilerBackendFunctionState
        (be_state.compiler-backend-state-function-state backend-state)]
      [cur-label : i64
        (be_state.compiler-backend-function-state-i64
          fn-state
          be_state.compiler-backend-function-i64-current-block-label)]
      (if (be_state.compiler-backend-function-loop-block? fn-state cur-label)
        compiler-backend-copy-thunk-loop-min-bytes
        compiler-backend-copy-thunk-min-bytes))))

(define (compiler-backend-copy-thunk-applies?
  [remaining : i64]
  [backend-state : be_state.CompilerBackendState]) : bool
  (let
    [fn-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [occupied-masks : (__tl_dyn-array i64)
      (be_state.compiler-backend-function-scratch-i64-array
        fn-state
        be_state.compiler-backend-scratch-i64-array-scavenge-occupied-masks)]
    [opt-size? : bool
      (be_state.compiler-backend-state-optimize-for-size? backend-state)]
    [min-sites : i64
      (cond
        [(>= remaining compiler-backend-copy-thunk-loop-min-bytes) 2]
        [opt-size? 3]
        [(>= remaining 56) 8]
        [else 32])]
    (and
      (>= remaining (compiler-backend-copy-thunk-min-threshold backend-state))
      (= (% remaining 4) 0)
      (not (compiler_ir_types.compiler-debug-info-enabled?))
      (be_state.compiler-backend-function-state-bool?
        fn-state
        be_state.compiler-backend-function-bool-has-returning-call)
      (> (array-length occupied-masks) 0)
      (>=
        (compiler-backend-copy-thunk-size-count backend-state remaining)
        min-sites)
      (<
        (compiler-backend-state-copy-thunk-count backend-state)
        compiler-backend-copy-thunk-capacity))))

;; Emit the body of a canonical thunk for `remaining` bytes (`remaining % 4 == 0`)
;; copying `0(src-reg)` -> `dst-bias(dst-reg)` using only `xmm-scratch`
;; (`movups`, `movsd`, `movss`). Neither `src-reg`, `dst-reg`, flags, nor any
;; other GP register is written.
(define (compiler-backend-emit-copy-bytes-chunks-canonical
  [dst-reg : (& str)]
  [src-reg : (& str)]
  [xmm-scratch : (& str)]
  [offset : i64]
  [remaining : i64]
  [dst-bias : i64]) : String
  (if (<= remaining 0)
    ""
    (let
      [src-disp : String
        (if (= offset 0)
          ""
          (string.int->string offset))]
      [dst-off : i64 (+ offset dst-bias)]
      [dst-disp : String
        (if (= dst-off 0)
          ""
          (string.int->string dst-off))]
      (cond
        [(>= remaining 16)
          (str_cat.str-cat
            (str_cat.str-cat
              "    movups "
              src-disp
              "("
              src-reg
              "), "
              xmm-scratch
              "\n")
            (str_cat.str-cat
              "    movups "
              xmm-scratch
              ", "
              dst-disp
              "("
              dst-reg
              ")\n")
            (compiler-backend-emit-copy-bytes-chunks-canonical
              dst-reg
              src-reg
              xmm-scratch
              (+ offset 16)
              (- remaining 16)
              dst-bias))]
        [(>= remaining 8)
          (str_cat.str-cat
            (str_cat.str-cat
              "    movsd "
              src-disp
              "("
              src-reg
              "), "
              xmm-scratch
              "\n")
            (str_cat.str-cat
              "    movsd "
              xmm-scratch
              ", "
              dst-disp
              "("
              dst-reg
              ")\n")
            (compiler-backend-emit-copy-bytes-chunks-canonical
              dst-reg
              src-reg
              xmm-scratch
              (+ offset 8)
              (- remaining 8)
              dst-bias))]
        [else
          (str_cat.str-cat
            (str_cat.str-cat
              "    movss "
              src-disp
              "("
              src-reg
              "), "
              xmm-scratch
              "\n")
            (str_cat.str-cat
              "    movss "
              xmm-scratch
              ", "
              dst-disp
              "("
              dst-reg
              ")\n"))]))))

;; Register `key`'s thunk (its instruction text is `body`) and return the
;; symbol to call. The index is the registration order, so the symbols and the
;; emitted program text depend only on emission order.
(define (compiler-backend-copy-thunk-register
  [key : String]
  [body : String]
  [backend-state : be_state.CompilerBackendState]) : String
  (let
    [seen : backend_string_i64_map.Map
      (compiler-backend-state-copy-thunks backend-state)]
    (match (backend_string_i64_map.get-borrowed (& seen) (& key))
      [(LookupFound index)
        (str_cat.str-cat "tl_copy_chunks_" (string.int->string index))]
      [(LookupMissing)
        (let
          [index : i64 (compiler-backend-state-copy-thunk-count backend-state)]
          [bodies : (__tl_dyn-array String)
            (compiler-backend-state-copy-thunk-bodies backend-state)]
          (if (< index (array-length bodies))
            (set! (array-ref bodies index) body)
            (__tl_array-push! bodies body))
          (backend_string_i64_map.insert-ref! (&mut seen) key index)
          (compiler-backend-state-set-copy-thunks! backend-state seen)
          (compiler-backend-state-set-copy-thunk-count!
            backend-state
            (+ index 1))
          (str_cat.str-cat "tl_copy_chunks_" (string.int->string index)))])))

;; The emission's thunk text, in registration order, as a run of leaf
;; functions in the ordinary executable section. Debug/backtrace emissions
;; never register a thunk (`compiler-backend-copy-thunk-applies?`), so no
;; `.cfi` or backtrace row describes code whose crash site has no source line.
(define (compiler-backend-copy-thunk-text
  [program-index : be_state.CompilerBackendProgramIndex]) : String
  (if (<=
    (compiler-backend-state-copy-thunk-count program-index.backend-state)
    0)
    ""
    (let
      [bodies : (__tl_dyn-array String)
        (compiler-backend-state-copy-thunk-bodies program-index.backend-state)]
      [buf : text_buf.TextBuf (text_buf.append (text_buf.empty) "    .text\n")]
      (for [index
        (iterator.range
          0
          (compiler-backend-state-copy-thunk-count program-index.backend-state))]
        (set!
          buf
          (text_buf.append
            (text_buf.append
              (text_buf.append
                (text_buf.append buf "tl_copy_chunks_")
                (string.int->string index))
              ":\n")
            (str_cat.str-cat
              (owned_view.compiler-owned-element-view (& bodies) index)
              "    ret\n"))))
      (text_buf.render buf))))

;; GAP2a: `dst-bias` is a constant displacement added to every DST chunk
;; address (src addresses stay at `offset`). A fused Gep+CopyBytes folds its
;; gep displacement here instead of `addq $disp` on a staged base copy, so a
;; register-homed base serves as the store base directly. Callers guarantee
;; dst-bias + remaining fits imm32; plain copies pass 0 (byte-identical).
;;
;; CONTRACT: `dst-reg` and `src-reg` are memory-operand BASE SPELLINGS, not
;; necessarily bare registers. They reach the output only through
;; `compiler-backend-copy-address`, which parenthesizes the spelling and
;; prefixes the displacement, so a `base,index,scale` SIB triple renders as
;; `disp(base,index,scale)` through the same path a register renders as
;; `disp(%reg)`. `compiler-backend-copy-gep-element-spelling` relies on this to
;; address a fused gep element without materializing it. Any future use of
;; either parameter as a register (sizing it, comparing it to a home, emitting
;; it as an operand) must first reject the SIB form.
(define (compiler-backend-emit-copy-bytes-chunks-inline
  [type-segment-bases : i64]
  [dst-reg : String]
  [src-reg : String]
  [gp-scratch : String]
  [xmm-scratch : String]
  [offset : i64]
  [remaining : i64]
  [dst-bias : i64]) : String
  (if (<= remaining 0)
    ""
    (if (and (>= remaining 16) (> (string.string-length xmm-scratch) 0))
      (str_cat.str-cat
        (str_cat.str-cat
          "    movups "
          (be_facts.compiler-backend-copy-address
            offset
            (be_state.compiler-backend-global-shared-view src-reg))
          ", "
          xmm-scratch
          "\n"
          "")
        (str_cat.str-cat
          "    movups "
          xmm-scratch
          ", "
          (be_facts.compiler-backend-copy-address
            (+ dst-bias offset)
            (be_state.compiler-backend-global-shared-view dst-reg))
          "\n"
          "")
        (compiler-backend-emit-copy-bytes-chunks-inline
          type-segment-bases
          dst-reg
          src-reg
          gp-scratch
          xmm-scratch
          (+ offset 16)
          (- remaining 16)
          dst-bias))
      (let
        [chunk : i64 (compiler-backend-copy-chunk-size remaining)]
        [chunk-ty : compiler_ast_types.AstType
          (compiler-backend-copy-chunk-type chunk)]
        [reg : String
          (be_operand.compiler-backend-sized-reg
            type-segment-bases
            (be_state.compiler-backend-global-shared-view gp-scratch)
            (be_state.compiler-backend-global-shared-view chunk-ty))]
        (str_cat.str-cat
          (str_cat.str-cat
            "    mov"
            (be_operand.compiler-backend-int-instruction-suffix
              type-segment-bases
              (be_state.compiler-backend-global-shared-view chunk-ty))
            " "
            (be_facts.compiler-backend-copy-address
              offset
              (be_state.compiler-backend-global-shared-view src-reg))
            ", ")
          reg
          "\n"
          (str_cat.str-cat
            "    mov"
            (be_operand.compiler-backend-int-instruction-suffix
              type-segment-bases
              chunk-ty)
            " "
            reg
            ", ")
          (be_facts.compiler-backend-copy-address
            (+ dst-bias offset)
            (be_state.compiler-backend-global-shared-view dst-reg))
          "\n"
          (compiler-backend-emit-copy-bytes-chunks-inline
            type-segment-bases
            dst-reg
            src-reg
            gp-scratch
            xmm-scratch
            (+ offset chunk)
            (- remaining chunk)
            dst-bias))))))

(define (compiler-backend-c-memory-stack-dst-address
  [base-offset : i64]
  [copy-offset : i64]) : String
  (str_cat.str-cat
    (string.int->string (+ base-offset copy-offset))
    "(%rsp)"
    ""
    ""))

(define (compiler-backend-c-memory-stack-xmm-mnemonic [chunk : i64]) : String
  (if (>= chunk 8)
    "movq"
    "movd"))

(define (compiler-backend-emit-c-memory-stack-copy-chunks
  [type-segment-bases : i64]
  [dst-offset : i64]
  [src-reg : String]
  [xmm-scratch : String]
  [copy-offset : i64]
  [remaining : i64]) : String
  (if (<= remaining 0)
    ""
    (if (>= remaining 16)
      (str_cat.str-cat
        (str_cat.str-cat
          "    movups "
          (be_facts.compiler-backend-copy-address
            copy-offset
            (be_state.compiler-backend-global-shared-view src-reg))
          ", "
          xmm-scratch
          "\n")
        (str_cat.str-cat
          (str_cat.str-cat
            "    movups "
            xmm-scratch
            ", "
            (compiler-backend-c-memory-stack-dst-address dst-offset copy-offset)
            "\n")
          (compiler-backend-emit-c-memory-stack-copy-chunks
            type-segment-bases
            dst-offset
            src-reg
            xmm-scratch
            (+ copy-offset 16)
            (- remaining 16))))
      (let
        [chunk : i64 (compiler-backend-copy-chunk-size remaining)]
        (if (< chunk 4)
          ;; XMM `movd` is a four-byte transfer even when the logical tail is
          ;; one or two bytes.  Use the low GP sub-register of the source-stage
          ;; register (`src-reg`) for an exact tail transfer.  When a further
          ;; chunk follows, preserve and restore that stage pointer in
          ;; `xmm-scratch` so no additional GP scratch is needed.
          (let
            [chunk-ty : compiler_ast_types.AstType
              (compiler-backend-copy-chunk-type chunk)]
            [suffix : String
              (be_operand.compiler-backend-int-instruction-suffix
                type-segment-bases
                (be_state.compiler-backend-global-shared-view chunk-ty))]
            [part : String
              (be_operand.compiler-backend-sized-reg
                type-segment-bases
                (be_state.compiler-backend-global-shared-view src-reg)
                chunk-ty)]
            [preserve? : bool (> remaining chunk)]
            (str_cat.str-cat
              (if preserve?
                (str_cat.str-cat "    movq " src-reg ", " xmm-scratch "\n")
                "")
              "    mov"
              suffix
              " "
              (be_facts.compiler-backend-copy-address
                copy-offset
                (be_state.compiler-backend-global-shared-view src-reg))
              ", "
              part
              "\n"
              "    mov"
              suffix
              " "
              part
              ", "
              (compiler-backend-c-memory-stack-dst-address
                dst-offset
                copy-offset)
              "\n"
              (if preserve?
                (str_cat.str-cat "    movq " xmm-scratch ", " src-reg "\n")
                "")
              (compiler-backend-emit-c-memory-stack-copy-chunks
                type-segment-bases
                dst-offset
                src-reg
                xmm-scratch
                (+ copy-offset chunk)
                (- remaining chunk))))
          (let
            [mnemonic : String
              (compiler-backend-c-memory-stack-xmm-mnemonic chunk)]
            (str_cat.str-cat
              (str_cat.str-cat
                "    "
                mnemonic
                " "
                (be_facts.compiler-backend-copy-address
                  copy-offset
                  (be_state.compiler-backend-global-shared-view src-reg))
                ", "
                xmm-scratch
                "\n")
              (str_cat.str-cat
                (str_cat.str-cat
                  "    "
                  mnemonic
                  " "
                  xmm-scratch
                  ", "
                  (compiler-backend-c-memory-stack-dst-address
                    dst-offset
                    copy-offset)
                  "\n")
                (compiler-backend-emit-c-memory-stack-copy-chunks
                  type-segment-bases
                  dst-offset
                  src-reg
                  xmm-scratch
                  (+ copy-offset chunk)
                  (- remaining chunk))))))))))

(define (compiler-backend-copy-run-protect-value-count
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : (& compiler_ir_types.CompilerIrValue)]) : i64
  (if (string.eq
    (be_operand.compiler-backend-value-scalar-register
      backend-state
      assignments
      value)
    "")
    0
    1))

;; Scans the CopyBytes/Gep/StorePtr run starting at the cursor and stops at the
;; first instruction of any other shape, exactly as the cons walk did.
(define (compiler-backend-copy-run-protect-count
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [instrs : (& compiler_ir_types.CompilerIrInstrSeq)]
  [index : i64]) : i64
  (if (>= index instrs.len)
    0
    (match (compiler_ir_types.compiler-ir-instr-seq-ref instrs index)
      [(or (CopyBytes dst src _) (Gep _ dst src _) (StorePtr dst src _))
        (+
          (compiler-backend-copy-run-protect-value-count
            backend-state
            assignments
            dst)
          (+
            (compiler-backend-copy-run-protect-value-count
              backend-state
              assignments
              src)
            (compiler-backend-copy-run-protect-count
              backend-state
              assignments
              instrs
              (+ index 1))))]
      [_ 0])))

(define (compiler-backend-copy-run-protect-fill-value
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : (& compiler_ir_types.CompilerIrValue)]
  [out : (&mut out (__tl_dyn-array String))]
  [index : i64]) : i64
  (let
    [home : String
      (be_operand.compiler-backend-value-scalar-register
        backend-state
        assignments
        value)]
    (if (string.eq home "")
      index
      (begin
        (set! (array-ref out index) (str_cat.str-cat home ""))
        (+ index 1)))))

(define (compiler-backend-copy-run-protect-fill
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [instrs : (& compiler_ir_types.CompilerIrInstrSeq)]
  [cursor : i64]
  [out : (&mut out (__tl_dyn-array String))]
  [index : i64]) : i64
  (if (< cursor instrs.len)
    (let
      [instr (compiler_ir_types.compiler-ir-instr-seq-ref instrs cursor)]
      [rest : i64 (+ cursor 1)]
      (match instr
        [(or (CopyBytes dst src _) (Gep _ dst src _) (StorePtr dst src _))
          (compiler-backend-copy-run-protect-fill
            backend-state
            assignments
            instrs
            rest
            out
            (compiler-backend-copy-run-protect-fill-value
              backend-state
              assignments
              src
              out
              (compiler-backend-copy-run-protect-fill-value
                backend-state
                assignments
                dst
                out
                index)))]
        [_ index]))
    index))

(define (compiler-backend-copy-run-protect-exclude
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]
  [index : i64]) : (__tl_dyn-array String)
  (let
    [n : i64
      (compiler-backend-copy-run-protect-count
        backend-state
        assignments
        instrs
        index)]
    [out : (__tl_dyn-array String) (__tl_make-array String n)]
    (compiler-backend-copy-run-protect-fill
      backend-state
      assignments
      instrs
      index
      (&mut out)
      0)
    out))

;; --- gep element addressing folded into the copy chunks --------------------
;; A fused Gep+CopyBytes need not COMPOSE the element address into a register
;; (`leaq (base,index,scale), %r`) and then address every chunk off `(%r)`. A
;; register-homed base and index under a SIB scale make that register
;; unnecessary: each chunk spells `disp(base,index,scale)` itself and the leaq
;; disappears. The two emitters below apply that on each side --
;; `-gep-src` where the element is the copy SOURCE (`(array-ref xs i)` on a
;; multi-word struct) and `-gep-dst` where it
;; is the DESTINATION (the staged half of
;; `compiler-backend-emit-copy-bytes-from-gep-dyn`).
;;
;; REGISTER SAFETY. The chunk copies write only the xmm/gp scratch and the
;; destination MEMORY; base and index are read, never written, so their homes
;; stay valid across every chunk and no live range is extended -- the fold is
;; sound against the register plan already in force. The scavenge exclusions in
;; each emitter additionally keep the staged pointer and the gp scratch off both
;; operand homes.
;;
;; ORDINAL SAFETY. Admission is decided from the scale, the operand homes and
;; the size ALONE -- never from the GAP9 displacement -- so a declined shape
;; leaves `compiler-backend-gep-fold-next!` for the ordinary gep emission to
;; consume exactly once. `compiler-backend-gep-fold-k-bound` bounds a folded
;; displacement far below imm32, so every chunk address stays encodable.
;; The chunk base SPELLING for a fused gep element: a `base,index,scale` SIB
;; triple, or "" to decline. The spelling is consumed by
;; `compiler-backend-mem-base-address`, which parenthesizes it and prefixes the
;; displacement, so it renders through the ordinary chunk address path.
;;
;; #rbp-base: `address-base-filter` rejects a %rbp home -- the gep index already
;; occupies the SIB index slot, so it cannot also take the base slot. A %rbp
;; INDEX is admitted, as at every other dynamic gep site: the FPO rsp-rebase
;; pass and the peephole slot recognizers key frame slots on the `(%rbp)` base
;; spelling, which `(base,%rbp,scale)` does not match.
;;
;; CONSTANT gep offsets are admitted through a BOUND, never through the GAP9
;; displacement. Their element address is `disp(base)` with `disp = n * scale`
;; read straight off the instruction, so the chunk addresses span
;; `[disp, disp + size)`. The GAP9 fold contributes nothing to a constant
;; offset -- `compiler-backend-gep-fold-rewrite-seq` records displacement 0 for
;; every non-Var offset kind -- but admission still must not READ that entry
;; (reading is consuming), so it charges the fold's own magnitude cap,
;; `compiler-backend-gep-fold-k-bound`, against the range instead. `n` is
;; range-checked before the multiply and `scale` is a type size, so the product
;; and the sum below are computed without overflow. A declined shape emits
;; exactly once.
(define (compiler-backend-copy-gep-const-disp-ok?
  [n : i64]
  [scale : i64]
  [size : i64]) : bool
  (if (and
    (be_operand.compiler-backend-imm32? n)
    (> scale 0)
    (< scale 65536)
    (>= size 0)
    (< size 65536))
    (let
      [disp : i64 (* n scale)]
      [slack : i64 (+ size (compiler-backend-gep-fold-k-bound))]
      (and
        (be_operand.compiler-backend-imm32? (+ disp slack))
        (be_operand.compiler-backend-imm32? (- disp slack))))
    false))

(define (compiler-backend-copy-gep-element-spelling
  [backend-state : be_state.CompilerBackendState]
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [base : compiler_ir_types.CompilerIrValue]
  [offset : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [size : i64]) : String
  (if (<= size 0)
    ""
    (match (be_operand.compiler-backend-value-as-i64 offset)
      [(Some n)
        ;; Constant index: the element address is the base home alone, with the
        ;; whole displacement carried by the chunk addresses. The base occupies
        ;; the operand's BASE slot ALONE, so GAP7 admits a %rbp home here (spelled
        ;; `disp( %rbp)` by compiler-backend-mem-base-address) exactly as at the
        ;; other const-offset fused gep sites.
        (let
          [scale : i64
            (be_operand.compiler-backend-type-size type-segment-bases elem-ty)]
          [base-home : String
            (be_facts.compiler-backend-address-base-filter-direct
              (be_operand.compiler-backend-value-scalar-register
                backend-state
                assignments
                base))]
          (if (and
            (not (string.eq base-home ""))
            (compiler-backend-copy-gep-const-disp-ok? n scale size))
            base-home
            ""))]
      [(None)
        (let
          [scale : i64
            (be_operand.compiler-backend-type-size type-segment-bases elem-ty)]
          [base-home : String
            (compiler-backend-address-base-filter
              (be_operand.compiler-backend-value-scalar-register
                backend-state
                assignments
                base))]
          [offset-home : String
            (be_operand.compiler-backend-value-scalar-register
              backend-state
              assignments
              offset)]
          (if (and
            (compiler-backend-gep-sib-scale? scale)
            (not (string.eq base-home ""))
            (not (string.eq offset-home "")))
            (str_cat.str-cat
              base-home
              ","
              offset-home
              ","
              (string.int->string scale))
            ""))])))

;; Compose the dynamic gep element address into scav-base for the fused copy.
;; Direct forms read the operand homes only (leaq/addq never write them); the
;; staged index scratch is scavenged only on the path that needs it, so no
;; dead pick can trigger an emergency spill.
(define (compiler-backend-emit-copy-gep-dyn-address
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [base : compiler_ir_types.CompilerIrValue]
  [offset : compiler_ir_types.CompilerIrValue]
  [scale : i64]
  [scav-base : String]
  [base-home : String]
  [offset-home : String]
  [src-home : String]
  [protect : (& protect (__tl_dyn-array String))]
  [protect-n : i64]
  [gep-disp : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (and
    (not (string.eq base-home ""))
    (not (string.eq offset-home ""))
    (compiler-backend-gep-sib-scale? scale))
    (Ok
      (str_cat.str-cat
        "    leaq "
        (compiler-backend-gep-index-address-disp
          gep-disp
          base-home
          scale
          offset-home)
        ", "
        scav-base
        "\n"))
    (let
      [base-asm
        (try
          (be_operand.compiler-backend-emit-load-value
            assignments
            base
            (be_state.compiler-backend-global-shared-view scav-base)
            backend-state))]
      (if (and
        (not (string.eq offset-home ""))
        (compiler-backend-gep-sib-scale? scale))
        (Ok
          (str_cat.str-cat
            base-asm
            (compiler-backend-gep-index-base-asm-disp
              gep-disp
              scav-base
              scale
              offset-home)))
        ;; index scratch: avoid scav-base (live) + src's home (loaded later) +
        ;; the active set. Scavenged only on this path so a dead pick never
        ;; triggers an emergency spill.
        (let
          [scav-idx : String
            (be_operand.compiler-backend-scavenge-reg-here
              (compiler-backend-scavenge-exclude-merge
                (be_operand.compiler-backend-two-exclude
                  (be_state.compiler-backend-global-shared-view scav-base)
                  src-home)
                2
                protect
                protect-n)
              (+ 2 protect-n)
              "%r8"
              backend-state)]
          [offset-asm
            (try
              (be_operand.compiler-backend-emit-load-value
                assignments
                offset
                (be_state.compiler-backend-global-shared-view scav-idx)
                backend-state))]
          (Ok
            (str_cat.str-cat
              base-asm
              (str_cat.str-cat
                offset-asm
                (compiler-backend-gep-index-base-asm-disp
                  gep-disp
                  scav-base
                  scale
                  scav-idx)))))))))

(define (compiler-backend-emit-c-memory-stack-arg
  [type-segment-bases : i64]
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [value : compiler_ir_types.CompilerIrValue]
  [stack-idx : i64]
  [size : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [dst-offset : i64
      (be_facts.compiler-backend-outgoing-stack-arg-offset
        target
        convention
        stack-idx)]
    [src-reg : String (compiler-backend-stack-call-arg-stage backend-state)]
    [copy-xmm : String
      (let
        [no-exclude : (__tl_dyn-array String) (__tl_make-array String 0)]
        (be_operand.compiler-backend-scavenge-xmm-reg
          -1
          no-exclude
          0
          "%xmm2"
          backend-state))]
    [src-asm
      (try
        (be_operand.compiler-backend-emit-load-value
          assignments
          value
          (be_state.compiler-backend-global-shared-view src-reg)
          backend-state))]
    (Ok
      (str_cat.str-cat
        src-asm
        (compiler-backend-emit-c-memory-stack-copy-chunks
          type-segment-bases
          dst-offset
          src-reg
          copy-xmm
          0
          size)))))

(define (compiler-backend-emit-load-from-gep
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [base : compiler_ir_types.CompilerIrValue]
  [offset : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [load-ty : compiler_ast_types.AstType]
  [gep-disp : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [scale : i64
      (be_operand.compiler-backend-type-size type-segment-bases elem-ty)]
    [displacement : option_i64.Option
      (compiler-backend-disp32-displacement offset scale gep-disp)]
    (match displacement
      [(Some disp)
        (let
          ;; IAG-1: an inline aggregate global's field read is a single
          ;; `movq g+k(%rip), %r` -- no base register is materialised at all.
          ;; Probed BEFORE the base scavenge below so a hit costs no pick.
          [rip : String
            (compiler-backend-inline-aggregate-gep-operand
              backend-state
              type-segment-bases
              (be_state.compiler-backend-global-shared-view base)
              offset
              (be_state.compiler-backend-global-shared-view elem-ty)
              gep-disp)]
          ;; gep-disp is 0 here in practice (only Var-index geps carry a folded
          ;; displacement); merged for totality.
          ;; base-reg-in "" -> scavenge our own base (single-load callers); else use
          ;; the caller-supplied register (the gep-pair shares one base across both
          ;; loads so the 2nd doesn't reload).
          ;; M-C2: a register-homed base is used DIRECTLY as the addressing base --
          ;; the constant-offset form only READS it, so no staging copy or scavenge
          ;; is needed (emit-load-value then elides the self-move). A dst
          ;; home equal to the base home is legal: `movq off(%rX), %rX` reads the
          ;; address before writing, and home equality means the allocator proved
          ;; the base value dead after this load.
          [base-home : String
            (if (string.eq rip "")
              (be_facts.compiler-backend-address-base-filter-direct
                (be_operand.compiler-backend-value-scalar-register
                  backend-state
                  assignments
                  base))
              "")]
          [base-reg : String
            (if (not (string.eq rip ""))
              ""
              (if (string.eq base-home "")
                (be_operand.compiler-backend-scavenge-reg
                  dst
                  (be_facts.compiler-backend-addr-scavenge-exclude)
                  0
                  "%r10"
                  backend-state)
                base-home))]
          [addr : String
            (if (not (string.eq rip ""))
              (owned_view.compiler-owned-shared-view rip)
              (compiler-backend-base-address
                disp
                (be_state.compiler-backend-global-shared-view base-reg)))]
          [base-asm
            (try
              (if (string.eq rip "")
                (be_operand.compiler-backend-emit-load-value
                  assignments
                  base
                  (be_state.compiler-backend-global-shared-view base-reg)
                  backend-state)
                (be_state.ResultCompilerBackend.Ok "")))]
          (Ok
            (if (be_operand.compiler-backend-float-type? load-ty)
              (str_cat.str-cat
                base-asm
                (compiler-backend-emit-load-float-address-to-var
                  assignments
                  dst
                  addr
                  load-ty
                  backend-state))
              (str_cat.str-cat
                base-asm
                (compiler-backend-emit-load-scalar-address-to-var
                  type-segment-bases
                  assignments
                  dst
                  addr
                  load-ty
                  (be_operand.compiler-backend-one-exclude base-reg)
                  (if (string.eq rip "")
                    1
                    0)
                  ""
                  backend-state)))))]
      [(None)
        ;; Dynamic-index load. For SIB scales, use allocator-owned operand homes
        ;; directly in the memory operand whenever they exist; copying an already
        ;; register-allocated index into a scavenged temp can clobber unrelated
        ;; live-through registers and creates redundant moves. Non-SIB scales still
        ;; need scratch copies because the fold mutates the base/index registers.
        (let
          [sib-scale? : bool (compiler-backend-gep-sib-scale? scale)]
          ;; BE-2: a %rbp base at scale 1 reads directly, swapped into the SIB
          ;; index slot (compiler-backend-gep-index-address).
          [base-home : String
            (compiler-backend-address-base-filter-sib
              (be_operand.compiler-backend-value-scalar-register
                backend-state
                assignments
                base)
              scale)]
          [offset-home : String
            (be_operand.compiler-backend-value-scalar-register
              backend-state
              assignments
              offset)]
          [use-base-home? : bool
            (and sib-scale? (not (string.eq base-home "")))]
          ;; A gep-PAIR threads a shared base register in via base-reg-in: the
          ;; first load must materialize the base there so the second load can
          ;; reuse it. Single loads can read a register-homed base directly for SIB
          ;; scales, otherwise they scavenge a mutable fold register.
          [base-reg : String
            (if use-base-home?
              base-home
              (be_operand.compiler-backend-scavenge-reg
                dst
                (be_operand.compiler-backend-one-exclude
                  (be_state.compiler-backend-global-shared-view offset-home))
                1
                "%r10"
                backend-state))]
          [use-offset-home? : bool
            (and
              sib-scale?
              (not (string.eq offset-home ""))
              (not (string.eq offset-home base-reg)))]
          [index-reg : String
            (if use-offset-home?
              offset-home
              (be_operand.compiler-backend-scavenge-reg
                dst
                (compiler-backend-scavenge-exclude-regs2
                  (be_state.compiler-backend-global-shared-view base-reg)
                  offset-home)
                7
                "%r8"
                backend-state))]
          [addr : String
            (compiler-backend-gep-index-address-disp
              gep-disp
              base-reg
              scale
              index-reg)]
          [addr-asm : String
            (if (string.eq addr "")
              (compiler-backend-gep-index-base-asm-disp
                gep-disp
                base-reg
                scale
                index-reg)
              "")]
          [load-addr : String
            (if (string.eq addr "")
              (str_cat.str-cat "(" base-reg ")" "")
              addr)]
          [base-asm
            (try
              (if use-base-home?
                (be_state.ResultCompilerBackend.Ok "")
                (be_operand.compiler-backend-emit-load-value
                  assignments
                  base
                  (be_state.compiler-backend-global-shared-view base-reg)
                  backend-state)))]
          [offset-asm
            (try
              (if use-offset-home?
                (be_state.ResultCompilerBackend.Ok "")
                (be_operand.compiler-backend-emit-load-value
                  assignments
                  offset
                  (be_state.compiler-backend-global-shared-view index-reg)
                  backend-state)))]
          (Ok
            (if (be_operand.compiler-backend-float-type? load-ty)
              (str_cat.str-cat
                base-asm
                offset-asm
                addr-asm
                (compiler-backend-emit-load-float-address-to-var
                  assignments
                  dst
                  load-addr
                  load-ty
                  backend-state))
              (str_cat.str-cat
                base-asm
                offset-asm
                addr-asm
                (compiler-backend-emit-load-scalar-address-to-var
                  type-segment-bases
                  assignments
                  dst
                  load-addr
                  load-ty
                  (be_operand.compiler-backend-two-exclude base-reg index-reg)
                  2
                  ""
                  backend-state)))))]))
  ;; Evaluate BODY with the pair-emission flag set (the sibling-reordering load
  ;; families), restoring the flag's previous value afterwards.
  )

(defmacro (compiler-backend-with-pair-emission
  [function-state : Expr]
  [body : Expr]) : Expr
  `(let
    [pair-emission-state : be_state.CompilerBackendFunctionState
      ,function-state]
    [pair-emission-prev : bool
      (be_state.compiler-backend-function-scratch-bool?
        pair-emission-state
        be_state.compiler-backend-scratch-bool-pair-emission)]
    [_pair-emission-on : unit
      (be_state.compiler-backend-function-scratch-set-bool!
        pair-emission-state
        be_state.compiler-backend-scratch-bool-pair-emission
        true)]
    [pair-emission-result : be_state.ResultCompilerBackend ,body]
    [_pair-emission-off : unit
      (be_state.compiler-backend-function-scratch-set-bool!
        pair-emission-state
        be_state.compiler-backend-scratch-bool-pair-emission
        pair-emission-prev)]
    pair-emission-result))

;; R4-C wrapper: bracket the reordering family with the pair-emission flag,
;; restoring the caller's value so a nested pair keeps the outer one flagged.
(define (compiler-backend-emit-load-from-gep-pair-first
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [base : compiler_ir_types.CompilerIrValue]
  [offset : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [load-ty : compiler_ast_types.AstType]
  [base-reg : String]
  [sibling-home : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (compiler-backend-with-pair-emission
    (be_state.compiler-backend-state-function-state backend-state)
    (match (be_operand.compiler-backend-value-as-i64 offset)
      [(Some n)
        (let
          [disp : i64
            (*
              n
              (be_operand.compiler-backend-type-size type-segment-bases elem-ty))]
          [addr : String
            (compiler-backend-base-address
              disp
              (be_state.compiler-backend-global-shared-view base-reg))]
          (match (be_operand.compiler-backend-emit-load-value
            assignments
            base
            (be_state.compiler-backend-global-shared-view base-reg)
            backend-state)
            [(Ok base-asm)
              (be_state.ResultCompilerBackend.Ok
                (if (be_operand.compiler-backend-float-type? load-ty)
                  (str_cat.str-cat
                    base-asm
                    (compiler-backend-emit-load-float-address-to-var
                      assignments
                      dst
                      addr
                      load-ty
                      backend-state))
                  (str_cat.str-cat
                    base-asm
                    ;; The pair head's emergency restore runs after both loads; if
                    ;; this spilled first load borrows the sibling result home, the
                    ;; restore clobbers the second load before its consumer.
                    (compiler-backend-emit-load-scalar-address-to-var
                      type-segment-bases
                      assignments
                      dst
                      addr
                      load-ty
                      (if (string.eq sibling-home "")
                        (be_operand.compiler-backend-one-exclude base-reg)
                        (be_operand.compiler-backend-two-exclude
                          base-reg
                          (be_state.compiler-backend-global-shared-view
                            sibling-home)))
                      (if (string.eq sibling-home "")
                        1
                        2)
                      ""
                      backend-state))))]
            [(Err message) (be_state.ResultCompilerBackend.Err message)]))]
      [(None)
        (be_state.ResultCompilerBackend.Err
          (box
            (compiler_diagnostic.compiler-diagnostic-at-start
              ""
              "backend: non-immediate gep pair first load")))])))

;; R4-C wrapper: bracket the reordering family with the pair-emission flag,
;; restoring the caller's value so a nested pair keeps the outer one flagged.
(define (compiler-backend-emit-load-from-gep-r10-live
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [offset : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [load-ty : compiler_ast_types.AstType]
  [base-reg : String]
  [sibling-home : String]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (compiler-backend-with-pair-emission
    (be_state.compiler-backend-state-function-state backend-state)
    (match (be_operand.compiler-backend-value-as-i64 offset)
      [(Some n)
        (let
          [disp : i64
            (*
              n
              (be_operand.compiler-backend-type-size type-segment-bases elem-ty))]
          ;; The base was loaded into base-reg by the 1st load of the pair; reuse it.
          [addr : String
            (compiler-backend-base-address
              disp
              (be_state.compiler-backend-global-shared-view base-reg))]
          (be_state.ResultCompilerBackend.Ok
            (if (be_operand.compiler-backend-float-type? load-ty)
              (compiler-backend-emit-load-float-address-to-var
                assignments
                dst
                addr
                load-ty
                backend-state)
              ;; M-D clobber fix (companion to emit-load-from-gep-pair's base guard):
              ;; a SPILLED 2nd-load dst stages through a scavenged scratch, and this
              ;; whole gep-pair is ONE emergency-wrap head. `sibling-home` is the 1st
              ;; load's register home -- already DEFINED at this point but saved by the
              ;; head's emergency-wrap PROLOGUE (before the def), so an emergency pick
              ;; landing there would be OVERWRITTEN by the wrap's restore, dropping the
              ;; 1st word. Exclude it too; "" (a register-homed sibling absent, or
              ;; itself spilled) keeps the base-only set.
              (compiler-backend-emit-load-scalar-address-to-var
                type-segment-bases
                assignments
                dst
                addr
                load-ty
                (if (string.eq sibling-home "")
                  (be_operand.compiler-backend-one-exclude base-reg)
                  (be_operand.compiler-backend-two-exclude
                    base-reg
                    (be_state.compiler-backend-global-shared-view sibling-home)))
                (if (string.eq sibling-home "")
                  1
                  2)
                ""
                backend-state))))]
      [(None)
        (be_state.ResultCompilerBackend.Err
          (box
            (compiler_diagnostic.compiler-diagnostic-at-start
              ""
              "backend: non-immediate r10-live gep load")))])))

;; R4-C wrapper: bracket the reordering family with the pair-emission flag,
;; restoring the caller's value so a nested pair keeps the outer one flagged.
(define (compiler-backend-emit-load-from-gep-pair
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [base : compiler_ir_types.CompilerIrValue]
  [offset0 : compiler_ir_types.CompilerIrValue]
  [elem-ty0 : compiler_ast_types.AstType]
  [load-dst0 : i64]
  [load-ty0 : compiler_ast_types.AstType]
  [offset1 : compiler_ir_types.CompilerIrValue]
  [elem-ty1 : compiler_ast_types.AstType]
  [load-dst1 : i64]
  [load-ty1 : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (compiler-backend-with-pair-emission
    (be_state.compiler-backend-state-function-state backend-state)
    (let
      ;; Scavenge ONE base register and share it across both loads: the 1st load
      ;; materializes the base into it, the 2nd reuses it (no reload).
      ;;
      ;; M-D clobber fix: EXPLICITLY exclude the SIBLING load's register home.
      ;; scavenge-reg's dst-var only excludes load-dst0's home, and the sibling is
      ;; protected on the free path solely by the staging-window occupancy query --
      ;; which the EMERGENCY path deliberately ignores (everything is occupied when
      ;; it fires). Under full occupancy the emergency scratch could land on
      ;; load-dst1's home; the emergency-wrap restore then overwrites the second
      ;; load's just-defined result. The free path never picks the sibling home
      ;; (occupied in the window), so this exclusion only changes emergency
      ;; picks.
      [dst1-home : String
        (compiler-backend-var-register-home backend-state assignments load-dst1)]
      ;; M-C2: when the shared base is register-homed, address both loads off the
      ;; home directly -- no staging copy (the 1st load's materialization becomes
      ;; an elided self-move) and no scavenge side effects. Guard: the FIRST
      ;; load's dst home must differ from the base home, or load0 would clobber
      ;; the base register load1 still needs. dst1's home MAY equal the base home
      ;; (the 2nd load reads its address operand before writing, and afterwards
      ;; the base register is no longer needed).
      [base-home : String
        (be_facts.compiler-backend-address-base-filter-direct
          (be_operand.compiler-backend-value-scalar-register
            backend-state
            assignments
            base))]
      [dst0-home : String
        (compiler-backend-var-register-home backend-state assignments load-dst0)]
      [base-reg : String
        (if (and
          (not (string.eq base-home ""))
          (not (string.eq base-home dst0-home)))
          base-home
          (be_operand.compiler-backend-scavenge-reg
            load-dst0
            (if (string.eq dst1-home "")
              (be_facts.compiler-backend-addr-scavenge-exclude)
              (be_operand.compiler-backend-one-exclude
                (be_state.compiler-backend-global-shared-view dst1-home)))
            (if (string.eq dst1-home "")
              0
              1)
            "%r10"
            backend-state))]
      (match (compiler-backend-emit-load-from-gep-pair-first
        type-segment-bases
        assignments
        load-dst0
        base
        offset0
        elem-ty0
        load-ty0
        (be_state.compiler-backend-global-shared-view base-reg)
        dst1-home
        backend-state)
        [(Ok first-asm)
          (match (compiler-backend-emit-load-from-gep-r10-live
            type-segment-bases
            assignments
            load-dst1
            offset1
            elem-ty1
            load-ty1
            base-reg
            dst0-home
            backend-state)
            [(Ok second-asm)
              (be_state.ResultCompilerBackend.Ok
                (str_cat.str-cat first-asm second-asm))]
            [(Err message) (be_state.ResultCompilerBackend.Err message)])]
        [(Err message) (be_state.ResultCompilerBackend.Err message)]))))

;; R4-C wrapper: bracket the reordering family with the pair-emission flag,
;; restoring the caller's value so a nested pair keeps the outer one flagged.
(define (compiler-backend-emit-load-load
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [first-dst : i64]
  [ptr : compiler_ir_types.CompilerIrValue]
  [first-ty : compiler_ast_types.AstType]
  [second-dst : i64]
  [second-ty : (& compiler_ast_types.AstType)]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (compiler-backend-with-pair-emission
    (be_state.compiler-backend-state-function-state backend-state)
    (let
      [_first-dst : i64 first-dst]
      (if (=
        (be_operand.compiler-backend-type-size type-segment-bases first-ty)
        8)
        (let
          ;; M-D clobber fix (see emit-load-from-gep-pair): the pointer-chase base
          ;; scratch must not land on second-dst's register home under EMERGENCY
          ;; scavenge -- the wrap restore would overwrite the chased load's result.
          [second-home : String
            (compiler-backend-var-register-home
              backend-state
              assignments
              second-dst)]
          [base : String
            (be_operand.compiler-backend-scavenge-reg-here
              (if (string.eq second-home "")
                (be_facts.compiler-backend-addr-scavenge-exclude)
                (be_operand.compiler-backend-one-exclude
                  (be_state.compiler-backend-global-shared-view second-home)))
              (if (string.eq second-home "")
                0
                1)
              "%r10"
              backend-state)]
          [base-mem : String
            (compiler-backend-base-deref
              (be_state.compiler-backend-global-shared-view base))]
          (match (be_operand.compiler-backend-emit-load-value
            assignments
            ptr
            (be_state.compiler-backend-global-shared-view base)
            backend-state)
            [(Ok ptr-asm)
              (be_state.ResultCompilerBackend.Ok
                (str_cat.str-cat
                  ptr-asm
                  (str_cat.str-cat "    movq " base-mem ", " base "\n")
                  (if (be_operand.compiler-backend-float-type? second-ty)
                    (compiler-backend-emit-load-float-address-to-var
                      assignments
                      second-dst
                      base-mem
                      second-ty
                      backend-state)
                    (compiler-backend-emit-load-scalar-address-to-var
                      type-segment-bases
                      assignments
                      second-dst
                      base-mem
                      second-ty
                      (be_operand.compiler-backend-one-exclude base)
                      1
                      ""
                      backend-state))))]
            [(Err message) (be_state.ResultCompilerBackend.Err message)]))
        (compiler-backend-emit-load-instr
          type-segment-bases
          assignments
          first-dst
          ptr
          first-ty
          backend-state)))))

(define (compiler-backend-emit-store-value-to-address
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [src : (& compiler_ir_types.CompilerIrValue)]
  [ty : (& compiler_ast_types.AstType)]
  [addr : String]
  [program-index : be_state.CompilerBackendProgramIndex]
  [exclude : (__tl_dyn-array String)]
  [exclude-n : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (match (compiler-backend-emit-store-immediate-to-memory
    type-segment-bases
    src
    addr
    ty
    backend-state)
    [(Some store-asm) (Ok store-asm)]
    [(No)
      (if (be_operand.compiler-backend-float-type? ty)
        (let
          [src-home : String
            (compiler-backend-float-value-register
              backend-state
              assignments
              src)]
          [store-reg : String
            (if (string.eq src-home "")
              (be_operand.compiler-backend-scavenge-xmm-reg
                -1
                exclude
                exclude-n
                "%xmm2"
                backend-state)
              (owned_view.compiler-owned-shared-view src-home))]
          [src-asm
            (try
              (if (string.eq src-home "")
                (compiler-backend-emit-load-typed-value-to-reg
                  type-segment-bases
                  assignments
                  src
                  ty
                  (be_state.compiler-backend-global-shared-view store-reg)
                  program-index)
                (be_state.ResultCompilerBackend.Ok "")))]
          (Ok
            (str_cat.str-cat
              src-asm
              (compiler-backend-emit-store-xmm-to-memory
                (string.copy addr)
                store-reg
                ty))))
        (let
          [src-home : String
            (be_operand.compiler-backend-value-scalar-register
              backend-state
              assignments
              src)]
          [store-reg : String
            (if (string.eq src-home "")
              (be_operand.compiler-backend-scavenge-reg-here
                exclude
                exclude-n
                "%r8"
                backend-state)
              (owned_view.compiler-owned-shared-view src-home))]
          [src-asm
            (try
              (if (string.eq src-home "")
                (compiler-backend-emit-load-typed-value-to-reg
                  type-segment-bases
                  assignments
                  src
                  ty
                  (be_state.compiler-backend-global-shared-view store-reg)
                  program-index)
                (be_state.ResultCompilerBackend.Ok "")))]
          (Ok
            (str_cat.str-cat
              src-asm
              (compiler-backend-emit-store-reg-to-memory
                type-segment-bases
                addr
                store-reg
                ty)))))]))

(define (compiler-backend-emit-store-ptr
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : compiler_ir_types.CompilerIrValue]
  [src : compiler_ir_types.CompilerIrValue]
  [ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [dst-home : String
      (be_facts.compiler-backend-value-register-home
        backend-state
        assignments
        dst)]
    [src-home : String
      (be_facts.compiler-backend-value-register-home
        backend-state
        assignments
        src)]
    [scav-base : String
      (be_operand.compiler-backend-scavenge-reg-here
        (be_operand.compiler-backend-two-exclude dst-home src-home)
        2
        "%r10"
        backend-state)]
    [base
      (try
        (compiler-backend-emit-address-base
          assignments
          dst
          scav-base
          program-index.backend-state))]
    [ptr-asm : String base.asm]
    [addr : String
      (be_facts.compiler-backend-copy-address
        0
        (compiler_abi.compiler-abi-register-spelling base.reg))]
    [store-asm
      (try
        (compiler-backend-emit-store-value-to-address
          type-segment-bases
          assignments
          src
          ty
          addr
          program-index
          (be_operand.compiler-backend-one-exclude
            (compiler_abi.compiler-abi-register-spelling base.reg))
          1
          backend-state))]
    (Ok (str_cat.str-cat ptr-asm store-asm))))

(define (compiler-backend-emit-store-to-gep
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [base : compiler_ir_types.CompilerIrValue]
  [offset : compiler_ir_types.CompilerIrValue]
  [elem-ty : compiler_ast_types.AstType]
  [value : (& compiler_ir_types.CompilerIrValue)]
  [store-ty : (& compiler_ast_types.AstType)]
  [program-index : be_state.CompilerBackendProgramIndex]
  [gep-disp : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [scale : i64
      (be_operand.compiler-backend-type-size type-segment-bases elem-ty)]
    [displacement : option_i64.Option
      (compiler-backend-disp32-displacement offset scale gep-disp)]
    (match displacement
      [(Some disp)
        (let
          ;; gep-disp is 0 here in practice (only Var-index geps carry a folded
          ;; displacement); merged for totality.
          [base-home : String
            (be_facts.compiler-backend-value-register-home
              backend-state
              assignments
              base)]
          [value-home : String
            (be_facts.compiler-backend-value-register-home
              backend-state
              assignments
              value)]
          [scav-base : String
            (be_operand.compiler-backend-scavenge-reg-here
              (be_operand.compiler-backend-two-exclude base-home value-home)
              2
              "%r10"
              backend-state)]
          [base-plan
            (try
              (compiler-backend-emit-address-base
                assignments
                base
                scav-base
                program-index.backend-state))]
          [base-asm : String base-plan.asm]
          [addr : String
            (be_facts.compiler-backend-copy-address
              disp
              (compiler_abi.compiler-abi-register-spelling base-plan.reg))]
          [store-asm
            (try
              (compiler-backend-emit-store-value-to-address
                type-segment-bases
                assignments
                value
                store-ty
                addr
                program-index
                (be_operand.compiler-backend-one-exclude
                  (compiler_abi.compiler-abi-register-spelling base-plan.reg))
                1
                backend-state))]
          (Ok (str_cat.str-cat base-asm store-asm)))]
      [(None)
        (let
          [value-home : String
            (be_operand.compiler-backend-value-scalar-register
              backend-state
              assignments
              value)]
          ;; BE-2: a %rbp base at scale 1 spells directly, swapped into the SIB
          ;; index slot (compiler-backend-gep-index-address).
          [base-home : String
            (compiler-backend-address-base-filter-sib
              (be_operand.compiler-backend-value-scalar-register
                backend-state
                assignments
                base)
              scale)]
          [offset-home : String
            (be_operand.compiler-backend-value-scalar-register
              backend-state
              assignments
              offset)]
          ;; M-G (B2, M-C2 for stores): base AND index both register-homed with a
          ;; SIB-encodable scale -> address them directly (`mov src, (base,idx,s)`),
          ;; skipping the index staging copy (`movq <idx-home>, %rSCAV`) AND both
          ;; scavenge picks -- under full occupancy those picks force the
          ;; emergency save/restore wrap around the store (the vm_run pattern:
          ;; `movq %r10,-N(%rbp); movq %rsi,%r11; movq %rax,(%rdi,%r11,8);
          ;; movq -N(%rbp),%r10`). The store writes only memory, so reading the
          ;; homes directly is always safe (the load side proved this shape in
          ;; M-C2). Spilled/remat/non-var operands and non-SIB scales keep the
          ;; staged path below.
          [direct-addr : String
            (if (and
              (not (string.eq base-home ""))
              (not (string.eq offset-home "")))
              (compiler-backend-gep-index-address-disp
                gep-disp
                base-home
                scale
                offset-home)
              "")]
          (if (not (string.eq direct-addr ""))
            (compiler-backend-emit-store-value-to-address
              type-segment-bases
              assignments
              value
              store-ty
              direct-addr
              program-index
              (be_operand.compiler-backend-two-exclude base-home offset-home)
              2
              backend-state)
            (compiler-backend-emit-store-to-gep-staged
              type-segment-bases
              assignments
              base
              offset
              value
              store-ty
              program-index
              scale
              value-home
              base-home
              offset-home
              gep-disp
              backend-state)))]))
  ;; The pre-B2 staged dynamic-index store path: scavenge an index scratch (and a
  ;; fold-base scratch for non-SIB scales), load the offset into it, then store
  ;; through the composed address. Reached when the base or offset is not
  ;; register-homed or the scale is not SIB-encodable.
  )

(define (compiler-backend-emit-store-to-gep-staged
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [base : compiler_ir_types.CompilerIrValue]
  [offset : compiler_ir_types.CompilerIrValue]
  [value : (& compiler_ir_types.CompilerIrValue)]
  [store-ty : (& compiler_ast_types.AstType)]
  [program-index : be_state.CompilerBackendProgramIndex]
  [scale : i64]
  [value-home : String]
  [base-home : String]
  [offset-home : String]
  [gep-disp : i64]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    ;; SCR-1 (B1): an index that already has a register home and a SIB-encodable
    ;; scale is read straight from that home. Staging it through a scratch costs
    ;; a copy per store and, under full occupancy, a second borrowed register
    ;; with its save/restore wrap around every store of a hoisted loop. The
    ;; store reads the index and writes only memory, so the home is safe to
    ;; read in place, as on the direct (base AND index resident) path above.
    [direct-index? : bool
      (and
        (not (string.eq offset-home ""))
        (compiler-backend-gep-sib-scale? scale))]
    [scav-idx : String
      (if direct-index?
        (owned_view.compiler-owned-shared-view offset-home)
        (be_operand.compiler-backend-scavenge-reg-here
          (be_operand.compiler-backend-scavenge-exclude-ops2
            backend-state
            assignments
            (be_state.compiler-backend-global-shared-view base)
            value)
          7
          "%r8"
          backend-state))]
    ;; Fold-base scratch. For non-SIB scales the scaled index is folded into a
    ;; register, which must not clobber the base/value homes; it also serves as
    ;; the load fallback when the base is spilled. If that fallback aliases the
    ;; offset home, the offset copy is emitted before the base reload below.
    [scav-fold : String
      (be_operand.compiler-backend-scavenge-reg-here
        (be_operand.compiler-backend-scavenge-exclude-append
          (compiler-backend-scavenge-exclude-regs2
            (be_state.compiler-backend-global-shared-view scav-idx)
            base-home)
          7
          value-home)
        8
        "%r10"
        backend-state)]
    [base-plan
      (try
        (compiler-backend-emit-address-base-with-avoid
          assignments
          base
          (be_state.compiler-backend-global-shared-view scav-fold)
          (be_state.compiler-backend-global-shared-view scav-idx)
          ;; BE-4: variable-index store -- the base reg feeds gep-index-address,
          ;; which spells a %rbp base at every SIB scale now, so it is admitted.
          true
          backend-state))]
    [offset-asm
      (try
        (if direct-index?
          (be_state.ResultCompilerBackend.Ok "")
          (be_operand.compiler-backend-emit-load-value
            assignments
            offset
            (be_state.compiler-backend-global-shared-view scav-idx)
            backend-state)))]
    [base-reg : String
      (compiler_abi.compiler-abi-register-spelling base-plan.reg)]
    [addr : String
      (compiler-backend-gep-index-address-disp gep-disp base-reg scale scav-idx)]
    [addr-asm : String
      (if (string.eq addr "")
        (str_cat.str-cat
          (if (string.eq base-reg scav-fold)
            ""
            (str_cat.str-cat "    movq " base-reg ", " scav-fold "\n"))
          (compiler-backend-gep-index-base-asm-disp
            gep-disp
            scav-fold
            scale
            scav-idx))
        "")]
    [store-addr : String
      (if (string.eq addr "")
        (compiler-backend-base-deref
          (be_state.compiler-backend-global-shared-view scav-fold))
        (owned_view.compiler-owned-shared-view addr))]
    [store-exclude : (__tl_dyn-array String)
      (if (string.eq addr "")
        (be_operand.compiler-backend-one-exclude scav-fold)
        (be_operand.compiler-backend-two-exclude
          (be_state.compiler-backend-global-shared-view base-reg)
          scav-idx))]
    [store-exclude-n : i64
      (if (string.eq addr "")
        1
        2)]
    [base-asm : String base-plan.asm]
    [addr-prefix-asm : String
      (if (and
        (not (string.eq offset-home ""))
        (string.eq base-reg offset-home))
        (str_cat.str-cat offset-asm base-asm)
        (str_cat.str-cat base-asm offset-asm))]
    [store-asm
      (try
        (compiler-backend-emit-store-value-to-address
          type-segment-bases
          assignments
          value
          store-ty
          store-addr
          program-index
          store-exclude
          store-exclude-n
          backend-state))]
    (Ok (str_cat.str-cat addr-prefix-asm addr-asm store-asm))))

(define (compiler-backend-emit-store-ptr-pair
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [ptr : compiler_ir_types.CompilerIrValue]
  [value0 : compiler_ir_types.CompilerIrValue]
  [ty0 : compiler_ast_types.AstType]
  [disp : i64]
  [value1 : (& compiler_ir_types.CompilerIrValue)]
  [ty1 : (& compiler_ast_types.AstType)]
  [program-index : be_state.CompilerBackendProgramIndex]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [ptr-home : String
      (be_facts.compiler-backend-value-register-home
        backend-state
        assignments
        ptr)]
    [value0-home : String
      (be_facts.compiler-backend-value-register-home
        backend-state
        assignments
        value0)]
    [value1-home : String
      (be_facts.compiler-backend-value-register-home
        backend-state
        assignments
        value1)]
    [scav-base : String
      (be_operand.compiler-backend-scavenge-reg-here
        (be_operand.compiler-backend-three-exclude
          ptr-home
          value0-home
          (be_state.compiler-backend-global-shared-view value1-home))
        3
        "%r10"
        backend-state)]
    [base-plan
      (try
        (compiler-backend-emit-address-base
          assignments
          ptr
          scav-base
          program-index.backend-state))]
    [base-asm : String base-plan.asm]
    [base-reg : String
      (compiler_abi.compiler-abi-register-spelling base-plan.reg)]
    [addr0 : String
      (be_facts.compiler-backend-copy-address
        0
        (be_state.compiler-backend-global-shared-view base-reg))]
    [addr1 : String
      (be_facts.compiler-backend-copy-address
        disp
        (be_state.compiler-backend-global-shared-view base-reg))]
    [store0
      (try
        (compiler-backend-emit-store-value-to-address
          type-segment-bases
          assignments
          value0
          ty0
          addr0
          program-index
          (be_operand.compiler-backend-two-exclude
            (be_state.compiler-backend-global-shared-view base-reg)
            value1-home)
          2
          backend-state))]
    [store1
      (try
        (compiler-backend-emit-store-value-to-address
          type-segment-bases
          assignments
          value1
          ty1
          addr1
          program-index
          (be_operand.compiler-backend-one-exclude base-reg)
          1
          backend-state))]
    (Ok (str_cat.str-cat base-asm store0 store1))))

(define (compiler-backend-float-precision-cast-reg-asm
  [from-ty : compiler_ast_types.AstType]
  [to-ty : (& to-ty compiler_ast_types.AstType)]
  [reg : (& reg str)]) : String
  (match from-ty
    [(F64)
      (match to-ty
        [(F32) (str_cat.str-cat "    cvtsd2ss " reg ", " reg "\n")]
        [_ ""])]
    [(F32)
      (match to-ty
        [(F64) (str_cat.str-cat "    cvtss2sd " reg ", " reg "\n")]
        [_ ""])]
    [_ ""]))

(define (compiler-backend-int-to-float-cast-reg-asm
  [src-reg : String]
  [to-ty : (& to-ty compiler_ast_types.AstType)]
  [dst-reg : (& dst-reg str)]) : String
  (match to-ty
    [(F32) (str_cat.str-cat "    cvtsi2ssq " src-reg ", " dst-reg "\n")]
    [_ (str_cat.str-cat "    cvtsi2sdq " src-reg ", " dst-reg "\n")]))

(define (compiler-backend-u64-to-float-cast-op
  [to-ty : (& to-ty compiler_ast_types.AstType)]) : String
  (match to-ty
    [(F32) "ss"]
    [_ "sd"]))

(define (compiler-backend-u64-to-float-cast-label
  [current-label : i64]
  [dst : i64]
  [suffix : String]) : i64
  (compiler_ir_types.compiler-ir-label
    (&
      (str_cat.str-cat
        "cast_u64_float_"
        (compiler_ir_types.compiler-ir-label-text current-label)
        "_v"
        (string.int->string dst)
        suffix))))

(define (compiler-backend-u64-to-float-cast-asm
  [function : String]
  [current-label : i64]
  [dst : i64]
  [to-ty : (& to-ty compiler_ast_types.AstType)]
  [value-reg : String]
  [result-reg : (& result-reg str)]
  [scratch-reg : String]) : String
  (let
    [op : String (compiler-backend-u64-to-float-cast-op to-ty)]
    [high-label : i64
      (compiler-backend-u64-to-float-cast-label current-label dst "_high")]
    [done-label : i64
      (compiler-backend-u64-to-float-cast-label current-label dst "_done")]
    [high-symbol : String
      (be_operand.compiler-backend-asm-label
        (be_state.compiler-backend-global-shared-view function)
        high-label)]
    [done-symbol : String
      (be_operand.compiler-backend-asm-label function done-label)]
    (str_cat.str-cat
      (str_cat.str-cat "    testq " value-reg ", " value-reg "\n")
      (str_cat.str-cat
        "    js "
        high-symbol
        "\n    cvtsi2"
        op
        "q "
        value-reg
        ", "
        result-reg
        "\n")
      (str_cat.str-cat "    jmp " done-symbol "\n")
      (str_cat.str-cat high-symbol ":\n" "")
      (str_cat.str-cat
        "    movq "
        value-reg
        ", "
        scratch-reg
        "\n    andq $1, "
        scratch-reg
        "\n")
      (str_cat.str-cat
        "    shrq $1, "
        value-reg
        "\n    orq "
        scratch-reg
        ", "
        value-reg
        "\n")
      (str_cat.str-cat
        "    cvtsi2"
        op
        "q "
        value-reg
        ", "
        result-reg
        "\n    add"
        op
        " "
        result-reg
        ", "
        result-reg
        "\n")
      (str_cat.str-cat done-symbol ":\n" ""))))

(define (compiler-backend-float-to-int-cast-reg-asm
  [from-ty : compiler_ast_types.AstType]
  [src-reg : (& src-reg str)]
  [dst-reg : (& dst-reg str)]) : String
  (match from-ty
    [(F32) (str_cat.str-cat "    cvttss2siq " src-reg ", " dst-reg "\n")]
    [_ (str_cat.str-cat "    cvttsd2siq " src-reg ", " dst-reg "\n")]))

(define (compiler-backend-float-to-u64-cast-label
  [current-label : i64]
  [dst : i64]
  [suffix : String]) : i64
  (compiler_ir_types.compiler-ir-label
    (&
      (str_cat.str-cat
        "cast_float_u64_"
        (compiler_ir_types.compiler-ir-label-text current-label)
        "_v"
        (string.int->string dst)
        suffix))))

(define (compiler-backend-float-to-u64-cast-asm
  [function : String]
  [current-label : i64]
  [dst : i64]
  [from-ty : compiler_ast_types.AstType]
  [src-reg : String]
  [dst-reg : (& dst-reg str)]) : String
  (let
    [op : String (compiler-backend-u64-to-float-cast-op from-ty)]
    [threshold : String
      (be_operand.compiler-backend-float-label
        from-ty
        (be_state.compiler-backend-float-to-u64-threshold-bits from-ty))]
    [high-label : i64
      (compiler-backend-float-to-u64-cast-label current-label dst "_high")]
    [done-label : i64
      (compiler-backend-float-to-u64-cast-label current-label dst "_done")]
    [high-symbol : String
      (be_operand.compiler-backend-asm-label
        (be_state.compiler-backend-global-shared-view function)
        high-label)]
    [done-symbol : String
      (be_operand.compiler-backend-asm-label function done-label)]
    [convert : String
      (compiler-backend-float-to-int-cast-reg-asm from-ty src-reg dst-reg)]
    (str_cat.str-cat
      (str_cat.str-cat
        "    ucomi"
        op
        " "
        threshold
        "(%rip), "
        src-reg
        "\n    jae "
        high-symbol
        "\n")
      (str_cat.str-cat
        convert
        "    jmp "
        done-symbol
        "\n"
        high-symbol
        ":\n    sub"
        op
        " "
        threshold
        "(%rip), "
        src-reg
        "\n"
        convert
        "    btsq $63, "
        dst-reg
        "\n"
        done-symbol
        ":\n"))))

(define (compiler-backend-emit-float-to-float-cast
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [from-ty : compiler_ast_types.AstType]
  [to-ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [dst-home : String
      (compiler-backend-var-register-home backend-state assignments dst)]
    (if (be_operand.compiler-backend-string-prefix-at? dst-home "%xmm" 0)
      (let
        [load
          (try
            (be_operand.compiler-backend-emit-load-float-value
              assignments
              src
              from-ty
              (be_state.compiler-backend-global-shared-view dst-home)
              backend-state))]
        (Ok
          (str_cat.str-cat
            load
            (compiler-backend-float-precision-cast-reg-asm
              from-ty
              to-ty
              dst-home))))
      (let
        [tmp-reg : String
          (be_operand.compiler-backend-scavenge-xmm-reg
            dst
            (__tl_make-array String 0)
            0
            "%xmm2"
            backend-state)]
        [load
          (try
            (be_operand.compiler-backend-emit-load-float-value
              assignments
              src
              from-ty
              (be_state.compiler-backend-global-shared-view tmp-reg)
              backend-state))]
        (Ok
          (str_cat.str-cat
            load
            (compiler-backend-float-precision-cast-reg-asm
              from-ty
              to-ty
              tmp-reg)
            (be_operand.compiler-backend-emit-store-float-var
              assignments
              dst
              tmp-reg
              to-ty
              backend-state)))))))

(define (compiler-backend-emit-int-to-float-cast
  [type-segment-bases : i64]
  [function : String]
  [current-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [from-ty : compiler_ast_types.AstType]
  [to-ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [dst-home : String
      (compiler-backend-var-register-home backend-state assignments dst)]
    [src-reg : String
      (be_operand.compiler-backend-value-scalar-register
        backend-state
        assignments
        src)]
    (if (and
      (not (compiler_optimize.opt-type-eq type-segment-bases from-ty (& (U64))))
      (be_operand.compiler-backend-string-prefix-at? dst-home "%xmm" 0)
      (not (string.eq src-reg "")))
      (Ok (compiler-backend-int-to-float-cast-reg-asm src-reg to-ty dst-home))
      (if (not
        (compiler_optimize.opt-type-eq type-segment-bases from-ty (& (U64))))
        (let
          [src-tmp : String
            (if (string.eq src-reg "")
              (be_operand.compiler-backend-scavenge-reg
                dst
                (__tl_make-array String 0)
                0
                "%r8"
                backend-state)
              (owned_view.compiler-owned-shared-view src-reg))]
          [dst-tmp : String
            (be_operand.compiler-backend-scavenge-xmm-reg
              dst
              (__tl_make-array String 0)
              0
              "%xmm2"
              backend-state)]
          [load
            (try
              (if (string.eq src-reg "")
                (compiler-backend-emit-load-typed-value-to-reg
                  type-segment-bases
                  assignments
                  src
                  from-ty
                  (be_state.compiler-backend-global-shared-view src-tmp)
                  program-index)
                (be_state.ResultCompilerBackend.Ok "")))]
          (Ok
            (str_cat.str-cat
              load
              (compiler-backend-int-to-float-cast-reg-asm src-tmp to-ty dst-tmp)
              (be_operand.compiler-backend-emit-store-float-var
                assignments
                dst
                dst-tmp
                to-ty
                backend-state))))
        (let
          [value-reg : String
            (be_operand.compiler-backend-scavenge-reg
              dst
              (__tl_make-array String 0)
              0
              "%r8"
              backend-state)]
          [scratch-exclude : (__tl_dyn-array String)
            (be_operand.compiler-backend-one-exclude
              (be_state.compiler-backend-global-shared-view value-reg))]
          [scratch-reg : String
            (be_operand.compiler-backend-scavenge-reg
              dst
              scratch-exclude
              1
              "%r9"
              backend-state)]
          [result-reg : String
            (if (be_operand.compiler-backend-string-prefix-at?
              dst-home
              "%xmm"
              0)
              dst-home
              (be_operand.compiler-backend-scavenge-xmm-reg
                dst
                (__tl_make-array String 0)
                0
                "%xmm2"
                backend-state))]
          [load
            (try
              (compiler-backend-emit-load-typed-value-to-reg
                type-segment-bases
                assignments
                src
                from-ty
                (be_state.compiler-backend-global-shared-view value-reg)
                program-index))]
          (Ok
            (str_cat.str-cat
              load
              (compiler-backend-u64-to-float-cast-asm
                function
                current-label
                dst
                to-ty
                value-reg
                result-reg
                scratch-reg)
              (be_operand.compiler-backend-emit-store-float-var
                assignments
                dst
                result-reg
                to-ty
                backend-state))))))))

(define (compiler-backend-emit-float-to-int-cast
  [function : String]
  [current-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [from-ty : compiler_ast_types.AstType]
  [to-ty : compiler_ast_types.AstType]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [dst-home : String
      (compiler-backend-var-register-home backend-state assignments dst)]
    [src-reg : String
      (compiler-backend-float-value-register backend-state assignments src)]
    [unsigned-u64? : bool
      (match (& to-ty)
        [(U64) true]
        [_ false])]
    (if (and
      (not unsigned-u64?)
      (not (string.eq dst-home ""))
      (not (be_operand.compiler-backend-string-prefix-at? dst-home "%xmm" 0))
      (not (string.eq src-reg "")))
      (Ok (compiler-backend-float-to-int-cast-reg-asm from-ty src-reg dst-home))
      (let
        [src-tmp : String
          (if unsigned-u64?
            (be_operand.compiler-backend-scavenge-xmm-reg
              dst
              (if (string.eq src-reg "")
                (__tl_make-array String 0)
                (be_operand.compiler-backend-one-exclude
                  (be_state.compiler-backend-global-shared-view src-reg)))
              (if (string.eq src-reg "")
                0
                1)
              "%xmm2"
              backend-state)
            (if (string.eq src-reg "")
              (be_operand.compiler-backend-scavenge-xmm-reg
                dst
                (__tl_make-array String 0)
                0
                "%xmm2"
                backend-state)
              (owned_view.compiler-owned-shared-view src-reg)))]
        [dst-reg : String
          (if (and
            (not (string.eq dst-home ""))
            (not
              (be_operand.compiler-backend-string-prefix-at? dst-home "%xmm" 0)))
            dst-home
            (be_operand.compiler-backend-scavenge-reg
              dst
              (__tl_make-array String 0)
              0
              "%r8"
              backend-state))]
        [load
          (try
            (if (or unsigned-u64? (string.eq src-reg ""))
              (be_operand.compiler-backend-emit-load-float-value
                assignments
                src
                from-ty
                (be_state.compiler-backend-global-shared-view src-tmp)
                backend-state)
              (be_state.ResultCompilerBackend.Ok "")))]
        (Ok
          (str_cat.str-cat
            load
            (if unsigned-u64?
              (compiler-backend-float-to-u64-cast-asm
                function
                current-label
                dst
                from-ty
                src-tmp
                dst-reg)
              (compiler-backend-float-to-int-cast-reg-asm
                from-ty
                src-tmp
                dst-reg))
            (be_operand.compiler-backend-emit-store-typed-var
              assignments
              dst
              dst-reg
              to-ty
              backend-state)))))))

(define (compiler-backend-emit-cast
  [type-segment-bases : i64]
  [function : String]
  [current-label : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [from-ty : compiler_ast_types.AstType]
  [to-ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (if (and
    (compiler_optimize.opt-type-eq type-segment-bases from-ty (& to-ty))
    (compiler-backend-value-same-home?
      backend-state
      assignments
      dst
      (be_state.compiler-backend-global-shared-view src)))
    (Ok "")
    (let
      [from-is-float : bool (be_operand.compiler-backend-float-type? from-ty)]
      [to-is-float : bool (be_operand.compiler-backend-float-type? to-ty)]
      (cond
        [(and from-is-float to-is-float)
          (compiler-backend-emit-float-to-float-cast
            assignments
            dst
            (be_state.compiler-backend-global-shared-view src)
            from-ty
            to-ty
            backend-state)]
        [(and (not from-is-float) to-is-float)
          (compiler-backend-emit-int-to-float-cast
            type-segment-bases
            function
            current-label
            assignments
            dst
            src
            from-ty
            to-ty
            program-index
            backend-state)]
        [(and from-is-float (not to-is-float))
          (compiler-backend-emit-float-to-int-cast
            function
            current-label
            assignments
            dst
            src
            from-ty
            to-ty
            backend-state)]
        [else
          (let
            [dst-home : String
              (compiler-backend-var-register-home backend-state assignments dst)]
            [from-size : i64
              (be_operand.compiler-backend-type-size type-segment-bases from-ty)]
            [to-size : i64
              (be_operand.compiler-backend-type-size type-segment-bases to-ty)]
            (if (if (string.eq dst-home "")
              false
              (and
                (be_operand.compiler-backend-intlike-scalar-type? from-ty)
                (be_operand.compiler-backend-intlike-scalar-type? to-ty)
                (< from-size to-size)
                (< from-size 8)))
              (match (& src)
                [(Var src-id)
                  ;; Widening int/char/bool casts can extend straight
                  ;; into the destination register home. This preserves the
                  ;; typed sign/zero-extension load while skipping the
                  ;; %rax store round-trip.
                  (Ok
                    (compiler-backend-emit-load-typed-var-to-reg
                      type-segment-bases
                      assignments
                      src-id
                      from-ty
                      dst-home
                      backend-state))]
                [_
                  (Ok
                    (try
                      (compiler-backend-emit-load-typed-value-to-reg
                        type-segment-bases
                        assignments
                        src
                        from-ty
                        dst-home
                        program-index)))])
              (if (if (string.eq dst-home "")
                false
                (= from-size to-size))
                ;; A same-width int/char cast only reinterprets
                ;; signedness; it needs neither extension nor narrowing, so
                ;; copy the source straight into the destination register
                ;; home (which holds the full normalized 64-bit value),
                ;; skipping the %rax round-trip. Width-changing casts keep
                ;; the typed load+store below so sign/zero extension is
                ;; applied.
                (be_operand.compiler-backend-emit-load-value
                  assignments
                  src
                  dst-home
                  backend-state)
                (let
                  [cast-reg : String
                    (if (string.eq dst-home "")
                      (be_operand.compiler-backend-scavenge-reg
                        dst
                        (compiler-backend-binop-scavenge-exclude-build)
                        5
                        "%r8"
                        backend-state)
                      dst-home)]
                  [load
                    (try
                      (compiler-backend-emit-load-typed-value-to-reg
                        type-segment-bases
                        assignments
                        src
                        from-ty
                        (be_state.compiler-backend-global-shared-view cast-reg)
                        program-index))]
                  (Ok
                    (str_cat.str-cat
                      load
                      (be_operand.compiler-backend-emit-store-typed-var
                        assignments
                        dst
                        cast-reg
                        to-ty
                        backend-state)))))))]))))

(define (compiler-backend-bitcast-width
  [ty : (& ty compiler_ast_types.AstType)]) : i64
  (match ty
    [(or (F32) (I32) (U32)) 4]
    [(or (F64) (I64) (U64)) 8]
    [_ 0]))

(define (compiler-backend-bitcast-int-type?
  [ty : (& ty compiler_ast_types.AstType)]) : bool
  (match ty
    [(or (I32) (U32) (I64) (U64)) true]
    [_ false]))

(define (compiler-backend-bitcast-type-debug-name
  [ty : compiler_ast_types.AstType]) : String
  (match ty
    [(F32) "f32"]
    [(F64) "f64"]
    [(I32) "i32"]
    [(I64) "i64"]
    [(U32) "u32"]
    [(U64) "u64"]
    [_ "other"]))

(define (compiler-backend-float-to-int-bitcast-reg-asm
  [from-ty : compiler_ast_types.AstType]
  [src-reg : String]
  [dst-reg : String]) : String
  (match from-ty
    [(F32)
      (str_cat.str-cat
        "    movd "
        src-reg
        ", "
        (be_operand.compiler-backend-reg-part dst-reg 4)
        "\n")]
    [_ (str_cat.str-cat "    movq " src-reg ", " dst-reg "\n")]))

(define (compiler-backend-int-to-float-bitcast-reg-asm
  [to-ty : (& to-ty compiler_ast_types.AstType)]
  [src-reg : String]
  [dst-reg : (& dst-reg str)]) : String
  (match to-ty
    [(F32)
      (str_cat.str-cat
        "    movd "
        (be_operand.compiler-backend-reg-part src-reg 4)
        ", "
        dst-reg
        "\n")]
    [_ (str_cat.str-cat "    movq " src-reg ", " dst-reg "\n")]))

(define (compiler-backend-bitcast-compatible?
  [_from-ty : (& _from-ty compiler_ast_types.AstType)]
  [_to-ty : (& _to-ty compiler_ast_types.AstType)]
  [from-width : i64]
  [to-width : i64]
  [from-float : bool]
  [to-float : bool]
  [from-int : bool]
  [to-int : bool]) : bool
  (or
    (= from-width to-width)
    (and from-float to-int (= from-width 4) (= to-width 8))
    (and from-int to-float (= from-width 8) (= to-width 4))))

(define (compiler-backend-emit-bitcast
  [type-segment-bases : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]
  [from-ty : compiler_ast_types.AstType]
  [to-ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]
  [backend-state : be_state.CompilerBackendState]) : be_state.ResultCompilerBackend
  (let
    [from-width : i64 (compiler-backend-bitcast-width from-ty)]
    [to-width : i64 (compiler-backend-bitcast-width to-ty)]
    [from-float : bool (be_operand.compiler-backend-float-type? from-ty)]
    [to-float : bool (be_operand.compiler-backend-float-type? to-ty)]
    [from-int : bool (compiler-backend-bitcast-int-type? from-ty)]
    [to-int : bool (compiler-backend-bitcast-int-type? to-ty)]
    (cond
      [(or
          (= from-width 0)
          (= to-width 0)
          (not
            (compiler-backend-bitcast-compatible?
              from-ty
              to-ty
              from-width
              to-width
              from-float
              to-float
              from-int
              to-int)))
        (Err
          (box
            (compiler_diagnostic.compiler-diagnostic-at-start
              ""
              (str_cat.str-cat
                "backend: unsupported bitcast width "
                (compiler-backend-bitcast-type-debug-name from-ty)
                " -> "
                (compiler-backend-bitcast-type-debug-name to-ty)
                " from-width="
                (string.int->string from-width)
                " to-width="
                (string.int->string to-width)
                " from-float="
                (if from-float
                  "1"
                  "0")
                " to-float="
                (if to-float
                  "1"
                  "0")
                " from-int="
                (if from-int
                  "1"
                  "0")
                " to-int="
                (if to-int
                  "1"
                  "0")))))]
      [(and from-float to-int)
        (let
          [dst-home : String
            (compiler-backend-var-register-home backend-state assignments dst)]
          [src-reg : String
            (compiler-backend-float-value-register
              backend-state
              assignments
              src)]
          (if (and
            (not (string.eq dst-home ""))
            (not
              (be_operand.compiler-backend-string-prefix-at? dst-home "%xmm" 0))
            (not (string.eq src-reg "")))
            (Ok
              (compiler-backend-float-to-int-bitcast-reg-asm
                from-ty
                src-reg
                dst-home))
            (let
              [src-tmp : String
                (if (string.eq src-reg "")
                  (be_operand.compiler-backend-scavenge-xmm-reg
                    dst
                    (__tl_make-array String 0)
                    0
                    "%xmm2"
                    backend-state)
                  (owned_view.compiler-owned-shared-view src-reg))]
              [dst-reg : String
                (if (and
                  (not (string.eq dst-home ""))
                  (not
                    (be_operand.compiler-backend-string-prefix-at?
                      dst-home
                      "%xmm"
                      0)))
                  dst-home
                  (be_operand.compiler-backend-scavenge-reg
                    dst
                    (__tl_make-array String 0)
                    0
                    "%r8"
                    backend-state))]
              [load
                (try
                  (if (string.eq src-reg "")
                    (be_operand.compiler-backend-emit-load-float-value
                      assignments
                      src
                      from-ty
                      (be_state.compiler-backend-global-shared-view src-tmp)
                      backend-state)
                    (be_state.ResultCompilerBackend.Ok "")))]
              (Ok
                (str_cat.str-cat
                  load
                  (compiler-backend-float-to-int-bitcast-reg-asm
                    from-ty
                    src-tmp
                    (be_state.compiler-backend-global-shared-view dst-reg))
                  (be_operand.compiler-backend-emit-store-typed-var
                    assignments
                    dst
                    dst-reg
                    to-ty
                    backend-state))))))]
      [(and from-int to-float)
        (let
          [dst-home : String
            (compiler-backend-var-register-home backend-state assignments dst)]
          [src-reg : String
            (be_operand.compiler-backend-value-scalar-register
              backend-state
              assignments
              src)]
          (if (and
            (be_operand.compiler-backend-string-prefix-at? dst-home "%xmm" 0)
            (not (string.eq src-reg "")))
            (Ok
              (compiler-backend-int-to-float-bitcast-reg-asm
                to-ty
                src-reg
                dst-home))
            (let
              [src-tmp : String
                (if (string.eq src-reg "")
                  (be_operand.compiler-backend-scavenge-reg
                    dst
                    (__tl_make-array String 0)
                    0
                    "%r8"
                    backend-state)
                  (owned_view.compiler-owned-shared-view src-reg))]
              [dst-tmp : String
                (if (be_operand.compiler-backend-string-prefix-at?
                  dst-home
                  "%xmm"
                  0)
                  dst-home
                  (be_operand.compiler-backend-scavenge-xmm-reg
                    dst
                    (__tl_make-array String 0)
                    0
                    "%xmm2"
                    backend-state))]
              [load
                (try
                  (if (string.eq src-reg "")
                    (compiler-backend-emit-load-typed-value-to-reg
                      type-segment-bases
                      assignments
                      src
                      from-ty
                      (be_state.compiler-backend-global-shared-view src-tmp)
                      program-index)
                    (be_state.ResultCompilerBackend.Ok "")))]
              (Ok
                (str_cat.str-cat
                  load
                  (compiler-backend-int-to-float-bitcast-reg-asm
                    to-ty
                    src-tmp
                    dst-tmp)
                  (be_operand.compiler-backend-emit-store-float-var
                    assignments
                    dst
                    dst-tmp
                    to-ty
                    backend-state))))))]
      [(and from-int to-int)
        (let
          [dst-home : String
            (compiler-backend-var-register-home backend-state assignments dst)]
          [tmp-reg : String
            (if (and
              (not (string.eq dst-home ""))
              (not
                (be_operand.compiler-backend-string-prefix-at?
                  dst-home
                  "%xmm"
                  0)))
              dst-home
              (be_operand.compiler-backend-scavenge-reg
                dst
                (__tl_make-array String 0)
                0
                "%r8"
                backend-state))]
          [load
            (try
              (compiler-backend-emit-load-typed-value-to-reg
                type-segment-bases
                assignments
                src
                from-ty
                (be_state.compiler-backend-global-shared-view tmp-reg)
                program-index))]
          (Ok
            (str_cat.str-cat
              load
              (be_operand.compiler-backend-emit-store-typed-var
                assignments
                dst
                tmp-reg
                to-ty
                backend-state))))]
      [(and from-float to-float)
        (let
          [dst-home : String
            (compiler-backend-var-register-home backend-state assignments dst)]
          [tmp-reg : String
            (if (be_operand.compiler-backend-string-prefix-at?
              dst-home
              "%xmm"
              0)
              dst-home
              (be_operand.compiler-backend-scavenge-xmm-reg
                dst
                (__tl_make-array String 0)
                0
                "%xmm2"
                backend-state))]
          [load
            (try
              (be_operand.compiler-backend-emit-load-float-value
                assignments
                src
                from-ty
                (be_state.compiler-backend-global-shared-view tmp-reg)
                backend-state))]
          (Ok
            (str_cat.str-cat
              load
              (be_operand.compiler-backend-emit-store-float-var
                assignments
                dst
                tmp-reg
                to-ty
                backend-state))))]
      [else
        (Err
          (box
            (compiler_diagnostic.compiler-diagnostic-at-start
              ""
              "backend: unsupported bitcast type")))])))

;; Whether the argument at the given bank indexes is passed on the stack.
;; Windows shares one positional slot bank (`position`); System V keeps
;; the integer and float banks independent, so an arg spills only once its own
;; bank is exhausted (rdi..r9 / xmm0..xmm7).
(define (compiler-backend-stack-call-arg-for-banks?
  [target : be_state.CompilerBackendTarget]
  [convention : compiler_abi.CompilerCallConvention]
  [is-float : bool]
  [int-idx : i64]
  [float-idx : i64]
  [position : i64]) : bool
  (compiler_abi.compiler-abi-stack-call-arg-for-banks?
    (be_state.compiler-backend-target-abi target)
    convention
    is-float
    int-idx
    float-idx
    position))

(define (compiler-backend-group-pair-reserve
  [backend-state : be_state.CompilerBackendState]) : i64
  (be_state.compiler-backend-function-state-i64
    (be_state.compiler-backend-state-function-state backend-state)
    be_state.compiler-backend-function-i64-group-pair-reserve))

(define (compiler-backend-vars-same-home?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [left : i64]
  [right : i64]) : bool
  (if (= left right)
    true
    (match (be_operand.compiler-backend-emit-assignment-lookup
      backend-state
      assignments
      left)
      [(Some left-location)
        (match (be_operand.compiler-backend-emit-assignment-lookup
          backend-state
          assignments
          right)
          [(Some right-location)
            (compiler_regalloc.compiler-reg-location-eq?
              (& left-location)
              (& right-location))]
          [(No) false])]
      [(No) false])))

(define (compiler-backend-value-same-home?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [dst : i64]
  [src : compiler_ir_types.CompilerIrValue]) : bool
  (match src
    [(Var src-var)
      ;; A forwarded address is recomputed at its use; its nominal allocator
      ;; home was never initialized by the suppressed AddrOf definition.
      (and
        (<
          (be_operand.compiler-backend-forwarded-addr-of-src
            backend-state
            src-var)
          0)
        (compiler-backend-vars-same-home? backend-state assignments dst src-var))]
    [_ false]))

(define (compiler-backend-instr-return-count
  [instr : compiler_ir_types.CompilerIrInstr]) : i64
  (match instr
    [(Return _) 1]
    [_ 0]))

(define (compiler-backend-instr-seq-return-count
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  (let
    [slots : (__tl_dyn-array compiler_ir_types.CompilerIrInstr) instrs.slots]
    [count : i64 instrs.len]
    [out : i64 0]
    (for [index (iterator.range 0 count)]
      (+=
        out
        (compiler-backend-instr-return-count
          (be_state.compiler-backend-global-array-element-shared-view
            slots
            index))))
    out))

(define (compiler-backend-swb-bare-label?
  [backend-state : be_state.CompilerBackendState]
  [label : i64]) : bool
  (let
    [labels : (__tl_dyn-array i64)
      (be_state.compiler-backend-function-state-i64-array
        (be_state.compiler-backend-state-function-state backend-state)
        be_state.compiler-backend-function-i64-array-swb-bare-labels)]
    [i : i64 0]
    [hit : bool false]
    (while (and (not hit) (< i (array-length labels)))
      (if (= (array-ref labels i) label)
        (set! hit true)
        unit)
      (+= i 1))
    hit))

(define (compiler-backend-shared-return-block-count
  [backend-state : be_state.CompilerBackendState]
  [label : i64]
  [instrs : compiler_ir_types.CompilerIrInstrSeq]) : i64
  ;; Bare shrink-wrap exits return before the frame exists and never target the
  ;; framed epilogue. Excluding them keeps a function with one ordinary framed
  ;; return on the inline-epilogue path instead of adding a useless jump merely
  ;; because the entry return was cloned.
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [bare-label : String
      (be_state.compiler-backend-function-state-string
        function-state
        be_state.compiler-backend-function-string-shrinkwrap-bare-label)]
    (if (or
      (and
        (not (string.eq bare-label ""))
        (be_operand.compiler-backend-string-prefix-at?
          (compiler_ir_types.compiler-ir-label-text label)
          bare-label
          0))
      (compiler-backend-swb-bare-label? backend-state label))
      0
      (compiler-backend-instr-seq-return-count instrs))))

(define (compiler-backend-block-list-return-count
  [backend-state : be_state.CompilerBackendState]
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (match blocks
    [(Array seq) (compiler-backend-block-seq-return-count backend-state seq 0)]))

(define (compiler-backend-block-seq-return-count
  [backend-state : be_state.CompilerBackendState]
  [blocks : compiler_ir_types.CompilerIrBlockSeq]
  [index : i64]) : i64
  (if (>= index (compiler_ir_types.compiler-ir-block-seq-count blocks))
    0
    (match (compiler_ir_types.compiler-ir-block-seq-ref blocks index)
      [(Block label instrs)
        (+
          (compiler-backend-shared-return-block-count
            backend-state
            label
            instrs)
          (compiler-backend-block-seq-return-count
            backend-state
            blocks
            (+ index 1)))])))

;; The shared-return tail is only reachable for plans that save callee
;; registers, so plans without them (every stack-only opt0/opt1 plan) skip
;; the whole-function return walk; the count is only consumed through
;; use-shared-return-count?, where 0 and the true count decide identically
;; once the callee-regs conjunct is false.
(define (compiler-backend-shared-return-count
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [blocks : compiler_ir_types.CompilerIrBlockList]) : i64
  (if (be_operand.compiler-backend-plan-uses-callee-regs?
    assignments
    backend-state)
    (compiler-backend-block-list-return-count backend-state blocks)
    0))

(define (compiler-backend-use-shared-return-count?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [return-count : i64]) : bool
  (and
    (be_operand.compiler-backend-plan-uses-callee-regs?
      assignments
      backend-state)
    (> return-count 1)))

(define (compiler-backend-return-tail-for-return-count
  [backend-state : be_state.CompilerBackendState]
  [source-function : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [return-count : i64]) : String
  (let
    [function-state : be_state.CompilerBackendFunctionState
      (be_state.compiler-backend-state-function-state backend-state)]
    [bare-label : String
      (be_state.compiler-backend-function-state-string
        function-state
        be_state.compiler-backend-function-string-shrinkwrap-bare-label)]
    (if (or
      (and
        (not (string.eq bare-label ""))
        (be_operand.compiler-backend-string-prefix-at?
          (compiler_ir_types.compiler-ir-label-text
            (be_state.compiler-backend-function-state-i64
              function-state
              be_state.compiler-backend-function-i64-current-block-label))
          bare-label
          0))
      (compiler-backend-swb-bare-label?
        backend-state
        (be_state.compiler-backend-function-state-i64
          function-state
          be_state.compiler-backend-function-i64-current-block-label)))
      "    ret\n"
      (if (compiler-backend-use-shared-return-count?
        backend-state
        assignments
        return-count)
        (str_cat.str-cat
          "    jmp "
          (compiler-backend-return-label backend-state source-function)
          "\n"
          "")
        (compiler-backend-inline-return-tail assignments vars backend-state)))))

(define (compiler-backend-return-tail
  [backend-state : be_state.CompilerBackendState]
  [source-function : i64]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [blocks : compiler_ir_types.CompilerIrBlockList]) : String
  (compiler-backend-return-tail-for-return-count
    backend-state
    source-function
    assignments
    vars
    (compiler-backend-shared-return-count backend-state assignments blocks)))

(define (compiler-backend-spmd-symbol-prefix?
  [backend-state : be_state.CompilerBackendState]
  [name : i64]
  [prefix : String]) : bool
  (be_operand.compiler-backend-string-prefix-at?
    (be_state.compiler-backend-symbol-text-state backend-state name)
    prefix
    0))

(define (compiler-backend-spmd-varying-return-function?
  [backend-state : be_state.CompilerBackendState]
  [name : i64]) : bool
  (compiler-backend-spmd-symbol-prefix?
    backend-state
    name
    "__tl_spmd_ret_varying_"))

(define (compiler-backend-spmd-mask-return-function?
  [backend-state : be_state.CompilerBackendState]
  [name : i64]) : bool
  (compiler-backend-spmd-symbol-prefix?
    backend-state
    name
    "__tl_spmd_ret_mask_"))

(define (compiler-backend-emit-spmd-private-return-value
  [backend-state : be_state.CompilerBackendState]
  [source-function : i64]
  [value : compiler_ir_types.CompilerIrValue]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [ret-ty : compiler_ast_types.AstType]) : be_state.ResultCompilerBackend
  (if (be_state.compiler-backend-current-mode-avx2?
    (be_state.compiler-backend-state-function-state backend-state))
    (let
      [elem-ty : compiler_ast_types.AstType
        (if (compiler-backend-spmd-mask-return-function?
          backend-state
          source-function)
          (I8)
          ret-ty)]
      (match (be_operand.compiler-backend-vector-register-use
        assignments
        value
        "private AVX2 SPMD return value"
        "ymm"
        elem-ty
        "%ymm14"
        backend-state)
        [(Ok use)
          (match use
            [(Use load-asm reg)
              (Ok
                (str_cat.str-cat
                  load-asm
                  (if (string.eq reg "%ymm0")
                    ""
                    (str_cat.str-cat "    vmovdqu " reg ", %ymm0\n"))
                  ""))])]
        [(Err message)
          (Err
            (box (compiler_diagnostic.compiler-diagnostic-at-start "" message)))]))
    (if (compiler-backend-spmd-mask-return-function?
      backend-state
      source-function)
      (match (be_operand.compiler-backend-avx512-mask-register-use
        assignments
        value
        "private SPMD return value"
        64
        "%k7"
        backend-state)
        [(Ok use)
          (match use
            [(Use load-asm reg)
              (Ok
                (str_cat.str-cat
                  load-asm
                  (if (string.eq reg "%k1")
                    ""
                    (str_cat.str-cat "    kmovq " reg ", %k1\n" ""))
                  ""))])]
        [(Err message)
          (Err
            (box (compiler_diagnostic.compiler-diagnostic-at-start "" message)))])
      (match (be_operand.compiler-backend-vector-register-use
        assignments
        value
        "private SPMD return value"
        "zmm"
        ret-ty
        "%zmm14"
        backend-state)
        [(Ok use)
          (match use
            [(Use load-asm reg)
              (Ok
                (str_cat.str-cat
                  load-asm
                  (if (string.eq reg "%zmm16")
                    ""
                    (str_cat.str-cat
                      "    "
                      (be_operand.compiler-backend-avx512-vector-move ret-ty)
                      " "
                      reg
                      ", %zmm16\n"))
                  ""))])]
        [(Err message)
          (Err
            (box (compiler_diagnostic.compiler-diagnostic-at-start "" message)))]))))

(define (compiler-backend-emit-return-with-return-count
  [type-segment-bases : i64]
  [source-function : i64]
  [return-count : i64]
  [value : compiler_ir_types.CompilerIrMaybeValue]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [ret-ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]) : be_state.ResultCompilerBackend
  (match value
    [(No)
      (Ok
        (str_cat.str-cat
          (if (=
            (compiler_ir_types.compiler-ir-symbol-id source-function)
            cbi.compiler-builtin-id-fix-main)
            "    xorl %eax, %eax\n"
            "")
          (compiler-backend-return-tail-for-return-count
            program-index.backend-state
            source-function
            assignments
            vars
            return-count)))]
    [(Some v)
      ;; A register-group return goes in %rax:%rdx (word0:word1).
      (if (or
        (compiler-backend-spmd-varying-return-function?
          program-index.backend-state
          source-function)
        (compiler-backend-spmd-mask-return-function?
          program-index.backend-state
          source-function))
        (let
          [load
            (try
              (compiler-backend-emit-spmd-private-return-value
                program-index.backend-state
                source-function
                v
                assignments
                ret-ty))]
          (Ok
            (str_cat.str-cat
              load
              (compiler-backend-return-tail-for-return-count
                program-index.backend-state
                source-function
                assignments
                vars
                return-count))))
        (if (be_facts.compiler-backend-group-type?
          type-segment-bases
          program-index
          ret-ty)
          (let
            [load
              (try
                (compiler-backend-emit-group-load
                  type-segment-bases
                  assignments
                  v
                  (compiler-backend-group-return-reg
                    type-segment-bases
                    program-index
                    (be_state.compiler-backend-global-shared-view ret-ty)
                    0)
                  (compiler-backend-group-return-reg
                    type-segment-bases
                    program-index
                    (be_state.compiler-backend-global-shared-view ret-ty)
                    1)
                  vars
                  ret-ty
                  program-index
                  program-index.backend-state))]
            (Ok
              (str_cat.str-cat
                load
                (compiler-backend-return-tail-for-return-count
                  program-index.backend-state
                  source-function
                  assignments
                  vars
                  return-count))))
          (let
            [load
              (try
                (compiler-backend-emit-load-typed-value
                  type-segment-bases
                  assignments
                  v
                  ret-ty
                  program-index
                  program-index.backend-state))]
            (Ok
              (str_cat.str-cat
                load
                (compiler-backend-return-tail-for-return-count
                  program-index.backend-state
                  source-function
                  assignments
                  vars
                  return-count))))))]))

(define (compiler-backend-emit-return
  [type-segment-bases : i64]
  [source-function : i64]
  [blocks : compiler_ir_types.CompilerIrBlockList]
  [value : compiler_ir_types.CompilerIrMaybeValue]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [ret-ty : compiler_ast_types.AstType]
  [program-index : be_state.CompilerBackendProgramIndex]) : be_state.ResultCompilerBackend
  (compiler-backend-emit-return-with-return-count
    type-segment-bases
    source-function
    (compiler-backend-shared-return-count
      program-index.backend-state
      assignments
      blocks)
    value
    assignments
    vars
    ret-ty
    program-index))

;; The destination's home register, or "" if it is spilled / has no home. Used to
;; load a move's source directly into the destination register (1 instr) instead
;; of routing through %rax and storing back (2 instrs).
(define (compiler-backend-var-register-home
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var : i64]) : String
  (match (be_operand.compiler-backend-emit-assignment-lookup
    backend-state
    assignments
    var)
    [(Some location)
      (match location
        [(or (Register r) (RegisterPair r _))
          (compiler_abi.compiler-abi-register-spelling r)]
        [_ ""])]
    [_ ""]))

;; R5. Is `var`'s home a RECOMPUTE rather than storage? Then this instruction is
;; its single definition, every use materialises the value for itself, and the
;; definition is dead -- not just its store. The immediate path already emitted
;; nothing (compiler-backend-emit-store-immediate-to-var-home); a global cell
;; read, a `leaq label(%rip)` or a `load @g` still staged the value into a
;; scavenged register and then dropped it, leaving one dead instruction per
;; definition. Removing a pure recompute is always safe.
(define (compiler-backend-var-remat-home?
  [backend-state : be_state.CompilerBackendState]
  [assignments : compiler_regalloc.CompilerRegAssignmentTable]
  [var-id : i64]) : bool
  (match (be_operand.compiler-backend-emit-assignment-lookup
    backend-state
    assignments
    var-id)
    [(Some location)
      (match location
        [(Remat _) true]
        [_ false])]
    [(No) false]))

;; #8894: a float parameter word that arrives in the incoming stack area and
;; lives in a frame slot is copied memory to memory through a volatile register.
;; Picking that register at the word's place in the walk was unsound: the
;; earlier parameters already occupy their homes, the scavenger's occupancy
;; is the cursor the body left behind, and its XMM pool (%xmm2-%xmm5) runs
;; out when those four are pinned parameter homes, so the pick fell back to a
;; pinned register and overwrote that parameter. These copies are entry
;; copies instead: they run first, before any incoming register is written,
;; when only the incoming argument registers are live. Use the first XMM past
;; the argument bank only when it is volatile. Otherwise copy the bits through
;; RAX, which neither Internal convention uses for incoming arguments or the
;; private SPMD block pointer. In particular, Windows XMM0-5 are all arguments
;; and XMM6 must be preserved; choosing it would require a new callee save.
(define (compiler-backend-param-entry-memory-copy
  [target : be_state.CompilerBackendTarget]
  [src : (& src str)]
  [dst : (& dst str)]
  [ty : (& ty compiler_ast_types.AstType)]) : String
  (let
    [abi : compiler_abi.CompilerRegTargetAbi
      (be_state.compiler-backend-target-abi target)]
    [args : i64
      (compiler_abi.compiler-abi-float-arg-register-count abi (Internal))]
    [sse? : bool
      (<
        args
        (compiler_abi.compiler-abi-caller-saved-xmm-register-count
          abi
          (Internal)))]
    [f32? : bool
      (match ty
        [(F32) true]
        [_ false])]
    [mov : String
      (if sse?
        (be_operand.compiler-backend-float-move ty)
        (if f32?
          "movl"
          "movq"))]
    [stage : String
      (if sse?
        (compiler_abi.compiler-abi-register-spelling
          (compiler_abi.compiler-abi-xmm-register-id args))
        (if f32?
          "%eax"
          "%rax"))]
    (str_cat.str-cat
      "    "
      mov
      " "
      src
      ", "
      stage
      "\n    "
      mov
      " "
      stage
      ", "
      dst
      "\n")))

;; Exclude set for binop scavenging: a safe superset of every binop op's fixed
;; registers (div/mul: rax/rdx; shift: rcx; fallback binops: rax=lhs). Pooled
;; scratch registers such as r10/r11 must stay available to the scavenger.
(define (compiler-backend-binop-scavenge-exclude-build) : (__tl_dyn-array
    String)
  (__tl_make-array "%rax" "%rdx" "%rcx" "" ""))

;; Op-specific scavenge exclude: only the registers THIS op actually clobbers
;; (beyond operand/dst homes, excluded separately). The over-broad superset
;; excluded rcx+rdx for every op, removing them as scratch candidates even for
;; add/sub/and/or/xor/cmp that don't touch them -> needless degradation to the
;; fallback. Returns a size-5 array (padded with zero-bit empty-string sentinels).
;; div/mod -> rax:rdx, mul -> rax/rdx, shift -> rcx, everything else -> nothing extra.
(define (compiler-backend-binop-scavenge-exclude-for-op
  [op : (& op compiler_ir_types.CompilerIrBinOp)]) : (__tl_dyn-array String)
  (let
    [op : compiler_ir_types.CompilerIrBinOp
      (owned_view.compiler-owned-reference-shared-view op)]
    [rax-extra : String
      (match (& op)
        [(or (Div) (Mod) (SafeDiv) (SafeMod) (Mul)) "%rax"]
        [_ ""])]
    [extra : String
      (match op
        [(or (Div) (Mod) (SafeDiv) (SafeMod) (Mul)) "%rdx"]
        [(or (Shl _) (Shr _) (Rotr)) "%rcx"]
        [_ ""])]
    (__tl_make-array rax-extra extra "" "" "")))

;; Constant/magic-division 3-scratch discipline. The magic multiply needs a
;; scratch for the magic constant, a saved-dividend register read back for the
;; remainder, and a sign-mask register for signed cases. All three must be
;; mutually distinct and distinct from %rax/%rdx (the multiply/idiv clobbers).
;; The freeness query cannot see a sibling scratch's transient use at the same
;; point, so each scavenge excludes the already-picked regs. The sibling fallback
;; registers themselves stay available unless they were actually picked.
(define (compiler-backend-divmod-dividend-exclude [magic : String]) : (__tl_dyn-array
    String)
  (__tl_make-array "%rax" "%rdx" "" "" magic))

(define (compiler-backend-divmod-mask-exclude
  [magic : String]
  [dividend : String]) : (__tl_dyn-array String)
  (__tl_make-array "%rax" "%rdx" "" "" magic dividend))

;; Concatenate two exclude arrays into a fresh array.
(define (compiler-backend-scavenge-exclude-merge
  [left : (__tl_dyn-array String)]
  [left-n : i64]
  [right : (& right (__tl_dyn-array String))]
  [right-n : i64]) : (__tl_dyn-array String)
  (let
    [a : (__tl_dyn-array String) (__tl_make-array String (+ left-n right-n))]
    (for [i (iterator.range 0 left-n)]
      (set! (array-ref a i) (owned_view.compiler-owned-element-view left i)))
    (for [j (iterator.range 0 right-n)]
      (set!
        (array-ref a (+ left-n j))
        (owned_view.compiler-owned-element-view right j)))
    a))

;; Exclude set = HW-fixed regs PLUS two given register names (caller already knows
;; them, e.g. the emission's dst-home + an operand's home reg). "" stays a zero-bit
;; sentinel. Pooled scratch registers such as r10/r11 stay available unless one is
;; one of the explicit register names. n = 7.
(define (compiler-backend-scavenge-exclude-regs2 [r1 : String] [r2 : String]) : (__tl_dyn-array
    String)
  (__tl_make-array
    "%rax"
    "%rdx"
    "%rcx"
    ""
    ""
    (if (string.eq r1 "")
      ""
      r1)
    (if (string.eq r2 "")
      ""
      r2)))

;; Conservative magnitude cap for the folded element offset and its byte
;; displacement: far below imm32 so downstream constant-offset merges can
;; never overflow.
(define (compiler-backend-gep-fold-k-bound) : i64
  16777216)