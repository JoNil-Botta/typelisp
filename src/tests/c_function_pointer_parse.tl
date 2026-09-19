(import compiler_ast_types as ast)
(import compiler_parse_core as parser)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.test)

(define (c-function-parse-mode [mode : ast.AstCFunctionMode]) : bool
  (match (parser.parse-ast-source
    (str_cat.str-cat
      "(define value : (CFunc "
      (ast.ast-c-function-mode-name mode)
      " (-> i32 f64 u64)) 0)"))
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (ast.ast-decl-list-box-shared-view decls-box)]
        (and
          (= (ast.ast-decl-list-len (& decls)) 1)
          (match (ast.ast-decl-list-ref decls 0)
            [(ast.AstDecl.Def
                _
                _
                (ast.AstMaybeType.Some (ast.AstType.CFunc signature actual))
                _)
              (and
                (ast.ast-c-function-mode-eq? actual mode)
                (match (ast.ast-node-pool-reader-type-get signature)
                  [(ast.AstType.Func args result)
                    (let
                      [params : ast.AstTypeList
                        (ast.ast-type-list-box-shared-view args)]
                      (and
                        (= params.len 2)
                        (ast.ast-type-eq?
                          (ast.ast-node-pool-reader-type-get result)
                          ast.AstType.U64)
                        (ast.ast-type-eq?
                          (ast.ast-node-pool-reader-type-get
                            (ast.ast-type-list-get (& params) 0 0))
                          ast.AstType.I32)
                        (ast.ast-type-eq?
                          (ast.ast-node-pool-reader-type-get
                            (ast.ast-type-list-get (& params) 1 0))
                          ast.AstType.F64)))]
                  [_ false]))]
            [_ false])))]
    [(parser.ResultAstProgram.Err _) false]))

(define (c-function-parse-invalid [type-source : String]) : bool
  (match (parser.parse-ast-source
    (str_cat.str-cat "(define value : " type-source " 0)"))
    [(parser.ResultAstProgram.Err _) true]
    [(parser.ResultAstProgram.Ok _) false]))

(test
  c-function-parser-modes
  (begin
    (test.assert-true
      (c-function-parse-mode ast.AstCFunctionMode.Nullable)
      "nullable C signature")
    (test.assert-true
      (c-function-parse-mode ast.AstCFunctionMode.NonNull)
      "non-null C signature")
    (test.assert-true
      (c-function-parse-mode ast.AstCFunctionMode.UnsafeNullable)
      "unsafe nullable C signature")
    (test.assert-true
      (c-function-parse-mode ast.AstCFunctionMode.UnsafeNonNull)
      "unsafe non-null C signature")))

(test
  c-function-parser-invalid
  (begin
    (test.assert-true (c-function-parse-invalid "(CFunc)") "missing operands")
    (test.assert-true
      (c-function-parse-invalid "(CFunc nullable)")
      "missing signature")
    (test.assert-true
      (c-function-parse-invalid "(CFunc nullable (-> i64) i64)")
      "extra operand")
    (test.assert-true
      (c-function-parse-invalid "(CFunc wrong (-> i64))")
      "unknown mode")
    (test.assert-true
      (c-function-parse-invalid "(CFunc 0 (-> i64))")
      "non-symbol mode")
    (test.assert-true
      (c-function-parse-invalid "(CFunc nullable i64)")
      "non-function signature")
    (test.assert-true
      (c-function-parse-invalid "(CFunc nullable SomeAlias)")
      "signature alias rejected")
    (test.assert-true
      (c-function-parse-invalid "(CFunc nullable (->))")
      "missing result")
    (test.assert-true
      (c-function-parse-invalid "(CFunc nullable (CFunc nullable (-> i64)))")
      "nested wrapper is not a signature")))