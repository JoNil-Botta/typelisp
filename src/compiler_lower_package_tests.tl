;; compiler_lower_package_tests.tl - package-callable lowering test support.
(import compiler_lower as lower)
(import compiler_ir_types as ir)
(import compiler_ast_types as ast)
(import compiler_diagnostic as cdiag)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_owned_view as owned_view)
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
  [functions : ir.CompilerIrFunctionSeq]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index functions.len)
        (begin
          (match (ir.compiler-ir-function-seq-ref functions index)
            [(Function name _ _ _ _ _)
              (let
                [name-text : String (ir.compiler-ir-symbol-text name)]
                (if (or
                  (lower.lower-string-prefix-at?
                    (ir.compiler-ir-global-shared-view name-text)
                    "__tl_spmd_pkg_"
                    0)
                  (lower.lower-string-prefix-at?
                    (ir.compiler-ir-global-shared-view name-text)
                    "__tl_spmd_ret_uniform___tl_spmd_pkg_"
                    0)
                  (lower.lower-string-prefix-at?
                    (ir.compiler-ir-global-shared-view name-text)
                    "__tl_spmd_ret_varying___tl_spmd_pkg_"
                    0)
                  (lower.lower-string-prefix-at?
                    name-text
                    "__tl_spmd_ret_mask___tl_spmd_pkg_"
                    0))
                  (set! count (+ count 1))
                  unit))])
          (set! index (+ index 1))))
      count)))

(define (compiler-lower-spmd-package-helper-count-ok?
  [source : String]
  [mode : lower.CompilerLowerMode]
  [wanted : i64]) : bool
  (let
    [result : lower.ResultCompilerLower
      (lower-compiler-source-with-mode-and-package source mode "spmd_fixture")]
    (match result
      [(Ok program _)
        (match program
          [(Program _ functions _)
            (= (compiler-lower-spmd-package-helper-count functions) wanted)])]
      [(Err _) false])))

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

(define (compiler-lower-spmd-package-uniform-helper-render-from
  [functions : ir.CompilerIrFunctionSeq]
  [index : i64]) : String
  (if (>= index functions.len)
    ""
    (let
      [function : ir.CompilerIrFunction
        (ir.compiler-ir-function-seq-ref functions index)]
      (match (ir.compiler-ir-global-shared-view function)
        [(Function name _ _ _ _ _)
          (if (lower.lower-string-prefix-at?
            (ir.compiler-ir-symbol-text name)
            "__tl_spmd_ret_uniform___tl_spmd_pkg_"
            0)
            (ir.compiler-ir-function-render
              (cis.InternStructuralSessionHandle 0)
              (ast.ast-node-pool-reader-type-segment-bases)
              function)
            (compiler-lower-spmd-package-uniform-helper-render-from
              functions
              (+ index 1)))]))))

(define (compiler-lower-spmd-package-uniform-helper-render
  [functions : ir.CompilerIrFunctionSeq]) : String
  (compiler-lower-spmd-package-uniform-helper-render-from functions 0))

