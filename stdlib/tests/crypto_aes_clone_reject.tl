(import stdlib.crypto_aes_core as aes)

(define (bad [schedule : (& schedule aes.Aes128Schedule)]) : aes.Aes128Schedule
  (clone (deref schedule)))