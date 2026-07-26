;; compiler_driver_smoke_tests.tl - Shared driver/lowering integration smokes.
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import "compiler_driver_core.tl")
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
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
      ;; one overflow segment. The saved frontend-return handle still names
      ;; `owner`, while the correct allocation target is the new head.
      (compiler-driver-smoke-runtime-alloc 67108800)
      (compiler-driver-smoke-runtime-alloc 8)
      (let
        [head : i64 (arena.tl_arena_current)]
        (begin
          (compiler-driver-restore-arena-owner-current! owner)
          (let
            [preserved? : bool (= (arena.tl_arena_current) head)]
            (begin
              (unsafe
                (arena.tl_arena_set home))
              (compiler-driver-restore-arena-owner-current! owner)
              (let
                [resumed? : bool (= (arena.tl_arena_current) head)]
                (begin
                  (unsafe
                    (arena.tl_arena_set home)
                    (arena.tl_arena_destroy owner))
                  (and preserved? resumed?))))))))))

(define (lower-symbol-smoke-extern-metadata
  [link-id : i64]
  [matches-source : bool]) : AstExternMetadata
  (AstExternMetadata.Metadata
    (AstExternAbi.C)
    link-id
    (ast-extern-link-input-list-new)
    (ast-extern-metadata-flags false matches-source)
    AstImportedSpmdMetadata.No))

