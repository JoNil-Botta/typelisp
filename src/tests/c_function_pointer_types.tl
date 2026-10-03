(import compiler_ast_types as ast)
(import compiler_ast_types_tests as ast_tests)
(import compiler_builtin_ids as cbi)
(import stdlib.test)

(define (c-function-test-type-id
  [mode : ast.AstCFunctionMode]
  [result : ast.AstType]) : i64
  (ast.ast-node-pool-reader-type-push
    (ast_tests.ast-ty-c-func
      (ast.ast-type-cons I64 (ast.ast-type-list-new))
      result
      mode)))

(define (c-function-test-mode [index : i64]) : ast.AstCFunctionMode
  (cond
    [(= index 0) Nullable]
    [(= index 1) NonNull]
    [(= index 2) UnsafeNullable]
    [else UnsafeNonNull]))

(test
  c-function-type-node-stride
  (test.assert-true
    (ast_tests.ast-node-stride-pinned?)
    "adding C callable identity must preserve the real 24-byte type node stride"))

(test
  c-function-type-identity
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (let
      [ordinary : i64
        (ast.ast-node-pool-reader-type-push
          (ast.ast-ty-func (ast.ast-type-cons I64 (ast.ast-type-list-new)) I64))]
      [index : i64 0]
      (while (< index 4)
        (let
          [mode : ast.AstCFunctionMode (c-function-test-mode index)]
          [first : i64 (c-function-test-type-id mode I64)]
          [repeated : i64 (c-function-test-type-id mode I64)]
          [other-result : i64 (c-function-test-type-id mode U64)]
          [other : i64 0]
          (begin
            (test.assert-true
              (= first repeated)
              "equal C signatures deduplicate")
            (test.assert-true
              (not (= first ordinary))
              "C code and ordinary closure descriptors have distinct identity")
            (test.assert-true
              (not (= first other-result))
              "C signatures preserve their exact result type")
            (while (< other 4)
              (let
                [second : i64
                  (c-function-test-type-id (c-function-test-mode other) I64)]
                (begin
                  (test.assert-true
                    (= (= first second) (= index other))
                    "deduplication preserves nullability and unsafe effect")
                  (test.assert-true
                    (=
                      (ast.ast-type-eq?
                        (ast.ast-node-pool-reader-type-get first)
                        (ast.ast-node-pool-reader-type-get second))
                      (= index other))
                    "structural equality preserves nullability and unsafe effect")
                  (set! other (+ other 1)))))
            (set! index (+ index 1))))))))