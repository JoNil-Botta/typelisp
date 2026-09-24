(import compiler_backend as backend)
(import compiler_builtin_ids as cbi)
(import compiler_backend_runtime_common as common)
(import compiler_backend_runtime_linux as linux)
(import compiler_backend_runtime_windows as windows)
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import compiler_owned_view as owned)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.test)

(define (leaf-name [i : i64]) : String
  (cond
    [(= i 0) "tl_memchr"]
    [(= i 1) "tl_tlci_call_image_entry"]
    [(= i 2) "tl_mem_copy_fwd"]
    [(= i 3) "tl_mem_copy8_fwd"]
    [else "tl_mem_fill8"]))

(define (check-reference [which : i64] [mode : i64]) : unit
  (let
    [name : String (leaf-name which)]
    [link : i64 (ci.intern (owned.compiler-owned-shared-view name))]
    [alias : i64 (ci.intern "runtime-leaf-alias")]
    [source : i64 (ci.intern "runtime-leaf-source")]
    [state
      (backend.compiler-backend-state-new
        (ci.intern-compat-state-capture-active))]
    [externs
      (ir.compiler-ir-extern-seq1
        (ir.CompilerIrExtern.Extern
          alias
          source
          name
          (ast.AstType.Unit)
          (ast.AstExternAbi.C)
          link
          (ast.ast-extern-link-input-list-new)
          false))]
    [index (backend.compiler-backend-runtime-index-empty)]
    [refs (backend.BackendSymbolSeq (__tl_make-array i64 1) 0)]
    (begin
      ;; An unused extern declaration is deliberately insufficient. Keep the
      ;; linked helper for either call identity or an address-taking reference.
      (when
        (and (> mode 0) (< mode 4))
        (set!
          index
          (backend.compiler-backend-runtime-index-instr
            index
            (ir.CompilerIrInstr.Call
              0
              (if (= mode 1)
                link
                (if (= mode 2)
                  alias
                  source))
              (ir.CompilerIrCallArgs.Nil)
              (ast.AstType.Unit)))))
      (when
        (and (>= mode 4) (<= mode 6))
        (begin
          (set!
            (array-ref refs.slots 0)
            (if (= mode 4)
              link
              (if (= mode 5)
                alias
                source)))
          (set! refs.len 1)))
      (when
        (= mode 7)
        (set!
          index
          (backend.compiler-backend-runtime-index-instr
            index
            (ir.CompilerIrInstr.TailCall
              alias
              (ir.CompilerIrCallArgs.Nil)
              (ast.AstType.Unit)))))
      (test.assert-i64-eq
        (backend.compiler-backend-runtime-used-leaf-mask
          state
          index
          refs
          externs)
        (if (= mode 0)
          0
          (shl 1 which))
        "direct, alias and address-taken runtime leaf references"))))

(test
  runtime-leaf-reference-inventory
  (let
    [which : i64 0]
    (while (< which 5)
      (let
        [mode : i64 0]
        (begin
          (while (< mode 8)
            (begin
              (check-reference which mode)
              (set! mode (+ mode 1))))
          (set! which (+ which 1)))))))

(define (leaf-features [mask : i64]) : common.CompilerBackendRuntimeFeatures
  (common.CompilerBackendRuntimeFeatures
    false
    false
    false
    false
    false
    false
    false
    false
    false
    mask))

(test
  runtime-leaf-recipe-subsets
  (let
    [mask : i64 0]
    (while (< mask 32)
      (let
        [features (leaf-features mask)]
        [asm (linux.compiler-backend-runtime-functions (& features))]
        [win (windows.compiler-backend-runtime-functions (& features))]
        [full (leaf-features 31)]
        [which : i64 0]
        (begin
          (test.assert-true
            (string.contains (& asm) ".globl tl_memcpy\n")
            "forward copy leaves retain their common copy core")
          (test.assert-true
            (string.eq
              win
              (windows.compiler-backend-runtime-functions (& full)))
            "Linux leaf selection preserves Windows runtime")
          (while (< which 5)
            (let
              [anchor (str_cat.str-cat ".globl " (leaf-name which) "\n" "")]
              (begin
                (test.assert-true
                  (=
                    (string.contains (& asm) (& anchor))
                    (!= (bit-and mask (shl 1 which)) 0))
                  "only selected runtime leaves are emitted")
                (set! which (+ which 1)))))
          (set! mask (+ mask 1)))))))

(test
  runtime-leaf-selection-keeps-library-and-windows-recipes
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (let
      [index (backend.compiler-backend-runtime-index-empty)]
      [refs (backend.BackendSymbolSeq (__tl_make-array i64 0) 0)]
      [externs (ir.compiler-ir-extern-seq-empty)]
      [state
        (backend.compiler-backend-state-new
          (ci.intern-compat-state-capture-active))]
      (match (backend.compiler-backend-runtime-plan-for
        (ir.compiler-ir-function-seq-empty)
        (owned.compiler-owned-shared-view externs))
        [(backend.ResultBackendRuntimePlan.Ok plan)
          (let
            [executable
              (backend.compiler-backend-runtime-features-for-emission
                (backend.CompilerBackendTarget.Linux)
                (owned.compiler-owned-shared-view plan)
                state
                (owned.compiler-owned-shared-view index)
                (owned.compiler-owned-shared-view refs)
                (owned.compiler-owned-shared-view externs)
                true)]
            [library
              (backend.compiler-backend-runtime-features-for-emission
                (backend.CompilerBackendTarget.Linux)
                (owned.compiler-owned-shared-view plan)
                state
                (owned.compiler-owned-shared-view index)
                (owned.compiler-owned-shared-view refs)
                (owned.compiler-owned-shared-view externs)
                false)]
            [win
              (backend.compiler-backend-runtime-features-for-emission
                (backend.CompilerBackendTarget.Windows)
                plan
                state
                index
                refs
                externs
                true)]
            (begin
              (test.assert-i64-eq
                executable.leaf-mask
                0
                "unused executable helpers")
              (test.assert-i64-eq
                library.leaf-mask
                31
                "entryless library helper exports")
              (test.assert-i64-eq win.leaf-mask 31 "Windows helper selection")))]
        [_ (test.assert-true false "runtime plan")]))))