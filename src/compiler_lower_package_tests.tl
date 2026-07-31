;; compiler_lower_package_tests.tl - package-callable lowering test support.
(import compiler_lower)
(import compiler_ir_types)
(import compiler_ast_types)
(import compiler_diagnostic)
(import stdlib.string)

(define (compiler-lower-spmd-package-callable-source) : String
  "(module spmd_fixture)
(define (helper [x : i64] [scale : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying uniform)
      (result varying)
      (index-param 0))
    (specialization
      (lanes 8)
      (args uniform varying)
      (result varying)
      (index-param 1)))
  : i64
  (+ x scale))")

(define (compiler-lower-spmd-package-helper-count
  [functions : compiler_ir_types.CompilerIrFunctionList]) : i64
  (match functions
    [(compiler_ir_types.CompilerIrFunctionList.Nil) 0]
    [(compiler_ir_types.CompilerIrFunctionList.Array seq)
      (compiler-lower-spmd-package-helper-count
        (compiler_ir_types.compiler-ir-function-seq-to-list seq))]
    [(compiler_ir_types.CompilerIrFunctionList.Cons function rest)
      (+
        (match function
          [(compiler_ir_types.CompilerIrFunction.Function name _ _ _ _)
            (let
              [name-text : String
                (compiler_ir_types.compiler-ir-symbol-text name)]
              (if (or
                (compiler_lower.lower-string-prefix-at?
                  name-text
                  "__tl_spmd_pkg_"
                  0)
                (compiler_lower.lower-string-prefix-at?
                  name-text
                  "__tl_spmd_ret_uniform___tl_spmd_pkg_"
                  0)
                (compiler_lower.lower-string-prefix-at?
                  name-text
                  "__tl_spmd_ret_varying___tl_spmd_pkg_"
                  0)
                (compiler_lower.lower-string-prefix-at?
                  name-text
                  "__tl_spmd_ret_mask___tl_spmd_pkg_"
                  0))
                1
                0))])
        (compiler-lower-spmd-package-helper-count (box-get rest)))]))

(define (compiler-lower-spmd-package-helper-count-ok?
  [source : String]
  [mode : compiler_lower.CompilerLowerMode]
  [wanted : i64]) : bool
  (let
    [_package : unit
      (compiler_lower.lower-spmd-set-package-name! "spmd_fixture")]
    [result : compiler_lower.ResultCompilerLower
      (compiler_lower.lower-compiler-source-with-mode source mode)]
    (begin
      (compiler_lower.lower-spmd-clear-package-name!)
      (match result
        [(compiler_lower.ResultCompilerLower.Ok program _)
          (match program
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (= (compiler-lower-spmd-package-helper-count functions) wanted)])]
        [(compiler_lower.ResultCompilerLower.Err _) false]))))

(define (compiler-lower-spmd-package-scalar-collapse-source) : String
  "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable
    (specialization (lanes 8) (args uniform) (result uniform) (index-param none))
    (specialization (lanes 16) (args uniform) (result uniform) (index-param none)))
  : i64
  x)")

