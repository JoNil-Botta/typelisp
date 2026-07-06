;; tlci_core_smoke.tl - Executable smoke for tlci parse/emit helpers.
(import tlci_core)

(define (main) : i64
  (tlci_core.tlci-core-self-test))