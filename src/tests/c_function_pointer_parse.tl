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
    [(Ok (Program decls-box))
      (let
        [decls : ast.AstDeclList (ast.ast-decl-list-box-shared-view decls-box)]
        (and
          (= (ast.ast-decl-list-len (& decls)) 1)
          (match (ast.ast-decl-list-ref decls 0)
            [(Def _ _ (Some (CFunc signature actual)) _)
              (and
                (ast.ast-c-function-mode-eq? actual mode)
                (match (ast.ast-node-pool-reader-type-get signature)
                  [(Func args result)
                    (let
                      [params : ast.AstTypeList
                        (ast.ast-type-list-box-shared-view args)]
                      (and
                        (= params.len 2)
                        (ast.ast-type-eq?
                          (ast.ast-node-pool-reader-type-get result)
                          U64)
                        (ast.ast-type-eq?
                          (ast.ast-node-pool-reader-type-get
                            (ast.ast-type-list-get (& params) 0 0))
                          I32)
                        (ast.ast-type-eq?
                          (ast.ast-node-pool-reader-type-get
                            (ast.ast-type-list-get (& params) 1 0))
                          F64)))]
                  [_ false]))]
            [_ false])))]
    [(Err _) false]))

(define (c-function-parse-invalid [type-source : String]) : bool
  (match (parser.parse-ast-source
    (str_cat.str-cat "(define value : " type-source " 0)"))
    [(Err _) true]
    [(Ok _) false]))

(test
  c-function-parser-modes
  (test.assert-true (c-function-parse-mode Nullable) "nullable C signature")
  (test.assert-true (c-function-parse-mode NonNull) "non-null C signature")
  (test.assert-true
    (c-function-parse-mode UnsafeNullable)
    "unsafe nullable C signature")
  (test.assert-true
    (c-function-parse-mode UnsafeNonNull)
    "unsafe non-null C signature"))

(test
  c-function-parser-invalid
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
    "nested wrapper is not a signature"))