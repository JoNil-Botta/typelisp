(import stdlib.crypto_aes_core as aes)
(import stdlib.io)

(define (bad [schedule : (& schedule aes.Aes256Schedule)]) : unit
  (io.println "{}" (deref schedule)))