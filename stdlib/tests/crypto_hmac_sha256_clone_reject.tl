(import stdlib.clone)
(import stdlib.crypto_hmac_sha256 as hmac)

(define (copy-keyed-state [state : hmac.HmacSha256State]) : hmac.HmacSha256State
  (let
    [copy : hmac.HmacSha256State (clone.deep state)]
    (hmac.close state)
    copy))