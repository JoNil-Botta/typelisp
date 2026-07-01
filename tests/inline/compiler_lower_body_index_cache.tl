;; Regression for stale lowerer global-name cache use during prune body indexing.
(import stdlib.io)
(import "stdlib/test.tl")
(import "../../src/compiler_lower.tl")

(define (compiler-lower-body-index-cache-regression) : i64
  (let
    [prev-name-cache : LowerNameCache lower-active-global-name-cache]
    (begin
      (set!
        lower-active-global-name-cache
        (lower-name-cache-from-env LowerNameEnv.Nil))
      (match (lower-compiler-source
        "(define (helper) : i64 42)
(module main)
(define (main) : i64 (helper))")
        [(ResultCompilerLower.Ok _ _)
          (begin
            (set! lower-active-global-name-cache prev-name-cache)
            42)]
        [(ResultCompilerLower.Err diag)
          (io.panic (compiler-diagnostic-message (box-get diag)))]))))

(test
  compiler-lower-body-index-cache
  (assert-i64-eq
    (compiler-lower-body-index-cache-regression)
    42
    "module body index should resolve helpers through a fresh global cache"))