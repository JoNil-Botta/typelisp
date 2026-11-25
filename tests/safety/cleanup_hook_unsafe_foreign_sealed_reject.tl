;; A foreign unsafe hook cannot run on a value the owner merely holds: the
;; trigger would close the secret from safe code (#9783).
(import stdlib.crypto_secret as secret)

; Must fail: `secret/storage-close` is a foreign unsafe declaration.
(defstruct Trigger
  (:cleanup close-trigger)
  (h secret.SecretHandle (:cleanup secret/storage-close)))

(define (main) : i64
  0)