;; tlci_loader_smoke.tl - Executable smoke for tlci loader helpers (#2657).
(import "../tlci_loader.tl")

(define (main) : i64
  (tlci-loader-self-test))