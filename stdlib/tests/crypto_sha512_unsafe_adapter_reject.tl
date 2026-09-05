(import stdlib.crypto_sha512)

(define (main) : i64
  (let
    [state : crypto_sha512.Sha512State (crypto_sha512.new)]
    (begin
      (crypto_sha512.update-from-pointer! (&mut state) (ptr-null : (Ptr u8)) 0)
      42)))