(import stdlib.crypto_aes_core as aes)
(import stdlib.crypto_secret as secret)

(define (bad [schedule : (& schedule aes.Aes128Schedule)]) : secret.SecretStorage
  (ptr-read schedule.expanded.handle.storage))