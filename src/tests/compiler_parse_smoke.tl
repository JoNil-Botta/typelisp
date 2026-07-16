;; compiler_parse_smoke.tl - Runnable structural smoke for compiler_parse_core.
(import "../compiler_parse_core.tl")
(import compiler_builtin_ids as cbi)

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

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (if (and
      (= (compiler-diagnostic-self-test) 42)
      (compiler-parse-member-origin-boundary-ok?))
      (compiler-parse-smoke)
      1)))