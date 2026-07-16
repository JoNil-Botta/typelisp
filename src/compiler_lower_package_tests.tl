;; compiler_lower_package_tests.tl - package-callable lowering test support.
(import "compiler_lower.tl")

(define (compiler-lower-spmd-package-callable-source) : String
  "(module spmd_fixture)
(define (helper [x : i64] [scale : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying uniform)
      (result varying)
      (index-param 0)))
  : i64
  (+ x scale))")

(define (compiler-lower-spmd-package-helper-count
  [functions : CompilerIrFunctionList]) : i64
  (match functions
    [(CompilerIrFunctionList.Nil) 0]
    [(CompilerIrFunctionList.Array seq)
      (compiler-lower-spmd-package-helper-count
        (compiler-ir-function-seq-to-list seq))]
    [(CompilerIrFunctionList.Cons function rest)
      (+
        (match function
          [(CompilerIrFunction.Function name _ _ _ _)
            (if (or
              (lower-string-prefix-at? name "__tl_spmd_pkg_" 0)
              (lower-string-prefix-at?
                name
                "__tl_spmd_ret_uniform___tl_spmd_pkg_"
                0)
              (lower-string-prefix-at?
                name
                "__tl_spmd_ret_varying___tl_spmd_pkg_"
                0)
              (lower-string-prefix-at?
                name
                "__tl_spmd_ret_mask___tl_spmd_pkg_"
                0))
              1
              0)])
        (compiler-lower-spmd-package-helper-count (box-get rest)))]))

(define (compiler-lower-spmd-package-callable-mode-ok?
  [mode : CompilerLowerMode]) : bool
  (let
    [_package : unit (lower-spmd-set-package-name! "spmd_fixture")]
    [result : ResultCompilerLower
      (lower-compiler-source-with-mode
        (compiler-lower-spmd-package-callable-source)
        mode)]
    (begin
      (lower-spmd-clear-package-name!)
      (match result
        [(ResultCompilerLower.Ok program _)
          (match program
            [(CompilerIrProgram.Program _ functions _)
              (= (compiler-lower-spmd-package-helper-count functions) 1)])]
        [(ResultCompilerLower.Err _) false]))))

(define (compiler-lower-spmd-package-callable-error-ok?
  [source : String]
  [mode : CompilerLowerMode]
  [wanted : String]) : bool
  (let
    [_package : unit (lower-spmd-set-package-name! "spmd_fixture")]
    [result : ResultCompilerLower (lower-compiler-source-with-mode source mode)]
    (begin
      (lower-spmd-clear-package-name!)
      (match result
        [(ResultCompilerLower.Ok _ _) false]
        [(ResultCompilerLower.Err diag)
          (string.eq (compiler-diagnostic-message (box-get diag)) wanted)]))))

(define (compiler-lower-spmd-package-symbol-collision-ok?) : bool
  (let
    [_package : unit (lower-spmd-set-package-name! "collision_fixture")]
    [first : String
      (lower-spmd-package-symbol-register "__collision" "identity-a")]
    [repeat : String
      (lower-spmd-package-symbol-register "__collision" "identity-a")]
    [collision : String
      (lower-spmd-package-symbol-register "__collision" "identity-b")]
    (begin
      (lower-spmd-clear-package-name!)
      (and
        (string.eq first "")
        (string.eq repeat "")
        (string.eq
          collision
          "lower: :spmd-callable stable symbol collision for __collision")))))

(define (compiler-lower-spmd-package-callable-validation-errors-ok?) : bool
  (and
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 8) (args varying) (result uniform) (index-param 0)))
  : i64 x)"
      (CompilerLowerMode.Avx512)
      "lower: :spmd-callable varying body requires result varying")
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 8) (args uniform) (result uniform) (index-param 0)))
      : i64 x)"
      (CompilerLowerMode.Avx512)
      "lower: :spmd-callable index-param must name a varying argument")
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param 0)))
  : i64
  (unsafe (+ x 1)))"
      (CompilerLowerMode.Avx512)
      "lower: :spmd-callable body does not support SPMD specialization")))

(define (compiler-lower-spmd-package-callable-recursion-errors-ok?) : bool
  (compiler-lower-spmd-package-callable-error-ok?
    "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param 0)))
  : i64
  (helper x))"
    (CompilerLowerMode.Avx512)
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
    (CompilerLowerMode.Avx512)
    "lower: recursive SPMD helper call is not supported"))

(define (compiler-lower-spmd-package-callable-abi-errors-ok?) : bool
  (and
    (compiler-lower-spmd-package-callable-error-ok?
      (compiler-lower-spmd-package-callable-source)
      (CompilerLowerMode.Avx2)
      "lower: :spmd-callable is not supported in AVX2 backend mode; use scalar or avx512")
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : String])
  (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param none)))
  : String
  x)"
      (CompilerLowerMode.Avx512)
      "lower: :spmd-callable parameter type is not supported by private ABI v1")
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 16) (args varying) (result varying) (index-param 0)))
  : i64
  x)"
      (CompilerLowerMode.Avx512)
      "lower: :spmd-callable lane width does not match varying parameter type")
    (compiler-lower-spmd-package-symbol-collision-ok?)))

(define (compiler-lower-spmd-package-callable-tests-ok?) : bool
  (and
    (compiler-lower-spmd-package-callable-mode-ok? (CompilerLowerMode.Scalar))
    (compiler-lower-spmd-package-callable-mode-ok? (CompilerLowerMode.Avx512))))