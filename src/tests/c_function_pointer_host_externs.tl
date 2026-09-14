;; Generated native host pointers must retain the same canonical callable type
;; as user-written external data declarations.
(import compiler_tlci_native_producer as producer)
(import compiler_typecheck_api as tc_api)
(import compiler_typecheck_core as tc)
(import stdlib.test)

(test
  c-function-pointer-generated-host-externs
  (test.assert-true
    (match (tc_api.typecheck-compiler-source
      (producer.embedded-native-host-externs))
      [(tc.ResultCompilerTypecheck.Ok _) true]
      [(tc.ResultCompilerTypecheck.Err _) false])
    "all generated host pointer declarations typecheck without legacy erasure"))