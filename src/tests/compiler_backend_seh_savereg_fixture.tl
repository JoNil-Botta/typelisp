;; compiler_backend_seh_savereg_fixture.tl - emit Windows framed prologues
;; with described callee-register saves for scripts/verify-win64-seh-unwind.sh,
;; which assembles them and compares the unwind rows llvm-readobj decodes with
;; tests/fixtures/win64-seh/savereg-oracle.expected. The layouts cover the full
;; GP save set, a probed frame with XMM saves, and a frame whose save offsets
;; need the far encoding.
(import compiler_abi as cabi)
(import compiler_backend as backend)
(import compiler_diagnostic as cdiag)
(import compiler_intern as ci)
(import compiler_regalloc as regalloc)
(import compiler_str_cat as str_cat)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)

(define (seh-oracle-home
  [table : regalloc.CompilerRegAssignmentTable]
  [var : i64]
  [spelling : String]) : regalloc.CompilerRegAssignmentTable
  (regalloc.compiler-reg-assignments-prepend
    (regalloc.CompilerRegAssignment
      var
      (Register (cabi.compiler-abi-register-id-from-spelling spelling)))
    table))

(define (seh-oracle-function
  [state : backend.CompilerBackendState]
  [symbol : String]
  [assignments : regalloc.CompilerRegAssignmentTable]
  [vars : i64]
  [frame : i64]) : String
  (let
    [entry : String
      (backend.compiler-backend-emit-function-entry
        (backend.compiler-backend-target-policy-new Windows)
        (string.copy symbol)
        frame
        assignments
        vars
        true
        state)]
    [body : String
      (str_cat.str-cat
        (backend.compiler-backend-emit-save-callee-regs assignments vars state)
        "    leave\n    ret\n")]
    (match (backend.compiler-backend-windows-framed-save-splice
      body
      0
      ""
      assignments
      vars
      frame
      symbol
      (cdiag.compiler-diagnostic-at-start "" "")
      state)
      [(Ok described)
        (str_cat.str-cat
          ".globl "
          symbol
          "\n"
          entry
          described
          "    .seh_endproc\n")]
      [(Err _) ""])))

(define (seh-oracle-asm [state : backend.CompilerBackendState]) : String
  (let
    [full : regalloc.CompilerRegAssignmentTable
      (seh-oracle-home
        (seh-oracle-home
          (seh-oracle-home
            (seh-oracle-home
              (seh-oracle-home
                (seh-oracle-home
                  (seh-oracle-home
                    (regalloc.compiler-reg-assignment-table-empty)
                    6
                    "%rdi")
                  5
                  "%rsi")
                4
                "%rbx")
              3
              "%r15")
            2
            "%r14")
          1
          "%r13")
        0
        "%r12")]
    [mixed : regalloc.CompilerRegAssignmentTable
      (seh-oracle-home
        (seh-oracle-home
          (seh-oracle-home
            (regalloc.compiler-reg-assignment-table-empty)
            2
            "%xmm15")
          1
          "%xmm6")
        0
        "%rbx")]
    [far : regalloc.CompilerRegAssignmentTable
      (seh-oracle-home
        (seh-oracle-home
          (regalloc.compiler-reg-assignment-table-empty)
          1
          "%rdi")
        0
        "%r12")]
    [full-text : String
      (seh-oracle-function
        state
        "seh_oracle_full"
        full
        3
        (backend.compiler-backend-frame-size
          (backend.compiler-backend-frame-slots 3 full state)))]
    [mixed-text : String
      (seh-oracle-function
        state
        "seh_oracle_probed"
        mixed
        600
        (backend.compiler-backend-frame-size
          (backend.compiler-backend-frame-slots 600 mixed state)))]
    [far-text : String
      (seh-oracle-function state "seh_oracle_far" far 3 600000)]
    (if (or
      (string.eq full-text "")
      (string.eq mixed-text "")
      (string.eq far-text ""))
      ""
      (str_cat.str-cat "    .text\n" full-text mixed-text far-text))))

(define (main) : i64
  (if (< (io.arg-count) 2)
    (begin
      (io.print-error
        "compiler-backend-seh-savereg-fixture: expected output path")
      2)
    (let
      [state : backend.CompilerBackendState
        (backend.compiler-backend-state-new
          (ci.intern-compat-state-capture-active))]
      [_win : unit
        (backend.compiler-backend-function-state-set-bool!
          (backend.compiler-backend-state-function-state state)
          backend.compiler-backend-function-bool-current-fn-win64
          true)]
      [text : String (seh-oracle-asm state)]
      (if (string.eq text "")
        (begin
          (io.print-error
            "compiler-backend-seh-savereg-fixture: a layout was rejected")
          1)
        (begin
          (io.write-file (io.arg 1) (byte_buf.str-as-bytes (& text)))
          0)))))