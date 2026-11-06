(import stdlib.crypto_aes128_gcm as gcm)

(define (bad [key : (& key gcm.GcmKey)]) : gcm.GcmKey
  (clone (deref key)))