(define (compiler-lower-spmd-package-return-context-source-ok?
  [source : String]) : bool
  (let
    [result : lower.ResultCompilerLower
      (lower-compiler-source-with-mode-and-package
        source
        (lower.CompilerLowerMode.Avx512)
        "spmd_fixture")]
    (match result
      [(Ok program _)
        (match program
          [(Program _ functions _)
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
      [(Err _) false])))

(define (compiler-lower-spmd-package-return-context-ok?) : bool
  (and
    (compiler-lower-spmd-package-return-context-source-ok?
      (compiler-lower-spmd-package-literal-return-source))
    (compiler-lower-spmd-package-return-context-source-ok?
      (compiler-lower-spmd-package-cast-return-source))))

(define (compiler-lower-spmd-package-callable-error-ok?
  [source : String]
  [mode : lower.CompilerLowerMode]
  [wanted : String]) : bool
  (let
    [result : lower.ResultCompilerLower
      (lower-compiler-source-with-mode-and-package source mode "spmd_fixture")]
    (match result
      [(Ok _ _) false]
      [(Err diag)
        (string.eq
          (cdiag.compiler-diagnostic-message (__tl-box-place diag))
          wanted)])))

(define (compiler-lower-spmd-package-symbol-collision-ok?) : bool
  (let
    [state : lower.CompilerLowerState
      (lower.compiler-lower-state-new-with-intern-state
        (ci.intern-compat-state-new))]
    [_package : unit
      (lower.compiler-lower-state-set-spmd-package! state "collision_fixture")]
    [intern-state : ci.InternCompatState
      (lower.compiler-lower-state-interns state)]
    [classes : ast.AstSpmdParamClassList (ast.ast-spmd-param-class-list-new)]
    [canonical-handle : i64
      (ci.intern-compat-state-intern (&mut intern-state) "collision/helper")]
    ;; The result type is a typed structural component even though this
    ;; deliberately inconsistent fixture keeps the old serialized signature
    ;; byte-identical. Both recipes therefore produce the same stable hash and
    ;; linker spelling while retaining distinct identity and symbol handles.
    [identity-a : i64
      (lower.lower-spmd-package-structural-symbol
        state
        "collision_fixture"
        "collision/helper"
        canonical-handle
        "(-> i64)"
        (I64)
        (Scalar)
        1
        classes
        (Uniform)
        -1)]
    [identity-b : i64
      (lower.lower-spmd-package-structural-symbol
        state
        "collision_fixture"
        "collision/helper"
        canonical-handle
        "(-> i64)"
        (F64)
        (Scalar)
        1
        classes
        (Uniform)
        -1)]
    [expected-symbol : String
      (lower.lower-spmd-package-symbol
        "collision_fixture"
        "collision/helper"
        "(-> i64)"
        (I64)
        (Scalar)
        1
        ""
        "u"
        -1)]
    [first : lower.LowerSpmdPackageSymbolRegistration
      (lower.lower-spmd-package-symbol-register
        state
        (lower.lower-spmd-package-structural-linker-symbol
          intern-state
          identity-a)
        (lower.lower-spmd-package-structural-registration-key
          intern-state
          identity-a)
        (lower.lower-spmd-package-structural-identity
          (owned_view.compiler-owned-shared-view intern-state)
          identity-a))]
    [repeat : lower.LowerSpmdPackageSymbolRegistration
      (lower.lower-spmd-package-symbol-register
        state
        (lower.lower-spmd-package-structural-linker-symbol
          intern-state
          identity-a)
        (lower.lower-spmd-package-structural-registration-key
          intern-state
          identity-a)
        (lower.lower-spmd-package-structural-identity
          (owned_view.compiler-owned-shared-view intern-state)
          identity-a))]
    [collision : lower.LowerSpmdPackageSymbolRegistration
      (lower.lower-spmd-package-symbol-register
        state
        (lower.lower-spmd-package-structural-linker-symbol
          intern-state
          identity-b)
        (lower.lower-spmd-package-structural-registration-key
          intern-state
          identity-b)
        (lower.lower-spmd-package-structural-identity
          (owned_view.compiler-owned-shared-view intern-state)
          identity-b))]
    (and
      (not
        (=
          (lower.lower-spmd-package-structural-identity
            (owned_view.compiler-owned-shared-view intern-state)
            identity-a)
          (lower.lower-spmd-package-structural-identity
            (owned_view.compiler-owned-shared-view intern-state)
            identity-b)))
      (not
        (=
          (lower.lower-spmd-package-structural-linker-symbol
            intern-state
            identity-a)
          (lower.lower-spmd-package-structural-linker-symbol
            intern-state
            identity-b)))
      (=
        (lower.lower-spmd-package-structural-registration-key
          intern-state
          identity-a)
        (lower.lower-spmd-package-structural-registration-key
          intern-state
          identity-b))
      (match first
        [(New) true]
        [_ false])
      (match repeat
        [(Existing) true]
        [_ false])
      (match collision
        [(Collision message)
          (string.eq
            message
            (str_cat.str-cat
              "lower: :spmd-callable stable symbol collision for "
              expected-symbol))]
        [_ false]))))

(define (compiler-lower-spmd-package-test-classes
  [first : ast.AstSpmdParamClass]
  [second : ast.AstSpmdParamClass]) : ast.AstSpmdParamClassList
  (let
    [classes : ast.AstSpmdParamClassList (ast.ast-spmd-param-class-list-new)]
    (begin
      (ast.ast-spmd-param-class-list-push (&mut classes) first)
      (ast.ast-spmd-param-class-list-push (&mut classes) second)
      classes)))

(define (compiler-lower-spmd-test-identity
  [state : lower.CompilerLowerState]
  [record : i64]) : i64
  (lower.lower-spmd-package-structural-identity
    (lower.compiler-lower-state-interns state)
    record))

(define (compiler-lower-spmd-test-symbol
  [state : lower.CompilerLowerState]
  [record : i64]) : i64
  (let
    [intern-state (lower.compiler-lower-state-interns state)]
    (lower.lower-spmd-package-structural-linker-symbol intern-state record)))

(define (compiler-lower-spmd-test-registration-key
  [state : lower.CompilerLowerState]
  [record : i64]) : i64
  (let
    [intern-state (lower.compiler-lower-state-interns state)]
    (lower.lower-spmd-package-structural-registration-key intern-state record)))

(define (compiler-lower-spmd-test-identity-components
  [state : lower.CompilerLowerState]
  [record : i64]) : i64
  (lower-spmd-package-structural-identity-components
    (lower.compiler-lower-state-interns state)
    record))

(define (compiler-lower-spmd-structural-symbols-ok?) : bool
  (let
    [state-a : lower.CompilerLowerState
      (lower.compiler-lower-state-new-with-intern-state
        (ci.intern-compat-state-new))]
    [state-b : lower.CompilerLowerState
      (lower.compiler-lower-state-new-with-intern-state
        (ci.intern-compat-state-new))]
    [_package-a : unit
      (lower.compiler-lower-state-set-spmd-package! state-a "pkg-a")]
    [_package-b : unit
      (lower.compiler-lower-state-set-spmd-package! state-b "pkg-a")]
    [intern-a : ci.InternCompatState
      (lower.compiler-lower-state-interns state-a)]
    [intern-b : ci.InternCompatState
      (lower.compiler-lower-state-interns state-b)]
    [canonical-a : i64
      (ci.intern-compat-state-intern (&mut intern-a) "pkg-a/helper")]
    [canonical-b : i64
      (ci.intern-compat-state-intern (&mut intern-b) "pkg-a/helper")]
    [varying-uniform : ast.AstSpmdParamClassList
      (compiler-lower-spmd-package-test-classes Varying Uniform)]
    [uniform-varying : ast.AstSpmdParamClassList
      (compiler-lower-spmd-package-test-classes Uniform Varying)]
    [base : i64
      (lower.lower-spmd-package-structural-symbol
        state-a
        "pkg-a"
        "pkg-a/helper"
        canonical-a
        "(-> i64 i64 i64)"
        (I64)
        (Avx512)
        8
        varying-uniform
        (Varying)
        0)]
    [repeat : i64
      (lower.lower-spmd-package-structural-symbol
        state-a
        "pkg-a"
        "pkg-a/helper"
        canonical-a
        "(-> i64 i64 i64)"
        (I64)
        (Avx512)
        8
        varying-uniform
        (Varying)
        0)]
    [different-lanes : i64
      (lower.lower-spmd-package-structural-symbol
        state-a
        "pkg-a"
        "pkg-a/helper"
        canonical-a
        "(-> i64 i64 i64)"
        (I64)
        (Avx512)
        16
        varying-uniform
        (Varying)
        0)]
    [different-args : i64
      (lower.lower-spmd-package-structural-symbol
        state-a
        "pkg-a"
        "pkg-a/helper"
        canonical-a
        "(-> i64 i64 i64)"
        (I64)
        (Avx512)
        8
        uniform-varying
        (Varying)
        0)]
    [different-result : i64
      (lower.lower-spmd-package-structural-symbol
        state-a
        "pkg-a"
        "pkg-a/helper"
        canonical-a
        "(-> i64 i64 i64)"
        (I64)
        (Avx512)
        8
        varying-uniform
        (Uniform)
        0)]
    [other-state : i64
      (lower.lower-spmd-package-structural-symbol
        state-b
        "pkg-a"
        "pkg-a/helper"
        canonical-b
        "(-> i64 i64 i64)"
        (I64)
        (Avx512)
        8
        varying-uniform
        (Varying)
        0)]
    [source-name : i64 (ci.intern-generated-canonical-name "value")]
    [private-param : i64
      (lower.lower-spmd-private-param-symbol
        state-a
        source-name
        (Varying)
        (lower.CompilerLowerMode.Avx2))]
    [private-param-repeat : i64
      (lower.lower-spmd-private-param-symbol
        state-a
        source-name
        (Varying)
        (lower.CompilerLowerMode.Avx2))]
    [private-param-mask : i64
      (lower.lower-spmd-private-param-symbol
        state-a
        source-name
        (Mask)
        (lower.CompilerLowerMode.Avx2))]
    [private-param-text : String
      (lower.lower-spmd-private-param-name
        state-a
        source-name
        (Varying)
        (lower.CompilerLowerMode.Avx2))]
    [private-helper : i64
      (lower.lower-spmd-private-helper-symbol
        state-a
        (ci.intern-compat-state-intern (&mut intern-a) "__tl_lambda_fixture_0")
        (Bool)
        true)]
    [expected-identity : String
      (lower.lower-spmd-package-symbol-identity
        "pkg-a"
        "pkg-a/helper"
        "(-> i64 i64 i64)"
        (Avx512)
        8
        "vu"
        "v"
        0)]
    [expected-symbol : String
      (lower.lower-spmd-package-symbol
        "pkg-a"
        "pkg-a/helper"
        "(-> i64 i64 i64)"
        (I64)
        (Avx512)
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
      (lower.lower-materialize-generated-role-symbols! state-a)
      (lower.lower-materialize-generated-role-symbols! state-b)
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
          (lower.compiler-lower-state-reset! state-b)
          (ci.intern-compat-state-reset! (&mut intern-b))
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
                  (lower.compiler-lower-profile-value
                    state-a
                    lower.compiler-lower-profile-spmd-identity-serializations-metric)
                  4)
                (=
                  (lower.compiler-lower-profile-value
                    state-a
                    lower.compiler-lower-profile-spmd-stable-hash-computations-metric)
                  4)
                (=
                  (lower.compiler-lower-profile-value
                    state-a
                    lower.compiler-lower-profile-spmd-render-cache-misses-metric)
                  4)
                (>=
                  (lower.compiler-lower-profile-value
                    state-a
                    lower.compiler-lower-profile-spmd-render-cache-hits-metric)
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
      (lower.CompilerLowerMode.Avx512)
      "lower: :spmd-callable varying body requires result varying")
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 8) (args uniform) (result uniform) (index-param 0)))
      : i64 x)"
      (lower.CompilerLowerMode.Avx512)
      "lower: :spmd-callable index-param must name a varying argument")
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param 0)))
  : i64
  (unsafe (+ x 1)))"
      (lower.CompilerLowerMode.Avx512)
      "lower: :spmd-callable body does not support SPMD specialization")))

