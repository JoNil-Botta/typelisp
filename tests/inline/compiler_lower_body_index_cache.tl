;; Regression for stale lowerer global-name cache use during prune body indexing.
(import stdlib.io)
(import stdlib.test)
(import compiler_lower)
(import compiler_diagnostic as diag)

(define (compiler-lower-body-index-cache-regression) : i64
  (let
    [lower-state : compiler_lower.CompilerLowerState
      (compiler_lower.compiler-lower-state-new)]
    [prev-name-cache : compiler_lower.LowerNameCache
      (compiler_lower.lower-active-global-name-cache-current lower-state)]
    (begin
      (compiler_lower.lower-active-global-name-cache-set!
        lower-state
        (compiler_lower.lower-name-cache-from-env
          lower-state
          compiler_lower.LowerNameEnv.Nil))
      (match (compiler_lower.lower-compiler-source-with-state
        lower-state
        "(define (helper) : i64 42)
(module main)
(define (main) : i64 (helper))")
        [(compiler_lower.ResultCompilerLower.Ok _ _)
          (begin
            (compiler_lower.lower-active-global-name-cache-set!
              lower-state
              prev-name-cache)
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