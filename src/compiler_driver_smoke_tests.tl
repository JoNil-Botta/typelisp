;; compiler_driver_smoke_tests.tl - Shared driver/lowering integration smokes.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf)
(import stdlib.string)
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_driver_core as driver)
(import compiler_ast_types as ast)
(import compiler_lower as lower)
(import compiler_lower_tests)
(import compiler_symbols)
(import compiler_optimize)
(import compiler_cfg_core)
(import compiler_diagnostic as cdiag)
(import compiler_diagnostic_tests as cdiag_tests)
(import compiler_typecheck_core as tc)
(import compiler_parse_core)
(import compiler_backend)
(import compiler_ir_types)
(import compiler_load)
(import sym_i64_env)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_profile_state as profile_state)
(import compiler_owned_view as owned_view)
(import stdlib.arena)
(cfg compile-profile (import stdlib.profile))
(cfg test (import stdlib.test))
(import compiler_cfg_core as cfg_core)
(cfg embedded-stdlib-tlci (import compiler_build_identity as build_identity))
(cfg embedded-stdlib-tlci (import compiler_surface_ast as surface_ast))
(cfg embedded-stdlib-tlci (import compiler_surface_hydrate))
(cfg embedded-stdlib-tlci (import tlci_core as tlci))

(extern (compiler-driver-smoke-runtime-alloc [bytes : i64]) : i64 (:symbol "tl_alloc"))

(define (compiler-driver-restore-arena-owner-current-ok?) : bool
  (let
    [home : i64 (arena.tl_arena_current)]
    [owner : i64 (arena.tl_arena_make)]
    (unsafe
      (arena.tl_arena_set owner))
    ;; Fill the 64 MiB root without touching its payload pages, then force
    ;; one overflow segment. Public current remains the stable `owner` root.
    (compiler-driver-smoke-runtime-alloc 67108800)
    (compiler-driver-smoke-runtime-alloc 8)
    (let
      [stable? : bool (= (arena.tl_arena_current) owner)]
      (driver.compiler-driver-restore-arena-owner-current! owner)
      (let
        [preserved? : bool (= (arena.tl_arena_current) owner)]
        (unsafe
          (arena.tl_arena_set home))
        (driver.compiler-driver-restore-arena-owner-current! owner)
        (let
          [resumed? : bool (= (arena.tl_arena_current) owner)]
          (unsafe
            (arena.tl_arena_set home)
            (arena.tl_arena_destroy owner))
          (and stable? preserved? resumed?))))))

