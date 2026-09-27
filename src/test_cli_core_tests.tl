;; test_cli_core_tests.tl - White-box tests for the test CLI: batch paths, seeded
;; shuffle and selection, harness reachability and imported-test pruning.
(import compiler_owned_view as owned_view)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.process)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as tltest_name_map)
(import stdlib.vector)
(import (vector.vector String) as cli_svec)
(import build_run_core)
(import compiler_ast_types as ast)
(import compiler_ast_types_tests as ast_tests)
(import compiler_backend as backend)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic as cdiag)
(import compiler_driver_core as driver)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_ir_types as ir)
(import compiler_load)
(import compiler_lower as lower)
(import compiler_typecheck_api)
(import stdlib.string)
(import test_cli_core as tltest)

(define (tltest-write-text [path : (& path str)] [contents : String]) : unit
  (io.write-file path (byte_buf.str-as-bytes (& contents))))

(define (tltest-eq-id) : i64
  (begin
    (cbi.compiler-builtin-refresh!)
    cbi.compiler-builtin-id-eq))

(define (tltest-string-id) : i64
  (begin
    (cbi.compiler-builtin-refresh!)
    cbi.compiler-builtin-id-fix-string))

(test
  test-batch-paths-vector-preserves-order
  (if (let
    [paths : cli_svec.Vec
      (tltest.tltest-batch-paths-from-text "a.tl\n\nb.tl\r\nc.tl")]
    (and
      (= (cli_svec.len (& paths)) 3)
      (string.eq (cli_svec.get (& paths) 0 "") "a.tl")
      (string.eq (cli_svec.get (& paths) 1 "") "b.tl")
      (string.eq (cli_svec.get (& paths) 2 "") "c.tl")))
    unit
    (io.panic "test: batch path vector self-test mismatch")))

(define (tltest-shuffle-golden-permutation-ok?) : bool
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 5)]
    [state : u64 (tltest.tltest-shuffle-initial-state (cast 42 : u64))]
    [index : i64 4]
    (begin
      (set! (array-ref items 0) 0)
      (set! (array-ref items 1) 1)
      (set! (array-ref items 2) 2)
      (set! (array-ref items 3) 3)
      (set! (array-ref items 4) 4)
      (while (> index 0)
        (let
          [next-state : u64 (tltest.tltest-xorshift64-next state)]
          [other : i64 (cast (% next-state (cast (+ index 1) : u64)) : i64)]
          [saved : i64 (array-ref items index)]
          (begin
            (set! state next-state)
            (set! (array-ref items index) (array-ref items other))
            (set! (array-ref items other) saved)
            (set! index (- index 1)))))
      (and
        (= (array-ref items 0) 3)
        (= (array-ref items 1) 0)
        (= (array-ref items 2) 2)
        (= (array-ref items 3) 4)
        (= (array-ref items 4) 1)))))

(test
  test-cli-replayable-shuffle-and-selection
  (if (and
    (match (tltest.tltest-parse-seed "0")
      [(tltest.ResultTestSeed.Ok value) (= value (cast 0 : u64))]
      [_ false])
    (match (tltest.tltest-parse-seed "18446744073709551615")
      [(tltest.ResultTestSeed.Ok value)
        (and
          (= value (bit-not (cast 0 : u64)))
          (string.eq (tltest.tltest-u64-decimal value) "18446744073709551615"))]
      [_ false])
    (match (tltest.tltest-parse-seed "18446744073709551616")
      [(tltest.ResultTestSeed.Err _) true]
      [_ false])
    (match (tltest.tltest-parse-seed "-1")
      [(tltest.ResultTestSeed.Err _) true]
      [_ false])
    (tltest-shuffle-golden-permutation-ok?)
    (match (tltest.tltest-test-selection-with
      (ast.ast-test-metadata-new (ast.AstTestIgnoreReason.Some "reason") false)
      false
      false)
      [(tltest.InlineTestSelection.Ignored reason) (string.eq reason "reason")]
      [_ false])
    (match (tltest.tltest-test-selection-with
      (ast.ast-test-metadata-new ast.AstTestIgnoreReason.No true)
      false
      false)
      [(tltest.InlineTestSelection.SlowSkipped) true]
      [_ false])
    (match (tltest.tltest-test-selection-with
      (ast.ast-test-metadata-new (ast.AstTestIgnoreReason.Some "reason") true)
      true
      false)
      [(tltest.InlineTestSelection.SlowSkipped) true]
      [_ false])
    (match (tltest.tltest-test-selection-with
      (ast.ast-test-metadata-new (ast.AstTestIgnoreReason.Some "reason") true)
      true
      true)
      [(tltest.InlineTestSelection.Run) true]
      [_ false]))
    unit
    (io.panic "test CLI replayable shuffle/selection self-test mismatch")))

(define (tltest-path-at [paths : (& paths ast.AstDeclPathList)] [index : i64]) : String
  (match (ast.ast-decl-path-list-step paths)
    [(ast.AstDeclPathListStep.Nil) ""]
    [(ast.AstDeclPathListStep.Cons path rest)
      (if (= index 0)
        path
        (tltest-path-at rest (- index 1)))]))

(define (tltest-decl-name [decl : ast.AstDecl]) : String
  (match decl
    [(ast.AstDecl.Def decl-meta name _ _) (ci.intern-str name)]
    [(ast.AstDecl.DefFn decl-meta name _ _ _ _) (ci.intern-str name)]
    [(ast.AstDecl.DefMacro decl-meta name _ _ _) (ci.intern-str name)]
    [(ast.AstDecl.Extern decl-meta name _ _ _) (ci.intern-str name)]
    [(ast.AstDecl.Unsafe inner-box)
      (let
        [inner : ast.AstDecl (deref inner-box)]
        (tltest-decl-name inner))]
    [_ ""]))

(define (tltest-decl-name-at [decls : (& decls ast.AstDeclList)] [index : i64]) : String
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) ""]
    [(ast.AstDeclListStep.Cons decl rest)
      (if (= index 0)
        (tltest-decl-name decl)
        (tltest-decl-name-at rest (- index 1)))]))

(define (tltest-decl-list-has-name?
  [decls : (& decls ast.AstDeclList)]
  [name : String]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) false]
    [(ast.AstDeclListStep.Cons decl rest)
      (if (string.eq (tltest-decl-name decl) name)
        true
        (tltest-decl-list-has-name? rest name))]))

(test
  test-cli-inline-harness-keeps-alias-qualified-base
  (if (let
    [_builtin-init : unit (cbi.compiler-builtin-initialize-for-parse!)]
    [span : ast.AstSourceSpan (ast.ast-source-span 1 1 1 1)]
    [dep-path : String "stdlib/string.tl"]
    [source : String "stdlib/args.tl"]
    [stdlib-string-id : i64 (ci.intern-generated-name "stdlib.string")]
    [stdlib-args-id : i64 (ci.intern-generated-name "stdlib.args")]
    [string-id : i64 (tltest-string-id)]
    [eq-id : i64 (tltest-eq-id)]
    [string-eq-id : i64
      (ci.intern-generated-dotted-name "string.eq" string-id string-id eq-id)]
    [owned-id : i64 (ci.intern-generated-name "owned")]
    [dep-fn : ast.AstDecl
      (ast.ast-decl-def-fn-id
        eq-id
        (ast.ast-param-list-new)
        (ast.AstType.Bool)
        (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Bool true))))]
    [source-import : ast.AstDecl
      (ast.AstDecl.Import
        (ast.ast-decl-meta-runtime-shared-view)
        (ast.AstImportSpec.Spec
          (ast.AstImportKind.Module)
          (owned_view.compiler-owned-shared-view dep-path)
          (ast.AstMaybeModuleName.Some stdlib-string-id)
          (ast.AstMaybeImportAlias.Some string-id)
          (box span)))]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons
        (ast.ast-decl-module-id stdlib-string-id)
        (ast.ast-decl-cons
          dep-fn
          (ast.ast-decl-cons
            (ast.ast-decl-module-id stdlib-args-id)
            (ast.ast-decl-cons
              source-import
              (ast.ast-decl-cons
                (ast.ast-decl-test-id
                  owned-id
                  (tltest.tltest-call-expr-id string-eq-id)
                  span)
                (ast.ast-decl-list-new))))))]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-root-path-cons
        (owned_view.compiler-owned-shared-view dep-path)
        (ast.ast-decl-root-path-cons
          dep-path
          (ast.ast-decl-root-path-cons
            (owned_view.compiler-owned-shared-view source)
            (ast.ast-decl-root-path-cons
              (owned_view.compiler-owned-shared-view source)
              (ast.ast-decl-root-path-cons
                (owned_view.compiler-owned-shared-view source)
                (ast.ast-decl-path-list-new))))))]
    (match (tltest.tltest-build-harness source decls paths)
      [(tltest.InlineHarness.Harness program _ count)
        (match program
          [(ast.AstProgram.Program harness-decls-box)
            (and
              (= count 1)
              (tltest-decl-list-has-name? (deref harness-decls-box) "eq"))])]))
    unit
    (io.panic "test CLI alias-qualified reachability mismatch")))

