;; tlci_loader_smoke.tl - Executable smoke for tlci loader helpers.
(import tlci_loader_tests)

(define (main) : i64
  (tlci_loader_tests.tlci-loader-self-test))