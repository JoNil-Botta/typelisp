;; compiler_codegen_smoke_suite.tl - Compile-once suite for source-owned
;; lowering and backend self-tests. Drivers with substantial test bodies remain
;; standalone.
(import stdlib.io)
(import stdlib.process)
(import stdlib.string)
(import compiler_lower_tests)
(import compiler_lower_package_tests)
(import compiler_backend_tests)
(import compiler_backend_object_target_tests as object_target_tests)
(import compiler_x64_executable_template_tests as x64_template_tests)
(import compiler_driver_smoke_tests)
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
      (if (compiler_lower_tests.compiler-lower-spmd-scalar-call-shape-ok?)
        42
        1)]
    [(string.eq name "spmd-avx512")
      (if (compiler_lower_tests.compiler-lower-spmd-out-of-line-call-shape-ok?)
        42
        1)]
    [(string.eq name "spmd-imported-selection")
      (if (compiler_lower_tests.compiler-lower-imported-spmd-selection-smoke-ok?)
        42
        1)]
    [(string.eq name "spmd-package-callable")
      (if (compiler_lower_package_tests.compiler-lower-spmd-package-callable-tests-ok?)
        42
        1)]
    [(string.eq name "spmd-package-validation")
      (if (compiler_lower_package_tests.compiler-lower-spmd-package-callable-validation-errors-ok?)
        42
        1)]
    [(string.eq name "spmd-package-recursion")
      (if (compiler_lower_package_tests.compiler-lower-spmd-package-callable-recursion-errors-ok?)
        42
        1)]
    [(string.eq name "spmd-package-mutual-recursion")
      (if (compiler_lower_package_tests.compiler-lower-spmd-package-callable-mutual-recursion-error-ok?)
        42
        1)]
    [(string.eq name "spmd-package-abi")
      (if (compiler_lower_package_tests.compiler-lower-spmd-package-callable-abi-errors-ok?)
        42
        1)]
    [(string.eq name "backend")
      (begin
        (cbi.compiler-builtin-initialize-for-parse!)
        (compiler_backend_tests.compiler-backend-configured-self-test))]
    [(string.eq name "backend-object-target")
      (object_target_tests.compiler-backend-object-target-tests-main)]
    [(string.eq name "x64-template-registry")
      (x64_template_tests.compiler-x64-template-tests-main)]
    [(string.eq name "lower-symbol-identity")
      (compiler_driver_smoke_tests.compiler-lower-symbol-identity-smoke-main)]
    [(string.eq name "driver-pic")
      (compiler_driver_smoke_tests.compiler-driver-pic-smoke-main)]
    [(string.eq name "driver-reader-context")
      (begin
        (cbi.compiler-builtin-initialize-for-parse!)
        (compiler_driver_smoke_tests.compiler-driver-reader-context-smoke-main))]
    [(string.eq name "driver-typecheck-cache-owner")
      (if (compiler_driver_smoke_tests.compiler-driver-typecheck-cache-owner-smoke-ok?)
        42
        1)]
    [(string.eq name "driver-base-transients")
      (compiler_driver_smoke_tests.compiler-driver-base-transients-smoke-main)]
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
        "backend-object-target"
        "compiler smoke suite: compiler_backend_object_target_smoke failed")
      (compiler-smoke-suite-require-child
        "x64-template-registry"
        "compiler smoke suite: compiler_x64_template_registry failed")
      (compiler-smoke-suite-require-child
        "lower-symbol-identity"
        "compiler smoke suite: compiler_lower_symbol_identity_smoke failed")
      (compiler-smoke-suite-require-child
        "driver-pic"
        "compiler smoke suite: compiler_driver_pic_smoke failed")
      (compiler-smoke-suite-require-child
        "driver-reader-context"
        "compiler smoke suite: compiler_driver_reader_context_smoke failed")
      (compiler-smoke-suite-require-child
        "driver-typecheck-cache-owner"
        "compiler smoke suite: typecheck cache owner isolation failed")
      (compiler-smoke-suite-require-child
        "driver-base-transients"
        "compiler smoke suite: compiler_driver_base_transients_smoke failed")
      42)))