(define (compiler-lower-spmd-package-literal-return-source) : String
  "(module spmd_fixture)
(define (helper [_x : i64])
  (:spmd-callable
    (specialization (lanes 8) (args varying) (result uniform) (index-param none)))
  : i64
  7)")

(define (compiler-lower-spmd-package-cast-return-source) : String
  "(module spmd_fixture)
(define (helper [_x : i64])
  (:spmd-callable
    (specialization (lanes 8) (args varying) (result uniform) (index-param none)))
  : i64
  (cast 7 : i64))")

(define (compiler-lower-spmd-package-uniform-helper-render
  [functions : compiler_ir_types.CompilerIrFunctionList]) : String
  (match functions
    [(compiler_ir_types.CompilerIrFunctionList.Nil) ""]
    [(compiler_ir_types.CompilerIrFunctionList.Array seq)
      (compiler-lower-spmd-package-uniform-helper-render
        (compiler_ir_types.compiler-ir-function-seq-to-list seq))]
    [(compiler_ir_types.CompilerIrFunctionList.Cons function rest)
      (match function
        [(compiler_ir_types.CompilerIrFunction.Function name _ _ _ _)
          (if (compiler_lower.lower-string-prefix-at?
            (compiler_ir_types.compiler-ir-symbol-text name)
            "__tl_spmd_ret_uniform___tl_spmd_pkg_"
            0)
            (compiler_ir_types.compiler-ir-function-render
              (compiler_ast_types.ast-node-pool-reader-type-segment-bases)
              function)
            (compiler-lower-spmd-package-uniform-helper-render (box-get rest)))])]))

(define (compiler-lower-spmd-package-return-context-source-ok?
  [source : String]) : bool
  (let
    [_package : unit
      (compiler_lower.lower-spmd-set-package-name! "spmd_fixture")]
    [result : compiler_lower.ResultCompilerLower
      (compiler_lower.lower-compiler-source-with-mode
        source
        (compiler_lower.CompilerLowerMode.Avx512))]
    (begin
      (compiler_lower.lower-spmd-clear-package-name!)
      (match result
        [(compiler_lower.ResultCompilerLower.Ok program _)
          (match program
            [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
              (let
                [rendered : String
                  (compiler-lower-spmd-package-uniform-helper-render functions)]
                [splat-i64 : String "splat 7 lanes 8 : i64"]
                [splat-i32 : String "splat 7 lanes 8 : i32"]
                [reduce-i64 : String "vector_reduce_min"]
                (and
                  (string.contains (& rendered) (& splat-i64))
                  (not (string.contains (& rendered) (& splat-i32)))
                  (string.contains (& rendered) (& reduce-i64))))])]
        [(compiler_lower.ResultCompilerLower.Err _) false]))))

(define (compiler-lower-spmd-package-return-context-ok?) : bool
  (and
    (compiler-lower-spmd-package-return-context-source-ok?
      (compiler-lower-spmd-package-literal-return-source))
    (compiler-lower-spmd-package-return-context-source-ok?
      (compiler-lower-spmd-package-cast-return-source))))

(define (compiler-lower-spmd-package-callable-error-ok?
  [source : String]
  [mode : compiler_lower.CompilerLowerMode]
  [wanted : String]) : bool
  (let
    [_package : unit
      (compiler_lower.lower-spmd-set-package-name! "spmd_fixture")]
    [result : compiler_lower.ResultCompilerLower
      (compiler_lower.lower-compiler-source-with-mode source mode)]
    (begin
      (compiler_lower.lower-spmd-clear-package-name!)
      (match result
        [(compiler_lower.ResultCompilerLower.Ok _ _) false]
        [(compiler_lower.ResultCompilerLower.Err diag)
          (string.eq
            (compiler_diagnostic.compiler-diagnostic-message (box-get diag))
            wanted)]))))

(define (compiler-lower-spmd-package-symbol-collision-ok?) : bool
  (let
    [_package : unit
      (compiler_lower.lower-spmd-set-package-name! "collision_fixture")]
    [symbol : i64 (compiler_ir_types.compiler-ir-test-symbol "__collision")]
    [first : compiler_lower.LowerSpmdPackageSymbolRegistration
      (compiler_lower.lower-spmd-package-symbol-register symbol "identity-a")]
    [repeat : compiler_lower.LowerSpmdPackageSymbolRegistration
      (compiler_lower.lower-spmd-package-symbol-register symbol "identity-a")]
    [collision : compiler_lower.LowerSpmdPackageSymbolRegistration
      (compiler_lower.lower-spmd-package-symbol-register symbol "identity-b")]
    (begin
      (compiler_lower.lower-spmd-clear-package-name!)
      (and
        (match first
          [(compiler_lower.LowerSpmdPackageSymbolRegistration.New) true]
          [_ false])
        (match repeat
          [(compiler_lower.LowerSpmdPackageSymbolRegistration.Existing) true]
          [_ false])
        (match collision
          [(compiler_lower.LowerSpmdPackageSymbolRegistration.Collision message)
            (string.eq
              message
              "lower: :spmd-callable stable symbol collision for __collision")]
          [_ false])))))

(define (compiler-lower-spmd-package-callable-validation-errors-ok?) : bool
  (and
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 8) (args varying) (result uniform) (index-param 0)))
  : i64 x)"
      (compiler_lower.CompilerLowerMode.Avx512)
      "lower: :spmd-callable varying body requires result varying")
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 8) (args uniform) (result uniform) (index-param 0)))
      : i64 x)"
      (compiler_lower.CompilerLowerMode.Avx512)
      "lower: :spmd-callable index-param must name a varying argument")
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param 0)))
  : i64
  (unsafe (+ x 1)))"
      (compiler_lower.CompilerLowerMode.Avx512)
      "lower: :spmd-callable body does not support SPMD specialization")))

