(import stdlib.crypto_aes128_gcm as gcm)
(import stdlib.io)

(define (bad [key : (& key gcm.GcmKey)]) : unit
  (io.println "{}" (deref key)))