;; compiler_parse_smoke.tl - Runnable structural smoke for compiler_parse_core.
(import "../compiler_parse_core.tl")

(define (compiler-parse-member-origin-boundary-ok?) : bool
  (match (parse-ast-source
    "(defstruct First (x i64))
(defstruct Second (y i64))")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (let
        [decls : AstDeclList (box-get decls-box)]
        (match (ast-decl-list-get (& decls) 0 (ast-decl-fallback))
          [(AstDecl.DefStruct _ _ _ fields)
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
              (and
                (string.eq (intern-str name) "parsed.module")
                (= (intern "parsed.module") name))]
            [_ false])
          (match (ast-decl-list-get (& decls) 1 (ast-decl-fallback))
            [(AstDecl.DefStruct name _ _ fields)
              (and
                (string.eq (intern-str name) "ParsedType")
                (match (ast-field-def-list-get
                  (& fields)
                  0
                  (ast-field-def-fallback))
                  [(AstFieldDef.Def field _ _)
                    (string.eq (intern-str field) "parsed-field")]))]
            [_ false])
          (match (ast-decl-list-get (& decls) 2 (ast-decl-fallback))
            [(AstDecl.DefFn name params ret _ _)
              (and
                (string.eq (intern-str name) "parsed-fn")
                (match (ast-param-list-get (& params) 0 (ast-param-fallback))
                  [(AstParam.Param param ty _ _)
                    (and
                      (string.eq (intern-str param) "parsed-param")
                      (match ty
                        [(AstType.Var type-name)
                          (string.eq (intern-str type-name) "ParsedType")]
                        [_ false]))])
                (match ret
                  [(AstType.Var type-name)
                    (string.eq (intern-str type-name) "ParsedType")]
                  [_ false]))]
            [_ false])
          (match (ast-decl-list-get (& decls) 3 (ast-decl-fallback))
            [(AstDecl.Test name _ _)
              (string.eq (intern-str name) "parsed-test")]
            [_ false])))]
    [(ResultAstProgram.Err _) false]))

(define (main) : i64
  (if (and
    (= (compiler-diagnostic-self-test) 42)
    (compiler-parse-member-origin-boundary-ok?)
    (compiler-parse-name-id-provenance-ok?))
    (compiler-parse-smoke)
    1))