(test
  test-cli-vector-builders-preserve-order
  (if (let
    [helper-name : String "__tl_fixture_helper"]
    [helper-id : i64
      (ci.intern-generated-name
        (owned_view.compiler-owned-shared-view helper-name))]
    [first-id : i64 (ci.intern-generated-name "first")]
    [second-id : i64 (ci.intern-generated-name "second")]
    [helper-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        helper-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit))))]
    [first-span : ast.AstSourceSpan (ast.ast-source-span 11 1 11 1)]
    [second-span : ast.AstSourceSpan (ast.ast-source-span 22 1 22 1)]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons
        helper-decl
        (ast.ast-decl-cons
          (ast.ast-decl-test-id
            first-id
            (tltest.tltest-call-expr-id helper-id)
            first-span)
          (ast.ast-decl-cons
            (ast.ast-decl-test-id
              second-id
              (tltest.tltest-call-expr-id helper-id)
              second-span)
            (ast.ast-decl-list-new))))]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-root-path-cons
        "runtime.tl"
        (ast.ast-decl-root-path-cons
          "driver.tl"
          (ast.ast-decl-root-path-cons "driver.tl" (ast.ast-decl-path-list-new))))]
    (match (tltest.tltest-build-harness "driver.tl" decls paths)
      [(tltest.InlineHarness.Harness program harness-paths count)
        (match program
          [(ast.AstProgram.Program harness-decls-box)
            (let
              [harness-decls : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view harness-decls-box)]
              (and
                (= count 2)
                (string.eq (tltest-decl-name-at harness-decls 0) helper-name)
                (string.eq (tltest-decl-name-at harness-decls 1) "")
                (string.eq
                  (tltest-decl-name-at harness-decls 2)
                  "__tl_inline_test_0")
                (string.eq (tltest-decl-name-at harness-decls 3) "")
                (string.eq
                  (tltest-decl-name-at harness-decls 4)
                  "__tl_inline_test_1")
                (string.eq (tltest-decl-name-at harness-decls 5) "")
                (string.eq (tltest-decl-name-at harness-decls 6) "")
                (string.eq (tltest-decl-name-at harness-decls 7) "main")
                (string.eq (tltest-path-at harness-paths 0) "runtime.tl")
                (string.eq (tltest-path-at harness-paths 1) "driver.tl")
                (string.eq (tltest-path-at harness-paths 2) "driver.tl")
                (string.eq (tltest-path-at harness-paths 3) "driver.tl")
                (string.eq (tltest-path-at harness-paths 4) "driver.tl")
                (string.eq (tltest-path-at harness-paths 5) "driver.tl")
                (string.eq (tltest-path-at harness-paths 6) "driver.tl")
                (string.eq (tltest-path-at harness-paths 7) "driver.tl")))])]))
    unit
    (io.panic "test CLI vector builder order mismatch")))

(test
  test-cli-inline-harness-keeps-global-field-roots
  (if (let
    [_builtin-init : unit (cbi.compiler-builtin-initialize-for-parse!)]
    [seed : i64 (ci.intern "field-root-seed")]
    [owner : i64 (ci.intern "field-root-owner")]
    [dead : i64 (ci.intern "field-root-unrelated")]
    [field : i64 (ci.intern "field-root-owner.nested.value")]
    [unit-expr : i64
      (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit)))]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons
        (ast.ast-decl-def-id seed (ast.AstMaybeType.No) unit-expr)
        (ast.ast-decl-cons
          (ast.ast-decl-def-id
            owner
            (ast.AstMaybeType.No)
            (ast.ast-node-push (ast.AstExpr.Var seed)))
          (ast.ast-decl-cons
            (ast.ast-decl-def-id dead (ast.AstMaybeType.No) unit-expr)
            (ast.ast-decl-cons
              (ast.ast-decl-test-id
                (ci.intern "uses-global-field-root")
                (ast.ast-node-push (ast.AstExpr.Var field))
                (ast.ast-source-span 1 1 1 1))
              (ast.ast-decl-list-new)))))]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-root-path-cons
        "field-root.tl"
        (ast.ast-decl-root-path-cons
          "field-root.tl"
          (ast.ast-decl-root-path-cons
            "field-root.tl"
            (ast.ast-decl-root-path-cons
              "field-root.tl"
              (ast.ast-decl-path-list-new)))))]
    (match (tltest.tltest-build-harness "field-root.tl" decls paths)
      [(tltest.InlineHarness.Harness program _ count)
        (match program
          [(ast.AstProgram.Program harness-decls-box)
            (let
              [kept : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view harness-decls-box)]
              (and
                (= count 1)
                (tltest-decl-list-has-name? kept "field-root-owner")
                (tltest-decl-list-has-name? kept "field-root-seed")
                (not (tltest-decl-list-has-name? kept "field-root-unrelated"))))])]))
    unit
    (io.panic "test CLI global field root reachability mismatch")))

(test
  test-cli-inline-harness-keeps-structural-global-field-roots
  (if (let
    [_builtin-init : unit (cbi.compiler-builtin-initialize-for-parse!)]
    [owner-state : ci.InternCompatState (ci.intern-compat-state-new)]
    [root-id : i64
      (ci.intern-compat-state-intern (&mut owner-state) "structural-field-root")]
    [field-id : i64
      (ci.intern-compat-state-intern
        (&mut owner-state)
        "structural-field-root.nested.value")]
    [module-id : i64
      (ci.intern-compat-state-intern (&mut owner-state) "field-module")]
    [dead-id : i64
      (ci.intern-compat-state-intern (&mut owner-state) "unrelated-field-root")]
    [session : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names
        (ci.intern-source-name-session-handle
          (ci.intern-source-name-session-from-state owner-state)))]
    [pair-id : i64
      (cis.intern-structural-key-raw
        (cis.intern-structural-session-composite-pair-key
          session
          module-id
          field-id))]
    [triple-id : i64
      (cis.intern-structural-key-raw
        (cis.intern-structural-session-composite-triple-key
          session
          module-id
          module-id
          field-id))]
    [owner-id : i64
      (cis.intern-structural-key-raw
        (cis.intern-structural-session-composite-pair-key
          session
          module-id
          root-id))]
    [marked : tltest_name_map.Map
      (tltest.tltest-reach-mark-source-name
        session
        (tltest_name_map.with-capacity 8)
        pair-id)]
    (and
      (= (tltest.tltest-reach-name-source-base-id session pair-id) field-id)
      (= (tltest.tltest-reach-name-source-base-id session triple-id) pair-id)
      (tltest.tltest-reachable-name-marked? session (& marked) owner-id)
      (not (tltest.tltest-reachable-name-marked? session (& marked) dead-id))))
    unit
    (io.panic "test CLI structural field owner reachability mismatch")))

