;; compiler_lower_symbol_identity_smoke.tl - Typed lowerer symbol selection.
(import stdlib.string)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import "../compiler_driver_core.tl")

(define (lower-symbol-smoke-extern-metadata
  [link-id : i64]
  [matches-source : bool]) : AstExternMetadata
  (AstExternMetadata.Metadata
    (AstExternAbi.C)
    link-id
    (ast-extern-link-input-list-new)
    (ast-extern-metadata-flags false matches-source)))

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

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (unless
      (lower-symbol-smoke-ok?)
      (panic "lower: typed symbol identity smoke mismatch"))
    42))