(define (lower-symbol-smoke-parsed-extern-match?
  [source : String]
  [want : bool]) : bool
  (match (parse-ast-source source)
    [(ResultAstProgram.Ok program)
      (match program
        [(AstProgram.Program decls-box)
          (match (ast-decl-list-get
            (& (box-get decls-box))
            0
            (ast-decl-fallback))
            [(AstDecl.Extern _ _ _ metadata _)
              (=
                (ast-extern-metadata-symbol-matches-source? (box-get metadata))
                want)]
            [_ false])])]
    [(ResultAstProgram.Err _) false]))

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
        [source-id : i64 (ci.intern "same-name")]
        [module-id : i64 (ci.intern "identity-module")]
        [link-id : i64 (ci.intern-generated-name "same-name")]
        [opaque-logical-id : i64 (ci.intern-generated-name "same-name")]
        [module-logical-id : i64
          (compiler-symbol-module-key-id-by-id module-id source-id)]
        [module-name : String
          (compiler-symbol-module-key "identity-module" "same-name")]
        [root-env : LowerNameEnv
          (lower-name-env-add-module-binding-id
            LowerNameEnv.Nil
            ""
            (compiler-symbol-root-module-id)
            "same-name"
            source-id
            "same-name"
            source-id
            true)]
        [root-cache : LowerNameCache (lower-name-cache-from-env root-env)]
        [entry-main-source-id : i64 (ci.intern-generated-name "main")]
        [entry-main-env : LowerNameEnv
          (lower-name-env-add-decl-module-binding-id
            LowerNameEnv.Nil
            "entry.tl"
            "entry.tl"
            ""
            (compiler-symbol-root-module-id)
            "main"
            entry-main-source-id)]
        [entry-main-cache : LowerNameCache
          (lower-name-cache-from-env entry-main-env)]
        [stale-main-symbol-id : i64
          (ci.intern-generated-name "package-entry-main")]
        [stale-main-cache : LowerNameCache
          (lower-name-cache-from-env
            (lower-name-env-bind-logical-symbol-id
              entry-main-source-id
              cbi.compiler-builtin-id-fix-main
              stale-main-symbol-id
              LowerNameEnv.Nil))]
        [derived-env : LowerNameEnv
          (lower-name-env-bind-logical-id
            source-id
            "same-name"
            opaque-logical-id
            LowerNameEnv.Nil)]
        (begin
          ;; A composite module key can numerically equal the source key passed
          ;; through a later boundary, but it is not an interned symbol id.
          (unless
            (not
              (lower-logical-symbol-id-direct?
                module-logical-id
                module-logical-id))
            (set! ok false))
          (unless
            (=
              (lower-extern-logical-symbol-id
                source-id
                "same-name"
                source-id
                (lower-symbol-smoke-extern-metadata source-id true))
              source-id)
            (set! ok false))
          (unless
            (=
              (lower-extern-logical-symbol-id
                source-id
                "same-name"
                source-id
                (lower-symbol-smoke-extern-metadata link-id true))
              link-id)
            (set! ok false))
          (unless
            (=
              (lower-extern-logical-symbol-id
                source-id
                "same-name"
                source-id
                (lower-symbol-smoke-extern-metadata link-id false))
              source-id)
            (set! ok false))
          (let
            [module-symbol : i64
              (lower-extern-logical-symbol-id
                module-logical-id
                module-name
                source-id
                (lower-symbol-smoke-extern-metadata link-id true))]
            (unless (not (= module-symbol link-id)) (set! ok false))
            (unless
              (string.eq (ci.intern-str module-symbol) module-name)
              (set! ok false)))
          (unless
            (=
              (lower-name-cache-lookup-symbol-id (& root-cache) source-id -1)
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
              (lower-name-cache-lookup-symbol-id
                (& entry-main-cache)
                cbi.compiler-builtin-id-fix-main
                -1)
              entry-main-source-id)
            (set! ok false))
          (unless
            (=
              (lower-decl-function-symbol-id
                stale-main-cache
                cbi.compiler-builtin-id-fix-main
                entry-main-source-id
                "main")
              entry-main-source-id)
            (set! ok false))
          (match derived-env
            [(LowerNameEnv.Bind _ logical-id symbol-id _)
              (begin
                (unless (= logical-id opaque-logical-id) (set! ok false))
                (unless (not (= symbol-id opaque-logical-id)) (set! ok false))
                (unless
                  (string.eq (ci.intern-str symbol-id) "same-name")
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
            (lower-extern-logical-symbol-id
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

(define (compiler-lower-symbol-identity-smoke-main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (unless
      (lower-symbol-smoke-ok?)
      (panic "lower: typed symbol identity smoke mismatch"))
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
  [paths : AstDeclPathList]
  [needle : String]) : bool
  (match (ast-decl-path-list-step paths)
    [(AstDeclPathListStep.Nil) false]
    [(AstDeclPathListStep.Cons path rest)
      (or
        (compiler-driver-pic-smoke-contains? path needle)
        (compiler-driver-pic-smoke-paths-contain? rest needle))]))

(define (compiler-driver-pic-smoke-output-ok?
  [output : CompilerBackendPicOutput]) : bool
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
  [target : CompilerBackendTarget]
  [input-path : String]) : bool
  (match (compiler-driver-emit-file-pic-with-target-roots-level-mode-and-cfg
    input-path
    target
    true
    (compiler-driver-pic-smoke-roots)
    (compiler-optimize-default-level)
    (CompilerBackendMode.Scalar)
    (compiler-cfg-empty))
    [(ResultCompilerDriverPic.Ok output)
      (compiler-driver-pic-smoke-output-ok? output)]
    [(ResultCompilerDriverPic.Err _) false]))

(define (compiler-driver-pic-smoke-core-macros-ok?
  [target : CompilerBackendTarget]) : bool
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
  (match (try-write-file (& path) (& contents))
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
    (if (compiler-driver-pic-smoke-write-fixture-at? path contents)
      path
      (begin
        (write-file fallback-path contents)
        fallback-path))))

(define (compiler-driver-pic-smoke-extern-reject-ok?) : bool
  (match (compiler-driver-emit-file-pic-with-target-roots-level-mode-and-cfg
    (compiler-driver-pic-smoke-write-extern-fixture)
    (CompilerBackendTarget.Windows)
    true
    (compiler-driver-pic-smoke-roots)
    (compiler-optimize-default-level)
    (CompilerBackendMode.Scalar)
    (compiler-cfg-empty))
    [(ResultCompilerDriverPic.Ok _) false]
    [(ResultCompilerDriverPic.Err diag)
      (compiler-driver-pic-smoke-contains?
        (compiler-diagnostic-render (box-get diag))
        "backend: --pic supports only internal references")]))

(define (compiler-driver-pic-smoke-user-cfg-keeps-runtime-prelude?) : bool
  (match (compiler-driver-load-runtime-prelude-cold
    (compiler-driver-pic-smoke-roots)
    (compiler-cfg-enable (compiler-cfg-empty) "__typelisp_pic_image"))
    [(ResultCompilerLoadWithPaths.Ok _ paths _ _)
      (compiler-driver-pic-smoke-paths-contain? paths "stdlib/runtime.tl")]
    [(ResultCompilerLoadWithPaths.Err _) false]))

(define (compiler-driver-pic-smoke-main) : i64
  (begin
    (unless (compiler-driver-restore-arena-owner-current-ok?) (return 5))
    (unless
      (compiler-driver-pic-smoke-core-macros-ok? (CompilerBackendTarget.Linux))
      (return 1))
    (unless
      (compiler-driver-pic-smoke-core-macros-ok?
        (CompilerBackendTarget.Windows))
      (return 2))
    (unless (compiler-driver-pic-smoke-extern-reject-ok?) (return 3))
    (unless
      (compiler-driver-pic-smoke-user-cfg-keeps-runtime-prelude?)
      (return 4))
    42))