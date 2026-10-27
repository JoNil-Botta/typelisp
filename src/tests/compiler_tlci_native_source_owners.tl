(import compiler_tlci_native_producer_tests as owners)

(define (main) : i64
  (owners.producer-source-failure-sentinel!)
  (owners.producer-pattern-fallback!)
  (owners.producer-owner-isolation!)
  (owners.producer-owner-result-kinds!)
  42)