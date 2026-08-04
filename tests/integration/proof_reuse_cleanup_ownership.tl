;; FileHandle is a normal entry-visible cleanup-owning type.  The generated
;; struct deliberately omits :owned on its FileHandle field.
(import tests.proof_reuse_safety_provider as provider)

(define cleanup-file-handle-total : i64
  0)

(define (cleanup-file-handle-fd [fd : i64]) : unit
  (set! cleanup-file-handle-total (+ cleanup-file-handle-total fd)))

(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup cleanup-file-handle-fd)))

(import (provider.proof-reuse-cleanup-substitution i64) as cleanup_i64)
(import (provider.proof-reuse-cleanup-substitution FileHandle) as cleanup_file)

(define (main) : i64
  42)