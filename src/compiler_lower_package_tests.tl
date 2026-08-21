;; compiler_lower_package_tests.tl - package-callable lowering test support.
(import compiler_lower)
(import compiler_ir_types)
(import compiler_ast_types)
(import compiler_diagnostic)
(import compiler_intern as ci)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)

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
        (compiler-lower-spmd-package-helper-count (__tl-box-place rest)))]))

(define (compiler-lower-spmd-package-helper-count-ok?
  [source : String]
  [mode : compiler_lower.CompilerLowerMode]
  [wanted : i64]) : bool
  (let
    [result : compiler_lower.ResultCompilerLower
      (compiler_lower.lower-compiler-source-with-mode-and-package
        source
        mode
        "spmd_fixture")]
    (match result
      [(compiler_lower.ResultCompilerLower.Ok program _)
        (match program
          [(compiler_ir_types.CompilerIrProgram.Program _ functions _)
            (= (compiler-lower-spmd-package-helper-count functions) wanted)])]
      [(compiler_lower.ResultCompilerLower.Err _) false])))

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
            (compiler-lower-spmd-package-uniform-helper-render
              (__tl-box-place rest)))])]))

(define (compiler-lower-spmd-package-return-context-source-ok?
  [source : String]) : bool
  (let
    [result : compiler_lower.ResultCompilerLower
      (compiler_lower.lower-compiler-source-with-mode-and-package
        source
        (compiler_lower.CompilerLowerMode.Avx512)
        "spmd_fixture")]
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
      [(compiler_lower.ResultCompilerLower.Err _) false])))

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
    [result : compiler_lower.ResultCompilerLower
      (compiler_lower.lower-compiler-source-with-mode-and-package
        source
        mode
        "spmd_fixture")]
    (match result
      [(compiler_lower.ResultCompilerLower.Ok _ _) false]
      [(compiler_lower.ResultCompilerLower.Err diag)
        (string.eq
          (compiler_diagnostic.compiler-diagnostic-message
            (__tl-box-place diag))
          wanted)])))

(define (compiler-lower-spmd-package-symbol-collision-ok?) : bool
  (let
    [state : compiler_lower.CompilerLowerState
      (compiler_lower.compiler-lower-state-new-with-intern-state
        (ci.intern-compat-state-new))]
    [_package : unit
      (compiler_lower.compiler-lower-state-set-spmd-package!
        state
        "collision_fixture")]
    [intern-state : ci.InternCompatState
      (compiler_lower.compiler-lower-state-interns state)]
    [classes : compiler_ast_types.AstSpmdParamClassList
      (compiler_ast_types.ast-spmd-param-class-list-new)]
    [canonical-handle : i64
      (ci.intern-compat-state-intern intern-state "collision/helper")]
    ;; The result type is a typed structural component even though this
    ;; deliberately inconsistent fixture keeps the old serialized signature
    ;; byte-identical. Both recipes therefore produce the same stable hash and
    ;; linker spelling while retaining distinct identity and symbol handles.
    [identity-a : i64
      (compiler_lower.lower-spmd-package-structural-symbol
        state
        "collision_fixture"
        "collision/helper"
        canonical-handle
        "(-> i64)"
        (compiler_ast_types.AstType.I64)
        (compiler_ir_types.CompilerIrSpmdBackend.Scalar)
        1
        classes
        (compiler_ast_types.AstSpmdResultClass.Uniform)
        -1)]
    [identity-b : i64
      (compiler_lower.lower-spmd-package-structural-symbol
        state
        "collision_fixture"
        "collision/helper"
        canonical-handle
        "(-> i64)"
        (compiler_ast_types.AstType.F64)
        (compiler_ir_types.CompilerIrSpmdBackend.Scalar)
        1
        classes
        (compiler_ast_types.AstSpmdResultClass.Uniform)
        -1)]
    [expected-symbol : String
      (compiler_lower.lower-spmd-package-symbol
        "collision_fixture"
        "collision/helper"
        "(-> i64)"
        (compiler_ast_types.AstType.I64)
        (compiler_ir_types.CompilerIrSpmdBackend.Scalar)
        1
        ""
        "u"
        -1)]
    [first : compiler_lower.LowerSpmdPackageSymbolRegistration
      (compiler_lower.lower-spmd-package-symbol-register
        state
        (compiler_lower.lower-spmd-package-structural-linker-symbol
          intern-state
          identity-a)
        (compiler_lower.lower-spmd-package-structural-registration-key
          intern-state
          identity-a)
        (compiler_lower.lower-spmd-package-structural-identity
          intern-state
          identity-a))]
    [repeat : compiler_lower.LowerSpmdPackageSymbolRegistration
      (compiler_lower.lower-spmd-package-symbol-register
        state
        (compiler_lower.lower-spmd-package-structural-linker-symbol
          intern-state
          identity-a)
        (compiler_lower.lower-spmd-package-structural-registration-key
          intern-state
          identity-a)
        (compiler_lower.lower-spmd-package-structural-identity
          intern-state
          identity-a))]
    [collision : compiler_lower.LowerSpmdPackageSymbolRegistration
      (compiler_lower.lower-spmd-package-symbol-register
        state
        (compiler_lower.lower-spmd-package-structural-linker-symbol
          intern-state
          identity-b)
        (compiler_lower.lower-spmd-package-structural-registration-key
          intern-state
          identity-b)
        (compiler_lower.lower-spmd-package-structural-identity
          intern-state
          identity-b))]
    (and
      (not
        (=
          (compiler_lower.lower-spmd-package-structural-identity
            intern-state
            identity-a)
          (compiler_lower.lower-spmd-package-structural-identity
            intern-state
            identity-b)))
      (not
        (=
          (compiler_lower.lower-spmd-package-structural-linker-symbol
            intern-state
            identity-a)
          (compiler_lower.lower-spmd-package-structural-linker-symbol
            intern-state
            identity-b)))
      (=
        (compiler_lower.lower-spmd-package-structural-registration-key
          intern-state
          identity-a)
        (compiler_lower.lower-spmd-package-structural-registration-key
          intern-state
          identity-b))
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
            (str_cat.str-cat
              "lower: :spmd-callable stable symbol collision for "
              expected-symbol))]
        [_ false]))))