(test
  test-cli-inline-harness-normalizes-inactive-field-owner
  (if (let
    [home : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [decoy : ci.InternCompatState (ci.intern-compat-state-new)]
    [decoy-id : i64
      (ci.intern-compat-state-intern
        (&mut decoy)
        "__tl_macro_global$probe/foreign")]
    [owner : ci.InternCompatState (ci.intern-compat-state-new)]
    [index : i64 0]
    [_fill : unit
      (while (< (ci.intern-compat-state-pool-len (& owner)) decoy-id)
        (begin
          (ci.intern-compat-state-intern
            (&mut owner)
            (string.int->string index))
          (set! index (+ index 1))))]
    [field-id : i64 (ci.intern-compat-state-intern (&mut owner) "owner.field")]
    [session : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names
        (ci.intern-source-name-session-handle
          (ci.intern-source-name-session-from-state owner)))]
    (begin
      (unless (= decoy-id field-id) (io.panic "probe setup IDs differ"))
      (ci.intern-compat-state-install! decoy)
      (unless
        (and
          (ci.intern-qualified? field-id)
          (ci.intern-macro-global-name-id? field-id))
        (io.panic "probe setup decoy not classified"))
      (let
        [valid : bool
          (=
            (tltest.tltest-reach-name-source-base-id session field-id)
            field-id)]
        (begin
          (ci.intern-compat-state-install! home)
          valid))))
    unit
    (io.panic "test CLI field owner normalization consulted the installed pool")))

(test
  test-cli-inline-harness-keeps-lowered-runtime-helpers
  (if (let
    [unit-expr : i64
      (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit)))]
    [substring-id : i64 cbi.compiler-builtin-id-runtime-substring]
    [str-view-id : i64 cbi.compiler-builtin-id-runtime-str-view]
    [bytes-view-id : i64 cbi.compiler-builtin-id-tl-bytes-view-from-str-parts]
    [helper-id : i64 (ci.intern-generated-name "__tl_generated_runtime_helper")]
    [test-id : i64 (ci.intern-generated-name "keeps-generated-runtime")]
    [substring-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        substring-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        unit-expr)]
    [str-view-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        str-view-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        unit-expr)]
    [helper-body : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons
            (ast.ast-expr-with-scratch
              (ast.ast-expr-cons unit-expr (ast.ast-expr-list-new)))
            (ast.ast-expr-cons
              (tltest.tltest-call-expr-id bytes-view-id)
              (ast.ast-expr-cons unit-expr (ast.ast-expr-list-new))))))]
    [helper-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        helper-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        helper-body)]
    [span : ast.AstSourceSpan (ast.ast-source-span 17 1 17 1)]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons
        substring-decl
        (ast.ast-decl-cons
          str-view-decl
          (ast.ast-decl-cons
            helper-decl
            (ast.ast-decl-cons
              (ast.ast-decl-test-id
                test-id
                (tltest.tltest-call-expr-id helper-id)
                span)
              (ast.ast-decl-list-new)))))]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-root-path-cons
        "stdlib/runtime.tl"
        (ast.ast-decl-root-path-cons
          "stdlib/runtime.tl"
          (ast.ast-decl-root-path-cons
            "driver.tl"
            (ast.ast-decl-root-path-cons
              "driver.tl"
              (ast.ast-decl-path-list-new)))))]
    (match (tltest.tltest-build-harness "driver.tl" decls paths)
      [(tltest.InlineHarness.Harness program _ count)
        (match program
          [(ast.AstProgram.Program harness-decls-box)
            (let
              [harness-decls : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view harness-decls-box)]
              (and
                (= count 1)
                (string.eq (tltest-decl-name-at harness-decls 0) "substring")
                (string.eq (tltest-decl-name-at harness-decls 1) "str-view")
                (string.eq
                  (tltest-decl-name-at harness-decls 2)
                  "__tl_generated_runtime_helper")))])]))
    unit
    (io.panic "test CLI inline harness dropped lowered runtime helper")))

(test
  test-cli-inline-harness-keeps-lambda-runtime-helper
  (if (let
    [unit-expr : i64
      (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit)))]
    [substring-id : i64 cbi.compiler-builtin-id-runtime-substring]
    [helper-id : i64 (ci.intern-generated-name "__tl_generated_lambda_helper")]
    [test-id : i64 (ci.intern-generated-name "keeps-generated-lambda-runtime")]
    [substring-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        substring-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        unit-expr)]
    [lambda-expr : i64
      (ast.ast-expr-lambda
        (ast.ast-param-list-new)
        ast.AstMaybeType.No
        unit-expr)]
    [helper-body : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons
            lambda-expr
            (ast.ast-expr-cons unit-expr (ast.ast-expr-list-new)))))]
    [helper-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        helper-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        helper-body)]
    [span : ast.AstSourceSpan (ast.ast-source-span 18 1 18 1)]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons
        substring-decl
        (ast.ast-decl-cons
          helper-decl
          (ast.ast-decl-cons
            (ast.ast-decl-test-id
              test-id
              (tltest.tltest-call-expr-id helper-id)
              span)
            (ast.ast-decl-list-new))))]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-root-path-cons
        "stdlib/runtime.tl"
        (ast.ast-decl-root-path-cons
          "driver.tl"
          (ast.ast-decl-root-path-cons "driver.tl" (ast.ast-decl-path-list-new))))]
    (match (tltest.tltest-build-harness "driver.tl" decls paths)
      [(tltest.InlineHarness.Harness program _ count)
        (match program
          [(ast.AstProgram.Program harness-decls-box)
            (let
              [harness-decls : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view harness-decls-box)]
              (and
                (= count 1)
                (string.eq (tltest-decl-name-at harness-decls 0) "substring")
                (string.eq
                  (tltest-decl-name-at harness-decls 1)
                  "__tl_generated_lambda_helper")))])]))
    unit
    (io.panic "test CLI inline harness dropped lambda runtime helper")))

(test
  test-cli-inline-harness-keeps-substring-runtime-helper
  (if (let
    [unit-expr : i64
      (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit)))]
    [substring-id : i64 cbi.compiler-builtin-id-runtime-substring]
    [helper-id : i64
      (ci.intern-generated-name "__tl_generated_substring_helper")]
    [test-id : i64
      (ci.intern-generated-name "keeps-generated-substring-runtime")]
    [substring-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        substring-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        unit-expr)]
    [helper-body : i64
      (ast.ast-node-push
        (ast.AstExpr.Begin
          (ast.ast-expr-cons
            (tltest.tltest-call-expr-id substring-id)
            (ast.ast-expr-cons unit-expr (ast.ast-expr-list-new)))))]
    [helper-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        helper-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        helper-body)]
    [span : ast.AstSourceSpan (ast.ast-source-span 19 1 19 1)]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons
        substring-decl
        (ast.ast-decl-cons
          helper-decl
          (ast.ast-decl-cons
            (ast.ast-decl-test-id
              test-id
              (tltest.tltest-call-expr-id helper-id)
              span)
            (ast.ast-decl-list-new))))]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-root-path-cons
        "stdlib/runtime.tl"
        (ast.ast-decl-root-path-cons
          "driver.tl"
          (ast.ast-decl-root-path-cons "driver.tl" (ast.ast-decl-path-list-new))))]
    (match (tltest.tltest-build-harness "driver.tl" decls paths)
      [(tltest.InlineHarness.Harness program _ count)
        (match program
          [(ast.AstProgram.Program harness-decls-box)
            (let
              [harness-decls : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view harness-decls-box)]
              (and
                (= count 1)
                (string.eq (tltest-decl-name-at harness-decls 0) "substring")
                (string.eq
                  (tltest-decl-name-at harness-decls 1)
                  "__tl_generated_substring_helper")))])]))
    unit
    (io.panic "test CLI inline harness dropped substring runtime helper")))

