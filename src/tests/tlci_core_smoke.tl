;; tlci_core_smoke.tl - Executable smoke for tlci parse/emit helpers.
(import tlci_core_tests)

(define (main) : i64
  (tlci_core_tests.tlci-core-self-test))