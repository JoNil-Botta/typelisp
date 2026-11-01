(import stdlib.crypto_aes_core as aes)
(import stdlib.crypto_secret as secret)

(define (main) : i64
  (let
    [source : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    [destination : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    [ok : bool true]
    (match (aes.new-128 (secret.fixed-zero (secret.Secret16)))
      [(Aes128Ok schedule)
        (let
          [index : i64 0]
          (while (< index 2)
            (match (aes.encrypt-128! (& schedule) (& source) (&mut destination))
              [(AesOk) unit]
              [_ (set! ok false)])
            (set! index (+ index 1))))
        (aes.close-128 schedule)]
      [_ (set! ok false)])
    (match (aes.new-256 (secret.fixed-zero (secret.Secret32)))
      [(Aes256Ok schedule)
        (let
          [index : i64 0]
          (while (< index 2)
            (match (aes.encrypt-256! (& schedule) (& source) (&mut destination))
              [(AesOk) unit]
              [_ (set! ok false)])
            (set! index (+ index 1))))
        (aes.close-256 schedule)]
      [_ (set! ok false)])
    (secret.close-fixed source)
    (secret.close-fixed destination)
    (if ok
      42
      1)))