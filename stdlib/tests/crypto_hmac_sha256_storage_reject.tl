(import stdlib.crypto_hmac_sha256 as hmac)

;: A safe caller cannot project the keyed SHA state through the opaque pointer.
(define (read-keyed-state [storage : (& storage hmac.HmacSha256Storage)]) : i64
  storage.message-length)