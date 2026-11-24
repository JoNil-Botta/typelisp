(import stdlib.clone)
(import stdlib.crypto_aes_core as aes)

(define (bad [schedule : (& schedule aes.Aes128Schedule)]) : aes.Aes128Schedule
  (clone.deep (deref schedule)))