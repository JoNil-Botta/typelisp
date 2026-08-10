;; compiler_driver_smoke_tests.tl - Shared driver/lowering integration smokes.
(import stdlib.byte_buf)
(import stdlib.string)
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import compiler_driver_core)
(import compiler_ast_types)
(import compiler_lower)
(import compiler_symbols)
(import compiler_optimize)
(import compiler_cfg_core)
(import compiler_diagnostic)
(import compiler_typecheck_core)
(import compiler_parse_core)
(import compiler_backend)
(import compiler_ir_types)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_profile_state as profile_state)
(import stdlib.arena)

(extern (compiler-driver-smoke-runtime-alloc [bytes : i64]) : i64 (:symbol "tl_alloc"))

(define (compiler-driver-restore-arena-owner-current-ok?) : bool
  (let
    [home : i64 (arena.tl_arena_current)]
    [owner : i64 (arena.tl_arena_make)]
    (begin
      (unsafe
        (arena.tl_arena_set owner))
      ;; Fill the 64 MiB root without touching its payload pages, then force
      ;; one overflow segment. Public current remains the stable `owner` root;
      ;; the physical head is observed only through the raw helper.
      (compiler-driver-smoke-runtime-alloc 67108800)
      (compiler-driver-smoke-runtime-alloc 8)
      (let
        [head : i64
          (compiler_driver_core.compiler-driver-arena-owner-current-head owner)]
        [grown? : bool (not (= head owner))]
        (begin
          (compiler_driver_core.compiler-driver-restore-arena-owner-current!
            owner)
          (let
            [preserved? : bool (= (arena.tl_arena_current) owner)]
            (begin
              (unsafe
                (arena.tl_arena_set home))
              (compiler_driver_core.compiler-driver-restore-arena-owner-current!
                owner)
              (let
                [resumed? : bool (= (arena.tl_arena_current) owner)]
                (begin
                  (unsafe
                    (arena.tl_arena_set home)
                    (arena.tl_arena_destroy owner))
                  (and grown? preserved? resumed?))))))))))

(define (compiler-driver-lower-name-store-owner-current-ok?) : bool
  (let
    [home : i64 (arena.tl_arena_current)]
    [owner : i64 (arena.tl_arena_make)]
    (begin
      (unsafe
        (arena.tl_arena_set owner))
      ;; Advance this owner beyond its root before constructing the store. The
      ;; store retains the owner root while the raw helper exposes its current
      ;; physical head when a later segment is allocated.
      (compiler-driver-smoke-runtime-alloc 67108800)
      (compiler-driver-smoke-runtime-alloc 8)
      (let
        [head : i64 (compiler_lower.lower-name-arena-owner-current-head owner)]
        [store : (Box compiler_lower.LowerNameStore)
          (box (compiler_lower.lower-name-store-new))]
        [store-owner : i64 (struct-get (box-get store) arena)]
        (begin
          (unsafe
            (arena.tl_arena_set home))
          (compiler_lower.lower-name-store-add-segment! (&mut (box-get store)))
          (let
            [home-restored? : bool
              (=
                (compiler_lower.lower-name-arena-owner-root
                  (arena.tl_arena_current))
                (compiler_lower.lower-name-arena-owner-root home))]
            [owner-head : i64
              (compiler_lower.lower-name-arena-owner-current-head owner)]
            [segment-count : i64 (struct-get (box-get store) segment-count)]
            (begin
              (unsafe
                (arena.tl_arena_set home)
                (arena.tl_arena_destroy owner))
              (and
                (not (= head owner))
                (= store-owner owner)
                (= owner-head head)
                home-restored?
                (= segment-count 2)))))))))

(define (lower-symbol-smoke-extern-metadata
  [link-id : i64]
  [matches-source : bool]) : compiler_ast_types.AstExternMetadata
  (compiler_ast_types.AstExternMetadata.Metadata
    (compiler_ast_types.AstExternAbi.C)
    link-id
    (compiler_ast_types.ast-extern-link-input-list-new)
    (compiler_ast_types.ast-extern-metadata-flags false matches-source)
    compiler_ast_types.AstImportedSpmdMetadata.No))