(define (compiler-lower-spmd-package-test-classes
  [first : compiler_ast_types.AstSpmdParamClass]
  [second : compiler_ast_types.AstSpmdParamClass]) : compiler_ast_types.AstSpmdParamClassList
  (let
    [classes : compiler_ast_types.AstSpmdParamClassList
      (compiler_ast_types.ast-spmd-param-class-list-new)]
    (begin
      (compiler_ast_types.ast-spmd-param-class-list-push (&mut classes) first)
      (compiler_ast_types.ast-spmd-param-class-list-push (&mut classes) second)
      classes)))

(define (compiler-lower-spmd-test-identity
  [state : compiler_lower.CompilerLowerState]
  [record : i64]) : i64
  (compiler_lower.lower-spmd-package-structural-identity
    (compiler_lower.compiler-lower-state-interns state)
    record))

(define (compiler-lower-spmd-test-symbol
  [state : compiler_lower.CompilerLowerState]
  [record : i64]) : i64
  (compiler_lower.lower-spmd-package-structural-linker-symbol
    (compiler_lower.compiler-lower-state-interns state)
    record))

(define (compiler-lower-spmd-test-registration-key
  [state : compiler_lower.CompilerLowerState]
  [record : i64]) : i64
  (compiler_lower.lower-spmd-package-structural-registration-key
    (compiler_lower.compiler-lower-state-interns state)
    record))

(define (compiler-lower-spmd-test-identity-components
  [state : compiler_lower.CompilerLowerState]
  [record : i64]) : i64
  (compiler_lower.lower-spmd-package-structural-identity-components
    (compiler_lower.compiler-lower-state-interns state)
    record))

