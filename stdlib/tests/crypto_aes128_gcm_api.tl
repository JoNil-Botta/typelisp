(import stdlib.tests.crypto_aes128_gcm_kat_inline as vectors)

(define (main) : i64
  (vectors.self-test)
  42)