;; compiler_parse_smoke.tl - Runnable structural smoke for compiler_parse_core.
(import "../compiler_parse_core.tl")
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)

(define (compiler-parse-test-decl-origin-start-ok?
  [origin : CompilerParseMaybeDeclSpan]
  [line : i64]
  [col : i64]) : bool
  (match origin
    [(CompilerParseMaybeDeclSpan.Some span)
      (and
        (= (ast-source-span-start-line span) line)
        (= (ast-source-span-start-col span) col))]
    [(CompilerParseMaybeDeclSpan.None) false]))

(define (compiler-parse-test-decl-origin-records-ok?) : bool
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [ok : bool false]
    (begin
      (match (parse-ast-source
        "(module alpha)
(unsafe (extern (bad [arg0 : (Tuple i64 i64)]) : i64 (:abi c)))
(defstruct RefBox (:lifetimes a a) (value (& a i64)))")
        [(ResultAstProgram.Ok (AstProgram.Program decls-box))
          (let
            [decls : AstDeclList (box-get decls-box)]
            [tail1 : AstDeclList (ast-decl-list-tail decls)]
            [tail2 : AstDeclList (ast-decl-list-tail tail1)]
            [replacement : AstDeclList (ast-decl-list-with-capacity 3)]
            [alias1 : AstDeclList (ast-decl-list-with-capacity 3)]
            [alias2 : AstDeclList (ast-decl-list-with-capacity 3)]
            (begin
              (ast-decl-list-append-from (&mut replacement) (& decls) 0)
              (compiler-parse-decl-origin-register-maybe!
                (& replacement)
                0
                (compiler-parse-decl-origin-span (& decls) 0))
              (compiler-parse-decl-origin-register-maybe!
                (& replacement)
                2
                (compiler-parse-decl-origin-span (& tail2) 0))
              (ast-decl-list-append-from (&mut alias1) (& replacement) 0)
              (compiler-parse-decl-origin-register-list-aliases!
                (& alias1)
                0
                replacement)
              (ast-decl-list-append-from (&mut alias2) (& alias1) 0)
              (compiler-parse-decl-origin-register-list-aliases!
                (& alias2)
                0
                alias1)
              (set!
                ok
                (and
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler-parse-decl-origin-span (& decls) 0)
                    1
                    1)
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler-parse-decl-origin-span (& tail1) 0)
                    2
                    9)
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler-parse-decl-origin-span (& tail2) 0)
                    3
                    1)
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler-parse-decl-origin-span (& replacement) 0)
                    1
                    1)
                  (match (compiler-parse-decl-origin-span (& replacement) 1)
                    [(CompilerParseMaybeDeclSpan.None) true]
                    [_ false])
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler-parse-decl-origin-span (& replacement) 2)
                    3
                    1)
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler-parse-decl-origin-span (& alias2) 0)
                    1
                    1)
                  (match (compiler-parse-decl-origin-span (& alias2) 1)
                    [(CompilerParseMaybeDeclSpan.None) true]
                    [_ false])
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler-parse-decl-origin-span (& alias2) 2)
                    3
                    1)))
              (reader.sp-node-pool-truncate! mark)
              (compiler-parse-decl-origin-cache-reset!)
              (set!
                ok
                (and
                  ok
                  (match (compiler-parse-decl-origin-span (& decls) 0)
                    [(CompilerParseMaybeDeclSpan.None) true]
                    [_ false])))))]
        [(ResultAstProgram.Err _) (reader.sp-node-pool-truncate! mark)])
      ok)))

(define (compiler-parse-member-origin-boundary-ok?) : bool
  (match (parse-ast-source
    "(defstruct First (x i64))
(defstruct Second (y i64))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-get (& decls) 0 (ast-decl-fallback))
          [(AstDecl.DefStruct decl-meta _ _ _ fields)
            (let
              [span : AstSourceSpan
                (compiler-parse-field-def-list-span-get
                  (& fields)
                  1
                  (ast-decl-span-fallback))]
              (and
                (= (ast-source-span-start-line span) 1)
                (= (ast-source-span-start-col span) 12)))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-test-name-id? [name-id : i64] [text : String]) : bool
  (match (ci.intern-lookup text)
    [(ci.InternLookupFound expected-id) (= name-id expected-id)]
    [(ci.InternLookupMissing) false]))

(define (compiler-parse-name-id-provenance-ok?) : bool
  ;; Keep the inline-test discovery marker split: this source is parser input,
  ;; not an inline test declaration in this file.
  (match (parse-ast-source
    (string.concat3
      "(module parsed.module)
(defstruct ParsedType (parsed-field i64))
(define (parsed-fn [parsed-param : ParsedType]) : ParsedType parsed-param)
"
      "("
      "test parsed-test unit)"))
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (and
          (match (ast-decl-list-get (& decls) 0 (ast-decl-fallback))
            [(AstDecl.Module name)
              (compiler-parse-test-name-id? name "parsed.module")]
            [_ false])
          (match (ast-decl-list-get (& decls) 1 (ast-decl-fallback))
            [(AstDecl.DefStruct decl-meta name _ _ fields)
              (and
                (compiler-parse-test-name-id? name "ParsedType")
                (match (ast-field-def-list-get
                  (& fields)
                  0
                  (ast-field-def-fallback))
                  [(AstFieldDef.Def field _ _)
                    (compiler-parse-test-name-id? field "parsed-field")]))]
            [_ false])
          (match (ast-decl-list-get (& decls) 2 (ast-decl-fallback))
            [(AstDecl.DefFn decl-meta name params ret _ _)
              (and
                (compiler-parse-test-name-id? name "parsed-fn")
                (match (ast-param-list-get (& params) 0 (ast-param-fallback))
                  [(AstParam.Param param ty _ _)
                    (and
                      (compiler-parse-test-name-id? param "parsed-param")
                      (match ty
                        [(AstType.Var type-name)
                          (compiler-parse-test-name-id? type-name "ParsedType")]
                        [_ false]))])
                (match ret
                  [(AstType.Var type-name)
                    (compiler-parse-test-name-id? type-name "ParsedType")]
                  [_ false]))]
            [_ false])
          (match (ast-decl-list-get (& decls) 3 (ast-decl-fallback))
            [(AstDecl.Test name _ _)
              (compiler-parse-test-name-id? name "parsed-test")]
            [_ false])))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-removed-declaration-errors-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(comptime-decl (define value : i64 1))"
      (parse-ast-removed-declaration-message))
    (compiler-parse-error-ok?
      "(comptime-decls (define value : i64 1))"
      (parse-ast-removed-declaration-message))
    (compiler-parse-error-ok?
      "(define (main) : i64 (comptime-decl (define value : i64 1)))"
      (parse-ast-removed-declaration-message))
    (compiler-parse-error-ok?
      "(define (main) : i64 (comptime-decls (define value : i64 1)))"
      (parse-ast-removed-declaration-message))))

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (if (and
      (= (compiler-diagnostic-self-test) 42)
      (compiler-parse-test-decl-origin-records-ok?)
      (compiler-parse-member-origin-boundary-ok?)
      (compiler-parse-name-id-provenance-ok?)
      (compiler-parse-removed-declaration-errors-ok?))
      (compiler-parse-smoke)
      1)))