(test
  test-cli-inline-harness-skips-imported-tests
  (if (let
    [helper-name : String "__tl_imported_skip_helper"]
    [helper-id : i64
      (ci.intern-generated-name
        (owned_view.compiler-owned-shared-view helper-name))]
    [owned-id : i64 (ci.intern-generated-name "owned")]
    [imported-id : i64 (ci.intern-generated-name "imported")]
    [helper-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        helper-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit))))]
    [owned-span : ast.AstSourceSpan (ast.ast-source-span 5 1 5 1)]
    [imported-span : ast.AstSourceSpan (ast.ast-source-span 9 1 9 1)]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons
        helper-decl
        (ast.ast-decl-cons
          (ast.ast-decl-test-id
            owned-id
            (tltest.tltest-call-expr-id helper-id)
            owned-span)
          (ast.ast-decl-cons
            (ast.ast-decl-test-id
              imported-id
              (tltest.tltest-call-expr-id helper-id)
              imported-span)
            (ast.ast-decl-list-new))))]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-root-path-cons
        "driver.tl"
        (ast.ast-decl-root-path-cons
          "driver.tl"
          (ast.ast-decl-root-path-cons
            "imported.tl"
            (ast.ast-decl-path-list-new))))]
    (match (tltest.tltest-build-harness "driver.tl" decls paths)
      [(tltest.InlineHarness.Harness program harness-paths count)
        (match program
          [(ast.AstProgram.Program harness-decls-box)
            (let
              [harness-decls : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view harness-decls-box)]
              (and
                (= count 1)
                (string.eq (tltest-decl-name-at harness-decls 0) helper-name)
                (string.eq (tltest-decl-name-at harness-decls 1) "")
                (string.eq
                  (tltest-decl-name-at harness-decls 2)
                  "__tl_inline_test_0")
                (string.eq (tltest-decl-name-at harness-decls 3) "")
                (string.eq (tltest-decl-name-at harness-decls 4) "")
                (string.eq (tltest-decl-name-at harness-decls 5) "main")
                (string.eq (tltest-path-at harness-paths 0) "driver.tl")
                (string.eq (tltest-path-at harness-paths 1) "driver.tl")
                (string.eq (tltest-path-at harness-paths 2) "driver.tl")
                (string.eq (tltest-path-at harness-paths 3) "driver.tl")
                (string.eq (tltest-path-at harness-paths 4) "driver.tl")
                (string.eq (tltest-path-at harness-paths 5) "driver.tl")))])]))
    unit
    (io.panic "test CLI inline harness kept imported test")))

(define (tltest-import-alias-preserved? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Import
        decl-meta
        (ast.AstImportSpec.Spec
          _
          _
          (ast.AstMaybeModuleName.Some module)
          (ast.AstMaybeImportAlias.Some alias)
          _))
      (and
        (string.eq (ci.intern-str module) "stdlib.core_macros")
        (string.eq (ci.intern-str alias) "core"))]
    [_ false]))

(test
  test-cli-inline-harness-preserves-import-aliases
  (if (let
    [module-id : i64 (ci.intern-generated-name "stdlib.core_macros")]
    [alias-id : i64 (ci.intern-generated-name "core")]
    [test-id : i64 (ci.intern-generated-name "uses-qualified-macro-alias")]
    [import-decl : ast.AstDecl
      (ast.AstDecl.Import
        (ast.ast-decl-meta-runtime-shared-view)
        (ast.AstImportSpec.Spec
          (ast.AstImportKind.Module)
          "stdlib.core_macros"
          (ast.AstMaybeModuleName.Some module-id)
          (ast.AstMaybeImportAlias.Some alias-id)
          (box (ast.ast-source-span 0 0 0 0))))]
    [span : ast.AstSourceSpan (ast.ast-source-span 9 1 9 1)]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons
        import-decl
        (ast.ast-decl-cons
          (ast.ast-decl-test-id
            test-id
            (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit)))
            span)
          (ast.ast-decl-list-new)))]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-root-path-cons
        "alias.tl"
        (ast.ast-decl-root-path-cons "alias.tl" (ast.ast-decl-path-list-new)))]
    (match (tltest.tltest-build-harness "alias.tl" decls paths)
      [(tltest.InlineHarness.Harness program _ count)
        (match program
          [(ast.AstProgram.Program harness-decls-box)
            (match (ast.ast-decl-list-step (deref harness-decls-box))
              [(ast.AstDeclListStep.Cons first _)
                (and (= count 1) (tltest-import-alias-preserved? first))]
              [_ false])])]))
    unit
    (io.panic "test CLI inline harness dropped import alias")))

(test
  test-cli-inline-harness-keeps-runtime-string-helper-roots
  (if (let
    [dep-name : String "__tl_runtime_helper_dep"]
    [helper-name : String "substring"]
    [eq-dep-name : String "__tl_runtime_eq_dep"]
    [eq-name : String "eq"]
    [dep-id : i64
      (ci.intern-generated-name
        (owned_view.compiler-owned-shared-view dep-name))]
    [helper-id : i64 cbi.compiler-builtin-id-runtime-substring]
    [eq-dep-id : i64
      (ci.intern-generated-name
        (owned_view.compiler-owned-shared-view eq-dep-name))]
    [eq-id : i64 (tltest-eq-id)]
    [test-id : i64
      (ci.intern-generated-name "runtime-helper-not-called-by-test")]
    [dep-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        dep-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit))))]
    [helper-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        helper-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        (tltest.tltest-call-expr-id dep-id))]
    [eq-dep-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        eq-dep-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit))))]
    [eq-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        eq-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        (tltest.tltest-call-expr-id eq-dep-id))]
    [span : ast.AstSourceSpan (ast.ast-source-span 13 1 13 1)]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons
        dep-decl
        (ast.ast-decl-cons
          helper-decl
          (ast.ast-decl-cons
            eq-dep-decl
            (ast.ast-decl-cons
              eq-decl
              (ast.ast-decl-cons
                (ast.ast-decl-test-id
                  test-id
                  (ast.ast-node-push
                    (ast.AstExpr.Literal (ast.AstLiteral.Unit)))
                  span)
                (ast.ast-decl-list-new))))))]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-root-path-cons
        "stdlib/runtime.tl"
        (ast.ast-decl-root-path-cons
          "stdlib/runtime.tl"
          (ast.ast-decl-root-path-cons
            "stdlib/string.tl"
            (ast.ast-decl-root-path-cons
              "stdlib/string.tl"
              (ast.ast-decl-root-path-cons
                "driver.tl"
                (ast.ast-decl-path-list-new))))))]
    (match (tltest.tltest-build-harness "driver.tl" decls paths)
      [(tltest.InlineHarness.Harness program _ count)
        (match program
          [(ast.AstProgram.Program harness-decls-box)
            (let
              [harness-decls : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view harness-decls-box)]
              (and
                (= count 1)
                (tltest-decl-list-has-name? harness-decls helper-name)
                (tltest-decl-list-has-name? harness-decls dep-name)
                (tltest-decl-list-has-name? harness-decls eq-name)
                (tltest-decl-list-has-name? harness-decls eq-dep-name)))])]))
    unit
    (io.panic "test CLI inline harness pruned runtime string helper root")))

