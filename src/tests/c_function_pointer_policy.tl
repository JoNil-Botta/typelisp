(import compiler_typecheck_api as tc_api)
(import compiler_typecheck_core as tc)
(import compiler_diagnostic as diagnostic)
(import stdlib.string)
(import stdlib.test)

(define (c-function-policy-rejects? [source : String]) : bool
  (match (tc_api.typecheck-compiler-source source)
    [(tc.ResultCompilerTypecheck.Err diagnostics)
      (let
        [first : diagnostic.CompilerDiagnostic
          (diagnostic.compiler-diagnostic-list-first
            (diagnostic.compiler-diagnostic-list-box-shared-view diagnostics))]
        (string.contains
          (diagnostic.compiler-diagnostic-message first)
          "extern ABI c does not support"))]
    [(tc.ResultCompilerTypecheck.Ok _) false]))

(test
  c-function-policy-unused-parameter
  (test.assert-true
    (c-function-policy-rejects?
      "(define (unused [f : (CFunc non-null (-> (Slice i64) i64))]) : i64 0)")
    "invalid C signature is rejected before use"))

(test
  c-function-policy-nullable-init
  (test.assert-true
    (c-function-policy-rejects?
      "(define bad : (CFunc nullable (-> (Slice i64) i64)) (init : (CFunc nullable (-> (Slice i64) i64))))")
    "invalid C signature is rejected before use"))

(test
  c-function-policy-struct-field
  (test.assert-true
    (c-function-policy-rejects?
      "(defstruct Bad (entry (CFunc nullable (-> (Slice i64) i64))))")
    "invalid C signature is rejected before use"))

(test
  c-function-policy-enum-payload
  (test.assert-true
    (c-function-policy-rejects?
      "(defenum Bad (Entry (CFunc unsafe-nullable (-> (Slice i64) i64))))")
    "invalid C signature is rejected before use"))

(test
  c-function-policy-lambda-parameter
  (test.assert-true
    (c-function-policy-rejects?
      "(define (main) : i64 (let [f (lambda ([entry : (CFunc unsafe-non-null (-> (Slice i64) i64))]) : i64 0)] 0))")
    "invalid C signature is rejected before use"))

(test
  c-function-policy-boxed-field
  (test.assert-true
    (c-function-policy-rejects?
      "(defstruct Bad (entry (Box (CFunc nullable (-> i64 (Slice i64))))))")
    "invalid C signature is rejected before use"))

(test
  c-function-policy-array-field
  (test.assert-true
    (c-function-policy-rejects?
      "(defstruct Bad (entries (Array (CFunc nullable (-> (Slice i64) i64)) 0)))")
    "invalid C signature is rejected before use"))

(test
  c-function-policy-pointer-field
  (test.assert-true
    (c-function-policy-rejects?
      "(defstruct Bad (entry (Ptr (CFunc nullable (-> (Slice i64) i64)))))")
    "invalid C signature is rejected before use"))

(test
  c-function-policy-ordinary-signature
  (test.assert-true
    (c-function-policy-rejects?
      "(define (unused [f : (-> (CFunc nullable (-> (Slice i64) i64)) i64)]) : i64 0)")
    "invalid C signature is rejected before use"))

(test
  c-function-policy-nested-c-signature
  (test.assert-true
    (c-function-policy-rejects?
      "(define (unused [f : (CFunc non-null (-> (CFunc nullable (-> (Slice i64) i64)) i64))]) : i64 0)")
    "invalid C signature is rejected before use"))

(test
  c-function-policy-borrowed-slice-signature
  (test.assert-true
    (c-function-policy-rejects?
      "(define (unused [f : (CFunc non-null (-> (& n (Slice i64)) i64))]) : i64 0)")
    "invalid C signature is rejected before use"))

(test
  c-function-policy-valid-nested
  (test.assert-true
    (match (tc_api.typecheck-compiler-source
      "(defstruct Entries (items (Array (CFunc nullable (-> i64 i64)) 0)))
(defenum Entry (Present (CFunc unsafe-non-null (-> i64 i64))) (Missing))
(define (relay [f : (CFunc non-null (-> (CFunc nullable (-> i64 i64)) i64))]) : (CFunc non-null (-> (CFunc nullable (-> i64 i64)) i64)) f)")
      [(tc.ResultCompilerTypecheck.Ok _) true]
      [(tc.ResultCompilerTypecheck.Err _) false])
    "valid nested signatures and modes remain admitted"))