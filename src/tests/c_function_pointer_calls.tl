(import compiler_typecheck_api as tc_api)
(import compiler_typecheck_core as tc)
(import compiler_diagnostic as diagnostic)
(import stdlib.string)
(import stdlib.test)

(define (c-function-call-checks? [source : String]) : bool
  (match (tc_api.typecheck-compiler-source source)
    [(tc.ResultCompilerTypecheck.Ok _) true]
    [(tc.ResultCompilerTypecheck.Err _) false]))

(define (c-function-call-error? [source : String] [expected : String]) : bool
  (match (tc_api.typecheck-compiler-source source)
    [(tc.ResultCompilerTypecheck.Err diagnostics)
      (let
        [first : diagnostic.CompilerDiagnostic
          (diagnostic.compiler-diagnostic-list-first
            (diagnostic.compiler-diagnostic-list-box-shared-view diagnostics))]
        (string.contains
          (diagnostic.compiler-diagnostic-message first)
          expected))]
    [(tc.ResultCompilerTypecheck.Ok _) false]))

(test
  c-function-calls-checked-modes
  (begin
    (test.assert-true
      (c-function-call-checks?
        "(define (invoke [f : (CFunc non-null (-> i64 i64))]) : i64 (f 41))")
      "checked non-null C callee accepts its exact arguments")
    (test.assert-true
      (c-function-call-checks?
        "(define (invoke [f : (CFunc unsafe-non-null (-> i64 i64))]) : i64 (unsafe (f 41)))")
      "unsafe checked C callee requires an explicit unsafe call site")
    (test.assert-true
      (c-function-call-checks?
        "(defstruct Table (entry (CFunc non-null (-> i64 i64))))
(define (invoke [table : Table]) : i64 (table.entry 41))")
      "a stored C callee retains its mode and signature")))

(test
  c-function-calls-nullability-and-effect
  (begin
    (test.assert-true
      (c-function-call-error?
        "(define (invoke [f : (CFunc nullable (-> i64 i64))]) : i64 (f 41))"
        "nullable C function pointer must be checked")
      "nullable callee is not callable")
    (test.assert-true
      (c-function-call-error?
        "(define (invoke [f : (CFunc unsafe-nullable (-> i64 i64))]) : i64 (unsafe (f 41)))"
        "nullable C function pointer must be checked")
      "unsafe does not establish non-nullness")
    (test.assert-true
      (c-function-call-error?
        "(define (invoke [f : (CFunc unsafe-non-null (-> i64 i64))]) : i64 (f 41))"
        "requires unsafe")
      "stored unsafe effect cannot be erased by a safe call site")))

(test
  c-function-initialization-preserves-nullability
  (begin
    (test.assert-true
      (c-function-call-checks?
        "(define (empty) : (CFunc nullable (-> i64 i64)) (init : (CFunc nullable (-> i64 i64))))")
      "nullable C function pointer initializes to null")
    (test.assert-true
      (c-function-call-checks?
        "(define (empty) : (CFunc unsafe-nullable (-> i64 i64)) (init : (CFunc unsafe-nullable (-> i64 i64))))")
      "null initialization preserves unsafe mode")
    (test.assert-true
      (c-function-call-error?
        "(define (empty) : (CFunc non-null (-> i64 i64)) (init : (CFunc non-null (-> i64 i64))))"
        "init cannot create a non-null C function pointer")
      "init cannot establish non-nullness")
    (test.assert-true
      (c-function-call-error?
        "(define (empty) : (CFunc unsafe-non-null (-> i64 i64)) (unsafe (init : (CFunc unsafe-non-null (-> i64 i64)))))"
        "init cannot create a non-null C function pointer")
      "unsafe does not permit null proof fabrication")
    (test.assert-true
      (c-function-call-error?
        "(defstruct Table (entry (CFunc non-null (-> i64 i64))))
(define (main) : i64
  (let [entries : (__tl_dyn-array Table) (__tl_make-array Table 1)]
       [table : Table (array-ref entries 0)]
    (table.entry 41)))"
        "init cannot create a non-null C function pointer")
      "zero-filled aggregate arrays cannot manufacture checked code pointers")))

(test
  c-function-extern-signature-admission
  (begin
    (test.assert-true
      (c-function-call-checks?
        "(extern (resolve) : (CFunc non-null (-> i64 i64)) (:abi c))
(define (factory [resolver : (-> (CFunc non-null (-> i64 i64)))]) : (CFunc non-null (-> i64 i64)) (resolver))
(define saved : (CFunc non-null (-> i64 i64)) (factory resolve))
(defstruct Table (entry (CFunc non-null (-> i64 i64))))
(define (main) : i64 (let [table : Table (Table saved)] (+ (saved 41) (table.entry 41))))")
      "higher-order resolver result retains C ABI through a global")
    (test.assert-true
      (c-function-call-checks?
        "(extern (resolve) : (CFunc nullable (-> i64 i64)) (:abi c))
(extern (install [f : (CFunc nullable (-> i64 i64))]) : unit (:abi c))
(define (main) : unit (install (resolve)))")
      "nullable C pointers can pass through native parameters and results")
    (test.assert-true
      (c-function-call-checks?
        "(extern entry : (CFunc non-null (-> i64 i64)))
(define (main) : i64 (entry 41))")
      "external data symbol retains explicit C callable type")
    (test.assert-true
      (c-function-call-error?
        "(extern (resolve) : (CFunc non-null (-> (Slice i64) i64)) (:abi c))"
        "extern ABI c does not support return type")
      "nested C signature must use supported ABI types")
    (test.assert-true
      (c-function-call-error?
        "(extern (resolve) : (CFunc unsafe-non-null (-> i64 i64)))
(define saved : (CFunc unsafe-non-null (-> i64 i64)) (resolve))
(define (main) : i64 (saved 41))"
        "requires unsafe")
      "external result's unsafe effect survives global storage")))