(test
  test-cli-inline-harness-keeps-required-atomic-runtime-helper
  (if (let
    [_builtin-init : unit (cbi.compiler-builtin-initialize-for-parse!)]
    [unit-expr : i64
      (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit)))]
    [fetch-name : String "atomic-i64-fetch-add-ptr!"]
    [load-name : String "atomic-i64-load-ptr"]
    [wrapper-name : String "__tl_atomic_runtime_caller"]
    [fetch-id : i64 cbi.compiler-builtin-id-runtime-atomic-i64-fetch-add-ptr]
    [load-id : i64 cbi.compiler-builtin-id-runtime-atomic-i64-load-ptr]
    [wrapper-id : i64
      (ci.intern-generated-name
        (owned_view.compiler-owned-shared-view wrapper-name))]
    [fetch-source-id : i64 cbi.compiler-builtin-id-atomic-i64-fetch-add]
    [test-id : i64 (ci.intern-generated-name "keeps-atomic-runtime-helper")]
    [fetch-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        fetch-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        unit-expr)]
    [load-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        load-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        unit-expr)]
    [wrapper-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        wrapper-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        (tltest.tltest-call-expr-id fetch-source-id))]
    [span : ast.AstSourceSpan (ast.ast-source-span 20 1 20 1)]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons
        fetch-decl
        (ast.ast-decl-cons
          load-decl
          (ast.ast-decl-cons
            wrapper-decl
            (ast.ast-decl-cons
              (ast.ast-decl-test-id
                test-id
                (tltest.tltest-call-expr-id wrapper-id)
                span)
              (ast.ast-decl-list-new)))))]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-root-path-cons
        "stdlib/runtime.tl"
        (ast.ast-decl-root-path-cons
          "stdlib/runtime.tl"
          (ast.ast-decl-root-path-cons
            "driver.tl"
            (ast.ast-decl-root-path-cons
              "driver.tl"
              (ast.ast-decl-path-list-new)))))]
    (match (tltest.tltest-build-harness "driver.tl" decls paths)
      [(tltest.InlineHarness.Harness program _ count)
        (match program
          [(ast.AstProgram.Program harness-decls-box)
            (let
              [harness-decls : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view harness-decls-box)]
              (and
                (= count 1)
                (tltest-decl-list-has-name? harness-decls fetch-name)
                (not (tltest-decl-list-has-name? harness-decls load-name))
                (tltest-decl-list-has-name? harness-decls wrapper-name)))])]))
    unit
    (io.panic "test CLI inline harness atomic runtime reachability mismatch")))

(define (tltest-generated-wrapper [item : String] [decl : ast.AstDecl]) : ast.AstDecl
  (ast.ast-decl-comptime-decl-with-meta
    (ast.AstGeneratedDeclMeta.Some
      "tltest-generated"
      item
      (ast.ast-expr-list-new)
      "tltest")
    decl))

(test
  test-cli-inline-harness-prunes-generated-wrappers
  (if (let
    [dep-name : String "__tl_generated_reachable_dep"]
    [live-name : String "__tl_generated_reachable_live"]
    [dead-name : String "__tl_generated_reachable_dead"]
    [dep-id : i64
      (ci.intern-generated-name
        (owned_view.compiler-owned-shared-view dep-name))]
    [live-id : i64
      (ci.intern-generated-name
        (owned_view.compiler-owned-shared-view live-name))]
    [dead-id : i64
      (ci.intern-generated-name
        (owned_view.compiler-owned-shared-view dead-name))]
    [test-id : i64 (ci.intern-generated-name "uses-generated-live")]
    [dep-decl : ast.AstDecl
      (tltest-generated-wrapper
        (owned_view.compiler-owned-shared-view dep-name)
        (ast.ast-decl-def-fn-id
          dep-id
          (ast.ast-param-list-new)
          (ast.AstType.Unit)
          (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit)))))]
    [live-decl : ast.AstDecl
      (tltest-generated-wrapper
        (owned_view.compiler-owned-shared-view live-name)
        (ast.ast-decl-def-fn-id
          live-id
          (ast.ast-param-list-new)
          (ast.AstType.Unit)
          (tltest.tltest-call-expr-id dep-id)))]
    [dead-decl : ast.AstDecl
      (tltest-generated-wrapper
        (owned_view.compiler-owned-shared-view dead-name)
        (ast.ast-decl-def-fn-id
          dead-id
          (ast.ast-param-list-new)
          (ast.AstType.Unit)
          (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit)))))]
    [span : ast.AstSourceSpan (ast.ast-source-span 23 1 23 1)]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons
        dep-decl
        (ast.ast-decl-cons
          live-decl
          (ast.ast-decl-cons
            dead-decl
            (ast.ast-decl-cons
              (ast.ast-decl-test-id
                test-id
                (tltest.tltest-call-expr-id live-id)
                span)
              (ast.ast-decl-list-new)))))]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-root-path-cons
        "driver.tl"
        (ast.ast-decl-root-path-cons
          "driver.tl"
          (ast.ast-decl-root-path-cons
            "driver.tl"
            (ast.ast-decl-root-path-cons
              "driver.tl"
              (ast.ast-decl-path-list-new)))))]
    (match (tltest.tltest-build-harness "driver.tl" decls paths)
      [(tltest.InlineHarness.Harness program _ count)
        (match program
          [(ast.AstProgram.Program harness-decls-box)
            (let
              [harness-decls : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view harness-decls-box)]
              (and
                (= count 1)
                (tltest-decl-list-has-name? harness-decls live-name)
                (tltest-decl-list-has-name? harness-decls dep-name)
                (not (tltest-decl-list-has-name? harness-decls dead-name))))])]))
    unit
    (io.panic "test CLI inline harness generated reachability mismatch")))

(test
  test-cli-inline-harness-keeps-imported-generated-wrappers
  (if (let
    [dead-name : String "__tl_imported_generated_dead"]
    [ordinary-name : String "__tl_imported_ordinary_dead"]
    [dead-id : i64
      (ci.intern-generated-name
        (owned_view.compiler-owned-shared-view dead-name))]
    [ordinary-id : i64
      (ci.intern-generated-name
        (owned_view.compiler-owned-shared-view ordinary-name))]
    [test-id : i64 (ci.intern-generated-name "keeps-imported-generated")]
    [dead-decl : ast.AstDecl
      (tltest-generated-wrapper
        (owned_view.compiler-owned-shared-view dead-name)
        (ast.ast-decl-def-fn-id
          dead-id
          (ast.ast-param-list-new)
          (ast.AstType.Unit)
          (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit)))))]
    [ordinary-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        ordinary-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit))))]
    [span : ast.AstSourceSpan (ast.ast-source-span 29 1 29 1)]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons
        dead-decl
        (ast.ast-decl-cons
          ordinary-decl
          (ast.ast-decl-cons
            (ast.ast-decl-test-id
              test-id
              (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit)))
              span)
            (ast.ast-decl-list-new))))]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-root-path-cons
        "generated.tl"
        (ast.ast-decl-root-path-cons
          "generated.tl"
          (ast.ast-decl-root-path-cons "driver.tl" (ast.ast-decl-path-list-new))))]
    (match (tltest.tltest-build-harness "driver.tl" decls paths)
      [(tltest.InlineHarness.Harness program _ count)
        (match program
          [(ast.AstProgram.Program harness-decls-box)
            (let
              [harness-decls : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view harness-decls-box)]
              (and
                (= count 1)
                (tltest-decl-list-has-name? harness-decls dead-name)
                (not (tltest-decl-list-has-name? harness-decls ordinary-name))))])]))
    unit
    (io.panic "test CLI inline harness pruned imported generated wrapper")))

