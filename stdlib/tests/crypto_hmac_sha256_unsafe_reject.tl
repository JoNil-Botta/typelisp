(import stdlib.crypto_hmac_sha256 as hmac)

;: There is no safe raw secret source or unchecked state adapter.
(define (raw-update [state : (&mut state hmac.HmacSha256State)]) : hmac.HmacSha256Status
  (hmac.update-from-pointer! state (ptr-null : (Ptr u8)) 0))