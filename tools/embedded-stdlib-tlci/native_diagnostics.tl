(import compiler_tlci_native_producer_tests as producer_tests)

(define (main) : i64
  (producer_tests.producer-splice-diagnostics!)
  42)