(define (compiler-driver-lower-name-store-owner-current-ok?) : bool
  (let
    [home : i64 (arena.tl_arena_current)]
    [owner : i64 (arena.tl_arena_make)]
    (unsafe
      (arena.tl_arena_set owner))
    ;; Advance this owner beyond its root before constructing the store. Arena
    ;; handles are stable roots (#6285): growth keeps the public handle valid,
    ;; and add-segment! allocates through in-arena on that root.
    (compiler-driver-smoke-runtime-alloc 67108800)
    (compiler-driver-smoke-runtime-alloc 8)
    (let
      [store : (Box lower.LowerNameStore) (box (lower.lower-name-store-new))]
      [store-owner : i64 (__tl-project-field (__tl-box-place store) arena)]
      (unsafe
        (arena.tl_arena_set home))
      (lower.lower-name-store-add-segment! (&mut (__tl-box-place store)))
      (let
        [home-restored? : bool (= (arena.tl_arena_current) home)]
        [segment-count : i64
          (__tl-project-field (__tl-box-place store) segment-count)]
        (unsafe
          (arena.tl_arena_set home)
          (arena.tl_arena_destroy owner))
        (and (= store-owner owner) home-restored? (= segment-count 2))))))

(define (lower-symbol-smoke-extern-metadata
  [link-id : i64]
  [matches-source : bool]) : ast.AstExternMetadata
  (Metadata
    (C)
    (ci.intern-id-from-renderable link-id)
    (ast.ast-extern-link-input-list-new)
    (ast.ast-extern-metadata-flags false matches-source)
    No))

(define (lower-symbol-smoke-parsed-extern-match?
  [source : String]
  [want : bool]) : bool
  (match (compiler_parse_core.parse-ast-source source)
    [(Ok program)
      (match program
        [(Program decls-box)
          (let
            [decls : ast.AstDeclList (deref decls-box)]
            (match (ast.ast-decl-list-get (& decls) 0 (ast.ast-decl-fallback))
              [(Extern _ _ _ metadata _)
                (=
                  (ast.ast-extern-metadata-symbol-matches-source?
                    (& (deref metadata)))
                  want)]
              [_ false]))])]
    [(Err _) false]))

(define (lower-symbol-smoke-ok?) : bool
  (let
    [home : ci.InternCompatState (ci.intern-compat-state-new)]
    [state-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [state-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [ok : bool true]
    (set!
      ok
      (and
        ok
        (lower-symbol-smoke-parsed-extern-match?
          "(extern same-name (:symbol \"same-name\") : i64)"
          true)
        (lower-symbol-smoke-parsed-extern-match?
          "(extern source-name (:symbol \"link-name\") : i64)"
          false)))
    (ci.intern-compat-state-capture-from-globals! (&mut home))
    (ci.intern-compat-state-install! state-a)
    (cbi.compiler-builtin-reset!)
    (cbi.compiler-builtin-initialize-for-parse!)
    (let
      [lower-state : lower.CompilerLowerState (lower.compiler-lower-state-new)]
      [source-id : i64 (ci.intern "same-name")]
      [module-id : i64 (ci.intern "identity-module")]
      [link-id : i64 (ci.intern-generated-name "same-name")]
      [opaque-logical-id : i64 (ci.intern-generated-name "same-name")]
      [module-logical-id : i64
        (compiler_symbols.compiler-symbol-module-key-id-by-id
          module-id
          source-id)]
      [module-name : String
        (compiler_symbols.compiler-symbol-module-key
          "identity-module"
          "same-name")]
      [root-env : lower.LowerNameEnv
        (lower.lower-name-env-add-module-binding-id
          Nil
          ""
          (compiler_symbols.compiler-symbol-root-module-id)
          "same-name"
          source-id
          "same-name"
          source-id
          true)]
      [root-cache : lower.LowerNameCache
        (lower.lower-name-cache-from-env lower-state root-env)]
      [entry-main-source-id : i64 (ci.intern-generated-name "main")]
      [entry-main-env : lower.LowerNameEnv
        (lower.lower-name-env-add-decl-module-binding-id
          lower-state
          Nil
          "entry.tl"
          "entry.tl"
          ""
          (compiler_symbols.compiler-symbol-root-module-id)
          "main"
          entry-main-source-id)]
      [entry-main-cache : lower.LowerNameCache
        (lower.lower-name-cache-from-env lower-state entry-main-env)]
      [stale-main-symbol-id : i64
        (ci.intern-generated-name "package-entry-main")]
      [stale-main-cache : lower.LowerNameCache
        (lower.lower-name-cache-from-env
          lower-state
          (lower.lower-name-env-bind-logical-symbol-id
            entry-main-source-id
            cbi.compiler-builtin-id-fix-main
            stale-main-symbol-id
            Nil))]
      [derived-env : lower.LowerNameEnv
        (compiler_lower_tests.lower-name-env-bind-logical-id
          source-id
          "same-name"
          opaque-logical-id
          Nil)]
      ;; A composite module key can numerically equal the source key passed
      ;; through a later boundary, but it is not an interned symbol id.
      (set!
        ok
        (and
          ok
          (not
            (lower.lower-logical-symbol-id-direct?
              module-logical-id
              module-logical-id))
          (=
            (lower.lower-extern-logical-symbol-id
              lower-state
              source-id
              "same-name"
              source-id
              (lower-symbol-smoke-extern-metadata source-id true))
            source-id)
          (=
            (lower.lower-extern-logical-symbol-id
              lower-state
              source-id
              "same-name"
              source-id
              (lower-symbol-smoke-extern-metadata link-id true))
            link-id)
          (=
            (lower.lower-extern-logical-symbol-id
              lower-state
              source-id
              "same-name"
              source-id
              (lower-symbol-smoke-extern-metadata link-id false))
            source-id)))
      (let
        [module-symbol : i64
          (lower.lower-extern-logical-symbol-id
            lower-state
            module-logical-id
            (owned_view.compiler-owned-shared-view module-name)
            source-id
            (lower-symbol-smoke-extern-metadata link-id true))]
        (unless (not (= module-symbol link-id)) (set! ok false))
        (unless
          (string.eq
            (compiler_ir_types.compiler-ir-symbol-text module-symbol)
            module-name)
          (set! ok false)))
      (set!
        ok
        (and
          ok
          (=
            (lower.lower-name-cache-lookup-symbol-id
              (& root-cache)
              source-id
              -1)
            source-id)
          ;; Entry-main's fixed logical ID can differ from the current parsed
          ;; source symbol after state reuse. Preserve the typed entry-main
          ;; decision while selecting the active source symbol for emission.
          (not (= entry-main-source-id cbi.compiler-builtin-id-fix-main))
          (=
            (lower.lower-name-cache-lookup-symbol-id
              (& entry-main-cache)
              cbi.compiler-builtin-id-fix-main
              -1)
            entry-main-source-id)
          (=
            (lower.lower-decl-function-symbol-id
              stale-main-cache
              cbi.compiler-builtin-id-fix-main
              entry-main-source-id
              "main")
            entry-main-source-id)))
      (match (lower.lower-name-env-view derived-env)
        [(Bind _ logical-id symbol-id _)
          (set!
            ok
            (and
              ok
              (= logical-id opaque-logical-id)
              (not (= symbol-id opaque-logical-id))
              (string.eq
                (compiler_ir_types.compiler-ir-symbol-text symbol-id)
                "same-name")))]
        [_ (set! ok false)]))
    (ci.intern-compat-state-install! state-b)
    (cbi.compiler-builtin-reset!)
    (cbi.compiler-builtin-initialize-for-parse!)
    (let
      [source-id : i64 (ci.intern "other-name")]
      [link-id : i64 (ci.intern-generated-name "other-name")]
      [lower-state-b : lower.CompilerLowerState
        (lower.compiler-lower-state-new-with-intern-state
          (ci.intern-compat-state-capture-active))]
      (unless
        (=
          (lower.lower-extern-logical-symbol-id
            lower-state-b
            source-id
            "other-name"
            source-id
            (lower-symbol-smoke-extern-metadata link-id true))
          link-id)
        (set! ok false)))
    (ci.intern-compat-state-install! home)
    (cbi.compiler-builtin-reset!)
    (cbi.compiler-builtin-initialize-for-parse!)
    ok))

;; Derived logical symbols are minted into the IR's own growable table, not the
;; intern pool's generated lane, whose fixed ceiling a whole-program compile's
;; derived names would otherwise exhaust. A compile's generated lane must stay a
;; small fraction of the pool. Pin both halves of that here: a real
;; front-to-back emit stays inside the budget, and the derived mint itself costs
;; the lane nothing. Moving the mint back into the pool fails as a named smoke
;; instead of as a later bootstrap stage's bare abort.
(define (lower-symbol-generated-lane-budget-ok?) : bool
  (let
    [emitted : bool
      (match (compiler_backend.compiler-backend-emit-source
        "(define (shared [x : i64]) : i64 (+ x 1))
(define (first [x : i64]) : i64 (shared x))
(define (second [x : i64]) : i64 (shared (first x)))
(define (main) : i64 (+ (first 1) (second 2)))")
        [(Ok _) true]
        [(Err _) false])]
    [lane-after-compile : i64 (ci.intern-generated-count)]
    [derived-after-compile : i64
      (compiler_ir_types.compiler-ir-symbol-count-value)]
    [minted : i64 (lower.lower-derived-symbol-id "lower-symbol-budget/probe")]
    [lane-after-mint : i64 (ci.intern-generated-count)]
    [derived-after-mint : i64
      (compiler_ir_types.compiler-ir-symbol-count-value)]
    (and
      emitted
      (< lane-after-compile (/ (ci.intern-capacity) 64))
      (compiler_ir_types.compiler-ir-symbol-owned? minted)
      (= lane-after-mint lane-after-compile)
      (= derived-after-mint (+ derived-after-compile 1)))))

(define (compiler-lower-symbol-identity-smoke-main) : i64
  (cbi.compiler-builtin-initialize-for-parse!)
  (unless
    (lower-symbol-smoke-ok?)
    (io.panic "lower: typed symbol identity smoke mismatch"))
  (unless
    (lower-symbol-generated-lane-budget-ok?)
    (io.panic "lower: derived symbol generated-lane budget exceeded"))
  42)

(define (compiler-driver-pic-smoke-roots) : svec.Vec
  (let
    [roots : svec.Vec (svec.new)]
    (svec.push-ref! (&mut roots) "stdlib")
    (svec.push-ref! (&mut roots) "../stdlib")
    roots))

(define (compiler-driver-pic-smoke-contains?
  [text : (& text str)]
  [needle : String]) : bool
  (string.contains text (& needle)))

(define (compiler-driver-pic-smoke-paths-contain?
  [paths : ast.AstDeclPathList]
  [needle : String]) : bool
  (match (ast.ast-decl-path-list-step paths)
    [(Nil) false]
    [(Cons path rest)
      (or
        (compiler-driver-pic-smoke-contains?
          (& path)
          (owned_view.compiler-owned-shared-view needle))
        (compiler-driver-pic-smoke-paths-contain? rest needle))]))

;; A cache miss builds its persistent key and runtime-prelude result in the
;; process-lifetime node-pool arena. Verify that this nested target restores the
;; caller's arena and that the cached paths remain readable after that caller is
;; destroyed.
(define (compiler-driver-runtime-prelude-cache-in-caller-ok?
  [caller : arena.Arena]
  [caller-handle : i64]
  [key : compiler_load.CompilerLoadPreludeCacheKey]
  [roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (in-arena
    caller
    (match (compiler-driver-load-runtime-prelude-cache-miss key roots cfgs)
      [(Ok _ paths _ _)
        (and
          (= (arena.tl_arena_current) caller-handle)
          (compiler-driver-pic-smoke-paths-contain? paths "stdlib/runtime.tl"))]
      [(Err _) false])))

(define (compiler-driver-runtime-prelude-cache-arena-scope-ok?) : bool
  (let
    [roots : svec.Vec (compiler-driver-pic-smoke-roots)]
    [cfgs : sym_i64_env.SymI64Env (compiler_cfg_core.compiler-cfg-empty)]
    [key : compiler_load.CompilerLoadPreludeCacheKey
      (compiler_load.compiler-load-runtime-prelude-cache-key
        (owned_view.compiler-owned-shared-view roots)
        cfgs)]
    [home-handle : i64 (arena.tl_arena_current)]
    [caller : arena.Arena (arena.make)]
    [caller-handle : i64 (arena.raw-handle caller)]
    [scoped-ok? : bool
      (compiler-driver-runtime-prelude-cache-in-caller-ok?
        caller
        caller-handle
        (owned_view.compiler-owned-shared-view key)
        roots
        cfgs)]
    [home-restored? : bool (= (arena.tl_arena_current) home-handle)]
    (arena.destroy-safe! caller)
    (match (driver.compiler-driver-runtime-prelude-cache-lookup key)
      [(CompilerLoadPreludeCacheHit _ paths _ _)
        (and
          scoped-ok?
          home-restored?
          (compiler-driver-pic-smoke-paths-contain? paths "stdlib/runtime.tl"))]
      [(CompilerLoadPreludeCacheMiss) false])))

(define (compiler-driver-pic-smoke-output-ok?
  [output : compiler_backend.CompilerBackendPicOutput]) : bool
  (let
    [asm : String output.asm]
    [fixups : String output.fixups]
    (and
      (> (string.string-length asm) 0)
      (compiler-driver-pic-smoke-contains? (& asm) ".L_tl_pic_image_base:\n")
      (not (compiler-driver-pic-smoke-contains? (& asm) "_tl_start"))
      (not (compiler-driver-pic-smoke-contains? (& asm) "main:"))
      (not (compiler-driver-pic-smoke-contains? (& asm) ".extern"))
      (not (compiler-driver-pic-smoke-contains? (& asm) "tl_alloc"))
      (compiler-driver-pic-smoke-contains?
        (& fixups)
        "typelisp-pic-fixups v1\n"))))

(define (compiler-driver-pic-smoke-core-macros-path-ok?
  [target : compiler_backend.CompilerBackendTarget]
  [input-path : String]) : bool
  (match (compiler-driver-emit-file-pic-with-target-roots-level-mode-and-cfg
    input-path
    target
    true
    (compiler-driver-pic-smoke-roots)
    (compiler_optimize.compiler-optimize-default-level)
    (Scalar)
    (compiler_cfg_core.compiler-cfg-empty))
    [(Ok output _) (compiler-driver-pic-smoke-output-ok? output)]
    [(Err _ _) false]))

(define (compiler-driver-pic-smoke-core-macros-ok?
  [target : compiler_backend.CompilerBackendTarget]) : bool
  (or
    (compiler-driver-pic-smoke-core-macros-path-ok?
      target
      "stdlib/core_macros.tl")
    (compiler-driver-pic-smoke-core-macros-path-ok?
      target
      "../stdlib/core_macros.tl")))

(define (compiler-driver-pic-smoke-write-fixture-at?
  [path : (& path str)]
  [contents : (& contents str)]) : bool
  (match (io.try-write-file path (byte_buf.str-as-bytes contents))
    [(OkIoUnit) true]
    [(ErrIoUnit _) false]))

(define (compiler-driver-pic-smoke-write-extern-fixture) : String
  (let
    [path : String "target/compiler_driver_pic_extern_fixture.tl"]
    [fallback-path : String "compiler_driver_pic_extern_fixture.tl"]
    [contents : String
      "(extern (foreign-call [arg0 : i64]) : i64 (:abi c) (:symbol \"foreign_exact\"))
(define (main) : i64
  (foreign-call 1))"]
    (if (compiler-driver-pic-smoke-write-fixture-at? (& path) (& contents))
      path
      (begin
        (io.write-file fallback-path (byte_buf.str-as-bytes (& contents)))
        fallback-path))))

(define (compiler-driver-smoke-write-module-macro-diagnostic-fixture) : String
  (let
    [path : String "target/compiler_driver_module_macro_diagnostic_fixture.tl"]
    [fallback-path : String
      "compiler_driver_module_macro_diagnostic_fixture.tl"]
    [contents : String
      "(defmacro (gennum [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var (comptime.string-append \"generated.gennum.\" (type-key T)))]
    `(begin
      (module ,module-name)
      (define (big) : ,T 300))))

(import (gennum u8) as n8)

(define (main) : i64 (cast (n8.big) : i64))"]
    (if (compiler-driver-pic-smoke-write-fixture-at? (& path) (& contents))
      path
      (begin
        (io.write-file fallback-path (byte_buf.str-as-bytes (& contents)))
        fallback-path))))

(define (compiler-driver-smoke-module-macro-diagnostic-ok?) : bool
  (match (driver.compiler-driver-emit-file-with-target-roots-level-mode-cfg-and-crt
    (compiler-driver-smoke-write-module-macro-diagnostic-fixture)
    (Linux)
    true
    (compiler-driver-pic-smoke-roots)
    (compiler_optimize.compiler-optimize-default-level)
    (Scalar)
    (compiler_cfg_core.compiler-cfg-empty)
    true)
    [(Ok _ _) false]
    [(Err diag _)
      (let
        [rendered : String (cdiag.compiler-diagnostic-render (deref diag))]
        (and
          (compiler-driver-pic-smoke-contains?
            (& rendered)
            "integer literal 300 does not fit expected type u8")
          (compiler-driver-pic-smoke-contains?
            (& rendered)
            "in expansion of macro `gennum` invoked here")
          (compiler-driver-pic-smoke-contains?
            (& rendered)
            "compiler_driver_module_macro_diagnostic_fixture.tl:9:1")))]))

(define (compiler-driver-reader-context-smoke-write-fixture) : String
  (let
    [path : String "target/compiler_driver_reader_context_fixture.tl"]
    [fallback-path : String "compiler_driver_reader_context_fixture.tl"]
    [contents : String
      "(define (square [value : i64]) : i64
  (* value value))
(define (main) : i64
  (+ (square 6) 6))"]
    (if (compiler-driver-pic-smoke-write-fixture-at? (& path) (& contents))
      path
      (begin
        (io.write-file fallback-path (byte_buf.str-as-bytes (& contents)))
        fallback-path))))

(define (compiler-driver-reader-context-smoke-installed?
  [expr-segment-bases : i64]
  [type-segment-bases : i64]
  [base-arena : i64]) : bool
  (let
    [installed : ast.AstNodePoolContext
      (ast.ast-node-pool-reader-context-current)]
    (and
      (=
        (ast.ast-node-pool-context-expr-segment-bases installed)
        expr-segment-bases)
      (=
        (ast.ast-node-pool-context-type-segment-bases installed)
        type-segment-bases)
      (= (ast.ast-node-pool-context-base-arena installed) base-arena))))

(define (compiler-driver-reader-context-smoke-fail [message : String]) : bool
  (io.print-format
    "{}"
    (str_cat.str-cat "driver reader-context smoke: " message))
  (io.print-format "{}" "\n")
  false)

(define (compiler-driver-reader-context-smoke-mirror-intern-state-ok?
  [intern-a : ci.InternCompatState]
  [intern-b : ci.InternCompatState]) : bool
  (let
    [source-count-a : i64 (ci.intern-compat-state-pool-len intern-a)]
    [generated-count-a : i64 (ci.intern-compat-state-generated-count intern-a)]
    [source-count-b : i64 (ci.intern-compat-state-pool-len intern-b)]
    [generated-count-b : i64 (ci.intern-compat-state-generated-count intern-b)]
    [ok : bool (and (= source-count-b 0) (= generated-count-b 0))]
    [source-index : i64 0]
    [generated-index : i64 0]
    ;; The cloned IR retains A's numeric symbol identities. Rebuild those
    ;; spellings in B's still-fresh capability without installing either
    ;; table, so B remains an independently owned backend job.
    (while (and ok (< source-index source-count-a))
      (let
        [source-id : i64 source-index]
        [mirrored-id : i64
          (ci.intern-compat-state-intern
            (&mut intern-b)
            (& (ci.intern-compat-state-str intern-a source-id)))]
        (if (= mirrored-id source-id)
          unit
          (set! ok false))
        (+= source-index 1)))
    (while (and ok (< generated-index generated-count-a))
      (let
        [source-id : i64 (- (- (ci.intern-capacity) 1) generated-index)]
        [mirrored-id : i64
          (ci.intern-compat-state-generated-name
            (&mut intern-b)
            (& (ci.intern-compat-state-str intern-a source-id)))]
        (if (= mirrored-id source-id)
          unit
          (set! ok false))
        (+= generated-index 1)))
    (and
      ok
      (= source-count-a (ci.intern-compat-state-pool-len intern-b))
      (= generated-count-a (ci.intern-compat-state-generated-count intern-b))
      (not
        (=
          (ci.intern-compat-state-table-id intern-a)
          (ci.intern-compat-state-table-id intern-b))))))

(define (compiler-driver-reader-context-smoke-emit
  [backend-state : compiler_backend.CompilerBackendState]
  [pools : ast.AstNodePoolContext]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]) : compiler_backend.ResultCompilerBackend
  (compiler_backend.compiler-backend-emit-program-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
    backend-state
    pools
    program
    (Linux)
    (Scalar)
    spans
    true
    false
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-reader-context-smoke-backends-ok?
  [pools-a : ast.AstNodePoolContext]
  [program-a : compiler_ir_types.CompilerIrProgram]
  [spans-a : compiler_ir_types.CompilerSourceSpans]
  [pools-b : ast.AstNodePoolContext]
  [program-b : compiler_ir_types.CompilerIrProgram]
  [spans-b : compiler_ir_types.CompilerSourceSpans]
  [backend-state-a : compiler_backend.CompilerBackendState]
  [backend-state-b : compiler_backend.CompilerBackendState]
  [expr-segment-bases : i64]
  [type-segment-bases : i64]
  [base-arena : i64]) : bool
  ;; Emit in the opposite order from optimization. Register allocation runs
  ;; inside each backend call.
  (match (compiler-driver-reader-context-smoke-emit
    backend-state-b
    pools-b
    program-b
    spans-b)
    [(Ok asm-b)
      (if (not
        (compiler-driver-reader-context-smoke-installed?
          expr-segment-bases
          type-segment-bases
          base-arena))
        (compiler-driver-reader-context-smoke-fail
          "reader changed during state B backend")
        (match (compiler-driver-reader-context-smoke-emit
          backend-state-a
          pools-a
          program-a
          spans-a)
          [(Ok asm-a)
            (cond
              [(not
                  (compiler-driver-reader-context-smoke-installed?
                    expr-segment-bases
                    type-segment-bases
                    base-arena))
                (compiler-driver-reader-context-smoke-fail
                  "reader changed during state A backend")]
              [(not (string.eq asm-a asm-b))
                (compiler-driver-reader-context-smoke-fail
                  "state assemblies differ")]
              [(not
                  (and
                    (compiler_backend.compiler-backend-state-scalar-registers-enabled?
                      backend-state-a)
                    (compiler_backend.compiler-backend-state-scalar-registers-enabled?
                      backend-state-b)))
                (compiler-driver-reader-context-smoke-fail
                  "backend scalar options changed")]
              [else true])]
          [(Err diag)
            (compiler-driver-reader-context-smoke-fail
              (str_cat.str-cat
                "state A backend failed: "
                (cdiag.compiler-diagnostic-render (deref diag))))]))]
    [(Err diag)
      (compiler-driver-reader-context-smoke-fail
        (str_cat.str-cat
          "state B backend failed: "
          (cdiag.compiler-diagnostic-render (deref diag))))]))

(define (compiler-driver-reader-context-smoke-optimized-ok?
  [pools-a : ast.AstNodePoolContext]
  [program-a : compiler_ir_types.CompilerIrProgram]
  [spans-a : compiler_ir_types.CompilerSourceSpans]
  [pools-b : ast.AstNodePoolContext]
  [program-b : compiler_ir_types.CompilerIrProgram]
  [spans-b : compiler_ir_types.CompilerSourceSpans]
  [backend-state-a : compiler_backend.CompilerBackendState]
  [backend-state-b : compiler_backend.CompilerBackendState]
  [expr-segment-bases : i64]
  [type-segment-bases : i64]
  [base-arena : i64]) : bool
  (match (compiler_optimize.optimize-program
    program-a
    spans-a
    (compiler_optimize.optimize-request pools-a 1))
    [(Program optimized-a optimized-spans-a)
      (if (not
        (compiler-driver-reader-context-smoke-installed?
          expr-segment-bases
          type-segment-bases
          base-arena))
        (compiler-driver-reader-context-smoke-fail
          "reader changed during state A optimization")
        (match (compiler_optimize.optimize-program
          program-b
          spans-b
          (compiler_optimize.optimize-request pools-b 1))
          [(Program optimized-b optimized-spans-b)
            (if (not
              (compiler-driver-reader-context-smoke-installed?
                expr-segment-bases
                type-segment-bases
                base-arena))
              (compiler-driver-reader-context-smoke-fail
                "reader changed during state B optimization")
              (compiler-driver-reader-context-smoke-backends-ok?
                pools-a
                optimized-a
                optimized-spans-a
                pools-b
                optimized-b
                optimized-spans-b
                backend-state-a
                backend-state-b
                expr-segment-bases
                type-segment-bases
                base-arena))]))]))

(define (compiler-driver-reader-context-smoke-lowered-ok?
  [lowered-a : driver.ResultCompilerDriverLowered]
  [lowered-b : driver.ResultCompilerDriverLowered]) : bool
  (match lowered-a
    [(Ok program-a spans-a pools-a _profile-a backend-state-a _typecheck-a)
      (match lowered-b
        [(Ok program-b spans-b pools-b _profile-b backend-state-b _typecheck-b)
          (let
            [intern-a : ci.InternCompatState
              (compiler_backend.compiler-backend-state-exact-intern
                backend-state-a)]
            [intern-b : ci.InternCompatState
              (compiler_backend.compiler-backend-state-exact-intern
                backend-state-b)]
            [interns-ok? : bool
              (compiler-driver-reader-context-smoke-mirror-intern-state-ok?
                intern-a
                intern-b)]
            [restore-reader : ast.AstNodePoolContext
              (ast.ast-node-pool-reader-context-current)]
            [sentinel : ast.AstNodePoolContext
              (ast.ast-node-pool-context-new-with-capacities 1 1)]
            [expr-segment-bases : i64
              (ast.ast-node-pool-context-expr-segment-bases sentinel)]
            [type-segment-bases : i64
              (ast.ast-node-pool-context-type-segment-bases sentinel)]
            [base-arena : i64 (ast.ast-node-pool-context-base-arena sentinel)]
            [_install-sentinel : unit (ast.ast-node-pool-reader-use! sentinel)]
            [ok : bool
              (if (not interns-ok?)
                (compiler-driver-reader-context-smoke-fail
                  "intern capabilities could not be mirrored")
                (begin
                  (compiler_backend.compiler-backend-state-set-scalar-registers-enabled!
                    backend-state-a
                    true)
                  (compiler_backend.compiler-backend-state-set-scalar-registers-enabled!
                    backend-state-b
                    true)
                  (compiler-driver-reader-context-smoke-optimized-ok?
                    pools-a
                    program-a
                    spans-a
                    pools-b
                    program-b
                    spans-b
                    backend-state-a
                    backend-state-b
                    expr-segment-bases
                    type-segment-bases
                    base-arena)))]
            (ast.ast-node-pool-reader-use! restore-reader)
            ok)]
        [(Err diag _)
          (compiler-driver-reader-context-smoke-fail
            (str_cat.str-cat
              "state B lower failed: "
              (cdiag.compiler-diagnostic-render (deref diag))))])]
    [(Err diag _)
      (compiler-driver-reader-context-smoke-fail
        (str_cat.str-cat
          "state A lower failed: "
          (cdiag.compiler-diagnostic-render (deref diag))))]))

(define (compiler-driver-reader-context-smoke-backend-state-idle?
  [state : driver.CompilerDriverState]) : bool
  (let
    [backend-state : compiler_backend.CompilerBackendState
      (driver.compiler-driver-state-backend state)]
    [intern-state : ci.InternCompatState
      (driver.compiler-driver-state-owned-interns state)]
    (and
      (= (compiler_backend.compiler-backend-state-size) 8)
      (> (compiler_backend.compiler-backend-state-owner-arena backend-state) 0)
      (=
        (compiler_backend.compiler-backend-state-owner-arena backend-state)
        (driver.compiler-driver-state-surface-arena state))
      (=
        (compiler_backend.compiler-backend-state-intern-table-id backend-state)
        (ci.intern-compat-state-table-id intern-state))
      (=
        (compiler_backend.compiler-backend-state-intern-generation
          backend-state)
        (ci.intern-compat-state-generation intern-state))
      (=
        (compiler_backend.compiler-backend-state-lazy-table-arena backend-state)
        0)
      (=
        (compiler_backend.compiler-backend-state-slot-cache-capacity
          backend-state)
        0)
      (=
        (compiler_backend.compiler-backend-state-frame-offset-cache-capacity
          backend-state)
        0)
      (=
        (compiler_backend.compiler-backend-state-immediate-cache-capacity
          backend-state)
        0)
      (=
        (compiler_backend.compiler-backend-state-operand-cache-retained-bytes
          backend-state)
        0)
      (=
        (compiler_backend.compiler-backend-state-user-symbol-cache-count
          backend-state)
        0)
      (=
        (compiler_backend.compiler-backend-state-user-symbol-cache-capacity
          backend-state)
        0)
      (=
        (compiler_backend.compiler-backend-state-user-symbol-cache-retained-bytes
          backend-state)
        0)
      (not
        (compiler_backend.compiler-backend-state-scalar-registers-enabled?
          backend-state)))))

(define (compiler-driver-reader-context-smoke-backend-states-idle?
  [state-a : driver.CompilerDriverState]
  [state-b : driver.CompilerDriverState]) : bool
  (and
    (compiler-driver-reader-context-smoke-backend-state-idle?
      (owned_view.compiler-owned-shared-view state-a))
    (compiler-driver-reader-context-smoke-backend-state-idle?
      (owned_view.compiler-owned-shared-view state-b))
    (not
      (=
        (driver.compiler-driver-state-surface-arena state-a)
        (driver.compiler-driver-state-surface-arena state-b)))))

;; Driver construction owns two nested allocation targets: retained
;; typecheck/lower/backend state in the surface arena, and checked-lowering
;; wrapper cells plus storage in a fresh pool arena. Both constructors must
;; restore their caller, and the latter's returned context must stay readable
;; until its explicit error-path cleanup.
(define (compiler-driver-construction-arena-scope-ok?) : bool
  (let
    ;; Driver state still stores its owners as raw handles. Wrap a raw test
    ;; owner as the production bridge does, rather than claiming the returned
    ;; state is region-polymorphic under a direct `arena.make` owner.
    [caller-handle : i64 (arena.tl_arena_make)]
    [caller : arena.Arena (arena.Arena caller-handle)]
    [ok : bool
      (in-arena
        caller
        (let
          [state : driver.CompilerDriverState
            (driver.compiler-driver-state-new-for-compile)]
          [surface-arena : i64
            (driver.compiler-driver-state-surface-arena state)]
          [state-restored? : bool
            (and
              (= (arena.tl_arena_current) caller-handle)
              (> surface-arena 0)
              (not (= surface-arena caller-handle))
              (=
                (compiler_backend.compiler-backend-state-owner-arena
                  (driver.compiler-driver-state-backend state))
                surface-arena))]
          [pools : ast.AstNodePoolContext
            (driver.compiler-driver-state-new-checked-lower-pools)]
          [pool-arena : i64 (ast.ast-node-pool-context-base-arena pools)]
          [pools-restored? : bool
            (and
              (= (arena.tl_arena_current) caller-handle)
              (> pool-arena 0)
              (not (= pool-arena caller-handle))
              (= (ast.ast-node-pool-context-expr-len pools) 0)
              (= (ast.ast-node-pool-context-type-len pools) 0))]
          (driver.compiler-driver-state-destroy-uncommitted-pools! pools)
          (and
            state-restored?
            pools-restored?
            (= (arena.tl_arena_current) caller-handle))))]
    (unsafe
      (arena.tl_arena_destroy caller-handle))
    ok))

(define (compiler-driver-reader-context-smoke-prepare-state!
  [state : driver.CompilerDriverState]) : unit
  (let
    [intern-state : ci.InternCompatState
      (driver.compiler-driver-state-owned-interns state)]
    (if (= (driver.compiler-driver-state-intern-generation state) 0)
      (ci.intern-compat-state-reset! (&mut intern-state))
      unit)
    (driver.compiler-driver-state-install-pools! state)
    (driver.compiler-driver-state-install-interns! state)
    (driver.compiler-driver-state-reset-file-state! state)
    unit))

(define (compiler-driver-reader-context-smoke-ok?) : bool
  (let
    [state-a : driver.CompilerDriverState
      (driver.compiler-driver-state-new-for-compile)]
    [state-b : driver.CompilerDriverState
      (driver.compiler-driver-state-new-for-compile)]
    [source : String (compiler-driver-reader-context-smoke-write-fixture)]
    [target : compiler_backend.CompilerBackendTarget (Linux)]
    [mode : compiler_backend.CompilerBackendMode (Scalar)]
    [roots-a : svec.Vec (compiler-driver-pic-smoke-roots)]
    [idle-backend-state-ok? : bool
      (compiler-driver-reader-context-smoke-backend-states-idle?
        (owned_view.compiler-owned-shared-view state-a)
        (owned_view.compiler-owned-shared-view state-b))]
    (if (not idle-backend-state-ok?)
      (compiler-driver-reader-context-smoke-fail
        "fresh backend state is not idle/owned")
      (begin
        (compiler-driver-reader-context-smoke-prepare-state!
          (owned_view.compiler-owned-shared-view state-a))
        (let
          [lowered-a : driver.ResultCompilerDriverLowered
            (driver.compiler-driver-load-and-lower-pic-image-with-state-and-retirement
              (owned_view.compiler-owned-shared-view state-a)
              source
              target
              roots-a
              mode
              (driver.compiler-driver-state-target-cfgs
                state-a
                target
                (compiler_cfg_core.compiler-cfg-empty))
              true)]
          ;; The frontend still has separately tracked state-isolation work
          ;; (#4723, #4960-#4962). Fork the completed lower result into a second
          ;; state-owned reader context here, then interleave the phases covered
          ;; by this smoke: optimizer, regalloc, and backend.
          (match (owned_view.compiler-owned-shared-view lowered-a)
            [(Ok program-a spans-a pools-a _profile-a _backend-a _typecheck-a)
              (let
                [pools-b : ast.AstNodePoolContext
                  (ast.ast-node-pool-context-clone-types-only pools-a)]
                [program-b : compiler_ir_types.CompilerIrProgram
                  (compiler_ir_types.compiler-ir-clone-program-shell
                    pools-b
                    (& program-a))]
                [spans-b : compiler_ir_types.CompilerSourceSpans
                  (clone spans-a)]
                (driver.compiler-driver-state-adopt-pools! state-b pools-b)
                (compiler-driver-reader-context-smoke-lowered-ok?
                  lowered-a
                  (Ok
                    program-b
                    spans-b
                    pools-b
                    (driver.compiler-driver-state-profile state-b)
                    (driver.compiler-driver-state-backend state-b)
                    (driver.compiler-driver-state-typecheck state-b))))]
            [(Err diag _)
              (compiler-driver-reader-context-smoke-fail
                (str_cat.str-cat
                  "state A lower failed: "
                  (cdiag.compiler-diagnostic-render (deref diag))))]))))))

;; Reuse two real compile states with different target/custom cfg sets. Main's
;; source cfg selects names that exist only in the matching generated branch,
;; so successful compilation proves selection rather than just parsing syntax.
(define (compiler-driver-generated-cfg-job-ok?
  [state : (& state driver.CompilerDriverState)]
  [target : compiler_backend.CompilerBackendTarget]
  [enabled : bool]) : bool
  (let
    [state : driver.CompilerDriverState
      (owned_view.compiler-owned-reference-shared-view state)]
    (compiler-driver-reader-context-smoke-prepare-state!
      (owned_view.compiler-owned-shared-view state))
    (let
      [cfgs : sym_i64_env.SymI64Env
        (if enabled
          (compiler_cfg_core.compiler-cfg-enable-with-intern-state
            (compiler_cfg_core.compiler-cfg-empty)
            "generated-cfg-feature"
            (driver.compiler-driver-state-owned-interns-mut
              (owned_view.compiler-owned-shared-view state)))
          (compiler_cfg_core.compiler-cfg-empty))]
      (match (driver.compiler-driver-state-emit-file-buffer-with-target-roots-level-mode-and-cfg
        state
        "tests/integration/generated_cfg.tl"
        target
        true
        (compiler-driver-pic-smoke-roots)
        0
        Scalar
        cfgs
        true)
        [(Ok _ _) true]
        [(Err diagnostic _)
          (compiler-driver-reader-context-smoke-fail
            (cdiag.compiler-diagnostic-render (deref diagnostic)))]))))

(define (compiler-driver-generated-cfg-isolation-ok?) : bool
  (let
    [state-a : driver.CompilerDriverState
      (driver.compiler-driver-state-new-for-compile)]
    [state-b : driver.CompilerDriverState
      (driver.compiler-driver-state-new-for-compile)]
    [a-enabled : bool
      (compiler-driver-generated-cfg-job-ok? state-a Linux true)]
    [a-intern : ci.InternCompatState
      (driver.compiler-driver-state-owned-interns state-a)]
    [a-table : i64 (ci.intern-compat-state-table-id a-intern)]
    [a-count : i64 (ci.intern-compat-state-pool-len a-intern)]
    [a-pools : ast.AstNodePoolContext
      (driver.compiler-driver-state-pool-context state-a)]
    [a-exprs : i64 (ast.ast-node-pool-context-expr-len a-pools)]
    [a-types : i64 (ast.ast-node-pool-context-type-len a-pools)]
    [b-disabled : bool
      (compiler-driver-generated-cfg-job-ok? state-b Windows false)]
    [a-unchanged : bool
      (let
        [intern : ci.InternCompatState
          (driver.compiler-driver-state-owned-interns state-a)]
        [pools : ast.AstNodePoolContext
          (driver.compiler-driver-state-pool-context state-a)]
        (and
          (= (ci.intern-compat-state-table-id intern) a-table)
          (= (ci.intern-compat-state-pool-len intern) a-count)
          (= (ast.ast-node-pool-context-expr-len pools) a-exprs)
          (= (ast.ast-node-pool-context-type-len pools) a-types)))]
    [a-reused : bool (compiler-driver-generated-cfg-job-ok? state-a Linux true)]
    [a-disabled : bool
      (compiler-driver-generated-cfg-job-ok? state-a Linux false)]
    [b-enabled : bool
      (compiler-driver-generated-cfg-job-ok? state-b Windows true)]
    (and a-enabled b-disabled a-unchanged a-reused a-disabled b-enabled)))

(define (compiler-driver-reader-context-smoke-main) : i64
  (cbi.compiler-builtin-reset!)
  (cbi.compiler-builtin-initialize-for-parse!)
  (unless (compiler-driver-construction-arena-scope-ok?) (return 2))
  (unless
    (compiler-driver-reader-context-smoke-ok?)
    (io.panic "compiler-driver: reader context isolation failed"))
  42)

;; The reader-context smoke intentionally exercises low-level pool/reader
;; switching. Keep this end-to-end frontend sequence in its own suite child,
;; while all A/B cfg jobs remain in one process to test their isolation.
(define (compiler-driver-generated-cfg-smoke-main) : i64
  (cbi.compiler-builtin-reset!)
  (cbi.compiler-builtin-initialize-for-parse!)
  (unless
    (compiler-driver-generated-cfg-isolation-ok?)
    (io.panic "compiler-driver: generated cfg isolation failed"))
  42)

;; A batch reset advances the owned intern generation before the next loader
;; pass. Lazy aliases recorded by that loader must already carry the new
;; generation when the post-load source-name snapshot refreshes its count.
(define (compiler-driver-lazy-import-reset-source-names-ok?) : bool
  (let
    [state : driver.CompilerDriverState
      (driver.compiler-driver-state-new-for-compile)]
    [job-state : tc.TcJobState (driver.compiler-driver-state-typecheck state)]
    [macro-state : tc.TcMacroState (tc.tc-job-state-macro-state job-state)]
    (driver.compiler-driver-state-install-pools! state)
    (driver.compiler-driver-state-install-interns! state)
    (driver.compiler-driver-state-reset-file-state!
      (owned_view.compiler-owned-shared-view state))
    (let
      [intern-state : ci.InternCompatState
        (driver.compiler-driver-state-owned-interns state)]
      [importer : i64
        (ci.intern-compat-state-intern (&mut intern-state) "driver.lazy.entry")]
      [alias : i64
        (ci.intern-compat-state-intern (&mut intern-state) "driver-lazy-alias")]
      [target : i64
        (ci.intern-compat-state-intern (&mut intern-state) "driver.lazy.target")]
      ;; The first insert may lazily reset a fresh table and advance its
      ;; generation, so snapshot the identity only after populating it.
      [generation : i64 (ci.intern-compat-state-generation intern-state)]
      (tc.tc-lazy-import-stub-record-for-job!
        job-state
        importer
        alias
        target
        true)
      ;; Parsing grows the same-generation source-name table. Model the
      ;; driver's post-load refresh and require its freshly recorded alias
      ;; to survive.
      (tc.tc-macro-state-bind-source-names!
        macro-state
        (ci.intern-source-name-session-handle-from-state intern-state))
      (and
        (=
          generation
          (ci.intern-source-name-session-handle-reset-generation
            (tc.tc-macro-state-source-names macro-state)))
        (= (tc.tc-lazy-import-stub-count-for-state macro-state) 1)
        (match (tc.tc-lazy-import-stub-target-id-for-state
          macro-state
          importer
          alias)
          [(Some actual) (= actual target)]
          [(No) false])))))

;; The lowered-result boundary must reset the job that produced the IR while
;; retaining its compact definition-site alias handoff for package surface
;; emission. Before the job traveled with ResultCompilerDriverLowered, this
;; helper initialized and reset the unrelated serial adapter instead. Keep both
;; owners' aliases distinct while proving that the producing job is the one
;; reset at this boundary.
(define (compiler-driver-post-lower-typecheck-owner-ok?) : bool
  (let
    [state-a : driver.CompilerDriverState
      (driver.compiler-driver-state-new-for-compile)]
    [state-b : driver.CompilerDriverState
      (driver.compiler-driver-state-new-for-compile)]
    [job-a : tc.TcJobState (driver.compiler-driver-state-typecheck state-a)]
    [job-b : tc.TcJobState (driver.compiler-driver-state-typecheck state-b)]
    [macro-a : tc.TcMacroState (tc.tc-job-state-macro-state job-a)]
    [macro-b : tc.TcMacroState (tc.tc-job-state-macro-state job-b)]
    (driver.compiler-driver-state-install-pools! state-a)
    (driver.compiler-driver-state-install-interns! state-a)
    (driver.compiler-driver-state-reset-file-state! state-a)
    (tc.tc-lazy-import-stub-record-for-job! job-a 11 12 13 true)
    (tc.tc-lazy-import-summary-macro-force-record-for-state! macro-a)
    (driver.compiler-driver-state-install-pools! state-b)
    (driver.compiler-driver-state-install-interns! state-b)
    (driver.compiler-driver-state-reset-file-state! state-b)
    (tc.tc-lazy-import-stub-record-for-job! job-b 11 12 14 false)
    (tc.tc-lazy-import-summary-macro-force-record-for-state! macro-b)
    (driver.compiler-driver-release-typecheck-caches-after-lower-for-job! job-a)
    (and
      (= (tc.tc-lazy-import-summary-macro-force-count-for-state macro-a) 0)
      (= (tc.tc-lazy-import-summary-macro-force-count-for-state macro-b) 1)
      (= (tc.tc-lazy-import-stub-count-for-state macro-a) 1)
      (= (tc.tc-lazy-import-stub-count-for-state macro-b) 1)
      (match (tc.tc-lazy-import-stub-target-id-for-state macro-a 11 12)
        [(Some target) (= target 13)]
        [(No) false])
      (match (tc.tc-lazy-import-stub-target-id-for-state macro-b 11 12)
        [(Some target) (= target 14)]
        [(No) false]))))

(define (compiler-driver-typecheck-cache-owner-smoke-ok?) : bool
  (let
    [state-a : driver.CompilerDriverState
      (driver.compiler-driver-state-new-for-compile)]
    [state-b : driver.CompilerDriverState
      (driver.compiler-driver-state-new-for-compile)]
    [intern-a : ci.InternCompatState
      (driver.compiler-driver-state-owned-interns state-a)]
    [intern-b : ci.InternCompatState
      (driver.compiler-driver-state-owned-interns state-b)]
    [cache-a : tc.TcSourceKeyCacheState
      (tc.tc-job-state-source-key-cache
        (driver.compiler-driver-state-typecheck state-a))]
    [cache-b : tc.TcSourceKeyCacheState
      (tc.tc-job-state-source-key-cache
        (driver.compiler-driver-state-typecheck state-b))]
    [module-a : i64
      (ci.intern-compat-state-intern
        (&mut intern-a)
        "driver-state.cache.module")]
    [name-a : i64
      (ci.intern-compat-state-intern (&mut intern-a) "driver-state.cache.name")]
    [module-b : i64
      (ci.intern-compat-state-intern
        (&mut intern-b)
        "driver-state.cache.module")]
    [name-b : i64
      (ci.intern-compat-state-intern (&mut intern-b) "driver-state.cache.name")]
    (tc.tc-source-dotted-alias-key-cache-put-for-state!
      (owned_view.compiler-owned-shared-view cache-a)
      (ci.intern-compat-state-table-id (& intern-a))
      (ci.intern-compat-state-generation (& intern-a))
      module-a
      name-a
      71)
    (tc.tc-source-dotted-alias-key-cache-put-for-state!
      (owned_view.compiler-owned-shared-view cache-b)
      (ci.intern-compat-state-table-id (& intern-b))
      (ci.intern-compat-state-generation (& intern-b))
      module-b
      name-b
      72)
    (driver.compiler-driver-state-reset-typecheck! state-a)
    (and
      (=
        (tc.tc-source-dotted-alias-key-cache-get-for-state
          cache-a
          (ci.intern-compat-state-table-id (& intern-a))
          (ci.intern-compat-state-generation (& intern-a))
          module-a
          name-a)
        -2)
      (=
        (tc.tc-source-dotted-alias-key-cache-get-for-state
          cache-b
          (ci.intern-compat-state-table-id (& intern-b))
          (ci.intern-compat-state-generation (& intern-b))
          module-b
          name-b)
        72)
      (compiler-driver-lazy-import-reset-source-names-ok?)
      (compiler-driver-post-lower-typecheck-owner-ok?))))

;; Base-transient A/B interleaving smoke (refs #4723). Builtin/CTFE id state
;; and lower scratch/IR arenas are owned by each driver state: a state-owned
;; reset or release touches the compatibility globals only while they name
;; that state's handles, and never disturbs another state's installed storage.
(define (compiler-driver-base-transients-lower-arenas-ok?
  [state-a : driver.CompilerDriverState]
  [state-b : driver.CompilerDriverState]) : bool
  (let
    [lower-a : lower.CompilerLowerArenaState
      (driver.compiler-driver-state-owned-lower-arenas
        (owned_view.compiler-owned-shared-view state-a))]
    [lower-b : lower.CompilerLowerArenaState
      (driver.compiler-driver-state-owned-lower-arenas
        (owned_view.compiler-owned-shared-view state-b))]
    ;; A installs empty cells; the lazy selectors create its arenas.
    (driver.compiler-driver-state-install-lower-arenas!
      (owned_view.compiler-owned-shared-view state-a))
    (let
      [_a-scratch : i64 (lower.lower-scratch-arena-get)]
      [_a-ir : i64 (lower.lower-ir-arena-get)]
      (driver.compiler-driver-state-capture-active-lower-arenas!
        (owned_view.compiler-owned-shared-view state-a))
      ;; Installed release: A's cells and the selectors both zero.
      (driver.compiler-driver-state-release-lower-arenas!
        (owned_view.compiler-owned-shared-view state-a))
      (let
        [released-ok? : bool
          (and
            (= (lower.compiler-lower-arena-state-scratch-arena lower-a) 0)
            (= (lower.compiler-lower-arena-state-ir-arena lower-a) 0)
            (= lower.lower-scratch-arena 0)
            (= lower.lower-ir-arena 0))]
        ;; State reuse: fresh arenas recreate through the selectors.
        [_a-scratch-2 : i64 (lower.lower-scratch-arena-get)]
        [_a-ir-2 : i64 (lower.lower-ir-arena-get)]
        (driver.compiler-driver-state-capture-active-lower-arenas!
          (owned_view.compiler-owned-shared-view state-a))
        ;; B parks its own arena chain in the selectors.
        (lower.compiler-lower-arena-state-set!
          lower-b
          (arena.tl_arena_make)
          (arena.tl_arena_make))
        (driver.compiler-driver-state-install-lower-arenas!
          (owned_view.compiler-owned-shared-view state-b))
        ;; Isolation: A's release must not zero or destroy B's arenas.
        (driver.compiler-driver-state-release-lower-arenas! state-a)
        (let
          [isolated-ok? : bool
            (and
              released-ok?
              (> _a-scratch-2 0)
              (> _a-ir-2 0)
              (=
                (lower.lower-scratch-arena-get)
                (lower.compiler-lower-arena-state-scratch-arena lower-b))
              (=
                (lower.lower-ir-arena-get)
                (lower.compiler-lower-arena-state-ir-arena lower-b)))]
          ;; B's own release still zeroes the selectors it owns.
          (driver.compiler-driver-state-release-lower-arenas! state-b)
          (let
            [b-released-ok? : bool
              (and
                (= (lower.compiler-lower-arena-state-scratch-arena lower-b) 0)
                (= (lower.compiler-lower-arena-state-ir-arena lower-b) 0)
                (= lower.lower-scratch-arena 0)
                (= lower.lower-ir-arena 0))]
            ;; Reuse once more after B's release, then clean up.
            (lower.lower-scratch-arena-get)
            (lower.lower-ir-arena-get)
            (lower.lower-arenas-release!)
            (and isolated-ok? b-released-ok?)))))))

;; The driver owns one opaque lower job state per compile state. Run real
;; frontend lowers with deliberately identical source/AST IDs in A and B, plus
;; failures and reset/reuse in B. A's complete structural observation (including
;; SPMD package and memo backing) must remain exact throughout.
(define (compiler-driver-lower-state-isolation-ok?) : bool
  (let
    [state-a : driver.CompilerDriverState
      (driver.compiler-driver-state-new-for-compile)]
    [state-b : driver.CompilerDriverState
      (driver.compiler-driver-state-new-for-compile)]
    [lower-a : lower.CompilerLowerState
      (driver.compiler-driver-state-owned-lower-state state-a)]
    [lower-b : lower.CompilerLowerState
      (driver.compiler-driver-state-owned-lower-state state-b)]
    [initial-a : lower.CompilerLowerStateObservation
      (lower.compiler-lower-state-observe lower-a)]
    [b-prepopulate-failed : bool
      (match (lower.lower-compiler-source-with-path-mode-package-and-state
        lower-b
        "<state-b-pre-failure>"
        "(define"
        (Scalar)
        "package-b-pre-failure")
        [(Err _) true]
        [(Ok _ _) false])]
    [a-after-b-prepopulate-failure : lower.CompilerLowerStateObservation
      (lower.compiler-lower-state-observe lower-a)]
    (match (lower.lower-compiler-source-with-path-mode-package-and-state
      lower-a
      "<state-a>"
      "(define (helper) : i64 42)
(module main)
(define (main) : i64 (helper))"
      (Scalar)
      "package-a")
      [(Err diag)
        (compiler-driver-reader-context-smoke-fail
          (str_cat.str-cat
            "lower state A failed: "
            (cdiag.compiler-diagnostic-render (deref diag))))]
      [(Ok _ _)
        (let
          [a-before : lower.CompilerLowerStateObservation
            (lower.compiler-lower-state-observe lower-a)]
          [b-failed : bool
            (match (lower.lower-compiler-source-with-path-mode-package-and-state
              lower-b
              "<state-b-failure>"
              "(module main)
(define (main) : i64 lower-state-controlled-failure)"
              (Scalar)
              "package-b-failure")
              [(Err _) true]
              [(Ok _ _) false])]
          (driver.compiler-driver-state-reset-lower!
            (owned_view.compiler-owned-shared-view state-b))
          (let
            [b-reset-before-reuse : bool
              (compiler_lower_tests.compiler-lower-state-reset? lower-b)]
            (match (lower.lower-compiler-source-with-path-mode-package-and-state
              lower-b
              "<state-b-reuse>"
              "(define (helper) : i64 42)
(module main)
(define (main) : i64 (helper))"
              (Scalar)
              "package-b-reuse")
              [(Err diag)
                (compiler-driver-reader-context-smoke-fail
                  (str_cat.str-cat
                    "lower state B reuse failed: "
                    (cdiag.compiler-diagnostic-render (deref diag))))]
              [(Ok _ _)
                (let
                  [a-after-b-reuse : lower.CompilerLowerStateObservation
                    (lower.compiler-lower-state-observe lower-a)]
                  [b-package-reused : bool
                    (string.eq
                      (lower.compiler-lower-state-spmd-package-name lower-b)
                      "package-b-reuse")]
                  (driver.compiler-driver-state-reset-lower! state-b)
                  (let
                    [a-after-b-final-reset : lower.CompilerLowerStateObservation
                      (lower.compiler-lower-state-observe lower-a)]
                    (cond
                      [(not (= (lower.compiler-lower-state-size) 8))
                        (compiler-driver-reader-context-smoke-fail
                          "lower state carrier is not one word")]
                      [(= lower-a.address lower-b.address)
                        (compiler-driver-reader-context-smoke-fail
                          "lower state owners alias")]
                      [(not b-prepopulate-failed)
                        (compiler-driver-reader-context-smoke-fail
                          "controlled pre-cache lower state B failure succeeded")]
                      [(not
                          (lower.compiler-lower-state-observation-eq?
                            (& initial-a)
                            (& a-after-b-prepopulate-failure)))
                        (compiler-driver-reader-context-smoke-fail
                          "pre-cache state B failure mutated state A")]
                      [(lower.compiler-lower-state-observation-eq?
                          (& initial-a)
                          (& a-before))
                        (compiler-driver-reader-context-smoke-fail
                          "successful lower did not populate state A")]
                      [(not
                          (string.eq
                            (lower.compiler-lower-state-spmd-package-name
                              lower-a)
                            "package-a"))
                        (compiler-driver-reader-context-smoke-fail
                          "state A package identity changed")]
                      [(not b-failed)
                        (compiler-driver-reader-context-smoke-fail
                          "controlled lower state B failure succeeded")]
                      [(not b-reset-before-reuse)
                        (compiler-driver-reader-context-smoke-fail
                          "state B reset did not restore logical fresh state")]
                      [(not b-package-reused)
                        (compiler-driver-reader-context-smoke-fail
                          "state B package identity was not reusable")]
                      [(not
                          (lower.compiler-lower-state-observation-eq?
                            (& a-before)
                            (& a-after-b-reuse)))
                        (compiler-driver-reader-context-smoke-fail
                          "state B reuse mutated state A")]
                      [(not
                          (lower.compiler-lower-state-observation-eq?
                            (& a-before)
                            (& a-after-b-final-reset)))
                        (compiler-driver-reader-context-smoke-fail
                          "state B final reset mutated state A")]
                      [(not
                          (compiler_lower_tests.compiler-lower-state-reset?
                            lower-b))
                        (compiler-driver-reader-context-smoke-fail
                          "state B final reset did not restore logical fresh state")]
                      [else true])))])))])))

(define (compiler-driver-base-transients-smoke-ok?) : bool
  (let
    [state-a : driver.CompilerDriverState
      (driver.compiler-driver-state-new-for-compile)]
    [state-b : driver.CompilerDriverState
      (driver.compiler-driver-state-new-for-compile)]
    [intern-a : ci.InternCompatState
      (driver.compiler-driver-state-owned-interns state-a)]
    [intern-b : ci.InternCompatState
      (driver.compiler-driver-state-owned-interns state-b)]
    [builtins-a : cbi.CompilerBuiltinIdsState
      (driver.compiler-driver-state-owned-builtins
        (owned_view.compiler-owned-shared-view state-a))]
    [builtins-b : cbi.CompilerBuiltinIdsState
      (driver.compiler-driver-state-owned-builtins
        (owned_view.compiler-owned-shared-view state-b))]
    [table-a : i64 (ci.intern-compat-state-table-id intern-a)]
    [table-b : i64 (ci.intern-compat-state-table-id intern-b)]
    ;; Derive A's builtin table from A's own intern state. The first intern
    ;; into the fresh table lazily resets it, so read the owning intern
    ;; identity from the freshly captured cells, as production validation
    ;; does after the session-floor capture.
    (ci.intern-compat-state-install! intern-a)
    (cbi.compiler-builtin-reset!)
    (cbi.compiler-builtin-initialize-for-parse!)
    (driver.compiler-driver-state-capture-active-builtins! (&mut state-a))
    (driver.compiler-driver-state-capture-active-interns! (&mut state-a))
    (let
      [gen-a : i64 (driver.compiler-driver-state-intern-generation state-a)]
      [gen-b0 : i64 (driver.compiler-driver-state-intern-generation state-b)]
      [loaded-ok? : bool
        (and
          ;; Builtin lookup + CTFE success: A's snapshot serves the ids and
          ;; validates against A's own intern identity.
          (cbi.state-table-current-with? builtins-a gen-a table-a)
          (not (cbi.state-table-current-with? builtins-a gen-b0 table-b))
          (>= (cbi.state-ctfe-ref builtins-a 0) 0)
          (=
            (cbi.state-ctfe-ref builtins-a 0)
            (cbi.compiler-builtin-ctfe "size-of"))
          ;; Decoy: B's compatibility state never saw a load.
          (not (cbi.state-table-current-with? builtins-b gen-b0 table-b)))]
      ;; CTFE failure/reset: A is installed, so its state-owned reset
      ;; invalidates the compatibility table too.
      (driver.compiler-driver-state-reset-builtins!
        (owned_view.compiler-owned-shared-view state-a))
      (let
        [reset-ok? : bool
          (and
            (not (cbi.state-table-current-with? builtins-a gen-a table-a))
            (not (cbi.compiler-builtin-table-current?)))]
        ;; Install B: derive B's table from B's own intern state.
        (ci.intern-compat-state-install! intern-b)
        (cbi.compiler-builtin-reset!)
        (cbi.compiler-builtin-initialize-for-parse!)
        (driver.compiler-driver-state-capture-active-builtins! (&mut state-b))
        (driver.compiler-driver-state-capture-active-interns! (&mut state-b))
        ;; Isolation: resetting uninstalled A must not disturb B's
        ;; installed compatibility table -- the retired install/reset
        ;; bridge invalidated it unconditionally.
        (driver.compiler-driver-state-reset-builtins!
          (owned_view.compiler-owned-shared-view state-a))
        (let
          [gen-b : i64 (driver.compiler-driver-state-intern-generation state-b)]
          [isolated-ok? : bool
            (and
              (cbi.compiler-builtin-table-current?)
              (cbi.state-table-current-with? builtins-b gen-b table-b)
              (=
                (cbi.state-ctfe-ref builtins-b 0)
                (cbi.compiler-builtin-ctfe "size-of")))]
          (and
            loaded-ok?
            reset-ok?
            isolated-ok?
            (compiler-driver-base-transients-lower-arenas-ok? state-a state-b)
            (compiler-driver-lower-state-isolation-ok?)))))))

(define (compiler-driver-base-transients-smoke-main) : i64
  (if (compiler-driver-base-transients-smoke-ok?)
    42
    1))

(define (compiler-driver-pic-smoke-extern-reject-ok?) : bool
  (match (compiler-driver-emit-file-pic-with-target-roots-level-mode-and-cfg
    (compiler-driver-pic-smoke-write-extern-fixture)
    (Windows)
    true
    (compiler-driver-pic-smoke-roots)
    (compiler_optimize.compiler-optimize-default-level)
    (Scalar)
    (compiler_cfg_core.compiler-cfg-empty))
    [(Ok _ _) false]
    [(Err diag _)
      (let
        [rendered : String (cdiag.compiler-diagnostic-render (deref diag))]
        (compiler-driver-pic-smoke-contains?
          (& rendered)
          "backend: --pic supports only internal references"))]))

(define (compiler-driver-pic-smoke-user-cfg-keeps-runtime-prelude?) : bool
  (match (compiler-driver-load-runtime-prelude-cold
    (compiler-driver-pic-smoke-roots)
    (compiler_cfg_core.compiler-cfg-enable
      (compiler_cfg_core.compiler-cfg-empty)
      "__typelisp_pic_image"))
    [(ResultCompilerLoadWithPaths.Ok _ paths _ _)
      (compiler-driver-pic-smoke-paths-contain? paths "stdlib/runtime.tl")]
    [(ResultCompilerLoadWithPaths.Err _) false]))

(define (compiler-driver-advisory-fixture [message : String]) : cdiag.CompilerDiagnostic
  (cdiag.compiler-diagnostic-with-level
    (& (cdiag.compiler-diagnostic-simple "tests/advisories.tl" 1 1 message))
    CompilerDiagnosticWarning))

(define (compiler-driver-advisory-phase-is?
  [advisories : (& advisories cdiag.CompilerAdvisoryList)]
  [index : i64]
  [phase : cdiag.CompilerAdvisoryPhase]) : bool
  (let
    [advisory : cdiag.CompilerAdvisory
      (cdiag.compiler-advisory-list-get advisories index)]
    (match phase
      [(Semantic)
        (match (cdiag.compiler-advisory-phase (& advisory))
          [(Semantic) true]
          [_ false])]
      [(Lowering)
        (match (cdiag.compiler-advisory-phase (& advisory))
          [(Lowering) true]
          [_ false])]
      [(Optimization)
        (match (cdiag.compiler-advisory-phase (& advisory))
          [(Optimization) true]
          [_ false])]
      [(RegisterAllocation)
        (match (cdiag.compiler-advisory-phase (& advisory))
          [(RegisterAllocation) true]
          [_ false])]
      [(Backend)
        (match (cdiag.compiler-advisory-phase (& advisory))
          [(Backend) true]
          [_ false])])))

(define (compiler-driver-advisory-transport-ok?) : bool
  (let
    [state-a : driver.CompilerDriverState
      (driver.compiler-driver-state-new-for-compile)]
    [state-b : driver.CompilerDriverState
      (driver.compiler-driver-state-new-for-compile)]
    [semantic : cdiag.CompilerDiagnostic
      (compiler-driver-advisory-fixture "semantic")]
    [lowering : cdiag.CompilerDiagnostic
      (compiler-driver-advisory-fixture "lowering")]
    [optimization : cdiag.CompilerDiagnostic
      (compiler-driver-advisory-fixture "optimization")]
    [regalloc : cdiag.CompilerDiagnostic
      (compiler-driver-advisory-fixture "regalloc")]
    [backend : cdiag.CompilerDiagnostic
      (compiler-driver-advisory-fixture "backend")]
    [other : cdiag.CompilerDiagnostic
      (compiler-driver-advisory-fixture "other job")]
    [fatal : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-simple "tests/advisories.tl" 2 1 "fatal")]
    [sink-a : cdiag.CompilerAdvisorySink
      (driver.compiler-driver-state-advisory-sink
        (owned_view.compiler-owned-shared-view state-a))]
    [_append : unit
      (begin
        (cdiag_tests.compiler-advisory-sink-push!
          (tc.tc-job-state-advisory-sink
            (driver.compiler-driver-state-typecheck state-a))
          Semantic
          (& semantic))
        (cdiag_tests.compiler-advisory-sink-push!
          (compiler_lower_tests.compiler-lower-state-advisory-sink
            (driver.compiler-driver-state-owned-lower-state state-a))
          Lowering
          (& lowering))
        (cdiag_tests.compiler-advisory-sink-push!
          sink-a
          Optimization
          (& optimization))
        (cdiag_tests.compiler-advisory-sink-push!
          sink-a
          RegisterAllocation
          (& regalloc))
        (cdiag_tests.compiler-advisory-sink-push!
          (compiler_backend.compiler-backend-state-advisory-sink
            (driver.compiler-driver-state-backend state-a))
          Backend
          (& backend))
        (cdiag_tests.compiler-advisory-sink-push!
          (tc.tc-job-state-advisory-sink
            (driver.compiler-driver-state-typecheck state-b))
          Semantic
          (& other))
        unit)]
    [advisories : cdiag.CompilerAdvisoryList
      (driver.compiler-driver-state-advisories
        (owned_view.compiler-owned-shared-view state-a))]
    [success : driver.ResultCompilerDriver
      (Ok
        "artifact"
        (driver.compiler-driver-state-advisories
          (owned_view.compiler-owned-shared-view state-a)))]
    [failure : driver.ResultCompilerDriver
      (Err
        (box fatal)
        (driver.compiler-driver-state-advisories
          (owned_view.compiler-owned-shared-view state-a)))]
    [transport-ok? : bool
      (and
        (= (cdiag.compiler-advisory-list-count (& advisories)) 5)
        (compiler-driver-advisory-phase-is? (& advisories) 0 Semantic)
        (compiler-driver-advisory-phase-is? (& advisories) 1 Lowering)
        (compiler-driver-advisory-phase-is? (& advisories) 2 Optimization)
        (compiler-driver-advisory-phase-is? (& advisories) 3 RegisterAllocation)
        (compiler-driver-advisory-phase-is? (& advisories) 4 Backend)
        (match success
          [(Ok artifact carried)
            (and
              (string.eq artifact "artifact")
              (= (cdiag.compiler-advisory-list-count (& carried)) 5))]
          [(Err _ _) false])
        (match failure
          [(Ok _ _) false]
          [(Err diag carried)
            (let
              [fatal-diagnostic : cdiag.CompilerDiagnostic (deref diag)]
              (and
                (string.eq
                  (cdiag.compiler-diagnostic-message fatal-diagnostic)
                  "fatal")
                (= (cdiag.compiler-advisory-list-count (& carried)) 5)))]))]
    ;; Reset A as a cache/retry boundary. B is interleaved and must retain
    ;; its own advisory; A's retired payload strings must not leak forward.
    (driver.compiler-driver-state-prefix-cache-enable! state-a)
    (driver.compiler-driver-state-reset-typecheck!
      (owned_view.compiler-owned-shared-view state-a))
    (let
      [after-reset : cdiag.CompilerAdvisoryList
        (driver.compiler-driver-state-advisories state-a)]
      [still-b : cdiag.CompilerAdvisoryList
        (driver.compiler-driver-state-advisories state-b)]
      (and
        transport-ok?
        (= (cdiag.compiler-advisory-list-count (& after-reset)) 0)
        (= (cdiag.compiler-advisory-list-count (& still-b)) 1)))))

(define (compiler-driver-pic-smoke-main) : i64
  (unless (compiler-driver-restore-arena-owner-current-ok?) (return 5))
  (unless (compiler-driver-lower-name-store-owner-current-ok?) (return 6))
  (unless (compiler-driver-pic-smoke-core-macros-ok? (Linux)) (return 1))
  (unless (compiler-driver-pic-smoke-core-macros-ok? (Windows)) (return 2))
  (unless (compiler-driver-pic-smoke-extern-reject-ok?) (return 3))
  (unless (compiler-driver-smoke-module-macro-diagnostic-ok?) (return 7))
  (unless
    (compiler-driver-pic-smoke-user-cfg-keeps-runtime-prelude?)
    (return 4))
  (unless (compiler-driver-runtime-prelude-cache-arena-scope-ok?) (return 8))
  (unless (compiler-driver-advisory-transport-ok?) (return 9))
  42)

(cfg test (import stdlib.test))

(cfg
  test
  (test
    compiler-driver-source-name-session-retained-owner
    (let
      [state : driver.CompilerDriverState
        (driver.compiler-driver-state-new-for-compile)]
      [return-arena : i64 (arena.tl_arena_current)]
      [transient-arena : i64 (arena.tl_arena_make)]
      [source-names : ci.InternSourceNameSessionHandle
        (begin
          (unsafe
            (arena.tl_arena_set transient-arena))
          (let
            [session : ci.InternSourceNameSessionHandle
              (driver.compiler-driver-state-source-name-session
                (owned_view.compiler-owned-shared-view state))]
            (unsafe
              (arena.tl_arena_set return-arena))
            session))]
      [intern-state : ci.InternCompatState
        (driver.compiler-driver-state-owned-interns state)]
      (unsafe
        (arena.tl_arena_destroy transient-arena))
      (test.assert-i64-eq
        (ci.intern-source-name-session-handle-table-id source-names)
        (ci.intern-compat-state-table-id (& intern-state))
        "source-name capability survives retirement of the caller arena")
      (test.assert-i64-eq
        (cast
          (ci.intern-compat-state-profile-metrics-address-ref (& intern-state))
          : i64)
        (cast
          (profile_state.compiler-profile-state-metrics-address
            (driver.compiler-driver-state-profile state))
          : i64)
        "intern owner shares the driver profile metric array"))))

(cfg
  test
  (test
    compiler-driver-profile-prelude-job-isolation
    (let
      [left : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [right : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      (driver.compiler-driver-profile-reset-prelude! left)
      (driver.compiler-driver-profile-reset-prelude! right)
      (driver.compiler-driver-profile-note-prelude-source-pipeline! left)
      (driver.compiler-driver-profile-note-prelude-hydration! right)
      (driver.compiler-driver-profile-note-prelude-source-pipeline! left)
      (driver.compiler-driver-profile-note-prelude-hydration! left)
      (driver.compiler-driver-profile-reset-prelude! right)
      (test.assert-i64-eq
        (driver.compiler-driver-profile-value
          left
          driver.compiler-driver-profile-prelude-source-pipeline-entries-metric)
        2
        "left job keeps interleaved source-pipeline count")
      (test.assert-i64-eq
        (driver.compiler-driver-profile-value
          left
          driver.compiler-driver-profile-prelude-hydrations-metric)
        1
        "right reset does not erase left hydration count")
      (test.assert-i64-eq
        (driver.compiler-driver-profile-value
          right
          driver.compiler-driver-profile-prelude-source-pipeline-entries-metric)
        0
        "right source-pipeline count resets independently")
      (test.assert-i64-eq
        (driver.compiler-driver-profile-value
          right
          driver.compiler-driver-profile-prelude-hydrations-metric)
        0
        "right hydration count resets independently"))))

(cfg
  test
  (test
    compiler-driver-profile-intern-job-isolation
    (let
      [left : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [right : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [left-address : u64
        (profile_state.compiler-profile-state-metrics-address left)]
      [right-address : u64
        (profile_state.compiler-profile-state-metrics-address right)]
      (ci.intern-profile-reset! left-address)
      (ci.intern-profile-reset! right-address)
      (ci.intern-profile-note-intern left-address)
      (ci.intern-profile-note-slice left-address 7)
      (ci.intern-profile-note-lookup right-address)
      (ci.intern-profile-note-generated right-address)
      (ci.intern-profile-reset! right-address)
      (test.assert-i64-eq
        (ci.intern-profile-value left-address ci.intern-profile-intern-metric)
        1
        "left job keeps interleaved intern count")
      (test.assert-i64-eq
        (ci.intern-profile-value
          left-address
          ci.intern-profile-slice-bytes-metric)
        7
        "right reset does not erase left slice bytes")
      (test.assert-i64-eq
        (ci.intern-profile-value right-address ci.intern-profile-lookup-metric)
        0
        "right reset clears its lookup count")
      (test.assert-i64-eq
        (ci.intern-profile-value
          right-address
          ci.intern-profile-generated-metric)
        0
        "right reset clears its generated count"))))

(cfg
  test
  (test
    compiler-driver-profile-intern-storage-job-isolation
    (let
      [left : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [right : profile_state.CompilerProfileState
        (profile_state.compiler-profile-state-new)]
      [left-address : u64
        (profile_state.compiler-profile-state-metrics-address left)]
      [right-address : u64
        (profile_state.compiler-profile-state-metrics-address right)]
      [left-intern : ci.InternCompatState
        (ci.intern-compat-state-new-with-profile-metrics-address left-address)]
      [right-intern : ci.InternCompatState
        (ci.intern-compat-state-new-with-profile-metrics-address right-address)]
      (ci.intern-profile-reset! left-address)
      (ci.intern-profile-reset! right-address)
      (ci.intern-compat-state-reset! (&mut left-intern))
      (ci.intern-compat-state-reset! (&mut right-intern))
      (let
        [left-source : i64
          (ci.intern-compat-state-intern
            (&mut left-intern)
            "left-profile-source")]
        [right-source : i64
          (ci.intern-compat-state-intern
            (&mut right-intern)
            "right-profile-source")]
        [left-canonical : i64
          (ci.intern-compat-state-generated-canonical-name
            (&mut left-intern)
            "left-profile-canonical")]
        [left-canonical-again : i64
          (ci.intern-compat-state-generated-canonical-name
            (&mut left-intern)
            "left-profile-canonical")]
        [right-generated : i64
          (ci.intern-compat-state-generated-name
            (&mut right-intern)
            "right-profile-generated")]
        ;; A known larger observation proves max and total use the same
        ;; numeric slots in one owner without touching the other owner.
        (ci.intern-profile-note-source-map-probe! left-address 4)
        (test.assert-i64-eq
          left-source
          right-source
          "independent owners may assign the same source record id")
        (test.assert-i64-eq
          left-canonical
          right-generated
          "independent owners may assign the same generated record id")
        (test.assert-i64-eq
          left-canonical
          left-canonical-again
          "canonical generated insertion is counted once")
        (ci.intern-profile-reset! right-address)
        (ci.intern-compat-state-reset! (&mut right-intern))
        (test.assert-i64-eq
          (ci.intern-profile-value
            left-address
            ci.intern-profile-source-record-live-metric)
          1
          "right reset preserves left source record live count")
        (test.assert-i64-eq
          (ci.intern-profile-value
            left-address
            ci.intern-profile-generated-record-live-metric)
          1
          "right reset preserves left generated record live count")
        (test.assert-i64-eq
          (ci.intern-profile-value
            left-address
            ci.intern-profile-source-map-live-metric)
          1
          "left source map owns its occupancy")
        (test.assert-i64-eq
          (ci.intern-profile-value
            left-address
            ci.intern-profile-canonical-map-live-metric)
          1
          "left canonical map counts only the new record")
        (test.assert-i64-eq
          (ci.intern-profile-value
            left-address
            ci.intern-profile-source-map-probe-total-metric)
          5
          "source probe total accumulates per owner")
        (test.assert-i64-eq
          (ci.intern-profile-value
            left-address
            ci.intern-profile-source-map-probe-max-metric)
          4
          "source probe maximum is per owner")
        (test.assert-i64-eq
          (ci.intern-profile-value
            left-address
            ci.intern-profile-canonical-map-probe-total-metric)
          2
          "canonical insert and reuse each record one probe")
        (test.assert-i64-eq
          (ci.intern-profile-value
            right-address
            ci.intern-profile-source-record-live-metric)
          0
          "right reset clears only right live observations")
        (test.assert-i64-eq
          (ci.intern-profile-value
            right-address
            ci.intern-profile-source-record-capacity-metric)
          (ci.intern-capacity)
          "right reset restores fixed source record capacity")
        (test.assert-i64-eq
          (ci.intern-profile-value
            right-address
            ci.intern-profile-source-map-resize-metric)
          0
          "fixed source map reports zero resizes")
        (test.assert-true
          (>
            (ci.intern-profile-value
              right-address
              ci.intern-profile-record-reserved-bytes-metric)
            0)
          "right owner restores fixed record reserved bytes")))))

(define (compiler-driver-load-runtime-prelude-cold
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : compiler_load.ResultCompilerLoadWithPaths
  (driver.compiler-driver-load-runtime-prelude-cold-and-profile-state
    stdlib-roots
    cfgs
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-load-runtime-prelude-cache-miss
  [key : compiler_load.CompilerLoadPreludeCacheKey]
  [stdlib-roots : svec.Vec]
  [cfgs : sym_i64_env.SymI64Env]) : compiler_load.ResultCompilerLoadWithPaths
  (driver.compiler-driver-load-runtime-prelude-cache-miss-and-profile-state
    key
    stdlib-roots
    cfgs
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-emit-file-pic-with-target-roots-level-mode-and-cfg
  [input-path : String]
  [target : compiler_backend.CompilerBackendTarget]
  [has-target : bool]
  [stdlib-roots : svec.Vec]
  [opt-level : i64]
  [mode : compiler_backend.CompilerBackendMode]
  [cfgs : sym_i64_env.SymI64Env]) : driver.ResultCompilerDriverPic
  (let
    [profile-state : profile_state.CompilerProfileState
      (profile_state.compiler-profile-state-new)]
    (begin
      (cfg
        compile-profile
        (driver.compiler-driver-profile-start-total profile-state))
      (driver.compiler-driver-emit-lowered-result-pic-with-level-mode-entry-and-crt
        (owned_view.compiler-owned-shared-view input-path)
        (driver.compiler-driver-load-and-lower-pic-image-and-profile-state
          input-path
          target
          stdlib-roots
          mode
          (driver.compiler-driver-target-cfgs target cfgs)
          profile-state)
        target
        has-target
        mode
        opt-level
        false
        false))))

(define (compiler-driver-smoke-write-text-fixture
  [path : String]
  [fallback-path : String]
  [contents : String]) : String
  (if (compiler-driver-pic-smoke-write-fixture-at? (& path) (& contents))
    path
    (begin
      (io.write-file fallback-path (byte_buf.str-as-bytes (& contents)))
      fallback-path)))

;; A report whose diagnostics interleave two files renders each exactly as the
;; one-shot renderer does, and reads each file once (#7895).
(cfg
  test
  (test
    compiler-driver-diagnostic-sources-interleaved-files
    (let
      [path-a : String
        (compiler-driver-smoke-write-text-fixture
          "target/compiler_driver_diagnostic_source_a.tl"
          "compiler_driver_diagnostic_source_a.tl"
          "(define a 1)\n(define b 2)\n")]
      [path-b : String
        (compiler-driver-smoke-write-text-fixture
          "target/compiler_driver_diagnostic_source_b.tl"
          "compiler_driver_diagnostic_source_b.tl"
          "(define c 3)")]
      [a-second : cdiag.CompilerDiagnostic
        (cdiag.compiler-diagnostic-simple (clone path-a) 2 9 "second line of a")]
      [b-first : cdiag.CompilerDiagnostic
        (cdiag.compiler-diagnostic-simple (clone path-b) 1 9 "first line of b")]
      [a-first : cdiag.CompilerDiagnostic
        (cdiag.compiler-diagnostic-simple (clone path-a) 1 9 "first line of a")]
      [sources : driver.CompilerDriverDiagnosticSources
        (driver.compiler-driver-diagnostic-sources-new)]
      [out-a-second : String
        (driver.compiler-driver-render-source-diagnostic-from
          (&mut sources)
          (clone a-second))]
      [out-b-first : String
        (driver.compiler-driver-render-source-diagnostic-from
          (&mut sources)
          (clone b-first))]
      [out-a-first : String
        (driver.compiler-driver-render-source-diagnostic-from
          (&mut sources)
          (clone a-first))]
      (test.assert-owned-string-eq
        out-a-second
        (driver.compiler-driver-render-source-diagnostic a-second)
        "a's second line renders as a one-shot render does")
      (test.assert-owned-string-eq
        out-b-first
        (driver.compiler-driver-render-source-diagnostic b-first)
        "b renders as a one-shot render does")
      (test.assert-owned-string-eq
        out-a-first
        (driver.compiler-driver-render-source-diagnostic a-first)
        "returning to a, an earlier line renders as a one-shot render does")
      (test.assert-i64-eq sources.count 2 "each file is read once"))))