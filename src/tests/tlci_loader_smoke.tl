;; tlci_loader_smoke.tl - Executable smoke for tlci loader helpers.
(import tlci_loader)

(define (main) : i64
  (tlci_loader.tlci-loader-self-test))