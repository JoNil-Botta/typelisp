(import compiler_typecheck_api as tc_api)
(import compiler_typecheck_core as tc_core)
(import compiler_diagnostic as diagnostic)
(import stdlib.string)
(import stdlib.test)

;: Higher-order C resolvers must not turn their raw result into a closure.
(define (c-function-pointer-erasure-rejected? [source : String]) : bool
  (match (tc_api.typecheck-compiler-source source)
    [(tc_core.ResultCompilerTypecheck.Err diagnostics)
      (let
        [first : diagnostic.CompilerDiagnostic
          (diagnostic.compiler-diagnostic-list-first
            (diagnostic.compiler-diagnostic-list-box-shared-view diagnostics))]
        (string.contains
          (diagnostic.compiler-diagnostic-message first)
          "raw C function pointer"))]
    [(tc_core.ResultCompilerTypecheck.Ok _) false]))

(test
  c-function-pointer-higher-order-global-erasure
  (test.assert-true
    (c-function-pointer-erasure-rejected?
      "(extern (resolve) : (-> i64 i64))
(define (factory [resolver : (-> (-> i64 i64))]) : (-> i64 i64)
  (resolver))
(define saved : (-> i64 i64) (factory resolve))
(define (main) : i64 (saved 41))")
    "a higher-order resolver cannot publish raw code as a closure descriptor"))

(test
  c-function-pointer-higher-order-field-erasure
  (test.assert-true
    (c-function-pointer-erasure-rejected?
      "(extern (resolve) : (-> i64 i64))
(defstruct Table (entry (-> i64 i64)))
(define (factory [resolver : (-> (-> i64 i64))]) : Table
  (Table (resolver)))
(define (main) : i64
  (let [table : Table (factory resolve)] (table.entry 41)))")
    "an aggregate field cannot erase the result ABI of a C resolver"))

(test
  c-function-pointer-resolver-alias-erasure
  (test.assert-true
    (c-function-pointer-erasure-rejected?
      "(extern (resolve) : (-> i64 i64))
(define (main) : i64
  (let
    [resolver : (-> (-> i64 i64)) resolve]
    [entry : (-> i64 i64) (resolver)]
    (entry 41)))")
    "aliasing the resolver cannot erase the ABI of its later result"))

(test
  c-function-pointer-resolver-branch-erasure
  (test.assert-true
    (c-function-pointer-erasure-rejected?
      "(extern (resolve-a) : (-> i64 i64))
(extern (resolve-b) : (-> i64 i64))
(define (select [first : bool]) : (-> (-> i64 i64))
  (if first resolve-a resolve-b))
(define (main) : i64
  (let [resolver : (-> (-> i64 i64)) (select true)]
    (let [entry : (-> i64 i64) (resolver)] (entry 41))))")
    "both-extern branches still cannot become an ordinary resolver value"))