(test
  test-cli-inline-harness-keeps-macro-quasiquote-deps
  (if (let
    [helper-name : String "__tl_macro_generated_helper"]
    [macro-name : String "__tl_macro_generated_call"]
    [helper-id : i64
      (ci.intern-generated-name
        (owned_view.compiler-owned-shared-view helper-name))]
    [macro-id : i64
      (ci.intern-generated-name
        (owned_view.compiler-owned-shared-view macro-name))]
    [test-id : i64 (ci.intern-generated-name "uses-macro-generated-helper")]
    [helper-decl : ast.AstDecl
      (ast.ast-decl-def-fn-id
        helper-id
        (ast.ast-param-list-new)
        (ast.AstType.Unit)
        (ast.ast-node-push (ast.AstExpr.Literal (ast.AstLiteral.Unit))))]
    [macro-decl : ast.AstDecl
      (ast.ast-decl-def-macro-id
        macro-id
        (ast.ast-macro-param-list-new)
        (ast.AstType.Expr)
        (ast_tests.ast-expr-quasiquote (tltest.tltest-call-expr-id helper-id)))]
    [span : ast.AstSourceSpan (ast.ast-source-span 31 1 31 1)]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons
        helper-decl
        (ast.ast-decl-cons
          macro-decl
          (ast.ast-decl-cons
            (ast.ast-decl-test-id
              test-id
              (tltest.tltest-call-expr-id macro-id)
              span)
            (ast.ast-decl-list-new))))]
    [paths : ast.AstDeclPathList
      (ast.ast-decl-root-path-cons
        "macro-deps.tl"
        (ast.ast-decl-root-path-cons
          "macro-deps.tl"
          (ast.ast-decl-root-path-cons
            "macro-deps.tl"
            (ast.ast-decl-path-list-new))))]
    (match (tltest.tltest-build-harness "macro-deps.tl" decls paths)
      [(tltest.InlineHarness.Harness program _ count)
        (match program
          [(ast.AstProgram.Program harness-decls-box)
            (let
              [harness-decls : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view harness-decls-box)]
              (and
                (= count 1)
                (string.eq (tltest-decl-name-at harness-decls 0) helper-name)
                (string.eq (tltest-decl-name-at harness-decls 1) macro-name)
                (string.eq (tltest-decl-name-at harness-decls 2) "")
                (string.eq
                  (tltest-decl-name-at harness-decls 3)
                  "__tl_inline_test_0")
                (string.eq (tltest-decl-name-at harness-decls 4) "")
                (string.eq (tltest-decl-name-at harness-decls 5) "")
                (string.eq (tltest-decl-name-at harness-decls 6) "main")))])]))
    unit
    (io.panic "test CLI inline harness dropped macro quasiquote dependency")))

(define (tltest-nested-module-macro-vector-typecheck-ok?
  [program : ast.AstProgram]
  [harness-paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [target : backend.CompilerBackendTarget]) : bool
  (let
    [legacy-roots : cli_svec.Vec (clone roots)]
    (match (compiler_typecheck_api.typecheck-compiler-program-with-paths-cache
      (tltest.tltest-program-with-print-runtime program target)
      (tltest.tltest-paths-with-print-runtime target harness-paths)
      (owned_view.compiler-owned-shared-view legacy-roots)
      (tltest.tltest-cfgs target)
      (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
        "typecheck-prefix-test-cli"
        legacy-roots
        (tltest.tltest-cfgs target)))
      [(ResultCompilerTypecheck.Ok _) true]
      [(ResultCompilerTypecheck.Err diag)
        (begin
          (io.print-error
            (driver.compiler-driver-render-source-diagnostic
              (cdiag.compiler-diagnostic-list-first (deref diag))))
          false)])))

(define (tltest-function-base-defined?
  [funcs : ir.CompilerIrFunctionSeq]
  [base : String]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (< index funcs.len) (not found))
        (begin
          (match (array-ref funcs.slots index)
            [(ir.CompilerIrFunction.Function name _ _ _ _ _)
              (let
                [name-text : String (ir.compiler-ir-symbol-text name)]
                (if (string.contains (& name-text) (& base))
                  (set! found true)
                  unit))])
          (set! index (+ index 1))))
      found)))

