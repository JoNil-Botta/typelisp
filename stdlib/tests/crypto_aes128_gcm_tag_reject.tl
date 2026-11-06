(import stdlib.crypto_aes128_gcm as gcm)

(define (bad
  [key : (& key gcm.GcmKey)]
  [nonce : (& nonce gcm.GcmNonce)]
  [aad : (& aad bytes)]
  [ct : (& ct bytes)]) : gcm.GcmOpenResult
  (gcm.open key nonce aad ct nonce))