(define (compiler-lower-spmd-package-callable-recursion-errors-ok?) : bool
  (compiler-lower-spmd-package-callable-error-ok?
    "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param 0)))
  : i64
  (helper x))"
    (compiler_lower.CompilerLowerMode.Avx512)
    "lower: recursive SPMD helper call is not supported"))

(define (compiler-lower-spmd-package-callable-mutual-recursion-error-ok?) : bool
  (compiler-lower-spmd-package-callable-error-ok?
    "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param 0)))
  : i64
  (other x))
(define (other [x : i64]) : i64
  (helper x))"
    (compiler_lower.CompilerLowerMode.Avx512)
    "lower: recursive SPMD helper call is not supported"))

(define (compiler-lower-spmd-package-callable-abi-errors-ok?) : bool
  (and
    (compiler-lower-spmd-package-callable-error-ok?
      (compiler-lower-spmd-package-callable-source)
      (compiler_lower.CompilerLowerMode.Avx2)
      "lower: :spmd-callable is not supported in AVX2 backend mode; use scalar or avx512")
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : String])
  (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param none)))
  : String
  x)"
      (compiler_lower.CompilerLowerMode.Avx512)
      "lower: :spmd-callable parameter type is not supported by private ABI v1")
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 16) (args varying) (result varying) (index-param 0)))
  : i64
  x)"
      (compiler_lower.CompilerLowerMode.Avx512)
      "lower: :spmd-callable lane width does not match varying parameter type")
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 2) (args uniform) (result uniform) (index-param none)))
  : i64
  x)"
      (compiler_lower.CompilerLowerMode.Avx512)
      "lower: :spmd-callable lane width is not supported by private ABI v1")
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : f64])
  (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param 0)))
  : f64
  x)"
      (compiler_lower.CompilerLowerMode.Avx512)
      "lower: :spmd-callable index-param must name an i64 parameter")
    (compiler-lower-spmd-package-symbol-collision-ok?)))

(define (compiler-lower-spmd-package-callable-tests-ok?) : bool
  (and
    (compiler-lower-spmd-package-helper-count-ok?
      (compiler-lower-spmd-package-callable-source)
      (compiler_lower.CompilerLowerMode.Scalar)
      2)
    (compiler-lower-spmd-package-helper-count-ok?
      (compiler-lower-spmd-package-callable-source)
      (compiler_lower.CompilerLowerMode.Avx512)
      2)
    (compiler-lower-spmd-package-helper-count-ok?
      (compiler-lower-spmd-package-scalar-collapse-source)
      (compiler_lower.CompilerLowerMode.Scalar)
      1)
    (compiler-lower-spmd-package-helper-count-ok?
      (compiler-lower-spmd-package-scalar-collapse-source)
      (compiler_lower.CompilerLowerMode.Avx512)
      2)
    (compiler-lower-spmd-package-return-context-ok?)))