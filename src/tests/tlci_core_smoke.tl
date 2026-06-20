;; tlci_core_smoke.tl - Executable smoke for tlci parse/emit helpers (#2651).
(import "../tlci_core.tl")

(define (main) : i64
  (tlci-core-self-test))