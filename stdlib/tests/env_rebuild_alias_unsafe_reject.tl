;; Check-only: an import alias does not make the unsafe publication helper safe
;; (#7658).
(import stdlib.env as e)

(define (main) : i64
  (e.linux-rebuild! "TYPELISP_PROOF_ALIAS" "value" true)
  42)