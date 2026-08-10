;; Regression for stale lowerer global-name cache use during prune body indexing.
(import stdlib.io)
(import stdlib.test)
(import compiler_lower)
(import compiler_diagnostic as diag)

(define (compiler-lower-body-index-cache-regression) : i64
  (let
    [prev-name-cache : compiler_lower.LowerNameCache
      (compiler_lower.lower-active-global-name-cache-current)]
    (begin
      (compiler_lower.lower-active-global-name-cache-set!
        (compiler_lower.lower-name-cache-from-env
          compiler_lower.LowerNameEnv.Nil))
      (match (compiler_lower.lower-compiler-source
        "(define (helper) : i64 42)
(module main)
(define (main) : i64 (helper))")
        [(compiler_lower.ResultCompilerLower.Ok _ _)
          (begin
            (compiler_lower.lower-active-global-name-cache-set! prev-name-cache)
            42)]
        [(compiler_lower.ResultCompilerLower.Err diagnostic)
          (io.panic
            (diag.compiler-diagnostic-message (__tl-box-place diagnostic)))]))))

(test
  compiler-lower-body-index-cache
  (test.assert-i64-eq
    (compiler-lower-body-index-cache-regression)
    42
    "module body index should resolve helpers through a fresh global cache"))