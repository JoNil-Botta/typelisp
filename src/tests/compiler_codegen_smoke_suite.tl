;; compiler_codegen_smoke_suite.tl - Compile-once suite for source-owned
;; lowering and backend self-tests. Drivers with substantial test bodies remain
;; standalone.
(import stdlib.io)
(import stdlib.process)
(import stdlib.string)
(import "../compiler_lower_tests.tl")
(import "../compiler_lower_package_tests.tl")
(import "../compiler_backend_tests.tl")
(import "../compiler_driver_smoke_tests.tl")
(import compiler_builtin_ids as cbi)

(define (compiler-smoke-suite-child-ok? [name : String]) : bool
  (process.result-output-eq?
    (process.output (process.command (io.arg 0) (process.args-single name)))
    42
    ""
    ""))

(define (compiler-smoke-suite-require-child [name : String] [message : String]) : unit
  (unless (compiler-smoke-suite-child-ok? name) (io.panic message)))

(define (compiler-smoke-suite-child [name : String]) : i64
  (cond
    [(string.eq name "spmd-scalar")
      (if (compiler-lower-spmd-scalar-call-shape-ok?)
        42
        1)]
    [(string.eq name "spmd-avx512")
      (if (compiler-lower-spmd-out-of-line-call-shape-ok?)
        42
        1)]
    [(string.eq name "spmd-imported-selection")
      (if (compiler-lower-imported-spmd-selection-smoke-ok?)
        42
        1)]
    [(string.eq name "spmd-package-callable")
      (if (compiler-lower-spmd-package-callable-tests-ok?)
        42
        1)]
    [(string.eq name "spmd-package-validation")
      (if (compiler-lower-spmd-package-callable-validation-errors-ok?)
        42
        1)]
    [(string.eq name "spmd-package-recursion")
      (if (compiler-lower-spmd-package-callable-recursion-errors-ok?)
        42
        1)]
    [(string.eq name "spmd-package-mutual-recursion")
      (if (compiler-lower-spmd-package-callable-mutual-recursion-error-ok?)
        42
        1)]
    [(string.eq name "spmd-package-abi")
      (if (compiler-lower-spmd-package-callable-abi-errors-ok?)
        42
        1)]
    [(string.eq name "backend")
      (begin
        (cbi.compiler-builtin-initialize-for-parse!)
        (compiler-backend-self-test))]
    [(string.eq name "lower-symbol-identity")
      (compiler-lower-symbol-identity-smoke-main)]
    [(string.eq name "driver-pic") (compiler-driver-pic-smoke-main)]
    [(string.eq name "driver-reader-context")
      (begin
        (cbi.compiler-builtin-initialize-for-parse!)
        (compiler-driver-reader-context-smoke-main))]
    [else 1]))

(define (main) : i64
  (if (> (io.arg-count) 1)
    (compiler-smoke-suite-child (io.arg 1))
    (begin
      (compiler-smoke-suite-require-child
        "spmd-scalar"
        "compiler smoke suite: compiler_spmd_call_lower_scalar_smoke failed")
      (compiler-smoke-suite-require-child
        "spmd-avx512"
        "compiler smoke suite: compiler_spmd_call_lower_avx512_smoke failed")
      (compiler-smoke-suite-require-child
        "spmd-imported-selection"
        "compiler smoke suite: compiler_spmd_imported_selection_smoke failed")
      (compiler-smoke-suite-require-child
        "spmd-package-callable"
        "compiler smoke suite: compiler_spmd_package_callable_smoke failed")
      (compiler-smoke-suite-require-child
        "spmd-package-validation"
        "compiler smoke suite: compiler_spmd_package_validation_smoke failed")
      (compiler-smoke-suite-require-child
        "spmd-package-recursion"
        "compiler smoke suite: compiler_spmd_package_recursion_smoke failed")
      (compiler-smoke-suite-require-child
        "spmd-package-mutual-recursion"
        "compiler smoke suite: compiler_spmd_package_mutual_recursion_smoke failed")
      (compiler-smoke-suite-require-child
        "spmd-package-abi"
        "compiler smoke suite: compiler_spmd_package_abi_smoke failed")
      (compiler-smoke-suite-require-child
        "backend"
        "compiler smoke suite: compiler_backend_smoke failed")
      (compiler-smoke-suite-require-child
        "lower-symbol-identity"
        "compiler smoke suite: compiler_lower_symbol_identity_smoke failed")
      (compiler-smoke-suite-require-child
        "driver-pic"
        "compiler smoke suite: compiler_driver_pic_smoke failed")
      (compiler-smoke-suite-require-child
        "driver-reader-context"
        "compiler smoke suite: compiler_driver_reader_context_smoke failed")
      42)))