(define (compiler-lower-spmd-package-callable-recursion-errors-ok?) : bool
  (compiler-lower-spmd-package-callable-error-ok?
    "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param 0)))
  : i64
  (helper x))"
    (lower.CompilerLowerMode.Avx512)
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
    (lower.CompilerLowerMode.Avx512)
    "lower: recursive SPMD helper call is not supported"))

(define (compiler-lower-spmd-package-callable-abi-errors-ok?) : bool
  (and
    (compiler-lower-spmd-package-callable-error-ok?
      (compiler-lower-spmd-package-callable-source)
      (lower.CompilerLowerMode.Avx2)
      "lower: :spmd-callable is not supported in AVX2 backend mode; use scalar or avx512")
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : String])
  (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param none)))
  : String
  x)"
      (lower.CompilerLowerMode.Avx512)
      "lower: :spmd-callable parameter type is not supported by private ABI v1")
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 16) (args varying) (result varying) (index-param 0)))
  : i64
  x)"
      (lower.CompilerLowerMode.Avx512)
      "lower: :spmd-callable lane width does not match varying parameter type")
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : i64])
  (:spmd-callable (specialization (lanes 2) (args uniform) (result uniform) (index-param none)))
  : i64
  x)"
      (lower.CompilerLowerMode.Avx512)
      "lower: :spmd-callable lane width is not supported by private ABI v1")
    (compiler-lower-spmd-package-callable-error-ok?
      "(module spmd_fixture)
(define (helper [x : f64])
  (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param 0)))
  : f64
  x)"
      (lower.CompilerLowerMode.Avx512)
      "lower: :spmd-callable index-param must name an i64 parameter")
    (compiler-lower-spmd-package-symbol-collision-ok?)))

