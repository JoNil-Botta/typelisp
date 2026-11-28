(import stdlib.crypto_sha256 as sha)

(define (main) : i64
  (let
    [state : sha.Sha256State (sha.new)]
    state.block-length))