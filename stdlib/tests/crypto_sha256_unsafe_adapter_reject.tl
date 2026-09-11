(import stdlib.crypto_sha256)

(define (main) : i64
  (let
    [state : crypto_sha256.Sha256State (crypto_sha256.new)]
    (begin
      (crypto_sha256.update-from-pointer! (&mut state) (ptr-null : (Ptr u8)) 0)
      42)))