(define (compiler-lower-spmd-structural-symbols-ok?) : bool
  (let
    [state-a : compiler_lower.CompilerLowerState
      (compiler_lower.compiler-lower-state-new-with-intern-state
        (ci.intern-compat-state-new))]
    [state-b : compiler_lower.CompilerLowerState
      (compiler_lower.compiler-lower-state-new-with-intern-state
        (ci.intern-compat-state-new))]
    [_package-a : unit
      (compiler_lower.compiler-lower-state-set-spmd-package! state-a "pkg-a")]
    [_package-b : unit
      (compiler_lower.compiler-lower-state-set-spmd-package! state-b "pkg-a")]
    [intern-a : ci.InternCompatState
      (compiler_lower.compiler-lower-state-interns state-a)]
    [intern-b : ci.InternCompatState
      (compiler_lower.compiler-lower-state-interns state-b)]
    [canonical-a : i64 (ci.intern-compat-state-intern intern-a "pkg-a/helper")]
    [canonical-b : i64 (ci.intern-compat-state-intern intern-b "pkg-a/helper")]
    [varying-uniform : compiler_ast_types.AstSpmdParamClassList
      (compiler-lower-spmd-package-test-classes
        compiler_ast_types.AstSpmdParamClass.Varying
        compiler_ast_types.AstSpmdParamClass.Uniform)]
    [uniform-varying : compiler_ast_types.AstSpmdParamClassList
      (compiler-lower-spmd-package-test-classes
        compiler_ast_types.AstSpmdParamClass.Uniform
        compiler_ast_types.AstSpmdParamClass.Varying)]
    [base : i64
      (compiler_lower.lower-spmd-package-structural-symbol
        state-a
        "pkg-a"
        "pkg-a/helper"
        canonical-a
        "(-> i64 i64 i64)"
        (compiler_ast_types.AstType.I64)
        (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
        8
        varying-uniform
        (compiler_ast_types.AstSpmdResultClass.Varying)
        0)]
    [repeat : i64
      (compiler_lower.lower-spmd-package-structural-symbol
        state-a
        "pkg-a"
        "pkg-a/helper"
        canonical-a
        "(-> i64 i64 i64)"
        (compiler_ast_types.AstType.I64)
        (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
        8
        varying-uniform
        (compiler_ast_types.AstSpmdResultClass.Varying)
        0)]
    [different-lanes : i64
      (compiler_lower.lower-spmd-package-structural-symbol
        state-a
        "pkg-a"
        "pkg-a/helper"
        canonical-a
        "(-> i64 i64 i64)"
        (compiler_ast_types.AstType.I64)
        (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
        16
        varying-uniform
        (compiler_ast_types.AstSpmdResultClass.Varying)
        0)]
    [different-args : i64
      (compiler_lower.lower-spmd-package-structural-symbol
        state-a
        "pkg-a"
        "pkg-a/helper"
        canonical-a
        "(-> i64 i64 i64)"
        (compiler_ast_types.AstType.I64)
        (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
        8
        uniform-varying
        (compiler_ast_types.AstSpmdResultClass.Varying)
        0)]
    [different-result : i64
      (compiler_lower.lower-spmd-package-structural-symbol
        state-a
        "pkg-a"
        "pkg-a/helper"
        canonical-a
        "(-> i64 i64 i64)"
        (compiler_ast_types.AstType.I64)
        (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
        8
        varying-uniform
        (compiler_ast_types.AstSpmdResultClass.Uniform)
        0)]
    [other-state : i64
      (compiler_lower.lower-spmd-package-structural-symbol
        state-b
        "pkg-a"
        "pkg-a/helper"
        canonical-b
        "(-> i64 i64 i64)"
        (compiler_ast_types.AstType.I64)
        (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
        8
        varying-uniform
        (compiler_ast_types.AstSpmdResultClass.Varying)
        0)]
    [source-name : i64 (ci.intern-generated-canonical-name "value")]
    [private-param : i64
      (compiler_lower.lower-spmd-private-param-symbol
        state-a
        source-name
        (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
        (compiler_lower.CompilerLowerMode.Avx2))]
    [private-param-repeat : i64
      (compiler_lower.lower-spmd-private-param-symbol
        state-a
        source-name
        (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
        (compiler_lower.CompilerLowerMode.Avx2))]
    [private-param-mask : i64
      (compiler_lower.lower-spmd-private-param-symbol
        state-a
        source-name
        (compiler_ir_types.CompilerIrSpmdValueClass.Mask)
        (compiler_lower.CompilerLowerMode.Avx2))]
    [private-param-text : String
      (compiler_lower.lower-spmd-private-param-name
        state-a
        source-name
        (compiler_ir_types.CompilerIrSpmdValueClass.Varying)
        (compiler_lower.CompilerLowerMode.Avx2))]
    [private-helper : i64
      (compiler_lower.lower-spmd-private-helper-symbol
        state-a
        (ci.intern-compat-state-intern intern-a "__tl_lambda_fixture_0")
        (compiler_ast_types.AstType.Bool)
        true)]
    [expected-identity : String
      (compiler_lower.lower-spmd-package-symbol-identity
        "pkg-a"
        "pkg-a/helper"
        "(-> i64 i64 i64)"
        (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
        8
        "vu"
        "v"
        0)]
    [expected-symbol : String
      (compiler_lower.lower-spmd-package-symbol
        "pkg-a"
        "pkg-a/helper"
        "(-> i64 i64 i64)"
        (compiler_ast_types.AstType.I64)
        (compiler_ir_types.CompilerIrSpmdBackend.Avx512)
        8
        "vu"
        "v"
        0)]
    [unrendered : bool
      (and
        (=
          (string.string-length
            (ci.intern-compat-state-str
              intern-a
              (compiler-lower-spmd-test-identity state-a base)))
          0)
        (=
          (string.string-length
            (ci.intern-compat-state-str
              intern-a
              (compiler-lower-spmd-test-symbol state-a base)))
          0)
        (=
          (string.string-length
            (ci.intern-compat-state-str intern-a private-helper))
          0))]
    (begin
      (compiler_lower.lower-materialize-generated-role-symbols! state-a)
      (compiler_lower.lower-materialize-generated-role-symbols! state-b)
      (let
        [old-other-symbol : i64
          (compiler-lower-spmd-test-symbol state-b other-state)]
        [other-rendered-ok : bool
          (string.eq
            (ci.intern-compat-state-str
              intern-b
              (compiler-lower-spmd-test-symbol state-b other-state))
            expected-symbol)]
        (begin
          (compiler_lower.compiler-lower-state-reset! state-b)
          (ci.intern-compat-state-reset! intern-b)
          (and
            unrendered
            (=
              (compiler-lower-spmd-test-identity state-a base)
              (compiler-lower-spmd-test-identity state-a repeat))
            (=
              (compiler-lower-spmd-test-symbol state-a base)
              (compiler-lower-spmd-test-symbol state-a repeat))
            (=
              (compiler-lower-spmd-test-registration-key state-a base)
              (compiler-lower-spmd-test-registration-key state-a repeat))
            (not
              (=
                (compiler-lower-spmd-test-identity state-a base)
                (compiler-lower-spmd-test-identity state-a different-lanes)))
            (not
              (=
                (compiler-lower-spmd-test-identity state-a base)
                (compiler-lower-spmd-test-identity state-a different-args)))
            (not
              (=
                (compiler-lower-spmd-test-identity state-a base)
                (compiler-lower-spmd-test-identity state-a different-result)))
            (not
              (=
                (compiler-lower-spmd-test-identity-components state-a base)
                (compiler-lower-spmd-test-identity-components
                  state-b
                  other-state)))
            (= private-param private-param-repeat)
            (not (= private-param private-param-mask))
            (string.eq private-param-text "__tl_spmd_varying_arg_avx2_value")
            (string.eq
              (ci.intern-compat-state-str intern-a private-helper)
              "__tl_spmd_ret_mask___tl_lambda_fixture_0")
            (string.eq
              (ci.intern-compat-state-str
                intern-a
                (compiler-lower-spmd-test-identity state-a base))
              expected-identity)
            (string.eq
              (ci.intern-compat-state-str
                intern-a
                (compiler-lower-spmd-test-symbol state-a base))
              expected-symbol)
            other-rendered-ok
            (cfg
              test
              (and
                (=
                  (compiler_lower.compiler-lower-profile-spmd-identity-serializations-value
                    state-a)
                  4)
                (=
                  (compiler_lower.compiler-lower-profile-spmd-stable-hash-computations-value
                    state-a)
                  4)
                (=
                  (compiler_lower.compiler-lower-profile-spmd-render-cache-misses-value
                    state-a)
                  4)
                (>=
                  (compiler_lower.compiler-lower-profile-spmd-render-cache-hits-value
                    state-a)
                  5))
              true)
            (not
              (ci.intern-compat-state-generated-id-active?
                intern-b
                old-other-symbol))))))))

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
    (compiler-lower-spmd-structural-symbols-ok?)
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