(define (tltest-nested-module-macro-vector-lower-roots-ok?
  [source : String]
  [program : ast.AstProgram]
  [harness-paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [target : backend.CompilerBackendTarget]) : bool
  (let
    [legacy-roots : cli_svec.Vec (clone roots)]
    (match (lower.lower-compiler-program-with-decl-paths-mode-cache
      source
      (tltest.tltest-program-with-print-runtime program target)
      (tltest.tltest-paths-with-print-runtime target harness-paths)
      (lower.CompilerLowerMode.Scalar)
      (owned_view.compiler-owned-shared-view legacy-roots)
      (tltest.tltest-cfgs target)
      (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
        "typecheck-prefix-test-cli"
        legacy-roots
        (tltest.tltest-cfgs target)))
      [(lower.ResultCompilerLower.Ok lowered _)
        (match lowered
          [(ir.CompilerIrProgram.Program _ functions _)
            (tltest-function-base-defined? functions "clone$Pair")])]
      [(lower.ResultCompilerLower.Err _) false])))

(define (tltest-nested-module-macro-vector-loaded-ok?
  [source : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [target : backend.CompilerBackendTarget]) : bool
  (match (tltest.tltest-build-harness
    (owned_view.compiler-owned-shared-view source)
    decls
    paths)
    [(tltest.InlineHarness.Harness program harness-paths count)
      (begin
        (unless (= count 3) (return false))
        (unless
          (tltest-nested-module-macro-vector-typecheck-ok?
            (owned_view.compiler-owned-shared-view program)
            (owned_view.compiler-owned-shared-view harness-paths)
            (owned_view.compiler-owned-shared-view roots)
            target)
          (begin
            (io.print-error
              "nested module macro vector fixture failed typecheck")
            (return false)))
        (unless
          (tltest-nested-module-macro-vector-lower-roots-ok?
            source
            program
            harness-paths
            roots
            target)
          (begin
            (io.print-error
              "nested module macro vector fixture did not emit clone$Pair")
            (return false)))
        true)]))

(define (tltest-nested-module-macro-vector-self-test?) : bool
  (match (build_run_core.source-tool-create-temp-dir
    "tltest-nested-module-macro-vector")
    [(build_run_core.ResultSourceToolString.Err _) false]
    [(build_run_core.ResultSourceToolString.Ok dir)
      (let
        [source : String
          (build_run_core.source-tool-fs-path-join dir "nested_vector.tl")]
        [roots : cli_svec.Vec (tltest-roots-for-self-test)]
        [target : backend.CompilerBackendTarget
          (backend.CompilerBackendTarget.Linux)]
        (begin
          (tltest-write-text
            source
            "(import stdlib.vector)
(import (vector.vector String) as cli_svec)

(defstruct Pair
  (value i64))

(defmacro (slice-user [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append \"generated.native_slice_user.\" (type-key T)))]
    `(begin
      (module ,module-name)
      (import (vector.vector ,T) as vec)
      (define (score [first : ,T] [fallback : ,T]) : i64
        (let
          [items : vec.Vec (vec.new)]
        (begin
          (vec.push-ref! (&mut items) first)
          (let
            [has-one : bool
              (let
                [view : (& items (Slice ,T)) (vec.view (& items))]
                (= (array-length view) 1))]
            (if has-one
              (match (vec.pop-ref! (&mut items))
                [(vec.Pop.Ok _) 42]
                [(vec.Pop.Empty) 0])
              0))))))))

(import (slice-user i64) as user)
(import (slice-user Pair) as pair-user)

(test
  generated-module-body-uses-native-slice-i64
  (begin
    (user.score 7 0)
    unit))

(test
  generated-module-body-uses-native-slice-struct
  (begin
    (pair-user.score (Pair 7) (Pair 0))
    unit))

(cfg test
  (test
    generated-module-body-file-cfg-enabled
    unit))")
          (match (driver.compiler-driver-load-file-with-runtime
            (owned_view.compiler-owned-shared-view source)
            (owned_view.compiler-owned-shared-view roots)
            (tltest.tltest-cfgs target))
            [(compiler_load.ResultCompilerLoadWithPaths.Err _) false]
            [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
              (tltest-nested-module-macro-vector-loaded-ok?
                source
                decls
                paths
                roots
                target)])))]))

(test
  test-cli-inline-harness-nested-module-macro-vector-import
  (if (tltest-nested-module-macro-vector-self-test?)
    unit
    (io.panic "test CLI nested module macro vector import mismatch")))

(define (tltest-nested-generated-result-helper-loaded-ok?
  [source : String]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [roots : cli_svec.Vec]
  [target : backend.CompilerBackendTarget]) : bool
  (match (tltest.tltest-build-harness source decls paths)
    [(tltest.InlineHarness.Harness program harness-paths count)
      (begin
        (unless (= count 1) (return false))
        (tltest-nested-module-macro-vector-typecheck-ok?
          program
          harness-paths
          roots
          target))]))

(define (tltest-nested-generated-result-helper-self-test?) : bool
  (match (build_run_core.source-tool-create-temp-dir
    "tltest-nested-generated-result-helper")
    [(build_run_core.ResultSourceToolString.Err _) false]
    [(build_run_core.ResultSourceToolString.Ok dir)
      (let
        [source : String
          (build_run_core.source-tool-fs-path-join dir "nested_result.tl")]
        [roots : cli_svec.Vec (tltest-roots-for-self-test)]
        [target : backend.CompilerBackendTarget
          (backend.CompilerBackendTarget.Linux)]
        (begin
          (tltest-write-text
            source
            "(module test.nested_result_user)

(import stdlib.comptime)
(import stdlib.result)
(import stdlib.test)

(cfg
  test
  (defmacro (result-user [T : type] [E : type]) : Module
    (let
      [module-name : comptime.Expr
        (comptime.expr-var \"generated.result_user\")]
      `(begin
        (module ,module-name)
        (import stdlib.result)
        (import (result.result ,T ,E) as local_result)
        (define (value-or [value : local_result.Result] [fallback : ,T]) : ,T
          (local_result.value-or value fallback))))))

(cfg test (import (result.result i64 String) as result_i64_string))
(cfg test (import (result-user i64 String) as user))

(cfg
  test
  (test
    nested-generated-result-helper-value-or
    (test.assert-i64-eq
      (user.value-or (result_i64_string.ok 21) 0)
      21
      \"nested generated result helper should stay rooted\")))")
          (match (driver.compiler-driver-load-file-with-runtime
            (owned_view.compiler-owned-shared-view source)
            (owned_view.compiler-owned-shared-view roots)
            (tltest.tltest-cfgs target))
            [(compiler_load.ResultCompilerLoadWithPaths.Err _) false]
            [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
              (tltest-nested-generated-result-helper-loaded-ok?
                source
                decls
                paths
                roots
                target)])))]))

(test
  test-cli-inline-harness-nested-generated-result-helper
  (if (tltest-nested-generated-result-helper-self-test?)
    unit
    (io.panic "test CLI nested generated result helper import mismatch")))

(test
  test-cli-enables-test-cfg
  (cfg test unit (io.panic "test CLI did not enable test cfg")))

(define (tltest-roots-for-self-test) : cli_svec.Vec
  (let
    [roots : cli_svec.Vec (cli_svec.new)]
    (begin
      (cli_svec.push-ref! (&mut roots) "stdlib")
      (cli_svec.push-ref! (&mut roots) "src")
      roots)))

(test
  test-cli-package-loader-enables-test-cfg
  (unless
    (match (build_run_core.source-tool-create-temp-dir "tltest-package-cfg")
      [(build_run_core.ResultSourceToolString.Err _) false]
      [(build_run_core.ResultSourceToolString.Ok dir)
        (let
          [source : String
            (build_run_core.source-tool-fs-path-join dir "cfg_inline.tl")]
          [roots : cli_svec.Vec (tltest-roots-for-self-test)]
          (begin
            (tltest-write-text
              source
              "(cfg test (test package-cfg-inline unit))\n")
            (let
              [legacy-roots : cli_svec.Vec (clone roots)]
              (match (driver.compiler-driver-load-package-file-with-runtime-owned-cfg
                (owned_view.compiler-owned-shared-view source)
                (owned_view.compiler-owned-shared-view legacy-roots)
                "."
                "tltest"
                (compiler_load.compiler-pkg-deps-empty)
                true
                (tltest.tltest-cfgs (backend.CompilerBackendTarget.Linux)))
                [(compiler_load.ResultCompilerLoadWithPaths.Err _) false]
                [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
                  (let
                    [owned-source : String
                      (compiler_load.compiler-load-package-owned-path
                        "tltest"
                        "."
                        legacy-roots
                        source)]
                    (match (tltest.tltest-build-harness
                      owned-source
                      decls
                      paths)
                      [(tltest.InlineHarness.Harness _ _ count) (= count 1)]))]))))])
    (io.panic "test CLI package loader did not enable test cfg")))

(test
  test-cli-stdlib-io-import-lowers-bytes-surface
  (unless
    (match (build_run_core.source-tool-create-temp-dir "tltest-stdlib-io-lower")
      [(build_run_core.ResultSourceToolString.Err _) false]
      [(build_run_core.ResultSourceToolString.Ok dir)
        (let
          [source : String
            (build_run_core.source-tool-fs-path-join dir "io_run.tl")]
          [roots : cli_svec.Vec (tltest-roots-for-self-test)]
          [target : backend.CompilerBackendTarget
            (backend.CompilerBackendTarget.Linux)]
          (begin
            (tltest.tltest-inline-reset-load-state!)
            (tltest-write-text
              source
              "(import stdlib.io)
(import stdlib.byte_buf)

(define (main) : i64
  (begin
    (let
      [text : String \"ok\"]
      (io.stdout-write (byte_buf.str-as-bytes (& text))))
    0))
")
            (match (driver.compiler-driver-load-file-with-runtime
              (owned_view.compiler-owned-shared-view source)
              (owned_view.compiler-owned-shared-view roots)
              (tltest.tltest-cfgs target))
              [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
                (begin
                  (io.print-error
                    (driver.compiler-driver-render-source-diagnostic
                      (cdiag.compiler-diagnostic-box-shared-view diag)))
                  false)]
              [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
                (match (lower.lower-compiler-program-with-decl-paths-mode-cache
                  (owned_view.compiler-owned-shared-view source)
                  (ast.ast-program decls)
                  paths
                  (lower.CompilerLowerMode.Scalar)
                  (owned_view.compiler-owned-shared-view roots)
                  (tltest.tltest-cfgs target)
                  (tltest-typecheck-cache-scope roots target))
                  [(lower.ResultCompilerLower.Ok _ _) true]
                  [(lower.ResultCompilerLower.Err diag)
                    (begin
                      (io.print-error
                        (driver.compiler-driver-render-source-diagnostic
                          (tltest.tltest-diagnostic-with-source-fallback
                            source
                            (cdiag.compiler-diagnostic-box-shared-view diag))))
                      false)])])))])
    (io.panic "stdlib/io imported stdout-write failed to lower string helper")))

(define (tltest-typecheck-cache-scope
  [roots : cli_svec.Vec]
  [backend-target : backend.CompilerBackendTarget]) : String
  (let
    [legacy-roots : cli_svec.Vec (clone roots)]
    (compiler_typecheck_api.compiler-typecheck-prefix-cache-scope
      "typecheck-prefix-test-cli"
      legacy-roots
      (tltest.tltest-cfgs backend-target))))

(define (tltest-run-executable-error-message-self-test?) : bool
  (let
    [bin-path : String "target/typelisp-missing-test-executable-2619.exe"]
    [temp-dir : String "target/typelisp-test-2619"]
    [message : String
      (tltest.tltest-run-executable-error-message
        bin-path
        temp-dir
        (process.ProcessSpawnFailed "process: spawn failed"))]
    [missing-detail : String "test executable is missing after link"]
    [preserve-detail : String
      "preserving test artifacts in 'target/typelisp-test-2619'"]
    (and
      (string.contains (& message) (& missing-detail))
      (string.contains (& message) (& preserve-detail)))))

(test
  test-cli-spawn-error-preserves-artifacts
  (unless
    (tltest-run-executable-error-message-self-test?)
    (io.panic "test CLI spawn error diagnostic did not preserve artifacts")))

(define (tltest-stdlib-env-fixture-self-test?) : bool
  (and
    (tltest.tltest-stdlib-env-fixture-source? "stdlib/env.tl")
    (tltest.tltest-stdlib-env-fixture-source? "stdlib\\env.tl")
    (tltest.tltest-stdlib-env-fixture-source? "stdlib/tests/env_api.tl")
    (tltest.tltest-stdlib-env-fixture-source? "stdlib\\tests\\env_api.tl")
    (not (tltest.tltest-stdlib-env-fixture-source? "stdlib/process.tl"))
    (string.eq
      (tltest.tltest-stdlib-env-fixture-path
        (backend.CompilerBackendTarget.Windows))
      "one;two;three")
    (string.eq
      (tltest.tltest-stdlib-env-fixture-path
        (backend.CompilerBackendTarget.Linux))
      "one:two:three")))

(test
  test-cli-stdlib-env-fixture-is-target-aware
  (unless
    (tltest-stdlib-env-fixture-self-test?)
    (io.panic "test CLI stdlib/env fixture routing mismatch")))

(define (tltest-package-integration-filter-self-test?) : bool
  (let
    [tests-prefix : String (tltest.tltest-package-tests-prefix "repo")]
    [integration-source : String
      (compiler_load.compiler-load-normalize-path
        "repo/tests/integration/hello.tl")]
    (and
      (tltest.tltest-package-manifest-managed-integration-source-with?
        integration-source
        (owned_view.compiler-owned-shared-view tests-prefix)
        true)
      (not
        (tltest.tltest-package-manifest-managed-integration-source-with?
          integration-source
          (owned_view.compiler-owned-shared-view tests-prefix)
          false))
      (not
        (tltest.tltest-package-integration-source?
          "repo/tests/diagnostics/backend/quote_runtime_value.tl"
          (owned_view.compiler-owned-shared-view tests-prefix)))
      (not
        (tltest.tltest-package-integration-source?
          "repo/tests/format_golden/char_literal.tl"
          (owned_view.compiler-owned-shared-view tests-prefix)))
      (not
        (tltest.tltest-package-integration-source?
          "repo/tests/golden/tl_emit_program.tl"
          (owned_view.compiler-owned-shared-view tests-prefix)))
      (not
        (tltest.tltest-package-integration-source?
          "repo/tests/inline/auto_discovery.tl"
          (owned_view.compiler-owned-shared-view tests-prefix)))
      (not
        (tltest.tltest-package-integration-source?
          "repo/tests/no-libc/probe.tl"
          (owned_view.compiler-owned-shared-view tests-prefix)))
      (not
        (tltest.tltest-package-integration-source?
          "repo/tests/public-tools/fixture.tl"
          (owned_view.compiler-owned-shared-view tests-prefix)))
      (not
        (tltest.tltest-package-integration-source?
          "repo/tests/safety/array_bounds_trap.tl"
          (owned_view.compiler-owned-shared-view tests-prefix)))
      (not
        (tltest.tltest-package-integration-source?
          "repo/tests/spmd/masked_if_i64.tl"
          (owned_view.compiler-owned-shared-view tests-prefix)))
      (not
        (tltest.tltest-package-integration-source?
          "repo/tests/tlci/corpus_emit.tl"
          (owned_view.compiler-owned-shared-view tests-prefix)))
      (tltest.tltest-package-integration-source?
        "repo/tests/integration/hello.tl"
        (owned_view.compiler-owned-shared-view tests-prefix))
      (tltest.tltest-package-integration-source?
        "repo/tests/basic.tl"
        (owned_view.compiler-owned-shared-view tests-prefix))
      (tltest.tltest-package-integration-source?
        "repo/tests/nested/more.tl"
        (owned_view.compiler-owned-shared-view tests-prefix))
      (tltest.tltest-package-integration-source?
        "repo/tests/diagnostics_extra/example.tl"
        (owned_view.compiler-owned-shared-view tests-prefix))
      (tltest.tltest-package-integration-source?
        "repo/tests/tlci_extra/example.tl"
        tests-prefix))))

(test
  test-cli-package-integration-skips-diagnostics-fixtures
  (if (tltest-package-integration-filter-self-test?)
    unit
    (io.panic "test CLI package integration filter mismatch")))

(define (tltest-maybe-string-some? [value : tltest.TestMaybeString]) : bool
  (match value
    [(tltest.TestMaybeString.Some _) true]
    [(tltest.TestMaybeString.No) false]))

(test
  test-cli-backend-mode-host-isa-policy
  (begin
    (unless
      (and
        (not
          (tltest-maybe-string-some?
            (tltest.tltest-host-isa-refusal
              (backend.CompilerBackendMode.Scalar)
              false
              false)))
        (tltest-maybe-string-some?
          (tltest.tltest-host-isa-refusal
            (backend.CompilerBackendMode.Avx2)
            false
            true))
        (not
          (tltest-maybe-string-some?
            (tltest.tltest-host-isa-refusal
              (backend.CompilerBackendMode.Avx2)
              true
              false)))
        (tltest-maybe-string-some?
          (tltest.tltest-host-isa-refusal
            (backend.CompilerBackendMode.Avx512)
            true
            false))
        (not
          (tltest-maybe-string-some?
            (tltest.tltest-host-isa-refusal
              (backend.CompilerBackendMode.Avx512)
              true
              true))))
      (io.panic "test CLI host-ISA refusal policy mismatch"))
    (unless
      (and
        (tltest.tltest-backend-mode-executes?
          (backend.CompilerBackendMode.Avx512)
          tltest.TestMode.Run
          false)
        (not
          (tltest.tltest-backend-mode-executes?
            (backend.CompilerBackendMode.Avx512)
            tltest.TestMode.Check
            false))
        (not
          (tltest.tltest-backend-mode-executes?
            (backend.CompilerBackendMode.Avx512)
            tltest.TestMode.Run
            true))
        (not
          (tltest.tltest-backend-mode-executes?
            (backend.CompilerBackendMode.Scalar)
            tltest.TestMode.Run
            false)))
      (io.panic "test CLI backend-mode execution policy mismatch"))))

(define (tltest-lower-mode-tag [mode : lower.CompilerLowerMode]) : i64
  (match mode
    [(lower.CompilerLowerMode.Scalar) 0]
    [(lower.CompilerLowerMode.LinuxAvx2) 1]
    [(lower.CompilerLowerMode.WindowsAvx2) 2]
    [(lower.CompilerLowerMode.LinuxAvx512) 3]
    [(lower.CompilerLowerMode.WindowsAvx512) 4]
    [(lower.CompilerLowerMode.LinuxScalar) 5]
    [(lower.CompilerLowerMode.WindowsScalar) 6]
    [_ -1]))

(test
  test-cli-backend-mode-selects-paired-lower-mode
  (unless
    (and
      (=
        (tltest-lower-mode-tag
          (tltest.tltest-harness-lower-mode
            (backend.CompilerBackendTarget.Linux)
            (backend.CompilerBackendMode.Scalar)))
        5)
      (=
        (tltest-lower-mode-tag
          (tltest.tltest-harness-lower-mode
            (backend.CompilerBackendTarget.Windows)
            (backend.CompilerBackendMode.Scalar)))
        6)
      (=
        (tltest-lower-mode-tag
          (tltest.tltest-harness-lower-mode
            (backend.CompilerBackendTarget.Linux)
            (backend.CompilerBackendMode.Avx2)))
        1)
      (=
        (tltest-lower-mode-tag
          (tltest.tltest-harness-lower-mode
            (backend.CompilerBackendTarget.Windows)
            (backend.CompilerBackendMode.Avx2)))
        2)
      (=
        (tltest-lower-mode-tag
          (tltest.tltest-harness-lower-mode
            (backend.CompilerBackendTarget.Linux)
            (backend.CompilerBackendMode.Avx512)))
        3)
      (=
        (tltest-lower-mode-tag
          (tltest.tltest-harness-lower-mode
            (backend.CompilerBackendTarget.Windows)
            (backend.CompilerBackendMode.Avx512)))
        4))
    (io.panic "test CLI backend mode did not select its paired lower mode")))