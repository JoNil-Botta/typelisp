;; compiler_load_identity_smoke.tl - Loader module identity stays interned.
(import stdlib.io)
(import compiler_load)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import compiler_builtin_ids as cbi)
(import compiler_owned_view as owned_view)
(import compiler_parse_core as parser)
(import stdlib.test)

(define (compiler-load-contextual-origin-check
  [source : String]
  [fallback : String]
  [slot : i64]
  [count : i64]) : unit
  (match (parser.parse-ast-source source)
    [(Ok (Program box))
      (let
        [input : ast.AstDeclList (deref box)]
        [decls : ast.AstDeclList
          (compiler_load.compiler-load-contextual-moduleless-decls
            (owned_view.compiler-owned-shared-view input)
            (owned_view.compiler-owned-shared-view fallback)
            (ci.intern-generated-name fallback))]
        (begin
          (test.assert-i64-eq
            (ast.ast-decl-list-len (& decls))
            count
            "only a missing module gets a prefix")
          (match (parser.compiler-parse-semantic-origin-run (& decls) slot)
            [(Some run)
              (let
                [origin : parser.CompilerParseSemanticOrigin
                  (parser.compiler-parse-semantic-origin-run-get
                    (& run)
                    0
                    (parser.compiler-parse-semantic-origin-fallback))]
                (begin
                  (test.assert-string-eq
                    (ci.intern-str origin.written-name)
                    "Value"
                    "the original source name survives")
                  (test.assert-i64-eq
                    (ast.ast-source-span-start-line origin.span)
                    2
                    "the source token line survives")
                  (test.assert-i64-eq
                    (ast.ast-source-span-start-col origin.span)
                    12
                    "the source token column survives")))]
            [_
              (test.assert-true
                false
                "the shifted declaration retains its semantic origin")])
          (match (parser.compiler-parse-decl-origin-span (& decls) slot)
            [(Some span)
              (test.assert-i64-eq
                (ast.ast-source-span-start-line span)
                2
                "the declaration span survives")]
            [_
              (test.assert-true
                false
                "the shifted declaration retains its diagnostic origin")])))]
    [_ (test.assert-true false "origin fixture parses")]))

(test
  compiler-load-implicit-module-preserves-declaration-origins
  (begin
    (compiler-load-contextual-origin-check
      "\n(defstruct Value (x i64))"
      "implicit"
      1
      2)
    (compiler-load-contextual-origin-check "\n(defstruct Value (x i64))" "" 0 1)
    (compiler-load-contextual-origin-check
      "(module explicit)\n(defstruct Value (x i64))"
      "implicit"
      1
      2)))

(define (compiler-load-identity-current-ok?) : bool
  (let
    [module-name : String "loader.identity.same"]
    [source-id : i64
      (compiler_load.compiler-load-parse-context-name-id module-name)]
    [generated-id : i64
      (ci.intern-generated-name
        (owned_view.compiler-owned-shared-view module-name))]
    [decls : ast.AstDeclList
      (ast.ast-decl-cons (Module source-id) (ast.ast-decl-list-new))]
    [fallback-from-source : i64
      (compiler_load.compiler-load-module-fallback-id-for-parse
        (owned_view.compiler-owned-shared-view module-name)
        (Some source-id))]
    [fallback-from-generated : i64
      (compiler_load.compiler-load-module-fallback-id-for-parse
        (owned_view.compiler-owned-shared-view module-name)
        (Some generated-id))]
    (and
      (not (= source-id generated-id))
      (= fallback-from-source source-id)
      (= fallback-from-generated source-id)
      (compiler_load.compiler-load-decl-list-has-module-id?
        (owned_view.compiler-owned-shared-view decls)
        source-id)
      (not
        (compiler_load.compiler-load-decl-list-has-module-id?
          decls
          generated-id))
      (match (compiler_load.compiler-load-check-expected-module
        "src/loader_identity.tl"
        (Some source-id)
        (owned_view.compiler-owned-shared-view module-name)
        -1)
        [(Ok _ checked-id) (= checked-id source-id)]
        [(Err _) false])
      (match (compiler_load.compiler-load-check-expected-module
        "src/loader_identity.tl"
        (Some generated-id)
        module-name
        source-id)
        [(Ok _ _) false]
        [(Err _) true]))))

(test
  compiler-load-module-identity-ids
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (unless
      (compiler-load-identity-current-ok?)
      (io.panic "compiler-load: module identity ID provenance failed"))
    (ci.intern-reset!)
    (cbi.compiler-builtin-reset!)
    (cbi.compiler-builtin-initialize-for-parse!)
    (unless
      (compiler-load-identity-current-ok?)
      (io.panic "compiler-load: module identity ID reset failed"))
    (if (let
      [home : ci.InternCompatState (ci.intern-compat-state-capture-active)]
      [state-a : ci.InternCompatState (ci.intern-compat-state-new)]
      [state-b : ci.InternCompatState (ci.intern-compat-state-new)]
      [_b-decoy : i64
        (ci.intern-compat-state-intern (&mut state-b) "loader.identity.decoy")]
      [source-a : i64 -1]
      [source-b : i64 -1]
      [restored-source-a : i64 -1]
      [a-ok : bool false]
      [b-ok : bool false]
      [restored-ok : bool false]
      (begin
        (ci.intern-compat-state-install! state-a)
        (cbi.compiler-builtin-reset!)
        (cbi.compiler-builtin-initialize-for-parse!)
        (set!
          source-a
          (compiler_load.compiler-load-parse-context-name-id
            "loader.identity.same"))
        (set! a-ok (compiler-load-identity-current-ok?))
        (ci.intern-compat-state-capture-from-globals! (&mut state-a))
        (ci.intern-compat-state-install! state-b)
        (cbi.compiler-builtin-reset!)
        (cbi.compiler-builtin-initialize-for-parse!)
        (set!
          source-b
          (compiler_load.compiler-load-parse-context-name-id
            "loader.identity.same"))
        (set! b-ok (compiler-load-identity-current-ok?))
        (ci.intern-compat-state-capture-from-globals! (&mut state-b))
        (ci.intern-compat-state-install! state-a)
        (cbi.compiler-builtin-reset!)
        (cbi.compiler-builtin-initialize-for-parse!)
        (set!
          restored-source-a
          (compiler_load.compiler-load-parse-context-name-id
            "loader.identity.same"))
        (set!
          restored-ok
          (and
            a-ok
            b-ok
            (not (= source-a source-b))
            (= restored-source-a source-a)
            (compiler-load-identity-current-ok?)))
        (ci.intern-compat-state-install! home)
        (cbi.compiler-builtin-reset!)
        (cbi.compiler-builtin-initialize-for-parse!)
        restored-ok))
      unit
      (io.panic "compiler-load: module identity ID snapshot failed"))))