;; compiler_frontend_smoke_suite.tl - Compile-once suite for source-owned
;; semantic and documentation self-tests. Drivers with substantial test bodies
;; remain standalone.
(import stdlib.io)
(import stdlib.process)
(import stdlib.string)
(import compiler_symbols)
(import compiler_check_core)
(import compiler_semantic_index)
(import compiler_typecheck)
(import compiler_ctfe)
(import doc_test)
(import compiler_builtin_ids as cbi)

(define (compiler-smoke-suite-child-ok? [name : String]) : bool
  (process.result-output-eq?
    (process.output (process.command (io.arg 0) (process.args-single name)))
    42
    ""
    ""))

(define (compiler-smoke-suite-require-child [name : String] [message : String]) : unit
  (unless (compiler-smoke-suite-child-ok? name) (io.panic message)))

(define (compiler-smoke-suite-child [name : String]) : i64
  (cond
    [(string.eq name "symbols")
      (begin
        (cbi.compiler-builtin-initialize-for-parse!)
        (compiler_symbols.compiler-symbols-self-test))]
    [(string.eq name "check")
      (begin
        (cbi.compiler-builtin-initialize-for-parse!)
        (if (and
          (= (compiler_check_core.compiler-check-self-test) 42)
          (compiler_semantic_index.compiler-check-semantic-index-ok?))
          42
          1))]
    [(string.eq name "ctfe") (compiler_ctfe.compiler-ctfe-self-test)]
    [(string.eq name "reflection")
      (begin
        (cbi.compiler-builtin-initialize-for-parse!)
        (if (compiler_typecheck.compiler-typecheck-reflection-tests-ok?)
          42
          1))]
    [(string.eq name "doc-test") (doc_test.doc-test-smoke-all)]
    [else 1]))

(define (main) : i64
  (if (> (io.arg-count) 1)
    (compiler-smoke-suite-child (io.arg 1))
    (begin
      (compiler-smoke-suite-require-child
        "symbols"
        "compiler smoke suite: compiler_symbols_smoke failed")
      (compiler-smoke-suite-require-child
        "check"
        "compiler smoke suite: compiler_check_smoke failed")
      (compiler-smoke-suite-require-child
        "ctfe"
        "compiler smoke suite: compiler_ctfe_smoke failed")
      (compiler-smoke-suite-require-child
        "reflection"
        "compiler smoke suite: compiler_typecheck_reflection_smoke failed")
      (compiler-smoke-suite-require-child
        "doc-test"
        "compiler smoke suite: doc_test_smoke failed")
      42)))