;; Package producers are built by the same private helper lowering, so they
;; carry the private ABI as well. A declared `index-param` reuses that varying
;; source parameter where a same-program call site would append an index base;
;; the scalar backend never maps an index (#7405).
(define (compiler-lower-spmd-package-private-abi-ok?
  [mode : lower.CompilerLowerMode]
  [expected : String]) : bool
  (match (lower-compiler-source-with-mode-and-package
    (compiler-lower-spmd-package-callable-source)
    mode
    "spmd_fixture")
    [(Ok program _)
      (match program
        [(Program _ functions _)
          (and
            (string.eq
              (ir.compiler-ir-spmd-private-abi-program-error functions)
              "")
            (string.eq
              (ir.compiler-ir-test-spmd-private-abi-shapes functions)
              expected))])]
    [(Err _) false]))

(define (compiler-lower-spmd-package-callable-tests-ok?) : bool
  (and
    (compiler-lower-spmd-structural-symbols-ok?)
    (compiler-lower-spmd-package-helper-count-ok?
      (compiler-lower-spmd-package-callable-source)
      (lower.CompilerLowerMode.Scalar)
      2)
    (compiler-lower-spmd-package-helper-count-ok?
      (compiler-lower-spmd-package-callable-source)
      (lower.CompilerLowerMode.Avx512)
      2)
    (compiler-lower-spmd-package-helper-count-ok?
      (compiler-lower-spmd-package-scalar-collapse-source)
      (lower.CompilerLowerMode.Scalar)
      1)
    (compiler-lower-spmd-package-helper-count-ok?
      (compiler-lower-spmd-package-scalar-collapse-source)
      (lower.CompilerLowerMode.Avx512)
      2)
    (compiler-lower-spmd-package-return-context-ok?)
    (compiler-lower-spmd-package-private-abi-ok?
      (lower.CompilerLowerMode.Avx512)
      (str_cat.str-cat
        "avx512 lanes 8 [0 active-mask : bool, 1 source 0 varying i64 : i64,"
        " 2 source 1 uniform i64 : i64] index source 0 result varying i64 | "
        "avx512 lanes 8 [0 active-mask : bool, 1 source 0 uniform i64 : i64,"
        " 2 source 1 varying i64 : i64] index source 1 result varying i64"))
    (compiler-lower-spmd-package-private-abi-ok?
      (lower.CompilerLowerMode.Scalar)
      (str_cat.str-cat
        "scalar lanes 1 [0 active-mask : bool, 1 source 0 varying i64 : i64,"
        " 2 source 1 uniform i64 : i64] index none result varying i64 | "
        "scalar lanes 1 [0 active-mask : bool, 1 source 0 uniform i64 : i64,"
        " 2 source 1 varying i64 : i64] index none result varying i64"))))

(define (lower-spmd-package-structural-identity-components
  [intern-state : ci.InternCompatState]
  [record : i64]) : i64
  (ci.intern-compat-state-composite-right-id-unchecked
    intern-state
    (ci.intern-compat-state-composite-right-id-unchecked intern-state record)))

(define (lower-compiler-source-with-mode-and-package
  [src : String]
  [mode : lower.CompilerLowerMode]
  [package-name : String]) : lower.ResultCompilerLower
  (lower.lower-compiler-source-with-path-mode-package-and-state
    (lower.compiler-lower-state-new)
    "<source>"
    src
    mode
    package-name))