(define (lower-symbol-smoke-parsed-extern-match?
  [source : String]
  [want : bool]) : bool
  (match (compiler_parse_core.parse-ast-source source)
    [(compiler_parse_core.ResultAstProgram.Ok program)
      (match program
        [(compiler_ast_types.AstProgram.Program decls-box)
          (match (compiler_ast_types.ast-decl-list-get
            (& (box-get decls-box))
            0
            (compiler_ast_types.ast-decl-fallback))
            [(compiler_ast_types.AstDecl.Extern _ _ _ metadata _)
              (=
                (compiler_ast_types.ast-extern-metadata-symbol-matches-source?
                  (box-get metadata))
                want)]
            [_ false])])]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (lower-symbol-smoke-ok?) : bool
  (let
    [home : ci.InternCompatState (ci.intern-compat-state-new)]
    [state-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [state-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [ok : bool true]
    (begin
      (unless
        (lower-symbol-smoke-parsed-extern-match?
          "(extern same-name (:symbol \"same-name\") : i64)"
          true)
        (set! ok false))
      (unless
        (lower-symbol-smoke-parsed-extern-match?
          "(extern source-name (:symbol \"link-name\") : i64)"
          false)
        (set! ok false))
      (ci.intern-compat-state-capture-from-globals! home)
      (ci.intern-compat-state-install! state-a)
      (cbi.compiler-builtin-reset!)
      (cbi.compiler-builtin-initialize-for-parse!)
      (let
        [lower-state : compiler_lower.CompilerLowerState
          (compiler_lower.compiler-lower-state-new)]
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
        [root-env : compiler_lower.LowerNameEnv
          (compiler_lower.lower-name-env-add-module-binding-id
            compiler_lower.LowerNameEnv.Nil
            ""
            (compiler_symbols.compiler-symbol-root-module-id)
            "same-name"
            source-id
            "same-name"
            source-id
            true)]
        [root-cache : compiler_lower.LowerNameCache
          (compiler_lower.lower-name-cache-from-env lower-state root-env)]
        [entry-main-source-id : i64 (ci.intern-generated-name "main")]
        [entry-main-env : compiler_lower.LowerNameEnv
          (compiler_lower.lower-name-env-add-decl-module-binding-id
            lower-state
            compiler_lower.LowerNameEnv.Nil
            "entry.tl"
            "entry.tl"
            ""
            (compiler_symbols.compiler-symbol-root-module-id)
            "main"
            entry-main-source-id)]
        [entry-main-cache : compiler_lower.LowerNameCache
          (compiler_lower.lower-name-cache-from-env lower-state entry-main-env)]
        [stale-main-symbol-id : i64
          (ci.intern-generated-name "package-entry-main")]
        [stale-main-cache : compiler_lower.LowerNameCache
          (compiler_lower.lower-name-cache-from-env
            lower-state
            (compiler_lower.lower-name-env-bind-logical-symbol-id
              entry-main-source-id
              cbi.compiler-builtin-id-fix-main
              stale-main-symbol-id
              compiler_lower.LowerNameEnv.Nil))]
        [derived-env : compiler_lower.LowerNameEnv
          (compiler_lower.lower-name-env-bind-logical-id
            source-id
            "same-name"
            opaque-logical-id
            compiler_lower.LowerNameEnv.Nil)]
        (begin
          ;; A composite module key can numerically equal the source key passed
          ;; through a later boundary, but it is not an interned symbol id.
          (unless
            (not
              (compiler_lower.lower-logical-symbol-id-direct?
                module-logical-id
                module-logical-id))
            (set! ok false))
          (unless
            (=
              (compiler_lower.lower-extern-logical-symbol-id
                source-id
                "same-name"
                source-id
                (lower-symbol-smoke-extern-metadata source-id true))
              source-id)
            (set! ok false))
          (unless
            (=
              (compiler_lower.lower-extern-logical-symbol-id
                source-id
                "same-name"
                source-id
                (lower-symbol-smoke-extern-metadata link-id true))
              link-id)
            (set! ok false))
          (unless
            (=
              (compiler_lower.lower-extern-logical-symbol-id
                source-id
                "same-name"
                source-id
                (lower-symbol-smoke-extern-metadata link-id false))
              source-id)
            (set! ok false))
          (let
            [module-symbol : i64
              (compiler_lower.lower-extern-logical-symbol-id
                module-logical-id
                module-name
                source-id
                (lower-symbol-smoke-extern-metadata link-id true))]
            (unless (not (= module-symbol link-id)) (set! ok false))
            (unless
              (string.eq
                (compiler_ir_types.compiler-ir-symbol-text module-symbol)
                module-name)
              (set! ok false)))
          (unless
            (=
              (compiler_lower.lower-name-cache-lookup-symbol-id
                (& root-cache)
                source-id
                -1)
              source-id)
            (set! ok false))
          ;; Entry-main's fixed logical ID can differ from the current parsed
          ;; source symbol after state reuse. Preserve the typed entry-main
          ;; decision while selecting the active source symbol for emission.
          (unless
            (not (= entry-main-source-id cbi.compiler-builtin-id-fix-main))
            (set! ok false))
          (unless
            (=
              (compiler_lower.lower-name-cache-lookup-symbol-id
                (& entry-main-cache)
                cbi.compiler-builtin-id-fix-main
                -1)
              entry-main-source-id)
            (set! ok false))
          (unless
            (=
              (compiler_lower.lower-decl-function-symbol-id
                stale-main-cache
                cbi.compiler-builtin-id-fix-main
                entry-main-source-id
                "main")
              entry-main-source-id)
            (set! ok false))
          (match (compiler_lower.lower-name-env-view derived-env)
            [(compiler_lower.LowerNameEnvView.Bind _ logical-id symbol-id _)
              (begin
                (unless (= logical-id opaque-logical-id) (set! ok false))
                (unless (not (= symbol-id opaque-logical-id)) (set! ok false))
                (unless
                  (string.eq
                    (compiler_ir_types.compiler-ir-symbol-text symbol-id)
                    "same-name")
                  (set! ok false)))]
            [_ (set! ok false)])))
      (ci.intern-compat-state-install! state-b)
      (cbi.compiler-builtin-reset!)
      (cbi.compiler-builtin-initialize-for-parse!)
      (let
        [source-id : i64 (ci.intern "other-name")]
        [link-id : i64 (ci.intern-generated-name "other-name")]
        (unless
          (=
            (compiler_lower.lower-extern-logical-symbol-id
              source-id
              "other-name"
              source-id
              (lower-symbol-smoke-extern-metadata link-id true))
            link-id)
          (set! ok false)))
      (ci.intern-compat-state-install! home)
      (cbi.compiler-builtin-reset!)
      (cbi.compiler-builtin-initialize-for-parse!)
      ok)))

(define (lower-symbol-generated-lane-budget-source) : String
  "(define (shared [x : i64]) : i64 (+ x 1))
(define (first [x : i64]) : i64 (shared x))
(define (second [x : i64]) : i64 (shared (first x)))
(define (main) : i64 (+ (first 1) (second 2)))")

;; Derived logical symbols used to dominate the intern pool's generated lane:
;; 50,409 of the 51,482 generated names a whole-program self-compile allocated,
;; which met the pool's fixed 131,072-slot ceiling and aborted the
;; profile-enabled CLI build with a bare out-of-bounds three stages downstream
;; (#6293). They are minted into the IR's own growable table now, so a compile's
;; generated lane must stay a small fraction of the pool -- the self-compile's
;; lane fell to about 1,073 names, well under capacity/64. Pin both halves of
;; that here: a real front-to-back emit stays inside the budget, and the derived
;; mint itself costs the lane nothing. Moving the mint back into the pool fails
;; as a named smoke instead of as a later bootstrap stage's bare abort.
(define (lower-symbol-generated-lane-budget-ok?) : bool
  (let
    [emitted : bool
      (match (compiler_backend.compiler-backend-emit-source
        (lower-symbol-generated-lane-budget-source))
        [(compiler_backend.ResultCompilerBackend.Ok _) true]
        [(compiler_backend.ResultCompilerBackend.Err _) false])]
    [lane-after-compile : i64 (ci.intern-generated-count)]
    [derived-after-compile : i64
      (compiler_ir_types.compiler-ir-symbol-count-value)]
    [minted : i64
      (compiler_lower.lower-derived-symbol-id "lower-symbol-budget/probe")]
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
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (unless
      (lower-symbol-smoke-ok?)
      (io.panic "lower: typed symbol identity smoke mismatch"))
    (unless
      (lower-symbol-generated-lane-budget-ok?)
      (io.panic "lower: derived symbol generated-lane budget exceeded"))
    42))

(define (compiler-driver-pic-smoke-roots) : svec.Vec
  (let
    [roots : svec.Vec (svec.new)]
    (begin
      (svec.push (&mut roots) "stdlib")
      (svec.push (&mut roots) "../stdlib")
      roots)))

(define (compiler-driver-pic-smoke-contains? [text : String] [needle : String]) : bool
  (string.contains (& text) (& needle)))

(define (compiler-driver-pic-smoke-paths-contain?
  [paths : compiler_ast_types.AstDeclPathList]
  [needle : String]) : bool
  (match (compiler_ast_types.ast-decl-path-list-step paths)
    [(compiler_ast_types.AstDeclPathListStep.Nil) false]
    [(compiler_ast_types.AstDeclPathListStep.Cons path rest)
      (or
        (compiler-driver-pic-smoke-contains? path needle)
        (compiler-driver-pic-smoke-paths-contain? rest needle))]))

(define (compiler-driver-pic-smoke-output-ok?
  [output : compiler_backend.CompilerBackendPicOutput]) : bool
  (let
    [asm : String (struct-get output asm)]
    [fixups : String (struct-get output fixups)]
    (and
      (> (string.string-length asm) 0)
      (compiler-driver-pic-smoke-contains? asm ".L_tl_pic_image_base:\n")
      (not (compiler-driver-pic-smoke-contains? asm "_tl_start"))
      (not (compiler-driver-pic-smoke-contains? asm "main:"))
      (not (compiler-driver-pic-smoke-contains? asm ".extern"))
      (not (compiler-driver-pic-smoke-contains? asm "tl_alloc"))
      (compiler-driver-pic-smoke-contains? fixups "typelisp-pic-fixups v1\n"))))

(define (compiler-driver-pic-smoke-core-macros-path-ok?
  [target : compiler_backend.CompilerBackendTarget]
  [input-path : String]) : bool
  (match (compiler_driver_core.compiler-driver-emit-file-pic-with-target-roots-level-mode-and-cfg
    input-path
    target
    true
    (compiler-driver-pic-smoke-roots)
    (compiler_optimize.compiler-optimize-default-level)
    (compiler_backend.CompilerBackendMode.Scalar)
    (compiler_cfg_core.compiler-cfg-empty))
    [(compiler_driver_core.ResultCompilerDriverPic.Ok output)
      (compiler-driver-pic-smoke-output-ok? output)]
    [(compiler_driver_core.ResultCompilerDriverPic.Err _) false]))

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
  [path : String]
  [contents : String]) : bool
  (match (io.try-write-file (& path) (byte_buf.str-as-bytes (& contents)))
    [(io.OkIoUnit) true]
    [(io.ErrIoUnit _) false]))

(define (compiler-driver-pic-smoke-write-extern-fixture) : String
  (let
    [path : String "target/compiler_driver_pic_extern_fixture.tl"]
    [fallback-path : String "compiler_driver_pic_extern_fixture.tl"]
    [contents : String
      "(extern (foreign-call [arg0 : i64]) : i64 (:abi c) (:symbol \"foreign_exact\"))
(define (main) : i64
  (foreign-call 1))"]
    (if (compiler-driver-pic-smoke-write-fixture-at? path contents)
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
    (if (compiler-driver-pic-smoke-write-fixture-at? path contents)
      path
      (begin
        (io.write-file fallback-path (byte_buf.str-as-bytes (& contents)))
        fallback-path))))

(define (compiler-driver-smoke-module-macro-diagnostic-ok?) : bool
  (match (compiler_driver_core.compiler-driver-emit-file-with-target-roots-level-mode-cfg-and-crt
    (compiler-driver-smoke-write-module-macro-diagnostic-fixture)
    (compiler_backend.CompilerBackendTarget.Linux)
    true
    (compiler-driver-pic-smoke-roots)
    (compiler_optimize.compiler-optimize-default-level)
    (compiler_backend.CompilerBackendMode.Scalar)
    (compiler_cfg_core.compiler-cfg-empty)
    true)
    [(compiler_driver_core.ResultCompilerDriver.Ok _) false]
    [(compiler_driver_core.ResultCompilerDriver.Err diag)
      (let
        [rendered : String
          (compiler_diagnostic.compiler-diagnostic-render (box-get diag))]
        (and
          (compiler-driver-pic-smoke-contains?
            rendered
            "integer literal 300 does not fit expected type u8")
          (compiler-driver-pic-smoke-contains?
            rendered
            "generated identity: :gennum(type_u8)")
          (compiler-driver-pic-smoke-contains?
            rendered
            "generated declaration: big from gennum")))]))

(define (compiler-driver-reader-context-smoke-write-fixture) : String
  (let
    [path : String "target/compiler_driver_reader_context_fixture.tl"]
    [fallback-path : String "compiler_driver_reader_context_fixture.tl"]
    [contents : String
      "(define (square [value : i64]) : i64
  (* value value))
(define (main) : i64
  (+ (square 6) 6))"]
    (if (compiler-driver-pic-smoke-write-fixture-at? path contents)
      path
      (begin
        (io.write-file fallback-path (byte_buf.str-as-bytes (& contents)))
        fallback-path))))

(define (compiler-driver-reader-context-smoke-installed?
  [expr-segment-bases : i64]
  [type-segment-bases : i64]
  [base-arena : i64]) : bool
  (let
    [installed : compiler_ast_types.AstNodePoolContext
      (compiler_ast_types.ast-node-pool-reader-context-current)]
    (and
      (=
        (compiler_ast_types.ast-node-pool-context-expr-segment-bases installed)
        expr-segment-bases)
      (=
        (compiler_ast_types.ast-node-pool-context-type-segment-bases installed)
        type-segment-bases)
      (=
        (compiler_ast_types.ast-node-pool-context-base-arena installed)
        base-arena))))

(define (compiler-driver-reader-context-smoke-fail [message : String]) : bool
  (begin
    (io.print-string (string.append "driver reader-context smoke: " message))
    (io.print-string "\n")
    false))

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
    (begin
      ;; The cloned IR retains A's numeric symbol identities. Rebuild those
      ;; spellings in B's still-fresh capability without installing either
      ;; table, so B remains an independently owned backend job.
      (while (and ok (< source-index source-count-a))
        (let
          [source-id : i64 source-index]
          [mirrored-id : i64
            (ci.intern-compat-state-intern
              intern-b
              (ci.intern-compat-state-str intern-a source-id))]
          (begin
            (if (= mirrored-id source-id)
              unit
              (set! ok false))
            (set! source-index (+ source-index 1)))))
      (while (and ok (< generated-index generated-count-a))
        (let
          [source-id : i64 (- (- (ci.intern-capacity) 1) generated-index)]
          [mirrored-id : i64
            (ci.intern-compat-state-generated-name
              intern-b
              (ci.intern-compat-state-str intern-a source-id))]
          (begin
            (if (= mirrored-id source-id)
              unit
              (set! ok false))
            (set! generated-index (+ generated-index 1)))))
      (and
        ok
        (= source-count-a (ci.intern-compat-state-pool-len intern-b))
        (= generated-count-a (ci.intern-compat-state-generated-count intern-b))
        (not
          (=
            (ci.intern-compat-state-table-id intern-a)
            (ci.intern-compat-state-table-id intern-b)))))))

(define (compiler-driver-reader-context-smoke-emit
  [backend-state : compiler_backend.CompilerBackendState]
  [pools : compiler_ast_types.AstNodePoolContext]
  [program : compiler_ir_types.CompilerIrProgram]
  [spans : compiler_ir_types.CompilerSourceSpans]) : compiler_backend.ResultCompilerBackend
  (compiler_backend.compiler-backend-emit-program-target-with-mode-with-pools-and-crt-and-profile-state-backend-state
    backend-state
    pools
    program
    (compiler_backend.CompilerBackendTarget.Linux)
    (compiler_backend.CompilerBackendMode.Scalar)
    spans
    true
    false
    (profile_state.compiler-profile-state-new)))

(define (compiler-driver-reader-context-smoke-backends-ok?
  [pools-a : compiler_ast_types.AstNodePoolContext]
  [program-a : compiler_ir_types.CompilerIrProgram]
  [spans-a : compiler_ir_types.CompilerSourceSpans]
  [pools-b : compiler_ast_types.AstNodePoolContext]
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
    [(compiler_backend.ResultCompilerBackend.Ok asm-b)
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
          [(compiler_backend.ResultCompilerBackend.Ok asm-a)
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
          [(compiler_backend.ResultCompilerBackend.Err diag)
            (compiler-driver-reader-context-smoke-fail
              (string.append
                "state A backend failed: "
                (compiler_diagnostic.compiler-diagnostic-render (box-get diag))))]))]
    [(compiler_backend.ResultCompilerBackend.Err diag)
      (compiler-driver-reader-context-smoke-fail
        (string.append
          "state B backend failed: "
          (compiler_diagnostic.compiler-diagnostic-render (box-get diag))))]))

(define (compiler-driver-reader-context-smoke-optimized-ok?
  [pools-a : compiler_ast_types.AstNodePoolContext]
  [program-a : compiler_ir_types.CompilerIrProgram]
  [spans-a : compiler_ir_types.CompilerSourceSpans]
  [pools-b : compiler_ast_types.AstNodePoolContext]
  [program-b : compiler_ir_types.CompilerIrProgram]
  [spans-b : compiler_ir_types.CompilerSourceSpans]
  [backend-state-a : compiler_backend.CompilerBackendState]
  [backend-state-b : compiler_backend.CompilerBackendState]
  [expr-segment-bases : i64]
  [type-segment-bases : i64]
  [base-arena : i64]) : bool
  (match (compiler_optimize.optimize-program-with-spans-and-pools-and-level
    pools-a
    program-a
    spans-a
    1)
    [(compiler_optimize.CompilerOptimizedProgram.Program
        optimized-a
        optimized-spans-a)
      (if (not
        (compiler-driver-reader-context-smoke-installed?
          expr-segment-bases
          type-segment-bases
          base-arena))
        (compiler-driver-reader-context-smoke-fail
          "reader changed during state A optimization")
        (match (compiler_optimize.optimize-program-with-spans-and-pools-and-level
          pools-b
          program-b
          spans-b
          1)
          [(compiler_optimize.CompilerOptimizedProgram.Program
              optimized-b
              optimized-spans-b)
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
  [lowered-a : compiler_driver_core.ResultCompilerDriverLowered]
  [lowered-b : compiler_driver_core.ResultCompilerDriverLowered]) : bool
  (match lowered-a
    [(compiler_driver_core.ResultCompilerDriverLowered.Ok
        program-a
        spans-a
        pools-a
        _profile-a
        backend-state-a)
      (match lowered-b
        [(compiler_driver_core.ResultCompilerDriverLowered.Ok
            program-b
            spans-b
            pools-b
            _profile-b
            backend-state-b)
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
            [restore-reader : compiler_ast_types.AstNodePoolContext
              (compiler_ast_types.ast-node-pool-reader-context-current)]
            [sentinel : compiler_ast_types.AstNodePoolContext
              (compiler_ast_types.ast-node-pool-context-new-with-capacities 1 1)]
            [expr-segment-bases : i64
              (compiler_ast_types.ast-node-pool-context-expr-segment-bases
                sentinel)]
            [type-segment-bases : i64
              (compiler_ast_types.ast-node-pool-context-type-segment-bases
                sentinel)]
            [base-arena : i64
              (compiler_ast_types.ast-node-pool-context-base-arena sentinel)]
            [_install-sentinel : unit
              (compiler_ast_types.ast-node-pool-reader-use! sentinel)]
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
            (begin
              (compiler_ast_types.ast-node-pool-reader-use! restore-reader)
              ok))]
        [(compiler_driver_core.ResultCompilerDriverLowered.Err diag)
          (compiler-driver-reader-context-smoke-fail
            (string.append
              "state B lower failed: "
              (compiler_diagnostic.compiler-diagnostic-render (box-get diag))))])]
    [(compiler_driver_core.ResultCompilerDriverLowered.Err diag)
      (compiler-driver-reader-context-smoke-fail
        (string.append
          "state A lower failed: "
          (compiler_diagnostic.compiler-diagnostic-render (box-get diag))))]))

(define (compiler-driver-reader-context-smoke-backend-state-idle?
  [state : compiler_driver_core.CompilerDriverState]) : bool
  (let
    [backend-state : compiler_backend.CompilerBackendState
      (compiler_driver_core.compiler-driver-state-backend state)]
    [intern-state : ci.InternCompatState
      (compiler_driver_core.compiler-driver-state-owned-interns state)]
    (and
      (= (compiler_backend.compiler-backend-state-size) 8)
      (> (compiler_backend.compiler-backend-state-owner-arena backend-state) 0)
      (=
        (compiler_backend.compiler-backend-state-owner-arena backend-state)
        (compiler_driver_core.compiler-driver-state-surface-arena state))
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
  [state-a : compiler_driver_core.CompilerDriverState]
  [state-b : compiler_driver_core.CompilerDriverState]) : bool
  (and
    (compiler-driver-reader-context-smoke-backend-state-idle? state-a)
    (compiler-driver-reader-context-smoke-backend-state-idle? state-b)
    (not
      (=
        (compiler_driver_core.compiler-driver-state-surface-arena state-a)
        (compiler_driver_core.compiler-driver-state-surface-arena state-b)))))

(define (compiler-driver-reader-context-smoke-prepare-state!
  [state : compiler_driver_core.CompilerDriverState]) : unit
  (begin
    (if (=
      (compiler_driver_core.compiler-driver-state-intern-generation state)
      0)
      (ci.intern-compat-state-reset!
        (compiler_driver_core.compiler-driver-state-owned-interns state))
      unit)
    (compiler_driver_core.compiler-driver-state-install-pools! state)
    (compiler_driver_core.compiler-driver-state-install-interns! state)
    (compiler_driver_core.compiler-driver-state-reset-file-state! state)
    unit))

(define (compiler-driver-reader-context-smoke-ok?) : bool
  (let
    [state-a : compiler_driver_core.CompilerDriverState
      (compiler_driver_core.compiler-driver-state-new-for-compile)]
    [state-b : compiler_driver_core.CompilerDriverState
      (compiler_driver_core.compiler-driver-state-new-for-compile)]
    [source : String (compiler-driver-reader-context-smoke-write-fixture)]
    [target : compiler_backend.CompilerBackendTarget
      (compiler_backend.CompilerBackendTarget.Linux)]
    [mode : compiler_backend.CompilerBackendMode
      (compiler_backend.CompilerBackendMode.Scalar)]
    [roots-a : svec.Vec (compiler-driver-pic-smoke-roots)]
    [idle-backend-state-ok? : bool
      (compiler-driver-reader-context-smoke-backend-states-idle?
        state-a
        state-b)]
    (if (not idle-backend-state-ok?)
      (compiler-driver-reader-context-smoke-fail
        "fresh backend state is not idle/owned")
      (begin
        (compiler-driver-reader-context-smoke-prepare-state! state-a)
        (let
          [lowered-a : compiler_driver_core.ResultCompilerDriverLowered
            (compiler_driver_core.compiler-driver-load-and-lower-pic-image-with-state-and-retirement
              state-a
              source
              target
              roots-a
              mode
              (compiler_driver_core.compiler-driver-state-target-cfgs
                state-a
                target
                (compiler_cfg_core.compiler-cfg-empty))
              true)]
          ;; The frontend still has separately tracked state-isolation work
          ;; (#4723, #4960-#4962). Fork the completed lower result into a second
          ;; state-owned reader context here, then interleave the phases covered
          ;; by this smoke: optimizer, regalloc, and backend.
          (match lowered-a
            [(compiler_driver_core.ResultCompilerDriverLowered.Ok
                program-a
                spans-a
                pools-a
                _profile-a
                _backend-a)
              (let
                [pools-b : compiler_ast_types.AstNodePoolContext
                  (compiler_ast_types.ast-node-pool-context-clone-types-only
                    pools-a)]
                [program-b : compiler_ir_types.CompilerIrProgram
                  (compiler_ir_types.compiler-ir-clone-program-shell
                    pools-b
                    program-a)]
                [spans-b : compiler_ir_types.CompilerSourceSpans
                  (clone spans-a)]
                (begin
                  (compiler_driver_core.compiler-driver-state-adopt-pools!
                    state-b
                    pools-b)
                  (compiler-driver-reader-context-smoke-lowered-ok?
                    lowered-a
                    (compiler_driver_core.ResultCompilerDriverLowered.Ok
                      program-b
                      spans-b
                      pools-b
                      (compiler_driver_core.compiler-driver-state-profile
                        state-b)
                      (compiler_driver_core.compiler-driver-state-backend
                        state-b)))))]
            [(compiler_driver_core.ResultCompilerDriverLowered.Err diag)
              (compiler-driver-reader-context-smoke-fail
                (string.append
                  "state A lower failed: "
                  (compiler_diagnostic.compiler-diagnostic-render
                    (box-get diag))))]))))))

(define (compiler-driver-reader-context-smoke-main) : i64
  (begin
    (cbi.compiler-builtin-reset!)
    (cbi.compiler-builtin-initialize-for-parse!)
    (if (compiler-driver-reader-context-smoke-ok?)
      42
      1)))

(define (compiler-driver-typecheck-cache-owner-smoke-ok?) : bool
  (let
    [state-a : compiler_driver_core.CompilerDriverState
      (compiler_driver_core.compiler-driver-state-new-for-compile)]
    [state-b : compiler_driver_core.CompilerDriverState
      (compiler_driver_core.compiler-driver-state-new-for-compile)]
    [intern-a : ci.InternCompatState
      (compiler_driver_core.compiler-driver-state-owned-interns state-a)]
    [intern-b : ci.InternCompatState
      (compiler_driver_core.compiler-driver-state-owned-interns state-b)]
    [cache-a : compiler_typecheck_core.TcSourceKeyCacheState
      (compiler_typecheck_core.tc-job-state-source-key-cache
        (compiler_driver_core.compiler-driver-state-typecheck state-a))]
    [cache-b : compiler_typecheck_core.TcSourceKeyCacheState
      (compiler_typecheck_core.tc-job-state-source-key-cache
        (compiler_driver_core.compiler-driver-state-typecheck state-b))]
    [module-a : i64
      (ci.intern-compat-state-intern intern-a "driver-state.cache.module")]
    [name-a : i64
      (ci.intern-compat-state-intern intern-a "driver-state.cache.name")]
    [module-b : i64
      (ci.intern-compat-state-intern intern-b "driver-state.cache.module")]
    [name-b : i64
      (ci.intern-compat-state-intern intern-b "driver-state.cache.name")]
    (begin
      (compiler_typecheck_core.tc-source-dotted-alias-key-cache-put-for-state!
        cache-a
        (ci.intern-compat-state-table-id intern-a)
        (ci.intern-compat-state-generation intern-a)
        module-a
        name-a
        71)
      (compiler_typecheck_core.tc-source-dotted-alias-key-cache-put-for-state!
        cache-b
        (ci.intern-compat-state-table-id intern-b)
        (ci.intern-compat-state-generation intern-b)
        module-b
        name-b
        72)
      (compiler_driver_core.compiler-driver-state-reset-typecheck! state-a)
      (and
        (=
          (compiler_typecheck_core.tc-source-dotted-alias-key-cache-get-for-state
            cache-a
            (ci.intern-compat-state-table-id intern-a)
            (ci.intern-compat-state-generation intern-a)
            module-a
            name-a)
          -2)
        (=
          (compiler_typecheck_core.tc-source-dotted-alias-key-cache-get-for-state
            cache-b
            (ci.intern-compat-state-table-id intern-b)
            (ci.intern-compat-state-generation intern-b)
            module-b
            name-b)
          72)))))

;; Base-transient A/B interleaving smoke (refs #4723). Builtin/CTFE id state
;; and lower scratch/IR arenas are owned by each driver state: a state-owned
;; reset or release touches the compatibility globals only while they name
;; that state's handles, and never disturbs another state's installed storage.
(define (compiler-driver-base-transients-lower-arenas-ok?
  [state-a : compiler_driver_core.CompilerDriverState]
  [state-b : compiler_driver_core.CompilerDriverState]) : bool
  (let
    [lower-a : compiler_lower.CompilerLowerArenaState
      (compiler_driver_core.compiler-driver-state-owned-lower-arenas state-a)]
    [lower-b : compiler_lower.CompilerLowerArenaState
      (compiler_driver_core.compiler-driver-state-owned-lower-arenas state-b)]
    (begin
      ;; A installs empty cells; the lazy selectors create its arenas.
      (compiler_driver_core.compiler-driver-state-install-lower-arenas! state-a)
      (let
        [_a-scratch : i64 (compiler_lower.lower-scratch-arena-get)]
        [_a-ir : i64 (compiler_lower.lower-ir-arena-get)]
        (begin
          (compiler_driver_core.compiler-driver-state-capture-active-lower-arenas!
            state-a)
          ;; Installed release: A's cells and the selectors both zero.
          (compiler_driver_core.compiler-driver-state-release-lower-arenas!
            state-a)
          (let
            [released-ok? : bool
              (and
                (=
                  (compiler_lower.compiler-lower-arena-state-scratch-arena
                    lower-a)
                  0)
                (=
                  (compiler_lower.compiler-lower-arena-state-ir-arena lower-a)
                  0)
                (= compiler_lower.lower-scratch-arena 0)
                (= compiler_lower.lower-ir-arena 0))]
            ;; State reuse: fresh arenas recreate through the selectors.
            [_a-scratch-2 : i64 (compiler_lower.lower-scratch-arena-get)]
            [_a-ir-2 : i64 (compiler_lower.lower-ir-arena-get)]
            (begin
              (compiler_driver_core.compiler-driver-state-capture-active-lower-arenas!
                state-a)
              ;; B parks its own arena chain in the selectors.
              (compiler_lower.compiler-lower-arena-state-set!
                lower-b
                (arena.tl_arena_make)
                (arena.tl_arena_make))
              (compiler_driver_core.compiler-driver-state-install-lower-arenas!
                state-b)
              ;; Isolation: A's release must not zero or destroy B's arenas.
              (compiler_driver_core.compiler-driver-state-release-lower-arenas!
                state-a)
              (let
                [isolated-ok? : bool
                  (and
                    released-ok?
                    (> _a-scratch-2 0)
                    (> _a-ir-2 0)
                    (=
                      (compiler_lower.lower-scratch-arena-get)
                      (compiler_lower.compiler-lower-arena-state-scratch-arena
                        lower-b))
                    (=
                      (compiler_lower.lower-ir-arena-get)
                      (compiler_lower.compiler-lower-arena-state-ir-arena
                        lower-b)))]
                (begin
                  ;; B's own release still zeroes the selectors it owns.
                  (compiler_driver_core.compiler-driver-state-release-lower-arenas!
                    state-b)
                  (let
                    [b-released-ok? : bool
                      (and
                        (=
                          (compiler_lower.compiler-lower-arena-state-scratch-arena
                            lower-b)
                          0)
                        (=
                          (compiler_lower.compiler-lower-arena-state-ir-arena
                            lower-b)
                          0)
                        (= compiler_lower.lower-scratch-arena 0)
                        (= compiler_lower.lower-ir-arena 0))]
                    (begin
                      ;; Reuse once more after B's release, then clean up.
                      (compiler_lower.lower-scratch-arena-get)
                      (compiler_lower.lower-ir-arena-get)
                      (compiler_lower.lower-arenas-release!)
                      (and isolated-ok? b-released-ok?))))))))))))

;; The driver owns one opaque lower job state per compile state. Populate A
;; through a successful lower, drive B through a semantic failure, then reset B
;; through the driver lifecycle. The 30-cell structural observation of A must
;; remain exact, while B returns to its fresh observation.
(define (compiler-driver-lower-state-isolation-ok?) : bool
  (let
    [state-a : compiler_driver_core.CompilerDriverState
      (compiler_driver_core.compiler-driver-state-new-for-compile)]
    [state-b : compiler_driver_core.CompilerDriverState
      (compiler_driver_core.compiler-driver-state-new-for-compile)]
    [lower-a : compiler_lower.CompilerLowerState
      (compiler_driver_core.compiler-driver-state-owned-lower-state state-a)]
    [lower-b : compiler_lower.CompilerLowerState
      (compiler_driver_core.compiler-driver-state-owned-lower-state state-b)]
    [initial-a : compiler_lower.CompilerLowerStateObservation
      (compiler_lower.compiler-lower-state-observe lower-a)]
    (match (compiler_lower.lower-compiler-source-with-state
      lower-a
      "(define (helper) : i64 42)
(module main)
(define (main) : i64 (helper))")
      [(compiler_lower.ResultCompilerLower.Err diag)
        (compiler-driver-reader-context-smoke-fail
          (string.append
            "lower state A failed: "
            (compiler_diagnostic.compiler-diagnostic-render (box-get diag))))]
      [(compiler_lower.ResultCompilerLower.Ok _ _)
        (let
          [a-before : compiler_lower.CompilerLowerStateObservation
            (compiler_lower.compiler-lower-state-observe lower-a)]
          [b-failed : bool
            (match (compiler_lower.lower-compiler-source-with-state
              lower-b
              "(module main)
(define (main) : i64 lower-state-controlled-failure)")
              [(compiler_lower.ResultCompilerLower.Err _) true]
              [(compiler_lower.ResultCompilerLower.Ok _ _) false])]
          (begin
            (compiler_driver_core.compiler-driver-state-reset-lower! state-b)
            (let
              [a-after : compiler_lower.CompilerLowerStateObservation
                (compiler_lower.compiler-lower-state-observe lower-a)]
              (cond
                [(not (= (compiler_lower.compiler-lower-state-size) 8))
                  (compiler-driver-reader-context-smoke-fail
                    "lower state carrier is not one word")]
                [(= (struct-get lower-a address) (struct-get lower-b address))
                  (compiler-driver-reader-context-smoke-fail
                    "lower state owners alias")]
                [(compiler_lower.compiler-lower-state-observation-eq?
                    initial-a
                    a-before)
                  (compiler-driver-reader-context-smoke-fail
                    "successful lower did not populate state A")]
                [(not b-failed)
                  (compiler-driver-reader-context-smoke-fail
                    "controlled lower state B failure succeeded")]
                [(not
                    (compiler_lower.compiler-lower-state-observation-eq?
                      a-before
                      a-after))
                  (compiler-driver-reader-context-smoke-fail
                    "state B failure/reset mutated state A")]
                [(not (compiler_lower.compiler-lower-state-reset? lower-b))
                  (compiler-driver-reader-context-smoke-fail
                    "state B reset did not restore fresh state")]
                [else true]))))])))

(define (compiler-driver-base-transients-smoke-ok?) : bool
  (let
    [state-a : compiler_driver_core.CompilerDriverState
      (compiler_driver_core.compiler-driver-state-new-for-compile)]
    [state-b : compiler_driver_core.CompilerDriverState
      (compiler_driver_core.compiler-driver-state-new-for-compile)]
    [intern-a : ci.InternCompatState
      (compiler_driver_core.compiler-driver-state-owned-interns state-a)]
    [intern-b : ci.InternCompatState
      (compiler_driver_core.compiler-driver-state-owned-interns state-b)]
    [builtins-a : cbi.CompilerBuiltinIdsState
      (compiler_driver_core.compiler-driver-state-owned-builtins state-a)]
    [builtins-b : cbi.CompilerBuiltinIdsState
      (compiler_driver_core.compiler-driver-state-owned-builtins state-b)]
    [table-a : i64 (ci.intern-compat-state-table-id intern-a)]
    [table-b : i64 (ci.intern-compat-state-table-id intern-b)]
    (begin
      ;; Derive A's builtin table from A's own intern state. The first intern
      ;; into the fresh table lazily resets it, so read the owning intern
      ;; identity from the freshly captured cells, as production validation
      ;; does after the session-floor capture.
      (ci.intern-compat-state-install! intern-a)
      (cbi.compiler-builtin-reset!)
      (cbi.compiler-builtin-initialize-for-parse!)
      (compiler_driver_core.compiler-driver-state-capture-active-builtins!
        state-a)
      (compiler_driver_core.compiler-driver-state-capture-active-interns!
        state-a)
      (let
        [gen-a : i64
          (compiler_driver_core.compiler-driver-state-intern-generation state-a)]
        [gen-b0 : i64
          (compiler_driver_core.compiler-driver-state-intern-generation state-b)]
        [loaded-ok? : bool
          (and
            ;; Builtin lookup + CTFE success: A's snapshot serves the ids and
            ;; validates against A's own intern identity.
            (cbi.state-table-current-with? builtins-a gen-a table-a)
            (not (cbi.state-table-current-with? builtins-a gen-b0 table-b))
            (>= (cbi.state-ctfe-ref builtins-a 0) 0)
            (=
              (cbi.state-ctfe-ref builtins-a 0)
              (cbi.compiler-builtin-ctfe-ref 0))
            ;; Decoy: B's compatibility state never saw a load.
            (not (cbi.state-table-current-with? builtins-b gen-b0 table-b)))]
        (begin
          ;; CTFE failure/reset: A is installed, so its state-owned reset
          ;; invalidates the compatibility table too.
          (compiler_driver_core.compiler-driver-state-reset-builtins! state-a)
          (let
            [reset-ok? : bool
              (and
                (not (cbi.state-table-current-with? builtins-a gen-a table-a))
                (not (cbi.compiler-builtin-table-current?)))]
            (begin
              ;; Install B: derive B's table from B's own intern state.
              (ci.intern-compat-state-install! intern-b)
              (cbi.compiler-builtin-reset!)
              (cbi.compiler-builtin-initialize-for-parse!)
              (compiler_driver_core.compiler-driver-state-capture-active-builtins!
                state-b)
              (compiler_driver_core.compiler-driver-state-capture-active-interns!
                state-b)
              ;; Isolation: resetting uninstalled A must not disturb B's
              ;; installed compatibility table -- the retired install/reset
              ;; bridge invalidated it unconditionally.
              (compiler_driver_core.compiler-driver-state-reset-builtins!
                state-a)
              (let
                [gen-b : i64
                  (compiler_driver_core.compiler-driver-state-intern-generation
                    state-b)]
                [isolated-ok? : bool
                  (and
                    (cbi.compiler-builtin-table-current?)
                    (cbi.state-table-current-with? builtins-b gen-b table-b)
                    (=
                      (cbi.state-ctfe-ref builtins-b 0)
                      (cbi.compiler-builtin-ctfe-ref 0)))]
                (and
                  loaded-ok?
                  reset-ok?
                  isolated-ok?
                  (compiler-driver-base-transients-lower-arenas-ok?
                    state-a
                    state-b)
                  (compiler-driver-lower-state-isolation-ok?))))))))))

(define (compiler-driver-base-transients-smoke-main) : i64
  (if (compiler-driver-base-transients-smoke-ok?)
    42
    1))

(define (compiler-driver-pic-smoke-extern-reject-ok?) : bool
  (match (compiler_driver_core.compiler-driver-emit-file-pic-with-target-roots-level-mode-and-cfg
    (compiler-driver-pic-smoke-write-extern-fixture)
    (compiler_backend.CompilerBackendTarget.Windows)
    true
    (compiler-driver-pic-smoke-roots)
    (compiler_optimize.compiler-optimize-default-level)
    (compiler_backend.CompilerBackendMode.Scalar)
    (compiler_cfg_core.compiler-cfg-empty))
    [(compiler_driver_core.ResultCompilerDriverPic.Ok _) false]
    [(compiler_driver_core.ResultCompilerDriverPic.Err diag)
      (compiler-driver-pic-smoke-contains?
        (compiler_diagnostic.compiler-diagnostic-render (box-get diag))
        "backend: --pic supports only internal references")]))

(define (compiler-driver-pic-smoke-user-cfg-keeps-runtime-prelude?) : bool
  (match (compiler_driver_core.compiler-driver-load-runtime-prelude-cold
    (compiler-driver-pic-smoke-roots)
    (compiler_cfg_core.compiler-cfg-enable
      (compiler_cfg_core.compiler-cfg-empty)
      "__typelisp_pic_image"))
    [(ResultCompilerLoadWithPaths.Ok _ paths _ _)
      (compiler-driver-pic-smoke-paths-contain? paths "stdlib/runtime.tl")]
    [(ResultCompilerLoadWithPaths.Err _) false]))

(define (compiler-driver-pic-smoke-main) : i64
  (begin
    (unless (compiler-driver-restore-arena-owner-current-ok?) (return 5))
    (unless (compiler-driver-lower-name-store-owner-current-ok?) (return 6))
    (unless
      (compiler-driver-pic-smoke-core-macros-ok?
        (compiler_backend.CompilerBackendTarget.Linux))
      (return 1))
    (unless
      (compiler-driver-pic-smoke-core-macros-ok?
        (compiler_backend.CompilerBackendTarget.Windows))
      (return 2))
    (unless (compiler-driver-pic-smoke-extern-reject-ok?) (return 3))
    (unless (compiler-driver-smoke-module-macro-diagnostic-ok?) (return 7))
    (unless
      (compiler-driver-pic-smoke-user-cfg-keeps-runtime-prelude?)
      (return 4))
    42))